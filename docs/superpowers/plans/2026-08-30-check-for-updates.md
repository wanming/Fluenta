# GitHub Release Update Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a check-only GitHub Releases update feature with a manual menu command in all builds and a quiet, throttled 24-hour automatic check in production builds.

**Architecture:** A deterministic `InkletCore` checker validates and compares GitHub release metadata. An app-target coordinator owns scheduling, request coalescing, pending automatic presentation, and observable checking state; a separate AppKit presenter owns alerts and opening the already-validated release URL. `AppCoordinator` wires these parts into the existing application lifecycle and both menus.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation `URLSession`/`JSONDecoder`/`UserDefaults`/`Timer`, AppKit `NSAlert`/`NSMenu`/`NSWorkspace`, XCTest.

---

## File map

- Create `Sources/InkletCore/GitHubReleaseUpdateChecker.swift`: release value types, exact tag and URL validation, release-note excerpting, bounded GitHub REST request, and build comparison.
- Create `Sources/InkletApp/UpdateCheckCoordinator.swift`: 24-hour schedule policy, one-shot timer abstraction, request coalescing, manual/automatic feedback rules, and deferred automatic update presentation.
- Create `Sources/InkletApp/UpdateCheckAlertPresenter.swift`: localized AppKit alerts and validated GitHub page opening.
- Modify `Sources/InkletCore/InkletPreferenceKeys.swift`: add the new automatic-attempt timestamp key without adding it to legacy migration keys.
- Modify `Sources/InkletApp/AppCoordinator.swift`: construct/start/stop the coordinator, expose checking state in both menus, and retry pending automatic presentation whenever workflows become idle.
- Modify `Sources/InkletApp/InkletLocalization.swift`: add all update-check strings to all ten language tables.
- Create `Tests/InkletCoreTests/GitHubReleaseUpdateCheckerTests.swift`: deterministic parser, validation, request, response-size, HTTP, and comparison tests with no live network.
- Create `Tests/InkletCoreTests/UpdateCheckCoordinatorTests.swift`: deterministic scheduling, coalescing, presentation, cancellation, and local-build tests.
- Create `Tests/InkletCoreTests/UpdateCheckLocalizationTests.swift`: ten-table key/value and format-placeholder contracts.
- Modify `Tests/InkletCoreTests/AppCoordinatorSourceTests.swift`: lifecycle/menu/idle-gate wiring contracts.
- Modify `README.md`, `README.zh-CN.md`, `docs/privacy-policy.md`, and `docs/manual-test-checklist.md`: shipped behavior, privacy disclosure, and manual QA.
- Modify `VERSION`: patch release bump required before the local app build.

### Task 1: Implement exact release parsing and validation

**Files:**
- Create: `Sources/InkletCore/GitHubReleaseUpdateChecker.swift`
- Test: `Tests/InkletCoreTests/GitHubReleaseUpdateCheckerTests.swift`

- [ ] **Step 1: Write failing tests for exact tags and release-note excerpts**

Add tests that construct `InkletReleaseVersion(tagName:)` and assert:

```swift
func testParsesExactReleaseTag() throws {
    XCTAssertEqual(
        try InkletReleaseVersion(tagName: "v12.34.56-789"),
        InkletReleaseVersion(marketingVersion: "12.34.56", buildNumber: 789)
    )
}

func testRejectsMalformedReleaseTags() {
    ["1.2.3-4", "v1.2-4", "v1.2.3-0", "v1.2.3-beta-4", "v1.2.3-4-extra", "v01.2.3-4"]
        .forEach { tag in
            XCTAssertThrowsError(try InkletReleaseVersion(tagName: tag))
        }
}

func testReleaseNotesNormalizeAndCapAtEightHundredCharacters() {
    let source = "  First\r\n\r\nSecond  \n" + String(repeating: "界", count: 900)
    let excerpt = InkletReleaseNotes.excerpt(source)
    XCTAssertFalse(excerpt.contains("\r"))
    XCTAssertTrue(excerpt.hasSuffix("…"))
    XCTAssertLessThanOrEqual(excerpt.count, 800)
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `swift test --filter GitHubReleaseUpdateCheckerTests`

Expected: compilation fails because `InkletReleaseVersion` and `InkletReleaseNotes` do not exist.

- [ ] **Step 3: Add the minimal deterministic types and parser**

Implement public `Equatable`/`Sendable` types with the same signatures used in the tests:

```swift
public struct InkletReleaseVersion: Equatable, Sendable {
    public let marketingVersion: String
    public let buildNumber: Int

