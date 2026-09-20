# Crash audit implementation — 2026-09-20

Based on the owner's uploaded `Crash-Audit.md`. Reviewed and fixed on top of
`ce3c764f87fa565fd32ea31ed013fcef6d7032a2`, preserving the preceding performance
work. No subagents were used. The release target is **0.1.61 (65)**.

## Production crash confirmed

The retained **shipped 0.1.60** application dSYM has UUID
`324557FC-DD6B-3FAA-98F0-9D5AE1188FE7`, matching the report. `atos`, with load
address `0x102dc8000`, resolves the two application addresses as follows:

| Address | Symbol |
| --- | --- |
| `0x102f2480c` | `closure #1 in GitWorkingTreeWatcher.start()` |
| `0x102f267cc` | `specialized gitWatchCallback(_:_:_:_:_:_:)` |

This confirms the source match for the reported actor-isolation crash. It does
not turn the audit's other conditional hazards into observed production crashes.

## Disposition

| ID | Result | Change and boundary |
| --- | --- | --- |
| C01 | Fixed; production frame confirmed | Watch handlers are explicitly `@Sendable`. Nonisolated filtering precedes a real MainActor hop. Generation checks reject already-copied callbacks after stop/restart, including delayed coalesced work. |
| C02 | Fixed; conditional lifetime hazard | File-scope C retain/release callbacks own the borrowed bridge according to FSEvents' context contract. Stream cancellation may release the context asynchronously; tests await that release. Started background teardown and scheduled-but-unstarted teardown are exercised. A platform-level `FSEventStreamCreate` allocation failure was not forced. |
| C03 | Fixed | Nonblocking 64 KiB pipe reads and parsing share the transport's serial owner. Each read event yields after 256 KiB. A source's cancellation handler closes its descriptor only after an executing callback returns. The existing nonblocking stdin writer remains independent of pipe backpressure. Final output drains before exit; malformed/truncated frames remain explicit failures. |
| C04 | Fixed | A shared native duration policy rejects negative, nonfinite and unrepresentable millisecond values. Footer and transcript formatters cannot trap; restored helper timing remains nullable after invalid history. Request detail counts, retry counters and resource inspector numbers also use checked conversions. Original journal records are unchanged. |
| C05 | Fixed | Block and message rendering keys occupy disjoint namespaces, with an injective escape for reserved message prefixes. Journal IDs are opaque; streaming is explicit state, and the current helper keeps one ID through completion. Projection uniqueness is checked before reconciliation; invalid pages show a diagnostic and preserve the last valid page instead of dropping messages. |
| C06 | Fixed | Provider usage components require nonnegative representable integers. Checked cumulative sums distinguish missing, invalid and overflowing observations. A bad count does not discard the answer or rerun tools. Context baseline arithmetic is checked as well. Raw usage and captured HTTP bytes remain inspectable. |
| R01 | Bounded; exhaustion risk, not a reproduced OOM | Pending PTY output is capped at 1 MiB and delivered in 64 KiB batches. A full buffer suspends reading and applies kernel backpressure, preserving byte order. Final drain has byte/time limits and a visible truncation notice. Input admits at most 2 MiB/32 pending pastes before duplicating descriptors; a rejected paste is not partially enqueued. Combining text is capped at 64 bytes/cell with a replacement and notice; history has a 16 MiB accounted-cost cap and drawing caches have byte/count caps. |
| R02 | Bounded; exhaustion risk | MCP replies reserve at most 4 MiB plus a newline/64 frames before queueing work. Writes are nonblocking and cancellable. Server-directed requests are limited to 64/second. Overflow fails that connection with an unknown-outcome/no-replay diagnostic. Stdout/stderr use bounded POSIX reads; a small response does not wait for a Foundation read to fill 64 KiB. |
| R03 | Bounded; exhaustion/API risk | Git reads both nonblocking pipes on its dedicated worker. Limits are 4 MiB for ordinary output, 16 MiB for patches and 64 KiB for diagnostics. Limits/timeouts cancel the owned process, escalation remains bounded, and incomplete output is never returned as a complete result. The existing eight-process gate remains. |
| E01 | Fixed | Terminal construction now enforces the same two-column minimum as resize, including CJK and combining-character input. |

