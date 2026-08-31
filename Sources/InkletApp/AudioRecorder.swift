import AVFoundation
import CoreMedia
import Foundation

@MainActor
protocol DictationAudioCapturing: AnyObject {
    func startStreaming(microphoneDeviceID: String?) async throws -> AsyncThrowingStream<Data, Error>
    func stop() async throws -> URL
    func cancel() async
}

@MainActor
final class AudioRecorder: DictationAudioCapturing {
    enum AudioRecorderError: Error, LocalizedError {
        case microphonePermissionDenied
        case noAudioInputDevice
        case recordingUnavailable
        case realtimeBufferOverflow

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                L10n.text("voice.error.microphonePermission")
            case .noAudioInputDevice:
                L10n.text("voice.error.noAudioInputDevice")
            case .recordingUnavailable:
                L10n.text("voice.error.recordingUnavailable")
            case .realtimeBufferOverflow:
                L10n.text("dictation.error.realtimeBufferOverflow")
            }
        }
    }

    static let realtimeAudioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 24_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    private var captureSession: AVCaptureSession?
    private var fileOutput: AVCaptureAudioFileOutput?
    private var dataOutput: AVCaptureAudioDataOutput?
    private var recordingDelegate: AudioRecordingDelegate?
    private var sampleDelegate: RealtimeAudioSampleDelegate?
    private var recordingURL: URL?

    func start(microphoneDeviceID: String?) async throws {
        _ = try await startStreaming(microphoneDeviceID: microphoneDeviceID)
    }

    func startStreaming(
        microphoneDeviceID: String?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        guard await requestMicrophoneAccess() else {
            throw AudioRecorderError.microphonePermissionDenied
        }
        guard let device = audioDevice(matching: microphoneDeviceID) else {
            throw AudioRecorderError.noAudioInputDevice
        }

        await cancel()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inklet-voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let captureSession = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let fileOutput = AVCaptureAudioFileOutput()
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

        let recordingDelegate = AudioRecordingDelegate()
        self.captureSession = captureSession
        self.fileOutput = fileOutput
        self.dataOutput = dataOutput
        self.recordingDelegate = recordingDelegate
        self.sampleDelegate = sampleDelegate
        recordingURL = url

        captureSession.startRunning()
        guard captureSession.isRunning else {
            dataOutput.setSampleBufferDelegate(nil, queue: nil)
            await sampleDelegate.finishAfterDraining()
            stopCaptureSession()
            recordingURL = nil
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.recordingUnavailable
        }

        fileOutput.startRecording(to: url, outputFileType: .m4a, recordingDelegate: recordingDelegate)
        do {
            try await recordingDelegate.waitUntilStarted()
        } catch {
            dataOutput.setSampleBufferDelegate(nil, queue: nil)
            await sampleDelegate.finishAfterDraining()
            stopCaptureSession()
            recordingURL = nil
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.recordingUnavailable
        }

        return sampleDelegate.makeStream()
    }

    func stop() async throws -> URL {
        guard let fileOutput,
              let dataOutput,
              let recordingDelegate,
              let sampleDelegate,
              let recordingURL
        else {
            throw AudioRecorderError.recordingUnavailable
        }

        dataOutput.setSampleBufferDelegate(nil, queue: nil)
        await sampleDelegate.finishAfterDraining()
        fileOutput.stopRecording()
        do {
            try await recordingDelegate.waitUntilFinished()
        } catch {
            stopCaptureSession()
            self.recordingURL = nil
            try? FileManager.default.removeItem(at: recordingURL)
            throw AudioRecorderError.recordingUnavailable
        }

        stopCaptureSession()
        self.recordingURL = nil
        return recordingURL
    }

    func cancel() async {
        let fileOutput = fileOutput
        let dataOutput = dataOutput
        let recordingDelegate = recordingDelegate
        let sampleDelegate = sampleDelegate
        let recordingURL = recordingURL
        dataOutput?.setSampleBufferDelegate(nil, queue: nil)
        await sampleDelegate?.finishAfterDraining()
        if fileOutput?.isRecording == true {
            fileOutput?.stopRecording()
            try? await recordingDelegate?.waitUntilFinished()
        }
        stopCaptureSession()
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        self.recordingURL = nil
    }

    private func stopCaptureSession() {
        captureSession?.stopRunning()
        captureSession = nil
        fileOutput = nil
        dataOutput = nil
        recordingDelegate = nil
        sampleDelegate = nil
    }

    private func audioDevice(matching deviceID: String?) -> AVCaptureDevice? {
        if let deviceID,
           let selectedDevice = MicrophoneDeviceCatalog.availableAudioDevices().first(where: { $0.uniqueID == deviceID }) {
            return selectedDevice
        }

        return AVCaptureDevice.default(for: .audio)
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await Self.requestMicrophoneAccessFromSystem()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private nonisolated static func requestMicrophoneAccessFromSystem() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

final class RealtimeAudioSampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.tomwan.inklet.realtime-audio-samples")

    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var didFinish = false

    init(bufferLimit: Int) {
        precondition(bufferLimit > 0)
        let pair = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(bufferLimit)
        )
        stream = pair.stream
        continuation = pair.continuation
        super.init()
    }

    func makeStream() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            yield(data)
        }
    }

    func finishAfterDraining() async {
        await withCheckedContinuation { drainContinuation in
            queue.async { [self] in
                finish()
                drainContinuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let data = Self.data(from: sampleBuffer), !data.isEmpty else { return }
        yield(data)
    }

    static func data(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount > 0 else { return nil }

        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: bytes.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        return data
    }

    private func yield(_ data: Data) {
        guard !didFinish else { return }
        switch continuation.yield(data) {
        case .enqueued:
            break
        case .dropped:
            finish(throwing: AudioRecorder.AudioRecorderError.realtimeBufferOverflow)
        case .terminated:
            didFinish = true
        @unknown default:
            finish(throwing: AudioRecorder.AudioRecorderError.realtimeBufferOverflow)
        }
    }

    private func finish(throwing error: Error? = nil) {
        guard !didFinish else { return }
        didFinish = true
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

private final class AudioRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var startResult: Result<Void, Error>?
    private var finishResult: Result<Void, Error>?

    func waitUntilStarted() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let startResult {
                lock.unlock()
                continuation.resume(with: startResult)
            } else {
                startContinuation = continuation
                lock.unlock()
            }
        }
    }

    func waitUntilFinished() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let finishResult {
                lock.unlock()
                continuation.resume(with: finishResult)
            } else {
                finishContinuation = continuation
                lock.unlock()
            }
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        completeStart(with: .success(()))
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let result: Result<Void, Error> = error.map(Result.failure) ?? .success(())
        if case .failure = result {
            completeStart(with: result)
        }
        completeFinish(with: result)
    }

    private func completeStart(with result: Result<Void, Error>) {
        lock.lock()
        guard startResult == nil else {
            lock.unlock()
            return
        }
        startResult = result
        if let startContinuation {
            self.startContinuation = nil
            lock.unlock()
            startContinuation.resume(with: result)
        } else {
            lock.unlock()
        }
    }

    private func completeFinish(with result: Result<Void, Error>) {
        lock.lock()
        guard finishResult == nil else {
            lock.unlock()
            return
        }
        finishResult = result
        if let finishContinuation {
            self.finishContinuation = nil
            lock.unlock()
            finishContinuation.resume(with: result)
        } else {
            lock.unlock()
        }
    }
}
