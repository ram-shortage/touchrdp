import Foundation
import CoreGraphics
import Accelerate
import TouchRDPCore
import CRDPBridge

/// Concrete RDPSession backed by FreeRDP via CRDPBridge.
/// Threading: FreeRDP callbacks arrive on the bridge's RDP thread. We hop to the
/// main thread for all delegate calls EXCEPT `sessionVerifyCertificate`, which is
/// synchronous-by-necessity and must be handled with fast, non-blocking trust-store
/// logic (no modal) by the delegate. See SessionController.
public final class FreeRDPSession: RDPSession {
    // CONC-3: `delegate` is read from the RDP thread (handleCertVerify) while it is set to
    // nil/self on the main actor. A bare cross-thread `weak var` read/write is unsafe, so
    // back it with a lock-guarded stored property; all access goes through the accessor.
    private let delegateLock = NSLock()
    private weak var _delegate: RDPSessionDelegate?
    public weak var delegate: RDPSessionDelegate? {
        get { delegateLock.lock(); defer { delegateLock.unlock() }; return _delegate }
        set { delegateLock.lock(); _delegate = newValue; delegateLock.unlock() }
    }

    private var bridge: OpaquePointer?

    // Frame coalescing: the RDP thread can produce frames faster than the main thread
    // draws them. Keep only the newest pending frame and at most one scheduled main
    // hop, so frame work can never starve input/UI events on the main queue.
    private let frameLock = NSLock()
    private var pendingFrame: RemoteFrame?
    private var frameScheduled = false
    // PERF-1/PERF-5: pooled IOSurfaces backing the zero-copy frame snapshots.
    private let framePool = FrameSurfacePool()

