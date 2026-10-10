//! Message text whose shaped lines outlive the frame. GPUI's text element
//! shapes its whole string every time it is laid out, so a streaming reply cost
//! O(reply) per frame: each delta re-shaped (and copied) every line before it.
//! Here a message is split into fixed runs of lines, each its own text element,
//! and a run whose text, style and wrap width are unchanged reuses the lines it
//! was shaped into before. A growing reply re-shapes only its last run.
//!
//! Layout and painting follow `gpui::TextLayout` (0.2.2) exactly: the same
//! wrap-width choice, size (summed line heights, widest line rounded up) and
//! line painting. Message text sets no truncation, so none is supported.
use gpui::{
    App, AvailableSpace, Bounds, Element, ElementId, GlobalElementId, InspectorElementId,
    IntoElement, LayoutId, Pixels, SharedString, Size, Style, TextRun, WhiteSpace, Window,
    WrappedLine,
};
use std::{cell::RefCell, collections::HashMap, rc::Rc};

/// Lines per run. Boundaries depend only on line numbers, so text appended to
/// a reply leaves every earlier run unchanged.
const RUN_LINES: usize = 24;
/// Shaped lines kept for reuse, least recently used first out.
const BUDGET: usize = 16 * 1024 * 1024;

pub(super) struct Shaped {
    lines: Vec<WrappedLine>,
    size: Size<Pixels>,
    line_height: Pixels,
    wrap_width: Option<Pixels>,
}

struct Entry {
    text: SharedString,
    runs: Vec<TextRun>,
    font_size: Pixels,
    line_clamp: Option<usize>,
    shaped: Rc<Shaped>,
    cost: usize,
    used: u64,
}

/// Per transcript. Keyed by the row's text owner, the run's ordinal and the
/// exact wrap width: one layout pass measures text unwrapped and at more than
/// one width (a flex probe before the final width), and each must stay cached.
#[derive(Default)]
pub(super) struct ShapeCache {
    entries: HashMap<(SharedString, usize, Option<u32>), Entry>,
    bytes: usize,
    tick: u64,
    /// Ordinals of the runs shaped, in order.
    #[cfg(test)]
    pub shaped: Vec<usize>,
}

impl ShapeCache {
    #[allow(clippy::too_many_arguments)]
    fn shaped(
        &mut self,
        owner: &SharedString,
        ordinal: usize,
        text: &SharedString,
        runs: &[TextRun],
        font_size: Pixels,
        line_height: Pixels,
        line_clamp: Option<usize>,
        wrap_width: Option<Pixels>,
        window: &mut Window,
    ) -> Rc<Shaped> {
        self.tick += 1;
        let slot = (
            owner.clone(),
            ordinal,
            wrap_width.map(|width| f32::from(width).to_bits()),
        );
        if let Some(entry) = self.entries.get_mut(&slot)
            && entry.text == *text
            && entry.runs == runs
            && entry.font_size == font_size
            && entry.line_clamp == line_clamp
            && entry.shaped.line_height == line_height
        {
            entry.used = self.tick;
            return entry.shaped.clone();
        }
        #[cfg(test)]
        self.shaped.push(ordinal);
        let lines = window
            .text_system()
            .shape_text(text.clone(), font_size, runs, wrap_width, line_clamp)
            .unwrap_or_default();
        let mut size = Size::<Pixels>::default();
        for line in &lines {
            let line_size = line.size(line_height);
            size.height += line_size.height;
            size.width = size.width.max(line_size.width).ceil();
        }
        let lines = lines.into_vec();
        let cost = text.len() + lines.len() * std::mem::size_of::<WrappedLine>();
        let shaped = Rc::new(Shaped {
            lines,
            size,
            line_height,
            wrap_width,
        });
        if let Some(previous) = self.entries.remove(&slot) {
            self.bytes -= previous.cost;
        }
        while self.bytes + cost > BUDGET && !self.entries.is_empty() {
            let oldest = self
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.used)
                .map(|(key, _)| key.clone())
                .expect("non-empty cache");
            self.bytes -= self.entries.remove(&oldest).expect("oldest entry").cost;
        }
        self.bytes += cost;
        self.entries.insert(
            slot,
            Entry {
                text: text.clone(),
                runs: runs.to_vec(),
                font_size,
                line_clamp,
                shaped: shaped.clone(),
                cost,
                used: self.tick,
            },
        );
        shaped
    }
}

