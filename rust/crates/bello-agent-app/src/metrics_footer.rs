//! The session pills under the composer: Swift 0.1.122 `SessionStatsPills`
//! (Inspector/MetricsFooterView.swift) over `SessionStatsPresentation`
//! (Dashboard/SessionStatsPills.swift) and `ContextMeterPresentation`
//! (Inspector/MetricsFooter.swift). How much work the chat did and how fast,
//! what it consumed, and how full its window is: three pills, no figure that
//! ticks while a request runs. Each opens the inspector.
//!
//! The figures come from the chat's own request records
//! (`bello_agent_core::accounting`) and pi's context estimate
//! (`bello_agent_core::compaction::context_usage`), worked out once per
//! session snapshot, never per frame.
use crate::{AgentView, Palette, composer_attachments::TextHint, context_inspector};
use bello_agent_core::{
    Profile, Session,
    accounting::GatewayTotals,
    accounting_presentation::{self, Face, StatsPresentation},
    compaction::{self, ContextEstimate},
    metric_format,
};
use gpui::{prelude::*, *};
use std::{
    cell::RefCell,
    f32::consts::PI,
    rc::Rc,
    sync::{Arc, Weak},
};

/// `PiKit.StatPill` geometry: 7 + 16 (glyph) + 5 + reading + 7, and a
/// reading of caption type (11.5) six points taller than its line.
const PILL_LEADING: f32 = 7.;
const PILL_GLYPH: f32 = 16.;
const PILL_GAP: f32 = 5.;
const PILL_TRAILING: f32 = 7.;
const CAPTION: f32 = 11.5;
/// `PiFlow(spacing: 4, rowSpacing: 3)`.
const SPACING: f32 = 4.;
const ROW_SPACING: f32 = 3.;
/// A caption digit's advance, for choosing the usage pill's face as
/// `ViewThatFits` does without laying it out.
const CHARACTER_WIDTH: f32 = 6.6;

/// What the context pill reads (`ContextMeterPresentation`).
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum ContextReading {
    /// A count over a configured window.
    Counted {
        estimate: ContextEstimate,
        window: u32,
        output_limit_sent: bool,
        output_limit_omitted: bool,
    },
    /// After a compaction, until a reply that came after it reports.
    Pending,
    /// No window to count against.
    Unavailable,
}

/// `ContextMeterPresentation.methodExplanation`, with the throughput's: the
/// footer's own help.
const CONTEXT_EXPLANATION: &str = "The context ring counts the last reply's reported tokens, plus about 4 characters per token for the messages since. After a compaction it waits for the next reply.";
pub(crate) fn footer_help() -> String {
    format!(
        "{} {CONTEXT_EXPLANATION}",
        accounting_presentation::throughput_explanation()
    )
}
const USAGE_SOURCE: &str =
    "Last reply's reported tokens, plus about 4 characters per token for the messages since";
const CHARACTER_SOURCE: &str =
    "About 4 characters per token for every message; no reply has reported its tokens yet";
const PENDING_SOURCE: &str = "Pending until the next reply";

