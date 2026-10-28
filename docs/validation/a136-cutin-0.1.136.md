# AGENTS-2: drain-based mailbox cut-in — 0.1.136

Worktree `wt-a136-cutin`, branch `dev/a136-cutin`, starting at `9793eceb`.
Implementer: Codex; reviewer/merger: the lead. No release, tag, dev/next push,
installed-app launch, real preferences, Keychain access or paid request.
Build products, retained fixtures, generated fault sources and logs use the
assigned build root. Existing test utilities also create isolated, disposable
OS temporary directories; they do not read user data. All build/test commands
export:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-cutin
```

## Contract and implementation

The first commit, `60e89cf0` (**AGENTS-2 contract: drain-based cut-in (v4.1)**),
updated §11 before implementation. Owner decisions are binding: **“Match
Codex”**, **“Drain in background”**, **“Wait for cut-in”**, and **“No new
pauses.”** The cancelled-request/cost-unknown guard and unresolved choices
were removed. The wire examples and `subagents-mailbox-cutin-v1` capability
are frozen in [§11](../design/subagents-codex-style.md#11-mid-reply-cut-in-v41).

- Only completed `response.output_item.done` reasoning, commentary or
  `partial_answer` items can cut. Deltas, tools, final/unknown phases,
  incomplete prefixes, duplicate item/call IDs and malformed content cannot.
- Qualification requires actual SSE, `openai-responses`, pinned routing,
  reported effective identity matching expected identity, and the existing
  opaque replay binding/revision checks. RoutingContract has no upstream
  field: the documented OpenAI family allowlist is explicitly a **name rule**,
  including numeric gpt-5/gpt-6 revisions. Portable, ask, translated, unknown
  identity and JSON routes silently retain ordinary boundaries.
- The typed cut returns only after the durable prefix and one cancellation
  result per complete buffered call. Opaque items, argument strings, item
  order and phases replay unchanged. Cancelled calls do not invoke tools.
- The original reader continues independently. Its suffix cannot enter
  display deltas, normal context, tool dispatch or partial recovery. Existing
  capture still receives bytes. Original-attempt usage/dollars settle once
  through ordinary accounting. Continuations and overlapping drains use
  existing concurrent admission/overshoot rules. Stop, interrupt and quit
  terminate drains; error/termination without final evidence remains unknown.
- A completed child releases its scheduler slot immediately; retained HTTP
  readers keep their runtime alive for settlement. Close waits specifically
  for committed cut drains, not unrelated request permits.
- Preparation → v5 promotion → owner commit → recipient mirror/prefix/results
  precede existing mailbox delivery and request dispatch. Projection stays
  under the family gate; the gate is released before independent draining and
  continuation. No network wait holds that gate.
- v5 promotion is lazy. Preparation alone is inert in v4. Failed promotion or
  an ambiguous commit can conservatively leave v5 without an applied cut.
  Inherited committed cuts also require v5 in forks, newly published children
  and kept sides: an older writer can alter their phase/opaque replay. This is
  the necessary exception to “a chat that never cut stays v4.” Uncut,
  uninherited v4 chats remain continuable by 0.1.135.
- Version-3 checkpoints carry cut evidence; v2 remains normal for untouched
  chats. Cold replay, checkpoints, slimming and forks preserve prefix/result
  bytes. Retargeting retains historical indexes but drops source execution
  authority. Recovery performs no automatic request or tool execution.
- App presentation is gated by the new capability and typed metadata. The
  permanent **“Reply cut for agent message”** marker is static; cancelled
  cards show **“Not run · agent message arrived”** and the full durable result.
  **“Receiving agent message”** is temporary secondary text. Older history
  and unqualified routes gain no new state or pause.

Implementation commits: `3d0eb462` (helper/accounting/recovery) and
`5b4fdb39` (app/history/accessibility). `e18961ff` performs missing
row repairs directly in `JournalReplayConsumer` before actor state publication,
removing the new actor-initializer escape warning and preserving row spans.
Existing unrelated Swift 6 migration warnings remain.

The fold-gap files, `SubagentToolView` wait headings, markdown preview work,
`AgentForkSeed.requirePublished` and `HostService.rebind` were left to their
workstreams. WorkspaceRefresh and SessionDisplay have small additive
capability/status changes; no prepared-delta accounting rewrite was made.

## Failing-first evidence and corrections

Logs below are relative to `$PI_BUILD_ROOT/logs`.

| Evidence | Failure, correction and result |
|---|---|
| `helper-red.log` | Initial two tests failed four assertions: partial-answer replay, typed journal/display metadata and continuation. Both then passed. |
| `loopback-first.log`, `loopback-second.log` | Cut projection initially treated a decoded JSON null usage as present usage. The validator now distinguishes null from reported usage; real loopback cuts pass. |
| `cutin-crashes.log` | Owner commit before projection exposed recovery consuming a message before attaching its reserved ID. Recovery now validates and writes the same ID. All crash points pass. |
| `helper-affected.log` | Run was stopped after close waited on ordinary synthetic permits. Close now waits only on committed cut drains. The focused regression suite passes. |
| `app-affected.log` | 112 tests ran; 111 passed and one test had two assertions failing because unchanged snapshots published the new status. Assignment is now change-checked; that class passes. |
| `inherited-cut-red.log` | One test failed two writer-fence assertions for inherited child/kept-side history. Both now carry v5, without inherited execution authority. |
| `cut-marker-red.log` | One test failed spinner visibility and accessibility-label assertions. The permanent marker now has no activity spinner and uses the exact accessible label. |
| `cutin-write-failures-2.log` | Owner-commit fsync failure could leave an ordinary partial row with the reserved cut ID. Partial recovery is retired before a commit can become ambiguous; reserved rows alone own recovery, and persistence failure closes admission. All append/fsync points pass. |
| `cut-shape-red.log` | One test failed four assertions for non-array message content and duplicate function call IDs. These now fail closed. |

Two early app build attempts were discarded: one overlapped a helper source
edit; the other found a missing explicit closure around an actor-isolated
gallery traversal. Neither is counted as test success. Early negative-route
loopback fixtures ended at a final answer, where queue-only mail correctly
defers; the final fixture uses an ordinary tool boundary. An initial fault
harness missed the fsync hook; that run was discarded and the corrected hook
was verified in its generated source.

## Validation commands and results

Final counts and logs are recorded below after the last source changes.

### Helper classes

```sh
NSUnbufferedIO=YES swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-verify" -j 4 \
  --filter 'MailboxCut|AgentCodex|AgentSteering(Boundary|Command|Legacy|Promotion|Retry|ReviewFix)|Provider(MediaType|StreamError|Streaming)|RoutingTests|ResponsesSampleTests|ResponseOrderTests|JournalCheckpointTests|JournalSlimmingTests|ForkAtReplyTests|ForkCloneTests|ForkPointTests|ForkReplayHandoffTests|SubagentForkTests|SubagentRecoveryTests|PartialReplyLogTests|SubagentAccountingTests|SideChatTests'
