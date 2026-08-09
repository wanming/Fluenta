import XCTest
@testable import InkletCore

final class FocusRequestGenerationTests: XCTestCase {
    func testNewestIssuedRequestIsCurrent() {
        var generation = FocusRequestGeneration()

        let request = generation.issue()

        XCTAssertTrue(generation.isCurrent(request))
    }

    func testIssuingNewRequestMakesOlderQueuedRequestStale() {
        var generation = FocusRequestGeneration()
        let firstRequest = generation.issue()

        let secondRequest = generation.issue()

        XCTAssertFalse(generation.isCurrent(firstRequest))
        XCTAssertTrue(generation.isCurrent(secondRequest))
        XCTAssertNotEqual(firstRequest, secondRequest)
    }

    func testInvalidationMakesQueuedRequestStaleUntilAnotherRequestIsIssued() {
        var generation = FocusRequestGeneration()
        let queuedRequest = generation.issue()

        generation.invalidate()

        XCTAssertFalse(generation.isCurrent(queuedRequest))

        let replacementRequest = generation.issue()
        XCTAssertTrue(generation.isCurrent(replacementRequest))
        XCTAssertNotEqual(queuedRequest, replacementRequest)
    }
}
