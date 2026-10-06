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
| Queued follow-up promotion | Core/SessionQueue.swift steerQueued; App/Workspaces/QueuePanel.swift | Implemented pending follow-up → steering action, same identity/payload/choices and durable lane order. Active worker, edit-hold and persistence guards apply. Rust delivery remains at the current response boundary; production tool-batch parity is still missing. Validation recorded below |
| Queue presentation | App/Workspaces/QueuePanel.swift | Partial. Bounded/collapsible panel, truthful timing, stable lane grouping, full-text editing, and per-chat full-message/model-choice popover. Durable follow-up drag reorder and measured adaptive room budgeting are implemented below; source 52pt floor and wrapped-footer adaptation are explicit. Native macOS interaction validation remains pending |
| Images/attachments/image-only submissions | Core/PiImage.swift; App/Composer/Attachments.swift; Core/SessionQueue.swift validate | Unported. Attachment control unavailable; transport currently accepts text only |
| Built-in tool definitions/execution | Core/Tools.swift; Core/SessionTools.swift; Core/SessionRun.swift | Production unported. Fixture-only ls module + bounded/cancellable executor now implemented; no tool definitions sent or executed by Controller, no fabricated result |
| MCP lifecycle/invocation | Core/MCP.swift; Core/HostService.swift mcp.* | Unported |
| Skills and resource resolution | Core/Resources.swift; Core/HostService.swift resources.* | Unported |
| Project instructions and instruction precedence | Core/Resources.swift; Core/SessionRun.swift; Core/HostService.swift | Missing in production. Provider supports an instructions argument, but runtime.rs passes an empty string; no project instruction discovery or skills UI is implied |
| Compaction / context preview | Core/SessionCompaction.swift; Core/CompactionPlanner.swift; Core/ContextPreview.swift | Unported; no claim that local context budgeting is complete |
| Historical message edits/versions | Core/SessionVersions.swift; Core/EditReplayPlan.swift; Core/MessageVersions.swift | Unported |
| Branch/fork/side conversations | Core/SessionBranching.swift; Core/SessionSide.swift; Core/SessionPersistence.swift | Unported |
| Multiple projects/topics/chat organization | App/Workspaces/WorkspaceModel.swift; WorkspaceTopics.swift; WorkspaceTabs.swift | Partial: independent chats in one explicitly selected project, existing New Chat/sidebar controls, draft/selection persistence and deferred creation. Projects manager, multiple roots, topics and organization remain unported |
| Sidebar chat Pin/Unpin | App/Workspaces/SidebarChatRow.swift; SidebarGroups.swift SessionOrganizationActions; Storage/MetadataStore.swift sidebarPrecedes | Implemented source context-menu entry and committed pin marker/order. Pending chat record/draft/pin materialize atomically; selection, streaming title and newer typing are preserved. Native NSMenu bridge reuses existing GPUI Cocoa/objc versions. Independent review/headless validation recorded below; actual Linux/macOS runtime scope remains explicit. Rename, archive, multi-select and manual drag ordering remain missing |
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

## Viewport-limited transcript rows (2026-10-06)

Status: **implemented app-only rendering optimization; scoped local and Linux desktop gates passed; CI pending**.
The pinned GPUI variable-height List now constructs and measures visible rows and
an overdraw margin of `max(240pt, viewportHeight / 2)`, matching the measurement
margin in Swift `NativeTranscriptScrollView.swift:246–247`. This does not reproduce
Swift's retained selected/nearby hosts, native text selection or motion scheduling.
Existing top alignment, full logical history, Show earlier, message content, Copy,
24pt gutters, 13pt bottom inset, 16pt row gaps and 840pt row cap remain explicit.
No core/session schema, model context, provider or dependency changes are included.

Stable row kinds include loading, retry, earlier-history and message rows. The old
displayed projection is retained until synchronous prepaint reconciliation samples
the latest user position. Targeted splices restore unique message identity and
within-row pixel offset; deleted anchors fall to a surviving successor, then a
predecessor. Removing the earlier-history header while it is still the anchor
reveals the new top. A newer wheel gesture already anchored in a message wins.
A vanished pixel after a row shrinks is clamped to the newly measured row's end,
using one additional targeted measurement included in construction instrumentation.
This is a narrow GPUI safety policy, not a claim of exact Swift textual anchoring;
reflow preserves a valid pixel position, not necessarily the same textual line.

Wheel navigation uses measured row heights and nonzero, source-style estimates for
unseen rows. This avoids GPUI 0.2.2 List's zero-height unknown-row extent clamp;
a deterministic native 5000px event previously moved only 394px. Exact heights are
captured for both leading and trailing overdraw without a second layout. An
estimated target that exceeds its actual height retains residual pixels, with at
most two target preflights per frame. Further normalization keeps the last canonical
viewport interactive and requests another animation frame. New gestures and
width/presentation/style changes supersede pending work; height-only changes can
retain it because the row geometry remains valid.

Native Linux testing also exposed a separate input-unit mismatch: the original Div
used the inherited 26px line height, while List used 20px. The matched CUA gesture
emitted 50 events of three lines each, so those implementations moved 3900px versus
3000px despite the same 5000px CUA request. The adapter preserves the original Div's
inherited line-height conversion, per-event addition (including mixed units and
reversals), and horizontal-only input mapping on its vertical scroll axis. It leaves
row/ancestor event propagation intact.

On 2026-10-06, independently reviewed source 3ed7927a (SHA256 prefix, not a Git commit)
passed 36 focused transcript regressions, strict app all-target Clippy, rustfmt and
diff hygiene. Both app and core were freshly compiled before saving Linux binary
`75576b7ed2dce3dab9ecf2cdfbec83916a11ff4d36902842d9a8bfa417bd591b`.
The matched fresh 220-message fixture starts at 120–125 and, after the same gesture,
settles at partial 154/full 155–159/partial 160, matching the baseline's visible rows.
There is an approximately 3px placement difference; this is not pixel-identical
or native frame-time evidence. The fake-platform tests explicitly drive deferred
frames because that platform does not deliver native animation callbacks.
Native adversarial-estimate animation scheduling has not been separately exercised;
the per-frame work bound is established by focused tests and API review, while
ordinary native wheel navigation is the matched desktop result.
The same binary passed reverse scrolling, an immediate down/up gesture without later
position restoration, expansion through Show earlier to all 220 messages, and readable
reflow at 920px width. A native Copy smoke check pasted the expected visible Unicode,
Markdown and two lines into a disposable composer; exact clipboard bytes were not
separately inspected in that desktop pass. No wider platform QA is implied.

Ambiguous legacy message IDs are displayed without rewriting stored data. Each has
an ephemeral presentation identity and the existing empty 22pt action band; Copy
is omitted for those rows. Live Copy also requires exactly one current ID match,
so a formerly unique row becoming ambiguous cannot copy another row silently.
Controller/chat callbacks remain weak and identity-checked. Rendering and list
closures never read the parent; pre-draw input synchronization remains required.

This bounds constructed row trees, not complete Session memory or every frame's
CPU work. Projection reconciliation and resize can traverse logical metadata, and
one huge visible row still shapes its full text. Source resident 500-row/4MB paging,
latest-follow placement, bidirectional edge UI and durable reading state remain
separate gaps. Native macOS wheel/selection/IME/frame performance is unvalidated.

The common benchmark adapter uses schema 3 and identical payloads/profile/full-draw
timers on baseline and candidate, with logical-input and actual top-row/wheel
geometry checks. Eager/deferred returned-element construction is labeled separately;
no payload-clone estimate substitutes for measured full draws. Supplementary local
cold-window, wheel, visible-tail snapshot-update and resize evidence has separate
timer boundaries. All measurements remain synthetic CPU-work wall time with GPUI's
fake text system; they do not establish native font or compositor frame latency.
The first paired measurement attempt was invalidated: a shared Cargo target reused
one executable across distinct copied source trees. Raw attempts are retained as
invalid evidence, with no accepted speedup claim. The runner now cleans only the
app/core packages' generated artifacts before compilation, requires Cargo's `fresh=false`
and exact requested source path, records that proof, and rejects changed app-source
manifests paired with the same executable hash. Dependency caches, source and saved
QA binaries remain untouched. Source hashes alone are not compilation evidence.
The correction-specific local/static and matched desktop gates are recorded above.
No fresh timing claim is made for the final corrected source; exact-commit CI remains
a separate publication gate.

## Portable manual transcript measurement (2026-10-06)

An ignored, test-only GPUI benchmark and standard-library Python runner/parser make
future measurements reproducible from repository source. Production behavior and
normal CI timing policy are unchanged. Two small Rust checks and Python parser tests
validate configuration, statistics, complete workload records, profiles, counts,
budget exhaustion, mismatched comparisons and output preservation. The manual test
remains skipped unless explicitly invoked through the runner.

Generic mode measures full draws without child probes; it does not disable caching.
Cached mode labels parent composition and direct-child work separately. Source and
binary hashes, actual Cargo profile/fingerprint, and sanitized compiler identity are
checked; no raw environment, credential-derived Cargo config hashes or process logs
are retained. Fixture data is synthetic and isolated from ancestor Git discovery.
Comparison requires identical harness/method hashes and matching modes/profiles/matrix.

See [the method and commands](transcript-benchmark.md). The old direct-rustc baseline
is not automatically compatible with this Cargo harness. The final portable CLI completed all 12 cached workloads and a four-workload generic
pilot on the frozen source. A same-report comparison accepted all eight generic draw
rows, while a cached/generic comparison failed visibly without a valid comparison.
These are tool-validation runs, separate from the earlier performance comparison.
**364 default Rust tests /371 with the optional feature**, both strict Clippy modes,
formatting and workspace build pass; each routine suite explicitly skips the one
manual timing test. **32 Python tests** pass. The Linux workflow adds only their
cheap self-test command, with no timing invocation or policy/permission changes.
Existing original raw benchmark evidence
remains local-only, while this checkpoint backs up the reusable tool rather than large
binaries or environment diagnostics. No native frame/IME/desktop parity claim follows.

