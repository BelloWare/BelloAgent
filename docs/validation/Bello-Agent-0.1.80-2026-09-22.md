# Bello Agent 0.1.80 validation

Date: 2026-09-22. Version 0.1.80, build 84, arm64 macOS 14+.

## Change

Completed and ongoing turns share a compact report. The header keeps the response model and cost visible, with Info and Copy. Duration is split into recorded AI request time and tool time. Slim percentage bars partition input into cached/uncached tokens and output into reasoning/other output. Subsets are never added to their parent totals again. Full exact counts, coverage and request details remain in the Info table.

Percentages require complete, matching observations. Missing usage, partial coverage and reported zero remain distinct. Zero denominators leave an empty track; tiny nonzero shares display <1% and near-total cache shares do not round up to 100%. Zero and micro-costs remain visible. Requested model aliases and response-body model names are paired from the same retained attempt. Different names display as requested → responded; matching names display once. The latest pair follows dispatch wall time across message owners. Info, per-response accounting and turn copy retain the original pairing. Old snapshots without requested-model observations do not infer them from the current picker. The duration slot is visible from the start; Stop stays in the composer.

This release also includes the reviewed Claude transcript work: chronological response parts, one card per tool call, persistent folds, incremental Markdown delivery, reading-position ownership and session request/usage summaries.

## Validation

- Requested/returned routing follow-up: the 59-test native selection passed 58 tests; its new reopen test initially omitted archive configuration. After correcting that fixture setup, the focused reopen test passed. This selection covers gateway accounting, the 100,000-attempt scale fixture, live accounting/cache refresh, turn reports and copy. The scale query over 101 visible targets and 300,100 links took 845.881 ms off the main actor.

- Compact report and integration selections: **78 distinct focused native tests passed** across the 43-test accounting selection, 44-test chat/reading/tool selection and final six-test compact-report selection (overlapping suites counted once). Includes real SwiftUI layout at 280/640/900 points, matching denominators, missing/zero/conflicting values, micro-costs, model changes, native reading stability, working indicator and tools.
- Optimized report selection: **24 tests passed, zero failures**, with actor checks. Covers compact reports, the working indicator, turn info and stable tools, including the actual packaged helper and two mounted panes against the synthetic Responses gateway. The final <1% edge formatting is also covered by the final Debug selection.
- Visual checks: actual SwiftUI components in both themes and at side-chat width; a full app core gallery through the local request-aware Responses gateway, including completed token shares and an ongoing response. Screenshots use synthetic data. No production gateway was called.
- Reused passing validation for unchanged helper and transcript logic: **306 helper tests**, the prior **124-test native selection (one skip)**, and **24 optimized streaming/chronology/reading tests**. This is not a claim that a new full-suite run passed.
- Prior optimized synthetic streaming validation: decode/apply/regroup **0.974 ms** per row delta; real mounted app **823 frames over 12 seconds**, mean 3.73 ms, p95 8.31 ms, maximum 19.91 ms, with no visit to an unprepared row. These results describe that synthetic workload, not a guarantee of physical display cadence or unlimited history size.

Xcode 16.1, Swift 6 strict concurrency, remote Apple Silicon Mac. Native UI checks run against isolated fixtures; Debug and Release caches are reused. Existing SwiftUI view-update warnings in the broader fixture remain; the tests did not establish their removal. Fresh-install and actual updater/relaunch rehearsals were skipped at the owner's request.

## Release provenance

The locally staged 0.1.79 candidate was superseded before publication when requested/returned model display was added. Only 0.1.80 was selected for publication.

Release source reference: Git tag `v0.1.80` on `BelloWare/BelloAgent`.
App source tree: `cfcf21fabe3ac5f6b2dd025df88cbd3e1ecdcc5e`.
Helper source/test tree: `21c72b240da9f9c1b769d183919444c81c09c0a1`.
Runtime source trees are unchanged by the final publication documentation.

Website publication: `1ce4d72ed765165605841cd1d22dbb91f985b577` on `BelloWare/belloware.com` `main`.
Cloudflare check **106718080190** succeeded. The public product page advertises
0.1.80; both public feeds match the local canonical feed byte-for-byte. The downloaded
installer matches SHA-256 and verifies with the Sparkle Ed25519 key. Verified
**2026-09-22 11:06:46 UTC**.

`BelloAgent-0.1.80.dmg`: **9,383,184 bytes (8.95 MiB)**.
SHA-256: `235e1be074b20e51a170987ff77b2cb7fa53e0da107c297c53b6e6cc3bac687e`.

Developer ID signing, packaged offline helper/catalog smoke, app and DMG notarization/stapling,
Gatekeeper assessment and artifact validation passed. Apple accepted app submission
`5173b8f4-ab95-4f33-a59f-c16525fe935c` and DMG submission
`77ecec41-0283-4ab8-b97b-b2db83463847`. Versioned artifacts and dSYMs remain in the external
build directory. No installation or updater/relaunch rehearsal was performed.

