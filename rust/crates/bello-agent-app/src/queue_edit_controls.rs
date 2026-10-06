//! Queued-edit row controls from Workspaces/QueuePanel.swift:185–238.
//! This renderer has no operation state: callers choose the current state and
//! callbacks revalidate the captured chat, turn, and edit identities.
//!
//! PiFont.caption and PiGhostButtonStyle retain their source type/padding.
//! SF Symbols and SwiftUI Label's native metrics are not available in GPUI:
//! symbols use the existing geometric SVG adapter, with PiSpacing.xs between
//! each adapted symbol and its label. Text widths are shaped, never guessed.
use crate::{AgentView, theme::Palette};
use gpui::{
    Animation, AnimationExt, Context, Div, ElementId, FontWeight, Hsla, IntoElement, MouseButton,
    Pixels, Render, SharedString, Size, Stateful, TextRun, Transformation, Window, black, div,
    percentage, prelude::*, px, rgb, rgba, size,
};
use std::time::Duration;

const ROW_GAP: f32 = 8.;
const LABEL_GAP: f32 = 4.;
const CAPTION_SIZE: f32 = 11.5;
const CONTROL_SIZE: f32 = 22.;
// PiIconButton uses its hit area times 0.46 for the medium-weight symbol.
const CONTROL_ICON_SIZE: f32 = CONTROL_SIZE * 0.46;
const GHOST_SIZE: f32 = 12.5;
const GHOST_PADDING_X: f32 = 10.;
const GHOST_PADDING_Y: f32 = 6.;
const GHOST_DISABLED_OPACITY: f32 = 0.4;
const ICON_DISABLED_OPACITY: f32 = 0.35;
// PiSpinner(controlSize: .mini), Design/PiToggles.swift:142–151.
const SPINNER_SIZE: f32 = 10.;
const SPINNER_PERIOD: Duration = Duration::from_millis(900);

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum QueueEditRowState {
    Owned { resolving: bool },
    Held { edit_id: String, cancelling: bool },
    Preparing,
    Available { enabled: bool },
}

impl QueueEditRowState {
    /// Full labels plus source control padding, measured with the rendered font.
    pub(crate) fn natural_width(&self, window: &Window) -> f32 {
        self.layout(f32::INFINITY, window).total
    }

    /// The smallest control-group proposal that keeps every label's words
    /// intact. Labels may wrap at spaces, preserving source type and padding.
    pub(crate) fn minimum_word_width(&self, window: &Window) -> f32 {
        match self {
            Self::Owned { .. } => {
                CAPTION_SIZE
                    + LABEL_GAP
                    + text_metrics(
                        "Editing in the composer",
                        CAPTION_SIZE,
                        FontWeight::NORMAL,
                        window,
                    )
                    .word_width
            }
            Self::Held { .. } => {
                CAPTION_SIZE
                    + LABEL_GAP
                    + text_metrics("Edit open", CAPTION_SIZE, FontWeight::NORMAL, window).word_width
                    + text_metrics("Resume Edit", GHOST_SIZE, FontWeight::MEDIUM, window).word_width
                    + text_metrics("Cancel Edit", GHOST_SIZE, FontWeight::MEDIUM, window).word_width
                    + 4. * GHOST_PADDING_X
                    + 2. * ROW_GAP
            }
            Self::Preparing | Self::Available { .. } => CONTROL_SIZE,
        }
    }

    /// Height of this control group alone, at the same proposal passed to
    /// render_queue_edit_controls. Row minimum, row insets, and a flowed
    /// primary line belong to the caller and are not counted here.
    pub(crate) fn rendered_height(&self, available_width: f32, window: &Window) -> f32 {
        let layout = self.layout(available_width, window);
        let status_height = self.status().map_or(0., |(label, _)| {
            wrapped_text_height(
                label,
                CAPTION_SIZE,
                FontWeight::NORMAL,
                (layout.widths[0] - CAPTION_SIZE - LABEL_GAP).max(0.),
                window,
            )
            .max(CAPTION_SIZE)
        });
        match self {
            Self::Owned { .. } => status_height,
            Self::Held { .. } => ["Resume Edit", "Cancel Edit"]
                .into_iter()
                .enumerate()
                .map(|(index, label)| {
                    let metrics = text_metrics(label, GHOST_SIZE, FontWeight::MEDIUM, window);
                    let outer_width =
                        layout.widths[index + 1].min(f32::from(ghost_size(metrics).width));
                    wrapped_text_height(
                        label,
                        GHOST_SIZE,
                        FontWeight::MEDIUM,
                        (outer_width - 2. * GHOST_PADDING_X).max(0.),
                        window,
                    ) + 2. * GHOST_PADDING_Y
                })
                .fold(status_height, f32::max),
            Self::Preparing => SPINNER_SIZE,
            Self::Available { .. } => CONTROL_SIZE,
        }
    }

