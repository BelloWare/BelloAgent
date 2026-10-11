//! The words the accounting is read in: the session pills under the composer
//! (Swift `SessionStatsPresentation`, Dashboard/SessionStatsPills.swift), a
//! sidebar row's figures (`ChatRowStats`, Workspaces/SidebarChatRows.swift)
//! and a session reference's usage lines (`SessionReference.usageLines`,
//! Storage/SessionReference.swift). Pure functions over [`GatewayTotals`].
use crate::accounting::{GatewayTotals, MINIMUM_DECODE_SPAN_MS};
use crate::metric_format as format;

/// `SettledThroughput.explanation`.
pub fn throughput_explanation() -> String {
    format!(
        "Output tokens after the first ÷ time from the first generated token to the last (hidden reasoning included); replies under {} ms of generation are left out. Not a live rate, and not round-trip latency.",
        MINIMUM_DECODE_SPAN_MS as u64
    )
}
/// `SessionRatePresentation.explanation`.
pub fn rate_explanation() -> String {
    throughput_explanation()
        + " The latest completed request stays visible while the next one runs."
}
/// The gauge pill's help (`SessionStatsPills.gauge.toolTip`).
pub fn gauge_help() -> String {
    throughput_explanation() + " Opens the Session Inspector."
}
/// The usage pill's help.
pub const USAGE_HELP: &str = "Gateway-reported usage and cost for this session's retained requests, and its cost limit. Uncached and cached input make up the input; reasoning is part of the output. Opens the Session Inspector.";

/// A pill's reading: the label, and a trailing figure drawn in warning ink.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Face {
    pub label: String,
    pub warning_tail: Option<String>,
}

/// `SessionStatsPresentation` without a cost limit (this build has none).
#[derive(Clone, Debug, PartialEq)]
pub struct StatsPresentation<'a> {
    pub gateway: &'a GatewayTotals,
}
impl StatsPresentation<'_> {
    pub fn turns(&self) -> u64 {
        self.gateway.turn_count
    }
    pub fn steps(&self) -> u64 {
        self.gateway.requests
    }
    fn plural(n: u64, one: &str, many: &str) -> String {
        format!("{n} {}", if n == 1 { one } else { many })
    }
    pub fn counts_label(&self) -> String {
        format!(
            "{} {}",
            Self::plural(self.turns(), "turn", "turns"),
            Self::plural(self.steps(), "step", "steps")
        )
    }
    /// `2 turns 3 steps · 34 tok/s`.
    pub fn gauge_label(&self) -> String {
        [Some(self.counts_label()), self.gateway.throughput.label()]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" · ")
    }
    /// `3.2K uncached · 10.1K cached · 2.5K out (1.2K reasoning)`.
    pub fn token_split(&self) -> Vec<String> {
        let g = self.gateway;
        let mut parts = Vec::new();
        if let Some(input) = g.input.value() {
            match g.reported_input_split() {
                Some(split) if split.samples == g.input.samples && split.total == input => {
                    parts.push(format::tokens(split.total - split.part) + " uncached");
                    parts.push(format::tokens(split.part) + " cached");
                }
                _ => parts.push(format::tokens(input) + " in"),
            }
        }
        if let Some(output) = g.output.value() {
            let reasoning = g.reasoning.value();
            parts.push(
                format::tokens(output)
                    + " out"
                    + &reasoning
                        .map(|r| format!(" ({} reasoning)", format::tokens(r)))
                        .unwrap_or_default(),
            );
        }
        parts
    }
    fn usage_parts(&self, split: bool) -> Vec<String> {
        let mut parts = Vec::new();
        if let Some(total) = self.gateway.billed_total_tokens() {
            parts.push(format::token_count(total));
        }
        if split {
            parts.extend(self.token_split());
        }
        if let Some(hit) = self.gateway.cache_hit_percent() {
            parts.push(format!("Cache hit {hit}%"));
        }
        parts
    }
    /// The request log's spend: `$0.0025`.
    pub fn cost_figure(&self) -> Option<String> {
        let spent = (self.gateway.cost.samples > 0)
            .then(|| self.gateway.cost.value())
            .flatten();
        spent.map(|value| format::compact_gateway_usd(Some(value)))
    }
    /// `15.8K tok · 3.2K uncached · 10.1K cached · 2.5K out (1.2K reasoning) · Cache hit 75.94% · $0.0025`
    pub fn usage_label(&self) -> String {
        let mut parts = self.usage_parts(true);
        parts.extend(self.cost_figure());
        parts.join(" · ")
    }
    fn face(&self, split: bool) -> Face {
        let mut parts = self.usage_parts(split);
        parts.extend(self.cost_figure());
        Face {
            label: parts.join(" · "),
            warning_tail: None,
        }
    }
    pub fn usage_face(&self) -> Face {
        self.face(true)
    }
    /// For a pane too narrow for the token split: `15.8K tok · Cache hit 50.00% · $0.0025`.
    pub fn compact_usage_face(&self) -> Face {
        self.face(false)
    }
    pub fn has_usage(&self) -> bool {
        !self.usage_label().is_empty()
    }
}

