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

## Test host isolation follow-up — 2026-10-14

The owner confirmed the earlier preference leak was pre-existing and systemic:
PiAppTests ran inside the shipping `com.belloware.PiApp` host. This follow-up
on `dev/a126-tps` fixes the test boundary for 0.1.126. The output-speed change
above received a fresh read-only review: no actionable regressions found.

### Structural isolation

`project.yml` now defines a separate `PiAppTestHost` application target, using
the same app sources and module (`PiApp`) with product `Bello Agent Tests.app`
and bundle/defaults identity `com.belloware.PiAppTests.Host`. PiAppTests depends
on this target in both Debug and Release. The shared PiApp scheme builds this
host only for testing; run/profile/archive still select the shipping target.

The scheme records `CFFIXED_USER_HOME=$(PROJECT_TEMP_DIR)/PiAppTests-Home`
in the test environment and generated `.xctestrun`. Native regressions verify
that Foundation's home, Application Support, Caches, default workspace root
and Keychain lock path resolve under that scratch home. Helpers receive
`NSHomeDirectory()` from `HostSupervisor`; home-relative Codex resource paths
also use Foundation's isolated home.

**Correction to the earlier gallery-isolation assumption:** on this Mac,
`cfprefsd` persists standard defaults in the account's Preferences directory
even with `CFFIXED_USER_HOME`. A scratch home alone is therefore insufficient.
The new tests write their dedicated `com.belloware.PiAppTests.Host` domain;
they never use the installed app's domain. Only existence/stat metadata was
checked for those paths, not real preference contents.

`TestIsolationGuard.m` is compiled into both the host and test bundle, never
the shipping target. Its constructors run before Swift main and before tests,
respectively. It rejects `com.belloware.PiApp` regardless of the fixed home,
requires the dedicated test identity, validates a distinct resolved data home,
and rejects symlink aliases into account storage. Failure prints
`Refusing to run PiAppTests` and exits 78 before test execution. It uses bundle
identity, environment, `getpwuid`, and path resolution, with no UserDefaults,
CFPreferences or real plist access. It also sets the test-mode flag before
application services can start.

Additional shared-state risks and fixes:

- The app's default Application Support root and the vault lock previously
  retained the production path even in test mode. The required scratch home
  now isolates those paths and Foundation caches. Explicit fixture roots
  continue to work.
- A fixed home does not isolate the login Keychain. Test-host builds now
  reject vault reads/replacements before any Security API, including signed
  test runs. The production service, signing requirement and entitlements
  are unchanged. Tests continue to inject fixture vaults.
- App updater startup previously depended on environment detection. It is
  now compiled out for `PI_TEST_HOST` and `PI_LAUNCH_FIXTURE`. Existing Sparkle
  tests only construct inert updater/driver objects; production feed and
  public-key bytes are unchanged.
- Several clipboard and drag tests accessed the desktop's shared pasteboards.
  The test-only constructor now maps AppKit's general, drag, find, font and
  ruler pasteboards to private per-process names, before any content access.
  Named fixtures and the existing Git diff test's local override still work.
  The focused probe failed first with routing absent, checking only board
  names; fixture content is accessed only after private names are verified.
  Window focus remains shared for UI tests, which still run in the serial lane.
- `perf-launch.sh` already gives copied fixture apps their own `launchperf`
  bundle ID and fixture vault/data home. Its dedicated defaults cleanup is
  limited to that fixture domain. No launch-perf trial was run for this task.

### Entry points

| Entry point | Isolation |
| --- | --- |
| Xcode Test / plain `xcodebuild test` | Shared scheme selects the distinct test host and scratch data home; constructors guard both executable and test bundle. |
| `scripts/test-macos.sh` | Regenerates and uses that scheme in every configuration. |
| `scripts/verify-release.sh` | Its build, serial lane, parallel clones and gallery use the same scheme and test products. |
| `scripts/check-next.sh` | Its build-for-testing and subsequent tests use the same scheme; gate delegates to verify-release. |
| Release build-for-testing / `scripts/perf-transcript.sh` | Release test host explicitly enables testability; `.xctestrun` retains isolation. New `check-test-host.py` rejects stale products naming the shipping host or missing the scratch home before launch. |
| `scripts/dev-wire.sh` | This path does not exist in the supplied branch. No substitute was invented; callers of the shared scheme inherit the same boundary. |
| `scripts/perf-launch.sh` | Separate launchperf identity and fixture vault already in place; updater startup additionally compiled out. |

