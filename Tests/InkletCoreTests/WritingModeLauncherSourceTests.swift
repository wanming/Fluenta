import XCTest
@testable import InkletCore

final class WritingModeLauncherSourceTests: XCTestCase {
    func testPickerViewProvidesBoundedSearchableModeList() throws {
        let source = try pickerSource()

        XCTAssertTrue(source.contains("static let maxVisibleRows = 6"))
        XCTAssertTrue(source.contains("static let searchHeight: CGFloat = 46"))
        XCTAssertTrue(source.contains("static let rowHeight: CGFloat = 40"))
        XCTAssertTrue(source.contains("static let footerHeight: CGFloat = 36"))
        XCTAssertTrue(source.contains("struct WritingModeSearchField: NSViewRepresentable"))
        XCTAssertTrue(source.contains("NSSearchField"))
        XCTAssertTrue(source.contains("ScrollViewReader"))
        XCTAssertTrue(source.contains("model.highlightMode(modeID:"))
        XCTAssertTrue(source.contains("model.commitMode(modeID:"))
        XCTAssertTrue(source.contains("accessibilityAddTraits(.isSelected)"))
        XCTAssertTrue(source.contains(".help(item.title)"))
    }

    func testPickerSearchPreservesMarkedTextAndOwnsFocus() throws {
        let source = try pickerSource()

        XCTAssertTrue(source.contains("popover.modeSearch.placeholder"))
        XCTAssertTrue(source.contains("currentEditor"))
        XCTAssertTrue(source.contains("hasMarkedText"))
        XCTAssertTrue(source.contains("focusRevision"))
        XCTAssertTrue(source.contains("makeFirstResponder"))
        XCTAssertTrue(source.contains("controlTextDidChange"))
    }

    func testMouseHighlightSkipsOneScrollWithoutDisablingKeyboardScrolling() throws {
        let source = try pickerSource()
        let mouseHighlightStart = try XCTUnwrap(source.range(of: "private func highlightModeFromMouse"))
        let footerStart = try XCTUnwrap(source.range(
            of: "private var footer",
            range: mouseHighlightStart.upperBound..<source.endIndex
        ))
        let mouseHighlightBlock = source[mouseHighlightStart.lowerBound..<footerStart.lowerBound]
        let markerSet = try XCTUnwrap(mouseHighlightBlock.range(of: "mouseHighlightedModeID = modeID"))
        let modelHighlight = try XCTUnwrap(mouseHighlightBlock.range(of: "model.highlightMode(modeID: modeID)"))

        XCTAssertTrue(source.contains("@State private var mouseHighlightedModeID: String?"))
        XCTAssertLessThan(markerSet.lowerBound, modelHighlight.lowerBound)
        XCTAssertTrue(source.contains("if let mouseHighlightedModeID {"))
        XCTAssertTrue(source.contains("self.mouseHighlightedModeID = nil"))
        XCTAssertTrue(source.contains("if mouseHighlightedModeID == modeID {"))
        XCTAssertTrue(source.contains("withAnimation(.easeOut(duration: 0.08))"))
        XCTAssertTrue(mouseHighlightBlock.contains("DispatchQueue.main.asyncAfter("))
        XCTAssertTrue(mouseHighlightBlock.contains("deadline: .now() + NSEvent.doubleClickInterval"))
        XCTAssertFalse(mouseHighlightBlock.contains("DispatchQueue.main.async {"))
        XCTAssertTrue(mouseHighlightBlock.contains("mouseHighlightedModeID = nil"))
    }

    func testPickerRowsExposeNamedAccessibilityCommitAction() throws {
        let source = try pickerSource()
        let actionStart = try XCTUnwrap(source.range(
            of: ".accessibilityAction(named: L10n.text(\"popover.modeSearch.write\"))"
        ))
        let mouseHighlightStart = try XCTUnwrap(source.range(
            of: "private func highlightModeFromMouse",
            range: actionStart.upperBound..<source.endIndex
        ))
        let accessibilityBlock = source[actionStart.lowerBound..<mouseHighlightStart.lowerBound]

        XCTAssertTrue(accessibilityBlock.contains("model.commitMode(modeID: item.id)"))
    }

