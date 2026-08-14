import XCTest

final class SettingsViewSourceTests: XCTestCase {
    func testSelectionActionsExposeSafeForceSelectionChoicesAndCopyOptIn() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let panelRange = try XCTUnwrap(source.range(of: "private var selectionActionsPanel"))
        let historyRange = try XCTUnwrap(source.range(
            of: "\n    private var historyPanel",
            range: panelRange.upperBound..<source.endIndex
        ))
        let panelBlock = source[panelRange.lowerBound..<historyRange.lowerBound]

        XCTAssertTrue(panelBlock.contains("ForEach(SelectionForceSelectionMode.settingsCases)"))
        XCTAssertFalse(panelBlock.contains("ForEach(SelectionForceSelectionMode.allCases)"))
        XCTAssertTrue(panelBlock.contains("settings.row.allowSimulatedCopyFallback"))
        XCTAssertTrue(panelBlock.contains("settings.help.allowSimulatedCopyFallback"))
        XCTAssertTrue(panelBlock.contains("$model.config.selectionActions.allowsSimulatedCopyFallback"))
        XCTAssertTrue(panelBlock.contains(
            ".disabled(model.config.selectionActions.forceSelectionMode == .disabled)"
        ))
    }

    func testHistoryRowsExposeSingleCopyResultAction() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let rowRange = try XCTUnwrap(source.range(of: "private func historyRow"))
        let textBlockRange = try XCTUnwrap(source.range(
            of: "\n    private func historyTextBlock",
            range: rowRange.upperBound..<source.endIndex
        ))
        let rowBlock = source[rowRange.lowerBound..<textBlockRange.lowerBound]
        let copyButtonCount = rowBlock.components(separatedBy: "historyCopyButton(").count - 1

        XCTAssertEqual(copyButtonCount, 1)
        XCTAssertTrue(rowBlock.contains("settings.history.copyResult"))
        XCTAssertFalse(rowBlock.contains("settings.history.copyOriginal"))
    }
}
