# Writing Mode Picker Search Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the launcher search field's magnifier/text overlap and add deterministic Raycast-style fuzzy matching so initials such as `ts` find and rank writing modes.

**Architecture:** Keep search state and scoring inside `WritingModePickerState`; replace substring filtering with an ordered-subsequence dynamic-programming score and explicitly sort equal scores by the original Settings index. Keep the native `NSSearchField`, but provide a subclass-specific `NSSearchFieldCell` whose nonediting text and field-editor frames share the same inset native search-text rectangle.

**Tech Stack:** Swift 6, Foundation string folding and `CharacterSet`, AppKit `NSSearchField`/`NSSearchFieldCell`, SwiftUI `NSViewRepresentable`, XCTest, Markdown documentation.

---

## File Map

- Modify `Sources/InkletCore/WritingModePickerState.swift`: normalize queries, compute fuzzy scores, rank matches, and preserve Settings-order ties.
- Modify `Tests/InkletCoreTests/WritingModePickerStateTests.swift`: executable behavior coverage for matching, ranking priorities, Unicode, ties, and highlight reconciliation.
- Modify `Sources/InkletApp/WritingModePickerView.swift`: add the custom native search cell/control and align placeholder, caret, committed text, and marked text.
- Modify `Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift`: focused regression for the AppKit cell injection and editor-frame overrides.
- Modify `README.md`: describe initial-style fuzzy mode search in English.
- Modify `README.zh-CN.md`: describe the same behavior in Chinese.
- Modify `docs/manual-test-checklist.md`: replace the obsolete Settings-order filtering claim and add layout, fuzzy-rank, clear-button, Chinese, and IME checks.

### Task 1: Add deterministic fuzzy ranking to picker state

**Files:**
- Modify: `Tests/InkletCoreTests/WritingModePickerStateTests.swift`
- Modify: `Sources/InkletCore/WritingModePickerState.swift`

- [ ] **Step 1: Write failing fuzzy-search behavior tests**

Append these tests inside `WritingModePickerStateTests` and extend the existing Chinese test with the ordered-character assertion:

