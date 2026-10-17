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
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" --skip-build \
  --filter 'ContinueRunTests|QueueHandoffTests|QueueEditHoldTests|QueueDeliveryRecoveryTests|QueueEditingTests|SessionSettlementTests|RetryRecoveryTests|ConcurrentSessionsTests'
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
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" --skip-build \
  --filter 'ContinueRunTests|QueueHandoffTests|QueueEditHoldTests|QueueDeliveryRecoveryTests|QueueEditingTests|SessionSettlementTests|RetryRecoveryTests|ConcurrentSessionsTests'
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


## Round 4 — transition audit (before implementation)

Starting revision: `deb20a8d4d61d89ddce7166792d68282238d27f4`.
The two review findings are confirmed. This inventory was written before the
Round-4 production changes. “Terminal” below distinguishes a child turn's
terminal result from an independent chat's Stop: the latter intentionally keeps
its cost pause and pending work until explicit Resume. Deletion removes the
journal; it must also retire surviving ancestors' membership. Capture mode does
not own any of these fields.

| State / owner | Every set, clear or transfer path | Durability and terminal audit at start of Round 4 |
| --- | --- | --- |
| `costPaused` (independent chat) | `pauseAtCostLimit`, `notePausedMember`; restore saved/inherited/pending fan-out; failed/premature Resume restores it. `endCostPause`, `clearCostPauseWithoutWork`, missing-member recovery clear it. | Pause saved before cancellation/fan-out. Resume receipt saves before launch; pending Resume still serializes as paused. **Violation:** automatic no-work cleanup schedules root forget/coordinator release before saving its cleared state. Stop/close intentionally preserve unfinished work. |
| `costPausedMembers` (root, or unbound recovered side) | `notePausedMember` inserts; recovery promotes pending intents; `bindSideBudget` moves descendants to root. `forgetPausedMember`, deletion and missing-journal recovery remove. Resume retains the list until each side takes Resume. | **Violation:** transfer clears source after a swallowed destination save error; repair-known fast path provides no durable acknowledgment. Source removal on failed save also needs rollback. Recovery must keep intermediate descendants root-owned without inventing an intermediate's own pause. |
| `costPendingSidePauses` (issuing ancestor) | `rememberSidePauses` records callbacks alongside pause; recovery validates saved work and promotes membership. Callback/binding acknowledgment, member retirement/deletion and accepted `endCostPause` remove. Refused Resume restores. | **Violation:** both bind and callback acknowledge after unconfirmed side/root saves. Failed acknowledgment removes the in-memory intent anyway. Accepted Resume deliberately retires callbacks that have not applied (existing contract/test); already applied pauses need durable membership. |
| `costPauseCount`, `costResumeCount` | New pause/re-pause increments pause count; accepted end increments resume count; refusal restores resume count; fresh runtime starts at zero. | Runtime fences, not journal identities. Coordinator fence keys include runtime epoch. Callback acknowledgment checks issuer resume generation. No terminal persistence obligation for counters themselves. |
| `costResumePending`, `resumingCostPause`, `familyWaitResume`, `compactOnResume` | Accepted Resume sets; run takes/clears them; failed admission restores all; early cancellation restores cost pause; run consumes compaction/family wait. | `savedState` writes pending Resume as `costPaused=true` until installation is durable. Stop/close routes pending Resume to halt. No model/tool starts solely from a recovered transient flag. |
| `budgetStopIssued`, `familyStopReason`, `errorCode/errorMessage`, `state/runStatus` | Limit/side propagation latches; launch clears non-limit reason when allowed; Resume clears cost-limit reason/errors; failed accounting fails closed; no-work cleanup clears presentation. | Derived gates/presentation, saved with state where applicable. **Violation:** terminal child cleanup never clears the cost-limit presentation. Ordinary failure and independent Stop must retain their own presentation. |
| Child `costPaused`, `queuePaused`, `agentTurnClosed`, `agentLease` | `parkAgentTurn` saves queued mirror then pause; same-turn Resume clears pause but retains held work; `prepareAgentTurn` pairs old held calls and clears old pause on new turn; terminal currently sets only `agentTurnClosed`. | **Violation:** parked Stop with no job skips child entirely; live terminal and terminal recovery leave child pause state. Must cover retained reader, cold viewer, missing mirror/continuation, failure between terminal and cleanup, and later follow-up. |
| `costPendingCalls`, `heldBatchCalls` | Whole-batch gate, per-call gate and control admission hold calls; held IDs saved immediately/at batch end. Resume removes saved IDs before invocation; fresh child turn pairs cancelled calls before clearing. | Durable before-start evidence; clearing before invocation intentionally prevents replay after crash. **Violation:** stopped terminal child keeps pending calls until a follow-up. Terminal cleanup must pair them without invoking. Per-call failed save is conservative (recovery says unknown, never replays); batch/final save retries. |
| `costPendingCompaction`, `costPendingCompactionFocus`, manual-compaction flags | Pause marks cut manual compaction with focus; restore retains; Resume selects then clears durably before invocation; successful manual compaction clears; transient in-flight flags end with run. | Independent Stop preserves it for explicit Resume. A terminal managed child must not retain any resume-only state; child manual compaction is not admitted independently. |
| `queuePaused`, queue/steering/delivering, queue edit hold | Stop, pause, failed run and recovery hold; Resume/retry/release/branch/compaction/queue edit clear only through their admission checks; delivered IDs retire on recovery; pending input stays durable. | Ordinary Stop/quit intentionally holds input. Managed terminal turn must discard its accepted pending input and held pause, not future independent work (managed readers cannot submit independently). Queue edit is separate and barred while cost-paused. |
| Coordinator `paused`, `resumedThrough`, `budgetStopped` | `pause` inserts hold and cuts requests; `resumeParked` removes under gate after draining, records generation; `releaseStaleHold` removes only without jobs; runner budget error marks/removes per-turn set. | In-memory projection of durable owner/turn state. Park/install/terminal writes share gate; live cancellation precedes gate; provider compaction is outside it. Stop holds unfinished family; terminal child alone must not release siblings. |
| Coordinator jobs `cancelled`, `parking`, `sealed`, queues/active; `cancelledThrough` | Install/accept -> queued; pump -> active; pause -> park/remove; human/ordinary Stop -> cancelled, terminal -> sealed/remove; Resume reinstalls unsealed turns; cancellation generation fences old jobs. | Identity is instance-checked across awaits; snapshot/install serialized with Stop. Durable terminal precedes dropping runnable ownership. Parked Stop currently needs a child-writer route after job removal. |
| Family `run.heldChildren`, `run.closed`, child turn status/result/continuations | Human Stop appends hold; accepted new execution creates new run (clears holds); run fence/recovery closes; park queues without result; Resume appends continuation; seal/recovery writes terminal/result. | Durable Stop beats cost parking on recovery. Hold intentionally survives parent's current execution and is cleared only in a new execution. Terminal is authority for child cleanup; never replay stopped work. |
| `sideBudgetParents/IDs`, `sideBudgetMembers`, `sideBudgetStops` | Host binds validated ancestry and overwrites each ancestor callback for that side ID; weak runtime references expire on release; numeric family recovery reconstructs saved ancestry. | These identify authorization/accounting, not resumable work. They must not be removed when a pause clears. Weak callback references prevent lifetime retention. Only pause membership transfers. |
| `familyWaiting`, `agentDeliveryHeld`, `pendingInputHeld` | Coordinator boundary sets waiting while work/input is held; the family fence and run error path clear it through `setFamilyWaiting`. Delivery/edit holds derive from closed/queuePaused/queueEdit. | Waiting is runtime presentation, not a durable Resume obligation; derived holds need no separate transfer. Existing family-boundary and queue-edit tests cover release/cancellation. |
| `queueEdit` and its edit outcome/revision fields | `beginQueueEdit` saves the hold before replying, restores on failed save; resolution clears and saves an outcome, restores on failed save; restore removes a hold only for input already delivered. | Independent editing transaction, not cost membership. Stop preserves it; cost pause prevents new conflicting edits; deletion discards journal. Managed children cannot acquire an independent edit hold. |
| `membersPendingResume`, `hasParkedAgentTurns`, `canContinue`, snapshot pause/hint | Computed from the above; no independent writes. | Regression assertions must use snapshots/Resume reply members and actual follow-up execution, not only internal flags. |

