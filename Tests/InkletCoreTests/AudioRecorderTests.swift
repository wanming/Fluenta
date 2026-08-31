import AVFoundation
import CoreMedia
import XCTest
@testable import Inklet

@MainActor
final class AudioRecorderTests: XCTestCase {
    func testRealtimeAudioSettingsAreMono24kSignedLittleEndianInterleavedPCM16() {
        let settings = AudioRecorder.realtimeAudioSettings

        XCTAssertEqual(settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(settings[AVSampleRateKey] as? Int, 24_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsNonInterleaved] as? Bool, false)

        let format = AVAudioFormat(settings: settings)
        XCTAssertEqual(format?.commonFormat, .pcmFormatInt16)
    }

    func testSampleDelegateYieldsBytesInCallbackOrderAndFinishesAfterDrain() async throws {
        let delegate = RealtimeAudioSampleDelegate(bufferLimit: 4)
        let stream = delegate.makeStream()

        delegate.enqueue(Data([1, 2]))
        delegate.enqueue(Data([3, 4]))
        await delegate.finishAfterDraining()

        var values: [Data] = []
        for try await value in stream {
            values.append(value)
        }

        XCTAssertEqual(values, [Data([1, 2]), Data([3, 4])])
    }

    func testSampleDelegateSurfacesOverflowInsteadOfSilentlyDroppingPCM() async {
        let delegate = RealtimeAudioSampleDelegate(bufferLimit: 1)
        let stream = delegate.makeStream()

        delegate.enqueue(Data([1]))
        delegate.enqueue(Data([2]))
        await delegate.finishAfterDraining()

        var values: [Data] = []
        do {
            for try await value in stream {
                values.append(value)
            }
            XCTFail("Expected a realtime buffer overflow")
        } catch let error as AudioRecorder.AudioRecorderError {
            guard case .realtimeBufferOverflow = error else {
                return XCTFail("Expected realtimeBufferOverflow, got \(error)")
            }
        } catch {
            XCTFail("Expected AudioRecorderError, got \(error)")
        }

        XCTAssertEqual(values, [Data([1])])
    }

    func testFinishingAfterDrainTwiceTerminatesStreamOnceWithoutError() async throws {
        let delegate = RealtimeAudioSampleDelegate(bufferLimit: 2)
        let stream = delegate.makeStream()

        delegate.enqueue(Data([7]))
        await delegate.finishAfterDraining()
        await delegate.finishAfterDraining()

        var iterator = stream.makeAsyncIterator()
        let value = try await iterator.next()
        let firstEnd = try await iterator.next()
        let repeatedEnd = try await iterator.next()

        XCTAssertEqual(value, Data([7]))
        XCTAssertNil(firstEnd)
        XCTAssertNil(repeatedEnd)
    }

    func testSampleDelegateCopiesBytesFromSampleBuffer() throws {
        let expected = Data([0, 1, 127, 128, 254, 255])
        let sampleBuffer = try makeSampleBuffer(containing: expected)

        XCTAssertEqual(RealtimeAudioSampleDelegate.data(from: sampleBuffer), expected)
    }

    func testAudioRecorderConformsToDictationAudioCaptureContract() {
        let capture: any DictationAudioCapturing = AudioRecorder()

        XCTAssertTrue(capture is AudioRecorder)
    }

    func testOneCaptureLifecycleStreamsOrderedPCMAndReturnsFinalizedFallbackURL() async throws {
        let recordingURL = makeTemporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        let backend = FakeAudioRecorderCaptureBackend(bufferLimit: 4)
        let removalProbe = RecordingRemovalProbe()
        let recorder = makeRecorder(
            backend: backend,
            recordingURL: recordingURL,
            removalProbe: removalProbe
        )

        let stream = try await recorder.startStreaming(microphoneDeviceID: "test-device")
        XCTAssertTrue(backend.isFallbackRecordingActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))

        backend.emitPCM(Data([1, 2]))
        backend.emitPCM(Data([3, 4]))
        let returnedURL = try await recorder.stop()
        let values = try await collect(stream)

