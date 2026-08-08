# Raycast-Style Writing Mode Picker Design

## Goal

Make switching Writing Assistant prompt modes fast when the user has several built-in or custom modes, without relying on fixed mode shortcuts that can conflict with global shortcuts.

The Writing Assistant opens as a keyboard-first, searchable mode launcher. The highlighted search result is the candidate mode, and `Tab` advances into the existing writing editor.

## Current Behavior

The writing popover opens directly into the source editor and resets to the first visible prompt mode. The current mode is changed through a compact header menu or by cycling with `Command+Up` and `Command+Down`.

`PromptMode` still contains default `Command+1` and `Command+2` shortcut labels, and the README says those shortcuts are available, but the popover key handler does not implement them. Fixed numeric shortcuts are also undesirable because they can conflict with the user's global shortcut setup.

## Approved Launcher Interaction

Opening the Writing Assistant always shows a mode launcher before the writing editor:

- Focus starts in a single-line mode search field.
- All visible prompt modes appear below the search field in the same order as Settings.
- The last mode committed from the launcher is highlighted by default. If it is no longer visible, the first visible mode is highlighted.
- Typing filters modes locally by their localized display names. A mode matches when the normalized query is a case- and diacritic-insensitive substring of the normalized display name; matching rows retain Settings order.
- `Up` and `Down` move the highlight through the filtered list. Movement stops at the first and last rows rather than wrapping.
- The highlighted row is the launcher result. There is no separate selection or confirmation state.
- `Tab` commits the highlighted mode, collapses the launcher, shows the existing writing editor in the same window, and focuses the source editor.
- `Return` does not commit a mode and otherwise has no launcher action. During input-method composition, it remains available to confirm the composed text or candidate.
- A single mouse click changes the highlight. A double-click commits that row and enters the editor.
- If filtering produces no results, the launcher shows a localized empty state. `Tab` has no effect until a result is highlighted.
- The footer shows localized hints equivalent to `Up/Down Select`, `Tab Write`, and `Esc Close`.

The launcher remains 600 points wide. It displays at most six rows before scrolling and resizes vertically within the current popover behavior. Long mode names truncate without moving other controls and expose their full value through a tooltip and accessibility label.

## Editor Navigation And Mode Changes

The selected mode remains visible in the editor header. Activating that mode control or the adjacent back control returns to the launcher.

Returning to the launcher:

- Preserves the source draft and any generated or edited result.
- Clears the previous search query.
- Highlights the editor's currently selected mode.
- Does not commit a different mode merely because the user browses the list.

The navigation stack follows the existing `Esc` behavior while adding the launcher as the outermost level:

1. A visible result returns to the source-only editor.
2. The source-only editor returns to the mode launcher.
3. The mode launcher closes the popover.

During generation or insertion, mode changes are disabled. `Esc` cancels the active operation and keeps the user in the editor rather than navigating away in the same keystroke.

## Existing Results When The Mode Changes

Committing a different mode never starts a model request automatically:

- The source draft remains unchanged.
- The existing result remains visible and is identified as having been generated with the previous mode.
- The editor header shows the newly committed mode.
- The primary action becomes Regenerate. Pressing `Return` performs the request with the new mode.
- If regeneration fails or is cancelled, the previous result remains available and the new mode remains selected for retry.
- Re-selecting the result's original mode makes the existing result current again, restoring the normal Insert action.

The view model therefore records both the committed editor mode and the mode that produced the visible result. A result is stale when those identifiers differ.

## State And Component Boundaries

The popover view model owns the navigation and selection state:

- Route: mode launcher or editor.
- Search query and highlighted mode identifier.
- Committed editor mode identifier.
- Result-producing mode identifier.
- Last committed launcher mode identifier.

The UI is split into a focused `PromptModePickerView` and the existing writing editor content. Search and list-navigation logic is isolated from SwiftUI rendering so it can be tested without presenting a window. The existing transformation state machine continues to own transformation, result, insertion, cancellation, and error behavior.

The launcher maintains a provisional highlight separately from the committed editor mode. Closing or backing out of the launcher does not change the editor mode or the remembered last mode. `Tab` or double-click is the commit boundary.

## Persistence And Compatibility

Persist the last committed Writing Assistant mode as a lightweight UI preference in the app's UserDefaults domain rather than re-saving the full `AppConfig`. This avoids overwriting settings that may have changed in the Settings window.

When resolving that preference:

- Use it only if the mode still exists and is visible.
- Otherwise fall back to the first visible mode.
- Preserve the existing built-in fallback for malformed configuration with no visible modes.

Do not add or display fixed numeric mode shortcuts. Keep decoding and encoding the existing `PromptMode.shortcut` field for configuration compatibility, change built-in defaults to `nil`, and do not consume persisted values in the launcher or editor. Remove stale numeric-shortcut claims from both READMEs.

## Localization And Accessibility

All new user-facing strings must be added to every supported language table, including the search placeholder, empty state, navigation hints, stale-result label, and Regenerate action.

The launcher must:

- Preserve input-method composition so `Return`, `Tab`, and arrow handling do not preempt marked text.
- Expose the search field purpose, each row's full mode name, the highlighted or selected state, and the commit action to VoiceOver.
- Keep mouse hover, pressed, and selected appearances distinct using the existing Inklet theme.
- Give every icon-only back, mode, or settings control a tooltip and accessibility label.
- Fit long English and Chinese strings at the app's actual 600-point width without overlap.

## Error And Edge States

- No matches: show the localized empty state and disable launcher advancement.
- Last mode hidden or deleted: highlight the first visible mode without an error.
- Configuration reload changes the visible modes: reconcile the highlight and committed mode before rendering.
- Generation failure after a mode change: keep the previous result, show the existing error treatment, and allow retry.
- Cancellation: keep the draft, previous result, and committed mode in a stable editor state.
- Rapid reopen: cancel prior work through the existing session mechanism, reload visible modes, clear the launcher query, and focus the search field.

## Testing And Verification

Add focused tests for:

- Search filtering, stable ordering, no-result behavior, and highlight reconciliation.
- Up and Down clamping at list boundaries.
- `Tab` commit versus provisional browsing and `Return` non-commit behavior.
- Last-mode persistence, hidden/deleted-mode fallback, and malformed-config fallback.
- Launcher/editor/result `Esc` navigation.
- Source and result preservation across launcher visits and mode changes.
- Stale-result detection, regeneration success, failure, and cancellation.
- Input-method composition guards in launcher keyboard handling.
- Localization-key presence across all supported language tables.

Verification:

- Run the focused tests and the complete `swift test` suite.
- Build, install, and launch `/Applications/Inklet Local.app` with `scripts/run-local-app.sh`.
- Hand-test keyboard and mouse selection, Chinese IME composition, no matches, long English and Chinese mode names, mode changes before and after generation, cancellation, retry, insertion, VoiceOver labels, and popover sizing.
- Run `git diff --check` and inspect `git status` before completion.

## Documentation

Update `README.md` and `README.zh-CN.md` to describe the launcher-first flow, `Tab` transition, and revised navigation. Remove the stale `Command+1` through `Command+6` mode-shortcut claims while retaining accurate writing, voice, insertion, and Settings instructions.

## Out Of Scope

- A global or configurable shortcut per prompt mode.
- Numeric mode shortcuts.
- Searching or editing system prompts from the launcher.
- Automatically generating when a mode is committed.
- Changing the Voice Writing Assistant's separate post-transcription mode chooser.
- Reordering or hiding modes outside Settings.
