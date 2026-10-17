# Inspector, reports and storage — 0.1.130

Workstream: `dev/a130-inspector`. Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-inspector`.

Generated capture archives and synthetic headers only. Native tests use the isolated test host. No installed app, live capture, provider call, real preference, chat or Keychain access. No helper, wire, permission or capture-retention policy change. The lead owns merge and the full release gate.

## Findings

### inspector-storage-1 — confirmed + fixed (tiny reported cost)

Confirmed in code: both telemetry and `GatewayObservation` accept finite nonnegative `1e-300`; archive/report aggregation preserves it. `PiChartTicks.clean` overflows its decimal multiplier and produces NaN. The regression ingests a completed capture with that reported amount, filters its chat/window, builds `ReportChartSpec` and resolves `PiChartLayout`.

Tests: `DashboardTests.testTinyReportedCostResolvesAChartLayout`, `PiChartTicksTests.testFiniteExtremesKeepFiniteOrderedDomainsAndTicks`.

Failing first (`failing-numeric-pagination.log`, production unchanged):

```text
testTinyReportedCostResolvesAChartLayout started.
Fatal error: Range requires lowerBound <= upperBound
testFiniteExtremesKeepFiniteOrderedDomainsAndTicks started.
Fatal error: Double value cannot be converted to Int because it is either infinite or NaN
```

Fix: validate candidate scales and interval counts before integer conversion, keep rounding finite, and validate/clamp widened bounds before building a range. Tick enumeration is bounded and filters nonfinite/out-of-domain results. Ordinary measured tick choices are retained.

Nearby instance: subnormal accepted values underflow the candidate power to zero, causing the separate integer-conversion trap. The numeric regression includes the least nonzero and least normal values, positive/negative and off-zero ranges, and large finite bounds.

Passing: Dashboard 19/19 and tick tests 4/4. The strengthened cost test also passed the numeric mutation control (2/2). Mutation: restore the old rounding expression → both selected regressions fail (9 assertions, including one tick instead of multiple finite ticks); restore the old conversion before scale checks → the subnormal regression traps again. Logs: `mutation-rounding.log`, `mutation-tick-count.log`.

### inspector-storage-2 — confirmed + fixed (clearing an open capture)

Confirmed in code: `SessionInspectorModel.refresh` rereads the index but does not refresh a completed request's metadata. Same-row reopen only notices source/outcome changes. Raw keeps its document and copy source, and the parsed response can remain loaded too.

Test: `InspectorStorageTests.testClearThenRefreshRetiresLoadedBodiesWithoutNavigation`. It loads retained request/response documents and the Raw request, copies the generated body, clears the archive through the same operation used by `WorkspaceModel.clearCaptures`, and refreshes without changing the selected request.

Failing first (`failing-inspector.log`, production unchanged):

```text
testClearThenRefreshRetiresLoadedBodiesWithoutNavigation : failed - the purged descriptor
```

Fix: the successful Clear action cancels reads, clears request/response documents and metadata, advances a capture revision, and refreshes the Inspector. An ordinary Refresh reloads metadata and invalidates bodies only when changed descriptors show they are unavailable. Raw retires its body view and copy source on that revision. A copy already rendering checks the revision before publishing to the pasteboard. This also clears hidden parsed Response/Conversation documents without changing the running-response Load latest policy.

Additional regression: `testACopyAlreadyRenderingCannotPublishAfterClear` holds the rendering worker, starts Copy, clears and refreshes, then releases the worker; the generated pasteboard sentinel must survive. The final Inspector/gallery run passed all 7 tests. Three independent mutations failed their one selected regression each:

- Remove `request.refresh()` from the Inspector refresh path: timeout waiting for the purged descriptor (`mutation-refresh.log`, 2 failures including the thrown timeout).
- Remove Raw's document-retirement block: `XCTAssertNil` finds the original `CapturedBodyDocument`, 201 bytes, state `complete`, even after purged metadata has loaded (`mutation-raw-document.log`, 1 failure).
- Remove the post-render revision guard: clipboard contains the generated `message 0` / `message 1` JSON instead of `after clear` (`mutation-inflight-copy.log`, 1 failure).

These were run with the other fixes present, so they independently prove metadata reload, document retirement and pending-copy fencing.

After narrowing invalidation to preserve unchanged views, all three mutations were repeated against the refined implementation. Each again failed its selected test, with 2, 1 and 1 failures respectively (`preserved-mutation-refresh.log`, `preserved-mutation-raw-document.log`, `preserved-mutation-inflight-copy.log`). Sources were restored after each run.

Two further checks cover that refinement. Removing unavailable-descriptor invalidation leaves the old parsed Response and Raw copy source (3 failures including the thrown timeout, `preserved-mutation-descriptor.log`). Reintroducing blanket invalidation on Refresh breaks the preserved view identity, Hex format and document identity (3 failures, `preserved-mutation-unchanged-refresh.log`). Both mutations exited 65 after compilation, and both sources were restored before the final 7/7 Inspector/gallery run.

### inspector-storage-3 — confirmed + fixed (report pagination ceiling)

Confirmed in code: the actual count advertises another page, but `requestPage` rejects offsets above 100,000. The 100,097-row generated SQLite fixture uses the same archive reader as the report.

Test: `DashboardTests.testReportPagesReachEveryRetainedRequestAndSession`.

Nearby instances: `dashboard` (refresh at the last page) and `sessionSummaries` have the same obsolete ceiling; the fixture gives each request a distinct session to exercise both. Negative offsets and the existing bounded page sizes remain enforced.

Failing first (`failing-numeric-pagination.log`, production unchanged):

```text
The advertised final request page failed: unavailable
Refreshing the final request page failed: unavailable
```

Fix: each of the three reader entry points validates `offset >= 0`; SQL page limits remain 128 requests / 64 chats. The regression checks offset 99,968 advertises another page, offset 100,096 yields the final request, report refresh and chat pagination reach the same boundary, negative offsets fail, and `Int.max` yields an empty page.

Passing: the large regression passed (2.559 s including generated insert/queries); Dashboard 19/19 and report-worker 4/4. Mutation: restore the ceiling in all three entry points → the regression fails with request-page, report-refresh and final-chat-page `unavailable` errors (4 assertions/errors). `mutation-pagination.log` includes:

```text
The final chat page failed: unavailable
Executed 1 test, with 4 failures (1 unexpected)
```

The unchanged 100k report-worker check measured aggregate 1253.0 ms and two request pages 161.4 ms in this concurrent workstream environment; this is fixture evidence, not a release performance certification.

Additional nearby instance: `MenuBarMetrics.swift:144` used the same ceiling for menu and Inspector session model-route pages. `MenuBarMetricsTests.testModelPagesReachEveryRetainedRoute` inserts 100,009 generated routes, verifies offset 99,984 has another 24-row page, and requests the final route at offset 100,008 through both archive APIs. With that guard unchanged it failed twice (`failing-model-pagination.log`):

```text
The advertised final model page failed: unavailable
The final session model page failed: unavailable
Executed 1 test, with 2 failures (0 unexpected)
```

That guard now retains nonnegative and 24-row alignment checks without the obsolete ceiling. This changes no aggregate or route grouping logic. The existing invalid-offset test still rejects negative and unaligned offsets.

Passing: `MenuBarMetricsTests` 29/29 (`final-model-pagination.log`). Mutation: restore the ceiling in `usageMetrics` → the new boundary test fails both assertions again, exit 65 (`mutation-model-pagination.log`); the source was restored.

### inspector-storage-4 — confirmed + fixed (Headers Copy)

Confirmed in code: Headers renders directly from metadata; Copy uses the empty page buffer while any metadata enables the button.

Test: `InspectorStorageTests.testHeadersCopyIncludesBothDisplayedMaskedSections`. It clicks the actual Raw Copy button and compares the pasteboard to both rendered sections, including the already-masked authorization value.

Failing first (`failing-inspector.log`, production unchanged):

```text
Missing displayed headers: authorization: Bearer ********-key
Missing displayed headers: content-type: text/event-stream
```

Fix: the outer Copy representation is composed from the exact sorted strings used by the two `CapturedHeadersView` instances, with request/response headings. No masking, header capture or metadata export policy changes.

Nearby instances: empty Headers and empty Links enabled Copy solely because unrelated metadata existed. `testEmptyHeadersDoNotEnableCopyFromUnrelatedMetadata` and `testEmptyLinksDoNotEnableCopyFromUnrelatedMetadata` both failed before the fix. Copy availability now follows the selected part's own representation. All three header/empty-part regressions pass. Mutation: restore the old non-body copy selection → the header test fails all 5 content assertions (`mutation-headers-copy.log`). Restore metadata-based button enablement → both empty-part tests fail (3 failures including the thrown Links timeout; `mutation-empty-copy.log`).

## Commands and results

Text logs are under the build root. No named xcresult bundles. Focus-changing tests and galleries hold `/Users/admin/Library/Caches/BelloSwiftWork/full-lane.lock`, with cleanup on exit.

Commands use the worktree root as cwd:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-inspector
xcodegen generate --quiet

# Failing first, unchanged production: 3 selected tests failed (2 traps).
scripts/test-macos.sh \
  -only-testing:PiAppTests/DashboardTests/testTinyReportedCostResolvesAChartLayout \
  -only-testing:PiAppTests/DashboardTests/testReportPagesReachEveryRetainedRequestAndSession \
  -only-testing:PiAppTests/PiChartTicksTests/testFiniteExtremesKeepFiniteOrderedDomainsAndTicks

# Failing first, under the lock: 4 failed, 1 gallery skipped.
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorStorageTests

# First fixed model coverage: 34 passed, zero failures/skips.
scripts/test-macos.sh \
  -only-testing:PiAppTests/DashboardTests \
  -only-testing:PiAppTests/PiChartTicksTests \
  -only-testing:PiAppTests/ReportWorkerPerformanceTests \
  -only-testing:PiAppTests/InspectorRequestModelTests

# Final generated scenes plus Inspector regressions: 7 passed, no skips/failures.
TEST_RUNNER_PI_APP_INSPECTOR_STORAGE_GALLERY="$PI_BUILD_ROOT/gallery" \
  "$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorStorageTests
```

