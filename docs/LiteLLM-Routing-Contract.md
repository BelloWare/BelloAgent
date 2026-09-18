# LiteLLM identity and native reasoning replay

Implementation on Swift `master`, 2026-09-15. Deployment acceptance remains
external: no gateway URL/version, model aliases or paid-request authorization
has been supplied. The tests use a deterministic loopback contract, not a claim
about an undisclosed production deployment.

## Identity evidence

Every attempt preserves the requested alias. Response `model` evidence comes
from Responses lifecycle response objects, Messages message_start and optional
late message_delta model fields, or the nonstreaming response root. Assistant
self-descriptions and tool JSON are never model metadata. Alias-only echoes
remain unreported. Distinct non-alias names are conflicting evidence; malformed
or overflowed evidence is explicitly incomplete. Evidence is bounded to 32
unique records, each value at most 256 UTF-8 bytes, with source and kind.

Custom model/deployment/group header names require an explicit deployment
contract reference in native settings. No guessed actual-model header is
installed by default. Authentication/cookie/token/key headers and ambiguous
roles are rejected. An opaque deployment ID or route group is never promoted
to an upstream model name. The [LiteLLM header documentation](https://docs.litellm.ai/docs/proxy/response_headers)
distinguishes model_info.id deployment identifiers from model-group aliases;
body model values may also be alias echoes. These public docs do not verify
the user's deployed configuration.

The Inspector preserves provenance and the original response body separately.
The footer and dashboard show the reported model, or unreported/incomplete.
When reports conflict, every distinct name is stored with the request
(`reported_models`); the report, message details and footer show the shortest
name by default and a click reveals the other reported names.
The next request always sends the selected alias. Context capacity remains the
explicit configured conservative capacity; the app cannot discover hidden
upstream retries, model limits or unreported routing from an alias.

## Explicit continuation policy

The one native vault stores `routing` alongside the connection's advanced model
capabilities. New native connections visibly select portable history; saving
the connection records that choice. Missing policy in existing helper inputs
means ask before opaque replay, not an implicit conversion.

- `portable`: send visible text and paired tool calls/results. Keep original
  opaque/signed/encrypted provider items unchanged in the native journal and
  exact captures. This is an explicit lossy continuation projection, not an
  assertion that reasoning is portable.
- `pinned`: preserve native items only when the prior message has a reported
  expected model and the same profile ID, configuration revision, endpoint/API/
  alias binding and routing-contract fingerprint. Settings require the expected
  model plus the gateway's fixed-route compatibility contract. This is a
  prerequisite guaranteed by the gateway administrator; the app does not pin an
  auto-router or predict an unannounced routing change. Missing/conflicting/
  changed evidence blocks subsequent opaque replay before an HTTP attempt.
- `ask`: history containing opaque items pauses with a settings action. It is
  never silently stripped or replayed on a guessed compatible model.

A connection revision changes on every native settings save, including header
and key changes. Old journals remain readable; a user can explicitly choose
portable continuation without deleting their provider-native history. This is
a deliberate safety difference from the earlier unconditional Pi-style native
item replay; `testResponsesOpaqueReplayAndUsage` now declares a fixed fixture
contract and still asserts exact preservation of the original items.

## Verification

37 core XCTest and 13 executable fixture cases pass in the routing pass. Added
cases cover both APIs, streaming/nonstreaming model evidence, changing routes,
late/absent/alias-only/conflicting fields, opaque deployment IDs, invalid header
contracts, original journal preservation and fixed-route/revision mismatch.
The same executable fixtures cover tools, compaction and exact byte capture.

Review also found refusal-only output, terminal-only output, nonempty Messages
block starts and explicit provider-error terminal events needed independent
content/terminal timing. Those regressions now pass, including delayed HTTP EOF
after a model failure. Model failure and HTTP body completeness are distinct.

## Owner-supplied router model extension (2026-09-16)

The owner's LiteLLM 1.99.0 JSON sample reports `model: auto-router`,
`router_model_name: gpt-5.4-mini` and response header
`x-litellm-model-name: openai/gpt-5.4-mini`. `router_model_name` is explicit
resolved-model evidence for this gateway extension; it is not inferred from the
response ID, encrypted reasoning, model self-description or deployment hash.
The `openai/` namespace in the supplied model-name header is a known qualification
for comparison with its unqualified router model. Other arbitrary prefixes are
not stripped. Original evidence and distinct deployment/model-group values remain
available, and disagreement between model names remains a conflict.

## Fallbacks (2026-09-16)

Every Responses request carries `disable_fallbacks: true` unless the
connection's model capabilities JSON sets `compat.allowFallbacks` to `true`
(Settings › Gateway routing › Allow fallback models). A failing route therefore
returns its error, which the chat and the request report show against the
requested model, instead of LiteLLM silently answering from a fallback model.
The report lists the requested alias and the final model the gateway reported
for every request, marking routed requests and unreported identities.
