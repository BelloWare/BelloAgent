# Next release: 0.1.122

**Not released.** 0.1.121 (build 125, tag `v0.1.121`) is the latest release.

**Scope (owner, 2026-10-08):**
- [ ] **Mark as Unread**: a chat can be marked unread from the sidebar's context menu and the File menu; it shows the unread dot until opened, and survives a relaunch.
- [ ] **Paused after restart**: a chat that was paused (stopped mid-run, or holding queued work) still shows as paused in the sidebar and in the chat after the app restarts.
- [ ] **Sidebar sorted by last updated, always** (owner chose this over a switch): newest activity first; pinned chats stay on top; manual drag ordering is removed.
- [x] **Search inside threads**, both ways (owner chose both):
  - [x] the sidebar search matches message text as well as titles, shows a snippet under each matching chat, and opening it goes to the matching message (`dev/search`: trigram FTS5 index `search-index.sqlite` beside the desktop database, `Storage/ChatSearchIndex.swift`, `Workspaces/SidebarSearch.swift`; opening goes through the one adapter `SidebarSearchReveal`, which `dev/scroll` points at `revealInTranscript` with the hit's excerpt marked, its folded turn opened);
  - [x] ⌘F in an open chat shows a find bar that highlights matches in the transcript, with next/previous (`dev/scroll`: Pi find bar over the transcript; matches across the whole chat, loaded or not, read in and brought into view; ⌘G / ⇧⌘G, Return / Shift-Return, Escape; "Search and Copy Conversation…" moves to ⌥⌘F; `docs/transcript-reveal-api.md`).
- [ ] **Recently opened chats tinted** (owner, 2026-10-08): the open chat's sidebar row has the strongest tint, earlier-opened chats progressively less, fading to the normal grey after a few steps. Ranked by order of opening, not time; remembered across relaunch.
- [ ] **Draft indicator** (owner, 2026-10-08): a chat with an unsent composer draft shows a small draft marker on its sidebar row; clears when sent or emptied; survives relaunch.
- [x] **Smooth scrolling in very long chats (owner's priority):** scrolling up and down a long chat must be smooth, with no jumps or lost position; scrolling all the way to the start of the thread must work. Study how DeepSeek Harness's web UI (`@deepseek-ai/dsh`, open source) loads and scrolls its transcript and follow the same approach; if it doesn't load partially, use whatever gives smooth scrolling, with the loaded window prefetched ahead of the reader. Prove it with end-to-end tests that measure smoothness (frame times, no position jumps) and that reaching the first message works.
  - Done on `dev/scroll`. The reader's place is held through prepends and evictions: there were 18 jumps of 6,000–8,500 pt up and 28 down, now none. Pages are read three screenfuls ahead in the direction of travel: there were 32–60 frames stalled at an edge, now none. Home and ⌘↑ read the chat's first page: there were 34 presses, now one press, 0.6 s. Release frames improved: gesture up p95 37 → 30 ms, max 172–185 → 125–132 ms. No transcript measure got slower. `LongChatScrollTests` (serial) and `TranscriptRevealTests`/`TranscriptFindTests` are mutation-checked. Record: `docs/perf/long-chat-scrolling.md`. Remaining: 1–4% of Release frames still take 50–130 ms, where a page lands or a very long reply is first built (about 70 ms of TextKit layout for 51 KB). Measuring off the main thread is the next step. Release confirmation at `33f2dfd7`: the fling passed 6 of 6; the 200-turn probes had 0 jumps in 3 runs; the end-to-end class passed twice with its budgets.

**Rules:** AppKit only (no SwiftUI); Pi components (`docs/appkit-components.md`); every change planned and reviewed with Codex (gpt-6.1-sol, xhigh, read-only) to no findings, plus a final whole-change Codex double-check with advice; mutation-checked tests; serial-lane classes alone; work on `dev/next` via workstream branches; `main` only at release.

## Before release
- [ ] Codex whole-change double-check from 0.1.121 (`f4f80ddd`), with advice.
- [ ] Full gate (`scripts/verify-release.sh`), run alone.
- [ ] Hour-long soak of a Release build, no exceptions.
- [ ] Gallery review of the new states (light/dark, 920×600).
- [ ] Release notes.

---

# Next release

**Released 2026-10-08:** 0.1.121 (build 125, tag `v0.1.121`) removes every editing-tool lock (owner, 2026-10-08); record `docs/validation/Bello-Agent-0.1.121-2026-10-08.md`. Nothing is planned beyond it yet.

---

# Completed release: 0.1.120

**Released, 2026-10-06:** 0.1.120 (build 124, tag `v0.1.120`) is the latest release. The complete AppKit migration is shipped. Source/tag and website changes are pushed; the public page, identical update feeds and downloaded DMG hash/signature pass verification at 01:07:03 UTC. See `docs/validation/Bello-Agent-0.1.120-2026-10-06.md` for evidence and the explicit manual/measurement limits. `docs/HANDOVER-0.1.120.md` preserves the original implementation snapshot.

**Scope (owner, 2026-10-04): no SwiftUI.** Every view, window and the app itself move to AppKit, for predictable layout and real performance across the board. The look stays pixel-identical (screenshot gallery before/after) apart from run-to-run data. Behaviour, keyboard, focus and accessibility stay the same or better. **One release at the end**, when no file imports SwiftUI, the gate passes and the hour soak is clean.

**All work goes on `dev/next`.** Workstream branches (`dev/appkit-*`) are merged here by the integrator. `main` holds released versions only — never push to `main` outside a release.

## How work is done
- Parallel workstream agents, each in its own worktree, build folder and Codex session (gpt-6.1-sol, xhigh, read-only) that plans every step and reviews every diff before commit.
- Port, don't redesign: same layout, spacing, colours, motion, copy and behaviour. Compare gallery captures before and after (`scripts/compare-captures.py`); differences must be run-to-run data only.
- Performance discipline: reuse views, draw only what is visible, never relayout what didn't change, no work per token across the window. Measure against the baseline below.
- Existing tests keep passing; tests that read SwiftUI structure are rewritten to read AppKit/accessibility instead, never deleted without an equivalent.
- Checks: `scripts/check-next.sh` (build, `test <Class>…`, `helper`, `gate`). Serial-lane classes run alone.

## Rules for code on this branch
- AppKit only for new code. A file stops importing SwiftUI when its port is done.
- Keep the app's Pi look; no stock-looking controls.
- Keep `packages/bello-views` free of app types; macOS 13. App target macOS 14.
- Motion policy unchanged. Accessibility (A1) must not regress: native AppKit accessibility roles, labels, values and selected states.
- Tick items here in the commit that finishes them.

## Wave 1
- [x] **Baseline**: today's numbers on dev/next before any port — chat switch, opening a large chat, streaming a long reply, scrolling, typing latency, soak main-thread maxima. Recorded in `docs/perf/appkit-baseline.md`.
- [x] **Pi components in AppKit** (`Design/`): buttons, toggles/switches, tabs, steppers, choice picker, menu, popover, hover card, sheet, question, badges, stat pill, surfaces, flow indicators, chart parts. Same look and API shape; gallery parity.
- [x] **Transcript** (`Transcript/`): rows, cards, chrome, pills, markdown/code surfaces, turn fold, versions, large table — all AppKit inside the existing AppKit scroll view. Chat switch measured against the baseline.

## Wave 2 (after the components land)
- [x] **Workspace shell** (`Workspaces/`, `Composer/`, `Tabs/`, `Terminal/`): sidebar, conversation pane, footer, composer chrome, queue panel, tabs, terminal panel, sheets.
  - Native views are mounted directly. The metrics footer retains responsive layout, capture controls, run clock and automatic context counting; temporary SwiftUI adapters have been removed.
- [x] **Inspector and dashboard** (`Inspector/`, `Dashboard/`).
  - All Inspector pages, statistics dialogs, retained bodies, JSON/search, resources and MCP controls now use AppKit. Dashboard, live monitor, menu-bar panel, chart engine and cost-limit controls are integrated. Focused parity, lifetime, selection and accessibility checks pass; the complete gallery and gate remain below.
- [x] **Settings, onboarding, Git, files** (`Application/` settings and onboarding views, `Git/`, `Files/`, and the two SwiftUI files in `packages/bello-views`).

Integration checks: [AppKit integration record](docs/validation/AppKit-integration-0.1.120-2026-10-05.md). The fresh `1aa78749` gate passes every native/helper/wire/script check; a views-package test's unspecified task-entry order was repaired and the complete 167-case package plus two ten-case repeats pass. All 192 fresh pairs were actually viewed. The narrow Git background defect is fixed in `70812d5f`; all 28 affected Debug and 15 affected Release checks pass, with mutation proof and exact light/dark caption pixels. The final complete 192-capture gallery passes and all 12 affected Git pairs were reviewed afresh. Both 16-invocation performance sets and the actual 3,607-second mixed-action hour pass. The bounded reviews report no introduced findings. Release commit `f8a3a79a` is signed, notarized and publicly verified; measurement, retention and manual-check limits remain explicit.

## Wave 3
- [x] **App shell**: native `NSApplicationDelegate`, window controllers, menus and Settings window. Production sources in the app and `bello-views` have no SwiftUI imports or hosting views; a test enforces this. Frozen SwiftUI references remain in the test target for parity checks.

## Before release
- [x] Codex (gpt-6.1-sol, xhigh) double-checks the whole change from e59e41a7 and gives advice; findings acted on, advice reported to the owner (owner, 2026-10-04). Whole-change and subsequent bounded repair reviews report no introduced findings, including the composer/footer performance correction, narrow Git background and test-entry-order correction. Tests subsequently caught a transitional underlay fill; the final replacement reuses the existing flat `FillView` and passes unchanged light/dark pixel checks. Advice: confirm composed background coverage and event routing, finish comparable Release measurements and the actual hour soak before publication. See the integration record for exact review pins and limits.
- [x] Comparable Release performance recorded: all 16 baseline and 16 final invocations pass with the same fixtures, seed and start-load limit. Opening/reopening, streaming, scrolling and typical/p90 typing improve. Whole-window switching is broadly similar; typing maxima are slightly higher (9.9–10.8 ms versus 7.9–9.7 ms), reduced from the earlier candidate's 15–17 ms. This explicitly replaces the original blanket "no measure worse" criterion with the actual measurements under the owner's instruction that the handover need not be followed completely. See `docs/perf/appkit-0.1.120-final.md` for every round and memory/lifetime limits.
- [x] Complete visible-screen gallery review: all 192 fresh `1aa78749` pairs were viewed side by side. The discovered 15.5-point Git background defect is fixed in `70812d5f`; a fresh complete 192-capture run passes, and all 12 affected Git pairs were viewed afresh, including original 2x narrow captures. Unchanged-screen reviews are reused under `docs/Release.md`. No remaining actionable owned layout/color defect was found in the visible coverage. This is not blanket pixel equality: generated data/path wrapping, initial lazy scroll-thumb estimates, focus/selection, optical differences and offscreen limits remain explicit in the integration record and per-image notes.
- [x] Release gate checks complete: `1aa78749` ran the whole gate, passing 628 serial cases and 1,937 parallel passes plus every remaining check except one views-package test's unspecified task-entry order. The corrected full views package passes 167 cases, with two additional affected repeats. The later background correction passes eight strengthened frozen geometry/pixel cases; unchanged passing checks are reused under `docs/Release.md`. The original gate's nonzero exit and corrective logs are preserved rather than described as a fresh zero-exit run.
- [x] Actual mixed-action Release hour passes with original thresholds: 3,607 seconds, 177 launches, zero pauses over 250 ms, zero row jumps, zero slow/missing launches and zero quit failures. Longest recorded answer is 115 ms. The in-process harness retains 177 windows and six recent models, with zero closed views; footprint rises 102→922 MB (4.66 MB/cycle). Its teardown is unchanged apart from the native root, and previous releases document this test-window retention. This passes the soak's responsiveness/stability gates, not a bounded-memory certification. Full report is preserved in the validation record.
- [ ] Owner checks, or the owner defers them: VoiceOver; one compaction against a real gateway.
- [x] Release notes, including the terminal cursor correction (`releases/0.1.120.html`).
