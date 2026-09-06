import AppKit
import XCTest
@testable import Inklet

@MainActor
final class LocalizationWindowPlacementTests: XCTestCase {
    func testExpandedLocalizedContentStaysAboveTheScreenBottom() {
        let frame = InkletPopoverWindowController.resizedFrame(
            from: NSRect(x: 30, y: 20, width: 600, height: 150),
            toHeight: 400, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
        )
        XCTAssertEqual(frame, NSRect(x: 30, y: 0, width: 600, height: 400))
    }

    func testResizingPreservesTheTopEdgeWhenItFits() {
        let frame = InkletPopoverWindowController.resizedFrame(
            from: NSRect(x: 30, y: 500, width: 600, height: 150),
            toHeight: 400, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
        )
        XCTAssertEqual(frame.maxY, 650)
        XCTAssertEqual(frame.height, 400)
    }

    func testPlacementHandlesNegativeScreenCoordinatesAndMissingScreens() {
        let original = NSRect(x: -1200, y: -200, width: 600, height: 150)
        let constrained = InkletPopoverWindowController.resizedFrame(
            from: original, toHeight: 400,
            visibleFrame: NSRect(x: -1440, y: -300, width: 1440, height: 900)
        )
        XCTAssertEqual(constrained.minY, -300)
        XCTAssertEqual(constrained.minX, original.minX)
        let unconstrained = InkletPopoverWindowController.resizedFrame(
            from: original, toHeight: 400, visibleFrame: nil
        )
        XCTAssertEqual(unconstrained.maxY, original.maxY)
    }
}
