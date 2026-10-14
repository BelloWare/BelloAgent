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

All mutated sources were restored before the final passing run. Earlier phases and their 157-test selection, 27 v3 crash/shutdown cases, 21 v2 cases and other core mutations are recorded in [design implementation notes](../design/subagents-steering.md#implementation-notes). Those counts describe their respective selections, not distinct tests to add together.

## Phase 6 helper acceptance

In progress after the fix-list commit: real-helper overlap/question/steer/follow-up, 16 speakers and bounded delivery, coordination-limit pause, pending-event shutdown, extended crashes, budget stop, v2 continuation and both older-helper generations. Results and performance measurements will be appended here before the phase 6 commit. UI/gallery and release activation are not claimed by this helper record.
