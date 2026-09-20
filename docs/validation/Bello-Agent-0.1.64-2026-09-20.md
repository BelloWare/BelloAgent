# Bello Agent 0.1.64/build 68 acceptance — 2026-09-20

**Released and publicly verified 2026-09-20 09:50:33 UTC.** App/DMG signing,
notarization, stapling, public feeds, product page, downloaded SHA-256 and
Ed25519 signature checks passed.

## Scope

Implements the compaction plan and output-budget addendum with the owner's final
policy correction: preserve reasoning effort, use the declared model output cap
subject to actual headroom and explicit cost ceilings, no visible-length target,
and put the compaction instruction last. See the
[implementation record and CP01–CP33 dispositions](../Compaction-Implementation-2026-09-20.md).

The current native Swift engine remains. Tests use deterministic loopback
gateways and synthetic credentials. No real-key/paid request, subagents,
installation or actual updater rehearsal was used.

Environment: virtual Apple M3 Max, 10 CPUs, 16 GiB, macOS 14.8,
Xcode 16.1/Swift 6. Optimized native tests use testability; the shipped app uses
the normal Release build. Native windows run serially.

## Validation

- Baseline focused helper selection: 32 passed. The single-task regression
  failed its three target assertions before implementation, then passed.
- Final focused Debug compaction/output-budget/capacity selection: **48 passed**,
  including two request-dependent HTTP scenarios. They verify one-time tool
  effects, routed rejection, complete checkpoint replay, exact raw captures,
  source-first instruction-last layout, preserved effort and real sent caps.
- Final **260 optimized helper tests passed**, 25.508 s, including the original
  streaming CPU/retention assertions. Streamed snapshot cost was **0.701 ms per
  delta** with an approximately 2.4 KiB frame for a 251 KiB history page.
- Final **258 Debug functional helper tests passed**, 27.487 s. The two timing
  checks run in the optimized matrix above; their assertions are unchanged.
- **26 packaged-helper gateway tests passed**, 17.706 s, including exact request/
  response capture, tool round trips, streaming, cancellation and compaction.
- **62 native Release tests passed**, 14.307 s, covering context, follow-ups,
  accounting, durability, failures, twenty concurrent captured sessions and
  release configuration.
- **18 focused native Debug tests passed**, 6.089 s, with actor data-race checks
  enabled for context, follow-up progress and request observations.

The initial expanded matrix exposed a test fixture race: the gateway ready file
could exist while its JSON was still being written. Atomic temporary-file rename
fixes publication in both the new gateway and existing CrashAudit fixture. The
unchanged four crash assertions then passed in the focused rerun.

Earlier whole-suite Debug timing checks measured 1.009–1.267 ms per streamed
delta against the existing 1 ms performance bound; an earlier optimized run
during native compilation also exceeded it. The isolated optimized check passed
at 0.494 ms, and the expanded optimized run measured 0.380 ms. No timing assertion
was relaxed. Final Debug functional coverage excludes the two timing checks;
both remain required in the full optimized matrix.

## Reproduction

Use the existing external build root (do not clean caches):

```sh
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-tests" -c release
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-tests" --skip StreamingCostTests
python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
```

Native Release selection is listed in the [handoff](../Swift-Test-Handoff.md#0164-compaction-acceptance).
Run `xcodebuild test` using `ENABLE_TESTABILITY=YES`, ad-hoc test signing and
the cached `native-release` DerivedData. Focused Debug selection:
`AutomaticContextTests`, `WorkspaceFollowupTests`, `RequestContextObservationTests`,
with `OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -enable-actor-data-race-checks`.
Scratch logs/results are in the session's `tmp/compaction-064` directory.

## Limits and publication

The 20-compaction helper test checks independent state, queues and cancellation.
The native 20-session capture test is separate; `PI_REVIEW_VISUAL_LOAD` is unset.
This does not claim simultaneous native-visible compaction frame rate, exact
tokenization, real-route capacity, live cache-hit improvement or physical
power-loss validation. Fault injection establishes the journal transition rules.

Installation and actual Sparkle update/relaunch stay skipped under the owner's
policy. No installation or automatic update success is inferred from feed checks.

## Release artifacts

- Source: `b7f08f5fe812e52eef4ff3447ce66c0f3e1c080e` on `BelloWare/BelloAgent/main`.
- Website publication: `0adb68c37b16fe1a5eea2eaf755f3b6f51d150df` on
  `BelloWare/belloware.com/main`.
- Normal Release build, packaged native-helper smoke, Developer ID signatures,
  app/DMG notarization and stapling, Gatekeeper assessment and local Sparkle
  Ed25519 verification passed.
- Application notarization: `e5bfac5a-a20f-4e95-bc78-8d844967f0e1` — Accepted.
- DMG notarization: `be22c061-3d48-4bd9-b985-1ac2989325fa` — Accepted.
- `BelloAgent-0.1.64.dmg`: **8,216,889 bytes (7.84 MiB)**.
- SHA-256: `632c42730cc90b0538f92430baa7274416ef745bc6ece5bf1983ec5fb52438f9`.
- Signed artifacts and symbol files: session scratch
  `bello-agent-0.1.6/build/releases/0.1.64`; the final DMG is also in `tmp/outbox`.
- Build/notarization logs: `bello-agent-0.1.6/build/release.KAojak`.
- Public verification: **2026-09-20 09:50:33 UTC**. The downloaded DMG matches
  the local SHA-256 above and passes the Sparkle Ed25519 check. Canonical Bello
  Agent and legacy Pi App update feeds are byte-identical; the public product
  page links to this DMG.
- Cloudflare deployment check **106059060216** succeeded at
  **2026-09-20 09:50:27 UTC**.
- [Product page](https://belloware.com/bello-agent.html) ·
  [DMG](https://belloware.com/assets/BelloAgent-0.1.64.dmg).