/// A sidebar row's figures (`ChatRowStats`).
#[derive(Clone, Debug, PartialEq)]
pub struct RowStats<'a> {
    pub gateway: &'a GatewayTotals,
}
impl RowStats<'_> {
    /// `$0.0042`, `$0.00`, `cost n/a` once a request went out, else nothing.
    pub fn cost_label(&self) -> Option<String> {
        let g = self.gateway;
        match g.cost.value() {
            None => (g.requests > 0).then(|| "cost n/a".into()),
            Some(0.0) => Some("$0.00".into()),
            Some(cost) => Some(format::cents_usd(cost, 4, true)),
        }
    }
    /// `12.3K tok`, `tok n/a`.
    pub fn tokens_label(&self) -> Option<String> {
        let g = self.gateway;
        match g.total.value() {
            Some(tokens) => Some(format::row_token_count(tokens)),
            None => (g.requests > 0).then(|| "tok n/a".into()),
        }
    }
    /// The tokens figure's help (`usageHelp`).
    pub fn usage_help(&self) -> String {
        let g = self.gateway;
        format!(
            "Session tokens · input {} ({}/{} requests reported) · cached input {} ({}/{} reported) · output {} ({}/{} reported). Input counts cached tokens once; reasoning is included in output. Context size is shown below the composer.",
            format::menu_bar_tokens(g.input.value()),
            g.input.samples,
            g.requests,
            format::menu_bar_tokens(g.cache_read.value()),
            g.cache_read.samples,
            g.requests,
            format::menu_bar_tokens(g.output.value()),
            g.output.samples,
            g.requests,
        )
    }
}

/// `SessionReference.usageLines`.
pub fn reference_usage_lines(usage: &GatewayTotals) -> Vec<String> {
    let coverage = |samples: u64| format!(" ({samples}/{} requests reported)", usage.requests);
    let count = |value: Option<f64>, samples: u64| match value {
        Some(value) if samples > 0 => format!("{value:.0}") + &coverage(samples),
        _ => "not reported".into(),
    };
    let cost = |value: Option<f64>, samples: u64| match value {
        Some(value) if samples > 0 => format::gateway_usd(Some(value)) + &coverage(samples),
        _ => "not reported".into(),
    };
    vec![
        format!(
            "Gateway-reported usage (retained requests): {} requests",
            usage.requests
        ),
        format!(
            "Total tokens (input + output): {}",
            count(usage.total.value(), usage.total.samples)
        ),
        format!(
            "Input tokens (includes cache): {}",
            count(usage.input.value(), usage.input.samples)
        ),
        format!(
            "Output tokens (includes reasoning): {}",
            count(usage.output.value(), usage.output.samples)
        ),
        format!(
            "Cached input tokens: {}",
            count(usage.cache_read.value(), usage.cache_read.samples)
        ),
        format!(
            "Cache-write input tokens: {}",
            count(usage.cache_write.value(), usage.cache_write.samples)
        ),
        format!(
            "Reasoning tokens (part of output): {}",
            count(usage.reasoning.value(), usage.reasoning.samples)
        ),
        format!(
            "Reported cost: {}",
            cost(usage.cost.value(), usage.cost.samples)
        ),
        // No reasoning cost is reported over Responses streaming (the
        // gateway sends it only as a pre-stream header component).
        "Reasoning cost (part of reported cost): not reported".to_owned(),
        "Usage is a snapshot of this session's own retained requests; inherited conversation history and unreported in-flight usage are not added.".to_owned(),
    ]
}

#[cfg(test)]
#[path = "accounting_presentation_tests.rs"]
mod tests;