    public init(marketingVersion: String, buildNumber: Int) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
    }

    public init(tagName: String) throws {
        // Require v + three canonical non-negative integer components +
        // a canonical positive integer build, with no trailing content.
    }
}

public enum InkletReleaseNotes {
    public static func excerpt(_ body: String?, limit: Int = 800) -> String {
        // Normalize CRLF/CR, trim whitespace/newlines, and append one ellipsis
        // only when the user-perceived Character count exceeds `limit`, keeping
        // the final excerpt including the ellipsis within `limit` Characters.
    }
}
```

- [ ] **Step 4: Add failing release-validation tests**

Decode fixtures covering stable/draft/prerelease, expected uploaded/missing/non-uploaded `Inklet.dmg`, exact/malicious GitHub URLs, null name/body, and multi-digit versions. Assert the resulting model:

```swift
let release = try GitHubReleaseParser.parse(validFixtureData)
XCTAssertEqual(release.version.buildNumber, 23)
XCTAssertEqual(release.pageURL.absoluteString,
               "https://github.com/wanming/Inklet/releases/tag/v1.4.2-23")
```

- [ ] **Step 5: Run the focused test and verify the new cases fail**

Run: `swift test --filter GitHubReleaseUpdateCheckerTests`

Expected: compilation fails because the release parser and release model are missing.

- [ ] **Step 6: Implement the decoded schema and defensive validation**

Add:

```swift
public struct InkletRelease: Equatable, Sendable {
    public let version: InkletReleaseVersion
    public let tagName: String
    public let name: String?
    public let notes: String
    public let pageURL: URL
}

enum GitHubReleaseParser {
    static func parse(_ data: Data) throws -> InkletRelease {
        // Decode tag_name/name/body/html_url/draft/prerelease/assets.
        // Reject unstable flags, absent uploaded Inklet.dmg, malformed tags,
        // and URLs other than the exact https github.com wanming/Inklet tag path.
    }
}
```

Use `URLComponents` plus decoded path components; reject user/password, non-default ports, query strings, fragments, and tag/path disagreement.

- [ ] **Step 7: Run parser tests and commit**

Run: `swift test --filter GitHubReleaseUpdateCheckerTests`

Expected: all parser and excerpt tests pass.

```bash
git add Sources/InkletCore/GitHubReleaseUpdateChecker.swift Tests/InkletCoreTests/GitHubReleaseUpdateCheckerTests.swift
git commit -m "Add GitHub release validation"
```

### Task 2: Add the bounded GitHub request and build comparison

**Files:**
- Modify: `Sources/InkletCore/GitHubReleaseUpdateChecker.swift`
- Modify: `Tests/InkletCoreTests/GitHubReleaseUpdateCheckerTests.swift`

- [ ] **Step 1: Write failing request and comparison tests**

Inject a loader returning a small `LoadedHTTPResponse` so tests never use live networking. Verify URL, timeout, both GitHub headers, no authorization header, newer/equal/older build outcomes, malformed local build, HTTP errors, malformed JSON, a declared or actual body over 1 MiB, and `CancellationError` preservation.

```swift
let checker = GitHubReleaseUpdateChecker { request in
    XCTAssertEqual(request.url?.absoluteString,
                   "https://api.github.com/repos/wanming/Inklet/releases/latest")
    XCTAssertEqual(request.timeoutInterval, 15)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"),
                   "application/vnd.github+json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"),
                   "2022-11-28")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    return .init(data: validFixtureData, statusCode: 200, expectedContentLength: nil)
}
XCTAssertEqual(
    try await checker.check(currentBuildNumber: "22"),
    .updateAvailable(expectedRelease)
)
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `swift test --filter GitHubReleaseUpdateCheckerTests`

Expected: compilation fails because the checker, response wrapper, result, and error types are missing.

- [ ] **Step 3: Implement one bounded request with user-safe errors**

Add:

```swift
public enum AppUpdateCheckResult: Equatable, Sendable {
    case updateAvailable(InkletRelease)
    case upToDate(InkletRelease)
}

public enum AppUpdateCheckError: Error, Equatable, Sendable {
    case networkUnavailable
    case serviceUnavailable
    case invalidResponse
    case currentVersionUnavailable
}

public struct GitHubReleaseUpdateChecker: Sendable {
    public init()
    init(loader: @escaping Loader)
    public func check(currentBuildNumber: String?) async throws -> AppUpdateCheckResult
}
```

The live loader converts `URLSession.shared.data(for:)` into the Sendable wrapper. Check `expectedContentLength` and actual `Data.count` against `1_048_576` before decoding. Map non-2xx to `.serviceUnavailable`, transport failures to `.networkUnavailable`, preserve cancellation, and never log a response body.

- [ ] **Step 4: Run focused and full core tests, then commit**

Run: `swift test --filter GitHubReleaseUpdateCheckerTests`

Expected: all checker tests pass with zero live requests.

Run: `swift test`

Expected: the existing 568-test baseline plus new checker tests pass.

```bash
git add Sources/InkletCore/GitHubReleaseUpdateChecker.swift Tests/InkletCoreTests/GitHubReleaseUpdateCheckerTests.swift
git commit -m "Add bounded GitHub update request"
```

### Task 3: Build the testable update coordinator

**Files:**
- Create: `Sources/InkletApp/UpdateCheckCoordinator.swift`
- Modify: `Sources/InkletCore/InkletPreferenceKeys.swift`
- Create: `Tests/InkletCoreTests/UpdateCheckCoordinatorTests.swift`

- [ ] **Step 1: Add failing schedule-policy tests**

Cover due/no-timestamp, recent timestamp, future/invalid timestamps, disabled local automatic checks, and last-attempt persistence at automatic-start time:

```swift
XCTAssertEqual(
    UpdateCheckSchedulePolicy.delay(
        lastAttempt: now.addingTimeInterval(-3_600),
        now: now,
        interval: 86_400
    ),
    82_800
)
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `swift test --filter UpdateCheckCoordinatorTests`

Expected: compilation fails because coordinator scheduling types do not exist.

- [ ] **Step 3: Implement the schedule policy, timer seam, and preference key**

Add `InkletPreferenceKeys.lastAutomaticUpdateCheckDate = "lastAutomaticUpdateCheckDate"`; leave `recognizedLegacyKeys` unchanged. Implement an `@MainActor` one-shot scheduler abstraction backed by Foundation `Timer` and:

```swift
enum UpdateCheckSchedulePolicy {
    static let interval: TimeInterval = 24 * 60 * 60

    static func delay(lastAttempt: Date?, now: Date,
                      interval: TimeInterval = interval) -> TimeInterval {
        guard let lastAttempt else { return 0 }
        return max(0, interval - max(0, now.timeIntervalSince(lastAttempt)))
    }
}
```

- [ ] **Step 4: Add failing behavior tests with fakes**

Use a controllable async checker, fake one-shot scheduler, isolated `UserDefaults` suite, mutable clock, and recording presenter. Cover:

```swift
@MainActor
func testManualIntentJoinsAutomaticRequestAndReceivesFeedback() async {
    coordinator.start()
    coordinator.checkManually()
    XCTAssertEqual(checker.callCount, 1)
    checker.complete(with: .upToDate(release))
    await coordinator.waitUntilIdleForTesting()
    XCTAssertEqual(presenter.upToDateCount, 1)
}
```

Also assert automatic up-to-date/error silence, manual failure Retry/Cancel, timer rescheduling after failed automatic attempts, manual bypass of throttling/local mode, checking-state restoration, stop cancellation, deferred busy automatic update, and pending presentation when idle.

- [ ] **Step 5: Run the focused test and verify it fails**

Run: `swift test --filter UpdateCheckCoordinatorTests`

Expected: compilation fails because coordinator/presenter protocols and behavior are incomplete.

- [ ] **Step 6: Implement minimal coordinator behavior**

Define:

```swift
@MainActor
protocol UpdateCheckPresenting: AnyObject {
    func presentUpdate(_ release: InkletRelease, currentVersion: String)
    func presentUpToDate(currentVersion: String)
    func presentFailure(retry: @escaping @MainActor () -> Void)
}

@MainActor
final class UpdateCheckCoordinator {
    private(set) var isChecking = false
    var onCheckingStateChange: ((Bool) -> Void)?

