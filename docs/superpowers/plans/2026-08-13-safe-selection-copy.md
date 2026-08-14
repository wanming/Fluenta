# Safe Selection Copy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent passive Selection Actions from injecting `Command+C` into games or other foreground apps by default while preserving a hardened, user-initiated double-`Command+C` trigger.

**Architecture:** Keep safety decisions executable in `InkletCore`: config migration owns the opt-in boundary, a pure copy-gesture policy owns key sequencing and clipboard validation, and the clipboard reader marks/revalidates optional generated events. `InkletApp` converts global `NSEvent` metadata into those core APIs, rate-limits content-free diagnostics, and exposes one localized advanced setting.

**Tech Stack:** Swift 6, AppKit, CoreGraphics, ApplicationServices, SwiftUI, XCTest, Swift Package Manager.

---

## File Map

- Modify `Sources/InkletCore/SelectionActionsConfig.swift`: safe defaults, legacy normalization, and the explicit simulated-copy permission.
- Modify `Sources/InkletCore/SelectionCopyTriggerPolicy.swift`: independent key-cycle recognizer and pasteboard validation.
- Modify `Sources/InkletCore/SelectedTextReader.swift`: conservative selectable-text preflight.
- Modify `Sources/InkletCore/SelectionClipboardReader.swift`: opt-in enforcement, foreground PID revalidation, and private generated-event marker.
- Modify `Sources/InkletApp/SelectionActionMonitor.swift`: key-down/key-up routing, event provenance, lifecycle reset, and rate-limited metadata logging.
- Modify `Sources/InkletApp/AppCoordinator.swift`: pass safe config, validate manual-copy clipboard changes, and cancel stale source-app work.
- Modify `Sources/InkletApp/SelectionActionDiagnostics.swift`: focused rate-limited copy-event diagnostics.
- Modify `Sources/InkletApp/SettingsView.swift`: safe Force Selection cases and advanced opt-in toggle.
- Modify `Sources/InkletApp/InkletLocalization.swift`: all supported UI languages for the new setting and revised Force Selection help.
- Modify `Tests/InkletCoreTests/SelectionActionsConfigTests.swift`: defaults, migration, and round-trip coverage.
- Modify `Tests/InkletCoreTests/ConfigStoreTests.swift`: persistence coverage for the new property.
- Modify `Tests/InkletCoreTests/SelectionCopyTriggerPolicyTests.swift`: executable gesture and clipboard-validation matrix.
- Modify `Tests/InkletCoreTests/SelectedTextReaderTests.swift`: conservative preflight regressions.
- Modify `Tests/InkletCoreTests/SelectionClipboardReaderTests.swift`: opt-in, PID, marker, and clipboard restoration behavior.
- Create `Tests/InkletCoreTests/SelectionActionMonitorSourceTests.swift`: AppKit wiring and diagnostics privacy assertions.
- Modify `Tests/InkletCoreTests/AppCoordinatorSourceTests.swift`: config propagation and manual-copy validation wiring.
- Modify `Tests/InkletCoreTests/SettingsViewSourceTests.swift`: safe picker and advanced toggle wiring.
- Modify `README.md`, `README.zh-CN.md`, `docs/privacy-policy.md`, and `docs/manual-test-checklist.md`: shipped behavior, risk disclosure, privacy, and QA.

### Task 1: Make simulated copy an explicit safe configuration

**Files:**
- Modify: `Sources/InkletCore/SelectionActionsConfig.swift`
- Test: `Tests/InkletCoreTests/SelectionActionsConfigTests.swift`
- Test: `Tests/InkletCoreTests/ConfigStoreTests.swift`

- [ ] **Step 1: Write failing config tests**

Replace shortcut-default expectations and add migration/round-trip tests:

```swift
func testDefaultConfigUsesMenuCopyWithoutSimulatedShortcut() {
    let config = SelectionActionsConfig.defaultConfig()

    XCTAssertEqual(config.forceSelectionMode, .menuCopyOnly)
    XCTAssertFalse(config.allowsSimulatedCopyFallback)
    XCTAssertEqual(SelectionForceSelectionMode.settingsCases, [.disabled, .menuCopyOnly])
}

func testLegacyShortcutModesNormalizeToMenuCopyWithoutExplicitPermission() throws {
    for mode in ["menuCopyThenShortcut", "shortcutThenMenuCopy"] {
        let data = Data(#"{"forceSelectionMode":"\#(mode)"}"#.utf8)
        let config = try JSONDecoder().decode(SelectionActionsConfig.self, from: data)

        XCTAssertEqual(config.forceSelectionMode, .menuCopyOnly)
        XCTAssertFalse(config.allowsSimulatedCopyFallback)
    }
}

func testExplicitSimulatedCopyPermissionRoundTrips() throws {
    let config = SelectionActionsConfig(
        forceSelectionMode: .menuCopyOnly,
        allowsSimulatedCopyFallback: true
    )

    let decoded = try JSONDecoder().decode(
        SelectionActionsConfig.self,
        from: JSONEncoder().encode(config)
    )

    XCTAssertEqual(decoded.forceSelectionMode, .menuCopyOnly)
    XCTAssertTrue(decoded.allowsSimulatedCopyFallback)
}
```

