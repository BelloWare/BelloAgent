# Forks of sub-agent chats — 0.1.128

2026-10-15 · stream `fork-subagents` · branch `dev/a128-fork-subagents`.
Worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-fork-subagents`.
Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-fork-subagents`.
All log/gallery paths below are relative to that build root.

## Root causes and fix

1. `SessionPersistence.forkCopy` created a new v1 marker but excluded only the v1 marker while copying the source. A parent promoted to `pi-app.native.v3` therefore contributed a second marker. The copy was published before its later open rejected it. A running parent, including a parent in its final family wait, deliberately uses this copy fallback; an oversized replacement header or unavailable APFS clone can also take it. Both the byte scanner and full JSON fallback now exclude **every** recognized marker. The new copy's sole marker is promoted to v3 when its source requires v3, including forks at replies before the first delegation. Legacy parent forks retain v1.
2. In-place promotion changed the source marker's digest without refreshing the cached durable replay's marker. A clone's derived checkpoint could therefore fail validation and lose its fast open. Durable replay now retargets its marker/checkpoint checks in constant time. The low-level clone also carries `markerKind` instead of silently defaulting to v1. Re-promoting a v3 clone is a byte-identical no-op.
3. Retargeting a cloned replay discarded the whole family index, whereas full replay retained delivered context-row digests. Prepared handoff, checkpoint and cold replay disagreed. Retarget now retains just that deduplication evidence in a fresh fork-owned family; execution plans, turns, operations, messages, deliveries, holds, run state and spend authority remain excluded. Empty plan indexes are normalized consistently.

APFS clone, fixed-length header rewriting, truncate-at-reply, incremental replay and checkpoint paths remain in use. Tests assert the clone reset record and checkpoint acceptance; no new full-journal scan was added. The UI computes historical status from two identities when configuring a visible row. No transcript-sized work was added to view bodies/layout.

## Fork contract and decisions

