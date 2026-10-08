import XCTest
import CoreGraphics
import Combine
@testable import TouchRDPCore
@testable import TouchRDPEngine

@MainActor
final class ClipboardSessionRoutingTests: XCTestCase {
    private func makeController() -> SessionController {
        SessionController(makeSession: { ClipboardSession() }, trustStore: ClipboardTrust())
    }

    func testTextNotificationCannotBeConsumedByAnotherSession() {
        let a = makeController(), b = makeController()
        var received: Notification?
        let observer = NotificationCenter.default.publisher(for: .touchRDPRemoteClipboard)
            .sink { received = $0 }
        defer { observer.cancel() }
        a.sessionClipboardTextChanged("from A")
        guard let note = received else { return XCTFail("No text notification") }
        XCTAssertEqual(a.clipboardPayload(from: note, as: String.self), "from A")
        XCTAssertNil(b.clipboardPayload(from: note, as: String.self))
        // Legacy/unattributed events must fail closed too.
        XCTAssertNil(a.clipboardPayload(from: Notification(name: .touchRDPRemoteClipboard,
                                                           object: "unattributed"), as: String.self))
    }

    func testImageNotificationCannotBeConsumedByAnotherSession() throws {
        let a = makeController(), b = makeController()
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1,
                                              bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        var received: Notification?
        let observer = NotificationCenter.default.publisher(for: .touchRDPRemoteClipboardImage)
            .sink { received = $0 }
        defer { observer.cancel() }
        a.sessionClipboardImageChanged(image)
        let note = try XCTUnwrap(received)
        XCTAssertNotNil(a.clipboardPayload(from: note, as: CGImage.self))
        XCTAssertNil(b.clipboardPayload(from: note, as: CGImage.self))
    }

    func testFilesWithMatchingGenerationsStayWithTheirSourceSession() async throws {
        let a = makeController(), b = makeController()
        let announced = expectation(description: "both file announcements")
        announced.expectedFulfillmentCount = 2
        var received: [Notification] = []
        let observer = NotificationCenter.default.publisher(for: .touchRDPRemoteClipboardFiles).sink {
            received.append($0)
            announced.fulfill()
        }
        defer { observer.cancel() }
        // One empty file in a FILEGROUPDESCRIPTORW; both sessions start at generation 1.
        var blob = Data(repeating: 0, count: 4 + RemoteFileClipboard.descriptorStride)
        blob[0] = 1
        blob[4] = 0x40 // FD_FILESIZE
        blob[76] = 65 // filename "A", UTF-16LE
        a.sessionClipboardFilesChanged(blob)
        blob[76] = 66 // filename "B"
        b.sessionClipboardFilesChanged(blob)
        await fulfillment(of: [announced], timeout: 2)
        XCTAssertEqual(received.count, 2)
        let fromA = try XCTUnwrap(received.first { ($0.object as? SessionController) === a })
        let fromB = try XCTUnwrap(received.first { ($0.object as? SessionController) === b })
        let filesA = try XCTUnwrap(a.clipboardPayload(from: fromA, as: RemoteFileAnnouncement.self))
        let filesB = try XCTUnwrap(b.clipboardPayload(from: fromB, as: RemoteFileAnnouncement.self))
        XCTAssertEqual(filesA.generation, filesB.generation)
        XCTAssertEqual(filesA.descriptors.first?.name, "A")
        XCTAssertEqual(filesB.descriptors.first?.name, "B")
        XCTAssertNil(a.clipboardPayload(from: fromB, as: RemoteFileAnnouncement.self))
        XCTAssertNil(b.clipboardPayload(from: fromA, as: RemoteFileAnnouncement.self))
    }
}

private final class ClipboardTrust: CertificateTrustStore, @unchecked Sendable {
    func evaluate(_ info: CertInfo) -> TrustState { .trusted }
    func pin(_ info: CertInfo) {}
    func remove(host: String, port: Int) {}
}

private final class ClipboardSession: RDPSession {
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
