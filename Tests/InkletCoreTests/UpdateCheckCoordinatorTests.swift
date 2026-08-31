import Foundation
import XCTest
@testable import Inklet
@testable import InkletCore

@MainActor
final class UpdateCheckCoordinatorTests: XCTestCase {
    func testSchedulePolicyBoundsDelayForMissingRecentDueFutureAndInvalidInputs() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let interval: TimeInterval = 100

        XCTAssertEqual(UpdateCheckSchedulePolicy.delay(lastAttempt: nil, now: now, interval: interval), 0)
        XCTAssertEqual(
            UpdateCheckSchedulePolicy.delay(
                lastAttempt: now.addingTimeInterval(-25),
                now: now,
                interval: interval
            ),
            75
        )
        XCTAssertEqual(
            UpdateCheckSchedulePolicy.delay(
                lastAttempt: now.addingTimeInterval(-interval),
                now: now,
                interval: interval
            ),
            0
        )
        XCTAssertEqual(
            UpdateCheckSchedulePolicy.delay(
                lastAttempt: now.addingTimeInterval(-interval - 1),
                now: now,
                interval: interval
            ),
            0
        )
        XCTAssertEqual(
            UpdateCheckSchedulePolicy.delay(
                lastAttempt: now.addingTimeInterval(1),
                now: now,
                interval: interval
            ),
            interval
        )
        XCTAssertEqual(
            UpdateCheckSchedulePolicy.delay(
                lastAttempt: now.addingTimeInterval(10_000),
                now: now,
                interval: interval
            ),
            interval
        )
        XCTAssertEqual(
            UpdateCheckSchedulePolicy.delay(
                lastAttempt: Date(timeIntervalSinceReferenceDate: .nan),
                now: now,
                interval: interval
            ),
            interval
        )

