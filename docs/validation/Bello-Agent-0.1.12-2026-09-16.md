# Bello Agent 0.1.12 acceptance

Date: 2026-09-16. Branch: `master`. Version **0.1.12/build 16**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 11:52:59 UTC.**
Release source: `5bf9a8240df955725e05bfdcbc4b355a5d267cbf`. Website: `9154d3fa8c81520025737ac44baab0a5b021b01e`.
Feature commits: `64e5cfb` (combined response), `2a8f03d` (usage windows).

## Changed behavior

- Responses SSE captures default to a Combined JSON tree. A terminal event's
  response object is authoritative, preserving usage, gateway extensions and
  opaque content. With no terminal object, supported content, reasoning-summary,
  refusal, annotation and function-argument events form an explicitly partial
  object. Done snapshots replace deltas; identity/sequence conflicts, malformed
  frames and unsupported events stay visible. Sparse indices/text are bounded,
  and parsing is cancellable off the main actor.
- Events remains an ordered frame tree; UTF-8/hex and original-byte exports are
  unchanged. Copy in the inspector follows the chosen representation. The
  message-linked raw-copy actions are explicitly labeled as raw. Retention and
  partial-capture warnings stay independent from the combined object's status.
  The implementation references the local SDK event types and the official
  [Responses streaming guide](https://developers.openai.com/api/docs/guides/streaming-responses).
- Header and footer usage actions open the same resizable native window for
  that session. It retains scope across chat selection, refreshes after renames
  and accounting updates, and cancels reads/subscriptions on close or owner
  shutdown. Different session windows can remain open together.
- Usage now exposes input/output/reasoning/prompt-cache tokens, explicit response
  hits/misses and known hit rate with coverage, reported/reasoning USD cost,
  historical output TPS, and model/cost distributions. Missing reports remain
  unavailable; reasoning/cache components are not added twice. Archived typed
  metadata supplies the metrics without re-reading bodies or sending model calls.

## Focused acceptance

**89 native tests passed, zero failures, in 4.716 seconds.**

| Suite | Cases | Seconds |
| --- | ---: | ---: |
| CapturedBody | 14 | 0.963 |
| CombinedResponse | 21 | 0.163 |
| MenuBarMetrics | 21 | 0.865 |
| MessageDetail | 9 | 0.367 |
| SessionUsage | 10 | 1.913 |
| Workspace | 14 | 0.444 |

Coverage includes canonical and partial responses, failed/incomplete terminal
status, Unicode across 5,000 deltas, opaque fields, no delta duplication,
malformed/unfinished streams, bounds/cancellation, unchanged retained bytes and
hashes, combined/events copy selection, native tree rendering, cache denominator
semantics, reusable independent windows, live offscreen-session updates and
late-read rejection after close. The selected native suites use the existing
incremental build cache. Only two raw-copy labels changed after the passing run;
their behavior is unchanged. Five synthetic own-window JPEGs were visually
inspected: combined JSON plus light/dark, missing and zero usage states.

## Reused evidence and limits

Helper/provider, transcript and accounting storage code are unchanged. Reuse the
[0.1.11 acceptance](Bello-Agent-0.1.11-2026-09-16.md) and its linked catalog,
onboarding, title, request-aware gateway and wider historical checks; they were
not rerun or counted in the 89 cases. No production gateway credentials, deployed
LiteLLM, full gallery, full performance matrix, fresh installation, Sparkle
update/relaunch or signed owner/update rehearsal is used for this release.
Full-text capture search remains deferred. Combined JSON is a convenience view,
not new HTTP evidence or decryption of provider reasoning.

## Retained local evidence

Scratch: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/combined-usage-window`.
`native.log` records the selected run. `previews/` contains synthetic captured
JSON and session-usage windows; logs and private application state are not
published. Stable build root:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build`.

## Signing and public distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.12.dmg](https://belloware.com/assets/BelloAgent-0.1.12.dmg).
- Size: **6,989,644 bytes (6.67 MiB)**.
- SHA-256: `16e7798b04abbe7ce73647844bf9a2b3a8bb4f042b0af792680920d87903748c`.
- App notarization: `267bbd68-95fe-43e2-9ca3-30bbdc515115` (accepted).
- DMG notarization: `2ab55fcc-a272-4dbf-b5f0-34507ea9fb29` (accepted).

Developer ID signing, notarization, stapling and Gatekeeper checks pass. Packaged
smoke verifies the helper and exact catalog. Public product/download, homepage,
legacy redirect, sitemap and unchanged icon pass. Canonical and legacy feeds
are byte-identical and advertise build 16; the downloaded archive matches its
SHA-256 and Sparkle Ed25519 signature. Verified at 2026-09-16 11:52:59 UTC.
Two early feed checks still saw the preceding release during deployment.
Cloudflare build `05a47ee7-b775-4284-aafb-0a1b65f88061` completed successfully
at 11:51:58 UTC for website commit `9154d3f`; the subsequent public checks passed.
The selected icon is unchanged, SHA-256
`7d0dfb6361abd2da309b414cbbeddc6b5e39a336aa89f80bf11561f655a6779e`.
Release/publication/public checks are in `release.log`, `publish.log`,
`public.log` and `public-verification/` under the scratch folder above.
Detailed release logs: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.1SZ6qv`. No installed app was replaced as an
acceptance rehearsal. Source/documentation checks include whitespace and local
Markdown links. Public release facts refer to the packaged source commit;
the later documentation-only commit records those completed checks.
