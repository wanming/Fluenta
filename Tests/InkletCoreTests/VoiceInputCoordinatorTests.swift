import AppKit
import XCTest
@testable import InkletCore

@MainActor
final class VoiceInputCoordinatorTests: XCTestCase {
    func testStopNotifiesIdleOnlyAfterOperationFinishes() async {
        let harness = VoiceInputHarness()

        await harness.coordinator.start()
        harness.resetIdleStateObservations()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.idleStateChanges.last, true)
        XCTAssertEqual(harness.idleStateSnapshots.last, true)
    }

    func testCancelNotifiesIdleOnlyAfterOperationFinishes() async {
        let harness = VoiceInputHarness()

        await harness.coordinator.start()
        harness.resetIdleStateObservations()
        await harness.coordinator.cancel()

        XCTAssertEqual(harness.idleStateChanges.last, true)
        XCTAssertEqual(harness.idleStateSnapshots.last, true)
    }

    func testErrorNotifiesIdleOnlyAfterOperationFinishes() async {
        let harness = VoiceInputHarness()
        harness.transcriptionError = SpeechTranscriptionError.provider("test failure")

        await harness.coordinator.start()
        harness.resetIdleStateObservations()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.idleStateChanges.last, true)
        XCTAssertEqual(harness.idleStateSnapshots.last, true)
    }

    func testIsIdleTracksStartupListeningAndCancellation() async {
        let harness = VoiceInputHarness()
        harness.pauseStartRecording = true

        XCTAssertTrue(harness.coordinator.isIdle)

        let startTask = Task {
            await harness.coordinator.start()
        }
        await Task.yield()

        XCTAssertFalse(harness.coordinator.isIdle)

        let cancellationTask = Task {
            await harness.coordinator.cancelForMigrationMaintenance()
        }
        await Task.yield()

        XCTAssertFalse(harness.coordinator.isIdle)

        harness.resumeStartRecording()
        await startTask.value
        await cancellationTask.value

        XCTAssertTrue(harness.coordinator.isIdle)
        XCTAssertEqual(harness.cancelRecordingCount, 1)
        XCTAssertEqual(harness.statuses, [.idle])
    }

    func testMigrationMaintenanceCancellationInvalidatesInFlightTranscription() async {
        let harness = VoiceInputHarness()
        harness.pauseTranscription = true

        await harness.coordinator.start()
        let stopTask = Task {
            await harness.coordinator.stop()
        }
        await Task.yield()

        XCTAssertFalse(harness.coordinator.isIdle)

        let cancellationTask = Task {
            await harness.coordinator.cancelForMigrationMaintenance()
        }
        await Task.yield()

        XCTAssertFalse(harness.coordinator.isIdle)

        harness.resumeTranscription()
        await stopTask.value
        await cancellationTask.value

        XCTAssertEqual(harness.insertedTexts, [])
        XCTAssertTrue(harness.coordinator.isIdle)
        XCTAssertEqual(harness.statuses, [.listening, .transcribing, .idle])
    }

    func testMigrationMaintenanceWaitsForAnExistingRecordingCancellation() async {
        let harness = VoiceInputHarness()
        harness.pauseCancelRecording = true

        await harness.coordinator.start()
        let ordinaryCancellationTask = Task {
            await harness.coordinator.cancel()
        }
        await Task.yield()

        let maintenanceCancellationTask = Task {
            await harness.coordinator.cancelForMigrationMaintenance()
        }
        await Task.yield()

        XCTAssertFalse(harness.coordinator.isIdle)

        harness.resumeCancelRecording()
        await ordinaryCancellationTask.value
        await maintenanceCancellationTask.value

        XCTAssertTrue(harness.coordinator.isIdle)
        XCTAssertEqual(harness.cancelRecordingCount, 1)
    }

    func testStartBeginsRecordingAndShowsListening() async {
        let harness = VoiceInputHarness()

        await harness.coordinator.start()

        XCTAssertEqual(harness.startRecordingCount, 1)
        XCTAssertEqual(harness.statuses, [.listening])
    }

    func testRepeatedToggleDuringStartupStartsRecordingOnce() async {
        let harness = VoiceInputHarness()
        harness.pauseStartRecording = true

        let startTask = Task {
            await harness.coordinator.toggle()
        }
        await Task.yield()
        await harness.coordinator.toggle()

        XCTAssertEqual(harness.startRecordingCount, 1)
        XCTAssertEqual(harness.statuses, [])

        harness.resumeStartRecording()
        await startTask.value

        XCTAssertEqual(harness.startRecordingCount, 1)
        XCTAssertEqual(harness.statuses, [.listening])
    }

    func testStopDuringStartupCancelsBeforeListening() async {
        let harness = VoiceInputHarness()
        harness.pauseStartRecording = true

        let startTask = Task {
            await harness.coordinator.start()
        }
        await Task.yield()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.statuses, [.idle])

        harness.resumeStartRecording()
        await startTask.value

        XCTAssertFalse(harness.statuses.contains(.listening))
        XCTAssertEqual(harness.insertedTexts, [])
    }

    func testCancelDuringListeningStopsRecordingAndShowsIdle() async {
        let harness = VoiceInputHarness()

        await harness.coordinator.start()
        await harness.coordinator.cancel()

        XCTAssertEqual(harness.cancelRecordingCount, 1)
        XCTAssertEqual(harness.insertedTexts, [])
        XCTAssertEqual(harness.statuses, [.listening, .idle])
    }

    func testStopWithAutoProcessingDisabledInsertsRawTranscription() async {
        let harness = VoiceInputHarness(config: VoiceInputConfig(
            shortcut: .rightOption,
            speechProviderID: VoiceInputConfig.openAISpeechProviderID,
            speechEndpoint: VoiceInputConfig.defaultSpeechEndpoint,
            speechModel: VoiceInputConfig.defaultSpeechModel,
            microphoneDeviceID: nil,
            autoProcessTranscription: false,
            voiceCleanupPromptModeID: PromptMode.voiceCleanupID
        ))
        harness.transcriptionText = "raw transcript"

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.insertedTexts, ["raw transcript"])
        XCTAssertEqual(harness.cleanupInputs, [])
        XCTAssertEqual(harness.statuses, [.listening, .transcribing, .inserting, .idle])
    }

    func testRawTranscriptionSuccessRecordsHistory() async {
        let harness = VoiceInputHarness(config: VoiceInputConfig(
            shortcut: .rightOption,
            speechProviderID: VoiceInputConfig.openAISpeechProviderID,
            speechEndpoint: VoiceInputConfig.defaultSpeechEndpoint,
            speechModel: "gpt-speech-test",
            microphoneDeviceID: nil,
            autoProcessTranscription: false,
            voiceCleanupPromptModeID: PromptMode.voiceCleanupID
        ))
        harness.transcriptionText = "raw transcript"

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.recordedHistory, [
            VoiceInputHistoryEvent(
                transcript: "raw transcript",
                finalText: "raw transcript",
                cleanupPromptModeID: nil,
                speechModel: "gpt-speech-test",
                cleanupFallback: false
            )
        ])
    }

    func testStopWithAutoProcessingEnabledInsertsCleanedText() async {
        let harness = VoiceInputHarness()
        harness.transcriptionText = "um hello there"
        harness.cleanedText = "Hello there."

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.cleanupInputs, ["um hello there"])
        XCTAssertEqual(harness.insertedTexts, ["Hello there."])
        XCTAssertEqual(harness.statuses, [.listening, .transcribing, .polishing, .inserting, .idle])
    }

    func testCleanedTranscriptionSuccessRecordsHistory() async {
        let harness = VoiceInputHarness()
        harness.transcriptionText = "um hello there"
        harness.cleanedText = "Hello there."

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.recordedHistory, [
            VoiceInputHistoryEvent(
                transcript: "um hello there",
                finalText: "Hello there.",
                cleanupPromptModeID: PromptMode.voiceCleanupID,
                speechModel: VoiceInputConfig.defaultSpeechModel,
                cleanupFallback: false
            )
        ])
    }

    func testStopWithAskEachTimeUsesSelectedPromptMode() async {
        let harness = VoiceInputHarness(config: VoiceInputConfig(
            shortcut: .rightOption,
            speechProviderID: VoiceInputConfig.openAISpeechProviderID,
            speechEndpoint: VoiceInputConfig.defaultSpeechEndpoint,
            speechModel: VoiceInputConfig.defaultSpeechModel,
            microphoneDeviceID: nil,
            autoProcessTranscription: true,
            postTranscriptionAction: .askEachTime,
            voiceCleanupPromptModeID: PromptMode.voiceCleanupID
        ))
        harness.transcriptionText = "summarize this"
        harness.cleanedText = "Summary."
        harness.promptModeSelection = .promptMode(PromptMode.chineseSummaryID)

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.promptModeSelectionRequests.map(\.transcript), ["summarize this"])
        XCTAssertEqual(harness.promptModeSelectionRequests.map(\.defaultPromptModeID), [PromptMode.voiceCleanupID])
        XCTAssertEqual(harness.cleanupInputs, ["summarize this"])
        XCTAssertEqual(harness.cleanupModeIDs, [PromptMode.chineseSummaryID])
        XCTAssertEqual(harness.insertedTexts, ["Summary."])
        XCTAssertEqual(harness.statuses, [.listening, .transcribing, .choosingPromptMode, .polishing, .inserting, .idle])
    }

    func testAskEachTimePromptModeSuccessRecordsSelectedModeHistory() async {
        let harness = VoiceInputHarness(config: VoiceInputConfig(
            shortcut: .rightOption,
            speechProviderID: VoiceInputConfig.openAISpeechProviderID,
            speechEndpoint: VoiceInputConfig.defaultSpeechEndpoint,
            speechModel: "gpt-speech-test",
            microphoneDeviceID: nil,
            autoProcessTranscription: true,
            postTranscriptionAction: .askEachTime,
            voiceCleanupPromptModeID: PromptMode.voiceCleanupID
        ))
        harness.transcriptionText = "summarize this"
        harness.cleanedText = "Summary."
        harness.promptModeSelection = .promptMode(PromptMode.chineseSummaryID)

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.recordedHistory, [
            VoiceInputHistoryEvent(
                transcript: "summarize this",
                finalText: "Summary.",
                cleanupPromptModeID: PromptMode.chineseSummaryID,
                speechModel: "gpt-speech-test",
                cleanupFallback: false
            )
        ])
    }

    func testStopWithAskEachTimeCanInsertRawTranscription() async {
        let harness = VoiceInputHarness(config: VoiceInputConfig(
            shortcut: .rightOption,
            speechProviderID: VoiceInputConfig.openAISpeechProviderID,
            speechEndpoint: VoiceInputConfig.defaultSpeechEndpoint,
            speechModel: VoiceInputConfig.defaultSpeechModel,
            microphoneDeviceID: nil,
            autoProcessTranscription: true,
            postTranscriptionAction: .askEachTime,
            voiceCleanupPromptModeID: PromptMode.voiceCleanupID
        ))
        harness.transcriptionText = "raw words"
        harness.promptModeSelection = .rawTranscript

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.promptModeSelectionRequests.map(\.transcript), ["raw words"])
        XCTAssertEqual(harness.cleanupInputs, [])
        XCTAssertEqual(harness.insertedTexts, ["raw words"])
        XCTAssertEqual(harness.recordedHistory, [
            VoiceInputHistoryEvent(
                transcript: "raw words",
                finalText: "raw words",
                cleanupPromptModeID: nil,
                speechModel: VoiceInputConfig.defaultSpeechModel,
                cleanupFallback: false
            )
        ])
        XCTAssertEqual(harness.statuses, [.listening, .transcribing, .choosingPromptMode, .inserting, .idle])
    }

    func testStopWithAskEachTimeCancellationInsertsNothing() async {
        let harness = VoiceInputHarness(config: VoiceInputConfig(
            shortcut: .rightOption,
            speechProviderID: VoiceInputConfig.openAISpeechProviderID,
            speechEndpoint: VoiceInputConfig.defaultSpeechEndpoint,
            speechModel: VoiceInputConfig.defaultSpeechModel,
            microphoneDeviceID: nil,
            autoProcessTranscription: true,
            postTranscriptionAction: .askEachTime,
            voiceCleanupPromptModeID: PromptMode.voiceCleanupID
        ))
        harness.transcriptionText = "ignore this"
        harness.promptModeSelection = .cancelled

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.cleanupInputs, [])
        XCTAssertEqual(harness.insertedTexts, [])
        XCTAssertEqual(harness.recordedHistory, [])
        XCTAssertEqual(harness.statuses, [.listening, .transcribing, .choosingPromptMode, .idle])
    }

    func testCleanupFailureFallsBackToRawTranscription() async {
        let harness = VoiceInputHarness()
        harness.transcriptionText = "raw transcript"
        harness.cleanupError = TransformationError.provider("cleanup failed")

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.insertedTexts, ["raw transcript"])
        XCTAssertEqual(harness.statuses, [
            .listening,
            .transcribing,
            .polishing,
            .inserting,
            .fallbackInserted("Cleanup failed. Inserted transcription."),
            .idle
        ])
    }

    func testCleanupFallbackRecordsRawHistory() async {
        let harness = VoiceInputHarness()
        harness.transcriptionText = "raw transcript"
        harness.cleanupError = TransformationError.provider("cleanup failed")

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.recordedHistory, [
            VoiceInputHistoryEvent(
                transcript: "raw transcript",
                finalText: "raw transcript",
                cleanupPromptModeID: PromptMode.voiceCleanupID,
                speechModel: VoiceInputConfig.defaultSpeechModel,
                cleanupFallback: true
            )
        ])
    }

    func testAskEachTimeCleanupFallbackRecordsSelectedModeHistory() async {
        let harness = VoiceInputHarness(config: VoiceInputConfig(
            shortcut: .rightOption,
            speechProviderID: VoiceInputConfig.openAISpeechProviderID,
            speechEndpoint: VoiceInputConfig.defaultSpeechEndpoint,
            speechModel: VoiceInputConfig.defaultSpeechModel,
            microphoneDeviceID: nil,
            autoProcessTranscription: true,
            postTranscriptionAction: .askEachTime,
            voiceCleanupPromptModeID: PromptMode.voiceCleanupID
        ))
        harness.transcriptionText = "raw transcript"
        harness.cleanupError = TransformationError.provider("cleanup failed")
        harness.promptModeSelection = .promptMode(PromptMode.chineseSummaryID)

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.recordedHistory, [
            VoiceInputHistoryEvent(
                transcript: "raw transcript",
                finalText: "raw transcript",
                cleanupPromptModeID: PromptMode.chineseSummaryID,
                speechModel: VoiceInputConfig.defaultSpeechModel,
                cleanupFallback: true
            )
        ])
    }

    func testCleanupCancellationReturnsIdleWithoutInserting() async {
        let harness = VoiceInputHarness()
        harness.transcriptionText = "raw transcript"
        harness.cleanupError = CancellationError()

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.insertedTexts, [])
        XCTAssertEqual(harness.recordedHistory, [])
        XCTAssertEqual(harness.statuses, [.listening, .transcribing, .polishing, .idle])
    }

    func testMaintenanceInvalidationPreventsOrdinaryCleanupFailureFallbackInsertion() async {
        let harness = VoiceInputHarness()
        harness.transcriptionText = "raw transcript"
        harness.pauseCleanup = true
        harness.cleanupError = TransformationError.provider("cleanup failed")

        await harness.coordinator.start()
        let stopTask = Task {
            await harness.coordinator.stop()
        }
        await Task.yield()

        let maintenanceTask = Task {
            await harness.coordinator.cancelForMigrationMaintenance()
        }
        await Task.yield()

        harness.resumeCleanup()
        await stopTask.value
        await maintenanceTask.value

        XCTAssertEqual(harness.insertedTexts, [])
        XCTAssertEqual(harness.recordedHistory, [])
        XCTAssertTrue(harness.coordinator.isIdle)
        XCTAssertEqual(harness.statuses, [.listening, .transcribing, .polishing, .idle])
    }

    func testTranscriptionProviderFailureShowsShortError() async {
        let harness = VoiceInputHarness()
        harness.transcriptionError = SpeechTranscriptionError.provider(
            "OpenAI speech request failed: Invalid API key with a very long provider detail."
        )

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.insertedTexts, [])
        XCTAssertEqual(harness.statuses, [.listening, .transcribing, .error("Transcription failed. Please try again.")])
    }

    func testEmptyTranscriptionErrorKeepsSpecificShortMessage() async {
        let harness = VoiceInputHarness()
        harness.transcriptionError = SpeechTranscriptionError.emptyResponse

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.insertedTexts, [])
        XCTAssertEqual(harness.statuses, [.listening, .transcribing, .error("No speech was recognized.")])
    }

    func testEmptyTranscriptionInsertsNothing() async {
        let harness = VoiceInputHarness()
        harness.transcriptionText = "   "

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.insertedTexts, [])
        XCTAssertEqual(harness.statuses, [.listening, .transcribing, .error("No speech was recognized.")])
    }

    func testMissingTargetAppInsertsNothing() async {
        let harness = VoiceInputHarness(targetApplication: nil)
        harness.transcriptionText = "hello"

        await harness.coordinator.start()
        await harness.coordinator.stop()

        XCTAssertEqual(harness.insertedTexts, [])
        XCTAssertEqual(harness.statuses, [.listening, .transcribing, .polishing, .error("No target app is available.")])
    }
}

