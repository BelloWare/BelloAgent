# Bello Agent 0.1.42 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.42/build 46**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 11:35:50 UTC.**
Release source: `6b80619760c8328f9eb8a94e3f040cebfd82cc5c` (a local commit on `main`; the repository is pushed
as one squashed commit when the owner asks). Website: `1e57c83b90df30187a0e5d1943f29ee7225d425e`.

## Changed behavior

Version 0.1.42 fixes the connection deletion the owner reported as
doing nothing. Editing a connection's API route saves a new connection and
keeps the old one for its chats, recording the new one as the old route's
model-catalog source (`catalogSources`); deleting either one then left a
link to a missing connection, the vault's validation refused the save, and
the reason appeared only in the sheet's small status line, so the three
tabs stayed. `deleteProfile` now drops every catalog link of the deleted
connection inside the same vault update, reads the vault back and treats a
connection still listed as an error, reloads once when the list on screen is
older than the vault, and logs each outcome to the system log (subsystem
`com.belloware.PiApp`, category `vault`); the Settings footer reports a
failed deletion in red and the window's banner repeats it. Saving a
connection whose route changed keeps Settings open and explains that a new
tab appeared and why the old one stays.

## Acceptance checks

**453 native unit cases pass with 4 skipped, and the screenshot gallery
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
| Native unit suite (without acceptance/gallery classes) | 453 | 4 | 0 |
| `UIScreenshotTests` gallery and `TerminalCaptureTests` (42 captures) | 2 | 0 | 0 |
| Swift helper suite (unchanged since 0.1.38, run again) | 150 | 0 | 0 |
| Python (unchanged since 0.1.38, run again) | 52 | 0 | 0 |

New coverage: a settings test forks a connection by changing its model
(`catalogSources` then maps the old route to the fork), deletes the fork and
checks that the old route stands alone with no link, forks again, deletes
the old route, checks the vault itself lists only the survivor, and checks
that deleting an id the vault no longer has reloads and says so; the 0.1.41
deletion test (a running chat is stopped, not a reason to refuse) and all
earlier coverage run unchanged. The gallery captures every surface in both
appearances.

Performance, measured by `PerformanceBaselineTests` in a Release build on
the build Mac (Apple silicon, macOS 14.8); this version changes no measured
path, so the figures repeat 0.1.41's within run-to-run noise:

| Path | 0.1.41 | 0.1.42 |
| --- | ---: | ---: |
| Terminal emulator, 3.4 MB of colour-changing output | 68 ms | 73 ms |
| Markdown, 14 KB mixed document, parsed cold | 12.1 ms | 15.3 ms |
| Markdown, 11 KB reply streamed in 37 deltas, parse per delta | 0.45 ms | 0.44 ms |
| Grouping 500 rows into turns (`blocks(of:)`) | 1.9 ms | 1.6 ms |
| Syntax highlighting, 16 KB of Swift | 4.7 ms | 4.0 ms |
| Opening a 300-row chat (mount, layout, first display) | 9 ms | 15 ms |
| Streaming delta in a 300-row chat (explicit layout + display per delta) | 30 ms | 30 ms |

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
- Download: [BelloAgent-0.1.42.dmg](https://belloware.com/assets/BelloAgent-0.1.42.dmg).
- Size: **7,137,493 bytes (6.81 MiB)**.
- SHA-256: `f3b8460af5c7ee378921ab8766fbf1cd8dade20921c995255c7b0b0874e0405c`.
- App notarization: `bf284712-bb25-45a6-9db5-4611c7355376` (accepted).
- DMG notarization: `121e9039-2aab-4f19-887a-96a9a8d763dc` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.42` committed and pushed website
`1e57c83b90df30187a0e5d1943f29ee7225d425e` ("Publish Bello Agent 0.1.42 update"). The public
appcast lagged the push for under four minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 11:35:50 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.42.log` (unit suite), `gallery-0.1.42.log`, `perf-0.1.42.log`, `helper-0.1.42.log`, `python-0.1.42.log`, `release-0.1.42-sign.log`,
`publish-0.1.42.log`, `public-0.1.42.log`,
`release.862GxV/` (build, notarization and smoke logs) and `releases/0.1.42/`
including both dSYMs; gallery captures under the scratchpad's
`gallery34/screenshots`.
Historical [0.1.41 evidence](Bello-Agent-0.1.41-2026-09-18.md) remains unchanged.
