# Source-backed migration ledger

Baseline: Swift tree at `435c4c8a3` (2026-10-04 checkout). `AGENTS.md` and
`NEXT-RELEASE.md` were read; the explicit Rust-branch request supersedes their
Swift next-release branch/native-only instructions. Swift files and release
assets are unchanged.

This is a **vertical slice, not feature parity**. The broad product inventory
below is deliberately unweighted: passing tests do not equal completed features.
A working Responses chat is materially smaller than the source application.

## Current audit: 2026-10-05

Remote `rust` was fetched at `5f2df967a09d68c0019b624b0f3d3eb2c8cb5d9b`.
Fetched `main` remains `435c4c8a37072a3ce10229195d4dc39a2a43d976`; its
`apps/macos` and `packages/swift-host` trees match the Rust branch's original
source exactly. The reported recovery commit `82cd6d631f2aa3228983f70aeac0b6c782a625ef`
is not present in this fresh clone. No old workspace or uncommitted work was
overwritten, and no missing recovery implementation is assumed to exist.

Status vocabulary: **missing** means not wired into the Rust product;
**partial** means only a subset is implemented; **implemented** means source
and applicable tests exist for the stated scope; **validated** always names
the check actually run. Historical “unported” entries below mean **missing**.
No whole product capability is desktop-validated by this audit.

