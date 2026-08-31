import Foundation
import XCTest
@testable import InkletCore

final class OpenAIRealtimeTranscriptionClientTests: XCTestCase {
    func testConnectUsesFixedEndpointAndTrimmedAuthorizationHeader() async throws {
        let transport = FakeRealtimeTransport()
        let client = OpenAIRealtimeTranscriptionClient(
            apiKeyProvider: { "  test-key  " },
            endpoint: URL(string: "wss://api.openai.com/v1/realtime?model=gpt-live-transcribe")!,
            transport: transport
        )
        await transport.enqueue(#"{"type":"session.updated"}"#)

        try await client.connect(timeoutSeconds: 1)
        let snapshot = await transport.snapshot()

        XCTAssertEqual(
            OpenAIRealtimeTranscriptionClient.defaultEndpoint.absoluteString,
            "wss://api.openai.com/v1/realtime?model=gpt-live-transcribe"
        )
        XCTAssertEqual(snapshot.requestURL, "wss://api.openai.com/v1/realtime?model=gpt-live-transcribe")
        XCTAssertEqual(snapshot.authorization, "Bearer test-key")
    }

    func testConnectSendsExactTranscriptionSessionUpdate() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await transport.enqueue(#"{"type":"session.updated"}"#)

        try await client.connect(timeoutSeconds: 1)

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.sentTexts, [
            #"{"type":"session.update","session":{"type":"transcription","audio":{"input":{"format":{"type":"audio/pcm","rate":24000},"transcription":{"model":"gpt-live-transcribe"},"turn_detection":null}}}}"#
        ])
    }

    func testBlankKeyFailsBeforeConnecting() async {
        let transport = FakeRealtimeTransport()
        let client = OpenAIRealtimeTranscriptionClient(
            apiKeyProvider: { " \n " },
            endpoint: URL(string: "wss://api.openai.com/v1/realtime?model=gpt-live-transcribe")!,
            transport: transport
        )

        await assertThrowsRealtime(.missingAPIKey) {
            try await client.connect(timeoutSeconds: 1)
        }

        let snapshot = await transport.snapshot()
        XCTAssertNil(snapshot.requestURL)
    }

    func testInvalidEndpointFailsBeforeConnecting() async {
        let transport = FakeRealtimeTransport()
        let client = OpenAIRealtimeTranscriptionClient(
            apiKeyProvider: { "key" },
            endpoint: URL(string: "https://api.openai.com/v1/realtime")!,
            transport: transport
        )

        await assertThrowsRealtime(.invalidEndpoint) {
            try await client.connect(timeoutSeconds: 1)
        }
        let snapshot = await transport.snapshot()
        XCTAssertNil(snapshot.requestURL)
    }

    func testInsecureWebSocketEndpointFailsBeforeConnecting() async {
        let transport = FakeRealtimeTransport()
        let client = OpenAIRealtimeTranscriptionClient(
            apiKeyProvider: { "key" },
            endpoint: URL(string: "ws://api.openai.com/v1/realtime")!,
            transport: transport
        )
        await assertThrowsRealtime(.invalidEndpoint) { try await client.connect(timeoutSeconds: 1) }
        let snapshot = await transport.snapshot()
        XCTAssertNil(snapshot.requestURL)
    }

    func testEndpointWithoutHostFailsBeforeConnecting() async {
        let transport = FakeRealtimeTransport()
        let client = OpenAIRealtimeTranscriptionClient(
            apiKeyProvider: { "key" },
            endpoint: URL(string: "wss:/v1/realtime")!,
            transport: transport
        )

        await assertThrowsRealtime(.invalidEndpoint) {
            try await client.connect(timeoutSeconds: 1)
        }

        let snapshot = await transport.snapshot()
        XCTAssertNil(snapshot.requestURL)
    }