    func start()
    func stop()
    func checkManually()
    func presentPendingAutomaticUpdateIfPossible()
}
```

Maintain one `Task`, `hasManualIntent`, and `hasAutomaticIntent`. Joining an automatic intent records the timestamp and schedules the next one-shot timer exactly once. Capture all intents on completion, clear checking state before presentation so Retry creates a fresh request, and retain at most one automatic update in memory while `canPresentAutomatically()` is false.

- [ ] **Step 7: Run coordinator tests and commit**

Run: `swift test --filter UpdateCheckCoordinatorTests`

Expected: every coordinator test passes.

```bash
git add Sources/InkletApp/UpdateCheckCoordinator.swift Sources/InkletCore/InkletPreferenceKeys.swift Tests/InkletCoreTests/UpdateCheckCoordinatorTests.swift
git commit -m "Coordinate scheduled update checks"
```

### Task 4: Add localized AppKit update alerts

**Files:**
- Create: `Sources/InkletApp/UpdateCheckAlertPresenter.swift`
- Modify: `Sources/InkletApp/InkletLocalization.swift`
- Create: `Tests/InkletCoreTests/UpdateCheckLocalizationTests.swift`

- [ ] **Step 1: Write the failing ten-language localization contract**

Require exactly one occurrence per language table for:

```swift
private let updateKeys = [
    "app.menu.checkForUpdates",
    "app.menu.checkingForUpdates",
    "update.available.title",
    "update.available.latestVersion",
    "update.available.currentVersion",
    "update.available.noNotes",
    "update.action.viewOnGitHub",
    "update.action.later",
    "update.upToDate.title",
    "update.upToDate.message",
    "update.error.title",
    "update.error.message",
    "update.action.retry",
    "update.action.cancel",
]
```

Assert all ten table IDs, approved English/Simplified Chinese values, and matching `%@`/`%d` placeholder counts in every table.

- [ ] **Step 2: Run the localization test and verify it fails**

Run: `swift test --filter UpdateCheckLocalizationTests`

Expected: failures report every missing update key.

- [ ] **Step 3: Add concise translations to all ten tables**

Use these English and Simplified Chinese source values and equivalent native translations for Traditional Chinese, Japanese, Korean, Spanish, French, German, Portuguese, and Italian:

```swift
"app.menu.checkForUpdates": "Check for Updates…",
"app.menu.checkingForUpdates": "Checking for Updates…",
"update.available.title": "An Inklet update is available",
"update.available.latestVersion": "Latest: %@ (build %d)",
"update.available.currentVersion": "Current: %@",
"update.available.noNotes": "View the release on GitHub for details.",
"update.action.viewOnGitHub": "View on GitHub",
"update.action.later": "Later",
"update.upToDate.title": "Inklet is up to date",
"update.upToDate.message": "You’re using %@.",
"update.error.title": "Couldn’t check for updates",
"update.error.message": "Check your internet connection and try again.",
"update.action.retry": "Retry",
"update.action.cancel": "Cancel",

