import AppKit
import XCTest
@testable import Inklet
@testable import InkletCore

@MainActor
final class WritingPopoverDictationViewModelTests: XCTestCase {
    func testCurrentVoiceConfigAndShortcutHintUseFrozenLoadedConfig() throws {
        let harness = try makeHarness(shortcut: .rightCommand)
        let originalConfig = harness.model.currentVoiceInputConfig

        XCTAssertEqual(originalConfig.shortcut, .rightCommand)
        XCTAssertEqual(harness.model.voiceShortcutHint, .rightCommand)
        XCTAssertTrue(harness.model.shouldShowDictationStatus)

        var updated = try harness.configStore.load()
        updated.voiceInput.shortcut = .disabled
        try harness.configStore.save(updated)

        XCTAssertEqual(harness.model.currentVoiceInputConfig, originalConfig)
        XCTAssertEqual(harness.model.voiceShortcutHint, .rightCommand)
    }

    func testDictationStatusIsHiddenOnlyWhenShortcutIsDisabledAndPhaseIsInactive() throws {
        let harness = try makeHarness(shortcut: .disabled)

        XCTAssertEqual(harness.model.dictationPhase, .idle)
        XCTAssertFalse(harness.model.shouldShowDictationStatus)

        harness.model.setDictationPhase(.connecting)

        XCTAssertTrue(harness.model.shouldShowDictationStatus)
        XCTAssertTrue(harness.model.isBusy)
        XCTAssertEqual(
            harness.model.dictationStatusText,
            L10n.text("dictation.status.connecting")
        )

        harness.model.setDictationPhase(.recordingForFallback)
        XCTAssertEqual(
            harness.model.dictationStatusText,
            L10n.text("dictation.status.recordingFallback")
        )

        harness.model.setDictationPhase(.complete)

        XCTAssertFalse(harness.model.shouldShowDictationStatus)
        XCTAssertFalse(harness.model.isBusy)
    }

    func testBeginRequiresIdleEditorAndSinglePresentationSnapshot() throws {
        let harness = try makeHarness()

        XCTAssertFalse(harness.model.beginSourceDictationPresentation())

        enterEditor(harness.model)
        harness.model.isTransforming = true
        XCTAssertFalse(harness.model.beginSourceDictationPresentation())

        harness.model.isTransforming = false
        XCTAssertTrue(harness.model.beginSourceDictationPresentation())
        XCTAssertFalse(harness.model.beginSourceDictationPresentation())
    }

    func testProvisionalSourcePreservesVisibleResultAndProducingModeIdentity() async throws {
        let harness = try makeHarness(output: "Original result")
        try await prepareVisibleResult(in: harness.model)
        let originalResultMode = harness.model.popoverSession.resultModeID
        harness.model.errorMessage = "Previous error"

        XCTAssertTrue(harness.model.beginSourceDictationPresentation())
        XCTAssertNil(harness.model.errorMessage)

        harness.model.synchronizeSourceTextDuringDictation("Provisional source")

        XCTAssertEqual(harness.model.sourceText, "Provisional source")
        XCTAssertEqual(harness.model.resultText, "Original result")
        XCTAssertEqual(harness.model.popoverSession.resultModeID, originalResultMode)
        XCTAssertNotNil(originalResultMode)
    }

    func testFinalCommitInvalidatesOldResultExactlyOnce() async throws {
        let harness = try makeHarness(output: "Original result")
        try await prepareVisibleResult(in: harness.model)
        harness.model.errorMessage = "Previous error"

        XCTAssertTrue(harness.model.beginSourceDictationPresentation())
        harness.model.synchronizeSourceTextDuringDictation("Final source")
        harness.model.commitSourceDictationPresentation()

        XCTAssertEqual(harness.model.sourceText, "Final source")
        XCTAssertEqual(harness.model.resultText, "")
        XCTAssertNil(harness.model.errorMessage)
        XCTAssertNil(harness.model.popoverSession.resultModeID)
        XCTAssertEqual(harness.model.route, .editor)

        harness.model.submit()
        XCTAssertTrue(harness.model.isTransforming)
        harness.model.escape()
        XCTAssertFalse(harness.model.isTransforming)

        harness.model.resultText = "Newer result"
        harness.model.commitSourceDictationPresentation()

        XCTAssertEqual(harness.model.resultText, "Newer result")

        harness.model.returnToModePicker()
        harness.model.escape()
        harness.model.resetForOpen(previousApplication: nil)
        XCTAssertEqual(harness.model.sourceText, "Final source")
    }

