# AppKit integration for 0.1.120 — 2026-10-05

Development validation only. 0.1.120 has not been released.

## Integrated work

- Transcript: `cab40859` (the saved combined transcript branch), merged into
  `dev/next` as `678fbfc6`, preserving the handover commit and existing history.
  The tested app and test sources match the merge; two trailing blank lines
  were removed. The terminal cursor fix is included.
- Dashboard: `e97ec9e5`, merged after the transcript. The sole merge conflict
  was the generated Xcode project, resolved with `xcodegen generate`.
  Dashboard pages, live monitor, menu-bar panel, chart engine and cost-limit
  controls now use AppKit. One trailing blank line in a test reference was
  removed.
- Metrics footer: completed the saved `d23ba5d4` work on `dev/appkit-dash-wip`.
  The conversation pane now uses the AppKit footer directly, including its
  statistic pills, context ring, capture control, notice and running clock.
  The footer and statistics presentation models no longer import SwiftUI.
  The remaining Inspector consumers have subsequently been ported, and legacy
  design components now live only in the parity test target.

## Checks performed

macOS, arm64, Xcode 16.1, Debug; unsigned `build-for-testing` followed by
`test-without-building`, with parallel testing disabled. Each serial parity
class ran alone. The helper bundle was built and staged before the app build.

| Run | Cases | Optional skips | Failures |
| --- | ---: | ---: | ---: |
| Transcript integration and terminal cursor | 126 | 5 | 0 |
| Dashboard controls, navigation, models and chart ticks | 141 | 1 | 0 |
| PiChartParityTests | 6 | 0 | 0 |
| MonitorParityTests | 3 | 0 | 0 |
| CostLimitParityTests | 3 | 0 | 0 |
| MetricsFooterControlTests | 4 | 0 | 0 |
| MetricsFooterParityTests (44 light/dark comparisons) | 2 | 0 | 0 |
| SessionTimingTests | 25 | 0 | 0 |
| StatPillRollTests | 2 | 0 | 0 |
| AutomaticContextTests | 11 | 0 | 0 |
| WorkspaceRedrawTests | 1 | 0 | 0 |
| ConversationPaneRetentionTests | 6 | 0 | 0 |
| PiKitControlTests | 38 | 0 | 0 |
| ConversationPaneTests | 80 | 0 | 0 |
| ShellParityTests | 16 | 0 | 0 |

Final selected results total 464 cases, with six existing optional skips
and no remaining failures. This is focused development validation, not the
complete release gate.

Transcript coverage: native-renderer source guard, message kinds, row and
pane behavior, tool-card behavior, row/turn/work visual parity, and real-zsh
cursor alignment. The five skips are existing opt-in calibration/probe cases.

Dashboard coverage: background requests, report navigation, menu-bar usage
and presentation, live monitor and popup, lazy AppKit controls, session-series
builders, cost-limit behavior and chart ticks. The skip is an opt-in menu-bar
capture. The separate parity classes compare light and dark appearances with
the original SwiftUI/Swift Charts references at their existing thresholds.

Footer coverage: idle and running states at 1600, 1200, 900, 520 and 300
points; notices, preparation, unavailable capture and side footers at 1600,
900, 520 and 300 points, each in light and dark appearance. The frozen footer
reference comes from `e97ec9e5`. Height agreement is held to 0.5 points;
pixel thresholds remain 1.2% overall and 0.2% for strong differences.

Four added control regressions were verified to fail before their fixes:
the narrow badge kept its caption, resizing measured the wrong usage face
and rolled between forms, configuration changes missed an automatic context
recount, and disabling a pane recreated its footer and widened the reserved
capture slot by 30 points. They now pass. The native layout also preserves
context-slot wrapping, trailing notice alignment and clipping at the footer
edge. The prior narrow-pane capture/cost overlap is retained.

The migrated timing tests still cover stable row geometry, independent
press-target sizes and live clock/usage readings through screen OCR. Their
AppKit test wrapper now measures without invalidating layout; updates and
layout happen before geometry is read. Native stat-pill tests retain the
scope-switch contract and check that a roll avoids drawing the entire pill
every frame. Retention and redraw checks passed.
The conversation-pane suite also passed with the footer mounted alongside
the composer, queue, terminal and side panes. The existing shell parity
class passed at its unchanged thresholds.

