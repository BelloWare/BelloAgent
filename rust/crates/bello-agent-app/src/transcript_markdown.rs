//! A reply's Markdown as Swift 0.1.122 lays it out in one TextKit text
//! (`MarkdownTextDocument`). Each paragraph's lines are as tall as its opening
//! face's natural line (at least the body's), rounded up, with 0.35 of the
//! body size below each; blocks are 10 pt apart, 6 inside items and quotes, 4
//! between list items and 6 more above a heading, where the spacing TextKit
//! leaves below a paragraph's last line counts toward the gap. Prose ends 640
//! pt from the reply's leading edge; code and tables run its full width. Code
//! sits on a rounded panel with 31 pt above it (where the language and Copy
//! appear under the pointer) and 10 below, in the system monospaced face at
//! 0.86 of the body, coloured as Swift colours it. Markers sit right-aligned
//! in a column of at least 16 pt with 8 before the text; quotes have a 3 pt
//! bar and a 12 pt gap. Text is drawn through the shaped-text cache, so
//! unchanged blocks are not shaped again.
//!
//! GPUI shapes one text at one size, so a code span keeps its paragraph's size
//! (Swift draws it at 0.9×) in the monospaced face on the code background.
use super::shaped_text::{self, ShapeCache, Styled};
use crate::Palette;
use bello_agent_core::markdown::{Alignment, Block, Span, Style};
use bello_agent_core::syntax::{TokenKind, fence_tokens};
use gpui::{
    AnyElement, App, Div, Font, FontFeatures, FontStyle, FontWeight, InteractiveElement,
    IntoElement, ParentElement, SharedString, StatefulInteractiveElement, StrikethroughStyle,
    Styled as _, TextAlign, TextRun, Window, div, px, rgb, rgba, svg,
};
use std::{cell::RefCell, rc::Rc};

const BLOCK_GAP: f32 = 10.;
const ITEM_GAP: f32 = 4.;
const INNER_GAP: f32 = 6.;
const HEADING_TOP: f32 = 6.;
const CODE_TOP: f32 = 31.;
const CODE_BOTTOM: f32 = 10.;
const CODE_INSET: f32 = 14.;
const TABLE_PAD: f32 = 2.;
const LIST_LEADING: f32 = 4.;
const MARKER_WIDTH: f32 = 16.;
const MARKER_GAP: f32 = 8.;
const QUOTE_BAR: f32 = 3.;
const QUOTE_GAP: f32 = 12.;
/// Swift's `TranscriptMetrics.proseWidth`: where a reply's prose lines end.
pub(super) const PROSE_WIDTH: f32 = 640.;

#[derive(Clone, Copy, PartialEq)]
enum Face {
    Sans,
    Mono,
    Serif,
}

fn family(face: Face) -> &'static str {
    match (face, cfg!(target_os = "macos")) {
        (Face::Sans, true) => ".SystemUIFont",
        // `NSFont.monospacedSystemFont` (SF Mono) and the system serif
        // design (New York), by their system family names.
        (Face::Mono, true) => ".AppleSystemUIFontMonospaced",
        (Face::Serif, true) => ".AppleSystemUIFontSerif",
        (Face::Sans, false) => "DejaVu Sans",
        (Face::Mono, false) => "DejaVu Sans Mono",
        (Face::Serif, false) => "DejaVu Serif",
    }
}

fn font(face: Face, bold: bool, italic: bool) -> Font {
    Font {
        family: family(face).into(),
        features: FontFeatures::default(),
        fallbacks: None,
        weight: if bold {
            FontWeight::SEMIBOLD
        } else {
            FontWeight::NORMAL
        },
        style: if italic {
            FontStyle::Italic
        } else {
            FontStyle::Normal
        },
    }
}

fn span_face(span: &Span) -> Face {
    if span.mono {
        Face::Mono
    } else if span.serif {
        Face::Serif
    } else {
        Face::Sans
    }
}

fn span_font(span: &Span) -> Font {
    font(span_face(span), span.bold, span.italic)
}

/// The faces' ascent and descent per point: SF and SF Mono (1980 and 432 of
/// 2048 units) and New York (1950 and 494). Lines are measured by these on
/// every platform, so a reply is as tall as Swift's on the Mac whatever face
/// draws it, and the transcript's estimates can match it.
fn metrics(face: Face, size: f32) -> (f32, f32) {
    let (ascent, descent) = match face {
        Face::Sans | Face::Mono => (1980., 432.),
        Face::Serif => (1950., 494.),
    };
    (size * ascent / 2048., size * descent / 2048.)
}

