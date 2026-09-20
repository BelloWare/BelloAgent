# Bello Agent 0.1.63/build 67 acceptance — 2026-09-20

**Published and verified 2026-09-20 08:14:46 UTC.** Source
`b0ae02f51525f517929d4feb53deb5cf3bb9e3fc`; website
`2980441eeb55161c6e17d01c1d4f524d87e3e3d3`.

## Scope

Implements the uploaded chat-behavior plan and adds persistent session ordering
and Copy Turn Info. See the [implementation record](../Chat-Behavior-Implementation-2026-09-20.md).
The native SwiftUI/AppKit architecture and Swift helper remain. No analytics
upload, production-gateway probe, subagents, installation or update rehearsal was
introduced. Existing captures, replay semantics and preview limits remain.

Environment: the same virtual Apple M3 Max, 10 CPUs, 16 GiB, macOS 14.8,
Xcode 16.1/Swift 6. Native windows are tested serially. Release uses optimized
code with testability enabled for tests; the shipped app uses the normal Release
build. Debug runs explicitly enable actor data-race checks.

## Completed validation

- **228 helper tests passed**, 23.949 s, covering provider usage, generations,
  snapshots, cancellation, compaction, tools, byte fidelity and ingress budgets.
  The subsequently found HTTP MCP acknowledgement fix is verified by the staged
  production helper's JSON and multi-batch SSE integration cases below.
- **26 executable gateway tests passed**, 18.102 s. Includes the owner's cost,
  usage/cache/reasoning examples in JSON and fragmented SSE, exact capture,
  request validation, tool rounds, compaction, cancellation, replay, recorder
  rejection, capture-off usage observations, stdio MCP and large HTTP MCP bodies.
- **26 final focused native Debug tests passed**, 4.853 s with actor checks.
  Covers streaming syntax/host lifetime/selection, whole-source reconciliation,
  copyable turn counts, immediate/trailing presentation, native viewport geometry,
  source-position selection, ordering/pasteboard/restart/stale-write behavior.
  The earlier broader Debug selection's other relevant suites also passed.

- **176 optimized native tests passed**, 231.039 s, including composer/helper
  queue semantics, conversation pane lifecycle, turn/copy counts, request usage,
  ordering/topics, native Markdown selection/geometry, disclosure and the full
  35-case streaming-stress selection. The combined case runs 20 real local
  gateway sessions with tools and exact capture alongside two 300-row panes,
  a 2 MiB JSON inspector, marked-text input and resize.

## Measurements and combined workload

- The combined workload recorded 24 native layout opportunities: p50 **27.59 ms**,
  p95 **186.18 ms**, p99/max **206.50 ms**; resize/release **16.88 / 26.60 ms**.
  These are integration work timings, not physical frame rate; the expensive
  cold-content stalls remain material.
- A 20-answer cold short-container comparison in the same optimized process:
  prior SwiftUI stack **1.71 ms mean**, retained native container **3.11 ms**.
  The modest initial cost buys a stable streaming owner; already-complete short
  history retains the stack path.
- Other optimized checks: long-turn streaming among 30 rows **1.8 ms mean /
  9.4 ms worst**; one drag step over 500 rows **10.0 / 13.9 ms**; 300-row
  viewport opening **167 ms**, idle exact geometry **9,336 ms**. These exercise
  different workloads and should not be compared as the same measurement.


The final **134-delta / 300-row** comparison passed in 16.249 s, using 64-byte
chunks and rendering each prefix. Initial baseline: mean **23.2 ms**, maximum
**48.9 ms**, 2.0 sizing passes averaging 14.5 ms per delta. Updated result: mean
**20.7 ms**, p50 **19.27 ms**, p95 **33.86 ms**, p99 **39.51 ms**, maximum
**40.54 ms**; 2.0 sizing passes averaging **12.4 ms** per delta. All 134 deltas
laid out, with 160 retained Markdown blocks and 21 mounted. This modest observed
improvement is not a guarantee of physical frame rate or universal smoothness;
the rich-row result remains above a 16.7 ms frame budget on many updates.

The microbenchmark disables presentation coalescing only for this comparison,
after native mounting and with an assertion on every prefix. Production cadence
is checked separately. An earlier comparison assigned the optional override
before the page existed; its 134-input/40-layout result is discarded as a
before/after comparison. Commit `a0800aa` makes that setup error fail explicitly
instead of looking fast. The normal 300-byte chunk run in the 176-test selection
is also a different workload, not a substitute for the matched comparison.

## Publication checks

- Developer ID signing passes for the app, embedded Swift helper, Sparkle and
  DMG, using the existing Clipboard-style signing setup.
- App notarization accepted: `2815e0fb-c1e8-4a27-a940-58c611768221`; app stapling
  and Gatekeeper assessment pass.
- DMG notarization accepted: `f8208b4d-2827-4064-9289-5e12ea2a24dd`; stapling
  and ticket validation pass.
- The packaged helper smoke passes. The shipping app uses the normal optimized
  Release configuration; dSYMs for app and helper remain beside the artifacts.
- Sparkle Ed25519 signature verified for **8,115,649 bytes (7.74 MiB)**.
  SHA-256: `591a351f9a50f0deb34df45287336dddf654e146155336da0ae450daf5e8677d`.
- Website commit `2980441eeb55161c6e17d01c1d4f524d87e3e3d3` pushed. Cloudflare
  check **106047299701** succeeded at 2026-09-20 08:14:37 UTC.
- Public product link, byte-identical canonical/legacy appcasts and downloaded
  archive SHA-256/Ed25519 verified at **2026-09-20 08:14:46 UTC**.
- Final DMG copied to the session outbox as `BelloAgent-0.1.63.dmg`.

Fresh installation and actual update/relaunch were skipped under the owner's
standing policy. This does not claim new install/upgrade runtime evidence.