Local evidence is under `~/Library/Caches/BelloAgentNext/logs/`:
`transcript-integration.log`, `dashboard-build.log`, `dashboard-functional.log`,
`PiChartParityTests.log`, `MonitorParityTests.log`, `CostLimitParityTests.log`.
Dashboard parity captures are in `appkit-integration-gallery/` beside `logs/`.
Footer captures are in `footer-gallery/`. Additional logs:
`footer-final-build.log`, `footer-before-tests.log`,
`footer-lifecycle-before.log`, `MetricsFooterControlTests.log`,
`footer-parity.log`, `SessionTimingTests.log`, `StatPillRollTests.log` and
`footer-functional.log`. The last functional batch's timing geometry checks
were corrected and rerun in `SessionTimingTests.log`; the other classes in
that batch passed. Conversation and shell integration logs use their test
class names.

## Complete production integration

The session Inspector, retained payload/resource views and session-statistics
workstreams are merged into `dev/next` with their original commits preserved.
The application uses an `NSApplicationDelegate`, cached native workspace and
Settings window controllers, native menus and direct transcript/composer views.
Production sources in `PiApp` and `bello-views` contain no SwiftUI imports or
hosting views; `NativeApplicationTests` enforce this. Frozen references remain
only in `PiAppTests/SwiftUIReference` for comparison with the former UI.

Shared component corrections preserve measured baselines, wrapped text, scaled
values, section subtitles, button fonts, clipping and inherited motion. Field
blur no longer submits a form. Native custom buttons explicitly expose their
role and accessibility press action; selectable resource rows expose names,
selection, descriptions and paths. Window tests exercise actual key events,
minimize/close/Dock reopen, and reuse of the Settings editor.

The whole-change read-only Codex review found two regressions, both corrected:
retained Inspector views now switch their read source when a live capture is
archived, and resource rows expose their spoken names. Archive transition tests
cover request, response and event bodies with helper access unavailable. Read
scopes cancel when their view detaches, and delayed reads do not retain it.
Statistics ledger rows and accessibility children keep their identities across
updates and reject removed entries. Native lists preserve the preferred scroller
style and reserve a legacy gutter only when their content overflows.

Focused integration results include 10 Inspector controls and 24 Inspector parity
comparisons, 5 statistics controls and 46 statistics parity comparisons,
38 shared PiKit controls, 8 native application cases and 9 window-presentation
cases, all passing. Payload and complete gallery results are recorded after
their final viewport corrections. These are development checks; they do not
substitute for the complete release gate or Release soak.

## Whole-gallery corrections and additional checks

The first complete native gallery and the immutable 0.1.119 gallery each
contain 192 captures. Every pair was reviewed. That review identified measured
corrections to standalone Settings/Inspector title-bar space, the workspace
minimum height, empty conversation-search row height, narrow composer wrapping,
search reader insets, raw-search controls, request metrics, dashboard truncation
and routing alias image slots. The workstream commits remain in the integration
history. A final capture of the corrected candidate is still required.

The second whole-change read-only review found that selectable rows containing
`ShellText` did not inherit their spoken names. Shared text extraction and
explicit resource/compaction/title labels now cover that case. Real accessibility
press/selection tests exercise the mounted controls.

Additional passing checks, including passing classes within coordinated runs
whose other classes were still under repair:

| Checks | Cases | Result |
| --- | ---: | --- |
| Native application, including saved-display startup ordering | 9 | Pass |
| Settings rows, including exact field and cost-choice leading edges at three widths | 5 | Pass |
| Composer controls, including narrow-pane wrapping and retained caret | 5 | Pass |
| Payload controls, including a 500 KB reader that lays out only the chosen match | 21 | Pass |
| Native sheet lifecycle and initial fitted bounds | 11 | Pass |
| Background header/headline controls and frozen layout parity | 4 | Pass |
| Routing alias controls and frozen layout parity | 2 | Pass |
| Report headers, request rows, resolved tables and complete scroll documents | 3 | Pass |
| Packaged helper title suggestions and mounted accessibility press | 1 | Pass |

Report geometry agrees exactly with the frozen original: 29-point headers,
43/44/58-point request rows, 426/516-point resolved tables and 1,297-point
outer documents at 620, 1,139 and 1,440 points wide. No speculative document
padding correction was made.

The new sheet-bounds regression failed before its correction: content first
joined its window at 0×0 rather than its fitted 420×260 points. Sizing the host
and new window before attachment fixes that transition; all 11 sheet tests pass
and their invalid-view-geometry warnings are gone. The production transcript
also waits for the vault to load before applying saved display preferences.
The gallery explicitly restores its own transcript display state after opening
the separate Settings window, which uses a different fixture model.

