# Cost limit pauses the family; sides never delegate — 0.1.129

Branch `dev/a129-limit-pause`, based on `dev/next` 9d4123f6 (released 0.1.128).
Owner decisions:

- A (2026-10-16). "Pause immediately, and support resume once I increase the limit" — "Wait for Resume click".
- A, revised (2026-10-17), for **all** chats, plain and family: cut only model requests ("just cut off model reply so you can resume cleanly"); running tools finish with real results; nothing new starts; held calls run first on Resume; never regenerate a reply whose calls are pending.
- B (2026-10## A. The limit-pause state machine (owner rule of 2026-10-17)

`AgentSession.stopFamilyAtLimit` → `pauseAtCostLimit` is the only budget pause. It
is not Stop (`stopCount` is unchanged) and has no drain fence.

| From | Event | To |
| --- | --- | --- |
| A run in progress (any chat), or a family member with a run, queued input or an unsealed child turn | Spend reaches the limit: own or plain-chat count, side, nested side, sub-agent or side-owned sub-agent settlement, a late correction, adoption, or lowering the limit | **Paused**: `costPaused` persisted first. Every model request in flight is cut (request permits; the run's request task `abortable`, which also cuts a retry back-off). Its partial reply becomes an interrupted row, never resent. Running tools are **not** cut. Sides are reached through the root's weak callbacks; children through `AgentSteeringCoordinator.pause` (their model requests only). |
| Paused, a tool running | It finishes | Its real result is recorded. The next gate (`enforceCostHold`: round start, retry attempt, tool batch; for a child also its owner's pause and its coordinator's hold) ends the run, paused. |
| Paused, a completed reply's calls not started (the crossing reply included) | Tool gate | **Held**: no result, ids saved as `costPendingCalls` (durable). A relaunch gives them no invented outcome. |
| Paused, a child turn's run ends (cut, gated, or refused) | Runner | **Parked**: `queued`, no result, in owner and child journals; runtime released. At its final boundary during the pause a child does not seal. A completed turn seals normally. |
| Paused, child turn queued | — | Stays queued (never `not_executed`). |
| Paused | The run ends with nothing held, queued, delegated, pending or cut off | Not paused: the chat is at its limit; new messages are refused there. A root paused only for a side clears when that side resumes or clears. |
| Paused | Final family boundary or `subagent_wait` | The boundary ends the run (held); a wait returns `wake_reason: paused` (it is not cut). |
| Paused | Quit, relaunch, helper restart | Still paused; a tool still running at quit is interrupted as Stop does (unknown outcome, not replayed); held calls stay held; parked turns stay queued (a turn still `running` after a crash is requeued). |
| Paused | Limit raised | Still paused. Nothing starts. |
| Paused | New user message | Queued for after Resume. |
| Paused | Resume at or over the limit | Refused, `cost_limit`, with the reason. Any refused Resume (including invalid overrides) leaves the pause and side membership exactly as they were. |
| Paused | Resume below the limit | **Running**: held calls run first, from the reply that issued them; then a model request. The coordinator's hold is released even with no parked turn; Resume first waits for the pause's runners to finish parking, then requeues parked turns under the new execution (`continuations`). `pausedMembers` stay listed until each side resumes; a retried Resume still names them. |

 *Needs owner decision*).

Journal compatibility: no new status. `continuations` is optional and ignored by
older helpers (identity comparisons pass); an older helper reopening a paused family
seals its turns as interrupted, as for any crash. `costPaused`/`costPausedMembers`
are absent unless set.

### App

- Main chat and paused sides: **Paused at the cost limit** card with live spend and
  limit (`$X spent of the $Y limit.` / `of the main chat’s $Y limit.`), *Raise limit…*
  while the spend is at the limit (Resume unavailable, reason in the detail), then
  **Paused · cost limit raised** with *Resume*. Resume from any member resumes the
  root, then every side it names (opening unloaded ones). A chat read only from its
  journal shows Resume and lets the helper refuse it at the limit.
- Sub-agent cards, picker rows, child readers and footers say *Paused at cost limit* /
  *Paused*, with no Stop and no spinner/working badge. Sidebar: *Paused · cost limit*.
- The cold journal reader keeps the pause (and a run held across a crash mid-pause
  reads paused, not interrupted).

## B. Sides cannot delegate

`AgentSession.sideDelegationRefusal` refuses `subagent_start`, `subagent_send` and v2
`subagent` in any side (kept or not, any depth) with `read_only`: "Side chats cannot
start or message sub-agents: … Ask in the main chat to delegate this work." It runs
before acceptance (no operation, plan, child or adoption seed). The offered tool list
is unchanged and byte-equal to the parent's (`SideDelegationTests` compares the full
`ToolDefinition`s at depths 1–3), so the prompt-cache prefix is untouched. The side's
hidden note (sent once, after the inherited prefix) now also says it cannot start or
message sub-agents; existing sides keep theirs. Wait, status and Stop remain for
children a 0.1.128 side already owns; their history is unchanged. No UI became dead.

