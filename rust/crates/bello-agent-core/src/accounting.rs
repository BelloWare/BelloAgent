//! Per-request accounting: what each model request a chat made reported and
//! how long it took, kept with the chat so it survives relaunch, and the
//! session totals the footer, the sidebar and a session reference read.
//!
//! Ported from Swift 0.1.122: `UsageObservation.normalized`
//! (TelemetryValues.swift), `GatewayTelemetry` (cost evidence),
//! `TraceStore.metrics` (TTFT and the decode span), `GatewayObservation` and
//! `GatewayTotals` (Dashboard/GatewayAccounting.swift) and the archive's
//! `gatewayAggregateSQL` (PayloadArchive+Accounting.swift).
//!
//! Only reported figures are counted. A missing or invalid observation stays
//! missing; it never becomes a zero, and nothing here is a local price
//! estimate. Nothing is capped: every request is kept, and only validity
//! bounds (finite, non-negative, at most 10^12) apply to each value.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Instant;

/// `GatewayObservation`'s bound on a token count or an amount of money.
const MAXIMUM: f64 = 1_000_000_000_000.0;
/// `TraceStore.minimumDecodeSpanMs`: a shorter decode span is a burst, not a rate.
pub const MINIMUM_DECODE_SPAN_MS: f64 = 250.0;

/// One model request's normalized usage, as `UsageObservation.normalized`
/// reads it from the provider's usage object. Each field is the reported
/// count, or `None` when it was unreported or invalid.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestUsage {
    /// Input including cached and cache-write input (`inputIncludingCache`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<u64>,
    /// Output including reasoning.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write: Option<u64>,
    /// A reported part of output, never added to it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<u64>,
}

/// Swift `UsageObservation.count`: an integral, non-negative JSON number.
fn count(value: &Value) -> Option<u64> {
    if let Some(n) = value.as_u64() {
        return Some(n);
    }
    let number = value.as_f64()?;
    (number.is_finite() && number >= 0.0 && number.fract() == 0.0 && number < u64::MAX as f64)
        .then_some(number as u64)
}
/// `GatewayObservation.tokens`: what it accumulates is at most 10^12.
fn bounded(value: Option<u64>) -> Option<u64> {
    value.filter(|n| *n as f64 <= MAXIMUM)
}

impl RequestUsage {
    /// `UsageObservation.normalized(raw, api)` followed by `GatewayObservation`'s
    /// token reads: `inputIncludingCache`, `output`, `cacheRead`, `cacheWrite`
    /// and `reasoning` (dropped when it exceeds output).
    pub fn normalized(raw: &Value, api: &str) -> Self {
        let responses = api == "openai-responses";
        // (value, invalid): unreported is null; invalid is present but not a count.
        let read = |value: &Value| (count(value), !value.is_null() && count(value).is_none());
        let input = count(&raw["input_tokens"]);
        let output = count(&raw["output_tokens"]);
        let (mut cache_read, mut read_invalid) = read(if responses {
            &raw["input_tokens_details"]["cached_tokens"]
        } else {
            &raw["cache_read_input_tokens"]
        });
        let (mut cache_write, mut write_invalid) = read(if responses {
            &raw["input_tokens_details"]["cache_write_tokens"]
        } else {
            &raw["cache_creation_input_tokens"]
        });
        let mut reasoning = count(&raw["output_tokens_details"]["reasoning_tokens"]);
        // A part larger than its whole is invalid (the caches on Responses only).
        if responses {
            if cache_read
                .zip(input)
                .is_some_and(|(part, whole)| part > whole)
            {
                (cache_read, read_invalid) = (None, true);
            }
            if cache_write
                .zip(input)
                .is_some_and(|(part, whole)| part > whole)
            {
                (cache_write, write_invalid) = (None, true);
            }
        }
        if reasoning
            .zip(output)
            .is_some_and(|(part, whole)| part > whole)
        {
            reasoning = None;
        }
        if responses
            && let (Some(input), Some(r), Some(w)) = (input, cache_read, cache_write)
            && r.checked_add(w).is_none_or(|sum| sum > input)
        {
            (cache_read, cache_write) = (None, None);
            (read_invalid, write_invalid) = (true, true);
        }
        // Responses input already includes both caches; Messages adds them.
        let mut including = input;
        if api == "anthropic-messages"
            && let Some(mut total) = input
        {
            for (part, invalid) in [(cache_read, read_invalid), (cache_write, write_invalid)] {
                if invalid {
                    including = None;
                    break;
                }
                match total.checked_add(part.unwrap_or(0)) {
                    Some(sum) => (total, including) = (sum, Some(sum)),
                    None => {
                        including = None;
                        break;
                    }
                }
            }
        }
        let output = bounded(output);
        let reasoning =
            bounded(reasoning).filter(|r| output.is_some_and(|o| *r <= o) || output.is_none());
        Self {
            input: bounded(including),
            output,
            cache_read: bounded(cache_read),
            cache_write: bounded(cache_write),
            reasoning,
        }
    }
    pub fn is_empty(&self) -> bool {
        self.input.is_none() && self.output.is_none()
    }
}

