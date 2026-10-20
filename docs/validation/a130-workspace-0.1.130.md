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

Nearby issue left outside this draft-content fix: the anchor write at `apps/macos/PiApp/Workspaces/WorkspaceDrafts.swift:174`
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


## Round 4 — durable conflict copies and reading positions

Scope: the P1 review of Round 3's draft conflict handling, plus the recorded
cross-instance reading-position overwrite. Both findings are **confirmed and fixed**.
All work remains on `dev/a130-workspace`; no merge or dev/next fast-forward.
Evidence is under `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round4/`.
Generated databases, memory vaults, generated PNGs and scripted helper replies only.

### P1 — losing drafts must survive every display release

The review was correct. A rejected `putDraft` left the complete losing draft only
in a display. The original cache eviction had no unsaved/conflict guard. The first
run (`failing-first.log`) executed 16 tests: 9 failed, with 12 failing assertions.
It reproduced the missing durable copy at detection, after eviction and navigation,
and through close, quit/update refusal and transaction rollback. Representative output:

```text
testConflictIsDurableAtDetectionAndAfterDisplayEviction:
XCTAssertTrue failed - The losing draft must already be durable
testConflictCopyWriteFailurePinsTheDisplayDuringNavigation:
XCTAssertTrue failed - Failed conflict preservation must pin its only remaining copy
```

`MetadataStore` now records complete `DraftRecord` conflict copies under
`draft-conflict:<chat id>` before returning a conflict. This includes images,
skills, displaced message-edit drafts, queued edits and submission-review markers.
The failed transaction rolls back first; its conflict copies then commit separately
with SQLite's existing WAL/FULL durability. Thus preserving input cannot accidentally
commit a rejected submission, side registration or recovery operation. Identical
retries reuse a copy; distinct losing edits are retained without automatic pruning.
A failed copy write remains attached to the shared `DraftVersion` and pins its display.

Ordinary eviction also pins a changed draft while its conflict check is still
waiting, covering the interval before the store detects the conflict. Saved conflict
copies load on reopening the chat. The Pi recovery banner offers **Restore Draft**;
that explicit action saves both the latest database draft and the live composer
before restoring the chosen copy in one transaction. It does not submit input.
The existing refusal to flush a still-conflicting composer remains conservative.

### Display-release inventory and tests

Each required path is exercised with a conflicted draft. `DraftConcurrencyTests`
names below omit the common class prefix.

| Release path | Protection and regression |
| --- | --- |
| Eight-display eviction (`WorkspaceSelection.releaseUnreadDisplays`) | `testConflictIsDurableAtDetectionAndAfterDisplayEviction` checks the independent durable copy before and after eviction; `testAChangedDraftStaysPinnedWhileItsConflictCheckIsWaiting` holds the store before comparison; `testConflictCopyWriteFailurePinsTheDisplayDuringNavigation` injects SQLite write failure and asserts the original display remains. |
| Chat switch / sidebar selection (`select` → eviction) | `testChatSwitchPreservesTheConflictCopy` navigates away and back; the failed-copy test also switches after filling the cache. |
| Saved side Close (`closeSide`) | `testSideClosePreservesTheConflictCopy` retains the complete copy through the existing close refusal. |
| Pending side Close/replacement (`discardPendingSideNow`, `discardPendingSide`, `moveSideDraft`) | Failed-copy navigation test covers both sync and async discard. `testPendingSideConflictMustBeSavedBeforeQuitOrUpdate` also retries Close after storage recovers. Outstanding conflict snapshots commit before any side text is consumed or moved. |
| Main-window Close (`WindowActivityGuard`) | `WindowLifecycleTests.testClosingTheLastWindowKeepsAConflictedDraftDurable` closes the last fixture window and checks the independent database copy; window closing retains the workspace model. |
| Quit (`ApplicationLifecycle.beginShutdown`) | `testQuitPreservesTheConflictCopyBeforeAnswering` checks durability before the existing refusal. Failed-copy and pending-side tests assert termination is refused when preservation fails. |
| Update (`prepareForInstall`, side transfer and flush) | `testUpdatePreservesTheConflictCopyBeforeRefusing` checks the saved copy; failed-copy and pending-side tests assert the barrier cannot pass while a conflict snapshot is only in memory. |
| Helper loss (`onLoss` / `discardLostSides`) | `WorkspaceRaceTests.testHelperLossKeepsTheDurableConflictCopy` delivers actual scripted supervisor loss. Failed-copy navigation test checks that an unkept side with an unsaved conflict remains mounted. |
| Empty pending-chat removal (`discardPendingChat`) | Failed-copy navigation test verifies direct discard cannot remove a pinned conflict. `isPendingEmpty` also refuses it. Normal never-written placeholders cannot acquire cross-instance draft revisions; these guards cover a detected conflict regardless of provenance. |
| Explicit Delete Chat / family deletion | Failed-copy navigation test refuses Delete before preservation. `SubagentDeletionTests.testSavedForkAndKeptSideFamiliesDeleteTheirJournalsAndSidecars` verifies a durable conflict exists before authorized deletion and is removed with the other drafts. This preserves the owner's existing Delete semantics. |
| Sub-agent tab close / original-reader close | Both feed the same `releaseUnreadDisplays` guard; managed child displays have no composer/draft. `SubagentReaderTests.testClosingChildrenAppliesTheDisplayBudgetAndKeepsOpenAndRunningReaders` now closes readers over a conflicted ordinary draft and verifies its pin and durable copy. `InheritedSubagentReaderTests` also covers the original-reader route through the same unconditional close implementation. |
| New-chat project replacement / generated-title display cleanup | Project replacement accepts only a never-materialized, never-opened pending chat and copies its current text/images; materialization removes pending status before draft persistence can conflict. Title displays use fresh utility IDs and have no human composer. Neither can hold a cross-instance conflicting draft in the product. Existing pending-project and utility behavior is unchanged. |
| Direct `shutdown` / model destruction | The app reaches shutdown only after its quit/update flush; direct shutdown does not remove displays. Conflict copies already committed are independent of the model/store lifetime; the cold-display recovery test discards all old displays before loading them. |

### Nearby patterns and adversarial corrections

- **Rejected submission input:** preserving only the draft left in the composer
  missed input already captured by `recordSubmission`. The new
  `testRejectedSubmissionPreservesItsInputAsWellAsTheRemainingDraft` failed first
  in `supplement-first.log` (63 tests, one failure):
  `The rejected submission's input must be durable too`. The same rollback path
  now preserves that input and its images/skills as well; no pending command commits.
- **Explicit deletion cleanup:** saved conflict copies must follow an authorized
  Delete. The strengthened deletion fixture first failed twice (fork and side)
  in `release-sweep-first.log`: `Explicit family deletion includes its saved draft copies`.
  Both imported-chat and family cleanup now remove the conflict records and the
  new anchor deletion marker. Failed preservation still refuses release.
- **Pasted-image cleanup:** persisted copies are covered by the existing complete
  metadata-reference scan. Failed copies need a separate pin. The generated PNG
  in `testFailedConflictCopyDefersPastedImageCleanup` was deleted before the fix
  (`image-retention-first.log`, one test/one failure):
  `A conflict awaiting its durable copy still owns its image`.
  Cleanup now defers while any display holds an uncommitted conflict snapshot.
- **Pending-side shutdown ordering:** a failed older conflict snapshot could be
  left behind while newer side text moved to the parent. The new pending-side
  test failed first with nine assertions in `pending-side-conflict-first.log`,
  including `Quit must not drop an uncommitted conflict snapshot` (`[true]` vs
  `[false]`) and `Do not consume the side before its conflict copy is durable`.
  `moveSideDraft` now preserves outstanding conflict copies before consuming input;
  Close retries preservation once storage recovers. Synchronous transfer refuses
  a still-pinned copy.

Additional regressions cover cold recovery of the full edit/review payload, retry
deduplication, retaining distinct later edits, rollback without an intent, and an
old-generation pasted PNG retained solely by its saved conflict copy.

### Reading-position compare-and-swap

Confirmed separately: `testUnchangedStaleQuitDoesNotOverwriteANewerReadingPosition`
failed before the fix with saved anchor `old/3` instead of `new/42`;
`testChangedStaleReadingPositionCannotOverwriteAnotherInstancesSave` also failed.
Both are in `failing-first.log`.

Each display now carries the anchor and revision loaded together by one SELECT.
`putAnchor` compares and writes inside `BEGIN IMMEDIATE`, skips unchanged anchors,
and leaves a newer instance's position untouched on mismatch. Ordinary scroll
writes, quit/update flush and saved-side Close all use this path. Local writes
settle in order before the final flush. Clearing a position retains an
`anchor-deleted` revision, so an old missing-row baseline cannot resurrect it.
The marker is separate from the existing anchor value, preserving its old shape.
It is removed when a new anchor is saved or the chat is explicitly deleted.

Tests additionally cover changed-stale writes, created-then-cleared positions,
stale quit after a clear, local ordering, and saved-side Close. A stale display
keeps its local viewport but cannot publish a position over the newer revision;
a new display load acquires the current baseline.

### Adversarial condition review

- The draft comparison still skips unchanged snapshots. Only a real external
  revision mismatch or an outstanding failed conflict copy enters preservation;
  ordinary successful local saves and old local debounce rejection keep their behavior.
- Conflict persistence runs after rollback and before throwing, with no actor
  suspension between detection, rollback and save. Failed copies stay in the
  version until each save succeeds; successful saves do not advance the losing
  draft's canonical revision.
- Eviction now rejects unsaved input, outstanding conflict snapshots and queued
  draft writes. Clean idle displays still follow the eight-display policy. Running,
  loading, imported-image and open-side/sub-agent pins remain intact.
- Pending side discard and helper loss retain a failed conflict's original display.
  Side transfer awaits preservation before consuming any text. Once storage recovers,
  async Close can save the old copy and continue the normal parent transfer.
- Quit/update retain their existing conflict refusal. They now also refuse an
  ephemeral side whose earlier snapshot cannot be saved; the latest side text is
  not mistaken for preservation of that older snapshot.
- Explicit conflict restoration is the only new way to replace the primary draft.
  It verifies the chosen saved copy, preserves the latest saved and live contents
  atomically, blocks concurrent composer mutations with the existing recovery gate,
  participates in quit's recovery-task wait, and never submits or grants tools.
- Image cleanup changes only when a conflict copy is uncommitted. Saved copies are
  ordinary durable references; current-image protection and deleted-chat cleanup
  retain their existing rules.
- Anchor equality skips writes, including unchanged absence. Changed anchors require
  the exact loaded/committed revision, including a deletion marker. A conflict does
  not silently rebase the stale display and let a later quit overwrite the winner.
  Local versions advance only after commit, and side Close waits for queued writes.
- Deletion refuses unsaved conflict copies but still deletes saved drafts after the
  existing explicit confirmation. No new prompt or helper behavior was introduced.

### Final Round 4 validation

**572 native tests passed, 0 failed, 1 skipped**, across 42 affected classes (latest run per class).

The sole skip was `SessionReadFocusTests.testTheChatBeingReadNeverFlashesUnreadWhenItsRunFinishes`: the locked fixture could not provide its own key, unoccluded window. Its other test passed; every newly added conflict/anchor regression ran and passed. The lead can repeat that focus test on an interactive desktop.

Two mutation runs detected **24 failing regression-test executions**: 13 with conflict-copy persistence removed, and 11 with pin/transfer guards, submission-input preservation, anchor checks and explicit-deletion cleanup broken. Both were xcodebuild test failures (65), not build failures. All mutations were restored before final validation.

Gallery: **16 PNGs generated and inspected**, covering the changed conflict error and recovery banner, plus the retained model/import error scenes, in light/dark at 760 pt and 300 pt. No helper or wire implementation changed, so the helper and wire/concurrent/acceptance suites were not rerun in this round.

The UI/focus batch, each serial class alone, and gallery generation held the shared full-lane lock. Model-only classes used the same workstream build root without that lock. Two initially mixed selections were interrupted before their focus-changing classes ran and rescheduled into the locked batch (`interrupted-mixed-selection.log`, `interrupted-update-selection.log`); their partial results are excluded. The lock waiter was also stopped once while another workstream owned the lock so the final model batch could run; no UI test or owned lock was active at that point.

Exact final commands (also retained as `.command` files beside each text log):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftConcurrencyTests -only-testing:PiAppTests/WorkspaceRaceTests -only-testing:PiAppTests/MetadataDurabilityTests -only-testing:PiAppTests/StorageTruthTests -only-testing:PiAppTests/DraftSizeTests -only-testing:PiAppTests/DraftMarkTests -only-testing:PiAppTests/RecoveredDraftTests -only-testing:PiAppTests/SendBookkeepingTests -only-testing:PiAppTests/HistoricalEditBookkeepingTests -only-testing:PiAppTests/WorkspaceDurabilityTests -only-testing:PiAppTests/HardeningTests -only-testing:PiAppTests/DeferredCreationTests -only-testing:PiAppTests/PendingChatProjectTests -only-testing:PiAppTests/ComposerImportSubmissionTests -only-testing:PiAppTests/PastedAttachmentTests -only-testing:PiAppTests/QueuedAttachmentLimitTests -only-testing:PiAppTests/SideTests -only-testing:PiAppTests/SessionReadStateTests -only-testing:PiAppTests/WorkspaceLoadingTests -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests -only-testing:PiAppTests/SubagentDeletionTests -only-testing:PiAppTests/SubagentOrganizationTests -only-testing:PiAppTests/HistoryExtentTests -only-testing:PiAppTests/ImportLifecycleTests -only-testing:PiAppTests/ComposerAttachmentDestinationTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SideKeepOrderingTests -only-testing:PiAppTests/SideKeepRecoveryTests -only-testing:PiAppTests/SideRelaunchTests -only-testing:PiAppTests/SidebarSideClickTests -only-testing:PiAppTests/LaunchSelectionTests -only-testing:PiAppTests/TranscriptKeptRowsTests -only-testing:PiAppTests/HistoryEdgeTests -only-testing:PiAppTests/UpdatePauseTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WindowLifecycleTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/LifecycleHelperTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentReaderTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InheritedSubagentReaderTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationPaneTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/HistoryEdgeTimingTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/HistoryEditTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionReadFocusTests
TEST_RUNNER_PI_APP_WORKSPACE_VALIDATION_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round4/gallery PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceValidationGalleryTests
```

| Native class | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `ComposerAttachmentDestinationTests` | 2 | 0 | 0 |
| `ComposerImportSubmissionTests` | 11 | 0 | 0 |
| `ConversationPaneTests` | 81 | 0 | 0 |
| `DeferredCreationTests` | 4 | 0 | 0 |
| `DraftConcurrencyTests` | 27 | 0 | 0 |
| `DraftMarkTests` | 5 | 0 | 0 |
| `DraftSizeTests` | 2 | 0 | 0 |
| `HardeningTests` | 12 | 0 | 0 |
| `HistoricalEditBookkeepingTests` | 2 | 0 | 0 |
| `HistoryEdgeTests` | 16 | 0 | 0 |
| `HistoryEdgeTimingTests` | 2 | 0 | 0 |
| `HistoryEditTests` | 3 | 0 | 0 |
| `HistoryExtentTests` | 25 | 0 | 0 |
| `ImportLifecycleTests` | 4 | 0 | 0 |
| `InheritedSubagentReaderTests` | 7 | 0 | 0 |
| `LaunchSelectionTests` | 20 | 0 | 0 |
| `LifecycleHelperTests` | 11 | 0 | 0 |
| `MetadataDurabilityTests` | 10 | 0 | 0 |
| `PastedAttachmentTests` | 8 | 0 | 0 |
| `PendingChatProjectTests` | 24 | 0 | 0 |
| `QueuedAttachmentLimitTests` | 2 | 0 | 0 |
| `RecoveredDraftTests` | 13 | 0 | 0 |
| `SendBookkeepingTests` | 12 | 0 | 0 |
| `SessionReadFocusTests` | 1 | 0 | 1 |
| `SessionReadStateTests` | 16 | 0 | 0 |
| `SideKeepOrderingTests` | 12 | 0 | 0 |
| `SideKeepRecoveryTests` | 15 | 0 | 0 |
| `SideRelaunchTests` | 3 | 0 | 0 |
| `SideTests` | 15 | 0 | 0 |
| `SidebarSideClickTests` | 4 | 0 | 0 |
| `StorageTruthTests` | 11 | 0 | 0 |
| `SubagentDeletionTests` | 10 | 0 | 0 |
| `SubagentOrganizationTests` | 13 | 0 | 0 |
| `SubagentReaderTests` | 55 | 0 | 0 |
| `TranscriptKeptRowsTests` | 10 | 0 | 0 |
| `UpdatePauseTests` | 7 | 0 | 0 |
| `WindowLifecycleTests` | 5 | 0 | 0 |
| `WorkspaceDurabilityTests` | 7 | 0 | 0 |
| `WorkspaceLoadingTests` | 13 | 0 | 0 |
| `WorkspaceRaceTests` | 39 | 0 | 0 |
| `WorkspaceRefreshLifecycleTests` | 32 | 0 | 0 |
| `WorkspaceValidationGalleryTests` | 1 | 0 | 0 |

`xcodegen generate --quiet` reproduced the project unchanged; `git diff --check` passed. No installed app, real preferences/chats/Keychain, paid provider or live capture was used. Automatic result bundles and any test clones under this workstream's build root were removed; text logs and generated gallery images remain. Every acquired lane lock was released. Both assigned findings, including the previously documented reading-position issue, are resolved; no unrelated test failure remains.


## Round 5 — conflict episodes and bounded recovery

Scope: both Round 4 review findings are **confirmed and fixed** on
`dev/a130-workspace`. Evidence: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round5-restart/`.
Only generated SQLite state, memory vaults and existing fixture windows were used.

Restart audit (2026-10-20): the interrupted parent comparison had left all four
production files at Round 4 while the new tests survived. The native build was
cleaned in this workstream's existing build root; failing-first, mutation, final
classes and galleries below were rerun after the restart. Pre-restart logs are
superseded and do not count as validation. Source backups now live on disk before
baseline or mutation checks.

### Paused queues must not block Restore Draft

`testConflictRestorationKeepsAPausedQueueAndAllowsTheNextFlush` failed first:

```text
XCTAssertEqual failed: ("Current unsaved input") is not equal to ("Saved losing input")
A paused queue must not block replacing the composer
caught error: "draftConflict"
```

The previous `hasWork` guard included retained queue items. Restoration now uses
composer eligibility: no send/startup, running work, Resume, active message/queue
edit, edit preparation/submission/cancellation, unresolved queued edit or another
recovery. A paused queue by itself is eligible. The menu uses the same check and
disables unavailable Restore actions. Recovery changes no queued item, sends no
command and preserves the replaced composer before committing the chosen draft.
The regression verifies the queue stays paused and unchanged and the next flush
succeeds. An additional chooser test restores the oldest of 40 copies with a
paused queue; active send/edit cases are refused.

### One episode, one copy; a fixed recovery row

`testConflictEpisodeUpdatesOneCopyUntilTheOtherInstanceChangesAgain` failed first:
20 further edits left **21** copies instead of one; another winner change then
left **22** instead of two. `testConflictRecoveryKeepsTranscriptSpaceAndEveryCopyReachable`
failed with a **2,351 pt** banner and a **0 pt** transcript for 40 copies at both
760 pt and 300 pt. The fresh model run had three failing tests/seven assertions (including the
clear-to-baseline sweep); the two UI tests had thirteen failing assertions
(`failing-model.log`, `failing-ui.log`). The mixed recovery test also failed
because the original banner had no chooser.

**Retention rule (supersedes Round 4’s per-edit snapshots):** each losing display has one conflict episode for the winning
draft revision it observed. Editing, debounce retries and quit/update flushes
replace that episode's complete durable copy under its stable ID. A changed
winning revision starts a new episode and retains the previous episode's latest
copy. A successful canonical save/restoration ends the local episode. Failed copy
updates remain pinned, and the previous durable bytes remain until the replacement
commits. Legacy copies and all distinct episodes are retained without automatic
pruning; every saved copy is reachable through the chooser. Explicit restoration
still preserves the outgoing saved/live contents before replacing them, and
explicit chat deletion retains its existing cleanup semantics.

The recovery banner is one **56 pt** row, independent of width and copy count,
with a **N saved copies** PiKit menu. Its conflict actions list every copy;
interrupted submissions have their existing Insert/Dismiss actions in the same
menu, so old recovery controls cannot be pushed out of the pane. AppKit's existing
menu scrolling and keyboard navigation handle long lists. Complete draft payloads
stay in storage; the menu uses a short preview and numbered actions. A changing
episode invalidates the menu payload even though its record ID stays the same.

Nearby sweep:

- Returning a losing composer to its loaded baseline (including clearing it) must
  update the episode too. `testAnEpisodeTracksTheLatestDraftEvenWhenItReturnsToTheLoadedBaseline`
  failed first with `Losing text` instead of an empty copy (`failing-model.log`).
  An active episode therefore bypasses the ordinary unchanged-draft skip.
- Rejected submission input and the remaining composer now share the episode's
  complete copy rather than creating two records. Their texts are preserved in
  submission-then-composer order, with attachments/skills and edit/review state
  retained; the rejected pending command still rolls back.
- Same-ID payload refresh and mixed interrupted/conflict recovery are covered by
  `testRecoveryChooserRefreshesAnEpisodeAndKeepsInterruptedActionsReachable`.
- `testFailedEpisodeUpdateKeepsItsPinAndRetriesTheSameCopy` injects SQLite failure,
  checks the prior durable copy plus the pin, then retries under the same ID.

### Adversarial self-review

- Queue count no longer refuses restoration. Active runtime/startup/Resume and
  composer edits still refuse it. The new edit guards cover message-edit,
  queue-begin/cancel and edit-submission states the old guard did not name.
  Retained paused follow-ups never become runnable through recovery.
- Conflict IDs change only when the observed winning revision changes; local
  edits update the same ID, including empty input. Failed writes retain the
  latest complete snapshot; they do not advance the canonical revision or clear
  the pin. Different episodes and earlier stored copies are not deleted.
- Copy persistence still runs after the rejected transaction rolls back and before
  it returns its error. Combining rejected input changes only the conflict copy;
  no submission intent or helper request becomes committed by this operation.
- Recovery still validates the chosen ID and complete stored payload inside its
  transaction. A menu opened before a copy changed cannot restore an obsolete
  payload: it fails without replacing the draft or deleting the newer copy.
- The fixed row no longer scales with copy/intent counts. All menu actions remain
  present, including old interrupted submissions; the transcript loses only the
  fixed row's height. Same-ID text changes update the next menu and its action.

The changed conditions were checked state by state:

| Condition | Newly admitted/rejected state | Intended result |
| --- | --- | --- |
| Composer eligibility replaces `hasWork` | Queue-only work is admitted; message edit, queue begin/cancel, edit submission and unresolved queued edit are refused explicitly | Paused queued input stays untouched; active composer ownership is protected. The menu and action use the same predicate. |
| Episode ID selection | Same winning revision reuses the ID; absent episode or a different winning revision allocates an ID | Latest losing input replaces one copy; a new external conflict retains the preceding episode. |
| Unchanged draft skip | A live episode or unsaved conflict bypasses the skip, including an intentional clear | Returning to the loaded baseline cannot leave older losing text as the episode's latest copy. Unchanged non-conflicting instances still perform no write. |
| Failed-copy replacement/removal | Only the current episode's pending payload is replaced; only an exactly persisted snapshot is unpinned | A failed update preserves both the last durable copy and the latest pending input. Other failed episodes remain pinned. |
| Submission combination | Only a rejected draft transaction with an episode receives the captured input | No pending command survives the rollback. The full remaining draft and submitted input stay in one durable copy. |
| Banner state comparison | A payload change under an unchanged ID now invalidates the pane state | The next menu uses the latest text and payload. Stale open-menu actions still fail the existing transactional equality check safely. |
| Banner sizing/menu loops | Copy count no longer increases height; every conflict/intent still contributes an action | The transcript loses only 56 pt. Empty sections have no heading; one/many copy labels and attachment-only previews remain meaningful. |

No helper/wire implementation changed. No additional product decision was needed:
retaining all distinct episodes via the chooser is one of the owner's stated options.

### Final Round 5 validation

All evidence below was regenerated after the laptop restart. Native checks used
this workstream's existing build root, after a successful `xcodebuild clean`;
no additional DerivedData copy was created. Focus-changing classes and every
gallery run held the shared full-lane lock; serial-lane classes ran alone.

Fresh failing-first: **3 model tests failed (7 assertions)** and **2 pane tests
failed (13 assertions)** against the Round 4 production files. Restoring the fixes
passed **32/32 DraftConcurrencyTests** and **2/2 pane regressions** before the UI
mutation. The fresh Round 4 `HistoryEditTests` control also passed **3/3**.

Mutation evidence (all reverted; final results use the restored fixes):

| Mutation | Result | Evidence |
| --- | --- | --- |
| Restore the old `hasWork`/edit guard | 3 expected failing tests: paused restoration, oldest-copy chooser restore and active-edit protection | `mutation-paused-and-edit-guard.log`, exit 65 |
| Allocate a new ID on every conflict and restore the unchanged-baseline skip | 3 expected failing tests: episode reuse, intentional clear and failed-write retry | `mutation-episode.log`, exit 65 |
| Grow the banner per copy, retain only three chooser entries and ignore same-ID payload changes | 2 expected failing pane regressions | `mutation-chooser.log`, exit 65 |

Final native result: **579 passed, 0 failed, 1 skipped across 42 classes** (gallery included).

The sole skip is `SessionReadFocusTests.testTheChatBeingReadNeverFlashesUnreadWhenItsRunFinishes`:
its existing guard requires the test app's own key, unoccluded window, which this
desktop could not provide (`SessionReadStateTests.swift:237`). The other focus
class test passed. No unrelated failure occurred in these fresh runs; all three
`HistoryEditTests` passed against both the Round 4 control and the final fix.

| Class | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `ComposerAttachmentDestinationTests` | 2 | 0 | 0 |
| `ComposerImportSubmissionTests` | 11 | 0 | 0 |
| `ConversationPaneTests` | 83 | 0 | 0 |
| `DeferredCreationTests` | 4 | 0 | 0 |
| `DraftConcurrencyTests` | 32 | 0 | 0 |
| `DraftMarkTests` | 5 | 0 | 0 |
| `DraftSizeTests` | 2 | 0 | 0 |
| `HardeningTests` | 12 | 0 | 0 |
| `HistoricalEditBookkeepingTests` | 2 | 0 | 0 |
| `HistoryEdgeTests` | 16 | 0 | 0 |
| `HistoryEdgeTimingTests` | 2 | 0 | 0 |
| `HistoryEditTests` | 3 | 0 | 0 |
| `HistoryExtentTests` | 25 | 0 | 0 |
| `ImportLifecycleTests` | 4 | 0 | 0 |
| `InheritedSubagentReaderTests` | 7 | 0 | 0 |
| `LaunchSelectionTests` | 20 | 0 | 0 |
| `LifecycleHelperTests` | 11 | 0 | 0 |
| `MetadataDurabilityTests` | 10 | 0 | 0 |
| `PastedAttachmentTests` | 8 | 0 | 0 |
| `PendingChatProjectTests` | 24 | 0 | 0 |
| `QueuedAttachmentLimitTests` | 2 | 0 | 0 |
| `RecoveredDraftTests` | 13 | 0 | 0 |
| `SendBookkeepingTests` | 12 | 0 | 0 |
| `SessionReadFocusTests` | 1 | 0 | 1 |
| `SessionReadStateTests` | 16 | 0 | 0 |
| `SideKeepOrderingTests` | 12 | 0 | 0 |
| `SideKeepRecoveryTests` | 15 | 0 | 0 |
| `SideRelaunchTests` | 3 | 0 | 0 |
| `SideTests` | 15 | 0 | 0 |
| `SidebarSideClickTests` | 4 | 0 | 0 |
| `StorageTruthTests` | 11 | 0 | 0 |
| `SubagentDeletionTests` | 10 | 0 | 0 |
| `SubagentOrganizationTests` | 13 | 0 | 0 |
| `SubagentReaderTests` | 55 | 0 | 0 |
| `TranscriptKeptRowsTests` | 10 | 0 | 0 |
| `UpdatePauseTests` | 7 | 0 | 0 |
| `WindowLifecycleTests` | 5 | 0 | 0 |
| `WorkspaceDurabilityTests` | 7 | 0 | 0 |
| `WorkspaceLoadingTests` | 13 | 0 | 0 |
| `WorkspaceRaceTests` | 39 | 0 | 0 |
| `WorkspaceRefreshLifecycleTests` | 32 | 0 | 0 |
| `WorkspaceValidationGalleryTests` | 1 | 0 | 0 |

