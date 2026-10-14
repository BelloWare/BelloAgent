# Output speed includes TTFT — 0.1.126

Date: 2026-10-14. Branch: `dev/a126-tps`, based on `origin/dev/next`.
Worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-a126-tps`.
Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a126-tps`.
Logs and generated captures: `$PI_BUILD_ROOT/tps-validation`.

## Definition and scope

For a completed request, with timings in milliseconds:

```text
duration_ms = TTFT_ms + first_to_last_output_ms
tokens/s = reported_output_tokens / (duration_ms / 1000)
group tokens/s = sum(reported_output_tokens) / (sum(duration_ms) / 1000)
```

Both raw timing observations must be finite and nonnegative. Reported output
must be finite and at least one token. The total duration must be finite and
at least 250 ms; this is an eligibility threshold, not a denominator clamp.
Ineligible requests contribute neither tokens nor duration, but remain in the
request count. A single-token or single-burst reply can count when its total
duration reaches the floor. Hidden reasoning is already in reported output
and is counted once. A trailing terminal/usage event wait after the last
output remains excluded. TTFT values and `tok/s` formatting are unchanged.

`SettledThroughput`, archive SQL and the helper apply the same rule. Existing
archives are queried from raw `ttft_ms`, `stream_ms`, and `output_tokens`, so
old helper rates are ignored without a schema migration or raw-data rewrite.
Inspector live metadata also recomputes from raw timings and usage. A stored
rate alone is unmeasured. Aggregate-only Codable records use new keys
(`outputDurationMilliseconds`, `measuredOutputTokens`, `outputSpeedSamples`)
so old aggregate sums cannot enter a new-definition sum; requests, TTFT and
unrelated usage survive decoding. Raw archives supply refreshed aggregates.

The Dashboard, session timing/history/ledger/usage, reports, menu bar and
transcript pills use this shared definition. Inspector overview, turn page,
components and index were audited: their rate paths already use the shared
accounting or raw `SessionTimingSample`, so no separate production formula was
needed. The Inspector regression covers old helper metadata and rate-only
metadata. Both Python scripts that compute/assert tok/s were updated; a
repository-wide Python search found no additional report/perf calculation.

No active settled-throughput calculation retains the old N−1/span definition.
Internal property names and helper wire keys such as `decodeTokensPerSecond`
and `minimumDecodeSpanMs` remain for compatibility, with updated meanings and
comments. The raw decode span remains first-to-last output. The existing
fallback for records without any last-output stamp (0.1.85 and earlier) still
uses the model terminal as the only recorded end; that legacy limit is
documented, not a use of the old rate. Historical release/validation/performance
records remain historical. Independently observed live counter telemetry is
unchanged; it is not the settled N−1/span calculation.

## Regressions and mutation

Before changing production code, the new `MetricPillsTests` regressions failed
with 29 assertions across four tests (32 tests executed), and the new helper
`RequestRateTests.testOutputSpeedIncludesTTFTAndFloorsTheWholeDuration` failed
with six assertions. Logs: `failing-first-app.log`, `failing-first-helper.log`.

Coverage includes a long TTFT, all N tokens, unequal-duration group sums,
single-token and zero-span replies, the exact 250 ms boundary, missing/invalid
timings and output, overflow, failed requests, SQL/Swift parity, unchanged
TTFT, wording, and rejection of old serialized aggregate sums. Archive reopen
and Inspector regressions verify raw recomputation despite a conflicting old
stored rate; rate-only records remain unmeasured. Helper tests also hold the
terminal after the last output and include hidden reasoning without visible
text. App and helper floor cases share the same inputs and expected rates.

Mutation temporarily restored the old N−1/decode-only implementation in the
Swift fold, archive SQL and helper (keeping the new Swift call signature).
`MetricPillsTests` then failed with 32 assertions across seven tests, exit 65;
the helper regression failed with six assertions, exit 1. The three production
files were restored in a `finally` block. Logs: `mutation-app.log`,
`mutation-helper.log`, `mutation-run.log`, `mutation-results.json`; the scratch
recipe is `mutate.py`. The restored implementation passed the final app and
helper reruns below. The wording regression separately failed against the
original wording in the failing-first run.

## Native app checks

Checked lanes with `python3 scripts/test-lanes.py list`. The regular classes
below are parallel-lane eligible; each multi-class invocation used a Bash
array. Serial-lane `MonitorParityTests` and `UIScreenshotTests` ran alone.

