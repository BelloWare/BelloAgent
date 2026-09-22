# Bello Agent 0.1.84 validation

Date: 2026-09-23. Version 0.1.84, build 88, arm64 macOS 14+.

## Changes

- Input/cache and output/reasoning pairs are accumulated per request in the archive and transcript accounting. Pending or unmatched usage no longer replaces an established split with a generic bar. Independent totals and reporting coverage remain available in detailed accounting; cache and reasoning are still included only once.
- Concept C's routing presentation is applied to the status popup and analytics, using the existing dynamic palette. The popup has a distribution ring; analytics has requested-to-returned routes, model costs, matched token breakdowns, active sessions and the same live chart with drag-to-zoom.
- Five-minute and fifteen-minute analytics presets persist independently of the legacy whole-hour preference. Request filters narrower than a project use the matching historical rate rather than incorrectly showing other sessions' live counters.
- Live chart rendering stays in an observed leaf, with no SQL queries per tick. Independent visibility owners prevent one surface from stopping another's updates. Current rates remain gateway-counter observations; completed rates are reported output divided by dispatch-to-model-completion time. Unobserved intervals are not invented.
- Turn Info can expand to 1040×840 points or shrink to 680×640, clamped to the display. The existing host is resized, preserving request/body/search state.

## Evidence

- **129 focused native tests passed, no failures**, under Xcode 16.1 with Swift 6 strict concurrency and actor data-race checks. This includes per-request pair aggregation, archive reload, pending/unmatched counters, zero and missing values, minute presets, filtered live-history scope, independent visibility, chart dragging, multi-session load, completed duration stability and native popup expansion.
- The native screenshot gallery used an isolated in-memory vault and a loopback Responses gateway. Completed and ongoing compact reports were also rendered at 280 and 760 points in both themes; the pending request retains the preceding token split. Native status captures exercise three reported model series and chart zoom in light/dark appearance.
- Logs: `tmp/claude-ui-079/routing-c-verify.log` (113 initial checks) and `routing-c-final.log` (129 final regression checks) under the remote session scratch directory. After the latter, unused chart code was removed and minute-range axis labels were adjusted; the release build compiles these presentation-only changes.
- Helper/provider code is unchanged, so earlier passing helper checks are reused. These fixtures do not establish accuracy of a deployed gateway or guarantee all app performance. Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.

## Release provenance

- Source: tag `v0.1.84`; native tree `0c1df26f9e19b617dfda5299b32ec6cb44dcf723`, unchanged helper tree `21c72b240da9f9c1b769d183919444c81c09c0a1`. Only release-provenance documentation changed after the candidate build.
- Website publication: `57df3d8a5b433c7c34301a91d826c2cf51f0ab8b`; Cloudflare check `106832398788` completed successfully at **2026-09-22 16:18:19 UTC**.
- Optimized native build, packaged offline helper/catalog smoke, Developer ID signing, app/DMG notarization, stapling, Gatekeeper and Sparkle artifact validation passed.
- Accepted notarizations: app `7b0f4bf4-cccf-445a-a9fa-32fc9c5d65d1`; DMG `9016fb78-9379-47fd-a7b5-42caff204384`.
- Public verification at **2026-09-22 16:19:19 UTC**: the product page advertises 0.1.84, canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- DMG: **9,519,102 bytes (9.08 MiB)**; SHA-256 `0f1d492b66ed44c9b6e49d01d43ae1665865aa1a9c2419afeb96cf2ac94fc549`.
- Download: [Bello Agent 0.1.84](https://belloware.com/assets/BelloAgent-0.1.84.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
