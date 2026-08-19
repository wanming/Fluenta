# GPT-5.6 Luna Default Model Design

## Goal

Change Inklet's active OpenAI text-generation default from `gpt-5.4-mini` to `gpt-5.6-luna` and migrate existing configurations that still use the former default.

The migration must preserve every other explicitly saved model and must not affect speech transcription or text-to-speech models.

## Approaches Considered

### Change only the preset default

Reject. Fresh and reset configurations would use Luna, but existing users saved with `gpt-5.4-mini` would continue using the former default indefinitely.

### Rewrite `gpt-5.4-mini` on every decode

Reject. This would permanently prevent a user from deliberately selecting `gpt-5.4-mini` again, even after the upgrade migration has completed.

### Use a versioned one-time migration

Use this approach. Increment the app configuration version and migrate the exact former default only when decoding an older configuration. This updates existing default users without treating `gpt-5.4-mini` as permanently forbidden.

## Approved Behavior

- `LLMProviderPreset.openAI.defaultModel` becomes `gpt-5.6-luna`.
- Fresh installations, missing configurations, full resets, and legacy non-OpenAI provider fallbacks use `gpt-5.6-luna`.
- An OpenAI configuration from before this change whose saved model is exactly `gpt-5.4-mini` loads with `gpt-5.6-luna`.
- Older configurations with any other nonempty saved OpenAI model preserve that model unchanged.
- A current-version configuration that explicitly contains `gpt-5.4-mini` preserves it. The migration is an upgrade action, not a permanent ban on the former model.
- Matching is exact and case-sensitive. Namespaced values such as `openai/gpt-5.4-mini`, dated variants, and whitespace-altered strings are not treated as the former Inklet default.

Existing provider selection behavior remains unchanged: Inklet resolves text generation through its active OpenAI Responses preset.

## Configuration And Migration

Increment `AppConfig.currentVersion` from 2 to 3.

During `AppConfig` decoding, retain the original decoded version long enough to select the model:

1. If the decoded provider is not OpenAI, continue using the current OpenAI default, which is now Luna.
2. If the decoded provider is OpenAI and the decoded version is lower than 3 and the saved model is exactly `gpt-5.4-mini`, use Luna.
3. Otherwise preserve the saved OpenAI model, falling back to Luna only when the model field is missing.

The decoder returns the current configuration version as it does today. Migration occurs before any configuration consumer receives the value, so runtime requests never use the migrated `gpt-5.4-mini` value. Persistence continues through the existing configuration save lifecycle; until saved, repeated loads deterministically apply the same migration without mutating storage as a side effect of reading it.

Keep the migration rule local to `AppConfig` decoding. Do not add a `UserDefaults` rewrite pass, launch-time coordinator logic, or provider-specific state outside the configuration boundary.

## Settings And Model Catalog

No Settings layout or copy changes are needed. The model picker and help text already derive the default dynamically from `LLMProviderPreset.openAI.defaultModel`.

Do not edit the bundled model-catalog snapshot for this change. Settings already inserts the preset default when the cached or bundled catalog does not contain it, so Luna remains selectable offline without expanding the scope to a catalog refresh.

Do not remove `gpt-5.4-mini` from available model options. A user may deliberately select it after the one-time migration.

## Error Handling

The migration introduces no new fallible operations. Existing malformed-configuration handling remains unchanged: decoding errors surface through `ConfigStoreError.decodingFailed`, while absent fields use current defaults.

The migration must not make model selection depend on network availability or catalog refresh success.

## Documentation And Localization

No localization table changes are required because the Settings help text interpolates the model ID dynamically and no new user-facing copy is introduced.

No README change is required because `README.md` and `README.zh-CN.md` describe the model as configurable without naming the former default. Their existing statements remain accurate. This is an intentional documentation fallback, not an omitted translation update.

## Testing

Follow test-driven development for implementation.

Add or update focused tests that verify:

- The OpenAI preset and fresh `AppConfig` default are `gpt-5.6-luna`.
- A version-2 OpenAI configuration using `gpt-5.4-mini` migrates to Luna and reports the current config version.
- A version-2 OpenAI configuration using another saved model preserves it.
- A version-3 OpenAI configuration explicitly using `gpt-5.4-mini` preserves it, proving the migration is one-time.
- A legacy non-OpenAI configuration continues to fall back to the current OpenAI default.

Run the focused provider/configuration tests during the red-green cycle, then run complete `swift test`, `git diff --check`, and `git status --short` before completion.

No local app launch is required because the change has no layout or interaction behavior. If manual QA is desired, open Settings after upgrading a version-2 fixture and confirm the model field shows `gpt-5.6-luna` while another custom model remains unchanged.

## Out Of Scope

- Automatic routing between Sol, Terra, and Luna.
- Adding or changing reasoning-effort controls.
- Changing OpenRouter, custom-compatible, speech transcription, or TTS defaults.
- Refreshing the bundled model catalog.
- Removing `gpt-5.4-mini` as an explicit user-selectable model.
