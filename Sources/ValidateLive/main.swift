// Live end-to-end validation: drives a REAL RDP connection through CRDPBridge and
// exercises the clipboard channel, verifying the session survives clipboard activity
// (the "copying resets the connection" bug killed the cliprdr channel here).
//
// Reads the saved password from the Tier-2 keychain item directly — the raw item is a
// plain generic password (the Touch-ID gate lives in the app, not on the item), so the
// password stays inside this process and is never printed.
//
// Usage: ValidateLive <host> <port> <user> <domain|-> <account-uuid> [--stress [iterations]]
//
// F-23 `--stress` mode: instead of the clipboard validation, hammers the Cluster-A
// concurrency hardening (ctxLock / cbLock / rdpbridge_detach) with three phases of
// bridge churn (rapid connect/free cycles, mid-connect detach+free at varying delays,
// and a second thread spamming input/stats across a disconnect). PASS = no crash and
// zero callbacks delivered after rdpbridge_detach returned. Needs a live host to RUN.

import Foundation
import Security
import CRDPBridge

final class State: @unchecked Sendable {
    let lock = NSLock()
    var reachedConnected = false
    var failed = false
    var failMsg = ""
    var lastStateName = "idle"
    var clipboardFromRemote: String?
    func set(_ body: () -> Void) { lock.lock(); body(); lock.unlock() }
}
let S = State()

