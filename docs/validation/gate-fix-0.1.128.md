# 0.1.128 release-gate repairs

Branch: `dev/a128-gate-fix`, based on `02401065d221572a7acab7b2eb50ef14e921eae6`. Comparison: `3b3baa40` (sub-display merged, before sub-cost). All generated data, loopback gateways and native test-host windows; no installed application, real preferences, Keychain or paid provider.

Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-gate-fix`. The supplied `wire.log` and `suite-serial.log` are retained unchanged. Additional text evidence is under `logs/`; the final gate writes `verify-logs/`. No named result bundles were requested.

## Findings and decisions

| Gate failure | Evidence and repair | Pre-sub-cost result |
| --- | --- | --- |
| Cached-prefix side cost: 0.0246 versus 0.0123 | This is the correct family total: one parent request at 0.0123 plus one side request at 0.0123. The revised wire test verifies distinct physical capture IDs, one numeric cost record per physical attempt in the parent, one local side contribution, reported-request counts, and stable separate totals through two cold reopens. No product accounting change. | Original test passes in the complete 36-test wire suite. The accounting contract changed in sub-cost. |
| Side limit: nil versus 2 | `bindSideBudget` clears the local limit; `setCostLimit` ignores a bound side's legacy limit. Shared admission checks ancestors. The revised test proves open/configure cannot override the main limit, side spend reaches that limit, neither main nor side dispatches above it, raising the main limit permits side work, and forks/seeds retain their original independent behavior. Side submit accepts the human input before asynchronous shared admission reports `cost_limit`; main submit can reject immediately. | Original test passes in the complete baseline wire suite. The contract changed in sub-cost. |
| Two sidebar press/cut-out fixtures | Sides are intentionally absent. Ordinary topic chats still indent, so fixtures use them. Real queued mouse presses verify the indented body, Archive, its newly revealed Keep control, adjacent row body and double-click. Confirmation width, renamed-row rerender, narrow resize and restored icon bounds remain covered. | Both original tests fail, with the same five assertions, in the baseline selected serial run. This is display-fixture drift. |
| Rendered Find remains outside the clip | Expansion can finish while disclosure pins the former row height. Size invalidations were discarded during that pin, and Find could accept its target too early. Retain an invalidation until motion ends and defer Find while its row moves or awaits native validation. A held native geometry pin reproduces the race without relying on machine speed. | Original short class run passes. The new deterministic behavioral regression fails against unchanged baseline production, including an offscreen match at y=3616 with a 560-point clip. The defect predates sub-cost. |
| 50 KB result blocks the main thread | Two repeated costs: text adoption compared completed list items on every batch, and focus/scroll-anchor lookup copied row values across the whole transcript on layout ticks. The first optimization alone still failed the full serial heartbeat (120 ms cold, 151 ms expanded), despite Markdown batches below 6 ms. Cache message/row membership when content changes, preserving body priority, end-of-reply rows and latest preceding tool-call issuers. Expansion then makes zero history lookup visits. Also preserve completed Markdown segments only when extending the same immutable source, checking identity and list-marker geometry and rebuilding the possibly partial last segment. Replacement/fold/restyle retain full reconciliation. The 100 ms heartbeat and 50 ms Markdown/draw budgets are unchanged; work bounds cover both repeated costs. | Original short baseline timing runs pass; the supplied 150 ms full-lane timing failure was not reproduced there. Baseline production fails both new work bounds: 10,428 Markdown block visits (maximum 1,362), and 117,087 transcript-row visits during expansion. Both paths predate sub-cost. No claim that the short baseline run reproduced the 150 ms timing sample. |
| Child Find Previous consumes no fresh command | The pane's native Shift-Command-G handler ran before the owning tab, bypassing its command publication. The tab now handles its commands first, inside sheet/popover and visibility guards, then forwards other pane keys. The fixture explicitly supplies the child command window so both paths are exercised independently of window-server timing; a native sheet also rejects Previous. | Original short run passes. The strengthened test fails on baseline production with the same `.show` versus `.previous` and unchanged serial assertions. The handler-order defect predates sub-cost. |

No helper, model-facing tool, permission, capture, vault or journal-format changes. No owner decision beyond the supplied shared-spend/limit and hidden-sidebar-side contracts was needed.

The production files involved in the Markdown, disclosure, lookup and shortcut repairs, and `SubagentPerformanceTests.swift`, are byte-for-byte unchanged between `3b3baa40` and `02401065` (`git diff` is empty for those paths). The sub-cost transcript changes add the cost presentation to `ToolView`/`SubagentToolView` and display it on the card; the sampled expansion path is native text and transcript lookup/layout, without family-cost traversal. The repeated comparisons/scans and shortcut/disclosure ordering predate that merge.

## Failing-first and mutation evidence

- `logs/baseline-wire.log`: original complete wire suite, 36/36.
- `logs/baseline-native.log`: 82 tests; the two obsolete sidebar tests fail (five assertions); the three other originally reported methods pass in this short run.
- `logs/current-native-red.log`: after updating only the sidebar fixtures, 82/82 with original production. This short run also demonstrates why the timing races need deterministic coverage.
- `logs/deterministic-red.log`: both strengthened Find regressions fail against the original merged production. Temporary prefix timings showed at most about 2 ms in prefix construction; they were removed. `logs/markdown-sample.txt` is diagnostic sampling only; timings in the sampled repetition run are not acceptance measurements.
- `logs/baseline-deterministic-red.log`: unchanged baseline production with the new tests, 4 tests and five failed assertions across the two Find tests.
- `logs/baseline-performance-red.log`: 2 tests, one work-bound failure, 10,428 block visits.
- `logs/wire-contract.log`: both revised wire cases pass against the merged Release helper, including numeric-journal and cold-reopen checks.
- `logs/mutation-native.log`: disabled the actual row button exclusion, motion/height guards, tab-first shortcut dispatch and immutable-prefix optimization in a temporary build. All four targeted tests fail, seven assertions total. Sources were restored automatically after the run.
- `logs/native-green.log`: 98 tests, zero failures, including the affected classes and disclosure tests.
- `logs/native-restored.log`: 116 tests, 3 skipped, zero failures after restoring mutations; also covers native Markdown surfaces/sizing and ordered-marker/replacement/fold parity. Expansion performs 684 block visits, maximum Markdown batch 5.80 ms, maximum heartbeat 80.49 ms and maximum explicit draw 24.91 ms in this run. Thresholds are unchanged.
- `logs/gate-attempt-1/suite-serial.log`: complete first serial lane, 880 tests, 42 skipped, two heartbeat failures in the performance case; every other case passes. Stopped the gate before its parallel lane to repair the remaining work. The full run exposed what the short runs did not.
- `logs/lookup-red.log`: 111,843 transcript-row visits during one expansion, failing the new work bound with the first Markdown optimization present.
- `logs/baseline-lookup-red.log`: unchanged baseline lookup/Markdown logic with counters and assertions, 117,087 row visits and 10,428 block visits; both work bounds fail. The original timing limits pass in this short baseline run.
- `logs/lookup-green.log`: 58 tests, zero failures, including Find, reveal/navigation, retained rows, update isolation and history replacement. With indexed lookups, expansion makes zero row visits and 684 Markdown block visits; maximum heartbeat 45.05 ms, Markdown batch 5.65 ms, explicit draw 14.38 ms.
- `logs/lookup-membership.log`: 10 tests, zero failures. Added coverage for duplicate membership, changed source messages inside the same retained row, clearing a chat's lookup, reused tool-call IDs, page replacement and cosmetic streaming patches. Expansion heartbeat 38.44 ms, zero row visits.
- `logs/lookup-mutation.log`: bypassed the actual page/document indexes, restoring their former searches. The performance case fails the work bound with 119,083 row visits. Both source files were restored automatically.
- `logs/final-targeted.log`: restored caches, 14 tests, one opt-in original-reader gallery skipped, zero failures. Expansion heartbeat 37.66 ms, Markdown batch 5.64 ms, explicit draw 12.87 ms, 684 block visits and zero history-row visits. Includes the membership/replacement cases and regenerated standalone galleries.

## Final validation

The complete release gate passed on 2026-10-16, 10:20:36–11:16:56 SGT, in 56 minutes 20 seconds with exit status 0 and zero failures:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-gate-fix scripts/verify-release.sh
```