    func testPickerExposesLocalizedNavigationAndAccessibleSettings() throws {
        let source = try pickerSource()

        XCTAssertTrue(source.contains("popover.modeSearch.empty"))
        XCTAssertTrue(source.contains("popover.modeSearch.select"))
        XCTAssertTrue(source.contains("popover.modeSearch.write"))
        XCTAssertTrue(source.contains("popover.hint.close"))
        XCTAssertTrue(source.contains("Keycap(title: \"↑\", compact: true)"))
        XCTAssertTrue(source.contains("Keycap(title: \"↓\", compact: true)"))
        XCTAssertFalse(source.contains("footerHint(key: \"↑/↓\""))
        XCTAssertTrue(source.contains(".help(L10n.text(\"app.menu.settings\"))"))
        XCTAssertTrue(source.contains(".accessibilityLabel(L10n.text(\"app.menu.settings\"))"))
    }

    func testPopoverRoutesBetweenPickerAndEditorAtDeterministicHeights() throws {
        let source = try popoverSource()

        XCTAssertTrue(source.contains("switch model.route"))
        XCTAssertTrue(source.contains("case .modePicker:"))
        XCTAssertTrue(source.contains("WritingModePickerView(model: model)"))
        XCTAssertTrue(source.contains("case .editor:"))
        XCTAssertTrue(source.contains("editorContent"))
        XCTAssertTrue(source.contains("WritingModePickerView.preferredHeight"))
    }

    func testResetPublishesCurrentPickerHeightBeforeWindowDisplay() throws {
        let source = try popoverSource()
        let resetStart = try XCTUnwrap(source.range(of: "func resetForOpen"))
        let refreshStart = try XCTUnwrap(source.range(
            of: "private func refreshVoiceShortcutHint",
            range: resetStart.upperBound..<source.endIndex
        ))
        let resetBlock = source[resetStart.lowerBound..<refreshStart.lowerBound]

        XCTAssertTrue(resetBlock.contains("preferredPopoverHeight = WritingModePickerView.preferredHeight("))
        XCTAssertTrue(resetBlock.contains("resultCount: modePickerState.filteredItems.count"))
        XCTAssertFalse(resetBlock.contains("preferredPopoverHeight = 168"))
    }

    func testEditorCanReturnToPickerAndExplainsStaleResults() throws {
        let source = try popoverSource()

        XCTAssertTrue(source.contains("model.returnToModePicker()"))
        XCTAssertTrue(source.contains("popover.mode.backToModes"))
        XCTAssertTrue(source.contains("model.isResultStale"))
        XCTAssertTrue(source.contains("popover.result.generatedWith"))
        XCTAssertTrue(source.contains("popover.action.regenerate"))
        XCTAssertTrue(source.contains("writingModeIconName(for:"))
    }

    func testPopoverViewModelOwnsLauncherAndSessionState() throws {
        let source = try popoverSource()

        XCTAssertTrue(source.contains("@Published private(set) var modePickerState: WritingModePickerState"))
        XCTAssertTrue(source.contains("@Published private(set) var popoverSession: WritingPopoverSessionState"))
        XCTAssertTrue(source.contains("@Published private(set) var modeSearchFocusRevision = 0"))
        XCTAssertTrue(source.contains("@Published private(set) var modes: [PromptMode]"))
        XCTAssertTrue(source.contains("private let writingModePreferenceStore: WritingModePreferenceStore"))
        XCTAssertTrue(source.contains("func commitHighlightedMode()"))
        XCTAssertTrue(source.contains("func returnToModePicker()"))
        XCTAssertTrue(source.contains("writingModePreferenceStore.saveLastModeID"))
        XCTAssertFalse(source.contains("@Published var selectedModeID"))
        XCTAssertFalse(source.contains("@Published var openRevision"))
    }

    func testPopoverViewModelTracksAndPreservesStaleResults() throws {
        let source = try popoverSource()

        XCTAssertTrue(source.contains("var isResultStale: Bool"))
        XCTAssertTrue(source.contains("let preservesExistingResult = isResultStale"))
        XCTAssertTrue(source.contains("if !preservesExistingResult"))
        XCTAssertTrue(source.contains("recordResult(modeID: transformationModeID)"))
    }

    func testPopoverViewModelCanCancelTransformationWithoutClosingEditor() throws {
        let source = try popoverSource()

        XCTAssertTrue(source.contains("cancelTransformationAndStayInEditor"))
    }

