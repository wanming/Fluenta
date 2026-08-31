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
protocol AudioRecorderCaptureBackend: AnyObject, Sendable {
    var stream: AsyncThrowingStream<Data, Error> { get }

    func startRecording(to url: URL) async throws
    func detachRealtimeAndDrain() async
    func finalizeFile() async throws
    func stopSession() async
}

protocol AudioRecorderCaptureSessionGraph: AnyObject, Sendable {
    var stream: AsyncThrowingStream<Data, Error> { get }

    func startRecording(to url: URL) throws
    func waitUntilStarted() async throws
    func detachRealtime()
    func drainRealtime() async
    func finalizeFile()
    func waitUntilFinished() async throws
    func stopSession()
}

final class AudioRecorderCaptureExecutor: Sendable {
    private let queue: DispatchQueue

    init(label: String = "com.tomwan.inklet.audio-capture-session") {
        queue = DispatchQueue(label: label)
    }

    func run<Result: Sendable>(
        _ operation: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum AudioRecorderCaptureGraphConfigurator {
    static func configure<Session, Input, FileOutput, DataOutput, SampleDelegate, SampleQueue>(
        session: Session,
        input: Input,
        fileOutput: FileOutput,
        dataOutput: DataOutput,
        sampleDelegate: SampleDelegate,
        sampleQueue: SampleQueue,
        realtimeSettings: [String: Any],
        canAddInput: (Session, Input) -> Bool,
        canAddFileOutput: (Session, FileOutput) -> Bool,
        canAddDataOutput: (Session, DataOutput) -> Bool,
        applyRealtimeConfiguration: (
            Session,
            DataOutput,
            [String: Any],
            SampleDelegate,
            SampleQueue
        ) -> Void,
        beginConfiguration: (Session) -> Void,
        addInput: (Session, Input) -> Void,
        addFileOutput: (Session, FileOutput) -> Void,
        addDataOutput: (Session, DataOutput) -> Void,
        commitConfiguration: (Session) -> Void
    ) throws {
        guard canAddInput(session, input),
              canAddFileOutput(session, fileOutput),
              canAddDataOutput(session, dataOutput)
        else {
            throw AudioRecorder.AudioRecorderError.recordingUnavailable
        }

        applyRealtimeConfiguration(
            session,
            dataOutput,
            realtimeSettings,
            sampleDelegate,
            sampleQueue
        )
        beginConfiguration(session)
        addInput(session, input)
        addFileOutput(session, fileOutput)
        addDataOutput(session, dataOutput)
        commitConfiguration(session)
    }
}

@MainActor
final class AudioRecorder: DictationAudioCapturing {
    enum AudioRecorderError: Error, LocalizedError {
        case microphonePermissionDenied
        case noAudioInputDevice
        case recordingUnavailable
        case realtimeBufferOverflow
        case realtimeAudioUnavailable

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                L10n.text("dictation.error.microphonePermission")
            case .noAudioInputDevice:
                L10n.text("dictation.error.noAudioInputDevice")
            case .recordingUnavailable:
                L10n.text("dictation.error.recordingUnavailable")
            case .realtimeBufferOverflow:
                L10n.text("dictation.error.realtimeBufferOverflow")
            case .realtimeAudioUnavailable:
                L10n.text("dictation.error.recordingUnavailable")
            }
        }
    }

    nonisolated static var realtimeAudioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    typealias MicrophonePermissionResolver = () async -> Bool
    typealias CaptureBackendResolver = (String?) async throws -> any AudioRecorderCaptureBackend
    typealias CaptureBackendFactory = () throws -> any AudioRecorderCaptureBackend

    private struct ActiveCapture {
        let id: UUID
        let backend: any AudioRecorderCaptureBackend
        let recordingURL: URL
    }

    private let microphonePermissionResolver: MicrophonePermissionResolver
    private let captureBackendResolver: CaptureBackendResolver
    private let recordingURLProvider: () -> URL
    private let removeRecording: (URL) -> Void
    private var activeCapture: ActiveCapture?
    private var startGeneration: UInt64 = 0

