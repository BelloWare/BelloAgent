# Bello Agent 0.1.38 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.38/build 42**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 06:25:13 UTC.**
Release source: `bf04acfd3f41d2313d206052579091b94bf3966b` (a local commit on `main`; the repository is pushed
as one squashed commit when the owner asks). Website: `7538ca1ce73000bc1d11ec04989caa9625db2500`.

## Changed behavior

Version 0.1.38 makes the whole application native and leaves Sparkle as
its only third-party code. The conversation page is SwiftUI
(`apps/macos/PiApp/Transcript`): `TranscriptActivity` groups rows into
replies and turns and sums their usage, `TranscriptMarkdown` turns
Foundation's Markdown parse into blocks, `SyntaxHighlighter` colours code
with its own scanners, `TranscriptCopy` finds section and code copy targets
in the source, `TranscriptRows` draws the rows, and `TranscriptPage`
owns scrolling (the reader's own scrolls decide whether the page follows,
programmatic scrolls never do), anchors across chat switches and earlier
pages, fresh-row motion and read receipts. The WKWebView, React,
react-markdown, remark-gfm, highlight.js, esbuild, TypeScript, the old
TypeScript host and Node itself are gone from the build and the bundle.
The terminal panel is the app's own emulator (`apps/macos/PiApp/Terminal`):
a pty-owning process runner, an xterm-style VT parser over a cell grid with
scrollback, alternate screen, scroll regions, tab stops, DEC line drawing,
16/256/true colour, bracketed paste and the replies programs ask for, and a
CoreText view with keys, input methods, selection, copy, paste and wheel
scrollback; SwiftTerm and its swift-argument-parser dependency are gone.
Three behaviours changed at the owner's request: tool call rows and
per-request figures stay in view after a turn (the chevron folds them),
the working bar follows the session's run state rather than only a
streaming row, so it stays up from send to settle including between
requests, and any number of projects and chats can be active at once (the
concurrent-projects setting and its eviction are gone).

## Acceptance checks

**443 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 42 light/dark captures, now including the terminal; and
150 Swift helper cases pass.** The Python suite passes with 52 cases (the
10 dependency-cache cases left with npm). There is no transcript/host
JavaScript suite any more: its 149 cases became the native
`TranscriptActivityTests`, `TranscriptMarkdownTests`, `NativeTranscriptTests`
and `NativeTranscriptScrollTests`, and the terminal has
`TerminalEmulatorTests` (parser, grid, keys, a real shell with a controlling
terminal, the view). The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 443 | 4 | 0 |
| `UIScreenshotTests` gallery and `TerminalCaptureTests` (42 captures) | 2 | 0 | 0 |
| Swift helper suite | 150 | 0 | 0 |
| Python | 52 | 0 | 0 |

New coverage: the transcript's grouping, accounting, Markdown, highlighting,
copy scanning and page behaviour (display limits, fresh rows, following,
earlier requests, anchors) have native tests, and one test drives the real
workspace to check that the page lands at the newest row while rows stream
in, that a wheel scroll up detaches it and that a later row never pulls the
reader back. The terminal tests feed byte streams to the emulator (wrapping,
scrollback, editing, regions, SGR in every colour form, wide characters and
split UTF-8, the alternate screen, replies, titles, tabs, line drawing,
resizing) and run `/bin/sh` on the pseudo-terminal to prove it owns a
controlling terminal, sees the window size and starts in the project
directory.

## Limits and preserved contracts

Text selection in the conversation is per block (a paragraph, a code block),
not across the whole page. Mouse reporting to terminal programs is not
implemented; the wheel scrolls the scrollback, or moves the cursor in
full-screen programs. Rows journaled before 0.1.36 still fall back to
row-order grouping and row gaps. Deterministic local fixtures validate HTTP
requests, response SSE, tools, cancellation, compaction and capture. No live
deployed LiteLLM, production credential, Release performance matrix,
installation or Sparkle update/relaunch rehearsal was used. The supervised
Swift helper, saved history, Keychain item, stored anchors and the selected
icon are preserved; the stored concurrent-projects preference is kept but
unused.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.38.dmg](https://belloware.com/assets/BelloAgent-0.1.38.dmg).
- Size: **7,128,652 bytes (6.80 MiB)**.
- SHA-256: `90ed4270a53955671d875cae58b946b27ac7f74b561525b6599298f79246150d`.
- App notarization: `d6d2baf6-6aa8-4ec2-9612-268f2cd39058` (accepted).
- DMG notarization: `deba0567-d4d1-4138-9149-3cd0c906101e` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.38` committed and pushed website
`7538ca1ce73000bc1d11ec04989caa9625db2500` ("Publish Bello Agent 0.1.38 update"). The public
appcast lagged the push for about four minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 06:25:13 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.38.log` (unit suite), `gallery-0.1.38.log`, `helper-0.1.38.log`, `release-0.1.38-sign.log`,
`publish-0.1.38.log`, `public-0.1.38.log`,
`release.4x5o1p/` (build, notarization and smoke logs) and `releases/0.1.38/`
including both dSYMs; gallery captures under the scratchpad's
`gallery26/screenshots`.
Historical [0.1.37 evidence](Bello-Agent-0.1.37-2026-09-18.md) remains unchanged.
