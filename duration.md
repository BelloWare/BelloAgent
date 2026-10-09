# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T16:37:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 1 mixed windows; 1 with endpoints, 11m 56.6s union; scopes overlap resources and do not measure Review alone |
| Builds | Unavailable separately |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | 3m 18.0s measured command resource time |
| Interactive GUI validation | No new completed GUI process receipt |
| CI | 12m 21.0s runner time across 1 completed jobs (1 failed); 12m 21.0s wall union |
| Dependency/environment setup | 17.0s nested CI phase time (already inside CI jobs); command setup shown separately below |
| Retries/rework | Unavailable separately; retained successful checks do not establish zero rework |
| Publication | No isolated API total; 1 mixed windows; 1 with endpoints, 1m 0.2s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 9 | 239.812 | 9 | 239.812 | 239.812 |
| catchup_ci_job | 1 | 741.000 | 1 | 741.000 | 741.000 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: automated accounting validation | 0.154 |
| catchup_command: build + test/check (combined) | 198.000 |
| catchup_command: dependency/environment or verification | 0.278 |
| catchup_command: automated lint/check | 41.381 |
| catchup_ci_job: ci | 741.000 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|
| CI orchestration | 7.0s |
| dependency/environment setup | 17.0s |
| build/test/check (combined) | 11m 55.0s |
| build | 0.0s |

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

Within 2026-10-09T16:22:00Z–2026-10-09T16:37:00Z, newly recorded CI jobs cover 227.000 overlap-safe seconds. Remaining time is unclassified, not proven idle or inference.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Root paired timing verification and normal publication (shared once) | 2026-10-09T16:24:55.180Z | 2026-10-09T16:25:55.425Z | 60.245 | completed |
| Root cross-repository package review, publication, failure investigation, coordination and waits (shared once) | 2026-10-09T16:21:26Z | 2026-10-09T16:33:22.579839+00:00 | 716.579839 | completed |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Independent duration audit and historical-prefix verification | automated accounting validation | 2026-10-09T16:23:38.513477+00:00 | 2026-10-09T16:23:38.667288+00:00 | 0.1538214720058022 | 0 |
| Exact title/ACL follow-on apple-silicon CI job | ci | 2026-10-09T16:13:26Z | 2026-10-09T16:25:47Z | 741.0 | failure |
| CI fixture repair script-controls | build + test/check (combined) | 2026-10-09T16:30:25.585434+00:00 | 2026-10-09T16:30:25.700512+00:00 | 0.1150884689996019 | 0 |
| CI fixture repair package-clean | dependency/environment or verification | 2026-10-09T16:30:25.701040+00:00 | 2026-10-09T16:30:25.978529+00:00 | 0.277506327998708 | 0 |
| CI fixture repair focused | build + test/check (combined) | 2026-10-09T16:30:25.979108+00:00 | 2026-10-09T16:31:24.382027+00:00 | 58.40293668699451 | 0 |
| CI fixture repair allfeatures | build + test/check (combined) | 2026-10-09T16:31:24.384158+00:00 | 2026-10-09T16:32:41.864600+00:00 | 77.48045678100607 | 0 |
| CI fixture repair default | build + test/check (combined) | 2026-10-09T16:32:41.866208+00:00 | 2026-10-09T16:33:43.868016+00:00 | 62.00182438199408 | 0 |
| CI fixture repair strictall | automated lint/check | 2026-10-09T16:33:43.870456+00:00 | 2026-10-09T16:34:05.780661+00:00 | 21.9102432540094 | 0 |
| CI fixture repair strictdefault | automated lint/check | 2026-10-09T16:34:05.781501+00:00 | 2026-10-09T16:34:22.774708+00:00 | 16.993223752011545 | 0 |
| CI fixture repair fmt | automated lint/check | 2026-10-09T16:34:22.775663+00:00 | 2026-10-09T16:34:25.252763+00:00 | 2.477112577005755 | 0 |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,393 items; 821 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

| Existing resource group | Counted timed items | Resource seconds | Items with endpoints | Endpoint-subset seconds | Subset interval union seconds |
|---|---:|---:|---:|---:|---:|
| ci_job | 186 | 80885.000 | 186 | 80885.000 | 53609.000 |
| incremental_api | 58 | 427.621 | 50 | 389.193 | 254.901 |
| incremental_command | 64 | 956.457 | 39 | 517.000 | 517.000 |
| incremental_ci_job | 2 | 2171.000 | 2 | 2171.000 | 1424.000 |
| new_local_command | 8 | 209.302 | 8 | 209.302 | 209.302 |
| new_api_operation | 7 | 45.653 | 0 | 0.000 | unavailable |
| new_native_command | 75 | 506.149 | 74 | 500.224 | 500.244 |
| catchup_ci_job | 16 | 14841.000 | 16 | 14841.000 | 9974.000 |
| catchup_native_command | 36 | 718.272 | 36 | 718.272 | 718.281 |
| catchup_command | 229 | 5556.176 | 125 | 3486.989 | 3460.972 |
| catchup_api | 118 | 1088.447 | 94 | 810.611 | 424.003 |
| catchup_gui_process | 22 | 2313.456 | 22 | 2313.456 | 2313.456 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
