import Foundation

struct SelectionShutdownTaskSnapshot {
    private let tasks: [Task<Void, Never>]

    init(tasks: [Task<Void, Never>]) {
        self.tasks = tasks
    }

    init(
        read: Task<Void, Never>?,
        translation: Task<Void, Never>?,
        speech: Task<Void, Never>?,
        feedback: Task<Void, Never>?
    ) {
        self.tasks = [read, translation, speech, feedback].compactMap { $0 }
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
    }

    func waitForCompletion() async {
        for task in tasks {
            await task.value
        }
    }
}

@MainActor
final class SelectionTaskRegistry {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func register(_ task: Task<Void, Never>, id: UUID) {
        tasks[id] = task
    }

    func remove(id: UUID) {
        tasks[id] = nil
    }

    func snapshotAndClear() -> SelectionShutdownTaskSnapshot {
        let snapshot = SelectionShutdownTaskSnapshot(tasks: Array(tasks.values))
        tasks.removeAll()
        return snapshot
    }
}
