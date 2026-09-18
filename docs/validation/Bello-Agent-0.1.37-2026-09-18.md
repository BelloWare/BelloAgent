# Bello Agent 0.1.37 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.37/build 41**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 01:57:55 UTC.**
Release source: `f803d904f7c3963cc0fd170a652ba15d836ea319`. Website: `4363262d41c79fb0fb2f2f6aa9162bfc4e0d18e1`.

## Changed behavior

Version 0.1.37 removes the system title bar from every window. A strip
of the app's own chrome (`PiWindowBar`) replaces it: it drags the window,
zooms on a double click, hides the system title while keeping `.titled` for
native key handling and the traffic lights, and leaves the leading room
those buttons need. The Session info window's header and the Settings
window use it; sheets have no title bar to replace and are untouched, and
the window title still names the window in the Window menu. The dashboard
reads more quietly: a tile carries a small tinted glyph instead of a filled
badge, its value is 20pt semibold, and its caption reserves two lines so a
row of tiles keeps one height; sheet headers use a soft tinted icon and a
17pt title. Session info opens larger so its Models table and request
charts are both in view.

## Acceptance checks

**423 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 38 light/dark captures; 150 Swift helper cases and
149 transcript/host cases pass.** The Python suite (62) is unchanged since
0.1.36 and reuses that evidence. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 423 | 4 | 0 |
| `UIScreenshotTests` gallery (38 captures) | 1 | 0 | 0 |
| Swift helper suite | 150 | 0 | 0 |
| Transcript/host suite | 149 | 0 | 0 |
| Python (unchanged, 0.1.36 evidence) | 62 | 0 | 0 |

New coverage: a native test checks that a window wearing the app's chrome
hides its system title and separator, keeps `.titled` and its traffic
lights, keeps its title for the Window menu, that a window with no title
bar is left alone, and that hosting the bar applies the same chrome without
letting the background drag the window. The gallery re-captures every
surface, including the Session info window with its new header.

## Limits and preserved contracts

Window chrome, tile typography and sheet headers changed; no behaviour,
data or protocol did. Sheets keep the presentation macOS gives them. Rows journaled before 0.1.36 still fall back to row-order grouping and
row gaps. Deterministic local
fixtures validate HTTP requests, response SSE, tools, cancellation,
compaction and capture. No live deployed LiteLLM, production credential,
Release performance matrix, installation or Sparkle update/relaunch rehearsal
was used. SwiftUI/AppKit composers, WKWebView/React, the supervised Swift
helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.37.dmg](https://belloware.com/assets/BelloAgent-0.1.37.dmg).
- Size: **7,336,336 bytes (7.00 MiB)**.
- SHA-256: `19801f32ec462a9cba321629802db2ee4eecb2a07907377fbbe8ed3428577a06`.
- App notarization: `c30609cb-80d9-4fac-af46-41f8552340e5` (accepted).
- DMG notarization: `a75728b0-96af-4759-814d-8c6afcccaa66` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.37` committed and pushed website
`4363262d41c79fb0fb2f2f6aa9162bfc4e0d18e1` ("Publish Bello Agent 0.1.37 update"). The public
appcast lagged the push for under 4 minutes (7 checks 30 s apart) while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 01:57:55 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.37.log` (bundle, unit suite and gallery), `host-0.1.37.log`, `release-0.1.37-sign.log`,
`publish-0.1.37.log`, `public-0.1.37.log`,
`release.0wvWSi/` (build, notarization and smoke logs) and `releases/0.1.37/`
including both dSYMs; gallery captures under the scratchpad's
`gallery21/screenshots`.
Historical [0.1.36 evidence](Bello-Agent-0.1.36-2026-09-18.md) remains unchanged.
