# Bello Agent 0.1.62/build 66 acceptance — 2026-09-20

Signed release validated; public verification is pending.
Release source: `2ec983143943e68230b4fbe383702a8015422b8b`. Later documentation-only commits do not change the packaged source.

## Scope and environment

Baseline: `fe5b1daf2359117fa6e257722af1544b1b72c1a6` (0.1.61).
See [PF01–PF09 dispositions](../Performance-Review-0.1.62-2026-09-20.md).
Changes preserve the native SwiftUI/AppKit transcript/composer and Swift helper.
No actor-isolation checks, capture fidelity, durability barriers or test latency
thresholds were weakened. No new telemetry upload or external analytics was added.

Reference machine: virtual Apple M3 Max, 10 CPUs, 16 GiB, macOS 14.8,
Xcode 16.1/Swift 6, arm64. Optimized native tests use Release with
`ENABLE_TESTABILITY=YES`; helper tests use `swift test -c release`.
All gateway/archives are isolated fixtures; no production gateway was contacted.

## Completed checks

- Complete helper suite after ingress coalescing: **224 tests, zero failures**,
  23.703 s. Includes 1/8/32 MiB preparation, exact hash/canonical-Unicode cache
  identity, credential masking, response-byte limits, cancellation, compaction,
  tools, immutable inspector snapshots and twenty-attempt trace trimming.
- Executable gateway concurrency: **three tests pass**, 12.052 s overall.
  Twenty sessions in one project with deliberately slow capture ACKs: 7.903 s;
  four projects: 2.426 s. Each has peak 20 concurrent HTTP requests, 20 tool
  round trips and 80 independently matched request/response captures.
  A third case cancels one stream, fails another and queues a follow-up while
  the other 18 finish; partial cancelled bytes match the gateway prefix.
- Reader regression seeds 100,000 attempts and checks exact nearest-rank
  percentiles against a simple independent distribution, disjoint next/previous
  pages, no repeated aggregate sorts while paging, prepared-statement reset,
  query cancellation, concurrent writes and complete WAL checkpoint progress.
  The optimized aggregate took 1,247.60 ms; two row pages took 193.76 ms.
  Cancellation plus a concurrent write took 31.06 ms.

- Focused native Release selection: **105 passed, two optional screenshots skipped**,
  zero failures, 42.755 s. Includes report/dashboard/storage, all captured-body and
  combined-response regressions, native live-code selection, large tables and
  Markdown viewport/geometry. The final close-coalescing guard is checked separately
  in the actor-instrumented run; this Release selection predates that small guard.

- Broader native interaction selection: **117 passed**, zero failures, 338.962 s.
  Includes five loaded sessions, 37 composer tests (CJK/selection/typing/paste),
  rich scrolling, 35 streaming/resize regressions, disclosure motion, shared idle
  scheduling, geometry reuse and navigation. Native windows ran serially.
- Combined real native/helper load: **one test passed**, 6.031 s. Twenty sends
  reached peak 20 HTTP requests, 20 tool round trips and **80 exact durable bodies**
  in 4.703 s. Two 300-row panes, a 2 MiB JSON inspector, marked input and resize
  ran concurrently. Its 28 interaction iterations measured p50/p95/max
  **13.88/142.68/177.56 ms**, maximum MainActor heartbeat gap **304.56 ms**.
  This remains far from a universal one-frame target; p99 from 28 samples is
  simply the maximum. The faster request completion also changes overlap/sample
  duration, so it is not a controlled before/after UI-speed ratio.
- Isolated optimized helper performance/fidelity rerun: **four passed**. Repeated
  1/8/32 MiB count-cache calls averaged **0.51/3.90/15.33 ms**. Trace append median
  at 8 MiB was **2.09 ms memory / 90.42 ms acknowledging sink**, versus baseline
  **461.79/570.22 ms**. Each point has three samples; these measure the append
  loop, not native disk fsync or whole-application throughput.

