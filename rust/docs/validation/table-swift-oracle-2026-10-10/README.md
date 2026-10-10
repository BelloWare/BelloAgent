# Transcript tables: Rust layout vs Swift 0.1.122 — 2026-10-10

Swift draws a reply's Markdown table as an `NSTextTable`
(`MarkdownTextBuilder.table` in `apps/macos/PiApp/Transcript/MarkdownTextDocument.swift`
at `6319e368`) inside the reply's `NSTextView`. Its geometry was measured, not
guessed, with an oracle that lays out Swift's own code offscreen.

## Oracle

`swift-src/` builds a CLI from `TranscriptMarkdown.swift`,
`MarkdownTextDocument.swift` and `SyntaxHighlighter.swift`, all unchanged, plus
`Stubs.swift` (the block identity, page metrics and table preview limits it
refers to):

```sh
swiftc -O -o oracle swift-src/Stubs.swift swift-src/main.swift \
  TranscriptMarkdown.swift MarkdownTextDocument.swift SyntaxHighlighter.swift
oracle reply.md <container width> drawing.png > geometry.json
```

It parses the reply as Swift does, builds and assembles its paragraphs with
Swift's builder and assembler, lays them out with `MarkdownTextLayoutManager`
in a container of the given width (line fragment padding 0, as the surface
sets it), and prints every table cell's bounds, the table's margins and
outline, and every line fragment; it also saves the drawing at 2x. The
surface's own insets (`NativeMarkdownSurface.firstInset`/`lastInset`) are not
part of the container and are added by the test.

## What Swift does

- Each column is as wide as its widest cell set on one line, `ceil(width) + 1`
  (at most 320 pt in a preview), plus 10 pt padding a side and a 0.5 pt border
  a side: a cell's bounds are 21 pt wider than its text. Cells start 0.5 pt into
  the table (also from its top) and abut; rows are their line plus 13 pt.
- Every cell draws a 1 pt hairline centred on each of its edges, so a shared
  edge is drawn twice (two layers of `hair`) and an outer edge once; the
  rounded outline (radius 4, 1 pt) is drawn over the cells' outer edges, inset
  0.5 pt. The header row is 13 pt semibold system type on `panel`, filled
  inside its border.
- A table wider than its room is narrowed by NSTextTable's automatic layout:
  each cell gets `floor(n × room / Σn − 21) + 21` (at least 22), where `n` is
  its natural width and `room` is the container width less the table's
  leading margin (its indent) and its top margin rounded up. The rounding of
  the top margin also places the table: it starts `ceil(margin)` below the
  paragraph above. (Found by fitting 144 narrowed samples; the rule matches
  every one, and every case below.)
- Under a list item's marker line, the block below takes the inner gap in
  place of its own, so a table there keeps no pad above it.
- The surface adds room above a reply that opens with a heading (6), a table
  (2, not a preview) or a fence (31), and below its last paragraph's pad.

## Checks

`swift-tables.json`: 16 cases (simple, right/centred columns, dressed cells
with code, emphasis, links and strikethrough, narrowed at several widths,
crushed columns, nested in a list item and a quote, under a paragraph, under a
fence, under a list's marker line, a 50-row/10-column preview), with every
cell's bounds, each column's natural width, the table's margins and the
surface's first inset.

- `markdown_view::tests::tables_narrow_as_nstexttable_narrows_them`: Rust's
  narrowing from Swift's own natural widths gives Swift's cell widths in every
  case (exact).
- `transcript_view_tests::tables_open_where_swift_opens_them`: in the Rust
  transcript, every case's first row starts where Swift's does (to the device
  pixel; TextKit places it at fractional points) and its cells abut, from the
  indent plus half a border.

GPUI's test text system gives every glyph the same advance, so cell widths
and wrapping under test are not CoreText's; the native check below covers them.

## Native check

`native/`: one reply (`reply.md`) with a simple, a dressed, a quoted and a
list-nested wide table, drawn by the oracle at 2x (`swift-tables-840.jpg`; its
link is blue and underlined because the bare layout manager lacks the text
view's link attributes) and by the release Rust app on this Mac
(`rust-tables-840.jpg`: window capture at this display's 1x, seeded session,
scratch HOME, nothing sent; transcript column 840 pt). Measured on the Rust
capture against Swift's cell rects:

| | Rust | Swift |
|---|---|---|
| simple table: left edge, column rule, right edge (pt from the column) | 0–1, 120–121, 169–170 | 0.5, 120.5, 169.5 ± 0.5 |
| quoted table: left, rule, right | 15, 84, 140 | 15.5, 84.5, 140.5 ± 0.5 |
| list table: left, right | 28, 837 | 28.5, 836.5 ± 0.5 |
| row pitch | 29 | 29 |
| tops of tables 2–4 from table 1's | 129, 231, 327 | 129.57, 231.07, 327.64 |

Rust places at whole device pixels, TextKit at fractional points; the wide
cells wrap at the same words.

## Not covered

The "Open full table" control beside a preview's note and the table window it
opens (`MarkdownTableWindow`) are not built in Rust; nor is selecting or
copying table text.
