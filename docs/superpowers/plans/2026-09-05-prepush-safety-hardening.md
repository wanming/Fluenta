# Pre-Push Safety Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the security, Realtime failure, automatic-update race, shutdown, consent, and documentation gaps found before pushing the merged Writing Dictation work to `main`.

**Architecture:** Normalize historical recovery configuration and construct every production recovery request from one canonical OpenAI URL with redirects disabled. Route Realtime item failures through the existing one-shot fallback state machine, centralize automatic update presentation behind one deferred gate that observes a lock-backed selection interaction tracker, and quiesce/await selection work during shutdown. Keep the public disclosures and distribution contracts exact and testable.

**Tech Stack:** Swift 6, SwiftPM, AppKit, SwiftUI, XCTest, URLSession, shell distribution-contract tests

---

### Task 1: Normalize Legacy Recovery Endpoint Configuration

**Files:**
- Modify: `Sources/InkletCore/VoiceInputConfig.swift`
- Modify: `Tests/InkletCoreTests/VoiceInputConfigTests.swift`
- Modify: `Tests/InkletCoreTests/ConfigStoreTests.swift`

- [ ] **Step 1: Write failing normalization and encoding tests**

Replace custom-endpoint preservation assertions with a table-driven invariant and an encoded-value assertion:

```swift
func testLegacySpeechEndpointsNormalizeToCanonicalOpenAIEndpoint() throws {
    let legacyValues = [
        "https://fallback.example/v1/audio/transcriptions",
        "http://fallback.example/transcribe",
        "not a URL",
        "https://user:password@api.openai.com:8443/v1/audio/transcriptions?proxy=1"
    ]

    for legacyValue in legacyValues {
        let data = try JSONSerialization.data(withJSONObject: [
            "shortcut": "leftCommand",
            "speechEndpoint": legacyValue,
            "speechModel": "fallback-model",
            "microphoneDeviceID": "mic-123"
        ])
        let decoded = try JSONDecoder().decode(VoiceInputConfig.self, from: data)
        XCTAssertEqual(decoded.speechEndpoint, VoiceInputConfig.defaultSpeechEndpoint)
        XCTAssertEqual(decoded.shortcut, .leftCommand)
        XCTAssertEqual(decoded.speechModel, "fallback-model")
        XCTAssertEqual(decoded.microphoneDeviceID, "mic-123")
    }
}

func testEncodingAlwaysWritesCanonicalOpenAIRecoveryEndpoint() throws {
    let config = VoiceInputConfig(
        shortcut: .rightOption,
        speechModel: "gpt-4o-mini-transcribe",
        microphoneDeviceID: nil
    )
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
    )
    XCTAssertEqual(
        object["speechEndpoint"] as? String,
        VoiceInputConfig.defaultSpeechEndpoint
    )
}
```

Update the version-one-through-three migration test to expect `VoiceInputConfig.defaultSpeechEndpoint`, and update round-trip construction to omit the endpoint argument.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter VoiceInputConfigTests
swift test --filter ConfigStoreTests/testAppConfigMigratesVersionsOneThroughThreeToVersionFour
```

Expected: FAIL because decoding currently preserves historical endpoints and the initializer still requires `speechEndpoint`.

- [ ] **Step 3: Make the canonical endpoint an invariant**

Keep the legacy key in the Codable schema, validate its encoded type by decoding it, and discard its value:

```swift
public private(set) var speechEndpoint: String

public init(
    shortcut: Shortcut,
    speechModel: String,
    microphoneDeviceID: String?
) {
    self.shortcut = shortcut
    speechEndpoint = Self.defaultSpeechEndpoint
    self.speechModel = speechModel
    self.microphoneDeviceID = microphoneDeviceID
}

public init(from decoder: Decoder) throws {
    let defaults = Self.defaultConfig()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    shortcut = try container.decodeIfPresent(Shortcut.self, forKey: .shortcut) ?? defaults.shortcut
    _ = try container.decodeIfPresent(String.self, forKey: .speechEndpoint)
    speechEndpoint = Self.defaultSpeechEndpoint
    speechModel = try container.decodeIfPresent(String.self, forKey: .speechModel) ?? defaults.speechModel
    microphoneDeviceID = try container.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
}

public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(shortcut, forKey: .shortcut)
    try container.encode(Self.defaultSpeechEndpoint, forKey: .speechEndpoint)
    try container.encode(speechModel, forKey: .speechModel)
    try container.encodeIfPresent(microphoneDeviceID, forKey: .microphoneDeviceID)
}
```

Update `defaultConfig()` and all compile errors to use the three-argument initializer. Do not bump `AppConfig.currentVersion`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter VoiceInputConfigTests
swift test --filter ConfigStoreTests/testAppConfigMigratesVersionsOneThroughThreeToVersionFour
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/InkletCore/VoiceInputConfig.swift \
  Tests/InkletCoreTests/VoiceInputConfigTests.swift \
  Tests/InkletCoreTests/ConfigStoreTests.swift
git commit -m "Normalize dictation recovery endpoint configuration"
```

### Task 2: Pin Recovery Requests And Reject Redirects

**Files:**
- Modify: `Sources/InkletCore/OpenAISpeechTranscriptionProvider.swift`
- Modify: `Tests/InkletCoreTests/OpenAISpeechTranscriptionProviderTests.swift`

