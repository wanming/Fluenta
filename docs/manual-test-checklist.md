# Manual Test Checklist

This checklist defines required manual verification; it does not claim that any item has been run.

Record the tested Inklet version, artifact checksum, macOS version, hardware architecture, and result when executing release QA.

## Preparation

- For release testing, install the exact signed artifact from the GitHub Releases DMG. Do not substitute an unsigned archive or a development build.
- For source or local testing, run `scripts/run-local-app.sh` and use `/Applications/Inklet Local.app`. Do not launch a bare SwiftPM executable, a worktree-local `dist/...` app, or an ad-hoc-signed app for routine QA.
- Confirm the local runner uses the stable `com.tomwan.inklet.local` bundle, and do not print or record the configured signing identity.
- Configure a test OpenAI API key in General. Use non-production text, audio, and credentials.
- Confirm the default writing shortcut is `Option+Space` and the default voice shortcut is Right Option with Press and Hold, unless the test intentionally changes them.
- Use `scripts/reset-rebuild-install.sh` only for intentional local first-launch or permission-reset QA; it removes the selected local state by design.

## Fresh Install And Signed Upgrade

- On each supported macOS version, perform a fresh install from the exact signed release DMG. Confirm Gatekeeper permits the first launch, onboarding appears, and no pre-existing production data is assumed.
- Prepare a populated legacy sandboxed production build with recognized preferences, provider credentials, and History. Perform a signed in-place upgrade that preserves the production bundle identifier and signing requirement.
- Confirm automatic migration copies recognized preferences, imports a missing legacy credential into the production Keychain service, and imports or merges History before normal app state is constructed.
- Confirm the disposable legacy translation cache is not migrated.
- Confirm the legacy source remains unchanged after successful, failed, and repeated migration attempts. Relaunch twice and confirm migration is idempotent: settings do not regress, History records do not duplicate, and existing destination Keychain items are not overwritten.
- Block or deny automatic legacy-container access in a controlled fixture, then confirm Settings presents the assisted import action without crashing startup.
- Exercise assisted import with the correct legacy `Data` folder. Confirm it pauses active workflows, imports only incomplete components while the current file-panel grant is valid, and relaunches if destination data changes.
- Reject a different bundle's container, a symlink, and an arbitrary lookalike folder before contents are imported. Confirm no persistent file-access bookmark is created.
- Postpone or cancel assisted import and confirm the preserved-data notice and Settings action remain available for retry.
- For a same-path signed upgrade, verify retained Accessibility trust and Keychain access rather than assuming either. Confirm the existing production API key can be read and updated after upgrade.
- Confirm data created only after the direct upgrade is not written back into the legacy container.

## Production And Local Isolation

- Run production and local builds concurrently. Change settings, add a History item, create a Selection translation cache entry, and trigger selection diagnostics in each build.
- Confirm settings, History, translation cache, diagnostics, defaults, and Keychain remain isolated in both directions.
- Confirm production uses `~/Library/Application Support/com.tomwan.inklet/`, `~/Library/Preferences/com.tomwan.inklet.plist`, `$TMPDIR/InkletSelectionActions.com.tomwan.inklet.log`, and `Inklet.ProviderAPIKey`.
- Confirm local QA uses `~/Library/Application Support/com.tomwan.inklet.local/`, `~/Library/Preferences/com.tomwan.inklet.local.plist`, `$TMPDIR/InkletSelectionActions.com.tomwan.inklet.local.log`, and `Inklet.Local.ProviderAPIKey`.
- Confirm `history.jsonl` and `selection-translation-cache.json` exist only under the matching bundle-qualified Application Support root.
- Confirm changing or clearing production data does not change local data, and vice versa.

## Permissions And Stable Local Trust

- Deny Accessibility on a fresh install. Confirm onboarding or Settings explains the missing permission, selection reading and insertion do not proceed, and Inklet does not show an empty selection panel.
- Grant Accessibility and confirm generic selection reading, configured copy fallback, focus restoration, and insertion work without any browser-specific permission setup.
- Deny Microphone on first voice use. Confirm a clear error appears, recording does not continue, and no text is inserted.
- Restore Microphone permission and confirm only the voice workflow records audio.
- Confirm first voice use produces the macOS Microphone prompt; simply opening Inklet or using Selection Actions must not prompt for Microphone access.
- No browser Automation prompt may appear during onboarding, selection, double-copy, insertion, or migration. Confirm Inklet is absent from browser Automation grants used by the test account.
- Run `scripts/run-local-app.sh`, exercise Accessibility and Keychain access, then rebuild and reinstall the local app twice through the same script. Confirm `/Applications/Inklet Local.app` keeps the same bundle identity and reuses Accessibility trust and Keychain access without a new approval prompt.

## Core Writing Flow

