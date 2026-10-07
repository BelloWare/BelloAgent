# Explicit socket modes for synchronous test fixtures

Baseline `a890af0a7797197ee5eee4a538098eabbed2a492` passed Linux
[37636000086](https://github.com/BelloWare/BelloAgent/actions/runs/37636000086).
macOS [37636000099](https://github.com/BelloWare/BelloAgent/actions/runs/37636000099),
job `112842266619`, passed the prior Inspector reload test but failed another
fixture's ListTools setup. New diagnostics showed configured, idle, read-only
state with no unknown outcome and a connection/disconnection error, before any
intentional tool-call disconnect. The app MCP suite passed 43 / failed 1.

The fixture used a nonblocking listener, then synchronous reads on accepted
sockets with a read timeout but no explicit blocking-mode reset. Apple's
[accept implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/uipc_syscalls.c#L587-L619)
copies listener file flags to the accepted descriptor and applies its nonblocking
state. The parser treated any read error, including WouldBlock before a complete
request arrived, as a disconnect. The native log did not record socket flags or
errno; this source-proven portability defect explains a possible failure path,
rather than providing an observed errno from that particular connection.

Accepted MCP fixture streams now explicitly become blocking before bounded
three-second read/write operations. A deterministic regression forces the
nonblocking flag on either Unix host, applies the actual fixture normalizer,
then verifies flags and both timeouts. Removing the reset produced the expected
failure (`O_NONBLOCK` remained set); see `negative-control.log`. An initial
short-name invocation with `--exact` selected zero tests and is not counted as
negative evidence; the full-name binary invocation executed and failed one test.

The same source audit fixes three settings fixture accepts, their later bounded
closure-observation phase, and the read/edit native transcript fixture accepts.
Existing read/write bounds and strict protocol/call-count assertions remain.
Independent review found no production or authority change. This is test-support
code only; prior GUI binary attribution is unchanged.

All four source hashes are recorded in `SHA256SUMS`. Nonblank Rust delta is
**0 production / +39 test-support / 0 benchmark**: settings +4, MCP +33, native
read +1 and native edit +1. Totals after publication: **38,796 production /
53,044 test-support / 1,189 benchmark**, with shared code counted in BelloBox.

Local checks on the restored source passed: 45 focused MCP app tests; the full
synthetic-authority app suite (532 passed, three established platform ignores);
strict all-target synthetic-authority app Clippy; formatting and whitespace.
The original repository root was explicitly verified in compiler output after
package-only core/app cleanup. The actual negative-control binary ran one test
and failed its flag assertion; the final restored source was rebuilt afterward.
Fresh native CI is required after publication; no Linux test is substituted for it.
