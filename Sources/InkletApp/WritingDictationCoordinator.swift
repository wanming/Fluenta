import Foundation
import InkletCore

@MainActor
protocol WritingDictationFinalTimeoutWaiting: AnyObject {
    func wait(seconds: TimeInterval) async throws
}

@MainActor
private final class TaskWritingDictationFinalTimeoutWaiter: WritingDictationFinalTimeoutWaiting {
    func wait(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

@MainActor
protocol WritingDictationTerminalHandoffWaiting: AnyObject {
    func wait() async
}

@MainActor
private final class TaskWritingDictationTerminalHandoffWaiter:
    WritingDictationTerminalHandoffWaiting
{
    func wait() async {
        await Task.yield()
    }
}

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

    private enum OperationKind: Equatable {
        case preflightClose
        case captureStart
        case connect
        case frames
        case receive
        case finalize
        case commitAndFinalWait
        case finalTimeout
        case fallback
        case terminalCleanup
    }

    private struct Operation {
        let sessionID: UUID?
        let kind: OperationKind
        var task: Task<Void, Never>?
    }

    private struct OperationDrainWaiter {
        let excluding: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct Session {
        let id: UUID
        let config: VoiceInputConfig
        let transaction: any DictationEditorTransacting
        let client: any RealtimeTranscriptionClient
        var accumulator = RealtimeTranscriptAccumulator()
        var earlyAudio = Data()
        var captureStartInFlight = false
        var captureStarted = false
        var captureStopped = false
        var captureCancelled = false
        var connectionReady = false
        var realtimeAvailable = true
        var releaseRequested = false
        var commitSent = false
        var fallbackAttempted = false
        var terminalWon = false
        var clientClosed = false
        var temporaryFileDeleted = false
        var recordingURL: URL?
        var terminalPhase: Phase?
        var frameOperationID: UUID?
        var connectOperationID: UUID?
        var receiveOperationID: UUID?
        var finalizeOperationID: UUID?
        var commitOperationID: UUID?
        var timeoutOperationID: UUID?
        var fallbackOperationID: UUID?
        var cleanupOperationID: UUID?
        var finalWaiter: CheckedContinuation<Void, Error>?
    }

    private enum Outcome {
        case success(String)
        case failure(String)
        case cancelled
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
    private let finalTimeoutWaiter: any WritingDictationFinalTimeoutWaiting
    private let terminalHandoffWaiter: any WritingDictationTerminalHandoffWaiting
    private var session: Session?
    private var operations: [UUID: Operation] = [:]
    private var operationDrainWaiters: [OperationDrainWaiter] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupFinishingGeneration: UUID?
    private var cleanupHandoffTask: Task<Void, Never>?

    private(set) var phase: Phase = .idle
    var isActive: Bool { phase.isActive }
    var isIdle: Bool {
        session == nil
            && operations.isEmpty
            && cleanupFinishingGeneration == nil
            && !phase.isActive
    }

    convenience init(
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
        self.init(
            configProvider: configProvider,
            audioCapture: audioCapture,
            makeRealtimeClient: makeRealtimeClient,
            beginTransaction: beginTransaction,
            transcribeFallback: transcribeFallback,
            deleteTemporaryFile: deleteTemporaryFile,
            phaseHandler: phaseHandler,
            errorKey: errorKey,
            finalTimeoutSeconds: finalTimeoutSeconds,
            finalTimeoutWaiter: TaskWritingDictationFinalTimeoutWaiter(),
            terminalHandoffWaiter: TaskWritingDictationTerminalHandoffWaiter()
        )
    }

    init(
        configProvider: @escaping ConfigProvider,
        audioCapture: any DictationAudioCapturing,
        makeRealtimeClient: @escaping ClientFactory,
        beginTransaction: @escaping BeginTransaction,
        transcribeFallback: @escaping FallbackTranscriber,
        deleteTemporaryFile: @escaping DeleteTemporaryFile,
        phaseHandler: @escaping PhaseHandler,
        errorKey: @escaping ErrorKey,
        finalTimeoutSeconds: TimeInterval,
        finalTimeoutWaiter: any WritingDictationFinalTimeoutWaiting,
        terminalHandoffWaiter: any WritingDictationTerminalHandoffWaiting
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
        self.finalTimeoutWaiter = finalTimeoutWaiter
        self.terminalHandoffWaiter = terminalHandoffWaiter
    }

    func beginHold() async {
        guard session == nil,
              operations.isEmpty,
              cleanupFinishingGeneration == nil
        else { return }

        let client: any RealtimeTranscriptionClient
        do {
            client = try makeRealtimeClient()
        } catch {
            publish(.failed(errorKey(error)))
            return
        }

        guard let transaction = beginTransaction() else {
            let operationID = registerOperation(sessionID: nil, kind: .preflightClose)
            await client.close()
            completeOperation(operationID)
            publish(.failed("dictation.error.editorUnavailable"))
            return
        }

        let sessionID = UUID()
        let config = configProvider()
        session = Session(
            id: sessionID,
            config: config,
            transaction: transaction,
            client: client
        )
        publish(.connecting)

        let startOperationID = registerOperation(sessionID: sessionID, kind: .captureStart)
        session?.captureStartInFlight = true
        defer { completeOperation(startOperationID) }

        do {
            let stream = try await audioCapture.startStreaming(
                microphoneDeviceID: config.microphoneDeviceID
            )
            session?.captureStartInFlight = false
            guard session?.id == sessionID else {
                await audioCapture.cancel()
                return
            }

            session?.captureStarted = true
            guard session?.terminalWon == false else {
                await cancelCaptureIfNeeded(sessionID: sessionID)
                return
            }

            let frameOperationID = spawnOperation(sessionID: sessionID, kind: .frames) {
                coordinator, _ in
                await coordinator.consumeFrames(stream, sessionID: sessionID)
            }
            session?.frameOperationID = frameOperationID

            let connectOperationID = spawnOperation(sessionID: sessionID, kind: .connect) {
                coordinator, _ in
                await coordinator.connect(sessionID: sessionID)
            }
            session?.connectOperationID = connectOperationID
        } catch let error as CancellationError {
            session?.captureStartInFlight = false
            guard session?.id == sessionID, session?.terminalWon == false else { return }
            winTerminal(
                sessionID: sessionID,
                outcome: Task.isCancelled ? .cancelled : .failure(errorKey(error))
            )
        } catch {
            session?.captureStartInFlight = false
            guard session?.id == sessionID, session?.terminalWon == false else { return }
            winTerminal(sessionID: sessionID, outcome: .failure(errorKey(error)))
        }
    }

    func endHold() async {
        guard let current = session,
              !current.terminalWon,
              !current.releaseRequested
        else { return }

        session?.releaseRequested = true
        publish(.finalizing)
        guard current.captureStarted else {
            winTerminal(sessionID: current.id, outcome: .cancelled)
            return
        }
        startFinalization(sessionID: current.id)
    }

    func cancel() async {
        guard let current = session else { return }
        winTerminal(sessionID: current.id, outcome: .cancelled)
    }

    func cancelAndWait() async {
        await cancel()
        guard !isTrulyIdle else { return }
        await withCheckedContinuation { continuation in
            guard !isTrulyIdle else {
                continuation.resume()
                return
            }
            idleWaiters.append(continuation)
        }
    }

    private var isTrulyIdle: Bool {
        session == nil && operations.isEmpty && cleanupFinishingGeneration == nil
    }

    private func connect(sessionID: UUID) async {
        guard let current = session,
              current.id == sessionID,
              !current.terminalWon
        else { return }
        do {
            try await current.client.connect(timeoutSeconds: Self.connectionTimeoutSeconds)
            guard !Task.isCancelled else { return }
            await handleConnected(sessionID: sessionID)
        } catch is CancellationError {
            guard !shouldIgnoreCancellation(sessionID: sessionID) else { return }
            await loseRealtime(sessionID: sessionID)
        } catch {
            await loseRealtime(sessionID: sessionID)
        }
    }

    private func handleConnected(sessionID: UUID) async {
        while true {
            guard let current = session,
                  current.id == sessionID,
                  current.realtimeAvailable,
                  !current.terminalWon
            else { return }

            let pending = current.earlyAudio
            if pending.isEmpty {
                session?.connectionReady = true
                break
            }
            session?.earlyAudio.removeAll(keepingCapacity: false)
            do {
                try await current.client.appendPCM16(pending)
            } catch is CancellationError {
                guard !shouldIgnoreCancellation(sessionID: sessionID) else { return }
                await loseRealtime(sessionID: sessionID)
                return
            } catch {
                await loseRealtime(sessionID: sessionID)
                return
            }
        }

        guard let current = session,
              current.id == sessionID,
              current.realtimeAvailable,
              !current.terminalWon
        else { return }
        if !current.releaseRequested {
            publish(.listening)
        }
        let receiveOperationID = spawnOperation(sessionID: sessionID, kind: .receive) {
            coordinator, _ in
            await coordinator.receiveEvents(sessionID: sessionID)
        }
        session?.receiveOperationID = receiveOperationID
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
            guard !shouldIgnoreCancellation(sessionID: sessionID) else { return }
            await loseRealtime(sessionID: sessionID)
        } catch {
            await loseRealtime(sessionID: sessionID)
        }
    }

    private func acceptFrame(_ data: Data, sessionID: UUID) async {
        guard !data.isEmpty,
              let current = session,
              current.id == sessionID,
              !current.terminalWon,
              current.realtimeAvailable
        else { return }

        if !current.connectionReady {
            guard data.count <= Self.earlyAudioLimitBytes,
                  current.earlyAudio.count <= Self.earlyAudioLimitBytes - data.count
            else {
                await loseRealtime(sessionID: sessionID)
                return
            }
            session?.earlyAudio.append(data)
            return
        }

        do {
            try await current.client.appendPCM16(data)
        } catch is CancellationError {
            guard !shouldIgnoreCancellation(sessionID: sessionID) else { return }
            await loseRealtime(sessionID: sessionID)
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
                guard let updated = session,
                      updated.id == sessionID,
                      updated.realtimeAvailable,
                      !updated.terminalWon
                else { return }

                switch session?.accumulator.accept(event) {
                case let .provisional(text):
                    do {
                        try updated.transaction.replaceProvisional(with: text)
                    } catch {
                        winTerminal(sessionID: sessionID, outcome: .failure(errorKey(error)))
                        return
                    }
                case let .final(text):
                    resumeFinalWaiter(sessionID: sessionID)
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        winTerminal(
                            sessionID: sessionID,
                            outcome: .failure("dictation.error.noSpeech")
                        )
                    } else {
                        winTerminal(sessionID: sessionID, outcome: .success(text))
                    }
                    return
                case .ignored, .none:
                    continue
                }
            } catch is CancellationError {
                guard !shouldIgnoreCancellation(sessionID: sessionID) else { return }
                await loseRealtime(sessionID: sessionID)
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
              current.finalizeOperationID == nil,
              !current.terminalWon
        else { return }
        let operationID = spawnOperation(sessionID: sessionID, kind: .finalize) {
            coordinator, _ in
            await coordinator.finalize(sessionID: sessionID)
        }
        session?.finalizeOperationID = operationID
    }

    private func finalize(sessionID: UUID) async {
        guard session?.id == sessionID, session?.terminalWon == false else { return }
        let recordingURL: URL
        do {
            recordingURL = try await audioCapture.stop()
        } catch let error as CancellationError {
            guard session?.id == sessionID, session?.terminalWon == false else { return }
            winTerminal(sessionID: sessionID, outcome: .failure(errorKey(error)))
            return
        } catch {
            guard session?.id == sessionID, session?.terminalWon == false else { return }
            winTerminal(sessionID: sessionID, outcome: .failure(errorKey(error)))
            return
        }

        guard session?.id == sessionID else {
            deleteTemporaryFile(recordingURL)
            return
        }
        session?.captureStopped = true
        session?.recordingURL = recordingURL
        guard session?.terminalWon == false else { return }

        let frameOperationID = session?.frameOperationID
        let connectOperationID = session?.connectOperationID
        await waitForOperation(frameOperationID)
        await waitForOperation(connectOperationID)

        guard let current = session,
              current.id == sessionID,
              !current.terminalWon
        else { return }
        guard current.realtimeAvailable, current.connectionReady else {
            startFallback(sessionID: sessionID)
            return
        }
        startCommitAndFinalWait(sessionID: sessionID)
    }

    private func startCommitAndFinalWait(sessionID: UUID) {
        guard let current = session,
              current.id == sessionID,
              current.commitOperationID == nil,
              !current.terminalWon
        else { return }
        let operationID = spawnOperation(sessionID: sessionID, kind: .commitAndFinalWait) {
            coordinator, _ in
            await coordinator.commitAndWaitForFinal(sessionID: sessionID)
        }
        session?.commitOperationID = operationID
    }

    private func commitAndWaitForFinal(sessionID: UUID) async {
        guard let current = session,
              current.id == sessionID,
              !current.terminalWon
        else { return }
        do {
            if !current.commitSent {
                session?.commitSent = true
                try await current.client.commit()
            }
        } catch is CancellationError {
            guard !shouldIgnoreCancellation(sessionID: sessionID) else { return }
            await loseRealtime(sessionID: sessionID)
            startFallback(sessionID: sessionID)
            return
        } catch {
            await loseRealtime(sessionID: sessionID)
            startFallback(sessionID: sessionID)
            return
        }

        guard session?.id == sessionID, session?.terminalWon == false else { return }
        do {
            try await waitForFinal(sessionID: sessionID)
        } catch is CancellationError {
            guard !shouldIgnoreCancellation(sessionID: sessionID) else { return }
            await loseRealtime(sessionID: sessionID)
            startFallback(sessionID: sessionID)
        } catch {
            await loseRealtime(sessionID: sessionID)
            startFallback(sessionID: sessionID)
        }
    }

    private func waitForFinal(sessionID: UUID) async throws {
        guard session?.id == sessionID, session?.terminalWon == false else {
            throw CancellationError()
        }

        let timeoutOperationID = spawnOperation(sessionID: sessionID, kind: .finalTimeout) {
            coordinator, _ in
            do {
                try await coordinator.finalTimeoutWaiter.wait(
                    seconds: coordinator.finalTimeoutSeconds
                )
                guard !Task.isCancelled else { return }
                coordinator.finalTranscriptTimedOut(sessionID: sessionID)
            } catch is CancellationError {
                guard !coordinator.shouldIgnoreCancellation(sessionID: sessionID) else { return }
                coordinator.finalTranscriptTimedOut(sessionID: sessionID)
            } catch {
                guard coordinator.session?.id == sessionID,
                      coordinator.session?.terminalWon == false
                else { return }
                coordinator.finalTranscriptTimedOut(sessionID: sessionID)
            }
        }
        session?.timeoutOperationID = timeoutOperationID

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            guard session?.id == sessionID, session?.terminalWon == false else {
                continuation.resume(throwing: CancellationError())
                return
            }
            session?.finalWaiter = continuation
        }
    }

    private func finalTranscriptTimedOut(sessionID: UUID) {
        _ = latchRealtimeUnavailable(
            sessionID: sessionID,
            finalWaiterError: RealtimeTranscriptionError.finalTranscriptTimedOut,
            cancelTimeoutOperation: false
        )
    }

    private func resumeFinalWaiter(sessionID: UUID) {
        guard session?.id == sessionID else { return }
        cancelOperation(session?.timeoutOperationID)
        session?.finalWaiter?.resume()
        session?.finalWaiter = nil
    }

    private func loseRealtime(sessionID: UUID) async {
        guard let current = session,
              current.id == sessionID,
              !current.terminalWon
        else { return }

        let newlyLost = current.realtimeAvailable
        if newlyLost {
            _ = latchRealtimeUnavailable(
                sessionID: sessionID,
                finalWaiterError: RealtimeTranscriptionError.connectionClosed,
                cancelTimeoutOperation: true
            )
        }
        await closeRealtime(sessionID: sessionID)

        guard let updated = session,
              updated.id == sessionID,
              !updated.terminalWon
        else { return }
        if updated.releaseRequested, updated.recordingURL != nil {
            startFallback(sessionID: sessionID)
        } else if newlyLost, !updated.releaseRequested {
            publish(.recordingForFallback)
        }
    }

    @discardableResult
    private func latchRealtimeUnavailable(
        sessionID: UUID,
        finalWaiterError: Error,
        cancelTimeoutOperation: Bool
    ) -> Bool {
        guard let current = session,
              current.id == sessionID,
              current.realtimeAvailable,
              !current.terminalWon
        else { return false }

        session?.realtimeAvailable = false
        session?.earlyAudio.removeAll(keepingCapacity: false)
        cancelOperation(current.connectOperationID)
        cancelOperation(current.receiveOperationID)
        if cancelTimeoutOperation {
            cancelOperation(current.timeoutOperationID)
        }
        current.finalWaiter?.resume(throwing: finalWaiterError)
        session?.finalWaiter = nil
        return true
    }

    private func startFallback(sessionID: UUID) {
        guard let current = session,
              current.id == sessionID,
              current.releaseRequested,
              !current.terminalWon,
              !current.fallbackAttempted
        else { return }

        guard let recordingURL = current.recordingURL,
              isReadableNonemptyRecording(at: recordingURL)
        else {
            winTerminal(
                sessionID: sessionID,
                outcome: .failure("dictation.error.noSpeech")
            )
            return
        }

        session?.fallbackAttempted = true
        publish(.recovering)
        let operationID = spawnOperation(sessionID: sessionID, kind: .fallback) {
            coordinator, _ in
            await coordinator.runFallback(
                recordingURL: recordingURL,
                config: current.config,
                sessionID: sessionID
            )
        }
        session?.fallbackOperationID = operationID
    }

    private func isReadableNonemptyRecording(at recordingURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: recordingURL.path
        ),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let fileSize = attributes[.size] as? NSNumber,
        fileSize.uint64Value > 0,
        fileManager.isReadableFile(atPath: recordingURL.path)
        else { return false }
        return true
    }

