# Bello Agent 0.1.135 — Codex-style sub-agents, and finished turns that fold

Status: **released and verified 2026-10-28.** Marketing version 0.1.135, build 139. Previous public release: 0.1.134/build 138.

## Owner request

- 2026-10-27, after the lead compared our sub-agent messaging with Codex and Claude Code: "I like codex style of how sub and main communities, and sub agent can talk to each other if that's how Codex is implemented, but sub agents cannot spawn sub agent directly, only main agent can. And sub agent can start with full context with handoff. Let's try to follow codex style more".
- The lead's design v4 follows Codex 0.164's V2 multi-agent tools: `spawn_agent` (main chat only), `send_message` (queue only), `followup_task`, `wait_agent` (10 s–1 h, default 30 s), `interrupt_agent` and `list_agents`. Names are `/root/<task_name>`. A sub-agent forks the main chat's whole context by default, plus a hand-off in its first `NEW_TASK`. Siblings can message each other. Messages use Codex's text envelope with every payload line indented, and the whole `FINAL_ANSWER` reaches `/root` after every turn, bounded at 1 MiB.
- Kept from ours: the family wait, crash-safe delivery, the shared cost limit and 16 slots. The explicit-request-only delegation rule stays; Codex's wording replaces ours. Codex's mid-reply cut-in is deferred to an owner decision after the release.
- 2026-10-28, on 0.1.131, while the release waited for its build: "when the message finishes, when I was trying to scroll up, I still see intermediate tool results, even though they should be hidden. But if I scroll up further, they will be hidden... the expected behavior is that I don't need to scroll up to load more to have the tool result being collapsed. It should be collapsed by default. ... See if your recent release will actually fix that. If not, please include that fix as well and then release a new version."

## Change

- **Helper, `dev/a135-agents`** (Astra; record `a135-agents-0.1.135.md`), merged as `41e0d653`.
  - Commits: contract `114cd880`, runtime `6d99dbd8`, validation `c743816a`, lead-review fixes `c1c48ad1`.
  - Durable v4 records: marker `pi-app.native.v4` with one-way promotion, capability `subagents-codex-v4`.
  - A chat whose sub-agents ran on 0.1.135 is refused for continuation by 0.1.134. This was checked with the real 0.1.134 binary, with and without a valid version-2 `.meta`.
- **Lead review of the helper** (findings F1–F5), all fixed in `c1c48ad1`:
  - **F1 (P1):** fork-seed bodies were stored in the parent's agent-operation row, plans and checkpoint. A context over 32 MiB made `spawn_agent` fail, and every app scan decoded them. The records now hold only a reference: from, cutoff, ids and a digest. The bodies stay in memory until the child journal holds them, and recovery rebuilds them from the parent's context or fails closed. For a 4 MiB context with 4 forks, the operation row went from 4,195,646 to 1,238 B and the checkpoint's helper JSON from 33.5 MB to 9.6 KB.
  - **F2 (P2):** the global checkpoint version is back to 2, and a family-scoped gate covers the new derived state.
  - **F3–F5:** no `/root` fallback for an unnamed child sender; VT/FF are treated as line breaks in envelopes; added v4 cost-limit pause and Resume cases.
  - **Lead decisions:** keep the root notice for an undelivered running task, the `list_agents` cursor, the `subagent.list` detail modes and the description derived from the message.
- **App, `dev/a135-agents-ui`** (Astra; record `a135-agents-ui-0.1.135.md`), merged as `a3575eef`. Names everywhere; one card per agent tool; typed message, task and final-answer rows; queue-only mail to idle agents; the inherited context folded into one row that loads when opened. v3 and v1 history keep their old presentation.
- **Lead commit `1eb7be60`:** NEXT-RELEASE wording.
- **Gate fixes, `dev/a135-gatefix`** (Astra; record `a135-gatefix-0.1.135.md`), commit `de387346`, fast-forward:
  1. **Regression since 0.1.132, shipped in 0.1.132–0.1.134.** Reading a chat's sub-agent model grants started a model-catalog load as a side effect. Context-preview inputs include those grants, so when the catalog landed, the app threw away the first context count after launch, and the Inspector asked for a refresh. Grant reads are now pure, and previews await the shared bounded load. Session opening starts the load in the background, keeping 0.1.132's guarantee. A notification that grants changed no longer creates a hidden transcript for an unshown saved side.
  2. A helper test still looked up the v3 tool `subagent_start`; it now looks up `spawn_agent`.
  3. Gallery scene 11i assumed the expanded system prompt and tool schemas fit on one page. The v4 `/root` instructions make the prompt 2.3K chars, so the scene now waits for loaded expansions and checks the schema's end on screen.
