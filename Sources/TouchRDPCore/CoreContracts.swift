import Foundation
import CoreGraphics

// MARK: - Credential vault (security-critical; the ONLY plaintext-secret handler)

public enum BiometryKind: String, Sendable { case touchID, faceID, none }

public struct BiometricCapability: Sendable {
    public let available: Bool          // can we evaluate biometrics right now?
    public let type: BiometryKind
    public let deviceOwnerAuthAvailable: Bool  // passcode/password fallback present
    public init(available: Bool, type: BiometryKind, deviceOwnerAuthAvailable: Bool) {
        self.available = available; self.type = type
        self.deviceOwnerAuthAvailable = deviceOwnerAuthAvailable
    }
}

/// Which storage tier is actually protecting secrets (see docs/SECURITY.md).
public enum VaultTier: String, Sendable {
    case hardwareBound      // Secure-Enclave-bound, OS-enforced biometric ACL (signed builds)
    case appGatedFallback   // plain keychain + app-enforced Touch ID gate (unsigned local dev)
}

/// Why a credential is being requested. Lets the app layer choose a reuse window so an
/// automatic reconnect chain coalesces into ≤1 biometric prompt (LIFE-3).
public enum CredentialRequestReason: Sendable {
    case userInitiated
    case automaticReconnect
    /// F-27: the secret is about to be TYPED into a live session (lock-screen password
    /// typing), not handed to a verified NLA handshake. Always a fresh prompt and never
    /// seeds a reusable context — see `authDirective`.
    case inSessionTyping
}

public enum VaultError: Error, Equatable, Sendable {
    case itemNotFound
    case biometricUnavailable
    case userCancelled
    case authenticationFailed
    case invalidated          // biometric set changed (PRD §9.4) — re-store needed
    case duplicate
    /// The secret is empty: an empty password was offered for storage, or the stored item
    /// holds no bytes. TouchRDP requires a complete credential pair for every connection;
    /// with NLA specifically, an empty item reads back as "Saved" while the attempt dies
    /// deep inside NTLM. Both directions refuse it with an actionable reason instead.
    case emptySecret
    case unexpected(OSStatus)
}

/// Which secret of a connection a vault operation targets (F-6). A connection has at
/// most one secret per kind; both live under the same Keychain policy/tier and are
/// keyed distinctly (see `KeychainCredentialVault.keychainAccount(for:kind:)`).
public enum CredentialKind: String, Sendable, CaseIterable {
    case primary   // the RDP host password (pre-F-6 behavior)
    case gateway   // the separate RD Gateway password (only when configured)
}

/// The secrets released for ONE connect flow by a single biometric authentication.
/// `gateway` is nil unless the connection is configured with separate gateway
/// credentials. Never persisted, logged, or placed on the pasteboard; the engine
/// consumes it immediately (same lifetime rules as the plain password before F-6).
public struct ConnectionSecrets: Sendable {
    public let primary: String
    public let gateway: String?
    public init(primary: String, gateway: String? = nil) {
        self.primary = primary; self.gateway = gateway
    }
}

public protocol CredentialVault: AnyObject, Sendable {
    var capability: BiometricCapability { get }
    var activeTier: VaultTier { get }

    /// Store/replace the password for a connection. Storing requires NO biometric.
    func storePassword(_ password: String, for connectionID: UUID) throws
    /// Release the password, gated by Touch ID. `reason` is shown in the prompt.
    /// `allowReuseSeconds` honours CredentialPolicy.biometricReuse; `forceFreshPrompt` mints
    /// (and caches) a new `LAContext` even if a valid one exists, so this retrieval prompts
    /// but seeds a reusable authentication for a following automatic reconnect (LIFE-3).
    func retrievePassword(for connectionID: UUID, reason: String,
                          allowReuseSeconds: Int?, forceFreshPrompt: Bool) async throws -> String
    func hasPassword(for connectionID: UUID) -> Bool
    /// Deletes ALL secrets (every `CredentialKind`) for the connection — the
    /// delete-on-connection-delete path must never orphan a gateway item (F-6).
    func deletePassword(for connectionID: UUID) throws
    func deleteAll() throws

