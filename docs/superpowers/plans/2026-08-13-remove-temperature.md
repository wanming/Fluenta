# Remove Temperature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove temperature from Inklet's UI, persisted configuration, service interfaces, cache keys, and every provider request payload.

**Architecture:** First lock the external JSON contract with failing provider tests, then remove temperature from internal request and translation boundaries, and finally delete the persisted/UI concept while proving legacy configurations still decode. Provider defaults replace Inklet's former global `0.2` sampling value; no model-name branching or replacement generation control is introduced.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, SwiftUI, Foundation `Codable`/`JSONSerialization`, UserDefaults, SHA-256 translation-cache keys.

**Worktree note:** Preserve the concurrent cancellation-safety changes currently present in `Sources/InkletApp/AppCoordinator.swift`, `Sources/InkletCore/SelectionClipboardReader.swift`, `Tests/InkletCoreTests/AppCoordinatorSourceTests.swift`, and `Tests/InkletCoreTests/SelectionClipboardReaderTests.swift`. This plan changes only the two temperature call-site lines in `AppCoordinator.swift`; stage those hunks separately so the unrelated work is not mixed into a temperature commit.

---

### Task 1: Omit temperature from every provider request payload

**Files:**
- Modify: `Tests/InkletCoreTests/OpenAIProviderTests.swift`
- Modify: `Tests/InkletCoreTests/LLMProviderTests.swift`
- Modify: `Sources/InkletCore/OpenAIProvider.swift`
- Modify: `Sources/InkletCore/ChatCompletionProvider.swift`
- Modify: `Sources/InkletCore/AnthropicProvider.swift`
- Modify: `Sources/InkletCore/GeminiProvider.swift`

- [ ] **Step 1: Write failing JSON-contract tests**

In `OpenAIProviderTests`, replace the request-body test with this exact test and add the helper inside the test class:

```swift
func testBuildsResponsesAPIRequestWithoutTemperature() throws {
    let request = TransformationRequest(
        sourceText: "Make this clearer.",
        systemPrompt: "Rewrite in polished English.",
        modeID: "polish",
        modeName: "Polish",
        model: "gpt-4.1-mini",
        temperature: 0.2,
        timeoutSeconds: 10
    )

    let body = OpenAIProvider.makeRequestBody(for: request)
    let json = try encodedJSONObject(body)

    XCTAssertEqual(body.model, "gpt-4.1-mini")
    XCTAssertNil(json["temperature"])
    XCTAssertTrue(body.input.contains(.init(role: "system", content: "Rewrite in polished English.")))
    XCTAssertTrue(body.input.contains(.init(role: "user", content: "Make this clearer.")))
}

private func encodedJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
```

In `LLMProviderTests`, replace the three request-body tests with these versions and add the same helper inside the class:

```swift
func testChatCompletionBuildsOpenAICompatibleRequestWithoutTemperature() throws {
    let body = ChatCompletionProvider.makeRequestBody(for: request)
    let json = try encodedJSONObject(body)

    XCTAssertEqual(body.model, "test-model")
    XCTAssertNil(json["temperature"])
    XCTAssertEqual(body.messages.map(\.role), ["system", "user"])
    XCTAssertEqual(body.messages.map(\.content), ["Rewrite clearly.", "Hello"])
}

func testAnthropicBuildsMessagesRequestWithoutTemperature() throws {
    let body = AnthropicProvider.makeRequestBody(for: request)
    let json = try encodedJSONObject(body)

    XCTAssertEqual(body.model, "test-model")
    XCTAssertNil(json["temperature"])
    XCTAssertEqual(body.system, "Rewrite clearly.")
    XCTAssertEqual(body.messages.first?.role, "user")
    XCTAssertEqual(body.messages.first?.content.first?.text, "Hello")
}

func testGeminiBuildsGenerateContentRequestWithoutGenerationConfig() throws {
    let body = GeminiProvider.makeRequestBody(for: request)
    let json = try encodedJSONObject(body)

    XCTAssertNil(json["generationConfig"])
    XCTAssertEqual(body.systemInstruction.parts.first?.text, "Rewrite clearly.")
    XCTAssertEqual(body.contents.first?.role, "user")
    XCTAssertEqual(body.contents.first?.parts.first?.text, "Hello")
}

private func encodedJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
```