Additional confirmed violations to fix with the two reported ones: live fan-out
acknowledgment without durable side/root confirmation; failure rollback for
membership/intents; automatic no-work retirement before its own durable save;
and held-tool/pending-input retirement on child terminalization. Missing-member
recovery is repeatable from the deleted journal, but its corrected projection
should also be saved. The implementation/tests below will record the final
outcome of each transition, including any further findings.

### Round-4 implementation and terminal-path sweep

`notePausedMember` now returns a durable acknowledgment, including for a member
already known in memory. Failed appends/synchronizes cannot authorize removing
another writer's copy. Binding confirms the side state first, transfers every
member to the root, then saves the source removal. A failed source removal
restores the current list, including members added across the root await.
Live fan-out uses the same side/root confirmation before acknowledging an
ancestor's intent. Failed intent/member removals roll back in memory so a later
unrelated save cannot commit them accidentally. Automatic no-work retirement
saves before releasing the coordinator or notifying its root. Recovery saves
both newly inherited membership and removed/missing membership.

Unkept sides have no journal by design: their live pause is carried by the root;
Keep publishes the whole state. An ephemeral root cannot acknowledge a durable
transfer. Closing/discarding an unkept side or deleting a kept side retires its
membership; a publication crossing that close checks again and cannot resurrect
it. A kept side merely closing retains its durable Resume obligation. An
unreadable journal is not treated as proof of deletion.

A parked Stop writes the authoritative owner terminal under the family gate,
then reconciles the child outside that gate. A still-open parked writer is
checked and updated in one actor turn. If it has closed, the host resolves the
retained reader under its runtime gate or mirrors the terminal into the closed
journal. This avoids a second writer and a family/runtime gate inversion. A
late terminal for an older turn cannot clear a newer follow-up's state. A cold
reader uses the terminal as authority to clear and save its pause before
returning a snapshot. No model/tool is invoked for terminal reconciliation.

The common child terminal cleanup pairs held tool calls as `not_executed`,
retires their IDs, pending input, compaction and pause flags, and saves before
reporting completion. It also runs during terminal recovery. A failed state
save restores the pending state for retry; already-written tool results are
not duplicated. The existing fresh-follow-up cleanup remains a defensive path
for old journals whose owner terminal never reached the child mirror.

The adversarial sweep found two issues in the first Round-4 implementation,
both fixed before final validation: a failed terminal cleanup could clear its
in-memory retry predicate (2 failing assertions), and passing a parked job's
already-closed child writer to seal could prevent Stop acknowledgment (3
failing assertions). It also tightened source rollback to retain memberships
added while root acknowledgment was in flight. The broader existing pause class
exposed the close/publication race described above. No permission, capture,
tool grant, accounting ownership, vault or user-data boundary was relaxed.

### Round-4 adversarial condition audit

Compared the entire branch's production diff with the merge base of fetched
`origin/dev/next` (`6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1`), then included the
Round-4 working diff. The Round-3 condition audit above remains applicable;
these are the final decisions after rechecking every changed condition and its
opposite branch. Off/memory/persist are not predicates in any production fix.
The stopped-child reader, cold-recovery and follow-up fixtures exercise all
three modes with generated journals.

| Changed condition/path | States taking the changed branch; opposite states checked |
| --- | --- |
| Recovery excludes `heldChildren` from cost parking | Queued/running/stopping unsealed turns with durable human Stop become terminal. Unstopped unsealed turns still park; existing terminal evidence still wins. No execution on open. |
| Park sees cancelled job / terminal owner | Allocated cancelled jobs finish; queued cancelled jobs retain their existing finisher. A terminal owner mirrors terminal instead of writing queued. Uncancelled, unsealed jobs retain ordinary park behavior and instance checks. |
| Resume snapshot/install takes family gate | Stop can precede or follow installation, never seal between a stale snapshot and queued write. Draining is outside the gate; cancelled Resume restores the owner pause and halts live work. |
| Human Stop bypasses coordinator pause; allocated cancellation precedes gate | Live target requests/tools cancel promptly; siblings' compaction is independent. Queued/parking/absent jobs use gated terminal writes. Nonhuman cancellation still preserves cost parking. Unknown targets fail scope checks; stale old-turn Stops do not hold a newer turn. |
| Parked/terminal Stop resolves writer after sealing | Live parked writer is updated atomically; a closed writer falls back to host/cold reconciliation. The host serializes retained-reader mutation with opens/deletes. Ordinary live runners still seal themselves. A newer child turn skips old-turn pause retirement. |
| Delivery returns none/delivered/compact | Empty/held inbox remains unchanged; fitting input commits under gate; oversized single input may compact once outside gate and reselect. Multi-event batches still shrink; still-oversized input fails without delivery. Stop/cancellation and new sibling results during compaction are rechecked. |
| Fresh child follow-up retires old pause/held calls | Terminal prior turn's held calls are paired without execution. Same-turn Resume keeps legitimate held work. Unpaused fresh turns have no extra work to retire. |
| Terminal cleanup predicate | Only managed children with latest terminal and pause/held-call/compaction state retire it. Ordinary independent Stop, unfinished parked children, and newer follow-ups retain their state. Failed save rolls back; cold replay repairs terminal-before-cleanup crashes. |
| Pending Resume included in owner halt | Stop/close between accepted receipt and resumed runner halts children. Ordinary unpaused cancellation is unchanged; already-paused owner remains held. |
| Fan-out saved even without owner work | Idle ancestor with active descendants saves intents; truly empty family gains no invented own work. Recovery validates ancestry/journals; missing or idle sides are excluded. Idle intermediate carries descendants without becoming a paused member itself. Orphan becomes its own root. |
| Accepted Resume clears pending intents; refusal restores | Already-applied side pauses stay in root members until side Resume. Callbacks not yet applied are retired by the accepted generation. Invalid override/limit refusal preserves the original generation and obligations. |
| Root member acknowledgment / known repair | New member pauses the family; known repair confirms persistence without undoing an accepted root Resume. Closed/invalid owners cannot acknowledge. Append/sync failure retains source; a partial transfer may retain duplicates conservatively until retry. |
| Source transfer/removal rollback | Successful root save precedes source removal. Failed root save keeps all source members; failed source save restores its current list, including concurrent additions. Live callbacks cannot acknowledge a failed side/root save. |
| Automatic cleanup and member/intent removal | No-work pause clears durably before cross-actor release. Failed clear/removal keeps the obligation for retry; remaining own work or other members prevents clearing the aggregate pause. Deletion removes both membership and pending intents. |
| Publication crosses close/delete | A closed side cannot begin publication; if close crosses root acknowledgment, an unkept/deleted side is retired again. Kept closed sides with journals keep their Resume membership. File read errors retain obligations conservatively. |
| Restore persists changed projections | Newly inherited pause/membership and deletion/terminal cleanup are saved. Unchanged states need no new recovery save. Readers do not start work; authority remains in original journals, with no capture dependency. |

No additional product decision was needed. Independent Stop/close intentionally
continues to hold unfinished work for explicit Resume; clearing every pause on
an independent Stop would violate the owner's contract.

### Round-4 regression and mutation evidence

Ten new `FamilyLimitPauseTests` cover root append/synchronize failure with an
unopened leaf and restart; known-member acknowledgment retry; failed source
removal with concurrent membership; live side/ancestor fan-out save failure;
automatic retirement save failure; failed member/intent removal followed by an
unrelated save and restart; both host Stop routes with retained and reopened
readers in all capture modes; held-tool terminal recovery in all capture modes;
terminal cleanup retry; Stop after the parked writer closed; and delayed
publication after discard/delete. Assertions inspect snapshots, actual Resume
reply members, tool-result rows and request/tool invocation counts. The prior
Stop → Resume → follow-up and sibling-compaction acknowledgment tests remain in
the full affected class.

