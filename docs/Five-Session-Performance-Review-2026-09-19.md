# Five-session responsiveness review — 2026-09-19

Released: Bello Agent 0.1.57/build 61. Baseline: verified 0.1.56/build 60 (`bb114ef`, release documentation `1a1ffcf`).

## What was making five sessions expensive

Concurrent requests already run independently, but concurrency alone does not keep the main thread responsive. Two presentation paths repeated work unrelated to the selected chat:

- A retained billing total changed the published `WorkspaceModel.chatStats` dictionary. Each background total invalidated the whole window and sidebar, including the selected transcript. The five-session fixture measured 24 global notifications during 30 background update frames.
- Helper status reads constructed and encoded an unseen transcript before removing it from a status response. Repeated visible reads also rebuilt an unchanged projection. Large retained histories amplified this work on the session actors and their request pipeline.

The native transcript separately reconciled unchanged snapshots and traversed detached row hierarchies during layout. Switching to a loaded conversation rebuilt its exact native row measurements. Sampling confirms that native sizing, rather than Markdown parsing, dominates the latter delay: 1,963 of 3,206 sampled main-thread stacks during tab switching passed through `TranscriptNativeDocument.layoutRows`; most continued into the hosting view's fitting/layout methods. These inclusive sample counts are not additive percentages.

The first refresh hypothesis was rejected: `displays` was a plain dictionary, not `@Published`, and a five-session coalescing test already produced zero global notifications. The fix targets measured billing invalidation instead.

## Changes

Retained accounting has one stable observable row per session. A cost update notifies that row instead of the whole window; loaded rows continue observing their own footer. Identical totals do not publish. Empty retained totals clear prior cost/token values. Display insertion, removal or replacement intentionally updates the row's retained/live branch, while reuse of the same display identity stays local. Existing accounting revisions continue rejecting older asynchronous results.

Helper status responses skip hidden transcript construction. Visible projection caches reuse completed rows and invalidate the changed streaming tail, with unchanged byte/page bounds and fresh projection identities after runtime replacement. The native document skips unchanged content reconciliation and avoids laying out detached row trees when the buffered viewport is unchanged.

A bounded, process-local geometry cache retains verified sizes and immutable row content, never hidden views or animations. It admits up to 1,000 entries with a 16 MiB payload budget and a 256 KiB per-entry limit. Session identity, full content, freshness, rendering environment, exact width and backing scale must match. Live output and rows with tool/reasoning/compaction disclosures remain uncached. A changed answer or width gets fresh native layout, and rows entering the viewport confirm their actual geometry. The budget accounts for retained payload rather than claiming an exact process RSS bound.

Long Markdown replies keep their existing per-view block measurements and viewport mounting. An experimental cache shared block-prefix sizes across reconstructed views, but repeated scrolling measurements regressed. That experiment and its four executed cache-only tests were removed before release; the verified transcript-row cache above remains.

A separate concurrency audit found that a reply accepted immediately before helper loss could overwrite the interruption state when its continuation resumed. Refresh now checks the host connection, display identity and session binding after suspensions. A new-connection refresh requested during old work's unwind is preserved. Failed/cancelled partial output also stops sharing its ID with a streaming placeholder before awaiting durable output-link capture.

## Comparable helper measurements

The same synthetic fixture opens five retained sessions containing 80 rows each, with 16,384 bytes of text per row. It uses the real helper RPC transport, no gateway, and records the median of three runs. Each run batches five sessions together.

| Workload | 0.1.56 | Candidate | Reduction |
| --- | ---: | ---: | ---: |
| 100 background status reads | 1,941.27 ms | 39.13 ms | 98.0% |
| 25 unchanged visible snapshot reads | 545.48 ms | 32.97 ms | 94.0% |

The released baseline helper SHA-256 is `80ff200acb72c6d013044f8cf8c25c0a6f984b9b8ee3e04ae1aa4d739fe596a6`. The measured candidate helper is `b9503bbe84d27365a76fd602022c2c5e3cdb6ecd4328c4cf6071d9271899766c`. Preserve or update that attribution if the helper changes before release.

## Whole native workspace measurements

