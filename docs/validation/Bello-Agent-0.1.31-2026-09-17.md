# Bello Agent 0.1.31 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.31/build 35**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 13:26:47 UTC.**
Release source: `3ba3c8a9cf99b14fe283efb23afd5789283cc466`. Website: `fa1de3de210f6e0a1803015fe3875d8d61f00690`.

## Changed behavior

Version 0.1.31 puts a reply's figures on its own line: what it did, how
long it took, its tokens, cost and model (a link to the request), with
reasoning, tool call rows and each request's full accounting folded behind
the chevron. The turn line, under the last reply of every turn including
single-reply turns, is a plain summary with nothing to expand: time, replies
and tool calls, model versus tool time, input tokens split into cached and
uncached, output tokens with the reasoning share, and cost, each with
coverage when not every request reported. Session info is one scrolling page:
first-token time and speed first, then requests, tokens and cost, the
per-request charts, a bar stacking cached input, uncached input and output,
the token and cache cards, and the cost and model distributions. Settings
shows every saved connection as a tab with the count beside them, and a new
connection opens in its own tab until it is saved.

## Acceptance checks

**417 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 34 light/dark captures; 149 Swift helper cases and
145 transcript/host cases pass.** The Python suite (62) is unchanged since
0.1.30 and reuses that evidence. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 417 | 4 | 0 |
| `UIScreenshotTests` gallery (34 captures) | 1 | 0 | 0 |
| Swift helper suite | 149 | 0 | 0 |
| Transcript/host suite | 145 | 0 | 0 |
| Python (unchanged, 0.1.30 evidence) | 62 | 0 | 0 |

New coverage: transcript tests check a reply line's duration, tokens, cost
and model link with folded accounting, the turn summary's cached, uncached,
output and reasoning figures with partial coverage, live count-ups on both
lines, and the number formats; a native test stacks the token bar from
paired, derived and partial cache reports.

## Limits and preserved contracts

Sums add only what each request reported; a missing figure lowers the
coverage shown beside it rather than counting as zero. The uncached share of
input is derived from input minus cached only when both were reported for
every request. The helper is unchanged.
Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, Release performance matrix, installation or Sparkle update/relaunch
rehearsal was used. SwiftUI/AppKit composers, WKWebView/React, the supervised
Swift helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.31.dmg](https://belloware.com/assets/BelloAgent-0.1.31.dmg).
- Size: **7,246,039 bytes (6.91 MiB)**.
- SHA-256: `d4ed7f87eb93ef0703824e186f7771bcf566d6d8c84ccb1055d505ad4ce0b82f`.
- App notarization: `a1b7e404-0ad1-411a-89d4-b21890f0dfbc` (accepted).
- DMG notarization: `59b75257-38bb-4bef-9795-fd03232fb2c5` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.31` committed and pushed website
`fa1de3de210f6e0a1803015fe3875d8d61f00690` ("Publish Bello Agent 0.1.31 update"). The public
appcast lagged the push for about four minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 13:26:47 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.31.log` (bundle, unit suite and gallery), `host-0.1.31.log`, `release-0.1.31-sign.log`,
`publish-0.1.31.log`, `public-0.1.31.log`,
`release.kPjcGx/` (build, notarization and smoke logs) and `releases/0.1.31/`
including both dSYMs; gallery captures under the scratchpad's
`gallery14/screenshots`.
Historical [0.1.30 evidence](Bello-Agent-0.1.30-2026-09-17.md) remains unchanged.
