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


## Round-2 review: per-body availability

The review is confirmed. Capture Off changes `observedBytes` without making
any retained body unavailable. A credential-omitted Request likewise must not
retire a readable memory Response when the row moves to the archive. Availability
and Raw invalidation revisions are now tracked separately for Request and
Response. Links pagination is independent of body invalidation, including
an explicit Clear. Events belong to Response and refresh when that capture is
retired; `PayloadArchive.evict` deletes event indices but preserves message links. Request loss clears Conversation/delta only; Response loss
clears Response only. Only the task reading the affected body is cancelled.

Failing-first evidence used generated bodies and an archive with 260 generated
message links. `review2-before-storage.log` ran against `ae26ae78` production:
**3 tests failed, 20 assertions, zero unexpected errors**. The earlier
`review2-before.log` had a fixture error (missing required `turnId`); this was
corrected before collecting the evidence below. No production fix was applied
until both requested regressions failed for their intended reasons.

| Regression | Failing-first excerpt | Result |
| --- | --- | --- |
| `InspectorStorageTests.testCaptureOffStreamingKeepsRawLinksPagination` | revision `2` vs `1`; “Links must stay on rows 129–256”; “Copy must still use the selected links page” | Confirmed: metadata polling reset Links to row 1. |
| `InspectorStorageTests.testCredentialOmittedRequestCompletionPreservesReadableResponse` | `combined` vs `hex`; response bytes `0` vs `868`; partial document `nil` vs `true` | Confirmed: completion discarded the selected readable prefix. |
| `InspectorStorageTests.testLosingOneBodyPreservesTheOtherDocumentAndCopySource` | old view identity lost; `combined`/`json` vs `hex`; the other parsed document became nil | Nearby instance: actual loss of either body retired both. Both directions are covered. |
| `InspectorRequestModelTests.testLosingHelperMemoryRetiresAResponseWithUnchangedArchiveMetadata` | retained response was not nil; `868` vs `0` | Self-review finding: the archive stays `not-retained` across helper-memory loss, so descriptor inequality missed a real loss. `review2-before-memory-loss.log`: 1 test, 2 failed assertions. |

The self-review also deliberately delayed the initial metadata read while Raw
loaded a readable prefix. The first per-body implementation failed
`InspectorStorageTests.testRawBodyReadBeforeFirstMetadataStillRetiresWhenLost`:
Copy stayed enabled and the 868-byte document stayed mounted after the first
metadata record reported the loss (`review2-fixed-storage.log`: 12 passed,
2 opt-in gallery skips, 1 test with 2 failed assertions). This was an intermediate
regression caught before commit. Body readers now establish availability from their source metadata, before
parsing; stale Raw callbacks are fenced by body identity and its revision. The original two regressions and the one-body-loss test already passed
in that run. The full request-model class passed 8/8 in `review2-fixed-model.log`.

The next review pass added the inverse ordering: source bytes read successfully,
then a purge while parsing was held on the capture worker. A completion-only
availability notification was too late: `testPurgeDuringFirstRawParseCannotPublishTheBody`
failed twice, leaving the old body copyable. It now passes with source-metadata
observation before parsing. The same run confirmed that Events, unlike Links,
must retire with Response: `testClearingResponseRetiresItsRawEventIndex` failed
twice because the deleted event index remained displayed/copyable. Response
revision changes now refresh only that page; its Copy path also checks the
revision before the observer refresh runs. `review2-fixed-storage-race.log`:
**15 passed, 2 tests failed with 4 assertions, zero skips**. These intermediate
regressions were caught by the self-review before commit. With both corrections,
`review2-fixed-complete.log` passed **17/17**, including both gallery tests.
The cancelled sibling-probe control passed in the expanded request-model class:
**9/9** (`review2-fixed-model-race.log`).

### Adversarial review of the whole branch

Reviewed the full branch diff with `git diff origin/dev/next...HEAD` and the
direct comparison `git diff origin/dev/next HEAD --` for every production file
changed by this branch, then the final working-tree comparison `git diff
origin/dev/next --` for those files. `origin/dev/next` was initially fetched at
`5c52621c` and refreshed at the final audit to `daade17e` (common base `141666ca`).
None of the seven production files changed upstream between those references;
`review2-audit-final.diff` records the complete final comparison. The direct whole-tree comparison also shows other workstreams'
commits absent from this branch; those files were not edited or reverted. The
branch remains isolated for the lead's merge.

The table lists the inputs that take a different branch for each changed
production condition (related arithmetic guards are grouped). Unchanged request
polling and task-generation guards were checked at their new call sites too.

