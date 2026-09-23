# Bello Agent — Native Swift feature contract

Updated: 2026-09-21. Repository: `BelloWare/BelloAgent`, target branch: `main`.

**Status: native initial version implemented; UI redesigned on 2026-09-15.** Read [implementation status](docs/Implementation-Status.md) first, then [Design.md](Design.md) and [test handoff](docs/Swift-Test-Handoff.md). F13–F18 have implementations and deterministic Mac tests. Current request-aware loopback fixtures exercise Responses; earlier two-API checks remain historical evidence. These fixtures are not a deployed LiteLLM server. The owner selected Clipboard's ordinary macOS Keychain and profile-free Developer ID distribution; the native UI redesign landed on 2026-09-15 and plaintext settings remain deferred.

## 1. Fixed product decisions

The product is **Bello Agent**. Rename user-facing surfaces, the app bundle,
installer and product page together; retain the existing bundle identity,
Keychain item, history locations and updater signing key for compatibility.
The legacy Pi App update feed continues to receive the same signed release.

Retain the existing SwiftUI/AppKit application and native composers; since 0.1.38 the transcript is native SwiftUI as well (no WKWebView, React or Node anywhere in the build). Replace the shipped Node/Pi SDK host with the self-contained Swift helper in `packages/swift-host`. Do not switch to Rust, reintroduce bundled Pi, or implement a JavaScript compatibility runtime without a new architecture decision.

Pi `v0.85.1` is a behavioral reference, not a runtime dependency or a claim of full upstream parity. Arbitrary Pi extensions are excluded. Port selected useful extension behaviors as ordinary first-party tools, commands, or UI.

The current product target is **LiteLLM only**, with custom endpoint and API-key configuration. **Owner change, 2026-09-16: support Responses for all new requests.** Messages is retired from active connection/host capabilities; retained history, captures and saved credentials remain readable. A saved Messages connection requires an explicit Responses conversion; never silently change its API or endpoint. Do not silently substitute Chat Completions. External Pi auth/model files and credential commands are retired as configuration authorities.

Session model pickers load the bundled Bello catalog by default, including for
existing connections without a catalog URL. A custom catalog URL replaces the
bundled list; never use the gateway model list implicitly. Pickers load when shown, including
keyboard access, and keep all listed models selectable. New chats remember the
last deliberately selected model and reasoning effort for that connection across
projects and restarts, including catalog limits and explicit default choices.
Existing chats and shared connection defaults stay unchanged. Sides and forks
inherit their parent. See [model catalogs](docs/Model-Catalog.md).

ARM64/macOS 14+ is the application baseline. Bello Agent 0.1.10/build 14 is publicly
released from source `d1908dc` and website `b93433b`. The DMG measures
6,901,746 bytes (6.58 MiB). App/DMG signing and notarization, packaged-catalog/helper
smoke, public pages/icon, identical feeds and downloaded archive SHA-256/Ed25519
verification pass. All 60 focused native tests pass with zero failures; actual
bundled metadata, legacy/blank defaults, custom sources and rendered picker
content are covered. See [current release evidence](docs/validation/Bello-Agent-0.1.10-2026-09-16.md).
This corrects 0.1.9's missed default path, which still used gateway models unless
a catalog URL was saved. Unchanged 0.1.9 helper/transcript and broader acceptance
is reused explicitly. No full gallery, deployed-gateway or install/update
rehearsal was run. Installation/update rehearsals remain skipped by owner
instruction. SDK-era requirements remain in `docs/archive/PiSDK-Features.md`.

## 2. Required features and honest implementation status

