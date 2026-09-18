# Pi App — Implementation Design

Status: implementation handoff, not implemented or benchmarked.  
Updated: 2026-09-14.  
Requirements: [Features.md](Features.md). Read that document first.

## 1. Decisions and implementation authority

Build a native macOS client around Pi, not a new agent harness. The owner selected the native-shell/web-transcript architecture for long-term Mac quality and performance. All F01–F10 requirements in Features.md are v1 requirements.

| Concern | Decision | Reason / boundary |
| --- | --- | --- |
| Application | Swift + SwiftUI, AppKit where needed | Native windows, settings, menus, accessibility, and application state |
| Main and side composers | AppKit `NSTextView` wrapped for SwiftUI | Native editing, undo, IME, focus, and command completion |
| Transcript | React + TypeScript in `WKWebView` | Rich streaming Markdown, code, tool cards, and diffs; not the entire app |
| Agent execution | TypeScript + Pi SDK in bundled Node | Preserve Pi's loop, tools, model adapters, sessions, and compaction |
| Host boundary | Versioned NDJSON over anonymous local pipes | No localhost server, port, bearer token, or browser network bridge |
| Agent history | Pi-format session files | One authoritative model transcript |
| Desktop metadata | SQLite, owned by native application | Workspace/session index, drafts, profiles, command status, retained trace index |
| LLM APIs | `openai-responses` and `anthropic-messages` | Both first-class; HTTP/SSE in v1 |
| Request debugger | Instrumented provider fetch + separate normalized event view | Actual serialized bodies, not reconstructed chat messages |
| Distribution | Bundled, signed/notarized, direct-download app | No dependence on globally installed Node or Pi |

Proposed baseline is macOS 14+, Apple Silicon. Use a supported Swift toolchain with strict concurrency checks; pin the exact Xcode, Node, Pi, and JavaScript dependency versions during M0. Use Swift Package Manager for native dependencies and a committed JavaScript lockfile. Prefer the OS SQLite library behind a small Swift repository layer; no Node SQLite native addon is required. React/Vite, a safe Markdown parser, lazy syntax highlighting, and test tooling are sufficient; avoid a large frontend application framework.

Pi source inspected for this handoff: commit `71dca871bc80b6bc97be37f0ca3189399d651fff`. That is an inspection baseline, not a tested application dependency. Pi APIs have evolved; some older examples use different package names and runtime constructors. M0 must record the package/version actually compiled. No moving `main`, loosely ranged Pi dependency, or fabricated SDK method is acceptable. References [P1]–[P6] identify the implementation seams verified from source.

### Non-negotiable invariants

- Only a host-owned Pi session writes its authoritative history; the UI never reconstructs model input from rendered messages.
- Each session has at most one mutating command lane. Main and side share neither mutable history nor cancellation state.
- Every app-owned model request on either supported API passes through the same observability boundary, including compaction.
- Explicit skill invocation is a structured user action, not a model interpretation of arbitrary transcript text.
- The transcript webview receives neither credentials nor raw debug payloads nor arbitrary filesystem/shell access.
- No queue, trace buffer, transcript cache, or tool preview grows without a limit and defined overflow behavior.
- An interrupted request/tool is never automatically replayed as though its effects were known to be absent.

## 2. Components and repository layout

```text
PiApp.app
  Native application process
    Workspace/session controllers and SQLite
    Native main/side composers and metrics
    Native debug inspector / paged read-only payload viewer
    Host supervisor and protocol client
    WKWebView: main transcript
    WKWebView: side transcript, only while visible
           |
           | versioned commands/events, anonymous pipes
           v
  Node host for an active workspace
    Session registry and per-session command lanes
    Pi adapter + supplied ModelRuntime
    Codex resource resolver
    Provider-call instrumentation and bounded trace recorder
    Pi sessions, tools, and compaction
           |
           | actual serialized HTTP requests / SSE responses
           v
    Direct provider OR user-configured gateway such as LiteLLM
```

Start one host lazily per active workspace, capable of multiple Pi sessions including a main and its side. Do not start a host for browsing archived history. Unload idle session runtimes and stop an idle host after a configurable grace period. Default to at most one mutating main run per workspace plus its read-only side; another editing session queues until the existing writer finishes. Independent workspaces can run concurrently within an app-level configurable concurrency limit. These are app scheduling policies, not Pi capabilities or security isolation.

Each host failure affects its workspace, not other hosts. Native UI and saved-history browsing remain available when a host fails. Runtime sharing is an implementation economy; if profiling demonstrates harmful contention, splitting active sessions into individual hosts can be a later change behind the protocol.

Proposed implementation tree:

```text
Features.md
Design.md
apps/macos/PiApp/              # SwiftUI/AppKit app target
  Application/                # lifecycle, windows, menus
  Workspaces/                 # trust, session index, drafts
  Composer/                   # NSTextView, skill chips, IME
  Transcript/                 # WKWebView bridge and projection
  Inspector/                  # native debug/context/skill views
  Host/                       # Process supervision, framed I/O
  Storage/                    # SQLite, migrations, Keychain
packages/protocol/            # JSON schemas, TS types, Swift fixtures
packages/host/src/
  main.ts                     # protocol-only stdout
  sessions/                   # registry, state, command lanes
  pi/                         # all version-specific Pi adaptation
  providers/                  # profiles, instrumented runtime/fetch
  compatibility/              # skills and AGENTS resolver
  observability/              # attempts, SSE observer, metrics, storage
  security/                   # trust, tool allowlists, secret masking
packages/transcript/src/      # React presentation only
fixtures/providers/           # synthetic Responses/Messages traffic
fixtures/compatibility/       # synthetic skill/instruction trees
scripts/                      # build, bundle, sign, smoke tests
```

Use owned interfaces and contract fixtures across languages rather than sharing Pi classes with Swift or the webview. Do not implement plugin administration, a generic workflow engine, or an event-sourcing platform to deliver these features.

M1 implementation bounds: three loaded Pi runtimes per workspace host; 60-message /
300 kB host presentation pages plus one bounded active message; sixteen queued
follow-ups / 2 MiB and a separate sixteen-item / 2 MiB steering budget per turn.
The native archive reader and writable import validator currently allow 128 MiB
files and 32 MiB individual records, reporting larger inputs explicitly. These
are app limits, not Pi SDK guarantees. The 120-second idle host grace and
two-workspace concurrency default remain separate from the M5 measured budget.

