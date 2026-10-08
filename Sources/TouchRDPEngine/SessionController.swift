import Foundation
import CoreGraphics
import Combine
import os
import TouchRDPCore

/// Per-session/per-tab controller. Owns one RDPSession, implements its delegate,
/// drives auto-reconnect with backoff, and exposes observable state + the latest
/// frame for SwiftUI. Decoupled from the vault: callers supply a `passwordProvider`
/// async closure (which performs the Touch-ID-gated retrieval honoring policy), so
/// this controller never retains a plaintext secret.
@MainActor
public final class SessionController: ObservableObject, RDPSessionDelegate {

    // Observable UI state
    @Published public private(set) var state: ConnectionState = .idle
    // NOT @Published: frames arrive at video rates; publishing them would re-evaluate
    // the whole SwiftUI tree every frame. The canvas subscribes via `onFrame` and
    // pushes straight into its NSView layer instead. `currentFrame` is retained only
    // to seed a freshly (re)created canvas (and for screenshots via `makeCGImage()`).
    public private(set) var currentFrame: RemoteFrame?
    /// Direct, non-published frame sink for the canvas (main actor). Set by the view.
    public var onFrame: ((RemoteFrame) -> Void)?
    /// Latest remote cursor (retained to seed a freshly (re)created canvas).
    public private(set) var currentCursor: CursorUpdate = .arrow
    /// Direct, non-published cursor sink for the canvas (main actor). Set by the view.
    public var onCursor: ((CursorUpdate) -> Void)?
    // #22: ADDITIONAL keyed frame/cursor sinks for the per-display presentation, where
    // several canvases (one per display window) render crops of the same session
    // concurrently. The single `onFrame`/`onCursor` remain the unchanged single-canvas
    // path; these multicast alongside it. Keyed by a per-canvas token so a canvas can
    // unregister exactly its own sink on teardown.
    private var extraFrameSinks: [UUID: (RemoteFrame) -> Void] = [:]
    private var extraCursorSinks: [UUID: (CursorUpdate) -> Void] = [:]
    /// Register (or, with nil, remove) an additional frame sink for canvas `id`.
    public func setFrameSink(_ sink: ((RemoteFrame) -> Void)?, for id: UUID) {
        extraFrameSinks[id] = sink
    }
    /// Register (or, with nil, remove) an additional cursor sink for canvas `id`.
    public func setCursorSink(_ sink: ((CursorUpdate) -> Void)?, for id: UUID) {
        extraCursorSinks[id] = sink
    }
    @Published public private(set) var remoteSize: CGSize = .zero
    @Published public private(set) var statusMessage: String = ""
    // Live quality stats, refreshed ~1 Hz by `sampleStats()` while connected. `rttMs` and
    // `bandwidthKbps` are 0 when the server doesn't report network autodetect results.
    @Published public private(set) var fps: Double = 0
    @Published public private(set) var throughputKBps: Double = 0
    @Published public private(set) var rttMs: Int = 0
    @Published public private(set) var bandwidthKbps: Int = 0
    private var lastStatsTime: Date?
    private var lastFrameCount: UInt64 = 0
    private var lastCompressedBytes: UInt64 = 0
    /// Why a certificate needs the user's explicit decision. Both first-use and a
    /// changed cert are rejected inline (the verify callback can't block on UI) and
    /// surfaced here for an approve-and-reconnect flow. Nothing is pinned until the
    /// user approves — including first-use certs, which are NOT silently trusted.
    public enum CertReviewKind: Equatable, Sendable {
        case firstUse           // never seen this host before (TOFU) — review before trusting
        case hostMismatch       // first use AND the cert name does not match the host
        case changed            // differs from the previously pinned fingerprint
    }
    public struct PendingCertReview: Equatable, Sendable, Identifiable {
        public let info: CertInfo
        public let kind: CertReviewKind
        /// F-11: what was PREVIOUSLY pinned for this host (fingerprint always; subject/
        /// issuer/pinnedAt when the pin was written post-F-11), captured at review time
        /// so the `changed` sheet can show an old→new diff. Informational only — it
        /// never influences the accept/reject decision.
        public let previousPin: PinnedCertRecord?
        /// #32: bumped once per genuine raise (see `raiseCertReview`). The cert facts
        /// alone are NOT enough identity: re-raising the very same certificate after the
        /// sheet was dismissed handed SwiftUI an item it had just finished presenting,
        /// and `.sheet(item:)` could decline to present it a second time — which is what
        /// made "Review Certificate" look dead. The epoch guarantees each raise is a new
        /// presentation, while `raiseCertReview` suppresses same-cert re-assignments so
        /// a second verify callback within one connect can't churn a live sheet.
        public let epoch: Int

        init(info: CertInfo, kind: CertReviewKind, previousPin: PinnedCertRecord? = nil,
             epoch: Int = 0) {
            self.info = info; self.kind = kind; self.previousPin = previousPin
            self.epoch = epoch
        }
        public var id: String {
            "\(info.host):\(info.port):\(info.fingerprintSHA256):\(kind)#\(epoch)"
        }
        /// Identity of the certificate DECISION, ignoring the presentation epoch.
        func isSameReview(as other: PendingCertReview) -> Bool {
            info == other.info && kind == other.kind
        }
    }
    /// Set when a server certificate needs an explicit user decision (PRD §9.5).
    @Published public var pendingCertReview: PendingCertReview?
    /// #32: the last certificate the user was asked about and did not trust, kept after
    /// the sheet closes so `reviewLastCertificate()` can re-open it instantly. Cleared
    /// when it is pinned, when the session connects, and on a fresh `connect(_:)` (the
    /// connection — and therefore the host — may have been edited).
    public private(set) var lastRejectedCert: PendingCertReview?
    private var certReviewEpoch = 0
    private nonisolated static let certLog = Logger(subsystem: "com.touchrdp.app", category: "Cert")

    public let id = UUID()
    public private(set) var connection: Connection?

    // The FreeRDP bridge is single-use, so each connect attempt gets a fresh session
    // (see startConnect). `makeSession` is the factory; `session` is the current one.
    private let makeSession: () -> RDPSession
    private let checkReachability: (String, Int) async -> RDPError?
    private var session: RDPSession
    private var sessionUsed = false
    // A bridge attempt can report failure followed by disconnect during teardown.
    // Handle its terminal outcome only once, independently of the displayed state
    // (which may already have moved to a reconnect countdown).
    private var attemptFinished = false
    // #25: transfer engine for remote→Mac file paste. `nonisolated let` (an actor is
    // Sendable) so the RDP-thread FILECONTENTS forward and the promise coordinator can
    // reach it without touching main-actor state. Lives for the controller's lifetime;
    // (re)wired to the active session on every connect and deactivated on teardown.
    public nonisolated let filePuller = RemoteFilePuller()
    // #25: clipboard-generation counter for remote file announcements. Each server
    // FILE announcement mints a new generation; promises from an older generation fail
    // gracefully when fulfilled late (the descriptors they index are gone).
    private var remoteFileGeneration = 0
    // nonisolated: read synchronously from the RDP thread inside sessionVerifyCertificate.
    private nonisolated let trustStore: CertificateTrustStore
    // The active connection's certificate mode, copied here on every connect attempt
    // because the verify callback runs on the RDP thread and can't read `connection`.
    private nonisolated let certificatePolicyLock = OSAllocatedUnfairLock(initialState: CertificatePolicy())

    /// A connection's certificate mode and the endpoints it was chosen for. The relaxed
    /// modes cover only the host and gateway the user typed: a server redirect (session
    /// broker, load balancer) can make FreeRDP verify a certificate for a host the
    /// SERVER named, and trust-on-first-use pins are shared by every connection to
    /// that host:port — so anything else gets the normal review.
    struct CertificatePolicy: Sendable {
        var mode: CertificateCheckMode = .ask
        var endpoints: Set<String> = []