Current local baseline: `cargo test --locked -p bello-agent-core` passes **77**
tests (43 unit, 9 chat-workspace, 2 runtime, 18 tool-fixture, 5 transport).
`cargo clippy --locked -p bello-agent-core --all-targets -- -D warnings` and
`cargo fmt --all -- --check` pass with Rust 1.99.0. The tests use synthetic
data and loopback requests, not user sessions or a real model endpoint.
This is **validated core behavior**, not desktop interaction or full workspace
validation. The starting commit also has a successful historical full Linux
[CI run](https://github.com/BelloWare/BelloAgent/actions/runs/37181474816).
The current `cargo test --locked --workspace` attempt compiled the app's Rust
code but failed at native linking because `xcb`, `xkbcommon` and `xkbcommon-x11`
development libraries are unavailable locally. It did not run app tests.
`cargo clippy --locked --workspace --all-targets -- -D warnings` passes for
the queue presentation candidate, including the GPUI app and its test code;
this type-check does not establish a linked executable or UI behavior.

The next small slice restores queue presentation from `QueuePanel.swift`:
edit/failure/pause timing precedence, stable steering/follow-up grouping,
follow-up numbering, original row/header sizes and a 3.5-row scrolling cap.
Five pure presentation regression tests pass independently of GPUI. Source
response-boundary wording is retained where Rust has no production tool batch.
This is **implemented presentation policy / partial queue UI**. Actual pixels,
minimum-window overflow, drag reorder, queue details and native interactions
remain unvalidated or missing; adaptive room budgeting is not yet ported.

### Verified integration checkpoint

Queue commit `899b047cd810202aa5c735daf1444b290fa6ee28` is published on `rust`
and its exact [Linux CI run](https://github.com/BelloWare/BelloAgent/actions/runs/37260181436)
passed. Local linking was subsequently recovered using workspace-local linker
aliases for the preinstalled runtime libraries; no system settings or packages
were changed. All **89 workspace tests**, strict all-target Clippy, formatting
and native Linux build pass. These app tests are headless presentation/lifecycle
tests, not desktop interactions; macOS and screenshots remain unverified.

Both shared dependencies now pin the published BelloBox commit
`db679011ced3dd5f5c73a577d9f938fd44d9294b`, whose exact
[Linux CI run](https://github.com/BelloWare/BelloBox/actions/runs/37260219509)
passed. Compared with the previous pin, the shared-crate source delta is only
`bello-workbench/src/editor.rs`: unselected Backspace/Delete treat CRLF as one
newline, preserve Unicode neighbors, restore original bytes/caret through undo,
and leave read-only text/caret unchanged. Explicit selected ranges stay literal.
The shared UI crate is unchanged. The lockfile changes only these two Git pins;
no registry versions, workflows, release artifacts or source Swift code change.

Paths in the source column are relative to the repository root. Core source
paths begin `packages/swift-host/Sources/PiAgentCore/` (abbreviated `Core/` below).
Native UI paths begin `apps/macos/PiApp/` (abbreviated `App/`).

| Capability | Source inspected / implementation reference | Rust state / verification |
|---|---|---|
| Profile validation and endpoint normalization | Core/Profile.swift; Core/Profiles.swift | Implemented subset in profile.rs; HTTPS/loopback, capacities, identity, headers tested. Unknown profile options rejected |
| Source-only LiteLLM Responses requests | Core/Providers.swift requestBody / complete; Core/ResponsesInput.swift | Implemented text subset. stream/store, correlation, cache key, output budget versus cap tested over loopback HTTP |
| Reasoning effort and model overrides | Core/Profile.swift overriding; Core/PiProviderRules.swift | Partial. Captured model/effort, default/off and explicit effort supported. Catalog-specific maps/routing contracts not ported |
| Incremental SSE framing | Core/Transport.swift SSEParser | Implemented with split UTF-8, BOM, LF/CR/CRLF, multiline and safety bounds; all byte-boundary tests |
| Stream text/refusal/reasoning/tool metadata | Core/Providers.swift ProviderAccumulator | Implemented decoder subset, indexed fallback and argument ordering tested. No tools executed |
| Terminal/JSON/errors | Core/Providers.swift result / complete | Implemented terminal requirement, JSON fallback, incomplete reasons, bare gateway failure, error redaction tested |
| Cancellation / partial reply / retry | Core/SessionRun.swift interruptedPartial; Core/SessionQueue.swift retryRun | Implemented vertical slice. Transport cancellation, partial replay exclusion, retry identity tested. Actor Stop→edit→Save→Retry→follow-up→reopen regression tested |
| Transient retries/backoff | Core/SessionRun.swift completeWithRetries | Unported. Explicit user Retry only; no hidden paid retries |
| Conversation state persistence | Core/SessionPersistence.swift; Core/SessionJournal.swift | Independent plaintext Rust snapshot + generation-scoped delta journal. Exclusive lock, synced atomic checkpoints/append, stale identity, torn-tail, rollback and capacity/recovery tests. Not Swift journal compatibility; see storage/privacy boundaries below |
| Swift/Pi journal import/portable preview | Core/HostService.swift session.import / recover; Core/SessionReplay.swift | Unported. Explicitly refuses automatic journal migration |
| Follow-up and steering queue | Core/SessionQueue.swift | Partial. Separate lanes, steering at response boundaries, queue limits, captured model/effort, pause/resume, reorder core API. All-at-once mode not ported |
| Durable queued editing | Core/SessionQueueEdit.swift | Implemented hold/save/cancel/remove and idempotent identity subset. Both lanes held, restart retains hold; tests. Source revision-basis/outcome pruning not ported |
| Queue presentation | App/Workspaces/QueuePanel.swift | Partial. Bounded/collapsible panel, timing labels and full-text editing. Drag reorder and all detail controls not ported |
| Images/attachments/image-only submissions | Core/PiImage.swift; App/Composer/Attachments.swift; Core/SessionQueue.swift validate | Unported. Attachment control unavailable; transport currently accepts text only |
| Built-in tool definitions/execution | Core/Tools.swift; Core/SessionTools.swift; Core/SessionRun.swift | Production unported. Fixture-only ls module + bounded/cancellable executor now implemented; no tool definitions sent or executed by Controller, no fabricated result |
| MCP lifecycle/invocation | Core/MCP.swift; Core/HostService.swift mcp.* | Unported |
| Skills and resource resolution | Core/Resources.swift; Core/HostService.swift resources.* | Unported |
| Project instructions and instruction precedence | Core/Resources.swift; Core/SessionRun.swift; Core/HostService.swift | Missing in production. Provider supports an instructions argument, but runtime.rs passes an empty string; no project instruction discovery or skills UI is implied |
| Compaction / context preview | Core/SessionCompaction.swift; Core/CompactionPlanner.swift; Core/ContextPreview.swift | Unported; no claim that local context budgeting is complete |
| Historical message edits/versions | Core/SessionVersions.swift; Core/EditReplayPlan.swift; Core/MessageVersions.swift | Unported |
| Branch/fork/side conversations | Core/SessionBranching.swift; Core/SessionSide.swift; Core/SessionPersistence.swift | Unported |
| Multiple projects/topics/chat organization | App/Workspaces/WorkspaceModel.swift; WorkspaceTopics.swift; WorkspaceTabs.swift | Partial: independent chats in one explicitly selected project, existing New Chat/sidebar controls, draft/selection persistence and deferred creation. Projects manager, multiple roots, topics and organization remain unported |
| Native transcript/composer | App/Transcript/; App/Workspaces/ComposerInput.swift | Partial source-matched GPUI shell/transcript/composer with shared IME-aware proportional input, source tokens/geometry, adjacent pane, source Enter/Shift-Enter intent, persisted sidebar/split resizing. Markdown/links/rich tool cards and many interaction surfaces remain unported; initial transcript window explicitly paged |
| Quick Open / adjacent file tabs | App/Files/QuickOpen.swift; App/Files/QuickOpenPanel.swift; App/Files/WorkspaceQuickOpen.swift; App/Workspaces/WorkspaceTabs.swift | Source-shaped Ctrl/⌘P popup, bounded background fuzzy search, :line, recent files, independent file tabs and dirty-close flows. Core/lifecycle tests pass; latest native interaction QA pending |
| Shared folder browser | App/Files/; App/Workspaces/WorkspaceView.swift RightPane | Reuses BelloBox bello-workbench-ui; lazy/background filesystem work. See shared ledger/tests for limits |
| Shared Git changes/history/diff | App/Git/; NEXT-RELEASE.md D1/D8 | Partial shared workbench reader. Source commit scopes, reword, blame parity not established |
| Shared file editor and Vim | App/Files/ | Uses shared Rust editor and per-file opt-in Vim subset (Ctrl/⌘AltV or file actions). Independent text drafts, save/external-conflict/dirty-close protections. New Vim feature, not full Vim compatibility; final native QA pending |
| Multiple terminals / PTY | App/Workspaces/TerminalPanel.swift; App/Terminal/ | Unported |
| Native vault / settings transaction | App/Storage/; App/Workspaces/ProfileSettings.swift; ConnectionSettingsController.swift | Unported. Explicit stdin-only in-memory credential entry point; no credential discovery or persistence |
| Model catalog / onboarding probe | App/Workspaces/ModelCatalog.swift; GatewayModelDiscovery.swift; Core/ConnectionProbe.swift | Unported. CLI profile supplies model and capacities |
| HTTP capture / retention / inspector | Core/TraceStore.swift; App/Inspector/; App/Storage/CaptureArchive/ | Unported. Only redacted errors and optional content-free CPU telemetry |
| Usage / spend / cost limits / reports | Core/SessionCost.swift; App/Dashboard/; App/Workspaces/CostLimit.swift | Partial raw provider token display only. Billing rates, totals, budgets, dashboards unported |
| Webhooks / completion sounds / menu bar | App/Workspaces/WorkspaceWebhooks.swift; CompletionSound.swift; App/Dashboard/MenuBarMetrics.swift | Unported |
| Helper JSON protocol / process supervision | Core/HostService.swift; packages/swift-host/Sources/PiHost/Main.swift; App/Host/ | Unported. Rust in-process single-session actor, no Swift-compatible IPC claim |
| Accessibility / shortcut parity | NEXT-RELEASE.md A1; App/Design/; App/Application/ | Partial GPUI keyboard/text handling. AX tree, VoiceOver, app-wide shortcut audit not validated |
| macOS distribution / Sparkle update / signing | project.yml; docs/Release.md; App/Application/UpdateController.swift | Missing/unverified. Original Sparkle 2.8.1 includes configured check policy, active-work/install barriers and draft-flush failure handling; Rust has no updater integration. cfg-selected macOS storage path only; no release/tag/feed/assets changed |
| Performance vs Swift | README.md prior validation; docs/validation/ | Measurement hooks implemented; same-hardware baseline and sustained latency comparison pending. CPU callback timing is not frame presentation |

## Latest incremental slice

[Two-chat/durable-draft and ls-groundwork scope](multichat-and-tools-checkpoint.md)
records the newest implementation and its limits. Production model tools remain
disabled. Latest multi-chat native interactions are not yet visually verified.

## Storage and privacy

The source session journals and native metadata are plaintext; credentials use
Keychain. New HTTP captures are plaintext-v2, with a legacy encrypted reader.
The Rust slice has its own plaintext storage and no native vault/capture/import
parity. See [the source-backed storage and privacy contract](storage-and-privacy.md)
for isolation, durability, format, permission, recovery, and backup limits.

## Verification record

- Initial exact-source isolated core workspace: 16 unit tests + 5 loopback
  transport tests passed (2026-10-04 02:55 UTC).
- Integrated Rust workspace: 18 unit + 2 actor/lifecycle + 5 loopback transport
  tests passed, and native GPUI application built (2026-10-04 03:12 UTC).
- Strict Clippy (`-D warnings`) and rustfmt checks passed on the first integrated
  slice. The integrator records final pinned-build checks and screenshots.
- Corrected source-based native shell rendered on Linux software Vulkan. Native
  QA passed typing, draft-preserving Close/Keep working, Return-to-Send and a
  real local fixture SSE response. Original Swift pixel comparison and complete
  macOS interaction remain unverified. Dark/minimum-size/reflow review continues.
- Two source-geometry/stale-layout-write tests bring the workspace total to 27
  passing tests as of 2026-10-04 03:35 UTC.
- Snapshot publishing is event-driven; disk commits and commands run off the UI
  thread. The interrupted-worker race and async-runtime-drop regression are covered.
- Final journal core: 34 unit + 2 actor/lifecycle + 5 loopback transport tests
  passed (2026-10-04 04:56 UTC). Independent review cleared interruption-capacity
  admission, held-edit recovery reserve, and uncertain first-journal creation.
- Quick Open presentation/search generation and file-tab save/close lifecycle
  have unit coverage. Latest native Quick Open, dark/minimum-size, wrapping,
  and file-tab interaction validation is blocked by the disconnected desktop.
- No real gateway, paid model call, user credential or source-app storage used in
  automated validation.

- Multi-chat/draft development candidate: 84 workspace tests, strict Clippy,
  rustfmt and native build passed on 2026-10-04 05:53 UTC. Final identities,
  race fixes and unverified native interactions are recorded in
  [the validation record](validation/multichat-2026-10-04.md).

## Next implementation priorities

1. Preserve the existing UI before extending it: equivalent-state dark/light,
   minimum-size and responsive split/composer checks; close gaps recorded in the
   independent UI checklist. Continue repeated Send/Stop/Retry, queue-hold and
   reopen interaction checks.
2. Validate the new two-chat/durable-draft slice, then add source Projects
   management, bounded display eviction and remaining organization semantics.
3. Port guarded tool execution, MCP, resource/skill loading, compaction and replay
   semantics from their source tests. Do not expose unsupported controls early.
4. Add native credential vault/settings and source-backed migration/import.
5. Close Git/editor/terminal/rich transcript/usage parity and platform behavior.
6. Establish equal-workload Swift/GPUI latency and memory baselines on the same
   hardware, then optimize measured bottlenecks and regressions.
