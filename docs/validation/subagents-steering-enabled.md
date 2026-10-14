# Sub-agent steering — phase 7 enabled-build validation

2026-10-14, `dev/subagents-steer-ui`, worktree `wt-steer-ui`.
`PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-steer-ui` throughout.
Generated fixtures and loopback gateways only. Native tests use the isolated
`com.belloware.PiAppTests.Host`, scratch home and private pasteboards. No installed
app, real preferences, Keychain, user data or paid provider calls. No named
result bundles; text logs under `$PI_BUILD_ROOT/logs` are the evidence.

## Changes and enablement

- Fetched both workstreams. Helper `a2fe6b53` was already merged; merged
  `origin/dev/next` at `88329985` in merge `0056a45d`, including the load-sensitive
  test fixes. Final fetch confirms both upstream tips are ancestors of this tree.
- Enabled the single production `SubagentPolicy.steeringEnabled` switch. The
  default session installation advertises all five parent tools and the v3
  capability without fixture activation. It does not advertise the old
  synchronous `subagent` tool. Existing v2 journals remain recoverable.
- Child statistics pills omit the human-turn figure; the separate child footer
  keeps the real child turn. Parent statistics and money formatting are unchanged.
- Confirmed that the gallery's legacy Work header came from hand-built assistant
  rows without timeline data. Normal journal projection reconstructs timeline
  data even for a completed provider response lacking stream chronology. The
  steering gallery now supplies observed response parts, like a real stream.
- Kept v2 regression setup explicit: internal coordinator fixtures can select
  the historical contract, and generated v2 crash/stream helpers disable only
  v3. Recovery and explicit Resume use the supplied enabled bundled helper.
  There is no new preference, environment override or production control.
- Enabled native validation caught a failure-path regression: installing v3 for
  an ordinary chat made its error handler call Stop, then classify the original
  provider error as cancellation. Family settlement now runs only after family
  acceptance and preserves the original failure before its internal Stop.
  Active children still cancel and settle; genuine user cancellation stays paused.
- The full parallel lane caught three unguarded assignments of published agent
  state on every snapshot. These now follow the existing equality-check pattern,
  keeping ordinary token updates on the transcript channel while real waiting,
  inbox and child-turn changes still update the shell.

## Failing-first and mutation evidence

- `phase7-enablement-red.log`: **5 assertions fail** while the production switch
  is off, covering capability, switch and default coordinator tool availability.
- `phase7-footer-red.log`: the child pill says `0 turns 2 steps`; the new
  assertion requires `2 steps`. The normal-projection nonlegacy-header check
  passes without a production renderer change.
- `phase7-footer-mutation.log`: making child pills show human turns again fails
  that assertion. The child guard was restored before native validation.
- `phase7-enablement-mutation.log`: an unrelated fixture assertion initially
  failed to compile because it read an actor property inside XCTest's
  autoclosure. The read was moved before the assertion; this compilation failure
  is not mutation evidence.
- `phase7-enablement-mutation-2.log`: switching v3 off again produces the same
  **5 availability failures**. The switch was restored before final validation.
- `phase7-helper-full.log`: first full helper run executes **811 tests**, with
  7 opt-in skips and two stale expectations. Updated the large-output test to
  assert `tool-output/<physical-session>/…`, retaining its complete-body check;
  updated the side-cache test's expected tool list to v3, retaining its byte-for-
  byte parent/side tools and cached-prefix assertions.
- `phase7-helper-full-final.log`: those expectations pass; the previously
  documented `StreamingCostTests.testDeltaAccumulationIsConstantTimeInTheReplySoFar`
  process-heap check flakes at 80,976 bytes against its unchanged 65,536-byte
  bound. `phase7-helper-heap-recheck.log` passes alone at 33,328 bytes. No assertion
  or production behavior was weakened. A second full run reproduced the capacity
  boundary (`phase7-helper-full-confirmed.log`, 103,232 bytes with 113 fewer heap
  blocks). The fixture now reserves the known remaining reply capacity before
  its heap baseline, so the unchanged 64 KiB leak bound measures per-delta growth
  without charging a legitimate String capacity expansion. CPU limits remain
  unchanged. `phase7-helper-enabled-final.log` then passes all 811 tests, with
  7 opt-in skips, before the failure-state fix below.
- `phase7-native-affected.log`: the first enabled native run catches the real
  error-to-pause regression in CostLimitTests and WireContractTests. These
  expectations were retained. `phase7-failure-state-red.log` adds two helper
  regressions (ordinary failure/Stop generation and parent failure with an active
  background child), both failing on the original implementation. Their four
  assertions fail before the fix. `phase7-failure-state-green.log`: 28 tests pass.
