# Scripts

This directory is split by workflow. Prefer the smallest script that matches the job.

## Direct Bundle

- `build-macos-app-bundle.sh` builds and signs an Inklet `.app` in `dist/direct/` by default. Pass `INKLET_OUTPUT_DIR` to select another output directory.
- `verify-direct-app.sh` checks a direct-distribution bundle's identifier, signature, Hardened Runtime, entitlements, privacy metadata, and release signing policy.

## Public Install

- `install.sh` downloads the latest notarized GitHub Releases DMG, verifies its checksum, Gatekeeper acceptance, and app signature, then installs Inklet.

## Local QA

- `run-local-app.sh` is the routine hand-testing path for agents and worktrees. It builds, verifies, installs, and opens `/Applications/Inklet Local.app` with the `com.tomwan.inklet.local` bundle identifier. It uses a stable signing identity so macOS can preserve Accessibility permission across rebuilds.
- `reset-local-state.sh --scope local|production|all` performs an explicitly scoped destructive reset of preferences, Accessibility and Microphone permissions, the matching Keychain API key, app data, and selection diagnostics. Add `--remove-installed-app` to remove only the app selected by the scope, or `--dry-run` to inspect every exact target without changing state.
- `reset-rebuild-install.sh` runs the destructive local first-launch flow: reset only local state, remove `/Applications/Inklet Local.app`, then rebuild, reinstall, and open it through `run-local-app.sh`.

## Checks

- `check-localization.sh` validates permission string files and runs localization coverage, language switching, and native layout regression tests. Add `--snapshots` for a synthetic offscreen UI gallery; it prints the generated HTML path. It does not launch Inklet or read saved writing/history. Settings fixtures can read microphone names and the current permission status.
- `test-direct-distribution.sh` checks the direct-distribution bundle and verifier contracts.
- `test-install-security.sh` checks safety invariants in `install.sh`.
- `test-run-local-app.sh` checks that local app runs use stable signing, local bundle settings, and redacted signing logs.
- `test-reset-local-state.sh` checks exact reset scopes, targets, and destructive-command safety.

## Assets

- `generate-app-icons.swift` regenerates app icon PNGs, preview, and `.icns` from `Assets/PenNib.svg`.
