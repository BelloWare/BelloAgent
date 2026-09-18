# Pi App — Features and Product Requirements

Status: implementation handoff, not an implemented-feature claim.  
Updated: 2026-09-14.  
Read this first, then [Design.md](Design.md).

## 1. Product and fixed architecture

Build a long-lived, responsive macOS desktop client for the existing Pi coding agent. Pi owns the agent loop, model calls, tools, authoritative conversation state, and compaction. The app owns native interaction, presentation, Codex compatibility, side conversations, and request observability.

The owner selected **SwiftUI/AppKit for the native application and composers, React/TypeScript inside WKWebView for conversation rendering, and a supervised TypeScript/Node Pi SDK host**. Do not substitute Electron, Tauri, an embedded terminal, or a newly implemented agent harness without an explicit architecture decision.

All owner-requested features are required for v1: context usage; streaming; `/side` UX; Codex skills including `/a-skill-here` and explicit-only invocation; Codex `AGENTS.md`; tokens/second; time to first token; OpenAI Responses API; Anthropic Messages API; and an in-app current-session inspector of actual LLM requests/responses. Milestones sequence these requirements; they do not remove them from v1.

This file defines observable behavior; Design.md defines implementation contracts. Update both when changing a decision. Numeric limits below are proposed engineering defaults, not measured performance or claims about Pi.

## 2. Scope and product defaults

V1 is local, single-user, and Mac-first. Proposed baseline: Apple Silicon, macOS 14+, signed/notarized direct distribution. The application bundles a compatible Node runtime and Pi; neither a global Node installation nor an installed Pi CLI is required. Intel, App Store distribution, cloud agents, remote synchronization, and a new plugin marketplace are out of scope.

Owner addition (2026-09-14): first release a native dummy app with signed Sparkle
updates through belloware.com, then publish a second version and verify the
installed upgrade before M0. Updates must wait for active hosts to become idle.
These dummy versions do not constitute M0 or implemented agent features.

Reuse existing Pi provider/model configuration. Never silently rewrite `~/.pi`, `~/.codex`, skills, or repository instructions. New application settings are separate overlays with visible provenance.

Layout: native session/workspace sidebar, toolbar and model picker; web transcript; native multiline composer; native context/performance footer; optional right-hand side conversation. Debugging uses a native inspector or detachable window, not browser developer tools.

## 3. F01 — Native workspace, composer, and sessions

Select a working directory, create/reopen/rename a chat, and switch sessions without losing drafts. Display workspace, effective profile, API, and run status. Do not retain one agent process or webview per historical chat.

Main and side composers support native undo, selection, multiline editing, IME composition, slash completion, keyboard navigation, and attachments supported by the selected model. Enter sends and Shift+Enter inserts a newline; Enter must not send during IME composition. Follow system appearance and accessibility settings. Core actions are discoverable in native menus.

During a run, ordinary Send means **Queue follow-up**; **Steer current run** is separate and explicit. Show queued submissions and allow removal. Stop pauses automatic queue draining; it must not immediately start the next queued turn.

Pi sessions are authoritative. Imported CLI sessions open read-only; continuing creates an app-managed Pi-format copy with provenance. Do not let the CLI and app append to the same original file. A saved chat can have several UI viewers but only one host writer. Session deletion must also address retained traces and side descendants explicitly.

Acceptance: native typing and selection remain responsive during main/side streaming; changing views preserves drafts and scroll anchors; stopping one session never stops another.

## 4. F02 — OpenAI Responses and Anthropic Messages

| UI API | Pi identifier | Normal HTTP route |
| --- | --- | --- |
| OpenAI Responses | `openai-responses` | POST `/v1/responses` |
| Anthropic Messages | `anthropic-messages` | POST `/v1/messages` |

Use Pi's corresponding provider adapter. Do not silently substitute Chat Completions or implement one API by translating all requests through the other. Pi's inspected source exposes both adapters [P1].

Support API-key authentication against direct providers and configurable compatible endpoints, including LiteLLM. Distinguish profiles by provider, endpoint, API, and model: the same alias can exist on both APIs. Preserve imported context/output limits, thinking defaults, custom headers, and supported compatibility options. Do not hardcode a 1M window, output budget, or reasoning effort for every model.

