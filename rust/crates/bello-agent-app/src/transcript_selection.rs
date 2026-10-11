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

/// A plain text (a message the reader sent) as one piece.
impl ReplyText {
    pub fn plain(owner: &str, text: &str) -> Self {
        let owner = SharedString::from(owner.to_owned());
        let mut reply = Self {
            pieces: vec![Piece {
                owner: owner.clone(),
                text: text.to_owned(),
                kind: Kind::Text,
                start: 0,
                paragraph: 0,
            }],
            paragraphs: vec![Paragraph {
                pieces: 0..1,
                break_copy: String::new(),
                chrome: false,
                start: 0,
                end: text.len(),
            }],
            owners: HashMap::new(),
            len: text.len(),
        };
        reply.owners.insert(owner, 0);
        reply
    }

    /// Whether `other` reads the same as this text up to `upto`: a reply
    /// that grew keeps a selection in what it already said.
    pub fn same_through(&self, other: &Self, upto: usize) -> bool {
        if upto > self.len || upto > other.len {
            return false;
        }
        for (mine, theirs) in self.pieces.iter().zip(&other.pieces) {
            if mine.start >= upto {
                return true;
            }
            if mine.start != theirs.start || mine.owner != theirs.owner || mine.kind != theirs.kind {
                return false;
            }
            let end = (upto - mine.start).min(mine.text.len());
            if theirs.text.len() < end || mine.text.as_bytes()[..end] != theirs.text.as_bytes()[..end]
            {
                return false;
            }
            if mine.range().end >= upto {
                return true;
            }
        }
        self.pieces.len() <= other.pieces.len()
    }
}

/// What a reply's text is made from, its text built only once something
/// needs it (a press in it, or a selection to draw).
pub(super) struct Source {
    blocks: Option<std::rc::Rc<Vec<Block>>>,
    plain: Option<String>,
    owner: SharedString,
    built: std::cell::OnceCell<std::rc::Rc<ReplyText>>,
}

impl Source {
    pub fn markdown(owner: SharedString, blocks: std::rc::Rc<Vec<Block>>) -> Self {
        Self {
            blocks: Some(blocks),
            plain: None,
            owner,
            built: std::cell::OnceCell::new(),
        }
    }
    pub fn plain(owner: SharedString, text: String) -> Self {
        Self {
            blocks: None,
            plain: Some(text),
            owner,
            built: std::cell::OnceCell::new(),
        }
    }
    pub fn owner(&self) -> &SharedString {
        &self.owner
    }
    pub fn text(&self) -> std::rc::Rc<ReplyText> {
        self.built
            .get_or_init(|| {
                std::rc::Rc::new(match (&self.blocks, &self.plain) {
                    (Some(blocks), _) => ReplyText::new(blocks, &self.owner),
                    (_, Some(plain)) => ReplyText::plain(&self.owner, plain),
                    _ => ReplyText::default(),
                })
            })
            .clone()
    }
}

/// How far a press reaches as the pointer drags: characters, or (after a
/// double or triple click) whole words or paragraphs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Unit {
    Character,
    Word,
    Paragraph,
}

/// The selection: one reply's, as one text view holds one in Swift.
#[derive(Clone)]
pub(super) struct Selected {
    /// The reply's text owner.
    pub reply: SharedString,
    /// The message it belongs to, and whether a quote can be made of it.
    pub message: String,
    pub quotable: bool,
    pub text: std::rc::Rc<ReplyText>,
    /// What the press took (a point, a word or a paragraph).
    pub anchor: Range<usize>,
    pub focus: usize,
    pub unit: Unit,
}

impl Selected {
    fn unit_at(&self, at: usize) -> Range<usize> {
        match self.unit {
            Unit::Character => at..at,
            Unit::Word => self.text.word(at),
            Unit::Paragraph => self.text.paragraph(at),
        }
    }
    pub fn range(&self) -> Range<usize> {
        let focus = self.unit_at(self.focus);
        self.anchor.start.min(focus.start)..self.anchor.end.max(focus.end)
    }
    pub fn copy(&self) -> String {
        self.text.copy(self.range())
    }
}

