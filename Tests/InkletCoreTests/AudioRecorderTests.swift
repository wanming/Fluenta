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

    func testCaptureGraphConfiguratorAttachesChosenInputAndBothOutputsToOneSession() throws {
        let session = GraphConfigurationToken(name: "capture-session")
        let chosenInput = GraphConfigurationToken(name: "chosen-input")
        let fileOutput = GraphConfigurationToken(name: "file-output")
        let dataOutput = GraphConfigurationToken(name: "data-output")
        let sampleDelegate = GraphConfigurationToken(name: "sample-delegate")
        let sampleQueue = GraphConfigurationToken(name: "sample-queue")
        var configuredSettings: [String: Any]?
        var configuredDelegate: GraphConfigurationToken?
        var configuredSampleQueue: GraphConfigurationToken?
        var addedInput: GraphConfigurationToken?
        var addedFileOutput: GraphConfigurationToken?
        var addedDataOutput: GraphConfigurationToken?
        var observedSessions: [GraphConfigurationToken] = []
        var events: [String] = []

        try AudioRecorderCaptureGraphConfigurator.configure(
            session: session,
            input: chosenInput,
            fileOutput: fileOutput,
            dataOutput: dataOutput,
            sampleDelegate: sampleDelegate,
            sampleQueue: sampleQueue,
            realtimeSettings: AudioRecorder.realtimeAudioSettings,
            canAddInput: { receivedSession, input in
                observedSessions.append(receivedSession)
                return input === chosenInput
            },
            canAddFileOutput: { receivedSession, output in
                observedSessions.append(receivedSession)
                return output === fileOutput
            },
            canAddDataOutput: { receivedSession, output in
                observedSessions.append(receivedSession)
                return output === dataOutput
            },
            applyRealtimeConfiguration: { receivedSession, output, settings, delegate, queue in
                observedSessions.append(receivedSession)
                XCTAssertTrue(output === dataOutput)
                configuredSettings = settings
                configuredDelegate = delegate
                configuredSampleQueue = queue
                events.append("configure-realtime")
            },
            beginConfiguration: { receivedSession in
                observedSessions.append(receivedSession)
                events.append("begin")
            },
            addInput: { receivedSession, input in
                observedSessions.append(receivedSession)
                addedInput = input
                events.append("add-input")
            },
            addFileOutput: { receivedSession, output in
                observedSessions.append(receivedSession)
                addedFileOutput = output
                events.append("add-file-output")
            },
            addDataOutput: { receivedSession, output in
                observedSessions.append(receivedSession)
                addedDataOutput = output
                events.append("add-data-output")
            },
            commitConfiguration: { receivedSession in
                observedSessions.append(receivedSession)
                events.append("commit")
            }
        )

        XCTAssertTrue(addedInput === chosenInput)
        XCTAssertTrue(addedFileOutput === fileOutput)
        XCTAssertTrue(addedDataOutput === dataOutput)
        XCTAssertTrue(configuredDelegate === sampleDelegate)
        XCTAssertTrue(configuredSampleQueue === sampleQueue)
        XCTAssertTrue(observedSessions.allSatisfy { $0 === session })
        XCTAssertEqual(configuredSettings?[AVSampleRateKey] as? Int, 24_000)
        XCTAssertEqual(configuredSettings?[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(
            events,
            ["configure-realtime", "begin", "add-input", "add-file-output", "add-data-output", "commit"]
        )
    }

    func testAVFoundationBackendRunsBlockingGraphLifecycleOffMainActorInOrder() async throws {
        let captureExecutor = AudioRecorderCaptureExecutor(
            label: "com.tomwan.inklet.tests.audio-capture"
        )
        let graph = FakeAudioRecorderCaptureSessionGraph()
        let backend = AVFoundationAudioRecorderCaptureBackend(
            graph: graph,
            captureExecutor: captureExecutor
        )
        let recordingURL = makeTemporaryRecordingURL()

        try await backend.startRecording(to: recordingURL)
        await backend.detachRealtimeAndDrain()
        try await backend.finalizeFile()
        await backend.stopSession()

        XCTAssertEqual(
            graph.blockingEvents,
            [.startRecording, .detachRealtime, .finalizeFile, .stopSession]
        )
        XCTAssertEqual(graph.blockingCallWasOnMainThread, [false, false, false, false])
    }

    func testBackendFactoryBuildsChosenDeviceGraphOnCaptureExecutor() async throws {
        let captureExecutor = AudioRecorderCaptureExecutor(
            label: "com.tomwan.inklet.tests.audio-graph-factory"
        )
        let graph = FakeAudioRecorderCaptureSessionGraph()
        let probe = GraphFactoryProbe()

        _ = try await AVFoundationAudioRecorderCaptureBackend.make(
            deviceID: "chosen-device",
            captureExecutor: captureExecutor,
            graphFactory: { deviceID in
                probe.record(deviceID: deviceID, isMainThread: Thread.isMainThread)
                return graph
            }
        )

        XCTAssertEqual(probe.deviceIDs, ["chosen-device"])
        XCTAssertEqual(probe.wasOnMainThread, [false])
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

    func testPCMExtractionReportsMissingBlockBufferAsFailure() {
        XCTAssertEqual(
            RealtimeAudioSampleDelegate.extraction(from: nil),
            .failure
        )
    }

    func testPCMExtractionReportsMalformedNegativeLengthAsFailure() throws {
        let sampleBuffer = try makeSampleBuffer(containing: Data([1]))
        let blockBuffer = try XCTUnwrap(CMSampleBufferGetDataBuffer(sampleBuffer))

        XCTAssertEqual(
            RealtimeAudioSampleDelegate.extraction(
                from: blockBuffer,
                dataLength: { _ in -1 }
            ),
            .failure
        )
    }

    func testPCMExtractionTreatsZeroLengthCallbackAsBenignEmptyAudio() throws {
        let sampleBuffer = try makeSampleBuffer(containing: Data([1]))
        let blockBuffer = try XCTUnwrap(CMSampleBufferGetDataBuffer(sampleBuffer))

        XCTAssertEqual(
            RealtimeAudioSampleDelegate.extraction(
                from: blockBuffer,
                dataLength: { _ in 0 }
            ),
            .empty
        )
    }

    func testPCMExtractionReportsCopyFailure() throws {
        let sampleBuffer = try makeSampleBuffer(containing: Data([1, 2]))
        let blockBuffer = try XCTUnwrap(CMSampleBufferGetDataBuffer(sampleBuffer))

        XCTAssertEqual(
            RealtimeAudioSampleDelegate.extraction(
                from: blockBuffer,
                copyBytes: { _, _, _ in -1 }
            ),
            .failure
        )
    }

    func testAudioRecorderConformsToDictationAudioCaptureContract() {
        let capture: any DictationAudioCapturing = AudioRecorder()

        XCTAssertTrue(capture is AudioRecorder)
    }

    func testCancelWhilePermissionIsPendingPreventsBackendResolutionAndCaptureStart() async {
        let permissionGate = AsyncValueGate<Bool>()
        let backend = FakeAudioRecorderCaptureBackend(bufferLimit: 2)
        var backendResolutionCount = 0
        let recorder = AudioRecorder(
            microphonePermissionResolver: {
                await permissionGate.wait()
            },
            captureBackendResolver: { _ in
                backendResolutionCount += 1
                return backend
            }
        )

        let startTask = Task {
            try await recorder.startStreaming(microphoneDeviceID: "test-device")
        }
        await permissionGate.waitUntilWaiting()

        await recorder.cancel()
        permissionGate.resume(returning: true)

        do {
            _ = try await startTask.value
            XCTFail("Expected the pending start to be cancelled")
        } catch is CancellationError {
            // Expected: cancellation is not surfaced as a recorder failure.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(backendResolutionCount, 0)
        XCTAssertEqual(backend.events, [])
    }

    func testTaskCancellationWhilePermissionIsPendingPreventsCaptureStart() async {
        let permissionGate = AsyncValueGate<Bool>()
        let backend = FakeAudioRecorderCaptureBackend(bufferLimit: 2)
        var backendResolutionCount = 0
        let recorder = AudioRecorder(
            microphonePermissionResolver: {
                await permissionGate.wait()
            },
            captureBackendResolver: { _ in
                backendResolutionCount += 1
                return backend
            }
        )

        let startTask = Task {
            try await recorder.startStreaming(microphoneDeviceID: nil)
        }
        await permissionGate.waitUntilWaiting()
        startTask.cancel()
        permissionGate.resume(returning: true)

        do {
            _ = try await startTask.value
            XCTFail("Expected the task cancellation to win")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(backendResolutionCount, 0)
        XCTAssertEqual(backend.events, [])
    }

    func testOlderStartResolvingAfterNewerStartCannotCancelOrStartOverNewCapture() async throws {
        let firstResolutionGate = AsyncValueGate<any AudioRecorderCaptureBackend>()
        let secondResolutionGate = AsyncValueGate<any AudioRecorderCaptureBackend>()
        let firstBackend = FakeAudioRecorderCaptureBackend(bufferLimit: 2)
        let secondBackend = FakeAudioRecorderCaptureBackend(bufferLimit: 2)
        let firstURL = makeTemporaryRecordingURL()
        let secondURL = makeTemporaryRecordingURL()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        var recordingURLs = [firstURL, secondURL]
        let removalProbe = RecordingRemovalProbe()
        let recorder = AudioRecorder(
            microphonePermissionResolver: { true },
            captureBackendResolver: { deviceID in
                if deviceID == "first" {
                    return await firstResolutionGate.wait()
                }
                return await secondResolutionGate.wait()
            },
            recordingURLProvider: { recordingURLs.removeFirst() },
            removeRecording: { removalProbe.remove($0) }
        )

        let firstStart = Task {
            try await recorder.startStreaming(microphoneDeviceID: "first")
        }
        await firstResolutionGate.waitUntilWaiting()

        let secondStart = Task {
            try await recorder.startStreaming(microphoneDeviceID: "second")
        }
        await secondResolutionGate.waitUntilWaiting()
        secondResolutionGate.resume(returning: secondBackend)
        _ = try await secondStart.value

        firstResolutionGate.resume(returning: firstBackend)
        do {
            _ = try await firstStart.value
            XCTFail("Expected the superseded start to be cancelled")
        } catch is CancellationError {
            // Expected: an older start is stale, not a recorder failure.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(firstBackend.events, [.detachRealtime, .finalizeFile, .stopSession])
        XCTAssertEqual(secondBackend.events, [.startRecording])
        XCTAssertEqual(removalProbe.removedURLs, [firstURL])
        XCTAssertTrue(secondBackend.isFallbackRecordingActive)

        let returnedURL = try await recorder.stop()
        XCTAssertEqual(returnedURL, secondURL)
        XCTAssertEqual(
            secondBackend.events,
            [.startRecording, .detachRealtime, .finalizeFile, .stopSession]
        )
    }

    func testStaleResolutionFailureCannotSurfaceRecorderErrorOrTerminateNewCapture() async throws {
        let firstResolutionGate = AsyncValueGate<Void>()
        let secondBackend = FakeAudioRecorderCaptureBackend(bufferLimit: 2)
        let firstURL = makeTemporaryRecordingURL()
        let secondURL = makeTemporaryRecordingURL()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        var recordingURLs = [firstURL, secondURL]
        let removalProbe = RecordingRemovalProbe()
        let recorder = AudioRecorder(
            microphonePermissionResolver: { true },
            captureBackendResolver: { deviceID in
                if deviceID == "first" {
                    _ = await firstResolutionGate.wait()
                    throw FakeCaptureError.couldNotCreateBackend
                }
                return secondBackend
            },
            recordingURLProvider: { recordingURLs.removeFirst() },
            removeRecording: { removalProbe.remove($0) }
        )

        let firstStart = Task {
            try await recorder.startStreaming(microphoneDeviceID: "first")
        }
        await firstResolutionGate.waitUntilWaiting()
        _ = try await recorder.startStreaming(microphoneDeviceID: "second")

        firstResolutionGate.resume(returning: ())
        do {
            _ = try await firstStart.value
            XCTFail("Expected the stale start to be cancelled")
        } catch is CancellationError {
            // Expected: the stale backend failure is deliberately suppressed.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(secondBackend.events, [.startRecording])
        XCTAssertTrue(secondBackend.isFallbackRecordingActive)
        XCTAssertEqual(removalProbe.removedURLs, [firstURL])
        let returnedURL = try await recorder.stop()
        XCTAssertEqual(returnedURL, secondURL)
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

    func testMalformedRealtimePCMEndsStreamButFallbackRemainsAvailableForStop() async throws {
        let recordingURL = makeTemporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        let backend = FakeAudioRecorderCaptureBackend(bufferLimit: 2)
        let recorder = makeRecorder(backend: backend, recordingURL: recordingURL)
        let stream = try await recorder.startStreaming(microphoneDeviceID: nil)

        backend.emitMalformedPCM()
        await backend.waitForPCMDelivery()

        do {
            _ = try await collect(stream)
            XCTFail("Expected malformed realtime PCM to end the stream")
        } catch let error as AudioRecorder.AudioRecorderError {
            guard case .realtimeAudioUnavailable = error else {
                return XCTFail("Expected realtimeAudioUnavailable, got \(error)")
            }
        } catch {
            XCTFail("Expected AudioRecorderError, got \(error)")
        }

        XCTAssertTrue(backend.isFallbackRecordingActive)
        let returnedURL = try await recorder.stop()
        XCTAssertEqual(returnedURL, recordingURL)
        XCTAssertEqual(
            backend.events,
            [.startRecording, .detachRealtime, .finalizeFile, .stopSession]
        )
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

    func testThrowingBackendFactoryMapsErrorAndDeletesOwnedTemporaryURLOnce() async {
        let recordingURL = makeTemporaryRecordingURL()
        let removalProbe = RecordingRemovalProbe()
        let recorder = AudioRecorder(
            captureBackendFactory: {
                throw FakeCaptureError.couldNotCreateBackend
            },
            recordingURLProvider: { recordingURL },
            removeRecording: { removalProbe.remove($0) }
        )

        do {
            _ = try await recorder.startStreaming(microphoneDeviceID: "test-device")
            XCTFail("Expected backend construction to fail")
        } catch let error as AudioRecorder.AudioRecorderError {
            guard case .recordingUnavailable = error else {
                return XCTFail("Expected recordingUnavailable, got \(error)")
            }
        } catch {
            XCTFail("Expected AudioRecorderError, got \(error)")
        }

        await recorder.cancel()
        XCTAssertEqual(removalProbe.removedURLs, [recordingURL])
    }

    func testFinalizeFailureStillDetachesStopsAndDeletesFallbackRecording() async throws {
        let recordingURL = makeTemporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        let backend = FakeAudioRecorderCaptureBackend(
            bufferLimit: 2,
            finalizeError: FakeCaptureError.couldNotFinalize
        )
        let removalProbe = RecordingRemovalProbe()
        let recorder = makeRecorder(
            backend: backend,
            recordingURL: recordingURL,
            removalProbe: removalProbe
        )
        let stream = try await recorder.startStreaming(microphoneDeviceID: nil)
        backend.emitPCM(Data([5]))

        do {
            _ = try await recorder.stop()
            XCTFail("Expected finalization to fail")
        } catch let error as AudioRecorder.AudioRecorderError {
            guard case .recordingUnavailable = error else {
                return XCTFail("Expected recordingUnavailable, got \(error)")
            }
        }

        let streamedValues = try await collect(stream)
        XCTAssertEqual(streamedValues, [Data([5])])
        XCTAssertEqual(backend.events, [.startRecording, .detachRealtime, .finalizeFile, .stopSession])
        XCTAssertEqual(removalProbe.removedURLs, [recordingURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path))

        await recorder.cancel()
        XCTAssertEqual(removalProbe.removedURLs, [recordingURL])
        XCTAssertEqual(backend.stopSessionInvocationCount, 1)
    }

    func testStopWinsAgainstConcurrentCancelAndReturnsFallbackWithoutDeletingIt() async throws {
        let recordingURL = makeTemporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        let detachGate = AsyncValueGate<Void>()
        let backend = FakeAudioRecorderCaptureBackend(
            bufferLimit: 2,
            detachGate: detachGate
        )
        let removalProbe = RecordingRemovalProbe()
        let recorder = makeRecorder(
            backend: backend,
            recordingURL: recordingURL,
            removalProbe: removalProbe
        )
        _ = try await recorder.startStreaming(microphoneDeviceID: nil)

        let stopTask = Task {
            try await recorder.stop()
        }
        await detachGate.waitUntilWaiting()
        await recorder.cancel()
        detachGate.resume(returning: ())

        let returnedURL = try await stopTask.value
        XCTAssertEqual(returnedURL, recordingURL)
        XCTAssertEqual(removalProbe.removedURLs, [])
        XCTAssertEqual(backend.detachInvocationCount, 1)
        XCTAssertEqual(backend.finalizeInvocationCount, 1)
        XCTAssertEqual(backend.stopSessionInvocationCount, 1)
    }

    func testCancelWinsAgainstConcurrentStopAndDeletesFallbackOnce() async throws {
        let recordingURL = makeTemporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        let detachGate = AsyncValueGate<Void>()
        let backend = FakeAudioRecorderCaptureBackend(
            bufferLimit: 2,
            detachGate: detachGate
        )
        let removalProbe = RecordingRemovalProbe()
        let recorder = makeRecorder(
            backend: backend,
            recordingURL: recordingURL,
            removalProbe: removalProbe
        )
        _ = try await recorder.startStreaming(microphoneDeviceID: nil)

        let cancelTask = Task {
            await recorder.cancel()
        }
        await detachGate.waitUntilWaiting()

        do {
            _ = try await recorder.stop()
            XCTFail("Expected cancel to own the terminal lifecycle")
        } catch let error as AudioRecorder.AudioRecorderError {
            guard case .recordingUnavailable = error else {
                return XCTFail("Expected recordingUnavailable, got \(error)")
            }
        }

        detachGate.resume(returning: ())
        await cancelTask.value
        await recorder.cancel()

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
    private let finalizeError: Error?
    private let detachGate: AsyncValueGate<Void>?
    private var didDetach = false
    private var didFinalize = false
    private var didStopSession = false

    init(
        bufferLimit: Int,
        startError: Error? = nil,
        finalizeError: Error? = nil,
        detachGate: AsyncValueGate<Void>? = nil
    ) {
        let sampleDelegate = RealtimeAudioSampleDelegate(bufferLimit: bufferLimit)
        self.sampleDelegate = sampleDelegate
        stream = sampleDelegate.makeStream()
        self.startError = startError
        self.finalizeError = finalizeError
        self.detachGate = detachGate
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
        if let detachGate {
            _ = await detachGate.wait()
        }
        await sampleDelegate.finishAfterDraining()
    }

    func finalizeFile() async throws {
        finalizeInvocationCount += 1
        guard !didFinalize else { return }
        didFinalize = true
        events.append(.finalizeFile)
        isFallbackRecordingActive = false
        if let finalizeError {
            throw finalizeError
        }
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

    func emitMalformedPCM() {
        sampleDelegate.enqueueExtraction(.failure)
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
    case couldNotCreateBackend
    case couldNotFinalize
}

private final class GraphConfigurationToken {
    let name: String

    init(name: String) {
        self.name = name
    }
}

private final class FakeAudioRecorderCaptureSessionGraph: AudioRecorderCaptureSessionGraph, @unchecked Sendable {
    enum Event: Equatable {
        case startRecording
        case detachRealtime
        case finalizeFile
        case stopSession
    }

    private let lock = NSLock()
    private let sampleDelegate = RealtimeAudioSampleDelegate(bufferLimit: 2)
    private var storedBlockingEvents: [Event] = []
    private var storedBlockingCallWasOnMainThread: [Bool] = []

    var stream: AsyncThrowingStream<Data, Error> {
        sampleDelegate.makeStream()
    }

    var blockingEvents: [Event] {
        lock.withLock { storedBlockingEvents }
    }

    var blockingCallWasOnMainThread: [Bool] {
        lock.withLock { storedBlockingCallWasOnMainThread }
    }

    func startRecording(to url: URL) throws {
        record(.startRecording)
    }

    func waitUntilStarted() async throws {}

    func detachRealtime() {
        record(.detachRealtime)
    }

    func drainRealtime() async {
        await sampleDelegate.finishAfterDraining()
    }

    func finalizeFile() {
        record(.finalizeFile)
    }

    func waitUntilFinished() async throws {}

    func stopSession() {
        record(.stopSession)
    }

    private func record(_ event: Event) {
        lock.withLock {
            storedBlockingEvents.append(event)
            storedBlockingCallWasOnMainThread.append(Thread.isMainThread)
        }
    }
}

private final class GraphFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDeviceIDs: [String?] = []
    private var storedWasOnMainThread: [Bool] = []

    var deviceIDs: [String?] {
        lock.withLock { storedDeviceIDs }
    }

    var wasOnMainThread: [Bool] {
        lock.withLock { storedWasOnMainThread }
    }

    func record(deviceID: String?, isMainThread: Bool) {
        lock.withLock {
            storedDeviceIDs.append(deviceID)
            storedWasOnMainThread.append(isMainThread)
        }
    }
}

@MainActor
private final class AsyncValueGate<Value: Sendable> {
    private var valueContinuation: CheckedContinuation<Value, Never>?
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            valueContinuation = continuation
            let continuations = waitingContinuations
            waitingContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }
    }

    func waitUntilWaiting() async {
        guard valueContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    func resume(returning value: Value) {
        valueContinuation?.resume(returning: value)
        valueContinuation = nil
    }
}
