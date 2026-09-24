# Bello Agent 0.1.91 validation

Date: 2026-09-24. Version 0.1.91, build 95, arm64 macOS 14+.

## Changes

- **Compaction no longer loops.**
  - In the owner's chat, the summary request (88.3K in) returned exactly 13.1K out: pi's 13,107-token summary cap, used up by the reasoning at the chat's thinking level. The summary stopped at the cap and was rejected, as pi rejects a length stop. Following pi, the run then sent its full request (237K, then 238K) and tried the same summary every round.
  - Summaries now carry the model's own output limit (no summary cap; the owner's choice). It is clipped to the window as pi clips any request, and never below the room the source was packed beside. An unknown model ceiling sends no limit, as for any request. Packing still reserves pi's 0.8 × reserve share (0.5 × for a turn prefix).
  - Mid-run, a failed threshold compaction stops the run with its error, and a compaction that the next measurement still finds over the threshold stops it with `compact_no_progress`. Before a new prompt, a failed compaction still reports and sends, as in pi.
- **Tests.**
  - New: `PiParityTests.testAFailedThresholdCompactionMidRunStopsTheRunInsteadOfLooping` and `testACompactionThatFreesNoRoomStopsTheRunInsteadOfLooping`. The first was shown to fail on 0.1.90's loop.
  - Summary-cap assertions and fixture contracts now require the model's own limit.
  - `SteeringAndFollowUpTests` no longer assumes a reply's parallel tool calls begin in call order. `CostLimitTests` sends at the limit only once the reply's cost is counted.

## Evidence

- **Release gate** (`scripts/verify-release.sh`) on this product code:
  - Serial lane: 139 tests, 7 skipped, 0 failures.
  - Parallel lane: 1,403 passed, 13 skipped, 2 failed. Both were stale tests: `ManualCompactionTests` (its fixture still required pi's summary cap) and `CostLimitTests.testSendingAtTheLimitShowsTheNoticeAndADisabledDefaultNeverStops` (a race in the test). Both were fixed, and their classes rerun green (6 tests).
  - Gallery: 94 screenshots. Helper `swift test` 411/411, wire 29, concurrent 3, acceptance 2, Python script tests 55.
  - Only test code and one fixture changed after the gate.

## Release provenance

- **Source:** tag `v0.1.91`, one release commit on GitHub. The DMG was built from the local candidate `f5a01ef`, with native tree `768918b87d2834cc56aaa3637a227633cc47eee7` and helper tree `cbc4aa06dfb16089f549eff37c2d5bcb98e9f6d3`. Only release-provenance documentation changed after the candidate build.
- **Website publication:** `3ef6b6bcad809614f7d50a5f004295037b4cadc0`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `dd8aa235-a974-4b68-a696-8558b1312ad6`; DMG `e25b582d-2fc3-44bb-beaf-102a9c30e501`.
- **Public verification** at **2026-09-24 01:14:22 UTC**: the product page advertises 0.1.91, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,569,935 bytes (10.08 MiB)**; SHA-256 `231bd273a31f78e1089bf6349216248e1cc2ea752c97c766cc38e65db146cc61`.
- **Download:** [Bello Agent 0.1.91](https://belloware.com/assets/BelloAgent-0.1.91.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
