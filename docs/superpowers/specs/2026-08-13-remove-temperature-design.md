# Remove Temperature Design

## Goal

Remove `temperature` as an Inklet product and request concept. Inklet must no longer expose, persist, pass through, cache by, or send the parameter to any model provider.

This prevents current GPT models from rejecting OpenAI Responses requests that contain an unsupported `temperature` field and keeps the settings UI aligned with actual request behavior.

## Root Cause

`AppConfig` currently persists a global temperature value and the Settings window exposes it as a slider. The value is threaded through writing, selection translation, cache keys, transformation requests, and every provider request body.

`OpenAIProvider.RequestBody.temperature` is non-optional, so JSON encoding always sends the field even when the selected Responses API model does not support it. Hiding only the slider would leave the incompatible request behavior and stale configuration plumbing in place.

## Approaches Considered

### Omit temperature only for known GPT models

Reject. A model-name allowlist or denylist will become stale as new aliases, snapshots, and model families are introduced. The UI would also no longer offer a way to control the value.

### Keep temperature internally but hide the UI

Reject. This preserves dead persisted state and makes request behavior depend on an invisible legacy preference. It also leaves temperature coupled to services and caches even though it is no longer part of the product.

### Remove temperature end to end

Use this approach. Provider APIs select their own default generation behavior when the optional parameter is omitted. Removing the field from all layers gives the codebase one consistent behavior and prevents unsupported-parameter errors without model-specific branching.

## Approved Behavior

Inklet does not display or accept a temperature setting. All writing and selection-translation requests continue to use the selected model, prompts, source text, and timeout, but no temperature value is constructed or passed through the application.

Provider payloads omit the field:

- OpenAI Responses bodies contain `model` and `input`, without `temperature`.
- OpenAI-compatible Chat Completions bodies contain `model` and `messages`, without `temperature`.
- Anthropic Messages bodies keep `model`, `max_tokens`, `system`, and `messages`, without `temperature`.
- Gemini Generate Content bodies keep `systemInstruction` and `contents`. Because temperature is the only current generation-config value, remove the now-empty `GenerationConfig` type and `generationConfig` property rather than encoding an empty object.

Providers therefore use their model-specific default generation behavior. Legacy models may produce somewhat different output than Inklet's former fixed value of `0.2`; this is an accepted trade-off.

## Configuration And Migration

Remove `temperature` from `AppConfig`, its initializer, defaults, coding keys, decoder, and encoder. Do not replace it with another hidden setting.

Existing saved configurations remain readable because Swift's keyed decoding ignores fields that are no longer represented by `CodingKeys`. The old JSON `temperature` member is discarded when the configuration is next saved. No configuration-version bump or explicit migration is required.

Remove temperature normalization from Settings loading and saving. All construction sites for `AppConfig` must compile without a temperature argument.

## Request And Service Boundaries

Remove `temperature` from:

- `TransformationRequest` and its initializer.
- `TransformationService.transform`.
- `SelectionTranslationService.Transform`, `translate`, and provider bridging.
- `CachedSelectionTranslationService.translate`.
- App coordinator, popover, and selection-action call sites.
- OpenAI, compatible chat, Anthropic, and Gemini request-body models and builders.

Timeout, cancellation, error mapping, provider metadata, prompt handling, and response parsing remain unchanged.

## Selection Translation Cache

Remove temperature from `SelectionTranslationCacheKey` and its initializer. The resulting encoded key and SHA-256 hash intentionally change.

Translations cached under the old key will miss once after the upgrade and be regenerated. Existing cache entries are not migrated or deleted eagerly; the current seven-day TTL purge removes them through normal cache access. This avoids special-case migration code for disposable cached data.

## User Interface And Localization

Delete the Temperature settings row, slider, numeric value, and help text. Timeout follows Model directly in the existing restrained Settings layout.

Remove `settings.row.temperature` and `settings.help.temperature` from every language table where they occur. No replacement copy, disabled control, compatibility warning, or model-specific temperature UI is added.

## Documentation

Update `README.md` and `README.zh-CN.md` so their editable-settings lists no longer mention temperature. Update `docs/manual-test-checklist.md` to remove temperature from Settings verification.

No privacy, permissions, provider setup, or installation behavior changes.

## Testing

Follow test-driven development with focused failing tests before production edits.

Provider request tests must encode representative request bodies and assert that the JSON has no `temperature` key. Existing assertions that read request-body temperature values are removed. Gemini tests must assert that the obsolete `generationConfig` object is absent.

Update construction and behavior tests for configuration, transformations, selection translation, and cache keys so their public interfaces no longer accept temperature. Add or update source coverage to assert that Settings does not reference the temperature row or binding.

Compatibility coverage must decode a legacy saved configuration that contains `temperature`, confirm the rest of the configuration survives, then encode it and confirm the obsolete field is absent.

Run:

- Focused provider, configuration, transformation, selection-translation, cache, and Settings source tests during the red-green cycle.
- Complete `swift test`.
- `scripts/run-local-app.sh` for a targeted Settings and writing/selection smoke test.
- `git diff --check` and `git status --short` before completion.

## Manual Verification

- Open Settings and confirm Timeout follows Model with no Temperature row or unexpected spacing.
- Verify the Settings layout at the app's actual window size in English and Chinese.
- Run a writing request with the current default OpenAI model.
- Run selection translation, repeat it to confirm the new cache key hits, and verify audio controls remain unaffected.
- Confirm API errors, cancellation, timeout, retry, insertion, and return-to-idle behavior remain unchanged.

## Out Of Scope

- Replacing temperature with `reasoning.effort`, `text.verbosity`, `top_p`, or another model control.
- Adding per-provider or per-model generation settings.
- Migrating old translation-cache hashes.
- Changing provider selection, default models, prompts, timeouts, or response parsing.
