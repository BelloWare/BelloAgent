# Unexplained Responses incomplete retry — 0.1.127

Owner approval: 2026-10-15. Workstream: `dev/a127-retry-incomplete`, based on
`efe431a345fe68fba24cd8381940a9fb835d68fc`. This work is not merged into
`dev/next`. Build products and complete console logs are under
`/Users/admin/Library/Caches/BelloSwiftWork/build-retry-incomplete`.

## Decision and implementation

This is an **owner-approved deviation from pi 0.85.1**. A Responses terminal
whose status is `incomplete` and whose `incomplete_details.reason` is missing,
null or exactly the empty string is a transient provider failure. Its distinct
code, `provider_incomplete_unexplained`, uses the existing retry path for turns,
utility requests and compaction summaries. The request keeps the global policy
it began with; delays remain base × 2^(n−1). No new retry setting was added.

Explicit reasons remain non-retryable, including reasons whose text resembles
transient errors or context overflow. Malformed non-string reasons are not
treated as missing. `max_output_tokens` remains a length stop. Existing error
wording is preserved, including the empty-string wording and the existing
`Failed after N attempts.` prefix when turn/utility retries are exhausted.

The provider classifies the terminal before parsing its output/tools. A
discarded attempt cannot execute tools or enter model input. Its streamed
content, request ledger timeline and recovery log are cleared before retry or
final failure. Rejected summary content is also removed from compaction's
execution timeline while its local status and attempt links remain. The
content-free ledger retains attempt links; raw capture stays
available in Inspector. If unlink fails, the recovery file is emptied and
synced before proceeding. Stop still pauses the run, including Stop racing a
known incomplete terminal or arriving during backoff. Ordinary cut streams
keep their existing interrupted-reply behavior.

A transport failure after the known terminal cannot reclassify it as an
ordinary cut stream. Accounting failures remain primary errors but carry an
internal discard flag. Recovery-log cleanup precedes ledger persistence, so a
refused journal update cannot prevent that cleanup.

Unaccepted provider content stays in the live ledger only; the journal's
initial ledger remains content-free until settlement. Ordinary turn crash
recovery continues to use the existing partial-reply log. This prevents a
failed cleanup write from exposing already-journaled rejected content after
reload, while completed and ordinarily interrupted replies still persist
their timelines. Compaction likewise persists model parts at settlement.

Terminal normalized usage is recorded independently of reply acceptance for
both SSE and JSON, so failed zero/nonzero usage remains available to Inspector
and archive accounting. Per-attempt cost and family usage follow the existing
accounting paths; the completed reply retains only its own context usage.
Streaming header cost alone remains provisional, not a final reported charge.

## Failing-first and mutation evidence

`IncompleteRetryTests` uses a Python gateway bound to an ephemeral loopback
port, synthetic credentials and temporary projects. Its default response is
HTTP 200, one reasoning item, `response.incomplete` with no
`incomplete_details`, all-zero usage, and `[DONE]`. The next request completes.

- Initial baseline: 11 tests, 10 failing test cases (74 assertions/errors);
  the length-stop control passed. Failures included no second request, summary
  rejection, discarded assistant content and retry-like explicit reasons.
  Log: `logs/failing-first.log`.
- A terminal without an output array failed before classification was moved
  ahead of output validation: one test, five assertions.
  Log: `logs/failing-first-missing-output.log`.
- Review regressions failed before repairs: 17 tests, 13 failing cases,
  39 assertions covering ledger retention, missing failed usage, malformed
  reasons, overflow recovery and Stop at terminal.
  Log: `logs/failing-first-review.log`.
- The final review's three remaining cleanup issues failed first: three tests,
  six assertions. Log: `logs/failing-first-final-review.log`. The repairs and
  surrounding tests passed 58 cases, then the final loopback class passed.
- Extending the journal-write-failure test through live ledger inspection and
  reopen caught two further assertions before deferring ledger content writes
  until settlement. Log: `logs/failing-first-ledger-persistence.log`; the repair
  passed 45 affected cases, including ordinary partial-reply crash recovery,
  compaction gateway and task presentation tests.
- The following full run reported one failure in 833 cases: the timeline crash
  fixture copied only the journal and expected provisional ledger content.
  It now copies the actual `.stream` recovery file too and checks the same
  complete interleaved prefix, text/thinking, interrupted/non-replayable state
  and zero dispatches after reopen. All three `TimelineDurabilityTests` pass;
  completed ledger writes are one update / 1,681 bytes for three parts.
  The initial nonzero run is retained in
  `logs/helper-full-before-durability-fixture.log`; focused confirmation is
  `logs/timeline-durability.log`.
