# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T13:47:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 2 mixed windows; 2 with endpoints, 15m 52.0s union; scopes overlap resources and do not measure Review alone |
| Builds | Unavailable separately |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | 5m 7.1s measured command resource time |
| Interactive GUI validation | No new completed GUI process receipt |
| CI | No new completed job duration in this cohort; prior terminal jobs remain in the ledger and linked history |
| Dependency/environment setup | 1.0s measured command resource time |
| Retries/rework | 1m 10.0s across 2 failed command receipts; total rework effort unavailable |
| Publication | No isolated API total; 2 mixed windows; 2 with endpoints, 8m 52.0s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 9 | 329.989 | 4 | 133.281 | 133.179 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: build + test/check (combined) | 307.108 |
| catchup_command: automated lint/check | 21.740 |
| catchup_command: dependency/environment or verification | 1.039 |
| catchup_command: automated accounting validation | 0.102 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

This cohort adds no CI job execution intervals; prior verified terminal runs remain in earlier accounting. Coverage of 2026-10-09T13:37:00Z–2026-10-09T13:47:00Z is partial and does not establish an idle-time or inference budget.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Prepare, upload and verify paired 13:37 timing candidates | 2026-10-09T13:31:08Z | 2026-10-09T13:38:55Z | 467 | completed |
| Publish paired 13:37 timing checkpoint (shared once) | 2026-10-09T13:39:05Z | 2026-10-09T13:40:10Z | 65 | completed |
| Ongoing sidebar integration observed source workflow segment | 2026-10-09T13:36:00+00:00 | 2026-10-09T13:47:00Z | 660.0 | completed |
| App next validation phase | unknown | unknown | unknown | App source fixes active; Core owns build lane for reseal |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| core-all-features-retry-j1 | build + test/check (combined) | unknown | unknown | 96.05344729300123 | 0 |
| core-default-resealed | build + test/check (combined) | unknown | unknown | 77.87568292600918 | 0 |
| core-strict-resealed | automated lint/check | unknown | unknown | 20.808428161006304 | 0 |
| dependency-union-resealed | dependency/environment or verification | unknown | unknown | 1.0389979439933086 | 0 |
| core-fmt-resealed | automated lint/check | unknown | unknown | 0.9319743850064697 | 0 |
| selected-piece-digest-r1 | build + test/check (combined) | 2026-10-09T13:41:54.771925+00:00 | 2026-10-09T13:42:57.950612+00:00 | 63.17870601399045 | 0 |
| Independent compact accounting audit reproduction (shared once) | automated accounting validation | 2026-10-09T13:44:42.400716+00:00 | 2026-10-09T13:44:42.502884+00:00 | 0.10218544100644067 | passed; exact result matched, ledger unchanged |
| cargo test -p bello-agent-app --features synthetic-authority sidebar_ -- --nocapture | build + test/check (combined) | 2026-10-09T13:43:36Z | 2026-10-09T13:43:59Z | 23.0 | compile failed E0505 deferred-notice Rc borrow; fixed in r8 |
| cargo test -p bello-agent-app --features synthetic-authority sidebar_ -- --nocapture | build + test/check (combined) | 2026-10-09T13:44:12Z | 2026-10-09T13:44:59Z | 47.0 | 99 passed,1 failed: unopened normal open revoked loaded receipt before reveal admission; bounded fresh same-lane reacquisition now added, not yet executed |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,106 items; 586 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

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
| catchup_command | 114 | 2435.468 | 10 | 366.281 | 366.179 |
| catchup_api | 24 | 277.836 | 0 | 0.000 | unavailable |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