- `phase7-failure-state-mutation-ordinary.log` and
  `phase7-failure-state-mutation-family.log`: removing the family-adoption guard
  or classifying cancellation after internal Stop independently breaks its new
  regression. Both guards were restored before final validation.
- `phase7-SubagentOpeningTests.log`: stopped the failing run after identifying
  the shared loopback oracle's stale assumption that every tool schema has a
  root `type: object`. V3 status uses the design's `oneOf` object branches. The
  fixture now validates each branch and accepts arguments matching exactly one,
  including `const` discriminators. `phase7-gateway-contract-red.log` demonstrates
  the rejection; `phase7-gateway-contract-green.log` passes both oracle tests.
  Removing constant checks or allowing ambiguous branches independently fails
  `phase7-gateway-contract-mutation-const.log` / `-oneof.log`. Production tool
  schemas were not changed. The gateway's delegation scenario now selects the
  advertised v3 start tool and supplies `mode: wait`.
- `phase7-native-parallel.log` / `phase7-native-parallel-summary.json`: first full
  lane completes with 2,325 passed, 35 skipped and 3 failed tests. The redraw
  regression publishes the shell 36 times for 12 token snapshots. Added a
  nondefault-agent-state regression, also failing first in
  `phase7-run-state-red.log`, alongside that existing streamed-snapshot test.
  The other failures are stale fixture assumptions: the strict capture gateway
  still expects the old v2 tool name, and the manual-compaction fixture's 60k
  window cannot fit its 44,416-token intact history, instruction and 15k summary
  allowance with v3 schemas. Its selected synthetic window is now 80k; its model,
  effort, output-limit, exact-capture and request-count assertions are unchanged.
  The strict gateway now requires the exact enabled v3 parent tool set.
- `phase7-lane-fixes-green.log`: all 58 tests in the six affected classes pass.
  `phase7-run-state-mutation.log`: restoring unconditional publication recreates
  the 36-versus-0 failure. Equality guards were restored before final validation.
- `phase7-helper-wire.log`: the full wire suite finds one remaining historical
  v2 tool-list expectation in its side-cache test. It now expects the enabled
  v3 names; exact tools bytes, complete cached prefix and cache-affinity header
  assertions remain unchanged.

## Validation commands

All shell commands export the build root above and keep temporary files there.
The compatibility binaries are copies of the previous generated actual
`v0.1.125` and `82a307c9` helpers, not installed apps; hashes are recorded in
`phase7-compat-helper-sha256.log`.

```sh
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-tests"
python3 scripts/test-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
scripts/test-macos.sh -only-testing:PiAppTests/<affected-class>
python3 scripts/test-subagent-crashes.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-subagent-crashes.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" --steering --older-helper "$PI_BUILD_ROOT/compat-helpers/v2-82a307c9"
python3 scripts/test-subagent-streaming.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" --fixture
python3 scripts/test-subagent-streaming.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" --steering
python3 scripts/test-subagent-downgrade.py "$PI_BUILD_ROOT/compat-helpers/v0.1.125" --v2-helper "$PI_BUILD_ROOT/compat-helpers/v2-82a307c9" --current-helper "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
```

The affected native selection was RunHoldTests; SubagentCaptureTests,
SubagentDeletionTests, SubagentDiscoveryTests, SubagentInspectorTests,
SubagentMetadataTests, SubagentModelGrantTests, SubagentOrganizationTests,
SubagentTranscriptTests; SubagentSteeringInspectorTests,
SubagentSteeringPresentationTests, SubagentSteeringWorkspaceTests;
TranscriptActionsForwardingTests, TranscriptNativeWorkBehaviourTests;
MetricPillsTests, SessionStatsChartsTests, GatewayAccountingTests,
WireContractTests, CostLimitTests, ResponseChronologyTests and
ResponseTimelinePresentationTests. Their `-only-testing:PiAppTests/<Class>`
arguments were passed in a Bash array. The six serial classes in the results
table were run separately, as classified by `python3 scripts/test-lanes.py list`.

Gallery and full-lane commands:

