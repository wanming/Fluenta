# Legacy Sandbox Data Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move production and local Inklet builds to bundle-qualified storage while importing each matching legacy sandbox container safely, idempotently, and without overwriting post-upgrade user changes.

**Architecture:** A shared path value defines every bundle-specific file. A synchronous, versioned `LegacySandboxDataMigrator` runs under a cross-process lock before `AppDelegate` construction and independently migrates preferences, legacy plaintext credentials, and history; disposable cache data is not imported. When App Data protection blocks automatic access, a localized Settings card performs a canonical-path-validated import while the file-panel grant is alive, freezes mutations, and relaunches before normal interaction resumes.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Security/Keychain, Darwin file locking, AppKit, SwiftUI/Combine, JSONL, XCTest, Swift Package Manager.

---

## Execution Order And Ownership

Execute this plan before `2026-08-08-generic-selection-reading.md` and before removing App Sandbox. Automated tests are valid while the build is still sandboxed, but do not hand-test the relocated live stores until the direct-distribution plan lands. This plan owns storage paths, migration, startup ordering, assisted-import UI, and migration localization. The direct-distribution plan owns reset-script changes and must consume the exact paths defined here.

## File Structure

Create:

- `Sources/InkletCore/InkletStoragePaths.swift` — bundle-qualified store, lock, legacy-container, and diagnostic paths.
- `Sources/InkletCore/InkletPreferenceKeys.swift` — one registry for the five static legacy keys and dynamic credential prefix.
- `Sources/InkletCore/LegacyMigrationFileSystem.swift` — throwing filesystem abstraction and error classification.
- `Sources/InkletCore/LegacyMigrationLock.swift` — bounded cross-process `flock` wrapper.
- `Sources/InkletCore/LegacySandboxDataMigrator.swift` — versioned state, fingerprints, component migration, outcomes, and source validation.
- `Sources/InkletApp/LegacyMigrationPresentationModel.swift` — nonblocking notice/import state and maintenance UI state.
- `Tests/InkletCoreTests/InkletStoragePathsTests.swift`
- `Tests/InkletCoreTests/LegacyMigrationLockTests.swift`
- `Tests/InkletCoreTests/LegacySandboxDataMigratorTests.swift`
- `Tests/InkletCoreTests/LegacyMigrationSourceValidationTests.swift`
- `Tests/InkletCoreTests/LegacyMigrationAppSourceTests.swift`
- `Tests/InkletCoreTests/LegacyMigrationLocalizationTests.swift`

Modify:

- `Sources/InkletCore/HistoryStore.swift`
- `Sources/InkletCore/SelectionTranslationCache.swift`
- `Sources/InkletCore/ConfigStore.swift`
- `Sources/InkletCore/ModelCatalogService.swift`
- `Sources/InkletCore/VoiceInputCoordinator.swift`
- `Sources/InkletApp/InkletLocalization.swift`
- `Sources/InkletApp/SelectionActionDiagnostics.swift`
- `Sources/InkletApp/SelectionActionWindowController.swift`
- `Sources/InkletApp/SettingsView.swift`
- `Sources/InkletApp/SettingsWindowController.swift`
- `Sources/InkletApp/InkletPopoverView.swift`
- `Sources/InkletApp/InkletPopoverWindowController.swift`
- `Sources/InkletApp/AppCoordinator.swift`
- `Sources/InkletApp/main.swift`
- `Tests/InkletCoreTests/HistoryStoreTests.swift`
- `Tests/InkletCoreTests/SelectionTranslationCacheTests.swift`
- `Tests/InkletCoreTests/ConfigStoreTests.swift`

### Task 1: Qualify every persistent and diagnostic path by bundle identifier

**Files:**

