# Bello Agent — Native Swift implementation and continuation design

Selection, task clocks and queue handoff follow-up (2026-09-21): assistant prose
has a geometry-only selection marker. One native input observer per mounted
conversation reads the settled UTF-16 selection from AppKit's field editor or
code text view and presents a transient popover. It creates no extra text host,
does not publish per-selection transcript state and dismisses on navigation.
The captured selection opens a normal pending child side, appending quoted prose
to its draft without submission or interpreting slash/skill text as commands.

Task lifecycle `startedAt`/`endedAt` retain their original uptime-ms contract.
New optional `startedAtUnixMs`/`endedAtUnixMs` fields provide calendar stamps;
old journal receipts remain readable with their elapsed duration. Live duration
uses uptime in the app too. Interrupted receipts do not claim a finish timestamp
or duration, including legacy receipts with mixed-clock ends. Streaming row
`at` and completion-announcement comparisons use calendar timestamps.

The helper rechecks unpaused pending work after its last cleanup suspension,
after clearing run ownership. A successful compaction/run hands it to the next
run atomically; Stop, errors and durability failures still pause delivery. The
native queue offers Send queued for an idle unpaused queue, including queues
stranded by an older helper; paused work continues to require Resume.

Updated: 2026-09-21. Work on `main` in `BelloWare/BelloAgent`. Read [Features.md](Features.md), [implementation status](docs/Implementation-Status.md), and [test handoff](docs/Swift-Test-Handoff.md).

**Sections 1–9 describe the native implementation and its acceptance boundaries.** The archived SDK-era design at `docs/archive/PiSDK-Design.md` is historical. Current source and [implementation status](docs/Implementation-Status.md) establish what exists; deterministic fixtures do not establish compatibility with an unspecified deployment or signed-release readiness.

**Owner update, 2026-09-16:** new work uses Responses only. Preserve historical Messages journals/captures and stored credentials without silently converting endpoints. Speaker names are absent from transcript rows; request details stay accessible on user input, while each attempt has one inline accounting owner. Reasoning tokens and gateway-reported reasoning cost are output subsets, never additional totals.

## 1. Architecture

Bello Agent is the product name beginning with 0.1.2/build 6. Xcode still uses
project/target/module `PiApp`; `PRODUCT_NAME` produces `Bello Agent.app`. Bundle
ID `com.belloware.PiApp`, Keychain service/account, history paths and Sparkle
Ed25519 key stay unchanged. The canonical feed is `bello_agent.appcast.xml`;
publication mirrors its exact bytes to `pi_app.appcast.xml` for older installs.
The website uses `/bello-agent.html` with a compatibility redirect at the old URL.

```text
SwiftUI/AppKit application, native composers, SQLite desktop metadata
    Native SwiftUI transcript (Markdown, highlighting, diffs, accounting)
                      |
             NDJSON anonymous pipes
                      |
    pi-native-host (Swift, one per active workspace)
        NativeHostService: lifecycle, IDs, command dispatch
        AgentSession: context, queues, tools, sides, journal
        Resources: Codex files and explicit skill selection
        ProviderClient: Responses over HTTP/SSE
        TraceStore: submitted/received bodies and timings
        NativeTools / MCPManager: bounded local and remote tools
                      |
             LiteLLM and approved MCP servers
```

The existing frontend remains. The Swift package has no third-party dependencies. It uses Foundation networking, filesystem and subprocess services. Swift package language mode is 5 for the intended Xcode 16.1 toolchain; the macOS app retains Swift 6 strict concurrency. Linux Swift 6.2.1 tests do not prove compatibility with Xcode or AppKit.

`HostSupervisor.swift` launches `Contents/Helpers/pi-native-host`. Manifest/handshake identify engine `swift`, version `1.0.0`, protocol major 1 and capabilities. The transport remains local pipes with off-main IO. No credentials or raw debug bodies reach the transcript rows.

The single-item Keychain vault is owned by the native app. The helper receives only its workspace configuration and selected connection credentials over private IPC. It never receives the vault or capture encryption key. The helper process itself is not a sandbox.

## 2. Implementation map

| File under `packages/swift-host/Sources/PiAgentCore` | Responsibility |
| --- | --- |
| `JSON.swift`, `Support.swift`, `TextPreviews.swift` | The typed JSON value; errors, request-parameter validation, bounded IO and hashes; bounded text previews and paging |
| `Profile.swift`, `ChatMessage.swift`, `ModelInterface.swift` | One connection and its per-turn overrides; one conversation row in journal and display form; the provider and tool-executor protocols |
| `ToolInputDisplay.swift` | Cutting a tool call's arguments to a bound that still parses |
| `Transport.swift` | URLSession body observation, incremental SSE, per-attempt in-memory capture and metrics |
| `Providers.swift` | Active Responses request builder/accumulator; legacy Messages parser for retained compatibility |
| `Resources.swift` | Codex instructions, skills, policy/hash checks and conservative YAML/TOML parsing |
| `Tools.swift` | read/ls/find/grep/write/edit/bash, bounded output and image handling |
| `MCP.swift` | stdio/HTTP JSON-RPC, initialization, discovery, schemas, serial invocation and unknown-outcome markers |
| `Sessions.swift` and its `Session*.swift` extensions | One chat, split by concern: `SessionJournal` (the locked append-only record), `SessionPersistence` (saved state, appends, forks, keeping a side), `SessionBranching` (turn.edit), `SessionQueue` (follow-ups, steering, delivery), `SessionRun` (the run loop and retries), `SessionStreaming` (the partial row), `SessionTools` (execution and live cards), `SessionDisplay` (the projected page and snapshot), `SessionCompaction`, `SessionContext` (the prepared request), `SessionReads` (on-demand reads), `SessionTestSeams` |
| `Profiles.swift` | Retired external profile authority; native vault configuration is authoritative |
| `Routing.swift`, `GatewayTelemetry.swift` | Sourced model identity and gateway cost/cache metadata, explicit unknown/conflict states |
| `CaptureCredentials.swift`, `CaptureDelivery.swift` | Masked header capture, request-body credential hashing and acknowledged transport-body delivery |
| `HostService.swift` | UI command adapter, workspace/session registry and command deduplication |

`Sources/PiHost/Main.swift` is the executable/framing entry. Core tests are in `Tests/PiAgentCoreTests`; `scripts/test-native-host.py` exercises the real helper against loopback HTTP and subprocess fixtures. `fixtures/native/litellm_contract.py` independently validates both API request formats, schemas, tool IDs/results, credentials and compaction boundaries. Native archive/dashboard and UI integration tests live in `apps/macos/PiAppTests`.

## 3. Protocol and ownership

**Task presentation contract, 0.1.72:** `TaskPresentationRecord` and version-1
`TaskPresentationProjection` add small, scoped lifecycle evidence to snapshots.
Root/input, execution, operation and physical attempt are distinct; up to 64 recent
terminal records accompany the active execution. The helper records terminality
at the real continuation decision, durably before queued work advances. Native
refresh decodes rows before batching their adoption with lifecycle/notices, then
`TaskTranscriptPlan` uses one grouping rule for live and cold history. Work,
per-source prose and terminal summary have separate stable keys. Cosmetic tool
fragments share one pending update; semantic/error/stop transitions flush promptly.
Tool detail caches use owning assistant plus call ID. See [persistence, geometry,
compatibility and verification limits](docs/Stable-Tool-Streaming-2026-09-21.md).

Handshake uses `{v:1,kind:"hello",major:1,minor:1}` and a ready reply with epoch, engine/version and capabilities. Commands carry `commandId`, `hostEpoch`, method, optional sessionId and params; replies retain `{ok,result}`. The same command ID with different arguments is rejected. Retained duplicate commands reuse their known result or report uncertainty rather than replay effects. Beyond 4,096 recent mutation fingerprints, bounded host-epoch tombstones prevent evicted commands from executing again; a rare hash collision rejects a new command conservatively and requires reconciliation. This is local dispatch protection, not exactly-once remote execution.

Events are sequence-numbered invalidations coalesced around 16 ms; the frontend requests bounded snapshots. Footer presentation can update more slowly than telemetry capture. The command surface includes sessions/history, submit/steer/stop, queue remove/resume/configure, compact, side open/keep/close, resources, profiles, debugging and MCP.

Status-only reads do not project or encode a hidden transcript. `displayRevision`
is an opaque, runtime-scoped generation token; clients compare it for equality,
not as a content hash. A changed visible snapshot materializes only the newest
60 rows (plus a streaming reply) that fit the existing 300 KB page allowance,
reusing unchanged row projections. `before` describes that materialized page and
may be absent from an uncached status reply. Content, tool-state, branch,
compaction, retry and cancellation mutations invalidate the relevant cached rows;
reopening a session creates a new revision namespace. Raw HTTP capture remains
independent of this display cache.

The native supervisor admits 32 outstanding ordinary commands and queues up to
128 more FIFO. Queue cancellation removes an unsent command; an acknowledgment
timeout does not free its dispatched slot until a reply or host loss reconciles
it. Stop bypasses ordinary admission, and neither Stop nor capture ACKs consume
the ordinary pipe-write budget. No uncertain command is replayed. The UI inbox
retains at most 64 legal frames (1 MiB each), coalescing session invalidations by
ID; one project's valid 20-session snapshot burst must not kill its host.

Cold callers share one project initialization through `workspace.open`, bound
to the current connection UUID. Session callers share `session.open` through
the capture-mode acknowledgment, including the durable journal-path write.
Shutdown cancels shared startup and rejects work returning from credential
reads. Connection switches cannot overtake an opening session. Durable capture
ACKs wait for the archive actor, not UI accounting; presentation invalidations
are scheduled afterward. Background accounting coalesces per session and updates
totals/timing without rewriting hidden message attribution.

The helper owns authoritative context, provider items and native journals. The app owns desktop index/drafts, current profile metadata/Keychain access and durable trace export. Never use rendered text to recreate model context. There is no runtime fallback to the old Node host.

## 4. Session behavior

