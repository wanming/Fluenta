# Pre-Push Safety Hardening Design

## Summary

Before the merged Writing Dictation and update-check work is pushed to `main`, Inklet will close the safety gaps found during pre-push review. The change will make recovery transcription OpenAI-only, surface item-level Realtime transcription failures immediately, prevent automatic update alerts from interrupting selection gestures, and quiesce selection work before application termination suspends for dictation cleanup.

The same change will bring microphone consent copy, privacy documentation, and manual QA guidance into alignment with the shipped realtime flow. It will not add a new provider, credential, update channel, or user-facing interaction.

## Goals

- Never send the shared OpenAI API key or recovery audio to a user-configured host.
- Start the existing single recovery attempt as soon as OpenAI reports that the active Realtime transcription item failed.
- Never let an automatic update alert interrupt an in-progress mouse, keyboard, or double-copy selection interaction.
- Prevent new selection work from starting after application shutdown begins and wait for any clipboard-restoration work already in flight.
- Make every microphone disclosure accurately describe realtime streaming and the temporary recovery recording in all supported languages.
- Preserve the approved Writing Dictation interaction: active source editor only, long hold only, release to finalize into an editable draft.

## Non-Goals

- No support for third-party or OpenAI-compatible recovery endpoints.
- No second recovery API key or provider picker.
- No changes to the Realtime model, recovery model field, shortcut threshold, audio buffers, or one-attempt fallback limit.
- No change to manual update checks, release comparison, downloading, installation, or update scheduling frequency.
- No rewrite of the 87 already merged local commits and no removal of intentional tracked design or plan documents.
- No local app bundle build or version increment unless a later manual-QA request requires one.

## Approaches Considered

### 1. Fixed OpenAI Recovery Endpoint — Selected

Inklet always sends the recovery request to `https://api.openai.com/v1/audio/transcriptions` using the existing OpenAI key. The editable recovery-endpoint control is removed. The legacy stored field remains decodable so existing preferences continue loading, but normalization and runtime construction always select the official endpoint.

This is the smallest design that prevents credential and audio disclosure to an arbitrary host. It also makes the consent and privacy language unambiguous.

### 2. Arbitrary HTTPS With A Separate Recovery Key — Rejected

This would preserve proxy and compatible-provider support without sharing the OpenAI key, but it requires another Keychain item, provider identity, validation model, migration path, settings UI, localization, and privacy contract. That scope is not justified for a pre-push hardening pass.

### 3. Arbitrary Endpoint With The Shared Key And A Warning — Rejected

A warning does not prevent accidental credential exfiltration, and allowing plaintext HTTP would still expose both the key and audio in transit. Documentation alone is not an adequate control for this boundary.

## Architecture

### Recovery Endpoint Policy

`VoiceInputConfig.defaultSpeechEndpoint` remains the single canonical recovery URL. Config decoding accepts the historical `speechEndpoint` field, then normalizes its effective value to the canonical endpoint. Config saving writes only the canonical value for backward file-format compatibility.

Settings removes the editable recovery endpoint row and retains the recovery model row. Runtime fallback construction does not trust the stored string: it builds `OpenAISpeechTranscriptionProvider` from the canonical OpenAI URL. The production provider initializer and request builder do not accept an arbitrary endpoint; endpoint injection remains available only through an internal test seam.

The production recovery `URLSession` rejects every HTTP redirect. A `3xx` response is handled as a provider failure and may not forward the Authorization header or audio body to either a same-host or cross-host target. A pure policy test and a redirect integration test will prove that legacy custom, plaintext, malformed, credential-bearing, and redirect URLs cannot affect the destination request.

This creates defense in depth:

1. users cannot enter a custom endpoint in Settings;
2. legacy configuration is normalized;
3. runtime request construction independently selects the canonical endpoint.

### Realtime Item Failure Handling

OpenAI documents `conversation.item.input_audio_transcription.failed` as a distinct server event with a nested error object. `OpenAIRealtimeTranscriptionClient` will recognize this type before the generic transcription-event switch and throw the existing `RealtimeTranscriptionError.server` case.

The parser requires a string `item_id`, integer `content_index`, nested `error` object, string `error.type`, and string `error.message`. Top-level `event_id`, `error.code`, and `error.param` are optional and may be absent or JSON `null`; a present non-null value must have the documented type. Only the optional code and required message are carried into the existing typed error. Item identity is validated but is not logged or displayed.

The client will not log or display the server's raw message. Its existing failure path closes the socket and preserves the typed error only long enough for the coordinator to classify the realtime channel as unavailable.