- Create: `Sources/InkletCore/InkletStoragePaths.swift`
- Create: `Tests/InkletCoreTests/InkletStoragePathsTests.swift`
- Modify: `Sources/InkletCore/HistoryStore.swift`
- Modify: `Sources/InkletCore/SelectionTranslationCache.swift`
- Modify: `Sources/InkletApp/SelectionActionDiagnostics.swift`
- Modify: corresponding store tests

- [ ] **Step 1: Write failing exact-path tests**

Create tests using `/Users/test/Library/Application Support` and `/tmp/test` injections. Assert these exact values:

```swift
let production = InkletStoragePaths(
    bundleIdentifier: "com.tomwan.inklet",
    applicationSupportDirectory: URL(fileURLWithPath: "/Users/test/Library/Application Support"),
    temporaryDirectory: URL(fileURLWithPath: "/tmp/test")
)
XCTAssertEqual(
    production.applicationSupportRootURL.path,
    "/Users/test/Library/Application Support/com.tomwan.inklet"
)
XCTAssertEqual(production.historyFileURL.lastPathComponent, "history.jsonl")
XCTAssertEqual(production.translationCacheFileURL.lastPathComponent, "selection-translation-cache.json")
XCTAssertEqual(production.migrationLockFileURL.lastPathComponent, "legacy-migration.lock")
XCTAssertEqual(
    production.selectionDiagnosticsFileURL.lastPathComponent,
    "InkletSelectionActions.com.tomwan.inklet.log"
)
```

Repeat for `com.tomwan.inklet.local` and assert the two roots and diagnostics URLs differ. Add a test that `.current(bundle:fileManager:)` throws `.missingBundleIdentifier` for a bundle without an identifier.

- [ ] **Step 2: Run the path tests and confirm RED**

```bash
swift test --filter InkletStoragePathsTests
```

Expected: compilation fails because `InkletStoragePaths` does not exist.

- [ ] **Step 3: Implement the shared path value**

Create this public shape:

```swift
public struct InkletStoragePaths: Equatable, Sendable {
    public static let productionBundleIdentifier = "com.tomwan.inklet"
    public static let localBundleIdentifier = "com.tomwan.inklet.local"

    public let bundleIdentifier: String
    public let applicationSupportRootURL: URL
    public let historyFileURL: URL
    public let translationCacheFileURL: URL
    public let migrationLockFileURL: URL
    public let selectionDiagnosticsFileURL: URL

    public init(
        bundleIdentifier: String,
        applicationSupportDirectory: URL,
        temporaryDirectory: URL
    )

    public init(
        bundleIdentifier: String,
        applicationSupportRootURL: URL,
        temporaryDirectory: URL
    )

    public static func current(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> InkletStoragePaths
}

public enum InkletStoragePathsError: Error, Equatable {
    case missingBundleIdentifier
}
```

Derive the root as `Application Support/<bundleIdentifier>`. Do not fall back to a shared `Inklet` directory when the identifier is missing.

- [ ] **Step 4: Route stores and diagnostics through the path value**

Change the default URL factories to accept `InkletStoragePaths` and make production initializers resolve `.current()` once. Keep explicit `fileURL:` initializers for tests. Do not inspect or copy the legacy cache. Change diagnostics to use `selectionDiagnosticsFileURL`, never the fixed `InkletSelectionActions.log` filename.

- [ ] **Step 5: Run tests and commit**

```bash
swift test --filter 'InkletStoragePathsTests|HistoryStoreTests|SelectionTranslationCacheTests'
git add Sources/InkletCore/InkletStoragePaths.swift Sources/InkletCore/HistoryStore.swift Sources/InkletCore/SelectionTranslationCache.swift Sources/InkletApp/SelectionActionDiagnostics.swift Tests/InkletCoreTests/InkletStoragePathsTests.swift Tests/InkletCoreTests/HistoryStoreTests.swift Tests/InkletCoreTests/SelectionTranslationCacheTests.swift
git commit -m "Qualify app storage by bundle identifier"
```

Expected: focused tests pass.

### Task 2: Centralize migratable preference keys and remove runtime plaintext credential fallback

