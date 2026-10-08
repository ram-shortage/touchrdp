import Foundation

// MARK: - Video decoding (PERF-9)

/// Per-connection H.264 (GFX) decoding knobs. Both default to today's behaviour.
public struct VideoDecodingSettings: Codable, Equatable, Sendable {
    /// Negotiate AVC444 (a second, full-resolution chroma stream per frame for 4:4:4
    /// colour). Crisper coloured text; twice the decode work of AVC420. Off => the
    /// server may still use AVC420 / progressive / planar.
    public var avc444Enabled: Bool
    /// Decode AVC420/AVC444 frames with VideoToolbox when the linked FreeRDP has it
    /// (Tools/build-freerdp.sh). Lower CPU on video/animation, but a fixed GPU
    /// round-trip + full-frame readback per frame — software is often snappier for
    /// text and typing. Ignored by a FreeRDP built without VideoToolbox.
    public var hardwareDecodeEnabled: Bool

    public static let `default` = VideoDecodingSettings()

    public init(avc444Enabled: Bool = true, hardwareDecodeEnabled: Bool = true) {
        self.avc444Enabled = avc444Enabled
        self.hardwareDecodeEnabled = hardwareDecodeEnabled
    }

    // Forward-compatible: a missing key decodes to its default (no schema bump).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        avc444Enabled = try c.decodeIfPresent(Bool.self, forKey: .avc444Enabled) ?? true
        hardwareDecodeEnabled = try c.decodeIfPresent(Bool.self, forKey: .hardwareDecodeEnabled) ?? true
    }
}

// MARK: - Connection profile (NEVER contains a secret; passwords live in the vault)

