# Sub-agent steering validation — 2026-10-14

Worktree: `wt-steer-design`; branch: `dev/subagents-steer-design`; build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-steer`. Helper execution switch remains **off**. Generated projects, synthetic credentials and loopback gateways only. No installed app, real preferences, Keychain or user data. Swift package tests do not launch the app. App/UI work and gallery checks belong to the parallel `dev/subagents-steer-ui` session. Text logs, not named result bundles, are the execution evidence.

## Existing review findings: implementation disposition

This is the owner's supplied pre-implementation fix list, not another review round.

| # | Disposition | Implementation / evidence |
|---|---|---|
| 1 P1: promotion prerequisite/reentrancy | Fixed/clarified | Promotion already ran synchronously before acceptance, without awaiting the tool batch. §9/§10 now explicitly call this preflight. Added an append/nested-promotion fence covering source sync, copy, replacement and reopen. Reentrant-append regression fails without the fence. |
| 2 P1: replacement loops | Fixed | All starts/follow-ups share 64 child turns per real-user/Resume epoch. All work-authorizing parent delivery batches, including results, consume 32 continuations in the synced preparation. After that, terminal collection is allowed only with starts/sends prohibited; reports or renewed work pause with `coordination_limit`. Reopen/compaction/child replacement cannot reset these counters. |
| 3 P2: cancellation contradicts acceptance | Fixed | Live preflight/cancellation/fallback looks up the durable operation before writing a result, including the owner's authoritative report record when its child mirror is missing. Accepted starts keep their identity and stopped waits keep acceptance. Stable receipt row IDs remain unchanged. |
| 4 P2: same-batch routing | Explicitly permitted | §3.2 now specifies state-dependent routing in assistant-call acceptance order. A fast first follow-up may finish before another send; the second can be another follow-up. Receipts pin the actual turn; `expected_turn` rejects stale expectations. No batch reservation or additional IPC was added. |
| 5 P2: prepared steering recovery | Already handled; clarified | Recovery first adopts a durable recipient row/digest. Otherwise it marks child-bound events `not_delivered_interrupted`; their old preparation cannot select them again. Only parent-bound events remain pending for Resume. Existing actual-helper child-row before/after-sync cases check this precedence. |
| 6 P2: frozen instructions | New v3 already handled; legacy fallback fixed | New origins persist `frozenResources` independently of capture. Legacy turn 1 now persists `legacyResources` at first v3 adoption, with a provenance note; later follow-ups retain that snapshot across reopen while preserving old context and tool ceilings. |
| 7 P2: edit-hold liveness | Fixed | Waits wake on deliverable inbox entries, not held entries. Final family wait sleeps under an edit even after child jobs finish. Save/cancel/remove signals the family before the ordinary input-release path checks for an idle run. |
| 8 P2: retry delivery | Fixed/clarified | After backoff, human steering and the bounded agent lane refresh the next physical request. A current request is never changed. `RequestScope.agentDeliveryIDs` records included events per attempt, alongside the existing request fingerprint. No event is inserted twice. |
| 9 P2: restart ordering | Fixed helper contract | V3 list/summary semantic revisions come from the replayed family index. Progress has an optional session-runtime `progressEpoch` inside the existing transport `hostEpoch`; terminal summaries contain no transient progress. UI must retain terminal finality within one turn, while allowing later turns. Integration notes specify the additive fields. |
| 10 P3: acceptance complexity | Already handled | Phase 2 uses one synced self-contained operation row with plan/seed/lease/input/receipt. Removed the stale constituent-commit language. Keep explicit `start(mode)` plus bounded wait to preserve the already-published model/UI contract; background-only start is not required for safety. |

Asynchronous questions remain nonblocking. Reported-spend limits retain the existing admission/dispatch permit checks and possible concurrent/unknown-price overshoot; no reservation ledger was introduced.

## Fix-list tests and mutations

Commands run with `swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-host" --filter …`.

- Initial seven regression tests: **14 assertion failures**, `steering-fixlist-red.log` (promotion fence, replacement/collection bounds, result continuation charge, live acceptance, held wait/release and durable revision).
- Retry regression: **3 failures**, `steering-retry-red.log`, proving the refreshed attempt omitted the question and delivery IDs.
- Legacy reopen fixture initially needed its simulated new user task to clear the recovered queue pause (`steering-legacy-red.log`). With that corrected, omitting the adopted snapshot produces **2 context assertions**, `steering-legacy-snapshot-red.log`; restored implementation passes.
- Final regression selection: **155 tests, zero failures**, `steering-fixlist-final.log`. Includes v3 commands/boundaries/recovery/quotas, legacy adoption, retries, queue editing and existing v2 subagent suites.
- P1 mutation: remove promotion append fence → **2 failures**, `steering-mutation-promotion-fence.log`.
- P1 mutation: remove replacement/collection work caps → **3 failures**, `steering-mutation-replacement-limit.log`.
- P1 mutation: omit durable result-continuation charge → **1 failure**, `steering-mutation-result-continuation.log`.

