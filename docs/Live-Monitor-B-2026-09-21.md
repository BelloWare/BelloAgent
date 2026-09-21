# Live Monitor B

The owner selected concept B and requested light/dark appearance and chart
selection zoom. This is included in [0.1.71](validation/Bello-Agent-0.1.71-2026-09-21.md),
along with fresh conversation loading and history paging.

The native status popup now leads with project scope, 5m / 15m / 1h / 6h / 24h
ranges, current reported output rate, completed-request average rate, output
tokens, reported cost, paired prompt-cache share, and model distribution by
output tokens or cost. Requested aliases (including auto-router) expand to their
observed resolved models. Running session rows open their conversations; errors
remain accessible in a disclosure. Quiet/unread/paused/waiting sessions are
omitted. The gear menu retains detailed Usage, refresh, Settings and Quit.
The fixed footer keeps Open app and Usage report accessible on short screens.

The 480-point panel follows the macOS color scheme. Its charcoal dark surface
and warm light surface share geometry and semantic colors. Model colors retain
their identity across ranking changes. Overflow scrolls inside the fixed header
and footer; it does not expand the popover beyond its screen-height budget.

## Selection and navigation

Drag horizontally within the chart plot to select a time interval. The drag
holds the domain seen at mouse-down, clamps to the plot, accepts reverse drags
and uses the final mouse-up position. Subsecond selections, clicks and vertical
drags do not zoom. A completed selection updates the plot and the retained
totals/model distribution together. No query is made per pointer movement.
The current-rate headline and running rows continue to describe now.

Reset zoom, double-click or Escape returns to the selected preset. Selecting
a time preset also resets zoom. Arrow keys inspect samples; plus zooms the
middle half, minus resets. Hover provides the observed rate or a clear missing
observation. AppKit owns only the plot input surface and passes wheel scrolling
through to the popup.

Retained queries run on the existing bounded read worker. Cancellation and a
query generation prevent an older scope from replacing a newer one. Project and
explicit interval are part of the bounded cache identity. A selected interval
is fixed during subsequent refreshes. A page's model cost/token shares use the
denominators from its own query, including all pages.

## Accounting and chart semantics

- Current TPS sums fresh, validated gateway-reported cumulative-output
  counter intervals, including reported reasoning. Its n/N coverage stays
  visible; no text-byte estimates or summed historical request rates.
- Aggregate live history leaves intervals with incomplete reporting or
  observation gaps empty. An unrelated project's missing counters do not
  suppress a fully observed project when scoped to that project.
- Live history is local to the current app run: up to 900 observed seconds
  plus minute aggregates up to 24 hours. Series and retention are bounded;
  the chart reduces its projection to at most 120 columns × five model bands.
  Older live points are averages of observations, not billed token totals.
- Completed-request averages use reported output divided by the sum of valid
  dispatch-to-completion durations. They include first-token waiting and opaque
  reasoning. A final-only gateway supplies these averages without fabricating
  a live rate; this chart is selected automatically when no live counters exist.
- Retained scope is based on request dispatch-record time, with the same
  project/time filter for totals, rate buckets and model distribution.
  Missing usage/cost remains unavailable. Cache share requires paired
  cache/input observations. Reasoning and cache tokens remain subsets.
- The current Live Monitor replaces the older phase-count graph as the default
  view. Detailed Usage and the full report remain available.

## Verification

Native tests exercise reverse/clamped/frozen-domain brushes, real AppKit
mouse/hover/double-click events, final release coordinates, scoped query
cancellation, range/project SQL filters, model share accounting, bounded history,
gap handling, paired cache coverage and color identity. The rendered popup
fixture contains 15 minutes of three models' reported counters and verifies that
the actual ChartProxy time scale changes when zooming, not merely its caption.
It captures light, dark and zoomed native windows using sample data.

The existing fixture also opens the panel repeatedly with 20 streaming sessions
and 10,000 chat records, checking no transcript materialization, no sidebar
rescans from streaming text, and no hidden history polling/publications.
This is local fixture evidence, not a live-gateway throughput claim or a physical
frame-rate guarantee. Native pointer delivery is exercised against the AppKit
surface directly; no global input or unlocked-desktop assumption is required.

Validation on 2026-09-21: **55 distinct focused native tests pass**. The optimized
run passed 54 tests. After the final visibility/focus and legacy-loader guards,
27 affected UI/controller tests passed with actor data-race checks; the 28
unchanged accounting tests reuse their optimized pass. Both native screenshot
fixtures passed explicitly, including the detailed Usage view.

In the optimized 20-session fixture, warm-open p95 was 22.71 ms, synchronous
state-update/layout p95 0.43 ms and p99 0.45 ms. State-to-display-opportunity
p95 was 20.84 ms and p99 23.40 ms, including a deliberate 16 ms scheduling yield.
Eight warm openings made eight history reads; streaming and subsequent hidden
time added no polling. These numbers do not measure physical presented frames.
The final actor-checked run also passes the same no-rescan/no-hidden-work checks.

The version remains 0.1.70/build 74. No signing/publication, installation or
updater rehearsal was performed for this source-only UI request.