The inspector shows effective configuration and its origin. A router alias is not proof of a particular upstream model; show upstream identity only when reported. Expose API selection independently of the friendly model label. Resolve the endpoint exactly once and test against doubled `/v1` or `/messages/messages` paths.

Test connection is an explicit action that discloses possible charges and produces an inspectable request. Configuration discovery does not generate an LLM response. New app-managed secrets use Keychain; existing Pi credential references remain supported. Never import Codex authentication merely because Codex instructions are enabled.

Apply profile changes only at idle. Missing saved profiles must not silently select a different provider. Incompatible cross-API/endpoint reasoning state requires a new session or explicit portable-context handoff, preserving the original and disclosing omitted opaque state. Do not replay encrypted/signature-bearing provider state into an incompatible route.

V1 transport is HTTP streaming/SSE. WebSocket Responses transport and subscription-specific Codex adapters are not implied. Non-streaming JSON success/error bodies must still be observable and handled by the adapter where supported.

Acceptance on both APIs: streamed text, thinking where exposed, tools and tool results across subsequent model calls, cancellation, failure, usage, compaction, save/resume, and exact-body debugging. Verify Messages `max_tokens` in the serialized request, not merely the presence of a similarly named UI setting.

## 5. F03 — Streaming presentation

Stream assistant Markdown, code, exposed reasoning/summaries, tool-call arguments, tool output, and lifecycle status. Reasoning is collapsible; signatures and encrypted state are opaque payload data, not readable reasoning.

Tool cards show preparing/running/completed/failed/cancelled states, stable identity, input, duration, and bounded output previews. Execution begins only after a complete validated call. UI truncation is labeled and must not truncate the tool result that Pi itself receives. Expand large retained output on demand.

Retries, compaction, waits, cancellations, and interruptions are visible states, not indefinite spinners. Auto-scroll only while the user follows the bottom. Keep completed messages stable. Handle updates that replace snapshots differently from append-only deltas. Never rebuild Pi history from rendered text.

Acceptance: split Unicode, partial Markdown fences, interleaved calls, large output, unknown normalized events, and mid-stream disconnects do not duplicate/lose text or corrupt scrolling. Unknown raw provider events remain inspectable even when not displayed in the transcript.

Search and Copy Conversation reads the full retained branch independently of the
display page. Search returns at most 100 matches per page; Copy Conversation and
explicit message ranges use 16 Ki UTF-16 pages with an 8 MiB clipboard limit.
If a range changes while being read or exceeds the limit, preserve the clipboard
and show the reason. Copies include readable reasoning and tool results, with
opaque provider state and image bytes explicitly omitted. Larger ranges can be
copied separately. Code highlighting is bundled and deferred, with a 16 Ki
UTF-16 limit per code block and a 2 MiB / 128-block cache; other code remains
selectable plain text.

## 6. F04 — Context usage

Footer example: `Context ≈148k / 1M · 14.8%`. Numbers are illustrative. Use Pi's current context accounting and the configured model capacity, labeled **configured capacity** for router aliases.

Separate current context, latest provider request usage, draft/selected-skill estimates, output reserve, and cumulative session consumption. Cached prompt tokens still occupy context. Do not confuse cumulative spend with current context or count cached tokens twice.

Represent known, estimated, unknown, stale, and post-compaction states. Missing usage is not zero. A draft estimate is not provider-measured usage. Only show an exact component breakdown when the underlying adapter actually provides it.

Use Pi's automatic compaction policy and expose Compact now. Do not add an independent frontend compactor. Show progress/failure, and invalidate old percentages after compaction or incompatible model changes until an appropriate new estimate/report is available.

Acceptance: empty sessions, large skills/tool output, missing usage, cache accounting, profile changes, failed compaction, and successful compaction before the next usage report.

## 7. F05 — `/side` conversational detour

`/side` opens a right-hand panel; `/side <question>` opens it and submits. It is an independent ephemeral Pi session initialized from the parent's latest complete usable context boundary, not a subagent manager and not a switch of the parent's active branch.

Main remains visible and may keep running. Display the snapshot cutoff, independent model/request metrics, composer, Stop, and Read-only tools label. Exclude partial assistant messages and unmatched tool calls/results. Include valid compaction summaries. Future main messages do not automatically enter the side.

Main and side have different session IDs, mutable state, cancellation controllers, and continuation cursors. The workspace is live, not snapshotted: a side may see file changes made after its conversational snapshot.