With the final ten tests and production sources restored to `deb20a8d`, the
failing-first run produced **79 failed assertions, 0 unexpected errors** after
a successful build (`logs/round4-red-final.log`). The test runner restores all
production sources in `finally`. Initial fixture corrections were needed: host
open uses `path`, and a kept side must be reopened to inject failures into its
actual writer (Keep replaces the ephemeral writer). Failure probes now assert
that the injected failure ran. These early fixture runs are not the final red
evidence. One extra-mutation build caught a missing Swift `try` on the throwing
Boolean expression in the deletion check; it was corrected and both extra
mutations were rerun successfully.

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12
python3 "$B/check-round4-mutations.py"
python3 "$B/check-round4-extra-mutations.py"
```

Each mutation successfully built, failed the intended regression, and had zero
unexpected errors. Final sources were restored after every run.

| Mutation | Failed assertions | Text log under `$B/logs` |
| --- | ---: | --- |
| Return success after failed root save | 6 | `round4-mutation-false-ack.log` |
| Acknowledge known member without saving | 4 | `round4-mutation-known-member.log` |
| Acknowledge fan-out despite failed publication | 2 | `round4-mutation-callback-ack.log` |
| Roll back to the source list captured before the root await | 1 | `round4-mutation-stale-source.log` |
| Release automatic pause before local durable save | 1 | `round4-mutation-early-retirement.log` |
| Drop rollback for failed member/intent removals | 2 | `round4-mutation-removal-rollback.log` |
| Skip live terminal pause cleanup | 8 | `round4-mutation-live-terminal.log` |
| Skip cold terminal pause cleanup | 6 | `round4-mutation-cold-terminal.log` |
| Clear terminal cleanup's retry state on failed save | 2 | `round4-mutation-terminal-rollback.log` |
| Seal through the parked job's already-closed writer | 3 | `round4-mutation-closing-writer.log` |
| Allow closed sides to publish membership | 2 | `round4-mutation-late-closed-publication.log` |

### Round-4 final validation

All commands below run from this worktree, using only its build root. No app UI
code changed, so no galleries needed regeneration. The native runner takes and
releases the shared full-lane lock for each command, runs LifecycleHelper alone,
and removes only this build root's automatic result bundles.

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" \
  --filter 'FamilyLimitPauseTests|AgentFamilyRecoveryTests|CostLimitTests|SideBudgetTests|SideBudgetCrashMatrixTests|SideBudgetCorrectionTests|SideBudgetReplayTests|AgentSteering|Subagent|Compaction|HostServiceTests|HostDispatchTests'
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests"
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" --skip-build \
  --filter 'ContinueRunTests|QueueHandoffTests|QueueEditHoldTests|QueueDeliveryRecoveryTests|QueueEditingTests|SessionSettlementTests|RetryRecoveryTests|ConcurrentSessionsTests'
PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$B/bundle/Helpers/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/bundle/Helpers/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/bundle/Helpers/pi-native-host"
bash "$B/check-round4-native.sh"
# The native runner executes these exact focused commands:
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/RunHoldTests \
  -only-testing:PiAppTests/CostPausePresentationTests \
  -only-testing:PiAppTests/CostLimitTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/CostPauseFamilyTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/LifecycleHelperTests
```

| Suite | Final result | Text log under `$B/logs` |
| --- | --- | --- |
| Affected helper tests, including all 60 FamilyLimitPauseTests | 387 passed, 0 failed | `round4-focused.log` |
| Full helper suite | 1,034 passed, 7 skipped, 0 failed (1,041 total; 403.9 s) | `round4-helper-full.log` |
| Release helper build | Passed | `round4-bundle.log` |
| Native RunHold / CostPausePresentation / CostLimit | 37 passed (18 / 6 / 13), 0 failed | `round4-native-pause.log` |
| Native CostPauseFamily, alone | 3 passed, 0 failed | `round4-native-family.log` |
| Native LifecycleHelper, alone | 11 passed, 0 failed | `round4-native-lifecycle.log` |
| Wire | 36 passed, 0 failed | `round4-wire.log` |
| Concurrent | 4 passed, 0 failed | `round4-concurrent.log` |
| Acceptance | 3 passed, 0 failed | `round4-acceptance.log` |

In the final full helper run, `subagent.stop` acknowledged in **0.356 ms** and
managed-child `turn.stop` in **0.473 ms**, with sibling compaction still held.
The seven skips are the existing opt-in fixture/performance tests. No unrelated
test failed. The code/test diff fingerprint remained unchanged throughout final
validation (`round4-validated-diff.sha256`). All 51 native tests ran under the
shared lock, which was released; no clone directories or result bundles remain
under this build root. No unresolved finding or owner decision remains.

## Round 5 — cold terminal mirror responsiveness

Confirmed against `6d9cf5b0`: when a parked child's runtime had been evicted,
`NativeHostService.retireAgentChild` called `AgentFamilyRecovery.mirrorTerminal`
synchronously on the host actor. Managed-marker validation, the journal's chain
scan and the full family replay prevented unrelated commands from entering the
host. The writer gate was correct; the executor was not.

The entire cold reconciliation now runs in an awaited
`Task.detached(priority: .userInitiated)`. The runtime gate remains held through
completion or error, and the worker captures only the accepted plan/turn,
directory and optional test hook. Loaded readers still use their existing
session actor and original journal writer. No pause, membership, capture,
permission, tool, vault or accounting rule changed.

### Round-5 regression and mutation evidence

`FamilyLimitPauseTests.testColdParkedStopKeepsOtherChatsResponsiveAndRuntimeGated`
creates a real parked/evicted child, appends 12,000 generated messages, and
issues `subagent.stop` through the host. A synchronous disk-work barrier makes
the overlap deterministic: another chat's snapshot and Stop must both reply
within one second while a concurrent child open must remain gated. After
releasing the barrier, the test measures repeated snapshot/Stop pairs during
the actual journal replay. It checks the replies, the complete reopened
transcript, and the child's cleared pause in the returned snapshot.

The failing-first run added only the regression and a nil-by-default test seam
to the original production path. It built and failed **3 assertions, 0
unexpected errors**: neither unrelated command replied during the held mirror;
no snapshot/Stop pair completed during real replay; and a pair took **402 ms**
of the **405 ms** replay (`logs/round5-red.log`). With the fix, that same test
passed: **104** pairs completed during **421 ms** of replay, with worst combined
latency below **1 ms** (`logs/round5-green.log`). The child open waited for the
writer and returned all 12,000 messages without a cost pause.

Both effective mutations built and failed with zero unexpected errors. The
runner restores production source in `finally`.

| Mutation | Failed assertions | Real replay / worst other-chat pair | Log under `$B/logs` |
| --- | ---: | --- | --- |
| Put the entire worker back inline on the host actor | 3 | 426 / 422 ms; 0 pairs served during replay | `round5-mutation-inline-replay.log` |
| Keep only the barrier detached; replay the journal on the host actor | 2 | 406 / 402 ms; 0 pairs served during replay | `round5-mutation-replay-outside-worker.log` |

An initial `Task.detached` → `Task` mutation passed: this value-only closure did
not reproduce the blocked host on this Swift toolchain. It is not counted as
regression evidence (`round5-mutation-inherited-actor.log`). The explicit inline
mutations above verify the actual failure, including replay after the barrier.

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" \
  --filter FamilyLimitPauseTests/testColdParkedStopKeepsOtherChatsResponsiveAndRuntimeGated
python3 "$B/check-round5-mutations.py"
```

### Round-5 sweep and adversarial self-review

Fetched `origin/dev/next` (`6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1`) and
reviewed the full branch production diff plus this round's working diff. Grepped
every added journal/replay/recovery call and traced its caller's executor:

| Added disk work | Execution context / result |
| --- | --- |
| `mirrorTerminal` from the host's `retireSteering` callback | The confirmed finding; now entirely in the detached worker under the runtime gate. |
| Default coordinator `retire` callbacks | Async non-host closures; the host always supplies its explicit gated callback. No host-actor replay introduced. |
| `pauseState` / `inheritsPendingPause` and terminal cleanup during session restoration | Session construction runs inside the existing detached `makeSession` / `openAgentChild` workers; no host-actor replay introduced. |
| Side publication's `journalURL` existence check | Runs on the side session actor; no full journal replay. |

Rechecked the Round-3/4 condition and transition tables against all branch
changes. This round adds no state predicate. The retained-child path, missing
child path, scope/accepted-origin checks and terminal authority are unchanged.
The detached worker creates no runtime and holds no host/session mutable state.
Errors propagate through `withRuntimeGate`, which releases on success and
failure. The waiter does not abandon its worker on cancellation, so the writer
remains gated until completion. Host shutdown may close loaded sessions, but
cannot create a competing writer; the owner terminal was durable before cold
mirroring starts. A crash still recovers from that terminal. Streaming and idle
unrelated chats can enter the host during the await; cold opens and deletion
still wait for the gate. Existing Off/memory/persist reader and terminal-recovery
tests remain in the affected class. No additional in-scope defect or owner
decision was found.

Pre-existing, outside this branch: `HostService.swift`'s
`session.portable.preview` / `session.import.inspect` dispatch calls `portable`
synchronously (dispatch line 544, replay line 1029), and `session.recover` calls
`recoverCopy` synchronously (dispatch line 545, scan line 977). Large journals on
those paths can similarly hold unrelated host commands. They were not added by
this branch and are recorded for a separate workstream; they are not changed
here.

### Round-5 final validation

All runs use this worktree and its existing build root. The affected filter
includes the complete pause and child-cost-publication classes, the host classes,
and the family/recovery/compaction coverage from the prior round. No app UI was
changed and no gallery or native lane was run in this round.

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" \
  --filter 'FamilyLimitPauseTests|AgentFamilyRecoveryTests|CostLimitTests|SideBudgetTests|SideBudgetCrashMatrixTests|SideBudgetCorrectionTests|SideBudgetReplayTests|AgentSteering|Subagent|Compaction|HostServiceTests|HostDispatchTests|ChildCostPublicationTests'
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests"
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" --skip-build \
  --filter 'ContinueRunTests|QueueHandoffTests|QueueEditHoldTests|QueueDeliveryRecoveryTests|QueueEditingTests|SessionSettlementTests|RetryRecoveryTests|ConcurrentSessionsTests'
PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$B/bundle/Helpers/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/bundle/Helpers/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/bundle/Helpers/pi-native-host"
```

