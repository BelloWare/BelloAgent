//! A sidebar row's figures beside its state: Swift 0.1.122 `ChatRowStats`
//! and `ChatRowMetricsView` (Workspaces/SidebarChatRows.swift). Its cost,
//! the latest completed request's output rate in a fixed 108-point slot
//! (`SidebarRateView`, only for a chat that is open, as Swift shows it only
//! for a live page), and its token total, which a running chat hides.
//!
//! A loaded chat's figures come from its session; an unloaded chat's from the
//! totals read with its saved run state.
use crate::AgentView;
use bello_agent_core::{
    Session,
    accounting::{self, GatewayTotals},
    accounting_presentation::{self, RowStats},
    workspace::ChatRecord,
};
use gpui::{prelude::*, *};
use std::{
    cell::RefCell,
    rc::Rc,
    sync::{Arc, Weak},
};

/// `SidebarRateView.width`.
const RATE_WIDTH: f32 = 108.;
/// `SidebarMetricsFigures.spacing`.
const SPACING: f32 = 6.;

/// What a row shows beside its state.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct RowFigures {
    pub(crate) cost: Option<String>,
    /// `Some` for an open chat: the slot, with its label when the latest
    /// completed request measured a rate.
    pub(crate) rate: Option<Option<String>>,
    pub(crate) tokens: Option<String>,
    pub(crate) tokens_help: String,
}
impl RowFigures {
    pub(crate) fn of(totals: &GatewayTotals, rate: Option<Option<String>>, busy: bool) -> Self {
        let row = RowStats { gateway: totals };
        Self {
            cost: row.cost_label(),
            rate,
            // The token total is dropped while a run is in flight.
            tokens: (!busy)
                .then(|| row.tokens_label().map(|t| format!("· {t}")))
                .flatten(),
            tokens_help: row.usage_help(),
        }
    }
}

struct Cached {
    session: Weak<Session>,
    totals: Rc<(GatewayTotals, Option<String>)>,
}
thread_local! {
    static CACHE: RefCell<Vec<Cached>> = const { RefCell::new(Vec::new()) };
}
/// A loaded chat's totals and latest rate, worked out once per snapshot.
fn live(session: &Arc<Session>) -> Rc<(GatewayTotals, Option<String>)> {
    CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();
        if let Some(hit) = cache.iter().find(|c| {
            c.session
                .upgrade()
                .is_some_and(|held| Arc::ptr_eq(&held, session))
        }) {
            return hit.totals.clone();
        }
        let totals = Rc::new((
            session.request_totals(),
            accounting::latest_rate_label(&session.requests),
        ));
        cache.retain(|c| c.session.strong_count() > 0);
        if cache.len() >= 64 {
            cache.remove(0);
        }
        cache.push(Cached {
            session: Arc::downgrade(session),
            totals: totals.clone(),
        });
        totals
    })
}

impl AgentView {
    pub(crate) fn sidebar_row_figures(&self, record: &ChatRecord) -> RowFigures {
        if let Some(chat) = self.chat_ref(&record.id) {
            let live = live(&chat.session);
            let busy = chat.loading || chat.session.state == bello_agent_core::RunState::Running;
            return RowFigures::of(&live.0, Some(live.1.clone()), busy);
        }
        match self.sidebar_saved_totals(record) {
            Some(totals) => RowFigures::of(totals, None, false),
            None => RowFigures::default(),
        }
    }

    /// The row's line under its title: its state (and what needs attention),
    /// then its cost, rate slot and tokens, six points apart, cut at the edge.
    pub(crate) fn sidebar_metrics_line(
        &self,
        record: &ChatRecord,
        status: &str,
        attention: Option<&str>,
    ) -> Div {
        let p = self.palette;
        let figures = self.sidebar_row_figures(record);
        let id = record.id.clone();
        let quiet = |text: String| {
            div()
                .flex_none()
                .whitespace_nowrap()
                .text_color(rgb(p.tertiary))
                .child(text)
        };
        div()
            .debug_selector(move || format!("sidebar-metrics-{id}"))
            .flex()
            .items_center()
            .gap(px(SPACING))
            .min_w_0()
            .overflow_hidden()
            .text_size(px(10.5))
            .text_color(rgb(p.secondary))
            .child(
                div()
                    .flex_none()
                    .whitespace_nowrap()
                    .child(match attention {
                        Some(attention) => format!("{status} · {attention}"),
                        None => status.to_owned(),
                    }),
            )
            .when_some(figures.cost, |line, cost| line.child(quiet(cost)))
            .when_some(figures.rate, |line, rate| {
                let help = accounting_presentation::rate_explanation();
                let palette = p;
                line.child(
                    div()
                        .id("sidebar-reported-rate")
                        .debug_selector(|| "sidebar-reported-rate".into())
                        .flex_none()
                        .w(px(RATE_WIDTH))
                        .whitespace_nowrap()
                        .overflow_hidden()
                        .text_color(rgb(if rate.is_some() {
                            p.secondary
                        } else {
                            p.tertiary
                        }))
                        .child(rate.unwrap_or_default())
                        .tooltip(move |_, cx| {
                            cx.new(|_| crate::composer_attachments::TextHint {
                                text: help.clone(),
                                palette,
                            })
                            .into()
                        }),
                )
            })
            .when_some(figures.tokens, |line, tokens| {
                let help = figures.tokens_help.clone();
                let palette = p;
                line.child(
                    div()
                        .id("sidebar-tokens")
                        .min_w_0()
                        .truncate()
                        .text_color(rgb(p.tertiary))
                        .child(tokens)
                        .tooltip(move |_, cx| {
                            cx.new(|_| crate::composer_attachments::TextHint {
                                text: help.clone(),
                                palette,
                            })
                            .into()
                        }),
                )
            })
    }
}

#[cfg(test)]
#[path = "sidebar_metrics_tests.rs"]
mod tests;
