# Bello Agent 0.1.94 validation

Date: 2026-09-24. Version 0.1.94, build 98, arm64 macOS 14+.

## Changes

The owner chose pi's behaviour for the last compaction deviation we had kept.

- **Summary requests are pi's.**
  - A tool result in the text sent for summarizing is `[Tool result]: ` and its first 2,000 characters, as pi writes it.
  - The `[history_read: history:…]` tag after a cut result is gone, and so is the `(outcome: …)` label on a result that failed, was cancelled or has an unknown outcome.
  - The summary prompt no longer ends with our "Additional focus: Keep the history_read references…" line. `Additional focus:` comes only from a `/compact` focus, as pi's custom instructions do.
- **No `history_read` tool.**
  - Requests offer only the session's tools, as pi offers its own.
  - In a chat whose earlier summary still mentions a reference, a call to `history_read` gets pi's reply for a tool the request did not offer.
- **A result over 64 KB names its file.**
  - Pi's agent loop takes a tool's result whole; pi's own tools cut theirs and name the file that holds the rest. Ours do the same, so this applies to a tool that returns more, such as an MCP server.
  - Such a result reaches the model as its first 32 KB and pi's note, `[Output truncated. Full output: <path>]`. The file holds the whole text, and `read` opens it.
  - Before, the model got a `history_read` reference instead.
  - Records saved before 0.1.94 keep their old field and read back unchanged.

## Evidence

- **Full gate** (`scripts/verify-release.sh`) on the release candidate:
  - serial lane: 140 tests, 7 skipped, 0 failures;
  - parallel lane: 1,423 passed, 13 skipped, 0 failed;
  - gallery: 100 screenshots;
  - helper: 423 tests;
  - scripts: wire 31, concurrent 3, acceptance 2, Python 65;
  - all passed in 10 min 37 s.
- **Tests restated to pi's text:** `CompactionPiTests` (the cut tool result, and the turn-prefix prompt ending with pi's instruction), `CompactionSafetyTests` (results serialized with no outcome label), and the tool lists in `ContextPreviewTests`, `ContextGatewayTests`, `scripts/test-native-host.py` and `fixtures/native/compaction_gateway.py`, which now also asserts that no tag or focus line reaches a summary request.
- **New test:** `CompactionSafetyTests.testALargeResultNamesTheFileThatHoldsItWhole`.
- **Removed tests:** the `history_read` paging test and `EditRecoveryTests.testIndependentSummaryCannotRecallDiscardedFutureFromItsBroadSourceList`, which covered only the removed tool.
- **Live compaction test, fixture mode, on the release helper:** 3 of 3 scenarios passed. In the mid-run scenario, the final answer recalled all 10 markers without `history_read`.

## Release provenance

- **Source:** tag `v0.1.94`, one release commit on GitHub. The DMG was built from the local candidate `169308f`, with native tree `45383e4db532b9705a186fe4297a0e856b4142aa` and helper tree `787ed4778d3638c9108a034683d73afed4d08dc9`. Only release-provenance documentation changed after the candidate build.
- **Website publication:** `b09bcd5db59f0f40fb84a0823433ba2d374cf30e`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `c617485e-f1cb-4572-8737-0a449d1a024a`; DMG `a7d7c86d-daf2-4d84-8018-2df7c86843ab`.
- **Public verification** at **2026-09-24 05:28:52 UTC**: the product page advertises 0.1.94, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,714,670 bytes (10.22 MiB)**; SHA-256 `d7d8beb5162f3e600cc5c9d5a3ca4b1cc11bb092ca58ece461db5c4adbe5b57c`.
- **Download:** [Bello Agent 0.1.94](https://belloware.com/assets/BelloAgent-0.1.94.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
