import XCTest
@testable import InkletCore

final class SelectionDragPolicyTests: XCTestCase {
    func testClickWithoutDragDoesNotTriggerCandidate() {
        var policy = SelectionDragPolicy(minimumDistance: 6)
        policy.recordMouseDown(at: SelectionPoint(x: 10, y: 10))

        XCTAssertFalse(policy.consumeMouseUp(at: SelectionPoint(x: 12, y: 12)))
    }

    func testDragPastThresholdTriggersCandidate() {
        var policy = SelectionDragPolicy(minimumDistance: 6)
        policy.recordMouseDown(at: SelectionPoint(x: 10, y: 10))

        XCTAssertTrue(policy.consumeMouseUp(at: SelectionPoint(x: 20, y: 10)))
    }

    func testMouseUpActionReturnsDismissForClickWithoutDrag() {
        var policy = SelectionDragPolicy(minimumDistance: 6)
        policy.recordMouseDown(at: SelectionPoint(x: 10, y: 10))

        XCTAssertEqual(policy.consumeMouseUpAction(at: SelectionPoint(x: 12, y: 12)), .dismiss)
    }

    func testMouseUpActionReturnsCandidateForDragPastThreshold() {
        var policy = SelectionDragPolicy(minimumDistance: 6)
        policy.recordMouseDown(at: SelectionPoint(x: 10, y: 10))

        XCTAssertEqual(policy.consumeMouseUpAction(at: SelectionPoint(x: 20, y: 10)), .candidateSelection)
    }

    func testMouseUpActionReturnsCandidateForDoubleClick() {
        var policy = SelectionDragPolicy(minimumDistance: 6)
        policy.recordMouseDown(at: SelectionPoint(x: 10, y: 10))

        XCTAssertEqual(
            policy.consumeMouseUpAction(at: SelectionPoint(x: 10, y: 10), clickCount: 2),
            .candidateSelection
        )
    }

    func testMouseUpActionReturnsCandidateForDoubleClickWithoutMouseDown() {
        var policy = SelectionDragPolicy(minimumDistance: 6)

        XCTAssertEqual(
            policy.consumeMouseUpAction(at: SelectionPoint(x: 10, y: 10), clickCount: 2),
            .candidateSelection
        )
    }

    func testMouseUpWithoutMouseDownDoesNotTriggerCandidate() {
        var policy = SelectionDragPolicy(minimumDistance: 6)

        XCTAssertFalse(policy.consumeMouseUp(at: SelectionPoint(x: 20, y: 10)))
    }
}
