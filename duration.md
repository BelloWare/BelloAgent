# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T12:20:16Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains preserved below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; mixed source/test windows recorded below |
| Review | Active effort unavailable; only review-focused observations: 1 mixed windows; 1 with endpoints, 2m 28.0s union |
| Mixed implementation/review/validation windows | 2 mixed windows; 2 with endpoints, 3h 16m 52.3s union; scopes overlap resources and do not measure Review alone |
| Builds | 3m 31.8s measured command resource time |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | 20m 29.9s measured command resource time |
| CI | 2h 57m 0.0s runner time across 10 jobs; 1h 59m 14.0s wall union |
| Dependency/environment setup | 36.2s measured resource time |
| Retries/rework | 2m 4.6s across 10 failed command receipts; total rework effort unavailable |
| Publication | 4m 37.8s measured API/client time; 7 mixed windows; 6 with endpoints, 5m 59.0s union |
| Waiting | 3h 24m 14.9s enclosing blocked/cancelled orchestration; pure waiting unavailable, productive work overlapped |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_ci_job | 10 | 10620.000 | 10 | 10620.000 | 7154.000 |
| catchup_native_command | 36 | 718.272 | 36 | 718.272 | 718.281 |
| catchup_command | 52 | 1063.556 | 0 | 0.000 | unavailable |
| catchup_api | 24 | 277.836 | 0 | 0.000 | unavailable |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_ci_job: CI runner | 10620.000 |
| catchup_native_command: automated lint/check | 124.977 |
| catchup_native_command: build + test/check (combined) | 399.327 |
| catchup_native_command: build | 191.288 |
| catchup_native_command: dependency/environment or verification | 2.679 |
| catchup_command: build + test/check (combined) | 830.615 |
| catchup_command: automated lint/check | 178.863 |
| catchup_command: dependency/environment or verification | 33.565 |
| catchup_command: build | 20.513 |
| catchup_api: publication | 277.836 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|
| CI orchestration | 1m 20.0s |
| dependency/environment setup | 4m 19.0s |
| build + automated lint/check | 1m 7.0s |
| build/test/check (combined) | 2h 45m 27.0s |
| build | 4m 18.0s |
| CI reporting | 0.0s |

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

Within 2026-10-09T08:43:00Z–2026-10-09T12:20:16Z, the selected CI jobs cover 6440.000 overlap-safe wall seconds; 6596.000 seconds are outside those jobs. This remainder includes implementation, tests, review, publication, waiting and unknown time; it is neither proven idle nor model inference.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Native validation and oracle coordination (shared coordination once) | 2026-10-09T06:33:10Z | 2026-10-09T08:55:04Z | 8514.0 | completed |
| Coordinated inspection and safe selected opening | 2026-10-09T08:50:31+00:00 | 2026-10-09T09:50:02.336775+00:00 | 3571.336775 | completed |
| Coordinated inspection actual GUI workflow | unknown | unknown | 279.137925 | completed |
| inspection source publication and verified branch readback | 2026-10-09T09:49:34Z | 2026-10-09T09:49:51Z | 17.0 | completed |
| witness source publication and verified branch readback | 2026-10-09T10:27:52Z | 2026-10-09T10:28:11Z | 19.0 | completed |
| membership source publication and verified branch readback | 2026-10-09T11:01:00Z | 2026-10-09T11:01:24Z | 24.0 | completed |
| loaded source publication and verified branch readback | 2026-10-09T11:41:23Z | 2026-10-09T11:41:47Z | 24.0 | completed |
| Cross-repository source and validation review (shared once) | 2026-10-09T11:56:23Z | 2026-10-09T11:58:51Z | 148 | completed |
| Timing publication orchestration blocked then cancelled | unknown | unknown | 12254.9 | cancelled; same ledger action retried successfully |
| Reconcile cancelled upload, retry exact action and verify source-preserving candidates | 2026-10-09T12:15:03Z | 2026-10-09T12:19:11Z | 248.0 | completed |
| Publish both reviewed timing checkpoints (shared once) | 2026-10-09T12:19:49Z | 2026-10-09T12:20:16Z | 27 | completed |

The 12,254.9-second cancelled orchestration includes a preceding successful Markdown upload plus transport and the blocked ledger operation; it is not isolated approval time or idle time. Independent implementation and CI continued during this interval. Individual retry duration remains unknown.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Rust Linux checks / linux | CI runner | 2026-10-09T08:31:06Z | 2026-10-09T08:40:23Z | 557.0 | success |
| Rust macOS native checks / apple-silicon | CI runner | 2026-10-09T08:31:13Z | 2026-10-09T08:53:37Z | 1344.0 | success |
| Rust Linux checks / linux | CI runner | 2026-10-09T09:49:56Z | 2026-10-09T10:01:06Z | 670.0 | success |
| Rust macOS native checks / apple-silicon | CI runner | 2026-10-09T09:50:04Z | 2026-10-09T10:12:24Z | 1340.0 | success |
| Rust Linux checks / linux | CI runner | 2026-10-09T10:28:14Z | 2026-10-09T10:41:39Z | 805.0 | success |
| Rust macOS native checks / apple-silicon | CI runner | 2026-10-09T10:28:19Z | 2026-10-09T10:53:47Z | 1528.0 | success |
| Rust macOS native checks / apple-silicon | CI runner | 2026-10-09T11:01:34Z | 2026-10-09T11:27:14Z | 1540.0 | success |
| Rust Linux checks / linux | CI runner | 2026-10-09T11:01:29Z | 2026-10-09T11:12:38Z | 669.0 | success |
| Rust Linux checks / linux | CI runner | 2026-10-09T11:41:51Z | 2026-10-09T11:55:09Z | 798.0 | success |
| Rust macOS native checks / apple-silicon | CI runner | 2026-10-09T11:41:59Z | 2026-10-09T12:04:48Z | 1369.0 | success |
| 885a-clippy-all-features-result.json | automated lint/check | 2026-10-09T07:02:25.488711+00:00 | 2026-10-09T07:02:37.940638+00:00 | 12.451724417041987 | 101 |
| 885a-clippy-default-result.json | automated lint/check | 2026-10-09T07:02:17.215470+00:00 | 2026-10-09T07:02:25.487056+00:00 | 8.271056625060737 | 101 |
| clippy-all-features-result.json | automated lint/check | 2026-10-09T06:56:17.249637+00:00 | 2026-10-09T06:56:30.664268+00:00 | 13.4144726669183 | 101 |
| clippy-default-result.json | automated lint/check | 2026-10-09T06:55:27.306222+00:00 | 2026-10-09T06:56:17.248863+00:00 | 49.94234704202972 | 101 |
| fmt-result.json | automated lint/check | 2026-10-09T06:51:38.754352+00:00 | 2026-10-09T06:51:41.095534+00:00 | 2.3407308340538293 | 0 |
| inventory-all-features-result.json | build + test/check (combined) | 2026-10-09T06:54:15.724041+00:00 | 2026-10-09T06:54:43.768246+00:00 | 28.043927707942203 | 0 |
| inventory-default-result.json | build + test/check (combined) | 2026-10-09T06:51:41.096472+00:00 | 2026-10-09T06:54:15.720471+00:00 | 154.62375462497585 | 0 |
| metadata-all-features-result.json | automated lint/check | 2026-10-09T06:51:14.499961+00:00 | 2026-10-09T06:51:14.821645+00:00 | 0.32169274997431785 | 0 |
| metadata-default-result.json | automated lint/check | 2026-10-09T06:51:04.924637+00:00 | 2026-10-09T06:51:14.438165+00:00 | 9.513539583072998 | 0 |
| ordinary-build-result.json | build | 2026-10-09T06:56:42.531273+00:00 | 2026-10-09T06:58:48.615450+00:00 | 126.08401512494311 | 0 |
| tests-all-features-result.json | build + test/check (combined) | 2026-10-09T06:55:02.672654+00:00 | 2026-10-09T06:55:27.303621+00:00 | 24.630764749948867 | 0 |
| tests-default-result.json | build + test/check (combined) | 2026-10-09T06:54:43.771160+00:00 | 2026-10-09T06:55:02.670237+00:00 | 18.898862833040766 | 0 |
| clean-before-matrix-result.json | dependency/environment or verification | 2026-10-09T07:15:09.151098+00:00 | 2026-10-09T07:15:09.871905+00:00 | 0.7206422080053017 | 0 |
| clean-before-ordinary-result.json | dependency/environment or verification | 2026-10-09T07:18:27.560457+00:00 | 2026-10-09T07:18:27.873372+00:00 | 0.31268533295951784 | 0 |
| clippy-all-features-result.json | automated lint/check | 2026-10-09T07:17:01.282653+00:00 | 2026-10-09T07:17:14.816061+00:00 | 13.53322029102128 | 101 |
| clippy-default-result.json | automated lint/check | 2026-10-09T07:16:53.780909+00:00 | 2026-10-09T07:17:01.281848+00:00 | 7.500563791021705 | 101 |
| fmt-result.json | automated lint/check | 2026-10-09T07:15:09.872678+00:00 | 2026-10-09T07:15:12.317864+00:00 | 2.4450896669877693 | 0 |
| inventory-all-features-result.json | build + test/check (combined) | 2026-10-09T07:15:43.087889+00:00 | 2026-10-09T07:16:11.365232+00:00 | 28.277206417056732 | 0 |
| inventory-default-result.json | build + test/check (combined) | 2026-10-09T07:15:12.498968+00:00 | 2026-10-09T07:15:43.084515+00:00 | 30.5847326250514 | 0 |
| metadata-all-features-result.json | automated lint/check | 2026-10-09T07:14:53.597517+00:00 | 2026-10-09T07:14:53.918570+00:00 | 0.3211063330527395 | 0 |
| metadata-default-result.json | automated lint/check | 2026-10-09T07:14:52.123114+00:00 | 2026-10-09T07:14:53.512633+00:00 | 1.3895663330331445 | 0 |
| ordinary-build-result.json | build | 2026-10-09T07:18:27.874199+00:00 | 2026-10-09T07:18:48.823373+00:00 | 20.948914667009376 | 0 |
| post-repair-clean-before-ordinary-result.json | dependency/environment or verification | 2026-10-09T07:22:19.714809+00:00 | 2026-10-09T07:22:20.383673+00:00 | 0.6686066669644788 | 0 |
| post-repair-ordinary-build-result.json | build | 2026-10-09T07:22:20.384359+00:00 | 2026-10-09T07:22:44.409473+00:00 | 24.024727333919145 | 0 |
| tests-all-features-result.json | build + test/check (combined) | 2026-10-09T07:16:30.023886+00:00 | 2026-10-09T07:16:53.778460+00:00 | 23.754435040988028 | 0 |
| tests-default-result.json | build + test/check (combined) | 2026-10-09T07:16:11.369101+00:00 | 2026-10-09T07:16:30.021530+00:00 | 18.652258833986707 | 0 |
| clean-before-ordinary-result.json | dependency/environment or verification | 2026-10-09T07:33:03.584713+00:00 | 2026-10-09T07:33:04.077602+00:00 | 0.49271195800974965 | 0 |
| clean-before-scoped-result.json | dependency/environment or verification | 2026-10-09T07:31:48.949289+00:00 | 2026-10-09T07:31:49.434341+00:00 | 0.4847132909344509 | 0 |
| fmt-result.json | automated lint/check | 2026-10-09T07:31:49.435115+00:00 | 2026-10-09T07:31:51.677034+00:00 | 2.2416474159108475 | 0 |
| inventory-all-features-result.json | build + test/check (combined) | 2026-10-09T07:32:23.129722+00:00 | 2026-10-09T07:32:55.185319+00:00 | 32.05443037499208 | 0 |
| inventory-default-result.json | build + test/check (combined) | 2026-10-09T07:31:51.677783+00:00 | 2026-10-09T07:32:23.128068+00:00 | 31.449994000024162 | 0 |
| metadata-all-features-result.json | automated lint/check | 2026-10-09T07:31:48.534008+00:00 | 2026-10-09T07:31:48.849605+00:00 | 0.3156405830522999 | 0 |
| metadata-default-result.json | automated lint/check | 2026-10-09T07:31:47.492947+00:00 | 2026-10-09T07:31:48.467953+00:00 | 0.975042040925473 | 0 |
| ordinary-build-result.json | build | 2026-10-09T07:33:04.078280+00:00 | 2026-10-09T07:33:24.309149+00:00 | 20.230756832985207 | 0 |
| tests-all-features-result.json | build + test/check (combined) | 2026-10-09T07:32:59.979076+00:00 | 2026-10-09T07:33:03.545269+00:00 | 3.5659863330656663 | 0 |
| tests-default-result.json | build + test/check (combined) | 2026-10-09T07:32:55.186704+00:00 | 2026-10-09T07:32:59.977610+00:00 | 4.7903036249335855 | 0 |
| FINAL-CORE | build + test/check (combined) | unknown | unknown | 30.339 | 0 |
| FINAL-APP | build + test/check (combined) | unknown | unknown | 33.518 | 0 |
| FINAL-STRICT | automated lint/check | unknown | unknown | 16.417 | 0 |
| FINAL-FMT | automated lint/check | unknown | unknown | 2.111 | 0 |
| ALL-FEATURES-TESTS | build + test/check (combined) | unknown | unknown | 88.246 | 0 |
| ALL-FEATURES-STRICT | automated lint/check | unknown | unknown | 24.834 | 0 |
| PACKAGE-CLEAN | dependency/environment or verification | unknown | unknown | 0.28 | 0 |
| ORDINARY-BUILD | build | unknown | unknown | 20.513 | 0 |
| Create source blob rust/crates/bello-agent-app/src/chat.rs | publication | unknown | unknown | 6.735 | completed |
| Create source blob rust/crates/bello-agent-app/src/chat_load.rs | publication | unknown | unknown | 5.775 | completed |
| Create source blob rust/crates/bello-agent-app/src/chat_load_tests.rs | publication | unknown | unknown | 12.381 | completed |
| Create source blob rust/crates/bello-agent-app/src/chat_navigation.rs | publication | unknown | unknown | 17.786 | completed |
| Create source blob rust/crates/bello-agent-app/src/chat_organization.rs | publication | unknown | unknown | 5.966 | completed |
| Create source blob rust/crates/bello-agent-app/src/main.rs | publication | unknown | unknown | 14.882 | completed |
| Create source blob rust/crates/bello-agent-app/src/project_manager_controller.rs | publication | unknown | unknown | 10.05 | completed |
| Create source blob rust/crates/bello-agent-app/src/shutdown_barrier.rs | publication | unknown | unknown | 9.971 | completed |
| Create source blob rust/crates/bello-agent-app/src/shutdown_barrier_tests.rs | publication | unknown | unknown | 5.012 | completed |
| Create source blob rust/crates/bello-agent-app/src/sidebar_read_state_tests.rs | publication | unknown | unknown | 38.555 | completed |
| Create source blob rust/crates/bello-agent-app/src/sidebar_run_state.rs | publication | unknown | unknown | 5.786 | completed |
| Create source blob rust/crates/bello-agent-app/src/sidebar_run_state_tests.rs | publication | unknown | unknown | 12.749 | completed |
| Create source blob rust/crates/bello-agent-core/src/context_recovery.rs | publication | unknown | unknown | 19.159 | completed |
| Create source blob rust/crates/bello-agent-core/src/inspection.rs | publication | unknown | unknown | 5.195 | completed |
| Create source blob rust/crates/bello-agent-core/src/inspection_tests.rs | publication | unknown | unknown | 10.201 | completed |
| Create source blob rust/crates/bello-agent-core/src/lib.rs | publication | unknown | unknown | 14.375 | completed |
| Create source blob rust/crates/bello-agent-core/src/session.rs | publication | unknown | unknown | 22.124 | completed |
| Create source blob rust/crates/bello-agent-core/src/skill_schema.rs | publication | unknown | unknown | 4.242 | completed |
| Create source blob rust/crates/bello-agent-core/src/stream_journal.rs | publication | unknown | unknown | 8.466 | completed |
| Create source blob rust/crates/bello-agent-core/src/workspace.rs | publication | unknown | unknown | 4.638 | completed |
| Create source blob rust/docs/coordinated-session-inspection.md | publication | unknown | unknown | 8.824 | completed |
| Create source blob rust/docs/parity.md | publication | unknown | unknown | 14.624 | completed |
| tree_create_seconds | publication | unknown | unknown | 15.314 | completed |
| commit_create_seconds | publication | unknown | unknown | 5.026 | completed |
| core-default | build + test/check (combined) | 2026-10-09T10:50:54.577813+00:00 | unknown | 40.401 | 0 |
| core-all-features | build + test/check (combined) | 2026-10-09T10:51:34.978936+00:00 | unknown | 57.189 | 0 |
| core-clippy-default | automated lint/check | 2026-10-09T10:52:32.168917+00:00 | unknown | 9.577 | 0 |
| core-clippy-all | automated lint/check | 2026-10-09T10:52:41.746451+00:00 | unknown | 11.462 | 0 |
| format | automated lint/check | 2026-10-09T10:52:53.208320+00:00 | unknown | 2.148 | 0 |
| app-default | build + test/check (combined) | 2026-10-09T10:52:58.345758+00:00 | unknown | 48.834 | 0 |
| app-all-features | build + test/check (combined) | 2026-10-09T10:53:47.180621+00:00 | unknown | 55.061 | 0 |
| app-clippy-default | automated lint/check | 2026-10-09T10:54:42.242288+00:00 | unknown | 13.367 | 0 |
| app-clippy-all | automated lint/check | 2026-10-09T10:54:55.609914+00:00 | unknown | 14.857 | 0 |
| omit_uncertainty | build + test/check (combined) | unknown | unknown | 17.368 | Expected negative-control failure; source restored |
| omit_poison_check | build + test/check (combined) | unknown | unknown | 18.054 | Expected negative-control failure; source restored |
| reuse_incarnation | build + test/check (combined) | unknown | unknown | 17.196 | Expected negative-control failure; source restored |
| omit_unwind_fence | build + test/check (combined) | unknown | unknown | 17.33 | Expected negative-control failure; source restored |
| permit_rebinding | build + test/check (combined) | unknown | unknown | 17.803 | Expected negative-control failure; source restored |
| omit_final_recheck | build + test/check (combined) | unknown | unknown | 17.141 | Expected negative-control failure; source restored |
| wrap_epoch | build + test/check (combined) | unknown | unknown | 17.001 | Expected negative-control failure; source restored |
| omit_drop_retirement | build + test/check (combined) | unknown | unknown | 17.372 | Expected negative-control failure; source restored |
| reuse_epoch | build + test/check (combined) | unknown | unknown | 17.247 | Expected negative-control failure; source restored |
| initial-focused | build + test/check (combined) | 2026-10-09T11:05:30.422733+00:00 | unknown | 19.342222 | 0 |
| guarded-focused | build + test/check (combined) | 2026-10-09T11:09:30.552932+00:00 | unknown | 9.105983 | 101 |
| guarded-focused-fixed | build + test/check (combined) | 2026-10-09T11:10:03.617526+00:00 | unknown | 18.640265 | 0 |
| pure-projection | build + test/check (combined) | 2026-10-09T11:10:35.247515+00:00 | unknown | 12.272778 | 0 |
| final-focused-before-controls | build + test/check (combined) | 2026-10-09T11:14:53.452229+00:00 | unknown | 19.934243 | 0 |
| strict-core-before-controls | automated lint/check | 2026-10-09T11:15:13.428623+00:00 | unknown | 9.702933 | 101 |
| strict-core-fixed | automated lint/check | 2026-10-09T11:15:54.078660+00:00 | unknown | 0.372263 | 101 |
| strict-core-final | automated lint/check | 2026-10-09T11:16:04.737550+00:00 | unknown | 10.557313 | 0 |
| workspace-format | automated lint/check | 2026-10-09T11:17:12.103575+00:00 | unknown | 2.310065 | 0 |
| source-whitespace | build + test/check (combined) | 2026-10-09T11:17:14.447877+00:00 | unknown | 0.013395 | 0 |
| restored-focused | build + test/check (combined) | 2026-10-09T11:20:03.765796+00:00 | unknown | 0.268485 | 101 |
| clean-core-after-mutants | dependency/environment or verification | 2026-10-09T11:20:29.318743+00:00 | unknown | 0.212498 | 0 |
| clean-restored-focused | dependency/environment or verification | 2026-10-09T11:20:29.560998+00:00 | unknown | 19.740731 | 0 |
| clean-restored-pure | dependency/environment or verification | 2026-10-09T11:20:49.337161+00:00 | unknown | 13.185227 | 0 |
| loc-verifier | build + test/check (combined) | 2026-10-09T11:21:52.685010+00:00 | unknown | 1.565317 | 0 |
| final-core-default | build + test/check (combined) | 2026-10-09T11:28:00.770043+00:00 | unknown | 25.417021 | 0 |
| final-core-all-features | build + test/check (combined) | 2026-10-09T11:28:26.226821+00:00 | unknown | 82.724481 | 0 |
| final-core-clippy-default | automated lint/check | 2026-10-09T11:29:48.979461+00:00 | unknown | 9.989475 | 0 |
| final-core-clippy-all-features | automated lint/check | 2026-10-09T11:29:58.995985+00:00 | unknown | 12.827144 | 0 |
| clean-app-final | dependency/environment or verification | 2026-10-09T11:30:11.855840+00:00 | unknown | 0.146464 | 0 |
| final-app-default | build + test/check (combined) | 2026-10-09T11:30:12.034290+00:00 | unknown | 65.083309 | 0 |
| final-app-all-features | build + test/check (combined) | 2026-10-09T11:31:17.146727+00:00 | unknown | 66.124266 | 0 |
| final-app-clippy-default | automated lint/check | 2026-10-09T11:32:23.303562+00:00 | unknown | 20.4253 | 0 |
| final-app-clippy-all-features | automated lint/check | 2026-10-09T11:32:43.760535+00:00 | unknown | 15.824093 | 0 |
| final-workspace-format | automated lint/check | 2026-10-09T11:32:59.612092+00:00 | unknown | 2.081215 | 0 |
| final-source-whitespace | build + test/check (combined) | 2026-10-09T11:33:01.720291+00:00 | unknown | 0.023249 | 0 |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.

### Earlier accounting (unchanged)

## Checkpoint: 2026-10-09T08:43:00Z

This adds selected newly obtained receipts, including earlier intervals not present in the 08:08 snapshot. Historical records and previous checkpoint coverage remain unchanged. Unknown inference stays unavailable. Source/receipt hashes identify evidence; local observer timing is not independently verified merely by a source commit link.

| Group | Timed items | Resource/client seconds | Exact-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| new_local_command | 8 | 209.302 | 8 | 209.302 | 209.302 |
| new_api_operation | 7 | 45.653 | 0 | 0.000 | unavailable |
| new_native_command | 75 | 506.149 | 74 | 500.224 | 500.244 |

