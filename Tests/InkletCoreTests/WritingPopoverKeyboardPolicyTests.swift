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

    func testPickerReturnKeysConsumeWithoutTriggeringAnAction() {
        for keyCode: UInt16 in [36, 76] {
            XCTAssertEqual(action(route: .modePicker, keyCode: keyCode), .consume)
            XCTAssertEqual(
                action(route: .modePicker, keyCode: keyCode, modifiers: [.command, .shift]),
                .consume
            )
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

    func testPickerTabStillConsumesWhenFilteringHasNoResultToCommit() {
        var pickerState = WritingModePickerState(items: [
            WritingModePickerItem(id: "summary", title: "Summary")
        ])
        pickerState.setQuery("missing")

        XCTAssertNil(pickerState.highlightedModeID)
        XCTAssertEqual(action(route: .modePicker, keyCode: 48), .commitMode)
    }

    func testEditorCompositionPassesEscapeAndBothReturnKeysThrough() {
        for keyCode: UInt16 in [53, 36, 76] {
            XCTAssertEqual(
                action(route: .editor, keyCode: keyCode, isComposingText: true),
                .passThrough
            )
        }
    }

    func testEditorShortcutsPreserveExistingActions() {
        let cases: [(UInt16, WritingPopoverKeyboardModifiers, WritingPopoverKeyboardAction)] = [
            (53, [], .escape),
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
}