    func testRestoreReturnsExactVisibleSessionAndStateMachineSnapshot() async throws {
        let harness = try makeHarness(output: "Original result")
        try await prepareVisibleResult(in: harness.model)
        let originalSession = harness.model.popoverSession
        harness.model.errorMessage = "Previous error"

        XCTAssertTrue(harness.model.beginSourceDictationPresentation())
        harness.model.synchronizeSourceTextDuringDictation("Temporary source")
        harness.model.restoreSourceDictationPresentation()

        XCTAssertEqual(harness.model.sourceText, "Original source")
        XCTAssertEqual(harness.model.resultText, "Original result")
        XCTAssertEqual(harness.model.errorMessage, "Previous error")
        XCTAssertEqual(harness.model.popoverSession, originalSession)

        harness.model.submit()
        XCTAssertTrue(harness.model.isInserting == false)
        XCTAssertEqual(harness.model.errorMessage, L10n.text("popover.error.missingTarget"))
    }

    func testFailedPhasePublishesLocalizedErrorAfterRestoration() async throws {
        let harness = try makeHarness(output: "Original result")
        try await prepareVisibleResult(in: harness.model)
        harness.model.errorMessage = "Previous error"

        XCTAssertTrue(harness.model.beginSourceDictationPresentation())
        harness.model.synchronizeSourceTextDuringDictation("Temporary source")
        harness.model.restoreSourceDictationPresentation()
        harness.model.setDictationPhase(.failed("dictation.error.noSpeech"))

        XCTAssertEqual(harness.model.sourceText, "Original source")
        XCTAssertEqual(harness.model.resultText, "Original result")
        XCTAssertEqual(harness.model.errorMessage, L10n.text("dictation.error.noSpeech"))
    }

    func testCancellationRestoresPreviousError() throws {
        let harness = try makeHarness()
        enterEditor(harness.model)
        harness.model.updateSourceText("Original source")
        harness.model.errorMessage = "Previous error"

        XCTAssertTrue(harness.model.beginSourceDictationPresentation())
        harness.model.synchronizeSourceTextDuringDictation("Temporary source")
        harness.model.restoreSourceDictationPresentation()
        harness.model.setDictationPhase(.idle)

        XCTAssertEqual(harness.model.sourceText, "Original source")
        XCTAssertEqual(harness.model.errorMessage, "Previous error")
    }

    func testActiveDictationBlocksEveryEditorActionAndOrdinaryTyping() throws {
        let harness = try makeHarness()
        enterEditor(harness.model)
        harness.model.updateSourceText("Original source")
        harness.model.resultText = "Visible result"
        let originalModeID = harness.model.selectedModeID
        let otherModeID = try XCTUnwrap(
            harness.model.modes.first(where: { $0.id != originalModeID })?.id
        )
        var hideCount = 0
        var settingsCount = 0
        harness.model.onHidePopover = { hideCount += 1 }
        harness.model.onOpenSettings = { settingsCount += 1 }

        XCTAssertTrue(harness.model.beginSourceDictationPresentation())
        harness.model.setDictationPhase(.listening)
        harness.model.updateSourceText("Typed source")
        harness.model.updateResultText("Typed result")
        harness.model.submit()
        harness.model.insertOriginal()
        harness.model.commitMode(modeID: otherModeID)
        harness.model.cyclePromptMode(direction: 1)
        harness.model.returnToModePicker()
        harness.model.openSettings()

        XCTAssertEqual(harness.model.sourceText, "Original source")
        XCTAssertEqual(harness.model.resultText, "Visible result")
        XCTAssertEqual(harness.model.selectedModeID, originalModeID)
        XCTAssertEqual(harness.model.route, .editor)
        XCTAssertEqual(hideCount, 0)
        XCTAssertEqual(settingsCount, 0)
        XCTAssertFalse(harness.model.isTransforming)
        XCTAssertFalse(harness.model.isInserting)
    }

    func testActiveDictationBlocksEveryModePickerStateMutation() throws {
        let harness = try makeHarness()
        enterEditor(harness.model)
        let originalPickerState = harness.model.modePickerState
        let otherModeID = try XCTUnwrap(
            harness.model.modes.last(where: {
                $0.id != originalPickerState.highlightedModeID
            })?.id
        )

        XCTAssertTrue(harness.model.beginSourceDictationPresentation())
        harness.model.setDictationPhase(.listening)

        harness.model.updateModeSearchQuery("no matching writing mode")
        XCTAssertEqual(harness.model.modePickerState, originalPickerState)

        harness.model.moveModeHighlight(by: 1)
        XCTAssertEqual(harness.model.modePickerState, originalPickerState)

        harness.model.highlightMode(modeID: otherModeID)
        XCTAssertEqual(harness.model.modePickerState, originalPickerState)
    }

    func testEscapeCancelsActiveDictationOnceBeforeClearingResultOrNavigating() throws {
        let harness = try makeHarness()
        enterEditor(harness.model)
        harness.model.updateSourceText("Original source")
        harness.model.resultText = "Visible result"
        var cancelCount = 0
        harness.model.onCancelDictation = { cancelCount += 1 }

        XCTAssertTrue(harness.model.beginSourceDictationPresentation())
        harness.model.setDictationPhase(.listening)
        harness.model.escape()

        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(harness.model.route, .editor)
        XCTAssertEqual(harness.model.resultText, "Visible result")
    }

