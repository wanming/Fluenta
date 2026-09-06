# Writing Dictation Dispatch Work Item Crash Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent the release app from crashing when a valid Writing dictation modifier press creates the production hold-delay work item.

**Architecture:** Preserve the existing `CancellableHold` abstraction, `DispatchWorkItemHold` cancellation semantics, hold delay, and main-queue execution. Add an optimized-build regression that exercises the default scheduler, then remove only the explicit actor annotation that triggers malformed Swift 6 closure-to-block bridging.

**Tech Stack:** Swift 6, AppKit, Grand Central Dispatch, XCTest, Swift Package Manager, macOS app-bundle scripts.

---

### Task 1: Reproduce and repair the production hold scheduler

**Files:**
- Modify: `Tests/InkletCoreTests/WritingDictationShortcutMonitorTests.swift`
- Modify: `Sources/InkletApp/WritingDictationShortcutMonitor.swift:13-22`

- [ ] **Step 1: Write the production-scheduler regression test**

Add this test inside `WritingDictationShortcutMonitorTests` without injecting `scheduleHold`, so it exercises `DispatchWorkItemHold`:

```swift
func testDefaultHoldSchedulerStartsAfterDelay() async {
    let holdStarted = expectation(description: "default hold scheduler started dictation")
    let subject = WritingDictationShortcutMonitor(
        holdActivationDelay: 0.01,
        configuredKeyState: { _ in false }
    )
    subject.configure(
        shortcut: .rightOption,
        isEligible: { true },
        onStart: { holdStarted.fulfill() },
        onStop: {},
        onCancel: {}
    )
    subject.activateEditorContext(modifierAlreadyDown: false)

    subject.handle(makeKeyEvent(type: .flagsChanged, keyCode: 61, flags: .option))
    await fulfillment(of: [holdStarted], timeout: 1)
    subject.handle(makeKeyEvent(type: .flagsChanged, keyCode: 61, flags: []))
}
```

- [ ] **Step 2: Run the optimized regression and verify RED**

Run:

```bash
swift test -c release --filter WritingDictationShortcutMonitorTests.testDefaultHoldSchedulerStartsAfterDelay
```

Expected: the test process exits with `SIGBUS` / signal 10 while `_Block_copy` constructs `DispatchWorkItemHold` at `WritingDictationShortcutMonitor.swift:17`. An assertion failure or compilation error is not the expected RED result and must be corrected before proceeding.

- [ ] **Step 3: Apply the minimal production repair**

Change only the work-item closure construction:

```swift
let workItem = DispatchWorkItem {
    action()
}
```

Keep the `@MainActor` annotation on `DispatchWorkItemHold`, the `action` parameter, and the scheduler type alias. Keep scheduling the work item through `DispatchQueue.main.asyncAfter`.

- [ ] **Step 4: Run the regression and focused monitor suite GREEN**

Run:

```bash
swift test -c release --filter WritingDictationShortcutMonitorTests.testDefaultHoldSchedulerStartsAfterDelay
swift test --filter WritingDictationShortcutMonitorTests
```

Expected: the new optimized regression passes without a signal, and every shortcut-monitor test passes.

- [ ] **Step 5: Review and commit the focused fix**

Run:

```bash
git diff --check
git diff -- Sources/InkletApp/WritingDictationShortcutMonitor.swift Tests/InkletCoreTests/WritingDictationShortcutMonitorTests.swift
git add Sources/InkletApp/WritingDictationShortcutMonitor.swift Tests/InkletCoreTests/WritingDictationShortcutMonitorTests.swift
git commit -m "Fix Writing dictation hold scheduler crash"
```

Expected: the staged change contains only the production scheduler regression and the closure-annotation removal.

### Task 2: Run complete code and distribution verification

**Files:**
- Verify: `Sources/InkletApp/WritingDictationShortcutMonitor.swift`
- Verify: `Tests/InkletCoreTests/WritingDictationShortcutMonitorTests.swift`
- Verify: `scripts/test-run-local-app.sh`
- Verify: `scripts/test-direct-distribution.sh`

- [ ] **Step 1: Run both complete test configurations**

Run:

```bash
swift test
swift test -c release
```

Expected: all XCTest and Swift Testing tests pass in both debug and release configurations with zero unexpected signals.

- [ ] **Step 2: Run strict builds**

Run:

```bash
swift build -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
```

Expected: both builds exit successfully with no warnings.

- [ ] **Step 3: Run local-runner and distribution script checks**

Run:

```bash
bash scripts/test-run-local-app.sh
bash scripts/test-direct-distribution.sh
```

Expected: both script suites report success.

### Task 3: Version, install, and launch the repaired app

**Files:**
- Modify: `VERSION`

- [ ] **Step 1: Increment the local app version before bundle creation**

Change `VERSION` to:

```dotenv
INKLET_VERSION=1.1.3
INKLET_BUILD_NUMBER=9
```

- [ ] **Step 2: Review and commit the version change**

Run:

```bash
git diff --check
git diff -- VERSION
git add VERSION
git commit -m "Bump Inklet version to 1.1.3"
```

Expected: the commit changes only `1.1.2 (8)` to `1.1.3 (9)`.

- [ ] **Step 3: Build, sign, install, and launch the stable local bundle**

Run:

```bash
scripts/run-local-app.sh
```

Expected: the script shuts down any existing `Inklet Local` process, builds the release executable, signs and verifies the bundle, installs `/Applications/Inklet Local.app`, and launches it successfully without printing the signing identity.

- [ ] **Step 4: Verify the installed artifact and repository state**

Run:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '/Applications/Inklet Local.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '/Applications/Inklet Local.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '/Applications/Inklet Local.app/Contents/Info.plist'
codesign --verify --deep --strict '/Applications/Inklet Local.app'
pgrep -fl '^/Applications/Inklet Local.app/Contents/MacOS/Inklet Local$'
git diff --check
git status --short --branch
```

Expected: bundle ID `com.tomwan.inklet.local`, version `1.1.3`, build `9`, valid signature, one running installed process, and a clean `codex/voice-writing-integration` worktree.

- [ ] **Step 5: Hand off physical shortcut QA**

Ask the user to open Writing Assistant in Prompt mode, focus the editable source draft, hold physical Right Option for at least the activation delay, speak, and release. Expected behavior: the action bar enters connecting/listening state, live transcript text appears, release finalizes the editable draft, and no crash report is generated.