Update `testConfigRoundTripsThroughUserDefaults` so its `SelectionActionsConfig` fixture sets `allowsSimulatedCopyFallback: true` and proves persistence through the existing whole-config equality assertion.

- [ ] **Step 2: Run the focused tests to verify RED**

Run:

```bash
swift test --filter SelectionActionsConfigTests
swift test --filter ConfigStoreTests.testConfigRoundTripsThroughUserDefaults
```

Expected: compilation fails because `allowsSimulatedCopyFallback` and `settingsCases` do not exist, and the old default is shortcut-capable.

- [ ] **Step 3: Implement safe defaults and decoding**

Add a safe picker surface and persisted permission:

```swift
public enum SelectionForceSelectionMode: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case disabled
    case menuCopyOnly
    case menuCopyThenShortcut
    case shortcutThenMenuCopy

    public static let settingsCases: [Self] = [.disabled, .menuCopyOnly]
    public var id: String { rawValue }

    var normalizedForSafeSettings: Self {
        self == .disabled ? .disabled : .menuCopyOnly
    }
}
```

Add `public var allowsSimulatedCopyFallback: Bool`, default it to `false`, include it in `CodingKeys`, and decode missing values as `false`. Normalize every decoded non-disabled mode:

```swift
let decodedForceSelectionMode = try container.decodeIfPresent(
    SelectionForceSelectionMode.self,
    forKey: .forceSelectionMode
) ?? defaults.forceSelectionMode
forceSelectionMode = decodedForceSelectionMode.normalizedForSafeSettings
allowsSimulatedCopyFallback = try container.decodeIfPresent(
    Bool.self,
    forKey: .allowsSimulatedCopyFallback
) ?? false
```

Change the initializer default from `.menuCopyThenShortcut` to `.menuCopyOnly` and keep memberwise construction source-compatible by adding the new parameter after `forceSelectionMode` with a default value.

- [ ] **Step 4: Run focused config tests to verify GREEN**

Run:

```bash
swift test --filter SelectionActionsConfigTests
swift test --filter ConfigStoreTests
```

Expected: both suites pass with zero failures.

- [ ] **Step 5: Commit the safe configuration boundary**

```bash
git add Sources/InkletCore/SelectionActionsConfig.swift \
  Tests/InkletCoreTests/SelectionActionsConfigTests.swift \
  Tests/InkletCoreTests/ConfigStoreTests.swift
git commit -m "Make simulated selection copy opt in"
```

### Task 2: Tighten selectable-text preflight

**Files:**
- Modify: `Sources/InkletCore/SelectedTextReader.swift`
- Test: `Tests/InkletCoreTests/SelectedTextReaderTests.swift`

- [ ] **Step 1: Change permissive tests to safety regressions**

Replace the current missing-element and generic-value expectations:

```swift
func testFocusedSelectableElementRejectsMissingFocusedElement() {
    let reader = SelectedTextReader(
        isTrusted: { true },
        focusedElementProvider: { nil },
        applicationFocusedElementProvider: { _ in nil }
    )

    XCTAssertFalse(reader.isFocusedSelectableTextElement(sourceProcessIdentifier: 42))
}

func testFocusedSelectableElementRejectsGenericNonTextValue() {
    let reader = SelectedTextReader(
        isTrusted: { true },
        focusedElementProvider: { SelectedTextElement(rawValue: "button") },
        focusedElementRoleProvider: { _ in "AXButton" },
        focusedElementValueProvider: { _ in "Play" },
        selectedTextRangeProvider: { _ in .failure(.unsupported) },
        selectedTextMarkerRangeProvider: { _ in .failure(.unsupported) }
    )

    XCTAssertFalse(reader.isFocusedSelectableTextElement())
}
```

Keep the existing positive tests for known text roles, selected-text ranges, and marker ranges.

- [ ] **Step 2: Run the reader suite to verify RED**

Run: `swift test --filter SelectedTextReaderTests`

Expected: the two new safety expectations fail because missing elements and generic values currently return `true`.

- [ ] **Step 3: Make the preflight conservative**

In `isFocusedSelectableTextElement`, return `false` for a missing element and remove the generic non-empty `AXValue` branch:

```swift
guard let focusedElement else {
    return false
}

if let roleValue = focusedElementRoleProvider(focusedElement),
   Self.selectableTextRoles.contains(roleValue) {
    return true
}

if case .success = selectedTextRangeProvider(focusedElement) {
    return true
}

if case .success = selectedTextMarkerRangeProvider(focusedElement) {
    return true
}

return false
```

Do not change the broader candidate-element traversal used after the preflight succeeds.

- [ ] **Step 4: Run the reader suite to verify GREEN**

Run: `swift test --filter SelectedTextReaderTests`

Expected: all reader tests pass.

- [ ] **Step 5: Commit the preflight fix**

```bash
git add Sources/InkletCore/SelectedTextReader.swift \
  Tests/InkletCoreTests/SelectedTextReaderTests.swift
git commit -m "Tighten selection text preflight"
```

### Task 3: Replace timestamp-only double-copy detection with a key-cycle policy

