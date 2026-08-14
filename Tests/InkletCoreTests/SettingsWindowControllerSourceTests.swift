import XCTest

final class SettingsWindowControllerSourceTests: XCTestCase {
    func testMigrationWorkflowIdlePropagatesFromRetainedSettingsModel() throws {
        let source = try controllerSource()

        XCTAssertTrue(source.contains("var onMigrationWorkflowIdleChange: ((Bool) -> Void)?"))
        XCTAssertTrue(source.contains("var isMigrationWorkflowIdle: Bool"))
        XCTAssertTrue(source.contains("model.isMigrationWorkflowIdle"))
        XCTAssertTrue(source.contains("model.$isMigrationWorkflowIdle"))
        XCTAssertTrue(source.contains("removeDuplicates()"))
        XCTAssertTrue(source.contains("onMigrationWorkflowIdleChange?(isIdle)"))
    }

    func testSettingsWindowDragsOnlyFromTopStrip() throws {
        let source = try controllerSource()

        XCTAssertTrue(source.contains("private struct SettingsWindowDragState"))
        XCTAssertTrue(source.contains("private var dragState: SettingsWindowDragState?"))
        XCTAssertTrue(source.contains("override func sendEvent(_ event: NSEvent)"))
        XCTAssertTrue(source.contains("case .leftMouseDown"))
        XCTAssertTrue(source.contains("case .leftMouseDragged"))
        XCTAssertTrue(source.contains("case .leftMouseUp"))
        XCTAssertTrue(source.contains("setFrameOrigin(newOrigin)"))
        XCTAssertTrue(source.contains("private func isDraggableHeaderPoint(_ point: NSPoint) -> Bool"))
        XCTAssertTrue(source.contains("private final class RoundedSettingsHostingView"))
        XCTAssertTrue(source.contains("override var mouseDownCanMoveWindow: Bool { false }"))
        XCTAssertTrue(source.contains("private enum SettingsWindowDragMetrics"))
        XCTAssertTrue(source.contains("static let draggableHeaderHeight: CGFloat = 68"))
        XCTAssertTrue(source.contains("static let closeButtonExclusionWidth: CGFloat = 64"))
        XCTAssertTrue(source.contains("point.y >= frame.height - SettingsWindowDragMetrics.draggableHeaderHeight"))
        XCTAssertTrue(source.contains("point.x < frame.width - SettingsWindowDragMetrics.closeButtonExclusionWidth"))
        XCTAssertTrue(source.contains("window.isMovableByWindowBackground = false"))
    }

    private func controllerSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/SettingsWindowController.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
