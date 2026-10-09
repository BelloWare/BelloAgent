# BelloAgent 0.1.122 latest-main delta audit

Source audit of the changes from BelloAgent 0.1.121 to 0.1.122, dated 2026-10-09. Status below means source coverage, not runtime or native acceptance. No new builds or runtime checks were performed for this audit.

## Exact sources

- Fresh public `git ls-remote` main: `6319e368c6ddb7c3ef18605e78f23b1a5b69e63a`, tree `43ed6d8843a09b58fe00d436dd0e0c1a56c76972`.
- Previous source: `f4f80ddda3c27fac9e266896f69b725a06242e8f` (0.1.121).
- Delta: 36 reachable commits, 96 changed files, 7,486 insertions / 305 deletions. Release 0.1.122 build126; release head records verified public release. This audit did not independently rerun Swift release verification.
- Published Rust baseline: `4c4315bc7a8c9f36e59a1bb8992a33e5813fa830`. The loaded SearchCopy r2 candidate adds the latest occurrence-count contract and is still unpublished at this checkpoint. Its sealed patch SHA-256 is `1854a436e0bfc4c432c91b9831a1ceaf7271858ba96e3adcd13d90ec109ba368`; sealed binary SHA-256 is `1ccee19cbadf3dc6d42e4fcea96775454c17ebab347e1586c5ada84575820740`. Status of that candidate is distinct from published 4c4315bc.
- Full immutable `bd4e6ebb1fcf235a6d96701e8e56d620fd0864c0:rust/docs/MIGRATION-HANDOFF-2026-10-07.md` read. Its restrictions and invariants remain applicable; later Rust ledger entries supersede old feature-state rows.
- All Swift line references below refer to 6319e368; Rust paths start `rust/crates/`. [Immutable Swift source](https://github.com/BelloWare/BelloAgent/tree/6319e368c6ddb7c3ef18605e78f23b1a5b69e63a).

## Pending SearchCopy publication finding

Only additive occurrence-count contract changes directly affect the old loaded SearchCopy slice. `packages/swift-host/Sources/PiAgentCore/SessionReads.swift:107,114–120` returns count for every hit, counting non-overlapping Foundation case-insensitive ranges, advancing to the prior match upperBound; empty query count is zero. `apps/macos/PiApp/Storage/ConversationContent.swift:3–8,15–23` makes count optional with absent treated as one. The earlier r1 candidate lacked counts and stopped on the first match. Sealed r2 now supplies optional per-record non-overlapping counts with empty-query zero using its documented bounded portable Unicode matcher. Counts are not newly displayed in the old sheet, matching the unchanged Swift SearchCopy UI.

Loaded retained-text projection, 100-hit paging, 240-byte start preview, total-as-record-count, and copy concatenation are unchanged. The unopened `HistoryReader.swift:331–336` path only adds counts to nonempty-query hits and still differs in formatting/snippet behavior. Do not replace the loaded projection with the new sidebar index projection.

`ConversationContentView.swift` has no delta. Its reveal still calls `WorkspaceContent.swift:80–90` (also unchanged). Therefore the new Find/sidebar highlight, scoped tool-output expansion and navigation cancellation machinery is a separate slice, not a hidden requirement to expand old SearchCopy. ApplicationMenus.swift:163–172 gives Cmd-F to Find and Option-Cmd-F to SearchCopy; do not bind new SearchCopy to obsolete Cmd-F. Existing Rust Actions-menu access is a bounded adaptation.

Sealed r2 validation records show 32 focused all-feature tests and 651 app tests passed, zero failed, with three native tests ignored; format check, strict all-feature/all-target app Clippy and ordinary all-feature app build passed. Independent validation passed ten exact-module checks, 77,760 count differential cases and 20,250 match differential cases, killing eight mutants covering overlap, first-only counting, empty count, privacy projection, weak content fence, copy limit, active-stream inclusion and ignored cancellation. The source audit reviewed these records; it did not rerun their commands.

Actual desktop interaction evidence currently belongs to r1 only. Fresh r2 desktop interaction is pending and must not be inferred from unchanged UI wiring or passing GPUI test-platform tests. Native macOS IME, accessibility, clipboard and performance acceptance remain separate. Foundation matching equivalence is not claimed: Rust's documented portable normalization/lowercase is not Foundation locale matching. Full in-chat Find and sidebar content search remain missing separate workflows despite r2's count contract.

## Prioritized latest-delta parity matrix

### P1: Whole-chat Find and exact reveal

Swift: Transcript/TranscriptFind.swift:88–224; TranscriptHighlights.swift; Workspaces/TranscriptReveal.swift:3–106,109–187; TranscriptPage.swift revealContent/drawingMessageID; ApplicationMenus.swift:163–172; docs/transcript-reveal-api.md.

New behavior: Cmd-F in-chat bar; Cmd-G/Shift-Cmd-G and Return/Shift-Return step individual occurrences, wrap, Escape closes. 150ms debounce; paginated whole-chat search including unloaded history; incremental count with '+'; first match near reader. Source counts reconcile to rendered occurrences. Reveals unfold completed turns, open relevant tool card, distinguish its output/input occurrence, highlight drawn text and hold landing. Newest request wins; switch, manual scroll, Home/End, bottom and task cancellation cancel pending navigation; inaccessible match is shown honestly.

Rust: pending SearchCopy can search retained messages and reveal a uniquely identified message/owning tool card (`bello-agent-app/src/conversation_content_controller.rs:269–320`, `transcript_view.rs:748–787`), but no Find bar, occurrence stepping/highlights/render reconciliation, unloaded-journal search or this reveal lifecycle. Separate implementation required. Safety gates: scoped tool input/output IDs, identical text in multiple cards, stale result/newer navigation, short-chat final row, folded turns, invisible Markdown text, switch/retire/cancel, zero sends and no draft changes. Native shortcut/window focus and IME/accessibility acceptance remain separate.

### P1: Sidebar content search with privacy-preserving index

Swift: Storage/ChatSearchIndex.swift:97–168,193–301,309–355,390–539,598–668; Workspaces/SidebarSearch.swift:108–179,214–272,282–335.

New behavior: title search plus content match snippets; whole journal incremental/rebuild indexing, FTS5 trigram query (3–256 Unicode scalars), whitespace-collapsed/NFC prose and tool input/output; 32,768-character chunks overlapping 256. Excludes reasoning, execution/request-ledger/branch/compaction records. Opening selects exact hit via excerpt-context reveal; background answers are held while pointer/menu/drag protects row selection.

Rust: `sidebar_actions.rs:54–76` filters titles/topic titles only; no index/snippets. This projection intentionally includes tool input (unlike loaded SearchCopy), so do not share blindly. Safety gates: privacy permissions for new index; secure delete and WAL truncation retries (including blocked readers and reopen); deletion tombstones prevent stale indexing pass resurrection; generation-cancel query and stale open; transaction/revision lineage; branch/rewrite truncation; no private text logs; bounded memory; Unicode/short-query behavior. Preserve ownership/storage uncertainty rules; index is derived, never authority or replay source.

### P1: Last-activity sidebar ordering and interaction holds

Swift: Storage/MetadataStore.swift:678,735–750; Workspaces/WorkspaceActivityOrder.swift:3–55,58–97; WorkspaceTopics.swift removes reorder; SidebarGroups/Rows/Selection use new comparator.

New behavior: pinned first, then newest activity for pinned and unpinned; tie by ID. Activity changes on send/queue/edit/rewrite/run start-stop-finish, never per token. Family order follows newest member. Ignore old manual ranks. Freeze incidental order while pointer/menu/drag active; release on end/background; explicit pin/archive/topic/new-chat applies immediately. Next/Previous uses held visible order.

Rust: `bello-agent-core/src/workspace.rs:151–205` has no last_activity; comparator orders pinned by pinned_at ascending then sidebar_order descending. `bello-agent-app/src/sidebar_actions.rs:78–89` uses that comparator. Direct semantic mismatch with newest main, not merely missing UI. Needs durable additive metadata with older catalog byte-preservation, monotonic timestamps, shared visible order and metadata-conflict preservation; test concurrent activity/pin/topic/archive, held keyboard order, stale writes and no per-token churn. No need to port manual drag ordering, now removed.

### P1: Paused/interrupted status before opening after restart

Swift: Workspaces/WorkspaceRunHolds.swift:18–163; Storage/HistoryReader.swift:80–94,108–116,906–943; ApplicationLifecycle/WorkspaceShutdown flush holds after helper stop.

New behavior: durable run-hold summary ('active' shown paused after relaunch; interrupted kept distinct), corrected from journal tail off main thread; first-build bootstrap scans once; unknown read retains saved hold, no invented Ready; stop with queuePaused but zero queued work remains paused. Never resumes work. Journal is truth and current loaded state wins over delayed verification. Dirty write retries/flush bounded; bootstrap only after readable verification and committed holds.

Rust: loaded session recovery/queue pause exists, but `bello-agent-app/src/main.rs:2789–2803` defaults unloaded rows to Ready and no catalog run-hold cache exists. Adapt to existing Rust journal/inspection lease rather than reading Swift journals. Gate stop-empty/relaunch, interrupted/error, unopened rows, loaded-state race, unknown/truncated journals, failed saves, quit flush, zero replay/provider requests and writer-lock preservation.

### P2: Manual Mark as Unread and badge semantics

Swift: Workspaces/WorkspaceReadState.swift:5–24,40–95,123–130,174–185,218–253; ApplicationMenus.swift:114–116; sidebar menus/VoiceOver.

New behavior: persisted explicit unread marker, counts as one unread chat including Dock even after subsequent failure; cleared only by explicit reader opening/mark-read, not launch reopen or seeing a reply. Eligibility excludes archived, utility/test, unkept side and unsent New. Baseline-pending prevents existing history becoming newly unread when marked before first observation.

Rust: no unread-state model/manual action/badge found in app/core source. Needs full bounded read-state workflow (existing Swift unread behavior also unported), not just dot decoration. Gate recovery/store race, failure badge, launch vs deliberate focus, sides, archive/restore and native Dock/accessibility; no transcript bytes in metadata.

### P2: Durable draft marker

Swift: Workspaces/WorkspaceDraftMarks.swift:14–46; Storage/MetadataStore.swift:78–80,162,787–797.

New behavior: pencil/VoiceOver tracks committed draft writes, not keystrokes, restored with sequence arbitration. Includes nonblank text/images/skills, displaced edit draft or changed queued rewrite; merely opening rewrite is not a draft. Excludes ephemeral/unsent-new/utility chats.

Rust: durable text/displaced/queued-edit state exists in chat_navigation and DraftRecord, but no sidebar marker or committed-write observer. Implement against current supported draft types without claiming image/skill parity; preserve newer saves over launch snapshot and no false marker for uncommitted/failed writes. Gate marker transition-only redraw, recovered displaced text, unchanged vs changed queue edit, restore and failed/uncertain writes.

### P2: Durable recency tint

Swift: Workspaces/WorkspaceRecency.swift:12–51; DesignKit/PiKitRows.swift recencyLadder; RememberedSelection.recentChats.

New behavior: last16 durable opening IDs; selected/latest strongest, four preceding .75/.5/.3/.15 tints; based on opening order, not time/tokens. Parent passed through to a side is not an opening; manual focus during transition does count. Saved/reloaded, duplicate/stale/ephemeral IDs excluded.

Rust: selected-row accent only (`main.rs:2813`); no recency sequence. Needs additive selection metadata, clear distinction navigation/focus, preserve hover/marks/accessibility. Validate restart/rapid switch/deletion and side compatibility only when sides exist.

### P1/P2: Long-chat reading stability and first-page reach

Swift: TranscriptPage.swift:32–35,1141–1157 (prefetch max2400pt/3screens, directional), TranscriptReadingCoordinator.swift:108–134,171–223 (hold actual reading line including late wheel deltas), NativeTranscriptScrollView.swift:82–125; SessionReads.swift:19–39 and HistoryReader.swift:450–469 (edge=start full first-page index); TranscriptReveal.swift:73–104. Exact performance acceptance described in docs/perf/long-chat-scrolling.md.

Rust: existing virtualized retained transcript, logical row anchors/measurement preflight and pending reveal are substantial foundations (`transcript_view.rs:435–504,591–690,1296+`), but source architecture differs and newest Swift behavior has not been accepted in Rust by this audit. Rust retains messages in Session and expands visible window; do not transplant Swift paging blindly. Establish Home/Cmd-Up true first message and End, preserve reader line through variable-height remeasure/prepend/evict/late wheel; directional read-ahead where relevant; find near short-chat end must visibly land. Native same-hardware frame-time/jump/typing/resize evidence needed. Swift measured improvements are not evidence about Rust.

### P3: Narrow queue header and Git typing-layout fix

Swift: QueuePanelView.swift:254–271 gives status/hint their fitting width before flexible spacer; avoids wrapping 'Paused · 1' when enough room exists. GitPanel.swift:572–619,1230–1306 caches unrelated toolbar/amend/hint/button measurements while commit text changes; invalidates on inputs/scale/size.

Rust: current queue UI is different and needs narrow-width comparison; no full app Git panel matching this source workflow found. Treat as source UX/performance requirements, not code to copy verbatim. Native dimensions/pixels and component-level redraw counters would provide acceptance evidence; compilation alone is not.

## Scope and stopping point

This is a complete audit of newly changed functional areas, not a declaration of full application parity. Major preexisting migration work (production/native profile-vault/runtime acceptance, remaining tools/MCP, multimodal/skills/resources, multi-project/sides/import/export, remaining budgets/Inspector/Markdown/accessibility etc.) remains governed by current Rust ledger; the historical handoff is not a percentage. No build/runtime equivalence was attempted. Remote can move again; pin any new implementation and its evidence to a freshly rechecked main SHA.


## Recommended next slice: truthful unopened run status

**Current status: partial.** Loaded recovery exists; unopened sidebar status is missing. The first bounded slice should remove the false Ready fallback and hydrate only the presentation of existing Rust chats. Ordering, recency, unread and draft markers remain separate work.

The Swift persistence design is a separate `run-hold` record (`id`, `state`) plus `run-hold-bootstrap/v1`. A loaded display publishes `interrupted` before `paused` before `active`; active is presented as paused after relaunch. Journal verification uses a 256 KiB tail, one 4 MiB retry for unknown, and never guesses after failure. The bootstrap marker is written only after all required reads are known and hold writes have committed. The cache is a hint; journal/current display is authority. Flush occurs after helpers stop and is bounded to three seconds. These constants describe the Swift implementation, not an instruction to parse Rust journals using Swift's format.

A safe Rust first slice can obtain truth directly from already durable Rust checkpoints and journals via `bello-agent-core/src/session.rs:930–1023`, `SessionInspectionLease::acquire(...).snapshot()`. This API requires existing regular files and lock, verifies session UUID and supported schema, uses read-only journal replay and does not recover, create, checkpoint, start a provider or confirm durability. It refuses incomplete tails. A busy external writer or unreadable/missing/corrupt file therefore means unknown, not idle. Never substitute a new controller or an unprotected raw JSON read to get past the lock. Loaded controllers and their uncertainty fences always take precedence.

Suggested reservation: one new app-side unloaded-run-status module plus focused tests; narrow integration in sidebar rendering and launch/catalog adoption. Inspect one saved chat at a time off the UI thread, bound outstanding work, discard the parsed full session and lease promptly, and retain only a small presentation enum. Check chat ID, snapshot path, project/workspace identity, relevant catalog/load generation and shutdown before adopting results. New/materialization-pending chats should follow their known pending state rather than probing nonexistent files. A late inspection cannot overwrite a loaded chat or an explicitly changed status.

Projecting a persisted Running/active interrupted state must be display-only: label Interrupted or a truthful paused/interrupted presentation consistent with Rust recovery, but do not run recovery mutations, drain queues, execute tools, create a provider, query credentials, authorize roots, or set Resume. Error, pause with zero queue, pause with held/queued work, busy unknown and complete idle need explicit cases. Reuse existing recovery semantics rather than equating `require_idle()` with Ready: host-change idle intentionally permits stopped/failed sessions and is not a display classification.

An additional durable summary cache is an optimization, not required to make restart status durable: the underlying Rust session already is. If introduced later, use explicit versioned optional metadata and preserve old catalog bytes until an authorized mutation; write only from confirmed live transitions, retain dirty/uncertain state after failures, scope by session/path identity and validate against read-only truth. Do not mark bootstrap complete on unknown reads. Avoid new schema/mutation risk in the initial read-only correction.

Acceptance: reopen with stopped empty queue, held queue/edit, interrupted run and error; inspect unopened chats without changing checkpoint/journal/catalog bytes; zero provider/tool calls and no credential/native prompt; current loaded state wins; busy/FIFO/missing/corrupt/replaced paths fail closed without UI hang; cancellation/retirement/new project/newer status invalidate old work; lease released for later normal opening; bounded memory across many chats. Pure projection, lease filesystem, actual GPUI lifecycle tests and desktop interaction should be reported separately. Native macOS acceptance remains outstanding until actually performed.

## All 36 commits grouped by purpose

The list is exhaustive for `f4f80dd..6319e368`. Merge commits are integration history, not additional independent features. Test and documentation commits are evidence/support changes, not Rust acceptance.

### Product behavior: sidebar state, ordering and search

- [6d9988ef](https://github.com/BelloWare/BelloAgent/commit/6d9988efe742c24c220351b94f023788dc69a77b): Add Mark as Unread for sidebar chats
- [332ebce8](https://github.com/BelloWare/BelloAgent/commit/332ebce80112bffb970b13a3620c1eec048f0844): Show paused chats as paused after a restart
- [1bb49728](https://github.com/BelloWare/BelloAgent/commit/1bb49728896cd0b5de22013caa3e66d740d69553): Sort the sidebar by last activity, always
- [68375110](https://github.com/BelloWare/BelloAgent/commit/683751100f3bbd847df9b3da701d9753e499f3c3): Tint recently opened chats in the sidebar
- [03f06f46](https://github.com/BelloWare/BelloAgent/commit/03f06f46907b17278043f3ab95a64640dc9b0be6): Mark chats with an unsent draft in the sidebar
- [bef44b4d](https://github.com/BelloWare/BelloAgent/commit/bef44b4d017463419ab616c50e0d071a88fbc7a3): Search inside chats from the sidebar filter
- [73e8a252](https://github.com/BelloWare/BelloAgent/commit/73e8a252298f0bef476f424365a4182da465c9c6): Sidebar 0.1.122 follow-ups from the whole-change review
- [10027505](https://github.com/BelloWare/BelloAgent/commit/1002750551372fe83cf6f81136fb7b4f7186c491): Hold background search answers while the reader reaches for a row

### Product behavior: transcript navigation, scrolling and Find

- [95a17a1e](https://github.com/BelloWare/BelloAgent/commit/95a17a1e11a7e967fb993e69eee4c9bc48f7bf8d): Smooth long-chat scrolling: hold the reader's place, read ahead, reach the start; ⌘F find
- [652525e1](https://github.com/BelloWare/BelloAgent/commit/652525e17e108e1f5585203c4cc7a5d4f898389b): Cut the cost of the passes and long replies a long-chat scroll waits on
- [ae2036d3](https://github.com/BelloWare/BelloAgent/commit/ae2036d3067f70402fab09f7dbde23c158bc6f6a): Hold the reader's line through late wheel steps; reveal cancellation; scroll records
- [33f2dfd7](https://github.com/BelloWare/BelloAgent/commit/33f2dfd77d647178da05cc4f6d057bc4b15ae288): Hold the row being read, not one that barely reaches into the screen
- [2ce47806](https://github.com/BelloWare/BelloAgent/commit/2ce47806e8e331de99297dcfe6f96638f1a43aff): 0.1.122 final review: tool-output hits open at their result, deleted search text leaves the log, ⇧⌘G
- [114ff911](https://github.com/BelloWare/BelloAgent/commit/114ff9119ff09b1babc1c16c956f550e642cea79): Offer ⇧⌘G to the chat's window without waiting for it to win the keyboard
- [3772728e](https://github.com/BelloWare/BelloAgent/commit/3772728eefa20be67d3d1beed191a956305e8244): Let find land in a short chat: a held opening question is not a landing

### Product behavior: local layout cost and queue width

- [97c43aa5](https://github.com/BelloWare/BelloAgent/commit/97c43aa5f9adce1636acda81004b449feec51a5e): Measure only the commit message on a keystroke in the Changes panel
- [53f18014](https://github.com/BelloWare/BelloAgent/commit/53f180141c87d381128a5188a35a6c021a299552): Keep the queue header's status on one line when its words fit

### Test-only correction

- [2a678e9c](https://github.com/BelloWare/BelloAgent/commit/2a678e9cc36c4cd94b2c2d6f36c9da6f42aba2f0): Await the search before unwrapping its hit in the reveal test

### Planning and recorded validation

- [9ed04860](https://github.com/BelloWare/BelloAgent/commit/9ed0486095dce772134d70d56ed4f98f6415ffeb): Plan 0.1.122: mark as unread, paused after restart, last-updated order, search inside threads
- [5f93527e](https://github.com/BelloWare/BelloAgent/commit/5f93527ef5806f8ae55bbdd062c0f057b068dd9b): Add smooth long-chat scrolling to the 0.1.122 plan
- [8b78963e](https://github.com/BelloWare/BelloAgent/commit/8b78963ebc30a73eca9b0a6369904d5f00373adb): Add recency-tinted sidebar rows to the 0.1.122 plan
- [83b0c9b7](https://github.com/BelloWare/BelloAgent/commit/83b0c9b7ededb6b6ad42a3db462c69674073d917): Add the draft indicator to the 0.1.122 plan
- [6513ac56](https://github.com/BelloWare/BelloAgent/commit/6513ac56a6a122ff87c1406c06474bda185988d3): Record the Release confirmation of long-chat scrolling

### Release metadata / verification record

- [3d2d854e](https://github.com/BelloWare/BelloAgent/commit/3d2d854e3587fe549329e327a45360fb2348db56): Release Bello Agent 0.1.122
- [6319e368](https://github.com/BelloWare/BelloAgent/commit/6319e368c6ddb7c3ef18605e78f23b1a5b69e63a): Record verified public Bello Agent 0.1.122 release

### Merge / integration history

- [09b17277](https://github.com/BelloWare/BelloAgent/commit/09b172775dc553cff166b92c66cda4afb2a7142e): Merge sidebar search inside threads
- [a185856b](https://github.com/BelloWare/BelloAgent/commit/a185856beb8e653dabf708f1a15374bf759fea93): Merge origin/dev/next (sidebar content search) into dev/sidebar
- [c4ea3a5b](https://github.com/BelloWare/BelloAgent/commit/c4ea3a5be2f7d1595049ef639eae8692100cc211): Merge sidebar: mark unread, paused after restart, last-activity order, recency tint, draft marker
- [c91998f8](https://github.com/BelloWare/BelloAgent/commit/c91998f876c512f51bb18dce6c9da56f93b2a0cf): Merge: hold background search results while the reader reaches for a row
- [f40e1aa7](https://github.com/BelloWare/BelloAgent/commit/f40e1aa779b821f8b11fc0e477a18fe37d7c5e51): Merge dev/next into dev/scroll; sidebar search reveals through revealInTranscript
- [84a2ee01](https://github.com/BelloWare/BelloAgent/commit/84a2ee01c788792abb6c9cd052e0f58cddf2b19b): Merge: typing in the Git commit box measures only the message
- [5cec4206](https://github.com/BelloWare/BelloAgent/commit/5cec4206d093a6726cb51d7b83a0fe4a28f5b828): Merge long-chat scrolling: hold the reader's place, read ahead, reach the start; ⌘F find
- [a5509e5f](https://github.com/BelloWare/BelloAgent/commit/a5509e5f7d2134faecf3d19083c8f67a5619c9e7): Merge dev/fix122: Codex final-review fixes
- [ae78fa6b](https://github.com/BelloWare/BelloAgent/commit/ae78fa6bc9a7c199ddc1f5b438bfc661161ac39e): Merge dev/queuehdr: the queue header's status keeps one line when it fits
- [065d288b](https://github.com/BelloWare/BelloAgent/commit/065d288b027adcecec7a53c15ce21179914f8b29): Merge dev/findland: a find match near the end of a short chat is shown
- [151321cf](https://github.com/BelloWare/BelloAgent/commit/151321cf75d80d9488226c6f45ba721db5083c62): Merge dev/next for Bello Agent 0.1.122

Release version/project-file changes, release notes, Features/Design updates and source test suites support the workflow groups above. They do not independently prove Rust implementation, Swift/Rust matching performance, native input/accessibility or credential acceptance.
