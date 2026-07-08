import XCTest

final class SelectionActionWindowControllerSourceTests: XCTestCase {
    func testSelectionResultWindowSupportsBackgroundDragAndResizeOnlyForResultStates() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/SelectionActionWindowController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private struct SelectionActionPanelDragState"))
        XCTAssertTrue(source.contains("var isBackgroundDraggingEnabled = false"))
        XCTAssertTrue(source.contains("override func sendEvent(_ event: NSEvent)"))
        XCTAssertTrue(source.contains("case .leftMouseDragged"))
        XCTAssertTrue(source.contains("setFrameOrigin(newOrigin)"))
        XCTAssertTrue(source.contains("private func isBackgroundDragPoint(_ point: NSPoint) -> Bool"))
        XCTAssertTrue(source.contains("configureWindowInteraction(for: state)"))
        XCTAssertTrue(source.contains("styleMask.insert(.resizable)"))
        XCTAssertTrue(source.contains("styleMask.remove(.resizable)"))
        XCTAssertTrue(source.contains("hasUserResizedTranslationPanel"))
        XCTAssertTrue(source.contains("SelectionPanelSizing.translationResultSize"))
        XCTAssertTrue(source.contains("private static let translationPanelMinimumSize"))
        XCTAssertTrue(source.contains("window.minSize = NSSize("))
        XCTAssertTrue(source.contains("private static let translationPanelSizeKey"))
        XCTAssertTrue(source.contains("loadRememberedTranslationPanelSize"))
        XCTAssertTrue(source.contains("saveRememberedTranslationPanelSize"))
        XCTAssertTrue(source.contains("rememberedTranslationPanelSize"))
        XCTAssertTrue(source.contains("SelectionPanelDragRegions.translationResultRegions"))
    }
}