    // F-6: kind-aware variants (gateway secret). Extension defaults below keep
    // pre-F-6 conformers compiling; the real vault overrides all of them.
    func storePassword(_ password: String, for connectionID: UUID, kind: CredentialKind) throws
    func hasPassword(for connectionID: UUID, kind: CredentialKind) -> Bool
    func deletePassword(for connectionID: UUID, kind: CredentialKind) throws
    /// Release the primary password — and, when `includeGateway`, the gateway password —
    /// under ONE biometric authentication (a single Touch ID prompt covers both: the
    /// same authenticated `LAContext` is used for both reads; the context is cached,
    /// never the secrets).
    func retrieveConnectionSecrets(for connectionID: UUID, includeGateway: Bool,
                                   reason: String, allowReuseSeconds: Int?,
                                   forceFreshPrompt: Bool) async throws -> ConnectionSecrets
}

public extension CredentialVault {
    /// Back-compat convenience: retrieve without seeding a reusable context (`forceFreshPrompt:
    /// false`) — prompts per the reuse window as before.
    func retrievePassword(for connectionID: UUID, reason: String,
                          allowReuseSeconds: Int?) async throws -> String {
        try await retrievePassword(for: connectionID, reason: reason,
                                   allowReuseSeconds: allowReuseSeconds, forceFreshPrompt: false)
    }

    // F-6 back-compat defaults: `.primary` forwards to the pre-F-6 methods; `.gateway`
    // on a conformer that never implemented it fails closed (-4 = unimplemented) rather
    // than silently answering with the primary secret.
    func storePassword(_ password: String, for connectionID: UUID, kind: CredentialKind) throws {
        guard kind == .primary else { throw VaultError.unexpected(-4) }
        try storePassword(password, for: connectionID)
    }
    func hasPassword(for connectionID: UUID, kind: CredentialKind) -> Bool {
        kind == .primary ? hasPassword(for: connectionID) : false
    }
    func deletePassword(for connectionID: UUID, kind: CredentialKind) throws {
        guard kind == .primary else { return }   // nothing stored => nothing to delete
        try deletePassword(for: connectionID)
    }
    func retrieveConnectionSecrets(for connectionID: UUID, includeGateway: Bool,
                                   reason: String, allowReuseSeconds: Int?,
                                   forceFreshPrompt: Bool) async throws -> ConnectionSecrets {
        guard !includeGateway else { throw VaultError.unexpected(-4) }  // fail closed
        let primary = try await retrievePassword(for: connectionID, reason: reason,
                                                 allowReuseSeconds: allowReuseSeconds,
                                                 forceFreshPrompt: forceFreshPrompt)
        return ConnectionSecrets(primary: primary, gateway: nil)
    }
}

// MARK: - Connection store (no secrets persisted here)

public protocol ConnectionStore: AnyObject {
    var connections: [Connection] { get }
    /// Mutations commit to disk before publishing. Failure leaves the last saved
    /// state intact and must be surfaced to the user by the caller.
    func add(_ connection: Connection) throws
    func update(_ connection: Connection) throws
    func delete(id: UUID) throws
    @discardableResult func duplicate(id: UUID) throws -> Connection?
    func move(fromOffsets: IndexSet, toOffset: Int) throws
    /// Parse a Microsoft .rdp file into a Connection (no secret) — PRD FR-6.5.
    func importRDPFile(at url: URL) throws -> Connection
    /// Export profiles WITHOUT secrets — PRD FR-1.4.
    func exportConnections(to url: URL) throws
}

// MARK: - Certificate trust store (TOFU pinning)

