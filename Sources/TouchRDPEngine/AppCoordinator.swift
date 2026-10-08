import Foundation
import CoreGraphics
import Combine
import TouchRDPCore

/// Top-level composition + orchestration. Holds the vault, connection store, and
/// trust store (injected as protocols), manufactures SessionControllers, and turns
/// a connect request + the connection's CredentialPolicy into a biometric-gated
/// password provider. The app's composition root injects the concrete services.
@MainActor
public final class AppCoordinator: ObservableObject {
    public let vault: CredentialVault
    public let store: ConnectionStore
    public let trustStore: CertificateTrustStore
    @Published public var persistenceError: String?

    /// Factory for the RDP session backing a controller (overridable for tests).
    private let makeSession: () -> RDPSession

    private var cancellables = Set<AnyCancellable>()

    public init(vault: CredentialVault,
                store: ConnectionStore,
                trustStore: CertificateTrustStore,
                makeSession: @escaping () -> RDPSession = { FreeRDPSession() }) {
        self.vault = vault
        self.store = store
        self.trustStore = trustStore
        self.makeSession = makeSession

        // Views observe the coordinator, but the store is held as a protocol value, so
        // its @Published changes wouldn't otherwise reach them. Re-broadcast store
        // changes through us so the sidebar/detail/editor always see current data
        // (otherwise an edit looks like it "reverts" because the reopened editor is
        // seeded from a stale snapshot).
        if let observableStore = store as? FileConnectionStore {
            observableStore.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    public var biometricCapability: BiometricCapability { vault.capability }
    public var vaultTier: VaultTier { vault.activeTier }

    /// Human label for the active protection tier (PRD: always show the posture).
    public var vaultTierLabel: String {
        switch vault.activeTier {
        case .hardwareBound:    return "Hardware-bound (Secure Enclave)"
        case .appGatedFallback: return "Touch ID gated"
        }
    }

    public func makeSessionController() -> SessionController {
        SessionController(makeSession: makeSession, trustStore: trustStore)
    }

    /// Store/replace a connection's password under biometric protection.
    public func storePassword(_ password: String, for connection: Connection) throws {
        try vault.storePassword(password, for: connection.id)
    }

    public func hasPassword(for connection: Connection) -> Bool {
        vault.hasPassword(for: connection.id)
    }

    /// Deletes ALL of the connection's secrets (primary + gateway) — the
    /// delete-on-connection-delete path (F-6: never orphan the gateway item).
    public func forgetPassword(for connection: Connection) throws {
        try vault.deletePassword(for: connection.id)
    }

    // MARK: F-6 — separate RD Gateway credential (same tier/policy as the primary)

    public func storeGatewayPassword(_ password: String, for connection: Connection) throws {
        try vault.storePassword(password, for: connection.id, kind: .gateway)
    }

    public func hasGatewayPassword(for connection: Connection) -> Bool {
        vault.hasPassword(for: connection.id, kind: .gateway)
    }

    /// Removes ONLY the gateway secret (editor toggled "separate credentials" off).
    public func forgetGatewayPassword(for connection: Connection) throws {
        try vault.deletePassword(for: connection.id, kind: .gateway)
    }

    // MARK: - Certificate trust (TOFU pins, keyed by host:port)

    /// The certificate currently pinned for `host:port`, if any. Descriptive only —
    /// the trust decision itself belongs to `SessionController.sessionVerifyCertificate`.
    public func pinnedCertificate(host: String, port: Int) -> PinnedCertRecord? {
        trustStore.pinnedRecord(host: host, port: port)
    }

    /// Drop the pin for `host:port`, so the next connection to it is treated as first
    /// use and asks for an explicit review again. This is the only way back from a
    /// certificate approved by mistake, or one the user would rather re-examine;
    /// without it, recovery means hand-editing trust.json.
    public func forgetCertificate(host: String, port: Int) {
        trustStore.remove(host: host, port: port)
        // The trust store is a plain protocol value, not @Published, so views observing
        // the coordinator need a nudge to re-read it.
        objectWillChange.send()
    }

    /// Begin a connection on `controller`, wiring biometric retrieval per policy.
    /// `preferredLogicalSize`/`backingScale` (the app window) let Auto/Dynamic mode
    /// derive a Retina-matched remote resolution + DPI.
    public func connect(_ connection: Connection, using controller: SessionController,
                        preferredLogicalSize: CGSize? = nil, backingScale: CGFloat = 1,
                        monitors: [MonitorDef] = []) {
        var updated = connection
        updated.lastConnected = Date()
        do { try store.update(updated) }
        catch { persistenceError = error.localizedDescription }

        let vault = self.vault
        let policy = connection.credentialPolicy
        let id = connection.id
        let connectionName = connection.name
        // F-6: fetch the gateway secret in the SAME flow when the connection uses
        // separate gateway credentials — both reads share one authenticated LAContext,
        // so a connect costs exactly ONE Touch ID prompt for two secrets.
        let includeGateway = connection.gateway?.useSeparateCredentials == true

        controller.connect(connection, preferredLogicalSize: preferredLogicalSize,
                           backingScale: backingScale, monitors: monitors) { requestReason in
            // Runs off the main actor; returns the released secret(s) or throws VaultError.
            // LIFE-3: `authDirective` maps (policy, reason) → reuse window + whether to force
            // a fresh prompt. `biometricEveryConnect` prompts on every user-initiated connect
            // but seeds a reusable context so the single automatic reconnect reuses it.
            let d = policy.authDirective(for: requestReason)
            // The Touch ID prompt is the last thing the user sees before a secret is
            // released, and for F-27 it IS the confirmation step — so it has to say what
            // it is actually for. Labelling a password-typing request "Connect to …"
            // would ask for consent to the wrong thing.
            let promptReason: String
            switch requestReason {
            case .userInitiated, .automaticReconnect:
                promptReason = "Connect to \(connectionName)"
            case .inSessionTyping:
                promptReason = "Type the saved password into the \(connectionName) session"
            }
            return try await vault.retrieveConnectionSecrets(for: id,
                                                             includeGateway: includeGateway,
                                                             reason: promptReason,
                                                             allowReuseSeconds: d.reuseSeconds,
                                                             forceFreshPrompt: d.forceFreshPrompt)
        }
    }

    /// Quick Connect: begin a connection to an ad-hoc, UNSAVED profile using a password
    /// supplied inline. The connection is not added to the store and the password is not
    /// written to the vault — it is handed straight to the session. The provider closure
    /// retains it for the session's lifetime so auto-reconnect can re-use it (there is no
    /// vault entry to re-read); it is never persisted, logged, or placed on the pasteboard.
    public func connectAdHoc(_ connection: Connection, using controller: SessionController,
                             password: String,
                             preferredLogicalSize: CGSize? = nil, backingScale: CGFloat = 1,
                             monitors: [MonitorDef] = []) {
        controller.connect(connection, preferredLogicalSize: preferredLogicalSize,
                           backingScale: backingScale, monitors: monitors) { _ in
            ConnectionSecrets(primary: password)
        }
    }

}
