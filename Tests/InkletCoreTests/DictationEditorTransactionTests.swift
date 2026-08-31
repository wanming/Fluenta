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
        undoManager.registerUndo(withTarget: undoProbe) { probe in
            probe.invocationCount += 1
        }
        undoManager.endUndoGrouping()
        let subject = try XCTUnwrap(makeTransaction(textView))

        try subject.replaceProvisional(with: "draft")
        subject.restore()
        undoManager.undo()

        XCTAssertEqual(undoProbe.invocationCount, 1)
        XCTAssertFalse(undoManager.canUndo)
    }

    func testRestoreStillRestoresModelAfterWeakTextViewInvalidation() throws {
        var synchronized: [String] = []
        var restoreCount = 0
        let textView = makeTextView(
            "original",
            selection: NSRange(location: 3, length: 0)
        )
        let subject = try XCTUnwrap(DictationEditorTransaction(
            textView: textView,
            synchronizeProvisional: { synchronized.append($0) },
            commitSourceChange: { _ in },
            restoreModelSnapshot: { restoreCount += 1 }
        ))
        subject.invalidateEditorReferenceForTesting()

        subject.restore()
        subject.restore()

        XCTAssertEqual(synchronized, ["original"])
        XCTAssertEqual(restoreCount, 1)
    }

    func testUndoRegistrationDoesNotRetainTheTextView() throws {
        let textView = makeTextView(
            "abc",
            selection: NSRange(location: 1, length: 1)
        )
        let undoManager = textView.testUndoManager
        let subject = try XCTUnwrap(makeTransaction(textView))
        try subject.commitFinal("voice")
        XCTAssertTrue(undoManager.canUndo)

        subject.invalidateEditorReferenceForTesting()
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
