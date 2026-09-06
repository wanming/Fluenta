# Writing Dictation Parallel Startup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce confirmed-hold dictation startup latency by overlapping AVFoundation capture startup with OpenAI Realtime session setup without weakening permission, cancellation, fallback, or editor-restoration guarantees.

**Architecture:** Split microphone authorization from capture-graph startup while retaining the existing direct-start fallback inside `AudioRecorder`. After authorization succeeds, `WritingDictationCoordinator` starts the Realtime connection and capture graph concurrently, then uses the existing session flags plus one idempotent readiness gate to publish `listening` and begin receiving only after both sides are ready.

**Tech Stack:** Swift 6, Swift Concurrency and `@MainActor`, AVFoundation, OpenAI Realtime WebSocket client, XCTest, Swift Package Manager, macOS app-bundle scripts.

---

### Task 1: Add a cancellable microphone-authorization preflight

**Files:**
- Modify: `Sources/InkletApp/AudioRecorder.swift:5-10,150-205,288-302`
- Modify: `Tests/InkletCoreTests/AudioRecorderTests.swift:284-357`
- Modify: `Tests/InkletCoreTests/WritingDictationCoordinatorTests.swift:1201-1323`

- [ ] **Step 1: Write the failing preflight reuse test**

Add this test after `testAudioRecorderConformsToDictationAudioCaptureContract`:

```swift
func testAuthorizedPreflightIsConsumedByTheNextStreamingStart() async throws {
    let backend = FakeAudioRecorderCaptureBackend(bufferLimit: 2)
    var permissionResolutionCount = 0
    let recorder = AudioRecorder(
        microphonePermissionResolver: {
            permissionResolutionCount += 1
            return true
        },
        captureBackendResolver: { _ in backend }
    )

    try await recorder.authorizeMicrophone()
    _ = try await recorder.startStreaming(microphoneDeviceID: "test-device")

    XCTAssertEqual(permissionResolutionCount, 1)
    XCTAssertEqual(backend.events, [.startRecording])
    await recorder.cancel()
}
```

- [ ] **Step 2: Run the preflight test and verify RED**

Run:

```bash
swift test --filter AudioRecorderTests/testAuthorizedPreflightIsConsumedByTheNextStreamingStart
```

Expected: compilation fails because `AudioRecorder` has no `authorizeMicrophone` member. This is the expected RED result; no production file may be changed before observing it.

- [ ] **Step 3: Add the minimal preflight contract and prepared-grant state**

Add the protocol requirement:

```swift
@MainActor
protocol DictationAudioCapturing: AnyObject {
    func authorizeMicrophone() async throws
    func startStreaming(microphoneDeviceID: String?) async throws -> AsyncThrowingStream<Data, Error>
    func stop() async throws -> URL
    func cancel() async
}
```

In `AudioRecorder`, add `preparedPermissionGeneration`, extract the current permission logic, and consume one valid preflight from the next start while preserving direct `startStreaming` callers. Replace the current `startStreaming` prefix from `let generation = beginStart()` through the first `try validateStart(generation)` after `cancelActiveCapture()` with the block below; retain the existing implementation beginning at `let recordingURL = recordingURLProvider()` exactly as it is:

```swift
private var activeCapture: ActiveCapture?
private var startGeneration: UInt64 = 0
private var preparedPermissionGeneration: UInt64?

func authorizeMicrophone() async throws {
    let generation = beginStart()
    try await resolveMicrophonePermission(generation: generation)
    preparedPermissionGeneration = generation
}

func startStreaming(
    microphoneDeviceID: String?
) async throws -> AsyncThrowingStream<Data, Error> {
    let generation: UInt64
    if let preparedPermissionGeneration {
        self.preparedPermissionGeneration = nil
        generation = preparedPermissionGeneration
        try validateStart(generation)
    } else {
        generation = beginStart()
        try await resolveMicrophonePermission(generation: generation)
    }

    await cancelActiveCapture()
    try validateStart(generation)
}

private func resolveMicrophonePermission(generation: UInt64) async throws {
    try validateStart(generation)
    let hasMicrophoneAccess = await microphonePermissionResolver()
    try validateStart(generation)
    guard hasMicrophoneAccess else {
        throw AudioRecorderError.microphonePermissionDenied
    }
}

private func beginStart() -> UInt64 {
    startGeneration &+= 1
    preparedPermissionGeneration = nil
    return startGeneration
}

private func invalidatePendingStarts() {
    startGeneration &+= 1
    preparedPermissionGeneration = nil
}
```