```swift
func testFuzzySearchRanksRaycastStyleOrderedMatches() {
    var state = WritingModePickerState(items: [
        WritingModePickerItem(id: "chinese", title: "To Chinese Summary"),
        WritingModePickerItem(id: "simple", title: "To Simple and Correct English")
    ])

    state.setQuery("ts")
    XCTAssertEqual(state.filteredItems.map(\.id), ["simple", "chinese"])

    state.setQuery("tcs")
    XCTAssertEqual(state.filteredItems.map(\.id), ["chinese", "simple"])
}

func testFuzzySearchChoosesBestAlignmentInsteadOfFirstAlignment() {
    let state = WritingModePickerState(
        items: [
            WritingModePickerItem(id: "inline", title: "To xxxxxs"),
            WritingModePickerItem(id: "summary", title: "To Chinese Summary")
        ],
        query: "ts"
    )

    XCTAssertEqual(state.filteredItems.map(\.id), ["summary", "inline"])
}

func testExactAndPrefixMatchesRankAheadOfFuzzyMatches() {
    let state = WritingModePickerState(
        items: [
            WritingModePickerItem(id: "fuzzy", title: "Make Pro"),
            WritingModePickerItem(id: "prefix", title: "Professional"),
            WritingModePickerItem(id: "exact", title: "Pro")
        ],
        query: "pro"
    )

    XCTAssertEqual(state.filteredItems.map(\.id), ["exact", "prefix", "fuzzy"])
}

func testConsecutiveAndWordStartMatchesReceiveRankingBonuses() {
    let consecutiveState = WritingModePickerState(
        items: [
            WritingModePickerItem(id: "gapped", title: "xayczzz"),
            WritingModePickerItem(id: "consecutive", title: "xxaczzz")
        ],
        query: "ac"
    )
    XCTAssertEqual(consecutiveState.filteredItems.map(\.id), ["consecutive", "gapped"])

    let boundaryState = WritingModePickerState(
        items: [
            WritingModePickerItem(id: "inline", title: "As"),
            WritingModePickerItem(id: "wordStart", title: "A s")
        ],
        query: "s"
    )
    XCTAssertEqual(boundaryState.filteredItems.map(\.id), ["wordStart", "inline"])
}

func testEarlyTightAndShortMatchesReceiveRankingBonuses() {
    let earlyState = WritingModePickerState(
        items: [
            WritingModePickerItem(id: "late", title: "Z z x"),
            WritingModePickerItem(id: "early", title: "A x z")
        ],
        query: "x"
    )
    XCTAssertEqual(earlyState.filteredItems.map(\.id), ["early", "late"])

    let gapState = WritingModePickerState(
        items: [
            WritingModePickerItem(id: "longGap", title: "xayyczz"),
            WritingModePickerItem(id: "shortGap", title: "xxayczz")
        ],
        query: "ac"
    )
    XCTAssertEqual(gapState.filteredItems.map(\.id), ["shortGap", "longGap"])

    let lengthState = WritingModePickerState(
        items: [
            WritingModePickerItem(id: "long", title: "ax long"),
            WritingModePickerItem(id: "short", title: "ax")
        ],
        query: "x"
    )
    XCTAssertEqual(lengthState.filteredItems.map(\.id), ["short", "long"])
}

func testEqualFuzzyScoresPreserveSettingsOrder() {
    let state = WritingModePickerState(
        items: [
            WritingModePickerItem(id: "first", title: "Alpha"),
            WritingModePickerItem(id: "second", title: "Alpha")
        ],
        query: "ph"
    )

    XCTAssertEqual(state.filteredItems.map(\.id), ["first", "second"])
}

func testRankedFilteringKeepsVisibleHighlightOrSelectsFirstRankedMatch() {
    let items = [
        WritingModePickerItem(id: "chinese", title: "To Chinese Summary"),
        WritingModePickerItem(id: "simple", title: "To Simple and Correct English")
    ]
    var state = WritingModePickerState(items: items, preferredModeID: "chinese")

    state.setQuery("ts")
    XCTAssertEqual(state.filteredItems.map(\.id), ["simple", "chinese"])
    XCTAssertEqual(state.highlightedModeID, "chinese")

    state.setQuery("simple")
    XCTAssertEqual(state.highlightedModeID, "simple")

    let initiallyFiltered = WritingModePickerState(items: items, query: "ts")
    XCTAssertEqual(initiallyFiltered.highlightedModeID, "simple")
}
```

Add this assertion after the existing `中文摘` assertion in `testSearchMatchesChineseSubstrings`:

```swift
state.setQuery("中摘")
XCTAssertEqual(state.filteredItems.map(\.id), ["summary"])
```

- [ ] **Step 2: Run the picker-state suite and record RED**

Run:

```bash
swift test --filter WritingModePickerStateTests
```

Expected: the existing substring implementation fails the new ordered-subsequence and ranking assertions; all previously existing picker-state tests still pass.

- [ ] **Step 3: Replace substring filtering with the minimal DP scorer**

Add this nested value type and scoring constants inside `WritingModePickerState`:

```swift
private struct RankedItem {
    let item: WritingModePickerItem
    let score: Int
    let originalIndex: Int
}

private static let exactMatchBonus = 2_000
private static let prefixMatchBonus = 1_000
private static let matchedCharacterScore = 100
private static let consecutiveMatchBonus = 60
private static let wordStartBonus = 45
private static let maximumEarlyPositionBonus = 24
private static let gapPenalty = 6
private static let unmatchedTitleCharacterPenalty = 1
private static let unreachableScore = Int.min / 4
```

Replace `filteredItems` with:

```swift
public var filteredItems: [WritingModePickerItem] {
    let matchingQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !matchingQuery.isEmpty else {
        return items
    }

    let normalizedQuery = Self.normalizedForSearch(matchingQuery)
    guard !normalizedQuery.isEmpty else {
        return items
    }

    return items.enumerated().compactMap { index, item -> RankedItem? in
        let normalizedTitle = Self.normalizedForSearch(item.title)
        guard let score = Self.fuzzyScore(
            normalizedQuery: normalizedQuery,
            normalizedTitle: normalizedTitle
        ) else {
            return nil
        }

        return RankedItem(item: item, score: score, originalIndex: index)
    }.sorted { lhs, rhs in
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        return lhs.originalIndex < rhs.originalIndex
    }.map { $0.item }
}
```

