//! Lines whose runs are set at more than one size, as TextKit sets a reply's
//! paragraph with a code span in it (Swift draws inline code at 0.9 of its
//! paragraph's size, on the paragraph's baseline). GPUI shapes and paints a
//! line at one size, so each stretch of one size is shaped on its own and
//! the stretches are laid end to end into one line layout; the line wraps as
//! `gpui::LineLayout` wraps (its rule is copied below) and each glyph is
//! painted at its own stretch's size.
use gpui::{
    App, Bounds, Hsla, LineLayout, Pixels, Point, ShapedGlyph, ShapedRun, StrikethroughStyle,
    TextAlign, TextRun, Window, WrapBoundary, WrappedLineLayout, point, px, size,
};
use smallvec::SmallVec;
use std::{ops::Range, sync::Arc};

/// One line of text in stretches of more than one size.
pub(super) struct Mixed {
    pub layout: WrappedLineLayout,
    /// Each of the layout's runs' size.
    sizes: Vec<Pixels>,
    /// The line's runs: colour, background and strikethrough by bytes.
    runs: Vec<TextRun>,
}

/// `text`'s lines (split at '\n'), shaped at `base` but for the byte ranges
/// of `scaled`, each at its own size; `runs` cover the whole text.
pub(super) fn shape(
    window: &Window,
    text: &str,
    base: Pixels,
    runs: &[TextRun],
    scaled: &[(Range<usize>, Pixels)],
    wrap_width: Option<Pixels>,
) -> Vec<Mixed> {
    let mut lines = Vec::new();
    let mut start = 0;
    for line in text.split('\n') {
        let range = start..start + line.len();
        let line_runs = within(runs, range.clone());
        // The line's stretches: [from, to) at a size.
        let mut cuts = vec![0, line.len()];
        for (bytes, _) in scaled {
            for cut in [bytes.start, bytes.end] {
                if cut > range.start && cut < range.end {
                    cuts.push(cut - range.start);
                }
            }
        }
        cuts.sort_unstable();
        cuts.dedup();
        let size_at = |at: usize| {
            scaled
                .iter()
                .find(|(bytes, _)| bytes.contains(&(range.start + at)))
                .map_or(base, |(_, size)| *size)
        };
        let mut merged = LineLayout {
            font_size: base,
            len: line.len(),
            ..LineLayout::default()
        };
        let mut sizes = Vec::new();
        for pair in cuts.windows(2) {
            let (from, to) = (pair[0], pair[1]);
            if from == to {
                continue;
            }
            let size = size_at(from);
            let stretch = window.text_system().layout_line(
                &line[from..to],
                size,
                &within(&line_runs, from..to),
                None,
            );
            let x = merged.width;
            for run in &stretch.runs {
                merged.runs.push(ShapedRun {
                    font_id: run.font_id,
                    glyphs: run
                        .glyphs
                        .iter()
                        .map(|glyph| ShapedGlyph {
                            id: glyph.id,
                            position: point(glyph.position.x + x, glyph.position.y),
                            index: glyph.index + from,
                            is_emoji: glyph.is_emoji,
                        })
                        .collect(),
                });
                sizes.push(size);
            }
            merged.width += stretch.width;
            merged.ascent = merged.ascent.max(stretch.ascent);
            merged.descent = merged.descent.max(stretch.descent);
        }
        let boundaries = wrap_width.map_or_else(SmallVec::new, |width| {
            wrap_boundaries(&merged, line, width)
        });
        lines.push(Mixed {
            layout: WrappedLineLayout {
                unwrapped_layout: Arc::new(merged),
                wrap_boundaries: boundaries,
                wrap_width,
            },
            sizes,
            runs: line_runs,
        });
        start = range.end + 1;
    }
    lines
}

/// The parts of `runs` (laid end to end from byte 0) in `range`.
fn within(runs: &[TextRun], range: Range<usize>) -> Vec<TextRun> {
    let mut out = Vec::new();
    let mut start = 0;
    for run in runs {
        let end = start + run.len;
        let overlap = end.min(range.end).saturating_sub(start.max(range.start));
        if overlap > 0 {
            out.push(TextRun {
                len: overlap,
                ..run.clone()
            });
        }
        start = end;
    }
    out
}

/// `gpui::LineWrapper::is_word_char` (gpui 0.2.2, Apache-2.0).
fn is_word_char(c: char) -> bool {
    c.is_ascii_alphanumeric()
        || matches!(c, '\u{00C0}'..='\u{00FF}')
        || matches!(c, '\u{0100}'..='\u{017F}')
        || matches!(c, '\u{0180}'..='\u{024F}')
        || matches!(c, '\u{0400}'..='\u{04FF}')
        || matches!(
            c,
            '-' | '_' | '.' | '\'' | '$' | '%' | '@' | '#' | '^' | '~' | ',' | '=' | ':'
        )
        || matches!(c, '⋯')
}

