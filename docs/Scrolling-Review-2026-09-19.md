# Long-conversation scrolling — 2026-09-19

Released: Bello Agent 0.1.55/build 59.

## Findings

The previous row-height cache avoided repeated text measurements during updates,
but every loaded message still participated in native view traversal, cursor
tracking and window updates during scrolling. A 300-message fixture mounted
13,814 native views, including 1,800 selectable fields. Pure scrolling needed
85.720 ms per step on average, with a 104.682 ms p95, despite zero row remeasurements.

A separate 88 KiB Markdown answer mounted 9,005 native views. Its initial row
geometry failed to settle within the fixture timeout. After scroll warm-up,
scrolling averaged 44.552 ms with a 58.483 ms p95. The timeout-inclusive opening
figure is not a successful loading measurement.

Replacing only the outer scroll container was insufficient. The intermediate
native document retained all attached descendants and performed worse while
scrolling. The final change therefore limits attached views as well as keeping
exact native geometry.

## Changes

An AppKit scroll document owns exact message frames independently of scroll
offset. Retained row hosts preserve local state; only the viewport and a buffer
around it are attached. A selected field's owning row remains attached even when
outside that buffer. Long Markdown bodies use the same approach for individual
rendered blocks, without shortening the underlying answer.

Anchor reporting and read visibility use the current clip-view offset. Native
reflow preserves the first visible row and pixel offset; explicit restored or
prepended-history anchors take priority. Height-only viewport resizing retains
bottom-follow behavior. Distinct sessions get separate row hosts even when a
fork shares message IDs. Layout and scroll settlement remain deferred across
native intrinsic-size notifications.

## Validation

The focused Release XCTest run executed 78 cases: 76 passed and two interactive
pointer cases were explicitly skipped on the inactive remote desktop. Exact row
frames, current viewport/read offsets, prepend/restored anchors, bottom-follow,
session rebinding, offscreen selection, and deferred intrinsic reflow passed.

| Fixture | 0.1.54 mean / p95 | 0.1.55 mean / p95 | Mounted native views, before → after |
| --- | --- | --- | --- |
| 300 rich messages | 85.720 / 104.682 ms | 9.637 / 32.099 ms | 13,814 → 342 |
| One 88 KiB Markdown answer | 44.552 / 58.483 ms | 13.029 / 23.036 ms | 9,005 → 277 |

Each fixture traverses 120 native scroll steps after warm-up, performing layout,
display, and one main-queue turn at each step. Both retained stable clip targets,
document heights and row frames, with zero exact-width row-cache misses. AppKit
requested 64 separate intrinsic-size validations in the 300-row fixture; these
are measured separately and are not presented as zero measurement work. The
large-answer fixture performed zero such row validations. Initial full geometry
for that answer now settles in 1.17 seconds; its old timeout is not a comparable
successful load. Loading all 300 rows still measures their content up front and
took 5.35 seconds in this run, versus 4.75 seconds in the baseline. This change
addresses scrolling rather than claiming faster opening of every history.

The final review also fixed the Copy/Copied control width so feedback cannot
rewrap a heading inside the cached Markdown geometry. Its final four-case
Markdown/scroll rerun passed, and supplies the measurements above. Additional evidence
and signed distribution checks are in the
[0.1.55 acceptance record](validation/Bello-Agent-0.1.55-2026-09-19.md).
The fixtures measure real AppKit layout/display work, not physical display FPS.
Interactive pointer/VoiceOver behavior requires an active desktop and is not
claimed by these in-process checks. Installation/update rehearsals remain
skipped under the owner's standing instruction.

The large-body optimization starts at 32 top-level Markdown blocks. A single
enormous table or nested list remains one rendering block; its internal rows are
not virtualized. Crossing that threshold during a streaming answer changes the
renderer once, so selection inside that still-changing answer can reset at the
boundary. Retained earlier messages and subsequent native-body appends/reflow
have separate selection regressions. Neither fixture establishes performance
for every possible document shape.

Scratch evidence is under
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/scroll-055-20260919`.