- TextEdit: focus a text field, press `Option+Space`, search for a prompt mode, use `Up` / `Down` to highlight it, press `Tab` or `Return` to commit it, enter text, press `Enter` to transform, then press `Enter` again to insert the result.
- TextEdit: enter a rough English sentence, improve it, then insert the result.
- Notes: repeat the transform and insert flow.
- Safari or Chrome: repeat the flow in a web text field.
- Open Inklet with text selected in another app and confirm the selected text appears in the source editor after committing a prompt mode.
- Initial focus: each time the popover opens, confirm the mode search field is focused and the source editor is not focused yet.
- Search field layout: at the actual 600-point popover width, confirm the magnifier never overlaps the empty placeholder, caret, typed query, or Chinese IME marked text; clear a query and confirm the native clear button works without overlap.
- Fuzzy ranking: configure `To Simple and Correct English`, `To Chinese Summary`, mixed-case, diacritic-bearing, and Chinese mode names; confirm `ts` finds both built-in modes with Simple first, `tcs` ranks the Chinese mode first, and search supports case-insensitive, diacritic-insensitive, Chinese substring, and Chinese ordered-character matching.
- Arrow navigation: press `Up` / `Down` through filtered modes and confirm the highlight clamps at the first and last result instead of wrapping.
- `Tab` in the launcher: confirm it commits the highlighted mode and focuses the source editor.
- `Return` in the launcher: confirm both main Return and keypad Enter commit the highlighted mode and focus the source editor. Confirm Command-, Shift-, Option-, and Control-modified Return stay in the launcher. During Chinese IME composition, confirm Return accepts the text or candidate without entering the source editor, then a subsequent Return commits the highlighted mode.
- No matches: enter a query with no matching modes, confirm the empty state appears, and confirm `Tab`, Return, and keypad Enter do not advance to the editor.
- Back to modes: after committing a mode from a nonempty query, use the editor's back control and confirm the query clears while the source, any existing result, and the current mode highlight remain.
- Reopen persistence: commit a non-first visible mode, close and reopen the popover, and confirm that last committed mode is highlighted.
- Missing saved mode: hide the last committed mode in Settings, then delete it in a separate pass; each time, reopen the popover and confirm the first visible mode in Settings order is highlighted.
- Change mode with a result: return to the launcher, commit a different mode, and confirm the prior result remains visible with its `Generated with` mode label. Confirm generation waits for a deliberate `Enter`, then regenerates with the newly committed mode.
- Regeneration recovery: force both a provider failure and an `Escape` cancellation while regenerating with a different mode; confirm the prior result remains visible and `Enter` can retry.
- Restore Insert behavior: reselect the mode that generated the existing result and confirm the stale-result label clears and `Enter` inserts the result instead of regenerating it.
- Layered `Escape`: with a result visible, press `Escape` once to return to the source editor, once to return to the mode launcher, and once to close the popover. Confirm each press moves only one level.
- Generation cancellation: press `Escape` while transforming and confirm generation cancels, remains in the editor, and performs no additional back navigation.
- Launcher capacity and copy: configure more than six visible modes with long English and Chinese names; at the actual 600-point popover width, confirm scrolling reaches every mode and text, icons, and hints do not overlap.
- Pointer interaction: confirm a single click highlights without committing, a double-click commits, and hover and pressed states are visible without changing layout.
- VoiceOver: confirm the search field and every mode have useful labels, the highlighted mode exposes its selected state, and each mode offers a named `Write` action that commits it.
- `Command+Enter`: insert the original source text without calling the provider.
- `Command+Up` / `Command+Down`: cycle through visible prompt modes.
- Missing API key: show an inline error while preserving the source text.
- Network or provider failure: show an inline error while preserving the source text.
- Paste failure: keep the generated result visible so the user can copy or retry.
- Clipboard restoration after insertion: confirm the prior clipboard contents are restored.

## Voice Dictation

- TextEdit: focus a text field, hold Right Option, speak a short phrase, release Right Option, and confirm text is inserted.
- Change Voice Recording Mode to Tap Once; tap the configured shortcut to start, tap again to stop, and confirm text is inserted.
- Change Voice Recording Mode to Double Tap; double-tap to start, double-tap again to stop, and confirm text is inserted.
- Confirm the compact voice window shows Listening, Transcribing, Polishing, and Inserting states.
- Press Escape while Listening and confirm nothing is inserted.
- Disable Auto Process and confirm raw transcription is inserted. Enable it with Voice Cleanup and confirm meaning and language are preserved without summarizing.
- Select System Default and a concrete microphone in turn. Disconnect the concrete microphone and confirm fallback to System Default or a clear no-input error.
- Clear the shared OpenAI API key in General and confirm dictation shows a clear error without inserting.
- Change the voice shortcut to Right Command, Left Option, Left Command, and Disabled; confirm each works with the selected recording mode.

## Generic Selection Matrix

Run every item below in Chrome, Safari, Edge, and a native AppKit text view. Repeat with Force Selection disabled, Menu Copy with simulated `Command+C` off, and Menu Copy with the advanced simulated-copy fallback enabled where the source application supports it.