**Stable tool streaming (0.1.72), turn info and compaction follow-up (0.1.73):** one persistent compact task work row owns
request/tool/reasoning details; each assistant source owns its own prose body.
Empty/tool-only replies create no temporary prose or action placeholder. A Turn
summary appears only after a recorded task outcome, including failure, stop,
interruption and output limit. Tool rounds, retry waits, steering and automatic
compaction keep the task active; queued follow-ups have distinct executions.
The live dock keeps phase, elapsed time, gateway-reported tokens/cost and Stop
in fixed-height slots, with duration before the generating-response label.
Elapsed task time uses monotonic uptime; calendar start/finish stamps are
separate optional observations. Interrupted tasks have no invented finish time.
Turn summaries show timing, input/output/cache/reasoning
tokens and cost directly, wrapping to fit narrow panes. Info opens a table with
reported coverage, cache state, reasoning cost and per-request inspection. Zero
and micro-costs remain visible; unreported usage stays pending/unreported.
Manual compaction uses the originating session's selected model, effort,
context capacity, output budget and model output ceiling, frozen at dispatch. Closed
details stay closed; argument fragments and late usage cannot move existing prose.
Old histories without terminal evidence show an unavailable outcome, and partial
history remains labelled. See [the lifecycle contract and acceptance record](docs/Stable-Tool-Streaming-2026-09-21.md).

**Inline skills and historical edits, 0.1.72:** slash suggestions follow the
native caret at the beginning, middle or later lines of a draft. Explicit
selection adds a chip and removes only that token, with coherent undo/redo.
The popup and Skills inspector share ranked metadata search, and each composer
owns its discovery/loading/error state. Reserved app commands remain deliberate
whole-message actions; pasted text and retained history confer no authorization.

Editing a retained user message on the selected timeline works after compaction
and in saved forks, including with read-only tools. Load the full original input
independently of the three-turn viewport. Preserve recorded skills and attachment
references; older unknown selections require review and missing attachments
require replacement/removal. Only an idle conversation with empty queues can
accept the edit. The child restores a safe pre-target context and durably records
the new branch and replacement together. Original journals, captures, spending
and external tool effects remain historical truth. Context inspection describes
the unedited branch until Send. See [semantics, format and acceptance](docs/Inline-Skills-and-Historical-Edits-2026-09-21.md).

**Context meter, 0.1.66:** current-request input, historical request usage and
next-input previews have distinct identities and labels. Opening the inspector
uses the same primary meter as the footer and cannot change preflight state.
Streaming/status events do not invalidate a matching preview. New submissions,
compaction and helper restarts cannot revive an unrelated old count; valid lower
reported input is accepted. See [implementation and CTX acceptance](docs/Context-Meter-Fix-2026-09-20.md).

**Activity and disclosure, 0.1.65:** work/tool details start collapsed, archived
chats have no unread indicators, and live menu rows show elapsed time, models,
queues and reported session usage. Continuous streaming no longer starves popup
updates. Transient model failures allow five retries after the initial request;
invalid requests and tool side effects are not automatically replayed. Compaction
still shares its independent eight-physical-request budget across all chunks.

**Compaction, 0.1.64:** one long user task can compact between complete model/tool
batches. Original task input and delivered steering remain verbatim. Complete
assistant/call/result groups are retained or summarized together. Recorded unknown
outcomes and warning phrases in tool output do not block compaction; their recorded
status and evidence remain available to the summary. Large sources use bounded evidence excerpts and
chunk/merge requests, with eight physical summary attempts per operation.
`history_read` retrieves retained evidence in UTF-8 pages without rerunning tools.
Summary output has no fixed 4,096-token cap: use the selected model ceiling,
clipped to the actual summary request's remaining capacity; use the configured
output budget when the catalog has no ceiling. Preserve the session's reasoning
effort. The summarization instruction follows the source content, with no target
character or token count. Empty, refused, truncated, tool-calling or non-reducing
summaries do not replace context. A typed context rejection permits one reduction
and one retry of that model operation, never a replay of completed tools.
Checkpoints synchronize before memory adoption and preserve ordered lineage on
reopen, side/keep and fork. Existing banners show chunk/merge progress, and summary
usage stays separate from normal-request context observations. See the
[implementation and CP01–CP33 record](docs/Compaction-Implementation-2026-09-20.md).

Session right-click and conversation “…” menus offer **Copy Session ID** and
**Copy Session Reference**. A reference contains the app session ID and actual
retained JSONL path, with a shell-quoted read command for local inspection from
another session. It also includes freshly read retained input/output/total tokens,
cache and reasoning breakdowns, reported USD cost and reporting coverage. Missing
figures remain unreported, and cache/reasoning subsets are never added twice.
Command-click adds sessions and Shift-click selects a range; **Copy Session
References** in the right-click menu and the selection-bar copy button copy the
whole selection in sidebar order, including each session's individual usage.
Copying preserves the selection and does not open, export or modify conversations.
An unsaved chat reports that it has no journal yet; imported originals distinguish
the app ID from the file's original identity. References describe the full retained
journal, including branch metadata, rather than claiming to be the current context
or to include unsaved drafts and in-flight streamed output.

