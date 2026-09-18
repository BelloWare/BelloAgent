# Bello Agent 0.1.28 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.28/build 32**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 06:06:02 UTC.**
Release source: `5c8d5141d80a808d6048d29441e898c49b2acf62`. Website: `1198f1e1a41469313b8aa119e4aaea9d02b31b9a`.

## Changed behavior

Version 0.1.28 lets the chats of one project run at the same time: the helper
no longer holds a workspace-wide lease for a whole run, so a message sent to a
second chat starts immediately while the first is still answering; only
editing tool calls (write, edit, bash, MCP invoke) take turns on the
workspace gate. The Changes sheet becomes an IntelliJ-style git tool: a
branch menu that switches or creates branches, fetch, pull (fast-forward) and
push with ahead/behind counters, stash and pop, per-file and per-section
checkboxes so Commit takes the checked files, Amend that prefills HEAD's
message, Discard with a confirmation, a unified or side-by-side diff, history
filtered by message, hash prefix or author across all branches with branch
and tag badges, and per-file diffs inside a commit. A terminal panel (⌃`)
opens under the chat with one login shell per project that survives hiding.
Opening a chat focuses the composer; double-clicking a chat opens a rename
sheet with mini-model title suggestions; every chat row has an archive button
that asks once inline; projects list five chats with a "Show more" row. The
Session usage window becomes Session info, with tiles for the latest and
median first-token time, latest and average output rate, and the session's
model and tool time with the last turn's split; and when a turn spans several
replies the transcript adds the whole turn's time, counts and model/tool
split under the last reply.

## Acceptance checks

**411 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 34 light/dark captures; 144 Swift helper cases and
143 transcript/host cases pass.** The Python suite (62) is unchanged since
0.1.27 and reuses that evidence. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 411 | 4 | 0 |
| `UIScreenshotTests` gallery (34 captures) | 1 | 0 | 0 |
| Swift helper suite | 144 | 0 | 0 |
| Transcript/host suite | 143 | 0 | 0 |
| Python (unchanged, 0.1.27 evidence) | 62 | 0 | 0 |

New coverage: helper tests drive two sessions of one workspace through a
shared gate and assert the second answers while the first's model request is
still held, that their editing tool calls never overlap while read-only calls
do, and that only MCP invocations count as editing. Transcript tests cover
turn totals on multi-reply turns, including live ones; a native test covers
the Session info timing figures. Native tests drive the
git service through branch creation and switching, ref badges, all-branch,
text, hash-prefix and author history filters, per-file commit diffs, stash
push/list/pop, checked-file commits, amend, discard of staged, unstaged and
untracked files, and a push without a remote; a parser test covers
side-by-side row pairing.

## Limits and preserved contracts

The Changes sheet uses /usr/bin/git with the user's own configuration. Every
write is an explicit action; discard confirms first and pull is fast-forward
only. The terminal is a login shell with gateway keys removed from its
environment; it is not sandboxed beyond that. The gallery project is not a
repository, so the sheet's populated state is covered by native tests rather
than a capture, and the terminal panel is exercised manually.
Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, Release performance matrix, installation or Sparkle update/relaunch
rehearsal was used. SwiftUI/AppKit composers, WKWebView/React, the supervised
Swift helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.28.dmg](https://belloware.com/assets/BelloAgent-0.1.28.dmg).
- Size: **7,230,232 bytes (6.90 MiB)**.
- SHA-256: `ad09c1c2097925556da05a7324eae9aed118f98caa0b9d51831af6bd9ec37e6f`.
- App notarization: `cb4bcdeb-46cf-4654-8a82-adf44cf0e2ad` (accepted).
- DMG notarization: `21a3a0a7-fec4-44e6-bb1c-7c34798732a8` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.28` committed and pushed website
`1198f1e1a41469313b8aa119e4aaea9d02b31b9a` ("Publish Bello Agent 0.1.28 update"). The public
appcast lagged the push for about three minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 06:06:02 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.28.log` (bundle, unit suite and gallery), `host-0.1.28.log`, `release-0.1.28-sign.log`,
`publish-0.1.28.log`, `public-0.1.28.log`,
`release.jncQWA/` (build, notarization and smoke logs) and `releases/0.1.28/`
including both dSYMs; gallery captures under the scratchpad's
`gallery11/screenshots`.
Historical [0.1.27 evidence](Bello-Agent-0.1.27-2026-09-17.md) remains unchanged.
