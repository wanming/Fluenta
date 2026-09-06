# Writing Realtime Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the standalone Voice Write Assistant with press-and-hold, realtime OpenAI speech-to-text that edits the confirmed Writing Assistant source draft and falls back once to a session-scoped file transcription.

**Architecture:** `InkletCore` owns only the Foundation-based realtime protocol, OpenAI WebSocket implementation, and pure transcript accumulator. The `Inklet` executable owns the single AVFoundation capture session, AppKit editor transaction, popover-local shortcut monitor, and `WritingDictationCoordinator`; this keeps audio, UI, and lifecycle cleanup close to the active Writing popover without leaking voice behavior into Prompt Modes, insertion, or History.

**Tech Stack:** Swift 6, macOS 14, SwiftUI, AppKit `NSTextView`/`NSUndoManager`, AVFoundation `AVCaptureSession`, Foundation `URLSessionWebSocketTask`, XCTest, existing OpenAI file-transcription provider and Keychain API-key store.

---

## Locked Product And Engineering Decisions

- Dictation is available only after the user confirms a Prompt Mode and the source editor is first responder.
- The only gesture is a fresh press-and-hold of the configured modifier; a short press is a no-op.
- Opening the popover or choosing a mode never requests microphone permission. The first valid hold does.
- Realtime uses fixed `wss://api.openai.com/v1/realtime?model=gpt-live-transcribe`, `gpt-live-transcribe`, mono 24 kHz signed little-endian PCM16, and manual buffer commit with turn detection disabled.
- One microphone capture session simultaneously yields PCM frames and writes one temporary `.m4a` recovery file.
- Provisional transcript replaces one owned UTF-16 `NSRange` and is underlined. Manual editing, caret movement, and selection changes are locked during the transaction.
- Provisional updates preserve any visible old Writing result. Only a successful final transcript invokes the normal source-change invalidation once.
- Release stops sample production, drains conversion/append work, commits exactly once, then waits for the terminal transcript. If realtime has failed, release finalizes the file before one fallback upload.
- A technically successful empty realtime transcript restores the pre-dictation snapshot without file fallback. Realtime technical failure may use fallback once; fallback failure or no speech restores the exact snapshot and selection.
- The first terminal outcome wins. Session UUIDs, item/content filtering, event-ID de-duplication, and transport ownership prevent stale or late callbacks from mutating the editor.
- Escape priority is input-method marked text, then active dictation cancellation, then the existing Writing navigation.
- Popover hide, key-window loss, route change, supersession, migration maintenance, and application termination cancel, restore, close, and delete the temporary file.
- Dictation alone creates no history. `HistorySource.voice` remains solely for legacy history decoding/display; a later Prompt transformation continues to write the existing `.write` history entry.
- The top-level JSON key remains `voiceInput`. Schema v4 encodes only `shortcut`, `speechEndpoint`, `speechModel`, and `microphoneDeviceID`.
- The realtime endpoint/model are not settings. The endpoint/model shown under Advanced Dictation apply only to file recovery.

## File And Responsibility Map

### New Core files

- `Sources/InkletCore/RealtimeTranscriptionTypes.swift` — public realtime event/error/client protocol.
- `Sources/InkletCore/OpenAIRealtimeTranscriptionClient.swift` — request/session JSON, WebSocket transport, serial receive parser, idempotent commit and close.
- `Sources/InkletCore/RealtimeTranscriptAccumulator.swift` — pure active-item filter and cumulative delta/final aggregation.

### New App files

- `Sources/InkletApp/DictationEditorTransaction.swift` — source `NSTextView` registration, owned-range provisional replacement, styling, restoration, focus, and one-step undo.
- `Sources/InkletApp/WritingDictationCoordinator.swift` — session UUID, capture/transport tasks, bounded early audio, release ordering, fallback, first-terminal arbitration, and cancel-and-wait.
- `Sources/InkletApp/WritingDictationShortcutMonitor.swift` — app-local modifier events, fresh-release gate, context eligibility, hold timer, and balanced release/reset.

### Modified files

- `Sources/InkletApp/AudioRecorder.swift` — add PCM data output to the existing single capture session while retaining the finalized `.m4a` recovery file.
- `Sources/InkletCore/VoiceShortcutGestureRecognizer.swift` — remove toggle/double-tap behavior; retain hold start/stop only.
- `Sources/InkletCore/VoiceShortcutModifierPressTracker.swift` — retain physical left/right modifier tracking.
- `Sources/InkletCore/VoiceInputConfig.swift` — reduce encoded/runtime v4 voice value to four live Dictation fields.
- `Sources/InkletCore/ConfigStore.swift` — schema v4 and legacy-key-tolerant decode.
- `Sources/InkletApp/InkletPopoverView.swift` — dictation presentation snapshot, action-bar phase, source-only text-view registration, busy/escape rules, and accessibility labels.
- `Sources/InkletApp/InkletPopoverWindowController.swift` — own/wire dictation services, shortcut context, focus identity, resign/hide/route cleanup, and busy publication.
- `Sources/InkletApp/AppCoordinator.swift` — remove global voice workflow and make termination/maintenance await popover dictation cleanup.
- `Sources/InkletApp/SettingsView.swift` — merge Dictation controls into Write Assistant and remove retired controls.
- `Sources/InkletApp/InkletLocalization.swift` — all ten supported language tables and enum display-name cleanup.
- `README.md`, `README.zh-CN.md`, `SECURITY.md`, `docs/privacy-policy.md`, `docs/manual-test-checklist.md` — shipped workflow, privacy, permissions, recovery, and manual QA.
- `VERSION` — minor version `1.1.0` and build number `6` before the app bundle build.

### Deleted files

- `Sources/InkletCore/VoiceInputCoordinator.swift`
- `Sources/InkletCore/VoiceInputCancellationPolicy.swift`
- `Sources/InkletCore/VoicePromptModeSelectionMenuState.swift`
- `Sources/InkletApp/VoiceShortcutMonitor.swift`
- `Sources/InkletApp/VoiceStatusWindowController.swift`
- Their obsolete coordinator, cancellation, chooser, global-monitor, and HUD tests.

### Test files

- Create `Tests/InkletCoreTests/OpenAIRealtimeTranscriptionClientTests.swift`.
- Create `Tests/InkletCoreTests/RealtimeTranscriptAccumulatorTests.swift`.
- Create `Tests/InkletCoreTests/AudioRecorderTests.swift`.
- Create `Tests/InkletCoreTests/DictationEditorTransactionTests.swift`.
- Create `Tests/InkletCoreTests/WritingDictationCoordinatorTests.swift`.
- Create `Tests/InkletCoreTests/WritingDictationShortcutMonitorTests.swift`.
- Create `Tests/InkletCoreTests/WritingPopoverDictationViewModelTests.swift`.
- Modify configuration, Settings, localization, keyboard, launcher, app-wiring, migration, provider, history, and distribution contract tests named in the tasks below.

## Verification Contract

The implementation is complete only when:

1. Focused red/green commands in every task behave as stated.
2. `swift test` reports zero failures.
3. `swift build -Xswiftc -warnings-as-errors` succeeds.
4. `bash scripts/test-direct-distribution.sh` succeeds.
5. `scripts/run-local-app.sh` builds, installs, and launches `/Applications/Inklet Local.app` after `VERSION` is updated.
6. `git diff --check` is silent and `git status --short` contains only intentional changes.
7. The manual checklist explicitly records any interaction that still requires the user to exercise microphone hardware, VoiceOver, or forced network failure.

### Task 1: Add The Realtime Event Contract And Transcript Accumulator

**Files:**
- Create: `Sources/InkletCore/RealtimeTranscriptionTypes.swift`
- Create: `Sources/InkletCore/RealtimeTranscriptAccumulator.swift`
- Create: `Tests/InkletCoreTests/RealtimeTranscriptAccumulatorTests.swift`

- [ ] **Step 1: Write failing accumulator tests**

Create tests that exercise arrival-order concatenation, active item/content locking, event-ID de-duplication, optional comparable sequence rejection, and authoritative completion:

~~~swift
import XCTest
@testable import InkletCore

final class RealtimeTranscriptAccumulatorTests: XCTestCase {
    func testAccumulatesOneServerItemInArrivalOrder() {
        var subject = RealtimeTranscriptAccumulator()
        XCTAssertEqual(
            subject.accept(.delta(eventID: "1", sequence: 1, itemID: "item", contentIndex: 0, text: "你")),
            .provisional("你")
        )
        XCTAssertEqual(
            subject.accept(.delta(eventID: "2", sequence: 2, itemID: "item", contentIndex: 0, text: "好")),
            .provisional("你好")
        )
    }

    func testIgnoresWrongItemDuplicateAndComparableOutOfOrderEvents() {
        var subject = RealtimeTranscriptAccumulator()
        _ = subject.accept(.delta(eventID: "first", sequence: 4, itemID: "item", contentIndex: 0, text: "A"))

        XCTAssertEqual(
            subject.accept(.delta(eventID: "wrong", sequence: 5, itemID: "other", contentIndex: 0, text: "B")),
            .ignored
        )
        XCTAssertEqual(
            subject.accept(.delta(eventID: "first", sequence: 6, itemID: "item", contentIndex: 0, text: "B")),
            .ignored
        )
        XCTAssertEqual(
            subject.accept(.delta(eventID: "older", sequence: 3, itemID: "item", contentIndex: 0, text: "B")),
            .ignored
        )
    }

    func testMissingSequenceUsesSerialArrivalOrderAndCompletedTranscriptIsAuthoritative() {
        var subject = RealtimeTranscriptAccumulator()
        _ = subject.accept(.delta(eventID: nil, sequence: nil, itemID: "item", contentIndex: 0, text: "draft "))
        _ = subject.accept(.delta(eventID: nil, sequence: nil, itemID: "item", contentIndex: 0, text: "word"))

        XCTAssertEqual(
            subject.accept(.completed(
                eventID: "final",
                sequence: nil,
                itemID: "item",
                contentIndex: 0,
                transcript: "final words"
            )),
            .final("final words")
        )
    }
}
~~~

- [ ] **Step 2: Run the accumulator tests and confirm the red state**

Run: `swift test --filter RealtimeTranscriptAccumulatorTests`

Expected: compilation fails because `RealtimeTranscriptionEvent` and `RealtimeTranscriptAccumulator` do not exist.

- [ ] **Step 3: Add the realtime public contract**

Create `RealtimeTranscriptionTypes.swift` with this complete public surface:

~~~swift
import Foundation

public enum RealtimeTranscriptionEvent: Equatable, Sendable {
    case delta(
        eventID: String?,
        sequence: Int?,
        itemID: String,
        contentIndex: Int,
        text: String
    )
    case completed(
        eventID: String?,
        sequence: Int?,
        itemID: String,
        contentIndex: Int,
        transcript: String
    )
}

public enum RealtimeTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case missingAPIKey
    case connectionTimedOut
    case finalTranscriptTimedOut
    case connectionClosed
    case invalidMessage
    case invalidState
    case server(code: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Realtime transcription endpoint is invalid."
        case .missingAPIKey: "An OpenAI API key is required for dictation."
        case .connectionTimedOut: "Realtime transcription could not connect in time."
        case .finalTranscriptTimedOut: "Realtime transcription did not finish in time."
        case .connectionClosed: "The realtime transcription connection closed."
        case .invalidMessage: "Realtime transcription returned an invalid message."
        case .invalidState: "Realtime transcription received an invalid operation."
        case .server(_, let message): message
        }
    }
}

public protocol RealtimeTranscriptionClient: Sendable {
    func connect(timeoutSeconds: TimeInterval) async throws
    func appendPCM16(_ data: Data) async throws
    func commit() async throws
    func nextEvent() async throws -> RealtimeTranscriptionEvent
    func close() async
}
~~~

- [ ] **Step 4: Implement the pure accumulator**

Create `RealtimeTranscriptAccumulator.swift`. It must never sort event IDs; it compares only an actual integer sequence:

~~~swift
import Foundation

public struct RealtimeTranscriptAccumulator: Equatable, Sendable {
    public enum Update: Equatable, Sendable {
        case ignored
        case provisional(String)
        case final(String)
    }

    private var activeItemID: String?
    private var activeContentIndex: Int?
    private var seenEventIDs = Set<String>()
    private var lastSequence: Int?
    private var provisional = ""
    private var isCompleted = false

    public init() {}

    public mutating func accept(_ event: RealtimeTranscriptionEvent) -> Update {
        guard !isCompleted else { return .ignored }

        let identity: (eventID: String?, sequence: Int?, itemID: String, contentIndex: Int)
        switch event {
        case .delta(let eventID, let sequence, let itemID, let contentIndex, _),
             .completed(let eventID, let sequence, let itemID, let contentIndex, _):
            identity = (eventID, sequence, itemID, contentIndex)
        }

        if activeItemID == nil {
            activeItemID = identity.itemID
            activeContentIndex = identity.contentIndex
        }
        guard activeItemID == identity.itemID, activeContentIndex == identity.contentIndex else {
            return .ignored
        }
        if let eventID = identity.eventID, !seenEventIDs.insert(eventID).inserted {
            return .ignored
        }
        if let sequence = identity.sequence {
            if let lastSequence, sequence <= lastSequence {
                return .ignored
            }
            lastSequence = sequence
        }

        switch event {
        case .delta(_, _, _, _, let text):
            provisional += text
            return .provisional(provisional)
        case .completed(_, _, _, _, let transcript):
            isCompleted = true
            return .final(transcript)
        }
    }
}
~~~

- [ ] **Step 5: Run focused tests and commit**

Run: `swift test --filter RealtimeTranscriptAccumulatorTests`

Expected: all accumulator tests pass.

~~~bash
git add Sources/InkletCore/RealtimeTranscriptionTypes.swift \
  Sources/InkletCore/RealtimeTranscriptAccumulator.swift \
  Tests/InkletCoreTests/RealtimeTranscriptAccumulatorTests.swift
git commit -m "Add realtime transcript accumulation"
~~~

### Task 2: Implement The OpenAI Realtime WebSocket Client

**Files:**
- Create: `Sources/InkletCore/OpenAIRealtimeTranscriptionClient.swift`
- Create: `Tests/InkletCoreTests/OpenAIRealtimeTranscriptionClientTests.swift`

- [ ] **Step 1: Write failing transport, request, and parser tests**

Use an actor fake transport that records request headers/messages and dequeues server JSON. Cover:

~~~swift
func testConnectUsesFixedModelAndSendsTranscriptionSession() async throws {
    let transport = FakeRealtimeWebSocketTransport(receivedTexts: [
        #"{"type":"session.created"}"#,
        #"{"type":"session.updated"}"#
    ])
    let subject = OpenAIRealtimeTranscriptionClient(
        apiKeyProvider: { "secret" },
        transport: transport
    )

    try await subject.connect(timeoutSeconds: 1)

    let request = try XCTUnwrap(await transport.request)
    XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-live-transcribe")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    let sentTexts = await transport.sentTexts
    let session = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(try XCTUnwrap(sentTexts.first).utf8))
            as? [String: Any]
    )
    XCTAssertEqual(session["type"] as? String, "session.update")
    XCTAssertEqual(session.value(at: ["session", "type"]) as? String, "transcription")
    XCTAssertEqual(session.value(at: ["session", "audio", "input", "format", "type"]) as? String, "audio/pcm")
    XCTAssertEqual(session.value(at: ["session", "audio", "input", "format", "rate"]) as? Int, 24_000)
    XCTAssertEqual(session.value(at: ["session", "audio", "input", "transcription", "model"]) as? String, "gpt-live-transcribe")
    XCTAssertTrue(session.containsNull(at: ["session", "audio", "input", "turn_detection"]))
}

func testAppendCommitAndCommitIdempotence() async throws {
    let transport = FakeRealtimeWebSocketTransport(receivedTexts: [#"{"type":"session.updated"}"#])
    let subject = OpenAIRealtimeTranscriptionClient(apiKeyProvider: { "key" }, transport: transport)
    try await subject.connect(timeoutSeconds: 1)

    try await subject.appendPCM16(Data([0x01, 0x02]))
    try await subject.commit()
    try await subject.commit()

    let sentTexts = await transport.sentTexts
    let messages = try sentTexts.map { text in
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }
    XCTAssertEqual(messages.filter { $0["type"] as? String == "input_audio_buffer.append" }.count, 1)
    XCTAssertEqual(messages.filter { $0["type"] as? String == "input_audio_buffer.commit" }.count, 1)
}

func testParsesDeltaCompletedAndServerError() async throws {
    let delta = #"{"type":"conversation.item.input_audio_transcription.delta","event_id":"e1","item_id":"i1","content_index":0,"delta":"hello "}"#
    let completed = #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"e2","item_id":"i1","content_index":0,"transcript":"hello world"}"#
    XCTAssertEqual(
        try OpenAIRealtimeTranscriptionClient.parseEvent(Data(delta.utf8)),
        .delta(eventID: "e1", sequence: nil, itemID: "i1", contentIndex: 0, text: "hello ")
    )
    XCTAssertEqual(
        try OpenAIRealtimeTranscriptionClient.parseEvent(Data(completed.utf8)),
        .completed(eventID: "e2", sequence: nil, itemID: "i1", contentIndex: 0, transcript: "hello world")
    )
}
~~~

Put this complete test support directly in `OpenAIRealtimeTranscriptionClientTests.swift`:

~~~swift
private enum FakeTransportError: Error, Sendable {
    case closed
}

private actor FakeRealtimeWebSocketTransport: RealtimeWebSocketTransport {
    private(set) var request: URLRequest?
    private(set) var sentTexts: [String] = []
    private(set) var closeCount = 0
    private var receivedTexts: [String]
    private var receiveWaiters: [CheckedContinuation<String, Error>] = []

    init(receivedTexts: [String] = []) {
        self.receivedTexts = receivedTexts
    }

    func connect(_ request: URLRequest) async throws {
        self.request = request
    }

    func send(text: String) async throws {
        sentTexts.append(text)
    }

    func receiveText() async throws -> String {
        if !receivedTexts.isEmpty {
            return receivedTexts.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func enqueue(_ text: String) {
        if receiveWaiters.isEmpty {
            receivedTexts.append(text)
        } else {
            receiveWaiters.removeFirst().resume(returning: text)
        }
    }

    func close() async {
        closeCount += 1
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: FakeTransportError.closed) }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func value(at path: [String]) -> Any? {
        var current: Any = self
        for component in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[component]
            else { return nil }
            current = next
        }
        return current
    }

    func containsNull(at path: [String]) -> Bool {
        value(at: path) is NSNull
    }
}
~~~

Also assert missing/blank API keys fail before transport connection, `error` messages map to `.server`, append-after-commit returns `.invalidState`, timeout cancels transport, explicit close is idempotent, and irrelevant server events are skipped by `nextEvent()`.

- [ ] **Step 2: Run the realtime client tests and confirm the red state**

Run: `swift test --filter OpenAIRealtimeTranscriptionClientTests`

Expected: compilation fails because `OpenAIRealtimeTranscriptionClient` and the injectable transport do not exist.

- [ ] **Step 3: Implement the injectable WebSocket transport**

In `OpenAIRealtimeTranscriptionClient.swift` define an internal protocol and production actor:

~~~swift
import Foundation

protocol RealtimeWebSocketTransport: Sendable {
    func connect(_ request: URLRequest) async throws
    func send(text: String) async throws
    func receiveText() async throws -> String
    func close() async
}

actor URLSessionRealtimeWebSocketTransport: RealtimeWebSocketTransport {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(session: URLSession) {
        self.session = session
    }

    func connect(_ request: URLRequest) async throws {
        guard task == nil else { throw RealtimeTranscriptionError.invalidState }
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(text: String) async throws {
        guard let task else { throw RealtimeTranscriptionError.invalidState }
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        guard let task else { throw RealtimeTranscriptionError.invalidState }
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw RealtimeTranscriptionError.invalidMessage
            }
            return text
        @unknown default:
            throw RealtimeTranscriptionError.invalidMessage
        }
    }

    func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}
~~~

- [ ] **Step 4: Implement the client actor and exact wire messages**

Implement `public actor OpenAIRealtimeTranscriptionClient: RealtimeTranscriptionClient` with:

~~~swift
public actor OpenAIRealtimeTranscriptionClient: RealtimeTranscriptionClient {
    public static let model = "gpt-live-transcribe"
    public static let defaultEndpoint = URL(
        string: "wss://api.openai.com/v1/realtime?model=gpt-live-transcribe"
    )!

    private let apiKeyProvider: @Sendable () throws -> String
    private let endpoint: URL
    private let transport: any RealtimeWebSocketTransport
    private var isReady = false
    private var didCommit = false
    private var isClosed = false

    public init(
        apiKeyProvider: @escaping @Sendable () throws -> String,
        endpoint: URL = Self.defaultEndpoint,
        session: URLSession = .shared
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.endpoint = endpoint
        self.transport = URLSessionRealtimeWebSocketTransport(session: session)
    }

    init(
        apiKeyProvider: @escaping @Sendable () throws -> String,
        endpoint: URL = Self.defaultEndpoint,
        transport: any RealtimeWebSocketTransport
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.endpoint = endpoint
        self.transport = transport
    }
}
~~~

`connect(timeoutSeconds:)` trims the key, rejects an empty value, builds an Authorization request, connects under a task-group timeout, sends this exact object, and waits serially for `session.updated` while mapping a server `error` immediately:

~~~json
{
  "type": "session.update",
  "session": {
    "type": "transcription",
    "audio": {
      "input": {
        "format": { "type": "audio/pcm", "rate": 24000 },
        "transcription": { "model": "gpt-live-transcribe" },
        "turn_detection": null
      }
    }
  }
}
~~~

`appendPCM16` rejects empty frames and any call before ready or after commit, then sends:

~~~json
{"type":"input_audio_buffer.append","audio":"AQI="}
~~~

`commit` is idempotent and sends `{"type":"input_audio_buffer.commit"}` once. `nextEvent` loops on one actor-isolated receive path, skips session/buffer bookkeeping events, returns only delta/completed, and maps `error.error.code/message`. `parseEvent(_:)` uses a small `Decodable` envelope with optional `event_id`, `sequence`, `item_id`, `content_index`, `delta`, `transcript`, and nested error.

- [ ] **Step 5: Run focused tests and commit**

Run: `swift test --filter OpenAIRealtimeTranscriptionClientTests`

Expected: all client tests pass without accessing the network.

~~~bash
git add Sources/InkletCore/OpenAIRealtimeTranscriptionClient.swift \
  Tests/InkletCoreTests/OpenAIRealtimeTranscriptionClientTests.swift
git commit -m "Add OpenAI realtime transcription client"
~~~

### Task 3: Extend One Audio Capture Session For Realtime PCM And Recovery

**Files:**
- Modify: `Sources/InkletApp/AudioRecorder.swift`
- Create: `Tests/InkletCoreTests/AudioRecorderTests.swift`

- [ ] **Step 1: Write failing audio settings and stream-drain tests**

Expose only internal deterministic seams and test them with `@testable import Inklet`:

~~~swift
import AVFoundation
import XCTest
@testable import Inklet

final class AudioRecorderTests: XCTestCase {
    func testRealtimeAudioSettingsAreMono24kSignedLittleEndianPCM16() {
        let settings = AudioRecorder.realtimeAudioSettings
        XCTAssertEqual(settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(settings[AVSampleRateKey] as? Int, 24_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsNonInterleaved] as? Bool, false)
    }

    func testSampleDelegateYieldsBytesInCallbackOrderAndFinishesAfterDrain() async throws {
        let delegate = RealtimeAudioSampleDelegate(bufferLimit: 4)
        let stream = delegate.makeStream()
        delegate.yieldForTesting(Data([1, 2]))
        delegate.yieldForTesting(Data([3, 4]))
        delegate.finishAfterDraining()

        var values: [Data] = []
        for try await value in stream { values.append(value) }
        XCTAssertEqual(values, [Data([1, 2]), Data([3, 4])])
    }
}
~~~

Add a dropped-buffer test that expects `AudioRecorderError.realtimeBufferOverflow` and a cancellation test that terminates the stream exactly once.

- [ ] **Step 2: Run focused audio tests and confirm the red state**

Run: `swift test --filter AudioRecorderTests`

Expected: compilation fails because realtime settings, the sample delegate, and the stream-returning start contract do not exist.

- [ ] **Step 3: Add the capture protocol and realtime settings**

At the top of `AudioRecorder.swift` add:

~~~swift
@MainActor
protocol DictationAudioCapturing: AnyObject {
    func startStreaming(microphoneDeviceID: String?) async throws -> AsyncThrowingStream<Data, Error>
    func stop() async throws -> URL
    func cancel() async
}
~~~

Make `AudioRecorder` conform and add:

~~~swift
static let realtimeAudioSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 24_000,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false
]
~~~

Add `case realtimeBufferOverflow` to `AudioRecorderError` and localize it in Task 10.

- [ ] **Step 4: Add one data output to the existing capture session**

During `start` configuration create `AVCaptureAudioDataOutput`, assign `realtimeAudioSettings`, and add it alongside the existing `AVCaptureAudioFileOutput`:

~~~swift
let dataOutput = AVCaptureAudioDataOutput()
dataOutput.audioSettings = Self.realtimeAudioSettings
guard captureSession.canAddInput(input),
      captureSession.canAddOutput(fileOutput),
      captureSession.canAddOutput(dataOutput)
else {
    throw AudioRecorderError.recordingUnavailable
}

let sampleDelegate = RealtimeAudioSampleDelegate(bufferLimit: 96)
dataOutput.setSampleBufferDelegate(sampleDelegate, queue: sampleDelegate.queue)
captureSession.beginConfiguration()
captureSession.addInput(input)
captureSession.addOutput(fileOutput)
captureSession.addOutput(dataOutput)
captureSession.commitConfiguration()
~~~

Store `dataOutput` and `sampleDelegate`. `startStreaming` returns `sampleDelegate.makeStream()` only after file recording reports started. `RealtimeAudioSampleDelegate` copies bytes with `CMSampleBufferGetDataBuffer` and `CMBlockBufferCopyDataBytes`. On `AsyncThrowingStream.Continuation.YieldResult.dropped`, finish the stream with `.realtimeBufferOverflow`; never continue while silently discarding PCM.

Until Task 8 deletes the standalone caller, keep its compile-only wrapper:

~~~swift
func start(microphoneDeviceID: String?) async throws {
    _ = try await startStreaming(microphoneDeviceID: microphoneDeviceID)
}
~~~

Task 8 removes this wrapper with the old caller, leaving only `startStreaming` in the final app.

At the beginning of `stop()` detach the sample delegate so no new samples are produced, ask its serial queue to finish after already-enqueued callbacks, then stop/finalize file output. Return the file URL only after both sample drain and `AudioRecordingDelegate.waitUntilFinished()` complete. `cancel()` follows the same detach/drain order, closes the stream, stops the capture session, and removes the file.

- [ ] **Step 5: Preserve device and permission behavior**

Keep the current `requestMicrophoneAccess()` and `audioDevice(matching:)` logic unchanged. Verify no caller invokes `start` until the valid-hold boundary; the capture layer itself remains the single point that asks the system for access.

- [ ] **Step 6: Run focused tests and commit**

Run: `swift test --filter AudioRecorderTests`

Expected: deterministic settings/stream tests pass. A real microphone is not opened by the test suite.

~~~bash
git add Sources/InkletApp/AudioRecorder.swift \
  Tests/InkletCoreTests/AudioRecorderTests.swift
git commit -m "Stream realtime PCM from voice capture"
~~~

### Task 4: Build The AppKit Source Editor Transaction

**Files:**
- Create: `Sources/InkletApp/DictationEditorTransaction.swift`
- Create: `Tests/InkletCoreTests/DictationEditorTransactionTests.swift`

- [ ] **Step 1: Write failing AppKit transaction tests**

Use a real `NSTextView` and `NSUndoManager` on `@MainActor`:

~~~swift
@MainActor
final class DictationEditorTransactionTests: XCTestCase {
    func testRepeatedPartialsReplaceOwnedSelectionWithoutDuplication() throws {
        let textView = makeTextView("Hello old world", selection: NSRange(location: 6, length: 3))
        var synchronized: [String] = []
        let subject = try XCTUnwrap(DictationEditorTransaction(
            textView: textView,
            synchronizeProvisional: { synchronized.append($0) },
            commitSourceChange: { _ in },
            restoreModelSnapshot: {}
        ))

        try subject.replaceProvisional(with: "new")
        try subject.replaceProvisional(with: "new words")

        XCTAssertEqual(textView.string, "Hello new words world")
        XCTAssertEqual(synchronized.last, textView.string)
        XCTAssertFalse(textView.isEditable)
    }

