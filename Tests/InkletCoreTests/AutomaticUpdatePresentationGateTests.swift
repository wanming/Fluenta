import XCTest
@testable import Inklet

@MainActor
final class AutomaticUpdatePresentationGateTests: XCTestCase {
    func testScheduleCoalescesCallsAndDefersPresentation() {
        let state = AutomaticUpdatePresentationGateTestState()
        let deferrer = ControlledAutomaticUpdatePresentationDeferrer()
        let gate = AutomaticUpdatePresentationGate(
            canPresent: { true },
            present: { state.presentationCount += 1 },
            deferAction: { deferrer.enqueue($0) }
        )

        gate.schedule()
        gate.schedule()
        gate.schedule()

        XCTAssertEqual(state.presentationCount, 0)
        XCTAssertEqual(deferrer.actions.count, 1)
        deferrer.runAction(at: 0)
        XCTAssertEqual(state.presentationCount, 1)
        withExtendedLifetime(gate) {}
    }

    func testDefaultDeferrerPresentsAfterScheduleReturns() async {
        let state = AutomaticUpdatePresentationGateTestState(isEligible: true)
        let presented = expectation(description: "automatic update presentation runs")
        let gate = AutomaticUpdatePresentationGate(
            canPresent: { state.isEligible },
            present: {
                state.presentationCount += 1
                state.presentationObservedScheduleReturn = state.didScheduleReturn
                presented.fulfill()
            }
        )

        gate.schedule()
        XCTAssertEqual(state.presentationCount, 0)
        state.didScheduleReturn = true

        await fulfillment(of: [presented], timeout: 1)
        XCTAssertEqual(state.presentationCount, 1)
        XCTAssertTrue(state.presentationObservedScheduleReturn)
        withExtendedLifetime(gate) {}
    }

    func testScheduleRechecksEligibilityAtExecutionTime() {
        let state = AutomaticUpdatePresentationGateTestState(isEligible: true)
        let deferrer = ControlledAutomaticUpdatePresentationDeferrer()
        let gate = AutomaticUpdatePresentationGate(
            canPresent: {
                state.eligibilityCheckCount += 1
                return state.isEligible
            },
            present: { state.presentationCount += 1 },
            deferAction: { deferrer.enqueue($0) }
        )

        gate.schedule()
        state.isEligible = false

        deferrer.runAction(at: 0)
        XCTAssertEqual(state.eligibilityCheckCount, 1)
        XCTAssertEqual(state.presentationCount, 0)
        withExtendedLifetime(gate) {}
    }

    func testBlockedExecutionAllowsExplicitLaterRescheduling() {
        let state = AutomaticUpdatePresentationGateTestState()
        let deferrer = ControlledAutomaticUpdatePresentationDeferrer()
        let gate = AutomaticUpdatePresentationGate(
            canPresent: { state.isEligible },
            present: { state.presentationCount += 1 },
            deferAction: { deferrer.enqueue($0) }
        )

        gate.schedule()
        deferrer.runAction(at: 0)
        XCTAssertEqual(state.presentationCount, 0)

        state.isEligible = true
        gate.schedule()
        XCTAssertEqual(deferrer.actions.count, 2)
        deferrer.runAction(at: 1)
        XCTAssertEqual(state.presentationCount, 1)
        withExtendedLifetime(gate) {}
    }

    func testCancelInvalidatesEnqueuedTask() {
        let state = AutomaticUpdatePresentationGateTestState(isEligible: true)
        let deferrer = ControlledAutomaticUpdatePresentationDeferrer()
        let gate = AutomaticUpdatePresentationGate(
            canPresent: { state.isEligible },
            present: { state.presentationCount += 1 },
            deferAction: { deferrer.enqueue($0) }
        )

        gate.schedule()
        gate.cancel()

        XCTAssertEqual(deferrer.cancellationCount, 1)
        deferrer.runAction(at: 0)
        XCTAssertEqual(state.presentationCount, 0)
        withExtendedLifetime(gate) {}
    }

