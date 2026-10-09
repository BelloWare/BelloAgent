# BelloAgent Rust migration: where the time went

## Current accounting checkpoint: 2026-10-09T15:37:00Z

This catch-up incorporates selected verified receipts through the stated cutoff, including late-added earlier observations. Every earlier item and checkpoint remains in the complete ledger and SHA-pinned historical view linked below. It is not a complete timesheet. Model inference duration remains unavailable, not zero. Shared coordination/publication appears once; local receipt hashes establish provenance without claiming independent public timing verification.

### At a glance

These top totals cover only this catch-up receipt cohort, including late-added earlier observations; they are not whole-migration cumulative totals. These are overlapping accounting views, not shares of one total. Mixed windows do not measure active labor.

| Where time went | What is actually measured |
|---|---|
| Implementation | Active effort unavailable; no isolated implementation timer |
| Review | Active effort unavailable; only review-focused observations: 0 mixed windows; 0 with endpoints, unavailable union |
| Mixed implementation/review/validation windows | 1 mixed windows; 1 with endpoints, 4m 32.0s union; scopes overlap resources and do not measure Review alone |
| Builds | Unavailable separately |
| Tests | Unavailable separately from compilation in these command receipts |
| Build + test/check (combined) | Unavailable |
| Interactive GUI validation | 2m 7.1s observed process lifetime; overlaps workflow windows, limited acceptance only |
| CI | No new completed job duration in this cohort; prior terminal jobs remain in the ledger and linked history |
| Dependency/environment setup | Unavailable |
| Retries/rework | 7.8s across 1 failed process/API receipts; total rework effort unavailable |
| Publication | 2m 10.1s measured API/client time; 4 mixed windows; 4 with endpoints, 5m 2.8s union |
| Waiting | Unavailable separately; waiting is mixed into recorded workflow windows |
| Model inference | Unavailable; no timing telemetry |

### Separate measured resource groups

| Group | Timed items | Resource/client seconds | Known-endpoint items | Endpoint-subset seconds | Endpoint union seconds |
|---|---:|---:|---:|---:|---:|
| catchup_gui_process | 2 | 127.115 | 2 | 127.115 | 127.115 |
| catchup_command | 1 | 0.383 | 1 | 0.383 | 0.383 |
| catchup_api | 19 | 130.109 | 19 | 130.109 | 81.894 |

Groups overlap each other and mixed work windows; never add them into project elapsed or active-work time. Derived endpoints are excluded from unions. Monotonic timers and separately recorded UTC clocks can differ slightly. Whole-second 0s means below receipt resolution. CI steps and native subcommands are nested within job durations, not extra runner time.

| Resource group / category | Seconds |
|---|---:|
| catchup_gui_process: interactive GUI validation | 127.115 |
| catchup_command: automated accounting validation | 0.383 |
| catchup_api: publication | 130.109 |

### Nested CI phases (already included in CI jobs)

| Phase class | Runner step time |
|---|---:|

These conservative phase groups can include compilation and execution together; do not add them to the CI job totals.

This cohort adds no CI job execution intervals; prior verified terminal runs remain in earlier accounting. Coverage of 2026-10-09T15:17:00Z–2026-10-09T15:37:00Z is partial and does not establish an idle-time or inference budget.

### Mixed workflows and waits (excluded from resource totals)

| Activity | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---:|---|
| Root verification and paired 15:17 timing publication (shared once) | 2026-10-09T15:29:18.274Z | 2026-10-09T15:29:45.373Z | 27.099 | completed |
| Partial timing audit, focused controls, immutable upload, coordination and readback window (shared once) | 2026-10-09T15:25:40Z | 2026-10-09T15:30:12Z | 272.0 | completed |
| Curated immutable evidence upload and readback batch | 2026-10-09T15:25:30.027Z | 2026-10-09T15:26:20.671Z | 50.644 | completed |
| Root integrated sidebar source verification and normal publication | 2026-10-09T15:35:09.264Z | 2026-10-09T15:35:30.049Z | 20.785 | completed |
| Integrated sidebar Rust macOS native checks CI status | unknown | unknown | unknown | in_progress at 2026-10-09T15:36:08.502Z; final duration unavailable |
| Integrated sidebar Rust Linux checks CI status | unknown | unknown | unknown | in_progress at 2026-10-09T15:36:08.502Z; final duration unavailable |

Open task and CI rows retain unknown final duration. Failed source attempts and the original failed native URL job remain in preserved earlier accounting. Mixed windows overlap useful parallel work; they are not pure idle or active-review time.

### Measured items

