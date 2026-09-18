# Bello Agent 0.1.35 acceptance

Date: 2026-09-18. Branch: `master`. Version **0.1.35/build 39**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 17:16:54 UTC.**
Release source: `2f1e33fa9b40f3100a1018d18054380c3723fb1d`. Website: `c5ef318bc6e14f688627cb7002fab4b75617a514`.

## Changed behavior

Version 0.1.35 is a visual and motion pass with no loss of detail. A user
message is a soft tint with no outline; a settled turn closes with a hairline
and one quiet line of figures instead of a filled band, and that line wraps
between its dots in a narrow side pane instead of clipping; the composer,
cards and the live bar sit on a hairline with a short, soft shadow; footer
metric icons are tertiary so the figures read first. Motion follows one
language defined as tokens (one ease for state changes, a longer ease-out
for arrivals; 140, 220 and 320 ms): every hover, fold, chevron and arrival
uses them, a settled turn warms its hairline for a moment rather than
flashing a fill, and Reduce Motion turns off every transition as well as
every animation. The turn line is flowing text with the chevron as the
toggle, so a narrow pane wraps between figures. The cursor follows intent:
a new chat, a selected chat, an opened side, a side closed back to its
parent and an edited message all focus the right composer; plain typing
after a click on the transcript or a sidebar row goes to the composer,
while text fields, the terminal and shortcuts are untouched, and Escape
leaves the chat filter for the composer. Narrow panes shorten instead of
clipping: composer pills fall back to icons before the send button would
be pushed off, the metrics footer drops rows it cannot fit, sidebar rows
drop token and recency figures, and the empty-chat buttons wrap.

## Acceptance checks

**420 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 34 light/dark captures; 150 Swift helper cases and
149 transcript/host cases pass.** The Python suite (62) is unchanged since
0.1.34 and reuses that evidence. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 420 | 4 | 0 |
| `UIScreenshotTests` gallery (34 captures) | 1 | 0 | 0 |
| Swift helper suite | 150 | 0 | 0 |
| Transcript/host suite | 149 | 0 | 0 |
| Python (unchanged, 0.1.34 evidence) | 62 | 0 | 0 |

New coverage: native tests check that plain typing redirects to the
focused chat's composer while shortcuts, arrows, space and text inputs do
not, that closing a side returns the cursor to its parent, and that editing
a message focuses the composer; transcript tests pin the flowing turn line
(model link before the chevron toggle, nothing nested in the button). The
gallery captures carry the new look in light and dark appearance.

## Limits and preserved contracts

Colors, spacing, motion timings, focus handling and narrow-pane layouts
changed; no data or protocol did. Rows journaled before 0.1.34 still fall back to row-order grouping and
row gaps. Deterministic local
fixtures validate HTTP requests, response SSE, tools, cancellation,
compaction and capture. No live deployed LiteLLM, production credential,
Release performance matrix, installation or Sparkle update/relaunch rehearsal
was used. SwiftUI/AppKit composers, WKWebView/React, the supervised Swift
helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.35.dmg](https://belloware.com/assets/BelloAgent-0.1.35.dmg).
- Size: **7,283,236 bytes (6.95 MiB)**.
- SHA-256: `b7d8d50d7196a36287a8642fd447411ded475c89e1415c0f8742565baf7974a4`.
- App notarization: `864499b6-c09d-4e20-b3c9-33099d41d029` (accepted).
- DMG notarization: `5548aa98-5b9f-490c-9090-3c89c7175d06` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.35` committed and pushed website
`c5ef318bc6e14f688627cb7002fab4b75617a514` ("Publish Bello Agent 0.1.35 update"). The public
appcast lagged the push for about 4 minutes (8 checks 30 s apart) while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 17:16:54 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.35.log` (bundle, unit suite and gallery), `host-0.1.35.log`, `release-0.1.35-sign.log`,
`publish-0.1.35.log`, `public-0.1.35.log`,
`release.acOuCY/` (build, notarization and smoke logs) and `releases/0.1.35/`
including both dSYMs; gallery captures under the scratchpad's
`gallery19/screenshots`.
Historical [0.1.34 evidence](Bello-Agent-0.1.34-2026-09-18.md) remains unchanged.
