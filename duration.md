# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T14:47:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 2 mixed windows; 2 with endpoints, 14m 11.0s union; scopes overlap resources and do not measure Review alone |
| Builds | 19.0s measured command resource time |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | 2m 0.0s measured command resource time |
| Build + negative-control tests | 3m 2.4s measured command resource time; expected caught failures are not implementation failures |
| Interactive GUI validation | No new completed GUI process receipt |
| CI | No new completed job duration in this cohort; prior terminal jobs remain in the ledger and linked history |
| Dependency/environment setup | Unavailable |
| Retries/rework | 12.0s across 1 failed command receipts; total rework effort unavailable |
| Publication | No isolated API total; 2 mixed windows; 2 with endpoints, 9m 31.2s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 9 | 339.336 | 9 | 339.336 | 337.441 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: automated accounting validation | 1.895 |
| catchup_command: build + test/check (combined) | 120.000 |
| catchup_command: automated lint/check | 16.000 |
| catchup_command: build | 19.000 |
| catchup_command: build + negative-control test (combined) | 182.441 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

This cohort adds no CI job execution intervals; prior verified terminal runs remain in earlier accounting. Coverage of 2026-10-09T14:37:00Z–2026-10-09T14:47:00Z is partial and does not establish an idle-time or inference budget.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Prepare, upload and verify paired 14:37 timing candidates | 2026-10-09T14:31:49Z | 2026-10-09T14:40:45Z | 536 | completed |
| Publish paired compact 14:37 timing checkpoint (shared once) | 2026-10-09T14:41:26.999Z | 2026-10-09T14:42:02.204Z | 35.205 | completed |
| Reveal/paint-owner source repair, validation and coordination | 2026-10-09T14:37:00Z | 2026-10-09T14:46:00Z | 540.0 | completed |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Independent final Agent LOC reproduction | automated accounting validation | 2026-10-09T14:43:14.870984+00:00 | 2026-10-09T14:43:16.765603+00:00 | 1.8946233930037124 | passed; full inventory and classification match |
| app-navigation-r28 | build + test/check (combined) | 2026-10-09T14:37:38Z | 2026-10-09T14:37:50Z | 12.0 | 101 |
| app-navigation-r29 | build + test/check (combined) | 2026-10-09T14:38:10Z | 2026-10-09T14:39:07Z | 57.0 | 0 |
| app-navigation-r30 | build + test/check (combined) | 2026-10-09T14:39:39Z | 2026-10-09T14:40:30Z | 51.0 | 0 |
| app-strict-final-r31 | automated lint/check | 2026-10-09T14:40:38Z | 2026-10-09T14:40:54Z | 16.0 | 0 |
| synthetic-build-final-r32 | build | 2026-10-09T14:40:54Z | 2026-10-09T14:41:13Z | 19.0 | 0 |
| pending-hold-credit-erased | build + negative-control test (combined) | 2026-10-09T14:42:02.487326+00:00 | 2026-10-09T14:43:08.792324+00:00 | 66.3050045449927 | Expected negative-control failure; source restored |
| installation-consumes-navigation | build + negative-control test (combined) | 2026-10-09T14:43:08.793460+00:00 | 2026-10-09T14:44:06.195604+00:00 | 57.40215225699649 | Expected negative-control failure; source restored |
| completed-decoration-renavigates | build + negative-control test (combined) | 2026-10-09T14:44:06.196995+00:00 | 2026-10-09T14:45:04.931008+00:00 | 58.734018093004124 | Negative control survived: insufficient assertion; stronger test and rerun pending |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,185 items; 641 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

| Existing resource group | Counted timed items | Resource seconds | Items with endpoints | Endpoint-subset seconds | Subset interval union seconds |
|---|---:|---:|---:|---:|---:|
| ci_job | 186 | 80885.000 | 186 | 80885.000 | 53609.000 |
| incremental_api | 58 | 427.621 | 50 | 389.193 | 254.901 |
| incremental_command | 64 | 956.457 | 39 | 517.000 | 517.000 |
| incremental_ci_job | 2 | 2171.000 | 2 | 2171.000 | 1424.000 |
| new_local_command | 8 | 209.302 | 8 | 209.302 | 209.302 |
| new_api_operation | 7 | 45.653 | 0 | 0.000 | unavailable |
| new_native_command | 75 | 506.149 | 74 | 500.224 | 500.244 |
| catchup_ci_job | 12 | 12690.000 | 12 | 12690.000 | 8705.000 |
| catchup_native_command | 36 | 718.272 | 36 | 718.272 | 718.281 |
| catchup_command | 167 | 4084.798 | 63 | 2015.610 | 2012.698 |
| catchup_api | 24 | 277.836 | 0 | 0.000 | unavailable |
| catchup_gui_process | 2 | 653.507 | 2 | 653.507 | 653.507 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