    func testEscapeFromModePickerClosesDirectly() throws {
        let source = try popoverSource()
        let pickerEscapeStart = try XCTUnwrap(source.range(of: "if route == .modePicker {"))
        let editorEscapeStart = try XCTUnwrap(source.range(
            of: "\n        if !resultText.isEmpty {",
            range: pickerEscapeStart.upperBound..<source.endIndex
        ))
        let pickerEscapeBlock = source[pickerEscapeStart.lowerBound..<editorEscapeStart.lowerBound]

        XCTAssertTrue(pickerEscapeBlock.contains("handle(actions: stateMachine.send(.close))"))
        XCTAssertFalse(pickerEscapeBlock.contains("stateMachine.send(.escape)"))
    }

    func testPreservedFailureAndCancellationRestoreStateFromVisibleContent() throws {
        let source = try popoverSource()
        let transformationStart = try XCTUnwrap(source.range(of: "private func startTransformation"))
        let failureStart = try XCTUnwrap(source.range(
            of: "} catch {",
            range: transformationStart.upperBound..<source.endIndex
        ))
        let cancellationStart = try XCTUnwrap(source.range(
            of: "private func cancelTransformationAndStayInEditor",
            range: failureStart.upperBound..<source.endIndex
        ))
        let mutationHelperStart = try XCTUnwrap(source.range(
            of: "private func mutateModePickerState",
            range: cancellationStart.upperBound..<source.endIndex
        ))
        let failureBlock = source[failureStart.lowerBound..<cancellationStart.lowerBound]
        let cancellationBlock = source[cancellationStart.lowerBound..<mutationHelperStart.lowerBound]

        XCTAssertTrue(source.contains("private func synchronizeStateMachineWithVisibleContent()"))
        XCTAssertTrue(source.contains(".previewingResult(source: sourceText, result: resultText)"))
        XCTAssertTrue(source.contains(".editingSource(source: sourceText, errorMessage: nil)"))
        XCTAssertTrue(failureBlock.contains("if preservesExistingResult"))
        XCTAssertTrue(failureBlock.contains("\n                    synchronizeStateMachineWithVisibleContent()\n"))
        XCTAssertTrue(cancellationBlock.contains("\n        synchronizeStateMachineWithVisibleContent()\n"))
    }

    func testReselectingPreservedResultsModeMakesSubmitInsertVisibleResult() {
        let source = "Draft"
        let oldResult = "Old result"
        let oldModeID = "old-mode"
        var session = WritingPopoverSessionState(
            selectedModeID: oldModeID,
            route: .editor
        )
        session.recordResult(modeID: oldModeID)
        session.enterEditor(modeID: "new-mode")

        let failedMachine = PopoverStateMachine(state: .transforming(source: source))
        XCTAssertEqual(
            failedMachine.send(.transformationFailed(message: "Offline")),
            [.showError("Offline"), .focusSourceInput]
        )

        let restoredMachine = PopoverStateMachine(
            state: .previewingResult(source: source, result: oldResult)
        )
        session.enterEditor(modeID: oldModeID)

        XCTAssertFalse(session.isResultStale)
        let actions = restoredMachine.send(.submit)
        XCTAssertEqual(actions, [.insertText(oldResult)])
        XCTAssertFalse(actions.contains(.startTransformation(source: source)))
    }

    func testRetryingWhileResultIsStillStaleStartsTransformation() {
        let source = "Draft"
        let oldResult = "Old result"
        var session = WritingPopoverSessionState(
            selectedModeID: "old-mode",
            route: .editor
        )
        session.recordResult(modeID: "old-mode")
        session.enterEditor(modeID: "new-mode")
        let restoredMachine = PopoverStateMachine(
            state: .previewingResult(source: source, result: oldResult)
        )

        XCTAssertTrue(session.isResultStale)
        XCTAssertEqual(restoredMachine.send(.sourceChanged(source)), [])
        let actions = restoredMachine.send(.submit)
        XCTAssertEqual(actions, [.startTransformation(source: source)])
        XCTAssertFalse(actions.contains(.insertText(oldResult)))
    }

    private func popoverSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/InkletPopoverView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func pickerSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/WritingModePickerView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
