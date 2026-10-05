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

The subsequent shared integration advances both pins together to
`ee0d27a89aa52524c29b2be5937716b5e799e748`. It adds composed-character ordinary
arrow navigation and selection collapse, plus guarded IME replacement/commit
handling and marked-text protection in the shared editor. The file-tab Vim
toggle now refuses a change while marked text is active, keeping host and editor
mode state consistent. Lockfile changes remain limited to the two shared Git
sources. All **96 Agent workspace tests**, strict all-target Clippy, formatting
and native Linux build pass with that exact dependency revision. Shared callback
and Unicode tests do not establish real native candidate-window or macOS IME
behavior; those remain explicitly unvalidated.

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
| Queue presentation | App/Workspaces/QueuePanel.swift | Partial. Bounded/collapsible panel, truthful timing, stable lane grouping, full-text editing, and per-chat full-message/model-choice popover. Drag reorder, adaptive room budgeting, and native interaction validation remain pending |
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
| Transcript Copy | App/Transcript/TranscriptRows.swift RowActionsView/TranscriptPillStyle; App/Workspaces/ConversationPane.swift | Implemented hover Copy slice with source 22pt reserved band, trailing pill and raw message text. Resolves current active chat/message identity at click; stale/missing identities leave clipboard unchanged. Five lookup/headless clipboard/layout tests pass; native runtime scope below. Other transcript actions and accessibility parity remain missing |
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
| macOS last-window close, Dock reopen and cancellable Quit | App/Application/ApplicationLifecycle.swift; WindowActivityGuard.swift; PiApp.swift | Partial prerequisite. App-owned entity retention and guarded window rebinding are implemented at `2048dac`; production Close still shuts down the workspace and quits after final close on every platform. Source last-close refusal, idle detach/Dock reopen and cancellable true Quit remain unwired. Linux QA and six headless lifecycle tests do not establish macOS lifecycle parity |
| Performance vs Swift | README.md prior validation; docs/validation/ | Measurement hooks implemented; same-hardware baseline and sustained latency comparison pending. CPU callback timing is not frame presentation |

## Latest incremental slice

### Non-executing typed tool-history foundation

Optional typed assistant-call and result records now have validation at snapshot
write/load and Responses projection boundaries. Identity is scoped by assistant
message plus call ID, allowing a later assistant to reuse a provider call ID
without borrowing its earlier result. Supplied results must follow call order;
missing results project as the source's explicit “No result provided” placeholder.
No placeholder schedules execution. Incomplete/cancelled typed assistants and
their results stay out of replay; full Swift incomplete-call continuation is
deferred with the production multi-round loop.

Existing text-only messages keep their serialized and wire shapes and use Rust
snapshot v2. A transaction adding typed history upgrades to v3 so old Rust builds
fail rather than silently discard unfamiliar metadata. The new loader accepts
old text histories, rejects mislabeled/malformed typed histories without rewriting
their bytes, and validates unknown fields, owner/order, payload bounds and binding.

Binding retains profile ID, API, provider, model and the source-style endpoint
SHA256; it contains no credentials, headers or credential hashes. Opaque provider
reasoning is retained but **not enabled for same-profile replay**. `Routing.swift`
requires a configuration revision, pinned-route contract fingerprint and observed
effective model that Rust does not yet implement. Default-ask ordering fails closed
even on a same-profile model change. A different saved profile uses the source's
portable early path; no opaque bytes or foreign provider item IDs are sent.