impl ContextReading {
    pub(crate) fn of(session: &Session, profile: Option<&Profile>) -> Self {
        let Some(profile) = profile.filter(|p| p.context_window > 0) else {
            return Self::Unavailable;
        };
        match compaction::context_usage(&session.messages) {
            Ok(Some(estimate)) => Self::Counted {
                estimate,
                window: profile.context_window,
                output_limit_sent: profile.wire_output_limit().is_some(),
                output_limit_omitted: profile.compat.supports_max_output_tokens == Some(false),
            },
            Ok(None) => Self::Pending,
            Err(_) => Self::Unavailable,
        }
    }
    pub(crate) fn fraction(&self) -> Option<f64> {
        match self {
            Self::Counted {
                estimate, window, ..
            } => Some(estimate.tokens as f64 / f64::from(*window)),
            _ => None,
        }
    }
    /// What the pill says: `35%`, else `Context pending` or `Inspect context`.
    pub(crate) fn label(&self) -> String {
        match self {
            Self::Counted { .. } => self
                .fraction()
                .and_then(|f| metric_format::occupancy_percent(f, 0))
                .map_or_else(|| "Inspect context".into(), |p| format!("{p}%")),
            Self::Pending => "Context pending".into(),
            Self::Unavailable => "Inspect context".into(),
        }
    }
    /// `detailLabel`: `≈23,456 / 65,536 configured · 35.8% · <source>` and
    /// the count's warnings.
    pub(crate) fn detail(&self) -> String {
        match self {
            Self::Counted {
                estimate,
                window,
                output_limit_sent,
                output_limit_omitted,
            } => {
                let ratio = estimate.tokens as f64 / f64::from(*window);
                let percent = if ratio > 1. {
                    format!("{:.1}", ratio * 100.)
                } else {
                    metric_format::occupancy_percent(ratio, 1).unwrap_or_else(|| "—".into())
                };
                let source = if estimate.last_usage_id.is_some() {
                    USAGE_SOURCE
                } else {
                    CHARACTER_SOURCE
                };
                let mut warnings = Vec::new();
                if estimate.last_usage_id.is_none() {
                    warnings.push("Input is estimated from the complete provider projection, including instructions and tool schemas.");
                }
                if !output_limit_sent {
                    warnings.push(if *output_limit_omitted {
                        "The gateway compatibility setting omits the output limit; the gateway decides where the reply stops. The output budget is a local reserve and is not sent as a server-enforced cap."
                    } else {
                        "The model catalog gave no output ceiling for this model, so no output limit is sent; the gateway decides where the reply stops. The output budget is a local reserve and is not sent as a server-enforced cap."
                    });
                }
                let warning = if warnings.is_empty() {
                    String::new()
                } else {
                    format!(" · {}", warnings.join(" "))
                };
                format!(
                    "≈{} / {} configured · {percent}% · {source}{warning}",
                    metric_format::grouped(estimate.tokens as f64),
                    metric_format::grouped(f64::from(*window)),
                )
            }
            Self::Pending => PENDING_SOURCE.into(),
            Self::Unavailable => {
                "Click to calculate and inspect context; no response is generated".into()
            }
        }
    }
}

/// Everything the footer reads from one session snapshot.
#[derive(Debug)]
pub(crate) struct FooterReadings {
    pub(crate) totals: GatewayTotals,
    pub(crate) context: ContextReading,
}
impl FooterReadings {
    pub(crate) fn stats(&self) -> StatsPresentation<'_> {
        StatsPresentation {
            gateway: &self.totals,
        }
    }
}

/// What of a profile the readings depend on: its identity, model, window and
/// output-limit settings.
type ProfileKey = (String, String, u32, Option<u32>, Option<bool>);
struct Cached {
    session: Weak<Session>,
    profile: Option<ProfileKey>,
    readings: Rc<FooterReadings>,
}
thread_local! {
    static CACHE: RefCell<Vec<Cached>> = const { RefCell::new(Vec::new()) };
}

/// The readings of this exact snapshot under this profile, worked out once.
pub(crate) fn readings(session: &Arc<Session>, profile: Option<&Profile>) -> Rc<FooterReadings> {
    let key = profile.map(|p| {
        (
            p.id.clone(),
            p.model_id.clone(),
            p.context_window,
            p.wire_output_limit(),
            p.compat.supports_max_output_tokens,
        )
    });
    CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();
        if let Some(hit) = cache.iter().find(|c| {
            c.profile == key
                && c.session
                    .upgrade()
                    .is_some_and(|held| Arc::ptr_eq(&held, session))
        }) {
            return hit.readings.clone();
        }
        let readings = Rc::new(FooterReadings {
            totals: session.request_totals(),
            context: ContextReading::of(session, profile),
        });
        // A handful of chats' latest snapshots; older ones fall out.
        cache.retain(|c| c.session.strong_count() > 0);
        if cache.len() >= 16 {
            cache.remove(0);
        }
        cache.push(Cached {
            session: Arc::downgrade(session),
            profile: key,
            readings: readings.clone(),
        });
        readings
    })
}

