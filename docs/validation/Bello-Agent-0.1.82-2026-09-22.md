# Bello Agent 0.1.82 validation

Date: 2026-09-22. Version 0.1.82, build 86, arm64 macOS 14+.

## Changes and causes

The compact token track previously drew a fill only when every request reported a matching parent count and breakdown. Partial reports therefore looked empty despite having reported tokens. A positive observation now fills the track; known, complete breakdowns still divide it into cache/uncached or reasoning/other shares. Missing breakdowns stay explicitly partial and do not acquire invented percentages. Zero and entirely unreported counts remain distinct.

Captured JSON now has persistent controls outside its scroll view: Expand all, Collapse section, Collapse all and Top. Collapse section targets a visible selection or the branch at the reader's current scroll position, then exposes that branch's opening row. Repeating it moves up the hierarchy. Collapse all returns to the top-level overview. Pending event-frame expansion is cancelled so it cannot reopen a section after the reader closes it. These controls also apply to combined responses and event outlines.

The live duration was calculated inside a TimelineView closure. That closure also ran on parent updates, so streamed updates bypassed the intended periodic cadence. A dedicated duration owner now samples elapsed, AI and tool time no more than once every 500 ms, independently of response rendering. It uses monotonic time for active turns and keeps exact reported terminal readings. New tasks reset immediately. Completion, a finish timestamp or a terminal phase takes precedence over a stale live flag, and a completed execution ignores a late running reading for the same task. The older session run-line formatter also ignored its recorded finish; it now uses that finish instead of continuing to extrapolate to the current time.

## Validation

- Focused native selection: **50 passed, three optional visual tests skipped, zero failures** across CompactTurnReportTests, TurnDurationClockTests, CapturedBodyTests, TurnRequestPopupTests, LiveWorkingIndicatorTests and TurnInfoTests.
- Deterministic clock tests inject updates every 25 ms and require displayed changes only at 500 ms boundaries. They cover exact final values, late running updates, task changes, wall-clock changes, legacy timestamps, missing observations, terminal evidence with an old live flag, and session-footer finish handling.
- Mounted native outline tests expand 1,000 JSON values, scroll away from a selection, collapse the visible branch while preserving the other branch, collapse back to the overview, and return to the top without losing expanded content. Existing full-body, event-stream, Unicode, search, cancellation and asynchronous native-popover checks remain in the selection.
- Final completion follow-up: **12 passed, zero failures** across the clock tests, turn-info tests and the native popup sizing/completion test. An already-open popup receives the final turn, remains usable and preserves its exact duration when checked a minute later using an injected clock. These overlap the selection above and are not an additional 12 distinct tests.

Swift 6 strict concurrency with actor checks, Xcode 16.1 on the remote Apple Silicon Mac. The first build was interrupted when the owner added the completion issue; the subsequent full focused selection passed. Tests use isolated local data. No helper source changed, and unchanged helper/gateway validation is reused. Existing view-update warnings in the broader UI fixtures remain outside this change. Fresh-install and updater/relaunch rehearsals are omitted at the owner's request.

## Release provenance

- Source: tag `v0.1.82`; native app tree `1b6d269002c51ab548148123f6285b4bc02df660`, unchanged helper tree `21c72b240da9f9c1b769d183919444c81c09c0a1`. Only release-provenance documentation changed after the candidate build.
- Website publication: `4d1200d3f11fd6b02c33833da1b021755fa56c5c`; Cloudflare check `106801984691` completed successfully.
- Optimized native build, packaged offline helper/catalog smoke, Developer ID signing, app/DMG notarization, stapling, Gatekeeper and Sparkle artifact validation passed.
- Accepted notarizations: app `337abc69-d387-40b2-93b1-c55f700d1987`; DMG `b1259059-1584-49f0-864b-9b490b5e9acf`.
- Public verification at **2026-09-22 15:01:49 UTC**: product page advertises 0.1.82, canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- DMG: **9,436,559 bytes (9.00 MiB)**; SHA-256 `14d55efaa0b1a22094251cae3befcceb5827e630553749118e5b4dd3e0d3fcd7`.
- Download: [Bello Agent 0.1.82](https://belloware.com/assets/BelloAgent-0.1.82.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
