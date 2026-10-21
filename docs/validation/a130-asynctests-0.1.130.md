# Async XCTest assertion loss — 0.1.130

Workstream: `dev/a130-asynctests`, base `f80e83cb`. Xcode 16.1 (16B40), Swift 6.0.2, macOS 14.8 on the shared Mac. Generated fixtures and loopback services only; no installed-app launch, real preferences, chats, credentials, Keychain, paid provider, release, tag or publication. Build root `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-asynctests`; text evidence is under its `logs/` and `evidence/` directories (probe sources in `evidence/probe-sources/`, none committed).

## Verdict

- **Reproduced.** Failures recorded off the main thread are dropped by XCTest itself, not by repository code: in the helper bundle a test with 40 failing assertions reported as few as 30 (`evidence/helper-bundle-30-runs.txt`).
- **Root cause.** XCTest drops an issue that reaches it while the same thread is recording another issue of the same test. Assertions made off the main thread are queued for the main thread, which empties that queue inside each recording, so they hit this whenever the main thread starts recording while the test is still failing.
- **No test can pass because of it.** The dropped issue is always nested inside an issue of the same test that XCTest has already counted. The gate's pass/fail verdicts stand. Failure **counts** and **messages** do not: failing-first and mutation evidence may under-report.
- **Fix.** Every helper test class derives from `HelperTestCase`, and the app test bundle links `IssueRecordingGuard.m`. Each records a nested issue once the outer one is done. Production code is unchanged.
- **Hidden failures: none.** The full helper suite passes before and after (1,162 → 1,163 tests, 0 failures), as the mechanism predicts.

## Root cause

The path below comes from XCTestCore's disassembly (Xcode 16.1, `Platforms/MacOSX.platform/Developer/Library/PrivateFrameworks/XCTestCore.framework`) and was confirmed at run time.

1. `XCTFail`/`XCTAssert*` → `_XCTRegisterFailure` → `_XCTPreformattedFailureHandler(nil, …)` → `_XCTFailureHandler` → `[_XCTCurrentIssueHandler() handleIssue:]`. The current handler is a global stack, so it is the running test from any thread.
2. `-[XCTestCase handleIssue:]` queues `^{ [self recordIssue:issue]; }` with `_enqueuePrimaryThreadBlock:`. `_dequeuePrimaryThreadWork` runs the queue only on the test's primary thread, the main thread that `performTest:` stores. Off that thread the issue waits.
3. The main thread empties the queue (a) from a run-loop observer that `performTest:` installs, on every outermost run-loop exit. While an async test runs, `+[XCTWaiter _synchronouslyWaitForTimeInterval:]` runs `CFRunLoopRunInMode(default, min(t, 0.1 s), true)`, so this happens at least every 0.1 s, and sooner when main-thread work wakes the run loop. It also empties it (b) inside `_enqueueIssue:`, that is, inside the recording of every issue.
4. `-[XCTestCase recordIssue:]` stores the issue in progress as the thread's "candidate issue" (thread dictionary, keyed by test). It records it through the legacy `recordFailureWithDescription:…` → `_recordIssue:` → `_enqueueIssue:` → `_dequeuePrimaryThreadWork`. That nested drain first counts the outer issue (`_dequeueIssues` → `-[XCTestCaseRun recordIssue:]`), then runs the blocks queued since. Each block calls `recordIssue:` again, finds the candidate and takes XCTest's reentrancy branch. Its internal log text is: *"recordIssue invoked while already handling an issue (reentrant or recursive usage). The issue will be attached to the current issue and receive no further issue handling"*. The attachment goes on a copy of an issue that is already counted, so the nested issue disappears.

Run-time confirmation:

- **lldb** on a deterministic probe. B is recorded on another thread while XCTest delivers A. `_XCINFLog` fires with that text from `-[XCTestCase recordIssue:] + 88`, nested in `recordIssue: + 844` → `recordFailureWithDescription:` → `_recordIssue:` → `_enqueueIssue:` → `_dequeuePrimaryThreadWork`. The plain class reports 1 failure. Under `HelperTestCase` there is no such call, and the class reports 2 (`evidence/lldb-plain-xctest-reentrant-recordIssue.txt`, `evidence/lldb-helpertestcase-no-reentrant-recordIssue.txt`).
- **Stack counting.** A `record(_:)` override counts calls made inside another `-[XCTestCase recordIssue:]`. In every run, lost failures equal nested calls. For example, 40 − 31 = 9 nested and 40 − 35 = 5 nested; the deterministic probe always shows 1 nested and 1 lost (`evidence/probe-sources/standalone-nested-count-Probe.swift`).
- **Why the window is wide in the helper suite.** Recording an issue is slow: `_handleIssue:` symbolicates the issue's call stack unless the `XCTDisableAggressiveSymbolication` default is set. In the helper bundle, a test with one failure ran 5.016 s against 0.004 s when passing (`logs/mutation-inheritance.log`). Any failure queued during that time is folded away.

## Measurements

