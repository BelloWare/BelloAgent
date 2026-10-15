# Side-keep recovery · 0.1.128

Branch: `dev/a128-side-keep`; worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-fork-subagents`.
Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-fork-subagents`.
All evidence paths below are relative to that build root. Generated fixtures only; the owner's files were not read. No installed app, real preferences, Keychain or paid provider was used.

## Confirmed causes and candidate checks

`registerKeptSide` called `HistoryReader.validateIdentity`, which required both a matching version-3 session header **and an entirely warning-free history read**. A legitimate kept chat could fail permanently because its last write was cut off or a later record was damaged, even though the ordinary history opener could display it safely. `reconcileSideKeeps` retained that pending copy and replaced the global error for each failure on every launch, without naming the chat or providing a way to resolve it.

The first seven generated-fixture tests ran against the original implementation: **13 assertion failures in four test methods** (`logs/side-keep-red.log`). They demonstrate rejected streaming/tool tails, rejected later damage, unnecessary history indexing during identity validation, and the separate lost-registration bug when the file has not appeared yet. Three candidate checks already passed before the fix.

| Candidate | Finding |
|---|---|
| Quit during streaming / a tool call | A generated incomplete final record reproduces rejection in both cases. After registration, normal open shows its existing read-only cut-off-record recovery notice; no helper starts or bytes change. This does not establish which write the owner's app was performing. |
| Damage after a valid header | Confirmed: even the reader's recoverable “Damaged history record preserved” notice blocked registration. Now registered for the existing recovery path, without repairing the file. |
| V3 sub-agent marker, custom records, typed parent/child messages | No extra reader damage reproduced. The reader already recognizes v1/v2/v3 markers and ignores coordination metadata while projecting typed message rows. Generated normal/kept v3 histories with both authors and a fork context pass. Ephemeral sides cannot delegate before they have a journal; kept sides can. No helper/tool/model-visible semantics changed. |
| Fork / compaction / checkpoint | Existing clone fixture and generated promoted compaction fixture read and validate identity with and without checkpoint metadata. No defect reproduced here; the merged fork repair remains intact. |
| Symlink / path spelling | The existing `sameFile` comparison already resolves symlinks. Alias registration succeeds without rewriting bytes; a separate file cannot substitute for the expected path. |
| Intent before file publication | Separate confirmed bug: the original reconciler deleted the pending registration when the file was absent, losing a later publication. It now preserves the reminder and Check again (or the next launch) completes registration when the matching file appears. |
| Archived / renamed chat | Registration preserves the existing title and archived state. No failure reproduced. |
| Deleted / moved file | A genuinely absent file cannot be registered. It now stays named and actionable, without creating a placeholder file. Show file in Finder selects its nearest existing folder. |
| Copied/renamed path with a different header ID | Correct refusal, now explained as “The file belongs to a different chat.” Renaming the file does not change its chat identity. |
| Missing, cut-off, malformed or unsupported-version header | Correct refusal, with a specific plain reason. Files remain untouched, and the notice can be dismissed. A missing stored path also gets an actionable notice rather than being silently ignored. |

## Implementation and decisions

- Identity admission reads at most 64 KiB for the first header and checks type, ID and version. It no longer indexes transcript bodies or conflates their notices with identity. The normal open/recovery and automatic-context safety checks remain in force.
- One bounded Pi notice lists every failed copy, its name, available parent name, reason and file path. It is separate from transient global errors. Live keep failures with saved metadata use the same notice. Successful registration retires its item; a resolution revision prevents an in-flight check from restoring a settled item.
- **Open anyway inspects the original file in the existing read-only file tab.** It does not bypass identity checking, create a chat, adopt foreign children, or start a helper. The file viewer retains its existing trust rules. The notice explicitly describes this behavior.
- **Dismiss removes only the saved pending-registration record**, after a custom Pi confirmation naming the chat and stating that any existing file stays on disk. Cancel, Escape and Return cancel. The store compares the exact reviewed copy before removing it, so an old confirmation cannot dismiss a replacement. Files, chat records, drafts and other metadata are retained. Dismissed items do not return after relaunch.
- No automatic journal repair, file move or deletion, journal-format change, new persistence of unkept side drafts, capture/vault change or tool/parity change. No helper source changed.

