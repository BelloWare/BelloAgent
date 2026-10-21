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

## Separate observations for the lead (round 1)

These were pre-existing and outside the three round-1 findings. Round 2 below
fixes all three:

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

## Round 2 — the three reported issues

After lead review and a read-only Astra review of `10d2636f` (no findings), the
coordinator asked for the three observations above to be fixed under the same
state model. Evidence: `evidence/round2/` (text logs, `.command` files).

`round2/failing-first-final.log` ran the five new regressions with the round-2
production sources stashed (production as of `10d2636f`): **5 tests, 34
failures, 0 unexpected**. Only the "empty, idle side" control state passed.
With the fixes, `round2/fixed-final.log` passes all five.

### `/side Q` is never lost (item 1)

- The slash handler empties the parent composer only after `openSide` returns
  true, which with a question means a side captured Q as its first message (the
  round-1 path: pinned under the launch lease, recorded before any publication
  await). Every refusal returns false before the composer is touched, so Q and
  `directCommand` stay exactly as typed and the composer's normal save keeps Q
  durable. No restore or extra recovery path is needed because nothing is
  removed.
- Refusal notices: "Wait for the current side to finish opening before starting
  another. Your question is still in this chat's composer." (the old text plus
  the reassurance). A refused question also keeps the cursor in the parent
  instead of moving it to the opening side; `/side` without a question and
  menu/button opens behave as before.
- A new side whose send refuses before capture (size, storage, launch lease) is
  removed again, leaving no side holding Q, and the send's own message
  explains. A connection that is gone would have been *captured but never
  sent*, so it is refused before the send with the connection's own message.
- `testSlashSideQuestionStaysInTheParentWhileAnotherSideIsPublishing`: before,
  the composer was empty and the saved draft absent (Q lost). After, the
  composer and its saved draft hold `/side Explain this failure`.
- `testSlashSideQuestionTheSideCannotSendStaysInTheParent` (256 KiB + 1 byte
  question; deleted connection): before, the composer was emptied and a
  pending side held Q; after, the composer keeps the command and no side exists.

### A pending side is never overwritten or raced (item 2)

Choice: **refuse with a notice and keep Q in the parent composer** whenever the
pending side holds anything of its own or is busy. An empty, idle pending side
still takes Q as its first message, as before (no input is replaced or raced
there). Queueing was not chosen: no path queues a message behind a pending
side's first send (`send` refuses while it loads), and merging Q into the
side's typing would change what that side sends. **Needs owner decision**: the
notices below are new visible behavior where the old code silently replaced
the side's typing (or left Q unsent there).

- Busy (first send under way, or a recovery transaction): "Wait for this chat's
  side to send its first message. Your question is still in this chat's
  composer."
- Holds input (typing, images or skills, an image arriving, returned-input
  review, captured/recoverable/uncertain input, a pending transfer or conflict):
  "This chat's side has an unsent draft. Send or close it first; your question
  is still in this chat's composer."
- `testSlashSideQuestionNeverReplacesOrRacesAPendingSide` covers "sending"
  (empty composer during the first send), "sending and typed", "typed" and
  "empty". Before: Q replaced the side composer in the first three, was sent in
  place of the typing in "typed", and the parent was emptied. After: the side's
  text is untouched, only its own first message is sent, and Q stays put; the
  empty side takes and sends Q.
- `sendSideQuestion` counts as captured only a submission that send itself
  started, not one already in flight (defense in depth; the busy guard already
  excludes that case).

### Continue keeps its click's archive authority (item 3)

- `continueAfterCostLimit` captures `archiveRevisions[id]` at the click and
  checks `requireUnarchived` after opening the helper, before `turn.retry`, and
  again before the `queue.resume` fallback (after an answered `turn.retry`).
  Archive, or Archive then Restore, retires it with the existing "Archive
  cancelled this operation" message; a new Continue works.
- `testArchiveDuringCostLimitContinueOpeningRetiresIt` (archived; archived then
  restored) and `testArchiveDuringCostLimitContinueStopsItsQueueFallback`
  (`turn.retry` answered `nothing_to_retry` after Archive + Restore). Before:
  `turn.retry`, respectively `queue.resume`, was dispatched; after: neither.