`run-ui.sh` is the following lock wrapper, written under the build root; each invocation releases only the lock it acquired, including on test failure:

```sh
#!/bin/bash
set -u
L=/Users/admin/Library/Caches/BelloSwiftWork/full-lane.lock
until mkdir "$L" 2>/dev/null; do sleep 60; done
trap 'rm -rf "$L"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'a130-inspector %s\n' "$(date)" > "$L/owner"
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-inspector
scripts/test-macos.sh "$@"
```

An initial harness-only compile failed on sending the XCTest instance across actor isolation; chart layout/assertions now run in `MainActor.run`. All failing-first evidence above comes from subsequently compiled tests, before production edits.

All 11 mutation variants failed as expected (each exit 65, after successful compilation); production files were restored after each invocation. Three Inspector variants were also repeated after the preservation refinement, for 14 mutation runs total. The two-test numeric control passed before mutation. `mutation-summary.log`, `preserved-mutation-summary.log`, `finish-checks-summary.log` and the individual text logs retain the exact results.

The mutation commands used the following selectors, prefixed with `-only-testing:PiAppTests/`. Numeric/pagination runs used `scripts/test-macos.sh`; Inspector runs used `"$PI_BUILD_ROOT/run-ui.sh"`:

| Log stem | Test selectors | Failed tests |
| --- | --- | ---: |
| mutation-rounding | DashboardTests/testTinyReportedCostResolvesAChartLayout; PiChartTicksTests/testFiniteExtremesKeepFiniteOrderedDomainsAndTicks | 2 |
| mutation-tick-count | PiChartTicksTests/testFiniteExtremesKeepFiniteOrderedDomainsAndTicks | 1 (trap) |
| mutation-pagination | DashboardTests/testReportPagesReachEveryRetainedRequestAndSession | 1 |
| mutation-refresh | InspectorStorageTests/testClearThenRefreshRetiresLoadedBodiesWithoutNavigation | 1 |
| mutation-raw-document | InspectorStorageTests/testClearThenRefreshRetiresLoadedBodiesWithoutNavigation | 1 |
| mutation-inflight-copy | InspectorStorageTests/testACopyAlreadyRenderingCannotPublishAfterClear | 1 |
| mutation-headers-copy | InspectorStorageTests/testHeadersCopyIncludesBothDisplayedMaskedSections | 1 |
| mutation-empty-copy | InspectorStorageTests/testEmptyHeadersDoNotEnableCopyFromUnrelatedMetadata; InspectorStorageTests/testEmptyLinksDoNotEnableCopyFromUnrelatedMetadata | 2 |
| mutation-model-pagination | MenuBarMetricsTests/testModelPagesReachEveryRetainedRoute | 1 (2 assertions) |
| preserved-mutation-descriptor | InspectorStorageTests/testClearThenRefreshRetiresLoadedBodiesWithoutNavigation | 1 (3 assertions/errors) |
| preserved-mutation-unchanged-refresh | InspectorStorageTests/testRefreshPreservesAnUnchangedRawDocumentAndFormat | 1 (3 assertions) |