| Suite | Final result | Text log under `$B/logs` |
| --- | --- | --- |
| Affected helper tests, including all 61 FamilyLimitPauseTests | 394 passed, 0 failed | `round5-focused.log` |
| Full helper suite | 1,035 passed, 7 skipped, 0 failed (1,042 total; 394.6 s) | `round5-helper-full.log` |
| Release helper build | Passed | `round5-bundle.log` |
| Wire | 36 passed, 0 failed | `round5-wire.log` |
| Concurrent | 4 passed, 0 failed | `round5-concurrent.log` |
| Acceptance | 3 passed, 0 failed | `round5-acceptance.log` |

In the full helper run, the cold-mirror regression served **104** snapshot/Stop
pairs during **419 ms** of real replay, with worst combined latency below
**1 ms**. The prior sibling-compaction tests acknowledged `subagent.stop` in
**0.387 ms** and managed-child `turn.stop` in **0.547 ms** while compaction was
still held. The seven skips are the existing opt-in fixture/performance tests.
No unrelated test failed. The code/test diff fingerprint remained unchanged
through final validation (`logs/round5-validated-diff.sha256`). No clone
directories or result bundles remain under this build root. The in-scope fix
has no unresolved finding or owner decision; the older preview/recovery paths
are recorded above for separate work.

## Round 6 — repairing partial seals

Confirmed against `16333a41`: parked Stop wrote the parent terminal before the
result message and steering cleanup. If a later append failed, retry skipped
the entire seal because the turn was terminal. It could acknowledge after
mirroring the child while the parent still lacked its result and retained
undeliverable steering. A second gap existed after saving a steering message's
`not_delivered_interrupted` disposition but before its notice: both live sealing
and recovery selected only pending messages, so that notice was lost.

Sealing now reconciles each component independently. The accepted terminal is
preserved; an equal terminal is not appended again. Stable `result:<turn>` and
`undelivered:<message>` identities repair missing reports without replacing or
re-delivering existing reports. Both pending and already-retired parent inputs
participate; only pending dispositions need another write. A parked Stop retry
runs this repair even for a terminal turn, then reconciles the retained/cold
child before acknowledgment. Conflicting terminal evidence still fails the
existing validation rather than overwriting authority.

The sweep found another instance in this branch: parking a turn whose owner
was already terminal repaired only the child mirror. It now uses the same full
seal repair. Recovery also checks the **message's turn**, rather than the latest
turn of that child: a paused follow-up keeps its own pending steering without
preventing an older terminal turn's notice repair. No provider or tool executes
as part of these repairs.

### Round-6 failure matrices and observable assertions

Seven new tests in `FamilyLimitPauseTests` use generated journals and the
existing append-failure seam. Faults reject the next record after the selected
durable prefix; repeated rejection stays armed until the test explicitly
permits retry. A crash case copies the journals before retry or orderly close.
An actual write/synchronize failure still poisons the journal writer and refuses
live acknowledgment until recovery; it is not treated as a successful append.
Reopening reconciles whichever complete prefix survived. The existing journal
and Round-4 synchronization-failure tests cover that separate writer contract.

| Test | Boundaries / observable result |
| --- | --- |
| `testParkedStopRepairsEveryPartialSealBeforeAcknowledgingRetry` | Both host routes, `subagent.stop` and managed `turn.stop`. Measure and assert nine writes: held-child admission, parent terminal, result, two input-disposition/notice pairs, child terminal, cleared child state. Fail before each write, then retry twice. The child snapshot is unpaused; the list is terminal; the parent snapshot receives one result and both notices; the real family fence closes. Journal counts confirm one terminal per journal and one record per report. |
| `testRecoveryRepairsEveryPartialSealAndInterruptedNotice` | Crash after each of the eight incomplete nonempty Stop prefixes. For each prefix, also fail before every measured parent recovery write, then reopen again. The same snapshot, delivery, fence and physical-record assertions hold. |
| `testSealingRepairsEverySubsetWithoutRedeliveringExistingReports` | All 16 subsets of parent terminal / result / notices / child terminal, with pending or retired input dispositions, with and without restart: 64 cases. Existing notice text intentionally differs from newly generated text. Repeated repair preserves it and the delivered reports; another boundary delivers nothing. |
| `testParkingATerminalTurnRepairsItsPartialSeal` | Park after Stop prefixes 2, 4 and 6: terminal-only, or either disposition saved without its notice. Assert the repaired parent snapshot, child snapshot and family fence, not just the turn status. |
| `testPauseTransferRepairsEveryPartialWriteBeforeSourceRetirement` | Fail at each of four writes while transferring two members: source confirmation, either root member, source retirement. Retry binding, reopen, and check the app's Resume reply contains both leaves exactly once. |
| `testSidePauseFanoutRepairsEveryPartialWriteBeforeAcknowledgment` | Measure the complete side-pause/publication/ack transaction and fail before every write. Retry notification, check the side snapshot and durable intent acknowledgment, reopen, and check Resume returns that side exactly once. |
| `testRecoveryRepairsOldTurnNoticesWhileTheFollowUpStaysParked` | Crash with one retired-but-unreported old input, another old pending input, and a held follow-up with its own input. Recovery delivers the old result and both notices, while the child snapshot stays paused and the list reports only the follow-up input pending. |

The first failing-first run, with the two original regressions and unchanged
production code, built and failed **50 assertions, 0 unexpected errors**
(`logs/round6-red.log`). Representative failures after prefix 2:

```text
subagent.stop/2: one result reaches the parent — 0 != 1
subagent.stop/2: every undelivered input is reported — [] != [steer-1, steer-2]
subagent.stop/2: no stranded steering blocks completion — false
```

After the Stop/recovery fix, the parking sweep failed **8 assertions, 0
unexpected errors** (`round6-sweep-red.log`), including the same missing-result
and blocked-fence assertions. With that fix applied, the first six regressions
passed (`round6-regressions.log`); the old-turn regression and expanded subset
matrix also passed (`round6-old-turn.log`, `round6-subsets.log`). Replacing all
four changed production files with `16333a41` and running all seven new tests
produced **174 assertion failures, 0 unexpected errors**
(`round6-expanded-red.log`). The runner restores source in `finally`.

Each mutation below built and failed the selected regression with zero
unexpected errors. The mutation runner restores all production files between
cases and on exit.

| Mutation | Failed assertions | Log under `$B/logs` |
| --- | ---: | --- |
| Skip seal repair when Stop finds a terminal turn | 22 | `round6-mutation-terminal-retry-skip.log` |
| Live sealing scans only pending inputs | 6 | `round6-mutation-seal-pending-only.log` |
| Append equal parent terminals again | 58 | `round6-mutation-duplicate-terminal.log` |
| Append existing notices again | 168 | `round6-mutation-duplicate-notice.log` |
| Recovery scans only pending inputs | 22 | `round6-mutation-recovery-pending-only.log` |
| Recovery uses the latest turn's hold for older messages | 2 | `round6-mutation-recovery-latest-hold.log` |
| Parking repairs only the child mirror | 8 | `round6-mutation-park-mirror-only.log` |

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" \
  --filter 'FamilyLimitPauseTests/testParkedStopRepairsEveryPartialSealBeforeAcknowledgingRetry|FamilyLimitPauseTests/testRecoveryRepairsEveryPartialSealAndInterruptedNotice'
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" \
  --filter 'FamilyLimitPauseTests/testSealingRepairsEverySubsetWithoutRedeliveringExistingReports|FamilyLimitPauseTests/testParkingATerminalTurnRepairsItsPartialSeal'
