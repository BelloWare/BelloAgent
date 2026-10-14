# SCROLL-14: cooperative helper page cancellation

Scope: `dev/a126-scroll14`, based on `origin/dev/next` for 0.1.126. This completes the app-side journal cancellation work without changing the protocol major version or the history cursor contract.

## Behavior

The helper advertises the optional `read-cancel` capability. A history or version-page command sent by the new app carries a fresh `readToken`. When its caller is cancelled, the app sends:

```json
{"v":1,"kind":"read.cancel","hostEpoch":"…","requestId":"original command ID","readToken":"that dispatch's token"}
```

This control frame does not consume a command slot. The helper ignores unknown, stale-epoch, stale-token and non-page targets. It cancels only the task accepted for that exact dispatch. There is no separate cancellation acknowledgement: the original command replies with `command_cancelled` after unwinding. The app may release the waiting caller immediately but keeps physical admission capacity occupied until that reply or helper loss. An ignored cancel therefore cannot overfill the helper. Reusing a read command ID cannot let a late cancel stop its replacement.

Page construction checks cancellation between rows, before/after journal reads, and before decoding the next retained record. Parallel decode workers carry an explicit cancellation token because Dispatch does not inherit Swift task cancellation. A cancelled read throws; skipped rows never become an unreadable-file fallback or a successful partial page. Complete rows already being decoded are the bounded interruption unit.

Shared index/full-history loads register readers atomically. One departing reader releases its command without stopping other readers. The last departing reader retires the load and cancels its worker, including parallel index validation. New readers can replace a retiring load; only the worker owning the current handle can clear it. Existing file identity, lineage and generation checks still gate adoption. Large abandoned replays are disposed off the session actor. Independent session background loading retains its own lifetime.

Older apps issue unchanged commands and receive unchanged pages. New apps send no control frames to helpers lacking the optional capability, and keep coalescing scroll destinations behind their one physical helper read. A complete reply that beats cancellation remains valid. Unrelated mutations retain their existing cancellation and outcome behavior.

## Generated fixture and measurements

`HistoryReadCancellationTests.testRapidSupersessionMeasurement` generates 200 turns / 4,000 message rows in a 66,056,548-byte journal (63.0 MiB), followed by a compaction checkpoint. It opens through that checkpoint and warms the older-row index. Each of five runs submits 24 immediately superseded position reads, then requests row 3,200. It measures the final page's actual helper reply, not merely the app caller's cancellation, and validates its first row. There are no injected read delays or provider calls. Command handling, journal reads, decode and replies use the production `NativeHostService` in process, in Debug on the owner's Mac.

The initial failing-first baseline on the original helper produced final-page latencies of 726.49, 514.69, 389.31, 601.78 and 415.57 ms (median 514.69 ms); none of the 24 obsolete reads was cancelled. That first harness observed replies by 10 ms polling, and other worktrees were building/testing on the Mac. Treat those figures as reproduction evidence, not a controlled speed ratio.

The final comparison on 2026-10-14 uses timestamps captured inside the reply callback, from final-command submission to reply emission. The control run temporarily disables only the helper's `tasks[id]?.cancel()` handler; the enabled run restores it. Both use the same generated fixture and final code, with no other tests/builds started by this workstream during measurement. Shared-machine load can still vary.

| Round | Cancel disabled: final page (ms) | Enabled: final page (ms) | Enabled: entire request burst (ms) |
| --- | ---: | ---: | ---: |
| 1 | 143.97 | 8.77 | 14.61 |
| 2 | 131.29 | 7.53 | 11.48 |
| 3 | 129.35 | 8.86 | 12.94 |
| 4 | 126.71 | 8.67 | 12.47 |
| 5 | 134.09 | 8.72 | 12.48 |
| Median | **131.29** | **8.72** | **12.48** |

Median final-page latency fell 93.4% (15.1× faster). All 24 superseded reads returned `command_cancelled` in every enabled round; zero did in the control. The final page began at `r3200` in every run. This measures warm indexed page supersession, not cold full-history/version loading. Existing whole-array assembly/index operations can finish between cold-load cancellation checkpoints; cancellation is cooperative, not an interruption of an individual record decode.

Run with:

```sh
CFFIXED_USER_HOME="$PI_BUILD_ROOT/prefs-home" \
TMPDIR="$PI_BUILD_ROOT/tmp" PI_SCROLL14_PERF=1 \
swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-host" \
  --filter HistoryReadCancellationTests/testRapidSupersessionMeasurement
```

## Validation

Fixtures and helper state are generated. Native runs export both `CFFIXED_USER_HOME` and `TEST_RUNNER_CFFIXED_USER_HOME` to `$PI_BUILD_ROOT/prefs-home`; final runs also export both spellings of `PI_APP_SCRATCH_ROOT` to `$PI_BUILD_ROOT/tmp`. No installed app, real credentials/preferences, user journals, paid providers, or `xctrace --launch` are used. Native serial-lane classes run individually; result bundles are replaced rather than accumulated.

Failing-first helper checks produced 10 assertions across five selected cases: obsolete history/version pages still succeeded and built 57 rows rather than stopping after the held row, cancelled shared-load readers waited for completion, and the last reader left the worker running. The native baseline produced 11 assertions in nine cases: missing cancellation frames, callers waiting for replies, and a same-turn reply incorrectly winning over cancellation.

Final helper command:

