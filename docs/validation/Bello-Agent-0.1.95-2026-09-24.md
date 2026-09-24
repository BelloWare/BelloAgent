# Bello Agent 0.1.95 validation

Date: 2026-09-24. Version 0.1.95, build 99, arm64 macOS 14+.

## Changes

- **⌘↩ steers again.**
  - The owner reported that ⌘↩ did not steer.
  - AppKit offers a ⌘ key to the window's views, then to the menu bar, and only then to the focused view's `keyDown`. Since 0.1.37 the Conversation menu had bound ⌘↩ to "Send / Queue Follow-up". With a chat open, that item was enabled and took the key, so a message meant to steer was queued as a follow-up, against the composer's own "⌘↩ Steer" hint.
  - The composer's tests pressed keys on the editor directly, so they never met the menu.
  - The composer being typed in now claims ⌘↩ at the key-equivalent step, and `keyDown` decides as before: steer a running chat, send an idle one.
  - The menu's ⌘↩ is now "Send / Steer Current Run", which does exactly what ⌘↩ in the focused chat's composer does (`submitComposer`). "Send / Queue Follow-up" keeps Return in the composer.
- **The session's tokens are split.**
  - The usage pill under the composer reads, for example, `15.8K tok · 6K uncached · 6K cached · 3.8K out (900 reasoning) · Cache hit 50.00% · $0.0025`, the same split as a turn's usage dialog.
  - The input splits only when every request that reported its input also reported its cache use, so the parts add up to the total. Otherwise it reads `in`.
- **Two decimal places for the session's cache hit.**
  - The pill and the Session Inspector's figure read `50.00%` or `75.94%`.
  - A partial hit is still never rounded up to a full one (`99.996`), and a real but tiny hit reads `<0.01`, never zero.

## Evidence

- **Full gate** (`scripts/verify-release.sh`) on the release candidate:
  - serial lane: 140 tests, 7 skipped, 0 failures;
  - parallel lane: 1,426 passed, 13 skipped, 0 failed;
  - gallery: 100 screenshots;
  - helper: 423 tests (the helper is unchanged since 0.1.94);
  - scripts: wire 31, concurrent 3, acceptance 2, Python 65;
  - all passed in 8 min 58 s.
- **The gate before that one** failed a single test, `SessionTimingTests.testRunningFooterKeepsOnlyTheClockAndTheCurrentAction`. Its on-screen text check found the split pill running off a 420 pt pane and losing its cost.
  - The pill now falls back to its short form where the split does not fit.
  - `PiFlow` offers a pill wider than a whole row the row's width, so a `ViewThatFits` picks its shorter form.
  - The test now also requires the split at 1,000 pt and its absence at 420 pt.
  - The gallery shows the split in the main window and the short form in the narrower side pane.
- **New tests:**
  - `ComposerSubmissionTests.testTheFocusedComposerClaimsCommandReturnBeforeTheMenuBar` and `testTheMenuBarGivesCommandReturnToSendOrSteer`. Both fail on 0.1.94: the composer did not claim ⌘↩, and the app's real menu bar bound it to "Send / Queue Follow-up".
  - `MetricPillsTests.testTheSessionCacheHitHasTwoDecimalPlaces`.
- **Restated:** the session pill and accounting expectations in `MetricPillsTests` and `GatewayAccountingTests`.

## Release provenance

- **Source:** tag `v0.1.95`, one release commit on GitHub. The DMG was built from the local candidate `e28f8fd`, with native tree `4d904ace4b51f05776e4c73623add1a93787acca` and helper tree `787ed4778d3638c9108a034683d73afed4d08dc9`. Only release-provenance documentation changed after the candidate build.
- **Website publication:** `293b9bf8eb6ec73530ca37c951d9e3a79be7fb07`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `7a840132-6686-4d97-bf5b-f7f1763e5a84`; DMG `345e9983-2745-4e07-92a2-5012093a0f0d`.
- **Public verification** at **2026-09-24 09:26:56 UTC**: the product page advertises 0.1.95, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,720,890 bytes (10.22 MiB)**; SHA-256 `efeee3e07362f365534e50eca53cb8ae0a2ae752ed6bbba87ca1c5e8740ffe37`.
- **Download:** [Bello Agent 0.1.95](https://belloware.com/assets/BelloAgent-0.1.95.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