- [ ] **Step 1: Write failing canonical URL and redirect tests**

Update request-builder calls to omit `endpoint` and add exact URL assertions:

```swift
func testRequestUsesCanonicalOpenAIRecoveryURL() throws {
    let audioURL = temporaryAudioFile(contents: Data([1, 2, 3]))
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let request = try OpenAISpeechTranscriptionProvider.makeURLRequest(
        SpeechTranscriptionRequest(
            audioFileURL: audioURL,
            model: "gpt-4o-mini-transcribe",
            timeoutSeconds: 9
        ),
        apiKey: "test-key",
        boundary: "InkletBoundary"
    )
    let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "api.openai.com")
    XCTAssertNil(components.port)
    XCTAssertEqual(components.path, "/v1/audio/transcriptions")
    XCTAssertNil(components.query)
    XCTAssertNil(components.user)
    XCTAssertNil(components.password)
}

func testRecoveryRedirectPolicyDeclinesSameAndCrossHostRequests() throws {
    let delegate = RedirectRejectingDelegate()
    for target in [
        "https://api.openai.com/redirected",
        "https://attacker.example/capture"
    ] {
        var followedRequest: URLRequest?
        delegate.urlSession(
            .shared,
            task: URLSession.shared.dataTask(with: URL(string: VoiceInputConfig.defaultSpeechEndpoint)!),
            willPerformHTTPRedirection: try XCTUnwrap(HTTPURLResponse(
                url: URL(string: VoiceInputConfig.defaultSpeechEndpoint)!,
                statusCode: 307,
                httpVersion: nil,
                headerFields: ["Location": target]
            )),
            newRequest: URLRequest(url: try XCTUnwrap(URL(string: target))),
            completionHandler: { followedRequest = $0 }
        )
        XCTAssertNil(followedRequest)
    }
}
```

Extend the mock protocol redirect fixture so `testTranscribeRejectsRedirectBeforeForwardingAuthorizationOrAudio` records requests, returns a 307 toward a second host, and asserts the second host received no request, header, or body.

- [ ] **Step 2: Run the provider tests and verify RED**

Run: `swift test --filter OpenAISpeechTranscriptionProviderTests`

Expected: FAIL because the public builder/initializer accept arbitrary endpoints and the provider uses a redirect-following session.

- [ ] **Step 3: Restrict the production API and session**

Reuse the existing `RedirectRejectingDelegate` from `GitHubReleaseUpdateChecker.swift`. Make production construction canonical and keep only an internal configuration seam for URLProtocol tests:

```swift
public init(apiKeyProvider: @escaping @Sendable () throws -> String) {
    self.init(
        apiKeyProvider: apiKeyProvider,
        endpoint: URL(string: VoiceInputConfig.defaultSpeechEndpoint)!,
        sessionConfiguration: Self.productionSessionConfiguration()
    )
}

init(
    apiKeyProvider: @escaping @Sendable () throws -> String,
    endpoint: URL,
    sessionConfiguration: URLSessionConfiguration
) {
    self.apiKeyProvider = apiKeyProvider
    self.endpoint = endpoint
    session = URLSession(
        configuration: sessionConfiguration,
        delegate: RedirectRejectingDelegate(),
        delegateQueue: nil
    )
}

public static func makeURLRequest(
    _ request: SpeechTranscriptionRequest,
    apiKey: String,
    boundary: String
) throws -> URLRequest {
    try makeURLRequest(
        request,
        endpoint: URL(string: VoiceInputConfig.defaultSpeechEndpoint)!,
        apiKey: apiKey,
        boundary: boundary
    )
}
```

The production configuration must be ephemeral with `urlCredentialStorage`, `httpCookieStorage`, and `urlCache` set to `nil`. The internal endpoint overload remains non-public and is used only by tests. Map a received 3xx response to `SpeechTranscriptionError.provider`.

- [ ] **Step 4: Run focused security tests and verify GREEN**

Run:

```bash
swift test --filter OpenAISpeechTranscriptionProviderTests
swift test --filter GitHubReleaseUpdateCheckerTests/testRedirectDelegateDeclinesRedirectRequest
```

Expected: PASS; the redirect fixture records exactly one request to the canonical origin.

- [ ] **Step 5: Commit**

```bash
git add Sources/InkletCore/OpenAISpeechTranscriptionProvider.swift \
  Tests/InkletCoreTests/OpenAISpeechTranscriptionProviderTests.swift
git commit -m "Pin dictation recovery requests to OpenAI"
```

### Task 3: Remove Recovery Endpoint UI And Runtime Trust

**Files:**
- Modify: `Sources/InkletApp/SettingsView.swift`
- Modify: `Sources/InkletApp/InkletPopoverWindowController.swift`
- Modify: `Sources/InkletApp/InkletLocalization.swift`
- Modify: `Tests/InkletCoreTests/SettingsViewSourceTests.swift`
- Modify: `Tests/InkletCoreTests/WritingDictationLocalizationTests.swift`
- Modify: `Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift`

- [ ] **Step 1: Write failing source and localization contracts**

Require Advanced Dictation to retain the model while removing every editable-endpoint path:

```swift
func testWriteAssistantExposesRecoveryModelWithoutEditableEndpoint() throws {
    let source = try appSource(named: "SettingsView.swift")
    XCTAssertTrue(source.contains("$model.config.voiceInput.speechModel"))
    XCTAssertFalse(source.contains("$model.config.voiceInput.speechEndpoint"))
    XCTAssertFalse(source.contains("settings.row.fallbackSpeechEndpoint"))
    XCTAssertFalse(source.contains("settings.help.fallbackSpeechEndpoint"))
    XCTAssertFalse(source.contains("settings.error.invalidFallbackSpeechEndpoint"))
}
```

In `WritingModeLauncherSourceTests`, require the fallback closure to contain `OpenAISpeechTranscriptionProvider(apiKeyProvider:` and not contain `config.speechEndpoint`. Move the three endpoint localization identifiers from required keys to retired keys in `WritingDictationLocalizationTests`.

- [ ] **Step 2: Run the source tests and verify RED**

Run:

```bash
swift test --filter SettingsViewSourceTests/testWriteAssistantExposesRecoveryModelWithoutEditableEndpoint
swift test --filter WritingDictationLocalizationTests
swift test --filter WritingModeLauncherSourceTests/testWindowControllerOwnsTheWritingDictationDependencyGraph
```

Expected: FAIL because Settings validates/renders the endpoint and runtime parses it.

- [ ] **Step 3: Remove the unsafe paths**

Delete the endpoint URL validation from `SettingsViewModel.save()`, delete its settings row, and remove `settings.row.fallbackSpeechEndpoint`, `settings.help.fallbackSpeechEndpoint`, and `settings.error.invalidFallbackSpeechEndpoint` from every localization table.

Replace runtime endpoint parsing with canonical provider construction:

```swift
let provider = OpenAISpeechTranscriptionProvider(
    apiKeyProvider: { apiKey }
)
return try await provider.transcribe(SpeechTranscriptionRequest(
    audioFileURL: audioFileURL,
    model: config.speechModel,
    timeoutSeconds: 60
))
```

Retain the recovery model control and the existing shared OpenAI Keychain lookup.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter SettingsViewSourceTests
swift test --filter WritingDictationLocalizationTests
swift test --filter WritingModeLauncherSourceTests/testWindowControllerOwnsTheWritingDictationDependencyGraph
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/InkletApp/SettingsView.swift \
  Sources/InkletApp/InkletPopoverWindowController.swift \
  Sources/InkletApp/InkletLocalization.swift \
  Tests/InkletCoreTests/SettingsViewSourceTests.swift \
  Tests/InkletCoreTests/WritingDictationLocalizationTests.swift \
  Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift
git commit -m "Remove the recovery endpoint setting"
```

### Task 4: Handle Realtime Item-Level Transcription Failures

**Files:**
- Modify: `Sources/InkletCore/OpenAIRealtimeTranscriptionClient.swift`
- Modify: `Tests/InkletCoreTests/OpenAIRealtimeTranscriptionClientTests.swift`
- Modify: `Tests/InkletCoreTests/WritingDictationCoordinatorTests.swift`

- [ ] **Step 1: Write deterministic failing parser tests**

Enqueue each failed payload followed by a valid delta sentinel so current code fails promptly instead of hanging:

```swift
func testNextEventMapsInputAudioTranscriptionFailureToServerError() async throws {
    let harness = await connectedHarness()
    harness.transport.enqueueText(#"{
      "type":"conversation.item.input_audio_transcription.failed",
      "event_id":"evt_1",
      "item_id":"item_1",
      "content_index":0,
      "error":{
        "type":"invalid_request_error",
        "code":"audio_unintelligible",
        "message":"Audio is unintelligible",
        "param":"audio"
      }
    }"#)
    harness.transport.enqueueText(#"{
      "type":"conversation.item.input_audio_transcription.delta",
      "item_id":"sentinel",
      "content_index":0,
      "delta":"wrong"
    }"#)

    do {
        _ = try await harness.client.nextEvent()
        XCTFail("Expected item transcription failure")
    } catch {
        XCTAssertEqual(
            error as? RealtimeTranscriptionError,
            .server(code: "audio_unintelligible", message: "Audio is unintelligible")
        )
    }
    XCTAssertEqual(harness.transport.closeCount, 1)
}
```

Add table-driven cases accepting absent/`null` `event_id`, `code`, and `param`, and rejecting wrong/missing `item_id`, `content_index`, `error`, `error.type`, `error.message`, `error.code`, and `error.param` as `.invalidMessage`.

- [ ] **Step 2: Run parser tests and verify RED**

Run:

```bash
swift test --filter OpenAIRealtimeTranscriptionClientTests/testNextEventMapsInputAudioTranscriptionFailureToServerError
swift test --filter OpenAIRealtimeTranscriptionClientTests/testNextEventAcceptsAbsentAndNullOptionalInputAudioTranscriptionFailureFields
swift test --filter OpenAIRealtimeTranscriptionClientTests/testNextEventRejectsMalformedInputAudioTranscriptionFailureFields
```

Expected: FAIL because the failed event is skipped and the sentinel is returned.

- [ ] **Step 3: Parse the documented failure shape**

Call this parser after generic server-error parsing and before delta/completed parsing:

```swift
private static func inputAudioTranscriptionFailure(
    from message: [String: Any]
) throws -> RealtimeTranscriptionError? {
    let type = try requiredString(message["type"])
    guard type == "conversation.item.input_audio_transcription.failed" else { return nil }

    _ = try optionalString(message, key: "event_id")
    _ = try requiredString(message["item_id"])
    _ = try requiredInteger(message["content_index"])
    guard let details = message["error"] as? [String: Any] else {
        throw RealtimeTranscriptionError.invalidMessage
    }
    _ = try requiredString(details["type"])
    let code = try optionalString(details, key: "code")
    let errorMessage = try requiredString(details["message"])
    _ = try optionalString(details, key: "param")
    return .server(code: code, message: errorMessage)
}