“Present” means source and targeted tests exist. Read the validation records for actual Mac/UI coverage; fixture success does not establish signing, publication or compatibility with an unspecified gateway deployment.

| ID | Required behavior | Current state / acceptance boundary |
| --- | --- | --- |
| F01 | Native projects, sessions, composer and transcript | Native helper launch, Xcode 16.1 build/tests and actual CUA workspace/composer/transcript checks pass. Global conversation commands route to the focused window. Preserve IME, undo, selection, drafts and scroll anchors; real IME candidate composition remains unverified. |
| F02 | Context usage | One request-aware count drives the prepared context ring, inspector, preflight and compaction. Count actual instructions, tools, selected images and replayed items; fingerprint all request/configuration inputs. Only a matching explicit fixed route can reuse reported input for an unchanged prefix; estimate newly replayed items without adding all prior output. Separate requested output budget, supported ceiling and safety margin. Expose method and uncertainty; no verified gateway counting endpoint yet. Cumulative gateway-reported usage is separate. |
| F03 | Streaming | Responses text, exposed thinking, tool arguments, live tool output and lifecycle events present. Tool calls and results start collapsed, including running tools; manual toggles preserve their state across updates. Never execute incomplete/truncated tool calls or reconstruct model history from the display. |
| F04 | `/side` | Open directly with `/side` and Enter, without an initial message. Save an independent complete-boundary context snapshot as a child of the parent session; closing hides it without discarding its history or draft. `/fork` creates an independent session with the same completed context. Discussion-only permissions must not disable the composer. A snapshot is not a filesystem copy. |
| F05 | Codex skills, `/a-skill-here`, explicit-only selection | Codex/shared skill discovery, native command chips, policy/content hashes, dependencies and source inspection present. Pasted/model/history text is not user authorization. Conservative metadata parser, not arbitrary YAML/TOML compatibility. |
| F06 | Codex `AGENTS.md` | Global and project-root-to-cwd resolution, overrides, fallbacks, byte budget and source inspection present. No recursive global injection of every descendant file. |
| F07 | Tokens/sec and time to first token | Per-request client-observed TTFT (dispatch → first output item or non-empty delta, hidden reasoning included), first visible text, and decode speed present. Decode speed is the standard one (LLMPerf, vLLM TPOT): reported output tokens after the first, N − 1, over first → last output token (the latest non-empty delta or output item completion, never the terminal event, which a gateway can hold while it computes usage), for completed requests with N ≥ 2 over at least 250 ms; records written before the last-output stamp end at the model terminal. Every aggregate is Σ(N − 1) ÷ Σ span; missing usage stays unavailable. Chat TTFT/TPS show the latest completed request alongside weighted session-average TPS; both rates remain visible in narrow panes. Count reported output including its reasoning subset once; do not infer tokens from visible bytes. Keep metric layout stable and transitions local, using the app motion policy independently of macOS Reduce Motion. Hover reveals per-session history charts and click keeps them open. |
| F08 | Responses API | Native HTTP/SSE, function calls/results, usage and opaque reasoning item replay present. Custom endpoint and key supported. Explicit route/replay policy and gateway identity are covered by F17. |
| F09 | Historical Messages compatibility | Active Messages requests are disabled by owner decision. Preserve saved credentials, journals, captures and metrics; retain legacy parsing tests. Explicitly create/convert to a Responses connection for new work. |
| F10 | Exact request/response debugger | Submitted request and observed decoded response bytes, offsets, hashes, errors and compaction requests. Authentication header values are masked in request captures, with known credentials hashed in request bodies and masked in response echoes; any replacement is labeled as a byte-exactness exception. F13 stores new bodies unencrypted; retention remains finite. |
| F11 | Steering and queued messages | Separate steering and follow-up queues, removal, pause/resume and durable state present. Steering is consumed after the current complete model/tool turn. Follow-ups run when the agent would otherwise stop. Stop is in the chat input beside send/queue, scoped to that session; Stop/failure pauses remaining work. Failed responses show Error with visible provider details; queue pausing remains separate from failure status. |
| F12 | MCP through one meta-tool | List servers/tools without full schemas; describe a list of server/tool pairs; invoke one server/tool/arguments object at a time. stdio/HTTP and native inspector present. Calls serialize per workspace; uncertain dispatched effects block further invocation pending human review. |
| F13 | Efficient exact historical captures | **Implemented.** New plaintext content-defined chunks and SHA-256 manifests, legacy encrypted reads, paged reads/exports, quota/retention, request/message links and restart checks pass. Responses/tools traverse the packaged helper and native archive with byte equality, except explicitly hashed/masked credentials. Export/deletion races, metric-expiry tombstones, omitted credential bodies and SSE indices are tested. |
| F14 | One ordinary macOS Keychain item for app configuration and secrets | **Owner-selected Clipboard approach.** One versioned generic-password item contains connections, keys/headers, MCP, resources, runtime and capture/dashboard/update preferences. Revision/CAS, corruption/denial and no-fallback behavior remain. No restricted Data Protection access group or provisioning profile is required. Standard Keychain access controls do not promise isolation from raw writes/deletion by other same-user applications; verify and record the actual policy. |
| F15 | Local observability dashboard | **Implemented with native tests and fixture UI acceptance.** Durable request counts, exact nearest-rank p50/p99 and observed sample counts for TTFT, streaming span and full HTTP duration. Native Charts time series, all required filters and paged request-to-Inspector drill-down. Seven cases verify outliers, nulls, status scopes, filters, identity states, restart, migration and body/metric expiry in either order. |
| F16 | Custom LiteLLM endpoint and API key | LiteLLM-only native settings, Keychain credentials, Responses endpoint validation and retirement of Pi-file/environment credentials are **implemented**. Deterministic compatibility checks and native fixture UI pass; actual deployment verification is separate. |
| F17 | Auto-router actual-model visibility | **Implemented with deterministic and native UI evidence.** Requested alias and gateway-reported model remain distinct, with sourced evidence and unreported/conflict/incomplete states. Deployment IDs remain separate. Portable versus fixed-route native reasoning replay is explicit; original native items remain in history. The deployed gateway contract still requires authorized verification. |
| F18 | LiteLLM cost and cache visibility | **Implemented with core, native accounting and fixture UI checks.** Gateway-reported USD cost and response-cache state appear per message, session and dashboard, with evidence and sample coverage. Final streamed `usage.cost` is separate from provisional cost headers. Provider prompt-cache tokens are separate. Tool rounds and compaction count once in session/report totals; each attempt appears once inline, moving from user input to its assistant answer; user Details stays accessible. Reasoning tokens and reported reasoning cost are subsets of output, never added again to totals. Missing/invalid/conflicting data remains explicit. See the [accounting contract](docs/LiteLLM-Accounting-Contract.md). |
| F19 | Menu bar activity and usage | Left or right click opens the owner-selected Live Monitor (design B), adapting to light/dark appearance. Shared project scope and 5m/15m/1h/6h/24h ranges show current reported TPS, completed-request average TPS, output tokens, cost, paired input-cache share and requested/resolved model distribution. Drag across the chart to zoom the plot and retained totals; Reset zoom, double-click or Escape restores the preset. Live TPS uses fresh reported counter intervals only; partial coverage and unavailable values stay explicit, with gaps in aggregate history. Retained TPS remains output divided by dispatch-to-completion duration, never summed into current throughput. Omit unread, waiting and paused rows. Running sessions and error details remain accessible; detailed Usage and the full report retain longer history. |
| F20 | Onboarding gateway check | Before onboarding completes, send one small tools-disabled Responses request with the chosen model and scoped credentials. Empty/error/cancelled responses do not count as success. Preserve exact capture, no implicit retry, and no workspace instruction/skill/file content in the ping. |
| F21 | Unread replies | Mark new durable assistant outputs unread until their latest reply is actually visible in a foreground chat window. Report/background/scrollback cannot mark read. Persist read state across app restarts, preserve upgrade baselines, and expose unread badges in the sidebar. The status panel omits unread sessions by owner choice. |
| F22 | Completion sound | Play a short native chime when a user task completes, including background chats. Enable by default with a saved Settings toggle and Preview action. Tool rounds, compaction, title generation, connection tests, failure and cancellation do not announce task completion. Reopening history stays silent; simultaneous completions share a cue without a playback backlog. |