Evidence: `native-all-gallery-repairs-check.log`,
`native-payload-settings-final-check.log`,
`native-report-inspector-sheet-diagnostics.log`,
`native-sheet-payload-ready-check.log` and the per-screen
`gallery-{root,session,payloads,statistics}-review.txt` records under the same
cache log directory. Failed asynchronous captures were diagnosed and retained;
mounted-fixture readiness and real match navigation replace pre-mount timing
assumptions. Existing parity thresholds remain unchanged.

The final shared-control/Settings/search run executes 23 tests (one existing
opt-in hover-gallery case skipped) with no failures. The complete-body search
bar, previous/next buttons and reader match the original measured frames
within 0.25 points in both appearances and for matching/empty results. An
image-only ghost chevron keeps the original 8.5-point logical height and
half-point ink offset; other symbols and text labels keep their existing
drawing. The shared PiKit parity class executes 21 cases with no failures
and the one opt-in skip, preserving its existing limits.

The complete Settings document measures 1,721 points in both the native page
and the original frozen lazy page after every group has been realized. All
six group frames agree exactly, including the final 130-point editor, and the
resolved scrollbar proportion agrees. The original lazy page initially
estimates 2,378 points and estimates 2,068 after returning to the top; the
native document keeps its measured 1,721-point height. The regression compares
the native page strictly against the original realized geometry. An eager
test-only reference remains a supplemental check; it can round one point
differently. Earlier failed assumptions about lazy estimates and that eager
reference are retained in the logs. No production padding or fake document
height was added. Evidence: `native-final-symbol-settings-focused.log`.

## First complete gate and native test repairs

The complete gate ran alone at shipping source `cc34d8f8` from 21:37:25 to
22:17:54 SGT on October 5. Builds, the 192-capture gallery, helper cost and
remaining helper/views/wire/concurrent/acceptance/Python checks passed. The
native serial lane executed 608 cases (23 optional skips) with three failing
methods; the parallel lane reported 1,939 passes, four failing methods and
34 skips. This first gate failed; its logs are retained.

Six failures were stale native-test assumptions: an expired retained-body
fixture, the intentionally bare XCTest application's Settings menu, two
helpers looking for the former SwiftUI stat-pill class, the error strip's
old private view name, and dynamic NSColor provider identity. The repaired
tests keep their behavioral, lifetime, geometry and bounded-I/O assertions.
Syntax colors are compared as resolved sRGB RGBA in both appearances at
`1e-6`; no screenshot or functional tolerance was relaxed. The existing
short-page offer failure did not reproduce in the focused run. A separate
viewport-only regression proves a real missing recheck: the initial 900-point
document settles correctly at clip origin 300, an 800-point viewport settles
at 100 with the same rows and live tail, but the earlier offer stays absent.
`native-viewport-regression-before.log` retains this failing counterfactual.
The correction rechecks the existing guarded earlier-edge policy only after
the resize's deferred following/restoration placement settles. The new
viewport regression then passes, together with chat-open placement, history
edge/timing/edit and streamed-reply checks. That 37-case run found one
intermittent reading-test failure: no paint occurred when every appended
character was below the viewport. The earlier and repaired binaries both
pass the class on their own. The fixture now explicitly invalidates the
visible text for a real paint and retains its source-anchor, selection and
focus assertions; all six reading tests pass.

