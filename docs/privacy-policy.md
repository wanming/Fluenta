# Inklet Privacy Policy

Last updated: August 12, 2026

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

When Selection Actions are enabled, Inklet watches for selection-related mouse and keyboard events. It captures the source app's process identifier and selection location, confirms that the captured source process is still running and frontmost, and then uses macOS Accessibility to read the current selection after a short pause. A focus change, cancellation, timeout, protected field, or source-process mismatch produces no selection result.

If Accessibility does not return selected text, the configured Force Selection mode may use a temporary clipboard transaction to invoke menu Copy. Simulated `Command+C` is off by default and runs only after you explicitly enable the advanced fallback. Inklet allows only one such transaction at a time, snapshots the pasteboard, and restores that snapshot only if the same transaction still owns the observed copy-result change count. If you or another app changes the pasteboard, newer clipboard contents win and Inklet leaves them untouched. You can turn Force Selection off in Settings.

The double-copy trigger reads the copy you made by pressing `Command+C` twice quickly; it does not issue another synthetic copy or restore older clipboard data. Right-click remains the source application's native context-menu action and does not start a selection read. The generic path sends no browser-targeted Apple Events and does not request Automation permission.

Mere selection or copying does not persist text to disk. A selection result may remain in process memory as Inklet's current selection state until it is replaced or cleared, or until Inklet exits. Only successful Selection actions are saved in local History; successful translations may also be stored in the 7-day local translation cache.

If you choose Translate, Inklet first checks for a local cached translation. When no cached translation is available, the selected text and your custom Translate instructions are sent to your configured LLM provider. If you choose Pronounce, the selected text is sent to OpenAI text-to-speech using your OpenAI API key. Some apps may still block Accessibility and Force Selection reads; in those apps the floating menu may not appear automatically.

## Local Storage

Production and local QA builds use separate bundle-qualified local stores:

- Production preferences: `~/Library/Preferences/com.tomwan.inklet.plist`
- Local preferences: `~/Library/Preferences/com.tomwan.inklet.local.plist`
- Production Application Support: `~/Library/Application Support/com.tomwan.inklet/`
- Local Application Support: `~/Library/Application Support/com.tomwan.inklet.local/`
- Production Keychain service: `Inklet.ProviderAPIKey`
- Local Keychain service: `Inklet.Local.ProviderAPIKey`

Within each Application Support root, Inklet stores successful Write, Voice, and Selection source/result text in `history.jsonl` until you clear History in Settings. It stores successful Selection translations in `selection-translation-cache.json` for 7 days using hashed cache keys.

Selection diagnostics use the bundle-qualified temporary filename `$TMPDIR/InkletSelectionActions.<bundle-identifier>.log`. Diagnostics may include event type, source app bundle identifier or process identifier, read status, character count, and window geometry; repeated identical event entries are rate-limited. They do not include selected-text contents, clipboard contents, typed characters, provider keys, prompt text, generated text, or audio.

Provider API keys are stored as generic-password items in macOS Keychain, using the production or local service above and the provider identifier as the account. Inklet does not intentionally store active provider credentials in plaintext preferences.

## Legacy Data Migration

On launch, Inklet checks the matching legacy source at `~/Library/Containers/<bundle-identifier>/Data/`. It automatically copies recognized Inklet preferences, legacy provider credentials into the matching Keychain service when no destination credential exists, and History into the bundle-qualified destination. It does not delete or modify the legacy source. The disposable legacy translation cache is not migrated.

Migration is versioned and retry-safe. If both old and new History exist, Inklet merges records by identifier and keeps the destination record on a duplicate. Existing destination Keychain items are not overwritten. Delayed preference import preserves settings changed after the upgrade attempt.

If macOS blocks automatic source access, Settings offers **Import Old Data…**. The file panel accepts only the canonical legacy `Data` folder for the running production or local bundle. Inklet uses that file-panel access only for the in-process import, stops accessing it when the import finishes, and does not save a persistent bookmark. Import pauses active selection, voice, and settings work; if destination data changes, Inklet relaunches before normal work resumes.

## Permissions

Inklet requests the following macOS permissions:

- Accessibility: used to return focus to the previous app, insert text after you confirm insertion, inspect focused controls, invoke menu Copy when Force Selection is enabled, and read selected text for Selection Actions after you select text.
- Microphone: used only while recording voice dictation that you start.

Accessibility is the generic permission used for selection reading and simulated input. Inklet does not request browser-specific permissions or Automation permission. Inklet does not use Accessibility or Microphone permission to collect text or audio from other apps in the background.

## Analytics And Tracking

Inklet does not include third-party advertising, tracking, or analytics in the current app.

If this changes, this policy must be updated before release.

## Data Retention

Inklet does not operate a server that stores your text, audio, API keys, or settings.

Data sent to your configured providers may be retained according to those providers' own policies.

Local History stays on your Mac until you clear it in Settings or remove the corresponding bundle's local app data. Local Selection translation cache entries expire after 7 days. Legacy source data remains in its original container unless you remove it separately.

## Contact

For support or privacy questions, contact:

support@getinklet.app

## Changes

This policy may be updated as Inklet changes. The updated date at the top of this page will reflect the latest version.
