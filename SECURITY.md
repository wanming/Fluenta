# Security Policy

## Supported Versions

Inklet is currently an early MVP. Security fixes target the latest commit on `main`.

## Reporting a Vulnerability

Please report security issues privately instead of opening a public issue.

Use **Report a vulnerability** on the repository's Security tab when GitHub private vulnerability reporting is available. If that private flow is unavailable, contact the repository maintainer through GitHub before sending sensitive reproduction material. Do not post secrets, private text, migration data, or an exploitable report in a public issue or discussion.

Please include:

- A clear description of the issue.
- Steps to reproduce.
- Affected macOS version, Inklet version or commit, and relevant provider configuration.
- Any logs or screenshots that do not include secrets or private user text.
- Whether the report concerns a source build, `/Applications/Inklet Local.app`, or a signed release artifact.

## Sensitive Data

Inklet handles text that users type, select, transform, and paste. It also stores provider API keys locally. Security-sensitive areas include:

- Provider API-key storage in the production and local Keychain services.
- Production/local bundle-qualified storage for preferences, History, translation cache, and diagnostics.
- Automatic and user-assisted legacy migration, including source validation, conflict handling, atomic writes, and preserving the legacy source.
- Selection reads bound to the captured source process and cancelled when the source exits or loses focus.
- Clipboard transaction serialization, operation ownership, and conditional clipboard restoration when another app or the user changes the pasteboard.
- Accessibility and Microphone permission usage.
- Selected text capture, local History retention, provider request construction, and temporary voice audio.
- Signed and notarized direct releases, Hardened Runtime and effective-entitlement checks, Gatekeeper/stapling checks, the release verifier, and the standalone installer.

Do not include real API keys, private text, or personal data in bug reports.

## Release And Local-Build Trust

Public releases are expected to come from the GitHub Releases DMG and pass the repository's checksum, DMG, signature, notarization, stapling, Gatekeeper, bundle-identifier, Hardened Runtime, and entitlement gates. A report involving an installed release should include the release version and whether the artifact came from that channel, but should not paste certificate identities or other signing metadata.

Routine source QA uses the stable `/Applications/Inklet Local.app` bundle and its separate local storage and Keychain identity. Do not weaken signature or verification checks, clear quarantine, or use an ad-hoc identity to make a security-sensitive failure disappear.