- The final 24-case loopback class passes. It also covers disabled/zero and
  exhausted retries, missing/null/empty reason forms, JSON, function-call
  discard, a successful tool executing exactly once, ordinary/family cost,
  nonzero failed usage, persisted reopen, frozen policy/notices, Stop during
  backoff, unlink failure, post-terminal transport failure, journal/accounting
  write failures, utility purposes and compaction adoption/refusal/cancellation.
- The existing compaction budget test retains refusal/filter/tool/empty
  coverage; its unknown-reason case now verifies exhausted retries, unchanged
  context and no invented usage.
- Native `ResponseTimelinePresentationTests` includes a journal containing a
  streamed ledger followed by its content-free update. History reload and
  transcript projection must not restore old reasoning/text/tool parts, both
  with and without a completed retry.

All mutations were temporary and restored before final validation:

| Mutation | Rejected by |
| --- | --- |
| Retry every non-length incomplete, removing the no-reason condition | Explicit-reason loopback test |
| Remove unexplained-incomplete retry classification | Exact-shape turn and compaction tests |
| Retain failed ledger content | Discard/reopen test |
| Omit failed terminal usage metadata | Zero-usage SSE and nonzero JSON tests |
| Ignore failed recovery-log unlink | Read-only-directory recovery test |

Each mutation produced XCTest assertion failures, not compilation failures.
Summary: `logs/mutations.log`; individual logs: `logs/mutation-*.log`.

## Validation

Run on the owner's arm64 Mac with Xcode 16.1 (16B40) and Swift 6.0.2. The helper
checks follow the split in `scripts/verify-release.sh`: process-wide streaming
cost measurements run alone; the remaining filter covers the rest of the
package. Final production sources are the same in both runs.

| Check | Result | Evidence under the build root |
| --- | --- | --- |
| Full helper package, excluding the separately run cost class | 833 cases: 826 passed, 7 opt-in skips, zero failures | `logs/helper-full-final.log` |
| Isolated `StreamingCostTests` | 5/5 passed | `logs/helper-cost-final.log` |
| `IncompleteRetryTests`, included in the full run | 24/24 passed | `logs/helper-full-final.log` |
| Release helper bundle and Debug native test-host build | Passed | `logs/bundle-final.log`, `logs/native-build-final.log` |
| Native host wire integration | 36/36 passed | `logs/wire.log` |
| Concurrent native host integration | 4/4 passed | `logs/concurrent.log` |
| Native host restart/recovery acceptance | 3/3 passed | `logs/acceptance.log` |
| Python script tests | 79/79 passed | `logs/python.log` |
| Historical v2 subagent streaming, generated fixture | All four modes passed: complete, viewer, Stop, shutdown | `logs/subagent-streaming-fixture.log`, `logs/subagent-streaming.json` |
| Current v3 subagent streaming | All eight modes passed: flow, speakers, rate, loop, Stop, shutdown, update, budget | `logs/subagent-steering-streaming.log`, `logs/subagent-steering-streaming.json` |
| Targeted native retry/presentation/accounting classes | 137 cases: 133 passed, 4 opt-in skips, zero failures | `logs/native-retry.log` |

Together the helper runs cover 838 cases: **831 passed, seven skipped, zero
failures**. The skips are the existing fixture writer and opt-in fork,
history-cancellation and session-open performance measurements.

The first historical streaming invocation omitted `--fixture`, so its v2
gateway rejected the v3 helper's `subagent_start` tool set and timed out. This
nonzero result remains in `logs/subagent-streaming.log` and `logs/check-status.json`.
The corrected invocation uses the documented generated v2 fixture from
`docs/validation/subagents-steering-enabled.md`; all four modes pass. Current
v3 modes use the actual Release helper. No repository script was changed.