```bash
classes=(MetricPillsTests SessionTimingTests MenuBarMetricsTests DashboardTests
  SessionStatsChartsTests SessionUsageTests WireContractTests InspectorIndexTests
  GatewayAccountingTests MenuBarPresentationTests SessionOrganizationTests
  ReportPageTests TurnAccountingTests TurnInfoTests LiveAccountingTests)
args=()
for c in "${classes[@]}"; do args+=("-only-testing:PiAppTests/$c"); done
scripts/test-macos.sh "${args[@]}"
```

Result: 260 executed, zero failures, two optional skips, 156.3 seconds
(`app-pass2.log`). Skips were the opt-in default usage capture and the
70-finished-turn wire performance probe. An intermediate run had old-formula
expectations and an invalid ID in the new archive fixture; both were corrected
before this passing run.

After mutation restoration, the chart-caption adjustment and the added
Inspector regression:

```bash
classes=(MetricPillsTests GatewayAccountingTests SessionStatsChartsTests
  InspectorIndexTests LivePopupTests)
args=()
for c in "${classes[@]}"; do args+=("-only-testing:PiAppTests/$c"); done
scripts/test-macos.sh "${args[@]}"
```

Result: 102 executed, zero failures or skips (`app-final.log`). Only documentation
and a doc comment changed after this run.

## Helper and loopback checks

```bash
swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-host-tests" \
  --filter 'RequestRateTests|DecodeSpanTests|CaptureTraceTests'
python3 scripts/test-concurrent-native-host.py \
  "$PI_BUILD_ROOT/swift-host-tests/debug/pi-native-host"
python3 scripts/test-native-host.py \
  "$PI_BUILD_ROOT/swift-host-tests/debug/pi-native-host" \
  NativeIntegration.test_responses_distinct_timing_boundaries_streaming_and_json
python3 -m py_compile scripts/test-concurrent-native-host.py scripts/test-native-host.py
```

Results: 18 helper tests passed (`helper-final.log`), all four concurrent-host
tests passed in 28.7 seconds (`concurrent-host.log`), the streaming/JSON boundary
test passed (`native-timing-final.log`), and Python compilation passed. Helper
and boundary checks were rerun after restoring the mutation.

## Gallery checks and safety exception

All providers were generated fixtures or loopback servers, with scratch app
state and fixture vaults. The installed app was never launched, and no paid
provider or real Keychain was used.

**Exception to the owner's preferences rule:** the first Inspector-only gallery
also ran the existing `renderReviewScenes` sidebar scenes. Those call
`UserDefaults.standard.set` for `sidebarWidth` (first the minimum, then the
default width) at `UIScreenshotTests.swift:625` and `:629`. This was discovered
after execution, before a separate preferences home had been configured, and
was disclosed to the owner immediately. Thus this run cannot be claimed to
have left real preferences untouched. The original value was not read and no
speculative restoration was attempted. No other real user data was inspected.

The Inspector and report galleries were rerun, and the caption capture run,
with both `CFFIXED_USER_HOME` and `TEST_RUNNER_CFFIXED_USER_HOME` set to
`$PI_BUILD_ROOT/tps-validation/preferences-home`. Xcode's log resolves its
home/library paths under that scratch root. The original gallery also passed;
the isolated reruns are the final captures recorded here.

```bash
PI_COMPONENT_GALLERY="$PI_BUILD_ROOT/tps-validation/monitor-gallery" \
TEST_RUNNER_PI_COMPONENT_GALLERY="$PI_BUILD_ROOT/tps-validation/monitor-gallery" \
  scripts/test-macos.sh -only-testing:PiAppTests/MonitorParityTests

export CFFIXED_USER_HOME="$PI_BUILD_ROOT/tps-validation/preferences-home"
export TEST_RUNNER_CFFIXED_USER_HOME="$CFFIXED_USER_HOME"
PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/tps-validation/inspector-gallery-isolated" \
TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/tps-validation/inspector-gallery-isolated" \
PI_APP_UI_GALLERY_INSPECTOR_ONLY=1 TEST_RUNNER_PI_APP_UI_GALLERY_INSPECTOR_ONLY=1 \
  scripts/test-macos.sh -only-testing:PiAppTests/UIScreenshotTests
PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/tps-validation/report-gallery-isolated" \
TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/tps-validation/report-gallery-isolated" \
PI_APP_UI_GALLERY_REPORT_ONLY=1 TEST_RUNNER_PI_APP_UI_GALLERY_REPORT_ONLY=1 \
  scripts/test-macos.sh -only-testing:PiAppTests/UIScreenshotTests
PI_APP_USAGE_CAPTURE_ROOT="$PI_BUILD_ROOT/tps-validation/rate-caption" \
TEST_RUNNER_PI_APP_USAGE_CAPTURE_ROOT="$PI_BUILD_ROOT/tps-validation/rate-caption" \
  scripts/test-macos.sh \
  -only-testing:PiAppTests/SessionTimingTests/testTheUsagePanelQuotesTheOutputSpeedOfTheSameRequest
```

