import XCTest
@testable import TouchRDPCore

final class RDPErrorTests: XCTestCase {

    // MARK: - Code-based mapping (#32: FreeRDP 3 ERRCONNECT_* table, freerdp/error.h)

    func testBridgeCertRejectedCodeIsTheOnlyCertificateCode() {
        XCTAssertEqual(RDPError.from(code: RDPError.bridgeCertRejectedCode, rawMessage: "").cause,
                       .certificateRejected)
        // The bridge's code lives outside FreeRDP's error classes so it can never collide.
        XCTAssertNotEqual(RDPError.bridgeCertRejectedCode & 0xFFFF0000, 0x00020000)
    }

    /// The reported bug: FreeRDP's SECURITY_NEGO_CONNECT_FAILED (0x0002000C) was read as a
    /// rejected certificate — no certificate to review, "Review Certificate" looping.
    func testSecurityNegotiationFailureIsNotACertificateRejection() {
        let e = RDPError.from(code: 0x0002000C,
                              rawMessage: "The connection failed at negotiating security settings.")
        XCTAssertEqual(e.cause, .protocolError)
        XCTAssertTrue(e.humanMessage.contains("negotiating security settings"),
                      "the overlay must say what FreeRDP actually reported")
    }

    // MARK: - Server-ended sessions (ERRINFO_* class, 0x0001xxxx)

    /// The reconnect ping-pong: another client took the session. FreeRDP's sentence for it
    /// contains "connect", which the message fallback used to read as a retryable
    /// connection failure.
    func testAnotherConnectionTakingTheSessionIsNotRetryable() {
        let e = RDPError.from(code: 0x00010005,
                              rawMessage: "Another user connected to the server, forcing the disconnection of the current connection.")
        XCTAssertEqual(e.cause, .sessionTakenOver)
        XCTAssertFalse(ReconnectDecider.isRetryable(e.cause))
    }

    func testServerEndedSessionsAreNotRetryable() {
        for code: UInt32 in [0x00010001, 0x00010002, 0x00010003, 0x00010004, 0x0001000B, 0x0001000C] {
            let e = RDPError.from(code: code, rawMessage: "")
            XCTAssertEqual(e.cause, .sessionEndedByServer, "code 0x\(String(code, radix: 16))")
            XCTAssertFalse(ReconnectDecider.isRetryable(e.cause))
        }
    }

    func testHybridRequiredByServerIsAProtocolError() {
        XCTAssertEqual(RDPError.from(code: 0x0002001E, rawMessage: "").cause, .protocolError)
    }

    func testDNSCodes() {
        XCTAssertEqual(RDPError.from(code: 0x00020004, rawMessage: "").cause, .dnsFailure)
        XCTAssertEqual(RDPError.from(code: 0x00020005, rawMessage: "").cause, .dnsFailure)
    }

    func testConnectionFailedCodes() {
        for code: UInt32 in [0x00020001, 0x00020002, 0x00020006, 0x00020008, 0x0002000D] {
            XCTAssertEqual(RDPError.from(code: code, rawMessage: "").cause, .connectionFailed,
                           "code \(String(code, radix: 16))")
        }
    }

    func testAuthenticationCodes() {
        // AUTHENTICATION_FAILED used to be read as a DNS failure.
        for code: UInt32 in [0x00020009, 0x0002000A, 0x0002000E, 0x0002000F, 0x00020012,
                             0x00020013, 0x00020014, 0x00020015, 0x00020016, 0x00020018] {
            XCTAssertEqual(RDPError.from(code: code, rawMessage: "").cause, .authenticationFailed,
                           "code \(String(code, radix: 16))")
        }
    }

    func testMissingCredentialsCode() {
        XCTAssertEqual(RDPError.from(code: 0x0002001B, rawMessage: "").cause, .credentialsUnavailable)
        XCTAssertEqual(
            RDPError.from(code: RDPError.bridgeIncompleteCredentialsCode, rawMessage: "").cause,
            .credentialsIncomplete)
    }

    func testCancelledCodes() {
        XCTAssertEqual(RDPError.from(code: 0x00000000, rawMessage: "").cause, .cancelled)
        XCTAssertEqual(RDPError.from(code: 0x0002000B, rawMessage: "").cause, .cancelled)
    }

    func testActivationTimeoutCode() {
        XCTAssertEqual(RDPError.from(code: 0x0002001C, rawMessage: "").cause, .timeout)
    }

    // MARK: - Message-based fallback (unknown code)

    func testMessageFallbackLogonFailed() {
        let e = RDPError.from(code: 0xFFFFFFFF, rawMessage: "logon failed")
        XCTAssertEqual(e.cause, .authenticationFailed)
    }

