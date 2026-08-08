import XCTest
@testable import InkletCore

final class WritingPopoverSessionStateTests: XCTestCase {
    func testStartsInModePickerAndCanEnterEditorAndReturnToPicker() {
        var state = WritingPopoverSessionState(selectedModeID: "summary")

        XCTAssertEqual(state.route, .modePicker)
        XCTAssertEqual(state.selectedModeID, "summary")

        state.enterEditor(modeID: "reply")

        XCTAssertEqual(state.route, .editor)
        XCTAssertEqual(state.selectedModeID, "reply")

        state.showModePicker()

        XCTAssertEqual(state.route, .modePicker)
        XCTAssertEqual(state.selectedModeID, "reply")
    }

    func testShowingModePickerPreservesSelectionAndResultState() {
        var state = WritingPopoverSessionState(
            selectedModeID: "reply",
            route: .editor,
            resultModeID: "summary"
        )
        let selectedModeID = state.selectedModeID
        let resultModeID = state.resultModeID
        let isResultStale = state.isResultStale
        XCTAssertTrue(isResultStale)

        state.showModePicker()

        XCTAssertEqual(state.route, .modePicker)
        XCTAssertEqual(state.selectedModeID, selectedModeID)
        XCTAssertEqual(state.resultModeID, resultModeID)
        XCTAssertEqual(state.isResultStale, isResultStale)
    }

    func testResultBecomesStaleOnlyWhenSelectedModeDiffers() {
        var state = WritingPopoverSessionState(selectedModeID: "summary")
        state.enterEditor(modeID: "summary")
        state.recordResult(modeID: "summary")

        XCTAssertFalse(state.isResultStale)

        state.enterEditor(modeID: "reply")
        XCTAssertTrue(state.isResultStale)

        state.enterEditor(modeID: "summary")
        XCTAssertFalse(state.isResultStale)
    }

    func testClearingResultRemovesIdentityAndStaleState() {
        var state = WritingPopoverSessionState(selectedModeID: "summary")
        state.recordResult(modeID: "reply")
        XCTAssertTrue(state.isResultStale)

        state.clearResult()

        XCTAssertNil(state.resultModeID)
        XCTAssertFalse(state.isResultStale)
    }
}
