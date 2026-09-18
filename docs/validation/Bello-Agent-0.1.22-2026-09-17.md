# Bello Agent 0.1.22 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.22/build 26**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 02:12:26 UTC.**
Release source: `6e3cc97c50a9257e957339092f3339c14f741fd7`. Website: `e899b8af4e08b3970576651c0699f0af6beca3d3`.

## Changed behavior

Version 0.1.22 ships stripped binaries and folds exposed reasoning with the
tool calls. The release script now strips the app and helper executables
before signing, so the signature and notarization cover the stripped files,
and keeps both dSYMs in the release directory for crash symbolication; the
symbol table had been more than half of the app binary. The stripped app
binary measures 6,144,448 bytes (down from 14,216,720) and the helper 1,297,008 bytes (down from 1,908,368). Dead-code stripping and
optimisation settings are unchanged. In the transcript, a turn's header now
reads "Reasoned", "Read 1 file" or "Reasoned, read 1 file", and exposed
reasoning stays folded behind it with the tool calls until the user expands
it; a reply with no prose folds away entirely while the turn is collapsed.

## Acceptance checks

**404 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 32 light/dark captures; 143 transcript/host cases, TypeScript
checking and 62 Python script tests pass.** The helper (141 cases) is
unchanged since 0.1.20 and its passing run is reused. The native run skipped
the optional `NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate
requests, tools, cancellation, compaction and capture; no deployed LiteLLM was
used. No Release performance matrix was run. Installation/update rehearsals
were skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 404 | 4 | 0 |
| `UIScreenshotTests` gallery (32 captures) | 1 | 0 | 0 |
| Transcript/host `npm run test:host` | 143 | 0 | 0 |
| Python `scripts/tests` | 62 | 0 | 0 |
| Swift helper (unchanged, 0.1.20 run) | 141 | 0 | 0 |

New coverage: transcript tests for the "Reasoned" header, a reasoning-only
reply folding away, and an answer keeping its reasoning block hidden inside the
folded container. The stripped release is exercised by the release script's own
checks on the final signed bundle: the packaged helper/catalog smoke runs the
stripped helper from inside the app, and Gatekeeper assessment, notarization
and stapling cover the stripped app binary. The synthetic gateway cannot emit
exposed reasoning, so the gallery shows the folded header without a reasoning
case; the transcript tests carry that behaviour.

## Limits and preserved contracts

Stripping removes symbol names only; Swift metadata, Objective-C class tables
and the Sparkle update path are untouched, and the app has no by-name lookups
into its own symbols. The main app was not launched from the release directory
during acceptance because the owner's installed copy was running with the same
bundle identifier. Crash logs from stripped builds symbolicate only with the
retained dSYMs. Deterministic local fixtures validate HTTP requests, response
SSE, tools, cancellation, compaction and capture. No live deployed LiteLLM,
production credential, Release performance matrix, installation or Sparkle
update/relaunch rehearsal was used. SwiftUI/AppKit composers, WKWebView/React,
the supervised Swift helper, saved history, Keychain item and the selected icon
are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.22.dmg](https://belloware.com/assets/BelloAgent-0.1.22.dmg).
- Size: **6,261,291 bytes (5.97 MiB)** (0.1.21 measured 7,409,250 bytes (7.07 MiB)).
- SHA-256: `0efd10e77d7eeb5514113c18e19994fecfc04bc7bc97376c5c7ba6381d2b0eb5`.
- App notarization: `0326bc59-ee59-4c82-b47c-e83fa691e846` (accepted).
- DMG notarization: `825b8782-a3ee-4a34-86d7-dac5fc781bb0` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.22` committed and pushed website
`e899b8af4e08b3970576651c0699f0af6beca3d3` ("Publish Bello Agent 0.1.22 update"). The public
appcast lagged the push for about three minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 02:12:26 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.22.log` (bundle, unit suite and gallery), `release-0.1.22-sign.log`,
`publish-0.1.22.log`, `public-0.1.22.log`,
`release.Ykm8aj/` (build, notarization and smoke logs) and `releases/0.1.22/`
including `Bello Agent.app.dSYM` and `pi-native-host.dSYM`; gallery captures
under the scratchpad's `gallery5/screenshots`.
Historical [0.1.21 evidence](Bello-Agent-0.1.21-2026-09-17.md) remains unchanged.
