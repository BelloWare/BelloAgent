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


## Lead review round 2: shared side-budget audit

Merged `origin/dev/next` at `558630c8` first, in merge commit `b443116f`. This includes the independent fork-family fix and new-chat project chip. Changes remain on `dev/a128-sub-cost`; no dev/next push or history rewrite.

### Findings and decisions

| Case | Ownership and behavior after this review |
| --- | --- |
| Ordinary main chat | Own limit and durable family ledger. Every physical attempt counts once. |
| Actual saved side / pending side draft | Saved `side_<id>.jsonl` origin, or unpublished draft identity, determines ancestry. Side-pane placement cannot grant budget ownership. Connected sides ignore their old separate limits. |
| Mounted fork / fork of a side | Independent budget, zero inherited spend/authority, own new sides and agents. Tested with the merged fork implementation on creation and cold open. |
| Side-owned sub-agent | Side remains the delegation/permission owner. Admissions and charges reach the outer budget. A loaded managed reader accepts only an identity-validated contribution correction, without gaining admission authority. |
| Saved orphan | A genuinely missing parent journal permits independent reopening with the side’s own subtotal and saved limit/default. An existing unloaded parent still must open first. No deleted parent journal is recreated. Existing nested sides and managed children stay with the surviving owner. The existing UI refusal to create a new nested side from an orphan is unchanged. |
| Close / unload / deletion | Pane closure remains presentation-only. `session.close` rejects while side runtimes pin the owner; desktop bookkeeping retains a rejected runtime as loaded. Deletion preflights the family, refuses queued/running/admitted/dispatched work, and detaches idle dependents before forgetting the owner. Surviving saved sides can then reopen. |
| Legacy seeds | Unkeyed pre-ledger spend gets one stable numeric history charge during binding and cold recovery. The parent never receives side content. Existing keyed attempts are not counted again. |
| Late price correction / mirrors | Unknown-to-reported updates reach admission ledgers and separately validated contribution-only mirrors. Loaded readers, unloaded side-owned children, legacy ancestor mirrors, and repeated cold reloads are covered. An imported correction retains its accounting ancestry. |
| Captures / reporting | Retired fork/orphan ancestry removes stale side recipients and changes the report grouping, including after reload and later captures. Physical request scope and body identity remain immutable. The ordinary capture-start statement bound remains covered. |

The five reported causes were reproduced before their fixes. The audit additionally found that cold recovery skipped an already-imported unknown charge after a side obtained a reported price, and that forwarding a legacy correction could drop the ancestor mirror’s ancestry field. Both now retain the corrected dollars, tokens, and budget enforcement through repeated cold opens. Directory enumeration errors are propagated rather than treating an unreadable family as empty. An owner also remains loaded while bound managed work is unsettled between model requests, when the owner has no dispatched permit. Native deletion refreshes surviving side relationships and footer attribution. No pane/card placement, numbering, collapsed-turn composition, model-facing semantics, permissions, tool policy, provider cache identity, capture policy, or vault boundaries changed. No new journal kind or mandatory format field was introduced.

Old separate side-limit values are not erased: they are ignored while the side is connected to its parent. Once that parent is deleted, a surviving side becomes independent and its saved setting (or the default) applies. That orphan exception is deliberate; the main budget cannot be enforced after its owner has been deleted.

### Failing-first and mutation evidence

All logs below are under `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost/logs`. Generated journals, MemoryVault, synthetic clients and loopback only; no installed app, real preferences, Keychain or paid providers.

- `review2-helper-red.log`: 13 SideBudgetTests, 13 failure records (one unexpected follow-on persistence error), covering the close acknowledgement, orphan reopen, missed seed, and managed-reader correction.
- `review2-native-red2.log`: six SubagentCostTests, seven failure records (one unexpected thrown error after the fork assertions), covering mounted forks and stale orphan attribution. The first native attempt stopped at an existing Sendable capture compile error in the merged SidebarInteractionTests fixture. Its UI objects now cross the closure through that fixture’s existing Unchecked wrapper; behavior is unchanged.
- `review2-helper-audit-red3.log`: 17 tests, ten failure records from the cold legacy correction regression over two reopens. Earlier audit attempts had test-fixture compile/setup mistakes and are not behavioral evidence.
- `review2-helper-affected1.log`: the expanded 55-test run exposed four assertions from lost legacy mirror ancestry after reload. With that field retained, `review2-helper-affected2.log` passed 55/55.
- `review2-native-mutation.log`: restored the incorrect mounted-pane ownership shortcut, removed the desktop loaded-state acknowledgement guard, and disabled empty ancestry projection. Twenty tests produced eleven failure records across the three corresponding regressions (two follow-on thrown errors). All mutated files were restored in `finally`.
- `review2-helper-full.log`: 874 executed, 867 passed, seven skipped, zero failures.

- `review2-helper-mutation.log`: restoring successful-close acknowledgements for pinned owners, omitting unkeyed seed adoption, and requiring admissions for managed mirrors produced ten failures across 18 tests (one follow-on thrown error). Each corresponding behavioral test failed. Both source files were restored in `finally`.
- `review2-helper-restored.log`: 75/75 passed across side-budget, side/fork, shared accounting/recovery, host dispatch/service and cost-limit checks after restoration.
- `review2-native-affected.log`: 119/119 passed across SubagentCostTests, SubagentCaptureTests, SubagentDeletionTests, SideTests, SideRelaunchTests, CostLimitTests, CostLimitOpeningTests, SubagentInspectorTests, PayloadArchiveTests, WebhookTests and WorkspaceDisplayMemoryTests. Includes real packaged-helper deletion/reopen and read-only-to-editing flows without provider requests.
- `review2-helper-directory-red.log`: one real permission-denied fixture failed because recovery swallowed directory enumeration failure as an empty family. Recovery now propagates the I/O failure, preserving the budget boundary. This final audit correction prompted another full helper run.

- `review2-helper-between-requests-red.log`: one test, four failures across main and side owners. Both could unload while a bound managed child remained unsettled between model requests. The real unload dependency guard now checks that lifetime as well as loaded sides and active permits.
- `review2-native-opening-serial.log`: SubagentOpeningTests passed 10/10 alone, including inherited-reader recovery and opening invalidation.

- `review2-helper-audited-full.log`: final production helper suite, **876 executed: 869 passed, seven skipped, zero failures**. The preceding directory-only full run passed 875 tests with seven skips; the additional between-request lifetime regression is included in this final run.
- `review2-native-sidebar-serial.log`: SidebarInteractionTests passed **9/9** alone after the merged fixture’s Sendable capture repair.
- `review2-native-gallery.log`: standalone cost gallery passed 1/1, initially producing 30 PNGs. Visual inspection caught a light Inspector capture before its deferred request-index rendering had settled. The gallery now waits for the rendered turn/request header and absence of its loading label, and captures the cost-limit card explicitly too. This is a harness-only timing refinement; no production rendering change was made.

- `review2-native-gallery-settled.log`: standalone SubagentCostGalleryTests passed **1/1**, producing **34 PNGs** in `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost/gallery/review2-sub-cost`. Inspected main and side footers, light/dark 1240×800 and 920×600 breakdowns, 420×600 narrow cards and wrapped attribution, and the matching default-limit badge/chip. Titles and details share a leading edge; long titles truncate within their cards. Keyboard focus and full accessible cost labels remain asserted by the harness. The final light overview is fully rendered (one turn / five requests), and both limit controls show $5.00. Sidebar/card arrangement remains the sub-display stream’s integration work; no SidesPanel.swift edits.