        init() {}
        init(_ connection: Connection) {
            mode = connection.certificateMode
            endpoints = [Self.key(connection.host, connection.port)]
            if let gw = connection.gateway, !gw.hostname.isEmpty {
                endpoints.insert(Self.key(gw.hostname, gw.port))
            }
        }

        func mode(for info: CertInfo) -> CertificateCheckMode {
            endpoints.contains(Self.key(info.host, info.port)) ? mode : .ask
        }

        private static func key(_ host: String, _ port: Int) -> String {
            "\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(port)"
        }
    }
    // F-6: the provider releases BOTH the primary and (when configured) the gateway
    // secret under one biometric authentication; the controller retains neither.
    private var passwordProvider: ((CredentialRequestReason) async throws -> ConnectionSecrets)?

    // Reconnect control
    private var userInitiatedDisconnect = false
    private var hasConnectedOnce = false   // only auto-reconnect a session that actually connected
    // F-24: the proactive (network-return) path has its own ONE-shot budget per drop
    // episode, separate from the blind-retry budget. Set when the shot is spent; cleared
    // only when a connection fully succeeds or the user manually reconnects — so a link
    // that flaps without ever connecting can never earn more proactive attempts (LIFE-4).
    private var proactiveAttemptUsedThisEpisode = false
    // When the current drop episode began (state left .connected / a connect failed).
    // Used to enforce the ≥5 s (policy) floor on proactive attempts too (LIFE-3).
    private var lastDropAt: Date?
    // LIFE-1/LIFE-2: the in-flight connect Task, tracked so it can be cancelled on
    // disconnect and so its result can be re-validated against a session swap/teardown.
    private var connectTask: Task<Void, Never>?

    // Auto/Dynamic mode derives the remote resolution + DPI from the local window:
    // `preferredLogicalSize` is the window content area in points, `backingScale` its
    // Retina factor. Captured at connect so the initial resolution matches what a
    // later window-resize produces (no jump/discrepancy).
    private var preferredLogicalSize: CGSize?
    private var backingScale: CGFloat = 1
    // Multi-monitor layout supplied by the app layer (from local screens). Used only
    // when the connection opts into useAllDisplays and there is more than one monitor.
    // #22: public read — the per-display window presenter needs the connect-time layout
    // (each MonitorDef is that display's pixel rect within the spanned framebuffer).
    public private(set) var monitors: [MonitorDef] = []
    private var reconnectAttempt = 0
    /// When the current session reached `.connected` (nil while not connected). A drop
    /// re-earns the automatic-reconnect budget only if the session stayed up at least
    /// `stableConnectionSeconds` — a link that connects and drops again within seconds
    /// must run the budget down, not reset it every cycle.
    private var connectedAt: Date?
    static let stableConnectionSeconds: TimeInterval = 60
    // F-20: the ACTIVE connection's reconnect policy (defaults preserve the old global
    // behavior: enabled, 1 attempt, 5 s floor). Bounds are clamped by the model.
    private var activePolicy: ReconnectPolicy { connection?.reconnectPolicy ?? .default }
    // 0a: public so the recovery UI (Cluster C) can show "Attempt N of M".
    /// Automatic reconnects after an unexpected drop are capped by the per-connection
    /// policy (default ONE attempt, ≤5; every attempt reuses the existing Touch ID after a
    /// ≥5 s delay). When the budget runs out, auto-retry stops and the failure overlay's
    /// manual "Reconnect" (which re-prompts) takes over — so a struggling server is never
    /// hammered. `max(…, reconnectAttempt)` keeps "Attempt N of M" truthful when the F-24
    /// proactive one-shot fires beyond the blind budget (UX-4).
    public var maxReconnectAttempts: Int {
        max(activePolicy.effectiveMaxAttempts, reconnectAttempt)
    }
    private var reconnectTask: Task<Void, Never>?

    // F-26 "Stay awake" — bounded remote-lock deferral. RUNTIME-ONLY state: always off
    // on a new connection and never persisted, so it can never silently re-enable
    // across reconnect/relaunch. Only the cap duration comes from the connection.
    /// Remaining stay-awake seconds, or nil when off. Published for the toolbar toggle
    /// (updated ~1 Hz by the countdown task, not per input event).
    @Published public private(set) var stayAwakeRemainingSeconds: Double?
    /// Absolute end of the current stay-awake window; re-armed to now+cap on real input.
    private var stayAwakeDeadline: Date?
    /// Last REAL user input (scancode/unicode/pointer/wheel passthrough — never the
    /// injected keep-alive). Gates injection so F15 is never spliced into live typing.
    private var lastUserInputAt: Date = .distantPast
    private var stayAwakeCountdownTask: Task<Void, Never>?
    private var stayAwakeTickTask: Task<Void, Never>?
    /// The per-connection cap (model-clamped 60...3600 s; 300 s default).
    public var stayAwakeCapSeconds: Double {
        connection?.stayAwakeCapSeconds ?? StayAwake.defaultCapSeconds
    }

    // 0a: stable, race-free open ordering for tab sorting (UX-7). The counter is
    // main-actor isolated (the whole type is @MainActor), so increments can't race.
    @MainActor private static var openSequenceCounter = 0
    /// Monotonic per-process open index, assigned at init. Cluster C sorts tabs by this
    /// so tab order follows open order and is stable across open/close.
    public let openSequence: Int = {
        defer { SessionController.openSequenceCounter += 1 }
        return SessionController.openSequenceCounter
    }()
    // Watches for network-path recovery and wake-from-sleep to retry a dropped session
    // immediately instead of waiting out the exponential backoff.
    private var reconnectMonitor: ReconnectMonitor?

    public convenience init(makeSession: @escaping () -> RDPSession, trustStore: CertificateTrustStore) {
        self.init(makeSession: makeSession, trustStore: trustStore, checkReachability: { host, port in
            await ReachabilityProbe.probe(host: host, port: port)?.asRDPError(host: host, port: port)
        })
    }

    // Internal injection keeps lifecycle tests independent of DNS, sockets and Touch ID.
    init(makeSession: @escaping () -> RDPSession, trustStore: CertificateTrustStore,
         checkReachability: @escaping (String, Int) async -> RDPError?) {
        self.makeSession = makeSession
        self.checkReachability = checkReachability
        self.trustStore = trustStore
        self.session = makeSession()
        self.session.delegate = self
    }

    public var freeRDPVersion: String { session.freeRDPVersion }
    /// PERF-8: the linked FreeRDP was built with VideoToolbox H.264 decoding.
    public var hardwareH264DecodeAvailable: Bool { session.hardwareH264DecodeAvailable }

    // MARK: Lifecycle

    /// Connect to `connection`. `passwordProvider` performs the biometric-gated
    /// retrieval (and may be re-invoked on auto-reconnect).
    public func connect(_ connection: Connection,
                        preferredLogicalSize: CGSize? = nil,
                        backingScale: CGFloat = 1,
                        monitors: [MonitorDef] = [],
                        passwordProvider: @escaping (CredentialRequestReason) async throws -> ConnectionSecrets) {
        self.connection = connection
        self.preferredLogicalSize = preferredLogicalSize
        self.backingScale = backingScale
        self.monitors = monitors
        self.passwordProvider = passwordProvider
        // #32: a new connect may target an edited (or entirely different) endpoint —
        // never offer a certificate captured for the previous one.
        self.pendingCertReview = nil
        self.lastRejectedCert = nil
        self.userInitiatedDisconnect = false
        self.hasConnectedOnce = false
        self.proactiveAttemptUsedThisEpisode = false   // manual connect resets the F-24 shot
        self.reconnectAttempt = 0
        startProactiveReconnectMonitorIfNeeded()
        startConnect(reason: .userInitiated)
    }

