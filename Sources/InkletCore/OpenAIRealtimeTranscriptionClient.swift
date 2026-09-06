import Foundation
import CoreFoundation

protocol RealtimeWebSocketTransport: Sendable {
    func connect(_ request: URLRequest) async throws
    func send(text: String) async throws
    func receiveText() async throws -> String
    func close() async
}

actor URLSessionRealtimeWebSocketTransport: RealtimeWebSocketTransport {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(session: URLSession) {
        self.session = session
    }

    func connect(_ request: URLRequest) async throws {
        guard task == nil else {
            throw RealtimeTranscriptionError.invalidState
        }

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(text: String) async throws {
        guard let task else {
            throw RealtimeTranscriptionError.connectionClosed
        }
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        guard let task else {
            throw RealtimeTranscriptionError.connectionClosed
        }

        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw RealtimeTranscriptionError.invalidMessage
            }
            return text
        @unknown default:
            throw RealtimeTranscriptionError.invalidMessage
        }
    }

    func close() async {
        guard let task else { return }
        self.task = nil
        task.cancel(with: .normalClosure, reason: nil)
    }
}

public actor OpenAIRealtimeTranscriptionClient: RealtimeTranscriptionClient {
    public static let model = "gpt-live-transcribe"
    public static let defaultEndpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!

    private enum State {
        case fresh
        case connecting
        case ready
        case committed
        case closed
    }

    private let apiKeyProvider: @Sendable () throws -> String
    private let endpoint: URL
    private let transport: any RealtimeWebSocketTransport
    private var state: State = .fresh
    private var isReceiving = false
    private var outboundTail: Task<Void, Error>?
    private var commitTask: Task<Void, Error>?
    private var queuedOutboundCount = 0
    private var commitWaiterCount = 0
    private var outboundTaskStartedCount = 0
    private var waitingOnPredecessorCount = 0

    public init(
        apiKeyProvider: @escaping @Sendable () throws -> String,
        endpoint: URL = OpenAIRealtimeTranscriptionClient.defaultEndpoint,
        session: URLSession = .shared
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.endpoint = endpoint
        transport = URLSessionRealtimeWebSocketTransport(session: session)
    }

    init(
        apiKeyProvider: @escaping @Sendable () throws -> String,
        endpoint: URL,
        transport: any RealtimeWebSocketTransport
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.endpoint = endpoint
        self.transport = transport
    }

    public func connect(timeoutSeconds: TimeInterval) async throws {
        guard case .fresh = state else {
            throw RealtimeTranscriptionError.invalidState
        }
        guard Self.isValid(endpoint: endpoint) else {
            throw RealtimeTranscriptionError.invalidEndpoint
        }

        let apiKey: String
        do {
            apiKey = try apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw RealtimeTranscriptionError.missingAPIKey
        }
        guard !apiKey.isEmpty else {
            throw RealtimeTranscriptionError.missingAPIKey
        }

        state = .connecting
        let deadline = Date().addingTimeInterval(max(timeoutSeconds, 0))
        var configuredRequest = URLRequest(url: endpoint)
        configuredRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let request = configuredRequest

        do {
            try await Self.withTimeout(seconds: remainingTime(until: deadline)) {
                try await self.transport.connect(request)
            }
            try ensureStillConnecting()
            try await Self.withTimeout(seconds: remainingTime(until: deadline)) {
                try await self.transport.send(text: Self.sessionUpdateMessage)
            }
            try ensureStillConnecting()
            try await waitForSessionUpdated(deadline: deadline)
            try ensureStillConnecting()
            state = .ready
        } catch {
            await closeAfterFailure()
            throw Self.normalizedConnectionError(error)
        }
    }

    public func appendPCM16(_ data: Data) async throws {
        guard case .ready = state, !data.isEmpty else {
            throw RealtimeTranscriptionError.invalidState
        }

        let message = #"{"type":"input_audio_buffer.append","audio":"\#(data.base64EncodedString())"}"#
        let task = enqueueOutbound(message)
        do {
            try await awaitTransportTask(task)
        } catch {
            await closeAfterFailure()
            throw Self.normalizedConnectionError(error)
        }
    }

    public func commit() async throws {
        switch state {
        case .committed:
            guard let commitTask else { return }
            commitWaiterCount += 1
            defer { commitWaiterCount -= 1 }
            do { try await awaitTransportTask(commitTask) }
            catch { await closeAfterFailure(); throw Self.normalizedConnectionError(error) }
            return
        case .ready:
            state = .committed
        case .fresh, .connecting, .closed:
            throw RealtimeTranscriptionError.invalidState
        }

        let task = enqueueOutbound(#"{"type":"input_audio_buffer.commit"}"#)
        commitTask = task
        commitWaiterCount = 1
        defer { commitWaiterCount -= 1 }
        do {
            try await awaitTransportTask(task)
            commitTask = nil
        } catch {
            await closeAfterFailure()
            throw Self.normalizedConnectionError(error)
        }
    }

    public func nextEvent() async throws -> RealtimeTranscriptionEvent {
        guard state == .ready || state == .committed, !isReceiving else {
            throw RealtimeTranscriptionError.invalidState
        }
        isReceiving = true

        do {
            while true {
                let receiveTask = Task { try await self.transport.receiveText() }
                let text = try await awaitTransportTask(receiveTask)
                let message = try Self.parseMessage(text)
                if let serverError = try Self.serverError(from: message) {
                    throw serverError
                }
                if let transcriptionFailure = try Self.inputAudioTranscriptionFailure(from: message) {
                    throw transcriptionFailure
                }
                if let event = try Self.transcriptionEvent(from: message) {
                    isReceiving = false
                    return event
                }
            }
        } catch {
            isReceiving = false
            await closeAfterFailure()
            throw Self.normalizedConnectionError(error)
        }
    }

    public func close() async {
        guard state != .closed else { return }
        state = .closed
        await transport.close()
    }

    private func waitForSessionUpdated(deadline: Date) async throws {
        while true {
            let text = try await Self.withTimeout(seconds: remainingTime(until: deadline)) {
                try await self.transport.receiveText()
            }
            let message = try Self.parseMessage(text)
            if let serverError = try Self.serverError(from: message) {
                throw serverError
            }
            guard let type = message["type"] as? String else {
                throw RealtimeTranscriptionError.invalidMessage
            }
            if type == "session.updated" {
                return
            }
        }
    }

    private func ensureStillConnecting() throws {
        guard case .connecting = state else {
            throw RealtimeTranscriptionError.invalidState
        }
    }

    private func remainingTime(until deadline: Date) -> TimeInterval {
        deadline.timeIntervalSinceNow
    }

    private func closeAfterFailure() async {
        guard state != .closed else { return }
        state = .closed
        await transport.close()
    }

    private func enqueueOutbound(_ text: String) -> Task<Void, Error> {
        let predecessor = outboundTail
        let transport = transport
        queuedOutboundCount += 1
        let task = Task {
            outboundTaskStartedCount += 1
            if let predecessor {
                waitingOnPredecessorCount += 1
                defer { waitingOnPredecessorCount -= 1 }
                _ = try await predecessor.value
            }
            try await transport.send(text: text)
        }
        outboundTail = task
        return task
    }

    func waitForOutboundMilestone(queuedCount: Int, commitWaiterCount: Int, waitingOnPredecessorCount: Int) async {
        while queuedOutboundCount < queuedCount || self.commitWaiterCount < commitWaiterCount || self.waitingOnPredecessorCount < waitingOnPredecessorCount {
            await Task.yield()
        }
    }

    private func awaitTransportTask<T>(_ task: Task<T, Error>) async throws -> T {
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { await self.closeAfterFailure() }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static let sessionUpdateMessage = #"{"type":"session.update","session":{"type":"transcription","audio":{"input":{"format":{"type":"audio/pcm","rate":24000},"transcription":{"model":"gpt-live-transcribe"},"turn_detection":null}}}}"#

    private static func isValid(endpoint: URL) -> Bool {
        guard endpoint.scheme?.lowercased() == "wss" else {
            return false
        }
        return endpoint.host?.isEmpty == false
    }

    private static func parseMessage(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any]
        else {
            throw RealtimeTranscriptionError.invalidMessage
        }
        return message
    }

    private static func serverError(from message: [String: Any]) throws -> RealtimeTranscriptionError? {
        let type = try requiredString(message["type"])
        guard type == "error" else { return nil }
        guard let details = message["error"] as? [String: Any],
              let errorMessage = try? requiredString(details["message"])
        else { throw RealtimeTranscriptionError.invalidMessage }
        return .server(code: try optionalString(details, key: "code"), message: errorMessage)
    }

    private static func inputAudioTranscriptionFailure(
        from message: [String: Any]
    ) throws -> RealtimeTranscriptionError? {
        let type = try requiredString(message["type"])
        guard type == "conversation.item.input_audio_transcription.failed" else { return nil }
        _ = try optionalString(message, key: "event_id")
        _ = try requiredString(message["item_id"])
        _ = try requiredInteger(message["content_index"])
        guard let details = message["error"] as? [String: Any] else {
            throw RealtimeTranscriptionError.invalidMessage
        }
        _ = try requiredString(details["type"])
        let code = try optionalString(details, key: "code")
        let errorMessage = try requiredString(details["message"])
        _ = try optionalString(details, key: "param")
        return .server(code: code, message: errorMessage)
    }

    private static func transcriptionEvent(from message: [String: Any]) throws -> RealtimeTranscriptionEvent? {
        let type = try requiredString(message["type"])

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            let eventID = try optionalString(message, key: "event_id")
            let sequence = try optionalInteger(message, key: "sequence")
            let itemID = try requiredString(message["item_id"])
            let contentIndex = try requiredInteger(message["content_index"])
            let delta = try requiredString(message["delta"])
            return .delta(
                eventID: eventID,
                sequence: sequence,
                itemID: itemID,
                contentIndex: contentIndex,
                text: delta
            )
        case "conversation.item.input_audio_transcription.completed":
            let eventID = try optionalString(message, key: "event_id")
            let sequence = try optionalInteger(message, key: "sequence")
            let itemID = try requiredString(message["item_id"])
            let contentIndex = try requiredInteger(message["content_index"])
            let transcript = try requiredString(message["transcript"])
            return .completed(
                eventID: eventID,
                sequence: sequence,
                itemID: itemID,
                contentIndex: contentIndex,
                transcript: transcript
            )
        default:
            return nil
        }
    }

    private static func requiredString(_ value: Any?) throws -> String {
        guard let value = value as? String else {
            throw RealtimeTranscriptionError.invalidMessage
        }
        return value
    }

    private static func optionalString(_ message: [String: Any], key: String) throws -> String? {
        guard let value = message[key], !(value is NSNull) else { return nil }
        return try requiredString(value)
    }

    private static func requiredInteger(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number),
              let integer = Int(number.stringValue)
        else {
            throw RealtimeTranscriptionError.invalidMessage
        }
        return integer
    }

    private static func optionalInteger(_ message: [String: Any], key: String) throws -> Int? {
        guard let value = message[key] else { return nil }
        return try requiredInteger(value)
    }

    private static func normalizedConnectionError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let realtimeError = error as? RealtimeTranscriptionError {
            return realtimeError
        }
        if error is RealtimeTimeoutError {
            return RealtimeTranscriptionError.connectionTimedOut
        }
        return RealtimeTranscriptionError.connectionClosed
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds > 0 else { throw RealtimeTimeoutError() }
        let race = RealtimeTimeoutRace<T>()
        let operationTask = Task {
            try await operation()
        }
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(seconds))
            throw RealtimeTimeoutError()
        }
        race.setTasks(operationTask: operationTask, timeoutTask: timeoutTask)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.setContinuation(continuation)
                Task {
                    do {
                        _ = race.resolve(with: .success(try await operationTask.value))
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

private struct RealtimeTimeoutError: Error, Sendable {}

private final class RealtimeTimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var operationTask: Task<T, Error>?
    private var timeoutTask: Task<Void, Error>?
    private var pendingResult: Result<T, Error>?
    private var isResolved = false

    func setTasks(operationTask: Task<T, Error>, timeoutTask: Task<Void, Error>) {
        lock.lock()
        if isResolved {
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

    private func resume(_ continuation: CheckedContinuation<T, Error>, with result: Result<T, Error>) {
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
