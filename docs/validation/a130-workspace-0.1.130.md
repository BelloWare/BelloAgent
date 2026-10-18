# Workspace races — 0.1.130

Workstream: `dev/a130-workspace`, based on `141666ca` (0.1.129 publication).
Worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-a130-workspace`.
Build/evidence root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace`.

## Decisions and boundaries

All four reported findings are confirmed. The fixes preserve the existing capture,
connection, permission, tool and data boundaries. Only Settings' four editable
capture preferences are merged; session overrides and their timestamps remain
owned by the current vault configuration.

Archive retires accepted preparation synchronously, before discovery or its
metadata write. Preparation rechecks the archive revision, the current chat and
any archive write still pending immediately before dispatch. Restore does not
restart an older operation. A failed archive also leaves that undelivered input
for an explicit retry. Existing busy-run Stop workers and their bounded admission
are retained, with a separate revision from prepared submissions. Rejections use
existing draft/intent recovery, so unsent work is not
left as an uncertain command after relaunch.

Fork creation and durable registration still complete after navigation. Only the
selection/focus publication is suppressed. An unchanged destination still opens
the fork, covered by two positive controls.

No owner decision was needed. No view layout, component, styling, wire schema or
helper implementation changed. Gallery regeneration is therefore not applicable;
navigation and retained draft state are asserted directly. The lead owns review,
merge and the full gate. This branch does not release or publish anything.

Fixtures use scratch SQLite stores, `MemoryVaultStorage`, generated conversation
headers and the existing command-sender seam around the workstream's packaged
helper. Loopback suites use generated data. No installed app, real preferences,
real chats, Keychain or paid provider was used. Text logs are the evidence; no
named result bundle was requested.

## Findings and failing-first evidence

Every method below is in `WorkspaceRaceTests`. The unmodified production code
ran first: **18 tests, 16 failed, 2 passed; 45 assertion failures, 0 unexpected**
(`evidence/failing-first.log`). The two passes were unchanged-navigation fork
controls. After the fixes, the same 18 tests passed with zero failures
(`evidence/fixed.log`).

### APP-WORKSPACE-1 — confirmed and fixed

- `testCaptureSettingsPreserveOptOutAndTimestampThroughReloadAndOpen`: load
  Settings with persistent default, edit retention, call `setCaptureMode("off")`,
  save, reload the vault and reopen the session. Before the fix:
  `XCTAssertEqual failed: ("nil") is not equal to ("Optional("off")")`;
  the timestamp was also nil, and reopened `debug.mode` was `persist`, not `off`.
- `testCapturePreferencesMergeIndividuallyAndNeverCopySessionState`: changing
  retention also reverted another writer's default/quota preferences. Conversely,
  editing default/quota overwrote the newer retention and both session maps.
- Fix: enumerate default mode, retention days, quota bytes and unlimited quota
  as separate editable fields. The same merge list serves saves, conflict retries,
  refreshes and unsaved-change state.
- Mutation: restore the original whole-`capture` merge. Both tests fail again
  (7 assertions); the other 16 pass (`evidence/mutation-capture.log`).

### APP-WORKSPACE-2 — confirmed and fixed

- `testDeleteRefusesPendingFirstSendAndKeepsDurableChat`: a generated Encodable
  barrier occupies the metadata actor while the first chat write waits. Before
  the fix: `XCTAssertNotNil failed - Delete must refuse an accepted first send`,
  the display disappeared and the durable chat row was missing after completion.
- `testRemovedChatAbortsMaterializingSubmission`: directly retire the placeholder
  during the same write. Before: one `turn.submit` instead of zero, and a runtime
  was opened for the missing chat.
- `testRemovedPlaceholderMaterializationThrowsAfterCleaningItsRow`: before:
  `A removed placeholder must not report successful materialization`.
- Fix: put the existing loading/work guard before pending deletion shortcuts;
  throw after cleaning a materialized row whose desktop record disappeared.
- Nearby instance: the pending-side shortcut had the same guard ordering.
  `testDeleteRefusesPendingSideFirstSend` holds the parent's session open during
  an accepted side send, invokes Delete, then verifies the side stays visible,
  durably indexed and receives exactly one submission.
- Mutation: restore the old guard order and the successful return after cleanup.
  All four deletion/materialization tests fail (12 assertions), including the
  pending-side reproduction against the restored original shortcut; the other
  15 pass (`evidence/mutation-pending-delete.log`). The final dispatch guard is
  an additional backstop: in this mutation the removed chat still opens a
  runtime, but that guard prevents its `turn.submit`.

### APP-WORKSPACE-3 — confirmed and fixed

- `testArchiveDuringSendOpeningReturnsUnsentDraft`: hold `session.open`, complete
  Archive, then answer the open. Before: `Archived preparation dispatched
  turn.submit`; the composer and saved draft were empty rather than
  `Recoverable input`.
- `testArchiveThenRestoreStillInvalidatesPendingSend`: the same failure after
  restoring before answering the open.
- `testArchiveInvalidatesSendBeforeArchiveCommitReturns`: hold the archive's
  metadata write while answering the open. Before: the message was dispatched
  and its draft emptied.
- `testSendStartedDuringArchiveCommitKeepsItsDraft`: a new send during that
  metadata write also dispatched and emptied `Typed during archive`.
- Nearby edit instance: `testArchiveDuringEditOpeningKeepsReplacementDraft`
  dispatched `turn.edit` and cleared the replacement draft before the fix.
- Nearby Resume instance: `testArchiveDuringResumeOpeningDoesNotContinue`
  dispatched `run.continue` before the fix.
- Nearby compaction instance: `testArchiveDuringCompactionOpeningDoesNotDispatch`
  dispatched `context.compact` before the fix.
- Nearby queued-Resume instance:
  `testArchiveDuringQueueResumeOpeningDoesNotDispatch` dispatched `queue.resume`
  before the fix. Each of these four uses the same held-open fixture.
- Fix: capture the archive revision when accepting work and validate it just
  before dispatch; count pending archive operations until completion. These
  paths share the check and their existing rejection cleanup.
- Mutation: replace the final eligibility condition with the nonempty ID check,
  leaving archive tracking and other fixes intact. All eight archive regressions
  fail (20 assertions), while the other 11 pass (`evidence/mutation-archive.log`).
- Self-review correction: bulk Restore passes all marked IDs, including active
  chats. The first fix reused the Stop revision, which also advances on Restore.
  `testBulkRestoreDoesNotCancelAnActiveChatsPendingSend` reproduced an unrelated
  active send being cancelled (zero submits instead of one, three failed
  assertions in `evidence/bulk-restore-before.log`). The final fix gives Archive
  its own submission revision; Restore continues to affect only queued Stops.
  All 20 regressions pass (`evidence/final-regressions.log`). Reusing the Stop
  counter again makes this test fail with the same three assertions
  (`evidence/mutation-archive-counter.log`).

