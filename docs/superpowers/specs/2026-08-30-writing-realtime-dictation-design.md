# Realtime Dictation In Writing Assistant Design

## Goal

Merge voice dictation completely into Writing Assistant and replace the standalone Voice Write Assistant workflow with realtime speech-to-text inside the editable source draft.

The user explicitly opens Writing Assistant, confirms a Prompt Mode, then holds the configured voice shortcut while speaking. Realtime text appears at the source editor's caret or replaces its current selection. Releasing the shortcut finalizes the transcript but does not run the Prompt Mode or insert text into another app. The user may edit the resulting draft and later press `Return` to run the selected Prompt Mode through the existing Writing Assistant flow.

This design favors a single, predictable writing surface over a second global voice workflow. It preserves a local recording only for recovery during the active dictation session and falls back to file transcription if the realtime connection fails.

## Current Behavior

Inklet currently exposes Writing Assistant and Voice Write Assistant as separate features:

- Writing Assistant opens a Prompt Mode picker, then an editable source/result workflow.
- Voice Write Assistant owns a separate global shortcut, recording modes, floating status UI, file transcription, optional cleanup or mode selection, and direct insertion into the previously focused app.
- Voice dictation is recorded to a temporary `.m4a` file and sent to the configured speech transcription endpoint after recording stops.
- Voice-specific configuration includes tap, hold, and double-tap gestures; automatic processing; post-transcription actions; and cleanup behavior.

That division duplicates interaction state, hides the editable transcript behind a separate flow, and makes realtime correction difficult. The new feature removes the standalone voice path rather than layering realtime behavior onto it.

## Approaches Considered

### 1. Dedicated WritingDictationCoordinator — Selected

Add a coordinator whose only product responsibility is a voice-backed edit transaction in the Writing source editor. Reuse accurate low-level primitives such as shortcut values, microphone discovery, and file transcription, while deleting the old voice-only orchestration.

This keeps realtime transport, audio capture, editor-range ownership, and recovery independently testable without carrying forward cleanup, Prompt Mode selection, external insertion, HUD, and standalone history branches.

### 2. Generalize VoiceInputCoordinator

Turn the existing standalone coordinator into a strategy-driven engine that can target either another application or the Writing editor.

This appears to reuse more code, but the existing coordinator's states and dependencies are centered on post-recording cleanup, mode selection, direct insertion, and voice history. Supporting realtime in-editor replacement would add parallel policies to nearly every state while retaining a workflow that the product is removing.

### 3. Put Dictation Directly In The Popover View Model

Let the current popover model own audio capture, WebSocket events, fallback, selection replacement, and visual state.

This minimizes the first prototype's file count, but couples AppKit selection/undo behavior and long-lived asynchronous resources to an already broad UI model. It also makes stale-event and cleanup tests depend on the popover. The dedicated coordinator is therefore the smallest durable boundary.

## Product Principles

- Dictation is an input method for a Writing Assistant draft, not a separate assistant.
- The user chooses and confirms a Prompt Mode before the voice shortcut can record.
- The source draft remains editable before and after dictation.
- Dictation never starts a Prompt request or external insertion automatically.
- Only press-and-hold recording is supported.
- Realtime transcription is the primary path; a temporary local recording makes one file-transcription recovery attempt possible.
- Errors and cancellation preserve user-authored text and never leave provisional text behind.
- The compact popover layout remains stable through idle, listening, finalizing, recovery, success, and error states.

## Approved Interaction

### Opening And Mode Confirmation

`Option+Space` continues to open Writing Assistant at the Prompt Mode picker. The voice shortcut has no effect in the picker and does not implicitly confirm the highlighted or previously used mode.

After the user confirms a Prompt Mode, Writing Assistant enters the source editor. The action bar shows a compact, non-clickable microphone status indicator and a localized hint equivalent to `Hold Right Option to dictate`, using the configured shortcut name. Recording cannot be toggled with a mouse or trackpad. There is no additional panel, primary button, or popover-height change.

The microphone permission prompt is deferred until the first valid long press while the source editor is active. Opening the popover, browsing modes, or making a short press must not request permission.

### Starting Dictation

A valid press-and-hold begins only when all of these conditions are true:

- Writing Assistant is in the editor route, not the mode picker.
- The popover is the active key panel.
- The source editor is the active dictation target.
- The app is not generating, inserting, cancelling, or handling another dictation session.
- The text system has no active marked-text composition.
- The configured shortcut is enabled and the hold threshold has been reached.

