# Writing Dictation Modifier State Fix Design

## Problem

The Writing Assistant receives a local AppKit `flagsChanged` event for the configured modifier, but `WritingDictationShortcutMonitor` then asks `CGEventSource.keyState` whether that modifier key is down. On macOS, modifier state is carried by the event flags and the Quartz key-state query can remain `false` for the modifier virtual key. The tracker consequently classifies a valid Right Option press as ignored, so no hold timer, dictation phase, microphone request, or visible UI begins.

The existing monitor tests hide this behavior by making their injected Quartz state mirror the event flags.

## Selected Repair

For a `flagsChanged` event whose key code matches the configured shortcut:

- Keep using the event key code to distinguish left and right Option or Command.
- Use the event's device-independent modifier flags to decide whether a new matching press is down.
- Keep the tracker's existing active-key state authoritative for the matching release, including when the other key in the same modifier family remains held.
- Retain lifecycle reset and fresh-press protection. Context activation may inspect aggregate current modifier flags conservatively, but handling a press must not depend on `CGEventSource.keyState`.

This preserves the approved hold-only interaction and requires no global event monitor, Accessibility permission, Input Monitoring permission, or IOHID dependency.

## Rejected Alternatives

1. IOHID physical-key state would distinguish every edge case but adds a low-level dependency and permission/lifecycle complexity that is unnecessary for an app-local `flagsChanged` event.
2. Treating left and right Option as the same shortcut would avoid side-state handling but violate the existing shortcut choices and user configuration.

## Test Contract

Add a regression test that sends a Right Option `flagsChanged` event with `.option` present while the injected Quartz key-state provider returns `false`. After the hold delay, the monitor must emit `.start`; the matching release must emit `.stop` exactly once.

Keep all existing tests for short presses, wrong-side modifiers, simultaneous modifiers, fresh-release gating, context loss, key-down interruption, and monitor teardown.

## Verification

- The new regression test must fail before the production change and pass afterward.
- Run all shortcut-monitor tests and `swift test`.
- Run `swift build -Xswiftc -warnings-as-errors`.
- Increment the patch version and build number, then use `scripts/run-local-app.sh` to install and launch `/Applications/Inklet Local.app`.
- Verify the installed bundle version, code signature, running process, `git diff --check`, and clean worktree.
- The user performs the final physical Right Option hold test in the Writing source editor.