### APP-WORKSPACE-4 — confirmed and fixed

- `testReplyForkKeepsReportNavigation`: hold `session.fork`, call `openReport`,
  then finish the generated fork. Before: `("chats") is not equal to ("report")`,
  the selected/focused chat became the fork, and its composer focus count was 2
  instead of 0. The fork was durably saved in both cases.
- `testReplyForkDoesNotNavigateAfterLeavingAndReturning`: opening and closing
  Reports still allowed the older fork to take over before the fix.
- Nearby confirmed instance: `testWholeChatForkKeepsReportNavigation` reproduces
  the same behavior for `/fork` (composer focus count 1 instead of 0).
- Fix: both entry points capture and validate `organizationNavigationRevision`
  before selecting the finished fork.
- Controls: `testReplyForkStillOpensWithoutNewNavigation` and
  `testWholeChatForkStillOpensWithoutNewNavigation` pass before and after.
- Mutation: remove both navigation-revision checks while retaining the original
  selected/focused-ID checks. All three stale-navigation tests fail (11 assertions),
  while the other 16 pass (`evidence/mutation-fork-navigation.log`).

## Commands and results

All commands run from the worktree above, with:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace
xcodegen generate --quiet
scripts/test-macos.sh -only-testing:PiAppTests/WorkspaceRaceTests
```

The focused command is used for the initial failing run, fixed run and each
mutation. Mutations restore the affected source in `finally` before the next
run. `evidence/mutate.py` records the exact reversible substitutions;
`evidence/mutations.json` records their exit codes.

The first archive/navigation mutation attempts were rejected by the compiler's
warnings-as-errors setting (unused bindings); no tests ran in those attempts.
The corrected mutations above compile and fail their assertions. The discarded
build attempts remain in `mutation-archive-build-rejected.log` and
`mutation-fork-navigation-build-rejected.log`; they are not counted as evidence
of test sensitivity.

| Suite | Passed | Failed | Evidence |
| --- | ---: | ---: | --- |
| Initial regression baseline | 2 | 16 | `failing-first.log` |
| Initial fixes | 18 | 0 | `fixed.log` |
| Capture mutation | 16 | 2 expected | `mutation-capture.log` |
| Deletion mutation (side regression added) | 15 | 4 expected | `mutation-pending-delete.log` |
| Archive mutation | 11 | 8 expected | `mutation-archive.log` |
| Navigation mutation | 16 | 3 expected | `mutation-fork-navigation.log` |
| Bulk-Restore counter regression before correction | 0 | 1 | `bulk-restore-before.log` |
| Final regression class | 20 | 0 | `final-regressions.log` |
| Bulk-Restore counter mutation | 0 | 1 expected | `mutation-archive-counter.log` |
| Wire | 36 | 0 | `wire.log` |
| Concurrent helper | 4 | 0 | `concurrent.log` |
| Acceptance | 3 | 0 | `acceptance.log` |

```sh
python3 scripts/test-native-host.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
```

The full helper unit suite is not required: `packages/swift-host` is unchanged.

## Final focused validation

All **496 native tests passed**, with zero failures and zero skips. This includes
all 20 new regression/control tests. These runs use the final separate Archive
counter, after restoring every mutation. No unrelated test failure remains.
The earlier focused pass (388 tests) preceded that counter correction; the final
results below supersede it.

Each command below held the shared full-lane lock only for its run, including
focus-changing fixtures. Serial classes ran alone. The lock was released after
each run, including failure paths. Every build used the assigned `native-tests`
DerivedData directory; no extra DerivedData tree was created.

| Focused group | Passed | Failed | Evidence |
| --- | ---: | ---: | --- |
| settings | 64 | 0 | `final-focused-settings.log` |
| workspace | 153 | 0 | `final-focused-workspace.log` |
| editing-forks | 77 | 0 | `final-focused-editing-forks.log` |
| lifecycle | 11 | 0 | `final-focused-lifecycle.log` |
| cost-pause | 3 | 0 | `final-focused-cost-pause.log` |
| conversation | 81 | 0 | `final-focused-conversation.log` |
| deferred-navigation | 33 | 0 | `final-focused-deferred-navigation.log` |
| capture-drain | 6 | 0 | `final-focused-capture-drain.log` |
| subagent-opening | 13 | 0 | `final-focused-subagent-opening.log` |
| subagent-reader | 55 | 0 | `final-focused-subagent-reader.log` |

Exact commands (with `PI_BUILD_ROOT` exported as above):

```sh
# settings
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConnectionSettingsFlowTests \
  -only-testing:PiAppTests/SettingsUnsavedTests \
  -only-testing:PiAppTests/SettingsSaveTests \
  -only-testing:PiAppTests/KeychainSettingsTimeoutTests \
  -only-testing:PiAppTests/RetrySettingsTests \
  -only-testing:PiAppTests/SettingsRefreshRegressionTests

# workspace
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRaceTests \
  -only-testing:PiAppTests/WorkspaceDurabilityTests \
  -only-testing:PiAppTests/WorkspaceTests \
  -only-testing:PiAppTests/WorkspaceFollowupTests \
  -only-testing:PiAppTests/PendingChatProjectTests \
  -only-testing:PiAppTests/SendBookkeepingTests \
  -only-testing:PiAppTests/OrganizationBatchTests \
  -only-testing:PiAppTests/SessionOrganizationTests \
  -only-testing:PiAppTests/ArchiveSwitchTests \
  -only-testing:PiAppTests/WorkspaceFailureTests \
  -only-testing:PiAppTests/SubagentOrganizationTests \
  -only-testing:PiAppTests/SubagentDeletionTests \
  -only-testing:PiAppTests/RecoveredDraftTests

# editing-forks
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ForkFromReplyTests \
  -only-testing:PiAppTests/SideTests \
  -only-testing:PiAppTests/HistoricalEditBookkeepingTests \
  -only-testing:PiAppTests/HistoricalEditingTests \
  -only-testing:PiAppTests/MessageVersionTranscriptTests \
  -only-testing:PiAppTests/RunHoldTests \
  -only-testing:PiAppTests/CostPausePresentationTests \
  -only-testing:PiAppTests/SideBudgetIntegrationTests

# lifecycle
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/LifecycleHelperTests

# cost-pause
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/CostPauseFamilyTests

# conversation
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConversationPaneTests

# deferred-navigation
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/DeferredCreationTests \
  -only-testing:PiAppTests/LaunchSelectionTests \
  -only-testing:PiAppTests/ReportMessageNavigationTests

# capture-drain
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/CaptureDrainTests

# subagent-opening
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentOpeningTests

# subagent-reader
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests
```

Per-class counts:

| Class | Passed | Failed |
| --- | ---: | ---: |
| `ArchiveSwitchTests` | 4 | 0 |
| `CaptureDrainTests` | 6 | 0 |
| `ConnectionSettingsFlowTests` | 6 | 0 |
| `ConversationPaneTests` | 81 | 0 |
| `CostPauseFamilyTests` | 3 | 0 |
| `CostPausePresentationTests` | 6 | 0 |
| `DeferredCreationTests` | 4 | 0 |
| `ForkFromReplyTests` | 5 | 0 |
| `HistoricalEditBookkeepingTests` | 2 | 0 |
| `HistoricalEditingTests` | 5 | 0 |
| `KeychainSettingsTimeoutTests` | 13 | 0 |
| `LaunchSelectionTests` | 20 | 0 |
| `LifecycleHelperTests` | 11 | 0 |
| `MessageVersionTranscriptTests` | 8 | 0 |
| `OrganizationBatchTests` | 9 | 0 |
| `PendingChatProjectTests` | 24 | 0 |
| `RecoveredDraftTests` | 13 | 0 |
| `ReportMessageNavigationTests` | 9 | 0 |
| `RetrySettingsTests` | 5 | 0 |
| `RunHoldTests` | 18 | 0 |
| `SendBookkeepingTests` | 12 | 0 |
| `SessionOrganizationTests` | 9 | 0 |
| `SettingsRefreshRegressionTests` | 1 | 0 |
| `SettingsSaveTests` | 15 | 0 |
| `SettingsUnsavedTests` | 24 | 0 |
| `SideBudgetIntegrationTests` | 18 | 0 |
| `SideTests` | 15 | 0 |
| `SubagentDeletionTests` | 10 | 0 |
| `SubagentOpeningTests` | 13 | 0 |
| `SubagentOrganizationTests` | 13 | 0 |
| `SubagentReaderTests` | 55 | 0 |
| `WorkspaceDurabilityTests` | 7 | 0 |
| `WorkspaceFailureTests` | 6 | 0 |
| `WorkspaceFollowupTests` | 9 | 0 |
| `WorkspaceRaceTests` | 20 | 0 |
| `WorkspaceTests` | 17 | 0 |

Final checks: `git diff --check` passes and `xcodegen generate --quiet` reproduces the committed project byte-for-byte. No test clone folders remained. Automatic result bundles were removed from this workstream's build root; text logs remain in `evidence/`. No unresolved assigned finding or test failure remains. Lead review, merge and the full gate remain outside this workstream.

## Round 2 hunt

Base: `6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1`, after the first branch was
merged and this worktree fast-forwarded. Same branch, worktree and build root as
above. Round 2 text logs are in `build-a130-workspace/evidence/round2/`.
All fixtures use generated keys, images, journals, directories and memory vaults.
The shell test uses only its scratch project. No installed app, real preferences,
real chats, Keychain, live capture or paid provider was used.

### APP-WORKSPACE-5 — confirmed and fixed

`WorkspaceRaceTests.testOpeningReconcilesReplacementCredentialsBeforeSendingAgain`
holds `session.open` with generated key A, saves B plus a generated header, then
releases opening and sends again. Before the fix, both configuration assertions
read nil instead of B, and `Replacement credentials must reach the runtime before
its next turn` fails. `testOpeningRepeatsConfigurationWhenAnotherSaveIntervenes`
also fails: opening sends no replacement configuration at all.

The runtime's acknowledged profile revision is now tracked. Opening and saving
share one configuration operation per session, read credentials through the
existing vault boundary, and repeat when another saved revision intervenes.
An already loaded runtime waits for an outstanding update before reuse. Queued
configuration (`applied: false`) remains the helper's existing next-turn policy;
this does not change an active run's settings. Managed read-only readers do not
gain a new configuration command from opening.

Nearby confirmed instances: `testNewSideReconcilesCredentialsSavedDuringPublication`
and `testNewForkReconcilesCredentialsSavedDuringPublication` both read nil instead
of B before the fix. New sides and forks retain the parent revision they inherit
and reconcile their own runtime before returning to their caller.

### APP-WORKSPACE-6 — confirmed and fixed

`WorkspaceRaceTests.testSiblingNavigationCannotDiscardAPublishingSide` holds the
parent open while the side submits, then calls `openFromSidebar` for a saved
sibling. Before: `Publishing side must remain reachable` fails, the shown side
becomes the sibling, the original side receives zero submits instead of one, and
its durable chat row is absent. `testDirectDiscardCannotRemoveAPublishingSide`
reproduces the same loss through both discard entry points.

Both discard paths now refuse a loading side. `publishPendingSide` rechecks side
and display ownership after the parent open, before changing pending state or
issuing `side.open`. `testSidePublicationRechecksOwnershipAfterParentOpening`
previously created an obsolete helper side and changed the replacement's pending
state to false; its assertions check both effects.

Nearby confirmed image-import instance:
`testPendingSideWithAnImageImportCannotBeDiscarded` previously removed the display
while an import was outstanding. The same discard guards cover this work too.

### APP-UI-2 — confirmed and fixed

`ImportLifecycleTests.testQuitRefusesAnImageStillBeingInspectedThenFlushesIt` uses
a valid generated PNG and a semaphore inside the actual detached inspection path.
The only production change before the baseline was an injectable inspection
closure defaulting to `AttachmentRecord.inspect`; it changes no behavior.
Before the fix, Quit returns `terminateLater` instead of `terminateCancel`, begins
shutdown, loses the attachment (`[]` instead of the image path), and triggers
`Quit approved termination before the import finished`.

Conservative choice, explicitly allowed by this hunt: Quit refuses while an image
is being added and asks the reader to quit again when it finishes. A second check
covers an import started while the stop-and-quit question was open. Successful
Quit still flushes the completed attachment before approving termination. New
file and clipboard imports are refused once the shutdown/update barrier begins.
No new dialog, control, layout or gallery scene was introduced.

Nearby confirmed update instance:
`testUpdateBarrierRefusesAnOutstandingImageImport` previously acquired the barrier
while the import was outstanding. Update admission now requires zero imports.
`testShutdownBarrierBlocksNewFileAndClipboardImports` also failed before: imports
were registered during the barrier and after shutdown, and a file attached during
the barrier. Existing send/import limits and draft destination checks remain.

### APP-UI-3 — confirmed and fixed

`TerminalSessionsTests.testRestartUsesRelocatedProjectFolder` starts a shell in
scratch A, exits it, moves A to B and calls `requestEnding(.restart, …)` with the
same workspace ID and current B path. Before, the replacement's directory still
names A and its shell cannot report B. Restart now receives the current workspace
path while retaining ID, ordinal, custom name and generation validation. The test
also checks the actual shell's `$PWD` and refuses a second stale-generation click.

The baseline's missing-folder shell produced the directory assertion, a working-
directory timeout and the timeout's thrown error (one unexpected failure). The
test now returns after a wrong-directory assertion and reads the shell's `$PWD`
from a generated scratch file, normalizing macOS's temporary-directory symlink; this keeps mutation evidence focused on the wrong
path and still checks `$PWD` on the corrected path.

### Baseline and follow-up evidence

The initial unfixed run (`failing-first.log`, exit 65) executed 32 tests: 20 passed
and all 12 new tests failed (36 assertions/errors, including the terminal timeout
above). By class: WorkspaceRaceTests 20 passed/8 failed; ImportLifecycleTests
0 passed/3 failed; TerminalSessionsTests 0 passed/1 failed.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRaceTests \
  -only-testing:PiAppTests/ImportLifecycleTests \
  -only-testing:PiAppTests/TerminalSessionsTests/testRestartUsesRelocatedProjectFolder
```

