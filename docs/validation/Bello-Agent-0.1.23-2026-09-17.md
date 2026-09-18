# Bello Agent 0.1.23 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.23/build 27**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 02:56:14 UTC.**
Release source: `9fe4cbc518bd1b3003aa11d0eb1e55d268d6fc95`. Website: `9d3156f58a25b6f40ff90f7ff889bba9f50c4943`.

## Changed behavior

Version 0.1.23 lets a chat move between saved LiteLLM connections. Bello
Agent already stored several connections (endpoint, key, headers, model
catalog) and bound each chat to one at creation; the composer now shows a
connection pill beside the model and effort pills once more than one
Responses connection is saved. Switching is refused while the chat is working
and for imported history, connection tests, background tasks and side
conversations; otherwise it closes the open helper session, rebinds the chat,
keeps a model override only when the new connection's catalog lists it,
re-derives limits and effort, and the next turn reopens on the new endpoint
and key with the portable history replayed there. The switch is not
remembered as a model choice for new chats, but the switched chat's
connection becomes the next-chat default while it is selected. Sidebar rows
name each chat's connection when several are saved.

## Acceptance checks

**405 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 32 light/dark captures.** The transcript/host (143), Swift
helper (141) and Python (62) suites are unchanged since 0.1.22 and reuse that
evidence. The native run skipped the optional `NativeUIAcceptanceTests` class.
Local HTTP/SSE fixtures validate requests, tools, cancellation, compaction and
capture; no deployed LiteLLM was used. No Release performance matrix was run.
Installation/update rehearsals were skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 405 | 4 | 0 |
| `UIScreenshotTests` gallery (32 captures) | 1 | 0 | 0 |
| Transcript/host, helper, Python (unchanged, 0.1.22 evidence) | 346 | 0 | 0 |

New coverage: a model-switch test moves a chat between two Responses
connections and checks the persisted rebinding, the next-chat default, an
unlisted model override falling back to the connection default with limits
cleared and effort kept, that no remembered model choice is written, and that
the same connection, an unknown connection, a Messages connection, a running
chat, a connection test and a side conversation are refused without touching
the record or starting a helper. The gallery, which saves two connections,
shows the connection pill and the connection name in sidebar rows.

## Limits and preserved contracts

The helper is unchanged: a switch closes the session and the existing
`session.open` path reopens it with the other connection's profile and key,
so history replays under that connection's replay policy. A connection whose
policy pins native reasoning state to a fixed route still applies its own
checks on the first request after a switch. Kept side conversations created
before a switch keep the connection they were created with. Deterministic
local fixtures validate HTTP requests, response SSE, tools, cancellation,
compaction and capture. No live deployed LiteLLM, production credential,
Release performance matrix, installation or Sparkle update/relaunch rehearsal
was used. SwiftUI/AppKit composers, WKWebView/React, the supervised Swift
helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.23.dmg](https://belloware.com/assets/BelloAgent-0.1.23.dmg).
- Size: **6,276,182 bytes (5.99 MiB)**.
- SHA-256: `cd40536036a9b27a75624f4129ebf4df56790e87c02175951f3d9cc0d24e04a3`.
- App notarization: `f77c3e0d-920e-4b68-8163-43e166442110` (accepted).
- DMG notarization: `98f61df9-1a3c-4a41-9449-6c4ad135f3a7` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.23` committed and pushed website
`9d3156f58a25b6f40ff90f7ff889bba9f50c4943` ("Publish Bello Agent 0.1.23 update"). The public
appcast lagged the push for about three minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 02:56:14 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.23.log` (unit suite and gallery), `release-0.1.23-sign.log`,
`publish-0.1.23.log`, `public-0.1.23.log`,
`release.Bzz5WO/` (build, notarization and smoke logs) and `releases/0.1.23/`
including both dSYMs; gallery captures under the scratchpad's
`gallery6/screenshots`.
Historical [0.1.22 evidence](Bello-Agent-0.1.22-2026-09-17.md) remains unchanged.
