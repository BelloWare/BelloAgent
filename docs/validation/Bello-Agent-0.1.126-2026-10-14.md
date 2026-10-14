# Bello Agent 0.1.126 — Sub-agents with two-way steering, smoother scrolling, output speed with time to first token

Status: **publicly released and verified** at [belloware.com](https://belloware.com/bello-agent.html), marketing version 0.1.126, build 130. Public verification completed at **2026-10-14 11:44:10 UTC**. Tagged source: **`91efed8e`**, `v0.1.126`. Website: **`f5ca12b`**. Previous public release: 0.1.125/build 129.

## Owner request

On 2026-10-13, after 0.1.125, the owner asked for:
- three Codex (gpt-6-astra, max) audits: at least 20 confirmed scroll-smoothness issues, plus core and UI bugs. Codex fixes them in worktrees and merges them.
- sub-agents, designed jointly with Codex and implemented by Codex, with Claude orchestrating and reviewing. Budget belongs to the parent chat. The work covers display, the request Inspector and parent/child navigation.

On 2026-10-14 the owner added:
- "update the tps logic, so it's not starting from ttft, but ttft should be counted in the duration of tps";
- parent follow-ups to finished sub-agents and parent steering of running ones. Sub-agents can also message the parent ("sub session can steer parent as well"). The owner chose to include this in 0.1.126;
- "stop new fix finding for now, just fix existing ones … release a new version ASAP".

Owner decisions:
- Sub-agents inherit the parent's tools.
- At most 16 run at once per chat; extra ones wait in order.
- Sub-agents can't start sub-agents of their own (depth 1).
- All spend counts toward the parent chat.
- There is no human composer in a sub-agent.

Decisions made while the owner was away are recorded in `NEXT-RELEASE.md` and were reported to the owner:
- UI-05: Send waits while an image is being imported.
- RL-04: request captures use a bounded drain at quit.
- SCROLL-11 was reverted.
- Steering design §14 used choices A/A: one-way `pi-app.native.v3` journal promotion, and questions as asynchronous reports only.

## Scope

- **Sub-agents** (design `docs/design/subagents.md`; validation `docs/validation/subagents-phases-1-6.md`, `subagents-phases-7-12.md`):
  - each sub-agent shows as a card with Open, Inspect Requests and Stop, and is listed under its chat in the sidebar;
  - Back to Parent;
  - a family view in the Inspector;
  - durable Stop and Resume;
  - crash recovery.
- **Two-way steering** (design `docs/design/subagents-steering.md`; validation `subagents-steering.md`, `subagents-steering-ui.md`, `subagents-steering-enabled.md`):
  - tools `subagent_start` (background or wait), `subagent_send` (steer a running sub-agent, or send a follow-up to a finished one), `subagent_wait`, `subagent_status` and `subagent_stop`, plus the sub-agent-only `subagent_report` (note, blocker or question);
  - the parent waits for its sub-agents before finishing;
  - messages are typed by author.
- **Scroll audit:** 28 of 29 confirmed items fixed or partly fixed. SCROLL-11 was reverted and SCROLL-07 skipped. SCROLL-14 cancels superseded page reads inside the helper: median 131.29 → 8.72 ms on a 4,000-row fixture (`docs/perf/scroll14-helper-cancellation.md`).
- **Core and UI audit fixes**, including:
  - Send waits for image import;
  - the Git draft and Amend prefill during a repository switch;
  - no "Working" label in the side-chat panel;
  - captures saved at quit;
  - the helper stop race (`d5c6f84e`).
- **Output speed** is N ÷ (TTFT + first→last token span) everywhere, with a 250 ms floor (`docs/validation/Output-speed-0.1.126-2026-10-14.md`).
- **Test isolation.** Tests run in a separate host app with its own defaults identity (`com.belloware.PiAppTests.Host`), with:
  - a scratch home folder and private clipboards;
  - a fail-fast guard;
  - Keychain and Sparkle turned off.

  Before this, gallery runs wrote `sidebarWidth` into the installed app's preferences.
- **Parallel-gate flakes** fixed, including the app races they exposed (`docs/validation/parallel-flakes-0.1.126-2026-10-14.md`).

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1.

- **Codex review.** Every audit branch and the sub-agents branch were reviewed read-only by Codex until clean, or until the owner stopped review rounds on 2026-10-14. The steering work and the flake fixes had no further review rounds by owner instruction. Their validation is in the records above, including failing-first tests and mutation checks.
- **Steering-enabled branch** (`f86f63b1`):
  - helper 813 tests (7 skipped), 0 failures;
  - wire 36;
  - native parallel lane 2,329 passed (35 skipped), 0 failures;
  - 21 v2 and 33 v3 crash/shutdown cases;
  - streaming, whole-family and downgrade checks;
  - 184 steering gallery images.
- **Full gate** (`verify-release.sh`) on `dev/next` `84f89a01`:
  - native serial lane 745 (32 skipped), 0 failures;
  - gallery 218 screenshots, 0 failures;
  - helper 808 (7 skipped);
  - helper streaming cost 5;
  - wire 36, concurrent 4, acceptance 3, python 79.
  - The parallel lane had 2,328 passed, 1 failed (35 skipped). `ContextReadingTests.testAChangedModelOrJournalCountsAgain` timed out once at 66.7 s under the 8-clone load. It passed alone 3 of 3 (the class takes 8.7 s). It waits on real helper launches and is listed under Known.
- **Hour soak.** Release build of `84f89a01`, seed **1790822043708**, no other builds running:
  - 3,606 s, 178 launches (sidebar median 255 ms, max 308 ms), 0 slow or missing launches, 0 row jumps.
  - **0 stalls over 250 ms** (0.1.125: 0).
  - Main-thread answers over 100/150/200 ms: 7/0/0, longest 125 ms (0.1.125: 4/0/0, longest 125 ms).
  - Footprint 96 → 844 MB, 4.23 MB per launch (0.1.125: 3.65). The soak keeps every closed window alive inside XCTest (178 of 178), so this measures retained per-window state, not app behavior; see Known.
  - The 60 s draw soak passed: 0 stalls, 4/0/0, longest 141 ms.
- **Known:**
  - Per-launch soak footprint grew 0.58 MB (+16%) over 0.1.125. It comes from per-window state retained by the XCTest harness, and sub-agent and steering state was added in this release. Not investigated further, under the owner's ASAP instruction.
  - `ContextReadingTests.testAChangedModelOrJournalCountsAgain` fails under heavy parallel load (see above). The historical webhook test timeout's root cause is unconfirmed.
  - Steering contract gaps:
    - the helper has no turn or message detail paging;
    - consuming links point at the first retained request;
    - large-family scan performance is unmeasured.
  - SCROLL-11 (one-time measuring of an expanded long diff before first paint) is not fixed. SCROLL-07 was skipped.
- **Not done:** VoiceOver and real-gateway checks; install/update rehearsals skipped under standing policy.

## Publication

Packaged from **`91efed8e`** with `scripts/release.sh`. That commit is `main` merged with `dev/next` at `84f89a01`, plus the version bump, the release notes and this record's first draft. The script:
- made a Release build, stripped the binaries and kept the dSYMs;
- signed with Developer ID and ran the packaged-helper offline smoke test;
- notarized and stapled the app and the DMG, then checked them with Gatekeeper;
- signed the appcast and verified its Ed25519 signature.

`validate-release.py` against build 129 passed. The owner approved publishing 0.1.126 once it was gated and soaked.

- App notarization: **`9b796b5e-95ec-49e1-a598-5b291234f3ee`**, Accepted.
- DMG notarization: **`b519b0f9-38e5-4cf3-8efd-4291b21d97a6`**, Accepted.
- Installer: **14,366,530 bytes (13.70 MiB)**.
- SHA-256: **`2d769bc6df09a3ed6339339220d68559abeaab201bca1cfd0c1e55ab281ce315`**.

Source was pushed atomically to `main` and `dev/next` at `91efed8e`, with tag `v0.1.126`. `publish-release.sh 0.1.126` pushed website `f5ca12b`.

`verify-published.py` passed at 2026-10-14 11:44:10 UTC:
- the canonical and legacy feeds are identical;
- the public DMG's SHA-256 matches;
- the Ed25519 signature verifies.

Install and update rehearsals were skipped by standing owner instruction.