| Changed condition / branch | Inputs now taking the other branch; intended behavior and evidence |
| --- | --- |
| `PiChartTicks.numberStep`: positive finite `step` | Underflowed zero and overflowed infinite candidate scales are skipped. Finite candidates and ordinary ticks keep their prior scoring. Subnormal-to-maximum tests and numeric parity evidence above cover the endpoints. |
| `numberStep`: `count` in 2…12 before integer conversion; finite `count * step` | NaN/infinite counts no longer reach `Int`; overflowing candidate domains are skipped. If no candidate fits, the accepted finite `top` is the fallback. The former 2…12 restriction remains. |
| `multiples`: finite step and finite first/last | Infinite step returns the lower bound; overflowed multiples return no ticks. Bounded integer iteration replaces floating stride, which cannot reliably advance at huge indices. Zero/negative step and the 10,000-tick bound keep their previous behavior. |
| `multiples`: finite, contained tick filter | Rounding may push a boundary tick outside its domain; such ticks are omitted. Valid interior ticks are unchanged. |
| `automaticDomain`: finite, ordered input | Nonfinite or reversed inputs resolve to 0…1 before constructing a range. Accepted finite input remains on the numeric path. |
| Off-zero domain: finite rounded endpoints, `min`/`max` with data bounds | Overflowed or inward-rounded endpoints use the original finite bound; valid outward rounding remains. Both positive and negative domains are covered. |
| Zero-based domain: finite rounded upper/negative extent, outward clamps | Extreme rounding cannot construct an invalid range or exclude the data. Positive, all-negative and mixed-sign branch selection is unchanged. Cost values are nonnegative; the generic tick tests also cover negatives. |
| `clean`: finite positive multiplier/product and finite rounded result | Tiny numbers whose multiplier overflows and extreme numbers whose final rounding overflows retain their original finite value. Ordinary rounding and the zero/nonfinite early return are unchanged. |
| `DashboardQuery.dashboard`, `requestPage`, `sessionSummaries`: `offset >= 0` | Offsets above 100,000 are accepted. Negative offsets still fail; SQL retains 128/64 row limits and the same identity/status predicates. `Int.max` yields an empty page. Returned count cannot exceed remaining records, so `offset + count` is bounded. Reads use the existing snapshot transaction; sibling additions/removals do not bypass it. |
| `MenuBarMetrics.usageMetrics`: nonnegative aligned offset | Aligned offsets above 100,000 are accepted; negative/unaligned offsets still fail. The 24-row limit, date validation, cancellation and physical/family scope predicates remain. The 100,009-route fixture covers menu and Inspector usage paths. |
| `InspectorRequestModel.open`: mark metadata pending on source/outcome change | A same-attempt live/log or running/settled transition waits for its own descriptors before Raw changes route. Same source/outcome refreshes retain existing state. A new attempt already clears metadata/documents and now also clears its availability history. |
| Request `refresh`: active guard | An active completed/idle request rereads descriptors even without a row change, detecting purge/expiry. Hidden or deselected requests read nothing; `.record` rows still do not fetch capture metadata. |
| Per-body readability check | Readable archive/live states establish availability. Unreadable archive states probe the actual source: memory may still be readable. Off/credential-omitted/unavailable-to-unavailable changes retire nothing; readable-to-unreadable retires that body even if the archive descriptor is unchanged. |
| Response growth from a readable source | A completed memory row with `not-retained` archive bytes takes its latest byte count from helper memory. Its loaded prefix remains until Load latest; capture Off cannot acquire readable bytes through this branch. |
| Availability probe cancellation/generation/attempt guards | After each asynchronous source read, a cancelled/hidden/superseded read cannot invalidate or publish into the next selected request. `testCancelledAvailabilityProbeCannotRetireASiblingResponse` suspends a child-a probe, loads child-b, then delivers the old loss. The existing physical session source and same-session predecessor restrictions remain; sibling work does not share availability history. |
| `invalidateBody`: active tab matches affected kind | Only loss of Request cancels Conversation/delta work; only loss of Response cancels Response work. Raw stops the affected body itself. Losing an unrelated body leaves a readable partial Response, Raw format and Copy source intact. |
| Request-vs-Response retirement | Request loss resets Conversation/delta; Response loss resets Response/byte count. Explicit Clear calls both even if no descriptor was previously loaded, fencing pending copies. |
| `source`: provided descriptors may be used before `metadataLoaded` | Only the availability probe can use its just-read metadata while publication is pending. The workspace, ready helper and physical session checks still apply; no helper is started to recover a missing body. |
| Successful body read: same attempt, matching Raw body identity/revision | Readable source metadata now establishes availability before parsing, even if the Inspector metadata poll is still pending. The observing wrapper requires a live model, uncancelled task, same attempt and same body revision; unavailable descriptors establish nothing. Page/whole reads and source routing remain unchanged. Late callbacks from a replaced or invalidated body cannot establish availability or restore its Copy source. Parsed reads are cancellation-checked before publication. The delayed-first-metadata test covers the newly discovered ordering. |
| Raw: affected mounted body's revision differs | Only that body view is stopped/replaced; a cached body is retired even while Links/Events is selected. An unrelated body's revision cannot reset Raw. Row/part navigation still resets its own page; body invalidation no longer resets Links. Response invalidation refreshes Events because its index is deleted with that body; Request-only loss leaves Events alone. |
| Raw route change also requires loaded metadata | A transient log row with the previous live descriptors no longer triggers archive/live reloads. Actual persistent handoff still changes route after its descriptors arrive; memory completion preserves its live route. |
| Events revision and Copy checks | Response revision changes reset only Events, whose archive indices are deleted with the response. Links remain. Before the queued view refresh, an old Events page supplies no copy text; Request-only loss does not affect it. |
| Raw Copy revision checks before/after rendering | A purged body's pending copy cannot publish. The other body's revision cannot cancel a readable copy. Existing body/metadata/header/page selection still chooses the representation. |
| `copyText` switch, nonempty header sections, nonempty text guard | Headers now use exactly the displayed masked header text. Empty Headers/Links no longer enable Copy because unrelated metadata exists, and an empty copy does not clear the clipboard. Metadata, Events and nonempty Links retain their own representations. |
| Part-menu weak-self guard, current-part selection and fallback title | A released view supplies no menu; a live view lists the same six parts with the current part checked. The fallback Request title only applies if no matching part is found; every enum case is present. |
| Toolbar collapse threshold and selector choice | At insufficient width, the six tabs become the existing PiKit menu; at sufficient width they remain tabs. Request/Response reserve search width; the other parts do not. Search shrinks between its prior preferred size and 120 points; the selected menu width is measured. Geometry and light/dark galleries cover 1000, 740, 700 and minimum 485-point panes plus actual minimum windows. |

The state cross-check is explicit: streaming readable bodies keep their chosen
prefix; Off streaming changes only observations; idle and paused requests refresh
without forced body replacement; memory completion checks helper availability;
persistent completion still hands off to the archive; helper restart retires lost
memory but preserves readable archive captures; cancellation/hidden windows cannot
publish late reads; and concurrent sibling work keeps physical session and
attempt identities. No permission, tool, vault, retention or capture policy was
changed. The report notice is a wording correction with no changed condition.
Test-only fixture branches and opt-in gallery guards affect generated validation
only; generated project changes only register the new test file.

### Round-2 validation results

The 32 regenerated images in `review2-gallery/` were inspected: light/dark
Request/Response at 1000, 700 and 485-point panes, actual 1000 and minimum 700×520
Inspector windows, Headers, purged bodies and the tiny-cost chart. Copy/menu/search
fit; the purged view has no old body and Copy is disabled. Contact sheets
`review2-contact-1.png` through `review2-contact-8.png` retain the visual review.

All commands ran from this worktree, with
`PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-inspector`.
The `run-ui.sh` wrapper printed above owns/releases the shared lock for each
invocation. No serial-lane class was mixed with another class.

Failing-first and intermediate control commands (each selector is prefixed by
`-only-testing:PiAppTests/`):

| Text log | Invocation after `"$PI_BUILD_ROOT/run-ui.sh"` |
| --- | --- |
| `review2-before-storage.log` | `InspectorStorageTests/testCaptureOffStreamingKeepsRawLinksPagination`, `InspectorStorageTests/testCredentialOmittedRequestCompletionPreservesReadableResponse`, `InspectorStorageTests/testLosingOneBodyPreservesTheOtherDocumentAndCopySource` |
| `review2-before-memory-loss.log` | `InspectorRequestModelTests/testLosingHelperMemoryRetiresAResponseWithUnchangedArchiveMetadata` |
| `review2-fixed-model.log`, `review2-fixed-model-race.log` | `InspectorRequestModelTests` |
| `review2-fixed-storage.log` | `InspectorStorageTests` (gallery opt-in absent; 2 expected skips) |
| `review2-fixed-storage-race.log`, `review2-fixed-complete.log` | `InspectorStorageTests`, with `TEST_RUNNER_PI_APP_INSPECTOR_STORAGE_GALLERY="$PI_BUILD_ROOT/review2-gallery"` |

Mutation checks all compiled and failed the intended executed tests (exit 65),
then restored production files. **10 variants caught; 12/12 selected test
executions failed, 34 failed assertions, zero unexpected errors**. Each invocation
was `"$PI_BUILD_ROOT/run-ui.sh"` with the following selectors, each prefixed by
`-only-testing:PiAppTests/`. Log names are `review2-mutation-<variant>.log`.

