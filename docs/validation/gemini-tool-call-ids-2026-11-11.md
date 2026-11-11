# Gemini tool-call IDs: experimental fix

Date: 2026-11-11. Branch: `fix/gemini-tool-call-ids`.
Base: `dev/next`, `b351eb171ab4a015705767bda89080ceb154a7d1`.

## Failure and scope

`ProviderAccumulator.result()` rejected a returned tool-call ID above 512
UTF-8 bytes with `invalid_params: Invalid tool call id`. LiteLLM can embed a
Gemini thought signature in the ID as `call_...__thought__...`, making a valid
wire ID much longer. The user's actual failing response was not available, so
this is a source-confirmed compatibility defect, not a claim of live-request
reproduction.

The same ID also crossed smaller limits in subagent provenance and navigation,
the host's full tool-input read, and display timeline events. Merely raising
the response parser's limit left those paths inconsistent.

## Change

- One shared `ProviderToolCallID` policy accepts nonempty opaque IDs up to
  65,536 UTF-8 bytes and rejects ASCII controls and DEL. The size is an explicit
  application resource bound, not a provider's specified limit.
- The response parser and `session.tool.input` use that policy. Subagent
  provenance and navigation validate the provider ID separately from their
  existing, smaller local-identity bounds.
- Provider timeline events keep the full valid call ID so tool-card and input
  joins remain exact. Invalid IDs produce no call linkage, not a clipped ID.
  A Responses item ID is never substituted for its missing `call_id`.
- IDs are not shortened, normalized, decoded, re-encoded, or regenerated.
  The existing request replay therefore returns an embedded signature intact
  on both the function call and its matching result.
- The shared source is included in both the app and test-host Xcode targets
  and in `project.yml`; Swift Package Manager discovers it in PiAgentCore.

## Gateway compatibility

This branch keeps the existing Responses API and LiteLLM configuration. Use
LiteLLM's default signature-in-ID mode for this experiment. The separate
`thought_signature_in_tool_call_id: false` option needs a provider-metadata
replay change: the current `ResponsesInput` projection drops
`provider_specific_fields`. That work also needs to respect portable/pinned
and cross-provider routing policy, so it is outside this ID fix.

Sources:

- [LiteLLM Gemini thought-signature and short-ID documentation](https://docs.litellm.ai/docs/providers/gemini#keep-tool-call-ids-short)
- [Google thought-signature requirements](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures)

## Validation status

`git diff --check` passed. Static project checks confirmed unique Xcode object
IDs and the new shared source's membership in both `PiApp` and `PiAppTestHost`,
as well as the `project.yml` source list.
The required read-only plan and final whole-change reviews by `gpt-6.1-sol`
at `xhigh` reasoning reported no findings.

The editing environment is Linux and has neither Swift nor Xcode. Swift unit
tests, macOS app tests, mutation checks, and a live Gemini request have **not
been run here**. The branch is for review and testing, not release acceptance.

Regression cases are in the existing `ProviderStreamingTests`,
`ResponseTimelineTests`, `SubagentJournalTests`, `ToolInputDisplayTests`, and
`SubagentTranscriptTests` classes. They cover long signed-looking IDs, exact
call/result replay and persistence, distinct calls sharing a long prefix,
malformed and over-limit IDs, subagent provenance/navigation, timeline linkage,
and the host tool-input boundary.

### Run on a Mac

From a checkout of this branch, run the focused helper tests:

```sh
swift test --package-path packages/swift-host --filter 'ProviderStreamingTests|ResponseTimelineTests|SubagentJournalTests|ToolInputDisplayTests'
```

To build the app/test host and run the app regression through the repository's
isolated validation worktree, fetch the remote branch first, then use:

```sh
git fetch origin
PI_NEXT_REF=origin/fix/gemini-tool-call-ids scripts/check-next.sh test SubagentTranscriptTests
```

Before accepting this fix, verify the new tests fail with the old parser,
host-input, subagent, and timeline checks restored individually, then pass
with the fix. Finally run a Gemini tool loop through the actual gateway,
including a subagent call and a resumed saved chat, and inspect that the full
original `call_id` is returned unchanged. No provider credentials are needed
for the deterministic regression tests.

## Validation on macOS and the release-line port (2026-11-11)

Branch `dev/a136-gemini-callid`, from the `v0.1.135` tag. The fix was
cherry-picked there (author kept); its `NEXT-RELEASE.md` entry belongs to
`dev/next` and was left out. That was the only conflict. The Xcode project was
regenerated with XcodeGen 2.44.1 from `project.yml`: the same membership under
the generator's own object ids. Environment: macOS 14.8 arm64, Xcode 16.1,
Swift 6.0.2. Fixtures and a loopback gateway only; no provider, key or saved
chat was used.

### The fix as written

It compiled unchanged. The focused helper tests
(`ProviderStreamingTests|ResponseTimelineTests|SubagentJournalTests|ToolInputDisplayTests`)
ran 42 tests with no failure. The helper suite as `docs/Release.md` runs it:
StreamingCostTests alone, 5 tests, no failure; the rest, 1,250 tests, 8
skipped, no failure.

Each old check restored alone, against the same 42 tests:

| Restored check | Result |
|---|---|
| Parser, 512 bytes (`Providers.swift`) | 3 tests fail: `testResponsesSignatureBearingIDsSurviveStreamingPersistenceAndReplay`, `testProviderToolCallIDsUseAnOpaqueUTF8ByteBound`, `testMessagesStreamingSignaturesAndCumulativeUsage` |
| Host tool-input read, 256 bytes (`HostService.swift`) | `testHostToolInputReadsExactSignatureBearingIDsFromTheJournal` fails |
| Sub-agent link, 512 bytes (`SubagentTypes.swift`) | `testSignatureBearingSubagentPlansKeepDistinctCallsAndLocalIdentityLimits` and `testManagedOriginAndTerminalSurviveCheckpointAndFullReplay` fail |
| Timeline call id clipped to 256 bytes (`ProviderDisplayEvents.swift`) | `testSignatureBearingToolLinksStayExactAcrossStreamingAndCanonicalCompletion` and `testMalformedResponseCallIDsDoNotBecomeTruncatedOrItemIDLinks` fail |

A search of the helper, the app and the views for any other bound, clipping or
character rule on a call id found none: compaction grouping, edit and fork
replay, the duplicate check on a reply's calls, MCP result retention and the
app's history reader compare ids whole. The timeline still clips an output
*item* id to 256 bytes; LiteLLM's item ids begin with the call's own random id,
so two calls never share that prefix.

### What LiteLLM requires

Read from LiteLLM's source (1.80.5, 1.81.16, 1.83.7, 1.99.0, 1.104.0, 1.109.0)
and its Gemini provider page:

- From 1.80.5 a Gemini tool call id is `call_<28 hex>__thought__<signature>`
  for the call Gemini signed (the first of a parallel batch) and
  `call_<28 hex>` for the others. Through `/v1/responses` the function-call
  item's `id` repeats the call id up to 1.99 and is `fc_` plus the call id from
  1.104; every argument delta names the item by it.
- On the next request LiteLLM reads the signature from the function call's
  `call_id`, and up to 1.99 finds a tool output's call by equality of the two
  ids; a different id fails with "Missing corresponding tool call for tool
  response message". So both must go back byte for byte, as this fix does.
- `thought_signature_in_tool_call_id: false` (from 1.109.0) gives short ids
  and puts the signature in the item's `provider_specific_fields`. The app does
  not fail in that mode, but `ResponsesInput` rebuilds a call item without
  those fields, so the signature is not returned: for Gemini 3 and newer
  LiteLLM then sends a placeholder signature and the model loses that
  reasoning. Keep LiteLLM's default with this app until replay carries the
  fields.
- LiteLLM strips the signature for other chat-completions providers, but not
  on a Responses route it passes through: OpenAI answers "string too long.
  Expected a string with maximum length 64".

### Two additions

- **The bound is 1 MiB.** OpenHands measured LiteLLM's ids over one 47-call
  Gemini run: 14 above 1 KB, the longest 278,100 bytes
  ([software-agent-sdk PR 3581](https://github.com/OpenHands/software-agent-sdk/pull/3581)).
  At 64 KiB that reply would fail as before. An id over the bound now reads
  "Invalid tool call id: N bytes, over the M-byte limit". With 64 KiB
  restored, `testEveryLengthOfSignatureIsAccepted` fails at 278,144 bytes.
- **Another model gets an id it accepts.** A request to a model other than the
  one that made a call names the call by `call_` and 32 hex digits of the id's
  SHA-256 when the id is longer than 64 bytes: the call, its result and pi's
  synthetic missing result alike. The journal keeps the original, and the
  model that made the call is still sent it whole. With the shortening
  disabled, `testAnotherModelGetsIDsItAccepts` fails, and so does the model
  switch in `testAGeminiTurnWithToolCallsRunsAndGoesOnAfterARestartAndAModelSwitch`,
  where the loopback gateway answers a 3,344-character id as OpenAI does.

`GatewayCallIDTests` uses the shape LiteLLM really sends (above) and runs a
whole turn through a loopback gateway: two parallel calls, the request after
them, the same chat reopened from its journal, and a turn on another model.

### At the final commit

At `d78624ce` (both additions): the focused classes with `GatewayCallIDTests`,
50 tests, no failure; StreamingCostTests alone, 5 tests, no failure; the rest
of the helper suite, 1,258 tests, 8 skipped, no failure.

### Not done here

- The app target was not built to the end: the machine had under 3 GB free,
  and the build was stopped. The test host target, which compiles the same app
  sources including `SubagentToolView.swift` and `ProviderToolCallID.swift`,
  compiled and linked without an error first. `SubagentTranscriptTests` is an
  app test: it was neither compiled nor run, and is left for the release gate.
- A live Gemini tool loop through the owner's gateway, with a sub-agent call
  and a resumed chat.
