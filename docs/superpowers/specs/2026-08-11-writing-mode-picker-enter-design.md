# Writing Mode Picker Enter Navigation Design

## Goal

Let users enter the highlighted writing mode from the mode picker with Return or keypad Enter, while preserving the existing Tab interaction and native input-method behavior.

## Interaction

- Plain Return and keypad Enter commit the currently highlighted mode, exactly like Tab.
- Tab remains supported.
- Command-, Shift-, Option-, or Control-modified Return does not commit a mode.
- While an input method has marked text, Return and keypad Enter remain owned by the input method so users can confirm a candidate without leaving the picker.
- When filtering has no result and no highlighted mode, Return and keypad Enter are consumed but do not enter the editor.
- The highlighted row and footer show both `↵` and `tab` beside the existing localized Write label.

## Implementation

Extend `WritingPopoverKeyboardPolicy` so unmodified Return key codes 36 and 76 return `.commitMode` on the mode-picker route. Reuse the existing `commitHighlightedMode()` boundary, which already handles the no-highlight case safely. Update `WritingModePickerView` hints without adding new localized copy.

## Verification

- Executable policy tests cover main Return, keypad Enter, modifier combinations, IME composition, Tab, and no-result behavior.
- Source/UI tests cover both visible key hints.
- Manual app verification covers Return from the initial picker, Return after searching, IME candidate confirmation, and a no-result query.
