struct AutomaticUpdatePresentationState {
    var isMigrationMaintenanceActive: Bool
    var isRecordingHotkey: Bool
    var migrationWorkflowsAreIdle: Bool
    var isSelectingMigrationSource: Bool
    var hasModalWindow: Bool
    var isSelectionPanelVisible: Bool
    var isMenuTracking: Bool
    var isUpdateAlertPresenting: Bool

    var canPresent: Bool {
        !isMigrationMaintenanceActive
            && !isRecordingHotkey
            && migrationWorkflowsAreIdle
            && !isSelectingMigrationSource
            && !hasModalWindow
            && !isSelectionPanelVisible
            && !isMenuTracking
            && !isUpdateAlertPresenting
    }
}