```

`helper-final-recovery.log`: **192 tests, 191 passed, one skipped, zero
failures** (also green before the initialization cleanup in `helper-final.log`). The only skip is the opt-in shared
fork-fixture **writer**, which requires `PI_WRITE_FORK_FIXTURE`; it is not a
failed test. Earlier focused runs: 189 tests (one skip), and 104 inheritance/
replay tests (one skip), zero failures after their fixes.

### Release helper and wire

```sh
python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-native-acceptance.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-subagent-cutin.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
```

**Release build passed** (`release-recovery-build.log`); **wire 41/41**,
**concurrent 4/4**, **acceptance 3/3**, and **cut-in loopback 23/23** passed
(`wire-recovery.log`, `concurrent-recovery.log`, `acceptance-recovery.log`,
`cutin-release-recovery.log`). The cut fixtures include both tool-bearing and bare
reasoning/commentary prefixes, `partial_answer`, root mail, two overlapping
drains, error/Stop/interrupt/quit/crash, cut and terminal in one write,
duplicate terminal, incomplete terminal, no usage, tokens without dollars,
dollars without tokens, and all five route negatives. Each original attempt
is counted once; the full reported 2,000 output tokens and $0.02 include the
discarded remainder. The continuation is observed while the held original
connection is still open and before its settlement. No tool sentinel file
appears, no discarded text enters durable messages or continuation input.

### Crash and failed-write matrix

```sh
python3 scripts/test-subagent-cutin-crashes.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-subagent-cutin-write-failures.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
```

Fault switches exist only in generated source under the build root. Production
source contains none. A separate clean helper reopens each fixture twice.

| Stage | Process crash | Append/fsync failure | Required recovery |
|---|---:|---:|---|
| Recipient preparation | Before + synced | Both | No cut inferred; mail remains governed by ordinary interruption rules. |
| Owner commit | Before + synced | Both | No prefix before commit; a durable/ambiguous committed prefix repairs from reserved rows. |
| Recipient commit mirror | Before + synced | Both | Parent authority repairs the missing mirror. |
| Prefix row | Before + synced | Both | Exactly one reserved assistant row. |
| Cancelled-call result | Before + synced | Both | Exactly one matching durable result; no tool dispatch. |
| Delivery preparation | Before + synced | Both | Uninserted mail is not acknowledged. |
| Delivery row | Before + synced | Both | Row identity and event IDs remain reserved; recovery acknowledges a durable row once. |
| Owner acknowledgement | Before + synced | Both | Exactly one paired recipient row. |
| Recipient delivery mirror | Before + synced | Both | Repair evidence; no second context insertion. |
| Continuation admission | Before + synced | Both | No automatic request on reopen. |
| Continuation dispatch intent | Before + synced | Both | Preserve possible execution and ordinary unknown accounting; no automatic retry. |
| Original drain settlement | Before + synced | Both | Original attempt only; no duplicate contribution or suffix projection. |
| Owner v5 promotion | Copy + rename | — | Before rename v4 remains; after rename v5 remains even without a cut. |
| Recipient v5 promotion | Copy + rename | — | Same fence; no inferred commit. |
| Active background drain | One | Transport-error/Stop/quit loopbacks | Retain prefix/mail; unknown without final provider evidence; no suffix resurrection. |
| **Total** | **29** | **24** | Every tested reopen is idempotent and dispatches no work. |

Final recovery reruns: **29/29** in `cutin-crashes-recovery.log` and
**24/24** in `cutin-write-failures-recovery.log`, after the actor-initialization
cleanup. The earlier full generated-build runs also passed in
`cutin-crashes-final.log` and `cutin-write-failures-final.log`. The final rerun
reused the fault binary (dispatch behavior unchanged) with the newly rebuilt
clean recovery helper:

```sh
python3 scripts/test-subagent-cutin-crashes.py \
  "$PI_BUILD_ROOT/swift-verify/debug/pi-native-host" --skip-build