Final focused coverage: **175/175 distinct tests across 19 classes**, zero failures and zero skips in the final per-class runs below. Repeated controls, failing-first runs and mutation runs are excluded from that total. No unrelated test failed. The opt-in Inspector gallery is included.

| Class | Passed/total | Final evidence |
| --- | ---: | --- |
| DashboardTests | 19/19 | `final-models.log` |
| InspectorDocumentCacheTests | 3/3 | `final-models.log` |
| InspectorFollowTests | 2/2 | `final-summary-follow.log` |
| InspectorFrameTests | 2/2 | `final-inspector-frame.log` |
| InspectorIndexTests | 11/11 | `final-models.log` |
| InspectorNativeControlTests | 12/12 | `final-native-controls-preserved.log` |
| InspectorNativeParityTests | 7/7 | `final-native-parity.log` |
| InspectorPerformanceTests | 2/2 | `final-inspector-performance.log` |
| InspectorRequestModelTests | 7/7 | `final-request-models-preserved.log` |
| InspectorStorageTests | 7/7 | `final-raw-final.log` |
| InspectorSummaryRequestTests | 5/5 | `final-summary-follow.log` |
| MenuBarMetricsTests | 29/29 | `final-model-pagination.log` |
| PiChartParityTests | 6/6 | `final-chart-parity.log` |
| PiChartTicksTests | 4/4 | `final-models.log` |
| ReportPageTests | 33/33 | `final-report-page.log` |
| ReportWorkerPerformanceTests | 4/4 | `final-models.log` |
| SessionUsageTests | 14/14 | `final-session-usage.log` |
| SessionUsageWindowFrameTests | 1/1 | `final-session-usage-frame.log` |
| SubagentInspectorTests | 7/7 | `final-request-models-preserved.log` |

