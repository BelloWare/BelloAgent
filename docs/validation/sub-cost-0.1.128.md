# Sub-agent completion notifications and cost — 0.1.128

Stream: `sub-cost`, branch `dev/a128-sub-cost`. Worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-sub-cost`. Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost`.

## Scope and root causes

Owner requests 1 and 3 (2026-10-15): no sub-agent-triggered Notifications webhook; parent totals include all delegated spending, with visible attribution. Collapsed transcript presentation and numbering belong to `sub-display`.

- `WebhookFinishTracker` treated any newly completed command receipt as completion. It did not check family waiting, pending agent reports, or the helper's still-active task. A parent idle gap could therefore notify before the family finished; another receipt could notify again. The tracker now prefers the existing task terminal, which the helper publishes after its final family fence. It remembers the active task across omitted snapshot deltas, ignores later receipt-only changes, and retains compatibility with older receipt-only helpers. Family waiting and pending inbox guards also protect that fallback.
- Desktop `ChatRecord.isSubagent` can lag the helper snapshot when a child is first discovered or opened. The tracker now remembers the runtime child role from `subagentStatus` and stays silent even before metadata repair and on later delta-only snapshots. The existing eligibility rules, per-chat switch and preview behavior remain in place.
- Usage Report filtered/grouped by the physical session ID. Parent filters and “By chat” totals consequently omitted delegated requests. The common report predicate now includes the budget owner; unfiltered chat rows group physical attempts by workspace and budget owner. A selected child's report stays its own. Global totals continue to aggregate physical attempts once.
- Inspector stopped using journal-backed family spend when the chat had no cost limit. Its cost figure now uses the same spend source with or without a limit; a failing-first regression reproduces the prior “—” in place of $9.00.
- Inspector child-group statistics counted prepared captures that never dispatched. They now use the same dispatched-request population as the footer/report totals.

The helper's shared budget ledger and native parent footer/sidebar rollups already included child costs. They were not replaced or summed with a second child total. Added tests exercise failed, stopped, resumed and compaction requests, duplicate terminal delivery, child metadata arriving late, budget enforcement, unknown/zero costs and reload/checkpoint recovery.

## Presentation and boundaries

`GatewayTotals` carries an optional child-cost subset derived in the existing aggregate SQL pass. Its label flows to cost tooltips and accessibility labels in the footer, sidebar, reports, menu-bar usage and Inspector. The budget meter exposes the same explanation. Inspector Overview adds a per-child breakdown, eight entries per page, with keyboard-accessible links to each child's statistics. Child views identify their own spend as counting toward the parent; the card edit is one additive line using the existing child label.

Amounts use the app's existing money formatter, including its sub-cent precision. A child count means distinct physical children with retained dispatched requests in the selected scope. Queued/no-request children remain visible in the Inspector breakdown without fabricated spend. Missing costs remain unknown, distinct from reported zero.

Capture retention and report filters retain their existing meaning. The budget's journal-backed lifetime spend can exceed retained request totals; its attribution explicitly says “retained requests” in that case. No request bodies, credentials, permissions, model context, tool semantics, accounting journal records or retention policy changed. New cached projection fields are optional so older serialized projections remain readable. Work in UI refresh/layout is bounded; the child breakdown builds at most eight rows.

A failed parent with drained children may retain reports for explicit Resume. That terminal failure still waits for its user and can notify once; those held reports do not generate a new notification. Changing saved transcript history or reopening a helper silently establishes a baseline.

## Validation

All commands used the stream's build root. Native tests ran through `scripts/test-macos.sh`; no named result bundles were requested. Fixtures were generated with in-memory vaults; provider integration used only existing synthetic/loopback fixtures. The installed application, real preferences and Keychain were not used.