python3 scripts/test-subagent-cutin-write-failures.py \
  "$PI_BUILD_ROOT/swift-verify/debug/pi-native-host" --skip-build
```

Clean shutdown after an injected fsync failure
is deliberately tested in addition to SIGKILL: it caught the partial-ID
collision that process-crash-only checks missed.

### Actual 0.1.135 writer

The released helper was copied into this build root and run only on generated
journals. SHA-256:
`516fe2485b1c98496020b15dc2000f2746f4e71d4a3af1a7bb7b23a4f6253e73`.

```sh
python3 scripts/test-subagent-cutin-downgrade.py \
  "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" \
  "$PI_BUILD_ROOT/compat/pi-native-host-0.1.135"
```

Parent and child v5 journals are refused with `legacy_session`, with and
without checkpoints, byte-for-byte unchanged. An uncut v4 parent opens. A
disposable v5→v4 marker mutation permits the old writer, proving that the
fence check detects a bypass. All four variants passed again against the final Release helper in
`cutin-downgrade-recovery.log`; the mutation is included in the total below.

### App, accessibility and gallery

```sh
scripts/test-macos.sh -jobs 4 'OTHER_SWIFT_FLAGS=$(inherited) -driver-batch-count 4' \
  -only-testing:PiAppTests/MailboxCutPresentationTests \
  -only-testing:PiAppTests/SubagentSteeringPresentationTests \
  -only-testing:PiAppTests/TranscriptNativeRowBehaviourTests
