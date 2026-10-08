import XCTest
import CoreGraphics
import Network
@testable import TouchRDPCore
@testable import TouchRDPEngine

/// An empty password used to travel all the way into FreeRDP, where NLA has nothing to
/// hash: two doomed NTLM rounds (`SEC_E_NO_CREDENTIALS`, "Could not find user in SAM
/// database") and then "the connection transport layer failed" — a message that sent
/// the user chasing the network. It could get there from Quick Connect (blank field) or
/// from an empty Keychain item, which the editor then reported as "Saved".
///
/// Now the vault refuses to store or return one, and the engine refuses to send one.
@MainActor
final class EmptyPasswordTests: XCTestCase {

    func testVaultRefusesToStoreAnEmptyPassword() {
        let vault = KeychainCredentialVault()
        let id = UUID()
        XCTAssertThrowsError(try vault.storePassword("", for: id)) { error in
            XCTAssertEqual(error as? VaultError, .emptySecret)
        }
        // Nothing was written: the profile must not claim "Password: Saved".
        XCTAssertFalse(vault.hasPassword(for: id))
    }

    /// The engine-level guard: "" from the provider (an ad-hoc connect, or a vault
    /// implementation that doesn't check) never reaches the session; the failure lands
    /// on the credentials overlay whose action is "Update Saved Password…".
    func testEmptyPasswordNeverReachesTheSession() async throws {
        // The connect task TCP-probes the endpoint BEFORE asking for credentials, so
        // listen locally to get past the probe.
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }
        let port = Int(try XCTUnwrap(listener.port).rawValue)

        let stub = StubSession()
        let controller = SessionController(makeSession: { stub }, trustStore: StubTrustStore())
        let connection = Connection(name: "Test", host: "127.0.0.1", port: port, username: "u")
        XCTAssertEqual(connection.security, .nla, "the guard is specific to NLA")
        controller.connect(connection, passwordProvider: { _ in ConnectionSecrets(primary: "") })

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if case .connecting = controller.state {
                try await Task.sleep(nanoseconds: 50_000_000)
            } else { break }
        }
        guard case .failed(let err) = controller.state else {
            return XCTFail("expected a credentials failure, got \(controller.state)")
        }
        XCTAssertEqual(err.cause, .credentialsUnavailable)
        XCTAssertTrue(err.humanMessage.lowercased().contains("empty"), err.humanMessage)
        XCTAssertEqual(stub.connectCalls, 0, "an empty password must never be handed to FreeRDP")
    }

    /// TouchRDP's contract is a complete saved credential pair for every security mode;
    /// TLS must not silently defer an empty password to the Windows logon screen.
    func testEmptyPasswordNeverReachesTLSSession() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }
        let port = Int(try XCTUnwrap(listener.port).rawValue)

        let stub = StubSession()
        let controller = SessionController(makeSession: { stub }, trustStore: StubTrustStore())
        var connection = Connection(name: "Test", host: "127.0.0.1", port: port, username: "u")
        connection.security = .tls
        controller.connect(connection, passwordProvider: { _ in ConnectionSecrets(primary: "") })

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if case .connecting = controller.state {
                try await Task.sleep(nanoseconds: 50_000_000)
            } else { break }
        }
        guard case .failed(let err) = controller.state else {
            return XCTFail("expected a credentials failure, got \(controller.state)")
        }
        XCTAssertEqual(err.cause, .credentialsUnavailable)
        XCTAssertEqual(stub.connectCalls, 0)
    }

    /// A missing username is rejected synchronously, before the reachability probe or
    /// password provider. This covers legacy/imported profiles that bypassed the editor.
    func testMissingUsernamePromptsBeforeAnyConnectionWork() {
        let stub = StubSession()
        let controller = SessionController(makeSession: { stub }, trustStore: StubTrustStore())
        let connection = Connection(name: "Test", host: "unreachable.invalid",
                                    username: "  \n")
        var providerCalled = false

        controller.connect(connection, passwordProvider: { _ in
            providerCalled = true
            return ConnectionSecrets(primary: "secret")
        })

        guard case .failed(let err) = controller.state else {
            return XCTFail("expected an incomplete-credentials failure, got \(controller.state)")
        }
        XCTAssertEqual(err.cause, .credentialsIncomplete)
        XCTAssertTrue(err.humanMessage.lowercased().contains("username"))
        XCTAssertFalse(providerCalled)
        XCTAssertEqual(stub.connectCalls, 0)
    }
}

// MARK: - Doubles

private final class StubTrustStore: CertificateTrustStore, @unchecked Sendable {
    func evaluate(_ info: CertInfo) -> TrustState { .trusted }
    func pin(_ info: CertInfo) {}
    func remove(host: String, port: Int) {}
    func pinnedRecord(host: String, port: Int) -> PinnedCertRecord? { nil }
}

private final class StubSession: RDPSession {
    weak var delegate: RDPSessionDelegate?
    var freeRDPVersion: String { "stub" }
    private(set) var connectCalls = 0
    func connect(config: RDPConnectionConfig, password: String, gatewayPassword: String?) {
        connectCalls += 1
    }
    func disconnect() {}
    func sendPointer(buttonMask: PointerButtons, x: Int, y: Int, down: Bool, moved: Bool) {}
    func sendWheel(delta: Int, horizontal: Bool) {}
    func sendScancode(_ code: UInt16, down: Bool, extended: Bool) {}
    func sendUnicode(_ code: UInt16, down: Bool) {}
    func sendCtrlAltDel() {}
    func sendKeyboardSync(capsLock: Bool, numLock: Bool, scrollLock: Bool) {}
    func requestResize(width: Int, height: Int, scalePercent: Int) {}
    func setClipboardText(_ text: String) {}
    func setClipboardImage(_ image: CGImage) {}
}
