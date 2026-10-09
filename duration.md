# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T16:07:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 1 mixed windows; 1 with endpoints, 5m 44.4s union; scopes overlap resources and do not measure Review alone |
| Builds | Unavailable separately |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | 1m 56.1s measured command resource time |
| Interactive GUI validation | 2m 25.0s observed process lifetime; overlaps workflow windows, limited acceptance only |
| CI | No new completed job duration in this cohort; prior terminal jobs remain in the ledger and linked history |
| Dependency/environment setup | 387.936ms measured command resource time |
| Retries/rework | 1m 9.7s across 2 failed process/API receipts; total rework effort unavailable |
| Publication | No isolated API total; 1 mixed windows; 1 with endpoints, 43.4s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 9 | 270.192 | 9 | 270.192 | 269.976 |
| catchup_gui_process | 2 | 145.020 | 2 | 145.020 | 145.020 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: automated accounting validation | 0.216 |
| catchup_command: build + test/lint (combined) | 133.307 |
| catchup_command: build + test/check (combined) | 116.088 |
| catchup_command: remote evidence retrieval | 17.599 |
| catchup_command: dependency/environment or verification | 0.388 |
| catchup_command: automated lint/check | 2.594 |
| catchup_gui_process: interactive GUI validation | 145.020 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

This cohort adds no CI job execution intervals; prior verified terminal runs remain in earlier accounting. Coverage of 2026-10-09T15:47:00Z–2026-10-09T16:07:00Z is partial and does not establish an idle-time or inference budget.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Root paired timing verification and normal publication (shared once) | 2026-10-09T15:59:05.961Z | 2026-10-09T15:59:49.391Z | 43.43 | completed |
| Root cross-repository review, timing audit, source verification and coordination (shared once) | 2026-10-09T15:57:11Z | 2026-10-09T16:02:55.430922+00:00 | 344.430922 | completed |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Independent duration audit and historical-prefix verification | automated accounting validation | 2026-10-09T15:57:46.290938+00:00 | 2026-10-09T15:57:46.506864+00:00 | 0.21593388300971128 | 0 |
| Repaired first-frame restart GUI process | interactive GUI validation | 2026-10-09T15:47:29.399043882+00:00 | 2026-10-09T15:49:11.972619442+00:00 | 102.573576 | painted persisted selected102 and five Ready rows with exact synthetic title; exit=0 |
| Repaired first-frame ordinary GUI process | interactive GUI validation | 2026-10-09T15:49:30.429001202+00:00 | 2026-10-09T15:50:12.875862098+00:00 | 42.446861 | painted pending New chat, No connection, Tools unavailable, exact ordinary Bello Agent title; exit=0 |
| ACL diagnostic r1 | build + test/lint (combined) | 2026-10-09T15:55:03.086872+00:00 | 2026-10-09T15:55:55.224274+00:00 | 52.137414324999554 | 101 |
| ACL diagnostic focused-strict | build + test/lint (combined) | 2026-10-09T15:56:38.717248+00:00 | 2026-10-09T15:57:59.886766+00:00 | 81.16952962899813 | 0 |
| ACL diagnostic workflow-check | build + test/check (combined) | 2026-10-09T15:59:36.314807+00:00 | 2026-10-09T15:59:36.447425+00:00 | 0.13262218999443576 | completed |
| Public native CI log recovery request | remote evidence retrieval | 2026-10-09T15:50:20.317112+00:00 | 2026-10-09T15:50:37.916597+00:00 | 17.599489358006394 | Failed HTTP403; no log recovered |
| Combined title/ACL aggregate-synthetic | build + test/check (combined) | 2026-10-09T16:04:27.638132+00:00 | 2026-10-09T16:06:23.477903+00:00 | 115.839771 | 0 |
| Combined title/ACL clean-app | dependency/environment or verification | 2026-10-09T16:04:24.257562+00:00 | 2026-10-09T16:04:24.645498+00:00 | 0.387936 | 0 |
| Combined title/ACL fmt | automated lint/check | 2026-10-09T16:04:24.864532+00:00 | 2026-10-09T16:04:27.458091+00:00 | 2.593559 | 0 |
| Combined title/ACL workflow-check | build + test/check (combined) | 2026-10-09T16:03:28.672892+00:00 | 2026-10-09T16:03:28.788927+00:00 | 0.11603935400489718 | completed |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,370 items; 804 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

| Existing resource group | Counted timed items | Resource seconds | Items with endpoints | Endpoint-subset seconds | Subset interval union seconds |
|---|---:|---:|---:|---:|---:|
| ci_job | 186 | 80885.000 | 186 | 80885.000 | 53609.000 |
| incremental_api | 58 | 427.621 | 50 | 389.193 | 254.901 |
| incremental_command | 64 | 956.457 | 39 | 517.000 | 517.000 |
| incremental_ci_job | 2 | 2171.000 | 2 | 2171.000 | 1424.000 |
| new_local_command | 8 | 209.302 | 8 | 209.302 | 209.302 |
| new_api_operation | 7 | 45.653 | 0 | 0.000 | unavailable |
| new_native_command | 75 | 506.149 | 74 | 500.224 | 500.244 |
| catchup_ci_job | 14 | 13661.000 | 14 | 13661.000 | 9227.000 |
| catchup_native_command | 36 | 718.272 | 36 | 718.272 | 718.281 |
| catchup_command | 214 | 5136.048 | 110 | 3066.860 | 3041.067 |
| catchup_api | 118 | 1088.447 | 94 | 810.611 | 424.003 |
| catchup_gui_process | 22 | 2313.456 | 22 | 2313.456 | 2313.456 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
