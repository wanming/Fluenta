# Realtime Transcription Intent Fix Design

## Problem

Writing dictation reaches the realtime connection phase, but every attempt moves from the connecting state to the fallback-recording state. Unified logs from the installed `1.1.3 (9)` local app show four WebSocket requests completing TLS and receiving HTTP `101 Switching Protocols`; each connection then closes within one second. The subsequent file-transcription fallback requests return HTTP `200`, which rules out the microphone, DNS, TLS, basic connectivity, and a missing or wholly invalid API key as the cause.

`OpenAIRealtimeTranscriptionClient` currently opens:

```text
wss://api.openai.com/v1/realtime?model=gpt-live-transcribe
```

The `model` query selects a normal Realtime model session. A dedicated transcription WebSocket instead uses `intent=transcription`, and selects `gpt-live-transcribe` in the subsequent transcription `session.update`. Inklet already sends the correct nested transcription session update, so the URL query is the isolated protocol mismatch.

The existing client test repeats the production URL as both its input and expected value. Its fake transport accepts every connection and returns a preloaded `session.updated` event, so it cannot detect a wrong server-side session intent.

## Selected Repair

Change only the default WebSocket endpoint to:

```text
wss://api.openai.com/v1/realtime?intent=transcription
```

Keep the existing `session.update` payload, `gpt-live-transcribe` model selection, 24 kHz mono PCM16 audio, append and commit events, transcript event parsing, timeout behavior, and fallback flow unchanged.

This repair does not change visible copy, shortcut behavior, microphone capture, API-key storage, draft editing, or fallback transcription. README behavior remains accurate and requires no update.

## Rejected Alternatives

1. Add WebSocket delegate infrastructure and richer close diagnostics in the same change. Better observability is useful, but it expands a one-line protocol repair into transport lifecycle work and does not help prove the identified endpoint defect.
2. Open a normal `gpt-realtime` session and enable input transcription within it. That adds a conversational Realtime model Inklet does not need and changes cost and session behavior.
3. Restore the legacy flat `transcription_session.update` protocol. The existing nested `session.update` already matches the current API and should not be replaced.

## Test Contract

Replace the self-confirming endpoint expectation with a regression test that constructs the client from `OpenAIRealtimeTranscriptionClient.defaultEndpoint` and asserts that both the public default and the transport request equal the dedicated transcription URL.

Run that test before the production change and observe it fail because the current URL contains `model=gpt-live-transcribe`. After changing the endpoint, rerun it and observe it pass. Keep the existing exact `session.update` assertion unchanged so the model remains selected in the session payload rather than disappearing from the protocol.

No real API key or network connection is required by the automated regression.

## Verification

- Capture the focused endpoint regression failing against the current implementation and passing after the repair.
- Run all `OpenAIRealtimeTranscriptionClientTests`.
- Run the complete debug and release test suites.
- Run strict debug and release builds with warnings treated as errors.
- Run the existing local-runner and direct-distribution script tests.
- Increment the patch version and build number to `1.1.4 (10)` before rebuilding the app bundle.
- Build, sign, install, and launch `/Applications/Inklet Local.app` only through `scripts/run-local-app.sh`.
- Verify installed metadata, signature validity, the running process, `git diff --check`, and final worktree status.
- Leave the final physical Right Option hold and live draft update check to the user.

## Follow-up Boundary

Production WebSocket open/close diagnostics and explicit handling of `conversation.item.input_audio_transcription.failed` remain worthwhile follow-up work. They are intentionally excluded from this repair so its result can be attributed to the corrected transcription intent.
