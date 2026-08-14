# Direct Distribution Without App Sandbox Design

## Summary

Inklet will move to a Developer ID-only distribution model and stop producing a Mac App Store build. The direct-download app will keep Hardened Runtime signing, notarization, stapling, and the existing DMG release flow, but it will no longer use App Sandbox.

Removing the sandbox also lets Inklet use one application-agnostic selection-reading pipeline. Inklet will read selected text through macOS Accessibility first and fall back to a clipboard-preserving copy operation when an application does not expose its selection. Browser-targeted AppleScript and per-browser Automation permission prompts will be removed.

Existing sandboxed settings and history must survive the upgrade. A versioned, idempotent migration will import data from the matching legacy container before any normal configuration or store is constructed. Production and local builds will use bundle-specific Application Support directories so they cannot read, overwrite, or race on each other's user text.

## Goals

- Restore reliable selected-text handling in Chrome and other applications without browser-specific permissions.
- Require one generic Accessibility grant for selection reading and input control, rather than Automation grants for individual browsers.
- Preserve existing user settings and history during an in-place upgrade from the sandboxed release.
- Keep production and local-build settings, history, cache, diagnostics, and Keychain identities isolated.
- Retain the security and release checks required for a notarized Developer ID application.
- Make documentation and build tooling accurately describe direct distribution as the only supported channel.

## Non-Goals

- No Mac App Store-compatible build or alternate sandboxed entitlement set.
- No browser-specific integration, browser allowlist, browser-targeted AppleScript, or Automation permission UI.
- No automatic deletion of the legacy sandbox container after migration.
- No migration of the disposable translation cache.
- No attempt to read protected fields or content that the source application refuses to expose or copy.

## Current Behavior And Root Cause

The current shared entitlement file enables App Sandbox. The automatic selection pipeline first asks `SelectedTextReader` for the Accessibility selection, then calls `SelectionBrowserTextReader`, which sends Apple Events to Safari, Chrome, or Edge, and finally tries `SelectionClipboardReader`.

In the sandboxed direct build, macOS denies both the browser Apple Event and the Accessibility server lookup needed by the generic fallback. The browser read then waits for the failed AppleScript path before returning an empty result. Adding Automation capability would still produce independent target-specific grants because macOS authorizes Apple Events per receiving application; it cannot provide one universal browser permission.

The existing sandbox also changes the meaning of standard storage URLs. Sandboxed production and local builds currently resolve the same logical `Application Support/Inklet` path inside separate containers. Once unsandboxed, both builds would resolve that path globally and collide. `UserDefaults.standard` likewise moves from the container preferences domain to the global preferences domain, where an older stale plist may already exist.

## Approved Distribution Model

Inklet will support one release configuration: a direct-download Developer ID app distributed through the notarized DMG and GitHub Releases.

The release keeps:

- Developer ID signing with the current stable product identity.
- Hardened Runtime.
- Notarization and stapling.
- Gatekeeper, signature, and DMG validation.
- The existing production bundle identifier and local runner bundle identifier.

The shared direct-distribution entitlement file will:

- Remove `com.apple.security.app-sandbox`.
- Remove sandbox-only `com.apple.security.network.client`.
- Remove the redundant `com.apple.security.device.microphone` entry.
- Retain `com.apple.security.device.audio-input` for microphone use under Hardened Runtime.
- Not add `com.apple.security.automation.apple-events`.

`NSMicrophoneUsageDescription` remains. No `NSAppleEventsUsageDescription` or Automation localization is added because the selection pipeline will no longer send Apple Events to source applications.

The App Store build/upload script, compatibility wrappers whose only purpose is App Store packaging, App Store-only environment variables, and related instructions will be removed. Sandbox-named local scripts will be renamed or rewritten around the direct local bundle. Release checks will inspect the effective entitlements of the signed app and fail if App Sandbox or Automation is present, or if the required audio-input entitlement is absent.

## Generic Selected-Text Architecture

