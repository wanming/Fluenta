# Agent Instructions

Before any response or action, use the relevant `superpowers` skill.

## Workflow

- For every task, work in a dedicated linked Git worktree. Before editing, detect whether the current checkout is already isolated; if it is not, create a worktree and do not edit the primary checkout directly.
- Inspect relevant files and `git status` before editing. Preserve unrelated user work.
- State relevant assumptions before editing, and ask only when a safe assumption is not possible.
- Prefer the smallest surgical change that satisfies the request; avoid speculative abstractions and unrelated refactors.
- Match existing Swift, SwiftUI, naming, formatting, and file-organization patterns before introducing anything new.
- Add or update focused tests for behavior changes when practical.

## Running The App

- When asked to run Inklet locally, prefer the `/Applications/Inklet Local.app` workflow instead of `swift run Inklet` or an ad-hoc `dist/dev-run` bundle.
- Before every Inklet app bundle build, update `INKLET_VERSION` in the root `VERSION` file. Increment the patch version by default, the minor version for a substantial new feature, and the major version for broad or breaking changes; reset lower-order components to zero when incrementing minor or major.
- Build, install, and launch the local bundle with `scripts/run-local-app.sh`.
- Before every app launch, check whether the matching Inklet process is already running and stop it if necessary before starting a new instance. `scripts/run-local-app.sh` already handles this for `Inklet Local`; do not bypass its shutdown check.
- The local runner must use a stable signing identity from `INKLET_LOCAL_SIGN_IDENTITY`, `INKLET_SIGN_IDENTITY`, or an automatically detected local code signing identity hash. Do not use ad-hoc signing for normal local runs because macOS may ask for Accessibility permission again after each rebuild.
- The local bundle uses `com.tomwan.inklet.local` and the separate `Inklet.Local.ProviderAPIKey` Keychain service so local runs do not request the production `Inklet.ProviderAPIKey` item.
- If `/Applications` is not writable, use `sudo` only for the `rm -rf` and `ditto` install steps. Do not print or commit signing identities or other local-only values.

## Product Quality

- Treat localization as part of every user-facing copy change. Update all supported language tables, or explicitly document an intentional fallback.
- Keep UI consistent with the existing Inklet style: restrained macOS settings aesthetics, shared theme colors, consistent typography, spacing, controls, and alignment.
- Favor clarity over decoration. Do not add flashy effects, oversized cards, gradients, or new visual motifs unless the product already uses them.
- For SwiftUI layout changes, verify text fits in Chinese and English, avoids overlap, and behaves at the app's actual window size.
- Treat Accessibility, clipboard, text insertion, voice audio, and API key flows as sensitive surfaces.

## Interaction Details

- Fully think the interaction details for each features' each step before editing: idle, hover/focus, pressed, loading, playing, success, error, cancellation, dismissal, retry, and return-to-previous-state behavior.
- Prefer compact icon-only controls for repeated utility actions inside small popovers. Keep visible text for primary command buttons only when it improves first-use clarity.
- Every icon-only control must have a tooltip/help label and an accessibility label that names the action.
- Loading feedback should replace the current icon in place with a spinner, keeping the button size stable and avoiding added text or layout shifts.
- Playing feedback should replace the current audio icon in place with a playing-state icon, keeping the current content visible while audio plays.
- Success feedback should replace the current icon in place for a short confirmation interval, such as showing a copied/checkmark icon after copy, then restore the idle icon automatically.
- For Selection Actions, the first menu remains compact with Translate and Pronounce. Translation results keep the translated text visible while copy, original-audio, and translated-audio controls change only their own icons for loading, playing, copied, or error-adjacent states.
- Settings preview controls follow the same icon-state model: speaker icon when idle, spinner while generating audio, playing icon while audio is playing, then restore the idle icon when playback finishes.

## Documentation And Privacy

- Update `README.md` and `README.zh-CN.md` when changing features, setup, permissions, providers, install steps, or release behavior.
- Keep public documentation accurate to shipped behavior. Remove stale instructions in the same change.
- Never commit personal or private operational data: names, personal email or phone numbers, Team IDs, reviewer credentials, API keys, certificates, signing identities, or submission notes.
- Store local-only notes under `.private/`. Store secrets in Keychain, `.env.local`, or the relevant external service.
- Add an ignore rule before creating a new private local artifact. Never commit `.private/`, `.env.local`, `*.p8`, `*.p12`, provisioning profiles, or generated packages.

## Verification

- Define verification before editing, then run the narrowest relevant checks.
- Do not invoke the `computer-use` skill or tool to test Inklet. Use automated tests and scripts, and leave any required visual or interaction checks as an explicit manual QA checklist for the user.
- Run `swift test` for code changes. Use targeted app launches and the manual checklist for user-facing workflows.
- For routine local app hand-testing from any worktree, run `scripts/run-local-app.sh`. Do not launch worktree-local `dist/...` apps or ad-hoc signed bundles, because macOS treats each path, bundle identifier, and signing requirement as a different app for Accessibility and Keychain trust.
- Keep local hand-test builds on the stable identity `/Applications/Inklet Local.app` with bundle identifier `com.tomwan.inklet.local` and a real signing identity from `.env.local`, the environment, or local signing identity auto-detection. After the first Accessibility and Keychain approval, reuse this path so future worktrees do not prompt again.
- Use `scripts/reset-rebuild-install.sh` only for intentional first-launch or permission-reset QA, because it clears local permissions and Keychain state by design.
- For release-sensitive changes, also run strict builds, signature checks, or script checks as applicable.
- Before finishing, inspect `git diff --check` and `git status`. Report any unverified area or remaining risk.

## Commits

- Keep each commit focused on one logical purpose. Do not mix cleanup with unrelated behavior changes.
- Use an English imperative subject, sentence case, no trailing period, ideally under 72 characters. Example: `Fix installer checksum validation`.
- Review the staged diff before committing. Exclude generated files, local configuration, credentials, and unrelated user changes.
