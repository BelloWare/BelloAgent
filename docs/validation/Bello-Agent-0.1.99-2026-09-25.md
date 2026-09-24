# Bello Agent 0.1.99 validation

Date: 2026-09-25. Version 0.1.99, build 103, arm64 macOS 14+.

## Changes

- **One summary request per compaction** (`d99d992`), at the owner's request: "I think there should be just one term, only one… don't split anything into chunks. Just one request."
  - Before, a compaction could send several summary requests. Pi summarizes a split turn's prefix (the kept recent messages begin inside a turn) in a second request. Our fallback summarized a history too large for one request in chained chunks, each updating the summary so far, and it applied whenever the source did not fit beside a quarter of the window kept for output, so a prose-heavy history could chunk at pi's threshold.
  - Now a split turn's prefix is sent in the history's request, in `<turn-prefix>` after `<conversation>`, and the prompt ends with pi's turn-prefix instructions, asking for the "Turn Context (split turn)" section after the summary. The checkpoint keeps the shape pi's two requests gave it. A split turn with nothing new before it still gets pi's turn-prefix prompt alone.
  - The request leaves room for pi's two caps (13,107 and 8,192 tokens at the default reserve) and carries the model's own output limit, clipped to the room left in the window.
  - A request that cannot hold its source beside that room is not sent: the compaction fails with `compaction_too_large`, and the context is unchanged. At pi's threshold a history normally fits, since the summary source cuts each tool result to 2,000 characters; a refusal comes after a switch to a much smaller window, or from one message larger than the window. A gateway's rejection of the size ends it the same way. A transient failure is still retried, with the same request.
  - The composer's compaction status no longer shows a chunk number. The Session Inspector names a combined request "earlier history and start of this turn" (or "update and start of this turn"), and still names an older capture's parts.
  - A deviation from pi 0.85.1, approved by the owner: pi sends a split turn's prefix in a second request.

## Evidence

- **Full gate** (`scripts/verify-release.sh`) on `d99d992`:
  - serial lane: 207 tests, 7 skipped, 0 failures;
  - parallel lane: 1,415 passed, 16 skipped, 1 failed: `WireContractTests.testAHeldTerminalEventDilutesNeitherTheSessionPillNorTheSidebarNorSessionInfo` (6.3 s, against 5.1 s alone). It bracketed the fixture's one-second stream at 950–1,500 ms, which the lane's eight clones can stretch or bunch by half a second; the gate kept no assertion text. `a30f0f3` allows 500–1,900 ms, still short of the two seconds the gateway held the terminal event, and the test passed 3 of 3 alone;
  - gallery: 2 failures, stopped at 102 of 112 screenshots. Scene 20 waited for a split-turn compaction's two summary requests. `a30f0f3` waits for its one request and checks the Session Inspector names it "earlier history and start of this turn"; the gallery then passed with 112 screenshots and 0 failures;
  - helper: 435 tests, 0 failures;
  - scripts: wire 32, concurrent 3, acceptance 2, Python 66;
  - 12 min 6 s.
- The "AttributeGraph: cycle detected" lines in the gallery log predate 0.1.5, and are not failures.
- **Live compaction test, fixture mode, on the release helper:** 3 of 3 scenarios passed. Compact-now and mid-run each compacted in one summary request; mid-run's summarized the history and the split turn's start together (`history+turn-prefix`), and 10 of 10 markers were recalled. Too-large was refused with `compaction_too_large` and sent nothing. Reported cost $0.99 of the fixture's $5.00 cap (synthetic).

## Release provenance

- **Source:** tag `v0.1.99`. `release/0.1.99` was merged into main with `--no-ff` (2 commits since 0.1.98), followed by one release commit.
  - The release commit before these docs, `94ea208`, has native tree `58ce7660bb9d64023ba4724425d79f08c4331476` and helper tree `d3f808e359d79abd5096fd1eecbf0441795bab41`. The DMG was built from it.
  - Only release-provenance documentation changed after the candidate build.
- **Website publication:** `ec385ad`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `101a53ea-a162-4732-bc5f-acf81d705cf0`; DMG `2cf2b8e6-c944-46fa-beb8-28b78d1b0ea8`.
- **Public verification** at **2026-09-24 19:41:00 UTC**: the product page advertises 0.1.99, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,843,011 bytes (10.34 MiB)**; SHA-256 `161128eea9dc46f378d6100e7b53b8fea0bfc286c37fe0d6e61b8716730d2227`.
- **Download:** [Bello Agent 0.1.99](https://belloware.com/assets/BelloAgent-0.1.99.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
