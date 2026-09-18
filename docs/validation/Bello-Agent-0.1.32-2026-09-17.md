# Bello Agent 0.1.32 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.32/build 36**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 14:29:59 UTC.**
Release source: `094ea5c175e3f43c8e994aaf5e88121f1701683b`. Website: `86ea696d6e7f5d57498943c34c7f7207e220d7dd`.

## Changed behavior

Version 0.1.32 removes the conversation header. While a turn runs a live
bar docks above the composer with a spinner, the elapsed time counting up,
the action under way, any retry in progress, the replies, tool calls, tokens
and cost so far, and Stop; it settles back into the flow as the turn line.
Changes, Session info and the chat's action menu live in the composer bar,
an empty chat shows a starter card (project folders, connection, model, tool
mode and quick actions), and side panes say in plain words what they share.
Sidebar rows show cost, one token figure with the split on hover, a recency
stamp, a spinner while running and their archive control only on hover. A
live reply lists its last three actions inline and shows the first sentence
of exposed reasoning; edit and write calls expand to real diffs; prose is
capped near 80 characters a line; user bubbles and settled turn lines show
their times on hover; the model sits on the reply line before the chevron.
Reports and Session info name coverage only where it is partial, and an
unreported final model is a quiet dash.

## Acceptance checks

**417 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 34 light/dark captures; 149 Swift helper cases and
146 transcript/host cases pass.** The Python suite (62) is unchanged since
0.1.31 and reuses that evidence. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 417 | 4 | 0 |
| `UIScreenshotTests` gallery (34 captures) | 1 | 0 | 0 |
| Swift helper suite | 149 | 0 | 0 |
| Transcript/host suite | 146 | 0 | 0 |
| Python (unchanged, 0.1.31 evidence) | 62 | 0 | 0 |

New coverage: transcript tests check the live bar (current action, retry
notice folded in, Stop), the inline action trail, the reasoning teaser, the
model segment before the chevron, hover timestamps on turns and user rows,
the line diff and edit-text extraction, and the notice that stays a row after
a settled turn; native tests cover the token bar's quiet complete coverage and
the report's quiet unreported model.

## Limits and preserved contracts

The live bar sticks inside the transcript page, so it sits above the
composer only while the page is scrolled above its end; at the end it is the
turn line itself. Diffs are computed from the edit's old and new text with a
300-line bound, beyond which the change shows as removed then added lines.
The helper is unchanged.
Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, Release performance matrix, installation or Sparkle update/relaunch
rehearsal was used. SwiftUI/AppKit composers, WKWebView/React, the supervised
Swift helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.32.dmg](https://belloware.com/assets/BelloAgent-0.1.32.dmg).
- Size: **7,256,957 bytes (6.92 MiB)**.
- SHA-256: `cdf95a723f37ede9d7f87d9993097d976f9b09cc422a92e251a4bbf122899c62`.
- App notarization: `2146dd24-f927-496d-bb90-93b869978c3d` (accepted).
- DMG notarization: `4404ca7f-e45f-4ac1-8e76-1b6145b0b439` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.32` committed and pushed website
`86ea696d6e7f5d57498943c34c7f7207e220d7dd` ("Publish Bello Agent 0.1.32 update"). The public
appcast lagged the push for about four minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 14:29:59 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.32.log` (bundle, unit suite and gallery), `host-0.1.32.log`, `release-0.1.32-sign.log`,
`publish-0.1.32.log`, `public-0.1.32.log`,
`release.AlG0Yk/` (build, notarization and smoke logs) and `releases/0.1.32/`
including both dSYMs; gallery captures under the scratchpad's
`gallery15/screenshots`.
Historical [0.1.31 evidence](Bello-Agent-0.1.31-2026-09-17.md) remains unchanged.