Exact final invocations (each `.command` and `.log` is in the evidence folder):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/DraftConcurrencyTests \
  -only-testing:PiAppTests/WorkspaceRaceTests \
  -only-testing:PiAppTests/MetadataDurabilityTests \
  -only-testing:PiAppTests/StorageTruthTests \
  -only-testing:PiAppTests/DraftSizeTests \
  -only-testing:PiAppTests/DraftMarkTests \
  -only-testing:PiAppTests/RecoveredDraftTests \
  -only-testing:PiAppTests/SendBookkeepingTests \
  -only-testing:PiAppTests/HistoricalEditBookkeepingTests \
  -only-testing:PiAppTests/WorkspaceDurabilityTests \
  -only-testing:PiAppTests/HardeningTests \
  -only-testing:PiAppTests/DeferredCreationTests \
  -only-testing:PiAppTests/PendingChatProjectTests \
  -only-testing:PiAppTests/ComposerImportSubmissionTests \
  -only-testing:PiAppTests/PastedAttachmentTests \
  -only-testing:PiAppTests/QueuedAttachmentLimitTests \
  -only-testing:PiAppTests/SideTests \
  -only-testing:PiAppTests/SessionReadStateTests \
  -only-testing:PiAppTests/WorkspaceLoadingTests \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests \
  -only-testing:PiAppTests/SubagentDeletionTests \
  -only-testing:PiAppTests/SubagentOrganizationTests \
  -only-testing:PiAppTests/HistoryExtentTests \
  -only-testing:PiAppTests/ImportLifecycleTests \
  -only-testing:PiAppTests/ComposerAttachmentDestinationTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SideKeepOrderingTests \
  -only-testing:PiAppTests/SideKeepRecoveryTests \
  -only-testing:PiAppTests/SideRelaunchTests \
  -only-testing:PiAppTests/SidebarSideClickTests \
  -only-testing:PiAppTests/LaunchSelectionTests \
  -only-testing:PiAppTests/TranscriptKeptRowsTests \
  -only-testing:PiAppTests/HistoryEdgeTests \
  -only-testing:PiAppTests/UpdatePauseTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WindowLifecycleTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/LifecycleHelperTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/InheritedSubagentReaderTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConversationPaneTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEdgeTimingTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEditTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SessionReadFocusTests
TEST_RUNNER_PI_APP_WORKSPACE_VALIDATION_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round5-restart/gallery PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceValidationGalleryTests
```

The initial clean used `xcodebuild clean -project PiApp.xcodeproj -scheme PiApp
-destination 'platform=macOS,arch=arm64' -derivedDataPath
/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/native-tests
CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO`
(`clean.log`). Exact failing-first, fixed-regression and mutation selectors are
also retained in the matching `.command` files.

Gallery: `WorkspaceValidationGalleryTests` passed with **20 fresh PNGs**. The eight
full-pane recovery scenes cover **1 and 40 copies × light/dark × 760/300 pt**.
All eight were inspected: the row stays 56 pt, its label/chooser fit, and the
transcript and composer remain visible at both widths. The twelve retained
model/draft/import-error scenes were inspected too; their controls remain within
the banners. Menu tests enumerate all 40 actions, restore the oldest copy, and
verify both actions for each of 12 interrupted submissions.

Helper/wire behavior was not changed, so the full helper and wire/concurrent/
acceptance suites were not required for this round. `xcodegen generate --quiet`
and `git diff --check` passed. Automatic result bundles and test clones under this
workstream's build root were removed after the runs; text evidence and PNGs remain.
Every acquired shared lock was released. Both assigned findings are resolved.

## Round 6 — captured submissions and runtime configuration ownership

Work continues on `dev/a130-workspace` from `128156ba`, without merging or
fast-forwarding. Evidence is in
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round6/`.
All state, credentials and helper replies are generated fixtures. No installed
app, real preferences, Keychain, user chats or paid providers were used.

### Rejected submission overwritten by its conflict episode — confirmed and fixed

`WorkspaceRaceTests.testConflictDuringOpeningKeepsCapturedSubmissionAfterEmptyDebounce`
holds the initial `session.open`, accepts a message from a stale composer, then
waits for its empty-composer debounce. An independent store reads the database
before opening/recovery can finish. Before the fix (`failing-first.log`):

```text
XCTAssertEqual failed: ("[]") is not equal to ("[\"Captured input waiting for the helper\"]")
Captured input must have its own durable record before opening finishes
```

The conflict copy was already empty, and there was no pending submission record.
The captured `CommandIntent` now commits in its own existing `pending:<chat>`
record, keyed by command ID, atomically with the losing composer copy after the
failed canonical transaction rolls back. A debounce only replaces the composer
copy. Its text, images, skills, turn/command identity and review tracking remain
in the submission record. Preservation retries do not replace an existing intent
or regress its acknowledgement. Failed preservation keeps both inputs pinned in
the display's `DraftVersion` until the whole recovery transaction commits.

**Retention rule:** Round 5's one-copy-per-winning-revision rule applies to composer
snapshots only. Captured submissions are independent records, never episode
updates. Existing command acceptance/receipt handling settles sent input;
withdrawal removes an unsent record only with a committed restored draft, or an
explicit Dismiss. A conflicting withdrawal leaves the record intact. Existing
recovery menus expose the records after reload; no command is replayed. Conflict
episodes remain unpruned and reachable through the chooser.

`DraftConcurrencyTests` covers repeated empty/nonempty debounces, an independent
store/reloaded display, explicit Insert/Dismiss, transaction rollback and a
trigger-induced failure saving the captured input. The latter verifies atomic
rollback, display pinning above the eviction limit, and retry preserving the
original input. Round 4's release paths remain covered: eviction, chat switching,
side close/transfer, window close, quit, update and helper loss. Each either keeps
the unsaved version pinned or releases only after its input is durable.

Sweep: normal sends and steering share `recordSubmission`; both inherit the fix.
Recovery withdrawal retains its existing transaction, attachment reference scans
already cover pending records, and explicit queued-message edits remain explicit
input edits rather than composer snapshot writes. No additional persistence
instance was found. Removing captured-intent preservation reproduces the missing
record (`mutation-submission.log`).

### Configuration shared across retired runtimes — confirmed and fixed

`WorkspaceRaceTests.testReplacementOpeningDoesNotAwaitRetiredConfiguration`
keeps an old configuration continuation suspended across helper loss, then opens
the replacement before releasing it. The fixture holds the continuation outside
the transport, modeling a credential read that does not settle when transport
requests fail. Before the fix:

```text
XCTAssertTrue failed - Replacement opening must not wait for a retired configuration's credentials
Retired configuration rejected the replacement: failure("The project host changed while opening this chat. Open it again to continue.")
```

A configuration task now carries its helper connection, workspace, chat/profile
lease and runtime generation. Only a matching task is shared. Every resumed
configuration validates ownership before configuring or recording a revision.
Host loss and unload detach/cancel obsolete entries; token-checked completion
cannot remove a new entry. Generations distinguish unload/reopen on the same
helper with the same chat/profile IDs. The existing repeated-save and
configure-before-next-send tests cover legitimate sharing and newer revisions.
`testReconciliationDoesNotShareConfigurationFromAnotherLease` fails when the
sharing comparison is removed (`mutation-sharing.log`).

**Separate sweep instance:** an opening waiting for an obsolete configuration was
still shared through `sessionOpenings`. The new
`testReplacementOpeningDoesNotAwaitRetiredOpeningConfiguration` failed first
with three assertions (`failing-opening-sweep.log`): replacement remained blocked,
inherited the old error, and never became opened. Retirement now also detaches
and cancels that opening. The test passed with the fix and failed again when only
that retirement line was removed (`fixed-opening-sweep.log`,
`mutation-opening.log`). Opening's existing connection checks and token cleanup
continue protecting its late completion.

### Configuration-failure cleanup reaches a replacement — confirmed and fixed

`testRetiredConfigurationFailureCannotCloseReplacementHelper` and
`testRetiredConfigurationFailureCannotCloseReassignedChat` hold a save's
configuration continuation, replace the runtime, then release the old failure.
Before the fix, both sent an extra close and cleared the replacement cache:

```text
XCTAssertEqual failed: ("1") is not equal to ("0") - A retired save must not close a replacement runtime
XCTAssertTrue failed - A retired save must not clear replacement bookkeeping
```

`saveProfile` captures the runtime lease before reconciliation. Its fallback now
checks that lease before `session.close`, after a successful close reply, and
before release bookkeeping on a failed reply. A retired attempt is ignored;
current idle runtimes still use the unsupported-configure fallback. Tests cover
helper restart, chat reassignment, same-helper unload/reopen, successful and
rejected late close replies, and a current idle runtime that must still close and
reopen with the saved key. The late-reply cases are separate nearby instances of
the same ownership pattern and are fenced in the same catch block.

### Mutation evidence

Every mutation was applied alone, tested, and restored from a disk backup. These
are deliberate failing runs, not final-validation failures:

| Run | Broken behavior | Failing tests | Assertion failures |
|---|---|---:|---:|
| `mutation-submission` | Drop captured input when preserving the conflict | 1 | 1 |
| `mutation-sharing` | Share a task from another chat lease | 1 | 2 |
| `mutation-close` | Close before checking the original runtime lease | 3 | 3 |
| `mutation-close-reply` | Clear bookkeeping after a late successful close | 1 | 2 |
| `mutation-close-failure` | Release bookkeeping after a late rejected close | 1 | 1 |
| `mutation-opening` | Leave the obsolete opening available to new callers | 1 | 3 |

The original three findings failed in four tests/seven assertions; the additional
opening sweep failed in one test/three assertions. All source mutations were
restored before final validation.

### Adversarial self-review

Reviewed each changed condition and suspension boundary against the final diff:

- `hasUnsavedConflict` now also pins captured inputs whose independent write
  failed. Durable inputs unpin only after commit; a failed transaction cannot
  clear either pending collection. No release path needs a new exception.
- `preservingSubmission` adds only an unseen command ID. Later composer snapshots
  neither merge into nor replace it. A retry with the same ID retains the first
  captured input. `preserveSubmissions` skips an existing record, preserving
  acknowledgement/recovery state rather than replaying or downgrading it.
- Conflict restoration commits any pinned input records before releasing their
  in-memory copies. The selected composer snapshot's existing revision and
  equality checks still apply; outgoing canonical/live drafts are still kept.
- A configuration lease requires the current ready supervisor connection, the
  current chat/profile lease, and the same runtime generation. Helper loss,
  reassignment, deletion, shutdown, or same-helper unload therefore reject the
  old task. An unchanged runtime retains the previous configure/retry behavior.
- A shared task with a different lease is detached/cancelled instead of awaited.
  Same-lease saves still serialize. The owner is checked before any map mutation
  and after each credential/configuration await; old token cleanup cannot erase
  a replacement entry.
- Save fallback now skips missing/retired records and validates its original
  runtime before close and on both reply paths. Current idle failures still
  close; current busy/queued work keeps the existing refusal to close. No
  suspended code may infer ownership from a reused session ID alone.
- Retirement clears old revision/task/opening entries and advances the generation.
  Host loss includes configured sides not yet in the durable chat list. Idle
  unload and unload events use the same retirement. Late opening completion
  remains guarded by its connection and cancellation checks.
- The chooser's corner style is local to this banner. Recovery eligibility,
  action IDs, menu contents, fixed 56 pt height, and retention rules are unchanged.

### Chooser border and gallery inspection

The lines in Round 5's `conflict-recovery-40-light-760.png` were border artifacts,
not separator views. The recovery chooser now uses PiKit's existing circular
corner option. No shared control implementation or menu behavior changed.

Regenerated **20 PNGs** under `round6/gallery/` while holding the full-lane lock
and inspected every image. All eight recovery scenes (1/40 copies × light/dark ×
760/300 pt) have clean pill edges, a 56 pt recovery row, reachable chooser, and
normal transcript space. The twelve model/draft/import error-banner control
scenes retain their previous layout, including deliberate narrow text truncation
with Copy/Dismiss available.

**Separate visual follow-up, needs owner decision:** the same existing continuous
capsule border artifact is visible on the composer's model/effort pills in the
full-pane images (`apps/macos/PiApp/DesignKit/PiKitButtons.swift:188`, used by
`PiKitChoices.swift:22`). Conservatively kept the geometry change local to the
requested recovery chooser; a shared PiKit shape change needs its own parity and
component-gallery review.

### Final validation

Final native validation: **755 passed, 0 failed, 0 skipped**, across
**54 classes**. Release-helper wire checks: **36 passed**; concurrency:
**4 passed**; acceptance: **3 passed**. No unrelated test failures were observed.
PiAgentCore and the wire schema were unchanged, so the full Swift helper suite
was not required; the Release-helper wire suites were rerun because native
runtime orchestration changed. The lead retains the merged full-gate run.

Focused model/host runs used this workstream's existing build root. All
focus-changing runs, the gallery, and wire/concurrency/acceptance checks acquired
and released the shared full-lane lock. Serial-lane classes ran individually,
including LifecycleHelperTests. Automatic result bundles and any test-app clones
were removed afterward; text logs and gallery PNGs remain the evidence.

| Native class | Passed | Failed | Skipped |
|---|---:|---:|---:|
| `AutomaticContextTests` | 11 | 0 | 0 |
| `BudgetOwnerUnloadTests` | 7 | 0 | 0 |
| `CatalogSourceTests` | 9 | 0 | 0 |
| `ConfigurationVaultTests` | 14 | 0 | 0 |
| `ConnectionSettingsFlowTests` | 6 | 0 | 0 |
| `ConnectionSwitchJournalTests` | 6 | 0 | 0 |
| `ConversationPaneTests` | 83 | 0 | 0 |
| `DeferredCreationTests` | 4 | 0 | 0 |
| `DraftConcurrencyTests` | 34 | 0 | 0 |
| `DraftMarkTests` | 5 | 0 | 0 |
| `DraftSizeTests` | 2 | 0 | 0 |
| `FamilyDeletionTests` | 10 | 0 | 0 |
| `HardeningTests` | 12 | 0 | 0 |
| `HistoricalEditBookkeepingTests` | 2 | 0 | 0 |
| `HistoryEdgeTests` | 16 | 0 | 0 |
| `HistoryEditTests` | 3 | 0 | 0 |
| `HistoryExtentTests` | 25 | 0 | 0 |
| `InheritedSubagentReaderTests` | 7 | 0 | 0 |
| `KeychainSettingsTimeoutTests` | 13 | 0 | 0 |
| `LaunchSelectionTests` | 20 | 0 | 0 |
| `LifecycleHelperTests` | 11 | 0 | 0 |
| `MetadataDurabilityTests` | 10 | 0 | 0 |
| `OnboardingTests` | 20 | 0 | 0 |
| `PastedAttachmentTests` | 8 | 0 | 0 |
| `PendingChatProjectTests` | 24 | 0 | 0 |
| `RecoveredDraftTests` | 13 | 0 | 0 |
| `SendBookkeepingTests` | 12 | 0 | 0 |
| `SendImmediacyTests` | 14 | 0 | 0 |
| `SettingsSaveTests` | 15 | 0 | 0 |
| `SideBudgetInspectorLifetimeTests` | 2 | 0 | 0 |
| `SideBudgetIntegrationTests` | 18 | 0 | 0 |
| `SideKeepOrderingTests` | 12 | 0 | 0 |
| `SideKeepRecoveryTests` | 15 | 0 | 0 |
| `SideRelaunchTests` | 3 | 0 | 0 |
| `SideTests` | 15 | 0 | 0 |
| `SidebarSideClickTests` | 4 | 0 | 0 |
| `StorageTruthTests` | 11 | 0 | 0 |
| `SubagentDeletionTests` | 10 | 0 | 0 |
| `SubagentOpeningTests` | 13 | 0 | 0 |
| `SubagentOrganizationTests` | 13 | 0 | 0 |
| `SubagentReaderTests` | 55 | 0 | 0 |
| `TranscriptKeptRowsTests` | 10 | 0 | 0 |
| `UpdatePauseTests` | 7 | 0 | 0 |
| `WindowLifecycleTests` | 5 | 0 | 0 |
| `WorkspaceConcurrencyTests` | 10 | 0 | 0 |
| `WorkspaceDisplayMemoryTests` | 2 | 0 | 0 |
| `WorkspaceDurabilityTests` | 7 | 0 | 0 |
| `WorkspaceFailureTests` | 6 | 0 | 0 |
| `WorkspaceFollowupTests` | 9 | 0 | 0 |
| `WorkspaceLoadingTests` | 13 | 0 | 0 |
| `WorkspaceRaceTests` | 49 | 0 | 0 |
| `WorkspaceRefreshLifecycleTests` | 32 | 0 | 0 |
| `WorkspaceTests` | 17 | 0 | 0 |
| `WorkspaceValidationGalleryTests` | 1 | 0 | 0 |

Exact final commands (from the evidence `.command` files; each has a matching
text `.log` and exit `.status`):

```sh
# final-ConversationPaneTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationPaneTests
# final-HistoryEditTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/HistoryEditTests
# final-InheritedSubagentReaderTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InheritedSubagentReaderTests
# final-LifecycleHelperTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/LifecycleHelperTests
# final-SideBudgetInspectorLifetimeTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SideBudgetInspectorLifetimeTests
# final-SubagentOpeningTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentOpeningTests
# final-SubagentReaderTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentReaderTests
# final-WindowLifecycleTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WindowLifecycleTests
# final-followup
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceFailureTests -only-testing:PiAppTests/WorkspaceDisplayMemoryTests -only-testing:PiAppTests/SendImmediacyTests -only-testing:PiAppTests/ConnectionSettingsFlowTests -only-testing:PiAppTests/WorkspaceFollowupTests -only-testing:PiAppTests/KeychainSettingsTimeoutTests
# final-host
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRaceTests -only-testing:PiAppTests/WorkspaceConcurrencyTests -only-testing:PiAppTests/WorkspaceTests -only-testing:PiAppTests/WorkspaceLoadingTests -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests -only-testing:PiAppTests/CatalogSourceTests -only-testing:PiAppTests/ConfigurationVaultTests -only-testing:PiAppTests/SettingsSaveTests -only-testing:PiAppTests/OnboardingTests -only-testing:PiAppTests/SideTests -only-testing:PiAppTests/BudgetOwnerUnloadTests -only-testing:PiAppTests/SideBudgetIntegrationTests -only-testing:PiAppTests/FamilyDeletionTests -only-testing:PiAppTests/AutomaticContextTests
# final-model
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftConcurrencyTests -only-testing:PiAppTests/DraftMarkTests -only-testing:PiAppTests/DraftSizeTests -only-testing:PiAppTests/SendBookkeepingTests -only-testing:PiAppTests/RecoveredDraftTests -only-testing:PiAppTests/MetadataDurabilityTests -only-testing:PiAppTests/StorageTruthTests -only-testing:PiAppTests/WorkspaceDurabilityTests -only-testing:PiAppTests/HardeningTests -only-testing:PiAppTests/PastedAttachmentTests -only-testing:PiAppTests/DeferredCreationTests -only-testing:PiAppTests/PendingChatProjectTests -only-testing:PiAppTests/SubagentDeletionTests -only-testing:PiAppTests/SubagentOrganizationTests -only-testing:PiAppTests/HistoryExtentTests -only-testing:PiAppTests/HistoricalEditBookkeepingTests
# final-ui
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SideKeepOrderingTests -only-testing:PiAppTests/SideKeepRecoveryTests -only-testing:PiAppTests/SideRelaunchTests -only-testing:PiAppTests/SidebarSideClickTests -only-testing:PiAppTests/LaunchSelectionTests -only-testing:PiAppTests/UpdatePauseTests -only-testing:PiAppTests/HistoryEdgeTests -only-testing:PiAppTests/TranscriptKeptRowsTests -only-testing:PiAppTests/ConnectionSwitchJournalTests
# gallery
TEST_RUNNER_PI_APP_WORKSPACE_VALIDATION_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round6/gallery PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceValidationGalleryTests
# release-helper-build
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace python3 scripts/build-bundle.py
# wire
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace python3 scripts/test-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-host/arm64-apple-macosx/release/pi-native-host
# concurrent
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace python3 scripts/test-concurrent-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-host/arm64-apple-macosx/release/pi-native-host
# acceptance
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace python3 scripts/test-native-acceptance.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-host/arm64-apple-macosx/release/pi-native-host
```

Exact failing-first and mutation commands:

```sh
# failing-first
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRaceTests/testConflictDuringOpeningKeepsCapturedSubmissionAfterEmptyDebounce -only-testing:PiAppTests/WorkspaceRaceTests/testReplacementOpeningDoesNotAwaitRetiredConfiguration -only-testing:PiAppTests/WorkspaceRaceTests/testRetiredConfigurationFailureCannotCloseReplacementHelper -only-testing:PiAppTests/WorkspaceRaceTests/testRetiredConfigurationFailureCannotCloseReassignedChat
# failing-opening-sweep
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRaceTests/testReplacementOpeningDoesNotAwaitRetiredOpeningConfiguration
# mutation-submission
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRaceTests/testConflictDuringOpeningKeepsCapturedSubmissionAfterEmptyDebounce
# mutation-sharing
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRaceTests/testReconciliationDoesNotShareConfigurationFromAnotherLease
# mutation-close
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRaceTests/testRetiredConfigurationFailureCannotCloseReplacementHelper -only-testing:PiAppTests/WorkspaceRaceTests/testRetiredConfigurationFailureCannotCloseReassignedChat -only-testing:PiAppTests/WorkspaceRaceTests/testRetiredConfigurationFailureCannotCloseReopenedRuntime
# mutation-close-reply
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRaceTests/testConfigurationCloseReplyCannotClearReopenedRuntime
# mutation-close-failure
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRaceTests/testConfigurationCloseFailureCannotReleaseReopenedRuntime
# mutation-opening
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRaceTests/testReplacementOpeningDoesNotAwaitRetiredOpeningConfiguration
```

All requested findings are fixed. The separate shared-capsule visual follow-up
above is recorded for an owner decision; no wider PiKit change is included.

## Round 7 — loaded baselines and capsule outlines