Resource sums, interval unions, mixed windows and nested Cargo phase subtotals are separate accounting views. Do not add them into a total time budget. Parallel client/API durations include waiting, not server compute. Whole-second 0s means below receipt resolution, not zero effort. Absent endpoints exclude items from wall unions.

| Group / category | Seconds |
|---|---:|
| new_local_command: automated lint/check | 35.903 |
| new_local_command: build + test/check (combined) | 155.796 |
| new_local_command: dependency/environment or source verification | 0.294 |
| new_local_command: build | 17.309 |
| new_api_operation: publication / retry | 45.653 |
| new_native_command: build + test/check (combined) | 308.707 |
| new_native_command: dependency/environment or source verification | 16.433 |
| new_native_command: automated lint/check | 132.559 |
| new_native_command: build | 42.526 |
| new_native_command: dependency/environment recovery | 5.925 |

### Per-item observations

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| fmt | automated lint/check | 2026-10-09T08:03:25.860880+00:00 | 2026-10-09T08:03:28.041967+00:00 | 2.1810742410016246 | passed |
| focused-restored-app | build + test/check (combined) | 2026-10-09T08:03:28.042296+00:00 | 2026-10-09T08:03:57.797400+00:00 | 29.755095814995002 | passed |
| workspace-default | build + test/check (combined) | 2026-10-09T08:03:57.798025+00:00 | 2026-10-09T08:04:45.723458+00:00 | 47.925424418994226 | passed |
| workspace-all-features | build + test/check (combined) | 2026-10-09T08:04:45.723876+00:00 | 2026-10-09T08:06:03.839629+00:00 | 78.11574400600512 | passed |
| clippy-default | automated lint/check | 2026-10-09T08:06:03.840457+00:00 | 2026-10-09T08:06:21.814358+00:00 | 17.973891509995156 | passed |
| clippy-all-features | automated lint/check | 2026-10-09T08:06:21.814729+00:00 | 2026-10-09T08:06:37.562881+00:00 | 15.748145714998827 | passed |
| package-clean | dependency/environment or source verification | 2026-10-09T08:06:47.997387+00:00 | 2026-10-09T08:06:48.291130+00:00 | 0.29374756300239824 | passed |
| ordinary-build | build | 2026-10-09T08:06:48.291463+00:00 | 2026-10-09T08:07:05.600623+00:00 | 17.309179434996622 | passed |
| initial blob denied | publication / retry | unknown | unknown | 10.324 | denied |
| same blob authorized retry | publication / retry | unknown | unknown | 8.462 | passed |
| authority blob | publication / retry | unknown | unknown | 9.271 | passed |
| tree create | publication / retry | unknown | unknown | 9.183 | passed |
| commit create | publication / retry | unknown | unknown | 7.329 | passed |
| commit_seconds | publication / retry | unknown | unknown | 0.334 | passed |
| tree_seconds | publication / retry | unknown | unknown | 0.75 | passed |
| Composed source publication and readback | publication (mixed) | 2026-10-09T08:30:40Z | 2026-10-09T08:31:02Z | 22 | completed |
| integrated-gui | interactive validation (mixed) | 2026-10-09T08:09:33.018701+00:00 | 2026-10-09T08:12:57.543153+00:00 | 204.524452 | completed |
| actual-compiler-cfg-all-features | build + test/check (combined) | 2026-10-09T07:50:22.327462+00:00 | 2026-10-09T07:50:32.794480+00:00 | 10.46686275000684 | passed |
| actual-compiler-cfg-default | build + test/check (combined) | 2026-10-09T07:50:06.889163+00:00 | 2026-10-09T07:50:22.299328+00:00 | 15.409974584006704 | passed |
| actual-core-correction-reverted | build + test/check (combined) | 2026-10-09T07:50:38.868287+00:00 | 2026-10-09T07:50:47.428489+00:00 | 8.56000270799268 | expected negative-control failure |
| actual-manifest-expectation-omitted-all-features | build + test/check (combined) | 2026-10-09T07:50:57.919944+00:00 | 2026-10-09T07:51:11.880997+00:00 | 13.960888999979943 | expected negative-control failure |
| actual-manifest-expectation-omitted-default | build + test/check (combined) | 2026-10-09T07:50:47.620863+00:00 | 2026-10-09T07:50:57.918637+00:00 | 10.297562415944412 | expected negative-control failure |
| actual-reject-legacy-feature-all-features | build + test/check (combined) | 2026-10-09T07:50:22.301540+00:00 | 2026-10-09T07:50:22.326774+00:00 | 0.025055459002032876 | expected negative-control failure |
| actual-reject-legacy-feature-default | build + test/check (combined) | 2026-10-09T07:50:06.841712+00:00 | 2026-10-09T07:50:06.888420+00:00 | 0.04649849992711097 | expected negative-control failure |
| control-worktree-create | dependency/environment or source verification | 2026-10-09T07:50:32.795570+00:00 | 2026-10-09T07:50:38.738230+00:00 | 5.94269658299163 | passed |
| control-worktree-remove | dependency/environment or source verification | 2026-10-09T07:51:12.031487+00:00 | 2026-10-09T07:51:12.338462+00:00 | 0.30704483401495963 | passed |
| core-authority-tests-all | build + test/check (combined) | 2026-10-09T07:53:03.708009+00:00 | 2026-10-09T07:53:39.805964+00:00 | 36.0976893750485 | passed |
| core-authority-tests-default | build + test/check (combined) | 2026-10-09T07:52:34.510049+00:00 | 2026-10-09T07:53:03.706231+00:00 | 29.1959380840417 | passed |
| core-lib-clippy-all | automated lint/check | 2026-10-09T07:52:28.136368+00:00 | 2026-10-09T07:52:34.509079+00:00 | 6.372626958065666 | passed |
| core-lib-clippy-default | automated lint/check | 2026-10-09T07:52:00.446635+00:00 | 2026-10-09T07:52:14.835363+00:00 | 14.388524667010643 | passed |
| core-lib-clippy-native | automated lint/check | 2026-10-09T07:52:14.836193+00:00 | 2026-10-09T07:52:21.899889+00:00 | 7.063586708973162 | passed |
| core-lib-clippy-synthetic | automated lint/check | 2026-10-09T07:52:21.901171+00:00 | 2026-10-09T07:52:28.135696+00:00 | 6.23438683396671 | passed |
| final-app-clippy-all-features | automated lint/check | 2026-10-09T07:51:48.356652+00:00 | 2026-10-09T07:52:00.445147+00:00 | 12.088319333968684 | passed |
| final-app-clippy-default | automated lint/check | 2026-10-09T07:51:37.178515+00:00 | 2026-10-09T07:51:48.355647+00:00 | 11.176776958978735 | passed |
| final-clean-ordinary-app-core | dependency/environment or source verification | 2026-10-09T07:53:42.307493+00:00 | 2026-10-09T07:53:42.737108+00:00 | 0.42939100007060915 | passed |
| fixture-generate-lock | dependency/environment or source verification | 2026-10-09T07:47:57.150927+00:00 | 2026-10-09T07:47:57.176407+00:00 | 0.025309916934929788 | passed |
| fixture-legacy-default-inactive | build + test/check (combined) | 2026-10-09T07:47:57.177465+00:00 | 2026-10-09T07:47:57.622080+00:00 | 0.4442865001037717 | failed fixture; corrected in later separate receipt |
| fmt | automated lint/check | 2026-10-09T07:53:39.806851+00:00 | 2026-10-09T07:53:42.173232+00:00 | 2.3662612499902025 | passed |
| git-diff-check | automated lint/check | 2026-10-09T07:53:42.173931+00:00 | 2026-10-09T07:53:42.265019+00:00 | 0.09111591696273535 | passed |
| initial-clean-ordinary-app-core | dependency/environment or source verification | 2026-10-09T07:47:26.029670+00:00 | 2026-10-09T07:47:26.874708+00:00 | 0.8444503330392763 | passed |
| initial-clean-test-app-core | dependency/environment or source verification | 2026-10-09T07:47:25.015889+00:00 | 2026-10-09T07:47:26.028825+00:00 | 1.0127002079971135 | passed |
| metadata-all-features | dependency/environment or source verification | 2026-10-09T07:47:24.583089+00:00 | 2026-10-09T07:47:24.901935+00:00 | 0.31890641595236957 | passed |
| metadata-default | dependency/environment or source verification | 2026-10-09T07:47:23.223543+00:00 | 2026-10-09T07:47:24.528346+00:00 | 1.3048370409524068 | passed |
| ordinary-build | build | 2026-10-09T07:53:42.737903+00:00 | 2026-10-09T07:54:05.433071+00:00 | 22.695008042035624 | passed |
| patch-pristine-apply-check | dependency/environment or source verification | 2026-10-09T07:51:11.956643+00:00 | 2026-10-09T07:51:11.982011+00:00 | 0.02541550004389137 | passed |
| patch-pristine-apply | dependency/environment or source verification | 2026-10-09T07:51:11.982534+00:00 | 2026-10-09T07:51:12.007407+00:00 | 0.024920459021814167 | passed |
| v2-fixture-generate-lock | dependency/environment or source verification | 2026-10-09T07:49:40.499450+00:00 | 2026-10-09T07:49:40.547131+00:00 | 0.04747270804364234 | passed |
| v2-fixture-legacy-all-inactive | build + test/check (combined) | 2026-10-09T07:49:40.869370+00:00 | 2026-10-09T07:49:40.955050+00:00 | 0.08558229100890458 | passed |
| v2-fixture-legacy-default-inactive | build + test/check (combined) | 2026-10-09T07:49:40.548056+00:00 | 2026-10-09T07:49:40.868375+00:00 | 0.32024858403019607 | passed |
| v2-fixture-legacy-runtime-all | build + test/check (combined) | 2026-10-09T07:49:41.807942+00:00 | 2026-10-09T07:49:41.962536+00:00 | 0.1539502500090748 | passed |
| v2-fixture-legacy-runtime-default | build + test/check (combined) | 2026-10-09T07:49:40.956062+00:00 | 2026-10-09T07:49:41.807035+00:00 | 0.8507163330214098 | passed |
| v2-fixture-macos-native-constructor-removed | build + test/check (combined) | 2026-10-09T07:49:43.207940+00:00 | 2026-10-09T07:49:43.298349+00:00 | 0.09029429196380079 | expected negative-control failure |
| v2-fixture-misspelled-cfg | build + test/check (combined) | 2026-10-09T07:49:42.113105+00:00 | 2026-10-09T07:49:42.199626+00:00 | 0.0862996670184657 | expected negative-control failure |
| v2-fixture-misspelled-feature | build + test/check (combined) | 2026-10-09T07:49:41.963573+00:00 | 2026-10-09T07:49:42.111795+00:00 | 0.14793195901438594 | expected negative-control failure |
| v2-fixture-production-lib-all | build + test/check (combined) | 2026-10-09T07:49:43.033906+00:00 | 2026-10-09T07:49:43.120542+00:00 | 0.08644287497736514 | passed |
| v2-fixture-production-lib-default | build + test/check (combined) | 2026-10-09T07:49:42.382980+00:00 | 2026-10-09T07:49:42.578538+00:00 | 0.19543529197108 | passed |
| v2-fixture-production-lib-native | build + test/check (combined) | 2026-10-09T07:49:42.669165+00:00 | 2026-10-09T07:49:42.760583+00:00 | 0.09128912503365427 | passed |
| v2-fixture-production-lib-synthetic | build + test/check (combined) | 2026-10-09T07:49:42.854642+00:00 | 2026-10-09T07:49:42.945174+00:00 | 0.09044083394110203 | passed |
| v2-fixture-production-test-all | build + test/check (combined) | 2026-10-09T07:49:43.122045+00:00 | 2026-10-09T07:49:43.206709+00:00 | 0.08440599997993559 | passed |
| v2-fixture-production-test-default | build + test/check (combined) | 2026-10-09T07:49:42.579733+00:00 | 2026-10-09T07:49:42.668343+00:00 | 0.08845999999903142 | passed |
| v2-fixture-production-test-native | build + test/check (combined) | 2026-10-09T07:49:42.761974+00:00 | 2026-10-09T07:49:42.853621+00:00 | 0.09152554103638977 | passed |
| v2-fixture-production-test-synthetic | build + test/check (combined) | 2026-10-09T07:49:42.946406+00:00 | 2026-10-09T07:49:43.033095+00:00 | 0.08653887500986457 | passed |
| v2-fixture-test-constructor-removed | build + test/check (combined) | 2026-10-09T07:49:43.299351+00:00 | 2026-10-09T07:49:43.378505+00:00 | 0.07904691598378122 | expected negative-control failure |
| v2-fixture-unconstructed-enum | build + test/check (combined) | 2026-10-09T07:49:42.287091+00:00 | 2026-10-09T07:49:42.381644+00:00 | 0.08861570793669671 | expected negative-control failure |
| v2-fixture-unused-local | build + test/check (combined) | 2026-10-09T07:49:42.200917+00:00 | 2026-10-09T07:49:42.285367+00:00 | 0.08428779104724526 | expected negative-control failure |
| APFS copy-on-write deduplication of 562 byte-identical cache files | dependency/environment recovery | unknown | unknown | 5.924546291935258 | passed |
| clean-before-all-feature-retry | dependency/environment or source verification | 2026-10-09T08:16:46.370355+00:00 | 2026-10-09T08:16:47.101777+00:00 | 0.7311118750367314 | passed |
| clean-before-ordinary | dependency/environment or source verification | 2026-10-09T08:23:43.100725+00:00 | 2026-10-09T08:23:43.488840+00:00 | 0.3879264580318704 | passed |
| clippy-all-features | automated lint/check | 2026-10-09T08:22:46.199901+00:00 | 2026-10-09T08:23:42.214353+00:00 | 56.01429945894051 | passed |
| clippy-default | automated lint/check | 2026-10-09T08:12:08.510101+00:00 | 2026-10-09T08:12:22.396653+00:00 | 13.885679875034839 | passed |
| diff-check | automated lint/check | 2026-10-09T08:11:10.362899+00:00 | 2026-10-09T08:11:10.464939+00:00 | 0.10204837506171316 | passed |
| fmt | automated lint/check | 2026-10-09T08:11:07.586896+00:00 | 2026-10-09T08:11:10.362184+00:00 | 2.7749705830356106 | passed |
| inventory-app-all-features-after-cache-recovery | build + test/check (combined) | 2026-10-09T08:16:47.102489+00:00 | 2026-10-09T08:17:25.905583+00:00 | 38.80265187495388 | passed |
| inventory-app-all-features | build + test/check (combined) | 2026-10-09T08:12:22.756222+00:00 | 2026-10-09T08:12:57.157745+00:00 | 34.401384124998 | failed: ENOSPC; original failure preserved; exact later retry is separate |
| inventory-app-default | build + test/check (combined) | 2026-10-09T08:11:10.513353+00:00 | 2026-10-09T08:11:45.769955+00:00 | 35.25637795799412 | passed |
| inventory-core-existing-all-features | build + test/check (combined) | 2026-10-09T08:22:45.595832+00:00 | 2026-10-09T08:22:45.840448+00:00 | 0.2444106669863686 | passed |
| inventory-core-existing-default | build + test/check (combined) | 2026-10-09T08:12:07.904166+00:00 | 2026-10-09T08:12:08.136263+00:00 | 0.23175629100296646 | passed |
| inventory-core-initial-all-features-after-metadata-recovery | build + test/check (combined) | 2026-10-09T08:22:21.226655+00:00 | 2026-10-09T08:22:44.645732+00:00 | 23.418913415982388 | passed |
| inventory-core-initial-all-features | build + test/check (combined) | 2026-10-09T08:17:29.431273+00:00 | 2026-10-09T08:17:52.518060+00:00 | 23.08656570909079 | failed: ENOSPC; original failure preserved; exact later retry is separate |
| inventory-core-initial-default | build + test/check (combined) | 2026-10-09T08:11:48.780169+00:00 | 2026-10-09T08:12:06.955567+00:00 | 18.175217333016917 | passed |
| metadata-all-features | dependency/environment or source verification | 2026-10-09T08:11:07.049166+00:00 | 2026-10-09T08:11:07.515945+00:00 | 0.46681291598360986 | passed |
| metadata-default | dependency/environment or source verification | 2026-10-09T08:11:05.307776+00:00 | 2026-10-09T08:11:06.984784+00:00 | 1.6770502079743892 | passed |
| ordinary-build | build | 2026-10-09T08:23:43.489479+00:00 | 2026-10-09T08:24:03.320434+00:00 | 19.830512124928646 | passed |
| reclaim-after-default | dependency/environment or source verification | 2026-10-09T08:12:22.446034+00:00 | 2026-10-09T08:12:22.719750+00:00 | 0.27335841697640717 | passed |
| reclaim-check-metadata-after-strict | dependency/environment recovery | unknown | unknown | unknown | passed |
| reclaim-inventoried-check-metadata | dependency/environment recovery | unknown | unknown | unknown | passed |
| reclaim-ordinary-app-core | dependency/environment or source verification | 2026-10-09T08:08:28.238754+00:00 | 2026-10-09T08:08:28.728706+00:00 | 0.4898728330153972 | passed |
| reclaim-test-app-core | dependency/environment or source verification | 2026-10-09T08:08:26.114271+00:00 | 2026-10-09T08:08:28.238096+00:00 | 2.1236145000439137 | passed |
| tests-app-all-features | build + test/check (combined) | 2026-10-09T08:17:25.907655+00:00 | 2026-10-09T08:17:28.783584+00:00 | 2.87565399997402 | passed |
| tests-app-default | build + test/check (combined) | 2026-10-09T08:11:45.771280+00:00 | 2026-10-09T08:11:48.337768+00:00 | 2.566163167008199 | passed |
| tests-core-existing-all-features | build + test/check (combined) | 2026-10-09T08:22:45.841475+00:00 | 2026-10-09T08:22:46.199065+00:00 | 0.35743554192595184 | passed |
| tests-core-existing-default | build + test/check (combined) | 2026-10-09T08:12:08.137678+00:00 | 2026-10-09T08:12:08.493167+00:00 | 0.3553724579978734 | passed |
| tests-core-initial-all-features | build + test/check (combined) | 2026-10-09T08:22:44.646702+00:00 | 2026-10-09T08:22:45.467267+00:00 | 0.8204687499674037 | passed |
| tests-core-initial-default | build + test/check (combined) | 2026-10-09T08:12:06.958158+00:00 | 2026-10-09T08:12:07.767506+00:00 | 0.8086569999577478 | passed |
| Prepare, review and publish previous timing checkpoint | review/publication/waiting (mixed) | 2026-10-09T07:53:14Z | 2026-10-09T08:12:33Z | 1159 | completed |
| Rust Linux checks | CI status | unknown | unknown | unknown | success |
| Rust macOS native checks | CI status | unknown | unknown | unknown | in_progress |

### Mixed-window groups (not resource totals)

| Category | Windows | Known-endpoint union seconds |
|---|---:|---:|
| interactive validation (mixed) | 1 | 204.524 |
| publication (mixed) | 1 | 22.000 |
| review/publication/waiting (mixed) | 1 | 1159.000 |

Mixed work windows overlap commands and each other; no active implementation, review or inference time is inferred. Native final-receipt aggregates duplicate individual results and are excluded. Original failed native ENOSPC attempts and exact retries remain separate; APFS copy-on-write recovery timing is measured where available, but metadata removal lacks a timer and stays unknown. Independently verified delivery is not a new native execution. CI rows here are status observations only. No full native suite or GUI claim is added.

### Earlier checkpoints (preserved)

## Incremental checkpoint: 2026-10-09T08:08:00Z

Historical audit below and its original CI cutoff remain unchanged. This update covers selected newly recorded work, not every intervening run or task. Unknown durations and inference remain unavailable. Local timing observations below are source records supported by retained receipt hashes; public commit links identify source or outcome, not independent timing verification.

### Separate resource totals

| Group | All timed items | All resource/client seconds | Known-endpoint items | Known-endpoint resource seconds | Known-endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| incremental_api | 58 | 427.621 | 50 | 389.193 | 254.901 |
| incremental_command | 64 | 956.457 | 39 | 517.000 | 517.000 |
| incremental_ci_job | 2 | 2171.000 | 2 | 2171.000 | 1424.000 |

| Resource group / category | Seconds |
|---|---:|
| incremental_api: publication / verification | 427.621 |
| incremental_command: dependency/environment or verification | 67.239 |
| incremental_command: build + test/check (combined) | 707.268 |
| incremental_command: automated lint/check | 112.846 |
| incremental_command: build | 69.104 |
| incremental_ci_job: CI | 2171.000 |

API elapsed sums include overlapping pending calls and client/service waiting; they are not server compute or active work. Command sums include build/test mixtures. Whole-second 0s observations mean below the receipt counter resolution, not zero effort. Missing or arithmetically derived end timestamps are excluded from known-endpoint unions. CI steps are nested and excluded from job sums. These groups must not be added to mixed task windows or treated as project elapsed time.

### Where newly observed task time went

