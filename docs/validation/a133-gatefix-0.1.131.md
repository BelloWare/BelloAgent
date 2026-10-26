# Release-gate test corrections — 0.1.132 (planned as 0.1.131)

Workstream `dev/a133-gatefix`, based on `dev/next` `6dbaa1d4`.
Build and text evidence: `/Users/admin/Library/Caches/BelloSwiftWork/build-a133-gatefix/evidence/`.
The owner's scope override allows only the five affected classes, with no full
lanes, mutations or measurements. No product code, `project.yml` or release
notes change. Generated fixtures, the isolated test host and memory vaults only.

## Reproduction and causes

The supplied reruns at `6dbaa1d4` reproduce all seven assigned test methods:
`/Users/admin/Library/Caches/BelloSwiftWork/build-lead/rerun-132/parallel.log`
(the three submission tests and Hardening) and `serial.log` (the other three).
These logs are the before evidence; they were not rerun merely to duplicate it.

1. **SubmissionPersistenceTests — test premises, no lost-input product bug.**
   Reviewed `git log 48d05d30..HEAD`, EDIT-1 `5cc302e4`, EDIT-3 `b98df0d6`,
   PASTE-2 `43655daa` and EDIT-2 `732f0b27`. The relevant change is EDIT-3's
   `f80d0c12`: `draftChanged` now calls `preserveDraftConflicts` before saving
   the normal composer, as flush already did. That method also commits pinned
   submissions as independent `pending:<session>` records, then releases their
   pins only after the transaction commits. A draft-write failure can therefore
   coexist with a successfully saved intent; after the transaction-start lock
   is released, later typing can save it too. The old recovery assertions still
   required an in-memory pin. They now require either the exact durable intent
   or its pin, while retaining no-dispatch, visible recovery, cancellation,
   failed insertion/retirement, successful recovery/discard and no-resurrection
   checks. A held transaction lock still explicitly requires no durable record.
   The hydration/flush test installed its pending-record failure trigger after
   the debounce had already saved the input; it now injects the failure before
   that debounce, keeping the strict pin, non-uncertain and quit/flush refusal
   assertions. EDIT-1 only resumes edit preparation at the relevant draft
   restore points; PASTE-2's import reservation and EDIT-2's preparation reads
   do not explain these failures. The 0.1.130 durability guarantee remains.
2. **HardeningTests — test premise.** STREAM-1 opens a smaller first page and
   reads a full page on Latest. This fixture therefore holds 63 rows initially
   and 253 on Latest. Both counts now derive from the policy's opening/full
   row and byte budgets, metadata allowance and resident row weight. Anchor,
   bounds, paging, search/copy and no-host assertions remain.
3. **SubagentMarkdownTests — test premise.** The 165-row fixture fits inside
   the new opening page. This test pins its page limit to 60 rows and restores
   the prior limits afterward, so the agent result really starts unloaded.
   The original four rendered-prose searches and reveal assertions remain.
4. **TranscriptBugRegressionTests — test premise.** IMG-1 deliberately renders
   image-only rows as thumbnails with no visible text, while copy/Find retain
   `Image` or `2 images`, as recorded in `a131-img-0.1.131.md`. The test asserts
   both sides of that difference for image-only rows. All other saved/live
   projection-to-row equality checks remain.
5. **SessionTimingTests — test premise.** The visible clock starts at 19 seconds
   but OCR can finish after 29 seconds (40 seconds in the supplied rerun). The
   regex accepts readings from 19 seconds onward, including minutes and hours;
   action, usage, rate and width assertions remain.

## Validation

Each complete class runs separately with parallel testing disabled:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a133-gatefix scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubmissionPersistenceTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a133-gatefix scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/HardeningTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a133-gatefix scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentMarkdownTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a133-gatefix scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a133-gatefix scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionTimingTests
```

`scripts/test-lanes.py list` classifies SubmissionPersistence and Hardening as
parallel, and the other three as serial. Each serial class holds the shared
full-lane lock for its run; the lock was released afterward.

| Complete class | Passed | Failed / skipped | Text log |
| --- | ---: | ---: | --- |
| SubmissionPersistenceTests | 81 | 0 / 0 | `submission.log` |
| HardeningTests | 12 | 0 / 0 | `HardeningTests.log` |
| SubagentMarkdownTests | 19 | 0 / 0 | `SubagentMarkdownTests.log` |
| TranscriptBugRegressionTests | 124 | 0 / 0 | `TranscriptBugRegressionTests.log` |
| SessionTimingTests | 26 | 0 / 0 | `SessionTimingTests.log` |
| **Total** | **262** | **0 / 0** | |

All five commands exited 0. All seven assigned methods change from failing
in the supplied baseline reruns to passing. `git diff --check` passes. No
additional suites, mutation runs, measurements or production changes were
needed; no unresolved failure remains in the requested scope.
