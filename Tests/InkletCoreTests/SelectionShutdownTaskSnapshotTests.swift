import XCTest
@testable import Inklet

final class SelectionShutdownTaskSnapshotTests: XCTestCase {
    @MainActor
    func testRegistrySnapshotRetainsSupersededTaskUntilItsCleanupFinishes() async {
        let registry = SelectionTaskRegistry()
        let cancellationRecorder = CompletionRecorder()
        let oldCleanupGate = SuspensionGate()
        let newTaskGate = SuspensionGate()
        let oldTaskID = UUID()
        let oldTask = Task { @MainActor in
            while !Task.isCancelled {
                await Task.yield()
            }
            await cancellationRecorder.markComplete()
            await oldCleanupGate.wait()
        }
        registry.register(oldTask, id: oldTaskID)
        oldTask.cancel()
        while !(await cancellationRecorder.isComplete()) {
            await Task.yield()
        }

        let newTaskID = UUID()
        let newTask = Task { @MainActor in
            await newTaskGate.wait()
        }
        registry.register(newTask, id: newTaskID)
        let snapshot = registry.snapshotAndClear()
        snapshot.cancel()
        let waitCompletion = CompletionRecorder()
        let waitTask = Task {
            await snapshot.waitForCompletion()
            await waitCompletion.markComplete()
        }

        while !(await newTaskGate.hasWaiter()) {
            await Task.yield()
        }
        await newTaskGate.open()
        await Task.yield()
        let completedBeforeOldCleanup = await waitCompletion.isComplete()
        XCTAssertFalse(completedBeforeOldCleanup)

        await oldCleanupGate.open()
        await waitTask.value
        let completedAfterBothTasks = await waitCompletion.isComplete()
        XCTAssertTrue(completedAfterBothTasks)
    }

    func testCancelCancelsEveryCapturedTask() async {
        let recorder = CancellationRecorder()
        let tasks = SelectionTaskKind.allCases.map { kind in
            Task {
                while !Task.isCancelled {
                    await Task.yield()
                }
                await recorder.record(kind)
            }
        }
        let snapshot = SelectionShutdownTaskSnapshot(
            read: tasks[0],
            translation: tasks[1],
            speech: tasks[2],
            feedback: tasks[3]
        )

        snapshot.cancel()
        await snapshot.waitForCompletion()

        let cancelledTasks = await recorder.recordedKinds()
        XCTAssertEqual(cancelledTasks, Set(SelectionTaskKind.allCases))
    }

    func testWaitForCompletionWaitsForEveryCapturedTask() async {
        let gates = SelectionTaskKind.allCases.map { _ in SuspensionGate() }
        let tasks = gates.map { gate in
            Task {
                await gate.wait()
            }
        }
        let snapshot = SelectionShutdownTaskSnapshot(
            read: tasks[0],
            translation: tasks[1],
            speech: tasks[2],
            feedback: tasks[3]
        )
        let completion = CompletionRecorder()
        let waitTask = Task {
            await snapshot.waitForCompletion()
            await completion.markComplete()
        }

        for gate in gates {
            while !(await gate.hasWaiter()) {
                await Task.yield()
            }
        }
        let didCompleteBeforeAnyGateOpened = await completion.isComplete()
        XCTAssertFalse(didCompleteBeforeAnyGateOpened)

        for gate in gates.dropLast() {
            await gate.open()
            await Task.yield()
            let didCompleteBeforeFinalGateOpened = await completion.isComplete()
            XCTAssertFalse(didCompleteBeforeFinalGateOpened)
        }

        await gates[3].open()
        await waitTask.value
        let didComplete = await completion.isComplete()
        XCTAssertTrue(didComplete)
    }
}

private enum SelectionTaskKind: CaseIterable, Hashable, Sendable {
    case read
    case translation
    case speech
    case feedback
}

private actor CancellationRecorder {
    private var kinds: Set<SelectionTaskKind> = []

    func record(_ kind: SelectionTaskKind) {
        kinds.insert(kind)
    }

    func recordedKinds() -> Set<SelectionTaskKind> {
        kinds
    }
}

private actor CompletionRecorder {
    private var complete = false

    func markComplete() {
        complete = true
    }

    func isComplete() -> Bool {
        complete
    }
}

private actor SuspensionGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasWaiter() -> Bool {
        continuation != nil
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
