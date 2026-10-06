# Opt-in read-only tool Controller

This checkpoint integrates `ls` with the actual Rust Controller and local Responses
transport. It is **core integration, not enabled desktop tools or source feature
parity**. Existing `Controller::new` / `with_configuration` callers offer no tools;
there is no new CLI flag, trusted-project UI, tool-card UI, or automatic opt-in.
No provider credentials, real model requests, or paid services are used by tests.

## Explicit host contract

`runtime::RuntimeOptions` is an immutable per-Controller value containing:

- `instructions: String`: already-resolved, frozen text. Empty by default. It
  performs no resource or credential discovery and does not implement the full
  source Resources prompt/skills/revision contract.
- `tools: Option<TrustedReadOnlyTools>`: absent by default. Construction is an
  explicit host assertion that project trust and read-only mode were chosen.
  It requires absolute primary/additional/home paths supplied by that host.
  It offers only the source `ls` schema, never shell, write, edit or MCP tools.

`new_with_options` and `with_configuration_and_options` are the explicit entry
points. Restoring a snapshot never restores execution authority. A reopened
Controller must be explicitly configured again. Root paths are **resolution
context, not a sandbox**: source-compatible absolute, parent, tilde and symlink
paths may leave them. Named-user tilde lookup remains unsupported. A desktop
adapter must explain that boundary when obtaining trust and read-only consent.

Sources: `apps/macos/PiApp/Workspaces/WorkspaceHosts.swift:23–34`,
`HostService.swift:336–344`, `Tools.swift:235–277` and `SessionTools.swift:55–76`
under `packages/swift-host/Sources/PiAgentCore`.

## Durable phases and replay

A request starts with the established non-replayable streaming assistant row.
For a completed tool reply, one durable checkpoint makes that row a complete,
replay-eligible typed assistant and preserves its original calls, arguments,
assembled provider items, text, reasoning and usage. When a terminal omits its
output array and the item still has empty arguments, the exact successfully
parsed streamed argument string is retained in that item; a malformed nonempty
terminal argument string remains authoritative and is rejected. The session remains Running and its
`active_reply` names that final row. This combination identifies the active tool
phase; historical calls by themselves never schedule work.

Before this checkpoint is accepted, continuation projection is validated. Invalid
call identities/history, malformed or missing argument JSON, incomplete terminal
responses, oversized projected requests, and unsupported same-connection opaque
reasoning fail visibly before tool invocation. No route proof is invented.

After the checkpoint succeeds, calls execute concurrently through the existing
four-active/64-waiting filesystem executor. Native `ls` schema preparation,
Unicode sorting, path resolution and validation are reused. Unknown/unoffered
tools become failed result rows without executing. All results are appended in
original call order once the whole batch settles. That same checkpoint starts a
new streaming assistant for the next model request. Pending steering can join at
that complete boundary, one item at a time; an edit hold leaves it pending.
Follow-ups wait until the tool loop would stop.

Snapshot version 3 already contains the typed records required here. The earlier
v3 reader requires the active row to be non-replayable and streaming; it rejects
an active completed-tool checkpoint before confirmation, recovery or rewriting.
Completed histories remain backward-readable. A probe using the already-built
pre-integration reader rejected a synthetic active-tool checkpoint with
`Running checkpoint has an invalid streaming reply`; the original snapshot's
SHA-256 was unchanged before and after the rejection.

Active-tool checkpoint admission also encodes its full potential interruption
recovery (one Unknown row per call) and reserves the existing 128 KiB safety
margin against the store's actual capacity. This check runs before invocation
and for every queue/edit checkpoint during the batch. There is no silent call
truncation or arbitrary batch-count limit. A 400-call, 256-byte-ID regression
covers tight-capacity rejection and interrupted reopen after a result-write fault.

Sources: `Providers.swift:56–62`, `SessionRun.swift:238–260`,
`SessionTools.swift:169–229`, `ResponsesInput.swift`.

## Stop, crash and uncertain persistence

- Stop wins a provider terminal race. A cancelled tool batch records its actual
  retained outcomes and pauses pending work; it does not send another request.
- Cancellation before the session invocation boundary records NotExecuted.
  Once invocation has begun, cancellation records Unknown, including a read
  cancelled while queued or while retaining output, matching the source's
  `toolInvocationsBegan` boundary. Queued reads still cancel without filesystem
  dispatch. A running read cooperatively checks the cancellation token. Its worker slot and Controller shutdown remain pending
  until an uninterruptible filesystem call actually returns.
- Reopening an active call checkpoint preserves completed calls and writes
  Unknown output rows. It does not claim they never ran and never invokes them.
- A result-checkpoint failure before rename preserves the previous checkpoint.
  Failure after rename blocks further writes. Reopen is authoritative: it either
  retains the committed results or records unknown outputs for the older phase.
- Explicit Retry starts a model request with retained call/result context. It
  never directly dispatches a previous call again. A new model reply can request
  new read-only work. Resume only starts pending user input.

There are no editing tools, external mutations or process-group cancellation in
this slice. The tool-loop has no new arbitrary round limit, matching the source;
there are also no automatic gateway retries.

## Large results and limits

Text through 64 KiB is retained inline. Above that threshold the full text is
written to a private uniquely named file under the Rust snapshot directory's
`tool-output` directory, synchronized before its path is referenced. The retained
row contains a UTF-8-safe 32 KiB preview and the full-output path. The directory
and files are created with 0700/0600 modes on Unix; symlink output directories are
rejected. Text above 16 MiB is refused. Failed output persistence becomes a
visible failed result; it never fabricates a usable full-output reference.

Source: `SessionTools.swift:94–149`. The source card timing/display fields,
images and MCP structured-content retention are not part of this text-only
integration. Output files may be orphaned by a crash before the result checkpoint;
there is no automatic cleanup or secure-deletion claim. Stored conversation and
tool outputs are plaintext in the same private Rust storage boundary.

## Verification scope

Focused checks are in `tests/production_tools.rs` and the unit tests in
`src/tool_runtime.rs`. They cover local synthetic request schemas, two-round
execution, call order, unsupported calls, frozen instructions, disabled defaults,
malformed/incomplete/opaque rejection, queued cancellation, batch/held steering,
retained large output, restart, explicit retry, and pre-/post-rename faults.
A Controller-level test holds an entered read using a test-only callback,
polls the real shutdown future to prove it remains pending, checks the occupied
worker slot, then releases the read and verifies its durable Unknown result.
Existing executor tests independently cover uninterruptible-call slot retention.

On 2026-10-06, after integrating instruction-discovery commit `267f6ef`, the full
205-test core checkpoint (106 unit and 99 integration), strict all-target core
Clippy and workspace formatting passed with offline/locked Cargo. Coverage
includes an actual SSE tool reply through execution, history and the next request.
After the source cancellation-outcome correction and canonical-path fixture fix
`7436518`, the affected eight tool-runtime unit tests, six loopback integration
tests, strict core Clippy and workspace formatting passed again. No new broad
suite pass is claimed for that small follow-up.

Four mutations were caught by assertion failures: removing dynamic recovery
headroom, continuation replay preflight, assembled streamed-argument retention,
or classifying begun-but-interrupted reads as Cancelled instead of Unknown.
The mutations were restored and the applicable checks rerun successfully. These checks do not compile or exercise the desktop
app, validate macOS filesystem behavior, or contact a real provider.

Source output-token-limit automatic re-issue, general built-ins, full routing and
opaque-reasoning replay, complete prompt/resources, live tool cards, trusted-project
persistence/UI and native desktop acceptance remain separate work. Incomplete
call replies safely stop for explicit Retry in this bounded core slice.