Each probe test intends exactly the listed failures. "Lossy" counts runs that reported fewer; "min" is the lowest count reported. The tables come from `evidence/tally.py`.

Standalone package, 100 serial `swift test` runs (`evidence/standalone-matrix-serial-100-runs.txt`); 30 `--parallel` runs in brackets (`evidence/standalone-matrix-parallel-30-runs.txt`):

| Shape (40 failures unless noted) | Nonisolated | `@MainActor` | Via `HelperTestCase` |
| --- | --- | --- | --- |
| 40 × (`Task.yield`; `XCTFail`), ~4 ms | 0 lossy | 0 | 0 |
| 40 × (3 ms sleep; `XCTAssertEqual`) | 87 lossy, 3.1 % lost, min 38 [30/30 lossy] | 0 | 0 |
| 8 × (30 ms sleep; 5 × `XCTFail`) | 80 lossy, 15.4 %, min 30 [28/30] | 0 | 0 |
| 40 task-group children fail | 0 | 11 lossy, 9.7 %, min **1** [1/30] | 0 |
| 40 failures in one `Task.detached` | 0 | 0 [1/30, min 39] | 0 |
| 40 × (`Task.yield`; `XCTFail`) with a 0.5 ms main-thread timer | 0 | 0 | 0 |
| async `setUp`/`tearDown`, 20 + 20 after awaits | 0 | — | 0 |
| one failure: after an await, among 40 passing children, under the timer | never lost, never passed | same | same |

Helper bundle (`PiNativeHostPackageTests`), throwaway probe file, 30 runs each with `--filter AsyncIssueProbe` (`evidence/helper-bundle-30-runs.txt`):

| Shape | Plain `XCTestCase` | `HelperTestCase` |
| --- | --- | --- |
| deterministic nested issue (2) | 30/30 report 1 | 30/30 report 2 |
| 40 × (3 ms sleep; `XCTAssertEqual`), nonisolated | 18 lossy, 1.75 %, min 37 | 0 |
| 8 × 5 bursts, nonisolated | 21 lossy, 13.3 %, min 30 | 0 |
| 40 actor hops, nonisolated | 0 | 0 |
| 40 task-group children, nonisolated / `@MainActor` | 0 / 1 lossy, min 17 | 0 / 0 |
| one failure after a 50 ms sleep, nonisolated / `@MainActor` | never lost, never passed | same |

With slower recording (a `record(_:)` override that reads `Thread.callStackSymbols`), the plain sequential shape lost 43 % and bursts 34 % in every run, while `HelperTestCase` lost nothing (`evidence/helper-bundle-instrumented-30-runs.txt`). `XCTFail`, `XCTAssertEqual` and `XCTAssertNotEqual` share the same path and behave alike.

## Can a failing test pass?

Not through this mechanism. An issue is dropped only by the nested drain inside `_enqueueIssue:` of another issue of the same test, and `_dequeuePrimaryThreadWork` counts that outer issue (`_dequeueIssues`) before it runs the queued blocks. The repository uses neither `continueAfterFailure = false` nor `XCTExpectFailure`, so that counted issue fails the test. Without the fix, no single-failure test lost its failure or passed in 900 runs: 600 serial and 180 parallel standalone runs, and 120 in the helper bundle.

A different hazard, which neither this fix nor `@MainActor` addresses: an assertion in a task the test does not await is recorded against whichever test is running when it fires, or lost if the run ends first. A leaking test passed, the next test failed with the leaked message, and the last test's leak vanished (`evidence/probe-sources/standalone-late-Late.swift`). A source scan of the helper and app tests found no assertion in an unawaited `Task`.

## Fix

- `packages/swift-host/Tests/PiAgentCoreTests/HelperTestCase.swift`: `class HelperTestCase: XCTestCase` overrides the public `record(_:)`. An issue that arrives while the same thread is inside `super.record` for this test is held and recorded right after the outer one returns. It is skipped when `continueAfterFailure` is false, because XCTest keeps only the first failure then and may unwind the test from inside the call. A passing test never calls `record(_:)`, so passing runs pay nothing. All 158 helper test classes now derive from it.
- `apps/macos/TestSupport/IssueRecordingGuard.m`: compiled into `PiAppTests` only. Its constructor replaces `-[XCTestCase recordIssue:]` with the same algorithm and installs a marker method. `@try/@finally` clears the per-thread state if XCTest unwinds. The app target has about 480 test classes, so a constructor avoids editing each declaration. This follows `TestIsolationGuard.m`, which already installs process-wide test guards the same way.

Why not `@MainActor`: it only moves the test body to the main thread. Assertions in task-group children, detached tasks, actors, callbacks and nonisolated helpers such as `eventually` still run off the main thread. Main-actor work also makes the main run loop exit, and so drain, more often: a `@MainActor` test whose children failed lost up to 39 of 40. Moving 927 helper tests onto the main thread would also move their synchronous parts there, such as `stopFixtureProcess`'s `usleep` polling, with no recording benefit once the drop itself is fixed.

