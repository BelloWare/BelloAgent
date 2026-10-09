# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T14:57:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 2 mixed windows; 2 with endpoints, 14m 6.0s union; scopes overlap resources and do not measure Review alone |
| Builds | 21.0s measured command resource time |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | 1m 6.0s measured command resource time |
| Interactive GUI validation | 6m 21.7s diagnostic process lifetime; no complete workflow acceptance |
| CI | No new completed job duration in this cohort; prior terminal jobs remain in the ledger and linked history |
| Dependency/environment setup | Unavailable |
| Retries/rework | 6.679ms across 1 failed process/API receipts; total rework effort unavailable |
| Publication | 5m 8.3s measured API/client time; 3 mixed windows; 3 with endpoints, 8m 58.2s union |
| Waiting | 2 mixed windows; 1 with endpoints, 7m 13.0s union shared-build-lane constraint; overlaps useful work, not proven idle |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_gui_process | 2 | 381.681 | 2 | 381.681 | 381.681 |
| catchup_api | 19 | 308.289 | 19 | 308.289 | 121.586 |
| catchup_command | 3 | 104.000 | 3 | 104.000 | 104.000 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_gui_process: interactive GUI diagnostics | 381.681 |
| catchup_api: publication | 308.289 |
| catchup_command: build + test/check (combined) | 66.000 |
| catchup_command: automated lint/check | 17.000 |
| catchup_command: build | 21.000 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

This cohort adds no CI job execution intervals; prior verified terminal runs remain in earlier accounting. Coverage of 2026-10-09T14:47:00Z–2026-10-09T14:57:00Z is partial and does not establish an idle-time or inference budget.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Prepare, upload and verify paired 14:47 timing candidates | 2026-10-09T14:42:54Z | 2026-10-09T14:49:24Z | 390 | completed |
| Publish paired compact 14:47 timing checkpoint (shared once) | 2026-10-09T14:49:55.543Z | 2026-10-09T14:50:20.577Z | 25.034 | completed |
| Immutable Core blob preparation parallel batch | 2026-10-09T14:53:21.668Z | 2026-10-09T14:55:24.799Z | 123.131 | completed |
| Create immutable Core blob: .cargo/config.toml | unknown | unknown | unknown | Returned blob SHA matched local Git content SHA |
| Timer-owner repair, validation and coordination | 2026-10-09T14:46:00Z | 2026-10-09T14:57:00Z | 660.0 | completed |
| Shared Cargo lane yielded to Regex | 2026-10-09T14:45:43Z | 2026-10-09T14:52:56Z | 433.0 | Closed build-lane constraint; parallel source/coordination work may continue |
| Shared Cargo lane yielded to Regex | 2026-10-09T14:55:25Z | unknown | unknown | Open at cutoff; final duration unknown |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Synthetic sidebar v2 GUI process lifetime | interactive GUI diagnostics | 2026-10-09T14:42:21.828547815+00:00 | 2026-10-09T14:48:43.502424143+00:00 | 381.673877 | partial positive evidence only; independently confirmed timer-owner defect requires another seal/rerun |
| Create immutable Core blob: rust/crates/bello-agent-core/build.rs | publication | 2026-10-09T14:53:22.125Z | 2026-10-09T14:53:29.116Z | 6.991 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/Cargo.toml | publication | 2026-10-09T14:53:22.125Z | 2026-10-09T14:53:38.954Z | 16.829 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/Cargo.toml | publication | 2026-10-09T14:53:22.125Z | 2026-10-09T14:53:47.408Z | 25.283 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/Cargo.lock | publication | 2026-10-09T14:53:22.128Z | 2026-10-09T14:54:04.649Z | 42.521 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/src/sidebar_search/admission.rs | publication | 2026-10-09T14:54:05.044Z | 2026-10-09T14:54:10.158Z | 5.114 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/src/sidebar_search/cache/mac_acl.rs | publication | 2026-10-09T14:54:05.044Z | 2026-10-09T14:54:15.989Z | 10.945 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/src/sidebar_search/admission_tests.rs | publication | 2026-10-09T14:54:05.044Z | 2026-10-09T14:54:22.604Z | 17.56 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/src/sidebar_search/cache/mod.rs | publication | 2026-10-09T14:54:05.065Z | 2026-10-09T14:54:29.558Z | 24.493 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/src/sidebar_search/cache/privacy.rs | publication | 2026-10-09T14:54:29.885Z | 2026-10-09T14:54:35.537Z | 5.652 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/src/sidebar_search/cache/runtime.rs | publication | 2026-10-09T14:54:29.907Z | 2026-10-09T14:54:42.094Z | 12.187 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/src/sidebar_search/cache/observer.rs | publication | 2026-10-09T14:54:29.907Z | 2026-10-09T14:54:50.585Z | 20.678 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/src/sidebar_search/cache/query.rs | publication | 2026-10-09T14:54:29.908Z | 2026-10-09T14:54:57.416Z | 27.508 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/src/sidebar_search/mod.rs | publication | 2026-10-09T14:54:57.782Z | 2026-10-09T14:55:05.363Z | 7.581 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/src/sidebar_search/unloaded.rs | publication | 2026-10-09T14:54:57.783Z | 2026-10-09T14:55:11.637Z | 13.854 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/tests/sidebar_search_projection.rs | publication | 2026-10-09T14:55:05.683Z | 2026-10-09T14:55:12.265Z | 6.582 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/src/sidebar_search/projection.rs | publication | 2026-10-09T14:54:57.783Z | 2026-10-09T14:55:17.976Z | 20.193 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/scripts/check-sidebar-sqlite.py | publication | 2026-10-09T14:55:12.581Z | 2026-10-09T14:55:18.086Z | 5.505 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/docs/sidebar-private-cache.md | publication | 2026-10-09T14:55:12.581Z | 2026-10-09T14:55:24.378Z | 11.797 | Returned blob SHA matched local Git content SHA |
| Create immutable Core blob: rust/crates/bello-agent-core/src/sidebar_search/cache/tests.rs | publication | 2026-10-09T14:54:57.783Z | 2026-10-09T14:55:24.799Z | 27.016 | Returned blob SHA matched local Git content SHA |
| app-timer-owner-r33 | build + test/check (combined) | 2026-10-09T14:52:57Z | 2026-10-09T14:54:03Z | 66.0 | 0 |
| app-strict-timer-r34 | automated lint/check | 2026-10-09T14:54:12Z | 2026-10-09T14:54:29Z | 17.0 | 0 |
| synthetic-build-timer-r35 | build | 2026-10-09T14:54:29Z | 2026-10-09T14:54:50Z | 21.0 | 0 |
| Final-v3 GUI startup attempt | interactive GUI diagnostics | 2026-10-09T14:56:23.265230068+00:00 | 2026-10-09T14:56:23.271909516+00:00 | 0.006679 | Failed startup before window creation: OS StorageFull error; no interaction acceptance |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,216 items; 665 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

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
| catchup_command | 170 | 4188.798 | 66 | 2119.610 | 2116.698 |
| catchup_api | 43 | 586.125 | 19 | 308.289 | 121.586 |
| catchup_gui_process | 4 | 1035.187 | 4 | 1035.187 | 1035.187 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