M2 implementation bounds: 2 MiB Pi configuration files / 512 discovered profiles;
credential activation in a disposable 12-second worker; 4 images / 16 MiB per
turn, 8 MiB per image, 32 MiB queued or steering image-reference budget. Native
body pages are 32 KiB. Pretty JSON requires a complete body fitting one page;
raw byte paging and binary export remain available for larger captures. SSE
indices retain 1,024 ranges per attempt / 16,384 per workspace, independently of
the original body budget; omitted index ranges are counted. Capture preferences
are native metadata and apply before dispatch after host startup. One native
actor coordinates persistent trace retention across hosts. See
[docs/M2Validation.md](docs/M2Validation.md) for executed checks and compatibility.

## 3. Native shell, rendering, and focus

The native application owns selected workspace/session, drafts, profile selection, navigation, run indicators, side-panel lifetime, and debug inspector state. Keep high-frequency transcript updates out of broad SwiftUI observable objects. Parse host messages and perform SQLite work off the main actor; publish narrowly scoped presentation updates on the main actor.

Wrap `NSTextView` for both composers. The wrapper must support marked text and query IME state before treating Enter as Send. Model a draft as text plus explicit attachment/skill tokens, not Markdown inferred back from the text view. Preserve selection and undo across ordinary model updates. Slash suggestions are native and never generated by an LLM.

A visible transcript pane uses one webview, never one webview per message. Load bundled assets using a restricted app-owned scheme or strictly scoped bundled resources. Use a nonpersistent website data store. Do not serve the renderer from a remote origin or development server in production. Apple supplies `WKWebView` and script-message integration for this native/web boundary [M1].

The renderer receives presentation messages: stable IDs, text blocks, safe tool summaries, display status, and approved attachment references. It does not receive provider credentials, full raw traces, runtime configuration, or Pi's opaque continuation data. Raw debug bodies use a native paged read-only text/hex viewer so even malformed/private provider content does not enter the transcript webview.

Bridge actions are allowlisted and schema-validated: renderer ready, viewport change, request history page, copy selected text, request native open-link/artifact, and accessible focus transfer. Require current view/session identity. Validate origin/frame and user gesture for consequential UI actions; page-provided flags are not authorization. Do not expose Send, arbitrary file read, shell execution, or credential retrieval to transcript JavaScript.

Render Markdown with raw HTML disabled and sanitized links. Disallow executable URLs, remote scripts, automatic remote images, and unrestricted `file:` navigation. Bundle highlighting/theme resources. Clicking an external URL goes through native validation and the user's normal browser. Approved local attachments use opaque IDs resolved by native code, not arbitrary paths supplied by model output.

Virtualize/paginate large history; retain stable message IDs and scroll anchors as row heights change. Cache finalized Markdown/code. Batch foreground display changes once per animation frame, with a maximum delay consistent with F10; hidden panes receive a bounded dirty/version marker rather than repeated rendered deltas. Host execution and persistence continue independently.

Native text selection over currently loaded content must work. Virtualization cannot honestly promise browser selection across unmounted messages: provide explicit Copy conversation / Copy range and host-backed search that load the selected range. Live and in-memory sessions read completed entries through Pi's public branch API; unloaded archives use the read-only native history actor without starting Node. Search returns up to 100 matches per page. Copy uses Unicode-safe 16 Ki UTF-16 pages and an explicit 8 MiB clipboard limit, validates the branch/file revision, and changes the clipboard only after the whole chosen range succeeds. Opaque state and image bytes are omitted explicitly. VoiceOver should navigate messages/tool states without announcing every token; expose a reading mode or bounded accessible page instead of disabling virtualization globally.

Pinned highlight.js 11.12.0 loads its bundled TypeScript, JavaScript, Python,
Swift, JSON and shell grammars on demand after a 120 ms pause in code changes.
Only its escaped span output enters the code node; Markdown HTML stays disabled.
No auto-detection or network assets. Blocks above 16 Ki UTF-16 stay plain text;
the code cache is bounded to 2 MiB and 128 entries.

## 4. Host protocol and ownership

### 4.1 Transport and startup

Launch the bundled Node executable by absolute path with `Foundation.Process`, direct argv, known cwd, and an explicit environment. Do not interpolate a shell command or automatically source shell startup files. Strip injection variables such as unapproved `NODE_OPTIONS`, `NODE_PATH`, and loader overrides. Provide a configurable tools PATH for Finder launches. Authentication values are not command-line arguments.

Use UTF-8 NDJSON with one JSON object per line. Buffer partial reads and enforce a proposed 1 MiB encoded frame maximum before allocation/decoding. Chunk large text/blob transfers into smaller pages; no base64 megabody in the normal event stream. Newlines inside strings remain JSON-escaped. Standard output is protocol-only; redirect approved diagnostic logging to bounded, sanitized stderr before loading extensions. Tool subprocesses must not inherit protocol descriptors.

Startup: native sends `hello` with supported protocol major/minor and build ID; host replies `ready` with host epoch, exact Node/Pi versions, capabilities, and limits. Refuse incompatible major versions with an actionable packaged-runtime error. No session dispatch before the handshake completes. A host epoch is a fresh UUID on each process launch.

Example app-owned protocol, not a Pi SDK API:

```json
{"v":1,"kind":"command","commandId":"uuid","sessionId":"uuid","method":"turn.submit","params":{"clientTurnId":"uuid","mode":"normal","text":"Review this module","skills":[{"skillId":"canonical-id","expectedHash":"sha256","arguments":""}]}}
{"v":1,"kind":"reply","commandId":"uuid","ok":true,"result":{"accepted":true,"turnId":"uuid","queuePosition":0}}
{"v":1,"kind":"event","hostEpoch":"uuid","sessionId":"uuid","seq":42,"type":"message.delta","payload":{"messageId":"uuid","blockId":"text-0","delta":"Hello"}}
```

The native app computes/owns explicit skill selections. The host verifies them against its catalog. Do not let an event or renderer action create an equivalent authorization record.

### 4.2 Commands and events

| Command family | Operations |
| --- | --- |
| Workspace/runtime | open trusted workspace, list capabilities, shutdown |
| Session | create, open managed session, read-only import, continue-copy, snapshot, close |
| Turn | submit, queue, remove queued item, explicitly steer, stop |
| Configuration | list/select profile at idle, resolve credentials, reload resources at turn boundary |
| Context | get usage, compact now, list effective instructions/skills |
| Side | open from safe boundary, keep at safe boundary, close/discard |
| Debug | list attempts, read body/event range, change capture mode, clear, approved export |