Work remains on `dev/a130-workspace`, based on round 6 (`febcb31b`); no merge,
fast-forward, helper/protocol change, live provider call, installed-app launch,
real preferences or Keychain access. Fixtures use generated journals/databases
and memory vaults. Evidence is under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/`.
The lead's round-7 decision supersedes the shared-capsule “needs owner decision”
follow-up above: the seam is a rendering defect to fix in the shared control.

### Baseline loading: confirmed and fixed

A nil revision is not proof of an absent row until the baseline has been read.
Draft and anchor callbacks now remember changes made before that read, without
starting a versioned write. Initial metadata installs its versions once and
reschedules those callbacks. Explicit clears count as edits; they neither restore
old text/positions nor become eligible for eviction while their baseline is
pending. An already-installed baseline cannot be replaced by another initial
read returning late. Existing loaded-revision conflict checks and durable copies
remain in force for actual competing writers.

The first six regressions ran against unchanged round-6 production code:
`failing-drafts.log`: **6 tests failed, 28 assertions**. Representative output:

```text
XCTAssertTrue failed - Typing while the baseline is pending is not a conflict
XCTAssertEqual failed: ("Optional("")") is not equal to ("Optional("Typed during cold")")
XCTAssertNil failed: "TranscriptAnchor(id: "saved", offset: 17.0, followsBottom: false)" - Returning to latest before loading must remain cleared
```

The reader and additional-writer tests also ran before the fix:
`failing-reader.log`: **1 test failed / 2 assertions**;
`failing-original.log`: **1 failed / 3 assertions**;
`failing-sweep.log`: **2 failed / 3 failures**, including the side-registration
`draftConflict` thrown in ordinary single-instance use. Initial fixed runs passed
all ten regressions and all **79 tests** in the six existing draft/loading classes.

| Path / scenario | Regression | Before the fix |
| --- | --- | --- |
| Cold chat; type while the inherited-history read is held | `DraftLoadingTests.testColdOpenTypingWaitsForBaselineAndReschedules` | False conflict, typed text not saved, cleared position not saved |
| Saved side; type while its initial read is held | `testSavedSideTypingWaitsForBaselineAndReschedules` | Same false conflict and stale position |
| Relaunch's `reopenRememberedSelection`; type while loading | `testRelaunchSelectionTypingWaitsForBaselineAndReschedules` | Same; exercises the actual launch-selection entry point with a generated retained chat |
| Quit/update flush after navigation retires an initial read | `testFlushLoadsBaselineForTypingAfterNavigationRetiresTheRead` | Flush skipped the typed, unread display |
| Close a saved side while its metadata is unread | `testSideCloseLoadsBaselineForTypingBeforeHydration` | Close skipped typing, and the debounce manufactured a conflict |
| Transfer an unsent side into a parent typed in before loading | `testDraftTransferJoinsTypingBeforeParentBaselineLoads` | Parent's live typing omitted the transferred side input |
| Legacy accepted-submission marker while typing before load | `testReceiptProtectionLoadsBaselineBeforeMarkingPendingTyping` | Neither pending typing nor its review marker was saved |
| Side registration while typing before load | `testSideRegistrationLoadsBaselineBeforeSavingPendingTyping` | Threw `draftConflict` against its own saved draft |
| Managed sub-agent reader; clear its position while metadata is held, type in parent | `SubagentReaderTests.testPendingReaderBaselineDefersAnchorAndKeepsParentTyping` | Started a versioned write without a baseline; retained old anchor |
| Original sub-agent reader; clear position while history validation is held, type in fork | `InheritedSubagentReaderTests.testOriginalReaderLoadsAnchorBaselineBeforeSavingPendingPosition` | Never loaded the anchor baseline; retained old anchor |

Sub-agent readers have no editable composer. Their regressions type in the
editable parent/fork while changing the reader's position; no draft is written
for a managed child. Baseline adoption takes conflict metadata only with a
draft-version read; these read-only readers do not gain draft recovery controls.
Original readers now load desktop anchor metadata after validating the original
journal and before presenting its history.

Additional adversarial cases cover typing then clearing before load (the display
remains pinned through eviction and flush), and a late initial read after a
second reader has installed and advanced the baseline. Untouched unread displays
continue to skip flush/close writes; the existing tests protecting their saved
text pass. Fresh pending sides already mark their unique, not-yet-published baseline as
loaded. Pending chat materialization now installs its baseline before advancing
the first draft revision, so a late initial read cannot reset it to nil.

The write-site sweep included all `draftVersion`, `putAnchor`, submission,
withdrawal, review-marker and side-commit call sites. Send/edit entry points
already require `draftReady` after reconciliation. Runtime snapshots can also
expose interrupted-input recovery before selection hydration; Insert now loads
the baseline and rechecks acceptance and composer eligibility after that await.
Dismiss retains its existing path without an unnecessary baseline read. The
sweep fixes cover the independent writers that bypassed initial selection. Transfer without a live parent
already obtains its own version from the store; transfer to an existing unread
parent hydrates it only when it holds pending typing. Untouched unread parents
retain the existing durable transfer path.

### Additional write-site and adversarial checks

`failing-write-sweep.log`: **2 tests failed / 7 assertions** before the final
write-site fixes:

- `testPendingMaterializationInstallsBaselineBeforeItsFirstWrite`: an initial
  nil-revision read returned after materialization had already advanced the
  version; subsequent typing incorrectly produced a conflict copy. Materialize
  now installs the baseline before the first versioned draft write.
- `testReceiptRecoveryLoadsBaselineBeforeMergingPendingTyping`: a runtime
  snapshot exposed a pending intent while the composer's baseline was unread;
  Insert manufactured a conflict instead of recovering the input. Insert now
  obtains that baseline before merging the live composer and captured input.

The new recovery await also requires renewed eligibility. The accepted-command
race is covered by `testAcceptanceDuringRecoveryBaselineLoadStillRetiresTheInsert`.
`failing-recovery-edit.log`: **1 test failed / 3 assertions** in
`testRecoveryCannotReplaceAnEditRestoredByItsBaselineLoad`: loading restored an
existing edit and recovery appended into it and removed its pending record.
Recovery now repeats its existing composer guard after loading, retaining both
the edit and interrupted input. Paused queue counts remain irrelevant.

The first broad model run (`final-model.log`) caught **13 assertions in 2 of 15
SideTests**: eagerly hydrating untouched parents changed their established
save-to-disk transfer path. This was a regression in the initial approach,
not an ignored unrelated failure. Hydration is now limited to parents with
pending typing, including typing admitted while the transfer's store read was
pending. `fixed-write-sweep.log` passed **31/31**; the final corrected model run
passed **270/270 across 20 classes**, including the complete SideTests,
DraftLoadingTests, DeferredCreationTests and WorkspaceRaceTests.

The first full shell-performance run (`final-context-performance.log`) found
two assertions in `testFinishedDraftWritesLeaveNoTasksBehind`: its twelve raw
`SessionDisplay` fixtures had never loaded any metadata, so the corrected
admission guard deferred their writes. The fixture now reads each baseline,
then admits all twelve writes in one actor turn. Its original task-cleanup and
last-typing assertions remain unchanged; no production guard was bypassed.

### Shared capsule outlines: confirmed and fixed

`CapsuleRenderingTests.testCapsuleOutlineHasNoStraightSeamsOutsideItsArc` renders
an empty capsule with a black outline on white. Pixels outside the expected arc
have a 1.5-point raster allowance. Against unchanged round-6 PiKit code,
`failing-capsule.log` found **8 stray pixels at 1x and 16 at 2x** (one failed test,
two assertions). The fixed test passes with zero stray pixels. Reverting the
outline curve reproduces both failures (`mutation-capsule.log`).

```text
XCTAssertEqual failed: ("8") is not equal to ("0") - The capsule has stray outline pixels outside its arc at 1x
XCTAssertEqual failed: ("16") is not equal to ("0") - The capsule has stray outline pixels outside its arc at 2x
```

`ButtonBase` now uses circular arcs for a capsule's **stroke only**. Fill/shade
curves, radii, frames, intrinsic sizes, labels, hit testing, shadows and press
transforms are unchanged. Explicit circular controls stay circular; controls
with a smaller corner radius keep their continuous outline. This fixes the
shared shape, without adding per-user workarounds.

The native component gallery covers model/effort and compact composer pills,
normal/compact choices, family, search-scope menu face, one/many-copy chooser,
project, primary/secondary/danger/ghost buttons, statistics, circle icon,
back-to-bottom and a noncapsule rounded rectangle. The search-scope fixture uses
the existing PiKit menu face; it does not introduce a new search product feature.
Mounted native controls are rasterized at **1x and 2x in light and dark**.
The chooser rows exercise the shared menu face; the actual draft-recovery
banner, with its existing explicit circular fill setting, is also regenerated
in the workspace gallery with one and forty copies, wide and narrow.
All four before images were inspected; straight seams are visible at capsule
ends. Geometry JSON accompanies each appearance for exact frame comparisons.

The first full PiKit parity run (`final-parity.log`) reported two assertions in
`testPillButtons`: the repaired enabled secondary outline differed from the old
SwiftUI continuous outline at 8 light pixels / 32 dark pixels out of 20,520,
with largest channel differences 9 / 10. This is the intended outline change,
not a geometry regression. Only that comparison now uses the suite's existing
small curve-antialiasing allowance (`shapeShare`); disabled buttons and all other
button styles retain their original threshold. The independent analytic-arc
regression still rejects the old seams, and the before/after gallery comparison
checks every non-border pixel without a tolerance.

### Adversarial self-review

- **Unloaded versus absent:** only a completed metadata read (or the existing
  fresh-side known-absence path) authorizes a versioned debounce. Pending typing
  is remembered even when cleared back to empty. Once loaded, callbacks follow
  their original ordered/debounced path.
- **First completion versus late completion:** baseline adoption is monotonic
  for a display. A second initial read cannot roll back an already committed
  version; the late-read mutation produces the expected false conflict.
- **Restoration versus admitted input:** an untouched empty composer can restore
  saved text as before. Pending typing/clears win over automatic restoration.
  A pending nil anchor means an intentional return to latest, not “unread”.
- **Eviction:** pending draft clears and anchor changes pin their displays until
  hydration/flush; loaded idle unchanged displays remain eligible as before.
- **Flush/close:** untouched unread displays still skip writes. Dirty unread
  displays load their baselines and save; read failures keep the existing error
  path instead of approving loss. The original saved-draft protection tests pass.
- **Transfer:** untouched unloaded parents retain the durable disk merge and its
  failure behavior. Parents with pending typing hydrate and absorb into the
  current live draft; transfer failures restore the side input. Existing parked
  edit, attachment, skill, disk-failure and conflict-copy tests pass.
- **Other writers:** review markers, side registration and materialization load
  the baseline before snapshotting/writing. No wire call or permission/capture
  boundary is changed. New-chat identity/deletion guards remain in place.
- **Recovery after awaiting:** Insert rereads its baseline before constructing
  the merged candidate, then checks accepted receipts and active composer edits
  again. A newly accepted input or restored edit prevents replacement; the
  durable input record remains until the existing settling path handles it.
- **Capsules versus other shapes:** only outlines whose radius fills the smaller
  dimension use circular arcs; rectangle controls retain continuous corners,
  explicit circles retain circular corners, and fill/content geometry is untouched.
- **Parity and fixture checks:** only the enabled secondary-button comparison
  takes the existing curve allowance; all other thresholds remain unchanged.
  The debounce cleanup fixture reads real baselines before its twelve writes,
  preserving its simultaneous-admission and latest-write assertions.

### Mutations and final validation

Eleven mutation runs deliberately failed all **20 selected test executions**.
Snapshots on disk were restored in `finally` blocks. The own-build mutex kept
native builds/galleries from observing a partially mutated source tree.

| Mutation log | Broken condition / behavior | Failed tests |
| --- | --- | ---: |
| `mutation-draft-admission` | Permit a debounce before the draft baseline | 1 |
| `mutation-reschedule` | Do not reschedule initial typing/scrolling | 3 |
| `mutation-anchor-admission` | Permit anchor writes before the baseline | 1 |
| `mutation-write-paths` | Remove baseline loads from flush, close, transfer, markers, registration | 5 |
| `mutation-original-reader` | Remove original-reader anchor hydration | 1 |
| `mutation-late-baseline` | Let a late read replace an installed version | 1 |
| `mutation-additional-writers` | Remove the final transfer/materialization/recovery baseline checks | 3 |
| `mutation-pending-pins` | Allow eviction of pending clears/positions | 2 |
| `mutation-recovery-recheck` | Ignore acceptance arriving during baseline loading | 1 |
| `mutation-recovery-edit` | Allow replacement after baseline restores an edit | 1 |
| `mutation-capsule` | Restore continuous capsule outlines | 1 |

Final suite counts, gallery inspection and exact commands follow below.

### Gallery inspection and pixel comparison

Inspected all four after component images alongside their before captures. The
vertical end seams are gone at both scales in both appearances; labels, icons,
fills, spacing and sizes are unchanged. Both geometry JSON files match byte for
byte. Across all four pairs, **zero pixels outside the outline mask changed**,
with an exact RGBA comparison (no channel tolerance). The mask is the 2-point
antialiasing rim around the capsule arc plus the old straight-end seam band.
The circle icon, back-to-bottom circle and noncapsule rectangle are entirely
pixel-identical. `pixel-diff.json` records per-control counts and `pixel-diff.log`
records the comparison output.

| Appearance / scale | Changed border pixels | Changed non-border pixels | Before | After |
| --- | ---: | ---: | --- | --- |
| light-1x | 2149 | 0 | [PNG](/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/before/capsules-light-1x.png) | [PNG](/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/after/capsules-light-1x.png) |
| light-2x | 4810 | 0 | [PNG](/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/before/capsules-light-2x.png) | [PNG](/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/after/capsules-light-2x.png) |
| dark-1x | 2272 | 0 | [PNG](/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/before/capsules-dark-1x.png) | [PNG](/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/after/capsules-dark-1x.png) |
| dark-2x | 4920 | 0 | [PNG](/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/before/capsules-dark-2x.png) | [PNG](/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/after/capsules-dark-2x.png) |

Before captures used the unchanged round-6 `ButtonBase` outline; after captures
use the final outline with the same component fixture. Before-capture command:

```sh
TEST_RUNNER_PI_CAPSULE_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/before PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CapsuleGalleryTests
```

Exact comparison command:

```sh
xcrun swift -module-cache-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-tools-cache /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/compare-gallery.swift /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7 > /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/pixel-diff.log
```

Final focused validation (all text logs above; no named result bundles):

| Run | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `final-model-corrected` | 270 | 0 | 0 |
| `final-materialization` | 75 | 0 | 0 |
| `final-baseline-review` | 62 | 0 | 0 |
| `final-ui` | 187 | 0 | 2 |
| `final-context-performance-corrected` | 14 | 0 | 0 |
| `final-conversation` | 83 | 0 | 0 |
| `final-reader` | 56 | 0 | 0 |
| `final-original` | 8 | 0 | 0 |
| `final-opening` | 13 | 0 | 0 |
| `final-parity-corrected` | 20 | 0 | 1 |
| `final-lifecycle` | 11 | 0 | 0 |
| `final-window` | 5 | 0 | 0 |
| `gallery-after` | 1 | 0 | 0 |
| `final-workspace-gallery` | 1 | 0 | 0 |

The final runs cover **672 distinct tests in 43 classes**: **669 passed, 3 skipped, zero failures**. The materialization follow-up repeats its four affected classes after moving baseline loading ahead of the existing deletion guard; those repeated tests are not double-counted here. The baseline review repeats the three affected draft/loading classes after preserving anchor-only adoption for read-only sub-agent readers.

Class counts (latest final execution for each test):

| Class | Passed | Skipped |
| --- | ---: | ---: |
| `AppShellPerformanceTests` | 11 | 0 |
| `AutomaticContextTests` | 11 | 0 |
| `CapsuleGalleryTests` | 1 | 0 |
| `CapsuleRenderingTests` | 1 | 0 |
| `ContextReadingTests` | 3 | 0 |
| `ConversationFamilyTests` | 22 | 0 |
| `ConversationPaneTests` | 83 | 0 |
| `DeferredCreationTests` | 4 | 0 |
| `DraftConcurrencyTests` | 34 | 0 |
| `DraftLoadingTests` | 15 | 0 |
| `DraftMarkTests` | 5 | 0 |
| `DraftSizeTests` | 2 | 0 |
| `HardeningTests` | 12 | 0 |
| `InheritedSubagentReaderTests` | 8 | 0 |
| `LaunchSelectionTests` | 20 | 0 |
| `LifecycleHelperTests` | 11 | 0 |
| `MetadataDurabilityTests` | 10 | 0 |
| `ModelSwitchTests` | 24 | 0 |
| `PendingChatProjectTests` | 24 | 0 |
| `PiChoicePickerTests` | 7 | 2 |
| `PiKitControlTests` | 39 | 0 |
| `PiKitParityTests` | 20 | 1 |
| `PiMenuTests` | 3 | 0 |
| `RecoveredDraftTests` | 13 | 0 |
| `SendBookkeepingTests` | 12 | 0 |
| `SendImmediacyTests` | 14 | 0 |
| `SessionReadStateTests` | 16 | 0 |
| `SideKeepOrderingTests` | 12 | 0 |
| `SideKeepRecoveryTests` | 15 | 0 |
| `SideRelaunchTests` | 3 | 0 |
| `SideTests` | 15 | 0 |
| `SidebarSideClickTests` | 4 | 0 |
| `StorageTruthTests` | 11 | 0 |
| `SubagentOpeningTests` | 13 | 0 |
| `SubagentReaderTests` | 56 | 0 |
| `WindowLifecycleTests` | 5 | 0 |
| `WorkspaceDisplayMemoryTests` | 2 | 0 |
| `WorkspaceDurabilityTests` | 7 | 0 |
| `WorkspaceFailureTests` | 6 | 0 |
| `WorkspaceLoadingTests` | 13 | 0 |
| `WorkspaceRaceTests` | 49 | 0 |
| `WorkspaceRefreshLifecycleTests` | 32 | 0 |
| `WorkspaceValidationGalleryTests` | 1 | 0 |

The two `PiChoicePickerTests` interactive SwiftUI pointer/keyboard checks require `PI_APP_INTERACTIVE_POINTER_TESTS=1` and an unlocked interactive desktop; they retain their existing opt-in skips. The PiKit parity hover check also retains its Accessibility-permission skip. No permission was requested or changed. All 39 native PiKit control tests ran and passed.

No helper implementation, wire contract or host protocol behavior changed; the helper and wire/concurrent/acceptance suites were therefore not required this round. The native test script built/reused only this workstream’s bundle/build root. Focused headless model tests ran without the focus lock; all window/focus/gallery runs held it, with serial-lane classes run alone. No other workstream’s lock was removed.

Exact final commands:

```sh
# final-model-corrected
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests -only-testing:PiAppTests/DraftConcurrencyTests -only-testing:PiAppTests/WorkspaceLoadingTests -only-testing:PiAppTests/DraftMarkTests -only-testing:PiAppTests/DraftSizeTests -only-testing:PiAppTests/SendBookkeepingTests -only-testing:PiAppTests/RecoveredDraftTests -only-testing:PiAppTests/SideTests -only-testing:PiAppTests/DeferredCreationTests -only-testing:PiAppTests/WorkspaceDisplayMemoryTests -only-testing:PiAppTests/WorkspaceFailureTests -only-testing:PiAppTests/SessionReadStateTests -only-testing:PiAppTests/MetadataDurabilityTests -only-testing:PiAppTests/StorageTruthTests -only-testing:PiAppTests/WorkspaceDurabilityTests -only-testing:PiAppTests/CapsuleRenderingTests -only-testing:PiAppTests/WorkspaceRaceTests -only-testing:PiAppTests/AutomaticContextTests -only-testing:PiAppTests/HardeningTests -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests
# final-materialization
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests -only-testing:PiAppTests/DeferredCreationTests -only-testing:PiAppTests/WorkspaceRaceTests -only-testing:PiAppTests/WorkspaceDurabilityTests
# final-baseline-review
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests -only-testing:PiAppTests/DraftConcurrencyTests -only-testing:PiAppTests/WorkspaceLoadingTests
# final-ui
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SideKeepOrderingTests -only-testing:PiAppTests/SideKeepRecoveryTests -only-testing:PiAppTests/SideRelaunchTests -only-testing:PiAppTests/SidebarSideClickTests -only-testing:PiAppTests/LaunchSelectionTests -only-testing:PiAppTests/ConversationFamilyTests -only-testing:PiAppTests/ModelSwitchTests -only-testing:PiAppTests/PendingChatProjectTests -only-testing:PiAppTests/PiKitControlTests -only-testing:PiAppTests/PiChoicePickerTests -only-testing:PiAppTests/PiMenuTests -only-testing:PiAppTests/SendImmediacyTests
# final-context-performance-corrected
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ContextReadingTests -only-testing:PiAppTests/AppShellPerformanceTests
# final-conversation
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationPaneTests
# final-reader
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentReaderTests
# final-original
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InheritedSubagentReaderTests
# final-opening
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentOpeningTests
# final-parity-corrected
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/PiKitParityTests
# final-lifecycle
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/LifecycleHelperTests
# final-window
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WindowLifecycleTests
# gallery-after
TEST_RUNNER_PI_CAPSULE_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/after PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CapsuleGalleryTests
# final-workspace-gallery
TEST_RUNNER_PI_APP_WORKSPACE_VALIDATION_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/workspace-gallery PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceValidationGalleryTests
```

Exact failing-first and mutation commands:

```sh
# failing-capsule
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CapsuleRenderingTests
# failing-drafts
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests
# failing-original
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InheritedSubagentReaderTests/testOriginalReaderLoadsAnchorBaselineBeforeSavingPendingPosition
# failing-reader
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentReaderTests/testPendingReaderBaselineDefersAnchorAndKeepsParentTyping
# failing-recovery-edit
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests/testRecoveryCannotReplaceAnEditRestoredByItsBaselineLoad
# failing-sweep
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests/testReceiptProtectionLoadsBaselineBeforeMarkingPendingTyping -only-testing:PiAppTests/DraftLoadingTests/testSideRegistrationLoadsBaselineBeforeSavingPendingTyping
# failing-write-sweep
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests/testPendingMaterializationInstallsBaselineBeforeItsFirstWrite -only-testing:PiAppTests/DraftLoadingTests/testReceiptRecoveryLoadsBaselineBeforeMergingPendingTyping
# mutation-additional-writers
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests/testDraftTransferJoinsTypingBeforeParentBaselineLoads -only-testing:PiAppTests/DraftLoadingTests/testPendingMaterializationInstallsBaselineBeforeItsFirstWrite -only-testing:PiAppTests/DraftLoadingTests/testReceiptRecoveryLoadsBaselineBeforeMergingPendingTyping
# mutation-anchor-admission
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentReaderTests/testPendingReaderBaselineDefersAnchorAndKeepsParentTyping
# mutation-capsule
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CapsuleRenderingTests
# mutation-draft-admission
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests/testColdOpenTypingWaitsForBaselineAndReschedules
# mutation-late-baseline
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests/testLateBaselineCannotReplaceTheVersionUsedForNewTyping
# mutation-original-reader
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InheritedSubagentReaderTests/testOriginalReaderLoadsAnchorBaselineBeforeSavingPendingPosition
# mutation-pending-pins
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests/testClearingPendingTypingPinsTheDisplayUntilFlushLoadsItsBaseline -only-testing:PiAppTests/DraftLoadingTests/testPendingPositionPinsAnOtherwiseEmptyDisplayUntilFlush
# mutation-recovery-edit
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests/testRecoveryCannotReplaceAnEditRestoredByItsBaselineLoad
# mutation-recovery-recheck
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests/testAcceptanceDuringRecoveryBaselineLoadStillRetiresTheInsert
# mutation-reschedule
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests/testColdOpenTypingWaitsForBaselineAndReschedules -only-testing:PiAppTests/DraftLoadingTests/testSavedSideTypingWaitsForBaselineAndReschedules -only-testing:PiAppTests/DraftLoadingTests/testRelaunchSelectionTypingWaitsForBaselineAndReschedules
# mutation-write-paths
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftLoadingTests/testFlushLoadsBaselineForTypingAfterNavigationRetiresTheRead -only-testing:PiAppTests/DraftLoadingTests/testSideCloseLoadsBaselineForTypingBeforeHydration -only-testing:PiAppTests/DraftLoadingTests/testDraftTransferJoinsTypingBeforeParentBaselineLoads -only-testing:PiAppTests/DraftLoadingTests/testReceiptProtectionLoadsBaselineBeforeMarkingPendingTyping -only-testing:PiAppTests/DraftLoadingTests/testSideRegistrationLoadsBaselineBeforeSavingPendingTyping
```

The final workspace gallery also passed and all 20 PNGs were inspected in
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round7/workspace-gallery/`.
The eight recovery scenes cover one/forty copies, light/dark, and 300/760-point
widths. The chooser and composer outlines have no end seams; the recovery bar
stays one line and leaves the transcript its normal space. The twelve existing
draft/image/model notice scenes retain their existing narrow truncation and
reachable Copy/Dismiss actions.

Adversarial self-review is complete. All 14 source/project hashes match the
validated state (`tested-source-sha256.json`). Own generated test-result bundles
were removed; no own clone app folders remained. Text logs and gallery PNGs are
retained. No other workstream's build products or lock were touched. There are
no unresolved code findings; the three existing opt-in/permission skips are
listed above. The two requested defects and the confirmed nearby baseline
writers are fixed; no helper or wire behavior was changed.

## Round 8 — ordered draft writers

