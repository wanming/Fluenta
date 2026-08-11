# Writing Mode Picker Search Refinement

## Goal

Make the Writing Assistant mode launcher feel closer to Raycast by fixing the search field's leading layout and replacing plain substring filtering with deterministic fuzzy ranking.

## Current Problems

The borderless `NSSearchField` keeps its system magnifying-glass button, but its editable and placeholder text rect does not reserve enough leading space. The caret, magnifier, and placeholder can overlap.

Mode filtering currently uses a case- and diacritic-insensitive substring check. Queries such as `ts` therefore cannot find `To Chinese Summary`, even though the query characters appear in order across the title.

## Approved Search Behavior

Search continues to use only each visible mode's localized display name. It does not search mode identifiers, system prompts, or hidden modes.

The raw query remains unchanged in the search field. A trimmed, case-insensitive, and diacritic-insensitive representation is used for matching. An empty or whitespace-only query shows every visible mode in Settings order.

A nonempty query matches a title when every normalized query character can be aligned with title characters in the same order. Characters do not need to be adjacent. This makes `ts` match both `To Simple and Correct English` and `To Chinese Summary`.

Matching results are ranked by a small in-process fuzzy scorer rather than by Settings order alone. The scorer selects the best alignment and applies these priorities:

1. Exact and prefix matches receive the strongest bonuses.
2. Consecutive characters receive a bonus.
3. Characters at the start of a word receive a bonus.
4. Matches near the start of the title receive a bonus.
5. Gaps between matched characters and unmatched title length receive small penalties.

The scorer uses dynamic programming so it can choose a better later alignment instead of always accepting the first possible character. For example, the `s` in `Summary` can score better than the earlier non-boundary `s` in `Chinese`.

Results sort by descending score. Equal scores preserve the original Settings order, keeping the ordering deterministic. With `ts`, `To Simple and Correct English` ranks ahead of `To Chinese Summary` because its word-start matches are tighter and earlier. With `tcs`, `To Chinese Summary` ranks ahead.

Chinese substring matching remains supported. Chinese and other titles can also use ordered-character fuzzy matching without adding pinyin or transliteration behavior.

## Search Field Layout

Keep the native `NSSearchField` and its system magnifying-glass behavior. Give it a dedicated search-field cell that explicitly reserves a leading icon rect and a separate text rect.

The placeholder, caret, marked text, and committed text must share the same text origin to the right of the magnifier. The system cancel button, native accessibility role, focus behavior, and input-method composition remain intact.

The fix must work at the launcher's existing 28-point search-field height and 600-point popover width without adding a second magnifier or changing the surrounding header layout.

## State And Navigation

`WritingModePickerState` remains the owner of the raw query, ranked filtered items, and highlighted mode identifier. Updating the query recomputes ranked results and reconciles the highlight to the first ranked item only when the previous highlight is no longer present.

Arrow navigation, `Tab` commitment, no-results behavior, mouse highlighting, and the six-row scrolling limit remain unchanged. Keyboard navigation operates on the ranked result order shown on screen.

## Testing And Verification

Add executable core tests for:

- ordered subsequence matching, including `ts` and `tcs`;
- exact, prefix, consecutive, word-boundary, early-position, and gap ranking priorities;
- deterministic Settings-order tie breaking;
- existing case-, diacritic-, Chinese-, whitespace-, and no-match behavior;
- highlight reconciliation against the ranked result list.

Add a focused app-source regression for the custom search cell and its distinct icon and text rects. Preserve the existing IME and focus tests.

Run the focused picker and launcher suites, the full package test suite, a strict warnings-as-errors build, and `scripts/run-local-app.sh`. Hand-check the placeholder, caret, entered text, clear button, `ts`/`tcs` ranking, Chinese search, and IME composition in the stable `/Applications/Inklet Local.app` bundle.

## Out Of Scope

- Searching prompt bodies or mode identifiers.
- Pinyin, transliteration, synonyms, or semantic search.
- Highlighting matched characters inside result rows.
- Adding a third-party fuzzy-search dependency.
- Changing mode commitment, result regeneration, or editor navigation behavior.