At the start boundary, Inklet captures the source editor's original text, selection, insertion target, and any currently visible Writing result state. If the user has selected text, dictation owns and replaces that selection. Otherwise it owns a zero-length range at the caret.

The editor locks manual editing, caret movement, and selection changes for the duration of the active dictation transaction. This prevents user input from invalidating the owned range while transcript deltas arrive. The rest of the source draft stays visible.

### Realtime Draft Updates

As transcript deltas arrive, Inklet serially aggregates accepted events for the active server item, then replaces the transaction-owned range with the latest cumulative provisional transcript. It does not append events blindly to the editor. Wrong-item and stale-session events are ignored; duplicate or out-of-order events are rejected when the server provides identifiers that make that determination possible. The owned range expands to the UTF-16 length of the latest replacement so subsequent updates remain aligned with AppKit's `NSRange` semantics, including Chinese text, emoji, and combining characters.

The client processes events on one serial receive path in WebSocket arrival order. It filters by active session and server item, and uses a server-provided event identifier or sequence only when one is available; it does not invent an ordering for events that the protocol cannot compare. The coordinator builds one cumulative provisional string from accepted deltas, while the completed event remains authoritative and may revise the whole provisional transcript.

Provisional text uses a restrained underline, optionally accompanied by a tint, so its temporary state is not conveyed by color alone and does not change layout. Accessibility announcements occur only when the dictation phase changes; individual words or tokens are not announced.

Only the source editor supports dictation in this version. The generated-result editor is not a voice target.

### Releasing And Finalizing

Releasing the voice shortcut stops audio input. If realtime remains available, Inklet drains pending audio and commits the realtime buffer; if realtime has already failed, it finalizes the recovery file instead. The action bar replaces the listening icon in place with a spinner while waiting for the terminal transcript. Button dimensions remain fixed.

On a successful final transcript:

- The final text atomically replaces the owned provisional range.
- Provisional styling is removed.
- The caret moves to the end of the inserted transcript.
- Manual editing is re-enabled.
- The entire dictation transaction is presented as one undoable edit.
- The temporary recovery recording is deleted.
- The popover remains in the source editor.
- Any result produced from the old source is invalidated once, using the existing successful source-edit behavior.

The selected Prompt Mode is not run automatically. The user may edit the draft and press `Return` later to perform the existing Writing Assistant transformation.

### Cancellation And Escape

Escape handling follows this priority:

1. Let the input method consume `Escape` when marked text is active.
2. If dictation is connecting, listening, recording for fallback, finalizing, or recovering, cancel only that dictation transaction.
3. Otherwise use the existing Writing Assistant result, editor, picker, and close navigation.

Cancelling dictation restores the exact text and selection that existed before the long press, removes provisional styling, stops audio and network work, deletes the temporary recording, re-enables editing, and leaves the user in the source editor. The same restoration and cleanup apply when the popover closes, loses its valid editing context, returns to mode selection, is superseded by a new session, or the app terminates.

## UI State Model

The existing action-bar location owns all visible dictation feedback:

| State | Action-bar presentation | Editor behavior |
| --- | --- | --- |
| Idle | Microphone icon and hold-shortcut hint | Editable |
| Connecting | In-place spinner or pending microphone state | Locked after a valid hold begins |
| Listening | Listening waveform or active microphone icon | Provisional range updates; manual edits locked |
| Finalizing | In-place spinner | Last provisional text remains visible; edits locked |
| Recording for fallback | Active microphone icon and a compact connection-lost state | Local recording continues until release; no more realtime deltas; edits locked |
| Recovering | Same stable spinner with localized file-recovery status available to accessibility | Last provisional text remains visible; edits locked |
| Complete | Return to idle icon | Final transcript editable |
| Error | Return to idle icon plus existing compact inline error treatment | Pre-dictation text restored; editable |

All icon-only controls have localized tooltips and accessibility labels. State changes never add a new row or shift the popover's content.

## Architecture

### WritingDictationCoordinator

A new `WritingDictationCoordinator` owns the complete dictation session and replaces the standalone `VoiceInputCoordinator`. It is dedicated to inserting a transcript transaction into the Writing source editor; it does not select Prompt Modes, clean text, transform text, write into other applications, or create standalone voice history.

Its observable phases are:

```text
idle -> connecting -> listening -> finalizing -> complete -> idle
          |              |             |
          +--------------+             +-> recovering -> complete | error -> idle
                         |
                         +-> recordingForFallback -> recovering on release

connecting | listening | recordingForFallback | finalizing | recovering
  -> cancelled -> idle
```

The coordinator owns:

- A unique session identifier used by every asynchronous callback.
- The `DictationEditorTransaction` for the current source-editor edit.
- The audio capture session and temporary fallback recording.
- The realtime transcription client and its receive task.
- Finalization and fallback timeout tasks.
- The single fallback-attempt flag.
- Cleanup and terminal-state arbitration.
- An idle/cancel-and-wait boundary used by app migration, maintenance, popover teardown, and application termination.

Every event checks the active session identifier before changing UI or text. The first terminal result wins. Once fallback begins, late WebSocket events are ignored. Once a session completes, errors, or is cancelled, all later audio, network, timer, and delegate callbacks are no-ops.

The coordinator contributes its active phases to the popover/app busy state. Maintenance or configuration migration cannot begin until dictation has cancelled, restored its editor transaction, closed transport and capture, and deleted its temporary file.

### Shortcut Scope

The voice shortcut is handled through app-local modifier events only within the active Writing popover/editor context. It does not use the old global event monitor, require Accessibility permission for dictation, reopen Writing Assistant, operate from other applications, or maintain the old standalone global voice workflow. Accessibility permission remains relevant only to the existing later insertion workflow when that workflow targets another app.

Reuse the existing modifier recognition semantics where they satisfy the popover-scoping rules, but remove tap-toggle and double-tap behavior. A press shorter than the hold threshold is a no-op. The recognizer must balance key-down/key-up and cancellation paths so a missed release cannot leave the coordinator listening.

Any observed release of the configured modifier finalizes an otherwise valid recording exactly once. If the popover loses its valid context before release, the session cancels and restores instead. Window deactivation and monitor teardown reset the recognizer, so a missing key-up event cannot carry an active gesture into the next activation.

Entering the editor while the configured modifier is already down does not count as a dictation press. The recognizer first waits for that modifier to be released, then requires a fresh press and hold. This prevents the Writing Assistant open shortcut or Prompt Mode confirmation gesture from leaking into dictation.

Retain the existing shortcut choices, including `Disabled`; `Right Option` remains the default. The UI describes every enabled choice as hold-only.

### Audio Capture

One audio-capture owner supplies both outputs from the same microphone session:

1. Mono 24 kHz signed PCM16 frames for the realtime transcription connection.
2. A temporary local audio recording for file-transcription recovery.

The capture layer continues to honor the saved microphone device selection and System Default fallback. It requests microphone permission only after a valid hold gesture, reports permission/device/session setup errors before any editor mutation becomes permanent, and exposes start, stop-and-finalize-file, and cancel operations.

Realtime frame conversion and file writing must not create competing capture sessions for the same device. Temporary files are session-scoped and deleted on realtime success, fallback completion, fallback failure, cancellation, invalid configuration, supersession, and application termination.

Capture begins as soon as permission, device, API-key, and session checks pass. While the WebSocket is connecting, a bounded in-memory PCM queue preserves early frames and the local recovery file records continuously. When the connection becomes ready, queued frames flush in order before live frames. If the connection does not become ready within its timeout or the queue reaches its bound, the coordinator marks realtime unavailable, stops sending live events, and continues the local recording until release for one fallback attempt. Audio is never silently dropped while the UI claims to be listening.

### RealtimeTranscriptionClient

`RealtimeTranscriptionClient` is a narrow protocol and transport implementation with no UI, editor, history, or Prompt Mode responsibilities. It connects to OpenAI's Realtime transcription endpoint with a transcription session configured for:

- Model `gpt-live-transcribe`.
- Mono 24 kHz PCM audio.
- Manual turn boundaries with server voice-activity detection disabled.
- Incremental `input_audio_buffer.append` events while recording.
- A buffer commit when the hold gesture is released.
- Incremental transcript deltas and one completed transcript event.

The API key uses the existing provider-key storage and error treatment. The realtime model is fixed for this feature and is not exposed as a normal Settings choice. The client supports explicit close/cancel, validates server errors, and maps connection, protocol, authentication, and final-transcript timeout failures into coordinator recovery or error states.

