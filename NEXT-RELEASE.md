# Next release: 0.1.119

**Not released.** 0.1.118 (build 122, tag `v0.1.118`) is the latest release; its record is `docs/validation/Bello-Agent-0.1.118-2026-10-02.md`.

**Scope (owner, 2026-10-02):** the approved UI/UX handoff, `docs/reviews/BelloAgent-approved-UI-UX-handoff-2026-10-02.md` (D1–D8, A1, A2). Its requirements and acceptance lists are the contract; read the item's section before working on it. Release when every item below is done.

**All work goes on `dev/next`.** Workstream branches (`dev/ws-git`, `dev/ws-queue`, `dev/ws-ui`) are merged here by the integrator. `main` holds released versions only — never push to `main` outside a release.

## How work is done
- Parallel workstream agents, each in its own worktree, build folder and Codex session (gpt-6.1-sol, xhigh, read-only) that plans every step and reviews every diff before commit.
- Every change gets tests that fail without it (mutation-checked), including the failure and interruption paths the handoff lists.
- Checks: `scripts/check-next.sh` (build, `test <Class>…`, `helper`, `gate`). Serial-lane classes run alone.

## Rules for code on this branch
- Native only (AppKit/SwiftUI), the app's Pi components, no stock controls.
- The helper follows pi 0.85.1 except where the handoff approves otherwise; wire changes are optional fields.
- No timing waits that count polls (use `eventually` in PiAppTests/TestSeams.swift).
- `packages/bello-views` stays free of app types; macOS 13. App target macOS 14.
- Motion policy unchanged (always-on app motion).
- Tick items here in the commit that finishes them.

## Workstream Git — Git and files (`dev/ws-git`)
- [x] **D1** Commit Checked Files vs Commit Staged Changes, explicit scope; true Reword Last Commit that keeps the tree, index and worktree.
- [x] **D6** Find and Go to Line survive a live file reload.
- [ ] **D8** Git Blame in the file viewer, with clicks opening the real commit-versus-parent diff at the line in Changes → History.

## Workstream Queue — queue and input (`dev/ws-queue`)
- [ ] **D2** Editing a queued message holds all pending input in that chat; durable, atomic acquire/save/cancel/remove with edit identity; restart reconciliation.
- [ ] **D4** Bounded, scrolling, collapsible queue panel; steering vs follow-up headings with truthful timing; full text and captured model/effort on demand.
- [ ] **A2** Image-only messages valid on every submission path for models that take images.

## Workstream UI — Settings, terminals, MCP (`dev/ws-ui`)
- [ ] **D3** Settings: Save All, Cancel discards, dirty close offers Save / Discard / Keep Editing; guarded Reload; honest partial saves.
- [ ] **D5** Multiple terminals per project: create, switch, rename, close; confirm restart/close of a live shell (Cancel default).
- [ ] **D7** "Remove All MCP Servers…" with an honest confirmation and result.

## After the workstreams merge
- [ ] **A1** Contextual accessibility in shared Pi controls and the new queue, terminal, Git-scope and blame controls (AX-tree assertions).

## Refactors — not in this release
Left to a separate agent (owner, 2026-10-02): composer @Observable pilot; AgentSession property groups; shutdown task ownership; narrower chat-change invalidation; shared journal-format module; remaining poll-counting waits.

## Before release
- [ ] Full gate passes (`scripts/verify-release.sh`).
- [ ] Hour-long soak of a Release build passes, no exceptions.
- [ ] Gallery reviewed for the new states (light/dark, minimum window size 920×600).
- [ ] Owner checks, or the owner defers them: VoiceOver across Settings, queue, file viewer, terminals; one compaction against a real gateway.
- [ ] Release notes.