private static func optionalString(
    _ message: [String: Any],
    key: String
) throws -> String? {
    guard let value = message[key], !(value is NSNull) else { return nil }
    return try requiredString(value)
}
```

Do not log or display the raw server message.

- [ ] **Step 4: Characterize immediate coordinator recovery**

Update the held-failure test to inject `.server(code: "audio_unintelligible", message: "Audio is unintelligible")`, and add a released-session test using the manual timeout waiter:

```swift
await harness.subject.endHold()
await harness.client.waitUntilCommitted()
await harness.waitUntilTimeoutStarts()
harness.client.failReceive(with: RealtimeTranscriptionError.server(
    code: "audio_unintelligible",
    message: "Audio is unintelligible"
))
await harness.waitUntilFallbackStarts()
XCTAssertEqual(harness.subject.phase, .recovering)
XCTAssertEqual(harness.timeoutAdvanceCount, 0)
XCTAssertEqual(harness.fallbackRequests, [harness.capture.recordingURL])
```

Add `advanceCount` to the manual timeout waiter; advance it only during teardown after the zero-count assertion.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter OpenAIRealtimeTranscriptionClientTests
swift test --filter WritingDictationCoordinatorTests/testRealtimeServerFailureWhileHeldKeepsRecordingUntilReleaseThenFallsBack
swift test --filter WritingDictationCoordinatorTests/testRealtimeServerFailureAfterReleaseStartsFallbackWithoutAdvancingFinalTimeout
```

Expected: PASS without changing production coordinator state transitions.

- [ ] **Step 6: Commit**

```bash
git add Sources/InkletCore/OpenAIRealtimeTranscriptionClient.swift \
  Tests/InkletCoreTests/OpenAIRealtimeTranscriptionClientTests.swift \
  Tests/InkletCoreTests/WritingDictationCoordinatorTests.swift
git commit -m "Handle realtime transcription item failures"
```

### Task 5: Centralize Deferred Automatic Update Presentation

**Files:**
- Create: `Sources/InkletApp/AutomaticUpdatePresentationGate.swift`
- Create: `Tests/InkletCoreTests/AutomaticUpdatePresentationGateTests.swift`
- Modify: `Sources/InkletApp/UpdateCheckCoordinator.swift`
- Modify: `Sources/InkletApp/AppCoordinator.swift`
- Modify: `Tests/InkletCoreTests/UpdateCheckCoordinatorTests.swift`
- Modify: `Tests/InkletCoreTests/AppCoordinatorSourceTests.swift`

- [ ] **Step 1: Write failing gate and coordinator tests**

Test next-turn coalescing, execution-time eligibility, rescheduling, and stale-task cancellation:

```swift
@MainActor
func testScheduledPresentationRechecksEligibilityAtExecution() async {
    var canPresent = true
    var presentations = 0
    let gate = AutomaticUpdatePresentationGate(
        canPresent: { canPresent },
        present: { presentations += 1 }
    )
    gate.schedule()
    canPresent = false
    await Task.yield()
    XCTAssertEqual(presentations, 0)
    canPresent = true
    gate.schedule()
    await Task.yield()
    XCTAssertEqual(presentations, 1)
}
```

Add coordinator tests requiring an automatic result to set pending state and invoke `onPendingAutomaticUpdate` without presenting inline. Preserve immediate manual results, and require an automatic failure with an older pending release to schedule rather than flush inline.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter AutomaticUpdatePresentationGateTests
swift test --filter UpdateCheckCoordinatorTests
```

Expected: compile failure for the new gate and behavior failures for inline automatic presentation.

- [ ] **Step 3: Implement the generation-protected deferred gate**

```swift
@MainActor
final class AutomaticUpdatePresentationGate {
    typealias Eligibility = @MainActor () -> Bool
    typealias Presentation = @MainActor () -> Void

    private let canPresent: Eligibility
    private let present: Presentation
    private var scheduledTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(canPresent: @escaping Eligibility, present: @escaping Presentation) {
        self.canPresent = canPresent
        self.present = present
    }