- Final source with concurrent-close guard: **50 native Debug tests passed**,
  zero failures, 20.510 s, with explicit `-enable-actor-data-race-checks`.
  Covers read-worker cancellation/C callback ownership, two concurrent archive
  closes followed by reopen, all 25 storage tests, 15 report UI tests, the new
  table window and demand-driven combined view, and release configuration.
  Debug timings are not used as the Release performance comparison.

### Final renderer samples

The 134-delta/300-row follow-up measured mean 24.3 ms, p50/p95/max
24.31/35.51/57.31 ms, including layout/display opportunities and deferred
validation observation. It does not establish a rich-row speedup over the measured
20.4 ms baseline. Live-fence growth (160 samples) measured p50/p95/max
4.68/9.13/12.58 ms with continuous selection. Full initial sizing of the
640-block answer remained 813.91 ms. The 1,500-row table preview measured
12.94 ms at 614 points high; the full table/window test verifies all 1,500 rows,
last-cell access and complete Unicode/quoted copy.

## Failures investigated

The slow-ACK twenty-session single-project executable initially hit its existing
25-second completion deadline with 1,400 tiny body packets behind acknowledgements.
It remained a failure when rerun without compilation contention. The fix combines
already-received bytes on the sender before admission, keeps one 32 KiB batch in
flight, and retains original callback timestamps for SSE events. It does not wait
for future packets and does not alter durability. The unchanged deadline now passes.

An early native test expected the old statement-execution counter to remain
stable after caching. The instrumentation now separates executions, preparations,
sorts and commits, preserving that existing assertion's meaning. An intermediate
fold test measured 26.9 ms against its unchanged 25 ms limit; an isolated rerun
passed at 19.5 ms. Final outcomes are reported without hiding those samples.

The new asynchronous reader introduced an additional shutdown boundary. Final
source coalesces concurrent archive-close callers into one drain/cleanup task;
configuration cannot reopen the archive while it is draining. The dedicated
regression checks reader cancellation, old-reader rejection and successful reopen.

## Limits and remaining work

- Rich active-row sizing still exceeds a 60 Hz frame in the synthetic fixture.
  The 640-block first open still requires exact sizing of every block; only
  distant native-tree retention is improved. No universal smoothness claim.
- Full provisional inner-block virtualization, lazy event-offset indexing and
  filesystem transaction batching remain explicit follow-ups. All original
  capture bytes and complete table/copy source remain available.
- No physical pointer/trackpad refresh, VoiceOver, macOS 26, Instruments GPU,
  allocation-fault or process-wide peak RSS claim. Queue/host bounds are not a
  guarantee of total application memory.
- No fresh-install or actual Sparkle update rehearsal, per standing owner policy.
  Signing, notarization, packaged helper smoke and public hashes/signatures remain
  required before this record is marked released.

## Signed artifacts

- Developer ID: Zhaofeng Wang, team `43TXHV3TM3`; hardened runtime and timestamp.
- App and DMG notarizations accepted, both tickets stapled and validated.
  App submission `70f9452a-21d2-4b6b-a20a-f67ad9219047`;
  DMG submission `aedec28c-efd4-4173-a62c-2ccaf95798eb`.
- Packaged native helper/catalog smoke, archive validation and Sparkle signing pass.
- DMG: **8,030,328 bytes (7.66 MiB)**.
- SHA-256: `896e7b488c70617aaa60aca496f68fae13a64f112ee5ee5ccf07c20000b93f76`.
- App dSYM UUID: `6858B74E-C93C-358D-82AF-FACF557280DC`;
  helper: `3EEFB9FB-06F6-32F9-9FAB-2615457C07AD`. Matching symbols remain beside
  the local release artifacts for crash symbolication.
- No test bundle is embedded in the shipped application. No install/update
  rehearsal was run.

Public product/download/feed checks are recorded after deployment.