    init(
        microphonePermissionResolver: MicrophonePermissionResolver? = nil,
        captureBackendResolver: CaptureBackendResolver? = nil,
        captureBackendFactory: CaptureBackendFactory? = nil,
        recordingURLProvider: @escaping () -> URL = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("inklet-voice-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
        },
        removeRecording: @escaping (URL) -> Void = { url in
            try? FileManager.default.removeItem(at: url)
        }
    ) {
        if let microphonePermissionResolver {
            self.microphonePermissionResolver = microphonePermissionResolver
        } else if captureBackendResolver != nil || captureBackendFactory != nil {
            self.microphonePermissionResolver = { true }
        } else {
            self.microphonePermissionResolver = {
                await Self.requestMicrophoneAccess()
            }
        }

        if let captureBackendResolver {
            self.captureBackendResolver = captureBackendResolver
        } else if let captureBackendFactory {
            self.captureBackendResolver = { _ in
                try captureBackendFactory()
            }
        } else {
            self.captureBackendResolver = { deviceID in
                try await AVFoundationAudioRecorderCaptureBackend.make(deviceID: deviceID)
            }
        }
        self.recordingURLProvider = recordingURLProvider
        self.removeRecording = removeRecording
    }

    func startStreaming(
        microphoneDeviceID: String?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let generation = beginStart()
        try validateStart(generation)

        let hasMicrophoneAccess = await microphonePermissionResolver()
        try validateStart(generation)
        guard hasMicrophoneAccess else {
            throw AudioRecorderError.microphonePermissionDenied
        }

        await cancelActiveCapture()
        try validateStart(generation)

        let recordingURL = recordingURLProvider()
        var resolvedBackend: (any AudioRecorderCaptureBackend)?
        do {
            let backend = try await captureBackendResolver(microphoneDeviceID)
            resolvedBackend = backend
            try validateStart(generation)
        } catch {
            if let resolvedBackend {
                let unownedCapture = ActiveCapture(
                    id: UUID(),
                    backend: resolvedBackend,
                    recordingURL: recordingURL
                )
                await terminate(unownedCapture, deletingRecording: true)
            } else {
                removeRecording(recordingURL)
            }
            try validateStart(generation)
            if error is CancellationError {
                throw CancellationError()
            }
            throw mappedRecorderError(error)
        }
        guard let backend = resolvedBackend else {
            removeRecording(recordingURL)
            throw AudioRecorderError.recordingUnavailable
        }

        let capture = ActiveCapture(id: UUID(), backend: backend, recordingURL: recordingURL)
        activeCapture = capture
        do {
            try validateStart(generation)
            try await backend.startRecording(to: recordingURL)
            try validateStart(generation)
        } catch {
            if let ownedCapture = takeActiveCapture(id: capture.id) {
                await terminate(ownedCapture, deletingRecording: true)
            }
            try validateStart(generation)
            if error is CancellationError {
                throw CancellationError()
            }
            throw mappedRecorderError(error)
        }

        try validateStart(generation)
        guard activeCapture?.id == capture.id else { throw CancellationError() }
        return backend.stream
    }

    func stop() async throws -> URL {
        guard let capture = takeActiveCapture() else {
            throw AudioRecorderError.recordingUnavailable
        }

        await capture.backend.detachRealtimeAndDrain()
        do {
            try await capture.backend.finalizeFile()
        } catch {
            await capture.backend.stopSession()
            removeRecording(capture.recordingURL)
            throw AudioRecorderError.recordingUnavailable
        }

        await capture.backend.stopSession()
        return capture.recordingURL
    }

    func cancel() async {
        invalidatePendingStarts()
        await cancelActiveCapture()
    }

    private func cancelActiveCapture() async {
        guard let capture = takeActiveCapture() else { return }
        await terminate(capture, deletingRecording: true)
    }

    private func beginStart() -> UInt64 {
        startGeneration &+= 1
        return startGeneration
    }

    private func invalidatePendingStarts() {
        startGeneration &+= 1
    }