Both review findings are **confirmed and fixed**. The baseline is `edab6936`.
All fixtures use generated state directories, memory vaults and injected helper
frames. No live provider, real preferences, credentials or user chats are used.
Evidence is under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round8/`.

### Writer contract

`OrderedDraftWriter.swift` documents the rules enforced by `MetadataStore`:

1. Each actual snapshot write claims its chat's writer ticket synchronously, before
   creating a task or awaiting a predecessor. Newer snapshots invalidate and
   cancel older pending snapshots of the same payload, including when the new
   value equals the loaded baseline. A cancelled task cannot evade the store's
   separate ticket check by ignoring cancellation.
2. A conditional side registration first prepares an ordered candidate. A
   receipt replay is read-only and must not cancel pending typing or save its
   captured publication text. When eligibility checks show an actual write is
   needed, beginning that candidate supersedes older pending writes; any newer
   actual capture/commit has already retired the candidate. An older candidate
   beginning leaves newer conditional candidates eligible. All unused candidates
   are released without cancelling other work.
3. The store actor begins a ticket before reserving a revision or touching any
   conflict/recovery state. Superseded, reused or mismatched tickets throw
   `staleRevision`. Revision reservation, the loaded-revision comparison and
   commit have no suspension between them. An operation that has already begun
   finishes before the next operation can begin; its version advances only
   after commit. An older task's cleanup cannot retire a newer ticket.
4. All writes use this boundary, including compound transactions, their rollback
   conflict preservation, raw draft initialization, removals and conflict-copy
   pruning. Internal nested writes reuse the admitted operation. No production
   debounce reserves a draft revision outside its commit anymore.
5. A chat's text and reading position are independent payloads in this writer:
   scrolling cannot cancel typing, or vice versa. They still reserve and commit
   serially on the same store actor. Conflict copies and captured command inputs
   are independent durable records, not replaceable composer snapshots.
6. A superseded composer snapshot accompanying `recordSubmission` is skipped,
   while its captured command still commits. A superseded *restoration* cannot
   consume its recovery record. Explicit discard without a composer replacement
   does not claim a text ticket. Conflict episodes, review gates, attachment
   references and retention rules from earlier rounds remain intact.
7. Supplied legacy/test revisions at or below the version's committed revision
   are rejected **before writer admission**, the unchanged-value shortcut or
   conflict detection. They cannot cancel newer pending typing, create a new
   episode, replace an existing losing copy or pin obsolete input.

### Callers routed through the writer

| Caller | Payload / admission |
| --- | --- |
| `WorkspaceDrafts.draftChanged` (composer changes, edits/queue edits, attachments, returned input, review acknowledgement) | Text ticket captured before the debounce task and predecessor wait. |
| `WorkspaceDrafts.flushDrafts` (quit, update and explicit flush) | Current text and anchor each claim immediately before their store call, after baseline/recovery draining. |
| `WorkspaceDrafts.anchorChanged` (ordinary, side and managed-child readers) | Anchor ticket captured before the asynchronous predecessor wait. |
| `WorkspaceDrafts.protectReturnedDrafts` / `MetadataStore.preserveSubmissionReviews` | Ordered read/modify/write of the durable review marker; latest live typing is rescheduled with the marker. |
| `WorkspaceEditing.sendEdit` | Marked text claims a ticket before its task starts. Finish/cancel/newer editing goes through `draftChanged`. |
| `WorkspaceRun.deliverSubmission` | Connection refusal samples the live composer and claims at save; the captured post-send snapshot claims before `progress.recording` starts. `recordSubmission` independently preserves the command. |
| `WorkspaceRun.recoverFailedSubmission` | Returned snapshot claims before awaiting intent recording; newer typing can supersede that snapshot without consuming the intent. |
| `WorkspaceDrafts.recoverDraft` / `MetadataStore.withdrawSubmission` | Restored text and intent withdrawal are one ordered transaction; explicit discard uses the input-record operation only. |
| `WorkspaceDrafts.restoreConflictedDraft` / `MetadataStore.restoreConflict` | One ordered transaction preserves current copies, restores the chosen copy and removes only that recovery entry. |
| `WorkspaceChatLifecycle.materializeChat` | Baseline-loaded draft claims at save. |
| `WorkspaceSides.publishPendingSide`, `moveSideDraft`, `registerKeptSide`, `closeSide` | Initial side text, parent transfer, close text and anchor claim writes at capture. Kept-side registration prepares its candidate before the actor call, and begins only after eligibility checks. Standalone pinned-conflict preservation enters the ordered conflict operation. |
| `MetadataStore.put`, `putDraft`, `putAnchor`, `preserveDraftConflicts`, `preserveConflict`, `preserveSubmissions`, `acknowledgeCommand` | Generic desktop input writes, CAS, backup copies and command state changes all enter/reuse the writer. Conflict preservation completes synchronously after rollback before the original write returns. |
| `MetadataStore.commitKeptSide`, `commitPortableHandoff` | Actual writes begin after keep eligibility checks and run synchronously through commit. Handoff initialization is ordered too; its new identity has no display yet. |
| `MetadataStore.remove`, `removeAll` / `prune` | Draft/anchor deletion and per-chat conflict pruning enter the same writer, including side-open rollback, chat deletion and family deletion. Unrelated metadata kinds retain their previous path. |

### Findings and failing-first evidence

**Debounce versus direct writes — confirmed/fixed.**
`testDelayedDebounceCannotOverwriteDirectSave` and
`testDelayedDebounceCannotRemoveAnEditSubmissionReview` hold a predecessor while
respectively saving directly and dispatching a real `sendEdit` through an
injected helper. Releasing the older debounce must leave the newer durable
value and the interrupted edit's review marker intact. Before production edits,
`failing-order.log` recorded:

```text
XCTAssertEqual failed: (Optional("Older typing")) is not equal to (Optional("Direct save"))
XCTAssertEqual failed: (nil) is not equal to (Optional(Set([command])))
- An interrupted edit must reopen behind its review gate
```

**Superseded revision becomes conflict input — confirmed/fixed.**
`testSupersededRevisionCannotStartOrReplaceAConflictEpisode` reserves an older
revision, commits newer local input, then commits through a second independent
store. It checks both no existing episode and an existing latest losing copy.
Before the fix:

```text
XCTAssertEqual failed: Optional(StoreError.draftConflict) != Optional(StoreError.staleRevision)
Superseded input must not create or replace a recovery copy
actual: "Obsolete snapshot"; expected: no copy / "Latest losing input"
```

The initial native run executed **3 tests, all 3 failed (7 assertions)**.
A preliminary compile caught a missing `try` in the new helper fixture; that
was corrected before the recorded failing-first test execution.

### Nearby sweep and race coverage

`DraftOrderingTests` adds the two review reproductions plus coverage of:

- An obsolete ticket whose caller ignores cancellation, after another instance
  commits; neither conflict memory nor the durable conflict table changes.
- An obsolete or reused supplied revision arriving while newer typing is still
  pending; the latest ticket remains valid.
- Delayed anchors versus direct position saves and explicit clears, and both
  directions of independent anchor/text writes.
- Eight direct writers racing a held debounce: ordinary save, review marker,
  submission, withdrawal, chosen-conflict restoration, kept-side registration,
  portable handoff and deletion. Even an unchanged direct snapshot cancels its
  predecessor.
- Superseded post-send snapshots retaining independent captured input;
  superseded recovery operations retaining both the input and conflict copy.
- Cancellation binding after supersession and cleanup of an older ticket while
  a newer ticket remains pending.
- A write already inside its synchronous commit while newer input arrives;
  the newer revision and unchanged-value decision follow the older commit.

The existing `DraftConcurrencyTests` predecessor fixture now captures a ticket
before its artificial suspension instead of introducing an unlabelled direct
write after the newer snapshot. It still checks undo back to the initial empty
baseline. The separate begun-commit test covers the genuinely in-flight case.
The first integration run exposed that obsolete fixture assumption and a nil-
replacement withdrawal using a text ticket; both were corrected. The final
core run passed **76/76**, including all 34 concurrency tests and all 13 existing
recovered-input tests. Final wider validation and mutations are listed below.

The adversarial sweep reproduced a duplicate-registration corner in the new
integration: admitting the candidate too early cancelled a debounce even when
`commitKeptSide` found an existing receipt and performed no write.
`failing-registration.log` captured `Optional("") != Optional("Typing while
registration finishes")`. The first attempted correction saved the versioned
candidate; 13 ordering tests passed, but the wider window run correctly rejected
that approach. `SideKeepOrderingTests.testCapturedRegistrationSucceedsWhenAnotherRegistrationCommitsFirst`
failed for both sides and forks at line 241:

```text
actual: Optional("Question being published")
expected: Optional("Newer typing")
```

That run (`final-windows-before-conditional.log`) executed 182 tests: 180 passed,
1 skipped, 1 failed (two assertions). This was a regression from the attempted
correction, not an unrelated failure. The final implementation preserves the
existing read-only receipt replay: it **prepares** the conditional candidate,
then begins the writer only when a pending keep will actually be committed.
`testCompletedRegistrationLeavesPendingTypingWithItsWriter` covers the no-op
side; `testPreparedRegistrationSupersedesAnOlderDebounceWhenItWrites` covers a
real registration. The other new tests cover newer typing superseding a
prepared registration, and two conditional candidates beginning in either
order. The final targeted check (`fixed-conditional-order.log`) passed all
**16 ordering tests plus the existing side/fork race**, 17/17. The full affected
classes and final mutation cycle are rerun below.

### Adversarial self-review

Reviewed each new/changed branch against the states that now take it:

| Condition | Newly affected states and intended outcome |
| --- | --- |
| Capture replaces the pending ticket for the same payload | Older delayed text is cancelled by saves/markers/recovery, and older anchors by newer positions/clears. Different chats and text versus anchor remain independent. The eight-writer matrix and anchor tests cover this. |
| Bind cancellation after a newer capture; finish only if identity matches | A task bound late is still cancelled; an older task finishing cannot remove the current ticket. A ticket already begun is no longer pending and finishes its synchronous commit. |
| Begin requires the exact current ticket/key; nested synchronous calls reuse the active operation | Superseded/replayed/mismatched writes stop before revision reservation or conflict state. Compound calls cannot cancel their own nested writes. No asynchronous operation occurs inside this boundary. |
| Supplied revision is at or below the committed local revision | Obsolete or reused reservations fail before cancelling current typing or checking the other instance. Both new and existing conflict episodes remain untouched. Fresh reservations keep their existing CAS behavior. |
| Draft/anchor/conflict/pending record-kind routing | Only desktop input kinds use the writer; unrelated metadata retains its previous SQL path. Draft and anchor removals cancel pending snapshots too. |
| Empty `preserveDraftConflicts` input | No write is needed. Nonempty pinned copies/inputs still persist after rollback before errors return, and remain pinned if preservation fails. Existing release-path and rollback tests pass. |
| Submission snapshot is stale | Its composer write is skipped, but the captured input still commits independently. A genuine cross-instance conflict still saves both copies and throws. Recovery/withdrawal never catches stale to consume an unsaved restored input. |
| Withdrawal has no replacement draft | Explicit discard uses the independent input operation; it does not supersede unrelated typing. A text restoration uses one text transaction and preserves the intent on rejection. |
| Conditional registration finds a receipt instead of a pending keep | Return the registered chat without beginning its prepared writer, cancelling typing or replacing saved text. Real registration begins after eligibility checks and before any mutation. A newer actual write invalidates older preparations; an older candidate beginning does not invalidate newer candidates. Completion removes only its own candidate. Both the existing side/fork race and the new conditional ordering tests cover these branches. |
| Debounce/store unavailable or cancellation; anchor cancellation | The existing one-time save-error banner is retained. Cancelled/stale work is silent, without a conflict banner. Baseline-loading guards, ephemeral-side policy and recovery ownership remain unchanged. |
| Connection refusal samples the live composer at its save | The refusal never emptied the composer. New typing/attachments after Return now remain the durable contents, rather than being replaced by the rejected captured proposal. The original connection error and refusal to dispatch remain unchanged. |
| Returned-submission snapshot captured before waiting for recording | New typing during that wait supersedes the old returned snapshot. Rejected recovery leaves the independent intent durable rather than overwriting newer text or consuming the only recoverable copy. |

The review did not find changes to helper identity, wire parameters, dispatch
authority, permission/capture/tool/vault boundaries, conflict retention or UI
layout. No helper/wire behavior or UI rendering changed this round.

### Validation process note

One broad run was misclassified: `AppShellPerformanceTests` creates/focuses
windows and had been included in the headless group. It was stopped, its partial
results excluded, and its log retained as `aborted-focus-group.log`. Some AppShell
tests had started before the stop; this was a lock-procedure error, not a claim
that the run was focus-free. The corrected final script runs that class in the
locked window group. No other workstream's lock was removed. All remaining
window/focus runs use the shared lock, and serial-lane classes run alone.

### Initial mutation evidence

Each initial mutation was applied alone, tested, and restored in `finally`
before the next run. These seven commands exited 65 from test assertions, not
build failures (10/10 selected executions failed as expected). The final writer,
including conditional admission, is mutation-tested again below; these earlier
results are not added to the final counts.

| Log | Tests | Assertion/error failures | Result |
| --- | ---: | ---: | --- |
| `mutation-debounce.log` | 2 | 2 (0 unexpected-error assertions) | Mutation caught |
| `mutation-stale-revision.log` | 2 | 7 (1 unexpected-error assertions) | Mutation caught |
| `mutation-ticket.log` | 2 | 7 (0 unexpected-error assertions) | Mutation caught |
| `mutation-anchor.log` | 1 | 2 (0 unexpected-error assertions) | Mutation caught |
| `mutation-submission.log` | 1 | 1 (1 unexpected-error assertions) | Mutation caught |
| `mutation-cancel.log` | 1 | 8 (0 unexpected-error assertions) | Mutation caught |
| `mutation-registration.log` | 1 | 1 (0 unexpected-error assertions) | Mutation caught |

Exact reproduction and mutation commands:

```sh
# failing-order
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests
# failing-registration
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testAlreadyRegisteredSideSavesTheNewerSnapshotThatCancelledItsDebounce
# mutation-debounce
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testDelayedDebounceCannotOverwriteDirectSave -only-testing:PiAppTests/DraftOrderingTests/testDelayedDebounceCannotRemoveAnEditSubmissionReview
# mutation-stale-revision
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testSupersededRevisionCannotStartOrReplaceAConflictEpisode -only-testing:PiAppTests/DraftOrderingTests/testObsoleteReservationCannotCancelNewerPendingTyping
# mutation-ticket
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testSupersededTicketIsStaleEvenWhenItsTaskIgnoresCancellation -only-testing:PiAppTests/DraftOrderingTests/testSupersededRecoveryCannotConsumeItsInputOrConflictCopy
# mutation-anchor
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testDelayedAnchorCannotOverwriteDirectPositionOrClear
# mutation-submission
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testSupersededSubmissionSnapshotKeepsItsIndependentInput
# mutation-cancel
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testEveryDirectDraftWriterSupersedesAPendingDebounce
# mutation-registration
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testAlreadyRegisteredSideSavesTheNewerSnapshotThatCancelledItsDebounce
```

Intermediate integration evidence: `fixed-order.log` ran 39 tests with two
failures (the predecessor fixture and nil-replacement withdrawal described
above); `ordering-sweep.log` ran 47 with the remaining old fixture failure;
`fixed-core.log` passed 76/76 after both corrections. `fixed-registration.log`
passed all 13 ordering tests after the adversarial registration check. These
intermediate runs are not added to the final unique test count.

### Final mutation evidence

All nine isolated mutations failed through test assertions (native exit 65);
12/12 selected test executions failed as expected. Each mutation was restored
in `finally`. The final source hashes were captured after restoration.

| Log | Tests | Assertion/error failures |
| --- | ---: | ---: |
| `mutation-final-debounce.log` | 2 | 2 (0 unexpected-error assertions) |
| `mutation-final-stale-revision.log` | 2 | 7 (1 unexpected-error assertions) |
| `mutation-final-ticket.log` | 2 | 7 (0 unexpected-error assertions) |
| `mutation-final-anchor.log` | 1 | 2 (0 unexpected-error assertions) |
| `mutation-final-submission.log` | 1 | 1 (1 unexpected-error assertions) |
| `mutation-final-cancel.log` | 1 | 8 (0 unexpected-error assertions) |
| `mutation-final-conditional-admission.log` | 1 | 2 (0 unexpected-error assertions) |
| `mutation-final-conditional-begin.log` | 1 | 2 (0 unexpected-error assertions) |
| `mutation-final-conditional-order.log` | 1 | 3 (0 unexpected-error assertions) |

Exact final mutation commands:

```sh
# mutation-final-debounce
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testDelayedDebounceCannotOverwriteDirectSave -only-testing:PiAppTests/DraftOrderingTests/testDelayedDebounceCannotRemoveAnEditSubmissionReview
# mutation-final-stale-revision
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testSupersededRevisionCannotStartOrReplaceAConflictEpisode -only-testing:PiAppTests/DraftOrderingTests/testObsoleteReservationCannotCancelNewerPendingTyping
# mutation-final-ticket
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testSupersededTicketIsStaleEvenWhenItsTaskIgnoresCancellation -only-testing:PiAppTests/DraftOrderingTests/testSupersededRecoveryCannotConsumeItsInputOrConflictCopy
# mutation-final-anchor
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testDelayedAnchorCannotOverwriteDirectPositionOrClear
# mutation-final-submission
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testSupersededSubmissionSnapshotKeepsItsIndependentInput
# mutation-final-cancel
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testEveryDirectDraftWriterSupersedesAPendingDebounce
# mutation-final-conditional-admission
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testCompletedRegistrationLeavesPendingTypingWithItsWriter
# mutation-final-conditional-begin
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testPreparedRegistrationSupersedesAnOlderDebounceWhenItWrites
# mutation-final-conditional-order
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testPreparedRegistrationCannotOverwriteNewerTypingOrConsumeItsIntent
```

### Final caller audit: connection refusal

The final capture audit confirmed another delayed-snapshot instance in
`deliverSubmission`: a connection refusal saved the proposal captured before
its task started, while admitting it as a new write after newer typing.
`testConnectionRefusalSavesCurrentTypingInsteadOfItsCapturedMessage` failed
first in `failing-refusal.log`:

```text
actual: Optional("Text when Return was pressed")
expected: Optional("Newer typing after the refusal")
```

A refused send never cleared the composer. Its direct save now samples
`view.savedDraft` at admission, including the current text and attachments,
and still reports the original connection refusal without dispatching work.
`fixed-refusal.log` passed 35/35 tests (all 17 ordering tests, 12 submission
bookkeeping tests and 6 workspace-failure tests). Reinstating the captured
proposal is checked in `mutation-final-refusal.log`. This is an additional
nearby writer fixed in the same function. All final affected classes are rerun
after this one-line change; the preceding full pass remains available in the
`final-*-before-refusal.log` files and is not counted twice.

The refusal mutation restored the captured proposal and failed 1/1 test with
one equality assertion (native exit 65), reproducing the same text mismatch.
The source was restored before the final rerun. Together with the nine
mutations above, **10/10 mutation variants were caught; 13/13 selected test
executions failed as expected**.

```sh
# failing-refusal / mutation-final-refusal
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests/testConnectionRefusalSavesCurrentTypingInsteadOfItsCapturedMessage
# fixed-refusal
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests -only-testing:PiAppTests/SendBookkeepingTests -only-testing:PiAppTests/WorkspaceFailureTests
```

### Final native validation

**680 passed; 1 skipped; 0 failed**, across 45 affected classes.

| Class | Tests | Skipped | Failed |
| --- | ---: | ---: | ---: |
| `AppShellPerformanceTests` | 11 | 0 | 0 |
| `ComposerImportSubmissionTests` | 11 | 0 | 0 |
| `ComposerSubmissionTests` | 7 | 1 | 0 |
| `ConversationFamilyTests` | 22 | 0 | 0 |
| `ConversationPaneTests` | 83 | 0 | 0 |
| `DeferredCreationTests` | 4 | 0 | 0 |
| `DraftConcurrencyTests` | 34 | 0 | 0 |
| `DraftLoadingTests` | 15 | 0 | 0 |
| `DraftMarkTests` | 5 | 0 | 0 |
| `DraftOrderingTests` | 17 | 0 | 0 |
| `DraftSizeTests` | 2 | 0 | 0 |
| `FamilyDeletionTests` | 10 | 0 | 0 |
| `HardeningTests` | 12 | 0 | 0 |
| `HistoricalEditBookkeepingTests` | 2 | 0 | 0 |
| `HistoricalEditFocusTests` | 1 | 0 | 0 |
| `HistoricalEditingTests` | 5 | 0 | 0 |
| `InheritedSubagentReaderTests` | 8 | 0 | 0 |
| `LaunchSelectionTests` | 20 | 0 | 0 |
| `LifecycleHelperTests` | 11 | 0 | 0 |
| `MetadataDurabilityTests` | 10 | 0 | 0 |
| `ModelSwitchTests` | 24 | 0 | 0 |
| `PendingChatProjectTests` | 24 | 0 | 0 |
| `QueueEditInteractionTests` | 17 | 0 | 0 |
| `QueuedEditPresentationTests` | 9 | 0 | 0 |
| `RecoveredDraftTests` | 13 | 0 | 0 |
| `SendBookkeepingTests` | 12 | 0 | 0 |
| `SendImmediacyTests` | 14 | 0 | 0 |
| `SessionReadStateTests` | 16 | 0 | 0 |
| `SideKeepOrderingTests` | 12 | 0 | 0 |
| `SideKeepRecoveryTests` | 15 | 0 | 0 |
| `SideRelaunchTests` | 3 | 0 | 0 |
| `SideTests` | 15 | 0 | 0 |
| `SidebarSideClickTests` | 4 | 0 | 0 |
| `StorageTruthTests` | 11 | 0 | 0 |
| `SubagentDeletionTests` | 10 | 0 | 0 |
| `SubagentMetadataTests` | 9 | 0 | 0 |
| `SubagentOpeningTests` | 13 | 0 | 0 |
| `SubagentReaderTests` | 56 | 0 | 0 |
| `WindowLifecycleTests` | 5 | 0 | 0 |
| `WorkspaceDisplayMemoryTests` | 2 | 0 | 0 |
| `WorkspaceDurabilityTests` | 7 | 0 | 0 |
| `WorkspaceFailureTests` | 6 | 0 | 0 |
| `WorkspaceLoadingTests` | 13 | 0 | 0 |
| `WorkspaceRaceTests` | 49 | 0 | 0 |
| `WorkspaceRefreshLifecycleTests` | 32 | 0 | 0 |

Exact final commands (text logs use the comment names):

```sh
# final-model
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests -only-testing:PiAppTests/DraftConcurrencyTests -only-testing:PiAppTests/DraftLoadingTests -only-testing:PiAppTests/DraftMarkTests -only-testing:PiAppTests/DraftSizeTests -only-testing:PiAppTests/MetadataDurabilityTests -only-testing:PiAppTests/StorageTruthTests -only-testing:PiAppTests/SendBookkeepingTests -only-testing:PiAppTests/RecoveredDraftTests -only-testing:PiAppTests/SideTests -only-testing:PiAppTests/DeferredCreationTests -only-testing:PiAppTests/WorkspaceDurabilityTests -only-testing:PiAppTests/WorkspaceFailureTests -only-testing:PiAppTests/WorkspaceRaceTests -only-testing:PiAppTests/WorkspaceLoadingTests -only-testing:PiAppTests/WorkspaceDisplayMemoryTests -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests -only-testing:PiAppTests/SessionReadStateTests -only-testing:PiAppTests/HardeningTests -only-testing:PiAppTests/HistoricalEditBookkeepingTests -only-testing:PiAppTests/SubagentMetadataTests
# final-deletion
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FamilyDeletionTests -only-testing:PiAppTests/SubagentDeletionTests
# final-windows
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/AppShellPerformanceTests -only-testing:PiAppTests/HistoricalEditingTests -only-testing:PiAppTests/HistoricalEditFocusTests -only-testing:PiAppTests/SideKeepOrderingTests -only-testing:PiAppTests/SideKeepRecoveryTests -only-testing:PiAppTests/SideRelaunchTests -only-testing:PiAppTests/SidebarSideClickTests -only-testing:PiAppTests/LaunchSelectionTests -only-testing:PiAppTests/ConversationFamilyTests -only-testing:PiAppTests/ModelSwitchTests -only-testing:PiAppTests/PendingChatProjectTests -only-testing:PiAppTests/SendImmediacyTests -only-testing:PiAppTests/ComposerSubmissionTests -only-testing:PiAppTests/ComposerImportSubmissionTests -only-testing:PiAppTests/QueuedEditPresentationTests
# final-queue
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QueueEditInteractionTests
# final-reader
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentReaderTests
# final-original
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InheritedSubagentReaderTests
# final-opening
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentOpeningTests
# final-conversation
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationPaneTests
# final-lifecycle
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/LifecycleHelperTests
# final-window
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WindowLifecycleTests
```

All 10 source/project hashes match the validated state in
`tested-source-sha256.json`. The final classes cover draft ordering, conflict
retention and release, baseline hydration, markers, size limits, submission and
edit bookkeeping, side publication/recovery, queue editing, managed-child
readers, lifecycle/quit/update, and native conversation interactions. No helper
implementation, host protocol or wire contract changed; helper and
wire/concurrent/acceptance suites were not required. No UI rendering changed,
so no gallery was needed. No unresolved code findings remain.

The single existing skip is
`ComposerSubmissionTests.testTheMenuBarGivesCommandReturnToSendOrSteer`:
“This test host has no Conversation menu” (`ComposerSubmissionTests.swift:126`).
No additional skips or failed tests remain in the final run.

Final adversarial review and source-hash verification are complete. Own generated
test-result bundles were removed after the runs; no own clone app directories
remained. Text logs are retained. The shared lane was released after each owned
run, including the last window test. Other workstreams' locks and build products
were not touched. The early focus-group procedure error and corrected locked
rerun are recorded above; its partial results are excluded from these counts.

## Round 9 — independent captured submissions

Baseline: `d5d63a40`. The historical-edit review finding is **confirmed and
fixed**. The sweep covers every requested captured submission kind, including
an ordinary chat's first send. Generated state directories, memory vaults,
injected helper frames and existing loopback fixtures are the only inputs.
No installed app, real preferences/chats/credentials or paid provider is used.
Evidence directory:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round9/`.

### Input records and ordering

Captured input and the composer are separate lifetimes. `recordSubmission`
commits the captured `CommandIntent` even if a newer typing ticket has retired
its accompanying composer snapshot. It still refuses dispatch on a real
storage error or cross-instance conflict, preserving the existing error and
recovery paths. Connection, archive and helper-identity checks still gate
execution. No request parameters or helper implementation changed.

| Submission kind | Independent durable record | Dispatch / composer behavior |
| --- | --- | --- |
| Ordinary Send / follow-up | `pending:<sessionID>`, keyed by `commandID`, containing captured text, attachments, skills and turn ID | `turn.submit` waits for intent persistence. The post-send draft snapshot can be superseded. |
| New chat's first Send | Same `CommandIntent`, after creating its chat row | A stale materialization **draft** no longer aborts the captured first input. Chat identity, storage failures and genuine conflicts still refuse the operation. |
| Historical Resend / edit of an earlier message | Same `CommandIntent`, now saved by `recordSubmission` before opening the runtime | `turn.edit` uses the captured replacement and original target; newer editor typing stays attached to the accepted replacement as before. Its review marker belongs to the replaceable draft. |
| Queued-message Save | `pending:<sessionID>`, keyed by `queue-edit:<editID>:<SHA256(captured text)>`; `turnID` uses the `queue-edit:` namespace and optional `queueEditID` identifies its helper hold | `queue.edit.save` waits for the independent input. Same-edit/same-text retries reuse the record; a different capture cannot overwrite it. Ordinary turn-intent rewrites do not target this namespace. |
| Steer | Same ordinary `CommandIntent`, with its own command/turn IDs | `turn.steer` waits for persistence; text and image/skill captures remain independent of typing. Existing eligibility and completion behavior remain unchanged. |
| Side first Send | Same ordinary `CommandIntent`, saved beside the existing `SideKeepIntent` before parent opening | The input is no longer the side's initial draft. Parent opening can wait while the current composer is saved separately. The retained input is reused when normal submission persistence follows publication. |

Cancel/Remove of a queued hold do not capture new message input. They keep
using the existing hold-resolution protocol. A queue Save's successful reply
retires its captured input; after a lost reply, recovery requires both `saved`
and the exact captured text digest from `queue.edit.status`. Different or
unavailable outcomes keep the input in the existing recovery flow. The new
optional desktop field is backward-decodable; no database migration or wire
schema change is needed.

A rejected historical edit removes its input only together with a durable
composer still holding the captured text/images/skills. Changed typing or a
superseded restoration keeps the intent recoverable. A failed first side send
whose returned draft is only in an ephemeral display also keeps its intent,
exposed through the existing recovery actions. An unsent side with no accepted
submission retains its existing in-memory policy.

### Failing-first evidence

All new cases are in `SubmissionPersistenceTests`.

| Finding / sweep | Test | Failing evidence |
| --- | --- | --- |
| Historical edit cancelled by typing — confirmed/fixed | `testHistoricalEditKeepsCapturedInputWhileNewTypingSupersedesItsSnapshot` | No `turn.edit` frame and no intent; expected one frame and `Captured replacement`. |
| Queued Save lacks independent input — confirmed/fixed | `testQueuedEditKeepsCapturedInputWhileNewTypingSupersedesItsSnapshot` | `pending` text was `[]`, expected `["Captured replacement"]` while the helper reply was held. |
| First side input is only a draft — confirmed/fixed | `testSideFirstSendIsDurableWhileParentOpeningAndTypingContinue` | While parent opening was held, `pending` was `[]`, expected `["Captured first side message"]`. |
| First chat materialization aborts capture — confirmed/fixed | `testFirstChatSendSurvivesTypingDuringMaterializationDraftWrite` | Zero dispatches, no intent, and captured text returned into newer typing. The chat row had already committed. |
| Historical refusal drops changed input — confirmed/fixed | `testRejectedHistoricalEditRetainsItsInputWhenTheComposerChanged` | `pending` was `[]` after rejection; expected the captured replacement while the composer held different text. |
| Failed side recovery retires input held only in memory — confirmed/fixed | `testFailedSideFirstSendKeepsItsInputUntilDurableRecovery` | Neither the intent nor the saved draft contained the captured side input after parent-open rejection. |
| Queue retry record duplication — caught during implementation, fixed | `testQueuedSaveRetriesKeepOneRecordPerCapturedInput` | Two identical retries plus a different capture made three records; expected two distinct captures. |

The initial unchanged-production run, `failing-submissions.log`, executed five
tests: **two passed, three failed (five assertions)**. Ordinary Send and Steer
already used the separation correctly. The historical, queue and side failures
above were observed before changing production code.

`failing-recovery-sweep.log` executed three tests: **one passed, two failed
(four assertions)** before the materialization/refusal corrections. The
matching-versus-different queue outcome regression passed. `failing-side-recovery.log`
failed **one test / one assertion** before retaining the ephemeral side input.
`failing-queue-retry.log` failed **one test / one assertion** before making
same-input retry identity stable. These failures are not included in the final
passing counts.

The actor-barrier regressions hold the metadata writer, capture the command,
allow newer typing and its debounce, then release persistence. They assert one
dispatch with the original input, an independent durable intent while the reply
is held, and the newer saved composer. The side case additionally holds parent
opening; the new-chat case holds the separate materialization draft write.
A second store instance verifies that queue input survives later debounces and
is retired only by the matching durable helper outcome.

Intermediate positive evidence: `fixed-submissions.log` passed 24/24;
`fixed-core.log` passed 142/142; `fixed-captured-inputs.log` passed 12/12
(all ten new regressions plus both historical bookkeeping tests).

### Adversarial self-review

| Changed condition / ordering | States taking the new path and intended result |
| --- | --- |
| Historical snapshot ticket is stale | Skip only that snapshot; commit the captured intent and proceed through the existing connection/archive checks to `turn.edit`. No newer typing is substituted into dispatch. |
| Historical intent persisted before runtime opening | Opening failures cannot leave its captured replacement dependent on a mutable editor snapshot. Epoch is the ready helper's epoch when available, matching ordinary sends; it is not execution authority. |
| Queued Save versus Cancel/Remove | Only Save captures input. Its intent must be durable before the request; failed local persistence makes no helper mutation. Existing control operations still use their original protocol. |
| Same queued edit/text versus different capture | Same digest reuses one input identity. Another text has another identity; later draft debounces and queue-row bookkeeping cannot overwrite either captured input. |
| Queue reply or recovered outcome | A known successful Save retires the input. Recovery accepts only the same edit and exact text digest; missing, active or different outcomes retain the input. Later typing is never used as acceptance evidence. |
| Pending side has a captured first input | Persist that intent before awaiting its parent's runtime; save the current composer separately. Non-submitting side publication still saves its ordinary draft. |
| Only materialization's draft write becomes stale | Its already-written chat remains materialized and the first submission continues. Record removal, real CAS conflicts and storage errors retain their existing refusal behavior. |
| Rejected edit still matches captured input | Save that matching draft and withdraw the intent atomically. A changed composer or stale ticket keeps the independent record; review-marker removal cannot erase captured text. |
| Failed side has no durable replacement draft | Keep the independent input and existing recovery actions. Ordinary retained chats still withdraw only with their durable returned draft; connection refusals that never accepted input keep their previous path. |

The review also traced `recordQueuedRewrite` (explicit accepted rewrite of an
ordinary queued turn), `recoverFailedSubmission`, `recoverDraft`,
`restoreConflictedDraft`, `protectReturnedDrafts`, terminal receipt retirement,
side registration and materialization. Captured queue records use a separate
turn namespace so ordinary queued-turn updates do not replace them. No new
provider/tool/capture/vault permissions, routing behavior, prompt, or UI layout
is introduced. Existing recovery controls display retained input; no gallery
is required for these persistence and dispatch changes.

The final test partition is regenerated from `scripts/test-lanes.py list
--configuration Debug`; every serial class runs alone, including
`HistoricalEditFocusTests` and `SessionReadStateTests`. Window/focus runs hold
the shared full-lane lock. Focus-free actor tests and mutation checks use only
this workstream's build root. All commands and counts follow below.

### Mutation evidence

All **9/9 mutation variants were caught** through native test assertions;
**12/12 selected test executions failed as expected**, with native exit 65.
Each mutation was isolated and restored in `finally` before the next run.

| Mutation log | Tests | Assertion failures |
| --- | ---: | ---: |
| `mutation-historical.log` | 1 | 3 |
| `mutation-queue.log` | 1 | 1 |
| `mutation-side.log` | 1 | 1 |
| `mutation-independent-input.log` | 4 | 14 |
| `mutation-materialization.log` | 1 | 3 |
| `mutation-edit-refusal.log` | 1 | 1 |
| `mutation-side-recovery.log` | 1 | 1 |
| `mutation-queue-outcome.log` | 1 | 2 |
| `mutation-queue-retry.log` | 1 | 1 |

Two preliminary mutation builds exposed unused locals after instrumentation
removed their uses (`mutation-historical-build-failure.log` and
`mutation-queue-build-failure.log`). The harness was corrected, source restored,
and both variants rerun to actual failing assertions. Those build-only attempts
are excluded from mutation counts.

Exact reproduction, initial fixed and mutation commands:

```sh
# failing-submissions
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests
# failing-recovery-sweep
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testFirstChatSendSurvivesTypingDuringMaterializationDraftWrite -only-testing:PiAppTests/SubmissionPersistenceTests/testRejectedHistoricalEditRetainsItsInputWhenTheComposerChanged -only-testing:PiAppTests/SubmissionPersistenceTests/testQueuedSaveRecoveryRetiresOnlyTheMatchingDurableOutcome
# failing-side-recovery
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testFailedSideFirstSendKeepsItsInputUntilDurableRecovery
# failing-queue-retry
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testQueuedSaveRetriesKeepOneRecordPerCapturedInput
# fixed-submissions
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests -only-testing:PiAppTests/DraftOrderingTests -only-testing:PiAppTests/HistoricalEditBookkeepingTests
# fixed-core
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests -only-testing:PiAppTests/DraftOrderingTests -only-testing:PiAppTests/HistoricalEditBookkeepingTests -only-testing:PiAppTests/DraftConcurrencyTests -only-testing:PiAppTests/SendBookkeepingTests -only-testing:PiAppTests/SideTests -only-testing:PiAppTests/DeferredCreationTests -only-testing:PiAppTests/WorkspaceRaceTests
# fixed-captured-inputs
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests -only-testing:PiAppTests/HistoricalEditBookkeepingTests
# mutation-historical
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testHistoricalEditKeepsCapturedInputWhileNewTypingSupersedesItsSnapshot
# mutation-queue
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testQueuedEditKeepsCapturedInputWhileNewTypingSupersedesItsSnapshot
# mutation-side
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testSideFirstSendIsDurableWhileParentOpeningAndTypingContinue
# mutation-independent-input
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testSendKeepsCapturedInputWhileNewTypingSupersedesItsSnapshot -only-testing:PiAppTests/SubmissionPersistenceTests/testSteerKeepsCapturedInputWhileNewTypingSupersedesItsSnapshot -only-testing:PiAppTests/SubmissionPersistenceTests/testHistoricalEditKeepsCapturedInputWhileNewTypingSupersedesItsSnapshot -only-testing:PiAppTests/SubmissionPersistenceTests/testQueuedEditKeepsCapturedInputWhileNewTypingSupersedesItsSnapshot
# mutation-materialization
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testFirstChatSendSurvivesTypingDuringMaterializationDraftWrite
# mutation-edit-refusal
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testRejectedHistoricalEditRetainsItsInputWhenTheComposerChanged
# mutation-side-recovery
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testFailedSideFirstSendKeepsItsInputUntilDurableRecovery
# mutation-queue-outcome
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testQueuedSaveRecoveryRetiresOnlyTheMatchingDurableOutcome
# mutation-queue-retry
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testQueuedSaveRetriesKeepOneRecordPerCapturedInput
```

### Final native validation

**726 passed; 2 skipped; 0 failed**, across 50 affected classes.

| Class | Tests | Skipped | Failed |
| --- | ---: | ---: | ---: |
| `AppShellPerformanceTests` | 11 | 0 | 0 |
| `ComposerImportSubmissionTests` | 11 | 0 | 0 |
| `ComposerSubmissionTests` | 7 | 1 | 0 |
| `ConversationFamilyTests` | 22 | 0 | 0 |
| `ConversationPaneTests` | 83 | 0 | 0 |
| `DeferredCreationTests` | 4 | 0 | 0 |
| `DraftConcurrencyTests` | 34 | 0 | 0 |
| `DraftLoadingTests` | 15 | 0 | 0 |
| `DraftMarkTests` | 5 | 0 | 0 |
| `DraftOrderingTests` | 17 | 0 | 0 |
| `DraftSizeTests` | 2 | 0 | 0 |
| `FamilyDeletionTests` | 10 | 0 | 0 |
| `HardeningTests` | 12 | 0 | 0 |
| `HistoricalEditBookkeepingTests` | 2 | 0 | 0 |
| `HistoricalEditFocusTests` | 1 | 0 | 0 |
| `HistoricalEditingTests` | 5 | 0 | 0 |
| `InheritedSubagentReaderTests` | 8 | 0 | 0 |
| `LaunchSelectionTests` | 20 | 0 | 0 |
| `LifecycleHelperTests` | 11 | 0 | 0 |
| `MetadataDurabilityTests` | 10 | 0 | 0 |
| `ModelSwitchTests` | 24 | 0 | 0 |
| `PendingChatProjectTests` | 24 | 0 | 0 |
| `QueueEditInteractionTests` | 17 | 0 | 0 |
| `QueuedAttachmentLimitTests` | 2 | 0 | 0 |
| `QueuedEditPresentationTests` | 9 | 0 | 0 |
| `RecoveredDraftTests` | 13 | 0 | 0 |
| `SendBookkeepingTests` | 12 | 0 | 0 |
| `SendImmediacyTests` | 14 | 0 | 0 |
| `SessionReadStateTests` | 16 | 0 | 0 |
| `SideKeepOrderingTests` | 12 | 0 | 0 |
| `SideKeepRecoveryTests` | 15 | 0 | 0 |
| `SideRelaunchTests` | 3 | 0 | 0 |
| `SideTests` | 15 | 0 | 0 |
| `SidebarSideClickTests` | 4 | 0 | 0 |
| `SkillRefreshTests` | 15 | 0 | 0 |
| `StorageTruthTests` | 11 | 0 | 0 |
| `SubagentDeletionTests` | 10 | 0 | 0 |
| `SubagentMetadataTests` | 9 | 0 | 0 |
| `SubagentOpeningTests` | 13 | 0 | 0 |
| `SubagentReaderTests` | 56 | 0 | 0 |
| `SubmissionPersistenceTests` | 10 | 0 | 0 |
| `WindowLifecycleTests` | 5 | 0 | 0 |
| `WireContractTests` | 11 | 1 | 0 |
| `WorkspaceDisplayMemoryTests` | 2 | 0 | 0 |
| `WorkspaceDurabilityTests` | 7 | 0 | 0 |
| `WorkspaceFailureTests` | 6 | 0 | 0 |
| `WorkspaceFollowupTests` | 9 | 0 | 0 |
| `WorkspaceLoadingTests` | 13 | 0 | 0 |
| `WorkspaceRaceTests` | 49 | 0 | 0 |
| `WorkspaceRefreshLifecycleTests` | 32 | 0 | 0 |

Exact final commands (text logs use the comment names):

```sh
# final-model
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests -only-testing:PiAppTests/DraftConcurrencyTests -only-testing:PiAppTests/DraftLoadingTests -only-testing:PiAppTests/DraftMarkTests -only-testing:PiAppTests/DraftSizeTests -only-testing:PiAppTests/MetadataDurabilityTests -only-testing:PiAppTests/StorageTruthTests -only-testing:PiAppTests/SendBookkeepingTests -only-testing:PiAppTests/RecoveredDraftTests -only-testing:PiAppTests/SideTests -only-testing:PiAppTests/DeferredCreationTests -only-testing:PiAppTests/WorkspaceDurabilityTests -only-testing:PiAppTests/WorkspaceFailureTests -only-testing:PiAppTests/WorkspaceRaceTests -only-testing:PiAppTests/WorkspaceLoadingTests -only-testing:PiAppTests/WorkspaceDisplayMemoryTests -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests -only-testing:PiAppTests/HardeningTests -only-testing:PiAppTests/HistoricalEditBookkeepingTests -only-testing:PiAppTests/SubagentMetadataTests -only-testing:PiAppTests/SubmissionPersistenceTests
# final-alone-SessionReadStateTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionReadStateTests
# final-deletion
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FamilyDeletionTests -only-testing:PiAppTests/SubagentDeletionTests
# final-windows
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/AppShellPerformanceTests -only-testing:PiAppTests/HistoricalEditingTests -only-testing:PiAppTests/SideKeepOrderingTests -only-testing:PiAppTests/SideKeepRecoveryTests -only-testing:PiAppTests/SideRelaunchTests -only-testing:PiAppTests/SidebarSideClickTests -only-testing:PiAppTests/LaunchSelectionTests -only-testing:PiAppTests/ConversationFamilyTests -only-testing:PiAppTests/ModelSwitchTests -only-testing:PiAppTests/PendingChatProjectTests -only-testing:PiAppTests/SendImmediacyTests -only-testing:PiAppTests/ComposerSubmissionTests -only-testing:PiAppTests/ComposerImportSubmissionTests -only-testing:PiAppTests/QueuedEditPresentationTests
# final-alone-HistoricalEditFocusTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/HistoricalEditFocusTests
# final-queue
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QueueEditInteractionTests
# final-reader
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentReaderTests
# final-original
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InheritedSubagentReaderTests
# final-opening
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentOpeningTests
# final-conversation
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationPaneTests
# final-lifecycle
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/LifecycleHelperTests
# final-window
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WindowLifecycleTests
# final-additional
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QueuedAttachmentLimitTests -only-testing:PiAppTests/SkillRefreshTests -only-testing:PiAppTests/WireContractTests -only-testing:PiAppTests/WorkspaceFollowupTests
```

All 9 source/project hashes match the validated state in
`tested-source-sha256.json`. The final classes cover draft ordering, conflict
retention and release, baseline hydration, markers, size limits, submission and
edit bookkeeping, side publication/recovery, queue editing, managed-child
readers, lifecycle/quit/update, and native conversation interactions. No helper
implementation, host protocol or wire contract changed; helper and
wire/concurrent/acceptance suites were not required. No UI rendering changed,
so no gallery was needed. No unresolved findings from this review remain.

The two existing skips are:

- `ComposerSubmissionTests.testTheMenuBarGivesCommandReturnToSendOrSteer`
  (`ComposerSubmissionTests.swift:126`): the test host has no Conversation menu.
- `WireContractTests.testPerTokenSnapshotWithSeventyFinishedTurns`
  (`WireContractTests.swift:614`): the performance measurement requires
  `PI_PERF_WIRE=1`. No changed behavior depends on that opt-in measurement.

Final adversarial review, source-hash verification and `git diff --check` are
complete. All window/focus runs held the shared lane, and every serial class
ran alone. Own generated result bundles were removed after testing; no own
clone directories remained. Text logs are retained. No other workstream's
build products or lock were touched. No unresolved findings from this review
remain.

## Round 9 integration with dev/next

The lead requested a merge, after Round 9 passed review, of
`origin/dev/next` (`649ea623291c9417443d61d3bb55314d8a2f5d9a`) into
`dev/a130-workspace` (`8c3157244622061aa4904a364dc32cc968b2212f`).
`git fetch origin` and `git merge origin/dev/next` produced ten conflicts.
This is a two-parent merge; neither branch's history was rewritten.

### Conflict resolutions

- `NEXT-RELEASE.md`: retained both sets of completed entries. The incoming
  completed cost-pause entry supersedes the old unchecked known-issue entry.
- `PiApp.xcodeproj/project.pbxproj`: regenerated with
  `xcodegen generate --quiet`; both branches' sources and tests are included.
- `WorkspaceChatLifecycle.swift`: kept `anchor-deleted` and conflict-copy
  cleanup, plus incoming deferred tool-output collection. Automatically merged
  materialization retains loaded draft baselines and superseded-snapshot handling
  inside the incoming producer lifetime.
- `WorkspaceConnectionProbe.swift` / `WorkspaceModel.swift`: one
  `connectionProbeAdmissions` counter covers configuration/credential waits and
  cleanup. `connectionProbeHosts` owns private helpers so pause/quit can stop
  them. `hasActiveWork` includes both the probe counter and Inspector resource
  invocations. The workspace concurrency tests now assert the unified counter.
- `WorkspaceResume.swift`: pause waits for admissions without a registered
  helper, then stops and waits for registered private helpers. All incoming
  Stop/Resume task cancellation and generation fences remain; image-import and
  archive fences remain too.
- `WorkspaceDrafts.swift`: each debounce retains its synchronously captured
  ordered-writer ticket, predecessor drain, cancellation check and versioned
  store write. Incoming tool-output use starts synchronously, is prepared before
  writing and ends on every exit. No early revision reservation was restored.
  Flush/recovery retain the incoming producer protection as well.
- `WorkspaceSubagentDeletion.swift`: retained the unsaved-conflict refusal,
  anchor tombstone/conflict cleanup, complete incoming tool-output inventory and
  recycling, and identity-aware `removeDeletedSideKeep` ownership transfer.
  Kept the incoming internal visibility used by deletion tests.
- `SubagentReaderTests.swift`: kept all tests from both branches, including
  pending-baseline typing, newer reveal ownership and mounted selection after
  helper replacement.
- `WorkspaceRaceTests.swift`: combined the fixture's session-scoped hold,
  rejection and next-method hold support with multiple held frames, reply
  tracking and Stop/Resume tokens. No test was removed.
- Incoming `ToolOutputProducerTests` uses the current `publishPendingSide`
  signature; its displayed draft remains the input for that admission test.

### Adversarial integration review

The only competing activity conditions are unified: credential-only probe
admissions still block pausing; registered probes can now be stopped by the
existing pause flow instead of waiting for provider completion. Both remain
active through cleanup and refuse new work behind update/shutdown barriers.
Inspector invocations also remain active. Stop invalidates Resume preparation
before dispatch, including family fan-out, while archive invalidation remains
independent. No obsolete task can publish a runtime or clean up its replacement.

Draft ordering is unchanged: the incoming producer await does not reserve a
revision, and a superseded ticket still fails before conflict mutation. Captured
send/steer/edit/queue/side inputs stay in independent command records. Tool-output
inventory scans all metadata rows, including conflict copies and independent
inputs, so the durable recovery holders remain references after display release.
A deleted side's different pending journal is retained before its intent is
removed; draft-conflict cleanup occurs only with the explicit family deletion.

The fixture's combined hold condition admits precisely frames matching its
method and optional session filter, retaining every matching frame for release.
Release switches the next hold method before replying, and rejection still
reports failure while recording the answered method. Production conditions were
not broadened to make either test set pass. All original test names in both
conflicted test files and all completed release entries from both parents were
checked for retention. No new product behavior or layout was introduced by the
conflict resolution itself. The additional automatically merged queued-Save
overlap below has a failing-first regression and mutation check. No layout
changed, so a gallery run is not applicable to this integration.

### Integration validation

Fresh evidence is under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round9-integration/`.
Native checks use the existing `native-tests` build root and text logs, with
serial-lane classes run alone. The focused draft/model, deletion, onboarding, run-hold and concurrency classes
are headless and use the explicit focused-test lock exemption; all window/focus groups hold the
shared full-lane lock, including parallel-eligible classes that create windows. The helper
checks use `swift-verify`, with the helper-test lock exemption for the ordinary
suite/build and the shared lock for isolated streaming-cost measurements;
wire/concurrent/acceptance are headless loopback helper tests and use that same
helper-test lock exemption. They use the Release helper built
by `scripts/build-bundle.py` under this workstream's build root. No installed app,
real preferences/chats/Keychain, live capture or paid provider is used.


### Queued Save integration overlap

The automatically merged `QueuePanel.resolveQueuedEdit` persisted Round 9's
captured input before calling the incoming `queueEditRequest` producer guard.
The captured references therefore lacked the helper branch's synchronous
producer registration while that independent write was pending.
`SubmissionPersistenceTests.testQueuedSaveProtectsOutputBeforePublishingCapturedInput`
checks protection synchronously at Save admission, then holds the request's
recycling barrier. The independent input must already be durable while that
barrier delays dispatch. Typing meanwhile still replaces only the composer;
after release the captured input is dispatched exactly once and newer typing
survives.

Failing first against the unprotected merge: **1 test failed, 1 assertion**
(`failing-queue-admission.log`, native exit 65):

```text
XCTAssertTrue failed - Captured input needs protection before its persistence task starts
```

Fix: a Save registers the existing `.queuedEdit` producer synchronously, before
its persistence task is queued, and releases it on every exit. Captured input
is saved before the request-level recycling wait. The request-level producer
remains for direct requests and status/Cancel/Remove paths. The focused regression
passes (`fixed-queue-admission.log`, 1 test, native exit 0).

The adversarial review rejected an initial extra wait before input persistence:
recycling must not delay durability of the captured submission. The exploratory
`*-queue-output.log` runs tested that over-constrained ordering and are excluded
from the final proof. The corrected regression explicitly requires durable input
while the request waits. Only registration/lifetime extends to the earlier
independent write; its persistence order is unchanged.

Condition review: only `intent != nil` (Save) owns the additional producer;
Cancel/Remove keep their request guard. Store failure retains the existing
local-save refusal without dispatch. A newer composer ticket still cannot
supersede the independent intent. The producer's lifetime includes refusal and
uncertain-outcome settlement; its `defer` runs on all returns. Nearby captured
send, Resend and side-first-send entry points already register before their
persistence awaits; no further changes were needed.

Mutation: replace the synchronous registration with `nil`. The corrected
regression fails again on the admission gap (**1 test, 1 assertion**, native
exit 65, `mutation-queue-admission.log`). The production registration was
restored. Final native runs replace the preliminary/exploratory model/deletion
results; helper and script source hashes remain unchanged.

### Final integration results

**Native: 825 passed, 2 skipped, 0 failures** (827 cases across 56 classes).

| Suite | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Native focused classes | 825 | 2 | 0 |
| Helper except StreamingCostTests | 1137 | 7 | 0 |
| Isolated StreamingCostTests | 5 | 0 | 0 |
| Release wire | 40 | 0 | 0 |
| Release concurrent | 4 | 0 | 0 |
| Release acceptance | 3 | 0 | 0 |
| Script unit tests | 118 | 0 | 0 |

Together the two helper runs cover the full suite: **1,142 passed, 7 skipped, 0 failures** (1,149 cases).

Native counts by class:

| Class | Cases | Skipped | Failed |
| --- | ---: | ---: | ---: |
| `AppShellPerformanceTests` | 11 | 0 | 0 |
| `ComposerImportSubmissionTests` | 11 | 0 | 0 |
| `ComposerSubmissionTests` | 7 | 1 | 0 |
| `ConversationFamilyTests` | 22 | 0 | 0 |
| `ConversationPaneTests` | 83 | 0 | 0 |
| `CostPauseFamilyTests` | 3 | 0 | 0 |
| `DeferredCreationTests` | 4 | 0 | 0 |
| `DraftConcurrencyTests` | 34 | 0 | 0 |
| `DraftLoadingTests` | 15 | 0 | 0 |
| `DraftMarkTests` | 5 | 0 | 0 |
| `DraftOrderingTests` | 17 | 0 | 0 |
| `DraftSizeTests` | 2 | 0 | 0 |
| `FamilyDeletionTests` | 10 | 0 | 0 |
| `HardeningTests` | 12 | 0 | 0 |
| `HistoricalEditBookkeepingTests` | 2 | 0 | 0 |
| `HistoricalEditFocusTests` | 1 | 0 | 0 |
| `HistoricalEditingTests` | 5 | 0 | 0 |
| `InheritedSubagentReaderTests` | 8 | 0 | 0 |
| `LaunchSelectionTests` | 21 | 0 | 0 |
| `LifecycleHelperTests` | 11 | 0 | 0 |
| `MetadataDurabilityTests` | 10 | 0 | 0 |
| `ModelSwitchTests` | 24 | 0 | 0 |
| `OnboardingTests` | 22 | 0 | 0 |
| `PendingChatProjectTests` | 24 | 0 | 0 |
| `QueueEditInteractionTests` | 17 | 0 | 0 |
| `QueuedAttachmentLimitTests` | 2 | 0 | 0 |
| `QueuedEditPresentationTests` | 9 | 0 | 0 |
| `RecoveredDraftTests` | 13 | 0 | 0 |
| `RunHoldTests` | 18 | 0 | 0 |
| `SendBookkeepingTests` | 12 | 0 | 0 |
| `SendImmediacyTests` | 14 | 0 | 0 |
| `SessionReadStateTests` | 16 | 0 | 0 |
| `SideKeepOrderingTests` | 12 | 0 | 0 |
| `SideKeepRecoveryTests` | 15 | 0 | 0 |
| `SideRelaunchTests` | 3 | 0 | 0 |
| `SideTests` | 15 | 0 | 0 |
| `SidebarSideClickTests` | 4 | 0 | 0 |
| `SkillRefreshTests` | 15 | 0 | 0 |
| `StorageTruthTests` | 11 | 0 | 0 |
| `SubagentDeletionTests` | 19 | 0 | 0 |
| `SubagentMetadataTests` | 9 | 0 | 0 |
| `SubagentOpeningTests` | 14 | 0 | 0 |
| `SubagentReaderTests` | 58 | 0 | 0 |
| `SubmissionPersistenceTests` | 11 | 0 | 0 |
| `ToolOutputProducerTests` | 8 | 0 | 0 |
| `UpdatePauseTests` | 8 | 0 | 0 |
| `WindowLifecycleTests` | 5 | 0 | 0 |
| `WireContractTests` | 11 | 1 | 0 |
| `WorkspaceConcurrencyTests` | 10 | 0 | 0 |
| `WorkspaceDisplayMemoryTests` | 2 | 0 | 0 |
| `WorkspaceDurabilityTests` | 9 | 0 | 0 |
| `WorkspaceFailureTests` | 6 | 0 | 0 |
| `WorkspaceFollowupTests` | 9 | 0 | 0 |
| `WorkspaceLoadingTests` | 13 | 0 | 0 |
| `WorkspaceRaceTests` | 58 | 0 | 0 |
| `WorkspaceRefreshLifecycleTests` | 37 | 0 | 0 |

Exact final commands, run from the worktree root. Each comment names the corresponding `.log`, `.command` and `.status` file:

```sh
# test-macos.sh rebuilds/stages the Release helper with this nested command:
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace python3 scripts/build-bundle.py
# integration-model
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftOrderingTests -only-testing:PiAppTests/DraftConcurrencyTests -only-testing:PiAppTests/DraftLoadingTests -only-testing:PiAppTests/DraftMarkTests -only-testing:PiAppTests/DraftSizeTests -only-testing:PiAppTests/MetadataDurabilityTests -only-testing:PiAppTests/StorageTruthTests -only-testing:PiAppTests/SendBookkeepingTests -only-testing:PiAppTests/RecoveredDraftTests -only-testing:PiAppTests/SideTests -only-testing:PiAppTests/DeferredCreationTests -only-testing:PiAppTests/WorkspaceDurabilityTests -only-testing:PiAppTests/WorkspaceFailureTests -only-testing:PiAppTests/WorkspaceRaceTests -only-testing:PiAppTests/WorkspaceLoadingTests -only-testing:PiAppTests/WorkspaceDisplayMemoryTests -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests -only-testing:PiAppTests/HardeningTests -only-testing:PiAppTests/HistoricalEditBookkeepingTests -only-testing:PiAppTests/SubagentMetadataTests -only-testing:PiAppTests/SubmissionPersistenceTests
# integration-deletion
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FamilyDeletionTests -only-testing:PiAppTests/SubagentDeletionTests
# integration-probes
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/OnboardingTests -only-testing:PiAppTests/RunHoldTests -only-testing:PiAppTests/WorkspaceConcurrencyTests
# integration-priority
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ToolOutputProducerTests -only-testing:PiAppTests/UpdatePauseTests
# integration-cost-pause
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CostPauseFamilyTests
# integration-alone-SessionReadStateTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionReadStateTests
# integration-windows
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/AppShellPerformanceTests -only-testing:PiAppTests/HistoricalEditingTests -only-testing:PiAppTests/SideKeepOrderingTests -only-testing:PiAppTests/SideKeepRecoveryTests -only-testing:PiAppTests/SideRelaunchTests -only-testing:PiAppTests/SidebarSideClickTests -only-testing:PiAppTests/LaunchSelectionTests -only-testing:PiAppTests/ConversationFamilyTests -only-testing:PiAppTests/ModelSwitchTests -only-testing:PiAppTests/PendingChatProjectTests -only-testing:PiAppTests/SendImmediacyTests -only-testing:PiAppTests/ComposerSubmissionTests -only-testing:PiAppTests/ComposerImportSubmissionTests -only-testing:PiAppTests/QueuedEditPresentationTests
# integration-alone-HistoricalEditFocusTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/HistoricalEditFocusTests
# integration-queue
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QueueEditInteractionTests
# integration-reader
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentReaderTests
# integration-original
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InheritedSubagentReaderTests
# integration-opening
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentOpeningTests
# integration-conversation
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationPaneTests
# integration-lifecycle
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/LifecycleHelperTests
# integration-window
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WindowLifecycleTests
# integration-additional
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QueuedAttachmentLimitTests -only-testing:PiAppTests/SkillRefreshTests -only-testing:PiAppTests/WireContractTests -only-testing:PiAppTests/WorkspaceFollowupTests
# helper-build
swift build --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-verify --build-tests
# helper
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-verify --skip-build --skip StreamingCostTests
# helper-cost
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-verify --skip-build --filter StreamingCostTests
# wire
python3 scripts/test-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-host/arm64-apple-macosx/release/pi-native-host
# concurrent
python3 scripts/test-concurrent-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-host/arm64-apple-macosx/release/pi-native-host
# acceptance
python3 scripts/test-native-acceptance.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/swift-host/arm64-apple-macosx/release/pi-native-host
# python
python3 -m unittest discover -s scripts/tests
```

Exact final regression/fault-check commands (the failing-first and mutation exits are expected):

```sh
# failing-queue-admission
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testQueuedSaveProtectsOutputBeforePublishingCapturedInput
# fixed-queue-admission
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testQueuedSaveProtectsOutputBeforePublishingCapturedInput
# mutation-queue-admission
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests/testQueuedSaveProtectsOutputBeforePublishingCapturedInput
```

Skipped checks are explicit opt-ins/test-host limitations, not ignored failures:

- `ComposerSubmissionTests.testTheMenuBarGivesCommandReturnToSendOrSteer`: This test host has no Conversation menu
- `WireContractTests.testPerTokenSnapshotWithSeventyFinishedTurns`: Set PI_PERF_WIRE=1 to measure the per-token snapshot with 70 finished turns
- `ForkCloneTests.testWriteTheSharedForkFixture`: Set PI_WRITE_FORK_FIXTURE to the fixtures directory to write the fixture.
- `ForkPerformanceTests.testForkingAVeryLargeChat`: Set PI_PERF_FORK_MB (or PI_PERF_FORK_JOURNAL) to measure forking a large chat.
- `HistoryReadCancellationTests.testRapidSupersessionMeasurement`: Set PI_SCROLL14_PERF=1 for generated long-chat measurements
- `SessionOpenPerformanceTests.testMemoryOfOneOpenChat`: Set PI_PERF_MEMORY_JOURNAL and PI_PERF_MEMORY_MODE.
- `SessionOpenPerformanceTests.testOpeningAKeptJournal`: Set PI_PERF_OPEN_JOURNAL to a journal kept with PI_PERF_KEEP_JOURNAL.
- `SessionOpenPerformanceTests.testOpeningALongChat`: Set PI_PERF_SESSION_TURNS to measure opening a long chat.
- `SessionOpenPerformanceTests.testSlimmingAKeptJournal`: Set PI_PERF_SLIM_JOURNAL to a journal kept with PI_PERF_KEEP_JOURNAL.

All final commands exited 0. No unrelated test failure or unresolved integration
finding remains. The only red tests are the documented failing-first and
intentional mutation runs. The 1,310 source/project hashes match
`tested-source-sha256.json`; helper/script sources also match their pre-UI-run
hashes. The Release helper used by the Python suites has SHA-256
`377fcf9fbe8488222a0528e0b6c8206f0701b699792994a6a9bee3d8317aee8b`.

Final `xcodegen generate --quiet` reproduced the tested project exactly.
`git diff --check` and the staged equivalent pass. Automatic result bundles
were removed from this workstream's build root; no clone directories remained.
All owned full-lane locks were released. The lead still owns the merged full gate.


## Post-integration storage-failure review

2026-10-20, branch `dev/a130-workspace`, starting at integrated commit
`d686b22f61f09dcf323e8e1b3bc31383d8d378f9`. This round changes only desktop
workspace code and native tests. No helper/wire contract, UI layout, credentials,
capture policy, permission boundary or production path changes.

Fresh text evidence is in
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/post-integration-storage/`.
Every `.log` has its exact invocation in the matching `.command` and exit code
in `.status`. All fixtures use generated SQLite records, synthetic credentials,
scripted helpers or the packaged helper against unused loopback routes.

### Finding 1 — pinned recovery inputs and tool-output collection: confirmed and fixed

The collector inventoried durable metadata, journals, current composers and
parked edits, but omitted `DraftVersion.unsavedConflicts` and
`unsavedSubmissions`. Both arrays can outlive the failed writer's producer token.
After later typing removes a reference, an array may be its only owner.

The final inventory now includes both arrays for every retained display, before
applying the existing tombstone exclusion to its ordinary composer. Pinned input
is not an instruction to delete its referenced output, even if its own chat has
a tombstone. Candidate validation, journal/metadata consistency checks, producer
fences and the existing filesystem recycler stay unchanged. Successful
preservation transfers ownership to the durable records; explicit removal of the
last record permits collection again.

Regression tests in `ToolOutputProducerTests`:

- `testFailedConflictPreservationKeepsOutputAfterTheComposerChanges`
- `testFailedSubmissionPreservationKeepsOutputAfterTheComposerChanges`

Each fixture creates output owned by an already-deleted chat and an independent
winning draft. SQLite `BEFORE INSERT` triggers abort conflict-copy or captured-input
preservation. The tests verify that the producer has finished, no durable record
contains the reference, and the pinned input is its only owner; later typing then
removes the reference from the composer. They also retry preservation, release the
display, verify durable ownership, explicitly discard the records, and verify
reclamation.

Failing first (`failing-first.log`): both tests failed, two assertions each. The
first failure in each was:

```text
XCTAssertTrue failed - Pinned input must own its output after its producer finishes
```

The second assertion observed the same already-deleted file after successful
preservation. `fixed-regressions.log`: both pass. Separate mutations remove only
the conflict inventory line (`mutation-pinned-conflict.log`) or only the captured
submission inventory line (`mutation-pinned-submission.log`): each corresponding
test fails with the same two assertions. Both lines were restored before final
validation.

### Finding 2 — failed side-draft removal and its baseline: confirmed and fixed

`publishPendingSide` unconditionally installed an empty `DraftVersion` after an
ignored draft-removal error. Cleanup now resets the version only after
`store.remove` succeeds. On failure the saved row and the version that committed
it remain paired; the original publication error still reaches the caller.

`SideTests.testFailedSideDraftRemovalKeepsItsCommittedBaseline` holds `side.open`
after a nonempty draft has committed, injects a SQLite `BEFORE DELETE` failure,
and rejects side publication. It checks the durable and loaded draft/revision,
removes the fault, and saves new text without a conflict or recovery copy.

Failing first (`failing-first.log`): one test failed with five assertions,
including:

```text
XCTAssertEqual failed: ("nil") is not equal to ("Optional(...)") - A failed removal must not reset the loaded baseline
failed - This instance's own retained row must not cause a conflict: draftConflict
XCTAssertTrue failed - Single-instance retry must not create a recovery banner
```

`fixed-regressions.log`: passes. The mutation moves the baseline reset before
the throwing removal (`mutation-side-baseline.log`): the same test fails with
five assertions. The successful-removal control,
`testSuccessfulSideDraftRemovalResetsItsCommittedBaseline`, proves that an actual
removal still clears the loaded version and allows the next write.

### Nearby ownership gap — conflict restoration: confirmed and fixed

`restoreConflictedDraft` was the remaining recovery entry point without a
producer. Its transaction can turn pinned copies into durable records and clear
the arrays while a collector is checking ownership. It now registers
`.draftRecovery` synchronously, waits for any previously submitted recycling,
and holds the token through success/error cleanup. This is the same protection
used by interrupted-submission recovery.

`ToolOutputProducerTests.testConflictRestorationOwnsPinnedInputThroughStorageFailure`
first injects a failed conflict-copy write, removes its reference from the current
composer, and requests restoration of a different saved copy. The injected fault
also rejects restoration. It checks synchronous producer admission, preparation,
retention through failure, producer release and the eventual durable handoff.

Failing first (`failing-first-restoration.log`): one test, two assertions:

```text
XCTAssertTrue failed - Conflict restoration must register before its pinned references can move to durable storage
XCTAssertTrue failed - Restoration must also wait for any previously submitted recycling
```

`fixed-sweep.log`: passes. Removing this method's registration, preparation and
deferred release (`mutation-restoration.log`) produces the same two failures.
All three lines were restored before final validation.

### Cross-feature invariant sweep

Ownership checks:

| Holder / transition | Checked ownership and failure behavior |
| --- | --- |
| Pinned conflict snapshots and captured inputs | Both arrays are inventoried after producer release. New injected-failure tests cover each, durable retry, display removal and final discard. |
| Ordinary Send, Steer and side first Send | `.submission` is admitted before clearing the composer; it spans materialization, the independent `recordSubmission` task, dispatch and failed-send recovery. Side publication also holds `.sidePublication`. `SubmissionPersistenceTests` covers typing during all these waits. |
| Historical Resend and queued-message Save | `.messageEdit` / `.queuedEdit` register before their asynchronous captured-input write. New typing can supersede only the composer snapshot. The separate non-conflict persistence-failure follow-up below is outside the collector/baseline fixes. |
| Current, historical-edit displaced and queue-edit parked drafts | The final display inventory covers `savedDraft`, `draftBeforeEdit` and `draftBeforeQueueEdit`; metadata scanning includes nested parked drafts. Debounces/flushes hold `.draftWrite` / `.draftFlush` until completion. Existing displaced/queued producer tests cover display removal during the write. |
| Asynchronous side transfer | `.sideDraft` registers before consuming the source and remains until the destination commits or the source is restored. The new `testFailedSideTransferReturnsOutputOwnershipToItsComposerAndParkedDraft` injects a destination write failure for both a normal composer and a queued edit's parked draft. Collection is checked while transfer is suspended, after failure returns input, after a successful retry and after explicit discard. |
| Synchronous side transfer and helper-loss re-parking | `moveSideDraftHere`/`absorb` publish the parent holder before consuming the source, without suspension. `discardLostSides` transfers or re-parks the input synchronously and skips unsaved-conflict displays. Existing side/race/deletion classes cover these paths. |
| Recovery and explicit restoration | `recoverDraft` already holds `.draftRecovery`; `restoreConflictedDraft` now does too. Their storage transactions preserve input before consuming its previous durable record. Failed restoration retains the pins and live composer. |
| Keep/fork/registration, handoff, import/export | Existing producer registrations cover local captures through publication; an editable side-handoff holds its token for the editor lifetime, and export cancellation retains its reader until it returns. The full producer class exercises every producer's first suspension and already-submitted recycling. |
| Display release | Eviction, side replacement/close, helper loss and family deletion retain unsaved-conflict displays; quit/update flush/transfer paths refuse failed preservation. Durable copies remain discoverable after display release. Existing conflict, side, race and deletion tests were rerun. |

Baseline checks:

- Enumerated every assignment to `draftVersion` and `anchorVersion`: default
  construction for a new display; adoption only after successful initial metadata
  reads; the corrected side cleanup; and parent adoption only after a successful
  side-transfer write. Initial-read failure never marks metadata loaded.
- `putDraft`, `recordSubmission`, `withdrawSubmission`, submission-review writes,
  conflict restoration and kept-side registration stage version updates inside
  the store transaction. `transaction` applies them only after `COMMIT`; failure
  drops staged updates before rollback/recovery. Conflict snapshots/submissions
  clear only after their preservation transaction commits.
- `putAnchor` changes `AnchorVersion` only after its anchor/tombstone transaction
  returns successfully. Failed writes and clears leave the loaded version intact;
  a CAS mismatch does not adopt another instance's position as our own write.
- Failed anchor debounces and failed ordinary/returned-input draft writes do not
  reset their baseline. The next explicit save/flush still compares against the
  last successfully loaded or committed revision. No new revision is treated as
  durable merely because it was reserved.
- `DraftConcurrencyTests.testStorageFailuresLeaveDraftBaselinesAtTheDurableRevision`
  injects failures in six paths: snapshot, submission, withdrawal, review marker,
  conflict restore and side registration. For compound writes the fault is after
  the draft write, before its transaction completes. It verifies the durable row,
  loaded revision/content, retained input/conflict/keep records and retry after
  removing the fault.
- `testStorageFailuresLeaveAnchorBaselinesAtTheDurableRevision` fails the DELETE
  following the INSERT in both writing a new position over a tombstone and
  clearing a position. Both database rows roll back, the loaded baseline stays
  unchanged, and retry advances it correctly.

The first sweep-test attempt (`sweep-empty-review-fixture.log`) had two failed
assertions in the new review-marker case: its empty draft correctly owned no
review-marker write, so the injected trigger never fired. The fixture was corrected
to start with nonempty saved input; no product change was made for that test issue.
The other 11 classes passed in that exploratory run. Final counts exclude it.

### Separate finding for the lead — initial captured-edit storage failure

**Confirmed, recorded rather than fixed under the shared scope rule.** This is
loss of the captured holder itself, distinct from the assigned collector omitting
an existing pinned holder or cleanup corrupting a loaded baseline.

- `MetadataStore.swift:1053–1075`: `recordSubmission` pins an independent captured
  intent only on `draftConflict`. A normal `pending:<chat>` INSERT failure rolls
  back without pinning that input.
- `WorkspaceEditing.swift:190,264`: if typing superseded the captured editor
  snapshot before that write, the pre-dispatch error path leaves only the newer
  editor text; it does not retain the captured replacement elsewhere.
- `QueuePanel.swift:380–387`: queued Save has the same result on its initial local
  persistence failure while newer typing has replaced the captured text.

A temporary diagnostic test in `SubmissionPersistenceTests` exercised both
`turn.edit` and `queue.edit.save` with generated fixtures. It held the metadata
actor, accepted the captured replacement, typed different text, and released the
actor with a SQLite trigger aborting `pending:%` inserts. Neither operation was
dispatched. After all producers finished, the captured text was absent from the
live draft, durable draft, durable pending/conflict records and both pinned arrays.
`diagnostic-captured-edit.log` reports one diagnostic test with two failures:

```text
XCTAssertTrue failed - turn.edit lost captured input after a non-conflict storage failure
XCTAssertTrue failed - queue.edit.save lost captured input after a non-conflict storage failure
```

The exact test body and reversible insertion runner remain in the evidence folder
as `diagnostic-captured-edit.swift` and `diagnostic.py`. The original test file was
restored byte-for-byte afterward; the failing diagnostic is not in the committed
suite and is excluded from final passing counts. A follow-up should retain this
input independently on initial persistence failure, without treating a same-instance
storage error as a cross-instance conflict or allowing debounces to overwrite it.

### Adversarial self-review

Every changed branch and asynchronous boundary was reviewed against both sides
of the merge:

- Collector: a display with no pins contributes exactly its prior ordinary/parked
  references. A display with pins now keeps only matching validated candidates.
  A tombstoned display still does not retain its ordinary composer, but its
  uncommitted recovery input remains an owner. Successful preservation moves that
  ownership into the existing all-records metadata scan; removal of the final
  record allows recycling. There is no new filesystem authority or path parsing.
- Side cleanup: an unpublished side whose draft removal succeeds still gets an
  empty version; a failed removal keeps its old version. Published sides
  (`written == true`) continue retaining their journal/recovery state. Failures
  before this publication catch continue following their original recovery path.
  No failure installs a nil revision over a durable draft.
- Conflict restoration: existing eligibility/paused-queue behavior is unchanged.
  New admission happens before queuing the task, so a concurrent sweep defers.
  An already-submitted recycler finishes before restoration touches its inputs.
  The token is held while waiting for the previous debounce and through commit or
  error cleanup. Deferred `draftChanged` registers any following writer before
  this token is released; storage/cancellation errors still clear the busy flags.
- Collection cannot observe a gap when restoration drains the pin arrays into
  SQLite: the new producer spans that whole transaction. Side transfers likewise
  restore their source before releasing their producer when persistence fails.
- Mutation runs were followed by restoring the production fixes. Final source
  hashes are recorded in `tested-source-sha256.json`; docs do not alter those
  sources. The lead retains merge and full-gate ownership.


### Fresh validation commands

Focused failing-first and fixed regressions (the exact same selectors in both runs):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ToolOutputProducerTests/testFailedConflictPreservationKeepsOutputAfterTheComposerChanges \
  -only-testing:PiAppTests/ToolOutputProducerTests/testFailedSubmissionPreservationKeepsOutputAfterTheComposerChanges \
  -only-testing:PiAppTests/SideTests/testFailedSideDraftRemovalKeepsItsCommittedBaseline

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ToolOutputProducerTests/testConflictRestorationOwnsPinnedInputThroughStorageFailure
```

Each mutation uses the corresponding single selector above and the same
`PI_BUILD_ROOT`, script and `-parallel-testing-enabled NO` arguments. The
`fixed-sweep.command` additionally runs the restoration test,
`ToolOutputProducerTests/testFailedSideTransferReturnsOutputOwnershipToItsComposerAndParkedDraft`,
`DraftConcurrencyTests/testStorageFailuresLeaveDraftBaselinesAtTheDurableRevision`
and `DraftConcurrencyTests/testStorageFailuresLeaveAnchorBaselinesAtTheDurableRevision`.
All four pass, including six draft-operation and two anchor-operation fault cases.

Final full affected classes, after all mutations were restored:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/DraftConcurrencyTests \
  -only-testing:PiAppTests/DraftOrderingTests \
  -only-testing:PiAppTests/DraftLoadingTests \
  -only-testing:PiAppTests/MetadataDurabilityTests \
  -only-testing:PiAppTests/SubmissionPersistenceTests \
  -only-testing:PiAppTests/SideTests \
  -only-testing:PiAppTests/WorkspaceDurabilityTests \
  -only-testing:PiAppTests/WorkspaceDisplayMemoryTests \
  -only-testing:PiAppTests/WorkspaceRaceTests \
  -only-testing:PiAppTests/RecoveredDraftTests \
  -only-testing:PiAppTests/SubagentDeletionTests \
  -only-testing:PiAppTests/FamilyDeletionTests

# This second run holds the shared full-lane lock for its entire run.
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ToolOutputProducerTests \
  -only-testing:PiAppTests/SideKeepOrderingTests \
  -only-testing:PiAppTests/SideKeepRecoveryTests \
  -only-testing:PiAppTests/SideRelaunchTests
```

`run.py` in the evidence folder records commands/status, serializes this
workstream's build root, and releases only the full-lane lock it acquired in a
`finally` block. The headless focused runs use the documented lock exemption;
the full window-based classes run under the shared lock. No named result bundles,
installed app, live services, real credentials or user data are used.

### Final results

`final-headless.log`: **217 passed**. `final-window.log`: **42 passed**.
Total: **259 passed, 0 skipped, 0 failures**, across 16 complete native classes.

| Class | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| `DraftConcurrencyTests` | 36 | 0 | 0 |
| `DraftLoadingTests` | 15 | 0 | 0 |
| `DraftOrderingTests` | 17 | 0 | 0 |
| `FamilyDeletionTests` | 10 | 0 | 0 |
| `MetadataDurabilityTests` | 10 | 0 | 0 |
| `RecoveredDraftTests` | 13 | 0 | 0 |
| `SideKeepOrderingTests` | 12 | 0 | 0 |
| `SideKeepRecoveryTests` | 15 | 0 | 0 |
| `SideRelaunchTests` | 3 | 0 | 0 |
| `SideTests` | 17 | 0 | 0 |
| `SubagentDeletionTests` | 19 | 0 | 0 |
| `SubmissionPersistenceTests` | 11 | 0 | 0 |
| `ToolOutputProducerTests` | 12 | 0 | 0 |
| `WorkspaceDisplayMemoryTests` | 2 | 0 | 0 |
| `WorkspaceDurabilityTests` | 9 | 0 | 0 |
| `WorkspaceRaceTests` | 58 | 0 | 0 |

Both assigned findings and the nearby conflict-restoration ownership gap are
fixed. Four intentional mutation runs each failed their targeted regression;
all fixes were restored for the final runs. The separate captured-edit diagnostic
above remains a confirmed follow-up for the lead, not a passing-suite claim.
There were no unrelated failures in the final runs.

No helper or wire implementation changed, so helper/wire/concurrent/acceptance
suites were not repeated for this app-only round. No UI geometry changed.
`xcodegen generate --quiet` reproduced the tested project; all 936 source/project
hashes match `tested-source-sha256.json`, and `git diff --check` passes. Automatic
result bundles were removed from this workstream's build root, no cloned test
apps remained, and its owned full-lane lock was released. No branch other than
`dev/a130-workspace` is committed or pushed by this round.


## Round 12 — retained input through storage failures

Branch: `dev/a130-workspace`, continuing from `0aa9e6c1`. No merge/rebase or
helper/wire change in this round. All fixtures use generated desktop databases,
journals, text and credentials, memory vaults, and fake in-process host transports.
No installed app, real preferences/chats/Keychain, capture, or paid provider calls.

Evidence root:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round12-captured-input/`.
Every native run uses this workstream's build root. `run.py` records the exact
command, full text log and exit status; window and gallery runs take/release the
shared full-lane lock. Serial-lane classes run alone. Automatic Xcode result
bundles are not the evidence and are removed after validation.

### Findings and failing-first evidence

**P1 — queued rewrite storage failure: confirmed and fixed.** The recorded
round-11 follow-up was real for historical Resend too. Captured input now enters
`DraftVersion.unsavedSubmissions` synchronously at capture, before metadata or
producer awaits. `recordSubmission` also pins before BEGIN/read/write/commit can
fail. Its independent `pending:<chat>` record owns the input after commit; only
then does the pin clear. No subsequent typing/episode write replaces that input.

`SubmissionPersistenceTests.testStorageFailureKeepsEveryCapturedSubmissionRecoverableInPlace`,
`testDraftWriteFailureKeepsEveryCapturedSubmissionRecoverableInPlace`, and
`testSideIntentAndNewChatWriteFailuresRetainCapturedInput` failed first on all
12 scenarios (3 tests, 24 assertions, `failing-first-storage.log`). The queued
and historical edits lost the captured text; ordinary sends could still restore
text into their composer but lacked the independent failure pin/recovery action
required here:


```text
XCTAssertTrue failed - queue.edit.save/pending:% lost captured input or hid its recovery
XCTAssertNotNil failed - turn.edit/pending:% must offer recovery without reopening
XCTAssertTrue failed - side/side-keep lost captured input or hid its recovery
```

**P2 — retained rejected input hidden by uncertainty: confirmed and fixed.**
`ConversationPaneTests.testRejectedInputRecoveryStaysVisibleAfterCancellingAnEdit`
failed first with five assertions (`failing-first-recovery-ui.log`):

```text
XCTAssertFalse failed - Retained input does not require uncertain execution
XCTAssertFalse failed - Cancel Edit must leave recovery reachable in place
XCTAssertFalse failed - Running work must not hide retained input
```

Recovery visibility now depends on retained submissions/conflict copies, with
sub-agent readers still excluded. The existing one-row chooser remains present
through running work and editing; Insert still checks send/edit ownership before
replacing the composer, and becomes usable in place after Cancel. Undurable input
is labelled “retained”, not “saved”. Execution uncertainty and acceptance checks
remain separate; a known accepted command is never offered for replay.

### Capture records and storage-failure coverage

| Capture | Owner before durability | Durable record / dispatch |
| --- | --- | --- |
| Send, including refused connection preparation | Immutable `Submission.intent` and version pin | `pending:<chat>/<commandID>` / `turn.submit` only after persistence |
| Steer | Same independent input and pin | `pending:<chat>/<commandID>` / `turn.steer` |
| Historical Resend | Immutable intent and pin; replaceable editor snapshot separately ordered | `pending:<chat>/<commandID>` / `turn.edit` |
| Queued-message Save | Immutable intent and pin; newer rewrite remains editable | `pending:<chat>/queue-edit:<editID>:<digest>` / `queue.edit.save` |
| Side first send | Immutable first-send intent and pin before even `side-keep` | `pending:<side>/<commandID>` plus the existing side-keep/registration path / `turn.submit` |

The regression matrix exercises all five captures with newer typing during a held
metadata operation and injects:

- unavailable metadata before any write;
- an external SQLite write lock, causing transaction start/write acquisition to
  fail rather than accepting a command without a durable input;
- failed draft INSERT (including rollback of submission-review state);
- failed independent pending-input INSERT;
- rollback immediately after that INSERT, before successful transaction commit;
- failed recovery draft INSERT, then retry;
- failed post-acceptance acknowledgement UPDATE (pending DELETE for queued Save):
  the durable input remains but is not offered as an unaccepted duplicate.

Additional first-send tests fail new-chat materialization, side-keep INSERT, each
side-registration operation (chat INSERT, draft INSERT, side-keep DELETE and
registration-receipt INSERT), and recovery's pending DELETE (Insert and Dismiss,
for every capture kind). Explicit Dismiss is also tested for every capture kind: its pin and pending record stay gone after a
preservation retry. No test automatically retries a provider command.

