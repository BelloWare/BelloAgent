# AGENTS-1 helper validation — 0.1.135

Worktree `wt-a135-agents`, branch `dev/a135-agents`, based on `dev/next` b2fb1347.
All builds, generated fixtures and text logs use
`PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a135-agents`.
No installed app, real chats, preferences, Keychain or credentials are used.
No app source or app tests are part of this helper workstream.

## Contract checkpoint

The first commit provides v4 schemas/strict validation, names/addressing, fixed
prompts, the indented envelope renderer, typed delivery events, inherited-row
markers, additive origin/turn/summary fields, and the v4 receipt serializer.
At this checkpoint the existing coordinator still advertised v3; the runtime
commit below activates v4.
The design appendix **Wire contract for the app (v4)** is the UI integration
contract, including exact call/result, delivery, inheritance and pending-mail
examples. Three conservative choices are flagged there as **needs owner decision**:
list cursor, read-only detail modes, and locally derived spawn descriptions.

Commands (from the worktree, with the build root exported):

```sh
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" --filter SubagentCodexContractTests
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" --filter 'SubagentCodexContractTests|SubagentSteeringContractTests'
xcodegen generate --quiet
```

`logs/contract-red.log` records the initial absent-v4-API compilation failure.
The first green attempt caught two fixture typing errors (`JSON` construction
and array indexing); these were fixed. `contract-green-2.log` was invalidated
because an additional test was saved while SwiftPM was building. Neither is
counted as a behavioral failure or passing validation. Runtime failing-first
and guard mutation evidence follows with the runtime implementation.

`logs/contract-green-3.log`: **10 tests passed, zero failures** (6 new v4
contract tests and 4 existing v3 contract tests). XcodeGen produced no project
change. Contract commit **114cd880** was pushed immediately to
`origin/dev/a135-agents`, before runtime implementation, for the app workstream.

## Runtime implementation

Runtime checkpoint **6d99dbd8** was pushed for app integration while the final
crash matrices were completing. The fixture correction and completed evidence
are in the following validation commit.

The existing steering coordinator, admission gates, operation receipts, family
mailbox, delivery preparation/acknowledgement records, recovery and family wait
now carry the v4 contract. There is no second coordinator. Production advertises
`subagents-codex-v4`; legacy fixtures explicitly select their frozen v3 contract.

- The six tools use canonical lifetime names, root-only spawn, sibling addressing,
  strict schemas, bounded list paging, summary-only waits and durable acceptance.
- Full forks use the parent's complete boundary before the spawning assistant
  row, strip human consent, retain inherited row identities, and share the frozen
  prompt, tools and cache identity. The hand-off is a typed NEW_TASK. A durable
  seed reference and a request-time publication check prevent execution against
  an incomplete child journal.
- Queue-only messages to idle agents remain pending without opening turns or
  holding family closure. Pending messages after a final answer wait for the
  next task. Every turn sends its whole final answer, with the specified 1 MiB
  validity bound and explicit truncation notice. Interrupt notes distinguish
  parent, sibling and human interruption; a parent interrupt suppresses its own
  redundant automatic result.
- Delivery drains all fitting events, fairly across senders and FIFO within each
  sender. The report rate limit, small pending caps, eight-event/16 KiB delivery
  caps and one-message boundary cap are gone. Message-size validation and the
  whole-message context-fit check remain.
- Replay/checkpoint records preserve names, fork references, sender/recipient,
  turns, queue-only state and interrupt provenance. Promotion uses the existing
  copy/sync/rename fence with the v4 marker. V3 names are adopted once without
  rewriting history. Cost-paused v3 runs retain their old tools until a fresh
  root task selects v4.
- App wire output adds names/fork mode, nativeAgentDelivery v2, nativeInherited,
  message/turn details and waiting-next-turn state. The receiving turn in detail
  paging is updated by the same delivery acknowledgement as the transcript row.

No app source changes or compile fixes were needed. Deferred §11 work was not
implemented. All twelve JSON example blocks in the contract appendix remain
byte-for-byte unchanged from 114cd880 and parse successfully.