All source applications use the same ordered pipeline:

1. Inklet confirms that the process captured by the selection monitor is still running and frontmost. A focus change cancels the read rather than redirecting it to the newly focused application.
2. `SelectedTextReader` asks macOS Accessibility for the selected text, using only elements whose owning process matches the captured source process.
3. If Accessibility is trusted but the application does not expose a usable selection, `SelectionClipboardReader` performs the existing temporary copy fallback when the configured force-selection mode permits it.
4. Inklet revalidates the frontmost process immediately before a menu action or copy shortcut and again before accepting the copied text.
5. If both readers fail or return an empty selection, Inklet does not present a selection panel.

`SelectionBrowserTextReader`, its browser bundle-identifier list, its AppleScript tests, and the coordinator's browser-specific state and result arbitration will be removed. Chrome, Safari, and Edge remain manual compatibility targets, but the application code will not recognize them specially.

The current `isFocusedSelectableTextElement` preflight must not veto clipboard fallback. Inklet may retain it as an Accessibility optimization, but a false result proceeds to the configured fallback instead of returning `.emptySelection`. The existing force-selection setting remains authoritative: `.disabled` intentionally stops after Accessibility, while the enabled modes retain their configured menu-action and shortcut order.

The clipboard fallback must preserve user data:

- Allow only one clipboard transaction at a time. A newer read cancels and awaits cleanup of the previous transaction before taking its own snapshot.
- Give each transaction an operation token and record its initial pasteboard snapshot and change count.
- After the copy action, record the change count belonging to the observed copy result while the operation token and source-process checks are still valid.
- Restore the snapshot only if the same transaction is still current and the pasteboard change count still equals that observed copy-result count.
- If the user or another application changes the pasteboard, or a newer Inklet transaction starts, leave the newer contents untouched.
- Treat secure fields, protected pages, empty selections, copy failures, and timeouts as no result.

Automatic left-button selection and Shift-modified keyboard-selection candidates enter this Accessibility-to-clipboard pipeline. The existing double-copy trigger remains a distinct path: it consumes the pasteboard change created by the user's own copy command and never issues or restores another synthetic copy. Right mouse-up remains excluded at the event-monitor boundary, so a native context menu never starts a selection read. An already-visible Inklet panel may still be dismissed by right mouse-down as previously approved.

## Storage Layout

Unsandboxed stores will use a bundle-qualified root under the user's Application Support directory:

- Production: `~/Library/Application Support/com.tomwan.inklet/`
- Local: `~/Library/Application Support/com.tomwan.inklet.local/`

History remains `history.jsonl` within that root. The translation cache remains `selection-translation-cache.json` within that root. A shared path helper will derive the root from the running bundle identifier, with an explicitly injected identifier or root for tests.

Selection diagnostics will also include the bundle identifier in the temporary filename so simultaneously running production and local builds do not overwrite each other's logs.

Existing Keychain data does not change location. Production and local builds already use separate service names, and an in-place Developer ID upgrade retains the production bundle and signing identity. The signed-upgrade verification must nevertheless confirm that the existing API key can still be read and updated. Legacy plaintext API-key preferences receive the special handling described below and are never copied into global defaults.

## Legacy Sandbox Migration

A small `LegacySandboxDataMigrator` will run in `main.swift` before `AppDelegate` is created. This ordering is required because `AppDelegate` eagerly constructs `AppCoordinator`, which in turn reads defaults and opens the history and cache stores during initialization.

The migrator will target only the legacy container matching the running bundle identifier:

`~/Library/Containers/<bundle-identifier>/Data/`

It will maintain versioned, per-component migration state so a partially completed migration can safely resume. A component is marked complete only after its destination write succeeds. Every operation is retry-safe, and the legacy source is never moved, changed, or deleted.