## 3. Interaction and safety

Opening or revisiting a chat creates a fresh transcript presentation, initially
showing the latest three delivered-input turns (up to 60 rows and a 256 KiB page
envelope). Clicking the already-selected chat or returning from Reports keeps its
current page. Explicit message links open the requested bounded range. Drafts,
helper work, tools, accounting and full exports remain independent of this window.
Loading, known-empty and failed states are distinct; restore composer metadata
first and keep Stop usable. Earlier/newer controls share stable exclusive cursors,
retry in place, and retain a reader-centered window of at most 500 rows/about 4 MB.
A long turn exposes its initiating input and continuation rather than silently
cutting off history. Large-source indexing is cancellable, reports progress, and
never labels a safety stop or index segment as the end of the conversation.
Long Markdown answers measure visible blocks first; huge settled code fences use
browsable source sections and full-code copy. See the
[fresh-presentation implementation and acceptance](docs/Fresh-Session-Loading-2026-09-21.md).

Usage Report is a dedicated page inside the main window. Its default view is a
small summary, time range, chart and request list; filters and detailed timings
expand on demand. Active narrowing remains visible when filters are collapsed.
In-app selection controls use Bello-styled choice panels for connections,
reasoning effort, catalog sources, settings and report filters. Preserve keyboard
navigation, explicit selection, disabled choices and Escape dismissal. App windows
disable the macOS tab strip so it cannot overlap the custom navigation.
Returning to Chats preserves the selected conversation, native composer and
transcript, drafts, selection, scroll and any running work. Hidden composers
cannot receive input or send drafts. Keep New Chat as an accessible icon action,
compact sidebar spacing and short transitions that stay animated independently of macOS Reduce Motion.

