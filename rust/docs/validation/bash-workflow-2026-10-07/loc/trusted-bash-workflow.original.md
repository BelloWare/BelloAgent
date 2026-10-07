# Trusted Bash process workflow

This is the next source-backed tool vertical after project-only skills. It uses
ordinary saved-project authority and explicit Editing mode. Production vault/tool
startup gates remain unchanged; the app's explicit fake-vault fixture may offer
Bash in Editing mode on Unix. Read-only and ordinary disabled startup do not offer
it. This does not add stdio MCP, shell extensions, credentials, or a sandbox.
Workspace roots are the command's working-directory context, not an OS boundary.

## Source and data contract

The specification is `packages/swift-host/Sources/PiAgentCore/Tools.swift`'s
`ShellRun`, `MCP.swift`'s `ManagedChild`/`toolEnvironment`, and the invocation,
rejection, retention, and editing-gate paths in `SessionTools.swift`.
`NativeToolTests.swift` supplies the inherited-pipe/deadline/Stop cases.

The definition is `bash(command, timeout?)`. Invocation uses `/bin/bash
--noprofile --norc -c`, closed stdin, workspace cwd, and a fresh process group.
Command bytes are bounded at 262,144; timeout defaults to 120 seconds and must be
1–600. Applicable Pi string/integer/null preparation is reused. Unoffered tools,
invalid keys, invalid arguments and output-creation errors are rejected before a
process starts. NUL in a command is rejected before process APIs; it cannot
silently truncate a command. Construction alone creates no files or children.

Only HOME, PATH, LANG and TMPDIR enter the child environment. HOME is the explicit
host tool-context home. The other values come from the source allowlist with
source defaults. Isolated tests inject private values for all four. Shell-generated
variables are not additional inherited host credentials. No startup scripts are
read by the selected Bash invocation.

## Physical process ownership

One bounded file-executor worker owns the Child, both nonblocking output pipes,
retained file, cancellation checks, signal escalation, and shared workspace
editing admission. At most the existing four workers can run; queued jobs reuse
the existing bounded FIFO. There are no independent blocking reader threads,
unowned numeric-PID timers, or escaped-process searches.

`waitid(WNOWAIT)` observes the child without reaping it. The unreaped leader
reserves its PID through every possible process-group signal. TERM and the
one-second KILL escalation execute synchronously inside that owner; signalling is
permanently disabled before `Child::wait` releases the leader identity. Ownership
is rechecked by waitid before every signal, even after an earlier exit observation.
A wait error forbids further group signals; there is no direct-PID fallback.

Supported-host requirement: SIGCHLD must retain SIG_DFL without SA_NOCLDWAIT, and
no competing `waitpid(-1)`/`waitid(P_ALL)` consumer may reap this Child. The host
must preserve that exclusive-reaper contract. Nondefault/auto-reaping dispositions
are refused before spawning and before signalling. This may reject a runtime
that installs an otherwise legitimate global child handler. Actual app acceptance
must check Bash after representative picker/file-opener actions; unit-test default
signal state does not prove GPUI compatibility. Portable POSIX cannot atomically
signal an old process-group incarnation against a hostile concurrent reaper; no
such guarantee is claimed.

Normal settlement requires leader exit plus both EOFs, or 1.5 seconds of output
grace. Deadline includes that grace, and is rechecked after draining/file writes,
not only before them. On Stop/deadline, output grace is 0.5 seconds after exit;
owned escalation remains alive through its one-second bound. After three seconds,
an unreaped child can yield an uncertain logical result, but its same physical
worker, editing guard and registered owner remain until reaping. Retirement and
shutdown wait for that physical registry. Dropping either a call awaiter or a
retirement waiter cannot consume the sole cleanup owner. Opaque uninterruptible
OS operations cannot be forcibly bounded; the gate/session writer must not
pretend those operations joined.

Editing admission is released after physical settlement and native-result
retention, before the whole-batch durable receipt. Retaining it to that receipt
would deadlock a second editing call in the same sequential batch. Durable
begin/result ownership separately preserves Unknown after a missing receipt.
Normal background jobs are intentionally allowed to outlive Bash, as in Swift;
the background-process note explains closed inherited pipes and SIGPIPE risk.
Escaped process groups are never chased.

