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
//!
//! Styled text may carry links, which act as links in Swift's transcript
//! NSTextView: the pointing hand over one, and a press released on the link
//! it began on opens it.
use gpui::{
    App, AvailableSpace, Bounds, CursorStyle, DispatchPhase, Element, ElementId, GlobalElementId,
    Hitbox, HitboxBehavior, InspectorElementId, IntoElement, LayoutId, MouseButton, MouseDownEvent,
    MouseMoveEvent, MouseUpEvent, Pixels, Point, SharedString, Size, Style, TextAlign, TextRun,
    WhiteSpace, Window, WrapBoundary, WrappedLine,
};
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    ops::Range,
    rc::Rc,
};

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
    /// Links by their bytes in the text, in order and apart.
    pub links: Vec<Link>,
}

/// A link's bytes in its text and the web address it opens.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Link {
    pub range: Range<usize>,
    pub url: SharedString,
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
                links: links_within(&styled.links, range.clone()),
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

/// The parts of `links` that fall in `range`, from its start.
fn links_within(links: &[Link], range: Range<usize>) -> Vec<Link> {
    links
        .iter()
        .filter(|link| link.range.start < range.end && range.start < link.range.end)
        .map(|link| Link {
            range: link.range.start.max(range.start) - range.start
                ..link.range.end.min(range.end) - range.start,
            url: link.url.clone(),
        })
        .collect()
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

impl ShapedText {
    fn links(&self) -> Option<&Rc<Styled>> {
        self.styled
            .as_ref()
            .filter(|styled| !styled.links.is_empty())
    }
}

impl Element for ShapedText {
    type RequestLayoutState = Rc<RefCell<Option<Rc<Shaped>>>>;
    /// Where the pointer meets the text, when it has links.
    type PrepaintState = Option<Hitbox>;

    /// Text with links keeps where a press began; `owner` and the run's
    /// ordinal name it uniquely within the transcript.
    fn id(&self) -> Option<ElementId> {
        self.links()
            .map(|_| ElementId::named_usize(self.owner.clone(), self.ordinal))
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
        bounds: Bounds<Pixels>,
        _state: &mut Self::RequestLayoutState,
        window: &mut Window,
        _cx: &mut App,
    ) -> Option<Hitbox> {
        self.links()
            .map(|_| window.insert_hitbox(bounds, HitboxBehavior::Normal))
    }

    fn paint(
        &mut self,
        id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        state: &mut Self::RequestLayoutState,
        hitbox: &mut Self::PrepaintState,
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
        if let (Some(id), Some(hitbox), Some(styled)) = (id, hitbox.as_ref(), self.links()) {
            let hit = Hit {
                shaped,
                bounds,
                align,
                styled: styled.clone(),
            };
            link_events(id, hitbox, hit, window);
        }
    }
}

/// Which link the pointer is over and the link a press began on, kept from
/// frame to frame under the element's id.
#[derive(Default)]
struct LinkState {
    hovered: Rc<Cell<Option<usize>>>,
    pressed: Rc<Cell<Option<usize>>>,
}

fn link_events(id: &GlobalElementId, hitbox: &Hitbox, hit: Hit, window: &mut Window) {
    let view = window.current_view();
    let hit = Rc::new(hit);
    window.with_element_state::<LinkState, _>(id, |state, window| {
        let state = state.unwrap_or_default();
        let under = |hitbox: &Hitbox, position, window: &Window| {
            hitbox
                .is_hovered(window)
                .then(|| hit.link(position))
                .flatten()
        };
        let hovered = under(hitbox, window.mouse_position(), window);
        state.hovered.set(hovered);
        if hovered.is_some() {
            window.set_cursor_style(CursorStyle::PointingHand, hitbox);
        }
        // Moving onto or off a link draws again to change the pointer.
        window.on_mouse_event({
            let (hit, hitbox, hovered) = (hit.clone(), hitbox.clone(), state.hovered.clone());
            move |event: &MouseMoveEvent, phase, window, cx| {
                if phase != DispatchPhase::Bubble {
                    return;
                }
                let now = hitbox
                    .is_hovered(window)
                    .then(|| hit.link(event.position))
                    .flatten();
                if hovered.replace(now) != now {
                    cx.notify(view);
                }
            }
        });
        window.on_mouse_event({
            let (hit, hitbox, pressed) = (hit.clone(), hitbox.clone(), state.pressed.clone());
            move |event: &MouseDownEvent, phase, window, _| {
                if phase == DispatchPhase::Bubble && event.button == MouseButton::Left {
                    pressed.set(
                        hitbox
                            .is_hovered(window)
                            .then(|| hit.link(event.position))
                            .flatten(),
                    );
                }
            }
        });
        window.on_mouse_event({
            let (hit, hitbox, pressed) = (hit.clone(), hitbox.clone(), state.pressed.clone());
            move |event: &MouseUpEvent, phase, window, cx| {
                if phase != DispatchPhase::Bubble || event.button != MouseButton::Left {
                    return;
                }
                if let Some(began) = pressed.take()
                    && hitbox.is_hovered(window)
                    && hit.link(event.position) == Some(began)
                {
                    cx.open_url(&hit.styled.links[began].url);
                }
            }
        });
        ((), state)
    });
}

/// Painted text, for finding what lies under the pointer.
struct Hit {
    shaped: Rc<Shaped>,
    bounds: Bounds<Pixels>,
    align: TextAlign,
    styled: Rc<Styled>,
}

impl Hit {
    /// The link whose glyphs lie under `position`.
    fn link(&self, position: Point<Pixels>) -> Option<usize> {
        let index = self.index(position)?;
        self.styled
            .links
            .iter()
            .position(|link| link.range.contains(&index))
    }

    /// The byte of the glyph under `position`, found as
    /// `gpui::TextLayout::index_for_position` finds it, with each row moved
    /// as `WrappedLine::paint` aligns it.
    fn index(&self, position: Point<Pixels>) -> Option<usize> {
        if !self.bounds.contains(&position) {
            return None;
        }
        let pitch = self.shaped.line_height;
        let mut top = self.bounds.origin.y;
        let mut start = 0;
        for line in &self.shaped.lines {
            let bottom = top + line.size(pitch).height;
            if position.y >= bottom {
                top = bottom;
                start += line.len() + 1;
                continue;
            }
            let y = position.y - top;
            let row = (y / pitch) as usize;
            let x = position.x - self.bounds.origin.x - self.row_offset(line, row);
            return line
                .index_for_position(gpui::point(x, y), pitch)
                .ok()
                .map(|index| start + index);
        }
        None
    }

    /// How far `WrappedLine::paint` moves a row of `line` to align it.
    fn row_offset(&self, line: &WrappedLine, row: usize) -> Pixels {
        let layout = &line.unwrapped_layout;
        let x = |boundary: &WrapBoundary| {
            layout.runs[boundary.run_ix].glyphs[boundary.glyph_ix]
                .position
                .x
        };
        let start = row
            .checked_sub(1)
            .and_then(|row| line.wrap_boundaries.get(row))
            .map_or(Pixels::ZERO, x);
        let end = line.wrap_boundaries.get(row).map_or(layout.width, x);
        let width = self.bounds.size.width;
        match self.align {
            TextAlign::Left => Pixels::ZERO,
            TextAlign::Center => (width - (end - start)) / 2.,
            TextAlign::Right => width - (end - start),
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
                    links: Vec::new(),
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

    /// Links act as Swift's transcript links: a press released on the link
    /// it began on opens it, and only over the link's glyphs where the row
    /// is drawn, aligned or not.
    #[gpui::test]
    fn a_click_on_a_link_opens_it(cx: &mut TestAppContext) {
        struct Linked {
            cache: Rc<RefCell<ShapeCache>>,
        }
        impl Render for Linked {
            fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
                let element = |owner: &'static str, url: &'static str| {
                    let text = "plain line\nlinked line";
                    let start = "plain line\n".len();
                    super::styled_text(
                        &self.cache,
                        owner.into(),
                        text.into(),
                        super::Styled {
                            runs: vec![TextRun {
                                len: text.len(),
                                font: gpui::font("Helvetica"),
                                color: gpui::black(),
                                background_color: None,
                                underline: None,
                                strikethrough: None,
                            }],
                            font_size: px(14.5),
                            line_height: px(18.),
                            line_spacing: px(5.),
                            last: true,
                            links: vec![super::Link {
                                range: start..text.len(),
                                url: url.into(),
                            }],
                        },
                    )
                };
                div()
                    .flex()
                    .flex_col()
                    .items_start()
                    .child(
                        div()
                            .w(px(400.))
                            .debug_selector(|| "left".into())
                            .child(element("left", "https://example.com/left")),
                    )
                    .child(
                        div()
                            .w(px(400.))
                            .text_align(gpui::TextAlign::Center)
                            .debug_selector(|| "center".into())
                            .child(element("center", "https://example.com/center")),
                    )
            }
        }
        let cache = Rc::new(RefCell::new(ShapeCache::default()));
        let window = cx.add_window(|_, _| Linked { cache });
        let mut visual = VisualTestContext::from_window(window.into(), cx);
        visual.simulate_resize(size(px(800.), px(600.)));
        cx.run_until_parked();
        let left = visual.debug_bounds("left").unwrap().origin;
        let center = visual.debug_bounds("center").unwrap().origin;
        // The first line is plain; the second (one 23-point pitch down) links.
        let at = |origin: gpui::Point<gpui::Pixels>, x: f32, line: f32| {
            gpui::point(origin.x + px(x), origin.y + px(23. * line + 9.))
        };
        let none = gpui::Modifiers::none();
        visual.simulate_click(at(left, 10., 0.), none);
        // Pressed on the link, released off it.
        visual.simulate_mouse_down(at(left, 10., 1.), gpui::MouseButton::Left, none);
        visual.simulate_mouse_up(at(left, 10., 0.), gpui::MouseButton::Left, none);
        // Past the end of the link's row.
        visual.simulate_click(at(left, 300., 1.), none);
        // Where a left-aligned row would be: the centred row is not there.
        visual.simulate_click(at(center, 10., 1.), none);
        assert_eq!(cx.opened_url(), None);
        visual.simulate_click(at(center, 200., 1.), none);
        assert_eq!(
            cx.opened_url().as_deref(),
            Some("https://example.com/center")
        );
        visual.simulate_click(at(left, 10., 1.), none);
        assert_eq!(cx.opened_url().as_deref(), Some("https://example.com/left"));
    }

    #[test]
    fn links_split_with_the_runs_of_lines_they_fall_in() {
        let link = |range: std::ops::Range<usize>| super::Link {
            range,
            url: "https://example.com".into(),
        };
        let links = [link(2..5), link(8..14), link(20..22)];
        assert_eq!(
            super::links_within(&links, 0..10),
            vec![link(2..5), link(8..10)]
        );
        assert_eq!(super::links_within(&links, 10..20), vec![link(0..4)]);
        assert_eq!(super::links_within(&links, 22..30), vec![]);
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