Show every project in the sidebar, with persistent expand/collapse controls. Use “Project” in user-facing labels while preserving existing internal workspace IDs, storage paths and host ownership. Allow session renaming, pinning, archiving and restoring without deleting history or stopping work. Refresh session cost without focus changes. Keep the latest completed reported TPS steady while another request runs; show pending or unavailable usage explicitly instead of estimating tokens from streamed bytes.

Projects contain optional named **topics**, one level of collapsible session
groups. Create, rename and remove topics; removal returns chats to the project
without deleting history. Create chats directly in a topic. Ordinary New Chat
inherits the focused chat's topic, while the project's own New Chat starts at
its top level. Drag sessions between topics or back onto their project header,
with a Move to Topic menu as an alternative. Moves stay within the project and
include saved side descendants, preserving session IDs, drafts, context, tools,
running work, pin/archive state and unread markers. Group membership and
disclosure survive restarts. Missing topic metadata must never hide history.
Filtering finds topic names and chat titles; choosing a chat reveals its topic.
Topics are organization metadata, not filesystem folders or permission scopes.

Drag above/below a session to persist manual order within its topic/project,
parent and pinned group. Show an insertion line. Marked sessions retain their
relative order; moving a parent keeps children nested. New sessions appear above
an ordered group. Topic-header drops still move complete branches. Rank updates
are atomic organization writes and survive late title/model/path updates and
restarts; pin/archive/topic moves reset only the moved session's old rank.

A turn exposes **Copy Turn Info** as a clipboard action and context-menu item.
Copy timing, validated call counts, usage, model reports and reporting coverage;
label live figures and partial loaded history. The compact work summary counts
logical calls, including repeated operations on the same path, across distinct
assistant replies. It must not count argument deltas or duplicate result rows.
A complete count survives bounded display cards; older incomplete history says
“at least”. Unknown outcomes never imply successful file changes.

While running, Return queues a follow-up and Command-Return steers; when idle,
both send normally. Shift-Return inserts a newline. IME marked text and native
Option/Control behavior take precedence. Plain Return/Tab accepts a completion
without executing an unselected explicit-only skill. Buttons share this intent
routing, and delayed acknowledgments keep their originating session/draft.

