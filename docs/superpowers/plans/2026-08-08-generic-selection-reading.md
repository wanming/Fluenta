# Generic Selection Reading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace browser-specific selected-text AppleScript with one source-bound Accessibility-to-clipboard pipeline that preserves right-click, Shift selection, and double-copy behavior without corrupting the pasteboard.

**Architecture:** Put source-process validation and read orchestration in small `InkletCore` types so behavior is covered by unit tests rather than app-source string checks. `SelectedTextReader` will accept only AX elements owned by the captured process, synthetic clipboard reads will be serialized transactions with conditional restoration, and the explicit double-copy path will observe the user's pasteboard change without issuing another copy. `AppCoordinator` will capture immutable request values and contain no browser identifier or reader.

**Tech Stack:** Swift 6, AppKit, ApplicationServices Accessibility APIs, NSPasteboard, Swift concurrency, XCTest, Swift Package Manager.

---

## Execution Order

Execute `2026-08-08-legacy-sandbox-data-migration.md` first so this plan edits the migration-aware `AppCoordinator` instead of creating a difficult rebase. Execute `2026-08-08-direct-developer-id-distribution.md` afterward; browser manual QA remains blocked until that final plan removes App Sandbox.

## File Structure

Create:

- `Sources/InkletCore/SelectionSourceValidator.swift` — verifies that the captured source PID is alive and still frontmost.
- `Sources/InkletCore/SelectionReadPipeline.swift` — orders AX and configured clipboard reads and revalidates the source.
- `Sources/InkletCore/SelectionUserCopyReader.swift` — observes the pasteboard change produced by the user's second `Command+C`.
- `Tests/InkletCoreTests/SelectionSourceValidatorTests.swift`
- `Tests/InkletCoreTests/SelectionReadPipelineTests.swift`
- `Tests/InkletCoreTests/SelectionUserCopyReaderTests.swift`
- `Tests/InkletCoreTests/SelectionArchitectureSourceTests.swift`

Modify:

- `Sources/InkletCore/SelectedTextReader.swift`
- `Tests/InkletCoreTests/SelectedTextReaderTests.swift`
- `Sources/InkletCore/SelectionClipboardReader.swift`
- `Tests/InkletCoreTests/SelectionClipboardReaderTests.swift`
- `Sources/InkletApp/SelectionActionMonitor.swift`
- `Tests/InkletCoreTests/SelectionActionMonitorSourceTests.swift`
- `Sources/InkletApp/AppCoordinator.swift`
- `Tests/InkletCoreTests/AppCoordinatorSourceTests.swift`

Delete:

- `Sources/InkletCore/SelectionBrowserTextReader.swift`
- `Tests/InkletCoreTests/SelectionBrowserTextReaderTests.swift`

Do not modify `SelectionActionCoordinator`, `SelectionCopyTriggerPolicy`, `SelectionDragPolicy`, or `ClipboardService`.

### Task 1: Bind Accessibility reads to the captured process

**Files:**

- Create: `Sources/InkletCore/SelectionSourceValidator.swift`
- Create: `Tests/InkletCoreTests/SelectionSourceValidatorTests.swift`
- Modify: `Sources/InkletCore/SelectedTextReader.swift`
- Modify: `Tests/InkletCoreTests/SelectedTextReaderTests.swift`

- [ ] **Step 1: Write failing source-validator tests**

Create `SelectionSourceValidatorTests.swift` with injected state so no real applications are touched:

```swift
import XCTest
@testable import InkletCore

final class SelectionSourceValidatorTests: XCTestCase {
    @MainActor
    func testRequiresRunningFrontmostProcess() {
        var running = true
        var frontmostPID: pid_t? = 42
        let validator = SelectionSourceValidator(
            isProcessRunning: { _ in running },
            frontmostProcessIdentifier: { frontmostPID }
        )

        XCTAssertTrue(validator.isCurrent(42))
        frontmostPID = 99
        XCTAssertFalse(validator.isCurrent(42))
        frontmostPID = 42
        running = false
        XCTAssertFalse(validator.isCurrent(42))
    }
}
```

