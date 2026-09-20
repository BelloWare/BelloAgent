# Performance review follow-up — 2026-09-20 (unreleased)

Starting point: `6477980d916ad823d75e379f828a9e403cd58cbb`,
`BelloWare/BelloAgent/main`. This follows the owner's uploaded **corrected**
Performance-Review.md. The native AppKit document, native composers, immutable
geometry cache and Swift helper remain. No release, version bump, distribution
signing, notarization or website publication was performed; the version is still
0.1.60/build 64.

## Findings and disposition

| Review item | Implementation and limits |
| --- | --- |
| BA-P01: active streaming row | Added opt-in phase counters for root assignment, host construction, explicit sizing/placement and deferred validation. Start independent Markdown blocks at eight blocks instead of 32, following a controlled comparison. Large code fences use a persistent native text leaf. Authoritative stream delivery, capture, terminal/error/Stop publication and the second layout/validation remain intact. General rich-row sizing is still expensive. |
| BA-P02: disclosure motion | Replaced the fixed 120 Hz timer with the view-associated AppKit display link and a weak target. Unrelated snapshots preserve the interpolation; changed geometry retargets from the presented height. Reading anchors track presented row frames. Rebinding, removal and detachment stop motion; Reduce Motion still settles immediately. |
| BA-P03: resize completion | Keep the visible/anchored band exact at the current width. Mouse-up and the quiet fallback schedule reconciliation instead of synchronously measuring the remaining history. Unseen rows stay explicitly provisional, cannot be drawn or enter the shared exact cache, and reconcile against the latest width. |
| BA-P04: idle preparation | Both panes share a 1.5 ms admission budget and minimum interval. A host construction or row measurement/cache/placement is an indivisible unit. Input/content move a quiet deadline instead of causing 4 ms polling. Hidden, occluded, minimized and Reports-covered conversations suspend optional work. Required visible work remains immediate. Expensive native sizing can exceed the budget; it cannot be preempted. |
| BA-P05: large single answer | Added distinct many-block, giant-code and giant-table workloads. Retained the measured large-code improvement. Rejected a shared sizing-host/lazy-host prototype because it slowed streaming and scrolling. Many-block initial construction/exact sizing and giant tables remain synchronous. No approximate inner heights or cross-view Markdown prefix cache were introduced. |
| BA-P06: full-page walks | Kept the existing bounded page walks. Document reconciliation measured about 0.8 ms per rich delta versus roughly 23 ms in SwiftUI sizing. This does not justify a new indexing/parse-cursor rewrite yet. |
| Composer polish | Image drag admission checks pasteboard types without fetching promised image bytes. Asynchronous conversion retains the originating session's attachment/rejection callbacks, even if the editor is rebound before conversion finishes. |

The native code leaf is selected for a fence of at least **16 KiB when mounted**.
It retains literal source, native selection/copy, wrapping, the text accessibility
role, the existing palette/highlighting limit and complete-source copy controls.
Updates append only when the UTF-8 prefix is identical; canonical Unicode
equivalence is insufficient. Width probes restore the displayed text-container
width. Four exact width measurements are retained per leaf.

Small fences keep SwiftUI text. Each mounted fence keeps its chosen renderer so
growth cannot replace the selection owner. Consequently, a fence that starts
small and grows large still uses its original renderer until remounted. The
existing 64 KiB section-copy scan limit is unchanged; whole-message and code copy
continue to use complete source rather than mounted text.

## Measurements and rejected experiments

Release, Swift 6, Xcode 16.1, macOS 14.8 (23J21), `VirtualMac2,1`, Apple M3 Max
virtual machine, 10 CPUs, 16 GiB. Tests ran serially on the same remote machine.
These are CPU/layout/display-call measurements, not physical presentation latency.
Cold means a new pane/cache in the fixture, not a reboot or purged OS cache.
Streaming percentiles use nearest rank; with 28 deltas, p99 equals the maximum.
Phase timings are inclusive and cannot be added together. Counters cover our
explicit calls, not all internal SwiftUI passes. Deferred validation samples are
not an exhaustive trace of all work queued after an update.

The new resize regression was first run against the pinned implementation:

| 300-row history, reader in middle | Pinned implementation | Bounded reconciliation, measured follow-up |
| --- | ---: | ---: |
| Last drag layout | 863.21 ms, 159 rows measured | 17.37 ms, 10 rows measured |
| Mouse-up | 786.97 ms, 141 rows measured | 1.72 ms, no additional rows measured |
| Reading anchor | jumped 253 points | held within 2 points |