Add a no-op authorization method to `FakeDictationCapture` so it continues conforming:

```swift
func authorizeMicrophone() async throws {}
```

- [ ] **Step 4: Verify the preflight test is GREEN**

Run:

```bash
swift test --filter AudioRecorderTests/testAuthorizedPreflightIsConsumedByTheNextStreamingStart
```

Expected: PASS with one permission resolution and one backend start.

- [ ] **Step 5: Write the failing stale-grant cancellation test**

Add:

```swift
func testCancelInvalidatesPreparedPermissionBeforeANewerStart() async throws {
    let backend = FakeAudioRecorderCaptureBackend(bufferLimit: 2)
    var permissionResolutionCount = 0
    let recorder = AudioRecorder(
        microphonePermissionResolver: {
            permissionResolutionCount += 1
            return true
        },
        captureBackendResolver: { _ in backend }
    )

    try await recorder.authorizeMicrophone()
    await recorder.cancel()
    _ = try await recorder.startStreaming(microphoneDeviceID: nil)

    XCTAssertEqual(permissionResolutionCount, 2)
    await recorder.cancel()
}
```

Temporarily omit `preparedPermissionGeneration = nil` from `invalidatePendingStarts` and run the test. Expected: the newer start consumes the stale generation and throws `CancellationError` before its permission resolver runs. Restore the invalidation line and rerun for GREEN. This mutation proves cancellation, rather than ordinary start behavior, owns the assertion.

- [ ] **Step 6: Run the complete audio-recorder suite**

Run:

```bash
swift test --filter AudioRecorderTests
```

Expected: all `AudioRecorderTests` pass, including the existing permission-pending, overlapping-start, fallback-file, PCM-order, overflow, and cleanup cases.

- [ ] **Step 7: Review and commit the permission preflight**

Run:

```bash
git diff --check
git diff -- Sources/InkletApp/AudioRecorder.swift Tests/InkletCoreTests/AudioRecorderTests.swift Tests/InkletCoreTests/WritingDictationCoordinatorTests.swift
git add Sources/InkletApp/AudioRecorder.swift Tests/InkletCoreTests/AudioRecorderTests.swift Tests/InkletCoreTests/WritingDictationCoordinatorTests.swift
git diff --cached --check
git commit -m "Prepare microphone permission before dictation startup"
```

Expected: the commit adds only the authorization preflight, its generation-safe prepared grant, focused tests, and the required fake conformance.

### Task 2: Start capture and Realtime setup concurrently

**Files:**
- Modify: `Sources/InkletApp/WritingDictationCoordinator.swift:84-114,207-375,621-645`
- Modify: `Tests/InkletCoreTests/WritingDictationCoordinatorTests.swift:8-171,1201-1323,1430-1634`

- [ ] **Step 1: Add fake-client startup observability**

Extend `FakeRealtimeClient` without changing production behavior:

```swift
private(set) var connectCount = 0
var didStartReceiving: Bool { receiveStarted }

func connect(timeoutSeconds: TimeInterval) async throws {
    connectCount += 1
    do {
        if let pendingConnectionResult {
            self.pendingConnectionResult = nil
            return try pendingConnectionResult.get()
        }
        try await withCheckedThrowingContinuation { connectContinuation = $0 }
    } catch {
        connectErrorWasThrown = true
        let waiters = connectErrorWaiters
        connectErrorWaiters.removeAll()
        waiters.forEach { $0.resume() }
        throw error
    }
}
```

- [ ] **Step 2: Write the failing parallel-start readiness test**

Add near the coordinator happy-path tests:

```swift
func testConnectionStartsWhileCaptureStartIsPendingAndListeningWaitsForBoth() async {
    let harness = DictationHarness()
    harness.capture.blockStart()
    let begin = Task { await harness.subject.beginHold() }
    await harness.capture.waitUntilStartWasCalled()
    await Task.yield()

    XCTAssertEqual(harness.client.connectCount, 1)

    harness.client.completeConnection()
    await Task.yield()
    XCTAssertEqual(harness.subject.phase, .connecting)
    XCTAssertFalse(harness.client.didStartReceiving)

    harness.capture.resumeStart()
    await begin.value
    await harness.client.waitUntilReceiveStarts()

    XCTAssertEqual(harness.subject.phase, .listening)
    await harness.subject.cancelAndWait()
}
```

