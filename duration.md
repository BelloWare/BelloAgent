# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T15:47:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 0 mixed windows; 0 with endpoints, unavailable union; scopes overlap resources and do not measure Review alone |
| Builds | 1m 49.5s measured command resource time |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | 3m 36.8s measured command resource time |
| Interactive GUI validation | 2m 5.3s scoped validation + 5m 50.0s diagnostic process lifetimes; no rendering-latency inference |
| CI | 16m 11.0s runner time across 2 completed jobs (2 failed); 8m 42.0s wall union |
| Dependency/environment setup | 37.0s nested CI phase time (already inside CI jobs); command setup shown separately below |
| Retries/rework | 5.2s across 1 failed process/API receipts; total rework effort unavailable |
| Publication | No isolated API total; 1 mixed windows; 1 with endpoints, 29.8s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_command | 21 | 377.617 | 21 | 377.617 | 357.913 |
| catchup_gui_process | 11 | 475.315 | 11 | 475.315 | 475.315 |
| catchup_ci_job | 2 | 971.000 | 2 | 971.000 | 522.000 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_command: automated accounting validation | 0.193 |
| catchup_command: build | 109.531 |
| catchup_command: build + test/check (combined) | 216.801 |
| catchup_command: dependency/environment or verification | 0.453 |
| catchup_command: automated lint/check | 50.638 |
| catchup_gui_process: interactive GUI diagnostics | 349.971 |
| catchup_gui_process: interactive GUI validation | 125.343 |
| catchup_ci_job: ci | 971.000 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|
| CI orchestration | 12.0s |
| dependency/environment setup | 37.0s |
| build + automated lint/check | 3.0s |
| build/test/check (combined) | 15m 14.0s |
| build | 0.0s |
| CI reporting | 0.0s |

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

