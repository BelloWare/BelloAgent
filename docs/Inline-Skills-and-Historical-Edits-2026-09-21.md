# Inline skills and historical edits — implementation record

September 21, 2026. Repository `BelloWare/BelloAgent`, branch `main`.
Started from `3ac6677`, preserving the intervening fresh-history/live-update and
micro-cost changes. Implements the uploaded **Implementation-Plan.md** prepared
against `1b58c8a`; no reset, architecture change, push or release is included.

## Behavior

Type a slash token anywhere in prose, or move the caret into one, to find a
skill. Accepting a choice adds its explicit chip and replaces only the token.
Surrounding text stays intact; inline arguments start empty. Undo/redo restores
both text and authorization. Return/Tab selects without sending, arrows reach
the complete result list, Escape closes, and marked text belongs to the input
method. Command-Return never implicitly chooses a skill. Deliberate standalone
`/side`, `/fork`, `/debug`, `/compact` and `/skill arguments` keep their distinct
command behavior. Pasted/restored text does not grant permission.

Search is shared between the inline list and Skills inspector: case/diacritic
folding, exact/prefix/component/substring ranking, then description/path AND-term
matches. A standalone `/name` query is normalized; multi-component paths are
preserved. Ties use canonical identity/path. All discovered results are ranked
before the bounded scroll viewport. Disabled or unavailable skills remain
inspectable but cannot be selected. Separate loading, failure, partial discovery,
no-match and Retry states prevent discovery errors from masquerading as an empty
catalog. Project/main/side loads have independent origin and capability scopes.

Modify a retained user input on the selected conversation branch, including
one summarized out of active context or outside the initial three-turn window.
The input loader fetches the original display text, never the truncated row or
expanded skill body. Recorded attachment references and selected skills return
to the composer. Missing/changed attachments block Send until removed/replaced;
legacy inputs without reliable selections require explicit review/reselection.
Saved read-only-tool chats can be edited. Archived/imported/unkept side policies,
active runs and nonempty queues still apply; no work is silently discarded.

Entering edit mode changes no conversation. The ordinary unsent draft is kept
and Cancel restores it. Late target loads, catalog replies and acknowledgements
cannot overwrite newer input or steal another pane's focus. If typing changes
the edited draft while its acknowledgement is pending, that newer draft remains
in edit mode, now attached to the accepted replacement occurrence rather than
the abandoned target. An explicit notice explains this; Cancel still restores
the ordinary draft, and the next Send can amend the replacement once idle.
Context inspection is labelled as the **current unedited branch until Send**.

An accepted edit reconstructs the selected pre-target context, dropping the
original target and its reply tail from that branch. A summary is reused only
when its entire transitive dependency set is safely before the target. Otherwise
the original retained prefix is restored. Complete assistant/tool groups are
validated by occurrence, including reused tool-call IDs. Files, Bash/MCP effects,
original journal records, captured bodies and historical spending are preserved.
Editing does not undo or rerun tools. A new model turn can propose new actions.

## Persistence and compatibility

`EditReplayPlan.swift` is the shared pure metadata planner for helper and native
reader. `ConversationReplay` provides read-only portable replay without runtime
construction or recovery writes. The native reader indexes selected identities
independently of the visible page; opening an older input does not hydrate all
transcript rows or restore a hidden-view cache.

New `branch` records retain their ordinary append-only envelope and add:

| Field | Meaning |
| --- | --- |
| `nativeBranchVersion: 2` | Widened historical rollback contract |
| `fromMessageId` | Selected retained user occurrence |
| `keptIds` | Ordered validated replay prefix |
| `selectedTimelinePrefix` | Ordered display branch before the target |
| `sourceTimelineDigest` | SHA-256 of the selected ordered source identities |
| `sourceJournalHead`, `targetDigest` | Captured diagnostic provenance |
| `nativeState` | Accepted replacement and command receipt in the same commit |

The live edit checks the journal head across asynchronous validation and verifies
the preparation's timeline/text digests. Readers recompute the historical plan
and require exact ordered replay/prefix/digest agreement. Physical journal-head
identity is diagnostic on reopen because forks preserve records while stripping
inherited queue authorization; it is not used to guess a missing branch.
Legacy branch records retain their previous ordered-subset validation.
Fork context-selection records carry `visibleIDs` through the latest complete
boundary. Incomplete later physical records remain retained, not activated.

