# Writing Dictation Caret Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the newest realtime-dictation caret line visible when the editable Writing draft exceeds its bounded viewport.

**Architecture:** Preserve the existing two-to-seven-row popover sizing and native scroll container. Add the visibility request at the transaction boundary immediately after the dictation replacement moves the caret, so provisional and final dictation follow the insertion point without affecting ordinary model refreshes, manual scrolling, IME, cancellation, or undo behavior.

**Tech Stack:** Swift 6, AppKit `NSTextView`/`NSScrollView`, XCTest, Swift Package Manager, macOS app-bundle scripts.

---

### Task 1: Reproduce and repair dictated-caret visibility

**Files:**
- Modify: `Tests/InkletCoreTests/DictationEditorTransactionTests.swift:26-80,479-497`
- Modify: `Sources/InkletApp/DictationEditorTransaction.swift:302-326`

- [ ] **Step 1: Add the failing AppKit visibility regression**

Add this test near the existing provisional-replacement tests:

```swift
func testLongProvisionalReplacementKeepsCaretLineVisible() throws {
    let fixture = makeScrollableTextView()
    let textView = fixture.textView
    let subject = try XCTUnwrap(makeTransaction(textView))
    let draft = Array(
        repeating: "今天中午吃什么？ What should I eat?",
        count: 24
    ).joined(separator: "\n")

    try subject.replaceProvisional(with: draft)

    let layoutManager = try XCTUnwrap(textView.layoutManager)
    let textContainer = try XCTUnwrap(textView.textContainer)
    layoutManager.ensureLayout(for: textContainer)

    let lastCharacterRange = NSRange(
        location: (textView.string as NSString).length - 1,
        length: 1
    )
    let glyphRange = layoutManager.glyphRange(
        forCharacterRange: lastCharacterRange,
        actualCharacterRange: nil
    )
    let caretLineRect = layoutManager.lineFragmentRect(
        forGlyphAt: glyphRange.location,
        effectiveRange: nil
    )

    XCTAssertTrue(
        NSContainsRect(textView.visibleRect, caretLineRect),
        "The editor must scroll the inserted caret line into view"
    )
}
```

Add this fixture beside the existing `makeTextView` helper:

```swift
private func makeScrollableTextView() -> (
    scrollView: NSScrollView,
    textView: TestTextView
) {
    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 160, height: 40)
    )
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false

    let textView = TestTextView(
        frame: NSRect(
            x: 0,
            y: 0,
            width: scrollView.contentSize.width,
            height: scrollView.contentSize.height
        )
    )
    textView.font = .systemFont(ofSize: 14)
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
        width: scrollView.contentSize.width,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.minSize = .zero
    textView.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.allowsUndo = true
    textView.testUndoManager.groupsByEvent = false
    textView.string = ""
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.testUndoManager.removeAllActions()

    scrollView.documentView = textView
    return (scrollView, textView)
}
```

- [ ] **Step 2: Run the regression and verify RED**

Run:

```bash
swift test --filter DictationEditorTransactionTests/testLongProvisionalReplacementKeepsCaretLineVisible
```

Expected: FAIL at `NSContainsRect` with `The editor must scroll the inserted caret line into view`. The text replacement and layout must succeed; a compile error or missing layout object is not the expected RED result.

- [ ] **Step 3: Add the minimal visibility request**

In `replaceOwnedRange`, retain the computed collapsed caret range and scroll that same range into view:

```swift
ownedRange.length = (replacement as NSString).length
let caretRange = NSRange(location: NSMaxRange(ownedRange), length: 0)
textView.setSelectedRange(caretRange)
textView.scrollRangeToVisible(caretRange)
```

Do not change the editor height policy, scroll indicators, text measurement, transaction locking, underlining, cancellation, or undo registration.

- [ ] **Step 4: Verify GREEN and the complete transaction suite**

Run:

```bash
swift test --filter DictationEditorTransactionTests/testLongProvisionalReplacementKeepsCaretLineVisible
swift test --filter DictationEditorTransactionTests
```