The `draft` failure cases deliberately keep the admitted snapshot ticket while
changing live composer text, so the failing draft write actually executes. The
pending INSERT/rollback cases also call `draftChanged` and supersede the old
snapshot: that cancellation must never cancel the captured input. Existing
round-9 typing-during-write tests remain in the full class run.

### Nearby sweep and release ownership

- **Side transfer after failed first keep INSERT — confirmed and fixed.** A later
  preservation could save `pending:<side>` without any chat/keep record through
  which to find it after the side disappeared. New
  `testSideTransferCannotOrphanInputCapturedBeforeItsKeepIntentCouldBeSaved`
  failed first twice (`failing-first-side-release.log`). Transfer now keeps that
  side pinned and asks the reader to restore or dismiss its retained submission
  in place before closure/quit/update can release it. Restoration then transfers
  the complete draft to the parent and flushes it durably. No fabricated saved
  side or journal is created to bypass the side-draft policy.
- **Retired recovery/cache entries — confirmed and fixed.** With recovery visible
  independently of uncertainty, a definitively rejected input successfully moved
  back into its durable draft must also leave the recovery array and invalidate
  the pending-input cache. `testDefiniteRejectionRetiresVisibleRecoveryOnlyAfterItsDraftCommits`
  failed first three times across Send and Resend
  (`failing-first-retired-recovery.log`). Retirement now follows commit, and
  failure preserves the independent input instead.