Migration for one bundle identifier is protected by a cross-process lock file in the new bundle-qualified Application Support root. A second launch waits for the bounded migration attempt to finish, then reloads the component markers rather than running a concurrent merge. The migrator returns a structured outcome to `AppDelegate`; user-facing status is presented only after the coordinator starts and migrated language preferences have taken effect.

### Preferences

On the first unsandboxed launch, the legacy container preference domain is authoritative for known Inklet-owned keys. The migrator reads the legacy property list directly from `Data/Library/Preferences/<bundle-identifier>.plist`; constructing a normal `UserDefaults` suite would resolve the new unsandboxed domain instead. It copies only recognized keys used by configuration, language, onboarding, model catalog, selection actions, and app UI state. It does not copy arbitrary system-managed preference entries, API-key values, or other secrets.

When automatic migration succeeds before the app's first normal unsandboxed launch, recognized legacy values overwrite matching global values during that migration. Keys absent from the legacy domain leave any global value unchanged. This is intentional because an existing global preferences plist may be older than the active sandboxed state.

If automatic access fails, the migrator records a non-secret, tri-state fingerprint baseline for every recognized global key before allowing the app to start: absent, or present with a cryptographic digest of its property-list encoding. It does not duplicate the preference value itself. On a later automatic or user-assisted retry, a legacy value replaces the global value only when the current global value still matches that recorded baseline. A value added, changed, or removed after the baseline was recorded is treated as a post-upgrade user edit and wins over the legacy value. This prevents a delayed migration from silently undoing settings saved in the meantime.

The migrator writes the preference migration marker to the global domain only after the conflict-aware import succeeds. After that version is recorded, future launches never import preferences from the legacy container again.

### Legacy API Keys

Dynamic preferences matching the existing `providerAPIKey.*` legacy format are imported directly into the matching production or local Keychain service through the existing Keychain abstraction. They are never written to global `UserDefaults`. An existing Keychain item wins and is not overwritten. The credential component is marked complete only when every legacy value is already present in Keychain or has been saved successfully; failures remain retryable without logging key contents.

### History

If legacy history exists and the new destination is empty, the migrator imports it atomically. If both sources contain records, it decodes all valid JSONL records, merges them by `HistoryItem.id`, and preserves the destination copy when an identifier appears in both. The merged file is written atomically in deterministic `createdAt` order, using the record identifier as the tie-breaker.

Malformed legacy lines are skipped consistently with the existing history reader. Re-running after an interruption cannot duplicate records because merging is identifier-based. The legacy history file remains untouched for rollback or manual recovery.

### Translation Cache

The translation cache is disposable and is not imported. The unsandboxed build starts with a fresh cache in its bundle-qualified directory.

### Migration Failure

The migrator must use error-reporting directory and file operations rather than `fileExists`, because App Data protection can make an existing container look absent. Only a confirmed `ENOENT`-equivalent result is treated as no legacy data. Permission denial, an indeterminate lookup, a read or decode failure, and a destination write failure remain incomplete migration states.

An incomplete migration does not crash startup:

- Inklet logs the component, bundle-relative source and destination labels, and a non-sensitive error description without including the user's home-directory path.
- The application continues with whatever new-store data is safely available.
- The failed component is not marked complete and is retried on a later launch.
- After launch, a localized, non-blocking notice explains that old data could not be imported and remains preserved.
- The notice provides an `Import Old Data…` action. It uses a system file-selection panel to let the user grant access to the matching legacy `Data` directory.
- Inklet resolves symlinks and requires the selected canonical URL to equal `~/Library/Containers/<current-bundle-identifier>/Data/`. It also verifies the expected bundle-specific preferences filename. Another bundle's container, a symlink, an arbitrary lookalike directory, and production/local cross-selection are rejected without reading or copying their contents.
- The import action is unavailable while voice recording or another user-visible transformation is active. After validation in an idle state, Inklet enters a bounded migration-maintenance state while the file-panel grant is still valid in the current process. It pauses new selection and voice work, cancels outstanding selection reads, and makes settings read-only with an in-place progress indicator so no live component can save across the import.
- While still in that process, Inklet acquires the migration lock and imports the incomplete components with the same conflict and atomicity rules as startup migration. It does not assume that access to another app container survives process exit and does not persist a reusable grant.
- If any destination component changed, Inklet performs a controlled relaunch before re-enabling normal interaction, so newly constructed coordinators load the migrated configuration and stores. If an import fails, completed components remain idempotently committed, incomplete components remain retryable, and the relaunch preserves the post-launch failure notice for them.
- If the user postpones the import, the same action remains available from Settings until migration succeeds; the automatic path continues to retry on later launches.