**Files:**

- Create: `Sources/InkletCore/InkletPreferenceKeys.swift`
- Modify: `Sources/InkletCore/ConfigStore.swift`
- Modify: `Sources/InkletCore/ModelCatalogService.swift`
- Modify: `Sources/InkletApp/InkletLocalization.swift`
- Modify: `Sources/InkletApp/SettingsWindowController.swift`
- Modify: `Sources/InkletApp/SelectionActionWindowController.swift`
- Modify: `Tests/InkletCoreTests/ConfigStoreTests.swift`

- [ ] **Step 1: Write failing registry and Keychain-only tests**

Assert the registry contains exactly these five static keys and parses only nonempty dynamic provider IDs:

```swift
XCTAssertEqual(Set(InkletPreferenceKeys.recognizedLegacyKeys), [
    "appConfig",
    "modelCatalogSnapshot",
    "InkletInterfaceLanguage",
    "didCompleteOnboarding",
    "SelectionActionWindowController.translationPanelSize"
])
XCTAssertEqual(
    InkletPreferenceKeys.providerID(fromLegacyKey: "providerAPIKey.openai"),
    "openai"
)
XCTAssertNil(InkletPreferenceKeys.providerID(fromLegacyKey: "providerAPIKey."))
XCTAssertNil(InkletPreferenceKeys.providerID(fromLegacyKey: "other.openai"))
```

Replace the existing `testLocalAPIKeyStoreMigratesLegacyUserDefaultsKeyToKeychain` with a test that puts a stale plaintext value in `UserDefaults`, returns no Keychain item, and expects `loadAPIKey` to return `nil` without writing the stale value.

- [ ] **Step 2: Run tests and confirm RED**

```bash
swift test --filter ConfigStoreTests
```

Expected: missing registry compile failure, then the current runtime fallback returns the stale plaintext key.

- [ ] **Step 3: Implement the exact key registry**

```swift
public enum InkletPreferenceKeys {
    public static let appConfig = "appConfig"
    public static let modelCatalogSnapshot = "modelCatalogSnapshot"
    public static let interfaceLanguage = "InkletInterfaceLanguage"
    public static let didCompleteOnboarding = "didCompleteOnboarding"
    public static let translationPanelSize = "SelectionActionWindowController.translationPanelSize"
    public static let providerAPIKeyPrefix = "providerAPIKey."

    public static let recognizedLegacyKeys = [
        appConfig,
        modelCatalogSnapshot,
        interfaceLanguage,
        didCompleteOnboarding,
        translationPanelSize
    ]

    public static func providerID(fromLegacyKey key: String) -> String? {
        guard key.hasPrefix(providerAPIKeyPrefix) else { return nil }
        let providerID = String(key.dropFirst(providerAPIKeyPrefix.count))
        return providerID.isEmpty ? nil : providerID
    }
}
```

