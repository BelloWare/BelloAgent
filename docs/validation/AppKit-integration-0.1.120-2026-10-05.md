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
updates and reject removed entries. SwiftUI scroll replacements use overlay
indicators to preserve their original full-width viewport.

Focused final results include 10 Inspector controls and 24 Inspector parity
comparisons, 5 statistics controls and 46 statistics parity comparisons,
38 shared PiKit controls, 8 native application cases and 9 window-presentation
cases, all passing. Payload and complete gallery results are recorded after
their final viewport corrections. These are development checks; they do not
substitute for the complete release gate or Release soak.

## Still required

Perform the complete gallery comparison, Release
performance comparison, full release gate and hour-long soak. Owner VoiceOver
and real-gateway checks remain subject to the release checklist. No packaging,
signing, website publication or release tag was performed by this integration.