Exact final invocations (using the exported build root and lock wrapper above):

```sh
# final-models.log: 55 passed.
scripts/test-macos.sh \
  -only-testing:PiAppTests/DashboardTests \
  -only-testing:PiAppTests/InspectorDocumentCacheTests \
  -only-testing:PiAppTests/InspectorIndexTests \
  -only-testing:PiAppTests/InspectorRequestModelTests \
  -only-testing:PiAppTests/PiChartTicksTests \
  -only-testing:PiAppTests/ReportWorkerPerformanceTests \
  -only-testing:PiAppTests/SubagentInspectorTests

# Boundary regression before the model-route fix: 1 test, 2 failures.
scripts/test-macos.sh -only-testing:PiAppTests/MenuBarMetricsTests/testModelPagesReachEveryRetainedRoute
# Fixed model-route class: 29 passed.
scripts/test-macos.sh -only-testing:PiAppTests/MenuBarMetricsTests

# Repeated after refining Inspector invalidation: 14 passed.
scripts/test-macos.sh \
  -only-testing:PiAppTests/InspectorRequestModelTests \
  -only-testing:PiAppTests/SubagentInspectorTests

# UI invocations held the lock; serial-lane classes each ran alone.
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/PiChartParityTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorNativeControlTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorNativeParityTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/ReportPageTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/SessionUsageTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/SessionUsageWindowFrameTests
"$PI_BUILD_ROOT/run-ui.sh" \
  -only-testing:PiAppTests/InspectorSummaryRequestTests \
  -only-testing:PiAppTests/InspectorFollowTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorPerformanceTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorFrameTests
```

The final Inspector/gallery invocation is recorded above and writes `final-raw-final.log`. All serial-lane classes ran alone. The long-chat frame fixture passed 2/2: opening its 301-request overview took 308 ms; the 5 MB Conversation became ready in 439 ms, and switching to Raw took 0 ms of measured preparation (`final-inspector-frame.log`). No clone directories remained under this workstream's build root.

## Gallery review and scope

Regenerated and visually inspected all 12 PNGs under `gallery/`: Headers, purged request, and tiny-cost chart; light/dark; 1000/700-point widths. The fixture uses a native Pi background and generated capture data. Masked headers remain readable, the purged view shows no body and disables Copy, and tiny cost has finite ticks at zero, 5e-301 and 1e-300. The first transparent component-only captures were replaced with captures of the same components on the app's actual background color.