Release follows a strict transport order: stop producing new samples, wait for audio conversion and the serial append queue to drain, send the buffer commit exactly once, then wait for the completed transcript. The fallback file may finalize concurrently after samples stop, but file transcription cannot begin until file finalization succeeds. If any queued append fails, the realtime path loses terminal ownership and the coordinator follows the one-attempt fallback path.

Release while the client is still connecting enters `finalizing`: the bounded early-audio queue waits only for the remaining connection timeout, then either flushes and commits through the normal realtime path or proceeds to file fallback. The user never needs to keep holding the shortcut merely because the network handshake is unfinished.

### DictationEditorTransaction

`DictationEditorTransaction` isolates direct AppKit text editing from the SwiftUI popover model. It records:

- The target `NSTextView` identity.
- Original complete text or the minimal reliable restoration snapshot.
- Original UTF-16 selection.
- The current session-owned UTF-16 range.
- Whether provisional attributes are active.
- The pre-dictation Writing result and its producing-mode identity, when a result is visible.

It performs targeted text-storage replacements instead of assigning the entire bound string on every transcript update. A dedicated dictation-update path synchronizes provisional source text without triggering the normal source-change callback that invalidates an existing result. It also prevents SwiftUI from resetting selection or creating multiple undo records.

Its terminal operations are:

- `replaceProvisional(with:)` for the latest cumulative partial transcript.
- `commitFinal(_:)` for realtime or fallback success.
- `restore()` for cancellation, no-speech, or unrecoverable failure.

Provisional replacements do not create individual undo entries. A successful terminal replacement registers the complete original-to-final change as one undo operation and then triggers the normal source-change invalidation once. Cancellation or restoration leaves the undo stack as it was before dictation, returns text and selection exactly to the pre-dictation state, and preserves the result that was visible when the gesture began.

## Realtime And Fallback Data Flow

```text
valid hold
  -> begin editor transaction
  -> open realtime connection + start one audio capture
  -> stream PCM frames and write temporary recovery audio
  -> replace provisional source range from transcript deltas

release
  -> stop production of new audio samples
  -> drain audio conversion and ordered realtime append work
  -> commit realtime audio buffer exactly once
  -> finalize temporary audio concurrently before any fallback upload
  -> await first terminal outcome
       -> realtime final: commit transcript, delete file, finish
       -> realtime failure/timeout: close socket, transcribe file once
            -> fallback final: commit transcript, delete file, finish
            -> fallback failure/no speech: restore draft, delete file, error

cancel or invalidated context
  -> cancel capture/socket/tasks
  -> restore draft and selection
  -> delete file
```

The file fallback uses the existing speech transcription provider and the advanced endpoint/model configuration. It runs at most once per dictation. If the connection fails before release, the coordinator enters `recordingForFallback`: local capture continues until release, the UI tells the user that recording is still active, and no more realtime deltas are accepted. Release finalizes the file and enters `recovering`; `Escape` or context loss cancels and restores instead. If local capture itself fails, the transaction is cancelled immediately and restored.

The fallback provider rejects an empty or clearly invalid recording before upload. V1 retains the existing whole-file request construction; streaming multipart upload and longer-session memory optimization are out of scope. Upload-size or provider-limit errors still restore the transaction and delete the temporary file.

## Failure Semantics

- Short press or invalid editor context: no-op, no permission request, no text change.
- Microphone permission denied: preserve the current draft and show the existing actionable permission error.
- No valid audio input or capture setup failure: preserve the draft and show a localized recording error.
- Missing or invalid API key before capture can begin: preserve the draft and show the existing provider-key guidance.
- Permission response returns after the shortcut was released or the editor context changed: do not start capture and return to idle without changing text.
- Realtime authentication, connection, protocol, or finalization timeout: stop accepting realtime events and make one file fallback attempt after the audio file is finalized.
- Fallback success: commit through the same editor transaction as realtime success.
- Fallback failure: restore the pre-dictation text and selection and show a localized error with retry guidance.
- A technically successful realtime completion with an empty transcript: restore the pre-dictation state and show a concise no-speech result without invoking fallback.
- File fallback returns no speech after a realtime technical failure: restore the pre-dictation state and show the same concise no-speech result without another attempt.
- Popover dismissal, route change, supersession, or application exit: cancel and restore without surfacing a stale error in a later session.

No branch may leave the editor locked, provisional attributes applied, a socket/task running, or a temporary recording retained.

## Settings And Configuration Migration

Remove the `Voice Write Assistant` Settings section. Expand `Write Assistant` with visually consistent Writing and Dictation subsections.

