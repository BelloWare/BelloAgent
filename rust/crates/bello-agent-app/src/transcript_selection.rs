//! A reply as one selectable text, as Swift 0.1.122 sets it in one TextKit
//! text (`MarkdownTextDocument.swift`) and copies it
//! (`MarkdownTextView.copyText`, NativeMarkdownSurface.swift): every
//! paragraph, heading, list item, quote, table cell and fence in reading
//! order, one line break between two paragraphs. A copy is the text as it
//! reads: a list item's marker as "- " or "2. " (indented two spaces a level),
//! a table's cells split by tabs and its rows by line breaks, blocks by a
//! blank line, and the page's own words (a large table's preview note) left
//! out.
//!
//! Rust draws a reply as separate text elements; each is one piece of this
//! text, named by the element's owner. The text's offsets are bytes of the
//! pieces laid end to end with one byte for each break, as Swift's storage
//! lays its characters (a marker is its storage text, "\t•\t").
use bello_agent_core::markdown::{Block, Span};
use gpui::SharedString;
use std::{collections::HashMap, ops::Range};

/// Swift's `MarkdownTablePresentation`.
pub(super) const PREVIEW_ROWS: usize = 20;
pub(super) const PREVIEW_COLUMNS: usize = 8;

pub(super) fn large_table(header: &[Vec<Span>], rows: &[Vec<Vec<Span>>]) -> bool {
    rows.len() > 40
        || header.len() > PREVIEW_COLUMNS
        || rows.iter().any(|row| row.len() > PREVIEW_COLUMNS)
}

