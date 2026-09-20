# Twenty-session concurrency review

Date: 2026-09-19, Asia/Singapore. Baseline: Bello Agent 0.1.50, source
`603fccb`. Released: 0.1.51/build 55. Native Swift application and helper.

## What failed and what changed

Independent model streams already overlapped, but the surrounding app had limits
that made twenty-session operation unreliable. These changes preserve the native
architecture and project editing gate.

| Defect | Change | Regression evidence |
| --- | --- | --- |
| Helper capture rejected producers beyond one active delivery plus 16 waiters | Suspend producers FIFO with one outstanding packet per producer | Baseline lost 3 of 20 capture beginnings/finishes; pressure test now preserves all |
| One absent ACK cascaded into a separate timeout for every waiter | First ACK timeout closes the channel and releases queued producers; negative ACKs remain packet-local | Deterministic timeout test verifies one emitted packet/deadline instead of 20 |
| Native archive allowed only 32 body writers, effectively 16 persisted attempts | 128 bounded body writers allow 64 simultaneous persisted attempts | Forty interleaved captures retain exact bytes after reopening |
| Live-memory trimming excluded active attempts | Trim active attempts to contiguous prefixes and label memory truncation; durable bytes remain independent | Injected 16,000-byte cap formerly retained 51,541 bytes; regression enforces the cap and durable offsets |
| Native command 33 failed instead of waiting | 32 dispatched slots plus bounded FIFO of 128; Stop bypasses ordinary admission | Eighty concurrent real-helper commands; cancellation and late-ACK capacity tests |
| Stop/capture ACKs consumed ordinary pipe-write slots | Control traffic uses separate accounting | Saturated ordinary writes still admit Stop and capture ACK |
| Legal snapshot bursts exceeded a 2 MiB UI inbox and killed the host | Retain the 64-frame bound with a matching legal-frame byte budget | Twenty 150 KiB snapshots survive a busy MainActor; 65 noncoalescible frames still fail |
| A ready process was treated as an initialized project; duplicate session opens could outrun capture preferences | Share project startup through workspace binding and session startup through capture-mode ACK | Twenty cold sessions and twenty callers to the same session |
| Credential reads could finish after shutdown; connection changes could overtake a cold open | Terminal startup guards, shared-task cancellation and in-flight session-open tracking | Gated credential-read/shutdown and connection-switch tests |
| Capture ACKs waited for UI accounting; background refresh rebuilt hidden attribution | ACK after durable storage, enqueue presentation work separately, coalesce totals/timing updates | Twenty background chats and 1,000 accounting invalidations |

## Real helper and gateway proof

`scripts/test-concurrent-native-host.py` launches the packaged Release helper and
a request-aware local HTTP/SSE gateway. A barrier refuses to complete the first
round until **all 20 HTTP requests are simultaneously in flight**. Each session
must request its own file, receive its own real tool result, then enter a second
20-request barrier. The fixture independently validates request structure, tool
IDs/results and credentials; it does not serve a canned response regardless of
the request.

Both one-project and four-project runs pass with **20 tool round trips, 660 text
deltas and 80 exact captured request/response bodies** per run. Authentication
headers remain masked. Capture acknowledgments are deliberately delayed by
10 ms to exercise producer backpressure. The runs took 30.943 s and 4.648 s on
this machine under that synthetic recorder delay; these are correctness checks,
not gateway speed or UI frame-rate benchmarks. The baseline used fewer deltas,
so its elapsed times are not a performance comparison.

The 0.1.50 single-project baseline reached both HTTP barriers and returned the
correct tool results but retained only **34 of 40 attempts**. The mixed
cancel/error/follow-up baseline retained **18 of 21 attempts**. The new helper
retains the complete expected attempt sets. The mixed test keeps twenty streams
open, cancels one, fails another, completes the unaffected eighteen and executes
one queued follow-up in only its intended session. No retry or cross-session
delivery is allowed.

The final mixed-case assertion also waits for the gateway to observe the stopped
connection closing before releasing the other streams. Its cancelled response
is an exact nonempty 121-byte prefix marked partial/cancelled; the provider error
retains its complete EOF body marked failed. All 21 attempts remain available.

Full helper tests: **176 passed, zero failures**. Existing packaged HTTP/SSE/MCP
tests: **24 passed**. Process crash/restart acceptance: **2 passed**. Native
acceptance and final distribution evidence are recorded in the
[0.1.51 validation record](validation/Bello-Agent-0.1.51-2026-09-19.md).

The final native test exercises the whole app path, not just separate layers:
twenty cold `WorkspaceModel.send` calls, the packaged helper, two HTTP barriers,
twenty tool round trips, native capture delivery, then a reopened archive with
eighty exact bodies. All twenty sessions automatically report two requests,
220 gateway tokens and $0.002 each without selecting them or refreshing metrics.
It completes in 2.274 s on this fixture. A MainActor heartbeat sampled 345 times
with an 8.43 ms maximum gap. These numbers are observations under synthetic local
load, not screen-paint timings or guarantees. Twenty cold opens in the separate
startup test took 65.97 ms, followed by 121.76 ms to settle refresh bursts.

Native acceptance has **137 distinct passing cases**. Initial test-only Swift 6
compile errors and missing synthetic dispatch metadata were corrected; the
final focused run passes without changing the production accounting contract.

## Concurrency boundaries

- Per-session Swift actors and asynchronous networking allow model requests to
  overlap. This does not allocate twenty dedicated OS threads. The UI remains
  MainActor-owned; storage mutations remain serialized by their archive actor.
- Write/edit/bash/MCP invocation intentionally take turns within a project.
  Cancelling a waiter must never execute its edit; other projects have their own
  gates. A session does not hold the editing gate for its entire model run.
- Read/list/find/grep currently run synchronously inside one `NativeTools` actor
  per project. A long search can delay other file tools and tool-definition
  requests there. Already-dispatched model requests continue. Parallel file-tool
  execution needs a separate bounded I/O design and is not claimed here.
- The 128 MiB live capture budget bounds retained body buffers, not total process
  RSS. Durable capture has its own disk quota/retention and 64-attempt writer
  capacity. Twenty active sessions can create more than twenty HTTP attempts over
  time; completed attempts release their body writers.
- A provider or deployed gateway can impose its own limits. These tests use a
  synthetic loopback gateway and no production credentials. They establish app
  behavior, not a twenty-request guarantee from every remote provider.
- The large-history rendering limitation recorded in the
  [0.1.50 performance review](Performance-Review-2026-09-19.md) is unchanged.
  No universal frame-rate claim or install/update rehearsal is made.

## Evidence locations

Session scratch: `tmp/concurrency-051-20260919`, including `wire-before.log`,
`wire-after.log`, `wire-mixed-reviewed.log`, native Release result bundles and the release/public checks.
Helper tests: `tmp/review-concurrency-0.1.51/helper`, including
`capture-before.log`, `pressure-before.log`, `pressure-after.log`, and
`full-after.log`. All paths are under the current remote session temporary
directory; no logs containing user data are published.