/// Byte ranges of `text`'s runs of `RUN_LINES` lines. The newline that ends a
/// run is the boundary between two elements, so stacking the runs gives the
/// same lines, including empty ones, as shaping the text whole.
fn run_ranges(text: &str) -> Vec<std::ops::Range<usize>> {
    let mut ranges = Vec::new();
    let mut start = 0;
    let mut lines = 0;
    for (index, byte) in text.bytes().enumerate() {
        if byte == b'\n' {
            lines += 1;
            if lines == RUN_LINES {
                ranges.push(start..index);
                start = index + 1;
                lines = 0;
            }
        }
    }
    ranges.push(start..text.len());
    ranges
}

/// `text` as stacked run elements for a block container. `owner` names the
/// row's text uniquely within its transcript.
pub(super) fn message_text(
    cache: &Rc<RefCell<ShapeCache>>,
    owner: SharedString,
    text: &str,
) -> Vec<ShapedText> {
    run_ranges(text)
        .into_iter()
        .enumerate()
        .map(|(ordinal, range)| ShapedText {
            cache: cache.clone(),
            owner: owner.clone(),
            ordinal,
            text: SharedString::from(text[range].to_owned()),
            styled: None,
        })
        .collect()
}

/// Text in explicit runs at its own size (rendered Markdown), set in lines as
/// TextKit sets Swift's reply text: each line `line_height` tall with
/// `line_spacing` below it, and its glyphs standing on TextKit's baseline,
/// the line's height less its rounded descent, rather than centred as GPUI
/// centres them. GPUI shapes one text at one size.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Styled {
    pub runs: Vec<TextRun>,
    pub font_size: Pixels,
    pub line_height: Pixels,
    pub line_spacing: Pixels,
    /// The text's last lines: no spacing below the last of them, which
    /// TextKit leaves after every line but a paragraph's last.
    pub last: bool,
}

impl Styled {
    fn pitch(&self) -> Pixels {
        self.line_height + self.line_spacing
    }
}

/// One styled text element; `owner` must be unique within the transcript.
pub(super) fn styled_text(
    cache: &Rc<RefCell<ShapeCache>>,
    owner: SharedString,
    text: SharedString,
    styled: Styled,
) -> ShapedText {
    ShapedText {
        cache: cache.clone(),
        owner,
        ordinal: 0,
        text,
        styled: Some(Rc::new(styled)),
    }
}

/// Long text as stacked runs of lines like `message_text` (a code block that
/// grows re-shapes only its last run). `styled.runs` cover all of `text`;
/// each run of lines takes its share, and only the last ends without spacing.
pub(super) fn styled_lines(
    cache: &Rc<RefCell<ShapeCache>>,
    owner: SharedString,
    text: &str,
    styled: Styled,
) -> Vec<ShapedText> {
    let ranges = run_ranges(text);
    let count = ranges.len();
    ranges
        .into_iter()
        .enumerate()
        .map(|(ordinal, range)| ShapedText {
            cache: cache.clone(),
            owner: owner.clone(),
            ordinal,
            styled: Some(Rc::new(Styled {
                runs: runs_within(&styled.runs, range.clone()),
                last: ordinal + 1 == count && styled.last,
                ..styled.clone()
            })),
            text: SharedString::from(text[range].to_owned()),
        })
        .collect()
}

/// The parts of `runs` (laid end to end from byte 0) that fall in `range`.
fn runs_within(runs: &[TextRun], range: std::ops::Range<usize>) -> Vec<TextRun> {
    let mut within = Vec::new();
    let mut start = 0;
    for run in runs {
        let end = start + run.len;
        let overlap = end.min(range.end).saturating_sub(start.max(range.start));
        if overlap > 0 {
            within.push(TextRun {
                len: overlap,
                ..run.clone()
            });
        }
        start = end;
    }
    within
}

pub(super) struct ShapedText {
    cache: Rc<RefCell<ShapeCache>>,
    owner: SharedString,
    ordinal: usize,
    text: SharedString,
    styled: Option<Rc<Styled>>,
}

