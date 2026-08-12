# Inklet

[English](README.md) | [简体中文](README.zh-CN.md)

Homepage: [gitinklet.app](https://gitinklet.app)

**Turn rough thoughts into clear text.**

**Inklet** is a macOS writing assistant that helps you turn typed, pasted, or spoken thoughts into clear text without leaving the app you are already using.

Use the global shortcut to open a small writing popover, or use the voice shortcut to dictate a short phrase. Inklet can rewrite, summarize, clean up speech transcription, and insert the result back into the text field you were using.

## Demo

Watch the demo video: [Inklet on YouTube](https://www.youtube.com/watch?v=F5wmFruo0a4).

## Install

GitHub Releases is Inklet's only supported distribution channel. Download the latest signed and notarized DMG from [GitHub Releases](https://github.com/wanming/Inklet/releases), open it, and copy Inklet to `/Applications`.

Alternatively, use the install script below. The install script downloads the latest GitHub Releases DMG and checksum, verifies the DMG structure, checksum, Gatekeeper acceptance, bundle identifier, Hardened Runtime, effective entitlements, and app signature, and then copies Inklet to `/Applications`.

```bash
curl -fsSL https://raw.githubusercontent.com/wanming/Inklet/main/scripts/install.sh | bash
```

## First-Time Setup

1. Open Inklet from your Applications folder. For a source build, run `scripts/run-local-app.sh` from the repository root, then use `/Applications/Inklet Local.app`.
2. Click the Inklet menu bar icon and open Settings.
3. Grant Accessibility permission when macOS asks. Inklet uses this one generic permission to read selections, perform a configured copy fallback, return focus to the previous app, and paste confirmed results. Inklet stays in the background while System Settings is open and returns to General settings when you close it.
4. Enter your OpenAI API key in General. Inklet uses this one key for writing, voice transcription, selection translation, and pronunciation.
5. Configure Write Assistant with the model, writing shortcut, generation settings, and prompt modes you want to use.
6. Optional: configure Voice Write Assistant with a microphone, speech preset, voice shortcut, recording mode, and what happens after transcription.
7. Optional: configure Selection Assistant with a translation language, AI pronunciation voice, and pronunciation speed, then preview the voice in Settings.
8. Grant Microphone permission the first time you use voice dictation.

## Everyday Use

Text workflow:

1. Focus any text field in another app.
2. Press `Option+Space`.
3. Type or paste rough text.
4. Press `Enter` to transform it.
5. Press `Enter` again to insert the result.

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
- Uses one application-agnostic, Accessibility-first selection path. Automatic Selection Actions first ask macOS Accessibility for the selection, then use the configured temporary clipboard fallback only when Force Selection permits it. Each read stays bound to the captured source process and cancels if that process exits or loses focus.
- Serializes temporary clipboard reads and restores the prior snapshot only while the same read still owns the observed copy result; newer clipboard contents win. The double-copy trigger is passive: it consumes the copy the user already made without issuing another synthetic copy or restoring older clipboard data. Right-click remains native and never starts a selection read.
- Does not use browser-specific selection code and does not request browser Automation. Chrome, Safari, Edge, and native apps use the same generic path.
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
- Accessibility permission for Inklet, required for generic selection reading, configured copy fallback, returning focus to the previous app, and pasting the generated result.
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
- `Enter`: transform the source text, or insert the generated result when a result is already shown.
- `Command+Enter`: insert the original text without calling the model.
- `Command+Up` / `Command+Down`: cycle through visible prompt modes.
- `Escape`: clear the result or close the popover.
- `Command+,`: open Settings while Inklet is active.

Prompt modes also have default shortcuts such as `Command+1` through `Command+6` in the mode list.
The first visible prompt mode in Settings is selected when the popover opens.

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
- Use `scripts/run-local-app.sh` instead of a bare SwiftPM executable or `open dist/...` for routine app hand-testing, so local Accessibility and Keychain approvals stay attached to one stable app identity.
- Treat the clipboard and Accessibility flows carefully; they are central to the app experience.
- The project is still MVP-stage, so README details should track the code rather than future plans.

## Local Storage And Upgrades

Production and local QA builds use bundle-qualified storage and do not share settings, History, translation cache, diagnostics, or Keychain credentials:

- Production Application Support: `~/Library/Application Support/com.tomwan.inklet/`
- Local Application Support: `~/Library/Application Support/com.tomwan.inklet.local/`
- Production preferences: `~/Library/Preferences/com.tomwan.inklet.plist`
- Local preferences: `~/Library/Preferences/com.tomwan.inklet.local.plist`
- Production Keychain service: `Inklet.ProviderAPIKey`
- Local Keychain service: `Inklet.Local.ProviderAPIKey`

On first launch after upgrading from the legacy sandboxed build, Inklet automatically copies recognized legacy preferences, provider API keys into the matching Keychain service, and History into the current bundle's storage. It does not delete or modify the legacy source, so the old data remains available for rollback or recovery. The disposable translation cache is not migrated.

If macOS blocks automatic access to the matching legacy container, Settings keeps an **Import Old Data…** action available. The assisted import validates the exact legacy `Data` folder for the running production or local bundle, reads it only while the current file-panel grant is valid, and does not save a persistent access bookmark.

## Privacy

- Inklet uses your configured OpenAI API key to call OpenAI for writing, voice transcription, selection translation, and pronunciation.
- Voice dictation sends temporary audio to OpenAI transcription.
- Your OpenAI API key is stored locally on your Mac.
- Inklet uses Accessibility permission for generic selection reading, configured copy fallback, returning focus to the previous app, and pasting text.
- Inklet uses Microphone permission only while recording voice dictation.
- Inklet temporarily uses the clipboard for insertion and configured Force Selection fallback reads. A Force Selection read restores the previous clipboard only if Inklet's temporary copied value is still current, and does not overwrite a later external clipboard change.
- Inklet saves successful Write, Voice, and Selection source/result text locally in History until you clear it in Settings, while skipping consecutive duplicate entries.
- Selection Actions capture the source app and selection location, validate that source before and during the read, and use Accessibility to read its current selection. If Accessibility does not return selected text, the configured Force Selection mode can briefly invoke menu Copy and/or `Command+C` and read the resulting clipboard text through the protected transaction described above. You can turn Force Selection off in Settings. This path sends no browser-targeted Apple Events and does not request browser Automation. Pressing `Command+C` twice quickly after selecting text explicitly reads the copy you already made. Inklet does not save merely selected text unless a successful action is recorded in local History.
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