public struct Connection: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var domain: String?
    public var security: RDPSecurity
    public var display: DisplaySettings
    public var gateway: GatewaySettings?
    public var clipboardEnabled: Bool
    /// Also synchronize bitmap images over the clipboard (in addition to text). Off by
    /// default: images are a wider exfiltration surface than text. Requires
    /// `clipboardEnabled`. See SECURITY.md.
    public var imageClipboardEnabled: Bool
    /// F-8: offer local FILES to the remote clipboard (Mac→Windows only; Finder ⌘C or
    /// drag-drop onto the session canvas). Off by default: the remote host can request
    /// the offered files' contents for as long as the offer stands. Requires
    /// `clipboardEnabled`. See SECURITY.md.
    public var fileClipboardEnabled: Bool
    public var audioEnabled: Bool
    public var credentialPolicy: CredentialPolicy
    public var groupName: String?
    public var lastConnected: Date?
    /// Opt-in drive redirection: absolute path of a local folder shared (read/write)
    /// with the remote host for the session. `nil`/empty = disabled (default). Carries
    /// real risk — the remote host can read and write everything under this folder.
    public var sharedFolderPath: String?
    /// F-17: opt-in printer redirection. Makes ALL local (CUPS) printers available in
    /// the remote session over the rdpdr channel. Off by default: it exposes local
    /// printer queue names to the host. Print jobs flow host→client only. See SECURITY.md.
    public var printerRedirectionEnabled: Bool
    /// F-10: per-connection keyboard modifier override. `.useGlobal` (default) follows
    /// the app-wide Cmd-key preference; the explicit modes pin this host regardless of it.
    public var modifierOverride: ModifierModeOverride
    /// F-20: per-connection automatic-reconnect policy. The default reproduces the
    /// global LIFE-3 behavior exactly (enabled, 1 attempt, ≥5 s delay).
    public var reconnectPolicy: ReconnectPolicy
    /// F-26: "Stay awake" cap in seconds (clamped 60...3600, default 300). Only the CAP
    /// is persisted — the on/off toggle itself is per-session runtime state and always
    /// starts OFF, so the feature can never silently re-enable on reconnect/relaunch.
    public var stayAwakeCapSeconds: Double
    /// F-2: per-connection experience/performance profile (wallpaper, font smoothing,
    /// color depth, bandwidth class). `.default` (profile `.auto`) leaves the bridge's
    /// built-in defaults untouched — exactly the pre-F-2 behavior.
    public var experience: ExperienceSettings
    /// F-15: remote keyboard LAYOUT preset — the Windows KBD_* layout id announced to
    /// the server at connect. `.auto` (default) sets nothing: the bridge never touches
    /// FreeRDP_KeyboardLayout, exactly the pre-F-15 behavior.
    public var keyboardLayout: KeyboardLayoutPreset
    /// F-15: small per-connection scancode override list, consulted by the mapper
    /// BEFORE the standard table (e.g. remap § to backtick on ISO keyboards).
    /// Capped at `maxKeyOverrides` on both init and decode.
    public var keyOverrides: [KeyOverride]
    /// PERF-9: per-connection H.264 decoding knobs (AVC444 on/off, hardware decode
    /// on/off). `.default` == today's behaviour: both on.
    public var videoDecoding: VideoDecodingSettings
    /// F-27: allow TouchRDP to TYPE the vaulted password into the live session (the
    /// Windows lock screen), as Unicode key events, behind a fresh Touch ID prompt and
    /// an explicit toolbar action. OFF by default and deliberately per-connection:
    /// unlike every other credential path, the client cannot verify what is focused on
    /// the remote side, so a mistimed use types the password into whatever window is
    /// open. Only enable it for hosts where that risk is acceptable. See SECURITY.md.
    public var passwordTypingEnabled: Bool
    /// How this connection treats the server's certificate. `.ask` (default) is the
    /// review-before-trust flow; the other modes trade that safety for convenience and
    /// are only ever chosen explicitly in the editor. See SECURITY.md.
    public var certificateMode: CertificateCheckMode

    /// F-15: hard cap on the override list — enforced in the model (init + decode),
    /// not just the editor UI.
    public static let maxKeyOverrides = 32

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 3389,
                username: String, domain: String? = nil, security: RDPSecurity = .nla,
                display: DisplaySettings = .init(), gateway: GatewaySettings? = nil,
                clipboardEnabled: Bool = true, imageClipboardEnabled: Bool = false,
                fileClipboardEnabled: Bool = false,
                audioEnabled: Bool = true,
                credentialPolicy: CredentialPolicy = .biometricEveryConnect,
                groupName: String? = nil, lastConnected: Date? = nil,
                sharedFolderPath: String? = nil,
                printerRedirectionEnabled: Bool = false,
                modifierOverride: ModifierModeOverride = .useGlobal,
                reconnectPolicy: ReconnectPolicy = .default,
                stayAwakeCapSeconds: Double = StayAwake.defaultCapSeconds,
                experience: ExperienceSettings = .default,
                keyboardLayout: KeyboardLayoutPreset = .auto,
                keyOverrides: [KeyOverride] = [],
                videoDecoding: VideoDecodingSettings = .default,
                passwordTypingEnabled: Bool = false,
                certificateMode: CertificateCheckMode = .ask) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.username = username; self.domain = domain; self.security = security
        self.display = display; self.gateway = gateway
        self.clipboardEnabled = clipboardEnabled
        self.imageClipboardEnabled = imageClipboardEnabled
        self.fileClipboardEnabled = fileClipboardEnabled
        self.audioEnabled = audioEnabled
        self.credentialPolicy = credentialPolicy; self.groupName = groupName
        self.lastConnected = lastConnected
        self.sharedFolderPath = sharedFolderPath
        self.printerRedirectionEnabled = printerRedirectionEnabled
        self.modifierOverride = modifierOverride
        self.reconnectPolicy = reconnectPolicy
        self.stayAwakeCapSeconds = StayAwake.clampCap(stayAwakeCapSeconds)
        self.experience = experience
        self.keyboardLayout = keyboardLayout
        self.keyOverrides = Array(keyOverrides.prefix(Self.maxKeyOverrides))
        self.videoDecoding = videoDecoding
        self.passwordTypingEnabled = passwordTypingEnabled
        self.certificateMode = certificateMode
    }

    // Custom decoding tolerates profiles saved before a field existed (e.g.
    // `imageClipboardEnabled`), defaulting missing keys instead of failing the whole
    // load. Mirrors the same forward-compatible pattern used by DisplaySettings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 3389
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        security = try c.decodeIfPresent(RDPSecurity.self, forKey: .security) ?? .nla
        display = try c.decodeIfPresent(DisplaySettings.self, forKey: .display) ?? .init()
        gateway = try c.decodeIfPresent(GatewaySettings.self, forKey: .gateway)
        clipboardEnabled = try c.decodeIfPresent(Bool.self, forKey: .clipboardEnabled) ?? true
        imageClipboardEnabled = try c.decodeIfPresent(Bool.self, forKey: .imageClipboardEnabled) ?? false
        // F-8: field added post-v1; older profiles decode to false (no schema bump).
        fileClipboardEnabled = try c.decodeIfPresent(Bool.self, forKey: .fileClipboardEnabled) ?? false
        audioEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? true
        credentialPolicy = try c.decodeIfPresent(CredentialPolicy.self, forKey: .credentialPolicy)
            ?? .biometricEveryConnect
        groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        sharedFolderPath = try c.decodeIfPresent(String.self, forKey: .sharedFolderPath)
        // F-17: field added post-v1; older profiles decode to false (no schema bump).
        printerRedirectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .printerRedirectionEnabled) ?? false
        // F-10: field added post-v1; older profiles decode to .useGlobal (no schema bump).
        modifierOverride = try c.decodeIfPresent(ModifierModeOverride.self, forKey: .modifierOverride)
            ?? .useGlobal
        // F-20: field added post-v1; older profiles decode to the default policy
        // (enabled, 1 attempt, 5 s) — today's global behavior, no schema bump.
        reconnectPolicy = try c.decodeIfPresent(ReconnectPolicy.self, forKey: .reconnectPolicy)
            ?? .default
        // F-26: field added post-v1; older profiles decode to the 5 min default. Clamped
        // on decode too, so a hand-edited store can't stretch the cap (no schema bump).
        stayAwakeCapSeconds = StayAwake.clampCap(
            try c.decodeIfPresent(Double.self, forKey: .stayAwakeCapSeconds)
                ?? StayAwake.defaultCapSeconds)
        // F-2: field added post-v1; older profiles decode to `.default` (profile .auto),
        // which resolves to "no override" — bit-for-bit today's connect settings.
        experience = try c.decodeIfPresent(ExperienceSettings.self, forKey: .experience)
            ?? .default
        // F-15: fields added post-v1; older profiles decode to .auto + no overrides
        // (no schema bump). An unknown layout raw string (from a newer build or a
        // hand-edited store) degrades to .auto instead of failing the load, and the
        // override list is clamped to the model cap on decode too.
        let rawLayout = (try? c.decodeIfPresent(String.self, forKey: .keyboardLayout)) ?? nil
        keyboardLayout = rawLayout.flatMap(KeyboardLayoutPreset.init(rawValue:)) ?? .auto
        let rawOverrides = ((try? c.decodeIfPresent([KeyOverride].self, forKey: .keyOverrides)) ?? nil) ?? []
        keyOverrides = Array(rawOverrides.prefix(Self.maxKeyOverrides))
        // PERF-9: field added post-v1; older profiles decode to both-on (no schema bump).
        videoDecoding = try c.decodeIfPresent(VideoDecodingSettings.self, forKey: .videoDecoding)
            ?? .default
        // F-27: field added post-v1. Defaults to FALSE — a feature that types a secret
        // into an unverified target must never arrive switched on by a store upgrade.
        passwordTypingEnabled = try c.decodeIfPresent(Bool.self, forKey: .passwordTypingEnabled)
            ?? false
        // Field added post-v1. Missing or unknown values (a newer build, a hand-edited
        // store) fall back to `.ask`: a store upgrade must never weaken verification.
        let rawCertMode = (try? c.decodeIfPresent(String.self, forKey: .certificateMode)) ?? nil
        certificateMode = rawCertMode.flatMap(CertificateCheckMode.init(rawValue:)) ?? .ask
    }
}