        XCTAssertEqual(values, [Data([1, 2]), Data([3, 4])])
        XCTAssertEqual(returnedURL, recordingURL)
        XCTAssertFalse(backend.isFallbackRecordingActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))
        XCTAssertEqual(backend.events, [.startRecording, .detachRealtime, .finalizeFile, .stopSession])

        await recorder.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))
        XCTAssertEqual(removalProbe.removedURLs, [])
        XCTAssertEqual(backend.detachInvocationCount, 1)
        XCTAssertEqual(backend.finalizeInvocationCount, 1)
        XCTAssertEqual(backend.stopSessionInvocationCount, 1)
    }

    func testRealtimeOverflowLeavesFallbackAvailableForStop() async throws {
        let recordingURL = makeTemporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        let backend = FakeAudioRecorderCaptureBackend(bufferLimit: 1)
        let recorder = makeRecorder(backend: backend, recordingURL: recordingURL)
        let stream = try await recorder.startStreaming(microphoneDeviceID: nil)

        backend.emitPCM(Data([1]))
        backend.emitPCM(Data([2]))
        await backend.waitForPCMDelivery()

        var values: [Data] = []
        do {
            for try await value in stream {
                values.append(value)
            }
            XCTFail("Expected a realtime buffer overflow")
        } catch let error as AudioRecorder.AudioRecorderError {
            guard case .realtimeBufferOverflow = error else {
                return XCTFail("Expected realtimeBufferOverflow, got \(error)")
            }
        }

        XCTAssertEqual(values, [Data([1])])
        XCTAssertTrue(backend.isFallbackRecordingActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))

        let returnedURL = try await recorder.stop()

        XCTAssertEqual(returnedURL, recordingURL)
        XCTAssertFalse(backend.isFallbackRecordingActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))
        XCTAssertEqual(backend.events, [.startRecording, .detachRealtime, .finalizeFile, .stopSession])
    }

    func testCancelDrainsOnceFinalizesStopsAndDeletesTemporaryRecording() async throws {
        let recordingURL = makeTemporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        let backend = FakeAudioRecorderCaptureBackend(bufferLimit: 2)
        let removalProbe = RecordingRemovalProbe()
        let recorder = makeRecorder(
            backend: backend,
            recordingURL: recordingURL,
            removalProbe: removalProbe
        )
        let stream = try await recorder.startStreaming(microphoneDeviceID: nil)
        backend.emitPCM(Data([9]))

        await recorder.cancel()
        let values = try await collect(stream)
        await recorder.cancel()

        XCTAssertEqual(values, [Data([9])])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path))
        XCTAssertEqual(removalProbe.removedURLs, [recordingURL])
        XCTAssertEqual(backend.events, [.startRecording, .detachRealtime, .finalizeFile, .stopSession])
        XCTAssertEqual(backend.detachInvocationCount, 1)
        XCTAssertEqual(backend.finalizeInvocationCount, 1)
        XCTAssertEqual(backend.stopSessionInvocationCount, 1)
    }

    func testStartFailureDetachesFinalizesStopsDeletesAndCannotTerminateTwice() async throws {
        let recordingURL = makeTemporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        let backend = FakeAudioRecorderCaptureBackend(
            bufferLimit: 2,
            startError: FakeCaptureError.couldNotStart
        )
        let removalProbe = RecordingRemovalProbe()
        let recorder = makeRecorder(
            backend: backend,
            recordingURL: recordingURL,
            removalProbe: removalProbe
        )
        let stream = backend.stream

        do {
            _ = try await recorder.startStreaming(microphoneDeviceID: nil)
            XCTFail("Expected start to fail")
        } catch let error as AudioRecorder.AudioRecorderError {
            guard case .recordingUnavailable = error else {
                return XCTFail("Expected recordingUnavailable, got \(error)")
            }
        }

        let values = try await collect(stream)
        XCTAssertEqual(values, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path))
        XCTAssertEqual(removalProbe.removedURLs, [recordingURL])
        XCTAssertEqual(backend.events, [.startRecording, .detachRealtime, .finalizeFile, .stopSession])

        await recorder.cancel()
        do {
            _ = try await recorder.stop()
            XCTFail("Expected a repeated stop to fail")
        } catch let error as AudioRecorder.AudioRecorderError {
            guard case .recordingUnavailable = error else {
                return XCTFail("Expected recordingUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(removalProbe.removedURLs, [recordingURL])
        XCTAssertEqual(backend.detachInvocationCount, 1)
        XCTAssertEqual(backend.finalizeInvocationCount, 1)
        XCTAssertEqual(backend.stopSessionInvocationCount, 1)
    }

    private func makeRecorder(
        backend: FakeAudioRecorderCaptureBackend,
        recordingURL: URL,
        removalProbe: RecordingRemovalProbe = RecordingRemovalProbe()
    ) -> AudioRecorder {
        AudioRecorder(
            captureBackendFactory: { backend },
            recordingURLProvider: { recordingURL },
            removeRecording: { removalProbe.remove($0) }
        )
    }

    private func makeTemporaryRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("inklet-audio-recorder-test-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
    }

    private func collect(
        _ stream: AsyncThrowingStream<Data, Error>
    ) async throws -> [Data] {
        var values: [Data] = []
        for try await value in stream {
            values.append(value)
        }
        return values
    }

    private func makeSampleBuffer(containing data: Data) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let createBlockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(createBlockStatus, noErr)
        let unwrappedBlockBuffer = try XCTUnwrap(blockBuffer)

        let replaceStatus = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: unwrappedBlockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        XCTAssertEqual(replaceStatus, noErr)

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        let createSampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: unwrappedBlockBuffer,
            formatDescription: nil,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(createSampleStatus, noErr)
        return try XCTUnwrap(sampleBuffer)
    }
}

