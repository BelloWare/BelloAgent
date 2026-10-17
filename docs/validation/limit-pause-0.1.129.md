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

### Full gate

`PI_BUILD_ROOT=…/build-limit-pause scripts/verify-release.sh` (under the shared lane
lock; `verify-1.out`, logs in `verify-logs/`):

| Suite | Result |
| --- | --- |
| Native serial lane | 882 tests, 43 skipped, 0 failures |
| Native parallel lane (8 clones) | 2,633 passed, 0 failed, 38 skipped |
| Helper | 964 tests, 7 skipped, 0 failures; streaming cost 5/5 |
| Wire | 36 tests: 1 failure in the rewritten side cost test (its assertions read the side's inherited history and assumed a tool round). Corrected; the test and then the whole wire suite passed, 36/36 (`logs/wire-rerun.log`) |
| Concurrent / acceptance / Python | 4 / 3 / 86, all OK |
| Gallery | 3 tests, 1 failure: `testRenderRedesignGallery` "session did not settle" under the loaded gate. Unchanged code path; it passed alone (`logs/redesign-gallery-1.log`, 495 s). The sub-agent and steering galleries (with the updated cost scenes) passed. |

`scripts/test-subagent-cache.py` on the release helper: 26 requests, 22 comparisons,
no prefix breaks, 100% previous-prefix retention (`logs/subagent-cache.log`).

Earlier focused gallery runs on this shared Mac twice failed the sub-agent/steering
galleries' `canBackToSubagentParent` key-window check (another workstream's windows);
both passed in the full gate.

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
Resume-then-Stop (no Discard); idle sides stay unmarked. Remaining limitation: a
plain chat's compaction summary request in flight is not cut by the pause (its
gate refuses the next one).
