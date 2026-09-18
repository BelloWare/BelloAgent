# Bello Agent 0.1.21 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.21/build 25**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 01:41:55 UTC.**
Release source: `6654428f9b4dfddaff2a470d9965d5be4e3d8877`. Website: `7ac59ce6764510f0ef34cf095864f2e5616e9fd0`.

## Changed behavior

Version 0.1.21 folds tool calls behind each turn's header by default; the
header names the work and, while live, the current action, expanding lists the
calls, and only clicking a call shows its request and response. The status bar
panel is one page: a "Now" list of running, waiting and unread chats that open
on click, period tabs, token and cost tiles, a chart switching between
requests, reported cost and historical output tok/s per time slice, and a model
distribution bar chart; the Activity tab and its live output-rate estimate are
removed. The colour scheme is flat: no gradients or corner wash, solid
brand-orange fills for primary controls and badges, and a darker accent for
text that reads at 4.5:1 on cream. A reply becomes unread, on the Dock badge and
the sidebar dot, only after the run has finished and reported back. Archiving a
chat keeps the sidebar on active chats and moves on to the nearest active chat.
While a run is in progress the context ring holds its last settled count
instead of flickering through pending and per-request estimates.

The accent-text token split and the contrast test were another session's
uncommitted work in the main checkout; they were adopted into the flat colour
commit with the primary-fill case adjusted to the solid brand-orange fill. The
checkout was clean at the release commit, so the release was built from the
main checkout.

## Acceptance checks

**404 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 32 light/dark captures; the optional status-bar capture passes;
143 transcript/host cases and TypeScript checking pass.** The helper (141
cases) and the Python scripts (62 cases) are unchanged since 0.1.20 and their
passing runs from that release are reused. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were skipped
under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 404 | 4 | 0 |
| `UIScreenshotTests` gallery (32 captures) | 1 | 0 | 0 |
| `MenuBarPresentationTests` including the opt-in panel capture | 3 | 0 | 0 |
| Transcript/host `npm run test:host` | 143 | 0 | 0 |
| Swift helper (unchanged, 0.1.20 run) | 141 | 0 | 0 |
| Python `scripts/tests` (unchanged, 0.1.20 run) | 62 | 0 | 0 |

New coverage: unread state ignores running/compacting snapshots and counts the
finished run's replies; archiving the selected or focused chat leaves the
archive filter off; status-bar buckets slice the period, carry cost and output
rate and exclude attempts outside the window; the activity snapshot separates
running, waiting and unread rows; the contrast test checks accent text on every
surface and the flat primary fill; transcript tests cover the folded header,
the live current action and expanded rows with closed cards.

Gallery and panel review confirmed: no wash or gradient anywhere; solid orange
primary, send and sheet-badge fills; the turn header reads "Worked for 0.4s ·
Read 1 file  model 0.3s · tools 0.0s" with a folded chevron and no rows until
expanded; the status-bar panel shows the Now list, period tabs, tiles, the
requests chart and the model distribution.

## Limits and preserved contracts

Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, Release performance matrix, installation or Sparkle update/relaunch
rehearsal was used. Chart buckets come from retained attempt metadata and use
the same aggregate and rate SQL as the totals; a slice with no completed,
timed attempts has no output rate. The held context count is a presentation
rule in the footer; the helper's counts, preflight and compaction are unchanged.
Unread counts are still recorded internally; only their timing changed. The
Dock badge still shows the count of unread replies. SwiftUI/AppKit composers,
WKWebView/React, the supervised Swift helper, saved history, Keychain item and
the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.21.dmg](https://belloware.com/assets/BelloAgent-0.1.21.dmg).
- Size: **7,409,250 bytes (7.07 MiB)**.
- SHA-256: `220b140c4b778963234ffe796684cbae08363807f4ea05effa5caa5cd7609e6d`.
- App notarization: `6c1660f3-6ebe-4511-bb29-aca92cf632d9` (accepted).
- DMG notarization: `324e4fcd-31cb-40bc-9ea7-727f9478b4cf` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass. The
release validator and packaged helper/catalog smoke pass. Canonical and legacy
appcasts are byte-identical. Bundle ID `com.belloware.PiApp`, Keychain
ownership, history locations and updater signing identity remain unchanged.

`scripts/publish-release.sh 0.1.21` committed and pushed website
`7ac59ce6764510f0ef34cf095864f2e5616e9fd0` ("Publish Bello Agent 0.1.21 update"). The public
appcast lagged the push for about four minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 01:41:55 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `release-0.1.21-sign.log`, `release.dc5faK/` (build, notarization and smoke
logs), `publish-0.1.21.log`, `public-0.1.21.log` and `releases/0.1.21/`; the unit, gallery and panel runs are in the
`fix/Logs/Test` result bundles, with captures under the scratchpad's
`gallery4/screenshots` and `menu-capture` folders.
Historical [0.1.20 evidence](Bello-Agent-0.1.20-2026-09-17.md) remains unchanged.