| Variant / key line broken | Test selectors | Failed tests / assertions |
| --- | --- | ---: |
| `descriptor`: restore descriptor inequality instead of prior readability | `InspectorStorageTests/testCaptureOffStreamingKeepsRawLinksPagination`; `InspectorStorageTests/testCredentialOmittedRequestCompletionPreservesReadableResponse` | 2 / 2 |
| `blanket`: retire both bodies when one is lost | `InspectorStorageTests/testLosingOneBodyPreservesTheOtherDocumentAndCopySource` | 1 / 10 |
| `unchanged`: require a changed descriptor to detect loss | `InspectorRequestModelTests/testLosingHelperMemoryRetiresAResponseWithUnchangedArchiveMetadata` | 1 / 2 |
| `raw-body`: let any body's revision discard the mounted Raw body | `InspectorStorageTests/testLosingOneBodyPreservesTheOtherDocumentAndCopySource` | 1 / 8 |
| `raw-pages`: reset unrelated pages on body revision changes | `InspectorStorageTests/testCaptureOffStreamingKeepsRawLinksPagination` | 1 / 1 |
| `copy`: remove the post-render revision fence | `InspectorStorageTests/testACopyAlreadyRenderingCannotPublishAfterClear` | 1 / 1 |
| `early-read`: stop recording availability at source metadata reads | `InspectorStorageTests/testRawBodyReadBeforeFirstMetadataStillRetiresWhenLost`; `InspectorStorageTests/testPurgeDuringFirstRawParseCannotPublishTheBody` | 2 / 4 |
| `events`: stop refreshing Events on Response retirement | `InspectorStorageTests/testClearingResponseRetiresItsRawEventIndex` | 1 / 2 |
| `events-copy`: permit copying an event page before its invalidation refresh | `InspectorStorageTests/testClearingResponseRetiresItsRawEventIndex` | 1 / 1 |
| `cancelled-probe`: remove the guard immediately after the awaited source check | `InspectorRequestModelTests/testCancelledAvailabilityProbeCannotRetireASiblingResponse` | 1 / 3 |

Final focused rerun commands (all after restoring production):

```sh
"$PI_BUILD_ROOT/run-ui.sh" \
  -only-testing:PiAppTests/InspectorDocumentCacheTests \
  -only-testing:PiAppTests/InspectorIndexTests \
  -only-testing:PiAppTests/InspectorRequestModelTests \
  -only-testing:PiAppTests/SubagentInspectorTests \
  -only-testing:PiAppTests/SubagentSteeringInspectorTests
TEST_RUNNER_PI_APP_INSPECTOR_STORAGE_GALLERY="$PI_BUILD_ROOT/review2-gallery" \
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
"$PI_BUILD_ROOT/run-ui.sh" \
  -only-testing:PiAppTests/DashboardTests \
  -only-testing:PiAppTests/PiChartTicksTests \
  -only-testing:PiAppTests/MenuBarMetricsTests
```

The final matrix passed **189/189 tests across 22 classes**, zero failures and
zero skips: **104 Inspector-related, 33 Report, 19 Dashboard, 29 MenuBarMetrics
and 4 chart tick tests**. Failing-first runs, mutations and repeated controls are
excluded. No unrelated test failed. `review2-checks-summary.log` ends with
`Failed: []`.

| Class | Passed/total | Final text log |
| --- | ---: | --- |
| DashboardTests | 19/19 | `review2-final-chart-pagination.log` |
| InspectorDocumentCacheTests | 3/3 | `review2-final-models.log` |
| InspectorEntryPointTests | 7/7 | `review2-final-pages.log` |
| InspectorExpandInPlaceTests | 8/8 | `review2-final-expand.log` |
| InspectorExpandPerformanceTests | 2/2 | `review2-final-expand-performance.log` |
| InspectorFollowTests | 2/2 | `review2-final-pages.log` |
| InspectorFrameTests | 2/2 | `review2-final-frame.log` |
| InspectorIndexTests | 11/11 | `review2-final-models.log` |
| InspectorNativeControlTests | 12/12 | `review2-final-controls.log` |
| InspectorNativeParityTests | 7/7 | `review2-final-parity.log` |
| InspectorOverviewDocumentGeometryTests | 1/1 | `review2-final-overview-geometry.log` |
| InspectorPerformanceTests | 2/2 | `review2-final-performance.log` |
| InspectorRequestModelTests | 9/9 | `review2-final-models.log` |
| InspectorStorageTests | 17/17 | `review2-final-storage-gallery.log` |
| InspectorSummaryRequestTests | 5/5 | `review2-final-pages.log` |
| InspectorWindowControlTests | 1/1 | `review2-final-pages.log` |
| MenuBarMetricsTests | 29/29 | `review2-final-chart-pagination.log` |
| PiChartTicksTests | 4/4 | `review2-final-chart-pagination.log` |
| ReportPageTests | 33/33 | `review2-final-report.log` |
| SideBudgetInspectorLifetimeTests | 2/2 | `review2-final-budget-lifetime.log` |
| SubagentInspectorTests | 7/7 | `review2-final-models.log` |
| SubagentSteeringInspectorTests | 6/6 | `review2-final-models.log` |

The final gallery rerun again passed both opt-in tests; the minimum-window
Request/Response scenes were rechecked after regeneration. The Debug frame fixture loaded the 5 MB Conversation in 440 ms, its Response
in 12 ms, and Raw with 0 ms measured preparation (`review2-final-frame.log`).
No clone directories remained under this workstream's build root; no extra DerivedData was created.

Self-review outcome: the two reported scenarios are fixed. The review also
confirmed lost memory behind unchanged archive metadata and caught two ordering
cases in the intermediate implementation (before/during the first Raw parse),
plus the need to retire Response event indices while preserving Links. All have
regression and mutation evidence above. The cancelled sibling availability probe
also passes its control and fails its mutation. No other defect was confirmed in
the branch's changed conditions; no owner decision remains pending.

No helper or wire behavior changed, so helper/wire/concurrent/acceptance suites
were not rerun for this app-only follow-up. All data was generated; no installed
app, real preferences/chats/credentials, Keychain, live capture or paid provider
was used. Only the workstream branch is committed/pushed; the lead owns the merge
and merged full gate.


## Round 2 hunt

Baseline: `6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1` (the earlier
Inspector branch merged into `origin/dev/next`), continuing on
`dev/a130-inspector`. All commands below run from this worktree with
`B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-inspector`.
Only generated captures, temporary databases, an in-memory vault and generated
helper replies are used. No installed app, real preferences, real credentials,
real chats, Keychain, live capture or paid provider is involved.

### INSPECTOR-STORAGE-1 — confirmed and fixed

Both retention queries materialised every eligible ID through `CaptureDatabase.rows`.
Its 100,001-row result bound rejects row 100,002 before either loop can process
anything. Capture Off still creates durable metadata rows and can reach this
limit without retaining a body. The fix pages both queries in ID order, at
most `PayloadArchive.maintenanceBatch` (512) rows each, inside the existing
single transaction. The cursor advances to the last *queried* ID, including
leased IDs. Body eligibility uses an indexed existence lookup of references;
expiry predicates, lease protection, tombstones and reconciliation scheduling
are unchanged.

Regression tests in `PayloadArchiveTests`:

- `testShorteningMetricRetentionExpiresMoreThanOneHundredThousandOffRequests`
  seeds 100,002 completed Off attempts within 90-day retention, advances two
  days, shortens metric retention to one day, verifies all old metrics expire,
  accepts a new completed attempt, reopens, and reads both dashboard and
  Inspector rows.
- `testLargeBodyAndMetricRetentionSweepsAdvancePastExportLeases` seeds 100,002
  completed captures sharing generated body bytes, holds an export lease on
  the first ID, and shortens both retention windows. All later bodies/metrics
  expire while that export remains exact. Releasing the lease expires the
  deferred record on the next sweep. No maintenance batch exceeds 512 rows.

Failing first, before production edits (`hunt2-retention-before.log`):