- [ ] **Step 2: Run the provider tests and verify the new assertions fail**

Run:

```bash
swift test --filter OpenAIProviderTests
swift test --filter LLMProviderTests
```

Expected: `testBuildsResponsesAPIRequestWithoutTemperature`, the compatible-chat test, and the Anthropic test fail because `temperature` is present; the Gemini test fails because `generationConfig` is present.

- [ ] **Step 3: Remove temperature from the provider request-body types and builders**

Use this `OpenAIProvider.RequestBody` shape and builder:

```swift
public var model: String
public var input: [InputMessage]

public init(model: String, input: [InputMessage]) {
    self.model = model
    self.input = input
}

public static func makeRequestBody(for request: TransformationRequest) -> RequestBody {
    RequestBody(
        model: request.model,
        input: [
            RequestBody.InputMessage(role: "system", content: request.systemPrompt),
            RequestBody.InputMessage(role: "user", content: request.sourceText)
        ]
    )
}
```

Use this compatible-chat request shape and builder:

```swift
public var model: String
public var messages: [Message]

public static func makeRequestBody(for request: TransformationRequest) -> RequestBody {
    RequestBody(
        model: request.model,
        messages: [
            RequestBody.Message(role: "system", content: request.systemPrompt),
            RequestBody.Message(role: "user", content: request.sourceText)
        ]
    )
}
```

Use this Anthropic request-body field list, coding keys, and builder:

```swift
public var model: String
public var maxTokens: Int
public var system: String
public var messages: [Message]

enum CodingKeys: String, CodingKey {
    case model
    case maxTokens = "max_tokens"
    case system
    case messages
}

public static func makeRequestBody(for request: TransformationRequest) -> RequestBody {
    RequestBody(
        model: request.model,
        maxTokens: 4096,
        system: request.systemPrompt,
        messages: [
            RequestBody.Message(
                role: "user",
                content: [.init(type: "text", text: request.sourceText)]
            )
        ]
    )
}
```

Delete `GeminiProvider.RequestBody.GenerationConfig` and use this request-body shape and builder:

```swift
public var systemInstruction: Content
public var contents: [Content]

public static func makeRequestBody(for request: TransformationRequest) -> RequestBody {
    RequestBody(
        systemInstruction: .init(role: nil, parts: [.init(text: request.systemPrompt)]),
        contents: [
            .init(role: "user", parts: [.init(text: request.sourceText)])
        ]
    )
}
```

- [ ] **Step 4: Run the provider tests and verify they pass**

Run:

```bash
swift test --filter OpenAIProviderTests
swift test --filter LLMProviderTests
```

Expected: both commands exit 0; all provider body, response parsing, and error mapping tests pass.

- [ ] **Step 5: Commit the provider payload change**

```bash
git add Sources/InkletCore/OpenAIProvider.swift Sources/InkletCore/ChatCompletionProvider.swift Sources/InkletCore/AnthropicProvider.swift Sources/InkletCore/GeminiProvider.swift Tests/InkletCoreTests/OpenAIProviderTests.swift Tests/InkletCoreTests/LLMProviderTests.swift
git commit -m "Omit temperature from provider requests"
```

### Task 2: Remove temperature from transformation and selection-translation boundaries