/// The transcript's selection and what the last frame drew of it.
#[derive(Default)]
pub(super) struct SelectionHost {
    pub selected: Option<Selected>,
    /// A press is dragging the selection.
    pub dragging: bool,
    /// A piece of text took the press being dispatched.
    pub claimed: bool,
    /// The quote bar is up over the selection.
    pub bar: bool,
    /// The transcript's focus: a press in its text takes it, so the
    /// selection's commands (Copy, Select All) reach the transcript.
    pub focus: Option<gpui::FocusHandle>,
    /// The frame being painted, and its selectable text.
    pub frame: u64,
    pub regions: Vec<std::rc::Rc<Region>>,
    /// The selection's rows as this frame painted them, in window space.
    pub painted: Vec<gpui::Bounds<gpui::Pixels>>,
}

/// One text element as painted: what it holds of which reply's text.
pub(super) struct Region {
    pub reply: SharedString,
    pub message: String,
    pub quotable: bool,
    pub source: std::rc::Rc<Source>,
    pub owner: SharedString,
    pub base: usize,
    pub bounds: gpui::Bounds<gpui::Pixels>,
    /// The element's local byte nearest a point, the element's own length.
    pub closest: std::rc::Rc<dyn Fn(gpui::Point<gpui::Pixels>) -> usize>,
}

impl Region {
    /// The reply's offset nearest `point`.
    pub fn offset(&self, point: gpui::Point<gpui::Pixels>) -> Option<usize> {
        let text = self.source.text();
        let piece = &text.pieces[text.piece(&self.owner)?];
        Some(match piece.kind {
            Kind::Text => piece.start + (self.base + (self.closest)(point)).min(piece.text.len()),
            Kind::Marker(_) => {
                if point.x < self.bounds.center().x {
                    piece.start
                } else {
                    piece.range().end
                }
            }
        })
    }
    fn distance(&self, point: gpui::Point<gpui::Pixels>) -> (f32, f32) {
        let gap = |value: gpui::Pixels, low: gpui::Pixels, high: gpui::Pixels| {
            f32::from(if value < low {
                low - value
            } else if value > high {
                value - high
            } else {
                gpui::Pixels::ZERO
            })
        };
        (
            gap(point.y, self.bounds.top(), self.bounds.bottom()),
            gap(point.x, self.bounds.left(), self.bounds.right()),
        )
    }
}

impl SelectionHost {
    pub fn begin_frame(&mut self, frame: u64) {
        if frame != self.frame {
            self.frame = frame;
            self.regions.clear();
            self.painted.clear();
        }
    }

    /// The range selected in the reply `reply`, if it is the selected one.
    pub fn range_in(&self, reply: &str) -> Option<Range<usize>> {
        self.selected
            .as_ref()
            .filter(|selected| selected.reply == reply)
            .map(Selected::range)
            .filter(|range| !range.is_empty())
    }

    /// The reply's text changed: a selection in what it already said stays,
    /// any other goes.
    pub fn follow(&mut self, reply: &str, text: &std::rc::Rc<ReplyText>) {
        let Some(selected) = self.selected.as_mut().filter(|selected| selected.reply == reply)
        else {
            return;
        };
        if std::rc::Rc::ptr_eq(&selected.text, text) {
            return;
        }
        let end = selected.range().end.max(selected.focus);
        if selected.text.same_through(text, end) {
            selected.text = text.clone();
        } else {
            self.selected = None;
            self.bar = false;
        }
    }

    /// A press in `region` at `point`.
    pub fn press(&mut self, region: &Region, point: gpui::Point<gpui::Pixels>, clicks: usize, extend: bool) {
        self.claimed = true;
        self.bar = false;
        let text = region.source.text();
        let Some(at) = region.offset(point) else {
            return;
        };
        if extend
            && let Some(selected) = self
                .selected
                .as_mut()
                .filter(|selected| selected.reply == region.reply)
        {
            selected.focus = at;
            self.dragging = true;
            return;
        }
        let unit = match clicks {
            0 | 1 => Unit::Character,
            2 => Unit::Word,
            _ => Unit::Paragraph,
        };
        let mut selected = Selected {
            reply: region.reply.clone(),
            message: region.message.clone(),
            quotable: region.quotable,
            text,
            anchor: at..at,
            focus: at,
            unit,
        };
        selected.anchor = selected.unit_at(at);
        self.selected = Some(selected);
        self.dragging = true;
    }

