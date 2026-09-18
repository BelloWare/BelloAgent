# Bello Agent 0.1.33 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.33/build 37**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 15:41:42 UTC.**
Release source: `e677cdd231584fcec89af3b15e3faa306b10fbee`. Website: `f7d6e1a1dd828123d54f436709be201ea1dca78a`.

## Changed behavior

Version 0.1.33 gives a settled one-reply turn a single line, labelled
Turn, carrying the reply's work, its duration, the model-versus-tool split,
the turn's usage and cost, and the model; multi-reply turns keep a line per
reply plus the turn line. The turn line's hover timestamp no longer wraps an
empty band under the text. Conversations pace by turn: more room before
each user message, less between a message and its reply. Code blocks name
their language beside the copy control on hover, user bubbles wrap at the
same readable width as reply prose, and the empty composer's placeholder
carries the keyboard hints and leaves as typing starts. Motion is brief:
new rows slide in, a finished turn glows for under a second, details unfold,
the live bar breathes and names when the turn started, copies confirm with a
pop, the terminal slides up and sidebar chats fade in and out, all off under
Reduce Motion. The sidebar loses its app name and icon (New Chat joins
the Projects row); the Bello mark sits on the empty-chat card and pulses
while a chat is being prepared.

## Acceptance checks

**417 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 34 light/dark captures; 149 Swift helper cases and
148 transcript/host cases pass.** The Python suite (62) is unchanged since
0.1.32 and reuses that evidence. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 417 | 4 | 0 |
| `UIScreenshotTests` gallery (34 captures) | 1 | 0 | 0 |
| Swift helper suite | 149 | 0 | 0 |
| Transcript/host suite | 148 | 0 | 0 |
| Python (unchanged, 0.1.32 evidence) | 62 | 0 | 0 |

New coverage: transcript tests check the merged single-reply turn line
(label, work, duration, split, usage, model, chevron, no separate band),
that multi-reply turns keep their turn line with hover stamps, the code block
language label, and that fresh rows and settled turns carry their motion
classes while restored pages do not; the composer placeholder and native
transitions are exercised by the screenshot gallery.

## Limits and preserved contracts

The merged line applies only to settled turns; a live turn keeps its
docked bar and the reply's own line. The helper is unchanged.
Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, Release performance matrix, installation or Sparkle update/relaunch
rehearsal was used. SwiftUI/AppKit composers, WKWebView/React, the supervised
Swift helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.33.dmg](https://belloware.com/assets/BelloAgent-0.1.33.dmg).
- Size: **7,268,189 bytes (6.93 MiB)**.
- SHA-256: `9348db4b6471c5ead40672783e5494a0c14e621e481041750d628f865bab4256`.
- App notarization: `79520d07-6aad-4cf7-b1a7-0de700fc464f` (accepted).
- DMG notarization: `c059af27-bdfc-427f-a2f2-8a98a677cc45` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.33` committed and pushed website
`f7d6e1a1dd828123d54f436709be201ea1dca78a` ("Publish Bello Agent 0.1.33 update"). The public
appcast lagged the push for about 5 minutes (10 checks 30 s apart) while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 15:41:42 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.33.log` (bundle, unit suite and gallery), `host-0.1.33.log`, `release-0.1.33-sign.log`,
`publish-0.1.33.log`, `public-0.1.33.log`,
`release.oWqLrA/` (build, notarization and smoke logs) and `releases/0.1.33/`
including both dSYMs; gallery captures under the scratchpad's
`gallery16/screenshots`.
Historical [0.1.32 evidence](Bello-Agent-0.1.32-2026-09-17.md) remains unchanged.