    private func validateStart(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == startGeneration else {
            throw CancellationError()
        }
    }

    private func takeActiveCapture(id: UUID? = nil) -> ActiveCapture? {
        guard let activeCapture else { return nil }
        if let id, activeCapture.id != id {
            return nil
        }
        self.activeCapture = nil
        return activeCapture
    }

    private func terminate(
        _ capture: ActiveCapture,
        deletingRecording: Bool
    ) async {
        await capture.backend.detachRealtimeAndDrain()
        try? await capture.backend.finalizeFile()
        await capture.backend.stopSession()
        if deletingRecording {
            removeRecording(capture.recordingURL)
        }
    }

    private func mappedRecorderError(_ error: Error) -> AudioRecorderError {
        (error as? AudioRecorderError) ?? .recordingUnavailable
    }

    private nonisolated static func requestMicrophoneAccess() async -> Bool {
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

@MainActor
final class AVFoundationAudioRecorderCaptureBackend: AudioRecorderCaptureBackend {
    typealias GraphFactory = @Sendable (String?) throws -> any AudioRecorderCaptureSessionGraph

    private let graph: any AudioRecorderCaptureSessionGraph
    private let captureExecutor: AudioRecorderCaptureExecutor
    private var didRequestFileRecording = false
    private var didDetachRealtime = false
    private var didFinalizeFile = false
    private var didStopSession = false

    var stream: AsyncThrowingStream<Data, Error> {
        graph.stream
    }

    init(
        graph: any AudioRecorderCaptureSessionGraph,
        captureExecutor: AudioRecorderCaptureExecutor
    ) {
        self.graph = graph
        self.captureExecutor = captureExecutor
    }

    static func make(
        deviceID: String?,
        captureExecutor: AudioRecorderCaptureExecutor = AudioRecorderCaptureExecutor(),
        graphFactory: @escaping GraphFactory = { deviceID in
            try AVFoundationAudioRecorderCaptureSessionGraph(deviceID: deviceID)
        }
    ) async throws -> AVFoundationAudioRecorderCaptureBackend {
        let graph = try await captureExecutor.run {
            try graphFactory(deviceID)
        }
        return AVFoundationAudioRecorderCaptureBackend(
            graph: graph,
            captureExecutor: captureExecutor
        )
    }

    func startRecording(to url: URL) async throws {
        try await captureExecutor.run { [graph] in
            try graph.startRecording(to: url)
        }
        didRequestFileRecording = true
        try await graph.waitUntilStarted()
    }

    func detachRealtimeAndDrain() async {
        guard !didDetachRealtime else { return }
        didDetachRealtime = true
        try? await captureExecutor.run { [graph] in
            graph.detachRealtime()
        }
        await graph.drainRealtime()
    }

    func finalizeFile() async throws {
        guard didRequestFileRecording, !didFinalizeFile else { return }
        didFinalizeFile = true
        try await captureExecutor.run { [graph] in
            graph.finalizeFile()
        }
        try await graph.waitUntilFinished()
    }

    func stopSession() async {
        guard !didStopSession else { return }
        didStopSession = true
        try? await captureExecutor.run { [graph] in
            graph.stopSession()
        }
    }
}

private final class AVFoundationAudioRecorderCaptureSessionGraph: AudioRecorderCaptureSessionGraph, @unchecked Sendable {
    private let captureSession: AVCaptureSession
    private let fileOutput: AVCaptureAudioFileOutput
    private let dataOutput: AVCaptureAudioDataOutput
    private let recordingDelegate: AudioRecordingDelegate
    private let sampleDelegate: RealtimeAudioSampleDelegate

    var stream: AsyncThrowingStream<Data, Error> {
        sampleDelegate.makeStream()
    }

    init(deviceID: String?) throws {
        guard let device = Self.audioDevice(matching: deviceID) else {
            throw AudioRecorder.AudioRecorderError.noAudioInputDevice
        }
        let captureSession = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let fileOutput = AVCaptureAudioFileOutput()
        let dataOutput = AVCaptureAudioDataOutput()
        let recordingDelegate = AudioRecordingDelegate()
        let sampleDelegate = RealtimeAudioSampleDelegate(bufferLimit: 96)
        try AudioRecorderCaptureGraphConfigurator.configure(
            session: captureSession,
            input: input,
            fileOutput: fileOutput,
            dataOutput: dataOutput,
            sampleDelegate: sampleDelegate,
            sampleQueue: sampleDelegate.queue,
            realtimeSettings: AudioRecorder.realtimeAudioSettings,
            canAddInput: { session, input in session.canAddInput(input) },
            canAddFileOutput: { session, output in session.canAddOutput(output) },
            canAddDataOutput: { session, output in session.canAddOutput(output) },
            applyRealtimeConfiguration: { _, output, settings, delegate, queue in
                output.audioSettings = settings
                output.setSampleBufferDelegate(delegate, queue: queue)
            },
            beginConfiguration: { $0.beginConfiguration() },
            addInput: { session, input in session.addInput(input) },
            addFileOutput: { session, output in session.addOutput(output) },
            addDataOutput: { session, output in session.addOutput(output) },
            commitConfiguration: { $0.commitConfiguration() }
        )

        self.captureSession = captureSession
        self.fileOutput = fileOutput
        self.dataOutput = dataOutput
        self.recordingDelegate = recordingDelegate
        self.sampleDelegate = sampleDelegate
    }

    private static func audioDevice(matching deviceID: String?) -> AVCaptureDevice? {
        if let deviceID {
            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            if let selectedDevice = discoverySession.devices.first(where: { $0.uniqueID == deviceID }) {
                return selectedDevice
            }
        }

        return AVCaptureDevice.default(for: .audio)
    }

    func startRecording(to url: URL) throws {
        captureSession.startRunning()
        guard captureSession.isRunning else {
            throw AudioRecorder.AudioRecorderError.recordingUnavailable
        }

        fileOutput.startRecording(to: url, outputFileType: .m4a, recordingDelegate: recordingDelegate)
    }

    func waitUntilStarted() async throws {
        try await recordingDelegate.waitUntilStarted()
    }

    func detachRealtime() {
        dataOutput.setSampleBufferDelegate(nil, queue: nil)
    }

    func drainRealtime() async {
        await sampleDelegate.finishAfterDraining()
    }

    func finalizeFile() {
        fileOutput.stopRecording()
    }

    func waitUntilFinished() async throws {
        try await recordingDelegate.waitUntilFinished()
    }

    func stopSession() {
        captureSession.stopRunning()
    }
}

final class RealtimeAudioSampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum PCMExtraction: Equatable, Sendable {
        case bytes(Data)
        case empty
        case failure
    }

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

    func enqueueExtraction(_ extraction: PCMExtraction) {
        queue.async { [self] in
            accept(extraction)
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
        accept(Self.extraction(from: CMSampleBufferGetDataBuffer(sampleBuffer)))
    }

    static func data(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard case let .bytes(data) = extraction(
            from: CMSampleBufferGetDataBuffer(sampleBuffer)
        ) else {
            return nil
        }
        return data
    }

    static func extraction(
        from blockBuffer: CMBlockBuffer?,
        dataLength: (CMBlockBuffer) -> Int = { CMBlockBufferGetDataLength($0) },
        copyBytes: (CMBlockBuffer, Int, UnsafeMutableRawPointer) -> OSStatus = { blockBuffer, byteCount, destination in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: destination
            )
        }
    ) -> PCMExtraction {
        guard let blockBuffer else { return .failure }
        let byteCount = dataLength(blockBuffer)
        guard byteCount >= 0 else { return .failure }
        guard byteCount > 0 else { return .empty }

        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { bytes in
            copyBytes(blockBuffer, byteCount, bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return .failure }
        return .bytes(data)
    }

    private func accept(_ extraction: PCMExtraction) {
        switch extraction {
        case let .bytes(data):
            yield(data)
        case .empty:
            break
        case .failure:
            finish(throwing: AudioRecorder.AudioRecorderError.realtimeAudioUnavailable)
        }
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
