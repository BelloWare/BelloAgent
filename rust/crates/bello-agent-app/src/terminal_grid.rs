//! Draws a terminal's grid as Swift 0.1.122 TerminalView.swift does: the
//! system monospaced face at 12 points, a cell exactly one advance of "M"
//! wide and ceil(ascent + descent + 2) tall, an 8-point inset, backgrounds in
//! runs, the selection, ASCII runs on the grid and every other glyph at its
//! own cell, underline and strikethrough bars, and the cursor in the brand
//! orange. Scrolling back, selection and copy are the view's; the emulator
//! owns the screen.
use crate::terminal_panel::TerminalPanel;
use bello_agent_core::terminal::{
    CellStyle, TerminalCell, TerminalColor, TerminalCursorShape, TerminalEmulator, width,
};
use gpui::{prelude::*, *};

pub(crate) const INSET: f32 = 8.;
pub(crate) const FONT_SIZE: f32 = 12.;

pub(crate) fn mono_family() -> &'static str {
    if cfg!(target_os = "macos") {
        ".AppleSystemUIFontMonospaced"
    } else {
        "DejaVu Sans Mono"
    }
}
/// NSFontManager's bold of the monospaced system face is its semibold.
pub(crate) fn mono_font(bold: bool, italic: bool) -> Font {
    Font {
        family: mono_family().into(),
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

/// One cell's size and where the baseline sits in it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct CellMetrics {
    pub(crate) width: f32,
    pub(crate) height: f32,
    /// From the cell's top to the baseline: ascent plus half the leading
    /// (the face has none, so Swift's floor of two points).
    pub(crate) baseline: f32,
}
impl CellMetrics {
    pub(crate) fn measure(window: &Window) -> Self {
        let text = window.text_system();
        let font = text.resolve_font(&mono_font(false, false));
        let size = px(FONT_SIZE);
        let width = text
            .advance(font, size, 'M')
            .map(|advance| f32::from(advance.width))
            .unwrap_or(7.418);
        let ascent = f32::from(text.ascent(font, size));
        let descent = f32::from(text.descent(font, size)).abs();
        Self::from_font(width, ascent, descent)
    }
    pub(crate) fn from_font(advance: f32, ascent: f32, descent: f32) -> Self {
        let leading = 2f32;
        Self {
            width: advance.max(1.),
            height: (ascent + descent + leading).ceil().max(1.),
            baseline: ascent + leading / 2.,
        }
    }
    /// The grid a view of this size holds, or None when it is too small to
    /// fit (a view not shown yet, a collapsing panel): it keeps its grid.
    pub(crate) fn grid(self, width: f32, height: f32) -> Option<(usize, usize)> {
        if width < INSET * 2. + self.width * 2. || height < INSET * 2. + self.height {
            return None;
        }
        let columns = (((width - INSET * 2.) / self.width) as usize).max(2);
        let rows = (((height - INSET * 2.) / self.height) as usize).max(1);
        Some((columns, rows))
    }
}

const LIGHT: [u32; 16] = [
    0x1d1b17, 0xb3312c, 0x2f7d3b, 0x9a6a00, 0x2a5aa6, 0x8a3fb0, 0x1f7a8c, 0xc9c3b8, 0x6e6a61,
    0xd1453f, 0x3d8a57, 0xb97a1e, 0x3b6fc4, 0xa35bd1, 0x2c96a8, 0xf2ede5,
];
const DARK: [u32; 16] = [
    0x3a3129, 0xea7c7c, 0x7cc48f, 0xe3b15c, 0xa8c9fc, 0xd7a5ee, 0x7fd3e0, 0xd9d4cb, 0x78746b,
    0xf19a9a, 0x98d6a8, 0xf0c67c, 0xbcd6ff, 0xe4c0f5, 0x9fe0eb, 0xf5f1ea,
];

/// The terminal's colours in one appearance (`.piInk`, `.piTerminalSurface`,
/// `.piBrandOrange` and the sixteen-colour palettes).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct TerminalColors {
    pub(crate) dark: bool,
}
impl TerminalColors {
    pub(crate) fn foreground(self) -> u32 {
        if self.dark { 0xf1ece5 } else { 0x1f1b17 }
    }
    pub(crate) fn background(self) -> u32 {
        if self.dark { 0x15120f } else { 0xede4d8 }
    }
    pub(crate) fn accent(self) -> u32 {
        if self.dark { 0xf0a052 } else { 0xd67520 }
    }
    /// A colour as 0xRRGGBB.
    pub(crate) fn rgb(self, colour: TerminalColor, foreground: bool) -> u32 {
        match colour {
            TerminalColor::Standard => {
                if foreground {
                    self.foreground()
                } else {
                    self.background()
                }
            }
            TerminalColor::Rgb(r, g, b) => u32::from(r) << 16 | u32::from(g) << 8 | u32::from(b),
            TerminalColor::Indexed(index) if index < 16 => {
                (if self.dark { DARK } else { LIGHT })[usize::from(index)]
            }
            TerminalColor::Indexed(index) if index < 232 => {
                let value = usize::from(index) - 16;
                let steps = [0u32, 95, 135, 175, 215, 255];
                steps[value / 36] << 16 | steps[value / 6 % 6] << 8 | steps[value % 6]
            }
            TerminalColor::Indexed(index) => {
                let gray = 8 + 10 * (u32::from(index) - 232);
                gray << 16 | gray << 8 | gray
            }
        }
    }
    /// A glyph's colour: inverse swaps, dim is at 60%.
    pub(crate) fn glyph(self, style: &CellStyle) -> Hsla {
        let colour = if style.inverse {
            self.rgb(style.background, false)
        } else {
            self.rgb(style.foreground, true)
        };
        let mut colour: Hsla = rgb(colour).into();
        if style.dim {
            colour.a = 0.6;
        }
        colour
    }
    /// A background to paint, or None where the view's own shows.
    pub(crate) fn fill(self, style: &CellStyle) -> Option<u32> {
        if style.inverse {
            return Some(self.rgb(style.foreground, true));
        }
        match style.background {
            TerminalColor::Standard => None,
            colour => Some(self.rgb(colour, false)),
        }
    }
    /// What a program gets when it asks for the default colours (OSC 10/11).
    pub(crate) fn publish(self, emulator: &mut TerminalEmulator) {
        let split = |c: u32| ((c >> 16) as u8, (c >> 8) as u8, c as u8);
        emulator.default_foreground_rgb = split(self.foreground());
        emulator.default_background_rgb = split(self.background());
    }
}

