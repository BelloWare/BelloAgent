# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T16:22:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 0 mixed windows; 0 with endpoints, unavailable union; scopes overlap resources and do not measure Review alone |
| Builds | 1m 5.8s measured command resource time |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | 1m 13.2s measured command resource time |
| Interactive GUI validation | No new completed GUI process receipt |
| CI | 7m 19.0s runner time across 1 completed jobs (1 failed); 7m 19.0s wall union |
| Dependency/environment setup | 26.0s nested CI phase time (already inside CI jobs); command setup shown separately below |
| Retries/rework | Unavailable separately; retained successful checks do not establish zero rework |
| Publication | No isolated API total; 2 mixed windows; 2 with endpoints, 1m 26.8s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 6 | 180.316 | 6 | 180.316 | 180.093 |
| catchup_ci_job | 1 | 439.000 | 1 | 439.000 | 439.000 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: automated accounting validation | 0.223 |
| catchup_command: build + test/check (combined) | 73.232 |
| catchup_command: build | 65.812 |
| catchup_command: automated lint/check | 41.048 |
| catchup_ci_job: ci | 439.000 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|
| CI orchestration | 5.0s |
| dependency/environment setup | 26.0s |
| build + automated lint/check | 3.0s |
| build/test/check (combined) | 6m 43.0s |
| build | 0.0s |
| CI reporting | 0.0s |

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

Within 2026-10-09T16:07:00Z–2026-10-09T16:22:00Z, newly recorded CI jobs cover 439.000 overlap-safe seconds. Remaining time is unclassified, not proven idle or inference.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Root paired timing verification and normal publication (shared once) | 2026-10-09T16:10:52.891Z | 2026-10-09T16:11:26.839Z | 33.948 | completed |
| Root title/ACL follow-on normal source publication and verification | 2026-10-09T16:12:23.579Z | 2026-10-09T16:13:16.455Z | 52.876 | completed |
| Six immutable title/ACL source and evidence blobs created and read back | unknown | unknown | unknown | All six blob SHAs/readbacks verified; individual operation durations unavailable |
| Exact title/ACL follow-on apple-silicon CI status | unknown | unknown | unknown | in_progress at post-cutoff observation 2026-10-09T16:22:13.197Z; final duration unavailable |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Independent duration audit and historical-prefix verification | automated accounting validation | 2026-10-09T16:09:19.730663+00:00 | 2026-10-09T16:09:19.953887+00:00 | 0.22323214300558902 | 0 |
| Combined title/ACL aggregate-default | build + test/check (combined) | 2026-10-09T16:06:24.463321+00:00 | 2026-10-09T16:07:37.695770+00:00 | 73.232449 | 0 |
| Combined title/ACL build-default | build | 2026-10-09T16:08:53.889282+00:00 | 2026-10-09T16:09:27.621437+00:00 | 33.732155 | 0 |
| Combined title/ACL build-synthetic | build | 2026-10-09T16:08:20.186767+00:00 | 2026-10-09T16:08:52.266660+00:00 | 32.079893 | 0 |
| Combined title/ACL clippy-default | automated lint/check | 2026-10-09T16:08:01.475425+00:00 | 2026-10-09T16:08:19.985411+00:00 | 18.509986 | 0 |
| Combined title/ACL clippy-synthetic | automated lint/check | 2026-10-09T16:07:38.344595+00:00 | 2026-10-09T16:08:00.883098+00:00 | 22.538503 | 0 |
| Exact title/ACL follow-on linux CI job | ci | 2026-10-09T16:13:20Z | 2026-10-09T16:20:39Z | 439.0 | failure |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,381 items; 811 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

| Existing resource group | Counted timed items | Resource seconds | Items with endpoints | Endpoint-subset seconds | Subset interval union seconds |
|---|---:|---:|---:|---:|---:|
| ci_job | 186 | 80885.000 | 186 | 80885.000 | 53609.000 |
| incremental_api | 58 | 427.621 | 50 | 389.193 | 254.901 |
| incremental_command | 64 | 956.457 | 39 | 517.000 | 517.000 |
| incremental_ci_job | 2 | 2171.000 | 2 | 2171.000 | 1424.000 |
| new_local_command | 8 | 209.302 | 8 | 209.302 | 209.302 |
| new_api_operation | 7 | 45.653 | 0 | 0.000 | unavailable |
| new_native_command | 75 | 506.149 | 74 | 500.224 | 500.244 |
| catchup_ci_job | 15 | 14100.000 | 15 | 14100.000 | 9666.000 |
| catchup_native_command | 36 | 718.272 | 36 | 718.272 | 718.281 |
| catchup_command | 220 | 5316.364 | 116 | 3247.176 | 3221.160 |
| catchup_api | 118 | 1088.447 | 94 | 810.611 | 424.003 |
| catchup_gui_process | 22 | 2313.456 | 22 | 2313.456 | 2313.456 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
