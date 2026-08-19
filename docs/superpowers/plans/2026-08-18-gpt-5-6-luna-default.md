# GPT-5.6 Luna Default Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `gpt-5.6-luna` Inklet's OpenAI text-generation default and migrate pre-version-3 configurations that still use the exact former default, `gpt-5.4-mini`.

**Architecture:** Keep the product default centralized in `LLMProviderPreset.openAI`. Bump `AppConfig` to version 3 and perform an exact, version-gated migration inside decoding so all runtime consumers receive Luna while current-version users can still deliberately select the former model.

**Tech Stack:** Swift 6, Foundation `Codable`, XCTest, Swift Package Manager.

---

## File Map

- Modify `Sources/InkletCore/LLMProviderPreset.swift`: active OpenAI default model ID.
- Modify `Sources/InkletCore/ConfigStore.swift`: configuration version and one-time former-default migration.
- Modify `Tests/InkletCoreTests/LLMProviderTests.swift`: exact provider-default regression coverage.
- Modify `Tests/InkletCoreTests/ConfigStoreTests.swift`: fresh default, versioned migration, exact matching, and current-version preservation coverage.

No Settings, localization, README, bundled model-catalog, speech, TTS, OpenRouter, or custom-compatible files change. Settings already derives and inserts the active preset default dynamically.

### Task 1: Make Luna the active OpenAI default

**Files:**
- Modify: `Sources/InkletCore/LLMProviderPreset.swift:37-45`
- Test: `Tests/InkletCoreTests/LLMProviderTests.swift:34-46`
- Test: `Tests/InkletCoreTests/ConfigStoreTests.swift:134-148`

- [ ] **Step 1: Change the default expectations to Luna**

In `testProviderDefaultsUseCurrentFastModels`, change only the native OpenAI expectation; leave the namespaced OpenRouter and custom-compatible expectations unchanged:

```swift
XCTAssertEqual(defaults["openai"], "gpt-5.6-luna")
XCTAssertEqual(defaults["openrouter"], "openai/gpt-5.4-mini")
XCTAssertEqual(defaults["custom-openai-compatible"], "gpt-5-mini")
```

In `testDefaultConfigMatchesSpec`, make the product default explicit while retaining the preset relationship:

```swift
XCTAssertEqual(config.providerID, LLMProviderPreset.openAI.id)
XCTAssertEqual(config.model, "gpt-5.6-luna")
XCTAssertEqual(config.model, LLMProviderPreset.openAI.defaultModel)
```

- [ ] **Step 2: Run the focused tests to verify RED**

Run:

```bash
swift test --filter LLMProviderTests.testProviderDefaultsUseCurrentFastModels
swift test --filter ConfigStoreTests.testDefaultConfigMatchesSpec
```

Expected: both commands fail because the current native OpenAI default is `gpt-5.4-mini`.

- [ ] **Step 3: Change the native OpenAI preset default**

In `LLMProviderPreset.openAI`, replace only the model ID:

```swift
public static let openAI = LLMProviderPreset(
    id: "openai",
    name: "OpenAI",
    defaultModel: "gpt-5.6-luna",
    apiKeyPlaceholder: "sk-...",
    keychainService: KeychainStore.defaultService,
    kind: .openAIResponses,
    endpoint: URL(string: "https://api.openai.com/v1/responses")!
)
```

Do not change the OpenRouter or custom-compatible defaults.

- [ ] **Step 4: Run the focused tests to verify GREEN**

Run:

```bash
swift test --filter LLMProviderTests.testProviderDefaultsUseCurrentFastModels
swift test --filter ConfigStoreTests.testDefaultConfigMatchesSpec
```

Expected: both commands pass with zero failures.

- [ ] **Step 5: Commit the default change**

```bash
git add Sources/InkletCore/LLMProviderPreset.swift \
  Tests/InkletCoreTests/LLMProviderTests.swift \
  Tests/InkletCoreTests/ConfigStoreTests.swift
git diff --cached --check
git diff --cached
git commit -m "Use GPT-5.6 Luna as the default model"
```

### Task 2: Migrate the exact former default once

**Files:**
- Modify: `Sources/InkletCore/ConfigStore.swift:11-13,98-110`
- Test: `Tests/InkletCoreTests/ConfigStoreTests.swift:191-208`

- [ ] **Step 1: Add failing migration tests**

Add these tests after `testConfigDecodeFallsBackToDefaultsForMissingFields`:

```swift
func testConfigDecodeMigratesFormerOpenAIDefaultToLuna() throws {
    let data = """
    {
        "version": 2,
        "providerID": "openai",
        "model": "gpt-5.4-mini"
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder().decode(AppConfig.self, from: data)

    XCTAssertEqual(AppConfig.currentVersion, 3)
    XCTAssertEqual(config.version, AppConfig.currentVersion)
    XCTAssertEqual(config.model, "gpt-5.6-luna")
}

func testConfigDecodePreservesOtherLegacyOpenAIModels() throws {
    let savedModels = [
        "gpt-5.4",
        "openai/gpt-5.4-mini",
        "gpt-5.4-mini-2026-05-21",
        "GPT-5.4-MINI",
        " gpt-5.4-mini "
    ]

    for savedModel in savedModels {
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "providerID": "openai",
            "model": savedModel
        ])

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.version, AppConfig.currentVersion)
        XCTAssertEqual(config.model, savedModel)
    }
}

func testCurrentConfigPreservesExplicitFormerOpenAIDefault() throws {
    let data = """
    {
        "version": 3,
        "providerID": "openai",
        "model": "gpt-5.4-mini"
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder().decode(AppConfig.self, from: data)

    XCTAssertEqual(config.version, AppConfig.currentVersion)
    XCTAssertEqual(config.model, "gpt-5.4-mini")
}
```

The existing `testConfigDecodeMigratesLegacyProvidersToOpenAI` remains the regression for non-OpenAI configurations falling back to the current OpenAI default.

- [ ] **Step 2: Run the configuration suite to verify RED**

Run: `swift test --filter ConfigStoreTests`

Expected: the suite fails because `AppConfig.currentVersion` is still 2 and a version-2 OpenAI config still preserves `gpt-5.4-mini`.

- [ ] **Step 3: Implement the versioned exact-match migration**

At the top of `AppConfig`, bump the current version and add fixed migration constants:

```swift
public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 3

    private static let lunaDefaultMigrationVersion = 3
    private static let formerOpenAIDefaultModel = "gpt-5.4-mini"
```

Replace the current provider/model decode branch with:

```swift
let decodedProviderID = try container.decodeIfPresent(
    String.self,
    forKey: .providerID
) ?? defaults.providerID
providerID = LLMProviderPreset.openAI.id
if decodedProviderID == LLMProviderPreset.openAI.id {
    let decodedModel = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
    if decodedVersion < AppConfig.lunaDefaultMigrationVersion,
       decodedModel == AppConfig.formerOpenAIDefaultModel {
        model = defaults.model
    } else {
        model = decodedModel
    }
} else {
    model = defaults.model
}
```

Keep `lunaDefaultMigrationVersion` fixed at 3 rather than comparing against `currentVersion`. A future version bump must not re-run this migration for a version-3 user who deliberately selected `gpt-5.4-mini`.

- [ ] **Step 4: Run focused provider and configuration tests to verify GREEN**

Run:

```bash
swift test --filter ConfigStoreTests
swift test --filter LLMProviderTests
```

Expected: both suites pass with zero failures, including the existing non-OpenAI fallback coverage.

- [ ] **Step 5: Commit the migration**

```bash
git add Sources/InkletCore/ConfigStore.swift \
  Tests/InkletCoreTests/ConfigStoreTests.swift
git diff --cached --check
git diff --cached
git commit -m "Migrate the former default model to Luna"
```

### Task 3: Verify the completed change

**Files:**
- Verify: `Sources/InkletCore/LLMProviderPreset.swift`
- Verify: `Sources/InkletCore/ConfigStore.swift`
- Verify: `Tests/InkletCoreTests/LLMProviderTests.swift`
- Verify: `Tests/InkletCoreTests/ConfigStoreTests.swift`

- [ ] **Step 1: Run the complete automated test suite**

Run: `swift test`

Expected: the package builds and every XCTest and Swift Testing test passes with zero failures.

- [ ] **Step 2: Check whitespace and repository state**

Run:

```bash
git diff --check
git status --short --branch
```

Expected: `git diff --check` emits no output and status shows branch `codex/default-gpt-5-6-luna` with no uncommitted files.

- [ ] **Step 3: Review the implementation diff against the approved design**

Run:

```bash
git diff --stat 5eeef63..HEAD
git diff 5eeef63..HEAD -- \
  Sources/InkletCore/LLMProviderPreset.swift \
  Sources/InkletCore/ConfigStore.swift \
  Tests/InkletCoreTests/LLMProviderTests.swift \
  Tests/InkletCoreTests/ConfigStoreTests.swift
```

Expected: only the active OpenAI default, versioned exact-match migration, and focused tests differ from the approved-design commit. There are no changes to OpenRouter, custom-compatible, catalog, speech, TTS, Settings, localization, or README files.

- [ ] **Step 4: Record manual QA as intentionally unnecessary**

No app launch is required. This change adds no UI layout, interaction, permission, audio, clipboard, or text-insertion behavior; the Settings default label and picker already derive from the tested preset value.