/// Swift's `MarkdownTextLayout.lineHeight`: a face's natural line, rounded
/// up to a whole point.
fn natural_line(face: Face, size: f32) -> f32 {
    let (ascent, descent) = metrics(face, size);
    (ascent + descent).ceil()
}

/// TextKit's own line for a paragraph that sets no height: the face's
/// ascent and descent, each rounded.
fn textkit_line(face: Face, size: f32) -> f32 {
    let (ascent, descent) = metrics(face, size);
    ascent.round() + descent.round()
}

/// A reply's body line and the spacing below it: 18 and 5.075 at 14.5 pt.
pub(super) fn body_line(style: Style) -> (f32, f32) {
    (
        natural_line(Face::Sans, style.base_size),
        style.base_size * 0.35,
    )
}

/// What a reply's Markdown is drawn with.
pub(super) struct Context<'a> {
    pub cache: &'a Rc<RefCell<ShapeCache>>,
    /// Unique within the transcript: the row's text owner.
    pub owner: &'a str,
    pub palette: Palette,
    /// For the width of a list's numbers.
    pub window: &'a Window,
    /// Swift's `capsWidth`: prose lines end this far from the leading edge.
    pub prose_width: Option<f32>,
    /// The fence whose Copy was just pressed, by its key.
    pub copied: Option<SharedString>,
    /// Copies a fence's code and marks it copied, by its key.
    pub on_copy: CopyCode,
}

/// A fence's Copy: its key and code.
pub(super) type CopyCode = Rc<dyn Fn(SharedString, &str, &mut App)>;

/// A block's slot in a reply's column (its gap above and itself), top and
/// bottom from the column's top, where it was last drawn.
pub(super) type Slot = Option<(f32, f32)>;

impl Context<'_> {
    fn color(&self, light: u32, dark: u32) -> gpui::Hsla {
        rgb(if self.palette.dark { dark } else { light }).into()
    }
    fn alpha(&self, light: u32, dark: u32) -> gpui::Hsla {
        rgba(if self.palette.dark { dark } else { light }).into()
    }
    fn ink(&self) -> gpui::Hsla {
        rgb(self.palette.ink).into()
    }
    fn muted(&self) -> gpui::Hsla {
        self.color(0x6e6a61, 0xa9a59b)
    }
    fn faint(&self) -> gpui::Hsla {
        self.color(0x9b968c, 0x78746b)
    }
    fn hair(&self) -> gpui::Hsla {
        self.alpha(0x00000014, 0xffffff17)
    }
    fn hair_strong(&self) -> gpui::Hsla {
        self.alpha(0x00000024, 0xffffff29)
    }
    /// Swift's `panelStrong`: a code span's background, a button's hover.
    fn panel_strong(&self) -> gpui::Hsla {
        self.alpha(0x0000000f, 0xffffff14)
    }
    /// Swift's `codeBackground`: a fence's panel.
    fn code_panel(&self) -> gpui::Hsla {
        self.color(0xf6f1ea, 0x211d1a)
    }
    fn accent(&self) -> gpui::Hsla {
        rgb(self.palette.accent).into()
    }
}

/// How a block's text sits among the blocks around it, as Swift's
/// `MarkdownTextParagraph` sets its first and last paragraphs.
#[derive(Clone, Copy, Default)]
struct Edges {
    /// Room inside the block above its first line and below its last (a
    /// fence's panel).
    top_pad: f32,
    bottom_pad: f32,
    /// The spacing TextKit leaves below the block's last line.
    spacing: f32,
    /// Room a table keeps above and below itself.
    before: f32,
    after: f32,
}

struct Part {
    element: AnyElement,
    edges: Edges,
}

/// From one block's edge to the next's: Swift's paragraph spacing
/// (`MarkdownTextAssembler.spacing`) less what TextKit already leaves below
/// the previous paragraph's last line and the pads inside the two blocks.
fn between(previous: Edges, next: Edges, gap: f32) -> f32 {
    (previous.spacing - previous.bottom_pad - next.top_pad).max(gap + previous.after + next.before)
}