python3 "$B/check-round6-mutations.py"
```

Initial test-only compile errors (an awaited actor ID and a `Set<JSON>` assertion)
were corrected before collecting failing-first or mutation evidence. Only
successful builds with expected assertions count as failures above.

### Round-6 multi-record transition audit

Rechecked every multi-record path added or changed by this branch against the
Round-4 field inventory. An in-memory flag is never proof of a completed seal.
For cross-journal membership, the source is retained until the destination
confirms a durable save. The two new membership matrices pass without further
production changes. Intentional accounting/persistence failures still block
execution admission until reopen; the tests do not clear that safety latch to
make Resume pass.

| Transaction / state fields | Durable order, partial-write repair and terminal handling |
| --- | --- |
| Reader Stop: `heldChildren`, parent turn/result, steering dispositions/notices, child mirror | Admission survives before terminalization. Every remaining component is reconciled on retry or recovery; terminal presence alone no longer skips the rest. Stop acknowledges only after parent repair and child reconciliation. |
| Runner seal: child terminal/cleanup, parent terminal/report, notices, job `sealed` | Each component has its own identity/predicate. `sealed` is set only after complete parent repair. A failed append does not mark it complete; recovery repairs the durable prefix. Existing delivered report state is preserved. |
| Recovery: turn terminal, result, input disposition, notice | Parent and child terminal authority remain validated. Missing result and notices are repaired independently; retired inputs stay eligible for notice repair. An unsealed held turn retains its own pending inputs. Repeated recovery does not duplicate records. |
| Park: owner queued state, child queued mirror and pause, job removal | Unsealed work keeps the existing queue/pause path and recovery from the owner's durable hold. A terminal owner now repairs the entire seal before settling, rather than treating its terminal as proof that reports exist. Cancelled/terminal work is never queued again. Existing crash-before-park/Resume tests remain in the affected class. |
| Child terminal/continuations, `costPaused`, `costPendingCalls`, compaction and queue state | Catch up continuations before terminal; pair held calls before clearing IDs; save cleared state last. Already paired calls are filtered by their result evidence. Failed cleanup restores its retry predicates; terminal recovery repeats it before returning a snapshot. An old terminal cannot clear a newer follow-up. Existing Round-4 append/sync, held-tool and capture-mode tests remain. |
| Fresh child follow-up | Old held calls are paired before clearing the old pause and installing the new turn. Failure aborts preparation; the runner seals/recovery reconciles the accepted turn rather than starting past the failed write. Same-turn Resume retains its separate held-work path. |
| Initial fan-out: `costPaused` + `costPendingSidePauses` | Both are saved in one state record before callbacks. Recovery validates saved descendants and promotes remaining work to membership; idle intermediates carry descendants without inventing their own pause. |
| Callback/binding acknowledgment | Persist side state, confirm root membership when needed, then save issuer intent removal. Failure keeps or restores the source intent. Known in-memory membership still requires a durable confirmation. Old-generation callbacks/acks remain fenced. |
| Non-root membership transfer | Persist source state, confirm every root member, then persist source removal. Destination failure retains the source; source-save failure restores its current list, including concurrent additions. Root Resume owns the final members. |
| No-work retirement, side Resume, deletion | Save local retirement before releasing a coordinator/ancestor hold. Failed member/intent removal rolls back; restart can repeat missing-journal retirement. Kept sides retain obligations; deleted/unkept closed sides cannot be resurrected by late publication. |
| Resume receipt, continuation records, job installation | Pending Resume stays serialized as paused until taken. Snapshot/install remains gated with Stop, and each continuation is durable before its job is installed. Stop during pending Resume still halts; recovery never schedules by itself. |
| Inbox delivery intent, context row, owner/recipient acknowledgment | Existing stable delivery/row identities repair a missing acknowledgment from its durable context digest. Compaction stays outside the family gate; selection and commit are rechecked under the gate afterward. This round does not change delivery records. |

### Round-6 adversarial self-review

Reviewed the full branch production diff against `origin/dev/next`
(`6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1`) and this round's diff. The earlier
condition/transition tables still apply, with these refinements:

| Changed condition | States taking the changed branch; opposite states checked |
| --- | --- |
| Human Stop no longer excludes terminal parked turns | Absent/parking jobs repair existing terminal reports. Unsealed turns still get their conservative stopped outcome; terminal turns retain the existing result. Live nonparking jobs still cancel/finish normally. Stale old-turn Stop does not hold a newer turn. |
| Equal parent terminal is skipped | A retry avoids duplicate terminal records. A missing terminal is appended; a different terminal still hits the existing conflict validation. The child mirror and report repair run regardless. |
| Pending **or retired** parent inputs are selected | Pending inputs get one disposition update and any missing notice. Retired inputs get only a missing notice. Delivered inputs, other children and other turns are left alone. Existing notices preserve text, sequence and delivery state. |
| Recovery hold is per message turn | A paused unsealed follow-up keeps its steering. An older terminal's pending input and already-retired notices are repaired even if that follow-up is held. Ordinary nonpaused recovery still retires interrupted inputs. |
| Park finds an owner terminal | Full seal repair runs instead of only child mirroring. Unsealed park behavior, instance checks, cancellation routing, live-tool draining and gate order remain unchanged. |

Checked streaming and idle runners, queued/parked turns, retained and cold
readers, restart, cancellation during Resume, and concurrent sibling work.
Capture Off/memory/persist do not change these predicates. No new synchronous
journal replay was added to the host actor; cold terminal mirroring remains in
the Round-5 detached worker under the runtime gate. No permission, tool, vault,
capture or data boundary changed. The additional findings were the incomplete
terminal-park repair and the recovery notice/old-turn selection gaps described
above; no new product decision was required.

### Round-6 final validation

All runs use this worktree and its existing build root. No app/UI code changed,
no files were added or removed, and no gallery or native lane was needed for
this round. The prior Round-4 51-test native evidence remains above.

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" \
  --filter 'FamilyLimitPauseTests|AgentFamilyRecoveryTests|CostLimitTests|SideBudgetTests|SideBudgetCrashMatrixTests|SideBudgetCorrectionTests|SideBudgetReplayTests|AgentSteering|Subagent|Compaction|HostServiceTests|HostDispatchTests|ChildCostPublicationTests'
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests"
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" --skip-build \
  --filter 'ContinueRunTests|QueueHandoffTests|QueueEditHoldTests|QueueDeliveryRecoveryTests|QueueEditingTests|SessionSettlementTests|RetryRecoveryTests|ConcurrentSessionsTests'
PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$B/bundle/Helpers/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/bundle/Helpers/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/bundle/Helpers/pi-native-host"
```

| Suite | Final result | Text log under `$B/logs` |
| --- | --- | --- |
| Affected helper tests, including all 68 FamilyLimitPauseTests | 401 passed, 0 failed | `round6-focused.log` |
| Full helper suite | 1,042 passed, 7 skipped, 0 failed (1,049 total; 418.6 s) | `round6-helper-full.log` |
| Release helper build | Passed | `round6-bundle.log` |
| Wire | 36 passed, 0 failed | `round6-wire.log` |
| Concurrent | 4 passed, 0 failed | `round6-concurrent.log` |
| Acceptance | 3 passed, 0 failed | `round6-acceptance.log` |

In the full run, `subagent.stop` acknowledged in **0.334 ms** and managed-child
`turn.stop` in **0.451 ms** while sibling compaction remained held. Cold terminal
mirroring served **119** other-chat snapshot/Stop pairs during **423 ms** of real
replay, with worst combined latency below **1 ms**. The seven skips remain the
existing opt-in fixture/performance tests; no unrelated test failed. Release
build warning texts match Round 5 (the existing Swift 6 migration/unused-await
warnings); none was added by this round.