This is **implemented/partially validated foundation, not production tools**.
The live request still offers no tools and its completion handler still fails
visibly on unexpected calls without executing them. Eighteen synthetic tests cover
text compatibility, identities/order, missing/incomplete records, provider binding,
large/invalid data, snapshot v3 reopen, and the existing rejection boundary.
The foundation is backed up at `4a9732bcc8df1319abc5e7572829cc9bff0edff4`;
its [Linux CI](https://github.com/BelloWare/BelloAgent/actions/runs/37266217199)
and [native macOS build/core checks](https://github.com/BelloWare/BelloAgent/actions/runs/37266217184)
both pass. Those macOS checks compile/link test targets, execute core tests and
build the app; they do not establish macOS desktop or IME interaction.

The separate regression follow-up adds nine checks without changing production
behavior: pre/post-rename result cuts, atomic v3 upgrade/pair publication,
malformed transaction rollback, torn stream-tail recovery and torn snapshot
preservation; live loopback Controller rejection/cancellation with no second
request after worker shutdown; real HTTP replay projection with no offered tool
schema; and opaque-policy failure before an HTTP connection is made.
All **123 workspace tests**, strict all-target Clippy, formatting and native Linux
build pass locally for this follow-up. Previous CI validates the first checkpoint,
not these newer test bytes; the new checkpoint needs its own CI run.

Output retention, source trust/mode UI, immutable project tool
policy, instructions/resources, cost/context controls, multi-round execution and
tool cards remain missing. No external model service was contacted; the production
path still invokes no filesystem tools. Existing tool tests use disposable fixtures.

### Literal user-message width correction

Linux desktop validation found that short user messages collapsed to one glyph
per line. The user body had no proposed width while its text child had a
percentage maximum, allowing minimum-content sizing. `TranscriptRows.swift`
defines the 840pt page, 48pt gutter, 40pt leading user spacer and 640pt prose
cap; `TranscriptPlainText.swift` explicitly expands literal text to its available
width. Rust now proposes that same capped width, accounting for the sidebar
divider once. Font, right alignment, padding and colors are unchanged.

The geometry regression covers normal, minimum-window, half-pane and narrowest
supported split widths, plus invalid-width defense. All **96 workspace tests**,
strict all-target Clippy, formatting and native Linux build pass. Fresh native
Linux screenshots confirm horizontal short messages at 1180×812 and literal
multiline text at 1270×900. The current window manager did not honor the requested
920×600 bounds; exact minimum-size desktop and Unicode-paste validation remain
pending. Geometry tests cover those layout bounds but do not replace desktop QA.
This corrects a real UI defect, not a claim of full Swift pixel or macOS parity.

### Queue full-message detail

The existing queue row now has the source information control. It opens a
queue-anchored, window-bounded 340pt popover with a selectable, read-only text
viewport capped at 220pt, captured Model/Reasoning values, and the source's
default labels. Rust already retains full queued text, so this performs no
asynchronous preview read, acquires no edit hold, changes no composer draft,
and sends no request. Source context/output capacity rows are not fabricated
because Rust submissions do not yet capture those fields.

Disclosure state belongs to each chat. Rendering looks up the original chat
and turn identity afresh, so reorders keep the target, rewrites update its text,
and removed/delivered messages show “This message is no longer waiting.”
Escape restores focus only if the read-only detail still owns it; outside clicks
close without stealing the new focus. Dismissal callbacks are scoped to a unique
presentation identity, so an old popup cannot close another chat or a reopened
popup. Opening Quick Open dismisses the detail before transferring focus.

Six new deterministic tests cover full Unicode text/choices without mutation,
reorder/rewrite/removal, cross-chat isolation, repeated missing-message reads,
defaults/geometry, and fresh presentation identities. **95 workspace tests**,
full strict Clippy and formatting pass in the local candidate. These are
headless tests; actual popover placement, text selection, Escape/outside-click
and macOS behavior still require desktop validation.

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

## Transcript Copy validation (2026-10-05)

The Copy pill follows `TranscriptRows.swift`'s reserved 22pt action band, 6pt gap,
11pt medium text, 10pt horizontal/4pt vertical padding and overlaid border. Both
roles' actions trail their row; existing message-body widths/alignment are unchanged.
It copies the current controller message's exact text by chat/message identity,
including raw Markdown, whitespace and Unicode. A missing/stale identity is a no-op.

Five regression tests cover lookup, a real GPUI fake-platform clipboard boundary
and repeated normal/minimum resize geometry; all 141 workspace tests, strict Clippy, formatting and build passed in an isolated
worktree containing only this app slice and the published dependency manifests.
Earlier Linux desktop candidate
`a40471202cbd97dc2c97e5d61353a3114017c13c93b3d446e07057d7dc1662b2`
passed hover visibility, trailing alignment and no row-height jump. Click → paste
through the actual clipboard reproduced the synthetic user message (51 UTF-8 bytes)
and assistant reply (73 bytes) exactly, including combining text, raw Markdown and
trailing spaces, verified from the disposable saved draft. Its minimum-width check
then exposed a regression: a redundant nested auto-height flex wrapper retained
phantom row height after resize and displaced the assistant message. The final
candidate removes that wrapper while retaining source geometry; its headless
1180→920→1280→920 test asserts both text visibility and exact 22px pill/band height.
Current candidate `1b2dd0455bb51677f4a15b1087d1bbbaad32c90998d9b4dff93ca85bc7122e6e`
passed fresh actual 920×600 desktop checks: both messages remain visible through
resize/scroll, hover pills trail without row jumps, and both exact-byte clipboard
checks were repeated successfully. These current screenshots and results supersede
the earlier candidate's geometry evidence. Live stream-update desktop checks remain
pending; latest-stream identity is headless-tested.
This is not full transcript selection, Markdown rendering, other row actions,
accessibility or native macOS interaction parity.

## Optional macOS own-window probe

The default build excludes the `native-lifecycle-smoke` feature and all of its
startup hooks. The opt-in probe reuses GPUI's already-locked Cocoa/Objective-C
bindings; it adds no new package versions. The reviewed workflow uses a public
standard `macos-26` Actions job. The runner requires explicit public-job opt-in,
creates a fresh empty isolated project/session/home, and passes no provider
configuration or credentials.

The probe observes a native GUI session/display/Metal device and our own visible
AppKit window with nonempty bounds, then invokes that window's ordinary
`performClose:` on the native main queue, outside a borrowed GPUI callback. It
requires ordered window-close/app-quit markers and a clean process exit. A watchdog,
missing capability, unexpected window or failed marker sequence fails the experiment;
it does not skip or change permissions/TCC. Logs expose only allowlisted markers.

Local Linux checks passed: 141 default Rust tests, 145 feature-enabled tests,
strict Clippy/build for both configurations, and four Python harness tests.
The macOS-only probe has **not yet compiled or run**; native evidence requires its
own exact-commit CI result. Even a successful probe establishes only empty-workspace
native lifecycle traversal. It does not prove pixels, desktop input, IME, accessibility,
nonempty draft persistence, Dock reopen, cancellable Quit, or Sparkle behavior.
Probe code and its feature-gated hooks count as test-support LOC, not shipped
production code. No macOS lifecycle parity is claimed by adding this diagnostic.

## Next implementation priorities

### macOS application lifetime prerequisite (source audit)

The original app deliberately separates three actions:

- `WindowActivityGuard.windowShouldClose` refuses the last visible main-window
  close while active work or unkept sides remain. Its explanation has one
  **Keep Window Open** button; stopping work belongs to a separate Quit decision.
- `ApplicationLifecycle.applicationShouldTerminateAfterLastWindowClosed` returns
  false. `PiApp` owns `WorkspaceModel` at app scope and one named main window;
  Dock/menu-bar reopening returns to that model, rather than rebuilding it from
  a transcript and losing unsaved editor or undo state.
- `ApplicationLifecycle.applicationShouldTerminate` can defer/cancel true Quit:
  resolve dirty settings, confirm active work, flush drafts/selection, wait for
  hosts, and remain open if saving fails. Sparkle's install path uses the same
  source save/work barrier.

Rust `AgentView::request_close` currently routes close into `begin_shutdown`,
which flushes drafts, stops controllers and removes the window. Its global
last-window callback then quits. Checkpoint `2048dac43ec47437da8d29260576f645bd33c21e`
now retains the actual workspace entity graph at app scope and rebinds
window-scoped subscriptions/close/focus handlers with a generation guard.
Production idle detach and Dock reopen are not connected: simply skipping the
final quit would still leave the workspace already shut down. Disk reconstruction
alone would not preserve unsaved file buffers/undo.

Six real GPUI headless tests cover retained parent/editor/controller identity,
draft and file undo, one-window/stale callback protection, rebound subscriptions,
existing close/save-failure retry, and actual `App::shutdown` release timing.
The quit observer synchronously removes only the retention owner so the existing
release cleanup runs at its previous boundary; it performs no new save or veto.
Fresh Linux desktop QA of immutable candidate `b09c31b67c3fe46e75b48177469dc8c03a65b2291f5bee5627ea47c46a670803`
verified two initial paints before input, no-click Quick Open, composer typing,
draft save/relaunch and clean close. An extra startup activation found by QA was
removed before publication. All 129 workspace tests, strict Clippy, formatting
and Linux build passed. Exact `2048dac` CI also passed:
[Linux tests/Clippy/build/live smoke](https://github.com/BelloWare/BelloAgent/actions/runs/37270031171)
and [macOS test-target compile/link, selected pure tests and app build](https://github.com/BelloWare/BelloAgent/actions/runs/37270031142).
These are ownership groundwork and Linux evidence, not macOS lifecycle validation.

Pinned GPUI **0.2.2** source was inspected: `Application::on_reopen` is supported
(`src/app.rs`), but `App::on_app_quit` explicitly cannot veto termination. The
`App::shutdown` also gives quit observers only 100ms to finish. The
macOS delegate registers `applicationWillTerminate:`, not
`applicationShouldTerminate:` (`src/platform/mac/platform.rs`). Its native quit
dispatches `NSApplication.terminate:` on the main queue. An asynchronous cleanup
observer must not be presented as a cancellable save-failure barrier.

The save/stop prerequisite now captures drafts, selection revisions and controller
identities into a window-independent `ShutdownPlan`. It preserves the current
register → save draft → select → sequential controller shutdown ordering.
An operation identity controls outcome application; only the matching window
binding can be removed. A detached-window save failure still restores the retained
workspace's error/editability state. This does not activate idle detach or native Quit.

Seven additional regression tests cover stale revision rejection, queued edits and
unsettled submission receipts across reopen, registration failure before stopping,
partial registration, duplicate/stale completion, detached failure and rebound-window
protection. A real active loopback worker is stopped before an injected later
stop-boundary failure, then its shutdown is safely repeated on retry. This does not
claim recovery from real poisoned locks or panicked workers; later save/select fault
cuts are not injected by these tests. All 136 workspace tests, strict Clippy,
formatting and Linux build pass. Current Linux desktop candidate
`fce530826b456ff552a9bd9bb9159ca83e3b96278f4db122b7b5e0a1e865fa34`
painted before input, opened Quick Open without a click, kept the window/draft editable
on a real disposable catalog-write failure, then saved/closed/reopened the exact
edited draft after removal of that fixture obstruction.

Composition during Close/Quit remains an explicit audit gap: the existing shutdown
path makes composers read-only before capturing drafts, without an explicit
marked-text commit/cancel gate. The pinned editor already exposes `has_marked_text`;
retaining the same editor entities does not require a move-only transfer API.
No macOS IME close/quit interaction has been validated, and this checkpoint does
not silently choose a new composition policy.

Source settings/side-draft/read-state/project/topic barriers, install quiescence and
resume, and native termination veto remain missing. Current Rust selection failure
is still fatal; Swift Quit treats selection as best-effort. Those policy gaps were
not silently changed by this extraction. The next boundary is distinct source-backed
CloseWindow/Quit coordination followed by reviewed native termination-veto integration. Preserve active work, chat drafts, unsaved editors
and undo; recreate only window-scoped bindings. A native delegate bridge must
retain/forward GPUI's existing delegate behavior, including reopen and quit
notifications; no unreviewed delegate replacement or implicit veto is acceptable.
Pure state/flush tests and macOS compilation are groundwork only. Actual Dock
reopen, repeated Quit/Cancel/save-failure and editor restoration still require
native macOS desktop validation. The retention prerequisite does not activate
new close/quit policy, and the existing safe Linux final-window quit remains unchanged.

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