Make all five existing owners reference these constants. Remove `UserDefaults` and `keyPrefix` from `LocalAPIKeyStore`; it must read, write, and delete only its bundle-specific Keychain service.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter ConfigStoreTests
git add Sources/InkletCore/InkletPreferenceKeys.swift Sources/InkletCore/ConfigStore.swift Sources/InkletCore/ModelCatalogService.swift Sources/InkletApp/InkletLocalization.swift Sources/InkletApp/SettingsWindowController.swift Sources/InkletApp/SelectionActionWindowController.swift Tests/InkletCoreTests/ConfigStoreTests.swift
git commit -m "Centralize legacy preference keys"
```

Expected: tests pass and no runtime code loads `providerAPIKey.*` from current global defaults.

### Task 3: Add error-reporting filesystem access, fingerprints, state, and locking

**Files:**

- Create: `Sources/InkletCore/LegacyMigrationFileSystem.swift`
- Create: `Sources/InkletCore/LegacyMigrationLock.swift`
- Create: `Sources/InkletCore/LegacySandboxDataMigrator.swift`
- Create: `Tests/InkletCoreTests/LegacyMigrationLockTests.swift`
- Create: `Tests/InkletCoreTests/LegacyMigrationSourceValidationTests.swift`
- Create: `Tests/InkletCoreTests/LegacySandboxDataMigratorTests.swift`

- [ ] **Step 1: Write failing filesystem classification tests**

Using an injected fake filesystem, assert confirmed `ENOENT` maps to no legacy data, `EACCES`/`EPERM` map to `.permissionDenied`, any other lookup error maps to `.indeterminateLookup`, a symlink maps to `.invalidSource`, and no content-read call occurs before canonical source validation passes.

- [ ] **Step 2: Write failing lock tests**

Test successful lock/release, a five-millisecond timeout while another process holds the same file, and a true cross-process wait using `fork` plus a pipe. The child must acquire first; the parent must block, acquire after the child releases, reload the persisted marker, and avoid rerunning the operation.

- [ ] **Step 3: Write failing fingerprint/state tests**

Assert fingerprints distinguish absent, Boolean, integer, real, data, date, string, array order, and recursively sorted dictionary keys. Assert stored baseline data contains SHA-256 digests but not a known plaintext setting string. Assert a marker is visible only after the state store writes and reads it back successfully.

- [ ] **Step 4: Run the new tests and confirm RED**

```bash
swift test --filter 'LegacyMigrationLockTests|LegacyMigrationSourceValidationTests|LegacySandboxDataMigratorTests'
```

Expected: compilation fails for the new migration types.

- [ ] **Step 5: Implement the filesystem protocol and strict classification**

Use this interface:

```swift
public enum LegacyMigrationItemKind: Equatable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case other
}

public protocol LegacyMigrationFileSystem: Sendable {
    func itemKind(at url: URL) throws -> LegacyMigrationItemKind
    func readData(at url: URL) throws -> Data
    func createDirectory(at url: URL) throws
    func writeDataAtomically(_ data: Data, to url: URL) throws
    func canonicalURL(for url: URL) throws -> URL
}
```

Production code must use throwing resource/attribute APIs, not `fileExists`. Only Cocoa no-such-file or underlying POSIX `ENOENT` is “missing”; permission errors remain retryable and every other lookup error is indeterminate. A confirmed-missing container completes all three components at their current versions with `noLegacyData`. A missing preferences plist inside a readable container completes preferences and credentials with no source; a missing history file completes history. Neither case converts a permission or indeterminate lookup into “missing.”

- [ ] **Step 6: Implement bounded cross-process locking**

```swift
public final class LegacyMigrationLock: @unchecked Sendable {
    public init(
        fileURL: URL,
        timeout: Duration = .seconds(5),
        retryInterval: Duration = .milliseconds(50)
    )

    public func withLock<T>(_ operation: () throws -> T) throws -> T
}

public enum LegacyMigrationLockError: Error, Equatable {
    case timedOut
}
```

Use `open(O_CREAT | O_RDWR, 0o600)`, `flock(LOCK_EX | LOCK_NB)`, bounded retries, and `defer` for unlock/close. Reload all component markers after acquisition.

- [ ] **Step 7: Implement canonical fingerprints and migration types**

Define `LegacyMigrationComponent` (`preferences`, `credentials`, `history`), per-component version `1`, `PreferenceFingerprint` (`absent`, `present(sha256:)`), automatic/user-assisted modes, typed failure kinds, component results, and `LegacySandboxMigrationOutcome` with `hasIncompleteComponents`, `changedDestination`, and `shouldOfferAssistedImport`.

Use these shared seams so startup and tests refer to the same types:

```swift
public protocol LegacyMigrationStateStore: Sendable {
    func reload() throws
    func completedVersion(for component: LegacyMigrationComponent) throws -> Int?
    func setCompletedVersion(_ version: Int, for component: LegacyMigrationComponent) throws
    func preferenceBaseline() throws -> [String: PreferenceFingerprint]?
    func setPreferenceBaseline(_ baseline: [String: PreferenceFingerprint]) throws
}

