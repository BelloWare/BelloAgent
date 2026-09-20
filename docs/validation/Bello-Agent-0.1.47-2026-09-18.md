# Bello Agent 0.1.47 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.47/build 51**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 16:14:07 UTC.**
Release source: `a093b4df18176df0df411d842475cbaff9efc43e` (a local commit on `main`; the repository is pushed
as one squashed commit when the owner asks). Website: `4580f6b23af1dafecd459cc47b96cfcbc1923781`.

## Changed behavior

Version 0.1.47 changes three things the owner asked for. Retry request
now sends the chat's current model and reasoning effort: the app passes the
pills as they stand to `turn.retry`, and the helper builds the retried
request from them (cleared pills retry with the connection's defaults), so a
model switched after a failure is what retries. The output budget is
metadata only: it is never sent as `max_output_tokens` and never fails a
turn. A conversation request carries the model's catalog ceiling as its
output limit, clipped to the room the context estimate leaves in the window,
or no limit when the catalog gives none; the connection test, chat titles
and compaction summaries keep their own small caps. The budget only sizes
the reserve that decides when a chat compacts, and a request whose input
fits the window is always sent. The Usage menu's model distribution keeps
its layout with very long model ids: axis labels and the per-model rows are
cut in the middle, and the bars and figures keep their columns.

## Acceptance checks

**457 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures.** The
Swift helper package changed in this version and its 159 cases pass;
the Python fixture contract changed too (a request may omit its output
limit) and its 52 cases pass. The end-to-end native host script
(`scripts/test-native-host.py`) ran against the Release helper for the first
time since 0.1.37; its 24 cases pass once its failed-run expectations were
brought up to the `error` state introduced in 0.1.45 (that script edit is in
the record commit, not in the release source). The performance
baseline class ran again in a Release build; its numbers are below. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 457 | 4 | 0 |
| `UIScreenshotTests` gallery and `TerminalCaptureTests` (42 captures) | 2 | 0 | 0 |
| Swift helper suite | 159 | 0 | 0 |
| Python fixtures (contract changed in this version) | 52 | 0 | 0 |
| End-to-end native host script against the Release helper | 24 | 0 | 0 |

New coverage: five helper cases (`OutputCapDispatchTests`) show a
conversation turn sending the model ceiling and not the budget, no cap when
no ceiling is known, the cap clipped to the room a nearly full window leaves
while the reserve no longer stops the turn, input that cannot fit still
stopping the turn before any request, and a title task keeping its 512-token
cap; the profile, request-context, capacity and gateway cases were updated
to the same rule. The helper's retry case retries once with switched
overrides and once with none and checks each request's model and effort.
The opt-in Usage menu capture renders a 70-character model id. Earlier
coverage runs unchanged; the gallery captures every surface in both
appearances.

Performance, measured by `PerformanceBaselineTests` in a Release build on
the build Mac (Apple silicon, macOS 14.8); this version changes no measured
path, so the figures repeat 0.1.46's within run-to-run noise:

| Path | 0.1.46 | 0.1.47 |
| --- | ---: | ---: |
| Terminal emulator, 3.4 MB of colour-changing output | 70 ms | 73 ms |
| Markdown, 14 KB mixed document, parsed cold | 14.7 ms | 12.1 ms |
| Markdown, 11 KB reply streamed in 37 deltas, parse per delta | 0.35 ms | 0.34 ms |
| Grouping 500 rows into turns (`blocks(of:)`) | 1.6 ms | 1.5 ms |
| Syntax highlighting, 16 KB of Swift | 4.2 ms | 4.3 ms |
| Opening a 300-row chat (mount, layout, first display) | 24 ms | 21 ms |
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
- Download: [BelloAgent-0.1.47.dmg](https://belloware.com/assets/BelloAgent-0.1.47.dmg).
- Size: **7,186,673 bytes (6.85 MiB)**.
- SHA-256: `8b718ddd7b93de0626328383f7344b1c078f1c81aebbae6980fe435219922f0f`.
- App notarization: `45cb290b-fc2b-4b96-9ffb-8882773703cf` (accepted).
- DMG notarization: `7bc97997-d9be-40d4-965c-bac7eb5c3531` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.47` committed and pushed website
`4580f6b23af1dafecd459cc47b96cfcbc1923781` ("Publish Bello Agent 0.1.47 update"). The public
appcast lagged the push for under five minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 16:14:07 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.47.log` (unit suite), `gallery-0.1.47.log`, `perf-0.1.47.log`, `helper-0.1.47.log`, `python-0.1.47.log`, `native-host-0.1.47.log`, `release-0.1.47-sign.log`,
`publish-0.1.47.log`, `public-0.1.47.log`,
`release.EZrhYx/` (build, notarization and smoke logs) and `releases/0.1.47/`
including both dSYMs; gallery captures under the scratchpad's
`gallery40/screenshots`.
Historical [0.1.46 evidence](Bello-Agent-0.1.46-2026-09-18.md) remains unchanged.