    public init() {
        let cbs = RDPBridgeCallbacks(
            onState: { ctx, state, code, str in
                FreeRDPSession.from(ctx)?.handleState(state, code, str)
            },
            onFrame: { ctx, bgra, _, y, _, h, fullW, fullH, stride in
                // PERF-1: x/width are ignored — the pool blits full rows (contiguous
                // memcpy); only the row range matters for the copy cost.
                FreeRDPSession.from(ctx)?.handleFrame(bgra, dirtyY: y, dirtyH: h,
                                                      fullW, fullH, stride)
            },
            onResize: { ctx, w, h in
                FreeRDPSession.from(ctx)?.handleResize(w, h)
            },
            onCertVerify: { ctx, info in
                FreeRDPSession.from(ctx)?.handleCertVerify(info) ?? 0
            },
            onClipboard: { ctx, text in
                FreeRDPSession.from(ctx)?.handleClipboard(text)
            },
            onClipboardImage: { ctx, dib, len in
                FreeRDPSession.from(ctx)?.handleClipboardImage(dib, len)
            },
            onCursor: { ctx, bgra, w, h, hotX, hotY in
                FreeRDPSession.from(ctx)?.handleCursor(bgra, w, h, hotX, hotY)
            },
            onCursorHidden: { ctx in
                FreeRDPSession.from(ctx)?.handleCursorState(.hidden)
            },
            onCursorDefault: { ctx in
                FreeRDPSession.from(ctx)?.handleCursorState(.arrow)
            },
            onClipboardFiles: { ctx, blob, len in
                FreeRDPSession.from(ctx)?.handleClipboardFiles(blob, len)
            },
            onFileContents: { ctx, streamId, success, data, len in
                FreeRDPSession.from(ctx)?.handleFileContents(streamId, success, data, len)
            }
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        bridge = rdpbridge_create(selfPtr, cbs)
    }

    deinit {
        // CONC-4: the bridge holds an unretained pointer to self. Detach first — it blocks
        // on the bridge's callback lock until any in-flight RDP-thread callback returns and
        // then nulls the callback link — so no late callback can touch this freed object.
        // rdpbridge_free then disconnects, joins the RDP thread, and frees the context.
        if let b = bridge { rdpbridge_detach(b); rdpbridge_free(b) }
    }

    private static func from(_ ctx: UnsafeMutableRawPointer?) -> FreeRDPSession? {
        guard let ctx else { return nil }
        return Unmanaged<FreeRDPSession>.fromOpaque(ctx).takeUnretainedValue()
    }

    // MARK: RDPSession

    public func connect(config: RDPConnectionConfig, password: String, gatewayPassword: String?) {
        guard let b = bridge else { return }
        // Pre-marshal the monitor layout into the C struct layout; the buffer's address
        // is handed to the bridge (which deep-copies) inside the call below.
        let monitorArray: [RDPBridgeMonitor] = config.monitors.map { m in
            var rm = RDPBridgeMonitor()
            rm.x = Int32(m.x); rm.y = Int32(m.y)
            rm.width = Int32(m.width); rm.height = Int32(m.height)
            rm.isPrimary = m.isPrimary ? 1 : 0
            rm.scaleFactor = UInt32(max(100, min(m.scaleFactor, 500)))
            return rm
        }
        let drivePath = Self.validatedSharedFolder(config.sharedFolderPath)
        // Marshal the secret as an explicitly sized UTF-8 byte slice. A C string alone
        // cannot distinguish an embedded NUL from truncation, which made it impossible
        // to prove that FreeRDP received the same value released by the vault.
        let passwordBytes = Array(password.utf8)
        config.host.withCString { host in
        config.username.withCString { user in
        (config.domain ?? "").withCString { domain in
        (config.gateway?.hostname ?? "").withCString { gwHost in
        (config.gateway?.username ?? "").withCString { gwUser in
        (config.gateway?.domain ?? "").withCString { gwDomain in
        drivePath.withCString { dpath in
        (gatewayPassword ?? "").withCString { gwPass in
        passwordBytes.withUnsafeBufferPointer { pbuf in
        monitorArray.withUnsafeBufferPointer { mbuf in
            var cfg = RDPBridgeConfig()
            cfg.hostname = host
            cfg.port = UInt32(config.port)
            cfg.username = user
            cfg.domain = (config.domain?.isEmpty == false) ? domain : nil
            cfg.width = UInt32(config.width)
            cfg.height = UInt32(config.height)
            cfg.desktopScaleFactor = UInt32(config.desktopScaleFactor)
            cfg.security = config.security.bridgeValue
            cfg.clipboardEnabled = config.clipboardEnabled ? 1 : 0
            cfg.imageClipboardEnabled = config.imageClipboardEnabled ? 1 : 0
            // F-8: file offers require the clipboard toggle too (defense in depth —
            // the UI already disables the file toggle when clipboard is off).
            cfg.fileClipboardEnabled = (config.clipboardEnabled && config.fileClipboardEnabled) ? 1 : 0
            cfg.audioEnabled = config.audioEnabled ? 1 : 0
            cfg.tcpConnectTimeoutMs = UInt32(config.tcpConnectTimeoutMs)
            // F-15: keyboard layout preset. `.auto` has kbdID 0 == "unset", so the
            // bridge leaves FreeRDP_KeyboardLayout alone (pre-F-15 behavior).
            cfg.keyboardLayout = config.keyboardLayout.kbdID
            if let gw = config.gateway {
                cfg.gatewayEnabled = 1
                cfg.gatewayHostname = gwHost
                cfg.gatewayPort = UInt32(gw.port)
                cfg.gatewayUsername = (gw.username?.isEmpty == false) ? gwUser : nil
                cfg.gatewayDomain = (gw.domain?.isEmpty == false) ? gwDomain : nil
                // F-6: NULL => the bridge falls back to the main password for the
                // gateway (pre-F-6 behavior). The C side dup+zeroes it (SEC-2).
                cfg.gatewayPassword = (gatewayPassword?.isEmpty == false) ? gwPass : nil
            }
            // Multi-monitor (only meaningful when more than one).
            if monitorArray.count > 1 {
                cfg.monitors = mbuf.baseAddress
                cfg.monitorCount = UInt32(monitorArray.count)
            }
            // Drive redirection: path drives it; the bridge defaults the share name.
            cfg.driveSharePath = drivePath.isEmpty ? nil : dpath
            cfg.driveShareName = nil
            // F-17: printer redirection (all local CUPS printers, same rdpdr channel).
            cfg.printerRedirectionEnabled = config.printerRedirectionEnabled ? 1 : 0
            // PERF-9: decoding knobs. Zero == the bridge's built-in behaviour (both on).
            cfg.avc444Disabled = config.videoDecoding.avc444Enabled ? 0 : 1
            cfg.h264HardwareDecodeDisabled = config.videoDecoding.hardwareDecodeEnabled ? 0 : 1
            // F-2: experience profile. `.auto` resolves to nil, leaving experienceSet
            // at 0 (zero-initialized struct) so the bridge keeps its built-in defaults
            // — bit-for-bit the pre-F-2 connect settings.
            if let exp = config.experience.resolved() {
                cfg.experienceSet = 1
                cfg.expConnectionType = exp.connectionType.rawValue
                cfg.expNetworkAutoDetect = exp.networkAutoDetect ? 1 : 0
                cfg.expColorDepth = UInt32(exp.colorDepth.rawValue)
                cfg.expShowWallpaper = exp.showWallpaper ? 1 : 0
                cfg.expFontSmoothing = exp.fontSmoothing ? 1 : 0
                cfg.expFullWindowDrag = exp.fullWindowDrag ? 1 : 0
                cfg.expMenuAnimations = exp.menuAnimations ? 1 : 0
                cfg.expThemes = exp.themes ? 1 : 0
            }
            _ = rdpbridge_connect(b, &cfg, pbuf.baseAddress, pbuf.count)
        }}}}}}}}}}
    }

    /// Defense-in-depth for drive redirection: the editor's folder picker already
    /// validates, but a hand-edited profile JSON could smuggle in "/" or a home dir.
    /// Re-check here at the connect chokepoint: must be an existing directory and not a
    /// sensitive root. Returns "" (disabled) otherwise.
    static func validatedSharedFolder(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        let normalized = (path as NSString).standardizingPath
        let blocked: Set<String> = ["/", "/Users", "/Volumes", "/System",
                                    "/Library", "/private", NSHomeDirectory()]
        if blocked.contains(normalized) { return "" }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir),
              isDir.boolValue else { return "" }
        return normalized
    }