Append and synchronization happen before memory adoption. A definite write
failure restores the prior queue/commands. An uncertain synchronization error
returns `journal_uncertain`, leaves the journal poisoned/preserved and requires
reopen/recovery. A durably accepted but undelivered replacement reopens paused.
Same-epoch mutation deduplication keeps its original command/turn identity.

User messages now have `nativeUserInput` version 1 containing attachment
references and skill identity/hash/intent/argument metadata. Raw images and
expanded skill bodies are not duplicated into that envelope. The read-only
`session.edit.prepare` RPC returns at most 16,384 UTF-16 units per page, full
text length, target/timeline/text identity and first-page input metadata. Native
assembly rejects non-progress, changed identities and oversized input.
The handshake advertises `session.edit.prepare` and `native-branch-v2`.
**Ship this helper and native reader together**; earlier binaries cannot read
the widened branch contract. No migration rewrites user journals.

Scoped `history_read` follows summary source/dependency closure, not the broad
original source list that may also contain subsequently discarded replies.
Reopen, native paging, portable context and a new fork share the same selection.
Current context baselines, observations, retries, partial output, task root and
compaction status reset on adoption; historical counters/captures are not reset.

## Bounds and deliberate limits

- Eight unique selected skills, at most 512 discovered metadata entries, and
  ASCII skill-token names up to 64 characters. Unsupported names remain available
  through the full Skills inspector. Local recognition suppresses URL/path and
  escaped fragments, nonempty selections and unfinished input methods. Backtick
  spans and backtick/tilde fences are classified conservatively off the UI actor.
- The composer retains the existing 256 KiB UTF-8 limit. Local token work is
  bounded before any full-prefix classification; metadata is pre-folded and no
  skill file is read for keystroke search.
- Replay plans accept at most 100,000 metadata identities and cap summary
  dependency/candidate work at 250,000 operations. Exhausted summary optimization
  falls back to a validated raw prefix. Missing required raw sources fail with
  preserved history; the app never fabricates forgotten input.
- Entering edit mode does not call a model. Existing bounded preflight/compaction
  applies to the committed safe candidate; a candidate that cannot fit fails
  visibly rather than borrowing abandoned summaries or future messages.
- No new branch-tree UI, edited-request preview, global fuzzy search, filesystem
  rollback, implicit skill grant or automatic remote retry is introduced.

## Validation

Executed on Apple M3 Max virtual hardware, macOS 14.8, arm64, Xcode 16.1.
The tests use synthetic temporary projects, local HTTP and synthetic credentials;
they do not contact the owner's gateway or modify user projects.

- **277 distinct helper tests pass**: the broad suite's 275 tests, its isolated
  HTTP-429 capture test, and one later nested-child/fork regression. The six
  `HistoricalEditTests` pass after the final fixture addition. All helper
  production changes were present in the broad run.
- **55 distinct native tests pass with actor data-race checks**, covering inline
  skills, historical editing, message details, policy, keyboard submit, side/fork,
  report navigation and refresh lifecycle. The five historical-edit tests were
  rerun with the final native-to-packaged-helper gateway regression.
- **26 optimized native tests pass**, including mounted composer replacement,
  selection changes, stale acceptance, undo/redo and native keyboard/helper lanes.
  With 512 entries, shared search p95 was **1.421 ms**; the bounded local token
  parser at a 256 KiB draft was **0.0011 ms p95**. These measure those operations,
  not end-to-end frame rate or real IME candidate-window latency.
  This optimized run preceded the final acknowledgement-retarget refinement;
  its 17 affected native edit/detail/keyboard checks passed again with actor
  checks afterward. The measured search/parser implementation did not change.
- The helper HTTP fixture performs an original mutating tool call, compacts the
  target out, forks, edits with a current explicitly frozen skill, and validates
  the actual replacement Responses request. It checks ordered call/result pairs,
  exclusion of target/future/unsafe-summary/opaque markers, unchanged parent
  bytes, one old mutation, exact request/response capture bytes, reopen, portable
  replay and another fork. Separate crash, write/sync-failure and lost-ack tests
  verify paused recovery and deduplication.
- Common `historical-edit-before/after.jsonl` fixtures drive native and helper
  readers, full off-window input loading, invalid-version refusal and preserved
  historical assistant counters. A nested runtime test compacts the child, removes
  the original synthetic parent file, edits the child, forks/edits again and reopens.