Within 2026-10-09T15:37:00Z–2026-10-09T15:47:00Z, newly recorded CI jobs cover 436.000 overlap-safe seconds. Remaining time is unclassified, not proven idle or inference.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Root paired timing verification and normal publication (shared once) | 2026-10-09T15:41:13.735Z | 2026-10-09T15:41:43.499Z | 29.764 | completed |
| Initial first-frame diagnostic build setup failed | unknown | unknown | unknown | Required compile-time asset omitted; corrected in subsequent build; full elapsed unavailable |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Independent duration global-identity and historical-prefix audit | automated accounting validation | 2026-10-09T15:39:02.067678+00:00 | 2026-10-09T15:39:02.260634+00:00 | 0.19296199901145883 | completed |
| First-frame diagnostic GUI mode sealed-original | interactive GUI diagnostics | 2026-10-09T15:25:52.854958451+00:00 | 2026-10-09T15:26:33.497567887+00:00 | 40.642609 | black; exit=0 |
| First-frame diagnostic GUI mode original | interactive GUI diagnostics | 2026-10-09T15:27:09.983488610+00:00 | 2026-10-09T15:27:34.240597681+00:00 | 24.257109 | black; exit=0 |
| First-frame diagnostic GUI mode no-install | interactive GUI diagnostics | 2026-10-09T15:28:07.765241296+00:00 | 2026-10-09T15:28:29.344707067+00:00 | 21.579466 | black; exit=0 |
| First-frame diagnostic GUI mode no-update | interactive GUI diagnostics | 2026-10-09T15:28:45.095136845+00:00 | 2026-10-09T15:29:22.467957636+00:00 | 37.372821 | painted selected101 and five Ready rows; exit=0 |
| First-frame diagnostic GUI mode deferred | interactive GUI diagnostics | 2026-10-09T15:29:39.581095020+00:00 | 2026-10-09T15:30:33.232733591+00:00 | 53.651638 | painted selected101 and five Ready rows; exit=0 |
| First-frame diagnostic GUI mode noop-update | interactive GUI diagnostics | 2026-10-09T15:32:26.484227713+00:00 | 2026-10-09T15:32:49.740674501+00:00 | 23.256447 | painted selected101 and five Ready rows; exit=0 |
| First-frame diagnostic GUI mode cache-only | interactive GUI diagnostics | 2026-10-09T15:33:05.706682872+00:00 | 2026-10-09T15:33:29.504294832+00:00 | 23.797612 | painted selected101 and five Ready rows; exit=0 |
| First-frame diagnostic GUI mode early-title | interactive GUI diagnostics | 2026-10-09T15:33:45.400235444+00:00 | 2026-10-09T15:35:00.243931571+00:00 | 74.843696 | painted selected101 and five Ready rows with synthetic title; exit=0 |
| First-frame diagnostic GUI mode original-v2 | interactive GUI diagnostics | 2026-10-09T15:35:16.480410097+00:00 | 2026-10-09T15:35:41.533937708+00:00 | 25.053527 | black; exit=0 |
| First-frame diagnostic GUI mode early-title-restart | interactive GUI diagnostics | 2026-10-09T15:35:58.458004056+00:00 | 2026-10-09T15:36:23.974454775+00:00 | 25.51645 | painted persisted selected102 and five Ready rows with synthetic title; exit=0 |
| First-frame diagnostic v1 build wrapper | build | 2026-10-09T15:26:09.931785904+00:00 | 2026-10-09T15:26:31.954693001+00:00 | 22.022908 | passed |
| First-frame diagnostic v2 build wrapper | build | 2026-10-09T15:31:21.821440269+00:00 | 2026-10-09T15:31:42.270532963+00:00 | 20.449092 | passed |
| First-frame repair aggregate-default | build + test/check (combined) | 2026-10-09T15:46:23.672631+00:00 | 2026-10-09T15:46:36.103634+00:00 | 12.431003 | 0 |
| First-frame repair aggregate-synthetic | build + test/check (combined) | 2026-10-09T15:45:46.526438+00:00 | 2026-10-09T15:46:23.495431+00:00 | 36.968993 | 0 |
| First-frame repair build-default | build | 2026-10-09T15:45:28.003270+00:00 | 2026-10-09T15:46:06.230097+00:00 | 38.226827 | 0 |
| First-frame repair build-synthetic | build | 2026-10-09T15:43:44.848585+00:00 | 2026-10-09T15:44:13.680924+00:00 | 28.832339 | 0 |
| First-frame repair clean-app | dependency/environment or verification | 2026-10-09T15:42:17.029257+00:00 | 2026-10-09T15:42:17.295019+00:00 | 0.265762 | 0 |
| First-frame repair clippy-default | automated lint/check | 2026-10-09T15:45:07.664569+00:00 | 2026-10-09T15:45:27.471460+00:00 | 19.806891 | 0 |
| First-frame repair clippy-synthetic | automated lint/check | 2026-10-09T15:43:23.485843+00:00 | 2026-10-09T15:43:44.469816+00:00 | 20.983973 | 0 |
| First-frame repair fixture-synthetic | build + test/check (combined) | 2026-10-09T15:43:20.794747+00:00 | 2026-10-09T15:43:22.105081+00:00 | 1.310334 | 0 |
| First-frame repair fmt | automated lint/check | 2026-10-09T15:42:17.459492+00:00 | 2026-10-09T15:42:19.798063+00:00 | 2.338571 | 0 |
| First-frame repair search-synthetic | build + test/check (combined) | 2026-10-09T15:43:22.268850+00:00 | 2026-10-09T15:43:23.318548+00:00 | 1.049698 | 0 |
| First-frame repair workspace-default | build + test/check (combined) | 2026-10-09T15:44:14.445234+00:00 | 2026-10-09T15:45:07.103760+00:00 | 52.658526 | 0 |
| First-frame repair workspace-synthetic | build + test/check (combined) | 2026-10-09T15:42:19.964614+00:00 | 2026-10-09T15:43:20.245012+00:00 | 60.280398 | 0 |
| First-frame initial incomplete-input clean-app | dependency/environment or verification | 2026-10-09T15:40:38.309828+00:00 | 2026-10-09T15:40:38.496611+00:00 | 0.186783 | 0 |
| First-frame initial incomplete-input clippy-synthetic | automated lint/check | 2026-10-09T15:41:33.861086+00:00 | 2026-10-09T15:41:39.013855+00:00 | 5.152769 | 101 |
| First-frame initial incomplete-input fixture-synthetic | build + test/check (combined) | 2026-10-09T15:41:31.304392+00:00 | 2026-10-09T15:41:32.508140+00:00 | 1.203748 | 0 |
| First-frame initial incomplete-input fmt | automated lint/check | 2026-10-09T15:40:38.611376+00:00 | 2026-10-09T15:40:40.967583+00:00 | 2.356207 | 0 |
| First-frame initial incomplete-input search-synthetic | build + test/check (combined) | 2026-10-09T15:41:32.642575+00:00 | 2026-10-09T15:41:33.738930+00:00 | 1.096355 | 0 |
| First-frame initial incomplete-input workspace-synthetic | build + test/check (combined) | 2026-10-09T15:40:41.100351+00:00 | 2026-10-09T15:41:30.902784+00:00 | 49.802433 | 0 |
| Repaired first-frame fresh synthetic GUI process | interactive GUI validation | 2026-10-09T15:44:49.623980579+00:00 | 2026-10-09T15:46:54.967314949+00:00 | 125.343334 | Normal exit0; first untouched capture painted; scoped synthetic cloud interaction |
| Exact integrated sidebar linux CI job | ci | 2026-10-09T15:35:34Z | 2026-10-09T15:43:05Z | 451.0 | failure |
| Exact integrated sidebar apple-silicon CI job | ci | 2026-10-09T15:35:36Z | 2026-10-09T15:44:16Z | 520.0 | failure |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,357 items; 793 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

| Existing resource group | Counted timed items | Resource seconds | Items with endpoints | Endpoint-subset seconds | Subset interval union seconds |
|---|---:|---:|---:|---:|---:|
| ci_job | 186 | 80885.000 | 186 | 80885.000 | 53609.000 |
| incremental_api | 58 | 427.621 | 50 | 389.193 | 254.901 |
| incremental_command | 64 | 956.457 | 39 | 517.000 | 517.000 |
| incremental_ci_job | 2 | 2171.000 | 2 | 2171.000 | 1424.000 |
| new_local_command | 8 | 209.302 | 8 | 209.302 | 209.302 |
| new_api_operation | 7 | 45.653 | 0 | 0.000 | unavailable |
| new_native_command | 75 | 506.149 | 74 | 500.224 | 500.244 |
| catchup_ci_job | 14 | 13661.000 | 14 | 13661.000 | 9227.000 |
| catchup_native_command | 36 | 718.272 | 36 | 718.272 | 718.281 |
| catchup_command | 205 | 4865.855 | 101 | 2796.668 | 2771.091 |
| catchup_api | 118 | 1088.447 | 94 | 810.611 | 424.003 |
| catchup_gui_process | 20 | 2168.436 | 20 | 2168.436 | 2168.436 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