    fn layout(&self, available: f32, window: &Window) -> ControlLayout {
        match self {
            Self::Owned { .. } => {
                let status = text_metrics(
                    "Editing in the composer",
                    CAPTION_SIZE,
                    FontWeight::NORMAL,
                    window,
                );
                allocate_controls(
                    [status.width, 0., 0.],
                    [status.word_width, 0., 0.],
                    [CAPTION_SIZE + LABEL_GAP, 0., 0.],
                    0.,
                    available,
                )
            }
            Self::Held { .. } => {
                let status = text_metrics("Edit open", CAPTION_SIZE, FontWeight::NORMAL, window);
                let resume = text_metrics("Resume Edit", GHOST_SIZE, FontWeight::MEDIUM, window);
                let cancel = text_metrics("Cancel Edit", GHOST_SIZE, FontWeight::MEDIUM, window);
                allocate_controls(
                    [status.width, resume.width, cancel.width],
                    [status.word_width, resume.word_width, cancel.word_width],
                    [
                        CAPTION_SIZE + LABEL_GAP,
                        2. * GHOST_PADDING_X,
                        2. * GHOST_PADDING_X,
                    ],
                    2. * ROW_GAP,
                    available,
                )
            }
            Self::Preparing | Self::Available { .. } => ControlLayout {
                widths: [CONTROL_SIZE, 0., 0.],
                total: CONTROL_SIZE,
            },
        }
    }

    fn status(&self) -> Option<(&'static str, &'static str)> {
        match self {
            Self::Owned { .. } => Some(("Editing in the composer", "pencil.line")),
            Self::Held { .. } => Some(("Edit open", "pause.circle")),
            Self::Preparing | Self::Available { .. } => None,
        }
    }
}

/// Measured placement for an unowned Held row. Other states keep their existing
/// one-line layout; callers must not use this as a general responsive toolbar.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct HeldRowPlan {
    pub(crate) second_line: bool,
    pub(crate) controls_width: f32,
    pub(crate) preview_width: f32,
    /// False explicitly identifies a pane too narrow even after the approved
    /// second-line flow. It does not authorize clipped or omitted actions.
    pub(crate) whole_words_fit: bool,
}

// Source row chrome: 14pt ordinal/steering slot, 22pt info and remove controls,
// and 8pt gaps. Outer panel margins, padding, and border are already excluded
// from content_width and must not be charged again.
const ROW_INDEX_WIDTH: f32 = 14.;
const INLINE_ROW_CHROME: f32 = ROW_INDEX_WIDTH + 2. * CONTROL_SIZE + 4. * ROW_GAP;
const FIRST_LINE_CHROME: f32 = ROW_INDEX_WIDTH + CONTROL_SIZE + 2. * ROW_GAP;
const SECOND_LINE_CHROME: f32 = CONTROL_SIZE + ROW_GAP;

/// Keep wide rows unchanged. Use the user-approved second line only when the
/// measured preview requirement and complete control words cannot coexist.
/// On that line, the only trailing furniture is Remove plus one source gap.
/// A 309pt pane has 251pt content, giving controls 221pt on the second line;
/// a 149pt pane has only 91pt content, which is still physically insufficient.
pub(crate) fn held_row_plan(
    content_width: f32,
    preview_requirement: f32,
    natural_controls_width: f32,
    minimum_word_controls_width: f32,
) -> HeldRowPlan {
    let finite_width = |width: f32| if width.is_finite() { width.max(0.) } else { 0. };
    let content = finite_width(content_width);
    let preview = finite_width(preview_requirement);
    let minimum = finite_width(minimum_word_controls_width);
    let natural = finite_width(natural_controls_width).max(minimum);
    let second_line = content < INLINE_ROW_CHROME + preview + minimum;
    let controls_width = if second_line {
        (content - SECOND_LINE_CHROME).max(0.).min(natural)
    } else {
        (content - INLINE_ROW_CHROME - preview).max(0.).min(natural)
    };
    let preview_width = if second_line {
        (content - FIRST_LINE_CHROME).max(0.)
    } else {
        (content - INLINE_ROW_CHROME - controls_width).max(0.)
    };
    HeldRowPlan {
        second_line,
        controls_width,
        preview_width,
        whole_words_fit: controls_width + f32::EPSILON * natural.max(1.) >= minimum,
    }
}

