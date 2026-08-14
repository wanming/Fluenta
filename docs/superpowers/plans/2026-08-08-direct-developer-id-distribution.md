# Direct Developer ID Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove App Sandbox and Mac App Store packaging while preserving a hardened, signed, notarized, and verified Developer ID DMG and the stable local-app workflow.

**Architecture:** A one-key entitlement contract and reusable signed-app verifier become the source of truth for local builds, CI, and release artifacts. App Store/sandbox entry points are removed, destructive reset operations become explicit bundle scopes, and CI/installer verification checks the final mounted app instead of trusting packaging inputs. The sandbox entitlement is removed only after the migration and generic-selection plans pass.

**Tech Stack:** Bash, Swift/XCTest property-list parsing, codesign, Hardened Runtime, hdiutil, notarytool, stapler, spctl, GitHub Actions, Developer ID signing.

---

## Prerequisites And File Ownership

Complete `2026-08-08-legacy-sandbox-data-migration.md` first and `2026-08-08-generic-selection-reading.md` second. This plan is the release switch that makes Chrome/manual selection verification meaningful. It owns entitlements, build/release/install/reset scripts, release CI, and public documentation. It must not re-edit selection orchestration or migration algorithms.

## File Structure

Create:

- `scripts/verify-direct-app.sh` — validates the effective signature, entitlement allowlist, bundle identity, runtime, and non-MAS artifact shape.
- `scripts/test-direct-distribution.sh` — shell contract for retired tooling and CI/direct-build wiring.
- `Tests/InkletCoreTests/DirectDistributionContractTests.swift` — parses entitlement and Info property lists.

Modify:

- `StoreSupport/Inklet.entitlements`
- `scripts/build-macos-app-bundle.sh`
- `scripts/run-local-app.sh`
- `scripts/reset-local-state.sh`
- `scripts/reset-rebuild-install.sh`
- `scripts/install.sh`
- `scripts/test-run-local-app.sh`
- `scripts/test-reset-local-state.sh`
- `scripts/test-install-security.sh`
- `scripts/README.md`
- `.github/workflows/build-dmg.yml`
- `.env.local.example`
- `.gitignore`
- `README.md`
- `README.zh-CN.md`
- `CONTRIBUTING.md`
- `docs/privacy-policy.md`
- `docs/manual-test-checklist.md`
- `SECURITY.md`

Delete:

- `scripts/build-app-store-release.sh`
- `scripts/build-app-store-spike.sh`
- `scripts/rebuild-sandbox-app.sh`

Leave `StoreSupport/Info.plist` and all ten `StoreSupport/InfoPlistStrings/*.lproj/InfoPlist.strings` unchanged; tests will prove microphone copy remains and Apple Events copy is absent.

### Task 1: Define the direct-distribution entitlement contract

**Files:**

- Create: `Tests/InkletCoreTests/DirectDistributionContractTests.swift`
- Modify: `StoreSupport/Inklet.entitlements`

- [ ] **Step 1: Write the failing plist contract**

Create a test helper that loads a plist with `PropertyListSerialization`, then assert:

```swift
func testDirectEntitlementsUseExactAllowlist() throws {
    let entitlements = try loadPlist("StoreSupport/Inklet.entitlements")
    XCTAssertEqual(entitlements.count, 1)
    XCTAssertEqual(entitlements["com.apple.security.device.audio-input"] as? Bool, true)
    XCTAssertNil(entitlements["com.apple.security.app-sandbox"])
    XCTAssertNil(entitlements["com.apple.security.network.client"])
    XCTAssertNil(entitlements["com.apple.security.device.microphone"])
    XCTAssertNil(entitlements["com.apple.security.automation.apple-events"])
    XCTAssertNil(entitlements["com.apple.security.get-task-allow"])
}

func testInfoPlistDeclaresOnlyMicrophonePrivacyCopy() throws {
    let info = try loadPlist("StoreSupport/Info.plist")
    XCTAssertFalse((info["NSMicrophoneUsageDescription"] as? String ?? "").isEmpty)
    XCTAssertNil(info["NSAppleEventsUsageDescription"])
}
```