- [ ] **Step 3: Run the readiness test and verify RED**

Run:

```bash
swift test --filter WritingDictationCoordinatorTests/testConnectionStartsWhileCaptureStartIsPendingAndListeningWaitsForBoth
```

Expected: FAIL at `connectCount`, reporting `0` instead of `1`, because the current coordinator waits for capture startup before spawning `connect`.

- [ ] **Step 4: Move connection startup after authorization and add a double-readiness gate**

In `beginHold`, keep `captureStartInFlight` registered, await permission, validate the session, then spawn connection before awaiting the capture graph:

```swift
do {
    try await audioCapture.authorizeMicrophone()
    guard session?.id == sessionID, session?.terminalWon == false else { return }

    let connectOperationID = spawnOperation(sessionID: sessionID, kind: .connect) {
        coordinator, _ in
        await coordinator.connect(sessionID: sessionID)
    }
    session?.connectOperationID = connectOperationID

    let stream = try await audioCapture.startStreaming(
        microphoneDeviceID: config.microphoneDeviceID
    )
    session?.captureStartInFlight = false
    guard session?.id == sessionID else {
        await audioCapture.cancel()
        return
    }

    session?.captureStarted = true
    guard session?.terminalWon == false else {
        await cancelCaptureIfNeeded(sessionID: sessionID)
        return
    }

    let frameOperationID = spawnOperation(sessionID: sessionID, kind: .frames) {
        coordinator, _ in
        await coordinator.consumeFrames(stream, sessionID: sessionID)
    }
    session?.frameOperationID = frameOperationID

    if session?.realtimeAvailable == true {
        beginListeningIfReady(sessionID: sessionID)
    } else if session?.releaseRequested == false {
        publish(.recordingForFallback)
    }
} catch let error as CancellationError {
    session?.captureStartInFlight = false
    guard session?.id == sessionID, session?.terminalWon == false else { return }
    winTerminal(
        sessionID: sessionID,
        outcome: Task.isCancelled ? .cancelled : .failure(errorKey(error))
    )
} catch {
    session?.captureStartInFlight = false
    guard session?.id == sessionID, session?.terminalWon == false else { return }
    winTerminal(sessionID: sessionID, outcome: .failure(errorKey(error)))
}
```

At the end of `handleConnected`, set `connectionReady` after the existing ordered flush and call one gate instead of publishing directly:

```swift
session?.connectionReady = true
beginListeningIfReady(sessionID: sessionID)
```

Add the idempotent gate:

```swift
private func beginListeningIfReady(sessionID: UUID) {
    guard let current = session,
          current.id == sessionID,
          current.captureStarted,
          current.connectionReady,
          current.realtimeAvailable,
          !current.terminalWon
    else { return }

    if !current.releaseRequested, phase != .listening {
        publish(.listening)
    }
    guard current.receiveOperationID == nil else { return }
    let receiveOperationID = spawnOperation(sessionID: sessionID, kind: .receive) {
        coordinator, _ in
        await coordinator.receiveEvents(sessionID: sessionID)
    }
    session?.receiveOperationID = receiveOperationID
}
```

Do not change the five-second timeout, buffer sizes, hold threshold, or action-bar copy.

- [ ] **Step 5: Verify the parallel-start test is GREEN**

Run:

```bash
swift test --filter WritingDictationCoordinatorTests/testConnectionStartsWhileCaptureStartIsPendingAndListeningWaitsForBoth
```

Expected: PASS; connection starts during blocked capture, connection-first does not publish `listening`, and both-ready starts one receive loop.

- [ ] **Step 6: Write the failing early connection-loss state test**

Add:

```swift
func testConnectionFailureBeforeCaptureStartsWaitsToPublishFallbackRecording() async {
    let harness = DictationHarness()
    harness.capture.blockStart()
    let begin = Task { await harness.subject.beginHold() }
    await harness.capture.waitUntilStartWasCalled()
    await Task.yield()

    harness.client.failConnection(with: RealtimeTranscriptionError.connectionClosed)
    await harness.client.waitUntilClosed()

    XCTAssertEqual(harness.subject.phase, .connecting)
    XCTAssertFalse(harness.phases.contains(.recordingForFallback))

    harness.capture.resumeStart()
    await begin.value

    XCTAssertEqual(harness.subject.phase, .recordingForFallback)
    await harness.subject.cancelAndWait()
}
```

