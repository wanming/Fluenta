import Foundation
import InkletCore

@MainActor
final class WritingDictationCoordinator {
    enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case listening
        case recordingForFallback
        case finalizing
        case recovering
        case complete
        case failed(String)

        var isActive: Bool {
            switch self {
            case .connecting, .listening, .recordingForFallback, .finalizing, .recovering:
                true
            case .idle, .complete, .failed:
                false
            }
        }
    }

    typealias ConfigProvider = @MainActor () -> VoiceInputConfig
    typealias ClientFactory = @MainActor () throws -> any RealtimeTranscriptionClient
    typealias BeginTransaction = @MainActor () -> (any DictationEditorTransacting)?
    typealias FallbackTranscriber = @MainActor (URL, VoiceInputConfig) async throws -> String
    typealias DeleteTemporaryFile = @MainActor (URL) -> Void
    typealias PhaseHandler = @MainActor (Phase) -> Void
    typealias ErrorKey = @MainActor (Error) -> String

    private struct Session {
        let id: UUID
        let config: VoiceInputConfig
        let transaction: any DictationEditorTransacting
        let client: any RealtimeTranscriptionClient
        var accumulator = RealtimeTranscriptAccumulator()
        var earlyAudio = Data()
        var captureStarted = false
        var captureStopped = false
        var connectionReady = false
        var realtimeAvailable = true
        var releaseRequested = false
        var commitSent = false
        var fallbackAttempted = false
        var terminalWon = false
        var clientClosed = false
        var recordingURL: URL?
        var frameTask: Task<Void, Never>?
        var connectTask: Task<Void, Never>?
        var receiveTask: Task<Void, Never>?
        var finalizeTask: Task<Void, Never>?
        var finalTimeoutTask: Task<Void, Never>?
        var finalWaiter: CheckedContinuation<Void, Error>?
    }

    private static let earlyAudioLimitBytes = 240_000
    private static let connectionTimeoutSeconds: TimeInterval = 5
    private static let finalTimeoutSeconds: TimeInterval = 15

    private let configProvider: ConfigProvider
    private let audioCapture: any DictationAudioCapturing
    private let makeRealtimeClient: ClientFactory
    private let beginTransaction: BeginTransaction
    private let transcribeFallback: FallbackTranscriber
    private let deleteTemporaryFile: DeleteTemporaryFile
    private let phaseHandler: PhaseHandler
    private let errorKey: ErrorKey
    private let finalTimeoutSeconds: TimeInterval
    private var session: Session?

    private(set) var phase: Phase = .idle
    var isActive: Bool { phase.isActive }
    var isIdle: Bool { !phase.isActive }

    init(
        configProvider: @escaping ConfigProvider,
        audioCapture: any DictationAudioCapturing,
        makeRealtimeClient: @escaping ClientFactory,
        beginTransaction: @escaping BeginTransaction,
        transcribeFallback: @escaping FallbackTranscriber,
        deleteTemporaryFile: @escaping DeleteTemporaryFile = { url in
            try? FileManager.default.removeItem(at: url)
        },
        phaseHandler: @escaping PhaseHandler = { _ in },
        errorKey: @escaping ErrorKey = WritingDictationCoordinator.defaultErrorKey,
        finalTimeoutSeconds: TimeInterval = WritingDictationCoordinator.finalTimeoutSeconds
    ) {
        self.configProvider = configProvider
        self.audioCapture = audioCapture
        self.makeRealtimeClient = makeRealtimeClient
        self.beginTransaction = beginTransaction
        self.transcribeFallback = transcribeFallback
        self.deleteTemporaryFile = deleteTemporaryFile
        self.phaseHandler = phaseHandler
        self.errorKey = errorKey
        self.finalTimeoutSeconds = finalTimeoutSeconds
    }

    func beginHold() async {
        guard session == nil else {
            await cancelAndWait()
            await beginHold()
            return
        }

        let client: any RealtimeTranscriptionClient
        do {
            client = try makeRealtimeClient()
        } catch {
            publish(.failed(errorKey(error)))
            return
        }

        guard let transaction = beginTransaction() else {
            publish(.failed("dictation.error.editorUnavailable"))
            await client.close()
            return
        }

        let id = UUID()
        let config = configProvider()
        session = Session(id: id, config: config, transaction: transaction, client: client)
        publish(.connecting)

        do {
            let stream = try await audioCapture.startStreaming(microphoneDeviceID: config.microphoneDeviceID)
            guard session?.id == id else { return }
            session?.captureStarted = true
            session?.frameTask = Task { @MainActor [weak self] in
                await self?.consumeFrames(stream, sessionID: id)
            }
            session?.connectTask = Task { @MainActor [weak self] in
                await self?.connect(sessionID: id)
            }
            if session?.releaseRequested == true {
                startFinalization(sessionID: id)
            }
        } catch is CancellationError {
            guard session?.id == id else { return }
            await cancelAndWait()
        } catch {
            guard session?.id == id else { return }
            await finish(sessionID: id, outcome: .failure(errorKey(error)))
        }
    }

    func endHold() async {
        guard let session, !session.terminalWon, !session.releaseRequested else { return }
        self.session?.releaseRequested = true
        publish(.finalizing)
        if session.captureStarted {
            startFinalization(sessionID: session.id)
        }
    }

    func cancel() async {
        guard let session else {
            publish(.idle)
            return
        }
        self.session = nil
        session.frameTask?.cancel()
        session.connectTask?.cancel()
        session.receiveTask?.cancel()
        session.finalizeTask?.cancel()
        session.finalTimeoutTask?.cancel()
        session.finalWaiter?.resume(throwing: CancellationError())
        session.transaction.restore()
        if !session.captureStopped {
            await audioCapture.cancel()
        }
        await session.client.close()
        if let recordingURL = session.recordingURL {
            deleteTemporaryFile(recordingURL)
        }
        publish(.idle)
    }

    func cancelAndWait() async {
        await cancel()
    }

    private func connect(sessionID: UUID) async {
        guard let client = session?.client, session?.id == sessionID else { return }
        do {
            try await client.connect(timeoutSeconds: Self.connectionTimeoutSeconds)
            await handleConnected(sessionID: sessionID)
        } catch is CancellationError {
            return
        } catch {
            await loseRealtime(sessionID: sessionID)
        }
    }

    private func handleConnected(sessionID: UUID) async {
        guard let current = session, current.id == sessionID, current.realtimeAvailable else { return }
        let earlyAudio = current.earlyAudio
        session?.earlyAudio.removeAll(keepingCapacity: false)
        if !earlyAudio.isEmpty {
            do {
                try await current.client.appendPCM16(earlyAudio)
            } catch is CancellationError {
                return
            } catch {
                await loseRealtime(sessionID: sessionID)
                return
            }
        }
        guard session?.id == sessionID, session?.realtimeAvailable == true else { return }
        session?.connectionReady = true
        if session?.releaseRequested == false {
            publish(.listening)
        }
        session?.receiveTask = Task { @MainActor [weak self] in
            await self?.receiveEvents(sessionID: sessionID)
        }
    }

    private func consumeFrames(
        _ stream: AsyncThrowingStream<Data, Error>,
        sessionID: UUID
    ) async {
        do {
            for try await data in stream {
                await acceptFrame(data, sessionID: sessionID)
            }
        } catch is CancellationError {
            return
        } catch {
            await loseRealtime(sessionID: sessionID)
        }
    }

    private func acceptFrame(_ data: Data, sessionID: UUID) async {
        guard !data.isEmpty,
              let current = session,
              current.id == sessionID,
              !current.terminalWon
        else { return }
        guard current.realtimeAvailable else { return }

        if !current.connectionReady {
            guard current.earlyAudio.count <= Self.earlyAudioLimitBytes - data.count else {
                await loseRealtime(sessionID: sessionID)
                return
            }
            session?.earlyAudio.append(data)
            return
        }

        do {
            try await current.client.appendPCM16(data)
        } catch is CancellationError {
            return
        } catch {
            await loseRealtime(sessionID: sessionID)
        }
    }

    private func receiveEvents(sessionID: UUID) async {
        while let current = session,
              current.id == sessionID,
              current.realtimeAvailable,
              !current.terminalWon {
            do {
                let event = try await current.client.nextEvent()
                guard session?.id == sessionID, session?.realtimeAvailable == true else { return }
                switch session?.accumulator.accept(event) {
                case let .provisional(text):
                    try session?.transaction.replaceProvisional(with: text)
                case let .final(text):
                    resumeFinalWaiter(sessionID: sessionID)
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await finish(sessionID: sessionID, outcome: .failure("dictation.error.noSpeech"))
                    } else {
                        await finish(sessionID: sessionID, outcome: .success(text))
                    }
                    return
                case .ignored, .none:
                    continue
                }
            } catch is CancellationError {
                return
            } catch {
                await loseRealtime(sessionID: sessionID)
                return
            }
        }
    }

    private func startFinalization(sessionID: UUID) {
        guard let current = session,
              current.id == sessionID,
              current.captureStarted,
              current.finalizeTask == nil,
              !current.terminalWon
        else { return }
        session?.finalizeTask = Task { @MainActor [weak self] in
            await self?.finalize(sessionID: sessionID)
        }
    }

    private func finalize(sessionID: UUID) async {
        guard let current = session, current.id == sessionID else { return }
        let recordingURL: URL
        do {
            recordingURL = try await audioCapture.stop()
        } catch is CancellationError {
            return
        } catch {
            await finish(sessionID: sessionID, outcome: .failure(errorKey(error)))
            return
        }
        guard session?.id == sessionID else {
            deleteTemporaryFile(recordingURL)
            return
        }
        session?.captureStopped = true
        session?.recordingURL = recordingURL
        await current.frameTask?.value
        guard let updated = session, updated.id == sessionID, !updated.terminalWon else { return }
        guard updated.realtimeAvailable else {
            await attemptFallback(sessionID: sessionID)
            return
        }
        do {
            if !updated.commitSent {
                session?.commitSent = true
                try await updated.client.commit()
            }
        } catch is CancellationError {
            return
        } catch {
            await loseRealtime(sessionID: sessionID)
            await attemptFallback(sessionID: sessionID)
            return
        }
        guard session?.id == sessionID, session?.terminalWon == false else { return }
        do {
            try await waitForFinal(sessionID: sessionID)
        } catch is CancellationError {
            return
        } catch {
            await loseRealtime(sessionID: sessionID)
            await attemptFallback(sessionID: sessionID)
        }
    }

    private func waitForFinal(sessionID: UUID) async throws {
        guard session?.id == sessionID else { throw CancellationError() }
        session?.finalTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.finalTimeoutSeconds ?? Self.finalTimeoutSeconds))
                await self?.finalTranscriptTimedOut(sessionID: sessionID)
            } catch {}
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard session?.id == sessionID, session?.terminalWon == false else {
                continuation.resume(throwing: CancellationError())
                return
            }
            session?.finalWaiter = continuation
        }
    }

    private func finalTranscriptTimedOut(sessionID: UUID) async {
        guard session?.id == sessionID, session?.terminalWon == false else { return }
        session?.finalWaiter?.resume(throwing: RealtimeTranscriptionError.finalTranscriptTimedOut)
        session?.finalWaiter = nil
        await loseRealtime(sessionID: sessionID)
        await attemptFallback(sessionID: sessionID)
    }

    private func resumeFinalWaiter(sessionID: UUID) {
        guard session?.id == sessionID else { return }
        session?.finalTimeoutTask?.cancel()
        session?.finalTimeoutTask = nil
        session?.finalWaiter?.resume()
        session?.finalWaiter = nil
    }

    private func loseRealtime(sessionID: UUID) async {
        guard let current = session,
              current.id == sessionID,
              current.realtimeAvailable,
              !current.terminalWon
        else { return }
        session?.realtimeAvailable = false
        session?.earlyAudio.removeAll(keepingCapacity: false)
        session?.receiveTask?.cancel()
        session?.finalTimeoutTask?.cancel()
        session?.finalTimeoutTask = nil
        session?.finalWaiter?.resume(throwing: RealtimeTranscriptionError.connectionClosed)
        session?.finalWaiter = nil
        await closeRealtime(sessionID: sessionID)
        guard session?.id == sessionID, session?.terminalWon == false else { return }
        if session?.releaseRequested == true, session?.recordingURL != nil {
            await attemptFallback(sessionID: sessionID)
        } else if session?.releaseRequested == false {
            publish(.recordingForFallback)
        }
    }

    private func attemptFallback(sessionID: UUID) async {
        guard let current = session,
              current.id == sessionID,
              current.releaseRequested,
              !current.terminalWon,
              !current.fallbackAttempted,
              let recordingURL = current.recordingURL
        else { return }
        session?.fallbackAttempted = true
        publish(.recovering)
        await closeRealtime(sessionID: sessionID)
        do {
            let text = try await transcribeFallback(recordingURL, current.config)
            guard session?.id == sessionID else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                await finish(sessionID: sessionID, outcome: .failure("dictation.error.noSpeech"))
            } else {
                await finish(sessionID: sessionID, outcome: .success(trimmed))
            }
        } catch is CancellationError {
            return
        } catch {
            guard session?.id == sessionID else { return }
            await finish(sessionID: sessionID, outcome: .failure(errorKey(error)))
        }
    }

    private enum Outcome {
        case success(String)
        case failure(String)
    }

    private func finish(sessionID: UUID, outcome: Outcome) async {
        guard var current = session, current.id == sessionID, !current.terminalWon else { return }
        current.terminalWon = true
        session = current
        current.finalTimeoutTask?.cancel()
        current.finalWaiter?.resume(throwing: CancellationError())
        current.receiveTask?.cancel()
        current.connectTask?.cancel()

        switch outcome {
        case let .success(text):
            do {
                try current.transaction.commitFinal(text)
                publish(.complete)
            } catch {
                current.transaction.restore()
                publish(.failed(errorKey(error)))
            }
        case let .failure(key):
            current.transaction.restore()
            publish(.failed(key))
        }

        if current.captureStarted && !current.captureStopped {
            await audioCapture.cancel()
        }
        await closeRealtime(sessionID: sessionID)
        guard var owned = session, owned.id == sessionID else { return }
        let recordingURL = owned.recordingURL
        owned.recordingURL = nil
        session = nil
        if let recordingURL {
            deleteTemporaryFile(recordingURL)
        }
    }

    private func closeRealtime(sessionID: UUID) async {
        guard var current = session, current.id == sessionID, !current.clientClosed else { return }
        current.clientClosed = true
        session = current
        await current.client.close()
    }

    private func publish(_ phase: Phase) {
        self.phase = phase
        phaseHandler(phase)
    }

    private static func defaultErrorKey(_ error: Error) -> String {
        switch error {
        case RealtimeTranscriptionError.missingAPIKey:
            "dictation.error.missingAPIKey"
        case SpeechTranscriptionError.emptyResponse:
            "dictation.error.noSpeech"
        case AudioRecorder.AudioRecorderError.microphonePermissionDenied:
            "dictation.error.microphonePermission"
        default:
            "dictation.error.fallback"
        }
    }
}
