# Bello Agent 0.1.34 acceptance

Date: 2026-09-18. Branch: `master`. Version **0.1.34/build 38**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 16:48:47 UTC.**
Release source: `124b2f2fccb8d5648bbfeff7f49c5f94e62b9d12`. Website: `1b8ef22a9a558aa37698c4dce74b7ac1d434f0d1`.

## Changed behavior

Version 0.1.34 makes the transcript's work lines outcome-aware: a file
counts once however many times it was read or edited, a directory listing is
not a file read, failed or skipped calls are reported as attempts rather than
as work done, and verbs follow the call's state (Editing, Edited, Failed
editing, Skipped editing). MCP calls name their action (listed servers,
loaded tool schemas, called a tool). Edit previews are labelled as the
requested change and marked not applied when the call failed or was skipped;
an overwrite shows its requested content plainly and only a confirmed new
file reads as added lines. The helper stamps every row with its turn id and
each reply with the measured duration of its model request, journaled with
the row; the transcript groups replies by that id, so a compaction, a retry
notice or a failure mid-run no longer splits a turn, a turn that began before
the loaded history says so, and model time is measured rather than inferred
from row gaps. The turn line counts files changed. An expanded work line
keeps a stable key while its reply streams in and stays open; the reply line
no longer repeats the live bar's spinner and current action; the model link
is the toggle's sibling rather than its child; reasoning inside an expanded
line starts folded and unfolds with the same motion; a live reply's line
eases in once it has work to report.

## Acceptance checks

**418 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 34 light/dark captures; 150 Swift helper cases and
149 transcript/host cases pass.** The Python suite (62) is unchanged since
0.1.33 and reuses that evidence. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 418 | 4 | 0 |
| `UIScreenshotTests` gallery (34 captures) | 1 | 0 | 0 |
| Swift helper suite | 150 | 0 | 0 |
| Transcript/host suite | 149 | 0 | 0 |
| Python (unchanged, 0.1.33 evidence) | 62 | 0 | 0 |

New coverage: transcript tests check outcome-aware summaries (one file for
repeated reads or edits, listings apart from reads, failed and skipped calls
named as such, state-following verbs, MCP actions), the requested-change
labels on edit and write previews, stable block keys while a reply arrives,
turn grouping across compaction, notice and failure rows, host turn ids
separating replies and marking partial turns, measured model time winning
over row gaps, the files-changed count and the model link as the toggle's
sibling. The helper suite checks that rows carry their turn id and model
time and that both survive a journal reload; the native suite checks the
history projection keeps clock, turn and model time.

## Limits and preserved contracts

Rows journaled before 0.1.34 carry no turn id or model time; the transcript
falls back to row-order grouping and row gaps for them. Deterministic local
fixtures validate HTTP requests, response SSE, tools, cancellation,
compaction and capture. No live deployed LiteLLM, production credential,
Release performance matrix, installation or Sparkle update/relaunch rehearsal
was used. SwiftUI/AppKit composers, WKWebView/React, the supervised Swift
helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.34.dmg](https://belloware.com/assets/BelloAgent-0.1.34.dmg).
- Size: **7,275,516 bytes (6.94 MiB)**.
- SHA-256: `edd71cf3ede27bb773d68059542cd1bcc07fb8e6387d4053702dbd9edf3bce64`.
- App notarization: `72ce12d9-88d2-4818-9fd6-b057ca088538` (accepted).
- DMG notarization: `8bf531a8-a33c-4458-b66b-cc8347d39539` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.34` committed and pushed website
`1b8ef22a9a558aa37698c4dce74b7ac1d434f0d1` ("Publish Bello Agent 0.1.34 update"). The public
appcast lagged the push for under 4 minutes (7 checks 30 s apart) while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 16:48:47 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.34.log` (bundle, unit suite and gallery), `host-0.1.34.log`, `release-0.1.34-sign.log`,
`publish-0.1.34.log`, `public-0.1.34.log`,
`release.KDaEa4/` (build, notarization and smoke logs) and `releases/0.1.34/`
including both dSYMs; gallery captures under the scratchpad's
`gallery17/screenshots`.
Historical [0.1.33 evidence](Bello-Agent-0.1.33-2026-09-17.md) remains unchanged.