The single final native parallel lane ran **2,539 tests: 2,501 passed, 37 skipped, one failed** (`logs/review2-full-parallel.log`, `logs/review2-full-parallel-summary.json`). The sole failure was `WorkspaceRefreshLifecycleTests.testEvictingAnIdleDisplayClosesItsHelperSessionBeforeItOpensAgain`: its old assertion expected `opened` to drop both runtimes before either close acknowledgement. The new reviewed contract deliberately retains them until the helper acknowledges an actual unload, because a busy rejection must preserve the real tool mode. This is an outdated fixture expectation exposed by the production fix, not a timing failure. The fixture now asserts the complete loaded set before acknowledgement, verifies reopening still waits for the close, then acknowledges both closes and checks the reduced set. No production change followed the full lane, and the full lane was not repeated.

The post-gate affected classes passed **36/36**: WorkspaceRefreshLifecycleTests (26), SubagentCostTests (8), and WorkspaceDisplayMemoryTests (2), recorded in `logs/review2-native-close-followup.log` and `logs/review2-native-close-followup-summary.json`. This includes both acknowledged unloads and a real busy rejection preserving read-only tool mode. The full-lane failure and the passing targeted follow-up are separate evidence; no second clean full lane is claimed.

All five review comments and the additional audit findings are addressed. Remaining work is the lead’s independent branch review and integration with sub-display; this stream did not merge or push dev/next. The release note, design decisions, and this validation record accompany the implementation commit.

## Lead review round 3: replay parity and durable side corrections

The saved-side scanner replayed standalone accounting records but missed the `family-adoption` reset embedded in `subagentCall` and `agentOperation`. Full `SessionReplay` replaced earlier keyed charges with that seed, so later binding could import both representations into the parent. The reported $0.20 own plus $0.30 delegated example reproduced as $0.70, three reported requests, and duplicated known tokens. `AttemptAccounting.consumeRecord` now handles the journal-level accounting interpretation for both paths, including the existing owner checks that reject copied foreign adoption records. The example remains $0.50 and two requests through repeated real binding, cold opens, and orphan recovery.

The property-style regression enumerates **180 combinations**: keyed/unkeyed own spend before, after, or on both sides of first delegation; no delegation, a plan without adoption, a standalone reset, v2 embedded adoption, or v3 embedded adoption; no seed, an app-request-log seed, or a numeric side-history seed; and a present or deleted parent. Every generated journal goes through full `SessionReplay` and `SideBudgetRecovery`, comparing dollars, reported/unreported request counts, known token totals and token observation counts. Repeated scans and subsequent binding must preserve count-once totals. Separate tests exercise real runtime binding and copied foreign-owner adoption guards. Historical tokens that an existing adoption seed did not retain remain unknown; the fix preserves replay semantics rather than inventing them.

Late reconciliation previously updated loaded side runtimes, with a disk fallback only for managed children of loaded owners. An unloaded saved side could therefore retain an unknown price after its main ledger recorded the correction. The host now persists numeric corrections into unloaded side journals and their managed children before acknowledging reconciliation. It discovers ownership from actual saved side origins, validates existing attempt/source/owner/delegation identities, uses each journal’s local accounting revision and exclusive writer lock, and excludes loaded writers. Nested sides, loaded and unloaded managed readers, repeated corrections, and two subsequent orphan reopens are covered without any retained capture evidence.

The retry audit found an additional crash window: a durable main correction can survive a failed mirror, after which unresolved-capture paging no longer selects that known attempt. Before `session.forget` releases a parent, the helper now repairs surviving sides from the parent’s committed numeric ledger, including when that parent runtime is unloaded. A failed repair rejects forgetting, preserving the owner’s evidence. Disk mirrors retry even when the side’s own correction was already committed. Forks, foreign families, loaded writers and paths outside the workspace are excluded; discarded side content is never recreated.

No new journal kind or mandatory field was added. Existing journals and checkpoints remain readable. These fixes change neither provider/tool semantics nor permissions, captures, vault boundaries, or side-content persistence. The existing round-2 limit decision is unchanged: an attached side follows its parent; a surviving orphan becomes independent and its saved limit/default applies. All work uses generated journals, synthetic clients, MemoryVault or loopback, and only this stream’s build root.

### Round 3 failing-first and mutation evidence

Logs are under `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost/logs`.

- `review3-replay-red.log`: three tests, **180 assertion failures**, zero unexpected failures, reproducing adoption count-once and token divergence. The initial matrix contained 144 combinations; the final 180 also include sides without delegation.
- `review3-helper-red.log`: the unloaded-side deletion regression alone produced **109 assertion failures** across six direct/nested and own/managed/reader combinations. Its first matrix fixture used strict duplicate-record equality for floating-point legacy remainders and was superseded by the clean replay run above.
- `review3-helper-affected.log`: **88/88 passed** across side budgets, accounting/recovery, forks, family recovery, host dispatch/service and cost limits before the final deletion-crash audit.
- `review3-helper-mutation.log`: bypassing embedded adoption replay, removing unloaded-side persistence, and disabling the loaded-writer exclusion produced **276 assertion failures across eight tests**, zero unexpected failures. Each corresponding regression failed; all production files were restored in `finally`.
- `review3-delete-audit-red2.log`: disabling the deletion repair reproduced **34 assertion failures in one test** after a durable root-only correction, with the parent runtime unloaded and no capture available. The preceding attempt stopped at a fixture that read the journal path after unload; the corrected fixture retains the path before closing.

- `review3-helper-full.log`: **885 executed, 878 passed, seven skipped, zero failures**, including all nine new test methods and the 180-case matrix. An earlier helper/native build attempt stopped at an optional workspace-directory type error; the command now receives the already-validated workspace directory explicitly. No tests ran in that failed build attempt (`review3-helper-build-error.log`, `review3-native-build-error.log`).
- `review3-native-affected.log` and its JSON summary: **145/145 passed** across SubagentCostTests, SubagentCaptureTests, SubagentDeletionTests, SideTests, SideRelaunchTests, CostLimitTests, CostLimitOpeningTests, SubagentInspectorTests, PayloadArchiveTests, WebhookTests, WorkspaceDisplayMemoryTests and WorkspaceRefreshLifecycleTests.
- `review3-native-opening-serial.log` and its JSON summary: **10/10 passed**, SubagentOpeningTests alone as required by the serial lane.
- `review3-native-gallery.log` and its JSON summary: **1/1 passed**, SubagentCostGalleryTests alone, producing **34 PNGs** in `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost/gallery/review3-sub-cost`. Inspected `breakdown-light-1240.png`, `breakdown-dark-920.png`, both `sides-breakdown-narrow-*.png`, `completed-light-920.png`, `side-dark-920.png`, `child-light-1240.png`, and `cost-limit-light-1240.png`. Cost/title alignment, compact side/sub-agent breakdowns, narrow truncation and matching $5.00 default-limit controls are intact. The harness also asserts keyboard access and full accessible attribution labels. This round makes no UI or SidesPanel.swift change.