public protocol CertificateTrustStore: AnyObject, Sendable {
    func evaluate(_ info: CertInfo) -> TrustState
    func pin(_ info: CertInfo)
    func remove(host: String, port: Int)
    /// F-11: what was pinned for this host, for the "certificate changed" old→new diff.
    /// Read-only; never influences the trust decision itself. Default nil so pre-F-11
    /// conformers keep compiling (the review sheet then shows fingerprints only).
    func pinnedRecord(host: String, port: Int) -> PinnedCertRecord?
}

public extension CertificateTrustStore {
    func pinnedRecord(host: String, port: Int) -> PinnedCertRecord? { nil }
}

// MARK: - RDP session engine

/// One monitor in a multi-monitor layout, in remote virtual-desktop pixel space
/// (top-left origin). The app layer derives these from the local macOS screens.
public struct MonitorDef: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var isPrimary: Bool
    public var scaleFactor: Int   // DesktopScaleFactor 100..500
    public init(x: Int, y: Int, width: Int, height: Int, isPrimary: Bool, scaleFactor: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.isPrimary = isPrimary; self.scaleFactor = scaleFactor
    }
}

public struct RDPConnectionConfig: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var domain: String?
    public var security: RDPSecurity
    public var width: Int
    public var height: Int
    public var desktopScaleFactor: Int   // 100/140/180; 0 => 100
    public var clipboardEnabled: Bool
    public var imageClipboardEnabled: Bool
    /// F-8: offer local files to the remote clipboard (Mac→Windows only).
    public var fileClipboardEnabled: Bool
    public var audioEnabled: Bool
    public var gateway: GatewaySettings?
    public var tcpConnectTimeoutMs: Int
    /// Multi-monitor layout. Empty or single-element = single-monitor session.
    public var monitors: [MonitorDef]
    /// Opt-in drive redirection: absolute local folder shared with the host. nil = off.
    public var sharedFolderPath: String?
    /// F-17: opt-in printer redirection — all local CUPS printers, rdpdr channel.
    public var printerRedirectionEnabled: Bool
    /// F-2: experience/performance profile. `.default` (.auto) => the engine sets no
    /// experience override and the bridge keeps its built-in defaults.
    public var experience: ExperienceSettings
    /// F-15: remote keyboard layout preset. `.auto` (kbdID 0) => the bridge leaves
    /// FreeRDP_KeyboardLayout untouched — exactly the pre-F-15 behavior.
    public var keyboardLayout: KeyboardLayoutPreset
    /// PERF-9: AVC444 and hardware-decode toggles. `.default` (both on) == the
    /// bridge's pre-PERF-9 behaviour.
    public var videoDecoding: VideoDecodingSettings

    public init(host: String, port: Int, username: String, domain: String?,
                security: RDPSecurity, width: Int, height: Int, desktopScaleFactor: Int,
                clipboardEnabled: Bool, imageClipboardEnabled: Bool = false,
                fileClipboardEnabled: Bool = false,
                audioEnabled: Bool, gateway: GatewaySettings?,
                tcpConnectTimeoutMs: Int = 15000,
                monitors: [MonitorDef] = [], sharedFolderPath: String? = nil,
                printerRedirectionEnabled: Bool = false,
                experience: ExperienceSettings = .default,
                keyboardLayout: KeyboardLayoutPreset = .auto,
                videoDecoding: VideoDecodingSettings = .default) {
        self.host = host; self.port = port; self.username = username; self.domain = domain
        self.security = security; self.width = width; self.height = height
        self.desktopScaleFactor = desktopScaleFactor
        self.clipboardEnabled = clipboardEnabled
        self.imageClipboardEnabled = imageClipboardEnabled
        self.fileClipboardEnabled = fileClipboardEnabled
        self.audioEnabled = audioEnabled
        self.gateway = gateway; self.tcpConnectTimeoutMs = tcpConnectTimeoutMs
        self.monitors = monitors; self.sharedFolderPath = sharedFolderPath
        self.printerRedirectionEnabled = printerRedirectionEnabled
        self.experience = experience
        self.keyboardLayout = keyboardLayout
        self.videoDecoding = videoDecoding
    }

    /// Build a config from a Connection (secrets excluded by construction).
    public init(from c: Connection) {
        self.init(host: c.host, port: c.port, username: c.username, domain: c.domain,
                  security: c.security, width: c.display.width, height: c.display.height,
                  // Per-connection server-side DPI ("zoom"): 100 = native (no zoom).
                  // Higher values make Windows render its UI larger. Clamped to RDP's
                  // accepted 100–500 range.
                  desktopScaleFactor: min(max(c.display.scaleFactor, 100), 500),
                  clipboardEnabled: c.clipboardEnabled,
                  imageClipboardEnabled: c.imageClipboardEnabled,
                  fileClipboardEnabled: c.fileClipboardEnabled,
                  audioEnabled: c.audioEnabled,
                  gateway: c.gateway,
                  sharedFolderPath: c.sharedFolderPath?.isEmpty == false ? c.sharedFolderPath : nil,
                  // F-17: printer redirection rides the same rdpdr channel as the drive.
                  printerRedirectionEnabled: c.printerRedirectionEnabled,
                  // F-2: both the fresh-connect and reconnect paths build their config
                  // here (SessionController.makeConfig), so the profile applies to both.
                  experience: c.experience,
                  // F-15: layout preset rides the same path (fresh connect + reconnect).
                  keyboardLayout: c.keyboardLayout,
                  // PERF-9: decoding knobs ride the same path too.
                  videoDecoding: c.videoDecoding)
    }
}

