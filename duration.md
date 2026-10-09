# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T14:07:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 3 mixed windows; 3 with endpoints, 13m 15.0s union; scopes overlap resources and do not measure Review alone |
| Builds | Unavailable separately |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | 3m 0.0s measured command resource time |
| Interactive GUI validation | No new completed GUI process receipt |
| CI | No new completed job duration in this cohort; prior terminal jobs remain in the ledger and linked history |
| Dependency/environment setup | Unavailable |
| Retries/rework | 1m 38.0s across 3 failed command receipts; total rework effort unavailable |
| Publication | No isolated API total; 2 mixed windows; 2 with endpoints, 7m 33.0s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 8 | 216.020 | 8 | 216.020 | 216.020 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: implementation tool execution | 0.001 |
| catchup_command: implementation + structural validation tool execution | 0.019 |
| catchup_command: build + test/check (combined) | 180.000 |
| catchup_command: automated lint/check | 36.000 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

This cohort adds no CI job execution intervals; prior verified terminal runs remain in earlier accounting. Coverage of 2026-10-09T13:57:00Z–2026-10-09T14:07:00Z is partial and does not establish an idle-time or inference budget.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Prepare, upload and verify paired 13:57 timing candidates with terminal CI receipts | 2026-10-09T13:53:45Z | 2026-10-09T14:00:12Z | 387 | completed |
| Publish paired compact 13:57 timing checkpoint (shared once) | 2026-10-09T14:00:40.356Z | 2026-10-09T14:01:46.399Z | 66.043 | completed |
| Root review, CI edits, cross-repository coordination and tool waits (shared once) | 2026-10-09T13:56:36Z | 2026-10-09T14:06:32.356139+00:00 | 596.356139 | completed |
| Ongoing sidebar integration observed source workflow segment | 2026-10-09T13:56:00+00:00 | 2026-10-09T14:07:00Z | 660.0 | completed |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| workflow-edit | implementation tool execution | 2026-10-09T13:57:19.943747+00:00 | 2026-10-09T13:57:19.945041+00:00 | 0.0012905570038128644 | completed tool operation; native execution pending |
| workflow-final | implementation + structural validation tool execution | 2026-10-09T13:57:35.624132+00:00 | 2026-10-09T13:57:35.642832+00:00 | 0.018711002005147748 | completed tool operation; native execution pending |
| app-focused-r11 | build + test/check (combined) | 2026-10-09T13:56:58Z | 2026-10-09T13:57:10Z | 12.0 | compile failed: test ListOffset lacks PartialEq; fixed field assertions and launcher unused import |
| app-focused-r12 | build + test/check (combined) | 2026-10-09T13:58:10Z | 2026-10-09T13:59:03Z | 53.0 | 115 sidebar/fixture tests passed |
| app-strict-r13 | automated lint/check | 2026-10-09T13:59:11Z | 2026-10-09T13:59:32Z | 21.0 | failed:13 Clippy style/test-module placement errors |
| app-strict-r14 | automated lint/check | 2026-10-09T14:01:38Z | 2026-10-09T14:01:53Z | 15.0 | strict all-targets/all-features passed |
| app-all-r15 | build + test/check (combined) | 2026-10-09T14:04:03Z | 2026-10-09T14:05:08Z | 65.0 | 822 passed,1 failed,3 ignored: partial-save fixture reused unsaved tab; implementation unchanged, fixture corrected |
| app-focused-r16 | build + test/check (combined) | 2026-10-09T14:06:00Z | 2026-10-09T14:06:50Z | 50.0 | 117 sidebar/fixture tests passed, including corrected partial-save recovery and changed-piece reveal rejection |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,129 items; 601 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

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
| catchup_command | 129 | 2915.121 | 25 | 845.933 | 845.831 |
| catchup_api | 24 | 277.836 | 0 | 0.000 | unavailable |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
