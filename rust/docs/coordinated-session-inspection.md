# Coordinated retained-session inspection and safe selected opening

This prerequisite adds cooperative inspection scheduling and safe selected-chat
opening. It does not enable sidebar content search, a persistent search cache,
or an atomic loaded/durable-source certainty publication. The separate pure
projection experiment is not included in this checkpoint.

## Admission and cancellation

WorkspaceStore clones share one inspection coordinator. Selected openings queue
FIFO, cancel the currently admitted background inspection, and wait asynchronously
for its permit to be released. Background scans wait on notifications. Dropped
selected requests leave the queue; cancellation does not grant another permit
while the previous lease still exists. The selected queue is bounded at 1,024
requests and identifier exhaustion is an explicit error.

A read-only inspection borrows its permit exclusively. A compile-fail doctest
prevents two simultaneous leases through the same permit. Checkpoint reads check
cancellation around bounded 64 KiB reads. The cancellation-aware serde reader
caps each read to its remaining 4,096-byte check budget. Replay checks cancellation
between records and during parsing. Cancelled inspection returns the distinct
Cancelled error, never a corruption result or recovery-write instruction.
Non-cancelled parsing retains the original slice parser. Differential tests cover
reader/slice acceptance for arbitrary-precision number lexemes, deep nesting,
malformed trailing bytes, duplicate/schema fields, and escaped Unicode.

Existing semantic validators are unchanged. Cancellation checks between validators
do not interrupt their inner loops, and filesystem calls can block. This is not a
hard latency guarantee or a native responsiveness measurement. Successful inspection
or possession of a permit is not evidence of persistence certainty or authority.
The coordinated callers are the restored sidebar run-state scanner and selected
chat loader; other direct inspection factories are not all migrated here.

## Selected-chat handoff and retirement

The selected loader waits and opens on the background executor. UI admission
checks current project, workspace identity, generation, previous Controller
identity and existing project/mode/connection gates. Cancellation is rechecked
immediately before opening; UI admission is checked again before installation.
Later UI invalidation can race synchronous opening. A newly opened Controller is
therefore retained before any fallible UI delivery and retired if never installed.
It cannot start provider/tool work through this loading path.

One app-lifetime retirement slot holds that Controller and its inspection permit.
It belongs to AgentView, already retained across window detach by WorkspaceLifetime,
and survives bind_window. It stores no view, task or runtime reference. Placing it
in WorkspaceStore or the coordinator would create authority or permit cycles.
The slot clears only after exact-operation installation or successful
retire_and_wait. Cancelled cleanup keeps the original entry. Failed cleanup also
cancels queued admissions and remains a visible blocker; only explicit successful
cleanup creates a fresh admission generation. Sticky worker failures may remain
blocked and are not promised recoverable.

Workspace cleanup Retry is independent of the selected chat's loading bit or
generation. Shutdown can reach it despite cancelled queued openings, saves drafts
first, and explicitly retires the never-installed actor before ordinary Controller
shutdown. Failure vetoes close. Normal in-progress slot occupancy allows a newer
selected chat to queue; failed cleanup and project replacement remain blocked.
This preserves the existing draft/writer policy and does not claim native Quit
acceptance.

No workspace/coordinator/retirement-state mutex is held across asynchronous waits
or parsing. The workspace mutex is released after cloning the coordinator. Previous
Controller retirement runs in the background before acquiring the lane. The slot
mutex is released before retirement. The permit spans admission and any necessary
never-installed cleanup, not the installed chat's lifetime.

## Review and regression evidence

Independent review found four App defects before the final checkpoint:

1. Admission rejection after waiting left the same target permanently loading.
   Completion now clears it only with matching identity/generation.
2. Stale-open cleanup ran on the foreground executor. It now runs in the background
   because retirement can synchronously lock or checkpoint.
3. Normal slot occupancy suppressed a newer unloaded chat, leaving an unopened
   placeholder. Navigation and loading now distinguish in-progress from failed
   cleanup and queue the newer selection.
4. Aborted shutdown could reuse a cancelled sidebar scope and repeatedly retry.
   Cancellation invalidates scope, so the next active refresh renews its token.

All four findings were closed by source rereview and deterministic GPUI coverage.
Tests also cover failed-retirement ownership, cancelled retry, exact-operation
installation, stale open/window rebind, shutdown reachability with queued loading,
and workspace Retry independent of selected generation.

Three source mutants reintroduced stuck loading, newer-selection suppression and
cancelled-scope reuse. Each failed its intended regression test; exact original
bytes were restored before full suites. Core controls caught late notification
subscription, missing parser cancellation and shared permit reuse. Removing only
Notify.enable did not fail: existing Notified creation already tracked broadcast
generation. That surviving control is not counted as a caught defect. Earlier
checkpoint controls remain attributed to their original source, while later async
API additions are covered by final tests. Fixture-development failures were kept
separately and are not counted as successful product checks.

Final restored Linux validation passed:

- Default Core: 589 unit tests, all integration targets and the compile-fail
  doctest; full command 30.339 s (unit execution 10.66 s).
- Default App: 637 passed, one manual benchmark ignored; command 33.518 s
  (test execution 11.31 s).
- All features: Core 774 unit tests plus integration targets/docfail; App 782
  passed, three intentional ignores (benchmark and two macOS-only workflows).
  Combined command 88.246 s.
- Strict Core/App all-target Clippy: default 16.417 s; all features 24.834 s.
  Workspace formatting check: 2.111 s.
- Package-clean ordinary, no-default-features App build: 20.513 s. The sealed
  Linux binary SHA-256 is
  `fcd537f3090df26e72ca8eeb03be77eb0e859dad1aab315b79896846e3a3c21a`.

Measured command durations include build/test overhead. Inference timing is
unavailable. A pre-existing proc-macro-error2 future-compatibility notice remains;
it did not fail these gates. Physical LOC delta is +818 production, +881
support/tests, zero benchmark, chained to exact baseline e4d (shared Box and
366 documentation/evidence Rust lines remain excluded). LOC is not completion
or performance evidence.

Actual ordinary Linux GUI navigation passed on that sealed binary: three retained
saved synthetic chats, rapid A-to-B selection settling on the correct transcript,
Projects-folder and Connections-gear sheet transitions/return, draft preservation,
and normal close (exit 0). Before/after source, session and journal bytes matched;
there were zero provider POSTs, tool calls or new records. The observed workflow
lasted 279.138 s; this is not interaction latency.

No pending-load phase was captured on the small local records, so adjacent clicks
do not prove a transition during I/O. No ordinary native reopen route exists;
detach/rebind remains headless-only evidence. Cleanup-failure, cancellation and
stale-controller races remain deterministic synthetic GPUI evidence. No sidebar
search or native macOS acceptance was exercised.
Synthetic GPUI failure injection is not actual-GUI race acceptance. No native
permission, real provider/user data, persistent index or source-certainty gate is
opened by this checkpoint.
