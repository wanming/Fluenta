import XCTest
@testable import InkletCore

final class VoiceShortcutModifierPressTrackerTests: XCTestCase {
    func testReleaseWithAggregateModifierFlagStillSetEndsActivePress() {
        var tracker = VoiceShortcutModifierPressTracker()

        XCTAssertEqual(
            tracker.transition(
                keyCode: 61,
                expectedKeyCode: 61,
                isConfiguredModifierDown: true
            ),
            .began
        )
        XCTAssertEqual(
            tracker.transition(
                keyCode: 61,
                expectedKeyCode: 61,
                isConfiguredModifierDown: true
            ),
            .ended
        )
    }

    func testReleaseWithClearedModifierFlagEndsActivePress() {
        var tracker = VoiceShortcutModifierPressTracker()

        _ = tracker.transition(
            keyCode: 61,
            expectedKeyCode: 61,
            isConfiguredModifierDown: true
        )

        XCTAssertEqual(
            tracker.transition(
                keyCode: 61,
                expectedKeyCode: 61,
                isConfiguredModifierDown: false
            ),
            .ended
        )
    }

    func testUnexpectedKeyCodeIsIgnored() {
        var tracker = VoiceShortcutModifierPressTracker()

        XCTAssertEqual(
            tracker.transition(
                keyCode: 58,
                expectedKeyCode: 61,
                isConfiguredModifierDown: true
            ),
            .ignored
        )
    }

    func testResetIgnoresLaterReleaseFromClearedActivePress() {
        var tracker = VoiceShortcutModifierPressTracker()

        _ = tracker.transition(
            keyCode: 61,
            expectedKeyCode: 61,
            isConfiguredModifierDown: true
        )
        tracker.reset()

        XCTAssertEqual(
            tracker.transition(
                keyCode: 61,
                expectedKeyCode: 61,
                isConfiguredModifierDown: true
            ),
            .ignored
        )
        XCTAssertEqual(
            tracker.transition(
                keyCode: 61,
                expectedKeyCode: 61,
                isConfiguredModifierDown: true
            ),
            .began
        )
    }
}
