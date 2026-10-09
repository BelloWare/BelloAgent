# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T16:47:00Z

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
| Build + test/check (combined) | 1m 10.5s measured command resource time |
| Interactive GUI validation | No new completed GUI process receipt |
| CI | 38.0s runner time across 1 completed jobs (1 failed); 38.0s wall union |
| Dependency/environment setup | 31.0s nested CI phase time (already inside CI jobs); command setup shown separately below |
| Retries/rework | Unavailable separately; retained successful checks do not establish zero rework |
| Publication | 1m 43.2s measured API/client time; 2 mixed windows; 2 with endpoints, 1m 39.2s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 8 | 89.721 | 8 | 89.721 | 89.721 |
| catchup_api | 12 | 103.160 | 12 | 103.160 | 36.504 |
| catchup_ci_job | 1 | 38.000 | 1 | 38.000 | 38.000 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: automated accounting validation | 0.201 |
| catchup_command: build + test/check (combined) | 70.535 |
| catchup_command: automated lint/check | 18.635 |
| catchup_command: negative-control test (existing script) | 0.350 |
| catchup_api: publication | 103.160 |
| catchup_ci_job: ci | 38.000 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|
| CI orchestration | 4.0s |
| dependency/environment setup | 31.0s |
| build/test/check (combined) | 0.0s |
| build + automated lint/check | 0.0s |
| build | 0.0s |
| CI reporting | 0.0s |

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

