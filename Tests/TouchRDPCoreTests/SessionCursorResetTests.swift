import XCTest
import CoreGraphics
@testable import TouchRDPCore
@testable import TouchRDPEngine

/// The remote pointer shape must never outlive the session it belongs to.
///
/// Windows routinely asks for a hidden pointer (typing, video playback, the lock
/// screen) and frequently does so right as the link drops. The canvas stays in the
/// view hierarchy under the disconnect/reconnect overlay and still owns the pointer
/// through its tracking area, so a retained "hidden" cursor makes the mouse invisible
/// over the overlay's Reconnect/Disconnect buttons.
@MainActor
final class SessionCursorResetTests: XCTestCase {

    private func makeController() -> (SessionController, StubTrustStore) {
        let trust = StubTrustStore()
        let controller = SessionController(makeSession: { StubSession() }, trustStore: trust)
        return (controller, trust)
    }

    func testHiddenCursorIsResetOnDisconnect() {
        let (controller, _) = makeController()
        controller.sessionDidChangeState(.connected)
        controller.sessionDidUpdateCursor(.hidden)
        XCTAssertFalse(isArrow(controller.currentCursor))

        controller.sessionDidChangeState(.disconnected(reason: "dropped"))
        XCTAssertTrue(isArrow(controller.currentCursor))
    }

    func testHiddenCursorIsResetOnFailureAndReconnect() {
        for terminal in [ConnectionState.failed(RDPError(code: 0, rawMessage: "x", cause: .unknown)),
                         .reconnecting(attempt: 1),
                         .idle] {
            let (controller, _) = makeController()
            controller.sessionDidChangeState(.connected)
            controller.sessionDidUpdateCursor(.hidden)
            controller.sessionDidChangeState(terminal)
            XCTAssertTrue(isArrow(controller.currentCursor),
                          "cursor not reset for state \(terminal)")
        }
    }

    /// The reset must reach the canvas sinks, not just the stored value — the canvas
    /// renders from what it was last pushed.
    func testResetIsPushedToCanvasSinks() {
        let (controller, _) = makeController()
        var exclusive: [CursorUpdate] = []
        var keyed: [CursorUpdate] = []
        controller.onCursor = { exclusive.append($0) }
        controller.setCursorSink({ keyed.append($0) }, for: UUID())

        controller.sessionDidChangeState(.connected)
        controller.sessionDidUpdateCursor(.hidden)
        controller.sessionDidChangeState(.disconnected(reason: nil))

        XCTAssertTrue(exclusive.last.map(isArrow) ?? false)
        XCTAssertTrue(keyed.last.map(isArrow) ?? false)
    }

    /// A cursor that is already the arrow must not generate a redundant push (the
    /// canvas rebuilds its NSCursor on every update).
    func testNoRedundantPushWhenAlreadyArrow() {
        let (controller, _) = makeController()
        var pushes = 0
        controller.onCursor = { _ in pushes += 1 }

        controller.sessionDidChangeState(.connected)
        controller.sessionDidChangeState(.disconnected(reason: nil))
        XCTAssertEqual(pushes, 0)
    }

    /// A live session keeps whatever shape the host asked for.
    func testConnectedStateKeepsRemoteCursor() {
        let (controller, _) = makeController()
        controller.sessionDidChangeState(.connected)
        controller.sessionDidUpdateCursor(.hidden)
        controller.sessionDidChangeState(.connected)
        XCTAssertFalse(isArrow(controller.currentCursor))
    }

    private func isArrow(_ update: CursorUpdate) -> Bool {
        if case .arrow = update { return true }
        return false
    }
}

// MARK: - Doubles

private final class StubTrustStore: CertificateTrustStore, @unchecked Sendable {
    func evaluate(_ info: CertInfo) -> TrustState { .trusted }
    func pin(_ info: CertInfo) {}
    func remove(host: String, port: Int) {}
}

private final class StubSession: RDPSession {
    weak var delegate: RDPSessionDelegate?
    var freeRDPVersion: String { "stub" }
    func connect(config: RDPConnectionConfig, password: String, gatewayPassword: String?) {}
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
