# Bello Agent 0.1.36 acceptance

Date: 2026-09-18. Branch: `main`. Version **0.1.36/build 40**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-18 01:24:31 UTC.**
Release source: `e1836b3bf5511a97e9cc9a6f9a7d48644106dfde`. Website: `942d788b4591b182dd0638e182ed010aebac207c`.

## Changed behavior

Version 0.1.36 splits usage per model wherever a scope can mix routes.
Session info shows one Models table in place of two distribution lists:
for each requested route and the model that served it, requests and cost
with their share of the session, tokens, the route's own duration-weighted
output rate and its nearest-rank first-token median, so a fast model and a
slow one never blend; the header tiles say "per model below" when a session
used more than one route. The usage report gains a By model view with the
same columns for the filtered window, share bars of that window, and an
Output tok/s tile beside Time to first token; clicking a route narrows the
report to its alias and model. The gallery now captures the Session info
window and the By model view.

## Acceptance checks

**422 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 38 light/dark captures; 150 Swift helper cases and
149 transcript/host cases pass.** The Python suite (62) is unchanged since
0.1.35 and reuses that evidence. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 422 | 4 | 0 |
| `UIScreenshotTests` gallery (38 captures) | 1 | 0 | 0 |
| Swift helper suite | 150 | 0 | 0 |
| Transcript/host suite | 149 | 0 | 0 |
| Python (unchanged, 0.1.35 evidence) | 62 | 0 | 0 |

New coverage: query tests check that per-route summaries carry their own
duration-weighted output rate and nearest-rank first-token and whole-request
medians, that an unreported route stays its own row, and that the window
figure blends every measured route while the rows keep them apart, for both
the report (`modelSummaries`) and Session info (`sessionMetrics`). The
gallery captures the Session info window and the By model view in light
and dark appearance, with a chat that used two routes.

## Limits and preserved contracts

Per-route figures come from the retained attempts table; the busiest 64
routes are shown in the report and 24 per page in Session info. No data
or protocol changed. Rows journaled before 0.1.35 still fall back to row-order grouping and
row gaps. Deterministic local
fixtures validate HTTP requests, response SSE, tools, cancellation,
compaction and capture. No live deployed LiteLLM, production credential,
Release performance matrix, installation or Sparkle update/relaunch rehearsal
was used. SwiftUI/AppKit composers, WKWebView/React, the supervised Swift
helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.36.dmg](https://belloware.com/assets/BelloAgent-0.1.36.dmg).
- Size: **7,328,637 bytes (6.99 MiB)**.
- SHA-256: `d5ce235338331aa2f8fae3fc3ca8ae37bb14fe4bcc97862dbc86dbdcaee307fc`.
- App notarization: `702a982b-a4ad-4e22-aa0c-ac9addbef709` (accepted).
- DMG notarization: `d733cd82-2249-4534-bd66-4f35b2d45e4c` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.36` committed and pushed website
`942d788b4591b182dd0638e182ed010aebac207c` ("Publish Bello Agent 0.1.36 update"). The public
appcast lagged the push for under 4 minutes (7 checks 30 s apart) while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-18 01:24:31 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.36.log` (bundle, unit suite and gallery), `host-0.1.36.log`, `release-0.1.36-sign.log`,
`publish-0.1.36.log`, `public-0.1.36.log`,
`release.hyWgxn/` (build, notarization and smoke logs) and `releases/0.1.36/`
including both dSYMs; gallery captures under the scratchpad's
`gallery20/screenshots`.
Historical [0.1.35 evidence](Bello-Agent-0.1.35-2026-09-18.md) remains unchanged.
