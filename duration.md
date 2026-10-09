# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T16:57:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 0 mixed windows; 0 with endpoints, unavailable union; scopes overlap resources and do not measure Review alone |
| Builds | Unavailable separately |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | Unavailable |
| Interactive GUI validation | No new completed GUI process receipt |
| CI | 7m 52.0s runner time across 1 completed jobs (1 failed); 7m 52.0s wall union |
| Dependency/environment setup | 15.0s nested CI phase time (already inside CI jobs); command setup shown separately below |
| Retries/rework | Unavailable separately; retained successful checks do not establish zero rework |
| Publication | No isolated API total; 1 mixed windows; 1 with endpoints, 1m 22.6s union |
| Waiting | 1 mixed windows; 0 with endpoints, unavailable union shared-build-lane constraint; overlaps useful work, not proven idle |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 7 | 1.090 | 7 | 1.090 | 1.090 |
| catchup_ci_job | 1 | 472.000 | 1 | 472.000 | 472.000 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: automated accounting validation | 0.201 |
| catchup_command: test execution (existing script) | 0.290 |
| catchup_command: negative-control test (existing script) | 0.600 |
| catchup_ci_job: ci | 472.000 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|
| CI orchestration | 8.0s |
| dependency/environment setup | 15.0s |
| build/test/check (combined) | 7m 27.0s |
| build | 0.0s |

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

Within 2026-10-09T16:47:00Z–2026-10-09T16:57:00Z, newly recorded CI jobs cover 141.000 overlap-safe seconds. Remaining time is unclassified, not proven idle or inference.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Root paired timing verification, publication and intervening coordination (shared once) | 2026-10-09T16:49:26.630Z | 2026-10-09T16:50:49.265Z | 82.635 | completed |
| Observed shared Cargo lane queue: canonical source fixture and CI root-parent repair | 2026-10-09T16:55:37.242920+00:00 | unknown | unknown | Open lower-bound queue observation; earlier entry time unknown |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Independent duration audit and historical-prefix verification | automated accounting validation | 2026-10-09T16:48:02.684490+00:00 | 2026-10-09T16:48:02.885450+00:00 | 0.20096693398954812 | 0 |
| Exact fixture repair apple-silicon CI job | ci | 2026-10-09T16:41:29Z | 2026-10-09T16:49:21Z | 472.0 | failure |
| Fixture root routing all_fixture_and_root_routing_controls | test execution (existing script) | 2026-10-09T16:49:29.156481+00:00 | 2026-10-09T16:49:29.295764+00:00 | 0.13928769501217175 | 0 |
| Fixture root routing wrong-create-parent | negative-control test (existing script) | 2026-10-09T16:49:29.296122+00:00 | 2026-10-09T16:49:29.466323+00:00 | 0.17021593400568236 | Expected negative-control failure; source restored |
| Fixture root routing omit-cleanup-parent | negative-control test (existing script) | 2026-10-09T16:49:29.466789+00:00 | 2026-10-09T16:49:29.640104+00:00 | 0.17332828999496996 | Expected negative-control failure; source restored |
| Initial fixture root routing all_fixture_and_root_routing_controls | test execution (existing script) | 2026-10-09T16:49:15.717315+00:00 | 2026-10-09T16:49:15.867748+00:00 | 0.15043557800527196 | 0 |
| Initial fixture root routing wrong-create-parent | negative-control test (existing script) | 2026-10-09T16:49:15.868231+00:00 | 2026-10-09T16:49:15.993978+00:00 | 0.12575965801079292 | Observed exit1 plus generic AssertionError matcher; original raw stack unavailable |
| Initial fixture root routing omit-cleanup-parent | negative-control test (existing script) | 2026-10-09T16:49:15.994423+00:00 | 2026-10-09T16:49:16.124794+00:00 | 0.13038140500430018 | Observed exit1 plus specific non-root cleanup-parent rejection matcher; original raw log unavailable |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,427 items; 850 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

| Existing resource group | Counted timed items | Resource seconds | Items with endpoints | Endpoint-subset seconds | Subset interval union seconds |
|---|---:|---:|---:|---:|---:|
| ci_job | 186 | 80885.000 | 186 | 80885.000 | 53609.000 |
| incremental_api | 58 | 427.621 | 50 | 389.193 | 254.901 |
| incremental_command | 64 | 956.457 | 39 | 517.000 | 517.000 |
| incremental_ci_job | 2 | 2171.000 | 2 | 2171.000 | 1424.000 |
| new_local_command | 8 | 209.302 | 8 | 209.302 | 209.302 |
| new_api_operation | 7 | 45.653 | 0 | 0.000 | unavailable |
| new_native_command | 75 | 506.149 | 74 | 500.224 | 500.244 |
| catchup_ci_job | 18 | 15351.000 | 18 | 15351.000 | 10451.000 |
| catchup_native_command | 36 | 718.272 | 36 | 718.272 | 718.281 |
| catchup_command | 244 | 5646.988 | 140 | 3577.800 | 3551.406 |
| catchup_api | 130 | 1191.607 | 106 | 913.771 | 460.507 |
| catchup_gui_process | 22 | 2313.456 | 22 | 2313.456 | 2313.456 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
