# Bello Agent 0.1.25 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.25/build 29**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 03:24:26 UTC.**
Release source: `541b206b4c710fa081b77917569f40754effed95`. Website: `74365cd67c84cb3c8b9ab86295c3a4fb4d37d4de`.

## Changed behavior

Version 0.1.25 refreshes custom model catalogs lazily every five minutes
instead of every hour, so a changed catalog reaches the model picker sooner.
Loading stays lazy and per connection, a failed fetch still backs off for
thirty seconds, and explicit Refresh still reloads immediately.

## Acceptance checks

**405 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 32 light/dark captures.** The transcript/host (143), Swift
helper (141) and Python (62) suites are unchanged since 0.1.24 and reuse that
evidence. The native run skipped the
optional `NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate
requests, tools, cancellation, compaction and capture; no deployed LiteLLM was
used. No Release performance matrix was run. Installation/update rehearsals
were skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 405 | 4 | 0 |
| `UIScreenshotTests` gallery (32 captures) | 1 | 0 | 0 |
| Transcript/host, helper and Python (unchanged, 0.1.24 evidence) | 346 | 0 | 0 |

New coverage: the catalog endpoint test now advances a synthetic clock past
four minutes without a refetch and past five minutes with one.

## Limits and preserved contracts

The shorter window only changes when a lazily opened picker refetches; it
adds no background polling. Gateway catalogs are fetched anonymously as
before, and only the gateway's origin receives its key.
Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, Release performance matrix, installation or Sparkle update/relaunch
rehearsal was used. SwiftUI/AppKit composers, WKWebView/React, the supervised
Swift helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.25.dmg](https://belloware.com/assets/BelloAgent-0.1.25.dmg).
- Size: **6,277,089 bytes (5.99 MiB)**.
- SHA-256: `ace9b565cf8b2d3d3cf03d642eee3c9a63d5ebc95a8a445b0aca67fcc3d164a4`.
- App notarization: `2dbebf7e-bee2-464f-bb39-58c45a767e0e` (accepted).
- DMG notarization: `6c789cfd-7d4d-4694-8de2-34e03df9a294` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.25` committed and pushed website
`74365cd67c84cb3c8b9ab86295c3a4fb4d37d4de` ("Publish Bello Agent 0.1.25 update"). The public
appcast lagged the push for about three minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 03:24:26 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.25.log` (bundle, unit suite and gallery), `release-0.1.25-sign.log`,
`publish-0.1.25.log`, `public-0.1.25.log`,
`release.kRjc1V/` (build, notarization and smoke logs) and `releases/0.1.25/`
including both dSYMs; gallery captures under the scratchpad's
`gallery8/screenshots`.
Historical [0.1.24 evidence](Bello-Agent-0.1.24-2026-09-17.md) remains unchanged.