| Check | Result | Log under build root |
| --- | --- | --- |
| Original failing-first webhook/report regressions | 22 tests, 22 expected assertion failures in four new behavioral tests | `logs/failing-first.log` |
| First fix pass | 22/22 passed | `logs/fixes.log` |
| Affected native classes | 131 executed, 130 passed, 1 existing opt-in performance skip | `logs/affected-green.log` |
| Helper accounting/admission/family recovery/final fence | 24/24 passed | `logs/helper-tests.log` |
| Native guard mutations | All five selected tests failed (16 assertions); sources restored automatically | `logs/mutation-native.log` |
| Unlimited Inspector failing-first | 6 tests, one expected failure | `logs/unlimited-red.log` |
| Restored guards and unlimited Inspector fix | 45/45 passed | `logs/restored-green.log` |
| Standalone cost gallery | 1/1 passed; 20 PNGs | `logs/gallery.log` |
| Serial footer controls (alone) | 4/4 passed | `logs/footer-controls.log` |
| Full native parallel lane (one run, four workers) | 2,461 passed, 37 skipped, 1 sidebar accessibility regression; fixed below | `logs/full-parallel.log` |
| Final sidebar, unread/paused state and attribution regressions | 48/48 passed | `logs/post-gate-sidebar.log` |

The full lane's sole failure was `SideRowPresentationTests.testUnsavedSideAnnouncesUnreadAndLivePausedState`: the added row announcement included “Cost unavailable · 0/0 requests reported” on an empty side. The final guard adds that row explanation only when sub-agent attribution exists; ordinary and empty chats retain their previous announcements. `SubagentCostTests` now pins both cases as well as the family explanation. The final affected-class run passed all 48 tests in `SideRowPresentationTests`, `SubagentCostTests`, `SidebarMetricsLayoutTests`, `SidebarFigureGoldenTests`, `SessionReadStateTests` and `RunHoldTests`. The full lane was not repeated, as requested. Its structured result is retained at `logs/full-parallel-summary.json` (2,499 total tests).

Affected native classes: `WebhookTests`, `SubagentCaptureTests`, `SubagentCostTests`, `SubagentTranscriptTests`, `SubagentInspectorTests`, `DashboardTests`, `CostLimitTests`, `GatewayAccountingTests`, `MenuBarMetricsTests`, `SessionStatsPopoverTests`.

Helper command:

```sh
swift test --package-path packages/swift-host \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost/helper-tests \
  --filter 'SubagentAccountingTests|SubagentAdmissionTests|AgentSteeringBoundaryTests|AgentFamilyRecoveryTests'
```

Native invocation pattern (each serial class was run alone):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost \
  scripts/test-macos.sh -only-testing:PiAppTests/<Class>

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost \
TEST_RUNNER_PI_APP_SUB_COST_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost/gallery/sub-cost \
  scripts/test-macos.sh -only-testing:PiAppTests/SubagentCostGalleryTests -parallel-testing-enabled NO

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost \
  scripts/test-macos.sh -parallel-testing-enabled YES -parallel-testing-worker-count 4 \
  $(python3 scripts/test-lanes.py parallel)
```

The gallery, serial footer run and full lane also forwarded `TEST_RUNNER_PI_BUILD_ROOT` and `TEST_RUNNER_PI_APP_SCRATCH_ROOT` to keep generated fixture directories under this build root. Four parallel workers limit contention with the other implementation stream.

Mutation evidence: disabled the production runtime-child, task/receipt and family-wait guards; changed the report budget-owner predicate back to physical-session-only matching; removed the Inspector dispatch guard. The corresponding notification, family report and undispatched-cost regressions all failed. All mutations were restored before final checks.

## Gallery and integration handoff

Gallery: `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost/gallery/sub-cost`. Standalone `SubagentCostGalleryTests` covers parent and child conversation panes and the Inspector at 1240×800 and 920×600 in light/dark, plus a 420×600 Inspector pane. The scrolled breakdown is captured separately. It also checks keyboard entry into child statistics and the accessible attribution labels. Reviewed light/dark, wide/920×600 and narrow images for legibility, wrapping and consistent amounts. Gallery captures wait for rendered controls and settled numeric pills; the reused illustrative card progress is aligned to the generated capture amounts.

The other stream owns sub-agent numbering and the collapsed result. Its numbering may be applied to the existing child labels used here. The only card change is the additive “Counts toward parent chat” text in `TranscriptNativeSubagentCard.swift`; no card structure, disclosure or turn aggregation changed.

Lead tasks: reconcile shared-file changes, run the separate Codex review, integrate both branches and perform release validation/publication. This stream does not merge, tag, publish or push `dev/next`.