    public func disconnect() { if let b = bridge { rdpbridge_disconnect(b) } }

    public func sendPointer(buttonMask: PointerButtons, x: Int, y: Int, down: Bool, moved: Bool) {
        guard let b = bridge else { return }
        // RDP PTR_FLAGS: MOVE=0x0800, DOWN=0x8000, BUTTON1=0x1000, BUTTON2=0x2000, BUTTON3=0x4000
        var flags: UInt16 = 0
        if moved { flags |= 0x0800 }
        if buttonMask.contains(.left)   { flags |= 0x1000 }
        if buttonMask.contains(.right)  { flags |= 0x2000 }
        if buttonMask.contains(.middle) { flags |= 0x4000 }
        if down { flags |= 0x8000 }
        rdpbridge_send_pointer(b, flags, UInt16(clamping: x), UInt16(clamping: y))
    }

    public func sendExtendedPointer(buttonMask: PointerButtons, x: Int, y: Int, down: Bool) {
        guard let b = bridge else { return }
        // F-9 — RDP PTR_XFLAGS (freerdp3/freerdp/input.h): DOWN=0x8000,
        // XBUTTON1=0x0001 (back), XBUTTON2=0x0002 (forward).
        var flags: UInt16 = 0
        if buttonMask.contains(.back)    { flags |= 0x0001 }
        if buttonMask.contains(.forward) { flags |= 0x0002 }
        guard flags != 0 else { return }   // nothing but X buttons travels this PDU
        if down { flags |= 0x8000 }
        rdpbridge_send_extended_pointer(b, flags, UInt16(clamping: x), UInt16(clamping: y))
    }

    public func sendWheel(delta: Int, horizontal: Bool) {
        if let b = bridge { rdpbridge_send_wheel(b, Int16(clamping: delta), horizontal ? 1 : 0) }
    }

    public func sendScancode(_ code: UInt16, down: Bool, extended: Bool) {
        guard let b = bridge else { return }
        // KBD_FLAGS_DOWN=0x0000 (implicit), KBD_FLAGS_RELEASE=0x8000, KBD_FLAGS_EXTENDED=0x0100
        var flags: UInt16 = down ? 0x0000 : 0x8000
        if extended { flags |= 0x0100 }
        rdpbridge_send_scancode(b, flags, code)
    }

    public func sendUnicode(_ code: UInt16, down: Bool) {
        if let b = bridge { rdpbridge_send_unicode(b, down ? 0x0000 : 0x8000, code) }
    }