The transcript attaches a work line to the bottom of every assistant reply: how long that reply took, what it did ("Reasoned", "1 tool call", "Reasoned · 6 tool calls"), the model-versus-tool split and, while live, the action currently running. The helper records message clocks, tool durations and file edit line counts so reopened sessions keep the same figures. A reply's work is the reasoning-only and tool-only replies before it plus its own reasoning and tool calls; work a turn ended on without prose forms a trailing line of its own. A reply reads in the order things happened (0.1.39, at the user's request): what the model did comes first, under a small header naming the work ("1 tool call") with the chevron that folds it: the exposed reasoning behind its own fold, one verb-and-object row per call with its status, duration and +added/-removed counts, and the figures of each request; then the reply text; then the turn line. The rows stay in view after the turn, only clicking a row reveals its request and response card, and nothing reopens itself on new stream data. While a reply streams, the page scrolls once per change and only after the AppKit document has taken SwiftUI's new height (landing short and correcting made the text stutter), and no snapshot is animated during a live turn. Rows are laid out exactly rather than lazily (a plain `VStack` under the scroll view): a lazy stack estimated the heights of rows out of view and corrected them later, which moved rows in view while a reply streamed below; with exact layout the rows in view, and the buttons on them, stay put, anchors are exact, and the 500-row page cap bounds the cost. Nothing reopens itself on new stream data. Standalone tool-result rows fold into their call. The accounting line under a message shows only what the gateway reported; an unreported model, usage or cost is left out, and a message with nothing reported has no line. Before the first token of a reply arrives, its row shows three pulsing dots rather than a bare caret. The conversation pane has no header: the sidebar names the chat, the composer bar holds Changes, Session info and the chat's action menu, and while a turn runs a fixed-height live bar docks above the composer with current phase, elapsed time, reported tokens/cost, input/output counters, Info and Stop. The terminal summary wraps its timing, token breakdown, cost and model fields directly in the transcript. Manual compaction carries the originating chat’s model, reasoning effort and capacity/output overrides through the command boundary; the helper validates and freezes them before starting. Info opens a metric/value/coverage table with cache and reasoning cost, timestamps and per-request inspection. Work details remain in the persistent task disclosure. An authoritative terminal outcome adopts a compact Turn summary and releases or retargets the dock in one snapshot. The side pane keeps a slim header with its name, whether it is saved, and what it shares in plain words ("Shares the parent's context up to '…'"), the identifiers a hover away. An empty chat shows a starter card with its project folders, connection, model and tool mode, and buttons for Changes, Terminal, Skills and a side, gone with the first message. Sidebar rows show cost, one token figure (the split a hover away), a recency stamp ("3m ago"), a spinner while running, and their archive control only on hover. Reports and Session info name coverage only where it is partial, and a request whose gateway echoed no final model shows a quiet dash rather than a warning. Every reply carries one line with everything in view: what it did ("Reasoned, read 1 file"), how long it took, its tokens and cost, and its model as a link to the request; the chevron folds the bulky parts (reasoning, tool call rows, each request's full accounting with coverage and cache notes). While live, the docked bar alone carries the spinner, the current action and Stop; the reply line lists only work already done and counts up (its last three actions appear beneath it only while its rows are folded). The bar follows the session's run state, not only a streaming row: it stays up from the moment a message is sent, through tool calls between requests, compaction and stopping, naming the state (Waiting to start, Working, Compacting context, Stopping) with the turn's figures so far. A turn is the user's message plus every request the assistant makes until the next user message; under its last reply a plain summary line, with nothing to expand, gives how long the turn took, its replies and tool calls, model versus tool time, input tokens with the cached and uncached split, output tokens with the reasoning share, and reported cost, each with coverage when not every request reported. Single-reply turns get the line too. Token counts are exact under ten thousand and compact above. Work summaries count outcomes, not calls: distinct files for edits, reads and listings (three reads of one file are one file; a listing is not a read), and failed or skipped calls are reported as such rather than as work done; verbs follow the call's state (Editing, Edited, Failed editing, Skipped editing), and the MCP meta-tool's action names what it did (Listed MCP servers, Loaded 2 tool schemas, Called server · tool). The helper stamps every row with its turn (the user message id) and each assistant row with the measured duration of its model request, journaled with the row; the transcript groups replies by that id, so a compaction summary, a retry notice or a failure inside a run no longer splits the turn, a history page that begins mid-turn labels its first turn partial, and model time comes from the measurement rather than the gap between rows (older journals fall back to the gap). A reply's block keeps the key of its first row while its prose arrives, so an expanded work line stays open and nothing re-animates; the model link sits beside the toggle rather than inside it; reasoning inside an expanded line starts folded and unfolds with the same motion as the details; the turn line adds the count of files changed. The look is calm by construction: a user message is a soft tint with no outline; a settled turn closes with a hairline (not a filled band) and one quiet line of figures that wraps between its dots in a narrow pane; raised surfaces (composer, cards, the live bar) sit on a hairline with a short, soft shadow rather than floating; footer metric icons are tertiary so the figures read first. Motion follows one language (one ease for state changes, a longer ease-out for arrivals; 140, 220 and 320 ms): every hover, fold, chevron and arrival uses them, a settled turn warms its hairline for a moment instead of flashing a fill, and app-owned transitions and animations stay enabled even when macOS Reduce Motion is on. The turn line is flowing text rather than a button: its figures are inline spans separated by trailing dots, so a narrow pane wraps between figures with no dot at a line start; the chevron is the real toggle button (keyboard reachable, aria-expanded) and clicking anywhere on the line also toggles. Keyboard focus follows intent: `focusComposer` (WorkspaceModel) bumps a chat's `composerFocusRequest`, and every deliberate move calls it (new chat, select, open side, select side, close or discard a side back to its parent, edit a message); background events never do. Typing that would land nowhere (the transcript, a sidebar row, nothing) goes to the visible composer of the focused chat: `WindowPresentationController.redirectTyping` moves first responder on a plain printable keystroke only, never for shortcuts, arrows, space, Escape, Return or Delete, and never away from a text field, field editor or the terminal; Escape in the chat filter clears it and returns to the composer. Nothing clips in a narrow pane: the composer pills degrade full → compact connection and shorter model → icons only (`ViewThatFits`), the metrics footer falls back from one row to timing on a second row, then timing without the work split, then the bar alone; sidebar stats drop tokens then recency before truncating; the empty-chat buttons wrap (`PiFlow`). Usage is split per route wherever a scope can mix models: `MenuBarModelDistribution` (Session info) and `DashboardModelSummary` (the report's By model view, `PayloadArchive.modelSummaries`, busiest 64 routes) each carry the route's own duration-weighted output rate (`HistoricalOutputRate`) and nearest-rank first-token and whole-request medians, grouped by API, requested alias, served model and identity status, so an unreported or conflicting route stays its own row. Session info renders one Models table (requests and cost with share bars of the session, tokens, output tok/s, first token) in place of separate cost and model distribution lists, and its tiles note "per model below" when a session used more than one route. The report's tiles add Output tok/s for the window (blended, with the same note), and a By model row click sets the alias and model filters. `UsageShareBar` is the quiet share capsule for these rows; `PiMeter` stays for capacity, since a share is never a warning. No window shows the system title bar: `PiWindowBar` (WindowPresentation.swift) is a strip that replaces it, dragging the window, zooming on a double click and applying `NSWindow.applyPiWindowChrome()` (hidden title, transparent titlebar, full-size content, no separator, the app's canvas as the window background) to whatever window hosts it, while `.titled` stays for native key handling and the traffic lights; `PiWindowBar.trafficLightInset` keeps headers clear of those buttons. The Session info window's header and `PiSheet(windowChrome: true)` (the Settings window) use it; sheets have no title bar to replace and are left untouched, and the window title still names the window in the Window menu. Tiles read quietly: `PiStatTile` shows a tinted glyph beside its uppercase label rather than a filled badge, its value is 20pt semibold, and the caption reserves two lines so a row of tiles keeps one height; sheet headers use a soft tinted `PiIconBadge` and a 17pt title. The sidebar carries no app name or icon; New Chat sits on the Projects row beside the project manager, and the Bello mark appears on an empty chat's starter card and, pulsing softly, while a chat is being prepared. Motion is brief and purposeful: rows that were not on the page at the previous paint slide in (a restored page or a switched chat arrives settled), a turn that has just finished glows for under a second where it ended, expanded details unfold, the live bar enters its fixed slot with a short opacity/offset transition, a copy confirms with a pop, the terminal panel slides up, and sidebar chats fade in and out; macOS Reduce Motion does not disable these app-owned effects. The terminal panel is the app's own emulator since 0.1.38 (`apps/macos/PiApp/Terminal`): `PseudoTerminal` runs the login shell on a pty it owns (forkpty, so job control and window-size changes work), `TerminalEmulator` is an xterm-style VT parser over a cell grid with 10,000 lines of scrollback, an alternate screen, scroll regions, tab stops, DEC line drawing, 16/256/true colour, bracketed paste and the replies programs ask for (DA, DSR, DECRQM, XTWINOPS, OSC 10/11 colour queries), and `TerminalView` draws it with CoreText in the app's palette, handles keys (arrows, function keys, Control and Option-as-Meta, input methods for CJK), selection and copy, paste, wheel scrollback (arrow keys for full-screen programs) and accessibility; the shell never sees provider credentials. Each task keeps one compact work row and independently owned prose rows. Its single terminal Turn summary offers full timing, model/tool, token, cost and request details; per-request figures stay in the work disclosure. Model reply completion alone never creates that summary. A user message opens a turn with more room above it and less between it and its reply; user bubbles are capped like reply prose; code blocks name their language beside the copy control on hover; the empty composer's placeholder carries the keyboard hints. A live task exposes source-ordered actions and reasoning inside its reader-controlled work disclosure; an edit or write call expands to the change it requested, labelled Requested edit or Requested content and marked not applied when the call failed or was skipped (an overwrite shows the requested content plainly; only a confirmed new file reads as added lines); prose is capped near 80 characters a line while code and tables keep the full width; a user bubble and a settled turn line reveal their times on hover. Settings shows every saved connection as a tab with the count beside them; a new connection opens as its own tab until it is saved, so how many connections exist and which one is being edited are visible at a glance. The Session info window (conversation header) is one scrolling page with no tabs, in reading order: first-token time, output rate, model and tool time, then requests, tokens and cost tiles, the four per-request charts, a token-mix bar that stacks cached input, uncached input and output (with the reasoning share named), the token and response-cache cards, cost and model distributions, and the usage notes; the footer popover keeps the two speed charts. Status and copy/inspection actions remain available.

A session actor owns its history and two separate queues. Pi `v0.85.1/packages/agent/src/agent-loop.ts` is the steering/follow-up reference. Deliver a user input, stream a complete model response, append it, execute validated tools serially and save each result. Only then consume steering; consult queued follow-ups when the run would otherwise stop. `one-at-a-time` is the default; `all` is an explicit queue setting.

Stop lives beside the send/queue controls inside each chat composer and cancels only that session's active work, pausing its queues. Background tasks with no composer expose Stop in their lower task footer. Failures, truncated responses and failed compaction also pause continuation. Failed responses display Error and a visible, wrapping explanation without opening an inspector. Persist the failure for reopened sessions, bound long details with scrolling, and redact known credentials before display or journal storage. The failed run and its paused follow-up queue remain separate states; deliberate cancellation stays paused. Transient HTTP failures have five retries after the initial request (six attempts total), with 1/3/5/8/10-second cancellable backoffs. Explicit context rejection permits one bounded reduction/retry cycle per logical model operation; mutating tools are never automatically retried. Recovery pairs unresolved tool calls with explicit unknown results; it does not rerun them. Journal delivery IDs avoid duplicate user delivery after a crash between a message append and queue-state append.

Each native journal is append-only, exclusively locked and bounded. Its envelope supports existing history display, but native opaque state is not Pi SDK session compatibility. Additional backward migration is not a release goal. Preserve old user files rather than silently rewriting them.

`/side` copies the latest complete context boundary into an independent session. Parent and side then evolve independently; a snapshot is not a filesystem snapshot. Side tools are read-only by default, but its composer stays usable. Publish the complete journal before exposing the side as saved. `/side` with no prompt opens it immediately. A chat can have several sides: the pane shows one at a time and takes exactly half of the content width; opening another side while one is shown swaps the pane, and clicking a saved child chat in the sidebar shows it in the pane (its context menu still opens it on its own). The replaced side keeps its display and any running work. `/fork` publishes a separate journal containing the same complete active context and provider/tool state, with independent future turns and no inherited pending commands. New sides are durable child sessions immediately; closing only hides their pane, and reopening or restarting restores them. Legacy unkept sides are retained through the existing keep recovery path. Sessions of one workspace run concurrently, including their model requests; editing tool calls (write, edit, bash, MCP invoke) take turns on a per-workspace gate, so a chat never waits for another chat's whole run. There is no artificial active-project count setting or its former eviction; protocol, capture and OS resource budgets still apply. The verified target is twenty concurrent model streams. Idle helpers still leave after the grace period. An archived chat runs nothing: sending, steering, editing, queue resume and commands other than Stop are refused with a notice, the composer gives way to a Restore footer, archiving a running chat stops it (its queued follow-ups wait for a restore), and archived chats never count in the Dock badge. A run that fails while its chat is not in front marks the chat in the sidebar (a red dot when nothing new arrived) without bouncing the Dock or counting in the badge; opening the chat clears the mark. Project chat lists show five chats, Show more adds ten at a time and Show less folds back to the first page with the selected chat kept in view. Chat titles come from the connection's mini model once, on the first message; the chat's action menu can ask for a title again (replacing an edited one), and a request that fails says why in the chat's footer.

Accounting presentation observes each chat independently. A changed retained
total does not invalidate the workspace; only inserting, removing or replacing
a live display changes the sidebar's retained/live binding. Native transcript
reconciliation uses the page's own revision, and layout requires exact geometry
for mounted rows. Offscreen width changes may use provisional frames until
bounded idle reconciliation makes them exact.

A process-local geometry cache can reuse verified immutable row measurements
across tab returns. Full content, session identity, freshness, rendering
environment, width and backing scale must match. Live replies and rows with
tool/reasoning/compaction disclosures are excluded. The cache retains values,
not hidden views or animations, with a 1,000-entry/16 MiB payload budget and a
256 KiB per-entry limit. Viewport rows validate actual native layout on mounting.
See the [five-session performance review](docs/Five-Session-Performance-Review-2026-09-19.md)
for measurements and qualification of cold versus warm history loading.

### Unreleased performance follow-up (2026-09-20)

Disclosure geometry follows the view-associated AppKit display link rather than
a fixed-frequency timer. Unrelated snapshots preserve motion; changed geometry
retargets from the presented height. Reading anchors use the presented row frames.

A window resize keeps the visible/anchored band exact, including at mouse-up.
Offscreen rows remain explicitly provisional until idle reconciliation reaches
them. They cannot be drawn or enter the shared exact cache. Main and side share
one 1.5 ms optional-work admission budget, with a minimum interval between budgets,
input/content quiet deadlines, visibility checks and fair rotation. A native sizing
call is indivisible and may exceed this allowance. Reports hides the retained
native transcript as well as the composer, suspending covered layout work.

Markdown block isolation starts at eight blocks. Large code fences (at least
16 KiB when mounted) use a persistent selectable TextKit leaf, exact width-keyed
sizing and incremental byte-prefix updates. Small fences keep SwiftUI text; a
mounted fence keeps its renderer when its length changes to retain selection.
Source-based copy actions and the existing syntax-highlighting size limit remain.
Many-block first sizing and large tables are still synchronous. The measured
shared-sizing-host prototype was rejected because it slowed common workloads.
See the [performance follow-up](docs/Performance-Review-Implementation-2026-09-20.md)
for before/after evidence, rejected experiments and validation limits.

## 5. Context, tools and resources

Context usage comes from one shared request-aware service used by preview, preflight and compaction. Its input is the same provider request builder output used for dispatch, including instructions, actual tool schemas, images and the items selected by replay policy. Results expose tokens, method, requested/counted model, request fingerprint, estimated status, warnings and budgets. A bounded five-minute cache keys all request and configuration inputs. An unprepared context is pending rather than a second competing formula.

The local fallback uses UTF-8/3 over model-facing request structure, actual image dimensions and explicitly qualified model policies. Only a declared fixed route with matching reported identity can reuse gateway-reported input for an unchanged ordered request prefix; newly replayed items are estimated. Never add all previous output usage or double-count cache/reasoning subsets. Changed instructions, schemas, route, replay policy, model, limits or request parameters invalidate that baseline. Opaque replay and unknown image policies stay uncertain. LiteLLM counting endpoints are not enabled until a full request-compatible, provenance-preserving contract is established; see [the pinned source assessment](docs/Context-Accounting.md).

`maxOutputTokens` is the requested response budget. The model catalog's output capability is separately stored as `modelOutputLimit`; selecting a model can clamp the budget down but cannot raise it to the ceiling. Preflight reserves the requested budget plus a margin of min(1024, max(1, contextWindow/100)) tokens. Routed client estimates cannot guarantee every possible backend fits. Explicit saved profile budgets are preserved because legacy storage cannot distinguish a catalog default from a deliberate choice; legacy per-chat catalog limits migrate separately.

Compaction summarizes older complete user/tool boundaries through the same instrumented API with tools disabled. Keep recent complete turns. Empty/failed/truncated summaries cannot replace context. The journal retains original history. A summary source that itself exceeds the limit fails visibly; recursive overflow handling is not implemented.

Status and full snapshots expose the latest committed compaction summary still
in active context. The native composer baselines it when opening a session and
shows a result only for a new successful summary. This works while browsing
history or observing a background chat; a failed/cancelled attempt cannot reuse
an older success notice. Sending or dismissing clears the displayed result.

Native tools are deliberately narrower than Pi: exact-match edit, bounded read/search, bounded/spooled tool output and managed shell process groups. Do not signal the application process group. Darwin cancellation and descendant cleanup are explicit test gates. Script toolchains are external dependencies, not bundled runtimes.

Codex instructions resolve global then project-root-to-cwd guidance with override/fallback precedence and a total byte budget. Do not preload all descendant instructions globally. New delivered user inputs refresh resources; in-flight requests retain their resolved content. A fully general YAML/TOML parser is not included; unsupported metadata must remain visible and fail closed.

The composer resolves `/skill-name` to canonical identity, policy/content hashes, arguments and explicit user-origin provenance. The host freezes selected bodies and validates permissions/dependencies at delivery. Explicit-only skills are available to the picker, not automatic discovery. Historical/model/pasted mentions do not grant authorization. Preserve source directory-relative references and do not execute scripts during discovery.

### Caret-local completion and historical editing (0.1.72)

`ComposerLocation` carries native UTF-16 selection/marked ranges, an editor
generation and draft revision. `SlashCompletionToken` examines a bounded local
token first; cancellable off-actor code-span/fence classification is cached by
that revision and position. Selection/text notifications advance the right
identity, including undo and input-method completion. `SkillSearch` preindexes
metadata and ranks the entire discovered catalog, shared with the inspector.
Per-composer catalog tasks key session, project, configuration revision, tool
mode and helper connection/epoch. Pages must share a source revision and valid,
advancing identities/counts. Old entries remain labelled unavailable during
refresh/failure; partial-source diagnostics remain visible. Acceptance validates
the actual editor/token/catalog before one undoable text-and-chip operation.
The existing `picker` intent represents inline selection; legacy deliberate
`/skill arguments` conversion and whole-message app commands remain separate.

`EditReplayPlan.swift` is metadata-only and compiled into both helper and native
retained reader. It selects a user occurrence from the child's selected display
timeline, independently of compacted context and viewport residency. It restores
raw pre-target messages, optionally substituting only summaries whose transitive
dependencies are wholly pre-target. Reused tool-call IDs are paired per assistant
occurrence; missing sources or invalid groups fail without modifying history.
No planner opens a runtime, recovers tools, generates a summary or writes a file.

New branch records have `nativeBranchVersion: 2`, ordered `keptIds`, a
`selectedTimelinePrefix`, target ID and source-timeline digest, plus diagnostic
journal-head/target digests. The replacement queue is in the same synchronized
record. Memory adopts the branch only after the append succeeds. Reopen, native
paging, portable replay, scoped recall and subsequent forks validate/select the
same branch; legacy ordered-subset branches keep their strict reader. Fork
context-selection records now include their proven visible prefix. An unsupported
version or missing source preserves the journal and explains the failure.

`session.edit.prepare` reads original display text in bounded UTF-16 pages with
source digests and version-1 `nativeUserInput` references. Closed sessions use the
retained-file actor without starting a helper. The native editor retains ordinary
drafts, skills and attachment references and rejects late target/draft results.
Current policy/hashes/dependencies and attachments are validated before commit.
Definite rejection leaves the branch unchanged; uncertain synchronization poisons
the journal and requires recovery. Crash restoration pauses accepted replacement
work rather than dispatching it. Branch adoption invalidates replay/count/partial/
retry/compaction state without rewriting historical usage or external effects.

The helper advertises `session.edit.prepare` and `native-branch-v2`; distribute
this helper and native reader together. No protocol-major or app-version bump,
release or publication is part of this implementation. Full contracts, bounds,
test evidence and acceptance dispositions are in
[the implementation record](docs/Inline-Skills-and-Historical-Edits-2026-09-21.md).

## 6. Provider transport and current capture

The active Responses builder and stream accumulator preserve complete Responses items (including opaque reasoning) for compatible replay. Legacy Messages parsing/history remains for read compatibility; the Profile boundary rejects new Messages requests before HTTP dispatch. Tool IDs/results remain paired. Never replay opaque state into an incompatible endpoint/API/model without an explicit compatibility decision or portable handoff. Default reasoning leaves the effort unspecified rather than pretending off is equivalent to omission.

One serialization supplies the HTTP request body and its capture. Authentication header values are masked. Known authentication credentials found in the request body are replaced with labeled SHA-256 fingerprints in the recorded body only, without reserializing it; transformations, original/retained lengths and non-exact status are explicit. If hashing exceeds safety limits, the body is omitted with no digest or empty-body export. Observe response bytes before SSE/JSON parsing. Known credential echoes in captured responses are replaced with same-length asterisks, including matches crossing chunks; the parser still receives the original bytes. Response transformation metadata explicitly marks non-exact captures, and SSE offsets remain unchanged. Flush buffered capture tails on cancellation and failure; handle arbitrarily split Unicode, SSE lines, partial tool arguments, error bodies, JSON fallback and cancellation. Disable credential-forwarding redirects. Capture boundaries are application-observed decoded HTTP, not TCP/TLS or gateway upstream traffic.

The helper's live `TraceStore` still bounds memory to 8 MiB per body, 128 MiB per
host and 64 attempts. Durable recording now bypasses those history limits:
`CaptureDelivery` sends original serialized request and pre-parser response bytes
in acknowledged pages of at most 32 KiB to the native `PayloadArchive` actor.
Only one page per helper can be outstanding; recorder failure is explicit and
never retries model/tool work. Metadata and message links are sent even with
body capture off. The old polling retention path is removed. `TraceArchive` is
used only for deliberate live-memory exports, not app-managed persistence.

Concurrent producers suspend FIFO behind that page instead of failing when 16
waiters are already present. A missing acknowledgment closes the capture channel
at the first deadline and releases waiting producers; it cannot multiply the
timeout by the session count. An ordinary negative acknowledgment remains local
to its packet. The archive supports 64 simultaneous persisted attempts (128 body
chunkers, at most 4 MiB of unpublished tails). The live memory budget also applies
to active attempts: trim them to explicitly incomplete contiguous prefixes while
durable delivery continues with original offsets and bytes. Do not append after
a trimmed gap or mistake a memory prefix for the complete recorded body.

The 20-session acceptance target uses per-session actors and independent async
URLSession requests. Since 0.1.52, synchronous read/list/search jobs leave the
`NativeTools` actor for a helper-wide bounded worker pool with up to four active
jobs and 64 FIFO waiters. Separate OS threads can execute jobs concurrently;
thread barriers verify this independently of networking concurrency. Permissions
and argument shape are checked before admission. Cancellation removes queued work and
signals running scans, which keep their slot until they exit; no worker thread
is killed. Individual filesystem calls or regex matches can still take time.
Editing tools retain the project gate. UI and storage keep their actor ownership;
OS resources and gateway admission remain finite. See the historical
[0.1.51 concurrency review](docs/Concurrency-Review-2026-09-19.md) and the current
[TPS and worker review](docs/TPS-Workers-Review-2026-09-19.md).

Timing version 2 records actual URLSession dispatch, first response-header observation, first decoded body byte, the body callback containing first nonempty content/text, the provider terminal event and HTTP task completion separately. TTFT is content minus dispatch; streaming span is terminal minus content; HTTP duration is task completion minus dispatch. Missing boundaries stay null. Full HTTP error bodies can be complete despite a failed model request. These are application observations, not socket/TLS or screen-paint timestamps. The native dashboard queries durable typed timing columns independently of payload retention.

## 7. MCP

One model-visible meta-tool has these actions:

```json
{"action":"list"}
{"action":"list","server":"local"}
{"action":"describe","targets":[{"server":"local","tool":"search"},{"server":"remote","tool":"lookup"}]}
{"action":"invoke","server":"local","tool":"search","arguments":{"query":"example"}}
```

List omits detailed schemas. Describe accepts 1–32 pairs. Invoke accepts one server/tool/arguments object; no batch invoke. A FIFO gate serializes invocations per workspace. Multiple separately emitted calls remain serial, not one unbounded batch. A durable unresolved marker is written before dispatch; uncertain transport loss/cancellation preserves it across restart. Further invocation requires explicit human acknowledgement, not model-controlled acknowledgement or automatic retry.

Read-only sessions may list/describe, not invoke, regardless of server annotations. Tools/results/schemas are untrusted data. Protocol support in this source targets 2025-11-25 and 2025-06-18 tools over stdio or Streamable HTTP; no OAuth/sampling/elicitation/resource UI, legacy HTTP+SSE, or complete future-protocol compatibility is promised. Server validation remains necessary; the native wrapper is not a full JSON Schema validator.

MCP configuration is edited in the native inspector, saved in the single vault and delivered directly over private IPC. External configuration paths, inherited credential environment references and ambiguous transports are rejected. Explicit server environment values are scoped to that server's child. Existing user configuration files remain untouched.

## 8. Build and existing verification

`build-bundle.py` builds the Swift release helper and stages Helpers/pi-native-host plus manifest/NOTICE; nothing else is built, no package manager runs and no runtime is downloaded. `sign-host.py` signs the helper without JIT entitlements. The release smoke check is `smoke-native-bundle.py`. The old TypeScript host and the React transcript were removed in 0.1.38: the transcript is native Swift in `apps/macos/PiApp/Transcript` (`TaskTranscriptPlan` gives tasks, assistant prose and terminal summaries stable ownership while `TranscriptActivity` supplies detail and usage calculations, `TranscriptMarkdown` turns Foundation's Markdown parse into blocks, `SyntaxHighlighter` colours code with its own scanners, `TranscriptCopy` finds section and code copy targets in the source, `TranscriptRows` draws the rows and `NativeTranscriptView`/`TranscriptPage` own scrolling, anchors, earlier pages, fresh-row motion and read receipts).

The recovered source's 28 payload hashes were verified. Subsequent macOS 14.8 arm64 / Xcode 16.1 checks cover core, executable, strict native compilation, storage/accounting, packaged-helper and actual CUA fixture UI. The current counts, failures and unverified gates belong in `docs/Implementation-Status.md` and validation records. The owner selected ordinary Keychain storage and the sibling applications' profile-free Developer ID release flow. The native UI was redesigned on 2026-09-15 around `apps/macos/PiApp/Design/DesignSystem.swift` (semantic AppKit colors, light and dark appearance); the earlier generated design concepts are superseded. On 2026-09-17 the visual language was aligned with Bello Box: cream surfaces with a faint orange wash, white cards on hairlines, the Bello orange accent and its gradient for primary actions and header badges, tinted icon squares, and SF type in place of serif, for both appearances; the transcript stylesheet carries the same palette.

## 9. Historical capture, configuration and gateway reporting

### 9.1 Deduplicated exact captures (F13)

**Current owner change (2026-09-15), implemented:** new captured
HTTP bodies use unencrypted, versioned chunks and verifiable digests. Preserve
compatible reads of existing encrypted history. The AES details below describe
the legacy format. Credentials/configuration remain in the Keychain vault.
Recorded authentication headers use masked values with at most a four-character token suffix; known credential literals inside request bodies become labeled SHA-256 fingerprints. A configured
credential found within a serialized request body is replaced in the capture
only, with explicit redaction metadata; ordinary bodies remain byte exact and
the HTTP request is unchanged. Full-text body search is out of scope. See
[implementation status](docs/Implementation-Status.md).

Gear-v1 content-defined boundaries are 2 KiB minimum, approximately 8 KiB mask,
32 KiB maximum. Schema 5 marks new chunks/body digests `plaintext-v2`; they use
SHA-256 identities scoped to a session, owner-only directories/files and verified
lengths. Session scope prevents cross-session sharing; it is not encryption.
Legacy `aes-gcm-v1` chunks/digests remain readable using their existing vault key;
missing or wrong keys preserve the old bytes and fail visibly. Fresh vaults do
not generate capture keys. Chunk files are synchronized before SQLite manifests
reference them. SQLite owns ordered offsets/lengths/references, request metadata
and context/output links, including compaction. Reads verify content identity and
length; exports also verify the whole digest. No historical request is regenerated.

`Requests-v1` is independent of preserved legacy `Traces` folders. Body expiry
and purge release only unreferenced chunks, retaining request metrics and links
within their separate retention window. After metric expiry, compact relationship
tombstones preserve the message-to-request lookup and explicitly mark unavailable
metrics. Active export leases protect chunk references. SSE event byte indices
are separately paged (4,096/request, 100,000/archive) and expire with bodies. Interrupted writers expose a verified
prefix. Persistent request/response safety limits are 32/64 MiB; live memory
limits do not silently truncate native persistence. The stored chunk quota,
body retention and metric retention are vault preferences. Current finite
metadata/chunk limits are 100,000 each; saturation is an explicit recorder error.
Reader races, metric-expiry relationships, restart and fixture UI checks pass;
the signed application remains a separate acceptance gate.

Store byte content once and reconstruct any retained attempt by ordered references. The versioned chunk store and per-body manifests retain chunk IDs, lengths, total length, whole-body digest, boundary and completeness. Content-defined boundaries reuse shifted prefixes; whole-body hashes alone would only reuse identical bodies. Compression and new encryption are not implemented.

Never reconstruct an old request by reserializing chat JSON, rerunning current prompt builders or resolving current skills. Store the serialized bytes that were actually submitted and the received byte stream. Keep request/response manifests independent of TCP/SSE chunk boundaries; retain event/timing byte offsets separately. Storage reads use bounded ranges without unbounded delta chains. The inspector and message-linked details assemble the complete retained body with cancellation and stale-selection protection, so response viewing has no manual pagination. JSON requests and responses default to a formatted, expandable tree. Responses SSE adds a default Combined JSON tree: prefer the terminal event's response object verbatim, including gateway extensions, usage and opaque fields. Otherwise reconstruct supported item/content/reasoning-summary/function-argument deltas and done events as explicitly partial JSON, bounding sparse indices and accumulated text. Invalid/conflicting or unsupported events remain visible in the separate ordered Events tree, with original fields, non-JSON data, sentinels and unfinished-frame labels. These are derived presentations; UTF-8/hex and original-byte exports preserve the recorded stream. Rendering must stay responsive within the existing 32/64 MiB capture limits. Incomplete captures keep their labels even if a terminal response object was retained. The event contract follows the [Responses streaming guide](https://developers.openai.com/api/docs/guides/streaming-responses) and the local SDK event types; derived JSON never substitutes for raw capture.

Add durable SQLite request/attempt metadata and message/turn/compaction relationships. Commit chunks/manifests/ownership atomically or publish a durable manifest only after referenced content exists. Verify hashes and lengths on reads, never silently repair corruption. Garbage collection must respect all live references and concurrent readers/writers. Requests can share chunks across a session; privacy boundaries and deletion semantics must be explicit before broader sharing.

Metrics survive body expiration. Expose expiry, truncation, capture-off, corruption and purge states; finite storage cannot promise unlimited retention. Durable capture discloses its plaintext storage and finite retention. Legacy encryption keys remain only in the same vault item. Exports are deliberate and preserve the recorded masked credential headers; historical hashed headers remain unchanged. Shifted-prefix, one-byte-change, binary/Unicode, cancellation, crash, disk-full, migration and shared-chunk deletion tests cover the archive. Full-text body search is explicitly deferred.

### 9.2 Single Keychain configuration vault (F14)

Implemented by `ConfigurationVault`, `KeychainVaultStorage` and `WorkspaceConfiguration`.
One schema/revision/CAS-protected object is stored as an ordinary macOS Keychain
generic password, service `com.belloware.PiApp.configuration`, account `vault-v1`.
No Data Protection selector or restricted access-group entitlement is used.
Missing data is created only on an
explicit save; unreadable/corrupt/future versions fail closed. A serialized
worker plus a cross-process advisory lock prevents cooperating app instances
from losing updates. The lock contains no configuration. Old SQLite and user
files are preserved but are no longer configuration authorities. Benchmark
environment hooks are test instrumentation; Sparkle's internal defaults are
overwritten from the vault before starting its updater.

The owner explicitly selected the same ordinary Keychain approach as Clipboard,
BelloTracker and BelloBox after comparing their working release implementations.
That supersedes the earlier Data Protection/provisioning requirement and the
interim plaintext-settings proposal. Keep the established Developer ID identity,
hardened runtime, secure timestamps and notarization without restricted Keychain
entitlements. The app's production backend checks its own signed identity; this
is not a system-wide denial of raw Security-framework calls from other programs.
Standard Keychain read authorization remains in force, but same-user raw updates
and deletion are not promised to be app-isolated. Record those limits explicitly
in the signed synthetic acceptance rather than mislabeling them as denied.
Existing Keychain items are not deleted or exported during this change.

Create one versioned configuration object containing app-owned profiles, endpoint/key/header settings, MCP configuration/credentials, discovery/policy preferences, runtime limits and capture/dashboard preferences. Imported AGENTS.md/SKILL.md source files remain external user documents, not app configuration that must be copied into Keychain. Conversation history, request bodies and metric events belong in protected storage, not the configuration item.

The native app is the sole vault reader/writer. Serialize updates through one actor, update the item in place, detect/reject lost-update revisions, and distinguish missing from locked/denied/corrupt data. Never replace an unreadable vault with defaults. Do not introduce per-profile items, plaintext fallback, credential command execution or helpers with broad vault access. Backward compatibility is not required, but destructive cleanup of existing user data still needs an explicit action.

Use the ordinary Keychain policy selected above; verify owner and authorized app-update access under real signing. Record other-application read/update/delete behavior separately from the app backend's own signature check. Signing alone must not be advertised as making arbitrary configuration app-only. Keep hardened runtime enabled without unnecessary JIT/debug/library-validation exceptions. Document same-user processes, administrator compromise, memory access and user-granted access as threat-model limits; do not claim absolute secrecy.

The helper receives only needed runtime configuration via private IPC, never argv/logs or broad child-process environment inheritance. MCP subprocesses receive only their explicit credentials. Raw bodies may contain user-supplied secrets even when authentication headers are masked.

### 9.3 Durable local dashboard (F15)

Record monotonic request dispatch, first HTTP byte, first nonempty content, first visible text, provider terminal event, and HTTP EOF/error/cancellation separately. Record wall time for filtering, never for elapsed calculations. Define:

- TTFT = first observable model content minus request dispatch; absent content is null.
- Streaming span = provider terminal event minus first content, when both were observed; label this, not server decode latency.
- Full HTTP duration = HTTP terminal time minus dispatch, including transport completion/error.
- User-turn elapsed, including tools and queue delay, is a separate metric, not substituted for HTTP duration.

Persist compact per-attempt records independent of payload retention. Request count is dispatched local HTTP attempts; user submissions, tool invocations, compaction and hidden gateway attempts are distinct. Filter by time, workspace/session, purpose, status, API, requested alias and reported effective model. Display request/error/cancel counts, active requests, sample counts, time series and p50/p99; offer drill-down into retained exact bodies.

Choose/document a reproducible percentile definition and test it on known data. Do not average percentiles, replace missing samples with zero, count incomplete runs as completed, or mix successes/failures without a visible selection. Use asynchronous bounded queries and parameterized filters; no raw arbitrary SQL or full Splunk language implementation is needed. Dashboard configuration belongs in the single vault.

Implemented in `DashboardQuery.swift`, `ReportController.swift` and
`ReportPage.swift`. Usage Report is a main-window page, not a dashboard sheet.
The controller retains filter/selection state, refreshes newly retained requests
on entry, and cancels pending work on exit. Applied labels stay tied to the
displayed snapshot while pending filter changes are indicated. Sidebar, app menu
and status-panel entry points use the same page state. Main and side chat views
remain mounted; a native visibility/focus guard hides their AppKit
surfaces, resigns the old responder and restores it only for the same selected
conversation. Conversation commands cannot send hidden drafts. Filters and
timing methodology expand on demand; controls wrap and request columns scroll
within smaller windows. Report/navigation animations use the app motion policy independently of macOS Reduce Motion.

Archive schema 4
adds nullable dispatch/TTFT/streaming/HTTP columns and an explicit model-identity
status column. Only timing-version-2 dispatch
observations count as requests; prepared and legacy records appear as a separate
excluded count. Migration decodes at most 32 metadata records per page. Normal
queries use typed columns and parameterized filters, never a full metadata scan.
Actual dispatch wall time defines the half-open time window; monotonic values
define elapsed time. Body purge preserves these columns, and independent metric
expiry clears them while leaving message-to-request tombstones.

The percentile definition is nearest rank: sort the n non-null observations and
select one-based rank `ceil(p × n)`. Zero remains a valid observation. Completed
requests are the default latency scope; selecting another status or all statuses
is explicit. Every status counter remains visible within the selected time and
workspace/session/API/purpose/model scope. Overall percentiles and each time
bucket are independently calculated from underlying observations with SQLite
window functions. The UI shows sample counts, request counts and percentile
points, up to 60 buckets and 128 rows per request page, then opens the exact
attempt in the native Inspector. A “No resolved model” filter includes missing,
conflicting and incomplete identity evidence while retaining their distinct row
labels and inspectable provenance, without substituting the requested alias. Defaults
for rolling hours and exact-value filters are saved only through the native
configuration vault. No Splunk server or query language is embedded.

### 9.4 Custom LiteLLM endpoint/key (F16)

Retain custom HTTPS endpoints and explicit loopback HTTP for tests. Normalize base URLs/full API routes once; test path prefixes, duplicate v1, wrong API leaf, credentials/query fragments and redirects. Both API selections refer to the selected LiteLLM endpoint. No automatic direct-provider fallback or silent protocol translation in the app. Preserve TLS certificate validation and test auth failure without leaking credentials.

Remove or clearly retire the old Pi models/auth import path in the LiteLLM-only product rather than maintaining another configuration authority. Connection tests require explicit user action and stay separately inspectable. Do not contact real gateways merely to discover settings.

### 9.5 Auto-router identity (F17)

Persist requested alias, response-reported model, any LiteLLM-reported route/deployment evidence, provenance and resolution/conflict status as distinct fields per request. Inspect the deployed LiteLLM Responses contract before hardcoding headers; preserve historical Messages evidence. Extract only allowlisted non-secret metadata; an opaque deployment ID is not a model name. Never infer an upstream model from `auto-router`, user text or model self-description.

Keep reported identity and the requested alias separately inspectable, with `unreported` when identity is unavailable. The assistant status line displays a single response-body name, preferring `router_model_name` over `model`; clicking opens sourced body/header reports and routing details. A body alias echo may be displayed literally but does not become verified upstream identity. Omit the inline model-conflict warning while preserving conflicting evidence and its effect on routing/replay. Routing may vary across requests in one session. Do not silently replace the next request's chosen alias with the previous effective model. Route-aware context limits, cache accounting and opaque reasoning replay need explicit compatibility tests; one gateway endpoint does not prove different upstream models share continuation state.

If a required identity is not exposed by the deployed proxy, document a minimal gateway metadata change as an external dependency. The app cannot recover undisclosed upstream routing or requests. Test two successive routed models, alias-only output, late/absent metadata, conflicting fields, malformed errors and both streaming/nonstreaming responses.

Implemented routing policy and fixture contract details are in
[LiteLLM routing and reasoning replay](docs/LiteLLM-Routing-Contract.md). Native
settings collect the metadata header contract and continuation policy in the
single vault. No actual-model header is guessed. Profile configuration revisions
are part of the opaque replay binding, so key/header edits cannot silently reuse
old fixed-route state. Header/body evidence remains separate from exact bodies.

### 9.6 Gateway cost and cache reporting (F18)

`GatewayTelemetry` retains bounded, sourced gateway observations per local HTTP
attempt. The verified upstream source contract is pinned in
[LiteLLM accounting](docs/LiteLLM-Accounting-Contract.md); the configured gateway's
behavior must be checked separately. Final Responses terminal `usage.cost` and
Messages terminal `message_delta.usage.cost` are accepted, with legacy
`usage.response_cost` evidence kept distinct. Nonstreaming JSON can report cost
in its final body or `x-litellm-response-cost` header. Pre-stream headers are
provisional Inspector evidence and never count as final zero-cost requests.
Interim Messages usage cannot finalize cost. Invalid/nonfinite/negative amounts,
conflicting amounts and absent reports remain explicit rather than estimates.

Response-cache HIT/MISS requires a configured, deployment-documented
`routing.cacheHeader` and contract reference. A cache key, model alias or positive
provider cached-token count does not establish a gateway cache hit. Prompt-cache
read/write tokens retain their own nullable values and sample coverage. No
accounting evidence can echo configured authentication keys into metadata.

The archive projects nullable cost/token values and status columns independently
of body storage. A durable projection marker is invalidated before schema edits
and set only after all bounded 32-record backfill batches succeed. Interrupted
migrations therefore resume even when every column already exists. Metrics
survive body eviction and expire under metric retention; changing retention or
refreshing the report also refreshes cached message/session totals.

User message Details retains attempts triggered by or linked to its turn. Inline
accounting prefers one linked assistant, then its streaming answer, then the user
row until an answer exists. Tool rows show no duplicate inline totals. Inherited
side origins may still be displayed. Indexed turn/output queries select one owner;
session totals use only that session's dispatched local attempts, and report
totals use the selected filter scope. Tool rounds and compaction are included
once, independently of the number of message links. Unknown costs are excluded
with coverage counts; explicit reported zero remains zero. Native footer/report
and transcript accounting lines show totals and separate cache/token coverage. Only
bounded numeric projections and allowlisted model-identity summaries reach
the transcript rows, not raw headers or bodies. Assistant status lines show one reported
body name from the most recent uniquely attributed request with a displayable
name; older captures may retain a verified gateway name. Projection version 6
backfills this nullable display name in bounded batches and expires it with
metrics, independently of strict identity status. The click-through retains all
reported names and missing, mixed, incomplete or conflicting identity evidence.
A configured alias is never used to invent a returned model, and a literal body
alias never upgrades routing identity.

The session header's usage control and footer cost open the same resizable
native window for that session, with Models and Costs tabs. Its session/project
scope persists across chat selection changes; multiple sessions can have separate
windows. Renames and accounting updates refresh the open window, and closing it
or shutting down its owner cancels reads and subscriptions. The overview includes
token components and sample coverage, explicit response-cache hits/misses and
known hit rate, reported/reasoning costs and historical output TPS. Missing
reports are unavailable, and reasoning/prompt-cache components are not added
twice. Both distributions use the archive's typed columns,
scoped by session and project, with bounded pages. Percentages use the entire
scope, including groups on other pages. Unknown costs are excluded with sample
coverage; a zero/unknown total produces no cost percentage. Parent request
links do not import cost into a child or fork. Queries cancel on window close and
reject obsolete session/page revisions.

The chat footer shows TTFT and output TPS from the same latest completed,
retained HTTP request in that session. Pending requests leave those values in
place until completion; missing values remain unavailable. Hover previews two
native charts of the most recent 128 completed requests, with gaps for missing
measurements and valid zeroes preserved. Clicking pins the chart for inspection.
Show latest-request TPS beside the weighted session average in both wide and narrow footers. The average uses all retained completed requests with valid output and timing, including requests older than the bounded chart. Show coverage and keep unavailable values distinct from zero. Reuse cached accounting updates instead of querying on render.

History is read from the session/project index with loaded-chat accounting, so
background completions and reopening update it without reading payload bodies.
The Session info window retains its explicitly historical aggregate rate.

Pending follow-ups can be dragged to reorder, rewritten in place, promoted
to steering (delivered after the current tool batch instead of after the run)
or removed; the helper validates every change (`queue.reorder`, `queue.update`,
`queue.steer`) and persists it with the queue. The sidebar's width is dragged on
its hairline and remembered. Chat and saved side titles are generated with the
connection's mini model or the catalog's mini default, never the conversation
model; without one, the app says so once per connection and launch, and the
chat keeps its first-message title. A failed title task releases its claim so
the next message retries, and says why in the chat's footer and the window's
banner (a task the reader or the app stopped says so in the footer only).
The title is read leniently, as models actually answer: the first
usable line, without a "Title:" label, bullets, numbering, quotes, emphasis
or a trailing period, cut at a word boundary past eighty characters; only an
empty or refused reply fails. Generate Title in a chat's menu asks again,
replacing an edited title too.

The Changes sheet (project header, conversation header, ⇧⌘G) runs the system
git for a project's folders the way IntelliJ's Git tool window does. The
toolbar carries a branch menu (switch to a local branch, or create one from
HEAD), fetch, pull (fast-forward only) and push with ahead/behind counters,
and a stash menu (stash everything including untracked files, pop a listed
stash). The changelist shows staged and unstaged files with status badges and
a checkbox per file and per section; Commit takes the checked files' working
tree state (or the staged index when nothing is checked), Amend folds them
into HEAD and prefills its message, and Discard, per file or for everything,
always confirms first because git keeps no copy. The diff pane renders hunk
headers, old/new line numbers and tinted rows, unified or side-by-side
(removed and added blocks paired line by line), with wrap. History filters by
message text or hash prefix and by author, optionally across all branches,
marks commits with their branch and tag badges, and a commit's file chips
narrow its diff to one file. Reads never touch the index; every write is an
explicit action.

Choosing a commit reads what it changed, not what it looks like: one `git show`
returns the message and the changed paths, a second returns their line counts,
and neither produces patch text, so the file list, "12 files · +340 −58" and
the per-file counts appear from two cheap reads. The patch follows separately,
read and parsed in the same background task so no diff text is ever parsed on
the main thread, and never inside a view body. A commit of more than 30 files
or 3,000 changed lines keeps its patch behind "Show the whole diff" and opens
one file at a time instead. Each commit's metadata, patch and per-file patches
are kept for the last 24 commits looked at, so going back to one costs nothing
and starts no process, and choosing another commit terminates the reads of the
last one rather than leaving them to finish into a discarded result. A file has
its own history from either panel: "Show History of This File" filters the log
to that path with `--follow`, and a chip above the list names it until it is
cleared. Sidebar totals load through one grouped archive query
instead of one query per chat.

Errors live in the conversation, not in a strip pinned above it: a failed run
appears as a card where the conversation stopped, a refused send as a card
under the messages, and while the helper retries a transient failure a status
line says so. The helper allows five retries after the initial model request
(six attempts total, with 1/3/5/8/10-second backoffs) before reporting failure: transport failures, HTTP 408, 425,
429 and 5xx, and provider errors describing overload, rate limits or
temporary unavailability are retried, a partial reply from the failed attempt
is dropped, and anything about the request itself (a missing model, an auth
failure, an oversized body) fails at once. The report names the attempt
count. Cancelling during the wait cancels; nothing is replayed after a tool
ran. The chat shows its newest page and loads earlier pages as the reader
scrolls up (or with the header's Earlier button), prepending them under the
reader's place; live updates keep merging underneath, and Latest returns to
the tail. The project helper keeps every opened chat and side loaded for as
long as the app holds it open: there is no cap on live runtimes and no
unloading of idle chats to make room (the three-runtime limit and its
"Three runtimes are active or pinned by side chats" refusal are gone). A
page never opens in the middle of a turn: when the newest page
begins with a reply's rows, earlier pages are pulled in (four at most) until
the user message that started the turn leads. An idle chat opens with that
question at the top when the last turn is taller than the window, so the
reader sees what they asked before the reply; a chat that is still working
opens at the bottom, a remembered reading position is restored as it was, and
sending a message returns to the bottom. Every scroll the page lands (to the
bottom, back to an anchored row, or through SwiftUI's scroll proxy when a row
has no frame yet) is deferred to the next run-loop turn: AppKit frame
notifications and SwiftUI geometry callbacks arrive while the hosting scroll
view is still mid-update, and driving the proxy from there trapped the app in
0.1.47. Up to eight hidden chats keep their pages in memory. A new chat or
an empty side exists only on screen until its first message: no record,
draft, journal or helper session is written for it, an empty pending chat
disappears when the user moves on, a second New Chat reuses it, a rename or
archive writes it first, and closing a pending side hands its unsent text back
to the parent composer. The app has one window; the menu bar item and the
Dock bring it forward instead of opening another view of the same chats. The
sidebar opens 300 points wide.

A reply that reaches the output limit is a complete row with `stopReason`
"length", shown with a warning under it (ask the model to continue); the
turn ends idle and queued follow-ups go on. The output budget is metadata:
it is never sent as a limit and never fails a turn. A conversation request
carries the model's catalog ceiling as `max_output_tokens`, clipped to the
room the context estimate leaves in the window, or no limit at all when the
catalog gives none; bounded tasks (connection test, title, compaction
summary) send their own small caps. The budget only sizes the local reserve
that decides when a chat compacts, and a request whose input fits the window
is always sent. The helper's HTTP stream buffers without limit,
so a consumer busy journaling or notifying the app never loses a chunk to a
fixed buffer, and a `stream_backpressure` failure, should one ever occur,
is retried like a transport failure. A run that failed or was stopped can be
retried from its failure row ("Retry request", helper command `turn.retry`):
the last user message, or the tool results after it, go to the model again
with the chat's current model, reasoning effort and budgets, which the app
sends with the retry (the pills as they stand when Retry is clicked, so a
model switched after the failure is what retries; cleared pills retry with
the connection's own defaults), the partial reply of the failed attempt
stays in the transcript but is never replayed, and queued follow-ups go on
after the turn; a completed turn has nothing to retry. Robustness rules the 0.1.48 pass added, each after a real or traced failure:
the app never waits on its own host command queue from the stdout reader
(a stdin write blocked on a full pipe would otherwise deadlock both
processes); a host handshake watchdog belongs to one connection attempt and
is dropped when the handshake lands, so a stale one cannot shoot down a
later, healthy host; a terminal's delayed SIGKILL is dropped once the child
is reaped, so a recycled pid is never signalled, and starting a running
terminal is an error, not a trap; a damaged request archive (a missing or
mistyped NOT NULL column) is a recoverable `corrupt` error, never a force
unwrap; the captured-JSON outline writes its SwiftUI selection on the next
run-loop turn, never from inside `reloadData`; the composer's scroller is an
overlay, so a reply reaching the height clamp cannot rewrap, hide the
scroller and rewrap again; and the slash-completion popup no longer forces
the composer to re-render on every keystroke.

Saving a connection never waits for its chats. A run that is going keeps
the settings it started with; the helper takes the new profile and key when
the run ends (`session.configure`, reported as `settingsPending` in the
status until then), an idle chat or side takes them at once without being
closed, and a chat whose run is still on the old settings shows a notice
above its composer. Only a changed API route still forks the connection.
Every confirmation the app asks for is asked in place: deleting or testing a
connection in the Settings footer, removing a project in the Projects sheet,
typing a model alias inside the catalog picker. No flow runs a system alert
from a sheet. Gateway failures are worded for the reader by the helper
(`ProviderClient.guidance` and `transportGuidance`): the provider's own
detail when it sent one, then the likely cause with what to check (the API
key for 401/403, the base URL and alias for 404, a rate limit for 429, the
gateway itself for 5xx, the final URL for redirects; an unknown host, an
unreachable gateway, a timeout or an untrusted certificate for transport
failures), keeping the "Provider returned HTTP N." prefix the retry policy
and the connection test read. Onboarding explains a disabled Continue
(`OnboardingState.gatewayHint`), greets a returning user whose connection is
saved, and names the last step "Start your first chat" once a project is
ready; the welcome screen offers New Chat once a project and a connection
exist. Settings edits connections through `ConnectionSettingsController`: every
saved connection is a tab, each tab keeps its own draft so switching never
discards an edit (a dot marks unsaved edits; Save writes every edited tab,
the current one last; Discard drops an unsaved one), the API key sits right
under the base URL, and the model picker lists for the draft as typed: the
bundled catalog without a key, a custom catalog with the key typed above or
the saved one, relisting when the URL fields change, and saying why when it
cannot list. Saves use the vault's current revision and retry once after a
conflict; a failed save stays on its tab with the reason in red.
Connections are renamed in Settings by their name field alone: the id, key,
chats and model cache stay. Delete Connection asks in the sheet's own footer,
where the button was, and says what the deletion touches: the key leaves the
Keychain item, its chats keep their history and ask for another connection
on their next message, the current-connection choice moves to a remaining
one, and a run still going under the connection is stopped and its helper
session closed. Nothing about the deletion waits on work or on a side. A
connection whose API route was edited is saved as a new connection, the old
one staying for its earlier chats and following the new one's model catalog
(`catalogSources`); the sheet stays open after such a save and explains the
extra tab. Deleting either of them drops that link, the vault is read back
to prove the connection is gone, and a deletion that does not happen says
why in the footer, in the window's banner and in the system log (subsystem
`com.belloware.PiApp`, category `vault`); the list never quietly stays the
same.

Motion follows one set of tokens (`PiMotion`: quick 140 ms, base 220 ms,
slow 320 ms, a spring that pops and a spring that glides), and every use
uses the app policy through `piAnimation`, independently of macOS Reduce Motion. The sidebar's selection
highlight glides independently of its usage labels; tab strips slide their
selected pill; copy controls and buttons retain brief feedback. Starting in
0.1.50, chat replacement and side/terminal/queue size changes apply their final
geometry directly. `piStableLayout` prevents ancestor animations from
interpolating the native composer and transcript. Typing height and live usage
updates do not animate; starter/loading/error fades are confined to overlays,
and starter appearance finishes within 200 ms. Report query results replace
data without animating the entire list. Deliberate disclosure and decorative
feedback can still animate locally. Starting in 0.1.67, app-owned loading, waiting,
caret and transition animations remain enabled even with macOS Reduce Motion on.
`piReduceMotion` supplies the same app default to every SwiftUI hosting root; native
transcript disclosures and jump-to-latest scrolling use `PiMotion.reducesMotion`.
The app never changes the system preference. Explicit local/test motion overrides
remain available, and layout stabilization still removes inherited geometry animations. The transcript keeps exact row
geometry: streaming below the viewport must not move the reader's rows.
Starting in 0.1.55, an AppKit scroll document retains the exact frames and row
hosts, but attaches only the viewport and a small surrounding buffer. Selected
native text stays attached outside that buffer so scrolling does not discard
selection. Long Markdown replies similarly limit attached block hosts without truncating
content or copy targets. Native reflow
preserves the visible row and pixel offset, including when an earlier disclosure
changes height while scrolling. Visible geometry is measured when content or width changes; valid exact geometry
is reused. Since 0.1.71, distant blocks in large answers retain provisional
geometry separately and resolve near the viewport, preserving a logical source
block and offset. Provisional sizes never enter the shared exact cache.

What the reader has opened or closed in a conversation (a turn's work, one tool
call's card, exposed reasoning, a compaction note) is conversation state, not
view state (0.1.59). `TranscriptDisclosure`, owned by the session's display,
keeps only the parts the reader changed, keyed by the turn's stable key rather
than the id of its latest row, so a turn folded while it streams stays folded
as it grows, and forgets the parts of rows that leave the conversation. Each
row host reads its own slice as a plain value and compares it like content: a
click records the change, rebuilds that one row, drops its measurements and
lays the document out in the same pass, so the rows below move with the click
instead of one or two run-loop turns later, and the row clips to its frame in
between. The shared geometry cache is keyed by that value, so a height measured
with a card open is never handed to the same row closed. Folding and unfolding
do not animate: the AppKit frame snaps, and a 220 ms height animation only
kept the whole tree re-measuring for the duration, which is what let text of
neighbouring rows paint over each other. A folded turn keeps its list in the
tree at zero height and clipped; tearing down sixty tool rows on a click and
building them again on the next was most of the click's cost.

A terminal panel (⌃`, View menu) opens under the conversation, as in VS Code:
one login shell per project, kept alive while hidden, resizable by dragging
its top edge, restartable after it exits, with the gateway keys stripped from
its environment. Its emulator takes output at tens of megabytes a second:
runs of printable ASCII print in one pass over the row, character widths are
looked up once per scalar, a full-screen scroll dirties the screen at once,
the history gives up its oldest lines in batches rather than one at a time,
and the state every byte touches skips Swift's dynamic exclusivity checks.
A streaming reply is parsed in settled parts plus a live tail: the text is
cut after a blank line outside any code fence, before a line at the margin
that is not a list item, so fences, lists, quotes and tables stay whole; the
settled parts are remembered by the Markdown cache and only the tail parses
again on each delta, and every inline run is dressed once at parse time.
`PerformanceBaselineTests` measures actual row layout after async binding,
streaming with deferred UI work between deltas, and full attributed syntax
coloring, in addition to parsing. Snapshot probe timings are labeled as
snapshot application, not visible paint. Timings are observations rather than
machine-dependent pass thresholds. Unchanged journal revisions reuse retained
pages/drafts/anchors; automatic turn-boundary repair fetches only the missing
start of the turn instead of successively adding unrelated older pages.
Hiding the terminal returns focus to the composer, and opening a chat
always focuses the composer. Double-clicking a chat renames it in a sheet
that, when the connection has a mini model, suggests three titles from the
conversation; each project lists five chats and a "Show more" row pages the
rest, keeping the selected chat visible. Every chat row has an archive icon
that asks once, inline, and archives on the second click.

The status panel is one page: a "Now" list of chats that are running, waiting
on the user (queued, paused, failed) or holding unread replies, each opening
its chat; then the period tabs, token and cost tiles, a chart switching between
requests, reported cost and historical output tok/s per time slice, a model
distribution bar chart with the resolution rows, and the expandable
timing/cache/request details. There is no live output-rate estimate in the
panel. Sidebar rows mark an
unread chat with a dot, never a count, and list cost with input, cached-input and
output tokens; unreported usage reads n/a rather than zero. A reply becomes
unread, on the sidebar dot and the Dock badge alike, only when the run has
finished and reported back; tool-round messages appended mid-run wait for the
idle snapshot. The Dock badge counts chats with unread replies, one per chat
however many replies each holds. Archiving a chat never switches the sidebar to the archive: the
archive is opened deliberately, and archiving the selected chat moves on to the
nearest active chat in its project. Projects open and are
created without a trust confirmation, and no Trusted badge or "Editing tools"
notice is shown; read-only and tool-less chats keep their footer notice. Historical TPS is summed reported output divided
by summed dispatch-to-model-completion time for completed, retained, dispatched
attempts with valid usage/timing. Since 0.1.52 a typed `request_ms` projection
stores model completion minus dispatch independently of first visible content.
Retained metadata is reprojected on migration, and expiry clears this field.
TTFT/streaming observations remain independently nullable. Include first-token
latency and zero stream spans when total duration is positive. Reported output
already includes reasoning: never add that subset again or count streamed bytes.
Rates and sample counts are calculated overall and per requested/resolved model
group. The sidebar, footer and usage views show the actual latest completion and
a duration-weighted average. A new in-progress request leaves that latest value
steady; a completed request missing usage/duration is explicitly unavailable.
Numeric layout stays stable and local transitions follow the app motion policy.
Activity protocol version 2 retains phase/model/tool/queue status and removes
byte-derived token-rate fields. This is request-average throughput, not server
decode speed or a fabricated instantaneous rate.

The strict local gateway validates method/path, model, API-specific headers and
body fields, token limits, tool schemas/call IDs/results, native-versus-portable
replay and summary source history before generating a response. Continuations
depend on the supplied tool result, and cache hits depend on identical serialized
requests. Negative probes must fail instead of receiving generic success. This
fixture proves the application request/capture behavior; it is not an installed
LiteLLM process or a claim of paid/deployed gateway acceptance.

## 10. Session correlation, multi-root workspaces, per-turn overrides and edit branches

**Correlation (H1).** Every LiteLLM request carries `x-session-id: <sessionID>`
and `x-turn-id: <turnID>`; a compaction or auxiliary request carries that
purpose's turn identity. Responses bodies also carry
`{"metadata":{"session_id":"<sessionID>"}}`; Messages bodies never grow a
metadata field. Values are reduced to the identity alphabet `[A-Za-z0-9._:-]`
(at most 128 characters) so no identity can inject a header. Both names join
the transport-owned header denylist, so a profile custom header cannot replace
them, and they are ordinary capture headers: they stay readable in attempt
metadata and never trigger credential hashing of the request body. The local
fixture rejects requests missing either header or whose Responses metadata
disagrees with the header.

**Multi-root workspaces (H2).** `workspace.open` accepts `roots: [String]`
(1…16 absolute directories, primary first; duplicates collapse after
canonicalization) in addition to the legacy single `cwd`. The reply lists
`cwd`, `roots` and `directory`. A second open with a different root set, or a
legacy `cwd` that differs from the bound set, throws `workspace_conflict`.
`Resources`, `NativeTools` and `MCPManager` receive every root. Instruction
discovery walks each root's repository-root-to-root chain once; skill
discovery covers every chain; the system instruction lists all roots and states
that relative paths resolve against the primary root. Tools resolve relative
paths against the primary root; for read, ls, find, grep and edit, a relative
path that does not exist there but exists under exactly one other root resolves
to that root. `write` of a new file always targets the primary root. stdio MCP
servers start in the primary root. `resources.inspect` reports `roots`.

**Remembered chat choices.** Desktop metadata stores the last deliberately
selected model, effort and catalog limits per connection. A picker choice and
its chat record commit atomically, with writes serialized per connection. New
ordinary chats wait for a pending choice and inherit it; selecting old history
does not replace the remembered choice. An explicit nil/default record differs
from an absent record, which can use the current same-connection chat on upgrade.
Connection defaults remain separate; onboarding/tests use their tested connection,
and sides/forks inherit their parent. Visible pickers load their saved catalog
without a hover and refresh on saved connection changes, using the shared cache.
The open searchable picker observes fresh catalog results directly, rather than
freezing the choices in a native menu snapshot. Opening it rechecks cache expiry;
configured catalogs remain its sole list source. Without a custom URL, the
signed app's bundled `bello-agent.models.json` is the sole source, also for
legacy decoded connections. It is copied directly from the reviewed repository
catalog and parsed by the same endpoint parser. Loading the bundled list never
reads credentials or contacts `/v1/models`; a missing/corrupt bundle resource
surfaces an error. Source changes invalidate cached lists. Optional flat
`catalogSources` references in the vault separate catalog authority from request
profile snapshots. Every list consumer, descriptor/effort lookup and mini-model
recommendation resolves this authority; requests still use the original profile.
Explicit selection can link an old connection to a saved catalog. New same-gateway,
same-API, same-credential default-model forks retain the established catalog
linkage. Independent connections and legacy lookalikes are never merged by inference.
Unlinked older routes visibly offer later saved custom catalogs for the same
gateway; a direct action (or chooser for several alternatives) saves only the
catalog binding and refreshes the mounted picker. Suggestions use saved record
order, not `profileChoice`, which changes when a chat is selected. Existing
explicit links and different gateways do not produce a repair suggestion.
A follower's edited URL detaches only that connection. Catalog credentials come
from its selected saved authority and only leave on that authority's matching origin;
external catalogs stay anonymous. Refresh reloads bindings and configuration,
bypasses cache TTL, requests HTTP revalidation and shows the success time.
No automatic replacement of a selected alias/effort is required.

**Mini-model tasks.** Store a separate optional mini-model alias per connection;
an active catalog mini recommendation supplies the default when none is chosen.
Title generation runs as a durable tools-disabled session outside user projects,
with a fixed task title and a relation to its source chat. It uses bounded text
from the triggering input and a small output limit, with independent capture and
accounting. Background sessions are hidden by default but explicitly browsable.
Never overwrite a manual title or recursively generate a task session's title.
No configured/recommended mini model means no auxiliary model call. Uncertain
or interrupted jobs must not automatically resend on restart.

**Per-turn overrides (H3).** `turn.submit`, `turn.steer` and `turn.edit`
accept optional `model` (1…200 characters) and `thinkingLevel` (`default`,
`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`), plus optional integer
`contextWindow` (1…10,000,000), `maxOutputTokens` (the requested budget, 1…1,000,000),
and `modelOutputLimit` (the optional supported ceiling, 1…1,000,000). The effective
context capacity must exceed the output budget; the ceiling is independent of
the budget (either may be the larger) and is what the request carries as its
output limit. Preflight reserves the budget and a separate safety margin only
to decide when to compact. Invalid values fail
at submit time with `invalid_params`, before queue or edit-branch mutation.
The override is stored on the queued
`Submission` (so it survives a paused restart) and applies to every request of
that turn only, including tool rounds and a compaction triggered inside it.
Omitted limits inherit the session profile; supplied limits govern request
output, context preflight, summary input bounds and active context metrics.
Idle host metrics revert to the session profile; the composer can project its
selected next-turn limits separately. A model switch discards another alias's
token-usage baseline and effort translation map. A chat can also move to
another saved Responses connection from a composer pill (shown once more than
one is saved): the switch is refused while the chat is working, for imported
history, connection tests, background tasks and side conversations; otherwise
it closes the open helper session, rebinds the chat, keeps a model override
only when the new connection's catalog lists it, re-derives limits and effort,
and the next turn reopens on the new endpoint and key with the portable
history replayed there. Unlike model and effort choices it is not remembered
for new chats, though the switched chat's connection becomes the next-chat
default while it is selected. Sidebar rows name each chat's connection once
more than one is saved. Explicit non-default effort
enables serialization even if the profile omitted reasoning; explicit `default`
omits inherited reasoning/effort options, while an omitted effort inherits the
profile. Headers and API compatibility remain connection configuration;
Messages adaptive-versus-budget behavior needs a gateway-specific compatibility
setting and is never guessed from model names. Attempt metadata
`requestedModel` reflects the requested alias and the journal user record
stores `modelOverride`, `thinkingLevel`, `contextWindow`, `maxOutputTokens` and `modelOutputLimit`
when present. A different alias leaves
the configured pinned route: that turn's assistant messages are recorded with a
portable binding, and any assistant message whose recorded binding names
another alias replays portably (its opaque state is retained, not sent) rather
than failing the route check. The journal's session binding marker is unchanged,
so reopening a journal with override turns passes the binding check.

**Edit branches (H4).** `turn.edit` takes `{messageId, text, clientTurnId,
attachments, skills, model?, thinkingLevel?}`. Preconditions: the session is
idle with empty queues, it is not an unkept (ephemeral) side chat
(`side_ephemeral`; keep it first so the branch is durable), and `messageId` is a
user message in the current context (`edit_target` otherwise); the new
submission is validated before anything is written. The host appends
`{"type":"branch","id","parentId","timestamp","fromMessageId","keptIds":[…]}`
where `keptIds` are the context messages strictly before the edited message.
The optional `nativeState` field contains the accepted replacement queue and
command state in that same record: failure cannot publish only a branch, and a
restart after the branch restores the replacement paused without resending it.
The live context becomes exactly those messages, a display-only marker with
`kind: "branch"` and text `Edited from here · earlier replies stay in the
journal` is appended to the timeline (never to the model context), then the
text is submitted as a normal turn. The journal remains an append-only single
parent chain; nothing is deleted, and abandoned messages stay readable through
`session.message.read`. Journal load replays branch records in order, as does
the portable preview. `session.snapshot`, `session.history` and content search
show the visible timeline: the active context plus rows after the branch, not
the abandoned tail. A compaction summary retained by the branch stays visible
even if its journal record followed the edited user message. Content-page
revisions combine visible and journal counts.

**Compaction checkpoints (0.1.64).** `CompactionPlanner` validates complete
assistant/tool groups with occurrence-scoped call IDs. The current task root and
delivered steering are protected inputs; old ambiguous legacy inputs are also
protected. The planner can summarize the newest complete group when keeping it
would exceed capacity. `CompactionSourceBuilder` preserves requested tool
arguments and observed outcomes, labels omitted evidence and emits scoped
`history_read` references. Historical text never grants skills or approvals.

`SessionSummarizer` uses the same selected connection/model, tools disabled, and
at most eight physical requests including chunks, merges and transient retries.
The output allowance is the model ceiling, respecting an explicit task/cost cap
and actual input headroom; without a catalog ceiling it uses the configured budget.
Each dispatched summary profile reserves the full transmitted cap plus the
existing safety margin. The session's reasoning effort is unchanged. Source
records come first and the compaction instruction is the last input message,
with no requested character/token length. This preserves a stable source prefix;
actual prompt-cache hits remain gateway observations, not a client guarantee.
These owner instructions supersede the original 4,096 cap and the addendum's
proposed 16,384/32,768 defaults, low effort, and visible-summary target.
Source/intermediate data is bounded to 2 MiB; each actual summary body gets an
independent capacity check. Explicit summary-input rejection shrinks packing
within the same budget. Non-shrinking merges, incomplete output and a candidate
that does not reduce the actual next request fail without adoption.
Typed terminal metadata distinguishes explicit output exhaustion, other/unknown
incompleteness, refusal, empty text and unexpected tool calls. A headroom-clipped
exhaustion may reduce its source once to make more of the model allowance fit;
a full-cap exhaustion cannot be escalated above that ceiling. All attempts share
the same eight-request budget and retain their usage, diagnostics and captures.

Version-2 `compaction` records retain ordered source/protected/kept IDs, exact
summary dependencies, task root, before/after count provenance, operation and
attempt IDs, output allowance and recovery linkage. An explicit synchronized
append flushes preceding tool writes. Memory adopts the checkpoint synchronously
before any trace-link await. Failed synchronization poisons the writer; reopening
validates either a complete old or new projection and never replays work.
Queue changes do not invalidate frozen context; immediate configuration/context
changes do. Native history indexing and portable export validate checkpoint
version/order instead of silently filtering missing IDs. Editing a protected
input abandons summaries that depend on it. Forks retain original sources but
start independent recovery state; a side with only a boundary snapshot reports
missing ancestor evidence as unavailable.

Only typed context rejections trigger one durable reduction/retry allowance per
logical model operation. Transient HTTP retry remains separate. No complete tool
batch is rewound, and a length-truncated tool request stops without invocation
or automatic regeneration. Summary usage is linked per physical attempt; it
does not replace the normal-request context meter. Snapshot progress omits large
source-ID arrays, which remain in the checkpoint journal.

**Display kinds (H5).** Display messages carry optional `kind` and `detail`.
The compaction summary row has `kind: "compaction"` and
`detail: "Compacted N estimated input tokens · M messages kept"` (tokens estimated before
compaction, kept message count), reconstructed from the compaction record on
load. The branch marker has `kind: "branch"`. Ordinary rows omit both fields;
role, text, thinking and tools are unchanged.

**Tool call input (H6).** A tool card's `input` is a *document*, not prose:
the transcript parses it to show "Requested edit" with a diff. The host never
cuts the encoded document at a byte offset, because that lands inside a string
value and nothing parses. Long *string values* are cut individually and each
carries the marker `…[truncated, N more bytes]`, so every key survives and
`input` always parses at any argument size. Three fields describe it:

- `input` — the bounded document, at most 4096 encoded bytes. This inline
  preview rides along on every display snapshot.
- `inputTruncated` — `true` when that document is a partial view of the
  arguments. The legacy `truncated` flag stays `inputTruncated || output was
  cut`, so an app that does not read the new fields is unaffected.
- `inputBytes` — the full encoded size of the arguments, so the app can label
  the preview and decide whether to fetch the rest.

The inline preview stays small because the display page is re-sent whole on
every streamed delta and the transport terminates the helper above a 1 MiB
frame. The complete bounded document is fetched once, on demand:
`session.tool.input {sessionId, messageId, callId}` returns
`{id, messageId, name, input, inputTruncated, inputBytes, limit, streaming}`
with `input` bounded to 65_536 bytes for tools whose arguments carry file
content (`edit`, `write`, `apply_patch`, `multi_edit`, `str_replace`,
`notebook_edit`, and any `*_edit`/`*_write`/`*_patch` name) and 8192 bytes for
every other tool; the same per-value cutting applies there. A call that is
still streaming returns `streaming: true` and the accumulating argument text,
which is not yet a document. Unknown message or call ids fail with
`message_missing` / `tool_call_missing`. The app reads this when a card is
`inputTruncated` and it wants a full diff; the fields and the method are
additive, so older journals and older app builds are unaffected. The helper
advertises `tool-input` in its ready-frame capabilities.

**Queued message text (H7).** A snapshot's `queue` rows carry a 1 KiB `text`
preview beside `textBytes` (the whole submission's size) and `textTruncated`.
An editor must never write that preview back: `queue.read {sessionId, turnId}`
returns `{turnId, commandId, kind, text, textBytes}` with the complete text,
bounded only by the 256 KiB submission limit, and `queue.update` takes the
full text. The helper advertises `queue.read`.

A projected assistant row shows at most 32 tool cards, streamed or durable,
and sets the row's `truncated` when the reply announced more; a row is always
admitted to a display page even when it is over the page budget, so its card
count and every preview it carries are bounded by encoded, not source, bytes.

Coverage: `ContractTests` (host package), `test-native-host.py` wire, journal
and negative-probe cases, the shared fixture contract's correlation checks,
and `ToolInputDisplayTests` for the bounds above.

## 10. Project navigation and inspection follow-up (0.1.5)

Project is the user-facing name for an existing workspace. Preserve its IDs, paths and helper ownership. Sidebar project disclosures and archive filters live in desktop metadata; session title/pin/archive edits carry independent revisions so delayed path/model writes cannot revert organization. All project rows retain billing caches. Capture metadata commits invalidate affected session totals even when the chat is unfocused; query generations prevent older reads from replacing newer billing.

Project topics are local desktop records (`TopicRecord`, kind `topic`), with a
stable ID, owning project, title, creation order and saved disclosure state.
`ChatRecord.topicID` is optional so older chats remain at project level. Topic
membership shares the chat's independent organization revision: delayed
path/model writes cannot undo a move. Batch branch moves and topic removal are
SQLite transactions; removal clears membership and retains a tombstone, never
deleting journals, drafts, captures or queued work. Generic metadata writes
normalize deleted/invalid group references to project level rather than block
conversation persistence. Explicit moves validate all selected sessions and the
destination before writing; another project's topic is never a valid target.

Topics precede ungrouped chats in the native sidebar and keep independent chat
paging and disclosure. Filtering opens matching groups without overwriting their
saved disclosure preference. Selected chats reveal their group. A child whose
parent is in another group remains visible as a root in its own group; moving a
parent includes its same-project descendants with cycle protection. Pending
sides inherit the parent's latest group when published. Forks and continued
copies inherit their source's group. Native drag data uses a bounded,
process-local session/project payload and routes through the same model command
as Move to Topic. There is no filesystem move, host start or model request.

Several rows can be marked for one action: Shift-click extends a range in the
order the sidebar lists chats, Command-click adds or removes one row, and an
ordinary click drops the marks and opens the chat (Control-click stays the
context menu, as macOS expects). Marking is presentation only. A bar above the
list says how many are marked and archives or restores them in one press, and
a right-click on a marked row offers Archive, Restore, Pin, Unpin, Move to
Topic and Mark as Read for the whole set, each through the same durable path
as its single-chat menu item, one write per chat, with the marks spent by the
action. A range covers rows inside a collapsed side or a folded page too, which
is why the count is always shown before acting. Dragging a marked row carries
every marked chat of that project in one payload, bounded like a bulk action
and previewed as "N chats"; dragging an unmarked row still carries only itself.
Marks never cross into a bulk delete: chats are still deleted one at a time.

Starting in 0.1.68, the marked-row menu and selection bar also copy all selected
session references, without consuming the marks. Single-session references use
the same path. Each reference contains identity, the actual journal path and a
shell-quoted read command, plus gateway-reported retained token counts, cached
input, reasoning tokens, reported cost and reasoning cost, with per-field sample
coverage. Cache/reasoning are labeled subsets; unknown or expired observations
are not replaced with zero or estimated from transcript text. Request metadata
is read on the archive actor for the chosen project/session scopes in bounded
200-session batches; copying starts no helpers and reads no conversation bodies.
Selected IDs/order are fixed before the read, with current records rechecked
before writing the clipboard. A newer copy, changed clipboard, deleted chat,
cancelled task or shutdown prevents a stale result overwriting clipboard data.


A chat row's press belongs to AppKit (0.1.59). SwiftUI's `.onDrag` on a row
inside a `Button` never started a drag, because the button claims the press
on macOS, so the sidebar showed no drag at all. Each draggable row now carries
a transparent `TopicSessionDragSurfaceView` that claims only a plain left
mouse-down (Control-click and the right button still reach the context menu;
hover, tooltips and scrolling pass through), runs an event-tracking loop, and
past four points begins a real dragging session with the row's pasteboard
item and a rendered "N chats" image; a press that ends without travelling is
the click the row always handled, decided in one place (`SidebarRowClick`)
for both the pointer and keyboard activation. The row publishes the bounds of
its own controls (archive, its confirm pair, the side chevron) so the surface
declines those presses. The source offers move, copy and generic inside the
application and nothing outside it, because the drop zones answer with copy.
Those zones are the whole project group and the whole topic group, not their
header strips: a chat dropped on a topic's rows lands in that topic and one
dropped beside a project's rows returns to its root, with the header still
highlighted to name the receiver. A draggable row shows an open hand instead
of the pointing hand, pushed and popped exactly once.

Retained HTTP capture defaults to plaintext bodies and masked headers for 30 days, subject to quota. Existing explicit settings and historical captures remain readable; the legacy seven-day default migrates once. Ordinary headers remain inspectable, authentication values retain only a short masked suffix, and credential echoes cannot restore full secrets. Body credentials remain explicitly hashed byte transformations. Inspector pages load bodies directly.

The context ring opens a read-only request preview from authoritative session context and the provider builder. Opening a session applies the helper's context estimate immediately. Selecting a chat previews after a short pause; typing waits 1.5 s after the last keystroke before the helper recounts the draft, showing the pending state meanwhile. The footer and inspector primary meter use one scope resolver: the current request's bound estimate/report, a labeled last-request observation during tools/retry backoff, or a matching next-input preview while idle. A new submission shows preparation before helper work; unrelated older usage cannot become current. Request generation/attempt identity is distinct from replay-input revision and helper epoch. Stream/status events do not expire a valid preview. Committed replay or applicable configuration changes do, as does the existing five-minute age limit. Previewing is observational and never replaces preflight state. Explicit resets clear current state, while omitted fields retain unchanged values.  An idle preview includes the draft and selected resources; a running preview excludes unsent and queued turns. Selecting a safe idle tab automatically calculates a preview after history and draft restoration, with a short debounce, deduplication and loading state. Only the focused chat is prepared. Local helper startup is allowed; model requests and tool execution are not. Read-only journal indexing rejects unresolved tool calls or pending native work before automatic opening. Imported, untrusted, archived, background, interrupted and active sessions are skipped. Cancellation and input/selection checks reject stale work; new journal paths are persisted even before sending. Explicit inspection remains available on failure. Preview snapshots must stay bounded, reject stale results and remain distinct from past wire captures. Skill disabling belongs to Bello Agent configuration; shared Codex sources remain untouched.

The main WindowGroup uses SwiftUI's [hidden title bar](https://developer.apple.com/documentation/swiftui/windowstyle/hiddentitlebar)
and AppKit full-size content consistently. A 36-point custom drag/control area
occupies the top of the sidebar; chat/report headers begin beside it without a
second blank row. The root extends through the top safe area so SwiftUI cannot
apply a second title-bar inset. The native title/backdrop
and separator are hidden, while the titled window and its standard traffic-light
controls remain for keyboard focus, close, minimize and full-screen behavior.
Only the header background starts native window dragging or double-click zoom;
content, controls and attached sheets keep their own events. Zoom toggles the
available-screen frame without animation. Window tests must include the real
app-hosted SwiftUI scene after layout/resize, not only manually created NSWindows.

## 11. Rules kept by the 0.1.59 audit

Version 0.1.59 was a sweep for the bugs a passing suite had not found: six
agents hosted the real views in real windows, drove them as a user would and
fixed what they confirmed, keeping each reproduction as a test. The rules
that came out of it are design, not history, and later work keeps them.

Nothing stops the main thread to ask a question. `NSAlert.runModal()` and a
modal open or save panel freeze every other chat's stream, its live bar and
its timers, and re-enter AppKit's own window and application callbacks from
inside the one that is running. A question is a sheet on the window that
shows what it is about (`ChatPrompts` for a chat's own questions, `PiPrompt`
for everything else, `GitDiscardConfirmation` in the Changes panel; the close
refusal and the quit question the same way), one at a time, with the work
continuing in the completion or resumed through a continuation; the
application-modal form survives only where no window can host a sheet.
`BlockingAlertTests` reads the converted sources and fails on a new
`runModal()`.

The sidebar answers a workspace change in one frame. Chat and side lookups,
per-group buckets, entry lists, project groups and the keyboard order come
from one `SidebarIndex`, rebuilt lazily once per change; every scan of
`chats` per row was the O(chats²) the owner felt as a stutter. The metrics
line under a chat measures its figure strings once and builds only the form
that fits the width the sidebar passes down (a 600-case oracle against
`ViewThatFits` agrees), truncating only as a last resort. What the reader
folds or pages in the sidebar (side chats, "Show more") is model state and
travels in the project-sidebar record. A Shift range covers exactly the rows
the filter left listed. A press on a row is owned by AppKit and can never
wedge the app: the tracking loop polls, gives up when the button is no
longer down or the row has left its window, and acts on nothing after that.

The transcript measures what the reader can see. The reading anchor is
resolved once per layout, never per row (an O(rows²) walk made a pane-edge
drag over 500 rows cost 729 ms a frame). During a live resize the document
measures from the top of the page to the bottom of the viewport the reader
will see and leaves the rows below standing, out of the view tree, at the
height they had; the end of the drag (or a 200 ms grace timer) measures
everything; a width change that is not a drag keeps the exact pass. Rows are
laid out once per reflow, hover-only controls are built with the pointer
(and offered as accessibility actions), a folded turn's list is not placed
at all, and a block is keyed by the settled form of its reply id so a turn
folded while it streams stays folded when it settles. Reasoning and
compaction fold through the transcript's own header. An edit's diff is
computed once per call, off the body, and refused past 4,000 lines. A tool
card whose arguments were cut shows what arrived and fetches the whole
document through `session.tool.input` when opened; a chat read from disk
builds the same card as a live one.

The helper never exits on a frame. Every preview bounds encoded bytes, not
source bytes; a tool call's display input is a document that always parses
(long values cut individually, keys kept, `inputTruncated`/`inputBytes` set);
streamed cards are projected in arrival order, capped at 32; live tool cards
retire oldest-first within 1 MiB; a queued message's whole text comes from
`queue.read`, never from its preview.

Storage tells the truth and stays off the main actor. The desktop database
opens inside its actor on first use, not in the first `body`; journal paging
resolves through the offset index and decodes a record once; id-less
imported records are reachable; a read failure says it could not read, a
missing journal says it is missing, a long conversation is browsable with a
notice rather than "damaged", and chats the sidebar could not list are
reported once. Capture work is priced per request, never against the whole
archive: the retention deadline moves to the finishing request's own expiry,
totals are kept in the actor, a page of attempts is two statements, a sweep
is one transaction, and no view body decodes a captured payload. A stalled
Keychain call admits bounded retries with an actionable message. The idle
stop of a project helper never makes the next message fail: connect waits
for the previous helper's exit. Quitting materialises a never-sent chat that
has text. A chat record this build cannot decode is skipped everywhere, not
only in the sidebar, so one bad row cannot disable topic moves.

The Changes panel and the terminal keep the reader's place. The panel
watches the working tree (FSEvents on the root and on the real git
directory, HEAD/refs/index only inside `.git`, one refresh a second, root
changes handled) and an automatic refresh never moves the selection, the
ticks, the scroll or the whole-diff gate; a reader's own refresh always
wins. Git paths travel in batches (Foundation raises past 4,096 arguments),
reads wait on their own queue behind an eight-process gate, patches and file
chips are lazy, and superseded reads are cancelled. Terminal output is
delivered in whole chunks, the bell is coalesced, the history is text plus
style runs with a cell ceiling, a scrolled-back reader holds their line as
output arrives, and shells end with their projects and at shutdown.

## 12. Rules kept by the 0.1.60 pass

Version 0.1.60 raised the bar on how the app feels: performance, smoothness,
an intuitive UI and code quality, each driven by an agent that measured in a
Release build and kept its measurement as a test. The rules it established:

The transcript shows the viewport first. Opening a chat measures the rows the
reader can see (and the rows the anchor will show), estimates the rest from
their typography for the scroll bar, keeps estimated rows out of the view
tree, and measures the remainder in idle slices that never move the row being
read. A row builds its SwiftUI tree when the reader reaches it (prepared a
few screenfuls ahead in the direction of travel) and gives it back when they
are pages away; the conversation pane is kept across chats, and rebinding
releases everything the previous chat owned. A width change that is not a
pane drag uses the same standing-rows mechanism. A row is sized once per
measurement. A turn's tool calls draw through a viewport-culled native
surface where a closed card is one line high, checked against the first
cards that mount and never trusted.

Motion is driven by the document from geometry measured once. A fold, a card,
reasoning or a compaction summary measures its target exactly, rewinds to
the old geometry, and eases the changed row's height over `PiMotion.base`
while every row below shifts by the same amount and the document's height
follows each tick; the region the two states do not share is masked and
faded on the row's layer; a second click retargets from the interpolated
geometry and streaming lands after the motion; an explicit local motion override snaps. Nothing
animates a height through SwiftUI. The shell's own motion (rows unfolding,
panels sliding, the strip arriving, pills cross-fading, the live bar sliding
into its slot) takes its slot in one step and moves inside it, so the reader's
line never drags; a transition that costs more than it is worth (a cross-fade
of a chat switch: one second) is left out.

A streamed token costs its row. The helper sends the changed rows and the
appended text (`messageDelta`, opt-in, any out-of-step read is a whole page),
the app applies them off the main actor reusing untouched rows by identity,
whole pages are read straight from the frame, the footer's figures travel
only when they will be shown, and the journal is flushed once per settled
run. A 0.1.59 helper and a 0.1.60 app still understand each other.

The shell compares, it does not rebuild. Sidebar rows, headers and groups are
comparable over the values they draw, with a staleness guard that asserts the
picture changes for every change it should; the composer bar and the
sidebar's metrics line measure their labels once and build the one form that
fits (each with an oracle against the trial layouts they replaced); polls stop
for views nobody can see; the status panel counts on change.

Words a reader knows, affordances a reader can see. Run states are plain
words; a marked row is outlined, the open chat highlighted; every draggable
boundary has a grip; every pointer path has a keyboard path; a destructive
action is quieter than the action beside it until confirmed; a figure that
matters reads first; `docs/UX-Review-2026-09-19-0.1.60.md` is the ranked
review the changes came from.

Code is organised along its seams. No source file outside the transcript is
over 800 lines; the session in the helper is thirteen extension files; one
mechanism asks a question (`PiQuestion`), one table measures text
(`PiTextWidth`), one file holds the test seams; no crash a request or a user
can reach; every unchecked `Sendable` names its invariant. Absolute frame
budgets in tests are Release claims (`PI_RELEASE_TESTS`); the shape assertions
beside them hold in every configuration.

## 13. Performance ownership and bounds in 0.1.62

The second [performance review disposition](docs/Performance-Review-0.1.62-2026-09-20.md)
records measured improvements and deferred work separately. Tool-list height
identity excludes unrelated prose. A live code fence starts with a persistent
native text leaf; small already-complete fences keep their previous renderer.
Many-block answers retain lightweight source/geometry records while distant,
unselected native hosts can be reclaimed by the shared idle scheduler. That version still measured all cold inner-block geometry; 0.1.71 replaces that
path with visible-block preparation and separately tracked provisional heights.

Tables above 40 rows or eight columns show a labeled 20-row/eight-column inline
preview. The full native table window reuses visible cells, offers complete cell
text and full TSV copy. Original Markdown copy is unchanged.

Each HTTP stream admits at most 4 MiB of pending bytes, with 32 MiB shared per
helper and a 64 MiB response ceiling enforced at ingress. Suspend/resume happens
at 1 MiB/512 KiB. One ordered body batch of at most 32 KiB advances at a time;
bytes already received during its capture ACK are coalesced before the next
admission. Original network callback timestamps still determine SSE timing.
Overflow is an explicit partial capture, never a successful dropped stream.
Durable capture-before-dispatch and finalization fences are unchanged.

Reports use a dedicated read-only connection on a serial worker, with a short WAL
snapshot per query and reader-local progress cancellation. Paging reads rows and
counts without recalculating percentiles; charts retain their refresh observation,
and a paging notice identifies newer rows. Reader shutdown cancels and drains
queries before releasing archive ownership. Each connection caches at most 96
prepared statements and clears bindings on every exit. Data/directory sync and
manifest ordering remain unchanged.

Combined Response is generated off-main only when selected. Raw retained bytes
remain available and closing releases the document. Event parsing/formatting is
still eager; full lazy event indexing is a documented follow-up. Context-count
cache identities cover original UTF-8 and all request/profile inputs before
serialization; they are distinct from actual submitted-byte fingerprints.

## 2026-09-20 chat behavior and ordering (0.1.63)

`ComposerSubmissionIntent` carries follow-up or steering through native key
routing and buttons. IME, Shift and Option/Control are handled first; ordinary
Return/Tab completion is separate from command submission. WorkspaceRun captures
the originating session and reuses durable command intents. A steering
`not_running` rejection preserves the draft for an explicit new send; transport
uncertainty never becomes an automatic normal send.

`ChatMessage.view` and history projection supply optional `toolCallCount` before
truncating cards. `ToolCallSummary` scopes occurrences by assistant row identity,
excludes provisional `preparing` cards, retains legacy lower-bound wording and
explicit outcomes. Turn copy includes the same figures and per-request reporting
coverage. File-change counts require confirmed completed edit/write calls.

`ProviderClient` emits typed `RequestObservation` snapshots independently of raw
capture. Request identity includes session, turn, attempt, purpose, serialized
request fingerprint and dispatch profile capacity. Responses lifecycle/JSON
usage uses checked `UsageObservation` normalization. Fields remain nullable;
missing final fields retain their interim phase. AgentSession binds observations
to a generation, rejects stale/wrong-purpose updates and publishes at boundaries
or at 250 ms intervals through existing refresh events. Metrics-only snapshot
reads no longer await trace aggregation. Native `SessionMetrics` updates only
footer/inspector observers. The request ring uses reported input only; a new
request resets to its captured estimate, and previous observations are separately
inspectable. Compaction/branch/profile changes invalidate current observations.
No generation observation modifies preflight/compaction counts or route limits.

`StreamingMarkdownState` retains source, parse generation/revision, settled
source ranges and a provisional tail for one mounted message. Foundation source
positions anchor block identities. Safe fragment parses are cached, ambiguous
inline/list/quote tails stay literal, known fences use literal code, and confirmed
tables use Foundation's parser. A terminal pass uses the full authoritative
source, reconciling existing hosts so late reference definitions are resolved.
Retries invalidate streaming generations; idle source edits retain compatible
selection owners. NativeMarkdownSurface keeps a container throughout an active
message's lifetime, then retains it at completion. Short replies opened already
complete can still use a SwiftUI stack. The caret is an overlay, not mutable
selectable text. TranscriptPage retains at most one trailing 30 Hz presentation
job, flushing first content, tool transitions, completion/error and pane rebinding;
it batches presentation only, never provider parsing, persistence or tools.

`ChatRecord.manualSidebarOrder` is optional backward-compatible desktop metadata.
`MetadataStore.reorderChats` validates a complete same-project/topic/parent/pin
selection and atomically assigns ranks plus organization revisions. The sidebar's
shared comparator honors ranks; revision-aware organization merging prevents a
late title, model, draft or path write from undoing a drag. Pin/archive/topic moves
reset an old group's rank. Native row drag handling remains above the SwiftUI
insertion target, preserving selection, double-click rename and control cutouts.

### Activity and disclosure follow-up (0.1.65)

A turn's work, individual tool input/output, exposed reasoning and compaction
notes start collapsed. No recent-tool trail or reasoning teaser leaks out of a
closed work section. Explicit choices remain scoped to the conversation through
streaming, scrolling and tab switches. The sidebar calls a running tool phase
"Working"; the ongoing-turn bar omits the current tool's verb/arguments.

Archive hides unread reply/failure indicators from the sidebar, project groups,
Dock and menu activity without marking the retained output read. Restoring the
chat restores its original read state. Archived sessions never populate live
menu rows even while their stop request is settling.

The menu's live section shows running/generating counts, queued input counts,
turn elapsed time, requested model and last reported route, latest completed
request output rate, and reported session tokens/cost. It omits idle unread,
paused and waiting-only rows. Continuous workspace events coalesce in a fixed
250 ms window, rather than a trailing debounce that can starve during multiple
streams. Only elapsed labels tick once per second; clocks perform no database,
provider or transcript queries. Reported accounting signals update live rows,
and hiding the popup cancels its pending refresh and archive polling. Historical
charts and model distribution retain their independent bounded query cadence.

## 17. Fresh transcript presentations in 0.1.71

`ConversationPresentation` owns a UUID generation and cancellable navigation,
older/newer and optional-read tasks. It does not own the agent runtime. Ordinary
selection/revisit publishes loading before any await, restores composer metadata,
and asks one read-only adapter for the latest three display turns. Re-selecting
the same chat and returning from Reports are idempotent. Saved sides get their
own generations. Late results, focus, viewport and progress callbacks validate
ownership; closing or leaving a pane cancels its presentation tasks.

`HistoryWindowPolicy` is compiled by the native app and helper. Delivered user
inputs (including steering) delimit display turns. Version-2 `session.history`
returns an exclusive older/newer cursor, incarnation, branch lineage, start/end
coverage, messages and a partial-turn input reference. Latest/around/older/newer
share 3-turn, 60-row and 256 KiB encoded-envelope bounds. Legacy numeric calls
retain their adapter. Display windows never become replay context or export scope.

`HistoryReader` uses a private derived SQLite offset/visible-position index with
bounded page cache and eight retained indexes. Full supported files are indexed;
the former 100,000-record ceiling is a cancellation/progress segment only. The
128 MiB file and 32 MiB record safety bounds remain. Compact replay-validation
metadata is temporary and source-size-bounded; this is not a constant-memory
parser for arbitrary files. File incarnation plus committed-prefix SHA-256 lets
ordinary appends preserve cursors and rejects rewrites. Source handoff passes
stable entry IDs and lineage, never numeric file positions. Browsing remains
read-only; incomplete tails and missing identities are explicit failures.

The reader-centered resident window admits requested rows at the appropriate edge
and evicts the opposite edge within 500 rows/about 4 MB. Selection and a current
reading anchor are pinned. Admission failure leaves the page/cursor intact.
Nonoverlapping live snapshots expose a gap instead of replacing history. Latest
fetches a fresh source window. Visible Earlier/Retry/Newer controls share the
same single-flight loaders; initial short-viewport fill admits at most two pages.

The native document measures rich pages near the viewport even below 32 rows;
small plain pages retain a bounded fast path. Large Markdown containers keep
source identities and provisional descriptors, resolving four visible blocks per
step. Settled code fences beyond 32 KiB use UTF-8-safe sections of at most 8 KiB,
with full-copy source preserved. Visible exact layout and placement gate readiness;
a separate probe records a native draw opportunity, not physical scanout.
Optional context/accounting work starts after readiness and input quiet. Existing
motion policy and per-session disclosure ownership remain intact. See
[implementation/acceptance](docs/Fresh-Session-Loading-2026-09-21.md) for measured
costs and unperformed physical-device checks.
