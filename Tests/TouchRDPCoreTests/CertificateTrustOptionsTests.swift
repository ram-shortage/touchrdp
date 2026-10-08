import XCTest
import CoreGraphics
@testable import TouchRDPCore
@testable import TouchRDPEngine

/// Per-connection certificate modes (ask / trust on first use / don't check) and
/// pre-trusting a certificate from a pasted fingerprint or an imported file.
final class CertificateFingerprintTests: XCTestCase {

    // A throwaway self-signed certificate (CN=rdp-test.example) made with
    // `openssl req -x509 -newkey rsa:1024`; the fingerprint is openssl's own
    // `x509 -fingerprint -sha256`, independent of the code under test.
    static let pem = """
        -----BEGIN CERTIFICATE-----
        MIIBrTCCARYCCQCiGArEIGlWJzANBgkqhkiG9w0BAQsFADAbMRkwFwYDVQQDDBBy
        ZHAtdGVzdC5leGFtcGxlMB4XDTI2MTAwODExMjQyOVoXDTM2MTAwNTExMjQyOVow
        GzEZMBcGA1UEAwwQcmRwLXRlc3QuZXhhbXBsZTCBnzANBgkqhkiG9w0BAQEFAAOB
        jQAwgYkCgYEAz8j+BDEvUSYsbXrlE211u4BYomYikdcxhX3Bu6SYk5m598KTC9Fj
        POoqcVwTIi3AUNQ5n9FAPoamJniv5hiiaj+mD4kNw5MkCi+ov+gzIT3y7xmsEog1
        uxDxZa6Xb9S+n3CT1cEhj4coaSzAzaibty3mv3z46bTKPrH72QXSIdcCAwEAATAN
        BgkqhkiG9w0BAQsFAAOBgQCX6+9Bb4QzaBxnbiEMzslUVupe5PZAf7ZrJUUx4+/1
        BaH9QqwRtbREEnUv8sykrFgal0AO8riduMscBpWh+uRYwbYx3ckjjc6r1E0A+RyP
        Sm1EFON43QUjkhwAFeR1pWtVAJ/Pv8fS9qV/1gk0P/GIno5jGVKgEpxztXyH8tAr
        5g==
        -----END CERTIFICATE-----
        """
    static let opensslFingerprint =
        "10:F7:3C:D6:FB:47:FD:CE:DA:05:7D:F5:42:FB:A6:53:EA:DD:E2:A6:09:8F:2E:85:98:D7:88:BF:E9:EC:21:3A"
    /// The form FreeRDP hands the verify callback: lowercase, colon-separated.
    static let canonical = opensslFingerprint.lowercased()

    // MARK: Fingerprint text

    func testNormalizeAcceptsCommonLayouts() throws {
        let bare = Self.canonical.replacingOccurrences(of: ":", with: "")
        let inputs = [
            Self.opensslFingerprint,
            Self.canonical,
            bare,
            bare.uppercased(),
            Self.canonical.replacingOccurrences(of: ":", with: " "),
            Self.canonical.replacingOccurrences(of: ":", with: "-"),
            "SHA256 Fingerprint=\(Self.opensslFingerprint)\n",
            "  \(bare)  ",
        ]
        for input in inputs {
            XCTAssertEqual(try CertificateFingerprint.normalize(input), Self.canonical, input)
        }
    }

    func testNormalizeRejectsWhatIsNotASHA256Fingerprint() {
        func error(_ text: String) -> CertificateFingerprint.ParseError? {
            do { _ = try CertificateFingerprint.normalize(text); return nil }
            catch { return error as? CertificateFingerprint.ParseError }
        }
        XCTAssertEqual(error(""), .empty)
        XCTAssertEqual(error("  :: "), .empty)
        XCTAssertEqual(error("5F:2E:5F:BE:91:A0:73:B4:FB:E1:4C:4D:D7:97:33:F7:E7:98:7D:F7"),
                       .looksLikeSHA1, "Windows shows a SHA-1 thumbprint by default")
        XCTAssertEqual(error("zz" + String(repeating: "0", count: 62)), .notHex)
        XCTAssertEqual(error("abcd"), .wrongLength(digits: 4))
        XCTAssertEqual(error(String(repeating: "a", count: 66)), .wrongLength(digits: 66))
    }

    // MARK: Certificate files

    func testParsesPEM() throws {
        let cert = try ImportedCertificate.parse(Data(Self.pem.utf8))
        XCTAssertEqual(cert.fingerprintSHA256, Self.canonical)
        XCTAssertEqual(cert.commonName, "rdp-test.example")
    }