Expose each session's model and cost distribution from its header and cost
total in a resizable native window, reusing that session's window and keeping
its scope when another chat is selected. Show tokens (input, output, reasoning,
prompt-cache reads/writes), explicit response-cache hits/misses and known hit
rate with coverage, reported/reasoning cost and historical output tokens per
second. Missing observations stay unavailable, not zero. Reasoning/cache token
components must not be added twice. Show request shares and shares of reported USD cost, retaining requested
aliases such as auto-router alongside resolved model names. Scope totals to
that session and project, including its tool rounds and compactions once;
inherited parent messages do not import parent charges. Missing costs and
unresolved models stay explicit. A reported zero is not missing data, and a
zero total has no meaningful cost percentage. Poll only while the breakdown
is open and reject stale results after session or page changes.

Archived chats may be deleted with explicit confirmation while idle, after
closing any open parent/child side pane. Settings has one Save action and must
preserve untouched connections when saving preferences, including retained
Messages profiles. Edited invalid connection fields remain visible for correction.
Settings Test Connection saves first and targets a separate persisted, tools-disabled
chat in the app-owned No project group. It requires no project, cannot open sides
or enable editing tools, and must not send into another chat after selection changes.

Show context use as a circular indicator with a click-through inspector. The prepared-request preview must use authoritative context and the same provider request builder, expose included instructions, messages and tools, and clearly distinguish estimates/previews from actual captured requests. Outside an observed generation request, the ring must reuse the inspector's current matching estimate: idle previews include the unsent draft and selected skills, while running previews exclude unsent and queued turns. Invalidate that estimate when its inputs or conversation change. When a safe, idle tab is opened or selected, calculate its prepared context automatically after saved history and drafts load. Show calculation progress and reuse the matching estimate in the inspector. This may start the local helper, but sends no model request and executes no tools. Skip imported, untrusted, interrupted and active sessions; explicit inspection remains available. Never infer exact model context from rendered transcript text. During generation, valid current-request input usage takes precedence, with its dispatch-time configured capacity; output/cached/reasoning breakdowns are never added again. Retain the dispatch estimate while waiting for LiteLLM, distinguish interim and incomplete observations, and expose the previous request in the inspector. This is generation usage, not proof of the next request's replay size. Preflight/compaction continue using the shared request-aware estimate. Usage-only updates must not rebuild transcript rows or depend on capture retention. Individual skill disabling is stored only in Bello Agent configuration and must not change Codex or shared skill files. Keep original skill policy restrictions effective.

The main window uses a custom draggable area above the sidebar with reserved
space for native close, minimize and full-screen controls. Hide the native title
and backdrop. Chat/report headers start beside those controls at the top of the
window, without an empty full-width padding row or covering other controls.
Double-clicking its background fills the available screen and toggles back to
the prior window frame without stealing clicks from controls or sheets. Code
blocks and Markdown sections can be copied as their original source. Omit the
LiteLLM/API/model-ID/editing badges from the conversation title.

Normal Send while busy means Queue follow-up; Steer is separate and explicit. Both queues default to one-at-a-time delivery. Cancellation is not proof that a tool had no effects. Pending work pauses after failure, cancellation or restart; it is not silently resent. Main and side have independent conversation/cancellation state. Editing sessions share a workspace execution gate.

Messages accepted during manual compaction or final run cleanup must continue
automatically after successful settlement. An idle retained queue always offers
an explicit Send queued/Resume action; failed or stopped queues stay paused.

Selecting text in an assistant response opens an anchored **Ask in side chat**
popover. Quote the rendered selection into an unsent side draft and focus its
native composer; do not submit until the user sends a question. Preserve the
parent draft and model/effort settings, append to an unfinished side draft, and
retain a previous saved side when opening a new child. The action supports native
prose and code selection and does not offer nested, imported, archived or
connection-test side chats. Ordinary selection and copying remain available.