- **Finished turns fold, `dev/a135-turnfold`** (Astra; record `a135-turnfold-0.1.135.md`), commits `1a7e29e5` and `92ec7256`, fast-forward.
  - **Cause.** 0.1.133 (SCROLL-1) made history pages whole turns, which fixed the report for older turns. The live snapshot still holds three turns or sixty rows (`HistoryWindowPolicy`). A new chat, or a branch adopted fresh after an edit, whose turn passes sixty rows first reaches the app without the turn's question. The fold hides a turn's work only when the question is on the page, so the finished turn showed every call until the reader scrolled up and a read brought the question in. This was SCROLL-1's Known item 3.
  - **Reproduced on `a20a317f`:** a late-observed new chat, a fresh edit/resend branch, and a cut finished turn before a newer running turn, through the scripted host and the real helper with a loopback gateway (sixty local reads). The early-observed controls passed.
  - **Fix.** When the cut first turn has finished (also when a newer turn is already running, and on first presentation), the app makes one automatic whole-turn read (`loadHistoryPage(completingTurn:)`). It adopts only that turn's missing rows, within the resident caps, with ordinary paging's source checks and the reader's anchor. Removing the footer's "Partial history" note would have moved a following reader's answer down 18 pt, so that height is held below the footer until the next tail. Opened folds stay open, and a running turn keeps every row. The helper, the wire and the snapshot are unchanged; tokens add only a constant check.
  - **Lead review** (round 2, `92ec7256`): a turn that cannot be completed is read once per generation and boundary, where it had been read again on every new row of a newer turn (6 reads → 1 in the new test); an errored boundary waits for the reader's Retry. Round 1's room held above a short finished turn was removed, so a short turn lays out from the top exactly as one folded with its question on the page.

## Validation

Toolchain: macOS 14.8 (Tart VM, Apple Silicon), Xcode 16.1, XcodeGen 2.44.1.

- **Workstreams** (details in their records):
  - helper: 315 focused tests, wire 41 / concurrent 4 / acceptance 3, two streaming modes, 44 v4 and 21 v2 crash edges, 60 mutations caught;
  - app: 297 passed and 1 optional skip, with `SubagentPerformanceTests` failing as below; 62 gallery images reviewed by the lead.
- **Full gate on `1eb7be60`** (`scripts/verify-release.sh`, 199 min):
  - passed: helper-cost 5, wire 41, concurrent 4, acceptance 3, python 150, views;
  - failed: serial lane 12 tests plus one watchdog abort; parallel lane 12 of 2,034; helper 2 of 1,244; gallery scene 11i.
  - Every class ran about twice as slowly as in the 0.1.130 and 0.1.133 gates. From 14:16 that day the Mac had an active screen capture (`replayd` at about 85% CPU even when idle; it restarts at once when stopped).
- **Triage** (logs `build-lead/rerun-135`, `build-ab134/logs`, `build-ab134/logs133`): every failed class was run alone, then on `b2fb1347` (dev/next just before AGENTS-1) and on `6dbaa1d4` (passed the 0.1.133 gate on 2026-10-26):
  - **load flakes, passed alone:** CompactionResponsiveness, ComposerPasteLifecycle (the watchdog abort), SubagentDeletion, SubmissionPersistence, WorkspaceRace, DecodeSpan;
  - **regression since 0.1.132**, failing on `b2fb1347` and `1eb7be60` and passing on `6dbaa1d4`: AutomaticContext (7), PreparedContextLifecycle, PendingChatProject, MetricsFooterControl, BudgetOwnerUnload. Fixed as item 1;
  - **AGENTS-1 test premises**, failing only on `1eb7be60`: helper ContextPreview and gallery 11i. Fixed as items 2 and 3;
  - **machine conditions:** SubagentPerformance (405 row visits), HistoryEdit (an empty row moving −98 pt), PayloadNativeParity (resources sheet heights and pixels), LongChatScroll (fling or scroller) and TranscriptBugRegression's wide-issuer yields. These failed the same way on `6dbaa1d4`, which passed them the day before, so they don't come from this release's code.