The next run (`fixed.log`) passed the original new regression cases except for
a terminal-fixture timeout comparing rendered `$PWD` text. The directory property
was already correct. The shell check now reads a generated scratch file and
compares resolved paths, avoiding terminal wrapping and macOS's `/var` versus
`/private/var` spelling. That corrected test passes in `fixed-all.log` and
`fixed-final.log`; the full terminal class is rerun below.

That run also reproduced two additional same-function side races (five assertions):

- `testPendingSideImportStartedDuringDraftTransferRemainsReachable`: an import
  begun during the parent's saved-draft read lost its display. Discard now checks
  imports again after that await, retaining the side while its earlier text has
  safely reached the parent.
- `testSidePublicationDoesNotTakeFocusBackFromASavedSibling`: after durable side
  registration, switching to T was allowed, but the late S callback overwrote
  T's boundary and focused S. Boundary/focus publication now requires that S is
  still the side shown. S still completes exactly one send and remains saved.

The self-review also caught a failed-opening retry: a helper runtime can exist
before capture setup fails, and another `session.open` returns that runtime
without applying new credentials. `testRetryAfterCaptureSetupFailureReconcilesTheExistingRuntime`
reproduced nil instead of B in `fixed-all.log`. The other 36 tests passed. That
fixture initially put its rejection description in the wrong wire field, adding
one assertion about the description; it now uses the helper's `result.code` and
`result.message`. The missing configuration assertion independently reproduced
the bug. Runtime stamps now include the helper connection and preserve the prior
revision on a same-runtime retry; successful unload clears the stamp and cancels
its old writer. `fixed-final.log` passes all 37 tests with zero skips or failures.

The loaded-runtime guard has a held-configuration test too:
`testLoadedRuntimeWaitsForReplacementConfiguration`. The positive control
`testStopDoesNotWaitForCredentialReconciliation` confirms that Stop still dispatches
while that acknowledgement is held.

### Adversarial review of changed conditions

| Condition | Newly handled state and intended effect |
| --- | --- |
| Saved target is looked up again | A deleted record is skipped; a connection change uses the current record/lease. The workspace of an opened chat cannot change (`pendingProjectBlocker` requires a never-opened pending chat), so the captured workspace host remains the correct boundary. |
| Saved profile revision differs | Seed an unstamped loaded runtime with its previous revision before publishing saved preferences; unrelated profiles and route forks remain unchanged. |
| Cached runtime is independent | Reconcile before reuse; managed read-only readers retain their existing owner-policy boundary. |
| Same helper already has a revision after a failed open | Preserve it and reconcile, instead of trusting new open arguments that the helper ignores. A new helper connection gets its own initial stamp; a confirmed unload retires the old stamp/writer. |
| Same-session configuration exists | Join its acknowledgement instead of issuing an overlapping older writer; remove only the completed token, then recheck the latest revision. |
| Acknowledged stamp is absent/matching/different | Absent, or matching helper connection and revision, requires no update; app creation paths stamp the inherited/opened revision, and saves seed previously unstamped loaded sessions. A different helper connection or revision reads the vault and configures. |
| Revision changes during credential read | Discard the obsolete read and loop; an unrelated vault failure still propagates. No credentials are taken from an unrelated connection. |
| Cancellation, shutdown, host-connection change or invalid lease | Refuse before configuration or before recording its acknowledgement. Reopening cannot treat an obsolete reply as current. |
| `applied == false` | Preserve the existing notice and helper next-turn policy; Stop still uses its direct host path and is covered while configuration is held. |
| Pending side is loading or importing | Both discard entry points refuse; ready empty/drafted sides retain their normal transfer behavior. |
| Side/display ownership changed during parent open | Clean the unpublished intent/draft and refuse before `side.open`; never mutate the replacement. |
| An import starts during draft transfer | Keep its side display after the saved parent write, so its destination survives. |
| Another saved side is shown after registration | Finish and retain the originating side, but do not overwrite the shown side's boundary or focus. |
| Import count is nonzero at Quit or after its confirmation | Refuse shutdown. Retry after completion uses the unchanged final draft flush. |
| Import count is nonzero at update admission | Do not acquire the barrier; existing work/update behavior is otherwise unchanged. |
| Shutdown/update barrier or shutdown has begun | Reject new import registration; file inspection and clipboard conversion do not start with an invalid ticket. Normal imports keep edit-generation/destination and size/count validation. |
| Restart receives a current directory | Use the workspace captured by the restart request. Internal callers without a replacement directory retain the old path. ID/generation checks and Cancel behavior are unchanged. |

No owner decision is pending: retaining active input and refusing Quit until image
inspection finishes follow the conservative options explicitly authorized in the
hunt. No helper implementation or wire schema changed. Existing native Stop,
connection deletion/reassignment, capture policy, trust, tool and vault checks
remain in place. No view geometry or styling changed; gallery regeneration is
not applicable to these state/dispatch fixes.

### Final Round 2 validation

All **552 affected native tests passed**, with **0 failures** and
**0 skips**. This is the final source after every mutation was restored.
The Release-helper checks also passed: **36 wire**, **4 concurrent** and **3
acceptance** tests. `packages/swift-host` is unchanged, so the full helper unit
suite was not required. The lead's merged full gate remains separate.

The model-only regressions and state batch use unmounted fixtures and hidden
PTYs, without app-focus changes. The window mutation and the uninterrupted focus
validation batch hold the shared full-lane lock; every serial class runs in its
own command. The lock is released in `finally`, including failure. The two
interrupted queue waits never acquired it. No other workstream's lock was removed.

| Focused group | Passed | Failed | Skipped | Evidence |
| --- | ---: | ---: | ---: | --- |
| final-state | 247 | 0 | 0 | `final-state.log` |
| final-ui | 123 | 0 | 0 | `final-ui.log` |
| final-window-lifecycle | 4 | 0 | 0 | `final-window-lifecycle.log` |
| final-lifecycle-helper | 11 | 0 | 0 | `final-lifecycle-helper.log` |
| final-subagent-opening | 13 | 0 | 0 | `final-subagent-opening.log` |
| final-subagent-reader | 55 | 0 | 0 | `final-subagent-reader.log` |
| final-conversation | 81 | 0 | 0 | `final-conversation.log` |
| final-terminal-serial | 18 | 0 | 0 | `final-terminal-serial.log` |