/// A place in the grid: a line counted from the start of the history
/// (lines the scrollback has dropped included), and a column.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Position {
    pub(crate) line: usize,
    pub(crate) column: usize,
}

/// What the reader is doing with one terminal: how far back they have
/// scrolled, what they selected, and text an input method is composing.
#[derive(Clone, Debug, Default)]
pub(crate) struct GridState {
    pub(crate) scroll_offset: usize,
    pub(crate) scroll_accumulator: f32,
    pub(crate) selection: Option<(Position, Position)>,
    pub(crate) anchor: Option<Position>,
    pub(crate) produced_lines: usize,
    pub(crate) marked_text: String,
}
impl GridState {
    /// The first line on screen, in emulator line indices.
    pub(crate) fn first_visible(&self, emulator: &TerminalEmulator) -> usize {
        emulator
            .line_count()
            .saturating_sub(emulator.rows() + self.scroll_offset)
    }
    /// Output arrived: a reader who has scrolled back stays on the lines they
    /// are reading, the bottom moving further away instead.
    pub(crate) fn output_arrived(&mut self, emulator: &TerminalEmulator) {
        let produced = emulator.trimmed_lines() + emulator.scrollback_len();
        if self.scroll_offset > 0 {
            self.scroll_offset = (self.scroll_offset
                + produced.saturating_sub(self.produced_lines))
            .min(emulator.scrollback_len());
        }
        self.produced_lines = produced;
    }
    /// Where a point in the view falls.
    pub(crate) fn position(
        &self,
        emulator: &TerminalEmulator,
        metrics: CellMetrics,
        x: f32,
        y: f32,
    ) -> Position {
        let column =
            (((x - INSET) / metrics.width).floor().max(0.) as usize).min(emulator.columns());
        let row =
            (((y - INSET) / metrics.height).floor().max(0.) as usize).min(emulator.rows() - 1);
        Position {
            line: emulator.trimmed_lines() + self.first_visible(emulator) + row,
            column,
        }
    }
    pub(crate) fn select_line(&mut self, emulator: &TerminalEmulator, at: Position) {
        self.selection = Some((
            Position {
                line: at.line,
                column: 0,
            },
            Position {
                line: at.line,
                column: emulator.columns(),
            },
        ));
        self.anchor = None;
    }
    /// A word: letters, digits and `_-./~` around the point.
    pub(crate) fn select_word(&mut self, emulator: &TerminalEmulator, at: Position) {
        let Some(index) = at.line.checked_sub(emulator.trimmed_lines()) else {
            return;
        };
        if index >= emulator.line_count() {
            return;
        }
        let cells = emulator.line(index);
        if at.column >= cells.len() || !is_word(&cells[at.column]) {
            return;
        }
        let (mut start, mut end) = (at.column, at.column + 1);
        while start > 0 && is_word(&cells[start - 1]) {
            start -= 1;
        }
        while end < cells.len() && is_word(&cells[end]) {
            end += 1;
        }
        self.selection = Some((
            Position {
                line: at.line,
                column: start,
            },
            Position {
                line: at.line,
                column: end,
            },
        ));
        self.anchor = None;
    }
    pub(crate) fn drag_to(&mut self, at: Position) {
        if let Some(anchor) = self.anchor {
            self.selection = Some((anchor.min(at), anchor.max(at)));
        }
    }
    /// A press that did not move selects nothing.
    pub(crate) fn mouse_up(&mut self) {
        if self.selection.is_some_and(|(start, end)| start == end) {
            self.selection = None;
        }
        self.anchor = None;
    }
    /// Everything with content: the blank rows under the cursor add nothing.
    pub(crate) fn select_all(&mut self, emulator: &TerminalEmulator) {
        let last = (0..emulator.line_count())
            .rev()
            .find(|&line| !emulator.text_at_line(line).is_empty());
        self.selection = last.map(|last| {
            (
                Position {
                    line: emulator.trimmed_lines(),
                    column: 0,
                },
                Position {
                    line: emulator.trimmed_lines() + last,
                    column: emulator.columns(),
                },
            )
        });
    }
    pub(crate) fn selected_text(&self, emulator: &TerminalEmulator) -> Option<String> {
        let (start, end) = self.selection?;
        let mut lines = Vec::new();
        for absolute in start.line..=end.line {
            let Some(index) = absolute.checked_sub(emulator.trimmed_lines()) else {
                continue;
            };
            if index >= emulator.line_count() {
                continue;
            }
            let cells = emulator.line(index);
            let from = if absolute == start.line {
                start.column
            } else {
                0
            };
            let to = if absolute == end.line {
                end.column.min(cells.len())
            } else {
                cells.len()
            };
            if from >= to {
                lines.push(String::new());
                continue;
            }
            let mut text = String::new();
            for cell in &cells[from..to] {
                cell.text.push_to(&mut text);
            }
            if absolute != end.line || to >= cells.len() {
                text.truncate(text.trim_end_matches(' ').len());
            }
            lines.push(text);
        }
        Some(lines.join("\n"))
    }
}
fn is_word(cell: &TerminalCell) -> bool {
    !cell.is_blank()
        && cell
            .text
            .as_string()
            .chars()
            .all(|c| c.is_alphanumeric() || "_-./~".contains(c))
}

