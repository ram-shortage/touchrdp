import XCTest
import CoreGraphics
@testable import TouchRDPCore
@testable import TouchRDPEngine

@MainActor
final class SessionLifecycleRegressionTests: XCTestCase {
    private func makeController(attempts: Int = 5) -> SessionController {
        let controller = SessionController(makeSession: { LifecycleSession() },
                                           trustStore: LifecycleTrust(),
                                           checkReachability: { _, _ in nil })
        controller.connect(Connection(name: "Test", host: "example.test", username: "user",
                                      reconnectPolicy: .init(maxAttempts: attempts))) { _ in
            ConnectionSecrets(primary: "test-secret")
        }
        return controller
    }

    func testFailureAndTeardownConsumeOnlyOneRetry() {
        for attempts in [1, 5] {
            let controller = makeController(attempts: attempts)
            defer { controller.disconnect() }
            controller.sessionDidChangeState(.connected)
            controller.sessionDidChangeState(.failed(RDPError(code: 0, rawMessage: "dropped", cause: .hostUnreachable)))
            XCTAssertEqual(controller.state, .reconnecting(attempt: 1))
            controller.sessionDidChangeState(.disconnected(reason: "Disconnected"))
            XCTAssertEqual(controller.state, .reconnecting(attempt: 1))
            controller.sessionDidChangeState(.disconnected(reason: "duplicate"))
            XCTAssertEqual(controller.state, .reconnecting(attempt: 1))
        }
    }

    func testTeardownPreservesNonRetryableFailure() {
        for cause: RDPErrorCause in [.authenticationFailed, .certificateRejected, .cancelled] {
            let controller = makeController()
            defer { controller.disconnect() }
            controller.sessionDidChangeState(.connected)
            let failure = ConnectionState.failed(RDPError(code: 0, rawMessage: "specific error", cause: cause))
            controller.sessionDidChangeState(failure)
            controller.sessionDidChangeState(.disconnected(reason: "Disconnected"))
            XCTAssertEqual(controller.state, failure)
        }
    }

    /// A reconnect that comes up and drops again within seconds must NOT re-earn the
    /// budget — otherwise connect → drop → connect loops forever (two clients taking a
    /// session from each other, or a link that barely holds).
    func testShortLivedReconnectDoesNotResetTheAttemptBudget() async throws {
        let controller = makeController(attempts: 2)
        defer { controller.disconnect() }
        controller.sessionDidChangeState(.connected)
        controller.sessionDidChangeState(.disconnected(reason: "dropped"))
        XCTAssertEqual(controller.state, .reconnecting(attempt: 1))

        // Wait out the 5 s floor; the automatic reconnect starts a new attempt.
        try await Task.sleep(nanoseconds: 5_600_000_000)
        controller.sessionDidChangeState(.connected)
        controller.sessionDidChangeState(.disconnected(reason: "dropped again"))
        XCTAssertEqual(controller.state, .reconnecting(attempt: 2),
                       "a connection that lasted seconds keeps counting toward the limit")

        try await Task.sleep(nanoseconds: 5_600_000_000)
        controller.sessionDidChangeState(.connected)
        controller.sessionDidChangeState(.disconnected(reason: "and again"))
        XCTAssertEqual(controller.state, .disconnected(reason: "and again"),
                       "budget spent — auto-reconnect stops")
    }

    func testTakenOverSessionIsNotAutoReconnected() {
        let controller = makeController()
        defer { controller.disconnect() }
        controller.sessionDidChangeState(.connected)
        let takenOver = ConnectionState.failed(RDPError.from(code: 0x00010005, rawMessage: ""))
        controller.sessionDidChangeState(takenOver)
        controller.sessionDidChangeState(.disconnected(reason: "Disconnected"))
        XCTAssertEqual(controller.state, takenOver)
    }

    func testCancelReconnectCountdownIsTerminalAndRetryStartsNewAttempt() {
        let controller = makeController()
        controller.sessionDidChangeState(.connected)
        controller.sessionDidChangeState(.disconnected(reason: "dropped"))
        controller.disconnect()
        XCTAssertEqual(controller.state, .disconnected(reason: "Disconnected"))
        controller.sessionDidChangeState(.connected) // late callback from the closed attempt
        XCTAssertEqual(controller.state, .disconnected(reason: "Disconnected"))
        controller.retry()
        XCTAssertEqual(controller.state, .connecting)
        controller.sessionDidChangeState(.connected)
        XCTAssertEqual(controller.state, .connected)
        controller.disconnect()
    }

    func testDisconnectBeforeTaskStartsNeverRequestsCredentials() async {
        var requested = false
        let session = LifecycleSession()
        let controller = SessionController(makeSession: { session }, trustStore: LifecycleTrust(),
                                           checkReachability: { _, _ in nil })
        controller.connect(Connection(name: "Test", host: "example.test", username: "user")) { _ in
            requested = true
            return ConnectionSecrets(primary: "test-secret")
        }
        controller.disconnect()
        XCTAssertEqual(controller.state, .disconnected(reason: "Disconnected"))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(requested)
        XCTAssertEqual(session.connectCount, 0)
        XCTAssertNil(session.delegate)
    }

    func testDisconnectWhileReachabilityIsPendingIgnoresItsLateResult() async {
        let started = expectation(description: "probe started")
        var resume: CheckedContinuation<RDPError?, Never>?
        var requested = false
        let session = LifecycleSession()
        let controller = SessionController(makeSession: { session }, trustStore: LifecycleTrust(),
                                           checkReachability: { _, _ in
            await withCheckedContinuation {
                resume = $0
                started.fulfill()
            }
        })
        controller.connect(Connection(name: "Test", host: "example.test", username: "user")) { _ in
            requested = true
            return ConnectionSecrets(primary: "test-secret")
        }
        await fulfillment(of: [started], timeout: 2)
        controller.disconnect()
        resume?.resume(returning: nil)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(requested)
        XCTAssertEqual(session.connectCount, 0)
        XCTAssertEqual(controller.state, .disconnected(reason: "Disconnected"))
    }

    func testDisconnectWhileCredentialReadIsPendingCannotReviveSession() async {
        let started = expectation(description: "vault started")
        var resume: CheckedContinuation<ConnectionSecrets, Never>?
        let session = LifecycleSession()
        let controller = SessionController(makeSession: { session }, trustStore: LifecycleTrust(),
                                           checkReachability: { _, _ in nil })
        controller.connect(Connection(name: "Test", host: "example.test", username: "user")) { _ in
            await withCheckedContinuation {
                resume = $0
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        controller.disconnect()
        resume?.resume(returning: ConnectionSecrets(primary: "late-secret"))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(session.connectCount, 0)
        XCTAssertEqual(controller.state, .disconnected(reason: "Disconnected"))
    }
}

private final class LifecycleTrust: CertificateTrustStore, @unchecked Sendable {
    func evaluate(_ info: CertInfo) -> TrustState { .trusted }
    func pin(_ info: CertInfo) {}
    func remove(host: String, port: Int) {}
}

private final class LifecycleSession: RDPSession {
    weak var delegate: RDPSessionDelegate?
    var connectCount = 0
    var freeRDPVersion: String { "stub" }
    func connect(config: RDPConnectionConfig, password: String, gatewayPassword: String?) { connectCount += 1 }
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
