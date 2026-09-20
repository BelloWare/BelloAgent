# Bello Agent 0.1.46 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.46/build 50**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 15:20:46 UTC.**
Release source: `3fcb762c54d6dc8a4681b846a1b339d5d56ae6d8` (a local commit on `main`; the repository is pushed
as one squashed commit when the owner asks). Website: `def13c36778eefc98fb6d61ecd8959b71a3fb7b8`.

## Changed behavior

Version 0.1.46 fixes the retry the owner found wrong: Retry request re-ran
the failed turn with the connection's default model and effort, because the
helper cleared the turn's submission (which carries the chat's model,
reasoning effort and budgets) when the run ended, and the retried run built
its request from the bare profile. The helper now keeps the failed or
stopped turn's submission and restores it for the retry, so the retried
request uses the same model, effort and budgets as the request that failed
and completes the same command receipt.

## Acceptance checks

**457 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures.** The
Swift helper package changed in this version and its 154 cases pass;
the Python scripts are unchanged since 0.1.38 and their 52 cases pass again. The performance
baseline class ran again in a Release build; its numbers are below. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 457 | 4 | 0 |
| `UIScreenshotTests` gallery and `TerminalCaptureTests` (42 captures) | 2 | 0 | 0 |
| Swift helper suite | 154 | 0 | 0 |
| Python (unchanged since 0.1.38, run again) | 52 | 0 | 0 |

New coverage: the helper's retry test now submits with a model override and
a reasoning effort and checks that the retried request carries the same
model and effort as the failed one. Earlier coverage runs unchanged; the
gallery captures every surface in both appearances.

Performance, measured by `PerformanceBaselineTests` in a Release build on
the build Mac (Apple silicon, macOS 14.8); this version changes no measured
path, so the figures repeat 0.1.45's within run-to-run noise:

| Path | 0.1.45 | 0.1.46 |
| --- | ---: | ---: |
| Terminal emulator, 3.4 MB of colour-changing output | 73 ms | 70 ms |
| Markdown, 14 KB mixed document, parsed cold | 14.0 ms | 14.7 ms |
| Markdown, 11 KB reply streamed in 37 deltas, parse per delta | 0.34 ms | 0.35 ms |
| Grouping 500 rows into turns (`blocks(of:)`) | 1.5 ms | 1.6 ms |
| Syntax highlighting, 16 KB of Swift | 3.9 ms | 4.2 ms |
| Opening a 300-row chat (mount, layout, first display) | 10 ms | 24 ms |
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
- Download: [BelloAgent-0.1.46.dmg](https://belloware.com/assets/BelloAgent-0.1.46.dmg).
- Size: **7,180,448 bytes (6.85 MiB)**.
- SHA-256: `789fc8ab3a3b313b9d3e7c658e7e2f55394139cfd4c4559e73a0437347f0a259`.
- App notarization: `2620a294-c002-4543-8f3f-56156eb12db4` (accepted).
- DMG notarization: `b49989ec-e3ec-4a8f-a1d0-d1f810f7aa51` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.46` committed and pushed website
`def13c36778eefc98fb6d61ecd8959b71a3fb7b8` ("Publish Bello Agent 0.1.46 update"). The public
appcast lagged the push for under five minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 15:20:46 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.46.log` (unit suite), `gallery-0.1.46.log`, `perf-0.1.46.log`, `helper-0.1.46.log`, `python-0.1.46.log`, `release-0.1.46-sign.log`,
`publish-0.1.46.log`, `public-0.1.46.log`,
`release.HoLX4z/` (build, notarization and smoke logs) and `releases/0.1.46/`
including both dSYMs; gallery captures under the scratchpad's
`gallery39/screenshots`.
Historical [0.1.45 evidence](Bello-Agent-0.1.45-2026-09-18.md) remains unchanged.
