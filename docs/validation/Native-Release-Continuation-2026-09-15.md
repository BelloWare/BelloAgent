# Native release continuation — implementation and verification

Branch `master`, continued from `da6028153bea8d0b94a4b9a5bbae11158a64030d`.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
Source includes `6017b01` (native relaunch/streaming acceptance),
`6657168` (historical-tool validation and wire checkpoints),
`471336e` (display timing), `547691d` (strict packaged Mac test),
`38d5f59` (indexed accounting query), `2788b10` (accounting UI/archive),
`833b2e3` (request-aware fixtures), `be17810` (gateway telemetry),
`7887d83` (plaintext storage) and `12f3272` (credential hashing).

## Scope and implemented behavior

Current owner instructions authorize release after validation, plaintext new
HTTP bodies, request-key hashing and LiteLLM cost/cache reporting; they defer
full-text HTTP body search. SwiftUI/AppKit composers, React/WKWebView transcript
and the native Swift helper remain the selected architecture.

The HTTP request still uses its original credential. Captured auth headers use
SHA-256 fingerprints. Known credentials within a serialized request body are
replaced only in the capture, with transformations, byte counts and non-exact
status retained. Omitted bodies have no original-body digest or empty export.
New shared chunks/digests are plaintext; older encrypted chunks remain readable
with their existing vault key. Wrong/missing legacy keys preserve stored data.

Gateway costs come from final reported usage or completed JSON headers, not
local price estimates or preliminary streaming headers. Response-cache state
requires an explicit documented header; provider prompt-cache tokens remain
separate. Per-message attribution can overlap; session/report totals count each
local attempt once and show unknown/invalid/conflicting evidence and coverage.
Metric retention is independent of body retention. Projection backfill resumes
across failures, and preference/report refresh updates cached chat totals.

## Deterministic and packaged checks

All build products and raw logs are in the remote session scratch directory.
No production model credentials or production vault item were used.

| Check | Actual result |
| --- | --- |
| Swift core, final display helper | **58 XCTest passed**, including 8 display-timing regressions; `display-final/core-tests-final.log`. |
| Optimized helper HTTP suite | **19 cases passed**, including **24 malformed-request probes**; `release-final/final-strict-host.log`. Uses the final stripped helper and historical-tool validator. |
| Process/MCP acceptance | **2 passed** on the optimized telemetry helper; `release-final/final-process-acceptance.log`. |
| Full native app suite | **74 registered, 73 passed, 1 opt-in UI harness skipped, 0 failures**; `release-final/final-macos-tests-fixed.log`. Uses the final gateway/accounting helper before the display-timing-only change. |
| Final interactive native XCTest | **1 passed in 447.418 seconds**; `native-final/ui-run-final-checkpoint.log`. 30 retained bodies independently verified, including all 6 current-run durable bodies. Two earlier disk-full attempts remain explicitly unverified. |
| Native accounting review | **29 passed**: dashboard 7, accounting 8, archive 12, routing 2. Includes interrupted backfill and unloaded-chat retention refresh. |
| Accounting at retention limit | **9 passed**: accounting 8 plus scale 1; `accounting-scale/xcode-indexed-test.log`. |
| TypeScript | Passed; `release-final/typecheck-final.log`. |
| Fixture and release scripts | **23 passed**; `release-final/final-fixture-release-tests.log`. Includes four historical-tool HTTP regressions and isolated website/publication-order fixtures with external commands mocked. |
| Provisioning validator | **1 passed**, with rejection subcases; `release-final/final-provisioning.log`. This is not a signed Keychain identity test. |
| Final packaged integration | **1 passed** after final helper staging; `release-final/final-display-integration.log`. Actual helper → strict HTTP → native archive → reopen. |
| Unsigned Release compile | Passed with final helper embedded; `release-final/final-display-release.log`. |
| Packaged smoke | Passed; `release-final/final-packaged-smoke.json`. Swift handshake, orderly EOF, MCP and absence of a bundled Node runtime. |

The strict loopback gateway independently validates method/route, API-specific
headers and fields, alias, stream flag, output limits, native tool schemas and
complete call/result pairs. Tool continuation must contain the actual README
result previously requested by the fixture. Compaction must include the source
history with tools disabled. Native/pinned versus portable replay is checked.
Identical serialized requests cause cache MISS then HIT; error/cancel responses
are selected by the request. Negative probes mutate real outgoing requests and
must fail, rather than receiving canned success.

Both APIs compare actual submitted/received bytes to helper captures and
acknowledged durable packets. The packaged Mac test now also uses the strict
scenario with a custom header and explicit portable replay: four tool-cycle HTTP
attempts, eight retained bodies, native cost/cache assertions and archive reopen.
See the [accounting source contract](../LiteLLM-Accounting-Contract.md).

## Issues found and resolved

- Credential omission was initially representable as a complete empty body in
  the native archive. It now stays unavailable with no digest/export, including
  after restart.
- Accounting schema additions could survive while a partial backfill was lost.
  A persisted projection marker is invalidated before ALTER and set only after
  every batch succeeds. A 65-record test injects failure in the second 32-row batch,
  then reopens and verifies all 65 reports recover.
- Retention edits could expire metrics without refreshing an unloaded chat's
  cached totals. Native configuration/report refresh now updates those projections.