Enumerate all ten localized InfoPlist tables and assert each contains nonempty `NSMicrophoneUsageDescription` and no `NSAppleEventsUsageDescription`.

- [ ] **Step 2: Run and confirm RED**

```bash
swift test --filter DirectDistributionContractTests
```

Expected: the entitlement allowlist test fails because four keys currently exist.

- [ ] **Step 3: Reduce the entitlement file to one key**

The `<dict>` must contain exactly:

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

Do not add Automation, network, application-identifier, team, or provisioning entitlements.

- [ ] **Step 4: Run and commit**

```bash
plutil -lint StoreSupport/Inklet.entitlements StoreSupport/Info.plist
swift test --filter DirectDistributionContractTests
git add StoreSupport/Inklet.entitlements Tests/InkletCoreTests/DirectDistributionContractTests.swift
git commit -m "Define direct distribution entitlement contract"
```

Expected: plist lint and tests pass.

### Task 2: Verify effective signed-app identity and entitlements

**Files:**

- Create: `scripts/verify-direct-app.sh`
- Create: `scripts/test-direct-distribution.sh`
- Modify: `scripts/build-macos-app-bundle.sh`
- Modify: `scripts/run-local-app.sh`
- Modify: `scripts/test-run-local-app.sh`

- [ ] **Step 1: Write the failing shell contract**

Build a temporary minimal `.app`, sign it ad hoc with `--options runtime --entitlements StoreSupport/Inklet.entitlements`, and require the new verifier to pass. Re-sign copies with a sandbox entitlement, an Automation entitlement, a wrong bundle ID, and an embedded provisioning profile; require each to fail. Ensure failure output contains no `Authority=`, `TeamIdentifier=`, certificate subject, or configured identity text.

Run:

```bash
bash scripts/test-direct-distribution.sh
```

Expected: FAIL because the verifier does not exist.

- [ ] **Step 2: Implement `verify-direct-app.sh`**

Use this CLI:

```text
scripts/verify-direct-app.sh APP_PATH EXPECTED_BUNDLE_ID [--release]
```

Capture all verbose command output in a `mktemp -d` directory and remove it with `trap`. Assert:

- `codesign --verify --deep --strict` succeeds;
- `codesign -d --entitlements :-` parses and equals the one-key audio-input allowlist;
- code-signing flags contain `runtime`;
- `CFBundleIdentifier` equals the expected production/local identifier;
- microphone usage copy is nonempty and Apple Events usage copy is absent;
- `Contents/embedded.provisionprofile` and `Contents/_MASReceipt` are absent.

With `--release`, require `APPLE_TEAM_ID` in the environment, Developer ID Application authority, a secure timestamp, and exact team match. Never print the expected or discovered team/identity; emit only generic failed-check names.

Mark both new shell files executable before invoking them:

```bash
chmod +x scripts/verify-direct-app.sh scripts/test-direct-distribution.sh
```

- [ ] **Step 3: Harden the shared app builder**

In `build-macos-app-bundle.sh`:

- change default output from `dist/app-store-spike` to `dist/direct`;
- always pass `--options runtime`;
- pass `--timestamp` only when `INKLET_REQUIRE_TIMESTAMP=1`;
- stop dumping entitlements/signature metadata;
- invoke `verify-direct-app.sh "$app_path" "$bundle_id"`, adding `--release` when timestamp mode is required;
- continue receiving the signing identity only by environment and never echo it.

- [ ] **Step 4: Preserve and extend stable local-run guarantees**

Keep `/Applications/Inklet Local.app`, `com.tomwan.inklet.local`, `dist/local`, stable identity resolution, and default rejection of ad-hoc signing. Verify both the built app and installed app with `verify-direct-app.sh`. Extend `test-run-local-app.sh` to assert runtime signing, verifier calls, identity redaction, stable path/ID, and no default ad-hoc path.