/// A run of blocks: the first one's head and the last one's tail.
fn joined(first: Option<Edges>, last: Option<Edges>) -> Edges {
    let (first, last) = (first.unwrap_or_default(), last.unwrap_or_default());
    Edges {
        top_pad: first.top_pad,
        before: first.before,
        bottom_pad: last.bottom_pad,
        spacing: last.spacing,
        after: last.after,
    }
}

/// Parts stacked with Swift's spacing: each with the gap it is given (the
/// first part's is the column's own, given by its parent).
fn stack(parts: Vec<(Part, f32)>) -> Part {
    let mut column = div().flex().flex_col().min_w_0().w_full();
    let mut first: Option<Edges> = None;
    let mut last: Option<Edges> = None;
    for (part, gap) in parts {
        let top = last.map_or(0., |previous| between(previous, part.edges, gap));
        first.get_or_insert(part.edges);
        last = Some(part.edges);
        column = column.child(div().pt(px(top)).min_w_0().w_full().child(part.element));
    }
    Part {
        element: column.into_any_element(),
        edges: joined(first, last),
    }
}

/// An item that opens with a fence, a table or nothing has its marker on a
/// line of its own, its blocks below it.
fn marker_on_own_line(item: &[Block]) -> bool {
    !matches!(
        item.first(),
        Some(Block::Paragraph(_) | Block::Heading { .. } | Block::List { .. } | Block::Quote(_))
    )
}

/// A block's edges, as `block_part` draws it, without drawing it.
fn edges(block: &Block, style: Style) -> Edges {
    let (_, spacing) = body_line(style);
    match block {
        Block::Paragraph(_) => Edges {
            spacing,
            ..Edges::default()
        },
        // Whatever gap a heading is given, it takes 6 more.
        Block::Heading { .. } => Edges {
            spacing,
            before: HEADING_TOP,
            ..Edges::default()
        },
        Block::Code { .. } => Edges {
            top_pad: CODE_TOP,
            bottom_pad: CODE_BOTTOM,
            spacing: style.base_size * 0.86 * 0.4,
            ..Edges::default()
        },
        Block::Table { .. } => Edges {
            before: TABLE_PAD,
            after: TABLE_PAD,
            ..Edges::default()
        },
        Block::Quote(blocks) => joined(
            blocks.first().map(|block| edges(block, style)),
            blocks.last().map(|block| edges(block, style)),
        ),
        Block::List { items, .. } => {
            let marker = Edges {
                spacing,
                ..Edges::default()
            };
            joined(
                items.first().map(|item| {
                    if marker_on_own_line(item) {
                        marker
                    } else {
                        edges(&item[0], style)
                    }
                }),
                items
                    .last()
                    .map(|item| item.last().map_or(marker, |block| edges(block, style))),
            )
        }
    }
}

/// Where a reply's top-level blocks were last drawn, and the part of the
/// reply on screen.
pub(super) struct Placement<'a> {
    /// Each block's slot (its gap above and itself), top and bottom from the
    /// column's top, where it was last drawn and is unchanged since.
    pub slots: &'a [Slot],
    /// The column's part on screen or near it: blocks with a slot outside it
    /// are drawn as one spacer of their height. None draws every block.
    pub visible: Option<std::ops::Range<f32>>,
}

/// One child of a reply's column: a block, or a spacer standing in for
/// blocks off screen.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Child {
    Block(usize),
    Spacer,
}

/// The reply's blocks as one column, and what each of its children is. A
/// long reply costs what is on screen: GPUI lays out a list row whole, so
/// blocks far from the viewport stand aside as spacers of the height they
/// were last drawn at.
pub(super) fn render(
    blocks: &[Block],
    style: Style,
    cx: &Context,
    placement: &Placement,
) -> (Div, Vec<Child>) {
    let mut column = div().flex().flex_col().min_w_0().w_full();
    let mut children = Vec::new();
    let mut hidden: Option<(f32, f32)> = None;
    let mut previous: Option<Edges> = None;
    for (index, block) in blocks.iter().enumerate() {
        let block_edges = edges(block, style);
        let slot = placement.slots.get(index).copied().flatten();
        let off_screen = placement
            .visible
            .as_ref()
            .zip(slot)
            .is_some_and(|(visible, (top, bottom))| bottom <= visible.start || top >= visible.end);
        if let (true, Some((top, bottom))) = (off_screen, slot) {
            hidden = Some(hidden.map_or((top, bottom), |(start, _)| (start, bottom)));
        } else {
            if let Some((start, end)) = hidden.take() {
                column = column.child(div().flex_none().h(px(end - start)));
                children.push(Child::Spacer);
            }
            let top = previous.map_or(0., |previous| between(previous, block_edges, BLOCK_GAP));
            column =
                column.child(div().pt(px(top)).min_w_0().w_full().child(
                    block_part(block, style, cx, &format!(".{index}"), cx.prose_width).element,
                ));
            children.push(Child::Block(index));
        }
        previous = Some(block_edges);
    }
    if let Some((start, end)) = hidden {
        column = column.child(div().flex_none().h(px(end - start)));
        children.push(Child::Spacer);
    }
    (column, children)
}

