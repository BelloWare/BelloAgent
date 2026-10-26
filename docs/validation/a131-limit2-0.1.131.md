# LIMIT-2: the raised-limit notice and failed limit sends — 0.1.131

Workstream `dev/a131-limit2`, based on `dev/next` **5b8fe72f755d** (LIMIT-1).
macOS 14.8 (23J21), Xcode 16.1 (16B40), arm64. Build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-a131-limit2`; text evidence in
`evidence/` and `logs/` below it. This record accompanies the implementation
commit. Generated scratch chats, memory vaults and loopback gateways only; the
isolated `com.belloware.PiAppTests.Host`, with no installed app, real preferences,
chats, Keychain or paid provider.

## Cause and change

LIMIT-1 delivered a saved limit independently of its editor and repaired a missed
raise before Resume. Its record left two gaps:

- The helper keeps its pause-time `preflightError` until Resume. The card already
  uses the app's live cost reading, but `WorkspaceRefresh.applyToolNotice` copied
  the old explanation to the composer. After $25.01 spent under $25, raising to
  $100 still left “Raise the limit above the spend” below a card offering Resume.
- `sendCostLimit` and snapshot reconciliation marked a limit as sent before any
  acknowledgement. A refused lower limit stayed saved in the app while the helper
  enforced its older, higher limit; snapshots never retried that choice.

`SessionDisplay` now composes the cost-pause explanation from the same live limit
and shared spend as the card once there is room. The chat reads “The limit is now
$100.00. Choose Resume to continue.” Sides name the main chat's limit; sub-agents
say they continue when the main chat resumes. No limit reads “There is no limit
now.” The line follows a second raise and repeated old helper messages, retains
queued-edit explanations, respects an edit hold and a Resume in progress, and
preserves other preflight errors. Unknown spend and a limit at or below the spend
keep their previous instruction. No work resumes automatically.

`WorkspaceCostLimits` now distinguishes a pending send from an acknowledged one.
An unsuccessful cost-only configure retries after **1, 2, 4, 8, 16, then at most
once per 30 seconds**, while the same chat, budget owner, host and connection are
still current. This bounds the rate, rather than abandoning an unconfirmed choice
after a fixed number of attempts. Snapshots share a pending send/backoff. A timed-out
command must physically settle before another enters the helper's command queue.
A new choice or an explicit Resume supersedes a backoff; old acknowledgements
cannot mark the new choice confirmed. Unload, host loss and shutdown retire the
retry. A save completing during update preparation stays pending: the helper
still refuses it while quiesced, and the retry can recover if the update is
abandoned. No retry opens a helper or resumes a run. Only the idempotent cost-limit setting is retried; the helper and
wire contract are unchanged.

## Failing first

Production sources remained at 5b8fe72f for `evidence/red-base.log`:
**5 tests failed, 58 XCTest failures (including 2 thrown finite-wait errors)**.

| Test | Before the fix |
| --- | --- |
| `CostLimitTests.testARaiseUpdatesTheComposerBeforeResumeAndSurvivesOldHelperNotices` | Both the immediate line and a fresh helper snapshot still said $25.01 of $25 and asked for a raise; `FooterNotice` never showed the raised explanation. |
| `CostLimitTests.testAFailedLoweredLimitIsRetriedAndOnlyAcknowledgedAfterItReachesTheHelper` | Both sent markers already said $1 before acknowledgement; after a `quiesced` refusal the lower limit was never sent again. |
| `CostPauseFamilyTests.testARaiseUpdatesNestedFamilyComposerLinesWithoutAnOwnerDisplay` | A side, nested side and sub-agent all kept the instruction to raise after the root's saved $100 choice, with no root display. |
| `CostPauseFamilyTests.testAFamilyResumeGivesTheChatsHelperItsRaisedLimitFirst` (existing LIMIT-1 test, extended) | The real chat and side kept their old pause explanations after the raise. |
| `CostPausePresentationTests.testTheComposerAndItsFooterFollowTheRaisedLimitForEveryFamilyMember` | The display, native `MetricsFooter`/`FooterNotice`, help and accessibility text all kept the old explanation at $5, $6 and No limit. |

An additional update edge was tested with the real helper quiesced, app update
preparation active and app snapshots held. Dropping the send at the app's update
guard lost the choice even after `workspace.resume` and release of the barrier:
`evidence/red-update-preparation.log`, **1 test failed, 2 failures**. Saved choices
now retain their delivery/retry during update preparation; the helper continues
to enforce quiescence. The regression covers both ordinary quiescence and an
abandoned update without relying on a fresh app snapshot.

The tests use `setCostLimit`, snapshots, `SessionDisplay`, the native footer and
real card/pane paths. Additional regressions exercise a real quiesced helper,
seven consecutive refusals with held backoffs and 100 snapshots per refusal,
new choices, late acknowledgements, runtime unload, physical timeout settlement,
edit holds, other preflight reasons and unknown spend. The retry delay seam holds
only the wait; command admission, replies, persistence and reconciliation use the
normal app paths.

## Validation commands and scope

Before every heavy build, checked the shared lock and waited out any perf/soak
owner. Focus-dependent runs held the shared full-lane lock and released it on
failure too. Classes ran separately with parallel testing disabled; the initial
five-selector red run ran sequentially in one isolated host under the lock.
No named result bundles; text logs are the evidence. No full native lane, helper
suite, wire suite, performance run, release or publication was performed.

Build and test recipe (each class/selector below supplies `-only-testing:…`):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a131-limit2
python3 scripts/build-bundle.py
xcodegen generate --quiet
X=(-project PiApp.xcodeproj -scheme PiApp -destination 'platform=macOS,arch=arm64'
   -derivedDataPath "$PI_BUILD_ROOT/native-tests" CODE_SIGN_IDENTITY=-
   CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO)
xcodebuild build-for-testing "${X[@]}"
xcodebuild test-without-building "${X[@]}" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/CostLimitTests
```