Default tools are explicitly allowlisted local read/search operations. No shell, writes, mutating MCP tools, or arbitrary executable extensions in the side. This is a tool policy, not an OS sandbox. Skills cannot grant additional tools.

Actions: Copy; Bring back to main; Keep as separate chat; Close. Bring back inserts an editable draft, never silently sends or steers. Keep persists an independent chat; it remains read-only until the user explicitly changes its tool mode at idle. Closing a running side asks to cancel/discard or leave it open.

One side per main chat; no nested sides in v1. Unkept sides are memory-only and disappear after host/app termination. They do not inherit persistent body tracing. Keeping/exporting side content is deliberate.

Acceptance: concurrent streaming; independent cancellation; snapshot after compaction; parent immutable on close/promotion; no new explicit-skill authorization from historical text; side cannot gain write tools through extensions or skill scripts.

## 8. F06 — Codex skills and explicit-only invocation

Discover `${CODEX_HOME:-~/.codex}/skills`, compatible user/project `.agents/skills` directories, configured additional paths, and approved existing Pi skill paths. Read in place and preserve relative scripts/assets. Canonical path, not name alone, identifies a skill. Duplicate names require disambiguation; symlink aliases deduplicate.

A user types `/a-skill-here` or selects a slash-picker item. Selection creates a structured skill chip carrying canonical identity, arguments, and explicit user intent. Built-ins `/side`, `/debug`, and `/compact` are reserved; conflicting skills remain available through qualified picker entries.

Only direct user invocation authorizes explicit expansion. Model output, tool output, copied history, quoted examples, and code blocks do not. The host validates the invocation and loads the selected version, rather than asking the model to decide whether it was explicitly mentioned.

Read Codex `agents/openai.yaml` policy `allow_implicit_invocation: false` and translate it to the host/Pi explicit-only policy without rewriting files. Explicit-only skills remain in the user picker but are absent from the model's automatic skill-discovery prompt. Honor disabled skills separately; conflicting restrictions take the stricter result. Invalid policy metadata must not silently enable implicit use [C1].

Support the relevant Codex disabled-skill configuration and a per-skill Explicit only override. Preserve prose-only restrictions; arbitrary prose cannot be reliably classified as machine policy. Display unresolved/malformed policy as needing attention, not unrestricted execution.

Activation records content hash, source directory, and submitted-turn identity. It authorizes expansion for that turn and its tool loop, not permanent implicit activation. Historical instructions may remain in context; history is not a fresh permission grant. A selected skill cannot authorize unavailable tools or install plugins. Missing Codex/MCP dependencies are shown clearly.

Acceptance: duplicate names, disabled vs explicit-only, malformed YAML, reserved command names, quoted commands, symlinks, modified files between selection/send, missing dependencies, and side snapshots. Discovery filtering is not filesystem isolation for an unrestricted local agent.

## 9. F07 — Codex AGENTS.md

Resolve global instructions from `CODEX_HOME` and project instructions from the project root to the session working directory. Prefer `AGENTS.override.md`, then `AGENTS.md`, then configured project fallback names; at most one applicable nonempty file per directory. Preserve root-to-leaf ordering and deeper scope. When there is no project root, do not scan arbitrary filesystem ancestors [C2].

Keep Pi's base system prompt but supply one resolved instruction chain, avoiding duplicate Pi/Codex loading. Deduplicate canonical paths. Additional Pi-only instructions require an explicit compatibility setting and visible order.

Inspector: selected/ignored files, scope, ordering, working directory, hash, read errors, configured size limit, and truncation. Respect the documented default 32 KiB combined discovery limit unless configured otherwise; label any implementation differences. Do not truncate in the middle of a UTF-8 codepoint. Refresh only at a deliberate turn boundary and record the applied version.

V1 requires startup/root-to-working-directory discovery. Do not preload every repository AGENTS.md as global guidance. Automatic enforcement for all newly visited descendants is not claimed; deeper instructions should be read when working there, and sessions can start in the relevant directory. Arbitrary shell commands cannot be reliably statically mapped to every affected path.

Acceptance: global/project overrides, nested working directory, fallback names, empty/unreadable files, custom home, no repository root, duplicate symlinks, byte limit, and edited instructions between turns. Supporting instructions does not import Codex sandbox/auth behavior.

## 10. F08 — Token rate and first-token timing

Measure in the host at provider dispatch/content observation using a monotonic clock; never use webview render timestamps.

