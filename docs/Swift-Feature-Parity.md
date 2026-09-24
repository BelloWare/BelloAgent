# Swift host parity and intentional differences

Updated 2026-09-19. Read [Implementation-Status.md](Implementation-Status.md)
for the current public release and versioned acceptance records. Earlier test
counts and release notes below are historical evidence, not fresh checks.

Since 0.1.38 the transcript and composers are native SwiftUI/AppKit, with the
self-contained Swift helper in `packages/swift-host`. React, WKWebView and Node
are no longer in the build. Pi `v0.85.1` remains a behavioral reference, not a
runtime dependency or a claim of complete upstream compatibility.

The [0.1.52 throughput/worker review](TPS-Workers-Review-2026-09-19.md) supersedes
older live-byte estimates and the serialized read-tool limitation. Read the
latest acceptance record for actual native, helper and distribution coverage.

| Area | Current implementation | Difference / obligation |
| --- | --- | --- |
| Durable recovery | Monotonic metadata revisions; quit save failures keep the app open; atomic handoffs; independent side recovery; queue checkpoint recovery preserves one delivered user message | Explicitly stale writes fail. Mutating command tombstones prevent replay after ledger eviction; a rare collision refuses conservatively. |
| Transcript recovery | Native transcript rendering and visibility determine read receipts; historical WebKit checks below are retired | Current native rendering and lifecycle checks are recorded in versioned acceptance, with large-history layout limits explicit. |
| Capture and accounting review | Known response credential echoes are masked across chunk boundaries with metadata disclosure; paired input/cache observations retain coverage; archive reads reuse the next maintenance deadline | Parsing receives original bytes. Existing historical captures are not rewritten. Finite archive limits and unverified billing provenance remain. |
| Agent loop | Complete assistant/tool turns, tool results, usage, cancellation | First-party subset, not line-for-line Pi or an identical system prompt. |
| Steering | Consumed after full current tool batch | Does not cancel the HTTP response or skip remaining tools. |
| Follow-ups | FIFO after agent would stop; remove/resume; durable pending data | Interrupted work pauses; no silent resend. |
| Context | Ring, inspector, preflight and compaction share the provider-built request count, with method, fingerprint, model, budget and warning provenance. Idle selection and draft changes debounce/cancel safely; counts cache by request/configuration and baseline evidence | A local heuristic or matching pinned-model usage-input baseline is still estimated. Previous output is not added wholesale. Tools, instructions, images and replay follow the actual request. No compatible remote counter/routing contract is enabled; see Context-Accounting.md. Captured HTTP remains separate. |
| Compaction | Complete-boundary summary and recent turns, native resume; composer strip shows progress and the latest successful summary from authoritative active context | Fast/background completion and historical baselines are independent of transcript scrollback. Failed/cancelled attempts cannot reuse an old success; abandoned branches cannot supply the notice. No recursive overflow recovery or automatic retry. |
| Streaming | Responses text/exposed reasoning/tool arguments, live shell output, jump-to-latest control, streaming caret and resize follow | New Messages dispatch is rejected; historical records remain readable. Opaque reasoning stays opaque and display batching is separate from byte capture. |
| Native tools | read/ls/find/grep use four bounded blocking worker threads per helper; write/edit/bash/MCP preserve project coordination | Exact edit, bounded UTF-8 reads/search; cooperative cancellation between filesystem/regex calls. Not all Pi options. |
| `/side` and `/fork` | `/side` + Enter immediately creates a durable child from the complete context boundary; closing preserves history, pending work and draft. `/fork` creates an independent session with the same completed context | No model call is needed to open either. Provider items, tools, compaction and branch selections survive; queues and identity are independent. Side tool policy is read-only, not OS filesystem isolation. Legacy ephemeral sides are saved when closed. |
| Multiple project roots | Primary-first trusted roots, native manager and matching host tool/resource resolution | Relative paths use the primary root or an unambiguous existing path under another root. Workspace changes guard affected active/loading/queued sessions; this is not OS filesystem isolation. |
| Project sidebar | All projects have independent persisted disclosure/archive filters; session rename, pin, archive/restore and child relationships persist | Organization revisions prevent late host/model writes from undoing edits. Orphaned historical project groups remain readable without restoring trust. Archive does not delete or interrupt work. Explicit deletion requires idle work and closed parent/child side panes. |
| Background accounting | Capture metadata invalidates session totals regardless of focus; all project groups retain cost caches and running rows keep the latest completed reported output TPS stable | Query generations reject stale reads and late final billing survives display eviction. Session consumption is separate from the context estimate. |
| Native window and copying | Native traffic lights keep reserved sidebar space; chat/report headers start at the window top without a blank full-width strip. Dragging, double-click zoom/restore and exact code/Markdown-section copy remain | Top safe-area handling belongs on the split detail child. UTF-16/stale-copy validation, native-control exclusions and focus/draft preservation remain. |
| Output budgets | Requested output budget is distinct from model catalog output ceiling, clamped to supported limits and propagated through chats, queues, sides, titles and preflight; safety margin is explicit | Catalog selection does not raise the requested budget to the theoretical maximum. Legacy per-chat catalog ceilings migrate once; old explicit profile budgets are preserved because their provenance is unknown. |
| Model and effort selection | Searchable native model popover plus effort actions; per-chat overrides and deliberate choices/limits remembered per connection for new chats across projects/restarts | Profile and Model default remain distinct. Incompatible effort resets on model selection; manual aliases remain explicit and are not injected into catalog rows. |
| Session timing | Latest completed retained request supplies chat TTFT/TPS; weighted session average TPS is shown alongside it, including narrow layouts; hover/click reveals up to 128 recent request samples | Whole-scope average uses output divided by summed valid dispatch-to-completion duration, with coverage. Own-session/project typed metrics only; missing values remain gaps. Pending work retains preceding completed values. |
| Legacy catalog repair | Older unbound routes surface different custom catalogs from later saved same-base/API records; one source offers Use this catalog and multiple sources offer a chooser. Explicit repair loads immediately and persists across restart | The original fresh-save alias/catalog flow already inherits lineage. Suggestions ignore profileChoice, respect explicit bindings and never silently retarget the request connection, credentials, selected model or effort. Independent catalogs remain separate until chosen. |
| Model catalog | Composer, Settings and onboarding default to the bundled six-model Bello catalog, including upgraded profiles with nil/blank URLs. Explicit Refresh reloads the same saved connection before fetching, shared by Chat and Settings; open pickers observe revised metadata. Rich metadata, ordering and deprecation are preserved; explicit custom URLs replace the bundle | No implicit gateway discovery or credential read for the bundled list. Custom catalogs retain one-hour caching, same-source last-good-list errors and cancellation guards; no bundle/gateway fallback on failure. Same-origin keys and anonymous external catalogs remain. Listing does not verify gateway support. |
| Skills | Codex/shared locations, explicit-only policy, chips/hashes/dependencies; per-skill Bello-only disabling across projects | Shared files and Codex settings are unchanged. Disabling removes unsent selections and blocks future/queued execution; already running requests retain frozen inputs. Re-enabling does not override source/project restrictions. Conservative metadata subset; no executable Pi extension ecosystem. |
| Instructions | Global/project precedence, fallbacks and byte budget | No unbounded descendant preload or import of Codex approval/auth/sandbox policy. |
| Gateway fallbacks | `disable_fallbacks: true` on every request unless Allow fallback models is explicitly enabled | A failing route surfaces its error by default; a gateway's fallback behavior is not inferred from its reported identity. |
| Settings and connection tests | One Save action closes only on success. Preferences-only saves preserve untouched active and legacy connections; changed invalid fields remain available for correction. Test Connection saves first and uses its own persisted No project chat | No project is required. Scratch chats retain their native composer and disabled tools; sides/edit promotion cannot add tools. Submission uses the test chat identity even after selection changes. Onboarding retains its separate bounded no-chat probe. |
| Responses | The only active request API; HTTP/SSE, function-call rounds and opaque item preservation | No WebSockets, subscription adapter or Chat Completions fallback. Saved Messages connections require explicit conversion into a separate Responses connection. |
| Historical Messages | Saved connections/keys, journals, captures and provider metadata remain readable | Earlier two-API tests are historical evidence. New Messages requests are rejected; do not silently rewrite their URLs, credentials or history. |
| Debugging | Exact retained HTTP bodies and metadata; valid JSON and combined Responses default to expandable formatting with separate Events/raw views; both inspectors load all retained bytes without manual pagination | Formatting never rewrites capture/export bytes. Raw text/hex, credential masking, plaintext 30-day defaults, legacy encrypted reads and partial/expired/omitted states remain. Full-text body search stays deferred. |
| MCP | One tool with list, batched describe, singular serial invoke; stdio/HTTP and inspector | Tools subset only; no OAuth, sampling, elicitation or resource UI. |
| MCP unknown outcome | Durable pre-dispatch marker, human-only acknowledgement | Does not make remote mutation exactly once, retry it or undo effects. |
| Credentials | One ordinary macOS Keychain item; scoped private IPC; no external credential authorities | Clipboard's profile-free Developer ID signing now works. Signed synthetic owner/update acceptance completed 51 checks and observations without failures; raw same-user writes remain possible, so write/delete isolation is not promised. No plaintext fallback or signing-key ACL change. |
| Failure presentation | HTTP, stream and agent failures show Error with visible sanitized detail, retained across history reload; Stop remains cancellation/paused | Pending queues remain separately paused and require explicit resume; clearing an item or reopening cannot silently hide the failure or retry it. |
| Tool disclosure and Stop | Tool calls/results start collapsed and retain manual toggles during updates; Stop sits inside main/side chat inputs, with a lower task footer for input-free title jobs | Status remains visible while collapsed; body details require expansion. Existing session-scoped cancellation remains. |
| Native sessions | Locked native JSONL plus opaque provider items; atomic edit branch/replacement queue recovery and retained summaries | Restart leaves accepted edits paused. Offline visible history follows branches; displaced composer drafts survive edit/cancel/restart. Pi CLI must not write these files. Old SDK sessions are read-only/portable-draft only. |
| Extensions | Excluded | Port selected behavior as ordinary native features. |
| Distribution | 0.1.19/build 23 is publicly released; source `9b94e4d`, website `d37b885`, 7,288,456 bytes (6.95 MiB). Signing/notarization, packaged smoke and public artifact checks pass | Install/update rehearsals were skipped. Preserve identity, Keychain, history, Sparkle key and selected icon. |
| Report page | In-window report with collapsed filters/details, visible active chips, responsive layouts and requested/final models together in a horizontally scrollable request table | Native composer/WKWebView identity, focus, undo, selection and drafts survive navigation; hidden sends are guarded. Re-entry refreshes data while preserving choices; canceled/obsolete queries cannot replace newer results. Applied labels remain tied to displayed data while filters are pending. |
| Dashboard | Durable native metrics, Charts time series, time presets/live filters/cache ratio and paged request drill-down | Exact nearest-rank p50/p99, null/sample/status/identity accounting and filter behavior have native coverage. Summaries follow selected status; brush/paging races are covered and body purge/restart preserve metrics. Chart drag interaction remains unverified by CUA. |
| LiteLLM auto-router | Requested alias retained, bounded sourced identity, explicit portable/fixed-route native-state replay | Gateway-reported model/provenance/unknown/conflict states implemented, with every conflicting name retained and expandable in request details; deployment contract verification remains external. |
| LiteLLM cost/cache/reasoning | Per-message/session/report cost and token accounting, cache-write tokens, reasoning tokens and reported reasoning cost, with sample coverage | Reasoning is a subset of output, never an extra total. Final JSON headers can supply cost when body cost is null; provisional streaming headers cannot. No local price estimates or inferred zero. Response-cache state is distinct from provider prompt-cache tokens; see the pinned accounting contract. |
| Inline request attribution | One inline accounting owner per attempt, moving from user input to assistant response. The status line shows one literal response-body model with other body/header reports on click | Body aliases are not verified upstream identity. Unknown/conflicting/incomplete identity stays in details; raw evidence never enters the transcript bridge. User Details and compaction attribution remain. |
| Status bar Activity / Usage | Usage opens first with time scopes, historical output TPS and requested/resolved models. Activity shows only running work; byte-derived live output estimates have been removed | Historical rates use reported output divided by summed valid dispatch-to-completion duration, with completed-sample coverage. Reasoning is included once, and first-content timing is not required. Unread/waiting/paused rows are omitted from this panel. Physical menu clicks remain outside CUA coverage. |
| Session distributions and titles | Resizable native usage windows show tokens/cache/TPS and group requested/resolved models and reported costs; scope persists across chat changes. Separate selected/catalog-recommended mini model generates titles in retained background sessions | Whole-scope shares and null coverage stay truthful. Title tasks have fixed labels, independent capture/cost, no tools/resources, manual-rename protection and durable no-retry claims; hidden until revealed. No mini choice means no auxiliary model call. |
| First-launch setup | Persistent setup, retry-safe identity, trusted workspace and a real selected-model Test & Start request through the packaged helper/scoped vault/capture path | Probe has no tools/history/resources, output ≤256, cancellation and timeout. Empty/error/stale/cancelled results cannot finish setup; no probe chat/journal is created. Discovery alone is not connection verification. |
| Unread replies | Durable unread state baselines old history, reconciles offline journals and survives restart; the sidebar shows a dot rather than a count; explicit Mark as Read remains | Only the latest completed reply visibly painted in a foreground chat clears automatically. Status-panel unread rows are omitted. Background/report/scrollback and stale receipts cannot clear newer output. Existing CUA limits remain. |
| Request-aware gateway tests | Current Responses requests and selected-model probes are validated before replies, including negative probes, exact bytes and no probe session pollution | Historical Messages coverage stays recorded separately. Tool-result/compaction/cache behavior depends on requests. These are independent local mocks, not installed LiteLLM or deployed-gateway acceptance. |