## Failing-first evidence and fixes found

Logs are under `$PI_BUILD_ROOT/logs`. These are behavioral failures, separate
from the initial contract compilation failure documented above:

| Log | Tests / recorded failures | Cause and final behavior |
| --- | --- | --- |
| `runtime-red-2.log` | 2 / 4 | New tools and full-fork behavior were absent before the runtime implementation. |
| `fork-repair-red.log` | 1 / 1 | A partial child seed could not recover. Recovery now completes only missing validated seed rows, seals the interrupted turn without execution, and permits an explicit later task. |
| `parent-stop-red.log` | 1 / 2 | Whole-chat Stop lost the human initiator. Durable family intent now survives cancellation and late mirrors. |
| `publication-red.log` | 1 / 2 | Failed child publication left an initial task pending and held family closure. The existing sealing path now disposes it and emits its terminal result. |
| `delivered-turn-red-2.log` | 1 / 1 | An idle message delivered in turn 2 still reported turn 1 in details. Delivery acknowledgement now persists the receiving turn. |

Guard-by-guard broken/restored executions are also recorded by the mutation
runner below. Early attempts exposed fixture issues (waiting for terminal status
before the separately appended result, incorrect detail-page selection, and a
parser consuming the separator between adjacent envelopes). Those fixture
assumptions were corrected. The mutation baseline also exposed a missing binding
when recreating a never-published child journal; recovery now uses the accepted
parent connection and the child's frozen model. Invalidated/failed attempts
remain in the build-root logs and are not counted as passes.

## Focused helper tests