impl IntoElement for ShapedText {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for ShapedText {
    type RequestLayoutState = Rc<RefCell<Option<Rc<Shaped>>>>;
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        _cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        let text_style = window.text_style();
        // Lines are shaped at their pitch; the spacing below the text's last
        // line is no part of its size.
        let trim = self
            .styled
            .as_ref()
            .filter(|styled| styled.last)
            .map_or(Pixels::ZERO, |styled| styled.line_spacing);
        let (runs, font_size, line_height) = match &self.styled {
            Some(styled) => (styled.runs.clone(), styled.font_size, styled.pitch()),
            None => {
                let font_size = text_style.font_size.to_pixels(window.rem_size());
                let line_height = text_style
                    .line_height
                    .to_pixels(font_size.into(), window.rem_size());
                (
                    vec![text_style.to_run(self.text.len())],
                    font_size,
                    line_height,
                )
            }
        };
        let wraps = text_style.white_space == WhiteSpace::Normal;
        let line_clamp = text_style.line_clamp;
        let state = Rc::new(RefCell::new(None::<Rc<Shaped>>));
        let measured = state.clone();
        let cache = self.cache.clone();
        let owner = self.owner.clone();
        let ordinal = self.ordinal;
        let text = self.text.clone();
        let trimmed = move |size: Size<Pixels>| Size {
            width: size.width,
            height: (size.height - trim).max(Pixels::ZERO),
        };
        let layout_id = window.request_measured_layout(
            Style::default(),
            move |known_dimensions, available_space, window, _cx| {
                let wrap_width = if wraps {
                    known_dimensions.width.or(match available_space.width {
                        AvailableSpace::Definite(width) => Some(width),
                        _ => None,
                    })
                } else {
                    None
                };
                // As gpui::TextLayout: within a frame, an unwrapped query keeps
                // the lines already shaped.
                if let Some(shaped) = measured.borrow().as_ref()
                    && (wrap_width.is_none() || wrap_width == shaped.wrap_width)
                {
                    return trimmed(shaped.size);
                }
                let shaped = cache.borrow_mut().shaped(
                    &owner,
                    ordinal,
                    &text,
                    &runs,
                    font_size,
                    line_height,
                    line_clamp,
                    wrap_width,
                    window,
                );
                let size = shaped.size;
                *measured.borrow_mut() = Some(shaped);
                trimmed(size)
            },
        );
        (layout_id, state)
    }

