# Handover: Bello Agent 0.1.120 (AppKit only), 2026-10-05

**Continuation, 2026-10-05:** the transcript and dashboard branches have been merged into `dev/next`, built and tested. The saved native metrics-footer work has also been completed, with regression and visual checks. Follow `NEXT-RELEASE.md` and [the integration record](validation/AppKit-integration-0.1.120-2026-10-05.md) for the current state; the branch table below describes the original handover snapshot. 0.1.120 remains unreleased.

Read this first, then `NEXT-RELEASE.md`, `AGENTS.md`, `docs/appkit-components.md`, `docs/Swift-Test-Handoff.md` and `docs/Release.md`.

## Goal and owner decisions
- **Remove SwiftUI entirely.** Every view, window and the app entry point move to AppKit, for performance. No file may `import SwiftUI` in the shipped app. SwiftUI reference copies used only by parity tests live under `apps/macos/PiAppTests/SwiftUIReference`.
- **Look bar: visually identical, not strict pixel-identical** (owner, 2026-10-05).
  - Accepted: sub-pixel antialiasing, icon offsets up to about 0.25 pt, and middle truncation that occasionally keeps one character more or fewer.
  - Must be fixed: anything visible, meaning layout shifts, colours, wrapping, or moves of 1 pt or more.
  - Every screen gets a side-by-side check.
- **One release at the end:** 0.1.120, after the whole port. Not partial releases.
- **Terminal cursor bug:** included in 0.1.120; already fixed (below).
- **Codex:** gpt-6.1-sol, `model_reasoning_effort="xhigh"`, read-only.
  - Plans every step and reviews every commit until it reports no findings.
  - The owner also wants a final whole-change Codex double-check, with advice, at the end of every big change.
  - Command: `codex exec [resume <id>] -m gpt-6.1-sol -c model_reasoning_effort='"xhigh"' -c sandbox_mode='"read-only"' -o <file> "<prompt>" </dev/null`
- **Decisions go to the owner** as 2–4 clickable options, recommended first.
- **Behaviour and accessibility** stay the same or better. Motion policy is unchanged.

## Where everything is (all pushed to GitHub BelloWare/BelloAgent)
| Ref | Commit | State |
|---|---|---|
| `main` | `435c4c8a` | 0.1.119, released (tag `v0.1.119`). Only releases go here. |
| `dev/next` | `e9e9ce0b` | AppKit Pi components + parity fixes, Git/Files/Settings/onboarding, the whole workspace shell (window root included) and the terminal cursor fix. Last build-verified at `9ca27dc8` (82 key tests); the terminal merge after it was conflict-free but not rebuilt. |
| `wip/next-plus-transcript` | `cab40859` | `dev/next` + the finished transcript port. The project-file conflict was resolved with ours + `xcodegen generate`. **Not built yet**: disk ran out. Build and test this first, then fast-forward `dev/next` to it. |
| `dev/appkit-transcript` | `569f2470` | Transcript port, done and Codex-reviewed (already inside `wip/next-plus-transcript`). |
| `dev/appkit-dash` | `e97ec9e5` | Chart engine (`Charts/`), live monitor, menu-bar panel, Dashboard pages, cost-limit views. Built on the older `9ca27dc8`. Whether Codex reviewed this last batch to no findings is unknown, so re-review it. |
| `dev/appkit-dash-wip` | `d23ba5d4` | The stopped agent's uncommitted MetricsFooter → AppKit work, saved as is. Unbuilt and unreviewed. |

Old workstream branches (`dev/appkit-design`, `-shell`, `-settings`, `-kitfix`, `dev/terminal-cursor`) are merged and can be deleted.

