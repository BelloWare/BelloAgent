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

Transcript coverage: native-renderer source guard, message kinds, row and
pane behavior, tool-card behavior, row/turn/work visual parity, and real-zsh
cursor alignment. The five skips are existing opt-in calibration/probe cases.

Dashboard coverage: background requests, report navigation, menu-bar usage
and presentation, live monitor and popup, lazy AppKit controls, session-series
builders, cost-limit behavior and chart ticks. The skip is an opt-in menu-bar
capture. The separate parity classes compare light and dark appearances with
the original SwiftUI/Swift Charts references at their existing thresholds.

Local evidence is under `~/Library/Caches/BelloAgentNext/logs/`:
`transcript-integration.log`, `dashboard-build.log`, `dashboard-functional.log`,
`PiChartParityTests.log`, `MonitorParityTests.log`, `CostLimitParityTests.log`.
Dashboard parity captures are in `appkit-integration-gallery/` beside `logs/`.

## Still required

Finish the footer, Inspector and app-shell ports; remove the remaining SwiftUI
imports and bridges. Perform the complete gallery comparison, Release
performance comparison, full release gate and hour-long soak. Owner VoiceOver
and real-gateway checks remain subject to the release checklist. No packaging,
signing, website publication or release tag was performed by this integration.