- Entry-point audit: Retry (`action("turn.retry")`), Resume Follow-ups and the
  queue's Resume (`action("queue.resume")`, also from `resumeOrSendQueued`),
  Compact (`action`), Resume (`resumeRun`, ordinary and the round-1 family path)
  and Send/Steer/Resend already capture the archive revision at the click and
  check it before dispatch. Responses incomplete-reply retries are helper-side
  policy retries with no app entry point. `continueAfterCostLimit` was the
  only gap.

### Round-2 mutation evidence

`round2/mutations-round2.py` (same runner semantics as round 1, against the
final round-2 source; `round2/pre-mutation-sha256.txt` matched after every
run). All **7 mutations compiled and failed** (exit 65); `round2/mutations/results.json`.

| Mutation | Source change | Failing test | Assertions |
| --- | --- | --- | ---: |
| `r2-m1-clear-before-side-takes-it` | slash handler empties the composer before `openSide` (old order) | all three `/side` tests | 14 |
| `r2-m2-keep-uncaptured-side` | a side whose send refused before capture is kept | cannot-send (size, connection) | 2 |
| `r2-m3-no-connection-precheck` | connection refusal not checked before the send | cannot-send (connection) | 3 |
| `r2-m4-race-first-send` | no busy guard for a pending side's first send | pending side, sending states | 2 |
| `r2-m5-replace-side-typing` | the side's typing no longer counts as its own input | pending side, typed state | 7 |
| `r2-m6-no-archive-check-before-retry` | no archive check before `turn.retry` | Continue archived / restored | 4 |
| `r2-m7-no-archive-check-before-queue-fallback` | no archive check before the `queue.resume` fallback | Continue queue fallback | 2 |

r2-m4 fails only on the notice text: without the busy guard, `holdsNothing`
still refuses a side whose first send is pinned (its input is captured), so Q
stays in the parent either way; the guard supplies the accurate notice.

### Round-2 validation

**761 native tests passed across 46 classes; zero failures or skips**, all on
the final round-2 sources (`round2/tested-source-sha256.txt`). The round-1
classes were rerun, plus `CostLimitOpeningTests` for the changed Continue path.
Parallel-lane classes ran together with parallel testing disabled; every
serial-lane run held the shared full-lane lock (`round2/serial-runs-round2.sh`).

| Run (log under `round2/`) | Classes and passed tests |
| --- | --- |
| `final-headless.log` (501) | AutomaticContextTests 11, ContextAndSkillPolicyTests 12, ConversationFamilyTests 22, CostLimitOpeningTests 1, CostPausePresentationTests 6, DeferredCreationTests 4, DraftConcurrencyTests 36, DraftLoadingTests 15, DraftOrderingTests 19, FamilyDeletionTests 10, MetadataDurabilityTests 10, ModelSwitchTests 24, OrganizationBatchTests 9, RecoveredDraftTests 13, RunHoldTests 18, SendBookkeepingTests 12, SessionOrganizationTests 9, SettingsSaveTests 15, SideBudgetIntegrationTests 18, SideKeepOrderingTests 12, SideKeepRecoveryTests 15, SideTests 17, SidebarMultiSelectionTests 4, SkillRefreshTests 15, SubagentDeletionTests 19, SubmissionPersistenceTests 81, WorkspaceConcurrencyTests 12, WorkspaceRaceTests 62 |
| `final-window.log`, locked (154) | CompactionResponsivenessTests 1, ConnectionSwitchJournalTests 6, CostLimitTests 13, CostPauseFamilyTests 3, LaunchSelectionTests 21, PendingChatProjectTests 24, SideRelaunchTests 3, SubagentNavigationTests 7, SubagentOpeningTests 15, TopicOrganizationTests 14, WorkspaceFollowupTests 9, WorkspaceRefreshLifecycleTests 38 |
| `final-lifecycle.log`, locked | LifecycleHelperTests 11 |
| `final-queue.log`, locked | QueueEditInteractionTests 17 |
| `final-subagent-reader.log`, locked | SubagentReaderTests 58 |
| `final-native-application.log`, locked | NativeApplicationTests 12 |
| `final-smooth-shell.log`, locked | SmoothShellTests 5 |
| `final-shell-performance.log`, locked | AppShellPerformanceTests 3 |

