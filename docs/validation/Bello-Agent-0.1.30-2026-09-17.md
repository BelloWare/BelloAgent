# Bello Agent 0.1.30 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.30/build 34**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 11:19:04 UTC.**
Release source: `c9ef75aac5d5c3c69a83d81ddd55ba4c8e4fa47e`. Website: `a7ad6b2b89db03461667f734fdb26aa909c88fac`.

## Changed behavior

Version 0.1.30 makes the turn line the one place for a turn's figures:
its time, replies and tool calls, model-versus-tool split, summed tokens and
reported cost, with coverage shown when not every request reported. Clicking
the line lists each request's usage with its model and a Details action, so
replies no longer repeat their accounting under themselves, and the "Did"
label is gone from the reply's work line. A spinner turns while a reply is
being worked on, while a turn is live (it also counts up every second) and
while a failed request is being retried; the retry notice names the attempt.

## Acceptance checks

**416 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 34 light/dark captures; 149 Swift helper cases and
145 transcript/host cases pass.** The Python suite (62) is unchanged since
0.1.29 and reuses that evidence. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 416 | 4 | 0 |
| `UIScreenshotTests` gallery (34 captures) | 1 | 0 | 0 |
| Swift helper suite | 149 | 0 | 0 |
| Transcript/host suite | 145 | 0 | 0 |
| Python (unchanged, 0.1.29 evidence) | 62 | 0 | 0 |

New coverage: transcript tests sum a turn's requests (partial coverage
stays null), render the turn's tokens and cost with folded per-request rows,
keep accounting off the reply row inside a turn, and check spinners on live
replies, live turns and retry notices; formatting helpers for compact token
counts and costs are covered directly.

## Limits and preserved contracts

Turn sums add only what each request reported; a request without a figure
lowers the coverage shown next to it rather than counting as zero. Compact
token counts round to three figures. The helper and native app are unchanged
in behaviour apart from the transcript bundle they embed.
Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, Release performance matrix, installation or Sparkle update/relaunch
rehearsal was used. SwiftUI/AppKit composers, WKWebView/React, the supervised
Swift helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.30.dmg](https://belloware.com/assets/BelloAgent-0.1.30.dmg).
- Size: **7,238,488 bytes (6.90 MiB)**.
- SHA-256: `426f8613ddb5d60bfeec0a5b90cd8df51af0b3c2bbbfbc90625b9ce80815b9f3`.
- App notarization: `1e2a6c50-906d-4e68-8418-cbe0d968695d` (accepted).
- DMG notarization: `9dbd351d-3586-43b4-bcf8-5c46baa29abd` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.30` committed and pushed website
`a7ad6b2b89db03461667f734fdb26aa909c88fac` ("Publish Bello Agent 0.1.30 update"). The public
appcast lagged the push for about three minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 11:19:04 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.30.log` (bundle, unit suite and gallery), `host-0.1.30.log`, `release-0.1.30-sign.log`,
`publish-0.1.30.log`, `public-0.1.30.log`,
`release.jQ2UQG/` (build, notarization and smoke logs) and `releases/0.1.30/`
including both dSYMs; gallery captures under the scratchpad's
`gallery13/screenshots`.
Historical [0.1.29 evidence](Bello-Agent-0.1.29-2026-09-17.md) remains unchanged.