- The mounted native workflow loads a retained target in a compacted fork,
  selects a skill from its caret-local popup and calls native Send Edit through
  the newly staged helper. The request-aware loopback validates the actual
  replacement; the native archive records one child attempt, the parent bytes
  remain identical and the ordinary unsent draft is restored. Its controlled
  original tool writes only inside the test's temporary project.
  The fixture's declared fixed route actually replays a retained opaque item
  before rollback, then verifies that item and a future tool result disappear
  from the edited request. A second edit checks typing during acknowledgement
  and restoration of the ordinary draft.

One broad run hung in an existing Foundation `Process.waitUntilExit` fixture
teardown after its Python child had exited. It was stopped after a process sample;
the remaining suite and that HTTP-429 case were then run separately and passed.
Several old tests assumed an initial 60-row projection; their expectations now
exercise the existing three-turn page and byte/delta bounds. The keyboard stale-
state fixture now suspends snapshot publication while deliberately assigning stale
state, so cancellation observations cannot race the simulated state. No product
assertions were removed to mask failures.

## Acceptance dispositions

“Passed” identifies executed tests. “Bounded” specifies the implemented contract
and its evidence boundary; it does not imply a manual gesture was observed.

| ID | Disposition and evidence |
| --- | --- |
| S01 | Passed: `InlineSkillTests`, `SkillTests`, native whole-command compatibility. |
| S02 | Passed: mounted caret-local acceptance preserves Unicode prose on both sides. |
| S03 | Passed: later-line/trailing-prose parser and native range replacement. |
| S04 | Passed: mounted selection notification refreshes without a slash keystroke. |
| S05 | Passed: CJK, family emoji, combining marks and UTF-16 range/undo checks. |
| S06 | Bounded: native marked-text Return test and parser suppression pass; a real OS candidate-window/manual IME session was not exercised. |
| S07 | Passed: URL/path/escape, backtick span and backtick/tilde fence regressions; no inline reserved-command execution. |
| S08 | Passed: `SkillTests` preserves explicit origin and stored chip provenance; restored text does not execute. |
| S09 | Passed: shared name-component/substring/description/path ranking. |
| S10 | Passed: `/name` normalization and multi-component path lookup. |
| S11 | Passed: two-page discovery, all 512 results searched, mounted keyboard selection beyond eight. |
| S12 | Passed: stable path/ID tie-breaks and helper duplicate/alias refusal in `ResourceCatalogTests`; explicit canonical selection required. |
| S13 | Passed: disabled search/action separation; helper policy/dependency/hash validation. |
| S14 | Passed: malformed cursor failures retain unavailable prior metadata; partial diagnostics and successful multi-page refresh are distinct. |
| S15 | Passed: held A discovery does not prevent B's independent request/completion. |
| S16 | Bounded: origin workspace/tool-mode scopes and read-only host inspection are explicit; main/side keyboard isolation is covered, not every capability permutation. |
| S17 | Bounded: settings/host/source revision checks reject mixed pages and expose Retry; corrupt/repeated cursor tests pass. No automatic unbounded restart. |
| S18 | Passed: mounted stale draft refuses text/chip mutation; text revision invalidates same-offset code classification. |
| S19 | Bounded: shared acceptance refuses duplicates and ninth skills without mutation; helper and existing selection tests retain the eight-item boundary. |
| S20 | Passed: native one-step text/chip undo and redo. |
| S21 | Passed: native Return/keypad Enter/modifiers/marked text, popup navigation and menu submission policy tests. |
| S22 | Passed: `SkillTests`, `ComposerSubmissionTests`, packaged `/side`/`/fork` in `SideTests`; legacy argument conversion remains separately explicit. |
| S23 | Bounded: inspector filter reconciles selection; body/refresh success and errors check origin, generation, offset and hashes. Manual slow-source inspector presentation was not exercised. |
| S24 | Passed: helper resource freeze/revocation tests and precommit validation; no asynchronous catalog callback submits a changed draft. |
| S25 | Passed for measured operations: 512-entry and 256 KiB optimized samples above; no claimed app-wide FPS or filesystem work per keystroke. |