    func testUTF16OwnedRangeHandlesChineseEmojiAndCombiningMarks() throws {
        let original = "甲👩‍💻e\u{301}乙"
        let range = (original as NSString).range(of: "👩‍💻e\u{301}")
        let textView = makeTextView(original, selection: range)
        let subject = try XCTUnwrap(makeTransaction(textView))
        try subject.replaceProvisional(with: "听写")
        XCTAssertEqual(textView.string, "甲听写乙")
    }

    func testRestoreReturnsExactTextSelectionAndUndoStack() throws {
        let original = "before"
        let selection = NSRange(location: 2, length: 3)
        let textView = makeTextView(original, selection: selection)
        let subject = try XCTUnwrap(makeTransaction(textView))
        try subject.replaceProvisional(with: "draft")
        subject.restore()
        XCTAssertEqual(textView.string, original)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertFalse(textView.undoManager?.canUndo ?? true)
        XCTAssertTrue(textView.isEditable)
    }

    func testFinalCommitCreatesOneUndoableEdit() throws {
        let textView = makeTextView("abc", selection: NSRange(location: 1, length: 1))
        let subject = try XCTUnwrap(makeTransaction(textView))
        try subject.replaceProvisional(with: "draft")
        try subject.commitFinal("voice")
        XCTAssertEqual(textView.string, "avoicec")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "abc")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 1))
        XCTAssertFalse(textView.undoManager?.canUndo ?? true)
    }
}
~~~

Add these helpers inside `DictationEditorTransactionTests` so the examples are self-contained:

~~~swift
private func makeTextView(_ string: String, selection: NSRange) -> NSTextView {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    textView.allowsUndo = true
    textView.string = string
    textView.setSelectedRange(selection)
    return textView
}

private func makeTransaction(_ textView: NSTextView) -> DictationEditorTransaction? {
    DictationEditorTransaction(
        textView: textView,
        synchronizeProvisional: { _ in },
        commitSourceChange: { _ in },
        restoreModelSnapshot: {}
    )
}
~~~

Also test empty-caret insertion, temporary underline presence/removal, caret at final end, source focus restoration, weak target invalidation, and that restore is idempotent.

- [ ] **Step 2: Run transaction tests and confirm the red state**

Run: `swift test --filter DictationEditorTransactionTests`

Expected: compilation fails because `DictationEditorTransaction` does not exist.

- [ ] **Step 3: Implement the transaction contract and snapshot**

Create:

~~~swift
import AppKit

@MainActor
protocol DictationEditorTransacting: AnyObject {
    func replaceProvisional(with cumulativeText: String) throws
    func commitFinal(_ text: String) throws
    func restore()
}

@MainActor
final class DictationEditorTransaction: DictationEditorTransacting {
    struct Snapshot: Equatable {
        let string: String
        let selectedRange: NSRange
    }

    private weak var textView: NSTextView?
    private let original: Snapshot
    private var ownedRange: NSRange
    private let originalIsEditable: Bool
    private let originalIsSelectable: Bool
    private let synchronizeProvisional: (String) -> Void
    private let commitSourceChange: (String) -> Void
    private let restoreModelSnapshot: () -> Void
    private var terminal = false

    init?(
        textView: NSTextView,
        synchronizeProvisional: @escaping (String) -> Void,
        commitSourceChange: @escaping (String) -> Void,
        restoreModelSnapshot: @escaping () -> Void
    ) {
        let selection = textView.selectedRange()
        guard NSMaxRange(selection) <= (textView.string as NSString).length else { return nil }
        self.textView = textView
        self.original = Snapshot(string: textView.string, selectedRange: selection)
        self.ownedRange = selection
        self.originalIsEditable = textView.isEditable
        self.originalIsSelectable = textView.isSelectable
        self.synchronizeProvisional = synchronizeProvisional
        self.commitSourceChange = commitSourceChange
        self.restoreModelSnapshot = restoreModelSnapshot
        textView.isEditable = false
        textView.isSelectable = false
    }
}
~~~

- [ ] **Step 4: Implement targeted replacement, styling, restore, and undo**

`replaceProvisional` removes old temporary attributes, replaces `ownedRange` under disabled undo registration, updates `ownedRange.length = (text as NSString).length`, adds a single underline temporary attribute to the new range, keeps selection at the range end, and calls `synchronizeProvisional(textView.string)`. It never invokes `commitSourceChange`.

`commitFinal` performs the same targeted replacement with the server/fallback final string, removes temporary attributes, restores editability/selectability/focus, registers exactly one undo closure that swaps between the original and committed `Snapshot` values, and calls `commitSourceChange(textView.string)` once. The undo/redo helper updates the text storage under disabled automatic registration, registers the inverse operation, restores selection, and synchronizes the source model.

`restore` removes temporary attributes, restores `original.string` and `original.selectedRange` under disabled undo registration, restores editability/selectability/focus, invokes `synchronizeProvisional(original.string)` and `restoreModelSnapshot()`, and becomes idempotent. An invalidated weak text view still invokes the model restore callback and terminates safely.

- [ ] **Step 5: Run focused tests and commit**

Run: `swift test --filter DictationEditorTransactionTests`

Expected: all range, style, focus, restoration, and undo tests pass.

~~~bash
git add Sources/InkletApp/DictationEditorTransaction.swift \
  Tests/InkletCoreTests/DictationEditorTransactionTests.swift
git commit -m "Add transactional editor dictation"
~~~

### Task 5: Implement The Dictation Session Coordinator And Race Semantics

**Files:**
- Create: `Sources/InkletApp/WritingDictationCoordinator.swift`
- Create: `Tests/InkletCoreTests/WritingDictationCoordinatorTests.swift`
- Modify: `Tests/InkletCoreTests/OpenAISpeechTranscriptionProviderTests.swift`

- [ ] **Step 1: Build a deterministic coordinator harness and write the first failing state test**

The harness uses fake `DictationAudioCapturing`, `RealtimeTranscriptionClient`, `DictationEditorTransacting`, and manually resumed continuations. The first test must prove that only a valid begin reaches permission/capture:

~~~swift
@MainActor
final class WritingDictationCoordinatorTests: XCTestCase {
    func testBeginHoldCreatesTransactionStartsCaptureAndPublishesListeningAfterConnection() async {
        let harness = DictationHarness()
        await harness.subject.beginHold()
        XCTAssertEqual(harness.transactionBeginCount, 1)
        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertEqual(harness.phases.first, .connecting)

        await harness.client.completeConnection()
        await harness.drainTasks()

        XCTAssertEqual(harness.subject.phase, .listening)
        XCTAssertTrue(harness.subject.isActive)
    }

    func testInvalidPreflightDoesNotRequestMicrophoneOrCreateTransaction() async {
        let harness = DictationHarness(clientFactoryError: RealtimeTranscriptionError.missingAPIKey)
        await harness.subject.beginHold()
        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertEqual(harness.transactionBeginCount, 0)
        XCTAssertEqual(harness.subject.phase, .failed("dictation.error.missingAPIKey"))
    }
}
~~~

The production client factory reads and trims the canonical OpenAI Keychain item before it returns a client. This keeps API-key validation before `AudioRecorder.start` and therefore before the permission request.

Use these concrete fakes in the same test file; add only the additional connection/append/fallback gates required by later named tests:

~~~swift
@MainActor
private final class FakeDictationTransaction: DictationEditorTransacting {
    private(set) var provisional: [String] = []
    private(set) var committed: [String] = []
    private(set) var restoreCount = 0

    func replaceProvisional(with cumulativeText: String) throws {
        provisional.append(cumulativeText)
    }

    func commitFinal(_ text: String) throws {
        committed.append(text)
    }

    func restore() {
        restoreCount += 1
    }
}

@MainActor
private final class FakeDictationCapture: DictationAudioCapturing {
    let recordingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationHarness-\(UUID().uuidString).m4a")
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var createdURLs: [URL] = []
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var startError: Error?
    var stopError: Error?

    func startStreaming(microphoneDeviceID: String?) async throws -> AsyncThrowingStream<Data, Error> {
        startCount += 1
        if let startError { throw startError }
        createdURLs = [recordingURL]
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        let stream = AsyncThrowingStream<Data, Error> { captured = $0 }
        continuation = captured
        return stream
    }

    func stop() async throws -> URL {
        stopCount += 1
        continuation?.finish()
        continuation = nil
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let stopError { throw stopError }
        try Data([1]).write(to: recordingURL)
        return recordingURL
    }

    func cancel() async {
        cancelCount += 1
        continuation?.finish()
        continuation = nil
    }

    func yield(_ data: Data) {
        continuation?.yield(data)
    }

    func waitUntilStopWasCalled() async {
        if stopCount > 0 { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }
}

@MainActor
private final class FakeRealtimeClient: RealtimeTranscriptionClient, @unchecked Sendable {
    private(set) var operations: [String] = []
    private(set) var commitCount = 0
    private(set) var closeCount = 0
    private(set) var appendedAfterCommit = false
    var didCommit: Bool { commitCount > 0 }

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var pendingConnectionResult: Result<Void, Error>?
    private var eventQueue: [Result<RealtimeTranscriptionEvent, Error>] = []
    private var eventWaiters: [CheckedContinuation<RealtimeTranscriptionEvent, Error>] = []
    private var blockedAppendContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextAppend = false
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []

    func connect(timeoutSeconds: TimeInterval) async throws {
        if let pendingConnectionResult {
            self.pendingConnectionResult = nil
            return try pendingConnectionResult.get()
        }
        try await withCheckedThrowingContinuation { connectContinuation = $0 }
    }

    func completeConnection() {
        if let connectContinuation {
            self.connectContinuation = nil
            connectContinuation.resume()
        } else {
            pendingConnectionResult = .success(())
        }
    }

    func failConnection(with error: Error) {
        if let connectContinuation {
            self.connectContinuation = nil
            connectContinuation.resume(throwing: error)
        } else {
            pendingConnectionResult = .failure(error)
        }
    }

    func appendPCM16(_ data: Data) async throws {
        if didCommit { appendedAfterCommit = true }
        if shouldBlockNextAppend {
            shouldBlockNextAppend = false
            await withCheckedContinuation { blockedAppendContinuation = $0 }
        }
        operations.append("append:\(data.count)")
    }

    func blockNextAppend() {
        shouldBlockNextAppend = true
    }

    func resumeAppend() {
        blockedAppendContinuation?.resume()
        blockedAppendContinuation = nil
    }

    func commit() async throws {
        commitCount += 1
        operations.append("commit")
        let waiters = commitWaiters
        commitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilCommitted() async {
        if didCommit { return }
        await withCheckedContinuation { commitWaiters.append($0) }
    }

    func nextEvent() async throws -> RealtimeTranscriptionEvent {
        if !eventQueue.isEmpty { return try eventQueue.removeFirst().get() }
        return try await withCheckedThrowingContinuation { eventWaiters.append($0) }
    }

    func send(_ event: RealtimeTranscriptionEvent) {
        enqueue(.success(event))
    }

    func failReceive(with error: Error) {
        enqueue(.failure(error))
    }

    private func enqueue(_ result: Result<RealtimeTranscriptionEvent, Error>) {
        if eventWaiters.isEmpty {
            eventQueue.append(result)
        } else {
            eventWaiters.removeFirst().resume(with: result)
        }
    }

    func close() async {
        closeCount += 1
        let waiters = eventWaiters
        eventWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: RealtimeTranscriptionError.connectionClosed) }
    }
}

@MainActor
private final class DictationHarness {
    let capture = FakeDictationCapture()
    let client = FakeRealtimeClient()
    let transaction = FakeDictationTransaction()
    private(set) var transactionBeginCount = 0
    private(set) var fallbackRequests: [URL] = []
    private(set) var deletedURLs: [URL] = []
    private(set) var phases: [WritingDictationCoordinator.Phase] = []
    private let clientFactoryError: Error?
    private let fallbackText: String
    private let fallbackError: Error?

    lazy var subject = WritingDictationCoordinator(
        configProvider: {
            VoiceInputConfig(
                shortcut: .rightOption,
                speechEndpoint: VoiceInputConfig.defaultSpeechEndpoint,
                speechModel: VoiceInputConfig.defaultSpeechModel,
                microphoneDeviceID: nil
            )
        },
        audioCapture: capture,
        makeRealtimeClient: { [unowned self] in
            if let clientFactoryError { throw clientFactoryError }
            return client
        },
        beginTransaction: { [unowned self] in
            transactionBeginCount += 1
            return transaction
        },
        transcribeFallback: { [unowned self] url, _ in
            fallbackRequests.append(url)
            if let fallbackError { throw fallbackError }
            return fallbackText
        },
        deleteTemporaryFile: { [unowned self] url in
            deletedURLs.append(url)
            try? FileManager.default.removeItem(at: url)
        },
        phaseHandler: { [unowned self] in phases.append($0) },
        errorKey: { error in
            if error as? RealtimeTranscriptionError == .missingAPIKey {
                "dictation.error.missingAPIKey"
            } else if error as? SpeechTranscriptionError == .emptyResponse {
                "dictation.error.noSpeech"
            } else {
                "dictation.error.fallback"
            }
        }
    )

    init(
        clientFactoryError: Error? = nil,
        fallbackText: String = "fallback",
        fallbackError: Error? = nil
    ) {
        self.clientFactoryError = clientFactoryError
        self.fallbackText = fallbackText
        self.fallbackError = fallbackError
    }

    func startListening() async {
        await subject.beginHold()
        client.completeConnection()
        await drainTasks()
    }

    func drainTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
~~~

- [ ] **Step 2: Run the first coordinator tests and confirm the red state**

Run: `swift test --filter WritingDictationCoordinatorTests`

Expected: compilation fails because `WritingDictationCoordinator` does not exist.

- [ ] **Step 3: Define the coordinator surface and injected dependencies**

Create `WritingDictationCoordinator.swift` with:

~~~swift
import Foundation
import InkletCore

@MainActor
final class WritingDictationCoordinator {
    enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case listening
        case recordingForFallback
        case finalizing
        case recovering
        case complete
        case failed(String)

        var isActive: Bool {
            switch self {
            case .connecting, .listening, .recordingForFallback, .finalizing, .recovering:
                true
            case .idle, .complete, .failed:
                false
            }
        }
    }