The single final native parallel lane ran **2,539 tests: 2,500 passed, 37 skipped, two failed** (`review3-full-parallel.log`, `review3-full-parallel-summary.json`). `ModelCatalogEndpointTests.testVisibleDefaultPickerShowsBundledCatalogWithoutReadingTheVaultOrGateway` failed because `CGWindowListCreateImage` returned nil, before OCR could inspect the window. `TerminalPanelAuditTests.testTheRegistryEndsShellsForClosedProjectsAndOnShutdown` observed an empty registry where the second fixture workspace should still have been present. Neither failing class nor its production code changed in this round; their causes remain unconfirmed.

The unchanged classes then passed alone: **19/19 ModelCatalogEndpointTests** and **8/8 TerminalPanelAuditTests** (`review3-native-catalog-followup.log`, `review3-native-terminal-followup.log`, and their JSON summaries). No source change followed the full lane, and it was not repeated. These targeted passes do not turn the full-lane result into a clean gate. The two validation follow-ups are retained in NEXT-RELEASE.md for the lead.

Both round-3 review comments and the interrupted-mirror audit finding are addressed. Remaining work is the lead’s independent review/integration and investigation of the two native parallel-lane failures above. This stream commits and pushes only `dev/a128-sub-cost`; it does not merge or push dev/next.

## Lead review round 4: orphan ownership and cache audit

Both reported defects are reproduced and fixed. The child mirror compared whole numeric records except for their local revision. Legacy side adoption adds top-level `sideParents`, so an already-reported child charge could disagree solely on that derived ancestry and block `session.forget`. The idempotence comparison now excludes that field too. Physical request scope (including its original ancestry), source/owner/delegation identity, money and tokens must still match exactly. A known matching mirror returns without rewriting the child journal.

The Overview cached its limit editor only by footer identity and did not observe shared-budget footers. Parent deletion preserves a saved side’s display and footer. The page now follows every footer and keys the editor by both footer and current budget owner. The same open page gains the orphan’s editor, follows edits to its limit, and removes the editor if the chat shares a budget again.

The final audit also reproduced stale attribution in existing footer and row caches: repairing the archive’s side ancestry did not schedule new readings. `recordSideBudgets` now returns the identities affected by an actual projection change, including former ancestors. The workspace refreshes their existing accounting displays/caches and those of their managed children. Repeating an unchanged restore schedules nothing. This runs during relationship restoration, not view layout, and reads numeric accounting through the existing coalesced path.

### Ownership audit

| Area | Parent-deletion/orphan result |
| --- | --- |
| Runtime ownership and close (`HostService`, `SessionSideBudget`, `SessionCost`) | Actual side origins bind budgets; mounting a fork does not. Forget preflights settlement and unloads bound descendants before the ancestor disappears. Saved orphans reopen independently; nested sides bind to the surviving owner. Managed children retain their direct owning side. Existing pinned-unload and busy-work regressions remain in the helper suite. |
| Mirror and recovery comparisons (`SessionBudgetRecovery`, `SideBudgetCorrections`, `SubagentRecovery`, `AgentFamilyRecovery`, `Sessions`) | Only known-charge mirror equivalence ignores derived top-level ancestry. Admission, capture scope, delegation, source and direct owner comparisons retain their immutable meaning. Loaded mirrors use their existing contribution/admission paths; unloaded mirrors retain exclusive journal locks and actual saved-family checks. The new host regression covers all four loaded/unloaded side and managed-reader combinations, followed by two orphan reopens and budget enforcement. |
| Legacy accounting (`AttemptAccounting`, `SideBudgetRecovery`, `SessionReplay`) | The shared adoption reducer and stable unkeyed seed identities remain unchanged. The 180-case replay/recovery matrix still covers before/after delegation, adoption forms, keyed/unkeyed costs, side-owned sub-agents and deletion. The new mirror matrix checks 16 ancestry pairs twice, unchanged child bytes, and rejection of changed amount, tokens, source, owner, delegation or physical scope. |
| Desktop ownership (`WorkspaceCostLimits`, `WorkspaceHosts`, deletion flow) | Ownership follows the actual side journal relationship with workspace/cycle checks. Missing parents end ancestry; fork pane placement is irrelevant. A helper reopen receives the newly resolved limit, so `costLimitSent` does not preserve an old runtime budget. Legacy per-side values remain stored and ignored while attached; an independent orphan uses its saved limit/default, as decided in round 2. |
| UI identity caches (`InspectorOverviewPage`, `SessionInspectorModel.follow`, `SessionInspectorWindow`, `ConversationPane.metrics`, `MetricsFooter`, `CostLimitLiveEditor`) | The Overview now invalidates on owner changes. The other identity checks retain subscriptions to observable cost/gateway values or replace the Inspector on an actual scope change. The added projection refresh updates retained displays, cached rows, nested sides and managed children without requiring a new request or recreating a page. |
| Archive/report ancestry (`CaptureLineage`, `InspectorFamily`, accounting projections) | Current numeric projection ancestry changes; physical capture scope remains immutable. Persisted empty ancestry prevents later captures/reload from resurrecting a deleted ancestor. Existing report/dashboard/menu-bar and relaunch tests cover the repaired projection; this round adds live-cache invalidation and preserves count-once totals. |

No journal kind, mandatory field, tool/model-facing contract, permission, capture, vault or side-content boundary changed. No edits to SidesPanel.swift or the other stream’s numbering/navigation. All fixtures and artifacts remain under this stream’s build root; no installed app, real preferences/Keychain or paid provider calls.

### Round 4 validation

Evidence is under `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost/logs`.

- `review4-helper-red.log`: the known-child mirror matrix reproduced 28 `subagent_recovery` assertions. An initial integration fixture omitted its plan from the saved journal and failed earlier with `accounting_damaged`; it was corrected by keeping the side before installing the plan. The subsequent mutation below reproduces the actual deletion failure with the corrected fixture.
- `review4-native-red.log`: SubagentCostTests passed seven tests and failed the unchanged-footer orphan editor regression. `review4-native-cache-red.log` then reproduced the stale accounting-cache regression alone. An earlier cache fixture used a non-UUID capture attempt and was corrected before this behavioral run.
- `review4-helper-mutation.log`: restoring the old exact ancestry comparison caused **30 assertion failures across two tests**, zero unexpected failures, including deletion with both a loaded and unloaded side when its child reader was unloaded. Production source was restored in `finally`.
- `review4-native-mutation.log` and JSON summary: removing ownership from the editor key and disabling refresh of existing accounting caches caused **both targeted tests to fail** for their intended reasons. Both production files were restored in `finally`.
- `review4-helper-full.log`: **887 executed, 880 passed, seven skipped, zero failures**. `review4-helper-restored.log`: **31/31 passed** after restoring the mutation. The intermediate focused build’s inferred array type was corrected to the `Set<String>` required by `JSON.removing` before successful testing.
- `review4-native-focused.log` and JSON summary: **28/28 passed**, SubagentCostTests, SubagentInspectorTests and SubagentCaptureTests.

