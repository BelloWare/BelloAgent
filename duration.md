# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T15:17:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 3 mixed windows; 3 with endpoints, 26m 6.0s union; scopes overlap resources and do not measure Review alone |
| Builds | 30.0s measured command resource time |
| Tests | 4.659ms measured execution of existing binaries; no compilation included |
| Build + test/check (combined) | 2m 4.0s measured command resource time |
| Build + negative-control tests | 1m 50.0s measured command resource time; expected caught failures are not implementation failures |
| Interactive GUI validation | 8m 50.8s observed process lifetime; overlaps workflow windows, limited acceptance only |
| CI | No new completed job duration in this cohort; prior terminal jobs remain in the ledger and linked history |
| Dependency/environment setup | 491.910ms measured command resource time |
| Retries/rework | 11.116ms across 1 failed process/API receipts; total rework effort unavailable |
| Publication | 6m 12.2s measured API/client time; 3 mixed windows; 3 with endpoints, 16m 18.8s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 13 | 299.058 | 13 | 299.058 | 296.097 |
| catchup_gui_process | 3 | 530.818 | 3 | 530.818 | 530.818 |
| catchup_api | 56 | 372.213 | 56 | 372.213 | 220.523 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: dependency/environment recovery | 0.492 |
| catchup_command: automated accounting validation | 2.961 |
| catchup_command: packaging/source validation | 0.556 |
| catchup_command: build + test/check (combined) | 124.000 |
| catchup_command: automated lint/check | 31.000 |
| catchup_command: build | 30.000 |
| catchup_command: build + negative-control test (combined) | 110.044 |
| catchup_command: test execution (existing binary) | 0.005 |
| catchup_gui_process: interactive GUI validation | 530.818 |
| catchup_api: publication | 372.213 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