## Guards

| Guard | Runs in | Mutation evidence |
| --- | --- | --- |
| `IssueRecordingTests.testEveryTestClassRecordsIssuesThroughHelperTestCase`: every `XCTestCase` subclass in the helper bundle derives from `HelperTestCase` (runtime class list, more than 100 found) | helper suite | `RetryTests` back to `XCTestCase`: fails naming `PiAgentCoreTests.RetryTests` (`logs/mutation-inheritance.log`) |
| `scripts/tests/test_xctest_issue_recording.py` builds two XCTest bundles with the deterministic nested issue. Plain XCTest reports 1, which shows the probe reaches the drop and flags it if a later Xcode fixes it. `HelperTestCase` reports 2. Plain XCTest with `IssueRecordingGuard.m` reports 2. The `.m` is in `PiAppTests` only. | gate's Python suite | `HelperTestCase` without deferral: `1 != 2`. The `.m` recording nested issues in place: `1 != 2`. The `.m` removed from `project.yml`: fails (`evidence/mutation-*.txt`) |
| `IssueRecordingGuardTests.testNestedIssueRecordingIsInstalled`: the marker is present in the app test process | native parallel lane | without the `.m` it fails (see App) |

## App tests

The app target has the same exposure. About 330 of its 2,723 `async` test methods are nonisolated (all 927 in the helper are). In the `@MainActor` ones, assertions in tasks and callbacks still run off the main thread, and the app's main thread is busier than the helper runner's. A throwaway class in the real test host (`evidence/probe-sources/app-host-ZZIssueProbeTests.swift`) recorded these counts over six runs each:

| Shape (intended) | Without `IssueRecordingGuard.m` | With it |
| --- | --- | --- |
| deterministic nested issue (2) | 1 every run | 2 every run |
| 8 × 5 bursts after sleeps, nonisolated (40) | 35–40 | 40 |
| 40 × (3 ms sleep; `XCTAssertEqual`), nonisolated (40) | 35–37 | 40 |
| 40 task-group children, `@MainActor` (40) | 40 | 40 |

Logs: `logs/app-probe-without-guard*.log`, `logs/app-probe-with-guard*.log`. The probe file and `project.yml` change were then removed. `IssueRecordingGuardTests` failed first without the `.m` ("IssueRecordingGuard.m is not linked into PiAppTests") and passes with it (`logs/app-IssueRecordingGuardTests.log`, final project). No helper or app test uses `XCTExpectFailure`, `continueAfterFailure` or a `record(_:)` override, so a passing test never calls the replaced method.

## Suites

| Run | Result |
| --- | --- |
| Helper suite, base, `--skip StreamingCostTests` (`logs/baseline-suite.log`) | 1,162 tests, 7 skipped, 0 failures; 478.3 s in XCTest, 7:59 wall; load 3.1 → 16.6 |
| Helper suite, fix (`logs/fixed-suite.log`) | 1,163 tests (+`IssueRecordingTests`), 7 skipped, 0 failures; 449.2 s, 7:30 wall; load 22.6 → 4.7 |
| `StreamingCostTests` alone under the full-lane lock (`logs/streaming-cost.log`) | 5 tests, 0 failures, 3.68 s; load 2.1 |
| Wire / concurrent / acceptance, Release helper from `scripts/build-bundle.py` (`logs/wire.log`, `concurrent.log`, `acceptance.log`) | 40 / 4 / 3 tests OK |
| Python, `python3 -m unittest discover -s scripts/tests` with `PI_BUILD_ROOT` (`logs/python.log`) | 148 tests OK (3 new), 155.5 s |
| Focused app: `IssueRecordingGuardTests` | 1 test passed |

The pass/fail set is identical before and after, as the mechanism predicts. No test newly fails, so there is nothing to classify as a product bug or a broken test. The timing difference (−29 s) is within the shared machine's noise: load averages swung between 3 and 42 during the runs. A passing test never calls `record(_:)`, so the fix adds no work to a passing run.

## For the lead

- Branches merged later that add `final class …: XCTestCase` to the helper tests will fail `IssueRecordingTests` until they derive from `HelperTestCase`. The fix is a one-word change.
- If a later Xcode stops dropping the nested issue, `test_xctest_issue_recording.py` fails on its plain-XCTest control and says to retire both workarounds.
- Validation records that quote failure counts from earlier helper or app runs (failing-first and mutation logs) may under-count. Their failing/passing conclusions hold.
- Assertions in unawaited tasks remain a separate hazard: they are attributed to whichever test is running, or lost at the end of a run. None were found; the handoff note says to await them.
- Not changed, same exposure: `packages/bello-views`, with 291 `async` tests in 34 classes across three test targets. It would need a copy of `HelperTestCase` in each target or a shared test-support target. **Needs a lead decision.**
- The full app suite was not run here: the replaced method runs only for failing tests. `TestHostIsolationTests` (serial lane, unchanged `TestIsolationGuard.m`) was not rerun.