    /// The pointer dragged to `point`: the nearest of the selected reply's
    /// painted text takes the selection's end. Whether it changed.
    pub fn drag(&mut self, point: gpui::Point<gpui::Pixels>) -> bool {
        let Some(selected) = self.selected.as_mut() else {
            return false;
        };
        let nearest = self
            .regions
            .iter()
            .filter(|region| region.reply == selected.reply)
            .min_by(|a, b| {
                a.distance(point)
                    .partial_cmp(&b.distance(point))
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
        let Some(at) = nearest.and_then(|region| {
            // Above or below the text, a drag takes the line's start or end.
            let clamped = gpui::point(
                point.x,
                point.y.clamp(region.bounds.top(), region.bounds.bottom() - gpui::px(0.5)),
            );
            region.offset(clamped)
        }) else {
            return false;
        };
        let before = selected.range();
        selected.focus = at;
        before != selected.range()
    }

    /// The selection's text as a copy gives it.
    pub fn copy(&self) -> Option<String> {
        let selected = self.selected.as_ref()?;
        let range = selected.range();
        (!range.is_empty()).then(|| selected.copy())
    }

    /// Select All: every word of the reply the selection is in.
    pub fn select_all(&mut self) -> bool {
        let Some(selected) = self.selected.as_mut() else {
            return false;
        };
        selected.unit = Unit::Character;
        selected.anchor = 0..0;
        selected.focus = selected.text.len;
        self.bar = false;
        true
    }

    /// The quote bar can stand over the selection.
    pub fn quotable(&self) -> Option<(String, String)> {
        let selected = self.selected.as_ref().filter(|selected| selected.quotable)?;
        let text = self.copy()?;
        (!text.trim().is_empty()).then(|| (selected.message.clone(), text))
    }
}

/// The transcript's own listeners for its selection, registered before its
/// rows so that theirs run first: a press no text took ends the selection, a
/// drag extends it, a release puts the quote bar up, a scroll takes it down
/// (as Swift's `TranscriptQuoteSelectionController` does).
pub(super) fn listen(host: &std::rc::Rc<std::cell::RefCell<SelectionHost>>, window: &mut gpui::Window) {
    use gpui::{DispatchPhase, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, ScrollWheelEvent};
    let view = window.current_view();
    let press = host.clone();
    window.on_mouse_event(move |event: &MouseDownEvent, phase, _, cx| {
        if phase != DispatchPhase::Bubble || event.button != MouseButton::Left {
            return;
        }
        let mut host = press.borrow_mut();
        if !std::mem::take(&mut host.claimed) && (host.selected.is_some() || host.bar) {
            host.selected = None;
            host.bar = false;
            host.dragging = false;
            cx.notify(view);
        }
    });
    let drag = host.clone();
    window.on_mouse_event(move |event: &MouseMoveEvent, phase, _, cx| {
        if phase != DispatchPhase::Bubble {
            return;
        }
        let mut host = drag.borrow_mut();
        if !host.dragging {
            return;
        }
        if event.pressed_button != Some(MouseButton::Left) {
            host.dragging = false;
            return;
        }
        if host.drag(event.position) {
            cx.notify(view);
        }
    });
    let release = host.clone();
    window.on_mouse_event(move |event: &MouseUpEvent, phase, _, cx| {
        if phase != DispatchPhase::Bubble || event.button != MouseButton::Left {
            return;
        }
        let mut host = release.borrow_mut();
        if std::mem::take(&mut host.dragging) {
            host.bar = host.quotable().is_some();
            cx.notify(view);
        }
    });
    let scroll = host.clone();
    window.on_mouse_event(move |_: &ScrollWheelEvent, phase, _, cx| {
        if phase == DispatchPhase::Capture && std::mem::take(&mut scroll.borrow_mut().bar) {
            cx.notify(view);
        }
    });
}

#[cfg(test)]
#[path = "transcript_selection_tests.rs"]
mod tests;
