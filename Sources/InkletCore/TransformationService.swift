import Foundation

public struct TransformationService: Sendable {
    private let provider: any LLMProvider

    public init(provider: any LLMProvider) {
        self.provider = provider
    }

    public func transform(
        sourceText: String,
        mode: PromptMode,
        model: String,
        timeoutSeconds: TimeInterval
    ) async throws -> TransformationResult {
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            throw TransformationError.emptySource
        }

        let request = TransformationRequest(
            sourceText: trimmedSource,
            systemPrompt: mode.systemPrompt,
            modeID: mode.id,
            modeName: mode.name,
            model: model,
            timeoutSeconds: timeoutSeconds
        )

        let result = try await withTimeout(seconds: timeoutSeconds) {
            try await transformWithNetworkConnectionLostRetry(request)
        }
        let trimmedOutput = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            throw TransformationError.emptyResponse
        }

        return TransformationResult(
            outputText: trimmedOutput,
            providerMetadata: result.providerMetadata,
            elapsedMilliseconds: result.elapsedMilliseconds
        )
    }

    private func transformWithNetworkConnectionLostRetry(
        _ request: TransformationRequest
    ) async throws -> TransformationResult {
        do {
            return try await provider.transform(request)
        } catch {
            guard Self.isNetworkConnectionLost(error) else { throw error }
        }

        try Task.checkCancellation()

        do {
            return try await provider.transform(request)
        } catch {
            guard Self.isNetworkConnectionLost(error) else { throw error }
            throw TransformationError.networkConnectionLost
        }
    }

    private static func isNetworkConnectionLost(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == URLError.networkConnectionLost.rawValue
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()

        let nanoseconds = UInt64(max(seconds, 0.001) * 1_000_000_000)
        let race = TimeoutRaceState<T>()
        let operationTask = Task {
            try await operation()
        }
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw TransformationError.timeout
        }
        race.setTasks(operationTask: operationTask, timeoutTask: timeoutTask)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.setContinuation(continuation)

                Task {
                    do {
                        let result = try await operationTask.value
                        _ = race.resolve(with: .success(result))
                    } catch {
                        _ = race.resolve(with: .failure(error))
                    }
                }

                Task {
                    do {
                        _ = try await timeoutTask.value
                    } catch {
                        _ = race.resolve(with: .failure(error))
                    }
                }
            }
        } onCancel: {
            _ = race.resolve(with: .failure(CancellationError()))
        }
    }
}

private final class TimeoutRaceState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var operationTask: Task<T, Error>?
    private var timeoutTask: Task<Void, Error>?
    private var pendingResult: Result<T, Error>?
    private var isResolved = false

    func setTasks(operationTask: Task<T, Error>, timeoutTask: Task<Void, Error>) {
        lock.lock()
        let shouldCancel = isResolved
        if shouldCancel {
            lock.unlock()
            operationTask.cancel()
            timeoutTask.cancel()
        } else {
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
    }

    func setContinuation(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            resume(continuation, with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(with result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return false
        }
        isResolved = true

        let operationTask = operationTask
        let timeoutTask = timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil

        guard let continuation else {
            pendingResult = result
            lock.unlock()
            operationTask?.cancel()
            timeoutTask?.cancel()
            return true
        }
        self.continuation = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        resume(continuation, with: result)
        return true
    }

    private func resume(
        _ continuation: CheckedContinuation<T, Error>,
        with result: Result<T, Error>
    ) {
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
