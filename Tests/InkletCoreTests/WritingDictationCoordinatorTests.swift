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

    func testEditorUnavailableClosesClientSilentlyAndNeverRequestsMicrophone() async {
        let harness = DictationHarness(transactionAvailable: false)
        harness.client.blockClose()
        let begin = Task { await harness.subject.beginHold() }
        await harness.client.waitUntilClosed()

        XCTAssertEqual(harness.transactionBeginCount, 1)
        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertTrue(harness.phases.isEmpty)
        XCTAssertEqual(harness.subject.phase, .idle)

        harness.client.resumeClose()
        await begin.value

        XCTAssertEqual(harness.client.closeCount, 1)
        XCTAssertEqual(harness.subject.phase, .idle)
        XCTAssertTrue(harness.phases.isEmpty)
    }

    func testCaptureStartErrorsUseSpecificDictationErrorKeys() async {
        let permission = await phaseForCaptureStartError(.microphonePermissionDenied)
        let noDevice = await phaseForCaptureStartError(.noAudioInputDevice)
        let recording = await phaseForCaptureStartError(.recordingUnavailable)
        let overflow = await phaseForCaptureStartError(.realtimeBufferOverflow)

        XCTAssertEqual(permission, .failed("dictation.error.microphonePermission"))
        XCTAssertEqual(noDevice, .failed("dictation.error.noAudioInputDevice"))
        XCTAssertEqual(recording, .failed("dictation.error.recordingUnavailable"))
        XCTAssertEqual(overflow, .failed("dictation.error.realtimeBufferOverflow"))
    }

    func testRealtimeErrorsUsePhaseSpecificDictationErrorKeys() async {
        let connection = await phaseForClientFactoryError(
            RealtimeTranscriptionError.connectionClosed
        )
        let connectionTimeout = await phaseForClientFactoryError(
            RealtimeTranscriptionError.connectionTimedOut
        )
        let finalTimeout = await phaseForClientFactoryError(
            RealtimeTranscriptionError.finalTranscriptTimedOut
        )

        XCTAssertEqual(connection, .failed("dictation.error.connection"))
        XCTAssertEqual(connectionTimeout, .failed("dictation.error.connectionTimeout"))
        XCTAssertEqual(finalTimeout, .failed("dictation.error.finalTimeout"))
    }

    func testBeginWhileSessionIsActiveIsIgnoredWithoutRestartingCaptureOrTransaction() async {
        let harness = DictationHarness()
        await harness.subject.beginHold()
        await harness.subject.beginHold()

        XCTAssertEqual(harness.transactionBeginCount, 1)
        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertEqual(harness.client.closeCount, 0)
        XCTAssertEqual(harness.subject.phase, .connecting)
        await harness.subject.cancelAndWait()
    }

    func testReleaseStopsSamplesDrainsAppendQueueThenCommitsExactlyOnce() async {
        let harness = DictationHarness()
        await harness.startListening()
        harness.client.blockNextAppend()
        await harness.capture.yield(Data([1]))
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

    func testAudioArrivingDuringEarlyFlushIsFlushedBeforeListeningAndCommit() async {
        let harness = DictationHarness()
        await harness.subject.beginHold()
        harness.client.blockNextAppend()
        await harness.capture.yieldAndWaitUntilAccepted(Data([1]))
        harness.client.completeConnection()
        await harness.client.waitUntilAppendStarts()
        XCTAssertEqual(harness.subject.phase, .connecting)

        harness.client.blockNextAppend()
        await harness.capture.yieldAndWaitUntilAccepted(Data([2, 3]))
        harness.client.resumeAppend()
        await harness.client.waitUntilAppendStarts(2)
        XCTAssertEqual(harness.subject.phase, .connecting)

        harness.client.resumeAppend()
        await harness.client.waitUntilReceiveStarts()
        await harness.subject.endHold()
        await harness.client.waitUntilCommitted()

        XCTAssertEqual(harness.client.operations, ["append:1", "append:2", "commit"])
        harness.client.send(
            .completed(
                eventID: "final",
                sequence: nil,
                itemID: "item",
                contentIndex: 0,
                transcript: "complete"
            )
        )
        await harness.subject.cancelAndWait()
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
        await harness.capture.yield(Data(repeating: 0, count: 240_001))
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

    func testProvisionalEditorFailureRestoresWithoutFallback() async {
        let harness = DictationHarness()
        harness.transaction.provisionalError = DictationEditorTransactionError.editorUnavailable
        await harness.startListening()

        harness.client.send(.delta(eventID: "partial", sequence: nil, itemID: "item", contentIndex: 0, text: "temporary"))
        await harness.transaction.waitUntilRestored()
        await harness.subject.cancelAndWait()

        XCTAssertTrue(harness.fallbackRequests.isEmpty)
        XCTAssertEqual(harness.transaction.restoreCount, 1)
        XCTAssertEqual(harness.client.closeCount, 1)
        XCTAssertEqual(harness.subject.phase, .idle)
        XCTAssertFalse(harness.phases.contains { phase in
            if case .failed = phase { return true }
            return false
        })
    }

    func testSuccessfulEmptyRealtimeCompletionRestoresWithoutFallback() async {
        let harness = DictationHarness()
        await harness.startListening()
        await harness.subject.endHold()
        await harness.client.waitUntilCommitted()
        harness.client.send(.completed(eventID: "final", sequence: nil, itemID: "item", contentIndex: 0, transcript: "   "))
        await harness.transaction.waitUntilRestored()
        await harness.subject.cancelAndWait()
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
        await harness.subject.cancelAndWait()
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
        await failing.subject.cancelAndWait()
        XCTAssertEqual(failing.transaction.restoreCount, 1)

        let empty = DictationHarness(fallbackText: "  \n")
        await empty.startListening()
        empty.client.failReceive(with: RealtimeTranscriptionError.connectionClosed)
        await empty.client.waitUntilClosed()
        await empty.subject.endHold()
        await empty.waitUntilFallbackStarts()
        empty.resumeFallback()
        await empty.transaction.waitUntilRestored()
        await empty.subject.cancelAndWait()
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

    func testDuplicateReleaseAndCancelRestoreCloseAndCancelCaptureExactlyOnce() async {
        let harness = DictationHarness()
        await harness.startListening()

        await harness.subject.cancel()
        await harness.subject.cancel()
        await harness.subject.endHold()
        await harness.subject.cancelAndWait()

        XCTAssertEqual(harness.transaction.restoreCount, 1)
        XCTAssertEqual(harness.client.closeCount, 1)
        XCTAssertEqual(harness.capture.cancelCount, 1)
        XCTAssertEqual(harness.capture.stopCount, 0)
        XCTAssertEqual(harness.subject.phase, .idle)
    }

    func testFinalTranscriptTimeoutFallsBackAfterCommit() async {
        let harness = DictationHarness(manualTimeout: true)
        await harness.startListening()
        await harness.subject.endHold()
        await harness.client.waitUntilCommitted()
        await harness.waitUntilTimeoutStarts()
        harness.resumeTimeout()
        await harness.waitUntilFallbackStarts()
        harness.resumeFallback()
        await harness.transaction.waitUntilCommitted()

        XCTAssertEqual(harness.client.commitCount, 1)
        XCTAssertEqual(harness.transaction.committed, ["fallback"])
    }

    func testTimeoutLatchesRealtimeLossBeforeLateFinalCanWin() async {
        let harness = DictationHarness(manualTimeout: true)
        harness.client.blockNextEvent()
        await harness.startListening()
        await harness.subject.endHold()
        await harness.client.waitUntilCommitted()
        await harness.waitUntilTimeoutStarts()

        harness.client.send(
            .completed(
                eventID: "late-final",
                sequence: nil,
                itemID: "item",
                contentIndex: 0,
                transcript: "late realtime"
            )
        )
        await harness.client.waitUntilNextEventIsBlocked()

        harness.resumeTimeout()
        harness.client.resumeNextEvent()
        let terminalContender = await harness.waitUntilPhase([.recovering, .complete])

        XCTAssertEqual(terminalContender, .recovering)
        if terminalContender == .recovering {
            await harness.waitUntilFallbackStarts()
            harness.resumeFallback()
            await harness.transaction.waitUntilCommitted()
        }
        await harness.subject.cancelAndWait()

        XCTAssertEqual(harness.transaction.committed, ["fallback"])
        XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
    }

    func testCancelAndWaitJoinsBlockedTimeoutTaskBeforeBecomingIdle() async {
        let harness = DictationHarness(manualTimeout: true)
        await harness.startListening()
        await harness.subject.endHold()
        await harness.client.waitUntilCommitted()
        await harness.waitUntilTimeoutStarts()

        var cancelCompleted = false
        let cancel = Task {
            await harness.subject.cancelAndWait()
            cancelCompleted = true
        }
        await harness.transaction.waitUntilRestored()

        XCTAssertFalse(cancelCompleted)
        XCTAssertFalse(harness.subject.isIdle)

        harness.resumeTimeout()
        await cancel.value

        XCTAssertTrue(cancelCompleted)
        XCTAssertTrue(harness.subject.isIdle)
        XCTAssertTrue(harness.fallbackRequests.isEmpty)
        XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
    }

    func testCancelDuringFallbackSuppressesStaleResult() async {
        let fallback = DictationHarness()
        await fallback.startListening()
        fallback.client.failReceive(with: RealtimeTranscriptionError.connectionClosed)
        await fallback.client.waitUntilClosed()
        await fallback.subject.endHold()
        await fallback.waitUntilFallbackStarts()
        var cancelCompleted = false
        let cancel = Task {
            await fallback.subject.cancelAndWait()
            cancelCompleted = true
        }
        await fallback.transaction.waitUntilRestored()

        XCTAssertFalse(cancelCompleted)
        XCTAssertFalse(fallback.subject.isIdle)

        fallback.resumeFallback()
        await cancel.value

        XCTAssertTrue(cancelCompleted)
        XCTAssertTrue(fallback.subject.isIdle)
        XCTAssertEqual(fallback.transaction.restoreCount, 1)
        XCTAssertTrue(fallback.transaction.committed.isEmpty)
    }

    func testReleaseThenCancelDuringBlockedConnectWaitsForConnectToSettle() async {
        let harness = DictationHarness()
        harness.client.closeUnblocksConnect = false
        await harness.subject.beginHold()
        await harness.subject.endHold()
        await harness.capture.waitUntilStopWasCalled()

        var cancelCompleted = false
        let cancel = Task {
            await harness.subject.cancelAndWait()
            cancelCompleted = true
        }
        await harness.transaction.waitUntilRestored()
        await harness.client.waitUntilClosed()

        XCTAssertFalse(cancelCompleted)
        XCTAssertFalse(harness.subject.isIdle)
        XCTAssertTrue(harness.fallbackRequests.isEmpty)

        harness.client.completeConnection()
        await cancel.value

        XCTAssertTrue(cancelCompleted)
        XCTAssertTrue(harness.subject.isIdle)
        XCTAssertEqual(harness.client.closeCount, 1)
        XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
    }

    func testCancelDuringBlockedAppendWaitsForAppendBeforeBecomingIdle() async {
        let harness = DictationHarness()
        await harness.startListening()
        harness.client.blockNextAppend()
        await harness.capture.yield(Data([1, 2]))
        await harness.client.waitUntilAppendStarts()

        var cancelCompleted = false
        let cancel = Task {
            await harness.subject.cancelAndWait()
            cancelCompleted = true
        }
        await harness.transaction.waitUntilRestored()

        XCTAssertFalse(cancelCompleted)
        XCTAssertFalse(harness.subject.isIdle)

        harness.client.resumeAppend()
        await cancel.value

        XCTAssertTrue(cancelCompleted)
        XCTAssertTrue(harness.subject.isIdle)
        XCTAssertEqual(harness.transaction.restoreCount, 1)
    }

    func testCancelDuringBlockedCommitWaitsAndIgnoresLateCommitResult() async {
        let harness = DictationHarness()
        await harness.startListening()
        harness.client.blockCommit()
        await harness.subject.endHold()
        await harness.client.waitUntilCommitted()

        var cancelCompleted = false
        let cancel = Task {
            await harness.subject.cancelAndWait()
            cancelCompleted = true
        }
        await harness.transaction.waitUntilRestored()

        XCTAssertFalse(cancelCompleted)
        XCTAssertTrue(harness.transaction.committed.isEmpty)

        harness.client.resumeCommit()
        await cancel.value

        XCTAssertTrue(cancelCompleted)
        XCTAssertTrue(harness.subject.isIdle)
        XCTAssertTrue(harness.transaction.committed.isEmpty)
        XCTAssertEqual(harness.client.commitCount, 1)
        XCTAssertEqual(harness.client.closeCount, 1)
        XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
    }

    func testRapidRestartIsBlockedDuringCleanupAndStaleEventCannotMutateTransaction() async {
        let harness = DictationHarness()
        await harness.startListening()
        harness.client.blockClose()

        let cancel = Task { await harness.subject.cancelAndWait() }
        await harness.transaction.waitUntilRestored()
        await harness.client.waitUntilClosed()
        await harness.subject.beginHold()
        harness.client.send(
            .completed(
                eventID: "stale",
                sequence: nil,
                itemID: "old",
                contentIndex: 0,
                transcript: "must not commit"
            )
        )

        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertEqual(harness.transactionBeginCount, 1)
        XCTAssertTrue(harness.transaction.committed.isEmpty)

        harness.client.resumeClose()
        await cancel.value
        await harness.subject.beginHold()

        XCTAssertEqual(harness.capture.startCount, 2)
        XCTAssertEqual(harness.transactionBeginCount, 2)
        XCTAssertTrue(harness.transaction.committed.isEmpty)
        await harness.subject.cancelAndWait()
    }

    func testCancelAndWaitDuringBlockedStopWaitsForLateURLAndDeletesItOnce() async {
        let harness = DictationHarness()
        await harness.startListening()
        harness.capture.blockStop()
        await harness.subject.endHold()
        await harness.capture.waitUntilStopWasCalled()

        var cancelCompleted = false
        let cancel = Task {
            await harness.subject.cancelAndWait()
            cancelCompleted = true
        }
        await harness.transaction.waitUntilRestored()

        XCTAssertFalse(cancelCompleted)
        XCTAssertTrue(harness.deletedURLs.isEmpty)

        harness.capture.resumeStop()
        await cancel.value

        XCTAssertTrue(cancelCompleted)
        XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
        XCTAssertEqual(harness.capture.cancelCount, 1)
    }

    func testInvalidFinalizedFilesNeverInvokeFallbackAndDeleteOnce() async {
        for recordingFile in [
            FakeDictationCapture.RecordingFile.missing,
            .empty,
            .unreadable
        ] {
            let harness = DictationHarness()
            harness.capture.recordingFile = recordingFile
            await harness.startListening()
            harness.client.failReceive(with: RealtimeTranscriptionError.connectionClosed)
            await harness.client.waitUntilClosed()

            await harness.subject.endHold()
            await harness.transaction.waitUntilRestored()
            await harness.subject.cancelAndWait()

            XCTAssertTrue(harness.fallbackRequests.isEmpty)
            XCTAssertEqual(harness.subject.phase, .failed("dictation.error.noSpeech"))
            XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
        }
    }

    func testFallbackEligibilityDoesNotReadTheWholeRecordingOnMainActor() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/InkletApp/WritingDictationCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("Data(contentsOf: recordingURL)"))
    }

    func testFinalEditorFailureRestoresWithoutFallbackAndDeletesOnce() async {
        let harness = DictationHarness()
        harness.transaction.finalError = DictationEditorTransactionError.editorUnavailable
        await harness.startListening()
        await harness.subject.endHold()
        await harness.client.waitUntilCommitted()
        harness.client.send(
            .completed(
                eventID: "final",
                sequence: nil,
                itemID: "item",
                contentIndex: 0,
                transcript: "dictated"
            )
        )
        await harness.transaction.waitUntilRestored()
        await harness.subject.cancelAndWait()

        XCTAssertTrue(harness.transaction.committed.isEmpty)
        XCTAssertEqual(harness.transaction.restoreCount, 1)
        XCTAssertTrue(harness.fallbackRequests.isEmpty)
        XCTAssertEqual(harness.client.closeCount, 1)
        XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
        XCTAssertEqual(harness.subject.phase, .idle)
        XCTAssertFalse(harness.phases.contains { phase in
            if case .failed = phase { return true }
            return false
        })
    }

    func testSuccessFailureAndCancelDeleteEachOwnedTemporaryFileExactlyOnce() async {
        let success = DictationHarness()
        await success.startListening()
        await success.subject.endHold()
        await success.client.waitUntilCommitted()
        success.client.send(
            .completed(
                eventID: "success",
                sequence: nil,
                itemID: "item",
                contentIndex: 0,
                transcript: "success"
            )
        )
        await success.subject.cancelAndWait()

        let failure = DictationHarness(fallbackError: SpeechTranscriptionError.provider("offline"))
        await failure.startListening()
        failure.client.failReceive(with: RealtimeTranscriptionError.connectionClosed)
        await failure.client.waitUntilClosed()
        await failure.subject.endHold()
        await failure.waitUntilFallbackStarts()
        failure.resumeFallback()
        await failure.subject.cancelAndWait()

        let cancellation = DictationHarness()
        cancellation.client.closeUnblocksConnect = false
        await cancellation.subject.beginHold()
        await cancellation.subject.endHold()
        await cancellation.capture.waitUntilStopWasCalled()
        let cancelled = Task { await cancellation.subject.cancelAndWait() }
        await cancellation.transaction.waitUntilRestored()
        cancellation.client.completeConnection()
        await cancelled.value

        XCTAssertEqual(success.deletedURLs, [success.capture.recordingURL])
        XCTAssertEqual(failure.deletedURLs, [failure.capture.recordingURL])
        XCTAssertEqual(cancellation.deletedURLs, [cancellation.capture.recordingURL])
    }

    func testTerminalCleanupReentrantCancelCannotUndoCommittedText() async {
        let harness = DictationHarness()
        var reentrantCancel: Task<Void, Never>?
        harness.deleteHandler = { _ in
            reentrantCancel = Task { await harness.subject.cancel() }
        }
        await harness.startListening()
        await harness.subject.endHold()
        await harness.client.waitUntilCommitted()
        harness.client.send(
            .completed(
                eventID: "terminal",
                sequence: nil,
                itemID: "item",
                contentIndex: 0,
                transcript: "owned text"
            )
        )
        await harness.transaction.waitUntilCommitted()
        await harness.subject.cancelAndWait()
        await reentrantCancel?.value

        XCTAssertEqual(harness.transaction.committed, ["owned text"])
        XCTAssertEqual(harness.transaction.restoreCount, 0)
        XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
        XCTAssertEqual(harness.subject.phase, .complete)
    }

    func testTerminalPhaseHandlerCannotRestartBeforeCleanupTaskReturns() async {
        let harness = DictationHarness(manualTerminalHandoff: true)
        let restartReturned = ManualGate()
        harness.phaseCallback = { phase in
            guard phase == .complete else { return }
            Task { @MainActor in
                await harness.subject.beginHold()
                restartReturned.open()
            }
        }

        await harness.startListening()
        await harness.subject.endHold()
        await harness.client.waitUntilCommitted()
        harness.client.send(
            .completed(
                eventID: "final",
                sequence: nil,
                itemID: "item",
                contentIndex: 0,
                transcript: "done"
            )
        )
        await restartReturned.wait()

        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertEqual(harness.transactionBeginCount, 1)
        XCTAssertFalse(harness.subject.isIdle)

        harness.resumeTerminalHandoff()
        await harness.subject.cancelAndWait()
        XCTAssertTrue(harness.subject.isIdle)

        harness.phaseCallback = nil
        await harness.subject.beginHold()
        XCTAssertEqual(harness.capture.startCount, 2)
        XCTAssertEqual(harness.transactionBeginCount, 2)
        await harness.subject.cancelAndWait()
    }

    func testReleaseDuringPendingCaptureStartRestoresImmediatelyAndBlocksRestartUntilCleanup() async {
        let harness = DictationHarness()
        harness.capture.blockStart()
        let begin = Task { await harness.subject.beginHold() }
        await harness.capture.waitUntilStartWasCalled()

        await harness.subject.endHold()
        XCTAssertEqual(harness.transaction.restoreCount, 1)
        XCTAssertFalse(harness.subject.isIdle)
        await harness.client.waitUntilClosed()
        XCTAssertEqual(harness.capture.cancelCount, 1)

        await harness.subject.beginHold()
        XCTAssertEqual(harness.capture.startCount, 1)

        harness.capture.resumeStart()
        await begin.value
        await harness.subject.cancelAndWait()

        XCTAssertTrue(harness.subject.isIdle)
        XCTAssertEqual(harness.transaction.restoreCount, 1)
        XCTAssertEqual(harness.capture.cancelCount, 1)
        XCTAssertEqual(harness.client.closeCount, 1)
        XCTAssertTrue(harness.capture.createdURLs.isEmpty)
        XCTAssertFalse(harness.phases.contains(.listening))
    }

    func testCancelAndWaitDuringPendingCaptureStartWaitsForLateStartCleanup() async {
        let harness = DictationHarness()
        harness.capture.blockStart()
        let begin = Task { await harness.subject.beginHold() }
        await harness.capture.waitUntilStartWasCalled()

        var cancelCompleted = false
        let cancel = Task {
            await harness.subject.cancelAndWait()
            cancelCompleted = true
        }
        await harness.transaction.waitUntilRestored()
        await harness.client.waitUntilClosed()

        XCTAssertFalse(cancelCompleted)
        XCTAssertFalse(harness.subject.isIdle)
        XCTAssertEqual(harness.capture.cancelCount, 1)

        harness.capture.resumeStart()
        await begin.value
        await cancel.value

        XCTAssertTrue(cancelCompleted)
        XCTAssertTrue(harness.subject.isIdle)
        XCTAssertEqual(harness.capture.cancelCount, 1)
        XCTAssertEqual(harness.client.closeCount, 1)
        XCTAssertTrue(harness.capture.createdURLs.isEmpty)
    }

    func testCancelPublishesIdleBeforePendingCaptureStartCleanupDrains() async {
        let harness = DictationHarness()
        harness.capture.blockStart()
        let begin = Task { await harness.subject.beginHold() }
        await harness.capture.waitUntilStartWasCalled()

        await harness.subject.cancel()

        XCTAssertEqual(harness.transaction.restoreCount, 1)
        XCTAssertEqual(harness.subject.phase, .idle)
        XCTAssertEqual(harness.phases.last, .idle)

        var cleanupCompleted = false
        let cleanup = Task {
            await harness.subject.cancelAndWait()
            cleanupCompleted = true
        }
        await harness.client.waitUntilClosed()

        XCTAssertFalse(cleanupCompleted)

        harness.capture.resumeStart()
        await begin.value
        await cleanup.value

        XCTAssertTrue(cleanupCompleted)
        XCTAssertTrue(harness.subject.isIdle)
    }

    func testCaptureAndStopFailureRestoreCloseAndNeverFallback() async {
        let capture = DictationHarness()
        capture.capture.startError = AudioRecorder.AudioRecorderError.recordingUnavailable
        await capture.subject.beginHold()
        await capture.subject.cancelAndWait()
        XCTAssertEqual(capture.transaction.restoreCount, 1)
        XCTAssertEqual(capture.client.closeCount, 1)
        XCTAssertTrue(capture.fallbackRequests.isEmpty)

        let stop = DictationHarness()
        await stop.startListening()
        stop.capture.stopError = AudioRecorder.AudioRecorderError.recordingUnavailable
        await stop.subject.endHold()
        await stop.transaction.waitUntilRestored()
        await stop.subject.cancelAndWait()
        XCTAssertEqual(stop.transaction.restoreCount, 1)
        XCTAssertEqual(stop.client.closeCount, 1)
    }

    func testSpontaneousStartCancellationFailsAndCleansUpInsteadOfPublishingIdle() async {
        let harness = DictationHarness()
        harness.capture.startError = CancellationError()

        await harness.subject.beginHold()
        await harness.subject.cancelAndWait()

        XCTAssertEqual(harness.subject.phase, .failed("dictation.error.fallback"))
        XCTAssertEqual(harness.transaction.restoreCount, 1)
        XCTAssertEqual(harness.client.closeCount, 1)
        XCTAssertEqual(harness.capture.cancelCount, 0)
        XCTAssertTrue(harness.deletedURLs.isEmpty)
    }

    func testSpontaneousConnectCancellationLosesRealtimeThenFallsBackAndCleansUp() async {
        let harness = DictationHarness()
        await harness.subject.beginHold()
        harness.client.failConnection(with: CancellationError())
        await harness.client.waitUntilConnectErrorWasThrown()

        XCTAssertEqual(harness.subject.phase, .recordingForFallback)
        XCTAssertEqual(harness.client.closeCount, 1)

        await harness.subject.endHold()
        await harness.waitUntilFallbackStarts()

        harness.resumeFallback()
        await harness.transaction.waitUntilCommitted()
        await harness.subject.cancelAndWait()

        XCTAssertEqual(harness.transaction.committed, ["fallback"])
        XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
    }

    func testSpontaneousAppendCancellationLosesRealtimeAndCanCancelCleanly() async {
        let harness = DictationHarness()
        await harness.startListening()
        harness.client.nextAppendError = CancellationError()

        await harness.capture.yieldAndWaitUntilAccepted(Data([1, 2, 3]))

        XCTAssertEqual(harness.subject.phase, .recordingForFallback)
        XCTAssertEqual(harness.client.closeCount, 1)

        await harness.subject.cancelAndWait()
        XCTAssertEqual(harness.transaction.restoreCount, 1)
        XCTAssertTrue(harness.subject.isIdle)
    }

    func testSpontaneousStopCancellationFailsAndCleansUpInsteadOfStrandingFinalizing() async {
        let harness = DictationHarness()
        await harness.startListening()
        harness.capture.stopError = CancellationError()

        await harness.subject.endHold()
        await harness.capture.waitUntilStopErrorWasThrown()

        XCTAssertEqual(harness.transaction.restoreCount, 1)
        await harness.subject.cancelAndWait()
        XCTAssertEqual(harness.subject.phase, .failed("dictation.error.fallback"))
        XCTAssertEqual(harness.client.closeCount, 1)
        XCTAssertTrue(harness.deletedURLs.isEmpty)
    }

    func testSpontaneousCommitCancellationFallsBackAndDeletesFinalizedFileOnce() async {
        let harness = DictationHarness()
        await harness.startListening()
        harness.client.commitError = CancellationError()

        await harness.subject.endHold()
        await harness.client.waitUntilCommitErrorWasThrown()

        XCTAssertEqual(harness.subject.phase, .recovering)
        if harness.subject.phase == .recovering {
            await harness.waitUntilFallbackStarts()
            harness.resumeFallback()
        }
        await harness.transaction.waitUntilCommitted()
        await harness.subject.cancelAndWait()

        XCTAssertEqual(harness.transaction.committed, ["fallback"])
        XCTAssertEqual(harness.client.closeCount, 1)
        XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
    }

    func testSpontaneousFallbackCancellationFailsRestoresAndDeletesOnce() async {
        let harness = DictationHarness(fallbackError: CancellationError())
        await harness.startListening()
        harness.client.failReceive(with: RealtimeTranscriptionError.connectionClosed)
        await harness.client.waitUntilClosed()
        await harness.subject.endHold()
        await harness.waitUntilFallbackStarts()

        harness.resumeFallback()
        await harness.waitUntilFallbackErrorWasThrown()

        XCTAssertEqual(harness.transaction.restoreCount, 1)
        await harness.subject.cancelAndWait()
        XCTAssertEqual(harness.subject.phase, .failed("dictation.error.fallback"))
        XCTAssertEqual(harness.client.closeCount, 1)
        XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
    }

    private func phaseForCaptureStartError(
        _ error: AudioRecorder.AudioRecorderError
    ) async -> WritingDictationCoordinator.Phase {
        let capture = FakeDictationCapture()
        capture.startError = error
        let client = FakeRealtimeClient()
        let transaction = FakeDictationTransaction()
        let subject = WritingDictationCoordinator(
            configProvider: { VoiceInputConfig.defaultConfig() },
            audioCapture: capture,
            makeRealtimeClient: { client },
            beginTransaction: { transaction },
            transcribeFallback: { _, _ in "unused" }
        )

        await subject.beginHold()
        await subject.cancelAndWait()
        return subject.phase
    }

    private func phaseForClientFactoryError(
        _ error: Error
    ) async -> WritingDictationCoordinator.Phase {
        let capture = FakeDictationCapture()
        let transaction = FakeDictationTransaction()
        let subject = WritingDictationCoordinator(
            configProvider: { VoiceInputConfig.defaultConfig() },
            audioCapture: capture,
            makeRealtimeClient: { throw error },
            beginTransaction: { transaction },
            transcribeFallback: { _, _ in "unused" }
        )

        await subject.beginHold()
        return subject.phase
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
    var deleteHandler: ((URL) -> Void)?
    var phaseCallback: ((WritingDictationCoordinator.Phase) -> Void)?
    private let clientFactoryError: Error?
    private let fallbackText: String
    private let fallbackError: Error?
    private let transactionAvailable: Bool
    private let finalTimeoutSeconds: TimeInterval
    private var fallbackBlocked = true
    private let fallbackGate = ManualGate()
    private let timeoutWaiter: FakeFinalTimeoutWaiter
    private let terminalHandoffWaiter: FakeTerminalHandoffWaiter
    private var fallbackStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var fallbackErrorWaiters: [CheckedContinuation<Void, Never>] = []
    private var phaseWaiters: [PhaseWaiter] = []

    private struct PhaseWaiter {
        let candidates: [WritingDictationCoordinator.Phase]
        let continuation: CheckedContinuation<WritingDictationCoordinator.Phase, Never>
    }

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
            return transactionAvailable ? transaction : nil
        },
        transcribeFallback: { [weak self] url, _ in
            guard let self else { throw CancellationError() }
            fallbackRequests.append(url)
            let waiters = fallbackStartWaiters
            fallbackStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if fallbackBlocked {
                await fallbackGate.wait()
            }
            if let fallbackError {
                let waiters = fallbackErrorWaiters
                fallbackErrorWaiters.removeAll()
                waiters.forEach { $0.resume() }
                throw fallbackError
            }
            return fallbackText
        },
        deleteTemporaryFile: { [weak self] url in
            self?.deletedURLs.append(url)
            self?.deleteHandler?(url)
        },
        phaseHandler: { [weak self] phase in
            self?.record(phase)
            self?.phaseCallback?(phase)
        },
        errorKey: { error in
            error as? RealtimeTranscriptionError == .missingAPIKey
                ? "dictation.error.missingAPIKey"
                : "dictation.error.fallback"
        },
        finalTimeoutSeconds: finalTimeoutSeconds,
        finalTimeoutWaiter: timeoutWaiter,
        terminalHandoffWaiter: terminalHandoffWaiter
    )

    init(
        clientFactoryError: Error? = nil,
        fallbackText: String = "fallback",
        fallbackError: Error? = nil,
        transactionAvailable: Bool = true,
        finalTimeoutSeconds: TimeInterval = 15,
        manualTimeout: Bool = false,
        manualTerminalHandoff: Bool = false
    ) {
        self.clientFactoryError = clientFactoryError
        self.fallbackText = fallbackText
        self.fallbackError = fallbackError
        self.transactionAvailable = transactionAvailable
        self.finalTimeoutSeconds = finalTimeoutSeconds
        timeoutWaiter = FakeFinalTimeoutWaiter(manual: manualTimeout)
        terminalHandoffWaiter = FakeTerminalHandoffWaiter(manual: manualTerminalHandoff)
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
        fallbackGate.open()
    }

    func waitUntilFallbackErrorWasThrown() async {
        await withCheckedContinuation { fallbackErrorWaiters.append($0) }
    }

    func waitUntilTimeoutStarts() async {
        await timeoutWaiter.waitUntilStarted()
    }

    func resumeTimeout() {
        timeoutWaiter.resume()
    }

    func resumeTerminalHandoff() {
        terminalHandoffWaiter.resume()
    }

    func waitUntilPhase(
        _ candidates: [WritingDictationCoordinator.Phase]
    ) async -> WritingDictationCoordinator.Phase {
        if let phase = phases.last(where: { candidates.contains($0) }) {
            return phase
        }
        return await withCheckedContinuation { continuation in
            phaseWaiters.append(
                PhaseWaiter(candidates: candidates, continuation: continuation)
            )
        }
    }

    private func record(_ phase: WritingDictationCoordinator.Phase) {
        phases.append(phase)
        let ready = phaseWaiters.filter { $0.candidates.contains(phase) }
        phaseWaiters.removeAll { $0.candidates.contains(phase) }
        ready.forEach { $0.continuation.resume(returning: phase) }
    }

}

