import Foundation
import XCTest
@testable import Inklet
@testable import InkletCore

@MainActor
final class WritingDictationCoordinatorTests: XCTestCase {
    func testBeginHoldCreatesTransactionStartsCaptureAndPublishesListeningAfterConnection() async {
        let harness = DictationHarness()
        await harness.subject.beginHold()
        XCTAssertEqual(harness.transactionBeginCount, 1)
        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertEqual(harness.phases.first, .connecting)

        harness.client.completeConnection()
        await harness.client.waitUntilReceiveStarts()
        XCTAssertEqual(harness.subject.phase, .listening)
        XCTAssertTrue(harness.subject.isActive)
        await harness.subject.cancelAndWait()
    }

    func testInvalidPreflightDoesNotRequestMicrophoneOrCreateTransaction() async {
        let harness = DictationHarness(clientFactoryError: RealtimeTranscriptionError.missingAPIKey)
        await harness.subject.beginHold()
        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertEqual(harness.transactionBeginCount, 0)
        XCTAssertEqual(harness.subject.phase, .failed("dictation.error.missingAPIKey"))
    }

    func testReleaseStopsSamplesDrainsAppendQueueThenCommitsExactlyOnce() async {
        let harness = DictationHarness()
        await harness.startListening()
        harness.client.blockNextAppend()
        harness.capture.yield(Data([1]))
        await harness.client.waitUntilAppendStarts()

        await harness.subject.endHold()
        await harness.capture.waitUntilStopWasCalled()
        XCTAssertFalse(harness.client.didCommit)
        harness.client.resumeAppend()
        await harness.client.waitUntilCommitted()
        XCTAssertEqual(harness.client.operations, ["append:1", "commit"])

        harness.client.send(.completed(eventID: "final", sequence: nil, itemID: "item", contentIndex: 0, transcript: "done"))
        await harness.transaction.waitUntilCommitted()
        XCTAssertEqual(harness.transaction.committed, ["done"])
        XCTAssertEqual(harness.client.commitCount, 1)
        XCTAssertFalse(harness.client.appendedAfterCommit)
    }

    func testReleaseDuringConnectionFallsBackOnlyAfterFileFinalizes() async {
        let harness = DictationHarness()
        await harness.subject.beginHold()
        await harness.subject.endHold()
        await harness.capture.waitUntilStopWasCalled()
        XCTAssertTrue(harness.fallbackRequests.isEmpty)

        harness.client.failConnection(with: RealtimeTranscriptionError.connectionTimedOut)
        await harness.waitUntilFallbackStarts()
        XCTAssertEqual(harness.fallbackRequests, [harness.capture.recordingURL])
        harness.resumeFallback()
        await harness.transaction.waitUntilCommitted()
        XCTAssertEqual(harness.transaction.committed, ["fallback"])
    }

    func testEarlyAudioOverflowKeepsRecordingUntilReleaseThenFallsBack() async {
        let harness = DictationHarness()
        await harness.subject.beginHold()
        harness.capture.yield(Data(repeating: 0, count: 240_001))
        await harness.client.waitUntilClosed()
        XCTAssertEqual(harness.subject.phase, .recordingForFallback)
        XCTAssertTrue(harness.fallbackRequests.isEmpty)

        await harness.subject.endHold()
        await harness.waitUntilFallbackStarts()
        harness.resumeFallback()
        await harness.transaction.waitUntilCommitted()
        XCTAssertEqual(harness.transaction.committed, ["fallback"])
    }

    func testDeltaPublishesCumulativeProvisionalText() async {
        let harness = DictationHarness()
        await harness.startListening()
        harness.client.send(.delta(eventID: "first", sequence: 1, itemID: "item", contentIndex: 0, text: "hello"))
        await harness.transaction.waitUntilProvisionalCount(1)
        harness.client.send(.delta(eventID: "second", sequence: 2, itemID: "item", contentIndex: 0, text: " world"))
        await harness.transaction.waitUntilProvisionalCount(2)
        XCTAssertEqual(harness.transaction.provisional, ["hello", "hello world"])
        await harness.subject.cancelAndWait()
    }

    func testSuccessfulEmptyRealtimeCompletionRestoresWithoutFallback() async {
        let harness = DictationHarness()
        await harness.startListening()
        await harness.subject.endHold()
        await harness.client.waitUntilCommitted()
        harness.client.send(.completed(eventID: "final", sequence: nil, itemID: "item", contentIndex: 0, transcript: "   "))
        await harness.transaction.waitUntilRestored()
        XCTAssertEqual(harness.transaction.restoreCount, 1)
        XCTAssertTrue(harness.fallbackRequests.isEmpty)
        XCTAssertEqual(harness.subject.phase, .failed("dictation.error.noSpeech"))
    }