15 mixed task windows; union of closed observed intervals: 7889.000 seconds. This includes overlap and waiting; it is not an active-work, CPU or inference total. Unfinished waits keep an unknown final duration.

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Timing-report GitHub blob publication waiting for platform confirmation | waiting | 2026-10-09T06:08:37Z | 2026-10-09T07:49:53Z | 6076.0 | approval_resolved_blob_created |
| Selected-chat Find waits for shared Box dependency publication after local candidate matrix | waiting | 2026-10-09T05:41:15Z | 2026-10-09T07:00:39Z | 4764 | publication_gate_satisfied_ci_pending |
| Immutable selected-chat Find source candidate preparation and verification | publication/preparation (mixed) | 2026-10-09T06:25:09Z | 2026-10-09T06:30:09Z | 300.0 | completed |
| Actual Git-pinned source-before | dependency/environment or verification | 2026-10-09T06:27:57Z | 2026-10-09T06:27:57Z | 0.0 | completed |
| Actual Git-pinned toolchain | dependency/environment or verification | 2026-10-09T06:27:57Z | 2026-10-09T06:27:57Z | 0.0 | completed |
| Actual Git-pinned fetch | dependency/environment or verification | 2026-10-09T06:27:57Z | 2026-10-09T06:28:21Z | 24.0 | completed |
| Actual Git-pinned metadata | dependency/environment or verification | 2026-10-09T06:28:21Z | 2026-10-09T06:28:22Z | 1.0 | completed |
| Actual Git-pinned app-default | build + test/check (combined) | 2026-10-09T06:28:22Z | 2026-10-09T06:29:15Z | 53.0 | completed |
| Actual Git-pinned app-all-features | build + test/check (combined) | 2026-10-09T06:29:15Z | 2026-10-09T06:30:25Z | 70.0 | completed |
| Actual Git-pinned clippy-default | automated lint/check | 2026-10-09T06:30:25Z | 2026-10-09T06:30:34Z | 9.0 | completed |
| Actual Git-pinned clippy-all-features | automated lint/check | 2026-10-09T06:30:34Z | 2026-10-09T06:30:44Z | 10.0 | completed |
| Actual Git-pinned fmt | automated lint/check | 2026-10-09T06:30:44Z | 2026-10-09T06:30:46Z | 2.0 | completed |
| Actual Git-pinned diff-check | automated lint/check | 2026-10-09T06:30:46Z | 2026-10-09T06:30:46Z | 0.0 | completed |
| Actual Git-pinned package-clean | dependency/environment or verification | 2026-10-09T06:30:46Z | 2026-10-09T06:30:46Z | 0.0 | completed |
| Actual Git-pinned ordinary-build | build | 2026-10-09T06:30:46Z | 2026-10-09T06:31:03Z | 17.0 | completed |
| Actual Git-pinned source-after | dependency/environment or verification | 2026-10-09T06:31:03Z | 2026-10-09T06:31:03Z | 0.0 | completed |
| Ordinary Linux Find GUI acceptance: short chat and seeded history; overlay occlusion found | validation (mixed) | 2026-10-09T06:33:52Z | 2026-10-09T06:43:04Z | 552 | failed_with_independent_passes |
| Sidebar search architecture and acceptance design | review/documentation (mixed) | 2026-10-09T06:37:38+00:00 | 2026-10-09T06:42:49.201430+00:00 | 311.20143 | completed |
| Independent sidebar index and privacy review | review/documentation (mixed) | 2026-10-09T06:43:21Z | 2026-10-09T06:45:55Z | 154.0 | completed |
| Official dependency research, isolated probes and enforcement addendum | dependency/environment (mixed) | 2026-10-09T06:46:43Z | 2026-10-09T06:55:21.950025+00:00 | 518.950025 | completed |
| Isolated official dependency resolve | dependency/environment or verification | 2026-10-09T06:50:51.470064+00:00 | unknown | 17.92824319600186 | completed |
| Isolated official dependency metadata | dependency/environment or verification | 2026-10-09T06:51:18.161061+00:00 | unknown | 5.449316037003882 | completed |
| Isolated official dependency probe189 | dependency/environment or verification | 2026-10-09T06:52:16.662576+00:00 | unknown | 8.207819590999861 | failed_assertion |
| Isolated official dependency probe189-refined | dependency/environment or verification | 2026-10-09T06:52:36.625088+00:00 | unknown | 0.3228246350045083 | completed |
| Isolated official dependency probe199 | dependency/environment or verification | 2026-10-09T06:52:41.405380+00:00 | unknown | 8.109944761999941 | completed |
| Observed official-download poll cancellation and authorized retry note | design_and_review | 2026-10-09T06:49:02Z | unknown | unknown | cancellation_observed_retry_success_reported |
| upload_blob | publication / verification | 2026-10-09T07:04:33.940Z | 2026-10-09T07:04:40.251Z | 6.311 | completed |
| upload_blob | publication / verification | 2026-10-09T07:04:33.942Z | 2026-10-09T07:04:46.543Z | 12.601 | completed |
| upload_blob | publication / verification | 2026-10-09T07:04:33.943Z | 2026-10-09T07:04:51.395Z | 17.452 | completed |
| upload_blob | publication / verification | 2026-10-09T07:04:33.943Z | 2026-10-09T07:04:56.092Z | 22.149 | completed |
| upload_blob | publication / verification | 2026-10-09T07:04:33.943Z | 2026-10-09T07:05:03.099Z | 29.156 | completed |
| upload_blob | publication / verification | 2026-10-09T07:04:33.945Z | 2026-10-09T07:05:10.071Z | 36.126 | completed |
| upload_blob | publication / verification | 2026-10-09T07:04:33.944Z | 2026-10-09T07:05:15.217Z | 41.273 | completed |
| upload_tree | publication / verification | 2026-10-09T07:05:20.560Z | 2026-10-09T07:05:31.680Z | 11.12 | completed |
| upload_commit | publication / verification | 2026-10-09T07:05:36.988Z | 2026-10-09T07:05:42.624Z | 5.636 | completed |
| remote_readback | publication / verification | 2026-10-09T07:05:53.730Z | 2026-10-09T07:05:54.023Z | 0.293 | completed |
| remote_readback | publication / verification | 2026-10-09T07:05:53.730Z | 2026-10-09T07:05:54.068Z | 0.338 | completed |
| remote_readback | publication / verification | 2026-10-09T07:05:53.730Z | 2026-10-09T07:05:54.125Z | 0.395 | completed |
| remote_readback | publication / verification | 2026-10-09T07:05:53.730Z | 2026-10-09T07:05:54.131Z | 0.401 | completed |
| remote_readback | publication / verification | 2026-10-09T07:05:53.730Z | 2026-10-09T07:05:54.178Z | 0.448 | completed |
| remote_readback | publication / verification | 2026-10-09T07:05:53.730Z | 2026-10-09T07:05:54.226Z | 0.496 | completed |
| remote_readback | publication / verification | 2026-10-09T07:05:53.730Z | 2026-10-09T07:05:54.232Z | 0.502 | completed |
| public_fetch | publication / verification | 2026-10-09T07:06:13.337905+00:00 | 2026-10-09T07:06:27.573858+00:00 | 14.23594502400374 | completed |
| Frozen landing final matrix and clean build | validation (mixed) | 2026-10-09T07:02:33Z | 2026-10-09T07:05:18Z | 165.0 | completed |
| upload_blob | publication / verification | 2026-10-09T07:23:19.717Z | 2026-10-09T07:23:27.451Z | 7.734 | completed |
| upload_blob | publication / verification | 2026-10-09T07:23:19.718Z | 2026-10-09T07:23:38.214Z | 18.496 | completed |
| upload_tree | publication / verification | 2026-10-09T07:23:45.948Z | 2026-10-09T07:23:52.663Z | 6.715 | completed |
| upload_commit | publication / verification | 2026-10-09T07:23:52.663Z | 2026-10-09T07:23:58.048Z | 5.385 | completed |
| remote_readback | publication / verification | 2026-10-09T07:24:12.911Z | 2026-10-09T07:24:13.308Z | 0.397 | completed |
| remote_readback | publication / verification | 2026-10-09T07:24:12.911Z | 2026-10-09T07:24:13.481Z | 0.57 | completed |
| public_fetch | publication / verification | 2026-10-09T07:24:13.885281+00:00 | 2026-10-09T07:24:23.309522+00:00 | 9.424232270001085 | completed |
| Notice final frozen matrix and clean build | validation (mixed) | 2026-10-09T07:21:36Z | 2026-10-09T07:24:24Z | 168.0 | completed |
| B27 actual Linux GUI retest with residual notice observations | validation (mixed) | 2026-10-09T07:07:24+00:00 | 2026-10-09T07:17:47+00:00 | 623 | completed |
| Final 570 focused actual Linux Find notice GUI acceptance | validation (mixed) | 2026-10-09T07:26:13+00:00 | 2026-10-09T07:31:58+00:00 | 345.0 | completed |
| Final Find source publication and branch readback | publication/preparation (mixed) | 2026-10-09T07:40:22Z | 2026-10-09T07:40:57Z | 35 | completed |
| Separate multiline title-layout implementation and source validation | implementation/rework + validation (mixed) | 2026-10-09T07:28:11+00:00 | 2026-10-09T07:39:13.277693+00:00 | 662.277693 | completed |
| Separate title immutable source preparation measured API resources | source_publication_resources | unknown | unknown | 38.428000000000004 | completed |
| Separate title multiline layout and ASCII derivation actual Linux GUI | validation (mixed) | 2026-10-09T07:40:56.765267+00:00 | 2026-10-09T07:44:00.600154+00:00 | 183.834887 | completed |
| Exact Find570 Linux CI job | CI | 2026-10-09T07:41:02Z | 2026-10-09T07:53:31Z | 749.0 | completed_success |
| Exact Find570 apple-silicon CI job | CI | 2026-10-09T07:41:04Z | 2026-10-09T08:04:46Z | 1422.0 | completed_success |
| Exact Find570 two-job elapsed CI coverage | ci_interval_union | 2026-10-09T07:41:02+00:00 | 2026-10-09T08:04:46+00:00 | 1424.0 | completed_success |
| Publish both initial migration timing reports and verify readbacks | publication | 2026-10-09T06:07:44Z | 2026-10-09T07:52:44Z | 6300.0 | Both initial timing reports published |

### Mixed-window groups (not resource totals)

| Category | All windows | Closed windows with endpoints | Closed interval union (seconds) |
|---|---:|---:|---:|
| dependency/environment (mixed) | 1 | 1 | 518.950 |
| implementation/rework + validation (mixed) | 1 | 1 | 662.278 |
| publication | 1 | 1 | 6300.000 |
| publication/preparation (mixed) | 2 | 2 | 335.000 |
| review/documentation (mixed) | 2 | 2 | 465.201 |
| validation (mixed) | 6 | 6 | 2036.835 |
| waiting | 2 | 2 | 7718.000 |

Categories can overlap each other and include productive parallel work during waits. Do not sum category unions or interpret any category as active labor.

Per-command and API child records, nested CI steps, source hashes and uncertainty are retained in duration-data.json. Nested child resource totals are counted once in their separate group; their parent windows remain excluded. Shared editor work is assigned to BelloBox; shared initial timing-publication wait is represented once in BelloAgent.

## Historical audit (original coverage below)