Release configuration, Xcode 16.1, arm64 macOS 14.8. One actual `WorkspaceView` is mounted with five loaded sessions, each containing 61 rich history messages and its own unsent draft. The visible answer grows through 30 rich Markdown updates to exactly 11,808 UTF-8 bytes. Background billing uses the real `publishChatStats` path every fifth frame. Each frame forces native layout/display, yields a main-queue turn, then lays out/displays again; its 16 ms delivery pacing is excluded from reported frame-work time. A separate 5 ms heartbeat measures main-thread scheduling gaps.

| Workload | Baseline mean | Baseline p95 | Candidate mean | Candidate p95 |
| --- | ---: | ---: | ---: | ---: |
| Four background sessions: status coalescing | 0.90 ms | 2.52 ms | 0.94 ms | 1.63 ms |
| Four background sessions: content and billing | 12.51 ms | 58.23 ms | 7.24 ms | 31.29 ms |
| Five sessions: rich content and billing | 66.12 ms | 94.15 ms | 54.46 ms | 85.52 ms |

The baseline background content/billing phase triggered six reconciliations of the unchanged selected transcript. The foreground phase traversed 1,860 retained row trees over 30 frames. Its main-queue latency averaged 23.51 ms and heartbeat maximum was 115.88 ms.

First complete workspace layout took 1,622.78 ms. Loaded-data tab switches took 1,246.48 / 1,442.65 / 1,391.05 / 1,459.55 ms for the four first native mounts; returning to the initially mounted session took 1,421.23 ms. These first four pages had warm data but had never been natively mounted. The post-change fixture additionally records a second complete five-tab cycle for previously mounted returns; that added cycle has no original baseline and must not be presented as one. It preserves the original readiness endpoint, then yields a main-queue turn and drains deferred mounted-row height validation before recording geometry or switching again. This additional settlement time is reported separately and must be included when describing fully settled switching cost.

The shipping run produced zero global workspace notifications in every phase.
Background-only updates did not reconcile, traverse or lay out the selected
transcript. Background content/billing work averaged 42.1% less than the original
baseline; the foreground phase traversed 49 retained rows instead of 1,860.
Five genuinely idle sessions averaged 0.36 ms per measurement, with no native
transcript work or global notifications.

Initial workspace layout took 1,422.39 ms. The four first native mounts took
1,343.88–1,385.48 ms including their separately measured deferred settlement.
Returning to the initially mounted session took 629.11 ms to the original
readiness endpoint, plus 68.76 ms for deferred validation: 697.88 ms combined.
The directly comparable readiness figure decreased 55.7%; the original baseline
did not measure a separate fully settled endpoint. The second five-tab cycle
took 516.77–588.44 ms to readiness and another 45.85–87.37 ms to settle,
562.62–675.81 ms combined. Each return kept exact row geometry, 62 retained rows,
one mounted row, one conversation and composer, and 356 native views.

Foreground rich streaming still has substantial layout spikes: 54.46 ms mean,
85.52 ms p95 and 124.57 ms maximum, with a 119.07 ms maximum heartbeat gap. The
separate 32-byte/50-ms-pacing phase averaged 23.04 ms, with 56.56 ms p95 and
93.25 ms maximum. Those results do not establish a steady frame-rate target or
uniformly smooth foreground rendering.

The final 120-step scrolling checks retained exact geometry without new row
measurements. Three hundred rich rows averaged 10.09 ms per step, 30.16 ms p95,
with a 5,565.10 ms cold complete-geometry setup. One 88 KB Markdown answer
averaged 15.39 ms, 32.09 ms p95 and 78.61 ms maximum, with 1,246.90 ms cold setup.
Its synchronous scrolling work was 7.26 ms, close to the pre-experiment
candidate's 7.14 ms (14.40 ms total mean). This restores the earlier renderer's
cost; it is not evidence of a substantial new scrolling improvement. Cold
layout and rich foreground work remain areas for further improvement.

## Validation and limits

