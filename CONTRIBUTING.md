# Contributing

Thanks for your interest in Inklet. This project is a native macOS Swift app, and contributions are welcome.

## Development Setup

Requirements:

- macOS 14 or newer.
- Swift 6 toolchain.
- Full Xcode is recommended for XCTest support.

Build and run:

```bash
swift build
scripts/run-local-app.sh
```

The local runner installs and launches the stable `/Applications/Inklet Local.app` identity so Accessibility and Keychain approvals can be reused across rebuilds.

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

## Security and Privacy Expectations

- Do not log API keys, prompts, source text, generated text, clipboard contents, or selected text.
- Keep API keys local to the user's machine.
- Treat Accessibility, clipboard, and text insertion flows as sensitive surfaces.

## Manual QA

Before submitting a user-facing change, run through the relevant items in [docs/manual-test-checklist.md](docs/manual-test-checklist.md).