The same-binary Markdown comparison, with the other fixes held constant:

| Strategy | p50 | p95 | p99/max |
| --- | ---: | ---: | ---: |
| Original 32-block threshold, separate hosts | 30.90 ms | 48.03 ms | 111.35 ms |
| Eight-block threshold, separate hosts | 28.96 ms | 41.91 ms | 67.11 ms |
| 32 blocks, shared sizing-host prototype | 37.43 ms | 50.55 ms | 140.87 ms |
| Eight blocks, shared sizing-host prototype | 31.85 ms | 42.47 ms | 66.00 ms |

The shared sizing host also changed the 88 KiB single-answer scrolling workload
from 14.21 ms mean / 24.30 ms p95 to 19.43 / 29.39 ms, despite improving first open
from 1,589 to 1,066 ms. It was not kept. Assertions specific to that discarded
prototype were removed; exact geometry, selection, copying and long-block
workloads remain.

A same-binary comparison of the complete 90 KB code fence measured **2,066.05 ms
with SwiftUI text versus 94.37 ms with the native leaf**, at the same 50,036-point
height. The final block-surface fixture measured 77.58 ms for a 90,292-byte fence.
A 68,309-byte, 1,500-row table still took **553.02 ms**. An 83,288-byte, 640-block
answer took **840.46 ms** and retained 640 block hosts, although fewer than 40
were mounted during the viewport test. This is not lazy initial block construction.

Using the native code leaf for *all* fences was also rejected: small-fence rich
streaming showed no consistent benefit, and the many-small-block workload slowed.
The final implementation restricts it to large fences.

Renderer-scoped checkpoint (`review-scoped-code`, before the final scheduler
budget-utilization correction):

| Workload | Result |
| --- | --- |
| Rich streaming into 300 rows, 28 deltas | 30.9 ms mean, 29.90 p50, 43.92 p95, 59.01 p99/max |
| Root assignment in that fixture | 0.01 ms p50, 0.06 p95, 0.07 max |
| Explicit placement in that fixture | 1.58 ms p50, 2.57 p95, 2.75 max |
| Four hidden sessions, content + billing | 2.63 ms mean, 6.32 p95, 15.54 max; no whole-workspace publications |
| Five sessions, content + billing including visible rich content | 54.30 ms mean, 75.70 p95, 81.80 max, including deferred work |
| Five sessions, 32-byte deltas at 50 ms | 20.52 ms mean, 34.21 p95, 50.00 max, including deferred work |
| First native mount of five loaded chats | 211–319 ms to visual readiness; separately 76–2,431 ms to settle provisional geometry |
| Returns to those five chats | 239–350 ms to visual readiness; separately 12–75 ms to exact settlement |

There was **no demonstrated general scrolling speedup at that checkpoint**. The
pinned 300-rich-row scroll fixture measured 18.82 ms mean / 65.17 p95 / 175.47 max;
the checkpoint run was
26.07 / 59.89 / 176.47 ms. The single 88 KiB answer changed from 14.21 / 24.30 /
124.04 ms to 21.56 / 47.78 / 114.66 ms. First open was 284.52 → 213.37 ms for the
300-row case and 1,589.23 → 1,566.49 ms for the single answer. These separate runs
include native draw and run-loop scheduling; they are not isolated causal
comparisons. Both retain zero exact-width cache misses during unchanged scrolling,
stable anchors and bounded mounted view counts. Cold host/draw work remains a
follow-up target; the resize/code improvement does not establish universal smoothness.

The test formerly described as a “2,000-row page” actually applies the production
**500-row display cap to 2,000 source messages**. Its output now reports both
counts and asserts the cap. Do not cite it as 2,000 simultaneously rendered rows.

## Combined concurrency and interaction

The opt-in integration runs the actual packaged helper and request-aware loopback
gateway with 20 cold sessions, two visible native conversations each seeded with
300 historical rows, a 2 MiB structured JSON inspector, native CJK marked text and
two width changes. Synthetic historical rows affect the native projection only;
they do not alter provider context or the helper journal.

Final result (`review-budget-utilization`): **20 overlapping HTTP requests, 20 real read-tool round trips,
660 streamed text events and 80 exact durable request/response bodies**, including
masked authorization and accounting checks. All sessions finished in 6.400 s.
The 64 interaction iterations measured 4.58 ms p50, 112.65 p95 and 181.98 p99/max;
the two resize/release steps were 13.25 and 27.02 ms. The main-thread heartbeat
maximum gap was **351.01 ms**. These spikes fail the review's aspirational
continuous-interaction target and remain visible in the record.