## Tests

Helper (`packages/swift-host/Tests/PiAgentCoreTests`):

- `FamilyLimitPauseTests` replaces `FamilyLimitStopTests`:
  `testEveryPhaseAndChargeSourceAbortsInFlightWorkAtOnce` (6 phases × 5 charge sources;
  one Stop, held requests cancelled at once including a nested side's, aborted charges
  kept, unknown stays unknown), `testQueuedAndRunningChildrenParkForEveryChargeSourceAndResumeInPlace`
  (18 accepted, 16 dispatched cancelled without release, all 18 parked queued, runtimes
  released, no terminal; raise resumes nothing; Resume completes all with one
  continuation, task never resent, mirrors equal), `testRealRunPausesTheFamilyAndResumesItAfterTheLimitIsRaised`
  (background, wait, tool-reply, queued; no tool runs; message sent while paused goes
  after), `testPauseSurvivesReopenAndACrashBeforeParkingThenResumes`,
  `testSidesPauseImmediatelyAndTheRootsResumeNamesThem`,
  `testLoweringTheLimitPausesAndRaisingItResumesNothing`,
  `testChildFinalBoundaryDuringThePauseDefersItsSeal`, `testRetryBackoffIsCutShortByThePause`.
- `SideDelegationTests` (depth 1–3 refusal, identical tools, fork still allowed; a real
  side run refused and continuing).
- Updated to the new semantics: `AgentSteeringBoundaryTests.testChildCostLimitPausesParentInUnrelatedToolUntilResume`,
  `SideBudgetTests.testEphemeralSpend…`, `testOpeningASideDuringTheParentsRequestKeepsItsChargeAndPausesIt`,
  `SubagentAdmissionTests` (2), `SubagentCoordinatorTests` (v2 limit; durable side refuses),
  `ChildCostPublicationTests` (limit ending holds the turn).

Native (`apps/macos/PiAppTests`): `CostPauseFamilyTests` (packaged helper + synthetic
gateway: a side's slow request cut at once when the chat crosses, both cards, quit and
relaunch, cold Resume refused at the limit with nothing sent, raise resumes nothing,
Resume from the chat resumes the named, unloaded side once), `CostPausePresentationTests`,
`CostPauseGalleryTests`; sub-agent and steering gallery cost scenes updated.

Wire: `test-native-host.py` side section now asserts the pause, refusal at the limit,
no auto-resume, `pausedMembers` and the side's continuation.

### Failing-first evidence

The updated tests that compile against the base sources were run on base sources
(`logs/red-base-sources.log`): all 7 failed (dispatched permits not cancelled, side
request finished instead of pausing, v2 drain counts, side accepted delegation).
The new pause tests depend on new API, so mutations demonstrate them:

| Mutation | Detected by | Log |
| --- | --- | --- |
| Restore the drain fence in `stopFamilyAtLimit` | 3 failures | `logs/mutation-drain-fence.log` |
| Never park (seal instead) | 27 failures | `logs/mutation-no-park.log` |
| Do not restore `costPaused` on open | 5 failures | `logs/mutation-no-restore.log` |
| Resume without resuming parked turns | 2 failures | `logs/mutation-no-resume.log` |
| Skip the resume-at-limit check | 2 failures | `logs/mutation-auto-resume-room.log` |
| Recovery seals paused turns | 2 failures | `logs/mutation-recovery-seals.log` |
| Child seals at its final boundary during a pause | 3 failures | `logs/mutation-child-seal-during-pause.log` |
| No side delegation refusal | 33 failures | `logs/mutation-side-delegation.log` |

`FamilyLimitPauseTests` passed 12 consecutive repetitions after the final race fix.

### Full gate (after review round 4)

`PI_BUILD_ROOT=…/build-limit-pause scripts/verify-release.sh` under the shared lane lock
(`verify-5.out`, logs in `verify-logs/`): **all passed in 56 min 53 s** (rounds 2 and 3's
`verify-3.out` and `verify-4.out` also passed).

| Suite | Result |
| --- | --- |
| Native serial lane | 890 tests, 43 skipped, 0 failures |
| Native parallel lane (8 clones) | 2,632 passed, 0 failed, 38 skipped |
| Helper | 989 tests, 7 skipped, 0 failures; streaming cost 5/5 |
| Wire / concurrent / acceptance / Python | 36 / 4 / 3 / 86, all OK |
| Gallery | 3 tests, 0 failures (230 screenshots) |

Earlier gates (`verify-1.out`, `verify-2.out`) are superseded; their failures (the wire
side test, a load race in a native cost test) were fixed as recorded above.
`scripts/test-subagent-cache.py`: no prefix breaks (tools unchanged).

## Review round 1 (Codex, 9 findings) — all fixed

| Finding | Fix | Test (mutation detected) |
| --- | --- | --- |
| P1 coordinator hold never cleared without parked turns | Every Resume releases it (`resumeParked` always; the no-run path too) | `FamilyLimitPauseTests.testResumeWithoutParkedTurnsReleasesTheCoordinatorHold` (`mutation-r1-no-hold-release`) |
| P1 Resume before parking finished | `resumeParked` applies a late pause, then waits for the pause's runners; pause generations ignore a pause older than a Resume | `testResumeWaitsForTurnsStillParking` (`mutation-r1-no-park-wait`) |
| P1 delivery judged from the loaded window | Durable command receipt decides `.delivered` | `testResumedTurnStartUsesDurableEvidence` (`mutation-r1-window-only`) |
| P2 accepted-but-undelivered input lost | The turn's own queued submission is kept and released | same test (`mutation-r1-drop-accepted`) |
| P2 side membership cleared before fan-out | Kept until each side resumes; duplicate replies include it | `testRootKeepsPausedSidesUntilTheyResumeAndRefusalsChangeNothing` (`mutation-r1-forget-members`) |
| P2 cold side skipped its root | The app asks the root's helper (`rootReadsCostPaused`) | native `CostPauseFamilyTests.testAColdSidesResumeResumesItsRootFirst` (`mutation-r1-cold-root`) |
| P2 answered child bypassed its final boundary | It takes `boundary(final:)` before ending | `testAnsweredResumedChildSealsAtItsFinalBoundary` (`mutation-r1-skip-final-boundary`) |
| P2 overrides validated after clearing the pause | Any refusal restores the saved pause state | `testRootKeepsPausedSides…` (`mutation-r1-no-rollback`) |
| P2 cold discovery read paused children as interrupted | Owner/child `costPaused` keeps them queued and paused | native `CostPausePresentationTests.testColdDiscoveryKeepsPausedChildrenQueued` (`mutation-r1-cold-discovery`) |

