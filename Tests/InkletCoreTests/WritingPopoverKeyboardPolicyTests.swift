import XCTest
@testable import InkletCore

final class WritingPopoverKeyboardPolicyTests: XCTestCase {
    func testPickerCompositionPassesEveryNavigationKeyThrough() {
        let navigationKeyCodes: [UInt16] = [48, 53, 126, 125, 36, 76]

        for keyCode in navigationKeyCodes {
            XCTAssertEqual(
                action(route: .modePicker, keyCode: keyCode, isComposingText: true),
                .passThrough,
                "Expected IME ownership for key code \(keyCode)"
            )
        }
    }

    func testPickerPlainReturnKeysCommitHighlightedMode() {
        for keyCode: UInt16 in [36, 76] {
            XCTAssertEqual(action(route: .modePicker, keyCode: keyCode), .commitMode)
        }
    }

    func testPickerModifiedReturnKeysAreConsumedWithoutCommitting() {
        let modifiers: [WritingPopoverKeyboardModifiers] = [
            .command,
            .shift,
            .option,
            .control,
            [.command, .shift, .option, .control]
        ]

        for keyCode: UInt16 in [36, 76] {
            for modifierSet in modifiers {
                XCTAssertEqual(
                    action(route: .modePicker, keyCode: keyCode, modifiers: modifierSet),
                    .consume
                )
            }
        }
    }

    func testPickerUnmodifiedNavigationMapsToHighlightAndCommitActions() {
        let cases: [(UInt16, WritingPopoverKeyboardAction)] = [
            (126, .moveHighlight(-1)),
            (125, .moveHighlight(1)),
            (48, .commitMode),
            (53, .escape)
        ]

        for (keyCode, expectedAction) in cases {
            XCTAssertEqual(action(route: .modePicker, keyCode: keyCode), expectedAction)
        }
    }

    func testPickerModifiedArrowsAndTabPassThrough() {
        let navigationKeyCodes: [UInt16] = [126, 125, 48]
        let modifiers: [WritingPopoverKeyboardModifiers] = [
            .command,
            .shift,
            .option,
            .control,
            [.command, .shift, .option, .control]
        ]

        for keyCode in navigationKeyCodes {
            for modifierSet in modifiers {
                XCTAssertEqual(
                    action(route: .modePicker, keyCode: keyCode, modifiers: modifierSet),
                    .passThrough,
                    "Expected modified key code \(keyCode) to pass through"
                )
            }
        }
    }

    func testPickerTypingPassesThrough() {
        XCTAssertEqual(action(route: .modePicker, keyCode: 0), .passThrough)
    }

    func testPickerCommitKeysRemainSafeWhenFilteringHasNoResult() {
        var pickerState = WritingModePickerState(items: [
            WritingModePickerItem(id: "summary", title: "Summary")
        ])
        pickerState.setQuery("missing")

        XCTAssertNil(pickerState.highlightedModeID)
        for keyCode: UInt16 in [48, 36, 76] {
            XCTAssertEqual(action(route: .modePicker, keyCode: keyCode), .commitMode)
        }
    }

    func testEditorCompositionPassesEscapeAndBothReturnKeysThrough() {
        for keyCode: UInt16 in [53, 36, 76] {
            XCTAssertEqual(
                action(route: .editor, keyCode: keyCode, isComposingText: true),
                .passThrough
            )
        }
    }

    func testEditorEscapePassesThroughToFocusedResponderForSingleOwnership() {
        XCTAssertEqual(action(route: .editor, keyCode: 53), .passThrough)
    }

    func testEditorIMEStillOwnsEscapeBeforeDictationCancellation() throws {
        let source = try popoverSource()
        let nativeStart = try XCTUnwrap(source.range(of: "private final class InkletNativeTextView"))
        let representableStart = try XCTUnwrap(source.range(
            of: "private struct InkletTextView",
            range: nativeStart.upperBound..<source.endIndex
        ))
        let nativeBlock = source[nativeStart.lowerBound..<representableStart.lowerBound]
        let markedTextCheck = try XCTUnwrap(nativeBlock.range(of: "!hasMarkedText()"))
        let escapeCallback = try XCTUnwrap(nativeBlock.range(
            of: "onEscapeKeyDown?()",
            range: markedTextCheck.upperBound..<nativeBlock.endIndex
        ))

        XCTAssertLessThan(markedTextCheck.lowerBound, escapeCallback.lowerBound)
        XCTAssertTrue(nativeBlock.contains("super.keyDown(with: event)"))
    }

    func testPanelIMEStillOwnsEscapeBeforeViewModelCancellation() throws {
        let source = try windowControllerSource()
        let cancelStart = try XCTUnwrap(source.range(of: "override func cancelOperation"))
        let keyDownStart = try XCTUnwrap(source.range(
            of: "override func keyDown(with event: NSEvent)",
            range: cancelStart.upperBound..<source.endIndex
        ))
        let cancelBlock = source[cancelStart.lowerBound..<keyDownStart.lowerBound]
        let compositionGuard = try XCTUnwrap(cancelBlock.range(of: "guard !isComposingText else"))
        let escapeCallback = try XCTUnwrap(cancelBlock.range(
            of: "onEscape?()",
            range: compositionGuard.upperBound..<cancelBlock.endIndex
        ))

        XCTAssertLessThan(compositionGuard.lowerBound, escapeCallback.lowerBound)
        XCTAssertTrue(cancelBlock.contains("super.cancelOperation(sender)"))
    }

    func testEditorShortcutsPreserveExistingActions() {
        let cases: [(UInt16, WritingPopoverKeyboardModifiers, WritingPopoverKeyboardAction)] = [
            (126, [.command], .cycleMode(-1)),
            (125, [.command], .cycleMode(1)),
            (36, [.command], .insertOriginal),
            (76, [.command], .insertOriginal),
            (36, [], .submit),
            (76, [], .submit),
            (36, [.control], .submit),
            (36, [.shift], .passThrough),
            (36, [.option], .passThrough),
            (36, [.shift, .option], .passThrough),
            (0, [], .passThrough)
        ]

        for (keyCode, modifiers, expectedAction) in cases {
            XCTAssertEqual(
                action(route: .editor, keyCode: keyCode, modifiers: modifiers),
                expectedAction,
                "Unexpected editor action for key code \(keyCode), modifiers \(modifiers.rawValue)"
            )
        }
    }

    func testEditorCycleRequiresCommandWithoutShiftOrOption() {
        for modifiers: WritingPopoverKeyboardModifiers in [
            [.command, .shift],
            [.command, .option]
        ] {
            XCTAssertEqual(
                action(route: .editor, keyCode: 126, modifiers: modifiers),
                .passThrough
            )
            XCTAssertEqual(
                action(route: .editor, keyCode: 125, modifiers: modifiers),
                .passThrough
            )
        }

        XCTAssertEqual(
            action(route: .editor, keyCode: 126, modifiers: [.command, .control]),
            .cycleMode(-1)
        )
    }

    private func action(
        route: WritingPopoverSessionState.Route,
        keyCode: UInt16,
        modifiers: WritingPopoverKeyboardModifiers = [],
        isComposingText: Bool = false
    ) -> WritingPopoverKeyboardAction {
        WritingPopoverKeyboardPolicy.action(
            route: route,
            keyCode: keyCode,
            modifiers: modifiers,
            isComposingText: isComposingText
        )
    }

    private func popoverSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/InkletApp/InkletPopoverView.swift"),
            encoding: .utf8
        )
    }

    private func windowControllerSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/InkletApp/InkletPopoverWindowController.swift"
            ),
            encoding: .utf8
        )
    }
}
