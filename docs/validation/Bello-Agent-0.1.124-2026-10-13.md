# Bello Agent 0.1.124 — a flat view of a project's chats, retries for every connection, audit fixes

Status: **packaged, pending publication**. Marketing version 0.1.124, build 128. Previous public release: 0.1.123/build 127.

## Owner request

On 2026-10-13 the owner asked for three read-only Codex audits (gpt-6-astra, max), chose the 13 "worth doing" findings, and had four Codex sessions implement them ("please have 4 new codex session to do the fix instead", then "run them with full access"). The owner also asked for a flat topic view ("see all threads by their updated time, and see their topic more like a tag") and for retries set once for all connections with exponential back-off, both in this release, which was to be delivered "ASAP".

## Scope

- **Flat topic view** (`dev/flat-topics`). A project's "…" menu has Show Chats ▸ Topics / Flat, stored per project in `ProjectSidebarState.flatTopics`.
  - Flat lists the project's chats by last update, pinned chats first, with the topic as a compact `PiKit.Badge` tag.
  - Sides stay under their parent. Archived chats are tagged under one heading. Search also matches topic names.
  - Drag and drop are off in Flat.
  - The Topics view's sidebar is pixel-identical to before (0 differing sidebar pixels in light and dark).
- **Retries for all connections** (`dev/retry`). Settings ▸ Connections ▸ "Retries · all connections".
  - Controls: on/off, 0–10 retries, first delay 1–60 s. pi's defaults: on, 3 retries, 2 s.
  - The setting reaches the helper in `workspace.open` and through `retry.configure`. Every provider retry (turns, utility requests, compaction summaries) waits base × 2^(n−1). Each request keeps the policy it started with.
  - `CompactionPolicy.maximumAttempts` raised 8 → 11.
- **Audit fixes** (Codex-implemented on `dev/shell-inspector`, `dev/mcp`, `dev/composer-send`, `dev/git-files`):
  - **Inspector:** captured numbers are converted with checks.
  - **Terminal:**
    - a folder that cannot be entered fails the launch through a bounded handshake that runs off the main thread;
    - closing and restarted terminals are ended at Quit.
  - **Keychain:**
    - operations that time out before they start never run;
    - uncertain saves say so and reconcile without overwriting later edits.
  - **MCP:**
    - HTTP MCP has an overall deadline;
    - Inspector MCP outcomes are kept until saved, including a retention failure that arrives before the call ends.
  - **Composer and drafts:**
    - pasted images are durable, with deferred and safe cleanup;
    - an accepted message is not offered for resend;
    - draft recovery is full and atomic, and closing a side waits for it;
    - confirmed sends survive a cancelled chat selection.
  - **Git and file viewer:**
    - git diff prefixes are forced;
    - Git actions are bound to their repository snapshot;
    - interrupted commit reads resume;
    - FIFO-safe file opens;
    - the newest copy wins across viewers.

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1.

- **Codex review loop.** Each branch was reviewed read-only by Codex (gpt-6-astra, max) until clean:
  - shell-inspector: 2 rounds;
  - mcp: 2 rounds;
  - composer-send: 4 rounds;
  - git-files: 4 rounds;
  - flat-topics: 2 rounds;
  - retry: 2 rounds.
  Every finding was fixed test-first. A fifth Git fix (`6609532d`, which disabled the commit editor during repository switches) regressed panel re-show and same-repository refreshes in review, so it was left out (see Known).
- **Full gate** (`verify-release.sh`) on `e411c390`:
  - native serial lane 668 (31 skipped), 0 failures;
  - parallel lane 2,122 passed, 0 failed (35 skipped);
  - helper 647 (6 skipped);
  - helper streaming cost 5.
  - The gallery failed once, at scene 20: a chat did not settle in 120 s, the known intermittent full-gallery failure. The rerun alone on the same build passed with 210 screenshots and 0 failures.
- **Merged-tree checks** after the overlapping merges: 46 helper and 97 app tests (settings, vault, Keychain, MCP, retry, flat topics) passed.
- **Hour soak.** Release build of `3cc33732`, seed **1790822043708**, no other builds running:
  - 3,603 s, 178 launches (sidebar median 243 ms, max 285 ms), 0 slow or missing launches, 0 row jumps.
  - Main-thread answers over 100/150/200 ms: 6/1/1 (0.1.123: 8/1/0).
  - **One stall over 250 ms: 368 ms** at 2,431 s, during "switch chat 1 then chat 3". All three stacks are in `CA::Context::synchronize` / `wait_for_synchronize`, waiting on the window server, with no app frames. It came after the test runner passed 100 live windows (its documented window retention), so it is recorded as a test-environment artifact.
  - Footprint 98 → 737 MB, 3.61 MB per launch (0.1.123: 3.58).
  - The 60 s draw soak passed: 0 stalls, longest 124 ms.
- **Known:**
  - Git (rare): during a repository switch, a commit message typed while the new repository loads can be cleared if a second folder in the same repository is chosen before it loads, and Amend can prefill the previous repository's HEAD message.
  - `WorkspaceFollowupTests.testScratchChatRendersComposerAndPreparesToolFreeRequestWithoutProject` can time out in helper shutdown under heavy machine load; it passed in the gate.
- **Not done:** VoiceOver and real-gateway checks; install/update rehearsals skipped under standing policy.

## Publication

Pending.
