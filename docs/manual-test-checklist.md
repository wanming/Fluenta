# Manual Test Checklist

## Preparation

- Launch the installed release app bundle. For source or local testing, run `scripts/run-local-app.sh` and use `/Applications/Inklet Local.app` so Accessibility and Keychain approvals stay attached to its stable identity.
- Configure an LLM provider and API key in Settings.
- Configure Voice settings with a speech API key if testing dictation.
- Grant Accessibility permission in macOS System Settings.
- Grant Microphone permission when prompted during dictation.
- Confirm the default global hotkey is `Option+Space`, unless you intentionally changed it.
- Confirm the default voice shortcut is Right Option and the default recording mode is Press and Hold, unless you intentionally changed them.

## Core Flow

- TextEdit: focus a text field, press `Option+Space`, enter text, press `Enter` to transform, then press `Enter` again to insert the result.
- TextEdit: enter a rough English sentence, improve it, then insert the result.
- Notes: repeat the transform and insert flow.
- Safari or Chrome: repeat the flow in a web text field.
- Selected text: select text in another app, open Inklet, and confirm the selected text appears in the source editor.
- `Command+Enter`: insert the original source text without calling the model.
- `Command+Up` / `Command+Down`: cycle through visible prompt modes.
- `Escape`: close the popover without inserting text.
- Missing API key: show an inline error while preserving the source text.
- Network or provider failure: show an inline error while preserving the source text.
- Paste failure: keep the generated result visible so the user can copy or retry.
- Clipboard restoration: after insertion, confirm the previous clipboard contents are restored.

## Voice Dictation

- TextEdit: focus a text field, hold Right Option, speak a short phrase, release Right Option, and confirm text is inserted.
- Change Voice Recording Mode to Tap Once; tap the configured shortcut to start, tap it again to stop, and confirm text is inserted.
- Change Voice Recording Mode to Double Tap; double-tap the configured shortcut to start, double-tap it again to stop, and confirm text is inserted.
- Confirm the compact voice window shows Listening, Transcribing, Polishing, and Inserting states.
- Press Escape while Listening and confirm nothing is inserted.
- Disable Auto Process in Voice settings and confirm raw transcription is inserted.
- Enable Auto Process and select Voice Cleanup; confirm the inserted text preserves language and meaning without summarizing.
- Select System Default in Voice settings and confirm dictation records from the current macOS default input.
- Select a concrete microphone in Voice settings and confirm dictation records from that input.
- Disconnect or disable the selected microphone and confirm dictation falls back to System Default, or shows the no-audio-input error if no input is available.
- Remove the speech API key and confirm dictation shows a clear error without inserting.
- Deny Microphone permission and confirm dictation shows a clear error without inserting.
- Change the voice shortcut to Right Command, Left Option, Left Command, and Disabled, then confirm each setting applies with the selected recording mode.

## Selection Actions

- Select text in another app and pause briefly; confirm the compact menu appears with Translate and Pronounce.
- Translate selected text and confirm the result remains visible with copy, original-audio, and translated-audio controls.
- Translate the same selected text with the same Selection Assistant settings again and confirm the cached result appears quickly.
- Confirm a successful selection translation appears in Settings > History with the original text and translated result.

## Settings

- `Command+,`: open Settings while Inklet is active.
- General: change hotkey, timeout, temperature, language, and appearance.
- Providers: configure one provider, API key, model, and custom OpenAI-compatible endpoint when needed.
- Voice: configure shortcut, microphone, speech API key, speech endpoint, speech model, auto-processing, and cleanup prompt mode.
- Prompt Modes: add, edit, hide, delete with confirmation, and reorder prompt modes.
- Permissions: verify Accessibility status and the button that opens System Settings. Inklet should not steal focus while System Settings is open; close System Settings and confirm the existing Inklet Settings window returns with the refreshed status.
- History: confirm successful Write, Voice, and Selection results appear with the newest item first.
- History: repeat the same successful action twice in a row and confirm only one new item appears; repeat it again after a different item and confirm it is kept.
- History: filter by Write, Voice, and Selection; select original/result text; copy result text; clear history and confirm the empty state.
- First-time onboarding: with no provider API key configured, grant Accessibility permission, close System Settings, and confirm the existing Inklet Settings window returns on the Providers page.
- Save behavior: confirm changes persist after quitting and reopening Inklet.

## Compatibility Smoke Tests

- Slack or Discord.
- Notion.
- VS Code or Cursor.
- Terminal or iTerm. Record behavior, but do not treat terminal insertion issues as release blockers for the MVP.