Add these helpers next to `normalizedForSearch`:

```swift
private static func fuzzyScore(
    normalizedQuery: String,
    normalizedTitle: String
) -> Int? {
    let queryCharacters = Array(normalizedQuery)
    let titleCharacters = Array(normalizedTitle)
    guard !queryCharacters.isEmpty,
          queryCharacters.count <= titleCharacters.count
    else {
        return nil
    }

    var previousScores = Array(
        repeating: unreachableScore,
        count: titleCharacters.count
    )

    for queryIndex in queryCharacters.indices {
        var currentScores = Array(
            repeating: unreachableScore,
            count: titleCharacters.count
        )

        for titleIndex in titleCharacters.indices
        where titleCharacters[titleIndex] == queryCharacters[queryIndex] {
            let characterScore = scoreForMatchedCharacter(
                in: titleCharacters,
                at: titleIndex
            )

            if queryIndex == queryCharacters.startIndex {
                currentScores[titleIndex] = characterScore
                continue
            }

            var bestPreviousScore = unreachableScore
            for previousTitleIndex in titleCharacters.startIndex..<titleIndex
            where previousScores[previousTitleIndex] != unreachableScore {
                let gap = titleIndex - previousTitleIndex - 1
                let transitionScore = gap == 0
                    ? consecutiveMatchBonus
                    : -(gap * gapPenalty)
                bestPreviousScore = max(
                    bestPreviousScore,
                    previousScores[previousTitleIndex] + transitionScore
                )
            }

            if bestPreviousScore != unreachableScore {
                currentScores[titleIndex] = bestPreviousScore + characterScore
            }
        }

        previousScores = currentScores
    }

    guard let bestAlignmentScore = previousScores.max(),
          bestAlignmentScore != unreachableScore
    else {
        return nil
    }

    let unmatchedCharacterCount = titleCharacters.count - queryCharacters.count
    var score = bestAlignmentScore
        - unmatchedCharacterCount * unmatchedTitleCharacterPenalty
    if normalizedTitle == normalizedQuery {
        score += exactMatchBonus
    } else if normalizedTitle.hasPrefix(normalizedQuery) {
        score += prefixMatchBonus
    }
    return score
}

private static func scoreForMatchedCharacter(
    in title: [Character],
    at index: Int
) -> Int {
    var score = matchedCharacterScore
    if isWordStart(in: title, at: index) {
        score += wordStartBonus
    }
    score += max(0, maximumEarlyPositionBonus - index)
    return score
}

private static func isWordStart(in title: [Character], at index: Int) -> Bool {
    index == title.startIndex
        || (!isWordCharacter(title[index - 1]) && isWordCharacter(title[index]))
}

private static func isWordCharacter(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0)
    }
}
```

Keep `normalizedForSearch` on `en_US_POSIX` with `.caseInsensitive` and `.diacriticInsensitive`. All indices above belong to normalized `[Character]` arrays, so folded grapheme expansion cannot mix original and normalized string indices.

- [ ] **Step 4: Run picker-state tests and record GREEN**

Run:

```bash
swift test --filter WritingModePickerStateTests
```

Expected: every picker-state test passes, including `ts`, `tcs`, exact/prefix/consecutive/word-start/early/gap/length ordering, Chinese fuzzy matching, Settings-order ties, raw query preservation, and ranked highlight reconciliation.

- [ ] **Step 5: Commit the fuzzy-search core change**

```bash
git add Sources/InkletCore/WritingModePickerState.swift Tests/InkletCoreTests/WritingModePickerStateTests.swift
git diff --cached --check
git diff --cached
git commit -m "Add fuzzy writing mode search"
```

### Task 2: Align the native search icon, placeholder, and field editor

**Files:**
- Modify: `Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift`
- Modify: `Sources/InkletApp/WritingModePickerView.swift`

- [ ] **Step 1: Write the failing AppKit wiring regression**

Add this test to `WritingModeLauncherSourceTests`:

```swift
func testPickerSearchCellKeepsNativeButtonsOutsidePlaceholderAndEditor() throws {
    let source = try pickerSource()
    let cellStart = try XCTUnwrap(source.range(
        of: "private final class WritingModeSearchFieldCell"
    ))
    let controlStart = try XCTUnwrap(source.range(
        of: "private final class WritingModeSearchFieldControl",
        range: cellStart.upperBound..<source.endIndex
    ))
    let representableStart = try XCTUnwrap(source.range(
        of: "private struct WritingModeSearchField",
        range: controlStart.upperBound..<source.endIndex
    ))
    let cellSource = String(source[cellStart.lowerBound..<controlStart.lowerBound])
    let controlSource = source[controlStart.lowerBound..<representableStart.lowerBound]
    let representableSource = source[representableStart.lowerBound...]

    XCTAssertTrue(cellSource.contains("override func searchTextRect(forBounds rect: NSRect)"))
    XCTAssertTrue(cellSource.contains(
        "super.searchTextRect(forBounds: rect).insetBy(dx: 4, dy: 0)"
    ))
    XCTAssertTrue(cellSource.contains("override func edit(withFrame rect: NSRect"))
    XCTAssertTrue(cellSource.contains("override func select(withFrame rect: NSRect"))
    XCTAssertEqual(
        cellSource.components(separatedBy: "withFrame: searchTextRect(forBounds: rect)").count - 1,
        2
    )
    XCTAssertTrue(controlSource.contains("override class var cellClass: AnyClass?"))
    XCTAssertTrue(controlSource.contains("WritingModeSearchFieldCell.self"))
    XCTAssertTrue(representableSource.contains(
        "let searchField = WritingModeSearchFieldControl(frame: .zero)"
    ))
    XCTAssertFalse(source.contains("searchButtonCell = nil"))
    XCTAssertFalse(source.contains("cancelButtonCell = nil"))
    XCTAssertFalse(source.contains("textContainerInset"))
}
```

- [ ] **Step 2: Run the focused source test and record RED**

Run:

```bash
swift test --filter WritingModeLauncherSourceTests/testPickerSearchCellKeepsNativeButtonsOutsidePlaceholderAndEditor
```

Expected: FAIL because the custom cell and control do not exist yet.

- [ ] **Step 3: Add the native cell and control subclasses**

Insert these private types immediately before `WritingModeSearchField`:

```swift
private final class WritingModeSearchFieldCell: NSSearchFieldCell {
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        super.searchTextRect(forBounds: rect).insetBy(dx: 4, dy: 0)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: searchTextRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: searchTextRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

private final class WritingModeSearchFieldControl: NSSearchField {
    override class var cellClass: AnyClass? {
        get { WritingModeSearchFieldCell.self }
        set {}
    }
}
```

In `makeNSView`, replace the stock constructor with the subclass while retaining the `NSSearchField` return type and all existing delegate, marked-text, focus, native button, and accessibility wiring:

```swift
let searchField = WritingModeSearchFieldControl(frame: .zero)
```

Do not assign a custom instance to `searchField.cell`: direct replacement resets editability/selectability on this SDK. Do not replace either native button cell.

- [ ] **Step 4: Run focused launcher tests and compile the app**

Run:

```bash
swift test --filter WritingModeLauncherSourceTests
swift build
```

Expected: all launcher source tests pass and the app target compiles against the current AppKit SDK.

- [ ] **Step 5: Commit the native search-field layout fix**

```bash
git add Sources/InkletApp/WritingModePickerView.swift Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift
git diff --cached --check
git diff --cached
git commit -m "Fix writing mode search field spacing"
```

