# Context accounting and gateway counting compatibility

Reviewed on 2026-09-16. This document records the limits of the available counting contracts, not a claim that a remote count or tokenizer has been implemented. The deployed gateway was not contacted during this source review.

## What a count describes

Reported request usage, an estimate of the next request's context, live output activity, and completed-request throughput are distinct observations. Gateway-reported input includes cached input; reported output includes reasoning output. Neither breakdown should be added a second time. A future context estimate must describe the actual request selected for replay, rather than assume every previously generated output token is replayed.

Gateway-reported usage is not independently verified billing. Context estimates remain estimates unless a compatible counting contract establishes otherwise. In particular, a model alias and a successful HTTP response do not establish the identity of an automatically selected backend.

## Scope and lifetime fix in 0.1.66

The footer and primary Context Inspector header share one `ContextPresentation`
resolver. An active request's estimate/report is bound to its runtime epoch,
generation, attempt and dispatch capacity. A completed request is explicitly
historical while tools run. Idle counts describe a matching next-input preview;
changed drafts show pending rather than borrowing the last request's usage.

Preview validity uses committed replay-input revision and effective configuration,
resource/tool/authorization and draft bindings, not the general event sequence.
Opening or closing the inspector cannot write the preflight count. A compact
versioned context envelope is independent of transcript and accounting payloads.
The helper publishes preparing state before recorder waits and captures context
state before awaited trace reads. Successful compaction alone invalidates replay;
failed/cancelled summaries do not replace input or generation usage.

See [CTX-01–CTX-20 evidence and limitations](Context-Meter-Fix-2026-09-20.md).
This fixes freshness/scope, not tokenizer accuracy or automatic-route capacity.

## Implemented in 0.1.17

`RequestContextCounter` consumes the provider request builder's output. The context ring, prepared inspector, dispatch preflight, retained-context sizing, and compaction-summary preflight use this service. Its result includes tokens, method, requested/counted model, a request fingerprint, uncertainty warnings, capacity, requested output budget, and safety margin. Opening an idle chat or changing its draft schedules the existing debounced preview; while a changed request is being prepared, the ring shows a pending count rather than another formula's result.

The fingerprint includes the complete request and effective profile, including instructions, actual tool schemas, images, replayed items, reasoning settings, route, limits, and revision. Only the hash is exposed. A bounded, five-minute cache also keys on usage-baseline evidence, so newly reported usage invalidates an earlier estimate of the same request.

A usage baseline is accepted only for an explicitly pinned route whose reported model matches the expected model, an unchanged request template, and an exact ordered prefix of previously sent input. It reuses gateway-reported input and estimates only newly replayed items. It never adds all previous output or adds cached Responses input again. Changed instructions, tools, configuration, or prefix reject the baseline. All such results still carry `estimated: true`.

Without a valid baseline, the heuristic counts the serialized model-facing request fields at UTF-8 bytes / 3, including actual schemas rather than a fixed tool allowance. It excludes image base64 from text, reads image dimensions locally, applies documented tile formulas only to explicitly pinned `gpt-4o`, `gpt-4.1`, and `gpt-4o-mini` routes, and labels other image and opaque-reasoning allowances as uncertain. The newer patch-model formulas discussed below are research findings, not implemented tokenizer support.

Catalog `maxOutputTokens` now means the supported model ceiling. The configured request budget remains separate and is clamped downward when necessary; selecting a large-capacity model does not raise that budget automatically. Input capacity is context capacity minus the requested output budget and a safety margin of 1%, capped at 1,024 tokens. This remains a product policy applied to an estimate, not a guarantee that every router backend will fit.

If gateway compatibility disables `max_output_tokens`, the budget remains a local reserve and the result explicitly warns that it is not sent as a server-enforced cap. Explicit-skill draft previews also use a placeholder turn identifier inside the expanded skill text; delivery inserts the real turn identifier and recomputes the count/fingerprint. Equality with captured bytes is tested for a draft without that delivery-specific expansion. The inspector preview can therefore differ from a later captured request while still using the same accounting service.

