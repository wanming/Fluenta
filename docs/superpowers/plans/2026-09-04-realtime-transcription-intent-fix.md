# Realtime Transcription Intent Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Writing dictation open a dedicated OpenAI Realtime transcription session instead of immediately falling back after the WebSocket upgrade.

**Architecture:** Preserve the existing WebSocket transport, nested transcription `session.update`, `gpt-live-transcribe` model, PCM streaming, transcript parsing, and fallback state machine. Pin the dedicated `intent=transcription` endpoint with a focused regression, then change only the default endpoint query.

**Tech Stack:** Swift 6, Foundation `URLSessionWebSocketTask`, XCTest, Swift Package Manager, macOS app-bundle scripts.

---

### Task 1: Reproduce and repair the transcription endpoint

**Files:**
- Modify: `Tests/InkletCoreTests/OpenAIRealtimeTranscriptionClientTests.swift:6-24`
- Modify: `Sources/InkletCore/OpenAIRealtimeTranscriptionClient.swift:63`

- [ ] **Step 1: Write the failing dedicated-intent regression**

Replace the first client test with this test so it uses the production default rather than repeating a hand-written endpoint as both input and expectation:

```swift
func testConnectUsesDedicatedTranscriptionIntentAndTrimmedAuthorizationHeader() async throws {
    let transport = FakeRealtimeTransport()
    let client = OpenAIRealtimeTranscriptionClient(
        apiKeyProvider: { "  test-key  " },
        endpoint: OpenAIRealtimeTranscriptionClient.defaultEndpoint,
        transport: transport
    )
    await transport.enqueue(#"{"type":"session.updated"}"#)

    try await client.connect(timeoutSeconds: 1)
    let snapshot = await transport.snapshot()

    XCTAssertEqual(
        OpenAIRealtimeTranscriptionClient.defaultEndpoint.absoluteString,
        "wss://api.openai.com/v1/realtime?intent=transcription"
    )
    XCTAssertEqual(
        snapshot.requestURL,
        "wss://api.openai.com/v1/realtime?intent=transcription"
    )
    XCTAssertEqual(snapshot.authorization, "Bearer test-key")
}
```

- [ ] **Step 2: Run the regression and verify RED**

Run:

```bash
swift test --filter OpenAIRealtimeTranscriptionClientTests/testConnectUsesDedicatedTranscriptionIntentAndTrimmedAuthorizationHeader
```

Expected: FAIL because both endpoint assertions receive `wss://api.openai.com/v1/realtime?model=gpt-live-transcribe`. Connection setup itself still succeeds against the fake transport; a compile error or timeout is not the expected RED result.

- [ ] **Step 3: Apply the minimal production repair**

Change only the default endpoint declaration in `OpenAIRealtimeTranscriptionClient`:

```swift
public static let defaultEndpoint = URL(
    string: "wss://api.openai.com/v1/realtime?intent=transcription"
)!
```

Do not change `model`, `sessionUpdateMessage`, headers, audio settings, error mapping, or the coordinator fallback flow.

- [ ] **Step 4: Run the regression and focused client suite GREEN**

Run:

```bash
swift test --filter OpenAIRealtimeTranscriptionClientTests/testConnectUsesDedicatedTranscriptionIntentAndTrimmedAuthorizationHeader
swift test --filter OpenAIRealtimeTranscriptionClientTests
```

Expected: the endpoint regression passes and every realtime client test passes, including the unchanged exact `session.update` payload assertion with `gpt-live-transcribe`.

- [ ] **Step 5: Review and commit the focused repair**

Run:

```bash
git diff --check
git diff -- Sources/InkletCore/OpenAIRealtimeTranscriptionClient.swift Tests/InkletCoreTests/OpenAIRealtimeTranscriptionClientTests.swift
git add Sources/InkletCore/OpenAIRealtimeTranscriptionClient.swift Tests/InkletCoreTests/OpenAIRealtimeTranscriptionClientTests.swift
git diff --cached --check
git commit -m "Fix realtime transcription session intent"
```

Expected: the commit contains only the endpoint regression and the default endpoint query change.

### Task 2: Run complete code and distribution verification

**Files:**
- Verify: `Sources/InkletCore/OpenAIRealtimeTranscriptionClient.swift`
- Verify: `Tests/InkletCoreTests/OpenAIRealtimeTranscriptionClientTests.swift`
- Verify: `scripts/test-run-local-app.sh`
- Verify: `scripts/test-direct-distribution.sh`

- [ ] **Step 1: Run both complete test configurations**

Run:

```bash
swift test
swift test -c release
```

Expected: all XCTest and Swift Testing tests pass in debug and release configurations.

- [ ] **Step 2: Run strict builds**

Run:

```bash
swift build -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
```

Expected: both builds exit successfully with no warnings.

- [ ] **Step 3: Run local-runner and distribution script checks**

Run:

```bash
bash scripts/test-run-local-app.sh
bash scripts/test-direct-distribution.sh
```

Expected: both script suites report success.

### Task 3: Version, install, and launch the repaired app

**Files:**
- Modify: `VERSION`

- [ ] **Step 1: Increment the local app version before bundle creation**

Change `VERSION` to:

```dotenv
INKLET_VERSION=1.1.4
INKLET_BUILD_NUMBER=10
```

- [ ] **Step 2: Review and commit the version change**

Run:

```bash
git diff --check
git diff -- VERSION
git add VERSION
git diff --cached --check
git commit -m "Bump Inklet version to 1.1.4"
```

Expected: the commit changes only `1.1.3 (9)` to `1.1.4 (10)`.

- [ ] **Step 3: Build, sign, install, and launch the stable local bundle**

Run:

```bash
scripts/run-local-app.sh
```

Expected: the script stops the existing `Inklet Local` process, builds the release executable, signs and verifies the bundle without printing the signing identity, installs `/Applications/Inklet Local.app`, and launches it successfully.

- [ ] **Step 4: Verify the installed artifact and repository state**

Run:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '/Applications/Inklet Local.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '/Applications/Inklet Local.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '/Applications/Inklet Local.app/Contents/Info.plist'
codesign --verify --deep --strict '/Applications/Inklet Local.app'
pgrep -fl '^/Applications/Inklet Local.app/Contents/MacOS/Inklet Local$'
git diff --check
git status --short --branch
```

Expected: bundle ID `com.tomwan.inklet.local`, version `1.1.4`, build `10`, a valid signature, one running installed process, and a clean `codex/voice-writing-integration` worktree.

- [ ] **Step 5: Hand off physical realtime-dictation QA**

Ask the user to open Writing Assistant in Prompt mode, focus the editable source draft, hold physical Right Option until the listening state appears, speak, and release. Expected behavior: the UI progresses from connecting to listening instead of connection-lost fallback, transcript deltas update the draft, and release leaves the final transcript editable.
