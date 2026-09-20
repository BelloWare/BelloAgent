# Bello Agent 0.1.65/build 69 acceptance — 2026-09-20

Candidate; signing and public publication checks pending.

## Changes

- Work/tool/reasoning details start collapsed; closed work sections no longer
  show live tool trails or reasoning previews. Sidebar tool phases read
  “Working”; the live turn footer no longer renders the current tool arguments.
- Archive suppresses unread reply/failure indicators and aggregate counts in
  every presentation while retaining the original read state for restoration.
- Menu activity shows live elapsed time, generating/running counts, queued inputs,
  models and last reported routes, reported session usage/cost and the latest
  completed-request output rate. Byte-based live speed is never used.
- Fixed-window 250 ms coalescing replaces a trailing debounce that could starve
  under continuous streaming. The clock ticks once per second without querying
  the archive/provider. Hidden panels cancel their update work. Historical
  charts keep their existing polling cadence and model distribution.
- Transient model requests allow five retries after the initial attempt, with
  cancellable 1/3/5/8/10-second backoffs. Invalid requests/auth failures fail
  immediately. Dropped streams replace partial output; completed tools are not
  replayed. Compaction retains its separate eight-request total budget.

## Validation

- **26 packaged-helper gateway tests passed**, 42.080 s, including exactly six
  physical requests for sustained HTTP 429, unchanged request bodies, exact raw
  response capture, cancellation, tool round trips and compaction.

- **38 optimized helper tests passed**, 34.082 s: retry/recovery plus compaction
  output-budget and safety regressions. Production backoffs are exercised, not
  shortened: the failure case makes exactly six attempts and then stops.
- **75 native Debug tests passed**, 22.144 s, with Swift actor data-race checks.
  One optional visual test was initially skipped, then run explicitly below.
  Coverage includes uninterrupted change streams, hide/cancel lifecycle,
  reported-rate semantics, archived indicators, sidebar layout and collapsed
  work during streaming; existing expanded-work geometry/viewport cases now
  explicitly open the work they exercise.
- **One optional native visual test passed**, 0.982 s. Inspected the resulting
  synthetic menu screenshot for live elapsed/rate/model/usage layout. No user
  transcripts or credentials appear in the fixture.
- The first native build caught a Swift 6 sendable-capture issue in the new
  test's mutable counter; the fixture now uses an explicitly MainActor-owned
  state object. The production update path was unchanged by that correction.
- The first 26-test packaged gateway run reached its former 12-second deadline
  in the sustained-429 case. Five backoffs intentionally take 27 seconds, so
  only that scenario now has a 40-second deadline and stronger assertions for
  exactly six physical requests, identical request bodies and exact captures
  of every response. Other cases retain the original short deadline.

Scratch logs and intermediate screenshots are in the session's
`tmp/activity-065` directory. Helper command:

```sh
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-tests" -c release --filter 'RetryTests|RetryRecoveryTests|CompactionBudgetTests|CompactionSafetyTests'
python3 scripts/test-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
```

Native selection: `MenuBarMetricsTests`, `MenuBarPresentationTests`,
`SessionReadStateTests`, `SidebarMetricsLayoutTests`, `SessionOrganizationTests`,
`TranscriptDisclosureTests`, `NativeWorkListViewportTests`, and
`AppShellPerformanceTests/testTheStatusPanelCountsOnChangeRatherThanOnATick`.

No subagents, live paid gateway calls, installation or actual Sparkle update
rehearsal were used. Local fixture timing is not a claim about every real
provider's latency; throughput remains gateway-reported output divided by
completed-request duration, including reasoning tokens once.