    private func runFallback(
        recordingURL: URL,
        config: VoiceInputConfig,
        sessionID: UUID
    ) async {
        await closeRealtime(sessionID: sessionID)
        guard session?.id == sessionID, session?.terminalWon == false else { return }
        do {
            let text = try await transcribeFallback(recordingURL, config)
            guard session?.id == sessionID,
                  session?.terminalWon == false,
                  !Task.isCancelled
            else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                winTerminal(
                    sessionID: sessionID,
                    outcome: .failure("dictation.error.noSpeech")
                )
            } else {
                winTerminal(sessionID: sessionID, outcome: .success(trimmed))
            }
        } catch let error as CancellationError {
            guard session?.id == sessionID, session?.terminalWon == false else { return }
            winTerminal(sessionID: sessionID, outcome: .failure(errorKey(error)))
        } catch {
            guard session?.id == sessionID, session?.terminalWon == false else { return }
            winTerminal(sessionID: sessionID, outcome: .failure(errorKey(error)))
        }
    }

    private func winTerminal(sessionID: UUID, outcome: Outcome) {
        guard var current = session,
              current.id == sessionID,
              !current.terminalWon
        else { return }

        current.terminalWon = true
        current.finalWaiter?.resume(throwing: CancellationError())
        current.finalWaiter = nil

        let publishTerminalPhaseImmediately: Bool
        switch outcome {
        case let .success(text):
            do {
                try current.transaction.commitFinal(text)
                current.terminalPhase = .complete
            } catch {
                current.transaction.restore()
                current.terminalPhase = .failed(errorKey(error))
            }
            publishTerminalPhaseImmediately = false
        case let .failure(key):
            current.transaction.restore()
            current.terminalPhase = .failed(key)
            publishTerminalPhaseImmediately = false
        case .cancelled:
            current.transaction.restore()
            current.terminalPhase = .idle
            publishTerminalPhaseImmediately = true
        }
        session = current

        cancelSessionOperations(sessionID: sessionID)
        let cleanupGeneration = UUID()
        cleanupFinishingGeneration = cleanupGeneration
        let cleanupOperationID = spawnOperation(sessionID: sessionID, kind: .terminalCleanup) {
            coordinator, operationID in
            await coordinator.cleanUpTerminalSession(
                sessionID: sessionID,
                cleanupOperationID: operationID
            )
        }
        session?.cleanupOperationID = cleanupOperationID
        guard let cleanupTask = operations[cleanupOperationID]?.task,
              let terminalPhase = current.terminalPhase
        else { return }
        cleanupHandoffTask = Task { @MainActor [weak self] in
            await cleanupTask.value
            await self?.finishTerminalHandoff(
                generation: cleanupGeneration,
                terminalPhase: terminalPhase,
                shouldPublishTerminalPhase: !publishTerminalPhaseImmediately
            )
        }
        if publishTerminalPhaseImmediately {
            publish(terminalPhase)
        }
    }

    private func cleanUpTerminalSession(
        sessionID: UUID,
        cleanupOperationID: UUID
    ) async {
        guard session?.id == sessionID, session?.terminalWon == true else { return }

        if session?.captureStartInFlight == true || session?.captureStarted == true,
           session?.captureStopped == false,
           session?.captureCancelled == false {
            await cancelCaptureIfNeeded(sessionID: sessionID)
        }
        await closeRealtime(sessionID: sessionID)
        await waitForOperations(excluding: cleanupOperationID)

        guard var current = session,
              current.id == sessionID
        else { return }

        if let recordingURL = current.recordingURL, !current.temporaryFileDeleted {
            current.temporaryFileDeleted = true
            current.recordingURL = nil
            session = current
            deleteTemporaryFile(recordingURL)
        }

        session = nil
    }

    private func finishTerminalHandoff(
        generation: UUID,
        terminalPhase: Phase,
        shouldPublishTerminalPhase: Bool
    ) async {
        guard cleanupFinishingGeneration == generation else { return }
        if shouldPublishTerminalPhase {
            publish(terminalPhase)
        }
        await terminalHandoffWaiter.wait()
        guard cleanupFinishingGeneration == generation else { return }
        cleanupFinishingGeneration = nil
        cleanupHandoffTask = nil
        resumeIdleWaitersIfNeeded()
    }

    private func cancelCaptureIfNeeded(sessionID: UUID) async {
        guard var current = session,
              current.id == sessionID,
              current.captureStartInFlight || current.captureStarted,
              !current.captureStopped,
              !current.captureCancelled
        else { return }
        current.captureCancelled = true
        session = current
        await audioCapture.cancel()
    }

    private func closeRealtime(sessionID: UUID) async {
        guard var current = session,
              current.id == sessionID,
              !current.clientClosed
        else { return }
        current.clientClosed = true
        session = current
        await current.client.close()
    }

    private func shouldIgnoreCancellation(sessionID: UUID) -> Bool {
        guard let current = session, current.id == sessionID else { return true }
        return current.terminalWon || Task.isCancelled
    }

    private func registerOperation(sessionID: UUID?, kind: OperationKind) -> UUID {
        let operationID = UUID()
        operations[operationID] = Operation(sessionID: sessionID, kind: kind, task: nil)
        return operationID
    }

    @discardableResult
    private func spawnOperation(
        sessionID: UUID,
        kind: OperationKind,
        operation: @escaping @MainActor (WritingDictationCoordinator, UUID) async -> Void
    ) -> UUID {
        let operationID = registerOperation(sessionID: sessionID, kind: kind)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation(self, operationID)
            self.completeOperation(operationID)
        }
        operations[operationID]?.task = task
        return operationID
    }

    private func cancelSessionOperations(sessionID: UUID) {
        for operation in operations.values where operation.sessionID == sessionID {
            operation.task?.cancel()
        }
    }

    private func cancelOperation(_ operationID: UUID?) {
        guard let operationID else { return }
        operations[operationID]?.task?.cancel()
    }

    private func waitForOperation(_ operationID: UUID?) async {
        guard let operationID, let task = operations[operationID]?.task else { return }
        await task.value
    }

    private func waitForOperations(excluding operationID: UUID) async {
        guard operations.keys.contains(where: { $0 != operationID }) else { return }
        await withCheckedContinuation { continuation in
            guard operations.keys.contains(where: { $0 != operationID }) else {
                continuation.resume()
                return
            }
            operationDrainWaiters.append(
                OperationDrainWaiter(excluding: operationID, continuation: continuation)
            )
        }
    }

    private func completeOperation(_ operationID: UUID) {
        guard operations.removeValue(forKey: operationID) != nil else { return }

        let readyDrainWaiters = operationDrainWaiters.filter { waiter in
            !operations.keys.contains(where: { $0 != waiter.excluding })
        }
        operationDrainWaiters.removeAll { waiter in
            !operations.keys.contains(where: { $0 != waiter.excluding })
        }
        readyDrainWaiters.forEach { $0.continuation.resume() }
        resumeIdleWaitersIfNeeded()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard isTrulyIdle else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
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
