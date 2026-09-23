# Bello Agent 0.1.88 validation

Date: 2026-09-23. Version 0.1.88, build 92, arm64 macOS 14+.

## Changes

- **Turn info from every request.**
  - A turn's input and output no longer disappear when the request log lacks its rows. That happened when metrics had expired, or when a capture was dropped while the archive was still closed at launch. The report falls back to the record each reply kept when it finished, matched by attempt id. Display rows carry an optional `reply` field (additive).
  - Auto-routed turns show "requested → answered · N models". Turn info lists every request with its model, figures and source (request log or reply record), and gives a subtotal per model. When the gateway's header and body disagree, the body's model is shown, with the header's in brackets.
  - Partial coverage shows what is known and says what is missing, for example "input and output from 3 of 4 requests; 1 came back with no usage from the gateway". The reasons are: no usage from the gateway, expired from the request log, or model unreported. A running turn shows "Reported so far".
  - The per-request list is built only when Turn info opens. On the 100,000-request scale test the page query takes a median of 898 ms, against 895 ms on 0.1.87 and 1,241 ms before the list was deferred (Debug).
- **Compaction as pi 0.85.1 does it.**
  - It summarizes only what is new since the last compaction and folds it into the previous summary with pi's update prompt. It keeps about 20,000 recent tokens verbatim (`keepRecentTokens`, pi's `estimateTokens`), and serializes the source as pi's `serializeConversation` does, with tool results cut to 2,000 characters.
  - It uses pi's prompts and system prompt. Output is capped at min(0.8 × reserve, the model's limit), and a split turn's prefix at 0.5 × reserve.
  - A source too long for one request is summarized in chained parts. The 2 MiB source cap, the record builder, merge levels and the headroom retry are removed, so "Bounded summary source exceeds the operation limit" can no longer occur.
  - "Compact now" on a chat below the threshold says "Nothing to compact (session too small)".
  - Journal records gain `details` (files read and modified). The `merging` and `retrying-output-budget` phases are no longer emitted.
  - Deliberate differences from pi: the current task's inputs are replayed verbatim after the summary, and fallbacks remain where pi cannot compact.

## Evidence

- **Debug whole suite** (Xcode 16.1, Swift 6): 1,519 tests, 22 skipped, 0 failures, 1,389 s.
- **Gallery:** `UIScreenshotTests` passed with 76 screenshots in light and dark.
- **Helper:** `swift test` 364/364, including `CompactionPiTests`. Its 7 MB history failed before with the source-limit error. Wire tests 27/27, concurrent wire 3/3, acceptance 2/2, Python script tests 53/53.

## Release provenance

- **Source:** tag `v0.1.88`, one release commit on GitHub. The DMG was built from the local candidate `f80fbef`, with native tree `e284c0bcbc7a7a37f340283b0d8bba538c03c68e` and helper tree `750b34982b8279ee8f9fa6f78242755586e4492d`. Only release-provenance documentation changed after the candidate build.
- **Website publication:** `9813a23a0f65ee6780724496c5bb63f1a162260a`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `118faadd-2a2f-473f-b5ae-352498be8dbe`; DMG `77f7d528-ae8e-4e64-bb8b-cdeb59600a65`.
- **Public verification** at **2026-09-23 14:50:29 UTC**: the product page advertises 0.1.88, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,391,163 bytes (9.91 MiB)**; SHA-256 `04747e794b6ad8b979b92b71d773b707a7c761ee844209e71cb8a616a8a2f268`.
- **Download:** [Bello Agent 0.1.88](https://belloware.com/assets/BelloAgent-0.1.88.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