    func testParsesDERToTheSameFingerprint() throws {
        let body = Self.pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: body))
        XCTAssertEqual(try ImportedCertificate.parse(der).fingerprintSHA256, Self.canonical)
    }

    func testPEMChainUsesTheFirstCertificate() throws {
        let other = Self.pem.replacingOccurrences(of: "5g==", with: "5h==")
        let chain = "Subject: something\n" + Self.pem + "\n" + other + "\n"
        XCTAssertEqual(try ImportedCertificate.parse(Data(chain.utf8)).fingerprintSHA256,
                       Self.canonical)
    }

    func testRejectsNonCertificates() {
        XCTAssertThrowsError(try ImportedCertificate.parse(Data("hello".utf8))) {
            XCTAssertEqual($0 as? ImportedCertificate.ImportError, .notACertificate)
        }
        XCTAssertThrowsError(try ImportedCertificate.parse(Data())) {
            XCTAssertEqual($0 as? ImportedCertificate.ImportError, .notACertificate)
        }
        let garbledPEM = "-----BEGIN CERTIFICATE-----\nnot base64!\n-----END CERTIFICATE-----"
        XCTAssertThrowsError(try ImportedCertificate.parse(Data(garbledPEM.utf8))) {
            XCTAssertEqual($0 as? ImportedCertificate.ImportError, .notACertificate)
        }
        let huge = Data(count: ImportedCertificate.maxFileBytes + 1)
        XCTAssertThrowsError(try ImportedCertificate.parse(huge)) {
            XCTAssertEqual($0 as? ImportedCertificate.ImportError, .tooLarge)
        }
    }

    // MARK: Model

    func testCertificateModeDecodesSafely() throws {
        let missing = #"{"name":"a","host":"h","username":"u"}"#
        XCTAssertEqual(try JSONDecoder().decode(Connection.self, from: Data(missing.utf8))
            .certificateMode, .ask)
        let unknown = #"{"name":"a","host":"h","username":"u","certificateMode":"whatever"}"#
        XCTAssertEqual(try JSONDecoder().decode(Connection.self, from: Data(unknown.utf8))
            .certificateMode, .ask, "an unrecognised value must never weaken checking")

        for mode in CertificateCheckMode.allCases {
            let c = Connection(name: "a", host: "h", username: "u", certificateMode: mode)
            let decoded = try JSONDecoder().decode(Connection.self,
                                                   from: JSONEncoder().encode(c))
            XCTAssertEqual(decoded.certificateMode, mode)
        }
    }
}

@MainActor
final class CertificateModeVerifyTests: XCTestCase {

    private let host = "10.0.0.5"
    private let port = 3389
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cert-mode-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeController(mode: CertificateCheckMode, store: FileCertificateTrustStore)
        -> SessionController {
        let controller = SessionController(makeSession: { StubSession() }, trustStore: store,
                                           checkReachability: { _, _ in nil })
        controller.connect(Connection(name: "T", host: host, port: port, username: "u",
                                      certificateMode: mode),
                           passwordProvider: { _ in ConnectionSecrets(primary: "pw") })
        return controller
    }

    private func cert(_ fingerprint: String, mismatch: Bool = false) -> CertInfo {
        CertInfo(host: host, port: port, commonName: "WIN-SERVER", subject: "CN=WIN-SERVER",
                 issuer: "CN=WIN-SERVER", fingerprintSHA256: fingerprint,
                 hostMismatch: mismatch, changed: false)
    }

    private let fpA = String(repeating: "aa:", count: 31) + "aa"
    private let fpB = String(repeating: "bb:", count: 31) + "bb"

    func testAskStillReviewsAFirstSeenCertificate() async {
        let store = FileCertificateTrustStore(directory: dir)
        let controller = makeController(mode: .ask, store: store)
        XCTAssertFalse(controller.sessionVerifyCertificate(cert(fpA)))
        await Task.yield()
        XCTAssertEqual(controller.pendingCertReview?.kind, .firstUse)
        XCTAssertNil(store.pinnedRecord(host: host, port: port))
    }

    func testTrustFirstUsePinsSilentlyThenReviewsAChange() async {
        let store = FileCertificateTrustStore(directory: dir)
        let controller = makeController(mode: .trustFirstUse, store: store)

        XCTAssertTrue(controller.sessionVerifyCertificate(cert(fpA, mismatch: true)),
                      "connecting by IP to a self-signed cert always mismatches; the mode must still accept it")
        await Task.yield()
        XCTAssertNil(controller.pendingCertReview)
        XCTAssertEqual(store.pinnedRecord(host: host, port: port)?.fingerprintSHA256, fpA)

        XCTAssertTrue(controller.sessionVerifyCertificate(cert(fpA)), "same cert next time")

        XCTAssertFalse(controller.sessionVerifyCertificate(cert(fpB)),
                       "a changed certificate must still stop for review")
        await Task.yield()
        XCTAssertEqual(controller.pendingCertReview?.kind, .changed)
        XCTAssertEqual(store.pinnedRecord(host: host, port: port)?.fingerprintSHA256, fpA)
    }

