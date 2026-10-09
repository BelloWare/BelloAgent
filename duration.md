# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T13:57:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 2 mixed windows; 2 with endpoints, 13m 50.0s union; scopes overlap resources and do not measure Review alone |
| Builds | Unavailable separately |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | 4m 0.5s measured command resource time |
| Interactive GUI validation | No new completed GUI process receipt |
| CI | No new completed job duration in this cohort; prior terminal jobs remain in the ledger and linked history |
| Dependency/environment setup | 0.8s measured command resource time |
| Retries/rework | Unavailable separately; retained successful checks do not establish zero rework |
| Publication | No isolated API total; 2 mixed windows; 2 with endpoints, 8m 11.0s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 7 | 263.632 | 7 | 263.632 | 263.632 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: build + test/check (combined) | 240.507 |
| catchup_command: automated lint/check | 22.317 |
| catchup_command: dependency/environment or verification | 0.809 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

This cohort adds no CI job execution intervals; prior verified terminal runs remain in earlier accounting. Coverage of 2026-10-09T13:47:00Z–2026-10-09T13:57:00Z is partial and does not establish an idle-time or inference budget.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Audit compact renderer, prepare and verify paired 13:47 timing candidates | 2026-10-09T13:42:10Z | 2026-10-09T13:49:54Z | 464 | completed |
| Publish paired compact 13:47 timing checkpoint (shared once) | 2026-10-09T13:50:36.350Z | 2026-10-09T13:51:03.352Z | 27.002 | completed |
| Ongoing sidebar integration observed source workflow segment | 2026-10-09T13:47:00+00:00 | 2026-10-09T13:56:00Z | 540.0 | completed |
| Retrospective App r5–r10 build-job setting correction | unknown | unknown | unknown | All r5–r10 phase commands requested jobs1 at caller, but sourced env.sh reset effective CARGO_BUILD_JOBS=2. Commands succeeded or failed as recorded; no jobs1 claim. Script fixed13:52:18 to preserve caller value for subsequent commands. |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| core-all-features-sealed | build + test/check (combined) | 2026-10-09T13:45:49.583374+00:00 | 2026-10-09T13:46:26.665701+00:00 | 37.08235764999699 | 0 |
| core-default-sealed | build + test/check (combined) | 2026-10-09T13:46:26.666221+00:00 | 2026-10-09T13:47:49.090686+00:00 | 82.42449036700418 | 0 |
| core-strict-sealed | automated lint/check | 2026-10-09T13:47:49.091126+00:00 | 2026-10-09T13:48:10.479921+00:00 | 21.38881884100556 | 0 |
| dependency-union-sealed | dependency/environment or verification | 2026-10-09T13:48:10.480307+00:00 | 2026-10-09T13:48:11.288812+00:00 | 0.808527746994514 | 0 |
| core-fmt-sealed | automated lint/check | 2026-10-09T13:48:11.289463+00:00 | 2026-10-09T13:48:12.217556+00:00 | 0.9281179259996861 | 0 |
| cargo test -p bello-agent-app --features synthetic-authority sidebar_ -- --nocapture | build + test/check (combined) | 2026-10-09T13:48:28Z | 2026-10-09T13:49:16Z | 48.0 | 102 sidebar tests passed; evolving integration |
| cargo test -p bello-agent-app --all-features | build + test/check (combined) | 2026-10-09T13:49:29Z | 2026-10-09T13:50:42Z | 73.0 | 809 all-feature App tests passed,3 ignored; evolving integration before later Find/geometry/fixture changes |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,117 items; 593 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

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
| catchup_command | 121 | 2699.101 | 17 | 629.913 | 629.811 |
| catchup_api | 24 | 277.836 | 0 | 0.000 | unavailable |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