"app.menu.checkForUpdates": "检查更新…",
"app.menu.checkingForUpdates": "正在检查更新…",
"update.available.title": "Inklet 有可用更新",
"update.available.latestVersion": "最新版本：%@（构建 %d）",
"update.available.currentVersion": "当前版本：%@",
"update.available.noNotes": "请前往 GitHub 查看发布详情。",
"update.action.viewOnGitHub": "在 GitHub 上查看",
"update.action.later": "稍后",
"update.upToDate.title": "Inklet 已是最新版本",
"update.upToDate.message": "你正在使用 %@。",
"update.error.title": "无法检查更新",
"update.error.message": "请检查网络连接后重试。",
"update.action.retry": "重试",
"update.action.cancel": "取消",
```

- [ ] **Step 4: Add presenter-focused source tests, then implement alerts**

Assert the presenter activates Inklet, uses the 800-character core excerpt, includes a useful release name only when it differs from the tag/version, and opens only `release.pageURL`. Implement three standard `NSAlert`s; the failure alert invokes the supplied Retry closure only for the first button.

```swift
@MainActor
final class UpdateCheckAlertPresenter: UpdateCheckPresenting {
    func presentUpdate(_ release: InkletRelease, currentVersion: String) {
        NSApp.activate(ignoringOtherApps: true)
        // Latest/current lines, optional useful name, notes or localized fallback.
        // First button opens release.pageURL; second dismisses.
    }
}
```

- [ ] **Step 5: Run focused tests and commit**

Run: `swift test --filter UpdateCheckLocalizationTests`

Expected: all localization contracts pass.

Run: `swift test --filter UpdateCheckAlertPresenterSourceTests`

Expected: all presenter source contracts pass.

```bash
git add Sources/InkletApp/InkletLocalization.swift Sources/InkletApp/UpdateCheckAlertPresenter.swift Tests/InkletCoreTests/UpdateCheckLocalizationTests.swift Tests/InkletCoreTests/UpdateCheckAlertPresenterSourceTests.swift
git commit -m "Add localized update check alerts"
```

### Task 5: Wire lifecycle, both menus, and idle presentation

**Files:**
- Modify: `Sources/InkletApp/AppCoordinator.swift`
- Modify: `Tests/InkletCoreTests/AppCoordinatorSourceTests.swift`

- [ ] **Step 1: Write failing AppCoordinator wiring contracts**

Assert the source contains one coordinator property/factory, production gating by `InkletStoragePaths.productionBundleIdentifier`, `start()` after existing normal startup, `stop()`, one selector used by both menu builders, checking-state title/disabled state, and idle retry from `refreshMigrationImportEligibility()`.

```swift
XCTAssertTrue(source.contains("action: #selector(checkForUpdates)"))
XCTAssertEqual(source.components(separatedBy: "action: #selector(checkForUpdates)").count - 1, 2)
XCTAssertTrue(source.contains("updateCheckCoordinator.start()"))
XCTAssertTrue(source.contains("updateCheckCoordinator.stop()"))
XCTAssertTrue(source.contains("updateCheckCoordinator.presentPendingAutomaticUpdateIfPossible()"))
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `swift test --filter AppCoordinatorSourceTests`

Expected: the new update-check wiring assertions fail.

- [ ] **Step 3: Construct and lifecycle-manage the coordinator**

Use a lazy factory so the existing initializer remains unchanged:

```swift
private lazy var updateCheckCoordinator = makeUpdateCheckCoordinator()

private func makeUpdateCheckCoordinator() -> UpdateCheckCoordinator {
    let checker = GitHubReleaseUpdateChecker()
    return UpdateCheckCoordinator(
        automaticallyChecks: storagePaths.bundleIdentifier == InkletStoragePaths.productionBundleIdentifier,
        currentVersion: { BuildInfo.displayVersion },
        check: {
            try await checker.check(
                currentBuildNumber: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String
            )
        },
        canPresentAutomatically: { [weak self] in self?.canPresentAutomaticUpdate == true },
        presenter: UpdateCheckAlertPresenter()
    )
}
```

Start it only after the existing startup work and stop it before releasing observers/tasks.

- [ ] **Step 4: Add both shared-state menu items**

Add the application-menu item immediately after About, and the status-menu item after Settings and before the separator leading to About/Quit:

```swift
private func makeCheckForUpdatesMenuItem() -> NSMenuItem {
    let item = NSMenuItem(
        title: L10n.text(updateCheckCoordinator.isChecking
            ? "app.menu.checkingForUpdates"
            : "app.menu.checkForUpdates"),
        action: #selector(checkForUpdates),
        keyEquivalent: ""
    )
    item.target = self
    item.isEnabled = !updateCheckCoordinator.isChecking
    return item
}

@objc func checkForUpdates() {
    updateCheckCoordinator.checkManually()
}
```

Set `onCheckingStateChange` once so a transition rebuilds both menus. Language changes continue to rebuild them with the active state.

- [ ] **Step 5: Gate automatic presentation on every sensitive workflow**

Define `canPresentAutomaticUpdate` using `!isMigrationMaintenanceActive`, `!isRecordingHotkey`, and `migrationWorkflowsAreIdle`. Extend `refreshMigrationImportEligibility()` to call `presentPendingAutomaticUpdateIfPossible()`, and call the refresh from both transitions in `setHotkeyRecording(_:)`.

- [ ] **Step 6: Run focused and full tests, then commit**

Run: `swift test --filter AppCoordinatorSourceTests`

Expected: lifecycle, two-menu, checking-state, and idle-gate contracts pass.

Run: `swift test`

Expected: all existing and new tests pass.

