# Native selection and responsiveness review — 2026-09-19

Released: Bello Agent 0.1.53/build 57. Baseline: `b29adbc` (the verified 0.1.52 release and its documentation).

## Findings

The remaining slow transcript path is native layout, not the number of concurrent
HTTP requests. The original eager SwiftUI stack remeasures retained selectable
text during a tail update. Equatable rows prevent unnecessary body reconstruction,
but do not isolate the text layout beneath those rows.

Two additional accounting paths amplified streaming work: each status snapshot
could query retained accounting again after 250 ms, and a capture link packet
invalidated every loaded chat in its project. Those reads share the archive actor
with durable capture delivery. Neither operation is necessary for another text delta.

## Changes

- App-owned choice panels replace native selection menus for connection, reasoning,
  catalog-source, generic settings and report filters. Arrow keys move focus without
  saving; Return/click chooses; Escape dismisses. Disabled choices remain visible.
  Window chrome disallows the system tab strip.
- Transcript rows keep their native text and local disclosure state behind an exact
  measured layout boundary. Content, wrapping width and rendering environment changes
  invalidate the row; unrelated streamed text does not require a fresh measurement.
- Accounting invalidation follows capture metadata and changes in visible attribution
  targets. Link ownership uses indexed archive lookups. Inherited visible replies
  follow retained output links when late billing metadata omits message IDs.

## Comparable native rendering measurements

Release configuration, Xcode 16.1, arm64 macOS 14.8. The fixture waits for actual
row geometry, then forces native layout/display on each streamed delta. This is
an end-to-end layout stress measurement, not a claim about display frame rate.

| Fixture | 0.1.52 first layout | 0.1.53 first layout | 0.1.52 per streamed delta | 0.1.53 per streamed delta |
| --- | ---: | ---: | ---: | ---: |
| 61 rich rows | 1,409.6 ms | 881.6 ms | 699.7 ms | 102.3 ms |
| 300 rich rows | 6,968.2 ms | 4,359.7 ms | 2,525.9 ms | 208.7 ms |

Opening is approximately **37% faster** in both fixtures. Per-delta work drops
**85.4%** on the normal loaded page and **91.7%** on the 300-row stress fixture,
over 37 updates to an 11 KB answer. Native view counts increase (2,262 to 2,597
on the normal page): isolating layout, not simply removing views, produces this
improvement. These are single comparable fixture runs, not population statistics.

The cache retains a small set of exact width measurements because SwiftUI probes
both the ideal page width and the viewport width beside the scrollbar. A cache
with only one width repeatedly evicted the other measurement. The actual drawing
width is synchronized to the row's bounds, independently of speculative probes.
A regression verifies zero fresh measurements for retained rows during four
streaming updates, alongside preserved text selection, scroll position, resize
reflow and insertion of earlier history.

The baseline 300-row transcript contains 11,109 native views, including 1,500
selectable fields and 1,500 selection overlays. The smaller loaded page improves
opening cost but does not by itself fix layout amplification. The rich-history
stress case still takes seconds to open; these improvements are not a claim of
uniform 60 fps rendering or zero remaining performance work.

## Validation and boundaries

Final focused evidence contains **191 distinct native passes and four explicit
interactive-desktop skips**, with no unresolved failure in the required checks.
The selector regressions caught a real initial-focus error: Return could select
the last row, while default-focus priority could undo arrow navigation. One list
now owns keyboard focus and tracks its highlighted row separately from the saved
choice. Native key events verify initial Return, navigation, disabled choices,
commit/cancel, refreshed lists and empty states. Light/dark rendered text and
saved-checkmark captures were also inspected.

An independent review caught the need to pass the disabled environment through
the new hosting boundary and the helper's separate output-link packets. Archive
and accounting regressions verify retained ownership and late metadata. The
native/helper/gateway fixture also completed 20 concurrent sessions and 20 tool
round trips, retaining 80 exact request/response bodies. Its maximum MainActor
heartbeat gap was 9.14 ms, a scheduling measurement rather than a frame-rate test.

This remote desktop cannot activate even a plain SwiftUI Button with pointer
input. Pointer selection, actual popover activation/dismissal, disclosure animation
containment and disabled/re-enabled Retry interaction remain four opt-in checks
for an interactive desktop. Their assertions remain in the suite. No pointer or
VoiceOver coverage is claimed; in-process SwiftUI accessibility children were
unavailable. Do not interpret the preserved failed input-harness attempts as
successful tests or the skipped checks as passes.

Unchanged helper/provider/worker coverage is reused from 0.1.52; no fresh-install
or Sparkle update rehearsal is required by the standing owner workflow. Signed
release and public publication checks remain required. The release record tracks
their outcome separately from these source and rendering checks.

Scratch evidence lives under
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/perf-053-20260919`.