Expected: the focused regression passes and every `DictationEditorTransactionTests` case passes with zero failures.

- [ ] **Step 5: Review and commit the focused repair**

Run:

```bash
git diff --check
git diff -- Sources/InkletApp/DictationEditorTransaction.swift Tests/InkletCoreTests/DictationEditorTransactionTests.swift
git add Sources/InkletApp/DictationEditorTransaction.swift Tests/InkletCoreTests/DictationEditorTransactionTests.swift
git diff --cached --check
git commit -m "Keep dictated caret visible"
```

Expected: the commit contains only the real AppKit regression, its fixture, and the transaction's caret visibility request.

### Task 2: Run complete code and distribution verification

**Files:**
- Verify: `Sources/InkletApp/DictationEditorTransaction.swift`
- Verify: `Tests/InkletCoreTests/DictationEditorTransactionTests.swift`
- Verify: `scripts/test-run-local-app.sh`
- Verify: `scripts/test-direct-distribution.sh`

- [ ] **Step 1: Run the complete debug test suite**

Run:

```bash
swift test
```

Expected: all XCTest and Swift Testing tests pass with zero failures.

- [ ] **Step 2: Run the complete release test suite**

Run:

```bash
swift test -c release
```

Expected: all XCTest and Swift Testing tests pass with zero failures.

- [ ] **Step 3: Run strict debug and release builds**

Run:

```bash
swift build -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
```

Expected: both builds exit successfully with no Swift warnings.

- [ ] **Step 4: Run the local-runner and distribution script checks**

Run:

```bash
bash scripts/test-run-local-app.sh
bash scripts/test-direct-distribution.sh
```

Expected: the runner suite prints `run-local-app.sh checks passed.` and the distribution suite prints `Direct distribution checks passed.`

- [ ] **Step 5: Confirm the verified tree remains clean**

Run:

```bash
git diff --check
git status --short --branch
```

Expected: no uncommitted files and branch `codex/voice-writing-integration` remains checked out.

### Task 3: Version, install, and launch the repaired app

**Files:**
- Modify: `VERSION`

- [ ] **Step 1: Increment the version before bundle creation**

Change `VERSION` to exactly:

```dotenv
INKLET_VERSION=1.1.5
INKLET_BUILD_NUMBER=11
```

- [ ] **Step 2: Review and commit the version change**

Run:

```bash
git diff --check
git diff -- VERSION
git add VERSION
git diff --cached --check
git commit -m "Bump Inklet version to 1.1.5"
```

Expected: the commit changes only `1.1.4 (10)` to `1.1.5 (11)`.

- [ ] **Step 3: Build, sign, install, and launch the stable local bundle**

Run only:

```bash
scripts/run-local-app.sh
```

Expected: the script stops the prior `Inklet Local` process, builds the release executable, signs and verifies the bundle with the configured stable identity, installs `/Applications/Inklet Local.app`, and launches it successfully.

- [ ] **Step 4: Verify the installed artifact and repository state**

Run:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '/Applications/Inklet Local.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '/Applications/Inklet Local.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '/Applications/Inklet Local.app/Contents/Info.plist'
codesign --verify --deep --strict '/Applications/Inklet Local.app'
pgrep -fl '^/Applications/Inklet Local\.app/Contents/MacOS/Inklet Local$'
git diff --check
git status --short --branch
```

Expected: bundle ID `com.tomwan.inklet.local`, version `1.1.5`, build `11`, a valid signature, exactly one running process from the installed path, and a clean worktree.

- [ ] **Step 5: Hand off physical long-dictation QA**

Ask the user to open Writing Assistant, focus the editable source draft, hold physical Right Option, and dictate until the source exceeds the visible viewport. Expected: the newest provisional text remains visible immediately above the fixed action bar, release keeps the final caret visible, and the draft becomes editable without changing the action bar or showing a new scrollbar.