Without visual load, the same integration completed in 5.519 s with a maximum
heartbeat gap of 11.90 ms. Capture progress is therefore checked separately from
rendering load; no artificial slow-disk fault injection was performed. This change
does not claim a new concurrency architecture or change helper/storage contracts.

## Final source confirmation

The scheduler's original one-unit-per-pane limit underused the time allowance.
The final correction rotates after each cheap unit and continues until the shared
budget is spent. It does not lift the global interval or input/visibility guards.

`review-budget-utilization` passed **16/16**. Its 500-rendered-row/2,000-source
scrolling workload completed 11,908 synthetic steps: **4.92 ms mean, 106.1 ms
maximum, 12.8% above 8.33 ms**. Before the budget-utilization correction it was
5.01 ms / 95.9 ms / 13.2%; this is a small mean improvement, not a solved cold-scroll
problem. The repeat five-session rich-content/billing phase still measured
65.51 ms mean / 92.98 p95 / 110.68 max; the 32-byte-delta phase measured 20.64 /
31.03 / 64.17 ms. Background content/billing stayed at 2.44 / 7.33 / 9.73 ms with
no whole-workspace publications. Tab readiness ranged 228–321 ms on first mount
and 269–325 ms on return; offscreen settlement remains a separate measurement.

A fresh-process repeat without the preceding concurrency/workspace load
(`review-isolated-scroll`) passed **3/3**:

| Workload | Final repeat |
| --- | --- |
| 300 rich rows, 120 scrolling steps | 23.24 ms mean, 50.47 p95, 140.11 max; first open 307.55 ms |
| Single 88 KiB answer, 120 scrolling steps | 18.77 ms mean, 49.29 p95, 93.73 max; first open 1,520.77 ms |
| Rich streaming, 28 deltas | 30.1 ms mean, 28.75 p50, 38.61 p95, 45.54 p99/max |

The repeated scrolling means remain above the pinned baseline, despite lower
maximums. Do not describe this change as a general scrolling speedup. The large
code-fence, resize and scheduling/continuity changes have specific evidence; the
remaining cold drawing and rich-row work require further profiling and improvement.

## Validation

The renderer-scoped native selection passed **15/15**. It covers the combined real
gateway load, five-session workspace, native code, long Markdown sizing/viewport
selection, two scroll workloads and rich streaming timing. Its supplementary
selection passed **67/67**, covering disclosure ticks, the 2,000-source/500-row
scroll workload, input and geometry/scheduling/resize regressions.

That scrolling run exposed underutilization of the new idle budget: admitting
only one unit per pane per interval left cheap preparation delayed. The scheduler
now rotates after each unit and admits additional ready work until the shared
time budget is spent (with a 32-unit guard for zero-duration work). The global
interval, future deadlines and input/visibility pause remain. A new deterministic
regression covers cheap-unit fairness and future-work waiting. The final 16-case
selection and three-case isolated repeat both passed, as recorded above.

Together these selections contain **83 distinct passing focused cases**, without
skips. Another **12 unchanged checks** reuse the earlier successful Release run:
nine Markdown/source-copy cases, two streaming-parser cases, and the whole-window
page-cache lifetime case. The removed universal-native-code comparison is excluded
from this total. Commands and opt-in fixture setup are in
[Swift-Test-Handoff.md](Swift-Test-Handoff.md#unreleased-2026-09-20-performance-acceptance).

The earlier broader selection passed 86 of 88 cases. Two fixture assumptions were
corrected before the final passes: programmatic CJK marked-text insertion must
send the normal edit notification to update the draft binding; tab-return geometry
comparisons must wait for provisional rows to become exact. The assertions for
draft retention, exact frames, capture and accounting were retained. Intermediate
code-leaf prototypes also exposed missing TextKit ownership and a pasteboard test
using a non-advertised write type; both were corrected and retested before adoption.

No physical 60/120 Hz cadence, external-display move, real trackpad/divider input,
VoiceOver or system-driven Reduce Motion is claimed on this virtual desktop.
The deterministic motion/Reduce Motion and native selection/IME tests do not
replace those checks. No Time Profiler/GPU trace is claimed. Installation/update
rehearsals remain skipped under the owner's standing instruction.

Remaining priorities: rich active-row sizing; cold many-block host construction;
large-table layout; a measured lazy inner surface that preserves exact anchors and
selection without slowing common scrolling; physical-display validation. Keep
the new shared scheduling, exact-geometry and full-source-copy invariants while
working on them.
