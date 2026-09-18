# Dependency compatibility record

## M5 display and measurement boundaries

The visible main transcript reuses one WKWebView when switching chats; its
session identity resets scrolling, pending delivery and stale acknowledgements.
Native composers remain distinct per session so Undo cannot pull text from a
different chat. Three native indexes retain only bounded record offsets/parent
links; device/inode/size/mtime/ctime validation invalidates edited or replaced
files. Browsing history never starts Pi or sends it a rendered projection.

Pi partial messages are projected only when a foreground snapshot is requested.
Dirty host displays schedule one 16 ms flush, with no polling timer at idle.
Native drops unchanged publications, and context/elapsed/request footer values refresh
at 4 Hz; full precision attempt data remain in the host and native inspector.
Native request timeout tasks are cancelled on acknowledgement and bounded by the
32 outstanding-command limit. These changes do not reduce raw capture coverage.

Opt-in `BenchmarkOutput` plus `BenchmarkStateRoot` defaults isolate synthetic
native state and record bounded timing samples only. They are unset in normal
use. Measurement uses native edit events (not Send) to NSTextView draw, launch
date to first shell draw, and calibrated host/WebKit monotonic clocks. The
visible-paint metric uses a post-frame task plus the minimum of five WebKit
round-trip uncertainties; the older acknowledgment metric remains separate.
Neither measures physical display scanout. Fixtures and real UI measurements,
not probes alone, determine M5 acceptance. Native edit drawing flushes only the
visible composer’s invalidated region after key handling, before processing
background stream work.

The bundled manifest pins V8 to 384 MiB old space and 8 MiB semi-space. This
is a garbage-collection/heap budget, not a process RSS cap; captured Buffers,
native modules, WebKit and AppKit remain in aggregate measurements. The default
V8 heap allowed reclaimable large-turn allocations to push aggregate RSS above
1 GiB. Both provider/tool/capture stress suites and final paired native streams use
384 MiB; the 40-turn native plateau was measured with the intermediate 512 MiB
bound. Raw retention remains 128 MiB and full Pi history is
not truncated to satisfy the budget. Host exhaustion still follows interrupted
recovery with no automatic request replay. `runtime.info` reports actual flags
and V8’s heap limit, checked by the native launch test and packaged smoke test.

## M5 pinned Anthropic SSE parser correction (2026-09-14)

The 1 MiB fixture exposed an upstream 0.85.1 framing defect that TCP coalescing
had hidden in the smaller M0 fixtures. A read ending in CR followed by a read
starting in LF prematurely dispatched an event-only record, producing
`Could not parse Anthropic SSE event content_block_delta`. This is a real
provider-parser failure, not a capture error.

`scripts/patch-pi.py` changes only `consumeLine` in the installed unbundled
`pi-ai/dist/api/anthropic-messages.js`: hold a trailing CR until its following
byte is known, and permit it at EOF. It patches both the direct and nested SDK
copies, requires version 0.85.1 and upstream SHA-256
`f748560c80fe91bb5736b62f6f34c5e2e2bfa224cd5eb959134ca903c226b604`,
and produces SHA-256
`cabc7550eef22362b9d6fada1dfe57de4ed3ddbcdde5c993e288c69bae9eaf72`.
Unexpected source or partial patches fail the build. The app does not invoke
Pi's bundled CLI chunks. Dependency archives and the npm integrity lock remain
unchanged; packaged `pi-patches.json` records the reviewed modification.

The test and bundle workflows apply this patch explicitly. Three regressions
use the public Pi runtime with a synthetic fetch returning exactly one byte per
read, including CR/LF, bare CR at EOF, LF and split UTF-8. All yield the complete
message and byte-identical request/response capture. The recorder still passes
each original chunk unchanged; no newline rewriting, event normalization or
replacement agent/provider loop is involved.

## M3 resource resolution (2026-09-14)

