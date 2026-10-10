# Transcript Markdown: Rust reading vs Swift 0.1.122 — 2026-10-10

`bello_agent_core::markdown` reads Markdown as Swift's
`TranscriptMarkdown.parse` does (`apps/macos/PiApp/Transcript/TranscriptMarkdown.swift`
at `6319e368`, which parses with Foundation's CommonMark/GFM reader). The Rust
reading runs on pulldown-cmark 0.13.4 and reproduces Foundation's choices:

- soft breaks become spaces in replies and stay line breaks in user messages;
  hard breaks are line breaks; trailing spaces end a paragraph;
- headings are semibold serif at 1.5 / 1.3 / 1.12 × the base size (levels 1–3);
  code spans are monospaced at 0.9 ×, table cells 0.9 ×;
- only plain http(s) links without credentials stay links; bare `http(s)://`
  and `www.` addresses are linked (GFM autolinks, trailing punctuation and
  unbalanced `)` excluded, `www.` gets `http://`), except after a `[` still
  open; formatting opened inside a link's text is dropped;
- images become `[Image not loaded: alt]` (alt keeps raw HTML and nested
  images' alt; an empty alt reads as U+FFFC, as in Swift);
- raw HTML is literal text: at the top level a paragraph that runs on through
  adjacent HTML blocks (with its line ending), inside a quote or list item
  nothing; rules show nothing but keep their quote or item;
- empty headings, items, lists and quotes leave no block; a fence with no line
  is dropped, a fence with a blank line is kept; the info string, trimmed and
  lowercased, is the language;
- task markers and footnotes stay literal text.

## Oracle

`swift-src/` builds a CLI from `TranscriptMarkdown.swift` unchanged plus
`Shims.swift` (the font-spec and inline-code attribute types from
`MarkdownTextDocument.swift`, and a stub of the streaming preview it does not
use): `swiftc -O -o swift-markdown-oracle swift-src/*.swift TranscriptMarkdown.swift`.
It prints every block with each inline run's text and dress (size, bold,
italic, monospaced, serif, code, strikethrough, link).

- **Curated corpus** (106 documents covering every construct and its edge
  cases, prose and user styles): checked in as
  `crates/bello-agent-core/tests/data/markdown/`; `markdown::tests` asserts
  Rust equals Swift on every one, in CI.
- **Generated corpus** (`generate.py`, fixed seed, 300 adversarial documents
  mixing nested emphasis, intraword `*`, links, bare URLs, images, HTML,
  breaks, lists, quotes, tables and fences): run with
  `BELLO_MARKDOWN_ORACLE_DIR=<folder> cargo test -p bello-agent-core --lib markdown::tests::generated`.
  74 of 300 documents still differ (69 of 300 without intraword `*`/`_`
  words). `minimize.py` (delta debugging with `rust-dump/`) reduces each to its
  cause; all remaining ones are:
  - ambiguous emphasis delimiter runs (intraword `*` mixed with `**`, an
    unclosed backtick inside emphasis, a delimiter right after a bare URL),
    where Foundation's inline reader and pulldown-cmark resolve differently.
    Checked by hand on `**a*b* é*`, pulldown-cmark follows the CommonMark
    rules there; matching Foundation would mean reimplementing its delimiter
    algorithm;
  - empty table cells: Foundation gives them no run, so Swift drops them and
    the row's later cells shift columns. Rust keeps each cell in its column
    (deliberate; `empty_table_cells_keep_their_column`);
  - a last whitespace-only line without a line ending inside an unclosed fence
    (transient while a reply streams).
