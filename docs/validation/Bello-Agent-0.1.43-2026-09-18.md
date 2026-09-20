# Bello Agent 0.1.43 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.43/build 47**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 13:13:16 UTC.**
Release source: `b3491f8c2fe62250896c918c9624d0f79a2991e3` (a local commit on `main`; the repository is pushed
as one squashed commit when the owner asks). Website: `8008e13ec2ce0bf447d1f4f80c58f12df760d7a4`.

## Changed behavior

Version 0.1.43 reworks the connection flow in Settings after the owner
found it off in every step. The sheet's state moved into
`ConnectionSettingsController`, so it could be driven by a test the way a
person drives it. A new connection lists models before it is saved: the API
key now sits right under the base URL, the included Bello catalog lists
without a key, and a gateway's own catalog lists with the key typed above
(or the saved one), relisting when the base URL or catalog URL changes and
saying why when it cannot list; before, the picker was disabled until the
connection was saved and its list ignored edited URLs. Each tab keeps its
own draft, so switching tabs no longer discards edits; a dot marks unsaved
edits, Save writes every edited tab (the current one last), and Discard
drops an unsaved one. Saves use the vault's current revision rather than
the sheet's snapshot and retry once after a conflict, so a write made
elsewhere while Settings was open no longer fails the save quietly; a save
that fails keeps its edits on their tab with the reason in red.

## Acceptance checks

**455 native unit cases pass with 4 skipped, and the screenshot gallery
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
| Native unit suite (without acceptance/gallery classes) | 455 | 4 | 0 |
| `UIScreenshotTests` gallery and `TerminalCaptureTests` (42 captures) | 2 | 0 | 0 |
| Swift helper suite (unchanged since 0.1.38, run again) | 150 | 0 | 0 |
| Python (unchanged since 0.1.38, run again) | 52 | 0 | 0 |

New coverage: a connection-flow test opens an empty vault, types a URL and
lists the bundled catalog without a key, sets a custom catalog URL and
checks that the picker asks for the key, types the key and lists the
gateway's models, chooses a model and a mini model, saves, renames (the tab
dot, the vault, the id), adds a second connection, edits the first, switches
tabs and back, saves both tabs at once, saves after another write moved the
vault, changes the catalog URL of a saved connection and relists with the
saved key, discards, and deletes; a second test checks that a failed save
stays on its tab with the reason. Earlier coverage runs unchanged. The
gallery captures every surface in both appearances.

Performance, measured by `PerformanceBaselineTests` in a Release build on
the build Mac (Apple silicon, macOS 14.8); this version changes no measured
path, so the figures repeat 0.1.42's within run-to-run noise:

| Path | 0.1.42 | 0.1.43 |
| --- | ---: | ---: |
| Terminal emulator, 3.4 MB of colour-changing output | 73 ms | 70 ms |
| Markdown, 14 KB mixed document, parsed cold | 15.3 ms | 13.4 ms |
| Markdown, 11 KB reply streamed in 37 deltas, parse per delta | 0.44 ms | 0.36 ms |
| Grouping 500 rows into turns (`blocks(of:)`) | 1.6 ms | 2.5 ms |
| Syntax highlighting, 16 KB of Swift | 4.0 ms | 4.1 ms |
| Opening a 300-row chat (mount, layout, first display) | 15 ms | 18 ms |
| Streaming delta in a 300-row chat (explicit layout + display per delta) | 30 ms | 31 ms |

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
- Download: [BelloAgent-0.1.43.dmg](https://belloware.com/assets/BelloAgent-0.1.43.dmg).
- Size: **7,161,822 bytes (6.83 MiB)**.
- SHA-256: `f30b09b90f84f0ce25c72314352f74b4ad36f4f04ea5917656543e677f408ce1`.
- App notarization: `3f2ed059-9b6d-4753-aa5a-4cf61477afb5` (accepted).
- DMG notarization: `bb1a4156-6815-47e6-aa0f-328a2e116df0` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.43` committed and pushed website
`8008e13ec2ce0bf447d1f4f80c58f12df760d7a4` ("Publish Bello Agent 0.1.43 update"). The public
appcast lagged the push for under four minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 13:13:16 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.43.log` (unit suite), `gallery-0.1.43.log`, `perf-0.1.43.log`, `helper-0.1.43.log`, `python-0.1.43.log`, `release-0.1.43-sign.log`,
`publish-0.1.43.log`, `public-0.1.43.log`,
`release.ZFahUE/` (build, notarization and smoke logs) and `releases/0.1.43/`
including both dSYMs; gallery captures under the scratchpad's
`gallery35/screenshots`.
Historical [0.1.42 evidence](Bello-Agent-0.1.42-2026-09-18.md) remains unchanged.