- At 100,000 requests/300,100 links/101 visible messages, SQLite chose a broad scan.
  EXPLAIN identified the loop order; target-first indexed joins preserve results
  and reduced the real Debug query from 3259.024 ms to 387.629 ms (about 8.4×).
  Session-only 36.862 ms and one-message 40.374 ms were measured separately. The test
  asserts exact scope/attribution/coverage, not a brittle machine timing limit.
- The first full Mac run rejected the old synthetic test credential with HTTP 422,
  producing seven assertions in its single capture test. The test was updated to
  the strict request-aware scenario; the full rerun passes. The same failed run
  exhausted disk during Xcode result export. Obsolete generated build caches were
  removed; source, text evidence, fixtures, release files and outbox were preserved.
- Swift initially emitted no `displayObservedAt`, so WebKit receipt-to-paint could
  not be called helper-delta latency. The helper now retains the earliest actual
  visible model/tool mutation by message, consumes only included changed projections,
  and preserves observations through status polling and async snapshot boundaries.
  Initial/resumed/off-page history does not manufacture live samples.
- The strict UI gateway initially rejected a read-only side carrying earlier bash
  history because bash was absent from the current tool list. Known historical
  schemas now validate completed call/result pairs without granting the side a
  new tool. Unknown, malformed or unpaired history still fails. Four HTTP
  regressions cover this distinction. Wire records are checkpointed atomically
  after completed/cancelled requests, rather than only at harness shutdown.
  Two captures from the earlier disk-full run have no surviving independent
  server record; they are explicitly unverified historical evidence, not rebuilt
  from the archive. Every current-run capture must still match the wire record.

## Native UI and performance

See [native acceptance](Native-Release-Acceptance-2026-09-15.md) for exact CUA runs,
PIDs, fixed-port fixture relaunch, body verification and numeric windows. Covered
workflows include both APIs/tools, focused global commands, explicit-only skills,
instruction/discovery panels, MCP list/describe/confirmed invoke, cost/cache
messages/session/report, main/read-only-side concurrent streaming, 100 saved chats
with 10,000 messages each, 50 MiB tool output and saved Unicode drafts.

The initial paced-key window measured p95/p99 input-to-draw 6.63/7.88 ms; the separate
bulk-CUA injection window measured 216.61/259.74 ms and did not meet the historical
50/100 ms target. Both are retained and neither replaces the other. Process-tree
RSS mean/peak 570.31/755.75 MiB excludes the synthetic gateway and includes native,
helper and observed WebKit processes; RSS can double-count shared pages and
one-second sampling can miss shorter peaks. Real language IME candidate input
remains unverified; native marked-text tests and Unicode paste are narrower checks.

The final corrected helper run passed its functional XCTest in 447.418 seconds.
Fresh requests reached both APIs, both main and read-only side were observed
streaming before and after 80 paced keys, and native Stop cancelled both. Those
80 input-to-draw samples measured p50/p95/p99 **2.17/6.23/48.94 ms**. Across the
full focused streaming window, 177 calibrated helper-to-paint observations
measured **92.74/175.96/308.63 ms**, maximum **485.90 ms**. This is a post-paint
task upper bound, not physical scanout. The corrected result exceeds the
historical 75 ms p95 display target. It does not replace the older burst failure
or establish a passed Release performance budget. See the native evidence for
exact artifacts, workload and all timing boundaries; no samples were trimmed.

## Release gates and publication

The final unsigned engineering package uses the stripped optimized helper:

- Helper: **1,580,368 bytes**, SHA-256
  `4fa44e0427bd897959209f07f8a000a049f0ed4426dbc60a4358cb30c123fa6b`.
- APFS/ULFO DMG: **3,086,080 bytes (2.94 MiB)**, SHA-256
  `500cd4b1e92936bbdc2606190ec6a8349e8b7e4351d7a9564afc42b68843562d`.
- `hdiutil verify` passed. Version is 0.1.1/build 5; app logical bytes total
  9,597,363. No Node runtime, node_modules or XCTest bundle is included.

Evidence: `release-final/final-unsigned-dmg.log` and
`release-final/final-unsigned-size.json`. This scratch artifact is **unsigned and
not notarized, distributable or published**. It is not placed in the outbox, and
its size does not establish the final signed/notarized release size.

Release notes, product-page/homepage/sitemap staging and version 0.1.1/build 5 are
committed. Isolated tests prove invalid metadata, oversized installer, unsafe
paths or failed signature/notarization checks prevent website writes/publication.
Local desktop and 390 px product-page previews were reviewed and clearly marked
unpublished; no fake installer was supplied.

Production Keychain uses `43TXHV3TM3.com.belloware.PiApp`. No installed profile
authorizes it. The existing Apple release key returned HTTP 403 when asked to
register PiApp; Safari was rechecked after the final UI run and remains at the
empty Apple Developer sign-in form. Owner sign-in or an authorized Developer ID
profile has been requested. No registration/profile was created, no private key
was exported, and no fallback vault was added. Signed read/write/update identity
acceptance, notarization, final signed DMG and actual Sparkle installation remain
blocked on this prerequisite. Release authorization already exists.

No new app, DMG, product page or appcast was published in this continuation.
The belloware.com working tree remains unchanged. A real LiteLLM endpoint/version,
model aliases and secure key location are also unspecified. The strict local
mock requirement is satisfied; actual deployed gateway compatibility is not claimed.