/// A gateway-reported cost (`GatewayTelemetry.json["cost"]` read by
/// `GatewayObservation`): reported with an amount, or unreported, invalid or
/// conflicting without one.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestCost {
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usd: Option<f64>,
}

fn money(value: &Value) -> Option<f64> {
    // `GatewayTelemetry.number`: a JSON number or a numeric string of at most 64 bytes.
    let number = match value {
        Value::String(text) if text.len() <= 64 => text.trim().parse::<f64>().ok(),
        Value::String(_) => None,
        other => other.as_f64(),
    }?;
    (number.is_finite() && (0.0..=MAXIMUM).contains(&number)).then_some(number)
}

/// The cost evidence one attempt collected: amounts the final usage carried
/// (`usage.cost`, `usage.response_cost`) and, for a non-streaming response,
/// the `x-litellm-response-cost` header. A streaming header is sent before
/// the reply is generated and never proves its cost.
#[derive(Clone, Debug, Default)]
pub struct CostEvidence {
    amounts: Vec<f64>,
    invalid: bool,
    header: Option<f64>,
    header_invalid: bool,
    streaming: bool,
}
impl CostEvidence {
    pub fn head(&mut self, header: Option<&str>, streaming: bool, secret: &dyn Fn(&str) -> bool) {
        self.streaming = streaming;
        let Some(text) = header else { return };
        match money(&Value::String(text.to_owned())) {
            Some(amount) if !secret(text) => self.header = Some(amount),
            _ => self.header_invalid = true,
        }
    }
    /// A response body or stream event (`GatewayTelemetry.body`): only a
    /// JSON body's `usage` or a Responses terminal event's usage carries cost.
    pub fn body(&mut self, value: &Value, streaming: bool, secret: &dyn Fn(&str) -> bool) {
        self.streaming = streaming;
        if !streaming {
            self.usage(&value["usage"], secret);
        } else if matches!(
            value["type"].as_str(),
            Some("response.completed" | "response.incomplete" | "response.failed")
        ) {
            self.usage(&value["response"]["usage"], secret);
        }
    }
    /// A terminal usage object (`response.completed|incomplete|failed`, or a
    /// JSON body's `usage`).
    pub fn usage(&mut self, usage: &Value, secret: &dyn Fn(&str) -> bool) {
        for field in ["cost", "response_cost"] {
            let value = &usage[field];
            if value.is_null() {
                continue;
            }
            match money(value) {
                Some(amount) if !value.as_str().is_some_and(secret) => {
                    if !self.amounts.contains(&amount) {
                        if self.amounts.len() >= 16 {
                            self.invalid = true;
                        } else {
                            self.amounts.push(amount);
                        }
                    }
                }
                _ => self.invalid = true,
            }
        }
    }
    pub fn cost(&self) -> RequestCost {
        let mut amounts = self.amounts.clone();
        if !self.streaming {
            if self.header_invalid {
                return RequestCost {
                    status: "invalid".into(),
                    usd: None,
                };
            }
            if let Some(header) = self.header
                && !amounts.contains(&header)
            {
                amounts.push(header);
            }
        }
        let status = if self.invalid {
            "invalid"
        } else if amounts.len() > 1 {
            "conflict"
        } else if amounts.is_empty() {
            "unreported"
        } else {
            "reported"
        };
        RequestCost {
            status: status.into(),
            usd: (status == "reported").then(|| amounts[0]),
        }
    }
}