No helper, wire contract or request payload changed, so helper and wire suites
were not required. No layout, component or style changed; the new refusals use
the window's existing error banner, so no gallery was regenerated. The
automatic result bundle was deleted after the last run. `git diff --check`
passes.

### Remaining observations (not fixed)

- Continue had no in-flight guard (fixed in round 3 below) and has no Stop
  fence. Stop is not offered on a chat stopped at its limit, so the missing Stop
  fence is not reachable from the UI today.
- The parent composer's emptied snapshot after a captured `/side` question is
  still the ordinary 150 ms debounced write beside the side's record (round-1
  residual note above): unchanged, as for Send.

## Round 3 — one request per Continue, Retry or Compact press

Round 2 (`bb037100`) was accepted; the item-2 refusal notices stay as the
conservative choice for the owner's post-release decision list. Round 3
closes the double-click gap noted above. Evidence: `evidence/round3/`.

### What the helper does with a repeated press (read-only check)

- `AgentSession` is an actor and `retryRun` (`turn.retry`) launches its run
  synchronously. A second retry that lands while the first run is active is
  refused `session_busy` ("Run already active"), which the app showed as an
  error banner. If the first run has already failed again (`state == .error`),
  the second retry **runs again: a duplicate provider request**. If the first
  has already succeeded, the second answers `nothing_to_retry`, and Continue
  then fell back to `queue.resume`.
- A second `context.compact` while the first compaction runs **stops it and
  starts a new one** (`compact()` stops a running task, waits for it, then
  launches), so a repeated Compact Now replaced the first summary request with
  a second.
- Repeated presses share one helper open and dispatch back to back, so the
  busy refusal or restarted compaction is the usual outcome, and a fast
  failure turns a retry into a duplicate request.

### Fix

- `runActionsInFlight` holds one key per chat and action: Retry and the
  cost-limit Continue share one (both send `turn.retry`), Compact has its own.
  A press is admitted only when no attempt with its key is on its way; a repeat
  is ignored, with no request and no notice. The key is released when that
  attempt's task ends (sent, refused, failed, or retired by Archive), so the
  action works again once it has settled.
- A `/compact` typed while a compaction is on its way stays in the composer
  instead of being emptied and dropped.