```

35 passed after the static-marker change (`app-marker-final.log`): 6 new
presentation tests, 10 steering presentation tests, 19 native row tests.
The final combined run passed **137 tests, zero failures** (`app-final.log`):

```sh
xcodebuild test-without-building -project PiApp.xcodeproj -scheme PiApp \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/MailboxCutPresentationTests \
  -only-testing:PiAppTests/TranscriptNativeRowBehaviourTests \
  -only-testing:PiAppTests/SubagentCodexPresentationTests \
  -only-testing:PiAppTests/SubagentCodexStorageTests \
  -only-testing:PiAppTests/SubagentSteeringPresentationTests \
  -only-testing:PiAppTests/SubagentTranscriptTests \
  -only-testing:PiAppTests/SubagentDiscoveryTests \
  -only-testing:PiAppTests/SubagentMetadataTests \
  -only-testing:PiAppTests/SubagentDisplayTests \
  -only-testing:PiAppTests/SubagentInspectorTests \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests \
  -only-testing:PiAppTests/HistoryReaderStateTailTests \
  -only-testing:PiAppTests/HistoryExtentTests
```

Gallery command, alone under the shared full-lane lock:

```sh
TEST_RUNNER_PI_APP_CUTIN_GALLERY="$PI_BUILD_ROOT/cutin-gallery" \
xcodebuild test-without-building -project PiApp.xcodeproj -scheme PiApp \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/MailboxCutGalleryTests
```

**One gallery test passed**, producing 12 PNGs (`cutin-gallery-final.log`). All 12 PNGs were opened and inspected: reasoning,
commentary and cancelled-call scenes × light/dark × 920/640 widths. Marker,
card and secondary-status text remain readable. At narrow width the expanded
card scrolls normally; it does not truncate the durable result. Accessibility
assertions check the marker/card labels; the permanent marker has its exact
label without a “Status:” prefix. No opaque reasoning is displayed.

## Mutation evidence

```sh
python3 scripts/test-subagent-cutin-mutations.py \
  --recovery "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-cutin-app-mutations.py
```

**53 mutations caught:** 45 helper (`cutin-mutations-final.log`), seven app
(`cutin-app-mutations.log`, individual logs under `cutin-app-mutations/`), and
one actual older-writer fence bypass (`cutin-downgrade-final.log`). The final
45-case run reused the generated baseline with `--skip-build`; its recovery
helper was `$PI_BUILD_ROOT/swift-verify/debug/pi-native-host`. After the
initialization cleanup, regenerated sources caught and restored all three
relevant mutations (`cutin-mutations-recovery.log`):

```sh
python3 scripts/test-subagent-cutin-mutations.py \
  --recovery "$PI_BUILD_ROOT/swift-verify/debug/pi-native-host" \
  --cases recovery_prefix checkpoint_authority ambiguous_commit_partial
