# Selected-conversation Find parity

Specification: BelloAgent Swift main commit `6319e368c6ddb7c3ef18605e78f23b1a5b69e63a`, tree `43ed6d8843a09b58fe00d436dd0e0c1a56c76972`, inspected 2026-10-09. This is a scoped Find workflow, not a declaration of full application or native macOS parity. Recheck main before broadening a parity claim.

## Workflow

- Command-F opens Find and selects an existing query; Command-G opens or advances it. Shift-Command-G reverses only while Find is open, preserving Changes and History when closed. Linux Control equivalents are provided. Editable file tabs keep their routing. Option-Command-F remains Search and Copy Conversation.
- Type a query, wait for the 150 ms debounce, and search every retained display record, including rows outside the rendered viewport. Results arrive in 100-hit-record pages, preserve record/occurrence order, and wrap forward/backward. Return, Shift-Return and Escape operate in the Find editor. Marked-text composition suspends stale searches and navigation; unmark restarts even an unchanged committed query.
- Prose receives temporary source-byte highlights. Tool results decorate only the owning call's OUT editor, open the selected collapsed card/read middle, and scroll the capped inner editor before placing the outer row. Text, Undo, caret, draft and focus ownership remain separate from presentation decoration.
- Close clears transient Find state and decorations; reopening starts blank. Close restores transcript focus only when the query owned focus. Chat/workspace/controller/window identity changes, new queries, newer destinations and manual reader navigation cancel older work.

## Identity and bounded work

Core publishes an atomic snapshot/content-identity pair. The identity represents exact retained session ID, message IDs/order and text, so unrelated streaming/queue/usage publications do not force whole-history comparisons on the UI thread. Display adoption uses the ordinary selected-controller observer and the latest paired publication; queued older watch values cannot roll it back. Tool role, call ownership and preview metadata are checked separately.

Range normalization and mapping run in cancellable background work. Source text remains in immutable snapshot storage. Soft decoration is limited to 64 nearby records, 4096 occurrences per record, 16384 total spans and 8 MiB per row. The selected record is reserved first and its selected occurrence is mapped separately beyond soft-span limits. These are decoration limits, not silently reduced search totals. UI notices disclose partial/omitted previews. Overlapping source envelopes caused by normalization merge only visually; distinct normalized occurrences retain their counts and navigation positions.

Tool geometry comes from actual painted shared-editor layout. The transcript records painted outer origin, viewport and selected row geometry, rejects stale callbacks and permits at most three fresh attempts before an explicit row-level fallback. A scoped deadline prevents permanent pending navigation. This does not constitute a performance-speedup claim. The current callback deliberately retains a conservative whole-presentation identity fence: unrelated streaming that replaces the presentation can force a fresh retry and, if it keeps changing, an explicit row-only outcome. Search totals remain stable; uninterrupted exact tool landing during continuous presentation replacement is not claimed.

## Explicit limits

- The portable matcher reuses existing Search and Copy normalization and limits. Foundation linguistic equivalence is not claimed.
- Current prose is raw text. Full Swift Markdown rendering is outside this slice.
- Generated line numbers, labels, input arguments, image descriptors, omitted generic-output suffixes, omitted diff text and cross-line transformed-preview envelopes are not false exact destinations. Retained source matches can remain honest row-level destinations. No provider/tool rerun or automatic full-content opening is added.
- Find does not add discarded-history recovery, unopened-chat search, Swift storage import, sidebar indexing or a persistence format change.

## Validation boundaries

GPUI TestPlatform exercises actual application query events, keyboard routing, focus ownership, asynchronous delivery, source/display identity, tool path clicks, inner/outer landing, stale-callback rejection, cancellation, draft/clipboard/checkpoint preservation and bounded work. Test-only delivery delays hold real search/preparation results and real fresh-paint callbacks; they do not synthesize a successful geometry result. Selected fixture tests use explicitly synthetic history created through the existing storage APIs.

Synthetic display-only legacy tests use a clearly named fixture adoption helper without a Find binding. Production observer and stale-controller tests retain the normal atomic-pair path. Tool-owner/role rejection and legitimate same-content metadata refresh are tested independently; arbitrary same-controller retained-owner mutation has no public production API and no test-only snapshot constructor was exposed.

Interactive cloud GUI acceptance, native macOS menu/IME/AX/focus behavior, TCC/AX/Keychain, capture/tool/vault authority, signing, same-hardware performance and release acceptance remain separately gated. No screenshots are published as validation. Final package-clean builds and CI must use the reviewed immutable shared Box pin and locked Agent dependency graph; local path-patched runs are development evidence only.
