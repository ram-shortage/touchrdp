import SwiftUI
import AppKit
import TouchRDPCore
import TouchRDPEngine

struct ConnectionEditorView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    /// Which group of sections the sheet shows. Always opens on Connection.
    @State private var tab: EditorTab = .connection

    private let isNew: Bool
    private let onSave: (Connection) throws -> Void

    // Local editing state
    @State private var connection: Connection
    @State private var password: String = ""
    // POL-3 / F-12: reveal the password field to check what was typed (eye toggle below).
    @State private var revealPassword = false
    @State private var isRevealingSaved = false
    @State private var showGateway: Bool
    // F-6: separate RD Gateway credential. The gateway password is a SECOND vault
    // secret (kind .gateway) — same tier/policy as the primary, never in the model.
    @State private var useSeparateGatewayCreds: Bool
    @State private var gatewayPassword: String = ""
    @State private var revealGatewayPassword = false
    @State private var showValidationError = false
    @State private var validationMessage = ""
    // The certificate pinned for the host currently in the field, re-read whenever that
    // host/port changes so the Security section never describes a different server.
    @State private var pinnedCert: PinnedCertRecord?
    @State private var showForgetCertConfirm = false
    // Whether the user has typed into the credential fields yet. A new connection starts
    // blank, so the "required" warnings would otherwise greet an untouched form.
    @State private var usernameTouched = false
    @State private var passwordTouched = false
    // Scale mode via an intermediate @State (mirrors the credential-policy pattern):
    // a Picker bound directly to the nested `$connection.display.scaleMode` path with
    // `ForEach(id: \.self)` + `.tag()` doesn't reliably write back, so the selection
    // appeared to "reset". We bind to this and fold it into the model on save.
    @State private var scaleMode: DisplaySettings.ScaleMode
    // Zoom (server-side DPI %) — intermediate @State for the same reason as scaleMode.
    @State private var scaleFactor: Int
    @State private var useHiDPI: Bool
    @State private var useAllDisplays: Bool
    // #22: one window per display (presentation of the spanned session; applies at
    // the next connect). Shown only while "Use all displays" is on.
    @State private var perDisplayWindows: Bool

    // Credential policy helpers
    @State private var policySelection: CredentialPolicyOption = .biometricEveryConnect
    @State private var reuseSeconds: Int = 300

    // F-20: reconnect policy via intermediate @State (same write-back reasoning as
    // scaleMode above), folded into the model on save. `enabled` is normalized so a
    // stored `maxAttempts == 0` (also "disabled") presents as toggle-off with 1 attempt.
    @State private var reconnectEnabled: Bool
    @State private var reconnectAttempts: Int
    @State private var reconnectDelay: Int   // seconds, 5–60

    // F-26: stay-awake cap in minutes (1–60, default 5), folded back in on save. Only
    // the cap persists — the Stay Awake toggle itself is per-session and always starts off.
    @State private var stayAwakeCapMinutes: Int

    // F-15: keyboard layout preset via intermediate @State (same write-back reasoning
    // as scaleMode above) + editable scancode-override rows (UUID-keyed so ForEach has
    // stable identity while editing); both folded into the model on save.
    @State private var keyboardLayout: KeyboardLayoutPreset
    @State private var overrideRows: [KeyOverrideRow]

    // F-2: experience profile + custom knobs via intermediate @State (same nested-path
    // write-back reasoning as scaleMode above), folded into the model on save.
    @State private var expProfile: ExperienceSettings.Profile
    @State private var expShowWallpaper: Bool
    @State private var expFontSmoothing: Bool
    @State private var expFullWindowDrag: Bool
    @State private var expMenuAnimations: Bool
    @State private var expThemes: Bool
    @State private var expColorDepth: ExperienceSettings.ColorDepth

    init(connection: Connection, isNew: Bool, onSave: @escaping (Connection) throws -> Void) {
        self._connection = State(initialValue: connection)
        self._showGateway = State(initialValue: connection.gateway != nil)
        self._useSeparateGatewayCreds = State(initialValue:
            connection.gateway?.useSeparateCredentials ?? false)
        self._scaleMode = State(initialValue: connection.display.scaleMode)
        self._scaleFactor = State(initialValue: connection.display.scaleFactor)
        self._useHiDPI = State(initialValue: connection.display.useHiDPI)
        self._useAllDisplays = State(initialValue: connection.display.useAllDisplays)
        self._perDisplayWindows = State(initialValue: connection.display.perDisplayWindows)
        let policy = connection.reconnectPolicy
        self._reconnectEnabled = State(initialValue: policy.enabled && policy.maxAttempts > 0)
        self._reconnectAttempts = State(initialValue: max(1, policy.maxAttempts))
        self._reconnectDelay = State(initialValue: Int(ReconnectPolicy.clampDelay(policy.minDelaySeconds)))
        self._stayAwakeCapMinutes = State(initialValue:
            Int((StayAwake.clampCap(connection.stayAwakeCapSeconds) / 60).rounded()))
        self._keyboardLayout = State(initialValue: connection.keyboardLayout)
        self._overrideRows = State(initialValue: connection.keyOverrides.map(KeyOverrideRow.init))
        let exp = connection.experience
        self._expProfile = State(initialValue: exp.profile)
        self._expShowWallpaper = State(initialValue: exp.showWallpaper)
        self._expFontSmoothing = State(initialValue: exp.fontSmoothing)
        self._expFullWindowDrag = State(initialValue: exp.fullWindowDrag)
        self._expMenuAnimations = State(initialValue: exp.menuAnimations)
        self._expThemes = State(initialValue: exp.themes)
        self._expColorDepth = State(initialValue: exp.colorDepth)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(isNew ? "New Connection" : "Edit Connection")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button(isNew ? "Add" : "Save") { attemptSave() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Picker("Section", selection: $tab) {
                ForEach(EditorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 10)

            // A grouped Form scrolls on its own, so it needs no outer ScrollView.
            Form {
                switch tab {
                case .connection:
                    generalSection
                    credentialsSection
                    securitySection
                    gatewaySection
                case .display:
                    displaySection
                    experienceSection
                    videoSection
                case .behaviour:
                    reconnectSection
                    stayAwakeSection
                    lockScreenSection
                    keyboardSection
                    redirectionSection
                }
            }
            .formStyle(.grouped)
        }
        // Flexible height: the old fixed 680 pt sheet overflowed a small main window.
        .frame(width: 560)
        .frame(minHeight: 360, idealHeight: 560, maxHeight: 720)
        .alert("Validation Error", isPresented: $showValidationError) {
            Button("OK") {}
        } message: {
            Text(validationMessage)
        }
        .alert("Forget this certificate?", isPresented: $showForgetCertConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { forgetCertificate() }
        } message: {
            Text("TouchRDP will no longer trust the approved certificate for \(certHostLabel). The next connection will ask you to review the server's certificate before connecting.")
        }
        .onAppear {
            syncPolicyFromModel()
            refreshPinnedCert()
        }
        .onChange(of: connection.host) { refreshPinnedCert() }
        .onChange(of: connection.port) { refreshPinnedCert() }
        .onChange(of: connection.username) { usernameTouched = true }
        .onChange(of: password) { passwordTouched = true }
    }

    // MARK: - Sections

        // MARK: General
    @ViewBuilder
    private var generalSection: some View {
        Section("General") {
            TextField("Display Name", text: $connection.name)
                .accessibilityLabel("Connection display name")

            HStack {
                TextField("Host / IP", text: $connection.host)
                    .accessibilityLabel("Remote host address")
                Text(":")
                    .foregroundStyle(.secondary)
                TextField("Port", value: $connection.port, formatter: portFormatter)
                    .frame(width: 70)
                    .accessibilityLabel("Port number")
            }

            TextField("Username", text: $connection.username)
                .textContentType(.username)
                .accessibilityLabel("Username")

            // Flag the gap, don't scold an empty form: a brand-new connection
            // opens with every field blank, so warn only once the field has
            // been used and left empty, or when a SAVED profile is missing a
            // username (the legacy/imported case that reaches connect).
            if showUsernameWarning {
                Label("A username is required before connecting.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            TextField("Domain (optional)", text: Binding(
                get: { connection.domain ?? "" },
                set: { connection.domain = $0.isEmpty ? nil : $0 }
            ))
            .accessibilityLabel("Windows domain, optional")

            TextField("Group (optional)", text: Binding(
                get: { connection.groupName ?? "" },
                set: { connection.groupName = $0.isEmpty ? nil : $0 }
            ))
            .accessibilityLabel("Connection group name, optional")
        }
    }

        // MARK: Credentials
    @ViewBuilder
    private var credentialsSection: some View {
        Section("Credentials") {
            HStack {
                Group {
                    if revealPassword {
                        TextField("Password (leave blank to keep existing)", text: $password)
                    } else {
                        SecureField("Password (leave blank to keep existing)", text: $password)
                    }
                }
                .textContentType(.password)
                .accessibilityLabel("Password — leave blank to keep existing saved password")

                Button {
                    revealPassword.toggle()
                } label: {
                    Image(systemName: revealPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealPassword ? "Hide what you typed" : "Show what you typed")
                .accessibilityLabel(revealPassword ? "Hide password" : "Show password")
            }

            // Same rule as the username warning: an untouched new form is not
            // yet a mistake. `attemptSave` is what actually enforces the pair.
            if showPasswordWarning {
                Label("A password is required before connecting.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // The field above is write-only: it never loads the saved secret
            // (that needs Touch ID), so the eye only reveals what was typed
            // this time. Offer an explicit, biometric-gated way to see what
            // is actually stored — the question "is it saving correctly?"
            // deserves a real answer, not a blank field.
            if !isNew, coordinator.hasPassword(for: connection) {
                HStack(alignment: .firstTextBaseline) {
                    Text("A password is saved. The field never shows it; type here only to replace it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Saved Password…") { revealSavedPassword() }
                        .disabled(isRevealingSaved)
                        .help("Unlock the saved password with Touch ID and show it in the field, so you can check exactly what is stored")
                        .accessibilityLabel("Show the saved password (requires Touch ID)")
                }
            }

            Text("Protected by: \(coordinator.vaultTierLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Policy", selection: $policySelection) {
                Text("Touch ID on every connect").tag(CredentialPolicyOption.biometricEveryConnect)
                Text("Cache Touch ID briefly").tag(CredentialPolicyOption.biometricReuse)
                Text("Minimal prompts").tag(CredentialPolicyOption.savedNoBiometric)
            }
            .accessibilityLabel("Credential policy")

            if policySelection == .biometricReuse {
                // macOS caps Touch ID reuse at 5 minutes; offering longer would
                // be misleading since the OS re-prompts past that window.
                Stepper("Don't re-ask for \(reuseSeconds / 60) min",
                        value: $reuseSeconds, in: 60...maxReuseSeconds, step: 60)
                    .accessibilityLabel("Biometric reuse duration in minutes")
            }

            Text(policyFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)

            // F-25: surface the LIFE-3 reconnect-reuse rule where credentials
            // are configured (wording aligned with docs/SECURITY.md). Kept
            // generic so it stays truthful for any Reconnect policy (F-20).
            Text("Manual connects prompt Touch ID according to the policy above. After a connection drop, automatic reconnects (configured in the Reconnect section) reuse that authentication without a new prompt. When automatic retries run out, reconnecting is manual again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

        // MARK: Reconnect (F-20: per-connection auto-reconnect policy)
    @ViewBuilder
    private var reconnectSection: some View {
        Section("Reconnect") {
            Toggle("Automatically reconnect after a drop", isOn: $reconnectEnabled)
                .accessibilityLabel("Automatically reconnect after a connection drop")

            if reconnectEnabled {
                Stepper("Attempts: \(reconnectAttempts)",
                        value: $reconnectAttempts, in: 1...5)
                    .accessibilityLabel("Automatic reconnect attempts, one to five")

                Stepper("Wait at least \(reconnectDelay) s before retrying",
                        value: $reconnectDelay, in: 5...60, step: 5)
                    .accessibilityLabel("Minimum delay before an automatic reconnect, in seconds")

                Text("Automatic retries never re-prompt Touch ID — attempts beyond the first reuse the same authentication. The delay can be raised, but never below the 5-second minimum.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("After a drop, this connection waits for you to reconnect manually (which prompts Touch ID per the credential policy).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

        // MARK: Stay awake (F-26: bounded remote-lock deferral — cap only;
        // the toggle itself is per-session and never persisted)
    @ViewBuilder
    private var stayAwakeSection: some View {
        Section("Stay Awake") {
            Stepper("Stay awake cap: \(stayAwakeCapMinutes) min",
                    value: $stayAwakeCapMinutes, in: 1...60)
                .accessibilityLabel("Stay awake cap in minutes, one to sixty")

            Text("The Stay Awake button keeps the remote session from locking for up to this long; real activity restarts the countdown. It always starts off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

        // MARK: Security
    @ViewBuilder
    private var securitySection: some View {
        Section("Security") {
            Picker("Protocol", selection: $connection.security) {
                ForEach(RDPSecurity.allCases, id: \.self) { s in
                    Text(s.displayLabel).tag(s)
                }
            }
            .accessibilityLabel("RDP security protocol")

            // The TOFU pin is keyed by host:port, not by connection id, so it
            // is shown against whatever host is currently in the field above.
            // Approving a certificate is a one-way door without this: there was
            // no way to re-review one, or to undo an approval, short of editing
            // trust.json by hand.
            if let pinned = pinnedCert {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Certificate approved for \(certHostLabel)")
                            .font(.caption)
                        Spacer()
                        Button("Forget…") { showForgetCertConfirm = true }
                            .help("Forget this certificate so the next connection asks you to review the server's certificate again")
                            .accessibilityLabel("Forget the approved certificate for this host")
                    }
                    Text(pinned.fingerprintSHA256)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityLabel("Approved certificate fingerprint")
                    if let pinnedAt = pinned.pinnedAt {
                        Text("Approved \(pinnedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No certificate is approved for \(certHostLabel). The next connection will ask you to review the server's certificate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

        // MARK: Display
    @ViewBuilder
    private var displaySection: some View {
        Section("Display") {
            Picker("Resolution", selection: resolutionPreset) {
                Text("1280 × 800").tag(ResolutionPreset.r1280x800)
                Text("1440 × 900").tag(ResolutionPreset.r1440x900)
                Text("1920 × 1080").tag(ResolutionPreset.r1920x1080)
                Text("2560 × 1440").tag(ResolutionPreset.r2560x1440)
                Text("Custom").tag(ResolutionPreset.custom)
            }
            .accessibilityLabel("Display resolution preset")

            if resolutionPreset.wrappedValue == .custom {
                HStack {
                    TextField("Width", value: $connection.display.width, formatter: dimensionFormatter)
                        .frame(width: 80)
                        .accessibilityLabel("Custom display width")
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", value: $connection.display.height, formatter: dimensionFormatter)
                        .frame(width: 80)
                        .accessibilityLabel("Custom display height")
                }
            }

            Picker("Zoom", selection: $scaleFactor) {
                Text("100% (native)").tag(100)
                Text("125%").tag(125)
                Text("150%").tag(150)
                Text("175%").tag(175)
                Text("200%").tag(200)
                Text("250%").tag(250)
            }
            .accessibilityLabel("Remote display zoom (server DPI scaling)")

            Picker("Scale Mode", selection: $scaleMode) {
                ForEach(DisplaySettings.ScaleMode.allCases, id: \.self) { mode in
                    Text(mode.displayLabel).tag(mode)
                }
            }
            .accessibilityLabel("Display scale mode")

            Toggle("Retina (HiDPI)", isOn: $useHiDPI)
                .accessibilityLabel("Retina HiDPI for Auto mode")

            Toggle("Use all displays (multi-monitor)", isOn: $useAllDisplays)
                .accessibilityLabel("Span the session across all attached displays")
            if useAllDisplays {
                Text("Spans every attached Mac display as remote monitors. The session window shows the whole desktop; window-follow resizing is off in this mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // #22: presentation split of the spanned session.
                Toggle("One window per display", isOn: $perDisplayWindows)
                    .accessibilityLabel("Show one session window per Mac display")
                Text("Each Mac display gets its own full-screen-style window showing that display's portion of the remote desktop. Changing this applies at the next connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if scaleMode == .dynamic {
                Text("Auto follows the window; Zoom sets the remote UI size and is pinned for the whole session. Retina on = full-resolution pixels; off = more workspace. Resolution below applies to Fit and 1:1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Resolution applies to Fit and 1:1. Zoom applies to every mode (pinned per session). Retina applies to Auto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

        // MARK: Experience (F-2: per-connection performance profile;
        // .lowBandwidth is F-17's low-bandwidth half)
    @ViewBuilder
    private var experienceSection: some View {
        Section("Experience") {
            Picker("Profile", selection: $expProfile) {
                Text("Automatic").tag(ExperienceSettings.Profile.auto)
                Text("LAN").tag(ExperienceSettings.Profile.lan)
                Text("Broadband").tag(ExperienceSettings.Profile.broadband)
                Text("Low bandwidth").tag(ExperienceSettings.Profile.lowBandwidth)
                Text("Custom").tag(ExperienceSettings.Profile.custom)
            }
            .accessibilityLabel("Experience profile")

            if expProfile == .custom {
                Toggle("Desktop wallpaper", isOn: $expShowWallpaper)
                    .accessibilityLabel("Show the remote desktop wallpaper")
                Toggle("Font smoothing", isOn: $expFontSmoothing)
                    .accessibilityLabel("Enable remote font smoothing")
                Toggle("Window contents while dragging", isOn: $expFullWindowDrag)
                    .accessibilityLabel("Show window contents while dragging")
                Toggle("Menu animations", isOn: $expMenuAnimations)
                    .accessibilityLabel("Enable remote menu animations")
                Toggle("Visual styles (themes)", isOn: $expThemes)
                    .accessibilityLabel("Enable remote visual styles")
                Picker("Color depth", selection: $expColorDepth) {
                    Text("16-bit").tag(ExperienceSettings.ColorDepth.depth16)
                    Text("24-bit").tag(ExperienceSettings.ColorDepth.depth24)
                    Text("32-bit").tag(ExperienceSettings.ColorDepth.depth32)
                }
                .accessibilityLabel("Remote session color depth")
            }

            Text(experienceFootnote + " Applies at the next connect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

        // MARK: Video (PERF-9: per-connection H.264 decoding knobs)
    @ViewBuilder
    private var videoSection: some View {
        Section("Video") {
            Toggle("Hardware H.264 decoding", isOn: $connection.videoDecoding.hardwareDecodeEnabled)
                .accessibilityLabel("Decode H.264 frames with VideoToolbox")
            Text(connection.videoDecoding.hardwareDecodeEnabled
                 ? "Decodes on the GPU (VideoToolbox): lower CPU for video and animation, but every frame pays a fixed GPU round-trip — software decoding is often snappier for text and typing. Needs a FreeRDP built with VideoToolbox; the toolbar shows HW or SW."
                 : "Decodes on the CPU: usually the most responsive choice for desktop work; costs more CPU on video and animation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Full-colour text (AVC444)", isOn: $connection.videoDecoding.avc444Enabled)
                .accessibilityLabel("Negotiate AVC444 for full-resolution colour")
            Text(connection.videoDecoding.avc444Enabled
                 ? "Sends a second chroma stream per frame (4:4:4 colour): crisper coloured text, twice the decoding work."
                 : "AVC420 only (4:2:0 colour): half the decoding work; coloured text may fringe slightly.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Both apply at the next connect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

        // MARK: Lock screen (F-27: type the vaulted password into a live session)
    @ViewBuilder
    private var lockScreenSection: some View {
        Section("Lock Screen") {
            Toggle("Allow typing the password into this session",
                   isOn: $connection.passwordTypingEnabled)
                .accessibilityLabel("Allow TouchRDP to type the saved password into the remote lock screen")
            Text(connection.passwordTypingEnabled
                 ? "Adds a “Type Password” button to the session toolbar. It asks for Touch ID, sends Ctrl-Alt-Del, then types this connection's password and presses Return to sign in."
                 : "Off: the session toolbar has no password-typing button.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Only enable this for hosts where you trust the risk: RDP never tells the client whether the remote screen is locked, so using the button at the wrong moment types the password into whatever window has focus.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

        // MARK: Keyboard (F-10: per-connection modifier override;
        // F-15: layout preset + scancode override list)
    @ViewBuilder
    private var keyboardSection: some View {
        Section("Keyboard") {
            Picker("⌘ key on this host", selection: $connection.modifierOverride) {
                Text("Use global setting").tag(ModifierModeOverride.useGlobal)
                Text("⌘ acts as Ctrl").tag(ModifierModeOverride.cmdAsCtrl)
                Text("⌘ is literal (Windows key)").tag(ModifierModeOverride.literal)
            }
            .accessibilityLabel("Command key behavior for this connection")
            Text(modifierFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)

            // F-15: which KBD_* layout the server is told to load.
            Picker("Remote keyboard layout", selection: $keyboardLayout) {
                ForEach(KeyboardLayoutPreset.pickerOrder, id: \.self) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            .accessibilityLabel("Remote keyboard layout announced to the server")

            // F-15: minimal per-key scancode override list (no visual editor).
            ForEach($overrideRows) { $row in
                HStack(spacing: 8) {
                    KeyRecorderButton(macKeyCode: $row.macKeyCode)
                    Text("sends scancode")
                        .foregroundStyle(.secondary)
                    TextField("hex", text: $row.scancodeHex)
                        .font(.body.monospaced())
                        .frame(width: 64)
                        .accessibilityLabel("Scancode in hexadecimal")
                    Toggle("E0", isOn: $row.extended)
                        .toggleStyle(.checkbox)
                        .help("Extended key (E0-prefixed scancode)")
                        .accessibilityLabel("Extended, E0-prefixed scancode")
                    Spacer()
                    Button {
                        overrideRows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this override")
                    .accessibilityLabel("Remove this key override")
                }
            }
            Button("Add Override") {
                overrideRows.append(KeyOverrideRow())
            }
            .disabled(overrideRows.count >= Connection.maxKeyOverrides)
            .accessibilityLabel("Add a key override")

            Text("Overrides apply before the standard mapping. Layout applies at next connect."
                 + (overrideRows.count >= Connection.maxKeyOverrides
                    ? " Maximum of \(Connection.maxKeyOverrides) overrides reached." : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

        // MARK: Gateway
    @ViewBuilder
    private var gatewaySection: some View {
        Section {
            Toggle("Connect via RD Gateway", isOn: $showGateway)
                .accessibilityLabel("Enable RD Gateway")

            if showGateway {
                let gwBinding = Binding<GatewaySettings>(
                    get: { connection.gateway ?? GatewaySettings(hostname: "") },
                    set: { connection.gateway = $0 }
                )
                TextField("Gateway Host", text: gwBinding.hostname)
                    .accessibilityLabel("Gateway hostname")
                TextField("Gateway Port", value: gwBinding.port, formatter: portFormatter)
                    .accessibilityLabel("Gateway port")
                TextField("Gateway Username (optional)", text: Binding(
                    get: { gwBinding.username.wrappedValue ?? "" },
                    set: { gwBinding.username.wrappedValue = $0.isEmpty ? nil : $0 }
                ))
                .accessibilityLabel("Gateway username, optional")

                // F-6: separate gateway password (second vault secret).
                Toggle("Use separate gateway credentials", isOn: $useSeparateGatewayCreds)
                    .accessibilityLabel("Use a separate password for the RD Gateway")

                if useSeparateGatewayCreds {
                    HStack {
                        Group {
                            if revealGatewayPassword {
                                TextField("Gateway password (leave blank to keep existing)",
                                          text: $gatewayPassword)
                            } else {
                                SecureField("Gateway password (leave blank to keep existing)",
                                            text: $gatewayPassword)
                            }
                        }
                        .textContentType(.password)
                        .accessibilityLabel("Gateway password — leave blank to keep existing saved gateway password")

                        Button {
                            revealGatewayPassword.toggle()
                        } label: {
                            Image(systemName: revealGatewayPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealGatewayPassword ? "Hide gateway password" : "Show gateway password")
                        .accessibilityLabel(revealGatewayPassword ? "Hide gateway password" : "Show gateway password")
                    }
                    Text("Stored in the Keychain like the main password (\(coordinator.vaultTierLabel)). One Touch ID unlocks both at connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The gateway signs in with this connection's main credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Gateway")
        }
    }

        // MARK: Redirection
    @ViewBuilder
    private var redirectionSection: some View {
        Section("Redirection") {
            Toggle("Clipboard", isOn: $connection.clipboardEnabled)
                .accessibilityLabel("Enable clipboard redirection")
            Toggle("Sync images", isOn: $connection.imageClipboardEnabled)
                .disabled(!connection.clipboardEnabled)
                .accessibilityLabel("Also sync clipboard images")
            if connection.clipboardEnabled && connection.imageClipboardEnabled {
                Text("⚠︎ Bitmaps copied on either side cross the clipboard — a wider data path than text. Leave off unless you need it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // F-8 + #25: file clipboard, BOTH directions (Finder ⌘C / drag
            // onto the canvas → Windows; remote copy → paste in Finder).
            Toggle("Send files", isOn: $connection.fileClipboardEnabled)
                .disabled(!connection.clipboardEnabled)
                .accessibilityLabel("Sync copied files with the remote clipboard in both directions")
            if connection.clipboardEnabled && connection.fileClipboardEnabled {
                Text("⚠︎ Both directions: files you copy in Finder or drop on the session are offered to the remote clipboard (max 64 files / 256 MB, no folders) and the remote host can pull their contents while the offer stands; files copied on the remote can be pasted into Finder (max 256 MB per file / 1 GB per copy) — their contents are pulled only when you actually paste.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Audio", isOn: $connection.audioEnabled)
                .accessibilityLabel("Enable audio redirection")

            // Shared folder (drive redirection). Opt-in and explicit: the
            // remote host gets read/write access to the chosen folder.
            HStack {
                Text("Shared folder")
                Spacer()
                if let path = connection.sharedFolderPath, !path.isEmpty {
                    Text((path as NSString).lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Clear") { connection.sharedFolderPath = nil }
                        .accessibilityLabel("Stop sharing the folder")
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
                Button("Choose…") { chooseSharedFolder() }
                    .accessibilityLabel("Choose a local folder to share with the remote host")
            }
            if let path = connection.sharedFolderPath, !path.isEmpty {
                Text("⚠︎ The remote host can read AND write everything in “\(path)” for the duration of the session. Share a narrow, non-sensitive folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // F-17: printer redirection (opt-in, off by default).
            Toggle("Redirect printers", isOn: $connection.printerRedirectionEnabled)
                .accessibilityLabel("Make local printers available in the remote session")
            if connection.printerRedirectionEnabled {
                Text("Makes your Mac's printers available in the remote session (via CUPS). Applies at next connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    /// A saved profile with no username is the anomaly PR #42 targets — say so on sight.
    /// On a new connection, wait until the field has actually been used and emptied.
    private var showUsernameWarning: Bool {
        guard connection.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return !isNew || usernameTouched
    }

    /// A blank field means "keep existing" only when a secret really is stored, so the
    /// warning tracks the vault, not the field.
    private var showPasswordWarning: Bool {
        guard password.isEmpty, !coordinator.hasPassword(for: connection) else { return false }
        return !isNew || passwordTouched
    }

    /// "host:port" as the trust store keys it, for labels the user can match against
    /// what the certificate review sheet showed them.
    private var certHostLabel: String {
        let host = connection.host.trimmingCharacters(in: .whitespaces)
        return "\(host.isEmpty ? "this host" : host):\(connection.port)"
    }

    private func refreshPinnedCert() {
        let host = connection.host.trimmingCharacters(in: .whitespaces)
        pinnedCert = host.isEmpty
            ? nil
            : coordinator.pinnedCertificate(host: host, port: connection.port)
    }

    private func forgetCertificate() {
        let host = connection.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        coordinator.forgetCertificate(host: host, port: connection.port)
        refreshPinnedCert()
    }

    private func attemptSave() {
        guard !connection.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "Host is required."
            showValidationError = true
            return
        }

        let username = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            validationMessage = "Username is required before connecting."
            showValidationError = true
            return
        }
        connection.username = username

        // A blank field means "keep existing" only when an existing secret really is
        // present. New/imported profiles without one must collect it before they can be
        // saved as connectable profiles.
        guard !password.isEmpty || coordinator.hasPassword(for: connection) else {
            validationMessage = "Password is required before connecting."
            showValidationError = true
            return
        }

        // Apply credential policy
        connection.credentialPolicy = buildPolicy()

        // F-20: fold the reconnect policy back in (the initializer clamps 0...5 / 5...60).
        connection.reconnectPolicy = ReconnectPolicy(
            enabled: reconnectEnabled,
            maxAttempts: reconnectAttempts,
            minDelaySeconds: Double(reconnectDelay))

        // F-26: fold the stay-awake cap back in (the model clamps 60...3600 s).
        connection.stayAwakeCapSeconds = Double(stayAwakeCapMinutes * 60)

        // F-2: fold the experience profile + custom knobs back in.
        connection.experience = ExperienceSettings(
            profile: expProfile, showWallpaper: expShowWallpaper,
            fontSmoothing: expFontSmoothing, fullWindowDrag: expFullWindowDrag,
            menuAnimations: expMenuAnimations, themes: expThemes,
            colorDepth: expColorDepth)

        // F-15: fold the keyboard layout + valid override rows back in. Rows without a
        // recorded key or a parseable non-zero hex scancode are dropped; the model
        // additionally clamps to Connection.maxKeyOverrides.
        connection.keyboardLayout = keyboardLayout
        connection.keyOverrides = Array(
            overrideRows.compactMap { $0.toOverride() }.prefix(Connection.maxKeyOverrides))

        // Fold the intermediate display selections into the model.
        connection.display.scaleMode = scaleMode
        connection.display.scaleFactor = scaleFactor
        connection.display.useHiDPI = useHiDPI
        connection.display.useAllDisplays = useAllDisplays
        connection.display.perDisplayWindows = perDisplayWindows

        // Clear gateway if toggled off
        if !showGateway { connection.gateway = nil }

        // F-6: fold the separate-gateway-credentials choice in. The password itself
        // goes to the vault (kind .gateway) — NEVER into the model/JSON. Toggling the
        // feature off (or removing the gateway) deletes the gateway secret so no
        // orphaned Keychain item remains.
        if showGateway, connection.gateway != nil, useSeparateGatewayCreds {
            connection.gateway?.useSeparateCredentials = true
            if !gatewayPassword.isEmpty {
                do {
                    try coordinator.storeGatewayPassword(gatewayPassword, for: connection)
                } catch {
                    failSave("The gateway password could not be saved to the Keychain (\(error)).")
                    return
                }
            }
        } else {
            connection.gateway?.useSeparateCredentials = false
            try? coordinator.forgetGatewayPassword(for: connection)
        }

        // Store password if provided. A swallowed failure here used to leave the user
        // believing a password was saved; refuse the save and say why instead.
        if !password.isEmpty {
            do {
                try coordinator.storePassword(password, for: connection)
            } catch {
                failSave("The password could not be saved to the Keychain (\(error)).")
                return
            }
        }

        do {
            try onSave(connection)
            dismiss()
        } catch {
            failSave(error.localizedDescription)
        }
    }

    /// Keep the sheet open with the reason; nothing has been written to the store.
    private func failSave(_ reason: String) {
        validationMessage = reason + " The connection was not saved — please try again."
        showValidationError = true
    }

    /// Touch ID-gated reveal of the STORED password into the (revealed) field. An empty
    /// stored item — the cause of "transport layer failed" sign-ins — is called out by
    /// name so the fix (type it and save) is obvious.
    private func revealSavedPassword() {
        isRevealingSaved = true
        let id = connection.id
        let reason = "Show the saved password for \(connection.name)"
        Task { @MainActor in
            defer { isRevealingSaved = false }
            do {
                let saved = try await coordinator.vault.retrievePassword(
                    for: id, reason: reason, allowReuseSeconds: nil, forceFreshPrompt: true)
                password = saved
                revealPassword = true
            } catch VaultError.emptySecret {
                validationMessage = "The saved password for this connection is EMPTY — that is why signing in fails. Type the password and save to replace it."
                showValidationError = true
            } catch VaultError.userCancelled {
                // Nothing to report.
            } catch {
                validationMessage = "Couldn't unlock the saved password (\(error)). Type it and save to replace it."
                showValidationError = true
            }
        }
    }

    /// Pick a single local folder to share with the host (drive redirection).
    /// Validates it's a real directory before storing the path.
    private func chooseSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share Folder"
        panel.message = "Choose a folder to share with the remote host (read/write)."
        if panel.runModal() == .OK, let url = panel.url {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                connection.sharedFolderPath = url.path
            }
        }
    }

    private func buildPolicy() -> CredentialPolicy {
        switch policySelection {
        case .biometricEveryConnect: return .biometricEveryConnect
        case .biometricReuse: return .biometricReuse(seconds: reuseSeconds)
        case .savedNoBiometric: return .savedNoBiometric
        }
    }

    private func syncPolicyFromModel() {
        switch connection.credentialPolicy {
        case .biometricEveryConnect:
            policySelection = .biometricEveryConnect
        case .biometricReuse(let secs):
            policySelection = .biometricReuse
            // Clamp legacy values (older builds allowed up to 60 min) into the OS-backed range.
            reuseSeconds = min(max(secs, 60), maxReuseSeconds)
        case .savedNoBiometric:
            policySelection = .savedNoBiometric
        }
    }

    // macOS caps Touch ID reuse at LATouchIDAuthenticationMaximumAllowableReuseDuration (5 min).
    private var maxReuseSeconds: Int { KeychainCredentialVault.maxReuseSeconds }

    private var policyFootnote: String {
        switch policySelection {
        case .biometricEveryConnect:
            return "Touch ID is required for every connection (most secure)."
        case .biometricReuse:
            return "After one Touch ID, reconnects within the window skip the prompt. macOS limits reuse to \(maxReuseSeconds / 60) minutes."
        case .savedNoBiometric:
            return "Touch ID is still required, but reuse is set to the maximum macOS allows (\(maxReuseSeconds / 60) min). The password is never stored without a biometric gate."
        }
    }

    // F-2: explain what each experience profile does.
    private var experienceFootnote: String {
        switch expProfile {
        case .auto:
            return "Balanced default: visual effects off for responsiveness, network speed detected automatically."
        case .lan:
            return "Full visual quality (wallpaper, themes, animations, 32-bit color) for fast local networks."
        case .broadband:
            return "Keeps font smoothing and themes, drops wallpaper and animations."
        case .lowBandwidth:
            return "Minimal bandwidth: all visual effects off and 16-bit color for slow or metered links."
        case .custom:
            return "Choose exactly which visual features the remote session renders."
        }
    }

    // F-10: explain the per-connection modifier choice vs the global preference.
    private var modifierFootnote: String {
        switch connection.modifierOverride {
        case .useGlobal: return "Follows Settings ▸ Keyboard. Override it here for hosts that need the other behavior."
        case .cmdAsCtrl: return "On this host, ⌘ acts as Windows Ctrl (⌘C copies)."
        case .literal:   return "On this host, ⌘ sends the Windows key (use ⌃C to copy)."
        }
    }

    // Resolution preset binding
    private var resolutionPreset: Binding<ResolutionPreset> {
        Binding(
            get: {
                switch (connection.display.width, connection.display.height) {
                case (1280, 800): return .r1280x800
                case (1440, 900): return .r1440x900
                case (1920, 1080): return .r1920x1080
                case (2560, 1440): return .r2560x1440
                default: return .custom
                }
            },
            set: { preset in
                switch preset {
                case .r1280x800: connection.display.width = 1280; connection.display.height = 800
                case .r1440x900: connection.display.width = 1440; connection.display.height = 900
                case .r1920x1080: connection.display.width = 1920; connection.display.height = 1080
                case .r2560x1440: connection.display.width = 2560; connection.display.height = 1440
                case .custom: break
                }
            }
        )
    }

    private let portFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimum = 1; f.maximum = 65535; f.allowsFloats = false
        return f
    }()

    private let dimensionFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimum = 320; f.maximum = 7680; f.allowsFloats = false
        return f
    }()
}

// MARK: - Supporting types

enum CredentialPolicyOption {
    case biometricEveryConnect, biometricReuse, savedNoBiometric
}

enum ResolutionPreset {
    case r1280x800, r1440x900, r1920x1080, r2560x1440, custom
}

// MARK: - F-15: key-override editing support

/// One editable override row. UUID identity keeps SwiftUI's ForEach stable while the
/// user edits; only rows with a recorded key AND a valid non-zero hex scancode fold
/// back into the model on save.
struct KeyOverrideRow: Identifiable {
    let id = UUID()
    var macKeyCode: UInt16?
    var scancodeHex: String
    var extended: Bool

    init() {
        macKeyCode = nil
        scancodeHex = ""
        extended = false
    }

    init(_ override: KeyOverride) {
        macKeyCode = override.macKeyCode
        scancodeHex = String(format: "%02X", override.scancode)
        extended = override.extended
    }

    func toOverride() -> KeyOverride? {
        guard let keyCode = macKeyCode,
              let scancode = Self.parseHex(scancodeHex), scancode > 0 else { return nil }
        return KeyOverride(macKeyCode: keyCode, scancode: scancode, extended: extended)
    }

    /// Lenient hex parse: optional "0x"/"0X" prefix, surrounding whitespace OK.
    static func parseHex(_ text: String) -> UInt16? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { t.removeFirst(2) }
        guard !t.isEmpty else { return nil }
        return UInt16(t, radix: 16)
    }
}

/// F-15: "press a key" recorder. Click to arm; a local NSEvent keyDown monitor captures
/// the next keystroke's virtual keyCode (swallowing the event) and disarms. Click again
/// while armed to cancel. The monitor is always removed on disappear.
struct KeyRecorderButton: View {
    @Binding var macKeyCode: UInt16?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording { stopRecording() } else { startRecording() }
        } label: {
            Text(isRecording ? "Press a key…" : label)
                .frame(minWidth: 110)
        }
        .help(isRecording ? "Press the Mac key to remap (click again to cancel)"
                          : "Click, then press the Mac key to remap")
        .accessibilityLabel(isRecording ? "Recording — press the Mac key to remap"
                                        : "Mac key: \(label). Click to record a key")
        .onDisappear { stopRecording() }
    }

    private var label: String {
        macKeyCode.map(MacKeyNames.name(for:)) ?? "Record Key"
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            macKeyCode = event.keyCode
            stopRecording()
            return nil   // swallow the recorded keystroke
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

/// Display names for macOS virtual key codes (HIToolbox/Events.h assignments; ANSI-US
/// physical positions). Covers every key the mapper's table knows; anything else shows
/// its numeric code so a recorded exotic key is still identifiable.
enum MacKeyNames {
    static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        10: "§ (ISO)", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`",
        51: "Delete", 52: "Enter", 53: "Esc",
        54: "R⌘", 55: "⌘", 56: "⇧", 57: "Caps Lock", 58: "⌥", 59: "⌃",
        60: "R⇧", 61: "R⌥", 62: "R⌃", 63: "Fn",
        65: "KP .", 67: "KP *", 69: "KP +", 71: "KP Clear", 75: "KP /", 76: "KP Enter",
        78: "KP -", 81: "KP =",
        82: "KP 0", 83: "KP 1", 84: "KP 2", 85: "KP 3", 86: "KP 4", 87: "KP 5",
        88: "KP 6", 89: "KP 7", 91: "KP 8", 92: "KP 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Insert", 115: "Home", 116: "Page Up", 117: "Fwd Delete", 118: "F4",
        119: "End", 120: "F2", 121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

extension DisplaySettings.ScaleMode {
    var displayLabel: String {
        switch self {
        case .dynamic: return "Dynamic (follows window)"
        case .fitToWindow: return "Fit to Window"
        case .oneToOne: return "1:1 (scrollable)"
        }
    }
}

/// The editor's section groups, shown as a segmented control at the top of the sheet.
private enum EditorTab: String, CaseIterable, Identifiable {
    case connection, display, behaviour
    var id: Self { self }
    var title: String {
        switch self {
        case .connection: return "Connection"
        case .display:    return "Display"
        case .behaviour:  return "Behaviour"
        }
    }
}