    func testReceiveFailureWhileHeldFallsBackOnlyAfterRelease() async {
        let harness = DictationHarness(fallbackText: "fallback final")
        await harness.startListening()
        harness.client.failReceive(with: RealtimeTranscriptionError.connectionClosed)
        await harness.client.waitUntilClosed()
        XCTAssertEqual(harness.subject.phase, .recordingForFallback)
        XCTAssertTrue(harness.fallbackRequests.isEmpty)

        await harness.subject.endHold()
        await harness.waitUntilFallbackStarts()
        harness.resumeFallback()
        await harness.transaction.waitUntilCommitted()
        XCTAssertEqual(harness.transaction.committed, ["fallback final"])
        XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
    }

    func testFallbackFailureAndWhitespaceRestoreTransaction() async {
        let failing = DictationHarness(fallbackError: SpeechTranscriptionError.provider("offline"))
        await failing.startListening()
        failing.client.failReceive(with: RealtimeTranscriptionError.connectionClosed)
        await failing.client.waitUntilClosed()
        await failing.subject.endHold()
        await failing.waitUntilFallbackStarts()
        failing.resumeFallback()
        await failing.transaction.waitUntilRestored()
        XCTAssertEqual(failing.transaction.restoreCount, 1)

        let empty = DictationHarness(fallbackText: "  \n")
        await empty.startListening()
        empty.client.failReceive(with: RealtimeTranscriptionError.connectionClosed)
        await empty.client.waitUntilClosed()
        await empty.subject.endHold()
        await empty.waitUntilFallbackStarts()
        empty.resumeFallback()
        await empty.transaction.waitUntilRestored()
        XCTAssertEqual(empty.subject.phase, .failed("dictation.error.noSpeech"))
    }

    func testFirstTerminalWinsAndDuplicateReleaseDoesNotRepeatCommit() async {
        let harness = DictationHarness()
        await harness.startListening()
        await harness.subject.endHold()
        await harness.subject.endHold()
        await harness.client.waitUntilCommitted()
        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.client.commitCount, 1)
        harness.client.send(.completed(eventID: "final", sequence: nil, itemID: "item", contentIndex: 0, transcript: "realtime"))
        await harness.transaction.waitUntilCommitted()
        harness.client.failReceive(with: RealtimeTranscriptionError.connectionClosed)
        XCTAssertEqual(harness.transaction.committed, ["realtime"])
        XCTAssertTrue(harness.fallbackRequests.isEmpty)
    }

    func testFinalTranscriptTimeoutFallsBackAfterCommit() async {
        let harness = DictationHarness(finalTimeoutSeconds: 0)
        await harness.startListening()
        await harness.subject.endHold()
        await harness.client.waitUntilCommitted()
        await harness.waitUntilFallbackStarts()
        harness.resumeFallback()
        await harness.transaction.waitUntilCommitted()

        XCTAssertEqual(harness.client.commitCount, 1)
        XCTAssertEqual(harness.transaction.committed, ["fallback"])
    }

    func testCancelDuringPermissionAndFallbackSuppressesStaleResults() async {
        let permission = DictationHarness()
        permission.capture.blockStart()
        let begin = Task { await permission.subject.beginHold() }
        await permission.capture.waitUntilStartWasCalled()
        await permission.subject.cancelAndWait()
        await begin.value
        XCTAssertTrue(permission.subject.isIdle)
        XCTAssertEqual(permission.transaction.restoreCount, 1)
        XCTAssertEqual(permission.client.closeCount, 1)
        XCTAssertFalse(permission.phases.contains(.listening))

        let fallback = DictationHarness()
        await fallback.startListening()
        fallback.client.failReceive(with: RealtimeTranscriptionError.connectionClosed)
        await fallback.client.waitUntilClosed()
        await fallback.subject.endHold()
        await fallback.waitUntilFallbackStarts()
        await fallback.subject.cancelAndWait()
        fallback.resumeFallback()
        XCTAssertTrue(fallback.subject.isIdle)
        XCTAssertEqual(fallback.transaction.restoreCount, 1)
        XCTAssertTrue(fallback.transaction.committed.isEmpty)
    }

    func testCaptureAndStopFailureRestoreCloseAndNeverFallback() async {
        let capture = DictationHarness()
        capture.capture.startError = AudioRecorder.AudioRecorderError.recordingUnavailable
        await capture.subject.beginHold()
        XCTAssertEqual(capture.transaction.restoreCount, 1)
        XCTAssertEqual(capture.client.closeCount, 1)
        XCTAssertTrue(capture.fallbackRequests.isEmpty)

        let stop = DictationHarness()
        await stop.startListening()
        stop.capture.stopError = AudioRecorder.AudioRecorderError.recordingUnavailable
        await stop.subject.endHold()
        await stop.transaction.waitUntilRestored()
        XCTAssertEqual(stop.transaction.restoreCount, 1)
        XCTAssertEqual(stop.client.closeCount, 1)
    }
}