- **Connection refusal plus failed chat creation — confirmed and fixed.** Capture
  formerly depended on a valid connection even though asynchronous materialization
  could fail after typing replaced that text. The new
  `testConnectionRefusalDoesNotDropCapturedInputWhenMaterializationFails` failed
  first three times (`failing-first-refused-storage.log`). Connection refusal still
  dispatches nothing; unchanged input can settle into its durable draft, whereas
  changed input or failed storage retains the captured copy independently.
- **Hydration and side-transfer baseline replacement:** `SessionDisplay` carries
  pinned submissions into a replacement `DraftVersion`. A baseline is not an input
  owner. Reconciliation and snapshot inventories union durable pending records
  with pins; missing durable records cannot hide them. Known undurable input does
  not assert execution uncertainty.
- **Debounce/direct writes:** submission-only pins no longer trigger a composer
  conflict. Real conflict copies still use the same loaded-revision CAS, ordering,
  and episode rules. Quit/update flush preserves pins before saving snapshots.
- **Display eviction/chat switch:** the existing `hasUnsavedDraft` and
  `hasUnsavedConflict` release guards now see the capture pin immediately, including
  before the metadata actor starts. Neither direct placeholder discard nor Delete
  can remove it. Busy Delete retains the Stop-work notice; idle retained input is
  identified as recovery input, not a fictitious cross-instance conflict.
- **Side close/sibling replacement/helper loss:** the existing pin guards retain
  the display; side transfer additionally refuses the orphan-input case above.
- **Family deletion and collection:** existing pin guards still prevent release;
  round-11's collector inventories `unsavedSubmissions` and `unsavedConflicts`, and
  the producer remains registered through capture, persistence and failed-input
  settlement. Ordinary/parked/displaced drafts and transfers retain their existing
  ownership. Tool-output/deletion classes are included in the final runs.
- **Recovery:** Insert/Dismiss clears the pin only after its atomic withdrawal
  commits. A failed withdrawal keeps both input and UI. New-chat recovery first
  materializes its owner so it cannot save an orphan draft. Cancellation of an
  active historical/queued edit changes only that editor/parked draft, never the
  independent captured input. Explicit acceptance, restored input, or successful
  Dismiss retires recovery; storage failure does not.

### Validation notes before final runs

The first broad run (`fixed-matrix.log`) found an old test fixture expectation:
`testFailedSubmissionTransactionDoesNotAdvanceTheDraftVersion` intentionally
creates an input larger than the metadata record limit. That input now correctly
stays pinned, so flush refuses it. The test now verifies its pin, explicitly
discards that invalid synthetic input, and retries the baseline write; app entry
points already reject oversized input before capture. The other 96 tests passed.

The first expanded class run (`final-headless.log`) had 269 passing tests and four
assertions in two race tests. Delete's work notice now precedes the pin notice.
The old direct-discard test expected removal during first-send materialization;
that is now forbidden by the capture rule, so it was renamed to
`testDirectDiscardRefusesCapturedFirstSendBeforeItsRecordCommits` and verifies
that the same display/chat remains, becomes durable, and submits once. The
separate removed-placeholder/no-input materialization test remains unchanged.
Final passing counts below exclude those exploratory runs.

### Final validation and adversarial review

**466 distinct native tests passed across 28 classes; zero failures or skips.**
`SubmissionPersistenceTests` was repeated after extending every capture's failed
Insert/Dismiss retirement coverage (`final-submissions.log`, 24/24); it is counted
once here. Exploratory/failing-first/mutation runs are excluded.

| Class | Passed | Final log |
| --- | ---: | --- |
| `ConversationPaneTests` | 84 | `final-conversation.log` |
| `DraftConcurrencyTests` | 36 | `final-headless-rerun.log` |
| `DraftLoadingTests` | 15 | `final-headless-rerun.log` |
| `DraftOrderingTests` | 17 | `final-headless-rerun.log` |
| `FamilyDeletionTests` | 10 | `final-headless-rerun.log` |
| `HistoricalEditBookkeepingTests` | 2 | `final-headless-rerun.log` |
| `HistoricalEditFocusTests` | 1 | `final-window.log` |
| `HistoricalEditingTests` | 5 | `final-window.log` |
| `LifecycleHelperTests` | 11 | `final-lifecycle.log` |
| `MetadataDurabilityTests` | 10 | `final-headless-rerun.log` |
| `PendingChatProjectTests` | 24 | `final-headless-rerun.log` |
| `QueueEditInteractionTests` | 17 | `final-queue.log` |
| `QueuedEditPresentationTests` | 9 | `final-headless-rerun.log` |
| `RecoveredDraftTests` | 13 | `final-headless-rerun.log` |
| `RunHoldTests` | 18 | `final-headless-rerun.log` |
| `SendBookkeepingTests` | 12 | `final-headless-rerun.log` |
| `SessionOrganizationTests` | 9 | `final-headless-rerun.log` |
| `SideKeepOrderingTests` | 12 | `final-window.log` |
| `SideKeepRecoveryTests` | 15 | `final-window.log` |
| `SideRelaunchTests` | 3 | `final-window.log` |
| `SideTests` | 17 | `final-headless-rerun.log` |
| `SubagentDeletionTests` | 19 | `final-headless-rerun.log` |
| `SubmissionPersistenceTests` | 24 | `final-submissions.log` |
| `ToolOutputProducerTests` | 12 | `final-window.log` |
| `WorkspaceDisplayMemoryTests` | 2 | `final-headless-rerun.log` |
| `WorkspaceDurabilityTests` | 9 | `final-headless-rerun.log` |
| `WorkspaceRaceTests` | 58 | `final-headless-rerun.log` |
| `WorkspaceValidationGalleryTests` | 2 | `final-gallery.log` |

Exact final commands (each also saved in the matching `.command` file):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubmissionPersistenceTests \
  -only-testing:PiAppTests/DraftConcurrencyTests \
  -only-testing:PiAppTests/DraftLoadingTests \
  -only-testing:PiAppTests/DraftOrderingTests \
  -only-testing:PiAppTests/RecoveredDraftTests \
  -only-testing:PiAppTests/MetadataDurabilityTests \
  -only-testing:PiAppTests/WorkspaceDurabilityTests \
  -only-testing:PiAppTests/WorkspaceRaceTests \
  -only-testing:PiAppTests/WorkspaceDisplayMemoryTests \
  -only-testing:PiAppTests/SideTests \
  -only-testing:PiAppTests/SubagentDeletionTests \
  -only-testing:PiAppTests/FamilyDeletionTests \
  -only-testing:PiAppTests/SendBookkeepingTests \
  -only-testing:PiAppTests/HistoricalEditBookkeepingTests \
  -only-testing:PiAppTests/QueuedEditPresentationTests \
  -only-testing:PiAppTests/RunHoldTests \
  -only-testing:PiAppTests/PendingChatProjectTests \
  -only-testing:PiAppTests/SessionOrganizationTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubmissionPersistenceTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SideKeepOrderingTests \
  -only-testing:PiAppTests/SideKeepRecoveryTests \
  -only-testing:PiAppTests/SideRelaunchTests \
  -only-testing:PiAppTests/ToolOutputProducerTests \
  -only-testing:PiAppTests/HistoricalEditingTests \
  -only-testing:PiAppTests/HistoricalEditFocusTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/QueueEditInteractionTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/LifecycleHelperTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConversationPaneTests
```

```sh
TEST_RUNNER_PI_APP_WORKSPACE_VALIDATION_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round12-captured-input/gallery PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceValidationGalleryTests
```

Mutation checks: each temporarily broke the named fix, failed its targeted
regression, and was restored before the final class runs. All eight exit 65
results below are assertion failures, not build failures. The UI and refused-
connection mutants additionally have adjacent fixed/restored targeted passes.

| Evidence log | Tests | Expected failed assertions |
| --- | ---: | ---: |
| `mutation-baseline-pin.log` | 1 | 12 |
| `mutation-captured-pin.log` | 1 | 12 |
| `mutation-flush-pin.log` | 1 | 9 |
| `mutation-recovery-ui.log` | 1 | 5 |
| `mutation-refused-capture.log` | 1 | 3 |
| `mutation-retired-recovery.log` | 1 | 1 |
| `mutation-side-release.log` | 1 | 2 |
| `mutation-submission-is-not-conflict.log` | 1 | 4 |

`mutations.py` and `final-mutations.py` contain the exact reversible mutations
and selectors. They serialize the worktree/build root and restore source in
`finally` blocks. `tested-source-sha256.json` records the final 936 Swift/project
files after every mutation was restored. `git diff --check` passes.

Gallery: `final-gallery.log`, 2/2 tests, 28 generated PNGs under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round12-captured-input/gallery`.
Inspected all eight new `retained-{unsaved,rejected}-{light,dark}-{300,760}.png`
scenes and all eight `conflict-recovery-{1,40}-{light,dark}-{300,760}.png`
scenes. The retained/saved labels are truthful, the 56-point recovery row
fits at both widths, and transcript space is preserved. No shape/layout
geometry changed. The twelve existing error-banner scenes were regenerated
by the same class as well. All focus-changing checks held the shared lock.

Our locks were released, and our automatic result bundle/test clone cleanup
completed. Evidence is the text logs and PNGs; no named xcresult was created.


Adversarial review of every changed condition and ownership transition:

- `putDraft` ignores submission-only pins for conflict detection and unchanged
  draft comparisons. Real pinned conflict copies and mismatching loaded revisions
  still take the conflict path; superseded snapshots are still rejected by the
  ordered writer before this code. Capture pins cannot manufacture single-instance
  conflicts or force an unchanged stale composer over another instance's draft.
- Admission pins every captured input, including connection-refused preparation.
  A refused connection with unchanged input retires it only through a successful
  durable draft transaction. New typing, stale tickets, materialization failure,
  or any storage error leaves the independent captured input. No connection refusal
  starts helper work or changes its lease/capture/tool permissions.
- `recordSubmission` clears pins only after transaction success. BEGIN/read/write/
  rollback errors keep them; a real draft conflict still attempts durable
  preservation in the transaction's existing rollback handler. Withdrawal clears
  its pin after commit, never on failure or supersession.
- Resend settles a definite rejection into its draft only if the complete current
  text/images/skills still match and no failed-persistence pin remains. Otherwise
  the captured intent is offered independently. Successful retirement removes only
  that command and invalidates the pending cache; failed retirement repins it.
- Queued Save's final recovery publication covers initial persistence errors,
  definite rejection and unresolved outcomes. It excludes known acceptance;
  newer typing and cancelling the active editor do not consume captured input.
  Repeating the same edit/text keeps the same record ID; different text remains a
  separate capture. Cancel/Remove without new text create no capture pin.
- Baseline replacement carries pins forward without changing the loaded draft
  revision. Inventories deduplicate pins against durable IDs, preserve acceptance
  filtering, and never infer execution uncertainty from undurable input alone.
- Flush commits retained input before it can release a normal display. Pending
  chats get an owner first. An unsaved side is conservatively held for in-place
  recovery/dismissal rather than creating an unreachable pending record. Ordinary
  side transfers, actual conflict-copy preservation, parked input and successfully
  registered sides retain their prior behavior.
- Delete checks active work before explaining a retained pin, so active sends
  keep the Stop-work message. Idle captured input gets a recovery message; actual
  conflicting drafts keep their conflict message. Every destructive release guard
  still sees the pin. Direct placeholder discard cannot bypass it.
- Recovery visibility no longer depends on `uncertain` or busy work. Sub-agent
  readers remain excluded, and Insert retains its loading/edit/acceptance and
  size-limit checks. The row stays 56 points high. A pin is never described as a
  saved copy. Recovery failure leaves the input and actions intact; no automatic
  dispatch or new prompt was introduced.
- Known helper acceptance remains authoritative even if local acknowledgement
  fails. Captured input has already committed before any dispatch; acceptance
  guards and durable journal/digest reconciliation still prevent duplicate recovery.

No helper/wire source, protocol, live-provider behavior, permission, capture,
vault or data boundary was changed; helper and Python wire suites are therefore
not rerun for this app-only round. No unresolved finding or owner decision from
this round. If storage remains unavailable, retained input stays pinned and
quit/update refuses to discard it.


## Round 13 — captured input ownership and reachable side recovery

Reviewed base: `2fea5b95dcc1203255c9cc77ff2d60746320f1dd` on
`dev/a130-workspace`. Work remains in the assigned worktree and build root;
no merge, rebase or history rewrite. Read the round-13 shared rules,
`AGENTS.md`, `NEXT-RELEASE.md` and the side/reader/lifecycle design policies.
All storage, helper and image fixtures are generated; no live provider,
credentials, user data, preferences or installed app are used.

Evidence directory:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round13-input-ownership/`.
Every test run has its exact `.command`, text `.log` and exit `.status` there.
`run.py` serializes this worktree's build root; window/gallery runs also acquire
and release the shared full-lane lock. Serial classes run alone.

### Findings and failing-first evidence

All four findings are confirmed. The initial unchanged-production run
`failing-first.log` executed four tests with 15 expected assertion failures,
exit 65; no build failure. The tests exercise real desktop SQLite records,
independent store baselines and generated helper replies.

1. **Persisted side input after failed publication — confirmed and fixed.**
   `testFailedSidePublicationTransfersPersistedInputToParentRecovery` rejects
   `side.open`, replaces the returned composer, then exercises Close and the
   quit/update side-transfer path. Before the fix the parent inventory and
   recovery chooser are empty, `pending:<side>` remains orphaned, and an
   independent reopened store cannot recover the input via the parent.
   The source input now moves to `pending:<parent>` in one transaction; its
   immutable command ID, text, images and skills are retained and only its
   recovery owner changes. The current composer still follows the existing
   side-draft merge policy. Nothing is resent.
2. **Withdrawal of an unchanged stale baseline — confirmed and fixed.**
   `testWithdrawalCannotConsumeInputFromAnUnchangedButStaleDraft` loads a
   draft, captures the same text, commits a different draft through a second
   store, then withdraws the first input. Before: withdrawal succeeds, the
   pin disappears and `hasUnsavedDraft` is false. Now withdrawal verifies the
   actual durable draft's complete normalized contents inside the same
   `BEGIN IMMEDIATE` transaction before removing the independent input or
   its pin. Ordinary unchanged/stale flushes still perform no write. A
   mismatching durable row returns `staleRevision`, without inventing a
   composer conflict or modifying either instance's durable baseline.
3. **Preservation and an empty pending cache — confirmed and fixed.**
   `testPreservationInvalidatesAnEmptyPendingSnapshotCache` first delivers a
   real snapshot with an empty durable inventory and a visible memory pin,
   then preserves through both `flushDrafts` and `restoreConflict`, then
   delivers another snapshot. Before: both cases replace visible recovery
   with an empty list. A thread-safe generation on `DraftVersion` now advances
   when a committed operation releases an input pin. The snapshot cache keys
   and post-await validation include that generation and baseline identity;
   replacing the baseline also clears the cached inventory. This includes
   transaction-conflict preservation, explicit preservation retries,
   conflict restoration, initial recording and withdrawal; rollback never
   advances it. The existing `pendingIntentRevision` still handles ordinary
   record/receipt changes.
4. **Live input exposed as recovery — confirmed and fixed.**
   `testStreamingSnapshotsNeverOfferLiveSteersOrFollowupsForRecovery` holds
   dispatch replies after durable recording while a chat streams and delivers
   a snapshot. Before: both sends appear as recoverable. A display now tracks
   each captured command's live task separately from its durable record.
   Hydration/snapshot inventories and pane/menu presentation exclude live
   IDs; Insert and Dismiss recheck ownership before admission and after
   suspension. A settled failure is offered when its task releases ownership,
   including failure bookkeeping that itself suspends. Accepted input never
   becomes recoverable, even when acknowledgement storage fails.

Failing-first output excerpts (full records are in `failing-first.log`):

```text
testFailedSidePublicationTransfersPersistedInputToParentRecovery:
  XCTAssertEqual failed: ("[]") is not equal to ("[\"First side input\"]")
  XCTAssertTrue failed - No unresolved input may remain under an unregistered side
testWithdrawalCannotConsumeInputFromAnUnchangedButStaleDraft:
  failed - An unchanged loaded snapshot is not proof that durable storage holds the input
  XCTAssertTrue failed - Eviction must retain input absent from the current durable draft
testPreservationInvalidatesAnEmptyPendingSnapshotCache:
  XCTAssertEqual failed: ("[]") ... A preservation commit must retire the cached empty inventory
testStreamingSnapshotsNeverOfferLiveSteersOrFollowupsForRecovery:
  XCTAssertTrue failed - A snapshot cannot turn live input into recovery
```

The first fixed run (`fixed-first.log`) passed all 45 tests in the then-current
`SubmissionPersistenceTests` and `SideTests`. The initial expanded headless run
(`final-headless.log`) passed 311 tests; the first restored run adds the two
side self-review cases and passes 313. The next run covers side recovery/close
ordering and passes 314; the final `final-headless-owned.log` also includes
live queued-Save eviction and passes 315. Mutation selectors and assertion
counts are recorded with the final validation below.

### Ownership and nearby sweep

| Captured input | Durable record | Live owner / settlement |
| --- | --- | --- |
| Send / follow-up | `pending:<chat>/<commandID>` | `send` task, through acceptance or failure bookkeeping |
| Steer | Same independent command record | Same task ownership while the original run streams |
| Historical Resend | Same independent command record; separate replaceable editor/review snapshot | `sendEdit` task |
| Queued Save | `pending:<chat>/queue-edit:<editID>:<textDigest>` | `resolveQueuedEdit` task, including repeat-save/status reconciliation |
| Side first send | `pending:<side>/<commandID>` until registration or parent transfer | `send` task also covers side publication |

Pins protect storage failures from capture onward. A task's terminal failure
can await further bookkeeping: `settlingSubmissions` retains its recovery
offer across intervening snapshots until the task finishes. This contains the
same immutable input already owned by a pin or independent durable record;
it never replaces either owner. Older failed input remains recoverable while
unrelated work streams. A retry of the same queued input hides only that
command's recovery actions. Mere queued/paused work does not acquire live
ownership and does not prevent draft restoration.

Side release paths checked: immediate close/replacement, asynchronous close,
quit, update, helper-loss discard, missing-journal keep reconciliation after
relaunch. Immediate release refuses retained or live input; asynchronous
transfer saves the independent records under the saved parent before release.
Failed transfer leaves the source records/pins, composer and pane available.
The helper-loss path leaves such a pane reachable instead of discarding it.
A failed `side.open` keeps its durable parent link until transfer; relaunch
with no live display and no side journal recovers the input via that parent,
without creating a saved side or starting a helper. Existing journal-backed
keep registration remains its own path.

Additional regressions cover every capture kind during held dispatch;
Insert/Dismiss with deliberately stale menu data and other UI guards cleared;
side transfer failures at destination insert, source delete, link delete and
transaction rollback; missing-journal relaunch; and pinned tool-output
references through failed transfer, successful parent recovery and display
release. The round-12 storage-failure and rejected-Resend cases remain required.

### Additional ordering check — side Close versus admitted recovery

`testSideCloseWaitsForAnAdmittedDismissalBeforeTransferringInput` holds a
Dismiss at its producer barrier and then closes the failed side. Before the
ordering fix, Close completes and migrates the input; the admitted Dismiss
then has nothing left in its source display to act on, so the parent offers
input the user had chosen to discard. `failing-side-recovery-order.log` has
two expected assertion failures. The restored focused check passes;
`mutation-side-recovery-order.log` fails again when the wait before setting
`loading` is removed. Waiting only inside the transfer would be too late:
`loading` would itself refuse the admitted recovery action.

Asynchronous Close now drains the side's admitted recovery before setting
`loading`; immediate release refuses it, and the shared quit/update transfer
also drains it before moving records or composer state. This is the same
per-side release path, with no new prompt or recovery behavior.

### Additional ownership check — live queued Save and display eviction

`testLiveQueuedSaveKeepsItsDisplayAfterItsInputBecomesDurable` holds a queued
Save after its independent input record commits, then navigates above the
8-display limit. A held queued edit can have no running work, no loading flag
and no dirty draft: its captured snapshot is already saved. Before the fix,
its display is evicted, which would let a new display hydrate the still-live
input as recovery without knowing its task. `failing-live-eviction.log` fails
one assertion; the fixed check passes and `mutation-live-eviction.log` fails
the same assertion when the new release guard is removed.

The eviction predicate now also requires no live captured submissions. This
pins the task's display until settlement without changing `hasWork`, Stop,
Resume or paused-queue behavior. Ordinary sends and Resend already have
`loading`; pending sides and their parents are protected by pane membership.
Saved-side Close retains the display, so the same eviction guard protects a
queued Save after that pane closes. Quit/update drain or settle these tasks,
and helper loss keeps the owning display while its request unwinds.

### Adversarial self-review and additional side checks

Reviewed every changed decision against both its old and new branch:

| Decision | States newly taking the other branch; intended result |
| --- | --- |
| Pin-release generation | An existing pin successfully committed/consumed now invalidates its cached pending inventory. A failed write and a nonexistent pin do not advance it. Both preservation APIs share this release point. |
| Snapshot cache hit/publication | A preservation-generation change or replaced baseline now forces reread/rejects a suspended stale result; stable streams retain the cache optimization. |
| Withdrawal proof | An unchanged loaded draft whose current durable contents differ now refuses consumption. A committed matching draft still succeeds; explicit Dismiss has no draft and still consumes only its chosen input. No new conflict episode is created. |
| Display eviction | A durable queued Save can have no run work or dirty draft. Its live ownership now prevents eviction; idle settled displays remain eligible under the existing eight-display policy. |
| Live task capture/finish | Send/follow-up, Steer, historical Resend, queued Save and side first send now own their IDs synchronously before suspension. All task exits release ownership. Captured input remains pinned or durable throughout; only a settled unaccepted outcome is offered. |
| Pending inventory filter | Pinned or durable live IDs are excluded; unrelated settled failures and hydrated records without a live task are retained. Acceptance and receipt filtering are unchanged. |
| Recovery UI/actions | The pane and dynamic chooser exclude live IDs, including a chooser cached before a retry. Insert/Dismiss check the same ownership after each suspension; merely running/paused queued work still does not hide settled failures. |
| Deferred failure offer | A known failure waiting on later bookkeeping retains its offer separately until the task finishes, so a streaming snapshot cannot erase the offer. Acceptance checks still win. |
| Side release | A captured-input transfer flag, retained records or live task now refuse synchronous release. Async transfer finishes before composer transfer/display release; failures preserve the original pane and storage owners. Ordinary untouched sides still merge synchronously. |
| Parent ownership | A side capture ensures its parent is materialized before saving its link/input. Retrying a failed transfer also materializes a still-pending parent. An absent/deleted durable parent still refuses transfer instead of creating orphan records. |
| Keep-link retirement | Failed first-send publication retains a parent link. Only a successful transfer retires a missing-journal link. Existing journal-backed registration remains available. Keep-resolution revision changes prevent concurrent scans from resurrecting a retired notice. |
| Helper loss/relaunch | Helper loss cannot discard a pane still owning input/transfer work. With no live display and a missing journal, launch reconciliation moves pending input to the saved parent; live or journal-backed sides retain their existing publication/registration path. |

Besides the recovery ordering above, the self-review found two nearby cases
within the side-transfer fix:

- `testDismissingFailedSideInputRetiresItsParentLinkOnClose`: after explicit
  Dismiss the recovered list is empty, but Close must still retire the missing
  journal's parent link. `failing-side-link-cleanup.log` fails one assertion
  before the transfer flag; `mutation-side-link-cleanup.log` independently
  reproduces it. The flag lasts until the storage transaction succeeds, even
  if no input remains to migrate.
- `testPinnedSideInputMaterializesItsPendingParentBeforeTransfer`: an initial
  keep-write failure can leave a new parent memory-only. Its input must still
  close/quit safely once storage recovers. `failing-pending-parent.log` fails
  three assertions; `mutation-pending-parent.log` reproduces them. The parent
  is saved before it becomes the durable recovery owner.

No production helper code, wire contract, provider behavior, controls or layout
geometry changed. Helper/wire/concurrent/acceptance suites are therefore not
required for this native-only round. The generated fake helper supports held
replies and streaming snapshots; it no longer writes a fixture side journal
when `side.open` is rejected. Existing tests that expected a rejected first
send to leave no recovery link now require that link until parent transfer and
await the resulting asynchronous Close. These changes preserve the existing
side-draft UX while making its independent input recoverable.

### Final validation

**480 distinct native tests passed across 28 classes; zero failures or skips.**
All round-12 classes were rerun from this worktree. Counts below exclude
exploratory passes, expected failures, mutations and the restored UI spot check.

| Class | Passed | Evidence log |
| --- | ---: | --- |
| `ConversationPaneTests` | 85 | `final-conversation.log` |
| `DraftConcurrencyTests` | 36 | `final-headless-owned.log` |
| `DraftLoadingTests` | 15 | `final-headless-owned.log` |
| `DraftOrderingTests` | 17 | `final-headless-owned.log` |
| `FamilyDeletionTests` | 10 | `final-headless-owned.log` |
| `HistoricalEditBookkeepingTests` | 2 | `final-headless-owned.log` |
| `HistoricalEditFocusTests` | 1 | `final-window.log` |
| `HistoricalEditingTests` | 5 | `final-window.log` |
| `LifecycleHelperTests` | 11 | `final-lifecycle.log` |
| `MetadataDurabilityTests` | 10 | `final-headless-owned.log` |
| `PendingChatProjectTests` | 24 | `final-headless-owned.log` |
| `QueueEditInteractionTests` | 17 | `final-queue.log` |
| `QueuedEditPresentationTests` | 9 | `final-headless-owned.log` |
| `RecoveredDraftTests` | 13 | `final-headless-owned.log` |
| `RunHoldTests` | 18 | `final-headless-owned.log` |
| `SendBookkeepingTests` | 12 | `final-headless-owned.log` |
| `SessionOrganizationTests` | 9 | `final-headless-owned.log` |
| `SideKeepOrderingTests` | 12 | `final-window.log` |
| `SideKeepRecoveryTests` | 15 | `final-window.log` |
| `SideRelaunchTests` | 3 | `final-window.log` |
| `SideTests` | 17 | `final-headless-owned.log` |
| `SubagentDeletionTests` | 19 | `final-headless-owned.log` |
| `SubmissionPersistenceTests` | 35 | `final-headless-owned.log` |
| `ToolOutputProducerTests` | 13 | `final-window.log` |
| `WorkspaceDisplayMemoryTests` | 2 | `final-headless-owned.log` |
| `WorkspaceDurabilityTests` | 9 | `final-headless-owned.log` |
| `WorkspaceRaceTests` | 58 | `final-headless-owned.log` |
| `WorkspaceValidationGalleryTests` | 3 | `final-gallery.log` |

Exact final commands (also retained in the matching `.command` files):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/DraftConcurrencyTests \
  -only-testing:PiAppTests/DraftLoadingTests \
  -only-testing:PiAppTests/DraftOrderingTests \
  -only-testing:PiAppTests/FamilyDeletionTests \
  -only-testing:PiAppTests/HistoricalEditBookkeepingTests \
  -only-testing:PiAppTests/MetadataDurabilityTests \
  -only-testing:PiAppTests/PendingChatProjectTests \
  -only-testing:PiAppTests/QueuedEditPresentationTests \
  -only-testing:PiAppTests/RecoveredDraftTests \
  -only-testing:PiAppTests/RunHoldTests \
  -only-testing:PiAppTests/SendBookkeepingTests \
  -only-testing:PiAppTests/SessionOrganizationTests \
  -only-testing:PiAppTests/SideTests \
  -only-testing:PiAppTests/SubagentDeletionTests \
  -only-testing:PiAppTests/SubmissionPersistenceTests \
  -only-testing:PiAppTests/WorkspaceDisplayMemoryTests \
  -only-testing:PiAppTests/WorkspaceDurabilityTests \
  -only-testing:PiAppTests/WorkspaceRaceTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SideKeepOrderingTests \
  -only-testing:PiAppTests/SideKeepRecoveryTests \
  -only-testing:PiAppTests/SideRelaunchTests \
  -only-testing:PiAppTests/ToolOutputProducerTests \
  -only-testing:PiAppTests/HistoricalEditingTests \
  -only-testing:PiAppTests/HistoricalEditFocusTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConversationPaneTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/QueueEditInteractionTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/LifecycleHelperTests
```

```sh
TEST_RUNNER_PI_APP_WORKSPACE_VALIDATION_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round13-input-ownership/gallery PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceValidationGalleryTests
```

Mutation checks below each broke the named fix, produced assertion failures
(exit 65, never a compile failure), and restored exact source in `finally`.
The UI mutation and its restored pass held the shared focus lock. All source
mutations serialized with the same build mutex as the final tests.

| Mutation log | Tests | Expected failed assertions |
| --- | ---: | ---: |
| `mutation-edit-owner.log` | 1 | 4 |
| `mutation-live-actions.log` | 1 | 10 |
| `mutation-live-eviction.log` | 1 | 1 |
| `mutation-live-inventory.log` | 1 | 2 |
| `mutation-live-ui.log` | 1 | 1 |
| `mutation-pending-parent.log` | 1 | 3 |
| `mutation-preservation-cache.log` | 1 | 2 |
| `mutation-queue-owner.log` | 1 | 4 |
| `mutation-side-link-cleanup.log` | 1 | 1 |
| `mutation-side-recovery-order.log` | 1 | 1 |
| `mutation-side-relaunch.log` | 1 | 2 |
| `mutation-side-transfer.log` | 1 | 4 |
| `mutation-withdrawal-proof.log` | 1 | 3 |

The reversible edits and exact selectors are in `mutations.py`,
`mutation-side-cleanup.py`, `mutation-parent.py`, `mutation-ui.py` and
`side-recovery-ordering.py` and `live-eviction.py`.
The final source manifest is `tested-source-sha256.json`; `git diff --check` passes.
No unexplained or unrelated test failures occurred. The additional failing
self-review checks are listed above; all are fixed and mutation-checked.

The gallery run generated **44 PNGs**, all visually inspected: live and settled
Steer/follow-up (16), retained unsaved/rejected input (8), one/40 conflict copies
(8), and existing draft/image/model errors (12). Each includes light/dark and
760/300-point widths. Source PNGs are in
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round13-input-ownership/gallery/`.
The labeled inspection sheets in the adjacent `gallery-inspection/` directory
show those same captures at their native point dimensions; `manifest.json`
maps every sheet to its source images.

Live Steer/follow-up scenes have no recovery row. Their settled counterparts
show the fixed one-row chooser while unrelated work continues. Unsaved input
shows “1 retained copy”; durable rejected input shows “1 saved copy”, including
after edit cancellation. One and 40 conflict copies retain the same banner
height and transcript space. At narrow width the transcript remains scrollable;
the settled streaming fixture preserves its bottom reading position. No new
control, layout geometry, clipping of recovery controls or capsule-border
change was introduced.

No production helper or wire behavior changed. All locks owned by this
workstream were released and its automatic test results/clones cleaned up;
text logs and generated PNGs are the evidence, with no named xcresult.

## Round 14 — confirmed input settlement and publication ownership

Reviewed base: `888366091541c18b6d8f365e0539bd1b76b453f4` on
`dev/a130-workspace`. Read the shared round rules, `AGENTS.md`,
`NEXT-RELEASE.md` and the relevant side/lifecycle design policies. No merge,
rebase, history rewrite or installed-app launch. Fixtures use temporary state,
MemoryVault, generated helpers and loopback services only.

Evidence directory:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round14-settlement-ownership/`.
Each run retains its exact `.command`, text `.log` and exit `.status`.
`run.py` serializes this build root; `windows.py` also owns the shared full-lane
lock for its window, serial and gallery runs. Serial classes run alone.

### Findings and failing-first evidence

All three findings are **confirmed and fixed**. With production code unchanged,
`failing-first.log` ran three regressions: **10 expected assertion failures**,
exit 65, with no compilation failure.

1. **Earlier queued Save settlement.**
   `testEarlierQueuedSaveConfirmationRetiresItsCapturedInput` loses the Save
   reply and all three status replies, types different text, then confirms
   the earlier digest through the alternate settlement branch. Before the fix:

   ```text
   XCTAssertTrue failed - The earlier operation's completion must retire its independent input
   XCTAssertTrue failed - A confirmed queued Save cannot be offered again
   ```

   Direct replies, unanswered-operation status, the earlier-operation branch
   and hydrated editor settlement now share confirmed-input retirement. It
   runs before completing the editor UI. Only the confirmed edit/digest's ID
   is consumed; the later text remains in the composer ahead of its parked
   draft. Identity is checked again after storage awaits.

2. **Accepted retry pins.**
   `testConfirmedQueuedSaveRetiresAPinLeftByFailedRetryPersistence` loses a
   Save reply, injects a failure into the same input's retry transaction,
   confirms the helper's saved digest, delivers a snapshot and flushes.
   Before:

   ```text
   XCTAssertTrue failed - Confirmation consumes both the durable record and its retry pin
   XCTAssertTrue failed - An empty durable inventory must not revive the accepted pin
   XCTAssertTrue failed - Flush must not recreate confirmed input
   ```

   Confirmed retirement uses the ordered, transactional `withdrawSubmission`
   path with the draft version. The pin is released only after the deletion
   commits. Acceptance suppresses recovery before any await, and remains
   remembered while a durable record, pin or live submission still owns the
   command. A failed cleanup is retried even when acceptance is already known;
   that retry does not require another helper response.

3. **Cross-instance publication ownership.**
   `testAnotherInstanceCannotRecoverALiveSidePublication` holds the first
   model's parent opening after the side intent/input are durable, and runs
   reconciliation in a second model sharing the same state root. Before:

   ```text
   XCTAssertNotNil failed - A different instance's missing display is not abandonment
   XCTAssertNotNil failed - The owner's registration intent must survive
   XCTAssertEqual failed: ("0") is not equal to ("1")
   ```

   The observer previously moved the live input into parent recovery, removed
   its keep intent and prevented the owner's dispatch. Publication now records
   a UUID identifying a model-lifetime `WorkspaceLock` before saving its keep
   intent. Reconciliation only acts on an owned publication after acquiring
   that lease nonblockingly, and holds the acquired lease through registration
   or parent transfer. A held lease skips both recovery and actionable notices;
   local display absence supplies no ownership evidence.

   `testCrashedPublicationOwnerReleasesItsLeaseForParentRecovery` starts a
   generated Python child holding the same `flock`, verifies that recovery
   cannot run, kills only that fixture child, then verifies parent recovery
   and keep-intent retirement. The kernel releases ownership after the crash.
   Lease files remain in `PublicationLeases/<UUID>.lock`; their stable inode,
   not their presence or a PID, defines ownership. IDs are parsed as UUIDs;
   the existing lock uses `O_NOFOLLOW`, `O_CLOEXEC` and nonblocking `flock`.
   A model retains its lease while shutdown tasks unwind. No polling of the
   publisher, new prompt, helper call or production-path enablement is added.

`fixed-first.log` passed all **38** then-current submission tests. Further
sweep tests reproduced two related settlement gaps (`failing-settlement-sweep.log`:
four tests, six expected assertions; the lease-crash and legacy-policy tests
passed). Journal/terminal-receipt acceptance could also leave retry pins, and
known acceptance skipped a later failed-cleanup retry. These are fixed through
the same ordered acknowledgement/retirement operations.