fn column(
    blocks: &[Block],
    style: Style,
    cx: &Context,
    path: &str,
    gap: f32,
    width: Option<f32>,
) -> Part {
    stack(
        blocks
            .iter()
            .enumerate()
            .map(|(index, block)| {
                (
                    block_part(block, style, cx, &format!("{path}.{index}"), width),
                    gap,
                )
            })
            .collect(),
    )
}

fn block_part(block: &Block, style: Style, cx: &Context, path: &str, width: Option<f32>) -> Part {
    Part {
        element: block_element(block, style, cx, path, width),
        edges: edges(block, style),
    }
}

fn block_element(
    block: &Block,
    style: Style,
    cx: &Context,
    path: &str,
    width: Option<f32>,
) -> AnyElement {
    match block {
        Block::Paragraph(spans) => prose(spans, style.base_size, style, cx, path, width).element,
        Block::Heading { level, spans, .. } => {
            let size = style.base_size
                * match level {
                    1 => 1.5,
                    2 => 1.3,
                    3 => 1.12,
                    _ => 1.,
                };
            prose(spans, size, style, cx, path, width).element
        }
        Block::Code { language, code } => {
            code_block(language.as_deref(), code, style, cx, path).element
        }
        Block::List {
            ordered,
            start,
            items,
        } => list(*ordered, *start, items, style, cx, path, width).element,
        Block::Quote(blocks) => {
            let inner = column(
                blocks,
                style,
                cx,
                path,
                INNER_GAP,
                width.map(|width| width - QUOTE_BAR - QUOTE_GAP),
            );
            div()
                .flex()
                .flex_row()
                .min_w_0()
                .child(
                    div()
                        .flex_none()
                        .w(px(QUOTE_BAR))
                        .rounded(px(1.5))
                        .bg(cx.hair_strong()),
                )
                .child(div().flex_none().w(px(QUOTE_GAP)))
                .child(div().flex_1().min_w_0().child(inner.element))
                .into_any_element()
        }
        Block::Table {
            alignments,
            header,
            rows,
        } => table(alignments, header, rows, style, cx, path).element,
    }
}

/// A line as a paragraph style sets it: its height and the spacing below it.
#[derive(Clone, Copy)]
struct Line {
    height: f32,
    spacing: f32,
}

/// A prose paragraph's line: as tall as its opening run's natural line (in
/// the face and size Swift gives that run) and at least the body's, with
/// 0.35 of the body size below it.
fn prose_line(spans: &[Span], style: Style) -> Line {
    let (body, spacing) = body_line(style);
    let opening = spans
        .first()
        .map_or(body, |span| natural_line(span_face(span), span.size));
    Line {
        height: opening.max(body),
        spacing,
    }
}

fn prose(
    spans: &[Span],
    size: f32,
    style: Style,
    cx: &Context,
    path: &str,
    width: Option<f32>,
) -> Part {
    let line = prose_line(spans, style);
    let element = text(spans, size, line, cx, path);
    Part {
        element: match width {
            Some(width) => div()
                .min_w_0()
                .max_w(px(width))
                .child(element)
                .into_any_element(),
            None => element,
        },
        edges: Edges {
            spacing: line.spacing,
            ..Edges::default()
        },
    }
}

fn run(span: &Span, cx: &Context) -> TextRun {
    TextRun {
        len: span.text.len(),
        font: span_font(span),
        color: if span.link.is_some() {
            cx.accent()
        } else {
            cx.ink()
        },
        background_color: span.code.then(|| cx.panel_strong()),
        underline: None,
        strikethrough: span.strike.then_some(StrikethroughStyle {
            thickness: px(1.),
            color: None,
        }),
    }
}