The app owns discovery and policy; Pi 0.85.1's duplicate name lookup and default
context discovery are not used. Public `ResourceLoader.getAgentsFiles/getSkills`
and `setActiveToolsByName` retain Pi's base prompt while rebuilding it at idle
turn boundaries. This avoids `AgentSession.reload()` resetting the global API
provider registry during another session's run. No private SDK imports are used.
Pi's `/skill:name` rereads by name, so the app expands hash-verified, frozen source
through public `prompt(..., { expandPromptTemplates: false })` exactly once.
Its path and original base directory remain in the expansion. Scripts never run
as part of discovery or expansion, and there are no executable extensions.

The compatible Codex inputs are `agents/openai.yaml` invocation policy/tool
dependencies and `[[skills.config]]` disabled paths. Restrictions combine with
Pi `disable-model-invocation` frontmatter and app overrides. Malformed mandatory
metadata blocks invocation until repaired; absent metadata alone does not.
Arbitrary prose is preserved, not treated as a verified policy classifier.
See the [official skill documentation](https://learn.chatgpt.com/docs/build-skills).

The instruction resolver implements global override/base and root-to-cwd
override/base/fallback ordering, including linked worktrees and cwd-only behavior
without Git. Its default 32 KiB combined budget counts original UTF-8 source
bytes; Pi's prompt headings/separators are additional prompt overhead. The app
caps configured discovery at 256 KiB and each source read at 1 MiB, with visible
diagnostics. This is documented compatibility with the
[instruction guide](https://learn.chatgpt.com/docs/agent-configuration/agents-md),
not a claim to reproduce all Codex sandboxing, descendant enforcement or settings.

YAML 2.9.0 and smol-toml 1.8.0 are exact direct dependencies. Discovery is capped
at 5,000 entries, depth 12, 512 skills and 2 MiB retained skill source per snapshot;
individual skill files are 256 KiB, YAML 64 KiB, TOML 1 MiB. Aliases and custom
YAML tags cannot expand executable/custom objects. Up to eight selected skills
and 16 KiB arguments each count toward the existing 256 KiB submission and 2 MiB
queue budgets. Queued content stays frozen; changed/revoked metadata or missing
dependencies fail before the next Pi dispatch. File watches are advisory; every
new turn rereads configured sources. Persisted grants record the turn and source
hashes, and raw HTTP attempt metadata records the applied resource revision.

## Distribution prerequisite

- Xcode 16.1 (16B40), Swift 6.0.2, strict Swift 6 concurrency, macOS 14+,
  arm64. XcodeGen 2.44.1 generates the committed project.
- Sparkle 2.8.1, revision `5581748cef2bae787496fe6d61139aebe0a451f6`, matches
  BelloBox's pin. The Objective-C updater delegate lacks Swift actor isolation
  annotations; its main-thread delegate conformance uses `@preconcurrency`.
  The application and updater state remain `@MainActor`.
- Release code uses archive Ed25519 signatures, not features introduced by
  newer Sparkle versions. Native app hardened runtime remains enabled in
  Release; Debug alone disables it for XCTest injection.

## Pi / Node M0

Selected: published `@earendil-works/pi-coding-agent` and `@earendil-works/pi-ai`
**0.85.1**, with npm integrity and transitive versions in `package-lock.json`.
The design's inspected commit `71dca871bc80b6bc97be37f0ca3189399d651fff` also
declares 0.85.1; the application dependency is the published archive, not a
moving Git branch. Node **24.21.0** (npm **11.19.0**) comes from the official
darwin-arm64 archive verified against the committed SHA-256 in
`scripts/runtime-lock.json`. TypeScript 5.9.3 checks host-owned adapters.

Confirmed in the installed package: `ModelRuntime.create`, supplied runtime in
`createAgentSession`, string tool allowlists, instance-local `stream` and
`streamSimple`, and the HTTP `fetch` option. Complete helpers call the stream
methods. Both real providers now pass synthetic tool, streaming, manual
compaction, save/resume, request-schema and exact transport-byte fixtures.

Observed upstream limitation: `EventStream.result()` resolves the final result
without draining its event queue; `ModelRuntime.complete`/`completeSimple` call
only `.result()`. A complete-only call can therefore retain all normalized
events until collection. The app adapter must drain those two complete paths,
without adding another capture/request ID or replacing raw transport capture.
This is a memory correction to the suggested wrapper implementation, not a
new compaction algorithm or a replacement agent loop. Real Pi compaction
integration tests cover both a history summary and a separate turn-prefix
summary, each with its own captured logical request.

The pinned compactor does **not** normally call `ModelRuntime.complete`:
`completeSummarization` awaits `agent.streamFunction(...).result()`. The SDK
session's stream function delegates to the supplied runtime's `streamSimple`,
so the same fetch instrumentation covers this path. The adapter uses Pi's
public `isCompacting` state when allocating immutable call context and drains
that unused normalized queue as well. Normal agent streams keep their single
Pi consumer. No provider SDK or compaction algorithm is replaced.

Anthropic's HTTP-200 stream-error path can settle Pi without completing the
fetch-body iterator. The recording fetch therefore exposes an app-private
finalizer called when the Pi stream result settles. It cancels/releases any
remaining reader and marks the response prefix-only, without reading extra
bytes or claiming EOF. The original user abort signal is tracked separately
from SDK-internal transport aborts. A provider parse failure is not reported
as a user cancellation. Both provider error fixtures verify this behavior.

HTTP failure status alone does not mean a body has finished: memory eviction
and attempt retention use explicit transport-active state. This prevents an
in-flight 500 body from evicting its own retained prefix.

## Packaged M0 runtime and transcript

React/React DOM and their types are pinned to 19.3.0; esbuild to 0.28.2.
The app bundles compiled host JavaScript, production dependencies, Node and
the offline transcript. No globally installed Node or Pi is used at runtime.
The published Pi archive contains bundled esbuild packages for many platforms;
the arm64 product removes only non-darwin-arm64 `@esbuild` packages and records
every removed path in `platform-pruning.json`. Host source/API logic is unchanged.

The signed Node helper needs only `allow-jit` on the tested macOS 14.8 build.
Native addons and esbuild are signed before the outer bundle; the native UI
does not receive JIT or library-validation exceptions. Packaged provider smoke
tests run after signing. See [M0Validation.md](M0Validation.md) for evidence.

## M1 command retention

The bounded host ledger retains every mutating command receipt for its epoch
(4,096 commands), rather than evicting IDs and risking duplicate effects. At
capacity it rejects new mutations before dispatch and requires an idle host
restart/new epoch; previous IDs still return their recorded result. Read-only
queries and idempotent Stop do not consume receipt capacity. Native durable
intent reconciliation remains necessary across epochs; an old command is never
automatically replayed merely because the process restarted.

## M1 Pi persistence and recovery

Pi's `SessionManager` defers its first disk flush until an assistant message
exists. App command entries before the first request therefore cannot prove
that request never started after a crash. Native intent journaling must retain
**Outcome uncertain** in that gap; there is no cross-file atomicity claim.
Once Pi appends the first assistant/tool-call message, the preceding app command
receipt is flushed as well. A SIGKILL test after a real synthetic tool effect
verifies this persisted receipt, zero execution on reopen, and no tool replay
when the user explicitly submits a new continuation. Pi supplies the missing
tool-result protocol record during that explicit continuation.

Writable resume is restricted to the managed directory. CLI continuation first
validates and takes an immutable byte snapshot through an open descriptor,
checks source identity/size/timestamps again, and forks the snapshot with Pi's
public `SessionManager.forkFrom`. The completed managed copy is published
atomically without overwriting an existing file. Source hash/path provenance
and the original snapshot are retained; the CLI original is never opened by a
writable Pi manager.

The app rejects invalid UTF-8/JSON, missing final newlines, unsupported versions,
invalid v3 parent references and compaction boundaries before Pi's permissive
JSONL parser can skip damaged data. Initial active-file limits are 128 MiB per
session file and 32 MiB per record. Oversized/damaged originals are preserved
and require an explicit recovery/continuation action, not silent truncation.
These are visible app limits required for bounded runtime loading.

The adapter uses `prompt(..., {streamingBehavior: 'steer',
expandPromptTemplates: false})` for resolved steering text. Pi's `steer()`
convenience method would expand skills/templates again. Stop clears Pi's
undelivered steering queue and independently pauses app-owned follow-ups.

### M1 import finalization and native delivery

Pi 0.85.1 also defers custom-entry persistence in an imported file without any
assistant message. Import/recovery finalization therefore serializes the public
`getHeader()` / `getEntries()` Pi-format snapshot at an isolated staging path,
validates it, and atomically publishes it. This preserves unflushed provenance
without inventing an assistant message or using a private flush method. It is
never used to rewrite an active session or reconstruct input from UI text.
Explicit tail recovery retains the entire original first, drops only an
unterminated final record in a new copy, and rejects earlier corruption.

Display delivery uses conflated `session.changed` notifications and bounded
snapshot pages instead of forwarding each normalized token event through Swift.
The normalized event journal remains a separately labeled, bounded preview;
it is not HTTP capture. Host epochs and runtime reopen reset sequence baselines.
Native/renderer queues are bounded, and archived browsing uses a native read-only
Pi JSONL index without a host. UI pages retain at most 101 messages / 500 kB;
host pages use 60 messages / 300 kB plus a bounded active message. Full retained
message text is read in 16,384 UTF-16-character pages in a native viewer.

Ad hoc test signatures change Keychain's code identity between builds. A real
UI test exposed a blocking macOS Security lookup on the main thread. Credential
operations now use one bounded background worker with a ten-second UI deadline,
noninteractive read context, and no automatic provider dispatch on lookup failure.
The release uses the stable Developer ID identity recorded in Release.md.

Steering is separately capped at sixteen submissions / 2 MiB per owning turn;
its receipts settle with that turn. Queued follow-ups have the same count/byte
limits and remain paused after Stop. Compaction has its own durable command
receipt while provider capture retains purpose `compaction` and the appropriate
nullable turn association. App/host scheduling and these caps are desktop
policies, not additional Pi agent loops.

### M2 configuration and inspection seams (Pi 0.85.1)

- `ModelConfig`, `ReadOnlyAuthStorage`, and the config-value resolver are not
  exported by the package. Discovery uses public `ModelRuntime.create` with an
  in-memory credential/model store, network/availability refresh disabled, and a
  bounded, hash-checked models.json. It does not call `getAuth` or any model.
- Existing Pi auth.json is read through exported `readStoredCredential`; only
  API-key credentials are supported. Activation resolves public `getAuth` in a
  disposable worker so Pi's synchronous `!command` resolver cannot block Stop.
  Executable references require profile-specific trust. A changed models.json
  requires refresh. The worker neither rewrites auth.json nor imports Codex auth.
- Resolved headers enter the public stream options, avoiding a second round of
  Pi `$ENV`/`!command` interpolation. Unknown/auth headers remain redacted in the
  recorder. Profile model limits, inputs, reasoning map, sampling, and supported
  compatibility fields reach Pi registration without replacing them with UI defaults.
- The app resolves root/base/full API endpoints to each Pi adapter's base URL;
  credentials in URL query/userinfo are rejected in favor of header credentials.
  Pi adds `?beta=true` to Anthropic thinking requests. This is preserved and
  captured (its query value is redacted in metadata), not a doubled Messages path.
- Unbound imported history with opaque/signature-bearing state cannot prove its
  endpoint affinity. It requires an explicit portable handoff; source files stay
  intact. Same-API text-only continuation still retains the original Pi entries.
- Raw SSE events are indexed as byte ranges into the sole captured response:
  1,024 ranges per attempt / 16,384 per workspace; omitted index entries are
  counted. Index exhaustion does not truncate the raw body or Pi's stream.
  UTF-8, hex and pretty JSON are derived native views, never replacement bytes.
- Imported thinking defaults resolve model-specific settings before global
  settings in the sibling Pi settings.json, then Pi 0.85.1's `medium` default.
  Settings and model files are both hash-bound; the inspector also shows the
  effective Pi-clamped level. Project-specific Pi setting overlays are not
  silently loaded; explicit app profile overrides remain visible.
- Image references are bounded (4 / 16 MiB per turn; 8 MiB per file; 32 MiB
  queued/steering reference budgets), hash-checked at execution, and passed to
  public Pi prompt `images`. Pi retains authoritative image inputs; React sees
  only an attachment marker. No arbitrary renderer filesystem bridge is added.
- A portable handoff is an explicit, editable new-chat draft from Pi's public
  compaction-aware context, capped at 128 KiB. It omits thinking, opaque state,
  images, and tool-call arguments, and never claims to be a lossless resume.
  The original and a byte-identical snapshot remain intact. Pi's in-memory
  manager performs any format migration without rewriting that snapshot.

## M4: independent side sessions (Pi 0.85.1)

- Pi emits `message_end` before synchronously appending that entry. The app
  refreshes a bounded immutable boundary cache in the following microtask from
  public `buildContextEntries()` and `getBranch()`, never the mutable assistant
  stream or React projection. Opening a side selects that cached boundary
  synchronously; creating its runtime does not hold the parent's execution lane.
- A usable boundary excludes failed, aborted, length-truncated assistants and
  unmatched tool groups. Completed user entries may be included. Its 32 MiB /
  20,000-entry limit rejects the operation visibly; it does not silently fall back
  to older context. Resource revision and omitted-entry count remain visible.
- Public `SessionManager.inMemory(cwd, {id}, entries)` creates a fresh header when
  entries exclude the old header. Semantic tool IDs and provider signatures stay
  intact for the same profile. Entry parent links are rebuilt around a new
  non-context anchor; public `buildSessionContext` equality is asserted before
  installation. Pi may retain an older compaction summary within a kept range;
  each summary in Pi's effective context is preserved exactly once.
- The selected plain Responses SSE adapter uses `store:false` and a session-based
  `prompt_cache_key`; it does not send `previous_response_id`. A new session ID,
  ModelRuntime, agent and cancellation token isolate side affinity. Codex-specific
  Responses WebSocket continuation is outside the two selected APIs.
- Pi has no public switch from an in-memory manager to persistent operation.
  Keep writes public Pi entries to a private staged file, validates and fsyncs it,
  then atomically publishes without overwrite. A new idle adapter opens that
  file under the same side identity. Failure before publication preserves the
  in-memory side. The parent manager and file are never mutated.
- Side tools are `read`, `grep`, `find`, `ls`, enforced by the active registry and
  an additional bundled `tool_call` policy hook. No filesystem extensions or
  executable skills are loaded. This is tool policy, not an OS filesystem sandbox.
  Historical skill text remains context; its old explicit grants are inactive.
- Unkept sides inherit Off or memory capture only. Keep is explicit, at idle with
  an empty queue, or explicitly deferred until that boundary. Closing an unkept
  side removes its in-memory capture metadata/bodies. Persistent tracing can be
  enabled only after Keep. Runtime creation/retirement serialize separately from
  the independent editing and read-only model lanes.

## M5: lifecycle and bounded native presentation

- Update installation takes a synchronous native barrier, then a host barrier
  that drains accepted asynchronous preflights and checks authoritative lanes.
  Active work or an unkept side rejects installation. New work stays blocked
  while drafts flush and every host exits. Sparkle 2.8.1's public postpone hook
  resumes installation only afterward; a failure re-enters its relaunch veto.
- UTF-16 paging (Cocoa offsets) never splits surrogate pairs. Middle-of-codepoint
  input offsets fail visibly. Retained message and skill viewers keep exact
  previous page offsets. These are derived text pages, never raw HTTP bytes.
- Native pipe parsing applies backpressure instead of accumulating Data blocks.
  Receipts retain 128 records per chat; deletion removes receipts, capture
  preference, handoff and Keep metadata along with the chat and trace artifacts.
- Profile source reads now use bounded descriptors with replacement/growth
  checks. Locked or timed-out Keychain reads cannot silently clear saved headers.
- The web bridge accepts only its exact local main document and file origin.
  The final active window remains visible until work and unkept sides are handled;
  Quit remains an explicit stop/discard action. Composer text is capped at 256 KiB
  before insertion, preserving the existing draft if a paste exceeds the limit.
