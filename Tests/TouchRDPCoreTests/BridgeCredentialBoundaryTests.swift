import XCTest
import CRDPBridge

private final class BridgeStateRecorder {
    var state = RDPB_STATE_IDLE
    var code: UInt32 = 0
}

private let recordBridgeState: RDPBridgeStateCb = { context, state, code, _ in
    guard let context else { return }
    let recorder = Unmanaged<BridgeStateRecorder>.fromOpaque(context).takeUnretainedValue()
    recorder.state = state
    recorder.code = code
}

/// Exercises the C ABI before a network thread is started. These cases previously
/// could be silently truncated into a non-NULL empty string inside FreeRDP.
final class BridgeCredentialBoundaryTests: XCTestCase {
    private func withBridge(_ body: (OpaquePointer, BridgeStateRecorder) -> Void) throws {
        let recorder = BridgeStateRecorder()
        let callbacks = RDPBridgeCallbacks(
            onState: recordBridgeState,
            onFrame: nil,
            onResize: nil,
            onCertVerify: nil,
            onClipboard: nil,
            onClipboardImage: nil,
            onCursor: nil,
            onCursorHidden: nil,
            onCursorDefault: nil,
            onClipboardFiles: nil,
            onFileContents: nil)
        let context = Unmanaged.passUnretained(recorder).toOpaque()
        let bridge = try XCTUnwrap(rdpbridge_create(context, callbacks))
        defer {
            rdpbridge_detach(bridge)
            rdpbridge_free(bridge)
        }
        body(bridge, recorder)
    }

    func testEmptyNLAPasswordFailsBeforeStartingAThread() throws {
        try withBridge { bridge, recorder in
            "user".withCString { username in
                var config = RDPBridgeConfig()
                config.security = RDPB_SEC_NLA
                config.username = username

                XCTAssertEqual(rdpbridge_connect(bridge, &config, nil, 0), 0)
            }
            XCTAssertEqual(recorder.state, RDPB_STATE_FAILED)
            XCTAssertEqual(recorder.code, UInt32(RDPB_ERROR_NO_CREDENTIALS))
        }
    }

    func testEmptyUsernameFailsBeforeStartingAThread() throws {
        try withBridge { bridge, recorder in
            var config = RDPBridgeConfig()
            config.security = RDPB_SEC_NLA
            let password = Array("secret".utf8)

            let started = password.withUnsafeBufferPointer {
                rdpbridge_connect(bridge, &config, $0.baseAddress, $0.count)
            }
            XCTAssertEqual(started, 0)
            XCTAssertEqual(recorder.state, RDPB_STATE_FAILED)
            XCTAssertEqual(recorder.code, UInt32(RDPB_ERROR_INCOMPLETE_CREDENTIALS))
        }
    }

    func testEmptyTLSPasswordIsAlsoRejected() throws {
        try withBridge { bridge, recorder in
            "user".withCString { username in
                var config = RDPBridgeConfig()
                config.security = RDPB_SEC_TLS
                config.username = username

                XCTAssertEqual(rdpbridge_connect(bridge, &config, nil, 0), 0)
            }
            XCTAssertEqual(recorder.state, RDPB_STATE_FAILED)
            XCTAssertEqual(recorder.code, UInt32(RDPB_ERROR_NO_CREDENTIALS))
        }
    }

    func testEmbeddedNULIsRejectedInsteadOfTruncated() throws {
        try withBridge { bridge, recorder in
            let password: [UInt8] = [0x61, 0x00, 0x62]

            let started = "user".withCString { username in
                var config = RDPBridgeConfig()
                config.security = RDPB_SEC_NLA
                config.username = username
                return password.withUnsafeBufferPointer {
                    rdpbridge_connect(bridge, &config, $0.baseAddress, $0.count)
                }
            }
            XCTAssertEqual(started, 0)
            XCTAssertEqual(recorder.state, RDPB_STATE_FAILED)
            XCTAssertEqual(recorder.code, UInt32(RDPB_ERROR_CREDENTIAL_HANDOFF))
        }
    }

    func testNonzeroLengthRequiresAValidPointer() throws {
        try withBridge { bridge, recorder in
            "user".withCString { username in
                var config = RDPBridgeConfig()
                config.security = RDPB_SEC_NLA
                config.username = username

                XCTAssertEqual(rdpbridge_connect(bridge, &config, nil, 1), 0)
            }
            XCTAssertEqual(recorder.state, RDPB_STATE_FAILED)
            XCTAssertEqual(recorder.code, UInt32(RDPB_ERROR_CREDENTIAL_HANDOFF))
        }
    }
}
