# Network Connection Lost Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retry an interrupted LLM text transformation once for `NSURLErrorDomain` code `-1005`, preserve the original cancellation and timeout budget, and show a localized error if both attempts fail.

**Architecture:** Add a semantic `TransformationError.networkConnectionLost` and map it through the existing writing-popover localization boundary. Keep retry classification and the two-attempt loop inside `TransformationService`, nested within its existing operation-wide timeout task, so all LLM text transformations share the policy while speech transcription and TTS remain untouched.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, Foundation `URLError`/`NSError`, Swift concurrency, and the existing source-based localization tests.

**Approved design:** `docs/superpowers/specs/2026-08-18-network-connection-lost-retry-design.md`

---

## File Map

- `Sources/InkletCore/TransformationTypes.swift`: owns the semantic exhausted-retry error.
- `Sources/InkletCore/TransformationService.swift`: classifies `-1005`, retries once, and keeps both attempts inside the original timeout race.
- `Sources/InkletApp/InkletPopoverView.swift`: converts the semantic error into a localized user-facing message.
- `Sources/InkletApp/InkletLocalization.swift`: supplies the message for all ten supported language tables.
- `Tests/InkletCoreTests/TransformationServiceTests.swift`: exercises retry count, exact error classification, cancellation, and total timeout behavior.
- `Tests/InkletCoreTests/WritingModeLauncherLocalizationTests.swift`: proves every language table has the approved copy.
- `Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift`: proves the popover maps the semantic error through `L10n`.

### Task 1: Add the semantic and localized exhausted-retry error

**Files:**
- Modify: `Tests/InkletCoreTests/TransformationServiceTests.swift`
- Modify: `Tests/InkletCoreTests/WritingModeLauncherLocalizationTests.swift`
- Modify: `Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift`
- Modify: `Sources/InkletCore/TransformationTypes.swift:48-64`
- Modify: `Sources/InkletApp/InkletPopoverView.swift:616-629`
- Modify: `Sources/InkletApp/InkletLocalization.swift:434-439,736-741,922-927,1103-1108,1285-1290,1467-1472,1649-1654,1831-1836,2013-2018,2195-2200`

- [ ] **Step 1: Write the failing localization and popover-mapping tests**

Add this fixture beside `expectedLauncherValues` in `WritingModeLauncherLocalizationTests.swift`:

```swift
private let expectedNetworkConnectionLostValues = [
    "en": "The network connection was interrupted. Please try again.",
    "zhHans": "网络连接已中断，请重试。",
    "zhHant": "網路連線已中斷，請再試一次。",
    "ja": "ネットワーク接続が中断されました。もう一度お試しください。",
    "ko": "네트워크 연결이 중단되었습니다. 다시 시도하세요.",
    "es": "Se interrumpió la conexión de red. Inténtalo de nuevo.",
    "fr": "La connexion réseau a été interrompue. Réessayez.",
    "de": "Die Netzwerkverbindung wurde unterbrochen. Bitte erneut versuchen.",
    "pt": "A conexão de rede foi interrompida. Tente novamente.",
    "it": "La connessione di rete è stata interrotta. Riprova.",
]
```

Add this test to `WritingModeLauncherLocalizationTests` before its private helpers:

```swift
func testNetworkConnectionLostCopyMatchesEveryApprovedLocalizationTable() throws {
    let source = try localizationSource()
    let key = "error.networkConnectionLost"

    XCTAssertEqual(Set(expectedNetworkConnectionLostValues.keys), Set(approvedTableIDs))

    for tableID in approvedTableIDs {
        let tableSource = try localizationTableSource(tableID, in: source)
        let expectedValue = try XCTUnwrap(expectedNetworkConnectionLostValues[tableID])
        let normalizedEntries = normalizedDictionaryEntries(in: tableSource)

        XCTAssertEqual(
            countDictionaryEntries(key, in: tableSource),
            1,
            "Expected exactly one \(key) entry in \(tableID)"
        )
        XCTAssertTrue(
            normalizedEntries.contains(#""\#(key)": "\#(expectedValue)""#),
            "Unexpected \(key) value in \(tableID)"
        )
    }
}
```

Add this test to `WritingModeLauncherSourceTests` before its private source helpers:

```swift
func testNetworkConnectionLostUsesLocalizedPopoverError() throws {
    let source = try popoverSource()

    XCTAssertTrue(source.contains("case .networkConnectionLost:"))
    XCTAssertTrue(source.contains(#"return L10n.text("error.networkConnectionLost")"#))
}
```

- [ ] **Step 2: Run the localization tests and verify their contracts are red**

Run:

```bash
swift test --filter WritingModeLauncherLocalizationTests/testNetworkConnectionLostCopyMatchesEveryApprovedLocalizationTable
swift test --filter WritingModeLauncherSourceTests/testNetworkConnectionLostUsesLocalizedPopoverError
```

