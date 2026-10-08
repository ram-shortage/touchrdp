import SwiftUI
import TouchRDPCore
import TouchRDPEngine

struct PreferencesView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    @AppStorage("defaultModifierMode") private var modifierModeRaw: String = ModifierMode.cmdAsCtrl.rawValue
    @AppStorage("defaultScaleMode") private var scaleModeRaw: String = DisplaySettings.ScaleMode.dynamic.rawValue
    @AppStorage("defaultSecurity") private var securityRaw: String = RDPSecurity.nla.rawValue
    @AppStorage("defaultWidth") private var defaultWidth: Int = 1280
    @AppStorage("defaultHeight") private var defaultHeight: Int = 800
    @AppStorage("defaultHiDPI") private var defaultHiDPI: Bool = true

    @State private var showForgetAllConfirm = false

    private var modifierMode: Binding<ModifierMode> {
        Binding(
            get: { ModifierMode(rawValue: modifierModeRaw) ?? .cmdAsCtrl },
            set: { modifierModeRaw = $0.rawValue }
        )
    }

    private var scaleMode: Binding<DisplaySettings.ScaleMode> {
        Binding(
            get: { DisplaySettings.ScaleMode(rawValue: scaleModeRaw) ?? .dynamic },
            set: { scaleModeRaw = $0.rawValue }
        )
    }

    private var security: Binding<RDPSecurity> {
        Binding(
            get: { RDPSecurity(rawValue: securityRaw) ?? .nla },
            set: { securityRaw = $0.rawValue }
        )
    }

    var body: some View {
        TabView {
            keyboardTab
                .tabItem { Label("Keyboard", systemImage: "keyboard") }

            displayTab
                .tabItem { Label("Display", systemImage: "display") }

            securityTab
                .tabItem { Label("Security", systemImage: "lock.shield") }

            vaultTab
                .tabItem { Label("Vault", systemImage: "key.fill") }
        }
        .frame(width: 480, height: 320)
        .padding()
    }

    // MARK: - Keyboard tab

    private var keyboardTab: some View {
        Form {
            Section("Modifier Mapping") {
                Picker("Cmd key behavior", selection: modifierMode) {
                    Text("Cmd → Ctrl (recommended for Windows)").tag(ModifierMode.cmdAsCtrl)
                    Text("Cmd → Windows key (literal)").tag(ModifierMode.literal)
                }
                .accessibilityLabel("Command key behavior in remote sessions")

                Text(modifierMode.wrappedValue == .cmdAsCtrl
                     ? "Mac Cmd acts as Windows Ctrl. Use Cmd+C to copy on the remote."
                     : "Mac Cmd sends Windows/Super key. Use Ctrl+C to copy on the remote.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // F-10: individual connections may pin the other behavior.
                Text("Connections can override this per host in the connection editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard Capture") {
                Text("Press Cmd+Escape in a session to toggle keyboard capture. When captured, all key events go to the remote — including Cmd+Q and Cmd+Tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Display tab

    private var displayTab: some View {
        Form {
            Section("Default Resolution") {
                HStack {
                    TextField("Width", value: $defaultWidth, formatter: dimensionFormatter)
                        .frame(width: 80)
                        .accessibilityLabel("Default display width")
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", value: $defaultHeight, formatter: dimensionFormatter)
                        .frame(width: 80)
                        .accessibilityLabel("Default display height")
                }
                Toggle("HiDPI (Retina)", isOn: $defaultHiDPI)
                    .accessibilityLabel("Enable HiDPI retina by default")
            }

            Section("Default Scale Mode") {
                Picker("Scale Mode", selection: scaleMode) {
                    ForEach(DisplaySettings.ScaleMode.allCases, id: \.self) { mode in
                        Text(mode.displayLabel).tag(mode)
                    }
                }
                .accessibilityLabel("Default display scale mode")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Security tab

    private var securityTab: some View {
        Form {
            Section("Default Protocol") {
                Picker("Security Protocol", selection: security) {
                    ForEach(RDPSecurity.allCases, id: \.self) { s in
                        Text(s.displayLabel).tag(s)
                    }
                }
                .accessibilityLabel("Default RDP security protocol")

                Text(securityWarning)
                    .font(.caption)
                    .foregroundStyle(security.wrappedValue == .rdpLegacy ? .red : .secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var securityWarning: String {
        switch security.wrappedValue {
        case .nla: return "NLA (Network Level Authentication) is the most secure option."
        case .tls: return "TLS encrypts the connection but does not require NLA pre-authentication."
        case .rdpLegacy: return "Legacy RDP is insecure and should only be used with very old servers."
        }
    }

    // MARK: - Vault tab

    private var vaultTab: some View {
        Form {
            Section("Password Vault") {
                LabeledContent("Active Tier", value: coordinator.vaultTierLabel)
                LabeledContent("Biometric", value: biometricLabel)
            }

            Section {
                Button("Forget All Saved Passwords…", role: .destructive) {
                    showForgetAllConfirm = true
                }
                .accessibilityLabel("Forget and delete all saved passwords")
            } footer: {
                Text("This removes all saved passwords from the keychain. You will be prompted to re-enter passwords on next connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Forget All Passwords?",
            isPresented: $showForgetAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Forget All", role: .destructive) {
                forgetAllPasswords()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all saved passwords. Sessions will require you to enter passwords again.")
        }
    }

    private var biometricLabel: String {
        let cap = coordinator.biometricCapability
        if !cap.available { return "Not available" }
        switch cap.type {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .none: return "Device password"
        }
    }

    // MARK: - Actions

    private func forgetAllPasswords() {
        let store = coordinator.store
        for connection in store.connections {
            try? coordinator.forgetPassword(for: connection)
        }
    }

    private let dimensionFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimum = 320; f.maximum = 7680; f.allowsFloats = false
        return f
    }()
}