func readKeychainPassword(service: String, account: String) -> String? {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: AnyObject?
    let st = SecItemCopyMatching(q as CFDictionary, &out)
    if st != errSecSuccess {
        FileHandle.standardError.write(Data("keychain read status: \(st)\n".utf8))
        return nil
    }
    guard let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

let onState: RDPBridgeStateCb = { _, state, code, str in
    let s = str.map { String(cString: $0) } ?? ""
    var name = "?"
    S.set {
        switch state {
        case RDPB_STATE_CONNECTING:     name = "connecting"
        case RDPB_STATE_AUTHENTICATING: name = "authenticating"
        case RDPB_STATE_NEGOTIATING:    name = "negotiating"
        case RDPB_STATE_CONNECTED:      name = "connected";    S.reachedConnected = true
        case RDPB_STATE_DISCONNECTED:   name = "disconnected(\(s))"
        case RDPB_STATE_FAILED:         name = "failed";       S.failed = true; S.failMsg = "\(code) \(s)"
        default:                        name = "idle"
        }
        S.lastStateName = name
    }
    print("[state] \(name)\(state == RDPB_STATE_FAILED ? " — \(code) \(s)" : "")")
}
let onFrame: RDPBridgeFrameCb = { _,_,_,_,_,_,_,_,_ in }
let onResize: RDPBridgeResizeCb = { _,_,_ in }
let onCert: RDPBridgeCertCb = { _, _ in 1 }   // accept (TOFU) for the test
let onClip: RDPBridgeClipboardCb = { _, txt in
    let s = txt.map { String(cString: $0) } ?? ""
    S.set { S.clipboardFromRemote = s }
    print("[clipboard <- remote] \"\(s)\"")
}

let args = CommandLine.arguments
let usageLine = "usage: ValidateLive <host> <port> <user> <domain|-> <account-uuid> [--stress [iterations]]"
guard args.count >= 6 else {
    print(usageLine); exit(2)
}
let host = args[1], user = args[3], account = args[5]
let port = UInt32(args[2]) ?? 3389
let domain = args[4] == "-" ? nil : args[4]

// F-23: optional stress mode. Positional args stay exactly as before; `--stress`
// (with an optional iteration count, default 50) must follow them.
var stressMode = false
var stressIterations = 50
if args.count >= 7 {
    guard args[6] == "--stress" else { print(usageLine); exit(2) }
    stressMode = true
    if args.count >= 8 {
        guard let n = Int(args[7]), n >= 1 else { print(usageLine); exit(2) }
        stressIterations = n
    }
}

guard let password = readKeychainPassword(service: "com.touchrdp.app.credential", account: account) else {
    print("FAIL: could not read saved password from keychain"); exit(1)
}

guard let hostC = strdup(host), let userC = strdup(user) else { print("FAIL: oom"); exit(1) }
let domainC: UnsafeMutablePointer<CChar>? = domain.flatMap { strdup($0) }
defer { free(hostC); free(userC); if let d = domainC { free(d) } }

var cfg = RDPBridgeConfig()
cfg.hostname = UnsafePointer(hostC)
cfg.port = port
cfg.username = UnsafePointer(userC)
cfg.domain = domainC.map { UnsafePointer($0) }
cfg.width = 1280; cfg.height = 800
cfg.desktopScaleFactor = 100
cfg.security = RDPB_SEC_NLA
cfg.clipboardEnabled = 1
cfg.audioEnabled = 0
cfg.tcpConnectTimeoutMs = 15000

// ============================================================================
// F-23 — teardown/concurrency stress mode (`--stress [iterations]`).
//
// Exercises the Cluster-A hardening WITHOUT a UI, in three phases of
// `iterations` each:
//   A) rapid connect -> wait-for-connected (bounded) -> disconnect + detach + free;
//   B) mid-connect teardown: start connect, then detach+free after a deterministic
//      (i*37)%200 ms delay so the teardown lands in different connect phases
//      (rdpbridge_free joins the RDP thread, so this is the supported contract);
//   C) while connected, a second thread spams send_pointer/send_scancode/get_stats
//      in a tight loop while the main thread disconnects — the ctxLock `connected`
//      gate must turn the racing calls into safe no-ops, never a UAF.
//
// Anomaly detection: each bridge generation's index is passed as userCtx; every
// callback checks it against the currently-live generation under a lock. After
// rdpbridge_detach returns the live generation is cleared, so ANY later callback
// (nulled ctx or stale generation) counts as a contract violation. PASS requires
// anomalies == 0, no hard failures, and at least one real connect. No crash = the
// locks held; a crash fails by definition (no summary, signal exit).
// ============================================================================

final class StressMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var liveGen = 0          // generation of the one live bridge; 0 = none
    private var connected = false
    private var terminal = false     // failed or disconnected seen this generation
    private var lastState = "idle"
    private var anomalies = 0
    private var anomalyNotes: [String] = []

    func begin(gen: Int) {
        lock.lock()
        liveGen = gen; connected = false; terminal = false; lastState = "idle"
        lock.unlock()
    }
    func end() { lock.lock(); liveGen = 0; lock.unlock() }   // call AFTER rdpbridge_detach returns

    private func genOK(_ gen: Int, _ kind: String) -> Bool { // caller holds lock
        if gen == liveGen && gen != 0 { return true }
        anomalies += 1
        if anomalyNotes.count < 25 {
            anomalyNotes.append("\(kind) callback outside live window (cb gen \(gen), live gen \(liveGen))")
        }
        return false
    }
    func event(gen: Int, kind: String) { lock.lock(); _ = genOK(gen, kind); lock.unlock() }
    func stateEvent(gen: Int, name: String, isConnected: Bool, isTerminal: Bool) {
        lock.lock()
        if genOK(gen, "state(\(name))") {
            lastState = name
            if isConnected { connected = true }
            if isTerminal { terminal = true }
        }
        lock.unlock()
    }
    func snapshot() -> (connected: Bool, terminal: Bool, state: String) {
        lock.lock(); defer { lock.unlock() }
        return (connected, terminal, lastState)
    }
    func result() -> (anomalies: Int, notes: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (anomalies, anomalyNotes)
    }
}
let SM = StressMonitor()

func stressGen(_ ctx: UnsafeMutableRawPointer?) -> Int { ctx.map { Int(bitPattern: $0) } ?? 0 }