- [ ] **Step 5: Run and commit**

```bash
bash scripts/test-direct-distribution.sh
bash scripts/test-run-local-app.sh
bash -n scripts/verify-direct-app.sh scripts/build-macos-app-bundle.sh scripts/run-local-app.sh
git add scripts/verify-direct-app.sh scripts/test-direct-distribution.sh scripts/build-macos-app-bundle.sh scripts/run-local-app.sh scripts/test-run-local-app.sh
git commit -m "Add direct app signature verification"
```

Expected: shell contracts pass without printing a real or fake signing identity.

### Task 3: Retire App Store/sandbox entry points and scope destructive reset

**Files:**

- Delete: `scripts/build-app-store-release.sh`
- Delete: `scripts/build-app-store-spike.sh`
- Delete: `scripts/rebuild-sandbox-app.sh`
- Modify: `scripts/reset-local-state.sh`
- Modify: `scripts/reset-rebuild-install.sh`
- Modify: `scripts/test-reset-local-state.sh`
- Modify: `scripts/README.md`
- Modify: `.env.local.example`
- Modify: `.gitignore`
- Modify: `scripts/test-direct-distribution.sh`

- [ ] **Step 1: Extend the retirement/reset tests and confirm RED**

Require obsolete scripts not to exist. Reject active occurrences of `app-store-spike`, `build-app-store`, `rebuild-sandbox`, `INKLET_APP_STORE_`, `ASC_EMAIL`, and `ASC_PASSWORD`. For reset dry runs, require an explicit `--scope local|production|all` and exact bundle-specific targets.

```bash
bash scripts/test-direct-distribution.sh
bash scripts/test-reset-local-state.sh
```

Expected: failures for existing App Store scripts, old names, and missing data directories.

- [ ] **Step 2: Delete obsolete entry points and simplify local rebuild**

Delete the three scripts. Make `reset-rebuild-install.sh` pass `--scope local --remove-installed-app` to reset, then call `scripts/run-local-app.sh`; do not retain a second production-bundle local runner.

- [ ] **Step 3: Implement exact reset scopes**

Require one scope and map it without globs:

| Scope | Bundle ID | Application Support | Legacy Container | Keychain service | Installed app |
|---|---|---|---|---|---|
| local | `com.tomwan.inklet.local` | `~/Library/Application Support/com.tomwan.inklet.local` | `~/Library/Containers/com.tomwan.inklet.local` | `Inklet.Local.ProviderAPIKey` | `/Applications/Inklet Local.app` |
| production | `com.tomwan.inklet` | `~/Library/Application Support/com.tomwan.inklet` | `~/Library/Containers/com.tomwan.inklet` | `Inklet.ProviderAPIKey` | `/Applications/Inklet.app` |

`all` runs both exact scopes. Delete the matching defaults domain and bundle-qualified temporary diagnostic file. Reset only Accessibility and Microphone TCC; never reset Automation. Print the selected destructive scope before executing. Never target the parent Application Support, Containers, home, or `/Applications` directory.

- [ ] **Step 4: Remove App Store-only local configuration**

Reduce `.env.local.example` to comments plus:

```bash
INKLET_LOCAL_SIGN_IDENTITY="<code-signing-identity-hash>"
```

Remove stale `.gitignore` entries for `docs/app-store-submission.md` and `docs/mac-app-store-spike.md`; keep `.private/`, `.env.local`, `*.p8`, `*.p12`, `*.mobileprovision`, and `*.provisionprofile` ignored.

- [ ] **Step 5: Update script documentation and commit**

Document direct bundle building, stable local QA, scoped destructive reset, verifier, and public installer. Remove every App Store/sandbox workflow claim.

