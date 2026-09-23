# Bello Agent 0.1.89 validation

Date: 2026-09-23. Version 0.1.89, build 93, arm64 macOS 14+.

## Changes

- **Requests sized as pi sizes them.**
  - Before 0.1.89, requests were sized at the whole JSON body's UTF-8 bytes over three, well above pi's figure. A turn stopped before its request when that passed the window, with "Estimated request input plus the safety margin exceeds configured capacity", on chats pi measured well inside it.
  - Requests now use pi 0.85.1's `estimateContextTokens` from `packages/ai`: the last valid reply's reported total plus characters over four after it. Before any reply, it is the rows, the system prompt and the tool schemas at characters over four. Images count 4,800 characters, and opaque reasoning replay counts nothing.
  - The wire output cap is `clampMaxTokensToContext`: the model ceiling clipped to the window less the estimate and 4,096, and at least one token.
  - As in pi, no estimate refuses a request. The three preflight refusals are gone. A context rejection from the gateway is compacted and retried once.
  - Compaction sizes its candidate in the same units, with a summary reserve of cap × 4 characters. Its chunk packer prices parts at characters over four.
  - Like pi, a summary is no longer required to be smaller than the rows it replaces. The compacted request only has to fit the window.
- **Release gate.** `scripts/verify-release.sh` runs the whole gate as one command. The gallery and the helper checks run side by side.
- **Tests.** Tests that asserted the old heuristic, or were sized for it, were restated to pi's rules: the output clip, the tool-schema preflight, images, opaque replay and the chunked-summary fixtures. The compaction gateway fixture's own contract now checks characters over four, and its test reads captured bodies page by page.

## Evidence

- **Helper:** `swift test` 365/365 on the fix. The new `OutputCapDispatchTests.testAChatPiMeasuresInsideTheWindowIsSentWhateverItsBytes` fails on 0.1.88 with the reported error and no request sent.
- **Not run, at the owner's request:** the Debug whole native suite, the screenshot gallery, the wire, concurrent and acceptance scripts, and the Python script tests. The Debug app and test build had succeeded before the gate was stopped.

## Release provenance

- **Source:** tag `v0.1.89`, one release commit on GitHub. The DMG was built from the local candidate `8f94e0a`, with native tree `e284c0bcbc7a7a37f340283b0d8bba538c03c68e` and helper tree `dd1fa8e60cf7e395d641576651547f3e7617485e`. Only release-provenance documentation changed after the candidate build.
- **Website publication:** `b06f498300129eb4d743ec0e445d5e79cba58b54`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `fd3b6acd-e1d5-405f-b9e6-ed85b20b5ee9`; DMG `1b71fdee-0e14-4ebe-b635-c6624cc8440c`.
- **Public verification** at **2026-09-23 16:05:57 UTC**: the product page advertises 0.1.89, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,387,171 bytes (9.91 MiB)**; SHA-256 `ae3aa6d2f92b4359f1eb38866bd67c57c4901e2cb1454e9f30356dfcc8b52776`.
- **Download:** [Bello Agent 0.1.89](https://belloware.com/assets/BelloAgent-0.1.89.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
