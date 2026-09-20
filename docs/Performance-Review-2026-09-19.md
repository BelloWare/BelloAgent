# Native loading and motion review

Version 0.1.50, reviewed on macOS 14.8 arm64 with Xcode 16.1 / Swift 6.0.2.
The comparison baseline is `bf85f19` (the completed 0.1.49 release).
These are synthetic Release-build observations on this machine, not frame-rate
guarantees or timings from the owner's MacBook.

## Confirmed problems and changes

- Selecting an unchanged chat rebuilt history and replaced retained pages. A
  descriptor-based journal revision now reuses loaded pages, drafts and anchors;
  replacement and same-size in-place writes invalidate the revision. A selection
  revision prevents older asynchronous A→B→A work from overwriting the new view.
- Turn-boundary repair could repeatedly prepend unrelated pages, mounting 300
  rows instead of the 61 needed by the normal fixture. Repair retains the missing
  user turn and its tool evidence, keeps a correct earlier-page cursor, and
  preserves existing follow-bottom or detached reading intent.
- The visible native page can hold 500 rows, but accounting queried only 101.
  Accounting now uses the same bounded row/byte projection as the transcript.
- Chat, composer, side-panel, terminal, report and live sidebar changes inherited
  broad animations. Native text now receives final geometry directly; decorative
  selection, overlays and explicit disclosures keep local feedback. Reduce
  Motion disables those effects and static waiting/caret timers.
- Syntax coloring rebuilt the entire source prefix for every token. A single
  forward Unicode-scalar traversal removes that quadratic work. Unchanged
  Markdown/code/tool projections are equatable; decorative labels no longer
  create selectable AppKit text fields. Prose, code and tables remain selectable.
- A streaming reply could move the bottom during a Latest jump, causing a false
  detach. Explicit jumps now own scrolling until completion, reconcile the new
  bottom, and yield immediately to the user's scrolling.

## Measurement correction

The previous opening benchmark measured a roughly 6 ms empty hosting shell
before the transcript's asynchronous binding installed its rows. It now waits
for actual row geometry and services deferred layout/display between deltas.
Code-color measurements include attributed-string construction, not only token
scanning. The runtime probe labels snapshot application as snapshot application,
not visible paint. Neither benchmark establishes physical display scanout/FPS.

| Same fixture / operation | 0.1.49 baseline | Final 0.1.50 source |
| --- | ---: | ---: |
| Cold attributed coloring, 16 KB Swift | 629.2 ms | 22.0 ms |
| Mount through actual layout, 300 rich rows | 7,280.3 ms | 6,602.4 ms |
| Native views in those 300 rows | 13,209 | 11,109 |
| Forced layout/display per streamed delta, 300 rows | 2,322.5 ms | 2,450.6 ms |
| Edit typing, 40 keystrokes | 1.70 ms/key | 1.25 ms/key |

The 300-row streaming stress test did **not** improve. An intermediate run was
also slower (2,557.1 ms/delta). These observations are retained rather than
replaced by the empty-shell timing or by an unsupported smoothness claim.

With the repaired normal history page, 61 rich rows mount in 1,263.8 ms and
forced streaming layout/display takes 679.7 ms/delta. This is a smaller rendered
page, not a same-size speed comparison. Data-only selection of a 1,001-message
journal took 15.08 ms cold (61 displayed rows) and 1.90 ms on return (121 already
loaded rows retained). A 20,001-message index/page took 162.40 ms; an unchanged
revision check after index-cache eviction took 0.03 ms. Those data timings do
not include native rendering.

## Remaining performance work

Rich retained histories still create many native selectable text views and can
block the main thread during layout. This release improves loading, highlighting
and transition stability; it does not meet a universal 60 fps or large-history
streaming budget. Exact-height eager layout remains because simply substituting
a lazy stack previously destabilized anchors. Future viewport virtualization
needs persistent disclosure state, selection preservation, width/environment
aware height invalidation, and anchor/read-receipt regression coverage first.

The benchmarks are bounded samples, not percentile distributions. No physical
mouse/frame trace, full gallery, production gateway or install/update rehearsal
was run in this pass. Unchanged provider/helper evidence is reused from 0.1.49.

## Regression evidence

Across the focused and final reruns, **195 distinct native tests pass, one
opt-in test is skipped, and none fail**. New coverage includes warm-page reuse,
revision invalidation, cleared drafts, rapid selection, turn repair, accounting
beyond 101 rows, native focus/selection under panel changes, Reduce Motion,
Unicode coloring, selectable Markdown and a growing document during Latest.

The final rendering run contains 30 passing tests. A separate 33-case rerun
fixes legacy test teardown ordering: pending writes finish and both SQLite
owners close before fixture removal. Its log has no vnode-unlinked warnings;
earlier warnings were fixture cleanup defects, not suppressed diagnostics.

Logs and `.xcresult` bundles are in the session scratch directory
`tmp/performance-050-20260919`: `baseline-release`, `focused-final`,
`rendering-final` and `fixture-cleanup`. Initial build-only failures (missing
Release testability and an attempted write to a read-only SDK environment key)
were corrected before these passing runs without weakening assertions.