```bash
export PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/gallery"
export TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$PI_APP_UI_SCREENSHOT_ROOT"
gallery=(-only-testing:PiAppTests/UIScreenshotTests/testRenderSubagentGallery
         -only-testing:PiAppTests/UIScreenshotTests/testRenderSubagentSteeringGallery)
scripts/test-macos.sh "${gallery[@]}"
unset PI_APP_UI_SCREENSHOT_ROOT TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT
parallel=()
while IFS= read -r arg; do parallel+=("$arg"); done < <(python3 scripts/test-lanes.py parallel)
scripts/test-macos.sh -parallel-testing-enabled YES -parallel-testing-worker-count 8 "${parallel[@]}"
```

The v3 whole-family script uses the supplied bundled helper for seven modes.
Only the 16-speaker pending-mailbox stress uses a generated helper's accelerated
acceptance clock. Crash hooks likewise exist only in generated source copies.
The downgrade check additionally creates a real v3 parent/child with the enabled
bundle and verifies both older generations refuse them, with and without a saved
parent checkpoint, without changing journal bytes. The checkpoint comes from
editing a second parent turn, retaining nonempty family context. Initial fixture
attempts incorrectly expected a checkpoint after close or after editing the very
first turn; their logs are `phase7-downgrade.log` and
`phase7-downgrade-empty-context.log`. The final fixture makes five loopback
requests through the supplied production helper and uses no injected hooks.

## Results

| Check | Result | Text evidence under `$PI_BUILD_ROOT/logs` |
| --- | --- | --- |
| Full enabled helper suite, after the failure-state fix | 813 tests, 7 opt-in skips, 0 failures | `phase7-helper-release.log` |
| Full helper wire integration suite | 36 tests, 0 failures | `phase7-helper-wire-final.log` |
| Affected native parallel-lane classes, selected together | 244 tests, 1 skip, 0 failures | `phase7-native-affected-final.log` |
| Full-lane fixes: presentation, workspace refresh, manual compaction, capture, run holds and steering workspace | 58 tests, 0 failures | `phase7-lane-fixes-green.log` |
| Full native parallel lane, 8 workers | 2,329 passed, 35 skipped, 0 failures (2,364 total) | `phase7-native-parallel-final.log`, `phase7-native-parallel-final-summary.json` |
| SubagentNavigationTests, alone after the final state guard | 6 tests, 0 failures | `phase7-state-SubagentNavigationTests.log` |
| SubagentOpeningTests, alone after the final state guard | 9 tests, 0 failures | `phase7-state-SubagentOpeningTests.log` |
| SubagentPerformanceTests, alone | 1 test, 0 failures | `phase7-SubagentPerformanceTests-final.log` |
| MetricsFooterControlTests, alone | 4 tests, 0 failures | `phase7-MetricsFooterControlTests-final.log` |
| MetricsFooterParityTests, alone | 2 tests, 0 failures | `phase7-MetricsFooterParityTests-final.log` |
| CaptureDrainTests, alone after the final state guard | 6 tests, 0 failures | `phase7-state-CaptureDrainTests.log` |
| V2 crash/recovery matrix | 21 cases pass | `phase7-v2-crashes.log` |
| V3 crash/recovery matrix | 33 cases pass | `phase7-v3-crashes.log` |
| V2 four-child streaming | Complete, viewer, Stop and shutdown pass | `phase7-v2-streaming.log` |
| V3 whole-family validation | All 8 modes pass: flow, 16 speakers, rate, loop, Stop, shutdown, update, budget | `phase7-family.log` |
| Downgrade against enabled bundled helper | Both actual older generations refuse promoted parent/child, with and without the parent's real checkpoint; journal bytes unchanged | `phase7-downgrade-final.log` |
| Sub-agent + steering gallery, serial after the final state guard | Both gallery tests pass; 92 + 92 images in light/dark at 920×600 and 1240×800 | `phase7-gallery-final.log` |

Gallery output is `$PI_BUILD_ROOT/gallery/subagents` and
`$PI_BUILD_ROOT/gallery/steering`. Visually checked `parent-steering` in light
1240×800 and dark 920×600: the footer says `2 steps`, with the actual running
child turn still above it. Checked `final-wait` light 920×600,
`delivered-question` dark 1240×800 and the original child view light 1240×800:
typed authorship, selected child, waiting state and two-decimal money remain
intact; the steering fixture no longer shows the legacy Work header.

The final bundled helper has SHA-256
`35be6b82c487906ad54a6e20a0834192d4c2a385ce217741a8637f113a4e9a63`,
matching `phase7-enabled-helper-sha256.log` from before the crash, streaming and
downgrade checks. Only the newest automatic `.xcresult` remains; earlier runs'
text logs and the full-lane JSON summaries retain their evidence. No new owner
decisions or contract gaps were introduced by enablement.