/// One visible row, copied out of the emulator for painting.
struct Row {
    row: usize,
    absolute: usize,
    cells: Vec<TerminalCell>,
}
struct Cursor {
    column: usize,
    row: usize,
    wide: bool,
    shape: TerminalCursorShape,
    text: String,
}
pub(crate) struct Frame {
    rows: Vec<Row>,
    cursor: Option<Cursor>,
    selection: Option<(Position, Position)>,
    columns: usize,
    marked_text: String,
    focused: bool,
    colors: TerminalColors,
    metrics: CellMetrics,
}

/// The shown terminal's grid. It reads the panel's selected session.
pub(crate) struct TerminalGrid {
    pub(crate) panel: Entity<TerminalPanel>,
    pub(crate) focus: FocusHandle,
}
impl IntoElement for TerminalGrid {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}

pub(crate) enum Paint {
    Quad(PaintQuad),
    Text(Box<ShapedLine>, Point<Pixels>, Pixels),
}

impl Element for TerminalGrid {
    type RequestLayoutState = ();
    type PrepaintState = Vec<Paint>;

    fn id(&self) -> Option<ElementId> {
        None
    }
    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        None
    }
    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        let style = Style {
            size: Size {
                width: relative(1.).into(),
                height: relative(1.).into(),
            },
            ..Style::default()
        };
        (window.request_layout(style, [], cx), ())
    }
    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) -> Vec<Paint> {
        let metrics = CellMetrics::measure(window);
        let focused = self.focus.is_focused(window);
        let frame = self.panel.update(cx, |panel, _| {
            panel.grid_laid_out(bounds, metrics);
            panel.frame(metrics, focused)
        });
        let Some(frame) = frame else {
            return Vec::new();
        };
        paints(&frame, bounds, window)
    }
    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        paints: &mut Vec<Paint>,
        window: &mut Window,
        cx: &mut App,
    ) {
        window.handle_input(
            &self.focus,
            TerminalInput(ElementInputHandler::new(bounds, self.panel.clone())),
            cx,
        );
        window.with_content_mask(Some(ContentMask { bounds }), |window| {
            for paint in paints.drain(..) {
                match paint {
                    Paint::Quad(quad) => window.paint_quad(quad),
                    Paint::Text(line, origin, height) => {
                        let _ = line.paint(origin, height, window, cx);
                    }
                }
            }
        });
    }
}

