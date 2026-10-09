# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T17:10:00Z

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
| Build + test/check (combined) | 2m 56.1s measured command resource time |
| Build + negative-control tests | 37.6s measured command resource time; expected caught failures are not implementation failures |
| Interactive GUI validation | No new completed GUI process receipt |
| CI | No new completed job duration in this cohort; prior terminal jobs remain in the ledger and linked history |
| Dependency/environment setup | 1m 1.2s measured command resource time |
| Retries/rework | Unavailable separately; retained successful checks do not establish zero rework |
| Publication | No isolated API total; 1 mixed windows; 1 with endpoints, 49.9s union |
| Waiting | 1 mixed windows; 1 with endpoints, 2m 41.2s union shared-build-lane constraint; overlaps useful work, not proven idle |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 11 | 317.116 | 10 | 317.116 | 317.116 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: dependency/environment or verification | 61.179 |
| catchup_command: build + negative-control test (combined) | 37.582 |
| catchup_command: build + test/check (combined) | 176.141 |
| catchup_command: automated lint/check | 42.215 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

This cohort adds no CI job execution intervals; prior verified terminal runs remain in earlier accounting. Coverage of 2026-10-09T16:57:00Z–2026-10-09T17:10:00Z is partial and does not establish an idle-time or inference budget.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Root paired timing verification and normal publication (shared once) | 2026-10-09T17:04:20Z | 2026-10-09T17:05:09.937Z | 49.937 | completed |
| Agent shared Cargo lane lower-bound wait | 2026-10-09T16:55:37.242920+00:00 | 2026-10-09T16:58:18.436510+00:00 | 161.19359 | completed |
| Independent root fixture-repair LOC/source review | unknown | unknown | unknown | Review confirmed test-owned delta; isolated duration unavailable |
| Independent fixture-repair review and Python control check | unknown | unknown | unknown | Review/control result retained; elapsed unavailable |
| Fixture/test/documentation source publication paused for required confirmation | unknown | unknown | unknown | Publication worker stopped; per-call outcomes and elapsed unavailable; confirmation pending at observation |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Independent duration audit and historical-prefix verification | automated accounting validation | unknown | unknown | unknown | completed |
| Canonical fixture Core initial-clean | dependency/environment or verification | 2026-10-09T16:58:18.436510+00:00 | 2026-10-09T16:58:18.777550+00:00 | 0.3410487259970978 | 0 |
| Canonical fixture Core focused | dependency/environment or verification | 2026-10-09T16:58:18.778223+00:00 | 2026-10-09T16:59:18.806236+00:00 | 60.02803086998756 | 0 |
| Canonical fixture Core mutant-clean | dependency/environment or verification | 2026-10-09T16:59:18.809747+00:00 | 2026-10-09T16:59:19.236222+00:00 | 0.4265031050017569 | 0 |
| Canonical fixture Core omit-fixture-canonicalization | build + negative-control test (combined) | 2026-10-09T16:59:19.236644+00:00 | 2026-10-09T16:59:56.818841+00:00 | 37.58221474800666 | Expected negative-control failure; source restored |
| Canonical fixture Core restored-clean | dependency/environment or verification | 2026-10-09T16:59:56.822986+00:00 | 2026-10-09T16:59:57.206287+00:00 | 0.3833161590009695 | 0 |
| Canonical fixture Core default | build + test/check (combined) | 2026-10-09T16:59:57.206771+00:00 | 2026-10-09T17:01:16.074812+00:00 | 78.86806167800387 | 0 |
| Canonical fixture Core allfeatures | build + test/check (combined) | 2026-10-09T17:01:16.075886+00:00 | 2026-10-09T17:02:53.348382+00:00 | 97.27251017499657 | 0 |
| Canonical fixture Core strictdefault | automated lint/check | 2026-10-09T17:02:53.349408+00:00 | 2026-10-09T17:03:11.447706+00:00 | 18.09831485399627 | 0 |
| Canonical fixture Core strictall | automated lint/check | 2026-10-09T17:03:11.448203+00:00 | 2026-10-09T17:03:33.133887+00:00 | 21.685701048001647 | 0 |
| Canonical fixture Core fmt | automated lint/check | 2026-10-09T17:03:33.134382+00:00 | 2026-10-09T17:03:35.565074+00:00 | 2.4307111170055578 | 0 |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,443 items; 861 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

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
| catchup_command | 255 | 5964.104 | 150 | 3894.917 | 3868.522 |
| catchup_api | 130 | 1191.607 | 106 | 913.771 | 460.507 |
| catchup_gui_process | 22 | 2313.456 | 22 | 2313.456 | 2313.456 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
