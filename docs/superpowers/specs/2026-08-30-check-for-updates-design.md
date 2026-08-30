# GitHub Release Update Check Design

## Summary

Inklet will check GitHub Releases for a newer stable version without downloading or installing it. The production app will perform a throttled background check every 24 hours and both production and local builds will expose a manual **Check for Updates…** command. When a newer release is available, Inklet will show the version and a bounded excerpt of its release notes, then let the user open that exact GitHub Release in the default browser.

The feature will use GitHub's public latest-release REST endpoint directly. It will not add Sparkle, an update manifest, a privileged helper, a download path, or any release-pipeline work.

## Goals

- Let users discover a newer stable Inklet release from inside the menu-bar app.
- Check automatically without delaying app startup or interrupting active work.
- Provide an explicit manual check from both macOS application menus used by Inklet.
- Use the existing GitHub Release tag and asset contract as the version source.
- Keep network, parsing, scheduling, and presentation responsibilities independently testable.
- Make automatic failures quiet while giving manual checks complete feedback.
- Send no user text, audio, API keys, settings, history, or other private Inklet data to GitHub.

## Non-Goals

- No update download, verification, mounting, installation, self-replacement, or relaunch.
- No Sparkle dependency or appcast.
- No prerelease, draft, beta-channel, or custom-channel support.
- No change to the signed and notarized DMG release workflow.
- No automatic-update preference or new Settings section in this iteration.
- No Dock badge, menu-bar icon badge, notification permission, or persistent dismissed-release state.

## Current Context

Inklet is a SwiftPM macOS 14 menu-bar application with an AppKit lifecycle and SwiftUI content. `AppCoordinator` owns the main application menu, status-item menu, app-level workflows, and localized menu rebuilding. The app is distributed only through signed and notarized GitHub Release DMGs.

The release workflow derives tags from `VERSION` in this format:

```text
v<CFBundleShortVersionString>-<CFBundleVersion>
```

For example, marketing version `1.0.1` and build number `5` produce `v1.0.1-5`. The workflow publishes a stable `Inklet.dmg` asset after creating the Release. The client therefore must not announce an incomplete Release that does not yet contain an uploaded `Inklet.dmg` asset.

## Chosen Approach

Inklet will request:

```text
https://api.github.com/repos/wanming/Inklet/releases/latest
```

The request will identify JSON as the accepted representation and use a versioned GitHub REST API header. It will not include a GitHub token. The response model will decode only the required fields:

- `tag_name`
- `name`
- `body`
- `html_url`
- `draft`
- `prerelease`
- asset `name` and `state`

Although GitHub's latest-release endpoint excludes draft and prerelease releases, Inklet will validate both flags defensively. It will also require an uploaded `Inklet.dmg` asset before treating the Release as available.

The tag parser will accept only the repository's exact `v<major>.<minor>.<patch>-<positive build>` format. The remote integer build number will be compared with the running bundle's integer `CFBundleVersion`:

- remote build greater than current build: update available;
- remote build equal to or lower than current build: up to date;
- missing or malformed local or remote build: check failure.

The marketing version is display metadata and is not used to order builds. This avoids semantic-version ambiguity and matches the current release workflow's monotonically increasing build-number contract.

## Architecture

### Core Release Model And Parser

A focused `InkletCore` unit will own value types and deterministic rules:

- `GitHubRelease` represents the decoded remote release fields.
- `InkletReleaseVersion` represents the parsed marketing version and build number.
- `AppUpdateCheckResult` represents either `updateAvailable` or `upToDate`.
- A parser validates tags, release flags, the DMG asset, and the allowed release URL.

The release page URL must use HTTPS, have host `github.com`, and belong to the `wanming/Inklet` Release path. Inklet will never open an arbitrary URL supplied by a malformed response.

### GitHub Release Client

`GitHubReleaseUpdateChecker` will perform one asynchronous request and return an `AppUpdateCheckResult`. Its data-loading dependency and current-version input will be injected so tests do not call the live GitHub API. It will distinguish transport, HTTP, decoding, release-validation, and local-version errors internally while exposing user-safe error categories that the app layer maps to localized copy.