let stressOnState: RDPBridgeStateCb = { ctx, state, _, _ in
    var name = "idle"; var conn = false; var term = false
    switch state {
    case RDPB_STATE_CONNECTING:     name = "connecting"
    case RDPB_STATE_AUTHENTICATING: name = "authenticating"
    case RDPB_STATE_NEGOTIATING:    name = "negotiating"
    case RDPB_STATE_CONNECTED:      name = "connected";    conn = true
    case RDPB_STATE_DISCONNECTED:   name = "disconnected"; term = true
    case RDPB_STATE_FAILED:         name = "failed";       term = true
    default: break
    }
    SM.stateEvent(gen: stressGen(ctx), name: name, isConnected: conn, isTerminal: term)
}
let stressOnFrame: RDPBridgeFrameCb = { ctx, _,_,_,_,_,_,_,_ in SM.event(gen: stressGen(ctx), kind: "frame") }
let stressOnResize: RDPBridgeResizeCb = { ctx, _,_ in SM.event(gen: stressGen(ctx), kind: "resize") }
let stressOnCert: RDPBridgeCertCb = { ctx, _ in SM.event(gen: stressGen(ctx), kind: "cert"); return 1 } // accept (TOFU)
let stressOnClip: RDPBridgeClipboardCb = { ctx, _ in SM.event(gen: stressGen(ctx), kind: "clipboard") }

/// The bridge pointer / stop flag / call counter cross into the phase-C hammer
/// thread; tiny lock-guarded boxes keep that explicit (and Swift-6-migration clean).
final class BridgeBox: @unchecked Sendable {
    let b: OpaquePointer
    init(_ b: OpaquePointer) { self.b = b }
}
final class StressFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}
final class StressCounter: @unchecked Sendable {
    private let lock = NSLock(); private var v = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    func add(_ n: Int) { lock.lock(); v += n; lock.unlock() }
}

func stressCreateBridge(gen: Int) -> OpaquePointer? {
    SM.begin(gen: gen)
    let cbs = RDPBridgeCallbacks(onState: stressOnState, onFrame: stressOnFrame, onResize: stressOnResize,
                                 onCertVerify: stressOnCert, onClipboard: stressOnClip, onClipboardImage: nil,
                                 onCursor: nil, onCursorHidden: nil, onCursorDefault: nil,
                                 onClipboardFiles: nil, onFileContents: nil)
    return rdpbridge_create(UnsafeMutableRawPointer(bitPattern: gen), cbs)
}

func stressConnect(_ b: OpaquePointer) -> Bool {
    let bytes = Array(password.utf8)
    return bytes.withUnsafeBufferPointer {
        rdpbridge_connect(b, &cfg, $0.baseAddress, $0.count)
    } == 1
}

/// Detach-then-free per the bridge contract; clearing the live generation between
/// the two is what arms the "no callback may arrive after detach" assertion.
func stressTeardown(_ b: OpaquePointer) {
    rdpbridge_detach(b)
    SM.end()
    rdpbridge_free(b)
}

/// Poll `done` every 50 ms for up to `ms` milliseconds.
@discardableResult
func stressWait(ms: Int, done: () -> Bool) -> Bool {
    var waited = 0
    while waited < ms {
        if done() { return true }
        usleep(50_000); waited += 50
    }
    return done()
}

