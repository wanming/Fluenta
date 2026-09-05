# Writing Dictation Parallel Startup Design

## Problem

Writing dictation currently waits for the complete audio-capture startup before it begins the OpenAI Realtime connection. The critical path is therefore the sum of AVFoundation startup and Realtime session setup, even though neither operation depends on the other after a valid hold has been accepted. The action bar remains in `connecting` until capture is running, the server has acknowledged `session.update`, and buffered early audio has flushed.

The Right Option hold threshold is already 80 milliseconds. Reducing it would recover only a small fixed delay while increasing accidental activation risk, so the shortcut recognizer is not the target of this change.

## Desired Behavior

- Preserve the existing 80-millisecond hold-only interaction.
- Do not request microphone permission or connect to OpenAI on a short press, while browsing Prompt Modes, or merely because the popover is open.
- Once a valid hold begins, overlap audio-capture startup with Realtime session setup whenever microphone permission is already granted.
- Publish `listening` only after capture is running, Realtime is ready, and all early audio accepted before readiness has flushed in order.
- Preserve speech produced while the connection is becoming ready through the existing bounded PCM buffers and recovery recording.
- Preserve exact release, cancellation, fallback, editor restoration, temporary-file cleanup, and rapid-restart behavior.
- Keep the current action-bar layout and user-facing copy.

## Approaches Considered

### 1. Parallel Capture And Realtime With A Readiness Barrier — Selected

After the coordinator creates the validated session, it starts the Realtime connection operation before awaiting full capture startup. Capture and connection progress independently. A shared readiness gate enters `listening` only when both sides are ready and the early-audio queue has drained.

This reduces the structural ready time from approximately `capture startup + Realtime setup` to `max(capture startup, Realtime setup)`. It reuses the coordinator's existing session identity, operation registry, early-audio buffer, and first-terminal-wins cleanup model.

### 2. Lower The Hold Threshold

Reducing the threshold below 80 milliseconds would change the distinction between a short press and a deliberate hold. It cannot remove AVFoundation or network latency and risks starting dictation during normal modifier use. This approach is rejected.

### 3. Preconnect When The Popover Opens

Opening a Realtime session before a confirmed hold could hide more network latency, but it would contact OpenAI without a dictation gesture, consume resources during idle editing, and complicate session expiry. Starting the microphone on initial key-down would likewise weaken the confirmed-hold privacy boundary. Both are rejected.

## Selected Architecture

`WritingDictationCoordinator` remains the sole session owner. On `beginHold` it performs the existing API-key and editor-transaction preflight, publishes `connecting`, registers the capture-start operation, and starts the Realtime connection operation without waiting for AVFoundation to finish.

The session tracks the two independent milestones:

- `captureStarted`: AVFoundation is running and the PCM stream is available.
- `connectionReady`: `session.updated` was received and the client can accept PCM.

Neither milestone alone may publish `listening`. The coordinator runs one idempotent readiness method after either milestone changes. That method attaches the frame consumer once capture exists, flushes every accumulated early-audio batch in order once the connection is ready, then rechecks session identity and terminal state before publishing `listening` and starting the receive loop exactly once.

The existing early-audio capacity remains unchanged at 240,000 bytes, approximately five seconds of mono 24 kHz PCM16. The AV sample stream's bounded queue continues to cover frames produced before the coordinator begins consuming the returned stream. No new unbounded buffer is introduced.

## Permission And Privacy Boundary

The first microphone authorization prompt remains part of a valid hold. Inklet must not open a Realtime connection while the user is still deciding the system permission prompt. For an already-authorized microphone, capture and Realtime setup may begin together immediately after the hold is confirmed.

To keep this boundary explicit, the audio-capture contract exposes an authorization preflight distinct from starting the AVFoundation graph. The coordinator awaits that preflight first. A denial fails locally without connecting. After authorization succeeds, it starts the capture graph and Realtime connection concurrently.

The preflight remains cancellation-aware: if the user releases, dismisses the popover, or invalidates the editor while authorization is pending, neither capture nor connection may start afterward.

## State And Failure Semantics

- **Capture wins first:** PCM is consumed into the bounded early-audio buffer while Realtime connects. The phase remains `connecting`.
- **Connection wins first:** the client remains ready, but `listening` and the receive loop wait for capture. No audio state is implied before the microphone is running.
- **Both become ready:** buffered PCM flushes in order before live frames, then the phase becomes `listening` and the receive loop starts once.
- **Realtime fails while capture is starting:** the failure is latched and the client closes. `recordingForFallback` is not published until capture has actually started; after that, the local recording continues until release.
- **Capture fails while Realtime is connecting or ready:** the session terminates with the existing capture-specific error, closes the client, restores the editor transaction, and deletes any owned temporary file.
- **Release during either startup:** finalization waits only for the already-owned operations needed to produce a valid realtime commit or finalized fallback file. It must not start a late capture or connection after cancellation wins.
- **Cancellation or context loss:** all in-flight startup work is cancelled or joined through the existing operation registry. The editor is restored once, the client closes once, and capture cleanup remains generation-safe.

The existing five-second Realtime timeout begins when the connection operation starts. Parallel startup therefore also bounds the total pre-listening wait more closely than the previous sequence, where audio startup elapsed before the timeout began.

## Test Contract

Use focused coordinator tests with controllable capture and client fakes:

1. Block capture startup and assert that Realtime connection has already started. Complete the connection first and assert the phase remains `connecting`; resume capture and then expect `listening` and one receive loop.
2. Block capture startup, fail the connection first, and assert `recordingForFallback` is not published before capture starts. Resume capture and expect fallback recording state while the hold remains active.
3. Block capture startup, complete the connection, then fail capture. Assert the client closes, the editor restores, the capture error wins, and `listening` is never published.
4. Keep existing early-audio ordering, overflow, release-during-connection, pending-capture cancellation, cleanup, and rapid-restart tests green.
5. Add audio-capture authorization tests proving denial prevents backend construction and proving cancellation while permission is pending prevents both startup milestones.

The first test must be run before production changes and fail specifically because the current coordinator has not started `connect` while capture is blocked. After implementation, the focused coordinator and audio-recorder suites must pass. A mutation check that restores serial connection startup must make the regression fail.

## Verification

- Capture the focused parallel-start regression failing before implementation and passing afterward.
- Run `swift test --filter WritingDictationCoordinatorTests` and `swift test --filter AudioRecorderTests`.
- Run the complete `swift test` suite and strict warnings-as-errors builds used by the project.
- Run `git diff --check` and inspect the final worktree status.
- Request independent review of lifecycle, cancellation, fallback, privacy, and buffer ordering.
- Increment the patch version and build number before building another app bundle.
- Build, sign, install, and launch `/Applications/Inklet Local.app` through `scripts/run-local-app.sh`.
- Leave physical latency comparison to the user: open Writing Assistant, enter the editor, hold Right Option, confirm the status reacts promptly, speak immediately, release, and verify the complete editable transcript remains intact.

No localization or README change is required because the shortcut contract, user-facing copy, provider configuration, permissions, and documented workflow remain unchanged.
