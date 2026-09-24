# Bello Agent 0.1.92 validation

Date: 2026-09-24. Version 0.1.92, build 96, arm64 macOS 14+.

## Changes

- **Chunked summaries get real room.**
  - 0.1.91 took the summary cap off the wire. When a history was too long for one summary request, though, each chunk was still packed beside pi's 13,107-token share, and its output limit came out at exactly 13,107.
  - A summary request now keeps free pi's share or a quarter of the window, whichever is more, within the model's own limit (`CompactionPolicy.summaryRoom`). The summary text's own budget is still pi's share.
  - The 0.1.91 test checked "at least 13,107", which exactly 13,107 passes. The new `CompactionPiTests.testChunksLeaveAQuarterOfTheWindowForTheirSummary` requires the quarter of the window, and it fails on 0.1.91.
- **Test.** `CostLimitTests.testSendingAtTheLimitShowsTheNoticeAndADisabledDefaultNeverStops` now waits for the last reply's spend before checking the chat's total.

## Evidence

- **Helper:** `swift test` 412/412.
- **Scripts against the new helper:** wire 29, concurrent 3, acceptance 2.
- **App classes that drive the real helper:** `ManualCompactionTests`, `CompactionResponsivenessTests`, `CostLimitTests` (3 consecutive green runs after its test fix) and `WireContractTests`.
- **Full gate:** it ran on 0.1.91's code. This release changes only the helper's summary room, plus one test.

## Release provenance

- **Source:** tag `v0.1.92`, one release commit on GitHub. The DMG was built from the local candidate `998f2ad`, with native tree `8c25da314827a17c1d02ca88e017ec63f55b826e` and helper tree `0202e43a9d21bae7b4341c0271f4699f6c8acadb`. Only release-provenance documentation changed after the candidate build.
- **Website publication:** `82de1e8141c79d34adce9e6507aee626e2c0a124`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `b36030e1-8f44-4ab6-837f-d5675a15d41b`; DMG `c18fa3ff-11aa-426b-89ec-12386ac21c79`.
- **Public verification** at **2026-09-24 01:45:32 UTC**: the product page advertises 0.1.92, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,569,473 bytes (10.08 MiB)**; SHA-256 `a2ada7728ab859301b9acb2c5357c75899d94fc6c3f916d3835cb1bf8fb58520`.
- **Download:** [Bello Agent 0.1.92](https://belloware.com/assets/BelloAgent-0.1.92.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