    typealias ConfigProvider = @MainActor () -> VoiceInputConfig
    typealias ClientFactory = @MainActor () throws -> any RealtimeTranscriptionClient
    typealias BeginTransaction = @MainActor () -> (any DictationEditorTransacting)?
    typealias FallbackTranscriber = @MainActor (URL, VoiceInputConfig) async throws -> String
    typealias DeleteTemporaryFile = @MainActor (URL) -> Void
    typealias PhaseHandler = @MainActor (Phase) -> Void
    typealias ErrorKey = @MainActor (Error) -> String

    private struct Session {
        let id: UUID
        let config: VoiceInputConfig
        let transaction: any DictationEditorTransacting
        let client: any RealtimeTranscriptionClient
        var accumulator = RealtimeTranscriptAccumulator()
        var earlyAudio = Data()
        var captureStarted = false
        var connectionReady = false
        var realtimeAvailable = true
        var releaseRequested = false
        var fallbackAttempted = false
        var terminalWon = false
        var recordingURL: URL?
        var frameTask: Task<Void, Never>?
        var connectTask: Task<Void, Never>?
        var receiveTask: Task<Void, Never>?
        var finalizeTask: Task<Void, Never>?
    }

    private static let earlyAudioLimitBytes = 240_000
    private static let connectionTimeoutSeconds: TimeInterval = 5
    private static let finalTimeoutSeconds: TimeInterval = 15

    private let configProvider: ConfigProvider
    private let audioCapture: any DictationAudioCapturing
    private let makeRealtimeClient: ClientFactory
    private let beginTransaction: BeginTransaction
    private let transcribeFallback: FallbackTranscriber
    private let deleteTemporaryFile: DeleteTemporaryFile
    private let phaseHandler: PhaseHandler
    private let errorKey: ErrorKey
    private var session: Session?
    private(set) var phase: Phase = .idle
    private var activeOperationCount = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var isActive: Bool { phase.isActive }
    var isIdle: Bool { !phase.isActive && activeOperationCount == 0 }
}
~~~

Provide an initializer with defaults:

~~~swift
init(
    configProvider: @escaping ConfigProvider,
    audioCapture: any DictationAudioCapturing,
    makeRealtimeClient: @escaping ClientFactory,
    beginTransaction: @escaping BeginTransaction,
    transcribeFallback: @escaping FallbackTranscriber,
    deleteTemporaryFile: @escaping DeleteTemporaryFile = {
        try? FileManager.default.removeItem(at: $0)
    },
    phaseHandler: @escaping PhaseHandler,
    errorKey: @escaping ErrorKey = WritingDictationCoordinator.defaultErrorKey
)
~~~

`defaultErrorKey` maps known realtime, speech, and audio errors to stable localization keys. It must not include authorization headers, audio bytes, transcript text, microphone IDs, or temporary paths.

- [ ] **Step 4: Implement begin, capture, bounded early audio, and serial receive**

`beginHold()` performs this exact order:

1. Accept only `idle`, `complete`, or `failed` with no active operation.
2. Call `makeRealtimeClient()` so a missing API key fails before editor/capture work.
3. Call `beginTransaction()` and fail without capture if the source editor is no longer eligible.
4. Freeze `configProvider()` and create a UUID-backed `Session`.
5. Publish `.connecting`.
6. Await `audioCapture.startStreaming(microphoneDeviceID:)`. Because the await is reentrant, re-check the UUID and `releaseRequested` before installing tasks.
7. If release/context cancellation happened during permission, cancel capture, restore the transaction, close the client, and return to `idle` without a stale error.
8. Start one frame-consumer task and one connection task.

While connecting, the frame task appends to `earlyAudio` until 240,000 bytes. Reaching the bound calls `loseRealtime(id:)`, closes the client, clears the queue, publishes `.recordingForFallback` while the modifier is still held, and continues draining/discarding stream elements because the `.m4a` output remains authoritative for fallback. It never drops frames while presenting realtime listening.

After `connect(timeoutSeconds: 5)` succeeds, `handleConnected(id:)` flushes `earlyAudio` in its original byte order through `appendPCM16`, clears it, sets `connectionReady`, publishes `.listening` unless release was already requested, and starts one receive loop. Every await is followed by a UUID/`realtimeAvailable` check.

The receive loop calls `nextEvent()` serially. `RealtimeTranscriptAccumulator.accept` produces cumulative provisional text or one authoritative final; only provisional updates invoke `transaction.replaceProvisional`. A wrong/stale item or duplicate produces no editor callback.

- [ ] **Step 5: Add release-order tests before release implementation**

Add tests with a gated stream/client:

~~~swift
func testReleaseStopsSamplesDrainsAppendQueueThenCommitsExactlyOnce() async {
    let harness = DictationHarness()
    await harness.startListening()
    harness.capture.yield(Data([1]))
    harness.client.blockNextAppend()

    let release = Task { await harness.subject.endHold() }
    await harness.capture.waitUntilStopWasCalled()
    XCTAssertFalse(harness.client.didCommit)

    harness.client.resumeAppend()
    await harness.client.waitUntilCommitted()
    harness.client.send(.completed(
        eventID: "final", sequence: nil, itemID: "item", contentIndex: 0, transcript: "done"
    ))
    await release.value
    XCTAssertEqual(harness.client.operations, ["append:1", "commit"])
    XCTAssertEqual(harness.client.commitCount, 1)
    XCTAssertFalse(harness.client.appendedAfterCommit)
}

func testReleaseDuringConnectionWaitsOnlyForRemainingConnectionTimeoutThenFallsBack() async {
    let harness = DictationHarness()
    await harness.subject.beginHold()
    let release = Task { await harness.subject.endHold() }
    XCTAssertEqual(harness.subject.phase, .finalizing)

    await harness.client.failConnection(with: .connectionTimedOut)
    await release.value
    await harness.drainTasks()

    XCTAssertEqual(harness.fallbackRequests.count, 1)
    XCTAssertEqual(harness.subject.phase, .recovering)
}
~~~

Run: `swift test --filter WritingDictationCoordinatorTests`

Expected: the new release tests fail because `endHold()` and ordered finalization are not implemented.

- [ ] **Step 6: Implement release and final transcript timeout**

`endHold()` ignores terminal/duplicate releases. During permission/connection it sets `releaseRequested = true` and publishes `.finalizing`; it never requires the modifier to remain held for the network.

For a started capture, create exactly one `finalizeTask` that:

1. Calls `audioCapture.stop()`. The capture method stops new sample production before its first suspension and returns only after its sample stream and file output drain.
2. Stores the finalized file URL.
3. Awaits `frameTask.value` so all append calls finish.
4. If realtime is still available, calls `client.commit()` once and waits for an accepted completed event under a 15-second timeout.
5. If realtime became unavailable at any point, invokes `attemptFallback(id:)` only after the finalized file URL exists.

If an append or commit fails, `loseRealtime` gives terminal ownership to fallback. Late WebSocket events are ignored as soon as `realtimeAvailable` becomes false.

- [ ] **Step 7: Add fallback, no-speech, terminal race, and cleanup tests**

Add explicit tests for all branches:

~~~swift
func testRealtimeFailureWhileHeldRecordsUntilReleaseThenFallsBackOnce() async {
    let harness = DictationHarness(fallbackText: "fallback final")
    await harness.startListening()
    await harness.client.failReceive(with: .connectionClosed)
    await harness.drainTasks()
    XCTAssertEqual(harness.subject.phase, .recordingForFallback)
    XCTAssertEqual(harness.fallbackRequests.count, 0)

    await harness.subject.endHold()
    await harness.drainTasks()
    XCTAssertEqual(harness.transaction.committed, ["fallback final"])
    XCTAssertEqual(harness.fallbackRequests.count, 1)
    XCTAssertEqual(harness.deletedURLs, [harness.capture.recordingURL])
}

func testSuccessfulEmptyRealtimeCompletionRestoresWithoutFallback() async {
    let harness = DictationHarness()
    await harness.startListening()
    let release = Task { await harness.subject.endHold() }
    await harness.client.waitUntilCommitted()
    await harness.client.send(.completed(
        eventID: "final", sequence: nil, itemID: "item", contentIndex: 0, transcript: "   "
    ))
    await release.value
    await harness.drainTasks()
    XCTAssertEqual(harness.transaction.restoreCount, 1)
    XCTAssertTrue(harness.fallbackRequests.isEmpty)
    XCTAssertEqual(harness.subject.phase, .failed("dictation.error.noSpeech"))
}

func testFallbackFailureRestoresPartialAndSelectionSnapshotRatherThanKeepingPartial() async {
    let harness = DictationHarness(fallbackError: SpeechTranscriptionError.provider("offline"))
    await harness.startListening()
    await harness.client.send(.delta(
        eventID: "partial", sequence: nil, itemID: "item", contentIndex: 0, text: "temporary"
    ))
    await harness.client.failReceive(with: .connectionClosed)
    await harness.subject.endHold()
    await harness.drainTasks()
    XCTAssertEqual(harness.transaction.provisional, ["temporary"])
    XCTAssertEqual(harness.transaction.restoreCount, 1)
    XCTAssertTrue(harness.transaction.committed.isEmpty)
}

func testFirstTerminalResultWinsAgainstLateSocketAndFallbackCallbacks() async {
    let harness = DictationHarness(fallbackText: "fallback")
    await harness.startListening()
    let release = Task { await harness.subject.endHold() }
    await harness.client.waitUntilCommitted()
    await harness.client.send(.completed(
        eventID: "final", sequence: nil, itemID: "item", contentIndex: 0, transcript: "realtime"
    ))
    await harness.client.failReceive(with: .connectionClosed)
    await release.value
    await harness.drainTasks()
    XCTAssertEqual(harness.transaction.committed, ["realtime"])
    XCTAssertTrue(harness.fallbackRequests.isEmpty)
}

func testCancelAndWaitWhileListeningRestoresClosesUnlocksAndDeletes() async {
    let harness = DictationHarness()
    await harness.startListening()
    await harness.subject.cancelAndWait()
    XCTAssertTrue(harness.subject.isIdle)
    XCTAssertEqual(harness.transaction.restoreCount, 1)
    XCTAssertEqual(harness.client.closeCount, 1)
    XCTAssertEqual(harness.capture.cancelCount + harness.capture.stopCount, 1)
    XCTAssertEqual(harness.deletedURLs, harness.capture.createdURLs)
}
~~~

Repeat that exact cleanup assertion in named tests entered through the harness's connection gate, receive failure, commit gate, and fallback gate for connecting, recording-for-fallback, finalizing, and recovering. Add named tests for stale session callback after rapid restart, capture failure, file finalization failure, fallback empty text, double release, double cancel, cancel during permission, cancel during fallback, and context supersession.

- [ ] **Step 8: Implement terminal arbitration, fallback, and cancel-and-wait**

`attemptFallback(id:)` guards the UUID, `terminalWon == false`, `fallbackAttempted == false`, and a finalized non-empty file. It sets `fallbackAttempted = true`, closes the client, publishes `.recovering`, calls the injected file transcriber with the frozen v4 config, trims the result, and commits or restores.

`finish(id:outcome:)` is the only terminal text mutation. On non-empty success it sets `terminalWon`, commits once, publishes `.complete`, and cleans up. On no speech or error it sets `terminalWon`, restores once, publishes `.failed(localizationKey)`, and cleans up. Cleanup cancels tasks other than the current task, closes the client, cancels/stops capture as appropriate, removes the URL, clears the session, decrements operation ownership, and resumes idle waiters. The URL is cleared before deletion so reentrant cancellation cannot delete twice.

`cancel()` invalidates the UUID/session before awaiting external cleanup, restores immediately on the main actor, cancels capture and tasks, closes transport, removes the URL, publishes `.idle`, and discards stale errors. `cancelAndWait()` invokes cancel and then waits until `activeOperationCount == 0`; it is the maintenance/termination boundary.

- [ ] **Step 9: Keep the existing file fallback compatible**

Extend `OpenAISpeechTranscriptionProviderTests` to assert:

- A zero-byte file throws `.emptyAudio` before a request.
- A non-empty `.m4a` still uses `audio/m4a`.
- The request uses `VoiceInputConfig.speechEndpoint` and `speechModel` supplied by the frozen dictation config.
- A whitespace response maps to `.emptyResponse`.

Run:

~~~bash
swift test --filter WritingDictationCoordinatorTests
swift test --filter OpenAISpeechTranscriptionProviderTests
~~~

Expected: both suites pass.

- [ ] **Step 10: Commit the coordinator**

~~~bash
git add Sources/InkletApp/WritingDictationCoordinator.swift \
  Tests/InkletCoreTests/WritingDictationCoordinatorTests.swift \
  Tests/InkletCoreTests/OpenAISpeechTranscriptionProviderTests.swift
git commit -m "Coordinate realtime writing dictation"
~~~

### Task 6: Add A Popover-Local Hold Monitor

**Files:**
- Modify: `Tests/InkletCoreTests/VoiceShortcutModifierPressTrackerTests.swift`
- Create: `Sources/InkletApp/WritingDictationShortcutMonitor.swift`
- Create: `Tests/InkletCoreTests/WritingDictationShortcutMonitorTests.swift`

- [ ] **Step 1: Lock the reusable existing hold behavior before adding the local monitor**

At this stage the global monitor still compiles against the legacy recognizer API, so do not remove its enum cases yet. Add/retain these focused press-and-hold expectations:

~~~swift
func testShortPressDoesNothing() {
    var subject = VoiceShortcutGestureRecognizer()
    XCTAssertEqual(subject.pressBegan(at: 0, mode: .pressAndHold), [])
    XCTAssertEqual(subject.pressEnded(at: 0.04, mode: .pressAndHold), [])
}

func testHoldStartsAndReleaseStopsExactlyOnce() {
    var subject = VoiceShortcutGestureRecognizer()
    _ = subject.pressBegan(at: 0, mode: .pressAndHold)
    XCTAssertEqual(subject.holdDelayElapsed(at: 0.08, mode: .pressAndHold), [.start])
    XCTAssertEqual(subject.holdDelayElapsed(at: 0.09, mode: .pressAndHold), [])
    XCTAssertEqual(subject.pressEnded(at: 0.10, mode: .pressAndHold), [.stop])
    XCTAssertEqual(subject.pressEnded(at: 0.11, mode: .pressAndHold), [])
}