All mutated sources were restored before the final passing run. Fix-list commit: `3ce58e0e`, pushed before phase 6. Earlier phases and their 157-test selection, 27 v3 crash/shutdown cases, 21 v2 cases and other core mutations are recorded in [design implementation notes](../design/subagents-steering.md#implementation-notes). Those counts describe their respective selections, not distinct tests to add together.

## Phase 6 helper acceptance

All requested helper scenarios pass. `scripts/test-subagent-streaming.py --steering` invokes the new whole-family fixture; the existing streaming cases remain its default. `scripts/test-subagent-crashes.py --steering` invokes the extended v3 crash matrix; its existing v2 cases remain the default. Logs listed below are under `$PI_BUILD_ROOT/logs`.

| Case | Observed assertion / evidence |
|---|---|
| Overlap and two-way question | Two children overlap while the parent performs an independent native tool. The child reports a question; the parent's `subagent_send` receipt routes it as `steer`; the child's next safe request contains the answer and its tool writes that answer to a generated file. Parent request prefixes stay stable. |
| Finished-child follow-up | The second send routes as `follow_up`, uses turn 2 of the same child, and its physical request contains the original sentinel, earlier answer and whole prior conversation. Capture scopes retain the parent budget owner, child turn and depth 1. |
| 16 speakers / mailbox / fairness | `subagent.list.active == 16`; 64 pending reports (four per child); 16 fifth reports rejected as mailbox-full. Each boundary has at most eight events / 16 KiB of event text. The first two batches cover all 16 children despite skewed backlogs. All 64 reports and 16 results arrive exactly once. |
| Real-time rate limit | A separate 16-child fixture uses the real clock: 16 reports accepted, subsequent rapid reports rejected as rate-limited. Final results remain available. |
| Replacement-only coordination | No reports or follow-ups are used to consume allowances. Exactly 32 work-authorizing result continuations occur; the next replacement is refused and the parent pauses with `coordination_limit`. No unlimited start → result → start loop. |
| Stop / Quit / update with pending events | Four accepted questions stay pending behind a parent tool. All child turns settle before close, accepted report receipts still say accepted, and cold open dispatches nothing. Explicit Resume delivers the retained questions/results once, with zero child requests replayed. Update exercises Stop, workspace quiesce and helper shutdown. |
| Budget during background work | Parent cost reaches $0.01 before four concurrent $0.01 child completions. The $0.015 reported-spend limit stops the family at $0.05; this is the designed in-flight overshoot. Exactly five HTTP requests reach the gateway; Resume at the limit sends none. |
| v2 continuation | All 21 existing crash/Resume/shutdown cases and four v2 streaming cases still pass. Legacy-adoption crash cases first finish a real v2 child, then exercise first v3 follow-up adoption without replay. The Swift legacy test retains its once-adopted instructions and conversation across reopen. |

The first 16-speaker fixture incorrectly waited for 16 simultaneous HTTP connections and timed out (`steering-phase6-stream-red.log`). URLSession's existing per-host pool has six connections. The corrected fixture holds children in native tools, checks all 16 active turns through IPC, and lets HTTP slots circulate. It then exposed the real fairness defect: repeatedly selecting the oldest child heads starved later speakers (`steering-phase6-fairness-red.log`). The fix persists a stable child-ID rotation cursor in the same delivery preparation as the continuation charge; the 16-speaker case and final suite now pass. These optional private journal fields do not change the IPC contract.

Only the generated stress helper advances its acceptance clock, by ten seconds per accepted operation, to fill the pending mailbox without a minute of waiting. The separate rate scenario uses real wall time. Crash hooks and the enabled v3 switch also exist only in generated helper source copies. Production has no test environment override, and `SubagentPolicy.steeringEnabled` remains `false`.

Final commands (with the build root exported):

```sh
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-host" --filter 'Agent(Steering|Mailbox|FamilyRecovery)|Subagent|Retry|QueueEdit'
python3 scripts/test-subagent-streaming.py "$PI_BUILD_ROOT/swift-host/debug/pi-native-host" --steering --fixture
python3 scripts/test-subagent-crashes.py "$PI_BUILD_ROOT/swift-host/debug/pi-native-host" --steering --skip-build --older-helper "$PI_BUILD_ROOT/steering-v2-build/debug/pi-native-host"
python3 scripts/test-subagent-crashes.py "$PI_BUILD_ROOT/swift-host/debug/pi-native-host"
python3 scripts/test-subagent-streaming.py "$PI_BUILD_ROOT/swift-host/debug/pi-native-host"
python3 scripts/test-subagent-downgrade.py "$PI_BUILD_ROOT/steering-v1-build/debug/pi-native-host" --v2-helper "$PI_BUILD_ROOT/steering-v2-build/debug/pi-native-host"
```

| Final check | Result / log |
|---|---|
| Helper regression selection after fairness fix | **155 tests, zero failures**, `steering-phase6-helper.log` |
| Whole-family loopback | **8 modes pass**, `steering-phase6-streams.log`; structured measurements in `subagent-steering-streaming.json` |
| Extended v3 crash matrix | **33 cases pass**, `steering-phase6-crashes-final.log`: before/after-sync promotion, start, follow-up, steer, report, report mirror, recipient rows, delivery preparation, report receipt, delivery acknowledgement, both terminal copies, final family fence and legacy instruction adoption; plus Stop/Quit/update with 16 active + 2 queued |
| Existing v2 crash matrix | **21 cases pass**, `steering-phase6-v2-crashes.log` |
| Existing v2 streaming | **4 modes pass**, `steering-phase6-v2-streams.log` |
| Downgrade | Both actual old generations refuse promoted parent and child without changing bytes, `steering-phase6-downgrade.log`. Pre-v2 helper built from tag `v0.1.125` (`steering-v1-helper-build.log`); v2 helper from `82a307c91ffc91e5733308080a51c11185ba97ff` (`phase4-v2-helper-build.log`). Pre-v2 v1 repair / v2 child refusal / marker-only checks also pass. |

Each SIGKILL case verifies the accepted operation/receipt identities, actual tool effects and HTTP count across explicit Resume, no duplicate recipient rows, explicit dispositions for accepted messages, and stable costs on repeated open. The new barriers cover the delivery preparation that persists quota/cursor changes, the child's report receipt, and the one-time legacy instruction snapshot. Existing phase 1–4 and fix-list mutations are retained above; the fairness regression supplies failing-first acceptance evidence. No additional bug-finding/review round was run.

## Measured performance

One Debug run per mode against the generated loopback gateway, with capture enabled. These are synthetic execution measurements, not real-provider latency, a production p95 or a release benchmark. `admission_ms` in the JSON includes helper open/workspace setup and runs until every child has reached the gateway. RSS is one helper sample at that point, not peak memory. Total elapsed includes settlement and helper close. A zero sample in the sequential replacement case means not measured.

| V3 scenario | HTTP requests | Open to all children (ms) | Total (ms) | Stop/close (ms) | Sampled RSS (MiB) |
|---|---:|---:|---:|---:|---:|
| Two-way flow + follow-up | 14 | 98.19 | 437.57 | 4.66 | 23.22 |
| 16 speakers / 64 reports / 16 results | 127 | 270.84 | 976.62 | 4.77 | 45.23 |
| Real-time rate limiting | 68 | 267.15 | 551.39 | 10.67 | 45.64 |
| Replacement limit | 97 | — | 1743.86 | 4.69 | — |
| Stop with pending questions | 8 | 81.68 | 278.69 | 27.89 | 25.20 |
| Quit with pending questions | 10 | 76.83 | 271.23 | 22.76 | 26.84 |
| Update with pending questions | 10 | 75.96 | 255.98 | 18.35 | 26.16 |
| Background budget limit | 5 | 79.50 | 133.47 | 4.83 | 25.02 |

The question's acceptance-to-next-parent-request interval was **21.2 ms**. The 16-speaker case delivered 80 events in ten batches; its peak concurrent child HTTP requests was six, with all 16 child turns active. The Stop fixture captured ten attempts but only eight reached the gateway because cancellation can precede HTTP dispatch. Stop/close includes active stop settlement and shutdown for Stop/update, active shutdown for Quit, and idle close for the other modes.

Existing v2 streaming measurements, four concurrent children:

| Mode | Admission (ms) | Settlement (ms) | Captured attempts | Capture packets | Discovery revisions during stream |
|---|---:|---:|---:|---:|---:|
| Complete | 45.07 | 1305.96 | 6 | 380 | 1 |
| Viewer open | 46.66 | 1281.50 | 6 | 379 | 1 |
| Stop | 40.29 | 70.95 | 5 | 90 | 1 |
| Shutdown | 39.59 | 22.82 | 5 | 86 | 1 |

`origin/dev/subagents` was fetched between steps and remains merged through `65572583`; no further changes were available at phase 6 completion. UI rendering/Inspector/deletion integration, gallery scenes, provider-specific compaction and storage-failure combinations beyond these barriers, the full app/release gate and activation remain outside this helper acceptance. No installed app was launched. Both owner decisions remain resolved; no new permission or design decision is needed to integrate this work.
