import XCTest
@testable import InkletCore

final class SelectionCopyTriggerPolicyTests: XCTestCase {
    func testTwoIndependentCopiesTriggerWithOriginalPasteboardCount() {
        var policy = SelectionCopyTriggerPolicy(doubleCopyInterval: 0.8)

        XCTAssertEqual(
            policy.recordKeyDown(
                at: 10,
                pasteboardChangeCount: 4,
                isRepeat: false,
                isInkletGenerated: false
            ),
            .armed
        )
        policy.recordKeyUp(isInkletGenerated: false)

        XCTAssertEqual(
            policy.recordKeyDown(
                at: 10.5,
                pasteboardChangeCount: 5,
                isRepeat: false,
                isInkletGenerated: false
            ),
            .triggered(initialPasteboardChangeCount: 4)
        )
    }

    func testRepeatAndMissingKeyUpCannotTrigger() {
        var policy = SelectionCopyTriggerPolicy(doubleCopyInterval: 0.8)
        _ = policy.recordKeyDown(
            at: 10,
            pasteboardChangeCount: 4,
            isRepeat: false,
            isInkletGenerated: false
        )

        XCTAssertEqual(
            policy.recordKeyDown(
                at: 10.2,
                pasteboardChangeCount: 4,
                isRepeat: true,
                isInkletGenerated: false
            ),
            .ignoredRepeat
        )
        XCTAssertEqual(
            policy.recordKeyDown(
                at: 10.4,
                pasteboardChangeCount: 4,
                isRepeat: false,
                isInkletGenerated: false
            ),
            .awaitingKeyUp
        )
    }

    func testGeneratedEventsNeverArmOrReleaseGesture() {
        var policy = SelectionCopyTriggerPolicy(doubleCopyInterval: 0.8)

        XCTAssertEqual(
            policy.recordKeyDown(
                at: 10,
                pasteboardChangeCount: 4,
                isRepeat: false,
                isInkletGenerated: true
            ),
            .ignoredGenerated
        )
        policy.recordKeyUp(isInkletGenerated: true)
        XCTAssertEqual(
            policy.recordKeyDown(
                at: 10.4,
                pasteboardChangeCount: 5,
                isRepeat: false,
                isInkletGenerated: false
            ),
            .armed
        )
    }

    func testExpiredGestureRearmsInsteadOfTriggering() {
        var policy = SelectionCopyTriggerPolicy(doubleCopyInterval: 0.8)
        _ = policy.recordKeyDown(
            at: 10,
            pasteboardChangeCount: 4,
            isRepeat: false,
            isInkletGenerated: false
        )
        policy.recordKeyUp(isInkletGenerated: false)

        XCTAssertEqual(
            policy.recordKeyDown(
                at: 10.9,
                pasteboardChangeCount: 5,
                isRepeat: false,
                isInkletGenerated: false
            ),
            .armed
        )
    }

    func testResetClearsIncompleteGesture() {
        var policy = SelectionCopyTriggerPolicy(doubleCopyInterval: 0.8)
        _ = policy.recordKeyDown(
            at: 10,
            pasteboardChangeCount: 4,
            isRepeat: false,
            isInkletGenerated: false
        )
        policy.recordKeyUp(isInkletGenerated: false)

        policy.reset()

        XCTAssertEqual(
            policy.recordKeyDown(
                at: 10.4,
                pasteboardChangeCount: 5,
                isRepeat: false,
                isInkletGenerated: false
            ),
            .armed
        )
    }

    func testClipboardValidationRequiresChangedCountAndNonEmptyText() {
        XCTAssertNil(SelectionCopyTriggerPolicy.validatedClipboardText(
            initialChangeCount: 4,
            currentChangeCount: 4,
            text: "stale"
        ))
        XCTAssertNil(SelectionCopyTriggerPolicy.validatedClipboardText(
            initialChangeCount: 4,
            currentChangeCount: 5,
            text: "  \n "
        ))
        XCTAssertEqual(
            SelectionCopyTriggerPolicy.validatedClipboardText(
                initialChangeCount: 4,
                currentChangeCount: 5,
                text: "  copied text  "
            ),
            "copied text"
        )
    }
}
