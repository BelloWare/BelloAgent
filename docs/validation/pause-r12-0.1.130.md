# Cost-limit pause review round 12 — 0.1.130

Branch `dev/a130-pause-r12`, based on `dev/next` at `141666ca`.
This implements the three findings deferred from 0.1.129 in
[limit-pause-0.1.129.md](limit-pause-0.1.129.md#known-for-01130).

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