- `review4-native-affected.log` and JSON summary: **136/136 passed** across SubagentCostTests, SubagentCaptureTests, SubagentDeletionTests, SideTests, SideRelaunchTests, CostLimitTests, CostLimitOpeningTests, SubagentInspectorTests, PayloadArchiveTests, WorkspaceDisplayMemoryTests, WorkspaceRefreshLifecycleTests, InspectorFollowTests and ForkFromReplyTests. This includes the expanded cache regression with a loaded managed child and an unloaded nested-side row.
- `review4-native-opening-serial.log` and JSON summary: **10/10 passed**, SubagentOpeningTests alone.
- `review4-native-gallery.log` and JSON summary: **1/1 passed**, SubagentCostGalleryTests alone, producing **46 PNGs** in `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost/gallery/review4-sub-cost`. Twelve new captures show the same saved-side Overview before and after parent deletion, light/dark at 420×600, 920×600 and 1240×800. The harness asserts editable orphan limits, preserved spend, cleared parent attribution, keyboard focus and accessible chip labels. Its first run (`review4-native-gallery-unsettled.log`) checked before the editor’s queued update; visual review also caught the summary’s debounce and chart construction. The final harness waits for the rendered figures/editor to settle before capture, without changing production behavior.

Inspected the orphan variants in both appearances at all three widths, `side-shared-overview-light-920.png`, `breakdown-light-1240.png` and `sides-breakdown-narrow-dark.png`. Rechecked the shared 920-point light scene and orphan 920-point light/420-point dark scenes after tightening the render waits. The shared side names its parent; the orphan retains $0.40, gains the $5.00 default editor and loses the parent caption. Controls wrap within the narrow card; the existing side/sub-agent titles and detail lines remain aligned.

All round-4 fixes and the final audit finding are addressed. No full native lane ran, as explicitly requested. Remaining work is the lead’s independent review/integration; the two historical round-3 parallel-lane follow-ups above remain unchanged.


## Lead review round 5: ancestry consumers and runtime lifetime

Merged `origin/dev/next` at `e13e1462` with merge commit `ef285a99`, retaining the fork/project work already integrated and the new side-keep recovery and sub-agent policy/effort work. The release-note conflict retains both streams. No model-facing tool schema, prompt, permission, capture policy or helper journal semantics were changed by the review fixes.

### Root causes and corrections

- Coordination source/consumer queries compared a side ID to the root `budget_owner`. They now compare `local_owner`, keeping the exact physical session, workspace and retained message/delivery links. Side-owned sub-agents retain both directions of Inspector navigation before and after orphaning.
- The 10,000 ordinary-chat window could omit an old budget owner. `MetadataStore.loadChats` now retains the actual ancestors required by listed sides and managed children, outside that window. Targeted restore/open reads use the same store traversal. It rejects cross-project and managed-parent adoption, respects deletion tombstones, preserves stored ordering revisions, deduplicates ancestor reads and excludes fork provenance. Desktop publication rechecks the chat generation after the store actor hop. Missing in-memory metadata is no longer evidence of deletion.
- Recursive side opens created helper runtimes without a display, leaving no eviction path. Budget-only opens are tracked separately from direct uses; loaded and opening sides pin their ancestors before the first await. A completed direct open claims its own lifetime even when sharing an in-flight dependency open. Last-dependent unload cascades through idle ancestors, while the helper retains final authority over running, queued and settling work. Failed side opens and concurrent sibling opens are covered. Budget-only events do not manufacture transcript displays.
- Explicit eviction/close, editing changes, connection changes, family deletion, helper unload/loss and shutdown update the same release bookkeeping. Inspector windows pin a runtime until they close. A settings fallback formerly forgot an owner even when its close was rejected as busy; it now keeps the loaded runtime and a pending release. Re-selecting a retained display clears an earlier eviction request. The eight-display cache regression verifies that evicted side displays release their implicit writers too.
- A late capture-link update resolved only the physical child and root, omitting the coordinating side before child metadata discovery. The archive now returns all current `family_recipients`. Metadata updates also invalidate current ancestor records when the immutable request scope predates side adoption. No transcript scan or additional per-chunk query is introduced; orphaning replaces historical ancestry in the rebuildable projection.

### Integration findings

The broader affected-class run reproduced two upstream integration issues before the full native lane:

1. Upstream keep registration moved completion into a non-throwing helper and runs recovery before the request archive opens. The merged call initially did not compile; merely restoring propagation then exposed three upstream keep-test failures and a new cold-registration regression. A completed registration now settles normally. An unopened archive defers projection, and every successful archive open restores side ancestry before reading totals. An actual later projection error says that the chat was saved and its cost refresh failed; it does not mislabel a committed copy as an unkept one.
2. The synthetic gateway's schema oracle required `oneOf` to be the only key. The policy stream correctly combines an object schema with conditional model/effort branches. Ordinary native turns therefore received HTTP 400 from the loopback fixture. The oracle now validates the common object constraints and exactly one branch. Its new HTTP and argument regression rejects unsupported effort, extra arguments and violations of the common constraints. The actual helper/tool schema is unchanged.

The initial broader run was stopped after those causes were established (89 passing tests, five behavioral failures, one cancellation in its partial summary). It is not the full native lane. Its evidence remains in `logs/review5-native-affected.log`; the corrected affected run is separate.

### Consumer audit

The grep inventories are retained under the build root as `logs/review5-all-consumers.txt`, `logs/review5-ancestry-consumers.txt` and `logs/review5-final-ancestry-inventory.txt`.

| Consumer | Ownership used / result |
| --- | --- |
| Capture lineage and body reads | Physical source and immutable scope remain unchanged. `local_owner` identifies the direct coordinator; `budget_owner` identifies the current root. `family_recipients` supplies all current accounting recipients. |
| Coordination and Inspector navigation | Direct owner for source/consumer matching and journal coordination. Request/body readers retain physical session + project checks. Family lists and older-row navigation already use the recipient table. Parent navigation now has retained ancestor metadata even outside the root window. |
| Footer, row caches and Inspector ownership caches | Current ancestor metadata plus the round-4 ownership-key invalidation. Late link/metadata updates reach direct sides and roots. Existing orphan displays continue to gain independent limit editors and lose former-parent attribution. |
| Sidebar, dashboard, menu bar and Usage Report | Current family membership for explicit chat totals; one root grouping per physical request for unfiltered chat reports. Global sums still count physical requests once. No total is added to an already aggregated parent total. |
| Open, release and display eviction | Actual saved-side relationship, never pane placement or fork provenance. Opening calls pin the chain; direct uses, existing displays and Inspector windows retain their own lifetime. Busy close rejection never claims success. |
| Restore, kept-side registration and chat windowing | Persisted metadata ancestors retained before orphan decisions; tombstones and project checks preserved. Archive projection can wait for archive startup without invalidating a completed keep. |
| Helper admissions, mirrors and recovery | Root admission/settlement plus direct-owner mirror identity remain unchanged. Side journal recovery, adoption/count-once replay, orphan correction mirrors and migration-only ancestry normalization retain the previous rounds' guards. Full merged helper suite passes, including fork isolation and policy/effort recovery. |

Unkept side content remains ephemeral; these changes read/write metadata relationships and numeric capture projections only. Existing per-side limit values retain the round-2 behavior: ignored while sharing a live parent, available again if a surviving saved side becomes independent. Forks still own their budget and children. No edit was made to `SidesPanel.swift` or the other stream's collapsed transcript/numbering work.

### Validation

All native invocations used `PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost` through `scripts/test-macos.sh`. Test scratch roots and gallery paths were forwarded into the test host. Serial classes ran alone; no named result bundles were requested. Only generated fixtures, MemoryVault and synthetic/loopback requests were used.

