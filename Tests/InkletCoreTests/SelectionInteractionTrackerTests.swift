import XCTest

@testable import Inklet

final class SelectionInteractionTrackerTests: XCTestCase {
    func testMouseReleaseStaysActiveUntilCandidateHandoffCompletes() {
        let tracker = SelectionInteractionTracker()

        XCTAssertEqual(tracker.begin(.mouse), .becameActive)
        XCTAssertEqual(tracker.enqueueHandoff(for: .mouse), .unchanged)
        XCTAssertEqual(tracker.release(.mouse), .unchanged)
        XCTAssertTrue(tracker.isActive)

        XCTAssertEqual(tracker.completeHandoff(for: .mouse), .becameIdle)
        XCTAssertFalse(tracker.isActive)
    }

    func testShiftReleaseStaysActiveUntilEveryQueuedCandidateHandoffCompletes() {
        let tracker = SelectionInteractionTracker()

        XCTAssertEqual(tracker.begin(.keyboard), .becameActive)
        XCTAssertEqual(tracker.enqueueHandoff(for: .keyboard), .unchanged)
        XCTAssertEqual(tracker.enqueueHandoff(for: .keyboard), .unchanged)
        XCTAssertEqual(tracker.release(.keyboard), .unchanged)

        XCTAssertEqual(tracker.completeHandoff(for: .keyboard), .unchanged)
        XCTAssertTrue(tracker.isActive)
        XCTAssertEqual(tracker.completeHandoff(for: .keyboard), .becameIdle)
        XCTAssertFalse(tracker.isActive)
    }

    func testOverlappingKindsProduceOneAggregateIdleTransition() {
        let tracker = SelectionInteractionTracker()

        XCTAssertEqual(tracker.begin(.mouse), .becameActive)
        XCTAssertEqual(tracker.begin(.keyboard), .unchanged)
        XCTAssertEqual(tracker.begin(.copy), .unchanged)
        XCTAssertEqual(tracker.release(.mouse), .unchanged)
        XCTAssertEqual(tracker.release(.keyboard), .unchanged)
        XCTAssertEqual(tracker.release(.copy), .becameIdle)
        XCTAssertEqual(tracker.release(.copy), .unchanged)
    }

    func testResetClearsPressedKindsAndPendingHandoffs() {
        let tracker = SelectionInteractionTracker()
        _ = tracker.begin(.mouse)
        _ = tracker.begin(.keyboard)
        _ = tracker.enqueueHandoff(for: .mouse)

        XCTAssertEqual(tracker.reset(), .becameIdle)
        XCTAssertFalse(tracker.isActive)
        XCTAssertEqual(tracker.release(.mouse), .unchanged)
        XCTAssertEqual(tracker.completeHandoff(for: .mouse), .unchanged)
        XCTAssertEqual(tracker.reset(), .unchanged)
    }

    @MainActor
    func testStoppedMonitorDoesNotReportTrackedOrPhysicalInteractionState() {
        let tracker = SelectionInteractionTracker()
        let physical = SelectionPhysicalInteractionTestState()
        let monitor = SelectionActionMonitor(
            interactionTracker: tracker,
            physicalInteractionStateProvider: { physical.state }
        )

        XCTAssertFalse(monitor.isInteractionActive)
        physical.state = SelectionPhysicalInteractionState(
            isLeftMouseButtonPressed: true,
            isShiftPressed: false
        )
        XCTAssertFalse(monitor.isInteractionActive)
        physical.state = SelectionPhysicalInteractionState(
            isLeftMouseButtonPressed: false,
            isShiftPressed: false
        )
        _ = tracker.begin(.copy)
        XCTAssertFalse(monitor.isInteractionActive)
    }
}

@MainActor
private final class SelectionPhysicalInteractionTestState {
    var state = SelectionPhysicalInteractionState(
        isLeftMouseButtonPressed: false,
        isShiftPressed: false
    )
}