func testInterruptedCandidateCannotStart() {
    var subject = VoiceShortcutGestureRecognizer()
    _ = subject.pressBegan(at: 0, mode: .pressAndHold)
    subject.interrupt()
    XCTAssertEqual(subject.holdDelayElapsed(at: 0.08, mode: .pressAndHold), [])
    XCTAssertEqual(subject.pressEnded(at: 0.10, mode: .pressAndHold), [])
}
~~~

- [ ] **Step 2: Run the reusable tracker/recognizer baseline**

Run:

~~~bash
swift test --filter VoiceShortcutGestureRecognizerTests
swift test --filter VoiceShortcutModifierPressTrackerTests
~~~

Expected: both existing suites pass. Add one tracker test proving `reset()` makes the later release `.ignored`.

- [ ] **Step 4: Write failing local-monitor tests**

The monitor initializer injects a scheduler and current modifier flags so no test sleeps:

~~~swift
@MainActor
func testRequiresReleaseWhenModifierWasAlreadyDownAtEditorActivation() {
    let harness = ShortcutMonitorHarness()
    harness.activateEditor(modifierAlreadyDown: true)
    harness.flagsChanged(isDown: true)
    harness.fireHoldTimer()
    XCTAssertEqual(harness.starts, 0)

    harness.flagsChanged(isDown: false)
    harness.flagsChanged(isDown: true)
    harness.fireHoldTimer()
    XCTAssertEqual(harness.starts, 1)
}

@MainActor
func testContextEligibilityIsRecheckedAtHoldThreshold() {
    let harness = ShortcutMonitorHarness()
    harness.activateEditor(modifierAlreadyDown: false)
    harness.flagsChanged(isDown: true)
    harness.isSourceFirstResponder = false
    harness.fireHoldTimer()
    XCTAssertEqual(harness.starts, 0)
}

@MainActor
func testReleaseStopsActiveHoldExactlyOnceAndContextLossCancels() {
    let harness = ShortcutMonitorHarness()
    harness.startValidHold()
    harness.flagsChanged(isDown: false)
    harness.flagsChanged(isDown: false)
    XCTAssertEqual(harness.stops, 1)

    harness.startValidHold()
    harness.subject.invalidateContext()
    XCTAssertEqual(harness.cancels, 1)
    harness.flagsChanged(isDown: false)
    XCTAssertEqual(harness.stops, 1)
}
~~~

Use this deterministic scheduler harness in `WritingDictationShortcutMonitorTests.swift`:

~~~swift
@MainActor
private final class TestHold: CancellableHold {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}

@MainActor
private final class ShortcutMonitorHarness {
    var isSourceFirstResponder = true
    var starts = 0
    var stops = 0
    var cancels = 0
    private var scheduledAction: (@MainActor () -> Void)?
    private var scheduledHold: TestHold?
    lazy var subject = WritingDictationShortcutMonitor(
        holdActivationDelay: 0.08,
        schedule: { [unowned self] _, action in
            let hold = TestHold()
            scheduledHold = hold
            scheduledAction = action
            return hold
        }
    )

    func activateEditor(modifierAlreadyDown: Bool) {
        subject.configure(
            shortcut: .rightOption,
            isEligible: { [unowned self] in isSourceFirstResponder },
            onStart: { [unowned self] in starts += 1 },
            onStop: { [unowned self] in stops += 1 },
            onCancel: { [unowned self] in cancels += 1 }
        )
        subject.activateEditorContext(modifierAlreadyDown: modifierAlreadyDown)
    }

    func flagsChanged(isDown: Bool) {
        subject.handleFlagsChangedForTesting(
            keyCode: 61,
            isConfiguredModifierDown: isDown
        )
    }

    func fireHoldTimer() {
        guard scheduledHold?.isCancelled == false else { return }
        let action = scheduledAction
        scheduledAction = nil
        action?()
    }

    func startValidHold() {
        activateEditor(modifierAlreadyDown: false)
        flagsChanged(isDown: true)
        fireHoldTimer()
    }
}
~~~

Also test disabled, all four left/right modifier key codes, short press, marked text, picker route, result-editor focus, inactive panel, busy transformation/dictation, key-down interruption before threshold, missing-key-up reset, and that handled events are returned unchanged.

- [ ] **Step 5: Run local-monitor tests and confirm the red state**

Run: `swift test --filter WritingDictationShortcutMonitorTests`

Expected: compilation fails because `WritingDictationShortcutMonitor` does not exist.

- [ ] **Step 6: Implement the app-local monitor**

Create:

~~~swift
import AppKit
import InkletCore

@MainActor
final class WritingDictationShortcutMonitor {
    typealias Eligibility = @MainActor () -> Bool
    typealias Schedule = @MainActor (
        TimeInterval,
        @escaping @MainActor () -> Void
    ) -> any CancellableHold

    private let holdActivationDelay: TimeInterval
    private let schedule: Schedule
    private var localMonitor: Any?
    private var shortcut: VoiceInputConfig.Shortcut = .disabled
    private var tracker = VoiceShortcutModifierPressTracker()
    private var recognizer = VoiceShortcutGestureRecognizer()
    private var pendingHold: (any CancellableHold)?
    private var requiresFreshRelease = true
    private var isGestureActive = false
    private var isEligible: Eligibility = { false }
    private var onStart: @MainActor () -> Void = {}
    private var onStop: @MainActor () -> Void = {}
    private var onCancel: @MainActor () -> Void = {}

    init(
        holdActivationDelay: TimeInterval = 0.08,
        schedule: @escaping Schedule = { delay, action in
            DispatchWorkItemHold(delay: delay, action: action)
        }
    ) {
        self.holdActivationDelay = holdActivationDelay
        self.schedule = schedule
    }

    func configure(
        shortcut: VoiceInputConfig.Shortcut,
        isEligible: @escaping Eligibility,
        onStart: @escaping @MainActor () -> Void,
        onStop: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.shortcut = shortcut
        self.isEligible = isEligible
        self.onStart = onStart
        self.onStop = onStop
        self.onCancel = onCancel
    }
}
~~~

Define the scheduler token in the same file so both production and tests use the same cancellation contract:

~~~swift
@MainActor
protocol CancellableHold: AnyObject {
    func cancel()
}

@MainActor
private final class DispatchWorkItemHold: CancellableHold {
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        let workItem = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        self.workItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
~~~

The production scheduler wraps `DispatchWorkItem` at 0.08 seconds. `start()` installs only:

~~~swift
NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
    self?.handle(event) ?? event
}
~~~

`activateEditorContext(modifierAlreadyDown:)` resets tracker/recognizer/timer and sets `requiresFreshRelease` to the supplied physical flag. A release clears that gate without emitting stop unless a hold actually started. At timer fire, call `isEligible()` again before `holdDelayElapsed(at:mode: .pressAndHold)` and `onStart`. Any release after start emits `onStop` once even if eligibility changed at that instant; explicit context invalidation instead emits `onCancel`, resets the recognizer, and suppresses the later release. The legacy `.toggle` action is unreachable because this monitor always supplies `.pressAndHold`; keep an exhaustive switch with a no-op `.toggle` branch until Task 9 removes the old global caller and simplifies the recognizer.

`keyDown` interrupts only a pending candidate and returns the event. Escape is not consumed here; the text system/panel owns it. `stop()` removes the NSEvent monitor, cancels the timer, cancels an active transaction through `onCancel`, and clears closures/state.

- [ ] **Step 7: Run focused shortcut tests and commit**

Run:

~~~bash
swift test --filter VoiceShortcutGestureRecognizerTests
swift test --filter VoiceShortcutModifierPressTrackerTests
swift test --filter WritingDictationShortcutMonitorTests
~~~

Expected: all three suites pass and no test requires Accessibility trust.

~~~bash
git add Sources/InkletCore/VoiceShortcutModifierPressTracker.swift \
  Sources/InkletApp/WritingDictationShortcutMonitor.swift \
  Tests/InkletCoreTests/VoiceShortcutModifierPressTrackerTests.swift \
  Tests/InkletCoreTests/WritingDictationShortcutMonitorTests.swift
git commit -m "Scope dictation shortcut to Writing"
~~~

### Task 7: Integrate Dictation With The Writing View Model And Source Text View

**Files:**
- Modify: `Sources/InkletApp/DictationEditorTransaction.swift`
- Modify: `Sources/InkletApp/InkletPopoverView.swift`
- Create: `Tests/InkletCoreTests/WritingPopoverDictationViewModelTests.swift`
- Modify: `Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift`
- Modify: `Tests/InkletCoreTests/WritingPopoverKeyboardPolicyTests.swift`

- [ ] **Step 1: Write failing view-model snapshot tests**

Build the view model with isolated `UserDefaults`, Keychain test doubles already used by neighboring tests, and an in-memory history store. Cover result preservation during provisional updates and exactly-once invalidation at final:

~~~swift
@MainActor
func testProvisionalSourceSyncPreservesVisibleResultAndProducingMode() {
    let subject = makeEditorViewModel(source: "old", result: "old result")
    XCTAssertTrue(subject.beginSourceDictationPresentation())

    subject.synchronizeSourceTextDuringDictation("partial")

    XCTAssertEqual(subject.sourceText, "partial")
    XCTAssertEqual(subject.resultText, "old result")
    XCTAssertEqual(subject.popoverSession.resultModeID, nil)
}

@MainActor
func testSuccessfulFinalInvalidatesOldResultOnce() {
    let subject = makeEditorViewModel(source: "old", result: "old result")
    XCTAssertTrue(subject.beginSourceDictationPresentation())
    subject.synchronizeSourceTextDuringDictation("final")
    subject.commitSourceDictationPresentation()

    XCTAssertEqual(subject.sourceText, "final")
    XCTAssertEqual(subject.resultText, "")
    XCTAssertNil(subject.popoverSession.resultModeID)
}

@MainActor
func testRestoreRecoversSourceResultErrorSessionAndStateMachine() {
    let subject = makeEditorViewModel(source: "old", result: "old result")
    subject.errorMessage = "old error"
    let originalSource = subject.sourceText
    let originalResult = subject.resultText
    let originalError = subject.errorMessage
    let originalSession = subject.popoverSession
    XCTAssertTrue(subject.beginSourceDictationPresentation())
    subject.synchronizeSourceTextDuringDictation("partial")
    subject.restoreSourceDictationPresentation()

    XCTAssertEqual(subject.sourceText, originalSource)
    XCTAssertEqual(subject.resultText, originalResult)
    XCTAssertEqual(subject.errorMessage, originalError)
    XCTAssertEqual(subject.popoverSession, originalSession)
}

@MainActor
func testEscapeCancelsActiveDictationBeforeNormalWritingNavigation() {
    let subject = makeEditorViewModel(source: "draft", result: "")
    var cancellations = 0
    subject.onCancelDictation = { cancellations += 1 }
    subject.setDictationPhase(.listening)
    subject.escape()

    XCTAssertEqual(cancellations, 1)
    XCTAssertEqual(subject.route, .editor)
}
~~~

Add this helper inside `WritingPopoverDictationViewModelTests`:

~~~swift
private func makeEditorViewModel(
    source: String,
    result: String
) -> InkletPopoverViewModel {
    let suiteName = "WritingPopoverDictationViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let configStore = UserDefaultsConfigStore(userDefaults: defaults)
    let preferenceStore = WritingModePreferenceStore(userDefaults: defaults)
    let historyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(suiteName)
        .appendingPathComponent("history.jsonl")
    let subject = InkletPopoverViewModel(
        configStore: configStore,
        historyStore: JSONLHistoryStore(fileURL: historyURL),
        writingModePreferenceStore: preferenceStore
    )
    subject.resetForOpen(previousApplication: nil)
    subject.commitMode(modeID: subject.selectedModeID)
    subject.sourceText = source
    subject.resultText = result
    return subject
}
~~~

Also assert active dictation blocks submit, mode change, mode-picker return, insertion, settings open, and normal source/result typing; `failed(key)` shows localized inline error after restoration; cancellation without failure restores the previous error.

- [ ] **Step 2: Run view-model tests and confirm the red state**

Run: `swift test --filter WritingPopoverDictationViewModelTests`

Expected: compilation fails because the dictation presentation API and phase do not exist.

- [ ] **Step 3: Add the presentation snapshot and dedicated source paths**

In `InkletPopoverViewModel` add:

~~~swift
@Published private(set) var dictationPhase: WritingDictationCoordinator.Phase = .idle
var onCancelDictation: (() -> Void)?

private struct SourceDictationPresentationSnapshot {
    let sourceText: String
    let resultText: String
    let errorMessage: String?
    let popoverSession: WritingPopoverSessionState
    let stateMachineState: PopoverStateMachine.State
    let draftSourceText: String
    let hasTransformedInSession: Bool
}

private var sourceDictationSnapshot: SourceDictationPresentationSnapshot?
~~~

Implement:

~~~swift
func beginSourceDictationPresentation() -> Bool {
    guard route == .editor, !isBusy, sourceDictationSnapshot == nil else { return false }
    sourceDictationSnapshot = SourceDictationPresentationSnapshot(
        sourceText: sourceText,
        resultText: resultText,
        errorMessage: errorMessage,
        popoverSession: popoverSession,
        stateMachineState: stateMachine.state,
        draftSourceText: draftSourceText,
        hasTransformedInSession: hasTransformedInSession
    )
    errorMessage = nil
    return true
}

func synchronizeSourceTextDuringDictation(_ text: String) {
    guard sourceDictationSnapshot != nil else { return }
    sourceText = text
}

func commitSourceDictationPresentation() {
    guard sourceDictationSnapshot != nil else { return }
    sourceDictationSnapshot = nil
    resultText = ""
    errorMessage = nil
    draftSourceText = sourceText
    hasTransformedInSession = false
    mutatePopoverSession { $0.clearResult() }
    stateMachine = PopoverStateMachine(
        state: .editingSource(source: sourceText, errorMessage: nil)
    )
}

func restoreSourceDictationPresentation() {
    guard let snapshot = sourceDictationSnapshot else { return }
    sourceDictationSnapshot = nil
    sourceText = snapshot.sourceText
    resultText = snapshot.resultText
    errorMessage = snapshot.errorMessage
    popoverSession = snapshot.popoverSession
    stateMachine = PopoverStateMachine(state: snapshot.stateMachineState)
    draftSourceText = snapshot.draftSourceText
    hasTransformedInSession = snapshot.hasTransformedInSession
}