Run:

```bash
swift test --filter WritingDictationCoordinatorTests/testConnectionFailureBeforeCaptureStartsWaitsToPublishFallbackRecording
```

Expected before the state guard: FAIL because `loseRealtime` publishes `recordingForFallback` while capture is still pending.

- [ ] **Step 7: Gate fallback-recording publication on capture readiness**

Change the held connection-loss branch to:

```swift
if updated.releaseRequested, updated.recordingURL != nil {
    startFallback(sessionID: sessionID)
} else if newlyLost, !updated.releaseRequested, updated.captureStarted {
    publish(.recordingForFallback)
}
```

The capture-completion branch from Step 4 becomes the single delayed publication path when Realtime failed first. Rerun the focused test and expect PASS.

- [ ] **Step 8: Add and pass the connection-first/capture-failure cleanup test**

Add:

```swift
func testCaptureFailureAfterConnectionReadyClosesRealtimeWithoutListening() async {
    let harness = DictationHarness()
    harness.capture.blockStart()
    harness.capture.startError = AudioRecorder.AudioRecorderError.recordingUnavailable
    let begin = Task { await harness.subject.beginHold() }
    await harness.capture.waitUntilStartWasCalled()
    await Task.yield()

    harness.client.completeConnection()
    await Task.yield()
    XCTAssertFalse(harness.client.didStartReceiving)

    harness.capture.resumeStart()
    await begin.value
    await harness.subject.cancelAndWait()

    XCTAssertFalse(harness.phases.contains(.listening))
    XCTAssertEqual(harness.transaction.restoreCount, 1)
    XCTAssertEqual(harness.client.closeCount, 1)
    XCTAssertEqual(harness.subject.phase, .failed("dictation.error.fallback"))
}
```

Run:

```bash
swift test --filter WritingDictationCoordinatorTests/testCaptureFailureAfterConnectionReadyClosesRealtimeWithoutListening
```

Expected: PASS with the implementation from Steps 4 and 7. If it fails, repair coordinator cleanup rather than weakening the assertions.

- [ ] **Step 9: Add and pass the permission privacy-boundary test**

Extend `FakeDictationCapture` with an authorization gate:

```swift
private var authorizationBlocked = false
private let authorizationGate = ManualGate()
private(set) var authorizationCount = 0
private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []

func authorizeMicrophone() async throws {
    authorizationCount += 1
    let waiters = authorizationWaiters
    authorizationWaiters.removeAll()
    waiters.forEach { $0.resume() }
    if authorizationBlocked {
        await authorizationGate.wait()
    }
}

func blockAuthorization() { authorizationBlocked = true }
func resumeAuthorization() {
    authorizationBlocked = false
    authorizationGate.open()
}
func waitUntilAuthorizationWasRequested() async {
    if authorizationCount > 0 { return }
    await withCheckedContinuation { authorizationWaiters.append($0) }
}
```

Add the behavior test, using the fake's actual request counter or waiter so it cannot miss a fast call:

```swift
func testRealtimeDoesNotConnectWhileMicrophoneAuthorizationIsPending() async {
    let harness = DictationHarness()
    harness.capture.blockAuthorization()
    harness.capture.blockStart()
    let begin = Task { await harness.subject.beginHold() }
    await harness.capture.waitUntilAuthorizationWasRequested()

    XCTAssertEqual(harness.client.connectCount, 0)
    XCTAssertEqual(harness.capture.startCount, 0)

    harness.capture.resumeAuthorization()
    await harness.capture.waitUntilStartWasCalled()
    await Task.yield()
    XCTAssertEqual(harness.client.connectCount, 1)

    let cancel = Task { await harness.subject.cancelAndWait() }
    harness.capture.resumeStart()
    await begin.value
    await cancel.value
}
```

Run the focused privacy test and expect PASS. The test starts cancellation before resuming the deliberately blocked fake capture, then joins both tasks so the existing cleanup contract is exercised without hanging.

- [ ] **Step 10: Run coordinator and cross-surface tests**

Run:

```bash
swift test --filter WritingDictationCoordinatorTests
swift test --filter AudioRecorderTests
swift test --filter WritingPopoverDictationViewModelTests
swift test --filter WritingDictationGestureTaskArbiterTests
```

