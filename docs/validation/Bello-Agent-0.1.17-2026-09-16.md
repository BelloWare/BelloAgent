# Bello Agent 0.1.17 acceptance

Date: 2026-09-16. Branch: `master`. Version **0.1.17/build 21**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 15:31:21 UTC.**
Release source: `bbe02ecce0da172bbbcdf8304a663ff29d033269`. Website: `2cb0c457f52b522ef13c1e21c291fe7e151bfb69`.

## Changed behavior

Version 0.1.17 uses one request-aware context count for the ring, inspector,
preflight and compaction. It counts the actual provider-built instructions,
tools and replayed input. Gateway-reported input is reused only for a matching
prefix and an explicitly pinned, reported model; previous output is not added
wholesale. Counts carry method, request fingerprint, model and uncertainty.
Safe idle tabs and draft edits refresh through a shared debounce/cache; pending
counts do not display stale conversation totals. Output budgets are separate
from catalog model ceilings, with a distinct safety margin. Reported usage,
request context and estimated live output activity remain separate measurements.

The context service fingerprints the actual provider request and configuration,
including replay/routing policy. Its five-minute bounded cache keys baseline
input evidence separately. A reported usage baseline requires an explicit pinned
route, matching reported model, unchanged request template and exact ordered
input prefix. Only newly replayed items are estimated after that prefix. Cached
input and reasoning output remain reported subsets and are never added twice.
Image bytes are projected to dimensions/policy estimates rather than tokenized
as base64; unknown models/dimensions and opaque replay keep explicit warnings.

Before a request has been prepared, context is pending. The inspector and ring
normalize the same count object. Safe focused idle draft edits share the 180 ms
debounce; stale counts do not reappear while replacement work is pending.
Inactive, running, untrusted or interrupted chats do not generate previews.
Open ephemeral side drafts can prepare without changing their persistence rule.
No model generation, tool execution or remote counting is caused by preview.

Model catalog ceilings no longer become requested output budgets. Supported
ceilings may exceed context capacity; configured output budgets must fit their
ceiling/context limit. Existing explicit profile budgets are retained, while
legacy per-chat catalog limits migrate once to the configured requested budget.
The safety margin is min(1,024, max(1, contextWindow / 100)); input budget is the
remaining context after requested output and that margin. Both ordinary preflight
and compaction-summary requests use the shared counting contract.
If compatibility omits max_output_tokens, the count warns that its local reserve
is not a server-enforced cap. Explicit-skill previews use a placeholder turn ID;
delivery inserts the real ID and recomputes count/fingerprint. The same counting
service does not imply identical bytes when those prepared inputs change.

## Acceptance and corrected failures

**129 unique native tests and 132 unique helper tests have a final
observed pass.** Initial broad runs did not pass: one native case and three
helper cases failed. The corrected focused reruns passed (36 native, seven
capacity and 11 request-context cases), followed by 21 passing final helper
context/gateway/capacity cases. Every initial failing case has a later pass;
repeated executions are counted once. Coverage includes debounced/stale context,
output-budget migration, replay/baseline invalidation, image uncertainty and a
request-validating loopback gateway with exact request/response capture.
The unchanged transcript/WebKit/TypeScript evidence is reused from 0.1.16.
No live deployed gateway, remote token counter, screenshot gallery or physical
UI interaction is claimed. Installation/update rehearsals were skipped by owner
instruction.

| Log | Passed executions | Skipped | Failed cases | Failed assertions |
| --- | ---: | ---: | ---: | ---: |
| `native.log` | 126 | 0 | 1 | 2 |
| `native-followup.log` | 36 | 0 | 0 | 0 |
| `helper.log` | 128 | 0 | 3 | 6 |
| `capacity-followup.log` | 7 | 0 | 0 | 0 |
| `context-followup.log` | 11 | 0 | 0 | 0 |
| `context-final.log` | 21 | 0 | 0 | 0 |

Counting each case's **last observed result** across these logs gives
**129 native passes and 132 helper passes**;
0 final skips and zero unresolved failures.
The initial broad runs remain failed runs. The initial native run executed 127
cases with one failing case/two assertions; the initial helper run executed 131
cases with three failing cases/six assertions. Focused reruns resolved them:

- `-[PiAgentCoreTests.RequestContextTests testOpaqueReplayIsCountedOnlyWhenActuallyIncludedAndWarnsAboutUnknownContextCost]`.
- `-[PiAgentCoreTests.TurnCapacityTests testCompactionCannotDispatchOversizedSourceToSmallerModel]`.
- `-[PiAgentCoreTests.TurnCapacityTests testSmallerModelPreflightAndCompactionUseItsOwnCapacity]`.
- `-[PiAppTests.ContextAndSkillPolicyTests testFirstContextPreviewOfFreshChatUsesPackagedHelperWithoutSending]`.

The native failure expected an immediate numeric estimate from session.open;
this is now deliberately pending until the shared request body is prepared.
The opaque-replay assertion mistakenly searched the entire body, matching the
request option for future encrypted output; it now checks actual input replay.
Capacity fixtures were updated for real request/schema overhead and the explicit
output-budget/safety-margin error, replacing assumptions about the former fixed
allowance. The added draft-debounce and ephemeral-side regressions passed in the
native follow-up. No failure was discarded from the record or relabeled as a
passing initial broad run.

The loopback gateway validates model, reasoning, instructions, schema, tools,
authentication/correlation, output budget and replayed content before returning a
response derived from that content. For this plain-draft fixture without
delivery-specific skill expansion, the prepared body, execution preflight count
and fingerprint match the independently received request; exact captured request and
response bytes match. The malformed-request probe is rejected. Usage confirms
10,000 input including 8,000 cached, 2,000 output including 1,500 reasoning and
12,000 total, without adding cached/reasoning subsets again. Oversized actual tool
schemas fail before dispatch. The fixture observes no token-count endpoint call.
Other tests cover stable/pinned usage baselines, input-prefix changes, tools,
instructions, routes, parameters, budgets, retained opaque input and image policy.
These are local request-aware fixtures, not an installed LiteLLM or deployed
service acceptance test.

## Intentional limits and reused evidence

These remain estimates, not exact tokenizer results or independently
verified billing usage. No remote counting endpoint is enabled: the reviewed
LiteLLM interfaces do not establish complete Responses request compatibility
and a route-bound counted model. Automatic routing and opaque/image costs retain
explicit uncertainty. See [Context-Accounting.md](../Context-Accounting.md).

Live TPS remains an estimate of exposed output bytes. Completed TPS remains
reported output divided by end-to-end dispatch-to-completion time, including
startup latency; neither is claimed to measure backend decoding speed.

Transcript, disclosure/WebKit and TypeScript source are unchanged from 0.1.16;
their versioned passing evidence is reused, not reported as a new run. No live
remote gateway/counter, full screenshot gallery, physical UI interaction, full
Release performance matrix, installation, Sparkle update/relaunch or signed
owner/update rehearsal was performed. Signing and publication checks below
remain release gates. Known broader interaction gaps remain in the handoff.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.17.dmg](https://belloware.com/assets/BelloAgent-0.1.17.dmg).
- Size: **7,215,669 bytes (6.88 MiB)**.
- SHA-256: `63cbbf327f44fd5e8fbdedab420e96ff32d17591c56a094d045e1c6c775248d1`.
- App notarization: `be73a5d9-31da-4545-8f09-1f9b55df78e4` (accepted).
- DMG notarization: `dccc935b-28ab-4dd6-bc0a-d530b83ac98e` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass. Packaged
smoke verifies the helper and exact catalog. Product/download, home, legacy
redirect, sitemap and unchanged icon pass. Canonical/legacy feeds are identical;
the downloaded archive matches SHA-256 and Sparkle Ed25519 verification.
Bundle ID, Keychain ownership, saved history, selected icon and updater identity
are preserved.

Cloudflare build `a1f4a3ef-d3d9-4274-a5e6-0c5b48c1c018` completed successfully at 2026-09-16T15:30:37Z.

Scratch: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/context-accounting-017`. Logs: `native.log`, `native-followup.log`, `helper.log`,
`capacity-followup.log`, `context-followup.log`, `context-final.log`,
`helper-build.log`, `release.log`,
`publish.log`, `public.log`, `pages.log`, `public-verification/`.
Release work directory: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.IqpGKB`.
The unrelated Claude documents `docs/Code-Review-2026-09-16.md` and
`docs/Issue-Stale-Chat-Model-Catalog.md` remain untouched.
Publication uses a clean temporary source worktree. This later documentation-only
commit records completed checks; the packaged source SHA above remains exact.