| Metric | Definition |
| --- | --- |
| Observed TTFT | Actual HTTP attempt dispatch to first nonempty exposed model-content delta: text, thinking, or tool arguments |
| First text | Attempt dispatch to first nonempty visible answer-text delta |
| Request-average output rate | Provider-reported output tokens / dispatch-to-stream-completion seconds for that attempt |
| Live visible rate | Compatible-tokenizer estimate over a rolling visible-text interval, prefixed `≈` |
| Turn elapsed | End-to-end turn duration including tools, retries, and additional model requests; not generation speed |

Pings, headers, empty events, and start envelopes are not tokens. No observable content means unavailable TTFT. Hidden reasoning and proxy buffering limit what can be measured. Missing tokenizer support means unavailable live token rate or explicitly labeled characters/second.

One user turn may contain several requests; distinguish requests and attempts. Do not count cumulative stream usage as incremental counts or add reasoning twice when included in output [A1]. Failed/cancelled calls show partial metrics. Record per-request source/completeness and separate retry wait from successful-attempt TTFT.

Main and side have independent footers. Clicking a metric opens its request and attempt details. Rates must not be labeled provider decode speed unless that speed is actually reported by the provider.

Acceptance: fake-clock text-first/thinking-first/tool-first tests, empty events, retries, tool time, cumulative/cache usage, missing values, cancellation, and multiple requests per turn.

## 11. F09 — Exact current-session request/response debug view

### Inspector content

Open via `/debug`, toolbar, or View menu, during or after a run. Scope to the selected session; clearly distinguish main and side. Group actual requests by turn and purpose, including compaction and other app-owned model calls.

| View | Required data |
| --- | --- |
| Overview | Session/turn/request/attempt IDs, purpose, API, requested and reported model, effective URL, status, timings, usage, error/cancellation, capture completeness |
| Request | Actual HTTP method, URL, credential-redacted headers, final serialized outgoing body; raw bytes/text and separately labeled pretty JSON |
| Response | Actual status, credential-redacted headers, raw body/SSE, including non-2xx and non-JSON errors |
| Events | Timestamped raw provider events and a separately labeled Pi-normalized event stream |
| Context | Applied instructions/skills and normalized input diagnostics, not a substitute for the actual request |

Capture after serialization at the HTTP fetch boundary. Do not reconstruct the request from chat bubbles, treat pre-serialization `onPayload` as exact HTTP, or call normalized Pi events the raw response. Preserve unknown fields/events, whitespace, fragmented UTF-8, errors, signatures, and opaque encrypted content.

Exact means body bytes exposed at the application transport boundary, **not** TCP/TLS packets. HTTP decompression/header normalization may already have occurred; chunk boundaries are observational, not model token boundaries. Authentication headers and secret URL fields are always redacted and labeled; raw bodies are full sensitive payloads unless explicitly transformed. Pretty JSON/assembled messages/redacted exports are derived views, never byte-exact originals.

For LiteLLM, capture is **app ↔ LiteLLM**. Hidden LiteLLM ↔ upstream traffic is unavailable without separate gateway instrumentation. Show supplied correlation/backend metadata, but never invent unseen upstream requests.

### Capture controls and privacy

Default: bounded **Session memory** capture from session start, with a visible badge and first-use disclosure. Opening the inspector does not begin recording; closing it does not stop recording. Alternatives: Off and explicit Persist locally. Old imported sessions, pre-capture requests, and evicted payloads cannot be retroactively recovered as exact traces.

Initial limits: 128 MiB captured-body memory per workspace host, 32 MiB per individual body, and 2,000 attempt metadata records. Evict oldest completed bodies first. Under pressure, active captures stop recording further bytes with a visible reason; agent traffic continues. Always distinguish complete, prefix-only, evicted, unavailable, and capture-error states, with retained/observed bytes. Never silently claim an incomplete trace is exact and complete.

Persistence is opt-in, user-only local files, seven-day retention and a 1 GiB global cap shared across workspace hosts. Capture preferences can be chosen before the first request and survive idle host restarts. Bodies can include code, prompts, personal data, and secrets. Unkept sides stay memory-only. Off affects future capture; Clear deletes existing captures separately. Do not write traces into workspaces, general logs, crash reports, or cloud telemetry.