## Populated transcript invalidation (2026-10-06)

Status: **implemented app-only optimization; headless and running Linux validated;
matched synthetic measurement completed**. The original Swift
`TranscriptKeptRows.swift` retains settled row trees, and `TranscriptStreamingTail.swift`
limits its append fast path to an exact compatible projection. This bounded Rust
slice isolates the existing populated transcript in a retained per-chat GPUI entity;
it does not implement the source's full paging, native text or streaming-tail model.
Rows, Copy band, Show earlier count/order, loading/failure prefixes, and empty starter
keep their existing presentation. No core/provider/schema/dependency changes.

The child's immutable inputs are session Arc, chat/controller identity, reveal count,
palette, pane width and loading/failure flags. Equal inputs do not notify it. Parent
notifications synchronize changed inputs before drawing through `observe_self`:
updating them only from Render was shown to leave a same-bounds cached frame stale
and was corrected before validation. The cached outer style explicitly preserves
flex growth, zero minimum height and full width; the inner scroll view fills that
viewport. Bounds, inherited text-style and content-mask changes invalidate GPUI's
cache; explicit Window refresh bypasses it. Queue/composer height changes therefore
relayout the viewport. Streaming snapshots still rebuild the transcript.

The child never reads the parent during render/layout/prepaint. Weak parent and
controller references are upgraded only for actions and revalidate current chat,
session and controller identity. Copy reads the current controller snapshot, not a
cached text payload. A retained scroll handle preserves the chat's offset through
unrelated notifications/navigation. Controller replacement or empty history drops
the old projection, and weak callbacks do not retain its session-file lock.

Ten new GPUI tests cover unchanged-input cache hits; fresh Arc and same-ID text,
reasoning/state/reorder changes; every explicit input; Show earlier clicks; changed
queue/composer/pane geometry; navigation/scroll identity; controller replacement;
empty/loading/failure transitions; stale/dropped ownership; and synthetic marked
composition/selection. Actual simulated hover/Copy after cache hits, wheel scrolling
and explicit refresh are exercised. **362 default workspace tests  / 369 with the
optional native lifecycle feature**, both strict Clippy modes, formatting and build
pass. Independent review verified all five code hashes and reran all **183 app tests**.
TestPlatform cannot simulate native appearance-change callbacks: explicit palette
input tests pass, and inherited text-style changes invalidate when the root redraws,
but automatic native appearance redraw is not claimed.

Baseline evidence at committed `0beb423` uses a copied app, fixed synthetic histories
of 100/1,000/10,000 messages, and both default 100/all-revealed modes. It measures
actual conversation construction/destruction and complete root-notify/forced-refresh
draw paths with an unoptimized test-support build. GPUI uses NoopTextSystem and empty
assets: these are synchronous CPU-work wall times, excluding native shaping,
rasterization, compositor and display presentation. Sparse 10,000-row samples do not
establish tail latency. Source-accounted text-clone bytes are not heap telemetry.
The post-extraction conversation-only path measures parent composition; direct child
construction and full draw remain separate measurements. The final matched sweep
used the same dependency artifacts, compiler/profile, payloads and sample policies.
All 12 cases preserved exact revealed rows, session/workspace data, composer text and
persisted bytes. Across 252 measured ordinary root notifications the child rendered
zero times; forced refresh rendered it once per sample. With all rows revealed,
ordinary-notify median CPU-work wall times (short/multiline) were 5.32/6.12ms at 100,
11.87/12.60ms at 1,000, and 98.02/102.86ms at 10,000, versus baseline 52.26/89.68ms,
506.61/838.49ms and 5,313.64/8,551.46ms respectively. Final ordinary routes have 21
samples each; the two baseline 10,000 routes have only 6/2 samples. These medians
characterize this workload and profile, not a native frame budget or general speedup.
At 10,000 rows, forced refresh still took 3.806/7.525 seconds median and direct child
construction 218.52/232.02ms. Thus expensive cache misses remain, and even warm replay
still scales with row count. The initial warm pilot preceded the pre-draw ordering
fix; the quoted final sweep includes that correction and the frozen regression code.
Raw samples, copied-source harnesses and hash manifests are retained in the local
workspace audit evidence, outside this checkpoint; they are not backed up by this
commit. A separately reviewed portable harness is planned rather than committing
raw environment diagnostics or large artifacts.
Original Swift resident limits (500 rows/4MB) are not silently imposed here;
Rust Show earlier remains unbounded, and large cold/miss redraws plus background
whole-session snapshot cloning remain performance gaps. No native frame, scrolling
smoothness, IME or whole-product performance claim follows from these checks.

Fresh running Linux candidate
`094d9c0186cfa2a068db6f9c4d6c2bbd67c5dbab97b3ccf49dacf4f877c0902a`
passed warm typing/Undo, settled scroll retention through edits and chat switching,
per-chat drafts, and Show earlier from 100 to 200 to all 220 messages in order.
User and assistant Copy after cache hits each preserved the exact 65-byte synthetic
Markdown/Unicode/whitespace payload. Normal 1180×812, minimum 920×600 half split,
tall composer and last-row/Copy reachability passed; the prior 731c candidate matched
same-fixture minimum geometry. A separate dark launch painted readable expected
colors. The local gated stream painted arriving text while Working; typing remained
editable, Copy matched the active 70-byte response, completion changed status to
Ready, and all four history/new messages remained. Exactly one request completed
without cancellation. All apps and the loopback gateway closed cleanly.
One streaming-fixture launch initially painted black/transparent until pointer entry;
other launches painted normally. This intermittent observation resembles earlier
recorded startup behavior, but its cause and relation to this slice are unproven.
It is retained separately rather than omitted or counted as native parity evidence.
Current screenshots are
`agent-cache-094d-{scroll-restored,history220,copy,minimum,split,tall-last,dark,streaming,complete}.png`;
minimum/split/tall-last images are 920×600 and the others 1180×812. The separately
labeled `baseline731-split.png` is prior-binary comparison evidence only.
These interaction checks establish neither hardware frame timing nor native macOS
IME, dynamic appearance, accessibility or scrolling performance.

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