- [ ] **Step 2: Write failing AX-ownership tests**

Add three tests to `SelectedTextReaderTests.swift`. Use PID `42` for the source and PID `99` for the unrelated system-focused element:

```swift
func testIgnoresSystemFocusedElementOwnedByAnotherProcess() {
    let reader = SelectedTextReader(
        isTrusted: { true },
        focusedElementProvider: { SelectedTextElement(rawValue: "other") },
        applicationFocusedElementProvider: { _ in SelectedTextElement(rawValue: "source") },
        elementProcessIdentifierProvider: { $0.rawValue == AnyHashable("source") ? 42 : 99 },
        selectedTextProvider: { .success($0.rawValue == AnyHashable("source") ? "expected" : "wrong") }
    )

    XCTAssertEqual(reader.readSelectedText(sourceProcessIdentifier: 42), .success("expected"))
}

func testRejectsDescendantOwnedByAnotherProcess() {
    let reader = SelectedTextReader(
        isTrusted: { true },
        focusedElementProvider: { nil },
        applicationFocusedElementProvider: { _ in SelectedTextElement(rawValue: "root") },
        childElementsProvider: { _ in [SelectedTextElement(rawValue: "foreign-child")] },
        elementProcessIdentifierProvider: { $0.rawValue == AnyHashable("root") ? 42 : 99 },
        selectedTextProvider: { .success($0.rawValue == AnyHashable("foreign-child") ? "wrong" : "") }
    )

    XCTAssertEqual(reader.readSelectedText(sourceProcessIdentifier: 42), .emptySelection)
}

func testRejectsCandidateWhoseOwnerCannotBeDetermined() {
    let reader = SelectedTextReader(
        isTrusted: { true },
        focusedElementProvider: { SelectedTextElement(rawValue: "unknown") },
        elementProcessIdentifierProvider: { _ in nil },
        selectedTextProvider: { _ in .success("wrong") }
    )

    XCTAssertEqual(reader.readSelectedText(sourceProcessIdentifier: 42), .missingFocusedElement)
}
```

Update every existing test that supplies `sourceProcessIdentifier` to inject `elementProcessIdentifierProvider: { _ in expectedPID }`.

- [ ] **Step 3: Run the focused tests and confirm RED**

Run:

```bash
swift test --filter 'SelectionSourceValidatorTests|SelectedTextReaderTests'
```

Expected: compilation fails because `SelectionSourceValidator` and `elementProcessIdentifierProvider` do not exist.

- [ ] **Step 4: Implement the source validator**

Create `SelectionSourceValidator.swift` with this public surface and exact invariant:

```swift
import AppKit
import Foundation

@MainActor
public struct SelectionSourceValidator {
    public typealias ProcessRunningChecker = @MainActor @Sendable (pid_t) -> Bool
    public typealias FrontmostProcessIdentifierProvider = @MainActor @Sendable () -> pid_t?

    private let isProcessRunning: ProcessRunningChecker
    private let frontmostProcessIdentifier: FrontmostProcessIdentifierProvider

    public init(
        isProcessRunning: @escaping ProcessRunningChecker = {
            NSRunningApplication(processIdentifier: $0)?.isTerminated == false
        },
        frontmostProcessIdentifier: @escaping FrontmostProcessIdentifierProvider = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    ) {
        self.isProcessRunning = isProcessRunning
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
    }

    public func isCurrent(_ processIdentifier: pid_t) -> Bool {
        isProcessRunning(processIdentifier)
            && frontmostProcessIdentifier() == processIdentifier
    }
}
```

- [ ] **Step 5: Filter every AX candidate by owner PID**

Add `ElementProcessIdentifierProvider` to `SelectedTextReader`, default it to `systemProcessIdentifier(of:)`, and implement the system lookup with `AXUIElementGetPid`. When a source PID is present, filter both the initial candidate array and every recursively expanded child with:

```swift
private func belongsToSource(_ element: SelectedTextElement, sourcePID: pid_t?) -> Bool {
    guard let sourcePID else { return true }
    return elementProcessIdentifierProvider(element) == sourcePID
}
```

If filtering removes every initial candidate, return `.missingFocusedElement`. Remove `isFocusedSelectableTextElement` and its role/value-only dependencies and tests; orchestration must no longer use this unreliable Boolean preflight.

- [ ] **Step 6: Run focused tests and confirm GREEN**

Run:

```bash
swift test --filter 'SelectionSourceValidatorTests|SelectedTextReaderTests'
```

Expected: all selected tests pass.

- [ ] **Step 7: Commit the captured-process invariant**

```bash
git add Sources/InkletCore/SelectionSourceValidator.swift Sources/InkletCore/SelectedTextReader.swift Tests/InkletCoreTests/SelectionSourceValidatorTests.swift Tests/InkletCoreTests/SelectedTextReaderTests.swift
git commit -m "Validate selection reads against the captured process"
```

### Task 2: Serialize synthetic clipboard transactions

**Files:**

- Modify: `Sources/InkletCore/SelectionClipboardReader.swift`
- Modify: `Tests/InkletCoreTests/SelectionClipboardReaderTests.swift`

- [ ] **Step 1: Add failing focus and clipboard-ownership tests**

Extend `SelectionClipboardReaderTests` with injected `sourceProcessValidator`. Cover these exact transitions:

```swift
@MainActor
func testInactiveSourceDoesNotPerformCopy() async {
    var performed = false
    let reader = SelectionClipboardReader(
        pasteboard: .withUniqueName(),
        isTrusted: { true },
        sourceProcessValidator: { _ in false },
        copyMenuActionPerformer: { _ in performed = true; return .performed },
        copyShortcutSender: { _ in performed = true }
    )

    XCTAssertEqual(
        await reader.readSelectedText(sourceProcessIdentifier: 42),
        .emptySelection
    )
    XCTAssertFalse(performed)
}

@MainActor
func testExternalClipboardChangeIsNotOverwritten() async {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.clearContents()
    pasteboard.setString("original", forType: .string)
    var pollCount = 0
    let reader = SelectionClipboardReader(
        pasteboard: pasteboard,
        isTrusted: { true },
        sourceProcessValidator: { _ in true },
        copyMenuActionPerformer: { _ in
            pasteboard.clearContents()
            pasteboard.setString("selection", forType: .string)
            return .performed
        },
        delayProvider: { _ in
            pollCount += 1
            if pollCount == 1 {
                pasteboard.clearContents()
                pasteboard.setString("new user value", forType: .string)
            }
        },
        shortcutReadWrapper: { operation in await operation() }
    )

    _ = await reader.readSelectedText(sourceProcessIdentifier: 42)
    XCTAssertEqual(pasteboard.string(forType: .string), "new user value")
}
```

Add named tests for cancellation, timeout after an owned empty copy, source invalidation before shortcut fallback, and two overlapping reads. The overlap test must assert that read 1 cleanup completes before read 2 takes its snapshot and that read 1 cannot restore over read 2.

- [ ] **Step 2: Run the clipboard tests and confirm RED**

```bash
swift test --filter SelectionClipboardReaderTests
```

Expected: initializer/signature failures first; after those compile, the current unconditional restore fails the external-change and overlap assertions.

- [ ] **Step 3: Implement one-active-read ownership**

Make the PID nonoptional, add `SourceProcessValidator`, and expose cancellation:

```swift
public typealias SourceProcessValidator = @MainActor @Sendable (pid_t) -> Bool

public func readSelectedText(
    sourceProcessIdentifier: pid_t,
    forceSelectionMode: SelectionForceSelectionMode = .menuCopyThenShortcut
) async -> SelectedTextReadResult

public func cancelActiveRead() async
```