/// The panel's text input, without macOS press-and-hold: a held key
/// repeats into the shell as in any terminal, never opening the accent
/// picker. Input methods still compose through the panel's marked text.
struct TerminalInput(ElementInputHandler<TerminalPanel>);
impl InputHandler for TerminalInput {
    fn selected_text_range(
        &mut self,
        ignore_disabled_input: bool,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<UTF16Selection> {
        self.0
            .selected_text_range(ignore_disabled_input, window, cx)
    }
    fn marked_text_range(
        &mut self,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<std::ops::Range<usize>> {
        self.0.marked_text_range(window, cx)
    }
    fn text_for_range(
        &mut self,
        range: std::ops::Range<usize>,
        adjusted: &mut Option<std::ops::Range<usize>>,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<String> {
        self.0.text_for_range(range, adjusted, window, cx)
    }
    fn replace_text_in_range(
        &mut self,
        range: Option<std::ops::Range<usize>>,
        text: &str,
        window: &mut Window,
        cx: &mut App,
    ) {
        self.0.replace_text_in_range(range, text, window, cx)
    }
    fn replace_and_mark_text_in_range(
        &mut self,
        range: Option<std::ops::Range<usize>>,
        text: &str,
        selected: Option<std::ops::Range<usize>>,
        window: &mut Window,
        cx: &mut App,
    ) {
        self.0
            .replace_and_mark_text_in_range(range, text, selected, window, cx)
    }
    fn unmark_text(&mut self, window: &mut Window, cx: &mut App) {
        self.0.unmark_text(window, cx)
    }
    fn bounds_for_range(
        &mut self,
        range: std::ops::Range<usize>,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<Bounds<Pixels>> {
        self.0.bounds_for_range(range, window, cx)
    }
    fn character_index_for_point(
        &mut self,
        point: Point<Pixels>,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<usize> {
        self.0.character_index_for_point(point, window, cx)
    }
    fn apple_press_and_hold_enabled(&mut self) -> bool {
        false
    }
}

impl TerminalPanel {
    /// What the grid shows now, copied for painting.
    pub(crate) fn frame(&self, metrics: CellMetrics, focused: bool) -> Option<Frame> {
        let session = self.selected_session()?;
        let emulator = &session.emulator;
        let grid = self.grid_state(session);
        let first = grid.first_visible(emulator);
        let rows: Vec<Row> = (0..emulator.rows())
            .filter(|row| first + row < emulator.line_count())
            .map(|row| Row {
                row,
                absolute: emulator.trimmed_lines() + first + row,
                cells: emulator.line(first + row),
            })
            .collect();
        let cursor = (grid.scroll_offset == 0 && emulator.cursor_visible())
            .then(|| {
                let at = emulator.cursor();
                let row = emulator.scrollback_len() + at.y;
                let row = row
                    .checked_sub(first)
                    .filter(|row| *row < emulator.rows())?;
                let cell = &emulator.screen()[at.y][at.x.min(emulator.columns() - 1)];
                Some(Cursor {
                    column: at.x,
                    row,
                    wide: cell.width == 2,
                    shape: emulator.cursor_shape(),
                    text: cell.text.as_string(),
                })
            })
            .flatten();
        Some(Frame {
            rows,
            cursor,
            selection: grid.selection,
            columns: emulator.columns(),
            marked_text: grid.marked_text.clone(),
            focused,
            colors: self.colors(),
            metrics,
        })
    }
}

/// A painted rectangle with its edges on device pixels, so cells, the
/// cursor and backgrounds stay crisp though a cell is a fractional width.
fn aligned(x: f32, y: f32, w: f32, h: f32, scale: f32) -> Bounds<Pixels> {
    let round = |v: f32| (v * scale).round() / scale;
    let (left, top, right, bottom) = (round(x), round(y), round(x + w), round(y + h));
    Bounds::new(
        point(px(left), px(top)),
        size(px(right - left), px(bottom - top)),
    )
}

fn paints(frame: &Frame, bounds: Bounds<Pixels>, window: &mut Window) -> Vec<Paint> {
    let mut out = Vec::new();
    let scale = window.scale_factor();
    let m = frame.metrics;
    let c = frame.colors;
    let left = f32::from(bounds.origin.x) + INSET;
    let top0 = f32::from(bounds.origin.y) + INSET;
    out.push(Paint::Quad(fill(bounds, rgb(c.background()))));
    for row in &frame.rows {
        let top = top0 + row.row as f32 * m.height;
        let cells = &row.cells;
        // Backgrounds first, in runs of one colour.
        let mut column = 0;
        while column < cells.len() {
            let colour = c.fill(&cells[column].style);
            let mut end = column + 1;
            while end < cells.len() && c.fill(&cells[end].style) == colour {
                end += 1;
            }
            if let Some(colour) = colour {
                let x = left + column as f32 * m.width;
                out.push(Paint::Quad(fill(
                    aligned(x, top, (end - column) as f32 * m.width, m.height, scale),
                    rgb(colour),
                )));
            }
            column = end;
        }
        if let Some((start, end)) = frame.selection
            && row.absolute >= start.line
            && row.absolute <= end.line
        {
            let from = if row.absolute == start.line {
                start.column
            } else {
                0
            };
            let to = if row.absolute == end.line {
                end.column
            } else {
                cells.len().max(frame.columns)
            };
            if to > from {
                let mut colour: Hsla = rgb(c.accent()).into();
                colour.a = 0.22;
                let x = left + from as f32 * m.width;
                out.push(Paint::Quad(fill(
                    aligned(x, top, (to - from) as f32 * m.width, m.height, scale),
                    colour,
                )));
            }
        }
        // Then the glyphs: ASCII runs of one style in a single line, everything else cell by cell.
        let mut column = 0;
        while column < cells.len() {
            let cell = &cells[column];
            if cell.width == 0 || cell.style.hidden {
                column += 1;
                continue;
            }
            let plain = cell.width == 1 && cell.text.len_utf8() == 1;
            let mut end = column + 1;
            if plain {
                while end < cells.len()
                    && cells[end].width == 1
                    && cells[end].text.len_utf8() == 1
                    && cells[end].style == cell.style
                {
                    end += 1;
                }
            }
            let mut text = String::new();
            for cell in &cells[column..end] {
                cell.text.push_to(&mut text);
            }
            let x = left + column as f32 * m.width;
            if !text.chars().all(|ch| ch == ' ') {
                out.push(glyphs(
                    window,
                    &text,
                    &cell.style,
                    c.glyph(&cell.style),
                    plain.then_some(m.width),
                    x,
                    top + m.baseline,
                ));
            }
            let span = if plain {
                end - column
            } else {
                usize::from(cell.width)
            };
            let width = span as f32 * m.width;
            if cell.style.underline || cell.style.strikethrough {
                let colour = c.glyph(&cell.style);
                if cell.style.underline {
                    out.push(Paint::Quad(fill(
                        aligned(x, top + m.height - 1.5, width, 1., scale),
                        colour,
                    )));
                }
                if cell.style.strikethrough {
                    out.push(Paint::Quad(fill(
                        aligned(x, top + m.height / 2., width, 1., scale),
                        colour,
                    )));
                }
            }
            column = if plain {
                end
            } else {
                column + usize::from(cell.width).max(1)
            };
        }
    }
    if let Some(cursor) = &frame.cursor {
        let x = left + cursor.column as f32 * m.width;
        let top = top0 + cursor.row as f32 * m.height;
        let cell_width = if cursor.wide { 2. } else { 1. } * m.width;
        let rect = aligned(x, top, cell_width, m.height, scale);
        let accent: Hsla = rgb(c.accent()).into();
        if !frame.marked_text.is_empty() {
            // Text being composed sits at the cursor until the input method commits it.
            let cells: usize = frame
                .marked_text
                .chars()
                .map(|ch| usize::from(width::width(ch)))
                .sum::<usize>()
                .max(1);
            let marked = aligned(x, top, cells as f32 * m.width, m.height, scale);
            let mut soft = accent;
            soft.a = 0.15;
            out.push(Paint::Quad(fill(marked, soft)));
            out.push(glyphs(
                window,
                &frame.marked_text,
                &CellStyle::PLAIN,
                rgb(c.foreground()).into(),
                None,
                x,
                top + m.baseline,
            ));
            out.push(Paint::Quad(fill(
                Bounds::new(
                    point(
                        marked.origin.x,
                        marked.origin.y + marked.size.height - px(2.),
                    ),
                    size(marked.size.width, px(2.)),
                ),
                accent,
            )));
        } else if !frame.focused {
            out.push(Paint::Quad(outline(
                Bounds::new(
                    point(rect.origin.x + px(0.5), rect.origin.y + px(0.5)),
                    size(rect.size.width - px(1.), rect.size.height - px(1.)),
                ),
                accent,
                BorderStyle::Solid,
            )));
        } else {
            match cursor.shape {
                TerminalCursorShape::Block => {
                    out.push(Paint::Quad(fill(rect, accent)));
                    if !cursor.text.is_empty() && cursor.text != " " {
                        // At the cell's own origin, where the glyph it covers is drawn.
                        out.push(glyphs(
                            window,
                            &cursor.text,
                            &CellStyle::PLAIN,
                            rgb(c.background()).into(),
                            None,
                            x,
                            top + m.baseline,
                        ));
                    }
                }
                TerminalCursorShape::Underline => out.push(Paint::Quad(fill(
                    Bounds::new(
                        point(rect.origin.x, rect.origin.y + rect.size.height - px(2.)),
                        size(rect.size.width, px(2.)),
                    ),
                    accent,
                ))),
                TerminalCursorShape::Bar => out.push(Paint::Quad(fill(
                    Bounds::new(rect.origin, size(px(2.), rect.size.height)),
                    accent,
                ))),
            }
        }
    }
    out
}

/// A run of glyphs with its baseline at `baseline`; `grid` keeps each
/// character on its own cell (no kerning, no ligatures).
fn glyphs(
    window: &mut Window,
    text: &str,
    style: &CellStyle,
    colour: Hsla,
    grid: Option<f32>,
    x: f32,
    baseline: f32,
) -> Paint {
    let mut font = mono_font(style.bold, style.italic);
    font.features = FontFeatures::disable_ligatures();
    let run = TextRun {
        len: text.len(),
        font,
        color: colour,
        background_color: None,
        underline: None,
        strikethrough: None,
    };
    let line = window.text_system().shape_line(
        SharedString::from(text.to_owned()),
        px(FONT_SIZE),
        &[run],
        grid.map(px),
    );
    let height = line.ascent + line.descent;
    let origin = point(px(x), px(baseline) - line.ascent);
    Paint::Text(Box::new(line), origin, height)
}

#[cfg(test)]
#[path = "terminal_grid_tests.rs"]
mod tests;