func setDictationPhase(_ phase: WritingDictationCoordinator.Phase) {
    dictationPhase = phase
    if case .failed(let localizationKey) = phase {
        errorMessage = L10n.text(localizationKey)
    }
}
~~~

Expose only the current frozen-input values needed by the window controller and action bar:

~~~swift
var currentVoiceInputConfig: VoiceInputConfig { config.voiceInput }
var shouldShowDictationStatus: Bool {
    voiceShortcutHint != nil || dictationPhase.isActive
}

var dictationStatusText: String {
    switch dictationPhase {
    case .connecting: L10n.text("dictation.status.connecting")
    case .listening: L10n.text("dictation.status.listening")
    case .recordingForFallback: L10n.text("dictation.status.recordingFallback")
    case .finalizing: L10n.text("dictation.status.finalizing")
    case .recovering: L10n.text("dictation.status.recovering")
    case .idle, .complete, .failed:
        if let shortcut = voiceShortcutHint {
            L10n.format("dictation.hint.hold", shortcut.localizedName)
        } else {
            ""
        }
    }
}
~~~

Replace `refreshVoiceShortcutHint()` with:

~~~swift
private func refreshVoiceShortcutHint() {
    voiceShortcutHint = config.voiceInput.shortcut == .disabled
        ? nil
        : config.voiceInput.shortcut
}
~~~

This intentionally does not read Keychain or request any permission; a missing key becomes an actionable error only at the first valid hold.

`isBusy` becomes `isTransforming || isInserting || dictationPhase.isActive`. Replace all two-flag guards in editor actions with `guard !isBusy`. In `escape()`, after the native text system has already had first chance to consume marked text, call `onCancelDictation` and return when the phase is active.

- [ ] **Step 4: Add a source-only editor registration bridge**

In `DictationEditorTransaction.swift` add:

~~~swift
@MainActor
final class WritingSourceEditorBridge {
    private weak var textView: NSTextView?

    func attach(_ textView: NSTextView) {
        self.textView = textView
    }

    func detach(_ textView: NSTextView) {
        if self.textView === textView { self.textView = nil }
    }

    func isEligible(in window: NSWindow?, model: InkletPopoverViewModel) -> Bool {
        guard let textView, let window else { return false }
        return window.isKeyWindow
            && window.firstResponder === textView
            && model.route == .editor
            && !model.isBusy
            && !textView.hasMarkedText()
    }

    func beginTransaction(model: InkletPopoverViewModel) -> (any DictationEditorTransacting)? {
        guard let textView, model.beginSourceDictationPresentation() else { return nil }
        guard let transaction = DictationEditorTransaction(
            textView: textView,
            synchronizeProvisional: { [weak model] text in
                model?.synchronizeSourceTextDuringDictation(text)
            },
            commitSourceChange: { [weak model] _ in
                model?.commitSourceDictationPresentation()
            },
            restoreModelSnapshot: { [weak model] in
                model?.restoreSourceDictationPresentation()
            }
        ) else {
            model.restoreSourceDictationPresentation()
            return nil
        }
        return transaction
    }

    var attachedTextView: NSTextView? { textView }
}
~~~

Extend `InkletTextView` with `onResolveTextView: ((NSTextView?) -> Void)?`. Call it with the created text view in `makeNSView`, call it again in `updateNSView` to keep identity current, and call it with `nil` from `dismantleNSView`. Pass this callback only for the source editor around the existing source `InkletTextView`; the result editor passes `nil`.

Guard the representable's current whole-string synchronization:

~~~swift
if textView.string != text, textView.isEditable {
    textView.string = text
}
~~~

Dictation-owned updates therefore remain targeted and cannot be overwritten by the SwiftUI update cycle while the transaction has locked the view.

- [ ] **Step 5: Render all phases in the existing action-bar slot**

Replace the idle-only voice hint with one fixed-height `dictationStatusContent`:

~~~swift
@ViewBuilder
private var dictationStatusContent: some View {
    switch model.dictationPhase {
    case .connecting, .finalizing, .recovering:
        ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
    case .listening:
        Image(systemName: "waveform")
            .accessibilityLabel(L10n.text("dictation.accessibility.listening"))
    case .recordingForFallback:
        Image(systemName: "mic.badge.exclamationmark")
            .accessibilityLabel(L10n.text("dictation.accessibility.recordingFallback"))
    case .idle, .complete, .failed:
        Image(systemName: "mic")
            .accessibilityLabel(L10n.text("dictation.accessibility.ready"))
    }

    Text(model.dictationStatusText)
        .lineLimit(1)
        .truncationMode(.middle)
}
~~~

Show the container only when `model.shouldShowDictationStatus` is true, so `Disabled` produces no misleading ready microphone. The container retains the current action-bar height and icon frame in every state. It is informational, not clickable. Add `help` and a localized accessibility label. While active, keep current source content/result visible and do not replace the whole action bar with a differently sized row.

- [ ] **Step 6: Verify source-only wiring and keyboard priority**

Update source-contract tests to assert:

- Source `InkletTextView` receives `onResolveTextView`; result `InkletTextView` does not.
- Whole-string synchronization is gated while direct dictation owns the view.
- `escape()` checks active dictation before result clearing/mode navigation.
- `InkletNativeTextView` and `InkletPopoverPanel` still defer to `hasMarkedText()` before model Escape.
- Action-bar phase branches use one fixed frame and do not alter `preferredPopoverHeight`.

Run:

~~~bash
swift test --filter WritingPopoverDictationViewModelTests
swift test --filter WritingModeLauncherSourceTests
swift test --filter WritingPopoverKeyboardPolicyTests
~~~

Expected: all three suites pass.

- [ ] **Step 7: Commit the Writing presentation integration**

~~~bash
git add Sources/InkletApp/DictationEditorTransaction.swift \
  Sources/InkletApp/InkletPopoverView.swift \
  Tests/InkletCoreTests/WritingPopoverDictationViewModelTests.swift \
  Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift \
  Tests/InkletCoreTests/WritingPopoverKeyboardPolicyTests.swift
git commit -m "Show dictation in the Writing editor"
~~~

### Task 8: Wire Popover Lifecycle, Accessibility Announcements, And App Shutdown

**Files:**
- Modify: `Sources/InkletApp/InkletPopoverWindowController.swift`
- Modify: `Sources/InkletApp/AppCoordinator.swift`
- Delete: `Sources/InkletCore/VoiceInputCoordinator.swift`
- Delete: `Sources/InkletCore/VoiceInputCancellationPolicy.swift`
- Delete: `Sources/InkletCore/VoicePromptModeSelectionMenuState.swift`
- Delete: `Sources/InkletApp/VoiceShortcutMonitor.swift`
- Delete: `Sources/InkletApp/VoiceStatusWindowController.swift`
- Delete: `Tests/InkletCoreTests/VoiceInputCoordinatorTests.swift`
- Delete: `Tests/InkletCoreTests/VoiceInputCancellationPolicyTests.swift`
- Delete: `Tests/InkletCoreTests/VoicePromptModeSelectionMenuStateTests.swift`
- Delete: `Tests/InkletCoreTests/VoiceShortcutMonitorSourceTests.swift`
- Delete: `Tests/InkletCoreTests/VoiceStatusWindowControllerSourceTests.swift`
- Modify: `Tests/InkletCoreTests/AppCoordinatorSourceTests.swift`
- Modify: `Tests/InkletCoreTests/LegacyMigrationAppSourceTests.swift`
- Modify: `Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift`

- [ ] **Step 1: Write failing controller/wiring contract tests**

Add source and behavior assertions for:

- Window controller owns `WritingSourceEditorBridge`, `AudioRecorder`, `WritingDictationCoordinator`, and `WritingDictationShortcutMonitor`.
- The realtime client factory reads the canonical OpenAI provider key before returning a client.
- The fallback provider uses the frozen `speechEndpoint` and `speechModel`.
- Only the active, key Writing source editor is eligible.
- Picker, result editor, inactive panel, marked text, transform/insert/dictation busy states are ineligible.
- Route transition out of editor, `hide()`, `windowDidResignKey`, rapid `show()`, and migration maintenance await `cancelAndWait()`.
- App termination returns `.terminateLater` and calls `NSApp.reply(toApplicationShouldTerminate:)` only after dictation cleanup.
- AppCoordinator no longer owns or configures a global voice event tap/HUD/coordinator.

Run:

~~~bash
swift test --filter WritingModeLauncherSourceTests
swift test --filter AppCoordinatorSourceTests
swift test --filter LegacyMigrationAppSourceTests
~~~

Expected: failures reference missing dictation ownership and the still-present standalone voice wiring.

- [ ] **Step 2: Construct production dictation dependencies in the window controller**

Change initializer to accept the stores used by production and tests:

~~~swift
init(
    historyStore: any HistoryStore = JSONLHistoryStore(),
    configStore: UserDefaultsConfigStore = UserDefaultsConfigStore(),
    apiKeyStore: LocalAPIKeyStore = LocalAPIKeyStore()
)
~~~

Create one `AudioRecorder`, `WritingSourceEditorBridge`, and local monitor. Build the lazy coordinator with:

~~~swift
makeRealtimeClient: {
    let key = apiKeyStore
        .loadAPIKey(forProviderID: LLMProviderPreset.openAI.id)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !key.isEmpty else { throw RealtimeTranscriptionError.missingAPIKey }
    return OpenAIRealtimeTranscriptionClient(apiKeyProvider: { key })
},
beginTransaction: { [weak self] in
    guard let self,
          self.sourceEditor.isEligible(in: self.window, model: self.model)
    else { return nil }
    return self.sourceEditor.beginTransaction(model: self.model)
},
transcribeFallback: { [weak apiKeyStore] url, config in
    guard let endpoint = URL(string: config.speechEndpoint),
          let scheme = endpoint.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          endpoint.host != nil
    else { throw SpeechTranscriptionError.invalidEndpoint }
    let provider = OpenAISpeechTranscriptionProvider(
        apiKeyProvider: {
            guard let key = apiKeyStore?
                .loadAPIKey(forProviderID: LLMProviderPreset.openAI.id)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty
            else { throw RealtimeTranscriptionError.missingAPIKey }
            return key
        },
        endpoint: endpoint
    )
    return try await provider.transcribe(SpeechTranscriptionRequest(
        audioFileURL: url,
        model: config.speechModel,
        timeoutSeconds: 20
    )).text
}
~~~

The config provider returns `model.currentVoiceInputConfig`, a read-only property added in Task 7.

- [ ] **Step 3: Wire source identity, local shortcut, phases, and accessibility**

Pass `sourceEditor.attach/detach` into `InkletPopoverView`. Configure the local monitor whenever the popover is shown or v4 config changes. Its eligibility closure uses:

~~~swift
window?.isKeyWindow == true
    && model.route == .editor
    && sourceEditor.attachedTextView === window?.firstResponder
    && sourceEditor.attachedTextView?.hasMarkedText() == false
    && !model.isBusy
~~~

On start/end/cancel, create main-actor tasks that call `beginHold`, `endHold`, and `cancel`. Subscribe to `model.$popoverSession`: entering editor calls `activateEditorContext(modifierAlreadyDown:)` using current `NSEvent.modifierFlags`; leaving editor invalidates context and awaits coordinator cancellation.

The coordinator phase handler calls `model.setDictationPhase` and posts an AppKit accessibility announcement only for `listening`, `finalizing`, `recovering`, `complete`, `idle` after cancellation, and `failed`. Use:

~~~swift
NSAccessibility.post(
    element: panel,
    notification: .announcementRequested,
    userInfo: [
        .announcement: L10n.text(phase.accessibilityAnnouncementKey),
        .priority: NSAccessibilityPriorityLevel.medium.rawValue
    ]
)
~~~

Do not announce deltas or transcript text.

- [ ] **Step 4: Make hide, focus loss, reopen, and maintenance await cleanup**

Set the panel delegate to the controller. Implement `windowDidResignKey` as context invalidation followed by `Task { await cancelAndWait() }`.

Change `show` to use a monotonically increasing presentation generation:

~~~swift
func show(fallbackApplication: NSRunningApplication? = nil) {
    presentationGeneration += 1
    let generation = presentationGeneration
    Task { @MainActor [weak self] in
        guard let self else { return }
        await self.dictationCoordinator.cancelAndWait()
        guard generation == self.presentationGeneration else { return }
        self.prepareAndPresent(fallbackApplication: fallbackApplication)
    }
}
~~~

`hide()` increments the generation, invalidates the shortcut context, awaits cancel-and-wait, then orders out only if no newer show superseded it. `cancelForMigrationMaintenance() async` cancels dictation and the existing transform/insert tasks before ordering out. This makes rapid reopen and dismissal deterministic.

Publish busy state with:

~~~swift
Publishers.CombineLatest3(
    model.$isTransforming,
    model.$isInserting,
    model.$dictationPhase
)
.map { transforming, inserting, phase in
    transforming || inserting || phase.isActive
}
~~~

- [ ] **Step 5: Remove standalone voice ownership and global Accessibility gating**

From `AppCoordinator` delete:

- `voiceStatusController`, global `voiceShortcutMonitor`, its `audioRecorder`, and lazy `voiceCoordinator` fields.
- `configureVoiceInput()` and all config/accessibility/onboarding calls to it.
- `makeVoiceInputCoordinator()`, Prompt cleanup/choice, external insert, voice history, status window, and last-target-application voice wiring.
- `voiceCoordinator.isIdle` from migration readiness and `voiceCoordinator.cancelForMigrationMaintenance()` from maintenance.

The v4 configuration observer calls `windowController.reloadDictationConfiguration()`. Migration readiness uses `!windowController.isBusy`. `enterMigrationMaintenance()` awaits `windowController.cancelForMigrationMaintenance()` before starting data movement.

This removal must leave Accessibility permission behavior for existing external insertion and Selection Actions unchanged.

After the production call sites are gone, delete the five retired implementation files and their five obsolete tests listed in this task. Keep `HistorySource.voice`, `PromptMode.voiceCleanupID`, `VoiceShortcutModifierPressTracker`, `OpenAISpeechTranscriptionProvider`, and microphone discovery.

Remove the temporary no-result `AudioRecorder.start(microphoneDeviceID:)` compatibility wrapper added in Task 3; the final coordinator uses only `startStreaming`.

Run:

~~~bash
rg -n "VoiceInputCoordinator|VoiceInputCancellationPolicy|VoicePromptModeSelection|VoiceStatusWindowController|VoiceShortcutMonitor" Sources Tests/InkletCoreTests
~~~

