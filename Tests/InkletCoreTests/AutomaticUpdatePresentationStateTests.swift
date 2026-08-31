import XCTest

@testable import Inklet

final class AutomaticUpdatePresentationStateTests: XCTestCase {
    func testCanPresentOnlyWhenEveryPresentationBlockerIsIdle() {
        var state = AutomaticUpdatePresentationState(
            isMigrationMaintenanceActive: false,
            isRecordingHotkey: false,
            migrationWorkflowsAreIdle: true,
            isSelectingMigrationSource: false,
            hasModalWindow: false,
            isSelectionPanelVisible: false,
            isMenuTracking: false,
            isUpdateAlertPresenting: false
        )

        XCTAssertTrue(state.canPresent)

        state.isMigrationMaintenanceActive = true
        XCTAssertFalse(state.canPresent, "migration maintenance")
        state.isMigrationMaintenanceActive = false

        state.isRecordingHotkey = true
        XCTAssertFalse(state.canPresent, "hotkey recording")
        state.isRecordingHotkey = false

        state.migrationWorkflowsAreIdle = false
        XCTAssertFalse(state.canPresent, "workflow activity")
        state.migrationWorkflowsAreIdle = true

        state.isSelectingMigrationSource = true
        XCTAssertFalse(state.canPresent, "migration source selection")
        state.isSelectingMigrationSource = false

        state.hasModalWindow = true
        XCTAssertFalse(state.canPresent, "modal window")
        state.hasModalWindow = false

        state.isSelectionPanelVisible = true
        XCTAssertFalse(state.canPresent, "selection panel")
        state.isSelectionPanelVisible = false

        state.isMenuTracking = true
        XCTAssertFalse(state.canPresent, "menu tracking")
        state.isMenuTracking = false

        state.isUpdateAlertPresenting = true
        XCTAssertFalse(state.canPresent, "update alert")
        state.isUpdateAlertPresenting = false

        XCTAssertTrue(state.canPresent)
    }
}
