//! Swift 0.1.122's lines of a diff or a read (`TranscriptCardLines`, with
//! `TranscriptCardMetrics` and `TranscriptCardMoreLines`): each line's mark
//! — a diff's sign, a read's number ending at the right of its gutter —
//! before its text, a diff's added and removed lines tinted the card's whole
//! width, and a capped list's head and tail around the line that says how
//! many it is not showing.
//!
//! The texts are one selectable editor; its lines wrap where the editor
//! wraps them, so each mark and tint is placed by the same line wrapper.
use gpui::{
    AnyElement, Bounds, Hsla, InteractiveElement, IntoElement, ParentElement, Pixels, SharedString,
    StatefulInteractiveElement, Styled, Window, canvas, div, font, px,
};

/// How tall each of the editor's lines is (`TranscriptCardFaces.code`).
pub(super) const LINE_HEIGHT: f32 = 17.;
/// Lines of a diff or a read before the middle collapses.
pub(super) const MAX_LINES: usize = 12;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Style {
    Diff,
    Numbered,
}

impl Style {
    /// The mark's box: a diff's sign, a read's number gutter.
    pub(super) fn mark_width(self) -> f32 {
        match self {
            Self::Diff => 10.,
            Self::Numbered => 34.,
        }
    }
    /// Between the mark's box and the text.
    pub(super) fn gap(self) -> f32 {
        match self {
            Self::Diff => 8.,
            Self::Numbered => 12.,
        }
    }
    /// Where the text starts in the card: its 16-point side, the mark, the gap.
    pub(super) fn text_left(self) -> f32 {
        16. + self.mark_width() + self.gap()
    }
    fn mark_size(self) -> f32 {
        match self {
            Self::Diff => 12.,
            Self::Numbered => 11.5,
        }
    }
}

/// One line's mark and tint.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Mark {
    pub text: SharedString,
    pub color: Hsla,
    pub background: Option<Hsla>,
}

/// Lines in each piece of a long run: a run more than twice this long is
/// drawn a piece at a time.
pub(super) const PIECE: usize = 32;
/// The most pieces a run is named for; a longer run's pieces grow.
pub(super) const PIECES: usize = 256;

/// A run's pieces, by line index, from each line's editor rows: one piece
/// for a run of at most twice `PIECE` rows, else pieces of at least `PIECE`
/// rows (more for a run so long it would need over `PIECES`). A line is never
/// split, so one line that wraps very far is one piece.
pub(super) fn pieces(rows: &[usize]) -> Vec<std::ops::Range<usize>> {
    let total: usize = rows.iter().sum();
    if total <= 2 * PIECE || rows.len() < 2 {
        return std::iter::once(0..rows.len()).collect();
    }
    let target = PIECE.max(total.div_ceil(PIECES - 1));
    let (mut pieces, mut start, mut sum) = (Vec::new(), 0, 0);
    for (line, rows) in rows.iter().enumerate() {
        sum += rows;
        if sum >= target {
            pieces.push(start..line + 1);
            (start, sum) = (line + 1, 0);
        }
    }
    if start < rows.len() {
        pieces.push(start..rows.len());
    }
    pieces
}

/// The editor section a run's `k`th piece is: the run's own for the first,
/// "OUT#3" and so on after it.
pub(super) fn piece_label(run: &'static str, k: usize) -> &'static str {
    use std::sync::OnceLock;
    static LABELS: OnceLock<Vec<(&'static str, Vec<&'static str>)>> = OnceLock::new();
    if k == 0 {
        return run;
    }
    let labels = LABELS.get_or_init(|| {
        ["IN", "IN-tail", "OUT", "OUT-tail"]
            .into_iter()
            .map(|base| {
                let names = (0..PIECES)
                    .map(|k| &*Box::leak(format!("{base}#{k}").into_boxed_str()))
                    .collect();
                (base, names)
            })
            .collect()
    });
    labels
        .iter()
        .find(|(base, _)| *base == run)
        .map_or(run, |(_, names)| names[k.min(PIECES - 1)])
}

/// The card section ("IN" or "OUT") an editor section belongs to.
pub(super) fn section_of(label: &str) -> &str {
    let label = label.split('#').next().unwrap_or(label);
    label.strip_suffix("-tail").unwrap_or(label)
}

/// `TranscriptCardMetrics.headTail`: how many lines are hidden, whether the
/// list caps at all, and how the shown lines divide.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct HeadTail {
    pub hidden: isize,
    pub capped: bool,
    pub head: usize,
    pub tail: usize,
}