The first probe at `6966a43d7ef330e9d37d8802a809e000757e736f` compiled and
launched on macOS, but [run 37275935183](https://github.com/BelloWare/BelloAgent/actions/runs/37275935183)
failed `native_unexpected_window_count`: `NSApplication.windows` had more than
one entry before target-title/visibility checks. This does not identify any
concrete auxiliary window class or establish lifecycle success. Exact Linux CI
passed [run 37275935176](https://github.com/BelloWare/BelloAgent/actions/runs/37275935176).

The correction retains the exact single GPUI window identity and matches it to
the main native GPUIWindow with the expected title; unexpected visible/main/key
windows, GPUI panels, duplicate targets or identity mismatches still fail. It
emits only bounded numeric category counts, never raw titles or pointers. Local
checks passed: 141 default Rust tests, 148 feature-enabled tests, strict Clippy/build
for both configurations, and five Python harness tests.

The corrected probe at `6d4ce698c92342f99cfc1d93a08475f2e6af42b8` then
[passed the actual native run](https://github.com/BelloWare/BelloAgent/actions/runs/37277806197):
two native entries, one expected GPUI window, no GPUI panels, one visible and one
hidden entry, and the expected main/key/active identity. All five ordered lifecycle
markers and clean process exit passed. The hidden entry's concrete class/title
was not collected or inferred. [Its Linux run also passed](https://github.com/BelloWare/BelloAgent/actions/runs/37277806206).
The std-locking successor `8ccf5a52c33d55b8ab16af4e8f4f0f24b7040a2f` passed
[both native compilation and the own-window probe](https://github.com/BelloWare/BelloAgent/actions/runs/37278353020)
and [Linux checks](https://github.com/BelloWare/BelloAgent/actions/runs/37278353013).
The first failed run remains historical evidence, not a skipped success.

This establishes only empty-workspace native lifecycle traversal. It does not
prove pixels, desktop input, IME, accessibility,
nonempty draft persistence, Dock reopen, cancellable Quit, or Sparkle behavior.
Probe code and its feature-gated hooks count as test-support LOC, not shipped
production code. No macOS lifecycle parity is claimed by adding this diagnostic.

## Certain queued-edit reconciliation (first recovery checkpoint)

Implemented the first wired boundary in [the reviewed recovery design](held-edit-recovery.md).
`SessionQueueEdit.swift:44–52` requires a certain journal before answering edit
status. Rust now exposes typed, actor-locked Active/Saved/Cancelled/Removed/Unknown
status, including edit identity, current hold and session revision. Fatal or
uncertain storage cannot authorize recovery through an older published snapshot.
Opening an existing validated checkpoint confirms its file and parent directory
before any authoritative answer, without an extra rewrite. Edit/outcome validation
rejects malformed identities, conflicting holds and invalid saved digests while
preserving the original bytes. Unknown Cancel records only its own tombstone and
preserves an unrelated current hold, matching the source helper's lines 132–146 behavior.

The app uses this status at startup/load, on relevant live updates, and after
queued command failures, including generic removal of a held row. Known later
failures invalidate earlier pending or IME-deferred successful answers, even when
an uncertain write did not advance the published revision. Chat/project/controller,
operation and window-generation checks reject or requery stale completion. A
confirmed, unchanged Active hold remains editable. Definitive failed Save/Remove
can retry normally; an unconfirmed state leaves drafts intact and actions blocked.

Reconciliation validates the whole candidate and checked next revision before
changing live text or ownership. It uses the latest live rewrite/displaced draft,
not a captured background copy. Actual replacement waits for marked composition;
an entity observation catches unmark notifications, which do not emit a Changed
event. The existing source distinction remains: an explicit owned Cancel discards
its rewrite, whereas recovery preserves genuinely unsaved rewriting according to
the saved digest/original-text comparison. At that checkpoint, the v3 Cancel receipt,
nonfreezing Begin adoption and source owned/unowned row controls were still pending.
The later durable Cancel checkpoint below updates that boundary.

Ten added core tests bring the core suite to 143. They cover reopen confirmation
and failure, pre/post-rename errors, poisoned status versus old cached holds,
malformed open/encode data, tombstones beside other holds, and typed reconciliation
conflict/overflow rollback. Nine isolated safeguard mutations were detected.
Twelve fake-platform app checks cover authority rather than cached presentation,
latest rewrite merging, marked-text deferral, stale navigation/controller/window
completion, oversized/overflow preservation, live updates, and later Stop failure
invalidating deferred success. Every generic command/submission/recovery busy
completion drains a requested recheck, including successful Save after a newer
Stop failure and rejected submission settlement for an unowned hold. Disposable
pre-rename collisions demonstrate that
normal Save and held-row Remove preserve both disk and rewrite and retry safely.

The complete workspace passes 248 default and 255 optional native-probe tests,
strict all-feature Clippy, build, formatting and diff checks. Twenty repetitions
of the twelve app recovery tests pass. Independent review ran 52 queue checks
(including all twelve recovery tests), six shutdown checks, one rebind check,
all 64 core unit tests and all ten workspace integration tests on verified binaries.

Linux candidate `4f97c4c6e092d79cfa76f09b20a9bfd0e039af993bdfc7df71da8c58a40dd528`
passed a real pre-rename Save failure/retry: an empty disposable snapshot-path
directory caused a visible error, the rewrite stayed editable through typing/Undo,
and restoring only the fixture snapshot allowed Return to save the exact rewrite
and restore the ordinary Unicode draft. Startup of a settled Cancel preserved the
unsaved rewrite ahead of the ordinary draft; a matching saved digest restored only
the ordinary draft. These observations do not inject actual post-rename poisoning.

Final binary `c7abd93facf835f2836515c8626ae28603c959728438222aec77c485bc3156d1`
adds the reviewed completion-drain correction. Fresh Linux checks showed an unowned
hold retaining the exact ordinary draft without automatic adoption, and owned
Edit/type/Cancel at 920×600 restoring the ordinary draft and queued message.
Close/reopen preserved exact text, and initial Ctrl+P focus routing worked.
Earlier failure/reconciliation captures retain their 4f97 provenance; final
screenshots prove the final candidate's targeted smoke checks only.

Correction to the initial version of this section: it incorrectly stated that
session persistence uncertainty makes the Close barrier's stop/checkpoint fail.
`Controller::stop` only signals cancellation; it does not checkpoint. `shutdown`
then awaits the worker. A worker can therefore quiesce even when its final write
is refused by an uncertain store. A successful join neither confirms that write
nor clears uncertainty. Swift makes the same separation: `Sessions.swift:429–431`
cancels/awaits the run before releasing its journal; a poisoned journal refuses
synchronization but still closes (`SessionJournal.swift:236–239,293`). No shutdown
production change, force quit or persistence bypass was needed.

Four test-only regressions now verify this distinction. An idle, fault-injected post-rename-
uncertain controller shuts down without changing any retained snapshot/journal
bytes, while edit status remains unavailable until reopen confirms the actual Save.
A real Controller worker uses a gated loopback Responses stream: after a durable
partial fragment, a queued Begin triggers post-rename uncertainty; cancellation
and join finish without a provider terminal event or a second observed request;
retained snapshot/journal files remain byte-identical. Reopen preserves the interrupted, non-replayable partial
text, retry identity and paused pending edit. Retained-Arc checks prove joining
alone does not release the writer lock. Separate tests continue to reject worker
join failure and poisoned cancellation/worker locks; these are not persistence
uncertainty. No production shutdown code changed.

All 147 core tests pass (68 unit and 79 integration). Independent review verified
and reran all 68 unit tests, the focused reopen-confirmation test and the six
headless app save/stop checks. The real gated-worker test also passed 50 standalone
repetitions and 20 further independent repetitions. The complete workspace passes
252 default and 259 optional native-probe tests, strict all-feature Clippy, build,
formatting and diff checks. These are storage/loopback and headless lifecycle
checks, not a syscall trace, physical power-loss experiment, native desktop
interaction or a live reload feature.

Draft/catalog save failure is a different boundary. Source
`ApplicationLifecycle.swift:85–104` saves drafts/preferences before waiting for
helpers and refuses termination if those saves fail. Rust's existing
`ShutdownPlan` likewise does not reach its stop stage after a draft/catalog save
failure. Session uncertainty must not be confused with a poisoned synchronization
lock, worker panic or an uncertain WorkspaceStore; these have distinct failure
paths. Existing six headless save/stop/lifecycle checks were rerun for this correction.

There is still no live-controller reload command: joining does not release the
store while an Arc retains the controller, and opening a replacement before
retiring that owner cannot reacquire its file lock. The UI says recovery is
unconfirmed and text is preserved/blocked, without promising an in-app reload
control. A future catalog recovery must also confirm the validated catalog file
and parent directory before treating reopened cancellation receipts as durable;
that is separate from SessionStore's confirmation already implemented here.
At that checkpoint, global typing/Close revision saturation at u64::MAX was not fixed;
this checkpoint's checked-overflow proof covers the recovery merge only. Broader
checked protocol allocation and exact precommand draft flush belong to the next
reviewed slice. Native macOS IME, pixels, source window-Close versus true Quit,
and live-controller recovery remain unvalidated.

## Durable queued Cancel and exact-draft command boundary

Status: **implemented bounded recovery protocol; headless Linux validated**.
This extends the certain-status checkpoint above. At `fc9e530`, nonfreezing
Begin/adoption and source unowned “Resume Edit” / “Cancel Edit” row controls were
separate work; the later checkpoint below implements them. Live controller reload
and full held-edit parity remain incomplete.

Source: `QueuePanel.swift:370–739` distinguishes explicitly owned Cancel (discard
its rewrite) from recovered/unowned reconciliation (preserve genuinely unsaved
rewriting). `SessionQueueEdit.swift:132–146,175–208` records unknown cancellation
without releasing pending input; only resolving the named active hold can release
an idle, unpaused run. The Rust actor now checks certainty, typed status and exact
active edit/turn identity under one mutex. Saved/Cancelled/Removed answers are
unchanged observations with no transaction/publication/launch. Unknown writes its
own tombstone once, preserves another hold and never launches. Named Active
cancellation commits before atomically reserving an eligible idle worker; a running
worker is not interrupted. Paused/reopened/Error input is not implicitly resumed.

Catalog v3 adds per-chat identity-only Pending/Settled cancellation receipts,
independently fenced from draft revisions. Preparation persists before actor
Cancel; reopening retries the same identity, never Begin. A settled receipt is
retained to reject delayed preparation. Equal-revision unequal draft contents
conflict; settlement can preserve a newer already-reconciled autosave while clearing
only the exact receipt. Valid v1/v2 catalogs open without rewrite; promotion is
monotonic and malformed records remain untouched. Existing catalog files and parent
directories are confirmed before recovered records become authoritative.

The existing owned Cancel button now uses this protocol. Its callback captures
chat identity; completion checks project, operation and controller identity and
updates that retained chat rather than the current selection. Startup Pending
recovery leaves ordinary typing enabled, retains rewrite metadata separately and
merges only after certain terminal status. Marked composition defers replacement
until the editor notification; a known later command failure invalidates the deferred
answer. Whole merged drafts and checked revision allocations are validated before
replacement. Owned Cancel discards only after durable settlement; a later unrelated
actor failure rechecks certainty without resurrecting the durably discarded rewrite.
Window rebinding retains the same editor entity and does not steal focus.

Save and every generic Remove now persist the exact captured draft before actor
mutation, even if the cached display omits the hold. Their existing exclusive busy
barrier remains through completion; errors preserve text for retry. Submit, intent
recovery and queue operations cannot cross a pending Cancel. Close waits for active
operations. Typing, command capture, submission restoration and Close draft/selection
revisions use checked allocation rather than wrapping/saturating this protocol's
revision fence. Exhaustion keeps text and refuses unsafe persistence/Close; it does
not invent a revision reset. Session shutdown behavior is unchanged.

Validation: **300 default workspace tests / 307 with the optional native lifecycle
feature**, strict all-target Clippy in both configurations, formatting and Linux
workspace build pass. Core/catalog crash-cut and CAS tests cover prepare/actor/
settle, stale receipts, newer autosaves, payload conflicts, malformed v3 records,
pre-/post-rename uncertainty and reopen confirmation. Fourteen isolated mutation
checks reject removed catalog/actor safeguards. Ten actor cases include configured
loopback zero-dispatch terminal/unknown replays, one-time active release, a gated
active worker, identity races, Error/paused guards and real storage faults. Sixteen
new headless GPUI cases cover owned/recovered semantics, actual catalog-path
failure/retry, exact-draft Save/Remove failure, marked-text deferral, later failure,
merge limits, revision exhaustion, navigation/Close and window rebinding. Independent
review reran all 121 app tests and 95 core unit tests. These tests do not prove
physical power-loss behavior or native IME/pixel/accessibility parity. Current
macOS compilation/runtime evidence for these new bytes is pending publication.

Actual Linux desktop validation passed the bounded recovery matrix on candidate
`fc409b7e3f240f4b73f517a3ced6552719ecff1c80e693bb939652421440efc6`.
A disposable catalog-path obstruction showed the pending cancellation error while
preserving the rewrite and hold; restoring that fixture allowed Cancel to settle
and restore the ordinary draft. Pending Active/Cancelled/Unknown startup recovered
and retained the exact unsaved rewrite plus ordinary draft once; Pending Saved
preserved the saved queued text and restored only the ordinary draft. Repeated
Close/reopen did not duplicate a merge. Actual Save and generic Remove with a
catalog-path obstruction preserved the rewrite, original row and hold; after the
fixture was restored, retry respectively saved the rewrite or removed the queued
row, restoring the exact ordinary draft. All windows closed cleanly and fixture
obstructions were restored. A transient blank bound-window startup capture on the
Remove case resolved before interaction/full-desktop capture; its cause remains
unproven, consistent with the separately recorded intermittent paint observation.
Typing during the obstruction can produce a newer,
separately owned draft-save warning. That warning remains stale after a successful
Cancel until restart; it does not block typing, retry, Close or durable recovery.
At `fc9e530`, revision-tagged draft-error ownership remained a separate follow-up;
the next section records its bounded fix. No arbitrary message prefix is cleared. At `fc9e530`, Begin still used the earlier
frozen-composer command path. There is no generalized operation
journal, outcome retention policy or live reload added here; provider/tool behavior
and native lifecycle policy are unchanged.

## Draft-save warning ownership

Status: **implemented app-only safety correction; headless Linux validated**.
The preceding recovery QA exposed a stale warning: a failed debounce could replace
Cancel's error, then survive even after a later exact draft save had succeeded.
This is a Rust error-reporting correction, not a new claim of Swift feature parity.

Each chat now tracks the last confirmed durable draft revision and its latest
unconfirmed draft-save failure. Successful debounce writes, exact Save/Remove
flushes, Cancel preparation and applied settlement advance confirmation monotonically.
Only the matching displayed failure covered by that revision is cleared. A delayed
older failure cannot resurrect a warning after newer persistence; newer failures
and unrelated notices are preserved. Catalog-level debounce completion checks
project/chat/snapshot identity, while actor-dependent operations retain their
controller/operation fences. No-op debounce or stale settlement results remain
conservatively unconfirmed. Exact flush confirmation is retained even if the later
actor operation fails, so its new error is not overwritten by an older save failure.
No schema, controller lifecycle, queue policy or persistence ordering changed.

Fifteen pure ownership tests and eight isolated mutation checks cover monotonic
confirmation, delayed/out-of-order callbacks, equal-revision ordering, hidden
failures, maximum revisions and exact-message ownership. Four additional headless
GPUI tests reproduce real disposable catalog-path errors: typing after failed
Cancel then retry, ordinary debounce recovery without Cancel, an unrelated newer
warning, and an exact successful flush followed by an actor failure. Tests advance
the fake clock through the actual 150ms debounce rather than assuming idle callbacks
have persisted text. **319 default workspace tests / 326 native-feature tests**,
strict all-target Clippy in both modes, formatting and Linux workspace build pass.
Actual Linux collision/retry validation passed on immutable candidate
`2dd806b1dc3fc6950ba974e81d658d84f6277e8c0d616d36109d1fe2483f0307`.
The matching warning cleared immediately after restoring the disposable catalog
and retrying Cancel, and separately after successful debounced autosave without
Cancel. Exact ordinary/rewrite drafts survived Close/reopen; typing/Undo at 920×600
worked. The unrelated recovery notice remained visible. Every fixture obstruction
was restored and the app closed cleanly. Fresh 1180×812 captures show failure,
Cancel-cleared, autosave-cleared and reopened states. Newer/unrelated-error callback
races remain headless-only proof. Native macOS interaction/IME, accessibility and
new-checkpoint CI remain unverified.

## Nonfreezing queued Begin and source held-row controls

Status: **implemented app-only slice; headless and running Linux validated**. Specification:
`QueuePanel.swift:185–238,330–465,700–739`, including the source distinction between
preparing, composer-owned and unowned holds. Begin now claims a per-chat operation
before dispatch but leaves ordinary typing enabled. The actor takes the hold first;
a certain typed reply then adopts the whole queued message and captures the latest
ordinary draft. No displaced draft is frozen at click time. A retained earlier
rewrite is reconciled before another edit can replace its metadata.

Adoption validates the complete candidate and checked revision, and waits while
marked composition is active. The existing editor notification resumes on unmark;
Save, Remove, submit and Close cannot cross the pending operation. A known later
actor failure invalidates an older deferred success and requests a fresh certain
status. Project/chat/controller/operation and window-generation fences reject stale
completion. Text belongs to its retained chat after navigation; focus moves only
when the same active window, selected chat and first responder still match.

Cancel Edit abandons pending adoption synchronously before v3 receipt preparation.
It reuses the preceding durable Cancel protocol, so a Begin that executes later is
fenced by its exact identity. A failed preparation never installs the abandoned
rewrite; retry keeps the latest ordinary draft. Existing owned Cancel still discards
its rewrite only after durable settlement, while unowned recovery preserves unsaved
rewriting. Core actor, schema, provider and native lifecycle policy are unchanged.

Rows now show the original preparing mini spinner, “Editing in the composer”, or
“Edit open” with Resume Edit/Cancel Edit. Other edits and unowned held-row Remove
are guarded as in the source. Original fonts, ghost padding, hit areas and ordering
are retained. Queue-local info/edit/promote/remove glyphs use the source 10.12pt size
inside 22pt hit areas; other app icons are unchanged. The renderer shapes complete
labels and allocates the measured available width once, allowing wrapping and row
growth rather than truncating actions. A 30pt outer minimum includes the source 26pt
row plus 2pt vertical insets on each side; the source 3.5-row cap remains a scrolling
viewport. Ordinary 920px half-split and wider geometry/reachability are tested headlessly;
actual pixel evidence is recorded separately below.

The current Rust sidebar/split constraints can still permit an extreme 149pt chat
pane. Held controls require 71.5pt of fixed source padding/icons/gaps before text,
plus row furniture and panel chrome, so universal fit there is not claimed; changing
pane minima is a separate source audit. Native SF Symbol/Label metrics and pressed
scale/transition motion remain adapter limitations. There is also a pre-existing
composer undo gap across programmatic draft swaps: source `NativeComposer.swift:164–168`
uses native `insertText` to preserve undo, while the shared Rust `set_text` resets
its engine. Both the earlier Begin path and this slice use that method; ordinary
typing/Undo proof does not establish undo parity across Begin/Cancel replacements.
No native macOS fit, VoiceOver, IME or frame-performance claim follows from these tests.

Twenty Begin GPUI tests cover typing/latest capture, named Resume, Cancel before
reply and during marked adoption, navigation and independent focus changes, stale
controller/window replies, synthetic later-failure invalidation, revision exhaustion,
oversized live drafts, actual Begin/Cancel-preparation path failures and retries,
earlier rewrite preservation, warning ownership, and wrapped-row scrolling.
Twelve control tests cover source metrics, shaped Unicode/fallback, placement and
actual wrapped height. **352 default workspace tests / 359 with the optional native
lifecycle feature**, both strict Clippy configurations, formatting and Linux build
pass on the responsive candidate. Final independent review verified all nine source
hashes and independently reran all 173 app tests. Six isolated compiling mutants
failed intended assertions for displaced-draft preservation, focus equality, window
binding, synchronous Cancel abandonment, checked revision preflight and deferred
status invalidation. No compile failure or timeout counted as a kill. The incidental
IME unwrap from earlier exploration is excluded. Final isolated baseline, restored
rerun and fresh restored rebuild each passed all 20 Begin tests; rebuilt restored
binary matched baseline byte-for-byte.

Initial actual Linux candidate
`890133de4475b7475029687b47e7cfd67286c7c08238e3cafbde6d297eac7b7c`
passed full-width Resume/Save, held Cancel and rejected-Begin retry data checks,
but failed ordinary 920×600 half-split readability: bounds fit while labels broke
into character fragments and the queued preview disappeared. The initial bounds
assertion did not prove readable text. A stale Begin warning after successful retry
was also found. Fresh full-width candidate
`3c2a69c116b77cd635cd07fbce00ce745a9ba894c111593a2e8e87c593e4ff5f`
confirmed that a rejected Begin preserves the ordinary draft and a successful
retry clears its turn/controller-owned warning, followed by exact Cancel/Close/reopen
recovery. On the earlier 890 candidate, a real local gated stream stayed active
through Edit and Save with one request and no cancellation marker; delivery later
followed root, edited follow-up A and follow-up B, preserving captured model/effort
and the ordinary draft. Those checks are distinct from final responsive validation.

The original Swift row is a single HStack, and its split constraints do not establish
a sufficient minimum chat width. On October 5, 2026 the user approved a narrow
adaptation: in a split pane, only an unowned Held row moves its existing controls
onto a second line when measured complete-word controls and a readable queued
preview cannot coexist. Order, fonts, padding, hit areas and wider-row placement stay
unchanged. No pane/sidebar minimum was invented. The second line gets the exact
remaining row width after Remove and its gap; preview stays on the first line.
Actual shaped wrapped height now contributes to list content height, still bounded
by the original 3.5-row-plus-headings cap, measured room and 52pt floor. A single
Held row is fully visible when room permits; constrained content stays scrollable.
Tests assert complete-word and preview allocations, vertical ordering, exact
singleton content/heading accounting and action-line reachability at the floor.
Final candidate
`731c38f8581873e0fda19686e5dfdef63c36e0c64e64f9dd8e68661f39ed4e4e`
passed fresh running Linux checks at 1180×812 and ordinary 920×600 half split:
held preview and complete-word actions remain readable, a grown single row is fully
visible with available room, row eight is reachable, and the owned label is readable.
Resume/Save changed only the requested text and retained captured model/effort plus
the exact ordinary draft. Direct held Cancel and retained-owned Cancel passed. A
fresh pre-rename snapshot-path collision preserved the ordinary draft and unowned
state; restored retry adopted text and cleared its matching warning. Cancel followed
by clean Close/reopen preserved the exact ordinary draft and all eight queued items
without dispatch. All fixtures closed cleanly. Current screenshots are
`agent-begin-731c-{normal,held-minimum,single-minimum,owned-minimum,last-row,failure,retry,restart}.png`;
minimum/owned/last-row images are 920×600 and the others 1180×812. Prior candidate
890 supplies the separate running-stream test, not these final pixel results.
Delayed Begin/IME and stale-completion interleavings remain headless evidence.
Native macOS interaction remains unvalidated.

## Queue-header Resume / Send queued

Implemented the original `QueuePanel.swift:125–137` entry point, using
`SessionDisplay.swift:339` availability and the compact play-label pill from
`Design/PiButtons.swift:77–93`. A nonrunning, nonempty queue shows **Resume** when
paused and **Send queued** otherwise; an edit hold keeps the action visible but
disabled with the original finish/cancel help. Collapse precedes status, the
reorder hint and trailing action. The misplaced composer Resume was removed.
The panel's vertical gap is the original 6pt; status and reorder hint use the
original 10.5pt medium micro font, sharing the same shaping/rendering weight. Status/hint/action labels are shaped with the actual
platform font, size and weight; explicit widths preserve natural text size when
space permits and proportionally wrap the labels in a constrained header.
Available width subtracts existing panel margins/padding/borders, collapse control,
action and source gaps exactly once from measured pane width. The allocator has
no character-count estimate, truncation or fixed row height. GPUI supplies font
fallback; failure to resolve every font remains the framework's existing fatal
rendering condition. Empty queue panels remain absent, as before.

The callback revalidates chat identity and current state, shares the existing
per-chat queue-operation ownership token, and uses the existing Controller Resume
transaction. It does not make the composer read-only or replace its marked text.
Completion addresses the original chat/project/controller/operation identity;
Close waits for the operation, and errors stay visible without selecting a chat
or replacing its draft. Production core dispatch/persistence semantics are
unchanged. Resume consumes remaining pending work, not the interrupted turn that
belongs to the separate Retry action.

Five new fake-platform tests cover visibility/labels/edit hold, duplicate/stale
callbacks, disconnected failure, marked Unicode draft/focus/revision retention,
navigated-away completion and Close barriers. Geometry checks cover expanded and
collapsed headers with multiple follow-ups, long held/error labels and **Send
queued**, and prove the ordinary paused Send button fits the previously clipped
920×600 half-width pane. Error+Retry checks prove header bounds only; the broader
composer-width ladder remains incomplete.

Six new gated loopback actor tests cover captured IDs/text/order/model/effort,
exactly-once dispatch, active/held/disconnected rejection, provider EOF failure,
active close/reopen, and resuming remaining work without silently retrying an
interrupted turn. A disposable snapshot-path collision additionally verifies failed writes leave the snapshot/publication and
backup bytes unchanged, make no request, and allow the same Controller to resume
once after storage is restored. All 133 core tests pass, including 16 runtime
tests; 700 focused executions and eleven isolated mutation checks also pass.
No mutation touched the canonical production build cache. The complete workspace has 226 default and 233
optional native-probe tests passing, with strict all-feature Clippy, build and
format checks. Independent review reran all 40 queue UI/policy tests and seven
Resume runtime tests, then checked the final shared micro-font shaping/rendering
weight and reran the 40 UI/policy tests. These are headless/loopback observations;
macOS Resume/IME/accessibility validation remains separate.

Initial Linux candidates `021f9070` and `6d790ca6` passed fake-platform outer-bounds
checks but rendered status/hint text in near-character-wide columns after
Stop/reopen. Those candidates are superseded; their screenshots are not evidence
for the corrected binary. Explicit font-shaped widths fix the native rendering
failure that flexible intrinsic sizing and outer-bounds tests missed. The added
readable-label regression checks width, normal/constrained header height and
resize/snapshot refresh, while actual Linux screenshots remain necessary proof.

Linux candidate `f434223a1c2f0249156f8a280e299f895a92c200ee1c9fbe69a40d6a024e2567`
passed stopped-state startup at normal/minimum/split sizes, collapsed Resume
sending remaining B,C exactly once, and idle **Send queued** sending A,B,C exactly
once only after clicking. Composer typing/focus/Undo and the exact Unicode draft
survived; disconnected Resume showed a visible error without removing queued
work, and edit hold/Cancel/close/reopen checks passed. Ordinary paused 920×600
half-pane Send is fully visible. A transient Close while Cancel remained in flight
correctly waited for chat operations; retry closed cleanly. This does not establish
all composer widths, native macOS menu/input behavior or OS IME parity.

Final binary `fe94bb94d7db59cedc897cc4db8563d8e34bdaa2a2c43e13a523bd9ca61518e9`
aligns the retained reorder-hint weight with the original medium micro font,
sharing one weight for shaping and rendering. Fresh targeted 1180×812 and
920×600 half-pane screenshots show readable labels and the ordinary paused Send
fully visible. The app closed cleanly and all disposable gateways stopped.
The broader functional observations above retain their `f434223a` provenance;
these final screenshots are a distinct font/geometry check.

## Measured adaptive queue height

`QueuePanel.swift:101–117` budgets the list after actual pane/composer geometry,
150pt transcript reserve, 66pt panel chrome and 36pt footer allowance. The list is
bounded by its content and three-and-a-half rows plus headings, with the source
52pt one-row-and-heading floor taking priority when space is insufficient.
`ConversationPane.swift:176,193,290–298` supplies the measured dimensions.

Rust now observes the real GPUI pane and composer border box after layout, adding
only the same 8pt top/6pt bottom composer spacing used by rendering (matching
`ComposerInput.swift:156`). A nonpainting, out-of-flow pane probe avoids guessing
from whole-window height or double-subtracting chrome. Deferred measurement
completion checks chat/window-generation identity and notifies only when dimensions
change. The list retains its source computed height and the status footer remains
visible; the composer preserves baseline safe flex shrinking when space is tight.
Terminal height is zero because no terminal is implemented.

The current Rust footer can wrap in a narrow split, unlike the assumed source
36pt line. Only measured overflow beyond that already-reserved 36pt is additionally
subtracted; footer layout is preserved. With a tall draft and wrapped footer at
920×600, the 52pt queue floor can still leave less than 150pt of transcript. This
is an explicit constrained-layout result, not a universal reading-space guarantee.
Footer compaction, composer-cap redesign and broader native fidelity remain outside
this slice.

Nine pure presentation checks and four GPUI fake-platform geometry checks pass.
They verify exact source policy/floor, nonfinite initial measurements, one-time
composer margins and footer overflow, short/tall drafts, edit/recovery banners,
collapse, normal/minimum/split widths, stale callbacks and last-row reachability.
The exact combined tall-draft/recovery/minimum-split regression also checks visible
status, an input viewport of at least 44pt, unchanged active focus/draft/revision,
and stable repeated-layout measurements. Independent review inspects accounting,
lifecycle ordering and reruns the focused checks.

The full run exposed an existing test observation race: a stream snapshot can be
visible before its separate publication counter increments. Test-only checkpoint
`916cd712cf479453aa947a4bc393e1b5f5e02f8b` keeps exact snapshot/disk invariants
and requires counter equality only for quiescent callers, adding a no-worker
regression. Production runtime behavior is unchanged. With that correction,
all 214 default and 221 diagnostic-feature workspace tests, strict Clippy/build in
both configurations, formatting and diff checks pass. Independent final review
reran all 13 geometry/presentation checks on the corrected candidate.

Fresh Linux candidate `d3be781e7f6d3fc22e01ce6fcc5aef6bf0d1f0649f704a2f05151b0e483d7863`
passed ordinary short/tall, edit/cancel, collapse and scrolling checks, but introduced
a combined recovery+tall+920×600 half-pane regression: a new non-shrink flag on the
composer pushed the status strip below the viewport. Same-fixture baseline
`7e5fa1ab38e80b4b6a3133790af3c0759616d965acdaf5db361f4b59d2550c40`
kept the status visible by shrinking the composer. That one flag was removed
before publication; no new composer cap or footer redesign was introduced.

Final Linux binary `e0a60720982664cb5002ac357320042766b0c94189e246b633284b8fe7e5b97f`
passed the exact combined regression with visible status, last queued row and
last draft line reachable, typing/Undo, collapse/expand and close/reopen preserving
the exact 1529-character synthetic draft. Ordinary tall/minimum checks also pass;
the app closed cleanly. Earlier screenshots retain their own candidate identity.
The same pre-height baseline reproduced horizontal Send clipping in the narrowest
tested split; that separate responsive-control gap is not fixed by this height
slice. No universal 150pt transcript guarantee, arbitrary multi-recovery coverage,
macOS interaction, native IME or measured frame-performance claim is made.

## Durable follow-up drag reorder

`QueuePanel.swift:98–99,131,153–155,352–360` supplies the original row drag and
“Drag to reorder” hint. Follow-ups alone can move; steering rows and edit-held
queues cannot. The gesture retains the displayed follow-up identities and applies
the source single-row move semantics before/after a target. Original 30pt rows,
22pt controls, numbering, section order and capped scrolling remain in place.
The drag preview uses the row's number, literal preview text and control geometry;
an overlay insertion line does not change row height. Bounded edge scrolling keeps
later rows reachable at the minimum window size.

The existing durable reorder API now returns typed `QueueOrder` when the captured
membership is stale, duplicated or incomplete. Source membership-before-edit-hold
precedence is retained. The exact notice is “The queue changed while you were
dragging, so nothing was moved. Drag again.” Other failures say that the queue was
not reordered. No optimistic durable order, request restart or composer freeze is
introduced. Captured turn text/model/effort and steering order remain unchanged.

App drag/drop and completion check chat, project, controller, window binding and
operation identity. Escape, outside release, chat navigation and rebinding cancel
only the gesture. Mouse-up cleanup is deferred until the drop callback finishes.
One shared queue-operation token serializes promotion/reorder admission and uses
the existing reviewed close barrier; completion/failure releases it. Row action
buttons retain their own mouse-down/click path rather than initiating a drag.

Nine app checks exercise actual GPUI fake-platform mouse dispatch, cancellation,
stale membership, row actions/edit holds, minimum-size edge scrolling, composition
and rebinding, plus pure move/edge policy. Six focused core checks cover typed
rejection, stale remove/deliver/promote/add cases, captured choices/steering, rename faults,
uncertainty/reopen and live loopback request/delivery order. The prior six promotion
app checks also pass after sharing operation ownership. Independent review reran
all 21 focused checks from immutable binaries.

All 205 default and 212 diagnostic-feature workspace tests, strict Clippy/build in
both configurations, formatting and diff checks pass in the isolated canonical
target. No mutation builds, new dependencies, provider/tool execution changes or
native sheets are part of this slice. Fresh Linux binary
`7e5fa1ab38e80b4b6a3133790af3c0759616d965acdaf5db361f4b59d2550c40`
passed actual pointer reorder A below B, outside-release no-op, queued Edit and
held-drag rejection, Cancel/draft preservation, and 920×600 scrolling to later
rows followed by moving H before D. Stop/restart retained the queue. After an
explicitly stopped steering C, Resume produced the observed synthetic request
and transcript order B,A,C,H,D,E,F,G; all eight follow-ups completed and the exact
composer draft remained. Three observed launches painted before input.

The desktop tool provides an atomic drag operation, so timed edge dwell,
mid-drag Escape and concurrent stale races remain headless/core checks rather
than live desktop proof. Persistence fault cuts also remain core-test evidence.
Native macOS drag, accessibility and real OS IME interaction remain unvalidated.
The adaptive room-budget gap is addressed in the subsequent measured-height
slice; this drag checkpoint did not resolve the previously recorded intermittent
startup-paint observation. Exact new-checkpoint
CI remains to be observed after publication.

## Durable queued follow-up promotion

The source `SessionQueue.swift:91–100` moves one existing follow-up to the tail
of steering without changing its identity, text or captured model/reasoning.
Rust now exposes that transaction through the existing queue row's source 22pt
arrow action, offered only while running and without a queue edit hold. The
original current request is neither cancelled nor restarted. Its live stream
continues across the metadata checkpoint; steering is delivered at Rust's
existing response boundary, before follow-ups. The tooltip describes that actual
boundary rather than promising the unimplemented production tool batch.

Session validation rejects missing/already-steering, stopped and held targets.
Controller admission additionally checks the real active worker under the same
mutex as persistence. Failed and uncertain writes retain existing rollback and
fail-closed semantics; reopened sessions retain promoted lane/identity/choices.
The app captures project/chat/controller/operation identity, leaves composer and
IME state editable, and applies completion to the original chat after navigation.
Controller replacement invalidates old operation ownership. The existing close
barrier waits for active or inactive chat promotion completion without freezing
composition; either success or failure releases that pending-work guard. Successful retry only
clears its own still-displayed notice, not a newer unrelated error.

Six core regressions cover full Unicode/captured choices/order, all admission
failures, before/after-rename faults and recovered stream data, real loopback
blocked-response promotion with a subsequent delta, queued delivery order, Stop,
reopen and Retry with changed current configuration. Six GPUI fake-platform
checks cover action policy/22pt bounds at normal/minimum widths, composition,
stale/replaced ownership, navigation, error ownership and pending-promotion close
barriers across success/failure and active/inactive chats. Those headless checks
are separate from desktop interaction and native macOS validation.

Final gates use an isolated Cargo target seeded only with third-party artifacts;
all first-party libraries and tests are freshly compiled from this checkout.
No mutation-test artifacts are reused for the final candidate. All 191 default
and 198 diagnostic-feature workspace tests, strict Clippy/build in both
configurations, formatting and diff checks pass. Independent review reran six app,
three session and three runtime promotion checks on immutable final binaries.

Fresh Linux binary
`73b8e7a47e1ebe7ca7671ea46fa44c40774766db57a261c7eaf9770625b43929`
passed real arrow-click promotion with a gated loopback response: B moved to
steering while A stayed a follow-up, request count remained one, and the composer
stayed focused/editable. At 920×600 the controls and both lanes remained readable.
Stop/close/reopen retained B's steering lane, A's follow-up lane and the exact
composer draft. Resume produced the observed synthetic request order root, B, A,
with B and A completed in the transcript. No external provider was contacted.

One restart displayed a blank client until pointer movement; a same-fixture
pre-promotion baseline and repeated final candidate both painted before input.
This intermittent startup observation remains open, not attributed to promotion
or claimed resolved. Native macOS interaction, native IME, VoiceOver and full
source tool-batch parity remain unvalidated/missing. The new checkpoint requires
its own CI evidence. No dependency, provider setting, tool execution or
native-sheet behavior is enabled by this slice.

## Sidebar Pin/Unpin slice

The original right-click entry point supplies only the working `Pin Chat` or
`Unpin Chat` action, with the source pin symbol and 9pt sidebar indicator. No new
toolbar or inert rename/archive commands are substituted. Pinned chats sort first,
oldest pin first, followed by newest creation order and stable ID ties; repeated
Pin retains its original timestamp. Legacy Rust catalogs' append order is used
for stable creation-order presentation without rewriting the file on open.

Organization metadata is distinct from streamed session titles. Existing-record
pin writes patch only organization fields and leave current drafts, submission
receipts and selection unchanged. Pending record, captured draft and pin commit
in one catalog transaction. A successful pending materialization then queues its
current revision through receipt-aware autosave, including edits typed during the
write or after navigation; an earlier missing-autosave race was reproduced and
fixed before publication. In-flight pin writes prevent pending-empty discard and
make Close wait, without freezing typing or stealing a newer chat's focus.

Legacy v1 catalogs remain readable without an open-time rewrite. Organization
metadata promotes a successful transaction to catalog v2, so older Rust binaries
reject rather than silently remove it; mislabeled v1 metadata is rejected without
rewriting. Before-rename failure preserves previous bytes; after-rename uncertainty
requires reopen and preserves the durable result. This is the Rust catalog only,
not Swift journal compatibility.

The macOS bridge uses native NSMenu and existing Cocoa/objc package versions.
It validates the expected GPUI/native window, locates exactly one attached GPUIView
child inside the AppKit content container, converts the anchor in that hierarchy,
and tracks the menu on the main queue outside GPUI borrows. It records action intent
only inside the native callback and invokes the identity-checked completion after
tracking ends. Linux uses the same right-click action through a GPUI context popup.

Local gates: 167 default and 174 diagnostic-feature Rust tests, strict Clippy/build
in both configurations, formatting and diff checks passed. Coverage includes
ordering/idempotency, old formats, pending materialization, receipt/draft isolation,
project/identity rejection, write failure and uncertainty, menu cancellation/focus,
newer typing after idle/navigation, stale callbacks, and native hierarchy/ownership
policy tests. Linux desktop candidate
`a0fde624e0f1ecbe5d53de090efc5b229f5b9f898e7e382d174d8643fcc4667e`
passed right-click Pin/Unpin on a nonselected chat without changing selection or
draft, pin/creation ordering, Escape, pending creation, restart and minimum-size
checks. A real disposable catalog-write failure preserved editability and pin
rollback, but retry left its obsolete error banner. The final candidate
`36c327267df0425aefd9ba3bbd6c6c82347f3a8f00b4275679f44506e2f99e9e`
clears only its target/display-owned matching pin notice on confirmed success;
newer unrelated errors and another target's identical notice remain. Independent
re-review and regression tests pass. Fresh desktop validation of that final binary
confirmed failure keeps the draft editable, retry clears the matching banner and
commits the pin, and the same identity/pin/exact draft survive close/restart and a
clean final close. Earlier normal/minimum-width evidence remains attributed to its
own candidate, not relabeled as this final binary.
Published `b75dc7cd9bf04e61afd7935a9fc7af78bc0109ac` passed exact
[Linux CI](https://github.com/BelloWare/BelloAgent/actions/runs/37290801435) and
[macOS CI](https://github.com/BelloWare/BelloAgent/actions/runs/37290801409),
including compilation/linking of the native menu source and the limited own-window
lifecycle probe. Actual native right-click menu interaction remains unvalidated;
the lifecycle probe does not exercise menu tracking. No new library family or package version
was added; already-present Cocoa/objc now serve the actual macOS context menu.

Rename remains deferred: the source uses a real parent-attached AppKit sheet and
manual-title authority over helper snapshots, plus 120-grapheme normalization.
A generic dialog or scalar truncation would not preserve that contract.

## Next/previous chat shortcuts

`WorkspaceSessionOrganization.swift:93–130` and `PiApp.swift:113–114` define
Command-Option-Down/Up navigation through the currently visible sidebar order.
The Rust shortcut uses that same clamped, non-wrapping selection policy; when the
current chat is filtered out, Down chooses the first visible chat and Up the last.
Rendering and traversal now share one filtered/pinned-order query. Linux uses
Control-Alt-Down/Up, matching the existing platform command convention.

Selection reuses the existing per-chat draft/controller and lazy-load generation
path. The new shortcut does not bypass Quick Open, context menus, close prompts,
or focused marked-text composition in the composer, filter or file editor.
The file-tab queries are read-only; existing mouse navigation and Close/Quit
composition policy are unchanged. Eight real GPUI fake-platform tests cover
ordering/endpoints, filters, exact modifier rejection, modal routing, pending
Unicode drafts and rapid lazy selection, and composition guards through actual
root routing. These callbacks do not validate a native IME candidate window.

Local validation: 175 default and 182 diagnostic-feature workspace tests,
strict all-target Clippy, formatting and Linux build pass. Independent review
cleared the final routing and tests. Fresh Linux desktop binary
`8e62a42c3f6f9bb576fc8bb0626ef6031245df62cb77b6660a9dbf5668053537`
passed pinned/filter/no-wrap traversal, pending-draft preservation, Quick Open and
dirty-file prompt interception, 920×600 layout and exact-draft reopen. These tests
used supported window-targeted keyboard input: full-desktop Control-Alt-arrow
input was not delivered to the app, consistent with the desktop's workspace
shortcut bindings. No system shortcuts were changed. Native macOS shortcut
interaction and source View-menu command entries remain unvalidated or missing.

QA separately found that an existing Rust dirty-file prompt opened while the
composer owns focus cannot receive Escape through its file-child handler. The
following bounded correction addresses that defect; it is not a claim that this
Rust save dialog reproduces the original Swift file reader's UI.
No new dependency, provider request, archive behavior or native menu bridge change
is included.

## Dirty-file prompt keyboard cancellation

The visible file prompt now receives Escape/Enter from the root key handler even
when the composer still has focus. It uses the same existing Keep Editing state
transition as the child handler and does not focus the file, save, discard, close
the tab or alter either draft. Original `WorkspaceTabs.swift:65–85` documents
preserving prior focus for pane-tab close; the Rust safety dialog itself is an
existing Rust feature, not a newly ported Swift dialog. Active marked composition
in the focused composer, filter or file editor takes priority over cancellation.
Quick Open and other existing root modal handlers keep their prior ordering.

Four GPUI fake-platform regressions cover composer/file focus, both cancel keys,
unchanged chat/file/disk bytes, root/child composition priority, and explicit
held-key/KeyUp events across pane hiding followed by a fresh independent Enter.
An app-owned consumed-press latch prevents a held cancellation Enter from becoming
a Send after the prompt disappears. macOS and Wayland supply GPUI
`KeyDownEvent.is_held`; pinned GPUI 0.2.2 X11 reports false on every keypress, so
physical X11 auto-repeat cannot be distinguished by this guard and remains a
platform limitation. No GPUI fork or timing heuristic is introduced. The save state
machine and asynchronous completion policy are unchanged. This targets the
currently displayed pane tab; broader native dialog/accessibility and hidden-tab
close presentation remain separate audit scope. All 179 default and 186
optional diagnostic-feature workspace tests, strict Clippy/build in both
configurations, formatting and diff checks pass. Independent review reran the four
focused tests. Fresh Linux binary
`72af4123bb5948a993b72a1832315000416878c7a58347f5658f386fa6445404`
passed single Escape/Enter cancellation with composer and file focus, unchanged
chat/file drafts and disk bytes, and close/restart checks. No message was submitted
by cancellation. This is real single-press desktop evidence, not physical held-key,
macOS interaction, native IME or original Swift dialog parity validation.

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

## Source Stop keyboard shortcut (2026-10-06)

`PiApp.swift:132–134` and `WorkspaceChanges.swift:67–85` define Command-period
as the focused chat's Stop action, except while a sheet or editable tab text owns
input. Rust now routes that exact shortcut (Control-period on Linux) through the
same cancellation/result path as its existing Stop button. Extra modifiers are
rejected. Current-chat identity is resolved at the event; an inactive running
chat is not stopped by a shortcut in a newly selected idle chat. Idle presses do
not clear an unrelated notice. The composer is not replaced, focused or committed,
so its draft, marked text and selection remain owned by the editor.

Existing Quick Open, context-menu and close-dialog keyboard ownership remains in
front of the shortcut. File close prompts and the currently visible editable file
also block it. The embedded editor reached by selecting an untracked Changes row
uses the shared workbench's actual focus/read-only state. Both the outer pane/tab
and internal Editor panel must be visible; a retained hidden editor focus handle
does not veto the command. Read-only previews do not count as editable tab text.
This restores keyboard access to the existing Rust running-worker Stop behavior,
not missing Swift helper-loss recovery, pending-only queue semantics or native
Conversation-menu entries.

Both shared Git pins advance together from `ee0d27a` to published
`393133cd19d134ffd93c3a86449d94a7b1040683`. Besides the small read-only workbench
query, the imported source delta consists of the already-published additive
`EditorEditState`/retained-memory API and platform-separated filesystem tests.
Agent does not call the new edit-state transfer API. Shared manifests/GPUI/library
versions are unchanged; Cargo.lock changes only the two Git source entries.
Independent review checked this dependency scope and final shortcut routing.

Five GPUI fake-platform tests exercise actual root routing and held-open synthetic
loopback requests, current/inactive chats, exact modifier rejection, modal and
dirty-file guards, composer/file marked text, actual rendered embedded-editor
focus, hidden internal/outer panels and large read-only previews. Removing the
Stop call, file edit guard or workbench edit guard makes its targeted regression
fail. Final restored-source gates pass: 396 default workspace tests, one explicitly
ignored fixture, strict workspace/all-target Clippy, formatting and native Linux
build. The shared checkpoint separately passed 101 tests with one ignored fixture
and strict shared all-target Clippy. These are headless/loopback and compile checks;
native Linux shortcut QA and macOS keyboard/OS IME acceptance remain separate.

Fresh Linux desktop validation of immutable binary
`e6de9e2d480059832e44a3399bfc1b9a32f62272d10b93a2ff2574b1873110c6`
used three local gated synthetic requests. Control-period cancelled the first
from the composer and retained `draft keep`. During the second, Quick Open,
a dirty-file prompt, a focused tracked-file editor and the Changes pane's
untracked-file editor each left the request running; returning to the composer
and pressing the shortcut cancelled it. The third cancelled from the actual
focused greater-than-8-MiB read-only preview, again retaining the draft. Gateway
request/cancellation records and screenshots corroborate each outcome. This is
Linux native shortcut evidence, not macOS keyboard or OS IME acceptance.
The exact shared dependency checkpoint also passed both
[Linux CI](https://github.com/BelloWare/BelloBox/actions/runs/37418779184) and
[macOS CI](https://github.com/BelloWare/BelloBox/actions/runs/37418779183).

## Changes and History keyboard command (2026-10-06)

`PiApp.swift:107–110` exposes Changes and History with Command-Shift-G.
Rust now routes the same exact shortcut (Control-Shift-G on Linux) through its
existing `open_changes` action. Like `WorkspaceChanges.showChanges` and
`TabHost.open/activate`, repeated use reuses the workbench and preserves its
current panel, chat selection and existing file entities. It does not replace
text or force focus. This command remains available from editable file text;
the focused-chat Stop exclusion does not apply to a command that opens a tab.
Existing Quick Open/context-menu/close-dialog ownership and the Rust dirty-file
safety prompt keep priority. Native View-menu entries are still separate scope.

Three GPUI root-routing regressions cover repeated History reuse, exact modifiers,
composer/file marked text, file draft and undo retention, and modal prompt
cancellation/retry. Removing the activation makes the targeted regression fail.
The final scoped gate passed all eight Stop/Changes shortcut tests, strict app
all-target Clippy, formatting and a native Linux build. This checkpoint did not
rerun a broad workspace/feature matrix. Native desktop evidence is recorded
separately; fake-platform composition checks do not establish OS IME behavior.

Fresh Linux desktop binary
`c109bb3ea72044aebe1446dfb9d846c79ecb5427aa425dc7a34e0a27413db869`
passed the focused native gate: Control-Shift-G opened the pane from the composer
without changing its draft, repeated activation retained the existing History
panel, and activation from an edited file preserved its buffer and undo when
returning. Quick Open and a dirty-file close prompt intercepted the command until
dismissal. The fixture used an isolated local repository without a connection,
credential or provider request. Screenshots and the QA observation record support
these Linux results; native macOS shortcut/OS IME behavior remains unvalidated.

## Sidebar Copy Session ID (2026-10-06)

`SidebarChatRow.menu`, `SessionReferenceActions` and
`WorkspaceContent.copySessionID` supply the added source action: a separator
following the implemented organization action, then **Copy Session ID** with the
number symbol. It copies the requested existing record's exact ID, including a
nonselected pending chat, without selecting/materializing it, saving a draft or
altering Pin state. A removed record leaves the clipboard unchanged and uses the
source's unavailable-chat error. Copy Session Reference remains absent because its
source trace/accounting lookup is not implemented.

Menu completion now carries a typed Pin/Copy action rather than a Boolean. Existing
request-token, project, window-generation and shutdown guards still control
application. The native AppKit selectors only record intent; the shared target is
retained by each menu item's represented object and clipboard work occurs after
native tracking ends. Anchor/window validation and nested-tracking protection are
unchanged. Linux uses the same separator/action through its existing GPUI popup,
with pointer selection and Up/Down/Enter/Escape routing.

Four new GPUI tests exercise nonselected marked-draft/focus preservation, no pending
materialization/catalog writes, stale/removed identities and modal cancellation,
keyboard selection, the actual rendered Copy row and the existing Pin path. A new
pure native-policy test verifies labels/symbols and invalid/Pin/Copy intent values;
existing callback-drop/window/anchor tests are retained. Mutating the copied target
to the selected chat or the Copy intent to Pin makes the focused regression fail.
Fourteen distinct focused copy/menu/Pin tests, strict app all-target Clippy,
formatting and the native Linux build pass; no broad workspace matrix was rerun.
Independent source review found no remaining blocker.

These Linux tests do not execute AppKit selector dispatch or native menu tracking;
exact-commit macOS compilation and native interaction remain separate gates.
GPUI's clipboard API returns no write status, so Swift's pasteboard-write-failure
error cannot be reproduced here. No new dependency, provider call or core storage
change is included.

Fresh Linux desktop binary
`601694148cf55ad62d751ddb2f244b4ba566ff054b69f5d58eff36d168a3cc5a`
passed actual clipboard checks through both mouse and keyboard menu activation.
Each copied the older nonselected chat's exact UUID, independently matched against
its saved catalog record; the selected newer chat had a different ID and remained
selected. Pinning the older target still worked without selecting it. Normal close
persisted both exact drafts, `old draft` and `new draft`. No file editing or
provider request was involved. The isolated QA observation record and screenshots support these Linux
results; native macOS menu dispatch remains an explicit unvalidated interaction.

## Sidebar-menu held Enter safety (2026-10-06)

Root-dispatch regressions reproduced a GPUI popup defect in both Pin and Copy
Session ID: Enter correctly chose the menu action, but subsequent held Enter
repeats reached the newly exposed composer and queued its draft. The root now
uses the existing consumed-key latch for menu confirmation too. An unrelated
fresh key does not reset that latch; a fresh press of the matching key clears it
before normal dispatch. KeyUp handling is unchanged.

Two configured loopback regressions cover Copy/Pin, interleaved Left, a
filter/composer focus roundtrip, repeated held Enter and KeyUp events, unchanged
draft/revision and no queued submission. A fresh Enter then intentionally queues
exactly one follow-up and clears the latch. Both regressions fail on the original
code, and reinstating the old any-key reset also makes them fail. The final eight
focused menu/clipboard/consumed-Enter tests pass, including the existing dirty-file
prompt case; strict app all-target Clippy, formatting and Linux build pass.
Independent review found no remaining scoped blocker.

This covers explicit GPUI held events and the popup route. Pinned GPUI 0.2.2 X11
reports physical repeat events as non-held, so real X11 autorepeat remains a known
platform limitation. No timing heuristic, GPUI fork, native AppKit repeat claim,
or broader workspace matrix is introduced.

## Bounded instruction discovery groundwork (2026-10-06)

The disconnected core `instructions` module ports the instruction-file portion of
`PiAgentCore/Resources.swift`: global override/AGENTS precedence, repository-root
to working-directory chains across distinct roots, shared ancestor de-duplication,
project fallback names, and explicitly supplied additional instruction paths.
It preserves the source's 32 KiB default / 256 KiB maximum aggregate preview
budget, 1 MiB per-file bound, UTF-8 byte-prefix behavior, full-source SHA256,
source metadata and truncation diagnostics. Nonblocking descriptor-based regular
file checks reject FIFOs/devices without reading them on Linux/macOS. Roots are
resolution context, not a sandbox; source symlink resolution is retained.

This module accepts explicit typed, already-resolved paths/settings. It does not
read environment variables or credentials, parse Codex configuration, discover
skills, build the complete resource prompt/revision, grant project trust, freeze
queued request configuration, or wire instructions into a provider request.
Those integration steps remain missing. A returned snapshot owns its strings;
subsequent file changes/discovery do not mutate it. No dependencies were added.

Blank-file precedence uses Foundation's whitespace/newline set, including U+200B
but excluding U+FEFF. As in Swift, the recorded canonical path is resolved after
the bounded read; concurrent symlink replacement can therefore change that path
between reading and metadata recording. This is not a sandbox/authorization
boundary or a transactional filesystem snapshot.

Ten focused Linux tests pass, covering discovery/metadata, UTF-8 budgeting,
Foundation blank precedence, nonrepository ancestry, file bounds and FIFO/device
rejection. Mutations reversing precedence, hashing previews instead of source
bytes, and restoring Rust-only whitespace each fail their regression. Focused
core library/test strict Clippy and formatting pass. Native macOS runtime
filesystem behavior is not claimed from these Linux tests.

## Opt-in read-only tool Controller (2026-10-06)

The core now supports an explicitly trusted, read-only `ls` request/tool/result
loop with ordered durable call/result checkpoints, bounded filesystem workers,
retained large output, full-batch steering, interrupted-result recovery and
preflight replay validation before invocation. Existing desktop constructors
remain tools-disabled; saved-project trust, tool-mode controls and truthful tool
cards are not wired. This is core integration, not completed desktop tool parity.
The complete contract and remaining source gaps are in
`read-only-tool-controller.md`.

The combined core checkpoint passed 205 tests before the final cancellation
classification correction; its final 14 affected tests, strict core all-target
Clippy and formatting pass. Four safety mutations were caught and restored.
Actual SSE fallback, queued/running read cancellation, unknown-result recovery
headroom and old-reader byte-preserving refusal are covered. Independent review
is clear. All model requests in these tests use synthetic loopback servers.

## Archive / Restore workflow (2026-10-06)

The single-project Rust sidebar gains source Archive/Restore menu actions,
active-before-archived grouping, and a footer switch for archived chats. Archived
chat content stays readable; its composer is replaced by “Archived · Read-only”
and Restore Chat. The retained editor/draft, queued input, history, pin and
organization order are preserved. Stop remains available. Restore only changes
metadata and never resumes a run or queued message automatically.

Pin/Archive/Restore share a per-chat FIFO. Menu activation resolves its explicit
desired state against the current record; a queued intent does not optimistically
change metadata. Existing admitted actor work reaches its owned completion before
Archive requests Stop and writes metadata. Stop is a request, not an awaited
provider acknowledgment, and a failed metadata write may already have stopped
work. Different chats remain independent. Notification-driven draining has no
retry polling timer.

A confirmed Archive of the still-selected chat falls back to the first active
chat in current sidebar order, ignoring the text filter; if none exists, the
archived chat remains open. Newer navigation wins. The Rust navigation fence also
preserves explicit file/pane navigation, a stronger safety policy than Swift’s
selected/focused-session/page revision. Explicit archived selection reveals and
saves the archive switch; launch-only reveal is transient. Startup honors a saved
archived selection, while an all-archived catalog without one creates a genuinely
new pending chat rather than reusing the launch session anchor.

Catalog version4 adds archived timestamps and independently revisioned archive
visibility. Versions1–3 open without rewrite, then promote monotonically on an
archive/visibility mutation; every existing writer preserves version4, including
queued-cancellation preparation. Previous readers reject version4 rather than
silently dropping archive state. Metadata-only writes retain newer stored titles,
drafts, pins, selection and submission/cancellation receipts. Idempotent operations
do not change timestamps or trigger another selection fallback.

The app blocks new run/queue mutations both at controls and method admission while
Archive is pending or confirmed. Swift has broad archived run/edit guards but
not every specialized queue helper repeats one; consistently blocking new queue
mutation here is an explicit safety interpretation of its read-only contract.
IME-deferred adoption keeps its token and text. Restore/load/composer notifications
do not retry an Archive-deferred cancellation actor operation; later explicit
user intent is required. Close names a reachable Restore-and-finish-composition
path instead of discarding a hidden deferred edit.

Post-rename catalog uncertainty leaves visible live drafts intact, does not guess
whether metadata committed, and blocks later actor admissions/queued organization
writes once observed. There is still no safe in-app uncertain-store recovery.
Core reopen validation establishes committed bytes, but forced restart cannot be
promised to preserve unsaved live drafts; no automatic retry/restart is suggested.

Focused core archive/version/rename-boundary tests and six storage mutations pass.
Final app Archive40, error-ownership3 and shutdown4 tests pass; source FIFO, late
callback, actual loopback Stop, Restore-no-resume and selected/inactive IME-deferred
Close paths are covered. Four app mutations fail their regressions and were
restored. Strict app all-target Clippy, formatting and Linux build pass. Independent
core/app review is clear. Native Linux desktop QA is recorded below; native macOS
menus, accessibility and IME acceptance are not established by these Linux tests.

Initial native Linux Archive QA confirmed active Stop/fallback, preserved Unicode
drafts/pin/queued input, read-only footer, Restore without another request, and
reopen/temporary visibility behavior. It caught a popup keyboard-focus defect
after footer Restore. The non-macOS popup now owns explicit focus; safe dismissal
restores only a still-visible, current-route descendant, otherwise a noneditable
root. Archived startup/selection and disappearance of the focused composer use
that root without stealing file/filter/modal focus. Native macOS handling is
unchanged. Eight sidebar tests and three held-Enter regressions pass; removing
popup focus or the fresh pane-state fence fails the new real-dispatch tests.
Strict app Clippy/build pass. The exact corrected native Linux focus retest passed.

The frozen focus-fixed Linux binary `f67092cc5411f0e36013e596925487b9740c7e3910f42354ce2b14b2e9d742c1`
passed footer Restore → context menu Down/Escape without a composer click.
Returning from a menu also restored explicit composer keyboard focus, verified
by selecting its unchanged draft. Normal Close preserved all three exact fixture
drafts, pin, selected chat and paused queue. The gated loopback gateway retained
only the original request and cancellation, proving Restore did not launch work.
This was an isolated synthetic fixture on the cloud Linux desktop; native macOS
AppKit, accessibility, IME and same-hardware performance remain separate gates.

CI exposed a root-focus interaction with the existing queue drag test: GPUI's
tracked focus handle automatically focuses its element on bubbling mouse-down.
The noneditable root is now a programmatic fallback only. Its bubbling handler
prevents that root default after child handlers have already run, preserving
editor focus and drag/click behavior. The existing drag assertion fails before
this correction and passes afterward. All24 affected drag/sidebar/Stop/held-key
checks and strict app all-target Clippy pass; native macOS code is unchanged.

### Permanent controller retirement and replacement ownership

Controller retirement now closes admission synchronously and joins every admitted
provider/tool worker before releasing the session writer lock. Old controller
references reject all mutations; a confirmed retired writer keeps its readable
snapshot while allowing a new controller to open the same path. Join failure
retains the lock, and uncertain storage remains uncertain. Ordinary shutdown
keeps its separate reusable behavior. Snapshot, lazy-load and deferred callbacks
must still match the current controller identity before changing a chat.

Six integrated retirement tests pass, including admitted-launch races, concurrent
and cancelled waiters, partial streaming/tool cancellation, failed joins, old
references and same-path replacement. Focused ordinary shutdown, cancellation,
queue and snapshot-generation checks passed during independent review; strict
core/app Clippy passes after integration. This supplies lifecycle boundaries for
future host configuration changes; it does not enable tools or a native vault.
