# Family deletion and missing-project deletion (0.1.129)

Branch `dev/a129-family-delete`, based on `dev/next` 9d4123f6 (released 0.1.128).

## Owner decisions implemented (2026-10-16)

1. **Deleting a main chat deletes its whole family.** One Delete moves the chat, its saved sides at every depth and all of their managed sub-agents to Trash together. The confirmation lists the sides that go with it. Deleting a single side deletes that side and its descendants. Spend from a deleted side stays counted in the main chat ("Keep it counted").
2. **A chat whose project is missing can be deleted.** The restore-first requirement is gone. Deletion removes only the app's own chat records and files. Anything that needed the project folder is skipped and named.

## Behavior

- **Members.** `MetadataStore.savedSideDescendants(of:workspaceID:)` walks the complete durable chat graph, not just the 10,000-chat window. It is joined with any loaded record that the store has not caught up with yet. Membership follows `persistedBudgetParentID` (a `side_<id>.jsonl` journal plus `parentSessionID`). Forks are only provenance and are never included. Sub-agents are collected per member from the journal plans and the metadata, after the runtimes have detached, as before.
- **One durable intent.** Every member is written to `session-delete` / `session-deleted` under the root's owner ID in one transaction. Side members carry `sideDepth`, which is the only thing that lets a non-owner member use a `side_<id>.jsonl` name. A side ID must be one plain name. Managed children keep their strict UUID rule.
  - Files are removed root first, then sides parents-first, then sub-agents.
  - Metadata is removed in the reverse order, so the root's retry entry stays until everything else is gone.
  - Relaunch marks side members as deleting as well as the owner, and the tombstones block opens and discovery. M4 below shows that the tombstone alone already blocks reopening.
- **Running work.** As before, deletion refuses with the busy member's name. Nothing is stopped implicitly.
- **Ledger repair.**
  - A **main** chat has no surviving ancestor, so no repair runs. With no ready helper, none is started and no profile or credential is needed.
  - With a ready helper, idle dependents are released and `session.forget` is sent with `descendantsDeleted`. This means no owner charge is mirrored into the deleted subtree, so damaged evidence in a side that is going to Trash can no longer block the deletion.
  - A **side** root still takes the existing repair barrier: the helper repairs every surviving ancestor from the whole deleted subtree before tombstones and Trash. Members are then forgotten with `ancestorsRepaired`, so their ancestors are not written again.
- **Missing project.** `deletionProjectUnavailable` covers both a removed project and a missing root folder. The confirmation's notes say that only Bello's own copy is removed and nothing in the project folder is touched. For a side whose helper is not ready, the notes also include "Skipped: checking for costs from interrupted requests…". If the state changes after the confirmation, any skip it did not announce is reported once deletion finishes.
- **Earlier orphans.** Sides orphaned by 0.1.128 deletions are left alone: their parent no longer exists, so they belong to no family. Deleting an orphan deletes it and its own descendants, with no repair.
- **Older intents.** Intents written by 0.1.128 (sides survive) resume with their original manifest and the original downward-mirror repair. No user data is deleted retroactively.
- **Confirmation UI.** `ChatQuestion.list` sends the question to the new `ChatQuestionSheet`, which is built from Pi components: a scrolling body, at most 200 rows plus "and N more", depth indentation and warning-colored notes. Return and Escape choose Cancel for a destructive question. With no window available, it falls back to an alert whose list is limited to 20 rows.

## Changed files

- App
  - `Workspaces/WorkspaceSubagentDeletion.swift`: member discovery, preview, repair decision, ordering.
  - `Workspaces/WorkspaceChatLifecycle.swift`: confirmation and result.
  - `Storage/MetadataStore.swift`: graph query and the intent rule for side members.
  - `Storage/SessionDeletionRecord.swift`: `sideDepth`.
  - `Design/PiQuestion.swift`, `Design/ChatQuestionSheet.swift`.
- Helper
  - `HostService.swift`: the `session.forget` flags. No change to SessionCost, SessionRequestAdmission, AgentSteeringCoordinator, SessionSide or SessionRun.
- Docs
  - `docs/design/subagents.md` §5.6 and §9.5.

## Tests

New tests:

- Helper (`SideBudgetCrashMatrixTests`)
  - `testFamilyDeletionSkipsMirrorsIntoDeletedDescendants`, cold and loaded.
  - `testMemberForgetAfterTheRootRepairLeavesAncestorsUntouched`.
