# Writing Mode Picker Enter Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let plain Return and keypad Enter commit the highlighted writing mode just like Tab, while preserving modifier and IME behavior and showing both shortcuts in the picker.

**Architecture:** Keep key interpretation in the existing pure `WritingPopoverKeyboardPolicy` and route successful commits through the existing `commitHighlightedMode()` boundary. Keep presentation changes inside `WritingModePickerView`; update public docs and manual QA so they describe the shipped behavior.

**Tech Stack:** Swift, AppKit, SwiftUI, XCTest, Swift Package Manager.

---

### Task 1: Route plain Return to the highlighted mode

**Files:**
- Modify: `Tests/InkletCoreTests/WritingPopoverKeyboardPolicyTests.swift`
- Modify: `Sources/InkletCore/WritingPopoverKeyboardPolicy.swift`

- [ ] **Step 1: Write the failing policy tests**

Replace the current no-op Return test with explicit plain/modifier coverage and extend the no-result test:

```swift
func testPickerPlainReturnKeysCommitHighlightedMode() {
    for keyCode: UInt16 in [36, 76] {
        XCTAssertEqual(action(route: .modePicker, keyCode: keyCode), .commitMode)
    }
}

func testPickerModifiedReturnKeysAreConsumedWithoutCommitting() {
    let modifiers: [WritingPopoverKeyboardModifiers] = [
        .command, .shift, .option, .control,
        [.command, .shift, .option, .control]
    ]

    for keyCode: UInt16 in [36, 76] {
        for modifierSet in modifiers {
            XCTAssertEqual(
                action(route: .modePicker, keyCode: keyCode, modifiers: modifierSet),
                .consume
            )
        }
    }
}
```

Change the no-result assertion to cover Tab and both Return codes:

```swift
for keyCode: UInt16 in [48, 36, 76] {
    XCTAssertEqual(action(route: .modePicker, keyCode: keyCode), .commitMode)
}
```

- [ ] **Step 2: Run the policy tests and verify RED**

Run:

```bash
swift test --filter WritingPopoverKeyboardPolicyTests
```

Expected: the two plain Return assertions fail because the current policy returns `.consume`; IME, modifier, editor, and Tab assertions continue to pass.

- [ ] **Step 3: Implement the smallest policy change**

In the mode-picker branch of `WritingPopoverKeyboardPolicy.action`, replace the unconditional Return consumption with:

```swift
if isReturnKey {
    return modifiers.isEmpty ? .commitMode : .consume
}
```

Leave the existing composition guard before this branch so marked-text Return remains `.passThrough`.

- [ ] **Step 4: Run the policy tests and verify GREEN**

Run:

```bash
swift test --filter WritingPopoverKeyboardPolicyTests
```

Expected: all policy tests pass, including main Return, keypad Enter, modifiers, IME composition, Tab, and no-result behavior.

### Task 2: Show Return and Tab in both picker hints

**Files:**
- Modify: `Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift`
- Modify: `Sources/InkletApp/WritingModePickerView.swift`

- [ ] **Step 1: Write the failing source regression**

Extend `testPickerExposesLocalizedNavigationAndAccessibleSettings` with:

```swift
XCTAssertTrue(source.contains("Keycap(title: \"↵\", compact: true)"))
XCTAssertTrue(source.contains("footerHint(keys: [\"↵\", \"tab\"]"))
XCTAssertTrue(source.contains("ForEach(keys, id: \\.self) { key in"))
```

- [ ] **Step 2: Run the launcher source tests and verify RED**

Run:

```bash
swift test --filter WritingModeLauncherSourceTests
```

Expected: the new assertions fail because the highlighted row and footer currently show only Tab and `footerHint` accepts one key.

- [ ] **Step 3: Add the two visible hints**

In the highlighted-row hint, render both keys before the Write label:

```swift
Keycap(title: "↵", compact: true)
Keycap(title: "tab", compact: true)
```

Change the footer calls to:

```swift
footerHint(keys: ["↵", "tab"], label: L10n.text("popover.modeSearch.write"))
Spacer()
footerHint(keys: ["esc"], label: L10n.text("popover.hint.close"))
```

Change the helper signature and key rendering to:

```swift
private func footerHint(keys: [String], label: String) -> some View {
    HStack(spacing: 4) {
        ForEach(keys, id: \.self) { key in
            Keycap(title: key, compact: true)
        }
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(InkletTheme.textSecondary)
            .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
}
```

- [ ] **Step 4: Run the launcher source tests and verify GREEN**

Run:

```bash
swift test --filter WritingModeLauncherSourceTests
```

Expected: all launcher source tests pass.

### Task 3: Update shipped behavior documentation

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/manual-test-checklist.md`

- [ ] **Step 1: Replace stale Return behavior**

Update the English keyboard flow to say plain Return or keypad Enter commits the highlighted mode like Tab, modified Return does not commit, and active IME composition retains Return. Make the symmetric Chinese change.

Update both quick-start step 3 entries from Tab-only to `Tab` or `Enter`.

- [ ] **Step 2: Expand manual QA**

Replace the obsolete Return no-op check with checks for main Return, keypad Enter, modified Return, and Chinese IME candidate confirmation. Extend the no-matches case so Tab, Return, and keypad Enter all remain in the launcher.

- [ ] **Step 3: Check documentation consistency**

Run:

```bash
rg -n "Return.*no launcher action|Return.*不执行任何启动器操作|press `Tab` to commit|按 `Tab` 确认" README.md README.zh-CN.md docs/manual-test-checklist.md
git diff --check
```

Expected: no stale Return no-op or Tab-only quick-start claims; diff check exits successfully.

### Task 4: Verify and commit the feature

**Files:**
- Verify all modified production, test, and documentation files.

- [ ] **Step 1: Run the complete test suite**

```bash
swift test
```

Expected: every XCTest and Swift Testing test passes.

- [ ] **Step 2: Run the strict build**

```bash
swift build -Xswiftc -warnings-as-errors
```

Expected: build succeeds with no warnings.

- [ ] **Step 3: Install and manually verify the stable local app**

```bash
scripts/run-local-app.sh
```

In `/Applications/Inklet Local.app`, verify plain Return and keypad Enter enter the highlighted mode, Tab remains supported, modifier+Return stays in the picker, a no-result query stays in the picker, and Chinese IME Return confirms the candidate before a subsequent Return enters the selected mode.

- [ ] **Step 4: Review and commit**

```bash
git diff --check
git status --short
git diff
git add Sources/InkletCore/WritingPopoverKeyboardPolicy.swift \
  Sources/InkletApp/WritingModePickerView.swift \
  Tests/InkletCoreTests/WritingPopoverKeyboardPolicyTests.swift \
  Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift \
  README.md README.zh-CN.md docs/manual-test-checklist.md
git diff --cached --check
git diff --cached
git commit -m "Add Enter navigation to writing mode picker"
```

Expected: the commit contains only the policy, picker UI, focused tests, and synchronized docs.