## What is done
- **Pi components** (`apps/macos/PiApp/DesignKit/`): AppKit twins of everything in `Design/`, pixel-compared (`PiKitParityTests`, serial) and behaviour/accessibility-tested (`PiKitControlTests`). Guide: `docs/appkit-components.md`.
- **Git, Files, Settings, onboarding:** AppKit. D1/D3/D6/D7/D8 behaviour from 0.1.119 kept.
- **Workspace shell:** sidebar, conversation pane, composer, queue, terminal panel, tabs, sheets, side pane and window root.
- **Transcript:** every row, the pane and its chrome. Measured against the baseline:

  | Measure | Baseline | AppKit |
  |---|---|---|
  | Chat switch, main thread | ~52 ms | ~36 ms |
  | First open | 191–319 ms | 125–221 ms |
  | Streaming, main thread | 28% | 16–17% |
  | Scrolling p95 | 17.5 ms | 8 ms |
  | 122 s soak, answers over 100 ms | 8–14 | 1–3 |
- **Terminal cursor fix:**
  - Cells are now exactly one font advance wide. Before, cells were rounded up to whole points while glyphs used natural spacing, so they drifted about 0.6 pt per column.
  - Character widths follow Unicode 15.1 East Asian Width with zsh's emoji rules.
  - A zero-size layout no longer shrinks the grid to 2×1.
  - Tests: `TerminalCursorAlignmentTests` (15), which drive real zsh. 0.1.119 has all these bugs.
- **Performance baseline:** `docs/perf/appkit-baseline.md` and `scripts/perf-transcript.sh`, both on the transcript branch. The baseline Release build of `e59e41a7` was kept at `$S/baseline-0.1.120` (scratch, may be wiped). If it's gone, rebuild that commit for before/after comparisons.