The code/test diff fingerprint remained unchanged through final validation
(`logs/round6-validated-diff.sha256`). No clone directories or result bundles
remain under this build root. No unresolved in-scope finding or owner decision
remains; the older host-actor preview/recovery findings remain recorded in
Round 5 for separate work.

## Round 7 — generation fences and two-phase Resume

Confirmed both reports against `d34fdeb601f4d6a7db002ae0a9ea31ea8faff5d1`.
The continuation loop could finish after Stop installed a coordinator hold,
clear `costResumePending`, and leave the owner unpaused with held children.
The side callback and the original publication could also publish the same
pause on opposite sides of the root's accepted Resume. Checking the later
acknowledgment did not protect the earlier membership mutation.

The protocol now uses one runtime generation clock. A message captures its
issuer's clock identity and pause/Resume counts **before** crossing actors;
receivers check the stamp at the mutation, and check again after intervening
awaits. The clock has no session reference, journal, provider work, or capture
content. A fresh runtime has a fresh clock; closing/unloading retires the old
clock. Synchronous fences order publication/admission against counter changes,
always root before descendant, and are never held across an actor/provider
await. The durable authority remains the existing journals, not the clock.

Resume has two phases: prepare/install (steps 1–2), then commit/activate (step 3):

1. Prepare advances `costResumeCount`, retains `costPaused`, and saves the
   accepted receipt with that durable pause. It sets `costResumePending` and
   captures `costResumeGeneration` at acceptance, before the run can be scheduled. Sides that applied an intent but
   have not published are included in the reply before that intent is retired.
2. Install drains the old runners and installs durable continuations under the
   family gate. A separate install gate makes duplicate installs idempotent.
   Jobs stay held throughout. Cancellation/Stop generation is checked after
   the environment, gate, continuation, and final install awaits.
3. The owner performs one final cancellation/generation check, then clears and
   persists the pause/pending flags under the same synchronous clock fence,
   without an intervening await. Failed persistence cannot expose a temporary
   unpaused clock to another actor. Only the
   stamped activation may pump installed jobs. Stop before commit restores the
   same pause and halts children; a new Resume can release them. Stop after
   commit follows ordinary cancellation and the existing execution fence.

A new limit or genuinely new side pause during install supersedes the accepted
Resume by advancing `R` once. It keeps the same open `P`, so old child runners
can still drain into the hold. Installation uses the acceptance stamp, never a
new stamp captured after the pause arrived.

Acceptance failure restores the pause under a root-before-side clock fence.
No publication can capture a transient counter that a later acceptance reuses.
The same fence covers automatic no-work retirement and rollback. Pending side
fan-out counts as work until acknowledged; its final acknowledgment retires an
otherwise empty pause, so an idle side cannot leave a stale family hold.

A failed install retains the durable
pause and continuation prefix for the next Resume/recovery. A failed commit
restores the pause and never activates jobs. Opening a journal never executes
work. Capture Off/memory/persist use the same protocol and existing authority.

### Round-7 message inventory

`P` means the issuer's `costPauseCount`, `R` its `costResumeCount`, and `S` its
Stop count. Every stamp also carries runtime clock identity. A publication
checks the issuing pause state as well: a publication made during prepare
cannot remain valid after commit, which uses the same `R`. Root publication
fences use root `R`, since concurrent joining sides may advance root `P`
without accepting a Resume. Park uses `P` plus a still-open pause: draining
that same pause remains valid during prepare, and becomes stale at commit or
a new pause. This is necessary for Resume to drain the old runners.

| Cross-actor message | Receiver check and duplicate behavior | Stale/duplicate regression |
| --- | --- | --- |
| Inherited side pause, including intermediate → leaf | `receiveSidePause`: live issuer `P/R/pause-state` and root `R`; closed receivers do nothing. The returned publication retains the original root stamp. | `testStaleInheritedSidePauseIsIgnoredAfterRootResume` (direct and intermediate issuers) |
| Scheduled/repair side publication | `publishSidePause`: captured side/root envelope before local persistence, root note, and returned acknowledgment; never restamp a delayed original. | `testDuplicateSidePublicationCannotUndoTheRootsAcceptedResume`, `testPublicationIssuedDuringPrepareCannotOutliveTheCommit` |
| Root membership note and recovered membership transfer | `notePausedMember`: same envelope checked under synchronous root/issuer fences. Known duplicates confirm durability without starting another pause; retired duplicates cannot rejoin. Transfer retains its source until every root write succeeds and the envelope is still current. | `testDuplicateMembershipNoteIsIdempotentAndAnOldNoteCannotRejoin`; existing Round-4/6 transfer failure matrices |
| Side-resumed membership forget | `forgetPausedMember`: current issuer `P/R` and destination root `P/R`; an older retirement cannot erase a newer pause/intent. | `testStaleMembershipForgetCannotEraseTheNextPause` |
| Unkept-side terminal retirement | `forgetClosedSide`: current closing issuer generation and the ancestor's registered clock must match. Close advances `R` before sending; a replacement runtime cannot be retired by the old one. Duplicate retirement is harmless. Root `R` may advance while close travels: that does not create new work in a closed side. | `testClosingSideRetiresMembershipAcrossANewerRootPause`, `testStaleClosedSideRetirementCannotEraseAReplacement` |
| Fan-out acknowledgment, including binding repair | `acknowledgeSidePause`: original issuing `P/R/pause-state` and root `R`, before durable intent removal. | `testStaleSideAcknowledgmentCannotEraseTheNextDurableFanOut`; existing partial-write matrix |
| Coordinator pause / halt | `pause`: current owner `P/R`, checked at entry and between jobs. Halt no longer bypasses the fence. | `testStaleCoordinatorPauseAfterResume`, `testStaleCoordinatorHaltAfterResume` |
| Child request pause / halt | `receiveChildPause`: current owner `P/R` at the synchronous mutation. Duplicate halt also compares `S`, so it does not repeatedly Stop a child. | `testStaleChildPauseAfterResume`, `testStaleChildHaltAfterResume` |
| Job park | `park`: current owner `P` with pause still open; installed job instance and single-parker guard; recheck after family-gate/state awaits. | `testStaleParkJobAfterResume`; existing duplicate/old-job parking tests |
| Owner queued record / child park mirror | `parkOwnedTurn` / `parkAgentTurn`: same open `P`; child latest turn must still be nonterminal. A terminal or newer follow-up cannot regain its pause. | `testStaleOwnerParkRecordAfterResume`, `testStaleChildParkMirrorAfterResume`, `testDuplicateParkMirrorCannotRestoreATerminalChildPause` |
| Parked-state reader publication | `publishParkedSummary`: owner checks current open `P` after the coordinator's snapshot awaits. | `testStaleParkedPublicationAfterResume` (app discovery revision and child list) |
| Resume installation / owner continuation append | `resumeParked` / `installResumedTurn`: acceptance-time owner `P/R/S`, Task cancellation, pending phase, family gate, and per-runtime prepared stamp. No job pumps in this phase. | `testStaleAndDuplicateResumeInstallAndActivation`, `testStopDuringContinuationInstallationKeepsTheFamilyResumable`, `testResumeInstallCannotRestampAnAcceptanceSupersededBeforeTheRunStarts` |
| Resume activation | `activateResume`: current `P/R` and committed/unpaused owner; no await between check and pump. Repeated activation cannot append another continuation. | `testStaleAndDuplicateResumeInstallAndActivation` |
| Child Resume mirror | `resumeAgentTurn`: current committed owner `P/R` and unpaused phase under the issuer fence. An equal installed lease is a no-op; a newer pause is preserved. | `testStaleAndDuplicateChildResumeInstall` |
| Startup hold release | `releaseStaleHold`: current owner `P/R` before and after the owner-state await, with no jobs and unpaused owner. | `testStaleHoldReleaseCannotOverrideALaterResumeGeneration`; existing reopened-runtime hold tests |

Wake signals carry no authority to change a pause: they only wake a waiter,
which rechecks cancellation/generation/state. Authoritative deletion is a
runtime-lifecycle operation: the host unloads the deleted writer first (retires
its clock), then removes membership and callback registration. Recovery reads
durable intent and validated ancestry; it issues new stamps from the new
runtimes rather than replaying old runtime messages.

### Round-7 state transitions and terminal paths

This supplements the complete Round-4 field inventory and Round-6 record-order
matrix; terminal-result identities, pending tool IDs, compaction focus, and
input-disposition repair retain those rules.