| Activity | Category | Start UTC | End UTC | Seconds | Outcome |
|---|---|---|---|---:|---|
| Ordinary selected-history startup control incomplete copy | interactive GUI validation | 2026-10-09T15:18:30.737095387+00:00 | 2026-10-09T15:19:51.604971606+00:00 | 80.867876 | incomplete-copy checkpoint unavailable; not matched workload; normal exit0 |
| Ordinary selected-history startup control corrected copy | interactive GUI validation | 2026-10-09T15:20:36.799522625+00:00 | 2026-10-09T15:21:23.047126016+00:00 | 46.247604 | painted initial capture with actual selected101 transcript; ordinary content-search gate visibly closed; normal exit0 |
| Independent timing operation-identity audit and controls | automated accounting validation | 2026-10-09T15:27:01.387137+00:00 | 2026-10-09T15:27:01.770148+00:00 | 0.3830147870030487 | completed |
| Create curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/README.md | publication | 2026-10-09T15:25:30.376Z | 2026-10-09T15:25:52.552Z | 22.176 | SHA/full readback verified |
| Read curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/README.md | publication | 2026-10-09T15:25:52.552Z | 2026-10-09T15:25:52.996Z | 0.444 | SHA/full readback verified |
| Create curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/gui.md | publication | 2026-10-09T15:25:30.355Z | 2026-10-09T15:25:38.965Z | 8.61 | SHA/full readback verified |
| Read curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/gui.md | publication | 2026-10-09T15:25:38.965Z | 2026-10-09T15:25:39.332Z | 0.367 | SHA/full readback verified |
| Create curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/loc-controls.json | publication | 2026-10-09T15:25:30.376Z | 2026-10-09T15:25:46.670Z | 16.294 | SHA/full readback verified |
| Read curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/loc-controls.json | publication | 2026-10-09T15:25:46.671Z | 2026-10-09T15:25:47.016Z | 0.345 | SHA/full readback verified |
| Create curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/loc-verifier.py | publication | 2026-10-09T15:25:30.376Z | 2026-10-09T15:25:59.562Z | 29.186 | SHA/full readback verified |
| Read curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/loc-verifier.py | publication | 2026-10-09T15:25:59.562Z | 2026-10-09T15:26:00.048Z | 0.486 | SHA/full readback verified |
| Create curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/loc.json | publication | 2026-10-09T15:26:12.827Z | 2026-10-09T15:26:20.671Z | 7.844 | Failed initial upload (denied); authorized unchanged retry later verified |
| Create curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/verification.json | publication | 2026-10-09T15:26:01.793Z | 2026-10-09T15:26:11.375Z | 9.582 | SHA/full readback verified |
| Read curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/verification.json | publication | 2026-10-09T15:26:11.375Z | 2026-10-09T15:26:11.768Z | 0.393 | SHA/full readback verified |
| Create curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/loc.json | publication | 2026-10-09T15:27:36.972Z | 2026-10-09T15:27:48.240Z | 11.268 | SHA/full readback verified |
| Read curated evidence blob: rust/docs/validation/sidebar-content-workflow-2026-10-09/loc.json | publication | 2026-10-09T15:28:17.064Z | 2026-10-09T15:28:17.652Z | 0.588 | SHA/full readback verified |
| Immutable Agent candidate parent ref | publication | 2026-10-09T15:30:37.008Z | 2026-10-09T15:30:37.340Z | 0.332 | Verified immutable candidate; no worker ref movement |
| Immutable Agent candidate tree create | publication | 2026-10-09T15:33:18.777Z | 2026-10-09T15:33:30.272Z | 11.495 | Verified immutable candidate; no worker ref movement |
| Immutable Agent candidate tree read | publication | 2026-10-09T15:33:43.473Z | 2026-10-09T15:33:44.073Z | 0.6 | Verified immutable candidate; no worker ref movement |
| Immutable Agent candidate precommit ref | publication | 2026-10-09T15:33:44.086Z | 2026-10-09T15:33:44.469Z | 0.383 | Verified immutable candidate; no worker ref movement |
| Immutable Agent candidate commit create | publication | 2026-10-09T15:33:50.989Z | 2026-10-09T15:34:00.288Z | 9.299 | Verified immutable candidate; no worker ref movement |
| Immutable Agent candidate commit read | publication | 2026-10-09T15:34:22.344Z | 2026-10-09T15:34:22.761Z | 0.417 | Verified immutable candidate; no worker ref movement |

Full source hashes, source URLs, nested job steps and timing limitations are in duration-data.json. Native macOS full logs were unavailable for some Agent runs; verified job/step metadata is retained without a full-log claim. Later source CI may be running and is not silently promoted to success by this snapshot.


## All recorded resource groups

The ledger retains 1,321 items; 759 are flagged for their own resource-group totals. These are all recorded observations, not a complete migration budget. Groups retain their existing definitions and checkpoint-era names; they must not be added into one elapsed or effort total. Mixed work windows and nested phases remain excluded. Missing endpoints make some interval unions unavailable.

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
| catchup_command | 184 | 4488.239 | 80 | 2419.051 | 2413.178 |
| catchup_api | 118 | 1088.447 | 94 | 810.611 | 424.003 |
| catchup_gui_process | 9 | 1693.121 | 9 | 1693.121 | 1693.121 |

## Complete detail and immutable history

- [Complete per-item timing ledger, sources and checkpoint summaries](duration-data.json).
- [Full historical report through 13:37 UTC](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration.md).
- [Ledger paired with that immutable report](https://github.com/BelloWare/BelloAgent/blob/e6d9fcb8dd98f0d185526a2d985643b60e8a1b1e/duration-data.json).

The current page is a compact view. The ledger retains every historical item unchanged; earlier rendered reports remain available at their original Git commits. Inference timing is unavailable. Resource sums, overlap-safe endpoint subsets and mixed workflow windows answer different questions; none is a complete time budget.