@MainActor
private final class VoiceInputHarness {
    var startRecordingCount = 0
    var stopRecordingCount = 0
    var cancelRecordingCount = 0
    var insertedTexts: [String] = []
    var cleanupInputs: [String] = []
    var cleanupModeIDs: [String] = []
    var promptModeSelectionRequests: [VoicePromptModeSelectionRequest] = []
    var recordedHistory: [VoiceInputHistoryEvent] = []
    var statuses: [VoiceInputStatus] = []
    var idleStateChanges: [Bool] = []
    var idleStateSnapshots: [Bool] = []
    var transcriptionText = "hello"
    var cleanedText = "Hello."
    var transcriptionError: Error?
    var cleanupError: Error?
    var promptModeSelection = VoicePromptModeSelection.promptMode(PromptMode.voiceCleanupID)
    var pauseStartRecording = false
    var pauseTranscription = false
    var pauseCancelRecording = false
    var pauseCleanup = false
    private var startRecordingContinuation: CheckedContinuation<Void, Never>?
    private var transcriptionContinuation: CheckedContinuation<Void, Never>?
    private var cancelRecordingContinuation: CheckedContinuation<Void, Never>?
    private var cleanupContinuation: CheckedContinuation<Void, Never>?

    var coordinator: VoiceInputCoordinator!

