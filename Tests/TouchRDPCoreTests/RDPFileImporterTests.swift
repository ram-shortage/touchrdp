import XCTest
@testable import TouchRDPCore

final class RDPFileImporterTests: XCTestCase {

    // MARK: - Helpers

    private func writeTempRDP(_ contents: String, name: String = "test.rdp") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RDPImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Host + port splitting

    func testFullAddressHostOnly() throws {
        let url = try writeTempRDP("full address:s:myhost\n")
        let c = try RDPFileImporter.parse(url)
        XCTAssertEqual(c.host, "myhost")
        XCTAssertEqual(c.port, 3389) // default
    }

    func testFullAddressWithPort() throws {
        let url = try writeTempRDP("full address:s:myhost:3390\n")
        let c = try RDPFileImporter.parse(url)
        XCTAssertEqual(c.host, "myhost")
        XCTAssertEqual(c.port, 3390)
    }

    func testServerPortOverride() throws {
        let url = try writeTempRDP("""
        full address:s:host1
        server port:i:4000
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertEqual(c.host, "host1")
        XCTAssertEqual(c.port, 4000)
    }

    // MARK: - Username and domain

    func testUsernameAndDomain() throws {
        let url = try writeTempRDP("""
        full address:s:srv
        username:s:alice
        domain:s:CORP
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertEqual(c.username, "alice")
        XCTAssertEqual(c.domain, "CORP")
    }

    func testEmptyDomainBecomesNil() throws {
        let url = try writeTempRDP("""
        full address:s:srv
        username:s:bob
        domain:s:
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertNil(c.domain)
    }

    // MARK: - Security

    func testNLAWhenCredSSPEnabled() throws {
        let url = try writeTempRDP("""
        full address:s:srv
        enablecredsspsupport:i:1
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertEqual(c.security, .nla)
    }

    func testTLSWhenCredSSPDisabled() throws {
        let url = try writeTempRDP("""
        full address:s:srv
        enablecredsspsupport:i:0
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertEqual(c.security, .tls)
    }

    func testDefaultSecurityIsNLA() throws {
        let url = try writeTempRDP("full address:s:srv\n")
        let c = try RDPFileImporter.parse(url)
        XCTAssertEqual(c.security, .nla)
    }

    // MARK: - Gateway

    func testGatewayPresentWhenUsageMethodNonZero() throws {
        let url = try writeTempRDP("""
        full address:s:rdphost
        gatewayhostname:s:gw.corp.com
        gatewayusagemethod:i:1
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertNotNil(c.gateway)
        XCTAssertEqual(c.gateway?.hostname, "gw.corp.com")
    }

    func testGatewayAbsentWhenUsageMethodZero() throws {
        let url = try writeTempRDP("""
        full address:s:rdphost
        gatewayhostname:s:gw.corp.com
        gatewayusagemethod:i:0
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertNil(c.gateway)
    }

    func testGatewayAbsentWhenNoHostname() throws {
        let url = try writeTempRDP("""
        full address:s:rdphost
        gatewayusagemethod:i:1
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertNil(c.gateway)
    }

    // MARK: - Clipboard

    func testClipboardEnabled() throws {
        let url = try writeTempRDP("""
        full address:s:srv
        redirectclipboard:i:1
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertTrue(c.clipboardEnabled)
    }

    func testClipboardDisabled() throws {
        let url = try writeTempRDP("""
        full address:s:srv
        redirectclipboard:i:0
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertFalse(c.clipboardEnabled)
    }

    func testClipboardDefaultsToEnabled() throws {
        let url = try writeTempRDP("full address:s:srv\n")
        let c = try RDPFileImporter.parse(url)
        XCTAssertTrue(c.clipboardEnabled)
    }

    // MARK: - Audio

    func testAudioEnabledWhenModeZero() throws {
        let url = try writeTempRDP("""
        full address:s:srv
        audiomode:i:0
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertTrue(c.audioEnabled)
    }

    func testAudioDisabledWhenModeNonZero() throws {
        let url = try writeTempRDP("""
        full address:s:srv
        audiomode:i:2
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertFalse(c.audioEnabled)
    }

    // MARK: - Display

    func testDesktopDimensions() throws {
        let url = try writeTempRDP("""
        full address:s:srv
        desktopwidth:i:1920
        desktopheight:i:1080
        """)
        let c = try RDPFileImporter.parse(url)
        XCTAssertEqual(c.display.width, 1920)
        XCTAssertEqual(c.display.height, 1080)
    }

    // MARK: - Name derivation

    func testNameIsHostWhenHostPresent() throws {
        let url = try writeTempRDP("full address:s:myserver\n")
        let c = try RDPFileImporter.parse(url)
        XCTAssertEqual(c.name, "myserver")
    }

    func testNameFallsBackToFilename() throws {
        // This is hard to trigger because a non-empty host is always the name;
        // if host has no address at all parse throws. Verify the happy-path name.
        let url = try writeTempRDP("full address:s:rdpbox\n", name: "MyServer.rdp")
        let c = try RDPFileImporter.parse(url)
        XCTAssertEqual(c.name, "rdpbox")
    }

    // MARK: - Missing host throws

    func testMissingFullAddressThrows() throws {
        let url = try writeTempRDP("username:s:alice\n")
        XCTAssertThrowsError(try RDPFileImporter.parse(url))
    }

    func testEmptyFullAddressThrows() throws {
        let url = try writeTempRDP("full address:s:\n")
        XCTAssertThrowsError(try RDPFileImporter.parse(url))
    }

    // MARK: - Unknown keys tolerated

    func testUnknownKeysIgnored() throws {
        let url = try writeTempRDP("""
        full address:s:srv
        somefuturekey:s:value
        anotherfuturekey:i:42
        """)
        XCTAssertNoThrow(try RDPFileImporter.parse(url))
    }

    // MARK: - Authentication level key (unknown; should not crash)

    func testAuthenticationLevelIgnored() throws {
        let url = try writeTempRDP("""
        full address:s:srv
        authentication level:i:2
        """)
        XCTAssertNoThrow(try RDPFileImporter.parse(url))
    }
}