## Deviations from pi 0.85.1: side chats and skill selection

Pi has no side chats, and its fork starts a new session id. Our sides follow
Codex CLI's `/side` and Claude Code instead, so a side's first request reuses
its parent's prompt cache:

- **Tools.** A side sends its parent's exact tool list, which has write, edit
  and bash when the parent can edit. The side stays read-only when a call
  runs: write, edit and bash return an error that nothing ran, and point to
  the main chat or to `/fork` plus Enable Editing Tools. A chat that is
  read-only itself keeps pi's rule and offers only the read-only tools.
- **Cache key.** A side's `prompt_cache_key` and pi's `session_id` and
  `x-client-request-id` headers name its parent's cache, for open and kept
  sides but not forks. `x-session-id`, `metadata.session_id`, the attempt log
  and the spend stay the side's own.
- **Hidden note.** The side's first message carries a note, sent just before it
  as a user message of its own (never developer or system, which LiteLLM moves
  into Claude's system prompt): this is a read-only side conversation branched
  from the one above. No transcript shows it, and it stays in the context so
  every later request keeps the same prefix. It is journaled on the message
  (`nativeContextNote`), not as a row. A chat that holds the note and has its
  editing tools on gets a second note saying so.
- **Skill selection.** The system prompt no longer lists the turn's selected
  skill IDs, so it is byte-identical on every request of a chat. It keeps one
  fixed sentence: only the latest user message's own selection authorizes an
  explicit-only skill. A message that selects skills carries
  `Current explicit selection IDs: …` after their skill blocks; a message that
  selects none is its text alone, as pi sends it.

Shared native payload storage and acknowledged byte delivery preserve actual
HTTP request/response bodies separately from normalized events. Current tests
compare Responses capture against independent loopback bytes, including the
onboarding probe. New chunks are plaintext; legacy encrypted history is retained.
Authentication headers retain masked values (at most the final four characters of a sufficiently long token); response credential echoes and cookies are fully masked. Known credentials inside request bodies are hashed with explicit transformations/omissions;
omitted bodies are unavailable, never empty originals. Request/message/compaction
links survive body expiry and active exports protect shared chunks. HTTP-body
full-text search remains deferred.

Current 0.1.19 verification:

Version 0.1.19 completes a deeper review of Claude's recent changes and the
Settings-to-existing-chat catalog flow. It fixes clock-correction write loss,
quit and side recovery failures, non-atomic handoffs, false transcript paint/read
acknowledgements, command replay after ledger eviction and duplicated queued
messages after a partial journal commit. Response capture masks known credential
echoes across streaming boundaries and labels that transformation. Archive
maintenance avoids repeated whole-store sweeps; partial cache observations keep
paired sample coverage. Existing catalog lineage and explicit repair remain.
Unavailable live-export bodies cannot be misrepresented as empty captured files.
See the [review and remaining limits](Deep-Review-2026-09-17.md).

**394 unique native cases and 140 unique helper cases have a final
pass; 6 optional visual/interactive native captures were skipped.** The broad
native run had one failing case (two assertions); its corrected expectation and
affected behavior passed the 54-case focused rerun; the final nine-case export
and release-configuration check passed. The helper's full 138-case
suite passed, followed by 12 focused queue/recovery cases, including two new
regressions reproduced before the fix. Repeated cases are counted once.
**29 transcript tests, TypeScript checking and 10 dependency-cache tests pass.**
Four native tests exercise the packaged React page in WKWebView, including
render rejection and recovery. Local HTTP/SSE fixtures validate requests, tools,
cancellation, compaction and capture; no deployed LiteLLM was used. No full
screenshot gallery or Release performance matrix was run. Installation/update
rehearsals were skipped by owner instruction.

Historical 0.1.18 verification:

Version 0.1.18 makes stale catalog sources visible in older unbound chats.
The model picker offers a direct Use this catalog action for one later saved
custom list on the same gateway, or a chooser for multiple alternatives. The
selected source loads immediately and persists across restart. Repair preserves
the request connection, credentials, selected model, reasoning effort, output
budget and history. Explicit source bindings remain authoritative.

**67 focused native tests passed**, with 0 skips and
zero unresolved failures. Counts come from the actual test log, with repeated
cases counted once. Coverage includes the original save/inherit flow, legacy
repair and restart, distinct/multiple sources, explicit-binding preservation,
refresh source routing and the mounted picker's visible banner/replacement rows.
The mounted-view check invokes the action shared by the button; it does not
claim a physical mouse click. Unchanged helper/context/capture and transcript/
TypeScript evidence is reused from 0.1.17 and its referenced earlier records.
No live deployed gateway or full screenshot gallery was run. Installation/update
rehearsals were skipped by owner instruction.

The originally reported fresh-save alias/catalog flow was already handled
by inheritCatalog and covered by an integration test. The remaining gap was
older records without catalog lineage: Refresh correctly reloaded their old
source but gave no prominent repair path. Suggestions now use later saved
same-base/API records with a different custom URL, independently of profileChoice.
No independent connections are silently merged. See the
[issue resolution](Issue-Stale-Chat-Model-Catalog.md).

Historical 0.1.17 verification:

Version 0.1.17 uses one request-aware context count for the ring, inspector,
preflight and compaction. It counts the actual provider-built instructions,
tools and replayed input. Gateway-reported input is reused only for a matching
prefix and an explicitly pinned, reported model; previous output is not added
wholesale. Counts carry method, request fingerprint, model and uncertainty.
Safe idle tabs and draft edits refresh through a shared debounce/cache; pending
counts do not display stale conversation totals. Output budgets are separate
from catalog model ceilings, with a distinct safety margin. Reported usage,
request context and estimated live output activity remain separate measurements.

**129 unique native tests and 132 unique helper tests have a final
observed pass.** Initial broad runs did not pass: one native case and three
helper cases failed. The corrected focused reruns passed (36 native, seven
capacity and 11 request-context cases), followed by 21 passing final helper
context/gateway/capacity cases. Every initial failing case has a later pass;
repeated executions are counted once. Coverage includes debounced/stale context,
output-budget migration, replay/baseline invalidation, image uncertainty and a
request-validating loopback gateway with exact request/response capture.
The unchanged transcript/WebKit/TypeScript evidence is reused from 0.1.16.
No live deployed gateway, remote token counter, screenshot gallery or physical
UI interaction is claimed. Installation/update rehearsals were skipped by owner
instruction.

These remain estimates, not exact tokenizer results or independently
verified billing usage. No remote counting endpoint is enabled: the reviewed
LiteLLM interfaces do not establish complete Responses request compatibility
and a route-bound counted model. Automatic routing and opaque/image costs retain
explicit uncertainty. See [Context-Accounting.md](Context-Accounting.md).

Historical 0.1.16 verification:

Version 0.1.16 keeps tool calls and results collapsed until their disclosure
is opened, including running tools; manual expansion survives streaming updates.
Chat timing shows the latest completed request's TPS and the weighted session
average together, including narrow layouts, with history and coverage on hover.
Failed responses show Error with a visible, retained, credential-sanitized message;
paused/cancelled work stays distinct and pending messages never retry implicitly.
Stop now sits in the chat input for main and side conversations. Background title
jobs, which have no input, keep Stop in their lower task footer.

**74 unique focused native tests passed**, with
1 optional capture skip and zero failures. The initial native run executed
75 cases (74 passed, one skipped); the final Stop run rebuilt the app and repeated
five follow-up cases. Repeated cases are counted once. **115 unique helper tests,
27 transcript tests and 9 WebKit disclosure checks passed**; TypeScript passed.
Loopback HTTP 429/SSE failure fixtures verify useful errors, credential masking,
no automatic retry and exact captured bytes. Native coverage includes retained
errors, weighted timing and actual wide/narrow footer rendering with OCR.
No manual Stop click, screenshot gallery or full interactive gateway run is claimed.
Installation/update rehearsals were skipped by owner instruction.

Historical 0.1.15 verification:

Version 0.1.15 fixes New Project losing its primary folder immediately after
selection. The form now reads live draft state and publishes the primary/extra
folder change atomically. Changing the primary preserves unrelated extra
folders; an outgoing cancelled pane cannot reopen its draft. Additional projects
can be created after onboarding without replacing the first project.

**27 focused native tests passed with zero failures in 0.714 seconds**:
Workspace 17, ProjectSidebar 6 and ReleaseConfiguration 4. Three new regressions
cover live folder-selection state, cancellation/reopening and second-project
persistence with a fresh vault readback. These are state/integration checks;
physical NSOpenPanel interaction was not exercised. Unchanged context/catalog,
provider/transcript/capture evidence is reused from 0.1.14 and earlier records.
Installation/update rehearsals were skipped by owner instruction.

Historical 0.1.14 verification:

Version 0.1.14 calculates prepared context automatically when a safe idle
chat opens, using the local helper without sending a model request or executing
tools. Matching estimates are reused; cancelled or changed inputs cannot publish
stale results. Unsent chats retain their allocated journal across helper eviction.

Catalog lists now resolve independently of preserved request connections.
New same-authority default-model forks keep catalog linkage; older chats can
choose a saved custom catalog through **Catalog source…** in the model picker.
Refresh reloads saved bindings, requests HTTP revalidation and displays its
successful update time. Changing the list preserves the chat's request route,
credentials, selected model and effort. Legacy lookalike connections are not
automatically merged because their records contain no reliable lineage.

**98 unique focused native tests passed with zero failures.** The catalog/
configuration run passed 71 cases in 9.523 seconds; the final context/workspace
run passed 34 cases in 2.144 seconds, including seven repeated catalog-source
cases with strengthened credential assertions. Counts are not added twice.
The packaged-helper fixture verifies automatic calculation, no model request,
no message/queue changes, durable unsent journal paths and unchanged bytes after
helper reopening. Local catalogs verify refresh, metadata and credential scope.
Unchanged provider/transcript/capture evidence is reused from 0.1.13 and earlier
records. Installation/update rehearsals were skipped; the owner will test on
their own MacBook.

Historical 0.1.13 verification:

Version 0.1.13 fixes chat catalog Refresh by reloading the saved connection
before fetching, using the same path as Settings. Chat TTFT and TPS show the
same latest completed request and retain it while a new request runs. Hover
shows native history charts; clicking keeps them open. Charts cover up to 128
recent completed requests in that session/project, with gaps for missing
measurements. Usage-window/menu-bar historical averages remain independent.

**108 focused native tests passed with zero failures in 13.773 seconds**:
GatewayAccounting 19, LiveAccounting 5, MenuBarMetrics 21, ModelCatalogEndpoint
19, ModelSwitch 15, ReleaseConfiguration 4, SessionTiming 9, SessionUsage 10,
SettingsSave 6.
Synthetic native fixtures cover picker rendering and timing charts. The release
record preserves the corrected Swift test-helper isolation error and explains
why an inactive-window mouse harness does not establish a physical click or
end-to-end hover test. Unchanged helper/provider, transcript and capture evidence
is reused from 0.1.12. No installation/update rehearsal was run.

Historical 0.1.12 verification:

Version 0.1.12 adds Combined JSON for Responses streams, retaining the terminal
response object or an explicitly partial reconstruction. Events, UTF-8/hex,
original-byte exports and capture-state labels remain. Session usage opens in
reusable resizable native windows with tokens, response/prompt caching, reported
and reasoning cost, historical TPS and model/cost distributions. Windows retain
their session scope across chat changes and stop reads when closed.

**89 focused native tests passed with zero failures in 4.716 seconds**:
CapturedBody 14, CombinedResponse 21, MenuBarMetrics 21, MessageDetail 9,
SessionUsage 10 and Workspace 14. Five synthetic own-window views were inspected.
Helper/provider, transcript, catalog and storage evidence is reused from 0.1.11
and earlier records because those sources are unchanged. No deployed gateway,
full gallery, installation/update or signed owner/update rehearsal was run.

Historical 0.1.11 verification:

Version 0.1.11 simplifies reply footers to one response-body model, with
header/body evidence on click. Captured SSE responses now open as expandable
JSON event trees with original framing and bytes preserved. Calculated context
previews update the footer, with stale-input/activity/reopen guards; unloaded
context offers “Inspect context” without an automatic model request.

**103 unique focused native cases pass** after correcting two optional
screenshot readiness checks. The final 21-case viewer/context rerun passed in
1.248 seconds; helper ContextPreview 4 passed in 0.085 seconds, transcript 25
passed and TypeScript passed. Two synthetic own-window JPEGs were inspected.
The 100k-attempt Debug accounting fixture preserved attribution and coverage
(101-message page 605.350 ms; session-only 68.847 ms; one message 65.396 ms).
See the release record for individual suites and the original failures.
Unchanged catalog/onboarding/title and broader evidence is reused from 0.1.10
and earlier records; it was not rerun. No full gallery, deployed LiteLLM,
install/update/relaunch or signed owner/update rehearsal was performed.

Historical 0.1.10 verification:

Version 0.1.9 honored a model catalog only when a custom URL was saved; the
repository's catalog file was not packaged in the app. Version 0.1.10 fixes that
missed default path: nil, empty and whitespace catalog settings now load the
bundled six-model Bello catalog without requesting gateway models or reading an
API key. Existing selected aliases, reasoning efforts and per-connection defaults
are preserved. Explicit custom catalogs remain authoritative, with no fallback
to either the bundle or gateway after a custom-source failure.

**60 focused native tests passed, zero failures, in 6.899 seconds.**

| Native suite | Passed | Seconds |
| --- | ---: | ---: |
| ModelCatalogEndpoint | 18 | 5.365 |
| ModelSwitch | 11 | 0.243 |
| Onboarding | 18 | 0.684 |
| SettingsSave | 6 | 0.169 |
| TitleGeneration | 7 | 0.439 |

Checks read the actual application-bundle catalog and assert all six aliases,
context/output limits and reasoning choices. Legacy/blank defaults require no
gateway traffic or credential lookup; explicit catalogs retain source isolation,
credential-origin checks, caching and cancellation guards. Remembered choices,
Settings saves, onboarding probes and title-session isolation remain covered.

Three synthetic own-window picker JPEGs were visually inspected, with OCR
assertions for the default, custom-catalog and error views. No unrelated
application content is captured.
The unchanged helper, transcript, capture/accounting, chrome, broader native and
Keychain evidence is reused explicitly from the [0.1.9 record](validation/Bello-Agent-0.1.9-2026-09-16.md)
and its linked historical records. Those are not additional tests run for 0.1.10.
No full gallery, deployed LiteLLM, fresh-install, Sparkle update/relaunch or signed
owner/update rehearsal was run. Log: `catalog-default-fix/native.log` in session scratch.

Historical 0.1.9 verification:

**155 unique focused native tests pass after corrections and focused reruns.**
The first broad selected run executed 155 tests in 19.717 seconds with four
failed assertions across two cases: catalog-render inspection and a 28-point
native safe-area inset. The layout fix applies top safe-area handling to the
split child; the final WindowPresentation/ReportNavigation rerun passes.
The eight WindowPresentation/ReportNavigation cases pass in native-ui-rerun.log. That 22-case run also included the catalog check, which was corrected and passed in its separate final 14-case rerun; repeated cases are not added to the unique total.
ModelCatalogEndpoint's 14 cases pass in 4.124 seconds in native-picker-final.log. The fixture's inaccessible test-process accessibility tree was replaced with local Vision OCR over actual rendered window pixels, checking catalog names/aliases, wrong-source exclusion, source-change errors and removal of stale choices. Both picker JPEGs were inspected.

Helper title/session/context checks: **17 passed in 0.494 seconds**. Transcript:
**24 passed in 0.811 seconds**; TypeScript passes. Capture coverage includes
CapturedBody 9, MessageDetail 7 and PayloadArchive 13. TitleGeneration 7 includes
an actual packaged-helper loopback request checking the chosen mini model,
512-token output cap, disabled tools, isolated instructions, one dispatch,
durable title session and separate capture/cost accounting.

The 100,000-attempt/300,100-link Debug fixture preserves attribution and
coverage: a 101-message page took **555.924 ms**, session-only **56.682 ms**, and
a single-message query **59.201 ms**. These are local database timings, not
input-to-paint measurements or the full Release performance budget.

Eleven synthetic JPEGs were inspected: five session/menu usage views, three window-chrome views, expandable JSON, and two model-picker views. They show only isolated fixture windows, not unrelated applications.
Unchanged broader provider/wire/process, Python, native/gallery and ordinary
Keychain evidence is reused from versioned records. No full gallery, deployed
LiteLLM test, production gateway credentials, install/update or signed owner/update
rehearsal was used.

Historical 0.1.8 verification: **eight unique focused native tests passed**
(WindowPresentation 5, ReportNavigation 3). The window suite passed again after
optional screenshot-readiness changes. Three inspected light/dark/compact
synthetic views show the custom row above content. The real SwiftUI WindowGroup
is exercised after layout and resize; native controls, zoom/restore, focus,
drafts and retained report/chat surfaces remain covered. No new full gallery,
provider, performance or install/update acceptance is claimed.

Historical 0.1.7 verification: **81 unique focused native tests passed** across
GatewayModelDiscovery (9), ModelCatalogEndpoint (12), ProjectSidebar (6),
Workspace (14), ModelSwitch (11), Dashboard (14) and MenuBarMetrics (15).
The restart fixture initially held its previous archive lock; explicitly closing
that archive fixes the fixture while retaining all original assertions. No new
full/gallery/interactive/reveal-gesture or install/update rehearsal was run.
Unchanged helper/wire/transcript and broader UI evidence below is reused.

Historical 0.1.6 verification: **247 native tests executed = 246 passed + one
interactive opt-in skip**, zero failures in **91.525 seconds**. This includes the
gallery/onboarding test (**75.464 seconds**, 30 light/dark captures). Helper:
**105 passed in 5.179 seconds**; optimized wire **24 in 5.339 seconds**;
process/MCP **two in 2.599 seconds**; Python **52 in 17.046 seconds**;
transcript **21 passed in 0.933 seconds**, TypeScript passed. The isolated signed
Keychain owner/update suite repeated all **51 checks/observations** successfully.
Four Settings and five native follow-up tests cover the reviewed regressions;
helper tests cover successful/failed/cancelled/abandoned compaction summaries.
No new full interactive gateway run is claimed for 0.1.6.

Historical 0.1.5 verification: **236 native tests executed = 235 passed + one
interactive opt-in skip**, zero failures in **91.136 seconds**. This includes the
gallery/onboarding test (**75.587 seconds**, 30 light/dark captures). Helper:
**101 passed in 4.905 seconds**; optimized wire **24 in 5.160 seconds**;
process/MCP **two in 2.576 seconds**; Python **52 in 16.967 seconds**;
transcript **21 passed**, TypeScript passed. The final run includes updater edit-draft preservation and both new composer
reentrancy/focus regressions.

The historical 0.1.5 CUA test passed in **670.249 seconds**: **eight requests, sixteen
independently matched bodies, 1,290 tokens and $0.0101375**. It covers background
billing/unread state, exact code/Markdown copying, context exploration and direct
masked-header/body inspection, project grouping, rename/pin/archive/restore,
empty `/side`, retained child drafts, `/fork`, Bello-only skill disabling,
status scopes/report/main-window recovery and actual title-bar double-click
zoom/restore. No preview/side/fork operation sent a model request.

Fixtures use synthetic vaults and loopback gateways, not deployed LiteLLM.
Successful foreground unread clearing, physical status-item clicks, chart
dragging, real-language IME and the full Release performance budget remain
outside the claimed interactive scope. Native tests cover visibility and both
button event masks. Historical Debug target misses remain in the 0.1.3 record.
The ordinary Keychain policy is unchanged, including its same-user write/delete
limits. The historical 0.1.5 record contains signing/public evidence and its
actual update: all 75 installed files/links matched; history and Keychain
revision 0 remained intact. The historical 0.1.6 record separately confirms completed
signing/public/update checks: all 75 installed files/links match; five chats,
five drafts and five journals remain. Ten of eleven retained state records
and all journal bytes are unchanged; one empty draft differs only in JSON key
order, with its original hash reproduced from the unchanged values.

## Source reference points

- Pi loop: https://github.com/earendil-works/pi/blob/v0.85.1/packages/agent/src/agent-loop.ts
- Pi license: https://github.com/earendil-works/pi/blob/v0.85.1/LICENSE
- Responses streaming: https://developers.openai.com/api/docs/guides/streaming-responses
- Responses reasoning: https://developers.openai.com/api/docs/guides/reasoning
- Messages streaming: https://platform.claude.com/docs/en/build-with-claude/streaming
- Codex skills: https://developers.openai.com/codex/skills
- Codex instructions: https://developers.openai.com/codex/guides/agents-md
- MCP transports/tools: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports and https://modelcontextprotocol.io/specification/2025-11-25/server/tools

These are reference locations, not a guarantee that a moving upstream document matches the installed gateway or pinned implementation. Pin fixtures/version assumptions and preserve NOTICE for borrowed behavior/source. Do not use selective parity as evidence that the Mac app passed UI tests.
