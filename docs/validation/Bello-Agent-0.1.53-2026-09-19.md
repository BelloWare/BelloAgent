# Bello Agent 0.1.53/build 57 — 2026-09-19

**Public release verified at 2026-09-18 21:30:15 UTC.**
Release source: `feb9df30c02c21e38ccb95d378ac619688062e49` (local `main` commit under the owner's
source-push policy). Website: `5d43a239e2fdc8665e5782976ba8e3ec7c9cd352`. Later documentation commits
do not change the packaged source.

This release adds Bello-styled selection panels and addresses transcript layout
and accounting work that made active conversations feel slow. The system tab
strip is disabled for app windows. The custom navigation and header remain in
control of the window layout.

## Distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.53.dmg](https://belloware.com/assets/BelloAgent-0.1.53.dmg).
- Size: **7,329,401 bytes (6.99 MiB)**.
- SHA-256: `6354391322a03c8bc408b8db57e2edddc0fa1eb15cdece0f68c29edd30ae9c24`.
- App notarization: `d41b2fef-a2a2-4262-86d3-784e9d94e310` (accepted).
- DMG notarization: `1fb7fc51-2cc8-4e55-bc61-cfc810ef7e7d` (accepted).

Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper,
packaged helper/catalog smoke, version/build validation and local Sparkle
Ed25519 checks pass. Source `feb9df30c02c21e38ccb95d378ac619688062e49` remains local under the
owner's source-push policy. Website publication commit `5d43a239e2fdc8665e5782976ba8e3ec7c9cd352`
was pushed; Cloudflare check **105767983479** succeeded.
Public verification at **2026-09-18 21:30:15 UTC** confirms identical canonical/legacy
feed bytes, the downloaded DMG SHA-256 and Sparkle signature, and the product
page's 0.1.53 download link. Fresh-install and Sparkle update/relaunch
rehearsals remain skipped under the standing owner policy.

Distribution logs: `release.log`, `publish.log`, `public-verification.log` and
`public-verification.json`. Signing/notarization work: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.F9M3OY`.
Immutable artifacts, signed app and retained app/helper dSYMs: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/releases/0.1.53`.

## Evidence

**191 distinct native tests pass; four interactive-desktop tests are explicitly
skipped.** `native-acceptance.json` records each final case and its source log;
repeated passes are counted once.

- Integration acceptance: **134 native tests passed, zero failures** in 19.726 s.
  Coverage includes model/catalog selection, settings persistence, transcript
  safety/Markdown, report rendering, read state, motion, timing, accounting,
  loading and concurrent sessions.
- The actual native-model/helper/gateway fixture sent **20 concurrent sessions**,
  observed 20 simultaneous HTTP requests and 20 tool round trips, and retained
  80 exact request/response bodies. Its MainActor heartbeat maximum gap was
  9.14 ms; this measures scheduler responsiveness, not display frame rate.
- Archive, accounting, window and native scroll checks passed in the focused
  candidate run. The final selector run passes seven cases, including saved-choice
  Return, arrow navigation, disabled choices, cancel/commit, dynamic lists and
  light/dark rendering. Two selector and two transcript pointer/popover cases
  remain gated for an interactive desktop. The remote session cannot activate
  an ordinary SwiftUI Button with pointer input; pointer and VoiceOver behavior
  are not claimed as verified.
- Comparable rendering fixtures: 61 rich rows open in **881.6 ms** versus
  1,409.6 ms, with per-update layout/display **102.3 ms** versus 699.7 ms.
  The 300-row stress fixture opens in **4,359.7 ms** versus 6,968.2 ms, with
  per-update layout/display **208.7 ms** versus 2,525.9 ms. Each stream has
  37 updates to an 11 KB answer. These are comparable single runs, not a
  universal frame-rate guarantee.

Primary logs: `integration-acceptance.log`, `transcript-baseline.log`,
`choice-and-transcript-final-retry.log`, `choice-and-transcript-accepted.log`
and `choices-final.log`, with corresponding xcresult bundles. Earlier mixed
runs preserve native input-harness failures and the initial keyboard-focus bug
alongside successful rendering, cache, archive and window evidence. Those mixed
runs are not represented as entirely passing suites. The final selector run
verifies the focus correction; unchanged passing suites are reused.

See [the responsiveness review](../Responsiveness-Review-2026-09-19.md) for the
findings, measurement method and boundaries. Helper/provider/worker source is
unchanged from the verified 0.1.52 release; its deterministic gateway and
20-session concurrent-worker checks are reused. Installation and actual Sparkle
update rehearsals are skipped under the standing owner policy.

Scratch evidence:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/perf-053-20260919`.