Results: monitor parity three tests passed, with 16 PNGs (eight AppKit/SwiftUI
pairs); Inspector one test passed with 70 PNGs; report one test passed with six
PNGs; caption one test passed with one JPEG. Logs: `monitor-parity.log`,
`inspector-gallery-isolated.log`, `report-gallery-isolated.log`, `rate-caption.log`.

Visually inspected menu usage panels in light/dark, Inspector overview in
light/dark, narrow Inspector and turn page, report analytics in light/dark,
and the dedicated usage-rate caption. The new output-speed label and the
longer report/menu explanation fit without clipping. The Inspector overview's
explanation below the captured fold was not visually inspected; shared-string
and presentation regressions cover its content. Generated captures and logs
remain outside the repository.

`git diff --check` passed. This is a development-branch change, with no release,
tag, installed-app launch or merge into `dev/next`.

## Files changed

- `Design.md`
- `Features.md`
- `NEXT-RELEASE.md`
- `README.md`
- `apps/macos/PiApp/Application/MenuBarActivity.swift`
- `apps/macos/PiApp/Application/MenuBarMetricsView.swift`
- `apps/macos/PiApp/Application/MenuBarUsageChartSpec.swift`
- `apps/macos/PiApp/Application/MonitorRateChart.swift`
- `apps/macos/PiApp/Application/MonitorRateChartSpec.swift`
- `apps/macos/PiApp/Dashboard/DashboardQuery.swift`
- `apps/macos/PiApp/Dashboard/GatewayAccounting.swift`
- `apps/macos/PiApp/Dashboard/MenuBarMetrics.swift`
- `apps/macos/PiApp/Dashboard/ReportPage.swift`
- `apps/macos/PiApp/Dashboard/SessionRequestLedger.swift`
- `apps/macos/PiApp/Dashboard/SessionStatsChartSpecs.swift`
- `apps/macos/PiApp/Dashboard/SessionStatsCharts.swift`
- `apps/macos/PiApp/Dashboard/SessionTimingHistory.swift`
- `apps/macos/PiApp/Dashboard/SessionUsageView.swift`
- `apps/macos/PiApp/Design/MetricFormats.swift`
- `apps/macos/PiApp/Storage/CaptureArchive/PayloadArchive+Accounting.swift`
- `apps/macos/PiApp/Transcript/TranscriptItem.swift`
- `apps/macos/PiApp/Transcript/TurnPills.swift`
- `apps/macos/PiAppTests/DashboardTests.swift`
- `apps/macos/PiAppTests/GatewayAccountingTests.swift`
- `apps/macos/PiAppTests/InspectorIndexTests.swift`
- `apps/macos/PiAppTests/LivePopupTests.swift`
- `apps/macos/PiAppTests/MenuBarMetricsTests.swift`
- `apps/macos/PiAppTests/MenuBarPresentationTests.swift`
- `apps/macos/PiAppTests/MetricPillsTests.swift`
- `apps/macos/PiAppTests/MonitorParityReferences.swift`
- `apps/macos/PiAppTests/SessionOrganizationTests.swift`
- `apps/macos/PiAppTests/SessionStatsChartsTests.swift`
- `apps/macos/PiAppTests/SessionTimingTests.swift`
- `apps/macos/PiAppTests/SessionUsageTests.swift`
- `apps/macos/PiAppTests/WireContractTests.swift`
- `docs/LiteLLM-Accounting-Contract.md`
- `docs/validation/Output-speed-0.1.126-2026-10-14.md`
- `packages/swift-host/Sources/PiAgentCore/TraceStore.swift`
- `packages/swift-host/Tests/PiAgentCoreTests/DecodeSpanTests.swift`
- `packages/swift-host/Tests/PiAgentCoreTests/RequestRateTests.swift`
- `scripts/test-concurrent-native-host.py`
- `scripts/test-native-host.py`
