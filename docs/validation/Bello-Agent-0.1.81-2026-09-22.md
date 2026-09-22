# Bello Agent 0.1.81 validation

Date: 2026-09-22. Version 0.1.81, build 85, arm64 macOS 14+.

## Change

The turn Info action opens a compact native popover with a brief overview and one selected request. Request and Response tabs expose captured headers and complete retained bodies. Search scans the selected representation and its headers, including closed JSON children, with case-insensitive Unicode matching and next/previous navigation. Combined streaming JSON, events, formatted JSON, UTF-8 and hex views remain available where applicable. A bounded match index keeps common searches from allocating one result per byte; it does not truncate the body. Missing or expired bodies do not prevent searching retained headers.

The popup refreshes while visible during active requests, shares the existing working/compaction/retry styling and preserves request selection. Metadata queries page internally to collect every request for the selected turn, then load only the selected payload. Turn ownership excludes requests that merely reuse the turn as later context. Search/rendering uses the bounded payload worker, with a typing debounce and stale-result guards. A fixed 680-by-640-point NSPopover avoids a SwiftUI size-feedback failure observed during development inside virtualized transcript rows.

Compact reports show grouped exact token counts, two-decimal token shares, requested/returned model pairs, AI/tool timing and high-precision costs. Millisecond and sub-millisecond values remain visible. Cost labels retain up to twelve fractional decimal places, using six significant digits for smaller nonzero values; reported zero remains distinct from missing cost. The session footer uses the same precise cost formatter. Cached input and reasoning output remain subsets of input and output respectively.

## Validation

- Final native accounting/report/popup selection: **49 passed, one optional screenshot test skipped, zero failures** across CompactTurnReportTests, GatewayAccountingTests, TranscriptActivityTests and TurnRequestPopupTests. This selection ran after the final shared cost-formatter and expectation updates.
- Earlier payload/streaming/rendering selection: **87 passed, two optional tests skipped, zero failures**, covering CapturedBodyTests, CombinedResponseTests, CompactTurnReportTests, LiveWorkingIndicatorTests, MetricPillsTests, TurnInfoTests, TurnRequestPopupTests and the real-app screenshot gallery. Its unchanged payload and streaming results are reused.
- Synthetic Responses gateway fixture: **16 Python tests passed**, including the request-aware streaming event sequence used by the real app.
- Popup regressions cover turn ownership, 130-request pagination, compaction scope, live/archive merges, selection stability, stale asynchronous results, complete large-body/Unicode search, headers without bodies, and asynchronous native popover sizing. Numeric tests cover exact token counts, percentage denominators, zero/micro-costs and millisecond precision.
- Pointer/keyboard checks and screenshots of the actual native app cover completed turn details, request-header search, response search and a streaming combined response. The app used an isolated synthetic local gateway; no production gateway was called. Both completed and ongoing states were reviewed. Final screenshots were supplied to the owner separately.
- `git diff --check` passed. Existing helper validation is reused because this change does not modify helper sources.

Xcode 16.1 and Swift 6 strict concurrency, with actor checks in the focused native run. Existing SwiftUI view-update warnings in the broader fixture remain; this release does not claim to eliminate them. Fresh-install and updater/relaunch rehearsals are omitted at the owner's request. Signing, notarization and public artifact verification are still required below.

## Release provenance

Release source reference: Git tag `v0.1.81` on `BelloWare/BelloAgent`.
App source tree: `0ad16c61195773fc03f304644ae56df45c576bf4`.
Helper source/test tree: `21c72b240da9f9c1b769d183919444c81c09c0a1`.
Runtime source trees are unchanged by the final publication documentation.

Website publication: `653ade35ba23e0360776e1cb60730767988169b0` on `BelloWare/belloware.com` `main`.
Cloudflare check **106776224579** succeeded. The public product page advertises
0.1.81 and its installer; both public feeds match the local canonical feed byte-for-byte.
The downloaded installer matches SHA-256 and verifies with the Sparkle Ed25519 key.
Verified **2026-09-22 13:59:35 UTC**. The product-page check follows the site's
redirect from `/bello-agent.html` to `/bello-agent`.

`BelloAgent-0.1.81.dmg`: **9,423,705 bytes (8.99 MiB)**.
SHA-256: `3f2674c14b0ea679c4171f70af32538fc8d88477923d4dd864b5eea115f35011`.

Developer ID signing, packaged offline helper/catalog smoke, app and DMG notarization/stapling,
Gatekeeper assessment and artifact validation passed. Apple accepted app submission
`bc59403e-d304-4f8d-a7f0-3e8ccb41c24c` and DMG submission
`d1cfa42f-7f68-442f-a4bf-78430193558c`. Versioned artifacts and dSYMs remain in the external
build directory. No installation or updater/relaunch rehearsal was performed.