The entire release gate/soak and check-next pull were not run: targeted native
tests, the requested gallery, generated-product inspection and six shell-entry
point fixture tests validate the affected paths without switching branches or
making paid calls.

### Verification

Artifacts: `$PI_BUILD_ROOT/preferences-isolation`. Tests use generated data
and loopback only. No installed app was launched. The real app plist was
observed with filesystem stat only; no sentinel was read or written there.

- Failing first: the configuration regression rejected the old project,
  which had no separate test host (`failing-first.log`).
- Seven Python configuration/guard/manifest/pasteboard tests pass (`guard-tests.log`).
  The guard probe compiles the actual guard with synthetic path arguments,
  checking production IDs in both real-looking and scratch homes, missing
  isolation, home aliases and storage-directory aliases.
- A fail-open guard mutation was made only in a scratch copy compiled as a
  standalone probe. It caused six assertion failures (`guard-mutation.log`);
  no mutated app or real preferences domain was launched.
- The actual Release test-host executable, invoked with no fixed home,
  refused startup with exit 78 before Swift main (`guard-native-refusal.log`).
- Six fixture tests for verify-release/check-next pass
  (`entrypoint-tests.log`). Shell syntax checks pass for all existing entry
  points, and `git diff --check` passes.
- Debug native checks: `MetricPillsTests` (32, parallel enabled),
  `WorkspaceRootTests` (7, serial alone), `TestHostIsolationTests` (3, serial
  alone), and Inspector-only `UIScreenshotTests` (1, serial alone; 70 PNGs)
  passed. The initial combined smoke run was superseded by the per-class
  runs after lane classification identified the new defaults test as serial.

The first Release test-build attempt omitted the existing documented
`ENABLE_TESTABILITY=YES` command-line flag and stopped at `@testable import
GitView`; it launched no tests. Release test builds still need that flag for
the package dependencies, as documented in `Swift-Test-Handoff.md`. The
shipping Release build is not given it.

The corrected Release `build-for-testing` succeeded. The final host includes
the clipboard routing; its stored `.xctestrun` passed `check-test-host.py` and
ran `TestHostIsolationTests` (3) alone with `test-without-building`. Further
Release checks through `scripts/test-macos.sh` passed:

- Parallel, two workers enabled: `MetricPillsTests` (32),
  `ConfigurationVaultTests` (14), `ReleaseConfigurationTests` (4), and
  `UpdatePauseTests` (7), 57 total. Two distinct test-host processes appear
  in the result log.
- Serial, each in its own invocation: `WorkspaceRootTests` (7),
  `PlainTextCopyTests` (3), `GitDiffTableTests` (19), `SidebarRowDragTests` (4).
- Inspector-only `UIScreenshotTests`: 1 passed in 167.475 seconds with 70
  captures, using a fresh fixture directory. Final Release total: 94 passed.
  There are 13 passing Python/script tests in addition to the native checks.

The real `~/Library/Preferences/com.belloware.PiApp.plist` stat was identical
before the first test, after the serial defaults class, and after the gallery:
`mtime_ns=1791949124436383958`, `size=3990`, `inode=146351745`. Baseline and
after-run JSON files contain only those stat fields. Test output identifies
`com.belloware.PiAppTests.Host`; scratch home paths are printed by both guards.

Final review tightened `TestHostIsolationTests` itself: wrong host identity
or home now returns before any data access, rather than relying on a
non-fatal assertion followed by a defaults write. The three checks were
rerun alone in Debug; that class's latest result bundle supersedes its
earlier passing Release bundle, whose text log is retained. The shipping
code, host guard and build configuration did not change after the Release
validation.

The plist subsequently changed at 12:20:44 while this task was only compiling
Release products. Another worktree was observed running the old shipping-ID
test host; no claim is made about preferences across that intervening period.
After that process exited, a fresh stat-only baseline was recorded for the
final Release runs: `mtime_ns=1791951644942666833`, `size=3980`,
`inode=146533208`. It remained identical after the stored-product isolation
test, the parallel group, each serial class, and the final Inspector gallery.
No contents were read to investigate the intervening change.