The notice must not claim that the data was deleted and must not expose selected text, history contents, filesystem usernames, or other private data.

The exact Developer ID-signed upgrade must prove automatic legacy-container access on every supported macOS release before shipping. If a supported version blocks automatic access, the user-assisted import path becomes a release requirement on that version. The release cannot claim migration support unless at least one signed and verified path imports preferences, legacy credentials, and history without modifying the source.

## Permission And Interaction Behavior

Accessibility remains the single generic selection permission used for reading text and simulated input. A previously trusted, same-path, same-bundle, same-certificate upgrade is expected to retain trust, but this is verified rather than assumed. Fresh installs continue through the existing Accessibility onboarding.

Microphone permission remains tied to voice dictation and keeps its existing usage description. Browser Automation prompts, browser-specific permission explanations, and Chrome's "Allow JavaScript from Apple Events" requirement disappear with the AppleScript reader.

For every supported source application:

- Accessibility success presents the compact Inklet selection menu.
- Accessibility unsupported, empty, or rejected by its selectable-element heuristic falls back to the clipboard-preserving reader when force selection is enabled.
- Fallback success presents the same menu with no app-specific variation.
- Permission denial follows the existing Accessibility guidance.
- A source-app focus change, complete read failure, empty selection, protected content, cancellation, or timeout leaves the source application and any newer clipboard contents unchanged and presents no empty Inklet panel.

## Documentation And Tooling

Public documentation will describe signed and notarized direct download as the sole distribution channel. `README.md` and `README.zh-CN.md` will remove "Mac App Store coming soon" language and accurately describe the Accessibility and microphone permissions. The privacy policy and `SECURITY.md` will be reviewed for App Store, sandbox, storage-location, and selection-reading claims and updated where necessary.

Script documentation and local reset tooling will use the direct-build terminology. An intentional first-launch reset must cover both the legacy container and new bundle-qualified locations, reset only the relevant TCC services, and continue to preserve the production/local Keychain separation. Reset scripts remain destructive QA tools and must clearly state what they remove.

No new Automation permission copy is required. Any new migration failure notice must be added to every supported localization table.

## Testing Strategy

Implementation will follow test-driven development with focused tests before production changes.

### Automated Tests

- Bundle-qualified path resolution isolates production and local history, cache, and diagnostics.
- Preference migration copies only recognized keys, treats the matching container as authoritative once, and is idempotent after success.
- Delayed preference migration overwrites unchanged stale globals but preserves keys added, changed, or removed after the failure baseline.
- Legacy plaintext API keys go directly to the correct Keychain service, never global defaults, and never overwrite an existing Keychain item.
- Independent migration markers allow a failed component to resume without reapplying successful components.
- The cross-process lock prevents two first launches from migrating the same bundle concurrently.
- History migration handles an empty destination, merges two stores, preserves destination records on duplicate IDs, skips malformed lines, and remains idempotent.
- A confirmed missing container, a permission-denied container, and a user-selected legacy directory produce distinct outcomes; none crash startup or delete the source.
- User-assisted import accepts only the canonical container for the running bundle and rejects another bundle, symlinks, and lookalike directories before reading them.
- User-assisted import reads only while the current process's file-panel grant is valid, prevents concurrent settings/workflow mutations, and relaunches before normal interaction resumes.
- Partial assisted-import failure commits only atomic completed components, leaves the rest retryable, and still relaunches when any live destination changed.
- The automatic selection pipeline tries Accessibility first, falls back generically to clipboard, and has no browser-specific branch.
- A false selectable-element preflight reaches clipboard fallback when enabled, while `.disabled` intentionally stops without copying.
- Accessibility candidates with the wrong owning PID and reads whose frontmost PID changes are rejected.
- Clipboard transactions are serialized and restore the original pasteboard only while their token and observed change count still match.
- Clipboard tests cover user changes, cancellation, timeout, and overlapping old/new read requests.
- The double-copy trigger consumes the user's existing pasteboard change without starting a synthetic clipboard transaction.
- Source-contract tests verify right mouse-up is still excluded and browser AppleScript wiring is absent.
- Entitlement-contract tests verify App Sandbox, Automation, and obsolete sandbox-only entries are absent while audio input remains present; Info.plist tests verify `NSAppleEventsUsageDescription` is absent.
- Script tests and shell syntax checks cover renamed local/reset tooling and retired App Store entry points.