    func testCancelInvalidatesStaleTaskWithoutClearingReplacement() {
        let state = AutomaticUpdatePresentationGateTestState(isEligible: true)
        let deferrer = ControlledAutomaticUpdatePresentationDeferrer()
        let gate = AutomaticUpdatePresentationGate(
            canPresent: { state.isEligible },
            present: { state.presentationCount += 1 },
            deferAction: { deferrer.enqueue($0) }
        )

        gate.schedule()
        gate.cancel()
        gate.schedule()
        gate.schedule()

        XCTAssertEqual(deferrer.actions.count, 2)
        deferrer.runAction(at: 0)
        gate.schedule()
        XCTAssertEqual(deferrer.actions.count, 2)
        deferrer.runAction(at: 1)
        XCTAssertEqual(state.presentationCount, 1)
        withExtendedLifetime(gate) {}
    }

    func testCancelDuringEligibilityPreventsStaleTaskOvertakingReplacement() {
        let state = AutomaticUpdatePresentationGateTestState(isEligible: true)
        let deferrer = ControlledAutomaticUpdatePresentationDeferrer()
        let holder = AutomaticUpdatePresentationGateTestHolder()
        let gate = AutomaticUpdatePresentationGate(
            canPresent: {
                if !state.didReplaceTask {
                    state.didReplaceTask = true
                    holder.gate?.cancel()
                    holder.gate?.schedule()
                }
                return state.isEligible
            },
            present: { state.presentationCount += 1 },
            deferAction: { deferrer.enqueue($0) }
        )
        holder.gate = gate

        gate.schedule()
        deferrer.runAction(at: 0)

        XCTAssertEqual(state.presentationCount, 0)
        XCTAssertEqual(deferrer.actions.count, 2)
        deferrer.runAction(at: 1)
        XCTAssertEqual(state.presentationCount, 1)
        withExtendedLifetime(gate) {}
    }

    func testSynchronousDeferralPreservesReentrantReplacement() {
        let state = AutomaticUpdatePresentationGateTestState(isEligible: true)
        let deferrer = ReentrantAutomaticUpdatePresentationDeferrer()
        let holder = AutomaticUpdatePresentationGateTestHolder()
        let gate = AutomaticUpdatePresentationGate(
            canPresent: { state.isEligible },
            present: {
                state.presentationCount += 1
                if state.presentationCount == 1 {
                    holder.gate?.schedule()
                }
            },
            deferAction: { deferrer.enqueue($0) }
        )
        holder.gate = gate

        gate.schedule()

        XCTAssertEqual(state.presentationCount, 1)
        XCTAssertEqual(deferrer.actions.count, 1)
        XCTAssertEqual(deferrer.cancelledIDs, [0])
        guard deferrer.actions.count == 1 else { return }
        gate.schedule()
        XCTAssertEqual(deferrer.actions.count, 1)

        deferrer.runAction(at: 0)
        XCTAssertEqual(state.presentationCount, 2)
        withExtendedLifetime(gate) {}
    }
}

@MainActor
private final class AutomaticUpdatePresentationGateTestState {
    var isEligible: Bool
    var eligibilityCheckCount = 0
    var presentationCount = 0
    var didReplaceTask = false
    var didScheduleReturn = false
    var presentationObservedScheduleReturn = false

    init(isEligible: Bool = false) {
        self.isEligible = isEligible
    }
}

@MainActor
private final class AutomaticUpdatePresentationGateTestHolder {
    weak var gate: AutomaticUpdatePresentationGate?
}

@MainActor
private final class ControlledAutomaticUpdatePresentationDeferrer {
    typealias Action = @MainActor () -> Void

    private(set) var actions: [Action] = []
    private(set) var cancellationCount = 0

    func enqueue(_ action: @escaping Action) -> @MainActor () -> Void {
        actions.append(action)
        return { [weak self] in
            self?.cancellationCount += 1
        }
    }

    func runAction(at index: Int) {
        actions[index]()
    }
}

@MainActor
private final class ReentrantAutomaticUpdatePresentationDeferrer {
    typealias Action = @MainActor () -> Void

    private(set) var actions: [Action] = []
    private(set) var cancelledIDs: [Int] = []
    private var nextID = 0

    func enqueue(_ action: @escaping Action) -> @MainActor () -> Void {
        let id = nextID
        nextID += 1
        if id == 0 {
            action()
        } else {
            actions.append(action)
        }
        return { [weak self] in
            self?.cancelledIDs.append(id)
        }
    }

    func runAction(at index: Int) {
        actions[index]()
    }
}
