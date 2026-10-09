# r2 read-only review addendum

Initial reviewed freeze manifest SHA256 590ab5e36da4ae25915bc1c7c130580e7d9d3f2ca8dab8e662d0134fcbb7dfda, based on immutable r1 candidate source at unread-native-candidate/source. No Cargo, product edits or remote writes performed by reviewer. Previous review and diagnostics remain unchanged.

Core/catalog source remains byte-identical to all 12 final reviewed core hashes. Narrow App delta changes Resume error prefixing, missing Copy-ID explanation with replacement-path guard, existing Retry/archive fixture registration, and Workspace Arc identity checks on initial Send/generic command/Resume/Cancel/shutdown outcomes. Those changes preserve original dispatch and draft/receipt semantics; Resume uniformly formats both baseline and actor failures. Missing Copy target reports its prior notice without invoking mutation; reused IDs at different paths return before every action.

Blocking findings sent to root and App owner immediately:

1. chat_navigation.rs nested rejected-Send draft recovery outcome (~672–678) checks only project before adopting uncertainty; later Controller rejection cannot undo fencing a replacement Workspace Arc. Repro: rejected Send schedules restore save or settle_rejected; replace workspace with same project path while that write awaits; old uncertain outcome marks new workspace uncertain. Capture and compare exact workspace before any adoption.
2. queue_cancel.rs nested settlement outcome (~533–537) has the same gap after the initial Cancel outcome. Initial Arc guard does not protect the later catalog settlement callback. Add exact workspace guard there too.

Older untouched draft debounce/selection/title/recovery callbacks also have project-only or absent Arc checks; these predate this narrow delta and are recorded as separate scope, not evidence that the new initial guards regress behavior. Awaiting owner fixes/rebound freeze.

## Resolved in r3; final narrow verdict (03:48 UTC)

PASS on manifest d292caf142915327ebea3bdebb8dbbb7b001280421ab718d9ff626b6293250a2. Verified every one of 33 frozen files matches; copied manifest to r3-reviewed-freeze-manifest.json and source digest list to r3-reviewed-source-sha256.txt. All 12 prior core/catalog review hashes remain unchanged.

Both reported chained-outcome findings are fixed: rejected-Send recovery captures recovery_workspace; Cancel settlement captures settlement_workspace. Both compare project and invoke observe_bound_catalog_uncertainty before any uncertainty/UI adoption. The helper refuses a different Workspace Arc before side effects, while still applying genuine uncertainty within the current workspace even if the old Controller was replaced. Source inspections verify actual callback wiring. GPUI regression exercises that shared boundary with stale-negative and current-positive cases and checks draft preservation; it is not a separately controlled full asynchronous interleaving test.

Also reviewed the narrow writer retry correction: catalog-lock failure before flush_shared now increments bounded failure count without double-counting ordinary batch failures. Dirty state remains retained. Saved focused read-state log shows 29/29 PASS, including both the shared Arc-guard and mutex-poison bounded-three-retry regressions. git diff --check passed.

No remaining blocker found in the requested r1-to-r3 delta. Exact aggregate/strict reruns are still ongoing at review time and are not claimed successful here. Native acceptance and preexisting unrelated callback scope remain separate. No reviewer Cargo, source edits or remote writes.