// MARK: - Server certificate handling

/// How a connection treats the certificate the server presents.
public enum CertificateCheckMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// Review every certificate that isn't already trusted: a first-seen certificate
    /// and a changed one both stop the connection until you approve them.
    case ask
    /// Trust a first-seen certificate automatically and remember its fingerprint.
    /// A certificate that later CHANGES still stops the connection for review.
    case trustFirstUse
    /// Accept whatever certificate the server presents, without remembering or checking
    /// it. Offers no protection against interception.
    case ignore
}

// MARK: - F-15: keyboard layout presets + scancode overrides

/// F-15: remote keyboard LAYOUT preset. The raw KBD_* layout id (from FreeRDP's
/// freerdp/locale/keyboard.h, which mirrors Windows KLIDs) is what the client
/// announces to the server at connect (FreeRDP_KeyboardLayout) — the server picks its
/// keyboard driver from it, so it matters as much as the client-side scancode mapping.
/// `.auto` = don't set it at all (FreeRDP's own default), the pre-F-15 behavior.
public enum KeyboardLayoutPreset: String, Codable, Equatable, Sendable, CaseIterable {
    case auto
    case us               // KBD_US
    case usInternational  // KBD_UNITED_STATES_INTERNATIONAL
    case uk               // KBD_UNITED_KINGDOM
    case german           // KBD_GERMAN
    case french           // KBD_FRENCH
    case spanish          // KBD_SPANISH
    case italian          // KBD_ITALIAN
    case swissGerman      // KBD_SWISS_GERMAN
    case swissFrench      // KBD_SWISS_FRENCH
    case danish           // KBD_DANISH
    case swedish          // KBD_SWEDISH
    case norwegian        // KBD_NORWEGIAN
    case dutch            // KBD_DUTCH
    case belgianFrench    // KBD_BELGIAN_FRENCH
    case portuguese       // KBD_PORTUGUESE
    case brazilian        // KBD_PORTUGUESE_BRAZILIAN_ABNT
    case japanese         // KBD_JAPANESE
    case korean           // KBD_KOREAN
    case canadianFrench   // KBD_CANADIAN_FRENCH (0x1009; 0xC0C is the LEGACY variant)