### Acceptance and ownership sweep

| Path checked | Settlement / ownership result |
| --- | --- |
| Queued Save direct reply | Confirmed ID retires before editor completion; the live task still owns it through cleanup. |
| Same Save's lost reply followed by status | Matching edit/digest invokes the same retirement before its completion callback. |
| Different Save/Cancel/Remove while an earlier operation is unresolved | Only the earlier matching Save is retired. Newer typing is retained; mismatching digests remain unresolved input. |
| Hydrated queued editor | A saved outcome retires its matching command ID independently of the editor's current rewrite; replacement editor identity is rechecked after storage. |
| Hydrated independent queued input | Matching saved digest or already-known acceptance consumes the durable record and pin; a different digest stays recoverable. |
| Send, Steer, follow-up and side first send | Existing acknowledgement now carries its draft version; pin retirement follows the ordered acknowledgement commit. |
| Historical Resend | Uses the same version-aware acknowledgement; review markers remain separate ordered composer writes. |
| Journal acceptance | Matching accepted pins are acknowledged durably after returned-draft review protection. Inputs without pins retain their existing path. |
| Dispatched snapshot receipt | Only a remaining pin needs acknowledgement; ordinary streaming snapshots acquire no additional acknowledgement write. |
| Terminal snapshot receipt | Durable receipt precedes pending-record/pin retirement; pinned records also participate in the inventory. Failed cleanup remains suppressed and retryable. |
| Resume, compaction and title jobs | These do not capture user-input pins. Their existing calls retain the default no-version API; title and lifecycle classes are included in validation. |
| Queue removal and rewritten original-turn bookkeeping | These operate on already-dispatched original turn records, whose initial write committed before dispatch; the separate `queue-edit:` capture is settled by the paths above. |
| Pending side publication, Keep, keep-on-close and fork | All four keep-intent writers attach the model's lifetime lease. No anonymous new publication remains. |
| Close/quit/update of an owned side | Existing explicit parent transfer retains its input and collector ownership. Lifetime ownership affects observer reconciliation, not the owning model's transfer. |
| Relaunch and concurrent observers | The successful lease probe is held across awaited storage; another observer skips without waiting. Input moves atomically before the keep intent is removed. |

`testJournalAndTerminalReceiptSettlementRetireRetryPins` covers journal,
dispatched and terminal evidence. `testQueuedSaveConfirmationSurvivesFailedCleanupAndHydratedEditorSettlement`
checks both successful and failed deletion and a subsequent retry.
`testConfirmedInputWithoutADurableRowStaysSuppressedUntilCleanupRetries`
holds an independent SQLite writer to fail BEGIN, then checks an empty durable
snapshot cannot erase acceptance while its pin remains.
`testAcknowledgementSurvivesALiveTaskAfterItsInputWasRetired` covers the other
owner: a live task after successful durable cleanup, before its completion
callback. Its separate mutation removes only the live-task retention term.
`testAcknowledgementReleasesPinsOnlyAfterItsCommit` covers missing/existing
pending rows and failure before the write or transaction rollback after it;
failed writes preserve the pin and durable row, successful retry clears it.

The first expanded `fixed-sweep.log` ran 44 tests with three assertions in one
new fixture case. Its AFTER INSERT trigger did not fire on SQLite's upsert
UPDATE arm, so no failure had actually been injected. The fixture now selects
AFTER UPDATE for an existing row. `fixed-acknowledgement-fixture.log` passes;
this was a fixture correction, not an ignored production/test failure.

**Legacy compatibility — needs owner decision:** an old keep record without
a publication owner cannot prove its publisher is gone. Missing-journal legacy
records therefore retain their existing review notice and records, rather than
being automatically moved or discarded. `testLegacyMissingSideWithoutOwnershipEvidenceIsNotRetiredAutomatically`
covers this conservative rule. A future explicit recovery policy for such
ownerless legacy records needs the owner's decision; all newly
published records have a lease. Legacy records with a valid journal keep the
existing registration path.

### Adversarial self-review

Reviewed every changed condition and suspension boundary:

| Changed decision | Newly affected state; intended result |
| --- | --- |
| Known accepted queued input is revisited | Failed cleanup now retries instead of leaving a pin indefinitely. It uses existing acceptance evidence, not a second dispatch. |
| Matching saved status calls shared retirement | Earlier-operation and hydrated-editor branches now consume only the confirmed digest. Another rewrite's independent record is untouched. |
| Editor identity after cleanup | Navigation/replacement during an await cannot finish another editor. The old command's proven acceptance still settles its own input. |
| Pending pin included in receipt inventory | Receipt-backed input absent from desktop rows can now settle. Unmatched pins remain owned and recoverable after their task ends. |
| Acknowledgement has a pin but no pending row | The confirmed record is recreated as acknowledged, then its pin is released after commit. Failure leaves the original pin. |
| Acknowledgement is already durable | An acknowledged row needs no rewrite; only the redundant pin is retired. |
| Acceptance-cache intersection | Pins and live tasks now retain acknowledgement when the durable inventory is empty. IDs with no owner remain eligible for pruning. |
| Lease acquired before keep write | A failed lock/file operation fails publication while the existing captured-input pin remains available. No anonymous publication is written. |
| Foreign/own lifetime lease is held | Automatic reconciliation skips the entire publication; no missing-file notice or recovery action can retire live work. The owner's explicit publication/transfer paths remain available. |
| Lease owner exited | A nonblocking probe succeeds; recovery holds that descriptor across awaits and commits before releasing it. Files are never unlinked to manufacture ownership. |
| Invalid owner or unacquirable lease | No automatic retirement; UUID validation prevents a record from choosing an arbitrary lock path. |
| No owner on a legacy missing-journal record | No automatic abandonment claim; retain the existing review notice/data pending an explicit policy. |

No helper implementation, wire contract, provider behavior, capture policy,
permission boundary, control or layout geometry changed. Full helper and wire/
concurrent/acceptance suites are not required for this native-storage round.
The affected title-job tests are added because they share the acknowledgement API.

### Final validation

**503 distinct native tests passed across 29 classes; zero failures or skips.**
All round-13 classes were rerun, with `TitleGenerationTests` added for the shared
acknowledgement API. Counts exclude earlier exploratory/failing runs and mutations.

| Class | Passed | Evidence log |
| --- | ---: | --- |
| `ConversationPaneTests` | 85 | `final-conversation.log` |
| `DraftConcurrencyTests` | 36 | `final-headless.log` |
| `DraftLoadingTests` | 15 | `final-headless.log` |
| `DraftOrderingTests` | 17 | `final-headless.log` |
| `FamilyDeletionTests` | 10 | `final-headless.log` |
| `HistoricalEditBookkeepingTests` | 2 | `final-headless.log` |
| `HistoricalEditFocusTests` | 1 | `final-window.log` |
| `HistoricalEditingTests` | 5 | `final-window.log` |
| `LifecycleHelperTests` | 11 | `final-lifecycle.log` |
| `MetadataDurabilityTests` | 10 | `final-headless.log` |
| `PendingChatProjectTests` | 24 | `final-headless.log` |
| `QueueEditInteractionTests` | 17 | `final-queue.log` |
| `QueuedEditPresentationTests` | 9 | `final-headless.log` |
| `RecoveredDraftTests` | 13 | `final-headless.log` |
| `RunHoldTests` | 18 | `final-headless.log` |
| `SendBookkeepingTests` | 12 | `final-headless.log` |
| `SessionOrganizationTests` | 9 | `final-headless.log` |
| `SideKeepOrderingTests` | 12 | `final-window.log` |
| `SideKeepRecoveryTests` | 15 | `final-window.log` |
| `SideRelaunchTests` | 3 | `final-window.log` |
| `SideTests` | 17 | `final-headless.log` |
| `SubagentDeletionTests` | 19 | `final-headless.log` |
| `SubmissionPersistenceTests` | 45 | `final-headless.log` |
| `TitleGenerationTests` | 12 | `final-title.log` |
| `ToolOutputProducerTests` | 13 | `final-window.log` |
| `WorkspaceDisplayMemoryTests` | 2 | `final-headless.log` |
| `WorkspaceDurabilityTests` | 9 | `final-headless.log` |
| `WorkspaceRaceTests` | 58 | `final-headless.log` |
| `WorkspaceValidationGalleryTests` | 4 | `final-gallery.log` |

Exact final commands (also retained in the matching `.command` files):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/DraftConcurrencyTests \
  -only-testing:PiAppTests/DraftLoadingTests \
  -only-testing:PiAppTests/DraftOrderingTests \
  -only-testing:PiAppTests/FamilyDeletionTests \
  -only-testing:PiAppTests/HistoricalEditBookkeepingTests \
  -only-testing:PiAppTests/MetadataDurabilityTests \
  -only-testing:PiAppTests/PendingChatProjectTests \
  -only-testing:PiAppTests/QueuedEditPresentationTests \
  -only-testing:PiAppTests/RecoveredDraftTests \
  -only-testing:PiAppTests/RunHoldTests \
  -only-testing:PiAppTests/SendBookkeepingTests \
  -only-testing:PiAppTests/SessionOrganizationTests \
  -only-testing:PiAppTests/SideTests \
  -only-testing:PiAppTests/SubagentDeletionTests \
  -only-testing:PiAppTests/SubmissionPersistenceTests \
  -only-testing:PiAppTests/WorkspaceDisplayMemoryTests \
  -only-testing:PiAppTests/WorkspaceDurabilityTests \
  -only-testing:PiAppTests/WorkspaceRaceTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SideKeepOrderingTests \
  -only-testing:PiAppTests/SideKeepRecoveryTests \
  -only-testing:PiAppTests/SideRelaunchTests \
  -only-testing:PiAppTests/ToolOutputProducerTests \
  -only-testing:PiAppTests/HistoricalEditingTests \
  -only-testing:PiAppTests/HistoricalEditFocusTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConversationPaneTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/QueueEditInteractionTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/LifecycleHelperTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TitleGenerationTests
```

```sh
TEST_RUNNER_PI_APP_WORKSPACE_VALIDATION_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round14-settlement-ownership/gallery PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceValidationGalleryTests
```

Each mutation changed only its recorded condition(s), ran its dedicated
regressions, then restored exact source in `finally`. All failures were
assertions (exit 65), never compilation failures. Reversible edits/selectors
are in `mutations.py` and `live-acknowledgement.py`. The first script groups
independent changes into three builds; the live-task term has its own build.

| Mutation log | Failed regression tests | Expected assertions |
| --- | ---: | ---: |
| `mutation-acknowledgement-lifetime.log` | 1 | 4 |
| `mutation-live-acknowledgement.log` | 1 | 2 |
| `mutation-primary.log` | 5 | 13 |
| `mutation-settlement-sweep.log` | 3 | 10 |

The primary batch removes the earlier-status retirement call (finding 1),
omits the draft version from shared retirement (finding 2), and bypasses the
lease/proof guards (finding 3, including crash and legacy cases). Each finding's
regression fails again. The sweep batch removes acknowledgement pin release,
terminal-receipt pin retirement and known-acceptance cleanup retries. The two
lifetime batches separately exercise accepted pins without a durable row and
live tasks after that row has been retired.

All **10 mutation regressions** failed as expected. Final tests then ran restored source.
The final source manifest is `tested-source-sha256.json`. Compared with the
headless manifest, only the subsequently added gallery scene differs; all
production and headless-test sources match. `git diff --check` passes.
All failed runs are accounted for above; there are no ignored/unexplained failures.

The serial gallery regenerated **52 PNGs** under the shared focus lock:
the 44 existing scenes plus eight queued-Save unanswered/confirmed captures
(light/dark, 760/300-point widths). The eight new captures were visually checked
at their native point dimensions using the labeled inspection sheets. The
unanswered input has its existing one-row chooser; confirmation removes that
row, while “Newer typing after choosing Save.” remains in the composer.
The transcript regains the row's space without a new control or layout change.

Original captures:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round14-settlement-ownership/gallery/`.
The corresponding `gallery-inspection/queued-save-light.png` and
`gallery-inspection/queued-save-dark.png` sheets show both widths and states.
All sheets map to their source captures in `gallery-inspection/manifest.json`.

The 44 existing captures were also pixel-compared with the inspected round-13
gallery (`gallery-pixel-comparison.json`): **41 are pixel-identical**. The
remaining three live/wide captures differ only inside the unchanged message
Edit/Copy/Details toolbar rectangle (310×46 pixels at x=1162, y=135). Their
full scenes and before/after crops were visually inspected; the controls and
geometry are unchanged. All pixels outside that rectangle match.

All workstream-owned locks were released. Automatic Xcode result bundles and
any test clone folders were cleaned from this build root; text logs and PNGs
remain the evidence. No named xcresult was requested. The three assigned
findings and the confirmed nearby settlement gaps are fixed; the conservative
legacy ownership policy above is the only item flagged for an owner decision.


## Round 15 — retry and reading-position ownership

Base: `1df7f7edae587336a6191dec6d60cddcc7c168a4`, branch
`dev/a130-workspace`. All tests use generated state roots, in-memory vaults,
fake helper replies and injected SQLite failures. No installed app, real user
state/credentials or paid provider was used. The helper and wire contract are
unchanged; helper/wire suites are not required for these desktop-only changes.

Evidence root:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round15-save-retry-anchor/`.
Each run retains its exact `.command`, text `.log` and process `.status`.

### Findings and failing-first evidence

All three reported findings are **confirmed and fixed**. Before any production
change, `failing-first.log` ran the three regressions: **3 failed tests,
22 assertion failures, exit 65**. No build failure is counted as reproduction.

1. **Unresolved queued Save lost on retry persistence failure.**
   `SubmissionPersistenceTests.testFailedQueuedSaveRetryKeepsTheEarlierOutcomeForCancelAndChangedSave`
   sends a Save with missing reply/status responses, injects a pending-record
   INSERT failure on its identical retry, then exercises both Cancel and a
   changed Save. The old operation/digest must survive in memory **and** the
   saved queued-edit draft. Failing excerpt:
   `XCTAssertEqual failed: ("nil") is not equal to ("Optional("save")") — Local failure cannot settle the original helper request`;
   Cancel sent `queue.edit.cancel` instead of `queue.edit.status` and returned
   the confirmed rewrite as unsent. The fix restores the operation/digest from
   before this attempt, not unconditional nil. A first attempt still restores
   nil and keeps its captured input independently recoverable.

2. **The local publisher could not Retry its own registration.**
   `SubmissionPersistenceTests.testLocalSidePublicationCanRetryRegistrationWithoutDroppingItsNotice`
   publishes an actual generated side journal, fails its chat INSERT, obtains
   the existing issue through `applySideStatus`, retries while failure remains,
   then retries after removing the trigger. Failing excerpts:
   `Failed Retry must leave its actionable notice` (actual issues `[]`), and
   `The publication owner must be able to retry its own settled failure`
   (no saved chat; keep intent still present). Local settled publications now
   reuse their held lifetime lease; foreign owners still require a successful
   nonblocking lease probe. Skipped work retains any matching existing notice.

3. **Outstanding anchor writes did not retain their display.**
   `DraftOrderingTests.testOutstandingAnchorWritePinsDisplayAndReopenAdoptsItsCommittedRevision`
   holds an anchor predecessor, exceeds the eight-display budget, revisits,
   releases the old write, then scrolls and clears. Failing excerpts:
   `A predecessor wait must not make an outstanding anchor evictable`,
   `Later scrolls cannot silently lose against this instance's older write`,
   and `Return to latest must still clear the saved position`.
   An outstanding task now prevents eviction. Its identity token clears that
   task only on its own completion, so a canceled predecessor cannot clear a
   newer writer. Completed idle displays remain evictable. The final eviction
   assertion explicitly sets the revisited display's last-use time to oldest.

With the three fixes, `fixed-regressions.log`: **3 passed, 0 failed**.

### Nearby sweep and ownership rules

- **Additional confirmed instance in the same queued-edit function:** a retry
  refused with `session_missing` also cleared an earlier unanswered Save.
  `testRefusedQueuedSaveRetryDoesNotSettleTheEarlierUnknownOutcome` failed first
  in `sweep-regressions.log` (**1 failed / 4 run, 4 assertions**): it lost the
  original operation/digest, sent Cancel directly, and retained confirmed
  input. This catch now also restores prior state. Its notice explicitly says
  the earlier request remains unconfirmed. Accepted replies and matching
  status digests still settle and retire captured input; an authoritative
  active status still permits a new request. Different-operation reconciliation,
  hydrated queued edits and Cancel/Remove settlement retain their existing
  digest/identity gates.
- `testInitialQueuedSaveStorageFailureDoesNotInventAnUnansweredRequest`
  proves a failed **first** local Save leaves no pending helper request, allows
  Cancel directly, and retains the unsent rewrite through the recovery chooser.
- **Local publication ownership** covers all four intent writers:
  `publishPendingSide` (including first Send), `performKeepSide`, `closeSide`
  when keeping, and `createFork`. They register their ID before publication
  can suspend and release it in `defer` on success, refusal, storage failure or
  cancellation. `testOwnLivePublicationIsNotReconciledByAnyPublicationRoute`
  holds each helper reply with a valid journal already present, preserves an
  earlier issue, and verifies local Retry cannot preempt publication or offer
  its input to the parent. Completion then registers exactly that chat and
  clears the issue. Cross-instance live/crashed-owner and legacy-intent tests
  from Round 14 are rerun unchanged.
- **Deferred helper publication** also owns a Keep after the local request
  task ends. A review of the new local branch caught its need to check existing
  `keeping` / `keepRequested` flags. Before that guard,
  `testDeferredLocalKeepWaitsForTheHelpersPublication` failed both flag cases
  (`deferred-keep-first.log`: **1 failed, 2 assertions**), incorrectly creating
  a recovery notice. The guard now waits for the helper's publication status;
  the final saved snapshot registers normally. No helper behavior changed.
- The adversarial review then checked that deferred ownership ends on helper
  loss, even when captured input pins the display. The new deferred guard
  initially blocked that settled registration too.
  `testLostHelperReleasesDeferredKeepOwnershipEvenWhenInputPinsItsDisplay`
  failed first (`retired-keep-first.log`: **1 failed, 4 assertions**) for both
  flags: the display survived correctly, but its valid journal could not
  register. `discardLostSides` now clears the ended helper's Keep flags before
  its existing input-retention guard. The current-host check in `onLoss` still
  fences this cleanup against replacement helpers; other workspaces and saved
  sides are excluded. Pinned input remains in the display or its committed
  independent record. The dedicated fixed and mutation runs verify both
  lifetime boundaries without starting another helper.
- **Anchor ownership** begins synchronously when `anchorChanged` assigns its
  task, includes waiting for its predecessor and for the metadata actor, and
  ends only when that exact task finishes. Before baseline hydration the
  existing `anchorWritePending` flag still owns it. Revision reservation/CAS
  remains in the ordered writer. `testSupersededAnchorCompletionCannotReleaseTheNewerWritersDisplay`
  releases a canceled predecessor while the replacement waits on a held
  metadata actor; eviction must still retain the display, and the final saved
  anchor must be the replacement's position.
- **Release-path sweep:** main-chat and subagent-reader cache eviction both use
  `releaseUnreadDisplays` and gain the task guard. Saved-side Close and
  quit/update `flushDrafts` already await anchor tasks before their direct
  ordered writes. Helper loss retains saved displays; the removed ephemeral
  side paths never admit anchor writes. Explicit chat/family deletion removes
  the chat itself and is not a reopen path. Unsent pending-chat and background
  title-task disposal do not own a saved reading-position baseline. No other
  revision reset or direct anchor writer was added.

The conservative Round-14 policy for **legacy missing-journal keep intents
without an owner lease** is unchanged: retain them with their existing review
notice. Its recorded owner-decision follow-up is not expanded in this round.

### Adversarial self-review

Every changed conditional/state boundary was checked against both sides:

| Boundary | States that now differ | Intended result / evidence |
| --- | --- | --- |
| Save persistence catch restores prior state | Identical retry with unanswered predecessor | Keeps original operation/digest; Cancel/changed Save queries status first. First Save still restores nil. |
| Definitive retry refusal | Prior unanswered request versus first request | Refusal proves only this attempt failed; earlier outcome stays unknown. First-attempt refusal retains its existing notice and clearing behavior. |
| Local owner identity | Own lease versus foreign live/dead owner | Own settled registration can retry; foreign live lease is not acquired/waited on; dead owner's recovery remains guarded by its acquired lease. |
| Local publication admission | Active side open/keep/close/fork or deferred helper Keep versus settled failure | Active work is skipped without retiring input; settled failure registers. All four task scopes and both deferred flags are covered. |
| Skipped-issue retention | Matching prior notice versus a normal live publication with no issue | Existing notice remains until actual resolution; a live publication does not gain a new notice. |
| Helper-loss Keep flags | Unkept side retained by pinned input versus a live Keep | Ended helper flags clear even when the display stays; a live helper keeps its flags. The existing current-host and workspace guards remain in force. |
| Eviction checks outstanding anchor task | Hydrated display with a waiting/writing task versus completed task | Loaded baseline stays with its only writer. Completion restores normal cache eviction. |
| Anchor cleanup token equality | Current task versus superseded predecessor | Only current completion clears task ownership; prior completion cannot unpin its replacement. |

No submission acceptance predicate, durable record layout, revision/CAS rule,
permission, capture, tool, vault or data boundary changed. The retained-input
chooser continues to exclude live submissions and accepted commands.

The first complete headless pass (`pre-review-headless.log`) passed **333
native tests**. Its orchestrator was stopped while waiting for another
workstream's focus lock, before any window lane began, to test the helper-loss
boundary above. No running native test or foreign lock was interrupted. Final
counts below come from the subsequent full rerun of the final source.

### Final validation

**513 distinct native tests passed across 29 classes; zero failures or skips.**
Every Round-14 class was rerun. Counts exclude failing-first, exploratory and
mutation runs. Focus/window/gallery runs held the shared full-lane lock;
serial classes ran alone. All builds used this workstream’s single build root.

| Class | Passed | Evidence log |
| --- | ---: | --- |
| `ConversationPaneTests` | 85 | `final-conversation.log` |
| `DraftConcurrencyTests` | 36 | `final-headless.log` |
| `DraftLoadingTests` | 15 | `final-headless.log` |
| `DraftOrderingTests` | 19 | `final-headless.log` |
| `FamilyDeletionTests` | 10 | `final-headless.log` |
| `HistoricalEditBookkeepingTests` | 2 | `final-headless.log` |
| `HistoricalEditFocusTests` | 1 | `final-window.log` |
| `HistoricalEditingTests` | 5 | `final-window.log` |
| `LifecycleHelperTests` | 11 | `final-lifecycle.log` |
| `MetadataDurabilityTests` | 10 | `final-headless.log` |
| `PendingChatProjectTests` | 24 | `final-headless.log` |
| `QueueEditInteractionTests` | 17 | `final-queue.log` |
| `QueuedEditPresentationTests` | 9 | `final-headless.log` |
| `RecoveredDraftTests` | 13 | `final-headless.log` |
| `RunHoldTests` | 18 | `final-headless.log` |
| `SendBookkeepingTests` | 12 | `final-headless.log` |
| `SessionOrganizationTests` | 9 | `final-headless.log` |
| `SideKeepOrderingTests` | 12 | `final-window.log` |
| `SideKeepRecoveryTests` | 15 | `final-window.log` |
| `SideRelaunchTests` | 3 | `final-window.log` |
| `SideTests` | 17 | `final-headless.log` |
| `SubagentDeletionTests` | 19 | `final-headless.log` |
| `SubmissionPersistenceTests` | 52 | `final-headless.log` |
| `TitleGenerationTests` | 12 | `final-title.log` |
| `ToolOutputProducerTests` | 13 | `final-window.log` |
| `WorkspaceDisplayMemoryTests` | 2 | `final-headless.log` |
| `WorkspaceDurabilityTests` | 9 | `final-headless.log` |
| `WorkspaceRaceTests` | 58 | `final-headless.log` |
| `WorkspaceValidationGalleryTests` | 5 | `final-gallery.log` |

Exact final commands (also retained in the matching `.command` files):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/DraftConcurrencyTests -only-testing:PiAppTests/DraftLoadingTests -only-testing:PiAppTests/DraftOrderingTests -only-testing:PiAppTests/FamilyDeletionTests -only-testing:PiAppTests/HistoricalEditBookkeepingTests -only-testing:PiAppTests/MetadataDurabilityTests -only-testing:PiAppTests/PendingChatProjectTests -only-testing:PiAppTests/QueuedEditPresentationTests -only-testing:PiAppTests/RecoveredDraftTests -only-testing:PiAppTests/RunHoldTests -only-testing:PiAppTests/SendBookkeepingTests -only-testing:PiAppTests/SessionOrganizationTests -only-testing:PiAppTests/SideTests -only-testing:PiAppTests/SubagentDeletionTests -only-testing:PiAppTests/SubmissionPersistenceTests -only-testing:PiAppTests/WorkspaceDisplayMemoryTests -only-testing:PiAppTests/WorkspaceDurabilityTests -only-testing:PiAppTests/WorkspaceRaceTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SideKeepOrderingTests -only-testing:PiAppTests/SideKeepRecoveryTests -only-testing:PiAppTests/SideRelaunchTests -only-testing:PiAppTests/ToolOutputProducerTests -only-testing:PiAppTests/HistoricalEditingTests -only-testing:PiAppTests/HistoricalEditFocusTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationPaneTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QueueEditInteractionTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/LifecycleHelperTests
```

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TitleGenerationTests
```

```sh
TEST_RUNNER_PI_APP_WORKSPACE_VALIDATION_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round15-save-retry-anchor/gallery PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceValidationGalleryTests
```

The three reported fixes and each ownership guard were mutation-checked.
`mutations.py` temporarily restores pending-state loss, own-lease refusal and
anchor eviction, then removes the live-publication and replacement-task guards.
`retired-keep.py` separately removes helper-loss flag cleanup. Every script
restores exact source in `finally`; the final runs use that restored source.

| Mutation log | Failed regression tests | Assertion failures |
| --- | ---: | ---: |
| `mutation-ownership.log` | 3 | 12 |
| `mutation-primary.log` | 4 | 20 |
| `mutation-retired-keep.log` | 1 | 4 |

All **8 mutation regressions** failed as expected (exit 65). These are assertion failures, not compiler failures.
The additional focused pass (`fixed-affected.log`) passed 70 tests before the
helper-loss sweep; `retired-keep-fixed.log` passed its later regression.
The source manifest `tested-source-sha256.json` matches all final tested Swift
and generated project sources. `git diff --check` passes. Every failed run is
accounted for above; no unrelated failing test is ignored.

The serial gallery generated **56 PNGs**, covering the 52 prior scenes and four
new queued-retry notices (light/dark, 760/300 points), under the shared focus
lock. The four new scenes were visually inspected at native point dimensions:
the earlier-outcome warning wraps readably, the recovery chooser remains one
row and reachable, and the transcript keeps its space. The 300-point stress
scene retains the existing composer toolbar minimum-width overflow documented
in `ComposerInput.swift:450–476`; no toolbar or composer geometry changed.

Original captures:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-workspace/evidence/round15-save-retry-anchor/gallery/`.
The inspected new scenes are `queued-save-retry-refused-{light,dark}-{760,300}.png`.
Labeled sheets are `gallery-inspection/queued-save-retry-refused-{light,dark}.png`.

Pixel comparison with Round 14: **48 of 52 existing scenes are identical**.
The other four differ only within the existing Edit/Copy/Details toolbar
(310×46 pixels at x=1162, y=135, or a smaller rectangle within it). Their
before/after crops were visually inspected in
`gallery-inspection/toolbar-comparison.png`; the control geometry is unchanged.
All pixels outside that toolbar match. `gallery-pixel-comparison.json` records
every image's count and difference bounds; the inspection manifest maps all
56 captures to their labeled sheets.

The workstream's shared focus lock and build mutex were released. Automatic
Xcode result bundles were removed from this build root, no test clone folders
remained, and approximately 11.6 GiB remained free (`cleanup.json`). Text logs and
PNG evidence are retained; no named xcresult was requested. No new owner
product decision or unresolved assigned finding remains. The existing legacy
no-lease recovery-policy follow-up remains as recorded in Round 14.
