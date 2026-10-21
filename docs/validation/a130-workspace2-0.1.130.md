# Workspace hunt fixes (APP-WORKSPACE-7/8/9) — 0.1.130

Workstream: `dev/a130-workspace2`, based on `dev/next` `78729efa`.
Worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-a130-workspace2`.
Build/evidence root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace2`
(text logs under `evidence/`; no named result bundle).

## Decisions and boundaries

All three hunt findings are confirmed by failing-first tests against the
unchanged `78729efa` production code. Every fix keeps the Round-17
captured-input state model ([state model](a130-workspace-0.1.130.md#state-model-recorded-before-implementation)):
input is pinned before any await, owned by the per-launch lease, durably
recorded before dispatch, hidden while its task lives, and recoverable through
an indexed parent after a crash.

Owner-approved behavior is unchanged: sides stay read-only and cannot start
sub-agents, an unkept side's composer is still never persisted (the durable
home is the captured submission, as for every side first send), and a cost
limit still pauses the whole family until an explicit Resume. No wire schema,
helper source, permission, capture, tool, vault or data boundary changed.

Fixtures use scratch SQLite stores, `MemoryVaultStorage`, generated journal
headers, the command-sender seams, the workstream's packaged helper and a
generated loopback catalog (`ModelListGateway` on 127.0.0.1). No installed app,
real preferences, real chats, Keychain, live capture or paid provider was used.

## Findings and failing-first evidence

`evidence/failing-first.log` ran the four primary regressions against the
unchanged production code: **4 tests, 27 failures (1 unexpected: a timed-out
wait)**. `evidence/failing-first-switch-steps.log` and
`evidence/failing-first-member-authority.log` ran the two later checkpoint
tests with the production sources stashed: 6 failures (1 unexpected: the
refused reopen) and 3 failures. With the fixes,
`evidence/fixed-first.log` (5 tests) and `evidence/fixed-member-authority.log`
(1 test) pass with zero failures.

### APP-WORKSPACE-7 — confirmed and fixed

Trace (verified): the `/side` handler empties the parent composer
(`WorkspaceResources.swift:327`). `openSide(question:)` then created a
non-pending side and called `publishPendingSide` without a submission, which
saved only the unregistered side's draft holding the question, and called
`send` only after publication. Launch recovery moves missing-journal input
only when `pending:<side>` has a record (`WorkspaceSides.swift` reconcile), so
a crash while the parent opened left only the missing-file review notice.

- `SubmissionPersistenceTests.testSlashSideQuestionSurvivesProcessLossWhileItsParentOpens`:
  submit `/side Explain this failure` in a saved chat, hold the parent's
  `session.open` after the side's metadata commits, then simulate process loss
  and run `restore()` on a new model over the same state root. Before:
  `XCTAssertEqual failed: ("[]") is not equal to ("["Explain this failure"]")`,
  a missing-file notice in `sideKeepIssues`, and the parent never offered the
  question. After: the exact question is the parent's durable recovery, no
  input remains under the side, and Insert commits it to the parent draft.
- Process loss: the original model cannot be deallocated while its held
  publication task retains it. The test drops its per-launch lease (what the
  kernel does to a crashed owner's `flock`) and runs no shutdown, flush,
  transfer or failure path; the new model sees only durable records.
- `testSlashSideQuestionIsCapturedAtOnceAndSentOnce`: before, nothing was
  captured on Return (`submittingCommands` 0) and the question sat in the side
  composer during publication. After: captured at once, one `turn.submit` with
  the exact text, side kept.
- Fix: a non-empty `/side` question creates the pending side and is sent as
  its first message, the same path as typing into an empty side. The send pins
  it under the launch lease; `publishPendingSide` commits the keep intent and
  the independent pending record before parent opening or `side.open`; failures
  follow the Round-13 path (parent link kept; Close/Quit/relaunch move the input
  to parent recovery). The old in-place publication and its unwind are removed.
- Visible difference, transient only: while the side opens, the question shows
  as the side's sending row with an empty composer, instead of sitting in the
  loading composer. This is the existing presentation of a side's first send;
  no gallery scene covers either transient state and the final state is
  unchanged (`SideRelaunchTests` `/side <question>` scenario passes).

### APP-WORKSPACE-8 — confirmed and fixed

Trace (verified): `resumeRun` leaves for `resumeCostPausedFamily` before its
archive capture; the family task awaits `rootCostPause` (root opening), then
`performResume` captured the archive revision only then, after Archive. Archive
advanced `archiveRevisions` but neither cancelled the task nor stopped the
paused root (`stopForArchive` skips it: not busy). After Restore the old Resume
sent `run.continue`.

- `WorkspaceRaceTests.testArchiveAndRestoreDuringRootOpeningRetireAFamilyResume`
  (root archived, and a paused side archived): before, `2` `run.continue` after
  Archive + Restore in each variant, and a fresh Resume made four. After: zero
  until the fresh Resume, which resumes `[root, side]`.
- `testFamilyResumeKeepsItsArchiveAuthorityForMembersOutsideTheLoadedFamily`:
  a nested side whose parent side is not loaded until the root opens, archived
  in the same turn as the click. Before: `["chat", "nested"]` continued. After:
  only the untouched root continues; the member is refused with the existing
  "Archive cancelled this operation" error and leaves no pending record.
- Fix: the family Resume captures `archiveRevisions` at the click and passes
  each chat's admitted revision to its `performResume` (root and every member
  named later). Archiving any chat whose budget owner has a pending family
  Resume retires it synchronously at the click with the Stop fence (stop
  revision + task cancellation), so Restore cannot revive it. A chat's own
  Resume keeps its existing archive-revision check and message.

### APP-WORKSPACE-9 — confirmed and fixed

Trace (verified): `setConnection` captured `target` before awaiting the
catalog; `ModelCatalog.load` returns normally when `deleteProfile` invalidates
(cancels) the listing; the recheck only covered chat activity, so the switch
closed the session, rebound the journal, saved the deleted ID and announced
"Next turn uses …".

- `WorkspaceConcurrencyTests.testAConnectionDeletedWhileItsCatalogLoadsIsNeverSwitchedTo`
  (packaged helper, journal-backed chat with a model override, loopback catalog
  held): the listing either finishes while the deletion's vault write is held,
  or is cancelled by the completed deletion. Before, in both: steps
  `closed/marked/rebound/metadata`, record `doomed-connection`, success notice,
  no error, session closed and the chat no longer opened. After: no step runs,
  the chat stays on its connection (record, store, model override), no success
  notice, the error explains it, and the chat's session stays open there.
- `testADeletionAtEachSwitchStepIsNeverAnnouncedAsTheChatsConnection`: deletion
  at `closed` (refused before the journal moves), `rebound` (journal bound back
  and unmarked at once), `metadata` (not published; journal stays marked and the
  next open binds it back, as for a failed record write) and during the final
  record write (the deletion could not count the chat: it shows the deleted-
  connection notice, never "Next turn uses"). Before: the `closed` case already
  published the deleted connection and its reopen failed.
- Fix: the destination's deletion generation is captured at admission;
  `destinationSaved()` (not being deleted, same generation, still a saved
  Responses connection) is checked after the preparation awaits, before the
  journal moves, after the rebind and before metadata publication. Failure
  leaves the chat on its connection with
  "That connection was deleted before this chat could switch to it. The chat
  stays on its current connection." The deleted-connection notice text is now
  one constant shared with `deleteProfile`.

## Mutation evidence

`evidence/mutations.py` applies one exact single-match replacement to the final
production source, runs the two pinning tests of that finding, and restores the
exact bytes in `finally`; `pre-mutation-sha256.txt` matched after every run.
All **8 mutations compiled and failed** (exit 65); `mutations/results.json`
lists the failed tests. m1 and m3e were rerun after two synchronization-only
test edits (first runs kept in `mutations-initial/`, same outcome).

| Mutation | Source change | Failing test | Assertions |
| --- | --- | --- | ---: |
| `m1-publish-before-capture` | `/side` publishes the side, then sends (old order) | both `/side` tests | 6 |
| `m2a-no-archive-retirement` | Archive no longer retires the family Resume | root/side Archive + Restore | 5 |
| `m2b-member-revision-captured-late` | member continue reads the archive revision after discovery | member authority | 2 |
| `m3a-no-check-after-preparation` | no destination check after the catalog | catalog deletion (both variants) | 4 |
| `m3b-no-check-before-rebind` | no check before the journal moves | step matrix `closed` | 1 |
| `m3c-no-check-after-rebind` | no check after the rebind | step matrix `rebound` | 3 |
| `m3d-no-check-before-publication` | no check before the record write | step matrix `metadata` | 6 |
| `m3e-no-check-after-publication` | no notice after a write the deletion overlapped | step matrix final write | 2 |

m2a also shows the admission snapshot working on its own: with retirement
removed, the archived chat itself was refused and only the other member
continued (`["side", …]` for the root case, `["chat", …]` for the side case).
m3b and m3c show the later checks backing each other up: the switch then stops
one step later (journal bound back, or left marked for the next open).

## Final validation

**755 native tests passed across 45 classes; zero failures or skips.** Counts
exclude failing-first, exploratory and mutation runs. Parallel-lane classes ran
together with parallel testing disabled; every serial-lane run held the shared
full-lane lock (`evidence/serial-runs.sh`), with no parallel-lane class mixed
in. `SubmissionPersistenceTests` and `WorkspaceConcurrencyTests` are counted
from their rerun: two synchronization-only test edits landed after the first
headless build (that run also passed them).

| Run (log) | Classes and passed tests |
| --- | --- |
| `final-headless.log` (394 counted of 484) | ContextAndSkillPolicyTests 12, ConversationFamilyTests 22, CostPausePresentationTests 6, DeferredCreationTests 4, DraftConcurrencyTests 36, DraftLoadingTests 15, DraftOrderingTests 19, FamilyDeletionTests 10, MetadataDurabilityTests 10, ModelSwitchTests 24, OrganizationBatchTests 9, RecoveredDraftTests 13, RunHoldTests 18, SendBookkeepingTests 12, SessionOrganizationTests 9, SettingsSaveTests 15, SideBudgetIntegrationTests 18, SideKeepOrderingTests 12, SideKeepRecoveryTests 15, SideTests 17, SidebarMultiSelectionTests 4, SkillRefreshTests 15, SubagentDeletionTests 19, WorkspaceRaceTests 60 |
| `final-headless-rerun.log` (101) | AutomaticContextTests 11, SubmissionPersistenceTests 78, WorkspaceConcurrencyTests 12 |
| `final-window.log`, locked (154) | CompactionResponsivenessTests 1, ConnectionSwitchJournalTests 6, CostLimitTests 13, CostPauseFamilyTests 3, LaunchSelectionTests 21, PendingChatProjectTests 24, SideRelaunchTests 3, SubagentNavigationTests 7, SubagentOpeningTests 15, TopicOrganizationTests 14, WorkspaceFollowupTests 9, WorkspaceRefreshLifecycleTests 38 |
| `final-lifecycle.log`, locked | LifecycleHelperTests 11 (includes the Resume extension) |
| `final-queue.log`, locked | QueueEditInteractionTests 17 |
| `final-subagent-reader.log`, locked | SubagentReaderTests 58 |
| `final-native-application.log`, locked | NativeApplicationTests 12 |
| `final-smooth-shell.log`, locked | SmoothShellTests 5 |
| `final-shell-performance.log`, locked | AppShellPerformanceTests 3 (both bulk-archive scenes and the `/side` parse check) |

Exact commands are in the matching `.command` files; for example:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace2 scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests -only-testing:PiAppTests/WorkspaceConcurrencyTests -only-testing:PiAppTests/AutomaticContextTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace2 scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SideRelaunchTests -only-testing:PiAppTests/CostPauseFamilyTests -only-testing:PiAppTests/ConnectionSwitchJournalTests -only-testing:PiAppTests/WorkspaceFollowupTests -only-testing:PiAppTests/PendingChatProjectTests -only-testing:PiAppTests/CostLimitTests -only-testing:PiAppTests/LaunchSelectionTests -only-testing:PiAppTests/CompactionResponsivenessTests -only-testing:PiAppTests/SubagentNavigationTests -only-testing:PiAppTests/SubagentOpeningTests -only-testing:PiAppTests/TopicOrganizationTests -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests
```

`tested-source-sha256.txt` matches every changed file; the production hashes
equal `pre-mutation-sha256.txt`. No file was added or removed, so the project
was not regenerated by hand (`test-macos.sh` runs `xcodegen` itself). Helper
and wire suites were not required: no helper source, wire contract or request
payload changed. No gallery was regenerated: no layout, component or style
changed, and no gallery scene shows a side while it opens (the only visible
difference, described under APP-WORKSPACE-7). The automatic result bundle was
deleted after the last run; text logs remain. `git diff --check` passes.

## Adversarial self-review

| Condition | Newly selected branch; intended outcome |
| --- | --- |
| `/side` question refused before capture (storage unavailable, lease error, size, deleted connection) | The question stays in the new pending side's composer (ephemeral; Close moves it to the parent), with the send path's existing message. Previously most of these returned it to the parent composer; nothing is lost either way. |
| Failure after capture (parent opening, `side.open`, registration) | Round-13 path: the pending side keeps its parent link and pinned input; Close, Quit, update and relaunch transfer it to parent recovery. No new unwind code. |
| Close, Quit, update, host loss or Show Side during the first send | Unchanged pending-side rules: Close and Show Side refuse while it is loading, Quit/update refuse while the submission is live, host loss keeps a side with live input. |
| Family Resume pending; unrelated chat archived | `budgetOwner` differs: nothing retired. |
| Family Resume already dispatched the root; a member archived | Remaining members are retired; the running root is unaffected (Stop has the same shape). |
| Archive refused or failed after the click | The Resume stays retired, as archive revisions already do for sends (APP-WORKSPACE-3). |
| Ordinary (non-family) Resume, queued Resume, Send, Edit, Compact | Unchanged: each keeps its own captured archive revision and message. |
| Deletion fails after it began | The generation already moved, so an in-flight switch refuses conservatively; a new choice proceeds normally. |
| Destination edited (same ID) during a switch | Not a deletion: proceeds as before. A route change (new ID) is refused like a deletion. |
| Deletion during the final record write | The chat names the deleted connection, the same state as a deletion just after the switch; it shows Settings' deleted-connection notice and no profile choice or context preview is started. |

Residual window, unchanged in kind: the parent composer's emptied snapshot is a
150 ms debounced write separate from the side's captured record, like ordinary
Send's composer write beside its record. A crash after that write commits but
before the record would lose the question. In practice the record commits
first: both wait for the same tool-output collection gate, after which the
debounce sleeps 150 ms while the record follows only the keep-intent write
(and, for an unsaved parent, its materialization) on the same store actor.

## Separate observations for the lead (not fixed)

These are pre-existing, outside the three assigned findings, and need either a
UX decision or a different function:

1. `/side <question>` while another side of the same chat is still publishing
   (`WorkspaceSides.swift` `openSide`, "Wait for the current side to finish
   opening before starting another."): the slash handler
   (`WorkspaceResources.swift:327`) has already emptied and saved the parent
   composer, so the question is lost. Same before and after this change.
2. `/side <question>` while that chat has a pending side (`openSide`'s
   `existing.pending` branch): the question replaces the pending side's
   composer (its unsent typing is lost); if that side's first send is still in
   flight, `send` returns silently and the question stays unsent there. The
   fix above makes a `/side` side pending during its own first send, so this
   branch, rather than item 1, now answers a second `/side` sent in that window.
3. `continueAfterCostLimit` (`WorkspaceCostLimits.swift:350`), reached from
   the cost-limit failure row's Continue pill
   (`TranscriptNativeFailureRow.swift:94`): Archive is checked only at the
   click; after `open(item)` it dispatches `turn.retry`/`queue.resume` without
   the APP-WORKSPACE-3 archive-revision fence, so Archive (or Archive +
   Restore) during the open still continues the run.