    func testHandshakeSkipsSessionCreatedUntilSessionUpdated() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await transport.enqueue(#"{"type":"session.created"}"#)
        await transport.enqueue(#"{"type":"session.updated"}"#)

        try await client.connect(timeoutSeconds: 1)
    }

    func testHandshakeServerErrorMapsToRealtimeServerError() async {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await transport.enqueue(#"{"type":"error","error":{"code":"invalid_api_key","message":"not accepted"}}"#)

        await assertThrowsRealtime(.server(code: "invalid_api_key", message: "not accepted")) {
            try await client.connect(timeoutSeconds: 1)
        }
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
    }

    func testHandshakeRejectsMalformedMessage() async {
        for message in [
            #"{"type":"error","error":{"message":true}}"#,
            #"{"type":"error","error":{"code":true,"message":"rejected"}}"#,
            #"{"type":true}"#
        ] {
            let transport = FakeRealtimeTransport()
            let client = makeClient(transport: transport)
            await transport.enqueue(message)

            await assertThrowsRealtime(.invalidMessage) {
                try await client.connect(timeoutSeconds: 1)
            }
        }
    }

    func testConnectTimeoutClosesTransport() async {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)

        await assertThrowsRealtime(.connectionTimedOut) {
            try await client.connect(timeoutSeconds: 0.01)
        }
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
    }

    func testAppendEncodesPCM16AsBase64() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)