- Audit of the round-2 entry points: Resume (`resumeRun`), the family Resume
  and Resume Follow-ups / the queue's Resume already admit one at a time
  (`resumeTasks`, `view.resuming`); Send and Steer set `view.loading` at
  Return; Resend holds `editSubmitting` (a repeat keeps its existing "Waiting
  for the current operation to finish." notice). Left alone: Stop (idempotent)
  and *different* actions pressed within one window (for example Retry, then
  Resume Follow-ups), which the helper refuses as busy and which are not a
  same-action duplicate.

### Evidence

- `testRepeatedOneShotRunActionsWhileOpeningSendOneRequest` (Continue, Retry,
  Compact): two presses before and one during a held helper open, plus a typed
  `/compact`. Before (`round3/failing-first.log`, production at `bb037100`):
  3 `turn.retry` for Continue and for Retry, 4 compactions and an emptied
  composer for Compact (**1 test, 7 failures**). After: exactly one request
  each, no error or notice, the typed command kept; once settled, one more
  press sends exactly one more request.

### Round-3 mutation evidence

`round3/mutations-round3.py` (same runner semantics; `round3/pre-mutation-sha256.txt`
matched after every run). All **4 mutations compiled and failed** (exit 65).

| Mutation | Source change | Assertions |
| --- | --- | ---: |
| `r3-m1-no-action-guard` | Retry/Compact presses no longer checked in `action()` | 4 (3 requests for Retry and Compact) |
| `r3-m2-no-continue-guard` | Continue presses no longer checked | 2 (3 `turn.retry`) |
| `r3-m3-typed-compact-dropped` | `/compact` emptied while one is on its way | 1 (typed command lost) |
| `r3-m4-never-settles` | the attempt never releases its key | 2 (Retry never works again) |

r3-m3 shows why the slash check is separate: the `action()` guard still blocks
the second compaction, but the typed command would be emptied and lost.

### Round-3 validation

**236 native tests passed across 14 classes; zero failures or skips**, on the
final sources (`round3/tested-source-sha256.txt`). `runs.sh` ran the headless
classes together and the serial ones under the shared full-lane lock.

| Run (log under `round3/`) | Classes and passed tests |
| --- | --- |
| `final-headless.log` (216) | ConversationFamilyTests 22, CostLimitOpeningTests 1, CostPausePresentationTests 6, FamilyDeletionTests 10, ManualCompactionTests 1, RunHoldTests 18, SubagentCostTests 11, SubmissionPersistenceTests 81, TranscriptActionsForwardingTests 3, WorkspaceRaceTests 63 |
| `final-cost-serial.log`, locked (17) | CompactionResponsivenessTests 1, CostLimitTests 13, CostPauseFamilyTests 3 |
| `final-cost-parity.log`, locked (3) | CostLimitParityTests 3 |

No helper source, wire contract, layout or style changed; the helper was only
read to establish its behavior. The automatic result bundle was deleted after
the last run, and `git diff --check` passes.

## Round 4 — a published side reopens its own journal

A read-only Astra review through `8f21cf8d` found one issue, a consequence of
round 1 routing `/side Q` into the pending-side first send. Evidence:
`evidence/round4/`.

### [P2] Reopen published sides using their registered chat record — confirmed and fixed

Trace (verified): `deliverSubmission` keeps the `ChatRecord` captured on
Return. For a pending side that is `SideRecord.chat`, whose `path` is nil.
`publishPendingSide` registers the side (`side_<id>.jsonl`, budget parent), and
the send then opened the runtime with the captured record. Normally the side
is already open there (fast path). But if the helper exits between publication
and that open, `open()` sent `session.open` without a path, the replacement
helper started `<id>.jsonl`, and `open()` wrote that path over the registered
one, in memory and in SQLite. The side lost its inherited history and its family
budget association (`persistedBudgetParentID` needs `side_<id>.jsonl`). This
applies to every first message of a pending side (typed, quoted or `/side Q`);
the old `/side` path only sent after registration.

- Fix: once the side is published, `deliverSubmission` opens its runtime from
  the registered record (journal and family); the message and its choices
  (model, effort, limits, skills, images) stay as captured on Return, since
  `turnOverrides` still reads the captured record.
- `open()` never puts another file in place of a registered journal. A caller
  whose record would open a different journal (a record read before
  registration names none, so the helper would start `<id>.jsonl`) is refused
  before any `session.open`: "This chat's saved conversation changed while this
  was starting. Try again." A main chat's default journal is that same file, so
  a new chat's first send is unaffected. If the helper answers with another file
  anyway, the runtime it opened is closed and the open is refused instead of
  overwriting the path.
- Other first-send paths: typing into an empty side, quoted sides and `/side Q`
  all go through `deliverSubmission`. Keep and Close register a side without
  opening it; a send captured before such a registration and opened after a
  helper loss is now refused by `open()` (not dispatched, so it returns to its
  composer with the notice) instead of rewriting the path.
- `testPublishedSideReopensItsOwnJournalAfterHelperLoss` (typed and `/side Q`):
  the existing stub helper-loss fixture fails the helper at a new `"published"`
  send step, after registration and before the runtime open. After the fix the
  replacement opens `side_<id>.jsonl`, the record and SQLite path and the budget
  owner are unchanged, and Q is sent once.
- `testOpenNeverReplacesARegisteredJournal` (stale caller; helper answering
  with another file): refused with the notice, path unchanged, no runtime left
  (`[]`, respectively `["session.open", "session.close"]` for the side).
- Failing-first: `round4/failing-first.log` ran both tests on `8f21cf8d` plus
  only the `"published"` send-step seam (`round4/failing-first-production.diff`):
  **2 tests, 16 failures**. The replacement opened `<id>.jsonl`, the registered
  path was replaced in memory and SQLite, and the budget owner became the side
  itself; the stale caller and the other-file answer each rewrote the path and
  left a runtime (`session.open`, `debug.mode`). `round4/fixed-first.log`: both
  pass.

### Round-4 mutation evidence

`round4/mutations-round4.py` (same runner semantics; `round4/pre-mutation-sha256.txt`
matched after every run). All **3 mutations compiled and failed** (exit 65).

| Mutation | Source change | Failing test | Assertions |
| --- | --- | --- | ---: |
| `r4-m1-open-captured-record` | the send opens the captured pre-publication record | reopen after helper loss (typed, `/side`) | 8 |
| `r4-m2-no-stale-record-refusal` | no refusal before `session.open` | stale caller | 1 |
| `r4-m3-no-path-overwrite-guard` | a helper's other file is written over the registered path | other file | 5 |

The checks back each other up without hiding a regression. With m1, the
refusal keeps the journal intact but the question is not delivered (refused
with the notice). With m2, the post-open guard still restores safety but only
after a runtime was opened on the wrong file and closed again.

### Round-4 validation

**801 native tests passed across 53 classes; zero failures or skips**, on the
final sources (`round4/tested-source-sha256.txt`). Because `open()` is shared by
every chat, the round-2 set was rerun with `ForkCloneReaderTests`,
`ImportLifecycleTests`, `SubagentMetadataTests` and `InheritedSubagentReaderTests`
added. Parallel-lane classes ran together with parallel testing disabled; every
serial-lane run held the shared full-lane lock (`round4/round4-runs.sh`).

| Run (log under `round4/`) | Classes and passed tests |
| --- | --- |
| `final-headless.log` (533) | AutomaticContextTests 11, ContextAndSkillPolicyTests 12, ConversationFamilyTests 22, CostLimitOpeningTests 1, CostPausePresentationTests 6, DeferredCreationTests 4, DraftConcurrencyTests 36, DraftLoadingTests 15, DraftOrderingTests 19, FamilyDeletionTests 10, ForkCloneReaderTests 1, ImportLifecycleTests 4, ManualCompactionTests 1, MetadataDurabilityTests 10, ModelSwitchTests 24, OrganizationBatchTests 9, RecoveredDraftTests 13, RunHoldTests 18, SendBookkeepingTests 12, SessionOrganizationTests 9, SettingsSaveTests 15, SideBudgetIntegrationTests 18, SideKeepOrderingTests 12, SideKeepRecoveryTests 15, SideTests 17, SidebarMultiSelectionTests 4, SkillRefreshTests 15, SubagentCostTests 11, SubagentDeletionTests 19, SubagentMetadataTests 9, SubmissionPersistenceTests 81, TranscriptActionsForwardingTests 3, WorkspaceConcurrencyTests 12, WorkspaceRaceTests 65 |
| `final-window.log`, locked (154) | CompactionResponsivenessTests 1, ConnectionSwitchJournalTests 6, CostLimitTests 13, CostPauseFamilyTests 3, LaunchSelectionTests 21, PendingChatProjectTests 24, SideRelaunchTests 3, SubagentNavigationTests 7, SubagentOpeningTests 15, TopicOrganizationTests 14, WorkspaceFollowupTests 9, WorkspaceRefreshLifecycleTests 38 |
| locked singles (114) | LifecycleHelperTests 11, QueueEditInteractionTests 17, SubagentReaderTests 58, InheritedSubagentReaderTests 8, NativeApplicationTests 12, SmoothShellTests 5, AppShellPerformanceTests 3 |

No helper, wire contract, layout or style changed. The new notice reuses the
send failure row's existing presentation. The automatic result bundle was
deleted after the last run, and `git diff --check` passes.