    func schedule() {
        guard scheduledTask == nil else { return }
        generation &+= 1
        let capturedGeneration = generation
        scheduledTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.generation == capturedGeneration else { return }
            self.scheduledTask = nil
            guard self.canPresent() else { return }
            self.present()
        }
    }

    func cancel() {
        generation &+= 1
        scheduledTask?.cancel()
        scheduledTask = nil
    }
}
```

Give `UpdateCheckCoordinator` an `onPendingAutomaticUpdate` callback. Every automatic available result stores `PendingAutomaticUpdate` and invokes the callback; it never invokes the presenter. Automatic failure invokes the callback only if an older pending release exists. Manual behavior stays unchanged.

- [ ] **Step 4: Wire one gate into AppCoordinator**

Create one gate whose `canPresent` closure computes `AutomaticUpdatePresentationState.canPresent` and whose `present` closure calls `presentPendingAutomaticUpdateIfPossible()`. Both `refreshMigrationImportEligibility()` and `onPendingAutomaticUpdate` call `schedule()`; remove all other direct automatic flush call sites.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter AutomaticUpdatePresentationGateTests
swift test --filter UpdateCheckCoordinatorTests
swift test --filter AppCoordinatorSourceTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/InkletApp/AutomaticUpdatePresentationGate.swift \
  Sources/InkletApp/UpdateCheckCoordinator.swift \
  Sources/InkletApp/AppCoordinator.swift \
  Tests/InkletCoreTests/AutomaticUpdatePresentationGateTests.swift \
  Tests/InkletCoreTests/UpdateCheckCoordinatorTests.swift \
  Tests/InkletCoreTests/AppCoordinatorSourceTests.swift
git commit -m "Defer automatic update presentation"
```

### Task 6: Track Mouse, Shift, And Double-Copy Interaction Activity

**Files:**
- Create: `Sources/InkletApp/SelectionInteractionTracker.swift`
- Create: `Tests/InkletCoreTests/SelectionInteractionTrackerTests.swift`
- Modify: `Sources/InkletApp/SelectionActionMonitor.swift`
- Modify: `Sources/InkletApp/SelectionCopyEventTap.swift`
- Modify: `Sources/InkletApp/AutomaticUpdatePresentationState.swift`
- Modify: `Sources/InkletApp/AppCoordinator.swift`
- Modify: `Tests/InkletCoreTests/SelectionCopyEventTapTests.swift`
- Modify: `Tests/InkletCoreTests/SelectionActionMonitorSourceTests.swift`
- Modify: `Tests/InkletCoreTests/AutomaticUpdatePresentationStateTests.swift`
- Modify: `Tests/InkletCoreTests/AutomaticUpdatePresentationGateTests.swift`
- Modify: `Tests/InkletCoreTests/AppCoordinatorSourceTests.swift`

- [ ] **Step 1: Write failing tracker and state tests**

Cover queued handoffs, overlapping interaction kinds, and reset:

```swift
func testMouseReleaseStaysActiveUntilQueuedHandoffCompletes() {
    let tracker = SelectionInteractionTracker()
    XCTAssertEqual(tracker.begin(.mouse), .becameActive)
    tracker.enqueueHandoff(for: .mouse)
    XCTAssertEqual(tracker.release(.mouse), .unchanged)
    XCTAssertTrue(tracker.isActive)
    XCTAssertEqual(tracker.completeHandoff(for: .mouse), .becameIdle)
    XCTAssertFalse(tracker.isActive)
}
```

Extend `AutomaticUpdatePresentationState` tests so both `isSelectionInteractionActive` and `isStopping` independently make `canPresent` false.

- [ ] **Step 2: Run tracker/state tests and verify RED**

Run:

```bash
swift test --filter SelectionInteractionTrackerTests
swift test --filter AutomaticUpdatePresentationStateTests
```

Expected: compile failure because the tracker and new state fields do not exist.

- [ ] **Step 3: Implement the lock-backed tracker**

```swift
enum SelectionInteractionKind: Hashable, Sendable { case mouse, keyboard, copy }
enum SelectionInteractionTransition: Equatable, Sendable { case unchanged, becameActive, becameIdle }

final class SelectionInteractionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pressed: Set<SelectionInteractionKind> = []
    private var pendingHandoffs: [SelectionInteractionKind: Int] = [:]

    var isActive: Bool {
        lock.withLock { isActiveWhileLocked }
    }

    func begin(_ kind: SelectionInteractionKind) -> SelectionInteractionTransition {
        mutate { pressed.insert(kind) }
    }

    func enqueueHandoff(for kind: SelectionInteractionKind) {
        lock.withLock { pendingHandoffs[kind, default: 0] += 1 }
    }

    func release(_ kind: SelectionInteractionKind) -> SelectionInteractionTransition {
        mutate { pressed.remove(kind) }
    }

    func completeHandoff(for kind: SelectionInteractionKind) -> SelectionInteractionTransition {
        mutate {
            let remaining = max(0, pendingHandoffs[kind, default: 0] - 1)
            if remaining == 0 {
                pendingHandoffs.removeValue(forKey: kind)
            } else {
                pendingHandoffs[kind] = remaining
            }
        }
    }

    func reset() -> SelectionInteractionTransition {
        mutate {
            pressed.removeAll()
            pendingHandoffs.removeAll()
        }
    }

    private var isActiveWhileLocked: Bool {
        !pressed.isEmpty || pendingHandoffs.values.contains { $0 > 0 }
    }

    private func mutate(_ mutation: () -> Void) -> SelectionInteractionTransition {
        lock.withLock {
            let wasActive = isActiveWhileLocked
            mutation()
            let isActive = isActiveWhileLocked
            switch (wasActive, isActive) {
            case (false, true): return .becameActive
            case (true, false): return .becameIdle
            default: return .unchanged
            }
        }
    }
}
```

Each mutator compares aggregate activity before and after the mutation and returns exactly one transition.

- [ ] **Step 4: Write failing event-order tests**

Add copy-tap tests that use an injected expiry waiter:

```swift
func testSecondCopyTriggersWhileActiveAndEndsAfterCallbackReturns() {
    var active = false
    var activeDuringTrigger = false
    let tap = SelectionCopyEventTap(
        onInteractionBegan: { active = true },
        onInteractionEnded: { active = false },
        onCopyTrigger: { _ in activeDuringTrigger = active }
    )
    tap.handleEventFields(copyKeyDown(at: 1.0))
    tap.handleEventFields(copyKeyUp(at: 1.1))
    tap.handleEventFields(copyKeyDown(at: 1.2))
    XCTAssertTrue(activeDuringTrigger)
    XCTAssertFalse(active)
}
```

Add source contracts proving mouse/Shift starts occur before any `Task` hop and completion occurs only after candidate/dismiss callbacks. Require AppCoordinator handlers to register read work synchronously before interaction completion.

- [ ] **Step 5: Run monitor tests and verify RED**

Run:

```bash
swift test --filter SelectionCopyEventTapTests
swift test --filter SelectionActionMonitorSourceTests
swift test --filter AppCoordinatorSourceTests
```

Expected: FAIL because the monitor has no interaction callbacks or expiry task.

- [ ] **Step 6: Integrate interaction tracking and live physical state**

Add:

```swift
struct SelectionPhysicalInteractionState: Equatable, Sendable {
    let isLeftMouseButtonPressed: Bool
    let isShiftPressed: Bool
    var isActive: Bool { isLeftMouseButtonPressed || isShiftPressed }
}
```

`SelectionActionMonitor` exposes `isInteractionActive` as tracker activity OR the injectable physical provider, and `onInteractionStateChange`. Record raw left-down and Shift-down synchronously before actor hops; keep mouse-up/Shift-release active through their candidate or dismissal callbacks. `SelectionCopyEventTap` begins on `.armed`, schedules a generation-protected 0.8-second expiry, invokes the second-copy trigger while active, and ends only after the callback returns. `stop()` cancels expiry and resets all interaction state.

Remove unnecessary `Task { @MainActor ... }` wrappers from AppCoordinator’s monitor callbacks. On idle transitions schedule the sole automatic-update gate. Include live interaction and stopping in the presentation state.

- [ ] **Step 7: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter SelectionInteractionTrackerTests
swift test --filter SelectionCopyEventTapTests
swift test --filter SelectionActionMonitorSourceTests
swift test --filter AutomaticUpdatePresentationStateTests
swift test --filter AutomaticUpdatePresentationGateTests
swift test --filter AppCoordinatorSourceTests
```

Expected: PASS, including pre-scheduled alert recheck and first-copy expiry rescheduling.

- [ ] **Step 8: Commit**

```bash
git add Sources/InkletApp/SelectionInteractionTracker.swift \
  Sources/InkletApp/SelectionActionMonitor.swift \
  Sources/InkletApp/SelectionCopyEventTap.swift \
  Sources/InkletApp/AutomaticUpdatePresentationState.swift \
  Sources/InkletApp/AppCoordinator.swift \
  Tests/InkletCoreTests/SelectionInteractionTrackerTests.swift \
  Tests/InkletCoreTests/SelectionCopyEventTapTests.swift \
  Tests/InkletCoreTests/SelectionActionMonitorSourceTests.swift \
  Tests/InkletCoreTests/AutomaticUpdatePresentationStateTests.swift \
  Tests/InkletCoreTests/AutomaticUpdatePresentationGateTests.swift \
  Tests/InkletCoreTests/AppCoordinatorSourceTests.swift
git commit -m "Gate updates on active selection interactions"
```

### Task 7: Quiesce And Join Selection Work During Shutdown

**Files:**
- Create: `Sources/InkletApp/SelectionShutdownTaskSnapshot.swift`
- Create: `Tests/InkletCoreTests/SelectionShutdownTaskSnapshotTests.swift`
- Modify: `Sources/InkletApp/AppCoordinator.swift`
- Modify: `Tests/InkletCoreTests/AppCoordinatorSourceTests.swift`
- Modify: `Tests/InkletCoreTests/SelectionClipboardReaderTests.swift`

- [ ] **Step 1: Write failing snapshot and shutdown-order tests**

```swift
@MainActor
func testWaitDoesNotReturnUntilEveryCapturedTaskFinishes() async {
    let readGate = AsyncTestGate()
    let speechGate = AsyncTestGate()
    let snapshot = SelectionShutdownTaskSnapshot(
        read: Task { await readGate.wait() },
        translation: nil,
        speech: Task { await speechGate.wait() },
        feedback: nil
    )
    let waiter = Task { await snapshot.waitForCompletion() }
    await Task.yield()
    XCTAssertFalse(waiter.isCancelled)
    readGate.open()
    await Task.yield()
    speechGate.open()
    await waiter.value
}
```

Add source tests that slice `stop()` at its first `await` and assert `isStopping`, update stop, gate cancel, observer removal, hotkey unregister, selection monitor stop, task snapshot, cancellation, and playback stop all occur in the synchronous prefix. Add queued-callback tests requiring `guard !isStopping` before starting candidate/copy/dismiss/configuration work.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter SelectionShutdownTaskSnapshotTests
swift test --filter AppCoordinatorSourceTests
```

Expected: compile/source-contract failures.

- [ ] **Step 3: Implement snapshot cancellation and joining**

