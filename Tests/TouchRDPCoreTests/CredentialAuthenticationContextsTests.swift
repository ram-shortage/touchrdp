import XCTest
@testable import TouchRDPCore

final class CredentialAuthenticationContextsTests: XCTestCase {
    func testEveryConnectRequiresFreshAppAuthentication() {
        let contexts = CredentialAuthenticationContexts()
        let id = UUID()
        let directive = CredentialPolicy.biometricEveryConnect.authDirective(for: .userInitiated)
        let first = contexts.begin(for: id, reuseSeconds: directive.reuseSeconds,
                                   forceFresh: directive.forceFreshPrompt)
        XCTAssertEqual(first.context.touchIDAuthenticationAllowableReuseDuration, 0)
        contexts.complete(first)
        let second = contexts.begin(for: id, reuseSeconds: directive.reuseSeconds,
                                    forceFresh: directive.forceFreshPrompt)
        XCTAssertFalse(first.context === second.context)
        XCTAssertNil(second.authenticatedAt)
        XCTAssertEqual(second.context.touchIDAuthenticationAllowableReuseDuration, 0)
    }

    func testOnlyCompletedAuthenticationCanBeReused() {
        let contexts = CredentialAuthenticationContexts()
        let id = UUID()
        let pending = contexts.begin(for: id, reuseSeconds: 300, forceFresh: false)
        let next = contexts.begin(for: id, reuseSeconds: 300, forceFresh: false)
        XCTAssertFalse(pending.context === next.context)
        contexts.complete(next)
        let automatic = CredentialPolicy.biometricEveryConnect.authDirective(for: .automaticReconnect)
        let reused = contexts.begin(for: id, reuseSeconds: automatic.reuseSeconds,
                                    forceFresh: automatic.forceFreshPrompt)
        XCTAssertTrue(reused.context === next.context)
        XCTAssertNotNil(reused.authenticatedAt)
        let other = contexts.begin(for: UUID(), reuseSeconds: 300, forceFresh: false)
        XCTAssertNil(other.authenticatedAt)
    }

    func testReuseDoesNotExtendTheAuthenticationWindow() {
        var now = Date(timeIntervalSince1970: 1000)
        let contexts = CredentialAuthenticationContexts(now: { now })
        let id = UUID()
        let first = contexts.begin(for: id, reuseSeconds: 3000, forceFresh: false)
        contexts.complete(first)
        now.addTimeInterval(299)
        let reused = contexts.begin(for: id, reuseSeconds: 3000, forceFresh: false)
        XCTAssertTrue(reused.context === first.context)
        contexts.complete(reused)
        now.addTimeInterval(2)
        let expired = contexts.begin(for: id, reuseSeconds: 3000, forceFresh: false)
        XCTAssertNil(expired.authenticatedAt)
        XCTAssertFalse(expired.context === first.context)
    }

    func testShorterPolicyAppliesToAnExistingContext() {
        var now = Date(timeIntervalSince1970: 1000)
        let contexts = CredentialAuthenticationContexts(now: { now })
        let id = UUID()
        let first = contexts.begin(for: id, reuseSeconds: 300, forceFresh: false)
        contexts.complete(first)
        now.addTimeInterval(61)
        XCTAssertNil(contexts.begin(for: id, reuseSeconds: 60, forceFresh: false).authenticatedAt)
    }

    func testEvictionPreventsAnInFlightReadFromRestoringReuse() {
        let contexts = CredentialAuthenticationContexts()
        let id = UUID()
        let request = contexts.begin(for: id, reuseSeconds: 300, forceFresh: false)
        contexts.evict(for: id)
        contexts.complete(request)
        XCTAssertNil(contexts.begin(for: id, reuseSeconds: 300, forceFresh: false).authenticatedAt)
        let another = contexts.begin(for: id, reuseSeconds: 300, forceFresh: false)
        contexts.evictAll()
        contexts.complete(another)
        XCTAssertNil(contexts.begin(for: id, reuseSeconds: 300, forceFresh: false).authenticatedAt)
    }

    func testNoReuseAlsoDisablesDeviceUnlockReuse() {
        let contexts = CredentialAuthenticationContexts()
        for seconds: Int? in [nil, 0, -1] {
            let id = UUID()
            let first = contexts.begin(for: id, reuseSeconds: seconds, forceFresh: true)
            contexts.complete(first)
            let second = contexts.begin(for: id, reuseSeconds: seconds, forceFresh: false)
            XCTAssertEqual(first.context.touchIDAuthenticationAllowableReuseDuration, 0)
            XCTAssertNil(second.authenticatedAt)
            XCTAssertFalse(first.context === second.context)
        }
    }
}
