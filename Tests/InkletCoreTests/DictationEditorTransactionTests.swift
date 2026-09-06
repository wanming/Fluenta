import AppKit
import XCTest
@testable import Inklet

@MainActor
final class DictationEditorTransactionTests: XCTestCase {
    func testInitializationLocksEditingAndSelection() throws {
        let textView = makeTextView("Hello", selection: NSRange(location: 2, length: 0))

        let subject = try XCTUnwrap(makeTransaction(textView))

        XCTAssertNotNil(subject)
        XCTAssertFalse(textView.isEditable)
        XCTAssertFalse(textView.isSelectable)
        XCTAssertEqual(textView.string, "Hello")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testInitializationRejectsASelectionOutsideTheSourceString() {
        let textView = makeTextView("abc", selection: NSRange(location: 1, length: 0))
        textView.reportedSelectedRange = NSRange(location: 9, length: 2)

        XCTAssertNil(makeTransaction(textView))
    }

    func testRepeatedPartialsReplaceOwnedSelectionWithoutDuplication() throws {
        let textView = makeTextView(
            "Hello old world",
            selection: NSRange(location: 6, length: 3)
        )
        var synchronized: [String] = []
        var committed: [String] = []
        let subject = try XCTUnwrap(DictationEditorTransaction(
            textView: textView,
            synchronizeProvisional: { synchronized.append($0) },
            commitSourceChange: { committed.append($0) },
            restoreModelSnapshot: {}
        ))

        try subject.replaceProvisional(with: "new")
        try subject.replaceProvisional(with: "new words")

        XCTAssertEqual(textView.string, "Hello new words world")
        XCTAssertEqual(synchronized, ["Hello new world", "Hello new words world"])
        XCTAssertEqual(committed, [])
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: 15, length: 0)
        )
        XCTAssertFalse(textView.undoManager?.canUndo ?? true)
    }

    func testRepeatedPartialsInsertAtOriginalCaret() throws {
        let textView = makeTextView("ac", selection: NSRange(location: 1, length: 0))
        let subject = try XCTUnwrap(makeTransaction(textView))

        try subject.replaceProvisional(with: "b")
        try subject.replaceProvisional(with: "between")

        XCTAssertEqual(textView.string, "abetweenc")
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: 8, length: 0)
        )
    }

    func testLongProvisionalReplacementKeepsCaretLineVisible() throws {
        let leading = Array(
            repeating: "前置内容 Leading context",
            count: 8
        ).joined(separator: "\n") + "\n"
        let trailing = "\n" + Array(
            repeating: "后续内容 Trailing context",
            count: 12
        ).joined(separator: "\n")
        let selection = NSRange(
            location: (leading as NSString).length,
            length: 0
        )
        let fixture = makeScrollableTextView(
            initialString: leading + trailing,
            selection: selection
        )
        let textView = fixture.textView
        let subject = try XCTUnwrap(makeTransaction(textView))
        let draft = Array(
            repeating: "今天中午吃什么？ What should I eat?",
            count: 24
        ).joined(separator: "\n")

        try subject.replaceProvisional(with: draft)

        let expectedCaretLocation =
            (leading as NSString).length + (draft as NSString).length
        let caretRange = textView.selectedRange()
        XCTAssertEqual(
            caretRange,
            NSRange(location: expectedCaretLocation, length: 0)
        )

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let caretLineCharacterRange = NSRange(
            location: max(caretRange.location - 1, 0),
            length: 1
        )
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: caretLineCharacterRange,
            actualCharacterRange: nil
        )
        let caretLineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )

        XCTAssertTrue(
            NSContainsRect(textView.visibleRect, caretLineRect),
            "The editor must scroll the inserted caret line into view"
        )
        XCTAssertLessThan(
            NSMaxY(textView.visibleRect),
            NSMaxY(textView.bounds),
            "The editor must not scroll the document bottom into view"
        )
    }

    func testUTF16OwnedRangeHandlesChineseEmojiAndCombiningMarks() throws {
        let original = "甲👩‍💻e\u{301}乙"
        let range = (original as NSString).range(of: "👩‍💻e\u{301}")
        let textView = makeTextView(original, selection: range)
        let subject = try XCTUnwrap(makeTransaction(textView))

        try subject.replaceProvisional(with: "听写")

        XCTAssertEqual(textView.string, "甲听写乙")
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: range.location + ("听写" as NSString).length, length: 0)
        )
    }

    func testProvisionalUnderlineMovesWithTheOwnedRangeAndFinalRemovesIt() throws {
        let textView = makeTextView("a OLD z", selection: NSRange(location: 2, length: 3))
        let subject = try XCTUnwrap(makeTransaction(textView))

        try subject.replaceProvisional(with: "long draft")
        assertSingleUnderline(
            in: textView,
            expectedRange: NSRange(location: 2, length: ("long draft" as NSString).length)
        )

        try subject.replaceProvisional(with: "短")
        assertSingleUnderline(
            in: textView,
            expectedRange: NSRange(location: 2, length: ("短" as NSString).length)
        )

        try subject.commitFinal("final")

        XCTAssertEqual(textView.string, "a final z")
        assertNoUnderline(in: textView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 7, length: 0))
    }

    func testFinalCommitSynchronizesFinalTextThenCommitsExactlyOnce() throws {
        let textView = makeTextView("abc", selection: NSRange(location: 1, length: 1))
        var synchronized: [String] = []
        var committed: [String] = []
        var restoreCount = 0
        let subject = try XCTUnwrap(DictationEditorTransaction(
            textView: textView,
            synchronizeProvisional: { synchronized.append($0) },
            commitSourceChange: { committed.append($0) },
            restoreModelSnapshot: { restoreCount += 1 }
        ))

        try subject.replaceProvisional(with: "draft")
        try subject.commitFinal("voice")

        XCTAssertEqual(textView.string, "avoicec")
        XCTAssertEqual(synchronized, ["adraftc", "avoicec"])
        XCTAssertEqual(committed, ["avoicec"])
        XCTAssertEqual(restoreCount, 0)
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertThrowsError(try subject.commitFinal("again"))
        XCTAssertThrowsError(try subject.replaceProvisional(with: "again"))
        XCTAssertEqual(committed, ["avoicec"])
    }

    func testFinalCommitCreatesExactlyOneUndoableEditWithRedo() throws {
        let textView = makeTextView("abc", selection: NSRange(location: 1, length: 1))
        var synchronized: [String] = []
        var committed: [String] = []
        let subject = try XCTUnwrap(DictationEditorTransaction(
            textView: textView,
            synchronizeProvisional: { synchronized.append($0) },
            commitSourceChange: { committed.append($0) },
            restoreModelSnapshot: {}
        ))

        try subject.replaceProvisional(with: "draft")
        try subject.commitFinal("voice")

        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertEqual(undoManager.undoActionName, L10n.text("dictation.undo.action"))
        undoManager.undo()
        XCTAssertEqual(textView.string, "abc")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 1))
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()
        XCTAssertEqual(textView.string, "avoicec")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0))
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertFalse(undoManager.canRedo)
        XCTAssertEqual(
            synchronized,
            ["adraftc", "avoicec", "abc", "avoicec"]
        )
        XCTAssertEqual(committed, ["avoicec"])
    }

    func testUndoRedoRemainSynchronousAfterTransactionIsReleased() throws {
        let textView = makeTextView("abc", selection: NSRange(location: 1, length: 1))
        let undoManager = textView.testUndoManager
        var callbackStates: [String] = []
        var subject = DictationEditorTransaction(
            textView: textView,
            synchronizeProvisional: { _ in },
            synchronizePersistent: { [weak undoManager] _ in
                if undoManager?.isUndoing == true {
                    callbackStates.append("undo")
                } else if undoManager?.isRedoing == true {
                    callbackStates.append("redo")
                } else {
                    XCTFail("Synchronization must run inside the undo or redo callback")
                }
            },
            commitSourceChange: { _ in },
            restoreModelSnapshot: {}
        )
        let transactionReference = WeakObjectReference(try XCTUnwrap(subject))
        try XCTUnwrap(subject).commitFinal("voice")
        subject = nil
        XCTAssertNil(transactionReference.value)

        for cycle in 1...2 {
            undoManager.undo()
            XCTAssertEqual(textView.string, "abc")
            XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 1))
            XCTAssertFalse(undoManager.canUndo)
            XCTAssertTrue(undoManager.canRedo)
            XCTAssertEqual(callbackStates.count, cycle * 2 - 1)

            undoManager.redo()
            XCTAssertEqual(textView.string, "avoicec")
            XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0))
            XCTAssertTrue(undoManager.canUndo)
            XCTAssertFalse(undoManager.canRedo)
            XCTAssertEqual(callbackStates.count, cycle * 2)
        }
        XCTAssertEqual(callbackStates, ["undo", "redo", "undo", "redo"])
    }

    func testCommitPreservesPriorUndoAndRedoOrderWithDefaultGrouping() throws {
        let textView = makeTextView("abc", selection: NSRange(location: 1, length: 1))
        let undoManager = textView.testUndoManager
        undoManager.groupsByEvent = true
        XCTAssertTrue(undoManager.groupsByEvent)
        let counter = UndoableCounter(undoManager: undoManager)
        counter.change(to: 1)
        XCTAssertEqual(undoManager.groupingLevel, 1)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(undoManager.groupingLevel, 0)
        let subject = try XCTUnwrap(makeTransaction(textView))

        try subject.commitFinal("voice")

        undoManager.undo()
        XCTAssertEqual(textView.string, "abc")
        XCTAssertEqual(counter.value, 1)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertTrue(undoManager.canRedo)

        undoManager.undo()
        XCTAssertEqual(textView.string, "abc")
        XCTAssertEqual(counter.value, 0)
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()
        XCTAssertEqual(textView.string, "abc")
        XCTAssertEqual(counter.value, 1)
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()
        XCTAssertEqual(textView.string, "avoicec")
        XCTAssertEqual(counter.value, 1)
        XCTAssertFalse(undoManager.canRedo)
    }

    func testRestoreReturnsExactTextSelectionInteractionAndCallbacks() throws {
        let original = "before"
        let selection = NSRange(location: 2, length: 3)
        let textView = makeTextView(original, selection: selection)
        var synchronized: [String] = []
        var committed: [String] = []
        var restoreCount = 0
        let subject = try XCTUnwrap(DictationEditorTransaction(
            textView: textView,
            synchronizeProvisional: { synchronized.append($0) },
            commitSourceChange: { committed.append($0) },
            restoreModelSnapshot: { restoreCount += 1 }
        ))

        try subject.replaceProvisional(with: "draft")
        subject.restore()

        XCTAssertEqual(textView.string, original)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.undoManager?.canUndo ?? true)
        XCTAssertEqual(synchronized, ["bedrafte", original])
        XCTAssertEqual(committed, [])
        XCTAssertEqual(restoreCount, 1)
        assertNoUnderline(in: textView)

        subject.restore()

        XCTAssertEqual(synchronized, ["bedrafte", original])
        XCTAssertEqual(restoreCount, 1)
        XCTAssertThrowsError(try subject.replaceProvisional(with: "late"))
    }

    func testRestorePreservesAttributedRunsAndOutsideTemporaryAttributes() throws {
        let fixture = makeAttributedFixture()
        let subject = try XCTUnwrap(makeTransaction(fixture.textView))

        try subject.replaceProvisional(with: "a much longer draft")
        subject.restore()

        XCTAssertEqual(fixture.textView.attributedString(), fixture.original)
        assertOutsideTemporaryAttributes(
            in: fixture.textView,
            key: fixture.temporaryKey
        )
    }

    func testRestorePreservesExactTemporaryAttributesInsideOriginalRange() throws {
        let fixture = makeInsideTemporaryAttributeFixture()
        let originalTemporaryAttributes = temporaryAttributes(
            in: fixture.textView,
            range: fixture.selection
        )
        let subject = try XCTUnwrap(makeTransaction(fixture.textView))

        try subject.replaceProvisional(with: "a much longer draft")
        assertSingleUnderline(
            in: fixture.textView,
            expectedRange: NSRange(
                location: fixture.selection.location,
                length: ("a much longer draft" as NSString).length
            )
        )
        subject.restore()

        assertTemporaryAttributes(
            originalTemporaryAttributes,
            in: fixture.textView,
            range: fixture.selection
        )
    }

    func testUndoRedoPreservesAttributedRunsAndOutsideTemporaryAttributes() throws {
        let fixture = makeAttributedFixture()
        let subject = try XCTUnwrap(makeTransaction(fixture.textView))

        try subject.replaceProvisional(with: "draft")
        try subject.commitFinal("final voice")
        let committed = fixture.textView.attributedString()
        assertOutsidePersistentAttributes(
            in: fixture.textView,
            key: fixture.runKey
        )
        assertOutsideTemporaryAttributes(
            in: fixture.textView,
            key: fixture.temporaryKey
        )

        fixture.textView.testUndoManager.undo()

        XCTAssertEqual(fixture.textView.attributedString(), fixture.original)
        assertOutsideTemporaryAttributes(
            in: fixture.textView,
            key: fixture.temporaryKey
        )

        fixture.textView.testUndoManager.redo()

        XCTAssertEqual(fixture.textView.attributedString(), committed)
        assertOutsideTemporaryAttributes(
            in: fixture.textView,
            key: fixture.temporaryKey
        )
    }

    func testUndoRestoresExactTemporaryAttributesInsideOriginalRangeAndRedo() throws {
        let fixture = makeInsideTemporaryAttributeFixture()
        let originalTemporaryAttributes = temporaryAttributes(
            in: fixture.textView,
            range: fixture.selection
        )
        let subject = try XCTUnwrap(makeTransaction(fixture.textView))

        try subject.replaceProvisional(with: "draft")
        try subject.commitFinal("final voice")
        let committedRange = NSRange(
            location: fixture.selection.location,
            length: ("final voice" as NSString).length
        )
        let committedTemporaryAttributes = temporaryAttributes(
            in: fixture.textView,
            range: committedRange
        )

        fixture.textView.testUndoManager.undo()

        assertTemporaryAttributes(
            originalTemporaryAttributes,
            in: fixture.textView,
            range: fixture.selection
        )

        fixture.textView.testUndoManager.redo()

        assertTemporaryAttributes(
            committedTemporaryAttributes,
            in: fixture.textView,
            range: committedRange
        )
    }

    func testRestoreReturnsOriginalNonEditableNonSelectableState() throws {
        let textView = makeTextView("locked", selection: NSRange(location: 0, length: 0))
        textView.isEditable = false
        textView.isSelectable = false
        let subject = try XCTUnwrap(makeTransaction(textView))

        try subject.replaceProvisional(with: "draft")
        subject.restore()

        XCTAssertFalse(textView.isEditable)
        XCTAssertFalse(textView.isSelectable)
    }

    func testRestorePreservesAnExistingUndoStack() throws {
        let textView = makeTextView("abc", selection: NSRange(location: 1, length: 0))
        let undoProbe = UndoProbe()
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.beginUndoGrouping()
        let handler: @Sendable (UndoProbe) -> Void = { probe in
            MainActor.assumeIsolated {
                probe.invocationCount += 1
            }
        }
        undoManager.registerUndo(withTarget: undoProbe, handler: handler)
        undoManager.endUndoGrouping()
        let subject = try XCTUnwrap(makeTransaction(textView))

        try subject.replaceProvisional(with: "draft")
        subject.restore()
        undoManager.undo()

        XCTAssertEqual(undoProbe.invocationCount, 1)
        XCTAssertFalse(undoManager.canUndo)
    }

    func testWeakObjectReferenceDoesNotRetainItsObject() throws {
        var object: LifetimeProbe? = LifetimeProbe()
        let reference = WeakObjectReference(try XCTUnwrap(object))

        object = nil

        XCTAssertNil(reference.value)
    }

    func testDetachedEditorRestoreStillRestoresModelOnce() throws {
        var synchronized: [String] = []
        var restoreCount = 0
        let textView = makeTextView(
            "original",
            selection: NSRange(location: 3, length: 0)
        )
        let editorReference = WeakObjectReference<NSTextView>(textView)
        let subject = try XCTUnwrap(DictationEditorTransaction(
            textView: textView,
            editorReference: editorReference,
            synchronizeProvisional: { synchronized.append($0) },
            commitSourceChange: { _ in },
            restoreModelSnapshot: { restoreCount += 1 }
        ))
        editorReference.clear()

        subject.restore()
        subject.restore()

        XCTAssertEqual(synchronized, ["original"])
        XCTAssertEqual(restoreCount, 1)
    }

    func testUndoBecomesNoOpWhenEditorReferenceIsDetached() throws {
        let textView = makeTextView(
            "abc",
            selection: NSRange(location: 1, length: 1)
        )
        let undoManager = textView.testUndoManager
        let editorReference = WeakObjectReference<NSTextView>(textView)
        let subject = try XCTUnwrap(DictationEditorTransaction(
            textView: textView,
            editorReference: editorReference,
            synchronizeProvisional: { _ in },
            commitSourceChange: { _ in },
            restoreModelSnapshot: {}
        ))
        try subject.commitFinal("voice")
        XCTAssertTrue(undoManager.canUndo)

        editorReference.clear()
        undoManager.undo()

        XCTAssertEqual(textView.string, "avoicec")
        XCTAssertFalse(undoManager.canRedo)
    }

    func testRestoreReturnsFocusWhenTheEditorOriginallyOwnedIt() throws {
        let (window, textView) = makeWindowedTextView(
            "abc",
            selection: NSRange(location: 1, length: 0)
        )
        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertTrue(window.firstResponder === textView)
        let subject = try XCTUnwrap(makeTransaction(textView))
        XCTAssertTrue(window.makeFirstResponder(nil))

        subject.restore()

        XCTAssertTrue(window.firstResponder === textView)
    }

    func testFinalCommitReturnsFocusWhenTheEditorOriginallyOwnedIt() throws {
        let (window, textView) = makeWindowedTextView(
            "abc",
            selection: NSRange(location: 1, length: 0)
        )
        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertTrue(window.firstResponder === textView)
        let subject = try XCTUnwrap(makeTransaction(textView))
        XCTAssertTrue(window.makeFirstResponder(nil))

        try subject.commitFinal("voice")

        XCTAssertTrue(window.firstResponder === textView)
    }

    func testTerminalOperationDoesNotStealFocusWhenEditorDidNotOwnIt() throws {
        let (window, textView) = makeWindowedTextView(
            "abc",
            selection: NSRange(location: 1, length: 0)
        )
        let otherResponder = NSButton(frame: .zero)
        window.contentView?.addSubview(otherResponder)
        XCTAssertTrue(window.makeFirstResponder(otherResponder))
        let subject = try XCTUnwrap(makeTransaction(textView))

        try subject.commitFinal("voice")

        XCTAssertTrue(window.firstResponder === otherResponder)
    }

    private func makeTextView(_ string: String, selection: NSRange) -> TestTextView {
        let textView = TestTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200)
        )
        textView.string = string
        textView.allowsUndo = true
        textView.testUndoManager.groupsByEvent = false
        textView.setSelectedRange(selection)
        textView.testUndoManager.removeAllActions()
        return textView
    }

    private func makeScrollableTextView(
        initialString: String,
        selection: NSRange
    ) -> (
        scrollView: NSScrollView,
        textView: TestTextView
    ) {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 160, height: 40)
        )
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let textView = TestTextView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: scrollView.contentSize.width,
                height: scrollView.contentSize.height
            )
        )
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.allowsUndo = true
        textView.testUndoManager.groupsByEvent = false
        textView.string = initialString
        textView.setSelectedRange(selection)
        textView.testUndoManager.removeAllActions()

        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private func makeWindowedTextView(
        _ string: String,
        selection: NSRange
    ) -> (NSWindow, TestTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = makeTextView(string, selection: selection)
        window.contentView = textView
        return (window, textView)
    }

    private func makeAttributedFixture() -> (
        textView: TestTextView,
        original: NSAttributedString,
        runKey: NSAttributedString.Key,
        temporaryKey: NSAttributedString.Key
    ) {
        let string = "before MIDDLE after"
        let source = string as NSString
        let selection = source.range(of: "MIDDLE")
        let textView = makeTextView(string, selection: selection)
        let runKey = NSAttributedString.Key("DictationEditorTransactionTests.run")
        textView.textStorage?.addAttribute(
            runKey,
            value: "before",
            range: source.range(of: "before")
        )
        textView.textStorage?.addAttribute(
            runKey,
            value: "inside",
            range: selection
        )
        textView.textStorage?.addAttribute(
            runKey,
            value: "after",
            range: source.range(of: "after")
        )

        let temporaryKey = NSAttributedString.Key(
            "DictationEditorTransactionTests.outsideTemporary"
        )
        textView.layoutManager?.addTemporaryAttribute(
            temporaryKey,
            value: "leading",
            forCharacterRange: NSRange(location: 0, length: 1)
        )
        textView.layoutManager?.addTemporaryAttribute(
            temporaryKey,
            value: "trailing",
            forCharacterRange: NSRange(location: source.length - 1, length: 1)
        )

        return (
            textView,
            NSAttributedString(attributedString: textView.attributedString()),
            runKey,
            temporaryKey
        )
    }

    private func makeInsideTemporaryAttributeFixture() -> (
        textView: TestTextView,
        selection: NSRange
    ) {
        let string = "before MIDDLE after"
        let selection = (string as NSString).range(of: "MIDDLE")
        let textView = makeTextView(string, selection: selection)
        let temporaryKey = NSAttributedString.Key(
            "DictationEditorTransactionTests.insideTemporary"
        )
        textView.layoutManager?.addTemporaryAttribute(
            temporaryKey,
            value: "left",
            forCharacterRange: NSRange(location: selection.location, length: 3)
        )
        textView.layoutManager?.addTemporaryAttribute(
            temporaryKey,
            value: "right",
            forCharacterRange: NSRange(location: selection.location + 3, length: 3)
        )
        textView.layoutManager?.addTemporaryAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.double.rawValue,
            forCharacterRange: NSRange(location: selection.location + 2, length: 2)
        )
        return (textView, selection)
    }

    private func makeTransaction(
        _ textView: NSTextView
    ) -> DictationEditorTransaction? {
        DictationEditorTransaction(
            textView: textView,
            synchronizeProvisional: { _ in },
            commitSourceChange: { _ in },
            restoreModelSnapshot: {}
        )
    }

    private func assertSingleUnderline(
        in textView: NSTextView,
        expectedRange: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let layoutManager = textView.layoutManager else {
            return XCTFail("Expected an NSLayoutManager", file: file, line: line)
        }
        let length = (textView.string as NSString).length
        for index in 0..<length {
            let value = layoutManager.temporaryAttribute(
                .underlineStyle,
                atCharacterIndex: index,
                effectiveRange: nil
            ) as? Int
            if NSLocationInRange(index, expectedRange) {
                XCTAssertEqual(
                    value,
                    NSUnderlineStyle.single.rawValue,
                    "Expected underline at UTF-16 index \(index)",
                    file: file,
                    line: line
                )
            } else {
                XCTAssertNil(
                    value,
                    "Unexpected underline at UTF-16 index \(index)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertNoUnderline(
        in textView: NSTextView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let layoutManager = textView.layoutManager else {
            return XCTFail("Expected an NSLayoutManager", file: file, line: line)
        }
        let length = (textView.string as NSString).length
        for index in 0..<length {
            XCTAssertNil(
                layoutManager.temporaryAttribute(
                    .underlineStyle,
                    atCharacterIndex: index,
                    effectiveRange: nil
                ),
                "Unexpected underline at UTF-16 index \(index)",
                file: file,
                line: line
            )
        }
    }

    private func assertOutsideTemporaryAttributes(
        in textView: NSTextView,
        key: NSAttributedString.Key,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let layoutManager = textView.layoutManager else {
            return XCTFail("Expected an NSLayoutManager", file: file, line: line)
        }
        let lastIndex = (textView.string as NSString).length - 1
        XCTAssertEqual(
            layoutManager.temporaryAttribute(
                key,
                atCharacterIndex: 0,
                effectiveRange: nil
            ) as? String,
            "leading",
            file: file,
            line: line
        )
        XCTAssertEqual(
            layoutManager.temporaryAttribute(
                key,
                atCharacterIndex: lastIndex,
                effectiveRange: nil
            ) as? String,
            "trailing",
            file: file,
            line: line
        )
    }

    private func assertOutsidePersistentAttributes(
        in textView: NSTextView,
        key: NSAttributedString.Key,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let source = textView.string as NSString
        for (substring, value) in [("before", "before"), ("after", "after")] {
            let range = source.range(of: substring)
            XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
            XCTAssertEqual(
                textView.textStorage?.attribute(
                    key,
                    at: range.location,
                    effectiveRange: nil
                ) as? String,
                value,
                file: file,
                line: line
            )
        }
    }

    private func temporaryAttributes(
        in textView: NSTextView,
        range: NSRange
    ) -> [NSDictionary] {
        guard let layoutManager = textView.layoutManager else {
            return []
        }
        return (range.location..<NSMaxRange(range)).map { index in
            layoutManager.temporaryAttributes(
                atCharacterIndex: index,
                effectiveRange: nil
            ) as NSDictionary
        }
    }

    private func assertTemporaryAttributes(
        _ expected: [NSDictionary],
        in textView: NSTextView,
        range: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = temporaryAttributes(in: textView, range: range)
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(
                pair.0,
                pair.1,
                "Temporary attributes differ at offset \(index)",
                file: file,
                line: line
            )
        }
    }
}

@MainActor
private final class TestTextView: NSTextView {
    let testUndoManager = UndoManager()
    var reportedSelectedRange: NSRange?

    override var undoManager: UndoManager? {
        testUndoManager
    }

    override func selectedRange() -> NSRange {
        reportedSelectedRange ?? super.selectedRange()
    }
}

@MainActor
private final class UndoProbe: NSObject {
    var invocationCount = 0
}

@MainActor
private final class UndoableCounter: NSObject {
    private let undoManager: UndoManager
    private(set) var value = 0

    init(undoManager: UndoManager) {
        self.undoManager = undoManager
    }

    func change(to newValue: Int) {
        let previousValue = value
        let handler: @Sendable (UndoableCounter) -> Void = { counter in
            MainActor.assumeIsolated {
                counter.change(to: previousValue)
            }
        }
        undoManager.registerUndo(withTarget: self, handler: handler)
        value = newValue
    }
}

private final class LifetimeProbe {}