    func testSourceBridgeEligibilityRequiresExactSourceFirstResponder() throws {
        let harness = try makeHarness()
        enterEditor(harness.model)
        let window = AlwaysKeyWindow()
        let sourceTextView = MarkedTextView()
        let otherTextView = NSTextView()
        let contentView = NSView()
        contentView.addSubview(sourceTextView)
        contentView.addSubview(otherTextView)
        window.contentView = contentView
        let bridge = WritingSourceEditorBridge()
        bridge.attach(sourceTextView)

        XCTAssertTrue(window.makeFirstResponder(sourceTextView))
        XCTAssertTrue(bridge.isEligible(in: window, model: harness.model))

        window.reportsKeyWindow = false
        XCTAssertFalse(bridge.isEligible(in: window, model: harness.model))
        window.reportsKeyWindow = true

        sourceTextView.reportsMarkedText = true
        XCTAssertFalse(bridge.isEligible(in: window, model: harness.model))
        sourceTextView.reportsMarkedText = false

        XCTAssertTrue(window.makeFirstResponder(otherTextView))
        XCTAssertFalse(bridge.isEligible(in: window, model: harness.model))

        XCTAssertTrue(window.makeFirstResponder(sourceTextView))
        harness.model.setDictationPhase(.connecting)
        XCTAssertFalse(bridge.isEligible(in: window, model: harness.model))

        harness.model.setDictationPhase(.idle)
        harness.model.returnToModePicker()
        XCTAssertFalse(bridge.isEligible(in: window, model: harness.model))

        bridge.detach(sourceTextView)
        XCTAssertNil(bridge.attachedTextView)
    }

    func testSourceBridgeRestoresSnapshotWhenTransactionCreationFails() throws {
        let harness = try makeHarness()
        enterEditor(harness.model)
        harness.model.updateSourceText("Original source")
        harness.model.errorMessage = "Previous error"
        let window = AlwaysKeyWindow()
        let textView = NSTextView()
        window.contentView = textView
        XCTAssertTrue(window.makeFirstResponder(textView))
        let bridge = WritingSourceEditorBridge(transactionFactory: { _, _, _, _ in nil })
        bridge.attach(textView)

        XCTAssertNil(bridge.beginTransaction(model: harness.model))
        XCTAssertEqual(harness.model.sourceText, "Original source")
        XCTAssertEqual(harness.model.errorMessage, "Previous error")
        XCTAssertTrue(harness.model.beginSourceDictationPresentation())
    }

    private func makeHarness(
        shortcut: VoiceInputConfig.Shortcut = .rightOption,
        output: String = "Result"
    ) throws -> WritingPopoverDictationHarness {
        let identifier = "WritingPopoverDictation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        defaults.removePersistentDomain(forName: identifier)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(identifier, isDirectory: true)
        let configStore = UserDefaultsConfigStore(userDefaults: defaults)
        var config = AppConfig.defaultConfig()
        config.voiceInput.shortcut = shortcut
        try configStore.save(config)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: root)
        }
        let model = InkletPopoverViewModel(
            configStore: configStore,
            transformationServiceFactory: { _ in
                TransformationService(provider: ImmediateWritingProvider(output: output))
            },
            historyStore: JSONLHistoryStore(fileURL: root.appendingPathComponent("history.jsonl")),
            writingModePreferenceStore: WritingModePreferenceStore(userDefaults: defaults)
        )
        model.resetForOpen(previousApplication: nil)
        return WritingPopoverDictationHarness(model: model, configStore: configStore)
    }

    private func enterEditor(_ model: InkletPopoverViewModel) {
        model.commitMode(modeID: model.selectedModeID)
        XCTAssertEqual(model.route, .editor)
    }

    private func prepareVisibleResult(in model: InkletPopoverViewModel) async throws {
        enterEditor(model)
        model.updateSourceText("Original source")
        model.submit()
        for _ in 0..<200 where model.isTransforming {
            await Task.yield()
        }
        XCTAssertFalse(model.isTransforming)
        XCTAssertEqual(model.resultText, "Original result")
        XCTAssertNotNil(model.popoverSession.resultModeID)
    }
}

private struct WritingPopoverDictationHarness {
    let model: InkletPopoverViewModel
    let configStore: UserDefaultsConfigStore
}

private struct ImmediateWritingProvider: LLMProvider {
    let output: String

    func transform(_ request: TransformationRequest) async throws -> TransformationResult {
        TransformationResult(
            outputText: output,
            providerMetadata: [:],
            elapsedMilliseconds: 1
        )
    }
}

private final class AlwaysKeyWindow: NSWindow {
    var reportsKeyWindow = true

    override var isKeyWindow: Bool { reportsKeyWindow }
}

private final class MarkedTextView: NSTextView {
    var reportsMarkedText = false

    override func hasMarkedText() -> Bool {
        reportsMarkedText
    }
}