All commands run from the worktree with:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a135-agents
```

```sh
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" --filter 'AgentCodex|SubagentCodexContract|AgentMailboxPolicy'
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" --skip-build --filter 'Agent(Codex|Steering|FamilyRecovery|Mailbox)|Subagent|JournalCheckpoint|FamilyLimitPause|SideCache|SideDelegation|SideFork'
```

`codex-final-1.log`: **26 passed, 0 failed**. `focused-final.log`:
**306 passed, 0 failed**. The broader selected classes were built earlier using
the second command without `--skip-build`. This is a focused selection, not the
full helper suite; no app suite was run. The selection includes one matching
Subagent test method in SideBudgetTests. Per-class counts follow.

| Class | Passed |
| --- | ---: |
| `AgentCodexDeliveryTests` | 2 |
| `AgentCodexMessagingTests` | 6 |
| `AgentCodexPersistenceTests` | 5 |
| `AgentCodexRuntimeTests` | 4 |
| `AgentFamilyRecoveryTests` | 4 |
| `AgentMailboxPolicyTests` | 3 |
| `AgentSteeringBoundaryTests` | 6 |
| `AgentSteeringCommandTests` | 6 |
| `AgentSteeringLegacyTests` | 1 |
| `AgentSteeringPromotionTests` | 2 |
| `AgentSteeringRetryTests` | 1 |
| `AgentSteeringReviewFixTests` | 7 |
| `FamilyLimitPauseTests` | 110 |
| `JournalCheckpointTests` | 7 |
| `SideBudgetTests` | 1 |
| `SideCacheTests` | 6 |
| `SideDelegationTests` | 2 |
| `SideForkTests` | 3 |
| `SubagentAccountingTests` | 9 |
| `SubagentAdmissionTests` | 6 |
| `SubagentCacheTests` | 4 |
| `SubagentCodexContractTests` | 6 |
| `SubagentContractTests` | 4 |
| `SubagentCoordinatorTests` | 23 |
| `SubagentForkTests` | 12 |
| `SubagentJournalTests` | 8 |
| `SubagentPermissionTests` | 9 |
| `SubagentPolicyEffortTests` | 25 |
| `SubagentRecoveryTests` | 17 |
| `SubagentSteeringContractTests` | 4 |
| `SubagentToolTests` | 3 |

## Mutations

```sh
python3 scripts/test-subagent-codex-mutations.py
```

`mutations-final.log`: **39/39 guard mutations caught**, followed by **39/39
restored cases passing**; the fixture baseline is **26 tests passing**. Each
mutation must produce a nonzero XCTest assertion/throw failure, and zero selected
tests is rejected. The runner injects switches only into a generated source copy
under the assigned build root; production has no mutation environment controls.
Individual failing/restored logs are in `logs/codex-mutations/`.

| Guard group | Mutation names |
| --- | --- |
| Names and root-only spawn | `name_resolution`, `name_unique`, `root_spawn` (both admission checks) |
| Fork contents and identity | `fork_boundary`, `fork_consent`, `fork_cache`, `fork_prompt`, `fork_tools` |
| Unforgeable payload framing | `envelope_indent` |
| Sibling communication | `sibling_message`, `sibling_task` |
| Idle closure and final deferral | `idle_closure`, `final_deferral` |
| Whole final answer each turn | `whole_final`, `every_turn` |
| Wait bounds and wake reasons | `wait_bounds`, `wait_upper`, `wait_mail`, `wait_steer`, `wait_stop`, `wait_cost` |
| Interruption and undelivered notices | `interrupt_note`, `parent_stop`, `late_interrupt_note`, `undelivered_envelope`, `idle_v2_interrupt` |
| Adoption, promotion and publication | `name_adoption`, `marker_promotion`, `fork_publication_repair`, `publication_closure`, `publication_request_fence` |
| Delivery and retained validity limits | `eight_events`, `one_message`, `byte_cap`, `sender_fairness`, `context_fit`, `delivered_turn`, `report_caps` |
| Frozen v3 Resume | `frozen_v3_pause` |

The actual older-binary downgrade check and its marker mutation are recorded
with the crash matrix below.

## Release helper and wire suites

```sh
python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-native-acceptance.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
```

`release-build-final.log`: Release build passed. Existing Swift 6 isolation
warnings remain warnings under the package's current language mode.
`wire-final.log`: **41 passed, 0 failed**. `concurrent-final.log`: **4 passed,
0 failed**. `acceptance-final.log`: **3 passed, 0 failed**. All HTTP services were
generated loopback fixtures with synthetic keys. Timing is incidental; these
are correctness checks, not performance measurements.

## Streaming and crash matrices

Commands below ran serially while holding
`/Users/admin/Library/Caches/BelloSwiftWork/full-lane.lock`. The runner acquired
the directory atomically, recorded its PID/owner, and removed only its own lock
in `finally`, including on failure. The app workstream's preceding lock was
allowed to finish; it was never removed by this workstream.

```sh
python3 scripts/test-subagent-streaming.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" --steering --modes flow loop speakers rate
python3 scripts/test-subagent-crashes.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" --steering --older-helper "$PI_BUILD_ROOT/older-0134-build/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-subagent-crashes.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" --skip-build
```

`streaming-final.log`: **4/4 modes passed** against the final Release helper:

| Mode | Children | Requests | Accepted messages to root | Delivered parent events |
| --- | ---: | ---: | ---: | ---: |
| flow | 2 | 13 | 1 | 4 |
| loop | 41 | 124 | 0 | 41 |
| speakers | 16 | 123 | 80 | 96 |
| rate | 16 | 66 | 48 | 64 |

Flow checks exact tool/prompt-cache behavior, child history paging, inherited
markers without consent, NEW_TASK/MESSAGE/FINAL_ANSWER details and two child
turns. The 41-child loop exceeds the removed coordination limit. Speakers and
rate verify accepted messages survive the former pending/rate caps and that a
delivery can contain more than eight events. Timing and RSS in the JSON report
are incidental, not a release performance claim.

Crash fixtures were built from this worktree into `steering-crash-source` /
`steering-crash-build` and `subagent-crash-source` / `subagent-crash-build` under
the assigned build root. The scripts inject SIGSTOP barriers only into these
generated copies; cold recovery uses the unmodified Release helper. The v2
fixture selects the historical v2 policy explicitly. Build commands:

```sh
swift build --package-path "$PI_BUILD_ROOT/steering-crash-source" --scratch-path "$PI_BUILD_ROOT/steering-crash-build" --product pi-native-host
swift build --package-path "$PI_BUILD_ROOT/subagent-crash-source" --scratch-path "$PI_BUILD_ROOT/subagent-crash-build" --product pi-native-host
```

The real 0.1.134 helper was built from `git archive v0.1.134 packages/swift-host`
extracted under `$PI_BUILD_ROOT/older-0134-source`:

```sh
swift build --package-path "$PI_BUILD_ROOT/older-0134-source/packages/swift-host" --scratch-path "$PI_BUILD_ROOT/older-0134-build" -c release --product pi-native-host
```

It refuses promoted v4 owner and child journals with `legacy_session`, leaving
their bytes unchanged. At `promotion-replaced`, changing only the format marker
to v3 in a disposable copied journal makes that same older binary open it. This
**additional downgrade-marker mutation is caught**, with no model request.
Together with the 39 XCTest mutations, this is **40 guard mutations**.

`crash-v4-final.log`: **39/39 edges passed**. This includes the six new
fork-seed, sibling-delivery and name-adoption edges; legacy snapshot and v4
promotion; durable acceptance, mirrors, recipient rows, acknowledgements,
terminals and closure; and Stop/shutdown/update with **16 active + 2 queued**
agents. Cold recovery made no model request, explicit Resume did not re-execute
accepted child work, effects and deliveries were not duplicated, and repeated
reopen did not double-charge.

`crash-v2-final.log`: **21/21 edges passed** with the original v2 matrix.
The final runner exited successfully and released its own full-lane lock.

The first full v4 attempt (`crash-v4-attempt-1.log`) passed 19 edges, then timed
out waiting for `report-receipt-synced`: the fixture observed only the last row
of a sync, although a v4 message receipt can share that sync with later rows.
The fixture now retains every unsynced row and observes all of them after sync.
The first correction covered only copied-row appends (attempt 2 passed 3 edges
before the ordinary append hook was found missing). Both append paths are now
instrumented and asserted during fixture generation. These were fixture hook
failures; production durability code did not change.

## Decisions and deviations

The appendix records conservative choices for additive list paging, read-only
message/turn detail modes, and locally derived spawn descriptions. It also flags
**needs owner decision** for an accepted running task interrupted before
delivery: retain v3's root notice as a typed MESSAGE (implemented), notify its
original sender instead, or rely on the final answer plus inspectable record.
Queue-only mail never produces that notice. No stable JSON example changed.

Safety refinements within the design are documented in the same appendix:
complete only missing fork-seed publication during recovery without dispatch;
fail closed on conflicting evidence or missing publication after possible
execution; retain a paused v3 contract until a fresh task; preserve human Stop
intent before cancellation. These use the existing durable paths.

The helper work is complete. The lead owns app integration and the full merged
release gate. No full helper suite, app suite, installed app or live provider
was used. `git diff --check`, Python compilation of the changed scripts, and
`xcodegen generate --quiet` passed; XcodeGen produced no project-file change.


## Lead review round 2 — F1–F5

The parent plan now carries a small fork reference: `from`, `cutoffEntryId`,
ordered `ids` and a SHA-256 digest of ordered `[id, content, nativeInherited]`
tuples. Those fields round-trip through child message records. Acceptance keeps
bodies in a local variable only until child publication; plans, operation state
and checkpoint helper JSON contain no seed bodies. The live publication fence
and recovery share reference/order/digest checks. Partial recovery re-applies
inheritance to the reopened parent's context before the spawning assistant row,
checks the digest and existing child prefix, then appends only missing rows.
Missing or changed parent rows leave turn 1 `not_executed` and a later explicit
follow-up refused with `subagent_fork_publication`, without a child request.

Checkpoint version is back to **2**. The existing family-scoped effort/codex
markers still require full replay for old derived family state, while ordinary
chats retain their cache shortcut. A nameless child sender fails closed instead
of acquiring `/root` authorship. Envelope framing now normalizes vertical tab
and form feed as well as the other members of `CharacterSet.newlines`.

The focused v4 pause tests cover a forked worker paused after its first tool
round, same-turn Resume, one seed/reference and one NEW_TASK, delivery of the
whole 30,000-byte final answer, and pending queue-only mail to an idle sibling that
does not prevent closure. They also exposed a real Stop gap: the cost-pause
guard suppressed human provenance. Explicit Stop now durably records “the user”
on paused turns, including across reopen; internal pause, close, compaction and
error stops are distinguished. Parked-turn Resume semantics are preserved.

The lead's root-notice decision is recorded in the appendix, along with the
three settled cursor/detail/description choices. All **12 JSON example blocks**
are byte-for-byte unchanged; concatenated-block SHA-256:
`5a20a763d1190cdc305619b4e54c2cda986a9c9e51896e00f5c748348acd8dac`.
No app source, app suite, full helper suite, release tag or publication is part
of this round.

### Failing-first and sizes

Logs for this round are under `$PI_BUILD_ROOT/logs/round2/`.

- `red-behavior.log`: **5 tests, 23 assertion failures** against the pre-fix
  implementation: body retention/size, order/digest definition, child sender,
  version-2 cache and VT/FF framing.
- `red-recovery-pause.log`: **3 tests, 9 assertion failures in 2 tests** against
  the pre-fix implementation; the same-turn v4 Resume test already passed.
  Changed/missing parent bodies incorrectly permitted follow-up, and paused
  human Stop lost provenance before and after reopen. The old recovery entry
  accepted an unused `context` argument solely to compile the current fixture;
  its original behavior was otherwise unchanged. Source files were restored in
  `finally` before green validation.
- Initial compile attempts and pause-fixture iterations are retained but not
  counted as regression evidence. The pause fixture was corrected to journal
  actual tool receipts and to assert retained paused state rather than require
  a paused turn to seal immediately. `green-new-2.log`: **39 passed, 0 failed**.

The deterministic size fixture has one 4 MiB synthetic context row and four
forked spawns, with identical small operation metadata. Values are encoded
agent-operation envelope and checkpoint **helper JSON** bytes (not the whole
checkpoint file):

| Fixture | Operation before | Operation after | Helper JSON before | Helper JSON after |
| --- | ---: | ---: | ---: | ---: |
| 16-byte filler | 1,358 | 1,238 | 10,569 | 9,609 |
| 4 MiB filler | 4,195,646 | 1,238 | 33,564,873 | 9,609 |

The separate real acceptance test writes a multi-MiB fork through the live
coordinator, verifies the physical journal operation row is **under 16 KiB**,
checks the actual checkpoint helper excludes the body, and validates the
published child. This also exercises the in-memory body transport.

### Focused helper validation

From the worktree, with the assigned build root exported:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a135-agents
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" --filter 'AgentCodex|SubagentCodexContract|JournalCheckpoint|FamilyLimitPauseTests/testV4'
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" --skip-build --filter 'Agent(Codex|Steering|FamilyRecovery|Mailbox)|Subagent|JournalCheckpoint|FamilyLimitPause|SideCache|SideDelegation|SideFork'
```