    /// F-27. Hands the secret straight to C as a length-delimited UTF-8 slice — the same
    /// boundary shape the connect-time password uses — so the bridge can zero its own
    /// decoded copy. Swift's own String buffer cannot be reliably zeroed; that is a known
    /// limitation shared with the connect path, not something this adds.
    public func typeSecret(_ secret: String, perKeyDelayMs: UInt32) -> Bool {
        guard let b = bridge, !secret.isEmpty else { return false }
        var utf8 = Array(secret.utf8)
        defer { for i in utf8.indices { utf8[i] = 0 } }
        return utf8.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return false }
            return rdpbridge_type_secret_utf8(b, base, buf.count, perKeyDelayMs) != 0
        }
    }

    public func sendCtrlAltDel() { if let b = bridge { rdpbridge_send_cad(b) } }

    /// F-26 "Stay awake": no-op F15 tap (RDP_SCANCODE_F15 = 0x66, non-extended) that
    /// resets the remote idle timer. The bridge gates it on connected under ctxLock.
    public func sendKeepAlive() { if let b = bridge { rdpbridge_send_keepalive(b) } }

    public func sendKeyboardSync(capsLock: Bool, numLock: Bool, scrollLock: Bool) {
        guard let b = bridge else { return }
        // RDP KBD_SYNC_* bitmask: Scroll=0x01, Num=0x02, Caps=0x04.
        var flags: UInt32 = 0
        if scrollLock { flags |= 0x01 }
        if numLock    { flags |= 0x02 }
        if capsLock   { flags |= 0x04 }
        rdpbridge_send_keyboard_sync(b, flags)
    }

    public func requestResize(width: Int, height: Int, scalePercent: Int = 0) {
        if let b = bridge {
            rdpbridge_request_resize(b, UInt32(width), UInt32(height), UInt32(scalePercent))
        }
    }

    public func setClipboardText(_ text: String) {
        if let b = bridge { text.withCString { rdpbridge_set_clipboard_text(b, $0) } }
    }

    public func setClipboardImage(_ image: CGImage) {
        guard let b = bridge, let dib = ClipboardImageDIB.dib(from: image) else { return }
        dib.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            rdpbridge_set_clipboard_image(b, base, UInt32(dib.count))
        }
    }

    /// F-8: stage a Mac→Windows file offer. `files` are pre-validated/sanitized by
    /// `FileClipboardOffer.validate`; the bridge copies the strings, opens its own fds
    /// (O_RDONLY|O_NOFOLLOW), and announces "FileGroupDescriptorW". All-or-nothing.
    public func offerFiles(_ files: [FileClipboardOffer.StagedFile]) -> Bool {
        guard let b = bridge, !files.isEmpty,
              files.count <= FileClipboardOffer.maxFiles else { return false }
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { for p in owned { free(p) } }
        var cItems: [RDPBridgeFileOfferItem] = []
        cItems.reserveCapacity(files.count)
        for f in files {
            guard let path = strdup(f.path), let name = strdup(f.name) else { return false }
            owned.append(path)
            owned.append(name)
            var item = RDPBridgeFileOfferItem()
            item.path = UnsafePointer(path)
            item.name = UnsafePointer(name)
            cItems.append(item)
        }
        let staged = cItems.withUnsafeBufferPointer { buf in
            rdpbridge_stage_file_offer(b, buf.baseAddress, UInt32(buf.count))
        }
        return staged == 1
    }

    /// F-8: drop a staged file offer early (fds closed; the empty-of-files format list
    /// is re-announced). Also happens implicitly on any new offer and on disconnect.
    public func clearFileOffer() {
        if let b = bridge { rdpbridge_clear_file_offer(b) }
    }

    /// #25: FILECONTENTS_SIZE request against the server's announced file list. The
    /// bridge send is thread-safe (ctxLock + connected gate), so the puller actor may
    /// call this from any executor.
    public func requestFileSize(streamId: UInt32, listIndex: UInt32) -> Bool {
        guard let b = bridge else { return false }
        return rdpbridge_request_file_size(b, streamId, listIndex) == 1
    }

    /// #25: FILECONTENTS_RANGE request (one sequential pull chunk). Thread-safe.
    public func requestFileRange(streamId: UInt32, listIndex: UInt32,
                                 offset: UInt64, length: UInt32) -> Bool {
        guard let b = bridge else { return false }
        return rdpbridge_request_file_range(b, streamId, listIndex, offset, length) == 1
    }

    public func currentStats() -> RDPRawStats {
        guard let b = bridge else { return RDPRawStats() }
        var compressed: UInt64 = 0, frames: UInt64 = 0
        var rtt: UInt32 = 0, bw: UInt32 = 0
        rdpbridge_get_stats(b, &compressed, &frames, &rtt, &bw)
        return RDPRawStats(compressedBytes: compressed, frameCount: frames,
                           rttMs: rtt, bandwidthKbps: bw)
    }

    public var freeRDPVersion: String {
        String(cString: rdpbridge_freerdp_version())
    }

    public var hardwareH264DecodeAvailable: Bool {
        rdpbridge_h264_hw_decode_available() != 0
    }

    // MARK: Callback handlers (RDP thread -> main)

    private func handleState(_ state: RDPBridgeState, _ code: UInt32, _ str: UnsafePointer<CChar>?) {
        let raw = str.map { String(cString: $0) } ?? ""
        let mapped: ConnectionState
        switch state {
        case RDPB_STATE_CONNECTING:     mapped = .connecting
        case RDPB_STATE_AUTHENTICATING: mapped = .authenticating
        case RDPB_STATE_NEGOTIATING:    mapped = .negotiating
        case RDPB_STATE_CONNECTED:      mapped = .connected
        case RDPB_STATE_RECONNECTING:   mapped = .reconnecting(attempt: 1)
        case RDPB_STATE_DISCONNECTED:   mapped = .disconnected(reason: raw.isEmpty ? nil : raw)
        case RDPB_STATE_FAILED:         mapped = .failed(RDPError.from(code: code, rawMessage: raw))
        default:                        mapped = .idle
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.delegate?.sessionDidChangeState(mapped)
            }
        }
    }

    private func handleFrame(_ bgra: UnsafePointer<UInt8>?, dirtyY: UInt32, dirtyH: UInt32,
                             _ fullW: UInt32, _ fullH: UInt32, _ stride: UInt32) {
        guard let bgra, fullW > 0, fullH > 0, dirtyH > 0 else { return }
        // PERF-1: blit only the rows this paint changed into a pooled surface. This runs
        // while the bridge's ctxLock is held (input sends contend on it), so shrinking
        // the copy from full-frame to dirty-rows is a direct input-latency win; the pool
        // also removes per-paint allocation churn. PERF-5: the surface is an IOSurface
        // the canvas displays without a further copy.
        guard let image = framePool.snapshot(src: bgra,
                                             dirtyY: Int(dirtyY), dirtyH: Int(dirtyH),
                                             fullWidth: Int(fullW), fullHeight: Int(fullH),
                                             stride: Int(stride)) else { return }
        // Coalesce: stash the latest frame; only schedule a main hop if none is
        // already in flight. Under load, intermediate frames are dropped (newest wins).
        frameLock.lock()
        pendingFrame = image
        let needsSchedule = !frameScheduled
        frameScheduled = true
        frameLock.unlock()
        guard needsSchedule else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameLock.lock()
            let latest = self.pendingFrame
            self.pendingFrame = nil
            self.frameScheduled = false
            self.frameLock.unlock()
            guard let latest else { return }
            MainActor.assumeIsolated {
                self.delegate?.sessionDidRenderFrame(latest)
            }
        }
    }

    private func handleResize(_ w: UInt32, _ h: UInt32) {
        let size = CGSize(width: Int(w), height: Int(h))
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.delegate?.sessionDidResize(to: size)
            }
        }
    }

    // Synchronous — runs on the RDP thread. Delegate MUST be fast + non-blocking.
    private func handleCertVerify(_ info: UnsafePointer<RDPBridgeCertInfo>?) -> Int32 {
        // Fail closed. A nil delegate can occur during session replacement/teardown;
        // accepting there would bypass the application's TOFU decision.
        guard let info, let d = delegate else { return 0 }
        let i = info.pointee
        let certInfo = CertInfo(
            host: i.host.map { String(cString: $0) } ?? "",
            port: Int(i.port),
            commonName: i.commonName.map { String(cString: $0) } ?? "",
            subject: i.subject.map { String(cString: $0) } ?? "",
            issuer: i.issuer.map { String(cString: $0) } ?? "",
            fingerprintSHA256: i.fingerprintSHA256.map { String(cString: $0) } ?? "",
            hostMismatch: i.hostMismatch != 0,
            changed: i.changed != 0)
        return d.sessionVerifyCertificate(certInfo) ? 1 : 0
    }

    private func handleClipboard(_ text: UnsafePointer<CChar>?) {
        guard let text else { return }
        let s = String(cString: text)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.delegate?.sessionClipboardTextChanged(s)
            }
        }
    }

    /// Remote delivered a clipboard image as CF_DIB bytes (RDP thread). Decode to a
    /// CGImage here, then hop to the main actor to hand it to the delegate.
    private func handleClipboardImage(_ dib: UnsafePointer<UInt8>?, _ len: UInt32) {
        guard let dib, len > 0 else { return }
        let data = Data(bytes: dib, count: Int(len))
        guard let image = ClipboardImageDIB.cgImage(fromDIB: data) else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.delegate?.sessionClipboardImageChanged(image)
            }
        }
    }

    /// #25: the remote clipboard holds files — the raw FILEGROUPDESCRIPTORW blob
    /// arrives on the RDP thread (valid only during the call: copy synchronously),
    /// then hops to the main actor where the controller parses it and stages promises.
    private func handleClipboardFiles(_ blob: UnsafePointer<UInt8>?, _ len: UInt32) {
        guard let blob, len > 0 else { return }
        let data = Data(bytes: blob, count: Int(len))
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.delegate?.sessionClipboardFilesChanged(data)
            }
        }
    }

    /// #25: FILECONTENTS response for a pull we issued. Copy the payload and forward
    /// WITHOUT a main-thread hop (the delegate method is nonisolated): the puller
    /// actor owns matching/sequencing, and file bytes have no business on the main
    /// queue.
    private func handleFileContents(_ streamId: UInt32, _ success: Int32,
                                    _ data: UnsafePointer<UInt8>?, _ len: UInt32) {
        let copy = (data != nil && len > 0) ? Data(bytes: data!, count: Int(len)) : Data()
        delegate?.sessionFileContentsResponse(streamId: streamId,
                                              success: success == 1 && data != nil,
                                              data: copy)
    }

    /// Convert a remote BGRA (straight-alpha) cursor bitmap into a CGImage and forward it.
    /// Runs on the RDP thread — the source buffer is valid only for this call, so we copy
    /// and premultiply here (CG cannot consume straight alpha), then hop to the main actor.
    private func handleCursor(_ bgra: UnsafePointer<UInt8>?,
                              _ w: UInt32, _ h: UInt32, _ hotX: Int32, _ hotY: Int32) {
        guard let bgra, w > 0, h > 0, w <= 384, h <= 384 else { return }
        let width = Int(w), height = Int(h), count = width * height * 4
        var px = [UInt8](repeating: 0, count: count)
        // BGRA straight -> premultiplied, vectorized. The RGBA8888 variant multiplies
        // the first three channels by the fourth — alpha sits last in BGRA too, so the
        // channel order is irrelevant; rounding matches the old scalar (c*a+127)/255.
        px.withUnsafeMutableBytes { dst in
            var srcBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bgra),
                                       height: vImagePixelCount(height),
                                       width: vImagePixelCount(width),
                                       rowBytes: width * 4)
            var dstBuf = vImage_Buffer(data: dst.baseAddress,
                                       height: vImagePixelCount(height),
                                       width: vImagePixelCount(width),
                                       rowBytes: width * 4)
            vImagePremultiplyData_RGBA8888(&srcBuf, &dstBuf, vImage_Flags(kvImageNoFlags))
        }
        guard let cg = Self.makeCursorImage(px, width: width, height: height) else { return }
        let hot = CGPoint(x: Int(hotX), y: Int(hotY))
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.delegate?.sessionDidUpdateCursor(.image(cg, hotSpot: hot))
            }
        }
    }

    private func handleCursorState(_ update: CursorUpdate) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.delegate?.sessionDidUpdateCursor(update)
            }
        }
    }

    private static func makeCursorImage(_ px: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(px)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)   // BGRA byte order
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}

private extension RDPSecurity {
    var bridgeValue: RDPBridgeSecurity {
        switch self {
        case .nla:       return RDPB_SEC_NLA
        case .tls:       return RDPB_SEC_TLS
        case .rdpLegacy: return RDPB_SEC_RDP
        }
    }
}
