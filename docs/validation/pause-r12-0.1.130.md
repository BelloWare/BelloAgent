# Cost-limit pause review round 12 — 0.1.130

Branch `dev/a130-pause-r12`, based on `dev/next` at `141666ca`.
This implements the three findings deferred from 0.1.129 in
[limit-pause-0.1.129.md](limit-pause-0.1.129.md#known-for-01130).
The initial implementation and evidence below were committed as `68491378`.
The subsequent review fixes are recorded in the [follow-up](#follow-up-review-of-68491378).

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
