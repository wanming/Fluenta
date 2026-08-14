# Inklet Privacy Policy

Last updated: August 13, 2026

## Overview

Inklet is a macOS writing assistant. It helps you transform typed, pasted, or spoken text using the AI provider and speech provider you configure.

Inklet does not require an Inklet account and does not send your content to Inklet-controlled servers.

## Information Processed

Inklet may process:

- Text you type or paste into Inklet.
- Text selected or copied by you for insertion workflows.
- Text selected by you for Selection Actions.
- Successful Write, Voice, and Selection source/result text saved in local History.
- Successful Selection translation results cached locally for repeat use.
- Temporary audio recorded when you start voice dictation.
- API keys and provider settings you enter.
- App settings such as prompt modes, model choices, shortcuts, and preferences.

## How Information Is Used

Inklet uses this information to:

- Transform or summarize text.
- Transcribe voice dictation.
- Insert text into the app you were using.
- Show past successful results in local History.
- Speed repeated Selection translation requests with a local cache.
- Save your local settings.
- Store provider API keys locally.

## AI And Speech Providers

Inklet sends text and audio only to the provider endpoints you configure for app functionality.

Text may be sent to the selected AI provider for rewriting, summarization, or cleanup. Audio may be sent to the selected speech transcription provider for voice dictation.

Provider handling of your data is governed by the provider's own privacy policy and account terms. Do not send private text or audio to a provider unless you trust that provider.

Inklet may fetch the public model catalog from `models.dev` periodically, currently no more than once per day. This request does not include your text, audio, API keys, or app settings.

## Selection Actions

When Selection Actions are enabled, Inklet watches for selection-related mouse and keyboard events and then uses macOS Accessibility to read the currently selected text after a short pause. For supported browsers, Inklet may use browser JavaScript to read `window.getSelection()`. Menu Copy is the default final fallback when those methods do not return selected text. These automatic defaults do not synthesize keyboard input, and you can turn Force Selection off in Settings.

Simulated `Command+C` is off by default. If you explicitly enable this advanced fallback, Inklet may post `Command+C` to the foreground app after rechecking that the same app is still active. This can interfere with games, remote desktops, or virtual machines. One `Command+C` only performs the normal copy action. Two deliberate, separate quick presses explicitly read the changed clipboard text and open Selection Actions; holding the key does not count as two presses. Inklet does not store merely selected text unless a successful action is saved in local History.

Inklet's local Selection Actions diagnostic log may record timestamps, foreground app identifiers or process IDs, key codes, modifier bits, key-repeat and event-provenance metadata, and handling decisions. Repeated identical events are rate-limited. The diagnostic log never records typed characters, selected text, or clipboard contents.

If you choose Translate, Inklet first checks for a local cached translation. When no cached translation is available, the selected text and your custom Translate instructions are sent to your configured LLM provider. If you choose Pronounce, the selected text is sent to OpenAI text-to-speech using your OpenAI API key. Some apps may still block Accessibility, browser, and Force Selection reads; in those apps the floating menu may not appear automatically.

## Local Storage

Inklet stores API keys locally in macOS Keychain. Inklet stores app preferences locally on your Mac.

Inklet stores successful Write, Voice, and Selection source/result text locally in History until you clear it in Settings.

Inklet caches successful Selection translation results locally for 7 days using hashed cache keys, so repeated translations can return faster without another provider call.

Inklet temporarily uses the clipboard to insert text into the active app and for configured Force Selection fallback reads, then attempts to restore the previous clipboard contents.

## Permissions

Inklet requests the following macOS permissions:

- Accessibility: used to return focus to the previous app, insert text after you confirm insertion, inspect focused controls, invoke menu Copy when Force Selection is enabled, and read selected text for Selection Actions after you select text. If you explicitly enable simulated-copy fallback, it may also post `Command+C` to the foreground app.
- Microphone: used only while recording voice dictation that you start.

Inklet does not use these permissions to collect text from other apps in the background.

## Analytics And Tracking

Inklet does not include third-party advertising, tracking, or analytics in the current app.

If this changes, this policy and App Store privacy details must be updated before release.

## Data Retention

Inklet does not operate a server that stores your text, audio, API keys, or settings.

Data sent to your configured providers may be retained according to those providers' own policies.

Local History stays on your Mac until you clear it in Settings or remove the local app data. Local Selection translation cache entries expire after 7 days.

## Contact

For support or privacy questions, contact:

support@getinklet.app

## Changes

This policy may be updated as Inklet changes. The updated date at the top of this page will reflect the latest version.