Mutation checks (all compile and fail assertions; every mutation is restored):

| Mutation | Passed | Expected failed tests | Evidence |
| --- | ---: | ---: | --- |
| mutation-credentials | 0 | 4 | `mutation-credentials.log` |
| mutation-open-retry | 0 | 1 | `mutation-open-retry.log` |
| mutation-cached-profile | 0 | 1 | `mutation-cached-profile.log` |
| mutation-side | 0 | 6 | `mutation-side.log` |
| mutation-imports | 0 | 3 | `mutation-imports.log` |
| mutation-terminal | 0 | 1 | `mutation-terminal.log` |
| mutation-quit-confirmation | 0 | 1 | `mutation-quit-confirmation.log` |

Per finding: APP-WORKSPACE-5 is detected by the credentials (4 failed), failed-open
retry (1 failed), and cached-runtime (1 failed) mutations. APP-WORKSPACE-6 and its
nearby instances are detected by all 6 side-mutation tests. APP-UI-2 is detected
by the 3 import-mutation tests and the 1 late-confirmation mutation. APP-UI-3 is
detected by the terminal mutation (1 failed). `mutations.json` records the exact
substitutions, test names and exit codes; `mutation-sources.json` retains the
corrected source used to restore each case.

Exact focused commands (using the exported `PI_BUILD_ROOT` above):

```sh
# final-state
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRaceTests \
  -only-testing:PiAppTests/WorkspaceConcurrencyTests \
  -only-testing:PiAppTests/ConfigurationVaultTests \
  -only-testing:PiAppTests/SettingsSaveTests \
  -only-testing:PiAppTests/ConnectionSettingsFlowTests \
  -only-testing:PiAppTests/CatalogSourceTests \
  -only-testing:PiAppTests/CostLimitOpeningTests \
  -only-testing:PiAppTests/CostLimitTests \
  -only-testing:PiAppTests/KeychainSettingsTimeoutTests \
  -only-testing:PiAppTests/SideTests \
  -only-testing:PiAppTests/ForkFromReplyTests \
  -only-testing:PiAppTests/SideBudgetIntegrationTests \
  -only-testing:PiAppTests/ConversationFamilyTests \
  -only-testing:PiAppTests/ImportLifecycleTests \
  -only-testing:PiAppTests/ComposerImportSubmissionTests \
  -only-testing:PiAppTests/ComposerAttachmentDestinationTests \
  -only-testing:PiAppTests/QueuedAttachmentLimitTests \
  -only-testing:PiAppTests/PastedAttachmentTests \
  -only-testing:PiAppTests/PendingChatProjectTests \
  -only-testing:PiAppTests/RecoveredDraftTests \
  -only-testing:PiAppTests/HardeningTests

# final-ui
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceTests \
  -only-testing:PiAppTests/OnboardingTests \
  -only-testing:PiAppTests/ConnectionSwitchJournalTests \
  -only-testing:PiAppTests/SettingsUnsavedTests \
  -only-testing:PiAppTests/SideKeepOrderingTests \
  -only-testing:PiAppTests/SideKeepRecoveryTests \
  -only-testing:PiAppTests/SideRelaunchTests \
  -only-testing:PiAppTests/SidebarSideClickTests \
  -only-testing:PiAppTests/TerminalSessionsTests \
  -only-testing:PiAppTests/TerminalPanelAuditTests

# final-window-lifecycle
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WindowLifecycleTests

# final-lifecycle-helper
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/LifecycleHelperTests

# final-subagent-opening
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentOpeningTests

# final-subagent-reader
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

# final-conversation
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConversationPaneTests

# final-terminal-serial
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TerminalPanelSerialTests

python3 scripts/test-native-host.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
```

Each mutation used the same focused command with these exact selectors:

```sh
# mutation-credentials
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRaceTests/testOpeningReconcilesReplacementCredentialsBeforeSendingAgain \
  -only-testing:PiAppTests/WorkspaceRaceTests/testOpeningRepeatsConfigurationWhenAnotherSaveIntervenes \
  -only-testing:PiAppTests/WorkspaceRaceTests/testNewSideReconcilesCredentialsSavedDuringPublication \
  -only-testing:PiAppTests/WorkspaceRaceTests/testNewForkReconcilesCredentialsSavedDuringPublication

# mutation-open-retry
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRaceTests/testRetryAfterCaptureSetupFailureReconcilesTheExistingRuntime

# mutation-cached-profile
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRaceTests/testLoadedRuntimeWaitsForReplacementConfiguration

# mutation-side
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRaceTests/testSiblingNavigationCannotDiscardAPublishingSide \
  -only-testing:PiAppTests/WorkspaceRaceTests/testDirectDiscardCannotRemoveAPublishingSide \
  -only-testing:PiAppTests/WorkspaceRaceTests/testSidePublicationRechecksOwnershipAfterParentOpening \
  -only-testing:PiAppTests/WorkspaceRaceTests/testPendingSideWithAnImageImportCannotBeDiscarded \
  -only-testing:PiAppTests/WorkspaceRaceTests/testPendingSideImportStartedDuringDraftTransferRemainsReachable \
  -only-testing:PiAppTests/WorkspaceRaceTests/testSidePublicationDoesNotTakeFocusBackFromASavedSibling

# mutation-imports
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ImportLifecycleTests

# mutation-terminal
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TerminalSessionsTests/testRestartUsesRelocatedProjectFolder

# mutation-quit-confirmation
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WindowLifecycleTests/testQuitRechecksImagesStartedWhileTheStopQuestionIsOpen

```

Per-class final counts:

| Class | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `CatalogSourceTests` | 9 | 0 | 0 |
| `ComposerAttachmentDestinationTests` | 2 | 0 | 0 |
| `ComposerImportSubmissionTests` | 11 | 0 | 0 |
| `ConfigurationVaultTests` | 14 | 0 | 0 |
| `ConnectionSettingsFlowTests` | 6 | 0 | 0 |
| `ConnectionSwitchJournalTests` | 6 | 0 | 0 |
| `ConversationFamilyTests` | 22 | 0 | 0 |
| `ConversationPaneTests` | 81 | 0 | 0 |
| `CostLimitOpeningTests` | 1 | 0 | 0 |
| `CostLimitTests` | 13 | 0 | 0 |
| `ForkFromReplyTests` | 5 | 0 | 0 |
| `HardeningTests` | 12 | 0 | 0 |
| `ImportLifecycleTests` | 3 | 0 | 0 |
| `KeychainSettingsTimeoutTests` | 13 | 0 | 0 |
| `LifecycleHelperTests` | 11 | 0 | 0 |
| `OnboardingTests` | 20 | 0 | 0 |
| `PastedAttachmentTests` | 8 | 0 | 0 |
| `PendingChatProjectTests` | 24 | 0 | 0 |
| `QueuedAttachmentLimitTests` | 2 | 0 | 0 |
| `RecoveredDraftTests` | 13 | 0 | 0 |
| `SettingsSaveTests` | 15 | 0 | 0 |
| `SettingsUnsavedTests` | 24 | 0 | 0 |
| `SideBudgetIntegrationTests` | 18 | 0 | 0 |
| `SideKeepOrderingTests` | 12 | 0 | 0 |
| `SideKeepRecoveryTests` | 15 | 0 | 0 |
| `SideRelaunchTests` | 3 | 0 | 0 |
| `SideTests` | 15 | 0 | 0 |
| `SidebarSideClickTests` | 4 | 0 | 0 |
| `SubagentOpeningTests` | 13 | 0 | 0 |
| `SubagentReaderTests` | 55 | 0 | 0 |
| `TerminalPanelAuditTests` | 8 | 0 | 0 |
| `TerminalPanelSerialTests` | 18 | 0 | 0 |
| `TerminalSessionsTests` | 14 | 0 | 0 |
| `WindowLifecycleTests` | 4 | 0 | 0 |
| `WorkspaceConcurrencyTests` | 8 | 0 | 0 |
| `WorkspaceRaceTests` | 33 | 0 | 0 |
| `WorkspaceTests` | 17 | 0 | 0 |