The Dictation subsection exposes:

- Voice shortcut, described as press-and-hold.
- Microphone selection, including System Default and available devices.

Advanced Dictation settings retain only the file-recovery provider controls:

- Speech transcription endpoint.
- Speech transcription model.

Their labels and help text explicitly identify them as fallback settings. The realtime endpoint and `gpt-live-transcribe` model are fixed implementation details and are not user-editable in this version.

Keep the top-level `voiceInput` JSON key for import and tooling compatibility, but reduce its version 4 value to the live Dictation fields. Remove Recording Mode, Auto Process Transcription, Post-Transcription Action, Voice Cleanup Mode, and the now-fixed speech provider identifier from the live Settings UI, runtime model, and newly encoded configuration. Increment the configuration schema from version 3 to version 4 and migrate version 1 through version 3 configurations by preserving:

- The configured voice shortcut.
- The selected microphone device identifier.
- The speech transcription endpoint and model for fallback.

The version 4 decoder tolerates the removed legacy keys so existing configuration files load safely, but those values are no longer stored, encoded, or used. The fallback provider uses the app's canonical OpenAI provider-key identity. `Voice Cleanup` remains a normal visible Prompt Mode if present; it loses only its special role in the retired standalone voice workflow.

## History

Keep `HistorySource.voice` and its decoding/display behavior so existing JSONL history remains readable. Do not rewrite or delete historical entries.

Realtime dictation alone creates no history entry because it only edits the source draft. When the user later runs a Prompt Mode, the existing Writing transformation creates its normal `.write` history record. V1 does not add persisted voice-provenance fields; this avoids ambiguous metadata after the user edits a transcript or combines typed text with multiple realtime and fallback dictations. Any future provenance metadata must remain optional for older records and must never expose audio content or local file paths.

## Removed Standalone Surface

Remove the obsolete standalone voice feature and its wiring:

- Separate Voice Write Assistant entry, global voice launch, and recording workflow.
- `VoiceInputCoordinator` cleanup, mode-choice, polish, insertion, and fallback states.
- Voice-only status/HUD window.
- Post-transcription Prompt Mode chooser.
- Direct external-app insertion from voice dictation.
- Tap-toggle and double-tap recording modes.
- Voice-specific cleanup configuration and behavior.
- Source-contract tests and documentation that assert those retired surfaces.

Retain reusable primitives only when their naming and responsibilities remain accurate, such as shortcut modifier values, microphone discovery, and the file transcription provider.

## Privacy And Security

Documentation and in-app copy must state that active dictation audio is sent to the OpenAI Realtime transcription service as it is captured. Inklet also keeps a temporary local recovery recording for the duration of that dictation session. The file is used only if realtime transcription cannot complete and is deleted after every terminal path. A custom endpoint, when configured, applies only to the file-transcription fallback.

The design does not persist audio, include audio in history, log transcript contents, or put transcript/audio data on the clipboard. API keys continue to use Keychain. Logs must avoid request authorization headers, audio payloads, transcript contents, microphone identifiers that could be sensitive, and temporary file paths.

Microphone, Accessibility, clipboard, and text-insertion permissions remain distinct. This feature requires microphone access but does not perform external insertion when dictation ends.

## Localization And Accessibility

Update every supported localization table for new or revised Dictation labels, hold hints, phase descriptions, fallback wording, no-speech messages, and errors. Remove references to retired voice recording modes and automatic post-transcription behavior.

Verify English and Chinese at the app's actual popover and Settings widths. Long shortcut and microphone names truncate or wrap according to existing Settings patterns without overlapping controls.

Accessibility requirements include:

- A descriptive label and help text for the microphone/shortcut affordance.
- Announcements for listening, finalizing, recovering, completed, cancelled, and failed phase changes only.
- A non-color-only provisional-transcript indication.
- Restoration of source-editor focus and selection after completion, cancellation, or failure.
- No interception of marked-text input-method composition.

## Testing

### Coordinator And Race Tests

- Valid state transitions for connect, listen, release, finalize, recover, complete, cancel, and error.
- Realtime failure while held enters recording-for-fallback; release recovers and context loss cancels.
- First terminal result wins across realtime final, socket error, timeout, fallback completion, and cancellation races.
- Late events from stale session identifiers are ignored.
- Sample production stops before append-queue drain, commit occurs exactly once after drain, and no audio append occurs after commit.
- Fallback runs at most once and only after the recovery audio is finalized.
- Every terminal path closes tasks/transports, unlocks the editor, and deletes temporary audio.

