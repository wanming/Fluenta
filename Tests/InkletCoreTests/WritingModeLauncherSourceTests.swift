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

    func testNativeEditorRoutesEscapeFromFirstResponderWithoutStealingIME() throws {
        let source = try popoverSource()
        let nativeTextViewStart = try XCTUnwrap(source.range(
            of: "private final class InkletNativeTextView"
        ))
        let representableStart = try XCTUnwrap(source.range(
            of: "private struct InkletTextView",
            range: nativeTextViewStart.upperBound..<source.endIndex
        ))
        let nativeTextViewBlock = source[nativeTextViewStart.lowerBound..<representableStart.lowerBound]
        let makeNSViewStart = try XCTUnwrap(source.range(
            of: "func makeNSView(context: Context) -> InkletTextContainerView",
            range: representableStart.upperBound..<source.endIndex
        ))
        let updateNSViewStart = try XCTUnwrap(source.range(
            of: "func updateNSView",
            range: makeNSViewStart.upperBound..<source.endIndex
        ))
        let makeNSViewBlock = source[makeNSViewStart.lowerBound..<updateNSViewStart.lowerBound]

        XCTAssertTrue(nativeTextViewBlock.contains("var onEscapeKeyDown: (() -> Void)?"))
        XCTAssertTrue(nativeTextViewBlock.contains("override func keyDown(with event: NSEvent)"))
        XCTAssertTrue(nativeTextViewBlock.contains("event.keyCode == 53"))
        XCTAssertTrue(nativeTextViewBlock.contains("!hasMarkedText()"))
        XCTAssertTrue(nativeTextViewBlock.contains("onEscapeKeyDown?()"))
        XCTAssertTrue(nativeTextViewBlock.contains("super.keyDown(with: event)"))
        XCTAssertTrue(makeNSViewBlock.contains("textView.onEscapeKeyDown ="))
        XCTAssertTrue(makeNSViewBlock.contains("coordinator?.onEscape?()"))
    }

    func testOnlySourceEditorRegistersTheResolvedNativeTextView() throws {
        let source = try popoverSource()
        let commandStart = try XCTUnwrap(source.range(of: "private var commandInput"))
        let resultStart = try XCTUnwrap(source.range(
            of: "private var resultPanel",
            range: commandStart.upperBound..<source.endIndex
        ))
        let statusStart = try XCTUnwrap(source.range(
            of: "private var statusStrip",
            range: resultStart.upperBound..<source.endIndex
        ))
        let commandBlock = source[commandStart.lowerBound..<resultStart.lowerBound]
        let resultBlock = source[resultStart.lowerBound..<statusStart.lowerBound]

        XCTAssertTrue(commandBlock.contains("onTextViewAttachment:"))
        XCTAssertTrue(commandBlock.contains("onTextViewAttachment: onSourceTextViewAttachment"))
        XCTAssertTrue(resultBlock.contains("onTextViewAttachment: nil"))
        XCTAssertFalse(resultBlock.contains("onSourceTextViewAttachment"))
    }

    func testNativeTextViewResolutionTracksMakeUpdateAndDismantle() throws {
        let source = try popoverSource()
        let representableStart = try XCTUnwrap(source.range(of: "private struct InkletTextView"))
        let handlerStart = try XCTUnwrap(source.range(
            of: "private struct PopoverKeyEventHandler",
            range: representableStart.upperBound..<source.endIndex
        ))
        let representable = source[representableStart.lowerBound..<handlerStart.lowerBound]

        XCTAssertTrue(representable.contains("var onTextViewAttachment: ((InkletTextViewAttachmentEvent) -> Void)?"))
        XCTAssertTrue(representable.contains("onTextViewAttachment?(.attach(textView))"))
        XCTAssertTrue(representable.contains("onTextViewAttachment?(.detach(textView))"))
        XCTAssertTrue(representable.contains("static func dismantleNSView"))
    }

    func testWholeStringSynchronizationDoesNotOverwriteLockedTransactionEditor() throws {
        let source = try popoverSource()
        let updateStart = try XCTUnwrap(source.range(of: "func updateNSView(_ container: InkletTextContainerView"))
        let coordinatorStart = try XCTUnwrap(source.range(
            of: "final class Coordinator",
            range: updateStart.upperBound..<source.endIndex
        ))
        let updateBlock = source[updateStart.lowerBound..<coordinatorStart.lowerBound]

        XCTAssertTrue(updateBlock.contains("textView.isEditable"))
        XCTAssertTrue(updateBlock.contains("!textView.hasMarkedText()"))
        XCTAssertTrue(updateBlock.contains("textView.string != text"))
        XCTAssertTrue(updateBlock.contains("textView.string = text"))
    }

    func testActionBarUsesFixedDictationStatusSlotWithoutChangingPopoverHeight() throws {
        let source = try popoverSource()
        let actionStart = try XCTUnwrap(source.range(of: "private var actionBar"))
        let shortcutStart = try XCTUnwrap(source.range(
            of: "private func shortcutHint",
            range: actionStart.upperBound..<source.endIndex
        ))
        let actionBlock = source[actionStart.lowerBound..<shortcutStart.lowerBound]

        XCTAssertTrue(actionBlock.contains("model.shouldShowDictationStatus"))
        XCTAssertTrue(actionBlock.contains("dictationStatus"))
        XCTAssertTrue(actionBlock.contains("case .connecting, .finalizing, .recovering:"))
        XCTAssertTrue(actionBlock.contains("ProgressView()"))
        XCTAssertTrue(actionBlock.contains("case .listening:"))
        XCTAssertTrue(actionBlock.contains("waveform"))
        XCTAssertTrue(actionBlock.contains("case .recordingForFallback:"))
        XCTAssertTrue(actionBlock.contains("mic.badge"))
        XCTAssertTrue(actionBlock.contains("case .idle, .complete, .failed:"))
        XCTAssertTrue(actionBlock.contains(".frame(width: 16, height: 16)"))
        XCTAssertFalse(actionBlock.contains("preferredPopoverHeight"))
        XCTAssertFalse(actionBlock.contains("actionBarHeight +"))
    }

    func testPickerSearchFieldAlignsNativeTextEditingWithPlaceholder() throws {
        let source = try pickerSource()
        let cellStart = try XCTUnwrap(source.range(
            of: "private final class WritingModeSearchFieldCell: NSSearchFieldCell"
        ))
        let controlStart = try XCTUnwrap(source.range(
            of: "private final class WritingModeSearchFieldControl: NSSearchField",
            range: cellStart.upperBound..<source.endIndex
        ))
        let searchFieldStart = try XCTUnwrap(source.range(
            of: "private struct WritingModeSearchField",
            range: controlStart.upperBound..<source.endIndex
        ))
        let cellSource = source[cellStart.lowerBound..<controlStart.lowerBound]
        let controlSource = source[controlStart.lowerBound..<searchFieldStart.lowerBound]
        let searchFieldSource = source[searchFieldStart.lowerBound...]
        let cellText = String(cellSource)
        let editStart = try XCTUnwrap(cellSource.range(of: "override func edit("))
        let selectStart = try XCTUnwrap(cellSource.range(
            of: "override func select(",
            range: editStart.upperBound..<cellSource.endIndex
        ))
        let editBlock = cellSource[editStart.lowerBound..<selectStart.lowerBound]
        let selectBlock = cellSource[selectStart.lowerBound...]
        let makeNSViewStart = try XCTUnwrap(searchFieldSource.range(of: "func makeNSView"))
        let updateNSViewStart = try XCTUnwrap(searchFieldSource.range(
            of: "func updateNSView",
            range: makeNSViewStart.upperBound..<searchFieldSource.endIndex
        ))
        let makeNSViewBlock = searchFieldSource[makeNSViewStart.lowerBound..<updateNSViewStart.lowerBound]

        XCTAssertTrue(cellSource.contains("override func searchTextRect(forBounds rect: NSRect) -> NSRect"))
        XCTAssertTrue(cellSource.contains("super.searchTextRect(forBounds: rect).insetBy(dx: 4, dy: 0)"))
        for parameter in [
            "withFrame rect: NSRect",
            "in controlView: NSView",
            "editor textObj: NSText",
            "delegate: Any?",
            "event: NSEvent?"
        ] {
            XCTAssertTrue(editBlock.contains(parameter))
        }
        for parameter in [
            "withFrame rect: NSRect",
            "in controlView: NSView",
            "editor textObj: NSText",
            "delegate: Any?",
            "start selStart: Int",
            "length selLength: Int"
        ] {
            XCTAssertTrue(selectBlock.contains(parameter))
        }
        XCTAssertTrue(editBlock.contains("super.edit("))
        XCTAssertTrue(editBlock.contains("withFrame: searchTextRect(forBounds: rect)"))
        XCTAssertTrue(selectBlock.contains("super.select("))
        XCTAssertTrue(selectBlock.contains("withFrame: searchTextRect(forBounds: rect)"))
        XCTAssertEqual(
            cellText.components(separatedBy: "withFrame: searchTextRect(forBounds: rect)").count - 1,
            2
        )
        for forwardedArgument in ["in: controlView", "editor: textObj", "delegate: delegate"] {
            XCTAssertTrue(editBlock.contains(forwardedArgument))
            XCTAssertTrue(selectBlock.contains(forwardedArgument))
            XCTAssertEqual(
                cellText.components(separatedBy: forwardedArgument).count - 1,
                2
            )
        }
        XCTAssertTrue(editBlock.contains("event: event"))
        XCTAssertEqual(cellText.components(separatedBy: "event: event").count - 1, 1)
        XCTAssertTrue(selectBlock.contains("start: selStart"))
        XCTAssertEqual(cellText.components(separatedBy: "start: selStart").count - 1, 1)
        XCTAssertTrue(selectBlock.contains("length: selLength"))
        XCTAssertEqual(cellText.components(separatedBy: "length: selLength").count - 1, 1)
        XCTAssertTrue(controlSource.contains("override class var cellClass: AnyClass?"))
        XCTAssertTrue(controlSource.contains("get { WritingModeSearchFieldCell.self }"))
        XCTAssertTrue(controlSource.contains("set {}"))
        XCTAssertTrue(makeNSViewBlock.contains(
            "let searchField = WritingModeSearchFieldControl(frame: .zero)"
        ))
        XCTAssertFalse(makeNSViewBlock.contains(".cell ="))
        XCTAssertFalse(makeNSViewBlock.contains("searchField.cell ="))
        XCTAssertFalse(source.range(
            of: #"searchButtonCell\s*=\s*nil"#,
            options: .regularExpression
        ) != nil)
        XCTAssertFalse(source.range(
            of: #"cancelButtonCell\s*=\s*nil"#,
            options: .regularExpression
        ) != nil)
        XCTAssertFalse(source.contains("textContainerInset"))
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
        XCTAssertTrue(source.contains("Keycap(title: \"↵\", compact: true)"))
        XCTAssertTrue(source.contains("footerHint(keys: [\"↵\", \"tab\"]"))
        XCTAssertTrue(source.contains("ForEach(keys, id: \\.self) { key in"))
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

    func testWindowControllerOwnsTheWritingDictationDependencyGraph() throws {
        let source = try windowControllerSource()

        XCTAssertTrue(source.contains("private let audioRecorder: AudioRecorder"))
        XCTAssertTrue(source.contains("private let sourceEditorBridge: WritingSourceEditorBridge"))
        XCTAssertTrue(source.contains("private let dictationCoordinator: WritingDictationCoordinator"))
        XCTAssertTrue(source.contains("private let dictationShortcutMonitor: WritingDictationShortcutMonitor"))
        XCTAssertTrue(source.contains("configStore: UserDefaultsConfigStore = UserDefaultsConfigStore()"))
        XCTAssertTrue(source.contains("apiKeyStore: LocalAPIKeyStore = LocalAPIKeyStore()"))
        XCTAssertTrue(source.contains("LLMProviderPreset.openAI.id"))
        XCTAssertTrue(source.contains("RealtimeTranscriptionError.missingAPIKey"))
        XCTAssertTrue(source.contains("OpenAIRealtimeTranscriptionClient("))
        XCTAssertTrue(source.contains("OpenAISpeechTranscriptionProvider("))
        XCTAssertTrue(source.contains("endpoint.scheme == \"http\" || endpoint.scheme == \"https\""))
        XCTAssertTrue(source.contains("endpoint.host != nil"))
        XCTAssertTrue(source.contains("model: config.speechModel"))
        XCTAssertTrue(source.contains("timeoutSeconds: 20"))
    }

    func testWindowControllerWiresTheSourceEditorAndLocalShortcut() throws {
        let source = try windowControllerSource()

        XCTAssertTrue(source.contains("InkletPopoverView("))
        XCTAssertTrue(source.contains("onSourceTextViewAttachment:"))
        XCTAssertTrue(source.contains("case .attach(let textView):"))
        XCTAssertTrue(source.contains("sourceEditorBridge.attach(textView)"))
        XCTAssertTrue(source.contains("case .detach(let textView):"))
        XCTAssertTrue(source.contains("sourceEditorBridge.detach(textView)"))
        XCTAssertTrue(source.contains("dictationShortcutMonitor.configure("))
        XCTAssertTrue(source.contains("sourceEditorBridge.isEligible(in: window, model: model)"))
        XCTAssertTrue(source.contains("await self?.dictationCoordinator.beginHold()"))
        XCTAssertTrue(source.contains("await self?.dictationCoordinator.endHold()"))
        XCTAssertTrue(source.contains("await self?.dictationCoordinator.cancel()"))
        XCTAssertTrue(source.contains("dictationShortcutMonitor.activateEditorContext()"))
        XCTAssertTrue(source.contains("dictationShortcutMonitor.invalidateContext()"))
        XCTAssertTrue(source.contains("model.$popoverSession"))
    }

    func testPopoverPresentationSerializesDictationCleanupAcrossLifecycleChanges() throws {
        let source = try windowControllerSource()

        XCTAssertTrue(source.contains("NSWindowDelegate"))
        XCTAssertTrue(source.contains("panel.delegate = self"))
        XCTAssertTrue(source.contains("private var presentationGeneration"))
        XCTAssertTrue(source.contains("func cancelDictationAndWait() async"))
        XCTAssertTrue(source.contains("await dictationCoordinator.cancelAndWait()"))
        XCTAssertTrue(source.contains("func windowDidResignKey"))

        for method in ["func show(fallbackApplication:", "func hide()"] {
            let start = try XCTUnwrap(source.range(of: method))
            let body = source[start.lowerBound...]
            XCTAssertTrue(body.contains("presentationGeneration"), "Missing generation guard in \(method)")
            XCTAssertTrue(body.contains("cancelAndWait"), "Missing joined cancellation in \(method)")
        }

        let shutdownStart = try XCTUnwrap(source.range(of: "func cancelDictationAndWait() async"))
        let reloadStart = try XCTUnwrap(source.range(
            of: "func reloadDictationConfiguration()",
            range: shutdownStart.upperBound..<source.endIndex
        ))
        let shutdown = source[shutdownStart.lowerBound..<reloadStart.lowerBound]
        XCTAssertTrue(shutdown.contains("advancePresentationGeneration()"))
        XCTAssertTrue(shutdown.contains("pendingPresentationTask?.cancel()"))
        XCTAssertTrue(shutdown.contains("await pendingPresentationTask?.value"))
        XCTAssertTrue(shutdown.contains("dictationShortcutMonitor.stop()"))
        XCTAssertTrue(shutdown.contains("detachSourceEditor()"))
        XCTAssertTrue(source.contains("guard let textView = sourceEditorBridge.attachedTextView"))
        XCTAssertTrue(source.contains("sourceEditorBridge.detach(textView)"))
        XCTAssertTrue(shutdown.contains("window?.orderOut(nil)"))
    }

    func testFocusLossCancellationCannotOutliveAReactivatedEditorContext() throws {
        let source = try windowControllerSource()

        XCTAssertTrue(source.contains("private var dictationContextGeneration"))
        XCTAssertTrue(source.contains("private var dictationContextCleanupTask"))
        XCTAssertTrue(source.contains("private func activateDictationEditorContext()"))
        XCTAssertTrue(source.contains("dictationContextGeneration &+= 1"))
        XCTAssertTrue(source.contains("dictationContextCleanupTask?.cancel()"))
        XCTAssertTrue(source.contains("dictationContextCleanupTask = Task"))
        XCTAssertTrue(source.contains("self.dictationContextGeneration == generation"))
    }

    func testMonitorCancellationUsesTheTrackedEditorContextCleanupTask() throws {
        let source = try windowControllerSource()
        let reloadStart = try XCTUnwrap(source.range(of: "func reloadDictationConfiguration()"))
        let keyWindowStart = try XCTUnwrap(source.range(
            of: "func windowDidBecomeKey",
            range: reloadStart.upperBound..<source.endIndex
        ))
        let reloadBlock = source[reloadStart.lowerBound..<keyWindowStart.lowerBound]
        let onCancelStart = try XCTUnwrap(reloadBlock.range(of: "onCancel:"))
        let onCancelBlock = reloadBlock[onCancelStart.lowerBound...]

        XCTAssertTrue(onCancelBlock.contains("scheduleDictationContextCancellation()"))
        XCTAssertFalse(onCancelBlock.contains("Task { @MainActor"))
        XCTAssertTrue(source.contains("private func scheduleDictationContextCancellation()"))
        XCTAssertTrue(source.contains("dictationContextCleanupTask = Task"))
        XCTAssertTrue(source.contains("self.dictationContextGeneration == generation"))
    }

    func testDictationPhaseUpdatesTheModelAndPostsOnlyPhaseAnnouncements() throws {
        let source = try windowControllerSource()

        XCTAssertTrue(source.contains("model.setDictationPhase(phase)"))
        XCTAssertTrue(source.contains("NSAccessibility.post("))
        XCTAssertTrue(source.contains("notification: .announcementRequested"))
        XCTAssertTrue(source.contains("NSAccessibility.NotificationUserInfoKey.announcement"))
        XCTAssertFalse(source.contains("announceTranscript"))
        XCTAssertFalse(source.contains("announceDelta"))
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

    func testEscapeFromVisibleResultRequestsSourceFocusAfterRestoringEditorState() throws {
        let source = try popoverSource()
        let escapeStart = try XCTUnwrap(source.range(of: "func escape()"))
        let openSettingsStart = try XCTUnwrap(source.range(
            of: "func openSettings()",
            range: escapeStart.upperBound..<source.endIndex
        ))
        let escapeBlock = source[escapeStart.lowerBound..<openSettingsStart.lowerBound]
        let resultBranchStart = try XCTUnwrap(escapeBlock.range(of: "if !resultText.isEmpty {"))
        let returnToPickerStart = try XCTUnwrap(escapeBlock.range(
            of: "\n        returnToModePicker()",
            range: resultBranchStart.upperBound..<escapeBlock.endIndex
        ))
        let resultBranch = escapeBlock[
            resultBranchStart.lowerBound..<returnToPickerStart.lowerBound
        ]
        let restoredEditorState = try XCTUnwrap(resultBranch.range(
            of: "stateMachine = PopoverStateMachine("
        ))
        let focusRequest = try XCTUnwrap(resultBranch.range(of: "requestSourceInputFocus()"))
        let branchReturn = try XCTUnwrap(resultBranch.range(
            of: "\n            return",
            range: restoredEditorState.upperBound..<resultBranch.endIndex
        ))

        XCTAssertLessThan(restoredEditorState.lowerBound, focusRequest.lowerBound)
        XCTAssertLessThan(focusRequest.lowerBound, branchReturn.lowerBound)
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

    func testNetworkConnectionLostUsesLocalizedPopoverError() throws {
        let source = try popoverSource()

        XCTAssertTrue(source.contains("case .networkConnectionLost:"))
        XCTAssertTrue(source.contains("return L10n.text(\"error.networkConnectionLost\")"))
    }

    func testEditorEscapeHintAlwaysDescribesBackNavigation() throws {
        let source = try popoverSource()
        let actionBarStart = try XCTUnwrap(source.range(of: "private var actionBar"))
        let dictationStatusStart = try XCTUnwrap(source.range(
            of: "private var dictationStatus",
            range: actionBarStart.upperBound..<source.endIndex
        ))
        let actionBar = source[actionBarStart.lowerBound..<dictationStatusStart.lowerBound]

        XCTAssertTrue(actionBar.contains(
            "shortcutHint(keys: [\"esc\"], label: L10n.text(\"popover.hint.back\"))"
        ))
        XCTAssertFalse(actionBar.contains("popover.hint.close"))
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

    func testViewModelValidatesPersistedModeBeforeFallbackResolution() throws {
        let source = try popoverSource()
        let initializerStart = try XCTUnwrap(source.range(of: "\n    init(\n"))
        let resetStart = try XCTUnwrap(source.range(
            of: "func resetForOpen",
            range: initializerStart.upperBound..<source.endIndex
        ))
        let refreshStart = try XCTUnwrap(source.range(
            of: "private func refreshVoiceShortcutHint",
            range: resetStart.upperBound..<source.endIndex
        ))
        let initializerBlock = source[initializerStart.lowerBound..<resetStart.lowerBound]
        let resetBlock = source[resetStart.lowerBound..<refreshStart.lowerBound]
        let initializerSelection = try XCTUnwrap(initializerBlock.range(
            of: "let selectedModeID = Self.resolvedModeID("
        ))
        let initializerFallback = try XCTUnwrap(initializerBlock.range(
            of: "let visibleModes = Self.resolvedVisibleModes(from: loadedConfig)"
        ))
        let resetSelection = try XCTUnwrap(resetBlock.range(
            of: "let selectedModeID = Self.resolvedModeID("
        ))
        let resetFallback = try XCTUnwrap(resetBlock.range(
            of: "modes = Self.resolvedVisibleModes(from: config)"
        ))

        XCTAssertLessThan(initializerSelection.lowerBound, initializerFallback.lowerBound)
        XCTAssertTrue(initializerBlock.contains("config: loadedConfig"))
        XCTAssertLessThan(resetSelection.lowerBound, resetFallback.lowerBound)
        XCTAssertTrue(resetBlock.contains("config: config"))
        XCTAssertTrue(source.contains("config.visibleModeID(preferredModeID: preferredModeID)"))
        XCTAssertTrue(source.contains("config.defaultVisibleModeID"))
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