/// A remote mouse-cursor update. `.image` carries the cursor bitmap and its click
/// hotspot (both in cursor pixels); `.hidden` means the host wants no pointer; `.arrow`
/// restores the default system cursor.
public enum CursorUpdate {
    case image(CGImage, hotSpot: CGPoint)
    case hidden
    case arrow
}

/// Delegate callbacks. The UI-bound ones are delivered on the MAIN actor by the
/// engine. `sessionVerifyCertificate` is the sole exception: it is invoked
/// synchronously on the RDP thread (it must return a decision inline), so it is
/// nonisolated and its implementation must be fast + non-blocking (no modal UI).
public protocol RDPSessionDelegate: AnyObject {
    @MainActor func sessionDidChangeState(_ state: ConnectionState)
    /// A new framebuffer snapshot. PERF-5: an IOSurface-backed `RemoteFrame` the canvas
    /// hands to Core Animation without copying; use `makeCGImage()` for a copy.
    @MainActor func sessionDidRenderFrame(_ frame: RemoteFrame)
    @MainActor func sessionDidResize(to size: CGSize)
    /// Return true to accept the certificate (engine wires this to TOFU logic).
    /// SYNCHRONOUS, RDP thread — must not block on UI.
    func sessionVerifyCertificate(_ info: CertInfo) -> Bool
    @MainActor func sessionClipboardTextChanged(_ text: String)
    /// The remote clipboard now holds an image (delivered as a decoded CGImage).
    @MainActor func sessionClipboardImageChanged(_ image: CGImage)
    /// #25: the remote clipboard now holds FILES. `descriptorBlob` is the raw
    /// FILEGROUPDESCRIPTORW payload (already a private copy; parse it with
    /// `RemoteFileClipboard.parse`).
    @MainActor func sessionClipboardFilesChanged(_ descriptorBlob: Data)
    /// #25: a FILECONTENTS response for a pull WE issued (`requestFileSize` /
    /// `requestFileRange`). NONISOLATED — forwarded straight off the RDP thread so the
    /// transfer engine can match it to its pending table without a main-thread detour.
    /// `data` is already a private copy; `success` false => the server FAILed the
    /// request (or the bridge rejected an oversized payload) and `data` is empty.
    nonisolated func sessionFileContentsResponse(streamId: UInt32, success: Bool, data: Data)
    /// The remote cursor shape changed (or asked to hide / reset to arrow).
    @MainActor func sessionDidUpdateCursor(_ update: CursorUpdate)
}

