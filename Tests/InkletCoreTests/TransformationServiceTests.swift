import Foundation
import XCTest
@testable import InkletCore

final class TransformationServiceTests: XCTestCase {
    func testSuccessfulProviderReturnsTrimmedResult() async throws {
        let service = TransformationService(provider: FakeLLMProvider(outputText: "  Hello.  "))

        let result = try await service.transform(
            sourceText: "  hello  ",
            mode: mode,
            model: "test-model",
            timeoutSeconds: 1
        )

        XCTAssertEqual(result.outputText, "Hello.")
    }

    func testEmptyProviderResponseThrowsEmptyResponse() async throws {
        let service = TransformationService(provider: FakeLLMProvider(outputText: " \n\t "))

        do {
            _ = try await service.transform(
                sourceText: "hello",
                mode: mode,
                model: "test-model",
                timeoutSeconds: 1
            )
            XCTFail("Expected emptyResponse")
        } catch let error as TransformationError {
            XCTAssertEqual(error, .emptyResponse)
        }
    }

    func testTimeoutThrowsTimeout() async throws {
        let service = TransformationService(provider: FakeLLMProvider(
            outputText: "Hello.",
            delayNanoseconds: 500_000_000
        ))

        do {
            _ = try await service.transform(
                sourceText: "hello",
                mode: mode,
                model: "test-model",
                timeoutSeconds: 0.01
            )
            XCTFail("Expected timeout")
        } catch let error as TransformationError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testNetworkConnectionLostErrorHasSafeFallbackDescription() {
        XCTAssertEqual(
            TransformationError.networkConnectionLost.errorDescription,
            "网络连接中断，请重试"
        )
    }

    func testTimeoutReturnsPromptlyWhenProviderIgnoresCancellation() async throws {
        let service = TransformationService(provider: FakeLLMProvider(
            outputText: "Hello.",
            delayNanoseconds: 500_000_000,
            ignoresCancellation: true
        ))
        let started = Date()

        do {
            _ = try await service.transform(
                sourceText: "hello",
                mode: mode,
                model: "test-model",
                timeoutSeconds: 0.01
            )
            XCTFail("Expected timeout")
        } catch let error as TransformationError {
            XCTAssertEqual(error, .timeout)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        }
    }

    func testParentCancellationThrowsCancellationError() async throws {
        let service = TransformationService(provider: FakeLLMProvider(
            outputText: "Hello.",
            delayNanoseconds: 500_000_000,
            ignoresCancellation: true
        ))
        let mode = mode
        let task = Task {
            try await service.transform(
                sourceText: "hello",
                mode: mode,
                model: "test-model",
                timeoutSeconds: 10
            )
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        let started = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        }
    }

    private var mode: PromptMode {
        PromptMode(
            id: "polish",
            name: "Polish",
            description: "Polish text",
            systemPrompt: "Improve the text.",
            shortcut: nil,
            participatesInAuto: true,
            autoRule: .englishHeavy,
            sortOrder: 1,
            isVisible: true
        )
    }
}

private struct FakeLLMProvider: LLMProvider {
    var outputText: String
    var delayNanoseconds: UInt64
    var ignoresCancellation: Bool

    init(
        outputText: String,
        delayNanoseconds: UInt64 = 0,
        ignoresCancellation: Bool = false
    ) {
        self.outputText = outputText
        self.delayNanoseconds = delayNanoseconds
        self.ignoresCancellation = ignoresCancellation
    }

    func transform(_ request: TransformationRequest) async throws -> TransformationResult {
        if delayNanoseconds > 0 {
            if ignoresCancellation {
                await sleepIgnoringCancellation(nanoseconds: delayNanoseconds)
            } else {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }

        return TransformationResult(
            outputText: outputText,
            providerMetadata: ["provider": "fake"],
            elapsedMilliseconds: 1
        )
    }

    private func sleepIgnoringCancellation(nanoseconds: UInt64) async {
        let deadline = Date().addingTimeInterval(Double(nanoseconds) / 1_000_000_000)

        while Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                continue
            }
        }
    }
}