```

Each helper mutant is built only in generated source,
fails a specific XCTest/loopback/recovery assertion, and passes with its switch
removed. App mutations temporarily edit only the listed presentation sources,
restore them in `finally`, then rebuild and pass the original classes in the
same DerivedData. No mutation switch remains in production sources.

Covered defects: delta/tool/final/unknown cut boundaries; missing opaque
state; unfinished items; terminal ordering; interleaved complete calls;
unqualified policy/identity/translated routes; dropped/reordered opaque data
and phase; no-mail cuts; lost queue-only/root mail; buffered tool execution;
missing cancellation results; regenerated result/delivery IDs; stale
generation/branch/tombstone; lost crash/checkpoint authority; v5 promotion and
actual older-writer bypass; cancelling or awaiting a drain; suffix leakage;
discarded-output usage omission; double settlement; interrupt not cancelling
a drain; acknowledging delivery before row sync; continuation without mail;
mistaking a cut for a produced/final result; reasoning-only Resume; inherited
child/side fences; ambiguous-commit partial resurrection; malformed message
content/duplicate call IDs; unknown typed versions/reasons; app capability,
version, card, history, secondary status, static marker and unchanged-state
publication regressions.

The first `reasoning_is_final` loopback mutant survived: ordinary continuation
does not invoke the follow-up finality predicate. A focused test now exercises
that predicate and final-result selection directly, with both cut and ordinary
assistant tails. Both finality mutants failed that test and passed after restoration. Two harness runs
misclassified real XCTest/KeyError failures as absent assertion evidence;
the harness now checks explicit assertions, and those cases were rerun.

## Load and isolation

Initial load was `{ 2.23 2.60 2.75 }`; Codex Computer Use was quit and replayd
was idle. Wire start/end and process inventory are in `load-wire-start.txt`,
`load-wire-end.txt`, `processes-wire-start.txt`. Builds used four jobs. The
shared lock was checked before heavy runs; focus-changing gallery runs held
it. The final gallery recorded start `{ 4.50 16.84 34.24 }` and end
`{ 11.58 17.35 33.91 }`, while focused helper work was also running. Its process
inventory records replayd at 0.0% CPU and no Codex Computer Use process
(`load-gallery-final-start.txt`, `load-gallery-final-end.txt`,
`processes-gallery-final.txt`). The final Release build/suite chain recorded start `{ 8.33 15.65 32.25 }` and
end `{ 5.68 9.70 24.41 }` (`load-release-recovery-start.txt`,
`load-release-recovery-end.txt`). No performance claim is made. No extra DerivedData copy or
named xcresult was created; older automatic xcresults were pruned, no test
clone remained, and text logs are the validation record.

## Owner-only live check — not run by the implementer

All seven new scripts passed Python syntax compilation into
`$PI_BUILD_ROOT/python-compile`. `scripts/probe-cutin-live.py` was
syntax-checked only. **It has not been run.**
The owner supplies their own native pinned Responses gateway, alias, expected
upstream model and `BELLO_PROBE_API_KEY` in their own shell. The key is used
only by the local relay and removed from the helper/tool environment. The
report directory must be new. Run once per boundary:

```sh
python3 scripts/probe-cutin-live.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" \
  --gateway "$OWNER_GATEWAY" --alias "$OWNER_ALIAS" \
  --expected-model "$OWNER_MODEL" --boundary reasoning \
  --report "$PI_BUILD_ROOT/live-reasoning" --limit-usd 1
python3 scripts/probe-cutin-live.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" \
  --gateway "$OWNER_GATEWAY" --alias "$OWNER_ALIAS" \
  --expected-model "$OWNER_MODEL" --boundary commentary \
  --report "$PI_BUILD_ROOT/live-commentary" --limit-usd 1