| State | Set / clear / move; persistence and terminal handling |
| --- | --- |
| Owner `costPaused`, `queuePaused` | Limit or valid membership note latches and persists the pause before fan-out. Prepare retains it. Only final Resume commit clears it after the last install await/check; cancelled install retains it. No-work retirement waits for fan-out acknowledgments and persists before releasing holds. Acceptance/retirement rollback is fenced against external clock readers. |
| `costResumePending`, `resumingCostPause`, `costResumeGeneration` | Accepted prepare sets and captures the install stamp; saved as `costPaused`. Successful commit clears; cancellation/error restores the held family and clears only the in-flight operation. Reopen recovers the durable pause, never an automatically running Resume. |
| `costPauseCount`, `costResumeCount`, `stopCount`; clock `live`, `closing`, captured pause state | Property observers publish runtime generations; restore initializes the clock explicitly. Prepare/terminal retirement advances `R`, a new pause advances `P`, Stop advances `S`. A new cause during prepare advances `R` once to supersede acceptance without changing the open `P`. Failed acceptance restores its `R`; an interrupted accepted Resume retains its new `R` and the same open `P`. Close advances its issuing generation and marks `closing`; final retirement sets `live=false`. Clock retirement prevents old-runtime messages after reopen. |
| `costPendingSidePauses` | Saved with pause before callbacks; current acknowledgment removes only after side/root durability. Prepare promotes applied sides into root membership before clearing intent. Recovery still promotes saved unfinished descendants. A final reply cannot retire the pause while intents remain; the final idle acknowledgment retires an otherwise empty pause. Closed/deleted callback registrations cannot create new intents. |
| `costPausedMembers`, `costMemberGenerations` | Root retains durable members until their own stamped retirement. Recovered intermediate copies move only after durable root acknowledgment and current generation check. Runtime duplicate stamps are bookkeeping, never substitutes for a required durable confirmation. Close retires all ancestors and unregisters callbacks; delete removes registrations after unloading. |
| `sideBudgetPauseClocks` | Bound with each real side callback; provides synchronous pause admission/Resume ordering and discovers applied-but-unpublished sides. Clock identity distinguishes replacement runtimes. Closing/deletion removes registrations; retired clocks accept no new callbacks. |
| Coordinator `paused`, `resumeGates`, `preparedResumes`, `activatedResumes`, `resumedThrough` | Current pause/halt inserts hold. Install holds while it drains and writes continuations; prepared stamp deduplicates install. Only stamped post-commit activation releases/pumps; a newer pause rejects it. Existing instance guards protect replacement jobs. |
| Child `costPaused`, `lastCostHalt`, queued state | Current open-`P` park persists the child pause; repeated halt is idempotent. A committed owner Resume clears via a stamped child install; terminalization/recovery/follow-up retain the existing durable cleanup. A delayed park cannot re-pause a terminal child. |
| `heldChildren`, terminal/result/report records | Unchanged authority: explicit child Stop seals rather than parks; terminal children are excluded from Resume. Gate serialization and Round-6 idempotent repair still protect every terminal/result/notice/mirror prefix. |
| Wake revisions and test probes | Runtime notifications only. No durable membership or execution admission is inferred from a wake or a probe. Provider compaction stays outside the family gate; probes default to nil. |

### Round-7 adversarial self-review

Reviewed the whole branch's production changes from its common base with
`origin/dev/next` (`141666ca479184d10a9791754d4c91df456599d8`), plus this round's
working diff. A fresh fetch still has `origin/dev/next` at
`6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1`. A two-dot comparison also contains unrelated changes already
merged by other workstreams; those were not copied or reverted. The prior
Round-4/6 condition tables still apply. For each new condition:

| Condition | States taking the changed branch and opposite states checked |
| --- | --- |
| Live/current generation and publication phase | Streaming, idle and paused receivers ignore old messages after accepted Resume, close/unload, replacement runtime, or a newer pause. Current messages still save normally; a limit raise alone does not advance the generation. Idle intermediate sources can transfer descendant-only membership without becoming paused themselves. |
| Same-generation duplicate membership | A repeat confirms a possibly unsaved member before source retirement, but cannot begin another pause. A new side generation still creates a new pause. Restart uses a fresh clock and durable repair membership, preserving a root Resume accepted before side binding. |
| Applied-side promotion before intent retirement | Applied but unpublished sides join the reply once. Unapplied old callbacks become stale and cannot pause later; already durable members stay until their own Resume. Kept closed sides retain their durable obligation; deleted/unkept sides retire it. |
| Install pending/final cancellation check | Stop before first continuation, after one continuation, and after the final install await leaves all unsealed children held and the app able to Resume again. Streaming tool drain remains cancellable. Successful prepare installs once and activates only after commit. Empty/queued/side-only Resumes follow the same commit rule. |
| Acceptance/retirement rollback | Synchronous failure restores its counters before any external actor can capture a transient generation reused by the next Resume. The same root-before-side fence covers successful writes. Managed terminal cleanup has no outbound child-clock pause messages; snapshots remain actor-serialized. |
| Final reply before side acknowledgment | Pending fan-out retains the open generation even when the root has finished. An active side becomes durable Resume membership; all-idle acknowledgments retire the empty hold. No callback is invalidated merely because the owner finished first. |
| Fresh pause during installation | A new limit settlement or side pause invalidates acceptance even though `costPaused` is already true. Duplicate/repair notes for covered members do not. Repeated causes while that acceptance unwinds do not keep changing `R`; old runners still park under the same `P`. A superseded acceptance cannot be restamped when its run starts. |
| Park/current-turn and child-install checks | Current unsealed children park normally; terminal or newer turns are never moved back. Old park/mirror/reader messages after Resume do nothing. Duplicate child installation leaves a running lease alone. Capture modes do not select different behavior. |
| Close versus Resume retirement | A Resume retirement cannot remove a newer intent. A closing runtime has no future work and may retire its own membership even when the root accepts a newer Resume; generation/registered-clock checks protect replacement runtimes. Unregistering every ancestor prevents future fan-out to closed sides. |

The additional findings were applied-but-unpublished membership, publication
between prepare and commit, the child mirror/reader publication paths, and
close retirement across a newer root Resume. The lock-order review also found that an intermediate retirement could acquire its clock before its root; retirement now takes the root fence first. `testIntermediateCloseRetirementTakesTheRootFenceBeforeWriting` holds the root clock and verifies that the intermediate clock stays available and no write occurs while waiting, then checks its final snapshot. These findings are fixed and covered above.
The final condition sweep found that retaining `costPaused` during prepare
could hide a genuinely new limit or membership cause; both now supersede the
acceptance stamp as described above. It also checked the run-not-yet-started
case and fenced the complete synchronous commit/rollback against clock readers.
A subsequent counter-rollback audit reproduced a publication capturing a
temporary acceptance generation and reusing it after the next Resume. It also
found automatic no-work retirement could fence out unacknowledged side
callbacks. Both now have failing-first observable regressions and fixes:
acceptance/retirement are fenced through rollback, and pending fan-out keeps
the pause open until acknowledgment.
Family-turn snapshot/install and terminal writes remain under the family gate;
long compaction runs outside it and reselects delivery under the gate afterward.
The cold terminal mirror remains detached under the host runtime gate. Grepping
the whole branch found no new synchronous journal open/replay on the host actor.
No permission, capture, tool, vault, or data boundary changed. No new owner
product decision is needed; older out-of-scope host preview/recovery findings
remain recorded in Round 5.

### Round-7 regression, mutation and final validation

The initial failing-first run built and failed both reported cases. After
correcting an overstrict snapshot assertion (an idle root still shows paused
while its members await Resume), both tests were rerun against the pushed
Round-6 production files with only nil-default scheduling probes added. They
failed **5 assertions, 0 unexpected errors** (`round7-baseline-confirmed.log`):
late publication re-paused the queue; interrupted installation lost the parent's
pause, did not hold every child, and a second Resume could not release them.
The runner restores all files in `finally`. The close-retirement sweep separately
failed **2 assertions, 0 unexpected errors** before its fix (`round7-close-red.log`).

The fresh-pause sweep also failed first: `testNewLimitDuringResumeInstallKeepsItsPause`
and `testNewMemberDuringResumeInstallKeepsItsPause` produced **6 failed
assertions, 0 unexpected errors** (`round7-new-pause-red.log`). They inspect the
parent snapshot/queue hold, every child status, and provider request count.

