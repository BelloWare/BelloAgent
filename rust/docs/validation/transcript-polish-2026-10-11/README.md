# Transcript polish: Rust vs Swift 0.1.122 — 2026-10-11

Workstream B (`work/transcript-polish`). Swift source: pi-app `6319e368`,
`apps/macos/PiApp/`.

## What matches Swift

- **Response header strip** (`transcript_response.rs`) — Swift's
  `TranscriptNativeResponseRow` and `TaskTranscriptPlan.responseLine`: a strip
  above each response saying what it did (`ToolCallSummary.label(reasoned:)`,
  else "Answered"/"Response"), "N parts folded" while folded, 12.5 pt medium
  (11 pt on a plain answer), faint and muted under the pointer; a plain
  answer's strip is 14 pt and silent until hovered; 20 pt strip 4 pt down
  (+2) when the response holds work, +10 while folded. The 18×16 (×14)
  fold button with Swift's arrows, panel on hover, and its tooltip. A press
  anywhere on the strip folds the response to that line (`responseLine`);
  its other rows draw nothing. A streaming response leads with the 11 pt
  spinner (0.8 s turn). Rust draws the strip at the top of the response's
  first row rather than as its own list item, so row indices are unchanged.
- **Folding inside a response** (`response` part): its Think row and cards
  draw closed and keep what the reader opened, as Swift's `responseFolded`.
- **End-of-turn fold** (`transcript_turn_fold.rs`): the answer's own strip
  now folds with the work (Swift `answerHeader`); `TranscriptDisplayMode`
  (Normal / Compact, default Compact, Swift labels and details) is a view
  input — `TranscriptView::set_display_mode` relays out in place.
- **Conversation menu** (`application_menus.rs`): Fold This Turn ⌥⌘[,
  Unfold This Turn ⌥⌘], Fold Every Turn ⇧⌥⌘[, Unfold Every Turn ⇧⌥⌘],
  Fold This Response to One Line, Show This Response, in Swift's order
  (ApplicationMenus.swift 156–161), enabled by Swift's `canFoldTurns` /
  `canFoldResponses`, acting on the turn and response the reader is on
  (`WorkspaceCommands.turnFold(holding:)`, `focusedResponse(holding:)`;
  following the end means the newest). Note: Swift's keys are ⌥⌘[ / ⌥⌘],
  not ⌘[ / ⌘].
- **Work rows** (`transcript_work_line.rs`): a running row's
  `TranscriptShimmer` band (clear → strong panel → clear, 300 pt, 2.6 s),
  under its marks; every row's tooltip is its help, else its summary.
- **Diff and read cards** (`transcript_card_lines.rs`): Swift's
  `TranscriptCardLines` — a diff's sign in a 10 pt box (added `diffAddedMark`
  on `diffAdded`, removed danger on danger 10%), text at 34 pt; a read's
  number right-aligned in a 34 pt gutter, text 12 pt past it; numbers grouped
  ("1,000"); `headTail` (12 lines, 6 + 6) with the middle
  `TranscriptCardMoreLines` line ("… N more lines" / "Show fewer lines")
  between head and tail; an expanded diff scrolls past 224 pt; a failed
  change's or read's body dims to 72%; "Diff preview unavailable — N lines.
  Full content is available below."; `└ +N −M` grouped.

## How it was checked

- `transcript_polish_oracle_tests.rs` against `swift-polish.json`, made by
  compiling Swift's own declarations unchanged (`extract.py` →
  `swift-src/Extracted.swift`, with `Stubs.swift` and `main.swift`):
  `TranscriptCardMetrics` (164 splits), `TranscriptReadCardText.window`,
  `transcriptNumber` (en_US), `TurnFoldSpec.label`/`isSubagent`,
  `TranscriptDisplayMode`, and 45 response work labels over
  `ToolCallSummary`. All equal.

  ```sh
  python3 -I extract.py <pi-app checkout> > swift-src/Extracted.swift
  (cd swift-src && swiftc -O -o oracle Stubs.swift Extracted.swift main.swift)
  swift-src/oracle > swift-polish.json
  ```
- The tool-row oracle (661 rows, 26 summaries) still passes.
- GPUI tests: `transcript_response_ui_tests.rs` (strip geometry and words,
  fold to one line and back, inside fold keeps opened cards, display mode
  switch, fold commands following the reader), `application_menus_tests.rs`
  (menu order, key equivalents, availability, routing; ⌥⌘ keys gated to
  macOS), work-row shimmer, and the reworked edit/read/find tests (marks,
  tints, head/middle/tail geometry, find landing on a read line by its own
  layout).
- Native look: debug build on this Mac, scratch HOME, session from
  `seed.py` (structure seed + a 40-line read and a 30-line edit), window
  captures in `screens/`: 01 the compact fold, 02 an opened turn with the
  response strip under the pointer, 03 the diff card, 04 the read card.

## What still differs

- The strip has no duration or figures: Rust's history keeps no per-request
  clock or gateway accounting yet (the fields are wired, always empty).
- No context menus on the strip or rows (Rust's transcript has none).
- Work rows have no keyboard focus ring: the main window has no key loop
  (Tab) for transcript rows yet; adding one is a window-wide decision.
- A read's expanded window and lines use one editor per run; selection runs
  across a run's lines (Swift selects per line), and each mark is placed by
  re-wrapping the line with the editor's wrapper.
- A change too large to diff keeps Rust's in-section full content rather
  than Swift's Before/After disclosure.
- Not started: reply text selection with Copy and quote into draft
  (`MarkdownSelection.swift`, `TranscriptQuoteSelection.swift`).