Normalized events include session state, queue changes, message/block deltas or replacements, tool state/output references, usage/metrics, resource provenance, request/attempt updates, and recoverable errors. Unknown event types must not crash the UI. A debug observer cannot submit tools or replay requests.

Allocate increasing `seq` per session within a host epoch after applying the corresponding host projection update. One bounded event journal supports short reconnects. `session.snapshot` returns the current projection with its sequence boundary; the client replaces its old projection and applies only newer events. Events received while requesting the snapshot are buffered within a limit. On gaps or overflow, request another snapshot rather than guessing missing deltas.

This sequence is a presentation recovery mechanism, not a durable distributed log. Raw Pi history is not sent wholesale after every reconnect. Capture-body reads have explicit availability and offset bounds; trace IDs are not arbitrary filesystem paths.

### 4.3 Backpressure and command safety

Always drain child stdout off the UI thread. Separate control/status delivery from coalescible presentation traffic. Bound pending output and native/web delivery queues; when a client falls behind, replace accumulated display updates with `resyncRequired`. Never discard Pi history or corrupt the capture stream to preserve UI deltas.

Each session has one serialized command lane. Interrupt commands are handled promptly and set an abort request outside a long-running prompt await; they must not wait behind the prompt's completion. Queue/profile/resource changes are validated against session state. Repeated `commandId` in the same epoch returns the recorded acceptance/result rather than submitting twice.

Native SQLite stores command intent and acknowledgment. Link submitted commands to Pi-supported custom metadata/session entries where available. Do not claim an atomic transaction across SQLite and Pi files. If a crash occurs between dispatch and acknowledgment, reconcile known IDs with the saved session and show **Outcome uncertain** when necessary. Never automatically resend a possibly executed command because its acknowledgment was lost.

## 5. Session lifecycle, persistence, and recovery

Use explicit states:

```text
loading -> idle -> running <-> waitingTool / retryWaiting
                       -> compacting -> running or idle
                       -> stopping -> idle / interrupted
any active state -> interrupted on host loss
idle -> unloading -> closed
```

WaitingTool/retry/compaction are run substates with separate request identities. Only one Pi prompt/compaction mutation runs at once per session. Main and side have independent lanes. UI Stop sets cancellation intent immediately, stops queue draining, and calls Pi's cancellation path. A queued follow-up resumes only by an explicit user decision after Stop.

Track tool subprocesses by session. Normal side cancellation must not kill the entire workspace host. If an unresponsive extension/tool cannot be stopped without killing the host, display the consequence and require an explicit workspace-wide force stop. Aborted or uncertain tool effects remain marked; do not claim rollback.

Persist managed sessions under application support using Pi's session manager. Keep originals unchanged on import. Continuing a CLI session creates a new app session identity and copies through the adapter's Pi-format import operation, preserving original provenance and tool/message relationships. Detect truncated source files or changed sources during import; do not copy a live half-written record and call it valid.

Acquire a native OS-held app/workspace ownership lock before starting the writer host. A lock file's mere existence is not proof of a live owner. App-managed sessions must not also be opened for CLI writes; no cross-tool locking claim is made. Native stores a writer lease/host epoch for diagnostics, not as a replacement for the OS lock.

Host loss: mark active requests/turns interrupted, retain durable Pi history, release memory-only sides, and reload from the last valid session boundary. Do not replay recorded tool results as new actions. Saved partial assistant output can be displayed, but continuation must use Pi's validated recovery semantics or an explicit portable handoff. Recoverable incomplete tail records must be preserved for inspection before repair.

Native crash/quit: stdin EOF tells hosts to cancel, flush managed history, and exit; use a bounded shutdown grace period. Closing a window does not quit the application. Keep active work discoverable through the app/menu/windows. Full quit asks about active work, then stops it; v1 does not run a hidden persistent daemon.

## 6. Pi adapter and verified extension seams

All Pi-specific imports and mutations live under `packages/host/src/pi/`. Expose owned interfaces such as:

```ts
// Application contracts, not names claimed to exist in Pi.
interface PiSessionAdapter {
  submit(input: ResolvedSubmission): Promise<void>;
  steer(input: ResolvedSubmission): Promise<void>;
  abort(): Promise<void>;
  compact(): Promise<void>;
  contextUsage(): ContextUsageView;
  safeBoundary(): SafeSessionBoundary;
  subscribe(listener: (event: DesktopAgentEvent) => void): () => void;
  dispose(): Promise<void>;
}
```

The inspected `createAgentSession` accepts a supplied `ModelRuntime`, resource loader, session manager, model, and tool allowlist. Its current `tools` option is a list of tool names; older snippets passing tool objects must not be copied blindly [P1]. `ModelRuntime` exposes `stream`, `streamSimple`, `complete`, and `completeSimple`; the complete methods route through the corresponding stream methods [P2].

Create a separate instrumented ModelRuntime instance per active session, using a shared read-only configuration source and appropriately scoped credentials. At this baseline, install **instance-local, typed wrappers** on its public `stream` and `streamSimple` entry points, before passing it to Pi. Each wrapper creates a logical model-call record and supplies a call-scoped recording `fetch`. Preserve `this`, return-stream behavior, abort signals, original options, provider transforms, and caller hooks. Do not alter global prototypes or global fetch. A more direct officially supported hook may replace this adapter after tests, but it must preserve coverage.

Avoid wrapping `complete` again and double-counting the same request. `onPayload` can record a separately labeled pre-serialization view; `onResponse` provides response metadata, not the body. Neither alone satisfies raw capture. `ProviderRequestOptions.fetch` is the HTTP injection seam and explicitly does not cover WebSockets [P3]. Responses source passes it to its client [P4]; verify both adapters against the selected release.

Session/turn/purpose correlation is carried by immutable call context and closures, not a mutable global current-session variable. Session-owned runtime instances prevent main/side confusion. Allocate a call ID before lazy stream consumption. Use scoped async context where needed, but bind the recording fetch directly to the call so SDK callbacks cannot accidentally inherit another session.

