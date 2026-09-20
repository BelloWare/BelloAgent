# Bello Agent 0.1.52 acceptance

Date: 2026-09-19 (Asia/Singapore). Branch: `main` in `BelloWare/BelloAgent`.
Version **0.1.52/build 56**. Environment: macOS 14.8 arm64,
Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.

**Public release verified at 2026-09-18 20:13:40 UTC.**
Release source: `78e7b8f80a89e497978d915908f97b080a751512` (local `main` commit under the owner's source-push
policy). Website: `f188c0db312da614df13b97a6f113b899b87932a`. Later documentation commits do not change
the packaged source.

## Changes and acceptance

TPS now uses completed gateway-reported output divided by independently
measured request duration, including hidden reasoning once. Byte-derived live
rate telemetry and its sidebar timer are removed. Native history migration
retains rates when no visible-content timestamp exists, preserves missing
observations and clears duration on metric expiry. The latest rate stays stable
while another response runs, with a local fade and bounded sidebar layout.

Read/list/find/grep run on a helper-wide pool of four real worker threads with
64 FIFO waiters and explicit cancellation. Project editing coordination remains.
See the [throughput/worker review](../TPS-Workers-Review-2026-09-19.md) for details
and limits.

- Helper Debug suite: **188 passed, zero failures**, 25.319 s.
- Blocking barrier: **four distinct simultaneously occupied OS threads**,
  twenty jobs, four maximum active jobs and sixteen waiting. Tests also cover
  FIFO bounds, overload, permissions, cancellation and existing editing gates.
- Packaged Release helper concurrency: **3 passed**, 35.727 s. Both one-project
  and four-project cases reach two barriers with twenty simultaneous HTTP
  requests, twenty tool round trips, 660 text deltas and eighty exact captured
  bodies. Every completed attempt satisfies reported-output/request-duration
  TPS; failed/cancelled attempts expose no rate and activity contains no byte
  estimate. Cancellation closes one actual HTTP connection while nineteen
  other streams remain open; queued work and failures stay session-local.
- Existing packaged HTTP/SSE/MCP integration: **24 passed**, 9.230 s.
- Process crash/restart acceptance: **2 passed**, 2.580 s.
- Native Release main batch: **139 passed, 2 opt-in skips, zero failures**,
  14.133 s. It covers timing/history, migration, expiry, accounting, charts,
  sidebar presentation, startup concurrency, native capture and release settings.
- Full native `WorkspaceModel.send` integration reaches twenty simultaneous HTTP
  requests, completes twenty file-tool rounds and 660 text deltas, and reopens
  storage to verify eighty exact bodies. Background accounting refreshes all
  twenty chats automatically. Elapsed time: 2.288 s. A MainActor heartbeat
  sampled 347 times with an observed maximum gap of 8.02 ms. This is a local
  fixture observation, not a screen frame-rate or provider-speed guarantee.

The final focused native run passes **22 cases**, 9.964 s, covering session
organization and timing after adding the narrow-layout fallback. It includes
one additional regression, for **140 distinct native passes and two opt-in
skips** across the two batches. Twelve actual sidebar renderings at 226, 126
and 112 points of available content width preserve complete rate/cost/status
text; geometry and OCR assertions pass. Narrow and ordinary rows, the 420-point
footer and the timing history chart were visually inspected. Repeated cases are
not counted twice.

Unchanged broader rendering and release-tool checks are reused from 0.1.50 and
0.1.49. The two skipped tests are opt-in menu/session-usage screenshot previews.
Gateway fixtures use synthetic loopback services and credentials; no deployed
LiteLLM throughput or rate-limit claim is made. Fresh-install and actual Sparkle
update/relaunch rehearsals remain skipped under the owner's instruction.

## Distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.52.dmg](https://belloware.com/assets/BelloAgent-0.1.52.dmg).
- Size: **7,269,703 bytes (6.93 MiB)**.
- SHA-256: `39037ef81f15ef1c3c28be59c1c142b258f5b967372df03ceec71cb534887c4a`.
- App notarization: `49607b8d-d688-4207-ac9c-844d4a0059ee` (accepted).
- DMG notarization: `9c6c92f8-4dc1-4c0e-8677-2a5877693c41` (accepted).

Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper,
packaged helper/catalog smoke, version/build validation and local Sparkle
Ed25519 checks pass. Clipboard-style signing and ordinary Keychain storage,
bundle identity, history paths and the chosen icon are unchanged. Source commits
remain local under the owner's source-push policy. The website publication
commit was pushed; Cloudflare check 105746457498 succeeded.
Public verification confirms exact canonical/legacy feed bytes, the downloaded
DMG hash and its Sparkle signature. The product page links to 0.1.52, and the
same signed installer was copied to the session outbox.

Distribution logs: `release.log`, `publish.log`, `public-verification.log` and
`public-verification.json`. Signing/notarization work: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.r0DnJo`. Immutable
artifacts, the signed app and retained app/helper dSYMs: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/releases/0.1.52`.

## Evidence

Scratch root:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/tps-052-20260919`.

`helper-debug.log`, `helper-release-build.log`, `concurrent-wire.log`,
`native-wire.log`, `process-acceptance.log`, `native-rates-verified.log` and its
native result bundle record the completed checks above. `native-layout-final.log`
and its result bundle record the final 22-case run; `timing-previews/` holds
synthetic native renders, and `test-summary.json` records distinct case counts.

The first native build, `native-rates-workers.log`, stopped before executing
tests because a new geometry fixture tried to assign SwiftUI's read-only Reduce
Motion environment value. The fixture now uses the existing supported layout
override; the corrected batch passes. No production change was required for
that compiler correction.