    fn prepaint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        _bounds: Bounds<Pixels>,
        _state: &mut Self::RequestLayoutState,
        _window: &mut Window,
        _cx: &mut App,
    ) {
    }

    fn paint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        state: &mut Self::RequestLayoutState,
        _prepaint: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        let Some(shaped) = state.borrow().clone() else {
            return;
        };
        let align = window.text_style().text_align;
        let mut origin = bounds.origin;
        for line in &shaped.lines {
            let _ =
                line.paint_background(origin, shaped.line_height, align, Some(bounds), window, cx);
            // GPUI centres a line's glyphs in its pitch; TextKit stands them
            // on the line's height less its rounded descent, the spacing below.
            let lift = self.styled.as_ref().map_or(Pixels::ZERO, |styled| {
                let layout = &line.unwrapped_layout;
                (shaped.line_height - layout.ascent - layout.descent) / 2. + layout.ascent
                    - (styled.line_height - layout.descent.round())
            });
            let glyphs = gpui::point(origin.x, origin.y - lift);
            let _ = line.paint(glyphs, shaped.line_height, align, Some(bounds), window, cx);
            origin.y += line.size(shaped.line_height).height;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{RUN_LINES, ShapeCache, message_text, run_ranges};
    use gpui::{
        Context, TestAppContext, TextRun, VisualTestContext, Window, div, prelude::*, px, size,
    };
    use std::{cell::RefCell, rc::Rc};

    struct Host {
        cache: Rc<RefCell<ShapeCache>>,
        text: String,
    }

    impl Render for Host {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            let column = || div().w(px(300.)).text_size(px(14.5)).line_height(px(21.));
            div()
                .flex()
                .items_start()
                .gap(px(10.))
                .child(
                    column()
                        .debug_selector(|| "whole".into())
                        .child(self.text.clone()),
                )
                .child(
                    column()
                        .debug_selector(|| "runs".into())
                        .children(message_text(&self.cache, "owner".into(), &self.text)),
                )
        }
    }

    fn reply(lines: usize) -> String {
        (0..lines)
            .map(|line| match line % 7 {
                // Long enough to wrap at 300 px, and empty lines between.
                0 => format!("line {line} {}", "wrapping words ".repeat(12)),
                3 => String::new(),
                _ => format!("line {line}"),
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[gpui::test]
    fn stacked_runs_lay_out_as_the_whole_text_and_reshape_only_the_tail(cx: &mut TestAppContext) {
        let cache = Rc::new(RefCell::new(ShapeCache::default()));
        let window = cx.add_window(|_, _| Host {
            cache: cache.clone(),
            text: reply(100),
        });
        let host = window.root(cx).unwrap();
        let mut visual = VisualTestContext::from_window(window.into(), cx);
        visual.simulate_resize(size(px(800.), px(4000.)));
        for text in [
            reply(100),
            reply(100) + "\n",
            "\n\n".into(),
            reply(24),
            String::new(),
        ] {
            host.update(cx, |host, cx| {
                host.text = text.clone();
                cx.notify();
            });
            cx.run_until_parked();
            let whole = visual.debug_bounds("whole").unwrap();
            let runs = visual.debug_bounds("runs").unwrap();
            assert_eq!(runs.size, whole.size, "{text:?}");
        }
        // A reply growing by one line re-shapes its last run only, however
        // many runs come before it.
        host.update(cx, |host, cx| {
            host.text = reply(120);
            cx.notify();
        });
        cx.run_until_parked();
        cache.borrow_mut().shaped.clear();
        host.update(cx, |host, cx| {
            host.text.push_str("\none more streamed line");
            cx.notify();
        });
        cx.run_until_parked();
        let runs = run_ranges(&host.read_with(cx, |host, _| host.text.clone())).len();
        let shaped = cache.borrow().shaped.clone();
        assert!(
            !shaped.is_empty() && shaped.iter().all(|&ordinal| ordinal == runs - 1),
            "re-shaped runs {shaped:?} of {runs}"
        );
        assert_eq!(
            visual.debug_bounds("runs").unwrap().size,
            visual.debug_bounds("whole").unwrap().size
        );
    }

    /// Lines set as TextKit sets a reply's: 18 pt lines with 5.075 below
    /// each but the last, across the cached runs of a long fence too.
    #[gpui::test]
    fn styled_lines_keep_textkit_spacing_across_runs(cx: &mut TestAppContext) {
        struct Lines {
            cache: Rc<RefCell<ShapeCache>>,
            text: String,
        }
        impl Render for Lines {
            fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
                let styled = super::Styled {
                    runs: vec![TextRun {
                        len: self.text.len(),
                        font: gpui::font("Helvetica"),
                        color: gpui::black(),
                        background_color: None,
                        underline: None,
                        strikethrough: None,
                    }],
                    font_size: px(14.5),
                    line_height: px(18.),
                    line_spacing: px(5.075),
                    last: true,
                };
                div()
                    .flex()
                    .flex_col()
                    .items_start()
                    .child(div().w(px(600.)).debug_selector(|| "runs".into()).children(
                        super::styled_lines(
                            &self.cache,
                            "fence".into(),
                            &self.text,
                            styled.clone(),
                        ),
                    ))
                    .child(div().w(px(600.)).debug_selector(|| "one".into()).child(
                        super::styled_text(
                            &self.cache,
                            "paragraph".into(),
                            "one line".into(),
                            super::Styled {
                                runs: vec![TextRun {
                                    len: "one line".len(),
                                    ..styled.runs[0].clone()
                                }],
                                ..styled
                            },
                        ),
                    ))
            }
        }
        let cache = Rc::new(RefCell::new(ShapeCache::default()));
        let text = (0..30)
            .map(|line| format!("line {line}"))
            .collect::<Vec<_>>()
            .join("\n");
        let window = cx.add_window(|_, _| Lines { cache, text });
        let mut visual = VisualTestContext::from_window(window.into(), cx);
        visual.simulate_resize(size(px(800.), px(2000.)));
        cx.run_until_parked();
        // 30 lines in two runs: 30 × 23.075 − 5.075, on whole points.
        assert_eq!(
            visual.debug_bounds("runs").unwrap().size.height,
            px((30. * 23.075_f32 - 5.075).round())
        );
        assert_eq!(visual.debug_bounds("one").unwrap().size.height, px(18.));
    }

    fn lines(text: &str) -> Vec<&str> {
        text.split('\n').collect()
    }

    #[test]
    fn runs_stack_into_exactly_the_lines_of_the_whole_text() {
        let long = (0..100)
            .map(|line| format!("line {line}"))
            .collect::<Vec<_>>()
            .join("\n");
        let exact = (0..RUN_LINES).map(|_| "x").collect::<Vec<_>>().join("\n") + "\n";
        for text in [
            "",
            "one",
            "a\n\nb",
            "trailing\n",
            "\n\n\n",
            "日本語\ne\u{301}\r\nCRLF",
            long.as_str(),
            exact.as_str(),
        ] {
            let stacked: Vec<&str> = run_ranges(text)
                .into_iter()
                .flat_map(|range| lines(&text[range]))
                .collect();
            assert_eq!(stacked, lines(text), "{text:?}");
        }
    }

    #[test]
    fn appended_text_leaves_earlier_runs_unchanged() {
        let mut text = String::new();
        let mut previous: Vec<String> = Vec::new();
        for line in 0..200 {
            text.push_str(&format!("streamed line {line}\n"));
            let runs: Vec<String> = run_ranges(&text)
                .into_iter()
                .map(|range| text[range].to_owned())
                .collect();
            // Only the run that was last can change; new runs follow it.
            let stable = previous.len().saturating_sub(1);
            assert!(runs.len() >= previous.len());
            assert_eq!(runs[..stable], previous[..stable], "after line {line}");
            assert!(runs.iter().all(|run| run.matches('\n').count() < RUN_LINES));
            previous = runs;
        }
    }
}