    /// The KBD_* id sent as FreeRDP_KeyboardLayout. 0 == unset (`.auto`): the bridge
    /// leaves the setting alone. Values verified against
    /// /opt/homebrew/include/freerdp3/freerdp/locale/keyboard.h (FreeRDP 3.27).
    public var kbdID: UInt32 {
        switch self {
        case .auto:            return 0
        case .us:              return 0x0000_0409
        case .usInternational: return 0x0002_0409
        case .uk:              return 0x0000_0809
        case .german:          return 0x0000_0407
        case .french:          return 0x0000_040C
        case .spanish:         return 0x0000_040A
        case .italian:         return 0x0000_0410
        case .swissGerman:     return 0x0000_0807
        case .swissFrench:     return 0x0000_100C
        case .danish:          return 0x0000_0406
        case .swedish:         return 0x0000_041D
        case .norwegian:       return 0x0000_0414
        case .dutch:           return 0x0000_0413
        case .belgianFrench:   return 0x0000_080C
        case .portuguese:      return 0x0000_0816
        case .brazilian:       return 0x0000_0416
        case .japanese:        return 0x0000_0411
        case .korean:          return 0x0000_0412
        case .canadianFrench:  return 0x0000_1009
        }
    }

    /// Human-readable name for the editor picker.
    public var displayName: String {
        switch self {
        case .auto:            return "Automatic"
        case .us:              return "US"
        case .usInternational: return "US International"
        case .uk:              return "UK"
        case .german:          return "German"
        case .french:          return "French"
        case .spanish:         return "Spanish"
        case .italian:         return "Italian"
        case .swissGerman:     return "Swiss German"
        case .swissFrench:     return "Swiss French"
        case .danish:          return "Danish"
        case .swedish:         return "Swedish"
        case .norwegian:       return "Norwegian"
        case .dutch:           return "Dutch"
        case .belgianFrench:   return "Belgian French"
        case .portuguese:      return "Portuguese"
        case .brazilian:       return "Brazilian (ABNT)"
        case .japanese:        return "Japanese"
        case .korean:          return "Korean"
        case .canadianFrench:  return "Canadian French"
        }
    }