Generated: 2026-10-09T06:06:30.663402Z. CI evidence cutoff: 2026-10-09T06:00:00Z. Source checkpoint: [`885a5bcf`](https://github.com/BelloWare/BelloAgent/commit/885a5bcf6e608361692e877d7c77941b0db2f4d8). All dates below are UTC.

## Honest summary

- The recorded CI window spans **120h 46m 30.0s** from 2026-10-04T05:13:30Z to 2026-10-09T06:00:00Z. This is an audit window, not a measured migration start or active-work total.
- **186 CI jobs: 152 succeeded, 24 failed, 10 cancelled.** Their sum is **22h 28m 5.0s runner time**; overlap-safe wall coverage is **14h 53m 29.0s**. Parallel Linux/macOS jobs must not be added as elapsed days.
- **105h 53m 1.0s lies outside recorded CI job intervals.** That includes implementation, review, local/native validation, publication, waiting and unobserved time. Their individual shares cannot be reconstructed reliably. It is neither proven idle time nor model inference.
- Retained command receipts expose **9m 23.8s across 45 unique commands**. Additional Cargo/test log components expose **1h 58m 36.3s across 288 deduplicated logs**. These are separate evidence subtotals and may overlap CI/receipts; do not add them to the CI sum or elapsed coverage.
- **Assistant inference duration: unavailable, not zero.** No inference/usage timing telemetry is exposed. No elapsed remainder or token-speed estimate is relabeled as inference.
- Time was also spent on repeated parity fixes and validation, native/platform fixture differences, exact-source/evidence recovery after an environment reset, and failed prerequisite installation. The work is evidenced; most edit/review/wait durations are unknown.
- This is a retrospective lower-coverage accounting, not a complete timesheet. Shared editor/workbench implementation belongs to BelloBox; only Agent integration and consumer checks belong here.

## Grouped measured CI resource time

| Outcome | Jobs | Runner time |
|---|---:|---:|
| success | 152 | 19h 41m 22.0s |
| failure | 24 | 2h 22m 59.0s |
| cancelled | 10 | 23m 44.0s |

Failures and cancellations are real resource time, but not automatically wasted time: failures can expose defects. A later new-commit run is revalidation, not a GitHub rerun; all retrieved jobs have run_attempt=1. No failed investigation or code-edit duration is implied.

| Nested CI step classification | Resource time |
|---|---:|
| build + test/check (combined) | 10h 21m 46.0s |
| build | 7h 55m 30.0s |
| dependency/environment | 1h 27m 57.0s |
| automated lint/check | 1h 5m 28.0s |
| build/test/evidence transport (combined) | 51m 11.0s |
| ci orchestration | 18m 37.0s |
| test execution / UI observation | 18m 17.0s |
| evidence reporting/transport | 0m 9.0s |
| Job envelope remainder between/outside steps | 9m 10.0s |

Job-created → job-start queue sum: **16m 44.0s**, separately reported and overlapping across jobs. It is not total human blocked time. All 34 unique step names were explicitly classified against workflow commands. Cargo test/check/lint mixtures stay combined; no CI category represents assistant review. Build steps may still include dependency work. Nested steps are already inside job durations.

## Recorded work sequence and unknown effort

| Area | Evidence / result | Duration |
|---|---|---|
| Initial checkpoint and Oct 4–5 workflows | GPUI shell, durable multichat, queue/focus/lifecycle/sidebar organization, copy and recovery, with repeated source-parity fixes | unknown active effort |
| Oct 6–7 authority and tools | Find/Grep, instruction discovery, catalog identity/tool modes, synthetic runtime, Context Inspector; read/edit/attachments/MCP/profile/compaction followed | unknown active effort |
| Oct 8–9 integration and rework | Skills/path identity, native connections, macOS decoding, concurrent tools/timing, MCP race, Topics, context recovery, conversation search, sidebar activity/unread | unknown active effort |
| Environment/reset/dependency work | Source recovery proved trees, but lost GUI evidence stayed lost; prerequisite apt attempt failed with no install | unknown duration; see handoff |
| Review and publication | Independent checks and immutable commit milestones exist; no complete historical timers | unknown |
| Assistant inference | No timing telemetry available | unknown, not zero |

[Immutable historical handoff](https://github.com/BelloWare/BelloAgent/blob/bd4e6ebb/rust/docs/MIGRATION-HANDOFF-2026-10-07.md) · [Machine-readable item ledger](duration-data.json). The full per-item tables below retain failed/repeated attempts as well as successful ones.

<details>
<summary>All CI jobs: exact UTC spans, feature/checkpoint, result and source</summary>

| Start UTC | End UTC | Feature/checkpoint | Resource | Duration | Result / source |
|---|---|---|---|---:|---|
| 2026-10-04T05:13:33Z | 2026-10-04T05:17:01Z | Publish Rust GPUI agent checkpoint with pinned shared workbench | GitHub linux | 3m 28.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37179261160/job/111368302087) |
| 2026-10-04T05:59:45Z | 2026-10-04T06:02:17Z | Add durable one-project multi-chat and safe draft recovery | GitHub linux | 2m 32.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37181474816/job/111374769303) |
| 2026-10-05T03:37:35Z | 2026-10-05T03:41:07Z | Restore source queue timing and grouped presentation | GitHub linux | 3m 32.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37260181436/job/111605564419) |
| 2026-10-05T03:46:57Z | 2026-10-05T03:50:24Z | Integrate shared editor CRLF deletion fix | GitHub linux | 3m 27.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37260797984/job/111607403834) |
| 2026-10-05T04:03:04Z | 2026-10-05T04:07:00Z | ci(rust): capture isolated Linux UI smoke evidence | GitHub linux | 3m 56.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37261846708/job/111610527281) |
| 2026-10-05T04:09:05Z | 2026-10-05T04:10:43Z | Restore source queued-message detail popover | GitHub linux | 1m 38.0s | [cancelled](https://github.com/BelloWare/BelloAgent/actions/runs/37262252558/job/111611737320) |
| 2026-10-05T04:10:47Z | 2026-10-05T04:15:07Z | ci(rust): discover installed Mesa software Vulkan manifest | GitHub linux | 4m 20.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37262350324/job/111612092991) |
| 2026-10-05T04:17:27Z | 2026-10-05T04:21:16Z | ci(rust): improve tiny-label OCR without altering evidence | GitHub linux | 3m 49.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37262853455/job/111613507030) |
| 2026-10-05T04:22:44Z | 2026-10-05T04:23:55Z | Fix source user-bubble width collapsing to one glyph | GitHub linux | 1m 11.0s | [cancelled](https://github.com/BelloWare/BelloAgent/actions/runs/37263240442/job/111614630115) |
| 2026-10-05T04:23:58Z | 2026-10-05T04:25:03Z | ci(rust): focus composer before keyboard smoke | GitHub linux | 1m 5.0s | [cancelled](https://github.com/BelloWare/BelloAgent/actions/runs/37263317905/job/111614912191) |
| 2026-10-05T04:25:07Z | 2026-10-05T04:27:57Z | ci(rust): keep startup shortcut focus regression visible | GitHub linux | 2m 50.0s | [cancelled](https://github.com/BelloWare/BelloAgent/actions/runs/37263400253/job/111615159167) |
| 2026-10-05T04:28:00Z | 2026-10-05T04:30:18Z | Integrate shared IME and composed-character navigation fixes | GitHub linux | 2m 18.0s | [cancelled](https://github.com/BelloWare/BelloAgent/actions/runs/37263608700/job/111615776546) |
| 2026-10-05T04:30:21Z | 2026-10-05T04:33:51Z | Restore selected composer focus on initial launch | GitHub linux | 3m 30.0s | [cancelled](https://github.com/BelloWare/BelloAgent/actions/runs/37263780568/job/111616290290) |
| 2026-10-05T04:33:54Z | 2026-10-05T04:37:50Z | Defer last-window quit beyond native close callback | GitHub linux | 3m 56.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37264065170/job/111617059690) |
| 2026-10-05T04:38:30Z | 2026-10-05T04:44:17Z | ci(rust): validate native Apple Silicon builds on standard runners | GitHub apple-silicon | 5m 47.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37264389895/job/111618009462) |
| 2026-10-05T05:04:04Z | 2026-10-05T05:05:26Z | ci(rust): keep checks public-only without artifact storage | GitHub linux | 1m 22.0s | [cancelled](https://github.com/BelloWare/BelloAgent/actions/runs/37266137845/job/111623275771) |
| 2026-10-05T05:05:16Z | 2026-10-05T05:08:10Z | Add validated non-executing tool history and replay foundation | GitHub apple-silicon | 2m 54.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37266217184/job/111623513506) |
| 2026-10-05T05:05:29Z | 2026-10-05T05:09:26Z | Add validated non-executing tool history and replay foundation | GitHub linux | 3m 57.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37266217199/job/111623575295) |
| 2026-10-05T05:13:57Z | 2026-10-05T05:17:18Z | Verify typed-history failure cuts and disabled-tool transport boundary | GitHub linux | 3m 21.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37266848614/job/111625377201) |
| 2026-10-05T05:14:05Z | 2026-10-05T05:18:45Z | Verify typed-history failure cuts and disabled-tool transport boundary | GitHub apple-silicon | 4m 40.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37266848629/job/111625377353) |
| 2026-10-05T05:20:37Z | 2026-10-05T05:24:28Z | Record source macOS window and termination lifecycle gap | GitHub linux | 3m 51.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37267350494/job/111626848797) |
| 2026-10-05T05:20:43Z | 2026-10-05T05:26:47Z | Record source macOS window and termination lifecycle gap | GitHub apple-silicon | 6m 4.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37267350537/job/111626849302) |
| 2026-10-05T05:56:57Z | 2026-10-05T06:01:37Z | Retain workspace entities independently of window bindings | GitHub linux | 4m 40.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37270031171/job/111634871022) |
| 2026-10-05T05:57:01Z | 2026-10-05T06:02:10Z | Retain workspace entities independently of window bindings | GitHub apple-silicon | 5m 9.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37270031142/job/111634870439) |
| 2026-10-05T06:04:49Z | 2026-10-05T06:08:29Z | Record validated workspace retention prerequisite and remaining macOS… | GitHub linux | 3m 40.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37270626874/job/111636651671) |
| 2026-10-05T06:04:57Z | 2026-10-05T06:10:39Z | Record validated workspace retention prerequisite and remaining macOS… | GitHub apple-silicon | 5m 42.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37270626894/job/111636651745) |
| 2026-10-05T06:19:07Z | 2026-10-05T06:23:44Z | Separate durable save and worker stop from window completion | GitHub linux | 4m 37.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37271807676/job/111640206056) |
| 2026-10-05T06:19:12Z | 2026-10-05T06:23:15Z | Separate durable save and worker stop from window completion | GitHub apple-silicon | 4m 3.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37271807618/job/111640205955) |
| 2026-10-05T06:57:10Z | 2026-10-05T07:01:59Z | Restore source transcript Copy action and stable resize geometry | GitHub linux | 4m 49.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37275044029/job/111650105059) |
| 2026-10-05T06:57:19Z | 2026-10-05T07:03:21Z | Restore source transcript Copy action and stable resize geometry | GitHub apple-silicon | 6m 2.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37275044509/job/111650107377) |
| 2026-10-05T07:07:08Z | 2026-10-05T07:11:41Z | Add optional isolated macOS own-window lifecycle probe | GitHub linux | 4m 33.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37275935176/job/111652840902) |
| 2026-10-05T07:07:12Z | 2026-10-05T07:12:05Z | Add optional isolated macOS own-window lifecycle probe | GitHub apple-silicon | 4m 53.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37275935183/job/111652841035) |
| 2026-10-05T07:27:07Z | 2026-10-05T07:31:56Z | Identify native smoke target by exact GPUI workspace identity | GitHub linux | 4m 49.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37277806206/job/111658648380) |
| 2026-10-05T07:27:13Z | 2026-10-05T07:35:28Z | Identify native smoke target by exact GPUI workspace identity | GitHub apple-silicon | 8m 15.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37277806197/job/111658648134) |
| 2026-10-05T07:32:58Z | 2026-10-05T07:37:43Z | Use standard file locks and verify process ownership | GitHub linux | 4m 45.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37278353013/job/111660365824) |
| 2026-10-05T07:35:37Z | 2026-10-05T07:41:16Z | Use standard file locks and verify process ownership | GitHub apple-silicon | 5m 39.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37278353020/job/111661112689) |
| 2026-10-05T07:55:16Z | 2026-10-05T07:58:22Z | Record exact successful macOS own-window lifecycle evidence | GitHub linux | 3m 6.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37280460291/job/111667073341) |
| 2026-10-05T07:55:20Z | 2026-10-05T08:00:56Z | Record exact successful macOS own-window lifecycle evidence | GitHub apple-silicon | 5m 36.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37280460369/job/111667073595) |
| 2026-10-05T09:33:20Z | 2026-10-05T09:36:54Z | Restore source sidebar Pin and Unpin with durable organization | GitHub linux | 3m 34.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37290801435/job/111700463814) |
| 2026-10-05T09:33:25Z | 2026-10-05T09:39:40Z | Restore source sidebar Pin and Unpin with durable organization | GitHub apple-silicon | 6m 15.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37290801409/job/111700463346) |
| 2026-10-05T10:05:22Z | 2026-10-05T10:08:31Z | feat(agent): navigate visible chats with source keyboard shortcuts | GitHub linux | 3m 9.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37294288373/job/111711739234) |
| 2026-10-05T10:05:29Z | 2026-10-05T10:11:39Z | feat(agent): navigate visible chats with source keyboard shortcuts | GitHub apple-silicon | 6m 10.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37294288383/job/111711739289) |
| 2026-10-05T10:29:14Z | 2026-10-05T10:32:34Z | fix(agent): cancel dirty-file prompts without stealing focus | GitHub linux | 3m 20.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37296876844/job/111720079561) |
| 2026-10-05T10:29:23Z | 2026-10-05T10:35:40Z | fix(agent): cancel dirty-file prompts without stealing focus | GitHub apple-silicon | 6m 17.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37296876945/job/111720081472) |
| 2026-10-05T11:28:46Z | 2026-10-05T11:32:34Z | feat(agent): durably promote queued follow-ups to steering | GitHub linux | 3m 48.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37303182666/job/111740544405) |
| 2026-10-05T11:28:54Z | 2026-10-05T11:35:55Z | feat(agent): durably promote queued follow-ups to steering | GitHub apple-silicon | 7m 1.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37303182696/job/111740544681) |
| 2026-10-05T12:02:48Z | 2026-10-05T12:07:44Z | feat(agent): durably reorder queued follow-ups with source drag gesture | GitHub linux | 4m 56.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37306851752/job/111752489468) |
| 2026-10-05T12:02:53Z | 2026-10-05T12:09:23Z | feat(agent): durably reorder queued follow-ups with source drag gesture | GitHub apple-silicon | 6m 30.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37306851723/job/111752489559) |
| 2026-10-05T12:29:42Z | 2026-10-05T12:34:19Z | test(agent): scope publication counters to quiescent reorder checks | GitHub linux | 4m 37.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37309905223/job/111762484988) |
| 2026-10-05T12:29:47Z | 2026-10-05T12:35:50Z | test(agent): scope publication counters to quiescent reorder checks | GitHub apple-silicon | 6m 3.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37309905247/job/111762484714) |
| 2026-10-05T12:51:35Z | 2026-10-05T12:55:30Z | fix(agent): budget queue height from measured pane and composer geometry | GitHub linux | 3m 55.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37312454326/job/111770937432) |
| 2026-10-05T12:51:43Z | 2026-10-05T12:58:48Z | fix(agent): budget queue height from measured pane and composer geometry | GitHub apple-silicon | 7m 5.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37312454029/job/111770938955) |
| 2026-10-05T13:02:18Z | 2026-10-05T13:06:32Z | test(ci): bound and diagnose Agent Linux UI startup | GitHub linux | 4m 14.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37313751376/job/111775226128) |
| 2026-10-05T13:02:21Z | 2026-10-05T13:06:41Z | test(ci): bound and diagnose Agent Linux UI startup | GitHub apple-silicon | 4m 20.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37313751395/job/111775226121) |
| 2026-10-05T13:44:20Z | 2026-10-05T13:49:00Z | Restore source queue-header Resume and Send queued controls | GitHub linux | 4m 40.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37319116622/job/111793348846) |
| 2026-10-05T13:44:26Z | 2026-10-05T13:48:26Z | Restore source queue-header Resume and Send queued controls | GitHub apple-silicon | 4m 0.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37319116939/job/111793358047) |
| 2026-10-05T14:44:04Z | 2026-10-05T14:49:01Z | Require certain queued-edit status before recovering drafts | GitHub linux | 4m 57.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37327080413/job/111820457141) |
| 2026-10-05T14:44:11Z | 2026-10-05T14:50:27Z | Require certain queued-edit status before recovering drafts | GitHub apple-silicon | 6m 16.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37327080411/job/111820457093) |
| 2026-10-05T15:03:21Z | 2026-10-05T15:06:57Z | Verify uncertain worker shutdown and correct lifecycle evidence | GitHub linux | 3m 36.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37329673922/job/111829288554) |
| 2026-10-05T15:03:27Z | 2026-10-05T15:09:50Z | Verify uncertain worker shutdown and correct lifecycle evidence | GitHub apple-silicon | 6m 23.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37329673913/job/111829287463) |
| 2026-10-05T16:24:21Z | 2026-10-05T16:28:24Z | Persist queued Cancel receipts and exact-draft edit barriers | GitHub linux | 4m 3.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37340566462/job/111866288514) |
| 2026-10-05T16:24:27Z | 2026-10-05T16:29:47Z | Persist queued Cancel receipts and exact-draft edit barriers | GitHub apple-silicon | 5m 20.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37340566476/job/111866295482) |
| 2026-10-05T16:49:36Z | 2026-10-05T16:54:28Z | Clear only durably superseded draft-save warnings | GitHub linux | 4m 52.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37343781040/job/111877146853) |
| 2026-10-05T16:49:44Z | 2026-10-05T16:57:11Z | Clear only durably superseded draft-save warnings | GitHub apple-silicon | 7m 27.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37343781071/job/111877147265) |
| 2026-10-06T00:24:21Z | 2026-10-06T00:27:36Z | Keep queued edit adoption responsive and restore held-row actions | GitHub linux | 3m 15.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37393824626/job/112044913394) |
| 2026-10-06T00:24:31Z | 2026-10-06T00:29:56Z | Keep queued edit adoption responsive and restore held-row actions | GitHub apple-silicon | 5m 25.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37393824655/job/112044913194) |
| 2026-10-06T01:25:11Z | 2026-10-06T01:28:46Z | Reuse populated transcript presentation during unrelated updates | GitHub linux | 3m 35.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37399055916/job/112061851328) |
| 2026-10-06T01:25:13Z | 2026-10-06T01:29:01Z | Reuse populated transcript presentation during unrelated updates | GitHub apple-silicon | 3m 48.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37399055923/job/112061851084) |
| 2026-10-06T02:04:22Z | 2026-10-06T02:09:20Z | Add a reproducible manual transcript benchmark and strict report vali… | GitHub linux | 4m 58.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37402333878/job/112072072393) |
| 2026-10-06T02:04:29Z | 2026-10-06T02:10:50Z | Add a reproducible manual transcript benchmark and strict report vali… | GitHub apple-silicon | 6m 21.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37402333874/job/112072072441) |
| 2026-10-06T05:10:41Z | 2026-10-06T05:14:40Z | Render only visible transcript rows while preserving native wheel nav… | GitHub linux | 3m 59.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37417236078/job/112118435028) |
| 2026-10-06T05:10:46Z | 2026-10-06T05:17:43Z | Render only visible transcript rows while preserving native wheel nav… | GitHub apple-silicon | 6m 57.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37417236124/job/112118435671) |
| 2026-10-06T05:41:32Z | 2026-10-06T05:45:49Z | Restore source Stop shortcut with focused text ownership | GitHub linux | 4m 17.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37419790098/job/112126360319) |
| 2026-10-06T05:41:37Z | 2026-10-06T05:47:13Z | Restore source Stop shortcut with focused text ownership | GitHub apple-silicon | 5m 36.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37419790087/job/112126360629) |
| 2026-10-06T05:57:41Z | 2026-10-06T06:02:32Z | Restore Changes and History keyboard command | GitHub linux | 4m 51.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37421160927/job/112130597480) |
| 2026-10-06T05:57:47Z | 2026-10-06T06:05:02Z | Restore Changes and History keyboard command | GitHub apple-silicon | 7m 15.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37421160931/job/112130597506) |
| 2026-10-06T06:19:17Z | 2026-10-06T06:24:31Z | Add source Copy Session ID sidebar action | GitHub linux | 5m 14.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37423071954/job/112136546163) |
| 2026-10-06T06:19:22Z | 2026-10-06T06:25:14Z | Add source Copy Session ID sidebar action | GitHub apple-silicon | 5m 52.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37423071927/job/112136546221) |
| 2026-10-06T07:12:04Z | 2026-10-06T07:17:21Z | Keep consumed menu Enter repeats out of composer | GitHub linux | 5m 17.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37428183817/job/112152562798) |
| 2026-10-06T07:12:08Z | 2026-10-06T07:18:56Z | Keep consumed menu Enter repeats out of composer | GitHub apple-silicon | 6m 48.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37428183728/job/112152562088) |
| 2026-10-06T07:27:03Z | 2026-10-06T07:32:09Z | Add bounded source-backed instruction discovery | GitHub linux | 5m 6.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37429725512/job/112157503522) |
| 2026-10-06T07:27:08Z | 2026-10-06T07:32:27Z | Add bounded source-backed instruction discovery | GitHub apple-silicon | 5m 19.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37429725467/job/112157503014) |
| 2026-10-06T07:36:55Z | 2026-10-06T07:41:30Z | Compare canonical paths in instruction discovery fixtures | GitHub apple-silicon | 4m 35.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37430754755/job/112160796414) |
| 2026-10-06T07:37:27Z | 2026-10-06T07:43:08Z | Compare canonical paths in instruction discovery fixtures | GitHub linux | 5m 41.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37430754737/job/112160796506) |
| 2026-10-06T07:46:00Z | 2026-10-06T07:50:03Z | Integrate opt-in read-only tools with durable Controller phases | GitHub linux | 4m 3.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37431716954/job/112163871181) |
| 2026-10-06T07:46:06Z | 2026-10-06T07:51:22Z | Integrate opt-in read-only tools with durable Controller phases | GitHub apple-silicon | 5m 16.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37431716931/job/112163871475) |
| 2026-10-06T10:39:40Z | 2026-10-06T10:43:01Z | Preserve archived chats with durable restore and read-only controls | GitHub linux | 3m 21.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37451241441/job/112228053486) |
| 2026-10-06T10:39:48Z | 2026-10-06T10:47:13Z | Preserve archived chats with durable restore and read-only controls | GitHub apple-silicon | 7m 25.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37451241360/job/112228053496) |
| 2026-10-06T11:00:14Z | 2026-10-06T11:05:02Z | Keep programmatic root focus from intercepting queue gestures | GitHub linux | 4m 48.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37453495003/job/112235392575) |
| 2026-10-06T11:00:19Z | 2026-10-06T11:06:37Z | Keep programmatic root focus from intercepting queue gestures | GitHub apple-silicon | 6m 18.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37453494909/job/112235392166) |
| 2026-10-06T11:24:05Z | 2026-10-06T11:27:56Z | Fence retired controllers and scope replacement publications | GitHub linux | 3m 51.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37456141865/job/112244118498) |
| 2026-10-06T11:24:08Z | 2026-10-06T11:30:33Z | Fence retired controllers and scope replacement publications | GitHub apple-silicon | 6m 25.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37456141863/job/112244117949) |
| 2026-10-06T11:28:55Z | 2026-10-06T11:32:56Z | Define fail-closed project authority envelope contracts | GitHub linux | 4m 1.0s | [cancelled](https://github.com/BelloWare/BelloAgent/actions/runs/37456679844/job/112245892968) |
| 2026-10-06T11:30:42Z | 2026-10-06T11:37:33Z | Define fail-closed project authority envelope contracts | GitHub apple-silicon | 6m 51.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37456679774/job/112246509296) |
| 2026-10-06T11:32:59Z | 2026-10-06T11:37:26Z | Render retained tool cards with bounded previews and safe focus | GitHub linux | 4m 27.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37457015564/job/112247380411) |
| 2026-10-06T11:37:40Z | 2026-10-06T11:42:57Z | Render retained tool cards with bounded previews and safe focus | GitHub apple-silicon | 5m 17.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37457015539/job/112249071249) |
| 2026-10-06T13:21:44Z | 2026-10-06T13:24:46Z | Add current-project trust UI with fenced runtime replacement | GitHub linux | 3m 2.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37470178168/job/112291315518) |
| 2026-10-06T13:21:54Z | 2026-10-06T13:29:56Z | Add current-project trust UI with fenced runtime replacement | GitHub apple-silicon | 8m 2.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37470178352/job/112291315400) |
| 2026-10-06T20:17:26Z | 2026-10-06T20:23:06Z | Release session locks explicitly before descriptor close | GitHub linux | 5m 40.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37525310164/job/112480688247) |
| 2026-10-06T20:17:35Z | 2026-10-06T20:26:25Z | Release session locks explicitly before descriptor close | GitHub apple-silicon | 8m 50.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37525310312/job/112480689034) |
| 2026-10-06T20:44:25Z | 2026-10-06T20:50:12Z | Add opt-in Foundation Find with source oracle fixtures | GitHub linux | 5m 47.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37528717672/job/112492266411) |
| 2026-10-06T20:44:30Z | 2026-10-06T20:49:23Z | Add opt-in Foundation Find with source oracle fixtures | GitHub apple-silicon | 4m 53.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37528717787/job/112492266343) |
| 2026-10-06T20:57:28Z | 2026-10-06T21:01:29Z | Respect Darwin malformed-glob behavior in Find fixture | GitHub linux | 4m 1.0s | [cancelled](https://github.com/BelloWare/BelloAgent/actions/runs/37530348366/job/112497815741) |
| 2026-10-06T20:57:34Z | 2026-10-06T21:07:45Z | Respect Darwin malformed-glob behavior in Find fixture | GitHub apple-silicon | 10m 11.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37530348293/job/112497815250) |
| 2026-10-06T21:01:32Z | 2026-10-06T21:06:33Z | Add opt-in Foundation Grep with bounded reads | GitHub linux | 5m 1.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37530743224/job/112499529984) |
| 2026-10-06T21:07:55Z | 2026-10-06T21:17:38Z | Add opt-in Foundation Grep with bounded reads | GitHub apple-silicon | 9m 43.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37530743394/job/112502180391) |
| 2026-10-06T21:10:26Z | 2026-10-06T21:16:07Z | Add isolated native project authority behind explicit composition | GitHub linux | 5m 41.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37531951350/job/112503262160) |
| 2026-10-06T21:17:49Z | 2026-10-06T21:25:55Z | Add isolated native project authority behind explicit composition | GitHub apple-silicon | 8m 6.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37531951386/job/112506272802) |
| 2026-10-06T21:45:37Z | 2026-10-06T21:49:58Z | Persist project identity and fence saved chat mode transitions | GitHub linux | 4m 21.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37536120539/job/112517344763) |
| 2026-10-06T21:45:43Z | 2026-10-06T21:56:06Z | Persist project identity and fence saved chat mode transitions | GitHub apple-silicon | 10m 23.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37536120509/job/112517344848) |
| 2026-10-07T03:39:49Z | 2026-10-07T03:41:37Z | Compose synthetic trusted runtimes with delivery instruction snapshots | GitHub linux | 1m 48.0s | [cancelled](https://github.com/BelloWare/BelloAgent/actions/runs/37567784311/job/112619360414) |
| 2026-10-07T03:39:54Z | 2026-10-07T03:49:03Z | Compose synthetic trusted runtimes with delivery instruction snapshots | GitHub apple-silicon | 9m 9.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37567784307/job/112619360622) |
| 2026-10-07T03:41:40Z | 2026-10-07T03:44:47Z | Integrate Context preview with synthetic project runtime | GitHub linux | 3m 7.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37567909975/job/112619820039) |
| 2026-10-07T03:49:10Z | 2026-10-07T03:53:52Z | Integrate Context preview with synthetic project runtime | GitHub apple-silicon | 4m 42.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37567909976/job/112621622719) |
| 2026-10-07T04:05:00Z | 2026-10-07T04:07:33Z | Preserve migration handoff and fix Inspector test attribute | GitHub linux | 2m 33.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37569741307/job/112625436112) |
| 2026-10-07T04:05:04Z | 2026-10-07T04:08:25Z | Preserve migration handoff and fix Inspector test attribute | GitHub apple-silicon | 3m 21.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37569741232/job/112625435908) |
| 2026-10-07T04:28:58Z | 2026-10-07T04:34:31Z | Fix Inspector test macro resolution and validate GPUI regressions | GitHub linux | 5m 33.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37571661607/job/112631440947) |
| 2026-10-07T04:29:05Z | 2026-10-07T04:38:21Z | Fix Inspector test macro resolution and validate GPUI regressions | GitHub apple-silicon | 9m 16.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37571661653/job/112631441233) |
| 2026-10-07T04:59:20Z | 2026-10-07T05:05:13Z | Preserve verified cloud Inspector interaction evidence | GitHub linux | 5m 53.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37574089234/job/112638985767) |
| 2026-10-07T04:59:26Z | 2026-10-07T05:08:55Z | Preserve verified cloud Inspector interaction evidence | GitHub apple-silicon | 9m 29.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37574089272/job/112638986202) |
| 2026-10-07T05:35:41Z | 2026-10-07T05:40:52Z | Connect fixture Settings and saved profiles through guarded chat runtime | GitHub linux | 5m 11.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37577081642/job/112648270661) |
| 2026-10-07T05:35:45Z | 2026-10-07T05:41:53Z | Connect fixture Settings and saved profiles through guarded chat runtime | GitHub apple-silicon | 6m 8.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37577081644/job/112648270643) |
| 2026-10-07T05:48:16Z | 2026-10-07T05:53:42Z | Preserve reproducible Settings LOC accounting and exact CI evidence | GitHub linux | 5m 26.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37578131338/job/112651513521) |
| 2026-10-07T05:48:21Z | 2026-10-07T05:58:27Z | Preserve reproducible Settings LOC accounting and exact CI evidence | GitHub apple-silicon | 10m 6.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37578131347/job/112651513427) |
| 2026-10-07T06:13:03Z | 2026-10-07T06:19:20Z | Integrate bounded native read content, durable image replay and sourc… | GitHub apple-silicon | 6m 17.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37580297313/job/112658173510) |
| 2026-10-07T06:13:33Z | 2026-10-07T06:19:38Z | Integrate bounded native read content, durable image replay and sourc… | GitHub linux | 6m 5.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37580297270/job/112658173078) |
| 2026-10-07T06:32:21Z | 2026-10-07T06:37:47Z | Validate native read pixel budget with a valid bounded oversize PNG | GitHub linux | 5m 26.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37582044133/job/112663699504) |
| 2026-10-07T06:32:27Z | 2026-10-07T06:39:58Z | Validate native read pixel budget with a valid bounded oversize PNG | GitHub apple-silicon | 7m 31.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37582044194/job/112663699951) |
| 2026-10-07T06:45:54Z | 2026-10-07T06:50:14Z | test(read): compare native fixture filesystem identity | GitHub linux | 4m 20.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37583323641/job/112667726413) |
| 2026-10-07T06:46:01Z | 2026-10-07T06:57:04Z | test(read): compare native fixture filesystem identity | GitHub apple-silicon | 11m 3.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37583323651/job/112667726149) |
| 2026-10-07T07:24:25Z | 2026-10-07T07:30:09Z | Add guarded editing tools, source change cards and manual compaction | GitHub linux | 5m 44.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37587116298/job/112679710597) |
| 2026-10-07T07:24:30Z | 2026-10-07T07:36:43Z | Add guarded editing tools, source change cards and manual compaction | GitHub apple-silicon | 12m 13.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37587116338/job/112679711109) |
| 2026-10-07T08:49:56Z | 2026-10-07T08:54:18Z | Integrate saved connection authority with trusted chat runtimes | GitHub linux | 4m 22.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37596398489/job/112709997840) |
| 2026-10-07T08:50:02Z | 2026-10-07T09:03:01Z | Integrate saved connection authority with trusted chat runtimes | GitHub apple-silicon | 12m 59.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37596398498/job/112709997256) |
| 2026-10-07T09:40:23Z | 2026-10-07T09:45:37Z | fix(runtime): preserve completed sessions during late retirement | GitHub linux | 5m 14.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37602221180/job/112729081350) |
| 2026-10-07T09:40:30Z | 2026-10-07T09:51:52Z | fix(runtime): preserve completed sessions during late retirement | GitHub apple-silicon | 11m 22.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37602220932/job/112729081506) |
| 2026-10-07T11:20:53Z | 2026-10-07T11:28:17Z | Integrate project-scoped Streamable HTTP MCP workflow | GitHub linux | 7m 24.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37613454735/job/112766038767) |
| 2026-10-07T11:20:57Z | 2026-10-07T11:30:15Z | Integrate project-scoped Streamable HTTP MCP workflow | GitHub apple-silicon | 9m 18.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37613454732/job/112766036487) |
| 2026-10-07T13:26:08Z | 2026-10-07T13:30:50Z | Implement picker-selected image attachments and retained user replay | GitHub linux | 4m 42.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37628446533/job/112816181176) |
| 2026-10-07T13:26:14Z | 2026-10-07T13:33:31Z | Implement picker-selected image attachments and retained user replay | GitHub apple-silicon | 7m 17.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37628446507/job/112816181006) |
| 2026-10-07T13:43:15Z | 2026-10-07T13:55:21Z | test: compare native attachment paths by canonical target | GitHub apple-silicon | 12m 6.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37630731761/job/112823991278) |
| 2026-10-07T13:43:36Z | 2026-10-07T13:50:05Z | test: compare native attachment paths by canonical target | GitHub linux | 6m 29.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37630731740/job/112824150170) |
| 2026-10-07T14:21:27Z | 2026-10-07T14:28:07Z | fix: use authoritative MCP outcome state for invocation admission | GitHub linux | 6m 40.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37636000086/job/112842266653) |
| 2026-10-07T14:21:35Z | 2026-10-07T14:31:16Z | fix: use authoritative MCP outcome state for invocation admission | GitHub apple-silicon | 9m 41.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37636000099/job/112842266619) |
| 2026-10-07T14:47:14Z | 2026-10-07T14:52:29Z | test: normalize accepted socket modes for native fixtures | GitHub linux | 5m 15.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37639630682/job/112854823603) |
| 2026-10-07T14:47:22Z | 2026-10-07T14:57:44Z | test: normalize accepted socket modes for native fixtures | GitHub apple-silicon | 10m 22.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37639630764/job/112854824881) |
| 2026-10-07T17:46:02Z | 2026-10-07T17:53:26Z | feat: add project-only explicit skill selection workflows | GitHub linux | 7m 24.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37661601086/job/112930236752) |
| 2026-10-07T17:46:09Z | 2026-10-07T17:57:21Z | feat: add project-only explicit skill selection workflows | GitHub apple-silicon | 11m 12.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37661601424/job/112930238339) |
| 2026-10-07T18:08:27Z | 2026-10-07T18:15:21Z | test: align native Read replay with task provenance schema | GitHub linux | 6m 54.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37664508487/job/112940163930) |
| 2026-10-07T18:08:34Z | 2026-10-07T18:19:46Z | test: align native Read replay with task provenance schema | GitHub apple-silicon | 11m 12.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37664508508/job/112940164048) |
| 2026-10-07T19:43:30Z | 2026-10-07T19:54:29Z | feat: add bounded trusted Bash execution and live tool output | GitHub linux | 10m 59.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37676636286/job/112981722295) |
| 2026-10-07T19:43:35Z | 2026-10-07T20:02:52Z | feat: add bounded trusted Bash execution and live tool output | GitHub apple-silicon | 19m 17.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37676636287/job/112981720007) |
| 2026-10-07T21:46:57Z | 2026-10-07T21:55:53Z | fix: preserve Swift skill path identities and frozen legacy delivery | GitHub linux | 8m 56.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37691797161/job/113033542270) |
| 2026-10-07T21:47:04Z | 2026-10-07T22:03:03Z | fix: preserve Swift skill path identities and frozen legacy delivery | GitHub apple-silicon | 15m 59.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37691797287/job/113033543106) |
| 2026-10-08T02:42:05Z | 2026-10-08T02:47:52Z | fix: match Swift instruction path presentation without changing autho… | GitHub linux | 5m 47.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37719147602/job/113122523399) |
| 2026-10-08T02:42:12Z | 2026-10-08T03:00:01Z | fix: match Swift instruction path presentation without changing autho… | GitHub apple-silicon | 17m 49.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37719147569/job/113122523411) |
| 2026-10-08T03:35:02Z | 2026-10-08T03:41:51Z | docs(rust): record native connection host and extend CI coverage | GitHub linux | 6m 49.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37723409419/job/113136003475) |
| 2026-10-08T03:35:10Z | 2026-10-08T03:50:55Z | docs(rust): record native connection host and extend CI coverage | GitHub apple-silicon | 15m 45.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37723409432/job/113136003324) |
| 2026-10-08T12:11:54Z | 2026-10-08T12:20:44Z | feat(rust): add guarded catalog-assisted Connections workflow and val… | GitHub linux | 8m 50.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37775168687/job/113304075075) |
| 2026-10-08T12:11:58Z | 2026-10-08T12:29:03Z | feat(rust): add guarded catalog-assisted Connections workflow and val… | GitHub apple-silicon | 17m 5.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37775168679/job/113304075344) |
| 2026-10-08T18:39:31Z | 2026-10-08T18:48:35Z | Integrate source UTF-8 decoder with pinned native CI and same-build r… | GitHub linux | 9m 4.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37825970739/job/113478805734) |
| 2026-10-08T18:39:37Z | 2026-10-08T19:01:10Z | Integrate source UTF-8 decoder with pinned native CI and same-build r… | GitHub apple-silicon | 21m 33.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37825970758/job/113478806375) |
| 2026-10-08T19:00:59Z | 2026-10-08T19:06:40Z | Accept timestamp-prefixed GitHub log segment BOM in decoder receipts | GitHub linux | 5m 41.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37828732788/job/113488226675) |
| 2026-10-08T19:01:20Z | 2026-10-08T19:22:51Z | Accept timestamp-prefixed GitHub log segment BOM in decoder receipts | GitHub apple-silicon | 21m 31.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37828732845/job/113488342289) |
| 2026-10-08T19:32:41Z | 2026-10-08T19:41:25Z | Reconcile concurrent tools with Swift 0.1.121 and release workspace w… | GitHub linux | 8m 44.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37832736345/job/113501942118) |
| 2026-10-08T19:32:47Z | 2026-10-08T19:56:12Z | Reconcile concurrent tools with Swift 0.1.121 and release workspace w… | GitHub apple-silicon | 23m 25.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37832736557/job/113501942063) |
| 2026-10-08T19:56:05Z | 2026-10-08T20:06:54Z | Show bounded per-call terminal tool cards before batch settlement | GitHub linux | 10m 49.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37835646706/job/113511853347) |
| 2026-10-08T19:56:19Z | 2026-10-08T20:11:46Z | Show bounded per-call terminal tool cards before batch settlement | GitHub apple-silicon | 15m 27.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37835646693/job/113511932570) |
| 2026-10-08T21:11:27Z | 2026-10-08T21:18:15Z | feat(rust): preserve completed tool timing and batch wall accounting | GitHub linux | 6m 48.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37844995502/job/113543535109) |
| 2026-10-08T21:11:32Z | 2026-10-08T21:28:05Z | feat(rust): preserve completed tool timing and batch wall accounting | GitHub apple-silicon | 16m 33.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37844995497/job/113543535251) |
| 2026-10-08T21:42:22Z | 2026-10-08T21:46:42Z | fix(rust): keep MCP status observation outside tool admission | GitHub linux | 4m 20.0s | [failure](https://github.com/BelloWare/BelloAgent/actions/runs/37848622747/job/113555703052) |
| 2026-10-08T21:42:26Z | 2026-10-08T22:02:42Z | fix(rust): keep MCP status observation outside tool admission | GitHub apple-silicon | 20m 16.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37848622767/job/113555703370) |
| 2026-10-08T22:05:35Z | 2026-10-08T22:15:20Z | test(rust): observe completed actor publication before asserting sett… | GitHub linux | 9m 45.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37851230225/job/113564335212) |
| 2026-10-08T22:05:40Z | 2026-10-08T22:28:48Z | test(rust): observe completed actor publication before asserting sett… | GitHub apple-silicon | 23m 8.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37851230162/job/113564334616) |
| 2026-10-08T22:18:04Z | 2026-10-08T22:29:03Z | feat(rust): add metadata-only current-project Topics workflow | GitHub linux | 10m 59.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37852585623/job/113568967296) |
| 2026-10-08T22:28:56Z | 2026-10-08T22:52:32Z | feat(rust): add metadata-only current-project Topics workflow | GitHub apple-silicon | 23m 36.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37852585647/job/113572777192) |
| 2026-10-08T23:16:47Z | 2026-10-08T23:28:35Z | feat(rust): recover once from explicit context rejection with durable… | GitHub linux | 11m 48.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37858528406/job/113588441839) |
| 2026-10-08T23:16:50Z | 2026-10-08T23:34:15Z | feat(rust): recover once from explicit context rejection with durable… | GitHub apple-silicon | 17m 25.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37858528426/job/113588441915) |
| 2026-10-09T01:28:43Z | 2026-10-09T01:36:06Z | feat(rust): add loaded conversation search and copy against 0.1.122 | GitHub linux | 7m 23.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37869956762/job/113625508991) |
| 2026-10-09T01:28:46Z | 2026-10-09T01:47:00Z | feat(rust): add loaded conversation search and copy against 0.1.122 | GitHub apple-silicon | 18m 14.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37869956665/job/113625507818) |
| 2026-10-09T01:51:08Z | 2026-10-09T02:01:05Z | fix(rust): restore unopened sidebar run status without resuming work | GitHub linux | 9m 57.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37871750862/job/113631199136) |
| 2026-10-09T01:51:18Z | 2026-10-09T02:13:38Z | fix(rust): restore unopened sidebar run status without resuming work | GitHub apple-silicon | 22m 20.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37871751040/job/113631199429) |
| 2026-10-09T02:52:41Z | 2026-10-09T03:02:11Z | feat(rust): persist semantic sidebar activity ordering | GitHub linux | 9m 30.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37876640090/job/113646650365) |
| 2026-10-09T02:52:47Z | 2026-10-09T03:14:34Z | feat(rust): persist semantic sidebar activity ordering | GitHub apple-silicon | 21m 47.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37876640114/job/113646650410) |
| 2026-10-09T04:50:19Z | 2026-10-09T05:01:59Z | feat(rust): persist existing-chat unread and read state | GitHub linux | 11m 40.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37885732142/job/113675202050) |
| 2026-10-09T04:50:26Z | 2026-10-09T05:12:51Z | feat(rust): persist existing-chat unread and read state | GitHub apple-silicon | 22m 25.0s | [success](https://github.com/BelloWare/BelloAgent/actions/runs/37885732140/job/113675201962) |

</details>

<details>
<summary>Measured native/local command receipts (separate subtotal; no double counting with CI)</summary>

| Item | Class | Start UTC | End UTC | Timer duration | Outcome / source |
|---|---|---|---|---:|---|
| instruction-source-path-2026-10-08 / omit_prompt_map | build + test (combined) | unknown | unknown | 0m 17.0s | [expected negative control detected](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/behavior-controls.json) |
| instruction-source-path-2026-10-08 / resolve_locator_leaf | build + test (combined) | unknown | unknown | 0m 7.8s | [expected negative control detected](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/behavior-controls.json) |
| instruction-source-path-2026-10-08 / remove_target_check | build + test (combined) | unknown | unknown | 0m 15.0s | [expected negative control detected](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/behavior-controls.json) |
| instruction-source-path-2026-10-08 / rewrite_instruction_body | build + test (combined) | unknown | unknown | 0m 7.6s | [expected negative control detected](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/behavior-controls.json) |
| instruction-source-path-2026-10-08 / refresh_instruction_retry | build + test (combined) | unknown | unknown | 0m 24.0s | [expected negative control detected](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/behavior-controls.json) |
| instruction-source-path-2026-10-08 / refresh_project_retry | build + test (combined) | unknown | unknown | 0m 24.0s | [expected negative control detected](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/behavior-controls.json) |
| sidebar-activity-2026-10-09 / build-default | build | 2026-10-09T02:26:28.071817Z | 2026-10-09T02:26:50.423152Z | 0m 22.4s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/native/validation.json) |
| sidebar-activity-2026-10-09 / build-all-features | build | 2026-10-09T02:26:50.423994Z | 2026-10-09T02:27:08.468951Z | 0m 18.0s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/native/validation.json) |
| sidebar-activity-2026-10-09 / catalog-activity | build + test (combined) | 2026-10-09T02:27:08.469700Z | 2026-10-09T02:27:33.071717Z | 0m 24.6s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/native/validation.json) |
| sidebar-activity-2026-10-09 / semantic-activity | build + test (combined) | 2026-10-09T02:27:33.072305Z | 2026-10-09T02:27:40.920220Z | 0m 7.8s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/native/validation.json) |
| sidebar-activity-2026-10-09 / sidebar-activity | build + test (combined) | 2026-10-09T02:27:40.920884Z | 2026-10-09T02:28:08.755514Z | 0m 27.8s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/native/validation.json) |
| sidebar-activity-2026-10-09 / native-menu | build + test (combined) | 2026-10-09T02:28:08.756325Z | 2026-10-09T02:28:10.898021Z | 0m 2.1s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/native/validation.json) |
| sidebar-unread-2026-10-09 / app-cache-and-reply-geometry | build + test (combined) | 2026-10-09T04:23:49.745714Z | 2026-10-09T04:23:51.654546Z | 0m 1.9s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-final-eba/app-cache-and-reply-geometry-result.json) |
| sidebar-unread-2026-10-09 / app-read-all-features | build + test (combined) | 2026-10-09T04:23:21.068095Z | 2026-10-09T04:23:49.744808Z | 0m 28.7s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-final-eba/app-read-all-features-result.json) |
| sidebar-unread-2026-10-09 / app-read-default | build + test (combined) | 2026-10-09T04:22:55.001628Z | 2026-10-09T04:23:21.067309Z | 0m 26.1s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-final-eba/app-read-default-result.json) |
| sidebar-unread-2026-10-09 / candidate-build-all-features | build | 2026-10-09T04:22:37.218922Z | 2026-10-09T04:22:55.000844Z | 0m 17.8s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-final-eba/candidate-build-all-features-result.json) |
| sidebar-unread-2026-10-09 / candidate-build-default | build | 2026-10-09T04:22:12.717640Z | 2026-10-09T04:22:37.218153Z | 0m 24.5s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-final-eba/candidate-build-default-result.json) |
| sidebar-unread-2026-10-09 / format | automated lint/check | 2026-10-09T04:23:51.655311Z | 2026-10-09T04:23:53.979462Z | 0m 2.3s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-final-eba/format-result.json) |
| sidebar-unread-2026-10-09 / app-native-menu | build + test (combined) | 2026-10-09T04:02:38.612240Z | 2026-10-09T04:02:39.176536Z | 0m 0.6s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/app-native-menu-result.json) |
| sidebar-unread-2026-10-09 / app-read-all-features | build + test (combined) | 2026-10-09T04:02:07.200442Z | 2026-10-09T04:02:36.611135Z | 0m 29.4s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/app-read-all-features-result.json) |
| sidebar-unread-2026-10-09 / app-read-default | build + test (combined) | 2026-10-09T04:01:40.152960Z | 2026-10-09T04:02:07.199593Z | 0m 27.0s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/app-read-default-result.json) |
| sidebar-unread-2026-10-09 / app-reply-geometry | build + test (combined) | 2026-10-09T04:02:36.612070Z | 2026-10-09T04:02:38.611563Z | 0m 2.0s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/app-reply-geometry-result.json) |
| sidebar-unread-2026-10-09 / baseline-build-all-features | build | 2026-10-09T04:00:52.514606Z | 2026-10-09T04:01:10.631762Z | 0m 18.1s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/baseline-build-all-features-result.json) |
| sidebar-unread-2026-10-09 / baseline-build-default | build | 2026-10-09T04:00:28.996334Z | 2026-10-09T04:00:52.513875Z | 0m 23.5s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/baseline-build-default-result.json) |
| sidebar-unread-2026-10-09 / candidate-build-all-features | build | 2026-10-09T04:01:12.133954Z | 2026-10-09T04:01:12.717989Z | 0m 0.6s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/candidate-build-all-features-result.json) |
| sidebar-unread-2026-10-09 / candidate-build-default | build | 2026-10-09T04:01:10.632483Z | 2026-10-09T04:01:12.133182Z | 0m 1.5s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/candidate-build-default-result.json) |
| sidebar-unread-2026-10-09 / candidate-fresh-build-all-features | build | 2026-10-09T04:04:01.524994Z | 2026-10-09T04:04:19.087730Z | 0m 17.6s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/candidate-fresh-build-all-features-result.json) |
| sidebar-unread-2026-10-09 / candidate-fresh-build-default | build | 2026-10-09T04:03:42.636984Z | 2026-10-09T04:04:01.524526Z | 0m 18.9s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/candidate-fresh-build-default-result.json) |
| sidebar-unread-2026-10-09 / clean-before-fresh-candidate-builds | build | 2026-10-09T04:03:41.274739Z | 2026-10-09T04:03:42.632952Z | 0m 1.4s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/clean-before-fresh-candidate-builds-result.json) |
| sidebar-unread-2026-10-09 / core-read-catalog | build + test (combined) | 2026-10-09T04:01:39.029491Z | 2026-10-09T04:01:40.152276Z | 0m 1.1s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/core-read-catalog-result.json) |
| sidebar-unread-2026-10-09 / core-read-projection | build + test (combined) | 2026-10-09T04:01:12.718682Z | 2026-10-09T04:01:37.673069Z | 0m 25.0s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/core-read-projection-result.json) |
| sidebar-unread-2026-10-09 / core-read-reducer | build + test (combined) | 2026-10-09T04:01:38.724135Z | 2026-10-09T04:01:39.028754Z | 0m 0.3s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/core-read-reducer-result.json) |
| sidebar-unread-2026-10-09 / core-read-watch | build + test (combined) | 2026-10-09T04:01:37.673905Z | 2026-10-09T04:01:38.723503Z | 0m 1.0s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/core-read-watch-result.json) |
| sidebar-unread-2026-10-09 / format | automated lint/check | 2026-10-09T04:02:39.177324Z | 2026-10-09T04:02:41.537599Z | 0m 2.4s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/ec9/format-result.json) |
| sidebar-unread-2026-10-09 / app-native-menu | build + test (combined) | 2026-10-09T04:08:05.900633Z | 2026-10-09T04:08:06.476349Z | 0m 0.6s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/final766/app-native-menu-result.json) |
| sidebar-unread-2026-10-09 / app-read-all-features | build + test (combined) | 2026-10-09T04:07:34.250149Z | 2026-10-09T04:08:04.148970Z | 0m 29.9s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/final766/app-read-all-features-result.json) |
| sidebar-unread-2026-10-09 / app-read-default | build + test (combined) | 2026-10-09T04:07:04.782866Z | 2026-10-09T04:07:34.249340Z | 0m 29.5s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/final766/app-read-default-result.json) |
| sidebar-unread-2026-10-09 / app-reply-geometry | build + test (combined) | 2026-10-09T04:08:04.149753Z | 2026-10-09T04:08:05.899871Z | 0m 1.7s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/final766/app-reply-geometry-result.json) |
| sidebar-unread-2026-10-09 / core-read-catalog | build + test (combined) | 2026-10-09T04:07:03.671865Z | 2026-10-09T04:07:04.782199Z | 0m 1.1s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/final766/core-read-catalog-result.json) |
| sidebar-unread-2026-10-09 / core-read-projection | build + test (combined) | 2026-10-09T04:06:36.322133Z | 2026-10-09T04:07:02.187593Z | 0m 25.9s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/final766/core-read-projection-result.json) |
| sidebar-unread-2026-10-09 / core-read-reducer | build + test (combined) | 2026-10-09T04:07:03.362932Z | 2026-10-09T04:07:03.671222Z | 0m 0.3s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/final766/core-read-reducer-result.json) |
| sidebar-unread-2026-10-09 / core-read-watch | build + test (combined) | 2026-10-09T04:07:02.188214Z | 2026-10-09T04:07:03.362199Z | 0m 1.2s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/final766/core-read-watch-result.json) |
| sidebar-unread-2026-10-09 / format | automated lint/check | 2026-10-09T04:08:06.477283Z | 2026-10-09T04:08:08.789450Z | 0m 2.3s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/native-intermediate-766/final766/format-result.json) |
| tool-timing-2026-10-08 / compile | build | unknown | unknown | 0m 1.3s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-2026-10-08/native-formatter/receipt.json) |
| tool-timing-2026-10-08 / run | build + test (combined) | unknown | unknown | 0m 0.0s | [exit 0](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-2026-10-08/native-formatter/receipt.json) |