pub(super) fn head_tail(total: usize, max_lines: usize, expanded: bool) -> HeadTail {
    let hidden = total as isize - max_lines as isize;
    let head = max_lines.div_ceil(2);
    HeadTail {
        hidden,
        capped: collapses(hidden) && !expanded,
        head,
        tail: max_lines - head,
    }
}

/// The runs of a list's lines a `head_tail` shows, by line index: the
/// head and the tail while capped, every line otherwise.
pub(super) fn runs(total: usize, cap: HeadTail) -> Vec<std::ops::Range<usize>> {
    if cap.capped {
        vec![0..cap.head, total - cap.tail..total]
    } else {
        std::iter::once(0..total).collect()
    }
}

/// `TranscriptCardMetrics.collapses`: a list one line over its cap is drawn
/// whole; the line saying "1 more" would take the room of the line it hides.
pub(super) fn collapses(hidden: isize) -> bool {
    hidden > 1
}

/// `TranscriptCardMetrics.moreLines`: "… 12 more lines", singular for one.
pub(super) fn more_lines(hidden: isize) -> String {
    format!("… {hidden} more line{}", if hidden == 1 { "" } else { "s" })
}

/// `transcriptNumber`: an integer grouped as the reader's locale groups it
/// (en: "9,000").
pub(super) fn number(value: usize) -> String {
    let digits = value.to_string();
    let mut grouped = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    grouped
}

/// How many of the editor's rows each line takes at `width`, wrapped as the
/// editor wraps it: its monospaced face, the line without its line ending.
pub(super) fn rows<'a>(
    family: &'static str,
    lines: impl IntoIterator<Item = &'a str>,
    width: f32,
    window: &Window,
) -> Vec<usize> {
    let mut wrapper = window.text_system().line_wrapper(font(family), px(12.));
    let width = width.max(1.).round();
    lines
        .into_iter()
        .map(|line| {
            let line = line.trim_end_matches(['\r', '\n']);
            1 + wrapper
                .wrap_line(&[gpui::LineFragment::text(line)], px(width))
                .filter(|boundary| boundary.ix > 0 && boundary.ix < line.len())
                .count()
        })
        .collect()
}

/// Which of the editor's rows of `line` (one line, without its ending)
/// holds byte `at`, wrapped at `width` as the editor wraps it.
pub(super) fn row_of(
    family: &'static str,
    line: &str,
    at: usize,
    width: f32,
    window: &Window,
) -> usize {
    let line = line.split('\n').next().unwrap_or("");
    let line = line.trim_end_matches(['\r', '\n']);
    let mut wrapper = window.text_system().line_wrapper(font(family), px(12.));
    wrapper
        .wrap_line(&[gpui::LineFragment::text(line)], px(width.max(1.).round()))
        .filter(|boundary| boundary.ix > 0 && boundary.ix < line.len() && boundary.ix <= at)
        .count()
}

