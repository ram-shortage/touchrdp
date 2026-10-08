import XCTest
@testable import TouchRDPCore

final class FileCertificateTrustStoreTests: XCTestCase {

    private var store: FileCertificateTrustStore!

    // Unique host per test run to avoid cross-test pollution.
    private let host = "trust-test-\(UUID().uuidString).example.com"
    private let port = 3389

    override func setUp() {
        super.setUp()
        store = FileCertificateTrustStore()
    }

    override func tearDown() {
        // Always remove the pinned entry we may have written.
        store.remove(host: host, port: port)
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeCertInfo(fingerprint: String) -> CertInfo {
        CertInfo(
            host: host,
            port: port,
            commonName: host,
            subject: "CN=\(host)",
            issuer: "CN=TestCA",
            fingerprintSHA256: fingerprint,
            hostMismatch: false,
            changed: false
        )
    }

    // MARK: - TOFU: first evaluate is unknown

    func testFirstEvaluateIsUnknown() {
        let info = makeCertInfo(fingerprint: "aabbcc")
        XCTAssertEqual(store.evaluate(info), .unknown)
    }

    // MARK: - Trusted after pin with same fingerprint

    func testTrustedAfterPin() {
        let info = makeCertInfo(fingerprint: "deadbeef")
        store.pin(info)
        XCTAssertEqual(store.evaluate(info), .trusted)
    }

    // MARK: - Changed when different fingerprint presented

    func testChangedWhenFingerprintDiffers() {
        let original = makeCertInfo(fingerprint: "originalfp")
        store.pin(original)

        let different = makeCertInfo(fingerprint: "differentfp")
        let result = store.evaluate(different)

        XCTAssertEqual(result, .changed(previousFingerprint: "originalfp"))
    }

    // MARK: - Pin overwrites previous

    func testPinOverwritesPrevious() {
        let first = makeCertInfo(fingerprint: "fp1")
        store.pin(first)

        let second = makeCertInfo(fingerprint: "fp2")
        store.pin(second)

        XCTAssertEqual(store.evaluate(second), .trusted)
    }

    // MARK: - Remove clears pin

    func testRemoveClearsPinnedEntry() {
        let info = makeCertInfo(fingerprint: "pinnedvalue")
        store.pin(info)
        store.remove(host: host, port: port)
        XCTAssertEqual(store.evaluate(info), .unknown)
    }

    func testRemoveNonExistentIsNoop() {
        // Should not crash.
        XCTAssertNoThrow(store.remove(host: "nonexistent.host", port: 9999))
    }

    // MARK: - Different port treated as distinct entry

    func testDifferentPortIsIndependent() {
        let info3389 = CertInfo(host: host, port: 3389, commonName: host,
                                subject: "", issuer: "", fingerprintSHA256: "fp-3389",
                                hostMismatch: false, changed: false)
        let info3390 = CertInfo(host: host, port: 3390, commonName: host,
                                subject: "", issuer: "", fingerprintSHA256: "fp-3390",
                                hostMismatch: false, changed: false)
        store.pin(info3389)
        defer { store.remove(host: host, port: 3390) }

        // 3390 should still be unknown after only 3389 was pinned.
        XCTAssertEqual(store.evaluate(info3390), .unknown)

        // Pin 3390 — both should now be trusted independently.
        store.pin(info3390)
        XCTAssertEqual(store.evaluate(info3389), .trusted)
        XCTAssertEqual(store.evaluate(info3390), .trusted)
    }
}