The first final gallery attempt reused the earlier generated fixture root.
Its persisted chats broke the onboarding-empty assertion and later turns;
this was an invocation error. The failed run's text log is retained, and the
retry uses a fresh generated fixture directory. No production state was
used to reproduce or repair this setup. The retry passed. Only the latest
`.xcresult` for each class is retained (the four parallel classes share one
bundle); obsolete bundles and the reused generated fixture root were removed.

Shipping identity checks compare against the parent commit's recorded build
settings and file hashes: all PiApp target build settings are exactly
unchanged; `apps/macos/PiApp/Info.plist`, `PiApp.entitlements`, and
`scripts/release.sh` are byte-identical. Resolved Release build settings for
the shipping scheme select only `PiApp`, retain `com.belloware.PiApp`, and
contain no `PI_TEST_HOST` flag (`shipping-release-settings.json`). No release
tag, package publication or merge into `dev/next` is part of this follow-up.

Commands for the final native checks (all artifacts are outside the checkout):

```bash
python3 scripts/test-lanes.py list
xcodebuild build-for-testing -project PiApp.xcodeproj -scheme PiApp \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES COMPILER_INDEX_STORE_ENABLE=NO
python3 scripts/check-test-host.py \
  "$PI_BUILD_ROOT/native-tests/Build/Products/PiApp_macosx15.1-arm64.xctestrun"
xcodebuild test-without-building \
  -xctestrun "$PI_BUILD_ROOT/native-tests/Build/Products/PiApp_macosx15.1-arm64.xctestrun" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TestHostIsolationTests \
  -resultBundlePath "$PI_BUILD_ROOT/preferences-isolation/TestHostIsolationTests.xcresult"

classes=(MetricPillsTests ConfigurationVaultTests ReleaseConfigurationTests UpdatePauseTests)
selected=()
for class in "${classes[@]}"; do selected+=("-only-testing:PiAppTests/$class"); done
scripts/test-macos.sh -configuration Release ENABLE_TESTABILITY=YES \
  -parallel-testing-enabled YES -parallel-testing-worker-count 2 "${selected[@]}" \
  -resultBundlePath "$PI_BUILD_ROOT/preferences-isolation/ParallelServices.xcresult"
for class in WorkspaceRootTests PlainTextCopyTests GitDiffTableTests SidebarRowDragTests; do
  scripts/test-macos.sh -configuration Release ENABLE_TESTABILITY=YES \
    -parallel-testing-enabled NO "-only-testing:PiAppTests/$class" \
    -resultBundlePath "$PI_BUILD_ROOT/preferences-isolation/$class.xcresult"
done

# A fresh fixture root, not the root of an earlier gallery.
PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/preferences-isolation/inspector-gallery-release" \
TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/preferences-isolation/inspector-gallery-release" \
PI_APP_UI_GALLERY_INSPECTOR_ONLY=1 TEST_RUNNER_PI_APP_UI_GALLERY_INSPECTOR_ONLY=1 \
scripts/test-macos.sh -configuration Release ENABLE_TESTABILITY=YES \
  -parallel-testing-enabled NO -only-testing:PiAppTests/UIScreenshotTests \
  -resultBundlePath "$PI_BUILD_ROOT/preferences-isolation/UIScreenshotTests.xcresult"

# Final verification-test precondition tightening; one serial class alone.
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TestHostIsolationTests \
  -resultBundlePath "$PI_BUILD_ROOT/preferences-isolation/TestHostIsolationTests.xcresult"

python3 -m unittest scripts.tests.test_test_isolation
python3 -m unittest scripts.tests.test_verify_release scripts.tests.test_check_next
```

Follow-up files:

- `project.yml`
- `PiApp.xcodeproj/project.pbxproj`
- `PiApp.xcodeproj/xcshareddata/xcschemes/PiApp.xcscheme`
- `apps/macos/TestSupport/TestIsolationGuard.m`
- `apps/macos/PiAppTests/TestHostIsolationTests.swift`
- `apps/macos/PiApp/Storage/KeychainVaultStorage.swift`
- `apps/macos/PiApp/Application/UpdateController.swift`
- `scripts/check-test-host.py`
- `scripts/perf-transcript.sh`
- `scripts/perf-launch.sh`
- `scripts/tests/test_test_isolation.py`
- `docs/Swift-Test-Handoff.md`
- `docs/validation/Output-speed-0.1.126-2026-10-14.md`
- `NEXT-RELEASE.md`
