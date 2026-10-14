# Sub-agent steering — app phase 5 validation

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
large-family cost is part of phase 6 acceptance, not claimed here.
