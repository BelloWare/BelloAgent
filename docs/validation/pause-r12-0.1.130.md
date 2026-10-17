# Cost-limit pause review round 12 — 0.1.130

Branch `dev/a130-pause-r12`, based on `dev/next` at `141666ca`.
This implements the three findings deferred from 0.1.129 in
[limit-pause-0.1.129.md](limit-pause-0.1.129.md#known-for-01130).
The initial implementation and evidence below were committed as `68491378`.
The subsequent review fixes are recorded in the [first follow-up](#follow-up-review-of-68491378)
and [round 2](#round-2-review-of-3a1dfbda).

## Changes and decisions

- Recovery checks the durable reader Stop (`family.run.heldChildren`) before
  parking an unsealed child. It uses the existing terminal recovery rules:
  never-started work is `not_executed`; possible execution is `interrupted`;
  sealed child evidence remains authoritative. Owner and child mirrors agree,
  and repeated recovery emits one result event.
- Stop during an accepted, not-yet-entered cost Resume takes the coordinator's
  halt path. Running child tools stop even if the new run is cancelled at its
  first cancellation check. Close uses that same path.
- Each issuing ancestor saves `costPendingSidePauses` with its pause before
  scheduling callbacks, including an idle root with active sides. A callback
  acknowledges only after the side's pause and root membership are saved.
  Cold recovery validates the saved targets against side ancestry and keeps
  only sides with unfinished work. A side inherits its pending pause before
  child recovery, and saves it before binding acknowledges the intent. Root
  Resume can precede opening the sides: its durable member list still holds
  them until their own Resume takes the work. Idle/deleted/unkept sides are
  excluded. No conversation content is copied into the root.

The owner rule is unchanged: pause cuts model requests, lets running tools
finish, and runs held calls first on Resume. A human Stop is distinct from a
budget pause. There are no UI/control changes or new execution permissions.
No owner decision is required.

## Same-pattern sweep

Additional fixes, separately from the three original findings:

- **Live accepted child Stop versus parking:** the same coordinator guard
  ignored an explicit reader Stop if the hold arrived first; an already parked
  turn had no job to stop. Stop now shares the parking/sealing gate, honors
  human cancellation through a pause, and seals parked turns through the
  ordinary result/message path. A closed child's mirror catches up on recovery,
  as with the existing Stop-before-child-open window. The app still offers
  Resume-then-Stop for paused child readers; this covers commands already in
  flight, not a new control.
- **Other fan-out entry:** the first side membership can pause a root, so
  `notePausedMember` saves the callback intent too.
- **Binding and callback races:** binding takes an outstanding pause before
  acknowledging it; an old callback acknowledgement cannot erase a later
  pause's intent. An accepted Resume retires pending callbacks, while a
  refused Resume restores their intent.
- **Other cancellation paths:** close reaches `stop()` and its explicit halt;
  Stop during `resumeParked` already re-pauses and halts on cancellation.
  Automatic family cancellation continues to preserve budget-held turns;
  explicit child Stop is the exception above.

## Failing-first and mutation evidence

Text logs and the mutation runner are under
`/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12/`.
Every fixture uses generated journals, synthetic credentials and local tools
or loopback services. No installed app, real chats/preferences, Keychain,
live capture, or paid provider was used.

| Regression | Before fix | Coverage |
| --- | --- | --- |
| `AgentFamilyRecoveryTests.testRecoveryKeepsExplicitlyStoppedChildrenOutOfThePausedQueue` | 9 assertion failures (`logs/red-stops.log`) | Queued/running/stopping durable Stops, child mirror, repeated recovery |
| `FamilyLimitPauseTests.testStopBeforeAnAcceptedResumeRunsHaltsChildTools` | 2 assertion failures (`logs/red-stops.log`) | Resume and Stop in one actor turn; also close before Resume runs |
| `FamilyLimitPauseTests.testSidePauseFanoutSurvivesACrashBeforeItsCallbacks` | 2 assertions and `nothing_to_continue` (`logs/red-fanout.log`) | Callbacks held behind a gate, saved direct/nested/idle sides, idle/busy root, root Resume before side opening; limit/member/binding/renewed-pause cases |
| `FamilyLimitPauseTests.testAnExplicitChildStopAcceptedDuringThePauseNeverResumes` | 2 assertions (`logs/red-live-stop.log`) | Running, parking and parked children; no request on subsequent Resume |
| `FamilyLimitPauseTests.testAcceptedResumeRetiresPendingSidePausesButRefusalKeepsThem` | 2 assertions (`logs/red-pending-retirement.log`) | Pending intent survives refusal but is retired durably by accepted Resume |

All **11 mutations were detected by test failures**, with successful builds.
The runner restores each source in `finally` before the next mutation.
Each log is `logs/mutation-<name>.log`; `logs/mutations.log` records the summary.

| Mutation | Test failures |
| --- | ---: |
| `recovery-stop`: ignore the durable child Stop | 9 |
| `pending-resume-stop`: halt only when `costPaused` | 2 |
| `fanout-save`: omit pending callback targets from the saved state | 5 |
| `member-fanout`: omit targets when a side first pauses its root | 7 |
| `side-inherits`: do not restore the side's inherited pause | 10 |
| `binding-intent`: binding acknowledges without taking the pending pause | 7 |
| `stale-ack`: an old callback can acknowledge the current intent | 2 |
| `live-stop`: the pause ignores an explicit human Stop | 1 |
| `parked-stop`: do not seal a stopped parked turn | 1 |
| `pending-retire`: Resume retains obsolete callback intent | 2 |
| `pending-restore`: a refused Resume loses callback intent | 1 |

The fan-out mutation failures include the expected inability to Resume a
family whose membership was lost (one thrown error in each of `fanout-save`
and `member-fanout`), in addition to assertions. None is a compilation failure.

## Validation commands and results

Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12`.
All native runs hold `/Users/admin/Library/Caches/BelloSwiftWork/full-lane.lock`;
serial classes run alone. Only text logs are retained as evidence.

With `B=/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12`, from the
worktree root:

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" \
  --filter 'FamilyLimitPauseTests|AgentFamilyRecoveryTests|CostLimitTests|SideBudgetTests|AgentSteering|PausedFamilyCompactionTests'
python3 "$B/check-mutations.py"
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests"
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/RunHoldTests \
  -only-testing:PiAppTests/CostPausePresentationTests \
  -only-testing:PiAppTests/CostLimitTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/CostPauseFamilyTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/LifecycleHelperTests
python3 scripts/test-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
```

`scripts/test-macos.sh` stages the Release helper with
`PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py` and regenerates the project.
The exact lock-owning native runner is `$B/check-native-only.sh`. While waiting
for the shared lane, the Release helper was compiled separately, with the same
configuration and two compiler jobs, before the independent wire suites:

```sh
swift build --package-path packages/swift-host --scratch-path "$B/swift-host" \
  --configuration release --arch arm64 --product pi-native-host -Xswiftc -Osize --jobs 2
```

| Suite | Result | Log |
| --- | --- | --- |
| Focused helper classes | 127 passed, 0 failed | `logs/focused-final.log` |
| Final FamilyLimitPause fixture/assertion strengthening | 43 passed, 0 failed | `logs/focused-pause-completion.log` |
| Full helper suite | 1,017 passed, 7 skipped, 0 failed (1,024 total; 428.9 s) | `logs/helper-full.log` |
| Native RunHold/CostPausePresentation/CostLimit | 37 passed (18 / 6 / 13), 0 failed | `logs/native-pause.log` |
| Native CostPauseFamily, alone | 3 passed, 0 failed | `logs/native-family.log` |
| Native LifecycleHelper, alone | 11 passed, 0 failed | `logs/native-lifecycle.log` |
| Wire | 36 passed, 0 failed | `logs/wire.log` |
| Concurrent | 4 passed, 0 failed | `logs/concurrent.log` |
| Acceptance | 3 passed, 0 failed | `logs/acceptance.log` |

There are no UI changes, so no gallery was regenerated. The lead runs the full
native/release gate after review and merge; this branch is not a release.
The helper's seven skips are the existing opt-in large-journal, fork-fixture
and history-supersession measurements.
After the full helper run, the fan-out test's client was strengthened to make
accounted continuations and assert successful idle completion and exact request
counts. Its whole 43-test class passed again with `--filter FamilyLimitPauseTests`;
production sources were unchanged after the full suite and mutation checks.
All 51 focused native tests passed without skips. No unrelated test failed and
no unresolved finding or owner decision remains in this workstream. Native
result bundles were removed; the runs used one DerivedData root with parallel
testing disabled, and left no clone folders.

## Follow-up review of 68491378

Both reported findings were confirmed against the pushed code:

- `Sessions.init` promoted pending fan-out targets to the recovering session's
  own `costPausedMembers`, including intermediate sides. Their descendants
  retire membership only at the bound root. Thus an intermediate could be
  internally idle while its app snapshot still said `state: paused`,
  `costPaused: true` and `cost.paused: true` through `membersPendingResume`.
  `bindSideBudget` now transfers recovered descendant membership to the root
  before durably removing it locally. Cold recovery retains membership until
  binding establishes the actual root, preserving orphan-side behavior.
- `resumeParked` read unsealed turns outside the gate used by reader Stop.
  A Stop while Resume awaited its delegation environment could seal one of
  those turns; installing the stale queued continuation then failed and put
  the accepted family Resume back into pause. Snapshot, environment preparation
  and installation now share the owner gate. Acquisition follows the parking
  drain, so parking/sealing can finish; empty, successful and throwing exits
  release the gate. Stop either seals before the snapshot or cancels the newly
  installed job, leaving siblings free to finish.

### Additional same-pattern sweep

- **Saved membership at any intermediate depth:** the binding repair also
  transfers already-saved `costPausedMembers`, not just newly recovered pending
  fan-out. A four-level fixture puts the same unopened leaf on two intermediate
  ancestors. The root learns that leaf before it opens, both ancestors clear
  their persisted lists, and all app snapshots finish idle with no pending
  family Resume. This is covered separately from the original crash fixture.
- All production membership additions were traced: recovery, root notification,
  and synchronous refused-Resume state restoration. Runtime side notifications
  and acknowledgements already use the last bound ancestor; removal/deletion
  paths only prune. Binding is the point where an otherwise independent or
  orphaned session gains a root, so the repair handles all recovered holders.
- Audited family-turn writers and their callers: command preparation and legacy
  adoption, parking, terminal sealing and delivery/final boundaries already use
  the owner gate; recovery and child mirror transitions are synchronous actor
  operations. An allocated runner's running-state write precedes starting its
  child, checks cancellation, and remains owned by that runner until gated
  sealing; reader Stop cancels that job instead of separately sealing it.
  Status/progress snapshots do not rewrite turns. No further unsafe
  snapshot-then-install path was found.

There is no owner-visible behavior change beyond the requested corrections,
no new execution path or permission, and no owner decision needed.

### Failing-first and mutation evidence

All three regressions assert app snapshots or the child list as well as
completion. The fan-out fixture now checks snapshot `state`, `costPaused`,
`cost.paused`, `cost.pausedMembers` and `membersPendingResume`, replacing its
insufficient internal-state-only completion assertion. The race fixture holds
environment preparation, accepts reader Stop concurrently, and checks that
the root finishes normally, the stopped child stays terminal, and its sibling
completes. Its accepted tool receipts are retained so the resumed history is
protocol-valid.

With the final tests and both production files restored to `68491378`, all
three tests failed: **28 assertions, zero unexpected failures** in
`logs/review-red-final.log` (successful build). By regression:

| Regression | Failing assertions |
| --- | ---: |
| `testSidePauseFanoutSurvivesACrashBeforeItsCallbacks` | 10 |
| `testChildStopDuringResumeInstallationDoesNotPauseTheFamilyAgain` | 5 |
| `testBindingTransfersRecoveredMembershipFromEveryAncestorToTheRoot` | 13 |

`python3 "$B/check-review-mutations.py"` restores each file in `finally` and
also repeats the baseline failing-first run. All **four mutations were caught**
after successful compilation; `logs/review-mutations.log` records their exits.

| Mutation | Failing assertions | Log |
| --- | ---: | --- |
| Omit transfer to the root | 1 | `logs/review-mutation-transfer.log` |
| Keep membership on intermediate ancestors | 22 | `logs/review-mutation-retire.log` |
| Do not persist local membership removal | 2 | `logs/review-mutation-durable.log` |
| Give Resume a separate gate from Stop | 5 | `logs/review-mutation-resume-gate.log` |

### Follow-up validation

Uses the same assigned build root, generated journals, fixture credentials and
loopback services. No UI source changed; no gallery regeneration is needed.
After restoring the fixes, from this worktree root:

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" \
  --filter 'FamilyLimitPauseTests|AgentFamilyRecoveryTests|CostLimitTests|SideBudgetTests|AgentSteering|PausedFamilyCompactionTests'
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests"
swift build --package-path packages/swift-host --scratch-path "$B/swift-host" \
  --configuration release --arch arm64 --product pi-native-host -Xswiftc -Osize --jobs 2
python3 scripts/test-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
bash "$B/check-review-native.sh"
```

The native runner acquires/releases the shared full-lane lock for each of the
same three focused `PI_BUILD_ROOT="$B" scripts/test-macos.sh` invocations listed
above, with parallel testing disabled and the family/lifecycle classes each
alone. It stages the Release bundle helper and retains only text evidence.

| Suite | Result | Log |
| --- | --- | --- |
| Focused helper classes | 129 passed, 0 failed (including all 45 FamilyLimitPause tests) | `logs/review-focused-final.log` |
| Full helper suite | 1,019 passed, 7 skipped, 0 failed (1,026 total; 388.6 s) | `logs/review-helper-full.log` |
| Native RunHold/CostPausePresentation/CostLimit | 37 passed (18 / 6 / 13), 0 failed | `logs/review-native-pause.log` |
| Native CostPauseFamily, alone | 3 passed, 0 failed | `logs/review-native-family.log` |
| Native LifecycleHelper, alone | 11 passed, 0 failed | `logs/review-native-lifecycle.log` |
| Wire | 36 passed, 0 failed | `logs/review-wire.log` |
| Concurrent | 4 passed, 0 failed | `logs/review-concurrent.log` |
| Acceptance | 3 passed, 0 failed | `logs/review-acceptance.log` |

All final restored-source runs passed; the seven helper skips are the existing
opt-in measurements listed above. No unrelated test failed. Production and test
sources were unchanged throughout these final runs. The native runner released
its shared lock and removed automatic result bundles; no clone folders remain
under this workstream's build root. No unresolved finding or owner decision
remains from this review.

## Round-2 review of 3a1dfbda

Both findings were confirmed against the pushed branch:

- Reader Stop acquired the family gate before cancelling an allocated child.
  The delivery boundary can hold that gate throughout `agent-delivery`
  compaction, delaying cancellation of that request or a sibling's live tool.
  Reader Stop now signals cancellation of an allocated, non-parking job first.
  It still acquires the shared gate for durable Stop, terminal writes and the
  fresh state read; queued/parked turns retain the previous serialization with
  Resume installation. The normal gated cancellation remains necessary when
  Resume installs a job while Stop waits.
- Cold recovery promoted descendant-only pending fan-out to an intermediate
  side's own pause. Binding that idle side after an accepted root Resume added
  an unexpected member and paused the root again. Recovery now distinguishes
  sides with a saved parent and no work of their own from roots, orphaned sides
  and sides with their own unfinished work. An idle intermediate retains the
  descendant membership for transfer to the root, without an ancestor hold.
  Roots and orphan families still recover their aggregate pause.

### Round-2 same-pattern sweep

- **Sibling cancellation:** the new held-compaction fixture also stops a
  sibling's running tool while leaving the compaction request untouched. Both
  reader wire routes, `subagent.stop` and managed-child `turn.stop`, call this
  same coordinator method. Parent Stop/close, family halt, runtime cancellation
  and draining already signal live cancellation before terminal serialization.
  Model-issued `subagent_stop` retains its existing gated command admission.
- **Idle ancestors at every depth:** the crash fixture covers one and two idle
  intermediate sides, opening them before or after the root's Resume, and the
  same nested family after its original parent journal is missing. Only the
  active leaf is returned in the Resume reply; one leaf Resume completes it and
  all app snapshots become idle with empty paused-member lists.
- Rechecked membership writers, pause fan-outs and turn snapshot/write paths.
  Runtime fan-out already distinguishes own work through `hasCostPausableWork`;
  binding moves recovered membership off every intermediate to the root.
  Resume's snapshot/install, parking and sealing still share the family gate.
  Pre-gate cancellation marks only the current live job; the later state writes
  use a fresh gated read. No additional unsafe path was found.

No owner decision or new production path is needed. Permission, tool, capture,
vault and data boundaries and the owner's cost-pause behavior are unchanged.

### Round-2 failing-first and mutation evidence

The two new tests exercise real session/coordinator paths with generated
journals, scripted accounted requests and a cancellable held tool:

- `testReaderStopCancelsLiveWorkWhileDeliveryCompactionHoldsTheGate` checks the
  app's compaction snapshot is actively summarizing for `agent-delivery`, then
  requires the held request or sibling tool to observe cancellation within one
  second, before the fixture releases it. It also checks the stopped child list
  result and the cancelled compaction snapshot.
- `testRecoveryDoesNotPauseIdleAncestorsOfTheResumedLeaf` checks app snapshot
  state, pause flags, paused-member lists, the root's Resume reply and successful
  leaf completion across all six ancestry/open-order cases.

With the final tests and both production files restored to `3a1dfbda`, both
tests failed after a successful build: **91 assertions, zero unexpected
failures**, including both Stop-cancellation cases (`logs/round2-red-final.log`).
The Stop test produced 2 failures and the recovery test 89.
The production fixes were restored after every run by the mutation script's
`finally` block.

`python3 "$B/check-round2-mutations.py"` also caught both mutations after
successful builds (`logs/round2-mutations.log`):

| Mutation | Failing assertions | Log |
| --- | ---: | --- |
| Defer live cancellation until after acquiring the gate | 1 | `logs/round2-mutation-cancel-after-gate.log` |
| Promote every pending descendant fan-out to the intermediate's own pause | 91 | `logs/round2-mutation-pause-idle-ancestors.log` |

### Round-2 validation

All runs use this workstream's build root and generated fixture data. There are
no UI source changes and no gallery regeneration. From the worktree root:

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" \
  --filter 'FamilyLimitPauseTests|AgentFamilyRecoveryTests|CostLimitTests|SideBudgetTests|SideBudgetCrashMatrixTests|SideBudgetCorrectionTests|SideBudgetReplayTests|AgentSteering|PausedFamilyCompactionTests|CompactionSafetyTests|CompactionQueueTests'
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests"
PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$B/bundle/Helpers/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/bundle/Helpers/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/bundle/Helpers/pi-native-host"
bash "$B/check-round2-native.sh"
```

The native runner acquires/releases the shared full-lane lock for each command
below, keeping the family and lifecycle classes alone. It reuses the assigned
DerivedData and removes the automatic result bundles after each run.

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/RunHoldTests \
  -only-testing:PiAppTests/CostPausePresentationTests \
  -only-testing:PiAppTests/CostLimitTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/CostPauseFamilyTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/LifecycleHelperTests
```

| Suite | Result | Log |
| --- | --- | --- |
| Focused helper classes | 179 passed, 0 failed (including all 47 FamilyLimitPause tests) | `logs/round2-focused.log` |
| Full helper suite | 1,021 passed, 7 skipped, 0 failed (1,028 total; 388.9 s) | `logs/round2-helper-full.log` |
| Release bundle helper build | Passed | `logs/round2-bundle.log` |
| Native RunHold/CostPausePresentation/CostLimit | 37 passed (18 / 6 / 13), 0 failed | `logs/round2-native-pause.log` |
| Native CostPauseFamily, alone | 3 passed, 0 failed | `logs/round2-native-family.log` |
| Native LifecycleHelper, alone | 11 passed, 0 failed | `logs/round2-native-lifecycle.log` |
| Wire | 36 passed, 0 failed | `logs/round2-wire.log` |
| Concurrent | 4 passed, 0 failed | `logs/round2-concurrent.log` |
| Acceptance | 3 passed, 0 failed | `logs/round2-acceptance.log` |

The seven helper skips are unchanged opt-in fixture/performance tests. No
unrelated test failed. Production and test sources stayed unchanged throughout
the final restored-source runs. The native runner released the shared lock;
no result bundles or clone directories remain under this build root. Both
review findings are resolved; no additional unresolved finding or owner
decision remains.

## Round-3 review of 5fb1b5dc

Both findings were confirmed and reproduced through observable behavior:

- A reader Stop sealed the parked parent turn while the unloaded child's state
  still said `costPaused`. The next accepted `subagent_send` follow-up inherited
  that hold and parked without a request. `prepareAgentTurn` now retires the
  previous turn's pause before starting a newly accepted turn. Admission of the
  follow-up already requires the previous parent turn to be terminal; same-turn
  `resumeAgentTurn` retains its separate continuation behavior. A closed parked
  child's state is reconciled when the new turn opens it, without opening a
  second writer merely to acknowledge Stop.
- Both host Stop routes cancelled their target first but waited to persist the
  Stop behind another child's `agent-delivery` compaction. Delivery now releases
  the family gate before calling the provider. After compaction it reacquires
  the gate and selects pending messages again. Stop admission and terminal writes
  remain serialized with Resume installation, with no stale delivery snapshot
  carried across the provider request.

### Round-3 adversarial self-review and sweep

Reviewed the **entire branch contribution**, including the preceding three
commits, against fetched `origin/dev/next` (`5c52621c5db150bf6b1372eb47015c028301983c`).
The branch-only diff uses merge base `141666ca479184d10a9791754d4c91df456599d8`;
unrelated changes subsequently merged into `dev/next` were not reverted or
copied into this workstream. The pre-round production diff is retained in
`logs/round3-branch-before.diff` under this build root.

The review found two additional cases of the reported patterns, both covered
by the fixes and mutation checks:

1. Clearing only the child pause would leave its held tool calls unpaired in
   the next provider request. A fresh child turn now records `not_executed`
   results for those calls before retiring the saved held-call list. It never
   invokes them. The expanded follow-up fixture covers this case as well as a
   child parked before any request, with/without restart and in Off, memory and
   persist capture modes (12 combinations).
2. Parent delivery held the same family gate during compaction. Both delivery
   directions now release it. The added parent fixture stops a child while the
   summary is held and verifies that the subsequently delivered batch includes
   the newly sealed child result exactly once. This also checks that moving the
   provider await out of the gate does not introduce a stale selection/write.

Condition-by-condition audit below includes changed predicates and predicates
moved into the newly gated/looped phases. All rows were checked for streaming,
idle, paused, restart, cancellation and concurrent sibling work. Capture mode
is not a routing predicate in any of these production paths; journal durability
and capture policy remain separate. The new follow-up fixture exercises all
three capture modes; the full helper/wire suites cover their capture boundaries.

| Changed predicate or gated decision | States taking the changed path; intended behavior |
| --- | --- |
| `AgentFamilyRecovery.recover`: exclude `run.heldChildren` from the paused-unsealed branch | A durably reader-stopped child after a crash takes terminal recovery even if the owner is paused. Other unsealed children park; existing terminals stay terminal. A new epoch cannot admit a follow-up under the old epoch's Stop hold. |
| `Coordinator.park`: `current.cancelled` / `current.allocated` | A cancelled running job finishes its terminal result; a cancelled queued job retains its already scheduled finisher. Neither parks. Existing instance/parking checks still reject stale runners and duplicate parkers. |
| `park`: saved parent turn is terminal / child exists | A Stop that won the gate is mirrored into the live child. It is not rewritten queued or paused. Without a live child, later recovery catches up the mirror. |
| `park`: saved status differs from queued | Only an unsealed nonqueued turn gets a queued record; already queued work is parked without a duplicate state transition. |
| `resumeParked`: unsealed, no job / empty parked set | The same eligible turns are installed, but their snapshot and installation now share Stop's gate. Empty families release the gate and pump normally. Draining remains outside the gate so parkers/finishers can complete. |
| `resumeParked`: plan exists / legacy resource fallback | These unchanged decisions now execute under that same gate. Missing plans fail closed; old children retain their frozen fallback resources. No credential, resource or tool grant expands. |
| Coordinator cancellation: `human || !paused` | An explicit child Stop cancels during a family pause; automatic cancellation still leaves parked work resumable. Unknown, foreign and already cancelled jobs remain no-ops. |
| Reader Stop: allocated, same owner, not parking | Live models/tools are signalled before gate admission. Queued, parked or foreign jobs skip this early cancellation and use the gated lookup. |
| Reader Stop: known turn / human / latest turn / run exists / absent held child | Unknown turns are rejected; a reader Stop of the latest turn durably retains the epoch hold once. Stopping an older terminal turn cannot hold a newer turn. |
| Reader Stop: human, unsealed, absent or parking job | A parked turn can now seal without a runner. Running/queued installed jobs use cancellation and their finisher. Terminal turns never get a second terminal transition. |
| Reader Stop: dispatched evidence or running/stopping status | Work that may have begun reports interrupted; never-started work reports not executed. Both remain terminal after Resume/restart. |
| Shared seal: optional child / missing result event / matching pending parent messages | Live mirrors are updated; closed children wait for recovery. Each result event is emitted once and only messages to that stopped turn become undelivered. These predicates are unchanged by extracting the shared seal path. |
| `prepareAgentTurn`: paused or held calls / nonempty held calls | Only a fresh, owner-authorized, inactive managed-child turn retires old pause state. Held calls get cancelled-before-execution results and a durable cleared list. Ordinary first/follow-up turns have no held calls; same-turn Resume does not enter this path. |
| `endCostPause`: existing pause | Retires pending side callbacks when Resume is accepted, leaving actual paused-member membership for the app. A refused Resume restores the pending list and generation along with the old pause. The child fresh-turn use cannot release its owner's hold. |
| `boundary`: child lease / current job identity / cancellation | Children still use their owner's gate; roots use their own. Each pass checks cancellation and child identity. Cancellation before/after summary cannot deliver a stale message or seal a new execution. |
| `boundary`: delivered / none / needs compaction | Normal deliveries and final seals retain the gate. Only the provider-compaction await leaves it; both parent and child loops reacquire and reselect. No final parent fence is closed merely because compaction is pending. |
| `boundary`: final and no delivery / owner paused | A final child seals only when it has no input and is not held by the family pause; otherwise it parks. Root waiting/held-input/busy/final-fence decisions retain their prior behavior under the gate. |
| `deliver`: input held / no pending messages / selected message count | Held/empty inboxes return no delivery. Multi-message batches still shrink in order to fit; empty selections still fail rather than skip a child's FIFO head. |
| `deliver`: may compact and recipient can compact | A too-large single head requests one compaction outside the gate. The next pass either fits or reports the existing coordination-limit error; no unbounded compaction retry or partial delivery. Existing delivery reuse, continuation cap and cursor conditions are unchanged. |
| `pauseAtCostLimit`: own work pauses or pending fan-out exists | Saves side fan-out even for an idle root/intermediate. It does not invent an idle session's own paused work. Every save precedes the scheduled callbacks. |
| `rememberSidePauses`: side not already pending | Each registered descendant is retained once, including nested descendants registered with the root. No body/title/prompt is imported into the parent. |
| `acknowledgeSidePause`: resume generation matches / side pending | Old-generation acknowledgments cannot erase a newer intent. Current acknowledgments remove only that side after its pause/root membership is durable; missing entries are harmless. |
| `notePausedMember`: first pause | A newly paused family records pending fan-out before callbacks. Existing-member repair after an accepted Resume returns without re-pausing the root. |
| `forgetPausedMember`: member or pending intent exists | Resume/deletion can retire either representation of that side. The old no-work check clears an aggregate pause only when no resumable own work or member remains. A pending sibling callback still retains its durable intent until acknowledged. |
| `forgetDeletedMembers`: union of members and pending intents | Deleting an affected side also removes its not-yet-applied fan-out intent; unrelated descendants remain. |
| Persistence: nonempty pending list | Saves only nonempty metadata, in the existing bounded state record. Off/memory/persist capture all use the same journal authority. |
| `bindSideBudget`: an ancestor has pending intent | Binding takes the pause before acknowledging it; idle runtimes stay idle through the existing own-work check. Bound roots alone own actual Resume membership. |
| Binding: root exists / recovered members nonempty | Recovered descendant membership transfers to the root and is durably removed from the intermediate. Orphans retain their aggregate membership until an actual parent is bound. |
| Binding: own `costPaused` | Only a side with its own pause joins root membership. An idle intermediate transfers descendant membership without joining it or undoing an accepted root Resume. |
| Side callback: paused runtime and bound root | Persists root membership before acknowledging fan-out; idle sides acknowledge without becoming members. Existing weak-runtime and Resume-generation checks still fence obsolete callbacks. |
| Session restore: valid registered descendant journal / saved unfinished work | Pending intents for missing or idle sides are dropped; valid unfinished descendants become Resume members. Identity/path checks remain in `journalURL` and side registration. |
| Session restore: pending list / saved parent exists / own saved work | Roots and orphan families recover aggregate pauses. An idle intermediate with a surviving parent carries descendants without an own hold; active/queued/already paused intermediates retain their own pause. |
| Session restore: unpaused side with work / inherited ancestor intent | A crash before its callback cannot make an active side merely interrupted. The ancestor search also finds membership retained after root Resume, and is bounded/cycle-checked. |
| Restore persistence: paused now but not in the saved state | Saves the inherited pause before binding can acknowledge the ancestor's intent. Already saved pauses and idle intermediates avoid that write. |
| `Sessions.stop`: cost paused or cost Resume pending, independent owner, coordinator present | Stop/close during accepted-but-not-entered Resume halts live child tools. Managed children and ordinary nonpause cancellation keep their existing paths. |
| `SideBudgetRecovery.pauseState`: captured journal prefix / state or branch record / custom family metadata | Reads only the open-time prefix, uses the latest state and family-turn metadata, and copies no conversation to an ancestor. Corruption fails closed. |
| `hasPauseWork`: saved pause, active run, queue, steering, delivering or unsealed child | Each is unfinished own work; descendant-only pending membership is deliberately excluded. Idle completed sides are not promoted to paused work. |
| `inheritsPendingPause`: unseen ancestor within depth bound / journal exists / member or pending intent contains this side | Only existing ancestry metadata can confer a hold. Missing parents become independent orphan roots; cycles/depth overflow terminate without crossing ownership boundaries. |

Also swept every family-turn snapshot/write path and every membership writer.
Acceptance, Stop, Resume installation, parking, sealing and delivery commit use
the family gate. Runner state writes occur before child execution; the new
no-job Stop cannot terminalize a still-installed nonparking runner behind that
write. Status/progress reads do not change turn states. All bound membership
writes target the root; temporary non-root membership exists only during cold
recovery and is transferred on bind. No additional branch-introduced issue was
found beyond the held-call and parent-compaction cases above. No owner decision,
production switch, UI change or gallery regeneration is needed.

### Round-3 failing-first, mutation and final validation

The three new tests use generated journals and accounted scripted requests:

- `testAStoppedParkedChildRunsAFollowUpAfterParentResume`: Stop → parent Resume
  → real parent `subagent_send` → completed child turn 2, idle/unpaused parent
  snapshot, no old tool execution and protocol-paired stopped calls. Twelve
  combinations cover queued/held-tools, restart/no restart and all capture modes.
- `testBothReaderStopRoutesAcknowledgeWhileSiblingCompactionIsHeld`: actual
  `NativeHostService.command` replies for `subagent.stop` and managed `turn.stop`
  must arrive within 2 seconds, before releasing the sibling's summary. The
  sibling snapshot must still be `summarizing`; its request is not cancelled.
- `testReaderStopAcknowledgesWhileParentDeliveryCompactsAndDeliveryIsRefreshed`:
  the parent summary remains held while Stop completes; the refreshed delivery
  includes the newly sealed child result once.

Restoring `SessionAgentCommands.swift` and `AgentSteeringMessaging.swift` to
`5fb1b5dc` with the final tests produced **70 failed assertions, zero unexpected
errors**, across 3 tests after a successful build (`logs/round3-red-final.log`).
The follow-up test accounted for 66, the two host routes for 2, and the parent
compaction test for 2. This is the final failing-first evidence, after correcting
the parent fixture's report schema and compaction request allowance.

The baseline runner initially misread the substring `0 failures` inside
`70 failures`; its result parser was corrected to read the numeric count. This
was a runner assertion, not a missing or unexpected test failure. The mutation
run below then exited successfully and restored both sources in `finally`:

```sh
python3 "$B/check-round3-mutations.py" --mutations-only
```

| Mutation | Expected failed assertions | Log |
| --- | ---: | --- |
| Retain the previous turn's pause in `prepareAgentTurn` | 66 | `logs/round3-mutation-retain-pause.log` |
| Clear the held list without pairing its stopped tool calls | 9 | `logs/round3-mutation-unpaired-held-tools.log` |
| Put provider compaction back inside the family gate, both directions | 4 | `logs/round3-mutation-compaction-under-gate.log` |

Exact test/build commands from the worktree root (all logs under this build root):

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12
# Failing-first against 5fb1b5dc, then the same tests in the final class run:
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" \
  --filter 'FamilyLimitPauseTests.testAStoppedParkedChildRunsAFollowUpAfterParentResume|FamilyLimitPauseTests.testBothReaderStopRoutesAcknowledgeWhileSiblingCompactionIsHeld|FamilyLimitPauseTests.testReaderStopAcknowledgesWhileParentDeliveryCompactsAndDeliveryIsRefreshed'
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" \
  --filter 'FamilyLimitPauseTests|AgentFamilyRecoveryTests|CostLimitTests|SideBudgetTests|SideBudgetCrashMatrixTests|SideBudgetCorrectionTests|SideBudgetReplayTests|AgentSteering|SubagentForkTests|Compaction'
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests"
PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$B/bundle/Helpers/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/bundle/Helpers/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/bundle/Helpers/pi-native-host"
bash "$B/check-round3-native.sh"
```

The native runner holds/releases the shared full-lane lock for each focused
command below and removes only this build root's automatic result bundles:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/RunHoldTests \
  -only-testing:PiAppTests/CostPausePresentationTests \
  -only-testing:PiAppTests/CostLimitTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/CostPauseFamilyTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/LifecycleHelperTests
```

| Suite | Result | Text log |
| --- | --- | --- |
| Affected helper tests | 257 passed, 0 failed; all 50 `FamilyLimitPauseTests` included | `logs/round3-focused.log` |
| Full helper suite | 1,024 passed, 7 skipped, 0 failed (1,031 total; 399.9 s) | `logs/round3-helper-full.log` |
| Release bundle helper build | Passed | `logs/round3-bundle.log` |
| Native RunHold / CostPausePresentation / CostLimit | 37 passed (18 / 6 / 13), 0 failed | `logs/round3-native-pause.log` |
| Native CostPauseFamily, alone | 3 passed, 0 failed | `logs/round3-native-family.log` |
| Native LifecycleHelper, alone | 11 passed, 0 failed | `logs/round3-native-lifecycle.log` |
| Wire | 36 passed, 0 failed | `logs/round3-wire.log` |
| Concurrent | 4 passed, 0 failed | `logs/round3-concurrent.log` |
| Acceptance | 3 passed, 0 failed | `logs/round3-acceptance.log` |

In the full helper run, the host replies took **0.487 ms** (`subagent.stop`) and
**0.414 ms** (`turn.stop`), with sibling compaction still held. The assertion
allows 2 seconds, well below the supervisor's 30-second acknowledgment deadline.
The seven helper skips are unchanged opt-in fixture/performance tests. No
unrelated test failed. Production and test sources were unchanged throughout
the final restored-source runs (diff fingerprint in
`logs/round3-validated-diff.sha256`). The native runner released its shared lock;
no result bundles or clone directories remain under this build root. No
unresolved finding or owner decision remains.