    private func startConnect(reason: CredentialRequestReason) {
        guard let connection, let passwordProvider else { return }
        attemptFinished = false
        // A usable account name is mandatory for every connection mode. In particular,
        // FreeRDP's NLA path turns an empty username into a nullptr identity, falls back
        // to its local SAM database, and finally misreports the result as a transport
        // failure. Stop synchronously, before the reachability probe, Touch ID, or an RDP
        // session starts. The recovery action opens the connection editor.
        let username = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            let message = "Enter a username and confirm the saved password before connecting."
            state = .failed(RDPError(code: 0, rawMessage: message,
                                     cause: .credentialsIncomplete))
            statusMessage = message
            return
        }
        // #32 defense-in-depth: every caller has decided to connect, so a stale
        // user-disconnect flag must never make the task below bail silently and strand
        // the UI on "Connecting…". Callers that mean it (retry/accept) clear it too.
        userInitiatedDisconnect = false
        let certificatePolicy = CertificatePolicy(connection)
        certificatePolicyLock.withLock { $0 = certificatePolicy }
        // The FreeRDP bridge is single-use: a second connect on the same session
        // no-ops (and would leave us stuck on "connecting"). Use a fresh session for
        // every attempt after the first.
        if sessionUsed {
            session.delegate = nil
            session.disconnect()
            session = makeSession()
        }
        session.delegate = self
        sessionUsed = true
        let activeSession = session
        // #25: point the puller at THIS session's thread-safe request entry points
        // (stale-session sends fail harmlessly in the bridge's connected gate).
        Task { [filePuller] in
            await filePuller.setSender(RemoteFilePuller.Sender(
                requestSize: { [weak activeSession] sid, idx in
                    activeSession?.requestFileSize(streamId: sid, listIndex: idx) ?? false
                },
                requestRange: { [weak activeSession] sid, idx, off, len in
                    activeSession?.requestFileRange(streamId: sid, listIndex: idx,
                                                    offset: off, length: len) ?? false
                }))
        }
        state = .connecting
        statusMessage = "Connecting to \(connection.host)…"
        // LIFE-1/LIFE-2: track the Task and re-validate after each await. The keychain /
        // LAContext reads aren't cancellation-aware, so the re-validation guard (not the
        // cancel) is the real protection against a zombie connection or a redundant prompt.
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            guard self.isConnectStillValid(activeSession) else { return }
            // Pre-flight reachability: TCP-probe the endpoint we actually dial (the
            // gateway when one is configured) BEFORE requesting credentials. A network
            // outage must report as unreachable — not as whatever fails first behind it
            // (e.g. a vault error blaming the saved password) — and must not cost a
            // Touch ID prompt.
            let (probeHost, probePort) = Self.dialEndpoint(for: connection)
            if let err = await self.checkReachability(probeHost, probePort) {
                guard self.isConnectStillValid(activeSession) else { return }
                self.sessionDidChangeState(.failed(err))
                return
            }
            guard self.isConnectStillValid(activeSession) else { return }
            do {
                let secrets = try await passwordProvider(reason)
                guard self.isConnectStillValid(activeSession) else { return }
                // Every connection must carry a complete credential pair. For NLA an
                // empty value becomes a misleading transport failure; for TLS/RDP it
                // would defer authentication to the Windows logon screen, contrary to
                // TouchRDP's saved-credential contract. Refuse it before FreeRDP starts.
                if secrets.primary.isEmpty {
                    throw VaultError.emptySecret
                }
                let cfg = self.makeConfig(for: connection)
                // connect consumes the secrets and does not retain them.
                activeSession.connect(config: cfg, password: secrets.primary,
                                      gatewayPassword: secrets.gateway)
            } catch is CancellationError {
                return
            } catch let e as VaultError {
                if self.isConnectStillValid(activeSession) { self.handleVaultError(e) }
            } catch {
                if self.isConnectStillValid(activeSession) {
                    self.sessionDidChangeState(.failed(RDPError(code: 0, rawMessage: "\(error)", cause: .unknown)))
                }
            }
        }
    }

    /// True only if the connect Task that produced a password should still proceed: not
    /// cancelled, not torn down by the user, and still targeting the current session.
    private func isConnectStillValid(_ s: RDPSession) -> Bool {
        !Task.isCancelled && !userInitiatedDisconnect && !attemptFinished && (session === s)
    }

    /// The TCP endpoint a connect actually dials first: the RD gateway when one is
    /// configured, else the host itself.
    private static func dialEndpoint(for connection: Connection) -> (host: String, port: Int) {
        if let gw = connection.gateway, !gw.hostname.isEmpty {
            return (gw.hostname, gw.port)
        }
        return (connection.host, connection.port)
    }

    /// Build the per-connect config. Fit/1:1 use the connection's chosen resolution and
    /// Zoom (DesktopScaleFactor). Auto/Dynamic sizes the resolution to the window
    /// (points × Retina scale when Retina is on, logical 1× otherwise) but keeps the
    /// connection's configured Zoom as the DPI — pinned, never derived from the local
    /// display. Deriving it from backingScale (the old behavior) re-seated the Windows
    /// session's DPI differently depending on which display the window happened to be
    /// on at connect (200 on Retina, 100 off), and any mismatch with the session's
    /// signed-in DPI makes Windows bitmap-rescale every frame — blur no client-side
    /// rendering can undo. One DPI for all modes and displays keeps the server crisp.
    private func makeConfig(for connection: Connection) -> RDPConnectionConfig {
        var cfg = RDPConnectionConfig(from: connection)

        // Multi-monitor: span the supplied local screens. The remote desktop is the
        // union bounding box of all monitors; DPI follows the primary. Takes precedence
        // over the single-monitor Auto/Fit/1:1 sizing below.
        if connection.display.useAllDisplays, monitors.count > 1 {
            cfg.monitors = monitors
            cfg.width = monitors.map { $0.x + $0.width }.max() ?? cfg.width
            cfg.height = monitors.map { $0.y + $0.height }.max() ?? cfg.height
            cfg.desktopScaleFactor = monitors.first(where: { $0.isPrimary })?.scaleFactor
                ?? monitors.first?.scaleFactor ?? 100
            return cfg
        }

        guard connection.display.scaleMode == .dynamic,
              let logical = preferredLogicalSize, logical.width > 1, logical.height > 1
        else { return cfg }

        func clampEven(_ v: CGFloat) -> Int {
            let c = min(max(Int(v.rounded()), 640), 8192)
            return c - (c % 2)   // RDP requires an even desktop dimension
        }
        let density: CGFloat = connection.display.useHiDPI ? backingScale : 1
        cfg.width = clampEven(logical.width * density)
        cfg.height = clampEven(logical.height * density)
        // cfg.desktopScaleFactor stays the connection's Zoom (RDPConnectionConfig(from:)).
        return cfg
    }

    public func disconnect() {
        userInitiatedDisconnect = true
        connectTask?.cancel()       // LIFE-2: stop a pending password retrieval
        connectTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        disarmStayAwake()           // F-26: stay-awake never survives a teardown
        // There may be no RDP thread yet (reachability or Touch ID is pending),
        // so teardown must not depend on a future bridge callback. Detach before
        // cancelling to keep already queued callbacks from reviving this attempt.
        session.delegate = nil
        session.disconnect()
        if case .failed = state {
            // Retain an actionable error (especially certificate review) when its
            // failed attempt is explicitly closed. Pending countdowns are cancelled.
        } else {
            attemptFinished = false
            sessionDidChangeState(.disconnected(reason: "Disconnected"))
        }
    }

    /// User-initiated re-attempt from a failed/disconnected recovery overlay (0a). Re-runs
    /// certificate verification, so a `.failed(.certificateRejected)` overlay's "Review
    /// certificate" simply calls this and the review sheet reappears.
    public func retry() {
        guard connection != nil, passwordProvider != nil else { return }
        userInitiatedDisconnect = false
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectAttempt = 0
        proactiveAttemptUsedThisEpisode = false   // user manually reconnected: new episode
        pendingCertReview = nil
        startConnect(reason: .userInitiated)
    }

    /// Reconnect delay for attempt `a`: exponential backoff (2^(a-1)) with a **≥5 s floor**
    /// (raised, never lowered, by the per-connection policy — F-20) and a
    /// `max(16, floor)` ceiling → 5,5,5,8,16 s by default. The floor avoids swamping an
    /// overloaded server on the first retry. Public so the reconnect overlay (Cluster C)
    /// can show a truthful countdown (0a / UX-4). Pure math lives in `ReconnectDecider`.
    public static func backoffDelaySeconds(forAttempt a: Int, minDelaySeconds: Double = 5) -> Double {
        ReconnectDecider.backoffDelaySeconds(forAttempt: a, minDelaySeconds: minDelaySeconds)
    }

    /// The delay the controller will actually use for attempt `a` of the ACTIVE
    /// connection (its policy floor applied). For the overlay countdown (UX-4).
    public func reconnectDelaySeconds(forAttempt a: Int) -> Double {
        Self.backoffDelaySeconds(forAttempt: a, minDelaySeconds: activePolicy.minDelaySeconds)
    }

    private func handleVaultError(_ e: VaultError) {
        let cause: RDPErrorCause
        switch e {
        case .userCancelled: cause = .cancelled
        case .biometricUnavailable, .authenticationFailed: cause = .authenticationFailed
        // Missing/unreadable saved secrets (including items stored by a differently-
        // signed build — ad-hoc re-signs orphan Tier-2 items) need a re-save, not a
        // retry and not a "code 0x0" mystery.
        default: cause = .credentialsUnavailable
        }
        let msg: String
        switch e {
        case .userCancelled:  msg = "Touch ID was cancelled."
        case .invalidated:    msg = "Your saved password needs to be re-stored (it was saved by a different build of TouchRDP, or your biometrics changed)."
        case .itemNotFound:   msg = "No saved password for this connection."
        case .emptySecret:    msg = "The saved password for this connection is empty, so nothing could be sent to the server. Re-save the password to continue."
        case .biometricUnavailable: msg = "Biometric authentication is unavailable."
        default:              msg = "Could not unlock the saved password."
        }
        sessionDidChangeState(.failed(RDPError(code: 0, rawMessage: msg, cause: cause)))
    }

    // MARK: Input passthrough

    public func sendPointer(buttons: PointerButtons, x: Int, y: Int, down: Bool, moved: Bool) {
        noteRealUserInput()
        session.sendPointer(buttonMask: buttons, x: x, y: y, down: down, moved: moved)
    }
    /// F-9: X1/X2 (back/forward) side buttons via the extended-mouse PDU.
    public func sendExtendedPointer(buttons: PointerButtons, x: Int, y: Int, down: Bool) {
        noteRealUserInput()
        session.sendExtendedPointer(buttonMask: buttons, x: x, y: y, down: down)
    }
    public func sendWheel(delta: Int, horizontal: Bool) {
        noteRealUserInput()
        session.sendWheel(delta: delta, horizontal: horizontal)
    }
    public func sendScancode(_ code: UInt16, down: Bool, extended: Bool) {
        noteRealUserInput()
        session.sendScancode(code, down: down, extended: extended)
    }
    public func sendUnicode(_ code: UInt16, down: Bool) {
        noteRealUserInput()
        session.sendUnicode(code, down: down)
    }
    public func sendCtrlAltDel() {
        noteRealUserInput()
        session.sendCtrlAltDel()
    }
    /// F-4: send a canned special-key sequence (Windows key, Alt-Tab, PrintScreen, …)
    /// from the Send Keys menu. Sequences are pre-ordered (downs first, ups in reverse).
    public func sendSpecialKeys(_ sequence: SpecialKeySequence) {
        sendKeyActions(sequence.actions)
    }
    /// F-4: tap F1–F12 on the remote (1-based; out-of-range is a no-op).
    public func sendFunctionKey(_ n: Int) {
        sendKeyActions(SpecialKeySequence.functionKey(n))
    }
    private func sendKeyActions(_ actions: [KeyAction]) {
        noteRealUserInput()   // Send-Keys menu actions are user-initiated input (F-26)
        for action in actions {
            if case let .scancode(code, extended) = action.kind {
                session.sendScancode(code, down: action.down, extended: extended)
            }
        }
    }

    // MARK: F-27 — type the vaulted password into the live session (lock screen)

    /// True while a password-typing run is in flight, so the UI can disable its control
    /// and never start two overlapping runs.
    @Published public private(set) var isTypingPassword = false

    /// Settle time between the SAS and the first character. The credential UI has to be
    /// drawn and focused before it will accept input.
    private static let typingSettleSeconds: Double = 0.9
    /// Per-key pacing. The Windows credential UI drops input sent faster than it can
    /// consume; the bridge clamps this to 100 ms.
    private static let typingPerKeyDelayMs: UInt32 = 12
    /// Main-block Return (RDP_SCANCODE_RETURN, non-extended), pressed after the secret
    /// to submit it.
    private static let returnScancode: UInt16 = 0x1C

    /// Shown when the run is abandoned because the session it was authorized against is
    /// gone or has been replaced. Deliberately one message for both: from the user's side
    /// the outcome is identical — nothing was typed, and the next attempt needs a fresh
    /// Touch ID anyway.
    private static let typingTargetLostMessage =
        "The session changed before the password could be typed — nothing was sent."

    /// True only while `s` is still THIS controller's live session. Identity, not just
    /// state: an auto-reconnect swaps `session` for a new object while `state` returns to
    /// `.connected`, and a secret authorized for the old session must never be typed into
    /// the new one.
    private func isStillTargeting(_ s: RDPSession) -> Bool {
        guard case .connected = state else { return false }
        return session === s
    }

    /// F-27. Send the SAS, wait for the credential UI, then TYPE the vaulted password as
    /// Unicode key events. Deliberately **does not press Return** — the user confirms the
    /// characters landed in the password field and presses it themselves. That keeps a
    /// human at the one point where the client's model of the remote screen could be
    /// wrong (nothing in RDP reports lock state; see docs/SECURITY.md).
    ///
    /// Callers must gate this on `connection.passwordTypingEnabled` AND an explicit user
    /// action. The credential fetch always forces a fresh biometric prompt
    /// (`CredentialRequestReason.inSessionTyping`), which doubles as the confirmation step.
    public func typePasswordIntoSession() {
        guard !isTypingPassword,
              case .connected = state,
              connection?.passwordTypingEnabled == true,
              let passwordProvider else { return }

        isTypingPassword = true
        statusMessage = "Waiting for Touch ID…"
        // Pin the session this run targets. Connection STATE alone is not enough: a drop
        // plus auto-reconnect during the Touch ID prompt or the settle wait replaces
        // `session` with a NEW, freshly NLA-authenticated one sitting at the desktop, and
        // `state` is `.connected` again by the time we look. Typing then puts the password
        // on the desktop instead of a lock screen. The connect path pins the same way —
        // see `isConnectStillValid`.
        let target = session

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTypingPassword = false }
            do {
                // Fresh biometric every time — never a reuse window for this path.
                let secrets = try await passwordProvider(.inSessionTyping)
                guard self.isStillTargeting(target) else {
                    self.statusMessage = Self.typingTargetLostMessage
                    return
                }
                // The SAS raises the credential UI on a locked session; on an unlocked
                // one it raises the security-options screen, which has no text field for
                // the characters to land in.
                self.sendCtrlAltDel()
                self.statusMessage = "Typing password…"
                try? await Task.sleep(nanoseconds: UInt64(Self.typingSettleSeconds * 1_000_000_000))
                guard self.isStillTargeting(target) else {
                    self.statusMessage = Self.typingTargetLostMessage
                    return
                }

                // typeSecret paces the keystrokes and BLOCKS, so it must not run on the
                // main actor — a detached task keeps the UI (and this session's input)
                // responsive for the length of the secret. It runs against the PINNED
                // session, never `self.session`, which may have moved on.
                let session = target
                let password = secrets.primary
                let delay = Self.typingPerKeyDelayMs
                let ok = await Task.detached(priority: .userInitiated) {
                    session.typeSecret(password, perKeyDelayMs: delay)
                }.value

                guard ok else {
                    self.statusMessage = "Couldn't type the password — the session is no longer connected."
                    return
                }

                // Submit with Return. Re-check the target first: a session swapped while
                // the secret was being typed must never receive the submit.
                guard self.isStillTargeting(target) else {
                    self.statusMessage = Self.typingTargetLostMessage
                    return
                }
                target.sendScancode(Self.returnScancode, down: true, extended: false)
                target.sendScancode(Self.returnScancode, down: false, extended: false)
                self.statusMessage = "Password typed and submitted."
            } catch {
                // A cancelled Touch ID is a normal outcome, not an error to shout about.
                if let vaultError = error as? VaultError, vaultError == .userCancelled {
                    self.statusMessage = "Connected"
                } else {
                    self.statusMessage = "Couldn't unlock the password: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Stay awake (F-26 — bounded remote-lock deferral)

    /// Toggle the per-SESSION stay-awake control. Arms only while connected; always
    /// starts off for a new connection (the state is never persisted — see model docs).
    public func toggleStayAwake() {
        if stayAwakeRemainingSeconds != nil {
            disarmStayAwake(note: "Stay awake off.")
        } else if case .connected = state {
            armStayAwake()
        }
    }

    private func armStayAwake() {
        let cap = stayAwakeCapSeconds
        stayAwakeDeadline = Date().addingTimeInterval(cap)
        stayAwakeRemainingSeconds = cap
        statusMessage = "Stay awake on — up to \(Int(cap / 60)) min without activity."

        // ~1 Hz UI countdown; also enforces cap expiry (auto-off, unobtrusive note).
        stayAwakeCountdownTask?.cancel()
        stayAwakeCountdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard let deadline = self.stayAwakeDeadline else { return }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    self.disarmStayAwake(note: "Stay awake ended — the remote can lock normally now.")
                    return
                }
                // Publish only whole-second changes so real input (which moves the
                // deadline, not this property) can't spam SwiftUI at pointer rates.
                let rounded = remaining.rounded(.up)
                if self.stayAwakeRemainingSeconds != rounded {
                    self.stayAwakeRemainingSeconds = rounded
                }
            }
        }

        // Keep-alive tick: every 45 s, inject the no-op F15 ONLY if armed with time
        // remaining, connected, and the user has been idle >= the interval (never
        // spliced into live typing). The decision is pure logic in StayAwake so
        // ValidateCore asserts its truth table.
        stayAwakeTickTask?.cancel()
        stayAwakeTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(StayAwake.tickIntervalSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                var connected = false
                if case .connected = self.state { connected = true }
                let shouldInject = StayAwake.shouldInjectKeepAlive(
                    armed: self.stayAwakeDeadline != nil,
                    remainingSeconds: self.stayAwakeDeadline?.timeIntervalSinceNow ?? 0,
                    connected: connected,
                    secondsSinceRealInput: Date().timeIntervalSince(self.lastUserInputAt))
                // sendKeepAlive goes straight to the session — NOT through the input
                // passthroughs — so the injection never counts as real user activity.
                if shouldInject { self.session.sendKeepAlive() }
            }
        }
    }

    /// Turn stay-awake off (user toggle, cap expiry, disconnect, or session end).
    private func disarmStayAwake(note: String? = nil) {
        let wasArmed = stayAwakeRemainingSeconds != nil || stayAwakeDeadline != nil
        stayAwakeCountdownTask?.cancel(); stayAwakeCountdownTask = nil
        stayAwakeTickTask?.cancel(); stayAwakeTickTask = nil
        stayAwakeDeadline = nil
        stayAwakeRemainingSeconds = nil
        if wasArmed, let note { statusMessage = note }
    }

    /// Every REAL user input (never the injected keep-alive) lands here: it gates the
    /// injection idle check and, while armed, re-arms the cap to the full duration.
    private func noteRealUserInput() {
        lastUserInputAt = Date()
        if stayAwakeDeadline != nil {
            // Move the deadline only; the 1 Hz countdown publishes the change, so
            // pointer-rate input can't trigger per-event SwiftUI invalidation.
            stayAwakeDeadline = Date().addingTimeInterval(stayAwakeCapSeconds)
        }
    }
    public func sendKeyboardSync(capsLock: Bool, numLock: Bool, scrollLock: Bool) {
        session.sendKeyboardSync(capsLock: capsLock, numLock: numLock, scrollLock: scrollLock)
    }
    public func requestResize(width: Int, height: Int, scalePercent: Int = 0) {
        session.requestResize(width: width, height: height, scalePercent: scalePercent)
    }
    public func setClipboardText(_ text: String) { session.setClipboardText(text) }
    public func setClipboardImage(_ image: CGImage) { session.setClipboardImage(image) }

    // MARK: File offer (F-8, Mac→Windows)

    /// Outcome of an offer attempt, for the session HUD. `notes` carries per-file
    /// rejections and/or the whole-offer block reason.
    public struct FileOfferOutcome: Equatable, Sendable {
        public let offeredCount: Int
        public let totalBytes: UInt64
        public let notes: [String]
    }

    /// F-8: validate the dropped/copied `urls` and stage a Mac→Windows file offer on
    /// the remote clipboard. Returns nil when the feature isn't active (toggle off or
    /// not connected); otherwise an outcome for the HUD. Eligibility uses lstat
    /// semantics (`attributesOfItem` does NOT follow symlinks), so a symlink is
    /// rejected as itself — never resolved into its target.
    public func offerFiles(urls: [URL]) -> FileOfferOutcome? {
        guard case .connected = state, let conn = connection,
              conn.clipboardEnabled, conn.fileClipboardEnabled else { return nil }

        let fm = FileManager.default
        var candidates: [FileClipboardOffer.Candidate] = []
        for url in urls where url.isFileURL {
            let path = url.path
            let name = url.lastPathComponent
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let type = attrs[.type] as? FileAttributeType else {
                candidates.append(.init(path: path, name: name, size: 0,
                                        isRegularFile: false, isSymlink: false))
                continue
            }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            candidates.append(.init(path: path, name: name, size: size,
                                    isRegularFile: type == .typeRegular,
                                    isSymlink: type == .typeSymbolicLink))
        }

        let result = FileClipboardOffer.validate(candidates)
        if let blocked = result.offerBlocked {
            statusMessage = blocked
            return FileOfferOutcome(offeredCount: 0, totalBytes: 0,
                                    notes: [blocked] + result.rejections)
        }
        guard !result.staged.isEmpty else {
            let notes = result.rejections.isEmpty ? ["No files to offer."] : result.rejections
            return FileOfferOutcome(offeredCount: 0, totalBytes: 0, notes: notes)
        }
        guard session.offerFiles(result.staged) else {
            let note = "Couldn’t stage the files for the remote clipboard."
            statusMessage = note
            return FileOfferOutcome(offeredCount: 0, totalBytes: 0,
                                    notes: [note] + result.rejections)
        }
        let mb = Double(result.totalBytes) / (1024 * 1024)
        statusMessage = String(format: "Offering %d file%@ to remote clipboard (%.1f MB)",
                               result.staged.count, result.staged.count == 1 ? "" : "s", mb)
        return FileOfferOutcome(offeredCount: result.staged.count,
                                totalBytes: result.totalBytes,
                                notes: result.rejections)
    }

    // MARK: Quality stats

    /// Sample the bridge's counters and derive FPS + throughput over the elapsed interval.
    /// Call ~1 Hz from the UI while connected. The first call only seeds the baseline.
    public func sampleStats() {
        let snap = session.currentStats()
        let now = Date()
        // PERF-6: assign only on change. Each of these is @Published, and everything
        // observing the controller (the whole SessionView body + toolbar, the sidebar
        // tab row, detached windows) re-evaluates on every publish — four unconditional
        // writes a second kept an idle session doing SwiftUI work at 1 Hz for nothing.
        let newRTT = Int(snap.rttMs)
        if rttMs != newRTT { rttMs = newRTT }
        let newBW = Int(snap.bandwidthKbps)
        if bandwidthKbps != newBW { bandwidthKbps = newBW }
        if let last = lastStatsTime {
            let dt = now.timeIntervalSince(last)
            if dt > 0.2 {
                // Counters are monotonic; a decrease means the bridge was recreated
                // (reconnect) — treat as 0 for this interval rather than a huge spike.
                let dFrames = snap.frameCount >= lastFrameCount ? Double(snap.frameCount - lastFrameCount) : 0
                let dBytes = snap.compressedBytes >= lastCompressedBytes ? Double(snap.compressedBytes - lastCompressedBytes) : 0
                // Quantise to what the HUD can show (whole fps, 0.1 KB/s) so jitter in
                // the sampling interval doesn't publish a visually identical value.
                let newFPS = (dFrames / dt).rounded()
                if fps != newFPS { fps = newFPS }
                let newKBps = (dBytes / 1024.0 / dt * 10).rounded() / 10
                if throughputKBps != newKBps { throughputKBps = newKBps }
            }
        }
        lastStatsTime = now
        lastFrameCount = snap.frameCount
        lastCompressedBytes = snap.compressedBytes
    }

    private func resetStats() {
        fps = 0; throughputKBps = 0; rttMs = 0; bandwidthKbps = 0
        lastStatsTime = nil; lastFrameCount = 0; lastCompressedBytes = 0
    }

    /// #32: the single place a certificate review is raised. Re-assigning the same
    /// review while its sheet is up would only churn the presentation, so that case is
    /// dropped; every other raise gets a fresh epoch (a new `id`) so SwiftUI always
    /// treats it as a new presentation — including a re-review of a cert whose sheet the
    /// user just dismissed.
    private func raiseCertReview(info: CertInfo, kind: CertReviewKind,
                                 previousPin: PinnedCertRecord? = nil) {
        let candidate = PendingCertReview(info: info, kind: kind, previousPin: previousPin)
        if let current = pendingCertReview, current.isSameReview(as: candidate) {
            Self.certLog.notice("raise: same review already pending (epoch \(current.epoch)) — no-op")
            return
        }
        certReviewEpoch += 1
        Self.certLog.notice("raise: \(String(describing: kind)) for \(info.host):\(info.port) epoch \(self.certReviewEpoch) state=\(String(describing: self.state))")
        let review = PendingCertReview(info: info, kind: kind, previousPin: previousPin,
                                       epoch: certReviewEpoch)
        pendingCertReview = review
        lastRejectedCert = review
    }

    /// #32: "Review Certificate" on the `.certificateRejected` failure overlay.
    ///
    /// The certificate is already known — it was captured when the handshake rejected
    /// it — so re-open the sheet directly. The old behavior ran a whole fresh connect
    /// (Touch ID prompt, reachability probe, TLS handshake) and relied on the verify
    /// callback re-raising the sheet, so any hiccup anywhere in that chain left the
    /// button doing visibly nothing. Only when nothing is remembered (e.g. the failure
    /// was classified from a FreeRDP message rather than our own callback) does this
    /// fall back to re-running the connect to obtain the certificate.
    public func reviewLastCertificate() {
        // Guard against a cert remembered for a host the connection no longer points at.
        if let last = lastRejectedCert, let connection,
           last.info.host == connection.host, last.info.port == connection.port {
            Self.certLog.notice("review: re-opening remembered cert for \(last.info.host)")
            raiseCertReview(info: last.info, kind: last.kind, previousPin: last.previousPin)
            return
        }
        Self.certLog.notice("review: nothing remembered (last=\(self.lastRejectedCert?.info.host ?? "nil") conn=\(self.connection?.host ?? "nil")) — falling back to retry")
        retry()
    }

    /// User reviewed and accepted the pending certificate (first-use, host mismatch, or
    /// changed): pin it and reconnect. Apart from a connection the user set to trust
    /// on first use, and a certificate they imported in the editor, this is the only
    /// path that pins a cert.
    public func acceptPendingCertAndReconnect() {
        guard let review = pendingCertReview else { return }
        Self.certLog.notice("accept: pinning \(review.info.host):\(review.info.port)")
        trustStore.pin(review.info)
        pendingCertReview = nil
        lastRejectedCert = nil   // #32: trusted now — nothing left to review
        // #32: Cancel → Review Certificate → Trust & Connect. The Cancel went through
        // `disconnect()`, which raised `userInitiatedDisconnect`; the re-review no longer
        // passes through `retry()` (which cleared it), so without this the connect task
        // below silently bails at its first re-validation and the UI sits on
        // "Connecting…" forever. An explicit trust-and-connect is the opposite of a
        // user disconnect.
        userInitiatedDisconnect = false
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectAttempt = 0
        proactiveAttemptUsedThisEpisode = false   // explicit user action: new episode
        startConnect(reason: .userInitiated)
    }

    /// User declined the pending certificate (or dismissed the review sheet): clear the
    /// pending review and tear down the attempt. Nothing is pinned; the cert stays untrusted.
    /// #32: `lastRejectedCert` deliberately SURVIVES a decline — dismissing the sheet is
    /// exactly the case where the user then reaches for "Review Certificate" again.
    public func declinePendingCert() {
        Self.certLog.notice("decline: \(self.pendingCertReview?.info.host ?? "nil")")
        pendingCertReview = nil
        // The sheet can be declined before the bridge's failure callback reaches
        // the main queue. Keep the certificate recovery action available even then.
        if lastRejectedCert != nil, !attemptFinished {
            sessionDidChangeState(.failed(RDPError(code: RDPError.bridgeCertRejectedCode,
                                                   rawMessage: "Server certificate rejected",
                                                   cause: .certificateRejected)))
        }
        disconnect()
    }

    // MARK: RDPSessionDelegate (main thread, except certificate verify)

    public func sessionDidChangeState(_ newState: ConnectionState) {
        guard !attemptFinished else { return }
        switch newState {
        case .failed, .disconnected: attemptFinished = true
        default: break
        }
        self.state = newState
        // Stats are only meaningful while connected; clear them (and the sampling baseline)
        // on every other state so a reconnect doesn't show stale numbers or a spike.
        // F-26: stay-awake is per-SESSION runtime state — any departure from .connected
        // (drop, reconnect, failure) turns it off; it never re-arms silently.
        if case .connected = newState {} else {
            resetStats()
            disarmStayAwake()
            // #25: the remote file announcement dies with the session — fail any
            // in-flight promise pulls instead of letting them wait out the timeout.
            Task { [filePuller] in await filePuller.deactivate() }
            // The remote pointer shape dies with the session too. Windows routinely
            // sends "hide pointer" (typing, video, lock screen) and often does so right
            // as the link drops — without this reset the canvas keeps applying the
            // transparent cursor over the disconnect/reconnect overlay, leaving the user
            // unable to see where the mouse is to click Reconnect or Disconnect.
            resetCursorToArrow()
        }
        switch newState {
        case .connected:
            hasConnectedOnce = true
            // LIFE-4/F-24: the blind budget and the proactive one-shot are re-earned at
            // the next drop, and only if this connection proved stable (see connectedAt).
            connectedAt = Date()
            lastRejectedCert = nil   // #32: the link is up — nothing left to review
            statusMessage = "Connected"
        case .failed(let err):
            lastDropAt = Date()   // episode timing for the proactive ≥5 s floor (LIFE-3)
            reEarnReconnectBudgetIfStable()
            statusMessage = err.humanMessage
            scheduleReconnectIfAppropriate()
        case .disconnected(let reason):
            lastDropAt = Date()
            reEarnReconnectBudgetIfStable()
            statusMessage = reason ?? "Disconnected"
            scheduleReconnectIfAppropriate()
        case .connecting:    statusMessage = "Connecting…"
        case .authenticating: statusMessage = "Authenticating…"
        case .negotiating:   statusMessage = "Negotiating…"
        case .reconnecting(let n): statusMessage = "Reconnecting (attempt \(n))…"
        case .idle: break
        }
    }

    public func sessionDidRenderFrame(_ frame: RemoteFrame) {
        self.currentFrame = frame
        // Push directly to the canvas — bypasses SwiftUI invalidation entirely.
        self.onFrame?(frame)
        // #22: fan out to the per-display canvases (each crops its own viewport).
        for sink in extraFrameSinks.values { sink(frame) }
    }

    public func sessionDidResize(to size: CGSize) {
        self.remoteSize = size
    }

    public func sessionDidUpdateCursor(_ update: CursorUpdate) {
        self.currentCursor = update
        self.onCursor?(update)
        // #22: fan out to the per-display canvases.
        for sink in extraCursorSinks.values { sink(update) }
    }

    /// Restore the default pointer everywhere the remote cursor is mirrored. Called on
    /// every departure from `.connected` so a stale remote shape (in particular the
    /// remote "hide pointer" state) can never outlive the session it belongs to.
    private func resetCursorToArrow() {
        guard !isArrow(currentCursor) else { return }
        sessionDidUpdateCursor(.arrow)
    }

    private func isArrow(_ update: CursorUpdate) -> Bool {
        if case .arrow = update { return true }
        return false
    }

    /// #22: surface a UI-layer presentation note (e.g. the per-display window fallback)
    /// on the session status line. Presentation-only — never touches session state.
    public func noteUIStatus(_ message: String) {
        statusMessage = message
    }

    // SYNCHRONOUS, on the RDP thread — must be fast + non-blocking (no modal). It can
    // only return a yes/no, so anything needing user input is REJECTED here and surfaced
    // via `pendingCertReview` for an explicit approve-and-reconnect flow.
    public nonisolated func sessionVerifyCertificate(_ info: CertInfo) -> Bool {
        let mode = certificatePolicyLock.withLock { $0 }.mode(for: info)
        if mode == .ignore {
            // The user chose "Don't verify" for this connection: accept without
            // consulting or touching the trust store, so turning the mode off later
            // brings back exactly the pins that were there before.
            Self.certLog.notice("verify: \(info.host):\(info.port) accepted unverified (mode=ignore)")
            return true
        }
        let decision = trustStore.evaluate(info)
        Self.certLog.notice("verify: \(info.host):\(info.port) fp=\(info.fingerprintSHA256.prefix(11))… mismatch=\(info.hostMismatch) mode=\(mode.rawValue) -> \(String(describing: decision))")
        switch decision {
        case .trusted:
            // Already pinned by an earlier explicit approval. Honor it.
            return true
        case .unknown where mode == .trustFirstUse:
            // The user opted into automatic trust-on-first-use for this connection:
            // remember this certificate so that any later CHANGE still stops for
            // review. A name mismatch is accepted too — connecting by IP address to a
            // self-signed Windows certificate always mismatches, and prompting for it
            // would defeat the mode. The pin is written here, on the RDP thread; the
            // store is lock-guarded and does its file write outside the lock.
            trustStore.pin(info)
            return true
        case .unknown:
            // First use (TOFU): do NOT silently pin/accept. Require explicit review so a
            // first-connection MITM isn't trusted automatically. A name mismatch is called
            // out distinctly so the user sees it before deciding.
            let kind: CertReviewKind = info.hostMismatch ? .hostMismatch : .firstUse
            Task { @MainActor [weak self] in self?.raiseCertReview(info: info, kind: kind) }
            return false
        case .changed:
            // Reject and ask the user to explicitly approve the new certificate. F-11:
            // capture the previously pinned record NOW (before any re-pin) so the review
            // sheet can diff old→new. Lock-guarded read; safe on the RDP thread.
            let previous = trustStore.pinnedRecord(host: info.host, port: info.port)
            Task { @MainActor [weak self] in
                self?.raiseCertReview(info: info, kind: .changed, previousPin: previous)
            }
            return false
        }
    }

    public func sessionClipboardTextChanged(_ text: String) {
        // #25: a new remote TEXT copy supersedes any file announcement — outstanding
        // un-fulfilled promises fail gracefully rather than pulling a dead list.
        Task { [filePuller] in await filePuller.deactivate() }
        // Forwarded to the system pasteboard by the app layer if desired.
        NotificationCenter.default.post(name: .touchRDPRemoteClipboard, object: self,
                                        userInfo: [Self.clipboardPayloadKey: text])
    }

    public func sessionClipboardImageChanged(_ image: CGImage) {
        // #25: a new remote IMAGE copy supersedes any file announcement (see text above).
        Task { [filePuller] in await filePuller.deactivate() }
        // Forwarded to the system pasteboard by the app layer (gated on the per-connection
        // image-clipboard toggle + focus there).
        NotificationCenter.default.post(name: .touchRDPRemoteClipboardImage, object: self,
                                        userInfo: [Self.clipboardPayloadKey: image])
    }

    /// #25: the remote clipboard holds files. Parse + sanitize the server-controlled
    /// FILEGROUPDESCRIPTORW blob HERE (structurally invalid blobs die quietly), mint a
    /// new clipboard generation, arm the puller for it, and only then announce to the
    /// app layer — so a promise can never race ahead of its own generation.
    public func sessionClipboardFilesChanged(_ descriptorBlob: Data) {
        guard let descriptors = RemoteFileClipboard.parse(descriptorBlob),
              !descriptors.isEmpty else { return }
        remoteFileGeneration += 1
        let announcement = RemoteFileAnnouncement(descriptors: descriptors,
                                                  generation: remoteFileGeneration)
        let activeSession = session
        Task { @MainActor [weak self, filePuller] in
            guard let self, self.session === activeSession, !self.attemptFinished,
                  self.remoteFileGeneration == announcement.generation else { return }
            await filePuller.activate(generation: announcement.generation)
            guard self.session === activeSession, !self.attemptFinished,
                  self.remoteFileGeneration == announcement.generation else { return }
            NotificationCenter.default.post(name: .touchRDPRemoteClipboardFiles,
                                            object: self,
                                            userInfo: [Self.clipboardPayloadKey: announcement])
        }
    }

    public static let clipboardPayloadKey = "payload"

    /// Resolve a clipboard event only for the session that produced it. Views may
    /// coexist in detached windows; a file descriptor must never use another
    /// controller's puller, even when their generation counters happen to match.
    public func clipboardPayload<T>(from notification: Notification, as type: T.Type) -> T? {
        guard let source = notification.object as? SessionController, source === self else { return nil }
        return notification.userInfo?[Self.clipboardPayloadKey] as? T
    }

    /// #25: FILECONTENTS response, straight off the RDP thread — route to the puller
    /// actor (no main-actor state is touched; ordering doesn't matter because the
    /// puller keeps at most ONE request in flight and matches by streamId).
    public nonisolated func sessionFileContentsResponse(streamId: UInt32, success: Bool,
                                                        data: Data) {
        Task { [filePuller] in
            await filePuller.handleResponse(streamId: streamId, success: success, data: data)
        }
    }

    // MARK: Reconnect (exponential backoff)

    private func scheduleReconnectIfAppropriate() {
        // Only auto-reconnect a session that actually connected (i.e. a dropped session).
        // An INITIAL connect failure shows the error and waits for the user — no loop, no
        // repeated Touch ID prompts. A pending cert review is never auto-retried (LIFE-5).
        guard !userInitiatedDisconnect,
              connection != nil,
              hasConnectedOnce,
              pendingCertReview == nil
        else { return }

        // This backoff path counts up per drop-retry cycle (a real reconnect resets the
        // budget via the .connected handler), so it does NOT re-earn here.
        // F-20: the budget is the ACTIVE connection's policy (0 == disabled => stop).
        let decision = ReconnectDecider().decide(
            attempt: reconnectAttempt,
            max: activePolicy.effectiveMaxAttempts,
            connectedSinceReset: false,
            cause: failureCause(),
            pendingCert: pendingCertReview != nil)
        guard case let .retryNow(attempt) = decision else { return }

        reconnectAttempt = attempt
        // F-20: the policy may RAISE the delay floor above 5 s, never lower it (LIFE-3).
        let delaySeconds = Self.backoffDelaySeconds(forAttempt: attempt,
                                                    minDelaySeconds: activePolicy.minDelaySeconds)
        state = .reconnecting(attempt: attempt)
        statusMessage = "Reconnecting (attempt \(attempt)) in \(Int(delaySeconds))s…"
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.startConnect(reason: .automaticReconnect)
        }
    }

    /// Called once per drop. A session that stayed up long enough starts a fresh
    /// episode (full blind budget + proactive one-shot); a short-lived one keeps counting,
    /// so connect → drop → connect cycles end when the policy's attempts run out.
    private func reEarnReconnectBudgetIfStable() {
        if let at = connectedAt, Date().timeIntervalSince(at) >= Self.stableConnectionSeconds {
            reconnectAttempt = 0
            proactiveAttemptUsedThisEpisode = false
        }
        connectedAt = nil
    }

    /// The failure cause of the current state, or nil for a plain network disconnect.
    private func failureCause() -> RDPErrorCause? {
        if case .failed(let err) = state { return err.cause }
        return nil
    }

    // MARK: Proactive reconnect (network recovery / wake from sleep)

    // Rate-limits proactive reconnects so a flapping network / repeated wake events can't
    // spawn an unbounded retry (and Touch ID prompt) storm.
    private var lastProactiveReconnect: Date?
    private let proactiveReconnectDebounce: TimeInterval = 10

    private func startProactiveReconnectMonitorIfNeeded() {
        guard reconnectMonitor == nil else { return }
        let monitor = ReconnectMonitor { [weak self] in
            // Hop to the main actor explicitly (don't assume the caller's thread).
            Task { @MainActor in self?.attemptProactiveReconnect() }
        }
        reconnectMonitor = monitor
        monitor.start()
    }

    /// The network came back or the Mac woke. If this session is dropped (and the drop
    /// wasn't user-initiated or a non-retryable auth/cert failure), retry NOW rather than
    /// waiting out the backoff. A healthy/connecting session is left untouched.
    private func attemptProactiveReconnect() {
        // LIFE-5 defense-in-depth: never proactively reconnect while a cert review is pending.
        guard !userInitiatedDisconnect, connection != nil, hasConnectedOnce,
              pendingCertReview == nil else { return }
        // Debounce: ignore triggers that arrive in quick succession.
        let now = Date()
        if let last = lastProactiveReconnect, now.timeIntervalSince(last) < proactiveReconnectDebounce {
            return
        }
        switch state {
        case .reconnecting:
            // Already waiting out a backoff — fire the ALREADY-BUDGETED blind attempt
            // early instead of waiting out the full exponential delay. Keeps the attempt
            // count (consumes the blind budget, not the F-24 one-shot), and still honors
            // the policy's ≥5 s floor measured from the drop (LIFE-3).
            lastProactiveReconnect = now
            reconnectTask?.cancel(); reconnectTask = nil
            statusMessage = "Network changed — reconnecting…"
            startAutomaticConnectAfterPolicyFloor()
        case .failed, .disconnected:
            // Terminal — the blind budget is exhausted (or the cause stopped it). F-24:
            // a genuine network-return event has its own ONE-shot budget per drop
            // episode, spent here and re-earned only by a real connection or a manual
            // reconnect (LIFE-4: a flapping link can never mint extra attempts/prompts).
            lastProactiveReconnect = now
            let decision = ReconnectDecider().decideProactive(
                proactiveUsedThisEpisode: proactiveAttemptUsedThisEpisode,
                policyMaxAttempts: activePolicy.effectiveMaxAttempts,
                cause: failureCause(),
                pendingCert: pendingCertReview != nil)
            guard decision == .retry else {
                if proactiveAttemptUsedThisEpisode {
                    statusMessage = "Couldn't reconnect automatically — use Reconnect to retry."
                }
                return
            }
            proactiveAttemptUsedThisEpisode = true
            reconnectAttempt += 1   // truthful "Attempt N" (maxReconnectAttempts tracks it)
            reconnectTask?.cancel(); reconnectTask = nil
            state = .reconnecting(attempt: reconnectAttempt)
            statusMessage = "Network changed — reconnecting…"
            startAutomaticConnectAfterPolicyFloor()
        default:
            return   // connected / connecting / negotiating — don't disturb it
        }
    }

    /// Start an automatic reconnect, waiting out whatever remains of the policy's minimum
    /// delay since the drop (≥5 s floor — LIFE-3). If the floor already elapsed while the
    /// session sat disconnected, this connects immediately.
    private func startAutomaticConnectAfterPolicyFloor() {
        let floor = max(5.0, activePolicy.minDelaySeconds)
        let elapsed = lastDropAt.map { Date().timeIntervalSince($0) } ?? 0
        let wait = max(0, floor - elapsed)
        guard wait > 0 else {
            startConnect(reason: .automaticReconnect)
            return
        }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.startConnect(reason: .automaticReconnect)
        }
    }

    deinit { reconnectMonitor?.stop() }
}

public extension Notification.Name {
    static let touchRDPRemoteClipboard = Notification.Name("touchRDPRemoteClipboard")
    /// All clipboard notifications carry the originating SessionController as
    /// object and their data under SessionController.clipboardPayloadKey.
    static let touchRDPRemoteClipboardImage = Notification.Name("touchRDPRemoteClipboardImage")
    /// #25: carries a `RemoteFileAnnouncement` when the remote clipboard holds
    /// files (parsed + sanitized descriptors; the puller is already armed for the
    /// announcement's generation).
    static let touchRDPRemoteClipboardFiles = Notification.Name("touchRDPRemoteClipboardFiles")
}

/// #25: one remote file-clipboard announcement — the sanitized descriptors plus the
/// clipboard generation the puller was armed with. The app layer turns each descriptor
/// into an `NSFilePromiseProvider`; a promise fulfilled after a NEWER announcement (or
/// after disconnect) fails gracefully because its generation is stale.
public struct RemoteFileAnnouncement: Sendable {
    public let descriptors: [RemoteFileClipboard.Descriptor]
    public let generation: Int
    public init(descriptors: [RemoteFileClipboard.Descriptor], generation: Int) {
        self.descriptors = descriptors
        self.generation = generation
    }
}