        let invalidIntervals: [TimeInterval] = [0, -1, .nan, .infinity, -.infinity]
        for invalidInterval in invalidIntervals {
            XCTAssertEqual(
                UpdateCheckSchedulePolicy.delay(
                    lastAttempt: now.addingTimeInterval(-25),
                    now: now,
                    interval: invalidInterval
                ),
                0
            )
        }
    }

    func testAutomaticAttemptPreferenceKeyIsNotARecognizedLegacyKey() {
        XCTAssertEqual(
            InkletPreferenceKeys.lastAutomaticUpdateCheckDate,
            "lastAutomaticUpdateCheckDate"
        )
        XCTAssertFalse(
            InkletPreferenceKeys.recognizedLegacyKeys.contains(
                InkletPreferenceKeys.lastAutomaticUpdateCheckDate
            )
        )
    }

    func testDueStartRecordsCapturedTimeSchedulesNextAttemptAndKeepsFailureSilent() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let start = fixture.checker.expectStart(description: "automatic check starts")
        let finished = expectation(description: "automatic check finishes")
        var checkingEdges: [Bool] = []
        fixture.coordinator.onCheckingStateChange = { isChecking in
            checkingEdges.append(isChecking)
            if !isChecking { finished.fulfill() }
        }

        fixture.coordinator.start()

        XCTAssertEqual(
            fixture.defaults.object(forKey: InkletPreferenceKeys.lastAutomaticUpdateCheckDate) as? Date,
            fixture.clock.date
        )
        XCTAssertEqual(fixture.scheduler.delays, [UpdateCheckSchedulePolicy.interval])
        XCTAssertTrue(fixture.coordinator.isChecking)
        await fulfillment(of: [start], timeout: 1)

        fixture.checker.fail(TestError.failed, at: 0)
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(checkingEdges, [true, false])
        XCTAssertTrue(fixture.presenter.events.isEmpty)
        XCTAssertEqual(fixture.scheduler.delays, [UpdateCheckSchedulePolicy.interval])
    }

    func testRecentStartSchedulesRemainingDelayAndTimerFireRecordsNewAttempt() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let priorAttempt = fixture.clock.date.addingTimeInterval(-300)
        fixture.defaults.set(priorAttempt, forKey: InkletPreferenceKeys.lastAutomaticUpdateCheckDate)

        fixture.coordinator.start()
        fixture.coordinator.start()

        XCTAssertEqual(
            fixture.scheduler.delays,
            [UpdateCheckSchedulePolicy.interval - 300]
        )
        XCTAssertEqual(fixture.checker.callCount, 0)
        XCTAssertFalse(fixture.coordinator.isChecking)

        fixture.clock.date = fixture.clock.date.addingTimeInterval(600)
        let firedAt = fixture.clock.date
        let start = fixture.checker.expectStart(description: "timer starts automatic check")
        fixture.scheduler.fire()
        await fulfillment(of: [start], timeout: 1)

        XCTAssertEqual(
            fixture.defaults.object(forKey: InkletPreferenceKeys.lastAutomaticUpdateCheckDate) as? Date,
            firedAt
        )
        XCTAssertEqual(
            fixture.scheduler.delays,
            [UpdateCheckSchedulePolicy.interval - 300, UpdateCheckSchedulePolicy.interval]
        )
        XCTAssertEqual(fixture.checker.callCount, 1)

        let finished = expectation(description: "timer check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { finished.fulfill() } }
        fixture.checker.fail(TestError.failed, at: 0)
        await fulfillment(of: [finished], timeout: 1)
    }

    func testScheduledAutomaticActionFromPriorLifecycleNoOpsAfterRestart() async throws {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let priorAttempt = fixture.clock.date.addingTimeInterval(-300)
        fixture.defaults.set(priorAttempt, forKey: InkletPreferenceKeys.lastAutomaticUpdateCheckDate)
        fixture.coordinator.start()
        let staleAction = try XCTUnwrap(fixture.scheduler.capturedAction())

        fixture.coordinator.stop()
        fixture.coordinator.start()
        let unexpectedStart = fixture.checker.expectStart(
            description: "stale scheduled action starts a check"
        )
        staleAction()
        let staleActionStarted = fixture.coordinator.isChecking
        if staleActionStarted {
            let unexpectedFinished = expectation(description: "stale scheduled action finishes")
            fixture.coordinator.onCheckingStateChange = { if !$0 { unexpectedFinished.fulfill() } }
            await fulfillment(of: [unexpectedStart], timeout: 1)
            fixture.checker.fail(TestError.failed, at: 0)
            await fulfillment(of: [unexpectedFinished], timeout: 1)
        }

        XCTAssertFalse(staleActionStarted)
        XCTAssertEqual(fixture.checker.callCount, 0)
        XCTAssertEqual(
            fixture.defaults.object(forKey: InkletPreferenceKeys.lastAutomaticUpdateCheckDate) as? Date,
            priorAttempt
        )
        XCTAssertEqual(fixture.scheduler.delays.count, 2)
    }

    func testDisabledAutomaticChecksDoNotScheduleAndManualCheckBypassesTimestamp() async {
        let fixture = makeFixture(automaticChecksEnabled: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.coordinator.start()
        fixture.coordinator.start()
        XCTAssertTrue(fixture.scheduler.delays.isEmpty)
        XCTAssertEqual(fixture.checker.callCount, 0)

        let start = fixture.checker.expectStart(description: "manual check starts")
        let finished = expectation(description: "manual check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { finished.fulfill() } }
        fixture.coordinator.checkManually()
        await fulfillment(of: [start], timeout: 1)

        XCTAssertNil(
            fixture.defaults.object(forKey: InkletPreferenceKeys.lastAutomaticUpdateCheckDate)
        )
        fixture.checker.succeed(.upToDate(makeRelease(buildNumber: 1)), at: 0)
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(fixture.presenter.events, [.upToDate("1.0.0")])

        fixture.coordinator.stop()
        let cancellationCount = fixture.scheduler.cancellationCount
        fixture.coordinator.stop()
        XCTAssertEqual(fixture.scheduler.cancellationCount, cancellationCount)
        fixture.coordinator.checkManually()
        XCTAssertEqual(fixture.checker.callCount, 1)
    }

    func testRepeatedManualChecksCoalesceAndEmitOneCheckingEdgePair() async {
        let fixture = makeFixture(automaticChecksEnabled: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.coordinator.start()
        let start = fixture.checker.expectStart(description: "coalesced manual check starts")
        let finished = expectation(description: "coalesced manual check finishes")
        var checkingEdges: [Bool] = []
        fixture.coordinator.onCheckingStateChange = { isChecking in
            checkingEdges.append(isChecking)
            if !isChecking { finished.fulfill() }
        }

        fixture.coordinator.checkManually()
        fixture.coordinator.checkManually()
        fixture.coordinator.checkManually()
        await fulfillment(of: [start], timeout: 1)

        XCTAssertEqual(fixture.checker.callCount, 1)
        fixture.checker.succeed(.upToDate(makeRelease(buildNumber: 1)), at: 0)
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(checkingEdges, [true, false])
        XCTAssertEqual(fixture.presenter.events, [.upToDate("1.0.0")])
    }

    func testAutomaticThenManualUsesOneRequestAndManualPresentation() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.gate.value = false
        let start = fixture.checker.expectStart(description: "automatic check starts")
        let finished = expectation(description: "upgraded check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { finished.fulfill() } }

        fixture.coordinator.start()
        await fulfillment(of: [start], timeout: 1)
        fixture.coordinator.checkManually()
        fixture.checker.succeed(.updateAvailable(makeRelease(buildNumber: 2)), at: 0)
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(fixture.checker.callCount, 1)
        XCTAssertEqual(fixture.scheduler.delays, [UpdateCheckSchedulePolicy.interval])
        XCTAssertEqual(fixture.presenter.events, [.update(2, "1.0.0")])
    }

    func testManualThenAutomaticUsesOneRequestRecordsAttemptAndBecomesInteractive() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let oldAttempt = fixture.clock.date.addingTimeInterval(-100)
        fixture.defaults.set(oldAttempt, forKey: InkletPreferenceKeys.lastAutomaticUpdateCheckDate)
        fixture.coordinator.start()

        let start = fixture.checker.expectStart(description: "manual check starts")
        let finished = expectation(description: "joined check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { finished.fulfill() } }
        fixture.coordinator.checkManually()
        await fulfillment(of: [start], timeout: 1)

        fixture.clock.date = fixture.clock.date.addingTimeInterval(200)
        let firedAt = fixture.clock.date
        fixture.scheduler.fire()
        XCTAssertEqual(
            fixture.defaults.object(forKey: InkletPreferenceKeys.lastAutomaticUpdateCheckDate) as? Date,
            firedAt
        )
        XCTAssertEqual(
            fixture.scheduler.delays,
            [UpdateCheckSchedulePolicy.interval - 100, UpdateCheckSchedulePolicy.interval]
        )

        fixture.checker.succeed(.upToDate(makeRelease(buildNumber: 1)), at: 0)
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(fixture.checker.callCount, 1)
        XCTAssertEqual(fixture.presenter.events, [.upToDate("1.0.0")])
    }

    func testAutomaticUpToDateAndErrorAreSilent() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let firstStart = fixture.checker.expectStart(description: "first automatic check starts")
        let firstFinished = expectation(description: "first automatic check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { firstFinished.fulfill() } }
        fixture.coordinator.start()
        await fulfillment(of: [firstStart], timeout: 1)
        fixture.checker.succeed(.upToDate(makeRelease(buildNumber: 1)), at: 0)
        await fulfillment(of: [firstFinished], timeout: 1)

        fixture.clock.date = fixture.clock.date.addingTimeInterval(UpdateCheckSchedulePolicy.interval)
        let secondStart = fixture.checker.expectStart(description: "second automatic check starts")
        let secondFinished = expectation(description: "second automatic check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { secondFinished.fulfill() } }
        fixture.scheduler.fire()
        await fulfillment(of: [secondStart], timeout: 1)
        fixture.checker.fail(TestError.failed, at: 1)
        await fulfillment(of: [secondFinished], timeout: 1)

        XCTAssertTrue(fixture.presenter.events.isEmpty)
    }

    func testManualFailurePresentsRetryAfterFalseEdgeAndRetryStartsFreshRequest() async throws {
        let fixture = makeFixture(automaticChecksEnabled: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.coordinator.start()
        var checkingEdges: [Bool] = []
        var checkingWhenFailurePresented: Bool?
        fixture.presenter.onFailure = { checkingWhenFailurePresented = fixture.coordinator.isChecking }

        let firstStart = fixture.checker.expectStart(description: "first manual check starts")
        let firstFinished = expectation(description: "first manual check finishes")
        fixture.coordinator.onCheckingStateChange = { state in
            checkingEdges.append(state)
            if !state { firstFinished.fulfill() }
        }
        fixture.coordinator.checkManually()
        await fulfillment(of: [firstStart], timeout: 1)
        fixture.checker.fail(TestError.failed, at: 0)
        await fulfillment(of: [firstFinished], timeout: 1)

        XCTAssertEqual(checkingWhenFailurePresented, false)
        XCTAssertEqual(fixture.presenter.events, [.failure])
        let retry = try XCTUnwrap(fixture.presenter.retry)

        let secondStart = fixture.checker.expectStart(description: "retry starts fresh check")
        let secondFinished = expectation(description: "retry finishes")
        fixture.coordinator.onCheckingStateChange = { state in
            checkingEdges.append(state)
            if !state { secondFinished.fulfill() }
        }
        retry()
        await fulfillment(of: [secondStart], timeout: 1)
        XCTAssertEqual(fixture.checker.callCount, 2)
        fixture.checker.succeed(.upToDate(makeRelease(buildNumber: 1)), at: 1)
        await fulfillment(of: [secondFinished], timeout: 1)

        XCTAssertEqual(checkingEdges, [true, false, true, false])
        XCTAssertEqual(fixture.presenter.events, [.failure, .upToDate("1.0.0")])
    }

    func testUnexpectedCancellationOfActiveManualCheckPresentsFailure() async {
        let fixture = makeFixture(automaticChecksEnabled: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.coordinator.start()
        let start = fixture.checker.expectStart(description: "manual check starts")
        let finished = expectation(description: "manual cancellation finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { finished.fulfill() } }
        fixture.coordinator.checkManually()
        await fulfillment(of: [start], timeout: 1)

        fixture.checker.fail(CancellationError(), at: 0)
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(fixture.presenter.events, [.failure])
    }

    func testDeferredAutomaticUpdateFlushesOnlyOnceWhenGateBecomesAvailable() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.gate.value = false
        let start = fixture.checker.expectStart(description: "automatic update check starts")
        let finished = expectation(description: "automatic update check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { finished.fulfill() } }
        fixture.coordinator.start()
        await fulfillment(of: [start], timeout: 1)
        fixture.checker.succeed(.updateAvailable(makeRelease(buildNumber: 2)), at: 0)
        await fulfillment(of: [finished], timeout: 1)

        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertTrue(fixture.presenter.events.isEmpty)

        fixture.gate.value = true
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertEqual(fixture.presenter.events, [.update(2, "1.0.0")])
    }

    func testPendingFlushStopInsideGateDoesNotPresentOrSurviveRestart() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.gate.value = false
        await completeAutomaticCheck(
            fixture,
            result: .success(.updateAvailable(makeRelease(buildNumber: 2))),
            callIndex: 0,
            startCoordinator: true
        )

        fixture.gate.value = true
        fixture.gate.onRead = { fixture.coordinator.stop() }
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()

        XCTAssertFalse(fixture.coordinator.isChecking)
        XCTAssertTrue(fixture.presenter.events.isEmpty)
        fixture.coordinator.start()
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertTrue(fixture.presenter.events.isEmpty)
    }

    func testPendingFlushStopRestartInsideGateDoesNotPresentOldLifecycleRelease() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.gate.value = false
        await completeAutomaticCheck(
            fixture,
            result: .success(.updateAvailable(makeRelease(buildNumber: 2))),
            callIndex: 0,
            startCoordinator: true
        )

        fixture.gate.value = true
        fixture.gate.onRead = {
            fixture.coordinator.stop()
            fixture.coordinator.start()
        }
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()

        XCTAssertFalse(fixture.coordinator.isChecking)
        XCTAssertTrue(fixture.presenter.events.isEmpty)
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertTrue(fixture.presenter.events.isEmpty)
    }

    func testAutomaticUpdateGateStopReturningTrueSuppressesPresentation() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let started = fixture.checker.expectStart(description: "automatic check starts")
        let finished = expectation(description: "automatic check finishes")
        var checkingEdges: [Bool] = []
        fixture.coordinator.onCheckingStateChange = { state in
            checkingEdges.append(state)
            if !state { finished.fulfill() }
        }
        fixture.coordinator.start()
        await fulfillment(of: [started], timeout: 1)
        fixture.gate.value = true
        fixture.gate.onRead = { fixture.coordinator.stop() }

        fixture.checker.succeed(.updateAvailable(makeRelease(buildNumber: 2)), at: 0)
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(checkingEdges, [true, false])
        XCTAssertFalse(fixture.coordinator.isChecking)
        XCTAssertTrue(fixture.presenter.events.isEmpty)
        fixture.coordinator.start()
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertTrue(fixture.presenter.events.isEmpty)
    }

    func testAutomaticUpdateGateStopReturningFalseDoesNotRestorePendingAfterRestart() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let started = fixture.checker.expectStart(description: "automatic check starts")
        let finished = expectation(description: "automatic check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { finished.fulfill() } }
        fixture.coordinator.start()
        await fulfillment(of: [started], timeout: 1)
        fixture.gate.value = false
        fixture.gate.onRead = { fixture.coordinator.stop() }

        fixture.checker.succeed(.updateAvailable(makeRelease(buildNumber: 2)), at: 0)
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertFalse(fixture.coordinator.isChecking)
        XCTAssertTrue(fixture.presenter.events.isEmpty)
        fixture.coordinator.start()
        fixture.gate.value = true
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertTrue(fixture.presenter.events.isEmpty)
    }

    func testAutomaticUpdateGateStopRestartDoesNotPresentIntoNewLifecycle() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let started = fixture.checker.expectStart(description: "automatic check starts")
        let finished = expectation(description: "automatic check finishes")
        var checkingEdges: [Bool] = []
        fixture.coordinator.onCheckingStateChange = { state in
            checkingEdges.append(state)
            if !state { finished.fulfill() }
        }
        fixture.coordinator.start()
        await fulfillment(of: [started], timeout: 1)
        fixture.gate.value = true
        fixture.gate.onRead = {
            fixture.coordinator.stop()
            fixture.coordinator.start()
        }

        fixture.checker.succeed(.updateAvailable(makeRelease(buildNumber: 2)), at: 0)
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(checkingEdges, [true, false])
        XCTAssertFalse(fixture.coordinator.isChecking)
        XCTAssertTrue(fixture.presenter.events.isEmpty)
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertTrue(fixture.presenter.events.isEmpty)
    }

    func testPendingAutomaticUpdateDoesNotFlushWhileAnotherCheckIsActive() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.gate.value = false
        let automaticStart = fixture.checker.expectStart(description: "automatic check starts")
        let automaticFinished = expectation(description: "automatic check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { automaticFinished.fulfill() } }
        fixture.coordinator.start()
        await fulfillment(of: [automaticStart], timeout: 1)
        fixture.checker.succeed(.updateAvailable(makeRelease(buildNumber: 2)), at: 0)
        await fulfillment(of: [automaticFinished], timeout: 1)

        let manualStart = fixture.checker.expectStart(description: "manual check starts")
        fixture.coordinator.checkManually()
        await fulfillment(of: [manualStart], timeout: 1)
        fixture.gate.value = true
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertTrue(fixture.presenter.events.isEmpty)

        let manualFinished = expectation(description: "manual check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { manualFinished.fulfill() } }
        fixture.checker.fail(TestError.failed, at: 1)
        await fulfillment(of: [manualFinished], timeout: 1)
        XCTAssertEqual(fixture.presenter.events, [.failure])

        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertEqual(fixture.presenter.events, [.failure, .update(2, "1.0.0")])
    }

    func testManualUpdatePresentsWhileGateIsBusyAndClearsStalePendingUpdate() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.gate.value = false
        let automaticStart = fixture.checker.expectStart(description: "automatic check starts")
        let automaticFinished = expectation(description: "automatic check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { automaticFinished.fulfill() } }
        fixture.coordinator.start()
        await fulfillment(of: [automaticStart], timeout: 1)
        fixture.checker.succeed(.updateAvailable(makeRelease(buildNumber: 2)), at: 0)
        await fulfillment(of: [automaticFinished], timeout: 1)

        let manualStart = fixture.checker.expectStart(description: "manual check starts")
        let manualFinished = expectation(description: "manual check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { manualFinished.fulfill() } }
        fixture.coordinator.checkManually()
        await fulfillment(of: [manualStart], timeout: 1)
        fixture.checker.succeed(.updateAvailable(makeRelease(buildNumber: 3)), at: 1)
        await fulfillment(of: [manualFinished], timeout: 1)

        XCTAssertEqual(fixture.presenter.events, [.update(3, "1.0.0")])
        fixture.gate.value = true
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertEqual(fixture.presenter.events, [.update(3, "1.0.0")])
    }

    func testLatestDeferredAutomaticUpdateReplacesOlderAndUpToDateClearsIt() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.gate.value = false

        await completeAutomaticCheck(
            fixture,
            result: .success(.updateAvailable(makeRelease(buildNumber: 2))),
            callIndex: 0,
            startCoordinator: true
        )
        fixture.clock.date = fixture.clock.date.addingTimeInterval(UpdateCheckSchedulePolicy.interval)
        await completeAutomaticCheck(
            fixture,
            result: .success(.updateAvailable(makeRelease(buildNumber: 3))),
            callIndex: 1,
            startCoordinator: false
        )

        fixture.gate.value = true
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertEqual(fixture.presenter.events, [.update(3, "1.0.0")])

        fixture.gate.value = false
        fixture.clock.date = fixture.clock.date.addingTimeInterval(UpdateCheckSchedulePolicy.interval)
        await completeAutomaticCheck(
            fixture,
            result: .success(.updateAvailable(makeRelease(buildNumber: 4))),
            callIndex: 2,
            startCoordinator: false
        )
        fixture.clock.date = fixture.clock.date.addingTimeInterval(UpdateCheckSchedulePolicy.interval)
        await completeAutomaticCheck(
            fixture,
            result: .success(.upToDate(makeRelease(buildNumber: 1))),
            callIndex: 3,
            startCoordinator: false
        )
        fixture.gate.value = true
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertEqual(fixture.presenter.events, [.update(3, "1.0.0")])
    }

    func testAutomaticFailureRetainsPreviouslyDeferredUpdate() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.gate.value = false
        await completeAutomaticCheck(
            fixture,
            result: .success(.updateAvailable(makeRelease(buildNumber: 2))),
            callIndex: 0,
            startCoordinator: true
        )
        fixture.clock.date = fixture.clock.date.addingTimeInterval(UpdateCheckSchedulePolicy.interval)
        await completeAutomaticCheck(
            fixture,
            result: .failure(TestError.failed),
            callIndex: 1,
            startCoordinator: false
        )

        fixture.gate.value = true
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertEqual(fixture.presenter.events, [.update(2, "1.0.0")])
    }

    func testManualFailureRetainsPreviouslyDeferredUpdate() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.gate.value = false
        await completeAutomaticCheck(
            fixture,
            result: .success(.updateAvailable(makeRelease(buildNumber: 2))),
            callIndex: 0,
            startCoordinator: true
        )

        let manualStart = fixture.checker.expectStart(description: "manual check starts")
        let manualFinished = expectation(description: "manual check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { manualFinished.fulfill() } }
        fixture.coordinator.checkManually()
        await fulfillment(of: [manualStart], timeout: 1)
        fixture.checker.fail(TestError.failed, at: 1)
        await fulfillment(of: [manualFinished], timeout: 1)
        XCTAssertEqual(fixture.presenter.events, [.failure])

        fixture.gate.value = true
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertEqual(fixture.presenter.events, [.failure, .update(2, "1.0.0")])
    }

    func testStopCancelsActiveCheckDropsPendingAndSuppressesStaleCompletion() async {
        let fixture = makeFixture(automaticChecksEnabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.gate.value = false
        await completeAutomaticCheck(
            fixture,
            result: .success(.updateAvailable(makeRelease(buildNumber: 2))),
            callIndex: 0,
            startCoordinator: true
        )

        let manualStart = fixture.checker.expectStart(description: "manual check starts")
        var checkingEdges: [Bool] = []
        fixture.coordinator.onCheckingStateChange = { checkingEdges.append($0) }
        fixture.coordinator.checkManually()
        await fulfillment(of: [manualStart], timeout: 1)
        fixture.coordinator.stop()

        XCTAssertFalse(fixture.coordinator.isChecking)
        XCTAssertEqual(checkingEdges, [true, false])
        XCTAssertGreaterThanOrEqual(fixture.scheduler.cancellationCount, 1)
        fixture.checker.fail(TestError.failed, at: 1)

        fixture.gate.value = true
        fixture.coordinator.presentPendingAutomaticUpdateIfPossible()
        XCTAssertTrue(fixture.presenter.events.isEmpty)
    }

    func testRetryClosureNoOpsAfterStop() async throws {
        let fixture = makeFixture(automaticChecksEnabled: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.coordinator.start()
        let start = fixture.checker.expectStart(description: "manual check starts")
        let finished = expectation(description: "manual check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { finished.fulfill() } }
        fixture.coordinator.checkManually()
        await fulfillment(of: [start], timeout: 1)
        fixture.checker.fail(TestError.failed, at: 0)
        await fulfillment(of: [finished], timeout: 1)
        let retry = try XCTUnwrap(fixture.presenter.retry)

        fixture.coordinator.stop()
        retry()

        XCTAssertEqual(fixture.checker.callCount, 1)
        XCTAssertFalse(fixture.coordinator.isChecking)
    }

    func testRetryClosureRemainsInvalidAfterStopAndRestart() async throws {
        let fixture = makeFixture(automaticChecksEnabled: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.coordinator.start()
        let start = fixture.checker.expectStart(description: "manual check starts")
        let finished = expectation(description: "manual check finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { finished.fulfill() } }
        fixture.coordinator.checkManually()
        await fulfillment(of: [start], timeout: 1)
        fixture.checker.fail(TestError.failed, at: 0)
        await fulfillment(of: [finished], timeout: 1)
        let retry = try XCTUnwrap(fixture.presenter.retry)

        fixture.coordinator.stop()
        fixture.coordinator.start()
        let unexpectedStart = fixture.checker.expectStart(description: "stale retry starts")
        retry()
        let staleRetryStarted = fixture.coordinator.isChecking
        if staleRetryStarted {
            let unexpectedFinished = expectation(description: "stale retry finishes")
            fixture.coordinator.onCheckingStateChange = { if !$0 { unexpectedFinished.fulfill() } }
            await fulfillment(of: [unexpectedStart], timeout: 1)
            fixture.checker.succeed(.upToDate(makeRelease(buildNumber: 1)), at: 1)
            await fulfillment(of: [unexpectedFinished], timeout: 1)
        }

        XCTAssertFalse(staleRetryStarted)
        XCTAssertEqual(fixture.checker.callCount, 1)
    }

    func testStopFromFalseCheckingEdgeSuppressesTerminalPresentation() async {
        let fixture = makeFixture(automaticChecksEnabled: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.coordinator.start()
        let start = fixture.checker.expectStart(description: "manual check starts")
        let finished = expectation(description: "false checking edge observed")
        fixture.coordinator.onCheckingStateChange = { state in
            if !state {
                fixture.coordinator.stop()
                finished.fulfill()
            }
        }
        fixture.coordinator.checkManually()
        await fulfillment(of: [start], timeout: 1)
        fixture.checker.fail(TestError.failed, at: 0)
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertTrue(fixture.presenter.events.isEmpty)
    }

    func testStopRestartPreventsOldCompletionFromClearingOrPresentingOverNewTask() async {
        let fixture = makeFixture(automaticChecksEnabled: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        var checkingEdges: [Bool] = []
        fixture.coordinator.onCheckingStateChange = { checkingEdges.append($0) }
        fixture.coordinator.start()

        let oldStart = fixture.checker.expectStart(description: "old manual check starts")
        fixture.coordinator.checkManually()
        await fulfillment(of: [oldStart], timeout: 1)
        fixture.coordinator.stop()

        fixture.coordinator.start()
        let newStart = fixture.checker.expectStart(description: "new manual check starts")
        let newFinished = expectation(description: "new manual check finishes")
        fixture.coordinator.onCheckingStateChange = { state in
            checkingEdges.append(state)
            if !state { newFinished.fulfill() }
        }
        fixture.coordinator.checkManually()
        await fulfillment(of: [newStart], timeout: 1)

        fixture.checker.succeed(.updateAvailable(makeRelease(buildNumber: 99)), at: 0)
        XCTAssertTrue(fixture.coordinator.isChecking)
        fixture.checker.succeed(.upToDate(makeRelease(buildNumber: 1)), at: 1)
        await fulfillment(of: [newFinished], timeout: 1)

        XCTAssertEqual(checkingEdges, [true, false, true, false])
        XCTAssertEqual(fixture.presenter.events, [.upToDate("1.0.0")])
    }

    private func completeAutomaticCheck(
        _ fixture: Fixture,
        result: Result<AppUpdateCheckResult, Error>,
        callIndex: Int,
        startCoordinator: Bool
    ) async {
        let started = fixture.checker.expectStart(description: "automatic check \(callIndex) starts")
        let finished = expectation(description: "automatic check \(callIndex) finishes")
        fixture.coordinator.onCheckingStateChange = { if !$0 { finished.fulfill() } }
        if startCoordinator {
            fixture.coordinator.start()
        } else {
            fixture.scheduler.fire()
        }
        await fulfillment(of: [started], timeout: 1)
        fixture.checker.resolve(result, at: callIndex)
        await fulfillment(of: [finished], timeout: 1)
    }

    private func makeFixture(automaticChecksEnabled: Bool) -> Fixture {
        let suiteName = "UpdateCheckCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let scheduler = FakeUpdateCheckScheduler()
        let presenter = RecordingUpdateCheckPresenter()
        let checker = ControlledUpdateChecker()
        let clock = MutableClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let gate = MutableGate(value: true)
        let coordinator = UpdateCheckCoordinator(
            automaticChecksEnabled: automaticChecksEnabled,
            currentVersion: "1.0.0",
            userDefaults: defaults,
            scheduler: scheduler,
            presenter: presenter,
            now: { clock.date },
            canPresentAutomatically: { gate.read() },
            check: { try await checker.check() }
        )
        return Fixture(
            suiteName: suiteName,
            defaults: defaults,
            scheduler: scheduler,
            presenter: presenter,
            checker: checker,
            clock: clock,
            gate: gate,
            coordinator: coordinator
        )
    }

    private func makeRelease(buildNumber: Int) -> InkletRelease {
        let tagName = "v1.0.\(buildNumber)-\(buildNumber)"
        return InkletRelease(
            version: try! InkletReleaseVersion(tagName: tagName),
            tagName: tagName,
            name: "Inklet \(buildNumber)",
            notes: "Notes \(buildNumber)",
            pageURL: URL(string: "https://github.com/wanming/Inklet/releases/tag/\(tagName)")!
        )
    }
}

@MainActor
private struct Fixture {
    let suiteName: String
    let defaults: UserDefaults
    let scheduler: FakeUpdateCheckScheduler
    let presenter: RecordingUpdateCheckPresenter
    let checker: ControlledUpdateChecker
    let clock: MutableClock
    let gate: MutableGate
    let coordinator: UpdateCheckCoordinator
}

@MainActor
private final class FakeUpdateCheckScheduler: UpdateCheckOneShotScheduling {
    private(set) var delays: [TimeInterval] = []
    private(set) var cancellationCount = 0
    private var action: Action?

    func schedule(after delay: TimeInterval, action: @escaping Action) {
        delays.append(delay)
        self.action = action
    }

    func cancel() {
        cancellationCount += 1
        action = nil
    }

    func fire() {
        let action = action
        self.action = nil
        action?()
    }

    func capturedAction() -> Action? {
        action
    }
}

@MainActor
private final class RecordingUpdateCheckPresenter: UpdateCheckPresenting {
    enum Event: Equatable {
        case update(Int, String)
        case upToDate(String)
        case failure
    }

    private(set) var events: [Event] = []
    private(set) var retry: (@MainActor () -> Void)?
    var onFailure: (@MainActor () -> Void)?

    func presentUpdate(_ release: InkletRelease, currentVersion: String) {
        events.append(.update(release.version.buildNumber, currentVersion))
    }

    func presentUpToDate(currentVersion: String) {
        events.append(.upToDate(currentVersion))
    }

    func presentFailure(retry: @escaping @MainActor () -> Void) {
        events.append(.failure)
        self.retry = retry
        onFailure?()
    }
}

@MainActor
private final class ControlledUpdateChecker {
    private var startExpectations: [XCTestExpectation] = []
    private var continuations: [CheckedContinuation<AppUpdateCheckResult, Error>?] = []
    private(set) var callCount = 0

    func expectStart(description: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        startExpectations.append(expectation)
        return expectation
    }

    func check() async throws -> AppUpdateCheckResult {
        let callIndex = callCount
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            startExpectations.removeFirst().fulfill()
            XCTAssertEqual(continuations.count - 1, callIndex)
        }
    }

    func succeed(_ result: AppUpdateCheckResult, at index: Int) {
        resolve(.success(result), at: index)
    }

    func fail(_ error: Error, at index: Int) {
        resolve(.failure(error), at: index)
    }

    func resolve(_ result: Result<AppUpdateCheckResult, Error>, at index: Int) {
        guard let continuation = continuations[index] else {
            XCTFail("Check \(index) was already resolved")
            return
        }
        continuations[index] = nil
        continuation.resume(with: result)
    }
}

@MainActor
private final class MutableClock {
    var date: Date

    init(date: Date) {
        self.date = date
    }
}

@MainActor
private final class MutableGate {
    var value: Bool
    var onRead: (@MainActor () -> Void)?

    init(value: Bool) {
        self.value = value
    }

    func read() -> Bool {
        let action = onRead
        onRead = nil
        action?()
        return value
    }
}

private enum TestError: Error {
    case failed
}
