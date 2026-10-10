# Tool rows: Rust model vs Swift 0.1.122 — 2026-10-10

What a tool call's work row says — icon, title, summary, suffix, state, the
trailing clock, help, whether the summary is the file link, and where the row
opens its file — and the Work summary of a run of calls are worked out in
Swift by `TranscriptToolRow.model(of:)` (TranscriptRowParts.swift),
`TranscriptActivity.actionParts`/`describe`/`outcome`/`firstLine`/`shortPath`/
`fileLink`/`formatDuration` (TranscriptActivity.swift), `actionSymbol`
(TranscriptRows.swift) and `ToolCallSummary` (ToolCallSummary.swift), all at
pi-app `6319e368`. Rust's port is
`crates/bello-agent-app/src/transcript_tool_row.rs`.

## Oracle

Swift's declarations are copied unchanged (each from its opening line through
its matching brace) by `extract.py` into `swift-src/Extracted.swift`; the
header comment of each names its file and lines. `swift-src/Stubs.swift`
supplies `ToolView` and the `TranscriptMessage` fields `ToolCallSummary`
reads. `main.swift` runs the model over every call in `corpus.json`:

```sh
python3 -I extract.py /Users/admin/projects/pi-app > swift-src/Extracted.swift
python3 -I corpus.py > corpus.json
swiftc -O -o oracle swift-src/Stubs.swift swift-src/Extracted.swift swift-src/main.swift
./oracle corpus.json > swift-tool-rows.json
```

## Checks

`corpus.json` holds 661 calls: every helper state for each tool kind (bash,
read, write, edit, ls, find, grep, mcp, other) with and without output;
resolved and argument paths (short, deep, trailing slash, empty, missing,
non-ASCII); change counts with the outcome-unknown suffix; durations either
side of every unit boundary; commands that are heredocs, blank, missing,
padded, long, combining-mark, emoji-ZWJ, CRLF, non-string or raw text;
search patterns; every MCP action; failures whose first output line replaces
the summary (bounded to 96 characters); and reads that open at their lines
(offset/limit forms, the host's truncation note, images, host line ranges).
It also holds 26 Work summaries (reasoned or not; failed, skipped, unknown,
preparing; host call counts; truncated replies; a repeated reply id).

`transcript_tool_row_oracle_tests.rs` asserts that the Rust model equals
`swift-tool-rows.json` for every call and every summary. Result: 661/661 rows
and 26/26 summaries equal.