Support at least 20 concurrent session model streams, both within one project
and across projects. Bursts of startup, snapshot and capture work must not lose
captures, reject ordinary commands prematurely or make one session's Stop/error
interrupt another. Shared project startup and each session's capture preference
must settle before that session can send. Keep memory and command queues bounded,
and expose actual persistence failures. This is asynchronous concurrency, not a
promise of one OS thread per session: UI and archive mutation retain their actor
ownership and editing tools serialize per project. Read/list/search jobs execute
on a bounded pool of worker threads, outside the project tool actor. Gateway limits still apply. See the
[20-session concurrency review](docs/Concurrency-Review-2026-09-19.md) and
[worker-thread review](docs/TPS-Workers-Review-2026-09-19.md).

Native journals have a Pi-compatible display envelope but a distinct provider-state contract. One writer owns each journal. Do not let Pi CLI append to a native journal. Old Pi sessions remain read-only; an explicit portable draft is available, not lossless SDK replay. The owner does not require additional legacy migration work before release.

Explicit-only skills stay in the user picker and out of automatic discovery. Preserve original relative script paths. A skill grants no extra tools and cannot escalate permissions. Third-party skill scripts may still need an installed language runtime; the small application does not bundle every possible toolchain.

MCP server configuration is edited in the native inspector and saved in the single configuration vault. Listing can start a configured server process but cannot invoke its tools. Describe accepts multiple pairs; invoke accepts one pair/argument object, never a batch. Multiple calls in a model turn execute serially. Read-only sessions can list/describe but cannot invoke. Unknown-outcome acknowledgement is user-only and never retries the old operation.

The app is not a sandbox. Shell and approved MCP subprocesses run with the user's process permissions. Process separation, hashes, tool allowlists and read-only tool modes do not establish OS isolation.

## 4. Captures, privacy and metrics

**Current owner change (2026-09-16):** capture request/response bodies and headers by default, retain bodies for 30 days subject to quota, and display retained bodies directly without a reveal step. New retained HTTP bodies use plaintext chunks and verifiable digests; existing encrypted history remains readable with its existing vault key. Mask authentication header values, retaining at most the last four characters of longer request tokens; fully mask short tokens, cookies, response authentication and credential echoes. Known credentials in request bodies use labeled SHA-256 fingerprints. Known credentials found inside a request body are replaced only in its capture; redaction count, original/captured lengths and non-exact status are explicit. A safety-limit omission is unavailable, never an empty complete body. The wire request still uses the original value. Known credential echoes in new response captures use same-length masks across streaming chunks, with explicit transformation metadata; provider parsing and SSE offsets are unchanged. Credentials/configuration remain in the Keychain vault. Full-text search inside captured bodies is deferred.

Exactness refers to the serialized request body actually submitted and the decoded response body bytes actually received by the application. It is not TLS packet/header-order capture, hidden reasoning disclosure, or LiteLLM-to-upstream visibility. Authentication headers must remain redacted. Body contents can contain sensitive user data; durable capture needs an explicit privacy/retention policy, protected storage and deliberate export.

Captured JSON requests and responses open formatted by default, with expandable
objects and arrays. Responses SSE defaults to a Combined JSON view using the
terminal response object, including gateway extensions and usage. Without a
terminal object, reconstruct supported item/text/reasoning-summary/tool-argument
events into an explicitly partial object. Preserve provider incomplete/failed
status, unknown fields and opaque reasoning. Also offer an expandable Events
view of retained frames in captured order, with formatted JSON data and original event fields;
non-JSON data, sentinels and unfinished frames remain visible. Load the complete
retained response without manual body pagination.
Raw text/hex and original-byte exports remain available; JSON presentation does
not rewrite stored bytes or turn a partial capture into a complete one. Apply
the same behavior in the inspector and message-linked request details.

A message may relate to several LLM requests and compaction calls. Message/turn-to-attempt links are durable. Missing, partial, truncated, credential-omitted, expired and purged captures remain labeled. A request appears inline on its user turn until an assistant answer exists, then on one assistant row. Tool rows do not duplicate it. User Details retains all linked request information. Session/report totals sum each request once. Hide visible user/assistant speaker-name labels while retaining accessible roles.