- Left-button drag selection: the compact menu appears with Translate and Pronounce.
- double-click word selection and triple-click paragraph selection: each produces one stable selection result without immediately dismissing the panel.
- Shift-modified keyboard selection: the same generic Accessibility-first pipeline runs.
- Accessibility success: the temporary clipboard is not changed.
- Accessibility unsupported or empty with Force Selection enabled: the configured temporary copy path reads the same source app.
- Force Selection disabled: no synthetic copy occurs and no empty panel appears when Accessibility cannot read the selection.
- Leave simulated `Command+C` off, exercise a full-screen game or remote desktop, and confirm Inklet never sends a copy shortcut. Then enable the advanced fallback, confirm its warning is visible, and verify a focus change never sends `Command+C` to the newly active app.
- double-copy: press `Command+C` twice quickly and confirm Inklet passively reads the user's copy, issues no third copy, and does not restore older pasteboard data.
- right-click: the source application's native context menu remains usable and no selection read starts. With an Inklet panel already visible, right-click dismisses it without breaking the native menu.
- A protected password field or protected page that rejects copy: no empty Inklet panel appears and the previous clipboard stays unchanged.
- Trigger a focus change to a different app while a read is pending: Inklet cancels and neither copies nor presents text from the newly focused app.
- Exercise a clipboard race by copying different content from the source app or another app while the fallback is pending: the newer clipboard contents win and are not replaced by the saved snapshot.
- Start overlapping selection reads, cancel during the polling delay, and force a timeout. Confirm transactions remain serialized, cleanup finishes, and no stale read restores or presents data.
- No browser Automation prompt appears in any selection scenario.
- Inspect the bundle-qualified selection diagnostic log and confirm repeated event entries are rate-limited and no selected text, clipboard text, or typed characters are recorded.
- Translate selected text and confirm the result remains visible with copy, original-audio, and translated-audio controls.
- Translate the same text with the same settings again and confirm the cached result appears. Confirm a successful action is recorded in Settings > History, but mere selection without an action is not.

## Settings And History

- `Command+,`: open Settings while Inklet is active.
- General: configure the OpenAI API key, then change language and appearance.
- Write Assistant: configure the OpenAI model, writing shortcut, and timeout.
- Voice Write Assistant: configure shortcut, microphone, speech preset, speech endpoint, speech model, auto-processing, and cleanup prompt mode.
- Selection Assistant: configure translation language, Translate prompt, Force Selection mode, pronunciation voice, and speed; preview the voice.
- Prompt Modes: add, edit, hide, delete with confirmation, and reorder modes.
- Permissions: verify Accessibility status and the System Settings button. Inklet should not steal focus while System Settings is open; close it and confirm the existing Settings window returns with refreshed status.
- History: confirm successful Write, Voice, and Selection results appear newest first. Repeat identical consecutive actions and confirm duplicates collapse; add a different item and then repeat the original to confirm it is retained.
- History: filter by Write, Voice, and Selection; select source/result text; copy result text; clear History and confirm the empty state.
- Save behavior: quit and reopen Inklet and confirm changes persist in the matching bundle's defaults.

## Exact Signed Release Matrix

Run the fresh-install and signed-upgrade sections using the exact final DMG and supported hardware on macOS 14.x, macOS 15.x, and macOS 26.x. Record automatic versus assisted migration results separately for every OS version.

- Run `hdiutil verify` on the final DMG and require success.
- Run `xcrun stapler validate` on the final DMG and require a valid staple.
- Assess the DMG with Gatekeeper as an openable primary-signature artifact, mount it read-only, and assess the mounted app with Gatekeeper as executable.
- Verify the DMG signature, the app's deep strict signature, Hardened Runtime, production bundle identifier, and every architecture of the executable.
- Inspect effective entitlements on the final signed app: audio input is present; App Sandbox and Automation Apple Events are absent; no unexpected entitlement is present.
- Confirm the mounted app has no embedded provisioning profile and no store receipt, and the DMG contains only `Inklet.app` plus the expected `/Applications` link.
- Run the standalone installer against the final release assets. Confirm it requires and verifies the checksum, DMG, mounted payload, signature, Gatekeeper, Hardened Runtime, and effective entitlements before replacing `/Applications/Inklet.app`.
- Confirm quarantine is preserved through download and installation; do not clear extended attributes or bypass Gatekeeper.
- Verify first launch, automatic or assisted migration, Accessibility, first voice use, Keychain read/update, settings, History, and repeat-launch behavior from the installed final artifact.

## Compatibility Notes

- Smoke-test Slack or Discord, Notion, VS Code or Cursor, Terminal or iTerm, and any application changed by the release.
- Record unsupported protected-content or terminal behavior precisely. Do not turn an observed limitation into a claim that the entire matrix passed.