| ID | Disposition and evidence |
| --- | --- |
| E01 | Passed: ordinary edit/recovery tests and shared prefix planner; selected user identity determines the exact prefix. |
| E02 | Passed: `SideForkTests` and child snapshot tests preserve parent and drop inherited pending authorization. |
| E03 | Passed: actual gateway compact → fork → historical edit; target demonstrably absent from active context. |
| E04 | Passed: child compacts independently and edits an inherited summarized target. |
| E05 | Passed: unsafe summary removed while valid original prefix is restored. |
| E06 | Passed: existing independent earlier-task summary remains without double replay. |
| E07 | Passed/bounded: transitive summary closure and cycle fallback tests; unproven legacy lineage uses raw retained input. |
| E08 | Passed: golden branches reject abandoned targets; a subsequent fork does not reintroduce discarded messages. |
| E09 | Passed: child edit → fork → edit → reopen runtime test, plus gateway edit → reopen/fork parity. |
| E10 | Passed: child edit/replay succeeds after deleting the synthetic parent journal. |
| E11 | Passed: existing running-parent fork test plus validated complete-boundary `visibleIDs`. |
| E12 | Passed: native three-turn/off-window identity-based full input and report-navigation regressions. |
| E13 | Passed/bounded: 40 KiB original display text, skill/missing-attachment references, Unicode/control-heavy helper paging and source digest checks; legacy selections require explicit review. |
| E14 | Passed/bounded: shared native entry/submit blockers, helper idle/queue/ephemeral refusal, and queue/keyboard integration; no stop/discard shortcut. |
| E15 | Passed: native read-only-tool edit preparation and helper read-only fork edits. |
| E16 | Passed: stale target text/timeline and late native draft changes are rejected; precommit journal-head check. |
| E17 | Passed: repeated call IDs are occurrence-local; incomplete groups refuse; old unknown effects are not cleared or rerun. |
| E18 | Passed: actual captured gateway replacement contains safe prefix/current selection and excludes old target, future replies and unsafe state. |
| E19 | Bounded: existing preflight/compaction safety tests pass; the post-commit safe candidate alone can compact/fail. No oversized edited-history network stress run was added. |
| E20 | Passed: invalid/oversized input and injected definite write refusal leave journal/context/queue unchanged. |
| E21 | Passed: journal cut immediately after branch commit reopens one accepted replacement paused with overrides and zero automatic requests. |
| E22 | Passed: same-epoch lost acknowledgement uses one branch/turn identity; existing mutation ledger and native durable-intent recovery remain. |
| E23 | Passed: injected synchronization uncertainty preserves a poisoned journal and paused accepted work on reopen. |
| E24 | Passed: shared golden native paging, runtime reopen, pure portable replay, scoped recall and subsequent fork agree. Unsupported versions do not activate their tail. |
| E25 | Passed/bounded: session/generation-bound native loads preserve newer drafts and avoid focus theft; side lifecycle tests pass. No simultaneous two-pane edited-ack visual run. |
| E26 | Bounded: banner explicitly says current unedited context until Send; committed branch invalidates observations/previews through the existing resolver. No edited-request preview is offered. |
| E27 | Passed/bounded: historical assistant counter remains 21 after rollback; capture/observation/receipt suites pass. No manual audible notification check was required. |
| E28 | Passed: missing raw source and unsupported v2 successor refuse with preserved source bytes and a recoverable explanation. |

## Changed areas and reproduction

Local implementation commits: `11cd670` (three-turn test bounds), `db3468b`
(historical replay/helper durability), and `7cce9ee` (native caret skills,
discovery, retained edits and integration tests). The documentation commit
records this acceptance handoff. Nothing was pushed or released.

Native: `Composer/{NativeComposer,SlashCompletion,SkillCatalog}`, resource
inspector, workspace resource/edit/submission state, retained history reader and
offset index, persisted edit drafts. Helper: shared replay planner/adapters,
versioned branch adoption, input envelopes, fork/reopen/portable/recall readers
and preparation RPC. Tests and synthetic fixtures live beside those modules.

Rebuild the helper with `scripts/build-bundle.py` before testing the Xcode app;
`embed-runtime.py` copies staged helpers and does not rebuild them. Use isolated
scratch build/fixture directories as in [the test handoff](Swift-Test-Handoff.md).
Run `swift test --package-path packages/swift-host`; native suites are named
above. Include an optimized native run and actor-checked Debug run. Reuse
unchanged transport/capture evidence and never substitute normalized events for
the fixture's actual serialized request/observed response comparison.