    /// Picker order: Automatic first, then alphabetical by display name.
    public static var pickerOrder: [KeyboardLayoutPreset] {
        [.auto] + allCases.filter { $0 != .auto }
                          .sorted { $0.displayName < $1.displayName }
    }
}

/// F-15: one per-connection scancode override — "when macOS virtual key `macKeyCode`
/// is pressed, send this PC/AT Set-1 `scancode` (with the E0 prefix when `extended`)
/// instead of the standard table's entry". Applied by the mapper BEFORE the standard
/// table and before the unicode fallback: an explicit user remap always wins.
public struct KeyOverride: Codable, Equatable, Sendable {
    public var macKeyCode: UInt16   // NSEvent.keyCode (hardware-position virtual key)
    public var scancode: UInt16     // PC/AT Set-1 make code
    public var extended: Bool       // true => E0-prefixed key

    public init(macKeyCode: UInt16, scancode: UInt16, extended: Bool = false) {
        self.macKeyCode = macKeyCode
        self.scancode = scancode
        self.extended = extended
    }
}

/// F-2: per-connection "experience"/performance settings.
///
/// The persisted model is a PROFILE plus custom knobs; presets are resolved in Swift
/// (`resolved()`) into a concrete knob set + RDP connection-type hint, and the C bridge
/// applies those values verbatim. `.auto` (the default) resolves to `nil` = "override
/// nothing": the bridge keeps its built-in defaults (network autodetect + eye-candy-off
/// performance flags + 32-bit color), so legacy profiles behave exactly as before.
public struct ExperienceSettings: Codable, Equatable, Sendable {
    public enum Profile: String, Codable, Equatable, Sendable, CaseIterable {
        case auto          // default: bridge defaults + FreeRDP network autodetect
        case lan           // everything on, 32-bit
        case broadband     // wallpaper off, smoothing + themes on, 32-bit
        case lowBandwidth  // everything off, 16-bit (F-17's low-bandwidth half)
        case custom        // the individual knobs below
    }

    /// Session color depth in bits per pixel (raw value IS the bpp).
    public enum ColorDepth: Int, Codable, Equatable, Sendable, CaseIterable {
        case depth16 = 16
        case depth24 = 24
        case depth32 = 32
    }

    /// MS-RDPBCGR connection-type hint (raw values are the protocol's CONNECTION_TYPE_*).
    public enum ConnectionType: UInt32, Equatable, Sendable {
        case modem = 1, broadbandLow = 2, satellite = 3
        case broadbandHigh = 4, wan = 5, lan = 6, autodetect = 7
    }

    public static let `default` = ExperienceSettings()

    public var profile: Profile
    // Custom knobs — consulted only when `profile == .custom` (presets ignore them).
    // Defaults mirror the bridge's historical behavior (all eye candy off, 32-bit), so
    // switching a profile to Custom starts from what the connection was already doing.
    public var showWallpaper: Bool
    public var fontSmoothing: Bool
    public var fullWindowDrag: Bool   // show window contents while dragging
    public var menuAnimations: Bool
    public var themes: Bool           // visual styles
    public var colorDepth: ColorDepth

    public init(profile: Profile = .auto, showWallpaper: Bool = false,
                fontSmoothing: Bool = false, fullWindowDrag: Bool = false,
                menuAnimations: Bool = false, themes: Bool = false,
                colorDepth: ColorDepth = .depth32) {
        self.profile = profile
        self.showWallpaper = showWallpaper
        self.fontSmoothing = fontSmoothing
        self.fullWindowDrag = fullWindowDrag
        self.menuAnimations = menuAnimations
        self.themes = themes
        self.colorDepth = colorDepth
    }

