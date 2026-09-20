# Bello Agent 0.1.48 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.48/build 52**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 17:12:05 UTC.**
Release source: `c52a3d197553c32c7ef0e8dfa2230f16cff68066` (a local commit on `main`; the repository is pushed
as one squashed commit when the owner asks). Website: `67e1eb1414622f013abafc3e27f05462e9c64b93`.

## Changed behavior

Version 0.1.48 fixes the crash the owner reported in 0.1.47 and hardens
the app after it. The transcript page drove SwiftUI's scroll proxy from an
AppKit frame-change notification that fired while the hosting scroll view
was still mid-update, which trapped the app; every scroll the page lands is
now deferred to the next run-loop turn. Settings can be saved while a
connection's chats are working: the helper's new `session.configure` command
hands the saved profile and key to open sessions, a run that is going keeps
the settings it started with and switches when it ends, and an idle chat
takes them at once, so nothing is closed or blocked. Editing an earlier
message no longer re-anchors the page on every frame of the composer's
resize, and the slash-completion popup no longer forces a composer
re-render per keystroke. A code audit for the same classes of failure fixed
a host pipe deadlock (the stdout reader waited on the command queue while
a stdin write could block on a full pipe), a stale handshake watchdog that
could kill a later healthy host, a delayed terminal SIGKILL that could reach
a recycled pid, a `precondition` in the terminal, force unwraps on archive
rows that would trap on a damaged database, and AppKit calls made from
inside SwiftUI updates in the captured-JSON outline, the paged text view,
the page-visibility background and the session usage window.

## Acceptance checks

**458 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures.** The
Swift helper package changed in this version and its 161 cases pass;
the Python fixtures are unchanged since 0.1.47 and their 52 cases pass again. The end-to-end native host script
(`scripts/test-native-host.py`) ran again against the Release helper; its 24
cases pass, with its serve fixture now accepting a request that carries no
output limit, as a profile without a catalog ceiling sends. The performance
baseline class ran again in a Release build; its numbers are below. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 458 | 4 | 0 |
| `UIScreenshotTests` gallery and `TerminalCaptureTests` (42 captures) | 2 | 0 | 0 |
| Swift helper suite | 161 | 0 | 0 |
| Python fixtures (unchanged since 0.1.47, run again) | 52 | 0 | 0 |
| End-to-end native host script against the Release helper | 24 | 0 | 0 |

New coverage: the helper's `SessionConfigureTests` show settings saved
during a run applying when it ends and at once when idle, with the next
request carrying the new profile and key, plus the host command reporting
whether they are in use; the app's settings-save test now saves during a
run instead of expecting a refusal; a Release-build baseline times editing
the first message of a 300-row chat through the real conversation pane. The
transcript page, capture integration and usage tests run against the
deferred scroll landing and the relaxed serve fixture. Earlier coverage
runs unchanged; the gallery captures every surface in both appearances.

Performance, measured by `PerformanceBaselineTests` in a Release build on
the build Mac (Apple silicon, macOS 14.8); this version changes no measured
path, so the figures repeat 0.1.47's within run-to-run noise. The editing
baseline is new: it drives the real conversation pane and shows the pane
itself is not where an editing lag could come from:

| Path | 0.1.47 | 0.1.48 |
| --- | ---: | ---: |
| Terminal emulator, 3.4 MB of colour-changing output | 73 ms | 74 ms |
| Markdown, 14 KB mixed document, parsed cold | 12.1 ms | 11.9 ms |
| Markdown, 11 KB reply streamed in 37 deltas, parse per delta | 0.34 ms | 0.43 ms |
| Grouping 500 rows into turns (`blocks(of:)`) | 1.5 ms | 1.8 ms |
| Syntax highlighting, 16 KB of Swift | 4.3 ms | 4.3 ms |
| Opening a 300-row chat (mount, layout, first display) | 21 ms | 5 ms (the bottom scroll now lands one run-loop turn later, outside this measurement) |
| Streaming delta in a 300-row chat (explicit layout + display per delta) | 31 ms | 31 ms |
| Editing the first message of a 300-row chat: begin, then per keystroke, then cancel (new) | not measured | 2.7 ms, 1.4 ms, 1.0 ms |

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
- Download: [BelloAgent-0.1.48.dmg](https://belloware.com/assets/BelloAgent-0.1.48.dmg).
- Size: **7,203,566 bytes (6.87 MiB)**.
- SHA-256: `5b74ee2fded4a7ca8305a157d85db95a979b842ee6ab66624d1f1b14af129bd4`.
- App notarization: `6405e5e3-4257-47ff-91f3-ab04dffd4f2e` (accepted).
- DMG notarization: `ac6873f5-c55a-4253-b138-9245d7330c73` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.48` committed and pushed website
`67e1eb1414622f013abafc3e27f05462e9c64b93` ("Publish Bello Agent 0.1.48 update"). The public
appcast lagged the push for under five minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 17:12:05 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.48.log` (unit suite), `gallery-0.1.48.log`, `perf-0.1.48.log`, `helper-0.1.48.log`, `python-0.1.48.log`, `native-host-0.1.48.log`, `release-0.1.48-sign.log`,
`publish-0.1.48.log`, `public-0.1.48.log`,
`release.J4djTw/` (build, notarization and smoke logs) and `releases/0.1.48/`
including both dSYMs; gallery captures under the scratchpad's
`gallery41/screenshots`.
Historical [0.1.47 evidence](Bello-Agent-0.1.47-2026-09-18.md) remains unchanged.
