# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T14:17:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 3 mixed windows; 3 with endpoints, 14m 38.0s union; scopes overlap resources and do not measure Review alone |
| Builds | 31.0s measured command resource time |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | 2m 10.0s measured command resource time |
| Interactive GUI validation | 1m 55.1s diagnostic process lifetime; no interaction acceptance |
| CI | No new completed job duration in this cohort; prior terminal jobs remain in the ledger and linked history |
| Dependency/environment setup | Unavailable |
| Retries/rework | 15.0s across 1 failed command receipts; total rework effort unavailable |
| Publication | No isolated API total; 2 mixed windows; 2 with endpoints, 8m 11.8s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 17 | 210.058 | 17 | 210.058 | 210.058 |
| catchup_gui_process | 1 | 115.061 | 1 | 115.061 | 115.061 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: automated lint/check | 48.266 |
| catchup_command: automated configuration validation | 0.792 |
| catchup_command: build + test/check (combined) | 130.000 |
| catchup_command: build | 31.000 |
| catchup_gui_process: interactive GUI diagnostics | 115.061 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

This cohort adds no CI job execution intervals; prior verified terminal runs remain in earlier accounting. Coverage of 2026-10-09T14:07:00Z–2026-10-09T14:17:00Z is partial and does not establish an idle-time or inference budget.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Prepare, upload and verify paired 14:07 timing candidates | 2026-10-09T14:02:22Z | 2026-10-09T14:09:53Z | 451 | completed |
| Publish paired compact 14:07 timing checkpoint (shared once) | 2026-10-09T14:10:25.921Z | 2026-10-09T14:11:06.768Z | 40.847 | completed |
| Ongoing sidebar integration observed source workflow segment | 2026-10-09T14:07:00+00:00 | 2026-10-09T14:11:28Z | 268.0 | completed |
| Validation, coordination and build-lane workflow after source freeze | 2026-10-09T14:11:28Z | 2026-10-09T14:17:00Z | 332.0 | completed |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Synthetic launcher source formatting check | automated lint/check | 2026-10-09T13:57:37.684449+00:00 | 2026-10-09T13:57:37.950735+00:00 | 0.26648027999908663 | 0 |
| Synthetic launcher rustc cfg predicate 0 | automated configuration validation | 2026-10-09T13:58:55.149383+00:00 | 2026-10-09T13:58:55.358475+00:00 | 0.20905232899531256 | 0 |
| Synthetic launcher rustc cfg predicate 1 | automated configuration validation | 2026-10-09T13:58:55.358485+00:00 | 2026-10-09T13:58:55.736504+00:00 | 0.3779788079991704 | 0 |
| Synthetic launcher rustc cfg predicate 2 | automated configuration validation | 2026-10-09T13:58:55.736515+00:00 | 2026-10-09T13:58:55.809865+00:00 | 0.07331527899077628 | 0 |
| Synthetic launcher rustc cfg predicate 3 | automated configuration validation | 2026-10-09T13:58:55.809874+00:00 | 2026-10-09T13:58:55.825192+00:00 | 0.01526743000431452 | 0 |
| Synthetic launcher rustc cfg predicate 4 | automated configuration validation | 2026-10-09T13:58:55.825203+00:00 | 2026-10-09T13:58:55.893666+00:00 | 0.06842300599964801 | 0 |
| Synthetic launcher rustc cfg predicate 5 | automated configuration validation | 2026-10-09T13:58:55.893676+00:00 | 2026-10-09T13:58:55.914815+00:00 | 0.021089125992148183 | 0 |
| Synthetic launcher rustc cfg predicate 6 | automated configuration validation | 2026-10-09T13:58:55.914825+00:00 | 2026-10-09T13:58:55.929456+00:00 | 0.01459367100324016 | 0 |
| Synthetic launcher rustc cfg predicate 7 | automated configuration validation | 2026-10-09T13:58:55.929465+00:00 | 2026-10-09T13:58:55.941319+00:00 | 0.011823549997643568 | 0 |
| app-focused-r17 | build + test/check (combined) | 2026-10-09T14:07:21Z | 2026-10-09T14:08:13Z | 52.0 | 118 sidebar/fixture tests passed |
| app-all-r18 | build + test/check (combined) | 2026-10-09T14:08:39Z | 2026-10-09T14:08:57Z | 18.0 | 825 passed,3 ignored; frozen r1 |
| app-default-r19 | build + test/check (combined) | 2026-10-09T14:08:57Z | 2026-10-09T14:09:57Z | 60.0 | 651 passed,1 ignored; frozen r1 |
| app-strict-all-r20 | automated lint/check | 2026-10-09T14:09:57Z | 2026-10-09T14:10:14Z | 17.0 | strict all-targets/all-features passed; frozen r1 |
| app-strict-default-r21 | automated lint/check | 2026-10-09T14:10:14Z | 2026-10-09T14:10:29Z | 15.0 | failed only two unused synthetic-test helpers under default; cfg narrowed to test+Linux+synthetic-authority |
| app-strict-default-r21b | automated lint/check | 2026-10-09T14:11:27Z | 2026-10-09T14:11:40Z | 13.0 | strict default passed; sealed r2 helper-cfg delta |
| fmt-r22 | automated lint/check | 2026-10-09T14:11:40Z | 2026-10-09T14:11:43Z | 3.0 | workspace fmt check passed |
| synthetic-build-r23 | build | 2026-10-09T14:11:43Z | 2026-10-09T14:12:14Z | 31.0 | synthetic-authority debug Linux binary built and sealed ef71f8546e643398690978c9b7494fbd8e87b71b030b5f594622a75d92e0f1ef |
| Synthetic sidebar first GUI process attempt | interactive GUI diagnostics | 2026-10-09T14:14:18.899678735+00:00 | 2026-10-09T14:16:13.960951784+00:00 | 115.061273 | Inconclusive black-window capture; no interaction acceptance |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,151 items; 619 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

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
| catchup_command | 146 | 3125.179 | 42 | 1055.991 | 1055.097 |
| catchup_api | 24 | 277.836 | 0 | 0.000 | unavailable |
| catchup_gui_process | 1 | 115.061 | 1 | 115.061 | 115.061 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
