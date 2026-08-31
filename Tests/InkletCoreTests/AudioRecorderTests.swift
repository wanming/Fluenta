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

    func testAudioRecorderWiresFileAndRealtimeOutputsIntoOneSession() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/AudioRecorder.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("let dataOutput = AVCaptureAudioDataOutput()"))
        XCTAssertTrue(source.contains("dataOutput.audioSettings = Self.realtimeAudioSettings"))
        XCTAssertTrue(source.contains("captureSession.addOutput(fileOutput)"))
        XCTAssertTrue(source.contains("captureSession.addOutput(dataOutput)"))
        XCTAssertTrue(source.contains("dataOutput.setSampleBufferDelegate(sampleDelegate, queue: sampleDelegate.queue)"))
        XCTAssertTrue(source.contains("dataOutput.setSampleBufferDelegate(nil, queue: nil)"))
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