/// The lines under their marks: the tints across the whole width, the marks
/// in their box, and the editor holding the texts at `text_left`.
pub(super) fn render(
    selector: String,
    style: Style,
    marks: &[Mark],
    rows: &[usize],
    editor: AnyElement,
    height: f32,
    placed: std::rc::Rc<std::cell::Cell<Option<Bounds<Pixels>>>>,
) -> impl IntoElement {
    let mut tints = div()
        .absolute()
        .top_0()
        .left_0()
        .right_0()
        .flex()
        .flex_col();
    let mut gutter = div()
        .absolute()
        .top_0()
        .left(px(16.))
        .w(px(style.mark_width()))
        .flex()
        .flex_col();
    for (mark, rows) in marks.iter().zip(rows) {
        let line = *rows as f32 * LINE_HEIGHT;
        tints = tints.child(
            div()
                .w_full()
                .h(px(line))
                .when_some(mark.background, |d, tint| d.bg(tint)),
        );
        gutter = gutter.child(
            div()
                .h(px(line))
                .w_full()
                .flex()
                // A number ends at the right of its gutter; a sign stands at
                // the left of its box.
                .when(style == Style::Numbered, |d| d.justify_end())
                .text_size(px(style.mark_size()))
                .line_height(px(LINE_HEIGHT))
                .text_color(mark.color)
                .whitespace_nowrap()
                .child(mark.text.clone()),
        );
    }
    let marks_selector = format!("{selector}-marks");
    div()
        .debug_selector(move || selector)
        .relative()
        .w_full()
        .h(px(height))
        // Where the block stands, so a find can land on one of its lines.
        .child(
            canvas(
                move |bounds, _, _| placed.set(Some(bounds)),
                |_, _, _, _| {},
            )
            .absolute()
            .size_full(),
        )
        .child(tints)
        .child(gutter.debug_selector(move || marks_selector))
        .child(
            div()
                .absolute()
                .top_0()
                .left(px(style.text_left()))
                .right(px(16.))
                .h(px(height))
                .child(editor),
        )
}

/// The middle of a capped list: how many lines it is not showing, or, while
/// it shows them all, the way back; a plain button the width of the card.
pub(super) fn more(
    id: String,
    label: String,
    color: Hsla,
    hover: Hsla,
    family: &'static str,
    toggle: impl Fn(&mut Window, &mut gpui::App) + 'static,
) -> impl IntoElement {
    div()
        .id(SharedString::from(id.clone()))
        .debug_selector(move || id)
        .w_full()
        .px(px(16.))
        .py(px(4.))
        .cursor_pointer()
        .font_family(family)
        .text_size(px(12.))
        .line_height(px(LINE_HEIGHT))
        .text_color(color)
        .hover(move |d| d.text_color(hover))
        .truncate()
        .child(label)
        .on_click(move |_, window, cx| toggle(window, cx))
}

use gpui::prelude::FluentBuilder;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_capped_list_splits_and_counts_as_swifts() {
        assert_eq!(
            head_tail(20, 12, false),
            HeadTail {
                hidden: 8,
                capped: true,
                head: 6,
                tail: 6
            }
        );
        // One over the cap is drawn whole.
        assert!(!head_tail(13, 12, false).capped);
        assert!(head_tail(14, 12, false).capped);
        assert!(!head_tail(20, 12, true).capped);
        assert_eq!(head_tail(3, 12, false).hidden, -9);
        assert_eq!(head_tail(20, 7, false).head, 4);
        assert_eq!(more_lines(1), "… 1 more line");
        assert_eq!(more_lines(8), "… 8 more lines");
        assert_eq!(number(7), "7");
        assert_eq!(number(999), "999");
        assert_eq!(number(9000), "9,000");
        assert_eq!(number(1234567), "1,234,567");
    }

    #[test]
    fn long_runs_split_by_their_wrapped_rows() {
        let whole = pieces(&[1; 64]);
        assert_eq!((whole.len(), whole[0].clone()), (1, 0..64));
        assert_eq!(pieces(&[1; 65]), [0..32, 32..64, 64..65]);
        // A line that wraps far fills its piece alone.
        assert_eq!(pieces(&[1, 40, 1, 1, 30, 1]), [0..2, 2..5, 5..6]);
        let many = pieces(&[1; 100_000]);
        assert!(many.len() <= PIECES);
        assert_eq!(many.last().unwrap().end, 100_000);
        assert!(many.windows(2).all(|w| w[0].end == w[1].start));
    }

    #[test]
    fn the_text_stands_past_the_mark_as_in_swifts_card() {
        assert_eq!(Style::Diff.text_left(), 34.);
        assert_eq!(Style::Numbered.text_left(), 62.);
    }
}