The original two-test native reproduction passed. New structural regressions require no whole-workspace publication from status/content/billing arrivals, no selected-transcript reconciliation for background-only updates, and preserved composer identity, selection, draft, exact row geometry and a single mounted conversation. Five accounting cache tests cover independent observers, unchanged values, late row mounting, expired totals, and intentional display topology changes. The second tab cycle checks exact retained geometry and reports mounted host/view counts.

An added small-delta phase appends 32 UTF-8 bytes per update over the existing rich answer, with a 50 ms pacing delay between measured updates; this is a text-delivery workload, not a real token-rate or gateway measurement. Its first run failed because its size assertion overestimated the unchanged answer and because the fixture counted a deferred composer-focus callback as streaming work. It now asserts the exact original payload and finishes navigation before measurement; the zero-workspace-publication requirement is unchanged. The application also skips assigning the already-focused session again. That failed run's small-delta timings are provisional and are not used for a before/after performance claim.

The first Markdown block-cache candidate was rejected: `native-markdown-final`
crashed in both rich foreground streaming and the existing append/resize
regression. Both stacks reached a second `fittingSize` call after forced layout
inside the representable's sizing callback, causing SwiftUI's “setting value
during update” precondition. Its 88 KB cold/scroll timings also regressed. That
candidate was not released, and its interrupted five-session run is not passing
acceptance evidence. Moving confirmation to a later main-queue turn fixed both
crashes, but the subsequent candidates still increased the 88 KB scrolling
fixture's mean from 14.40 ms to 18.64–19.23 ms. Removing an offscreen frame
assignment did not recover that cost. The complete experimental Markdown cache
was therefore removed, preserving the existing per-view Markdown rendering.
Final acceptance verifies that restored renderer alongside the shipped
row-cache, notification-isolation and helper improvements.

The final shipping-source selection passed all 23 tests: the two whole-workspace
fixtures, two original Markdown viewport regressions, two scrolling fixtures and
17 workspace tests. The earlier successful selections ran 87 tests (85 passed,
two skipped) and 84 tests (82 passed, two skipped). After deduplication and
excluding four removed experimental cache tests, acceptance covers **118 unique
native passes and two interactive skips**. The skipped methods are
`testDisabledParentKeepsNestedRetryUnavailableUntilReenabled` and
`testDisclosureChangesTheExactHeightWithoutChangingRowContentOrWidth`; they
require an interactive desktop. Failed or interrupted runs are not counted as
passing evidence. `final-native-summary.json` records each method and source log.

The helper selection passed 41 tests, including seven new projection/cancellation regressions. All three real-helper 20-session gateway tests passed: one project with delayed capture acknowledgments, four projects, and mixed cancellation/error/follow-up isolation. Both tool fixtures observed 20 overlapping HTTP requests, 20 tool round trips, 660 text events, and 80 exact captured bodies. These are actual overlap barriers, not sequential fast fake responses.

Together, the relevant native, helper and real-gateway checks contain **162
distinct passing tests**, plus the two explicitly skipped native interactive
checks. Repeated runs do not inflate this total.

Measurements are native CPU/layout/display opportunities, not physical screen refresh or trackpad frame rates. Only the original unsampled run is baseline timing evidence; the later `sample` replay is attribution only. The remote desktop is inactive, so physical pointer/trackpad and VoiceOver smoothness remain unverified. The synthetic fixture excludes user history, real credentials and remote gateway behavior. AppKit layout stays on the main thread; helper networking, projection work and existing bounded file workers remain separate concurrent execution paths. No claim of one dedicated thread per session is made.

Fresh-install and actual Sparkle update/relaunch rehearsals remain skipped under the owner's standing instruction. Final signing, notarization and public artifact/feed verification are recorded separately.

Scratch evidence: `tmp/perf-057-20260919/` contains `five-session-baseline.log`,
`host-status-before.json`, `host-status-after.json`, `native-after-actor.log`,
`native-markdown-corrected.log`, `native-shipping-final.log`, their result bundles,
and `final-native-summary.json`. `profile-notes.md`, `rich-tail.sample.txt`,
`warm-switch.sample.txt` and `long-scroll-profile-notes.md` are attribution only.
`markdown-cache-crash-notes.md` records the rejected candidate's crash source.