`WritingDictationCoordinator.receiveEvents` already converts any client error into `loseRealtime`. If the hold has been released and a recovery file exists, losing Realtime resumes the final waiter and starts the existing one-shot recovery immediately. If the hold is still active, capture continues in `recordingForFallback` until release. No new terminal state is required.

### Selection Interaction Gate

`SelectionActionMonitor` will expose whether a physical selection gesture or double-copy window is active:

- left mouse down begins a mouse interaction;
- mouse up completes it only after the candidate or dismissal callback has been handed to `AppCoordinator`;
- Shift modifier activation begins a keyboard interaction;
- Shift release completes it after any queued selection candidate has been handed off;
- the first eligible `Command+C` begins a copy interaction that remains active through the second-copy handoff or the existing 0.8-second expiry;
- the second eligible `Command+C` invokes the trigger while the interaction remains active, and ends it only after `AppCoordinator` has registered the clipboard read;
- stopping the monitor clears the interaction state.

Interaction start is recorded synchronously at the raw event-delivery boundary before any `Task` hop. The final presentation gate also queries the current left-mouse-button and Shift-modifier state through an injectable state provider, so an already-scheduled alert cannot overtake a physical interaction whose main-actor callback is pending and tests need not manipulate real hardware. Interaction end remains active until candidate, dismissal, or copy-trigger handling has synchronously registered its replacement work on the main actor.

`AppCoordinator` includes this live interaction query in automatic-update eligibility. Candidate handling and `selectionReadTask` registration are synchronous relative to interaction completion, so there is no idle gap between release and read ownership.

`SelectionActionMonitor` reports interaction-state transitions to `AppCoordinator`. Every transition to idle—mouse completion, Shift release, first-copy expiry, second-copy handoff, or monitor reset—requests the sole automatic-presentation scheduler after its associated selection work is registered. Therefore an update that was blocked by a gesture is retried without polling and cannot remain pending indefinitely.

No automatic result may call the alert presenter inline. `UpdateCheckCoordinator` stores every available automatic update as pending and invokes a scheduling callback. `AppCoordinator` owns the sole automatic-presentation gate and coalesces requests into a next-main-actor-turn task. `refreshMigrationImportEligibility` continues updating migration eligibility synchronously, then schedules the same gate rather than presenting directly. At execution time the gate re-evaluates selection interaction, selection read/work, visible panels, menus, modal windows, migration, hotkey capture, stopping, and current alert presentation before it calls `presentPendingAutomaticUpdateIfPossible()`.

This ordering also protects double-copy replacement: all dismissal effects finish and the replacement read task is registered before a pending update can activate Inklet.

### Shutdown Quiescence

`AppCoordinator.stop()` will establish shutdown synchronously before its first suspension point:

1. set `isStopping`;
2. stop update scheduling and cancel any deferred presentation task;
3. synchronously remove configuration, permission, onboarding, hotkey-recording, language, workspace, and settings-shortcut observers;
4. unregister global hotkeys and stop the selection monitor;
5. snapshot the pending selection read, translation, speech, and feedback task references;
6. cancel those selection tasks and stop active playback;
7. await dictation cancellation and every captured selection task;
8. finish remaining teardown.

Every queued selection callback and every monitor-start or reconfiguration path will also guard `!isStopping`, because removing an observer or event monitor cannot retract a main-actor callback that was already enqueued. Awaiting the captured read task ensures a user clipboard handoff reaches its safe terminal outcome before termination replies to AppKit: it restores the captured clipboard when still owned, or deliberately relinquishes restoration rather than overwriting newer clipboard data.

## State And Error Behavior

- A Realtime item failure while the user is holding changes the session to fallback recording without ending capture.
- A Realtime item failure after release immediately begins the single file-transcription recovery attempt; the 15-second final-transcript timeout is cancelled.
- A malformed failure event is treated as an invalid Realtime message and follows the same safe fallback path.
- A custom endpoint left by an older build is ignored and normalized to the official OpenAI endpoint without sending a request to the old host.
- An HTTP redirect from the official recovery endpoint is rejected before credentials or audio can be forwarded.
- Automatic update results remain pending during selection gestures and are presented once after the complete interaction becomes idle.
- Manual update checks remain explicitly user initiated and keep their existing presentation semantics.
- Once shutdown begins, queued selection callbacks are no-ops and no new clipboard handoff can start.

## Privacy, Localization, And Documentation

