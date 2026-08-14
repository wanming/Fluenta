import XCTest
@testable import InkletCore

final class SelectionActionDiagnosticRateLimiterTests: XCTestCase {
    func testInterleavedRepeatedSignaturesAreRateLimitedIndependently() {
        var limiter = SelectionActionDiagnosticRateLimiter(interval: 1)

        XCTAssertEqual(limiter.record(signature: "candidate", at: 10), .log(suppressedCount: 0))
        XCTAssertEqual(limiter.record(signature: "read", at: 10.1), .log(suppressedCount: 0))
        XCTAssertEqual(limiter.record(signature: "candidate", at: 10.2), .suppress)
        XCTAssertEqual(limiter.record(signature: "read", at: 10.3), .suppress)
        XCTAssertEqual(limiter.record(signature: "candidate", at: 11), .log(suppressedCount: 1))
        XCTAssertEqual(limiter.record(signature: "read", at: 11.1), .log(suppressedCount: 1))
    }

    func testResetClearsSuppressedState() {
        var limiter = SelectionActionDiagnosticRateLimiter(interval: 1)
        _ = limiter.record(signature: "candidate", at: 10)
        _ = limiter.record(signature: "candidate", at: 10.2)

        limiter.reset()

        XCTAssertEqual(limiter.record(signature: "candidate", at: 10.3), .log(suppressedCount: 0))
    }
}