@MainActor
private final class ManualGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredCount = 0
    private var enteredWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func wait() async {
        enteredCount += 1
        let ready = enteredWaiters.filter { enteredCount >= $0.0 }
        enteredWaiters.removeAll { enteredCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func waitUntilEntered(_ count: Int = 1) async {
        if enteredCount >= count { return }
        await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }
}

@MainActor
private final class FakeFinalTimeoutWaiter: WritingDictationFinalTimeoutWaiting {
    private struct PendingWait {
        let generation: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let manual: Bool
    private let gate = ManualGate()
    private var pendingWait: PendingWait?

    init(manual: Bool) {
        self.manual = manual
    }

    func wait(seconds: TimeInterval) async throws {
        if manual {
            await gate.wait()
            return
        }

        let generation = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingWait = PendingWait(
                    generation: generation,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingWait(generation: generation)
            }
        }
    }

    func waitUntilStarted() async {
        await gate.waitUntilEntered()
    }

    func resume() {
        gate.open()
    }

    private func cancelPendingWait(generation: UUID) {
        guard pendingWait?.generation == generation else { return }
        let continuation = pendingWait?.continuation
        pendingWait = nil
        continuation?.resume(throwing: CancellationError())
    }
}

@MainActor
private final class FakeTerminalHandoffWaiter: WritingDictationTerminalHandoffWaiting {
    private let manual: Bool
    private let gate = ManualGate()

    init(manual: Bool) {
        self.manual = manual
    }

    func wait() async {
        guard manual else { return }
        await gate.wait()
    }

    func resume() {
        gate.open()
    }
}

@MainActor
private final class FakeDictationCapture: DictationAudioCapturing {
    enum RecordingFile {
        case nonempty
        case empty
        case missing
        case unreadable
    }

    let recordingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationHarness-\(UUID().uuidString).m4a")
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var createdURLs: [URL] = []
    var startError: Error?
    var stopError: Error?
    var recordingFile: RecordingFile = .nonempty
    private var frameSource: FakeFrameSource?
    private var startBlocked = false
    private var startInFlight = false
    private var startCancellationRequested = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopErrorWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopBlocked = false
    private let stopGate = ManualGate()

    func startStreaming(microphoneDeviceID: String?) async throws -> AsyncThrowingStream<Data, Error> {
        startCount += 1
        startInFlight = true
        startCancellationRequested = false
        defer { startInFlight = false }
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if startBlocked {
            await withCheckedContinuation { startContinuation = $0 }
        }
        if startCancellationRequested { throw CancellationError() }
        if let startError { throw startError }
        createdURLs = [recordingURL]
        let source = FakeFrameSource()
        frameSource = source
        return AsyncThrowingStream<Data, Error>(unfolding: {
            await source.next()
        })
    }

    func stop() async throws -> URL {
        stopCount += 1
        await frameSource?.finish()
        frameSource = nil
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if stopBlocked {
            await stopGate.wait()
        }
        if let stopError {
            let waiters = stopErrorWaiters
            stopErrorWaiters.removeAll()
            waiters.forEach { $0.resume() }
            throw stopError
        }
        switch recordingFile {
        case .nonempty:
            try Data([1]).write(to: recordingURL)
        case .empty:
            try Data().write(to: recordingURL)
        case .missing:
            try? FileManager.default.removeItem(at: recordingURL)
        case .unreadable:
            try Data([1]).write(to: recordingURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0],
                ofItemAtPath: recordingURL.path
            )
        }
        return recordingURL
    }

    func cancel() async {
        cancelCount += 1
        if startInFlight {
            startCancellationRequested = true
        }
        await frameSource?.finish()
        frameSource = nil
    }

    func yield(_ data: Data) async {
        _ = await frameSource?.send(data)
    }
    func yieldAndWaitUntilAccepted(_ data: Data) async {
        guard let frameSource else { return }
        let index = await frameSource.send(data)
        await frameSource.waitUntilAccepted(index)
    }
    func blockStart() { startBlocked = true }
    func blockStop() { stopBlocked = true }
    func resumeStart() {
        startBlocked = false
        startContinuation?.resume()
        startContinuation = nil
    }
    func waitUntilStartWasCalled() async {
        if startCount > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func waitUntilStopWasCalled() async {
        if stopCount > 0 { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }
    func waitUntilStopErrorWasThrown() async {
        await withCheckedContinuation { stopErrorWaiters.append($0) }
    }
    func resumeStop() {
        stopBlocked = false
        stopGate.open()
    }
}

private actor FakeFrameSource {
    private struct Frame {
        let index: Int
        let data: Data
    }

    private var frames: [Frame] = []
    private var nextWaiter: CheckedContinuation<Data?, Never>?
    private var submittedCount = 0
    private var acceptedCount = 0
    private var deliveredIndex: Int?
    private var acceptedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var isFinished = false

    func send(_ data: Data) -> Int {
        submittedCount += 1
        let frame = Frame(index: submittedCount, data: data)
        if let nextWaiter {
            self.nextWaiter = nil
            deliveredIndex = frame.index
            nextWaiter.resume(returning: frame.data)
        } else if !isFinished {
            frames.append(frame)
        }
        return frame.index
    }

    func next() async -> Data? {
        acknowledgeDeliveredFrame()
        if !frames.isEmpty {
            let frame = frames.removeFirst()
            deliveredIndex = frame.index
            return frame.data
        }
        if isFinished { return nil }
        return await withCheckedContinuation { nextWaiter = $0 }
    }

    func waitUntilAccepted(_ index: Int) async {
        if acceptedCount >= index { return }
        await withCheckedContinuation { acceptedWaiters.append((index, $0)) }
    }

    func finish() {
        isFinished = true
        guard frames.isEmpty, let nextWaiter else { return }
        self.nextWaiter = nil
        nextWaiter.resume(returning: nil)
    }

    private func acknowledgeDeliveredFrame() {
        guard let deliveredIndex else { return }
        self.deliveredIndex = nil
        acceptedCount = max(acceptedCount, deliveredIndex)
        let ready = acceptedWaiters.filter { acceptedCount >= $0.0 }
        acceptedWaiters.removeAll { acceptedCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

@MainActor
private final class FakeDictationTransaction: DictationEditorTransacting {
    private(set) var provisional: [String] = []
    private(set) var committed: [String] = []
    private(set) var restoreCount = 0
    var provisionalError: Error?
    var finalError: Error?
    private var provisionalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var committedWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoreWaiters: [CheckedContinuation<Void, Never>] = []

    func replaceProvisional(with cumulativeText: String) throws {
        if let provisionalError { throw provisionalError }
        provisional.append(cumulativeText)
        let ready = provisionalWaiters.filter { provisional.count >= $0.0 }
        provisionalWaiters.removeAll { provisional.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
    func commitFinal(_ text: String) throws {
        if let finalError { throw finalError }
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
    var closeUnblocksConnect = true
    var nextAppendError: Error?
    var commitError: Error?

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var pendingConnectionResult: Result<Void, Error>?
    private var connectErrorWasThrown = false
    private var connectErrorWaiters: [CheckedContinuation<Void, Never>] = []
    private var eventQueue: [Result<RealtimeTranscriptionEvent, Error>] = []
    private var eventWaiter: CheckedContinuation<RealtimeTranscriptionEvent, Error>?
    private var shouldBlockNextEvent = false
    private var nextEventGate: ManualGate?
    private var nextEventBlockWaiters: [CheckedContinuation<Void, Never>] = []
    private var receiveStarted = false
    private var receiveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldBlockNextAppend = false
    private var appendGate: ManualGate?
    private var appendStartCount = 0
    private var appendStartWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var shouldBlockCommit = false
    private var commitGate: ManualGate?
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitErrorWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeBlocked = false
    private let closeGate = ManualGate()

    func connect(timeoutSeconds: TimeInterval) async throws {
        do {
            if let pendingConnectionResult {
                self.pendingConnectionResult = nil
                return try pendingConnectionResult.get()
            }
            try await withCheckedThrowingContinuation { connectContinuation = $0 }
        } catch {
            connectErrorWasThrown = true
            let waiters = connectErrorWaiters
            connectErrorWaiters.removeAll()
            waiters.forEach { $0.resume() }
            throw error
        }
    }
    func completeConnection() { resumeConnection(with: .success(())) }
    func failConnection(with error: Error) { resumeConnection(with: .failure(error)) }

    func appendPCM16(_ data: Data) async throws {
        if didCommit { appendedAfterCommit = true }
        appendStartCount += 1
        let waiters = appendStartWaiters.filter { appendStartCount >= $0.0 }
        appendStartWaiters.removeAll { appendStartCount >= $0.0 }
        waiters.forEach { $0.1.resume() }
        if shouldBlockNextAppend {
            shouldBlockNextAppend = false
            let gate = ManualGate()
            appendGate = gate
            await gate.wait()
        }
        if let nextAppendError {
            self.nextAppendError = nil
            throw nextAppendError
        }
        operations.append("append:\(data.count)")
    }
    func blockNextAppend() { shouldBlockNextAppend = true }
    func resumeAppend() {
        appendGate?.open()
        appendGate = nil
    }

    func commit() async throws {
        commitCount += 1
        let waiters = commitWaiters
        commitWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if shouldBlockCommit {
            shouldBlockCommit = false
            let gate = ManualGate()
            commitGate = gate
            await gate.wait()
        }
        if let commitError {
            let waiters = commitErrorWaiters
            commitErrorWaiters.removeAll()
            waiters.forEach { $0.resume() }
            throw commitError
        }
        operations.append("commit")
    }
    func blockCommit() { shouldBlockCommit = true }
    func resumeCommit() {
        commitGate?.open()
        commitGate = nil
    }

    func nextEvent() async throws -> RealtimeTranscriptionEvent {
        receiveStarted = true
        let waiters = receiveStartWaiters
        receiveStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        let result: Result<RealtimeTranscriptionEvent, Error>
        if !eventQueue.isEmpty {
            result = eventQueue.removeFirst()
        } else {
            do {
                result = .success(
                    try await withCheckedThrowingContinuation { eventWaiter = $0 }
                )
            } catch {
                result = .failure(error)
            }
        }
        if shouldBlockNextEvent {
            shouldBlockNextEvent = false
            let gate = ManualGate()
            nextEventGate = gate
            let waiters = nextEventBlockWaiters
            nextEventBlockWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await gate.wait()
        }
        return try result.get()
    }
    func send(_ event: RealtimeTranscriptionEvent) { enqueue(.success(event)) }
    func failReceive(with error: Error) { enqueue(.failure(error)) }
    func blockNextEvent() { shouldBlockNextEvent = true }
    func waitUntilNextEventIsBlocked() async {
        if nextEventGate == nil {
            await withCheckedContinuation { nextEventBlockWaiters.append($0) }
        }
        await nextEventGate?.waitUntilEntered()
    }
    func resumeNextEvent() {
        nextEventGate?.open()
        nextEventGate = nil
    }

    func close() async {
        closeCount += 1
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if closeBlocked {
            await closeGate.wait()
        }
        if closeUnblocksConnect {
            connectContinuation?.resume(throwing: CancellationError())
            connectContinuation = nil
        }
        eventWaiter?.resume(throwing: RealtimeTranscriptionError.connectionClosed)
        eventWaiter = nil
    }

    func waitUntilReceiveStarts() async {
        if receiveStarted { return }
        await withCheckedContinuation { receiveStartWaiters.append($0) }
    }
    func waitUntilConnectErrorWasThrown() async {
        if connectErrorWasThrown { return }
        await withCheckedContinuation { connectErrorWaiters.append($0) }
    }
    func waitUntilAppendStarts(_ count: Int = 1) async {
        if appendStartCount >= count { return }
        await withCheckedContinuation { appendStartWaiters.append((count, $0)) }
    }
    func waitUntilCommitted() async {
        if didCommit { return }
        await withCheckedContinuation { commitWaiters.append($0) }
    }
    func waitUntilCommitErrorWasThrown() async {
        await withCheckedContinuation { commitErrorWaiters.append($0) }
    }
    func waitUntilClosed() async {
        if closeCount > 0 { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }
    func blockClose() { closeBlocked = true }
    func resumeClose() {
        closeBlocked = false
        closeGate.open()
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