Final checks: every mutation source matches its corrected snapshot; `xcodegen generate --quiet` reproduces the project byte-for-byte; `git diff --check` passes. No clone folders remained. Automatic result bundles were removed from this build root and text logs were retained. No assigned finding, observed nearby instance or test failure remains unresolved. Lead review, merge and the full merged gate remain outside this branch.

## Round 3 review and cross-cutting hunt

Continued from `49271c71` on `dev/a130-workspace`; no merge or fast-forward.
All new evidence is under `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round3`.
The app/helper fixtures use generated data, memory vaults and loopback endpoints. No installed app,
real preferences, chats, credentials, Keychain, live capture or paid provider was used.

### Admitted clipboard imports during update pausing — confirmed and fixed

`pauseRunsForUpdate` now refuses before setting `installPreparing` while an image import
is admitted. This lets the existing clipboard-conversion ticket hand its generated file to
inspection. The existing update failure flow offers a retry; no extra prompt was added.
The ordinary update barrier and Quit already refuse imports, and new imports remain blocked
once a barrier is acquired.

Regression: `ImportLifecycleTests.testPauseForUpdatePreservesAnAdmittedClipboardImport`
holds an admitted conversion across pause preparation, then performs NativeComposer's
file-inspection handoff and checks the saved attachment. `first-boundaries.log` failed:

```text
XCTAssertTrue failed - Pause must refuse before closing admission on an accepted clipboard conversion
XCTAssertEqual failed: ("[]") is not equal to ("[...generated PNG...]")
```

Mutation: remove the import guard; `mutation-boundaries-runtime.log` fails the same test,
including its persisted-attachment assertion. The sweep also rechecked direct-file imports,
shutdown admission and the Quit confirmation recheck through `ImportLifecycleTests` and
`WindowLifecycleTests`.

### WIRE-CONTRACT-4 — confirmed and fixed

The picker and turn-parameter validation now use the helper's existing 200 UTF-8 byte limit.
Both remembered-default creation and application normalize aliases, so legacy oversized
choices cannot become a new chat's accepted default. The helper's validation was already
correct and is unchanged.

Regressions in `ModelSwitchTests` cover 199, 200, 201 and 210 UTF-8 bytes, persisted chat/default
records, and a decoded legacy default. Failing-first evidence is in `first-boundaries.log`
and `first-defaults-and-fixtures.log`: an oversized alias was accepted, saved and copied
into defaults instead of being refused (`XCTAssertNotNil` / `XCTAssertNil` / persisted-model
assertions failed).

Nearby instance, separately confirmed: `WorkspaceEditing.editTurnParams` also counted characters
and admitted control characters. `MessageDetailTests.testEditModelOverrideUsesTheSameUTF8AndPrintableLimit`
failed for a 201-byte alias and a DEL character in `first-sweep.log`. It now uses the same
normalizer. Mutation: restore character counting; all three model regression tests fail
in `mutation-boundaries-runtime.log`.

### PERSISTENCE-COMPAT-1 — confirmed and fixed

Each loaded composer carries the draft and SQLite revision it read. Versioned saves compare
that revision inside `BEGIN IMMEDIATE`, then advance the composer's shared version only after
commit. Concurrent local debounce/submission/flush operations share that version; independent
instances do not. Unchanged drafts, including legacy nil/empty fields and edited drafts,
perform no write. A conflicting edit stays in its composer, the other instance's saved copy
stays on disk, and the existing failure banner/failed quit or update flush reports the conflict.
This conservative policy does not merge different writers' text or silently select a winner.

`DraftConcurrencyTests` uses two independent models/stores sharing one generated database.
It covers both a missing initial draft and an existing empty draft, conflicting debounce and
flush saves, concurrent writers, legacy edited drafts and transaction rollback. Failing-first
`first-drafts.log` showed:

```text
XCTAssertEqual failed: ("Optional("")") is not equal to ("Optional("Saved by A")")
failed - A conflicting draft must not silently replace another instance's text
XCTAssertEqual failed: ("Optional("Still owned by B")") is not equal to ("Optional("Saved by A")")
```

Nearby instances use the same versioned write: pending-chat materialization, edit submission,
submission/recovery transactions, returned-input review markers, side publication/registration,
side closing, and transfers to an unloaded parent's draft. A transfer preserves its side input
when the parent changed. Existing local typing revision guards remain in effect. A transaction
rollback never advances a version. Legacy edited-draft nil/false normalization was caught and
corrected by `first-sweep.log` before final validation.

The adversarial review caught a required ordering detail in the new unchanged check: cancellation
cannot withdraw a draft write already admitted to the store. Both a flush and a newer debounce
now await earlier admitted writes before comparing their shared committed version. They retain
newer task tokens rather than deleting another write's entry. The two held-write regressions
failed first in `first-draft-settlement.log` with `Older queued write` persisted instead of the
composer's undo back to an empty draft. The corrected draft/recovery/bookkeeping/durability batch
passed 39 tests in `fixed-draft-settlement.log`. Removing the waits fails both tests in
`mutation-draft-settlement.log`; the final affected-class run follows restoration.

Mutation evidence: disabling the atomic revision comparison fails the conflict and concurrent-writer
tests (`mutation-draft-cas.log`); disabling the unchanged check fails both unchanged-stale-instance
and legacy-edit tests (`mutation-draft-unchanged.log`). All mutation sources were restored.

The first broader run (`focused-state.log`, 236 tests) found 19 assertions across ten tests whose
fixtures directly seeded/changed a draft while marking its display loaded, without adopting its
revision. The fixtures now use the same version for simulated local writes or load the seeded
revision. Assertions and limits were retained. Recovery, bookkeeping and durability passed in
`first-defaults-and-fixtures.log`; the full affected classes are rerun below.