## Validation

| Check | Result | Evidence |
|---|---|---|
| Affected native classes, all restored guards | **56 passed, 0 failures**: `SideKeepRecoveryTests` 15, `SideTests` 15, `WorkspaceDurabilityTests` 7, `HistoryReaderCheckpointTests` 7, `ForkCloneReaderTests` 1, `AutomaticContextTests` 11 | `logs/side-keep-restored.log` |
| Restore the old reconciliation method | **Caught:** 15 tests, 23 failed assertions for missing/unnamed notices, overwritten errors and dropped pending copies | `logs/side-keep-mutation-old-reconciliation.log` |
| Reinstate rejection on any history warning | **Caught:** 15 tests, 11 failed assertions | `logs/side-keep-mutation-history-warning.log` |
| Bypass the real matching-ID guard | **Caught:** 15 tests, 18 failed assertions | `logs/side-keep-mutation-identity.log` |
| Bypass the real reviewed-copy guard before Dismiss | **Caught:** 15 tests, 3 failed assertions for deleting a replacement | `logs/side-keep-mutation-dismiss.log` |
| Restore Dismiss after the last mutation | **15 passed, 0 failures** | `logs/side-keep-restored-dismiss.log` |

The native classes use `PI_BUILD_ROOT=<build-root> scripts/test-macos.sh -only-testing:PiAppTests/<Class>`. All six affected classes belong to the parallel lane; the gallery class is serial and runs alone. Helper source was untouched, so no extra helper-package run was needed. All three mutated production files were compared byte-for-byte with their pre-mutation copies before the full lane. Initial mutation-harness failures (an empty-fixture array access and an unused local rejected by warnings-as-errors) were corrected; only the subsequent behavioral mutation runs above are counted.

The **one full native parallel lane passed: 2,473 passed, 37 skipped, 0 failures (2,510 total)**, with four workers and the exact skip list saved in `logs/side-keep-parallel-arguments.txt`. Evidence: `logs/side-keep-native-parallel.log` and the result-bundle summary in `logs/side-keep-native-parallel-summary.json`. It ran after affected tests, restored mutations and gallery inspection; no code changed afterwards. No validation failures remain.

