# Integrate Writing Mode Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate the existing searchable writing mode picker into current `main` without regressing migration, selection safety, provider requests, or the complete removal of temperature settings.

**Architecture:** Preserve the picker branch's launcher/session-state architecture, then merge current `main` into that branch so Git retains both histories. Resolve documentation conflicts deliberately and audit Swift auto-merges at the two popover integration seams. Treat the existing picker tests as the acceptance contract and add a focused regression test before any behavior fix exposed by the integration.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Package Manager, XCTest, Swift Testing, Git worktrees

---

### Task 1: Merge current main into the isolated picker branch

**Files:**
- Modify: `CONTRIBUTING.md`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/manual-test-checklist.md`
- Audit: `Sources/InkletApp/InkletLocalization.swift`
- Audit: `Sources/InkletApp/InkletPopoverView.swift`
- Audit: `Sources/InkletApp/InkletPopoverWindowController.swift`

- [ ] Confirm both `main` and `codex/raycast-writing-mode-picker` worktrees are clean and record their heads.
- [ ] Run `git merge --no-commit main` in `.worktrees/raycast-writing-mode-picker`.
- [ ] Resolve `CONTRIBUTING.md` by retaining the current stable local-runner and distribution workflow from `main`.
- [ ] Resolve both READMEs by retaining current installation, migration, selection-safety, privacy, provider, and temperature-removal documentation while adding the picker branch's search and keyboard workflow.
- [ ] Resolve `docs/manual-test-checklist.md` by retaining current preparation, migration, selection, release, and settings checks while adding the complete picker launch/search/navigation/return-state checks.
- [ ] Audit all auto-merged popover/localization code. Preserve `.modePicker` startup, fuzzy search, focus routing, Enter/Escape navigation, and persisted selection alongside current migration maintenance, selection safety, and reduced provider configuration.
- [ ] Run `rg -n '^(<<<<<<<|=======|>>>>>>>)' .` and confirm there are no unresolved conflict markers.
- [ ] Run `rg -n -i 'temperature' Sources README.md README.zh-CN.md CONTRIBUTING.md docs/manual-test-checklist.md` and confirm production/UI/documentation references remain absent.

### Task 2: Verify the integration contract and fix only exposed regressions

**Files:**
- Test: `Tests/InkletCoreTests/WritingModePickerStateTests.swift`
- Test: `Tests/InkletCoreTests/WritingModePreferenceStoreTests.swift`
- Test: `Tests/InkletCoreTests/WritingPopoverKeyboardPolicyTests.swift`
- Test: `Tests/InkletCoreTests/WritingPopoverSessionStateTests.swift`
- Test: `Tests/InkletCoreTests/FocusRequestGenerationTests.swift`
- Test: `Tests/InkletCoreTests/WritingModeLauncherSourceTests.swift`
- Test: `Tests/InkletCoreTests/WritingModeLauncherLocalizationTests.swift`
- Audit: `Sources/InkletApp/InkletPopoverView.swift`
- Audit: `Sources/InkletApp/InkletPopoverWindowController.swift`

- [ ] Run `swift test --filter WritingModePickerStateTests`.
- [ ] Run `swift test --filter WritingModePreferenceStoreTests`.
- [ ] Run `swift test --filter WritingPopoverKeyboardPolicyTests`.
- [ ] Run `swift test --filter WritingPopoverSessionStateTests`.
- [ ] Run `swift test --filter FocusRequestGenerationTests`.
- [ ] Run `swift test --filter WritingModeLauncherSourceTests`.
- [ ] Run `swift test --filter WritingModeLauncherLocalizationTests`.
- [ ] Run current-main regression suites: `OpenAIProviderTests`, `LLMProviderTests`, `ConfigStoreTests`, `SettingsViewSourceTests`, `SelectionTranslationCacheTests`, `SelectionTranslationServiceTests`, and `TransformationServiceTests`.
- [ ] If integration exposes a behavior defect, add or adjust the narrowest test so it fails for that defect, make the smallest production fix, and rerun the focused suite.

### Task 3: Complete branch-level verification and record the merge

**Files:**
- Verify: all merged source, test, and documentation files

- [ ] Run the complete `swift test` suite.
- [ ] Run `swift build -Xswiftc -warnings-as-errors`.
- [ ] Run `git diff --check` and inspect `git status --short` plus `git diff --stat`.
- [ ] Review the staged merge diff and confirm no private/generated files or runtime/UI temperature references were introduced.
- [ ] Commit the pending merge with subject `Merge main into writing mode picker`.

### Task 4: Review and hand-test the integrated app

**Files:**
- Review: merged picker, popover, localization, documentation, and regression-test changes

- [ ] Request an independent code review focused on state transitions, focus/keyboard handling, localization, selection safety, and temperature removal.
- [ ] Address every confirmed issue with a focused failing test first when behavior is involved, then rerun the affected and complete checks.
- [ ] Run `scripts/run-local-app.sh` to build, install, and launch `/Applications/Inklet Local.app` with the stable local bundle identity.
- [ ] Open Writing Assistant and confirm it initially shows the searchable mode picker; verify search, arrow/Tab selection, plain Enter commit, Escape behavior, and return to the picker without losing the draft/result.

### Task 5: Integrate into main and verify the delivered tree

**Files:**
- Verify: final `main` tree

- [ ] Confirm the `main` worktree is still clean and its head has not moved unexpectedly.
- [ ] Merge `codex/raycast-writing-mode-picker` into `main` without rewriting history.
- [ ] On `main`, run the complete `swift test` suite and `swift build -Xswiftc -warnings-as-errors`.
- [ ] Run `git diff --check`, inspect final `git status --short --branch`, and confirm `main` contains the picker files and no production/UI temperature references.
- [ ] Re-run `scripts/run-local-app.sh` from `main` so `/Applications/Inklet Local.app` reflects the delivered commit.
- [ ] Remove the merged picker worktree and branch after verification, preserving `main` as the only active delivery worktree.