```text
The retention sweep must pass a leased first ID and expire 100,001 later captures: quota
Shortening retention for 100,002 Off requests failed: quota
Executed 2 tests, with 2 failures (0 unexpected)
```

The same two tests pass after the fix (`hunt2-retention-fixed.log`): 2/2,
0 failures, 42.042 seconds including fixture creation, export, reopening and
report reads. Two earlier compile attempts only corrected missing `profileID`
and `await` in the new Inspector fixture; their logs are
`hunt2-before-compile.log` and `hunt2-before-compile2.log`, not failing-first
evidence.

Mutation checks (`hunt2-retention-mutations.py`, source restored after each):

| Mutation | Regression | Result |
| --- | --- | --- |
| Restore the unbounded metric query | 100,002 Off attempts | Failed with `quota` (1 assertion) |
| Restore the unbounded body query | Large leased sweep | Failed with `quota` (1 assertion) |
| Remove the metric lease exclusion | Large leased sweep | Failed: leased metrics were expired |

Logs: `hunt2-mutation-retention-{metrics,bodies,lease}.log`; all three mutations
were caught. The existing single-commit, independent retention and lease tests
are included in the final full class run below.


### INSPECTOR-STORAGE-2 — confirmed and fixed

A completed durable index row is not evidence that its payloads are durable.
`TraceStore.saved` deliberately keeps memory bodies and event indices in the
helper; only an acknowledged persist-mode handoff sets `savedToLog` and releases
those buffers. Raw now checks that ownership signal for Events and retained-byte
export. The completed archive row still supplies request identity/metrics.
No helper protocol, retention policy, masking rule, or body-view state changes.

`InspectorStorageTests.checkCompletedCaptureActions` finishes an actual generated
archive attempt, merges its completed row with a live row, uses the real Raw
Events page and capture-menu export action, and checks both exact binary files
and 128-entry event pages. A test-only `HostSupervisor.commandSender` supplies
generated debug replies matching `TraceStore`'s memory/persist/Off contracts;
the built helper only performs its isolated startup handshake. Every debug
command must name physical session `child`, even though the Inspector belongs
to `parent`. Export confirmations and destination selection use existing test
seams, then the production exporter performs its normal file writes and checks.

Failing first (`hunt2-inspector-before.log`, before the routing change):

```text
testCompletedMemoryCaptureExportsBodiesAndReadsHelperEvents:
  total Optional(0.0) is not equal to Optional(260.0)
  The helper's retained Events must have a second page
  false is not equal to true - memory request export availability
  false is not equal to true - memory response export availability
testCompletedOffCaptureReadsHelperEventsWithoutInventingBodies:
  total Optional(0.0) is not equal to Optional(260.0)
  The helper's retained Events must have a second page
```

The full log also contains the expected event-array mismatches: memory failed
five assertions and Off failed three. The persisted control fixture initially
sent a generated request as one packet larger than 32 KiB and threw `sequence`;
that fixture was corrected to use the existing 32 KiB packet contract. It is
not a product finding and is not counted as a reproduced regression.

The first routing fix passed memory, Off, persisted, expired-metadata and
stopped-helper cases. Its adversarial audit reproduced three timing failures
(`hunt2-inspector-routing-and-audit-before.log`: 8 tests, 5 passed, 3 expected
failures, 0 unexpected):

| Regression | Failing-first evidence | Correction |
| --- | --- | --- |
| `testEventsFollowTheArchiveHandoffDuringTheRead` | `failed - the Events page` | An explicit `capture_saved` reply switches this read to the archive |
| `testExportFollowsTheArchiveHandoffDuringTheRead` | `failed - the export manifest` | The exporter removes its incomplete staging directory, then reads the acknowledged archive |
| `testMemoryExportKeepsItsSessionWhenSelectionChangesInTheChooser` | `failed - the export manifest` | Capture the original row's physical session before presenting the chooser |

After those corrections the entire `InspectorStorageTests` class passed 25/25
with both gallery methods enabled (`hunt2-inspector-fixed.log`). Subsequent
source-lookup failure checks and the final full-class results are recorded below.

Nearby instances fixed separately:

- Completed capture-Off requests retain event indices for their latest helper
  attempt (`TraceStore.saved` does not set `savedToLog` for Off). Those Events
  now come from the helper; export still produces no invented body files.
- A persist-mode request may have finished its payload handoff while its index
  row is still live. The same ownership check selects the archive in that
  direction too; the two explicit handoff tests cover a handoff during reading.
- Switching to a sibling while a retained-byte export chooser is open no longer
  changes the selected export's physical session. Event reads also keep the
  captured row's session across the asynchronous ownership check.