```

The root orchestration is generated locally; the worker makes real gateway
requests. The transparent SSE relay holds the selected completed item until
the root's real `send_message` is durably accepted, then forwards it. It adds
no upstream protocol. The original reply is paid through its discarded end;
the existing family limit retains normal concurrent overshoot semantics.

**Passing** means both invocations print `PASS` and produce `result.json`
showing: a real worker cut at the requested item, exact retained opaque prefix
and phase accepted in the continuation alongside the mail, natural receipt of
the original terminal, and one original-attempt settlement whose output
tokens and reported dollars match final upstream evidence. No discarded item
may appear in continuation input. No commentary/reasoning item, missing final
usage or missing reported dollars is **INCONCLUSIVE**, not a pass; use a new
report directory for a retry. Inspect the two reports and gateway request
records before the lead's release sign-off.

No product decision remains open. Live deployment acceptance is intentionally
unverified until the owner performs this check; the lead owns branch review,
integration with the other two workstreams, and the merged release gate.

## Lead review, round 2

Starting commit: `89f97b074254e7882157b318502205001c7fdeb6`.
The scope is F1 writer lifetime, F2 cut declines and Stop ordering, and F3
measured promotion cost. Evidence is under `$PI_BUILD_ROOT/logs/round2`.
The PERF-1 lock was respected before every heavy build/test; the initial
focused build waited while successive `a136-perf` measurement owners held it.

### F1: a single child writer across turns

A completed child with a committed-cut reader is retained in
`AgentSteeringCoordinator.drainingChildren`, without a scheduler slot or an
unfinished family job. A follow-up takes that exact `AgentSession` in the
coordinator's isolation. `prepareAgentTurn` installs its new lease, owner
budget generation, queue state, progress/cancellation callbacks and accepted
turn; normal submission delivery installs the new presented task, and each request starts a new observation generation.
The old reader has already stopped publishing deltas/observations and settles
only through its captured original `RequestScope`. It cannot update the new
turn's context or result. Reuse therefore does not wait for the natural end
of the original response.

When a reader finishes, deferred close claims only the still-parked job
instance. Removing that entry and publishing the closing fence happen with
no actor suspension. A claimed close blocks further opens of that child
until `settled` returns. With no drain, `finishJob` awaits `settled` before
removing the old job or releasing its slot, preserving the old ordering.
Duplicate finishers cannot claim an instance twice. Owner Stop/close and
`interrupt_agent` cancel parked readers and use ordinary once-only original
attempt settlement; absent final evidence stays unknown.

Failing-first loopback on round 1: `f1-loopback-red.log`, retained generated
fixture `failed-cutin-followup`. The worker completed turn 1 with its original
stream held; `/root` then issued `followup_task`. Turn 2 became `not_executed`
with `session_busy: Child is still settling` in the hosted path, and made no
third worker request. The direct coordinator's corresponding open can hit
`session_locked`. Both are the same early slot-release/writer-lifetime bug.

### F2: decline before preparation, Stop before ownership validation

The recipient snapshots request generation and context tail at lifecycle
creation. Under the family gate, recipient and owner pre-check holds, queue
edits, closed state, turn/execution/branch/generation, request permit, exact
dispatched admission scope, ownership, pending triggering events and cost.
A declined check returns nil without writing a preparation or retiring the
partial reply; later eligible items in the same stream can still cut.

After preparation, a late hold, edit or tombstone only changes the next
ordinary delivery boundary. Even an empty boundary continues from the
retained prefix. Stop/generation, cancelled permit, close and permit-cancelling
cost pause remain cancellation; I/O/consistency failures remain fail-closed.
Stop/permit precede owner validation. Partial retirement still precedes the
commit, including an ambiguous failed fsync. Recovery ignores an uncommitted
preparation if the normal reply reused its reserved partial row ID.

Round-2 focused evidence:

- `f1-f2-round1-red.log`: the **four** new ordering/decline/Stop regression
  tests against `89f97b07` source (generated copy, only barrier seams added)
  failed with **15 recorded failures**, including `accounting_damaged` after
  Stop and the refusal of a fresh turn. No production behavior fix was present
  in that generated source.
- `review-focused-2.log`: **13/13 passed** (new barrier tests, no-drain
  ordering and cut persistence/recovery). The initial run passed 12/13;
  its new-turn fixture needed to record the synthetic control-tool results
  before issuing an ordinary root request. The fixture correction is included.
- `f1-loopback-green.log`: **1/1 passed**, eight physical requests, both worker
  turns and the parent family complete with the first stream still held;
  one original settlement after release, valid journal chains and no replay
  on reopen. This is rerun with every loopback mode in the final matrix.

```sh
NSUnbufferedIO=YES swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-verify" -j 4 \
  --filter 'MailboxCutReviewTests|AgentSteeringDrainTests|MailboxCutPersistenceTests'
python3 scripts/test-subagent-cutin.py \
  "$PI_BUILD_ROOT/swift-verify/debug/pi-native-host" --mode followup
