# Next release: 0.1.118

**Not released.** 0.1.117 (build 121) is the latest release; its record is in `docs/validation/` and in this file's git history.

**All work for 0.1.118 goes on `dev/next`.** Workstream branches (`dev/ws1-…` etc.) are merged here by the integrator. `main` holds released versions only (docs/Release.md).

**Release rule (owner, 2026-10-01): release only when every item below is done** — all five workstreams, the full gate, and an hour-long soak that passes with no exceptions.

## How work is done
- The integrator implements with parallel workstream agents, each in its own worktree and build folder, each with its own Codex session (gpt-6.1-sol, xhigh, read-only) that plans every step and reviews every diff before commit.
- Every fix gets a test that fails without it (mutation-checked). UI stays unchanged except where an item says otherwise.
- Checks: `scripts/check-next.sh` (build, `test <Class>…`, `helper`, `gate`).

## Rules for code on this branch
- Native only (AppKit/SwiftUI), the app's Pi components, no stock controls.
- The helper follows pi 0.85.1 exactly; wire format changes must be optional fields.
- No timing waits that count polls (use `eventually` in PiAppTests/TestSeams.swift).
- Keep `packages/bello-views` (FileView, FileFinder, GitView) free of app types; macOS 13.
- Tick items here in the commit that finishes them.

## Workstream 1 — data safety and connections (review findings 1–5)
Source: `docs/reviews/BelloAgent-0.1.117-deep-review.md`.
- [ ] **Literal Git paths** (finding 1): discard, delete untracked, stage, unstage, commit (both forms, incl. pathspec-file) use literal pathspecs; diff/history audited. Tests: `[`, `*`, `?`, leading `:` names; unselected files untouched; renames; long lists.
- [ ] **Serialized connection switch** (finding 2): per-chat gate over close/rebind/metadata vs open, send, prewarm and automatic context; opens tied to a binding generation and revalidated after awaits. Test the review's reverse interleaving, two quick switches, cancellation, failed writes.
- [ ] **Journal rebind on switch** (finding 5): rebind the journal to the new connection before committing the switch; a failed rebind leaves the old connection working. Two synthetic gateways; send and reopen on B; checkpoint and full-replay journals.
- [ ] **Confirm when reasoning can't carry over** (owner decision: ask each time): before switching, the helper checks the context against B. If replies hold provider-only reasoning that only A can use, ask "Earlier reasoning from A can't be sent to B. Switch anyway?" — on confirm those replies go to B portably (text and tool calls), as per-turn model changes already do; the original journal keeps everything. Otherwise switch silently.
- [ ] **Durable in-flight queue delivery** (finding 3): a claimed follow-up/steering item stays persisted until its user record is appended; recovery restores undelivered work paused without duplicates. Crash-snapshot test, both lanes, one-at-a-time and all modes.
- [ ] **Whole pending-side draft** (finding 4): close, replace, quit and update move text, images and skills to the parent through one merge path; storage failures keep everything recoverable.

## Workstream 2 — content and rendering correctness (findings 7–10)
- [x] **Nested code fence identities** (7): collision-free leaf identity; Copy, display and accessibility match; streaming selection stable.
- [x] **Linear terminal Markdown matching** (9): ordered cursor; candidate-visit test proves linear growth; identity rules unchanged.
- [x] **Bounded syntax-state reads** (8): chunked lexer advance, shared state across lines, cancellation; read-size test with a 64 MiB first line.
- [x] **Empty MCP SSE priming events** (10): ignored; loopback fixture with arbitrary chunk splits, no duplicate tool calls.

## Workstream 3 — capture cleanup (finding 6)
- [ ] Batched/keyset garbage collection and streaming orphan checks; >100,001 chunks; failure mid-batch recovers; bounded memory.

## Workstream 4 — smoothness and loose ends
- [ ] **Soak pauses**: 264–539 ms graphics/font-cache waits (0.1.117 soak, seed `1790822043708`; a 122 s replay reproduces one at 431 ms). Profile, then reduce text drawn at once. Target: hour-long soak passes.
- [ ] **Last SwiftUI publish-during-update warning** (edit-a-question flow; HistoryEditTests.testEditingAQuestionScrolledUpToGoesToTheNewTurn).
- [ ] **Helper loose ends**: cancel a chat's older-rows load on close/unload; guard unload while a command awaits the load; resume retries instead of replaying from the start.
- [ ] **The unexplained HostDispatchTests trap**: Thread Sanitizer run of fill/older-rows/dispatch tests; a backtrace diagnostic in the gate.

## Workstream 5 — refactors, no visible change (after 1–4 merge)
- [ ] Composer state in its own @Observable owner (pilot).
- [ ] AgentSession's ~104 properties in groups, receipts first.
- [ ] Closed chats released at shutdown (task ownership), not ~2 minutes later.
- [ ] Narrower chat-change invalidation, measured with 5,000 records.
- [ ] A shared journal-format module for app and helper.
- [ ] The remaining ~84 poll-counting test waits moved to `eventually`.

## Before release
- [ ] Full gate passes (`scripts/check-next.sh gate`).
- [ ] Hour-long soak of a Release build passes, no exceptions.
- [ ] Every review finding's acceptance test from the review exists and passes.
- [ ] Owner checks: a minute with VoiceOver in the file viewer; one compaction against a real gateway.
- [ ] Release notes, including the new switch confirmation.