fn text(spans: &[Span], size: f32, line: Line, cx: &Context, path: &str) -> AnyElement {
    let joined: String = spans.iter().map(|span| span.text.as_str()).collect();
    let runs = spans.iter().map(|span| run(span, cx)).collect();
    shaped_text::styled_text(
        cx.cache,
        SharedString::from(format!("{}{path}", cx.owner)),
        joined.into(),
        Styled {
            runs,
            font_size: px(size),
            line_height: px(line.height),
            line_spacing: px(line.spacing),
            last: true,
        },
    )
    .into_any_element()
}

fn list(
    ordered: bool,
    start: u64,
    items: &[Vec<Block>],
    style: Style,
    cx: &Context,
    path: &str,
    width: Option<f32>,
) -> Part {
    let marker_font = font(Face::Sans, false, false);
    // Swift's `markerColumn`: the last number and a row of eights, as wide
    // as the wider of them, and never under 16 pt.
    let column_width = if ordered && !items.is_empty() {
        let last = start + items.len() as u64 - 1;
        let measure = |text: String| {
            let len = text.len();
            f32::from(
                cx.window
                    .text_system()
                    .shape_line(
                        text.into(),
                        px(style.base_size),
                        &[TextRun {
                            len,
                            font: marker_font.clone(),
                            color: cx.ink(),
                            background_color: None,
                            underline: None,
                            strikethrough: None,
                        }],
                        None,
                    )
                    .width,
            )
        };
        let digits = start.max(last).to_string().len();
        MARKER_WIDTH.max(
            measure(format!("{last}."))
                .max(measure("8".repeat(digits) + "."))
                .ceil(),
        )
    } else {
        MARKER_WIDTH
    };
    let indent = LIST_LEADING + column_width + MARKER_GAP;
    let (height, spacing) = body_line(style);
    let marker_line = Line { height, spacing };
    let rows = items
        .iter()
        .enumerate()
        .map(|(index, item)| {
            let marker = if ordered {
                format!("{}.", start + index as u64)
            } else {
                "•".to_owned()
            };
            let marker_span = Span {
                text: marker,
                size: style.base_size,
                bold: false,
                italic: false,
                mono: false,
                serif: false,
                code: false,
                strike: false,
                link: None,
            };
            let marker_text = text(
                std::slice::from_ref(&marker_span),
                style.base_size,
                marker_line,
                cx,
                &format!("{path}.{index}m"),
            );
            let item_path = format!("{path}.{index}");
            let inner_width = width.map(|width| width - indent);
            let mut parts = Vec::new();
            if marker_on_own_line(item) {
                parts.push((
                    Part {
                        element: div().h(px(marker_line.height)).into_any_element(),
                        edges: Edges {
                            spacing: marker_line.spacing,
                            ..Edges::default()
                        },
                    },
                    0.,
                ));
            }
            for (block_index, block) in item.iter().enumerate() {
                let part = block_part(
                    block,
                    style,
                    cx,
                    &format!("{item_path}.{block_index}"),
                    inner_width,
                );
                parts.push((part, INNER_GAP));
            }
            let body = stack(parts);
            (
                Part {
                    element: div()
                        .flex()
                        .flex_row()
                        .min_w_0()
                        .child(
                            div()
                                .flex_none()
                                .w(px(LIST_LEADING + column_width))
                                .text_align(TextAlign::Right)
                                .child(marker_text),
                        )
                        .child(div().flex_none().w(px(MARKER_GAP)))
                        .child(div().flex_1().min_w_0().child(body.element))
                        .into_any_element(),
                    edges: body.edges,
                },
                ITEM_GAP,
            )
        })
        .collect();
    stack(rows)
}

/// Swift's code colours (`TranscriptNSPalette`), light and dark.
fn token_color(kind: TokenKind, cx: &Context) -> gpui::Hsla {
    match kind {
        TokenKind::Keyword => cx.color(0x8a3fb0, 0xd7a5ee),
        TokenKind::String => cx.color(0x2f6b45, 0xa5d9b3),
        TokenKind::Number | TokenKind::Title => cx.color(0x2a5aa6, 0xa8c9fc),
        TokenKind::Comment => cx.color(0x7a766d, 0x9a968d),
    }
}