```swift
struct SelectionShutdownTaskSnapshot {
    let read: Task<Void, Never>?
    let translation: Task<Void, Never>?
    let speech: Task<Void, Never>?
    let feedback: Task<Void, Never>?

    func cancel() {
        read?.cancel()
        translation?.cancel()
        speech?.cancel()
        feedback?.cancel()
    }

    func waitForCompletion() async {
        await read?.value
        await translation?.value
        await speech?.value
        await feedback?.value
    }
}
```

Reorder `AppCoordinator.stop()` so its synchronous prefix sets stopping, stops update scheduling, removes all observers/shortcut monitors, unregisters hotkeys, stops the selection monitor, captures and clears task slots/IDs, cancels the snapshot, and stops playback before its first `await`. Then:

```swift
await windowController.cancelDictationAndWait()
await selectionClipboardReader.cancelActiveRead()
await selectionTasks.waitForCompletion()
```

Add `!isStopping` guards to every queued selection callback, monitor configuration/start path, and post-suspension selection completion path.

- [ ] **Step 4: Add clipboard terminal-outcome coverage**

Use the existing fake pasteboard in `SelectionClipboardReaderTests` to prove shutdown cancellation restores the captured clipboard when Inklet still owns the transaction and returns `.restorationRelinquished` without overwriting when an external change count/value wins.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter SelectionShutdownTaskSnapshotTests
swift test --filter AppCoordinatorSourceTests
swift test --filter SelectionClipboardReaderTests
```

Expected: PASS; no shutdown path can restart a monitor or abandon clipboard ownership.

- [ ] **Step 6: Commit**

```bash
git add Sources/InkletApp/SelectionShutdownTaskSnapshot.swift \
  Sources/InkletApp/AppCoordinator.swift \
  Tests/InkletCoreTests/SelectionShutdownTaskSnapshotTests.swift \
  Tests/InkletCoreTests/AppCoordinatorSourceTests.swift \
  Tests/InkletCoreTests/SelectionClipboardReaderTests.swift
git commit -m "Quiesce selection work before shutdown"
```

### Task 8: Align Consent, Privacy, Security, And QA Documentation

**Files:**
- Modify: `StoreSupport/Info.plist`
- Modify: `StoreSupport/InfoPlistStrings/en.lproj/InfoPlist.strings`
- Modify: `StoreSupport/InfoPlistStrings/zh-Hans.lproj/InfoPlist.strings`
- Modify: `StoreSupport/InfoPlistStrings/zh-Hant.lproj/InfoPlist.strings`
- Modify: `StoreSupport/InfoPlistStrings/ja.lproj/InfoPlist.strings`
- Modify: `StoreSupport/InfoPlistStrings/ko.lproj/InfoPlist.strings`
- Modify: `StoreSupport/InfoPlistStrings/es.lproj/InfoPlist.strings`
- Modify: `StoreSupport/InfoPlistStrings/fr.lproj/InfoPlist.strings`
- Modify: `StoreSupport/InfoPlistStrings/de.lproj/InfoPlist.strings`
- Modify: `StoreSupport/InfoPlistStrings/pt.lproj/InfoPlist.strings`
- Modify: `StoreSupport/InfoPlistStrings/it.lproj/InfoPlist.strings`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `SECURITY.md`
- Modify: `docs/privacy-policy.md`
- Modify: `docs/manual-test-checklist.md`
- Modify: `Tests/InkletCoreTests/DirectDistributionContractTests.swift`
- Modify: `Tests/InkletCoreTests/UpdateCheckDocumentationTests.swift`
- Modify: `scripts/test-direct-distribution.sh`

- [ ] **Step 1: Write failing exact disclosure contracts**

Use an exact path-to-string map for base plus ten localized microphone strings. Base/English must be:

```text
Inklet streams microphone audio to OpenAI during a valid Dictation hold and keeps a temporary recovery recording for that session.
```

Require the privacy policy date to equal exactly `Last updated: September 5, 2026` once, and require public documents to contain the canonical URL, shared OpenAI key, local-until-fallback, at-most-once upload, and redirect-rejection contracts. Require the manual checklist phrases:

```text
compare responsiveness with the prior local build
speak immediately after holding
the beginning of the utterance is preserved
```

Update the shell contract date and add rejection checks for `configured recovery endpoint`, `recovery endpoint and model`, `恢复转写端点和模型`, and `voice recording`.

- [ ] **Step 2: Run distribution contracts and verify RED**

Run:

```bash
swift test --filter DirectDistributionContractTests
swift test --filter UpdateCheckDocumentationTests
bash scripts/test-direct-distribution.sh
```

Expected: FAIL on stale permission copy, August 30 date, endpoint-editing claims, and missing physical latency QA.

- [ ] **Step 3: Update all ten consent translations**

Set base and English to the exact string above. Use the approved concise translations:

```text
zh-Hans: 有效长按听写快捷键时，Inklet 会将麦克风音频流式发送到 OpenAI，并为该次会话保留一份临时恢复录音。
zh-Hant: 有效長按聽寫快速鍵時，Inklet 會將麥克風音訊串流傳送至 OpenAI，並為該次工作階段保留一份暫時復原錄音。
ja: 有効な音声入力の長押し中、Inklet はマイク音声を OpenAI にストリーミングし、そのセッション用の一時的な復旧録音を保持します。
ko: 유효한 받아쓰기 길게 누르기 동안 Inklet은 마이크 오디오를 OpenAI로 스트리밍하고 해당 세션의 임시 복구 녹음을 보관합니다.
es: Durante una pulsación válida para Dictado, Inklet transmite el audio del micrófono a OpenAI y conserva una grabación temporal de recuperación para esa sesión.
fr: Lors d’un appui valide pour la dictée, Inklet diffuse l’audio du microphone vers OpenAI et conserve un enregistrement temporaire de récupération pour cette session.
de: Während du die Diktierfunktion gültig gedrückt hältst, streamt Inklet Mikrofonaudio an OpenAI und speichert für diese Sitzung eine temporäre Wiederherstellungsaufnahme.
pt: Durante um pressionamento válido para Ditado, o Inklet transmite o áudio do microfone para a OpenAI e mantém uma gravação temporária de recuperação para essa sessão.
it: Durante una pressione valida per la dettatura, Inklet trasmette l’audio del microfono a OpenAI e conserva una registrazione temporanea di recupero per la sessione.
```

- [ ] **Step 4: Update public behavior and privacy documentation**

In both READMEs say Advanced Dictation exposes only the recovery model; the one recovery request uses the same OpenAI key and fixed `https://api.openai.com/v1/audio/transcriptions`; the temporary file remains local until fallback actually starts.