/// One model request this chat made, kept with the chat. Every value is an
/// observation of that request; nothing is derived from a later one.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestRecord {
    /// The physical attempt's identity (Swift `attemptId`).
    pub id: String,
    /// Why it was sent: `turn` or `compaction`.
    pub purpose: String,
    /// The turn (its user message id) it served, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
    /// The message its output became, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply: Option<String>,
    /// When it was dispatched, seconds since 1970.
    pub wall: f64,
    pub requested_model: String,
    /// `completed`, `truncated`, `failed` or `cancelled`.
    pub outcome: String,
    #[serde(default)]
    pub usage: RequestUsage,
    #[serde(default)]
    pub cost: RequestCost,
    /// Dispatch to the first output (Swift `observedTTFTms`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ttft_ms: Option<f64>,
    /// First output to last output, or to the model's terminal when no last
    /// output was stamped (Swift `streamDurationMs`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream_ms: Option<f64>,
    /// Dispatch to the model's terminal event.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_ms: Option<f64>,
    /// The request prefix this request's usage measures (Swift
    /// `contextUsageBinding`): only a request with the same binding may rest
    /// its size on this reply's reported tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage_binding: Option<String>,
}

fn duration(value: Option<f64>) -> Option<f64> {
    value.filter(|v| v.is_finite() && *v >= 0.0 && *v < i64::MAX as f64)
}

impl RequestRecord {
    /// The validity bounds a stored record keeps: identities a sane size,
    /// every figure finite and non-negative. Nothing else is limited.
    pub fn validate(&self) -> crate::Result<()> {
        let text = |value: &str, max: usize| {
            !value.is_empty() && value.len() <= max && !value.chars().any(char::is_control)
        };
        if !text(&self.id, 128)
            || !["turn", "compaction"].contains(&self.purpose.as_str())
            || self.turn.as_deref().is_some_and(|t| !text(t, 256))
            || self.reply.as_deref().is_some_and(|r| !text(r, 256))
            || self.requested_model.len() > 256
            || !["completed", "truncated", "failed", "cancelled"].contains(&self.outcome.as_str())
            || !(self.wall.is_finite() && self.wall >= 0.0)
            || [self.ttft_ms, self.stream_ms, self.request_ms]
                .into_iter()
                .any(|v| v.is_some() && duration(v).is_none())
            || self
                .cost
                .usd
                .is_some_and(|usd| !(usd.is_finite() && (0.0..=MAXIMUM).contains(&usd)))
            || !["reported", "unreported", "invalid", "conflict"]
                .contains(&self.cost.status.as_str())
            || (self.cost.status == "reported") != self.cost.usd.is_some()
            || self.usage_binding.as_deref().is_some_and(|b| b.len() > 128)
        {
            return Err(crate::invalid("Invalid request accounting record"));
        }
        Ok(())
    }
    /// `SessionTimingSample.settledTokensPerSecond`: this request's output
    /// tokens after the first over its decode span, when it completed with
    /// two or more over at least the floor.
    pub fn settled_tokens_per_second(&self) -> Option<f64> {
        if self.outcome != "completed" {
            return None;
        }
        let mut fold = SettledThroughput::default();
        fold.add(self.stream_ms, self.usage.output.map(|n| n as f64));
        fold.tokens_per_second()
    }
}

