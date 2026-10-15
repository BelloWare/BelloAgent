# Bello Agent 0.1.127 — IntelliJ-style Git tools, file folder navigation, global Flat sidebar

Status: **packaged; publication pending** (this record is updated after publication). Marketing version 0.1.127, build 131. Previous public release: 0.1.126/build 130.

## Owner request

On 2026-10-14 and 2026-10-15, after 0.1.126, the owner asked for:
- "topic or flat view should be set for all projects, and let's combine projects, if user select flat view". The owner chose:
  - project and topic tags on rows;
  - one switch in the sidebar header menu and the View menu;
  - New Chat in Flat uses the selected chat's project, and project actions move to a Projects submenu.
- a way to see a linked file's siblings and parents ("implement this feature, not i. future").
- more IntelliJ parity for file and Git tools, designed with Codex (gpt-6-astra, max) and implemented by parallel Codex sessions. The owner chose **Staged changes** as the commit default, with Checked files as a switch. Deferred to later releases:
  - branch graph;
  - cherry-pick, revert and reset;
  - interactive rebase and a 3-way conflict resolver;
  - gutter markers, Local History, changelists and shelve;
  - compare with clipboard and symbol navigation.
- retrying a LiteLLM/Responses reply that ends `incomplete` without a reason: "we treat it as like a transient error… Just retry directly." This is an **owner-approved pi 0.85.1 deviation**. Explicit reasons keep pi behavior.

## Scope

Each workstream's record is under `docs/validation/`:
- **Whole-hunk staging** (`git-hunks-0.1.127.md`):
  - Stage/Unstage hunk with exact index transactions under Git's index lock;
  - Previous/Next Change, F7/Shift-F7;
  - Review Staged Changes.
- **Git safety** (`git-safety-0.1.127.md`, `git-safety-pi-confirmations-0.1.127.md`):
  - conflict badges and guarded unborn unstage;
  - Amend/Reword review the target and recheck it, in Pi sheets;
  - Sign off, a pre-commit check and Open Working File;
  - Staged changes is the default (`GitController.defaultCommitScope`).
- **History browser** (`git-history-0.1.127.md`, `git-safety-integration-0.1.127.md`):
  - literal message search, hash jump and ref/date filters, with removable chips;
  - rename-aware date paging.
- **Branches and stash** (`git-branches-0.1.127.md`):
  - searchable Recent/Local/Remote popup with upstream ahead/behind;
  - checkout, tracking, new, rename and delete through native `git branch -d/-D`;
  - stash list with preview, Apply/Pop/Drop and New Stash;
  - Show in History, which follows renames and deletes.
- **File folders** (`file-folders-0.1.127.md`):
  - breadcrumb folder menus;
  - a resizable folder tree with per-pane persistence.
- **File continuity** (`file-continuity-0.1.127.md`):
  - viewport and selection persist across relaunch;
  - bounded per-project recent files;
  - Find, Go to Line and Show File History in the tab menu;
  - hidden tabs suspend their work.
- **Global Topics/Flat** (`sidebar-flat-all-0.1.127.md`): Flat combines every project, with project and topic tags.
- **Incomplete retry** (`retry-incomplete-0.1.127.md`): a missing, null or empty `incomplete_details.reason` is retried by the global retry policy for turns, utility requests and compaction.

Final integration is recorded in `git-safety-final-integration-0.1.127.md`.

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1.

- **Codex review.** Each workstream was reviewed read-only by Codex (`codex exec review --base origin/dev/next`) until clean. Findings that were fixed:
  - recovery logs kept from earlier unsaved replies are preserved (retry-incomplete);
  - nested repository picker (file-continuity);
  - native Git deletion guards, stale stash choices and History retargeting on rename (git-branches);
  - rename-aware end date and quiet refresh (git-history).
- **Full gate** (`verify-release.sh`) on `dev/next` `bb6e9503`, **all passed** in 52 min 37 s:
  - native serial lane 766 (33 skipped), 0 failures;
  - native parallel lane 2,454 passed, 0 failed (37 skipped);
  - helper streaming cost 5;
  - gallery 236 screenshots, 0 failures;
  - helper 835 (7 skipped);
  - wire 36, concurrent 4, acceptance 3, python 79.
- **Hour soak.** Release build of `bb6e9503`, seed **1790822043708**, no other builds running:
  - 3,606 s, 178 launches (sidebar median 260 ms, max 300 ms), 0 slow or missing launches, 0 row jumps.
  - **0 stalls over 250 ms** (0.1.126: 0).
  - Main-thread answers over 100/150/200 ms: 7/0/0, longest 141 ms (0.1.126: 7/0/0, longest 125 ms).
  - Footprint 104 → 734 MB, **3.56 MB per launch** (0.1.126: 4.23). The soak keeps every closed window alive inside XCTest (178 of 178), so this measures retained per-window state.
  - The 60 s draw soak passed: 0 stalls, 3/0/0, longest 122 ms.
- **Known:**
  - Native amend has a documented external-Git race after its last target check.
  - Intermittent single failures in earlier workstream parallel lanes passed alone and did not recur in the final gate. Their causes are unconfirmed:
    - the `PiSheetWindowTests` closed-sheet release;
    - cleanup startup;
    - transcript reveal;
    - `ContextReadingTests` from 0.1.126.
  - Carried over from 0.1.126:
    - steering contract gaps;
    - SCROLL-11 and SCROLL-07 not done;
    - the historical webhook timeout's cause unconfirmed.
- **Not done:** VoiceOver and real-gateway checks; install/update rehearsals skipped under standing policy.

## Publication

Pending.