The red selectors are the five test names above. Native positive runs cover only
the changed cost delivery, cost-pause presentation, notice composition, opening
reconciliation and family-budget paths:

| Class | Passed / failed | Text log |
| --- | --- | --- |
| `CostLimitTests` | 21 / 0 | `logs/green-update-preparation.log` |
| `CostPauseFamilyTests` | 5 / 0 | `logs/green-family-and-presentation.log` |
| `CostPausePresentationTests` | 8 / 0 | same |
| `QueuedEditPresentationTests` | 9 / 0 | same |
| `CostLimitOpeningTests` | 1 / 0 | same |
| `SubagentCostTests` | 11 / 0 | `logs/green-budget-families.log` |
| `SideBudgetIntegrationTests` | 18 / 0 | same |
| `CostPauseGalleryTests` | 1 / 0, 30 images | `logs/green-gallery.log` |

Earlier positives: `logs/green-cost-limit.log`, 19 / 0; `logs/green-delivery.log`,
20 / 0 after adding physical timeout settlement; the real-helper refusal/recovery
test in `logs/green-budget-families.log`, 1 / 0. These are overlapping checks,
not additional unique tests. Debug durations are not performance evidence.

## Mutation checks

Each mutation was built, its selected regression(s) executed, and both production
source files restored in `finally`. Evidence: `evidence/mutation-*.log`,
`evidence/mutations-summary.log` and `evidence/mutation-update-summary.log`.

| Mutation | Regression | Result |
| --- | --- | --- |
| Restore the raw helper notice | Chat, nested-family and native-footer notice regressions | 4 tests fail, 65 failures |
| Suppress the retry | Failed lowered send and real quiesced-helper recovery | 2 tests fail, 4 failures |
| Mark the limit sent before acknowledgement | Failed lowered-send regression | 1 test fails, 2 failures |
| Remove pending-send coalescing | Failed lowered send with 100 snapshots while the retry is in flight | 1 test fails, 3 failures; 32 commands instead of 2 |
| Keep every backoff at 1 second | Seven-refusal regression | 1 test fails, 6 failures |
| Retry before physical timeout settlement | Timed-out-send regression | 1 test fails, 1 failure; 2 commands instead of 1 |
| Drop sends during app update preparation | Real quiesced-helper recovery, with an abandoned update | 1 test fails, 2 failures |

The mutation driver's first summary parser expected the plural “failures” and
misreported the final one-failure result as unexecuted. The native test had failed
as intended. The parser was corrected to accept the singular, and that mutation
was rerun: one executed test, one failure, caught. Original driver output remains
in `evidence/mutations-summary.log`; the clean rerun summary is
`evidence/mutation-settlement-summary.log`. The restored production sources are
verified again in `logs/green-restored.log`.

## Gallery and remaining work

**74 unique focused tests passed, 0 failed** (73 native behavior/presentation tests
plus the gallery). The restored run repeated all 21 `CostLimitTests`, all 8
`CostPausePresentationTests` and the new nested-family regression, all green. After the update edge, the full 21-test cost class passed again in
`logs/green-update-preparation.log`. After the seventh mutation, the real-helper
recovery regression passed again (1 / 0) in `logs/green-update-restored.log`.
All **7 mutations were caught**. Exact commands, including each mutation's
`-only-testing` selectors, are in the corresponding text logs.

Generated `gallery-limit2/`: 30 PNGs at 700×600, 920×600 and 1240×800, light and
dark. Viewed all 12 raised-limit chat/child scenes, plus the existing dark narrow
child scene. The raised card and footer agree; the line's existing truncation and
narrow-window hiding remain, with full text checked in its help and accessibility
label. Children retain their existing no-Resume presentation.

```sh
export PI_APP_COST_PAUSE_GALLERY="$PI_BUILD_ROOT/gallery-limit2"
export TEST_RUNNER_PI_APP_COST_PAUSE_GALLERY="$PI_APP_COST_PAUSE_GALLERY"
xcodebuild test-without-building "${X[@]}" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/CostPauseGalleryTests
```

An observation outside LIMIT-2: the fixture's delegated task and reply prose
(`apps/macos/PiAppTests/SubagentGalleryTests.swift:177`) is blank in some dark
child captures, including `child-cost-paused-dark-700.png` (the existing scene),
`child-cost-paused-raised-dark-700.png` and
`child-cost-paused-raised-dark-1240.png`. The cost card and footer draw correctly;
light scenes and the dark 920 scene show the prose. This is a gallery observation,
not a localized production diagnosis; transcript rendering was not changed or
investigated further. It is recorded for the lead's separate UI review.

LIMIT-2 has no product decision pending. The lead's merged release gate remains
separate from this focused validation.