Other nearby findings left unchanged under the shared scope rule at that point
(now resolved in [the review follow-up](#round-2-hunt-review-follow-up)):

- `PayloadArchive.swift:640` (`clear(sessionID:)`): 100,002 attempts in one chat
  still exceed `CaptureDatabase.rows` before clear can purge any capture.
- `PayloadArchive.swift:666` (`reserve(_:)`): more than 100,001 completed attempts
  with references still exceed that reader's result bound before quota eviction
  can free space. This is the separate quota-eviction selector, not retention.
- `PayloadArchive.swift:511` (`eventIndices`): the boundary description still
  claims the removed 4,096-per-request/100,000-global event caps. The existing
  `testTheLogKeepsWhatUsedToBeCapped` stores 5,000 event indices.

These are static findings from their unbounded SQL/text and the existing row
reader/cap regression, not claims of additional runtime fixes. No owner product
decision is needed for either assigned finding.

### Adversarial review of the new diff

The review compared only this round's changes with `origin/dev/next` at
`6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1`. Besides the two handoff races and
chooser/session race above, it found that swallowing an ownership-query error
could recreate the successful empty memory export. Two more regressions were
run before correcting that path (`hunt2-inspector-probe-before.log`):

```text
testMemoryExportDoesNotClaimSuccessWhenOwnershipLookupFails:
  XCTAssertFalse failed - A failed ownership query cannot publish a successful empty memory export
  XCTAssertTrue failed
testPersistedExportRemainsReadableWhenOwnershipLookupFails passed
Executed 2 tests, with 2 failures (0 unexpected)
```

A ready helper's unknown lookup error now surfaces unless the archive actually
has a readable body. A confirmed `capture_unavailable`, an absent/stopped helper,
and readable persisted data preserve the existing archive fallback. The full
27-test storage class then passed with galleries enabled and is rerun after
mutation restoration in the final matrix below.

Every changed production condition and the newly selected states were checked:

| Condition/change | States taking the new path; intended result |
| --- | --- |
| Retention `id > after`, ordered `LIMIT 512` | Large eligible sets now continue across batches instead of hitting the reader quota. Valid IDs are nonempty UUIDs, so the initial empty cursor omits none. ID order changes no expiry policy. |
| Empty batch terminates each loop; advance before lease checks | A fully leased batch still advances; nonleased records behind it expire. Body and metric cursors restart independently. The large leased regression checks both selectors. |
| Body-reference `EXISTS` replaces `IN` | The same non-null attempt references qualify, using indexed per-attempt lookup without repeatedly materialising all references. No new body state qualifies. |
| Existing age, outcome and metric-retained predicates | Unchanged: running/streaming rows stay excluded; completed, cancelled, failed and interrupted rows expire by their original age. Idle or paused agent state does not alter archive eligibility. Independent body/metric retention and credential annotations survive. |
| Existing lease exclusions inside the new loops | Unchanged: an in-progress export keeps its bodies and metrics; releasing it schedules reconciliation again. The actor's synchronous transaction cannot interleave a sibling begin/finish during a sweep. Reopening and subsequent durable recording are exercised. |
| Live `savedToLog` replaces index provenance for Events/export | Completed memory and latest Off events use helper storage despite `.log`; a persist handoff can select the archive while the index still says `.live`. Unsaved persist remains in helper storage. Expired metric metadata no longer needs to reveal the original capture mode. |
| No workspace or stopped/missing host | Historical row/cached-descriptor fallback remains; no helper is started. Persisted bytes stay readable after shutdown. Missing memory bytes are not recreated. |
| Cached fallback requires the same request ID | Selecting a sibling cannot lend its `savedToLog` descriptor to the original row. The original row still supplies the physical session; a legacy row without one uses the Inspector scope as before. |
| Readable archived request **or** response after a failed source query | Persisted complete/partial/interrupted/truncated bodies remain exportable if the helper fails. A credential-omitted request does not hide a readable response. Normal archive publish/finish supplies the digest for retained prefixes; exporters still verify their bytes. |
| Explicit `capture_unavailable` versus another ready-helper error | Confirmed clearing/pruning/restart absence keeps the existing fallback. Unknown failures with no readable durable body now fail visibly, preventing a false successful memory export. The generated memory/persist failure tests check both sides. |
| Explicit `capture_saved` during Events/body reading | Only this acknowledged handoff retries in the archive. Other read/export errors remain errors; incomplete live-export staging is removed by the existing exporter. Both races have failing-first tests. |
| Cancellation checks around the new awaits | Cancelled page tasks stop before publishing or falling back. Existing page-key and task-cancellation guards remain. Streaming refresh, idle, pause and cancellation do not reset Raw format, pagination, or loaded partial bodies. Existing Off Links and memory-completion regressions still pass. |
| Captured physical session for asynchronous actions | Navigating to a concurrent sibling in the chooser no longer redirects the original export. Event reads also use the captured row. Existing consent, destination checks, capture boundaries and session authorization remain in force. |

No helper behavior, wire schema, quota policy, UI layout or production capture
path was enabled or changed. The audit's additional fixes are within the two
changed Raw action functions/source selector; unrelated archive selectors are
listed above instead of being folded into this workstream.

Inspector mutation checks (`hunt2-inspector-mutations.py`, production source
restored after each run):

| Mutation | Regression(s) | Result |
| --- | --- | --- |
| Restore archive-row Events routing | Completed memory and Off | 2 tests, 6 assertion failures |
| Restore archive-row export routing | Completed memory | 1 test, 2 assertion failures: both body files absent |
| Disable the Events `capture_saved` fallback | Events handoff | 1 test, 1 failure: Events page unavailable |
| Disable the export `capture_saved` fallback | Export handoff | 1 test, 1 failure: no export manifest |
| Read mutable `request.sessionID` after the chooser | Selection changes in chooser | 1 test, 1 failure: no export manifest |
| Treat unknown ownership errors as archive success | Memory ownership-query failure | 1 test, 2 assertion failures: empty successful export and no error notice |

All six variants failed for their intended assertion, with zero unexpected
failures. Logs: `hunt2-mutation-inspector-{events-source,export-source,
events-handoff,export-handoff,export-session,probe-error}.log`; summaries are
`hunt2-inspector-mutations-summary.log` and
`hunt2-inspector-mutations-remaining-summary.log`. Together with retention:
**9 mutation variants caught, 10 test executions, 17 assertion failures,
0 unexpected failures**. The compile-only session-mutation attempt below is
excluded from those counts.

### Commands and final validation

The retention failing-first/fixed command (logs `hunt2-retention-before.log`
and `hunt2-retention-fixed.log`):

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh \
  -only-testing:PiAppTests/PayloadArchiveTests/testShorteningMetricRetentionExpiresMoreThanOneHundredThousandOffRequests \
  -only-testing:PiAppTests/PayloadArchiveTests/testLargeBodyAndMetricRetentionSweepsAdvancePastExportLeases
```

The final archive/report/model command (`hunt2-final-data.log`):

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh \
  -only-testing:PiAppTests/PayloadArchiveTests \
  -only-testing:PiAppTests/CaptureGarbageCollectionTests \
  -only-testing:PiAppTests/TraceArchiveTests \
  -only-testing:PiAppTests/DashboardTests \
  -only-testing:PiAppTests/GatewayAccountingTests \
  -only-testing:PiAppTests/MenuBarMetricsTests \
  -only-testing:PiAppTests/InspectorIndexTests \
  -only-testing:PiAppTests/InspectorRequestModelTests
```

That run passed **135/135**, with zero failures or skips (85.414 seconds):

| Class | Passed | Failed / skipped |
| --- | ---: | ---: |
| PayloadArchiveTests | 33 | 0 / 0 |
| CaptureGarbageCollectionTests | 2 | 0 / 0 |
| TraceArchiveTests | 7 | 0 / 0 |
| DashboardTests | 19 | 0 / 0 |
| GatewayAccountingTests | 25 | 0 / 0 |
| MenuBarMetricsTests | 29 | 0 / 0 |
| InspectorIndexTests | 11 | 0 / 0 |
| InspectorRequestModelTests | 9 | 0 / 0 |

`$B/run-ui.sh` acquires the shared `full-lane.lock` with atomic `mkdir`, writes
the workstream owner, exports this build root and calls `scripts/test-macos.sh "$@"`;
its EXIT trap releases only its own lock. All Inspector window, gallery and
mutation runs use that wrapper. Classes marked `SerialTestLane` run alone.
The final UI commands are:

```sh
TEST_RUNNER_PI_APP_INSPECTOR_STORAGE_GALLERY="$B/hunt2-gallery" \
  "$B/run-ui.sh" -only-testing:PiAppTests/InspectorStorageTests
"$B/run-ui.sh" -only-testing:PiAppTests/InspectorNativeControlTests
"$B/run-ui.sh" -only-testing:PiAppTests/InspectorNativeParityTests
"$B/run-ui.sh" -only-testing:PiAppTests/SubagentInspectorTests
"$B/run-ui.sh" -only-testing:PiAppTests/SessionTimingTests
"$B/run-ui.sh" -only-testing:PiAppTests/TurnAccountingTests
```

All six final UI runs passed **92/92**, with zero failures or skips:

| Class | Passed | Failed / skipped | Test time (seconds) |
| --- | ---: | ---: | ---: |
| InspectorStorageTests (galleries enabled) | 27 | 0 / 0 | 10.935 |
| InspectorNativeControlTests | 12 | 0 / 0 | 5.462 |
| InspectorNativeParityTests | 7 | 0 / 0 | 35.970 |
| SubagentInspectorTests | 7 | 0 / 0 | 1.528 |
| SessionTimingTests | 26 | 0 / 0 | 116.342 |
| TurnAccountingTests | 13 | 0 / 0 | 15.928 |

Combined final validation: **227/227 tests in 14 classes**, zero failures and
zero skips. Failing-first runs, mutation runs and intermediate passing controls
are recorded separately above and are not added to this total.

Logs are `hunt2-final-{inspector-gallery,inspector-controls,inspector-parity,
subagent-inspector,session-timing,turn-accounting}.log`. Text logs are the
evidence; no named `.xcresult` bundle was requested. No helper source or wire
behavior changed, so helper, wire, concurrent and native acceptance suites were
not rerun in this workstream; the lead runs the merged full gate.

Gallery output: `$B/hunt2-gallery`, 38 PNGs, all inspected through ten contact
sheets. The six new memory Events/export scenes cover light/dark at 1000, 700
and 485-point content width (the minimum window's request pane). They show the
second event page, its pager, Copy/menu controls and export result. The existing
32 request/response, masked headers, purged-body and tiny-cost scenes were also
regenerated. The new fixture initially captured a transparent standalone Raw
view; it now wraps that view in the same opaque `FillView(.piContent)` used by
the host. This is a screenshot-fixture correction, not a production layout change.

Harness corrections are retained rather than counted as product failures:

- `hunt2-data-aborted-scheduler.log`: a duplicate own build was started while an
  earlier queued UI run acquired the lock. The new own build was immediately
  stopped before any test began. No other workstream process or lock was touched.
  Subsequent data and UI runs completed serially in this build root.
- `hunt2-mutation-inspector-export-session-compile.log`: the first session
  mutation left the now-unused local `sessionID`, and warnings-as-errors stopped
  compilation. The corrected mutation removes that unused declaration and is
  rerun; a compile failure is not counted as a caught mutation.

Final cleanup/checks: no clone directories remain under this workstream's build
root, no extra DerivedData copy was made, and `git diff --check` passes. All
owned full-lane locks were released. The only unresolved items are the separate
clear/quota selectors and stale Events-limit description listed above; both
assigned findings and the audit's related action races are fixed.

## Round 2 hunt review follow-up

Baseline: `10c653e6d4653b2695a80ab77d9b6f3f20a63f20`, continuing on
`dev/a130-inspector` without merging or fast-forwarding. `B` below is
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-inspector`. This follow-up
resolves the two review findings and the three explicitly assigned deferred
items. Fixtures use generated captures, temporary SQLite databases, generated
helper replies and an in-memory vault. The installed app, real preferences,
chats, credentials, Keychain and paid/live providers are not used.

### Metric-retention query work — confirmed and fixed

The previous ID cursor did bound result memory but did not bound repeated query
work. macOS SQLite chose `dashboard_window` and sorted the remaining eligible
set for every page. The strengthened
`PayloadArchiveTests/testShorteningMetricRetentionExpiresMoreThanOneHundredThousandOffRequests`
measures SQLite VM steps around shortening retention for 100,002 completed Off
attempts. Its allowance is 600 steps per fixture record, including expiry
updates, tombstones and maintenance, not a wall-clock timing threshold.

Failing first (`hunt2-review-archive-before.log`):

```text
PERF metric retention of 100,002 attempts: 139297326 VM steps
XCTAssertLessThan failed: ("139297326") is not less than ("60001200")
Each batch must seek past its cursor, not rescan and sort the remaining overdue set
```

The metric cursor now follows `(wall,id)`, supported by a partial index on
`(metrics_retained,wall,id)` for retained, non-running metrics. Including the
leading equality column matters: a native SQLite plan probe showed that an
index on just `(wall,id)` still lost to `dashboard_window`. The final plan is a
range seek on `attempts_expiring_metrics` with no temporary ordering tree.
Expiry predicates, export leases, transaction scope and tombstones are unchanged.
The fixed test uses **24,403,183 VM steps** and still verifies every old metric
expires, new captures are accepted, and Reports/Inspector work after reopening.

Mutation `metric-index` removes this index while retaining the bounded tuple
query. The same test fails at **276,423,509 VM steps** (1 assertion), proving a
bounded but inefficient query is detected. Source was restored afterward.

Nearby sweep: body retention already seeks in ID order and passes the added
100,002-row work assertion before the fix (13,403,460 steps; 13,403,462 with the
new indexes). Its query and behavior are left unchanged. The lease fixture now
measures body expiry separately before expiring metrics.

### Clearing a large chat — confirmed and fixed

`PayloadArchiveTests/testClearPagesMoreThanOneHundredThousandAttemptsWithoutChangingOtherSessions`
seeds 100,002 completed captures sharing generated bytes, plus a sibling chat
sharing the same chunk. Clearing must purge only the target bodies, preserve
all request metrics and the sibling's exact bytes, and use indexed bounded
pages. Failing first:

```text
Clearing 100,002 attempts failed: quota
```

`clear(sessionID:)` now seeks `(session,id)` pages of at most 512 inside one
transaction. A lease or writer encountered in a later page rolls back the
whole clear. File garbage collection runs after commit. The new
`testClearRollsBackEarlierPagesWhenALaterAttemptIsLeasedOrWriting` exercises both
busy conditions after the first page; it also passed before the change.
The fixed large fixture uses **11,003,331 VM steps and one commit**, below its
400-steps-per-record work allowance, with all 200,004 target body descriptors
purged and the sibling's reference intact.

Mutations:

- `clear-limit`: remove the query limit; the 100,002 fixture fails with `quota`.
- `clear-seek`: make the ID comparison non-indexable; the same fixture fails
  its work assertion at **60,724,750 VM steps**.
- `clear-atomic`: remove the outer transaction; the later-busy test fails two
  assertions because earlier refs/body states were changed.

All mutations were restored. Existing `evict` retains its lease/writer guards
and removes Events and body refs without deleting request metrics or links.

### Quota eviction in a large archive — confirmed and fixed

`PayloadArchiveTests/testQuotaEvictionPagesLargeArchivesAndStopsAsSoonAsSpaceIsAvailable`
seeds 100,002 completed attempts. An export leases the first of 100,001 attempts
sharing one chunk. The first 512 unleased attempts precede a unique chunk;
reclaiming that unique chunk makes room for a new 512-byte body. The remaining
later captures must stay retained. This forces multiple pages, tied timestamps,
a lease skip, shared-chunk protection and immediate stopping once space exists.

Failing first:

```text
PERF quota eviction through 513 of 100,002 attempts: 2201346 VM steps
XCTAssertEqual failed: ("Optional(\"partial\")") is not equal to ("Optional(\"complete\")")
XCTAssertEqual failed: ("Optional(0.0)") is not equal to ("Optional(512.0)")
```

The unbounded selector hit the reader quota before eviction; `finish` correctly
reported a partial capture, exposing the lost new body. The fix pages oldest
eligible attempts by `(wall,id)` using a partial completed-attempt index and an
indexed reference-existence check. Leased/running captures stay protected.
Eviction still checks physical room after each candidate rather than discarding
a whole batch. File deletion is not put inside a rollback-capable outer
transaction. The fixed fixture uses **123,661 VM steps** (allowance 1,000,000),
expires exactly 513 attempts, preserves the leased bytes and later captures,
and retains the new body exactly.

Mutations:

- `quota-limit`: remove the limit; the fixture again reports zero retained
  bytes/partial state and no evictions (5 failed assertions).
- `quota-index`: force the old wall/filter index; paging still returns correct
  records, but the query-work assertion fails at **3,607,940 VM steps**.

Both mutations were restored. Unlimited storage and the already-enough-room
return path remain unchanged.

### Events boundary description — confirmed and fixed

`PayloadArchiveTests/testTheLogKeepsWhatUsedToBeCapped` already retains and reads
5,000 events. It now also checks that their displayed boundary description does
not claim the obsolete 4,096/request or 100,000/global caps and still explains
expiry with bodies. Failing first, both removed-cap assertions fail. The fix
removes only that false claim. Mutation `events-description` restores the old
sentence and fails both assertions again.

The four archive items above were tested before production edits together:
6 tests, 4 failed tests / 9 failed assertions; the two lease/body-work controls
passed. After the fixes: **6/6 passed**, zero failures. The seven archive
mutations all failed their intended assertions, with no unexpected failures.
Logs are `hunt2-review-archive-{before,fixed}.log` and
`hunt2-review-mutation-{metric-index,clear-limit,clear-seek,clear-atomic,
quota-limit,quota-index,events-description}.log`; the driver is
`$B/hunt2-review-archive-mutations.py`.

### Helper-to-archive handoff races — confirmed and fixed

Six new `InspectorStorageTests` use the real Raw menu/exporter and Events pager
with generated helper replies. The fixture writes known request/response bytes
and 260 Events to a temporary archive, merges the completed `.log` row, and
places the handoff at the relevant helper command boundary. Hashes use the
helper's SHA-256 metadata shape and become null after saved acknowledgment.
Every command must address the selected child's physical session, not the
Inspector owner.

Failing first (`hunt2-review-inspector-before.log`), before changing the retry
logic:

```text
testEventsRecheckHandoffWhenHelperRecordWasPruned : failed - the Events page
testExportRechecksHandoffAfterTheLastBodyRead : failed - the export manifest
testExportRechecksHandoffWhenBodyRecordWasPruned : failed - the export manifest
testExportRechecksHandoffWhenVerificationRecordWasPruned : failed - the export manifest
Executed 6 tests, with 4 failures (0 unexpected)
```

The positive regressions cover `TraceError.changed` when `savedToLog`/hashes
change after the last body read, `capture_unavailable` during verification,
pruning during a body read, and pruning during an Events read. They check both
exact body files, the export manifest, and two exact Events pages.
`testChangedMemoryExportDoesNotRetryAnEmptyArchive` and
`testPrunedMemoryExportDoesNotRetryAnEmptyArchive` are negative controls: a log
row with no durable bytes must not turn an unconfirmed change/prune into a
successful manifest-only export. They verify failure and removal of staging.
Both controls passed before the fix.

Both Raw actions now share a narrow handoff retry check. `capture_saved` remains
an explicit acknowledgment. `changed` and `capture_unavailable` recheck the
helper's saved flag or readable archive descriptors. That recheck disables the
usual historical-row fallback: `.log` alone is not proof of a handoff. Other
errors and cancellation do not retry. The archive still enforces completed
outcome, physical session, leases and integrity checks; retry occurs only once.
No helper/wire behavior changes. All six tests pass afterward in
`hunt2-review-inspector-fixed.log` (6/6, zero failures).

### Adversarial condition review and nearby sweep

Reviewed the entire new production diff against `10c653e6`, including every
changed predicate, cursor, error branch and new guard. The concrete review
findings were the need for the metric index's leading equality column, atomic
rollback for clear, and confirmed ownership rather than `.log` fallback on a
retry. These are implemented and covered by work/rollback/negative tests; no
additional product bug was found or silently changed.

| Changed condition | States taking a different path; intended result |
| --- | --- |
| Metric `(wall,id)` cursor and partial index | Eligible rows are visited in timestamp/UUID order instead of UUID order. Equal timestamps remain distinct; the initial negative-infinity cursor admits every accepted finite timestamp. Leased rows advance the cursor without expiring. Running rows, metrics already expired, and timestamps at/after the cutoff still do not qualify. Cancelled, failed and interrupted requests keep their previous eligibility; idle/paused agent state does not change it. |
| Session/id clear pages and outer transaction | Large sessions now complete instead of hitting the result quota. Empty pages finish the pass. A writer or lease in a later page rolls back earlier edits; file collection occurs only after commit. The actor cannot interleave a sibling operation inside this synchronous transaction. Sibling sessions, metrics and message links remain untouched. |
| Quota tuple cursor and indexed `EXISTS` | The same completed attempts with refs qualify; `refs.attempt` is non-null, so `EXISTS` and `IN` have the same membership. Same-age ties now have deterministic UUID order (previously unspecified). Leased IDs are passed without eviction, running writers stay excluded, and each successful eviction still checks physical space before proceeding. Unlimited/enough-room paths and exhaustion errors are unchanged. |
| Nonempty-page/typed-key guards | An empty batch ends maintenance. App-created attempt IDs are nonempty UUIDs and wall values are numeric/non-null, so missing/mistyped cursor keys cannot arise from valid capture packets. Integer SQLite timestamps remain accepted through `.double`. Clear now uses the existing strict text reader rather than silently dropping a malformed ID. |
| Broader catch in Events/export | Only `changed` and `capture_unavailable` gain an ownership recheck. Explicit `capture_saved` still goes to the archive. All unrelated errors remain failures; cancellation is checked before rechecking or retrying, and Events retains its current-page/cancellation publication guards. |
| `requireConfirmation` gates fallback | Retry cannot succeed solely because a completed row is `.log`. A current helper saved flag or readable archive body descriptor permits it. Memory/Off captures with no durable bytes and an unavailable helper still fail; changed memory with helper ownership still fails. Initial historical reads retain the old stopped-helper behavior. A failed secondary lookup cannot manufacture bytes. |
| Archive retry once | Completion/acknowledgment/pruning races can use retained archive bytes; partial/purged/expired descriptors and archive integrity/lease/session checks still govern the result. Streaming exports remain blocked by the unchanged completed-outcome guards. Stopped helpers/restart use readable archive data. The selected physical session is captured before the chooser; sibling selection cannot retarget reads or exports. |

Body retention was checked with its own work bound and left unchanged. Both
Raw action callers use the same retry policy; the per-body rendering and
invalidation paths are unchanged, preserving partial responses and Off-stream
Links pagination. Event paging remains 128 rows, and chunk garbage collection
already uses bounded indexed pages. The previously deferred clear/quota/text
items are all handled in this follow-up. No owner decision is outstanding.

### Final validation commands and results

The archive failing-first/fixed group used this exact focused selection (logs
`hunt2-review-archive-before.log` and `hunt2-review-archive-fixed.log`):

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh \
  -only-testing:PiAppTests/PayloadArchiveTests/testShorteningMetricRetentionExpiresMoreThanOneHundredThousandOffRequests \
  -only-testing:PiAppTests/PayloadArchiveTests/testLargeBodyAndMetricRetentionSweepsAdvancePastExportLeases \
  -only-testing:PiAppTests/PayloadArchiveTests/testClearPagesMoreThanOneHundredThousandAttemptsWithoutChangingOtherSessions \
  -only-testing:PiAppTests/PayloadArchiveTests/testClearRollsBackEarlierPagesWhenALaterAttemptIsLeasedOrWriting \
  -only-testing:PiAppTests/PayloadArchiveTests/testQuotaEvictionPagesLargeArchivesAndStopsAsSoonAsSpaceIsAvailable \
  -only-testing:PiAppTests/PayloadArchiveTests/testTheLogKeepsWhatUsedToBeCapped
```

The Inspector failing-first/fixed group used `$B/run-ui.sh`, which acquires and
releases only its own shared full-lane lock, then calls `scripts/test-macos.sh`
with this build root:

```sh
"$B/run-ui.sh" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/InspectorStorageTests/testExportRechecksHandoffAfterTheLastBodyRead \
  -only-testing:PiAppTests/InspectorStorageTests/testExportRechecksHandoffWhenVerificationRecordWasPruned \
  -only-testing:PiAppTests/InspectorStorageTests/testExportRechecksHandoffWhenBodyRecordWasPruned \
  -only-testing:PiAppTests/InspectorStorageTests/testEventsRecheckHandoffWhenHelperRecordWasPruned \
  -only-testing:PiAppTests/InspectorStorageTests/testChangedMemoryExportDoesNotRetryAnEmptyArchive \
  -only-testing:PiAppTests/InspectorStorageTests/testPrunedMemoryExportDoesNotRetryAnEmptyArchive
```

Final data run (`hunt2-review-final-data.log`): **152/152 passed**, zero failures
or skips, 87.586 seconds. Exact command:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PayloadArchiveTests \
  -only-testing:PiAppTests/CaptureGarbageCollectionTests \
  -only-testing:PiAppTests/TraceArchiveTests \
  -only-testing:PiAppTests/DashboardTests \
  -only-testing:PiAppTests/GatewayAccountingTests \
  -only-testing:PiAppTests/MenuBarMetricsTests \
  -only-testing:PiAppTests/InspectorIndexTests \
  -only-testing:PiAppTests/InspectorRequestModelTests \
  -only-testing:PiAppTests/CaptureMacIntegrationTests \
  -only-testing:PiAppTests/SubagentCaptureTests
```

| Class | Passed | Failed / skipped |
| --- | ---: | ---: |
| PayloadArchiveTests | 36 | 0 / 0 |
| CaptureGarbageCollectionTests | 2 | 0 / 0 |
| TraceArchiveTests | 7 | 0 / 0 |
| DashboardTests | 19 | 0 / 0 |
| GatewayAccountingTests | 25 | 0 / 0 |
| MenuBarMetricsTests | 29 | 0 / 0 |
| InspectorIndexTests | 11 | 0 / 0 |
| InspectorRequestModelTests | 9 | 0 / 0 |
| CaptureMacIntegrationTests | 2 | 0 / 0 |
| SubagentCaptureTests | 12 | 0 / 0 |

The native SQLite plan probe uses generated in-memory tables only:

```sh
/usr/bin/sqlite3 :memory: < "$B/hunt2-review-query-plans.sql" > "$B/hunt2-review-query-plans.log"
```

macOS SQLite 3.43.2 reports indexed range seeks for metrics and quota, a covering
session/id seek for clear, and an indexed correlated refs lookup. None has a
temporary ordering tree. These plans supplement the actual archive VM-step
regressions; they are not substitutes for native tests.

Retry mutations (`hunt2-review-inspector-mutations.py`) all failed their intended
assertions, with no unexpected failures:

| Mutation | Regression(s) in InspectorStorageTests | Result |
| --- | --- | --- |
| `export-changed`: remove `TraceError.changed` from the recheck | `testExportRechecksHandoffAfterTheLastBodyRead` | 1 test, 1 failure: missing manifest |
| `pruned-handoff`: remove `capture_unavailable` from the recheck | `testExportRechecksHandoffWhenVerificationRecordWasPruned`, `testExportRechecksHandoffWhenBodyRecordWasPruned`, `testEventsRecheckHandoffWhenHelperRecordWasPruned` | 3 tests, 3 failures: missing exports/Events |
| `unconfirmed-pruned`: permit historical-row fallback during retry | `testPrunedMemoryExportDoesNotRetryAnEmptyArchive` | 1 test, 3 failures: an empty export was incorrectly published |
| `unconfirmed-changed`: accept `changed` without checking ownership | `testChangedMemoryExportDoesNotRetryAnEmptyArchive` | 1 test, 3 failures: an empty export was incorrectly published |

Each archive mutation runs `PI_BUILD_ROOT="$B" scripts/test-macos.sh
-only-testing:PiAppTests/PayloadArchiveTests/<named regression>`; each Inspector
mutation runs the corresponding `-only-testing:PiAppTests/InspectorStorageTests/<named regression>`
selection with `-parallel-testing-enabled NO` under the shared lock. The three
pruned-handoff tests are one focused run of that class. Mutation console logs
are `hunt2-review-mutation-<name>.log`; both mutation drivers restore their
original source in `finally`. The production diff was compared byte-for-byte
with `$B/hunt2-review-production.diff` after all mutations and matched.
Combined mutation result: **11/11 caught** (13 test executions, 23 intended
failed assertions), separate from passing validation counts.

Gallery output is `$B/hunt2-review-gallery`: **44 PNGs**, all inspected through
11 contact sheets. Six new persisted-Events/export scenes show the corrected
boundary text in light/dark at 1000, 700 and 485-point pane widths; it wraps
within the pane and Copy/menu/pager remain visible. The six Session-memory
Events/export scenes and 32 existing toolbar/body/header/purge/tiny-cost scenes
were regenerated and inspected too. The gallery fixture captures only normal
successful memory/persist cases; handoff/failure/expired/helper-stopped cases
remain behavioral tests. No production layout was changed in this follow-up.

The final native UI/capture run held the shared full-lane lock only for the
mutation/test batch, with an EXIT trap releasing its own lock. Each
`SerialTestLane` class ran alone. The driver was:

```sh
"$B/run-locked.sh" "$B/hunt2-review-ui-checks.sh"
```

After the restored-source mutations, it executed these commands sequentially
with `PI_BUILD_ROOT="$B"` exported:

```sh
TEST_RUNNER_PI_APP_INSPECTOR_STORAGE_GALLERY="$B/hunt2-review-gallery" \
  scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InspectorStorageTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InspectorNativeControlTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InspectorNativeParityTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentInspectorTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionTimingTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TurnAccountingTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CaptureDrainTests
```

All seven passed **104/104**, zero failures or skips:

| Class | Passed | Failed / skipped | Test time (seconds) |
| --- | ---: | ---: | ---: |
| InspectorStorageTests, galleries enabled | 33 | 0 / 0 | 13.417 |
| InspectorNativeControlTests | 12 | 0 / 0 | 5.686 |
| InspectorNativeParityTests | 7 | 0 / 0 | 36.426 |
| SubagentInspectorTests | 7 | 0 / 0 | 1.441 |
| SessionTimingTests | 26 | 0 / 0 | 118.355 |
| TurnAccountingTests | 13 | 0 / 0 | 15.943 |
| CaptureDrainTests | 6 | 0 / 0 | 8.057 |

Logs are `$B/hunt2-review-final-<Class>.log`; batch summaries are
`hunt2-review-{inspector-mutations,final-ui}.log`. Final validation is
**256/256 tests in 17 classes**, zero failures and zero skips. No unrelated test
failed. No helper source or wire contract changed, so the full helper and
wire/concurrent/acceptance suites were not rerun; the two loopback capture
integration tests and six native drain tests passed. The lead owns the merged
full gate.

No extra DerivedData copy or named `.xcresult` was created. Text logs are the
evidence. There are no test clone directories under this build root, all owned
full-lane locks were released, and `git diff --check` passes. Queued UI wrappers
were cancelled only while waiting for another owner's lock so independent data
checks could proceed; no native runs overlapped in this build root. No installed
app or real user data was opened. All five assigned items are fixed, with no
remaining finding or owner decision.