Require integration tests proving that automatic/manual compaction and app-owned auxiliary calls use this instrumented runtime. If a pinned Pi path bypasses it, make a narrowly scoped, documented adapter patch before M0 passes; do not ship with falsely complete capture. Deferred, WebSocket, subscription-specific, and extension-private transports are not v1-supported paths. Extension network traffic must be labeled outside coverage unless explicitly routed through the app adapter.

Use Pi resource-loader customization to provide the merged skills and resolved AGENTS chain, rather than duplicating built-in discovery. Isolate loader hook names and any session-import calls in this adapter and compile-test against the lockfile [P1, P6]. Pin compatibility fixtures and produce a small upgrade report whenever Pi changes.

## 7. Provider profiles, credentials, and continuation

### 7.1 Effective profiles

```ts
// Owned serializable view; secret values are never included.
type ApiKind = "openai-responses" | "anthropic-messages";
interface EffectiveProfile {
  id: string;
  revision: string;
  providerId: string;
  modelId: string;
  api: ApiKind;
  baseUrl: string;
  contextWindow: number | null;
  maxOutputTokens: number | null;
  credentialRef: string;
  continuationGroup: string;
  source: "pi-import" | "app";
}
```

Keep the full Pi-owned model/compatibility configuration in the host; the UI view above does not replace it. Preserve supported imported fields and show unsupported fields, instead of silently dropping them during round-trip edits. A profile change produces an immutable revision; requests record the revision they used.

Read existing Pi model/auth references without rewriting the original files. A separate app overlay adds profiles and explicit overrides. Precedence is imported Pi configuration, then declared app override, then explicit per-session selection; display all overrides. Do not infer credentials or API from model names.

New credentials live in Keychain. Native sends a required credential to the host over the private pipe or implements Pi's credential-store interface through a narrow native broker. Never return a credential to the renderer or store it in a profile row. Credentials present in host memory are not inaccessible to arbitrary same-user code. Imported command-based credential resolvers/executable configuration require trust; merely opening the profile list must not execute arbitrary shell commands.

### 7.2 Endpoint and request behavior

The Pi/provider adapter owns payload conversion and URL assembly. For app-created profiles use API-specific base-URL semantics: a Responses SDK base normally ends at `/v1`, while the Anthropic SDK convention normally uses the API origin and appends `/v1/messages`. Do not universally append `/v1` in the app. Imported values pass through the pinned adapter unchanged; the fixture suite verifies the resulting URL.

The same LiteLLM alias can have two profiles with different API settings. The adapter must serialize the right schema and authentication. Responses uses its input/tool-output shapes; Messages uses its messages/tool-result shapes and required output budget. Do not hand-edit one provider's JSON into the other's in the UI [P4, P5, O1, A1].

HTTP/SSE is required for v1 capture. Explicitly reject unsupported transport selections with a useful error, rather than silently losing observability. Default to HTTPS except approved loopback HTTP; non-loopback HTTP requires a visible insecure-endpoint opt-in. Reject silent redirects for supported generation requests in v1 and ask the user to configure the final endpoint, preventing hidden forwarded credentials and unobserved redirect hops. This transport policy is disclosed, not represented as unchanged Pi default behavior.

Preserve provider timeout/retry configuration. Do not introduce an extra app-level automatic retry loop. Each actual fetch invocation is a transport attempt. Pi may initiate a new logical call after an agent-level retry; group it with the turn and a retry linkage only when known. Distinguish SDK/provider retries from user Retry. No automatic retry of partially executed tool effects.

### 7.3 Continuation compatibility

Define a conservative continuation group from API, effective endpoint, provider/profile identity, model compatibility, and credential account identity. Changing an API, endpoint, account, or non-compatible model invalidates opaque continuation reuse. A display-name change does not.

Same compatible profile: retain Pi's exact replay state, including reasoning signatures, encrypted content, tool IDs, and compaction records. Do not sanitize authoritative history through the presentation model. Across an incompatible group: keep the original intact and offer either a blank new session or a reviewed portable-context handoff.

A portable handoff creates a new session with an explicitly labeled context summary/text selection and supported attachments; it does not reinterpret old provider-native tool/reasoning records as native records of the new provider. No silent LLM summarization call is needed; an optional summarize action is explicit and captured. Never assume a gateway alias can accept opaque data produced by whichever backend it routed to previously; show incompatibility errors rather than stripping data invisibly.

## 8. Current-session debugging: data model and exactness

### 8.1 Three separate layers

1. **Transport capture:** actual serialized request body and response bytes at the fetch boundary, with sanitized metadata.
2. **Provider interpretation:** timestamped SSE events/JSON, provider model/usage/errors, derived without changing capture bytes.
3. **Pi interpretation:** normalized messages, tool events, usage, and context, linked to the same call.

Keep these separately labeled. A response may be HTTP 200 and still fail in its stream. A pre-serialization payload may differ from the SDK's final request. A normalized assistant message is not the original SSE body.

```ts
type CaptureState =
  | "recording" | "complete" | "prefix-only"
  | "evicted" | "disabled" | "unavailable" | "capture-error";
interface AttemptRecord {
  sessionId: string;
  turnId: string | null;
  requestId: string;
  attemptId: string;
  purpose: "turn" | "compaction" | "connection-test" | "auxiliary";
  ordinal: number;
  api: ApiKind;
  profileRevision: string;
  method: string;
  redactedUrl: string;
  status: number | null;
  outcome: "in-flight" | "completed" | "failed" | "cancelled" | "interrupted";
  requestBodyRef: string | null;
  responseBodyRef: string | null;
  requestCapture: CaptureState;
  responseCapture: CaptureState;
  observedRequestBytes: number | null;
  observedResponseBytes: number;
  retainedRequestBytes: number;
  retainedResponseBytes: number;
}
```

Raw bodies and event chunks are not embedded into this metadata structure. Include explicit error/reason fields, hashes of retained bytes, response headers, reported model, metrics/provenance, and host epoch in the implementation schema. A prefix hash is labeled as such, not the full-body hash.

### 8.2 Request capture

Install the wrapper after Pi chooses its API and the provider SDK serializes the payload. Resolve `Request` plus `RequestInit` according to fetch semantics, including init overrides. Record the actual method/URL/headers and outgoing UTF-8 bytes. JSON body strings must be captured without parsing/reserializing. This is the submitted body at the fetch boundary; a DNS failure does not prove any byte reached the server.