/// Times in one request's life, on the process's monotonic clock, as the
/// Swift trace stamps them: dispatch, first output (an output item opened or
/// a non-empty delta), last output, and the model's terminal event.
#[derive(Clone, Debug, Default)]
pub struct AttemptClock {
    dispatch: Option<Instant>,
    first_content: Option<Instant>,
    last_content: Option<Instant>,
    completed: Option<Instant>,
}
impl AttemptClock {
    pub fn dispatched(&mut self) {
        self.dispatch.get_or_insert_with(Instant::now);
    }
    /// An output item opened: the model started generating.
    pub fn opened(&mut self) {
        self.first_content.get_or_insert_with(Instant::now);
    }
    /// A non-empty delta, or an output item completed.
    pub fn produced(&mut self, first: bool) {
        let now = Instant::now();
        if first {
            self.first_content.get_or_insert(now);
        }
        // Output after the terminal is not a token of this response.
        if self.completed.is_none() {
            self.last_content = Some(now);
        }
    }
    /// Output only a final body carried (`TraceStore.finalContent`).
    pub fn final_content(&mut self) {
        let now = Instant::now();
        self.first_content.get_or_insert(now);
        if self.last_content.is_none() {
            self.produced(false);
        }
    }
    pub fn terminal(&mut self) {
        self.completed.get_or_insert_with(Instant::now);
    }
    fn span(start: Option<Instant>, end: Option<Instant>) -> Option<f64> {
        let (start, end) = (start?, end?);
        duration(Some(
            end.checked_duration_since(start)?.as_secs_f64() * 1000.0,
        ))
    }
    pub fn ttft_ms(&self) -> Option<f64> {
        Self::span(self.dispatch, self.first_content)
    }
    pub fn stream_ms(&self) -> Option<f64> {
        Self::span(
            self.first_content,
            self.completed.map(|end| self.last_content.unwrap_or(end)),
        )
    }
    pub fn request_ms(&self) -> Option<f64> {
        Self::span(self.dispatch, self.completed)
    }
    pub fn was_dispatched(&self) -> bool {
        self.dispatch.is_some()
    }
}

/// What a request observed while it ran: filled in by the provider client,
/// turned into a [`RequestRecord`] by the runtime that knows its purpose.
#[derive(Clone, Debug, Default)]
pub struct AttemptObservation {
    pub id: String,
    pub wall: f64,
    pub api: String,
    pub requested_model: String,
    pub clock: AttemptClock,
    pub cost: CostEvidence,
    pub usage: Option<Value>,
    pub outcome: Option<String>,
    pub usage_binding: Option<String>,
}
impl AttemptObservation {
    pub fn record(
        &self,
        purpose: &str,
        turn: Option<&str>,
        reply: Option<&str>,
    ) -> Option<RequestRecord> {
        // A request that never went out is not a request (`dispatch IS NOT NULL`).
        if !self.clock.was_dispatched() || self.id.is_empty() {
            return None;
        }
        Some(RequestRecord {
            id: self.id.clone(),
            purpose: purpose.into(),
            turn: turn.map(str::to_owned),
            reply: reply.map(str::to_owned),
            wall: self.wall,
            requested_model: self.requested_model.chars().take(256).collect(),
            outcome: self.outcome.clone().unwrap_or_else(|| "failed".into()),
            usage: self
                .usage
                .as_ref()
                .map(|usage| RequestUsage::normalized(usage, &self.api))
                .unwrap_or_default(),
            cost: self.cost.cost(),
            ttft_ms: self.clock.ttft_ms(),
            stream_ms: self.clock.stream_ms(),
            request_ms: self.clock.request_ms(),
            usage_binding: self.usage_binding.clone(),
        })
    }
}

