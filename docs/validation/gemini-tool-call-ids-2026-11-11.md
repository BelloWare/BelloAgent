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