public extension RDPSessionDelegate {
    // Optional: existing conformers that don't care about the cursor still compile.
    @MainActor func sessionDidUpdateCursor(_ update: CursorUpdate) {}
    // Optional: conformers that don't handle image clipboard still compile.
    @MainActor func sessionClipboardImageChanged(_ image: CGImage) {}
    // Optional (#25): conformers without remote-file-paste support still compile.
    @MainActor func sessionClipboardFilesChanged(_ descriptorBlob: Data) {}
    nonisolated func sessionFileContentsResponse(streamId: UInt32, success: Bool, data: Data) {}
}

/// A point-in-time snapshot of low-level session counters. `compressedBytes` and
/// `frameCount` are cumulative/monotonic (difference them over an interval for throughput
/// and FPS). `rttMs` / `bandwidthKbps` come from RDP network autodetect and are 0 when the
/// server doesn't report them.
public struct RDPRawStats: Sendable, Equatable {
    public var compressedBytes: UInt64
    public var frameCount: UInt64
    public var rttMs: UInt32
    public var bandwidthKbps: UInt32
    public init(compressedBytes: UInt64 = 0, frameCount: UInt64 = 0,
                rttMs: UInt32 = 0, bandwidthKbps: UInt32 = 0) {
        self.compressedBytes = compressedBytes; self.frameCount = frameCount
        self.rttMs = rttMs; self.bandwidthKbps = bandwidthKbps
    }
}

public protocol RDPSession: AnyObject {
    var delegate: RDPSessionDelegate? { get set }
    /// Inject the Touch-ID-released password(s) and connect. Neither is retained.
    /// `gatewayPassword` nil => the RD Gateway (if any) uses the main credentials (F-6).
    func connect(config: RDPConnectionConfig, password: String, gatewayPassword: String?)
    func disconnect()

    // Input
    func sendPointer(buttonMask: PointerButtons, x: Int, y: Int, down: Bool, moved: Bool)
    /// F-9: X1/X2 (back/forward) buttons — a distinct extended-mouse PDU on the wire.
    /// `buttonMask` should contain only `.back` / `.forward`; others are ignored.
    func sendExtendedPointer(buttonMask: PointerButtons, x: Int, y: Int, down: Bool)
    func sendWheel(delta: Int, horizontal: Bool)
    func sendScancode(_ code: UInt16, down: Bool, extended: Bool)
    func sendUnicode(_ code: UInt16, down: Bool)
    /// F-27: type `secret` into the live session as Unicode key events (lock-screen
    /// password typing). BLOCKS while pacing the keystrokes — call it off the main
    /// thread. Returns false if the session was not connected or dropped partway.
    func typeSecret(_ secret: String, perKeyDelayMs: UInt32) -> Bool
    func sendCtrlAltDel()
    /// Synchronize the remote toggle-key (Caps/Num/Scroll Lock) state with the host.
    func sendKeyboardSync(capsLock: Bool, numLock: Bool, scrollLock: Bool)
    /// F-26 "Stay awake": inject a benign no-op keystroke (F15 down/up) so the remote
    /// idle timer resets without any visible effect. Never counts as real user input.
    func sendKeepAlive()

    // Display / clipboard
    /// `scalePercent`: Windows DesktopScaleFactor % for the new layout (100..500),
    /// tracking the display the window sits on; 0 = keep the connect-time value.
    func requestResize(width: Int, height: Int, scalePercent: Int)
    func setClipboardText(_ text: String)
    func setClipboardImage(_ image: CGImage)
    /// F-8: stage a Mac→Windows FILE offer on the remote clipboard. `files` are already
    /// validated/sanitized (`FileClipboardOffer.validate`). Returns true when staged.
    func offerFiles(_ files: [FileClipboardOffer.StagedFile]) -> Bool
    /// #25: issue a FILECONTENTS_SIZE request against the server's announced file list
    /// (the reply — an 8-byte LE size — comes back via `sessionFileContentsResponse`).
    /// Thread-safe; returns false when the request could not even be queued.
    func requestFileSize(streamId: UInt32, listIndex: UInt32) -> Bool
    /// #25: issue a FILECONTENTS_RANGE request (sequential pull chunk). Thread-safe.
    func requestFileRange(streamId: UInt32, listIndex: UInt32,
                          offset: UInt64, length: UInt32) -> Bool
    /// A snapshot of live session counters for the quality indicator.
    func currentStats() -> RDPRawStats