The normal two-provider JSON path should supply a string or byte buffer, allowing observation without consuming the body. Support other body forms only through a tested bounded adapter. Never eagerly buffer an arbitrary upload or call `.text()` on a live stream to make a debug view. An unsupported body form is explicitly unavailable for exact capture and fails the supported-provider M0 test if those providers require it.

Do not add correlation headers unless a profile explicitly supports them; local call/attempt IDs suffice. A wrapper must preserve the caller's abort signal, headers, body, and options, except the documented redirect policy. No debug mutation of model parameters, retries, or cache settings.

### 8.3 Response capture without unbounded teeing

Record response status and available headers before consuming its body. Return a demand-driven stream wrapper that reads one upstream chunk for the SDK consumer, timestamps it, offers a bounded copied chunk to the recorder, and forwards identical bytes in order. Recorder failures are caught and reported; the consumer continues.

Do not use `response.clone().text()`, an unbounded `tee()`, or a fire-and-forget second consumer that can buffer the entire stream. Preserve response semantics needed by both SDKs: status, headers, URL/redirect metadata, body-null cases, cancellation, text/JSON consumption, and stream errors. A naive `new Response(body)` loses metadata; the response adapter needs conformance tests for the actual SDK access patterns and Node version [N1].

Propagate SDK cancellation to the original reader and release reader locks. Distinguish EOF, SDK consumer cancellation, transport exception, user cancellation request, and host loss. Exact capture is complete only for the bytes fully observed at that boundary; early consumer stop after a terminal provider event can leave a consumed-prefix capture even when the model result completed successfully.

Fetch-exposed response bytes may already be decompressed. Headers can be normalized, combined, or runtime-generated. Network transfer chunking is not preserved and never equals token boundaries. State these limits in the UI/export manifest. Do not advertise a packet sniffer or hidden gateway traffic inspection.

### 8.4 SSE observer

Parse a bounded side observation of the forwarded bytes with streaming UTF-8 decoding. Support split codepoints, CRLF split across chunks, multiline `data:`, comments, blank-line event boundaries, and incomplete trailing events. Preserve raw bytes separately; parsing failures must not replace or repair the raw record.

Use API-specific event extractors. Responses semantic events and Anthropic content-block/message events are different [O1, A1]. Preserve unknown fields/events, ping events, malformed JSON, and stream-internal errors. A large event beyond the observer's parsing limit is marked unparsed; it must not crash Pi or turn the capture into valid-looking fabricated JSON.

Timestamp raw chunks on observation, then associate parsed events with the chunk completing that event. Normalized Pi event timings are a separate fallback/provenance. The observer is for inspection/metrics, not tool execution; Pi remains the authoritative parser and agent runtime.

### 8.5 Correlation and coverage

Allocate request ID once per instrumented model invocation and attempt ID per fetch. Record purpose before dispatch, including compaction that occurs between user-visible turns. Link to a turn when meaningful; do not force every auxiliary request onto the latest user message. Record requested model and response-reported model separately.

Gateway capture is app-to-gateway only. Preserve supplied request IDs and explicit backend metadata; gateway-internal attempts, request transformations, model reasoning not returned, and server token-generation timestamps are unknown. Do not label inferred upstream data exact.

## 9. Capture limits, storage, privacy, and export

Default mode is Session memory from session creation after the first-use disclosure. Raw body capture is visible and can be turned off; inspecting a chat does not initiate a retroactive recording. Main and side have separate controls. An unkept side cannot inherit persisted recording.

Implement F09's initial limits: 128 MiB raw-body memory per workspace host, 32 MiB per individual body, and 2,000 attempt metadata records. Count request bodies, response bodies, retained raw events, and duplicate previews against budgets; do not evade limits by keeping the same payload in another cache. Avoid storing full normalized and pretty-printed duplicates.

Evict oldest completed body records first. If active requests alone exhaust the budget, stop retaining subsequent bytes for those bodies and record a prefix-only reason; continue forwarding traffic and incrementing observed-byte counts. Do not retain isolated later suffixes while presenting them as a contiguous body. Keep a visible marker for missing/evicted attempts; metadata limits must not silently erase a currently active attempt.

Disk persistence is explicit, with user-only permissions (directories 0700, files 0600), seven-day retention and 1 GiB global cap as initial settings. Native coordinates global disk reservations across hosts; a host cannot independently consume the entire global quota. Disk-full/permission failure switches capture to an explicit degraded state without stopping the model request. Retained artifacts use opaque filenames outside workspaces, append-only bounded chunk files, and atomically finalized manifests. Incomplete manifests are reconciled on launch.

The native app is SQLite's writer; hosts own Pi session files and authorized trace payload files. Hosts emit small index updates, not SQLite writes. Metadata is safe to reconstruct from trace manifests after a crash. Do not promise atomicity across these stores. Memory-only bodies never go through a tempfile, SQLite BLOB, normal log, or crash attachment. OS swap/process dumps remain outside an application-level memory-only guarantee.

Always redact authentication headers, cookies, proxy credentials, secret query/userinfo values, and configured sensitive headers before metadata retention. Unknown custom header values default to redacted unless the profile marks them nonsecret; preserve their names. Record only allowlisted nonsensitive correlation headers by default. This means metadata is deliberately not byte-exact, and the UI says so.

Raw bodies intentionally retain exact sensitive payload bytes within capture limits. They can contain user secrets even with header redaction. Native viewers warn before revealing/copying/exporting full bodies. Pretty views and optional redacted body exports are generated on demand and labeled derived. Do not alter the original while calling it exact; do not claim a secret detector finds all sensitive data.

Export creates an explicit manifest with API/profile, capture boundary, completeness, byte counts, time basis, redactions, and file hashes; optional request.bin, response.bin, and parsed-events.jsonl contain only approved data. Default export is metadata-only. Full-body export requires native confirmation and a chosen destination. Persistent records and exports are not encrypted by this initial design beyond OS protection; disclose this and do not imply Keychain encrypts arbitrary trace files. Secure erasure on SSD/backups is not guaranteed by deletion.

No trace upload, crash-report attachment, agent-accessible debug tool, automatic cURL replay, or automatic retry button that reexecutes a tool cycle. Export destinations inside a repository require a warning. A user can separately choose to run a captured request, but replay tooling is not v1.

## 10. Metrics and context accounting

### 10.1 Timing

