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

## Lead review round 1

The first review found two distinct gaps in terminal-record comparison: checkpoint history loading restores terminal keys without a new epoch/timeline, while a fast edit can finish before any snapshot of its new active task. The first implementation could notify for the former and silently baseline the latter.

The helper now attaches an optional `completion` projection (`revision`, `outcome`) to `taskPresentation`. Its runtime counter advances only in `finishPresentedTask`, after the existing durable terminal/family fence; it starts at zero for each helper display epoch. Historical task loading, pruning, navigation and restoration do not change it. This is bounded presentation evidence, never a journal field or model input. The native tracker compares that counter across timeline changes. Older helpers remain readable: an observed active task identity or newly completed receipt matching the task root is required; newly revealed historical keys alone cannot notify. Receipt-only helpers keep their earlier fallback.

The Inspector cost breakdown now uses the same custom `PiKit.SelectableRow` approach as Inspector turn navigation. Its single-line title truncates within the available width, retains a full tooltip/accessibility label, and shares its leading edge with the detail. The full row is keyboard actionable. The generated gallery now includes a 120-character child title.

The $5/$25 discrepancy was a gallery fixture artifact, not a production discrepancy on this branch or `origin/dev/next`. The fixture constructed `SessionCostReading(limit: .usd(5))` while leaving `defaultLimit` at its default $25. Production `WorkspaceModel.costReading(for:)` resolves the override, default and effective limit together; that code is unchanged from `origin/dev/next`. The fixture now configures an in-memory $5 default and uses that production resolver, with assertions that the default chip and header agree. No new child-sidebar behavior was added.

| Round 1 check | Result | Log under build root |
| --- | --- | --- |
| Failing-first native review regressions | 24 tests; 8 expected assertion failures in the two webhook regressions and long-title layout regression | `logs/review1-native-red.log` |
| Failing-first helper completion evidence | 2 tests; 12 expected assertions for missing runtime completion evidence | `logs/review1-helper-red.log` |
| Helper task presentation, lazy/full history and family fence | 29/29 passed | `logs/review1-helper-green.log` |
| Affected native webhook, Inspector, cost attribution and cost-limit classes | 39/39 passed | `logs/review1-native-green.log` |
| Native mutations: remove legacy live-work proof, reset counter on timeline change, restore unconstrained title | All three selected regressions failed, 6 assertions | `logs/review1-mutation-native.log` |
| Helper mutation: remove the live completion-counter increment | Both selected regressions failed, 4 assertions | `logs/review1-mutation-helper.log` |
| Restored helper task/history/family regressions | 29/29 passed | `logs/review1-helper-restored.log` |
| Standalone regenerated cost gallery | 1/1 passed, 20 PNGs | `logs/review1-gallery.log` |
| Full native parallel lane (one run, four workers) | 2,464 passed, 37 skipped, 1 route-accounting failure | `logs/review1-full-parallel.log` |
| Unchanged route-accounting class, isolated after the gate | 13/13 passed | `logs/review1-turn-accounting-isolated.log` |

Both mutation runs restored production sources in `finally`; the guards, counter increment and constrained row were verified after restoration. The gallery was regenerated in `gallery/sub-cost`. Reviewed `breakdown-light-1240.png`, `breakdown-dark-920.png` and both `breakdown-narrow-*.png`: the 120-character title fits/truncates, title and detail align, and the parent limit header and Default chip both read $5.00. Also checked `inspector-light-920.png` and `completed-dark-920.png` for consistent parent figures and long-title behavior.