fn font_family() -> &'static str {
    if cfg!(target_os = "macos") {
        ".SystemUIFont"
    } else {
        "DejaVu Sans"
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct TextMetrics {
    width: f32,
    word_width: f32,
    line_height: f32,
}

fn text_metrics(text: &str, size: f32, weight: FontWeight, window: &Window) -> TextMetrics {
    let mut font = gpui::font(font_family());
    font.weight = weight;
    let shape = |text: &str| {
        window.text_system().shape_line(
            text.to_owned().into(),
            px(size),
            &[TextRun {
                len: text.len(),
                font: font.clone(),
                color: black(),
                background_color: None,
                underline: None,
                strikethrough: None,
            }],
            None,
        )
    };
    let line = shape(text);
    let width = f32::from(line.width).ceil();
    TextMetrics {
        width,
        // Measure whole words with the same shaping/fallback font system.
        // Narrower proposals may wrap within a word; no byte slicing or
        // character-count estimate is used for Unicode or fallback glyphs.
        word_width: text
            .split_whitespace()
            .map(|word| f32::from(shape(word).width).ceil())
            .fold(0., f32::max)
            .min(width),
        line_height: f32::from(line.ascent + line.descent).ceil(),
    }
}

/// Match GPUI TextLayout: shape the full label with normal whitespace and no
/// line clamp, then sum WrappedLine::size using the explicit renderer line
/// height. Font shaping failure has the same zero text-size result as GPUI;
/// there is no guessed line-count fallback.
fn wrapped_text_height(
    label: &str,
    font_size: f32,
    weight: FontWeight,
    text_width: f32,
    window: &Window,
) -> f32 {
    let metrics = text_metrics(label, font_size, weight, window);
    let mut font = gpui::font(font_family());
    font.weight = weight;
    window
        .text_system()
        .shape_text(
            label.to_owned().into(),
            px(font_size),
            &[TextRun {
                len: label.len(),
                font,
                color: black(),
                background_color: None,
                underline: None,
                strikethrough: None,
            }],
            Some(px(text_width.max(0.))),
            None,
        )
        .map_or(0., |lines| {
            lines
                .iter()
                .map(|line| f32::from(line.size(px(metrics.line_height)).height))
                .sum()
        })
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct ControlLayout {
    /// Status, Resume Edit, Cancel Edit, including each one's fixed padding.
    widths: [f32; 3],
    total: f32,
}

/// Distribute only text room. Fixed source padding, icon slot, and gaps are
/// charged exactly once. Keep complete words whenever the proposal allows;
/// below that, GPUI wraps full labels within words and the row grows vertically.
/// A proposal below fixed chrome alone cannot fit source controls; retain that
/// explicit floor rather than hiding actions or manufacturing negative sizes.
fn allocate_controls(
    natural: [f32; 3],
    words: [f32; 3],
    fixed: [f32; 3],
    gaps: f32,
    available: f32,
) -> ControlLayout {
    let sanitize = |width: f32| if width.is_finite() { width.max(0.) } else { 0. };
    let natural = natural.map(sanitize);
    let words = std::array::from_fn::<_, 3, _>(|i| sanitize(words[i]).min(natural[i]));
    let fixed = fixed.map(sanitize);
    let chrome = fixed.iter().sum::<f32>() + sanitize(gaps);
    let full = natural.iter().sum::<f32>();
    let available = if available == f32::INFINITY {
        chrome + full
    } else {
        sanitize(available)
    };
    let text_room = (available - chrome).clamp(0., full);
    let word_total = words.iter().sum::<f32>();
    let text_widths = if text_room < word_total && word_total > 0. {
        words.map(|word| word * text_room / word_total)
    } else {
        let surplus = full - word_total;
        let scale = if surplus > 0. {
            (text_room - word_total) / surplus
        } else {
            0.
        };
        std::array::from_fn(|i| words[i] + (natural[i] - words[i]) * scale)
    };
    ControlLayout {
        widths: std::array::from_fn(|i| fixed[i] + text_widths[i]),
        total: chrome + text_room,
    }
}

fn ghost_size(metrics: TextMetrics) -> Size<Pixels> {
    size(
        px(metrics.width + GHOST_PADDING_X * 2.),
        px(metrics.line_height + GHOST_PADDING_Y * 2.),
    )
}

fn fill_strong(p: Palette) -> Hsla {
    // Color.piFillStrong, Design/DesignSystem.swift.
    rgba(if p.dark { 0xffffff17 } else { 0x00000013 }).into()
}

fn queue_icon_frame(id: impl Into<ElementId>, enabled: bool, p: Palette) -> Stateful<Div> {
    div()
        .id(id)
        .size(px(CONTROL_SIZE))
        .flex_shrink_0()
        .flex()
        .items_center()
        .justify_center()
        .rounded_full()
        .opacity(if enabled { 1. } else { ICON_DISABLED_OPACITY })
        .when(enabled, |button| {
            button
                .cursor_pointer()
                .hover(move |style| style.bg(fill_strong(p)))
        })
}

fn ghost_button(
    id: SharedString,
    label: &'static str,
    enabled: bool,
    p: Palette,
    width: f32,
    window: &Window,
) -> Stateful<Div> {
    let metrics = text_metrics(label, GHOST_SIZE, FontWeight::MEDIUM, window);
    div()
        .id(id.clone())
        .debug_selector(move || id.to_string())
        .w(px(width.min(f32::from(ghost_size(metrics).width))))
        .min_w_0()
        .flex_shrink_0()
        .px(px(GHOST_PADDING_X))
        .py(px(GHOST_PADDING_Y))
        .rounded_full()
        .font_family(font_family())
        .font_weight(FontWeight::MEDIUM)
        .text_size(px(GHOST_SIZE))
        .line_height(px(metrics.line_height))
        .whitespace_normal()
        .text_color(rgb(p.secondary))
        .opacity(if enabled { 1. } else { GHOST_DISABLED_OPACITY })
        .when(enabled, |button| {
            button
                .cursor_pointer()
                .hover(move |style| style.bg(p.fill()))
                .active(move |style| style.bg(fill_strong(p)))
        })
        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
        .child(label)
}

impl AgentView {
    /// Queue-local PiIconButton: a 22pt circle, a 10.12pt geometric symbol,
    /// and one hover style. Other application icon buttons remain unchanged.
    pub(crate) fn queue_icon_button(
        &self,
        id: impl Into<ElementId>,
        symbol: &'static str,
        enabled: bool,
    ) -> Stateful<Div> {
        queue_icon_frame(id, enabled, self.palette).child(self.icon(symbol, CONTROL_ICON_SIZE))
    }

    pub(crate) fn render_queue_edit_controls(
        &self,
        chat_id: &str,
        turn_id: &str,
        state: QueueEditRowState,
        available_width: f32,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Div {
        let p = self.palette;
        let layout = state.layout(available_width, window);
        // The preview yields room first. Complete labels then wrap within
        // measured proposals; no fixed row height or clipped status container.
        let mut controls = div()
            .w(px(layout.total))
            .flex()
            .items_center()
            .gap(px(ROW_GAP))
            .flex_shrink_0();
        if let Some((label, symbol)) = state.status() {
            let metrics = text_metrics(label, CAPTION_SIZE, FontWeight::NORMAL, window);
            let selector = format!("queue-editing-{turn_id}");
            controls = controls.child(
                div()
                    .debug_selector(move || selector)
                    .flex()
                    .items_center()
                    .gap(px(LABEL_GAP))
                    .w(px(layout.widths[0]))
                    .min_w_0()
                    .flex_shrink_0()
                    .font_family(font_family())
                    .font_weight(FontWeight::NORMAL)
                    .text_size(px(CAPTION_SIZE))
                    .line_height(px(metrics.line_height))
                    .text_color(rgb(p.accent))
                    .child(
                        self.icon(symbol, CAPTION_SIZE)
                            .flex_shrink_0()
                            .text_color(rgb(p.accent)),
                    )
                    .child(
                        div()
                            .w(px((layout.widths[0] - CAPTION_SIZE - LABEL_GAP).max(0.)))
                            .min_w_0()
                            .flex_shrink_0()
                            .whitespace_normal()
                            .child(label),
                    ),
            );
        }
        match state {
            QueueEditRowState::Owned { .. } => controls,
            QueueEditRowState::Held {
                edit_id,
                cancelling,
            } => {
                let resume_chat = chat_id.to_owned();
                let resume_turn = turn_id.to_owned();
                let resume_edit = edit_id.clone();
                let cancel_chat = chat_id.to_owned();
                let cancel_turn = turn_id.to_owned();
                controls
                    .child(
                        ghost_button(
                            format!("queue-resume-edit-{turn_id}").into(),
                            "Resume Edit",
                            !cancelling,
                            p,
                            layout.widths[1],
                            window,
                        )
                        .when(!cancelling, |button| {
                            button.on_click(cx.listener(move |view, _, window, cx| {
                                view.begin_queued_edit(
                                    &resume_chat,
                                    &resume_turn,
                                    Some(resume_edit.clone()),
                                    window,
                                    cx,
                                );
                                cx.stop_propagation();
                            }))
                        }),
                    )
                    .child(
                        // The source keeps Cancel Edit enabled during cancel;
                        // the operation layer owns duplicate-click suppression.
                        ghost_button(
                            format!("queue-cancel-edit-{turn_id}").into(),
                            "Cancel Edit",
                            true,
                            p,
                            layout.widths[2],
                            window,
                        )
                        .on_click(cx.listener(move |view, _, _, cx| {
                            view.cancel_held_edit(&cancel_chat, &cancel_turn, &edit_id, cx);
                            cx.stop_propagation();
                        })),
                    )
            }
            QueueEditRowState::Preparing => controls.child(
                div()
                    .id(SharedString::from(format!(
                        "queue-edit-preparing-{turn_id}"
                    )))
                    .debug_selector(|| "queue-edit-preparing".into())
                    .w(px(CONTROL_SIZE))
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .tooltip(move |_, cx| {
                        cx.new(|_| EditHint {
                            p,
                            text: "Pausing the queue and reading the whole message",
                        })
                        .into()
                    })
                    .child(self.icon("spinner", SPINNER_SIZE).with_animation(
                        SharedString::from(format!("queue-edit-spinner-{chat_id}-{turn_id}")),
                        Animation::new(SPINNER_PERIOD).repeat(),
                        |icon, progress| {
                            icon.with_transformation(Transformation::rotate(percentage(progress)))
                        },
                    )),
            ),
            QueueEditRowState::Available { enabled } => {
                let chat_id = chat_id.to_owned();
                let turn = turn_id.to_owned();
                controls.child(
                    self.queue_icon_button(
                        SharedString::from(format!("queue-edit-{turn_id}")),
                        "pencil",
                        enabled,
                    )
                    .debug_selector(|| "queue-edit-available".into())
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .tooltip(move |_, cx| {
                        cx.new(|_| EditHint {
                            p,
                            text: "Edit queued message",
                        })
                        .into()
                    })
                    .when(enabled, |button| {
                        button.on_click(cx.listener(move |view, _, window, cx| {
                            view.begin_queued_edit(&chat_id, &turn, None, window, cx);
                            cx.stop_propagation();
                        }))
                    }),
                )
            }
        }
    }
}

struct EditHint {
    p: Palette,
    text: &'static str,
}
impl Render for EditHint {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .px(px(8.))
            .py(px(5.))
            .rounded(px(6.))
            .bg(rgb(self.p.surface))
            .text_color(rgb(self.p.ink))
            .text_size(px(CAPTION_SIZE))
            .child(self.text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::TestAppContext;

    #[test]
    fn source_owned_and_unowned_status_are_distinct_during_resolution() {
        for resolving in [false, true] {
            assert_eq!(
                QueueEditRowState::Owned { resolving }.status(),
                Some(("Editing in the composer", "pencil.line")),
            );
            assert_eq!(
                QueueEditRowState::Held {
                    edit_id: "edit-a".into(),
                    cancelling: resolving
                }
                .status(),
                Some(("Edit open", "pause.circle")),
            );
        }
        assert_eq!(QueueEditRowState::Preparing.status(), None);
        for enabled in [false, true] {
            assert_eq!(QueueEditRowState::Available { enabled }.status(), None);
        }
    }

    #[test]
    fn ghost_control_keeps_source_padding_around_natural_text_metrics() {
        assert_eq!(
            ghost_size(TextMetrics {
                width: 73.,
                word_width: 41.,
                line_height: 15.
            }),
            size(px(93.), px(27.)),
        );
        assert_eq!(
            ghost_size(TextMetrics {
                width: 89.,
                word_width: 57.,
                line_height: 19.
            }),
            size(px(109.), px(31.)),
        );
        assert_eq!(GHOST_SIZE, 12.5);
        assert_eq!(CAPTION_SIZE, 11.5);
        assert_eq!(GHOST_DISABLED_OPACITY, 0.4);
        assert_eq!(ICON_DISABLED_OPACITY, 0.35);
    }

    #[test]
    fn full_and_constrained_budgets_charge_each_source_inset_once() {
        let natural = [55., 79., 71.];
        let words = [30., 50., 44.];
        let fixed = [15.5, 20., 20.];
        let layout = allocate_controls(natural, words, fixed, 16., 400.);
        assert_eq!(
            layout,
            ControlLayout {
                widths: [70.5, 99., 91.],
                total: 276.5
            }
        );
        for budget in [276.5, 220., 195.5, 161., 101.5, 71.5] {
            let layout = allocate_controls(natural, words, fixed, 16., budget);
            assert!((layout.total - budget).abs() < 0.001);
            assert!((layout.widths.iter().sum::<f32>() + 16. - budget).abs() < 0.001);
            for i in 0..3 {
                assert!(layout.widths[i] >= fixed[i]);
                assert!(layout.widths[i] <= fixed[i] + natural[i]);
                if budget >= 195.5 {
                    assert!(layout.widths[i] + 0.001 >= fixed[i] + words[i]);
                }
            }
        }
    }

    #[test]
    fn held_row_flows_only_below_the_measured_preview_and_word_threshold() {
        let natural = 276.5;
        let words = 195.5;
        let preview = 46.;
        let threshold = 90. + preview + words;
        let wide = held_row_plan(560., preview, natural, words);
        assert_eq!(
            wide,
            HeldRowPlan {
                second_line: false,
                controls_width: natural,
                preview_width: 560. - 90. - natural,
                whole_words_fit: true,
            }
        );
        let exact = held_row_plan(threshold, preview, natural, words);
        assert!(!exact.second_line);
        assert_eq!(exact.controls_width, words);
        assert_eq!(exact.preview_width, preview);
        assert!(exact.whole_words_fit);
        assert!(held_row_plan(threshold - 0.25, preview, natural, words).second_line);

        // 309pt ordinary half-split minus 58pt panel chrome, already excluded.
        let split = held_row_plan(251., preview, natural, words);
        assert_eq!(
            split,
            HeldRowPlan {
                second_line: true,
                controls_width: 221.,
                preview_width: 199.,
                whole_words_fit: true,
            }
        );
        assert_eq!(split.controls_width + 22. + 8., 251.);
        assert_eq!(split.preview_width + 14. + 22. + 2. * 8., 251.);
    }

    #[test]
    fn second_line_does_not_claim_to_fix_the_extreme_149pt_pane() {
        let extreme = held_row_plan(149. - 58., 46., 276.5, 195.5);
        assert!(extreme.second_line);
        assert_eq!(extreme.controls_width, 61.);
        assert_eq!(extreme.preview_width, 39.);
        assert!(!extreme.whole_words_fit);
        assert!(extreme.controls_width < 71.5); // Even source control chrome.
        for content in [0., -1., f32::NAN, f32::INFINITY] {
            let plan = held_row_plan(content, 46., 276.5, 195.5);
            assert!(plan.second_line);
            assert_eq!(plan.controls_width, 0.);
            assert_eq!(plan.preview_width, 0.);
            assert!(!plan.whole_words_fit);
        }
    }

    #[gpui::test]
    fn measured_word_minima_survive_all_sufficient_control_budgets(cx: &mut TestAppContext) {
        cx.add_empty_window().update(|window, _| {
            let states = [
                QueueEditRowState::Owned { resolving: false },
                QueueEditRowState::Held { edit_id: "held".into(), cancelling: false },
                QueueEditRowState::Preparing,
                QueueEditRowState::Available { enabled: true },
            ];
            for state in states {
                let minimum = state.minimum_word_width(window);
                let natural = state.natural_width(window);
                assert!(minimum.is_finite() && minimum > 0.);
                assert!(natural >= minimum);
                let word_layout = state.layout(minimum, window);
                for budget in [minimum, (minimum + natural) / 2., natural, natural + 100.] {
                    let layout = state.layout(budget, window);
                    assert!(layout.total <= budget + 0.001);
                    for index in 0..3 {
                        assert!(layout.widths[index] + 0.001 >= word_layout.widths[index]);
                    }
                }
                if matches!(state, QueueEditRowState::Held { .. }) {
                    let preview = text_metrics("held", 13., FontWeight::NORMAL, window).width;
                    let plan = held_row_plan(251., preview, natural, minimum);
                    assert!(plan.second_line);
                    assert_eq!(plan.controls_width, 221.);
                    assert!(plan.whole_words_fit);
                    let allocated = state.layout(plan.controls_width, window);
                    for index in 0..3 {
                        assert!(allocated.widths[index] + 0.001 >= word_layout.widths[index]);
                    }
                    let status = text_metrics("open", CAPTION_SIZE, FontWeight::NORMAL, window);
                    let resume = text_metrics("Resume", GHOST_SIZE, FontWeight::MEDIUM, window);
                    let cancel = text_metrics("Cancel", GHOST_SIZE, FontWeight::MEDIUM, window);
                    assert!(allocated.widths[0] - CAPTION_SIZE - LABEL_GAP + 0.001 >= status.width);
                    assert!(allocated.widths[1] - 2. * GHOST_PADDING_X + 0.001 >= resume.width);
                    assert!(allocated.widths[2] - 2. * GHOST_PADDING_X + 0.001 >= cancel.width);
                    eprintln!("Held controls: natural {natural}pt, whole-word minimum {minimum}pt, split allocation {}pt", plan.controls_width);
                }
            }
        });
    }

    #[gpui::test]
    fn rendered_height_uses_shaped_single_and_two_line_ghost_labels(cx: &mut TestAppContext) {
        cx.add_empty_window().update(|window, _| {
            let state = QueueEditRowState::Held {
                edit_id: "held".into(),
                cancelling: false,
            };
            let caption = text_metrics("Edit open", CAPTION_SIZE, FontWeight::NORMAL, window);
            let resume = text_metrics("Resume Edit", GHOST_SIZE, FontWeight::MEDIUM, window);
            let cancel = text_metrics("Cancel Edit", GHOST_SIZE, FontWeight::MEDIUM, window);
            let single_line_height = caption
                .line_height
                .max(CAPTION_SIZE)
                .max(resume.line_height + 2. * GHOST_PADDING_Y)
                .max(cancel.line_height + 2. * GHOST_PADDING_Y);
            assert_eq!(
                state.rendered_height(state.natural_width(window), window),
                single_line_height
            );

            // At the measured word minimum, each of these two-word labels
            // wraps at its space into exactly two actual shaped lines.
            assert_eq!(
                wrapped_text_height(
                    "Resume Edit",
                    GHOST_SIZE,
                    FontWeight::MEDIUM,
                    resume.word_width,
                    window,
                ),
                2. * resume.line_height
            );
            assert_eq!(
                wrapped_text_height(
                    "Cancel Edit",
                    GHOST_SIZE,
                    FontWeight::MEDIUM,
                    cancel.word_width,
                    window,
                ),
                2. * cancel.line_height
            );
            let two_line_height = (2. * caption.line_height)
                .max(CAPTION_SIZE)
                .max(2. * resume.line_height + 2. * GHOST_PADDING_Y)
                .max(2. * cancel.line_height + 2. * GHOST_PADDING_Y);
            assert_eq!(
                state.rendered_height(state.minimum_word_width(window), window),
                two_line_height
            );
            assert!(two_line_height > single_line_height);

            let plan = held_row_plan(
                251.,
                46.,
                state.natural_width(window),
                state.minimum_word_width(window),
            );
            assert!(plan.second_line && plan.whole_words_fit);
            let flowed_height = state.rendered_height(plan.controls_width, window);
            assert!(flowed_height >= single_line_height);
            assert!(flowed_height <= two_line_height);
        });
    }

    #[gpui::test]
    fn rendered_height_keeps_status_icon_and_nontext_controls_intrinsic(cx: &mut TestAppContext) {
        cx.add_empty_window().update(|window, _| {
            let owned = QueueEditRowState::Owned { resolving: false };
            let metrics = text_metrics(
                "Editing in the composer",
                CAPTION_SIZE,
                FontWeight::NORMAL,
                window,
            );
            assert_eq!(
                owned.rendered_height(owned.natural_width(window), window),
                metrics.line_height.max(CAPTION_SIZE)
            );
            let narrow_height = owned.rendered_height(owned.minimum_word_width(window), window);
            assert!(narrow_height > metrics.line_height);
            assert_eq!(
                narrow_height,
                wrapped_text_height(
                    "Editing in the composer",
                    CAPTION_SIZE,
                    FontWeight::NORMAL,
                    metrics.word_width,
                    window,
                )
                .max(CAPTION_SIZE)
            );
            assert_eq!(
                QueueEditRowState::Preparing.rendered_height(22., window),
                10.
            );
            for enabled in [false, true] {
                assert_eq!(
                    QueueEditRowState::Available { enabled }.rendered_height(22., window),
                    22.
                );
            }
        });
    }

    #[test]
    fn impossible_proposals_keep_an_explicit_fixed_chrome_floor() {
        for budget in [0., -10., f32::NAN, f32::NEG_INFINITY, 1.] {
            assert_eq!(
                allocate_controls(
                    [55., 79., 71.],
                    [30., 50., 44.],
                    [15.5, 20., 20.],
                    16.,
                    budget
                ),
                ControlLayout {
                    widths: [15.5, 20., 20.],
                    total: 71.5
                },
            );
        }
    }

    #[gpui::test]
    fn word_minima_and_unicode_fallback_use_the_same_shaper(cx: &mut TestAppContext) {
        cx.add_empty_window().update(|window, _| {
            for label in ["Resume Edit", "编辑 消息", "Éditer 日本語", "👩🏽‍💻 edit"]
            {
                let metrics = text_metrics(label, GHOST_SIZE, FontWeight::MEDIUM, window);
                let measured_word = label
                    .split_whitespace()
                    .map(|word| text_metrics(word, GHOST_SIZE, FontWeight::MEDIUM, window).width)
                    .fold(0., f32::max)
                    .min(metrics.width);
                assert_eq!(metrics.word_width, measured_word);
                assert!(metrics.width.is_finite() && metrics.width > 0.);
                assert!(metrics.line_height.is_finite() && metrics.line_height > 0.);
            }
            let state = QueueEditRowState::Held {
                edit_id: "edit-a".into(),
                cancelling: false,
            };
            let natural = state.natural_width(window);
            assert_eq!(state.layout(natural, window).total, natural);
            assert!((state.layout(161., window).total - 161.).abs() < 0.001);
            eprintln!("Held controls shaped natural width: {natural}pt");
        });
    }

    #[test]
    fn queue_icon_preserves_source_hit_area_glyph_scale_and_disabled_opacity() {
        let p = Palette::for_appearance(gpui::WindowAppearance::Light);
        for enabled in [false, true] {
            let mut button = queue_icon_frame("queue-test-icon", enabled, p);
            assert_eq!(button.style().size.width, Some(px(22.).into()));
            assert_eq!(button.style().size.height, Some(px(22.).into()));
            assert_eq!(
                button.style().opacity,
                Some(if enabled { 1. } else { 0.35 })
            );
        }
        assert!((CONTROL_ICON_SIZE - 10.12).abs() < 0.001);
    }

    #[test]
    fn preparing_uses_source_mini_spinner_inside_the_regular_edit_slot() {
        assert_eq!(CONTROL_SIZE, 22.);
        assert_eq!(SPINNER_SIZE, 10.);
        assert_eq!(SPINNER_PERIOD, Duration::from_millis(900));
        assert_eq!(ROW_GAP, 8.);
    }
}