public final class LegacySandboxDataMigrator: @unchecked Sendable {
    public init(
        bundleIdentifier: String,
        storagePaths: InkletStoragePaths,
        homeDirectoryURL: URL,
        defaults: UserDefaults,
        fileSystem: any LegacyMigrationFileSystem,
        stateStore: any LegacyMigrationStateStore,
        keychainStore: @escaping (String) -> KeychainStore,
        lock: LegacyMigrationLock
    )

    public static func live(
        storagePaths: InkletStoragePaths,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> LegacySandboxDataMigrator

    public func migrateAutomatically() -> LegacySandboxMigrationOutcome
    public func migrateUserSelectedData(at selectedDataRootURL: URL) -> LegacySandboxMigrationOutcome
    public func validateUserSelectedDataRoot(_ selectedURL: URL) throws -> URL
    public static func expectedLegacyDataRoot(
        bundleIdentifier: String,
        homeDirectoryURL: URL
    ) -> URL
}
```

The automatic source is exactly `~/Library/Containers/<bundleIdentifier>/Data`. Under that root, read only `Library/Preferences/<bundleIdentifier>.plist` and `Library/Application Support/Inklet/history.jsonl`; never probe the legacy translation-cache file.

Canonical encoding must use explicit type tags, sorted dictionary keys, preserved array order, and distinct encodings for Boolean/integer/real/data/date/string before hashing with SHA-256. Marker keys are:

```text
Inklet.LegacySandboxMigration.preferencesVersion
Inklet.LegacySandboxMigration.credentialsVersion
Inklet.LegacySandboxMigration.historyVersion
Inklet.LegacySandboxMigration.preferenceBaseline.v1
```

- [ ] **Step 8: Run tests and commit primitives**

```bash
swift test --filter 'LegacyMigrationLockTests|LegacyMigrationSourceValidationTests|LegacySandboxDataMigratorTests'
git add Sources/InkletCore/LegacyMigrationFileSystem.swift Sources/InkletCore/LegacyMigrationLock.swift Sources/InkletCore/LegacySandboxDataMigrator.swift Tests/InkletCoreTests/LegacyMigrationLockTests.swift Tests/InkletCoreTests/LegacyMigrationSourceValidationTests.swift Tests/InkletCoreTests/LegacySandboxDataMigratorTests.swift
git commit -m "Add legacy migration state and locking"
```

Expected: primitive tests pass; component tests that are intentionally added in Task 4 remain excluded until then.

### Task 4: Implement preferences, credentials, and history migration

**Files:**

- Modify: `Sources/InkletCore/LegacySandboxDataMigrator.swift`
- Modify: `Sources/InkletCore/HistoryStore.swift`
- Modify: `Tests/InkletCoreTests/LegacySandboxDataMigratorTests.swift`
- Modify: `Tests/InkletCoreTests/HistoryStoreTests.swift`

- [ ] **Step 1: Add failing component tests**

Add explicit tests for:

- static whitelist only and property-list type validation;
- initial legacy authority over stale global values;
- legacy-absent keys preserving globals;
- marker idempotence and independent component retry;
- delayed conflict states: unchanged imports, added/changed/removed globals win;
- baseline write/readback failure preventing later overwrite;
- dynamic provider keys going only to the correct Keychain service/account;
- an existing Keychain item winning, Keychain failure remaining retryable, and no global plaintext write;
- empty-destination history import, two-store merge, destination UUID collision winning, malformed lines skipped, deterministic `createdAt`/UUID order, atomic-write failure preserving the destination, idempotent retry, and byte-for-byte unchanged legacy source;
- no filesystem access to the legacy translation cache.

- [ ] **Step 2: Run component tests and confirm RED**

```bash
swift test --filter 'LegacySandboxDataMigratorTests|HistoryStoreTests'
```

Expected: migration cases fail because component algorithms are not implemented.

- [ ] **Step 3: Implement conflict-aware preferences**

Read `Data/Library/Preferences/<bundle-id>.plist` directly with `PropertyListSerialization`. Validate the five expected types (`Data`, `Data`, `String`, `Bool`, `[String: NSNumber]`). On the first readable attempt with no baseline, present legacy values overwrite globals. If access fails, persist and verify tri-state fingerprints before startup proceeds. On delayed retry, overwrite only keys whose current fingerprint still matches baseline; added, changed, or removed globals win and count as resolved conflicts. Set the preferences marker only after all eligible writes persist.

- [ ] **Step 4: Import legacy credentials directly into Keychain**

Enumerate only valid `providerAPIKey.<nonempty-provider-id>` string entries. Resolve the service with `LocalAPIKeyStore.resolvedKeychainService(bundleIdentifier:)` and provider ID as account. Existing Keychain values win; missing values are saved directly; malformed values or Keychain errors keep the component incomplete. Never copy plaintext into global defaults or logs.

- [ ] **Step 5: Extract the shared history codec and merge atomically**

Add:

```swift
enum HistoryJSONLCodec {
    static func decodeValidItems(from data: Data) -> [HistoryItem]
    static func encode(_ items: [HistoryItem]) throws -> Data
}
```

Merge legacy items into a UUID dictionary, then overwrite with destination items so destination wins. Sort by `createdAt`, then `id.uuidString`. Encode one JSON object per line with a final newline, write to a same-directory temporary file, synchronize it, and atomically replace the destination. Set the history marker only after replacement. Never alter the source.

- [ ] **Step 6: Run component tests and commit**

```bash
swift test --filter 'LegacySandboxDataMigratorTests|HistoryStoreTests|ConfigStoreTests'
git add Sources/InkletCore/LegacySandboxDataMigrator.swift Sources/InkletCore/HistoryStore.swift Tests/InkletCoreTests/LegacySandboxDataMigratorTests.swift Tests/InkletCoreTests/HistoryStoreTests.swift
git commit -m "Migrate legacy sandbox data safely"
```

Expected: all focused component tests pass.

### Task 5: Run migration before constructing AppDelegate

**Files:**

- Modify: `Sources/InkletApp/main.swift`
- Modify: `Sources/InkletApp/AppCoordinator.swift`
- Create: `Tests/InkletCoreTests/LegacyMigrationAppSourceTests.swift`

- [ ] **Step 1: Write the startup-order source test**

Read `main.swift` as source. Assert `InkletStoragePaths.current`, `LegacySandboxDataMigrator.live`, and `migrateAutomatically()` appear before `AppDelegate(`. Read `AppCoordinator.swift` and assert the initializer receives `migrationOutcome`, `migrator`, and `storagePaths`, and that history/cache/controllers receive the same resolved paths.

- [ ] **Step 2: Run and confirm RED**

```bash
swift test --filter LegacyMigrationAppSourceTests
```

Expected: source contract fails because `AppDelegate` is still created first and `AppCoordinator` resolves stores independently.

- [ ] **Step 3: Wire synchronous startup migration**

Use this ordering in `main.swift`:

```swift
let storagePaths = try InkletStoragePaths.current()
let migrator = LegacySandboxDataMigrator.live(storagePaths: storagePaths)
let migrationOutcome = migrator.migrateAutomatically()

let app = NSApplication.shared
let delegate = AppDelegate(
    migrationOutcome: migrationOutcome,
    migrator: migrator,
    storagePaths: storagePaths
)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

Change `AppDelegate` from an eager property initializer to an explicit initializer that constructs `AppCoordinator` from those inputs. Resolve paths once and inject them into history, cache, Settings, popover, and diagnostics. Configure normal services before presenting any incomplete-migration notice so the migrated interface language is active.

- [ ] **Step 4: Run focused tests and commit**

```bash
swift test --filter 'LegacyMigrationAppSourceTests|InkletStoragePathsTests|LegacySandboxDataMigratorTests'
git add Sources/InkletApp/main.swift Sources/InkletApp/AppCoordinator.swift Tests/InkletCoreTests/LegacyMigrationAppSourceTests.swift
git commit -m "Run legacy migration before app startup"
```

Expected: startup-order and migration tests pass.

### Task 6: Add validated in-process assisted import and maintenance state

**Files:**

- Create: `Sources/InkletApp/LegacyMigrationPresentationModel.swift`
- Modify: `Sources/InkletCore/VoiceInputCoordinator.swift`
- Modify: `Sources/InkletApp/SettingsView.swift`
- Modify: `Sources/InkletApp/SettingsWindowController.swift`
- Modify: `Sources/InkletApp/InkletPopoverView.swift`
- Modify: `Sources/InkletApp/InkletPopoverWindowController.swift`
- Modify: `Sources/InkletApp/AppCoordinator.swift`
- Modify: `Tests/InkletCoreTests/LegacyMigrationSourceValidationTests.swift`
- Modify: `Tests/InkletCoreTests/LegacyMigrationAppSourceTests.swift`

- [ ] **Step 1: Write failing source-validation and maintenance tests**

Assert exact canonical acceptance only for `~/Library/Containers/<current-bundle-id>/Data`; reject symlinks, another bundle, production/local cross-selection, arbitrary lookalikes, and a missing/wrong bundle-specific preferences file before any contents are read. Source-contract tests must require autosave cancellation/read-only gating during maintenance, current-process import before relaunch, and no persisted bookmark or post-relaunch source read.

- [ ] **Step 2: Define the presentation state**

Create:

```swift
@MainActor
final class LegacyMigrationPresentationModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case needsImport
        case selecting
        case importing
        case failed
        case relaunching
        case relaunchFailed
    }

    @Published private(set) var phase: Phase
    @Published private(set) var outcome: LegacySandboxMigrationOutcome

    var isSettingsReadOnly: Bool { phase == .importing || phase == .relaunching || phase == .relaunchFailed }
    var canRequestImport: Bool { phase == .needsImport || phase == .failed }

    func update(with outcome: LegacySandboxMigrationOutcome)
}
```

- [ ] **Step 3: Add the restrained Settings card**

Retain one `SettingsViewModel` in `SettingsWindowController`. Add `flushPendingEdits()`, `setMigrationMaintenanceActive(_:)`, and `showMigrationNotice()`. Place the migration card above General settings only while components remain incomplete. Keep the Import button size stable; replace its icon in place with `ProgressView` during import. Disable all settings in maintenance, cancel the 450 ms debounce and pronunciation preview, and flush already-edited settings before computing/importing against the baseline.

- [ ] **Step 4: Validate and import while the file-panel grant is alive**

Use `NSOpenPanel` without bookmarks. Standardize and resolve the selected URL, reject any standardized/resolved mismatch, and require exact equality with the expected canonical Data directory before checking its exact preferences filename. Call `startAccessingSecurityScopedResource()` when available, retain the selected URL/access scope across the awaited import, then stop access. Do not persist the URL or assume access survives exit.

- [ ] **Step 5: Freeze mutation, import, and relaunch**

Expose `VoiceInputCoordinator.isIdle`, popover `isBusy`, and `cancelForMigrationMaintenance()`. Disable Import while voice, transform/insertion, selection translation/pronunciation, or audio playback is active; recheck after the panel closes. During maintenance stop hotkeys and voice/selection monitors, unregister the global hotkey, cancel pending selection work, hide/cancel the popover, stop audio, and block new open/menu handlers. Run migration off the main actor. If any destination changed, release the lock and use `NSWorkspace.OpenConfiguration.createsNewApplicationInstance = true` for a controlled relaunch before re-enabling interactions. If relaunch fails, remain read-only with retry/quit actions. If nothing changed, leave maintenance safely and refresh the notice.

- [ ] **Step 6: Run focused tests and commit**

```bash
swift test --filter 'LegacyMigrationSourceValidationTests|LegacyMigrationAppSourceTests|VoiceInputCoordinatorTests|SettingsViewSourceTests|SettingsWindowControllerSourceTests'
git add Sources/InkletApp/LegacyMigrationPresentationModel.swift Sources/InkletCore/VoiceInputCoordinator.swift Sources/InkletApp/SettingsView.swift Sources/InkletApp/SettingsWindowController.swift Sources/InkletApp/InkletPopoverView.swift Sources/InkletApp/InkletPopoverWindowController.swift Sources/InkletApp/AppCoordinator.swift Tests/InkletCoreTests/LegacyMigrationSourceValidationTests.swift Tests/InkletCoreTests/LegacyMigrationAppSourceTests.swift
git commit -m "Add assisted legacy data import"
```

Expected: focused tests pass.

### Task 7: Localize every migration state

**Files:**

- Modify: `Sources/InkletApp/InkletLocalization.swift`
- Create: `Tests/InkletCoreTests/LegacyMigrationLocalizationTests.swift`

- [ ] **Step 1: Write the localization count contract**

For every key below, assert exactly ten dictionary entries. Also assert representative English and Simplified Chinese values:

```text
legacyMigration.notice.title
legacyMigration.notice.message
legacyMigration.action.importOldData
legacyMigration.panel.title
legacyMigration.panel.message
legacyMigration.import.progress
legacyMigration.import.invalidSelection
legacyMigration.import.failed
legacyMigration.import.partialFailure
legacyMigration.import.relaunching
legacyMigration.import.relaunchFailed
legacyMigration.action.retryRelaunch
legacyMigration.action.quit
legacyMigration.settings.help
```

English core copy:

```text
Old Inklet data was not imported
Your previous settings and history are still preserved. You can choose the matching Inklet Data folder to import them.
Import Old Data…
Importing old data…
The selected folder is not the legacy data folder for this Inklet app.
Inklet needs to relaunch to finish loading the imported data.
```

Simplified Chinese core copy:

```text
旧版 Inklet 数据尚未导入
你之前的设置和历史记录仍被保留。你可以选择对应的 Inklet Data 文件夹进行导入。
导入旧数据…
正在导入旧数据…
所选文件夹不是当前 Inklet 对应的旧数据文件夹。
Inklet 需要重新启动以载入已导入的数据。
```

- [ ] **Step 2: Run and confirm RED**

```bash
swift test --filter LegacyMigrationLocalizationTests
```

Expected: all key-count assertions fail.

- [ ] **Step 3: Add native copy to all ten dictionaries**

Add every key to English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, French, German, Portuguese, and Italian. Reuse no English fallback. Copy must state that legacy data remains preserved and must never interpolate paths, usernames, selected text, history contents, or credential details.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter LegacyMigrationLocalizationTests
git add Sources/InkletApp/InkletLocalization.swift Tests/InkletCoreTests/LegacyMigrationLocalizationTests.swift
git commit -m "Localize legacy migration notices"
```

Expected: the localization contract passes with ten entries per key.

### Task 8: Verify migration without claiming TCC success

**Files:** No new files.

- [ ] **Step 1: Run the complete automated suite**

```bash
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
git status --short
```

Expected: all tests/builds pass and no unintended files appear.

- [ ] **Step 2: Defer signed Container-access verification to direct distribution**

Do not claim that the unsandboxed app can read its old Container from unit tests. The final plan must test the exact Developer ID-signed in-place upgrade on every supported macOS release, verify automatic import when permitted, and exercise the in-process file-panel fallback when App Data protection denies direct access.