## Review round 2 (Codex, 3 P1 + 5 P2) and the compaction rule — all fixed

| Finding | Fix | Test (mutation detected) |
| --- | --- | --- |
| Owner: a compaction summary in flight is a model request | Summary requests and their back-off are `abortable`; a cut (or refusal at the limit) is not a failed compaction of the context; a cut manual compaction is redone on Resume (`costPendingCompaction`, durable) | `CostLimitTests.testThePauseCutsACompactionSummaryAndResumeCompactsAgain` (`r2-compaction-not-cut`, `r2-compaction-fingerprint`) |
| P1 held calls consumed only in memory | Their release is persisted before any of them runs: a crash gives unknown outcomes, never a replay | `testResumedHeldCallIsDurablyConsumedBeforeItRuns` (`r2-consume-late`) |
| P1 a child inserted after the pause's snapshot waited unpumped | It parks on insertion (after the command releases the owner's lock); Resume parks any runnerless queued job it finds | `FamilyLimitPauseTests.testAChildOpenedAcrossThePauseParksOnInsertion` (`r2-late-job`) |
| P1 the parking wait ignored Stop | The wait checks cancellation; a Stop during it re-pauses the family and halts the held children (an explicit halt is never fenced off) | `testStopWhileResumeWaitsHaltsHeldChildrenAndKeepsThePause` (`r2-uncancellable-wait`); `testResumeWaitsForTurnsStillParking` now waits on a real running child tool |
| P2 pause fence keyed by chat id | Keyed by the owner runtime | `testAReopenedOwnersFirstPauseIsNotMistakenForAnOldOne` (`r2-id-fence`) |
| P2 calls gated after the batch gate got failed results | A call stopped at its own gate (or agent-control preparation) is held; the rest keep their results | `CostLimitTests.testACallHeldAtItsOwnGateRunsOnResume` (`r2-per-call-fail`) |
| P2 cold discovery never read run-state rows | `pi-app.native.state.v1` is scanned; the fixture's pause now sits past line 3 | native `testColdDiscoveryKeepsPausedChildrenQueued` (`r2-discovery-needle`) |
| P2 sides still paused after a lost root reply | The root's snapshot names its still-paused sides; every family Resume reads them | native `CostPauseFamilyTests.testSidesStillPausedAfterALostRootResumeAreRecovered` (`r2-members-lost`) |
| P2 a parked child with held input could not unload | Durable held input of a paused child does not pin it | `testAParkedChildWithHeldInputUnloads` (`r2-pinned-input`) |

## Review round 3 (Codex, 2 P1 + 4 P2) and the same kinds of case

| Finding | Fix | Test (mutation detected) |
| --- | --- | --- |
| P1 an automatically cleared pause left the coordinator holding | Every automatic clear (run end, last side resumed) goes through `clearCostPauseWithoutWork`, which releases and fences the hold | `FamilyLimitPauseTests.testAnAutomaticallyClearedPauseReleasesTheCoordinator` (`r3-auto-clear-hold`) |
| P1 a turn sealed before its child ran broke reopening (mirror missed a continuation) | Recovery catches the mirror up, one continuation at a time, before any terminal record, paused or not | `testReopenRepairsAMirrorThatMissedAContinuationBeforeSealing` (`r3-mirror-before-terminal`) |
| P2 a call held at its own gate was only in memory | Saved the moment its gate closes; a quit then interrupts only the call that ran | `CostLimitTests.testACallHeldWhileAnotherRunsSurvivesAQuit` (`r3-held-in-memory`) |
| P2 a redone compaction bypassed parked children | The redo runs inside the Resume's ordinary run, after parked work is released and held calls ran; "nothing to compact" cannot strand the family | `testCompactionRedoneOnResumeStillResumesParkedChildren` (`r3-compact-skips-family`) |
| P2 the redo ignored Resume overrides | It uses the continuation's validated submission | `CostLimitTests.testThePauseCutsACompactionSummaryAndResumeCompactsAgain` (`r3-overrides`) |
| P2 side membership lost in a crash between two saves | A side binding again sets or removes its root membership from its own durable pause | `testSideBindingRepairsTheRootsPausedMembers` (`r3-membership`) |