```sh
CFFIXED_USER_HOME="$PI_BUILD_ROOT/prefs-home" TMPDIR="$PI_BUILD_ROOT/tmp" \
swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-host" \
  --filter 'HistoryReadCancellationTests|HistoryFillTests|FullDisplayTests|HostDispatchTests|JournalCheckpointTests|HistoryWindowTests|MessageVersionTests|LongJournalTests'
```

Result: **49 executed, 48 passed, one opt-in measurement skipped, zero failures**. The measurement separately passed with `PI_SCROLL14_PERF=1`. This includes journal recovery beyond 128 MiB, checkpoint/index integrity, shared-load ownership, cursor identity, message versions, and cancellation before queued work starts. An earlier run hit two existing history-fill gate timeouts while other worktrees were heavily building/testing; the gates were unchanged and the final run passed.

Native tests use `scripts/test-macos.sh -only-testing:PiAppTests/<Class>` with the isolated homes above. The eleven parallel-lane classes below are supplied through a Bash argument array in one invocation; each serial class runs alone.

| Native class | Passed |
| --- | ---: |
| HostSupervisorTests (serial) | 9 |
| FullDisplayTests | 4 |
| HistoryEdgeTests | 16 |
| HistoryExtentTests | 24 |
| HistoryReaderCheckpointTests | 5 |
| HostTransportTests | 8 |
| LongJournalHistoryTests | 1 |
| MessageVersionTranscriptTests | 8 |
| NativeTranscriptScrollTests | 5 |
| NativeTranscriptScrollingPerformanceTests | 2 |
| TranscriptPagingTests | 6 |
| TranscriptRevealTests | 10 |
| TranscriptWirePageTests (serial) | 4 |
| LongChatScrollTests (serial) | 6 |
| LongChatScrollProbeTests (serial, `PI_LONG_PROBE=1`) | 5 |
| **Total** | **113** |

All 113 native tests passed, with zero failures or skips. The six asserting long-chat tests and opt-in 200-turn probe reported zero row jumps, lost rows, edge stalls or page errors. The probe reached both ends by gesture, reached the first row with one Home press in 0.577 s, and showed rows 0–1 ms after each drag stopped. Brief blank viewports during dragging and 34 blank frames during the return gesture remain visible in the probe log; this change does not claim to eliminate every paging/frame hitch.

Existing rich-row scrolling measured 1.945 ms mean / 6.468 ms p95 per step, and the single 88 KiB answer measured 0.281 / 0.565 ms. Wire projection measured 0.748 ms for 300 rows versus 4.408 ms through Codable. These are final Debug observations, not before/after UI speed claims.

Each deliberate regression below failed the named coverage, and all mutations were restored before final tests:

| Mutation | Detecting regression |
| --- | --- |
| Ignore helper cancel frame | History/version row-boundary cancellation |
| Omit cancellation from parallel stored-row reads | Parallel decode and queued-read cancellation: 60 record reads exceeded the 10 already-entered units |
| Remove history/version row checkpoints | Row-boundary cancellation: 57 rows built instead of one |
| Keep the last reader's history worker running | Last-reader cancellation and immediate replacement |
| Cancel a shared worker when another reader still needs it | Surviving-reader version page |
| Suppress the app's cancel frame | Dispatched-page cancellation, token/epoch and physical-slot accounting |
| Let a same-turn reply ignore synchronous cancellation | Legacy helper/same-turn reply regression |
| Stop cancelling modern-helper jump tasks | Newest-destination regression |
| Charge `read.cancel` an ordinary transport slot | Control frame plus 32 ordinary commands under pipe backpressure |

The actual bundled-helper pipe test also supersedes 24 reads from a generated 1,200-row journal and compares the complete final result with the expected page, including ordering and identity. It verifies app/pipe compatibility and caller cancellation; deterministic helper tests and the measurement above establish that helper work stops. Separate cases cover an older helper without the capability, stale epoch/token cancellation, reused command IDs, mutation commands, shared readers, and no partial-success replies.

Read-only planning/diff review and a separate whole-change review used gpt-6.1-sol at xhigh as required by `NEXT-RELEASE.md`; both concluded with no actionable findings. Review feedback was applied to shared-reader admission, worker cleanup ownership, off-actor disposal, and parallel decode cancellation. Final advice: distinguish warm paging from cold loading and helper execution from app caller completion (as above); if the short shared-reader polling windows become flaky under heavy machine load, replace them with bounded eventual conditions.

Logs are retained locally under `$PI_BUILD_ROOT/logs`: `helper-before.log`, `native-before.log`, `helper-perf-cancel-disabled.log`, `helper-perf-final.log`, `helper-final.log`, `mutation-helper-*.log`, `mutation-native-*.log`, and `native-final-*.log`.

## Files changed

- App: `Host/HostSupervisor.swift`, `Host/HostTransport.swift`, `Workspaces/TranscriptReveal.swift` under `apps/macos/PiApp`.
- Core: new `HistoryReadWait.swift`; `HostService.swift`, `SessionHistoryFill.swift`, `SessionOlderRows.swift`, `SessionReads.swift`, `SessionVersions.swift`, `Sessions.swift` under `packages/swift-host/Sources/PiAgentCore`.
- Tests: native `HostSupervisorTests.swift`, `HostTransportTests.swift`, `HistoryExtentTests.swift`; helper `HistoryFillTests.swift` and new `HistoryReadCancellationTests.swift`.
- Records: this document and `NEXT-RELEASE.md`. No release artifacts or generated fixture data are committed.