**Files:**
- Modify: `Sources/InkletCore/SelectionCopyTriggerPolicy.swift`
- Test: `Tests/InkletCoreTests/SelectionCopyTriggerPolicyTests.swift`

- [ ] **Step 1: Write the full failing gesture matrix**

Replace the three timestamp-only tests with executable key-cycle and clipboard tests:

```swift
func testTwoIndependentCopiesTriggerWithOriginalPasteboardCount() {
    var policy = SelectionCopyTriggerPolicy(doubleCopyInterval: 0.8)

    XCTAssertEqual(policy.recordKeyDown(
        at: 10,
        pasteboardChangeCount: 4,
        isRepeat: false,
        isInkletGenerated: false
    ), .armed)
    policy.recordKeyUp(isInkletGenerated: false)

    XCTAssertEqual(policy.recordKeyDown(
        at: 10.5,
        pasteboardChangeCount: 5,
        isRepeat: false,
        isInkletGenerated: false
    ), .triggered(initialPasteboardChangeCount: 4))
}

func testRepeatAndMissingKeyUpCannotTrigger() {
    var policy = SelectionCopyTriggerPolicy(doubleCopyInterval: 0.8)
    _ = policy.recordKeyDown(at: 10, pasteboardChangeCount: 4, isRepeat: false, isInkletGenerated: false)

    XCTAssertEqual(
        policy.recordKeyDown(at: 10.2, pasteboardChangeCount: 4, isRepeat: true, isInkletGenerated: false),
        .ignoredRepeat
    )
    XCTAssertEqual(
        policy.recordKeyDown(at: 10.4, pasteboardChangeCount: 4, isRepeat: false, isInkletGenerated: false),
        .awaitingKeyUp
    )
}

func testGeneratedEventsNeverArmOrReleaseGesture() {
    var policy = SelectionCopyTriggerPolicy(doubleCopyInterval: 0.8)

    XCTAssertEqual(
        policy.recordKeyDown(at: 10, pasteboardChangeCount: 4, isRepeat: false, isInkletGenerated: true),
        .ignoredGenerated
    )
    policy.recordKeyUp(isInkletGenerated: true)
    XCTAssertEqual(
        policy.recordKeyDown(at: 10.4, pasteboardChangeCount: 5, isRepeat: false, isInkletGenerated: false),
        .armed
    )
}

func testExpiredGestureRearmsAndResetClearsState() {
    var policy = SelectionCopyTriggerPolicy(doubleCopyInterval: 0.8)
    _ = policy.recordKeyDown(at: 10, pasteboardChangeCount: 4, isRepeat: false, isInkletGenerated: false)
    policy.recordKeyUp(isInkletGenerated: false)

    XCTAssertEqual(
        policy.recordKeyDown(at: 10.9, pasteboardChangeCount: 5, isRepeat: false, isInkletGenerated: false),
        .armed
    )
    policy.reset()
    policy.recordKeyUp(isInkletGenerated: false)
    XCTAssertEqual(
        policy.recordKeyDown(at: 11.1, pasteboardChangeCount: 6, isRepeat: false, isInkletGenerated: false),
        .armed
    )
}

func testClipboardValidationRequiresChangedCountAndNonEmptyText() {
    XCTAssertNil(SelectionCopyTriggerPolicy.validatedClipboardText(
        initialChangeCount: 4,
        currentChangeCount: 4,
        text: "stale"
    ))
    XCTAssertNil(SelectionCopyTriggerPolicy.validatedClipboardText(
        initialChangeCount: 4,
        currentChangeCount: 5,
        text: "  \n "
    ))
    XCTAssertEqual(SelectionCopyTriggerPolicy.validatedClipboardText(
        initialChangeCount: 4,
        currentChangeCount: 5,
        text: "  copied text  "
    ), "copied text")
}
```

Add a separate test proving a normal second key cycle after the interval arms a new gesture rather than triggering.

- [ ] **Step 2: Run the policy suite to verify RED**

Run: `swift test --filter SelectionCopyTriggerPolicyTests`

Expected: compilation fails because the key-cycle and validation APIs are absent.

- [ ] **Step 3: Implement the minimal pure policy**

Replace `recordCopy(at:)` with an explicit decision enum and key lifecycle APIs:

```swift
public enum SelectionCopyKeyDownDecision: Equatable, Sendable {
    case ignoredRepeat
    case ignoredGenerated
    case armed
    case awaitingKeyUp
    case triggered(initialPasteboardChangeCount: Int)
}

public struct SelectionCopyTriggerPolicy: Equatable, Sendable {
    private let doubleCopyInterval: TimeInterval
    private var firstCopyTime: TimeInterval?
    private var firstPasteboardChangeCount: Int?
    private var didReleaseCopyKey = false

    public mutating func recordKeyDown(
        at time: TimeInterval,
        pasteboardChangeCount: Int,
        isRepeat: Bool,
        isInkletGenerated: Bool
    ) -> SelectionCopyKeyDownDecision {
        guard !isInkletGenerated else { return .ignoredGenerated }
        guard !isRepeat else { return .ignoredRepeat }

        guard let firstCopyTime, let firstPasteboardChangeCount else {
            arm(at: time, pasteboardChangeCount: pasteboardChangeCount)
            return .armed
        }

        let elapsed = time - firstCopyTime
        guard elapsed >= 0, elapsed <= doubleCopyInterval else {
            arm(at: time, pasteboardChangeCount: pasteboardChangeCount)
            return .armed
        }

        guard didReleaseCopyKey else { return .awaitingKeyUp }

        reset()
        return .triggered(initialPasteboardChangeCount: firstPasteboardChangeCount)
    }

    public mutating func recordKeyUp(isInkletGenerated: Bool) {
        guard !isInkletGenerated, firstCopyTime != nil else { return }
        didReleaseCopyKey = true
    }

    public mutating func reset() {
        firstCopyTime = nil
        firstPasteboardChangeCount = nil
        didReleaseCopyKey = false
    }

    public static func validatedClipboardText(
        initialChangeCount: Int,
        currentChangeCount: Int,
        text: String?
    ) -> String? {
        guard currentChangeCount != initialChangeCount else { return nil }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
```

Implement `arm` as a private mutating helper that stores time/change count and clears `didReleaseCopyKey`.

- [ ] **Step 4: Run the policy suite to verify GREEN**

Run: `swift test --filter SelectionCopyTriggerPolicyTests`

Expected: all gesture and clipboard-validation tests pass.

- [ ] **Step 5: Commit the gesture policy**

```bash
git add Sources/InkletCore/SelectionCopyTriggerPolicy.swift \
  Tests/InkletCoreTests/SelectionCopyTriggerPolicyTests.swift
git commit -m "Harden double copy gesture detection"
```

### Task 4: Enforce opt-in and tag optional generated copy events

**Files:**
- Modify: `Sources/InkletCore/SelectionClipboardReader.swift`
- Test: `Tests/InkletCoreTests/SelectionClipboardReaderTests.swift`

- [ ] **Step 1: Write failing reader safety tests**

Add injected active-PID coverage and generated-event marker coverage:

```swift
@MainActor
func testShortcutCapableModeCannotSendShortcutWithoutExplicitPermission() async {
    let pasteboard = NSPasteboard.withUniqueName()
    var didSendShortcut = false
    let reader = SelectionClipboardReader(
        pasteboard: pasteboard,
        activeProcessIdentifierProvider: { 42 },
        copyMenuActionPerformer: { _ in .noMenuItem },
        copyShortcutSender: { _ in didSendShortcut = true },
        delayProvider: { _ in },
        shortcutReadWrapper: { operation in await operation() }
    )

    let result = await reader.readSelectedText(
        sourceProcessIdentifier: 42,
        forceSelectionMode: .menuCopyThenShortcut,
        allowsSimulatedCopyFallback: false
    )

    XCTAssertEqual(result, .unsupported)
    XCTAssertFalse(didSendShortcut)
}

@MainActor
func testExplicitPermissionUsesMenuThenShortcutForOriginalForegroundProcess() async {
    let pasteboard = NSPasteboard.withUniqueName()
    var didSendShortcut = false
    let reader = SelectionClipboardReader(
        pasteboard: pasteboard,
        activeProcessIdentifierProvider: { 42 },
        copyMenuActionPerformer: { _ in .noMenuItem },
        copyShortcutSender: { _ in
            didSendShortcut = true
            pasteboard.clearContents()
            pasteboard.setString("selection", forType: .string)
        },
        delayProvider: { _ in },
        shortcutReadWrapper: { operation in await operation() }
    )

    let result = await reader.readSelectedText(
        sourceProcessIdentifier: 42,
        forceSelectionMode: .menuCopyOnly,
        allowsSimulatedCopyFallback: true
    )

    XCTAssertEqual(result, .success("selection"))
    XCTAssertTrue(didSendShortcut)
}

@MainActor
func testAppSwitchPreventsOptionalShortcut() async {
    var didSendShortcut = false
    let reader = SelectionClipboardReader(
        activeProcessIdentifierProvider: { 99 },
        copyMenuActionPerformer: { _ in .noMenuItem },
        copyShortcutSender: { _ in didSendShortcut = true },
        delayProvider: { _ in },
        shortcutReadWrapper: { operation in await operation() }
    )

    let result = await reader.readSelectedText(
        sourceProcessIdentifier: 42,
        forceSelectionMode: .menuCopyOnly,
        allowsSimulatedCopyFallback: true
    )

    XCTAssertEqual(result, .unsupported)
    XCTAssertFalse(didSendShortcut)
}

func testGeneratedCopyEventsCarryInkletMarker() throws {
    let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
    let events = try SelectionClipboardReader.makeCopyShortcutEvents(eventSource: source)

    XCTAssertEqual(
        events.keyDown.getIntegerValueField(.eventSourceUserData),
        SelectionClipboardReader.generatedCopyEventUserData
    )
    XCTAssertEqual(
        events.keyUp.getIntegerValueField(.eventSourceUserData),
        SelectionClipboardReader.generatedCopyEventUserData
    )
}
```

Update existing shortcut-fallback tests to pass `allowsSimulatedCopyFallback: true`; keep menu-only and clipboard-restoration assertions unchanged.