## What is left
1. **Integration completed, 2026-10-05.** The transcript and dashboard branches are merged into `dev/next` with their commit identities preserved. Focused builds, behavior checks and parity checks passed; see the integration record. The remaining work below still precedes the release gate.
2. **Inspector/** (still SwiftUI):
   - `MetricsFooter` and `SessionStatsPills` are now AppKit, with the saved WIP completed and validated;
   - `SessionStatsPopovers`, `SessionUsageView`, `SessionRequestLedger`;
   - the Session Inspector window and pages;
   - `CapturedBody*`, `JSONOutline`, `PayloadSearch`, `PagedTextView`, `MessageModelReports`, `ConversationContentView`;
   - `ResourceInspector`, including D7 MCP removal.

   `InspectorOverviewPage` temporarily hosts the AppKit cost-limit editor.
3. **Wave 3, app shell:**
   - Replace the SwiftUI `App` (`Application/PiApp.swift`) with an `NSApplicationDelegate` and window controllers.
   - Port the window glue: `PiSheetWindow`, `WindowPresentation`, `WindowVisibility`, `WindowActivityGuard`, `WorkspaceCommands` (menus).
   - Remove every temporary bridge:
     - `Workspaces/WorkspaceRootBridges.swift`, `ConversationPaneBridges.swift`, `WorkspaceBridges.swift`, `SidebarSwiftUIBridges.swift`;
     - `Composer/NativeCodeEditorBridge.swift`, `Composer/SkillPillFaceSwiftUI.swift`;
     - `Application/SettingsBridge.swift`, `Application/AppKitTabBridge.swift`;
     - `Files/QuickOpenBridge.swift`;
     - `Workspaces/NativeTranscriptHost.swift` (thin wrapper).
   - Then delete the SwiftUI `Design/` components once unused, and add an app-wide test that fails on `import SwiftUI` (the transcript already has one for its folder).
4. **DesignKit gaps** reported by consumers, now worked around locally; fix them in DesignKit, then drop the local copies:
   - `PiKit.inset` strokes outside the edge (local `ShellInset`).
   - `PiKit.TextField` fires its action on end-editing.
   - Wrapped text lacks the `.standard` line-break strategy.
   - `SectionHeader` subtitle doesn't wrap (local `ShellSectionHeader`).
   - `Button` doesn't expose its title font.
   - `Row` vs Settings' local `SettingsRow`.
   - `statTile` caption wrapping and scaled-value spacing; `KeyValue` row height.
   - Settings' own `SymbolButton` places symbols about 0.2 pt low.
5. **Before release** (checklist in `NEXT-RELEASE.md`):
   - Codex's final whole-change double-check from `e59e41a7`, with advice.
   - Performance vs the baseline: nothing slower.
   - Gallery visual check of every screen vs 0.1.119.
   - Full gate (`scripts/verify-release.sh`), run alone.
   - A clean hour-long soak on a Release build.
   - Ask the owner about the VoiceOver and real-gateway checks; they deferred them for 0.1.117–0.1.119.
   - Release notes, which should mention the terminal fix.

## Known differences and open items (tell the owner, don't hide)
- **Transcript:**
  - RTL compaction long-detail differs 1.6% (SwiftUI wraps 3 pt wider).
  - Large-diff disclosure indent is estimated.
  - Off-grid rows draw sub-pixel differently.
  - Deliberate changes:
    - the quote bar shows its full title;
    - markdown Copy is keyboard-reachable;
    - the copy button is 22.5 pt.
- **Components:**
  - Symbol placement is a constant 0.25 pt lift, not SwiftUI's per-symbol position.
  - The stat pill's per-character roll has no blur.
  - Hover/press are not pixel-compared: the test runner lacks event-posting permission.
  - Inner non-Pi controls of a disabled row keep their own accessibility.
- **Shell:**
  - The over-long connection name in the catalog picker lays out differently.
  - The error strip fades rather than eases (tests require it).
- **0.1.119 behaviour the owner accepted:** at 920×600 with a terminal, a tall draft and a running reply, the transcript gets about 50–75 pt and the window grows.
- **Pre-existing:**
  - `InspectorFrameTests.testTheInspectorOverALongChat` fails on the baseline too.
  - The narrow-pane footer capture badge overlaps the cost line.
  - Changes file-row tick/Stage buttons may not be separately reachable with VoiceOver.
- **Terminal, not fixed (owner to decide):**
  - IME selected/actual range not reported.
  - Text composed while scrolled back isn't shown.
  - Glyphs wider than their cell (for example ❤️) overlap the next cell.
  - Indic spacing marks are counted as 1 cell.

## How to work here
- **Building:**
  - Set `PI_BUILD_ROOT` to a scratch folder and run `python3 scripts/build-bundle.py` before `xcodegen generate` and `xcodebuild build-for-testing -project PiApp.xcodeproj -scheme PiApp -destination 'platform=macOS,arch=arm64' -derivedDataPath $PI_BUILD_ROOT/native CODE_SIGNING_ALLOWED=NO`.
  - `scripts/check-next.sh` (build | test A B | helper | gate) does this in `~/Library/Caches/BelloAgentNext`. `PI_NEXT_REF=<ref>` checks a local ref.
- **Testing:**
  - Serial-lane classes run alone (`python3 scripts/test-lanes.py list`).
  - New tests must fail without their fix (mutation-check).
  - Use the time-bounded `eventually` (PiAppTests/TestSeams.swift), never poll counts.
  - Never loosen thresholds.
- **Disk is the hard limit:** 111 GB volume, often only 2–5 GB free.
  - One app build is about 1–1.2 GB. Run at most two builds at once.
  - Delete finished builds and galleries.
  - Do not delete `~/.codex` (the owner said no), `~/.cdkjj-remote`, or other projects.
- **Rules:**
  - Commit and push completed work (AGENTS.md).
  - Never force-push or rewrite published history.
  - Work goes to `dev/next` via workstream branches; `main` only at release.
  - Commit trailers: see AGENTS.md and the session's attribution lines.
- **Releasing:** follow `docs/Release.md`.
  - From a scratch worktree, `scripts/release.sh` needs `NOTARY_KEY_PATH=/Users/admin/projects/BelloWallProfiles/AuthKey_SSYSS59Z5W.p8`.
  - `scripts/publish-release.sh` needs `BELLOWARE_SITE_ROOT=/Users/admin/projects/belloware.com`.
  - `RELEASE_MESSAGE` must not contain `$`.
  - Sequence:
    1. Merge `dev/next` into `main` with `--no-ff`, plus one release commit.
    2. Publish, then verify with `scripts/verify-published.py`.
    3. Tag `v0.1.120` on the release commit.
    4. Add a "Record verified public … release" commit and push main, `dev/next` and the tag.
  - A sub-agent's publish step was blocked by the permission check. The agent the owner talks to directly should run the publish.