```

### F1 allocation fence and F3 promotion

A second review of the handoff found that claiming the parked writer inside
`run`, after its awaited owner-budget check, was too late: deferred close could
win after the new job was allocated. Allocation now claims the writer before
any suspension. The new latch test holds turn 2 before the budget check and
runs the old deferred-close callback; it must not close the assigned instance.
Cost-held turns use the same writer-release path, so Resume cannot open a second
writer while a cancelled drain is still settling. A claimed close awaits both
owner settlement and the child's mirror before releasing the runtime.

F3 was measured before changing promotion, in Release (`-Osize`, arm64) with
50,000 generated message rows: **209,714,720 bytes** (200.0 MiB). All files and
build products stayed under `PI_BUILD_ROOT`. The isolated benchmark target
avoids an unrelated full-Release-test-target compile error: `SideOriginReadProbe`
is available only in Debug. It uses the production sources and the same
`swift-host` build root. `promotion-copy-200.log` records:

| Promotion | Wall time | Family-gate hold |
|---|---:|---:|
| v3 | 763.262 ms | 763.167 ms |
| v4 | 829.761 ms | 829.719 ms |
| v5 | 743.885 ms | 743.857 ms |

The 1-minute load was **2.02 at start, 2.18 at end**, with our full-lane lock
held. The first trial used a larger 216,514,727-byte fixture; it is retained in
`promotion-copy.log` but the table uses the corrected 200 MiB fixture. The
measurement exceeds 250 ms, so all three promotions now use the existing
`fclonefileat` helper, verify the original marker at its checked offset,
rewrite only its same-length marker, verify the new digest, fsync, rename,
and fsync the directory. A failed clone removes its partial temporary file
and falls back to the existing line-copy implementation. The sidecar writer
lock stays held throughout. Fault hooks exist only in generated test sources.

`promotion-focused-2.log`: **51 executed, 48 passed, three opt-in skips, zero
failures**. This includes the new allocation/close race, clone/fallback byte
preservation and writer exclusion, bad marker/length rejection, F1/F2 barriers,
existing cut recovery and fork clone checks. An earlier compile attempt exposed
a throwing XCTest autoclosure in the nonthrowing clone seam; the fixture now
uses explicit `do/catch`. One Release benchmark build was discarded because
its source was edited during compilation; it supplied no measurement.

`promotion-clone-200.log`, on the final implementation (`d5f1d1ef`), measured
50,000 rows / **209,714,621 bytes**. The small envelope-size difference from the
baseline is generated IDs/timestamps; the message payload and row count match.
The gate metric encloses the production promotion call in `AsyncGate`, not the
rest of a cut transaction.

| Promotion | Clone wall time | Clone family-gate hold |
|---|---:|---:|
| v3 | 30.482 ms | 30.366 ms |
| v4 | 27.264 ms | 27.237 ms |
| v5 | 18.140 ms | 18.106 ms |

Load was **2.77 → 2.87** with the full-lane lock held. V5's gate-held promotion
fell from **743.857 to 18.106 ms**; all three are below 250 ms. The lock logs
also record waiting for PERF-1; its lock was never taken or removed while held.

### Round-2 validation counts and final-commit repetition

Production source is `d5f1d1ef` (following `b5f97fea`); the remaining commit
changes only this record and the release checklist. The first complete set
of source checks is below. Logs are under `$PI_BUILD_ROOT/logs/round2/`:
`preliminary/` for the matrix and `steering-crashes-fixed.log` for the corrected
older-suite invocation. Each matrix log records HEAD and start/end load.

| Suite | Result |
|---|---:|
| Affected helper classes | **316 executed: 313 passed, 3 opt-in skips, 0 failures** |
| App cut presentation + subagent steering presentation | **16/16 passed**, both before mutations and after source restoration |
| Release wire / concurrent / acceptance | **41/41**, **4/4**, **3/3** |
| Release cut-in loopback modes | **24/24**, including held-drain follow-up |
| Cut-in crash points | **37/37** |
| Cut-in write/fsync/promotion failures | **36/36** |
| Shared v3/v4/v5 promotion crash/failure/reopen matrix | **120/120** |
| Existing v4 steering crash matrix, with actual 0.1.134 refusal checks | **44/44** |
| Actual 0.1.135 downgrade variants | **4/4**: checkpoint, cold, uncut v4, fence bypass control |
| Mutation cases | **61 caught**: 52 helper (each restored), 7 app (sources restored), 0.1.135 fence bypass, 0.1.134 fence bypass |

The helper skips are the existing opt-in shared fork-fixture writer and the
two promotion fault-harness entry points. Those two entries run explicitly
in separate processes in all 120 promotion cases; none of those cases skipped.
The new helper mutation names are `promotion_clone_ignored`,
`decline_cancellation`, `late_hold_cancellation`, `owner_before_stop`,
`parked_reopen`, `close_order`, and `claim_after_suspension`. Each failed its
specific assertion and passed with its switch removed. The allocation mutant
recreates the gap found after the first F1 implementation.

The initial older steering invocation passed 36 cases, then its name-adoption
fixture guard rejected the missing `--older-helper` argument; this was not a
production assertion failure. The genuine helper was built from local tag
`v0.1.134` / `9b6c9486fda33e1f9714183f223e143ce56df0e6`, under
`$PI_BUILD_ROOT/compat-134-{source,build}`, and the entire 44-case suite was
rerun with it. Its SHA256 is
`dd1199ce328568364e4d9810a827ae2637e231e3d92a6ae850ea65ac80d1c5c1`.
The actual 0.1.135 helper remains
`516fe2485b1c98496020b15dc2000f2746f4e71d4a3af1a7bb7b23a4f6253e73`.
No release commit, tag or published history was changed.

The matrix started at load **2.36** and ended at **4.90** (one-minute values).
The corrected older steering run ended at **8.26** after the generated
concurrency stress. These are correctness runs, not performance evidence.
The Release F3 measurements above both stayed below 4. Process inventories
show replayd idle at **0.0%** and no Codex Computer Use process. The full-lane
lock was held for these runs; waits for PERF-1 are retained in the run logs.

Exact main commands (with `PI_BUILD_ROOT` exported to the specified build root):

```sh
swift build --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-host" --configuration release \
  --arch arm64 -Xswiftc -Osize -j 4 --product pi-native-host
