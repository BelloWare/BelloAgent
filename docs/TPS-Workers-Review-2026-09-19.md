# Reported throughput and worker-thread review

Date: 2026-09-19, Asia/Singapore. Baseline: Bello Agent 0.1.51, source
`fa9a395`. Released: 0.1.52/build 56. Native Swift application and helper.

## Throughput contract

Every displayed TPS value now uses gateway-reported output tokens divided by
the interval from request dispatch through model completion. Reasoning tokens
are a subset of output and are not added again. The interval includes startup
latency and excludes a later HTTP tail; this is an end-to-end request average,
not the provider's decoding speed. It does not require visible text or a
first-content timestamp. Missing usage stays missing; reported zero is valid.
Failed, cancelled, unfinished and truncated attempts do not supply completed
rate samples. Durations must be finite and positive, and output must be finite
and nonnegative.

The old helper meter estimated output from UTF-8 bytes divided by four. It
could not see opaque reasoning, depended on chunk delivery and drove flashing
sidebar updates. It is removed. Activity schema version 2 retains model/tool
phases and queue state without any byte-derived rate fields. Native phase
handling accepts versions 1 and 2 but consumes no older rate estimates.

The native archive now projects `request_ms` directly from dispatch and model
completion. Previously it derived duration by adding TTFT and streaming time,
which excluded valid responses with no first-content observation. Projection
version 7 backfills retained metadata; metric expiry clears the new column and
does not resurrect expired observations. TTFT remains independently nullable.

Sidebar, footer and session usage refer to the actual latest completed request.
Its rate stays unchanged while another request runs. If the next completion
lacks usage or timing, its rate is unavailable rather than silently falling
back to an older sample. A new chat waits for reported usage. The average is
summed reported output divided by summed duration across valid retained
completed requests. Charts preserve missing values and coverage.

The sidebar's per-second rate timer is removed. Its metric occupies a stable
slot and only changes on completed usage, with a small local fade that honors
Reduce Motion. Whole rows and streamed chunks do not animate the rate. At narrow widths the
rate moves below cost/status, preserving full labels instead of overflowing.
Rendered regressions cover ordinary and minimum-width top-level/child rows.

## Actual parallel file work

Twenty network streams already overlapped in the 0.1.51 concurrency fixture,
but synchronous read/list/find/grep work occupied the single project tools
actor. A long search could delay other read tools and definition requests.

The helper now shares a bounded Dispatch worker pool: four active blocking jobs
and up to 64 FIFO waiters. Only immutable path context crosses from the tools
actor; file handles, directory enumerators and regex objects stay local to each
job. Tool availability, read-only permissions and argument shape are checked
before admission. Overload produces a visible `tool_busy` error.

Queued cancellation removes a job before execution. Running jobs check an
explicit cancellation token between file entries and grep lines and after
blocking work. Cancelling a task does not pretend an occupied thread is free:
the slot remains held until that operation exits. No thread is forcibly killed.
An individual filesystem call or regex match can still take time to return.
Four stuck calls can occupy the pool; directory listing still enumerates before
applying its output limit. Write/edit work remains synchronous on the tools actor.

Write/edit/bash/MCP project coordination is preserved. Independent sessions can
overlap networking and read work; edits within one project remain ordered.
The UI remains MainActor-owned, and durable storage uses its serialized actor.
This is bounded multithreading, not a dedicated thread for every conversation.

## Evidence

The combined helper Debug suite passes **188 tests with zero failures**. The
worker barrier records 20 jobs, **four distinct simultaneously occupied OS
threads**, a maximum of four active jobs and 16 queued. Regressions cover FIFO
admission, overload, queued/running cancellation, retaining occupied slots,
tool permissions, responsive definitions and unchanged editing gates.

Reported-rate regressions cover hidden reasoning with no visible text,
reported zero versus absent usage, invalid durations, nonfinite values and
failed/cancelled/unfinished attempts. The request-aware 20-session gateway
fixture also verifies the exact reported-output/duration formula and the
absence of byte-rate telemetry.

Final native and packaged-helper checks, distribution evidence and any initial
test failures are recorded in the
[0.1.52 acceptance record](validation/Bello-Agent-0.1.52-2026-09-19.md).
Scratch logs are under the session's `tmp/tps-052-20260919` directory.

Fixtures use synthetic loopback gateways and credentials. They establish app
behavior, not a remote gateway's rate limits or a universal rendering frame
rate. The large-history rendering limitation in the 0.1.50 review remains.
Installation and actual update rehearsals are skipped under the owner's policy.
