# Bello Agent 0.1.40 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.40/build 44**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 09:15:59 UTC.**
Release source: `d2802278100ebaf6a414a0de139fc48a59cc7233` (a local commit on `main`; the repository is pushed
as one squashed commit when the owner asks). Website: `65730b4432a1d089df7804d9b92365a2ab638b60`.

## Changed behavior

Version 0.1.40 changes four things at the owner's request. Opening a
saved chat shows the question that started its last turn: a page that
began inside a reply's rows (what a short chat with many tool calls looks
like through the sixty-row window) pulls earlier pages until the user
message leads, and an idle chat whose last turn is taller than the window
opens with that question at the top rather than at the bottom; a working
chat, a remembered reading position and sending all behave as before.
Connections can be deleted from Settings after a confirmation (their chats
keep their history and ask for another connection; a chat still working or
a side not yet kept refuses the deletion), and renaming one keeps its id,
key, chats and model cache, which the settings row now says. Chat titles are
read leniently, as models actually answer: the first usable line without
labels, bullets, numbering, quotes, emphasis or a trailing period; a failed
request says why in the chat's footer and the window's banner, and Generate
Title in the chat's menu asks again. Performance across the app: the terminal
takes program output about six times faster (printable runs print in one
pass over the row, character widths are cached, the history trims in
batches and the parser's hot state skips exclusivity checks), a streaming
reply parses only the part still changing (the text is cut where a delta
can no longer change how the parts parse and settled parts are remembered),
and every Markdown run is dressed once instead of three times.

## Acceptance checks

**452 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures.** The
Swift helper package and the Python scripts are unchanged since 0.1.38;
their 150 and 52 cases were run again and pass. The performance
baseline class ran in a Release build; its numbers are below. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 452 | 4 | 0 |
| `UIScreenshotTests` gallery and `TerminalCaptureTests` (42 captures) | 2 | 0 | 0 |
| Swift helper suite (unchanged since 0.1.38, run again) | 150 | 0 | 0 |
| Python (unchanged since 0.1.38, run again) | 52 | 0 | 0 |

New coverage: a workspace test opens a saved chat whose newest page begins
inside a thirty-row reply and checks that the page starts at the question
without starting a helper; a scroll test opens an idle chat whose last turn
is taller than the viewport and checks that the question lands at the top,
that a working chat still opens at the bottom and that sending returns to
the bottom; a settings test deletes a connection (refused while its chat
works, chats keep their history and former id, the choice moves, the key is
gone) and renames one (same id, same key); the title parser test accepts
labelled, quoted, bulleted and multi-line replies and rejects empty ones; a
terminal test prints ASCII runs over both halves of a wide character, parses
colon sub-parameters and checks that trimmed history stays counted; and a
Markdown streaming test checks that every partial reply of a document with
fences, loose lists, quotes, tables and headings parses in settled parts
exactly as it parses whole. The gallery's synthetic gateway now accepts a
mini-model request whose output limit is below the catalog ceiling, which a
title request always is; before this record the gallery's title requests had
been rejected with HTTP 400 and the rejection stayed in the footer, unseen.

Performance, measured by `PerformanceBaselineTests` in a Release build on
the build Mac (Apple silicon, macOS 14.8), before and after this version's
changes; each figure is one run, so treat differences under a millisecond
as noise:

| Path | 0.1.39 | 0.1.40 |
| --- | ---: | ---: |
| Terminal emulator, 3.4 MB of colour-changing output | 458 ms | 68 ms |
| Markdown, 14 KB mixed document, parsed cold | 16.6 ms | 12.2 ms |
| Markdown, 11 KB reply streamed in 37 deltas, parse per delta | 4.5 ms | 0.33 ms |
| Grouping 500 rows into turns (`blocks(of:)`) | 2.2 ms | 1.8 ms, skipped for text-only deltas |
| Syntax highlighting, 16 KB of Swift | 4.0 ms | 3.8 ms |
| Opening a 300-row chat (mount, layout, first display) | 15 ms | 8 ms |
| Streaming delta in a 300-row chat (explicit layout + display per delta) | 59 ms (16 KB single paragraph) | 31 ms (11 KB mixed reply) |

The streaming-delta row changed its reply between versions (a realistic
mixed reply replaced one 16 KB paragraph), so it is not a like-for-like
comparison. Sampling that benchmark shows its remaining time in AppKit's
layout pass, which the benchmark forces after every delta, and in display;
the app's own share (parsing the tail and patching the last block) is under
a millisecond of it.

## Limits and preserved contracts

Text selection in the conversation is per block (a paragraph, a code block),
not across the whole page. Mouse reporting to terminal programs is not
implemented. A failure mark is set from live run-state transitions only;
failures retained in history from before this version carry no mark. The
page-start pull reads at most four earlier pages, so a turn longer than
that still opens mid-reply. Streaming parts split only at blank lines
outside fences before margin lines that are not list items; a loose list
without blank lines elsewhere parses whole per delta. Rows
journaled before 0.1.36 still fall back to row-order grouping and row gaps. Deterministic local fixtures validate HTTP
requests, response SSE, tools, cancellation, compaction and capture. No live
deployed LiteLLM, production credential, Release performance matrix,
installation or Sparkle update/relaunch rehearsal was used. The supervised
Swift helper, saved history, Keychain item, stored anchors and the selected
icon are preserved; the stored concurrent-projects preference is kept but
unused.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.40.dmg](https://belloware.com/assets/BelloAgent-0.1.40.dmg).
- Size: **7,113,393 bytes (6.78 MiB)**.
- SHA-256: `b8e4036068f3e89eb7e462a7a44c4bb418e3c8f638e1b5d1204eb87833a03b4e`.
- App notarization: `54063fe3-d6f9-49fe-afb3-f66043f56d5f` (accepted).
- DMG notarization: `088b70fb-7bea-49bc-9ed8-d35991007bec` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.40` committed and pushed website
`65730b4432a1d089df7804d9b92365a2ab638b60` ("Publish Bello Agent 0.1.40 update"). The public
appcast lagged the push for about three minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 09:15:59 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.40.log` (unit suite), `gallery-0.1.40.log`, `perf-0.1.40.log`, `helper-0.1.40.log`, `python-0.1.40.log`, `release-0.1.40-sign.log`,
`publish-0.1.40.log`, `public-0.1.40.log`,
`release.vN6Oho/` (build, notarization and smoke logs) and `releases/0.1.40/`
including both dSYMs; gallery captures under the scratchpad's
`gallery32/screenshots`.
Historical [0.1.39 evidence](Bello-Agent-0.1.39-2026-09-18.md) remains unchanged.
