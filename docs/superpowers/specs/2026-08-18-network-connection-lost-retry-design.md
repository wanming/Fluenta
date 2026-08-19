# Network Connection Lost Retry Design

## Goal

Make Inklet text transformations resilient to the transient
`NSURLErrorDomain` code `-1005` ("The network connection was lost") failures
that users encounter during writing transformations.

Inklet should recover silently from one interrupted connection when possible,
preserve the existing cancellation and total-timeout behavior, and show a
localized message instead of a raw Foundation error when recovery fails.

## Root Cause

Apple defines `URLError.networkConnectionLost` as a client or server connection
being severed during an in-progress load. `waitsForConnectivity` only applies
while establishing a connection and does not recover a connection that drops
after a request has begun.

Every Inklet LLM provider currently calls `URLSession.data(for:)` once and lets
transport errors escape unchanged. Text-generation requests use `POST`, which
Foundation cannot always retry automatically because the server may have
already received the request. The raw error then reaches the writing popover's
generic error formatting path.

References:

- [Apple: `networkConnectionLost`](https://developer.apple.com/documentation/foundation/urlerror/code/networkconnectionlost)
- [Apple: `waitsForConnectivity`](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/waitsforconnectivity)

## Approaches Considered

### Retry in each provider

This keeps the retry close to `URLSession`, but duplicates the policy across
OpenAI, Anthropic, Gemini, and OpenAI-compatible providers. A transport helper
also lacks the semantic context needed to decide whether repeating a `POST` is
acceptable.

### Retry at the transformation-service boundary

Use this approach. `TransformationService` represents one user-requested text
transformation and already owns the operation-wide timeout and cancellation
race. It can declare that one repeat of this specific semantic operation is
acceptable while keeping all attempts inside the original time budget.

This location also applies the same policy consistently to every LLM provider
without affecting unrelated audio requests.

### Configure a custom session or add broad network retries

Reject for this fix. `waitsForConnectivity` does not address an established
connection dropping, and retrying timeouts, offline errors, HTTP failures, or
other transport codes would broaden latency and duplicate-request risk beyond
the reported failure.

## Approved Behavior

For each `TransformationService.transform` call:

1. Validate and normalize the source text as today.
2. Start the existing operation-wide timeout race.
3. Ask the provider to perform the transformation.
4. If the provider throws exactly `NSURLErrorDomain` code `-1005`, check task
   cancellation and immediately make one final provider attempt.
5. Return a successful result normally.
6. If the final attempt also fails with `-1005`, throw a semantic
   `TransformationError.networkConnectionLost` error.
7. If the final attempt fails for any other reason, propagate that final error
   unchanged through the existing error path.

The total attempt count is at most two. The retry has no independent delay or
timeout. Both attempts run inside the original `timeoutSeconds` budget, so a
20-second transformation cannot become a 40-second transformation.

The retry classifier uses the bridged `NSError` domain and code so it matches
the Foundation error form observed in production:

- Domain must equal `NSURLErrorDomain`.
- Code must equal `URLError.networkConnectionLost.rawValue` (`-1005`).

No automatic retry occurs for:

- Parent-task cancellation or `URLError.cancelled`.
- `URLError.timedOut`.
- `URLError.notConnectedToInternet`.
- Connection, DNS, TLS, or certificate errors other than `-1005`.
- HTTP status failures.
- Provider error payloads.
- Response decoding failures or empty model output.

## Scope

The policy applies to every LLM text transformation that already uses
`TransformationService`:

- Writing transformations.
- Selection translation.
- Voice-transcript cleanup after transcription.

It does not change:

- Speech transcription uploads.
- Text-to-speech and pronunciation requests.
- Model-catalog refreshes.
- Clipboard, insertion, or Accessibility behavior.

No new setting is added. The retry count is intentionally not configurable.

## Cancellation And Timeout Semantics

The retry loop remains inside the operation task managed by the existing
`withTimeout` race. The timeout task therefore continues to cancel whichever
attempt is active when the original deadline expires.

The service calls `Task.checkCancellation()` before starting a retry. If the
parent task is cancelled after the first failure, cancellation wins and no
second provider request begins. The existing writing-popover Escape behavior
continues to cancel the transformation without presenting an error.

## Error Presentation And Localization

Add `TransformationError.networkConnectionLost` to distinguish exhausted
transient recovery from generic provider failures.

When both attempts fail with `-1005`, the writing UI displays the localized
equivalent of:

> The network connection was interrupted. Please try again.

Add the corresponding localization key to every language table supported by
`InkletLocalization.swift`. Do not expose `NSURLErrorDomain`, `-1005`, request
URLs, API keys, or request content in the user-facing message.

Other error presentation remains unchanged.

## Duplicate-Request Trade-Off

A dropped connection does not prove that the provider failed to receive or
process the first `POST`. Retrying can therefore produce a second billable
generation in a small number of cases.

Inklet accepts this trade-off for interactive text transformations because the
operation has no local destructive side effect and recovery avoids frequent
user interruption. Limiting recovery to exactly one retry and exactly error
`-1005` bounds the duplicate-request and billing risk. Inklet must not add a
third attempt or silently broaden the set of retryable errors as part of this
change.

## Testing

Add focused executable tests before production changes.

`TransformationServiceTests`:

- A first `URLError.networkConnectionLost` followed by success returns the
  successful result and records exactly two provider attempts.
- Two consecutive `URLError.networkConnectionLost` failures stop after two
  attempts and throw `TransformationError.networkConnectionLost`.
- A different `URLError` is propagated after exactly one provider attempt.
- Cancellation detected after the first `-1005` prevents the second attempt and
  throws `CancellationError`.
- A slow retry remains bounded by the original operation timeout and throws
  `TransformationError.timeout` promptly.
- Existing success, empty-response, timeout, and cancellation tests continue to
  pass.

Localization tests:

- Every supported language table contains the new network-interruption key.
- The writing-popover error mapping resolves
  `TransformationError.networkConnectionLost` through that key rather than a
  raw Foundation description.

Final automated verification:

- Run focused transformation and localization tests.
- Run `swift test`.
- Run `git diff --check`.
- Inspect `git status --short` and confirm no unrelated files changed.

Manual QA, if performed, must use `/Applications/Inklet Local.app` through
`scripts/run-local-app.sh` after the required `VERSION` increment. Verify that
Escape still cancels an active transformation, a recovered first connection
loss produces no error or layout shift, and a repeated connection loss displays
the localized message while keeping the source text available for retry.

## Documentation And Privacy

No README or privacy-policy update is required. This is an internal reliability
correction with no new feature setting, provider, permission, data flow, or
stored diagnostic data. Existing public setup and privacy descriptions remain
accurate.
