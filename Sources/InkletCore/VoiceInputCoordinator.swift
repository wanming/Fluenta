import AppKit
import Foundation

public enum VoiceInputStatus: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case choosingPromptMode
    case polishing
    case inserting
    case fallbackInserted(String)
    case error(String)

    public var allowsCancellation: Bool {
        switch self {
        case .listening, .transcribing, .choosingPromptMode, .polishing, .inserting:
            true
        case .idle, .fallbackInserted, .error:
            false
        }
    }
}

public struct VoiceInputHistoryEvent: Equatable, Sendable {
    public var transcript: String
    public var finalText: String
    public var cleanupPromptModeID: String?
    public var speechModel: String
    public var cleanupFallback: Bool

    public init(
        transcript: String,
        finalText: String,
        cleanupPromptModeID: String?,
        speechModel: String,
        cleanupFallback: Bool
    ) {
        self.transcript = transcript
        self.finalText = finalText
        self.cleanupPromptModeID = cleanupPromptModeID
        self.speechModel = speechModel
        self.cleanupFallback = cleanupFallback
    }
}

public struct VoicePromptModeSelectionRequest: Equatable, Sendable {
    public var transcript: String
    public var defaultPromptModeID: String

    public init(transcript: String, defaultPromptModeID: String) {
        self.transcript = transcript
        self.defaultPromptModeID = defaultPromptModeID
    }
}

public enum VoicePromptModeSelection: Equatable, Sendable {
    case promptMode(String)
    case rawTranscript
    case cancelled
}

@MainActor
public final class VoiceInputCoordinator {
    public typealias ConfigProvider = @MainActor () -> VoiceInputConfig
    public typealias TargetApplicationProvider = @MainActor () -> NSRunningApplication?
    public typealias StartRecording = @MainActor () async throws -> Void
    public typealias StopRecording = @MainActor () async throws -> URL
    public typealias CancelRecording = @MainActor () async -> Void
    public typealias Transcribe = @MainActor (SpeechTranscriptionRequest) async throws -> SpeechTranscriptionResult
    public typealias SelectPromptMode = @MainActor (VoicePromptModeSelectionRequest) async -> VoicePromptModeSelection
    public typealias Cleanup = @MainActor (String, String) async throws -> String
    public typealias Insert = @MainActor (String, NSRunningApplication) async throws -> Void
    public typealias RecordHistory = @MainActor (VoiceInputHistoryEvent) async -> Void
    public typealias StatusHandler = @MainActor (VoiceInputStatus) -> Void
    public typealias IdleStateHandler = @MainActor (Bool) -> Void

    private enum State {
        case idle
        case starting
        case listening
        case transcribing
        case choosingPromptMode
        case polishing
        case inserting
        case cancelling
    }

