# LiteLLM cost and cache accounting

Checked 2026-09-15 against upstream commit
`9496f16f1270b3435dff76e5d90753398453f42b`. This is a source contract and local
fixture verification, not a claim about an unconfigured live deployment.

## What the gateway reports

Responses terminal events (`response.completed`, `response.incomplete`,
`response.failed`) can include `response.usage.cost`. At this revision the
Responses iterator stamps calculated positive cost into the usage object and
preserves an existing numeric value. An absent field therefore does **not**
establish a free request. See the pinned
[Responses iterator](https://github.com/BerriAI/litellm/blob/9496f16f1270b3435dff76e5d90753398453f42b/litellm/responses/streaming_iterator.py#L1332).

For the Messages streaming path, the shared proxy processor can inject
`message_delta.usage.cost` when `include_cost_in_streaming_usage` is enabled.
Bello Agent counts the delta carrying a nonempty `stop_reason`, excluding interim usage.
Pricing or usage may still be unavailable. Check the deployed version and its
actual final SSE event. The setting is exposed in LiteLLM configuration as:

```yaml
litellm_settings:
  include_cost_in_streaming_usage: true
```

Sources: pinned [cost injection](https://github.com/BerriAI/litellm/blob/9496f16f1270b3435dff76e5d90753398453f42b/litellm/proxy/common_request_processing.py#L3837)
and [configuration example](https://github.com/BerriAI/litellm/blob/9496f16f1270b3435dff76e5d90753398453f42b/litellm/proxy/example_config_yaml/pass_through_config.yaml).
Current new requests use Responses only; Messages handling above is retained historical compatibility evidence. Bello Agent does not add Chat Completions-only `stream_options` to Responses.

The documented `x-litellm-response-cost` response header is supported for JSON
responses. For SSE it arrives before generation finishes and may be a zero
placeholder; Bello Agent retains that observation in Inspector but excludes it from
final cost. See [LiteLLM response headers](https://docs.litellm.ai/docs/proxy/response_headers).

There is no assumed universal boolean cache-hit header in this contract.
Configure **Cache result header** and a deployment reference in the native
routing settings when the gateway supplies one. Values `HIT`, `MISS`, `true`
and `false` are accepted without regard to case. For the local fixtures the
header is `x-fixture-cache`; that name is a fixture convention, not an upstream
LiteLLM guarantee. A cache key, zero cost or provider prompt-cache token count
does not prove a gateway response-cache hit.

## App representation and counting

Each HTTP attempt carries `metadata.gateway.version = 1` with:

- `cost.usd`, `cost.status`, `cost.source` and bounded evidence. Status is
  `reported`, `unreported`, `invalid` or `conflict`; unknown amounts stay null.
  Explicit zero is a reported sample. `usage.response_cost` is also accepted
  as a compatibility field and disagreement with `usage.cost` is a conflict.
- `cost.streamingHeaderUSD`, for Inspector only; never added to reported USD.
- `cache.status` (`hit`, `miss`, `unreported`, `invalid` or `conflict`) and source.
- Optional bounded `callId` and `gatewayVersion`, when the gateway supplies them.

The app does not estimate prices. Duplicate terminal observations are not
charged twice; invalid, negative, nonfinite, excessively large or conflicting
amounts are excluded from totals. Session/report totals deduplicate local
request IDs and show sample coverage, including requests with unavailable cost.
Message costs refer to the requests producing that message. Tool cycles and
compaction can create multiple requests. Gateway retries/upstream calls are
not individually observable at this local HTTP boundary.

Provider cache-read/cache-write tokens remain separate from the gateway
response-cache hit/miss indicator. Missing token fields stay unavailable.
Stopping before a cost-bearing terminal event leaves cost unknown; the app
does not equate cancellation with zero charges.

Exact response bytes remain unchanged. Request auth headers contain SHA-256
fingerprints; known credential literals in captured request bodies are also
hashed and the resulting non-exact capture is labeled. Credentials are not
included in fixture diagnostics or accounting metadata.

## Local acceptance

`scripts/test-native-host.py` runs the optimized helper against a loopback fake
gateway. Its shared `fixtures/native/litellm_contract.py` validates POST routes,
native API fields, alias, stream flag, output limits, authentication, custom
headers, tool schemas and complete matching tool-call/result history before
the fixture responds. It rejects malformed requests with HTTP 422.

Request-aware scenarios cover both APIs, actual README read results, portable
and pinned opaque continuations, tool-free compaction from original history,
Unicode streaming, request-keyed cache MISS/HIT, reported/zero/unknown/invalid/
conflicting costs, HTTP errors and cancellation. Negative probes mutate real
outgoing requests, including their tool IDs/results and replay items. Captured
wire bodies and acknowledged durable byte packets are compared exactly, with
the explicit credential-hashing exception tested separately.

Run:

```sh
swift test --package-path packages/swift-host
swift build -c release --package-path packages/swift-host
python3 scripts/test-native-host.py packages/swift-host/.build/release/pi-native-host
```

These fixtures make no outbound model calls and use only synthetic keys. They
are an independent application request oracle, not an installed LiteLLM server
or a substitute for verifying a particular deployed gateway version.

## Owner-supplied LiteLLM 1.99.0 response contract (2026-09-16)

The owner supplied two Responses JSON examples, plus headers for the second.
These are concrete gateway observations, not proof of every LiteLLM deployment.
Minimal synthetic fixtures preserve the relevant fields and exclude the original
opaque reasoning payload, identifiers and account-wide key-spend balance.

| Field | First body | Second body / headers |
| --- | --- | --- |
| Requested/body model | auto-router | auto-router |
| router_model_name | gpt-5.4-mini | gpt-5.4-mini |
| Input / output / total tokens | 38 / 423 / 461 | 38 / 302 / 340 |
| Reasoning tokens (part of output) | 326 | 253 |
| Cached input / cache-write tokens | 0 / 0 | 0 / 0 |
| usage.cost | null | null |
| x-litellm-response-cost | not supplied | 0.0013875 USD |
| x-litellm-response-cost-input | not supplied | 0.0000285 USD |
| x-litellm-response-cost-output | not supplied | 0.001359 USD |
| x-litellm-response-cost-reasoning | not supplied | 0.0011385 USD |

For the final JSON response, the total cost header supplies the cost even when
`usage.cost` is null. Reasoning tokens are included in output tokens, and the
reasoning cost header is an output-cost subset. Neither is added to the total.
The classifier cost, original/discount/margin fields and account-wide key spend
are not additional request charges. Their inclusion in billing cannot be inferred
from their presence. No local token price estimate is substituted for missing cost.

Normalized `usage.reasoning` and `gateway.costBreakdown.reasoning` preserve token
and cost observations independently. The cost component has `status`, nullable
`usd`, source and bounded evidence, using the same final-JSON versus provisional-SSE
header rule as total cost. Missing components remain unavailable; zero is a report
only when actually supplied. Invalid or conflicting observations are excluded.
Messages, sessions, report rows/groups and menu metrics show the subset with its
own sample coverage. Older records without these fields remain readable and do
not acquire invented reasoning values during projection migration.

`input_tokens_details.cache_write_tokens` is retained separately. Cached, cache-write
and reasoning token details are already part of the provider totals; adding them
again would overcount. This agrees with pinned LiteLLM
[Responses usage conversion](https://github.com/BerriAI/litellm/blob/9496f16f1270b3435dff76e5d90753398453f42b/litellm/responses/utils.py#L1057).
An unknown cache-read count cannot be treated as zero to calculate uncached input.
Aggregated input/cache counts are subtracted only when both cover all requests.

Inline message accounting chooses one visible assistant owner per attempt, with
a streaming-answer owner and user-row fallback while an answer is pending. Tool
rows do not duplicate it; the original user row always keeps its Details action
and durable request links. Session/report totals remain request-based.

## Session distributions and historical throughput

The native session breakdown groups retained dispatched attempts by API,
requested alias, reported resolved model and identity status. A session and its
project form the query scope. Tool rounds and compaction count once; inherited
message links do not add a parent's attempts to a child or fork. Request and
reported-cost shares use whole-scope denominators across all model pages.
Missing/invalid/conflicting costs do not become zero. A reported zero stays
visible, but a zero or unknown total has no defined cost percentage.

Status Usage shows historical output tokens per second for the selected time
scope and each model group. Eligible samples are completed, retained dispatched
attempts with reported output and valid client-observed completion timing.
Compute sum(output_tokens) / (sum(ttft_ms + stream_ms) / 1000), not an
unweighted mean or sum of per-request rates. Both timing parts must be finite
and nonnegative, and their sum positive. A zero stream span with positive TTFT
is valid for buffered JSON. Missing timing/output and unfinished, failed or
cancelled attempts are excluded with sample coverage. Zero output with valid
timing remains a measured zero. Reasoning is already included in output.

This matches the session footer's dispatch-to-completion request rate, including
first-token latency. It does not claim server decode speed and is never added to
live byte-based estimates. Distribution reads need no raw bodies, credentials,
new model calls or full-text search.