| Check | Result | Evidence under build root |
| --- | --- | --- |
| Original review regressions | Five tests fail: direct coordination links, cold unlisted ancestors, restore ancestry, metadata window and last-dependent release | `logs/review5-native-red-behavior.log` |
| Additional audit regressions | Late side-child capture links and rejected settings unload both fail | `logs/review5-native-audit-red.log` |
| Concurrent sibling open regression | Fails tracking and final release before correction | `logs/review5-native-concurrent-red.log` |
| Keep before archive startup | Fails with unavailable before correction | `logs/review5-native-keep-startup-red.log` |
| Conditional effort fixture regression | New HTTP case fails with 400; corrected oracle passes all 19 tests | `logs/review5-gateway-red.log`, `logs/review5-gateway-green.log` |
| Full merged Swift helper suite | 912 executed: 905 passed, 7 skipped, zero failures | `logs/review5-helper-full.log` |
| Affected native classes after integration fixes | 201 passed, zero failures | `logs/review5-native-affected-final.log` and `-summary.json` |
| Real guard mutation | All seven selected regressions fail (13 assertions); direct-owner query, metadata ancestry guard, implicit-runtime tracking, recipient invalidation and rejected-unload handling mutated; sources restored in `finally` | `logs/review5-native-mutation.log` and `-summary.json` |
| Restored native guards | 60 passed, zero failures | `logs/review5-native-restored.log` and `-summary.json` |
| Standalone opening, Inspector lifetime and galleries | 10 + 1 + 1 + 1 passed, zero failures; each serial class ran alone | `logs/review5-native-opening-serial.log`, `review5-native-inspector-serial.log`, `review5-native-gallery.log`, `review5-native-keep-gallery.log`, and their summaries |
| One full native parallel lane | 2,586 executed: 2,547 passed, 37 skipped, two failed; see follow-up below | `logs/review5-full-parallel.log` and `-summary.json` |

Gallery roots: `gallery/review5-sub-cost` (46 PNGs) and `gallery/review5-side-keep` (10 PNGs). Inspected `breakdown-light-1240.png`, `sides-breakdown-narrow-dark.png`, `side-shared-overview-light-920.png`, `side-orphan-overview-dark-420.png`, `notice-dark-300.png` and `dismiss-light-920.png`. Cost titles/details align and narrow titles truncate within the card. The shared side names its parent; after orphaning the same Overview gains its independent limit editor with matching $5.00 header/chip values. The merged keep notice and dismissal controls fit at narrow and 920-point widths. The gallery harness also checks geometry, keyboard focus and accessible attribution labels.

### Full-lane follow-up

The full lane exposed a regression in `WorkspaceConcurrencyTests.testAnOpenThatReadTheOldConnectionWaitsForTheSwitchAndOpensTheNewOne`: the early dependency pin reused `sessionOpenCallers`, making `isSessionOpening` true while an open was still waiting behind a connection switch. Budget pins now use a separate caller count; the existing session-opening counter retains its original position and meaning. The unchanged false-state assertion remains, and its fixture now waits for the budget pin explicitly instead of yielding an arbitrary number of times. Concurrent side/direct opens and pending ancestor release still use the earlier budget pin.

The other full-lane failure was `FileHiddenReadTests.testHidingSuspendsDocumentAndFindAndShowingResumesWithoutMovingSelection`, timing out at the `resumed` condition (document reading plus find count 500). Neither that test nor its production code changed in this round or the upstream merge. The unchanged class passed **5/5 alone** in `logs/review5-native-file-followup.log` and its summary; the parallel timeout's cause remains unconfirmed. No second full lane ran; targeted results below are separate evidence, not a clean full-lane claim.

Mutating the real `isSessionOpening` guard to include budget-only waiters reproduced the exact connection-switch assertion (**one test, one failure**) in `logs/review5-native-opening-mutation.log`. The source was restored in `finally`. The subsequent affected run passed **82/82** across WorkspaceConcurrencyTests, SideBudgetIntegrationTests, WorkspaceRefreshLifecycleTests, ConnectionSettingsFlowTests, ConnectionSwitchJournalTests, AutomaticContextTests, PreparedContextLifecycleTests, JournalSlimmingTriggerTests and SubagentCostTests (`logs/review5-native-postgate.log` and its summary).

After that correction, SubagentOpeningTests passed **10/10 alone** and SideBudgetInspectorLifetimeTests passed **1/1 alone** (`logs/review5-native-opening-serial-postgate.log`, `logs/review5-native-inspector-serial-postgate.log`, and their summaries). No helper or rendered UI change followed the helper suite or gallery inspections.

All three round-5 review findings, the ancestry-audit findings and the full-lane opening-state regression are addressed. Remaining work is the lead's independent review/integration and the unconfirmed file-viewer parallel timeout above; historical validation follow-ups remain recorded separately. This stream commits and pushes only `dev/a128-sub-cost`, with a clean worktree after pushing.

## Lead review round 6: discovery isolation and display-free budgets

The five review findings are addressed at their ownership boundaries. Side discovery now isolates failures before an origin establishes family membership; a related ledger still reads strictly, and opening the damaged file itself still reports through history recovery without rewriting it. Reconciliation repairs a loaded managed child's missing initial charge after validating its origin, instead of skipping both the live and disk mirror.

Archive ancestry now comes from `MetadataStore.sideBudgetAncestry`, a metadata-only read of the complete persisted graph. Deletion tombstones apply even when the stale chat row remains. Forks and workspace boundaries terminate ancestry; cycles and undecodable ancestor records do not become evidence of deletion. Restore generations prevent superseded reads from publishing. Unlisted descendants are reconciled without adding them to the chat window.

`SessionBudgetState` holds authoritative numeric spend, current limit and read lifetime without transcript rows, context or capture bodies. Initial open replies and reconciliation results publish into it. Dependency-only owners use a coalesced `session.status` read with `budgetOnly`, which returns only the existing cost snapshot. Runtime retirement cancels the read; connection, runtime generation and state identity fence late replies. Display creation cannot replace this reading with an empty footer. Retained capture totals never stand in for authoritative budget spend, and an unknown owner keeps Continue held. Continue rechecks after opening the family. An Inspector limit editor can observe this lightweight state directly, so Raise limit works without allocating an owner `SessionDisplay`.

### Shared budget invariants

This is the review checklist. Test names below are executable regressions, not just fixture descriptions. `SideBudgetTests`, `SideBudgetReplayTests` and `SideBudgetCorrectionTests` are helper classes; the other classes are native.