/// The fence's runs: plain code, and its tokens coloured (comments italic).
fn code_runs(code: &str, language: Option<&str>, cx: &Context) -> Vec<TextRun> {
    let plain = |len: usize| TextRun {
        len,
        font: font(Face::Mono, false, false),
        color: cx.ink(),
        background_color: None,
        underline: None,
        strikethrough: None,
    };
    let mut runs = Vec::new();
    let mut at = 0;
    for token in language.map_or_else(Vec::new, |language| fence_tokens(code, language)) {
        if token.range.start > at {
            runs.push(plain(token.range.start - at));
        }
        runs.push(TextRun {
            font: font(Face::Mono, false, token.kind == TokenKind::Comment),
            color: token_color(token.kind, cx),
            ..plain(token.range.len())
        });
        at = token.range.end;
    }
    if code.len() > at {
        runs.push(plain(code.len() - at));
    }
    runs
}

fn code_block(language: Option<&str>, code: &str, style: Style, cx: &Context, path: &str) -> Part {
    let size = style.base_size * 0.86;
    let line = Line {
        height: natural_line(Face::Mono, size),
        spacing: size * 0.4,
    };
    let key = SharedString::from(format!("{}{path}", cx.owner));
    let group = SharedString::from(format!("code{key}"));
    let copied = cx.copied.as_ref() == Some(&key);
    let lines = shaped_text::styled_lines(
        cx.cache,
        key.clone(),
        code,
        Styled {
            runs: code_runs(code, language, cx),
            font_size: px(size),
            line_height: px(line.height),
            line_spacing: px(line.spacing),
            last: true,
        },
    );
    // Swift's `TranscriptCopyButton` in the fence's toolbar: muted, the
    // text colour under the pointer, the accent once it has copied.
    let (tint, hover_tint) = if copied {
        (cx.accent(), cx.accent())
    } else {
        (cx.muted(), cx.ink())
    };
    let (stroke, hover_stroke) = if copied {
        let accent = gpui::Hsla {
            a: 0.4,
            ..cx.accent()
        };
        (accent, accent)
    } else {
        (gpui::transparent_black(), cx.hair_strong())
    };
    let hover_fill = cx.panel_strong();
    let on_copy = cx.on_copy.clone();
    let source = code.to_owned();
    let copy_key = key.clone();
    let button = div()
        .id(SharedString::from(format!("copy-code{key}")))
        .group(SharedString::from(format!("copy-code{key}")))
        .flex_none()
        .w(px(64.))
        .h(px(22.5))
        .rounded(px(5.))
        .bg(cx.code_panel())
        .border_1()
        .border_color(stroke)
        .flex()
        .flex_row()
        .items_center()
        .justify_center()
        .gap(px(4.))
        .text_size(px(10.5))
        .font_weight(FontWeight::MEDIUM)
        .text_color(tint)
        .cursor_pointer()
        .hover(move |button| {
            button
                .bg(hover_fill)
                .border_color(hover_stroke)
                .text_color(hover_tint)
        })
        .child(
            svg()
                .path(if copied { "checkmark" } else { "doc.on.doc" })
                .size(px(10.))
                .text_color(tint)
                .group_hover(format!("copy-code{key}"), move |icon| {
                    icon.text_color(hover_tint)
                }),
        )
        .child(if copied { "Copied" } else { "Copy" })
        .on_click(move |_, _, cx| on_copy(copy_key.clone(), &source, cx));
    let mut toolbar = div()
        .absolute()
        .top(px(5.))
        .right(px(8.))
        .h(px(20.))
        .flex()
        .flex_row()
        .items_center()
        .gap(px(6.))
        .invisible()
        .group_hover(group.clone(), |toolbar| toolbar.visible());
    if let Some(language) = language {
        toolbar = toolbar.child(
            div()
                .font_family(family(Face::Mono))
                .text_size(px(10.5))
                .font_weight(FontWeight::MEDIUM)
                .text_color(cx.faint())
                .child(language.to_lowercase()),
        );
    }
    // The panel's 1 pt hairline is inside its frame, as Swift strokes it;
    // the text keeps Swift's insets from the frame.
    let element = div()
        .group(group)
        .relative()
        .w_full()
        .min_w_0()
        .rounded(px(10.))
        .bg(cx.code_panel())
        .border_1()
        .border_color(cx.hair())
        .pt(px(CODE_TOP - 1.))
        .pb(px(CODE_BOTTOM - 1.))
        .px(px(CODE_INSET - 1.))
        .children(lines)
        .child(toolbar.child(button))
        .into_any_element();
    Part {
        element,
        edges: Edges {
            top_pad: CODE_TOP,
            bottom_pad: CODE_BOTTOM,
            spacing: line.spacing,
            ..Edges::default()
        },
    }
}