func runStress(iterations: Int) -> Never {
    print("== F-23 stress mode: \(iterations) iterations/phase against \(host):\(port) as \(user) ==")
    print("== exercising ctxLock/cbLock/rdpbridge_detach under churn (no UI) ==")

    var gen = 0
    var hardFailures = 0                       // create/connect-thread-start failures
    var connectsA = 0, noConnectA = 0
    var connectsC = 0, noConnectC = 0
    var histogram: [String: Int] = [:]         // phase B: connect phase at teardown
    var hammerCalls = 0

    // -- Phase A: rapid connect -> connected -> immediate disconnect+detach+free --
    print("-- phase A: connect/disconnect churn x\(iterations) --")
    for i in 1...iterations {
        gen += 1
        guard let b = stressCreateBridge(gen: gen) else { hardFailures += 1; SM.end(); continue }
        guard stressConnect(b) else { hardFailures += 1; stressTeardown(b); continue }
        stressWait(ms: 20_000) { let s = SM.snapshot(); return s.connected || s.terminal }
        if SM.snapshot().connected { connectsA += 1 } else { noConnectA += 1 }
        rdpbridge_disconnect(b)
        stressWait(ms: 3_000) { SM.snapshot().terminal }
        stressTeardown(b)
        if i % 10 == 0 || i == iterations {
            print("   A \(i)/\(iterations): connected \(connectsA), anomalies \(SM.result().anomalies)")
        }
    }

    // -- Phase B: mid-connect teardown at deterministic, phase-scanning delays --
    print("-- phase B: mid-connect detach+free at (i*37)%200 ms x\(iterations) --")
    for i in 1...iterations {
        gen += 1
        guard let b = stressCreateBridge(gen: gen) else { hardFailures += 1; SM.end(); continue }
        guard stressConnect(b) else { hardFailures += 1; stressTeardown(b); continue }
        let delayMs = (i * 37) % 200           // deterministic scan across connect phases
        if delayMs > 0 { usleep(UInt32(delayMs) * 1000) }
        histogram[SM.snapshot().state, default: 0] += 1
        stressTeardown(b)                      // free joins the connect thread mid-flight
        if i % 10 == 0 || i == iterations {
            print("   B \(i)/\(iterations): anomalies \(SM.result().anomalies)")
        }
    }

    // -- Phase C: second-thread input/stats hammer racing the main-thread disconnect --
    print("-- phase C: concurrent input hammer across disconnect x\(iterations) --")
    for i in 1...iterations {
        gen += 1
        guard let b = stressCreateBridge(gen: gen) else { hardFailures += 1; SM.end(); continue }
        guard stressConnect(b) else { hardFailures += 1; stressTeardown(b); continue }
        stressWait(ms: 20_000) { let s = SM.snapshot(); return s.connected || s.terminal }
        guard SM.snapshot().connected else {
            noConnectC += 1
            rdpbridge_disconnect(b)
            stressWait(ms: 2_000) { SM.snapshot().terminal }
            stressTeardown(b)
            continue
        }
        connectsC += 1

        let box = BridgeBox(b), stop = StressFlag(), calls = StressCounter()
        let finished = DispatchSemaphore(value: 0)
        let hammer = Thread {
            var x: UInt16 = 5
            while !stop.isSet {
                rdpbridge_send_pointer(box.b, 0x0800, x, 10)          // PTR_FLAGS_MOVE
                rdpbridge_send_scancode(box.b, 0, 0x2A)               // LShift down (harmless)
                rdpbridge_send_scancode(box.b, 0x8000, 0x2A)          // KBD_FLAGS_RELEASE
                var cb: UInt64 = 0, fc: UInt64 = 0
                var rtt: UInt32 = 0, bw: UInt32 = 0
                rdpbridge_get_stats(box.b, &cb, &fc, &rtt, &bw)
                calls.add(4)
                x = (x == 5) ? 6 : 5
            }
            finished.signal()
        }
        hammer.start()
        usleep(100_000)                        // let the hammer overlap the live window
        rdpbridge_disconnect(b)                // teardown races the hammer under ctxLock
        stressWait(ms: 3_000) { SM.snapshot().terminal }
        usleep(100_000)                        // keep hammering into the post-disconnect gate
        stop.set()
        finished.wait()                        // hammer MUST stop before free (contract)
        hammerCalls += calls.value
        stressTeardown(b)
        if i % 10 == 0 || i == iterations {
            print("   C \(i)/\(iterations): connected \(connectsC), \(hammerCalls) racing calls, anomalies \(SM.result().anomalies)")
        }
    }

    // -- Summary --
    let r = SM.result()
    let hist = histogram.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    print("")
    print("== F-23 stress summary ==")
    print("phase A churn:       \(iterations) iterations, \(connectsA) reached connected, \(noConnectA) did not")
    print("phase B mid-connect: \(iterations) teardowns; phase at detach: \(hist.isEmpty ? "(none)" : hist)")
    print("phase C hammer:      \(iterations) iterations, \(connectsC) connected, \(noConnectC) did not, \(hammerCalls) input/stats calls under teardown race")
    print("hard failures (create / connect-thread start): \(hardFailures)")
    print("callback anomalies after detach: \(r.anomalies)")
    for n in r.notes { print("  anomaly: \(n)") }

    if r.anomalies == 0 && hardFailures == 0 && (connectsA + connectsC) > 0 {
        print("PASS: no crash, zero post-detach callbacks, ctxLock survived \(hammerCalls) racing calls")
        exit(0)
    } else if connectsA + connectsC == 0 {
        print("FAIL: no iteration ever reached connected — host unreachable? The live path was never exercised.")
        exit(1)
    } else {
        print("FAIL: anomalies=\(r.anomalies) hardFailures=\(hardFailures)")
        exit(1)
    }
}