@MainActor
private final class FakeAudioRecorderCaptureBackend: AudioRecorderCaptureBackend {
    enum Event: Equatable {
        case startRecording
        case detachRealtime
        case finalizeFile
        case stopSession
    }

    let stream: AsyncThrowingStream<Data, Error>
    private(set) var events: [Event] = []
    private(set) var isFallbackRecordingActive = false
    private(set) var detachInvocationCount = 0
    private(set) var finalizeInvocationCount = 0
    private(set) var stopSessionInvocationCount = 0

    private let sampleDelegate: RealtimeAudioSampleDelegate
    private let startError: Error?
    private var didDetach = false
    private var didFinalize = false
    private var didStopSession = false

    init(bufferLimit: Int, startError: Error? = nil) {
        let sampleDelegate = RealtimeAudioSampleDelegate(bufferLimit: bufferLimit)
        self.sampleDelegate = sampleDelegate
        stream = sampleDelegate.makeStream()
        self.startError = startError
    }

    func startRecording(to url: URL) async throws {
        events.append(.startRecording)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        isFallbackRecordingActive = true
        if let startError {
            throw startError
        }
    }

    func detachRealtimeAndDrain() async {
        detachInvocationCount += 1
        guard !didDetach else { return }
        didDetach = true
        events.append(.detachRealtime)
        await sampleDelegate.finishAfterDraining()
    }

    func finalizeFile() async throws {
        finalizeInvocationCount += 1
        guard !didFinalize else { return }
        didFinalize = true
        events.append(.finalizeFile)
        isFallbackRecordingActive = false
    }

    func stopSession() {
        stopSessionInvocationCount += 1
        guard !didStopSession else { return }
        didStopSession = true
        events.append(.stopSession)
    }

    func emitPCM(_ data: Data) {
        sampleDelegate.enqueue(data)
    }

    func waitForPCMDelivery() async {
        await withCheckedContinuation { continuation in
            sampleDelegate.queue.async {
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class RecordingRemovalProbe {
    private(set) var removedURLs: [URL] = []

    func remove(_ url: URL) {
        removedURLs.append(url)
        try? FileManager.default.removeItem(at: url)
    }
}

private enum FakeCaptureError: Error {
    case couldNotStart
}
