# Bello Agent 0.1.45 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.45/build 49**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 14:45:05 UTC.**
Release source: `9af946daf435d696d0cab53ac402c21b70966912` (a local commit on `main`; the repository is pushed
as one squashed commit when the owner asks). Website: `d52e8ac9c8435cbac619812b54893764bdc12766`.

## Changed behavior

Version 0.1.45 walks the first-run and everyday paths after the owner
asked for a smooth, self-explaining experience. Gateway failures are worded
for the reader by the helper: the provider's own detail first, then the
likely cause with what to check (the API key for 401/403, the base URL and
alias for 404, a rate limit for 429, the gateway for 5xx, the final URL for
redirects; an unknown host, an unreachable gateway, a timeout or an
untrusted certificate for transport failures), keeping the
"Provider returned HTTP N." prefix the retry policy and the connection test
read. Onboarding explains a disabled Continue (the URL, its scheme, the
key), greets a returning user whose connection is saved, and names the last
step "Start your first chat" once a project is ready. The welcome screen
offers New Chat once a project and a connection exist. The test request in
Settings, removing a project and typing a model alias for a chat are
confirmed or entered in place, in the sheet or popover already open, so no
flow runs a system alert from a sheet. Two run failures the owner met are
gone: a reply the model cuts at the output budget is a complete row with
`stopReason` "length" and a warning under it, the turn ends idle and queued
follow-ups go on (before, the run failed with "Response reached its output
limit"); and the helper's HTTP stream buffers without limit, so a consumer
busy journaling or notifying the app never loses a chunk to a fixed buffer
(before, a 128-part buffer cancelled the stream with "Consumer could not
keep up"), with `stream_backpressure` retried like a transport failure
should it ever occur. A run that failed or was stopped can be retried from
its failure row: "Retry request" sends the turn again from where it stopped
(helper command `turn.retry`), the partial reply stays but is not replayed,
and queued follow-ups go on after the turn.

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

New coverage: a helper test checks the wording of gateway and transport
failures (401 names the API key, 404 the alias, a provider detail replaces
the pointer to the captured body, unknown host, unreachable gateway, timeout
and certificate causes are named) and that the status stays parseable; an
onboarding test walks the hints for an empty URL, a URL without a scheme,
an http URL that is not localhost, a missing key and an invalid key, and
checks that a saved connection is greeted as returning; a helper session
test runs a reply cut at the output budget and checks that the turn ends
idle with no failure, the row carries the reason and the next message goes
through; the retry classification test covers `stream_backpressure`; an
app test decodes the reason from a live row and a journal; a retry test
fails a request the policy does not retry, retries it from the row's
command, checks that the turn completes with no added message and that a
completed turn refuses another retry. Earlier coverage,
including the 0.1.43 connection flow and the 0.1.44 no-cap test, runs
unchanged. The gallery captures every surface in both appearances.

Performance, measured by `PerformanceBaselineTests` in a Release build on
the build Mac (Apple silicon, macOS 14.8); this version changes no measured
path, so the figures repeat 0.1.44's within run-to-run noise:

| Path | 0.1.44 | 0.1.45 |
| --- | ---: | ---: |
| Terminal emulator, 3.4 MB of colour-changing output | 72 ms | 73 ms |
| Markdown, 14 KB mixed document, parsed cold | 12.3 ms | 14.0 ms |
| Markdown, 11 KB reply streamed in 37 deltas, parse per delta | 0.42 ms | 0.34 ms |
| Grouping 500 rows into turns (`blocks(of:)`) | 2.0 ms | 1.5 ms |
| Syntax highlighting, 16 KB of Swift | 3.8 ms | 3.9 ms |
| Opening a 300-row chat (mount, layout, first display) | 9 ms | 10 ms |
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
- Download: [BelloAgent-0.1.45.dmg](https://belloware.com/assets/BelloAgent-0.1.45.dmg).
- Size: **7,179,717 bytes (6.85 MiB)**.
- SHA-256: `11d923809f4d6c4b7f524c280805372068b39ebe2f74e61d547db082f4082b0d`.
- App notarization: `3e4712ea-27f0-4e36-a1ef-74d00bc363bf` (accepted).
- DMG notarization: `f2ca761a-a388-45b4-8f12-87607f47b83c` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.45` committed and pushed website
`d52e8ac9c8435cbac619812b54893764bdc12766` ("Publish Bello Agent 0.1.45 update"). The public
appcast lagged the push for under four minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 14:45:05 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.45.log` (unit suite), `gallery-0.1.45.log`, `perf-0.1.45.log`, `helper-0.1.45.log`, `python-0.1.45.log`, `release-0.1.45-sign.log`,
`publish-0.1.45.log`, `public-0.1.45.log`,
`release.fHMROY/` (build, notarization and smoke logs) and `releases/0.1.45/`
including both dSYMs; gallery captures under the scratchpad's
`gallery38/screenshots`.
Historical [0.1.44 evidence](Bello-Agent-0.1.44-2026-09-18.md) remains unchanged.
