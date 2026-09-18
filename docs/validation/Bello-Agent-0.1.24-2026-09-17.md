# Bello Agent 0.1.24 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.24/build 28**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 03:15:07 UTC.**
Release source: `f5cd242345d315dd9a3997ce721112a031b30f86`. Website: `679e9d4244a8f275694009f3b224b85c0b88833f`.

## Changed behavior

Version 0.1.24 moves each reply's work line to its bottom. Every assistant
reply ends with how long it took, what it did and the model-versus-tool
split, and expanding that line shows the reasoning and tool calls that
produced the reply; a turn no longer shares one toggle at its top, so a long
reply is read first and its work is at hand where reading ends. Work a turn
ended on without prose forms a trailing line of its own. The Dock badge
counts chats with unread replies, one per chat, matching the sidebar dot.
Accounting lines show only what the gateway reported: an unreported model,
usage or cost is left out, and a message with nothing reported has no line.

## Acceptance checks

**405 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 32 light/dark captures; 143 transcript/host cases and
TypeScript checking pass.** The Swift helper (141) and Python (62) suites are
unchanged since 0.1.22 and reuse that evidence. The native run skipped the
optional `NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate
requests, tools, cancellation, compaction and capture; no deployed LiteLLM was
used. No Release performance matrix was run. Installation/update rehearsals
were skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 405 | 4 | 0 |
| `UIScreenshotTests` gallery (32 captures) | 1 | 0 | 0 |
| Transcript/host `npm run test:host` | 143 | 0 | 0 |
| Swift helper and Python (unchanged, 0.1.22 evidence) | 203 | 0 | 0 |

New coverage: transcript tests build per-reply blocks (a reply owns the work
before it and its own calls, a trailing block holds work without prose,
timing per block), render the work line under the reply folded with no rows
or reasoning in the DOM, a reply without work with nothing to expand, a live
block naming its current action, and accounting lines that leave out
unreported cost, model and usage or vanish when nothing was reported. A
native test asserts the Dock badge reads 1 for a chat holding three unread
replies and clears when the chat is marked read.

## Limits and preserved contracts

The synthetic gateway cannot emit exposed reasoning, so the gallery shows work
lines with tool calls only; the transcript tests carry the reasoning case.
Read receipts still target the latest completed reply's article, which the
block keeps in place. Unread counts are still recorded per reply for
acknowledgement; only the Dock and sidebar presentation is per chat.
Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, Release performance matrix, installation or Sparkle update/relaunch
rehearsal was used. SwiftUI/AppKit composers, WKWebView/React, the supervised
Swift helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.24.dmg](https://belloware.com/assets/BelloAgent-0.1.24.dmg).
- Size: **6,275,896 bytes (5.99 MiB)**.
- SHA-256: `52ef5685de99b400ed31e10d420ed43ea8655843388df1f89a2bb802a908919a`.
- App notarization: `1fed5aad-ed3b-4815-b969-992a8b6c2354` (accepted).
- DMG notarization: `d607b6e4-aef8-4263-a463-52f35130334f` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.24` committed and pushed website
`679e9d4244a8f275694009f3b224b85c0b88833f` ("Publish Bello Agent 0.1.24 update"). The public
appcast lagged the push for about five minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 03:15:07 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.24.log` (bundle, unit suite and gallery), `release-0.1.24-sign.log`,
`publish-0.1.24.log`, `public-0.1.24.log`,
`release.oJUJRy/` (build, notarization and smoke logs) and `releases/0.1.24/`
including both dSYMs; gallery captures under the scratchpad's
`gallery7/screenshots`.
Historical [0.1.23 evidence](Bello-Agent-0.1.23-2026-09-17.md) remains unchanged.