/// Where `layout` wraps at `wrap_width`: `gpui::LineLayout::compute_wrap_boundaries`
/// (gpui 0.2.2, Apache-2.0), unchanged but for the line clamp, which a
/// reply's text never sets.
fn wrap_boundaries(layout: &LineLayout, text: &str, wrap_width: Pixels) -> SmallVec<[WrapBoundary; 1]> {
    let mut boundaries = SmallVec::new();
    let mut first_non_whitespace_ix = None;
    let mut last_candidate_ix = None;
    let mut last_candidate_x = px(0.);
    let mut last_boundary = WrapBoundary {
        run_ix: 0,
        glyph_ix: 0,
    };
    let mut last_boundary_x = px(0.);
    let mut prev_ch = '\0';
    let mut glyphs = layout
        .runs
        .iter()
        .enumerate()
        .flat_map(move |(run_ix, run)| {
            run.glyphs.iter().enumerate().map(move |(glyph_ix, glyph)| {
                let character = text[glyph.index..].chars().next().unwrap_or(' ');
                (WrapBoundary { run_ix, glyph_ix }, character, glyph.position.x)
            })
        })
        .peekable();
    while let Some((boundary, ch, x)) = glyphs.next() {
        if ch == '\n' {
            continue;
        }
        if is_word_char(ch) {
            if prev_ch == ' ' && ch != ' ' && first_non_whitespace_ix.is_some() {
                last_candidate_ix = Some(boundary);
                last_candidate_x = x;
            }
        } else if ch != ' ' && first_non_whitespace_ix.is_some() {
            last_candidate_ix = Some(boundary);
            last_candidate_x = x;
        }
        if ch != ' ' && first_non_whitespace_ix.is_none() {
            first_non_whitespace_ix = Some(boundary);
        }
        let next_x = glyphs.peek().map_or(layout.width, |(_, _, x)| *x);
        let width = next_x - last_boundary_x;
        if width > wrap_width && boundary > last_boundary {
            if let Some(last_candidate_ix) = last_candidate_ix.take() {
                last_boundary = last_candidate_ix;
                last_boundary_x = last_candidate_x;
            } else {
                last_boundary = boundary;
                last_boundary_x = x;
            }
            boundaries.push(last_boundary);
        }
        prev_ch = ch;
    }
    boundaries
}

impl Mixed {
    /// Each row's first byte and the x its glyphs start from.
    fn rows(&self) -> Vec<(usize, Pixels)> {
        let layout = &self.layout.unwrapped_layout;
        std::iter::once((0, Pixels::ZERO))
            .chain(self.layout.wrap_boundaries.iter().map(|boundary| {
                let glyph = &layout.runs[boundary.run_ix].glyphs[boundary.glyph_ix];
                (glyph.index, glyph.position.x)
            }))
            .collect()
    }

    /// How far a row is moved to align it, as `WrappedLine::paint` moves it.
    fn offset(&self, row: usize, rows: &[(usize, Pixels)], align: TextAlign, width: Pixels) -> Pixels {
        let start = rows[row].1;
        let end = rows
            .get(row + 1)
            .map_or(self.layout.unwrapped_layout.width, |next| next.1);
        match align {
            TextAlign::Left => Pixels::ZERO,
            TextAlign::Center => (width - (end - start)) / 2.,
            TextAlign::Right => width - (end - start),
        }
    }

    /// The row `index` falls in.
    fn row_of(rows: &[(usize, Pixels)], index: usize) -> usize {
        rows.partition_point(|row| row.0 <= index).saturating_sub(1)
    }