/// The width a pill's reading takes, as the face choice measures it.
fn reading_width(label: &str) -> f32 {
    label.chars().count() as f32 * CHARACTER_WIDTH
}
fn pill_width(label: &str) -> f32 {
    PILL_LEADING + PILL_GLYPH + PILL_GAP + reading_width(label) + PILL_TRAILING
}

/// The usage pill's face for a row `width` wide: the token split when it
/// fits, else the compact one (`chooseUsageFace`).
pub(crate) fn usage_face(stats: &StatsPresentation<'_>, width: f32) -> Face {
    let full = stats.usage_face();
    if pill_width(&full.label) <= width {
        full
    } else {
        stats.compact_usage_face()
    }
}

/// `Ring.context(fraction, size: 14)`: a hairline track and, from twelve
/// o'clock clockwise, the share in accent, warning past 80% and danger past
/// 95%.
fn ring(fraction: Option<f64>, palette: Palette) -> impl IntoElement {
    let bounded = fraction.unwrap_or(0.).clamp(0., 1.) as f32;
    let track: Hsla = rgba(if palette.dark { 0xffffff29 } else { 0x0000001f }).into();
    let tint: Hsla = if bounded >= 0.95 {
        rgb(palette.danger).into()
    } else if bounded >= 0.8 {
        rgb(if palette.dark { 0xe3b15c } else { 0xa8781c }).into()
    } else {
        rgb(palette.accent).into()
    };
    canvas(
        |_, _, _| {},
        move |bounds, _, window, _| {
            let size = 14.;
            let center = point(
                bounds.origin.x + px(PILL_GLYPH / 2.),
                bounds.origin.y + bounds.size.height / 2.,
            );
            let radius = size / 2.;
            let point_at = |turn: f32| {
                let angle = -PI / 2. + turn * 2. * PI;
                point(
                    center.x + px(radius * angle.cos()),
                    center.y + px(radius * angle.sin()),
                )
            };
            let mut path = PathBuilder::stroke(px(2.));
            path.move_to(point_at(0.));
            for step in 1..=48 {
                path.line_to(point_at(step as f32 / 48.));
            }
            if let Ok(path) = path.build() {
                window.paint_path(path, track);
            }
            if bounded > 0. {
                let steps = ((48. * bounded).ceil() as usize).max(1);
                let mut arc = PathBuilder::stroke(px(2.));
                arc.move_to(point_at(0.));
                for step in 1..=steps {
                    arc.line_to(point_at(bounded * step as f32 / steps as f32));
                }
                if let Ok(arc) = arc.build() {
                    window.paint_path(arc, tint);
                }
            }
        },
    )
    .w(px(PILL_GLYPH))
    .h(px(PILL_GLYPH))
    .flex_none()
}

fn hint(text: String, palette: Palette) -> impl Fn(&mut Window, &mut App) -> AnyView {
    move |_, cx| {
        cx.new(|_| TextHint {
            text: text.clone(),
            palette,
        })
        .into()
    }
}

impl AgentView {
    /// `PiKit.StatPill`: a glyph or ring, the reading in secondary caption
    /// type, a soft fill under the pointer.
    fn stat_pill(
        &self,
        id: &'static str,
        glyph: AnyElement,
        label: String,
        truncates: bool,
    ) -> Stateful<Div> {
        let p = self.palette;
        div()
            .id(id)
            .debug_selector(move || id.into())
            .flex()
            .flex_none()
            .items_center()
            .h(px(22.))
            .pl(px(PILL_LEADING))
            .pr(px(PILL_TRAILING))
            .gap(px(PILL_GAP))
            .rounded_full()
            .cursor_pointer()
            .hover(move |d| d.bg(p.fill()))
            .text_size(px(CAPTION))
            .text_color(rgb(p.secondary))
            .child(glyph)
            .child(if truncates {
                div().min_w_0().truncate().child(label)
            } else {
                div().flex_none().whitespace_nowrap().child(label)
            })
            .when(truncates, |pill| pill.flex_shrink().min_w_0())
    }
    fn pill_symbol(&self, name: &'static str) -> AnyElement {
        div()
            .w(px(PILL_GLYPH))
            .h(px(PILL_GLYPH))
            .flex()
            .flex_none()
            .items_center()
            .justify_center()
            .child(
                svg()
                    .path(name)
                    .size(px(11.))
                    .text_color(rgb(self.palette.tertiary)),
            )
            .into_any_element()
    }