**Files:**
- Modify: `Sources/InkletCore/TransformationTypes.swift`
- Modify: `Sources/InkletCore/TransformationService.swift`
- Modify: `Sources/InkletCore/SelectionTranslationCache.swift`
- Modify: `Sources/InkletCore/SelectionTranslationService.swift`
- Modify: `Sources/InkletApp/AppCoordinator.swift`
- Modify: `Sources/InkletApp/InkletPopoverView.swift`
- Modify: `Tests/InkletCoreTests/OpenAIProviderTests.swift`
- Modify: `Tests/InkletCoreTests/LLMProviderTests.swift`
- Modify: `Tests/InkletCoreTests/TransformationServiceTests.swift`
- Modify: `Tests/InkletCoreTests/SelectionTranslationCacheTests.swift`
- Modify: `Tests/InkletCoreTests/SelectionTranslationServiceTests.swift`

- [ ] **Step 1: Add a failing cache-key serialization test**

Add this test to `SelectionTranslationCacheTests` while the current key still has the property:

```swift
func testCacheKeyDoesNotEncodeTemperature() throws {
    let data = try JSONEncoder().encode(cacheKey())
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertNil(json["temperature"])
}
```

- [ ] **Step 2: Run the cache test and verify it fails for the expected reason**

Run:

```bash
swift test --filter SelectionTranslationCacheTests/testCacheKeyDoesNotEncodeTemperature
```

Expected: FAIL because the encoded cache key contains `temperature`.

- [ ] **Step 3: Remove temperature from the shared transformation request and service API**

Replace the request fields and initializer with this exact API in `TransformationTypes.swift`:

```swift
public struct TransformationRequest: Equatable, Sendable {
    public var sourceText: String
    public var systemPrompt: String
    public var modeID: String
    public var modeName: String
    public var model: String
    public var timeoutSeconds: TimeInterval

    public init(
        sourceText: String,
        systemPrompt: String,
        modeID: String,
        modeName: String,
        model: String,
        timeoutSeconds: TimeInterval
    ) {
        self.sourceText = sourceText
        self.systemPrompt = systemPrompt
        self.modeID = modeID
        self.modeName = modeName
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }
}
```

Use this signature and request construction in `TransformationService.swift`:

```swift
public func transform(
    sourceText: String,
    mode: PromptMode,
    model: String,
    timeoutSeconds: TimeInterval
) async throws -> TransformationResult {
    let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedSource.isEmpty else {
        throw TransformationError.emptySource
    }

    let request = TransformationRequest(
        sourceText: trimmedSource,
        systemPrompt: mode.systemPrompt,
        modeID: mode.id,
        modeName: mode.name,
        model: model,
        timeoutSeconds: timeoutSeconds
    )

    let result = try await withTimeout(seconds: timeoutSeconds) {
        try await provider.transform(request)
    }
    let trimmedOutput = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedOutput.isEmpty else {
        throw TransformationError.emptyResponse
    }

    return TransformationResult(
        outputText: trimmedOutput,
        providerMetadata: result.providerMetadata,
        elapsedMilliseconds: result.elapsedMilliseconds
    )
}
```

- [ ] **Step 4: Remove temperature from translation service and cache interfaces**

Use this cache-key definition:

```swift
public struct SelectionTranslationCacheKey: Codable, Equatable, Sendable {
    public var sourceText: String
    public var targetLanguageName: String
    public var systemPrompt: String
    public var model: String
    public var providerID: String

    public init(
        sourceText: String,
        targetLanguageName: String,
        systemPrompt: String,
        model: String,
        providerID: String
    ) {
        self.sourceText = sourceText
        self.targetLanguageName = targetLanguageName
        self.systemPrompt = systemPrompt
        self.model = model
        self.providerID = providerID
    }
}
```

Use these signatures and calls in `SelectionTranslationService.swift`:

```swift
public typealias Transform = @Sendable (
    _ sourceText: String,
    _ systemPrompt: String,
    _ model: String,
    _ timeoutSeconds: TimeInterval
) async throws -> String

public init(provider: any LLMProvider) {
    let transformationService = TransformationService(provider: provider)
    self.init { sourceText, systemPrompt, model, timeoutSeconds in
        let result = try await transformationService.transform(
            sourceText: sourceText,
            mode: Self.promptMode(systemPrompt: systemPrompt),
            model: model,
            timeoutSeconds: timeoutSeconds
        )
        return result.outputText
    }
}

public func translate(
    sourceText: String,
    systemPrompt: String,
    model: String,
    timeoutSeconds: TimeInterval
) async throws -> String {
    try await transform(sourceText, systemPrompt, model, timeoutSeconds)
}
```

Use this cached-service signature and data flow:

```swift
public func translate(
    sourceText: String,
    targetLanguageName: String,
    systemPrompt: String,
    model: String,
    providerID: String,
    timeoutSeconds: TimeInterval,
    now: Date = Date()
) async throws -> String {
    let cacheKey = SelectionTranslationCacheKey(
        sourceText: sourceText,
        targetLanguageName: targetLanguageName,
        systemPrompt: systemPrompt,
        model: model,
        providerID: providerID
    )

    if let cachedTranslation = try? cache.translation(for: cacheKey, now: now) {
        return cachedTranslation
    }

    let translated = try await service.translate(
        sourceText: sourceText,
        systemPrompt: systemPrompt,
        model: model,
        timeoutSeconds: timeoutSeconds
    )
    try? cache.storeTranslation(translated, for: cacheKey, now: now)
    return translated
}
```

- [ ] **Step 5: Update app call sites to the reduced interfaces**

Use this selection-translation call in `AppCoordinator.swift`:

```swift
let translated = try await service.translate(
    sourceText: sourceText,
    targetLanguageName: targetLanguageName,
    systemPrompt: systemPrompt,
    model: config.model,
    providerID: providerID,
    timeoutSeconds: config.timeoutSeconds
)
```

Use this transformation call for voice cleanup in `AppCoordinator.swift`:

```swift
let result = try await TransformationService(provider: provider).transform(
    sourceText: source,
    mode: mode,
    model: config.model,
    timeoutSeconds: config.timeoutSeconds
)
```

In `InkletPopoverView.startTransformation`, delete the captured `config.temperature` local and use this call:

```swift
let result = try await transformationService.transform(
    sourceText: source,
    mode: mode,
    model: model,
    timeoutSeconds: timeoutSeconds
)
```

- [ ] **Step 6: Update tests to construct and call the reduced APIs**

Delete every `temperature: 0.2` argument from `TransformationRequest` initializers in `OpenAIProviderTests` and `LLMProviderTests`. In `TransformationServiceTests`, use this argument shape for all five service calls, preserving each test's existing source, timeout, and assertions:

```swift
try await service.transform(
    sourceText: "hello",
    mode: mode,
    model: "test-model",
    timeoutSeconds: 1
)
```

Update the injected translation closure and direct call in `SelectionTranslationServiceTests` to four values:

```swift
let service = SelectionTranslationService(
    transform: { source, systemPrompt, model, timeoutSeconds in
        XCTAssertEqual(source, "hello")
        XCTAssertEqual(systemPrompt, "Translate into Japanese.")
        XCTAssertEqual(model, "test-model")
        XCTAssertEqual(timeoutSeconds, 3)
        return "こんにちは"
    }
)

let result = try await service.translate(
    sourceText: "hello",
    systemPrompt: "Translate into Japanese.",
    model: "test-model",
    timeoutSeconds: 3
)
```

Change cached-test closures from five ignored parameters to four:

```swift
SelectionTranslationService { _, _, _, _ in
    XCTFail("Provider should not be called for cached translations.")
    return "network"
}
```

Remove temperature from all `SelectionTranslationCacheKey` and cached-service calls. The cache helper becomes:

```swift
private func cacheKey(
    sourceText: String = "hello",
    targetLanguageName: String = "Simplified Chinese",
    systemPrompt: String = "Translate into Simplified Chinese.",
    model: String = "gpt-test",
    providerID: String = "openai"
) -> SelectionTranslationCacheKey {
    SelectionTranslationCacheKey(
        sourceText: sourceText,
        targetLanguageName: targetLanguageName,
        systemPrompt: systemPrompt,
        model: model,
        providerID: providerID
    )
}
```

In `testCacheKeyIncludesTranslationSettings`, keep the system-prompt, model, and provider assertions and delete only the temperature-difference assertion.

- [ ] **Step 7: Run focused service and cache tests**

Run:

```bash
swift test --filter TransformationServiceTests
swift test --filter SelectionTranslationServiceTests
swift test --filter SelectionTranslationCacheTests
swift test --filter OpenAIProviderTests
swift test --filter LLMProviderTests
```

Expected: all five commands exit 0. The new cache serialization test passes, and provider tests still confirm that payloads omit temperature.

- [ ] **Step 8: Verify the remaining production references are configuration/UI-only**

Run:

```bash
rg -n -i 'temperature' Sources Tests
```

Expected: matches remain only in `ConfigStore.swift`, `SettingsView.swift`, `InkletLocalization.swift`, `ConfigStoreTests.swift`, and the not-yet-added Task 3 removal tests. No provider, transformation, translation, cache, coordinator, or popover matches remain.

- [ ] **Step 9: Commit the service and cache change**

```bash
git add Sources/InkletCore/TransformationTypes.swift Sources/InkletCore/TransformationService.swift Sources/InkletCore/SelectionTranslationCache.swift Sources/InkletCore/SelectionTranslationService.swift Sources/InkletApp/InkletPopoverView.swift Tests/InkletCoreTests/OpenAIProviderTests.swift Tests/InkletCoreTests/LLMProviderTests.swift Tests/InkletCoreTests/TransformationServiceTests.swift Tests/InkletCoreTests/SelectionTranslationCacheTests.swift Tests/InkletCoreTests/SelectionTranslationServiceTests.swift
git add -p Sources/InkletApp/AppCoordinator.swift
git diff --cached --check
git diff --cached -- Sources/InkletApp/AppCoordinator.swift
git commit -m "Remove temperature from transformation flow"
```

At the `git add -p` prompt, stage only the hunks that remove `temperature: config.temperature`; leave cancellation guards and selection-reader changes unstaged. The cached AppCoordinator diff must contain exactly the two reduced service calls and none of the concurrent cancellation-safety lines.

### Task 3: Remove persisted temperature, Settings UI, localization, and documentation

**Files:**
- Modify: `Tests/InkletCoreTests/ConfigStoreTests.swift`
- Modify: `Tests/InkletCoreTests/SettingsViewSourceTests.swift`
- Modify: `Sources/InkletCore/ConfigStore.swift`
- Modify: `Sources/InkletApp/SettingsView.swift`
- Modify: `Sources/InkletApp/InkletLocalization.swift`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/manual-test-checklist.md`

- [ ] **Step 1: Write failing legacy-config and Settings-source tests**

Add this compatibility test to `ConfigStoreTests`:

```swift
func testLegacyTemperatureIsIgnoredWhenConfigurationIsResaved() throws {
    let data = #"{"model":"saved-model","temperature":0.8}"#.data(using: .utf8)!

    let config = try JSONDecoder().decode(AppConfig.self, from: data)
    let encodedData = try JSONEncoder().encode(config)
    let encodedJSON = try XCTUnwrap(
        JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
    )

    XCTAssertEqual(config.model, "saved-model")
    XCTAssertNil(encodedJSON["temperature"])
}
```

Add these tests to `SettingsViewSourceTests`:

```swift
func testTemperatureSettingIsRemoved() throws {
    let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/SettingsView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("settings.row.temperature"))
    XCTAssertFalse(source.contains("settings.help.temperature"))
    XCTAssertFalse(source.contains("config.temperature"))
}

