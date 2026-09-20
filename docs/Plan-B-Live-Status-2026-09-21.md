# Plan B: live status popup

Implements the uploaded **Plan-B-Live-Status-Popup.md**, on top of Plan A at
`5f8576e`. Included in Bello Agent 0.1.69/build 73 with the previously unreleased
[Plan A improvements](Plan-A-Smoothness-2026-09-21.md).

## Presentation

- The existing native status item, either-button activation and persistent
  popover/controller remain. Live and Usage have independent time selections,
  chart selections, disclosures and scroll owners.
- One 428-point-wide layout budget includes the header, tabs and action footer.
  Height is capped at 720 points and the status item's screen's available height
  minus 24 points. Only the body scrolls; Open Bello Agent, Report and Quit remain
  available on short displays.
- Live shows disjoint working-session phases separately from dispatched active
  HTTP requests. Input/output and USD cost show per-field reporting coverage.
  Utilities are identified separately; these totals never become context usage.
- The Activity chart shows event-derived per-phase peaks in one-second buckets
  for 60 seconds or five minutes. Peaks of different phases are not stacked or
  added. Step lines, explicit gaps, selected values and keyboard navigation make
  the aggregation visible. A single observation still has a visible point.
- TPS shows completed-request average points with range/count coverage and
  separately marked observed interim intervals. It never sums last-request
  rates or estimates tokens from visible bytes. Details expose alias, reported
  route, output, duration, TTFT and purpose; Report retains full history.
- Attention has its own section, ahead of working rows, with explicit overflow
  navigation. Paused/error/uncertain states remain actionable. Hovered, focused
  and expanded rows retain their section and relative position until interaction
  ends. Removed rows become nonactionable rather than changing their target.
  Listing unread sessions does not mark them read.
- Usage preserves rolling 24-hour, seven-day and retained scopes, model pages,
  coverage, cache/reasoning, cost diagnostics, outcomes, utilities, retention and
  observation times. Tokens are input plus output; cache and reasoning remain
  subsets. Model routes are compact by default and expand in place.
- Uses existing typography, colors and app-owned motion policy. It does not
  change the chat UI, system Reduce Motion policy, retry/approval behavior or
  provider settings. No new service or remote analytics collection is added.

## Data and scheduling

The helper adds an optional cursor-based numerical monitoring lane to existing
session snapshots. It retains at most 96 phase/request observations per loaded
session and reports a gap when the cursor falls behind. This preserves interim
counters and sub-second phase bursts between native polling opportunities,
without emitting one IPC message for every token or replaying transcript text.
Only checked usage, small checked cost/model projections and timing cross this
boundary; raw request/response bodies and headers do not.

`session.status` previously replaced caller parameters with `includeMessages:
false`, silently ignoring metrics suppression and any cursor. It now forwards
the caller's parameters while still forcing messages off. A wire-level test
checks that a consumed monitoring page is not sent again and that suppressed
metrics remain absent.

Native attempt identity is project/session/runtime epoch/generation/attempt.
Repeated cumulative events replace an observation, not add tokens again.
Terminal enrichment updates the same completion. A generation watermark stops
late duplicates from recounting evicted completion details. Runtime replacement,
sleep, disconnect and clock discontinuities invalidate rate baselines and mark
gaps. Utility monitoring does not mutate conversation replay or context state.

Intervals require two valid cumulative counters for the same attempt and use
the actual monotonic receive-time difference. Negative corrections, invalid or
conflicting counters and nonfinite timing invalidate/rebaseline an interval.
The displayed interval expires after its observed duration, bounded to one to
five seconds. Final-only usage creates one completed-request point using final
reported output divided by dispatch-to-model-completion duration, including
TTFT. An interim value cannot stand in for a missing final output field.

The native numerical store is MainActor-owned rather than introducing an actor
hop and unstructured task for each small counter. It never parses captured
bodies, queries SQL, traverses transcript messages or opens sessions. This is an
explicit implementation choice from the plan's illustrative actor diagram;
native measurements below cover the resulting main-thread work.

One sampler maintains at most 900 one-second aggregate bins while work is active.
At most 1,000 completion details are retained; overflowing details leave their
counts/output/duration in aggregate bins. Active attempts use existing execution
admission rather than a new popup cap. Evicted displays retire their cursors.
There is no per-session idle timer. Visible changes coalesce in a fixed 200 ms
window; the elapsed/chart tick is one second. Hidden ingestion publishes no
SwiftUI snapshots and performs no history polling. The sampler stops when hidden
and idle. Opening immediately publishes already-available local state.

Retained Usage reuses Plan A's bounded read-only worker, cache and query-generation
cancellation. Route pagination does not rerun headline or time-bucket summaries.
The existing ten-second visible refresh ceiling stays separate from live data.
Failure of a retained read cannot blank live observations. Capture persistence,
exact bytes, credentials policy and provider dispatch authorization are unchanged.

## Validation and limits

Deterministic reducer tests cover final-only usage, variable interim intervals,
duplicates, corrections, out-of-order/partial observations, invalid numbers,
sub-second peaks, route evidence, epoch replacement, gaps, utility isolation and
history bounds. Native tests cover hidden publications, repeated visibility,
row stability, short displays, 20 active observations and 10,000 saved chats.
Gateway fixtures exercise real HTTP streaming, tools, cancellation/compaction
and exact capture, independently of rendering.

Final optimized results and publication evidence are recorded in
[0.1.69 acceptance](validation/Bello-Agent-0.1.69-2026-09-21.md).

The measurements are native window layout/display opportunities on the available
virtual Mac, not physical 60/120 Hz scanout measurements. Visual checks include
light/dark/high-contrast and a short panel. Physical multi-display placement,
large-text preferences and an interactive VoiceOver user session are not claimed
as executed hardware acceptance. The app uses public native controls and chart
selection/accessibility labels, without a per-second live announcement region.

**Actual deployed LiteLLM interim-usage cadence remains unverified.** Deterministic
gateway counters prove the app's behavior when counters exist, not that a user's
route supplies them. Terminal-only routes intentionally show phase/activity and
completed-request averages. No production request or credential was needed for
these tests. Plan A's remaining cold giant-answer sizing and rich-row frame-time
limits remain; this popup work does not claim to fix all transcript smoothness.
