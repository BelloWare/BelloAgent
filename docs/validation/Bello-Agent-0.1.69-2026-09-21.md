# Bello Agent 0.1.69/build 73 acceptance — 2026-09-21

**Released and publicly verified 2026-09-20 17:29:00 UTC.**

## Change

The native menu-bar popup now separates current Live observations from retained
Usage. It adds phase charts, checked active-request accounting, honest request
speed samples, attention and expandable stable rows, and one screen-aware layout
including the action footer. Helper snapshots preserve a bounded numerical event
lane across native polling; background status now honors caller parameters.

See [Plan B implementation](../Plan-B-Live-Status-2026-09-21.md) for semantics,
bounds, design choices and limitations. This release also ships the previously
committed [Plan A improvements](../Plan-A-Smoothness-2026-09-21.md), including
batched archive/pin/restore, isolated usage reads and lazy inspector preparation.

## Executed validation

- **59 optimized native tests passed**, zero failures/skips, 11.655 seconds:
  numerical live reducer and native popup, existing metrics/presentation,
  read-worker cancellation/concurrent persistence, context observation,
  concurrency and packaged helper capture integration.
- The real native concurrent fixture ran **20 sessions**, reached **20 HTTP
  requests simultaneously**, executed **20 real file-tool round trips**, and
  preserved **80 exact request/response bodies across 40 attempts**. Every attempt
  also reached the hidden popup accumulator exactly once, with zero hidden UI
  publications. Elapsed 1.444 seconds; main-actor heartbeat maximum gap 8.76 ms.
- **53 focused native Debug tests passed with actor data-race checks**, covering
  popup/metrics/presentation/context/concurrency before the final freshness-label
  refinement. The final refinement has deterministic optimized coverage.
- **22 helper tests passed**, covering monitoring cursors and overflow, compaction
  isolation, request observations, context scope, activity/display observations
  and compaction snapshots.
- **Seven optimized packaged-helper gateway tests passed**, 40.209 seconds:
  interim/final-only monitoring, capture disabled or rejected, owner JSON/SSE
  fixtures, exact bytes, tool replay, compaction, cancellation, errors and distinct
  timing boundaries.
- **17 optimized native popup/presentation tests passed** after the freshness
  refinement and stronger render benchmark, zero failures/skips, 6.409 seconds.
  A timer alone cannot refresh the source observation timestamp. Light, dark
  and high-contrast short-panel JPEGs were captured after native appearance
  updates had rendered and inspected; all footer actions fit.

Scratch evidence: session `tmp/live-popup-b`, `native-release-final.log/.xcresult`,
`native-visuals-a.log/.xcresult`, `helper-c.log`, `gateway-release.log`,
`native-release-measured.log/.xcresult` and `captures-final/`.

## Popup performance fixture

The native window is mounted before measurement, then reopened eight times.
Twenty active counters update with 10,000 saved chats; each of 60 updates yields
a 16 ms run-loop opportunity and forces layout/display again. There are no new
transcript/session materializations or full-chat activity projections, and no
additional UI/history refreshes while hidden. Repeated opens refresh retained
metrics normally (seven reads); the sixty counter updates do not query history.

| Measurement | Optimized result |
|---|---:|
| Warm reopen through next native display opportunity, p95 | 53.86 ms |
| Synchronous counter ingestion/publication and immediate layout, p95 / p99 / max | 0.329 / 0.422 / 0.422 ms |
| State update through subsequent display opportunity, p95 / p99 / max | 20.47 / 23.33 / 23.33 ms |
| Process-footprint delta for 1,000 completion details plus 900 bins | 0.30 MiB (0.66 MiB in the preceding run) |

The display-opportunity measurements include the deliberate 16 ms scheduling
interval. Synchronous update time excludes deferred SwiftUI rendering and is
**not** claimed as total per-frame main-thread cost. These satisfy the proposed
100 ms warm-open and 250 ms delivery targets in this fixture; they do not prove
physical 120 Hz rendering. Memory is a measured process-footprint delta, not a
universal RSS guarantee. Tests also process 2,000 completions while preserving
all 2,000 numerical samples after detail eviction.

The first draft stopwatch allowed only `Task.yield()` between updates and
under-measured work before the host mounted. Its sub-millisecond opening result
is intentionally not used as UI latency evidence.

## Scope of the evidence

Tests use deterministic local gateways, including terminal-only and interim
usage, actual tool input/output checks, streaming and JSON, cancellation and
compaction. They do not claim that deployed LiteLLM routes emit interim counters.
Live unknowns remain unknown; final reported output includes hidden reasoning.

Native measurements use the available virtual Apple M3 Max (10 CPUs/16 GiB),
macOS 14.8 and Xcode 16.1/Swift 6. They measure native layout/display opportunities,
not physical display scanout. Plan A's cold giant-answer sizing and rich-row
frame-time limits still apply. Unchanged Plan A archive, metadata, inspector,
failure and capture-backpressure evidence is reused.

No subagents, installation tests or actual Sparkle install/update rehearsals are
used. Developer ID signing, notarization, packaged smoke and public feed/archive
hash/signature verification remain release gates.

## Signed release and publication

- Shipping source: `6c101522840a5a5ac8dbbc9556ec37e4fceb477b`.
- Website publication: `fb34fa2404446ccbfeb2f906a7bbe8134b7d31c9`.
- Source and website commits were pushed to their respective `main` branches.
- Optimized build, Developer ID signatures, hardened runtime, packaged helper
  offline/catalog smoke, Gatekeeper and app/DMG staples passed.
- Apple accepted app submission `f23709ba-0f57-4c4c-b180-0dfad4d155f4` and DMG
  submission `ff9447b0-b8a8-482c-9e70-afd447ebc6dd`.
- DMG: **8,459,128 bytes (8.07 MiB)**,
  SHA-256 `2a7d429633d5a304278349c19cfee334f4a8cd88055f414ebf0d9ba940a2496f`.
- Build/notary/smoke evidence: shared build cache `release.JnbRQy`; release and
  publication commands: scratch `release.log` and `publish.log`. The final signed
  DMG was also copied to the session outbox.

Cloudflare check **106118013463** succeeded at **2026-09-20 17:28:07 UTC**.
Public product page and download link, byte-identical canonical/legacy update
feeds, and the downloaded archive's SHA-256 and Ed25519 signature passed at
**2026-09-20 17:29:00 UTC**. Evidence is in `public-product.html`,
`public-verification.log` and `public-0.1.69/`. Verification waited for the actual
deployment instead of treating the website Git push as public availability.