| Invariant | Enforcing tests |
| --- | --- |
| Ownership follows actual side origins, not pane placement. Forks own their ledger/children; nested sides and side-owned agents share the surviving root without changing direct delegation identity. | `SideBudgetTests.testForkOfASideStartsAnIndependentFamilyBudgetOnCreateAndReload`, `testNestedSideSharesRootAndItsImmediateParentsTotals`, `testSideOwnedSubagentUsesTheMainBudgetWithoutChangingDelegationIdentity`; `SubagentCostTests.testMountedForkKeepsItsBudgetAndOwnsItsSides` |
| Discovery isolates each unknown file. A damaged unrelated origin cannot block healthy chats; an established related ledger or unreadable directory cannot silently become zero spend. Damaged history remains unchanged and uses recovery when opened. | `SideBudgetTests.testUnrelatedSideWithUnreadableOriginDoesNotBlockHealthyColdOpens`, `testUnrelatedDamagedSideCannotPreventOpeningMainButRelatedDamageIsNotIgnored`, `testUnreadableSideDirectoryCannotSilentlyEraseTheRecoveredFamilyBudget` |
| The root checks the whole family's spend before admission. Already dispatched requests finish and settle, including an owner's request begun before side binding. Separate legacy side limits are ignored while sharing. | `SideBudgetTests.testEphemeralSpendSurvivesDiscardAndBlocksTheWholeFamilyWithoutSideContent`, `testOpeningASideDuringTheParentsRequestNeitherLosesItsChargeNorCancelsIt`; `SubagentCostTests.testSidesInheritTheMainLimitAndForksRemainIndependent` |
| Charges and tokens count once across live binding, cold replay, legacy keyed/unkeyed seeds, adoption before/after delegation and orphaning. Full replay and side recovery agree on dollars, reported/unknown cost counts, token totals and reported/unknown usage counts for every effective attempt state. | `SideBudgetReplayTests.testLegacyShapesHaveIdenticalReplayAndRecoveryTotalsBeforeAndAfterOrphaning` (3,060 cases: 180 legacy shapes × 17 attempt states), `testAdoptionBeforeFirstDelegationCountsOnceThroughRealBindAndColdReload`, `testCopiedAdoptionRecordsNeverResetAnotherOwnersLedger`; `SideBudgetTests.testLegacySideSeedJoinsTheBudgetImmediatelyAndOnlyOnce`, `testKeepAndReloadRetainAttemptIdentityTokensAndDoNotChargeAgain` |
| Unresolved admissions remain admissions during adoption. Dispatched work stays unknown; real settlement replaces it once and proof of non-dispatch removes it. Reload and orphaning retain the same coverage. Admission-only startup recovery still proves non-dispatch using the existing rule. | `SideBudgetReplayTests.testEveryAttemptStateSurvivesColdAdoptionLiveBindingAndReload`, `testRecoveredAdmissionsCanSettleOrBecomeNotDispatchedWithoutCountingTwice` |
| Adoption preserves immutable request identities and capture scopes. An imported legacy attempt is reconciled only by an owner authorized in its original scope; its correction then reaches the shared ledger. Legacy seeds, old checkpoints and owners joining a family retain unknown token coverage. | `SideBudgetReplayTests.testRecoveredAdmissionsKeepTheOriginalCaptureReconciliationAuthority`, `testOlderCheckpointRestoresTheSameUnknownUsageCoverageAsFullReplay`, `testJoiningALiveOwnersBudgetRetainsItsEarlierUnknownUsageCoverage` |
| Loaded and unloaded members both receive durable corrections, including missing initial child charges. Recovery is idempotent and rejects foreign identities. Only derived migration ancestry/local revision may differ in an already-known child mirror. | `SideBudgetTests.testReconciliationCreatesAMissingLoadedChildChargeAndPersistsIt`, `testMissingManagedMirrorRejectsForeignOwnershipAndIgnoresUnrelatedSources`, `testReconciliationUpdatesALoadedSideOwnedManagedMirror`, `testReconciliationRepairsAnUnloadedSideAndItsManagedMirrorOnOpen`; `SideBudgetCorrectionTests.testKnownChildMirrorsIgnoreOnlyDerivedAncestryAndLocalRevision`, `testCorrectionCannotChangeTheRecordedSourceIdentity` |
| Parent deletion repairs remaining evidence before unloading or Trash, including absent/stopped/stopping helpers and resumed deletion intents. Startup or mirror failure preserves the owner and a retryable operation. Saved sides survive as independent owners (or under a surviving side ancestor), retain corrected spend without captures, and never recreate the deleted parent. | `SideBudgetTests.testReconciliationPersistsUnloadedSidesBeforeParentDeletionWithoutCaptureRecovery`, `testForgettingAColdParentRepairsAnInterruptedMirrorBeforeDeletingItsOnlyEvidence`, `testSavedOrphanReopensWithItsOwnSpendAndBudgetWithoutRecreatingParent`, `testExistingUnloadedParentCannotBeBypassedAndNestedOrphansUseTheirSurvivingOwner`; `SubagentCostTests.testDeletingAnOwnerDetachesAndReopensSurvivingSavedSides`; `SideBudgetIntegrationTests.testDeletingWithNoReadyHelperRepairsSavedSideCostsBeforeTrashingOwner`, `testColdOwnerMirrorFailureCannotCommitDeletionAndCanRetry`, `testColdOwnerHelperStartFailureKeepsTheDeletionRetryable`, `testPendingColdOwnerDeletionRepairsBeforeRetryingTrash` |
| Unkept side content remains ephemeral. Only numeric accounting/usage reaches ancestors; discard does not erase spend or recreate a side journal. Paths remain workspace-bound. | `SideBudgetTests.testEphemeralSpendSurvivesDiscardAndBlocksTheWholeFamilyWithoutSideContent`, `testOpeningMainAdoptsLegacySavedSidesWithoutReopeningTheirContent`; `SideBudgetCorrectionTests.testDiscardedSidesAreNeverRecreatedAndSymlinksCannotEscapeTheWorkspace` |
| The chat-list window is presentation only. Persisted ancestors can be opened outside it; persisted descendant/archive mappings are reconciled from the store on deletion and reload. Damaged metadata is not a deletion. | `SubagentMetadataTests.testListedSidesAndManagedChildrenRetainBudgetAncestorsOutsideTheRootWindow`, `testPersistedBudgetProjectionHonorsForkDeletionDamageAndProjectBoundaries`; `SideBudgetIntegrationTests.testColdSideOpensPersistedAncestorsMissingFromTheListedChats`, `testPersistedUnlistedSideAncestryRetiresAfterParentDeletionAndReload` |
| Owners have authoritative spend/limit without displays or retained captures. Reads coalesce, reject retired runtime replies, and do not materialize transcripts. Unknown spend cannot unlock Continue; opening a display cannot lose known spend. | `SideBudgetTests.testBudgetStatusReadsNumericStateWithoutTranscriptOrCaptureContext`; `SideBudgetIntegrationTests.testBudgetOnlyOwnerPublishesDurableSpendWithoutATranscript`, `testBudgetOnlyRefreshCoalescesAndRejectsRetiredRuntimeReplies`, `testMissingOwnerReadingCannotOfferContinueFromRetainedCaptureTotals`, `testOpeningATranscriptPreservesTheAuthoritativeBudgetReading` |
| Runtime ownership and presentation lifetime stay separate. Dependents/opening callers pin ancestors, busy close is not unload, and the last released dependent frees an implicit owner while direct/Inspector use retains it. | `SideBudgetIntegrationTests.testLastDependentReleaseUnloadsImplicitAncestorsButKeepsDirectUses`, `testConcurrentSideOpensShareAndReleaseTheirImplicitWriter`, `testFailedSideOpenReleasesPartiallyOpenedAncestors`, `testConfigurationFallbackRetainsAnOwnerWhoseUnloadIsRejected`; `WorkspaceRefreshLifecycleTests.testEightDisplayCacheAlsoReleasesEvictedSideBudgetWriters`; `SideBudgetInspectorLifetimeTests.testInspectorPinsAnImplicitWriterUntilItsWindowCloses` |
| UI controls follow current ownership and default/override choices. Raise limit edits the actual owner without a display; an orphaned open Overview gains its own editor without recreation. Footers explain the contribution, with compact accessible breakdowns. | `SideBudgetInspectorLifetimeTests.testRaiseLimitFromNestedSideHasAnEditableOwnerWithoutADisplay`; `SubagentCostTests.testOrphanedSideClearsTheFormerBudgetAttribution`, `testCostHelpIsAccessibleCompactAndAbsentWithoutChildren`; `CostLimitTests`; `SubagentCostGalleryTests.testCostAttributionScenes` (light/dark, 420/920/1240, keyboard/accessibility checks) |
| Reports, dashboard, menu bar, footer and Inspector count each physical request once. Ancestry changes invalidate retained projections/caches without modifying physical capture identities. Coordination navigation uses the direct owner. | `SubagentCaptureTests.testSidesAndTheirSubagentsRollUpOnceAcrossEveryAccountingSurfaceAndReload`, `testRetiredSideAncestryRepairsHistoricalAndFutureCapturesWithoutChangingIdentity`, `testAttributionKeepsMissingCostUnknownAndExcludesUndispatchedRequests`; `SubagentCostTests.testOrphanTransitionRefreshesRetainedAttributionOnExistingDisplaysAndCachedRows`; `SubagentSteeringInspectorTests.testSideOwnedCoordinationLinksUseTheDirectOwnerAcrossOrphaning` |