The assistant output status line shows one model name from the response body,
preferring LiteLLM's `router_model_name` over `model`. Clicking it opens the
separate body and header reports with their sources and routing status. Omit
inline model-conflict warnings; conflicting evidence remains inspectable and
continues to govern routing verification. A literal body alias is a reported
name, not proof of the upstream model. Older captures may retain a verified
gateway name; never substitute the configured alias when no name was reported.
The composer model list must reflect its selected saved catalog, refresh on opening when stale, and retain all selectable entries. Catalog selection is independent of the request connection: a chat may explicitly follow another saved catalog without changing its request route, key, selected model or effort. Default-model connection copies made by the app share catalog updates only when gateway, API and credentials match. Older records have no reliable lineage; surface later saved custom catalogs for the same gateway directly in the chat picker, with a one-click binding action or a chooser for multiple alternatives, instead of silently guessing or hiding the difference behind Refresh. Respect explicit bindings. Refresh reloads saved configuration, forces a revalidated fetch, and displays its update time.

A connection can select a separate mini model for automatic title generation;
catalogs can recommend a mini model. Ordinary chat choices stay independent.
Each title-generation job is a retained, tools-disabled session with a fixed
title, hidden from the default chat list and available through an explicit
background-session view. Its requests and cost belong to that session. Keep
manual titles, bound the prompt/output, and do not retry uncertain work after
restart. If no mini model is configured or recommended, keep the local text
title rather than silently using the main chat model for an auxiliary call.

Define dashboard timing boundaries precisely and record them independently. Never turn missing first-token timing into zero, average bucket percentiles, or combine cancelled samples into a successful-request percentile without a visible filter. Display sample counts and distinguish local HTTP attempts from hidden gateway retries.

## 5. Acceptance and exclusions

Acceptance coverage includes native-core/executable and macOS/UI checks, F13–F21, active Responses requests/tools/streaming/cancellation/compaction against request-aware mocks, historical Messages readability and new-request rejection, Keychain behavior under release signing, and complete signed-DMG size. Deployed LiteLLM verification remains separate when configured. The owner has authorized release to belloware.com after validation.

**Owner workflow change after 0.1.6, 2026-09-16:** select checks for changed behavior, reuse passing evidence for unchanged code/dependencies/toolchain, run independent checks in parallel and reuse incremental build caches. Do not repeat the entire acceptance matrix for routine changes. Skip fresh-install and actual Sparkle update/relaunch rehearsals, including signed owner/update rehearsals, unless explicitly requested again. Keep code signing, notarization, artifact/feed validation and public download hash/signature verification. Historical installation/update evidence remains recorded, without implying it was repeated for later releases. See the [test selection policy](docs/Swift-Test-Handoff.md#current-test-selection-policy).

No arbitrary Pi extensions, OAuth/credential shell commands, new plugin marketplace, MCP sampling/elicitation, WebSockets, or automatic model/tool retry is promised. These exclusions do not excuse missing owner-requested features. See [implementation status](docs/Implementation-Status.md) for the continuation order and [parity](docs/Swift-Feature-Parity.md) for the narrower implementation boundary.

### Performance follow-up in 0.1.62

Large tables use an explicit bounded preview with a full native table window,
complete cell text and full-source copy. Live code preserves its native selection
owner, tool-list geometry survives prose-only changes, and distant unselected
Markdown hosts can be released without losing source or exact geometry. Reports
page requests without repeating summary calculations and run on a separate
cancellable reader. Capture retains exact ordered bytes with explicit ingress
budgets and coalesces received fragments before acknowledgement; durability is
unchanged. Combined response generation waits until that view is selected.
See the [review dispositions and measured limits](docs/Performance-Review-0.1.62-2026-09-20.md);
this does not claim that all rich-row or cold giant-answer frame costs are solved.

### Stable streaming Markdown (0.1.63)

Show unfinished inline syntax literally until the block is settled. Establish a
code leaf only after its fence info line is complete; retain it through growth,
fence closure and completion. Confirm tables before rendering a grid. Reconcile
final source through the canonical full-document parser, including later link
definitions. Keep raw output, copied text, journals and HTTP bytes unchanged.
Streaming messages keep one native container across the eight-block boundary;
settled hosts retain identity/selection and caret blinking only repaints a
separate decoration. Presentation is leading-plus-trailing, around 30 Hz per
visible pane, with first content and terminal transitions immediate. Maintain
16 KiB/8 KiB live previews and explicit access to retained full content.
