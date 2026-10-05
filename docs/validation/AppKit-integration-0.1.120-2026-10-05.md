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
Evidence: `native-final-layout-review.txt`. The final covered-side delta is
receiving its separate review before the source freeze.

## Still required

Perform the complete gallery comparison, Release
performance comparison, full release gate and hour-long soak. Owner VoiceOver
and real-gateway checks remain subject to the release checklist. No packaging,
signing, website publication or release tag was performed by this integration.
