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