Separate existing issue, initially left unchanged per scope (resolved in the review follow-up below): `apps/macos/PiApp/Inspector/Session/InspectorRawTab.swift:84` gives Request/Response search a fixed 180-point compact width alongside all six part tabs. At 700-point Raw content width, Copy/menu overflow the right edge (`purged-light-700.png`, `purged-dark-700.png`); Headers fits because it has no search field. `rebuildToolbar` and its layout were unchanged in the initial commit. The owner subsequently authorized the responsive-toolbar fix; no decision remains pending.

Separate existing wording issue, resolved in the review follow-up below: `apps/macos/PiApp/Dashboard/ReportController.swift:336` still describes a 100,000-record retention bound in its report notice, while `PayloadArchive.begin` no longer enforces that bound. Left for a separate wording correction; retention policy is unchanged here.

Self-review refinement: the first draft invalidated on every Refresh, unnecessarily replacing an unchanged Raw document and resetting Hex to JSON. `testRefreshPreservesAnUnchangedRawDocumentAndFormat` failed that draft with 3 assertions (`refresh-preservation-before.log`). Invalidation is now specific to successful clearing or changed unavailable descriptors. The complete refined Inspector class passes all 7 tests with the gallery enabled (`final-raw-final.log`); all 12 regenerated images were reviewed again. The Inspector-specific mutations above were run against this refinement.

No finding was rejected. No helper or wire behavior changed, so helper/wire/concurrent/acceptance suites are not required for this app-only patch. The native harness stages the Release helper as usual; the full merged gate remains with the lead.


## Review follow-up: session memory, narrow Raw toolbar and report notice

The owner authorized these three corrections after reviewing commit `7ac553a4`.
All three are confirmed; no owner decision remains pending.

### Session-memory completion

`InspectorIndex.merge` correctly prefers the completed durable row. For Session
memory captures, that row describes bodies as `not-retained`, while the helper
still holds readable bytes. The new removal check incorrectly treated the log's
descriptor as evidence that the body itself had disappeared.

`testSessionMemoryCompletionKeepsRawStateAndOffersTheLatestResponse` uses a
generated unfinished response, a real memory-mode archive record, the actual
index merge, and a generated readable helper-source seam (no helper or provider
starts). It covers both Raw Request and Response, retaining the mounted body,
Hex format, document identity, query, parsed response prefix and read count.
The final memory byte count must remain offered through Load latest; only the
explicit Load latest action replaces the parsed prefix.

Before the fix, both cases failed: capture revision `1 != 0`, the mounted Raw
view changed, its document disappeared, the parsed response became nil and its
byte count became zero. `growingBytes` was `0` instead of `4143`. Evidence:
`review1-before-inspector.log`, exit 65; this test contributed 14 assertion
failures before the later mounted-view assertion was strengthened.

The fix resolves the actual body source using the newly read descriptors and
checks its metadata before invalidating. Readable memory bodies keep their
state; the response's actual retained byte count supplies Load latest. Durable
metadata still accurately says `not-retained`. The check reads metadata only,
respects cancellation and request identity, and leaves explicit capture clearing
and unavailable-source invalidation intact.

### Narrow Raw toolbar

`testRawToolbarFitsEveryPartAtNarrowAndMinimumPaneWidths` reproduced clipping
in Request/Response at 700 points and all parts in the 485-point pane available
inside the minimum 700-point Inspector window. For example, Links' capture menu
ended at x=573.5 in a 485-point pane. The same baseline Inspector run contributed
18 geometry failures, for **2 tests / 32 assertion failures** in total.

The toolbar now allows search to shrink to 120 points, then uses the existing
PiKit menu-button control for all six parts when the tabs no longer fit. Copy
and capture actions remain visible. Tests cover every part, menu entries and
selection, accessibility names, and search focus/query across resizing.

### Report notice

`testPrepareQueriesTheArchiveAndBrushNarrowsTheActiveSnapshot` now checks the
successful report's notice. Before the fix it failed both assertions: the text
still contained `100,000` and did not describe configured retention
(`review1-before-report.log`, **1 test / 2 assertion failures**, exit 65).
The notice now states the 128-request page size, 60 time buckets and configured
metric retention period. Storage policy is unchanged.