func testTemperatureLocalizationKeysAreRemoved() throws {
    let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/InkletLocalization.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("settings.row.temperature"))
    XCTAssertFalse(source.contains("settings.help.temperature"))
}
```

- [ ] **Step 2: Run the new tests and verify they fail for the expected reasons**

Run:

```bash
swift test --filter ConfigStoreTests/testLegacyTemperatureIsIgnoredWhenConfigurationIsResaved
swift test --filter SettingsViewSourceTests/testTemperature
```

Expected: the config test fails because re-encoding still writes `temperature`; the source tests fail because the Settings binding and localization keys still exist.

- [ ] **Step 3: Remove temperature from `AppConfig` while preserving legacy decode compatibility**

The top-level stored fields and initializer become:

```swift
public var version: Int
public var providerID: String
public var model: String
public var timeoutSeconds: Double
public var hotkey: String
public var appearance: AppAppearance
public var promptModes: [PromptMode]
public var customOpenAICompatibleEndpoint: String
public var voiceInput: VoiceInputConfig
public var selectionActions: SelectionActionsConfig

public init(
    version: Int = AppConfig.currentVersion,
    providerID: String = LLMProviderPreset.openAI.id,
    model: String,
    timeoutSeconds: Double,
    hotkey: String,
    appearance: AppAppearance = .system,
    promptModes: [PromptMode],
    customOpenAICompatibleEndpoint: String = LLMProviderPreset.customOpenAICompatible.endpoint.absoluteString,
    voiceInput: VoiceInputConfig = VoiceInputConfig.defaultConfig(),
    selectionActions: SelectionActionsConfig = SelectionActionsConfig.defaultConfig()
) {
    self.version = version
    self.providerID = providerID
    self.model = model
    self.timeoutSeconds = timeoutSeconds
    self.hotkey = hotkey
    self.appearance = appearance
    self.promptModes = promptModes
    self.customOpenAICompatibleEndpoint = customOpenAICompatibleEndpoint
    self.voiceInput = voiceInput
    self.selectionActions = selectionActions
}
```

The default construction becomes:

```swift
AppConfig(
    providerID: LLMProviderPreset.openAI.id,
    model: LLMProviderPreset.openAI.defaultModel,
    timeoutSeconds: 20,
    hotkey: "⌥Space",
    appearance: .system,
    promptModes: PromptModeStore.defaultStore().modes
)
```

Delete `temperature` from `CodingKeys`, delete its decoder assignment, and delete its encoder call. Do not add a replacement key or increment `AppConfig.currentVersion`; keyed decoding ignores the legacy JSON member.

- [ ] **Step 4: Remove the Settings state normalization and UI row**

Delete this load-time line from `SettingsViewModel.init`:

```swift
loadedConfig.temperature = min(max(loadedConfig.temperature, 0), 1)
```

Delete this save-time line from `SettingsViewModel.save`:

```swift
config.temperature = min(max(config.temperature, 0), 1)
```

Delete the complete settings row:

```swift
settingsRow(L10n.text("settings.row.temperature"), help: L10n.text("settings.help.temperature")) {
    HStack(spacing: 12) {
        Slider(value: $model.config.temperature, in: 0...1, step: 0.1)
        Text(model.config.temperature, format: .number.precision(.fractionLength(1)))
            .font(.body.monospacedDigit())
            .frame(width: 42, alignment: .trailing)
    }
    .frame(maxWidth: 520)
}
```

Leave the existing Timeout row immediately after the Model row.

- [ ] **Step 5: Remove stale tests, localization keys, and documentation claims**

In `ConfigStoreTests`, delete the three obsolete operations:

```swift
XCTAssertEqual(config.temperature, 0.2)
config.temperature = 0.7
XCTAssertEqual(config.temperature, AppConfig.defaultConfig().temperature)
```

Delete every `settings.row.temperature` and `settings.help.temperature` entry from all language dictionaries in `InkletLocalization.swift`.

Change the README settings sentences to these exact versions:

```markdown
- Lets you edit prompt modes, OpenAI model, timeout, writing shortcut, voice shortcut, voice recording mode, microphone, speech preset, speech endpoint, speech model, post-transcription handling, selection translation language, selection Translate prompt, Force Selection mode, AI pronunciation voice, and AI pronunciation speed.
```

```markdown
- 可以编辑 prompt modes、OpenAI 模型、timeout、写作快捷键、语音快捷键、语音录音方式、麦克风、speech preset、speech endpoint、speech model、转写后处理方式、选区翻译语言、选区 Translate prompt、AI 发音声音和 AI 发音速度。
```

Change the manual Settings checklist line to:

```markdown
- General: change hotkey, timeout, language, and appearance.
```

- [ ] **Step 6: Run focused configuration and Settings tests**

Run:

```bash
swift test --filter ConfigStoreTests
swift test --filter SettingsViewSourceTests
```

Expected: both commands exit 0. The legacy JSON decodes, re-encoding omits the obsolete key, and the Settings/localization source contains no temperature control or copy.

- [ ] **Step 7: Prove the concept is absent outside the approved design records**

Run:

```bash
rg -n -i 'temperature' Sources Tests README.md README.zh-CN.md docs/manual-test-checklist.md
```

Expected: no output and exit status 1, which is ripgrep's normal no-match status.

- [ ] **Step 8: Commit configuration, UI, localization, and docs**

```bash
git add Sources/InkletCore/ConfigStore.swift Sources/InkletApp/SettingsView.swift Sources/InkletApp/InkletLocalization.swift Tests/InkletCoreTests/ConfigStoreTests.swift Tests/InkletCoreTests/SettingsViewSourceTests.swift README.md README.zh-CN.md docs/manual-test-checklist.md
git commit -m "Remove temperature setting"
```

### Task 4: Run complete verification and local UI smoke testing

**Files:**
- Verify only: all modified production, test, localization, and documentation files

- [ ] **Step 1: Run the complete test suite**

Run:

```bash
swift test
```

Expected: exit 0 with zero failed tests.

- [ ] **Step 2: Run a strict compiler build**

Run:

```bash
swift build -Xswiftc -warnings-as-errors
```

Expected: exit 0 with no compiler warnings or errors.

- [ ] **Step 3: Build, install, and launch the stable local app bundle**

Run:

```bash
scripts/run-local-app.sh
```

Expected: the signed `com.tomwan.inklet.local` bundle is installed at `/Applications/Inklet Local.app` and launches successfully without creating a worktree-local app bundle.

- [ ] **Step 4: Complete the targeted UI and request smoke checklist**

In `/Applications/Inklet Local.app`:

1. Open Settings in English and confirm Model is followed by Timeout, with no Temperature row or extra gap.
2. Switch the interface to Simplified Chinese and confirm the same layout fits without clipping or overlap.
3. Run one Writing Assistant transformation with the current OpenAI model and confirm success, insertion, retry, cancellation, and return-to-idle controls retain their existing behavior.
4. Translate one selection twice and confirm the second request uses the new cache entry; confirm pronunciation controls remain unaffected.
5. Trigger an API error or use an invalid key temporarily, confirm the existing error appears, then restore the valid local key without saving the temporary value to source control.

Expected: all checks match the approved design; no Temperature UI or unsupported-parameter error appears.

- [ ] **Step 5: Run final repository checks**

Run:

```bash
rg -n -i 'temperature' Sources Tests README.md README.zh-CN.md docs/manual-test-checklist.md
git diff --check
git status --short
```

Expected: ripgrep reports no matches; `git diff --check` exits 0; status contains no uncommitted temperature implementation files. The four preserved cancellation-safety files may remain modified if their owning work is still in progress. The committed design and plan remain under `docs/superpowers/` as the intentional historical record of the removed concept.
