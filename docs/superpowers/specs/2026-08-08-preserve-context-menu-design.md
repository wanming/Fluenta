# Preserve Native Context Menu Design

## Goal

Keep the source app's native context menu visible when the user right-clicks selected text or a word, without changing Inklet's existing left-drag, double-click, or keyboard selection workflows.

## Current Behavior And Root Cause

`SelectionActionMonitor` currently observes both left and right mouse-up events as candidate selections. Left mouse-up events are qualified through `SelectionDragPolicy`, but every right mouse-up falls through directly to the candidate-selection callback.

The coordinator then waits 120 milliseconds, reads the selected text, and presents Inklet's selection panel at the pop-up-menu window level. Presenting that panel while the source app's native context menu is active displaces or closes the native menu. Clipboard fallback actions can also end the source menu's tracking session.

## Approved Interaction

- A right-click never starts a new Inklet selection read or opens a new Inklet selection panel.
- If an Inklet selection panel is already open, right mouse-down continues to dismiss it.
- The source app remains responsible for displaying and managing its native context menu.
- Left-button drag selection, left-button double- or triple-click selection, and keyboard selection continue to trigger Inklet as they do today.
- Plain left clicks, scrolling, typing, and app activation retain their existing dismissal behavior.

## Implementation

Restrict the candidate mouse-up event monitor in `SelectionActionMonitor` to `.leftMouseUp`. Keep `.rightMouseDown` in the existing dismissal monitor.

This fixes the classification at the event source, so right-clicks never enter the delayed Accessibility, browser, or clipboard selection-reading pipeline. No changes are needed in the coordinator, readers, panel presentation, settings, localization, or documentation.

## Alternatives Considered

An explicit early return for `.rightMouseUp` would preserve behavior but continue installing an unnecessary event subscription. Deferring Inklet until the native context menu closes would add timing-dependent state and could still interfere with menu tracking. Restricting the event mask is the smallest and clearest fix.

## Testing And Verification

Add a focused app-source regression test that isolates the candidate mouse-up monitor and verifies it includes `.leftMouseUp` but excludes `.rightMouseUp`. Existing `InkletCore` tests cannot instantiate the app-only AppKit monitor, and the repository already uses source-level tests for app wiring.

Verification:

- Run the new focused regression test and the existing selection drag policy tests.
- Run the complete `swift test` suite.
- Launch `/Applications/Inklet Local.app` through `scripts/run-local-app.sh` and verify in at least one native text view and one browser:
  - Right-click opens and preserves the native context menu without showing a new Inklet panel.
  - Right-click dismisses an already-visible Inklet panel while leaving the native context menu usable.
  - Left-drag selection and double-click selection still show Inklet.
- Run `git diff --check` and inspect `git status` before completion.

## Scope

This change does not alter user-facing copy, configuration, permissions, provider behavior, clipboard fallback settings, or release behavior. README and localization updates are therefore not required.