- A parent fork is an independent ordinary chat. It keeps the chosen transcript/context, including accepted sub-agent receipts and delivered agent messages. It starts with zero spend and no inherited child execution, budget ledger, pending deliveries or child journals. Source journal and child journal bytes are unchanged by fork/open/Resume/new work/reopen.
- Historical cards show **History**, with Open/Inspect disabled and Stop absent. Their explanatory text directs the reader to the source chat. Collapsed summary links and pane action forwarding enforce the same boundary; even a retained button callback cannot navigate/control the source child. This deliberately chooses history-only presentation rather than opening a live source viewer from the fork. Existing task/result text and typed attribution remain available in the transcript.
- New children get new UUID identities owned and charged by the fork. The existing contract numbers **turns within each child**, not children globally: a new child starts at turn 1, its follow-up is turn 2, and both survive a cold reopen. Copied historical IDs/turn labels are preserved and cannot be used as owned child handles. No model-visible renumbering or tool-schema change was introduced.
- Forking directly **from a managed child remains rejected** with `managed_subagent`, with no destination/source writes. This retains the explicit deferral in [subagents design §9.5](../design/subagents.md#95-archive-delete-move-and-fork) and the native disabled Fork action. The bug fix enables parent forks; it does not grant human commands to managed children.
- Previously published duplicate-marker forks can exist. They are **not automatically repaired**: choosing one marker could discard a binding/version boundary incorrectly. The existing chain guard rejects them before opening for writes, leaves the journal unchanged, and now explains: “This chat has duplicate native format markers and cannot be opened safely. Its journal was not changed. If this is a fork, create a new fork from the source chat.” The source remains usable. No journal format or migration was added; old valid journals stay readable and v3 downgrade protection stays intact.

Permission, tool, capture, vault, provider-context and accounting semantics are unchanged. All fixtures are generated, with scripted model clients or the loopback gateway. No installed-app launch, real preferences, real Keychain, paid provider, or `xctrace --launch` was used. Native tests use the isolated test host. Only this stream's build root was used; no named result bundles were requested.

## Failing-first evidence and mutations

- `logs/helper-red.log`: the first two new behavioral tests produced five assertions/errors: two markers plus the exact owner-reported open error, stale promotion checkpoint, and prepared/full replay disagreement.
- `logs/native-history-red.log`: the new history-only card test failed five assertions before the UI guard existed (source actions still invoked, Open label, missing history notice).
- `logs/mutation-copy-marker.log`: removing the two `isMarker` exclusions caused the real copy/open regression (two failures).
- `logs/mutation-single-marker.log`: removing `chain()`'s duplicate-marker guard made the damaged-journal rejection test fail (one failure).
- `logs/mutation-fork-owner.log`: removing the real parent-plan ownership guard made `SubagentJournalTests.testParentPlanCannotTransferOwnershipToAFork` fail (one failure).
- `logs/mutation-promotion-checkpoint.log`: removing durable replay's marker retarget made checkpoint acceptance/parity fail (two failures).
- `logs/native-history-mutation.log`: forcing the historical ownership predicate false made the real native card test fail five assertions.

All mutations were restored. Final helper and native affected-class reruns below passed. Earlier fixture corrections are retained in logs: the native running-family fixture needed background mode to reach its final family wait, and its test used `isSubagent`; the runtime fixture now counts actual completed physical requests rather than assuming a fixed number of synthesis calls. No production admission or timing guard was weakened to make these fixtures pass.

## Verification

Helper commands ran in `packages/swift-host` with `swift test --scratch-path <build-root>/helper --jobs 4`.

| Run | Result | Log |
| --- | --- | --- |
| Full Swift helper package | 852 executed: **845 passed, 7 opt-in skips, 0 failures** | `logs/helper-full.log` |
| Final fork matrix and journal clone classes, after expanding copy runtime coverage | **21 passed**: 12 `SubagentForkTests`, 9 `JournalCloneTests` | `logs/helper-final-fork-matrix.log` |
| Existing fork/replay/side/steering parity selection, plus initial new cases | 62 executed: **60 passed, 2 opt-in skips, 0 failures** | `logs/helper-fork-parity.log` |
| Native affected classes after restoring mutation | **27 passed** | `logs/native-restored-affected.log` |
| Native `SubagentOpeningTests`, run alone | **10 passed** | `logs/native-opening-green.log` |
| Native `SubagentNavigationTests`, run alone | **6 passed** | `logs/native-navigation.log` |
| Standalone `SubagentForkGalleryTests`, run alone | **1 passed**, 12 PNGs | `logs/native-gallery.log` |
| One final native parallel lane, four workers | 2,492 executed: **2,455 passed, 37 skips, 0 failures** | `logs/native-parallel.log`, `logs/native-parallel-summary.json` |

Counts for different runs overlap; they are not additive. The full helper run preceded the final added copy-runtime test; the final 21-test run covers that addition and all its affected helper cases. The prior parity selection was `SubagentForkTests|ForkAtReplyTests|ForkCloneTests|ForkReplayHandoffTests|ForkPointTests|ForkPerformanceTests|JournalCloneTests|SideForkTests|ReplayParityTests|SubagentJournalTests|SubagentSteeringContractTests`. The full helper run also covers those classes.

The fork matrix covers copy and clone/truncate, whole chat and reply points before/between/after two real generated children, source checkpoint present/absent, fork checkpoint present/absent, legacy v1 parent history, escaped-v3 marker parser fallback, running/stopped families, the boundary immediately after a start receipt, and direct managed-child rejection. Every fork reopens as a valid one-marker journal, with exact expected context and no inherited authority/spend. Runtime tests for **both copy and clone** Stop/Resume, create a new child, send a turn-2 follow-up, reopen without the checkpoint, and send another user turn, while asserting byte-identical source and child journals.

The native Fork test invokes `WorkspaceModel.forkSession` with a real helper and a loopback child held at a streaming barrier. It verifies selection of the ordinary fork, empty child listing, zero fork spend, unchanged source/child bytes and a successful new fork turn. The native history test verifies disabled/hidden controls and directly invokes retained callbacks to check the boundary.

Affected native classes were run with `PI_BUILD_ROOT=<build-root> scripts/test-macos.sh -only-testing:PiAppTests/<Class>`: `SubagentTranscriptTests` (9), `ForkFromReplyTests` (5), `ForkCloneReaderTests` (1), `SubagentSteeringPresentationTests` (9), `TranscriptActionsForwardingTests` (3). `scripts/test-lanes.py list` assigns Opening, Navigation and the new Gallery class to the serial lane; each was run alone.

The full parallel command uses the exact skip list saved in `logs/native-parallel-arguments.txt`, generated by `python3 scripts/test-lanes.py parallel`, plus `-parallel-testing-enabled YES -maximum-parallel-testing-workers 4`. Exactly one full parallel lane ran, after focused tests and gallery inspection. Its result-bundle summary confirms the console counts. No validation failures remain.

## Gallery

Command: `PI_BUILD_ROOT=<build-root> TEST_RUNNER_PI_APP_FORK_GALLERY=<build-root>/gallery scripts/test-macos.sh -only-testing:PiAppTests/SubagentForkGalleryTests`.

All **12 images were opened and visually inspected**: `gallery/historical-{result,pending}-{light,dark}-{1240,920,684}x600.png`. The 684-wide window gives a 420-point conversation pane beside the sidebar. Historical notice/task/result wrap cleanly, disabled Pi buttons fit, source controls are absent, the sidebar has only the ordinary fork, and the ordinary composer remains available. History's accessible label/tooltip explains why the action is disabled; standard Pi keyboard behavior remains in use. No stock UI controls were added.

## Lead review round 1 — appearance refresh

The independent review of `12e8221e` found that `NativeTranscriptPane.viewDidChangeEffectiveAppearance()` rebuilt the row environment with default `sessionID = nil` and `managedChild = false`. A fork's inherited card then looked live after a light/dark switch, despite the pane's source-navigation guard rejecting clicks. The appearance callback now starts with the existing environment and refreshes only color scheme, contrast and layout direction. Session identity, managed-child state, locale, input availability and action permissions survive the refresh; the existing equality guard still avoids redundant work.

Two failing-first tests cover the real pane callback: the same rendered fork changes light → dark → light without another session update, retaining its notice, disabled History/Inspect controls, inaccessible Stop, explanatory accessibility label and inert callbacks; a managed child retains all session context while its appearance changes. The initial run had **15 assertion failures across these two tests**, with 26 tests executed (`logs/review1-appearance-red.log`). No helper or journal changes are involved.

Review validation is limited to the affected native classes, as requested; the full-suite counts above belong to the initial implementation. The standalone fork gallery now toggles each already-rendered scene to the opposite appearance and back before checking/capturing it.

- Forcing `current.sessionID = nil` in the real appearance callback reproduced **15 assertion failures**, including the visible fork-card regression (`logs/review1-appearance-mutation.log`). Mutation restored.
- Final restored run: **26 passed, 0 failures** — `SubagentTranscriptTests` (10) and `TranscriptNativePaneBehaviourTests` (16), using `PI_BUILD_ROOT=<build-root> scripts/test-macos.sh -only-testing:PiAppTests/SubagentTranscriptTests -only-testing:PiAppTests/TranscriptNativePaneBehaviourTests` (`logs/review1-appearance-restored.log`; initial green also in `logs/review1-appearance-green.log`).
- Standalone `SubagentForkGalleryTests`, run alone: **1 passed, 0 failures** (`logs/review1-appearance-gallery.log`). Set `TEST_RUNNER_PI_APP_FORK_GALLERY=<build-root>/gallery-review1` with the usual build root and class selection. All **12 refreshed images** were opened and visually inspected at `gallery-review1/historical-{result,pending}-{light,dark}-{1240,920,684}x600.png`; history notice, disabled controls and wrapping remain correct after toggling.
- No helper tests or full native lane were rerun for this UI-only review fix. No additional production semantics or data changes.

## Handoff

The first independent review finding is addressed; lead re-review and release integration remain outstanding. Managed-child forks remain a future design item; damaged forks require a new fork from their intact source. This stream does not package a release or merge/push `dev/next`.
