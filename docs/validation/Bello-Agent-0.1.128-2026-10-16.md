# Bello Agent 0.1.128 — sub-agents and sides at the main chat's top right, family spend, sub-agents on request

Status: **publicly released and verified** at [belloware.com](https://belloware.com/bello-agent.html), marketing version 0.1.128, build 132. Public verification completed at **2026-10-16 04:53:04 UTC**. Tagged source: **`73f9527c`**, `v0.1.128`. Website: **`7e4a5bb`**. Previous public release: 0.1.127/build 131.

## Owner request

On 2026-10-15 and 2026-10-16, after 0.1.127, the owner asked to "work on these and then release a new version":
- Sub-agents:
  - the completion webhook should not fire for sub-agents;
  - a collapsed turn shows only the main agent's response;
  - sub-agent cost counts toward the main session, and people can see it;
  - sub-agents are numbered so they can be told apart.
- Sub-agents and sides are shown at the top right of the main session, not in the left panel. The owner chose:
  - one pill ("2 sides · 3 agents") with two sections;
  - a small running count on the parent's sidebar row;
  - opening one shows it in the side panel beside the main chat;
  - sides leave the sidebar, and the right-edge hover sides panel is removed.
- Side spend counts toward the main chat's total **and** its cost limit; there are no separate side limits.
- Flat view: a project chip "in <Project> ▾" above the composer of an unsent chat.
- Fixes:
  - forking a chat with sub-agents ("A native journal has exactly one format marker");
  - keeping a side ("A previous conversation copy needs review"), fixed without reading real data at the owner's instruction;
  - saving an edited queued message.
- Sub-agent results are rendered as Markdown.
- By default the agent does not start sub-agents. The prompt rule: "Start sub-agents only when the user explicitly asks for sub-agents/agents, delegation, or parallel work; otherwise do the work yourself, even for large tasks."
- The main agent can set a sub-agent's thinking effort (`effort` on `subagent_start` and follow-ups; omitted means inherit).
- Fork plus sub-agents: the owner chose "Open original read-only"; a deep fork of sub-agents is deferred.
- Check that interaction with sub-sessions is cache-efficient.
- Side budget convergence: "Keep going until clean".

## Scope

Each workstream's record is under `docs/validation/`:
- **Fork with sub-agents** (merge `9c283ad2`): forks of chats with sub-agents succeed; the copy opens the original's agents read-only.
- **New-chat project chip** (`558630c8`).
- **Side keep** (`27bb12ef`).
- **Sub-agent policy** (`e13e1462`): the prompt rule and `effort`.
- **Queued-message edit** (`152725f0`).
- **Sub-agent cache** (`bd9a1a94`): fixed two prompt-cache breaks (model enum order in `subagent_start`; a child's instruction role flipping between developer and system). Cache breaks in the generated fixture went from 8 to 0, and reusable input from 60.82% to 86.80%. An effort change is itself a provider cache boundary; real upstream cache hits were not measured.
- **Sub-agent display** (`3b3baa40`, `sub-display-0.1.128.md`, 17 review rounds):
  - the top-right family popover with a nested tree and owner labels;
  - numbering, Markdown results and the details grid;
  - collapsed turns without sub-agent content;
  - read-only fork originals and reader navigation ownership;
  - SidesPanel removed.
- **Sub-agent and side cost** (`02401065`, `sub-cost-0.1.128.md`, 21 rounds, 20 independent reviews):
  - the family-completion webhook fence;
  - family spend in the main chat and its limit, with breakdowns;
  - the shared side budget and limit-stop state machine;
  - durable child cost revisions and an indexed side-origin cache (cold open with 200 saved sides: 3.29 s → 0.04 s).
- **Gate repairs** (`cd4730ec`, `gate-fix-0.1.128.md`): rendered Find waits for expanding geometry; child Find shortcuts keep ownership; 50 KB result expansion reuses Markdown segments and cached row lookups; side wire tests assert the shared-budget contract; sidebar fixtures use indented topic chats.

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1.

- **Codex review.** Each workstream was reviewed read-only by Codex (`codex exec review --base origin/dev/next`) until clean.
- **First gate** on `02401065` failed:
  - serial lane: 5 tests (sidebar fixtures, sub-agent Find, the 50 KB expansion heartbeat, popped-out Find shortcuts);
  - wire: 2 side-cost tests.

  The branches had been validated with the parallel lane only. `dev/a128-gate-fix` fixed these, and its review was clean.
- **Full gate** (`verify-release.sh`) on the gate-fix tree, identical to `dev/next` `cd4730ec`, **all passed** in 56 min 20 s:
  - native serial lane 880 executed (42 skipped), 0 failures;
  - native parallel lane 2,630 passed, 0 failed (38 skipped);
  - helper 959 (7 skipped); views 304 (3 skipped);
  - wire 36, concurrent 4, acceptance 3, python 86;
  - gallery 3/3, 230 screenshots.
- **Hour soak.** Release build of `cd4730ec`, seed **1790822043708**, no other builds running:
  - 3,606 s, 178 launches (sidebar median 258 ms, max 381 ms), 0 slow or missing launches, 0 row jumps.
  - **0 stalls over 250 ms** (0.1.127: 0).
  - Main-thread answers over 100/150/200 ms: 8/0/0, longest 143 ms (0.1.127: 7/0/0, longest 141 ms).
  - Footprint 99 → 747 MB, **3.66 MB per launch** (0.1.127: 3.56). The soak keeps every closed window alive inside XCTest (178 of 178), so this measures retained per-window state.
  - The 60 s draw soak passed: 0 stalls, 3/0/0, longest 146 ms.
- **Known:**
  - Intermittent single failures in workstream parallel lanes passed alone and did not recur in the final gate. Their causes are unconfirmed:
    - `ContextReadingTests` (nil fraction after helper shutdown);
    - Overview hover redraw counter;
    - `TerminalSessionsTests` and `CatalogModelPickerTests` timeouts;
    - `FileHiddenReadTests`.
  - `MarkdownSourceReconciliationTests` fails 1/5 when run alone, also on its baseline; it passes in the full lane.
  - A recovered saved side becomes an independent chat with its own limit.
  - Deleting a chat whose project is unavailable requires restoring the project first.
  - Wait receipts repeat a 64-character ID (about 40 tokens).
  - Deep fork of sub-agents is deferred.
  - Carried over:
    - the native amend external-Git race;
    - steering contract gaps;
    - SCROLL-11 and SCROLL-07 not done.
- **Not done:** VoiceOver and real-gateway checks; install/update rehearsals skipped under standing policy.

## Publication

Packaged from **`73f9527c`** with `scripts/release.sh`. That commit is `main` merged with `dev/next` at `cd4730ec`, plus the version bump, the release notes and this record's first draft. The script:
- made a Release build, stripped the binaries and kept the dSYMs;
- signed with Developer ID and ran the packaged-helper offline smoke test;
- notarized and stapled the app and the DMG, then checked them with Gatekeeper;
- signed the appcast and verified its Ed25519 signature.

`validate-release.py` against build 131 passed. The owner approved publishing 0.1.128 on 2026-10-15 ("work on these and then release a new version"), once the work, gate and soak were done.

- App notarization: **`3e098545-87bd-428a-8ca9-4712c450f48c`**, Accepted.
- DMG notarization: **`1dce34c5-ec20-44cb-9f82-e6fa0e73e5ea`**, Accepted.
- Installer: **15,536,212 bytes (14.82 MiB)**.
- SHA-256: **`ff5f6c50a59a261bda1ec045dc3f444b9b12467a836bbfb7db0484b310721244`**.

Source was pushed atomically to `main` and `dev/next` at `73f9527c`, with tag `v0.1.128`. `publish-release.sh 0.1.128` pushed website `7e4a5bb`.

`verify-published.py` passed at 2026-10-16 04:53:04 UTC:
- the canonical and legacy feeds are identical;
- the public DMG's SHA-256 matches;
- the Ed25519 signature verifies.

Install and update rehearsals were skipped by standing owner instruction.