The client will use a 15-second request timeout and reject response data larger than 1 MiB before decoding. HTTP `403`, `404`, `429`, and `5xx` responses are failures; it will not retry internally. Retry timing belongs to the coordinator so concurrent or repeated UI actions cannot create overlapping retry loops.

### App Update Coordinator

An app-target `UpdateCheckCoordinator` will own scheduling, request coalescing, presentation state, and browser opening. `AppCoordinator` will hold this object for the application lifetime and delegate menu actions to it.

Only one request may exist at a time. If a manual request arrives during an automatic request, it joins the in-flight work and upgrades that result to interactive presentation. This guarantees that a user-initiated check always receives an up-to-date, failure, or update-available response without causing a duplicate network request.

The coordinator will expose checking state so both menu instances can show the same disabled **Checking for Updates…** state. Language changes rebuild both menus using the current state and localized strings.

## Scheduling

Production automatic checks use a bundle-specific `UserDefaults` timestamp for the most recent automatic attempt. The timestamp is written when an automatic request begins, not only after success, so launching repeatedly while offline cannot hammer GitHub.

At app startup:

1. Inklet finishes normal coordinator startup first.
2. If 24 hours have elapsed since the last automatic attempt, it starts a background check.
3. Otherwise it schedules the next check for the remaining interval.
4. After an automatic attempt, it schedules another check 24 hours later.

A timer that resumes with the app run loop may fire late after system sleep; a late check is acceptable and must not be duplicated. Termination cancels the timer and in-flight work.

`Inklet Local` will not schedule automatic production checks. Its manual command remains enabled so developers can exercise the real interaction deliberately. Manual checks always bypass the stored interval in both bundles.

## User Interaction

### Menu Commands

Add **Check for Updates…** in two places:

- the main application menu, after **About Inklet**;
- the status-item menu, between **Settings…** and the About/Quit group.

Both commands call the same coordinator. While a request is active, both items use the localized **Checking for Updates…** title and are disabled.

### Update Available

Inklet activates itself and presents a standard macOS alert containing:

- the latest marketing version and build number;
- the current displayed version;
- the Release name when it adds information beyond the version;
- a plain-text excerpt of the GitHub Release body.

Release notes will be normalized for line endings, trimmed, and capped at 800 user-perceived characters with an ellipsis. An empty body uses localized fallback copy directing the user to GitHub for details. The full notes remain available on the Release page.

The alert actions are:

- **View on GitHub**: open the validated `html_url` in the default browser;
- **Later**: dismiss without downloading or changing update state.

An automatic update alert must not cancel, dismiss, or steal state from voice recording, migration maintenance, a running transformation, or another sensitive user workflow. The coordinator retains one pending automatic update result in memory until Inklet becomes idle or the process terminates; it is never persisted. A manual check is explicitly user initiated and presents its result as soon as the request completes.

No more than one automatic alert can be produced per 24-hour check interval. A later automatic check may remind the user again while the newer build remains available.

### Up To Date

A manual check shows a localized **Inklet is up to date** alert with the current version. An automatic up-to-date result is silent.

### Failure And Retry

A manual failure shows localized, non-technical guidance and offers **Retry** and **Cancel**. Retry starts another interactive check only after the prior request has completed. Raw response bodies, filesystem paths, and internal error details are never shown.

An automatic failure is silent and does not affect other Inklet features. The 24-hour attempt timestamp still prevents repeated launch-time requests. The user can always bypass the interval with the manual command.

## Privacy And Security

The check sends a normal HTTPS request to GitHub for public Release metadata. GitHub receives ordinary connection metadata such as the user's IP address and HTTP headers. Inklet sends no authentication token and no user text, audio, history, prompts, provider configuration, API keys, or other settings.

The response is untrusted input. Inklet will:

- enforce a bounded response size before decoding;
- decode only expected fields;
- reject malformed tags and non-stable releases;
- require the expected uploaded DMG asset;
- validate the Release URL before opening it;
- cap release-note text before presentation;
- avoid logging response bodies or release-note contents.

Because this iteration never downloads or executes code, it does not add an update-package trust chain. Existing Developer ID, notarization, checksum, installer, and DMG verification remain unchanged.

## Localization And Documentation

Every new user-facing string will be added to all ten existing localization tables: English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, French, German, Portuguese, and Italian. Localization contract tests will require every new key in every table. Menu and alert copy must fit the existing window sizes and macOS alert layout, with Chinese and English checked explicitly.

Documentation updates will include:

- `README.md` and `README.zh-CN.md`: describe automatic and manual update checks while keeping GitHub Releases as the only supported distribution channel;
- `docs/privacy-policy.md`: disclose the periodic GitHub metadata request and confirm that no Inklet content or credentials are sent;
- `docs/manual-test-checklist.md`: add online, offline, update-available, up-to-date, retry, URL-opening, production/local scheduling, and localization checks.

No third-party notice or release-script documentation change is needed because the feature adds no dependency and does not alter publishing.

## Testing Strategy

Implementation will follow test-driven development.

### Unit Tests

- Parse valid release tags across multi-digit versions and builds.
- Reject missing prefixes, missing components, prerelease-like tags, invalid numbers, overflow, and trailing text.
- Compare remote builds that are newer, equal, or older than the current build.
- Reject draft/prerelease flags, missing or incomplete `Inklet.dmg`, and unapproved Release URLs.
- Decode a valid GitHub response and handle malformed JSON, oversized data, timeouts, non-2xx status codes, and rate limiting.
- Verify no live network request occurs in tests.

### Coordinator Tests

- A due production launch starts exactly one automatic check after normal startup.
- A recent automatic-attempt timestamp suppresses the startup check and schedules the remaining interval.
- A failed automatic attempt is still throttled for 24 hours.
- Production reschedules after an attempt; local builds never schedule automatic checks.
- Manual checks bypass throttling in both bundles.
- Concurrent automatic and manual triggers share one request, and manual intent receives feedback.
- Automatic up-to-date and error results are silent; manual equivalents present feedback.
- Update presentation opens only the validated GitHub Release URL.
- Menu checking state is stable and restored after success, failure, or cancellation.

### Contract Tests

- Both menus contain the localized update command and share one action.
- All ten localization tables contain the complete update-check key set.
- Public documentation accurately states the check-only behavior and does not claim automatic download or installation.

### Manual QA

- Check from a production build with the current Release, a simulated newer Release, and an offline network.
- Check manually from `Inklet Local` and confirm it never schedules automatic checks.
- Verify update, up-to-date, failure, retry, later, and browser-opening behavior.
- Confirm automatic results do not interrupt voice, selection, migration, or transformation workflows.
- Verify long release notes remain bounded and readable.
- Verify Chinese and English copy fits and all supported languages resolve without English fallback.
- Confirm no DMG or other asset is downloaded.

Before a local app bundle is built for manual QA, increment the patch version in `VERSION` and use `scripts/run-local-app.sh` so the stable signed `/Applications/Inklet Local.app` identity is preserved.

## Alternatives Considered

### Static `latest.json`

A generated manifest could provide a smaller, application-owned schema and avoid depending on GitHub's Release JSON. It would require a stable hosting path and release-workflow changes, which are unnecessary for a check-only first iteration.

### Sparkle In Check-Only Mode

Sparkle provides mature scheduling and version discovery, but it would add a dynamic framework, helper signing, appcast generation, release secrets, and packaging work without using its download and installation value. It is disproportionate to the approved scope.

### Download Or Install The Release

Downloading a DMG would require progress, cancellation, disk-space handling, checksum and code-signing validation, cleanup, and user-consent design. Installing it would additionally require safe app replacement and authorization handling. These remain separate future projects rather than hidden extensions of update checking.
