# Bello Agent 0.1.29 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.29/build 33**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-17 06:49:15 UTC.**
Release source: `40675e8b7952b146c816771011d2c3fc2e721bea`. Website: `8cfe0b1e0174a73fee771e302d1fc90845d40a27`.

## Changed behavior

Version 0.1.29 moves errors into the conversation: a failed run appears
as a card where the conversation stopped, a refused send as a card under the
messages, and while the helper retries a transient failure a status line
says so. The helper now tries a model request up to three times before
reporting it: transport failures, HTTP 408/425/429/5xx and provider errors
describing overload, rate limits or temporary unavailability are retried
one and three seconds apart, a partial reply from the failed attempt is
dropped, request errors fail at once, and the report names the attempt
count. Conversations load earlier pages as the reader scrolls up, merging
live updates underneath; switching to an unloaded chat shows its newest page
rather than a page around an old reading position, and up to eight hidden
chats keep their pages. A new chat or an empty side is created only by its
first message; empty ones disappear when the user moves on and a rename or
archive writes the record first. The app has one window, so the menu bar item
and the Dock bring it forward instead of opening a duplicate; the sidebar
opens 300 points wide. Turn totals sit under every turn's last reply and
count up while the turn is live; a reply's own line only names its work.

## Acceptance checks

**416 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 34 light/dark captures; 149 Swift helper cases and
144 transcript/host cases pass.** The Python suite (62) is unchanged since
0.1.28 and reuses that evidence. The native run skipped the optional
`NativeUIAcceptanceTests` class. Local HTTP/SSE fixtures validate requests,
tools, cancellation, compaction and capture; no deployed LiteLLM was used. No
Release performance matrix was run. Installation/update rehearsals were
skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (without acceptance/gallery classes) | 416 | 4 | 0 |
| `UIScreenshotTests` gallery (34 captures) | 1 | 0 | 0 |
| Swift helper suite | 149 | 0 | 0 |
| Transcript/host suite | 144 | 0 | 0 |
| Python (unchanged, 0.1.28 evidence) | 62 | 0 | 0 |

New coverage: helper tests drive a session through two transient failures
before a reply, a third failure that reports the attempt count, a request
error that fails at once, and a Stop during the retry wait; the failure
fixture names a request problem so it is not retried. Native tests cover the
live-page merge with scrolled-up history, pending chats (nothing written,
reuse, drop when empty, rename writes first, delete without a prompt) and
pending sides (no intent or helper session, close hands the draft back).
Transcript tests render failure and notice rows in the conversation flow.

## Limits and preserved contracts

Retries cover model requests only; a tool that ran is never replayed, and a
failure after a tool effect still stops the run for inspection. Earlier pages
are bounded by the display's 500-row window; older rows return through
Earlier Messages. Unsent pending chats and sides are lost when the app quits,
by design, since nothing was written for them.
Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, Release performance matrix, installation or Sparkle update/relaunch
rehearsal was used. SwiftUI/AppKit composers, WKWebView/React, the supervised
Swift helper, saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.29.dmg](https://belloware.com/assets/BelloAgent-0.1.29.dmg).
- Size: **7,237,359 bytes (6.90 MiB)**.
- SHA-256: `75712c3265011ef43d67c165dee308825ac7aa1c78ee9f01e9337bbcb12329ba`.
- App notarization: `b3e3e489-10d5-473c-9ad2-62ada79e5ce1` (accepted).
- DMG notarization: `a538b408-6e99-40bd-b633-59f26978601e` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass on the
stripped bundle. The release validator and packaged helper/catalog smoke pass.
Canonical and legacy appcasts are byte-identical. Bundle ID
`com.belloware.PiApp`, Keychain ownership, history locations and updater
signing identity remain unchanged.

`scripts/publish-release.sh 0.1.29` committed and pushed website
`8cfe0b1e0174a73fee771e302d1fc90845d40a27` ("Publish Bello Agent 0.1.29 update"). The public
appcast lagged the push for about four minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-17 06:49:15 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `verify-0.1.29.log` (bundle, unit suite and gallery), `host-0.1.29.log`, `release-0.1.29-sign.log`,
`publish-0.1.29.log`, `public-0.1.29.log`,
`release.WB7CTC/` (build, notarization and smoke logs) and `releases/0.1.29/`
including both dSYMs; gallery captures under the scratchpad's
`gallery12/screenshots`.
Historical [0.1.28 evidence](Bello-Agent-0.1.28-2026-09-17.md) remains unchanged.