- App (`FamilyDeletionTests`)
  - Whole family, cold or warm, listed or unlisted, including a side-owned sub-agent.
  - The confirmation's list and wording.
  - A long list with a scrolling sheet.
  - Side deletion keeps 0.9 counted in main.
  - Interrupted deletion at six steps, relaunch marking and resume.
  - A missing or removed project, for both a main chat and a side. A sentinel file in the project folder stays untouched.
  - An earlier orphan survives until it is deleted itself.
- App (`SideBudgetIntegrationTests`)
  - Deleting main with no ready helper (absent, stopped or stopping) starts none.
  - Damaged side evidence cannot block a whole-family deletion, cold or with a ready helper.
  - A side's helper-start failure stays retryable.
- Gallery: `ChatDeletionGalleryTests` (`PI_APP_CHAT_DELETION_GALLERY`).

Tests updated because the old behavior they asserted is gone:

- Sides surviving owner deletion: `testDeleteActionAllowsAnIdleVisibleSide…`, `testDeletingAnOwnerDetachesAndDeletesItsLoadedSavedSides`, `testPersistedUnlistedSideAncestry…`, `testRestoreKeepsUnlistedAncestors…`.
- Main deletion repairing surviving sides with a cold helper: replaced by the tests above.

### Failing before the fix

- The helper tests were run against the HEAD `HostService.swift` with the new tests in place, and all 4 assertions failed:
  - The cold forget threw `subagent_recovery`.
  - The loaded forget threw `accounting_damaged`.
  - The member forget rewrote main's journal (2,353 vs 520 bytes).
- The pre-fix app does not have the new API the app tests call, so its old behavior was shown in two ways:
  - The first run of the updated old-semantics tests.
  - The mutations below.

### Mutation checks

Run against `FamilyDeletionTests` and `SideBudgetIntegrationTests`:

| Mutation | Result |
| --- | --- |
| M1: side members not added | 9 tests failed (whole family, side subtree, interruption, missing project, helper start, damaged evidence, no helper, unlisted, restore) |
| M2: missing project throws instead of skipping | `testMissingOrRemovedProjectDeletesOnlyTheChatsOwnFiles` failed |
| M3: main deletion always starts the helper | missing-project and no-ready-helper tests failed |
| M4: relaunch does not mark side members | survived: the per-side tombstone blocks opens on its own. The in-memory mark is kept as defense in depth (blocks discovery and ancestor retention before the first store read) |
| M5: `descendantsDeleted` not sent | `testDamagedSideEvidenceCannotBlockDeletingTheWholeFamily` (ready helper) failed |

### Focused runs

All with zero failures:

- `FamilyDeletionTests` + `SideBudgetIntegrationTests`: 25.
- `SubagentCostTests`: 11.
- 10 affected parallel classes plus `BudgetOwnerUnloadTests` and `PiQuestionSheetTests`, run with 4 workers: 142 passed. The one failure there was the obsolete survivor assertion, since updated.
- Serial-lane classes run alone: `ConversationPaneTests/testDeletingAChatAsksFirst`, `SubagentReaderTests`, `CaptureDrainTests`: 61.

### Gallery

The scenes are generated titles only: few sides, 240 sides, a missing project with a skip note, and no sides. Each is rendered light and dark, at 1240 and 340 wide. The images were checked by eye: buttons visible, long titles cut at the end, nested rows indented, notes legible in both themes.

### Full gate