/// `SettledThroughput`: Σ(N − 1) over Σ decode span, over the completed
/// requests with at least two output tokens and a span past the floor.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SettledThroughput {
    pub decode_ms: f64,
    pub output_tokens: f64,
    pub samples: u64,
    pub requests: u64,
}
impl SettledThroughput {
    pub fn add(&mut self, decode_ms: Option<f64>, output_tokens: Option<f64>) {
        self.requests += 1;
        self.fold(decode_ms, output_tokens);
    }
    /// The sample alone, without counting a request.
    fn fold(&mut self, decode_ms: Option<f64>, output_tokens: Option<f64>) {
        let (Some(decode), Some(output)) = (duration(decode_ms), output_tokens) else {
            return;
        };
        if decode < MINIMUM_DECODE_SPAN_MS || !output.is_finite() || output < 2.0 {
            return;
        }
        self.decode_ms += decode;
        self.output_tokens += output - 1.0;
        self.samples += 1;
    }
    pub fn tokens_per_second(&self) -> Option<f64> {
        if self.samples == 0
            || !self.decode_ms.is_finite()
            || self.decode_ms <= 0.0
            || self.output_tokens.is_nan()
            || self.output_tokens < 0.0
        {
            return None;
        }
        let rate = self.output_tokens / (self.decode_ms / 1000.0);
        rate.is_finite().then_some(rate)
    }
    /// `34 tok/s`, or nothing when no request reported both figures.
    pub fn label(&self) -> Option<String> {
        self.tokens_per_second()
            .map(crate::metric_format::throughput)
    }
}

/// A reported total and the part of it from the same requests
/// (`GatewayTokenSplit`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TokenSplit {
    pub total: f64,
    pub part: f64,
    pub samples: u64,
}
impl TokenSplit {
    pub fn valid(&self) -> bool {
        self.samples > 0
            && self.total.is_finite()
            && self.part.is_finite()
            && self.part >= 0.0
            && self.total >= self.part
    }
}

/// A sum over the requests that reported a value, and how many did.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Reported {
    pub sum: f64,
    pub samples: u64,
}
impl Reported {
    fn add(&mut self, value: Option<f64>) {
        if let Some(value) = value {
            self.sum += value;
            self.samples += 1;
        }
    }
    /// SQL `SUM`: nothing over no samples.
    pub fn value(&self) -> Option<f64> {
        (self.samples > 0 && self.sum.is_finite() && self.sum >= 0.0).then_some(self.sum)
    }
}