- [ ] **Step 2: Run reader tests to verify RED**

Run: `swift test --filter SelectionClipboardReaderTests`

Expected: compilation fails on the missing permission, PID provider, marker, and event factory.

- [ ] **Step 3: Add opt-in, PID revalidation, and marked events**

Add:

```swift
public static let generatedCopyEventUserData: Int64 = 0x494E4B4C45544350
public typealias ActiveProcessIdentifierProvider = @MainActor () -> pid_t?
```

Inject the provider with the production default:

```swift
activeProcessIdentifierProvider: @escaping ActiveProcessIdentifierProvider = {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
}
```

Add `allowsSimulatedCopyFallback: Bool = false` to `readSelectedText`. For every non-disabled mode, try menu copy first; only fall back to `readSelectedTextByShortcut(sourceProcessIdentifier:)` when permission is true and the menu item is unavailable. Do not preserve shortcut-first execution.

Use one normalized switch at the public boundary:

```swift
guard forceSelectionMode != .disabled else {
    return .unsupported
}

return await readSelectedTextByMenuAction(
    sourceProcessIdentifier: sourceProcessIdentifier,
    fallbackToShortcut: allowsSimulatedCopyFallback
)
```

Immediately before constructing/posting the optional shortcut, require:

```swift
guard activeProcessIdentifierProvider() == sourceProcessIdentifier else {
    return .unsupported
}
```

Extract event construction:

```swift
static func makeCopyShortcutEvents(
    eventSource: CGEventSource
) throws -> (keyDown: CGEvent, keyUp: CGEvent) {
    guard let keyDown = CGEvent(
        keyboardEventSource: eventSource,
        virtualKey: 0x08,
        keyDown: true
    ), let keyUp = CGEvent(
        keyboardEventSource: eventSource,
        virtualKey: 0x08,
        keyDown: false
    ) else {
        throw SelectionClipboardReaderError.cannotCreateCopyEvent
    }

    for event in [keyDown, keyUp] {
        event.flags = .maskCommand
        event.setIntegerValueField(
            .eventSourceUserData,
            value: generatedCopyEventUserData
        )
    }
    return (keyDown, keyUp)
}
```

Have `systemSendCopyShortcut` post exactly those marked events at `.cghidEventTap`.

- [ ] **Step 4: Run reader tests to verify GREEN**

Run: `swift test --filter SelectionClipboardReaderTests`

Expected: all tests pass, including unchanged clipboard restoration tests.

- [ ] **Step 5: Commit safe generated-event handling**

```bash
git add Sources/InkletCore/SelectionClipboardReader.swift \
  Tests/InkletCoreTests/SelectionClipboardReaderTests.swift
git commit -m "Guard simulated selection copy events"
```

### Task 5: Wire genuine double-copy events and content-free diagnostics

**Files:**
- Modify: `Sources/InkletApp/SelectionActionMonitor.swift`
- Modify: `Sources/InkletApp/SelectionActionDiagnostics.swift`
- Modify: `Sources/InkletApp/AppCoordinator.swift`
- Create: `Tests/InkletCoreTests/SelectionActionMonitorSourceTests.swift`
- Modify: `Tests/InkletCoreTests/AppCoordinatorSourceTests.swift`

- [ ] **Step 1: Add failing source-wiring tests**

Create `SelectionActionMonitorSourceTests` that scopes the monitor and diagnostics sources and asserts:

```swift
XCTAssertTrue(monitorSource.contains("matching: [.keyUp]"))
XCTAssertTrue(monitorSource.contains("event.keyCode == 8"))
XCTAssertTrue(monitorSource.contains("event.isARepeat"))
XCTAssertTrue(monitorSource.contains("NSEvent.mouseLocation"))
XCTAssertTrue(monitorSource.contains(".eventSourceUserData"))
XCTAssertTrue(monitorSource.contains(".eventSourceUnixProcessID"))
XCTAssertTrue(monitorSource.contains("SelectionClipboardReader.generatedCopyEventUserData"))
XCTAssertTrue(monitorSource.contains("copyTriggerPolicy.recordKeyUp"))
XCTAssertTrue(monitorSource.contains("copyTriggerPolicy.reset()"))
XCTAssertFalse(monitorSource.contains("event.characters"))
XCTAssertFalse(diagnosticsSource.contains("NSPasteboard.general.string"))
```

Add `AppCoordinatorSourceTests` assertions that automatic reads pass `allowsSimulatedCopyFallback`, and manual triggers call `validatedClipboardText` with both initial/current change counts before `showMenu`.

- [ ] **Step 2: Run source tests to verify RED**

Run:

```bash
swift test --filter SelectionActionMonitorSourceTests
swift test --filter AppCoordinatorSourceTests
```

Expected: the new wiring assertions fail because the monitor only has a timestamp-based key-down path.

- [ ] **Step 3: Route key lifecycle and provenance through the policy**

Change the callback to carry the first pasteboard count and source PID:

```swift
var onCopyTrigger: ((SelectionPoint, Int, pid_t) -> Void)?
```

For key-down events, compute:

```swift
let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
let cgEvent = event.cgEvent
let marker = cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
let sourcePID = pid_t(cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1)
let isInkletGenerated = marker == SelectionClipboardReader.generatedCopyEventUserData
```

Only key code 8 with exactly Command is a qualifying down event. Log C-key events with other modifier states as `ignoredModifiers`. Pass `event.isARepeat`, the current `NSPasteboard.general.changeCount`, and provenance to `recordKeyDown`, then exhaustively handle its decision:

```swift
let decision = copyTriggerPolicy.recordKeyDown(
    at: Date().timeIntervalSinceReferenceDate,
    pasteboardChangeCount: NSPasteboard.general.changeCount,
    isRepeat: event.isARepeat,
    isInkletGenerated: isInkletGenerated
)

switch decision {
case .ignoredRepeat:
    logCopyEvent(event, marker: marker, sourcePID: sourcePID, decision: "ignoredRepeat")
case .ignoredGenerated:
    logCopyEvent(event, marker: marker, sourcePID: sourcePID, decision: "ignoredGenerated")
case .armed:
    logCopyEvent(event, marker: marker, sourcePID: sourcePID, decision: "armed")
case .awaitingKeyUp:
    logCopyEvent(event, marker: marker, sourcePID: sourcePID, decision: "awaitingKeyUp")
case .triggered(let initialPasteboardChangeCount):
    logCopyEvent(event, marker: marker, sourcePID: sourcePID, decision: "triggered")
    guard let sourceApp = NSWorkspace.shared.frontmostApplication,
          sourceApp.processIdentifier != NSRunningApplication.current.processIdentifier
    else { return }
    onCopyTrigger?(
        SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y),
        initialPasteboardChangeCount,
        sourceApp.processIdentifier
    )
}
```

For key-up, keep the existing Shift-selection behavior and additionally pass every C-key release (`keyCode == 8`) to `recordKeyUp`; do not require Command to still appear in key-up flags. Generated key-up events remain ignored by policy.

Call `copyTriggerPolicy.reset()` from `stop()`.

- [ ] **Step 4: Add rate-limited metadata diagnostics**

In `SelectionActionDiagnostics`, add a main-actor copy-event logger that formats only bundle/PID, key code, numeric modifier raw value, repeat status, source PID, marker, and decision. Keep the last signature/time and suppress identical entries for one second; when a new signature arrives, append a `suppressed=<count>` summary before clearing the count:

```swift
@MainActor
enum SelectionActionDiagnostics {
    private static var lastCopySignature: String?
    private static var lastCopyLogTime: TimeInterval?
    private static var suppressedCopyEventCount = 0

    static func logCopyEvent(
        foregroundApp: String,
        keyCode: UInt16,
        modifiers: UInt,
        isRepeat: Bool,
        sourcePID: Int64,
        marker: Int64,
        decision: String,
        at time: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) {
        let signature = "app=\(foregroundApp) keyCode=\(keyCode) modifiers=\(modifiers) repeat=\(isRepeat) sourcePID=\(sourcePID) marker=\(marker) decision=\(decision)"
        if signature == lastCopySignature,
           let lastCopyLogTime,
           time - lastCopyLogTime < 1 {
            suppressedCopyEventCount += 1
            return
        }

        if suppressedCopyEventCount > 0 {
            log("copy event suppressed=\(suppressedCopyEventCount)")
        }
        log("copy event \(signature)")
        lastCopySignature = signature
        lastCopyLogTime = time
        suppressedCopyEventCount = 0
    }

    static func resetCopyEventAggregation() {
        lastCopySignature = nil
        lastCopyLogTime = nil
        suppressedCopyEventCount = 0
    }
}
```

Use fixed decision strings: `ignoredModifiers`, `ignoredRepeat`, `ignoredGenerated`, `armed`, `awaitingKeyUp`, and `triggered`. Never interpolate `event.characters`, selected text, pasteboard text, or clipboard contents.

Add `resetCopyEventAggregation()` and call it from monitor `stop()`.

- [ ] **Step 5: Validate manual clipboard state and source app in AppCoordinator**

Wire the new callback:

```swift
self.selectionActionMonitor.onCopyTrigger = { [weak self] point, initialChangeCount, sourcePID in
    Task { @MainActor in
        self?.handleSelectionActionCopyTrigger(
            at: point,
            initialPasteboardChangeCount: initialChangeCount,
            sourceProcessIdentifier: sourcePID
        )
    }
}
```

After the existing 120 ms delay, require the same frontmost PID and validate:

```swift
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourceProcessIdentifier else {
    SelectionActionDiagnostics.log("copy trigger source changed")
    return
}
let pasteboard = NSPasteboard.general
guard let text = SelectionCopyTriggerPolicy.validatedClipboardText(
    initialChangeCount: initialPasteboardChangeCount,
    currentChangeCount: pasteboard.changeCount,
    text: pasteboard.string(forType: .string)
) else {
    SelectionActionDiagnostics.log("copy trigger clipboard unchanged or empty")
    return
}
```

In `readSelectedTextForAutomaticSelection`, pass both `forceSelectionMode` and `allowsSimulatedCopyFallback` to the clipboard reader.