if stressMode { runStress(iterations: stressIterations) }

// ============================================================================
// Default (non-stress) mode — the original clipboard-channel validation, unchanged.
// ============================================================================

var cbs = RDPBridgeCallbacks(onState: onState, onFrame: onFrame, onResize: onResize,
                             onCertVerify: onCert, onClipboard: onClip, onClipboardImage: nil,
                             onCursor: nil, onCursorHidden: nil, onCursorDefault: nil,
                             onClipboardFiles: nil, onFileContents: nil)
guard let bridge = rdpbridge_create(nil, cbs) else { print("FAIL: bridge create"); exit(1) }

print("== connecting to \(host):\(port) as \(user) ==")
let passwordBytes = Array(password.utf8)
let started = passwordBytes.withUnsafeBufferPointer {
    rdpbridge_connect(bridge, &cfg, $0.baseAddress, $0.count)
}
guard started == 1 else { print("FAIL: connect thread did not start"); exit(1) }

func snap() -> (conn: Bool, failed: Bool, name: String) {
    var r = (false, false, ""); S.set { r = (S.reachedConnected, S.failed, S.lastStateName) }; return r
}

// 1) Wait up to 25s for CONNECTED (or failure).
var waited = 0
while waited < 25_000 {
    let s = snap()
    if s.conn || s.failed { break }
    usleep(200_000); waited += 200
}
var st = snap()
if !st.conn {
    print("FAIL: never reached connected (last=\(st.name), \(S.failMsg))")
    rdpbridge_disconnect(bridge); usleep(500_000); rdpbridge_free(bridge); exit(1)
}
print("== connected; letting cliprdr handshake settle (caps + format list) ==")
usleep(3_000_000)

// 2) Exercise clipboard local->remote (sends a Client Format List).
let probe = "TouchRDP-live-clipboard-validation"
print("== setting local clipboard -> remote (\"\(probe)\") ==")
probe.withCString { rdpbridge_set_clipboard_text(bridge, $0) }

// 3) The original bug dropped the session ~immediately on clipboard exchange.
//    Hold the session and confirm it stays alive.
for _ in 0..<10 { // ~6s
    usleep(600_000)
    let s = snap()
    if s.failed || s.name.hasPrefix("disconnected") {
        print("FAIL: session dropped during clipboard activity (state=\(s.name), \(S.failMsg))")
        rdpbridge_free(bridge); exit(1)
    }
}

st = snap()
print("== final state: \(st.name) ==")
rdpbridge_disconnect(bridge)
usleep(800_000)
rdpbridge_free(bridge)

if st.conn && !st.failed && st.name == "connected" {
    print("PASS: session survived clipboard exchange (cliprdr did not reset the connection)")
    exit(0)
} else {
    print("FAIL: unexpected final state \(st.name)")
    exit(1)
}