    /// The pills, flowed as `PiFlow(spacing: 4, rowSpacing: 3)`: the gauge
    /// once a request went out, the usage once one reported, and the context
    /// ring always. The first two open the inspector, the ring the next request.
    pub(crate) fn session_stats_pills(&self, width: f32, cx: &mut Context<Self>) -> Stateful<Div> {
        let p = self.palette;
        let profile = self.controller.profile();
        let readings = readings(&self.session, profile.as_ref());
        let stats = readings.stats();
        let target = self.context_inspector_target();
        let open = |target: context_inspector::ContextInspectorTarget| {
            cx.listener(move |view: &mut AgentView, _: &ClickEvent, window, cx| {
                view.open_context_inspector(&target, window, cx)
            })
        };
        let footer_help = footer_help();
        let mut row = div()
            .id("sessionStatsPills")
            .debug_selector(|| "sessionStatsPills".into())
            .tooltip(hint(footer_help, p))
            .flex()
            .flex_wrap()
            .items_center()
            .gap_x(px(SPACING))
            .gap_y(px(ROW_SPACING))
            .min_w_0();
        let mut used = 0.;
        if stats.steps() > 0 {
            let label = stats.gauge_label();
            used += pill_width(&label) + SPACING;
            let help = format!(
                "{}\n{}",
                accounting_presentation::gauge_help(),
                crate::tool_timing_presentation::total_label(&self.session)
            );
            row = row.child(
                self.stat_pill(
                    "session-stats-time",
                    self.pill_symbol("gauge"),
                    label,
                    false,
                )
                .tooltip(hint(help, p))
                .on_click(open(target.clone())),
            );
        }
        if stats.has_usage() {
            let face = usage_face(&stats, (width - used).max(0.));
            row = row.child(
                // Swift clips a face wider than the whole row; here it ends
                // in "…" rather than pushing the row past the pane.
                self.stat_pill(
                    "session-stats-usage",
                    self.pill_symbol("cylinder.split"),
                    face.label,
                    true,
                )
                .tooltip(hint(accounting_presentation::USAGE_HELP.into(), p))
                .on_click(open(target.clone())),
            );
        }
        let context = &readings.context;
        let fraction = context.fraction();
        let figure = matches!(context, ContextReading::Counted { .. });
        let help = format!(
            "{} Opens the next request in the Session Inspector.",
            context.detail()
        );
        row.child(
            self.stat_pill(
                "session-stats-context",
                ring(fraction, p).into_any_element(),
                context.label(),
                !figure,
            )
            .tooltip(hint(help, p))
            .on_click(open(target)),
        )
    }
}

impl AgentView {
    /// The composer bar's usage button (Swift `ComposerInput.usage`): the
    /// Session Inspector's icon, opening it on this chat.
    pub(crate) fn session_usage_button(&self, cx: &mut Context<Self>) -> Stateful<Div> {
        let target = self.context_inspector_target();
        let help = "Open the Session Inspector: what this chat cost and used, how fast it ran, and every request it made".to_owned();
        self.icon_button("usage", "chart.pie", 28.)
            .debug_selector(|| "sessionUsageButton".into())
            .tooltip(hint(help, self.palette))
            .on_click(cx.listener(move |view, _: &ClickEvent, window, cx| {
                view.open_context_inspector(&target, window, cx)
            }))
    }
}

#[cfg(test)]
#[path = "metrics_footer_tests.rs"]
mod tests;
