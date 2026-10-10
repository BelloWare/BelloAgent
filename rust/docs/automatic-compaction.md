# Automatic (threshold) compaction

Specification: Swift 0.1.122 (`6319e368`) `SessionRun.swift` (threshold check
before each model request), `SessionCompaction.swift` (`compactionThreshold`,
`canCompact`, `compactContext(reason:)`), `CompactionPlanner.swift`
(`CompactionPolicy.trigger`, `prepare`), `RequestContext.swift`
(`safetyMargin`) and `CompactionSourceBuilder.swift`.

## What matches Swift

- Before every model request of a turn (each model/tool round), the request's
  estimated size is compared with `compactionThreshold`: the window minus
  `max(maxOutputTokens, summaryTokens + instructionTokens)`, the safety margin
  `min(1024, max(1, window/100))` and `min(16384, window/4)`. The instruction is
  the real checkpoint instruction for the normal keep-recent cut, no focus and
  the default visible target. `summaryTokens = min(16384, modelOutputLimit,
  window/4)`. A window too small for these reserves fails the turn, as Swift's
  `try compactionThreshold` does.
- At or above the threshold, and when something new besides required inputs
  can be compacted (`canCompact`), the chat compacts first, then sends the
  request on the compacted context. The first request of an explicit Retry
  skips the check (`resumingFailedRequest`). The request that follows the
  compaction is not checked again in that round.
- Nothing useful to replace (Swift `compact_unavailable`: already compacted,
  only required inputs, an over-long boundary) is ignored while the intact
  request fits; otherwise, and for every other failure, the run fails with the
  compaction's error and the original history.
- The plan uses Swift's automatic rules: keep-recent cut, then move the cut
  until the retained tail plus the full summary allowance fits and is below the
  threshold measured with this cut's instruction (`hasRoom`); the candidate must
  free at least the safety margin and land below its own next threshold
  (`compact_no_progress`). Context-rejection recovery now uses the same rules
  (Swift applies them to every non-manual reason).
- Values were checked against an oracle compiled from Swift's unchanged
  sources: [compaction-threshold-swift-oracle-2026-10-10](validation/compaction-threshold-swift-oracle-2026-10-10/README.md).

## How Rust runs it

The compaction is the in-turn recovery machinery with receipt reason
`threshold` (no provider failure). Preparation is local and writes nothing.
The durable receipt is written before the summary request, then the usual
authority, resource and binding confirmations, Stop, write-fault fencing and
reopen rules apply: reopen marks the receipt interrupted and pauses input, and
the original history stays active until a checkpoint is adopted. A completed
tool batch is never re-entered. Rust creates the reply row before the request,
so that unrequested empty row is kept as `compaction-deferred` (never
replayed, hidden in the App); the progress row carries Swift's
"Compaction · …" labels and the next reply is ordinary. Snapshot receipts
without a reason read as context-rejection receipts, byte for byte as before.

## Deliberate differences

- Request size: Swift uses the last reply's reported usage when its usage
  binding matches the request; Rust records no usage bindings, so it always
  uses Swift's own fallback, the projection estimate. Rust may therefore
  compact at a different point than Swift on long tool-heavy chats.
- One compaction per logical request: the request after a threshold
  compaction cannot use context-rejection recovery (Swift would allow one), and
  after a failed or stopped threshold compaction the turn cannot compact again
  until a reply completes (Swift's `compact_previous_failure` covers most of
  this). The 256-receipt bound also caps automatic compactions per chat; past
  it the request is sent intact.
- One captured steering message is delivered after the checkpoint (Swift
  drains all pending steering only if none was delivered at the round start).
- Rust refuses locally when the intact history plus the summary allowance
  cannot fit, where Swift would send the summary request.
- Rust's wire request has no pi `msg_pi_<n>` ids on assistant message items;
  the checkpoint boundary still names them as Swift does, so the instruction
  (and the threshold) are Swift's.
- The legacy synthetic dynamic-resource runtime never compacts automatically.