@MainActor
private final class DictationHarness {
    let capture = FakeDictationCapture()
    let client = FakeRealtimeClient()
    let transaction = FakeDictationTransaction()
    private(set) var transactionBeginCount = 0
    private(set) var fallbackRequests: [URL] = []
    private(set) var deletedURLs: [URL] = []
    private(set) var phases: [WritingDictationCoordinator.Phase] = []
    private let clientFactoryError: Error?
    private let fallbackText: String
    private let fallbackError: Error?
    private let finalTimeoutSeconds: TimeInterval
    private var fallbackBlocked = true
    private var fallbackContinuation: CheckedContinuation<Void, Never>?
    private var fallbackStartWaiters: [CheckedContinuation<Void, Never>] = []

    lazy var subject = WritingDictationCoordinator(
        configProvider: { VoiceInputConfig.defaultConfig() },
        audioCapture: capture,
        makeRealtimeClient: { [weak self] in
            guard let self else { throw CancellationError() }
            if let clientFactoryError { throw clientFactoryError }
            return client
        },
        beginTransaction: { [weak self] in
            guard let self else { return nil }
            transactionBeginCount += 1
            return transaction
        },
        transcribeFallback: { [weak self] url, _ in
            guard let self else { throw CancellationError() }
            fallbackRequests.append(url)
            let waiters = fallbackStartWaiters
            fallbackStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if fallbackBlocked {
                await withCheckedContinuation { fallbackContinuation = $0 }
            }
            if let fallbackError { throw fallbackError }
            return fallbackText
        },
        deleteTemporaryFile: { [weak self] url in self?.deletedURLs.append(url) },
        phaseHandler: { [weak self] in self?.phases.append($0) },
        errorKey: { error in
            error as? RealtimeTranscriptionError == .missingAPIKey
                ? "dictation.error.missingAPIKey"
                : "dictation.error.fallback"
        },
        finalTimeoutSeconds: finalTimeoutSeconds
    )

    init(
        clientFactoryError: Error? = nil,
        fallbackText: String = "fallback",
        fallbackError: Error? = nil,
        finalTimeoutSeconds: TimeInterval = 15
    ) {
        self.clientFactoryError = clientFactoryError
        self.fallbackText = fallbackText
        self.fallbackError = fallbackError
        self.finalTimeoutSeconds = finalTimeoutSeconds
    }

    func startListening() async {
        await subject.beginHold()
        client.completeConnection()
        await client.waitUntilReceiveStarts()
    }

    func waitUntilFallbackStarts() async {
        if !fallbackRequests.isEmpty { return }
        await withCheckedContinuation { fallbackStartWaiters.append($0) }
    }

    func resumeFallback() {
        fallbackBlocked = false
        fallbackContinuation?.resume()
        fallbackContinuation = nil
    }
}

@MainActor
private final class FakeDictationCapture: DictationAudioCapturing {
    let recordingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationHarness-\(UUID().uuidString).m4a")
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var createdURLs: [URL] = []
    var startError: Error?
    var stopError: Error?
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var startBlocked = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func startStreaming(microphoneDeviceID: String?) async throws -> AsyncThrowingStream<Data, Error> {
        startCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if startBlocked {
            await withCheckedContinuation { startContinuation = $0 }
        }
        if let startError { throw startError }
        createdURLs = [recordingURL]
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        let stream = AsyncThrowingStream<Data, Error> { captured = $0 }
        streamContinuation = captured
        return stream
    }

    func stop() async throws -> URL {
        stopCount += 1
        streamContinuation?.finish()
        streamContinuation = nil
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let stopError { throw stopError }
        return recordingURL
    }

    func cancel() async {
        cancelCount += 1
        startBlocked = false
        startContinuation?.resume()
        startContinuation = nil
        streamContinuation?.finish()
        streamContinuation = nil
    }