Expected: no matches.

- [ ] **Step 6: Make application termination wait for temporary-file cleanup**

Change `AppCoordinator.stop()` to `async` and make its first lifecycle action:

~~~swift
await windowController.cancelDictationAndWait()
~~~

Then remove observers/monitors and cancel the existing Selection tasks as before.

Replace synchronous `applicationWillTerminate` cleanup in `AppDelegate` with:

~~~swift
private var terminationTask: Task<Void, Never>?

func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard terminationTask == nil else { return .terminateLater }
    terminationTask = Task { @MainActor [coordinator] in
        await coordinator.stop()
        sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
}
~~~

No termination branch may return `.terminateNow` while dictation is active.

- [ ] **Step 7: Run wiring and migration tests**

Run:

~~~bash
swift test --filter WritingModeLauncherSourceTests
swift test --filter AppCoordinatorSourceTests
swift test --filter LegacyMigrationAppSourceTests
swift test --filter WritingDictationCoordinatorTests
~~~

Expected: all suites pass; source-contract tests contain no global voice tap, standalone HUD, direct voice insertion, or voice-history production wiring.

- [ ] **Step 8: Commit lifecycle integration**

~~~bash
git add Sources/InkletApp/InkletPopoverWindowController.swift \
  Sources/InkletApp/AppCoordinator.swift \
  Tests/InkletCoreTests/AppCoordinatorSourceTests.swift \
  Tests/InkletCoreTests/LegacyMigrationAppSourceTests.swift \
  Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift
git add -u Sources Tests/InkletCoreTests
git commit -m "Wire dictation into the Writing popover"
~~~

### Task 9: Migrate Configuration To V4 And Merge Dictation Settings

**Files:**
- Modify: `Sources/InkletCore/VoiceInputConfig.swift`
- Modify: `Sources/InkletCore/ConfigStore.swift`
- Modify: `Sources/InkletCore/VoiceShortcutGestureRecognizer.swift`
- Modify: `Sources/InkletApp/SettingsView.swift`
- Modify: `Sources/InkletApp/InkletLocalization.swift`
- Modify: `Tests/InkletCoreTests/VoiceInputConfigTests.swift`
- Modify: `Tests/InkletCoreTests/ConfigStoreTests.swift`
- Modify: `Tests/InkletCoreTests/VoiceShortcutGestureRecognizerTests.swift`
- Modify: `Tests/InkletCoreTests/SettingsViewSourceTests.swift`

- [ ] **Step 1: Replace legacy configuration tests with v4 preservation/encoding tests**

Delete tests for recording-mode migration, auto processing, post action, cleanup-mode selection, provider ID, and Speech Profile. Add:

~~~swift
func testDefaultDictationConfigContainsOnlyLiveFields() {
    XCTAssertEqual(
        VoiceInputConfig.defaultConfig(),
        VoiceInputConfig(
            shortcut: .rightOption,
            speechEndpoint: "https://api.openai.com/v1/audio/transcriptions",
            speechModel: "gpt-4o-mini-transcribe",
            microphoneDeviceID: nil
        )
    )
}

func testV3VoiceConfigurationPreservesFourLiveFieldsAndIgnoresRetiredKeys() throws {
    let json = """
    {
      "shortcut": "leftCommand",
      "speechProviderID": "retired-provider",
      "speechEndpoint": "https://fallback.example/v1/audio/transcriptions",
      "speechModel": "fallback-model",
      "microphoneDeviceID": "mic-123",
      "autoProcessTranscription": false,
      "postTranscriptionAction": "askEachTime",
      "recordingMode": "doubleTap",
      "voiceCleanupPromptModeID": "legacy-cleanup"
    }
    """

    let decoded = try JSONDecoder().decode(VoiceInputConfig.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.shortcut, .leftCommand)
    XCTAssertEqual(decoded.speechEndpoint, "https://fallback.example/v1/audio/transcriptions")
    XCTAssertEqual(decoded.speechModel, "fallback-model")
    XCTAssertEqual(decoded.microphoneDeviceID, "mic-123")

    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
    )
    XCTAssertEqual(Set(object.keys), [
        "shortcut", "speechEndpoint", "speechModel", "microphoneDeviceID"
    ])
}

func testAppConfigMigratesVersionsOneThroughThreeToVersionFour() throws {
    for savedVersion in 1...3 {
        let data = makeLegacyAppConfigData(
            version: savedVersion,
            voiceInput: [
                "shortcut": "rightCommand",
                "speechEndpoint": "https://fallback.example/transcribe",
                "speechModel": "legacy-model",
                "microphoneDeviceID": "legacy-mic",
                "recordingMode": "tapToToggle"
            ]
        )
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(config.version, 4)
        XCTAssertEqual(config.voiceInput.shortcut, .rightCommand)
        XCTAssertEqual(config.voiceInput.speechEndpoint, "https://fallback.example/transcribe")
        XCTAssertEqual(config.voiceInput.speechModel, "legacy-model")
        XCTAssertEqual(config.voiceInput.microphoneDeviceID, "legacy-mic")
    }
}
~~~

Keep the future-version preservation test, changing only the current schema expectation from 3 to 4.

- [ ] **Step 2: Run configuration tests and confirm the red state**

Run:

~~~bash
swift test --filter VoiceInputConfigTests
swift test --filter ConfigStoreTests
~~~

Expected: failures show schema version 3 and encoded retired fields.

- [ ] **Step 3: Reduce `VoiceInputConfig` to its four live fields**

Keep `Shortcut` and its cases. Remove `RecordingMode`, `SpeechProfile`, `PostTranscriptionAction`, `speechProviderID`, `autoProcessTranscription`, `postTranscriptionAction`, `recordingMode`, and `voiceCleanupPromptModeID`.

The resulting type is:

~~~swift
import Foundation

public struct VoiceInputConfig: Codable, Equatable, Sendable {
    public static let defaultSpeechEndpoint = "https://api.openai.com/v1/audio/transcriptions"
    public static let defaultSpeechModel = "gpt-4o-mini-transcribe"

    public enum Shortcut: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
        case rightOption
        case rightCommand
        case leftOption
        case leftCommand
        case disabled

        public var id: String { rawValue }
    }

    public var shortcut: Shortcut
    public var speechEndpoint: String
    public var speechModel: String
    public var microphoneDeviceID: String?

    public init(
        shortcut: Shortcut,
        speechEndpoint: String,
        speechModel: String,
        microphoneDeviceID: String?
    ) {
        self.shortcut = shortcut
        self.speechEndpoint = speechEndpoint
        self.speechModel = speechModel
        self.microphoneDeviceID = microphoneDeviceID
    }

    public static func defaultConfig() -> VoiceInputConfig {
        VoiceInputConfig(
            shortcut: .rightOption,
            speechEndpoint: defaultSpeechEndpoint,
            speechModel: defaultSpeechModel,
            microphoneDeviceID: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case shortcut
        case speechEndpoint
        case speechModel
        case microphoneDeviceID
    }

    public init(from decoder: Decoder) throws {
        let defaults = Self.defaultConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try container.decodeIfPresent(Shortcut.self, forKey: .shortcut) ?? defaults.shortcut
        speechEndpoint = try container.decodeIfPresent(String.self, forKey: .speechEndpoint)
            ?? defaults.speechEndpoint
        speechModel = try container.decodeIfPresent(String.self, forKey: .speechModel)
            ?? defaults.speechModel
        microphoneDeviceID = try container.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
    }
}
~~~

Unknown v1-v3 keys are ignored by `Decodable` and can never be re-encoded because they are absent from `CodingKeys`.

- [ ] **Step 4: Simplify the recognizer now that the global caller is gone**

Replace the recognizer with the final hold-only surface:

~~~swift
import Foundation

public enum VoiceShortcutGestureAction: Equatable, Sendable {
    case start
    case stop
}

public struct VoiceShortcutGestureRecognizer: Equatable, Sendable {
    private var isPressed = false
    private var isInterrupted = false
    private var didStart = false

    public init() {}

    public mutating func pressBegan() -> [VoiceShortcutGestureAction] {
        guard !isPressed else { return [] }
        isPressed = true
        isInterrupted = false
        didStart = false
        return []
    }

    public mutating func holdDelayElapsed() -> [VoiceShortcutGestureAction] {
        guard isPressed, !isInterrupted, !didStart else { return [] }
        didStart = true
        return [.start]
    }

    public mutating func pressEnded() -> [VoiceShortcutGestureAction] {
        defer {
            isPressed = false
            isInterrupted = false
            didStart = false
        }
        guard isPressed, !isInterrupted, didStart else { return [] }
        return [.stop]
    }

    public mutating func interrupt() {
        guard isPressed, !didStart else { return }
        isInterrupted = true
    }

    public mutating func reset() {
        self = VoiceShortcutGestureRecognizer()
    }
}
~~~

Update `WritingDictationShortcutMonitor` to call the parameterless methods and remove its unreachable `.toggle` branch. Replace the recognizer tests with the three final hold-only tests shown in Task 6, without a recording-mode argument.

- [ ] **Step 5: Increment the app schema and remove obsolete migration logic**

Set `AppConfig.currentVersion = 4`. Decode `voiceInput` directly:

~~~swift
voiceInput = try container.decodeIfPresent(
    VoiceInputConfig.self,
    forKey: .voiceInput
) ?? defaults.voiceInput
~~~

Delete `migratedVoiceInput`. Do not modify `HistorySource.voice`, legacy history, or `LegacySandboxDataMigrator`: the latter copies validated app-config data and lets normal v4 decoding migrate it.

- [ ] **Step 6: Write failing Settings merge tests**

Update `SettingsViewSourceTests` to assert:

~~~swift
func testWriteAssistantContainsMergedDictationControls() throws {
    let source = try settingsSource()
    XCTAssertFalse(source.contains("case voiceWriteAssistant"))
    XCTAssertTrue(source.contains("settings.group.writing"))
    XCTAssertTrue(source.contains("settings.group.dictation"))
    XCTAssertTrue(source.contains("$model.config.voiceInput.shortcut"))
    XCTAssertTrue(source.contains("selectedMicrophoneBinding"))
    XCTAssertTrue(source.contains("$model.config.voiceInput.speechEndpoint"))
    XCTAssertTrue(source.contains("$model.config.voiceInput.speechModel"))
}

func testRetiredVoiceWorkflowControlsAreAbsent() throws {
    let source = try settingsSource()
    for retired in [
        "VoiceInputConfig.RecordingMode",
        "VoiceInputConfig.PostTranscriptionAction",
        "selectedSpeechProfile",
        "voiceCleanupModes",
        "autoProcessTranscription",
        "voiceCleanupPromptModeID"
    ] {
        XCTAssertFalse(source.contains(retired), retired)
    }
}
~~~

Retain the existing test proving that opening/flushing Settings without edits preserves raw imported configuration.

- [ ] **Step 7: Merge the Dictation controls into Write Assistant**

Delete `SettingsSection.voiceWriteAssistant`, its title/icon branches, panel switch, and standalone `voicePanel`. Structure `writeAssistantPanel` as one scroll view with:

~~~swift
VStack(alignment: .leading, spacing: 18) {
    settingsGroupTitle(
        L10n.text("settings.group.writing"),
        help: L10n.text("settings.group.writing.help")
    )
    writingSettingsPanel

    settingsGroupTitle(
        L10n.text("settings.group.dictation"),
        help: L10n.text("settings.group.dictation.help")
    )
    dictationSettingsPanel
}
~~~

`dictationSettingsPanel` contains:

1. Hold shortcut Picker over `VoiceInputConfig.Shortcut.allCases`.
2. Microphone Picker over `microphoneOptions`.
3. A restrained `DisclosureGroup` labeled `settings.group.dictationAdvanced`.
4. Inside Advanced, fallback endpoint and fallback model text fields. Their help explicitly says they are used only if realtime transcription cannot finish.

Do not include a speech profile, realtime endpoint/model, recording mode, toggle, auto process, post action, or cleanup mode.

Delete Settings-model properties and save mutations for retired fields. Keep endpoint URL validation, but use `settings.error.invalidFallbackSpeechEndpoint`. Quick Start always describes a hold gesture and never branches on a recording mode.

Delete the three now-invalid localized extensions for `VoiceInputConfig.RecordingMode`, `VoiceInputConfig.SpeechProfile`, and `VoiceInputConfig.PostTranscriptionAction` from `InkletLocalization.swift` in this same compile unit. Task 10 adds the replacement phase/settings dictionaries.

- [ ] **Step 8: Run configuration, recognizer, and Settings tests**

Run:

~~~bash
swift test --filter VoiceInputConfigTests
swift test --filter ConfigStoreTests
swift test --filter VoiceShortcutGestureRecognizerTests
swift test --filter WritingDictationShortcutMonitorTests
swift test --filter SettingsViewSourceTests
~~~

Expected: all suites pass and encoded v4 JSON contains no retired key.

- [ ] **Step 9: Commit configuration and Settings migration**

~~~bash
git add Sources/InkletCore/VoiceInputConfig.swift \
  Sources/InkletCore/ConfigStore.swift \
  Sources/InkletCore/VoiceShortcutGestureRecognizer.swift \
  Sources/InkletApp/SettingsView.swift \
  Sources/InkletApp/InkletLocalization.swift \
  Tests/InkletCoreTests/VoiceInputConfigTests.swift \
  Tests/InkletCoreTests/ConfigStoreTests.swift \
  Tests/InkletCoreTests/VoiceShortcutGestureRecognizerTests.swift \
  Tests/InkletCoreTests/SettingsViewSourceTests.swift \
  Tests/InkletCoreTests/WritingDictationShortcutMonitorTests.swift
git commit -m "Merge dictation settings into Writing"
~~~

### Task 10: Localize Dictation, Preserve Legacy History, And Update Public Documentation

**Files:**
- Modify: `Sources/InkletApp/InkletLocalization.swift`
- Create: `Tests/InkletCoreTests/WritingDictationLocalizationTests.swift`
- Modify: `Tests/InkletCoreTests/VoiceSettingsLocalizationTests.swift`
- Modify: `Tests/InkletCoreTests/HistoryStoreTests.swift`
- Modify: `Tests/InkletCoreTests/WritingModeLauncherLocalizationTests.swift`
- Modify: `Tests/InkletCoreTests/DirectDistributionContractTests.swift`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `SECURITY.md`
- Modify: `docs/privacy-policy.md`
- Modify: `docs/manual-test-checklist.md`
- Modify: `scripts/test-direct-distribution.sh`

