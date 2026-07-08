import XCTest
@testable import InkletCore

final class SelectionPanelPlacementTests: XCTestCase {
    func testPrefersBelowAndRightOfAnchorWithExtraGapWhenSpaceAllows() {
        let origin = SelectionPanelPlacement.origin(
            forPanelSize: SelectionPanelSize(width: 100, height: 50),
            near: SelectionPoint(x: 200, y: 200),
            in: SelectionScreenFrame(x: 0, y: 0, width: 500, height: 500)
        )

        XCTAssertEqual(origin, SelectionPoint(x: 218, y: 132))
    }

    func testUsesLeftSideWhenRightSideWouldLeaveVisibleFrame() {
        let origin = SelectionPanelPlacement.origin(
            forPanelSize: SelectionPanelSize(width: 100, height: 50),
            near: SelectionPoint(x: 470, y: 200),
            in: SelectionScreenFrame(x: 0, y: 0, width: 500, height: 500)
        )

        XCTAssertEqual(origin, SelectionPoint(x: 352, y: 132))
    }

    func testUsesAboveAnchorWhenBelowWouldLeaveVisibleFrame() {
        let origin = SelectionPanelPlacement.origin(
            forPanelSize: SelectionPanelSize(width: 100, height: 50),
            near: SelectionPoint(x: 200, y: 40),
            in: SelectionScreenFrame(x: 0, y: 0, width: 500, height: 500)
        )

        XCTAssertEqual(origin, SelectionPoint(x: 218, y: 58))
    }

    func testTranslationInitialSizeGrowsForLongText() {
        let shortSize = SelectionPanelSizing.translationResultSize(
            textLength: 40,
            fittingSize: SelectionPanelSize(width: 300, height: 180)
        )
        let longSize = SelectionPanelSizing.translationResultSize(
            textLength: 500,
            fittingSize: SelectionPanelSize(width: 300, height: 180)
        )

        XCTAssertEqual(shortSize, SelectionPanelSize(width: 320, height: 220))
        XCTAssertEqual(longSize, SelectionPanelSize(width: 440, height: 340))
    }

    func testTranslationInitialSizeStillRespectsMaximums() {
        let size = SelectionPanelSizing.translationResultSize(
            textLength: 2_000,
            fittingSize: SelectionPanelSize(width: 900, height: 900)
        )

        XCTAssertEqual(size, SelectionPanelSize(width: 520, height: 420))
    }

    func testTranslationInitialSizeUsesRememberedUserSize() {
        let size = SelectionPanelSizing.translationResultSize(
            textLength: 40,
            fittingSize: SelectionPanelSize(width: 300, height: 180),
            rememberedSize: SelectionPanelSize(width: 480, height: 360)
        )

        XCTAssertEqual(size, SelectionPanelSize(width: 480, height: 360))
    }

    func testTranslationRememberedSizeUsesManualResizeBounds() {
        let expandedSize = SelectionPanelSizing.translationResultSize(
            textLength: 40,
            fittingSize: SelectionPanelSize(width: 300, height: 180),
            rememberedSize: SelectionPanelSize(width: 540, height: 500),
            rememberedMinimumSize: SelectionPanelSize(width: 300, height: 180),
            rememberedMaximumSize: SelectionPanelSize(width: 560, height: 520)
        )
        let clampedSize = SelectionPanelSizing.translationResultSize(
            textLength: 40,
            fittingSize: SelectionPanelSize(width: 300, height: 180),
            rememberedSize: SelectionPanelSize(width: 260, height: 120),
            rememberedMinimumSize: SelectionPanelSize(width: 300, height: 180),
            rememberedMaximumSize: SelectionPanelSize(width: 560, height: 520)
        )

        XCTAssertEqual(expandedSize, SelectionPanelSize(width: 540, height: 500))
        XCTAssertEqual(clampedSize, SelectionPanelSize(width: 300, height: 180))
    }

    func testTranslationDragRegionAllowsToolbarBlankButExcludesTextAndButtons() {
        let regions = SelectionPanelDragRegions.translationResultRegions(
            panelSize: SelectionPanelSize(width: 440, height: 340)
        )

        XCTAssertTrue(regions.isBackgroundDragPoint(SelectionPoint(x: 220, y: 24)))
        XCTAssertFalse(regions.isBackgroundDragPoint(SelectionPoint(x: 40, y: 24)))
        XCTAssertFalse(regions.isBackgroundDragPoint(SelectionPoint(x: 370, y: 24)))
        XCTAssertFalse(regions.isBackgroundDragPoint(SelectionPoint(x: 220, y: 200)))
        XCTAssertFalse(regions.isBackgroundDragPoint(SelectionPoint(x: 4, y: 24)))
    }
}
