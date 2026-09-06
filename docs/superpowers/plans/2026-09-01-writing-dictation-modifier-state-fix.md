# Writing Dictation Modifier State Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a physical Right Option hold start Writing Assistant dictation when macOS carries modifier state in `flagsChanged.modifierFlags` rather than `CGEventSource.keyState`.

**Architecture:** Keep the app-local monitor, side-specific virtual key codes, gesture recognizer, and coordinator unchanged. The monitor will use each matching `flagsChanged` event's device-independent flags for press classification, while context activation uses aggregate AppKit modifier state only as a conservative fresh-release gate.

**Tech Stack:** Swift 6, AppKit `NSEvent`, CoreGraphics, XCTest, Swift Package Manager.

---

### Task 1: Reproduce And Repair Modifier Press Classification

**Files:**
- Modify: `Tests/InkletCoreTests/WritingDictationShortcutMonitorTests.swift`
- Modify: `Sources/InkletApp/WritingDictationShortcutMonitor.swift`

- [ ] **Step 1: Write the failing regression test**

Add this test to `WritingDictationShortcutMonitorTests`:

```swift
func testRightOptionHoldUsesEventFlagsWhenQuartzKeyStateIsFalse() {
    let harness = ShortcutMonitorHarness()
    harness.subject.activateEditorContext(modifierAlreadyDown: false)

    harness.sendModifier(
        keyCode: 61,
        flags: .option,
        configuredKeyIsDown: false
    )
    harness.scheduler.fireNext()
    harness.sendModifier(
        keyCode: 61,
        flags: [],
        configuredKeyIsDown: false
    )

    XCTAssertEqual(harness.actions, [.start, .stop])
}
```

- [ ] **Step 2: Run the regression test and confirm the red state**

Run:

```bash
swift test --filter WritingDictationShortcutMonitorTests/testRightOptionHoldUsesEventFlagsWhenQuartzKeyStateIsFalse
```

Expected: FAIL because `harness.actions` is `[]`; production currently trusts the injected Quartz key-state value instead of the event flags.

- [ ] **Step 3: Implement the minimal event-flags repair**

In `handleFlagsChanged`, derive the new-press state from the matching event:

```swift
let isConfiguredKeyDown = event.modifierFlags
    .intersection(.deviceIndependentFlagsMask)
    .contains(shortcut.modifierFlag)
```

Retain the injected `configuredKeyState` only for `activateEditorContext()`, but change its default implementation to aggregate AppKit state so it no longer calls `CGEventSource.keyState`:

```swift
configuredKeyState: @escaping ConfiguredKeyState = { keyCode in
    switch keyCode {
    case 58, 61:
        NSEvent.modifierFlags.contains(.option)
    case 54, 55:
        NSEvent.modifierFlags.contains(.command)
    default:
        false
    }
}
```

Add the side-family mapping beside the existing shortcut key-code mapping:

```swift
var modifierFlag: NSEvent.ModifierFlags {
    switch self {
    case .rightOption, .leftOption:
        .option
    case .rightCommand, .leftCommand:
        .command
    case .disabled:
        []
    }
}
```

- [ ] **Step 4: Run focused tests and confirm green**

Run:

```bash
swift test --filter WritingDictationShortcutMonitorTests
```

Expected: every shortcut-monitor test passes, including the new platform-shape regression.

- [ ] **Step 5: Commit the focused repair**

```bash
git add Sources/InkletApp/WritingDictationShortcutMonitor.swift \
  Tests/InkletCoreTests/WritingDictationShortcutMonitorTests.swift
git diff --cached --check
git commit -m "Fix Writing dictation modifier detection"
```

### Task 2: Verify And Install The Corrected Local App

**Files:**
- Modify: `VERSION`

- [ ] **Step 1: Run all automated verification**

Run:

```bash
swift test
swift build -Xswiftc -warnings-as-errors
bash scripts/test-run-local-app.sh
git diff --check
```

Expected: 0 test failures, strict build success, runner contract success, and silent diff check.

- [ ] **Step 2: Update the local build version**

Change `VERSION` to:

```text
INKLET_VERSION=1.1.2
INKLET_BUILD_NUMBER=8
```

- [ ] **Step 3: Build, install, and launch the stable local bundle**

Run:

```bash
scripts/run-local-app.sh
```

Expected: signed `Inklet Local` builds, replaces `/Applications/Inklet Local.app`, verifies, and launches.

- [ ] **Step 4: Verify the installed result**

Run:

```bash
pgrep -x 'Inklet Local'
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  -c 'Print :CFBundleShortVersionString' \
  -c 'Print :CFBundleVersion' \
  '/Applications/Inklet Local.app/Contents/Info.plist'
codesign --verify --deep --strict '/Applications/Inklet Local.app'
```

Expected: a running PID, bundle id `com.tomwan.inklet.local`, version `1.1.2`, build `8`, and successful signature verification.

- [ ] **Step 5: Commit the version and inspect repository state**

```bash
git add VERSION
git diff --cached --check
git commit -m "Bump Inklet version to 1.1.2"
git diff --check
git status --short
```

Expected: the commit succeeds, diff check is silent, and the worktree is clean.

- [ ] **Step 6: Hand off the physical-key check**

Ask the user to open Writing Assistant, confirm a Prompt Mode, focus the source editor, release all modifiers, then hold and release physical Right Option. Expected: the action bar enters listening/finalizing states and dictated text appears in the editable draft.