The first fixed control exposed a second instance in the same transition:
Raw could see the new `.log` row with the old live descriptor before the
asynchronous metadata read completed. It briefly switched to the archive and
back to memory, replacing both Raw documents despite preserving the view and
Hex selection. The same regression failed its two document-identity assertions
(`review1-fixed-storage-compiled.log`); the other eight non-gallery Inspector
checks passed, and two galleries were skipped in that control. The fix marks
metadata pending before publishing the changed row and defers Raw route changes
until metadata is loaded. This also preserves the prefix until Load latest.

Harness-only correction: the first fixed build stopped on Swift's
warnings-as-errors check for an ambiguous trailing closure in the new menu test.
It was parenthesized; no product failure was hidden by that compile error.
The report control subsequently passed 1/1 in
`review1-fixed-report-compiled.log`.

### Follow-up validation evidence

Failing-first excerpts (before any production edits):

```text
review1-before-inspector.log:
XCTAssertEqual failed: ("1") is not equal to ("0") - A durable row without durable bytes is not a purge
XCTAssertEqual failed: ("Optional(0)") is not equal to ("Optional(4143)") - Load latest uses the readable memory source
XCTAssertLessThanOrEqual failed: ("573.5") is greater than ("485.0") - links at 485.0
Executed 2 tests, with 32 failures (0 unexpected)

review1-before-report.log:
XCTAssertFalse failed - The report must not advertise an obsolete record ceiling
XCTAssertTrue failed - The notice explains the configured metric lifetime
Executed 1 test, with 2 failures (0 unexpected)
```

The fixed storage control passed **11/11, zero skips**, including both opt-in
galleries (`review1-fixed-storage-routes.log`). All six follow-up mutations
compiled and failed their intended assertions (exit 65); the original files
were restored after each run:

| Mutation log | Removed behavior | Regression | Failed tests / assertions |
| --- | --- | --- | ---: |
| `review1-mutation-source.log` | Actual-source readability check | `testSessionMemoryCompletionKeepsRawStateAndOffersTheLatestResponse` | 1 / 14 |
| `review1-mutation-growth.log` | Actual response retained byte count | same memory regression | 1 / 2 |
| `review1-mutation-route.log` | Wait for the new row's metadata before switching Raw sources | same memory regression | 1 / 2 |
| `review1-mutation-parts.log` | Collapse overflowing part tabs | `testRawToolbarFitsEveryPartAtNarrowAndMinimumPaneWidths` | 1 / 16 |
| `review1-mutation-search.log` | Shrink search before collapsing | same toolbar regression (740-point case) | 1 / 2 |
| `review1-mutation-notice.log` | Correct retention wording | `testPrepareQueriesTheArchiveAndBrushNarrowsTheActiveSnapshot` | 1 / 2 |

Exact focused commands use the build root and lock wrapper documented above:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-inspector
# Failing first, then fixed controls / individual mutation checks as listed above.
"$PI_BUILD_ROOT/run-ui.sh" \
  -only-testing:PiAppTests/InspectorStorageTests/testSessionMemoryCompletionKeepsRawStateAndOffersTheLatestResponse \
  -only-testing:PiAppTests/InspectorStorageTests/testRawToolbarFitsEveryPartAtNarrowAndMinimumPaneWidths
"$PI_BUILD_ROOT/run-ui.sh" \
  -only-testing:PiAppTests/ReportPageTests/testPrepareQueriesTheArchiveAndBrushNarrowsTheActiveSnapshot
# Each mutation uses its single corresponding selector from those commands.
TEST_RUNNER_PI_APP_INSPECTOR_STORAGE_GALLERY="$PI_BUILD_ROOT/review1-gallery" \
  "$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorStorageTests
```

Gallery review: **32 generated images** under `review1-gallery/` were inspected.
The new `raw-toolbar/` folder contains 20 Request/Response images: light and
dark at standalone pane widths 1000, 700 and 485, plus full Inspector windows
at 1000×700 and the actual 700×520 minimum. Search, Copy, capture menu and
format controls fit; the full minimum window retains a scrollable response.
The existing 12 Headers, purged-body and tiny-cost scenes were regenerated and
inspected too. The geometry regression also covers 740 points, exercising the
search-shrink range, and every Raw part at the minimum content width.

Nearby sweep: the transient Raw source change above was the additional real
instance, fixed in `InspectorRawTab.refreshContent` and
`InspectorRequestModel.open`. No other capture invalidation path or stale
100,000-record claim remained in Inspector/Dashboard. No helper or wire code
changed; helper/wire/concurrent/acceptance suites remain outside this app-only
follow-up. No live captures, real user data, credentials or paid calls were used.

Final focused rerun commands (each invocation takes/releases the shared lock;
serial-lane classes run alone):

```sh
"$PI_BUILD_ROOT/run-ui.sh" \
  -only-testing:PiAppTests/InspectorDocumentCacheTests \
  -only-testing:PiAppTests/InspectorIndexTests \
  -only-testing:PiAppTests/InspectorRequestModelTests \
  -only-testing:PiAppTests/SubagentInspectorTests \
  -only-testing:PiAppTests/SubagentSteeringInspectorTests