The rollback boundary failed **1 assertion, 0 unexpected errors**
(`round7-rollback-red.log`). The final-reply/fan-out boundary failed **5 times,
including 1 unexpected `nothing_to_continue` error** caused by lost membership
(`round7-final-fanout-red.log`); four failures are snapshot assertions. Neither
count includes a build error.

The Stop-install regression now checks three barriers: before the first
continuation, before the second, and after installation's final await. Every
barrier checks the parent snapshot, child list, provider request count, and a
successful second Resume. The 28 added tests bring `FamilyLimitPauseTests` from
68 to 96. Older fixtures now establish an owner pause/commit along with the
coordinator hold; they do not bypass the generation protocol in production.

All fifteen mutations built and were detected. Sources are restored between cases
and on exit. Two mutations deliberately destroy membership, causing the later
Resume to throw `nothing_to_continue`; the generation mutation reports two
unexpected errors and the fan-out mutation one, in addition to snapshot
failures. No compile failure counts as mutation evidence. After the shared rollback fence was added, the lock-order
mutation survived the original write-only assertion: it blocked before writing
while still holding the intermediate clock. The strengthened regression also
reads that clock while the root is held, and detects the mutation. The table
reports that final run.

| Mutation | Tests / failed assertions or errors / unexpected | Log under `$B/logs` |
| --- | --- | --- |
| Remove install cancellation/Stop checks | 1 / 2 / 0 | `round7-mutation-cancellation.log` |
| Remove Resume publication fence and duplicate-note protection | 1 / 1 / 0 | `round7-mutation-publication.log` |
| Allow prepare-time publication after commit | 1 / 4 / 0 | `round7-mutation-commit-phase.log` |
| Do not promote applied-but-unpublished sides | 1 / 1 / 0 | `round7-mutation-unpublished-member.log` |
| Ignore message generation counts | 3 / 5 / 2 | `round7-mutation-generation-fences.log` |
| Use ordinary Resume retirement for close | 1 / 3 / 0 | `round7-mutation-close-retirement.log` |
| Remove child-install generation/phase guard | 1 / 2 / 0 | `round7-mutation-child-install.log` |
| Allow park mirror to re-pause a terminal child | 1 / 1 / 0 | `round7-mutation-terminal-park.log` |
| Allow stale parked-state reader publication | 1 / 1 / 0 | `round7-mutation-reader-publication.log` |
| Take intermediate close fences before the root | 1 / 1 / 0 | `round7-mutation-close-lock-order.log` |
| Ignore new pause causes during install | 2 / 6 / 0 | `round7-mutation-new-pause.log` |
| Restamp a superseded acceptance when its run begins | 1 / 2 / 0 | `round7-mutation-acceptance-generation.log` |
| Expose a temporary acceptance generation before rollback | 1 / 2 / 0 | `round7-mutation-acceptance-rollback.log` |
| Retire the pause before fan-out acknowledgment | 1 / 5 / 1 | `round7-mutation-pending-fanout.log` |
| Keep an empty pause after all idle acknowledgments | 1 / 1 / 0 | `round7-mutation-idle-fanout-ack.log` |

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-pause-r12
python3 "$B/check-round7-baseline.py"
python3 "$B/check-round7-mutations.py"
python3 "$B/check-round7-extra-mutations.py"
python3 "$B/check-round7-lock-mutation.py"
xcodegen generate --quiet
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" \
  --filter 'FamilyLimitPauseTests|AgentFamilyRecoveryTests|CostLimitTests|SideBudgetTests|SideBudgetCrashMatrixTests|SideBudgetCorrectionTests|SideBudgetReplayTests|AgentSteering|Subagent|Compaction|HostServiceTests|HostDispatchTests|ChildCostPublicationTests'
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests"
swift test --package-path packages/swift-host --scratch-path "$B/swift-tests" --skip-build \
  --filter 'ContinueRunTests|QueueHandoffTests|QueueEditHoldTests|QueueDeliveryRecoveryTests|QueueEditingTests|SessionSettlementTests|RetryRecoveryTests|ConcurrentSessionsTests'
PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/RunHoldTests -only-testing:PiAppTests/CostPausePresentationTests -only-testing:PiAppTests/CostLimitTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CostPauseFamilyTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/LifecycleHelperTests
python3 scripts/test-native-host.py "$B/bundle/Helpers/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/bundle/Helpers/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/bundle/Helpers/pi-native-host"
```

The three native commands run serially under the shared full-lane lock, acquired
and released for each command by `check-round7-native.sh`, including failure
cleanup. No named result bundle is supplied. The new source file required
project regeneration; it produced no project-file diff. No UI changed, so no
gallery regeneration is applicable. Tests use generated journals and loopback
services only; the installed app, real preferences/chats/Keychain and paid
providers were not used.

Full runs were deliberately interrupted after the lock-order and
counter-rollback findings; their partial output is retained as `round7-helper-full-interrupted.log` and
`round7-before-rollback-fence-helper-full.log` and is not final evidence. An
earlier test build was also invalidated by a fixture edit while compiling; it is not counted. Final validation below uses the restored
source fingerprint and a fresh complete run.

One affected-class run exposed a test timing race: the pre-existing
`testAnsweredResumedChildSealsAtItsFinalBoundary` read its probe before the
final-links callback had fired. The test now waits for that probe before
asserting the captured status; the complete class then passed 94/94
(`round7-new-pause-green-final.log`). This was a test synchronization fix, not
a product failure hidden by a retry.

Build diagnostics: the configured Swift 5 build succeeds. The existing
nonisolated `AgentSession` initializer produces Swift 6 migration warnings;
the final clock initialization adds four warnings for reading the recovered
pause/Resume/Stop fields there (`Sessions.swift:642`). This round does not
migrate the initializer or claim Swift 6-mode compatibility. Other existing
initializer/test locking warnings remain visible in the text logs.

Final validation, 2026-10-18, on the restored source fingerprint:

| Check | Result | Text log under `$B/logs` |
| --- | --- | --- |
| Affected helper selection | **429 passed, 0 failed**; includes all **96** pause regressions | `round7-focused.log` |
| Complete continuation/queue classes | **62 passed, 0 failed**: ContinueRun 14, ConcurrentSessions 6, QueueDeliveryRecovery 2, QueueEditHold 16, QueueEditing 12, QueueHandoff 3, RetryRecovery 2, SessionSettlement 7 | `round7-continuation-classes.log` |
| Full helper suite | **1,070 passed, 7 skipped, 0 failed** (1,077 total; 423.49 s) | `round7-helper-full.log` |
| Release helper bundle | **Passed** | `round7-bundle.log` |
| Native RunHold / CostPausePresentation / CostLimit | **18 / 6 / 13 passed** (37 total), 0 failed | `round7-native-pause.log` |
| Native CostPauseFamily | **3 passed, 0 failed** | `round7-native-family.log` |
| Native LifecycleHelper, alone | **11 passed, 0 failed**; native total **51** | `round7-native-lifecycle.log` |
| Wire | **36 passed, 0 failed** | `round7-wire.log` |
| Concurrent host | **4 passed, 0 failed** | `round7-concurrent.log` |
| Native acceptance | **3 passed, 0 failed** | `round7-acceptance.log` |

The continuation-class run includes four tests also selected by the first
filter; the full helper total is counted once. The seven skips are the normal
opt-in fixture writer/large-journal/performance cases: ForkClone (1),
ForkPerformance (1), HistoryReadCancellation (1), SessionOpenPerformance (4).
There were no unrelated failures in the final runs.

In the full helper run, Stop acknowledged in **0.405 ms** (`subagent.stop`)
and **0.475 ms** (managed `turn.stop`) while sibling compaction remained held.
Cold mirroring replayed **12,000 messages in 412 ms** while serving **103**
other-chat snapshot/Stop pairs; the largest pair was below 1 ms (the log rounds
it down to 0). The separate held-worker check also served the other chat while
the cold mirror was blocked and kept opening the target reader runtime gated.

`check-round7-final.py` verified the Swift source hashes before and after the
full helper/build/native/wire sequence; they match
`round7-validated-source.json`. `git diff --check` passed. The shared native
lock was released after each run, including its cleanup path. No clone folders
or automatic result bundles remain in this workstream's build root. A final
fetch confirmed the reviewed `origin/dev/next` revision above is unchanged.
No new owner decision or in-scope failing check remains; the migration warnings
and prior out-of-scope findings are recorded above.