Expected: the localization test fails once for each approved table because `error.networkConnectionLost` is absent, and the source test fails because the switch has no `.networkConnectionLost` branch.

- [ ] **Step 3: Write the failing semantic-error test**

Add `import Foundation` above `import XCTest` in `TransformationServiceTests.swift`, then add this test inside `TransformationServiceTests`:

```swift
func testNetworkConnectionLostErrorHasSafeFallbackDescription() {
    XCTAssertEqual(
        TransformationError.networkConnectionLost.errorDescription,
        "网络连接中断，请重试"
    )
}
```

Run:

```bash
swift test --filter TransformationServiceTests/testNetworkConnectionLostErrorHasSafeFallbackDescription
```

Expected: compilation fails because `TransformationError.networkConnectionLost` does not exist. This is the expected API-contract red state.

- [ ] **Step 4: Add the semantic error and popover mapping**

Add the case and fallback description in `TransformationTypes.swift`:

```swift
public enum TransformationError: Error, Equatable, LocalizedError {
    case emptySource
    case emptyResponse
    case timeout
    case networkConnectionLost
    case provider(String)

    public var errorDescription: String? {
        switch self {
        case .emptySource:
            "请输入要转换的文本"
        case .emptyResponse:
            "模型返回了空内容"
        case .timeout:
            "请求超时，请稍后重试"
        case .networkConnectionLost:
            "网络连接中断，请重试"
        case .provider(let message):
            message
        }
    }
}
```

Add the matching branch to the `TransformationError` switch in the private `Error.userFacingMessage` extension in `InkletPopoverView.swift`:

```swift
case .networkConnectionLost:
    return L10n.text("error.networkConnectionLost")
```

Place it between the `.timeout` and `.provider` branches.

- [ ] **Step 5: Add the approved copy to every localization table**

In each dictionary in `InkletLocalization.swift`, add its entry immediately after `error.timeout`:

```swift
// en
"error.networkConnectionLost": "The network connection was interrupted. Please try again.",

// zhHans
"error.networkConnectionLost": "网络连接已中断，请重试。",

// zhHant
"error.networkConnectionLost": "網路連線已中斷，請再試一次。",

// ja
"error.networkConnectionLost": "ネットワーク接続が中断されました。もう一度お試しください。",

// ko
"error.networkConnectionLost": "네트워크 연결이 중단되었습니다. 다시 시도하세요.",

// es
"error.networkConnectionLost": "Se interrumpió la conexión de red. Inténtalo de nuevo.",

// fr
"error.networkConnectionLost": "La connexion réseau a été interrompue. Réessayez.",

// de
"error.networkConnectionLost": "Die Netzwerkverbindung wurde unterbrochen. Bitte erneut versuchen.",

// pt
"error.networkConnectionLost": "A conexão de rede foi interrompida. Tente novamente.",

// it
"error.networkConnectionLost": "La connessione di rete è stata interrotta. Riprova.",
```

The `//` labels above identify tables for the implementer; do not add those comment lines to the dictionaries.

- [ ] **Step 6: Run the focused tests and verify the localized error contract is green**

Run:

```bash
swift test --filter TransformationServiceTests/testNetworkConnectionLostErrorHasSafeFallbackDescription
swift test --filter WritingModeLauncherLocalizationTests/testNetworkConnectionLostCopyMatchesEveryApprovedLocalizationTable
swift test --filter WritingModeLauncherSourceTests/testNetworkConnectionLostUsesLocalizedPopoverError
```

Expected: all three commands exit 0 and each selected test passes.

- [ ] **Step 7: Commit the semantic error and localization**

Review the staged diff before committing:

```bash
git add Sources/InkletCore/TransformationTypes.swift Sources/InkletApp/InkletPopoverView.swift Sources/InkletApp/InkletLocalization.swift Tests/InkletCoreTests/TransformationServiceTests.swift Tests/InkletCoreTests/WritingModeLauncherLocalizationTests.swift Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift
git diff --cached --check
git diff --cached
git commit -m "Localize interrupted network errors"
```

### Task 2: Retry one interrupted text transformation inside the original timeout

**Files:**
- Modify: `Tests/InkletCoreTests/TransformationServiceTests.swift`
- Modify: `Sources/InkletCore/TransformationService.swift:30-43`

- [ ] **Step 1: Add failing retry-policy tests and a sequenced provider**

Add these tests inside `TransformationServiceTests`:

```swift
func testRetriesNetworkConnectionLostOnceAndReturnsSuccess() async throws {
    let provider = SequencedLLMProvider([
        .networkConnectionLost,
        .success("Recovered."),
    ])
    let service = TransformationService(provider: provider)

    let result = try await service.transform(
        sourceText: "hello",
        mode: mode,
        model: "test-model",
        timeoutSeconds: 1
    )

    XCTAssertEqual(result.outputText, "Recovered.")
    let attemptCount = await provider.attemptCount()
    XCTAssertEqual(attemptCount, 2)
}

func testMapsSecondNetworkConnectionLostToSemanticError() async throws {
    let provider = SequencedLLMProvider([
        .networkConnectionLost,
        .networkConnectionLost,
    ])
    let service = TransformationService(provider: provider)

    do {
        _ = try await service.transform(
            sourceText: "hello",
            mode: mode,
            model: "test-model",
            timeoutSeconds: 1
        )
        XCTFail("Expected network connection lost error")
    } catch let error as TransformationError {
        XCTAssertEqual(error, .networkConnectionLost)
    }

    let attemptCount = await provider.attemptCount()
    XCTAssertEqual(attemptCount, 2)
}

func testDoesNotRetryDifferentURLError() async throws {
    let provider = SequencedLLMProvider([
        .notConnectedToInternet,
        .success("Unexpected."),
    ])
    let service = TransformationService(provider: provider)

    do {
        _ = try await service.transform(
            sourceText: "hello",
            mode: mode,
            model: "test-model",
            timeoutSeconds: 1
        )
        XCTFail("Expected not-connected error")
    } catch let error as URLError {
        XCTAssertEqual(error.code, .notConnectedToInternet)
    }

    let attemptCount = await provider.attemptCount()
    XCTAssertEqual(attemptCount, 1)
}

func testPropagatesDifferentErrorFromSecondAttempt() async throws {
    let provider = SequencedLLMProvider([
        .networkConnectionLost,
        .badServerResponse,
    ])
    let service = TransformationService(provider: provider)

    do {
        _ = try await service.transform(
            sourceText: "hello",
            mode: mode,
            model: "test-model",
            timeoutSeconds: 1
        )
        XCTFail("Expected bad-server-response error")
    } catch let error as URLError {
        XCTAssertEqual(error.code, .badServerResponse)
    }

    let attemptCount = await provider.attemptCount()
    XCTAssertEqual(attemptCount, 2)
}

func testCancellationAfterFirstConnectionLossPreventsRetry() async throws {
    let provider = SequencedLLMProvider([
        .cancelThenNetworkConnectionLost,
        .success("Unexpected."),
    ])
    let service = TransformationService(provider: provider)

    do {
        _ = try await service.transform(
            sourceText: "hello",
            mode: mode,
            model: "test-model",
            timeoutSeconds: 1
        )
        XCTFail("Expected cancellation")
    } catch is CancellationError {
    }

    let attemptCount = await provider.attemptCount()
    XCTAssertEqual(attemptCount, 1)
}

func testRetrySharesOriginalTimeoutBudget() async throws {
    let provider = SequencedLLMProvider([
        .delayedNetworkConnectionLost(nanoseconds: 20_000_000),
        .delayedSuccess("Unexpected.", nanoseconds: 500_000_000),
    ])
    let service = TransformationService(provider: provider)
    let started = Date()

    do {
        _ = try await service.transform(
            sourceText: "hello",
            mode: mode,
            model: "test-model",
            timeoutSeconds: 0.1
        )
        XCTFail("Expected timeout")
    } catch let error as TransformationError {
        XCTAssertEqual(error, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
    }

    let attemptCount = await provider.attemptCount()
    XCTAssertEqual(attemptCount, 2)
}
```

Add this actor after the existing `FakeLLMProvider` in the same test file:

```swift
private actor SequencedLLMProvider: LLMProvider {
    enum Outcome: Sendable {
        case success(String)
        case networkConnectionLost
        case notConnectedToInternet
        case badServerResponse
        case delayedNetworkConnectionLost(nanoseconds: UInt64)
        case delayedSuccess(String, nanoseconds: UInt64)
        case cancelThenNetworkConnectionLost
    }

    private var outcomes: [Outcome]
    private var attempts = 0

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func transform(_ request: TransformationRequest) async throws -> TransformationResult {
        precondition(!outcomes.isEmpty, "Missing sequenced provider outcome")
        let outcome = outcomes.removeFirst()
        attempts += 1

        switch outcome {
        case .success(let outputText):
            return makeResult(outputText: outputText)
        case .networkConnectionLost:
            throw URLError(.networkConnectionLost)
        case .notConnectedToInternet:
            throw URLError(.notConnectedToInternet)
        case .badServerResponse:
            throw URLError(.badServerResponse)
        case .delayedNetworkConnectionLost(let nanoseconds):
            try await Task.sleep(nanoseconds: nanoseconds)
            throw URLError(.networkConnectionLost)
        case .delayedSuccess(let outputText, let nanoseconds):
            try await Task.sleep(nanoseconds: nanoseconds)
            return makeResult(outputText: outputText)
        case .cancelThenNetworkConnectionLost:
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            throw URLError(.networkConnectionLost)
        }
    }

    func attemptCount() -> Int {
        attempts
    }

    private func makeResult(outputText: String) -> TransformationResult {
        TransformationResult(
            outputText: outputText,
            providerMetadata: ["provider": "sequenced"],
            elapsedMilliseconds: 1
        )
    }
}
```