Use private `ActiveRead` and `PasteboardTransaction` values:

```swift
private struct ActiveRead {
    let token: UUID
    let task: Task<SelectedTextReadResult, Never>
}

private struct PasteboardTransaction {
    let token: UUID
    let snapshot: PasteboardSnapshot
    let initialChangeCount: Int
    var observedCopyChangeCount: Int?
}
```

A new public read cancels and awaits the prior task before constructing its transaction. Validate the source immediately before each menu action or shortcut send and before accepting text. Record only the first changed pasteboard count. Restore only when the transaction token is still current and `pasteboard.changeCount` equals `observedCopyChangeCount`; otherwise leave the current contents untouched. If no copy change was observed, do not restore. Propagate parent cancellation with `withTaskCancellationHandler` and return `.emptySelection` after conditional cleanup.

- [ ] **Step 4: Preserve the existing force-mode order**

Keep these exact results in tests and implementation:

| Mode | Menu result | Shortcut behavior | Final result |
|---|---|---|---|
| `.disabled` | not called | not called | `.unsupported` |
| `.menuCopyOnly` | `.noMenuItem` | not called | `.unsupported` |
| `.menuCopyThenShortcut` | `.noMenuItem` | called | shortcut result |
| `.menuCopyThenShortcut` | `.disabled` | not called | `.emptySelection` |
| `.shortcutThenMenuCopy` | no shortcut text | called after shortcut | menu result |

- [ ] **Step 5: Run tests and commit**

```bash
swift test --filter SelectionClipboardReaderTests
git add Sources/InkletCore/SelectionClipboardReader.swift Tests/InkletCoreTests/SelectionClipboardReaderTests.swift
git commit -m "Serialize clipboard selection transactions"
```

Expected: all clipboard tests pass.

### Task 3: Add the generic read pipeline and remove browser code

**Files:**

- Create: `Sources/InkletCore/SelectionReadPipeline.swift`
- Create: `Tests/InkletCoreTests/SelectionReadPipelineTests.swift`
- Create: `Tests/InkletCoreTests/SelectionArchitectureSourceTests.swift`
- Modify: `Sources/InkletApp/AppCoordinator.swift`
- Modify: `Tests/InkletCoreTests/AppCoordinatorSourceTests.swift`
- Delete: `Sources/InkletCore/SelectionBrowserTextReader.swift`
- Delete: `Tests/InkletCoreTests/SelectionBrowserTextReaderTests.swift`

- [ ] **Step 1: Write failing pipeline tests**

Create table-driven tests for these exact cases:

| Start current | AX result | Force mode | Current after read | Clipboard result | Expected |
|---|---|---|---|---|---|
| false | not called | enabled | — | not called | `.emptySelection` |
| true | `.success("AX")` | enabled | true | not called | `.success("AX")` |
| true | `.success("AX")` | enabled | false | not called | `.emptySelection` |
| true | `.permissionDenied` | enabled | true | not called | `.permissionDenied` |
| true | `.unsupported` | `.disabled` | true | not called | `.unsupported` |
| true | `.unsupported` | enabled | true | `.success("copy")` | `.success("copy")` |
| true | `.emptySelection` | enabled | true | `.emptySelection` | `.emptySelection` |
| true | `.failed("AX")` | enabled | true | `.unsupported` | `.failed("AX")` |

Use counters in the injected closures and assert every “not called” cell explicitly.

- [ ] **Step 2: Run the pipeline tests and confirm RED**

```bash
swift test --filter SelectionReadPipelineTests
```

Expected: compilation fails because `SelectionReadPipeline` does not exist.

- [ ] **Step 3: Implement the ordered pipeline**

Create the following public surface:

```swift
@MainActor
public final class SelectionReadPipeline {
    public typealias SourceValidator = @MainActor @Sendable (pid_t) -> Bool
    public typealias AccessibilityReader = @MainActor @Sendable (pid_t, SelectionPoint?) -> SelectedTextReadResult
    public typealias ClipboardReader = @MainActor @Sendable (pid_t, SelectionForceSelectionMode) async -> SelectedTextReadResult

    public init(
        sourceValidator: @escaping SourceValidator,
        accessibilityReader: @escaping AccessibilityReader,
        clipboardReader: @escaping ClipboardReader
    )

    public func readSelectedText(
        sourceProcessIdentifier: pid_t,
        mouseLocation: SelectionPoint?,
        forceSelectionMode: SelectionForceSelectionMode
    ) async -> SelectedTextReadResult
}
```

Implement the table from Step 1. Revalidate before accepting AX success and rely on `SelectionClipboardReader` to validate around each synthetic action. Prefer clipboard success, empty, or failure; when clipboard returns `.unsupported`, preserve the AX result.

- [ ] **Step 4: Write the architecture contract before deleting browser files**

`SelectionArchitectureSourceTests` must enumerate Swift source files and assert that none contains `SelectionBrowserTextReader`, `com.google.Chrome`, `com.microsoft.edgemac`, `com.apple.Safari`, or browser-targeted `tell application id`. It must allow the untargeted alert-volume `NSAppleScript` in `SelectionClipboardReader`.

Run:

```bash
swift test --filter SelectionArchitectureSourceTests
```

Expected: FAIL while browser source and coordinator wiring still exist.

- [ ] **Step 5: Wire immutable automatic reads in AppCoordinator**

Remove `selectionBrowserTextReader`, `pendingSelectionSourceBundleIdentifier`, the selectable-element early return, `browserResult`, and three-way arbitration. Construct one `SelectionReadPipeline` from `SelectionSourceValidator`, `SelectedTextReader`, and `SelectionClipboardReader`.

When scheduling, capture one immutable request rather than reading mutable pending properties after the delay:

```swift
private struct PendingSelectionRead {
    let sourceProcessIdentifier: pid_t
    let location: SelectionPoint
}
```

Pass that value into `completeScheduledSelectionRead(_:)`. A canceled old task must never observe a newer PID or location.

- [ ] **Step 6: Delete browser implementation/tests and update source tests**

Delete both browser files. Update `AppCoordinatorSourceTests.testAutomaticSelectionReadUsesEasyDictStyleFallbackPipeline` to require `SelectionReadPipeline`, `forceSelectionMode`, and immutable request capture, and to reject `SelectionBrowserTextReader`, bundle-ID state, and `isFocusedSelectableTextElement`.

- [ ] **Step 7: Run focused tests and commit**

```bash
swift test --filter 'SelectionReadPipelineTests|SelectionArchitectureSourceTests|AppCoordinatorSourceTests'
git add Sources/InkletCore/SelectionReadPipeline.swift Sources/InkletApp/AppCoordinator.swift Tests/InkletCoreTests/SelectionReadPipelineTests.swift Tests/InkletCoreTests/SelectionArchitectureSourceTests.swift Tests/InkletCoreTests/AppCoordinatorSourceTests.swift
git add -u Sources/InkletCore/SelectionBrowserTextReader.swift Tests/InkletCoreTests/SelectionBrowserTextReaderTests.swift
git commit -m "Replace browser selection with the generic pipeline"
```

Expected: all selected tests pass and no browser-specific selection source remains.

### Task 4: Preserve the user-driven double-copy path

**Files:**

- Create: `Sources/InkletCore/SelectionUserCopyReader.swift`
- Create: `Tests/InkletCoreTests/SelectionUserCopyReaderTests.swift`
- Modify: `Sources/InkletApp/SelectionActionMonitor.swift`
- Modify: `Tests/InkletCoreTests/SelectionActionMonitorSourceTests.swift`
- Modify: `Sources/InkletApp/AppCoordinator.swift`
- Modify: `Tests/InkletCoreTests/AppCoordinatorSourceTests.swift`

- [ ] **Step 1: Write failing user-copy tests**

