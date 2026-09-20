# Bello Agent 0.1.51 acceptance

Date: 2026-09-19 (Asia/Singapore). Branch: `main` in `BelloWare/BelloAgent`.
Version **0.1.51/build 55**. Environment: macOS 14.8 arm64,
Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.

**Public release verified at 2026-09-18 19:40:46 UTC.**
Release source: `1eb8f9ea3b801aa50d380b5ae9627f337aa45189` (local `main` commit under the owner's source-push
policy). Website: `fdcde0b40f8cc99d50bcc5ad2de74911912e33de`. Later documentation commits do not change
the packaged source.

## Changes and acceptance

Twenty-session concurrency now has explicit regression coverage. Fixes address
capture producer pressure, native archive writer capacity, active memory bounds,
command admission/cancellation/timeouts, UI inbox bursts, shared startup races
and background accounting work. See the
[concurrency review](../Concurrency-Review-2026-09-19.md) for before/after evidence
and boundaries, including serialized project tools and remote gateway limits.

- Helper Debug suite: **176 passed, zero failures**.
- Packaged Release helper: **3 concurrent-session scenarios passed**. Twenty
  simultaneous HTTP requests were required in one project and across four
  projects, with twenty real file-tool round trips, 660 streamed text deltas and
  eighty exact request/response bodies in each of the two tool-completion scenarios.
- The mixed case confirms actual HTTP cancellation while nineteen other streams
  remain open, failure isolation, exact partial/error captures and a session-local
  queued follow-up. Its strengthened assertion rerun passed; repeated cases are
  not counted twice.
- Existing packaged HTTP/SSE/MCP integration: **24 passed**.
- Process crash/restart acceptance: **2 passed**.
- Native Release checks: **137 distinct cases passed, zero unresolved failures**.
  The 136-case run passed 135 cases; one new accounting fixture omitted the
  timing-v2 dispatch metadata required for an observable request. Correcting the
  fixture preserved its expectations. The final seven-case run passed, including
  that case and one additional full native 20-session integration.
- The full native path calls `WorkspaceModel.send` twenty times from cold state,
  reaches two 20-request HTTP barriers, completes twenty file-tool round trips
  and 660 text deltas, then reopens native storage and verifies all eighty bodies.
  Automatic background accounting reports two requests, 220 gateway tokens and
  $0.002 for every session without manual refresh. Observed elapsed time was
  2.274 s; the 5 ms MainActor heartbeat's maximum observed gap was 8.43 ms.
  This is a local fixture observation, not a rendering or provider speed claim.

Unchanged rendering and release-tool evidence is reused from 0.1.50/0.1.49;
this does not claim a fresh full-gallery or universal frame-rate pass. All
gateway traffic uses deterministic local fixtures and synthetic credentials.
Fresh-install and actual Sparkle update/relaunch rehearsals remain skipped
under the owner's standing instruction.

## Distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.51.dmg](https://belloware.com/assets/BelloAgent-0.1.51.dmg).
- Size: **7,254,854 bytes (6.92 MiB)**.
- SHA-256: `4674b23636b513802ebbca323bed9e02794f129936f2b851528fc95c30fa3e40`.
- App notarization: `b592ea0d-7281-442c-99d9-d584a938cc6e` (accepted).
- DMG notarization: `17a6571c-5255-4eac-b01b-08d97000014f` (accepted).

Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper,
packaged helper/catalog smoke, version/build validation and local Sparkle
Ed25519 checks pass. Clipboard-style signing and ordinary Keychain storage,
bundle identity, history paths and the chosen icon are unchanged. Source commits
remain local under the owner's source-push policy. The website publication
commit was pushed; Cloudflare check 105736674105 succeeded.
Public verification confirms exact canonical/legacy feed bytes, the downloaded
DMG hash and its Sparkle signature. The product page links to 0.1.51, and the
same signed installer was copied to the session outbox.

Distribution logs: `release.log`, `publish.log`, `public-verification.log` and
`public-verification.json`. Signing/notarization work: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.s3leLu`. Immutable
artifacts, the signed app and retained app/helper dSYMs: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/releases/0.1.51`.

## Evidence

Scratch root:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/concurrency-051-20260919`.
Helper logs:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/review-concurrency-0.1.51/helper`.

The first native attempt stopped at a Swift 6 compile error in the new
test task-group closure, before executing tests (`native-final.log`).
`native-corrected.log` records the 136-case run and incomplete synthetic metadata
fixture. Adding the full integration exposed another test-only Swift 6 mutable
capture compile error (`native-concurrency-final.log`). The final corrected
seven-case run, `native-concurrency-verified.log` and its result bundle, passes.
No production change was needed for either fixture/compiler correction.
