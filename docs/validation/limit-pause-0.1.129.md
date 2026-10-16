# Cost limit pauses the family; sides never delegate — 0.1.129

Branch `dev/a129-limit-pause`, based on `dev/next` 9d4123f6 (released 0.1.128).
Owner decisions, 2026-10-16:

- A. "Pause immediately, and support resume once I increase the limit" — "Wait for Resume click".
- B. "Do not allow side to start their own" sub-agents.

All evidence uses generated fixtures, loopback gateways and the build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-limit-pause` (logs in `logs/`).
No installed app, real preferences, Keychain, real chats or paid provider was used.

## A. The limit-pause state machine

`AgentSession.stopFamilyAtLimit` stays the only budget-induced Stop. It no longer
waits for a drain fence (`inFlightBudgetAttempts.isEmpty && !modelActive`).

| From | Event | To |
| --- | --- | --- |
| Running family (any member has a run, queued input or an unsealed child turn) | Any charge reaches the root's limit: own, side, nested side, sub-agent or side-owned sub-agent settlement; a late correction; adoption; or lowering the limit | **Paused**: `costPaused` is persisted in the run state *before* anything is cancelled. Then Stop's cancellation: every request permit, run task (retry waits, tools, summaries) and, through `AgentSteeringCoordinator.pause`, every child run. Sides are reached through the root's weak side callbacks and pause the same way. |
| Owner with nothing unfinished | Same event | Gates close (one Stop, as before); no durable pause. A side that pauses registers with its root (`costPausedMembers`), and the root then shows the pause too. |
| Paused, a child turn running | Its run ends (cancelled, failed, or the limit refused it) | **Parked**: owner and child journals record the turn as `queued` with no result; its runtime is released. A child that reaches its final boundary during the pause does not seal (it would read as interrupted); its answer stays in place. A turn that had completed seals normally. |
| Paused, a child turn queued | — | Stays `queued` (never `not_executed`), keeps its acceptance order and undelivered parent messages. |
| Paused | Accounting for aborted requests arrives | Accepted; reported cost counts, unreported stays unknown. |
| Paused | Quit, relaunch or helper restart | Still paused: `costPaused` restores; recovery keeps unsealed turns `queued` (a turn still `running` because the helper died mid-pause is requeued, owner and child mirror), pending parent messages stay pending. |
| Paused | Limit raised (or removed) | Still paused. Nothing starts. |
| Paused | New user message | Queued for after Resume (`delivery: after-resume`). |
| Paused | Resume (`run.continue`) at or over the limit | Refused, `cost_limit`: "Still at the cost limit. Raise the limit above the current spend, then choose Resume." (a side checks its root's limit). `queue.resume` and `turn.retry` refuse while paused too. |
| Paused | Resume below the limit | **Running**: the pause ends; the run resumes its own cut-off work if any, else waits at the family boundary for the resumed children; parked turns are re-queued under the run's new execution (`AgentChildTurn.continuations`, +1 per Resume); queued follow-ups go after. The reply names paused sides (`pausedMembers`); the app resumes each. A resumed turn whose task was delivered continues from its own context (task not resent); one that had answered seals with that answer. |

Legacy v2 delegation (steering disabled; not shipped) has no resumable turn; its
children are cancelled at the pause. Chats that never shared a budget keep their
0.1.128 between-request stop (see *Needs owner decision*).

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

## Needs owner decision

1. **Ordinary chats** (never shared a budget: no side or sub-agent ever) keep the
   0.1.128 between-request stop ("Stopped at this chat's cost limit" → Continue). Should
   they pause the same way?
2. **Paused sub-agents have no Stop.** To drop paused work: Resume, then Stop. A
   per-child "discard" could be added.
3. Sides that were idle at the limit are not marked paused; the root's card covers them,
   and their next send is refused at the limit as before.