        try await client.appendPCM16(Data([0x00, 0x01, 0xFE, 0xFF]))

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.sentTexts.last, #"{"type":"input_audio_buffer.append","audio":"AAH+/w=="}"#)
    }

    func testEmptyAppendIsInvalidState() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)

        await assertThrowsRealtime(.invalidState) {
            try await client.appendPCM16(Data())
        }
    }

    func testAppendBeforeReadyIsInvalidState() async {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)

        await assertThrowsRealtime(.invalidState) {
            try await client.appendPCM16(Data([1]))
        }
    }

    func testCommitAndReceiveBeforeReadyAreInvalidState() async {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)

        await assertThrowsRealtime(.invalidState) {
            try await client.commit()
        }
        await assertThrowsRealtime(.invalidState) {
            _ = try await client.nextEvent()
        }
    }

    func testAppendAfterCommitIsInvalidState() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)
        try await client.commit()

        await assertThrowsRealtime(.invalidState) {
            try await client.appendPCM16(Data([1]))
        }
    }

    func testCommitSendsOneWireMessageAndIsIdempotent() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)

        try await client.commit()
        try await client.commit()

        let snapshot = await transport.snapshot()
        XCTAssertEqual(
            snapshot.sentTexts.filter { $0 == #"{"type":"input_audio_buffer.commit"}"# },
            [#"{"type":"input_audio_buffer.commit"}"#]
        )
    }

    func testOutboundOperationsRemainOrderedAndConcurrentCommitSharesSuccess() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)
        await transport.blockNextSend()

        let append = Task { try await client.appendPCM16(Data([1])) }
        await transport.waitUntilSendIsPending()
        let firstCommit = Task { try await client.commit() }
        let secondCommit = Task { try await client.commit() }
        await client.waitForOutboundMilestone(queuedCount: 2, commitWaiterCount: 2, waitingOnPredecessorCount: 1)

        await transport.resumeBlockedSend()
        try await append.value
        try await firstCommit.value
        try await secondCommit.value

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.phaseLog.suffix(4), ["appendStarted", "appendCompleted", "commitStarted", "commitCompleted"])
        XCTAssertEqual(snapshot.startedTexts.filter { $0 == #"{"type":"input_audio_buffer.commit"}"# }.count, 1)
        XCTAssertEqual(snapshot.completedTexts.filter { $0 == #"{"type":"input_audio_buffer.commit"}"# }.count, 1)
    }

    func testConcurrentCommitSharesFailure() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)
        await transport.blockNextSend()

        let first = Task { try await client.commit() }
        await transport.waitUntilSendIsPending()
        let second = Task { try await client.commit() }
        await client.waitForOutboundMilestone(queuedCount: 1, commitWaiterCount: 2, waitingOnPredecessorCount: 0)
        await transport.resumeBlockedSend(throwing: .sendFailed)

        await assertTaskThrowsRealtime(first, .connectionClosed)
        await assertTaskThrowsRealtime(second, .connectionClosed)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.startedTexts.filter { $0 == #"{"type":"input_audio_buffer.commit"}"# }.count, 1)
        XCTAssertEqual(snapshot.completedTexts.filter { $0 == #"{"type":"input_audio_buffer.commit"}"# }.count, 0)
        XCTAssertEqual(snapshot.closeCount, 1)
    }

    func testNextEventParsesDeltaWithOptionalSequence() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)
        await transport.enqueue(#"{"type":"conversation.item.input_audio_transcription.delta","event_id":"evt","item_id":"item","content_index":2,"delta":"hello"}"#)

        let event = try await client.nextEvent()

        XCTAssertEqual(event, .delta(eventID: "evt", sequence: nil, itemID: "item", contentIndex: 2, text: "hello"))
    }

    func testNextEventParsesCompletedWithSequence() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)
        await transport.enqueue(#"{"type":"conversation.item.input_audio_transcription.completed","sequence":9,"item_id":"item","content_index":0,"transcript":"hello world"}"#)

        let event = try await client.nextEvent()

        XCTAssertEqual(event, .completed(eventID: nil, sequence: 9, itemID: "item", contentIndex: 0, transcript: "hello world"))
    }

    func testNextEventRejectsWrongTypedRelevantFields() async throws {
        let invalidMessages = [
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item","content_index":true,"delta":"text"}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","sequence":true,"item_id":"item","content_index":0,"delta":"text"}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","sequence":1.5,"item_id":"item","content_index":0,"delta":"text"}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item","content_index":9223372036854775808,"delta":"text"}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":1,"content_index":0,"delta":"text"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":true,"item_id":"item","content_index":0,"transcript":"text"}"#
        ]

        for message in invalidMessages {
            let transport = FakeRealtimeTransport()
            let client = makeClient(transport: transport)
            await connect(client, transport: transport)
            await transport.enqueue(message)

            await assertThrowsRealtime(.invalidMessage) {
                _ = try await client.nextEvent()
            }
        }
    }

    func testNextEventSkipsIrrelevantEvents() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)
        await transport.enqueue(#"{"type":"input_audio_buffer.committed"}"#)
        await transport.enqueue(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item","content_index":0,"delta":"next"}"#)

        let event = try await client.nextEvent()
        XCTAssertEqual(event, .delta(eventID: nil, sequence: nil, itemID: "item", contentIndex: 0, text: "next"))
    }

    func testNextEventSkipsIrrelevantEventsBeforeDecodingTheirFields() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)
        await transport.enqueue(#"{"type":"rate_limits.updated","event_id":true,"sequence":true}"#)
        await transport.enqueue(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item","content_index":0,"delta":"next"}"#)
        let event = try await client.nextEvent()
        XCTAssertEqual(event, .delta(eventID: nil, sequence: nil, itemID: "item", contentIndex: 0, text: "next"))
    }

    func testCancellationClosesBlockedConnectAppendCommitAndReceive() async throws {
        let connectTransport = FakeRealtimeTransport()
        await connectTransport.blockNextConnect()
        let connectClient = makeClient(transport: connectTransport)
        let connectTask = Task { try await connectClient.connect(timeoutSeconds: 10) }
        await connectTransport.waitUntilConnectIsPending()
        connectTask.cancel()
        await assertTaskIsCancelled(connectTask)
        let connectSnapshot = await connectTransport.snapshot()
        XCTAssertEqual(connectSnapshot.closeCount, 1)

        for operation in ["append", "commit", "receive"] {
            let transport = FakeRealtimeTransport()
            let client = makeClient(transport: transport)
            await connect(client, transport: transport)
            let task: Task<Void, Error>
            switch operation {
            case "append":
                await transport.blockNextSend()
                task = Task { try await client.appendPCM16(Data([1])) }
                await transport.waitUntilSendIsPending()
            case "commit":
                await transport.blockNextSend()
                task = Task { try await client.commit() }
                await transport.waitUntilSendIsPending()
            default:
                task = Task { _ = try await client.nextEvent() }
                await transport.waitUntilReceiveIsPending()
            }
            task.cancel()
            await assertTaskIsCancelled(task)
            let snapshot = await transport.snapshot()
            XCTAssertEqual(snapshot.closeCount, 1)
            XCTAssertEqual(snapshot.pendingOperationCount, 0)
        }
    }

    func testNextEventMapsServerError() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)
        await transport.enqueue(#"{"type":"error","error":{"message":"rejected"}}"#)

        await assertThrowsRealtime(.server(code: nil, message: "rejected")) {
            _ = try await client.nextEvent()
        }
    }

    func testNextEventRejectsMalformedJSONAndRelevantMissingFields() async throws {
        let malformedTransport = FakeRealtimeTransport()
        let malformedClient = makeClient(transport: malformedTransport)
        await connect(malformedClient, transport: malformedTransport)
        await malformedTransport.enqueue("{")
        await assertThrowsRealtime(.invalidMessage) {
            _ = try await malformedClient.nextEvent()
        }

        let incompleteTransport = FakeRealtimeTransport()
        let incompleteClient = makeClient(transport: incompleteTransport)
        await connect(incompleteClient, transport: incompleteTransport)
        await incompleteTransport.enqueue(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item"}"#)
        await assertThrowsRealtime(.invalidMessage) {
            _ = try await incompleteClient.nextEvent()
        }
    }

    func testConcurrentNextEventIsInvalidState() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)

        let first: Task<RealtimeTranscriptionEvent, Error> = Task { try await client.nextEvent() }
        await transport.waitUntilReceiveIsPending()
        await assertThrowsRealtime(.invalidState) {
            _ = try await client.nextEvent()
        }
        await transport.enqueue(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item","content_index":0,"delta":"one"}"#)
        _ = try await first.value
    }

    func testSecondConnectDuringHandshakeIsInvalidState() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        let first: Task<Void, Error> = Task { try await client.connect(timeoutSeconds: 1) }

        await transport.waitUntilReceiveIsPending()
        await assertThrowsRealtime(.invalidState) {
            try await client.connect(timeoutSeconds: 1)
        }
        await transport.enqueue(#"{"type":"session.updated"}"#)
        try await first.value

        await assertThrowsRealtime(.invalidState) {
            try await client.connect(timeoutSeconds: 1)
        }
    }

    func testCloseIsIdempotentAndDisablesFurtherOperations() async throws {
        let transport = FakeRealtimeTransport()
        let client = makeClient(transport: transport)
        await connect(client, transport: transport)

        await client.close()
        await client.close()

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
        await assertThrowsRealtime(.invalidState) { try await client.appendPCM16(Data([1])) }
        await assertThrowsRealtime(.invalidState) { try await client.commit() }
        await assertThrowsRealtime(.invalidState) { _ = try await client.nextEvent() }
    }

    private func makeClient(transport: FakeRealtimeTransport) -> OpenAIRealtimeTranscriptionClient {
        OpenAIRealtimeTranscriptionClient(
            apiKeyProvider: { "test-key" },
            endpoint: URL(string: "wss://api.openai.com/v1/realtime?model=gpt-live-transcribe")!,
            transport: transport
        )
    }

    private func connect(_ client: OpenAIRealtimeTranscriptionClient, transport: FakeRealtimeTransport) async {
        await transport.enqueue(#"{"type":"session.updated"}"#)
        do {
            try await client.connect(timeoutSeconds: 1)
        } catch {
            XCTFail("Expected connected client: \(error)")
        }
    }

    private func assertThrowsRealtime(
        _ expected: RealtimeTranscriptionError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? RealtimeTranscriptionError, expected)
        }
    }

    private func assertTaskThrowsRealtime<T>(_ task: Task<T, Error>, _ expected: RealtimeTranscriptionError) async {
        do { _ = try await task.value; XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? RealtimeTranscriptionError, expected) }
    }

    private func assertTaskIsCancelled<T>(_ task: Task<T, Error>) async {
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private actor FakeRealtimeTransport: RealtimeWebSocketTransport {
    struct Snapshot: Sendable {
        var requestURL: String?
        var authorization: String?
        var sentTexts: [String]
        var startedTexts: [String]
        var completedTexts: [String]
        var phaseLog: [String]
        var closeCount: Int
        var pendingOperationCount: Int
    }

    private var request: URLRequest?
    private var sentTexts: [String] = []
    private var startedTexts: [String] = []
    private var completedTexts: [String] = []
    private var phaseLog: [String] = []
    private var queuedText: [String] = []
    private var receiveContinuations: [CheckedContinuation<String, Error>] = []
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var sendContinuation: CheckedContinuation<Void, Error>?
    private var blockConnect = false
    private var blockSend = false
    private var closeCount = 0

    func connect(_ request: URLRequest) async throws {
        self.request = request
        if blockConnect {
            blockConnect = false
            try await withCheckedThrowingContinuation { connectContinuation = $0 }
        }
    }

    func send(text: String) async throws {
        sentTexts.append(text)
        startedTexts.append(text)
        phaseLog.append(text.contains("input_audio_buffer.append") ? "appendStarted" : text.contains("input_audio_buffer.commit") ? "commitStarted" : "otherStarted")
        if blockSend {
            blockSend = false
            try await withCheckedThrowingContinuation { sendContinuation = $0 }
        }
        completedTexts.append(text)
        phaseLog.append(text.contains("input_audio_buffer.append") ? "appendCompleted" : text.contains("input_audio_buffer.commit") ? "commitCompleted" : "otherCompleted")
    }

    func receiveText() async throws -> String {
        if !queuedText.isEmpty {
            return queuedText.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuations.append(continuation)
        }
    }

    func close() async {
        closeCount += 1
        let continuations = receiveContinuations
        receiveContinuations.removeAll()
        let connectContinuation = connectContinuation
        self.connectContinuation = nil
        let sendContinuation = sendContinuation
        self.sendContinuation = nil
        connectContinuation?.resume(throwing: URLError(.cancelled))
        sendContinuation?.resume(throwing: URLError(.cancelled))
        for continuation in continuations {
            continuation.resume(throwing: URLError(.cancelled))
        }
    }

    func enqueue(_ text: String) {
        if !receiveContinuations.isEmpty {
            receiveContinuations.removeFirst().resume(returning: text)
        } else {
            queuedText.append(text)
        }
    }

    func waitUntilReceiveIsPending() async {
        while receiveContinuations.isEmpty {
            await Task.yield()
        }
    }

    func blockNextConnect() { blockConnect = true }
    func blockNextSend() { blockSend = true }
    func waitUntilConnectIsPending() async { while connectContinuation == nil { await Task.yield() } }
    func waitUntilSendIsPending() async { while sendContinuation == nil { await Task.yield() } }
    func resumeBlockedSend(throwing error: FakeTransportError? = nil) {
        let continuation = sendContinuation
        sendContinuation = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            requestURL: request?.url?.absoluteString,
            authorization: request?.value(forHTTPHeaderField: "Authorization"),
            sentTexts: sentTexts,
            startedTexts: startedTexts,
            completedTexts: completedTexts,
            phaseLog: phaseLog,
            closeCount: closeCount,
            pendingOperationCount: receiveContinuations.count + (connectContinuation == nil ? 0 : 1) + (sendContinuation == nil ? 0 : 1)
        )
    }
}

private enum FakeTransportError: Error, Sendable { case sendFailed }