Use the host monotonic clock for durations; record wall time only for display/export. Convert monotonic offsets to safe numeric milliseconds relative to a host/request origin, rather than exposing large nanosecond integers to JavaScript/Swift inconsistently. Clock epochs do not cross process restarts.

For each actual HTTP attempt record dispatch, response headers, first observed body bytes, first nonempty model-content event, first visible text event, normalized/provider terminal event, observed EOF, and cancellation request separately. TTFT is first exposed content minus attempt dispatch, not first HTTP bytes or `message_start`.

Prefer content timing from the raw observer; if unavailable, use Pi-normalized content observation with provenance explicitly shown. Empty/ping/signature-only metadata is not a token. A non-streaming complete text response can produce a first-text observation, but label it non-streaming rather than implying streamed decoding.

Request-average output rate is provider-reported output divided by attempt dispatch-to-model-stream-completion seconds. Record the completion timing source and do not substitute UI animation time or include later tool execution. A missing/partial output count yields unavailable/partial rate. Distinguish transport EOF from the provider's semantic terminal event in the inspector.

Retries have separate attempts. Successful-attempt TTFT excludes earlier retry wait; request elapsed includes the whole call, and turn elapsed includes tools and additional calls. The footer identifies which request/attempt it displays instead of silently mixing them.

### 10.2 Usage and live rate

Keep raw provider usage and Pi-normalized usage with provenance. Reconcile cumulative values as snapshots, not increments; Anthropic documents cumulative `message_delta` usage [A1]. Do not add reasoning to output when it is already a subset. Do not sum cache fields twice or estimate billed cost from tokens without a configured pricing source.

Compute optional live visible-token rate using a tokenizer validated for that profile, over a rolling interval such as two seconds. Tokenization must run outside native UI and be bounded/incremental; do not retokenize a million-token conversation every chunk. Label it approximate and visible-text-only. Unsupported model/router tokenizers produce unavailable token rate or clearly labeled characters/second. Final provider output rate can include hidden output categories and is a different number.

### 10.3 Context

Use Pi's context API in the pinned adapter. Map it to a view containing token value or null, configured capacity, percentage or null, provenance, observation time, and validity state. Do not independently sum every historical usage record. Show draft/selected-skill contribution separately; never call it already-used context.

Compaction/model changes invalidate old estimates. Pi owns automatic compaction and configured reserves; manual compaction enters the same serialized lane. Draft/resource size checks happen before sending with explicit error/warning policy. The model profile's configured capacity is not proof of an auto-router's actual hidden upstream capacity.

## 11. `/side` implementation

Maintain a cached immutable **safe boundary** as the parent advances: a validated Pi session-context snapshot after complete message/tool groups and compaction reconciliation. It includes the applicable summary and complete subsequent context, not every pre-compaction message plus a duplicate summary. A complete user message can be included when there is no unfinished assistant/tool group. During streaming or compaction use the prior cached boundary; never asynchronously copy a mutating active message array.

On `/side`, under a short parent lane operation, select the boundary and record its entry ID/context revision. Release the parent immediately. Create a new in-memory Pi session manager and independent runtime from the cloned usable context through the adapter. Keep semantic tool IDs and their matched results intact; any session-entry rekeying must preserve parent links and provenance. Set a new session ID/cache-affinity identity and clear provider server-continuation cursors that belong to the parent. Do not switch the parent's active branch.

Reuse the same compatible profile and instruction snapshot initially, with a visible cutoff. The side gets a new tool policy: explicitly allowlisted built-in local read/search tools only; no shell, edit/write, mutating MCP, or executable user/project extensions. Build the filtered resource/tool environment before creating the side. Enforce the allowlist again at dispatch so a prompt/skill cannot enable another tool. Read/search operations are not filesystem sandboxing and can still reveal sensitive local files; do not promise stronger isolation.

Explicit-skill authorizations from the parent are not inherited as active grants. Historical skill text may exist in cloned context, but the side's new resource catalog still excludes explicit-only skills from automatic discovery. Its first submitted question gets its own structured selections.

Keep as separate chat is applied at an idle safe boundary. While running, offer Keep when finished or allow the user to stop first; do not silently cancel. Write a complete independent Pi-format session to a temporary managed path, validate it, then atomically rename and register it. Until successful, keep the in-memory side intact. Avoid changing the active manager halfway through a tool run.

Bring back to main copies only user-selected text/summary into an editable draft; if the main has a draft, present insert/replace without destroying it. No hidden send or steering. Closing an unkept side cancels only its session, releases resources, and deletes its memory traces. Main cancellation and side cancellation remain independent.

## 12. Codex skill compatibility

### 12.1 Catalog and trust

Read approved Pi paths, `${CODEX_HOME:-~/.codex}/skills`, compatible `.agents/skills` user/project directories, and explicit added paths. Canonicalize real paths, deduplicate symlink aliases, detect cycles, and cap file count/size/depth. Bound parsing of YAML/TOML; disable executable/custom object tags. A directory scan must not execute scripts, install dependencies, or fetch remote content.

Record stable skill ID, name, canonical SKILL.md path, source root, content hash, metadata hash, scope, description, dependencies, and policy. Name is not identity. Built-in slash names have precedence; qualified picker entries resolve collisions. Treat selected paths/hashes as host-validated IDs, not user-supplied shell text.

Codex `agents/openai.yaml` and `[[skills.config]]` disabled entries are documented compatibility inputs [C1]. Combine restrictions:

```text
invalid mandatory policy -> needsAttention (not implicitly available)
any applicable disabled setting -> disabled
any explicit-only setting -> explicitOnly
otherwise -> implicitAllowed
```

Pi's native explicit-only frontmatter and an app override participate in the same reduction. Unknown prose restrictions remain visible and are preserved in the loaded instructions; do not pretend arbitrary natural-language policy has been formally validated. User can explicitly mark a skill Explicit only.

Keep two catalogs: enabled user-picker items and the subset allowed in the model's automatic skill-discovery prompt. Disabled items appear only in management with their reason. The model must not be shown an explicit-only description through a second duplicate Pi discovery path.

### 12.2 Command resolution and expansion

Only a leading top-level slash command or an explicit picker chip is a command. Do not parse slash-looking text inside code, quotations, pasted transcript examples, tool output, or assistant messages as new authorization. Support the requested `/name` UX and translate into a resolved invocation; a literal command without chip is resolved by the native command parser and revalidated by the host.