In `SECURITY.md`, document legacy normalization, fixed HTTPS request construction, shared-key use, and same-/cross-host redirect rejection before forwarding Authorization/audio. In the privacy policy update the exact date and preserve the full terminal deletion list. In the manual checklist replace retired “voice recording” wording and add the three physical startup checks.

- [ ] **Step 5: Run exact disclosure verification and verify GREEN**

Run:

```bash
plutil -lint StoreSupport/Info.plist StoreSupport/InfoPlistStrings/*.lproj/InfoPlist.strings
swift test --filter DirectDistributionContractTests
swift test --filter UpdateCheckDocumentationTests
bash scripts/test-direct-distribution.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add StoreSupport/Info.plist StoreSupport/InfoPlistStrings \
  README.md README.zh-CN.md SECURITY.md \
  docs/privacy-policy.md docs/manual-test-checklist.md \
  Tests/InkletCoreTests/DirectDistributionContractTests.swift \
  Tests/InkletCoreTests/UpdateCheckDocumentationTests.swift \
  scripts/test-direct-distribution.sh
git commit -m "Document fixed OpenAI dictation recovery"
```

### Task 9: Verify, Review, Integrate, And Push Main

**Files:**
- Inspect: all files changed since `874ffaa`
- Modify only if verification or review exposes a defect

- [ ] **Step 1: Run the complete automated verification matrix**

Run each command separately and retain the exit status:

```bash
swift test
swift test -c release
swift build -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
bash scripts/test-run-local-app.sh
bash scripts/test-direct-distribution.sh
git diff --check
git status --short --branch
```

Expected: every command exits 0; only intentional tracked changes are present. Do not run `scripts/run-local-app.sh`, build an app bundle, or modify `VERSION`.

- [ ] **Step 2: Run privacy and repository hygiene checks**

Run:

```bash
rg -n '/Users/|AKIA|sk-[A-Za-z0-9_-]{12,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|INKLET_(LOCAL_)?SIGN_IDENTITY' \
  README.md README.zh-CN.md SECURITY.md docs Sources Tests StoreSupport scripts
git diff --stat e6953ce...HEAD
git log --oneline e6953ce..HEAD
```

Expected: no committed personal path, credential, private key, or signing identity; the diff contains only the approved hardening work and plan/spec documents.

- [ ] **Step 3: Request independent code review and fix findings test-first**

Review the complete range `e6953ce..HEAD` against the approved spec. For every Critical or Important finding, add a reproducing test, run it RED, make the smallest fix, rerun GREEN, and commit with an imperative English subject. Repeat review until no blocking findings remain.

- [ ] **Step 4: Fetch and integrate into local main without rewriting history**

From the primary repository checkout:

```bash
git fetch origin main
git merge --no-ff codex/prepush-safety-fixes -m "Merge pre-push safety hardening"
```

If `origin/main` is not an ancestor of local `main`, first merge `origin/main` into local `main` and resolve conflicts without rebasing or force-pushing.

- [ ] **Step 5: Verify the exact merged main commit**

From the primary repository checkout, rerun:

```bash
swift test
swift test -c release
swift build -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
bash scripts/test-run-local-app.sh
bash scripts/test-direct-distribution.sh
git diff --check
```

Expected: all commands exit 0 on the exact commit intended for `origin/main`.

- [ ] **Step 6: Re-fetch immediately before push and enforce ancestry**

```bash
git fetch origin main
git merge-base --is-ancestor origin/main main
```

Expected: exit 0. If not, merge the new `origin/main` into local `main` and repeat Step 5 and this ancestry check.

- [ ] **Step 7: Push the tested main commit**

```bash
git push origin main:main
```

Expected: a non-force fast-forward update. Then verify:

```bash
git fetch origin main
test "$(git rev-parse main)" = "$(git rev-parse origin/main)"
```

- [ ] **Step 8: Clean up only after the push is confirmed**

From the primary repository checkout:

```bash
git worktree remove .worktrees/prepush-safety-fixes
git branch -d codex/prepush-safety-fixes
git status --short --branch
```

Expected: the linked worktree and merged feature branch are removed, and local `main` matches `origin/main`.
