# Loaded conversation search and copy

Search and Copy Conversation, in the Actions menu or archived read-only footer,
reads the selected loaded
chat, including archived chats and completed retained messages outside the transcript's
100-message initial window. Active streaming reply text is excluded until terminal;
interrupted/cancelled retained partial replies remain readable. It does not load a catalog entry, send a provider
request, persist any data, export a file, change a queue or change the composer.

## Source and bounded projection

Specification: Swift main `6319e368c6ddb7c3ef18605e78f23b1a5b69e63a`,
`ConversationContentView.swift`, `WorkspaceContent.swift`, and the loaded host
`SessionReads.swift` contentSearch/contentPage paths. These paths differ from
unopened journal HistoryReader/ConversationContent formatting. Rust copies the
retained message text without adding headings, separators, reasoning, raw tool
arguments, provider items, hidden skill bodies, context metadata or image bytes.
Execution/request-ledger timeline models not represented in Rust are not invented.
Existing raw per-message Copy remains unchanged.

Search pages contain at most 100 hits, positions are one-based, and previews use
240 UTF-8 bytes from the start. Queries are bounded to 256 extended grapheme
clusters and a documented Rust safety limit of 16 KiB, checked before segmentation
or copying input. Matching uses normalized portable Unicode lowercase substring search;
this is not a claim of Foundation locale-aware matching equivalence. Next Results
continues the previously searched query even if the editor has since changed.
Each loaded hit carries the latest source's optional occurrence-count contract:
non-overlapping case-insensitive occurrences per retained record, with zero for an
empty query. This loaded reader always supplies the value; absent values remain
representable for source compatibility (downstream fallback is one). Occurrences
do not consume the 100-record search page limit. The Search/Copy sheet itself does
not display counts, matching the latest source view; full Transcript Find and
sidebar Find/navigation are separate unimplemented parity work.
Matching streams normalization into a bounded-pattern substring matcher; it never
allocates a normalized copy of an entire message. Cancellation is checked at
1,024-scalar intervals during preflight, normalization input and match output.
Normalization rejects a canonical sequence longer than 16,384 consecutive
nonstarters with a visible error, rather than silently omitting a row. These
explicit resource limits adapt Swift semantics to the Rust worker model.

Range endpoints are inclusive. Copy concatenates the retained text exactly, with
an 8 MiB UTF-8 ceiling and bounded collection chunks. Only successful complete
collection writes the clipboard. Invalid ranges, oversize, cancellation, content
changes and stale completions leave it unchanged. Closing the sheet cancels work;
callbacks cannot affect a later sheet or a switched/rebound/replaced chat.

## Identity and revision

The source snapshot comes from Controller.snapshot_shared, not an actor/store lock.
A content fence compares session identity, ordered message identities and projected
text, including equal-length edits. Queue/draft changes alone do not invalidate
retained content. Sheet/operation tokens, selected navigation generation, load
generation, project/workspace identity, window binding and controller identity
are checked before publishing results, copying or revealing. Duplicate message
IDs cannot resolve a reveal to an arbitrary row.

Show in Transcript expands only the retained page needed to reach the selected
exact message. The virtualized list keeps viewport-limited materialization and
its bounded preflight machinery. Tool results paired into cards reveal the
owning card. The reveal is cleared on chat/controller replacement.

## Acceptance scope

Pure projection, bounds, Unicode and revision tests and real GPUI test-platform
controls cover the implemented workflow. Actual desktop interaction evidence,
macOS Foundation matching, native IME/accessibility and native clipboard/focus
acceptance remain separate gates; compilation or fake-platform tests do not
establish those outcomes.
