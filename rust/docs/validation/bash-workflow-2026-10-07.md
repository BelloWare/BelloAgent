# Trusted Bash workflow validation — 2026-10-07

This is a scoped Rust/synthetic-authority checkpoint. Production startup, vault
and authority gates are unchanged. Linux is not macOS native acceptance.

## Source and build attribution

The integration parent is published `c0df34001f512c2bc374329c13708afe9bfa0aaa`,
tree `7e9db8f815e5dcb998383da5b3c8dfb51d01bda6`. Its exact Linux run
[37664508487](https://github.com/BelloWare/BelloAgent/actions/runs/37664508487)
and macOS run
[37664508508](https://github.com/BelloWare/BelloAgent/actions/runs/37664508508)
passed, including native Read and Edit fixtures. This does not transfer a green
status to an unpublished Bash candidate.

Bash candidate2's immutable app SHA-256 is
`504d5291b53264673b85981009b3cb0c8655aa011e03ecf0b0009ad5adfefbdc`; its original
source-manifest SHA-256 is
`46dd6bc1d1711ad37d64933d5f628b21eea4e5d8519fad80ea47cb12175dd1ab`.
The later Skills carry changed five Rust test files, not production Rust or Cargo
inputs. The native Read schema correction is already part of the integration
parent. A separate compaction test-only barrier correction follows below.
The original app is explicitly not described as a rebuild on the newer parent.
All runtime Rust/Cargo inputs used for the Linux GUI evidence are unchanged.

The immutable rebased Bash source-manifest SHA-256, before these final test/docs
updates, is `0129e22e28ac05f2c610804dc6d1bdde366f98ff4e2d6243addcdfc4dca546e4`.
Its Skills baseline tree is `e41551e2cdc390c040820870eede7fdd2d4363ce`, originally
local `b44e47c9…`, published as `e2785bc7…`. The frozen-source directory's Python
GUI fixture was subsequently updated; all manifested Rust/Cargo inputs still
match. Do not claim whole-directory equality with the earlier manifest.

## Tests: distinguish passed, killed, and pending

The preserved candidate2 logs verify:

- Core default: 508 tests passed.
- Core all-feature: 661 top-level tests passed. Two nested child-process result
  lines are already represented by their parent unit tests and are not counted
  again as 663.
- App synthetic-authority: 551 passed, 3 ignored.
- Strict core/default/all-feature and app Clippy completed.
- Seven deliberately broken controls fail their targeted assertions: failed
  result propagation, physical admission, post-drain deadline, retention cap,
  generic and live late publication, and physical-job registry ownership.

Those are historical candidate2 passes, not a final-candidate full rerun. After
the final test-only corrections, the complete default core suite again passed
508 tests. The compaction focused test passed and its detecting semantic-refusal
mutation failed; production source was restored byte-for-byte.

The first final-source default run exposed a preexisting race in
`stop_during_summary_retains_stream_and_held_queue_without_adoption`: a watch
notification can arrive before `stream_delta` releases the actor mutex. The test
previously required the first nonblocking inspection to return the Compaction
refusal, although a transient busy refusal is also valid at that instant.
Twenty focused unchanged runs passed but did not erase that full-run failure.

The test now obtains/releases the actor lock as an explicit publication-settlement
barrier. The fixture sends no further stream chunks. While deliberately holding
the lock, it captures and asserts the exact documented busy error; afterward it
still requires the Compaction refusal and preserves all Stop, paused-queue and
reopen assertions. There is no generic retry or production change. Removing both
semantic compaction guards makes the strengthened test fail on an incorrectly
successful Context preview. Removing only one guard was not detecting because
the other guard still rejected the preview; that experiment was not counted as
a successful negative control.

Final all-feature Rust compilation was terminated by SIGKILL in repeated local
attempts, including jobs=1, package-scoped codegen-units=16 and an admitted
resource-escalated offline attempt. No final test result exists for those runs.
Resource pressure is suspected; these logs do not measure or prove host OOM.
No access denial was bypassed and no security setting or dependency cache changed.
Final local app/full-feature checks remain pending where not separately logged.

The updated Linux workflow runs complete all-feature core and synthetic app
suites plus strict corresponding Clippy. The macOS workflow runs all-feature core
and the full synthetic app suite, and explicitly names the extracted-Swift
`bash_native` target. Strict app lint remains Linux-only; existing legacy macOS
objc macro warnings are not suppressed. Exact published
Bash CI must pass before calling these final aggregate/native gates complete.

## Actual Linux GUI evidence

The `bash-workflow-2026-10-07/` evidence directory contains original screenshots,
verified result summaries, immutable build attribution and selected logs. All data
was generated in isolated HOME/TMPDIR/XDG/project/state paths, using numeric
loopback providers, a fake memory-only vault and fixed harmless commands. No paid
provider, real credentials, user files, Mac, signing or native permission was used.

Observed through the ordinary app:

- Explicit generated-project creation/trust and saved loopback selection.
- Bash Running output growing to all six lines; Completed, exit 0 and provider
  continuation. A later turn deliberately reuses the same provider call ID.
- Generated stderr/exit 7 remains Failed in the card and durable history.
- `sleep 4 & exit 0` with timeout 1 remains Failed despite leader exit zero.
- Stop produces Unknown, preserves a paused queued `Q`, and explicit Resume
  delivers that input without rerunning the interrupted command.
- 32,768 raw `0xff` bytes expand into a 98,317-byte retained text result including
  exit 3. Generic retention truncates the displayed/replayed summary while Failed
  and the retained bytes remain correct.
- The image picker opens, cancels, reopens and selects a generated PNG. The
  attachment opener was invoked, then another Bash run completed. No image-viewer
  window appeared, so successful external image opening remains unverified.
- After normal process close/reopen, the session file is byte-identical, including
  three Failed results and one Unknown. No request or command was automatically
  replayed. Memory-only fixture trust resets on restart; history remains visible
  while sends are correctly gated. This is not native-vault persistence proof.

The fixture chat was Editing; no interactive ReadOnly admission claim is made.
ReadOnly/unoffered/invalid admission and shared second-chat/MCP physical-gate cases
remain backed by the source/tests, not a newly executed GUI matrix for those paths.

## Actual last-window close through physical reap

A separate fresh fixture used a fixed held command: publish readiness and exact
Linux PID/start identity, record TERM without ending the loop, and wait until
owned escalation or a bounded control-file release. The loop also self-terminates
in roughly 90 seconds; timeout is 120. No arbitrary prompt is executed.

The command remained observably held for approximately 44 seconds while normal
close confirmation was navigated. The app kept its last native X11 window and
showed “Saving drafts…” during cleanup. A desktop-local observer sampled the
specific app and shell identities at 10 ms intervals:

- 89 samples show the app alive while the shell remains present after TERM.
- The shell identity disappears about 1.008 seconds after TERM.
- Seven subsequent samples show the app still alive after the shell disappears.
- The app exits normally about 75 ms afterward, status 0.
- Neither the manual-release path nor the command's normal-finish marker was used.
- Durable result is Unknown and session paused. No automatic replay occurred.

This corroborates the real native close veto and physical-join order, not merely
TestPlatform behavior. `main.rs` installs `on_window_should_close`; ordinary close
is vetoed while confirmation/shutdown is pending. `ShutdownPlan` waits for
`Controller::shutdown`, including `native.join_processes`; only successful
`finish_shutdown` allows removal. The compressed original observer stream and
original screenshots are retained, along with the exact observation/launch
scripts. Timing is evidence for this generated Linux run, not a performance or
macOS lifecycle guarantee.

## SIGCHLD boundary and native limitations

The supervisor requires SIG_DFL without SA_NOCLDWAIT and exclusive per-child
reaping; keep its WNOWAIT ownership, synchronous TERM/KILL, Jobs/gate lifetime and
Unknown semantics. Pinned GPUI `open_with_system` on macOS uses smol/async-process,
whose persistent SIGCHLD handler conflicts with that strict guard. Later Bash
would be refused; initializing that API during a run can suppress further signals
and delay cleanup until natural exit.

Current source uses NSWorkspace.openURL for Agent attachment URLs and
NSOpenPanel/NSSavePanel for pickers; the review found no current Agent/pinned
workbench call to `open_with_system`. Thus this is a documented unsupported host
API boundary, not an observed broken current Mac picker workflow. Linux can use
pidfd and cannot establish macOS compatibility. A future integration of competing
signal/reaper APIs needs a reviewed contract, preferably a fresh exec'd supervisor
boundary; pointer allowlisting or arbitrary-handler acceptance is insufficient.

The macOS Swift Bash oracle and actual current-path native host acceptance remain
separate exact-published gates. Linux does not validate Apple process behavior,
native dialogs, focus/IME/accessibility, signing or Keychain.

## LOC

Count nonblank physical Rust lines including comments, with positive test-only
spans/modules as support and benchmarks/examples separate. External shared
workbench/UI source is counted only in BelloBox. The immutable exact-blob Bash
audit was rerun, including all 18 tamper controls and unchanged-line classifications.
Inherited synthetic attachment fixture exceptions remain documented there; they
are not a new general rule for mixed feature/test gates.

Against Skills `e2785bc`: 42,590 production / 56,228 support / 1,192 benchmark.
The carried native Read parent correction adds 11 support lines. Bash adds
980 production / 1,824 support; the publication-barrier follow-up adds 20 support.
Therefore against the green `c0df340` parent, this Bash delta is +980 production /
+1,844 support / 0 benchmark. Result: 43,570 production / 58,083 support /
1,192 benchmark, total 102,845. These counts establish neither feature-completion
percentage nor performance/native readiness.

Reproduce the exact final LOC check with Python 3 and a repository containing the
published baseline Git objects (full history is recommended):

```sh
python3 -B rust/scripts/verify-loc-bash-final-2026-10-07.py \
  --repo . --source-root .
```

Use `--after EXACT_COMMIT` instead of `--source-root` for an immutable published
snapshot. This verifies source/category accounting, not remote publication or CI.

## Later final-source metadata validation and archive filename correction

After the frozen handoff, all four strict all-target Clippy configurations passed
against the unchanged final source: core default/all-features and app
default/synthetic-authority. `supplemental-clippy-results.json` binds exact argv,
exit statuses, log hashes and the unchanged source manifest. These are metadata
checks; the killed full runtime-suite attempts remain unverified until CI.

The original held-close screenshot was captured as JPEG bytes under a `.png`
filename. The published archive uses `held-close/04-held-close-drain.jpg`; its
bytes are unchanged, SHA256
`47df205b37c14ac03d6e451815e49660ad7dd3176295a308e60959acf798ccbc`.
Raw logs, CSV and patch context preserve their original whitespace rather than
being reformatted as source. No Rust, production gate or LOC changed here.