`focused-final.log`: **315 passed, 0 failed**. Per-class counts match the earlier
306-test table except: AgentCodexMessaging **7**, AgentCodexPersistence **8**,
AgentCodexRuntime **5**, FamilyLimitPause **112**, JournalCheckpoint **8**, and
SubagentCodexContract **7**. The same one matching SideBudget test is included.
Any fixture timing printed in this correctness lane is not performance evidence.


### Release and mutation validation

```sh
python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-native-acceptance.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-subagent-codex-mutations.py
```

`release-build.log`: Release build passed (existing Swift 6 isolation warnings).
`wire.log`: **41 passed**; `concurrent.log`: **4 passed**; `acceptance.log`:
**3 passed**, all zero failures. Generated loopback services and synthetic keys
only. `mutations.log`: **59/59 caught and 59/59 restored**, with a **34-test**
unmodified baseline. Each fault must cause an XCTest assertion/throw failure;
zero selected tests and compilation failures do not count. Per-fault logs remain
in `$PI_BUILD_ROOT/logs/codex-mutations/`; only generated source copies contain
mutation switches.

The prior 39 guards were rerun, with fork-boundary/publication hooks updated for
the reference representation. Twenty additions:

| Area | Mutations caught |
| --- | --- |
| Seed body transport and exclusion | `fork_body_transport`, `fork_body_exclusion` |
| Reference, digest, order and completeness | `fork_reference`, `fork_digest`, `fork_order`, `fork_recovery_completeness` |
| Parent reconstruction and fail-closed follow-up | `fork_parent_digest`, `fork_parent_missing`, `fork_recovery_inherited`, `fork_followup_fence` |
| Checkpoint compatibility | `checkpoint_v2`, `checkpoint_family_gate` |
| Child sender and newline framing | `child_sender`, `envelope_vtab`, `envelope_formfeed` |
| V4 pause/Resume | `v4_resume_task`, `v4_resume_seed`, `v4_pause_final`, `v4_pause_idle_mail`, `v4_pause_stop` |