The standalone `SideKeepGalleryTests` passes **1/1** (`logs/side-keep-gallery.log`). Command:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-fork-subagents \
TEST_RUNNER_PI_APP_SIDE_KEEP_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-fork-subagents/gallery-side-keep \
scripts/test-macos.sh -only-testing:PiAppTests/SideKeepGalleryTests
```

All **10 PNGs were opened and inspected**: `gallery-side-keep/notice-{light,dark}-{1240x600,920x600,300}.png` and `gallery-side-keep/dismiss-{light,dark}-{920,300}.png`. The narrow notice stacks actions and scrolls the remaining items; all confirmation actions and its file-preservation text fit. Controls are custom Pi buttons with named VoiceOver labels and native keyboard activation.

## Review round 1: dismissal and registration ordering (2026-10-15)

The independent review identified two stale-snapshot bugs. Registration captured a pending copy, suspended for its header read, then committed chat/draft metadata unconditionally even if Dismiss had removed that copy. Dismissal removed the visible notice by full presentation equality, so a changed reason or parent title could leave a reminder behind after its saved pending record was removed.

Eight generated-fixture ordering tests ran before the fix: **12 assertion failures in five methods**, with three existing safe orderings passing (`logs/side-keep-review-red.log`). A generated FIFO pauses the actual `HistoryReader.validateIdentity` read after the pending copy is captured; the test completes dismissal or replacement, publishes the valid fixture and releases the read. No production timing hook or fixed scheduling sleep substitutes for the race.

The store now checks the exact captured `ChatRecord` inside the same `BEGIN IMMEDIATE` transaction that saves the chat/draft and consumes the pending record. The comparison uses the original snapshot, before canonical-path and organization changes, preserving alias registration and parent-topic moves. Dismissal also compares/removes within a transaction. Missing or replaced copies reject the old commit without any chat/draft writes. Existing topic tests now seed the pending records required by the real registration path.

Notice removal compares the reviewed chat snapshot, independently of its reason or parent title. Successful registration likewise removes only its own snapshot's notice. Live failure reporting respects the resolution revision and ignores obsolete registration errors. Accepted dismissals retain process-local tokens for delayed live receipts; a failed confirmation removes only its own token. A new pending copy still gets its own notice. Nothing about an unkept side is persisted by those tokens.

| Ordering audited | Required result |
|---|---|
| Dismiss during a captured registration's header read | No chat is registered; the existing draft and journal bytes remain unchanged; another reconciliation cannot resurrect it. |
| Replacement during the old header read | The old commit is refused; the replacement remains pending and subsequently registers its own path. Both files remain unchanged. |
| Registration before the confirmation answer | Dismiss removes only the reminder; the registered chat and newer typing remain saved. |
| Reason/parent title refresh while confirmation is open | The same reviewed copy is dismissed and its refreshed notice disappears. |
| Different copy replaces the reviewed one | The old confirmation is refused and the replacement's current notice remains. |
| Dismiss an earlier failure while another file is being checked | The reconciliation resolution revision prevents the collected old notice from returning. |
| Duplicate registration after a successful commit | The consumed intent cannot commit again or overwrite a newer draft. |
| Live receipts after Dismiss | No automatic registration or renewed warning. An unexpected receipt that was never dismissed still reports its existing error. |

The first affected run passed 69/70: the existing durability test exposed an overly broad suppression of unexpected live receipts (`logs/side-keep-review-green.log`). The final implementation distinguishes explicit dismissal with process-local tokens and retains that test's original warning assertion.

| Real production mutation | Result (each run executes all 8 ordering tests) | Evidence |
|---|---|---|
| Remove the transaction's pending-copy guard | **Caught:** 10 assertion failures in 3 methods (dismissed registration, replacement consumption, newer-draft overwrite). | `logs/side-keep-review-mutation-registration.log` |
| Keep presence checking but remove snapshot equality | **Caught:** 5 assertion failures in the replacement test. | `logs/side-keep-review-mutation-snapshot.log` |
| Restore full `SideKeepIssue` equality for notice removal | **Caught:** 1 assertion failure after reason/parent-title refresh. | `logs/side-keep-review-mutation-notice.log` |

Both mutated production files were restored byte-for-byte before final verification. This review changes no scene layout, journal/helper format, tool/capture/vault boundary or persisted side-draft policy. Per the review request, only affected native classes run; the earlier gallery and full-lane evidence above belongs to the initial implementation and is not claimed as a new review run.

Final restored verification: **70 passed, 0 failed**, using `PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-fork-subagents scripts/test-macos.sh` with seven `-only-testing:PiAppTests/<Class>` arguments: `SideKeepOrderingTests` (8), `SideKeepRecoveryTests` (15), `SideTests` (15), `WorkspaceDurabilityTests` (7), `TopicStorageTests` (17), `SideRelaunchTests` (3), and `ForkFromReplyTests` (5). All seven are in the parallel lane according to `python3 scripts/test-lanes.py list`. Evidence: `logs/side-keep-review-restored.log`. No review validation failures remain. No helper or gallery source changed, so those suites were not repeated.

## Remaining limits

The particular cause in the owner's private file is unknown; no access was requested or used. Irrecoverable/mismatched identities are deliberately not guessed or silently adopted. The user can inspect their unchanged file, reveal its location, or dismiss the reminder. Missing files cannot be reconstructed by this change.