    private let configProvider: ConfigProvider
    private let targetApplicationProvider: TargetApplicationProvider
    private let startRecordingHandler: StartRecording
    private let stopRecordingHandler: StopRecording
    private let cancelRecordingHandler: CancelRecording
    private let transcribeHandler: Transcribe
    private let selectPromptModeHandler: SelectPromptMode
    private let cleanupHandler: Cleanup
    private let insertHandler: Insert
    private let recordHistoryHandler: RecordHistory
    private let statusHandler: StatusHandler
    private let idleStateHandler: IdleStateHandler
    private var state: State = .idle
    private var sessionID = 0
    private var activeOperationCount = 0
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        configProvider: @escaping ConfigProvider,
        targetApplicationProvider: @escaping TargetApplicationProvider,
        startRecording: @escaping StartRecording,
        stopRecording: @escaping StopRecording,
        cancelRecording: @escaping CancelRecording,
        transcribe: @escaping Transcribe,
        selectPromptMode: @escaping SelectPromptMode = { request in
            .promptMode(request.defaultPromptModeID)
        },
        cleanup: @escaping Cleanup,
        insert: @escaping Insert,
        recordHistory: @escaping RecordHistory = { _ in },
        statusHandler: @escaping StatusHandler,
        idleStateHandler: @escaping IdleStateHandler = { _ in }
    ) {
        self.configProvider = configProvider
        self.targetApplicationProvider = targetApplicationProvider
        self.startRecordingHandler = startRecording
        self.stopRecordingHandler = stopRecording
        self.cancelRecordingHandler = cancelRecording
        self.transcribeHandler = transcribe
        self.selectPromptModeHandler = selectPromptMode
        self.cleanupHandler = cleanup
        self.insertHandler = insert
        self.recordHistoryHandler = recordHistory
        self.statusHandler = statusHandler
        self.idleStateHandler = idleStateHandler
    }

    public func toggle() async {
        switch state {
        case .idle:
            await start()
        case .listening:
            await stop()
        case .starting, .transcribing, .choosingPromptMode, .polishing, .inserting, .cancelling:
            return
        }
    }

    public func start() async {
        guard case .idle = state else {
            return
        }

        beginOperation()
        defer { finishOperation() }

        sessionID += 1
        let activeSessionID = sessionID
        state = .starting
        do {
            try await startRecordingHandler()
            guard activeSessionID == sessionID else {
                await cancelRecordingHandler()
                return
            }
            state = .listening
            statusHandler(.listening)
        } catch is CancellationError {
            guard activeSessionID == sessionID else {
                return
            }
            state = .idle
            statusHandler(.idle)
        } catch {
            guard activeSessionID == sessionID else {
                return
            }
            state = .idle
            statusHandler(.error(userFacingMessage(for: error)))
        }
    }

    public func stop() async {
        if case .starting = state {
            await cancel()
            return
        }

        guard case .listening = state else {
            return
        }

        beginOperation()
        defer { finishOperation() }

        let activeSessionID = sessionID
        do {
            state = .transcribing
            statusHandler(.transcribing)
            let audioURL = try await stopRecordingHandler()
            let config = configProvider()
            let transcription: SpeechTranscriptionResult
            do {
                transcription = try await transcribeHandler(SpeechTranscriptionRequest(
                    audioFileURL: audioURL,
                    model: config.speechModel,
                    timeoutSeconds: 20
                ))
            } catch {
                guard activeSessionID == sessionID else {
                    return
                }
                state = .idle
                statusHandler(.error(transcriptionFailureMessage(for: error)))
                return
            }
            guard activeSessionID == sessionID else {
                return
            }

            let transcript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                state = .idle
                statusHandler(.error(SpeechTranscriptionError.emptyResponse.errorDescription ?? "No speech was recognized."))
                return
            }

            let finalText: String
            let cleanupPromptModeID: String?
            switch config.postTranscriptionAction {
            case .useDefaultPromptMode:
                guard let processedText = try await processedText(
                    from: transcript,
                    promptModeID: config.voiceCleanupPromptModeID,
                    speechModel: config.speechModel,
                    activeSessionID: activeSessionID
                ) else {
                    return
                }
                finalText = processedText
                cleanupPromptModeID = config.voiceCleanupPromptModeID
            case .askEachTime:
                state = .choosingPromptMode
                statusHandler(.choosingPromptMode)
                let selection = await selectPromptModeHandler(VoicePromptModeSelectionRequest(
                    transcript: transcript,
                    defaultPromptModeID: config.voiceCleanupPromptModeID
                ))
                guard activeSessionID == sessionID else {
                    return
                }

                switch selection {
                case .promptMode(let modeID):
                    guard let processedText = try await processedText(
                        from: transcript,
                        promptModeID: modeID,
                        speechModel: config.speechModel,
                        activeSessionID: activeSessionID
                    ) else {
                        return
                    }
                    finalText = processedText
                    cleanupPromptModeID = modeID
                case .rawTranscript:
                    finalText = transcript
                    cleanupPromptModeID = nil
                case .cancelled:
                    state = .idle
                    statusHandler(.idle)
                    return
                }
            case .insertRawTranscript:
                finalText = transcript
                cleanupPromptModeID = nil
            }

            try await insertText(finalText)
            guard activeSessionID == sessionID else {
                return
            }
            await recordVoiceHistory(
                transcript: transcript,
                finalText: finalText,
                cleanupPromptModeID: cleanupPromptModeID,
                speechModel: config.speechModel,
                cleanupFallback: false
            )
            state = .idle
            statusHandler(.idle)
        } catch is CancellationError {
            guard activeSessionID == sessionID else {
                return
            }
            state = .idle
            statusHandler(.idle)
        } catch {
            guard activeSessionID == sessionID else {
                return
            }
            state = .idle
            statusHandler(.error(userFacingMessage(for: error)))
        }
    }

    public func cancel() async {
        beginOperation()
        defer { finishOperation() }

        switch state {
        case .starting, .listening:
            sessionID += 1
            state = .cancelling
            await cancelRecordingHandler()
            state = .idle
            statusHandler(.idle)
        case .idle, .transcribing, .choosingPromptMode, .polishing, .inserting, .cancelling:
            sessionID += 1
            state = .idle
            statusHandler(.idle)
        }
    }

    public var isIdle: Bool {
        if case .idle = state {
            return activeOperationCount == 0
        }
        return false
    }

    public func cancelForMigrationMaintenance() async {
        guard !isIdle else {
            return
        }

        let shouldCancelRecordingDirectly: Bool
        switch state {
        case .listening:
            shouldCancelRecordingDirectly = true
        case .starting:
            shouldCancelRecordingDirectly = activeOperationCount == 0
        case .idle, .transcribing, .choosingPromptMode, .polishing, .inserting, .cancelling:
            shouldCancelRecordingDirectly = false
        }

        sessionID += 1
        state = .cancelling
        if shouldCancelRecordingDirectly {
            await cancelRecordingHandler()
        }
        await waitForActiveOperations()
        state = .idle
        statusHandler(.idle)
        idleStateHandler(true)
    }

    private func beginOperation() {
        activeOperationCount += 1
        idleStateHandler(false)
    }

    private func finishOperation() {
        activeOperationCount -= 1
        guard activeOperationCount == 0 else {
            return
        }
        let waiters = operationWaiters
        operationWaiters.removeAll()
        idleStateHandler(isIdle)
        waiters.forEach { $0.resume() }
    }

    private func waitForActiveOperations() async {
        guard activeOperationCount > 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func recordVoiceHistory(
        transcript: String,
        finalText: String,
        cleanupPromptModeID: String?,
        speechModel: String,
        cleanupFallback: Bool
    ) async {
        await recordHistoryHandler(VoiceInputHistoryEvent(
            transcript: transcript,
            finalText: finalText,
            cleanupPromptModeID: cleanupPromptModeID,
            speechModel: speechModel,
            cleanupFallback: cleanupFallback
        ))
    }

    private func processedText(
        from transcript: String,
        promptModeID: String,
        speechModel: String,
        activeSessionID: Int
    ) async throws -> String? {
        do {
            state = .polishing
            statusHandler(.polishing)
            let cleanedText = try await cleanupHandler(transcript, promptModeID)
            guard activeSessionID == sessionID else {
                throw CancellationError()
            }
            return cleanedText
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard activeSessionID == sessionID else {
                throw CancellationError()
            }
            try await insertText(transcript)
            guard activeSessionID == sessionID else {
                return nil
            }
            await recordVoiceHistory(
                transcript: transcript,
                finalText: transcript,
                cleanupPromptModeID: promptModeID,
                speechModel: speechModel,
                cleanupFallback: true
            )
            state = .idle
            statusHandler(.fallbackInserted(cleanupFailureMessage(for: error)))
            statusHandler(.idle)
            return nil
        }
    }

    private func insertText(_ text: String) async throws {
        guard let targetApplication = targetApplicationProvider() else {
            throw VoiceInputCoordinatorError.missingTargetApplication
        }

        state = .inserting
        statusHandler(.inserting)
        try await insertHandler(text, targetApplication)
    }

    private func transcriptionFailureMessage(for error: Error) -> String {
        switch error {
        case SpeechTranscriptionError.emptyAudio:
            return SpeechTranscriptionError.emptyAudio.errorDescription ?? "No audio was recorded."
        case SpeechTranscriptionError.emptyResponse:
            return SpeechTranscriptionError.emptyResponse.errorDescription ?? "No speech was recognized."
        default:
            return "Transcription failed. Please try again."
        }
    }

    private func cleanupFailureMessage(for error: Error) -> String {
        "Cleanup failed. Inserted transcription."
    }

    private func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

public enum VoiceInputCoordinatorError: Error, Equatable, LocalizedError {
    case missingTargetApplication

    public var errorDescription: String? {
        switch self {
        case .missingTargetApplication:
            return "No target app is available."
        }
    }
}
