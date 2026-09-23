# Bello Agent 0.1.86 validation

Date: 2026-09-23. Version 0.1.86, build 90, arm64 macOS 14+.

## Changes

- **Tokens per second is the standard decode speed.** It is (N − 1) ÷ (t_last − t_first):
  - N is the gateway-reported output tokens, hidden reasoning included.
  - t_first is the first generated output (the first output item opening, or the first delta).
  - t_last is the last output token, a delta or an item's completion. It is not the response's terminal event, which a gateway can hold while it computes usage and cost.
  - Aggregates are Σ(N − 1) ÷ Σ span over completed requests with N ≥ 2 and a span of at least 250 ms.
  - The helper records `timings.lastContent` (additive). It publishes only `decodeTokensPerSecond`; the round-trip `outputTokensPerSecond` is removed. `streamDurationMs` is the same first-to-last span.
  - Records from 0.1.85 and earlier, which lack a last-output stamp, fall back to the terminal event.
  - The unused round-trip rate in the live activity store is gone. The README, product page, contract doc and Features list state the definition.
  - With a gateway holding `response.completed` for 2 s after the last token, the session pill, sidebar, Session info and helper all read 89–91 tok/s; the old span read 32.
- **The session pills open charts.**
  - "Session statistics": where the time went (waiting for the first token, generating, tools), a request timeline, speed per request against the session average, and a by-model table.
  - "Token usage": composition (cached, cache write, uncached, reasoning, other output), tokens per request, cumulative cost and each model's share.
  - Both are built off the main actor once per history, and hovering redraws only the rule and the caption.
- **A relaunch reopens the chat the reader had open,** with its project, kept side and row.
  - The selection is written as it changes (`selection` record), so a crash or force-quit keeps it, and it is flushed at quit and update.
  - A chat clicked while launch is still reading is not switched away. The reopened chat paints before the retained billing, and the welcome no longer flashes.
- **Test robustness:** ten helper tests stopped their fixture process with `waitUntilExit()` after an `await`, which could hang forever. That wait is now bounded. The site staging test reads the redesigned page.

## Evidence

- Debug whole suite (Xcode 16.1, Swift 6): **1,438 tests, 20 skipped, 0 failures**.
- `UIScreenshotTests` gallery passed: 68 screenshots in light and dark, including both stats popovers.
- Helper `swift test`: 344/344.
- Wire tests 27/27, concurrent wire 3/3 and acceptance 2/2 against the release helper.
- Python script tests: 53/53.
- The Release budget classes were not rerun. This release does not touch the streaming or scrolling hot paths, and the 0.1.85 A/B stands.

## Release provenance

- Source: tag `v0.1.86`, one release commit on GitHub. The DMG was built from the local candidate `742e25e`, with native tree `0fe6d3dccd0cd41f280e53c3368a6b4b241a60b1` and helper tree `dc66374dc211d91710784893ecdc81eb491b4c94`. Only release-provenance documentation changed after the candidate build.
- Website publication: `014278499c049867c8ad7f5c6bf3bb69aab3e446`.
- Optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `eaff68b7-2d93-4856-8bb6-7bbe1abd3f31`; DMG `7bc2515c-9344-4d78-b708-73fee83aa7c9`.
- Public verification at **2026-09-23 09:49:26 UTC**: the product page advertises 0.1.86, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- DMG: **9,973,254 bytes (9.51 MiB)**; SHA-256 `8049f6089c609fdf0ab349cb96aba39081c0ee6188028f1ca9758a3d25b999b7`.
- Download: [Bello Agent 0.1.86](https://belloware.com/assets/BelloAgent-0.1.86.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
