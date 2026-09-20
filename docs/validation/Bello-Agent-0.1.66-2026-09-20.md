# Bello Agent 0.1.66/build 70 acceptance — 2026-09-20

Implementation and focused checks complete. Signing and public release
verification are pending. See [CTX-01–CTX-20](../Context-Meter-Fix-2026-09-20.md)
for changes, evidence and scope limitations.

## Validation

- **74 distinct optimized helper tests passed.** Initial selection: 56 tests,
  3.737 s, covering scoped context, previews, observations, compaction safety and
  budget, queue delivery, display snapshots and streaming cost. Integration:
  20 passes, 0.993 s, with two overlapping context-gateway tests plus 18 tests of
  request counting, compaction gateway/task behavior and retry recovery. Final
  strengthened compaction assertions: 21 passes, 1.696 s, already counted above.
- **58 distinct native Debug tests passed with Swift actor data-race checks.**
  Integration selection: 55 passes in 11.005 s. Final selection: 18 passes in
  1.579 s, including three newly added assertions/scenarios beyond that selection.
  Coverage includes shared preview startup/cancellation, automatic draft context,
  native scope resolution, legacy fallback resets, helper lifecycle, failed
  submissions, queued follow-ups, concurrency and zero transcript publication
  on usage-only updates.
- **26 packaged-helper gateway tests passed**, 42.669 s, against the staged
  shipping helper. Includes actual HTTP/SSE request validation, tool round trips,
  cancellation, retry behavior, compaction and exact transport captures.
- Optimized streaming fixture: 200 streamed updates, **0.3865 ms CPU/update**,
  **985 bytes/update** (maximum 988 bytes), versus a 255,595-byte initial page.
  Snapshot parameters now send context/observation revisions and omit accounting
  on streaming-only reads, matching the native caller. No threshold was loosened.
  Delta accumulation: 4,000 updates, 0.691 microseconds CPU/update; no heap growth.
- The new baseline native tests failed four assertions before production changes:
  busy heuristic rejected, explicit pending retained old count, baseline reset
  retained fallback, and status sequence erased the valid preview. They pass with
  the fix. Earlier tests asserting sequence-based expiry were changed to assert
  semantic replay invalidation and exact retained counts instead.
- One intermediate Debug compile hit SwiftUI's expression type-checking limit.
  Extracting the inspector's primary header and preview label into smaller view
  expressions fixed compilation; the final tests above passed afterward.

Scratch: session `tmp/context-066`. Files: `baseline.log`, `helper-second.log`,
`helper-integration.log`, `helper-compaction-final.log`, `native-integration.log`,
`native-final2.log`, `packaged-gateway.log`, and build/release logs. Scratch
artifacts remain outside the repository and user outbox.

No subagents, live paid/deployed LiteLLM requests, physical GUI reproduction,
installation or actual Sparkle update/relaunch rehearsal were used. Native
reducers/integration tests and deterministic gateways establish the implemented
contracts; they do not establish the owner's exact installed UI failure path or
provider-equivalent tokenization. The existing request-aware heuristic remains
explicitly estimated.

## Publication

Pending signing, notarization, website deployment and downloaded artifact/feed
verification. Final evidence will replace this paragraph after publication.