```bash
bash scripts/test-direct-distribution.sh
bash scripts/test-reset-local-state.sh
for script in scripts/*.sh; do bash -n "$script"; done
git add -u scripts/build-app-store-release.sh scripts/build-app-store-spike.sh scripts/rebuild-sandbox-app.sh
git add scripts/reset-local-state.sh scripts/reset-rebuild-install.sh scripts/test-reset-local-state.sh scripts/test-direct-distribution.sh scripts/README.md .env.local.example .gitignore
git commit -m "Retire App Store and sandbox build tooling"
```

Expected: contracts and syntax checks pass.

### Task 4: Harden DMG CI and the standalone installer

**Files:**

- Modify: `.github/workflows/build-dmg.yml`
- Modify: `scripts/install.sh`
- Modify: `scripts/test-install-security.sh`
- Modify: `scripts/test-direct-distribution.sh`

- [ ] **Step 1: Add failing release/install contract assertions**

Require CI and installer source to include:

```text
hdiutil verify
spctl --assess --type open --context context:primary-signature
spctl --assess --type execute
stapler validate
verify-direct-app.sh
```

Require CI to mount the final DMG read-only and verify its enclosed production app. Reject identity-dumping branches and checksum generation before final signing/notarization/stapling. Installer tests must retain the existing fail-closed checksum and quarantine-preservation cases.

- [ ] **Step 2: Run and confirm RED**

```bash
bash scripts/test-direct-distribution.sh
bash scripts/test-install-security.sh
```

Expected: failures for missing DMG verification, mounted-app verification, and correct Gatekeeper assessment modes.

- [ ] **Step 3: Make CI use the shared builder/verifier**

Replace duplicated bundle assembly/signing with `build-macos-app-bundle.sh`, passing production name, bundle ID, version, build, output, hidden identity, `INKLET_REQUIRE_TIMESTAMP=1`, and `APPLE_TEAM_ID`. Remove failure output that prints `security find-identity` results or the selected identity. Retain `APP_STORE_CONNECT_API_KEY_ID`, issuer, and private key because those credentials notarize the direct DMG; remove only package/upload credentials.

- [ ] **Step 4: Verify the final DMG in the correct order**

Use this order:

1. Verify the signed app with `verify-direct-app.sh --release`.
2. Create DMG and run `hdiutil verify`.
3. Sign and verify DMG.
4. Submit to notarytool and wait.
5. Staple and `stapler validate`.
6. Assess DMG with `spctl --assess --type open --context context:primary-signature`.
7. Mount read-only/nobrowse, run the app verifier against mounted `Inklet.app`, and assess it with `spctl --assess --type execute`.
8. Detach in `trap` cleanup.
9. Generate checksums only after every final mutation and verification.

Capture verbose signature/Gatekeeper output and print only generic success/failure messages.

- [ ] **Step 5: Harden the standalone installer without external dependencies**

Because README pipes only `install.sh`, keep its checks inline. Add `hdiutil verify`, correct DMG Gatekeeper assessment, mounted production bundle-ID and entitlement allowlist checks, Hardened Runtime, absence of profile/receipt, valid signature, and executable Gatekeeper assessment. Preserve quarantine and retain the negative contract forbidding `xattr -d`, `xattr -c`, or `--no-quarantine`. Avoid verbose output that exposes certificate identities.

- [ ] **Step 6: Run and commit**

```bash
bash scripts/test-direct-distribution.sh
bash scripts/test-install-security.sh
bash -n scripts/install.sh
git add .github/workflows/build-dmg.yml scripts/install.sh scripts/test-install-security.sh scripts/test-direct-distribution.sh
git commit -m "Harden DMG release and install verification"
```

Expected: shell contracts pass.

### Task 5: Update direct-distribution, selection, migration, privacy, and security documentation

**Files:**

- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `CONTRIBUTING.md`
- Modify: `docs/privacy-policy.md`
- Modify: `docs/manual-test-checklist.md`
- Modify: `SECURITY.md`
- Modify: `scripts/test-direct-distribution.sh`

