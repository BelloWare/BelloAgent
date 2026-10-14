# Sub-agent steering — app phase 5 validation

Phase 7 subsequently enables the completed feature and validates the merged
release tree; see [enabled-build validation](subagents-steering-enabled.md).
Statements below about the disabled switch describe the phase 5 checkpoint.

Worktree `wt-steer-ui`, branch `dev/subagents-steer-ui`, build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-steer-ui`. macOS arm64,
Xcode 16.1, isolated `com.belloware.PiAppTests.Host`. Generated fixtures and
loopback only; no installed app, owner preferences, Keychain or paid calls.
Text logs under `$PI_BUILD_ROOT/logs` are the evidence; automatic result bundles
are pruned by `scripts/test-macos.sh`. No named result bundles.

## Step 1 — typed presentation and turn ordering

Based on helper `43f9e0d9`. Live and journal readers preserve
`nativeAgentDelivery`; agent inputs have their own attributed native row and do
not create human task roots. V3 control receipts use the native sub-agent card;
accepted background starts remain live. Capture summaries advance by child turn
and revision, without reviving old terminal turns.

- `step1-red.log`: background card and typed-author regressions fail on baseline.
  The capture test initially lacked its SQLite fixture table; corrected before
  `step1-red-capture.log`, which reproduces the permanent-terminal failure.
- `step1-green.log`: 16 passes, 0 failures across
  `SubagentSteeringPresentationTests`, `SubagentTranscriptTests`,
  `SubagentCaptureTests` (bash-array selection).
- `step1-mutation.log`: restoring the permanent terminal guard, dropping live
  authorship and treating a background receipt as an ordinary status each fails
  its regression. All three mutations restored.

V3 execution remains hidden behind the helper's existing single switch.

## Step 2 — workspace lifetime, discovery and navigation

Merged helper phase 4 (`21feb72e`) and upstream round 7 in `8a072872`.
V3 journal readers recognize promoted parents/children and committed operation
plans. Discovery projects the latest turn, keeps one conversation per child,
and preserves newer attached runtimes over disk recovery fallbacks. The parent
renders family waiting and pending-Resume notices, persists family holds and
counts pending messages. Cards/child footers retain turn identity; Stop pins the
turn; a follow-up Open remembers its own return call. Deletion includes promotion
siblings. Coordination pauses offer parent Resume; the child composer remains
hidden.

- `step2-red.log`: both new workspace tests fail before implementation.
- `step2-green.log`: compiler caught a Swift exclusivity violation in optional
  navigation-target assignment; corrected before behavioral validation.
- `step2-green-2.log`: 62 passes; one fixture failure because its capture archive
  was not configured. Corrected fixture, without relaxing an assertion.
- `step2-green-3.log`: **63 passes**, 0 failures: steering workspace/presentation,
  discovery, transcript, organization, deletion and run-hold classes.
- `step2-mutation.log`: ignoring family waiting/pending state and ignoring newer
  turn records each fails its regression. Restored, `step2-restored.log`: 2 pass.
- `step2-SubagentNavigationTests.log`: **5 pass**, serial alone.
- `step2-SubagentOpeningTests.log`: existing live-discovery regression caught an
  interrupted disk fallback blocking a real running summary. Revision-zero
  interruption is now replaceable by authoritative live state.
- `step2-SubagentOpeningTests-2.log`: that regression passes; captured-cost fixture
  failed once because it killed the helper after capture begin but before the
  archived dispatch timestamp. Its fabricated terminal evidence therefore did
  not meet the production reconciliation predicate. Isolated recheck passed
  (`step2-cold-open-recheck.log`); fixture now waits for the actual retained
  dispatch timestamp, not merely an archive row.
- `step2-SubagentOpeningTests-3.log`: **9 pass**, serial alone, with that barrier.

## Step 3 — delivery and request provenance

Merged helper `3ce58e0e` during implementation. Capture now projects child turn,
sponsoring parent execution and the helper's exact `agentDeliveryIDs`, with an
indexed, body-free relationship table that expires with its physical attempt.
Existing captures fall back to their context-row links. No capture policy or
quota changed. The family Inspector subdivides requests by child turn and links
the source operation, delivery row, source request and first retained consuming
request. Source navigation uses the existing managed child/parent reveal paths,
including retained versions. Typed delivery inspection follows the consuming
request instead of creating a human turn root.

Message cards distinguish acceptance, pending delivery and actual delivery;
completed waits name their wake reason. Journal-derived human Stop holds appear
on cards and child footers. New runtime progress cannot replace the current
runtime's progress. Coordination rows expose their source through every
transcript action relay.

- `step3-red.log`: initial Inspector delivery/turn assertions fail on baseline.
- `step3-green.log`: compiler caught missing optional initializer arguments in
  the new journal projection; corrected. `step3-green-2.log`: **24 pass**.
- `step3-delivery-red.log`: fixture initializer label corrected before the
  behavioral run. `step3-delivery-red-2.log`: delivery inspection, queued-steer
  status and completed-wait status fail for the intended reasons.
- `step3-complete-green.log`: **28 pass**, 0 failures: steering Inspector,
  presentation/workspace, existing Inspector/capture and action forwarding.
- `step3-mutation.log`: removing physical-session scoping, treating typed agent
  input as a human root, and accepting progress from a different runtime each
  fails its regression. All mutations restored; `step3-restored.log`: **10 pass**.

Contract limits for integration: the helper now supplies exact included event
IDs, but source operation identities still come from the owner's journal;
`RequestScope` retains creation ancestry rather than a separate triggering-call
field. The app joins the durable operation with capture output links. Links mean
the **first retained** consuming attempt; expired capture cannot prove the first
historical inclusion. Missing/disabled capture keeps receipt/delivery inspection
and source transcript navigation, with an explicit unavailable-request note.
Read-only coordination projection uses a fingerprint-cached journal scan because
the helper does not yet expose the design's turn/message detail paging command;
the helper's phase 6 acceptance does not measure this app scan. Large-family scan
cost is not claimed here.

## Step 4 — complete navigation and native gallery

Merged helper acceptance `a2fe6b53` in `dc5a4294`; no app contract change was
needed for its persisted mailbox rotation. Steer-card Open retains the exact
message event, rather than revealing the turn's initial task. A source lookup
cannot replace a newer user selection. Back to Parent and source navigation find
the follow-up's actual issuing call inside an ancestor's retained version.
Human Stop on an old start card names the latest held turn. Report cards label
questions, blockers and notes, and expose pending message counts. Inspector
request buttons align with the turn headings. Parent/child deletion assertions
cover both promotion siblings.

Failing-first and mutation evidence:

- `step4-message-navigation-red.log`: steer-card Open loses its message ID.
  `step4-message-navigation-mutation.log`: removing the card's message ID and
  the reader's event-ID predicate each fails its regression. Both restored;
  `step4-message-navigation-restored.log`: **8 pass**.
- `step4-source-selection-red.log`: a delayed source read reveals the old
  destination after selection changes. `step4-source-selection-mutation.log`:
  accepting a changed selection fails the same assertion. Restored;
  `step4-source-selection-restored.log`: **1 pass**.
- Gallery diagnostics exposed a zero-width tool header's focus outline becoming
  `CGRect.null` during mounting. `step4-geometry-red.log` showed that AppKit clamps
  the invalid coordinates to very large finite values, so a finiteness-only
  assertion was insufficient. The exact inset-layout assertion fails twice in
  `step4-geometry-red-2.log`. The outline now keeps a nonnegative width before
  placement. A temporary stack probe identified the existing work-line layout;
  the probe was removed before validation and is not part of the implementation.

Final affected-class runs on the merged tree use the isolated test host:

| Evidence | Result |
|---|---|
| `final-app-complete.log` | **95 pass**, zero failures across the 13 classes below |
| `final-app-geometry.log` | **117 pass**, zero failures: those classes plus the new layout regression and `TranscriptNativeWorkBehaviourTests` |
| `final-SubagentNavigationTests.log` | **6 pass**, alone in the serial lane |
| `final-SubagentOpeningTests.log` | **9 pass**, alone in the serial lane |
| `final-SubagentPerformanceTests.log` | **1 pass**, alone in the serial lane |
| `gallery-final-verified.log` | **1 pass**, alone; all **92 images** rendered, zero invalid-view-geometry diagnostics |

The 13-class bash-array selection is `RunHoldTests`, `SubagentCaptureTests`,
`SubagentDeletionTests`, `SubagentDiscoveryTests`, `SubagentInspectorTests`,
`SubagentMetadataTests`, `SubagentModelGrantTests`, `SubagentOrganizationTests`,
`SubagentTranscriptTests`, `SubagentSteeringInspectorTests`,
`SubagentSteeringPresentationTests`, `SubagentSteeringWorkspaceTests`, and
`TranscriptActionsForwardingTests`. This is affected-class validation, not a
claim that the complete native or helper suite was rerun in this worktree.

The existing generated Debug performance fixture measured 20 progress updates:
64.74 ms median, 111.49 ms maximum; 52 measured rows, 16 markdown measurements,
zero sidebar recomputations, and 1127.63 ms for the switch round trip. These are
the existing fixture's measurements, not production or large-family scan claims.

`UIScreenshotTests/testRenderSubagentSteeringGallery` runs alone and writes
`$PI_BUILD_ROOT/gallery/steering/manifest.txt`. Its 23 scenes render in light/dark
at 920×600 and 1240×800: **92 images**. They cover folded/expanded background
cards, final family wait, pending/delivered results and messages, pending/delivered
questions and blockers, parent steering, child notes, second/third follow-ups
with earlier results, follow-up cards, user Stop holds, coordination/cost pauses,
Resume with undelivered events, long text/keyboard/author accessibility, Inspector
turns, unavailable capture and a link outside the 5,000-row display window.
Generated Inspector captures use distinct physical turn IDs and include 5,000
filler attempts to exercise the actual retained-window path. Assertions cover
hidden child composers, native agent author labels, visible cards, turn grouping
and successful out-of-window request focus. Money uses the shared two-decimal
formatter. Representative settled captures were visually inspected in both
themes and sizes.

Gallery setup evidence is retained: `gallery-first.log` caught an actor-isolated
fixture accessor; `gallery-second.log` skipped because the screenshot root had
not been forwarded through `TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT`. Both were
corrected. The later gallery logs contain actual rendered images; skips are not
counted as gallery validation.
The final render also corrects the fixture's stopped-family runtime/status
projection, so its paused/cost-limit sidebar shows pending messages without
claiming that stopped children are running. The final pause, narrow long-text
and out-of-window Inspector scenes were inspected after regeneration.

## Integration status

App implementation commits before the final gallery step: `ace01712` (typed
presentation/capture ordering), `ae6011fd` (workspace lifetime/navigation), and
`0835aa7b` (request provenance/Inspector). Helper merges are `8a072872`,
`f2fc36a0`, and `dc5a4294`. Only `dev/subagents-steer-ui` is pushed by this work.

No helper core files were edited for phase 5. V3 parsing and presentation are
ready; `SubagentPolicy.steeringEnabled` remains **false** for release integration.
The remaining contract limitations are the read-only paging/trigger provenance
items described above; they do not grant a child a composer, new permissions or
independent budget ownership. Capture policy and limits are unchanged. Release
activation and the release gate are separate from this app phase.