Existing per-side limit values remain stored for compatibility but do not override a surviving owner's budget. No side content, journal format, model tool schema, permission, vault or capture policy changed. The `budgetOnly` option is a native read projection of existing helper state. Old journals remain readable. Older test/gallery fixtures that simulated deletion by changing only `model.chats` now persist the same change; production ancestry deliberately has no in-memory-window fallback.

### Round 6 validation

All commands used the stream's build root `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost`. Native checks used `scripts/test-macos.sh -only-testing:PiAppTests/<Class>` with `PI_BUILD_ROOT` and the test scratch root forwarded. Serial classes ran alone. Helper checks used `swift test --scratch-path <build-root>/helper-tests --jobs 4`. No named result bundles, installed app, real preferences/Keychain or paid requests were used.

| Check | Result | Evidence under build root |
| --- | --- | --- |
| Discovery regression before the fix | Both truncated/overlong pre-origin fixtures block the unrelated healthy open | `logs/review6-helper-red.log` |
| Missing loaded child charge before the fix | One test fails four runtime/durable assertions | `logs/review6-helper-mirror-red.log` |
| Lightweight helper read before the fix | One test fails: ordinary status returns transcript/context fields | `logs/review6-helper-budget-read-red.log` |
| Unlisted orphan mapping and owner spend before the fixes | Two failures among nine tests | `logs/review6-native-red-behavior.log`, `-summary.json` |
| Raise limit before the fix | One failure among two serial tests: owner editor absent | `logs/review6-native-inspector-red.log`, `-summary.json` |
| Additional state regressions before the fixes | Two tests fail: missing owner reading unlocks Continue; new transcript loses known spend | `logs/review6-native-state-red.log`, `-summary.json` |
| Full helper suite | 916 executed: 909 passed, seven skipped, zero failures | `logs/review6-helper-full.log` |
| Helper real-guard mutations | All four selected tests fail, 11 assertions; per-file isolation, missing mirror repair and numeric-only status disabled | `logs/review6-helper-mutation.log` |
| Restored helper budget classes | 35 passed, zero failures, including replay's 180-case matrix | `logs/review6-helper-restored.log` |
| Native real-guard mutations | Four integration tests and one standalone Inspector test fail when store projection is windowed, authoritative state is bypassed and the editor requires a footer | `logs/review6-native-mutation.log`, `review6-native-mutation-inspector.log`, and summaries |
| Retired-reply guard mutation in isolation | One test fails two assertions: late $0.10 overwrites $1.60 without cancellation/generation checks | `logs/review6-native-stale-mutation.log`, `-summary.json` |
| Restored affected native classes | 207 passed, zero failures across 21 classes | `logs/review6-native-affected.log`, `-summary.json` |
| Final side integration class | 12 passed after strengthening the unknown-owner fixture with an actual retained $0.20 capture total | `logs/review6-native-final-side.log`, `-summary.json` |
| Standalone serial opening, Inspector and gallery | 10 + 2 + 1 passed, zero failures, each class alone | `logs/review6-native-opening-serial.log`, `review6-native-inspector-restored.log`, `review6-native-gallery.log`, and summaries |

Mutation drivers restored the original sources in `finally`. The first missing-mirror fixture incorrectly removed journal IDs and failed branch validation; the corrected fixture preserves links and omits only the cost custom record. Only the corrected four-assertion run is used as behavioral evidence. Likewise the initial native fixture extraction had a compile error, corrected before the behavioral red run.

Gallery: `gallery/review6-sub-cost` contains **52 PNGs**, including six `budget-only-owner-{light,dark}-{420,920,1240}.png` scenes. Visually inspected the light 420/1240 and dark 420/920 owner editors, `side-orphan-overview-dark-420.png`, `sides-breakdown-narrow-dark.png` and `breakdown-light-1240.png`. The owner editor shows authoritative $1.63 against a matching $5.00 header/default chip without a display. Side/sub-agent costs remain visibly included in the surrounding Overview; narrow titles truncate within aligned rows and the controls wrap. The orphan shows its own $0.40 and an editable limit. Gallery assertions cover full accessible labels and keyboard reachability.

### Round 6 full-lane follow-up

The **one full native parallel lane** executed **2,592 tests: 2,554 passed, 37 skipped, one failed** (`logs/review6-full-parallel.log` and `review6-full-parallel-summary.json`). The failure was `SessionStatsPopoverTests.testHoveringTheOverviewChartsRedrawsOnlyWhatFollowsThePointer`: `panels` was 1 rather than 0 during the hover measurement. Its chart-mark and pointer/caption assertions passed. Failure details were saved before result-bundle pruning in `logs/review6-hover-full-test-details.json` and `review6-hover-full-activities.json`.

The unchanged class then passed alone: **seven passed, one skipped**, with 32 hover steps rebuilding **zero pages and zero chart marks** (`logs/review6-native-hover-followup.log` and summary). The full-lane failure's cause remains unconfirmed; the standalone pass does not turn the full run green. No assertion was weakened, no production change followed the full lane, and no second full lane ran. The new shared-budget tests passed in the full lane. The earlier round-5 file-viewer and opening-state failures did not recur in this run.

All five round-6 findings and the two additional authoritative-state gaps are fixed. Remaining work is the lead's independent review/integration and attribution of the intermittent Overview redraw-counter failure. The invariant checklist above is the shared-budget review contract. This stream commits and pushes only `dev/a128-sub-cost`.


## Lead review round 7: repair before cold owner deletion

The helper already repaired interrupted side mirrors in `session.forget`, including a cold owner whose committed journal was the only remaining cost evidence. The native deletion path called it only when the project helper was ready. An absent/stopped/stopping helper therefore let deletion discard that evidence. Resuming an already-persisted deletion intent had the same bypass.

`prepareFamilyDeletion` now starts the normal project helper when an owner journal remains, waits for `session.forget` to repair surviving ledgers, and only then permits a new deletion intent and cleanup. A stopping helper first drains its capture barrier. This uses the existing helper accounting code; it does not open a conversation runtime, allocate a transcript display, require a model connection/key, or send a provider request. The helper retains the normal idle timeout after repair. A missing owner journal needs no repair; other inspection errors fail closed.

