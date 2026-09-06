import XCTest
@testable import Inklet

@MainActor
final class WritingDictationGestureTaskArbiterTests: XCTestCase {
    func testStopCancelsQueuedStartBeforeItCanBegin() async {
        let arbiter = WritingDictationGestureTaskArbiter<Int>()
        let blockedPredecessor = GestureArbiterGate()
        let tokenState = GestureArbiterTokenState(1)
        var beginCount = 0
        let currentChecks = GestureArbiterEventCounter()
        let endCalls = GestureArbiterEventCounter()
        let predecessorTask = Task { @MainActor in
            await blockedPredecessor.wait()
        }
        await blockedPredecessor.waitUntilEntered()

        let startTask = arbiter.scheduleStart(
            token: 1,
            after: predecessorTask,
            isCurrent: {
                currentChecks.record()
                return tokenState.current == $0
            },
            begin: { beginCount += 1 }
        )
        await currentChecks.wait(for: 1)
        tokenState.current = nil
        let stopTask = arbiter.scheduleStop(
            token: 1,
            after: startTask,
            isContextCurrent: { _ in true },
            end: { endCalls.record() }
        )

        await endCalls.wait(for: 1)

        XCTAssertEqual(beginCount, 0)
        XCTAssertEqual(endCalls.count, 1)
        XCTAssertFalse(predecessorTask.isCancelled)
        XCTAssertFalse(blockedPredecessor.isOpen)

        blockedPredecessor.open()
        await stopTask.value

        XCTAssertEqual(beginCount, 0)
        XCTAssertEqual(endCalls.count, 2)
    }

    func testCancellationCancelsQueuedStartBeforeItCanBegin() async {
        let arbiter = WritingDictationGestureTaskArbiter<Int>()
        let blockedPredecessor = GestureArbiterGate()
        let tokenState = GestureArbiterTokenState(1)
        var beginCount = 0
        let currentChecks = GestureArbiterEventCounter()
        let cancellationCalls = GestureArbiterEventCounter()
        let predecessorTask = Task { @MainActor in
            await blockedPredecessor.wait()
        }
        await blockedPredecessor.waitUntilEntered()

        let startTask = arbiter.scheduleStart(
            token: 1,
            after: predecessorTask,
            isCurrent: {
                currentChecks.record()
                return tokenState.current == $0
            },
            begin: { beginCount += 1 }
        )
        await currentChecks.wait(for: 1)
        tokenState.current = nil
        let cancellationTask = arbiter.scheduleCancellation(
            after: startTask,
            cancelAndWait: { cancellationCalls.record() }
        )

        await cancellationCalls.wait(for: 1)

        XCTAssertEqual(beginCount, 0)
        XCTAssertEqual(cancellationCalls.count, 1)
        XCTAssertFalse(predecessorTask.isCancelled)
        XCTAssertFalse(blockedPredecessor.isOpen)

        blockedPredecessor.open()
        await cancellationTask.value

        XCTAssertEqual(beginCount, 0)
        XCTAssertEqual(cancellationCalls.count, 2)
    }

    func testStopEndsImmediatelyWhileCancelledStartIsStillBlocked() async {
        let arbiter = WritingDictationGestureTaskArbiter<Int>()
        let blockedStart = GestureArbiterGate()
        let endCalls = GestureArbiterEventCounter()
        let tokenState = GestureArbiterTokenState(1)

        let startTask = arbiter.scheduleStart(
            token: 1,
            after: nil,
            isCurrent: { tokenState.current == $0 },
            begin: { await blockedStart.wait() }
        )
        await blockedStart.waitUntilEntered()

        tokenState.current = nil
        let stopTask = arbiter.scheduleStop(
            token: 1,
            after: startTask,
            isContextCurrent: { _ in true },
            end: { endCalls.record() }
        )

        await endCalls.wait(for: 1)
        XCTAssertEqual(endCalls.count, 1)
        XCTAssertFalse(blockedStart.isOpen)

        blockedStart.open()
        await stopTask.value

        XCTAssertEqual(endCalls.count, 2)
    }

    func testCancellationRunsImmediatelyWhileCancelledStartIsStillBlocked() async {
        let arbiter = WritingDictationGestureTaskArbiter<Int>()
        let blockedStart = GestureArbiterGate()
        let cancellationCalls = GestureArbiterEventCounter()
        let tokenState = GestureArbiterTokenState(1)

        let startTask = arbiter.scheduleStart(
            token: 1,
            after: nil,
            isCurrent: { tokenState.current == $0 },
            begin: { await blockedStart.wait() }
        )
        await blockedStart.waitUntilEntered()

        tokenState.current = nil
        let cancellationTask = arbiter.scheduleCancellation(
            after: startTask,
            cancelAndWait: { cancellationCalls.record() }
        )

        await cancellationCalls.wait(for: 1)
        XCTAssertEqual(cancellationCalls.count, 1)
        XCTAssertFalse(blockedStart.isOpen)

        blockedStart.open()
        await cancellationTask.value

        XCTAssertEqual(cancellationCalls.count, 2)
    }

    func testCancellationDoesNotCancelConfigurationOrActivationPredecessor() async {
        let arbiter = WritingDictationGestureTaskArbiter<Int>()
        let blockedPredecessor = GestureArbiterGate()
        let cancellationCalls = GestureArbiterEventCounter()
        let predecessorTask = Task { @MainActor in
            await blockedPredecessor.wait()
        }
        await blockedPredecessor.waitUntilEntered()

        let cancellationTask = arbiter.scheduleCancellation(
            after: predecessorTask,
            cancelAndWait: { cancellationCalls.record() }
        )

        await cancellationCalls.wait(for: 1)
        XCTAssertFalse(predecessorTask.isCancelled)

        blockedPredecessor.open()
        await cancellationTask.value

        XCTAssertEqual(cancellationCalls.count, 2)
    }
}

@MainActor
private final class GestureArbiterTokenState<Token> {
    var current: Token?

    init(_ current: Token?) {
        self.current = current
    }
}

@MainActor
private final class GestureArbiterGate {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredCount = 0
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        enteredCount += 1
        let enteredWaiters = enteredWaiters
        self.enteredWaiters.removeAll()
        enteredWaiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard enteredCount == 0 else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
private final class GestureArbiterEventCounter {
    private(set) var count = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let ready = waiters.filter { count >= $0.count }
        waiters.removeAll { count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func wait(for expectedCount: Int) async {
        guard count < expectedCount else { return }
        await withCheckedContinuation {
            waiters.append((count: expectedCount, continuation: $0))
        }
    }
}
