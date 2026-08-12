# Inklet

[English](README.md) | [简体中文](README.zh-CN.md)

Homepage: [gitinklet.app](https://gitinklet.app)

**Turn rough thoughts into clear text.**

**Inklet** is a macOS writing assistant that helps you turn typed, pasted, or spoken thoughts into clear text without leaving the app you are already using.

Use the global shortcut to open a small writing popover, or use the voice shortcut to dictate a short phrase. Inklet can rewrite, summarize, clean up speech transcription, and insert the result back into the text field you were using.

## Demo

Watch the demo video: [Inklet on YouTube](https://www.youtube.com/watch?v=F5wmFruo0a4).

## Install

Mac App Store: coming soon.

Alternatively, download the latest signed and notarized DMG from [GitHub Releases](https://github.com/wanming/Inklet/releases), or use the install script below. The script downloads the latest DMG, verifies its checksum, checks Gatekeeper and the app signature, and copies Inklet to `/Applications`.

```bash
curl -fsSL https://raw.githubusercontent.com/wanming/Inklet/main/scripts/install.sh | bash
```

## First-Time Setup

1. Open Inklet from your Applications folder. When running from source, use `scripts/run-local-app.sh` to build, install, and launch the stable `/Applications/Inklet Local.app` bundle.
2. Click the Inklet menu bar icon and open Settings.
3. Grant Accessibility permission when macOS asks. Inklet needs this to return focus to the previous app and paste the result. Inklet stays in the background while System Settings is open and returns to General settings when you close it.
4. Enter your OpenAI API key in General. Inklet uses this one key for writing, voice transcription, selection translation, and pronunciation.
5. Configure Write Assistant with the model, writing shortcut, generation settings, and prompt modes you want to use.
6. Optional: configure Voice Write Assistant with a microphone, speech preset, voice shortcut, recording mode, and what happens after transcription.
7. Optional: configure Selection Assistant with a translation language, AI pronunciation voice, and pronunciation speed, then preview the voice in Settings.
8. Grant Microphone permission the first time you use voice dictation.

## Everyday Use

Text workflow:

1. Focus any text field in another app.
2. Press `Option+Space`.
3. Fuzzy-search for a prompt mode (for example, `ts` can match `To Chinese Summary`), use `Up` / `Down` to highlight it, then press `Tab` to commit the mode.
4. Type or paste rough text.
5. Press `Enter` to transform it.
6. Press `Enter` again to insert the result.

Voice workflow:

1. Focus any text field in another app.
2. Hold Right Option to record with the selected microphone.
3. Speak a short phrase.
4. Release Right Option to stop recording.
5. Inklet transcribes the audio, then either uses your cleanup mode, asks you to choose a prompt mode, or inserts the raw transcript based on your Voice settings.

The default voice shortcut is Right Option with press-and-hold recording. In Settings, you can change the shortcut to Right Command, Left Option, Left Command, or Disabled, and you can choose press-and-hold, tap-to-toggle, or double-tap recording.

## What It Does

- Opens from a global macOS hotkey. The default is `Option+Space`.
- Starts short voice dictation from a modifier-key shortcut. The default is Right Option with press-and-hold recording; tap-to-toggle and double-tap modes are also available.
- Shows Selection Actions after you select text in another Mac app and pause briefly, with EasyDict-style selection reading, quick translation, a customizable Translate prompt, AI pronunciation, resizable translation results that remember their last size, and 7-day local caching for repeated translations.
- Ignores selected text longer than 1,500 characters to avoid accidental long-page triggers.
- Plays selected text directly, and can play both the original text and translated text from the translation result.
- Transforms text with built-in prompt modes:
  - To Simple and Correct English
  - To Chinese Summary
  - Voice Cleanup
- Inserts generated text back into the previously focused app.
- Restores your clipboard after insertion and force-selection reads. Automatic Selection Actions use Accessibility first, browser JavaScript where supported, then the configured Force Selection fallback; pressing `Command+C` twice quickly can explicitly trigger Selection Actions from the copied clipboard text.
- Lets you edit prompt modes, OpenAI model, timeout, temperature, writing shortcut, voice shortcut, voice recording mode, microphone, speech preset, speech endpoint, speech model, post-transcription handling, selection translation language, selection Translate prompt, Force Selection mode, AI pronunciation voice, and AI pronunciation speed.
- Shows local History for successful Write, Voice, and Selection results, with consecutive duplicate entries collapsed, selectable source/result text, a result copy control, and a clear-all action.
- Uses one shared OpenAI API key for writing, voice transcription, selection translation, and pronunciation.
- Provides English and Chinese app UI localization.

## Current Status

Inklet is an early MVP. The repository currently includes:

- A Swift Package for the macOS app and core writing engine.
- A menu bar app with a writing popover and settings window.
- Provider adapters and configuration storage.
- Unit tests for core behavior.
- Manual test notes in [docs/manual-test-checklist.md](docs/manual-test-checklist.md).

## Requirements

- macOS 14 or newer.
- Swift 6 toolchain.
- Full Xcode is recommended for XCTest support.
- Accessibility permission for Inklet, required for returning focus to the previous app and pasting the generated result.
- Microphone permission for voice dictation.
- An OpenAI API key.

## Build And Run

From the repository root:

```bash
swift build
scripts/run-local-app.sh
```

Use `scripts/run-local-app.sh` for routine manual app testing from any worktree. It installs and opens the stable `/Applications/Inklet Local.app` identity so macOS Accessibility and Keychain trust can be reused across rebuilds.

Run tests:

```bash
swift test
```

If tests fail because `XCTest` is unavailable, install the full Xcode app instead of using only Command Line Tools.

## Keyboard Flow

- `Option+Space`: open the writing popover.
- `Right Option`: hold to record voice dictation by default. This shortcut and its hold, tap, or double-tap recording mode can be changed or disabled in Settings.
- `Up` / `Down` in the mode launcher: move the highlight through fuzzy-ranked prompt modes.
- `Tab` in the mode launcher: commit the highlighted prompt mode and focus the source editor.
- `Return` in the mode launcher: outside active IME composition, it is consumed, performs no launcher action, and leaves the launcher open. During composition, it remains available to confirm text or an IME candidate.
- `Enter` in the editor: transform the source text, insert a result generated by the current mode, or regenerate a stale result from a previous mode with the newly committed mode.
- `Command+Enter`: insert the original text without calling the model.
- `Command+Up` / `Command+Down`: cycle through visible prompt modes.
- `Escape`: move back one level per press, from the result to the source editor, then to the mode launcher, then close the popover. While transforming, it cancels generation and stays in the editor.
- `Command+,`: open Settings while Inklet is active.

Search is case- and diacritic-insensitive and supports ordered-character matching. Exact and prefix matches receive the strongest boosts; consecutive, word-start, earlier, and tighter matches generally rank higher.

When the mode launcher opens, the last committed prompt mode is highlighted if it is still visible. A single click highlights a mode; a double-click commits it. Returning to the launcher keeps the current draft and result.

## Repository Layout

```text
Sources/InkletApp/       macOS app, popover UI, settings UI, menu bar coordination
Sources/InkletCore/      core config, providers, prompts, hotkeys, insertion, state machine
Tests/InkletCoreTests/   unit tests for core behavior
docs/                           manual QA and privacy policy
```

## Development Notes

- Keep provider behavior covered by focused unit tests.
- Use [docs/manual-test-checklist.md](docs/manual-test-checklist.md) before shipping user-facing app changes.
- Use `scripts/run-local-app.sh` for routine app hand-testing rather than opening worktree-local `dist/...` bundles, so local Accessibility and Keychain approvals stay attached to one stable app identity.
- Treat the clipboard and Accessibility flows carefully; they are central to the app experience.
- The project is still MVP-stage, so README details should track the code rather than future plans.

## Privacy

- Inklet uses your configured OpenAI API key to call OpenAI for writing, voice transcription, selection translation, and pronunciation.
- Voice dictation sends temporary audio to OpenAI transcription.
- Your OpenAI API key is stored locally on your Mac.
- Inklet uses Accessibility permission to return focus to the previous app and paste text.
- Inklet uses Microphone permission only while recording voice dictation.
- Inklet temporarily uses the clipboard for insertion and configured Force Selection fallback reads, then restores the previous clipboard contents.
- Inklet saves successful Write, Voice, and Selection source/result text locally in History until you clear it in Settings, while skipping consecutive duplicate entries.
- Selection Actions use Accessibility to read the current selection after you select text in another app. For supported browsers, Inklet can use browser JavaScript to read `window.getSelection()`. If Accessibility and browser reading fail, the configured Force Selection mode can briefly invoke menu Copy and/or `Command+C`, restore the previous clipboard, and use the copied text. You can turn Force Selection off in Settings. Pressing `Command+C` twice quickly after selecting text explicitly reads the copied clipboard text. Inklet does not save merely selected text unless a successful action is recorded in local History.
- Selection Assistant caches successful translation results locally for 7 days using hashed cache keys to speed repeated translations.
- Selection Assistant translation sends selected text and your custom Translate instructions to OpenAI when no local cached translation is available; AI pronunciation sends selected text to OpenAI.
- Inklet fetches the public model catalog from `models.dev` at most once per day. This request does not include your text, audio, API keys, or app settings.
- Do not send private text or audio to OpenAI unless you trust OpenAI's data handling policies.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting and sensitive data guidance.

## License

Inklet is released under the [MIT License](LICENSE).
Third-party notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
