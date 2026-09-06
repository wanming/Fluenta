# Writing Dictation Caret Visibility Design

## Problem

When realtime dictation grows beyond the visible source-editor viewport, the newest line can be clipped immediately above the action bar. The action bar is a separate fixed-height row and is already included in the popover height; it is not overlaying the editor.

The clipping occurs because `DictationEditorTransaction.replaceOwnedRange` updates `NSTextStorage` and moves the selection to the end of the provisional or final replacement, but never asks the enclosing `NSScrollView` to reveal that selection. Programmatic `setSelectedRange` does not scroll the clip view by itself. This is especially visible while streaming mixed Chinese and English into the initially compact editor.

## Desired Behavior

- Keep the existing source-editor sizing policy: grow from two rows up to seven rows.
- Once content exceeds the seven-row viewport, keep the popover at its existing maximum height and scroll only the editor content.
- During dictation, keep the caret created by the latest provisional or final replacement visible.
- For dictation inserted in the middle of a draft, reveal the resulting caret rather than forcing the editor to the document bottom.
- Leave ordinary typing, user-controlled scrolling, selection, IME composition, cancellation, undo, and result-editor behavior unchanged.

## Selected Repair

After `replaceOwnedRange` updates the text and sets the new collapsed selection, call `scrollRangeToVisible` with that selection. This belongs in `DictationEditorTransaction` because that component owns both the programmatic replacement and the caret movement.

The call applies only to provisional and final dictation replacements. It does not run from general SwiftUI model synchronization, so unrelated state updates cannot pull the viewport away from a user's manual scroll position. The existing UTF-16 `NSRange` remains the source of truth, preserving correct behavior for Chinese, emoji, combining marks, and insertion at arbitrary positions.

No new error state is required: scrolling is a local AppKit visibility request and does not change the transaction's text or lifecycle semantics.

## Interaction States

- **Idle and manual editing:** unchanged; the native editor retains normal keyboard and scrolling behavior.
- **Dictation below the height cap:** the popover may continue growing normally, while revealing the caret is harmless.
- **Dictation above the height cap:** the editor viewport follows the latest provisional caret and the action bar remains fixed below it.
- **Finalization:** the final replacement uses the same path, remains visible, and becomes editable when the transaction restores interaction.
- **Cancellation or failure:** the existing snapshot restoration path remains unchanged and does not introduce a new forced scroll.
- **Undo and redo:** existing transaction registration and selection restoration remain unchanged.

## Alternatives Considered

1. Enable a visible vertical scroller. This would improve overflow discoverability but changes the compact visual design and does not by itself guarantee caret following during programmatic updates.
2. Replace the hidden SwiftUI text measurement and 72-character estimate with native layout-manager height reporting. This could improve CJK and mixed-text growth accuracy, but it is a broader layout change and scrolling is still required after the seven-row cap.

Both alternatives are outside this repair. Native height measurement can be considered separately if mixed-language autosizing remains inaccurate after caret visibility is fixed.

## Test Contract

Add a focused AppKit behavior test to `DictationEditorTransactionTests`:

- Place the real test `NSTextView` inside a short `NSScrollView` configured for wrapping and vertical growth.
- Start a transaction at the source caret and apply a long provisional replacement containing explicit Chinese and English lines.
- Ensure text layout, resolve the line fragment containing the final caret, and assert that it lies inside the text view's visible rectangle.
- Run the test before the production change and observe it fail because the clip view remains at the top.
- Add the single visibility call, rerun the test, and observe it pass.

The test uses explicit newlines and AppKit geometry rather than character-width estimates or screenshot pixels, making it stable across fonts and languages. Existing transaction tests continue to cover exact text, UTF-16 ranges, underline ownership, commit, cancellation, undo, redo, and focus behavior.

## Verification

- Capture the focused caret-visibility regression failing before the repair and passing afterward.
- Run all `DictationEditorTransactionTests`.
- Run the complete `swift test` suite and strict warnings-as-errors builds.
- Run `git diff --check` and inspect final status.
- Increment the patch version and build number before creating another local bundle.
- Build, sign, install, and launch `/Applications/Inklet Local.app` through `scripts/run-local-app.sh`.
- Leave the final physical long-dictation check to the user: hold Right Option long enough to exceed the visible rows, confirm the newest text remains visible above the action bar, release, and confirm the draft remains editable.

No localization or README changes are required because this repair changes no user-facing copy, setup, provider behavior, or documented command.
