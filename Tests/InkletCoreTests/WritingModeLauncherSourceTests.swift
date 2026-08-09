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

    func testPickerSearchFocusRetriesOnlyCurrentRevisionAndDeactivatesOnDismantle() throws {
        let source = try pickerSource()
        let searchFieldStart = try XCTUnwrap(source.range(of: "private struct WritingModeSearchField"))
        let searchFieldSource = source[searchFieldStart.lowerBound...]
        let updateStart = try XCTUnwrap(searchFieldSource.range(of: "func updateNSView"))
        let dismantleStart = try XCTUnwrap(searchFieldSource.range(
            of: "static func dismantleNSView",
            range: updateStart.upperBound..<searchFieldSource.endIndex
        ))
        let coordinatorStart = try XCTUnwrap(searchFieldSource.range(
            of: "final class Coordinator",
            range: dismantleStart.upperBound..<searchFieldSource.endIndex
        ))
        let updateBlock = searchFieldSource[updateStart.lowerBound..<dismantleStart.lowerBound]
        let dismantleBlock = searchFieldSource[dismantleStart.lowerBound..<coordinatorStart.lowerBound]
        let coordinatorBlock = searchFieldSource[coordinatorStart.lowerBound...]
        let makeFirstResponder = try XCTUnwrap(coordinatorBlock.range(of: "makeFirstResponder(searchField)"))
        let markSuccessful = try XCTUnwrap(coordinatorBlock.range(
            of: "focusedRevision = revision",
            range: makeFirstResponder.upperBound..<coordinatorBlock.endIndex
        ))

        XCTAssertTrue(updateBlock.contains("context.coordinator.requestFocus("))
        XCTAssertTrue(updateBlock.contains("revision: focusRevision"))
        XCTAssertTrue(dismantleBlock.contains("coordinator.deactivate()"))
        XCTAssertTrue(coordinatorBlock.contains("requestedFocusRevision"))
        XCTAssertTrue(coordinatorBlock.contains("pendingFocusRevision"))
        XCTAssertTrue(coordinatorBlock.contains("isActive"))
        XCTAssertTrue(coordinatorBlock.contains("requestedFocusRevision == revision"))
        XCTAssertTrue(coordinatorBlock.contains("pendingFocusRevision == revision"))
        XCTAssertTrue(coordinatorBlock.contains("remainingRetries"))
        XCTAssertTrue(coordinatorBlock.contains("DispatchQueue.main.async"))
        XCTAssertTrue(coordinatorBlock.contains("self.attemptFocus("))
        XCTAssertLessThan(makeFirstResponder.lowerBound, markSuccessful.lowerBound)
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

    func testPopoverKeyHandlerReceivesRouteAwareModeActionsAndRefreshesCoordinator() throws {
        let source = try popoverSource()
        let handlerCallStart = try XCTUnwrap(source.range(of: "PopoverKeyEventHandler("))
        let handlerCallEnd = try XCTUnwrap(source.range(
            of: "\n        .frame(",
            range: handlerCallStart.upperBound..<source.endIndex
        ))
        let handlerCall = source[handlerCallStart.lowerBound..<handlerCallEnd.lowerBound]
        let handlerStart = try XCTUnwrap(source.range(of: "private struct PopoverKeyEventHandler"))
        let updateStart = try XCTUnwrap(source.range(
            of: "func updateNSView",
            range: handlerStart.upperBound..<source.endIndex
        ))
        let dismantleStart = try XCTUnwrap(source.range(
            of: "static func dismantleNSView",
            range: updateStart.upperBound..<source.endIndex
        ))
        let updateBlock = source[updateStart.lowerBound..<dismantleStart.lowerBound]

        XCTAssertTrue(handlerCall.contains("route: model.route"))
        XCTAssertTrue(handlerCall.contains("onMoveModeHighlight: { model.moveModeHighlight(by: $0) }"))
        XCTAssertTrue(handlerCall.contains("onCommitMode: { model.commitHighlightedMode() }"))
        XCTAssertTrue(source[handlerStart.lowerBound...].contains("let route: WritingPopoverSessionState.Route"))
        XCTAssertTrue(source[handlerStart.lowerBound...].contains("let onMoveModeHighlight: (Int) -> Void"))
        XCTAssertTrue(source[handlerStart.lowerBound...].contains("let onCommitMode: () -> Void"))
        XCTAssertTrue(updateBlock.contains("context.coordinator.route = route"))
        XCTAssertTrue(updateBlock.contains("context.coordinator.onMoveModeHighlight = onMoveModeHighlight"))
        XCTAssertTrue(updateBlock.contains("context.coordinator.onCommitMode = onCommitMode"))
    }

    func testPopoverKeyHandlerDelegatesToExecutableKeyboardPolicy() throws {
        let source = try popoverSource()
        let handlerStart = try XCTUnwrap(source.range(of: "private struct PopoverKeyEventHandler"))
        let handleStart = try XCTUnwrap(source.range(
            of: "private func handle(_ event: NSEvent)",
            range: handlerStart.upperBound..<source.endIndex
        ))
        let composingStart = try XCTUnwrap(source.range(
            of: "private var isComposingText",
            range: handleStart.upperBound..<source.endIndex
        ))
        let handleBlock = source[handleStart.lowerBound..<composingStart.lowerBound]
        let modifierHelperStart = try XCTUnwrap(source.range(
            of: "private func keyboardModifiers",
            range: composingStart.upperBound..<source.endIndex
        ))
        let modifierHelper = source[modifierHelperStart.lowerBound...]

        XCTAssertTrue(handleBlock.contains("WritingPopoverKeyboardPolicy.action("))
        XCTAssertTrue(handleBlock.contains("route: route"))
        XCTAssertTrue(handleBlock.contains("keyCode: event.keyCode"))
        XCTAssertTrue(handleBlock.contains("isComposingText: isComposingText"))
        XCTAssertTrue(handleBlock.contains("switch action"))
        XCTAssertTrue(handleBlock.contains("case .passThrough:"))
        XCTAssertTrue(handleBlock.contains("case .consume:"))
        XCTAssertTrue(handleBlock.contains("case .escape:"))
        XCTAssertTrue(handleBlock.contains("case .moveHighlight(let offset):"))
        XCTAssertTrue(handleBlock.contains("case .commitMode:"))
        XCTAssertTrue(handleBlock.contains("case .cycleMode(let direction):"))
        XCTAssertTrue(handleBlock.contains("case .submit:"))
        XCTAssertTrue(handleBlock.contains("case .insertOriginal:"))
        for modifier in ["command", "shift", "option", "control"] {
            XCTAssertTrue(modifierHelper.contains("modifiers.contains(.\(modifier))"))
        }
        XCTAssertFalse(handleBlock.contains("event.keyCode =="))
    }

    func testPopoverPanelLetsIMEOwnEscapeFallbacks() throws {
        let source = try windowControllerSource()
        let cancelStart = try XCTUnwrap(source.range(of: "override func cancelOperation"))
        let keyDownStart = try XCTUnwrap(source.range(
            of: "override func keyDown(with event: NSEvent)",
            range: cancelStart.upperBound..<source.endIndex
        ))
        let compositionStart = try XCTUnwrap(source.range(
            of: "private var isComposingText",
            range: keyDownStart.upperBound..<source.endIndex
        ))
        let hostingViewStart = try XCTUnwrap(source.range(
            of: "private final class ClearHostingView",
            range: compositionStart.upperBound..<source.endIndex
        ))
        let cancelBlock = source[cancelStart.lowerBound..<keyDownStart.lowerBound]
        let keyDownBlock = source[keyDownStart.lowerBound..<compositionStart.lowerBound]
        let compositionBlock = source[compositionStart.lowerBound..<hostingViewStart.lowerBound]

        XCTAssertTrue(cancelBlock.contains("guard !isComposingText else"))
        XCTAssertTrue(cancelBlock.contains("super.cancelOperation(sender)"))
        XCTAssertTrue(cancelBlock.contains("onEscape?()"))
        XCTAssertTrue(keyDownBlock.contains("guard !isComposingText else"))
        XCTAssertTrue(keyDownBlock.contains("super.keyDown(with: event)"))
        XCTAssertTrue(keyDownBlock.contains("onEscape?()"))
        XCTAssertTrue(compositionBlock.contains("firstResponder as? NSTextInputClient"))
        XCTAssertTrue(compositionBlock.contains("hasMarkedText()"))
    }

    func testViewModelScopesSourceFocusRequestsToCurrentEditorGeneration() throws {
        let source = try popoverSource()
        let resetStart = try XCTUnwrap(source.range(of: "func resetForOpen"))
        let refreshStart = try XCTUnwrap(source.range(
            of: "private func refreshVoiceShortcutHint",
            range: resetStart.upperBound..<source.endIndex
        ))
        let resetBlock = source[resetStart.lowerBound..<refreshStart.lowerBound]
        let commitStart = try XCTUnwrap(source.range(of: "func commitMode(modeID:"))
        let returnStart = try XCTUnwrap(source.range(
            of: "func returnToModePicker",
            range: commitStart.upperBound..<source.endIndex
        ))
        let cycleStart = try XCTUnwrap(source.range(
            of: "func cyclePromptMode",
            range: returnStart.upperBound..<source.endIndex
        ))
        let commitBlock = source[commitStart.lowerBound..<returnStart.lowerBound]
        let returnBlock = source[returnStart.lowerBound..<cycleStart.lowerBound]
        let focusActionStart = try XCTUnwrap(source.range(of: "case .focusSourceInput:"))
        let transformationActionStart = try XCTUnwrap(source.range(
            of: "case .startTransformation",
            range: focusActionStart.upperBound..<source.endIndex
        ))
        let focusActionBlock = source[focusActionStart.lowerBound..<transformationActionStart.lowerBound]

        XCTAssertTrue(source.contains("private var sourceFocusGeneration = FocusRequestGeneration()"))
        XCTAssertTrue(source.contains("var onFocusSourceInput: ((FocusRequestGeneration.Request) -> Void)?"))
        XCTAssertTrue(resetBlock.contains("invalidateSourceInputFocusRequests()"))
        XCTAssertTrue(commitBlock.contains("requestSourceInputFocus()"))
        XCTAssertFalse(commitBlock.contains("DispatchQueue.main.async"))
        XCTAssertTrue(returnBlock.contains("invalidateSourceInputFocusRequests()"))
        XCTAssertTrue(focusActionBlock.contains("requestSourceInputFocus()"))
        XCTAssertTrue(source.contains("let request = sourceFocusGeneration.issue()"))
        XCTAssertTrue(source.contains("onFocusSourceInput?(request)"))
        XCTAssertTrue(source.contains("sourceFocusGeneration.isCurrent(request)"))
    }

    func testPopoverShowLeavesSearchFocusedUntilModelRequestsSourceInput() throws {
        let source = try windowControllerSource()
        let showStart = try XCTUnwrap(source.range(of: "func show(fallbackApplication:"))
        let hideStart = try XCTUnwrap(source.range(
            of: "\n    func hide()",
            range: showStart.upperBound..<source.endIndex
        ))
        let showBlock = source[showStart.lowerBound..<hideStart.lowerBound]
        let focusCallbackStart = try XCTUnwrap(source.range(of: "model.onFocusSourceInput = { [weak self] request in"))
        let requiredInitStart = try XCTUnwrap(source.range(
            of: "@available(*, unavailable)",
            range: focusCallbackStart.upperBound..<source.endIndex
        ))
        let focusCallbackBlock = source[focusCallbackStart.lowerBound..<requiredInitStart.lowerBound]
        let focusMethodStart = try XCTUnwrap(source.range(of: "private func focusSourceTextView("))
        let resizeStart = try XCTUnwrap(source.range(
            of: "private func resizePopover",
            range: focusMethodStart.upperBound..<source.endIndex
        ))
        let focusMethodBlock = source[focusMethodStart.lowerBound..<resizeStart.lowerBound]
        let makeFirstResponder = try XCTUnwrap(focusMethodBlock.range(of: "window.makeFirstResponder(textView)"))
        let responderFailureStart = try XCTUnwrap(focusMethodBlock.range(
            of: "guard window.makeFirstResponder(textView) else",
            range: focusMethodBlock.startIndex..<focusMethodBlock.endIndex
        ))
        let responderFailureBlock = focusMethodBlock[responderFailureStart.lowerBound...]
        let finalRouteCheck = try XCTUnwrap(focusMethodBlock.range(
            of: "model.route == .editor",
            options: .backwards,
            range: focusMethodBlock.startIndex..<makeFirstResponder.lowerBound
        ))
        let finalGenerationCheck = try XCTUnwrap(focusMethodBlock.range(
            of: "model.isCurrentSourceFocusRequest(request)",
            options: .backwards,
            range: focusMethodBlock.startIndex..<makeFirstResponder.lowerBound
        ))

        XCTAssertFalse(showBlock.contains("focusSourceTextView()"))
        XCTAssertTrue(focusCallbackBlock.contains("self?.focusSourceTextView(for: request)"))
        XCTAssertTrue(focusMethodBlock.contains("remainingRetries: Int = 2"))
        XCTAssertTrue(focusMethodBlock.contains("DispatchQueue.main.async"))
        XCTAssertTrue(focusMethodBlock.contains("remainingRetries - 1"))
        XCTAssertTrue(focusMethodBlock.contains("focusSourceTextView("))
        XCTAssertTrue(focusMethodBlock.contains("window.isVisible"))
        XCTAssertTrue(focusMethodBlock.contains("window.isKeyWindow"))
        XCTAssertTrue(responderFailureBlock.contains("remainingRetries - 1"))
        XCTAssertTrue(responderFailureBlock.contains("focusSourceTextView("))
        XCTAssertLessThan(finalRouteCheck.lowerBound, makeFirstResponder.lowerBound)
        XCTAssertLessThan(finalGenerationCheck.lowerBound, makeFirstResponder.lowerBound)
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

    func testNoResultsModeCommitStopsAtViewModelBoundary() throws {
        let source = try popoverSource()
        let highlightedCommitStart = try XCTUnwrap(source.range(of: "func commitHighlightedMode()"))
        let explicitCommitStart = try XCTUnwrap(source.range(
            of: "func commitMode(modeID:",
            range: highlightedCommitStart.upperBound..<source.endIndex
        ))
        let highlightedCommitBlock = source[
            highlightedCommitStart.lowerBound..<explicitCommitStart.lowerBound
        ]

        XCTAssertTrue(highlightedCommitBlock.contains("guard let highlightedModeID"))
        XCTAssertTrue(highlightedCommitBlock.contains("else {\n            return\n        }"))
        XCTAssertTrue(highlightedCommitBlock.contains("commitMode(modeID: highlightedModeID)"))
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

    private func windowControllerSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent(
            "Sources/InkletApp/InkletPopoverWindowController.swift"
        )
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