</details>

<details>
<summary>Retained Cargo/test log components (unknown start/end; not invocation wall time)</summary>

Compilation and test-harness components only. These are not CPU usage, model inference or complete command elapsed. Exact identical logs and selected receipt-linked log hashes are excluded, but partial/repackaged overlap may remain. Do not add this subtotal to another total.

| Feature / log | Reported component sum | Outcome / source |
|---|---:|---|
| bash-workflow-2026-10-07 / agent-shell-candidate2-app-all.log | 0m 58.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-app-all.log) |
| bash-workflow-2026-10-07 / agent-shell-candidate2-app-clippy.log | 0m 14.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-app-clippy.log) |
| bash-workflow-2026-10-07 / agent-shell-candidate2-core-all-clippy-final.log | 0m 14.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-core-all-clippy-final.log) |
| bash-workflow-2026-10-07 / agent-shell-candidate2-core-all-final.log | 0m 59.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-core-all-final.log) |
| bash-workflow-2026-10-07 / agent-shell-candidate2-core-default-clippy.log | 0m 12.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-core-default-clippy.log) |
| bash-workflow-2026-10-07 / agent-shell-candidate2-core-default-final.log | 0m 47.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-core-default-final.log) |
| bash-workflow-2026-10-07 / agent-shell-candidate2-negative-failed-status.log | 0m 25.2s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-negative-failed-status.log) |
| bash-workflow-2026-10-07 / agent-shell-candidate2-negative-generic-late-publication.log | 0m 22.7s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-negative-generic-late-publication.log) |
| bash-workflow-2026-10-07 / agent-shell-candidate2-negative-live-late-publication.log | 0m 22.6s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-negative-live-late-publication.log) |
| bash-workflow-2026-10-07 / agent-shell-candidate2-negative-physical-admission.log | 0m 27.5s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-negative-physical-admission.log) |
| bash-workflow-2026-10-07 / agent-shell-candidate2-negative-physical-registry.log | 0m 27.1s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-negative-physical-registry.log) |
| bash-workflow-2026-10-07 / agent-shell-candidate2-negative-post-drain-deadline.log | 0m 23.5s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-negative-post-drain-deadline.log) |
| bash-workflow-2026-10-07 / agent-shell-candidate2-negative-retention-cap.log | 0m 23.4s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/agent-shell-candidate2-negative-retention-cap.log) |
| bash-workflow-2026-10-07 / compaction-barrier-focused.log | 0m 17.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/compaction-barrier-focused.log) |
| bash-workflow-2026-10-07 / compaction-negative-no-refusal.log | 0m 16.7s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/compaction-negative-no-refusal.log) |
| bash-workflow-2026-10-07 / core-default.log | 0m 42.8s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/core-default.log) |
| bash-workflow-2026-10-07 / final-core-default.log | 0m 48.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/final-core-default.log) |
| bash-workflow-2026-10-07 / supplemental-app-default-clippy.log | 0m 15.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/supplemental-app-default-clippy.log) |
| bash-workflow-2026-10-07 / supplemental-app-synthetic-clippy.log | 0m 19.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/supplemental-app-synthetic-clippy.log) |
| bash-workflow-2026-10-07 / supplemental-core-all-clippy.log | 0m 16.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/supplemental-core-all-clippy.log) |
| bash-workflow-2026-10-07 / supplemental-core-default-clippy.log | 0m 11.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/bash-workflow-2026-10-07/supplemental-core-default-clippy.log) |
| catalog-connections-2026-10-08 / focused-core-all-features.log | 0m 9.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/focused-core-all-features.log) |
| catalog-connections-2026-10-08 / build.log | 0m 28.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/gui/build.log) |
| catalog-connections-2026-10-08 / build.log | 0m 44.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/gui-r4/build.log) |
| catalog-connections-2026-10-08 / combined-clippy.log | 0m 14.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/notice-repair/corrected-r4/combined-clippy.log) |
| catalog-connections-2026-10-08 / core-all-features-clippy.log | 0m 14.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/notice-repair/corrected-r4/core-all-features-clippy.log) |
| catalog-connections-2026-10-08 / default-clippy.log | 0m 31.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/notice-repair/corrected-r4/default-clippy.log) |
| catalog-connections-2026-10-08 / focused-app-combined-restored.log | 0m 40.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/notice-repair/corrected-r4/focused-app-combined-restored.log) |
| catalog-connections-2026-10-08 / focused-app-native-restored.log | 0m 21.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/notice-repair/corrected-r4/focused-app-native-restored.log) |
| catalog-connections-2026-10-08 / native-clippy.log | 0m 12.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/notice-repair/corrected-r4/native-clippy.log) |
| catalog-connections-2026-10-08 / negative-discard-clear.log | 0m 24.4s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/notice-repair/corrected-r4/negative-discard-clear.log) |
| catalog-connections-2026-10-08 / negative-notice-owner-reset.log | 0m 23.1s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/notice-repair/corrected-r4/negative-notice-owner-reset.log) |
| catalog-connections-2026-10-08 / synthetic-clippy.log | 0m 24.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/notice-repair/corrected-r4/synthetic-clippy.log) |
| catalog-connections-2026-10-08 / r3-uncertainty-expectation-93-of-94.log | 0m 40.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/catalog-connections-2026-10-08/prior-failures/r3-uncertainty-expectation-93-of-94.log) |
| compaction-publication-observation-2026-10-08 / exact-selector.log | 0m 1.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/compaction-publication-observation-2026-10-08/exact-selector.log) |
| compaction-publication-observation-2026-10-08 / final-clippy-all.log | 0m 9.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/compaction-publication-observation-2026-10-08/final-clippy-all.log) |
| compaction-publication-observation-2026-10-08 / final-clippy-default.log | 0m 6.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/compaction-publication-observation-2026-10-08/final-clippy-default.log) |
| compaction-publication-observation-2026-10-08 / final-core-all.log | 0m 42.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/compaction-publication-observation-2026-10-08/final-core-all.log) |
| compaction-publication-observation-2026-10-08 / final-core-default.log | 0m 33.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/compaction-publication-observation-2026-10-08/final-core-default.log) |
| compaction-publication-observation-2026-10-08 / final-exact-selector.log | 0m 22.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/compaction-publication-observation-2026-10-08/final-exact-selector.log) |
| compaction-publication-observation-2026-10-08 / publication-green.log | 0m 23.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/compaction-publication-observation-2026-10-08/publication-green.log) |
| compaction-publication-observation-2026-10-08 / publication-red.log | 0m 21.1s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/compaction-publication-observation-2026-10-08/publication-red.log) |
| concurrent-tools-2026-10-08 / app-all-check.log | 0m 9.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/fresh/app-all-check.log) |
| concurrent-tools-2026-10-08 / clippy-all-features.log | 0m 9.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/fresh/clippy-all-features.log) |
| concurrent-tools-2026-10-08 / clippy-default.log | 0m 6.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/fresh/clippy-default.log) |
| concurrent-tools-2026-10-08 / core-all-features.log | 0m 57.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/fresh/core-all-features.log) |
| concurrent-tools-2026-10-08 / core-default.log | 0m 45.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/fresh/core-default.log) |
| concurrent-tools-2026-10-08 / regression-after.log | 0m 12.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/lease-diagnosis/regression-after.log) |
| concurrent-tools-2026-10-08 / regression-before.log | 0m 11.5s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/lease-diagnosis/regression-before.log) |
| concurrent-tools-2026-10-08 / app-clippy.log | 0m 20.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/post-lease/app-clippy.log) |
| concurrent-tools-2026-10-08 / app-shutdown-configured.log | 0m 49.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/post-lease/app-shutdown-configured.log) |
| concurrent-tools-2026-10-08 / app-synthetic-full.log | 0m 31.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/post-lease/app-synthetic-full.log) |
| concurrent-tools-2026-10-08 / core-all-features.log | 0m 36.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/post-lease/core-all-features.log) |
| concurrent-tools-2026-10-08 / core-clippy.log | 0m 9.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/post-lease/core-clippy.log) |
| concurrent-tools-2026-10-08 / process-locks.log | 0m 7.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/post-lease/process-locks.log) |
| concurrent-tools-2026-10-08 / workspace.log | 0m 29.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/post-lease/workspace.log) |
| concurrent-tools-2026-10-08 / app-all-check-r4.log | 1m 24.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/staging/app-all-check-r4.log) |
| concurrent-tools-2026-10-08 / bash-preview-repeat-r3.log | 0m 5.3s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/staging/bash-preview-repeat-r3.log) |
| concurrent-tools-2026-10-08 / bash-preview-repeat-r4.log | 0m 3.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/staging/bash-preview-repeat-r4.log) |
| concurrent-tools-2026-10-08 / concurrency-focused-r2.log | 0m 1.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/staging/concurrency-focused-r2.log) |
| concurrent-tools-2026-10-08 / core-all-clippy-final.log | 0m 8.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/staging/core-all-clippy-final.log) |
| concurrent-tools-2026-10-08 / core-all-full-r4.log | 1m 16.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/staging/core-all-full-r4.log) |
| concurrent-tools-2026-10-08 / core-all-unit-r2.log | 0m 32.1s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/staging/core-all-unit-r2.log) |
| concurrent-tools-2026-10-08 / core-all-unit-r3.log | 0m 32.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/staging/core-all-unit-r3.log) |
| concurrent-tools-2026-10-08 / core-all-unit.log | 0m 29.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/staging/core-all-unit.log) |
| concurrent-tools-2026-10-08 / core-default-clippy-final.log | 0m 0.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/staging/core-default-clippy-final.log) |
| concurrent-tools-2026-10-08 / core-default-unit-r4.log | 0m 23.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/concurrent-tools-2026-10-08/logs/staging/core-default-unit-r4.log) |
| context-rejection-recovery-2026-10-08 / app-all-features.log | 1m 28.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/context-rejection-recovery-2026-10-08/app-all-features.log) |
| context-rejection-recovery-2026-10-08 / app-build.log | 0m 15.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/context-rejection-recovery-2026-10-08/app-build.log) |
| context-rejection-recovery-2026-10-08 / app-clippy-all-features.log | 0m 13.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/context-rejection-recovery-2026-10-08/app-clippy-all-features.log) |
| context-rejection-recovery-2026-10-08 / app-focused.log | 0m 21.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/context-rejection-recovery-2026-10-08/app-focused.log) |
| context-rejection-recovery-2026-10-08 / core-all-features.log | 0m 44.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/context-rejection-recovery-2026-10-08/core-all-features.log) |
| context-rejection-recovery-2026-10-08 / core-clippy-all-features.log | 0m 10.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/context-rejection-recovery-2026-10-08/core-clippy-all-features.log) |
| context-rejection-recovery-2026-10-08 / core-clippy-default.log | 0m 7.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/context-rejection-recovery-2026-10-08/core-clippy-default.log) |
| context-rejection-recovery-2026-10-08 / core-default.log | 0m 37.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/context-rejection-recovery-2026-10-08/core-default.log) |
| conversation-content-2026-10-09 / attempt-01-focused.log | 0m 27.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/attempt-01-focused.log) |
| conversation-content-2026-10-09 / attempt-02-build.log | 0m 7.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/attempt-02-build.log) |
| conversation-content-2026-10-09 / attempt-02-full-app.log | 0m 13.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/attempt-02-full-app.log) |
| conversation-content-2026-10-09 / attempt-02-strict-clippy.log | 0m 8.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/attempt-02-strict-clippy.log) |
| conversation-content-2026-10-09 / baseline.log | 0m 0.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/independent-review/baseline.log) |
| conversation-content-2026-10-09 / empty_count_one.log | 0m 0.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/independent-review/empty_count_one.log) |
| conversation-content-2026-10-09 / exclusive_copy_limit.log | 0m 0.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/independent-review/exclusive_copy_limit.log) |
| conversation-content-2026-10-09 / first_occurrence_only.log | 0m 0.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/independent-review/first_occurrence_only.log) |
| conversation-content-2026-10-09 / ignore_search_cancel.log | 0m 0.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/independent-review/ignore_search_cancel.log) |
| conversation-content-2026-10-09 / include_stream.log | 0m 0.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/independent-review/include_stream.log) |
| conversation-content-2026-10-09 / leak_reasoning.log | 0m 0.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/independent-review/leak_reasoning.log) |
| conversation-content-2026-10-09 / overlapping_count.log | 0m 0.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/independent-review/overlapping_count.log) |
| conversation-content-2026-10-09 / weak_text_fence.log | 0m 0.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/conversation-content-2026-10-09/independent-review/weak_text_fence.log) |
| darwin-fixture-sockets-2026-10-07 / negative-control.log | 0m 0.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/darwin-fixture-sockets-2026-10-07/negative-control.log) |
| instruction-source-path-2026-10-08 / all-features-core.log | 0m 59.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/logs/all-features-core.log) |
| instruction-source-path-2026-10-08 / clippy-all-features.log | 0m 13.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/logs/clippy-all-features.log) |
| instruction-source-path-2026-10-08 / clippy-default.log | 0m 10.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/logs/clippy-default.log) |
| instruction-source-path-2026-10-08 / control-omit_prompt_map.log | 0m 17.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/logs/control-omit_prompt_map.log) |
| instruction-source-path-2026-10-08 / control-refresh_instruction_retry.log | 0m 24.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/logs/control-refresh_instruction_retry.log) |
| instruction-source-path-2026-10-08 / control-refresh_project_retry.log | 0m 24.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/logs/control-refresh_project_retry.log) |
| instruction-source-path-2026-10-08 / control-remove_target_check.log | 0m 15.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/logs/control-remove_target_check.log) |
| instruction-source-path-2026-10-08 / control-resolve_locator_leaf.log | 0m 7.8s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/logs/control-resolve_locator_leaf.log) |
| instruction-source-path-2026-10-08 / control-rewrite_instruction_body.log | 0m 7.6s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/logs/control-rewrite_instruction_body.log) |
| instruction-source-path-2026-10-08 / default-core.log | 0m 40.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/logs/default-core.log) |
| instruction-source-path-2026-10-08 / portable-integration.log | 0m 9.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/instruction-source-path-2026-10-08/logs/portable-integration.log) |
| live-terminal-cards-2026-10-08 / app-all.log | 0m 36.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/fresh/app-all.log) |
| live-terminal-cards-2026-10-08 / app-clippy.log | 0m 12.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/fresh/app-clippy.log) |
| live-terminal-cards-2026-10-08 / app-generic.log | 0m 29.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/fresh/app-generic.log) |
| live-terminal-cards-2026-10-08 / core-all.log | 0m 48.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/fresh/core-all.log) |
| live-terminal-cards-2026-10-08 / core-clippy.log | 0m 9.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/fresh/core-clippy.log) |
| live-terminal-cards-2026-10-08 / core-concurrency-corrected.log | 0m 1.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/fresh/core-concurrency-corrected.log) |
| live-terminal-cards-2026-10-08 / core-concurrency.log | 0m 0.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/fresh/core-concurrency.log) |
| live-terminal-cards-2026-10-08 / core-default-clippy.log | 0m 7.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/fresh/core-default-clippy.log) |
| live-terminal-cards-2026-10-08 / core-default.log | 0m 46.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/fresh/core-default.log) |
| live-terminal-cards-2026-10-08 / core-live.log | 0m 22.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/fresh/core-live.log) |
| live-terminal-cards-2026-10-08 / app-all-r3.log | 0m 9.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/prior-candidate/app-all-r3.log) |
| live-terminal-cards-2026-10-08 / core-all-r3.log | 0m 20.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/prior-candidate/core-all-r3.log) |
| live-terminal-cards-2026-10-08 / core-default-r3.log | 0m 35.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/prior-candidate/core-default-r3.log) |
| live-terminal-cards-2026-10-08 / mutation-bash-only-detect.log | 0m 5.1s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/prior-candidate/mutation-bash-only-detect.log) |
| live-terminal-cards-2026-10-08 / mutation-bash-only.log | 0m 23.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/prior-candidate/mutation-bash-only.log) |
| live-terminal-cards-2026-10-08 / restored-candidate-r3.log | 0m 5.2s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/prior-candidate/restored-candidate-r3.log) |
| live-terminal-cards-2026-10-08 / restored-candidate-rebuilt-r3.log | 0m 23.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/live-terminal-cards-2026-10-08/logs/prior-candidate/restored-candidate-rebuilt-r3.log) |
| mcp-2026-10-07 / app-default-clippy.log | 0m 10.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/candidate-3-accepted/app-default-clippy.log) |
| mcp-2026-10-07 / app-default-test.log | 0m 43.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/candidate-3-accepted/app-default-test.log) |
| mcp-2026-10-07 / app-synthetic-clippy.log | 0m 12.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/candidate-3-accepted/app-synthetic-clippy.log) |
| mcp-2026-10-07 / app-synthetic-test.log | 0m 34.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/candidate-3-accepted/app-synthetic-test.log) |
| mcp-2026-10-07 / build.log | 0m 15.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/candidate-3-accepted/build.log) |
| mcp-2026-10-07 / app-default-clippy.log | 0m 10.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/candidate-4-accepted/app-default-clippy.log) |
| mcp-2026-10-07 / app-default-test.log | 0m 28.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/candidate-4-accepted/app-default-test.log) |
| mcp-2026-10-07 / app-synthetic-clippy.log | 0m 13.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/candidate-4-accepted/app-synthetic-clippy.log) |
| mcp-2026-10-07 / app-synthetic-test.log | 0m 34.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/candidate-4-accepted/app-synthetic-test.log) |
| mcp-2026-10-07 / build.log | 0m 15.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/candidate-4-accepted/build.log) |
| mcp-2026-10-07 / final-core-all-clippy.log | 0m 10.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/writer-lease/final-core-all-clippy.log) |
| mcp-2026-10-07 / final-core-all.log | 0m 27.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/writer-lease/final-core-all.log) |
| mcp-2026-10-07 / final-core-default-clippy.log | 0m 9.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/writer-lease/final-core-default-clippy.log) |
| mcp-2026-10-07 / final-core-default.log | 0m 36.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/writer-lease/final-core-default.log) |
| mcp-2026-10-07 / mcp-writer-default.log | 0m 12.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/writer-lease/mcp-writer-default.log) |
| mcp-2026-10-07 / mcp-writer-focused.log | 0m 34.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/writer-lease/mcp-writer-focused.log) |
| mcp-2026-10-07 / mcp-writer-negative-catalogs.log | 0m 0.1s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/writer-lease/mcp-writer-negative-catalogs.log) |
| mcp-2026-10-07 / mcp-writer-negative-subprocess.log | 0m 17.6s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/writer-lease/mcp-writer-negative-subprocess.log) |
| mcp-2026-10-07 / mcp-writer-restored.log | 0m 18.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/writer-lease/mcp-writer-restored.log) |
| mcp-2026-10-07 / writer-independent-default.log | 0m 0.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/writer-lease/writer-independent-default.log) |
| mcp-2026-10-07 / writer-independent-focused.log | 0m 2.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-2026-10-07/writer-lease/writer-independent-focused.log) |
| mcp-inspector-admission-2026-10-07 / baseline-status-contention.log | 0m 32.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-inspector-admission-2026-10-07/baseline-status-contention.log) |
| mcp-status-race-2026-10-08 / final-app-all.log | 0m 35.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-status-race-2026-10-08/final-app-all.log) |
| mcp-status-race-2026-10-08 / final-app-synthetic.log | 0m 34.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-status-race-2026-10-08/final-app-synthetic.log) |
| mcp-status-race-2026-10-08 / final-clippy-all.log | 0m 12.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-status-race-2026-10-08/final-clippy-all.log) |
| mcp-status-race-2026-10-08 / final-clippy-default.log | 0m 11.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-status-race-2026-10-08/final-clippy-default.log) |
| mcp-status-race-2026-10-08 / final-core-all.log | 0m 41.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-status-race-2026-10-08/final-core-all.log) |
| mcp-status-race-2026-10-08 / final-core-default.log | 0m 33.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-status-race-2026-10-08/final-core-default.log) |
| mcp-status-race-2026-10-08 / mcp-green.log | 0m 25.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-status-race-2026-10-08/mcp-green.log) |
| mcp-status-race-2026-10-08 / original-focused.log | 0m 0.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-status-race-2026-10-08/original-focused.log) |
| mcp-status-race-2026-10-08 / status-red.log | 0m 22.3s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/mcp-status-race-2026-10-08/status-red.log) |
| picker-images-2026-10-07 / agent-attachments-negative-candidate.log | 0m 16.4s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/agent-attachments-negative-candidate.log) |
| picker-images-2026-10-07 / agent-attachments-negative-compaction.log | 0m 16.7s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/agent-attachments-negative-compaction.log) |
| picker-images-2026-10-07 / agent-attachments-negative-digest.log | 0m 16.6s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/agent-attachments-negative-digest.log) |
| picker-images-2026-10-07 / app-default-clippy.log | 0m 11.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/app-default-clippy.log) |
| picker-images-2026-10-07 / app-default.log | 0m 31.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/app-default.log) |
| picker-images-2026-10-07 / app-synthetic-clippy.log | 0m 13.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/app-synthetic-clippy.log) |
| picker-images-2026-10-07 / app-synthetic.log | 0m 8.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/app-synthetic.log) |
| picker-images-2026-10-07 / candidate2-build.log | 0m 19.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/candidate2-build.log) |
| picker-images-2026-10-07 / core-all-features.log | 0m 27.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/core-all-features.log) |
| picker-images-2026-10-07 / core-default-clippy.log | 0m 9.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/core-default-clippy.log) |
| picker-images-2026-10-07 / core-default.log | 0m 26.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/core-default.log) |
| picker-images-2026-10-07 / core-synthetic-clippy.log | 0m 6.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/core-synthetic-clippy.log) |
| picker-images-2026-10-07 / core-synthetic.log | 0m 33.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/core-synthetic.log) |
| picker-images-2026-10-07 / focused-picker.log | 0m 24.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/focused-picker.log) |
| picker-images-2026-10-07 / pre-rebase-context-negative.log | 0m 22.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/picker-images-2026-10-07/pre-rebase-context-negative.log) |
| project-skills-2026-10-07 / candidate2-app-default-clippy.log | 0m 13.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-app-default-clippy.log) |
| project-skills-2026-10-07 / candidate2-app-default.log | 1m 44.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-app-default.log) |
| project-skills-2026-10-07 / candidate2-app-synthetic-clippy.log | 0m 14.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-app-synthetic-clippy.log) |
| project-skills-2026-10-07 / candidate2-app-synthetic.log | 1m 28.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-app-synthetic.log) |
| project-skills-2026-10-07 / candidate2-build.log | 0m 19.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-build.log) |
| project-skills-2026-10-07 / candidate2-core-all-features-clippy.log | 0m 13.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-core-all-features-clippy.log) |
| project-skills-2026-10-07 / candidate2-core-all-features.log | 1m 8.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-core-all-features.log) |
| project-skills-2026-10-07 / candidate2-core-default-clippy.log | 0m 11.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-core-default-clippy.log) |
| project-skills-2026-10-07 / candidate2-core-default.log | 0m 45.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-core-default.log) |
| project-skills-2026-10-07 / candidate2-negative-delivery-scope.log | 0m 44.4s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-negative-delivery-scope.log) |
| project-skills-2026-10-07 / candidate2-negative-metadata-revocation.log | 0m 42.1s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-negative-metadata-revocation.log) |
| project-skills-2026-10-07 / candidate2-negative-task-carrier.log | 0m 35.5s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-negative-task-carrier.log) |
| project-skills-2026-10-07 / candidate2-restored-core-all-features.log | 0m 51.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-restored-core-all-features.log) |
| project-skills-2026-10-07 / candidate2-restored-core-clippy.log | 0m 13.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/candidate2-restored-core-clippy.log) |
| project-skills-2026-10-07 / core-all-features-clippy.log | 0m 13.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/core-all-features-clippy.log) |
| project-skills-2026-10-07 / core-all-features.log | 1m 0.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/core-all-features.log) |
| project-skills-2026-10-07 / core-default-clippy.log | 0m 10.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/core-default-clippy.log) |
| project-skills-2026-10-07 / core-default.log | 0m 46.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/core-default.log) |
| project-skills-2026-10-07 / negative-delivery-scope.log | 0m 41.5s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/negative-delivery-scope.log) |
| project-skills-2026-10-07 / negative-metadata-revocation.log | 1m 9.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/negative-metadata-revocation.log) |
| project-skills-2026-10-07 / negative-task-carrier.log | 0m 47.5s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/negative-task-carrier.log) |
| project-skills-2026-10-07 / post-socket-default-clippy.log | 0m 18.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/post-socket-default-clippy.log) |
| project-skills-2026-10-07 / post-socket-default.log | 0m 41.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/post-socket-default.log) |
| project-skills-2026-10-07 / post-socket-synthetic-clippy.log | 1m 29.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/post-socket-synthetic-clippy.log) |
| project-skills-2026-10-07 / post-socket-synthetic.log | 0m 43.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/project-skills-2026-10-07/post-socket-synthetic.log) |
| sidebar-activity-2026-10-09 / app-all-sealed.log | 1m 32.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/app-all-sealed.log) |
| sidebar-activity-2026-10-09 / app-clippy-sealed.log | 0m 8.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/app-clippy-sealed.log) |
| sidebar-activity-2026-10-09 / app-default-build-sealed-r2.log | 0m 14.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/app-default-build-sealed-r2.log) |
| sidebar-activity-2026-10-09 / app-default-clippy-sealed-r2.log | 0m 0.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/app-default-clippy-sealed-r2.log) |
| sidebar-activity-2026-10-09 / app-default-sealed-r2.log | 1m 4.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/app-default-sealed-r2.log) |
| sidebar-activity-2026-10-09 / app-focus-final.log | 0m 19.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/app-focus-final.log) |
| sidebar-activity-2026-10-09 / core-all-features.log | 0m 41.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/core-all-features.log) |
| sidebar-activity-2026-10-09 / core-default.log | 0m 29.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/core-default.log) |
| sidebar-activity-2026-10-09 / app-default-attempt1.log | 1m 10.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/earlier-attempts/app-default-attempt1.log) |
| sidebar-activity-2026-10-09 / app-focus-attempt2.log | 0m 19.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/earlier-attempts/app-focus-attempt2.log) |
| sidebar-activity-2026-10-09 / app-focus-attempt3.log | 0m 18.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/earlier-attempts/app-focus-attempt3.log) |
| sidebar-activity-2026-10-09 / app-focus-attempt4.log | 0m 19.4s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/earlier-attempts/app-focus-attempt4.log) |
| sidebar-activity-2026-10-09 / app-focus-attempt5.log | 0m 19.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/earlier-attempts/app-focus-attempt5.log) |
| sidebar-activity-2026-10-09 / integrations.log | 0m 0.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/integrations.log) |
| sidebar-activity-2026-10-09 / semantic-terminal-all-features.log | 0m 22.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/semantic-terminal-all-features.log) |
| sidebar-activity-2026-10-09 / semantic-terminal-clippy.log | 0m 10.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/semantic-terminal-clippy.log) |
| sidebar-activity-2026-10-09 / semantic-terminal-default.log | 0m 14.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/semantic-terminal-default.log) |
| sidebar-activity-2026-10-09 / workspace.log | 0m 18.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/linux/workspace.log) |
| sidebar-activity-2026-10-09 / baseline-default.log | 0m 16.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/native/baseline-default.log) |
| sidebar-activity-2026-10-09 / baseline.log | 0m 29.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/review/baseline.log) |
| sidebar-activity-2026-10-09 / mutant-baseline.log | 0m 20.3s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/review/mutant-baseline.log) |
| sidebar-activity-2026-10-09 / mutant-menu.log | 0m 19.6s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/review/mutant-menu.log) |
| sidebar-activity-2026-10-09 / restored.log | 0m 20.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-activity-2026-10-09/review/restored.log) |
| sidebar-restored-run-state-2026-10-09 / app-all-features-clippy-final.log | 0m 7.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-restored-run-state-2026-10-09/app-all-features-clippy-final.log) |
| sidebar-restored-run-state-2026-10-09 / app-all-features-final.log | 0m 30.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-restored-run-state-2026-10-09/app-all-features-final.log) |
| sidebar-restored-run-state-2026-10-09 / app-default-final.log | 0m 10.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-restored-run-state-2026-10-09/app-default-final.log) |
| sidebar-restored-run-state-2026-10-09 / app-sidebar-focused.log | 0m 15.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-restored-run-state-2026-10-09/app-sidebar-focused.log) |
| sidebar-restored-run-state-2026-10-09 / core-all-features.log | 0m 44.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-restored-run-state-2026-10-09/core-all-features.log) |
| sidebar-restored-run-state-2026-10-09 / core-all.log | 0m 16.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-restored-run-state-2026-10-09/core-all.log) |
| sidebar-restored-run-state-2026-10-09 / core-clippy-all-features.log | 0m 10.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-restored-run-state-2026-10-09/core-clippy-all-features.log) |
| sidebar-restored-run-state-2026-10-09 / fifo-negative-control.log | 0m 20.9s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-restored-run-state-2026-10-09/fifo-negative-control.log) |
| sidebar-restored-run-state-2026-10-09 / fifo-restored.log | 0m 15.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-restored-run-state-2026-10-09/fifo-restored.log) |
| sidebar-restored-run-state-2026-10-09 / workspace-build-final.log | 0m 14.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-restored-run-state-2026-10-09/workspace-build-final.log) |
| sidebar-restored-run-state-2026-10-09 / workspace-default-clippy-final.log | 0m 6.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-restored-run-state-2026-10-09/workspace-default-clippy-final.log) |
| sidebar-unread-2026-10-09 / all-features-clippy.log | 0m 8.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/all-features-clippy.log) |
| sidebar-unread-2026-10-09 / all-features-workspace-tests.log | 3m 10.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/all-features-workspace-tests.log) |
| sidebar-unread-2026-10-09 / cache-proof-test.log | 0m 17.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/cache-proof-test.log) |
| sidebar-unread-2026-10-09 / default-app-tests.log | 1m 14.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/default-app-tests.log) |
| sidebar-unread-2026-10-09 / default-build.log | 0m 15.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/default-build.log) |
| sidebar-unread-2026-10-09 / default-clippy.log | 0m 7.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/default-clippy.log) |
| sidebar-unread-2026-10-09 / default-workspace-tests.log | 1m 47.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/default-workspace-tests.log) |
| sidebar-unread-2026-10-09 / grace-timer-test.log | 0m 18.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/grace-timer-test.log) |
| sidebar-unread-2026-10-09 / hook-core-all-features-clippy.log | 0m 10.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/hook-core-all-features-clippy.log) |
| sidebar-unread-2026-10-09 / hook-core-default-clippy.log | 0m 7.7s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/hook-core-default-clippy.log) |
| sidebar-unread-2026-10-09 / r4-all-features-app-tests.log | 1m 43.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/r4-all-features-app-tests.log) |
| sidebar-unread-2026-10-09 / r4-all-features-clippy.log | 0m 10.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/r4-all-features-clippy.log) |
| sidebar-unread-2026-10-09 / r4-default-app-tests.log | 0m 55.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/r4-default-app-tests.log) |
| sidebar-unread-2026-10-09 / r4-default-build.log | 0m 0.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/r4-default-build.log) |
| sidebar-unread-2026-10-09 / r4-default-clippy.log | 0m 7.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/r4-default-clippy.log) |
| sidebar-unread-2026-10-09 / r4-reply-geometry.log | 0m 18.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/r4-reply-geometry.log) |
| sidebar-unread-2026-10-09 / r5-all-features-app-tests.log | 1m 44.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/r5-all-features-app-tests.log) |
| sidebar-unread-2026-10-09 / r5-all-features-clippy.log | 0m 8.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/r5-all-features-clippy.log) |
| sidebar-unread-2026-10-09 / r5-default-app-tests.log | 0m 56.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/r5-default-app-tests.log) |
| sidebar-unread-2026-10-09 / r5-default-build.log | 0m 8.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/r5-default-build.log) |
| sidebar-unread-2026-10-09 / r5-default-clippy.log | 0m 7.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/r5-default-clippy.log) |
| sidebar-unread-2026-10-09 / read-state-tests.log | 0m 20.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/read-state-tests.log) |
| sidebar-unread-2026-10-09 / real-uncertainty-test.log | 0m 27.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/real-uncertainty-test.log) |
| sidebar-unread-2026-10-09 / reply-geometry-tests.log | 0m 17.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/app/reply-geometry-tests.log) |
| sidebar-unread-2026-10-09 / final-clippy.log | 0m 8.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/core/final-clippy.log) |
| sidebar-unread-2026-10-09 / final-focused.log | 0m 15.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/core/final-focused.log) |
| sidebar-unread-2026-10-09 / typed-fixture-failure.log | 0m 15.1s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/core/typed-fixture-failure.log) |
| sidebar-unread-2026-10-09 / core-read_observation.log | 0m 0.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/independent-review/core-read_observation.log) |
| sidebar-unread-2026-10-09 / core-workspace__.log | 0m 0.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/independent-review/core-workspace__.log) |
| sidebar-unread-2026-10-09 / core-workspace__read_catalog_tests.log | 0m 0.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/independent-review/core-workspace__read_catalog_tests.log) |
| sidebar-unread-2026-10-09 / core-workspace_read_state.log | 0m 0.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/independent-review/core-workspace_read_state.log) |
| sidebar-unread-2026-10-09 / sidebar-organization.log | 0m 7.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/sidebar-unread-2026-10-09/independent-review/sidebar-organization.log) |
| skill-source-identity-2026-10-07 / agent-skill-path-negative-canonical_target.log | 0m 14.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/skill-source-identity-2026-10-07/logs/agent-skill-path-negative-canonical_target.log) |
| skill-source-identity-2026-10-07 / agent-skill-path-negative-fresh_remap.log | 0m 14.0s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/skill-source-identity-2026-10-07/logs/agent-skill-path-negative-fresh_remap.log) |
| skill-source-identity-2026-10-07 / agent-skill-path-negative-legacy_lookup.log | 0m 15.3s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/skill-source-identity-2026-10-07/logs/agent-skill-path-negative-legacy_lookup.log) |
| skill-source-identity-2026-10-07 / agent-skill-path-negative-metadata_revocation.log | 0m 13.8s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/skill-source-identity-2026-10-07/logs/agent-skill-path-negative-metadata_revocation.log) |
| skill-source-identity-2026-10-07 / agent-skill-path-negative-receipt_identity.log | 0m 14.9s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/skill-source-identity-2026-10-07/logs/agent-skill-path-negative-receipt_identity.log) |
| skill-source-identity-2026-10-07 / agent-skill-path-negative-unique_target.log | 0m 14.8s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/skill-source-identity-2026-10-07/logs/agent-skill-path-negative-unique_target.log) |
| skill-source-identity-2026-10-07 / apple-helper-only-passed.log | 0m 1.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/skill-source-identity-2026-10-07/logs/apple-helper-only-passed.log) |
| skill-source-identity-2026-10-07 / combined-default.log | 1m 3.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/skill-source-identity-2026-10-07/logs/combined-default.log) |
| skill-source-identity-2026-10-07 / prior-default-final.log | 0m 33.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/skill-source-identity-2026-10-07/logs/prior-default-final.log) |
| skill-source-identity-2026-10-07 / prior-focused.log | 0m 24.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/skill-source-identity-2026-10-07/logs/prior-focused.log) |
| source-utf8-integration-2026-10-08 / bash-focused.log | 1m 7.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/source-utf8-integration-2026-10-08/logs/bash-focused.log) |
| source-utf8-integration-2026-10-08 / clippy-all-features.log | 0m 19.3s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/source-utf8-integration-2026-10-08/logs/clippy-all-features.log) |
| source-utf8-integration-2026-10-08 / clippy-default.log | 0m 6.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/source-utf8-integration-2026-10-08/logs/clippy-default.log) |
| source-utf8-integration-2026-10-08 / core-all-features.log | 0m 44.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/source-utf8-integration-2026-10-08/logs/core-all-features.log) |
| source-utf8-integration-2026-10-08 / core-default.log | 0m 44.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/source-utf8-integration-2026-10-08/logs/core-default.log) |
| tool-timing-2026-10-08 / core-1.log | 0m 36.7s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-2026-10-08/earlier-attempts/core-1.log) |
| tool-timing-2026-10-08 / core-2.log | 0m 35.6s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-2026-10-08/earlier-attempts/core-2.log) |
| tool-timing-2026-10-08 / final-app-all.log | 0m 34.7s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-2026-10-08/earlier-attempts/final-app-all.log) |
| tool-timing-2026-10-08 / equality-mutant.log | 0m 25.6s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-2026-10-08/equality-mutant.log) |
| tool-timing-2026-10-08 / final-app-all-r3.log | 0m 9.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-2026-10-08/final-app-all-r3.log) |
| tool-timing-2026-10-08 / final-clippy-all.log | 0m 10.6s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-2026-10-08/final-clippy-all.log) |
| tool-timing-2026-10-08 / final-clippy-default.log | 0m 14.1s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-2026-10-08/final-clippy-default.log) |
| tool-timing-2026-10-08 / final-core-all.log | 0m 41.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-2026-10-08/final-core-all.log) |
| tool-timing-2026-10-08 / final-core-default.log | 0m 32.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-2026-10-08/final-core-default.log) |
| tool-timing-2026-10-08 / sum-mutant.log | 0m 25.2s | [contains failed test or error](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-2026-10-08/sum-mutant.log) |
| tool-timing-gui-2026-10-08 / build.log | 0m 34.0s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/tool-timing-gui-2026-10-08/archive/build.log) |
| topics-2026-10-08 / app-topics-r5.log | 0m 14.9s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/topics-2026-10-08/app-topics-r5.log) |
| topics-2026-10-08 / core-topics.log | 0m 13.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/topics-2026-10-08/core-topics.log) |
| topics-2026-10-08 / final-app-all.log | 0m 34.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/topics-2026-10-08/final-app-all.log) |
| topics-2026-10-08 / final-clippy-all.log | 0m 12.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/topics-2026-10-08/final-clippy-all.log) |
| topics-2026-10-08 / final-clippy-default.log | 0m 10.8s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/topics-2026-10-08/final-clippy-default.log) |
| topics-2026-10-08 / final-core-all.log | 0m 42.4s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/topics-2026-10-08/final-core-all.log) |
| topics-2026-10-08 / final-core-default.log | 0m 33.5s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/topics-2026-10-08/final-core-default.log) |
| topics-2026-10-08 / final-gui-build.log | 0m 16.2s | [recorded components complete; overall invocation exit not inferred](https://github.com/BelloWare/BelloAgent/blob/885a5bcf6e608361692e877d7c77941b0db2f4d8/rust/docs/validation/topics-2026-10-08/final-gui-build.log) |

</details>

<details>
<summary>Implementation/review publication milestones (durations unknown)</summary>

These timestamps mark committed snapshots, not task starts/ends, push completion, active effort or inference. Feature descriptions are commit subjects; they do not claim complete parity.

| Commit UTC | Milestone | Active duration |
|---|---|---|
| 2026-10-04T05:12:39Z | [Publish Rust GPUI agent checkpoint with pinned shared workbench](https://github.com/BelloWare/BelloAgent/commit/07c6a2b2c7052f91e0157b452964ed697b1d5078) | unknown |
| 2026-10-04T05:59:20Z | [Add durable one-project multi-chat and safe draft recovery](https://github.com/BelloWare/BelloAgent/commit/5f2df967a09d68c0019b624b0f3d3eb2c8cb5d9b) | unknown |
| 2026-10-05T03:37:25Z | [Restore source queue timing and grouped presentation](https://github.com/BelloWare/BelloAgent/commit/899b047cd810202aa5c735daf1444b290fa6ee28) | unknown |
| 2026-10-05T03:46:47Z | [Integrate shared editor CRLF deletion fix](https://github.com/BelloWare/BelloAgent/commit/654b6494edb0a43dcd14d17bc9a028f6b6583883) | unknown |
| 2026-10-05T04:02:54Z | [ci(rust): capture isolated Linux UI smoke evidence](https://github.com/BelloWare/BelloAgent/commit/f79504656a507cce981d2c128890a0a952f13a8f) | unknown |
| 2026-10-05T04:08:56Z | [Restore source queued-message detail popover](https://github.com/BelloWare/BelloAgent/commit/056cf6ac93f7989f8df7c162845dd24c2aab3a5e) | unknown |
| 2026-10-05T04:17:17Z | [ci(rust): improve tiny-label OCR without altering evidence](https://github.com/BelloWare/BelloAgent/commit/59a1e9bf13425c95c55e5a13232f93f0b2205fe1) | unknown |
| 2026-10-05T04:22:28Z | [Fix source user-bubble width collapsing to one glyph](https://github.com/BelloWare/BelloAgent/commit/17186a06a1879de5af0b525a1da0bf2516510cb7) | unknown |
| 2026-10-05T04:23:31Z | [ci(rust): focus composer before keyboard smoke](https://github.com/BelloWare/BelloAgent/commit/424cfdbc307de4f1bb5f734183788d4b4bb22ffe) | unknown |
| 2026-10-05T04:24:41Z | [ci(rust): keep startup shortcut focus regression visible](https://github.com/BelloWare/BelloAgent/commit/1df62a831cb4fdad926448b6ce58d4f32373822e) | unknown |
| 2026-10-05T04:27:30Z | [Integrate shared IME and composed-character navigation fixes](https://github.com/BelloWare/BelloAgent/commit/49258c3f3bb51e651e7dd1fce32a6b9b60bd6156) | unknown |
| 2026-10-05T04:29:56Z | [Restore selected composer focus on initial launch](https://github.com/BelloWare/BelloAgent/commit/7f2d5feb80c643554b6fc8450a4d3bfddab0c888) | unknown |
| 2026-10-05T04:33:42Z | [Defer last-window quit beyond native close callback](https://github.com/BelloWare/BelloAgent/commit/76b441de738f29ce4854a3ca28d4ef8a8d20b8ef) | unknown |
| 2026-10-05T05:05:01Z | [Add validated non-executing tool history and replay foundation](https://github.com/BelloWare/BelloAgent/commit/4a9732bcc8df1319abc5e7572829cc9bff0edff4) | unknown |
| 2026-10-05T05:13:46Z | [Verify typed-history failure cuts and disabled-tool transport boundary](https://github.com/BelloWare/BelloAgent/commit/150f7d023af32c6a60c9e2b03c6748f581e33fde) | unknown |
| 2026-10-05T05:20:27Z | [Record source macOS window and termination lifecycle gap](https://github.com/BelloWare/BelloAgent/commit/3e9ea5504a79096f49b4a734faae765175b604bd) | unknown |
| 2026-10-05T05:56:41Z | [Retain workspace entities independently of window bindings](https://github.com/BelloWare/BelloAgent/commit/2048dac43ec47437da8d29260576f645bd33c21e) | unknown |
| 2026-10-05T06:04:30Z | [Record validated workspace retention prerequisite and remaining macOS gaps](https://github.com/BelloWare/BelloAgent/commit/043990b30f30e4cb3bec2bd04854668c5b4b432e) | unknown |
| 2026-10-05T06:18:47Z | [Separate durable save and worker stop from window completion](https://github.com/BelloWare/BelloAgent/commit/e9fb8c974a902537486ec96f2421efff07a21d02) | unknown |
| 2026-10-05T06:56:49Z | [Restore source transcript Copy action and stable resize geometry](https://github.com/BelloWare/BelloAgent/commit/a27029c1b427115dc96eff13fd7c6326733890fb) | unknown |
| 2026-10-05T07:06:46Z | [Add optional isolated macOS own-window lifecycle probe](https://github.com/BelloWare/BelloAgent/commit/6966a43d7ef330e9d37d8802a809e000757e736f) | unknown |
| 2026-10-05T07:26:44Z | [Identify native smoke target by exact GPUI workspace identity](https://github.com/BelloWare/BelloAgent/commit/6d4ce698c92342f99cfc1d93a08475f2e6af42b8) | unknown |
| 2026-10-05T07:32:36Z | [Use standard file locks and verify process ownership](https://github.com/BelloWare/BelloAgent/commit/8ccf5a52c33d55b8ab16af4e8f4f0f24b7040a2f) | unknown |
| 2026-10-05T07:54:48Z | [Record exact successful macOS own-window lifecycle evidence](https://github.com/BelloWare/BelloAgent/commit/510ddc95967a4ae8e53575359095b861f55e5f8c) | unknown |
| 2026-10-05T09:32:58Z | [Restore source sidebar Pin and Unpin with durable organization](https://github.com/BelloWare/BelloAgent/commit/b75dc7cd9bf04e61afd7935a9fc7af78bc0109ac) | unknown |
| 2026-10-05T10:05:02Z | [feat(agent): navigate visible chats with source keyboard shortcuts](https://github.com/BelloWare/BelloAgent/commit/005a83f222da6f464d252c84003aa4520d92f609) | unknown |
| 2026-10-05T10:29:00Z | [fix(agent): cancel dirty-file prompts without stealing focus](https://github.com/BelloWare/BelloAgent/commit/c05e8d866833a701372e76619e4ae74eaca80e09) | unknown |
| 2026-10-05T11:28:30Z | [feat(agent): durably promote queued follow-ups to steering](https://github.com/BelloWare/BelloAgent/commit/fbbffd8d30afe70cdd078e245d523d1dd800dde1) | unknown |
| 2026-10-05T12:02:30Z | [feat(agent): durably reorder queued follow-ups with source drag gesture](https://github.com/BelloWare/BelloAgent/commit/dfef60edf6bb31e67f0ca0463d1b00907f4d91e0) | unknown |
| 2026-10-05T12:29:22Z | [test(agent): scope publication counters to quiescent reorder checks](https://github.com/BelloWare/BelloAgent/commit/916cd712cf479453aa947a4bc393e1b5f5e02f8b) | unknown |
| 2026-10-05T12:51:17Z | [fix(agent): budget queue height from measured pane and composer geometry](https://github.com/BelloWare/BelloAgent/commit/b130fcbc20d03867405da067a57ef8096af5e3bf) | unknown |
| 2026-10-05T13:02:04Z | [test(ci): bound and diagnose Agent Linux UI startup](https://github.com/BelloWare/BelloAgent/commit/2c69f2a242c574f8fc61c094b0cd503397250b92) | unknown |
| 2026-10-05T13:44:01Z | [Restore source queue-header Resume and Send queued controls](https://github.com/BelloWare/BelloAgent/commit/0bfc12042c3464c10fad72df5f870218cf208a7e) | unknown |
| 2026-10-05T14:43:44Z | [Require certain queued-edit status before recovering drafts](https://github.com/BelloWare/BelloAgent/commit/64b2e3848a99e451e711086916955d787772a068) | unknown |
| 2026-10-05T15:03:01Z | [Verify uncertain worker shutdown and correct lifecycle evidence](https://github.com/BelloWare/BelloAgent/commit/8a13714408afa3fccb345efc9ff0f139258d27de) | unknown |
| 2026-10-05T16:24:02Z | [Persist queued Cancel receipts and exact-draft edit barriers](https://github.com/BelloWare/BelloAgent/commit/fc9e530a9e61c3d0bea38a99a6cb68fed0eaac1d) | unknown |
| 2026-10-05T16:48:53Z | [Clear only durably superseded draft-save warnings](https://github.com/BelloWare/BelloAgent/commit/c3848fd00035ba4af9173c7dbe91373e751f3ab4) | unknown |
| 2026-10-06T00:24:06Z | [Keep queued edit adoption responsive and restore held-row actions](https://github.com/BelloWare/BelloAgent/commit/0beb42388ef0424f7d749cd889a8d09f5b8b36db) | unknown |
| 2026-10-06T01:24:38Z | [Reuse populated transcript presentation during unrelated updates](https://github.com/BelloWare/BelloAgent/commit/52703a8cce15865adf34b71d922c085b5a099d85) | unknown |
| 2026-10-06T02:04:05Z | [Add a reproducible manual transcript benchmark and strict report validation](https://github.com/BelloWare/BelloAgent/commit/467c4104e17979a610647ce099f99ef8d85e471e) | unknown |
| 2026-10-06T05:10:23Z | [Render only visible transcript rows while preserving native wheel navigation](https://github.com/BelloWare/BelloAgent/commit/3a142450304a5826ca303a45d5f265902c66ad48) | unknown |
| 2026-10-06T05:41:13Z | [Restore source Stop shortcut with focused text ownership](https://github.com/BelloWare/BelloAgent/commit/ab02f9681a9c27647af9966e709cb9f67b74dcdd) | unknown |
| 2026-10-06T05:57:23Z | [Restore Changes and History keyboard command](https://github.com/BelloWare/BelloAgent/commit/23bc0b743a3d96724eaeb419cfba4135d70dd535) | unknown |
| 2026-10-06T06:17:50Z | [Add source Copy Session ID sidebar action](https://github.com/BelloWare/BelloAgent/commit/d28916db709e4c9c82ec92b1065e5b272417bedb) | unknown |
| 2026-10-06T07:08:53Z | [Keep consumed menu Enter repeats out of composer](https://github.com/BelloWare/BelloAgent/commit/052f50fe783bbc754f24b23715aaa7998ae63155) | unknown |
| 2026-10-06T07:26:45Z | [Add bounded source-backed instruction discovery](https://github.com/BelloWare/BelloAgent/commit/267f6ef8d37a8288643d96339ce7ce3451fc6cc0) | unknown |
| 2026-10-06T07:36:35Z | [Compare canonical paths in instruction discovery fixtures](https://github.com/BelloWare/BelloAgent/commit/7436518cf4ada0b6ca0700c2d576ef54d8133731) | unknown |
| 2026-10-06T07:45:10Z | [Integrate opt-in read-only tools with durable Controller phases](https://github.com/BelloWare/BelloAgent/commit/12e67f22f0cbb0a54e318f159d102fa74aebbe26) | unknown |
| 2026-10-06T10:39:16Z | [Preserve archived chats with durable restore and read-only controls](https://github.com/BelloWare/BelloAgent/commit/42f5d0d92e9b0d7c4b793b4b5a9975ad52a7e613) | unknown |
| 2026-10-06T10:59:49Z | [Keep programmatic root focus from intercepting queue gestures](https://github.com/BelloWare/BelloAgent/commit/693038e682b743da458070466da232baab87db87) | unknown |
| 2026-10-06T11:23:42Z | [Fence retired controllers and scope replacement publications](https://github.com/BelloWare/BelloAgent/commit/a2cef10cc0ff51c4698334d809eddbd04a521303) | unknown |
| 2026-10-06T11:28:14Z | [Define fail-closed project authority envelope contracts](https://github.com/BelloWare/BelloAgent/commit/201a9f8375fb966631be35e0b2ad64c56888ecb8) | unknown |
| 2026-10-06T11:31:15Z | [Render retained tool cards with bounded previews and safe focus](https://github.com/BelloWare/BelloAgent/commit/a639a4ccb2b055e6924f1d8a3366c1f6a4998a43) | unknown |
| 2026-10-06T13:21:21Z | [Add current-project trust UI with fenced runtime replacement](https://github.com/BelloWare/BelloAgent/commit/51782ab961b47f931054921e3d6af549a1775cb3) | unknown |
| 2026-10-06T20:17:11Z | [Release session locks explicitly before descriptor close](https://github.com/BelloWare/BelloAgent/commit/6744f8b9fb7d2317a0f668c24718e8dd903ceab6) | unknown |
| 2026-10-06T20:44:06Z | [Add opt-in Foundation Find with source oracle fixtures](https://github.com/BelloWare/BelloAgent/commit/bee278dd902b1ba84cc16251c9f1faed463d484d) | unknown |
| 2026-10-06T20:57:10Z | [Respect Darwin malformed-glob behavior in Find fixture](https://github.com/BelloWare/BelloAgent/commit/75f5e0451429415100e729e333e058d95482da7d) | unknown |
| 2026-10-06T21:00:31Z | [Add opt-in Foundation Grep with bounded reads](https://github.com/BelloWare/BelloAgent/commit/0e464d26b496af721013c0d7939084ceed3dc499) | unknown |
| 2026-10-06T21:10:12Z | [Add isolated native project authority behind explicit composition](https://github.com/BelloWare/BelloAgent/commit/a4299df2b12c01cbb065a92ac518080d2bdf975a) | unknown |
| 2026-10-06T21:44:38Z | [Persist project identity and fence saved chat mode transitions](https://github.com/BelloWare/BelloAgent/commit/f443882dde2f7d917f3aed6d44bc93d1b35e1a36) | unknown |
| 2026-10-07T03:39:10Z | [Compose synthetic trusted runtimes with delivery instruction snapshots](https://github.com/BelloWare/BelloAgent/commit/88a0ddbb762703c47010f3eb2e537aa1eb0a3d71) | unknown |
| 2026-10-07T03:41:06Z | [Integrate Context preview with synthetic project runtime](https://github.com/BelloWare/BelloAgent/commit/df548008411b602e19ad2c3ac466a7a469ff6ae5) | unknown |
| 2026-10-07T04:04:42Z | [Preserve migration handoff and fix Inspector test attribute](https://github.com/BelloWare/BelloAgent/commit/bd4e6ebb1fcf235a6d96701e8e56d620fd0864c0) | unknown |
| 2026-10-07T04:28:43Z | [Fix Inspector test macro resolution and validate GPUI regressions](https://github.com/BelloWare/BelloAgent/commit/d2c85d4b9730fb8aa29a88922116af78de3d1a6b) | unknown |
| 2026-10-07T04:59:00Z | [Preserve verified cloud Inspector interaction evidence](https://github.com/BelloWare/BelloAgent/commit/de82d56d94099e0fb49434cf28ea0d34ee9f06f9) | unknown |
| 2026-10-07T05:35:24Z | [Connect fixture Settings and saved profiles through guarded chat runtime](https://github.com/BelloWare/BelloAgent/commit/7ca08d1176a23cd268ad891665c80ceb867c42bd) | unknown |
| 2026-10-07T05:47:59Z | [Preserve reproducible Settings LOC accounting and exact CI evidence](https://github.com/BelloWare/BelloAgent/commit/28aa1ef165f085a0f1c9843c88700b941cc16f83) | unknown |
| 2026-10-07T06:12:37Z | [Integrate bounded native read content, durable image replay and source tool cards](https://github.com/BelloWare/BelloAgent/commit/21e7481b7b7073846afd7f9c0a2208405f4d871e) | unknown |
| 2026-10-07T06:32:07Z | [Validate native read pixel budget with a valid bounded oversize PNG](https://github.com/BelloWare/BelloAgent/commit/73c8cd9bcfaa9b9c75c9fe0360bf35c503b8f660) | unknown |
| 2026-10-07T06:45:43Z | [test(read): compare native fixture filesystem identity](https://github.com/BelloWare/BelloAgent/commit/49b5e9330f3d11082efce5809090117887625499) | unknown |
| 2026-10-07T07:24:10Z | [Add guarded editing tools, source change cards and manual compaction](https://github.com/BelloWare/BelloAgent/commit/67b02843cdc353cfa6f5b760c4164a5af4b6da8c) | unknown |
| 2026-10-07T08:49:39Z | [Integrate saved connection authority with trusted chat runtimes](https://github.com/BelloWare/BelloAgent/commit/50da4e9969a75182461dd24619bbad083155d4cb) | unknown |
| 2026-10-07T09:40:03Z | [fix(runtime): preserve completed sessions during late retirement](https://github.com/BelloWare/BelloAgent/commit/33c79e21ca336a98483ca77adf7435aa885bf5d3) | unknown |
| 2026-10-07T11:20:03Z | [Integrate project-scoped Streamable HTTP MCP workflow](https://github.com/BelloWare/BelloAgent/commit/8498464d31778b14c7090c2a34835bac3319849c) | unknown |
| 2026-10-07T13:25:53Z | [Implement picker-selected image attachments and retained user replay](https://github.com/BelloWare/BelloAgent/commit/38a9d1f3efc414eb018a5a170cc01acfbc52aacd) | unknown |
| 2026-10-07T13:42:41Z | [test: compare native attachment paths by canonical target](https://github.com/BelloWare/BelloAgent/commit/af1ce5f7567b67358db03fd56339bce1c83bcb3f) | unknown |
| 2026-10-07T14:20:53Z | [fix: use authoritative MCP outcome state for invocation admission](https://github.com/BelloWare/BelloAgent/commit/a890af0a7797197ee5eee4a538098eabbed2a492) | unknown |
| 2026-10-07T14:46:44Z | [test: normalize accepted socket modes for native fixtures](https://github.com/BelloWare/BelloAgent/commit/110cde32753930599b2e10d76388bcffcf23624e) | unknown |
| 2026-10-07T17:45:33Z | [feat: add project-only explicit skill selection workflows](https://github.com/BelloWare/BelloAgent/commit/e2785bc7ebf6102b1d4d30e34bad40d64ff994c7) | unknown |
| 2026-10-07T18:07:54Z | [test: align native Read replay with task provenance schema](https://github.com/BelloWare/BelloAgent/commit/c0df34001f512c2bc374329c13708afe9bfa0aaa) | unknown |
| 2026-10-07T19:42:49Z | [feat: add bounded trusted Bash execution and live tool output](https://github.com/BelloWare/BelloAgent/commit/2ffbc323b9ad006683c2fef1eafa23f4990d8da5) | unknown |
| 2026-10-07T21:46:44Z | [fix: preserve Swift skill path identities and frozen legacy delivery](https://github.com/BelloWare/BelloAgent/commit/8914fd798e30750a0bd07c209d36138397b9ec4a) | unknown |
| 2026-10-08T02:41:52Z | [fix: match Swift instruction path presentation without changing authority](https://github.com/BelloWare/BelloAgent/commit/2a788cdc226ae6f5d8142112921d04db523681bc) | unknown |
| 2026-10-08T03:31:03Z | [feat(rust): compose opt-in native connection-only authority](https://github.com/BelloWare/BelloAgent/commit/f155d7ec3632562db85e1711e21b9e2e06193470) | unknown |
| 2026-10-08T03:34:51Z | [docs(rust): record native connection host and extend CI coverage](https://github.com/BelloWare/BelloAgent/commit/6eee1d06776b18b55b45f0f8adbbe6204c3cb328) | unknown |
| 2026-10-08T05:28:40Z | [docs: investigate macOS UTF-8 source parity](https://github.com/BelloWare/BelloAgent/commit/3f527c18bdf212ffa670ed0d172d76f4ac1a8837) | unknown |
| 2026-10-08T06:29:31Z | [Fix macOS text decoding with the original Swift semantics](https://github.com/BelloWare/BelloAgent/commit/4ec3cb010c2c10c4ad0fb720c2a37de03ca63a07) | unknown |
| 2026-10-08T06:38:57Z | [Use a borrowed SDK path comparison for strict Clippy](https://github.com/BelloWare/BelloAgent/commit/ab624240bd3e4841d06fc149080d7b3bf126d209) | unknown |
| 2026-10-08T12:11:30Z | [feat(rust): add guarded catalog-assisted Connections workflow and validation evidence](https://github.com/BelloWare/BelloAgent/commit/cf63b6d6f4007e65fe8e6e23bb211caf75b6e6ba) | unknown |
| 2026-10-08T12:31:24Z | [Merge published catalog checkpoint into A4 review branch](https://github.com/BelloWare/BelloAgent/commit/4ca6bcb048e9671c52e1950a2ff383089f5d5bfa) | unknown |
| 2026-10-08T18:38:38Z | [Integrate source UTF-8 decoder with pinned native CI and same-build receipts](https://github.com/BelloWare/BelloAgent/commit/a80b8719771d23156e1547bd9c7b67e84352c06c) | unknown |
| 2026-10-08T18:59:51Z | [Accept timestamp-prefixed GitHub log segment BOM in decoder receipts](https://github.com/BelloWare/BelloAgent/commit/9a07b0062a4e500f1dc49cc9656b90d15b970d93) | unknown |
| 2026-10-08T19:31:34Z | [Reconcile concurrent tools with Swift 0.1.121 and release workspace writer leases explicitly](https://github.com/BelloWare/BelloAgent/commit/b3acabc25817fbac97f54b73c88362fa584d40e3) | unknown |
| 2026-10-08T19:54:26Z | [Show bounded per-call terminal tool cards before batch settlement](https://github.com/BelloWare/BelloAgent/commit/fdc5bb0232f54def59b7a7df5363b6d73bdc2573) | unknown |
| 2026-10-08T21:10:38Z | [feat(rust): preserve completed tool timing and batch wall accounting](https://github.com/BelloWare/BelloAgent/commit/ca6136b57ee6f3bce84ab67ae0a12559bbfa51ca) | unknown |
| 2026-10-08T21:41:11Z | [fix(rust): keep MCP status observation outside tool admission](https://github.com/BelloWare/BelloAgent/commit/a73f56acdf5847e7a9e34c1cb2aceeb051df0db3) | unknown |
| 2026-10-08T22:04:52Z | [test(rust): observe completed actor publication before asserting settlement](https://github.com/BelloWare/BelloAgent/commit/ea2e2ed970cacd13d90e40eed5d1aaa3a565bd1a) | unknown |
| 2026-10-08T22:16:52Z | [feat(rust): add metadata-only current-project Topics workflow](https://github.com/BelloWare/BelloAgent/commit/3a566ae58ee334c3b317a47ce099306c0d6535b5) | unknown |
| 2026-10-08T23:15:54Z | [feat(rust): recover once from explicit context rejection with durable receipts](https://github.com/BelloWare/BelloAgent/commit/4c4315bc7a8c9f36e59a1bb8992a33e5813fa830) | unknown |
| 2026-10-09T01:28:05Z | [feat(rust): add loaded conversation search and copy against 0.1.122](https://github.com/BelloWare/BelloAgent/commit/e2a67c855442a22a24d71a26707df425c5fe277f) | unknown |
| 2026-10-09T01:50:03Z | [fix(rust): restore unopened sidebar run status without resuming work](https://github.com/BelloWare/BelloAgent/commit/1f351cd828ec878e5c0f40b861af5a3a1337c184) | unknown |
| 2026-10-09T02:19:24Z | [feat(rust): stage activity ordering candidate for native validation](https://github.com/BelloWare/BelloAgent/commit/6aad4189ff7ee494c837055ae5b3ebe38948cb9c) | unknown |
| 2026-10-09T02:52:00Z | [feat(rust): persist semantic sidebar activity ordering](https://github.com/BelloWare/BelloAgent/commit/464222b4b72ccb684d501a6301be1f1479591554) | unknown |
| 2026-10-09T03:40:41Z | [feat(rust): persist existing-chat read and unread attention](https://github.com/BelloWare/BelloAgent/commit/af5d548cab548a43b3b3a122111cac76c436ed07) | unknown |
| 2026-10-09T03:45:03Z | [fix(rust): retain unread admission notices and workspace outcome fences](https://github.com/BelloWare/BelloAgent/commit/d40dd93b16fd4782cd68fd9b218986938aa843e1) | unknown |
| 2026-10-09T03:49:47Z | [fix(rust): bound unread writer failures and chained outcome adoption](https://github.com/BelloWare/BelloAgent/commit/ba3bbce87aafbe141f1563f729105e513d59cdd1) | unknown |
| 2026-10-09T03:56:39Z | [fix(rust): revalidate live reply-end geometry before read acknowledgement](https://github.com/BelloWare/BelloAgent/commit/ec9ed1fdeba091095c41237701c741d19366a6a2) | unknown |
| 2026-10-09T04:01:10Z | [test(rust): remove unused mutation in unread resize regression](https://github.com/BelloWare/BelloAgent/commit/76649be3adef49cc4054ea4d479cd1b144780c33) | unknown |
| 2026-10-09T04:15:52Z | [fix(rust): refresh cached transcript proof on read-state delivery](https://github.com/BelloWare/BelloAgent/commit/eba8565c9fd4b01ad9875b338db47125fc2710dd) | unknown |
| 2026-10-09T04:49:44Z | [feat(rust): persist existing-chat unread and read state](https://github.com/BelloWare/BelloAgent/commit/885a5bcf6e608361692e877d7c77941b0db2f4d8) | unknown |

</details>

<details>
<summary>Largest gaps outside CI (unattributed, not proven idle)</summary>

| Start UTC | End UTC | Elapsed |
|---|---|---:|
| 2026-10-04T06:02:17Z | 2026-10-05T03:37:35Z | 21h 35m 18.0s |
| 2026-10-08T03:50:55Z | 2026-10-08T12:11:54Z | 8h 20m 59.0s |
| 2026-10-05T16:57:11Z | 2026-10-06T00:24:21Z | 7h 27m 10.0s |
| 2026-10-06T13:29:56Z | 2026-10-06T20:17:26Z | 6h 47m 30.0s |
| 2026-10-08T12:29:03Z | 2026-10-08T18:39:31Z | 6h 10m 28.0s |
| 2026-10-06T21:56:06Z | 2026-10-07T03:39:49Z | 5h 43m 43.0s |
| 2026-10-07T22:03:03Z | 2026-10-08T02:42:05Z | 4h 39m 2.0s |
| 2026-10-06T02:10:50Z | 2026-10-06T05:10:41Z | 2h 59m 51.0s |
| 2026-10-06T07:51:22Z | 2026-10-06T10:39:40Z | 2h 48m 18.0s |
| 2026-10-07T14:57:44Z | 2026-10-07T17:46:02Z | 2h 48m 18.0s |
| 2026-10-07T11:30:15Z | 2026-10-07T13:26:08Z | 1h 55m 53.0s |
| 2026-10-08T23:34:15Z | 2026-10-09T01:28:43Z | 1h 54m 28.0s |
| 2026-10-07T20:02:52Z | 2026-10-07T21:46:57Z | 1h 44m 5.0s |
| 2026-10-06T11:42:57Z | 2026-10-06T13:21:44Z | 1h 38m 47.0s |
| 2026-10-09T03:14:34Z | 2026-10-09T04:50:19Z | 1h 35m 45.0s |

</details>

## Grouped by UTC start day and platform

Runner/resource sums only; overlapping jobs are not elapsed day totals.

| UTC day | Platform | Jobs | Resource duration | Failed/cancelled jobs |
|---|---|---:|---:|---:|
| 2026-10-04 | GitHub linux | 2 | 6m 0.0s | 0 |
| 2026-10-05 | GitHub apple-silicon | 25 | 2h 23m 51.0s | 1 |
| 2026-10-05 | GitHub linux | 37 | 2h 16m 43.0s | 11 |
| 2026-10-06 | GitHub apple-silicon | 23 | 2h 35m 36.0s | 2 |
| 2026-10-06 | GitHub linux | 23 | 1h 44m 17.0s | 4 |
| 2026-10-07 | GitHub apple-silicon | 22 | 3h 40m 0.0s | 8 |
| 2026-10-07 | GitHub linux | 22 | 2h 5m 25.0s | 4 |
| 2026-10-08 | GitHub apple-silicon | 12 | 3h 53m 33.0s | 1 |
| 2026-10-08 | GitHub linux | 12 | 1h 39m 24.0s | 3 |
| 2026-10-09 | GitHub apple-silicon | 4 | 1h 24m 46.0s | 0 |
| 2026-10-09 | GitHub linux | 4 | 38m 30.0s | 0 |

## Most expensive checkpoint validations

Grouped by exact source SHA across both platforms. Includes successful, failed and cancelled jobs; excludes unknown implementation time.

| Checkpoint / work | Jobs | Runner/resource duration |
|---|---:|---:|
| [feat(rust): add metadata-only current-project Topics workflow](https://github.com/BelloWare/BelloAgent/commit/3a566ae58ee334c3b317a47ce099306c0d6535b5) | 2 | 34m 35.0s |
| [feat(rust): persist existing-chat unread and read state](https://github.com/BelloWare/BelloAgent/commit/885a5bcf6e608361692e877d7c77941b0db2f4d8) | 2 | 34m 5.0s |
| [test(rust): observe completed actor publication before asserting sett…](https://github.com/BelloWare/BelloAgent/commit/ea2e2ed970cacd13d90e40eed5d1aaa3a565bd1a) | 2 | 32m 53.0s |
| [fix(rust): restore unopened sidebar run status without resuming work](https://github.com/BelloWare/BelloAgent/commit/1f351cd828ec878e5c0f40b861af5a3a1337c184) | 2 | 32m 17.0s |
| [Reconcile concurrent tools with Swift 0.1.121 and release workspace w…](https://github.com/BelloWare/BelloAgent/commit/b3acabc25817fbac97f54b73c88362fa584d40e3) | 2 | 32m 9.0s |
| [feat(rust): persist semantic sidebar activity ordering](https://github.com/BelloWare/BelloAgent/commit/464222b4b72ccb684d501a6301be1f1479591554) | 2 | 31m 17.0s |
| [Integrate source UTF-8 decoder with pinned native CI and same-build r…](https://github.com/BelloWare/BelloAgent/commit/a80b8719771d23156e1547bd9c7b67e84352c06c) | 2 | 30m 37.0s |
| [feat: add bounded trusted Bash execution and live tool output](https://github.com/BelloWare/BelloAgent/commit/2ffbc323b9ad006683c2fef1eafa23f4990d8da5) | 2 | 30m 16.0s |
| [feat(rust): recover once from explicit context rejection with durable…](https://github.com/BelloWare/BelloAgent/commit/4c4315bc7a8c9f36e59a1bb8992a33e5813fa830) | 2 | 29m 13.0s |
| [Accept timestamp-prefixed GitHub log segment BOM in decoder receipts](https://github.com/BelloWare/BelloAgent/commit/9a07b0062a4e500f1dc49cc9656b90d15b970d93) | 2 | 27m 12.0s |
| [Show bounded per-call terminal tool cards before batch settlement](https://github.com/BelloWare/BelloAgent/commit/fdc5bb0232f54def59b7a7df5363b6d73bdc2573) | 2 | 26m 16.0s |
| [feat(rust): add guarded catalog-assisted Connections workflow and val…](https://github.com/BelloWare/BelloAgent/commit/cf63b6d6f4007e65fe8e6e23bb211caf75b6e6ba) | 2 | 25m 55.0s |
| [feat(rust): add loaded conversation search and copy against 0.1.122](https://github.com/BelloWare/BelloAgent/commit/e2a67c855442a22a24d71a26707df425c5fe277f) | 2 | 25m 37.0s |
| [fix: preserve Swift skill path identities and frozen legacy delivery](https://github.com/BelloWare/BelloAgent/commit/8914fd798e30750a0bd07c209d36138397b9ec4a) | 2 | 24m 55.0s |
| [fix(rust): keep MCP status observation outside tool admission](https://github.com/BelloWare/BelloAgent/commit/a73f56acdf5847e7a9e34c1cb2aceeb051df0db3) | 2 | 24m 36.0s |

## Update rules

1. Append each future task/invocation with an id, category, UTC start/end, timer seconds, resource, source, outcome and uncertainty. Update status after each completed item; group by both feature and category. Keep failed attempts and retries as separate linked items.
2. Use monotonic elapsed timing plus UTC boundaries for commands. Separate tool execution, queue/blocked waiting, publication and model inference. If inference telemetry remains unavailable, keep it null; never fill it using activity gaps.
3. Record parent/child relationships. Choose one counted level per subtotal; do not add CI jobs and their steps, commands and their compilation lines, or duplicated receipts. Use interval unions for wall coverage and explicit resource sums for parallel work.
4. Recompute grouped totals from duration-data.json and retain source provenance. Corrections amend evidence, not history; estimates must name their method and uncertainty. Do not silently convert unknowns into estimates.
5. Keep tracking files outside rust/ so routine duration updates do not trigger Rust CI. Publish normal commits to rust only; do not modify product code to collect this accounting.
6. Both repositories are updated independently. Shared BelloBox implementation stays in BelloBox; Agent consumer integration/checks stay here. Cross-repository elapsed totals require a joint interval union, never addition.

## Sources and coverage

GitHub REST actions/runs?branch=rust returned 186 runs across two pages; every run was followed by jobs?filter=all, returning 186 jobs. All jobs were completed and all attempts were 1 at collection. Latest Linux run [37885732142](https://github.com/BelloWare/BelloAgent/actions/runs/37885732142) and macOS run [37885732140](https://github.com/BelloWare/BelloAgent/actions/runs/37885732140) both succeeded. Timestamps and step details are retained in the ledger.
Published validation receipts/logs and immutable Git milestones supply additional evidence. Filesystem modification times, private conversation timestamps, product benchmark timings, assistant identities and internal notes are not used as active-effort evidence. Historical work before the first observed run and missing/deleted evidence remain unquantified.

## CI grouped by changed paths

Non-additive regrouping of the same 186 jobs against each exact first parent. Documentation/evidence-only means all changed paths are Markdown/text/images or non-executable validation data under docs; scripts count as mixed changes. This is validation overhead, not an automatic waste claim. Dates, migration effort and published completion are not inferred from this classification.

| Changed-path class | Commits | Jobs | Runner seconds |
|---|---:|---:|---:|
| source/build/workflow or other mixed changes | 97 | 178 | 78284 |
| documentation/evidence-only | 4 | 8 | 2601 |

<!-- duration-track: prospective -->
## New tracked work

Updated: 2026-10-09T06:07:35.887099Z. Historical CI coverage above retains its own cutoff.

Task windows include research, tools, transport and waiting. They are excluded from resource totals and do not measure active labor or model inference.

| Item | Class | Start UTC | End UTC | Duration (seconds) | Outcome |
|---|---|---|---|---:|---|
| Track migration work durations | review | 2026-10-09T05:59:35Z | unknown | unknown | in_progress |
| Reconstruct and document migration duration | review | 2026-10-09T06:00:27Z | 2026-10-09T06:07:35.886838Z | 428.886838 | Initial report and ledger generated; 186 CI jobs, retained receipts and milestones audited; helper tests passed |

### Current counted resource groups

Separate groups may overlap. Never add these blindly. Historical log components/receipts retain their separate disclosed subtotals above.

| Group | Items | Resource sum (seconds) | Known-span wall union (seconds) |
|---|---:|---:|---:|
| ci_job | 186 | 80885.000 | 53609.000 |

See duration-data.json for source, resource, uncertainty, parent relationships and per-category totals. Use duration-track.py begin/end for mixed task windows and record for explicitly measured commands; unknown inference stays null.