Reproducible commands (build products and logs use the requested build root):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-retry-incomplete
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" --filter StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" --skip-build --skip StreamingCostTests
python3 scripts/build-bundle.py
xcodebuild build-for-testing -project PiApp.xcodeproj -scheme PiApp -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PI_BUILD_ROOT/native-verify" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
python3 scripts/test-native-host.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 -m unittest discover -s scripts/tests
python3 scripts/test-subagent-streaming.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host" --fixture
python3 scripts/test-subagent-streaming.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host" --steering
xcodebuild test-without-building -project PiApp.xcodeproj -scheme PiApp -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PI_BUILD_ROOT/native-verify" CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -only-testing:PiAppTests/RetrySettingsTests \
  -only-testing:PiAppTests/MenuBarPresentationTests \
  -only-testing:PiAppTests/TurnInfoTests \
  -only-testing:PiAppTests/TranscriptStreamingStressTests \
  -only-testing:PiAppTests/TranscriptNativeRowParityTests \
  -only-testing:PiAppTests/StableToolPresentationTests \
  -only-testing:PiAppTests/WireContractTests \
  -only-testing:PiAppTests/WorkspaceFollowupTests \
  -only-testing:PiAppTests/InspectorIndexTests \
  -only-testing:PiAppTests/ResponseTimelinePresentationTests \
  -only-testing:PiAppTests/GatewayAccountingTests
