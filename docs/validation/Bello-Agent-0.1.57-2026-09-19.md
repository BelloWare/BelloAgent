# Bello Agent 0.1.57/build 61 acceptance — 2026-09-19

**Public release verified at 2026-09-19 01:00:09 UTC.**
Release source: `dbbf3421a7143e606768659be8e688ba64d8ac59` (local `main` commit under the owner's
source-push policy). Website: `eaaa9f647ff410dacc4126d3e370ea7249357264`. Later documentation commits
do not change the packaged source.

## Changes

Read the [five-session performance review](../Five-Session-Performance-Review-2026-09-19.md)
for the measured causes, comparison fixtures and remaining limits. This release
isolates per-chat accounting notifications, skips hidden transcript construction
and unchanged native reconciliation, and reuses verified geometry for immutable
history rows. The bounded row cache retains values and preserves selection;
long Markdown keeps its existing per-view measurements and viewport mounting.
An experimental shared Markdown-block cache was removed after repeated scrolling
measurements regressed. Late replies cannot replace a newer helper interruption state,
and saved partial replies cannot duplicate their former streaming placeholders.

## Validation

The final shipping-source selection passed **23/23 tests**: five-session
workspace behavior, native Markdown append/selection/width handling, both long
scrolling fixtures and workspace regressions. Across the successful targeted
runs, deduplication gives **118 unique native passes and two interactive skips**.
Four removed experimental Markdown-cache tests and failed/interrupted runs are
excluded. Per-test attribution is in `final-native-summary.json`.

The five-session fixture measured zero whole-workspace notifications from
background status, content or billing. Background content/billing layout work
fell from 12.51 ms to 7.24 ms mean. Returning to the initially mounted tab took
629.11 ms to readiness plus 68.76 ms deferred settlement, 697.88 ms combined;
the original readiness-only baseline was 1,421.23 ms. Draft, selection, exact
geometry and a single mounted conversation were preserved.

Rich foreground updates still averaged 54.46 ms with 85.52 ms p95 and 124.57 ms
maximum. The separate 32-byte update fixture averaged 23.04 ms with 56.56 ms
p95. Long-answer scrolling returned close to its pre-experiment cost after the
experimental cache was removed: 15.39 ms total mean and 7.26 ms synchronous
mean for 88 KB. These checks establish the reported improvements and remaining
spikes, not uniformly smooth physical scrolling or instantaneous cold loading.

The helper selection passed 41 tests, including seven new projection/cancellation
regressions. All three request-aware real-helper gateway scenarios passed, with
20 overlapping requests in each tool scenario, 20 tool round trips, 660 text
events and 80 exact captured bodies. Mixed cancellation, error and follow-up
isolation also passed. Fixtures use synthetic keys and loopback gateways.

The combined relevant selections contain **162 distinct passing tests**, plus
the two skipped native interactive checks; repeated tests are counted once.

Native timing measures actual layout/display work and main-queue scheduling,
not physical trackpad or display frame rates. Interactive pointer and VoiceOver
checks remain unverified on the inactive desktop. Fresh-install and actual
Sparkle update/relaunch rehearsals remain skipped by owner instruction.

## Distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.57.dmg](https://belloware.com/assets/BelloAgent-0.1.57.dmg).
- Size: **7,538,829 bytes (7.19 MiB)**.
- SHA-256: `f82811cec97b217385e2d58b9fb6a1ac62b3a6a8c8fa725e937a08afe00b5f3b`.
- App notarization: `51eac5ab-f082-49e6-bd44-0943b4ac611c` (accepted).
- DMG notarization: `b715e6e7-0ebf-407d-b964-9955c4058b6a` (accepted).

Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper,
packaged helper/catalog smoke, version/build validation and local Sparkle
Ed25519 checks pass. Source `dbbf3421a7143e606768659be8e688ba64d8ac59` remains local under the
owner's source-push policy. Website publication commit `eaaa9f647ff410dacc4126d3e370ea7249357264`
was pushed; Cloudflare check **105810946636** succeeded.
Public verification at **2026-09-19 01:00:09 UTC** confirms identical canonical/legacy
feed bytes, the downloaded DMG SHA-256 and Sparkle signature, and the product
page's 0.1.57 download link. Fresh-install and Sparkle update/relaunch
rehearsals remain skipped under the standing owner policy.

Distribution logs: `release.log`, `publish.log`, `public-verification.log` and
`public-verification.json`. Signing/notarization work: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/release.HsVMLY`.
Immutable artifacts, signed app and retained app/helper dSYMs: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build/releases/0.1.57`.

## Evidence

Scratch: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/perf-057-20260919`.

- Original native baseline: `five-session-baseline.log` and result bundle.
- Helper comparison: `host-status-before.json`, `host-status-after.json`.
- Sampling attribution only: `profile-notes.md`, `rich-tail.sample.txt`,
  `warm-switch.sample.txt`; sampling replay timings are not comparison evidence.
- Helper regression and concurrency: `helper-focused.log`, `helper-concurrent.log`.
- Native validation: `native-after-actor.log` (87 executed),
  `native-markdown-corrected.log` (84 executed) and their result bundles;
  `native-shipping-final.log` and `native-shipping-final.xcresult` (23/23 passed).
- Final metrics, deduplicated current-test IDs and exclusions:
  `final-native-summary.json`.
- Rejected experiment: `markdown-cache-crash-notes.md` and
  `long-scroll-profile-notes.md`; this shared Markdown-block cache is not shipped.
