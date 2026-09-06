# Writing Dictation Dispatch Work Item Crash Fix Design

## Problem

Holding the configured Writing dictation modifier now reaches the production hold scheduler, but the release app crashes before the activation delay can elapse. The crash is an `EXC_BAD_ACCESS` on the main thread while `_Block_copy` constructs the `DispatchWorkItem` created by `DispatchWorkItemHold`.

The failing source construct explicitly annotates the work-item closure with `@MainActor` even though the work item is always submitted to `DispatchQueue.main`:

```swift
DispatchWorkItem { @MainActor in
    action()
}
```

A minimal program reproduces the crash only when compiled in Swift 6 language mode with release optimization. The same program exits successfully when the explicit closure annotation is removed. Existing monitor tests inject `ManualHoldScheduler`, so they never exercise this production-only closure bridge.

## Selected Repair

Keep `DispatchWorkItemHold`, its cancellation behavior, the 80-millisecond activation delay, and main-queue scheduling unchanged. Remove only the explicit `@MainActor` annotation from the `DispatchWorkItem` closure. The enclosing type and initializer remain main-actor isolated, and the work item continues to execute exclusively on `DispatchQueue.main`.

No dictation state, shortcut semantics, microphone behavior, API flow, visible UI, permissions, or global event monitoring changes are included.

## Rejected Alternatives

1. Replace the scheduler with a Swift concurrency `Task` and `Task.sleep`. This avoids the closure bridge but changes cancellation and lifetime behavior beyond what the crash requires.
2. Replace the scheduler with `Timer`. This introduces run-loop ownership and invalidation behavior for no product benefit.

## Test Contract

Add a monitor regression test that uses the default production scheduler rather than `ManualHoldScheduler`. It activates the editor context, sends a valid Right Option press, and asserts that the hold callback starts after the configured delay without terminating the test process.

The regression must be run with `swift test -c release` so the current implementation fails through the same optimized Swift 6 closure bridge seen in the installed app. After the repair, the same release-mode test must pass. Existing injected-scheduler tests remain responsible for deterministic gesture, cancellation, and lifecycle behavior.

## Verification

- Capture the release-mode regression failing against the current implementation.
- Apply the single production change and capture the regression passing.
- Run the complete debug test suite and the complete release test suite.
- Run the strict warnings-as-errors build and the existing local/distribution script checks.
- Increment the patch version and build number, then rebuild, sign, install, and launch `/Applications/Inklet Local.app` through `scripts/run-local-app.sh`.
- Verify installed metadata, signature, running process, `git diff --check`, and clean worktree.
- Leave the final physical Right Option hold and realtime transcription check to the user.