Within 2026-10-09T16:37:00Z–2026-10-09T16:47:00Z, newly recorded CI jobs cover 38.000 overlap-safe seconds. Remaining time is unclassified, not proven idle or inference.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Root paired timing verification and normal publication (shared once) | 2026-10-09T16:39:28.769Z | 2026-10-09T16:40:12.429Z | 43.66 | completed |
| Root isolated fixture repair source publication and verification | 2026-10-09T16:40:24.870Z | 2026-10-09T16:41:20.417Z | 55.547 | completed |
| Exact fixture repair apple-silicon CI status | unknown | unknown | unknown | in_progress at 2026-10-09T16:45:55.689Z; final duration unavailable |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Independent duration audit and historical-prefix verification | automated accounting validation | 2026-10-09T16:37:35.847813+00:00 | 2026-10-09T16:37:36.048848+00:00 | 0.20104156900197268 | 0 |
| Final fixture repair root-assertion focused | build + test/check (combined) | 2026-10-09T16:34:54.408917+00:00 | 2026-10-09T16:35:48.363019+00:00 | 53.954110140010016 | 0 |
| Final fixture repair root-assertion strictall | automated lint/check | 2026-10-09T16:35:48.365526+00:00 | 2026-10-09T16:36:04.520905+00:00 | 16.155395948007936 | 0 |
| Final fixture repair root-assertion fmt | automated lint/check | 2026-10-09T16:36:04.521563+00:00 | 2026-10-09T16:36:06.973968+00:00 | 2.4524203530017985 | 0 |
| Final fixture repair final-aggregate allfeatures | build + test/check (combined) | 2026-10-09T16:36:11.689508+00:00 | 2026-10-09T16:36:28.270047+00:00 | 16.580548910002108 | 0 |
| Fixture workflow preservation controls | automated lint/check | 2026-10-09T16:31:40.238141+00:00 | 2026-10-09T16:31:40.265656+00:00 | 0.02752124599646777 | completed |
| Fixture control omit-real-acl-denial | negative-control test (existing script) | 2026-10-09T16:32:34.723674+00:00 | 2026-10-09T16:32:34.903285+00:00 | 0.17961245600599796 | Expected negative-control failure; source restored |
| Fixture control omit-marker-equality | negative-control test (existing script) | 2026-10-09T16:32:34.903797+00:00 | 2026-10-09T16:32:35.074489+00:00 | 0.17070302899810486 | Expected negative-control failure; source restored |
| Create fixture repair blob: .github/workflows/rust.yml | publication | 2026-10-09T16:38:26.995Z | 2026-10-09T16:38:40.778Z | 13.783 | SHA/full-byte readback verified; superseded earlier documentation blob retained as performed work |
| Read back fixture repair blob: .github/workflows/rust.yml | publication | 2026-10-09T16:38:40.778Z | 2026-10-09T16:38:49.212Z | 8.434 | SHA/full-byte readback verified; superseded earlier documentation blob retained as performed work |
| Create fixture repair blob: .github/workflows/rust-macos.yml | publication | 2026-10-09T16:38:26.996Z | 2026-10-09T16:38:34.791Z | 7.795 | SHA/full-byte readback verified; superseded earlier documentation blob retained as performed work |
| Read back fixture repair blob: .github/workflows/rust-macos.yml | publication | 2026-10-09T16:38:34.791Z | 2026-10-09T16:38:49.235Z | 14.444 | SHA/full-byte readback verified; superseded earlier documentation blob retained as performed work |
| Create fixture repair blob: rust/crates/bello-agent-app/src/synthetic_sidebar_fixture.rs | publication | 2026-10-09T16:38:26.996Z | 2026-10-09T16:38:45.114Z | 18.118 | SHA/full-byte readback verified; superseded earlier documentation blob retained as performed work |
| Read back fixture repair blob: rust/crates/bello-agent-app/src/synthetic_sidebar_fixture.rs | publication | 2026-10-09T16:38:45.114Z | 2026-10-09T16:38:49.204Z | 4.09 | SHA/full-byte readback verified; superseded earlier documentation blob retained as performed work |
| Create fixture repair blob: rust/scripts/sidebar-ci-fixture.py | publication | 2026-10-09T16:38:26.997Z | 2026-10-09T16:38:48.890Z | 21.893 | SHA/full-byte readback verified; superseded earlier documentation blob retained as performed work |
| Read back fixture repair blob: rust/scripts/sidebar-ci-fixture.py | publication | 2026-10-09T16:38:48.890Z | 2026-10-09T16:38:49.229Z | 0.339 | SHA/full-byte readback verified; superseded earlier documentation blob retained as performed work |
| Create fixture repair blob: rust/docs/validation/sidebar-ci-fixture-2026-10-09.md | publication | 2026-10-09T16:39:01.466Z | 2026-10-09T16:39:06.690Z | 5.224 | SHA/full-byte readback verified; superseded earlier documentation blob retained as performed work |
| Read back fixture repair blob: rust/docs/validation/sidebar-ci-fixture-2026-10-09.md | publication | 2026-10-09T16:39:06.691Z | 2026-10-09T16:39:07.081Z | 0.39 | SHA/full-byte readback verified; superseded earlier documentation blob retained as performed work |
| Create fixture repair blob: rust/docs/validation/sidebar-ci-fixture-2026-10-09.md | publication | 2026-10-09T16:39:30.681Z | 2026-10-09T16:39:38.836Z | 8.155 | SHA/full-byte readback verified; superseded earlier documentation blob retained as performed work |
| Read back fixture repair blob: rust/docs/validation/sidebar-ci-fixture-2026-10-09.md | publication | 2026-10-09T16:39:38.836Z | 2026-10-09T16:39:39.331Z | 0.495 | SHA/full-byte readback verified; superseded earlier documentation blob retained as performed work |
| Exact fixture repair linux CI job | ci | 2026-10-09T16:41:24Z | 2026-10-09T16:42:02Z | 38.0 | failure |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,417 items; 842 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

| Existing resource group | Counted timed items | Resource seconds | Items with endpoints | Endpoint-subset seconds | Subset interval union seconds |
|---|---:|---:|---:|---:|---:|
| ci_job | 186 | 80885.000 | 186 | 80885.000 | 53609.000 |
| incremental_api | 58 | 427.621 | 50 | 389.193 | 254.901 |
| incremental_command | 64 | 956.457 | 39 | 517.000 | 517.000 |
| incremental_ci_job | 2 | 2171.000 | 2 | 2171.000 | 1424.000 |
| new_local_command | 8 | 209.302 | 8 | 209.302 | 209.302 |
| new_api_operation | 7 | 45.653 | 0 | 0.000 | unavailable |
| new_native_command | 75 | 506.149 | 74 | 500.224 | 500.244 |
| catchup_ci_job | 17 | 14879.000 | 17 | 14879.000 | 10012.000 |
| catchup_native_command | 36 | 718.272 | 36 | 718.272 | 718.281 |
| catchup_command | 237 | 5645.897 | 133 | 3576.710 | 3550.316 |
| catchup_api | 130 | 1191.607 | 106 | 913.771 | 460.507 |
| catchup_gui_process | 22 | 2313.456 | 22 | 2313.456 | 2313.456 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
