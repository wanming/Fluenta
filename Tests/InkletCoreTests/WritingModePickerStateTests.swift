import XCTest
@testable import InkletCore

final class WritingModePickerStateTests: XCTestCase {
    func testInitialHighlightUsesPreferredModeWithoutReorderingItems() {
        let items = [
            WritingModePickerItem(id: "translate", title: "Translate"),
            WritingModePickerItem(id: "concise", title: "Make Concise"),
            WritingModePickerItem(id: "professional", title: "Professional Tone")
        ]

        let state = WritingModePickerState(items: items, preferredModeID: "concise")

        XCTAssertEqual(state.items, items)
        XCTAssertEqual(state.filteredItems, items)
        XCTAssertEqual(state.highlightedModeID, "concise")
    }

    func testSearchPreservesRawQueryDuringIncrementalMultiWordInput() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "resume", title: "Résumé Review"),
            WritingModePickerItem(id: "reply", title: "Friendly Reply")
        ])

        var searchedState = state
        searchedState.setQuery(" \nRESUME")
        XCTAssertEqual(searchedState.query, " \nRESUME")
        XCTAssertEqual(searchedState.filteredItems.map(\.id), ["resume"])

        searchedState.setQuery(" \nRESUME REVIEW\t")
        XCTAssertEqual(searchedState.query, " \nRESUME REVIEW\t")
        XCTAssertEqual(searchedState.filteredItems.map(\.id), ["resume"])
    }

    func testWhitespaceOnlySearchPreservesRawQueryAndShowsAllItems() {
        let items = [
            WritingModePickerItem(id: "resume", title: "Résumé Review"),
            WritingModePickerItem(id: "reply", title: "Friendly Reply")
        ]

        let state = WritingModePickerState(items: items, query: " \n\t ")

        XCTAssertEqual(state.query, " \n\t ")
        XCTAssertEqual(state.filteredItems, items)
    }

    func testSearchMatchesChineseSubstrings() {
        var state = WritingModePickerState(items: [
            WritingModePickerItem(id: "summary", title: "生成中文摘要"),
            WritingModePickerItem(id: "translate", title: "翻译为英文")
        ])

        state.setQuery("中文摘")

        XCTAssertEqual(state.filteredItems.map(\.id), ["summary"])
    }

    func testFilteringReconcilesHighlightWithVisibleRows() {
        var state = WritingModePickerState(
            items: [
                WritingModePickerItem(id: "alpha", title: "Alpha"),
                WritingModePickerItem(id: "beta", title: "Beta"),
                WritingModePickerItem(id: "gamma", title: "Gamma")
            ],
            preferredModeID: "beta"
        )

        state.setQuery("a")
        XCTAssertEqual(state.highlightedModeID, "beta")

        state.setQuery("gamma")
        XCTAssertEqual(state.highlightedModeID, "gamma")

        state.setQuery("missing")
        XCTAssertNil(state.highlightedModeID)

        state.setQuery("")
        XCTAssertEqual(state.highlightedModeID, "alpha")
    }

    func testHighlightMovementClampsAtBoundariesAndIgnoresZeroAndEmptyLists() {
        var state = WritingModePickerState(
            items: [
                WritingModePickerItem(id: "first", title: "First"),
                WritingModePickerItem(id: "middle", title: "Middle"),
                WritingModePickerItem(id: "last", title: "Last")
            ],
            preferredModeID: "middle"
        )

        state.moveHighlight(by: 0)
        XCTAssertEqual(state.highlightedModeID, "middle")

        state.moveHighlight(by: -100)
        XCTAssertEqual(state.highlightedModeID, "first")

        state.moveHighlight(by: -1)
        XCTAssertEqual(state.highlightedModeID, "first")

        state.moveHighlight(by: 100)
        XCTAssertEqual(state.highlightedModeID, "last")

        state.moveHighlight(by: 1)
        XCTAssertEqual(state.highlightedModeID, "last")

        var emptyState = WritingModePickerState(items: [])
        emptyState.moveHighlight(by: 1)
        XCTAssertNil(emptyState.highlightedModeID)
    }

    func testHighlightAcceptsOnlyCurrentlyFilteredRows() {
        var state = WritingModePickerState(items: [
            WritingModePickerItem(id: "alpha", title: "Alpha"),
            WritingModePickerItem(id: "beta", title: "Beta"),
            WritingModePickerItem(id: "gamma", title: "Gamma")
        ])
        state.setQuery("ma")

        XCTAssertTrue(state.highlight(modeID: "gamma"))
        XCTAssertEqual(state.highlightedModeID, "gamma")

        XCTAssertFalse(state.highlight(modeID: "alpha"))
        XCTAssertEqual(state.highlightedModeID, "gamma")

        XCTAssertFalse(state.highlight(modeID: "missing"))
        XCTAssertEqual(state.highlightedModeID, "gamma")
    }
}
