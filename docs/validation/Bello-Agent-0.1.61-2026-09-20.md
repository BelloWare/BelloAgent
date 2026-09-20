# Bello Agent 0.1.61/build 65 acceptance — 2026-09-20

Release candidate for the owner's uploaded `Crash-Audit.md`. Publication details
are recorded below after the signed archive and public feeds are verified.

## Scope and evidence

The shipped 0.1.60 dSYM UUID matches the supplied crash, and its two application
frames resolve to `GitWorkingTreeWatcher.start()`'s callback and
`gitWatchCallback`. The sendable callback contract, nonisolated C context
ownership and generation checks repair that crash path. The rest of the audit
covers conditional crashes and resource risks, not additional observed incidents.

See [the finding-by-finding implementation record](../Crash-Audit-Implementation-2026-09-20.md)
for C01–C06, R01–R03, E01, explicit output limits, callback ownership and limits
of the evidence. This release also includes the previously committed
[performance follow-up](../Performance-Review-Implementation-2026-09-20.md).

## Regression runs

Machine: arm64 virtual Apple M3 Max, 10 CPUs, 16 GiB, **macOS 14.8,
Xcode 16.1/Swift 6**. Tests use isolated fixture roots. No production gateway,
mutable external MCP service or private conversation was used.

| Run | Configuration | Result |
| --- | --- | --- |
| Complete Swift helper suite | Release (`swift test -c release`) | **215 passed**, zero failures, 19.238 s of tests |
| Final telemetry/context/gateway revalidation after the checked-JSON-sum guard | Release | **24 passed**, zero failures |
| Native crash/lifecycle/integration selection | Release, `ENABLE_TESTABILITY=YES` | **172 passed, 1 skipped**, zero failures, 155.744 s of tests |
| PTY root exit with a continuously writing descendant | Release | **1 passed**, bounded drain, one exit, no late output |
| Watcher/pipe/terminal regressions plus existing host transport tests | Debug, explicit `-enable-actor-data-race-checks` | **20 passed**, zero failures |
| Final native crash, opaque-ID/read-state and transcript document/wire checks | Debug, explicit actor checks | **37 passed**, zero failures; includes deferred projection diagnostics and the descendant exit fixture |

The native selection includes the real Git watcher and large-diff tests,
HostSupervisor/HostTransport/HostInbox, workspace failure/durability, gateway
accounting, timing/read state, transcript identity/reconciliation/scrolling,
terminal model/PTY/window tests, the streaming-to-settled fold regression and
release configuration. The single skip is the opt-in diff screenshot fixture;
it requires `PI_APP_UI_SCREENSHOT_ROOT`. Existing unaffected suites were reused
under the owner's focused-test policy, rather than claiming a full native run.

The local Responses fixture validates endpoint, stream flag, fake authorization
and input before producing request-dependent responses. Tool round trip, two
turns, compaction and a concurrent sibling complete exactly five HTTP calls;
usage overflow does not discard text or rerun a tool. Four primary-session raw
response captures equal the independently retained gateway bytes. The full
helper suite also covers request-aware provider/tool/cancellation/capture paths.

## Failures investigated

Early native failures were test expectations, corrected before the final run:
FSEvents context cancellation releases asynchronously (the test must await it),
and a two-column terminal's wrapped final line is not a wide-screen text oracle.
The unstarted stream fixture now schedules before invalidate/release.

An MCP flood fixture exposed that Foundation's requested-length read could wait
for more bytes; bounded nonblocking POSIX reads fixed that hang. The final MCP
flood completes through its connection error, with bounded queues and no replay.

A full Debug helper run hit a shell deadline and the process-CPU streamed-delta
threshold while a native compile competed for CPU. With the compile idle, the
shell check passed but the Debug CPU threshold still measured 1.262 ms against
1 ms. Assertions were not weakened: the full shipping-optimized helper suite
passed, measuring **0.333 ms CPU / 0.300 ms wall per delta**, 2,269 mean wire bytes
against a 250,883-byte full page. These are runner measurements, not a physical
frame-rate or universally smooth UI claim.

## Boundaries

- The reported **macOS 26.6.2** environment is unavailable; exact-OS reproduction
  is unverified. Explicit actor checks supplement the baseline Mac tests.
- No platform allocation failure was forced for `FSEventStreamCreate`; successful
  retain, unstarted teardown, background stop and eventual context release were
  exercised. No Thread Sanitizer or Address Sanitizer run is claimed.
- Byte budgets cover retained payload/cache costs, not a universal process RSS
  guarantee. The PTY preserves UTF-8/escape ordering under backpressure; final
  exit-drain and combining-text limits are visible policies. Git never presents
  a truncated patch as complete. MCP overflow preserves invocation uncertainty.
- No fresh-install or actual Sparkle update rehearsal, per the standing owner
  instruction. Signing, notarization, packaged smoke, public archive hash and
  Sparkle signature checks remain release requirements.
- This audit is not a proof that every crash or rich-content performance problem
  is fixed. The performance record retains its remaining cold-history/rich-row
  limitations.

## Publication

Pending signed artifact generation and public feed/archive verification.
