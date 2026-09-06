import Foundation

@MainActor
final class WritingDictationGestureTaskArbiter<Token: Equatable> {
    typealias IsCurrent = @MainActor (Token) -> Bool
    typealias Operation = @MainActor () async -> Void

    private struct StartHandle {
        let token: Token
        let task: Task<Void, Never>
    }

    private var startHandle: StartHandle?

    func scheduleStart(
        token: Token,
        after predecessor: Task<Void, Never>?,
        isCurrent: @escaping IsCurrent,
        begin: @escaping Operation
    ) -> Task<Void, Never> {
        let task = Task { @MainActor in
            guard !Task.isCancelled, isCurrent(token) else { return }
            await predecessor?.value
            guard !Task.isCancelled, isCurrent(token) else { return }
            await begin()
            guard !Task.isCancelled, isCurrent(token) else { return }
        }
        startHandle = StartHandle(token: token, task: task)
        return task
    }

    func scheduleStop(
        token: Token,
        after predecessor: Task<Void, Never>?,
        isContextCurrent: @escaping IsCurrent,
        end: @escaping Operation
    ) -> Task<Void, Never> {
        let startTask = takeStartTask(matching: token)
        startTask?.cancel()

        return Task { @MainActor in
            guard isContextCurrent(token) else {
                await startTask?.value
                return
            }
            await end()
            await startTask?.value
            await predecessor?.value
            guard isContextCurrent(token) else { return }
            await end()
        }
    }

    func scheduleCancellation(
        after predecessor: Task<Void, Never>?,
        cancelAndWait: @escaping Operation
    ) -> Task<Void, Never> {
        let startTask = takeStartTask()
        startTask?.cancel()

        return Task { @MainActor in
            await cancelAndWait()
            await startTask?.value
            await predecessor?.value
            await cancelAndWait()
        }
    }

    private func takeStartTask(matching token: Token? = nil) -> Task<Void, Never>? {
        guard let startHandle,
              token == nil || startHandle.token == token
        else { return nil }

        self.startHandle = nil
        return startHandle.task
    }
}