```

`scripts/test-lanes.py list` classifies all eleven selected native classes as
parallel-lane classes. They were run sequentially in the isolated test host.
The selection covers retry settings, retry notices at a full transcript window,
retry phase/menu labels, compaction retry progress, request accounting and
discarded-ledger projection on history reload.
The four native skips are the optional menu preview, two calibration sweeps
and the opt-in 70-turn wire measurement.

## Review and delivery

Codex `gpt-6.1-sol` with `xhigh` reasoning performed read-only planning,
implementation reviews and the final whole-change double-check required by
`NEXT-RELEASE.md`. Findings were reproduced before repairs as recorded above.
The final whole-diff review reports no actionable findings
(`logs/ledger-review-result.txt`); its advice was to finish the affected/full
tests and record post-repair evidence before delivery on this workstream only.
The final crash-fixture adjustment also has a clean bounded review
(`logs/test-review-result.txt`), confirming equivalent or stronger recovery
assertions. Neither review modified files or ran tests.

No real provider, production credentials, release packaging/publication or
full native lane is involved. There are no app production-code changes. No
named `.xcresult` bundle was requested; Xcode's automatic test result bundle
was removed after retaining the console log, matching the gate's cleanup.

## Follow-up: preserve an earlier unsaved reply's recovery log

An independent read-only review of `3a570601` found that incomplete cleanup
could delete or truncate a log belonging to an earlier reply. If journaling
that reply fails and `keepAside()` cannot rename its log, `partialReplyUnsaved`
keeps the log for a later open. `logStreamed()` refuses to overwrite it during
subsequent runs. The incomplete cleanup did not respect that ownership.

Before this follow-up, `origin/dev/next` was fetched and merged into the
workstream as requested. It was still
`efe431a345fe68fba24cd8381940a9fb835d68fc`, already an ancestor, so Git reported
`Already up to date.` No merge commit or history rewrite was needed.

While the follow-up was being validated, `origin/dev/next` advanced to
`c656d2dbe0edd2927bd43d24d715b6f290f2c8ef` with Git UI work. Before pushing,
that new tip was fetched and merged into the workstream, preserving the fix
commit `d0c2b638`. The sole conflict was the parallel release-note additions in
`NEXT-RELEASE.md`; both sets of entries are retained. The merged helper package
and `scripts` trees are identical to the tested fix commit, so the helper and
process-level evidence below still applies. Imported Git app changes retain
their upstream validation; no native lane was rerun for this merge.
The bounded read-only merge review confirmed both parents were preserved and
reported no introduced findings (`logs/retained-log-merge-review-result.txt`).

`discardIncompleteReply()` now discards and releases the log only when
`partialReplyUnsaved` is false. Current rejected text, reasoning, tools and
ledger content are still cleared. An earlier retained file and its ownership
flag remain under the existing `removeStreamedLog()` / `keepAside()` recovery
rules; the current attempt never entered that file.

Two new `PartialReplyLogTests` cover explicit Retry and Resume. They create a
real earlier stream, refuse its assistant journal append and make the directory
read-only so `keepAside()` fails. A scripted client then emits an awaiting
observation and rejected content before throwing the unexplained-incomplete
error. Its successful automatic retry waits on an explicit gate. The tests
check unchanged recovery bytes, path and unsaved flag after rejection and
successful settlement; the rejected ledger is empty. They copy the actual
journal and stream files as a crash would leave them, then reopen twice and
require the earlier reply's original identity, full text, reasoning and timeline
exactly once, interrupted and non-replayable, with zero model dispatches. The
successful later reply is present once and the rejected content stays absent.
Existing loopback `IncompleteRetryTests` retain coverage of the actual provider
terminal and current-attempt deletion/truncation controls.

- Failing first: both final gated regressions failed, 34 assertions, including
  the retained 7,579-byte log being truncated to zero and the earlier reply
  missing after reopen. `logs/retained-log-failing-first-gated.log`.
- With the guard: both regressions passed. `logs/retained-log-fixed.log`.
- Mutation: replacing the ownership guard with unconditional cleanup made both
  regressions fail again. The source was restored before subsequent checks.
  `logs/retained-log-mutation.log`.
- Affected helper tests: **86 passed, zero skips or failures**.
  `logs/retained-log-affected.log`. Classes: `PartialReplyLogTests`,
  `IncompleteRetryTests`, `TimelineDurabilityTests`, `RetryTests`,
  `RetryRecoveryTests`, `RetrySettingsTests`, `ContinueRunTests`,
  `AgentSteeringRetryTests`, `CompactionGatewayTests`, `TaskPresentationTests`.

The updated Release helper was rebuilt successfully
(`logs/retained-log-bundle.log`). Process-level checks then passed:

| Check | Result | Evidence under the build root |
| --- | --- | --- |
| Native host restart/recovery acceptance | 3/3 passed | `logs/retained-log-acceptance.log` |
| Historical v2 subagent streaming, generated fixture | All four modes passed | `logs/retained-log-subagent-streaming.log`, `logs/retained-log-subagent-streaming.json` |
| Current v3 subagent streaming | All eight modes passed | `logs/retained-log-subagent-steering-streaming.log`, `logs/retained-log-subagent-steering-streaming.json` |
| Historical v2 subagent crash matrix with current Release helper recovery | 21/21 points passed | `logs/retained-log-subagent-crashes.log` |
| Current v3 subagent crash matrix, including historical-helper refusal of v3 journals | 33/33 points passed | `logs/retained-log-subagent-steering-crashes-final.log` |

The initial v3 crash invocation incorrectly passed the generated v2-mode
fixture as `--older-helper`. That fixture still contains v3 journal support,
so the downgrade assertion correctly failed with `Older helper accepted v3`.
The nonzero result remains in `logs/retained-log-subagent-steering-crashes.log`
and `logs/retained-log-check-status.json`. The corrected full run used a helper
built from the unmodified archived package at
`82a307c91ffc91e5733308080a51c11185ba97ff`, the historical commit documented by
the original steering validation. Its build passed in
`logs/retained-log-compat-build.log`. No script assertions or repository
scripts were changed.

Follow-up commands, after exporting the same `PI_BUILD_ROOT` as above:

```sh
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" --filter 'PartialReplyLogTests|IncompleteRetryTests|TimelineDurabilityTests|RetryTests|RetryRecoveryTests|RetrySettingsTests|ContinueRunTests|AgentSteeringRetryTests|CompactionGatewayTests|TaskPresentationTests'
python3 scripts/build-bundle.py
python3 scripts/test-native-acceptance.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-subagent-streaming.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host" --fixture
python3 scripts/test-subagent-crashes.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host" --skip-build
python3 scripts/test-subagent-streaming.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host" --steering
swift build --package-path "$PI_BUILD_ROOT/compat-82a307c9-source/packages/swift-host" --scratch-path "$PI_BUILD_ROOT/compat-82a307c9-build" --product pi-native-host
python3 scripts/test-subagent-crashes.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host" --steering --skip-build --older-helper "$PI_BUILD_ROOT/compat-82a307c9-build/debug/pi-native-host"
```

The streaming runs generate the current v2/v3 fault-injection helpers reused
by the crash commands. The historical package was extracted with `git archive`
into `compat-82a307c9-source` under the build root.

Read-only Codex `gpt-6.1-sol` / `xhigh` planning confirmed the minimal ownership
guard; the final whole-follow-up review found no actionable findings and
confirmed the recovery coverage (`logs/retained-log-plan-result.txt`,
`logs/retained-log-review-result.txt`). Its advice to finish the process-level
checks and record their exact results before committing is fulfilled above.

This follow-up uses the same build root and only synthetic clients or loopback
gateways. It changes no app code; no native test lane was run and no `.xcresult`
bundle was requested for the follow-up. The full helper/native results above belong to the
original implementation; this follow-up reran the 86 affected helper tests.