    var freeRDPVersion: String { get }
    /// PERF-8: whether the linked FreeRDP can decode H.264 (AVC420/AVC444 GFX frames) on
    /// the hardware (VideoToolbox). A build property, not a live state: FreeRDP uses the
    /// hardware path automatically when compiled in and falls back to software only if
    /// the decoder session can't be created.
    var hardwareH264DecodeAvailable: Bool { get }
}

public extension RDPSession {
    // PERF-8 default so conformers that don't wrap FreeRDP (test doubles) still compile.
    var hardwareH264DecodeAvailable: Bool { false }
    // F-27 default so existing conformers (test doubles) still compile.
    func typeSecret(_ secret: String, perKeyDelayMs: UInt32) -> Bool { false }
    /// Back-compat convenience (pre-F-6 call sites): connect without a gateway secret.
    func connect(config: RDPConnectionConfig, password: String) {
        connect(config: config, password: password, gatewayPassword: nil)
    }
    // Default so conformers that don't surface stats (e.g. test doubles) still compile.
    func currentStats() -> RDPRawStats { RDPRawStats() }
    // F-9 default so existing conformers without X-button support still compile.
    func sendExtendedPointer(buttonMask: PointerButtons, x: Int, y: Int, down: Bool) {}
    // F-8 default so conformers without file-offer support (test doubles) still compile.
    func offerFiles(_ files: [FileClipboardOffer.StagedFile]) -> Bool { false }
    // #25 defaults so conformers without remote-file-pull support still compile.
    func requestFileSize(streamId: UInt32, listIndex: UInt32) -> Bool { false }
    func requestFileRange(streamId: UInt32, listIndex: UInt32,
                          offset: UInt64, length: UInt32) -> Bool { false }
    // F-26 default so existing conformers without stay-awake support still compile.
    func sendKeepAlive() {}
}

public struct PointerButtons: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left   = PointerButtons(rawValue: 1 << 0)
    public static let right  = PointerButtons(rawValue: 1 << 1)
    public static let middle = PointerButtons(rawValue: 1 << 2)
    // F-9: X1/X2 side buttons (browser back/forward). Sent via the RDP extended-mouse
    // PDU, not the standard pointer event — see RDPSession.sendExtendedPointer.
    public static let back    = PointerButtons(rawValue: 1 << 3)
    public static let forward = PointerButtons(rawValue: 1 << 4)
}

// MARK: - Keyboard mapping (PRD §8.6)

public enum ModifierMode: String, Sendable, CaseIterable {
    case cmdAsCtrl   // default (D5): Mac Cmd -> Windows Ctrl
    case literal     // Cmd -> Windows/Super; Ctrl -> Ctrl
}

public struct KeyAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case scancode(UInt16, extended: Bool)
        case unicode(UInt16)
    }
    public let kind: Kind
    public let down: Bool
    public init(kind: Kind, down: Bool) { self.kind = kind; self.down = down }
}

/// Maps a macOS key event into one or more RDP key actions. Implementations are
/// scancode-first for layout fidelity, with a unicode fallback (PRD §8.6.16).
public protocol KeyboardMapper: AnyObject {
    var modifierMode: ModifierMode { get set }
    var useUnicodeFallback: Bool { get set }
    /// keyCode = NSEvent.keyCode (virtual), modifiers = NSEvent.modifierFlags raw.
    func actions(forKeyCode keyCode: UInt16, characters: String?,
                 modifiers: UInt, keyDown: Bool) -> [KeyAction]
    /// The Ctrl+Alt+Del chord, for menu/toolbar.
    func ctrlAltDelActions() -> [KeyAction]
}