```bash
git add Sources/InkletApp/AppCoordinator.swift Tests/InkletCoreTests/AppCoordinatorSourceTests.swift
git commit -m "Wire update checks into Inklet menus"
```

### Task 6: Update public documentation and privacy disclosure

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/privacy-policy.md`
- Modify: `docs/manual-test-checklist.md`
- Create: `Tests/InkletCoreTests/UpdateCheckDocumentationTests.swift`

- [ ] **Step 1: Write a failing documentation contract**

Load all four documents and require statements covering manual update checks, production 24-hour checks, GitHub Release metadata only, local-build manual-only behavior, no download/install, and the manual QA scenarios. Also reject claims that Inklet automatically installs updates.

- [ ] **Step 2: Run the documentation test and verify it fails**

Run: `swift test --filter UpdateCheckDocumentationTests`

Expected: failures identify missing shipped-behavior and privacy text.

- [ ] **Step 3: Update all four documents precisely**

Document that GitHub Releases remains the only distribution source; production checks public stable-release metadata approximately every 24 hours; both builds can check manually; Inklet only opens GitHub and never downloads or installs the DMG. In privacy policy, state GitHub receives ordinary connection metadata but no Inklet content, prompts, audio, credentials, or settings. Add manual checks for current/newer fixtures, offline Retry, Later, validated browser URL, production/local scheduling, busy-workflow deferral, long notes, English/Chinese fit, every locale, and no asset download.

- [ ] **Step 4: Run the documentation test and commit**

Run: `swift test --filter UpdateCheckDocumentationTests`

Expected: all documentation contracts pass.

```bash
git add README.md README.zh-CN.md docs/privacy-policy.md docs/manual-test-checklist.md Tests/InkletCoreTests/UpdateCheckDocumentationTests.swift
git commit -m "Document update check behavior"
```

### Task 7: Verify the complete implementation and local bundle

**Files:**
- Modify: `VERSION`

- [ ] **Step 1: Run narrow feature tests**

Run:

```bash
swift test --filter GitHubReleaseUpdateCheckerTests
swift test --filter UpdateCheckCoordinatorTests
swift test --filter UpdateCheckLocalizationTests
swift test --filter UpdateCheckAlertPresenterSourceTests
swift test --filter UpdateCheckDocumentationTests
swift test --filter AppCoordinatorSourceTests
```

Expected: every command exits 0 with no failed tests.

- [ ] **Step 2: Run the entire suite**

Run: `swift test`

Expected: the original 568 tests plus all new tests pass with zero failures.

- [ ] **Step 3: Inspect the release diff and repository hygiene**

Run:

```bash
git diff --check HEAD~5
git status --short
git diff --stat HEAD~5
rg -n "Sparkle|download.*Inklet\.dmg|install.*update" Sources Tests README.md README.zh-CN.md docs
```

Expected: no whitespace errors, only intentional feature files are changed, and no implementation adds Sparkle/download/install behavior.

- [ ] **Step 4: Bump the patch version before building the app bundle**

Change the current root `VERSION` value from `1.0.1` to `1.0.2` (or, if the branch has advanced, increment its current patch component by one). Do not alter the build number here.

- [ ] **Step 5: Build, install, and launch the stable local bundle**

Run: `scripts/run-local-app.sh`

Expected: the script builds, signs, installs `/Applications/Inklet Local.app` with bundle identifier `com.tomwan.inklet.local`, stops any prior matching process, launches successfully, and emits no build/signature error. Do not use Computer Use.

- [ ] **Step 6: Run post-build verification**

Run:

```bash
swift test
git diff --check
git status --short --branch
```

Expected: all tests pass, no whitespace errors, and only the intended `VERSION` modification remains uncommitted.

- [ ] **Step 7: Commit the verified version bump**

```bash
git add VERSION
git commit -m "Bump version for update check testing"
```

- [ ] **Step 8: Request code review and address findings**

Use the `superpowers:requesting-code-review` skill against the full branch diff. Fix every confirmed correctness, security, localization, privacy, concurrency, or test gap with focused tests first, rerun the narrow and full checks, and commit each logical correction.

- [ ] **Step 9: Perform the completion audit**

Run:

```bash
git diff --check HEAD~7
git status --short --branch
swift test
```

Expected: zero test failures, zero diff errors, a clean worktree, and branch `codex/check-for-updates` containing only focused implementation/documentation/version commits.
