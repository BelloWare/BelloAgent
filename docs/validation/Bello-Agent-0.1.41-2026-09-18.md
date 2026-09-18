# Bello Agent 0.1.41 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.41/build 45**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 10:33:48 UTC.**
Release source: `4bfa49e039c6206e12afbb4dac823af27620c9ef` (a local commit on `main`; the repository is pushed
as one squashed commit when the owner asks). Website: `a11fb2989b9839061d6bb24f82dbb8e80876b072`.

## Changed behavior

Version 0.1.41 changes two things at the owner's request. Delete
Connection works from the Settings footer itself: the button asks in place
(no modal alert to miss), the question says what the deletion touches (the
key leaves the Keychain item, which chats keep their history and will need
another connection, how many runs will stop), and a run still going under
the connection is stopped and its helper session closed instead of the
deletion being refused; a vault revision conflict is retried once after a
reload, and the footer then says that the connection was deleted, or why it
was not. Motion, now that the whole app is native: one set of tokens
(`PiMotion`, honouring Reduce Motion through `piAnimation`) drives a
selection highlight that glides between sidebar rows, panes that cross over
when the chat changes, tab strips that slide their selected pill, sheet
badges that pop in, an empty chat's card that builds up line by line, title
suggestions that arrive one after another, tool rows whose glyph bounces
once as the call completes, footer figures that roll, unread dots that pop
and a terminal that springs open. Nothing animates while a reply streams.

## Acceptance checks

**452 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures.** The
Swift helper package and the Python scripts are unchanged since 0.1.38;
their 150 and 52 cases were run again and pass. The performance
baseline class ran again in a Release build; its numbers are below. The native run skipped the optional
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

New coverage: the settings test now deletes a connection whose chat is
running with two queued follow-ups and checks that the run is marked
interrupted, the queue emptied, the connection and its key gone, the chats
kept with their former connection id and the choice moved; the 0.1.40
coverage (page start, opening placement, lenient titles, terminal runs,
Markdown streaming parts, text-only delta patching) runs unchanged. The
gallery captures every animated surface at rest in both appearances.

Performance, measured by `PerformanceBaselineTests` in a Release build on
the build Mac (Apple silicon, macOS 14.8); this version changes no measured
path, so the figures repeat 0.1.40's within run-to-run noise:

| Path | 0.1.40 | 0.1.41 |
| --- | ---: | ---: |
| Terminal emulator, 3.4 MB of colour-changing output | 68 ms | 68 ms |
| Markdown, 14 KB mixed document, parsed cold | 12.2 ms | 12.1 ms |
| Markdown, 11 KB reply streamed in 37 deltas, parse per delta | 0.33 ms | 0.45 ms |
| Grouping 500 rows into turns (`blocks(of:)`) | 1.8 ms | 1.9 ms |
| Syntax highlighting, 16 KB of Swift | 3.8 ms | 4.7 ms |
| Opening a 300-row chat (mount, layout, first display) | 8 ms | 9 ms |
| Streaming delta in a 300-row chat (explicit layout + display per delta) | 31 ms | 30 ms |

## Limits and preserved contracts

Text selection in the conversation is per block (a paragraph, a code block),
not across the whole page. Mouse reporting to terminal programs is not
implemented. A failure mark is set from live run-state transitions only;
failures retained in history from before this version carry no mark. The
sidebar highlight glides only between rows that are both on screen; a row
outside the lazy list simply appears selected. The
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
- Download: [BelloAgent-0.1.41.dmg](https://belloware.com/assets/BelloAgent-0.1.41.dmg).
- Size: **7,115,515 bytes (6.79 MiB)**.
- SHA-256: `b9835306e36b9744258f1e50e41f5998c0438505d6676d6e01faea5c28bb58c4`.
- App notarization: `884b4db1-3c37-4f39-b037-97adffc4cae8` (accepted).
- DMG notarization: `a1645d76-9b67-4116-ad0a-faab0199f362` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.41` committed and pushed website
`a11fb2989b9839061d6bb24f82dbb8e80876b072` ("Publish Bello Agent 0.1.41 update"). The public
appcast lagged the push for about three minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 10:33:48 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.41.log` (unit suite), `gallery-0.1.41.log`, `perf-0.1.41.log`, `helper-0.1.41.log`, `python-0.1.41.log`, `release-0.1.41-sign.log`,
`publish-0.1.41.log`, `public-0.1.41.log`,
`release.uw7qxv/` (build, notarization and smoke logs) and `releases/0.1.41/`
including both dSYMs; gallery captures under the scratchpad's
`gallery33/screenshots`.
Historical [0.1.40 evidence](Bello-Agent-0.1.40-2026-09-18.md) remains unchanged.