    init(
        config: VoiceInputConfig = VoiceInputConfig.defaultConfig(),
        targetApplication: NSRunningApplication? = .current
    ) {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-input-test")
            .appendingPathExtension("m4a")

        coordinator = VoiceInputCoordinator(
            configProvider: { config },
            targetApplicationProvider: { targetApplication },
            startRecording: { [weak self] in
                self?.startRecordingCount += 1
                if self?.pauseStartRecording == true {
                    await withCheckedContinuation { continuation in
                        self?.startRecordingContinuation = continuation
                    }
                }
            },
            stopRecording: { [weak self] in
                self?.stopRecordingCount += 1
                return audioURL
            },
            cancelRecording: { [weak self] in
                self?.cancelRecordingCount += 1
                if self?.pauseCancelRecording == true {
                    await withCheckedContinuation { continuation in
                        self?.cancelRecordingContinuation = continuation
                    }
                }
            },
            transcribe: { [weak self] _ in
                if self?.pauseTranscription == true {
                    await withCheckedContinuation { continuation in
                        self?.transcriptionContinuation = continuation
                    }
                }
                if let transcriptionError = self?.transcriptionError {
                    throw transcriptionError
                }
                return SpeechTranscriptionResult(text: self?.transcriptionText ?? "")
            },
            selectPromptMode: { [weak self] request in
                self?.promptModeSelectionRequests.append(request)
                return self?.promptModeSelection ?? .cancelled
            },
            cleanup: { [weak self] source, modeID in
                self?.cleanupInputs.append(source)
                self?.cleanupModeIDs.append(modeID)
                if self?.pauseCleanup == true {
                    await withCheckedContinuation { continuation in
                        self?.cleanupContinuation = continuation
                    }
                }
                if let cleanupError = self?.cleanupError {
                    throw cleanupError
                }
                return self?.cleanedText ?? source
            },
            insert: { [weak self] text, _ in
                self?.insertedTexts.append(text)
            },
            recordHistory: { [weak self] event in
                self?.recordedHistory.append(event)
            },
            statusHandler: { [weak self] status in
                self?.statuses.append(status)
            },
            idleStateHandler: { [weak self] isIdle in
                self?.idleStateChanges.append(isIdle)
                self?.idleStateSnapshots.append(self?.coordinator.isIdle ?? false)
            }
        )
    }

    func resetIdleStateObservations() {
        idleStateChanges = []
        idleStateSnapshots = []
    }

    func resumeStartRecording() {
        pauseStartRecording = false
        startRecordingContinuation?.resume()
        startRecordingContinuation = nil
    }

    func resumeTranscription() {
        pauseTranscription = false
        transcriptionContinuation?.resume()
        transcriptionContinuation = nil
    }

    func resumeCancelRecording() {
        pauseCancelRecording = false
        cancelRecordingContinuation?.resume()
        cancelRecordingContinuation = nil
    }

    func resumeCleanup() {
        pauseCleanup = false
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }
}