    func testMessageFallbackCertificate() {
        let e = RDPError.from(code: 0xFFFFFFFF, rawMessage: "invalid certificate")
        XCTAssertEqual(e.cause, .certificateRejected)
    }

    func testMessageFallbackDNS() {
        let e = RDPError.from(code: 0xFFFFFFFF, rawMessage: "dns resolution failed")
        XCTAssertEqual(e.cause, .dnsFailure)
    }

    func testMessageFallbackTimeout() {
        let e = RDPError.from(code: 0xFFFFFFFF, rawMessage: "connection timeout")
        XCTAssertEqual(e.cause, .timeout)
    }

    func testMessageFallbackConnect() {
        let e = RDPError.from(code: 0xFFFFFFFF, rawMessage: "failed to connect to remote")
        XCTAssertEqual(e.cause, .connectionFailed)
    }

    func testMessageFallbackUnknown() {
        let e = RDPError.from(code: 0xFFFFFFFF, rawMessage: "some weird exotic error")
        XCTAssertEqual(e.cause, .unknown)
    }

    // MARK: - humanMessage non-empty

    func testHumanMessageNonEmpty() {
        for code: UInt32 in [0x00020006, 0x00020009, 0x00020014, 0x0002000C, RDPError.bridgeCertRejectedCode, 0x00000000] {
            let e = RDPError.from(code: code, rawMessage: "")
            XCTAssertFalse(e.humanMessage.isEmpty, "humanMessage empty for code \(code)")
        }
    }

    // MARK: - suggestedAction presence

    func testSuggestedActionAuth() {
        let e = RDPError.from(code: 0x00020014, rawMessage: "")
        XCTAssertNotNil(e.suggestedAction)
    }

    func testSuggestedActionCert() {
        let e = RDPError.from(code: RDPError.bridgeCertRejectedCode, rawMessage: "")
        XCTAssertNotNil(e.suggestedAction)
    }

    func testSuggestedActionHostUnreachable() {
        // hostUnreachable has no direct code mapping; verify via message fallback
        // (the hostname path) yields suggestedAction.
        let e = RDPError.from(code: 0xFFFFFFFF, rawMessage: "dns resolution failed")
        XCTAssertNotNil(e.suggestedAction)
    }

    func testSuggestedActionRetryForConnectionFailed() {
        let e = RDPError.from(code: 0x00020006, rawMessage: "")
        XCTAssertEqual(e.suggestedAction, "Retry")
    }

    func testSuggestedActionRetryForTimeout() {
        let e = RDPError.from(code: 0x0002001C, rawMessage: "")
        XCTAssertEqual(e.suggestedAction, "Retry")
    }

    func testSuggestedActionNilForCancelled() {
        let e = RDPError.from(code: 0x00000000, rawMessage: "")
        XCTAssertNil(e.suggestedAction)
    }

    // MARK: - Empty password (bridge RDPB_ERROR_NO_CREDENTIALS)

    func testBridgeNoCredentialsCodeMeansResaveThePassword() {
        let e = RDPError.from(code: RDPError.bridgeNoCredentialsCode, rawMessage: "the saved password is empty")
        XCTAssertEqual(e.cause, .credentialsUnavailable)
        XCTAssertEqual(e.suggestedAction, "Update saved password")
        // The bridge's own sentence is what the overlay shows, not the generic fallback.
        XCTAssertEqual(e.humanMessage, "the saved password is empty")
        // Bridge-private: outside every FreeRDP error class, and distinct from the cert code.
        XCTAssertNotEqual(RDPError.bridgeNoCredentialsCode & 0xFFFF0000, 0x00020000)
        XCTAssertNotEqual(RDPError.bridgeNoCredentialsCode, RDPError.bridgeCertRejectedCode)
    }

    func testCredentialsUnavailableFallsBackToGenericTextWithoutDetail() {
        let e = RDPError(code: 0, rawMessage: "", cause: .credentialsUnavailable)
        XCTAssertTrue(e.humanMessage.contains("Re-save"))
    }

    func testCredentialHandoffFailureIsLocalAndActionable() {
        let e = RDPError.from(code: RDPError.bridgeCredentialHandoffCode,
                              rawMessage: "The password could not be handed to FreeRDP intact.")
        XCTAssertEqual(e.cause, .credentialsUnavailable)
        XCTAssertEqual(e.suggestedAction, "Update saved password")
        XCTAssertEqual(e.humanMessage, "The password could not be handed to FreeRDP intact.")
        XCTAssertNotEqual(RDPError.bridgeCredentialHandoffCode & 0xFFFF0000, 0x00020000)
        XCTAssertNotEqual(RDPError.bridgeCredentialHandoffCode, RDPError.bridgeNoCredentialsCode)
    }
}