- [ ] **Step 1: Write failing all-language key and retired-copy tests**

Use the localization-table parser already present in `VoiceSettingsLocalizationTests`. The required keys are:

~~~swift
private let dictationKeys: Set<String> = [
    "settings.group.writing",
    "settings.group.writing.help",
    "settings.group.dictation",
    "settings.group.dictation.help",
    "settings.group.dictationAdvanced",
    "settings.row.dictationShortcut",
    "settings.help.dictationShortcut",
    "settings.row.microphone",
    "settings.help.microphone",
    "settings.row.fallbackSpeechEndpoint",
    "settings.help.fallbackSpeechEndpoint",
    "settings.row.fallbackSpeechModel",
    "settings.help.fallbackSpeechModel",
    "settings.error.invalidFallbackSpeechEndpoint",
    "dictation.hint.hold",
    "dictation.status.connecting",
    "dictation.status.listening",
    "dictation.status.recordingFallback",
    "dictation.status.finalizing",
    "dictation.status.recovering",
    "dictation.status.ready",
    "dictation.accessibility.ready",
    "dictation.accessibility.listening",
    "dictation.accessibility.recordingFallback",
    "dictation.accessibility.finalizing",
    "dictation.accessibility.recovering",
    "dictation.accessibility.completed",
    "dictation.accessibility.cancelled",
    "dictation.accessibility.failed",
    "dictation.accessibility.sourceEditor",
    "dictation.undo.action",
    "dictation.error.missingAPIKey",
    "dictation.error.microphonePermission",
    "dictation.error.noAudioInputDevice",
    "dictation.error.recordingUnavailable",
    "dictation.error.realtimeBufferOverflow",
    "dictation.error.connection",
    "dictation.error.connectionTimeout",
    "dictation.error.finalTimeout",
    "dictation.error.fallback",
    "dictation.error.noSpeech"
]
~~~

Assert the exact set is present with a non-empty value in `en`, `zhHans`, `zhHant`, `ja`, `ko`, `es`, `fr`, `de`, `pt`, and `it`.

Assert these retired keys/symbols are absent:

~~~swift
[
    "settings.section.voiceWriteAssistant",
    "settings.row.voiceRecordingMode",
    "settings.help.voiceRecordingMode",
    "settings.row.voicePostTranscriptionAction",
    "settings.help.voicePostTranscriptionAction",
    "settings.row.voiceCleanupMode",
    "settings.help.voiceCleanupMode",
    "voice.status.choosingPromptMode",
    "voice.status.polishing",
    "voice.status.inserting",
    "VoiceInputConfig.RecordingMode",
    "VoiceInputConfig.SpeechProfile",
    "VoiceInputConfig.PostTranscriptionAction"
]
~~~

- [ ] **Step 2: Run localization tests and confirm the red state**

Run:

~~~bash
swift test --filter WritingDictationLocalizationTests
swift test --filter VoiceSettingsLocalizationTests
swift test --filter WritingModeLauncherLocalizationTests
~~~

Expected: missing dictation keys and retired voice copy are reported.

- [ ] **Step 3: Add explicit localized strings in every supported table**

Use these English and Simplified Chinese source meanings exactly:

| Key | English | 简体中文 |
| --- | --- | --- |
| `settings.group.writing` | Writing | 写作 |
| `settings.group.dictation` | Dictation | 听写 |
| `settings.group.dictationAdvanced` | Advanced Dictation | 高级听写 |
| `settings.row.dictationShortcut` | Hold shortcut | 长按快捷键 |
| `settings.row.fallbackSpeechEndpoint` | Recovery endpoint | 恢复转写端点 |
| `settings.row.fallbackSpeechModel` | Recovery model | 恢复转写模型 |
| `dictation.hint.hold` | Hold %@ to dictate | 长按 %@ 开始听写 |
| `dictation.status.connecting` | Connecting… | 正在连接… |
| `dictation.status.listening` | Listening… Release to finish | 正在听写…松开以完成 |
| `dictation.status.recordingFallback` | Connection lost… Keep speaking | 连接已断开…可继续说话 |
| `dictation.status.finalizing` | Finishing transcription… | 正在完成转写… |
| `dictation.status.recovering` | Recovering from the temporary recording… | 正在使用临时录音恢复… |
| `dictation.status.ready` | Dictation ready | 听写已就绪 |
| `dictation.error.noSpeech` | No speech was recognized. | 未识别到语音。 |

For the other eight tables, write direct native-language translations with the same meaning; do not rely on the English fallback. Help text must explicitly say:

- the gesture works only while the confirmed Writing source editor is active;
- realtime audio goes to OpenAI while speaking;
- the endpoint/model are used only for the one recovery attempt;
- a temporary local recording is deleted when the session ends.

Remove localized extensions for retired `RecordingMode`, `SpeechProfile`, and `PostTranscriptionAction`. Keep `Shortcut.localizedName` and the legacy History source label for `.voice`.

- [ ] **Step 4: Add phase-only accessibility copy**

Map `WritingDictationCoordinator.Phase` to a status key and an optional announcement key. `connecting` may announce once, `listening`, `finalizing`, `recovering`, `complete`, cancellation, and `failed` each announce once; `delta` events have no localization/accessibility call. Give the source editor `dictation.accessibility.sourceEditor` and the informational microphone a ready/phase-specific label and help text.

- [ ] **Step 5: Add legacy-history and no-new-voice-history tests**

Write a literal legacy JSONL line with `"source":"voice"` to a temporary store and assert it decodes/displays:

~~~swift
func testLegacyVoiceHistoryEntryStillDecodes() throws {
    let entry = HistoryItem(
        id: UUID(),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: .voice,
        inputText: "legacy transcript",
        outputText: "legacy transcript",
        modeName: "Voice Cleanup",
        model: "legacy-speech",
        metadata: ["providerID": "openai"]
    )
    let url = temporaryHistoryURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(entry)
    data.append(0x0A)
    try data.write(to: url)

    let loaded = try JSONLHistoryStore(fileURL: url).load()
    XCTAssertEqual(loaded, [entry])
}
~~~

Add a coordinator harness assertion that realtime/fallback success has no history dependency or callback. Keep the existing Writing transformation test and assert it records one `.write` entry after the user later submits the edited source. Do not add a voice-provenance field to `HistoryItem`.

- [ ] **Step 6: Update the English and Chinese READMEs**

Replace the standalone voice feature/setup/workflow with this exact sequence:

1. Open Writing Assistant with its existing shortcut.
2. Confirm a Prompt Mode.
3. Put the caret in, or select text in, the source draft.
4. Hold the configured Dictation shortcut and speak.
5. Release to finalize; realtime recovery may use the temporary recording once.
6. Edit the draft.
7. Press Return only when ready to run the confirmed Prompt Mode.

State that the shortcut is local to the active Writing source editor, short press does nothing, result-editor/picker dictation is unavailable, release never auto-runs a Prompt or inserts into another app, and the realtime model is fixed. Remove tap/double-tap, voice cleanup automation, voice mode chooser, HUD, and direct insertion instructions.

- [ ] **Step 7: Update privacy and security documentation**

Change `docs/privacy-policy.md` to `Last updated: August 30, 2026` and update `scripts/test-direct-distribution.sh` to require that exact date.

The policy must state:

- active microphone audio is streamed to OpenAI's Realtime transcription service as it is captured;
- one temporary local `.m4a` is written simultaneously for recovery;
- a configured custom endpoint/model applies only to file recovery;
- the file is deleted on success, no speech, fallback success/failure, Escape, focus loss, popover closure, supersession, migration maintenance, and app termination;
- audio/transcript content, Authorization headers, microphone IDs, and temporary paths are not logged;
- audio is never placed on the clipboard or in History;
- an unprocessed dictated draft creates no History entry, while existing legacy Voice entries remain locally readable;
- the OpenAI API key remains in the bundle-specific Keychain service;
- microphone permission is distinct from Accessibility and dictation finalization performs no external insertion.

Update `SECURITY.md` sensitive surfaces with realtime transport authentication, bounded in-memory PCM, terminal-session arbitration, temporary-file deletion, and the rule against logging payloads/headers/paths.

- [ ] **Step 8: Replace the manual voice checklist with the merged workflow matrix**

In `docs/manual-test-checklist.md` keep the disclaimer that it defines required verification and does not claim the items were run. Add checkboxes for:

- mode-picker and result-editor isolation;
- short press, valid long hold, release, rapid repeat, and modifier already held on editor entry;
- caret insertion, selection replacement, CJK/English/mixed/emoji/combining text, and one-step undo;
- manual editing/caret/selection lock during active phases and restoration afterward;
- IME marked-text Escape, active dictation Escape, then normal Writing Escape navigation;
- realtime partial/final, connection failure while held, fallback success, fallback failure, no speech, and late-event races;
- permission not requested on open/mode/short press; permission denied; no device; unplugged selected device; System Default;
- close/focus loss/route change/rapid reopen/app quit in each active phase;
- temporary-file deletion, no draft-only History, unchanged legacy Voice History, and no transcript/audio in logs;
- English/Chinese actual popover width, long localized shortcut/microphone names, phase icon stability, VoiceOver labels, and phase-only announcements.

- [ ] **Step 9: Run localization, history, and documentation contracts**

Run:

~~~bash
swift test --filter WritingDictationLocalizationTests
swift test --filter VoiceSettingsLocalizationTests
swift test --filter WritingModeLauncherLocalizationTests
swift test --filter HistoryStoreTests
swift test --filter DirectDistributionContractTests
bash scripts/test-direct-distribution.sh
~~~

Expected: every command exits 0; all ten language tables contain every key; old Voice History remains readable; public documentation contains the new privacy/workflow contract.

- [ ] **Step 10: Commit localization and documentation**

~~~bash
git add Sources/InkletApp/InkletLocalization.swift \
  Tests/InkletCoreTests/WritingDictationLocalizationTests.swift \
  Tests/InkletCoreTests/VoiceSettingsLocalizationTests.swift \
  Tests/InkletCoreTests/HistoryStoreTests.swift \
  Tests/InkletCoreTests/WritingModeLauncherLocalizationTests.swift \
  Tests/InkletCoreTests/DirectDistributionContractTests.swift \
  README.md README.zh-CN.md SECURITY.md \
  docs/privacy-policy.md docs/manual-test-checklist.md \
  scripts/test-direct-distribution.sh
git commit -m "Document realtime Writing dictation"
~~~

### Task 11: Full Regression, Stable Local App Build, And Manual QA Handoff

**Files:**
- Modify: `VERSION`
- Inspect: all changed files

- [ ] **Step 1: Run the full Swift suite**

Run: `swift test`

Expected: all XCTest and Swift Testing cases pass with zero failures. If a failure appears, use `superpowers:systematic-debugging` before changing implementation and rerun the narrowest failing filter before rerunning the suite.

- [ ] **Step 2: Run strict compilation**

Run: `swift build -Xswiftc -warnings-as-errors`

Expected: exit 0 with no compiler warning promoted to an error.

- [ ] **Step 3: Run distribution/documentation validation**

Run: `bash scripts/test-direct-distribution.sh`

Expected: exit 0 and the final line reports that the direct-distribution checks passed.

- [ ] **Step 4: Inspect privacy-sensitive source and generated logs**

Run:

~~~bash
rg -n "Authorization|appendPCM16|transcript|recordingURL|microphoneDeviceID" \
  Sources/InkletApp Sources/InkletCore
~~~

Review every match. Expected: Authorization is set only on `URLRequest`; operational logs never interpolate keys, PCM/base64, transcript text, microphone device ID, or temporary URL. Remove any unsafe log before proceeding.

Run:

~~~bash
rg -n "HistorySource\\.voice|source: \\.voice|recordHistory" Sources
~~~

Expected: `HistorySource.voice` decode/display compatibility remains, but the new coordinator has no voice-history write path.

- [ ] **Step 5: Bump the substantial-feature version before the bundle build**

Change `VERSION` to:

~~~text
INKLET_VERSION=1.1.0
INKLET_BUILD_NUMBER=6
~~~

Run: `git diff -- VERSION`

Expected: only `1.0.1 → 1.1.0` and `5 → 6`.

- [ ] **Step 6: Build, install, and launch the stable local app**

Run: `scripts/run-local-app.sh`

Expected:

- the script stops an existing matching `Inklet Local` process if necessary;
- it uses the stable configured/detected signing identity without printing it;
- it installs `/Applications/Inklet Local.app` with bundle ID `com.tomwan.inklet.local`;
- signature verification succeeds;
- the installed app launches.

Do not launch a worktree-local `dist` bundle and do not use ad-hoc signing.

- [ ] **Step 7: Record the hardware/UI manual QA boundary**

Automated work must not invoke computer-use for Inklet. Report the following as a user-run checklist unless the user performs it while collaborating:

- first valid hold microphone prompt timing and denial/retry;
- real microphone partial/final quality in Chinese, English, mixed speech, and silence;
- forced realtime network loss with recovery success and dual failure restoration;
- source selection/caret, edit lock, focus restoration, and one-step Undo;
- picker/result/IME isolation and Escape priority;
- rapid reopen, focus loss, close, and app quit cleanup;
- Settings width in English/Chinese, long device names, stable icons, tooltips, accessibility labels, and VoiceOver phase announcements;
- temporary file absence after each terminal path.

- [ ] **Step 8: Run final repository hygiene checks**

Run:

~~~bash
git diff --check
git status --short
git diff --stat
git log --oneline --decorate -12
~~~

Expected: `git diff --check` is silent; status contains only intentional feature/version changes; no `.private`, `.env.local`, signing material, generated package, or secret is present.

- [ ] **Step 9: Commit the version bump**

~~~bash
git add VERSION
git commit -m "Bump Inklet version to 1.1.0"
~~~

- [ ] **Step 10: Perform a final plan-to-spec audit**

Read `docs/superpowers/specs/2026-08-30-writing-realtime-dictation-design.md` from top to bottom and map every bullet in Product Principles, Approved Interaction, Failure Semantics, Settings/Migration, Privacy, Accessibility, Testing, and Verification to a passing test, source location, documentation paragraph, or explicit manual QA item. Correct any uncovered gap, rerun the affected focused test, then rerun `swift test` and `git diff --check` before reporting completion.