- [ ] **Step 2: Run the retry tests and verify the behavior is red**

Run:

```bash
swift test --filter TransformationServiceTests
```

Expected: the new recovery test throws the first `URLError.networkConnectionLost`; the exhausted-retry test receives a raw `URLError` instead of `.networkConnectionLost`; the second-error, cancellation, and shared-timeout tests also fail because only one provider attempt occurs. The pre-existing success, empty-response, timeout, and parent-cancellation tests remain green.

- [ ] **Step 3: Implement the exact `-1005` classifier and one-retry loop**

In `TransformationService.transform`, replace the direct provider call inside `withTimeout`:

```swift
let result = try await withTimeout(seconds: timeoutSeconds) {
    try await transformWithNetworkConnectionLostRetry(request)
}
```

Add these helpers immediately below `transform` and above `withTimeout`:

```swift
private func transformWithNetworkConnectionLostRetry(
    _ request: TransformationRequest
) async throws -> TransformationResult {
    do {
        return try await provider.transform(request)
    } catch {
        guard Self.isNetworkConnectionLost(error) else {
            throw error
        }
    }

    try Task.checkCancellation()

    do {
        return try await provider.transform(request)
    } catch {
        guard Self.isNetworkConnectionLost(error) else {
            throw error
        }
        throw TransformationError.networkConnectionLost
    }
}

private static func isNetworkConnectionLost(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain
        && nsError.code == URLError.networkConnectionLost.rawValue
}
```

Do not add sleep, exponential backoff, a third attempt, broader retry codes, or a new configuration setting.

- [ ] **Step 4: Run the transformation tests and verify the retry policy is green**

Run:

```bash
swift test --filter TransformationServiceTests
```

Expected: all `TransformationServiceTests` pass, including exactly two attempts for recovery and exhaustion, exactly one attempt for a different URL error and post-first-failure cancellation, propagation of the second non-`-1005` error, and the original timeout bound.

- [ ] **Step 5: Run downstream text-transformation tests**

Run:

```bash
swift test --filter SelectionTranslationServiceTests
swift test --filter VoiceInputCoordinatorTests
swift test --filter WritingModeLauncherSourceTests
```

Expected: all three commands exit 0. Selection translation and voice cleanup still use `TransformationService`; speech transcription, pronunciation, cancellation fallback, and writing-popover source contracts remain unchanged.

- [ ] **Step 6: Commit the retry behavior**

Review the staged diff before committing:

```bash
git add Sources/InkletCore/TransformationService.swift Tests/InkletCoreTests/TransformationServiceTests.swift
git diff --cached --check
git diff --cached
git commit -m "Retry interrupted text transformations"
```

### Task 3: Verify the complete change and hand off manual QA

**Files:**
- Verify only; no source or documentation changes are expected.

- [ ] **Step 1: Confirm the committed scope is surgical**

Run:

```bash
git status --short --branch
git diff HEAD~2..HEAD --stat
git diff HEAD~2..HEAD -- Sources/InkletCore Sources/InkletApp Tests/InkletCoreTests
```

Expected: the worktree is clean. The two implementation commits contain only the seven files in the file map; no README, privacy, audio-provider, configuration, `VERSION`, generated, credential, or local-environment file changed.

- [ ] **Step 2: Run the complete automated suite**

Run:

```bash
swift test
```

Expected: the package builds without warnings or errors and all XCTest and Swift Testing suites pass.

- [ ] **Step 3: Run final repository checks**

Run:

```bash
git diff --check HEAD~2..HEAD
git status --short --branch
```

Expected: `git diff --check` produces no output and exits 0; `git status` reports a clean `codex/retry-network-connection-lost` branch.

- [ ] **Step 4: Report the unperformed manual network-switch checks explicitly**

Do not build or launch the app solely for this task unless the user requests local hand-testing. In the final handoff, report that automated transient-error, cancellation, timeout, localization, and full-suite checks passed, while real network-switch QA was not performed.

If the user requests manual QA later, first increment the patch component of root `VERSION`, then use only:

```bash
scripts/run-local-app.sh
```

Manually verify that Escape cancels an active transformation, a recovered first connection loss causes no error or layout shift, and a repeated connection loss leaves the source text available while showing the localized message. Do not use Computer Use to test Inklet.