The single full lane ran 2,502 tests. Its sole failure was `TurnAccountingTests.testAnAutoRouterTurnSaysHowManyModelsAnsweredAndListsEachRequest`, at the route-list assertion (line 111): the two expected routes were present alongside a third `wire-fixture → —` route. This was a data assertion, not an OCR assertion. All 13 tests in that unchanged class then passed in isolation. The fixture's `logSettled` predicate can accept usage filled from reply records before the capture's model identity settles (`TranscriptActivity.aggregate` fills the running request's usage); this is a plausible timing explanation, not a confirmed root cause of the full-lane failure. No route-accounting production code or that test class was changed. The full lane was not repeated. Its structured summary is retained at `logs/review1-full-parallel-summary.json`; isolated screenshots are under `gallery/review1-turn-accounting`.

All three review findings and the reported gallery discrepancy are addressed. The route-accounting full-lane failure remains a lead/integration follow-up; the isolated pass is not presented as a clean full gate.

## Owner addition: sides share the main budget (2026-10-15)

This addition supersedes the earlier sub-agent-only scope and the earlier statement that helper accounting records were unchanged.

### Root causes and implementation

- `side.open` configured a separate limit, side requests lacked billing ancestry, and saved-side `costLimit` overrides won over the main chat. Sides now bind through their journal origin to the loaded main budget writer. The native app opens that writer before a saved side, and ignores legacy side overrides. Their stored values are left intact for backwards reading; no new side limit is written. Forks keep independent budgets.
- Side requests, nested sides and a side's sub-agents register numeric admissions through the ancestor writers before dispatch. The outermost owner commits charges first, using physical attempt IDs for deduplication. A side retains its local subtotal. Its coordinator, provider identity/cache key, instructions and executable tools are unchanged. `RequestScope.sideParents` is an optional, helper-owned accounting field, not model input.
- Keeping an ephemeral side previously carried only aggregate dollars/request counts. Keep now preserves its attempt identities and token usage too. Cold reopening adopts legacy saved-side numeric costs and repairs an owner charge from saved-side evidence. Parent journals receive no side messages, prompts, descriptions or titles. Discarding an unkept side leaves its parent charges intact without creating a side journal.
- Recovery first discovers side origins, then replays accounting only for the selected family. An unrelated side's damaged tail cannot block another main chat, while a related damaged ledger still refuses to open. A pre-cost-record main chat takes its own physical request-log seed before saved-side adoption; a cached family total is never used as that seed.
- Reaching the shared limit previously cancelled requests already on the wire. The admission/dispatch checks now block subsequent requests; dispatched requests settle first. Queued managed work remains unexecuted, and ordinary Stop still cancels immediately. A main request already in flight when the first side opens remains chargeable and is not mistaken for an idle family.
- Native accounting uses indexed family recipients, preserving physical capture identity. Footer/sidebar cache, copied references, reports, dashboard/menu-bar and Inspector queries count a physical attempt once per selected family; unfiltered reports charge it to one main chat. A metadata-only side ancestry mapping adopts older retained captures. No body-retention or capture-permission policy changed.
- Inspector shows separate compact Side costs and Sub-agent costs cards (eight entries per page), with constrained full-accessibility titles. Cost tooltips distinguish the two shares. A side's footer/VoiceOver tooltip names the parent charge, and its Inspector opens the main budget instead of offering a separate editor. No `SidesPanel.swift` changes or dependencies on sidebar child rows.

### Validation evidence

Generated fixtures, MemoryVault and loopback only, under this stream's build root. The installed app, real preferences, Keychain and paid providers were not used.

- Initial helper red: one loopback test, three failures — parent cost stayed $0.0123 instead of $0.0369, request count stayed 1 instead of 3, and side attempt IDs were missing from the parent journal (`sides-helper-red.log`).
- Initial native red: three tests, three expected failures — saved side, nested side and draft side used their own limits instead of the main $3 limit (`sides-native-red.log`).
- Keep/reload red: three helper tests, four expected failures — lost physical attempt identity and input usage (`sides-lifecycle-red.log`).
- Mid-request adoption red: one helper test, four expected failures — the side cancelled the already-running main request and its $0.30 charge vanished (`sides-inflight-red.log`).
- Helper affected checks before mutation: 90/90 passed across side/cache/fork/cost-limit, shared admission/accounting/coordinator, steering and family recovery classes (`sides-helper-inflight-green.log`).
- Native affected checks before final attribution refinement: 34/34 passed (`sides-native-affected.log`). One earlier native build was invalidated by editing a helper input during compilation; it was rerun without edits and is not recorded as a test failure (`sides-native-green2.log`).
- Real helper guard mutations were caught: disabling shared side limit admission failed the budget test; stopping with in-flight permits failed the finish guarantee; restoring the old family-enabled accounting exclusion lost the pre-existing main charge. Source files were restored in `finally` (`sides-mutation-admission.log`, `sides-mutation-running.log`, `sides-mutation-adoption.log`).
- Nested-attribution red: one native test, six failures exposed a side's subtotal being mislabelled as its included side share. Selected-family aggregation now reports its own agents and nested sides relative to that family (`sides-nested-attribution-red.log`). The expanded affected run then passed 129/129 (`sides-native-final-affected.log`).
- Recovery-isolation red: one helper test failed opening an unrelated main because of a damaged side tail (`sides-recovery-isolation-red.log`). The fixed full helper package executed 851 tests, with seven skips and zero failures (`sides-helper-full.log`).
- Legacy seed red: the helper dropped the main's $0.50 seed once it adopted $0.70 of old side spending (one test, four assertions over two opens). The native seed incorrectly included that $0.70 too (one test, two assertions). Logs: `sides-legacy-seed-helper-red.log`, `sides-legacy-seed-native-red2.log`. The first native attempt had a test call-site label typo and did not execute; it is not failing-first behavioral evidence. Migration/family/checkpoint helper classes then passed 52/52 (`sides-final-migration-helper.log`).
- Native mutation disabled the real side-family projection guard. Both retained-scope/reload tests failed, with 99 failure records including dependent missing-value unwraps; the source was restored in `finally` (`sides-mutation-native.log`). Restored affected native classes passed 130/130 (`sides-native-restored.log`).
- Standalone gallery passed 1/1 and produced 30 PNGs (`sides-gallery-final.log`). An earlier capture waited for sub-agent controls while the side query was still publishing its next UI update; it failed before taking the side-card capture (`sides-gallery.log`). Waiting for both rendered cards fixes the harness race; no production redraw fix was necessary.

The regenerated gallery is `build-sub-cost/gallery/sub-cost`: parent, sub-agent and side footers at 1240×800 and 920×600; Inspector Overview and scrolled side/sub-agent breakdowns at both sizes and a 420×600 pane; all in light/dark. The main reads $1.63 including $0.40 from one side and $0.45 from three sub-agents; the side reads its own $0.40 and its tooltip/VoiceOver label names “Review the parser” as the parent. The harness checks keyboard reachability of both breakdowns and full accessible labels. Reviewed the narrow title truncation/alignment, wrapping attribution, and matching cost amounts. Gallery sidebar/card placement is the pre-integration shell; the sub-display stream owns those replacements.

Compatibility decisions: old per-side limit values remain stored but ignored; the parent is the only budget editor/writer. Actual sides inherit through their saved origin, while forks keep independent budgets. Each side's subtotal includes its own nested sides and agents, and the main counts each physical request once. A loaded side keeps its ancestor accounting writers loaded; operations requiring an unloaded parent, such as moving its connection, must wait until those sides are closed. Existing journal kinds remain readable; the optional ancestry field is accounting metadata only. Legacy aggregate side spending has unknown token coverage when no token records exist. Capture/report retention is unchanged and the breakdown says “retained requests”; durable budget spending survives discard/retention. No ephemeral side content is copied into a parent journal.

The final full helper package executed 852 tests: 845 passed, seven skipped, zero failures (`logs/sides-helper-final-full.log`). This includes the last physical-seed migration change. The earlier initializer-isolation warnings introduced by referencing actor properties inside a boolean autoclosure were removed by reading the local replay value; existing unrelated no-op-`await` warnings remain.

The single full native parallel lane executed 2,506 tests with four workers: 2,468 passed, 37 skipped, one failed (`logs/sides-full-parallel.log`, structured summary `logs/sides-full-parallel-summary.json`). The failure was `PayloadArchiveTests.testCapturingABodyLooksUpNoRowPerPacketAndSyncsOnlyTheChunksFolder`: beginning an ordinary request used 11 statements against its existing nine-statement bound. This was a real regression introduced by two legacy-side ancestry lookups, not a parallel timing failure. The archive now caches that identity-only mapping at open and updates it after successful relationship writes; capture uses the known physical identity and cached ancestry. The existing failing-first performance test is unchanged. The legacy-side regression additionally checks late captures, a cold reopen, workspace isolation and the nine-statement ordinary-request bound.

The post-gate affected classes (`PayloadArchiveTests`, `SubagentCaptureTests`, `AccountingScaleTests`, `SubagentInspectorTests`) passed **50/50**, with the original request-start check reporting nine statements (`logs/sides-capture-performance-followup.log`, structured summary beside it). The full lane was not repeated. The unchanged `TurnAccountingTests` class passed in this full lane; the earlier round-1 intermittent failure remains historical evidence, with no claimed root-cause fix.

The final standalone gallery passed **1/1**, regenerating all **30 PNGs** (`logs/sides-gallery-settled.log`). Visual review caught one earlier frame during request-index loading; the harness now waits for the loaded index and completed read before checking rendered controls. Rechecked the settled dark 1240 Inspector, both narrow side breakdowns, light 1240 and dark 920 breakdowns, and side/parent footers. No production rendering change was needed. The final production follow-up affects only capture ancestry lookup, and the gallery-only wait changes no application behavior.

Handoff remaining: separate lead review and integration with `sub-display`, including its top-right side/agent navigation. No changes to `SidesPanel.swift`, numbering or collapsed-turn composition were made in this addition. The full-gate failure and its passing targeted follow-up are recorded separately; this record does not claim a second clean full run.