/// A count as Swift's `formatted()` writes it: thousands grouped.
pub(super) fn grouped(count: usize) -> String {
    let digits = count.to_string();
    let mut out = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

/// A large table's note above its preview.
pub(super) fn preview_note(rows: usize) -> String {
    format!(
        "Preview · first {} of {} rows · up to {PREVIEW_COLUMNS} columns",
        rows.min(PREVIEW_ROWS),
        grouped(rows)
    )
}

#[derive(Clone, Debug, PartialEq)]
pub(super) enum Kind {
    /// The reply's own words.
    Text,
    /// A list item's marker: its storage text is "\t•\t", a copy gives this.
    Marker(String),
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Piece {
    /// The text element's owner (the reply's owner and the block's path).
    pub owner: SharedString,
    pub text: String,
    pub kind: Kind,
    /// Where the piece begins in the reply's text.
    pub start: usize,
    pub paragraph: usize,
}

impl Piece {
    pub fn range(&self) -> Range<usize> {
        self.start..self.start + self.text.len()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Paragraph {
    pub pieces: Range<usize>,
    /// What a copy puts for the line break after it (Swift's `breakCopy`).
    pub break_copy: String,
    /// The page's own words (`piChrome`): a copy leaves them out.
    pub chrome: bool,
    pub start: usize,
    /// Where its text ends: the break after it, if any, is this byte.
    pub end: usize,
}

/// A reply's text: its pieces in reading order.
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct ReplyText {
    pub pieces: Vec<Piece>,
    pub paragraphs: Vec<Paragraph>,
    owners: HashMap<SharedString, usize>,
    pub len: usize,
}

/// One paragraph as Swift's builder makes it.
struct Built {
    pieces: Vec<(SharedString, String, Kind)>,
    break_copy: String,
    chrome: bool,
    /// Swift's `multiline` or `textBlocks` or a fence: a list marker cannot
    /// lead its first line.
    boxed: bool,
}

fn joined(spans: &[Span]) -> String {
    spans.iter().map(|span| span.text.as_str()).collect()
}

fn prose(owner: String, spans: &[Span]) -> Built {
    Built {
        pieces: vec![(owner.into(), joined(spans), Kind::Text)],
        break_copy: "\n\n".into(),
        chrome: false,
        boxed: false,
    }
}

/// `MarkdownTextBuilder.paragraphs`, as the reply's owner and the block's
/// path name each element (`transcript_markdown`'s paths).
fn paragraphs(block: &Block, owner: &str, path: &str, depth: usize, out: &mut Vec<Built>) {
    match block {
        Block::Paragraph(spans) | Block::Heading { spans, .. } => {
            out.push(prose(format!("{owner}{path}"), spans));
        }
        Block::Code { code, .. } => out.push(Built {
            pieces: vec![(format!("{owner}{path}").into(), code.clone(), Kind::Text)],
            break_copy: "\n\n".into(),
            chrome: false,
            boxed: true,
        }),
        Block::Quote(blocks) => {
            for (index, child) in blocks.iter().enumerate() {
                paragraphs(child, owner, &format!("{path}.{index}"), depth, out);
            }
        }
        Block::List {
            ordered,
            start,
            items,
        } => {
            for (index, item) in items.iter().enumerate() {
                let number = start + index as u64;
                let marker = if *ordered {
                    format!("{number}.")
                } else {
                    "•".into()
                };
                let copy = "  ".repeat(depth)
                    + &if *ordered {
                        format!("{marker} ")
                    } else {
                        "- ".into()
                    };
                let mut parts = Vec::new();
                for (block_index, block) in item.iter().enumerate() {
                    paragraphs(
                        block,
                        owner,
                        &format!("{path}.{index}.{block_index}"),
                        depth + 1,
                        &mut parts,
                    );
                }
                let marker_piece = (
                    SharedString::from(format!("{owner}{path}.{index}m")),
                    format!("\t{marker}\t"),
                    Kind::Marker(copy),
                );
                match parts.first_mut() {
                    // The marker leads the item's first line.
                    Some(first) if !first.boxed => first.pieces.insert(0, marker_piece),
                    // An item that opens with a fence, a table or nothing
                    // has its marker on a line of its own.
                    _ => parts.insert(
                        0,
                        Built {
                            pieces: vec![marker_piece],
                            break_copy: "\n\n".into(),
                            chrome: false,
                            boxed: false,
                        },
                    ),
                }
                // Inside an item a copy puts one line break between lines.
                let count = parts.len();
                for part in &mut parts[..count - 1] {
                    if part.break_copy == "\n\n" {
                        part.break_copy = "\n".into();
                    }
                }
                // Between two items, one line break too.
                if index + 1 < items.len()
                    && let Some(last) = parts.last_mut()
                {
                    last.break_copy = "\n".into();
                }
                out.extend(parts);
            }
        }
        Block::Table { header, rows, .. } => {
            let large = large_table(header, rows);
            let shown_columns = if large { PREVIEW_COLUMNS } else { usize::MAX };
            let shown_rows = if large {
                &rows[..rows.len().min(PREVIEW_ROWS)]
            } else {
                rows
            };
            let mut cells: Vec<Vec<&Vec<Span>>> = Vec::new();
            if !header.is_empty() {
                cells.push(header.iter().take(shown_columns).collect());
            }
            for row in shown_rows {
                cells.push(row.iter().take(shown_columns).collect());
            }
            let columns = cells.iter().map(Vec::len).max().unwrap_or(0);
            if columns == 0 {
                return;
            }
            if large {
                out.push(Built {
                    pieces: vec![(
                        format!("{owner}{path}.note").into(),
                        preview_note(rows.len()),
                        Kind::Text,
                    )],
                    break_copy: String::new(),
                    chrome: true,
                    boxed: false,
                });
            }
            let last_row = cells.len() - 1;
            for (row_index, row) in cells.iter().enumerate() {
                for column in 0..columns {
                    let text = row.get(column).map_or_else(String::new, |spans| joined(spans));
                    out.push(Built {
                        pieces: vec![(
                            format!("{owner}{path}.{row_index}.{column}").into(),
                            text,
                            Kind::Text,
                        )],
                        break_copy: if row_index == last_row && column + 1 == columns {
                            "\n\n".into()
                        } else if column + 1 < columns {
                            "\t".into()
                        } else {
                            "\n".into()
                        },
                        chrome: false,
                        boxed: true,
                    });
                }
            }
        }
    }
}

impl ReplyText {
    /// The reply's blocks as one text; `owner` is the reply's text owner.
    pub fn new(blocks: &[Block], owner: &str) -> Self {
        let mut built = Vec::new();
        for (index, block) in blocks.iter().enumerate() {
            paragraphs(block, owner, &format!(".{index}"), 0, &mut built);
        }
        let mut text = Self::default();
        let mut at = 0;
        for (number, paragraph) in built.into_iter().enumerate() {
            if number > 0 {
                at += 1;
            }
            let start = at;
            let first = text.pieces.len();
            for (owner, piece, kind) in paragraph.pieces {
                text.owners.insert(owner.clone(), text.pieces.len());
                let len = piece.len();
                text.pieces.push(Piece {
                    owner,
                    text: piece,
                    kind,
                    start: at,
                    paragraph: number,
                });
                at += len;
            }
            text.paragraphs.push(Paragraph {
                pieces: first..text.pieces.len(),
                break_copy: paragraph.break_copy,
                chrome: paragraph.chrome,
                start,
                end: at,
            });
        }
        text.len = at;
        text
    }

    pub fn piece(&self, owner: &str) -> Option<usize> {
        self.owners.get(owner).copied()
    }

    /// The text as Swift's storage holds it, for checks.
    #[cfg(test)]
    pub fn storage(&self) -> String {
        let mut out = String::new();
        for (index, paragraph) in self.paragraphs.iter().enumerate() {
            if index > 0 {
                out.push('\n');
            }
            for piece in &self.pieces[paragraph.pieces.clone()] {
                out.push_str(&piece.text);
            }
        }
        out
    }

    /// `MarkdownTextView.copyText` over `range` of the text.
    pub fn copy(&self, range: Range<usize>) -> String {
        let mut out = String::new();
        if range.start >= range.end {
            return out;
        }
        for paragraph in &self.paragraphs {
            if paragraph.start > range.end {
                break;
            }
            if !paragraph.chrome {
                for piece in &self.pieces[paragraph.pieces.clone()] {
                    let span = piece.range();
                    let (from, to) = (range.start.max(span.start), range.end.min(span.end));
                    if from >= to {
                        continue;
                    }
                    match &piece.kind {
                        Kind::Text => {
                            let local = floor(&piece.text, from - span.start)
                                ..floor(&piece.text, to - span.start);
                            out.push_str(&piece.text[local]);
                        }
                        // A marker counts once, however the selection cuts it.
                        Kind::Marker(copy) => out.push_str(copy),
                    }
                }
                if range.contains(&paragraph.end) && paragraph.end < self.len {
                    out.push_str(&paragraph.break_copy);
                }
            }
        }
        out
    }

    /// The piece and its local offset at `at`, the piece before a break.
    pub fn locate(&self, at: usize) -> Option<(usize, usize)> {
        let index = self
            .pieces
            .partition_point(|piece| piece.start <= at)
            .checked_sub(1)?;
        let piece = &self.pieces[index];
        Some((index, (at - piece.start).min(piece.text.len())))
    }

    /// The word around `at` (a double click), as Unicode word bounds find it.
    pub fn word(&self, at: usize) -> Range<usize> {
        let Some((index, local)) = self.locate(at) else {
            return at..at;
        };
        let piece = &self.pieces[index];
        if !matches!(piece.kind, Kind::Text) {
            return piece.range();
        }
        use unicode_segmentation::UnicodeSegmentation;
        let mut start = 0;
        for word in piece.text.split_word_bounds() {
            let end = start + word.len();
            if local < end || end == piece.text.len() {
                return piece.start + start..piece.start + end;
            }
            start = end;
        }
        at..at
    }

    /// The paragraph around `at` (a triple click), its marker included.
    pub fn paragraph(&self, at: usize) -> Range<usize> {
        let Some((index, _)) = self.locate(at) else {
            return at..at;
        };
        let paragraph = &self.paragraphs[self.pieces[index].paragraph];
        paragraph.start..paragraph.end
    }
}

/// The nearest char boundary at or before `at`.
fn floor(text: &str, at: usize) -> usize {
    let mut at = at.min(text.len());
    while !text.is_char_boundary(at) {
        at -= 1;
    }
    at
}

/// Swift's quoting (`WorkspaceModel.openQuotedSide`): each line of the
/// selection after "> ", and a blank line after it, below any draft.
pub(super) fn quoted_draft(existing: &str, quote: &str) -> String {
    let quoted = quote
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .split('\n')
        .map(|line| format!("> {line}"))
        .collect::<Vec<_>>()
        .join("\n");
    let mut draft = existing.to_owned();
    if !draft.is_empty() {
        draft.push_str("\n\n");
    }
    draft.push_str(&quoted);
    draft.push_str("\n\n");
    draft
}

#[cfg(test)]
#[path = "transcript_selection_tests.rs"]
mod tests;