- [ ] **Step 6: Run focused wiring and policy tests to verify GREEN**

Run:

```bash
swift test --filter SelectionActionMonitorSourceTests
swift test --filter AppCoordinatorSourceTests
swift test --filter SelectionCopyTriggerPolicyTests
swift build
```

Expected: all tests and the app build pass.

- [ ] **Step 7: Commit monitor and coordinator wiring**

```bash
git add Sources/InkletApp/SelectionActionMonitor.swift \
  Sources/InkletApp/SelectionActionDiagnostics.swift \
  Sources/InkletApp/AppCoordinator.swift \
  Tests/InkletCoreTests/SelectionActionMonitorSourceTests.swift \
  Tests/InkletCoreTests/AppCoordinatorSourceTests.swift
git commit -m "Ignore synthetic selection copy feedback"
```

### Task 6: Expose the safe settings UI in every language

**Files:**
- Modify: `Sources/InkletApp/SettingsView.swift`
- Modify: `Sources/InkletApp/InkletLocalization.swift`
- Modify: `Tests/InkletCoreTests/SettingsViewSourceTests.swift`
- Modify: `Tests/InkletCoreTests/VoiceSettingsLocalizationTests.swift`

- [ ] **Step 1: Write failing settings and localization assertions**

Add a scoped source test:

```swift
func testSelectionActionsExposeOnlySafeForceSelectionAndAdvancedOptIn() throws {
    let source = try settingsViewSource()
    let panel = try selectionActionsPanelBlock(in: source)

    XCTAssertTrue(panel.contains("SelectionForceSelectionMode.settingsCases"))
    XCTAssertTrue(panel.contains("$model.config.selectionActions.allowsSimulatedCopyFallback"))
    XCTAssertTrue(panel.contains("settings.row.allowSimulatedCopyFallback"))
    XCTAssertTrue(panel.contains("settings.help.allowSimulatedCopyFallback"))
    XCTAssertFalse(panel.contains("SelectionForceSelectionMode.allCases"))
}
```

Extend localization coverage to require the two new keys in all ten language tables and assert that the English and Simplified Chinese help strings mention both `Cmd+C` and games.

- [ ] **Step 2: Run settings tests to verify RED**

Run:

```bash
swift test --filter SettingsViewSourceTests
swift test --filter VoiceSettingsLocalizationTests
```

Expected: failures for absent keys/toggle and unsafe `allCases` picker use.

- [ ] **Step 3: Add the compact advanced toggle**

Change the picker to:

```swift
ForEach(SelectionForceSelectionMode.settingsCases) { mode in
    Text(mode.localizedDisplayName).tag(mode)
}
```

Immediately below Force Selection, add:

```swift
settingsRow(
    L10n.text("settings.row.allowSimulatedCopyFallback"),
    help: L10n.text("settings.help.allowSimulatedCopyFallback")
) {
    Toggle("", isOn: $model.config.selectionActions.allowsSimulatedCopyFallback)
        .labelsHidden()
        .disabled(model.config.selectionActions.forceSelectionMode == .disabled)
}
```

Keep the row visible but disabled when Force Selection is off so the risk control does not appear/disappear and shift the settings layout.

- [ ] **Step 4: Localize the setting and revise Force Selection help**

Add these semantic equivalents to every table:

```text
English: Allow Simulated Cmd+C / Sends Cmd+C to the foreground app when Menu Copy is unavailable. This may interfere with games or remote apps.
简体中文: 允许模拟 Cmd+C / 菜单复制不可用时向前台 App 发送 Cmd+C，可能会干扰游戏或远程应用。
繁體中文: 允許模擬 Cmd+C / 選單複製無法使用時向前景 App 傳送 Cmd+C，可能會干擾遊戲或遠端 App。
日本語: Cmd+C のシミュレーションを許可 / メニューコピーを使えない場合、前面のアプリに Cmd+C を送信します。ゲームやリモートアプリに干渉する可能性があります。
한국어: Cmd+C 시뮬레이션 허용 / 메뉴 복사를 사용할 수 없을 때 전면 앱에 Cmd+C를 보냅니다. 게임이나 원격 앱을 방해할 수 있습니다.
Español: Permitir Cmd+C simulado / Envía Cmd+C a la app en primer plano si Copiar desde el menú no está disponible. Puede interferir con juegos o apps remotas.
Français: Autoriser la simulation de Cmd+C / Envoie Cmd+C à l’app au premier plan si la copie par menu est indisponible. Cela peut perturber les jeux ou apps distantes.
Deutsch: Simuliertes Cmd+C erlauben / Sendet Cmd+C an die Vordergrund-App, wenn Menükopie nicht verfügbar ist. Dies kann Spiele oder Remote-Apps stören.
Português: Permitir Cmd+C simulado / Envia Cmd+C ao app em primeiro plano quando a cópia pelo menu não está disponível. Pode interferir em jogos ou apps remotos.
Italiano: Consenti Cmd+C simulato / Invia Cmd+C all’app in primo piano quando Copia dal menu non è disponibile. Può interferire con giochi o app remote.
```