### Editor Transaction Tests

- Insert at an empty caret and replace a non-empty selection.
- Repeated cumulative provisional replacement without duplicate text.
- Serial delta accumulation plus wrong-item, duplicate-ID, comparable out-of-order, and stale-session filtering.
- UTF-16 range correctness for Chinese, emoji, surrogate pairs, and combining marks.
- Final transcript, fallback transcript, cancellation, failure, and no-speech behavior.
- Exact text/selection restoration and one-step undo.
- SwiftUI model synchronization without whole-editor replacement or caret reset.

### Shortcut And Popover Tests

- Hold threshold, release, short-press no-op, disabled shortcut, and modifier variants.
- A modifier already held while entering the editor must be released before a fresh hold can begin.
- Shortcut ignored in the Prompt Mode picker, result editor, inactive panel, busy states, and marked-text composition.
- Microphone permission requested only for the first valid hold.
- `Escape` priority and single cancellation ownership.
- Popover close, focus loss, route change, and rapid reopen cleanup.
- App-local shortcut behavior without Accessibility trust and recognizer reset after a missing key-up/context loss.

### Audio And Provider Tests

- One capture lifecycle feeds PCM frames and finalizes one fallback file.
- 24 kHz mono PCM conversion and ordered append events.
- Realtime session configuration, manual commit, delta/completed parsing, server error mapping, explicit close, and timeout.
- File fallback request compatibility, empty recording rejection, configured endpoint/model, and error mapping.
- Selected microphone resolution and System Default fallback.

### Migration, History, And Content Tests

- Configuration-version migration preserves shortcut, microphone, fallback endpoint, and fallback model.
- Removed legacy fields decode safely but do not re-encode or affect behavior.
- Existing `.voice` history decodes and displays unchanged.
- Dictation alone writes no history; a later transformation writes one unchanged `.write` record.
- New localization keys exist in every supported language table.
- README, Chinese README, privacy policy, and manual checklist describe the shipped workflow accurately.

## Verification

Before completion:

- Run focused tests while implementing each behavior.
- Run the complete `swift test` suite.
- Run the project's strict warnings-as-errors or release-sensitive checks where applicable.
- Increment `INKLET_VERSION` in `VERSION` before building the local app bundle.
- Build, install, and launch the stable `/Applications/Inklet Local.app` using `scripts/run-local-app.sh`.
- Run `git diff --check` and inspect `git status`.

Manual QA covers:

- Mode-picker shortcut isolation and source-editor-only dictation.
- Short press, long hold, release, cancellation, and rapid repeat sessions.
- Live partial replacement, caret/selection insertion, manual-edit lock, and single undo.
- Chinese, English, mixed-language, emoji, and input-method composition.
- Realtime success, forced network failure with fallback success, dual failure restoration, and no speech.
- Microphone permission denied, unavailable or unplugged selected microphone, and System Default fallback.
- Popover close/focus loss during every active phase.
- Settings layout, all icon states, VoiceOver labels/announcements, and long localized strings.
- Temporary-file deletion and absence of transcript/audio content in logs and history.

## Documentation

Update `README.md`, `README.zh-CN.md`, the privacy policy, and `docs/manual-test-checklist.md` in the same implementation. Remove stale instructions for the standalone Voice Write Assistant, tap/double-tap recording, automatic cleanup, mode choice, and direct voice insertion. Document the new explicit sequence: open Writing Assistant, confirm a Prompt Mode, hold the voice shortcut in the source editor, edit the transcript, and press `Return` only when ready to run the Prompt.

## Out Of Scope

- Realtime text-to-speech.
- A standalone or globally active dictation window.
- Starting dictation from the Prompt Mode picker.
- Dictation into the generated-result editor.
- Automatic Prompt execution or external insertion when speech ends.
- Tap-to-toggle or double-tap recording.
- User-selectable realtime transcription models or realtime endpoints.
- Persisting audio or creating history for an unprocessed dictated draft.
- Persisted provenance metadata for voice-assisted drafts.
- Streaming multipart optimization for long fallback recordings.
- Speaker diarization, word-level timestamps, translation, or multi-track audio.

## API References

- [OpenAI Realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)
- [OpenAI `gpt-live-transcribe` model](https://developers.openai.com/api/docs/models/gpt-live-transcribe)