It built the Release helper, ran the serial lane alone, the full parallel lane with eight workers, isolated helper cost tests, the remaining helper and views tests, the screenshot gallery, and the wire/concurrent/acceptance and script Python suites. This was the one full native parallel run after the final production changes. `scripts/dev-wire.sh` is not present in this checkout; the gate supplies the Release-helper commands directly. Summary: `logs/final-gate.log`; per-suite logs: `verify-logs/`. The gate collected no test-process crash reports.

In the final full serial run, the 50 KB performance case passes: maximum cold heartbeat 50.24 ms, expansion heartbeat 94.59 ms, expansion Markdown batch 5.79 ms and explicit draw 12.84 ms. Expansion performs 684 block visits and zero history-row visits. The 100 ms heartbeat limit is unchanged; these are full-lane results rather than the faster short-run figures above.

- Full native serial lane: 880 executed, 42 skipped, zero failures (1,951 seconds). Every originally reported native case passes.
- Full native parallel lane: 2,630 passed, 38 skipped, zero failures (eight workers). Both native lanes completed in 2,373 seconds.
- Full helper suite: 966 executed, 7 skipped, zero failures: 5 isolated `StreamingCostTests` plus 961 remaining tests (7 skipped).
- Views package: 307 executed, 3 skipped, zero failures.
- Release-helper Python suites: wire 36/36, concurrent 4/4 (including 20 sessions across four projects), acceptance 3/3.
- Python script tests: 86/86.
- Release `UIScreenshotTests`: 3/3, 230 images in `verify-gallery/screenshots/`. The sidebar/archive light and tab Find dark captures were also spot-checked at full size.

Standalone `SubagentMarkdownGalleryTests` and `SubagentPanelGalleryTests` ran with `scripts/test-macos.sh -parallel-testing-enabled NO`: 4 tests, 1 opt-in original-reader gallery skipped, zero failures. They were regenerated after the lookup repair in `logs/final-targeted.log`; all 100 final images were visually reviewed, covering light/dark, 1240×800, 920×600, narrow split panes, folded/expanded Markdown, child readers and nested family menus. No new clipping, overlapping controls or theme regressions were found. Image directories under the build root:

- `gallery-markdown/`: 28 images.
- `gallery-panel/`: 68 images.
- `gallery-nested/`: 4 images.
- `gallery-review/contact-01.jpg` through `contact-13.jpg`: contact sheets for review, with narrow Markdown and reader originals also checked at full size.