python3 scripts/build-bundle.py
swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-verify" --skip-build \
  --filter 'MailboxCut|AgentCodex|AgentSteering|FamilyLimitPauseTests|Provider(MediaType|StreamError|Streaming)|RoutingTests|ResponsesSampleTests|ResponseOrderTests|JournalCheckpointTests|JournalSlimmingTests|JournalPromotionTests|ForkAtReplyTests|ForkCloneTests|ForkPointTests|ForkReplayHandoffTests|SubagentForkTests|SubagentRecoveryTests|PartialReplyLogTests|SubagentAccountingTests|SideChatTests'
python3 scripts/test-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-native-acceptance.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-subagent-cutin.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-subagent-cutin-crashes.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-subagent-cutin-write-failures.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" --skip-build
python3 scripts/test-subagent-cutin-mutations.py --recovery "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-journal-promotion-faults.py \
  --fault-bundle "$PI_BUILD_ROOT/cutin-mutation-build/debug/PiNativeHostPackageTests.xctest" \
  --recovery-bundle "$PI_BUILD_ROOT/swift-verify/debug/PiNativeHostPackageTests.xctest"
python3 scripts/test-subagent-steering-crashes.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" \
  --skip-build --older-helper "$PI_BUILD_ROOT/compat/pi-native-host-0.1.134"
python3 scripts/test-cutin-app-mutations.py
python3 scripts/test-subagent-cutin-downgrade.py \
  "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" "$PI_BUILD_ROOT/compat/pi-native-host-0.1.135"
python3 scripts/measure-journal-promotion.py --label promotion-clone-200
```

The existing steering fixture was generated with its `fixture_binary()` helper,
adding `-j 4` to its Swift build command, in the same build root. No fault or
mutation switches were added to production sources. The generated fault helpers
use Debug; their cut-in cold recovery uses the normal Release helper. The
standalone promotion matrix reopens with the clean helper XCTest bundle.

Before pushing, the documentation-only final commit must repeat every table
suite using the already-built, unchanged implementation and generated helpers
(`--skip-build` for crash and helper-mutation generation). Its logs go to
`logs/round2/final/`, with HEAD in each log; the app mutation runner still
rebuilds and restores its test host. `logs/round2/completion-run.log` records
that final HEAD and the matrix outcome. The F3 number above is the separate
quiet Release measurement of the same implementation. The owner-only live
probe remains outside this offline review task.