Create tests that initialize a unique pasteboard at change count `N` and assert:

```swift
XCTAssertEqual(
    await reader.readCopiedText(sourceProcessIdentifier: 42, after: initialChangeCount),
    .success("second copy")
)
```

The success test changes the pasteboard once from the delay closure. Add separate tests where it never changes (expect `.emptySelection`), the source validator flips false before acceptance (expect `.emptySelection`), and the task is canceled (expect `.emptySelection`). In every test assert that the reader neither restores nor writes pasteboard contents.

- [ ] **Step 2: Run tests and confirm RED**

```bash
swift test --filter SelectionUserCopyReaderTests
```

Expected: compilation fails because the reader does not exist.

- [ ] **Step 3: Implement the passive reader**

Create `SelectionUserCopyReader` with this exact API:

```swift
@MainActor
public final class SelectionUserCopyReader {
    public typealias SourceProcessValidator = @MainActor @Sendable (pid_t) -> Bool
    public typealias DelayProvider = @MainActor @Sendable (UInt64) async -> Void

    public init(
        pasteboard: NSPasteboard = .general,
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        pollTimeoutNanoseconds: UInt64 = 400_000_000,
        sourceProcessValidator: @escaping SourceProcessValidator,
        delayProvider: @escaping DelayProvider = { try? await Task.sleep(nanoseconds: $0) }
    )

    public func readCopiedText(
        sourceProcessIdentifier: pid_t,
        after initialChangeCount: Int
    ) async -> SelectedTextReadResult
}
```

Poll until the count differs, then revalidate the source and return trimmed nonempty text. Never clear, snapshot, synthesize a key, perform a menu action, or restore the pasteboard.

- [ ] **Step 4: Carry the pre-copy change count from the monitor**

Change the callback to:

```swift
var onCopyTrigger: ((SelectionPoint, Int) -> Void)?
```

At the second-copy key-down boundary, pass `NSPasteboard.general.changeCount`. Preserve the Shift key-up candidate monitor, `.leftMouseUp`-only candidate mask, and `.rightMouseDown` dismissal mask. Add source tests for all three invariants.

- [ ] **Step 5: Wire the passive path in AppCoordinator**

Capture source PID, point, and change count immediately. Cancel the automatic selection task, call `await selectionClipboardReader.cancelActiveRead()`, then call `SelectionUserCopyReader.readCopiedText`. Revalidate through the shared `SelectionSourceValidator` before showing the panel. Do not call the synthetic reader from this handler.

- [ ] **Step 6: Run focused regressions and commit**

```bash
swift test --filter 'SelectionUserCopyReaderTests|SelectionCopyTriggerPolicyTests|SelectionActionMonitorSourceTests|AppCoordinatorSourceTests'
git add Sources/InkletCore/SelectionUserCopyReader.swift Sources/InkletApp/SelectionActionMonitor.swift Sources/InkletApp/AppCoordinator.swift Tests/InkletCoreTests/SelectionUserCopyReaderTests.swift Tests/InkletCoreTests/SelectionActionMonitorSourceTests.swift Tests/InkletCoreTests/AppCoordinatorSourceTests.swift
git commit -m "Preserve the user-driven double-copy path"
```

Expected: all selected tests pass.

### Task 5: Verify the generic selection subsystem

**Files:** No new files.

- [ ] **Step 1: Run the complete automated suite**

```bash
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
git status --short
```

Expected: all tests/builds pass, `git diff --check` is silent, and status contains only intentional plan-execution changes.

- [ ] **Step 2: Defer browser manual QA until the sandbox-removal plan lands**

Do not claim Chrome/Safari/Edge success from a still-sandboxed app. After the direct-distribution plan removes the sandbox, use `/Applications/Inklet Local.app` and verify drag selection, double/triple click, Shift selection, double-copy, right-click native menus, protected fields, focus changes, and concurrent clipboard changes. No browser Automation prompt may appear.
