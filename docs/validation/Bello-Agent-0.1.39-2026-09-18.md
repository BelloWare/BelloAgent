# Bello Agent 0.1.39 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.39/build 43**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 07:25:06 UTC.**
Release source: `a88bddbb4fbe0772bce8b182cf9116cda4309047` (a local commit on `main`; the repository is pushed
as one squashed commit when the owner asks). Website: `a7d2d22d809962d5f123d6c0b1cfbcb2a2bbf49b`.

## Changed behavior

Version 0.1.39 changes six things at the owner's request. Text no longer
jumps while a reply streams: the page scrolls once per change, after the
AppKit document has taken SwiftUI's new height, and nothing animates during
a live turn; and every row is laid out exactly rather than lazily, so rows
in view (and their buttons) stay put while a reply streams below them. A reply reads in
the order things happened: what the model did comes first, under a small
header naming the work with the chevron that folds it (reasoning, one row
per tool call, the figures of each request), then the reply text, then the
turn line. A run that fails while its chat is not in front marks the chat
in the sidebar (a red dot when nothing new arrived) without bouncing the
Dock or counting in its badge; opening the chat clears the mark. Archived
chats are read-only until restored: sending, steering, editing, queue
resume and commands other than Stop are refused with a notice, the composer
gives way to a Restore footer, archiving a running chat stops it, and
archived chats never count in the Dock badge. Project chat lists fold back
with Show less. A chat's action menu can ask the mini model for a title
again, replacing an edited one, and a title request that fails says why in
the chat's footer.

## Acceptance checks

**446 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures.** The
Swift helper package and the Python scripts are unchanged since 0.1.38, so
their 150 and 52 passing cases are reused from that record. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 446 | 4 | 0 |
| `UIScreenshotTests` gallery and `TerminalCaptureTests` (42 captures) | 2 | 0 | 0 |
| Swift helper suite (unchanged, 0.1.38 evidence) | 150 | 0 | 0 |
| Python (unchanged, 0.1.38 evidence) | 52 | 0 | 0 |

New coverage: a workspace test scrolls up while a reply streams below and
checks that the page offset and a row in view stay put through twelve
deltas, a new tool row and the reply settling; a read-state test marks a failed run, checks that the Dock
badge ignores failed and archived chats, that opening the chat clears the
mark, that an archived chat refuses to send or resume, and that Mark as Read
clears both; the gallery's activity capture shows the reordered reply, and
the terminal test suite gains a check that the panel's own shell start reads
the login and rc files (aliases, nvm, Homebrew and node on PATH).

## Limits and preserved contracts

Text selection in the conversation is per block (a paragraph, a code block),
not across the whole page. Mouse reporting to terminal programs is not
implemented. A failure mark is set from live run-state transitions only;
failures retained in history from before this version carry no mark. Rows
journaled before 0.1.36 still fall back to row-order grouping and row gaps. Deterministic local fixtures validate HTTP
requests, response SSE, tools, cancellation, compaction and capture. No live
deployed LiteLLM, production credential, Release performance matrix,
installation or Sparkle update/relaunch rehearsal was used. The supervised
Swift helper, saved history, Keychain item, stored anchors and the selected
icon are preserved; the stored concurrent-projects preference is kept but
unused.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.39.dmg](https://belloware.com/assets/BelloAgent-0.1.39.dmg).
- Size: **7,149,724 bytes (6.82 MiB)**.
- SHA-256: `1e93b8639cf4cd0ee12c20246f7ed331b929f1e925b62585ba2beab15de168f7`.
- App notarization: `457a1b20-9bf1-4f36-b23f-bdb0250aa093` (accepted).
- DMG notarization: `a266d4aa-6565-4621-ac23-e5eb13bb9be0` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.39` committed and pushed website
`a7d2d22d809962d5f123d6c0b1cfbcb2a2bbf49b` ("Publish Bello Agent 0.1.39 update"). The public
appcast lagged the push for about four minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 07:25:06 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.39.log` (unit suite), `gallery-0.1.39.log`, `release-0.1.39-sign.log`,
`publish-0.1.39.log`, `public-0.1.39.log`,
`release.dqdXeA/` (build, notarization and smoke logs) and `releases/0.1.39/`
including both dSYMs; gallery captures under the scratchpad's
`gallery29/screenshots`.
Historical [0.1.38 evidence](Bello-Agent-0.1.38-2026-09-18.md) remains unchanged.