Byte budgets bound retained payloads and accounted cache costs, not total process
RSS. A terminal limit can shorten hostile output; a Git/MCP limit can fail an
oversized operation. These policies are explicit rather than silently resuming
after dropping bytes or treating truncated results as complete.

## Callback and lifetime review

| Boundary | Executor and ownership | Stop/late-delivery behavior |
| --- | --- | --- |
| FSEvents C callbacks | File-scope nonisolated thunks; locked sendable bridge; framework-owned context retain | Invalidate handler, rotate generation, stop/invalidate/release. UI work hops to MainActor and rechecks generation. |
| Host read/write sources and process exit | Serial transport queue; nonblocking descriptors; close in cancellation handlers | Reads drain before exit. Repeated Stop is idempotent; existing supervisor ownership and uncertainty handling remain. |
| PTY read, process exit and queued writes | Serial reader queue, separate input queue, locked byte admission; explicit sendable closures | MainActor generation rejects stale deliveries. Descriptor duplicates have bounded admission and release on cancellation. Suspend/resume is balanced under a lock and capacity is rechecked to avoid a lost wakeup. |
| MCP peer callbacks | One serialized reader per FileHandle; bounded POSIX reads, locked continuation table, bounded writer queue | No concurrent explicit stdout/stderr close while callbacks read. Closing removes handlers, ends the writer and terminates the owned group; continuations are removed once and invocations are not replayed. |
| Native shell tool readers | Dedicated Dispatch readers, bounded POSIX reads, one read/close owner per handle | Process-group deadline/stop and the locked completion gate preserve uncertain outcomes. Legacy exception-raising reads were also removed here. |
| Git subprocesses | Dedicated workers, eight-process admission, one owner reading/closing both pipes | Cancellation/timeout/size failure drains without growing retained output, then closes once. No UI-actor blocking reads. |
| NotificationCenter observers and Combine | Native observers request `.main`; transcript publishers are MainActor-owned | Observer tokens/subscriptions are removed or cancelled. MainActor assertions remain only after a documented main-queue delivery boundary. |
| AppKit responder/delegate, sheets, animation completion and display links | Main-thread AppKit contracts; existing MainActor UI objects and weak ownership | Existing detachment, observer removal, generation and display-link invalidation remain; no new unchecked UI closure bridge was added. |
| URLSession provider transport | Per-request delegate and lock-protected state; session cancellation/terminal capture remain independent | Existing provider/capture tests are reused and rerun. This review does not establish a universal RSS bound for every transport or UI subsystem. |

## Regression evidence

Scratch evidence is under the session's `tmp/crash-audit-20260920`; no credentials
or private application state are used by the fixtures. The test harness uses
isolated state roots and incremental build caches.

- The real local Responses gateway checks the requested endpoint, streaming
  flag, authentication fixture and request input. Two turns, a tool round trip,
  compaction and a sibling session make exactly five HTTP calls. Huge usage
  overflows become unavailable, the tool runs once, both sessions finish, and
  retained response bytes match the gateway's independent bytes exactly.
- Native regressions cover externally changed Git files, generation replacement,
  linked worktrees/root moves, asynchronous context release, a paused pipe read
  racing close, EOF/SIGTERM/SIGKILL, repeated Stop, malformed history, consecutive
  native row reconciliations, pagination/branch/reopen, tool-only-to-prose identity,
  terminal floods/delayed consumption/paste admission, and Git output limits.
- Helper regressions cover malformed/missing usage, cumulative overflow, retained
  invalid timing, capture, cancellation, compaction, concurrent sessions, MCP
  floods, bounded writer cancellation and existing unknown-outcome recovery.

Final run counts and publication checks are recorded in the
[0.1.61 validation record](validation/Bello-Agent-0.1.61-2026-09-20.md).

## Verification limits

The available Mac is **macOS 14.8, arm64, Xcode 16.1/Swift 6**. Tests run both
optimized Release and Debug with explicit actor data-race checks. The reported
**macOS 26.6.2** environment is unavailable here; exact-OS reproduction is not
claimed. Symbolication uses the matching shipped dSYM, not a rebuilt substitute.
No install or actual Sparkle update rehearsal is performed under the owner's
standing policy. No finite audit proves the absence of all crashes, and this
release does not remove the rich-row/cold-history performance limits documented
in the preceding performance review.
