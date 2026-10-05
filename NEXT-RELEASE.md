# Next release: 0.1.120

**Handover: read `docs/HANDOVER-0.1.120.md` first.** **Not released.** 0.1.119 (build 123, tag `v0.1.119`) is the latest release; its record is `docs/validation/Bello-Agent-0.1.119-2026-10-03.md`.

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

Integration checks: [AppKit integration record](docs/validation/AppKit-integration-0.1.120-2026-10-05.md). These are focused checks; the release gate, full gallery and Release soak are still pending.

## Wave 3
- [x] **App shell**: native `NSApplicationDelegate`, window controllers, menus and Settings window. Production sources in the app and `bello-views` have no SwiftUI imports or hosting views; a test enforces this. Frozen SwiftUI references remain in the test target for parity checks.

## Before release
- [ ] Codex (gpt-6.1-sol, xhigh) double-checks the whole change from e59e41a7 and gives advice; findings acted on, advice reported to the owner (owner, 2026-10-04).
- [ ] Performance compared with the baseline: no measure worse; chat switch and opening a chat faster.
- [ ] Full gallery compared with 0.1.119: **visually identical** (owner, 2026-10-05) — sub-pixel antialiasing and icon offsets up to about 0.25 pt are accepted; anything visible (layout shifts, colours, wrapping, moves of 1 pt or more) is fixed. Every screen gets a side-by-side check.
- [ ] Full gate passes (`scripts/verify-release.sh`).
- [ ] Hour-long soak of a Release build passes, no exceptions.
- [ ] Owner checks, or the owner defers them: VoiceOver; one compaction against a real gateway.
- [x] Release notes, including the terminal cursor correction (`releases/0.1.120.html`).