    // Tolerant decoding: missing keys default, and (matching the clamp-on-decode spirit
    // of ReconnectPolicy/StayAwake) an unknown profile string or bogus color depth from
    // a hand-edited store degrades to the safe default instead of failing the load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawProfile = (try? c.decodeIfPresent(String.self, forKey: .profile)) ?? nil
        profile = rawProfile.flatMap(Profile.init(rawValue:)) ?? .auto
        showWallpaper = ((try? c.decodeIfPresent(Bool.self, forKey: .showWallpaper)) ?? nil) ?? false
        fontSmoothing = ((try? c.decodeIfPresent(Bool.self, forKey: .fontSmoothing)) ?? nil) ?? false
        fullWindowDrag = ((try? c.decodeIfPresent(Bool.self, forKey: .fullWindowDrag)) ?? nil) ?? false
        menuAnimations = ((try? c.decodeIfPresent(Bool.self, forKey: .menuAnimations)) ?? nil) ?? false
        themes = ((try? c.decodeIfPresent(Bool.self, forKey: .themes)) ?? nil) ?? false
        let rawDepth = (try? c.decodeIfPresent(Int.self, forKey: .colorDepth)) ?? nil
        colorDepth = rawDepth.flatMap(ColorDepth.init(rawValue:)) ?? .depth32
    }

    /// The concrete values a non-`.auto` profile applies at connect.
    /// `networkAutoDetect` stays ON for every profile: it only feeds the RTT/bandwidth
    /// measurement (quality indicator) and lets the server refine encoding — the
    /// enforced savings come from the client-declared performance flags + color depth,
    /// which autodetect cannot override.
    public struct Resolved: Equatable, Sendable {
        public var showWallpaper: Bool
        public var fontSmoothing: Bool
        public var fullWindowDrag: Bool
        public var menuAnimations: Bool
        public var themes: Bool
        public var colorDepth: ColorDepth
        public var connectionType: ConnectionType
        public var networkAutoDetect: Bool

        public init(showWallpaper: Bool, fontSmoothing: Bool, fullWindowDrag: Bool,
                    menuAnimations: Bool, themes: Bool, colorDepth: ColorDepth,
                    connectionType: ConnectionType, networkAutoDetect: Bool = true) {
            self.showWallpaper = showWallpaper
            self.fontSmoothing = fontSmoothing
            self.fullWindowDrag = fullWindowDrag
            self.menuAnimations = menuAnimations
            self.themes = themes
            self.colorDepth = colorDepth
            self.connectionType = connectionType
            self.networkAutoDetect = networkAutoDetect
        }
    }

    /// Pure preset resolution. `nil` == `.auto` == "override nothing at the bridge":
    /// the ONLY profile that changes no connect setting, guaranteeing legacy behavior.
    ///
    ///  profile        wallpaper smoothing drag  anims themes depth  connection type
    ///  .lan           on        on        on    on    on     32     LAN
    ///  .broadband     off       on        off   off   on     32     BROADBAND_HIGH
    ///  .lowBandwidth  off       off       off   off   off    16     BROADBAND_LOW
    ///  .custom        (the stored knobs)                            AUTODETECT
    ///
    /// `.lowBandwidth` hints CONNECTION_TYPE_BROADBAND_LOW rather than MODEM: MODEM
    /// declares a <56 kbit/s link — a class modern servers may degrade far beyond what
    /// helps (and we already turn every feature off ourselves); BROADBAND_LOW matches
    /// the real target (tethering / hotel Wi-Fi, 256 kbps–2 Mbps).
    public func resolved() -> Resolved? {
        switch profile {
        case .auto:
            return nil
        case .lan:
            return Resolved(showWallpaper: true, fontSmoothing: true, fullWindowDrag: true,
                            menuAnimations: true, themes: true, colorDepth: .depth32,
                            connectionType: .lan)
        case .broadband:
            return Resolved(showWallpaper: false, fontSmoothing: true, fullWindowDrag: false,
                            menuAnimations: false, themes: true, colorDepth: .depth32,
                            connectionType: .broadbandHigh)
        case .lowBandwidth:
            return Resolved(showWallpaper: false, fontSmoothing: false, fullWindowDrag: false,
                            menuAnimations: false, themes: false, colorDepth: .depth16,
                            connectionType: .broadbandLow)
        case .custom:
            return Resolved(showWallpaper: showWallpaper, fontSmoothing: fontSmoothing,
                            fullWindowDrag: fullWindowDrag, menuAnimations: menuAnimations,
                            themes: themes, colorDepth: colorDepth,
                            connectionType: .autodetect)
        }
    }
}