The base `NSMicrophoneUsageDescription` and all ten localized `InfoPlist.strings` entries will say that a valid Dictation hold streams microphone audio to OpenAI and keeps a temporary recovery recording for the same session. Copy will remain concise enough for the macOS permission prompt and will not imply background recording.

The recovery recording remains local unless the realtime path fails and the single fallback request actually starts. It is uploaded at most once to the fixed OpenAI endpoint and deleted after every terminal path, including realtime success, fallback success or failure, no speech, cancellation, focus loss, popover closure, supersession, migration maintenance, timeout, and app termination.

`README.md`, `README.zh-CN.md`, `SECURITY.md`, and `docs/privacy-policy.md` will describe the fixed OpenAI recovery destination and shared OpenAI credential accurately. The privacy-policy date becomes September 5, 2026, and the distribution contract will require that date exactly once.

`docs/manual-test-checklist.md` will replace retired voice-recording terminology and add the missing physical checks from the parallel-start plan: compare responsiveness with the prior local build, speak immediately after holding, and verify the beginning of the utterance is preserved.

## Test Strategy

Implementation follows red-green-refactor, one behavior at a time.

### Recovery Security

- A failing test first proves a legacy custom or HTTP endpoint can influence the runtime request today.
- Config tests require canonical normalization after decoding and saving.
- Settings source tests require removal of the editable endpoint binding.
- Runtime/provider tests prove the fallback request host, scheme, port, path, query, and user information are the canonical OpenAI values and that no credential-bearing or custom URL can be selected.
- A redirect test returns `3xx` toward a second host and proves no request, Authorization header, or audio body reaches that host.

### Realtime Failure

- Client tests enqueue the documented failed-event shape and initially fail because `nextEvent()` keeps receiving instead of throwing.
- Malformed nested error and structural fields produce `invalidMessage`.
- Coordinator tests use controllable fakes to prove a failure after release starts recovery without advancing the final-timeout waiter, and a failure while held preserves fallback capture until release.

### Update And Selection Races

- Presentation-state tests require active mouse and keyboard selection interactions to block automatic alerts.
- Monitor tests cover synchronous mouse-down/up, Shift-down/release, first-copy expiry, and second-copy handoff ordering.
- App-coordinator tests prove every automatic result enters the deferred gate, double-copy registers its replacement read before the copy interaction ends, and a pending result is retried after the interaction becomes idle.
- A pre-scheduled presentation test begins a physical interaction before the next-turn gate runs and proves the live state recheck blocks the alert.
- Idle-transition tests prove mouse completion, Shift release, copy expiry, and second-copy completion each reschedule the pending presentation exactly once.

### Shutdown

- Tests prove global selection monitoring stops before the first `await` in `stop()`.
- Queued candidate, copy, and dismissal callbacks are ignored once `isStopping` is true.
- Observer removal and `isStopping` guards prevent queued configuration notifications from restarting global monitors during shutdown.
- A blocked clipboard handoff and the remaining captured selection tasks are cancelled and joined before application termination replies.
- Clipboard tests distinguish safe restoration from deliberate relinquishment when another process has already changed the pasteboard.

### Final Verification

- Run focused tests after every red-green cycle.
- Run full `swift test` in Debug and Release.
- Run Debug and Release builds with `-warnings-as-errors`.
- Run `scripts/test-run-local-app.sh` and `scripts/test-direct-distribution.sh`.
- Run localization and documentation contract tests, `git diff --check`, secret/path scans, and an independent code review.
- Verify the temporary recovery file stays local unless fallback begins and is deleted on every existing terminal path.
- Fetch `origin` before integration, merge the reviewed branch into local `main`, and run the full suite on that exact merge result.
- Fetch `origin` again immediately before push. If `origin/main` changed, integrate it without rewriting published history and rerun the complete verification loop. Push `main` only when the re-fetched remote remains an ancestor of the tested local commit; never force-push.

## Acceptance Criteria

- Recovery audio and the OpenAI key can be sent only to the canonical OpenAI HTTPS transcription endpoint.
- The recovery request cannot follow an HTTP redirect, and the temporary recording remains local unless the single fallback attempt starts.
- A documented Realtime item failure cannot leave the UI waiting for the final-transcript timeout.
- Automatic update presentation cannot interrupt mouse, Shift-key, or double-copy selection interactions or their atomic handoff to a selection read.
- Shutdown begins by quiescing global input sources and waits for every captured selection task, including the clipboard transaction's safe terminal outcome.
- All supported microphone consent strings and public documentation match actual behavior.
- All automated verification passes and the final remote update is a non-force fast-forward of `main`.