    /// The runs' stretches by row: (row, x from, x to, run).
    fn stretches<'a>(
        &'a self,
        rows: &'a [(usize, Pixels)],
    ) -> impl Iterator<Item = (usize, Pixels, Pixels, &'a TextRun)> + 'a {
        let layout = &self.layout.unwrapped_layout;
        let mut start = 0;
        self.runs.iter().flat_map(move |run| {
            let range = start..start + run.len;
            start = range.end;
            let mut pieces = Vec::new();
            let mut at = range.start;
            while at < range.end {
                let row = Self::row_of(rows, at);
                let row_end = rows.get(row + 1).map_or(layout.len, |next| next.0);
                let end = range.end.min(row_end.max(at + 1));
                let x = |index: usize| layout.x_for_index(index) - rows[row].1;
                pieces.push((row, x(at), x(end), run));
                at = end;
            }
            pieces
        })
    }

    pub fn paint_background(
        &self,
        origin: Point<Pixels>,
        pitch: Pixels,
        align: TextAlign,
        bounds: Bounds<Pixels>,
        window: &mut Window,
    ) {
        let rows = self.rows();
        for (row, from, to, run) in self.stretches(&rows) {
            let Some(color) = run.background_color else {
                continue;
            };
            let x = origin.x + self.offset(row, &rows, align, bounds.size.width);
            window.paint_quad(gpui::fill(
                Bounds {
                    origin: point(x + from, origin.y + pitch * row as f32),
                    size: size(to - from, pitch),
                },
                color,
            ));
        }
    }

    pub fn paint(
        &self,
        origin: Point<Pixels>,
        pitch: Pixels,
        align: TextAlign,
        bounds: Bounds<Pixels>,
        window: &mut Window,
        _cx: &mut App,
    ) {
        let layout = &self.layout.unwrapped_layout;
        let rows = self.rows();
        let baseline = (pitch - layout.ascent - layout.descent) / 2. + layout.ascent;
        let color_at = |index: usize| -> Hsla {
            let mut start = 0;
            for run in &self.runs {
                if index < start + run.len {
                    return run.color;
                }
                start += run.len;
            }
            self.runs.last().map_or(gpui::black(), |run| run.color)
        };
        let content = window.content_mask().bounds;
        for (run_ix, run) in layout.runs.iter().enumerate() {
            let size = self.sizes[run_ix];
            for glyph in &run.glyphs {
                let row = Self::row_of(&rows, glyph.index);
                let x = origin.x + self.offset(row, &rows, align, bounds.size.width)
                    + glyph.position.x
                    - rows[row].1;
                let y = origin.y + pitch * row as f32 + baseline;
                let at = point(x, y);
                let near = Bounds {
                    origin: point(x, y - layout.ascent),
                    size: gpui::size(size * 2., pitch),
                };
                if !near.intersects(&content) {
                    continue;
                }
                let _ = if glyph.is_emoji {
                    window.paint_emoji(at, run.font_id, glyph.id, size)
                } else {
                    window.paint_glyph(at, run.font_id, glyph.id, size, color_at(glyph.index))
                };
            }
        }
        // Struck-through stretches, where GPUI strikes them.
        for (row, from, to, run) in self.stretches(&rows) {
            let Some(strike) = run.strikethrough else {
                continue;
            };
            let x = origin.x + self.offset(row, &rows, align, bounds.size.width);
            let y = origin.y + pitch * row as f32 + (layout.ascent * 0.5 + baseline) * 0.5;
            window.paint_strikethrough(
                point(x + from, y),
                to - from,
                &StrikethroughStyle {
                    color: Some(strike.color.unwrap_or(run.color)),
                    thickness: strike.thickness,
                },
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::within;
    use gpui::TextRun;

    #[test]
    fn runs_split_at_a_stretch() {
        let run = |len| TextRun {
            len,
            font: gpui::font("Helvetica"),
            color: gpui::black(),
            background_color: None,
            underline: None,
            strikethrough: None,
        };
        let lens = |runs: Vec<TextRun>| runs.iter().map(|run| run.len).collect::<Vec<_>>();
        assert_eq!(lens(within(&[run(4), run(3), run(5)], 2..9)), [2, 3, 2]);
        assert_eq!(lens(within(&[run(4)], 4..4)), Vec::<usize>::new());
    }

    /// A code span is shaped at its own size and laid on after the words
    /// before it; the line wraps where its stretches add up past the width.
    #[gpui::test]
    fn stretches_keep_their_sizes_end_to_end(cx: &mut gpui::TestAppContext) {
        struct Empty;
        impl gpui::Render for Empty {
            fn render(
                &mut self,
                _: &mut gpui::Window,
                _: &mut gpui::Context<Self>,
            ) -> impl gpui::IntoElement {
                gpui::div()
            }
        }
        let window = cx.add_window(|_, _| Empty);
        let text = "see `code` here";
        let run = TextRun {
            len: text.len(),
            font: gpui::font("Helvetica"),
            color: gpui::black(),
            background_color: None,
            underline: None,
            strikethrough: None,
        };
        window
            .update(cx, |_, window, _| {
                let base = gpui::px(14.5);
                let small = gpui::px(13.05);
                let lines = super::shape(window, text, base, &[run.clone()], &[(4..10, small)], None);
                assert_eq!(lines.len(), 1);
                let layout = &lines[0].layout.unwrapped_layout;
                assert_eq!(lines[0].sizes, [base, small, base]);
                let width = |part: &str, size| {
                    window
                        .text_system()
                        .layout_line(part, size, &[TextRun { len: part.len(), ..run.clone() }], None)
                        .width
                };
                let parts = width("see ", base) + width("`code`", small) + width(" here", base);
                assert_eq!(layout.width, parts);
                assert!(layout.width < width(text, base));
                // Byte offsets stay the text's own.
                assert_eq!(layout.runs[1].glyphs[0].index, 4);
                let wrapped = super::shape(
                    window,
                    text,
                    base,
                    &[run.clone()],
                    &[(4..10, small)],
                    Some(width("see `code`", base)),
                );
                assert_eq!(wrapped[0].layout.wrap_boundaries.len(), 1);
            })
            .unwrap();
    }
}