### Streaming and crash validation

The full-lane runner atomically acquired the shared lock, recorded its unique
owner/PID and released only its own lock in `finally`, including failed attempts.
It never removed another workstream's lock. Flow and loop ran serially before
the crash matrices. Compilation of the mutation baseline had finished before
this lane; independent fixture mutation checks continued separately.

```sh
python3 scripts/test-subagent-streaming.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" --steering --modes flow loop
python3 scripts/test-subagent-crashes.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" --steering --older-helper "$PI_BUILD_ROOT/older-0134-build/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-subagent-crashes.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
```

`streaming.log`: **2/2 modes passed**. Flow: **2 child conversations, 14 requests,
4 parent events**. Loop: **41 child conversations, 124 requests, 41 parent
events**. Printed elapsed times are incidental correctness-fixture observations,
not isolated performance measurements.


The v4 matrix passes **44/44 unique edges**, and v2 passes **21/21**. The v4
result consists of the first **40** edges in `crashes-v4-2.log` plus the final
**4** in `crashes-v4-remaining.log`; `crashes-v2.log` contains the complete v2 run.
The targeted continuation after the fixture correction was:

```sh
python3 scripts/test-subagent-crashes.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host" --steering --older-helper "$PI_BUILD_ROOT/older-0134-build/arm64-apple-macosx/release/pi-native-host" --skip-build --points fork-parent-missing stop shutdown update
```

