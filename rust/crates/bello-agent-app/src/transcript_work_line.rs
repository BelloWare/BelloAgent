//! The one line every piece of work reads as in Swift's transcript
//! (`TranscriptNativeWorkLine`): `[icon] Title · summary   suffix  0.4s`, 24
//! points tall, the whole line a button. Under the pointer the icon gives way
//! to the chevron and the line takes the panel; an open row is the chevron
//! outright. A failed (red) or stopped (amber) row shows its dot in the icon's
//! place, a running one tints its icon with the accent. A row whose summary is
//! its file's path opens the file from the summary.
use gpui::{
    Animation, AnimationExt, App, AppContext, ElementId, Hsla, InteractiveElement, IntoElement,
    ParentElement, SharedString, StatefulInteractiveElement, Styled, Transformation, Window, div,
    linear_color_stop, linear_gradient, prelude::FluentBuilder, px, radians, relative, rgb, rgba,
    svg,
};

/// The line box every work row shares, and where what opens under it starts:
/// the 16-point leading box and the 6 after it (`TranscriptRowChrome`).
pub(crate) const HEIGHT: f32 = 24.;
const LEADING: f32 = 16.;
pub(crate) const INDENT: f32 = LEADING + 6.;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum WorkState {
    Ok,
    Running,
    Stopped,
    Failed,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct WorkLine {
    pub icon: &'static str,
    pub title: SharedString,
    pub summary: SharedString,
    /// The change size and an unknown outcome, outside the ellipsized summary.
    pub suffix: Option<SharedString>,
    pub state: WorkState,
    pub expandable: bool,
    pub open: bool,
    pub trailing: Option<SharedString>,
    /// A line still being written: its end is the part kept in view.
    pub follow: bool,
    /// What the pointer says over the line; the summary when unset.
    pub help: Option<SharedString>,
}

impl WorkLine {
    /// Swift's `help ?? summary`, and nothing when that is empty.
    pub(crate) fn tooltip(&self) -> Option<SharedString> {
        let help = self.help.clone().unwrap_or_else(|| self.summary.clone());
        (!help.is_empty()).then_some(help)
    }
}

/// One sweep of the running shimmer (`TranscriptRowChrome.shimmerSeconds`),
/// and the band's width.
const SHIMMER: std::time::Duration = std::time::Duration::from_millis(2600);
const SHIMMER_BAND: f32 = 300.;

/// Swift's transcript colours, light and dark.
struct Colors {
    text: Hsla,
    muted: Hsla,
    faint: Hsla,
    accent: Hsla,
    danger: Hsla,
    warning: Hsla,
    panel: Hsla,
    panel_strong: Hsla,
}

impl Colors {
    fn new(palette: &crate::Palette) -> Self {
        let pick =
            |light: u32, dark: u32| -> Hsla { rgb(if palette.dark { dark } else { light }).into() };
        Self {
            text: rgb(palette.ink).into(),
            muted: pick(0x6e6a61, 0xa9a59b),
            faint: pick(0x9b968c, 0x78746b),
            accent: rgb(palette.accent).into(),
            danger: rgb(palette.danger).into(),
            warning: pick(0xb97a1e, 0xe3b15c),
            panel: rgba(if palette.dark { 0xffffff0b } else { 0x00000009 }).into(),
            panel_strong: rgba(if palette.dark { 0xffffff14 } else { 0x0000000f }).into(),
        }
    }
}

/// What a row's file link does when its summary is pressed.
pub(crate) type Link = Box<dyn Fn(&mut Window, &mut App)>;

/// The colours a work row's card is drawn in (`TranscriptNSPalette`).
pub(crate) struct CardColors {
    pub text: Hsla,
    pub muted: Hsla,
    pub faint: Hsla,
    pub hair: Hsla,
    pub code_background: Hsla,
    pub danger: Hsla,
    pub warning: Hsla,
    pub success: Hsla,
    pub panel: Hsla,
    pub hair_strong: Hsla,
    pub accent: Hsla,
}

pub(crate) fn card_colors(palette: &crate::Palette) -> CardColors {
    let colors = Colors::new(palette);
    let dark = palette.dark;
    CardColors {
        text: colors.text,
        muted: colors.muted,
        danger: colors.danger,
        warning: colors.warning,
        success: rgb(if dark { 0x7cc48f } else { 0x3d8a57 }).into(),
        faint: colors.faint,
        hair: rgba(if dark { 0xffffff17 } else { 0x00000014 }).into(),
        code_background: rgb(if dark { 0x211d1a } else { 0xf6f1ea }).into(),
        panel: colors.panel,
        hair_strong: rgba(if dark { 0xffffff29 } else { 0x00000024 }).into(),
        accent: colors.accent,
    }
}

pub(crate) fn work_line(
    id: impl Into<ElementId>,
    line: &WorkLine,
    palette: &crate::Palette,
    toggle: impl Fn(&mut Window, &mut App) + 'static,
    link: Option<Link>,
) -> impl IntoElement {
    let id = id.into();
    let group = SharedString::from(format!("work-line-{id}"));
    // Each piece answers to the line's id and its name, for checks.
    let piece = |name: &str| format!("{id}-{name}");
    let (title_selector, summary_selector) = (piece("title"), piece("summary"));
    let (suffix_selector, trailing_selector) = (piece("suffix"), piece("trailing"));
    let colors = Colors::new(palette);
    let marked = matches!(line.state, WorkState::Failed | WorkState::Stopped);
    let icon_tint = if line.state == WorkState::Running {
        colors.accent
    } else {
        colors.faint
    };
    // The leading box: the dot, or the icon and the chevron it becomes.
    let mut leading = div()
        .relative()
        .flex_none()
        .size(px(LEADING))
        .flex()
        .items_center()
        .justify_center();
    if marked {
        let dot = if line.state == WorkState::Failed {
            colors.danger
        } else {
            colors.warning
        };
        leading = leading.child(div().size(px(7.)).rounded_full().bg(dot));
    } else {
        let hides = line.expandable;
        leading = leading.child(
            svg()
                .path(line.icon)
                .size(px(12.))
                .text_color(icon_tint)
                .when(hides && line.open, |icon| icon.opacity(0.))
                .when(hides, |icon| {
                    icon.group_hover(group.clone(), |icon| icon.opacity(0.))
                }),
        );
    }
    if line.expandable {
        leading = leading.child(
            div()
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .child(
                    svg()
                        .path("chevron.down")
                        .size(px(11.))
                        .text_color(colors.faint)
                        .with_transformation(Transformation::rotate(radians(if line.open {
                            0.
                        } else {
                            -std::f32::consts::FRAC_PI_2
                        })))
                        .when(!line.open, |chevron| chevron.opacity(0.))
                        .group_hover(group.clone(), {
                            let text = colors.text;
                            move |chevron| chevron.opacity(1.).text_color(text)
                        }),
                ),
        );
    }
    let shimmer = (line.state == WorkState::Running).then(|| shimmer(&id, colors.panel_strong));
    let shimmer = shimmer.map(IntoElement::into_any_element);
    let tooltip = line.tooltip();
    let mut row = div()
        .id(id)
        .group(group.clone())
        .relative()
        .overflow_hidden()
        .h(px(HEIGHT))
        .w_full()
        .min_w_0()
        .flex()
        .flex_row()
        .items_center()
        .rounded(px(6.))
        // Under the line's marks and words, as Swift layers it.
        .children(shimmer)
        .child(div().flex_none().w(px(INDENT)).child(leading))
        .child(
            div()
                .flex_none()
                .debug_selector(move || title_selector)
                .text_size(px(13.))
                .text_color(colors.muted)
                .group_hover(group.clone(), {
                    let text = colors.text;
                    move |title| title.text_color(text)
                })
                .child(line.title.clone()),
        );
    if let Some(help) = tooltip {
        let palette = *palette;
        row = row.tooltip(move |_, cx| {
            cx.new(|_| crate::composer_skills::SkillHint {
                text: help.to_string(),
                palette,
            })
            .into()
        });
    }
    if line.expandable {
        let panel = colors.panel;
        row = row
            .cursor_pointer()
            .hover(move |row| row.bg(panel))
            .on_click(move |_, window, cx| toggle(window, cx));
    }
    if !line.summary.is_empty() {
        let summary_color = if line.state == WorkState::Failed {
            colors.danger
        } else {
            colors.faint
        };
        // The separator's 18 points hold a 2-point dot 8 points in.
        row = row
            .child(
                div().flex_none().w(px(18.)).flex().items_center().child(
                    div()
                        .ml(px(8.))
                        .size(px(2.))
                        .rounded_full()
                        .bg(colors.faint),
                ),
            )
            .child(
                div()
                    .debug_selector(move || summary_selector)
                    .min_w_0()
                    .flex_shrink()
                    .child(summary(line, summary_color, link)),
            );
    }
    if let Some(suffix) = line.suffix.clone() {
        row = row.child(
            div()
                .debug_selector(move || suffix_selector)
                .flex_none()
                .pl(px(8.))
                .text_size(px(12.5))
                .text_color(colors.faint)
                .whitespace_nowrap()
                .child(suffix),
        );
    }
    row = row.child(div().flex_1().min_w(px(4.)));
    if let Some(trailing) = line.trailing.clone().filter(|text| !text.is_empty()) {
        row = row.child(
            div()
                .debug_selector(move || trailing_selector)
                .flex_none()
                .text_size(px(11.5))
                .text_color(colors.faint)
                .child(trailing),
        );
    }
    row
}

/// Swift's `TranscriptShimmer`: a slow band of light crossing a running row,
/// clear to the strong panel and back, once every 2.6 s. It paints over the
/// row and decides no geometry.
fn shimmer(id: &ElementId, strong: Hsla) -> impl IntoElement {
    let clear = Hsla { a: 0., ..strong };
    let half = |from: Hsla, to: Hsla| {
        div().w(px(SHIMMER_BAND / 2.)).h_full().bg(linear_gradient(
            90.,
            linear_color_stop(from, 0.),
            linear_color_stop(to, 1.),
        ))
    };
    // The track runs from a band's width before the row to its end, so the
    // band enters whole and leaves whole.
    let selector = format!("{id}-shimmer");
    div()
        .debug_selector(move || selector)
        .absolute()
        .top_0()
        .bottom_0()
        .left(px(-SHIMMER_BAND))
        .right_0()
        .child(
            div()
                .absolute()
                .top_0()
                .h_full()
                .flex()
                .child(half(clear, strong))
                .child(half(strong, clear))
                .with_animation(
                    SharedString::from(format!("work-line-shimmer-{id}")),
                    Animation::new(SHIMMER).repeat(),
                    |band, delta| band.left(relative(delta)),
                ),
        )
}

/// The summary gives way first: cut at its end, or, for a line still being
/// written, clipped from its start so its newest words stay in view. A path
/// that is the row's file is its own press target, underlined under the
/// pointer.
fn summary(line: &WorkLine, color: Hsla, link: Option<Link>) -> impl IntoElement {
    let text = div()
        .text_size(px(12.5))
        .text_color(color)
        .whitespace_nowrap()
        .child(line.summary.clone());
    if line.follow {
        return div()
            .min_w_0()
            .flex_shrink()
            .overflow_hidden()
            .flex()
            .justify_end()
            .child(text.flex_none())
            .into_any_element();
    }
    let text = text.truncate();
    let Some(link) = link else {
        return div().min_w_0().flex_shrink().child(text).into_any_element();
    };
    div()
        .min_w_0()
        .flex_shrink()
        .child(
            text.id("work-line-link")
                .cursor_pointer()
                .hover(|text| text.underline())
                .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .on_click(move |_, window, cx| {
                    cx.stop_propagation();
                    link(window, cx)
                }),
        )
        .into_any_element()
}

/// Swift's `thinkSummary`: what a Think row says of its reasoning. While it
/// runs, the last line with words in it; once done, the first; bold marks
/// dropped and the ends trimmed.
pub(crate) fn think_summary(text: &str, running: bool) -> String {
    let line = if running {
        let Some(end) = text.rfind(|c: char| !c.is_whitespace()) else {
            return String::new();
        };
        let start = text[..end].rfind('\n').map_or(0, |at| at + 1);
        &text[start..end + text[end..].chars().next().map_or(0, char::len_utf8)]
    } else {
        let Some(start) = text.find(|c: char| !c.is_whitespace()) else {
            return String::new();
        };
        let rest = &text[start..];
        &rest[..rest.find('\n').unwrap_or(rest.len())]
    };
    line.replace("**", "").trim().to_owned()
}

#[cfg(test)]
mod tests {
    use super::{WorkLine, WorkState, think_summary};

    #[test]
    fn a_work_lines_tooltip_is_its_help_or_its_summary() {
        let mut line = WorkLine {
            icon: "terminal",
            title: "Ran".into(),
            summary: "cargo test".into(),
            suffix: None,
            state: WorkState::Ok,
            expandable: true,
            open: false,
            trailing: None,
            follow: false,
            help: None,
        };
        assert_eq!(line.tooltip(), Some("cargo test".into()));
        line.help = Some("/repo/src/main.rs".into());
        assert_eq!(line.tooltip(), Some("/repo/src/main.rs".into()));
        // A help that says nothing hides the summary too, as Swift's does.
        line.help = Some("".into());
        assert_eq!(line.tooltip(), None);
        line.help = None;
        line.summary = "".into();
        assert_eq!(line.tooltip(), None);
    }

    #[test]
    fn a_think_row_reads_its_first_line_or_while_running_its_last() {
        let text = "\n\n**Planning** the change\nthen checking\n  the tests  \n\n";
        assert_eq!(think_summary(text, false), "Planning the change");
        assert_eq!(think_summary(text, true), "the tests");
        assert_eq!(think_summary("  \n\t ", false), "");
        assert_eq!(think_summary("  \n\t ", true), "");
        assert_eq!(think_summary("one line", true), "one line");
        assert_eq!(think_summary("日本語の**推論**\n次", false), "日本語の推論");
        assert_eq!(think_summary("first\nlast é", true), "last é");
    }
}