At submit, resolve each selected canonical ID, verify policy and expected hashes, and freeze the content for that turn. Changed content/policy is not silently substituted: refresh the chip and require resubmission/confirmation. Use the Pi resource-loader/skill-expansion adapter for a path-aware expansion. Native `/skill:name` is acceptable only when it resolves unambiguously; do not depend on duplicate names in Pi's CLI lookup.

Retain original base directory for relative scripts/assets. Expansion is source content plus arguments and an explicit invocation provenance marker, not automatically executed code. Inject through Pi's supported prompt/resource mechanism exactly once. Tool permissions are unchanged.

Grant lifetime is the accepted turn and its agent/tool loop. Queued turns retain their own frozen selections and revalidate revocation before execution. Persistent history records what happened; it does not authorize later automatic rediscovery. A skill dependency referencing an unavailable Codex/MCP tool is reported before execution; reading Markdown is not complete compatibility with that runtime.

## 13. AGENTS.md resolver

Implement one resource-resolution service with deterministic fixtures [C2]. Resolve CODEX_HOME from explicit app setting/environment/default, without evaluating shell expressions. Establish the Git/project root and working directory with canonical path handling. For a linked worktree, use its actual root; do not treat a `.git` file as absence of a repository. With no root, check only cwd for project instructions.

Select one nonempty global override/base file, then one file per project directory from root to cwd, in priority order: AGENTS.override.md, AGENTS.md, configured fallback basenames. Bound fallback names to valid filenames rather than allowing path traversal. Empty files allow the documented fallback search; unreadable higher-priority files produce a visible warning/error rather than being silently treated as intentional empty guidance.

Track original bytes, selected scope, hash, and inclusion/truncation status. Respect configured discovery size limits (default combined 32 KiB per the referenced guide), and test a Unicode boundary. If behavior differs from the pinned Codex reference for global/project byte budgeting, document and expose it instead of claiming exact compatibility.

Pass the resulting chain to Pi's agent-file resource override while retaining its base prompt. Do not leave a duplicate Pi auto-loaded chain active. Deduplicate canonical aliases with a clear provenance note and retain effective root-to-leaf ordering. Pi-only instruction paths are optional explicit additions, not hidden defaults appended a second time.

Freeze applied instructions per submitted turn. File watching marks resources stale but does not alter an in-flight call. Refresh between turns, including before a queued turn starts. Capture the applied revision in request provenance. Side sessions start with the boundary's instruction snapshot and disclose any later refresh.

Do not recursively inject all descendant AGENTS files. V1 implements startup/root-to-cwd semantics; deeper-directory automatic enforcement is not claimed. Instruct the agent to inspect applicable descendant guidance before working there, and allow a session rooted in that directory. Do not claim static inspection of arbitrary shell commands enforces all directory-specific guidance.

## 14. SQLite and filesystem layout

```text
~/Library/Application Support/PiApp/
  app.sqlite                    # native-owned metadata; WAL/migrations
  settings.json                 # app-only settings; no plaintext API keys
  sessions/<workspace-id>/      # authoritative Pi-format managed sessions
  traces/<session-id>/<attempt-id>/  # explicitly persisted bodies/manifests
  runtime-state/                # bounded ownership/epoch diagnostics
~/Library/Caches/PiApp/          # discardable safe rendering/index caches
PiApp.app/Contents/Resources/    # immutable bundled host/UI/dependencies
```

Suggested native tables, with migrations and explicit schema versions:

| Table | Required responsibilities |
| --- | --- |
| workspace | ID, canonical root, trust decision/revision, last opened |
| session_metadata | app/Pi identity, path, title, parent/provenance, profile revision, tool mode, interrupted state |
| draft | session ID, text, structured attachments/skills, selection, version |
| provider_profile | nonsecret override/reference data and credential reference |
| command_log | command ID, session ID, intent kind, acceptance/outcome, epoch; bounded retention |
| llm_request / http_attempt | retained nonsensitive timing/status/usage/index metadata |
| trace_artifact | authorized body file reference, completeness, bytes, hash, expiration |

Do not create a second authoritative messages table. Any search/render index is disposable and rebuildable from Pi history. Do not persist unkept side drafts/history/traces through generic autosave. Persistent metadata must not accidentally contain copied prompts, raw errors with secrets, or body snippets.

Enable foreign keys, serialize native writes, use WAL appropriately, back up before migrations, and version the app/Pi format compatibility separately. Native failure between trace creation and index update is repaired from manifests. Deletion covers session indexes, requested trace artifacts, and references; retention and exports are separate lifecycle decisions.

## 15. Security and packaging

Threat model: untrusted model output, malicious repository instructions/skills/extensions, accidental credential disclosure, bad provider payloads, and same-user local tools. This design reduces renderer exposure and accidental leaks; it is not an OS sandbox. Pi tools execute with user permissions. Arbitrary trusted extensions in the Node host can access host memory and bypass application policy, which is why sides do not load them and workspace trust precedes executable discovery.

Keep runtime credential values out of global tool subprocess environments wherever possible; pass only needed variables. Do not automatically request Full Disk Access. Normal macOS privacy controls remain relevant. Use app-managed directories rather than workspace trace files and validate artifact opens against explicit user-approved roots/IDs.

Bundle Node/Pi and web assets reproducibly with locked dependency integrity and notices. Start the exact bundled runtime, not whichever `node` is on PATH. Test the packaged app launched from Finder without a shell environment.

Sign nested executable components correctly and notarize the resulting application. Node/V8 JIT and any native dependencies may require helper-specific hardened-runtime entitlements; verify the actual release build in M0. Do not blanket-disable hardening or give the native UI unnecessary executable-memory permissions. Do not claim signing makes user-writable code safe to execute.

Owner addition (2026-09-14): use pinned Sparkle 2.8.1 signed updates through the
existing belloware.com release repository. Release and verify a dummy 0.0.1 to
0.0.2 upgrade before M0. Enable automatic checks and user-initiated installation;
guard relaunch while hosts have active work. Retain older signed/notarized DMGs
for explicit manual rollback; never advertise a downgraded build in the feed.
See docs/Release.md for the workflow. No home-grown updater is required.

## 16. Test plan and release gates

### Deterministic provider fixtures

