# Transcript reading and ordered evidence

Introduced in Bello Agent 0.1.76. These are presentation contracts, not instructions to the model or tool executor.

## Reading ownership

Each outer native scroll view owns one `TranscriptReadingCoordinator`. Markdown blocks contribute stable source identities, actual AppKit character ranges and pixel displacement. The coordinator owns clip corrections. Session/generation changes and actual reader navigation invalidate older corrections; source appends and deferred parent height adoption do not. An explicit history/search destination temporarily takes precedence over retained geometry. Following the latest output clears the detached reader anchor.

Content, geometry and decoration are separate. Copy targets and carets update without making exact settled text provisional. Unchanged blocks retain width-specific measurements. Closed local part details accept new source without rebuilding their fixed-height header. Canonical inline Markdown maps provisional UTF-16 selections through Foundation's source positions; it preserves the same editor and never takes first responder from another view. Since 0.1.77, this also reconciles previously parsed fragments against document-scoped reference definitions using the previous block scope, including a definition appended after the last paragraph. The same lazy map restores unselected character anchors. Truly replaced streaming terminal payloads start fresh source identities; ordinary canonical edits keep their existing native containers. Equal rendered paragraphs alone never establish source identity.

## ResponseTimeline version 1

A message may carry `responseTimeline` in the native display projection and `nativeResponseTimeline` in its retained message record. Each segment has a stable ID, provider/local part metadata, text, state, truncation flag and revision.

Part metadata includes physical `attemptID`, ordinal, item ID, output/content/summary index, optional provider sequence, kind, update type, optional tool call ID/name, observation time and evidence. `sessionOrdinal` represents observed session delivery, not an upstream global clock. Observation times use the helper's existing clock and must not be rendered as calendar timestamps. `reconcilesPartKey` identifies a terminal correction's original part.

Kinds distinguish text/refusal, returned reasoning summary/text, tool arguments, opaque provider data, local status and terminal correction. Only adjacent fragments of the same part are coalesced. A/B/A therefore keeps three segments. Terminal content identical to accumulated content changes no segment identity. Different terminal content is explicit correction evidence at its observation position; original fragments remain available. Opaque signatures are not displayed as reasoning text.

Since 0.1.78, response text, returned reasoning, tool arguments and timeline segments are complete. The former 16 KiB/8 KiB flat previews, 64-segment retention limit and per-position timeline text allowances are removed. History pages keep their preferred row/byte window, but admit one complete oversized row. Large IPC results are read automatically from immutable transfers in 192 KiB chunks under the unchanged 1 MiB frame bound; decoding runs off the main actor. Transfers expire explicitly rather than returning a successful prefix. The transport has a 128 MiB resource budget; the existing journal limits still apply. None of these limits silently shorten a displayed answer.

Old shortened timelines are rebuilt in canonical content order from complete message content when available, without rewriting the journal or inventing lost arrival timing. Already-lost standalone presentation fragments cannot be recovered and retain an explicit historical incompleteness notice. Unknown schema versions or malformed identities fall back to retained canonical content.

Native part patches update existing stable segment IDs and revisions. Since 0.1.78, append patches carry only the added text plus the required base revision, so long replies do not resend entire parts on every update. Stale or repeated append patches request a full resync. Structural/state/terminal changes publish immediately; cosmetic fragments use the existing bounded presentation scheduler. Pricing, usage and model evidence are request metadata, not new reasoning events.

## Durable local operations

`requestLedger` and `execution` rows are system presentation messages with `nativeReplayEligible=false`. They never enter provider context or count as assistant responses. Semantic changes append `pi-app.presentation.update.v1` custom records targeting the original row ID. Helper restore and native history apply the newest applicable revision at the original position. Native indexed and direct full-source reads resolve revisions consistently.

A request ledger preserves interrupted partial delivery before a terminal assistant row exists. Once that response is present, the duplicate ledger is hidden. Actual tool-start records are emitted after admission, immediately before invocation. Argument generation alone is not execution evidence. Tool results remain at their recorded position.

Compaction has one stable operation ID with actual summary-attempt parts, validation and durable checkpoint adoption stages. A completed summary is not proof that the candidate was adopted. Restore can use the existing committed checkpoint as adoption evidence; otherwise missing terminal evidence remains interrupted/unknown. Opening, rendering and restoring these records never replays tools.

Legacy flat reasoning/tool/prose cannot establish precise intra-response arrival order. The UI labels this explicitly and keeps its local group at the response's position. Existing task-terminal records remain the sole authority for an aggregate completion receipt.

See [0.1.76 validation](validation/Bello-Agent-0.1.76-2026-09-22.md) for regressions, bounded-wire/durability tests and unverified physical-display scenarios.