Export defaults to metadata only. Full-body export needs native confirmation and destination choice. A redacted export includes a preview and transformation manifest; do not promise automatic redaction catches all secrets. Debug data is not exposed as an agent tool. The inspector must not automatically replay/retry requests that can incur cost or cause another tool cycle.

### Failure behavior and tests

Show attempts that fail before any response, HTML error bodies, HTTP-200 streams containing errors, malformed SSE, retries, and partial cancellation. Recorder failures must not crash or block the agent. Extension-owned network transports outside the instrumented path are explicitly outside coverage.

Acceptance: a local fixture server verifies request bytes received and response bytes emitted against captures. Capture must not change payloads, consume streams twice, reorder events, leak auth headers, or make memory unbounded. Test main/side/compaction correlation, large bodies, eviction, and disk failure.

## 12. F10 — Reliability, security, and performance

Host crashes preserve resumable Pi history and mark uncertain activity interrupted. Never automatically replay a possibly mutating tool or restart a request after crash. Closing the last window does not hide still-running work; quitting offers explicit stop/quit behavior.

The web renderer has no credentials, arbitrary filesystem or shell bridge. Render Markdown safely; do not execute transcript HTML/JavaScript or automatically load remote tracking images. Links and local artifacts are mediated by native code. Full debug bodies use a native read-only viewer, not the transcript webview.

Require workspace trust before executable project configuration/extensions run. Pi's local tools execute with user permissions; process separation and side tool allowlisting are not a security sandbox [P2]. Native/host credentials cannot be claimed inaccessible to arbitrary code running as the same user.

Initial release-build targets on a documented Apple Silicon Mac with at least 16 GiB RAM:

| Measurement | Target |
| --- | --- |
| Native typing during two streams | p95 ≤ 50 ms; p99 ≤ 100 ms |
| Foreground delta to visible update | p95 ≤ 75 ms, excluding network/provider latency |
| Warm indexed chat to first useful viewport | ≤ 500 ms |
| Native shell cold launch | ≤ 2 s, without waiting on provider network |
| Idle aggregate CPU | Average < 1% of one core over 60 s, excluding agent work |
| Capture overhead | ≤ 5% elapsed-time overhead in controlled fixture tests |

These are targets, not measured results. Benchmark 10,000 messages, a 1 MiB response, 50 MiB tool output, two streams, and capture-budget exhaustion. Count native + WebKit + Node memory. M0 must establish a total-memory release budget; no unbounded history/stream queues. Do not claim universal memory/battery superiority from the framework choice alone.

## 13. Implementation sequence and done criteria

| Milestone | Exit condition |
| --- | --- |
| M0 | Pin runtime/Pi; prove both APIs, byte capture, native/web bridge, packaged runtime signing; establish memory baseline |
| M1 | Native shell/composers, protocol, Pi persistence, streaming/tools, cancellation and recovery |
| M2 | Dual-API configuration, context/metrics, complete current-session debug inspector |
| M3 | Codex skills, explicit-only/disabled policy, AGENTS resolver/provenance |
| M4 | Independent read-only `/side`, promotion and bring-back behavior |
| M5 | Acceptance/performance/accessibility/security suite and signed release packaging |

A screen alone is not a completed feature. Error cases and acceptance tests are required. V1 is done only when F01–F10 work and the owner-requested capabilities are validated on both API paths. No implementation code is supplied or claimed by these planning documents.

## 14. Compatibility references

Checked 2026-09-14. Pi inspection baseline: `71dca871bc80b6bc97be37f0ca3189399d651fff`. M0 must choose and lock the tested published release or vendored commit; a moving `main` dependency is prohibited.

- [P1] [Pi API types and fetch hooks](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/ai/src/types.ts); [Responses adapter](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/ai/src/api/openai-responses.ts); [Messages adapter](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/ai/src/api/anthropic-messages.ts).
- [P2] [Pi SDK](https://pi.dev/docs/latest/sdk); [Pi security model](https://pi.dev/docs/latest/security).
- [C1] [Codex skills and invocation policy](https://developers.openai.com/codex/skills).
- [C2] [Codex AGENTS.md discovery](https://developers.openai.com/codex/guides/agents-md).
- [A1] [Anthropic streaming and usage](https://platform.claude.com/docs/en/build-with-claude/streaming).
- [O1] [OpenAI Responses streaming](https://developers.openai.com/api/docs/guides/streaming-responses).