### Manual Verification Matrix

Verify a fresh direct install and a controlled, signed in-place upgrade from the sandboxed build. For each, verify Accessibility onboarding or retained trust, microphone access, API-key access, configuration, history, and repeat-launch migration behavior.

Run production and local builds concurrently and confirm that changing settings, adding history, filling translation cache, and writing diagnostics in one build does not affect the other.

In Chrome, Safari, Edge, and a native AppKit text view, verify:

- Left-button drag selection presents Inklet.
- Double- and triple-click word or paragraph selection presents Inklet.
- Shift-modified keyboard selection presents Inklet.
- Keyboard selection plus the supported double-copy trigger presents Inklet without issuing a third copy or restoring older pasteboard data.
- Right-click presents and preserves only the source application's native context menu.
- Right-click dismisses an already-visible Inklet panel without making the native menu unusable.
- Protected fields and pages that reject copy show no empty Inklet panel and retain clipboard contents.
- Switching to another application during the read cancels Inklet without copying or presenting text from the newly focused application.

Test allowed and denied Accessibility states. No scenario should request Automation control of a browser.

### Release Verification

- Run targeted migration, storage-path, clipboard, and selection tests while developing.
- Run the complete `swift test` suite.
- Build, install, and launch `/Applications/Inklet Local.app` through `scripts/run-local-app.sh` with its stable signing identity.
- Inspect the local and release app's effective entitlements with `codesign`.
- On every supported macOS release, test the exact Developer ID-signed upgrade against a populated sandbox container and exercise the user-assisted import fallback if automatic access is blocked.
- Run strict signature, Hardened Runtime, Gatekeeper, notarization, stapling, and DMG checks used by the release workflow.
- Run shell syntax and focused script tests.
- Run `git diff --check` and inspect `git status` before completion.

## Rollback And Data Safety

Because migration copies rather than moves data, reinstalling the prior sandboxed build still exposes its unchanged container data. Data created only after moving to the unsandboxed build is not synchronized back into the legacy container. This limitation will be documented for release testing, and no cleanup of the container will be bundled with the normal application.

## Alternatives Considered

### Maintain Separate App Store And Direct Builds

A sandboxed App Store configuration and an unsandboxed direct configuration would preserve both channels, but it doubles entitlement, permission, storage, migration, and verification paths. The user explicitly chose to stop App Store distribution, so this complexity provides no product benefit.

### Remove Only The Sandbox Entitlement

Changing one plist key would unblock some system services but would silently move defaults and Application Support resolution, collide production and local user data, leave stale App Store tooling, and retain browser-specific permission behavior. It is not data-safe.

### Keep Browser AppleScript With Automation Entitlement

This could read browser JavaScript directly, but macOS would still grant Automation separately for Safari, Chrome, and Edge, and browser settings could independently disable execution. The approved design instead uses one application-agnostic Accessibility and clipboard pipeline.
