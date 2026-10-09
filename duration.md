# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T14:27:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 2 mixed windows; 2 with endpoints, 15m 11.0s union; scopes overlap resources and do not measure Review alone |
| Builds | Unavailable separately |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | Unavailable |
| Build + negative-control tests | 6m 42.2s measured command resource time; expected caught failures are not implementation failures |
| Interactive GUI validation | 8m 58.4s diagnostic process lifetime; no complete workflow acceptance |
| CI | No new completed job duration in this cohort; prior terminal jobs remain in the ledger and linked history |
| Dependency/environment setup | Unavailable |
| Retries/rework | 8m 58.4s across 1 failed command receipts; total rework effort unavailable |
| Publication | No isolated API total; 2 mixed windows; 2 with endpoints, 9m 21.1s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_gui_process | 1 | 538.445 | 1 | 538.445 | 538.445 |
| catchup_command | 7 | 402.160 | 7 | 402.160 | 402.160 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_gui_process: interactive GUI diagnostics | 538.445 |
| catchup_command: build + negative-control test (combined) | 402.160 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

This cohort adds no CI job execution intervals; prior verified terminal runs remain in earlier accounting. Coverage of 2026-10-09T14:17:00Z–2026-10-09T14:27:00Z is partial and does not establish an idle-time or inference budget.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Prepare, upload and verify paired 14:17 timing candidates | 2026-10-09T14:11:49Z | 2026-10-09T14:20:36Z | 527 | completed |
| Publish paired compact 14:17 timing checkpoint (shared once) | 2026-10-09T14:21:02.710Z | 2026-10-09T14:21:36.857Z | 34.147 | completed |
| Validation, GUI diagnosis, build-lane coordination and source repair continuation | 2026-10-09T14:17:00Z | 2026-10-09T14:27:00Z | 600.0 | completed |
| GUI-discovered first-open reveal correction begun | 2026-10-09T14:26:55Z | 2026-10-09T14:27:00Z | 5.0 | completed |
| First cross-chat reveal correction | 2026-10-09T14:26:55Z | unknown | unknown | Correction ongoing; no repaired GUI acceptance yet |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Synthetic sidebar second GUI process attempt | interactive GUI diagnostics | 2026-10-09T14:17:06.507062859+00:00 | 2026-10-09T14:26:04.952561133+00:00 | 538.445499 | Partial synthetic cloud GUI; loaded-result checks observed, cross-chat first-open reveal failed; repaired restart/manual wheel acceptance pending |
| debounce-cancel | build + negative-control test (combined) | 2026-10-09T14:17:17.858789+00:00 | 2026-10-09T14:18:24.699801+00:00 | 66.8410181329964 | Expected negative-control failure; source restored |
| cleanup-intent-loss | build + negative-control test (combined) | 2026-10-09T14:18:24.700732+00:00 | 2026-10-09T14:19:20.173351+00:00 | 55.47263274999568 | Expected negative-control failure; source restored |
| piece-digest-omitted | build + negative-control test (combined) | 2026-10-09T14:19:20.174495+00:00 | 2026-10-09T14:20:18.305889+00:00 | 58.13140206199023 | Expected negative-control failure; source restored |
| geometry-source-omitted | build + negative-control test (combined) | 2026-10-09T14:20:18.307413+00:00 | 2026-10-09T14:21:12.272737+00:00 | 53.96533010000712 | Expected negative-control failure; source restored |
| old-find-navigation | build + negative-control test (combined) | 2026-10-09T14:21:12.274151+00:00 | 2026-10-09T14:22:08.003951+00:00 | 55.729807583993534 | Expected negative-control failure; source restored |
| stream-starvation | build + negative-control test (combined) | 2026-10-09T14:22:08.005252+00:00 | 2026-10-09T14:23:03.351551+00:00 | 55.346306799998274 | Expected negative-control failure; source restored |
| live-cache-barrier-omitted | build + negative-control test (combined) | 2026-10-09T14:23:03.352856+00:00 | 2026-10-09T14:24:00.026469+00:00 | 56.67362241099181 | Expected negative-control failure; source restored |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,164 items; 627 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

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
| catchup_command | 153 | 3527.339 | 49 | 1458.151 | 1457.257 |
| catchup_api | 24 | 277.836 | 0 | 0.000 | unavailable |
| catchup_gui_process | 2 | 653.507 | 2 | 653.507 | 653.507 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
