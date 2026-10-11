# Reading and acting on replies: Rust vs Swift 0.1.122 — 2026-10-11

Workstream B2 (`work/reply-actions`). Swift source: pi-app `6319e368`,
`apps/macos/PiApp/`.

## What matches Swift

- **One selectable text per reply** (`transcript_selection.rs`): Swift sets a
  reply in one TextKit text (`Transcript/MarkdownTextDocument.swift`) and
  copies a selection with `MarkdownTextView.copyText`
  (`NativeMarkdownSurface.swift`). Rust models the same text over its
  separate elements: paragraphs, headings, list items (marker "\t•\t",
  copied as "- " / "2. ", two spaces a level), quotes, table cells
  (row-major, copied tab / line break / blank line), fences, and a large
  table's preview note (never copied). Press and drag across blocks, Shift
  extends, double click a word (Unicode word bounds), triple click a
  paragraph, Select All (⌘A) the reply, Copy (⌘C) and the Edit menu reach
  the transcript once a press in its text gave it the focus. The selection
  fill is AppKit's default `selectedTextBackgroundColor` (grey while the
  transcript does not have the focus); selected breaks fill to the line's
  end, as TextKit fills them. A reply that grows keeps a selection in what it
  already said. A message the reader sent selects and copies too.
- **Quote bar** (`transcript_quote.rs`, Swift `TranscriptQuoteSelection.swift`):
  after a press or drag in a reply settles on a non-blank selection, the bar
  floats 6 pt above the selection's first line, centred on it, below the
  last line when there is no room above, 8 pt inside the transcript; surface
  10 pt radius, strong hairline, shadow (radius 10, y 3), 3 pt lit inset on
  hover, glyph + 7 + title 12.5 medium + 7 + "↩" key (10.5 semibold on the
  fill, 4 pt radius). A press elsewhere or a scroll takes it down, Escape too;
  Return acts. Swift's text is quoted as `openQuotedSide` quotes it ("> "
  before each line, a blank line after, below any draft, 256 KiB cap).
- **Inline code at 0.9×** (`transcript_mixed_text.rs`): each stretch of one
  size is shaped on its own and laid end to end on the paragraph's
  baseline; lines wrap by GPUI's own rule (copied) and glyphs paint at their
  stretch's size. Table columns measure mixed cells the same way; a header
  cell stays 13 pt throughout, as Swift's header font overrides its runs.
- **Reply file links** (`transcript_reply_files.rs`, Swift
  `Files/ReplyFileResolver.swift`, `MarkdownTextView.resolveFileLinks`): a
  code span that names a regular file inside the chat's project
  (`path`, `path:N`, an absolute path, `~`) reads in the accent and opens the
  file in its tab at line N. Symbolic links are resolved before the
  containment check; the project itself, directories, `://` text, line
  breaks and names over 4 KiB never resolve. Checked once per reply off the
  main thread, and again at click time.
- **Copy targets** (`transcript_copy_targets.rs`, Swift `TranscriptCopy.swift`):
  the line scanner ported; each top-level heading of a settled reply shows
  `TranscriptCopyButton` (64 × 22.5, "Copy" → "Copied" for 2 s) 30 pt past
  the 640 pt prose end while the pointer is on its line, copying its section
  through its subsections; the reply's introduction (or the whole reply)
  copies from the button over its top corner (3 pt above, at its trailing
  edge) while the pointer is on its words. Tooltips are the targets' labels.
- **Open full table** (`transcript_table_window.rs`, Swift
  `LargeMarkdownTable.swift`): 11 pt accent words ending at the prose end
  beside the preview note; the window "Table · N rows" (880 × 600, min
  440 × 300): a 48 pt bar (title 14 semibold over "N rows", "Copy full table
  as TSV" compact secondary), the grid (26 pt rows, columns sized from the
  title and first 40 rows, 120–420 pt, only rows on screen drawn, selected
  row on the accent's soft fill) and a 120 pt pane with the chosen cell's
  whole text, selectable. TSV quoting as Swift's.
- **Streaming caret** (`NativeMarkdownSurface.updateCaret`, `MarkdownCaretView`):
  2 pt accent bar, as tall as the body size, 5 pt past the last glyph of a
  last paragraph or heading, standing on its line; on for the first half of
  every second.
- **Reply menus** (`ReplyMenu.entries`, response strip and reply part
  `menu(for:)`): right-click on a response strip → Fold This Response to
  One Line / Show This Response, separator, Copy Reply; on a reply's words →
  Fold This Response to One Line, separator, Copy Reply; on a selection →
  Copy. Native `NSMenu` on macOS through `native_menu::show_menu` (the
  sidebar's presentation, now taking any entries).

## How it was checked

- `copy-oracle/`: Swift's own builder, assembler and `copyText` (copied
  verbatim into `main.swift`), compiled with `TranscriptMarkdown.swift`,
  `MarkdownTextDocument.swift`, `SyntaxHighlighter.swift` and the table
  oracle's stubs, over the 106-document Markdown corpus plus 20 list, table,
  quote and fence documents. `copies.json` holds each text (UTF-16) and the
  copies of the whole text, of every range between line breaks and of 60
  random ranges: `transcript_selection::tests::copies_are_swifts_copies`
  checks Rust's text equals Swift's storage and every copy (>7,000 ranges);
  at most two documents (empty table cells, a known parse difference) are
  skipped.
- `copy-oracle/targets/`: `TranscriptCopy.swift` unchanged over the corpus
  plus 14 heading/fence documents (`targets.json`);
  `copy_targets::tests::targets_are_swifts_targets` compares every target.
- `transcript_reply_actions_ui_tests.rs` (GPUI test platform): drag across
  blocks and Copy, double click and Select All, a plain click selecting
  nothing, sent text, the quote bar into the draft, a project file link
  opening its tab (and one outside the project not), heading and corner
  copies with their geometry, the full table window (detail text, TSV), the
  caret, and every menu. `transcript_mixed_text` and
  `transcript_reply_files` have unit tests.

- Codex (gpt-6.1-sol, xhigh, read-only) reviewed the branch twice; its
  findings were fixed: quoting refused while an operation holds the draft,
  a card editor's own Copy / Select All left to it, a large table read from
  the blocks only when opened, the table window's Close Window and Edit
  commands, and the quote bar placed the frame after a selection made
  between frames. Its note that a heading's Copy is matched to the scanner's
  sections by order (so an indented heading inside a loose list shifts the
  later ones) is Swift's own behaviour (`headingIndex` against
  `TranscriptCopy.targets`) and is kept for parity.

## What still differs

- **Quote bar action**: Swift asks in a new side chat ("Ask in side chat");
  Rust has no side chats, so the bar is titled "Quote in draft" and quotes
  into this chat's draft. Needs the owner's approval, or side chats.
- **Message actions**: Copy Turn Info belongs to Swift's turn report and
  Details / Request Details open the Session Inspector; Rust has neither,
  so neither is offered. Edit and Fork are left for a later workstream.
- The selection's text menu is just Copy (AppKit adds Look Up, Services
  and the like). Dragging past the viewport does not scroll; a selection
  stays logical across blocks drawn as spacers but is painted only where
  drawn. A press outside reply text ends the selection (AppKit keeps it,
  inactive). One selection at a time, in one message.
- Drawn (non-macOS) context menus are not provided; the menus open on
  macOS only.
- The table window's bar, traffic lights (at 18, 17) and compact button are
  drawn to Swift's metrics from its source, not measured against a capture.
- The caret blinks on a shared clock rather than from when it appeared, and
  does not stop for Reduce Motion.