Revise each `settings.help.forceSelectionMode` translation to describe only safe menu-copy fallback; keep legacy mode display-name keys for decoding/localization compatibility even though the picker no longer shows them.

- [ ] **Step 5: Run settings/localization tests and build**

Run:

```bash
swift test --filter SettingsViewSourceTests
swift test --filter VoiceSettingsLocalizationTests
swift build
```

Expected: tests and build pass; both English and Chinese labels fit the existing 320-point control column without adding a new layout motif.

- [ ] **Step 6: Commit settings and localization**

```bash
git add Sources/InkletApp/SettingsView.swift \
  Sources/InkletApp/InkletLocalization.swift \
  Tests/InkletCoreTests/SettingsViewSourceTests.swift \
  Tests/InkletCoreTests/VoiceSettingsLocalizationTests.swift
git commit -m "Add safe simulated copy setting"
```

### Task 7: Update public behavior, privacy, and manual QA

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/privacy-policy.md`
- Modify: `docs/manual-test-checklist.md`

- [ ] **Step 1: Update English and Chinese feature documentation symmetrically**

Change Selection Actions text to say:

- Accessibility, supported-browser JavaScript, and Menu Copy are the automatic defaults.
- Simulated `Command+C` is an advanced explicit opt-in delivered to the foreground app.
- It may interfere with games, remote desktops, or virtual machines.
- Deliberately pressing `Command+C` twice remains the manual fallback.
- A single copy never invokes Inklet.

Remove the current unqualified statement that the configured automatic fallback may invoke `Command+C`.

- [ ] **Step 2: Update privacy disclosure**

In `docs/privacy-policy.md`, state that event diagnostics may record timestamp, app identifier/PID, key code, modifier bits, repeat/provenance metadata, and decisions, but never typed characters, selected text, or clipboard contents. State that simulated copy is off by default and, when enabled, posts to the foreground app.

- [ ] **Step 3: Extend the manual checklist**

Add explicit cases under Selection Actions:

```markdown
- Leave simulated Cmd+C fallback off, play a full-screen game, and confirm mouse/keyboard gameplay never receives an Inklet-generated copy shortcut.
- Confirm one Cmd+C copies normally; two deliberate independent Cmd+C presses open Selection Actions; holding Cmd+C does not trigger it.
- With simulated fallback off, verify TextEdit, Notes, Mail, Safari, Chrome, Edge, Terminal, and one standard editor still read selections through safe paths.
- Turn the advanced fallback on, verify the warning is visible, and confirm switching apps during a pending read never sends Cmd+C to the newly active app.
- Inspect the local diagnostic log and confirm it contains event metadata/decisions but no selected text, clipboard text, or typed characters, and repeated ignored events are rate-limited.
```

- [ ] **Step 4: Check doc consistency**

Run:

```bash
rg -n "Force Selection|强制取词|Command\+C|Cmd\+C|simulated|模拟" \
  README.md README.zh-CN.md docs/privacy-policy.md docs/manual-test-checklist.md
git diff --check
```

Expected: every automatic simulated-copy statement includes the explicit opt-in/risk context; no whitespace errors.

- [ ] **Step 5: Commit documentation**

```bash
git add README.md README.zh-CN.md docs/privacy-policy.md docs/manual-test-checklist.md
git commit -m "Document safe selection copy behavior"
```

### Task 8: Full verification and local app hand-test

**Files:**
- Review all files changed since commit `65ce7ce`

- [ ] **Step 1: Run all automated tests**

Run: `swift test`

Expected: all XCTest and Swift Testing suites pass with zero failures.

- [ ] **Step 2: Run strict build**

Run:

```bash
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: build completes with no warnings or errors.

- [ ] **Step 3: Install and launch the stable local bundle**

Run: `scripts/run-local-app.sh`

Expected: `/Applications/Inklet Local.app` is rebuilt, installed with the stable local signing identity, and launched without resetting Accessibility or Keychain trust.

- [ ] **Step 4: Perform non-game manual checks immediately available**

Verify:

- Settings shows only Off/Menu Copy and the disabled/enabled advanced toggle in English and Chinese without overlap.
- Single `Command+C` does not show Inklet.
- Two deliberate copies show Selection Actions with the newly copied text.
- Holding `Command+C` does not show Inklet.
- Text selection in at least TextEdit and one supported browser still works with the advanced option off.
- Switching apps during the 120 ms manual-copy settle period does not show stale content.

Record Dota 2 gameplay verification as pending if the game is not running; do not claim it was manually verified without performing it.

- [ ] **Step 5: Inspect logs and final diff**

Run:

```bash
tail -200 "/Users/tom/Library/Containers/com.tomwan.inklet.local/Data/tmp/InkletSelectionActions.log"
git diff 65ce7ce...HEAD --check
git status --short
git log --oneline 65ce7ce..HEAD
```

Expected: diagnostics contain metadata/decisions and no user text; diff check and status are clean; commits correspond one-to-one with the tasks above.

- [ ] **Step 6: Report verified and unverified areas**

Summarize automated counts, strict-build result, local-bundle result, completed manual cases, and any deferred Dota 2 verification. Do not make a broader safety claim than the executed checks support.