/// Session totals: `GatewayTotals` as `gatewayAggregateSQL` sums them over a
/// session's dispatched requests.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GatewayTotals {
    pub requests: u64,
    pub turn_count: u64,
    pub cost: Reported,
    pub cache_read: Reported,
    pub cache_write: Reported,
    pub input: Reported,
    pub output: Reported,
    /// Requests reporting both input and output: their sum.
    pub total: Reported,
    pub reasoning: Reported,
    pub input_split: Option<TokenSplit>,
    pub output_split: Option<TokenSplit>,
    pub throughput: SettledThroughput,
    pub ttft: Reported,
    /// The latest request's dispatch, seconds since 1970.
    pub last_activity: Option<f64>,
}
impl GatewayTotals {
    pub fn of<'a>(records: impl IntoIterator<Item = &'a RequestRecord>) -> Self {
        let mut totals = Self::default();
        let mut turns = std::collections::BTreeSet::new();
        let (mut input_split, mut output_split) = (TokenSplit::default(), TokenSplit::default());
        for record in records {
            totals.requests += 1;
            if let Some(turn) = &record.turn {
                turns.insert(turn.as_str());
            }
            let usage = &record.usage;
            let f = |value: Option<u64>| value.map(|n| n as f64);
            totals
                .cost
                .add(record.cost.usd.filter(|_| record.cost.status == "reported"));
            totals.cache_read.add(f(usage.cache_read));
            totals.cache_write.add(f(usage.cache_write));
            totals.input.add(f(usage.input));
            totals.output.add(f(usage.output));
            totals.total.add(
                usage
                    .input
                    .zip(usage.output)
                    .map(|(a, b)| a as f64 + b as f64),
            );
            totals.reasoning.add(f(usage.reasoning));
            if let (Some(input), Some(read)) = (usage.input, usage.cache_read)
                && input >= read
            {
                input_split.total += input as f64;
                input_split.part += read as f64;
                input_split.samples += 1;
            }
            if let (Some(output), Some(reasoning)) = (usage.output, usage.reasoning)
                && output >= reasoning
            {
                output_split.total += output as f64;
                output_split.part += reasoning as f64;
                output_split.samples += 1;
            }
            // `settledThroughputSQL` folds only completed requests in, but
            // counts nothing else into the rate's own request total.
            if record.outcome == "completed" {
                totals.throughput.fold(record.stream_ms, f(usage.output));
            }
            totals.ttft.add(duration(record.ttft_ms));
            if record.wall.is_finite() && record.wall > 0.0 {
                totals.last_activity = Some(
                    totals
                        .last_activity
                        .map_or(record.wall, |w| w.max(record.wall)),
                );
            }
        }
        totals.turn_count = turns.len() as u64;
        totals.throughput.requests = totals.requests;
        totals.input_split = (input_split.samples > 0).then_some(input_split);
        totals.output_split = (output_split.samples > 0).then_some(output_split);
        totals
    }
    /// `GatewayTokenSplit.reported(_, input: true)`.
    pub fn reported_input_split(&self) -> Option<TokenSplit> {
        self.input_split.filter(TokenSplit::valid)
    }
    /// `billedTotalTokens`: reported input plus reported output.
    pub fn billed_total_tokens(&self) -> Option<f64> {
        match (self.input.value(), self.output.value()) {
            (None, None) => None,
            (a, b) => Some(a.unwrap_or(0.0) + b.unwrap_or(0.0)),
        }
    }
    /// `cacheHitPercent`: two places, over the requests reporting both.
    pub fn cache_hit_percent(&self) -> Option<String> {
        let split = self.reported_input_split()?;
        crate::metric_format::padded_cache_hit_percent(split.part, split.total, 2)
    }
    /// `settledLatency.average`.
    pub fn average_ttft_ms(&self) -> Option<f64> {
        (self.ttft.samples > 0).then(|| self.ttft.sum / self.ttft.samples as f64)
    }
}

/// The latest completed request's settled rate (`SessionRatePresentation`).
/// Only a completed request supplies it; a running one does not replace it.
pub fn latest_completed_rate(records: &[RequestRecord]) -> Option<f64> {
    records
        .iter()
        .rev()
        .find(|record| record.outcome == "completed")
        .and_then(RequestRecord::settled_tokens_per_second)
}

/// `SessionRatePresentation.label`: `Latest 34 tok/s`.
pub fn latest_rate_label(records: &[RequestRecord]) -> Option<String> {
    latest_completed_rate(records).map(|rate| format!("Latest {}", compact_rate(rate)))
}

/// `SessionRatePresentation.compactRate`.
pub fn compact_rate(value: f64) -> String {
    if !(value.is_finite() && value >= 0.0) {
        return "Unavailable".into();
    }
    if value >= 999_500.0 {
        return format!("{:.1}M tok/s", value / 1_000_000.0).replace(".0M", "M");
    }
    if value >= 10_000.0 {
        return format!("{:.0}K tok/s", value / 1000.0);
    }
    if value >= 999.5 {
        return format!("{:.1}K tok/s", value / 1000.0).replace(".0K", "K");
    }
    // `SessionTimingMetric.rate.label`.
    if value > 0.0 && value < 1.0 {
        format!("{value:.2} tok/s")
    } else {
        format!("{value:.0} tok/s")
    }
}

#[cfg(test)]
#[path = "accounting_tests.rs"]
mod tests;