Expected: all focused suites pass with zero failures and no hangs.

- [ ] **Step 11: Perform the serial-start mutation check**

Temporarily move the connect-operation creation back below successful `startStreaming`, run:

```bash
swift test --filter WritingDictationCoordinatorTests/testConnectionStartsWhileCaptureStartIsPendingAndListeningWaitsForBoth
```

Expected: FAIL at `connectCount == 1`. Restore the parallel ordering and rerun the same command for PASS.

- [ ] **Step 12: Review and commit the coordinator change**

Run:

```bash
git diff --check
git diff -- Sources/InkletApp/WritingDictationCoordinator.swift Tests/InkletCoreTests/WritingDictationCoordinatorTests.swift
git add Sources/InkletApp/WritingDictationCoordinator.swift Tests/InkletCoreTests/WritingDictationCoordinatorTests.swift
git diff --cached --check
git commit -m "Start Writing dictation capture and connection together"
```

Expected: the commit contains only concurrent startup, readiness/fallback guards, fake observability, and focused lifecycle tests.

### Task 3: Verify, review, version, install, and launch

**Files:**
- Verify: `Sources/InkletApp/AudioRecorder.swift`
- Verify: `Sources/InkletApp/WritingDictationCoordinator.swift`
- Verify: `Tests/InkletCoreTests/AudioRecorderTests.swift`
- Verify: `Tests/InkletCoreTests/WritingDictationCoordinatorTests.swift`
- Verify: `scripts/test-run-local-app.sh`
- Verify: `scripts/test-direct-distribution.sh`
- Modify: `VERSION`

- [ ] **Step 1: Run complete debug and release tests**

Run:

```bash
swift test
swift test -c release
```

Expected: every XCTest and Swift Testing test passes with zero failures in both configurations.

- [ ] **Step 2: Run strict builds and script checks**

Run:

```bash
swift build -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
bash scripts/test-run-local-app.sh
bash scripts/test-direct-distribution.sh
```

Expected: both builds finish without Swift warnings, the runner suite prints `run-local-app.sh checks passed.`, and the distribution suite prints `Direct distribution checks passed.`

- [ ] **Step 3: Request independent lifecycle and code-quality review**

Give reviewers the design, plan, base commit, head commit, and exact requirements. Require inspection of permission timing, connection-first and capture-first ordering, early-audio preservation, release during startup, cancellation joins, fallback publication, cleanup idempotence, and unchanged hold/UI behavior. Resolve all Critical and Important findings and rerun the affected focused tests.

- [ ] **Step 4: Increment the version before creating another bundle**

Change `VERSION` to exactly:

```dotenv
INKLET_VERSION=1.1.6
INKLET_BUILD_NUMBER=12
```

- [ ] **Step 5: Review and commit the version change**

Run:

```bash
git diff --check
git diff -- VERSION
git add VERSION
git diff --cached --check
git commit -m "Bump Inklet version to 1.1.6"
```

Expected: the commit changes only `1.1.5 (11)` to `1.1.6 (12)`.

- [ ] **Step 6: Build, sign, install, and launch the stable local bundle**

Run only:

```bash
scripts/run-local-app.sh
```

Expected: the runner stops the prior matching process, builds after the version commit, signs with the configured stable non-ad-hoc identity, verifies and installs `/Applications/Inklet Local.app`, and launches it.

- [ ] **Step 7: Verify the installed artifact and final repository state**

Run:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '/Applications/Inklet Local.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '/Applications/Inklet Local.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '/Applications/Inklet Local.app/Contents/Info.plist'
codesign --verify --deep --strict '/Applications/Inklet Local.app'
pgrep -fl '^/Applications/Inklet Local\.app/Contents/MacOS/Inklet Local$'
git diff --check
git status --short --branch
```

Expected: bundle ID `com.tomwan.inklet.local`, version `1.1.6`, build `12`, valid stable signature, exactly one process from the installed path, and a clean `codex/voice-writing-integration` worktree.

- [ ] **Step 8: Hand off physical latency QA**

Ask the user to open Writing Assistant, choose a Prompt Mode, focus the editable source draft, hold physical Right Option, and begin speaking immediately. Expected: the connecting/listening transition is faster than version 1.1.5, early speech appears in the final editable transcript, release finalizes once, and cancellation/fallback behavior remains unchanged.