Nearby issue left outside this draft-content fix: the anchor write at `apps/macos/PiApp/Workspaces/WorkspaceDrafts.swift:164`
still has last-writer-wins semantics. A second instance's loaded reading position can supersede
another instance's newer reading position when it quits. It does not overwrite draft content.

### CONCURRENCY-LIFECYCLE-3 — confirmed and fixed

Ordinary opens, side publication and forks capture the acknowledging helper connection and
check readiness, supervisor identity and connection identity after suspension and before
runtime publication. Fork registration remains durable even if the helper dies; the next
open must issue `session.open`. Capture setup/status and profile reconciliation cannot publish
old runtime state on a replacement connection. The cached-open return also rechecks its helper
after asynchronous credential reconciliation.

`WorkspaceRaceTests` reproduces the ordinary final-reply/loss callback ordering and holds fork
registration after its successful reply. `first-runtime.log` failed both cache-empty assertions
and both required-reopen counts. The fork fixture also reconnects the same supervisor before
releasing registration, and a side fixture delivers loss immediately after its final status reply.
Both fail against the original production paths in `mutation-boundaries-runtime.log`.

Nearby instance, separately confirmed: `withConnectionOpen`'s invalid-profile cleanup used only
`isReady`, so it could stop and close the replacement helper's runtime. `first-sweep.log` showed
`2` cleanup commands where `0` were expected and the replacement cache entry removed. Cleanup
now checks its captured connection before each command and cache removal. Restoring the old
opening/publication/cleanup paths fails all five runtime race tests in the mutation run.

### Lead decision — pending onboarding tests count as active work

A counter spans onboarding probe admission, configuration/credential reads, private helper work
and cleanup, and decrements on success, failure or cancellation. `hasActiveWork` includes it;
Pause and Install waits for it with the existing preparation deadline. Shutdown/update barriers
refuse new probes. Existing work/quit/update questions are reused; no prompt was added.

`WorkspaceConcurrencyTests.testOnboardingProbeCountsAsActiveWhileCredentialsArePending` holds a
memory-vault read. Failing-first `first-boundaries.log` showed active-work false, update-barrier
acquisition true and pause returning while the probe remained admitted. The test cancels and
releases the read before any provider call. A second test checks admission after update/shutdown.
Removing the work accounting/wait and admission guards fails both tests in
`mutation-boundaries-runtime.log` (only the generated loopback endpoint is reachable).

### Adversarial review

- Import admission: only a previously admitted import now refuses Pause and Install; zero imports
  take the original path. The guard runs before any await or barrier mutation, so conversion can
  finish. Already acquired barriers continue blocking new imports.
- Probe accounting: pending credential reads, helper requests and cleanup now count as work; all
  exits decrement. A counter handles overlapping probes. Existing deadlines bound update waiting;
  no helper is silently replayed and no new confirmation appears.
- Model normalization: ASCII aliases retain the same limit; multibyte aliases are measured exactly
  as the helper measures them. Valid boundary aliases remain unchanged. Legacy invalid defaults
  fall back through the existing connection-default behavior rather than being propagated.
- Draft comparisons: unchanged loaded snapshots skip writing even if another instance advanced
  the row. Actual local edits require the exact observed revision, including missing/deleted rows.
  Only successful commits advance the shared version. Older local debounces still lose to newer
  reserved revisions; external conflicts use a distinct error and are not swallowed as old typing.
- Draft write settlement: cancelled work already admitted to the store is awaited before a newer
  comparison. Newer typing owns a different task token and is not removed by an older flush.
  Cancellation still prevents a waiting debounce from admitting a new write.
- Draft transactions: failed submission/recovery/side registration leaves both row and version at
  their prior state. Reviews, attachments, skills, displaced edits and queued edits remain part of
  the persisted draft. Unloaded/subagent displays retain their previous flush exclusions.
- Helper identity: a dead, replaced or detached supervisor now refuses publication/return; a live
  unchanged connection follows the original route. Durable fork/side metadata is retained. Late
  cleanup never sends Stop/Close to a replacement helper or removes its runtime cache entry.

### Final Round 3 validation

Final native coverage: **710 distinct tests passed, 0 failed, 0 skipped** (latest run of each class).
The first UI batch ran 237 tests: 236 passed and one failed with four assertions. Its refresh-review fixture
seeded a loaded draft without its version, as the earlier recovery fixtures did. The simulated local
submission now carries that version; no assertion was weakened. The entire `WorkspaceRefreshLifecycleTests`
class passed **32/32** in `final-refresh-recheck.log`. All other native final batches passed on their first run.

Full helper suite: **1027 passed, 0 failed, 7 skipped** across the normal and isolated streaming-cost lanes.
The seven expected opt-in skips are the shared fork-fixture writer, large-fork measurement, rapid-search
supersession measurement and four retained/long-session memory/open/slim measurements. No helper source changed.
The full suite was nevertheless run for the app-side wire-contract change.

Release-helper Python suites: **wire 36/36, concurrent 4/4, acceptance 3/3**.
Four mutation runs detected **17 failing regression tests**; all mutated sources were restored before final validation.

The shared full-lane lock covered the UI/focus batch, each serial class by itself, gallery capture and
the isolated helper timing tests. The refresh recheck has no windows or focus changes and ran as a focused model class.
All builds used this workstream's existing build root; helper unit-test artifacts use its `swift-verify` subdirectory.

Gallery: `TEST_RUNNER_PI_APP_WORKSPACE_VALIDATION_GALLERY` was set explicitly. All **12** PNGs were opened and inspected:
model validation, draft conflict and import/update messages in light/dark at 760 pt and the 300 pt stress width.
Text and controls fit at the normal width; the stress width retains the existing three-line ellipsis for longer
messages, with Copy and Dismiss visible and unobstructed. No layout or control behavior changed.

