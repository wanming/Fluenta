# Localization checks

Run from a macOS development checkout with Swift 6 and XCTest:

```bash
scripts/check-localization.sh
scripts/check-localization.sh --snapshots
swift test
```

The first command validates the permission string files and runs every localization test. The optional screenshot run creates a new gallery under `.build/localization-audit/` and prints its HTML path. Fixtures use synthetic text and offscreen native views, without launching Inklet, requesting permissions, recording audio, accessing other apps' content, or loading saved writing/history. Settings fixtures may enumerate microphone names and read the current Accessibility permission status. The pull-request workflow runs the same localization checks; the release workflow runs them as part of `swift test`.

## Audit scope

All ten shipped UI languages are covered: English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, French, German, Portuguese, and Italian.

| Surface | Audit and regression coverage |
| --- | --- |
| Localization tables and system selection | Complete key coverage, format argument compatibility, missing source references, preferred-language order and Chinese script/region selection |
| Selection menu and translation results | Content-sized labels, stable loading/playing dimensions, refresh and resize on language change, synthetic menu/error/result snapshots |
| Writing launcher, editor, result and dictation | Refresh preserves writing state; measured toolbar/error height handles wrapped text; errors scroll within a bounded area; windows reposition vertically after growth; synthetic writing snapshots |
| Settings navigation and instructions | Translated navigation can wrap, instructional copy has no arbitrary line cap, constrained controls adapt |
| About and History | Language refresh and interface-locale formatting; synthetic component snapshots |
| App menus, update/migration dialogs and permission strings | Source/table coverage and existing localized dialog tests; live dialog layout remains manual QA |

The audit found a fixed 224-point selection-menu width, eight incomplete language tables (93 missing English keys each), English-only Edit menu items, incorrect preferred-language ordering, stale open views after language changes, and constrained settings/writing text. Repairs address these causes in the existing views and localization layer.

## What is automatic

At runtime, layouts adapt to the actual label or wrapped content instead of relying on one language's dimensions. The compact selection menu keeps its width stable while its icon changes to loading or playback feedback. Writing content and Settings state survive language refresh.

During development, regression tests fail when localization contracts or the tested layout behaviors break. Fix the reported key, placeholder or layout constraint, then rerun the same command. The screenshot gallery makes localized fixtures reviewable; it is not an image-diff classifier or an unrestricted source-rewriting tool. New translations and arbitrary UI changes need review.

## Limits and manual checks

The source audit spans the app; automated rendering covers selected fixtures, not every possible screen/state combination. Font measurements and fitting sizes cannot prove that every glyph, VoiceOver action or live window interaction is correct. Snapshots depend on the host's macOS fonts and rendering. Review every newly translated language with a fluent speaker.

A remaining layout edge case is a display with less usable height than the fully expanded writing panel (roughly 700 points with long source, result and error content). Vertical repositioning preserves the top edge but cannot fit an oversized panel; bottom controls can remain offscreen. Check this configuration manually; the current layout does not provide a whole-panel scrolling fallback.

Brand names, provider/model identifiers, user-created prompt-mode names and descriptions, prompts, drafts, generated results, saved history and provider error details are content and retain their original language. Already-presented native dialogs and stored error messages may keep the language used when created; reopen or retry to generate current-language copy. macOS owns the language of system permission dialogs.

Use the language-switching section of [the manual checklist](manual-test-checklist.md) before release. A successful automated run does not mark those live checks as passed.
