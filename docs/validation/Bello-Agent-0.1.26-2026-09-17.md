# Bello Agent 0.1.26 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.26/build 30**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 04:37:08 UTC.**
Release source: `f9c4edb8a16302cb8c5cb8c094af620f65d1d00a`. Website: `332fa57ab023d20897b7f9856e3502737a867fa0`.

## Changed behavior

Version 0.1.26 makes pending follow-ups editable: they can be dragged to
reorder, rewritten in place, promoted to steering so they reach the current
run after its tool batch, or removed, with the helper validating and
persisting each change. A chat can have several side conversations; the pane
shows one at a time at exactly half the content width, opening another side
swaps the pane, and clicking a saved child chat in the sidebar shows it there.
The sidebar's width is dragged on its hairline and remembered. Chat titles are
generated again when no mini model is configured, using the chat's own model,
saved side chats get titles too, and a failed title task releases its claim so
the next message retries. The session usage window gains a Timing tab with
per-request charts for time to first token, output tokens per second, output
tokens and reported cost. The context ring waits 1.5 seconds after the last
keystroke before recounting a draft, and a reply that has not produced a
token yet shows three pulsing dots instead of a bare caret.

## Acceptance checks

**406 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 32 light/dark captures; 143 transcript/host cases and the
Swift helper suite (142 cases) pass.** The Python suite (62) is unchanged
since 0.1.22 and reuses that evidence. The native run skipped the
optional `NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate
requests, tools, cancellation, compaction and capture; no deployed LiteLLM was
used. No Release performance matrix was run. Installation/update rehearsals
were skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 406 | 4 | 0 |
| `UIScreenshotTests` gallery (32 captures) | 1 | 0 | 0 |
| Transcript/host `npm run test:host` | 143 | 0 | 0 |
| Swift helper `swift test` | 142 | 0 | 0 |
| Python `scripts/tests` (unchanged, 0.1.22 evidence) | 62 | 0 | 0 |

New coverage: a helper test reorders, rewrites and steers queued follow-ups
while a run is active and checks delivery in that shape; native tests cover the
title-model fallback, side titling and releasing a failed title claim. The
unit, gallery and transcript suites pass; the gallery's side capture shows the
half-width pane.

## Limits and preserved contracts

Side switching keeps every side's display and any running work; the pane is
presentation only. Queue edits apply to pending messages in the helper; a
message already delivered to the model is not affected. Title generation
still sends one small request per chat and never resends saved work. The
synthetic gateway cannot exercise drag reordering or the pre-token indicator,
so those are covered by helper tests and review of the transcript styles.
Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, Release performance matrix, installation or Sparkle update/relaunch
rehearsal was used. SwiftUI/AppKit composers, WKWebView/React, the supervised
Swift helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.26.dmg](https://belloware.com/assets/BelloAgent-0.1.26.dmg).
- Size: **6,324,764 bytes (6.03 MiB)**.
- SHA-256: `6bfaa63c54d53a42640f50b371e1488899d2aa250f7717289154a5e6f91f58ac`.
- App notarization: `6880cfbd-ce82-47e7-b02c-5fabd4137914` (accepted).
- DMG notarization: `f7fe8865-9295-4276-ac41-24ae97ee37bc` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.26` committed and pushed website
`332fa57ab023d20897b7f9856e3502737a867fa0` ("Publish Bello Agent 0.1.26 update"). The public
appcast lagged the push for about three minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 04:37:08 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.26.log` (bundle, unit suite and gallery), `release-0.1.26-sign.log`,
`publish-0.1.26.log`, `public-0.1.26.log`,
`release.XbdJ1h/` (build, notarization and smoke logs) and `releases/0.1.26/`
including both dSYMs; gallery captures under the scratchpad's
`gallery9/screenshots`.
Historical [0.1.25 evidence](Bello-Agent-0.1.25-2026-09-17.md) remains unchanged.