Five new v4 edges cover inherited-body before/synced/written boundaries and
changed/missing parent rows. Every recovered fork checks the reference's fixed
field set, child ID order and recomputed content digest. Both damaged-parent
edges seal turn 1 `not_executed`, refuse an explicit follow-up with
`subagent_fork_publication`, and dispatch **zero child requests**. The old
interrupted-turn no-replay and exactly-once delivery assertions remain.

Two harness corrections are retained as explicit failed attempts:
`crashes-v4.log` stopped because an uncompacted early-promotion chat has no
checkpoint automatically; the generated fixture now invokes the helper's real
`refreshCheckpoint` on close, scanning from the start, only when its fixture
checkpoint flag is set. No production flag was added. `crashes-v4-2.log` then
reached the missing-parent edge but the synthetic row deletion also broke the
journal's single-branch chain. The fixture now reconnects that one predecessor
link so it exercises missing model context, rather than the independent branch
integrity guard. The 40 unaffected passed edges were retained; the four remaining
edges ran under a newly acquired full-lane lock. Neither failed invocation is
reported as a clean complete matrix run.

For every promoted v4 owner/child encountered, the downgrade fixture first
writes a **version-2 `.meta` through current helper checkpoint code**, verifies
its header/marker/last/state/rebind byte hashes against the journal, then opens
it with the actual **v0.1.134** binary previously built from the release tag.
It refuses with `legacy_session` and leaves **both journal and `.meta` bytes
unchanged**. The `promotion-replaced` marker-removal mutation is caught again:
the older binary opens the disposable copy when its v4 fence is removed, with
no model request. Total round-2 mutations: **59 XCTest + 1 actual older-binary
marker mutation = 60 caught**.

No assigned helper finding remains unresolved. App integration and the merged
release gate remain with the app workstream and lead.