    func testIgnoreAcceptsAnythingAndLeavesPinsAlone() async {
        let store = FileCertificateTrustStore(directory: dir)
        store.pin(cert(fpA))
        let controller = makeController(mode: .ignore, store: store)

        XCTAssertTrue(controller.sessionVerifyCertificate(cert(fpB, mismatch: true)))
        await Task.yield()
        XCTAssertNil(controller.pendingCertReview)
        XCTAssertEqual(store.pinnedRecord(host: host, port: port)?.fingerprintSHA256, fpA,
                       "turning checking back on must find the original pin")

        let otherDir = dir.appendingPathComponent("fresh", isDirectory: true)
        let empty = FileCertificateTrustStore(directory: otherDir)
        let fresh = makeController(mode: .ignore, store: empty)
        XCTAssertTrue(fresh.sessionVerifyCertificate(cert(fpA)))
        XCTAssertNil(empty.pinnedRecord(host: host, port: port), "ignore never pins")
    }

    /// A server redirect makes FreeRDP verify a host the SERVER named. The relaxed modes
    /// were chosen for the typed host only, and a first-use pin would be shared with
    /// every other connection to the redirect target — so it gets the normal review.
    func testRelaxedModesDoNotCoverARedirectTarget() async {
        let store = FileCertificateTrustStore(directory: dir)
        for mode in [CertificateCheckMode.trustFirstUse, .ignore] {
            let controller = makeController(mode: mode, store: store)
            let redirected = CertInfo(host: "broker-target.internal", port: 3389,
                                      commonName: "X", subject: "X", issuer: "X",
                                      fingerprintSHA256: fpB, hostMismatch: false, changed: false)
            XCTAssertFalse(controller.sessionVerifyCertificate(redirected), "\(mode)")
            await Task.yield()
            XCTAssertEqual(controller.pendingCertReview?.kind, .firstUse, "\(mode)")
            XCTAssertNil(store.pinnedRecord(host: "broker-target.internal", port: 3389))
        }
    }

    /// The gateway the user typed is covered, matched case-insensitively.
    func testRelaxedModeCoversTheConfiguredGateway() async {
        let store = FileCertificateTrustStore(directory: dir)
        let controller = SessionController(makeSession: { StubSession() }, trustStore: store,
                                           checkReachability: { _, _ in nil })
        var connection = Connection(name: "T", host: host, port: port, username: "u",
                                    certificateMode: .trustFirstUse)
        connection.gateway = GatewaySettings(hostname: "GW.Example.com", port: 443)
        controller.connect(connection, passwordProvider: { _ in ConnectionSecrets(primary: "pw") })
        let gateway = CertInfo(host: "gw.example.com", port: 443, commonName: "gw",
                               subject: "gw", issuer: "gw", fingerprintSHA256: fpA,
                               hostMismatch: false, changed: false)
        XCTAssertTrue(controller.sessionVerifyCertificate(gateway))
    }

    /// Switching the mode in the editor takes effect at the next connect.
    func testModeIsReadAtEachConnect() async {
        let store = FileCertificateTrustStore(directory: dir)
        let controller = makeController(mode: .ignore, store: store)
        XCTAssertTrue(controller.sessionVerifyCertificate(cert(fpA)))

        controller.connect(Connection(name: "T", host: host, port: port, username: "u"),
                           passwordProvider: { _ in ConnectionSecrets(primary: "pw") })
        XCTAssertFalse(controller.sessionVerifyCertificate(cert(fpA)))
    }

    /// A fingerprint pasted in any layout, or read from the certificate file, matches
    /// what FreeRDP later reports for the same certificate — so the first connect
    /// goes straight through.
    func testImportedCertificateIsTrustedOnFirstConnect() async throws {
        let store = FileCertificateTrustStore(directory: dir)
        let imported = try ImportedCertificate.parse(Data(CertificateFingerprintTests.pem.utf8))
        store.pin(CertInfo(host: host, port: port, commonName: imported.commonName,
                           subject: imported.subject, issuer: "",
                           fingerprintSHA256: imported.fingerprintSHA256,
                           hostMismatch: false, changed: false))
        let controller = makeController(mode: .ask, store: store)

        XCTAssertTrue(controller.sessionVerifyCertificate(
            cert(CertificateFingerprintTests.canonical, mismatch: true)))
        await Task.yield()
        XCTAssertNil(controller.pendingCertReview)

        XCTAssertFalse(controller.sessionVerifyCertificate(cert(fpB)))
        await Task.yield()
        XCTAssertEqual(controller.pendingCertReview?.kind, .changed)
    }
}

// MARK: - Doubles

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
