# Bello Agent 0.1.118 — deep-review fixes and smoother chat switching

Status: **publicly released and verified** at [belloware.com](https://belloware.com/bello-agent.html), marketing version 0.1.118, build 122. Public verification completed at **2026-10-02 02:30:36 UTC**. Tagged source: **`3bd15d2`**, `v0.1.118`. Website: **`6eddd03`**. Previous public release: 0.1.117/build 121. The owner approved publication on 2026-10-02 after the gate, acceptance tests and hour-long soak passed, and deferred the manual VoiceOver and real-gateway checks again; neither is claimed to have run.

## Scope

All ten findings of the [0.1.117 deep review](../reviews/BelloAgent-0.1.117-deep-review.md), the soak pauses, the last SwiftUI publish-during-update warning and the helper's history-loading loose ends. The planned refactors were moved out of this release by the owner and are not included.

- Git operations take selected paths literally (`:(literal)` pathspecs).
- A chat's connection switch is serialized with its opens; its journal moves to the new binding (`pi-app.native.rebind.v1`) before the switch commits, and a failed move leaves the old connection working.
- A switch that would leave provider-only reasoning behind asks first ("Earlier reasoning from A can't be sent to B. Switch anyway?"); on confirm those replies replay portably. Owner-approved behaviour.
- A queued message being delivered stays saved until its user record is written, and comes back paused after a crash.
- A pending side's whole draft (text, images, skills) is kept on close, replace, quit and update.
- Nested fence identities, linear terminal Markdown matching, bounded syntax-state reads, empty MCP SSE priming events, batched capture garbage collection.
- Soak pauses: transcript text is drawn on the main thread (`NSViewCanUseGPUAcceleration` registered off; an undocumented AppKit default), and a chat switch shows the stat pills' figures at once instead of rolling them from the previous chat. The latter is an owner-approved visible change.
- Compatibility: a chat moved to another connection can't be opened by 0.1.117 or earlier.

Release notes: `releases/0.1.118.html`.

## Validation

Toolchain: macOS 14.8 (a VM) on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1.

- Wire scripts on a fresh Release helper before the gate: 34, 4 and 2 passed.
- Full gate `scripts/verify-release.sh` at `215b971`, run alone, **all checks passed in 21 min 1 s**. Native serial: **330 executed, 18 skipped, 0 failures**. Native parallel: **1,664 passed, 18 skipped, 0 failures**. Isolated StreamingCostTests: **5 passed**. Helper: **593 executed, 6 skipped, 0 failures**. Views package: **118 executed, 3 skipped, 0 failures**. Wire 34, concurrent wire 4, acceptance 2, Python 72. Gallery: **172 images**.
- Review acceptance tests, all passing in the gate: GitLiteralPathTests 8 (1), WorkspaceConcurrencyTests 8 (2), QueueEditingTests 10 (3), SideTests 15 (4), ConnectionSwitchJournalTests 6 and helper ConnectionSwitchTests 9 (5), CaptureGarbageCollectionTests 2 (6), NestedFenceIdentityTests 3 (7), FileSyntaxTests 9 (8), TerminalMarkdownMatchingTests 3 (9), MCPRecoveryTests 6 (10).
- One-hour Release soak at `215b971`, seed **1790903251581**, load 2.8 → 2.1, no other builds: **passed**. 3,601 s, 183 launches, **0 stalls over 250 ms**, 0 row jumps, 0 slow launches. Main-thread answers over 100/150/200 ms: 386/4/2; longest **245 ms**, a thin margin. Footprint grew 4.86 MB per launch with 183 windows alive, the test runner's documented window retention; not investigated further.
- Workstream soaks before the merge (same fixes): seeds 1790822043708 and 1790882027431 each passed an hour with 0 stalls (longest 222 and 213 ms); 0.1.117 had 6 pauses on the first seed.
- Every change was planned and reviewed with Codex (gpt-6.1-sol, xhigh, read-only) until it reported no findings; new tests were mutation-checked.
- Not run: the owner's VoiceOver minute and real-gateway compaction (deferred by the owner); install/update rehearsals (standing owner policy).

## Publication

Packaged from **`3bd15d2`** (the release commit; its `apps/` and `packages/` trees equal the gated `215b971`) with `scripts/release.sh` on 2026-10-02: Release build, stripped binaries with retained dSYMs, Developer ID signing, packaged-helper offline smoke, app and DMG notarization and stapling, Gatekeeper validation, signed appcast and Ed25519 verification.

- App notarization: **`38e10963-c282-437a-b2bb-36ccc05a0467`**, Accepted.
- DMG notarization: **`492b446e-be5c-4257-8323-5f2fab0bd751`**, Accepted.
- Installer: **12,357,208 bytes (11.78 MiB)**, below the 20 MiB target.
- SHA-256: **`4174aee9376ee62730ab41ef16a79450e3f12a35a25ea69c8d5ea6d184e43e1e`**.
- `validate-release.py --previous-build 121` passed; both local feeds byte-identical.

The owner's approval was given in the integrating session; the release agent's attempt was blocked by the permission check, so the integrator ran packaging and publication. Source was fast-forwarded and pushed atomically to `main` and `dev/next` at `3bd15d2`. `publish-release.sh 0.1.118` committed and pushed website `6eddd03`. `verify-published.py` passed at 2026-10-02 02:30:36 UTC, about 3 minutes after the push: identical canonical and legacy feeds, public DMG SHA-256 match and Ed25519 signature. Install and update rehearsals were skipped under the standing owner policy.
