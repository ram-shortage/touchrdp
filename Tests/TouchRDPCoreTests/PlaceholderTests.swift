import XCTest
@testable import TouchRDPCore

final class PlaceholderTests: XCTestCase {
    func testErrorTranslation() {
        let e = RDPError.from(code: 0x00020006, rawMessage: "The connection failed.")
        XCTAssertEqual(e.cause, .connectionFailed)
        XCTAssertNotNil(e.suggestedAction)
    }
}