Same-kind audit: automatic clears are only `clearCostPauseWithoutWork` (run end, last member
forgotten) and Resume's no-run path, all releasing the hold; every Resume branch
(continuation, family wait, queued follow-ups, compaction redo, no run) now reaches
`resumeParked`; the two-save windows (side pause/root membership, side resume/root forget,
owner continuation/child mirror, owner park/child park, held-call gate/batch end,
held-call release/tool start) each have a durable repair or are ordered save-first.
Remaining tolerated window: a live Stop seals a never-started resumed turn without its
child runtime; the stale child mirror is repaired by the next cold reopen (above).

## Review round 4 (Codex, 1 P1 + 5 P2) and the same kinds of case

| Finding | Fix | Test (mutation detected) |
| --- | --- | --- |
| P1 the held-call release was written but not forced to disk before the tools ran | Saved with `durable: true` (journal fsync) before `runToolBatch` | `CostLimitTests.testHeldCallReleaseIsSyncedBeforeTheToolBegins` (`r4-release-durable`) |
| P2 held calls left by a helper that ended after Resume was accepted lost Resume, and a Send bypassed them | Held calls are continuation work with or without the pause: `canContinue`, `run.continue`'s tail, and a Send waits behind them (`pausedWithPending`, `resumeQueue` refuses); also an accepted Resume keeps the pause on disk (`costResumePending`) until its run has taken the parked work, and a run that ends before that stays paused | `testHeldCallsLeftByAnAcceptedResumeKeepResumeAndGoBeforeASend` (`r4-continuable`, `r4-send-waits`, `r4-resume-pending`) |
| P2 a pause during agent-control admission gave permanent failures (`tool_unavailable`, `subagent_closed`) | `failedByCostPause`: an admission the pause closed is a hold — the v3 preparation, the v2 delegation environment and a call's own catch before entry | `FamilyLimitPauseTests.testAPauseDuringAgentControlAdmissionHoldsTheCall` (`r4-admission`) |
| P2 a cut compaction was recorded pending only after the pause's record | `markCutCompaction` sets it (with its focus) in the pause's own record, for the chat's own pause and a root paused by a side | `CostLimitTests.testACutCompactionIsSavedWithThePauseAndKeepsItsFocusAcrossAReopen` (`r4-compaction-with-pause`) |
| P2 the `/compact <instructions>` focus was lost | `costPendingCompactionFocus` is saved with the pending compaction and restored for the redo, also after reopening | same test (`r4-focus`) |
| P2 `subagent.list` between park and settle showed queued without the pause; the job's end bumped no revision | The flag is derived from the saved queued state (`listsPaused`); `publishParked` sends the parked summary when the job goes, and the snapshot's `subagentsRevision` includes the change count | `testAParkingTurnListsItsPauseAndItsJobsEndIsPublished` (`r4-list-derive`, `r4-publish-parked`) |
| Same kind: a cut compaction left once the pause ended on disk | Pending compaction is continuation work too: Resume offered, Send waits, Resume compacts without a pause | `testACutCompactionLeftAfterThePauseEndedKeepsResume` (`r4-compaction-continuable`, `r4-compaction-first`, `r4-compaction-send`) |

Same-kind audit. Durable saves before effects: every pause-related save is now `durable`
— the pause (`pauseAtCostLimit`, `notePausedMember`, `forgetPausedMember`), the batch
hold, a call held at its gate, the batch-end hold union, a child's park
(`parkAgentTurn`) and resume (`resumeAgentTurn`), Resume's commit (run and no-run
paths), a stopped Resume's re-pause, the end of `costResumePending` and the held-call
release and compaction-redo clears. A child's release/continue saves run with no run
task, so they flush already. Work restorable only through a flag: held calls and a cut
compaction no longer depend on `costPaused`; parked turns are covered by
`costResumePending`. Admission errors: the three sites above; any other error before a
call enters still fails it (a held call that is really unavailable fails on Resume).
Stale summaries: a job goes in two places — `finishJob`, after the terminal seal record
(a terminal row does not read the job), and `park`, now published.

