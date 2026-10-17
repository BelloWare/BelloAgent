# Bello Agent 0.1.129 — the cost limit pauses at once, family delete, outside review fixes

Status: **released and verified 2026-10-18.** Marketing version 0.1.129, build 133. Previous public release: 0.1.128/build 132.

## Owner request

On 2026-10-16 the owner reviewed the decisions made for 0.1.128 and answered ten more questions. They then approved the release: "I think you can feel free to release the new version once you have finished the thing." On 2026-10-17 they asked to "release new version ASAP".

- **Cost limit.** The owner's final rule: "just cut off model reply so you can resume cleanly. Let's do that for even like chat with subagent and chat without subagent."
  - At the limit, every in-flight model request, compaction included, is cut. Running tools finish with their real results, and nothing new starts.
  - Tool calls the pause held run first on Resume.
  - The pause survives relaunch. Raising the limit resumes nothing; Resume is explicit.
- **Sides.** Sides cannot start or message sub-agents: "do not allow side to start their own, also I thought my side are read only?"
- **Deleting.**
  - Deleting a main chat deletes its whole family, and the confirmation lists the sides.
  - A chat whose project is missing can be deleted, with the skipped steps listed.
  - A side in an untrusted project can be deleted, and the skipped step is named.
  - Sides get a "Delete Side" button.
- **Intermittent tests.** "Block until explained."
- **Outside review.** For the external review (11 bugs at `9d4123f6`), the owner said: "if you agree it's a bug, go ahead and fix it in current release". All 11 were confirmed and fixed.
- **Process.** From 2026-10-16, Claude and Claude sub-agents write the code, and Codex (gpt-6-astra, max effort, read-only) reviews it.
- **Shipping decision.** After Codex review round 11 of the cost-limit pause, the owner chose to "Ship after these fixes". Round 12's findings are recorded for 0.1.130.

## Scope

Each workstream's record is under `docs/validation/`. Each was reviewed by Codex until clean, except the cost-limit pause (see Known):

- **Cost-limit pause** (`limit-pause-0.1.129.md`, merge `262cfe7a`):
  - 12 Codex rounds, each finding fixed with a test that fails first and a mutation check;
  - full gates verify-1 to verify-8 on the branch;
  - native checks for rounds 8–11 with six app-side mutations.
- **Family delete** (`family-delete-0.1.129.md`, merge `1b4743d5`):
  - 3 Codex rounds;
  - also fixed a race where a live sub-agent list restored `running` after the helper was lost.
- **Git review fixes** (`bugs-git-0.1.129.md`, merge `e8ab5f11`): BUG-001, 006, 007 and 008; 2 Codex rounds.
- **Core review fixes** (`bugs-core-0.1.129.md`, merge `1f1a319d`): BUG-002, 003, 004, 005, 009, 010 and 011; 3 Codex rounds.
- **Intermittent tests** (`flakes-0.1.129.md`, `flake-inspector-0.1.129.md`):
  - ten failures were given causes and fixes, plus the Inspector raw-search failure;
  - the Settings 1 pt failure was traced to the frozen SwiftUI 0.1.119 oracle (±1 pt). The product page measured 783 pt in 170+ runs. A disagreeing oracle is now measured again, while the product stays compared strictly.

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1.

- **Full gate** (`verify-release.sh`) on `dev/next` `262cfe7a`, 59 min:
  - native serial lane 896 passed, 0 failures (44 skipped);
  - native parallel lane, 8 clones, 2,651 passed, **1 failed** (38 skipped);
  - helper 1,014/0 (7 skipped), helper cost 5/0, wire 36, concurrent 4, acceptance 3, Python 86, gallery 3/0 with 230 screenshots.
- **The one gate failure, explained and fixed** (`79cfea92`): `SessionReadStateTests.testAReplyInTheChatBeingReadWaitsForThePagesReadCheck` ran 6.0 s instead of 1.8 s.
  - Cause: a main-thread stall of about 4 s during frames 0–2 outlasted the 600 ms grace before the page's read at frame 3. The grace then published the reply as unread, as designed, and the frame count failed. A 0.7 s stall injected at frame 1 reproduces exactly that one assertion.
  - Not reproduced in 40 runs alone or 960 runs in 8 clones with all CPUs busy.
  - Fix: a test seam, `visibleReplyGraceOverride` (nil in the app), gives the frame phase a long grace. The unread phase keeps the app's 600 ms and waits for the result.
  - With the 0.7 s stall the test now passes. Mutations caught: the page's read not dropping the held reply, and no grace at all. 480/0 for both read-state classes in 8 clones under CPU load. Codex review: no findings.
  - The app's behavior is unchanged, so the rest of the gate was not rerun.
- **Hour soak**, Release build of the limit-pause head `623bc10d`, which contains every other 0.1.129 merge, seed **1790822043708**, no other builds running:
  - 3,609 s, 178 launches (sidebar median 261 ms, max 323 ms), 0 slow or missing launches, 0 row jumps.
  - **0 stalls over 250 ms** (0.1.128: 0).
  - Main-thread answers over 100/150/200 ms: 4/1/0, longest 167 ms (0.1.128: 8/0/0, longest 143 ms).
  - Footprint 108 → 762 MB, **3.70 MB per launch** (0.1.128: 3.66). This measures per-window state that XCTest retains.
  - The 60 s draw soak passed: 0 stalls, 4/0/0, longest 134 ms.

  Later round 8–11 fixes are small state-machine changes outside the soaked paths.

## Known

- **Cost-limit pause, for 0.1.130** (Codex round 12): all need a crash or an exactly timed Stop.
  - A child the reader stopped can be requeued by recovery after a crash.
  - Stop racing an accepted Resume can leave child tools running.
  - The side-pause fan-out is lost if the helper exits before its callbacks run.
- **Still unexplained**, each with diagnostics in place; none recurred in the eight or more full gates run on 2026-10-17:
  - `SessionTimingTests` narrow sidebar OCR;
  - `ContextReadingTests.testAChangedModelOrJournalCountsAgain` hang;
  - four never reproduced.
- **Git stash drop:** a stash pushed inside `git stash drop`'s own lookup window is detected and refused. It cannot be restored, because Git does not report its ID; its commit stays until garbage collection.
- **Webhook:** if an edit replaces the finished task's branch before preparation reads it, the webhook reports completion with an empty request and reply.

## Release

- Release commit `63b24d33` ("Release Bello Agent 0.1.129"), tag `v0.1.129`, pushed atomically to `main` and `dev/next`.
- `BelloAgent-0.1.129.dmg`, sha256 `2c124a883c0fe04c0ce488357efd5a64efe849faefce38a191bff6e010f4aabf`, 15,736,136 bytes; Developer ID signed and notarized (submission `71354d24-97da-4f99-b3f3-9df19671b530`, Accepted), stapled.
- `validate-release.py --previous-build 132`: passed (0.1.129 build 133, Ed25519 signature verified).
- Website commit `f5c21ad` (belloware.com `main`).
- `verify-published.py`: the public DMG matches, and the Bello Agent and legacy Pi App feeds are byte-identical.