    func yield(_ data: Data) { streamContinuation?.yield(data) }
    func blockStart() { startBlocked = true }
    func waitUntilStartWasCalled() async {
        if startCount > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func waitUntilStopWasCalled() async {
        if stopCount > 0 { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }
}

@MainActor
private final class FakeDictationTransaction: DictationEditorTransacting {
    private(set) var provisional: [String] = []
    private(set) var committed: [String] = []
    private(set) var restoreCount = 0
    private var provisionalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var committedWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoreWaiters: [CheckedContinuation<Void, Never>] = []

    func replaceProvisional(with cumulativeText: String) throws {
        provisional.append(cumulativeText)
        let ready = provisionalWaiters.filter { provisional.count >= $0.0 }
        provisionalWaiters.removeAll { provisional.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
    func commitFinal(_ text: String) throws {
        committed.append(text)
        let waiters = committedWaiters
        committedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    func restore() {
        restoreCount += 1
        let waiters = restoreWaiters
        restoreWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    func waitUntilProvisionalCount(_ count: Int) async {
        if provisional.count >= count { return }
        await withCheckedContinuation { provisionalWaiters.append((count, $0)) }
    }
    func waitUntilCommitted() async {
        if !committed.isEmpty { return }
        await withCheckedContinuation { committedWaiters.append($0) }
    }
    func waitUntilRestored() async {
        if restoreCount > 0 { return }
        await withCheckedContinuation { restoreWaiters.append($0) }
    }
}

@MainActor
private final class FakeRealtimeClient: RealtimeTranscriptionClient, @unchecked Sendable {
    private(set) var operations: [String] = []
    private(set) var commitCount = 0
    private(set) var closeCount = 0
    private(set) var appendedAfterCommit = false
    var didCommit: Bool { commitCount > 0 }

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var pendingConnectionResult: Result<Void, Error>?
    private var eventQueue: [Result<RealtimeTranscriptionEvent, Error>] = []
    private var eventWaiter: CheckedContinuation<RealtimeTranscriptionEvent, Error>?
    private var receiveStarted = false
    private var receiveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldBlockNextAppend = false
    private var appendContinuation: CheckedContinuation<Void, Never>?
    private var appendStarted = false
    private var appendStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    func connect(timeoutSeconds: TimeInterval) async throws {
        if let pendingConnectionResult {
            self.pendingConnectionResult = nil
            return try pendingConnectionResult.get()
        }
        try await withCheckedThrowingContinuation { connectContinuation = $0 }
    }
    func completeConnection() { resumeConnection(with: .success(())) }
    func failConnection(with error: Error) { resumeConnection(with: .failure(error)) }

    func appendPCM16(_ data: Data) async throws {
        if didCommit { appendedAfterCommit = true }
        appendStarted = true
        let waiters = appendStartWaiters
        appendStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if shouldBlockNextAppend {
            shouldBlockNextAppend = false
            await withCheckedContinuation { appendContinuation = $0 }
        }
        operations.append("append:\(data.count)")
    }
    func blockNextAppend() { shouldBlockNextAppend = true }
    func resumeAppend() {
        appendContinuation?.resume()
        appendContinuation = nil
    }

    func commit() async throws {
        commitCount += 1
        operations.append("commit")
        let waiters = commitWaiters
        commitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func nextEvent() async throws -> RealtimeTranscriptionEvent {
        receiveStarted = true
        let waiters = receiveStartWaiters
        receiveStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !eventQueue.isEmpty { return try eventQueue.removeFirst().get() }
        return try await withCheckedThrowingContinuation { eventWaiter = $0 }
    }
    func send(_ event: RealtimeTranscriptionEvent) { enqueue(.success(event)) }
    func failReceive(with error: Error) { enqueue(.failure(error)) }

    func close() async {
        closeCount += 1
        connectContinuation?.resume(throwing: CancellationError())
        connectContinuation = nil
        appendContinuation?.resume()
        appendContinuation = nil
        eventWaiter?.resume(throwing: RealtimeTranscriptionError.connectionClosed)
        eventWaiter = nil
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilReceiveStarts() async {
        if receiveStarted { return }
        await withCheckedContinuation { receiveStartWaiters.append($0) }
    }
    func waitUntilAppendStarts() async {
        if appendStarted { return }
        await withCheckedContinuation { appendStartWaiters.append($0) }
    }
    func waitUntilCommitted() async {
        if didCommit { return }
        await withCheckedContinuation { commitWaiters.append($0) }
    }
    func waitUntilClosed() async {
        if closeCount > 0 { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    private func resumeConnection(with result: Result<Void, Error>) {
        if let connectContinuation {
            self.connectContinuation = nil
            connectContinuation.resume(with: result)
        } else {
            pendingConnectionResult = result
        }
    }
    private func enqueue(_ result: Result<RealtimeTranscriptionEvent, Error>) {
        if let eventWaiter {
            self.eventWaiter = nil
            eventWaiter.resume(with: result)
        } else {
            eventQueue.append(result)
        }
    }
}