## Review round 5 (Codex, 1 P1 + 1 P2) and the same kinds of case

| Finding | Fix | Test (mutation detected) |
| --- | --- | --- |
| P1 a pause's parking loop (a snapshot across awaits) could park a job a concurrent Resume had just reinstalled, leaving an unsealed turn with no runner | Each job has an identity (`instance`) and a `parking` mark: `park` acts only on the job still installed, once, and removes only that job; the pause loop re-reads each job, and stops once a Resume covers its generation; Resume's own parking loop re-reads too | `FamilyLimitPauseTests.testAStaleParkNeverRemovesAJobAResumeInstalled` (`r5-park-identity`; `r5-no-identity`, both guards removed: the family never completes) |
| P2 after a relaunch, reopening a side the root's Resume already covered re-paused the root | A side's rebinding is a membership `repair`: it adds a missing membership (and the pause with it) but leaves a side the root still lists alone | `testRebindingASideTheRootsResumeCoversDoesNotPauseTheRootAgain` (`r5-repair-repause`) |

Same-kind audit. Coordinator loops across awaits over a jobs snapshot: the pause loop and
Resume's parking loop (above), and `cancel`, which now re-reads each job and judges it by
its own execution; `finishJob` removes only its own job; `drain` (shutdown) only stops and
waits. Paths that set a pause: a fresh `pauseAtCostLimit`, a child's `parkAgentTurn`
(only through the identity-checked `park`), a side's first pause reaching its root, and a
Resume that ended before taking its work (intended); the only repair path,
`bindSideBudget`, is membership-only for a side already listed.

## Owner rule of 2026-10-17 — evidence

| Requirement | Test | Mutation |
| --- | --- | --- |
| Running tool survives with its real result (main and side) | `CostLimitTests.testARunningToolSurvivesThePauseAndARelaunchKeepsThePause`, `FamilyLimitPauseTests.testSidesPauseImmediately…`, `AgentSteeringBoundaryTests.testChildCostLimitPausesParentInUnrelatedToolUntilResume` | `o-tools-cut` (pause calls Stop): 8 failures |
| Held calls of the crossing reply run first on Resume, no new request before | `CostLimitTests.testRunPausesWhenSpendReachesTheLimitAndHeldToolsRunFirstOnResume`, `testHeldToolCallsSurviveARelaunchAndRunFirstOnResume`; native `CostLimitTests.testThePauseNoticeAppearsAndResumeRunsTheHeldCallAfterARaise`, `CostPauseFamilyTests` | `o-no-hold` 5, `o-no-held-run` 9, `o-fabricate` 3 |
| A plain chat pauses and resumes | the plain-chat tests above, `testLoweringTheLimitMidRequestPausesAndResumeGoesOn` | `o-plain-no-pause` (both plain triggers): 2 |
| Relaunch while a tool is still finishing | `testARunningToolSurvivesThePauseAndARelaunchKeepsThePause` (quit-early case) | — |
| Final family wait ends at the pause | `FamilyLimitPauseTests.testPauseSurvivesReopen…` | `o-boundary-wait`: 2 |

The old app "Stopped at this chat's cost limit → Continue" card is no longer reached by a run (every run pauses); it remains only for journals written by older builds. A message refused at the limit still shows its send notice.

## Needs owner decision

Decided by the owner on 2026-10-17: plain chats pause too; paused sub-agents keep
Resume-then-Stop (no Discard); idle sides stay unmarked. Compaction summaries are
model requests and are cut too (review round 2); no known limitation remains.