TEST_RUNNER_PI_APP_INSPECTOR_STORAGE_GALLERY="$PI_BUILD_ROOT/review1-gallery" \
  "$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorStorageTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorNativeControlTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorNativeParityTests
"$PI_BUILD_ROOT/run-ui.sh" \
  -only-testing:PiAppTests/InspectorSummaryRequestTests \
  -only-testing:PiAppTests/InspectorFollowTests \
  -only-testing:PiAppTests/InspectorEntryPointTests \
  -only-testing:PiAppTests/InspectorWindowControlTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorExpandInPlaceTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorExpandPerformanceTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorOverviewDocumentGeometryTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorPerformanceTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/InspectorFrameTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/SideBudgetInspectorLifetimeTests
"$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/ReportPageTests
```

The final focused rerun passed **129/129 distinct tests across 19 classes**,
with zero failures and zero skips: **96 Inspector-related tests + 33 ReportPage
tests**. No unrelated test failed. Failing-first runs, mutation runs and repeated
controls are excluded from that total.

| Class | Passed/total | Final text log |
| --- | ---: | --- |
| InspectorDocumentCacheTests | 3/3 | `review1-final-models.log` |
| InspectorIndexTests | 11/11 | `review1-final-models.log` |
| InspectorRequestModelTests | 7/7 | `review1-final-models.log` |
| SubagentInspectorTests | 7/7 | `review1-final-models.log` |
| SubagentSteeringInspectorTests | 6/6 | `review1-final-models.log` |
| InspectorStorageTests | 11/11 | `review1-final-storage-gallery.log` |
| InspectorNativeControlTests | 12/12 | `review1-final-controls.log` |
| InspectorNativeParityTests | 7/7 | `review1-final-parity.log` |
| InspectorSummaryRequestTests | 5/5 | `review1-final-pages.log` |
| InspectorFollowTests | 2/2 | `review1-final-pages.log` |
| InspectorEntryPointTests | 7/7 | `review1-final-pages.log` |
| InspectorWindowControlTests | 1/1 | `review1-final-pages.log` |
| InspectorExpandInPlaceTests | 8/8 | `review1-final-expand.log` |
| InspectorExpandPerformanceTests | 2/2 | `review1-final-expand-performance.log` |
| InspectorOverviewDocumentGeometryTests | 1/1 | `review1-final-overview-geometry.log` |
| InspectorPerformanceTests | 2/2 | `review1-final-performance.log` |
| InspectorFrameTests | 2/2 | `review1-final-frame.log` |
| SideBudgetInspectorLifetimeTests | 2/2 | `review1-final-budget-lifetime.log` |
| ReportPageTests | 33/33 | `review1-final-report-gallery.log` |


The notice's native `ShellNote`/PiKit card was also captured from the prepared
controller's actual text at 1000, 700 and 485 points, light and dark. All six
images in `review1-gallery/report-notice/` were inspected: the complete wording
wraps without clipping. The full ReportPage class was rerun with that capture
enabled and passed **33/33, zero skips** (`review1-final-report-gallery.log`):

```sh
TEST_RUNNER_PI_APP_REPORT_NOTICE_GALLERY="$PI_BUILD_ROOT/review1-gallery/report-notice" \
  "$PI_BUILD_ROOT/run-ui.sh" -only-testing:PiAppTests/ReportPageTests
```

This brings the reviewed follow-up gallery to **38 images**. The final regenerated
minimum-window Request/Response scenes were inspected again in both appearances.
No clone directories remained in this workstream's build root. All three requested
corrections and the adjacent transient-route instance are resolved; nothing is
left for an owner decision. No merge, release or shared-branch push was performed.