This cohort adds no CI job execution intervals; prior verified terminal runs remain in earlier accounting. Coverage of 2026-10-09T14:57:00Z–2026-10-09T15:17:00Z is partial and does not establish an idle-time or inference budget.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Prepare, upload and verify paired 14:57 timing candidates | 2026-10-09T14:50:54Z | 2026-10-09T15:01:15Z | 621 | completed |
| Publish paired compact 14:57 timing checkpoint (shared once) | 2026-10-09T15:06:19.216Z | 2026-10-09T15:06:47.783Z | 28.567 | completed |
| Root cross-repository source/receipt review, coordination, publication and waits (shared once) | 2026-10-09T15:05:34Z | 2026-10-09T15:16:34.338Z | 660.338 | completed |
| Final controls, restored gates, GUI coordination and source preparation | 2026-10-09T14:57:00Z | 2026-10-09T15:17:00Z | 1200.0 | completed |
| App immutable source blob creation and readback workflow | 2026-10-09T15:08:55.696Z | 2026-10-09T15:14:24.947Z | 329.251 | completed |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Shared obsolete-target cleanup PATH failure | dependency/environment recovery | 2026-10-09T14:59:56.494497+00:00 | 2026-10-09T14:59:56.505610+00:00 | 0.01111584299360402 | Failed before rustc execution: PATH/toolchain lookup unavailable; no cleanup performed |
| Shared obsolete-target cleanup successful retry | dependency/environment recovery | 2026-10-09T15:00:19.273368+00:00 | 2026-10-09T15:00:19.754158+00:00 | 0.4807944150088588 | 0 |
| Independent final v3 Agent LOC reproduction | automated accounting validation | 2026-10-09T15:09:25.442547+00:00 | 2026-10-09T15:09:28.403497+00:00 | 2.9609540959936567 | passed; full ledger/source reproduction match |
| Final synthetic sidebar fresh GUI process lifetime | interactive GUI validation | 2026-10-09T15:04:41.956622428+00:00 | 2026-10-09T15:09:14.727092744+00:00 | 272.77047 | Normal exit0; scoped synthetic cloud GUI validation, initial-black startup caveat retained |
| Final synthetic sidebar restart GUI process lifetime | interactive GUI validation | 2026-10-09T15:09:54.150255263+00:00 | 2026-10-09T15:13:19.254798796+00:00 | 205.104543 | Normal exit0; scoped synthetic cloud GUI validation, initial-black startup caveat retained |
| Ordinary Agent binary sealing and source verification | packaging/source validation | 2026-10-09T15:13:30.588783+00:00 | 2026-10-09T15:13:31.145118+00:00 | 0.5563400880055269 | completed;49 source files verified; no GUI inferred |
| app-restored-all-r36 | build + test/check (combined) | 2026-10-09T15:07:33Z | 2026-10-09T15:08:44Z | 71.0 | 0 |
| app-restored-default-r37 | build + test/check (combined) | 2026-10-09T15:08:44Z | 2026-10-09T15:09:37Z | 53.0 | 0 |
| app-restored-strict-all-r38 | automated lint/check | 2026-10-09T15:10:00Z | 2026-10-09T15:10:16Z | 16.0 | 0 |
| app-restored-strict-default-r39 | automated lint/check | 2026-10-09T15:10:17Z | 2026-10-09T15:10:30Z | 13.0 | 0 |
| app-final-fmt-r40 | automated lint/check | 2026-10-09T15:10:30Z | 2026-10-09T15:10:32Z | 2.0 | 0 |
| app-ordinary-build-r41 | build | 2026-10-09T15:10:32Z | 2026-10-09T15:11:02Z | 30.0 | 0 |
| completed-decoration-renavigates | build + negative-control test (combined) | 2026-10-09T15:05:27.840804+00:00 | 2026-10-09T15:06:30.212429+00:00 | 62.371626684005605 | Expected negative-control failure; source restored |
| old-paint-owner-reused | build + negative-control test (combined) | 2026-10-09T15:06:30.213367+00:00 | 2026-10-09T15:07:17.885654+00:00 | 47.67228547100967 | Expected negative-control failure; source restored |
| Ordinary default startup-control process | interactive GUI validation | 2026-10-09T15:15:24.953625988+00:00 | 2026-10-09T15:16:17.896904986+00:00 | 52.943279 | Normal exit0; first capture painted without workaround |
| Ordinary binary rejects synthetic-only fixture route | test execution (existing binary) | 2026-10-09T15:15:02.756272+00:00 | 2026-10-09T15:15:02.760938+00:00 | 0.004658502992242575 | Expected negative-control failure |
| Create immutable App blob: .github/workflows/rust-macos.yml | publication | 2026-10-09T15:08:55.696Z | 2026-10-09T15:09:05.373Z | 9.677 | Blob SHA verified |
| Read immutable App blob: .github/workflows/rust-macos.yml | publication | 2026-10-09T15:09:12.475Z | 2026-10-09T15:09:13.013Z | 0.538 | Full remote blob bytes matched |
| Create immutable App blob: .github/workflows/rust.yml | publication | 2026-10-09T15:10:45.778Z | 2026-10-09T15:10:54.719Z | 8.941 | Blob SHA verified |
| Read immutable App blob: .github/workflows/rust.yml | publication | 2026-10-09T15:10:54.719Z | 2026-10-09T15:10:55.123Z | 0.404 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/chat_load.rs | publication | 2026-10-09T15:10:46.026Z | 2026-10-09T15:11:02.895Z | 16.869 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/chat_load.rs | publication | 2026-10-09T15:11:02.895Z | 2026-10-09T15:11:03.212Z | 0.317 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/chat_navigation.rs | publication | 2026-10-09T15:11:04.836Z | 2026-10-09T15:11:13.281Z | 8.445 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/chat_navigation.rs | publication | 2026-10-09T15:11:13.281Z | 2026-10-09T15:11:13.682Z | 0.401 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/chat_organization.rs | publication | 2026-10-09T15:10:55.321Z | 2026-10-09T15:11:04.540Z | 9.219 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/chat_organization.rs | publication | 2026-10-09T15:11:04.540Z | 2026-10-09T15:11:05.021Z | 0.481 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/connection_settings_controller.rs | publication | 2026-10-09T15:11:15.424Z | 2026-10-09T15:11:28.573Z | 13.149 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/connection_settings_controller.rs | publication | 2026-10-09T15:11:28.573Z | 2026-10-09T15:11:28.975Z | 0.402 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/connection_settings_controller_tests.rs | publication | 2026-10-09T15:11:29.423Z | 2026-10-09T15:11:36.669Z | 7.246 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/connection_settings_controller_tests.rs | publication | 2026-10-09T15:11:36.669Z | 2026-10-09T15:11:37.102Z | 0.433 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/main.rs | publication | 2026-10-09T15:11:38.542Z | 2026-10-09T15:11:47.684Z | 9.142 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/main.rs | publication | 2026-10-09T15:11:47.684Z | 2026-10-09T15:11:48.052Z | 0.368 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/mcp_inspector_controller.rs | publication | 2026-10-09T15:11:15.228Z | 2026-10-09T15:11:21.821Z | 6.593 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/mcp_inspector_controller.rs | publication | 2026-10-09T15:11:21.822Z | 2026-10-09T15:11:29.031Z | 7.209 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/project_manager_controller.rs | publication | 2026-10-09T15:12:05.256Z | 2026-10-09T15:12:21.473Z | 16.217 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/project_manager_controller.rs | publication | 2026-10-09T15:12:21.473Z | 2026-10-09T15:12:27.617Z | 6.144 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/project_manager_controller_tests.rs | publication | 2026-10-09T15:12:05.512Z | 2026-10-09T15:12:27.233Z | 21.721 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/project_manager_controller_tests.rs | publication | 2026-10-09T15:12:27.233Z | 2026-10-09T15:12:27.647Z | 0.414 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/sidebar_actions.rs | publication | 2026-10-09T15:11:49.007Z | 2026-10-09T15:11:57.467Z | 8.46 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/sidebar_actions.rs | publication | 2026-10-09T15:11:57.467Z | 2026-10-09T15:12:05.526Z | 8.059 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/sidebar_activity.rs | publication | 2026-10-09T15:11:49.007Z | 2026-10-09T15:12:04.947Z | 15.94 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/sidebar_activity.rs | publication | 2026-10-09T15:12:04.947Z | 2026-10-09T15:12:05.495Z | 0.548 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/sidebar_cache_cleanup.rs | publication | 2026-10-09T15:12:28.348Z | 2026-10-09T15:12:34.428Z | 6.08 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/sidebar_cache_cleanup.rs | publication | 2026-10-09T15:12:34.428Z | 2026-10-09T15:12:34.840Z | 0.412 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/sidebar_inspection.rs | publication | 2026-10-09T15:12:28.348Z | 2026-10-09T15:12:41.122Z | 12.774 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/sidebar_inspection.rs | publication | 2026-10-09T15:12:41.122Z | 2026-10-09T15:12:43.244Z | 2.122 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/sidebar_read_state.rs | publication | 2026-10-09T15:12:35.300Z | 2026-10-09T15:12:42.751Z | 7.451 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/sidebar_read_state.rs | publication | 2026-10-09T15:12:42.751Z | 2026-10-09T15:12:50.419Z | 7.668 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/sidebar_run_state.rs | publication | 2026-10-09T15:12:41.408Z | 2026-10-09T15:12:49.991Z | 8.583 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/sidebar_run_state.rs | publication | 2026-10-09T15:12:49.991Z | 2026-10-09T15:12:50.463Z | 0.472 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/sidebar_search_controller.rs | publication | 2026-10-09T15:13:00.108Z | 2026-10-09T15:13:13.564Z | 13.456 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/sidebar_search_controller.rs | publication | 2026-10-09T15:13:13.564Z | 2026-10-09T15:13:14.069Z | 0.505 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/sidebar_search_controller_tests.rs | publication | 2026-10-09T15:13:13.858Z | 2026-10-09T15:13:20.350Z | 6.492 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/sidebar_search_controller_tests.rs | publication | 2026-10-09T15:13:20.350Z | 2026-10-09T15:13:20.756Z | 0.406 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/sidebar_search_reveal.rs | publication | 2026-10-09T15:13:00.101Z | 2026-10-09T15:13:06.010Z | 5.909 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/sidebar_search_reveal.rs | publication | 2026-10-09T15:13:06.010Z | 2026-10-09T15:13:06.363Z | 0.353 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/sidebar_search_state.rs | publication | 2026-10-09T15:12:51.063Z | 2026-10-09T15:12:59.827Z | 8.764 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/sidebar_search_state.rs | publication | 2026-10-09T15:12:59.827Z | 2026-10-09T15:13:00.284Z | 0.457 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/synthetic_sidebar_fixture.rs | publication | 2026-10-09T15:13:28.388Z | 2026-10-09T15:13:58.158Z | 29.77 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/synthetic_sidebar_fixture.rs | publication | 2026-10-09T15:13:58.158Z | 2026-10-09T15:13:58.513Z | 0.355 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/transcript_find_controller.rs | publication | 2026-10-09T15:13:28.117Z | 2026-10-09T15:13:43.819Z | 15.702 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/transcript_find_controller.rs | publication | 2026-10-09T15:13:43.819Z | 2026-10-09T15:13:58.570Z | 14.751 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/transcript_find_presentation.rs | publication | 2026-10-09T15:13:28.117Z | 2026-10-09T15:13:49.296Z | 21.179 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/transcript_find_presentation.rs | publication | 2026-10-09T15:13:49.296Z | 2026-10-09T15:13:49.676Z | 0.38 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/transcript_find_state.rs | publication | 2026-10-09T15:13:21.341Z | 2026-10-09T15:13:27.809Z | 6.468 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/transcript_find_state.rs | publication | 2026-10-09T15:13:27.809Z | 2026-10-09T15:13:28.352Z | 0.543 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/transcript_view.rs | publication | 2026-10-09T15:14:17.730Z | 2026-10-09T15:14:24.507Z | 6.777 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/transcript_view.rs | publication | 2026-10-09T15:14:24.507Z | 2026-10-09T15:14:24.947Z | 0.44 | Full remote blob bytes matched |
| Create immutable App blob: rust/crates/bello-agent-app/src/transcript_view_tests.rs | publication | 2026-10-09T15:14:09.243Z | 2026-10-09T15:14:17.459Z | 8.216 | Blob SHA verified |
| Read immutable App blob: rust/crates/bello-agent-app/src/transcript_view_tests.rs | publication | 2026-10-09T15:14:17.459Z | 2026-10-09T15:14:17.819Z | 0.36 | Full remote blob bytes matched |
| Create immutable App blob: rust/docs/sidebar-content-workflow.md | publication | 2026-10-09T15:13:59.254Z | 2026-10-09T15:14:06.929Z | 7.675 | Blob SHA verified |
| Read immutable App blob: rust/docs/sidebar-content-workflow.md | publication | 2026-10-09T15:14:06.929Z | 2026-10-09T15:14:07.285Z | 0.356 | Full remote blob bytes matched |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,293 items; 737 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

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
| catchup_command | 183 | 4487.856 | 79 | 2418.668 | 2412.795 |
| catchup_api | 99 | 958.338 | 75 | 680.502 | 342.109 |
| catchup_gui_process | 7 | 1566.006 | 7 | 1566.006 | 1566.006 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