Exact final commands (full text also retained in the matching `.command` files):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftConcurrencyTests -only-testing:PiAppTests/ImportLifecycleTests -only-testing:PiAppTests/WorkspaceRaceTests -only-testing:PiAppTests/WorkspaceConcurrencyTests -only-testing:PiAppTests/MetadataDurabilityTests -only-testing:PiAppTests/StorageTruthTests -only-testing:PiAppTests/DraftSizeTests -only-testing:PiAppTests/DraftMarkTests -only-testing:PiAppTests/RecoveredDraftTests -only-testing:PiAppTests/SendBookkeepingTests -only-testing:PiAppTests/HistoricalEditBookkeepingTests -only-testing:PiAppTests/WorkspaceDurabilityTests -only-testing:PiAppTests/HardeningTests -only-testing:PiAppTests/DeferredCreationTests -only-testing:PiAppTests/PendingChatProjectTests -only-testing:PiAppTests/ComposerImportSubmissionTests -only-testing:PiAppTests/SideTests -only-testing:PiAppTests/SideBudgetIntegrationTests -only-testing:PiAppTests/ConversationFamilyTests -only-testing:PiAppTests/ForkFromReplyTests -only-testing:PiAppTests/MessageDetailTests -only-testing:PiAppTests/ConfigurationVaultTests -only-testing:PiAppTests/CostLimitOpeningTests -only-testing:PiAppTests/CostLimitTests -only-testing:PiAppTests/ComposerAttachmentDestinationTests -only-testing:PiAppTests/QueuedAttachmentLimitTests -only-testing:PiAppTests/PastedAttachmentTests -only-testing:PiAppTests/CatalogSourceTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ModelSwitchTests -only-testing:PiAppTests/CatalogModelPickerTests -only-testing:PiAppTests/OnboardingTests -only-testing:PiAppTests/SettingsSaveTests -only-testing:PiAppTests/ConnectionSettingsFlowTests -only-testing:PiAppTests/KeychainSettingsTimeoutTests -only-testing:PiAppTests/WorkspaceTests -only-testing:PiAppTests/WorkspaceLoadingTests -only-testing:PiAppTests/WorkspaceFollowupTests -only-testing:PiAppTests/HistoricalEditingTests -only-testing:PiAppTests/MessageVersionTranscriptTests -only-testing:PiAppTests/SideKeepOrderingTests -only-testing:PiAppTests/SideKeepRecoveryTests -only-testing:PiAppTests/SideRelaunchTests -only-testing:PiAppTests/SidebarSideClickTests -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests -only-testing:PiAppTests/ContextReadingTests -only-testing:PiAppTests/AutomaticContextTests -only-testing:PiAppTests/SkillRefreshTests -only-testing:PiAppTests/UpdatePauseTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QueueEditInteractionTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WindowLifecycleTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/LifecycleHelperTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentOpeningTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentReaderTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationPaneTests
TEST_RUNNER_PI_APP_WORKSPACE_VALIDATION_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round3/gallery PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceValidationGalleryTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests
swift build --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-verify --build-tests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-verify --skip-build --skip StreamingCostTests
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-verify --skip-build --filter StreamingCostTests
python3 scripts/test-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-concurrent-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-native-acceptance.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-host/arm64-apple-macosx/release/pi-native-host
```

Per native class (final pass / fail / skip counts):

| Class | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `AutomaticContextTests` | 11 | 0 | 0 |
| `CatalogModelPickerTests` | 5 | 0 | 0 |
| `CatalogSourceTests` | 9 | 0 | 0 |
| `ComposerAttachmentDestinationTests` | 2 | 0 | 0 |
| `ComposerImportSubmissionTests` | 11 | 0 | 0 |
| `ConfigurationVaultTests` | 14 | 0 | 0 |
| `ConnectionSettingsFlowTests` | 6 | 0 | 0 |
| `ContextReadingTests` | 3 | 0 | 0 |
| `ConversationFamilyTests` | 22 | 0 | 0 |
| `ConversationPaneTests` | 81 | 0 | 0 |
| `CostLimitOpeningTests` | 1 | 0 | 0 |
| `CostLimitTests` | 13 | 0 | 0 |
| `DeferredCreationTests` | 4 | 0 | 0 |
| `DraftConcurrencyTests` | 7 | 0 | 0 |
| `DraftMarkTests` | 5 | 0 | 0 |
| `DraftSizeTests` | 2 | 0 | 0 |
| `ForkFromReplyTests` | 5 | 0 | 0 |
| `HardeningTests` | 12 | 0 | 0 |
| `HistoricalEditBookkeepingTests` | 2 | 0 | 0 |
| `HistoricalEditingTests` | 5 | 0 | 0 |
| `ImportLifecycleTests` | 4 | 0 | 0 |
| `KeychainSettingsTimeoutTests` | 13 | 0 | 0 |
| `LifecycleHelperTests` | 11 | 0 | 0 |
| `MessageDetailTests` | 10 | 0 | 0 |
| `MessageVersionTranscriptTests` | 8 | 0 | 0 |
| `MetadataDurabilityTests` | 10 | 0 | 0 |
| `ModelSwitchTests` | 24 | 0 | 0 |
| `OnboardingTests` | 20 | 0 | 0 |
| `PastedAttachmentTests` | 8 | 0 | 0 |
| `PendingChatProjectTests` | 24 | 0 | 0 |
| `QueueEditInteractionTests` | 17 | 0 | 0 |
| `QueuedAttachmentLimitTests` | 2 | 0 | 0 |
| `RecoveredDraftTests` | 13 | 0 | 0 |
| `SendBookkeepingTests` | 12 | 0 | 0 |
| `SettingsSaveTests` | 15 | 0 | 0 |
| `SideBudgetIntegrationTests` | 18 | 0 | 0 |
| `SideKeepOrderingTests` | 12 | 0 | 0 |
| `SideKeepRecoveryTests` | 15 | 0 | 0 |
| `SideRelaunchTests` | 3 | 0 | 0 |
| `SideTests` | 15 | 0 | 0 |
| `SidebarSideClickTests` | 4 | 0 | 0 |
| `SkillRefreshTests` | 15 | 0 | 0 |
| `StorageTruthTests` | 11 | 0 | 0 |
| `SubagentOpeningTests` | 13 | 0 | 0 |
| `SubagentReaderTests` | 55 | 0 | 0 |
| `UpdatePauseTests` | 7 | 0 | 0 |
| `WindowLifecycleTests` | 4 | 0 | 0 |
| `WorkspaceConcurrencyTests` | 10 | 0 | 0 |
| `WorkspaceDurabilityTests` | 7 | 0 | 0 |
| `WorkspaceFollowupTests` | 9 | 0 | 0 |
| `WorkspaceLoadingTests` | 13 | 0 | 0 |
| `WorkspaceRaceTests` | 38 | 0 | 0 |
| `WorkspaceRefreshLifecycleTests` | 32 | 0 | 0 |
| `WorkspaceTests` | 17 | 0 | 0 |
| `WorkspaceValidationGalleryTests` | 1 | 0 | 0 |

No assigned item or test failure remains unresolved. The cross-instance scroll-anchor issue above remains
outside scope. Permission/capture/tool/vault/data boundaries and the helper wire schema are unchanged.
Lead review, merging and the merged full gate remain the lead's responsibility.


The isolated timing checks measured delta accumulation at 5.54 µs/delta (later 5.88 µs),
with -25,184 bytes of measured heap growth; streamed-page deltas used 0.548 ms CPU/delta
and a 2,386-byte maximum frame. These are unchanged-helper regression measurements,
not a claimed performance improvement from this patch. Full measurements are in `helper-cost.log`.

Final housekeeping: `git diff --check` passed; `xcodegen generate --quiet` reproduced the
project byte-for-byte. No clone folders remained, the automatic native result bundle was
removed, and text logs were retained. Every acquired full-lane lock was released.