fn table(
    alignments: &[Alignment],
    header: &[Vec<Span>],
    rows: &[Vec<Vec<Span>>],
    style: Style,
    cx: &Context,
    path: &str,
) -> Part {
    let cell_size = style.base_size * 0.9;
    let columns = alignments.len().max(1);
    let row = |cells: &[Vec<Span>], header: bool, row_path: &str| {
        let mut line = div().flex().flex_row().min_w_0().w_full();
        for column in 0..columns {
            let align = match alignments.get(column) {
                Some(Alignment::Center) => TextAlign::Center,
                Some(Alignment::Right) => TextAlign::Right,
                _ => TextAlign::Left,
            };
            let mut spans = cells.get(column).cloned().unwrap_or_default();
            if header {
                for span in &mut spans {
                    span.bold = true;
                }
            }
            // A cell sets no line height: TextKit's own, with no spacing.
            let size = if header { 13. } else { cell_size };
            let opening = spans.first().map_or(Face::Sans, span_face);
            let cell_line = Line {
                height: textkit_line(opening, size),
                spacing: 0.,
            };
            line = line.child(
                div()
                    .flex_1()
                    .min_w_0()
                    .px(px(8.))
                    .py(px(4.))
                    .when_some_border(column > 0, cx.hair())
                    .text_align(align)
                    .child(text(
                        &spans,
                        size,
                        cell_line,
                        cx,
                        &format!("{row_path}.{column}"),
                    )),
            );
        }
        line
    };
    let mut grid = div()
        .flex()
        .flex_col()
        .min_w_0()
        .w_full()
        .rounded(px(4.))
        .border_1()
        .border_color(cx.hair())
        .child(row(header, true, &format!("{path}.h")));
    for (index, cells) in rows.iter().enumerate() {
        grid = grid.child(div().border_t_1().border_color(cx.hair()).child(row(
            cells,
            false,
            &format!("{path}.{index}"),
        )));
    }
    Part {
        element: grid.into_any_element(),
        edges: Edges {
            before: TABLE_PAD,
            after: TABLE_PAD,
            ..Edges::default()
        },
    }
}

trait CellBorder {
    fn when_some_border(self, on: bool, color: gpui::Hsla) -> Self;
}
impl CellBorder for Div {
    fn when_some_border(self, on: bool, color: gpui::Hsla) -> Self {
        if on {
            self.border_l_1().border_color(color)
        } else {
            self
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Edges, between};

    fn prose(spacing: f32) -> Edges {
        Edges {
            spacing,
            ..Edges::default()
        }
    }
    const CODE: Edges = Edges {
        top_pad: 31.,
        bottom_pad: 10.,
        spacing: 12.47 * 0.4,
        before: 0.,
        after: 0.,
    };
    const TABLE: Edges = Edges {
        top_pad: 0.,
        bottom_pad: 0.,
        spacing: 0.,
        before: 2.,
        after: 2.,
    };

    /// Swift's spacing (`max(0, gap + bottomPad + topPad - lineSpacing)` after
    /// a last line that keeps its spacing), measured between block edges.
    #[test]
    fn blocks_are_spaced_as_textkit_spaces_swifts_paragraphs() {
        let body = 14.5 * 0.35;
        // Paragraphs and headings: the gap, which is more than the spacing.
        assert_eq!(between(prose(body), prose(body), 10.), 10.);
        assert_eq!(between(prose(body), prose(body), 16.), 16.);
        // List items 4 apart: the spacing below a line is already more.
        assert_eq!(between(prose(body), prose(body), 4.), body);
        // A fence's panel sits 10 below text and text 10 below the panel.
        assert_eq!(between(prose(body), CODE, 10.), 10.);
        assert_eq!(between(CODE, prose(body), 10.), 10.);
        assert_eq!(between(CODE, CODE, 10.), 10.);
        // A table keeps 2 more above and below.
        assert_eq!(between(prose(body), TABLE, 10.), 12.);
        assert_eq!(between(TABLE, prose(body), 10.), 12.);
        assert_eq!(between(CODE, TABLE, 10.), 12.);
    }
}
