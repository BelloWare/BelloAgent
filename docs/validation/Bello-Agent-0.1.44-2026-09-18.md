# Bello Agent 0.1.44 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.44/build 48**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 13:25:46 UTC.**
Release source: `a0cc15e3386cef9b6a044504191c72134a514f35` (a local commit on `main`; the repository is pushed
as one squashed commit when the owner asks). Website: `7199c735eb1ed977d187286b73b892f37dc538c4`.

## Changed behavior

Version 0.1.44 removes the cap on live chats at the owner's request. The
project helper kept at most three chat runtimes loaded per project, unloaded
an idle one to make room and refused a fourth with "Three runtimes are active
or pinned by side chats; close or keep a side first" when every loaded chat
was busy or pinned by a side. `HostService.ensureCapacity` and its three
call sites (opening a chat, opening a side, forking a side) are gone: every
opened chat and side stays loaded for as long as the app holds it open, and
nothing is unloaded to make room. The app's handling of a `session.unloaded`
event stays for older helpers.

## Acceptance checks

**455 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures.** The
Swift helper package changed in this version and its 151 cases pass;
the Python scripts are unchanged since 0.1.38 and their 52 cases pass again. The performance
baseline class ran again in a Release build; its numbers are below. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 455 | 4 | 0 |
| `UIScreenshotTests` gallery and `TerminalCaptureTests` (42 captures) | 2 | 0 | 0 |
| Swift helper suite | 151 | 0 | 0 |
| Python (unchanged since 0.1.38, run again) | 52 | 0 | 0 |

New coverage: a helper contract test opens six chats in one workspace and
checks that each opens idle, that every one still answers a snapshot
afterwards and that no `session.unloaded` event was emitted; the app suite,
the gallery and the 0.1.43 connection-flow test run unchanged.

Performance, measured by `PerformanceBaselineTests` in a Release build on
the build Mac (Apple silicon, macOS 14.8); this version changes no measured
path, so the figures repeat 0.1.43's within run-to-run noise:

| Path | 0.1.43 | 0.1.44 |
| --- | ---: | ---: |
| Terminal emulator, 3.4 MB of colour-changing output | 70 ms | 72 ms |
| Markdown, 14 KB mixed document, parsed cold | 13.4 ms | 12.3 ms |
| Markdown, 11 KB reply streamed in 37 deltas, parse per delta | 0.36 ms | 0.42 ms |
| Grouping 500 rows into turns (`blocks(of:)`) | 2.5 ms | 2.0 ms |
| Syntax highlighting, 16 KB of Swift | 4.1 ms | 3.8 ms |
| Opening a 300-row chat (mount, layout, first display) | 18 ms | 9 ms |
| Streaming delta in a 300-row chat (explicit layout + display per delta) | 31 ms | 31 ms |

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
- Download: [BelloAgent-0.1.44.dmg](https://belloware.com/assets/BelloAgent-0.1.44.dmg).
- Size: **7,160,116 bytes (6.83 MiB)**.
- SHA-256: `4d890fc163a3df16e5e9aad37fc781bc969297f12e6a2ab105ecc547f3879337`.
- App notarization: `439c6b08-bc28-4406-891f-46b6c253e543` (accepted).
- DMG notarization: `77d6cb1d-00ba-4f71-8171-0ebb0a6e863f` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.44` committed and pushed website
`7199c735eb1ed977d187286b73b892f37dc538c4` ("Publish Bello Agent 0.1.44 update"). The public
appcast lagged the push for under four minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 13:25:46 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.44.log` (unit suite), `gallery-0.1.44.log`, `perf-0.1.44.log`, `helper-0.1.44.log`, `python-0.1.44.log`, `release-0.1.44-sign.log`,
`publish-0.1.44.log`, `public-0.1.44.log`,
`release.YQXpgq/` (build, notarization and smoke logs) and `releases/0.1.44/`
including both dSYMs; gallery captures under the scratchpad's
`gallery36/screenshots`.
Historical [0.1.43 evidence](Bello-Agent-0.1.43-2026-09-18.md) remains unchanged.