- **Gate-fix branch** (Astra, on `de387346`): AutomaticContext 13, PreparedContextLifecycle 6, PendingChatProject 24, MetricsFooterControl 4, BudgetOwnerUnload 8; SubagentModelGrant 4, ModelCatalogEndpoint 23, ConnectionSettingsFlow 7, ModelSwitch 24; SidebarAskConnection 10, SideBudgetIntegration 18, WorkspaceRefreshLifecycle 40; helper ContextPreview 8; the whole gallery 1 (238 captures). Two mutations caught.
- **Turn-fold branch** (Astra): failing-first 3 scripted + 2 real-helper cases; round 1, 435 app tests in 33 classes plus 27 Python fixture tests; round 2, 161 passed in 13 classes (WorkspaceRefreshLifecycle 48, LongTurnPaging 9, TranscriptTurnFold 26, StreamedReplyEnd 8 + 1 optional skip, native document/scroll classes; StreamingDeliveryCost 4/4 three times). Mutations caught: the fill disabled, the footer hold removed, the one-read memo removed. Gallery light/dark/narrow inspected by Astra and the lead.
- **Lead, affected reruns on `92ec7256`** (`build-lead/affected-135b`), every class alone: 24 classes passed, 0 failed, 2 optional skips: LongTurnPaging 9, WorkspaceRefreshLifecycle 48, StreamedReplyEnd 8 (+1 skip), TranscriptTurnFold 26, TranscriptPaging 11, HistoryTurnPaging 6, HistoryExtent 26, FreshPresentation 21, TranscriptOpeningFill 11 (+1 skip), HistoryEdit 3, MessageVersionTranscript 8, WorkspaceLoading 13, HistoryEdge 16, TranscriptReveal 12, TranscriptFind 12, TranscriptIncremental 12, WorkspaceRace 65, WorkspaceConcurrency 12, NativeTranscriptDocument 10, NativeTranscriptScroll 5, TranscriptStreamingScroll 3, TranscriptKeptRows 10, TranscriptWidthChange 6, TranscriptGeometryCache 7. LongChatScroll passed 6/6 this time, with `replayd` at 94% CPU.
  - `StreamingDeliveryCostTests.testRefreshRoundTripOccupancy` failed 1 of 3 runs (301 projection visits in one delta). Lead A/B, ten runs each (`build-lead/delivery-ab`): as built 4/10 and 2/10 failed; with the turn fold's only call on that test's path removed, 2/10. So the failure predates this change. It passed in the 0.1.130 and 0.1.133 gates and in the 0.1.135 gate run on `1eb7be60`. Likely cause: the chat's accounting read lands about 100 ms after the first page and invalidates the presented projection mid-loop, more often under load.
- **Lead, affected reruns on `de387346`** (`build-lead/affected-135`):
  - app 257 passed, 0 failed, in 20 classes: the five context classes, SideBudgetIntegration 18, SubagentModelGrant 4, ModelCatalogEndpoint 23, ConnectionSettingsFlow 7, ModelSwitch 24, SidebarAskConnection 10, WorkspaceRefreshLifecycle 40, Side 17, SideKeepRecovery 15, SideKeepOrdering 12, SideRowPresentation 1, SideRelaunch 3, SideBudgetInspectorLifetime 2, CostLimit 21, CostPauseFamily 5; helper ContextPreview 8/0;
  - machine-sensitive classes, with `replayd` at 83% CPU: HistoryEdit 3/0 this time; SubagentPerformance (1), LongChatScroll (2), PayloadNativeParity (15 assertions) and the wide-issuer yields (2) failed again with the same signatures as on `6dbaa1d4`.

## Known

- Machine-sensitive classes (SubagentPerformance, LongChatScroll, PayloadNativeParity, the wide-issuer yields) are still to be confirmed on a quiet machine.
- **Folded rows keep one-point slots**, so a folded sixty-call turn leaves about 200 pt of blank between its fold line and its answer (193 folded rows in the gallery scene). This predates 0.1.135; the fix is planned for 0.1.136.
- `StreamingDeliveryCostTests.testRefreshRoundTripOccupancy` fails its projection-visit assertion (301 visits) in about 2–4 of 10 isolated runs on this machine, with or without the turn-fold change (see Validation). It is a test-timing issue, still to be fixed in the test.
- A turn larger than the resident window (3,000 rows / 24 MB) can still stay cut and unfolded, as decided in SCROLL-1.
- P3 follow-ups:
  - a completed `wait_agent` card still reads "Waiting for agents";
  - a final answer's bounded preview cut at a code block shows an empty frame (an older component);
  - `requirePublished` reads the whole child journal at each open or follow-up;
  - `HostService.rebind` guards only the child marker (predates this release).
- Deferred to the owner: Codex's mid-reply cut-in.

## Release

- Release commit `78869fab` ("Release Bello Agent 0.1.135"), tag `v0.1.135`, on `main` and `dev/next` (`e7bc9790` merges `dev/next` into `main`).
- `BelloAgent-0.1.135.dmg`, sha256 `b1a40adaca5f36fe5ae9220c4d90e69a68d5f800b2bb5f0abea11d0e7d50fb9b`, 17,315,814 bytes; Developer ID signed and notarized (app submission `9b916929-78d7-4e38-acd8-8a8f19fe493f`, DMG submission `fbe6be03-49d4-42ba-8844-953e3c73a7c3`, both Accepted), stapled.
- `validate-release.py --previous-build 138`: passed (0.1.135 build 139, Ed25519 signature verified).
- Website commit `e798de7` (belloware.com `main`).
- `verify-published.py`: the public DMG matches, and the Bello Agent and legacy Pi App feeds are byte-identical. The site took about seven minutes to deploy this time; until then the feed still served 0.1.134.