Use a local HTTP fixture server with synthetic prompts/keys. It stores received request bytes and emits predetermined byte streams with controlled chunk boundaries/delays. Do not use production secrets in fixtures. Run the matrix through the real Pi adapters, not only an invented transport mock.

| Case | Required result |
| --- | --- |
| Responses normal stream | Correct endpoint/schema, content, completion, exact request/response capture |
| Messages normal stream | Correct endpoint/schema and max_tokens, cumulative usage, completion |
| Tool round trip on each API | Valid full arguments, exactly one dispatch, matching result in next request |
| Thinking-first / tool-first | TTFT differs correctly from first visible text |
| Split UTF-8/CRLF/SSE fields | Unchanged bytes, correct observer behavior, no replacement characters introduced |
| Unknown/oversized/malformed event | Capture preserved or honestly bounded; observer failure does not corrupt Pi |
| HTTP 400/401/429/500 + HTML | Attempt-specific errors/status/body, credentials masked |
| HTTP 200 then stream error | Model failure despite HTTP success |
| Transport failure before headers | Request attempt visible, absent response/status, no fabricated data |
| Retry then success | Separate attempts, correct total vs successful-attempt latency |
| Cancel before/after first content | Accurate partial state; reader/tool cleanup; no automatic resend |
| Main + side + compaction overlap | Correct immutable correlation and independent cancellation |
| Recorder off/capped/disk full | Traffic unchanged, no hidden complete-capture claim |
| Stream consumer early stop | Model outcome and capture completeness distinguished |
| Request and response hashes | Exact equality against fixture boundary when captures are complete |

### Application and compatibility tests

Test protocol split frames, oversized frames, bad schema, unknown events, duplicate command IDs, stale epochs, lost acknowledgments, reconnect during streaming, and snapshot races. Test host crash after tool dispatch and before acknowledgment; verify no automatic replay.

Use synthetic skill trees covering collisions, symlinks/cycles, explicit-only/disabled metadata, malformed policy, code-block commands, changed hashes, missing dependencies, and attempted side tool escalation. Use instruction trees for global overrides, nested worktrees, fallbacks, no Git root, byte caps, unreadable files, duplicate sources, and between-turn changes.

Native tests cover IME Enter, large paste, undo, focus, draft preservation, keyboard-only navigation, VoiceOver, dark/light mode, and debug copy/export confirmations. Web tests cover malicious Markdown/URLs, long code blocks, selection, bounded virtualization, and hidden-pane behavior. Packaged tests cover Finder environment, signing, EOF shutdown, no global Node/Pi, and multiple workspace hosts.

### Performance

Measure the F10 scenarios and targets in release builds. Include native, WebKit, and Node processes together. Record hardware, OS, build, warm/cold state, context size, capture mode, stream rate, and p50/p95/p99 where relevant. Treat main typing, streaming rendering, capture overhead, idle wakeups, and memory plateau as separate measurements.

M0 sets a measured total-memory release budget, and M5 must prove memory plateaus when opening/closing 100 historical chats and repeating large streamed turns under capture limits. A framework name or single-process RSS screenshot is not performance evidence. Reducing capture coverage to pass a benchmark requires an explicit visible mode change, not silent dropping.

## 17. Milestones and handoff instructions

| Milestone | Build next | Evidence needed to finish |
| --- | --- | --- |
| M0 | Minimal native shell, bundled Pi host, both real API adapters, recording fetch, one transcript pane | Locked versions; fixture byte equality; tool round trip; compaction capture; signing/Finder launch; measured memory baseline |
| M1 | Session/command protocol, managed history, native composer, streaming/tools, recovery | Duplicate/reconnect/crash tests; responsive typing; no automatic replay |
| M2 | Full profiles, context and timings, native current-session debugger | Dual-API error/usage matrix; bounded recording; exports/redaction; source/completeness labels |
| M3 | Skill and AGENTS compatibility with native inspectors | Deterministic discovery/policy/provenance fixtures; no duplicate instruction chain |
| M4 | Independent side session and read-only policy | Safe-boundary cloning; concurrent main/side; independent stop; atomic keep; bring-back draft |
| M5 | Release hardening, accessibility and performance | F01–F10 checklist, benchmark report, signed/notarized build, reproducible build/test instructions |

The implementation agent should begin with M0, not mock every screen before proving Pi integration. Add small reviewable commits and tests with each milestone. Record unresolved SDK/version differences immediately in a compatibility note; fix the narrow adapter rather than spreading workarounds across Swift and React.

Required decisions are already made: native shell/composers, bounded web transcript, Pi SDK host, both specified APIs, and real request/response debugging. Remaining M0 choices are exact dependency versions, signing details, measured memory budget, and validated Pi hook/import names. These are explicit verification work, not a request to redesign the product.

Done means both files' required behaviors are implemented and validated. Do not call the app complete with only Responses, only normalized debug events, no explicit-only policy, an editing side by default, or a browser textarea substituted for the native composer.

## 18. Primary references and verification scope

External references support platform/compatibility facts; app-owned schemas, policies, algorithms, defaults, and targets above are this design. No test or benchmark described here has been run against an implemented app.

- [P1] [Pi createAgentSession / SDK source](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/core/sdk.ts).
- [P2] [Pi ModelRuntime source](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/coding-agent/src/core/model-runtime.ts).
- [P3] [Pi HTTP request options, custom fetch and usage types](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/ai/src/types.ts).
- [P4] [Pi OpenAI Responses adapter](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/ai/src/api/openai-responses.ts).
- [P5] [Pi Anthropic Messages adapter](https://github.com/earendil-works/pi/blob/71dca871bc80b6bc97be37f0ca3189399d651fff/packages/ai/src/api/anthropic-messages.ts).
- [P6] [Pi SDK integration documentation](https://pi.dev/docs/latest/sdk).
- [C1] [Codex skill metadata, explicit policy, and disabled configuration](https://developers.openai.com/codex/skills).
- [C2] [Codex AGENTS.md discovery](https://developers.openai.com/codex/guides/agents-md).
- [O1] [OpenAI Responses HTTP streaming](https://developers.openai.com/api/docs/guides/streaming-responses).
- [A1] [Anthropic Messages streaming, event shapes, and cumulative usage](https://platform.claude.com/docs/en/build-with-claude/streaming).
- [M1] [Apple WKWebView](https://developer.apple.com/documentation/webkit/wkwebview).
- [N1] [Node Web Streams](https://nodejs.org/api/webstreams.html).