### Task 3: Document fuzzy ranking and visual verification

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/manual-test-checklist.md`

- [ ] **Step 1: Update the English workflow and keyboard description**

Replace the text workflow's search step with:

```markdown
3. Fuzzy-search for a prompt mode—initials such as `ts` can match `To Chinese Summary`—use `Up` / `Down` to highlight it, then press `Tab` to commit the mode.
```

Replace the launcher arrow bullet with:

```markdown
- `Up` / `Down` in the mode launcher: move the highlight through fuzzy-ranked prompt modes.
```

Add this sentence before the paragraph beginning “When the mode launcher opens”:

```markdown
Mode search is case- and diacritic-insensitive and supports ordered-character initials while keeping exact, prefix, consecutive, word-start, and tighter matches ranked first.
```

- [ ] **Step 2: Update the Chinese workflow and keyboard description**

Replace the Chinese text workflow's search step with:

```markdown
3. 模糊搜索 Prompt 模式；例如输入 `ts` 也能匹配 `To Chinese Summary`。用 `↑` / `↓` 高亮，然后按 `Tab` 确认。
```

Replace the launcher arrow bullet with:

```markdown
- 模式启动器中的 `↑` / `↓`：在按模糊匹配度排序的 Prompt 模式之间移动高亮。
```

Add this sentence before the paragraph beginning “模式启动器打开时”:

```markdown
模式搜索不区分大小写和变音符号，并支持按顺序输入标题首字母；完整、前缀、连续、词首以及间隔更紧的匹配会排在前面。
```

- [ ] **Step 3: Replace stale manual filtering guidance and add the layout check**

Replace the current `Filtering:` checklist item with:

```markdown
- Fuzzy ranking: configure `To Simple and Correct English`, `To Chinese Summary`, mixed-case, diacritic-bearing, and Chinese mode names. Confirm `ts` finds both English titles and ranks `To Simple and Correct English` first; confirm `tcs` ranks `To Chinese Summary` first; then confirm case-, diacritic-, Chinese-substring-, and Chinese ordered-character matching.
```

Insert this item directly after `Initial focus:`:

```markdown
- Search field layout: at the actual 600-point popover width, confirm the native magnifier never overlaps the empty placeholder, caret, typed text, or Chinese IME marked text; enter and clear a query and confirm the native clear button remains usable without covering text.
```

- [ ] **Step 4: Check documentation symmetry and stale claims**

Run:

```bash
rg -n "fuzzy|Fuzzy|模糊|ts|tcs|preserves the visible mode order" README.md README.zh-CN.md docs/manual-test-checklist.md
git diff --check
```

Expected: both READMEs describe the same fuzzy-search capability, the checklist includes ranking/layout/IME/clear-button checks, and the obsolete “preserves the visible mode order” claim is absent.

- [ ] **Step 5: Commit the documentation updates**

```bash
git add README.md README.zh-CN.md docs/manual-test-checklist.md
git diff --cached --check
git diff --cached
git commit -m "Document fuzzy mode search"
```

### Task 4: Verify the integrated launcher refinement

**Files:**
- Verify only; modify the smallest owning file and its focused test if a check exposes a defect.

- [ ] **Step 1: Run focused tests**

```bash
swift test --filter WritingModePickerStateTests
swift test --filter WritingModeLauncherSourceTests
```

Expected: both focused suites pass.

- [ ] **Step 2: Run the full test suite**

```bash
swift test
```

Expected: all XCTest and Swift Testing tests pass with zero failures.

- [ ] **Step 3: Run the strict app build**

```bash
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: the Inklet app and core compile with no warnings promoted to errors.

- [ ] **Step 4: Install and launch the stable local bundle**

```bash
scripts/run-local-app.sh
```

Expected: `/Applications/Inklet Local.app` is rebuilt with the stable local identity, passes signature verification, installs, and launches.

- [ ] **Step 5: Hand-check the approved interaction**

In `/Applications/Inklet Local.app`, open the writing launcher and verify all of the following at its real 600-point width:

1. Empty placeholder, focused caret, typed text, and Chinese IME marked text all begin to the right of the native magnifier.
2. The clear button remains clickable and does not cover text.
3. `ts` shows both target modes with `To Simple and Correct English` first.
4. `tcs` puts `To Chinese Summary` first.
5. Chinese substring and ordered-character queries still match.
6. `Up` / `Down`, `Tab`, `Return`, `Escape`, mouse highlighting, double-click commitment, and the six-row scroll limit retain their existing behavior.

If the local automation cannot attach to the menu-bar-only app, record that limitation explicitly and report the interaction items as unverified rather than inferring success from the build.

- [ ] **Step 6: Request an independent code review and address concrete findings**

Use `superpowers:requesting-code-review` against the commits created by Tasks 1–3. For any confirmed defect, first add a focused failing test, then make the smallest fix and rerun the affected focused suite before repeating Steps 2–5.

- [ ] **Step 7: Inspect final repository state**

```bash
git diff --check
git status --short
git log -5 --oneline
```

Expected: no whitespace errors, no unintended uncommitted files, and focused commits for fuzzy core behavior, native field layout, and documentation.
