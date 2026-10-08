# Project-scoped Streamable HTTP MCP

This bounded vertical workflow uses the existing saved project authority and
`SavedRuntimeFactory`. It is not a second fixture-only runtime. Ordinary and
all-feature app startup still leave production/native storage and tools closed;
only the explicit existing synthetic authority route permits this preview.
Real Keychain, signing, credentials and native macOS interaction remain separate
acceptance gates. Fixtures use numeric loopback and fixed fake header values,
with no paid provider calls or external MCP traffic.

## Source and visible workflow

The concurrency behavior is pinned to Swift main `f4f80ddda3c27fac9e266896f69b725a06242e8f`
([immutable MCP source](https://github.com/BelloWare/BelloAgent/blob/f4f80ddda3c27fac9e266896f69b725a06242e8f/packages/swift-host/Sources/PiAgentCore/MCP.swift)). Earlier behavioral anchors include `MCP.swift:272–349,385–564`,
`ConfigurationVault.swift:320–349`, `WorkspaceConfiguration.swift:334–432`,
`ResourceInspector.swift:315–479`, and `SessionTools.swift:28–72,95–143,172–233`.
The Inspector edits a project's HTTP server JSON, with credentials in the reviewed
shared masked replacement input. General JSON cannot contain headers. Blank
replacements preserve headers for the same named endpoint, `{}` clears them, and
an endpoint change requires an explicit replacement or clearing. Loaded secrets
never repopulate either input. Explicit trust confirmation precedes saving.

Configuration changes acquire one manager reservation plus loaded Controller
idle-admission guards and unloaded idle inspection leases. Whole-envelope byte
CAS saves before apply; cancellation, uncertainty or failed apply after a save
keeps the old actors fenced. Unknown outcome evidence survives configuration
changes and server removal. A separately edited vault configuration can be
reloaded and reviewed even when the old manager is no longer current; an explicit
save/apply operation reconciles it. Receipt-read failure cannot discard a fresh
configuration baseline or silently relax invocation authority.

List/describe never invoke a tool. The provider sees exactly one `mcp` wrapper,
not every server schema. Server data remains untrusted, and no server instruction
becomes a system instruction. Each invocation requires an explicit saved Editing
mode, regardless of server annotations. Existing ordinary-chat Editing defaults
and every saved explicit mode are preserved. Genuine saved ReadOnly chats expose
the existing source-backed, one-way Enable Editing confirmation.

All factories and chats for the same workspace owner share one manager. Model
invocations take shared active admission and may overlap on the same HTTP server,
across servers and with native editing or Bash. Configuration takes exclusive
admission and still refuses completed receipts awaiting durable retention before
the vault CAS. Active admission ends after normalization, before a completed
Ticket is returned; retaining it in a Ticket would deadlock late batch siblings
behind a fair configuration writer. Full saved chat, connection, project and exact
MCP configuration checks run outside actor/catalog locks after admission waits and
again immediately before dispatch. Inspector one-shot work has separate fail-fast
exclusive admission and refuses pending receipts. It uses a Controller-owned
joined worker and idle-admission guard; Stop, retirement, dropped callers and
window lifecycle cannot detach a live invocation or release its writer early.

The canonical outcome-file location has its own nonblocking exclusive OS writer
lease, independent of a workspace catalog's lock. Distinct `--session` catalogs
in the same directory cannot open competing managers for the same project; the
second owner is rejected before marker access or network dispatch. Its stable
private lock sidecar is never unlinked on release. The ledger owns the lease,
so outstanding tickets and physical receipt/settlement work retain it even after
the workspace or caller is dropped. Same-workspace first construction is
serialized outside the catalog mutex. Root re-trust may rebind that workspace's
existing manager to fresh exact authority while sharing its ledger and operation
gates; unresolved evidence survives, old authority is fenced, and transport and
catalog caches are rebuilt. No separate catalog can borrow this lease.

## HTTP and catalog bounds

Only Streamable HTTP is implemented. stdio is explicitly unsupported, including
its command/environment lifecycle. URLs have no embedded credentials, query or
fragment, and require HTTPS or loopback HTTP. Synthetic provenance further
requires numeric loopback and known fixed fake header values. Clients explicitly
disable proxies, redirects and reqwest's protocol-level retry policy.

The client supports protocol 2025-11-25 and 2025-06-18, lazy initialize/initialized,
Mcp-Session-Id, protocol headers, bounded JSON responses and chunked SSE. Priming
and data-less events are ignored; list-change notifications invalidate cached
catalogs. Per-server connection/catalog setup is single-flight, while tools/call
clones the transport and releases discovery locks before network I/O. Transport
mutable state uses short snapshot locks and a session epoch: delayed old-session
404s or session headers cannot invalidate or replace a newer session. Catalogs
are scoped to their exact transport and list-change generation. The optional GET channel, server-initiated capabilities, sampling and
elicitation are not offered. Each response, including all SSE bytes, is limited
to 4 MiB and 2048 events, with a configured 1–300 second timeout. Catalogs have
1000 tools per page, 2000 total names, 100 unique cursors, a 4 MiB aggregate bound,
unique names, object schemas and explicit allowlists. An omitted allowlist permits
all catalog tools, an empty array permits none, and a present null or non-string
array is rejected before saving. Describe accepts 1–32
server/tool pairs and remains bounded.

Disconnects, timeout, cancellation, malformed/incomplete replies, mismatched IDs
and 5xx responses never automatically replay invocations. Only HTTP 404 carrying
an established session ID proves that the server did not process that request;
that source-backed case can reinitialize and resend once. Repeated expiry stops.
The source JSON-RPC request-rejection codes and selected explicit HTTP refusal
codes are recorded as not executed. Other remote errors remain unknown.

## Durable outcome safety difference from Swift

Swift removes its marker after HTTP success. Rust deliberately retains evidence
until the canonical result checkpoint is positively durable, following the
existing Rust Unknown/recovery contract. This is a conservative safety extension,
not a claim of byte-identical Swift behavior.

MCP persistence has its own four-physical-closure executor, separate from native
file/image/Bash workers. Pre-effect permit waits can be cancelled. Each submitted
blocking closure owns its permit through physical return; dropping an awaiter
cannot free capacity prematurely. Post-effect settlement is independently owned,
including queued work, and retains its ticket and OS lease. No persistence permit
is held across network or native-pool waits. Ticket target metadata is immutable,
and a contended Ticket drop closes admission immediately then schedules cleanup
without blocking a Tokio/UI thread on a mutex held through fsync.

Before `tools/call`, a private atomic/fsynced project ledger records an invocation
UUID and bounded server/tool identities, never URLs, headers or arguments. Up to
64 unresolved results are allowed. Successful calls carry settlement receipts;
a normal Controller batch removes only its own IDs after its ordered result
checkpoint commits. This supports multiple concurrent MCP calls in a batch
without clearing another chat's unresolved result. Dropping or failing to retain
a receipt quarantines the manager. Any unresolved ledger entries on restart also
quarantine the project. Failed or uncertain session/result writes do not remove
the marker, even when new checkpoint bytes can be read.

Inspector one-shot results have one bounded, private, canonical latest-result
receipt per project. It includes project/invocation/server/tool identity and
normalized content, without duplicating chat result payloads. Reopening validates
and displays the previous receipt without reexecution or marker clearing. It may
precede a later unresolved invocation, so the UI labels it as a retained result.
Reading bytes does not establish a formerly uncertain checkpoint's durability.

If the canonical result was positively durable but the subsequent marker cleanup
fails, the live manager remains quarantined. On restart, a retained pending ledger
still quarantines; a possibly committed empty housekeeping ledger can recover as
settled-known because the canonical result had already been confirmed. This is
different from uncertain canonical-result persistence, where marker removal is
never attempted. No rollback or inference from an HTTP success is used.

Acknowledgment requires explicit review confirmation and the exact current
unresolved-ledger fingerprint. A delayed confirmation cannot acknowledge a newer
unknown outcome; active invocations and uncheckpointed results block it. It does
not retry, undo or cancel any previous effect.

## Content, replay and snapshot v6

MCP text is retained, structuredContent is appended as explicit structured-data
text, supported image bytes stay typed, and audio/resource/other payloads become
short descriptors rather than base64 context dumps. Known configured header
values, including bearer-token suffixes, are redacted before UI, provider or
receipt exposure. This does not promise to discover arbitrary secrets in remote
content. Native macOS image normalization reuses the existing bounded ImageIO
worker path; Linux retains already-supported bounded images and never claims
native decoding/resizing acceptance. Invalid/unsupported images have explicit
omission text. Large text uses the existing private full-output file and bounded
preview while retaining images. The existing per-result and per-batch budgets
remain enforced.

Explicit `isError: true` is Failed, not Completed or Unknown. Snapshot v6 permits
retained Failed content only for its matching `mcp` call owner with is_error=true
and no forged native file statistics. Unknown content remains forbidden. Older
v1–5 snapshots retain existing read behavior; a v5 record claiming Failed content
is rejected without rewriting its bytes. Replay uses canonical retained content
and declared model image capability, never network calls or historical execution.

## Evidence and remaining gates

Injected-storage and numeric-loopback tests cover configuration validation/CAS,
secret preservation/clearing/redaction, catalog and schema/cursor limits, JSON and
chunked SSE, notifications/cache/expiry, no inherited proxy or followed redirect,
exactly one wrapper, read-only refusal, shared admission cancellation, dropped
Inspector callers, same-batch receipts, Controller continuation/reopen, v6 negative
ownership cases, marker/canonical-result crash cuts and explicit acknowledgment.

GPUI/host tests exercise explicit save/discovery/description/invocation,
one-way Editing confirmation, stale/project-changed callbacks, retained drafts,
uncertain apply fencing and unknown outcome recovery. Actual computer-use evidence
must be recorded against a final immutable copied binary and matching source
manifest. Automated GPUI tests are not actual desktop or native macOS acceptance.
See `mcp-gui-acceptance-recipe.md` for the disposable no-cost manual fixture.


## A5 reconstruction acceptance

The reconstructed concurrency tests include same-server overlap, single-flight
initialization, a sticky unknown sibling, the completed-ticket/fair-writer/late-
sibling deadlock regression, cancellable configuration drain, stale-session
response/404 fencing, physical persistence permit retention after dropped
awaiters, native-pool independence, and nonblocking ticket cleanup. These are
source additions, not a claim of passed tests. Record fresh runs at the final
integrated commit; historical GUI evidence above does not validate A5.