## Output, results, and live cards

Both pipes drain on one worker in bounded rounds. Their inter-pipe order is
scheduling-dependent. The raw preview is 32 KiB; malformed UTF-8 can render up to
96 KiB. Raw retention is capped at 64 MiB in a 0600 file under a new 0700 private
directory. Drain/count continues beyond retention. A retention failure stops
further writes, preserves bounded preview/drain, and reports the source warning.

Growing previews publish at most once per 66 ms and stop once the raw preview is
full. No unbounded callback queue is created. Live state is controller-, worker-,
configuration-, turn-, assistant- and call-owned, monotonic by sequence, and
non-durable. A split UTF-8 scalar can reduce rendered byte count while the raw
preview grows; rendered length is not an ordering token. Stop/retirement fence
publication, including already-prepared updates. Reused provider call IDs cannot
revive an older card. Reopening reads durable rows, never ephemeral output.

Native `isError` is retained through conversion and the existing generic 64 KiB
result-retention layer, so nonzero exits and deadlines remain Failed on cards and
provider replay. Bash has text-only content and does not weaken the existing
MCP-only Failed structured-content validator. Stop/interruption or a missing
authoritative receipt remains Unknown, with no automatic retry. Definite
pre-invocation cancellation/admission refusal remains NotExecuted.

## Evidence and acceptance boundaries

Focused Linux tests cover actual stdout/stderr processes, nonzero exit, timeout
with an already-exited Bash leader, dropped awaiter/admission, >64 MiB drain,
private permissions, raw/expanded malformed UTF-8, split scalars, I/O warning,
normal background grace, short-lived escaped group, and lost wait ownership.
An injected clock proves post-drain deadline ordering without a flaky slow-disk
sleep. An isolated subprocess proves auto-reap policy refuses before any spawn.

Normal saved-runtime tests exercise two editing calls in one batch, live preview,
Failed provider continuation, Stop/paused queue, close/reopen, read-only rejection,
and missing-receipt recovery without rerun. A shared-workspace regression queues
HTTP MCP and a second chat editing operation behind a physically cleaning Bash
owner. These are actual local processes plus numeric-loopback provider/MCP
fixtures; no paid model or real credentials are involved.

`tests/bash_native.rs` extracts the current Swift implementation rather than
reimplementing its algorithm. Its macOS-only oracle compares process-result
semantics, isolated environment, argument errors, raw retention/UTF-8 boundaries,
and inherited-pipe/timeout messages. It intentionally does not validate Swift's
unowned escalation lifetime. Apple compilation/execution is a separate CI gate;
Linux tests do not establish it.

At implementation preparation, Linux core regressions and strict Clippy passed;
app compilation/projection tests, independent final review, current GUI acceptance,
and exact-published macOS CI remain separate pending gates. Do not interpret this
file, a compiled app, or a synthetic projection as completed native UI acceptance.

## Generated interactive fixture

`rust/fixtures/bash_workflow_fixture.py init --root NEW_DIRECTORY --port PORT`
creates only generated files and a fake loopback profile. `serve` starts its
numeric-loopback provider; `seal --binary PATH` copies/hashes the exact reviewed
synthetic-authority binary. `launch_bash_gui.sh` is operator-only after the desktop
lane is assigned. It uses private HOME/TMPDIR/XDG paths, creates no trust silently,
and verifies the sealed binary before launch.

Explicit prompts BASH_LIVE, BASH_STOP, BASH_FAIL, BASH_TIMEOUT and BASH_MALFORMED
select predefined harmless commands. The server never executes prompt text as a
command. It reuses a call ID deliberately to exercise cross-turn ownership. The
operator must choose the saved connection, trust the generated project, and select
Editing through the normal app path. Check growing output, Stop, failed result,
new prompt, retained details, and close/reopen. Check a file/picker action before
another Bash turn to establish supported SIGCHLD runtime compatibility. Request
bodies are retained only inside this generated evidence directory; never use
personal content with the fixture logger.
