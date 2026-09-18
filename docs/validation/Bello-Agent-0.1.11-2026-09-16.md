# Bello Agent 0.1.11 acceptance

Date: 2026-09-16. Branch: `master`. Version **0.1.11/build 15**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 10:44:00 UTC.**
Release source: `bca8f816a9fe5959ad1d2a08e6ed077495c8ff2e`. Website: `0264f7a5b331d2655bd6bde478178fe1ab145a17`.

## Changed behavior

- Reply footers show one response-body model, preferring `router_model_name`
  over `model`. Clicking opens literal body/header reports with their sources.
  Older metadata can retain a verified gateway name. Strict identity conflicts,
  replay rules, requested aliases and monetary/token accounting are unchanged.
- Projection version 6 backfills the nullable body-model display column from
  existing bounded metadata, preserving same-owner message attribution. It
  survives body expiry and is removed with metric retention.
- Both capture inspectors show JSON and streamed SSE as expandable native
  trees. SSE retains frame order, fields, non-JSON data, sentinels and unfinished
  tails. Original bytes, hashes, UTF-8/hex views, exports and retention labels
  stay unchanged. Root/frame selection uses explicit safe formatting.
- Session opening now publishes the helper's existing context estimate.
  Calculated previews update the footer with the same count used by inspection.
  Draft/model/configuration/activity changes, helper reopening and a five-minute
  age check reject obsolete estimates. Before calculation, the action says
  “Inspect context”. Reading the footer does not start a helper or model call.
  Idle prepared previews include the draft; running previews exclude unsent and
  queued turns. These remain estimates, distinct from captured wire requests.

Feature commits: `35fb73a` (model display), `58fee52` (response tree),
`5e2deca` (context meter). The bundled catalog and selected icon are unchanged.

## Focused acceptance

**103 unique native cases pass after a focused fixture correction and rerun.**

| Native suite | Cases | Final suite seconds |
| --- | ---: | ---: |
| AccountingScale | 1 | 3.654 |
| CapturedBody | 13 | 1.012 |
| ContextAndSkillPolicy | 8 | 0.236 |
| Dashboard | 14 | 1.200 |
| GatewayAccounting | 19 | 0.717 |
| LiveAccounting | 5 | 0.665 |
| MenuBarMetrics | 21 | 0.951 |
| MessageDetail | 9 | 0.264 |
| PayloadArchive | 13 | 1.186 |

The initial 103-case run (9.730 seconds) had two optional screenshot failures:
the copy-text binding became ready before SwiftUI attached its NSOutlineView.
The fixtures now wait for the populated, laid-out outline in their own window.
The final CapturedBody/ContextAndSkillPolicy run passes all 21 cases in 1.248
seconds; repeated cases are not added to the unique total. Context additionally
checks a helper reopening invalidates the prior sequence epoch. Two synthetic
own-window JPEGs were visually inspected: formatted JSON request and streamed
response with nested usage and model fields. No unrelated app content is captured.

The unchanged-size 100,000-attempt / 300,100-link Debug accounting fixture
preserves ownership and coverage: a 101-message page took **605.350 ms**,
session-only **68.847 ms**, and a single-message query **65.396 ms**. These are
local database timings, not the full Release input-to-paint budget.

Helper ContextPreview: **4 passed**, 0.085 seconds. Native context coverage also
uses the actual packaged helper without sending a model request, preserving
the unsent draft, zero queue/messages and empty capture history. Transcript:
**25 passed**, approximately 0.71 seconds; TypeScript passes. Coverage includes
the one-model click action, unknown/legacy identities, bounded bridge data,
nonduplicated costs, SSE framing/selection, exact bytes, cancellation and expiry.
Logs are in session scratch `reply-context-fix/` (`native.log`,
`native-viewer-final.log`, `helper-context.log`, `staging.log`).

## Reused evidence and limits

Unchanged catalog/onboarding/title behavior reuses the
[0.1.10 record](Bello-Agent-0.1.10-2026-09-16.md). Broader provider/tool/wire,
window, Keychain and historical acceptance remains in the
[0.1.9 record](Bello-Agent-0.1.9-2026-09-16.md) and linked earlier records.
No production gateway credentials, deployed LiteLLM, full gallery, full Release
performance matrix, fresh installation, Sparkle update/relaunch or signed
owner/update rehearsal was used for these focused checks. Physical status-item
clicks, chart dragging, foreground unread clearing through CUA and real-language
IME remain outside this acceptance scope. HTTP-body full-text search stays
deferred. Signing/notarization and public artifact verification remain required.

## Signing and public distribution

- Source: `bca8f816a9fe5959ad1d2a08e6ed077495c8ff2e`.
- Website: `0264f7a5b331d2655bd6bde478178fe1ab145a17`.
- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.11.dmg](https://belloware.com/assets/BelloAgent-0.1.11.dmg).
- Size: **6,937,176 bytes (6.62 MiB)**.
- SHA-256: `e1058f581bb1ac809fd217ffbe64c3a888c601ef5a0e0739470d84adce907e4b`.
- App notarization: `246852e5-1767-4630-9a2b-89c5cf86e727` (accepted).
- DMG notarization: `6bf1f4b7-8132-4b68-b170-a19af2b8e711` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass. Packaged
smoke verifies the helper and exact bundled catalog. Public product/download,
homepage, legacy redirect, sitemap and unchanged icon pass. Both update feeds
are byte-identical and advertise build 15; the downloaded archive matches its
SHA-256 and Sparkle Ed25519 signature. Verification completed at 2026-09-16 10:44:00 UTC.
The first three feed checks still saw the previous release during deployment.
Cloudflare Workers build `efc7235b-3b3c-4631-86bf-300e9d0a3278` completed
successfully at 10:42:43 UTC for the website commit above; the next public check
passed. Deployment wait is separate from the completed local test/build work.
The selected icon is unchanged, SHA-256
`7d0dfb6361abd2da309b414cbbeddc6b5e39a336aa89f80bf11561f655a6779e`.

## Retained local evidence

Scratch: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/reply-context-fix`. Release/publication/public download logs are
`release.log`, `publish.log`, `public.log`, with page checks under
`public-verification/`. The native viewer images are `previews/captured-request-json.jpg`
and `previews/captured-response-sse.jpg`. Raw logs and private application state
are not published.

Stable build root: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build`.
Its folder name identifies reused caches, not the app version. Artifacts are
under `releases/0.1.11`; detailed release logs: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.0fj9Zl`.
Source/documentation checks include `git diff --check` and local Markdown links.
No installed app was replaced as an acceptance rehearsal.