See [Full gate result](#full-gate-result).

## Review round 1 and owner answers (2026-10-17)

Codex review findings:

- **Overlapping pending deletions.** Deleting a chat now first finishes this project's other interrupted deletions. Before adopting any side, it also checks that the side has no tombstone, failing closed with "An earlier deletion of … is still finishing". A new manifest therefore never overwrites another intent's owner receipt.
  - `testDeletingMainFinishesAnInterruptedSideDeletionInsteadOfAdoptingIt` interrupts a side deletion at `files:side`, hides the nested member from the chat window, then deletes main.
  - On the pre-fix code (mutation R1, which removes both changes), main's deletion overwrote the side's receipts ("main" instead of "side"). The resumed deletion then failed with "The desktop record could not be saved".
  - With only the finish-first step removed (R1b), the guard fails closed and names the unfinished deletion.
- **Published sides without a chat row.** `savedSideDescendants` now also reads `side-keep` intents that have no chat row and no tombstone. A side whose journal was published while registration failed is therefore listed, trashed and has its intent removed.
  - `testPublishedSideWithoutAChatRowGoesWithItsChat` covers this.
  - On the pre-fix code (R2), the journal and intent survived and no tombstone was written.

Owner answers:

- **Untrusted project.** Deletion is allowed and the one step that needs the helper is skipped. `deletionProjectUnavailable` reports an untrusted project, so a side is deleted without the helper. The confirmation names the skipped step: "Skipped: copying unreported spend from interrupted requests into “…”, which needs the project's helper." `testMissingOrRemovedProjectDeletesOnlyTheChatsOwnFiles` now also covers `untrusted`. With the mutation R3, the side deletion failed with the trust error.
- **Button label.** The action is "Delete Side" when the target is a side; main chats keep "Delete Chat". A mutation (R4) showed the confirmation test catches a regression.
- **Damaged side record.** The app itself never writes one. The never-delete-on-a-guess fallback covers only damage from outside the app.
- **Downgrade retry and capture projection rows.** Both are kept as described below.

The UI tests that delete through the confirmation now wait for the family's deleting mark to clear, not only for the record to disappear. The "missing side" case had raced the final unmark.

The rerun of the earlier mutations M1–M5 gave the same results on the new code. Run with the regenerated deletion gallery and its "Delete Side" and new skip copy (checked by eye), `FamilyDeletionTests` passed 9/9.

The merge of `origin/dev/next` (flakes workstream, a2691e9c) kept both 0.1.129 entries. The flakes workstream attributes the first gate's 11 gallery file-viewer timeouts to its own Finder-activating probe, and it fixed the 50 KB expansion heartbeat.

## Needs owner decision

- Untrusted project: answered (allow, skip the check).
- **Downgrade.** An older app that finds an interrupted 0.1.129 family intent cannot finish it, because its journal-name rule rejects `side_` members. It reports the incomplete deletion and keeps the intent until this version or a later one runs.
- **Damaged intermediate record.** A side below an unreadable intermediate side's metadata cannot be proven part of the family. It is left in place and becomes an independent chat after deletion, which is the 0.1.128 orphan behavior. It is never deleted on a guess.
- **Capture projection rows.** Capture-archive `side_budgets` projection rows for deleted sides stay, as they did for side deletion in 0.1.128. Their captures are cleared, so no total is affected.
- Button label: answered ("Delete Side").

## Full gate result

`PI_BUILD_ROOT=… scripts/verify-release.sh` was run on 86399a50 under the shared lock (2026-10-17, 59 min 35 s).

| Suite | Result |
| --- | --- |
| Native serial lane | 881 executed, 43 skipped, 1 failure |
| Native parallel lane (8 clones) | 2,637 passed, 0 failed, 38 skipped |
| Helper cost (alone) | 5/5 |
| Helper | 963 executed, 7 skipped, 0 failures |
| Wire | 36 OK |
| Concurrent | 4 OK |
| Acceptance | 3 OK |
| Python | 86 OK |
| Screenshot gallery (alongside the helper checks) | 3 executed, 11 failures in `testRenderRedesignGallery` |

Neither failure involves deletion code:

- **Serial-lane failure.** `SubagentPerformanceTests.testFiftyKilobyteMarkdownResultInALongChatKeepsTheMainThreadResponsive` measured a 101.7 ms gap against its 100 ms bound. This is a timing bound in transcript rendering, which this branch does not change. The class passed 2/2 when run alone on the same build.
- **Gallery failures.** All 11 were file-viewer waits ("folder menu is visible", "preview to load", "long-path fixture is read"), which this branch does not change. Rerun alone under the lock on the same build, `UIScreenshotTests` passed 3/3 with 0 failures and 230 screenshots.

## Full gate result, round 1

`verify-release.sh` was run on bb6e3107 (round-1 fixes merged with `origin/dev/next`) under the shared lock (58 min 50 s).

| Suite | Result |
| --- | --- |
| Native serial lane | 887 executed, 43 skipped, 1 failing test (2 assertions) |
| Native parallel lane (8 clones) | 2,637 passed, 0 failed, 38 skipped |
| Helper cost | 5/5 |
| Helper | 963 executed, 7 skipped, 0 failures |
| Wire | 36 OK |
| Concurrent | 4 OK |
| Acceptance | 3 OK |
| Python | 86 OK |
| Gallery | 3/3, 230 screenshots |

The earlier 50 KB perf and gallery failures did not recur.

The serial-lane failure was `SubagentOpeningTests.testLiveDiscoverySurvivesTopicMovesAndLosesAuthorityWhenTheHelperExits`: the child status was still `running` where `interrupted` was expected after the helper exited. This is sub-agent discovery after a helper exit, not deletion; the class does not call deletion. It is unchanged by this branch and passed 12/12 in each of five runs alone on the same build. It is handed to the flakes workstream; I did not try to fix it.

## Review round 2 and the SubagentOpening intermittent failure (2026-10-17)

### `SubagentOpeningTests.testLiveDiscoverySurvivesTopicMovesAndLosesAuthorityWhenTheHelperExits`

**Symptom.** In the round-1 gate's serial lane, the child stayed `running` after the helper was killed; the test expected `interrupted`. The class passed 12/12 in five runs alone.

**Cause (product).** With capture on, `HostTransport.captureEnded` reports `.failed` as soon as the helper process dies. `fail()` then runs `onLoss`, which calls `interruptSubagents` and marks running children `interrupted`. The `.exited` event, which is what clears `connectionID`, arrives only after the pending capture task and the `interrupted` capture write have finished. Under load, that gap is long.

During that gap, a live `subagent.list` registration can finish. In the fixture, such registrations are frequent: the parent is mid-turn and its snapshot refreshes call `refreshSubagentGroups` whenever `subagentsRevision` changes. If the registration already had its reply, it was waiting on archive/history actor hops when the helper died. Its only authority check was `connectionID == connection`, which still held, so it wrote `running` back over the interruption. When `.exited` arrived, nothing interrupted the children again, because the loss had already been reported once.

**Evidence.** The new deterministic test `testLiveRegistrationFinishingAfterHelperLossCannotRestoreRunning` reproduces the window exactly:
1. It delivers `.failed` on the live connection, so `connectionID` is unchanged.
2. It checks that the child is now `interrupted`.
3. It completes a live list registration for the old connection.

On the pre-fix code, the status went back to `running`, the same symptom as the gate.

**Fix.** Live sub-agent summaries are accepted only while the connection is both current and ready (`liveSubagentAuthority`). `fail()` clears `isReady`. The check is applied in `registerDiscoveredSubagent` and in both guards in `refreshSubagentGroups`.
- Mutation S3 (drop the ready check): the new test fails with `running`.
- After the fix: `SubagentOpeningTests` passed 13/13.

**Reproduction attempts on the original test.** Each was run under the full-lane lock, with 10 `yes` CPU hogs, as 15 consecutive single-test runs:
- Pre-fix code: 0 of 15 failed.
- Fixed code: 0 of 15 failed.

The window depends on capture-finalization timing in the full serial lane, so the original test was not reproduced on its own. The deterministic test covers the mechanism instead.

### Codex review round 2

- **[P2] Side marks leaked when the tombstone read failed.** Each side is now added to the cleanup set before the tombstone await, so any failure releases its deleting mark. A test seam `deletionTombstoneRead` exists for this.
  - New test `testFailedTombstoneReadReleasesEverySideMark`: the read fails, no side stays marked, the side reopens, and a retry deletes the whole family.
  - Mutation S1 restores the old order: `["side"]` stays marked and reopening fails with "This chat is being deleted."
- **[P3] Deleted sides' recovery notices lingered.** Deleting a member now removes its `sideKeepIssues` entry and advances `sideKeepResolutionRevision`, as registration and dismissal already do.
  - `testPublishedSideWithoutAChatRowGoesWithItsChat` now also asserts that the notice is gone.
  - Mutation S2: the notice stayed.

Focused results: `FamilyDeletionTests` passed 10/10 and `SubagentOpeningTests` 13/13, both under the lock.

### Full gate, round 2

`verify-release.sh` was run on bfa9387d under the shared lock (58 min 46 s).

| Suite | Result |
| --- | --- |
| Native serial lane | 888 executed, 43 skipped, 1 failing test |
| Native parallel lane | 2,638 passed, 0 failed, 38 skipped |
| Helper cost | 5/5 |
| Helper | 963 executed, 7 skipped, 0 failures |
| Wire | 36 OK |
| Concurrent | 4 OK |
| Acceptance | 3 OK |
| Python | 86 OK |
| Gallery | 3/3, 230 screenshots |

`SubagentOpeningTests` passed in the lane.

The serial-lane failure is a new intermittent one, not explained yet, in code this branch does not touch: `InspectorNativeControlTests.testRawSearchAfterExpandedTextAndResponseKeepsTheInitialHeaderInset`. The wait "The whole system prompt and tool schemas mount before raw search" timed out after 11.5 s, and the test then threw `CancellationError`. The class passed 12/12 in each of five runs alone under the lock on the same build. Its cause is not investigated here.
