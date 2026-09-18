# Bello Agent 0.1.27 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.27/build 31**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 05:13:27 UTC.**
Release source: `6e74ece51dae8780197b6430d2f8ce8963a02c63`. Website: `1826ed0739decfd08a756602f26ea48b1c37618a`.

## Changed behavior

Version 0.1.27 adds a Changes sheet that runs the system git for a
project's folders: branch, upstream and ahead/behind, staged and unstaged
files with status badges, a rendered unified diff with hunk headers, old/new
line numbers and tinted rows, stage and unstage per file or all, a commit box,
and the commit history with each commit's message, files and diff. Reads never
touch the index; stage, unstage and commit are the only writes. It opens from
the project header, the conversation header and ⇧⌘G. Chat titles require a
mini model again: without a chosen or catalog mini model the app says so once
per connection and launch and the chat keeps its first-message title. Sidebar
cost and token totals load through one grouped archive query instead of one
query per chat.

## Acceptance checks

**408 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 34 light/dark captures.** The transcript/host (143), Swift
helper (142) and Python (62) suites are unchanged since 0.1.26 and reuse
that evidence. The native run skipped the
optional `NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate
requests, tools, cancellation, compaction and capture; no deployed LiteLLM was
used. No Release performance matrix was run. Installation/update rehearsals
were skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 408 | 4 | 0 |
| `UIScreenshotTests` gallery (34 captures) | 1 | 0 | 0 |
| Transcript/host, helper and Python (unchanged, 0.1.26 evidence) | 347 | 0 | 0 |

New coverage: a native test drives the git service against a throwaway
repository through status, unstaged, untracked and staged diffs, staging,
unstaging, committing, history paging and commit details; a parser test covers
renames, binaries, no-newline notes, malformed input and porcelain status with
spaces and renames. Title tests assert there is no fallback to the chat model.

## Limits and preserved contracts

The Changes sheet uses /usr/bin/git with the user's own configuration; it
never rewrites history, discards changes or switches branches, and it stops
a git command that runs longer than twenty seconds. Commits use the
repository's identity; a missing identity surfaces git's own message. The
gallery project is not a repository, so the sheet's populated state is covered
by the native test rather than a capture.
Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, Release performance matrix, installation or Sparkle update/relaunch
rehearsal was used. SwiftUI/AppKit composers, WKWebView/React, the supervised
Swift helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.27.dmg](https://belloware.com/assets/BelloAgent-0.1.27.dmg).
- Size: **6,467,351 bytes (6.17 MiB)**.
- SHA-256: `15122026b2dadfe0687dca482df9c40614dc79809a707aff169249f9254ee22c`.
- App notarization: `ef7c337d-69ce-40e8-b2eb-a54ce269a822` (accepted).
- DMG notarization: `246c14d3-d264-42ee-8a9e-fe0c61710ad7` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.27` committed and pushed website
`1826ed0739decfd08a756602f26ea48b1c37618a` ("Publish Bello Agent 0.1.27 update"). The public
appcast lagged the push for about three minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 05:13:27 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.27.log` (bundle, unit suite and gallery), `release-0.1.27-sign.log`,
`publish-0.1.27.log`, `public-0.1.27.log`,
`release.3RScWU/` (build, notarization and smoke logs) and `releases/0.1.27/`
including both dSYMs; gallery captures under the scratchpad's
`gallery10/screenshots`.
Historical [0.1.26 evidence](Bello-Agent-0.1.26-2026-09-17.md) remains unchanged.