/// F-20: per-connection automatic-reconnect policy (LIFE-3/LIFE-4 hardened).
///
/// Bounds are enforced on BOTH init and decode so no persisted or programmatic value can
/// weaken the signed-off invariants:
///   - `maxAttempts` clamps to 0...5 (0 == auto-reconnect disabled);
///   - `minDelaySeconds` clamps to 5...60 — per-connection config may RAISE the delay
///     before an automatic attempt, never lower it below the 5 s floor.
/// Automatic attempts never re-prompt Touch ID regardless of these values (the reuse rule
/// lives in `CredentialPolicy.authDirective(for:)`, not here).
public struct ReconnectPolicy: Codable, Equatable, Sendable {
    public static let attemptsRange: ClosedRange<Int> = 0...5
    public static let delayRange: ClosedRange<Double> = 5...60
    /// Today's global behavior: enabled, exactly one automatic attempt, 5 s floor.
    public static let `default` = ReconnectPolicy()

    /// Master toggle ("Automatically reconnect after a drop").
    public var enabled: Bool
    /// Blind-retry budget per drop episode (clamped 0...5; 0 == disabled).
    public var maxAttempts: Int
    /// Minimum delay before ANY automatic attempt (clamped 5...60 s; 5 s floor is LIFE-3).
    public var minDelaySeconds: Double

    /// The attempts budget the engine actually uses: 0 when the toggle is off.
    public var effectiveMaxAttempts: Int { enabled ? maxAttempts : 0 }

    public init(enabled: Bool = true, maxAttempts: Int = 1, minDelaySeconds: Double = 5) {
        self.enabled = enabled
        self.maxAttempts = Self.clampAttempts(maxAttempts)
        self.minDelaySeconds = Self.clampDelay(minDelaySeconds)
    }

    // Clamp on decode too, so a hand-edited/legacy store can't exceed the bounds.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        maxAttempts = Self.clampAttempts(try c.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 1)
        minDelaySeconds = Self.clampDelay(
            try c.decodeIfPresent(Double.self, forKey: .minDelaySeconds) ?? 5)
    }

    public static func clampAttempts(_ n: Int) -> Int {
        min(max(n, attemptsRange.lowerBound), attemptsRange.upperBound)
    }
    public static func clampDelay(_ s: Double) -> Double {
        min(max(s, delayRange.lowerBound), delayRange.upperBound)
    }
}

/// F-10: per-connection keyboard modifier setting. `.useGlobal` defers to the app-wide
/// preference; the other cases pin an explicit `ModifierMode` for this host only.
public enum ModifierModeOverride: String, Codable, Equatable, Sendable, CaseIterable {
    case useGlobal   // default: follow the app-wide Cmd-key preference
    case cmdAsCtrl   // this host: Mac Cmd -> Windows Ctrl
    case literal     // this host: Cmd -> Windows/Super; Ctrl -> Ctrl

    /// Resolve against the app-wide mode: an explicit override wins, `.useGlobal` defers.
    public func resolved(global: ModifierMode) -> ModifierMode {
        switch self {
        case .useGlobal: return global
        case .cmdAsCtrl: return .cmdAsCtrl
        case .literal:   return .literal
        }
    }
}

public enum RDPSecurity: String, Codable, Sendable, CaseIterable {
    case nla        // preferred: TLS + CredSSP
    case tls        // TLS without NLA
    case rdpLegacy  // legacy RDP security (opt-in, insecure)
}