All seven affected classes then ran together serially: **40 executed, two
existing optional skips, no failures**, in 148.7 seconds. This covers
`InspectorFrameTests`, `LayoutCycleTests`, `StreamedReplyEndTests`,
`SessionStatsPopoverTests`, `FileSyntaxTests`, `SmoothReadingPositionTests`
and `CostLimitTests`. Evidence:
`logs/native-gate-repairs-build.log`, `logs/native-gate-repairs-tests.log`
and `first-gate-cc34-verify-logs` under
`/Users/admin/Library/Caches/BelloAgentNext`. The original 192 captures are
preserved in `first-gate-cc34-verify-gallery` before the gate rerun. A subsequent
16-case run also passes all nine syntax cases against independently frozen
baseline RGBA values in both appearances, the six reading cases and the
complete-body search comparison. Evidence:
`logs/native-raw-reader-before-and-reading.log` and
`logs/native-overview-document-geometry.log` (the latter still records the
new Overview comparison's failures, not a passing release check).

Every final gallery pair from this gate was viewed: root 82, Inspector
session 24, payloads/files 54 and statistics 32, totaling 192. The review
records are `logs/gallery-{root,session,payloads,statistics}-final-review.txt`.
The review still requires a measured narrow Git layout correction and the
final recapture. The narrow main-window pair was subsequently recaptured at
the shipped 920×628 minimum and viewed in both appearances; its conversation,
queue, composer and footer now align. Initial lazy-scroll thumb estimates
are recorded separately from settled geometry; no estimated padding was added.
The gallery log contains no invalid-view-geometry or unsatisfiable-constraint
warnings.

## Mounted search and complete document measurements

The real Inspector sequence reproduced a ten-point raw-search shift in both
appearances: a 478.5-point viewport moved to origin 10 although its first match
was fully visible at glyph y351 plus the ten-point text origin. A component
fixture alone did not reproduce it. A new real-window regression retains the
synthetic request and follows expanded-text selection/focus, Response, then
Raw and the README query. It exposes the same failure. The initial visible-
match guard was insufficient and its failed run is retained.

A temporary trace showed origin 0 throughout text assignment, selection and
attachment; the first zero-to-874-point width adjustment grew the document
from 1,770 to 1,959 points and moved the clip to 10 before the first layout.
The final correction saves the pre-update origin with the pending match and
restores it only when the match fits the final viewport at that origin.
It uses no inset-derived offset and retains AppKit's offscreen navigation.
The mounted regression now passes at origin 0 with its ten-point header
inset, together with all 22 payload controls including nonzero-viewport,
distant-match and bounded noncontiguous-layout checks. The temporary
production trace was removed. Evidence: `native-raw-gallery-diagnostics.log`,
`native-raw-trace-conversation.log`, `native-search-flow-overview-check.log`
and `native-final-viewports-check.log` in the cache log directory.

Conversation search measures all 13 original previews, including empty text,
the 240-byte boundary and trailing newline. Every realized row frame agrees
exactly, as do the 726-point document, 837×332.5 clip, 393.5 bottom origin and
0.4579889807 scrollbar proportion. The original lazy document initially
estimates 648 points and 0.51311728395; after visiting every row it agrees with
the native document at both the bottom and returned top. This explains the
initial thumb difference without changing production geometry.

The complete Overview's original row heights and gaps also agree. Its lazy
ledger can retain an internally inconsistent height estimate even when all
rows are visible. The original children in a resolved stack measure
3,270.5738525 points versus native 3,270.5, within the unchanged 0.25-point
geometry bound. Independent original cards at the exact native proposal
agree at 431 and 874 points. The full-page SwiftUI proposal differs by one
CGFloat ulp and rounds some widths up one backing pixel; the diagnostic
retains those raw frames, derives that rounding bound from backing scale,
and strictly compares every child at the same exact proposal. All positions,
heights, complete document and scrollbar checks remain strict and pass.
Evidence: `native-raw-trace-conversation.log` and
`native-final-viewports-check.log`. The latter has ten failures confined to
the two new Git comparisons; it is not recorded as a passing release gate.

The read-only whole-change follow-up reports no actionable source/test
findings through `d052ddc14549` and the inspected working repairs. It advises
finishing the remaining geometry checks, freezing the source, and running
the quiet full gate, final gallery, comparable Release measurements and
actual 3,600-second soak. Evidence: `native-release-delta-review.txt`.

## Narrow Git pane measurements

The real 310-point Changes pane's original toolbar has a 357.5-point minimum
from its folder symbol and fixed controls. It overflows symmetrically at
x −23.75 while the header, history and detail retain their pane allocation.
The correction derives that minimum from the actual layout items and centers
only the toolbar. Both standalone and Changes-from-Blame comparisons now
pass, including every visible child's unchanged 0.5-point frame bound.
Evidence: `native-git-toolbar-after-tests.log` (two cases, no failures).

A separate original RightPane topology probe retains the opacity-zero kept
side beneath Changes. It reproduces the full gallery's history discrepancy:
the old header/history/detail receive 336 points at x −13, while the native
body receives 310 at x 0. Filter widths are 320 versus 294, and first-row
widths are 305 versus 279. This establishes the hidden side's control minimum
as the cause; no history-row translation or fixed padding is justified.
Evidence: `native-git-kept-side-before-tests.log`, with saved frames/captures
under `git-narrow-before` in the cache.

The released composer's default eight-point spacer minimum and empty idle
run-control row's four-point outer gap account for the missing twelve points
in the native side's 324-point minimum. Restoring those real layout children
produces 336 points. The header also publishes its fixed badge/action minimum
and preserves the original fixed-size non-kept title; the kept title can
truncate. Side/RightPane size notifications keep the covered body's proposal
current, while the outer pane/strip and the composer's trial proposal retain
310 points. All visible child frames now agree with the original, including
history x −13/width 336 and first-row x −5/width 305. Running-to-idle changes,
a 600-point wider pane and side removal also pass without rebuilding the tab.
The three narrow probes and affected ConversationPane, ShellComposer,
ComposerBarLayout, Git width/layout classes pass together: **102 cases, no
failures**, in 81.5 seconds. Evidence: `native-right-pane-after-tests.log`
and `git-narrow-after` saved frames/captures.

The read-only review through `5cdff8e8` reports no findings in the correct
saved-origin raw search, toolbar, viewport paging and native fixture repairs.
Evidence: `native-final-layout-review.txt`. The final covered-side delta
`5cdff8e8..9ae46afc` also reports no findings in its minimum calculation,
size propagation, state transitions, proposal and removal paths. Evidence:
`native-right-pane-review.txt`. That pass excludes the later root commit;
the root commit's source/test changes were already reviewed as identical
working changes in the preceding pass. Together with the whole-change
review from `e59e41a7`, this covers the frozen source candidate `8a27e5b3`.
The candidate is committed and pushed to `dev/next`; its working tree is
clean. Debug executable and implementation dylib have no direct SwiftUI or
Charts linkage. The Release build-for-testing also compiles successfully,
and its executable has no direct SwiftUI or Charts linkage. Evidence:
`native-frozen-release-build.log` and `native-frozen-release-linkage.txt`.

## Second complete gate and pinned-column regression

The second quiet gate at `5b55bff6` (the same product source as `8a27e5b3`)
completed in 37 minutes 48 seconds and **failed**. The serial lane executed
622 cases, with 23 skips and one failure; the parallel lane reported 1,936
passes, 34 skips and one failure. The helper cost checks, all 192 gallery
captures, 611 helper cases (six skips), 167 views-package cases (three skips),
34 wire, four concurrent, two acceptance and 72 Python checks passed.
Evidence: `native-frozen-full-gate.log`; the complete logs and captures are
preserved under `second-gate-5b55-verify-{logs,gallery}` in the cache.

The serial failure measured the Changes pane's synchronous 21-character
typing step at 32.8255 ms against the unchanged 30 ms limit. An isolated
rerun passed at 22.2 ms, with no layout cycles or diff rows built. This is
not yet a passing complete gate; the limit remains unchanged.

The pinned sides-panel test reproducibly fails its existing column bound:
the side transcript ends at x 1,034.25 instead of at or before 1,032.
The immutable 0.1.119 Release build passes the same test, establishing an
introduced regression. A temporary test diagnostic measures the actual side
allocation shrinking from 489 to 365 points while the composer's trial
proposal incorrectly remains 489. Its 371.5-point minimum then overlaps
the reserved column. The original layout probe also confirms that fixed
controls can expand a visible side; simply clamping every visible transcript
would change the released behavior. The correction must refresh the trial
proposal before measuring those controls. The temporary diagnostic was removed;
its measurements remain in `native-pinned-probe.log`. Evidence:
`native-second-gate-failures-alone.log` and
`native-pinned-panel-v119-baseline.log`.

The exact single-profile original/native probe reproduces the resize at
489 → 365 → 489 points without a new side/model update. With the correction
removed, it fails the proposal, leading boundary, width and reserved-column
assertions: the original transcript is x 0/width 365, while native is
x −3.25/width 371.5 with proposal 489. Restoring the proposal update makes
the minimum 290.5 at width 365 and both transcript bounds agree. The same
side and composer remain mounted throughout. This is a proposal correction,
not a clamp: the independent kept/in-memory cases still retain the original
336/457-point overflowing minima at a 310-point allocation.

The existing affected pane/composer/Git/side-panel classes pass: 109 cases,
no failures, in 96.1 seconds. The five narrow probes and seven side-panel
cases then pass together, including both new comparisons, in 21.2 seconds.
No existing assertion or threshold was changed. Evidence:
`native-pinned-proposal-affected-tests.log`, `native-pinned-resize-before.log`
and `native-pinned-resize-after.log`.

Three fresh isolated Changes-pane runs pass the unchanged 30 ms typing
limit at 23.7, 24.7 and 22.4 ms. Each reports zero layout cycles and zero
diff rows built for that synchronous 21-character step. The machine's
one-minute load was 1.83 before these runs; no build, review or agent UI
work ran alongside them. Evidence: `native-pinned-typing-confidence-{1,2,3}.log`.

The final read-only review reports no introduced source/test findings in
`5b55bff6..d98446c1` and the proposal repair's working source blob
`a8388fab2492ce566dc8cd391469616d110b7c92`. It checks refresh ordering,
notifications, reuse/removal, detached/zero-size states, covered tabs and
the strict frozen width comparisons. That exact production blob is committed
as `478d0211d8abea59d053a0752aba6f61102ad2af`, the new source candidate.
Evidence: `native-final-pinned-pane-review.txt`. Advice remains to complete
the quiet gate, final gallery, comparable Release measurements and actual
3,600-second Release soak against this source before publication. The final
Release build-for-testing is being rebuilt for this candidate.

## Third complete gate, gallery review and final Git caption correction

The quiet full gate for production source `478d0211` passed in 36 minutes
44 seconds. The serial lane executed 624 cases (23 skips, no failures);
the parallel lane reported 1,937 passes (34 skips, no failures). Isolated
helper cost checks, the 192-image gallery, 611 helper cases (six skips),
167 views-package cases (three skips), 34 wire, four concurrent, two
acceptance and 72 Python checks passed. Changes-pane typing measured
23.2 ms against the unchanged 30 ms limit. There were no geometry or
constraint warnings and no test-process crash reports. The Release
build-for-testing also passed. Evidence: `native-final-proposal-full-gate.log`
and `native-final-proposal-release-build.log`; raw gate logs and captures
are preserved as `third-gate-478d-verify-{logs,gallery}` in the cache.

All 192 fresh native/baseline pairs were then reviewed side by side, without
masking or alignment. The manifest `gallery-478d-review-manifest.json`
records both image hashes and reviewer assignments. The review found a
real Git toolbar regression with the actual short gallery folder captions;
the passing older narrow probe used a long generated UUID instead. The
review is therefore not a blanket gallery pass. Dynamic data, initial lazy
scrollbar extents and offscreen coverage limits are recorded in the four
`gallery-*-478d-review.txt` files.

The new same-controller frozen comparisons use both actual gallery folder
names at 310, 336, 360, 400, 520 and 600 points, plus covered-side running,
idle, resize and removal transitions. The toolbar now retains the pane's
proposal while reporting its overflowing natural width. Its folder caption
measures truncated head, ellipsis and tail separately, matching the
released Text's natural width; it preserves the compressed first grapheme
where no ellipsis fits. Adjacent header, History and detail children keep
their allocated pane width. Existing child-frame limits remain unchanged.

The read-only caption review found a further P2: drawing recomputed the
cut at the already-truncated natural width, which could drop extra
characters. Placement now retains its selected cut, while sizing-only
probes cannot replace it. Appearance-neutral caches resolve ink during
drawing; proposal and reported-width changes invalidate layout.

All eight narrow parity cases pass in 31.0 seconds. The new rendered-text
check compares actual window-server crops with the independent frozen
v119 UI at 400 points (`iiiiiiiiii-WWWWW`) and 420 points (a composed-accent
name), in light and dark. All four crops have zero differing pixels under
the existing channel tolerance of eight, with largest channel difference
one. Removing only the retained drawing cut produces eight assertion
failures (469–750 differing pixels); the correction was restored. The four
unmasked caption pairs were also visually reviewed. Evidence:
`native-git-caption-plan-tests.log`, `native-git-caption-mutation-tests.log`
and `git-caption-plan/git-caption-pixels` in the cache. The follow-up
read-only review reports no remaining actionable findings; evidence:
`native-git-caption-plan-review.txt`.

This final product correction requires a fresh gate and final gallery,
Release build, comparable performance measurements and actual hour soak.

## Final source gate and gallery, 2026-10-06

Production source `2be1b0d6ef1abc9897d32861104062bf7a2176a0` passes the
fresh complete gate in 37 minutes 51 seconds. The serial lane executes 627
cases (23 skips, zero failures); the parallel lane reports 1,937 passes
(34 skips, zero failures). Helper cost checks pass, followed by the fresh
192-image gallery, 611 helper cases (six skips), 167 views-package cases
(three skips), 34 wire, four concurrent, two acceptance and 72 Python checks.
The three covered Changes-pane typing measurements are 25.8, 23.2 and
27.8 ms, below the unchanged 30 ms bound, with no synchronous layout cycles
or diff rows built. There are no geometry/constraint warnings or test-process
crash reports. Evidence: `native-git-caption-final-full-gate.log` and
`build/verify-logs` in the cache.

The final Release build-for-testing passes in 8 minutes 56 seconds. Neither
the Release executable nor the Debug executable/debug dylib/preview directly
links SwiftUI or Charts. The production-source check passes; independent
frozen SwiftUI references remain test-only. Evidence:
`native-git-caption-final-release-build.log` and
`native-git-caption-final-linkage.txt`.

All 192 fresh pairs have matching filenames and original image dimensions,
and all were actually viewed without masks or alignment. The four reviewers
cover 82/24/54/32 files; the completed `gallery-2be1-review-manifest.json`
records original baseline/native SHA-256 hashes and exact assignments.
The actual narrow Git toolbar now matches in both themes, including original
2x inspection. The original-resolution dark back-to-bottom button also
matches. No new actionable owned layout/color/wrapping defect was identified
within the visible coverage.

This is not a blanket pixel-equality claim: `compare-captures.py` exits one
with 192 same-sized pairs containing unmasked differences. Reviewer records
retain generated paths/IDs/timing, caret/activation/selection, initial lazy
scroll-thumb estimates and optical differences. Report initial thumb ends
differ by 1–8 points; Overview and Settings lazy estimates also differ,
while strict complete-document parity tests pass. Screens named for lower
tables sometimes show only the top viewport, so offscreen rows are not
visually certified. Evidence: `native-final-2be1-unmasked-comparison.log` and
the four `gallery-*-2be1-review.txt` files in the cache. This distinction
preserves the actual observations and independent test coverage.

## Final typing measurement and bounded repair, 2026-10-06

The quiet baseline/final Release comparison completed all 16 invocations
per build, three rounds per group, using `scripts/perf-transcript.sh`, the
same fixtures/seed and a one-minute start-load limit of four. Opening,
streaming, scrolling and typical typing improve. The first final candidate
has a reproducible higher worst typing sample: 15–17 ms versus 8–10 ms,
despite its roughly 2 ms median versus roughly 4 ms. Three isolated
typing-only repetitions confirm this, so the regression was investigated
rather than omitted from the record. Raw data is in `perf-2be1` in the cache;
complete final-source measurements remain pending.

The composer's first nonempty character changes only its placeholder overlay
and Send readiness. It now compares every other State field exactly and
updates those two states without invalidating the card/bar/pane geometry.
Native editor updates and real field-height callbacks still run first.
The footer also caches the existing off-window context-label width
measurement, keyed against the same main-screen scale and bounded at 64
entries. It stores widths only; rendering, capture room, motion and
accessibility remain unchanged.

Eight affected Release checks pass, including frozen light/dark footer
comparisons at wide/narrow/side widths, controls, and the new actual-typing
case. The latter verifies arming/clearing/whitespace preserve field and Send
frames without a height notification, while a wrapped draft still grows.
The combined repair measures typing medians 1.9/1.8/2.0 ms, p90
2.3/2.2/2.3 ms and worst samples 9.6/9.7/10.4 ms in three isolated runs.
This substantially reduces the earlier peak; these samples include deferred
main-thread work during each 30 ms test suspension and are not hard input
latency guarantees. Evidence: `composer-width-cache-parity-tests.log` and
`typing-width-cache-{1,2,3}.log` under `perf-2be1`.

The bounded read-only Codex review reports no introduced findings in the
complete three-file repair. It checks the exact State guard, native height
callbacks, motion/accessibility, sizing formula, scale key and cache bound.
Advice: verify wrapped-draft shrinking, IME and screen-scale transitions.
Existing growing/shrinking, marked-text round-trip and IME cases are included
in the fresh full gate. The physical VM display remains 2x; a physical
main-screen switch between 1x and 2x has not been exercised. Evidence:
`native-composer-typing-review.txt`.

The previously completed `2be1b0d6` gate/gallery remain preserved, but the
new production repair requires a fresh complete gate and final captures
before release.

## Fresh typing-source gate and complete visual review, 2026-10-06

Source `1aa78749d7b3f68c524463ca90acdf3a3fe6b3d3` ran the complete
gate in 37 minutes 16 seconds. All native checks pass: 628 serial cases
(23 skips), 1,937 parallel passes (34 skips), five isolated helper-cost
checks, 192 gallery captures, 611 helper cases (six skips), 34 wire,
four concurrent, two acceptance and 72 Python checks. The original gate
exits one solely because `GitRevealTests.testTheNewestAskWins` assumed
async-let children entered the controller in declaration order. The test
now waits for the first call to enter before issuing the superseding call;
all success, final-line and fresh-token assertions remain. This establishes
call-entry order, not guaranteed overlapping reads. The complete views
package rerun passes 167 cases (three skips), and two additional repetitions
of all ten GitReveal cases pass. Its bounded read-only Codex review reports
no introduced findings. No test tolerance, timeout or production hook was
changed. The original failed gate and corrective logs remain available.

All 192 fresh same-sized pairs were actually viewed, assigned 82/24/54/32
among the four reviewers. Original 2x images, SHA-256 manifest, unmasked
comparison and per-image notes are preserved. This review found a real
15.5-point missing background overflow in both `24d-changes-from-blame`
captures. Window edges and Git header/history/detail frames match, but the
released Git stack paints its full 367-point logical width over the adjacent
composer/footer while the native panel painted only its 336-point bounds.
The independent frozen geometry confirms the exact extent. The review
manifest records this defect and does not approve parity before correction.

The bounded correction paints a noninteractive full-height Git background
at the existing resolved toolbar width, preserving all finite child
proposals and frames. Existing frozen tests now compare the background's
logical extent separately from allocated host bounds. The first pixel run
caught transitional light-fill pixels on appearance change. The new flat
background reuses `FillView`, whose existing appearance invalidation and
redraw policy paint the view's backing layer directly. All 28 affected
Git checks pass after byte-for-byte source restoration, including all eight
strict frozen cases and four exact caption comparisons (zero differing
pixels; largest channel difference one). Mutation proof removes only the
background overflow and fails the independent leading/width assertions:
0 versus -23.75 points and 310 versus 357.5 points. The original source is
restored, rebuilt and checked again; no oracle, tolerance or wait changed.

The final complete gallery passes in 430.890 seconds with all 192 original
same-sized captures. The changed Git screens are re-reviewed separately;
the all-192 `1aa78749` per-image records are reused for unchanged screens.
Root and the payload reviewer have actually viewed the final narrow composed
pairs in both appearances, including the reviewer's original 2x inspection:
the background edge now matches at approximately x581.5, while the Git
children keep their original frames. The final bounded read-only review
reports no introduced findings; its explicit limits are that caption crops
and frames alone do not prove full-window composited paint or hosted input
routing. Composed images now cover the former; the background remains
decorative with nil hit testing.

Evidence: `logs/native-git-background-flat-tests.log`,
`logs/native-git-background-mutation-{driver,build,test}.log`,
`logs/native-git-background-restored-{build,tests}.log`,
`logs/native-git-background-final-gallery.log`,
`logs/native-git-background-fill-review.txt`, and
`logs/gallery-git-background-final-manifest.json`.

Visible limitations remain explicit: generated paths/IDs and rates can
change wrapping; initial lazy scroll-thumb estimates differ; activation,
caret and selection can differ; the optical glyph differences and
unseen lower rows are not a blanket pixel-equality certification. Strict
complete-document checks cover Settings, Overview and conversation geometry.
Adversarial frozen sizing probes emit intentional invalid-geometry warnings;
the gallery itself contains no geometry/constraint warnings.

Evidence in `/Users/admin/Library/Caches/BelloAgentNext`: original gate
`logs/native-composer-final-full-gate.log`, archived `final-1aa-verify-logs`
and `final-1aa-verify-gallery`, corrective
`logs/native-final-views-test-order-full.log`, the two
`logs/native-final-views-test-order-repeat-*.log` files, read-only report
`logs/native-final-git-reveal-order-review.txt`, completed
`logs/gallery-1aa-review-manifest.json`, four `logs/gallery-*-1aa-review.txt`
files and `logs/native-final-1aa-unmasked-comparison.log`.

## Still required

Finish the remaining affected visual review, final-source Release performance
comparison and actual hour-long Release soak.
Owner VoiceOver and real-gateway checks have not been run or
explicitly deferred for this release. Packaging, signing, website publication
and the release tag remain pending.
