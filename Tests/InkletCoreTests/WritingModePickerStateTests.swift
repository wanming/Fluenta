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

    func testFuzzySearchRanksWritingModesForOrderedQuery() {
        var state = WritingModePickerState(items: [
            WritingModePickerItem(id: "chinese", title: "To Chinese Summary"),
            WritingModePickerItem(id: "simple", title: "To Simple and Correct English")
        ], query: "ts")

        XCTAssertEqual(state.filteredItems.map(\.id), ["simple", "chinese"])

        state.setQuery("tcs")
        XCTAssertEqual(state.filteredItems.map(\.id), ["chinese", "simple"])
    }

    func testFuzzySearchRanksChineseSummaryForOrderedChineseQuery() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "translate", title: "翻译为中文"),
            WritingModePickerItem(id: "summary", title: "生成中文摘要")
        ], query: "中摘")

        XCTAssertEqual(state.filteredItems.map(\.id), ["summary"])
    }

    func testFuzzySearchPrefersLaterWordBoundaryOverEarlierInlineMatch() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "inline", title: "abcdes"),
            WritingModePickerItem(id: "boundary", title: "island Summary")
        ], query: "s")

        XCTAssertEqual(state.filteredItems.map(\.id), ["boundary", "inline"])
    }

    func testFuzzySearchUsesBestAlignmentBeforeRanking() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "inline", title: "To xxxxxs"),
            WritingModePickerItem(id: "summary", title: "To Chinese Summary")
        ], query: "ts")

        XCTAssertEqual(state.filteredItems.map(\.id), ["summary", "inline"])
    }

    func testFuzzySearchRanksExactPrefixAndFuzzyMatches() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "fuzzy", title: "xsum"),
            WritingModePickerItem(id: "prefix", title: "sum" + String(repeating: "z", count: 600)),
            WritingModePickerItem(id: "exact", title: "sum")
        ], query: "sum")

        XCTAssertEqual(state.filteredItems.map(\.id), ["exact", "prefix", "fuzzy"])
    }

    func testFuzzySearchPrefersConsecutiveMatchesOverGappedMatches() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "gapped", title: "xayczzzz"),
            WritingModePickerItem(id: "consecutive", title: "zzzzzacx")
        ], query: "ac")

        XCTAssertEqual(state.filteredItems.map(\.id), ["consecutive", "gapped"])
    }

    func testFuzzySearchPrefersWordStartsOverInlineMatches() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "inline", title: "xas"),
            WritingModePickerItem(id: "wordStart", title: "a s")
        ], query: "s")

        XCTAssertEqual(state.filteredItems.map(\.id), ["wordStart", "inline"])
    }

    func testFuzzySearchPrefersEarlierMatches() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "later", title: "xxxxqqxx"),
            WritingModePickerItem(id: "earlier", title: "xxqqxxxx")
        ], query: "qq")

        XCTAssertEqual(state.filteredItems.map(\.id), ["earlier", "later"])
    }

    func testFuzzySearchPenalizesLongerNonconsecutiveGaps() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "longGap", title: "xayyczz"),
            WritingModePickerItem(id: "shortGap", title: "xxayczz")
        ], query: "ac")

        XCTAssertEqual(state.filteredItems.map(\.id), ["shortGap", "longGap"])
    }

    func testFuzzySearchPrefersShorterTitlesForSameAlignment() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "long", title: "abxxx"),
            WritingModePickerItem(id: "short", title: "abx")
        ], query: "ab")

        XCTAssertEqual(state.filteredItems.map(\.id), ["short", "long"])
    }

    func testFuzzySearchPenalizesAllUnmatchedTitleCharacters() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "long", title: String(repeating: "z", count: 30) + " x"),
            WritingModePickerItem(id: "short", title: String(repeating: "z", count: 25) + " x")
        ], query: "x")

        XCTAssertEqual(state.filteredItems.map(\.id), ["short", "long"])
    }

    func testFuzzySearchReturnsNoResultsWhenQueryIsLongerThanTitle() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "short", title: "abc")
        ], query: "abcd")

        XCTAssertTrue(state.filteredItems.isEmpty)
    }

    func testFuzzySearchFiltersDenseLongTitleWithinInteractiveBudget() {
        let title = String(repeating: "a", count: 4_000)
        let query = String(repeating: "a", count: 8)
        let budget = Duration.milliseconds(500)
        let clock = ContinuousClock()

        let start = clock.now
        let state = WritingModePickerState(
            items: [WritingModePickerItem(id: "dense", title: title)],
            query: query
        )
        let resultIDs = state.filteredItems.map(\.id)
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(resultIDs, ["dense"])
        XCTAssertLessThan(elapsed, budget, "Dense fuzzy filtering took \(elapsed)")
    }

    func testFuzzySearchPreservesSettingsOrderForIdenticalScores() {
        let state = WritingModePickerState(items: [
            WritingModePickerItem(id: "first", title: "Alpha"),
            WritingModePickerItem(id: "second", title: "Alpha")
        ], query: "a")

        XCTAssertEqual(state.filteredItems.map(\.id), ["first", "second"])
    }

    func testFuzzySearchKeepsVisiblePreferredHighlightOrUsesFirstRankedRow() {
        var visiblePreferred = WritingModePickerState(
            items: [
                WritingModePickerItem(id: "summary", title: "To Chinese Summary"),
                WritingModePickerItem(id: "simple", title: "To Simple and Correct English")
            ],
            preferredModeID: "summary"
        )
        visiblePreferred.setQuery("ts")

        XCTAssertEqual(visiblePreferred.filteredItems.map(\.id), ["simple", "summary"])
        XCTAssertEqual(visiblePreferred.highlightedModeID, "summary")

        var hiddenPreferred = WritingModePickerState(
            items: [
                WritingModePickerItem(id: "summary", title: "To Chinese Summary"),
                WritingModePickerItem(id: "simple", title: "To Simple and Correct English"),
                WritingModePickerItem(id: "other", title: "Polish Writing")
            ],
            preferredModeID: "other"
        )
        hiddenPreferred.setQuery("ts")

        XCTAssertEqual(hiddenPreferred.highlightedModeID, "simple")
    }
}