Resumed intents also run the barrier before their first cleanup. The persisted owner record supplies its workspace/path even outside the chat-list window. An old intent is not treated as proof that a mirror was repaired. Repeated attempts are idempotent, including a failed file recycle followed by a helper restart. The existing busy-family check and project trust/startup checks remain in force: if the project/helper is unavailable or a ledger fails validation, deletion retains its evidence for retry rather than trashing first. A project removed from configuration must be restored before deleting a remaining journal through this path.

Four new native regressions inspect the real saved side ledgers at the recycling boundary, before any orphan open can repair them. The absent/stopped/stopping matrix removes the model connection and has no retained captures; a $0.90 root correction reaches both nested side journals before Trash. Both reopen twice with exactly one reported request, retain the corrected usage, and reach the surviving owner's $0.50 limit. Failure tests retain metadata/files with no new tombstones, then retry successfully. The resumed-intent test omits the owner from the chat window and proves that a recycle failure does not duplicate a correction on retry. The shared-budget invariant above names all four tests alongside the helper's existing cold-forget regression.

### Round 7 validation

All artifacts are under `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost`. Native runs used `PI_BUILD_ROOT` and `scripts/test-macos.sh -only-testing:PiAppTests/<Class>`; the serial capture-drain class ran alone. Helpers used `swift test --scratch-path <build-root>/helper-tests --jobs 4`. All data/credentials are generated fixtures; no installed app, real preferences/Keychain, paid provider, or named result bundle was used.

| Check | Result | Evidence under build root |
| --- | --- | --- |
| Cold deletion before the fix | Three tests fail: missing correction at Trash/reopen, skipped repair error, skipped startup error | `logs/review7-native-red-behavior.log`, `-summary.json` |
| Persisted intent before the fix | One test fails: correction absent before both recycle attempts | `logs/review7-native-red-resume-behavior.log`, `-summary.json` |
| Affected native classes | 90 passed across nine classes, zero failures | `logs/review7-native-affected.log`, `-summary.json` |
| Standalone capture-drain class | Six passed, zero failures | `logs/review7-native-capture-serial.log`, `-summary.json` |
| Full helper suite | 916 executed: 909 passed, seven skipped, zero failures | `logs/review7-helper-full.log` |
| Real cold-helper guard mutation | All four new tests fail (82 assertions) when unready helpers bypass repair again | `logs/review7-native-mutation.log`, `-summary.json` |
| Restored integration class | 16 passed, zero failures after the mutation driver restored production source in `finally` | `logs/review7-native-restored.log`, `-summary.json` |

The initial test compile caught a missing `try`; the initial resumed-intent fixture also incorrectly assumed `loadChats` filtered tombstones. Both were corrected before the behavioral red runs cited above. The first affected run passed the four new tests and exposed an older relaunch fixture replacing the entire configuration vault with an empty one. It now retains the same in-memory vault across relaunch and waits for the old helper to exit, matching production relaunch; its original deletion assertions remain unchanged.

No UI changes or new gallery scenes in this round. As requested, no full native lane was run. Historical full-lane follow-ups remain recorded above; this round does not claim to resolve the unrelated Overview redraw-counter failure.

The round-7 finding and the resumed-intent variant are fixed. The remaining work is the lead's independent review/integration and the historical validation follow-ups; this change is committed and pushed only to `dev/a128-sub-cost`.


## Lead review round 8: unresolved saved-side attempts

The cold saved-side scanner and live binding copied only terminal contributions. `Entry.effective` also counts unresolved admissions as unknown requests, and the unkeyed remainder already subtracts them, so an omitted admission disappeared from both paths. They now share an accounting-record projection and monotonic adoption merge: preserve admission state and immutable identity/scope, let a real settlement replace it once, and retain proof of non-dispatch. The existing startup rule still retires admission-only work that never reached dispatch; dispatched work remains unknown. Existing budget-attempt/cost rows are used, with no journal-format or model-tool changes.

The replay/recovery comparison now runs 3,060 combinations: all 180 legacy shapes from round 3 crossed with 17 attempt states (empty, admission, dispatch, direct/cancelled non-dispatch, reported/zero/unknown costs, valid/missing/invalid usage, invalid cost, correction/stale correction, and contribution-only reported/unknown mirrors). It compares dollars, reported/unreported request counts, token totals, per-field coverage and unknown-usage counts. Each case scans twice, binds the replay, and includes a deleted-parent variant. Runtime tests cover cold adoption, live binding, repeated binding, reload, orphaning and later settlement/non-dispatch proof.

Adding unknown-usage assertions also exposed older unkeyed seeds and checkpoints omitting that coverage. All unkeyed request counts now remain unknown for tokens; the initial app seed uses the accounting reducer, old checkpoints restore the cached count once at load, and a live owner retains its earlier unknown usage when its first side joins. No transcript-size work was added to snapshots or UI layout. Imported legacy admissions keep their original capture scope: the root lists an attempt for reconciliation only if that scope authorizes it; otherwise the side reconciles it and forwards the result. This does not broaden capture authority.

### Round 8 validation

All artifacts are under `/Users/admin/Library/Caches/BelloSwiftWork/build-sub-cost`. Helpers use `swift test --scratch-path <build-root>/helper-tests --jobs 4`; native classes use `PI_BUILD_ROOT` and `scripts/test-macos.sh -only-testing:PiAppTests/<Class>`. All data comes from generated fixtures and the synthetic/loopback gateway. No installed app, real preferences/Keychain, paid provider or named result bundle was used.

| Check | Result | Evidence under build root |
| --- | --- | --- |
| Expanded replay/recovery matrix before the fix | Fails on omitted admissions and unknown-usage coverage in legacy seeds | `logs/review8-helper-replay-red.log` |
| Old checkpoint and capture-authority regressions before the fix | Two tests fail with three assertions | `logs/review8-helper-authority-checkpoint-red-behavior.log` |
| Live owner's earlier usage before the fix | One test fails with two assertions | `logs/review8-helper-live-owner-red.log` |
| Affected helper classes | 83 passed, zero failures across seven classes | `logs/review8-helper-affected-final.log` |
| Real admission-projection mutation | Five tests fail with 1,460 failures, including the matrix and cold/live/reconciliation paths, when admission-only entries are filtered out again | `logs/review8-helper-mutation.log` |
| Full helper suite after restoration | 921 executed: 914 passed, seven skipped, zero failures | `logs/review8-helper-full.log` |
| Affected native classes | 79 passed across nine classes, zero failures or skips | `logs/review8-native-affected.log`, `-summary.json` |

The mutation driver restored production source in `finally` before final helper/native validation. Initial test iterations corrected a checkpoint fixture that did not create a checkpoint and a runtime fixture that tried to dispatch work already retired by existing startup recovery; neither required changing the production recovery rule. The cited behavioral red runs use the corrected fixtures.

Native coverage: `SideBudgetIntegrationTests` (16), `SubagentCostTests` (11), `SubagentCaptureTests` (12), `SubagentDeletionTests` (10), `CostLimitTests` (13), `CostLimitOpeningTests` (1), `SessionAccountingCacheTests` (5), `ForkCloneReaderTests` (1), and `LiveAccountingTests` (10). All are parallel-lane classes; only this affected selection was run.

No UI changes or new gallery scenes in this round. As requested, no full native lane was run. Historical full-lane follow-ups remain recorded above; this round does not resolve or reclassify them.

The round-8 finding and the additional usage-coverage/authority edges are fixed. Remaining work is the lead's independent review/integration and the historical validation follow-ups. This round is committed and pushed only to `dev/a128-sub-cost`.