public struct DisplaySettings: Codable, Equatable, Sendable {
    public enum ScaleMode: String, Codable, Sendable, CaseIterable {
        case dynamic     // remote resolution follows the window (default, single display)
        case fitToWindow // scale the remote image to fit
        case oneToOne    // 1:1 pixels with scrolling
    }
    public var width: Int
    public var height: Int
    public var useHiDPI: Bool       // legacy; retained for back-compat (no longer drives DPI)
    public var scaleMode: ScaleMode
    /// Server-side DPI scaling percentage (the "zoom"): 100 = native, 150 = 1.5×, etc.
    /// Sent to the host as DesktopScaleFactor. Per-connection.
    public var scaleFactor: Int
    /// Span the session across all attached Mac displays as multiple remote monitors.
    /// When on, the remote desktop is the union of the local screens and the in-session
    /// window-follow resize is disabled (the layout is fixed at connect).
    public var useAllDisplays: Bool
    /// #22: with `useAllDisplays` on, present the spanned session as ONE WINDOW PER MAC
    /// DISPLAY (each window shows that display's crop of the single spanned framebuffer)
    /// instead of one spanned canvas. Presentation-only — the RDP session itself is
    /// unchanged. Applies at the next connect; ignored when `useAllDisplays` is off.
    public var perDisplayWindows: Bool
    public init(width: Int = 1280, height: Int = 800, useHiDPI: Bool = true,
                scaleMode: ScaleMode = .dynamic, scaleFactor: Int = 100,
                useAllDisplays: Bool = false, perDisplayWindows: Bool = false) {
        self.width = width; self.height = height
        self.useHiDPI = useHiDPI; self.scaleMode = scaleMode
        self.scaleFactor = scaleFactor; self.useAllDisplays = useAllDisplays
        self.perDisplayWindows = perDisplayWindows
    }

    // Custom decoding tolerates connections saved before a field existed (e.g.
    // `scaleFactor`), defaulting missing keys instead of failing the whole load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1280
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 800
        useHiDPI = try c.decodeIfPresent(Bool.self, forKey: .useHiDPI) ?? true
        scaleMode = try c.decodeIfPresent(ScaleMode.self, forKey: .scaleMode) ?? .dynamic
        scaleFactor = try c.decodeIfPresent(Int.self, forKey: .scaleFactor) ?? 100
        useAllDisplays = try c.decodeIfPresent(Bool.self, forKey: .useAllDisplays) ?? false
        perDisplayWindows = try c.decodeIfPresent(Bool.self, forKey: .perDisplayWindows) ?? false
    }
}

public struct GatewaySettings: Codable, Equatable, Sendable {
    public var hostname: String
    public var port: Int
    public var username: String?  // defaults to connection username
    public var domain: String?
    /// F-6: when true, the gateway authenticates with its OWN password (a second vault
    /// secret, `CredentialKind.gateway`) instead of the connection's main credentials.
    /// Default false = pre-F-6 behavior (gateway uses the main credentials).
    public var useSeparateCredentials: Bool

    public init(hostname: String, port: Int = 443, username: String? = nil,
                domain: String? = nil, useSeparateCredentials: Bool = false) {
        self.hostname = hostname; self.port = port
        self.username = username; self.domain = domain
        self.useSeparateCredentials = useSeparateCredentials
    }

    // F-6: field added post-v1; legacy gateway JSON (no key) decodes to false — exactly
    // today's behavior. Mirrors the tolerant-decode pattern used across the models.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 443
        username = try c.decodeIfPresent(String.self, forKey: .username)
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        useSeparateCredentials = try c.decodeIfPresent(Bool.self, forKey: .useSeparateCredentials) ?? false
    }
}

// Per-connection credential policy (PRD FR-2.7).
public enum CredentialPolicy: Codable, Equatable, Sendable {
    case biometricEveryConnect              // default: Touch ID on every connect
    case biometricReuse(seconds: Int)       // reuse a recent Touch ID briefly (OS-capped at 5 min)
    case savedNoBiometric                   // still gated: uses the maximum OS-allowed reuse window
}