- [ ] **Step 1: Add stale-copy contract assertions**

Reject `Mac App Store: coming soon`, `Mac App Store：即将上线`, browser JavaScript/window selection claims, Automation setup, `swift run Inklet` as routine QA, and obsolete script names. Require both READMEs to mention signed/notarized GitHub DMG, Accessibility-only generic selection, temporary clipboard fallback, bundle-qualified local storage, and automatic legacy migration.

- [ ] **Step 2: Rewrite public install/setup copy**

Describe GitHub Releases DMG/install script as the only distribution channel. First-time source QA must use `scripts/run-local-app.sh` and `/Applications/Inklet Local.app`. Document that selection uses generic Accessibility first and configured clipboard fallback second, double-copy remains passive, right-click remains native, and no browser Automation grant is requested.

- [ ] **Step 3: Update privacy/security details**

Update the privacy-policy date. Remove browser-JavaScript and App Store privacy-detail language. Document bundle-qualified preferences/history/cache locations, copied-not-deleted legacy migration, in-process user-assisted import, conditional clipboard restoration, local History retention, Keychain credential handling, Accessibility, and Microphone. Add migration/storage and source-PID/clipboard concurrency to `SECURITY.md` sensitive surfaces.

- [ ] **Step 4: Expand the manual release checklist**

Replace Xcode/`swift run` preparation with the stable local app. Add fresh install and signed in-place upgrade checks, automatic/assisted migration, production/local concurrent isolation, retained Accessibility/Keychain trust, denied permissions, and the Chrome/Safari/Edge/AppKit matrix for drag, double/triple click, Shift, double-copy, right-click, protected fields, focus changes, and clipboard races. Explicitly require that no browser Automation prompt appears.

- [ ] **Step 5: Run contract and commit**

```bash
bash scripts/test-direct-distribution.sh
git add README.md README.zh-CN.md CONTRIBUTING.md docs/privacy-policy.md docs/manual-test-checklist.md SECURITY.md scripts/test-direct-distribution.sh
git commit -m "Update direct distribution documentation"
```

Expected: no stale App Store/browser-specific guidance remains.

### Task 6: Run automated, signed-local, and release-gate verification

**Files:** No new files.

- [ ] **Step 1: Run all automated checks**

```bash
swift test --filter DirectDistributionContractTests
bash scripts/test-direct-distribution.sh
bash scripts/test-run-local-app.sh
bash scripts/test-reset-local-state.sh
bash scripts/test-install-security.sh
for script in scripts/*.sh; do bash -n "$script"; done
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
git status --short
```

Expected: all commands pass and only intentional changes remain.

- [ ] **Step 2: Build and inspect the stable local app**

```bash
scripts/run-local-app.sh
scripts/verify-direct-app.sh "/Applications/Inklet Local.app" com.tomwan.inklet.local
```

Expected: the app is installed at the stable path, signed with Hardened Runtime, contains only audio-input entitlement, and launches without Automation prompts. Never print the signing identity.

- [ ] **Step 3: Complete the signed release matrix before shipping**

On macOS 14.x, 15.x, and 26.x, test the exact Developer ID artifact:

- fresh quarantined DMG install, `hdiutil verify`, stapler, DMG Gatekeeper, mounted app verifier, and executable Gatekeeper;
- in-place upgrade from a populated sandboxed build at the same path/bundle/certificate;
- retained or correctly re-requested Accessibility, production Keychain read/update, and first-use Microphone behavior;
- automatic settings/history/legacy-credential import with unchanged source and idempotent relaunch;
- file-panel assisted import when direct Container access is denied;
- production/local concurrent isolation for defaults, history, cache, diagnostics, and Keychain;
- complete selection matrix from the manual checklist;
- no Automation entry or prompt for Chrome, Safari, or Edge.

Do not publish the DMG until every supported-OS row has a recorded pass or a documented release blocker.