Legacy per-chat catalog ceilings migrate into the new ceiling field, using the configured profile budget for future requests. Existing queued turns retain their frozen parameters. Legacy profile budgets are preserved because stored records cannot distinguish a deliberate user setting from a previous catalog default. Title and connection-test tasks keep their smaller explicit budgets.

Deterministic tests compare a prepared count with dispatch preflight and independently captured HTTP request bytes against a request-validating loopback gateway. They cover cache/reasoning accounting, changed request inputs, rejected routed baselines, images, output-budget migration, and over-capacity tool schemas. No live deployed-gateway compatibility claim is made.

## LiteLLM contract findings

The owner's example identifies LiteLLM 1.99.0. The public `v1.99.0` tag resolves to commit `fa647f742d7baefe8eb1181899d9c81b41559772`. A separate check of current `main` used commit `9cd787386ea43aa9d6b18d8f31d7528a020a0622`; conclusions about that newer source must not be projected onto every deployed 1.99.0 installation.

### `/utils/token_counter` does not accept a complete Responses request

The 1.99.0 request schema accepts `model`, `prompt`, `messages`, `contents`, `tools`, and `system`. It does not define Responses `input`, `instructions`, `reasoning`, or the opaque input items our replay builder may retain. Supplying the original Responses request cannot establish a count of that request. Converting it into chat messages would introduce another transformation that needs independent validation. [Pinned request schema](https://github.com/BerriAI/litellm/blob/fa647f742d7baefe8eb1181899d9c81b41559772/litellm/proxy/_types.py#L3260)

`call_endpoint=true` enables an attempt to use a supported provider counter; it does not guarantee success or prohibit local fallback. The router chooses one available deployment for this operation. Its local fallback calls the tokenizer with the prompt and messages, without forwarding the separate `tools`, `system`, or `contents` fields. It does not bind a later generation request to the counted deployment. [Pinned endpoint implementation](https://github.com/BerriAI/litellm/blob/fa647f742d7baefe8eb1181899d9c81b41559772/litellm/proxy/proxy_server.py#L11912)

The generic response contains `request_model`, `model_used`, `tokenizer_type`, optional `original_response`, and error/status fields. Those observations would be necessary provenance for a compatible adapter, but they cannot fix missing or transformed request content. [Pinned response schema](https://github.com/BerriAI/litellm/blob/fa647f742d7baefe8eb1181899d9c81b41559772/litellm/types/utils.py#L3872)

### The provider-side OpenAI counter does not preserve our request

The OpenAI counter in 1.99.0 accepts chat messages and reconstructs Responses input before calling the upstream counting API. [Pinned provider counter](https://github.com/BerriAI/litellm/blob/fa647f742d7baefe8eb1181899d9c81b41559772/litellm/llms/openai/responses/count_tokens/token_counter.py)

That conversion extracts text from user content arrays, omitting non-text image blocks. It has no representation for the full Responses reasoning/replay configuration. Its outgoing body includes only model, input, instructions, and tools. The existence of an upstream counting endpoint therefore does not make this conversion request-equivalent. [Pinned transformation](https://github.com/BerriAI/litellm/blob/fa647f742d7baefe8eb1181899d9c81b41559772/litellm/llms/openai/responses/count_tokens/transformation.py)

### The newer `/responses/input_tokens` wrapper loses provenance

The reviewed 1.99.0 Responses proxy module does not register an input-token-count route. [Pinned 1.99.0 routes](https://github.com/BerriAI/litellm/blob/fa647f742d7baefe8eb1181899d9c81b41559772/litellm/proxy/response_api_endpoints/endpoints.py)

The reviewed newer implementation does register it, but first converts Responses input into chat messages, passes instructions through that conversion, then invokes the generic counter with `call_endpoint=true`. It extracts only model, input, instructions, and tools from the submitted body. Its response exposes `object` and `input_tokens`, discarding the generic counter's model and tokenizer provenance. A caller cannot distinguish local fallback from provider counting using that response. This is an inference from the complete wrapper and generic implementation, not a live compatibility test. [Pinned newer wrapper](https://github.com/BerriAI/litellm/blob/9cd787386ea43aa9d6b18d8f31d7528a020a0622/litellm/proxy/response_api_endpoints/endpoints.py#L1076)

### Application policy

Do not call either endpoint automatically for the context meter. The shared accounting path reports `countEndpointStatus: unverified-request-compatibility` and explains that a compatible gateway count is unavailable. It uses a clearly labeled local estimate instead. No adapter should silently turn Responses input into chat messages, infer provider counting from the query flag, or label a local tokenizer fallback as provider-exact.

Before adding an optional adapter, establish all of the following with the gateway owner and deterministic HTTP fixtures:

- The counted model-facing request preserves instructions, tools, images, structured output, selected reasoning configuration, and retained provider state; fingerprint the same request used by execution.
- The result identifies the requested alias, actual counted model, method/tokenizer, fallback status, and request fingerprint. Missing or contradictory provenance must reject the remote result.
- Automatic routing binds counting and generation to the same route, or validates each candidate against its own capacity. A previous response's model name does not bind a new request.
- Requests are limited to the configured gateway origin, with no cross-origin credential forwarding, bounded timeout/body sizes, cancellation, and no sensitive payload logging. Cache by complete fingerprint and debounce refreshes.

These are integration criteria. This change does not implement or enable a provider-count or tokenizer endpoint.

## Image-counting policy

Image bytes are not text tokens. Prefer dimensions read from the actual local image payload; do not tokenize base64 or fetch remote image URLs merely to update a context meter. Unknown dimensions, unknown model identity, and opaque replay must remain visible sources of uncertainty.

The current official guide documents 32-pixel patches for `gpt-5.4`, `gpt-5.4-mini`, and `gpt-5.4-nano`, with a 1.2 multiplier rounded up. High/auto detail fits within 2048 pixels and 2,500 patches; original detail permits 6000 pixels and 10,000 patches. Low detail has different limits, so it is not universally cheaper. Tile models have different rules: `gpt-4o`/`gpt-4.1` use 85 base plus 170 per tile, while `gpt-4o-mini` uses 2,833 plus 5,667. High/auto sizing fits within 2048 pixels, then caps the shorter side at 768 pixels, and counts 512-pixel tiles. Smaller images are not enlarged. Low detail uses only the tile model's base count. [Official image sizing and token calculations](https://developers.openai.com/api/docs/guides/images-vision#calculating-costs)

Consequently, 4,096 tokens per image is not a universal upper bound. Named formulas should only be enabled for an explicitly verified model route and supported detail mode. A router alias must not inherit a formula from its last reported backend. A dimension-aware fallback is still a heuristic, not proof that every possible route fits. Preserve that distinction in UI and preflight metadata.

## Source integrity

SHA-256 of retrieved source bytes, for repeatable review:

| Revision | File | SHA-256 |
| --- | --- | --- |
| 1.99.0 | `litellm/proxy/proxy_server.py` | `f63cd83c5c4459d84dbfbd350a460caf9e2907389f19d2c3090fe24ad937f47b` |
| 1.99.0 | `litellm/proxy/_types.py` | `3f9eda5af72454e46ccc9264196ba36ba490846631528b557e01fcdb9e83ec7f` |
| 1.99.0 | `litellm/types/utils.py` | `d29cc191ffba594996589148f541ccca01a67ad7e5895a03eee1c5ace41adbb0` |
| 1.99.0 | `litellm/llms/openai/responses/count_tokens/token_counter.py` | `91dc6e0680c7621262c1808152f95c4349b644dae7d089ff1d613d96f3df9b8c` |
| 1.99.0 | `litellm/llms/openai/responses/count_tokens/transformation.py` | `9d078c380e1d9a1a707f8ef2de73ab5e639b05a7776d0e19e99d17349b7229e3` |
| 1.99.0 | `litellm/proxy/response_api_endpoints/endpoints.py` | `563b462e7c36e729869d0acdc016a54c2e99ec07f70a3f6ea17482b1dbf11e4f` |
| main `9cd7873` | `litellm/proxy/response_api_endpoints/endpoints.py` | `f5aeb89d3a9937407bd3d84ab76b3eb9060dd497910a5110fa6a58a63e670fb1` |
