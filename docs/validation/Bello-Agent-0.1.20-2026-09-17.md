# Bello Agent 0.1.20 acceptance

Date: 2026-09-17. Branch: `master`. Version **0.1.20/build 24**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 21:06:29 UTC.**
Release source: `26579aa049f15c99c9968a135b97e070c14f920b`. Website: `4b67a23de568a6b711c80b283dc8b3acde3c75eb`.

## Changed behavior

Version 0.1.20 adopts the Codex-style activity presentation for tool calls
and simplifies the sidebar and project flow. The transcript groups each user
message with its reply as a turn whose header reports how long it worked and
how that time split between the model and tools; consecutive tool calls fold
into one collapsed activity line that expands to verb-and-object rows with
status, duration, line counts and a command/output card, and tool-result rows
fold into their call. The helper stamps message clocks, tool durations and file
edit line counts and persists the model/tool split with the session. Sidebar
chats mark unread replies with a dot instead of a count and list cost with
input, cached-input and output tokens. Projects open and are created without a
trust confirmation; the Trusted badge and "Editing tools · Trusted project"
notice are removed while read-only and tool-less notices remain. The footer
shows the session's model-versus-tool time with the last turn in its details.

The release was built from a clean git worktree checked out at the source
commit above. The main checkout held another session's uncommitted accent
contrast work (DesignSystem.swift, transcript.css and an untracked
DesignContrastTests.swift); that work is not part of this release and was not
modified.

## Acceptance checks

**400 native unit cases pass with 4 skipped; the screenshot gallery case
passes with 32 light/dark captures; 141 helper cases, 143 transcript/host
cases, TypeScript checking and 62 Python script tests pass.** All runs used
the release worktree at the source commit. The native run skipped the optional
`NativeUIAcceptanceTests` class; the gallery ran separately and now captures the
grouped tool activity of the first fixture turn (`01a-activity-*.png`). Local
HTTP/SSE fixtures validate requests, tools, cancellation, compaction and
capture; no deployed LiteLLM was used. No Release performance matrix was run.
Installation/update rehearsals were skipped under the standing owner policy.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native unit suite (`release-tests`, without acceptance/gallery classes) | 400 | 4 | 0 |
| `UIScreenshotTests` gallery (32 captures) | 1 | 0 | 0 |
| Swift helper `swift test` | 141 | 0 | 0 |
| Transcript/host `npm run test:host` | 143 | 0 | 0 |
| Python `scripts/tests` | 62 | 0 | 0 |

New coverage: transcript tests for turn grouping (tool-only replies follow
their activity, text starts a new group), action descriptions, activity
summaries and duration formatting; helper tests for message clocks, tool
durations, file diff statistics and the persisted model/tool split; native tests
for the sidebar usage breakdown (unreported usage reads n/a, never zero) and the
footer time split. The failure-notice fixture no longer uses the removed
"Editing tools · Trusted project" string.

Gallery review confirmed: the unread dot replaces the count in chat rows and
collapsed project headers; row stats read cost plus input/cached/output tokens
(arrow form when narrow); the Projects sheet shows no Trusted badge or trust
note and creates with "Create Project"; onboarding lists folders without a
trust warning; turn headers read "Worked for … model … · tools …" and the
footer shows "model … · tools …"; the activity line "Read 1 file" precedes
its accounting line and the final reply.

## Limits and preserved contracts

Deterministic local fixtures validate HTTP requests, response SSE, tools,
cancellation, compaction and capture. No live deployed LiteLLM, production
credential, Release performance matrix, installation or Sparkle update/relaunch
rehearsal was used. Turn model time in the transcript is derived from helper
message clocks (the gap before each non-streaming reply) and tool time from
recorded tool durations; the footer's session split comes from the helper's
own counters. Both are wall-clock observations, not provider-reported timings.

Removing the trust confirmation does not change what editing tools can do:
they still run with the user's account permissions and are not an OS
filesystem sandbox. Existing workspace records keep their `trusted` flag; new
projects are created trusted. Unread counts are still recorded internally for
read-state reconciliation and the Dock badge; only the sidebar stops showing
them. SwiftUI/AppKit composers, WKWebView/React, the supervised Swift helper,
saved history, Keychain item and the selected icon are preserved.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.20.dmg](https://belloware.com/assets/BelloAgent-0.1.20.dmg).
- Size: **7,326,425 bytes (6.99 MiB)**.
- SHA-256: `868034b838c18b2303e1e6ab88638039a1f87e175aab2f6ea262f61172bf878c`.
- App notarization: `8b03f0ba-6feb-4c72-b1cd-522f55c37a00` (accepted).
- DMG notarization: `e21630cf-9336-4100-a8f9-728b764c7197` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass. The
release validator and packaged helper/catalog smoke pass. Canonical and legacy
appcasts are byte-identical. Bundle ID `com.belloware.PiApp`, Keychain
ownership, history locations and updater signing identity remain unchanged.

`scripts/publish-release.sh 0.1.20` committed and pushed website
`4b67a23de568a6b711c80b283dc8b3acde3c75eb` ("Publish Bello Agent 0.1.20 update"). The public
appcast lagged the push for about four minutes while Cloudflare deployed;
`scripts/verify-published.py` then confirmed the live canonical and legacy feeds
match the staged release and the downloaded DMG matches its SHA-256 and Sparkle
Ed25519 signature at **2026-09-16 21:06:29 UTC**. Release evidence was complete
before this record was finalized; the later documentation commits do not change
the packaged source SHA.

Scratch evidence: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.
Files: `release-0.1.20.log` (bundle, typecheck, transcript, helper, Python,
native unit suite and gallery stages), `release-0.1.20-sign.log`,
`release.07YwN9/` (build, notarization and smoke logs), `publish-0.1.20.log`,
`public-0.1.20.log` and `releases/0.1.20/`.
Gallery captures: `/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/gallery-release/screenshots`.
Historical [0.1.19 evidence](Bello-Agent-0.1.19-2026-09-17.md) remains unchanged.
