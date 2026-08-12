# Contributing

Thanks for your interest in Inklet. This project is a native macOS Swift app, and contributions are welcome.

## Development Setup

Requirements:

- macOS 14 or newer.
- Swift 6 toolchain.
- Full Xcode is recommended for XCTest support.

Build:

```bash
swift build
```

Build, install, and run the local app:

```bash
scripts/run-local-app.sh
```

Use the installed `/Applications/Inklet Local.app` for local testing.

This is the routine QA workflow from every worktree. `scripts/run-local-app.sh` builds and verifies the local bundle, installs it at the stable path, and uses the configured stable signing identity so macOS can retain Accessibility and Keychain trust. Do not use an ad-hoc-signed or worktree-local app for routine QA. Use `scripts/reset-rebuild-install.sh` only for intentional first-launch or permission-reset testing because it removes local state by design.

Run tests:

```bash
swift test
```

Run the stricter build used before release:

```bash
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

## Pull Request Guidelines

- Keep changes focused and easy to review.
- Add or update tests for behavior changes.
- Keep user-facing behavior accessible by keyboard.
- Do not commit local build output, `.dmg` files, `.worktrees/`, `.build/`, API keys, tokens, or personal configuration.
- Update documentation when changing install, setup, provider, or release behavior.
- Use English for documentation and project-facing prose.

## Distribution And Release Changes

Inklet ships directly as a signed and notarized GitHub Releases DMG. Keep distribution changes aligned with the active scripts documented in [scripts/README.md](scripts/README.md), the standalone installer contract, and the release workflow in [.github/workflows/build-dmg.yml](.github/workflows/build-dmg.yml).

Before proposing a release-sensitive change, run the focused shell contracts, `swift test`, the strict build above, and `git diff --check`. Do not publish or claim a release from local QA results; the release workflow must still complete signing, notarization, stapling, Gatekeeper, mounted-app, and checksum verification for the final artifact.

## Security and Privacy Expectations

- Do not log API keys, prompts, source text, generated text, clipboard contents, or selected text.
- Keep API keys local to the user's machine.
- Treat Accessibility, clipboard, and text insertion flows as sensitive surfaces.

## Manual QA

Before submitting a user-facing change, run through the relevant items in [docs/manual-test-checklist.md](docs/manual-test-checklist.md).
