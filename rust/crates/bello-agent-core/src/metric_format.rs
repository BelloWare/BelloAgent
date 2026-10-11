//! How a figure is written on a pill, a sidebar row and a session reference:
//! Swift 0.1.122 `MetricFormat` (Design/MetricFormats.swift), with
//! `compactTokens` and `menuBarTokens` (Dashboard/MenuBarMetrics.swift) and
//! `gatewayUSD`/`compactGatewayUSD` (Dashboard/GatewayAccounting.swift).
//!
//! Money is rounded half-up on the decimal an amount is written as (Swift
//! reads `"\(value)"`, the shortest round-trip form, as a `Decimal`); Rust's
//! `Display` for `f64` gives the same shortest digits, never an exponent.

fn observed(value: f64) -> Option<f64> {
    (value.is_finite() && value >= 0.0).then_some(value)
}

/// `TranscriptActivity.grouped`: `15,800`.
pub fn grouped(value: f64) -> String {
    let rounded = value.round();
    if !rounded.is_finite() || rounded.abs() >= 9.223_372_036_854_776e18 {
        return "—".into();
    }
    let whole = rounded as i64;
    let digits = whole.unsigned_abs().to_string();
    let mut out = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            out.push(',');
        }
        out.push(digit);
    }
    if whole < 0 { format!("-{out}") } else { out }
}

fn whole(value: f64) -> String {
    grouped(value).replace(',', "")
}

/// A trailing zero says nothing: `50.0` is `50`, `12.20` is `12.2`.
fn trimmed(value: f64, places: usize) -> String {
    let mut text = format!("{value:.places$}");
    if !text.contains('.') {
        return text;
    }
    while text.ends_with('0') {
        text.pop();
    }
    if text.ends_with('.') {
        text.pop();
    }
    text
}

fn scaled(value: f64) -> String {
    if value >= 100.0 {
        whole(value.round())
    } else {
        trimmed((value * 10.0).round() / 10.0, 1)
    }
}

const UNITS: [(f64, &str); 3] = [(1_000.0, "K"), (1_000_000.0, "M"), (1_000_000_000.0, "B")];

/// `517`, `12.2K`, `517K`, `1.2M`.
pub fn tokens(value: f64) -> String {
    let Some(value) = observed(value) else {
        return "—".into();
    };
    if value.round() < 1_000.0 {
        return whole(value);
    }
    for (index, (scale, letter)) in UNITS.iter().enumerate() {
        let amount = value / scale;
        let shown = if amount >= 100.0 {
            amount.round()
        } else {
            (amount * 10.0).round() / 10.0
        };
        if shown < 1_000.0 || index == UNITS.len() - 1 {
            return scaled(amount) + letter;
        }
    }
    "—".into()
}

/// `15.8K tok`.
pub fn token_count(value: f64) -> String {
    tokens(value) + " tok"
}

/// `12.3K tok`: a sidebar row's count, one decimal of its unit always.
pub fn row_token_count(value: f64) -> String {
    let Some(value) = observed(value) else {
        return "—".into();
    };
    if value.round() < 1_000.0 {
        return whole(value) + " tok";
    }
    for (index, (scale, letter)) in UNITS.iter().enumerate() {
        let tenths = (value / scale * 10.0).round();
        if tenths < 10_000.0 || index == UNITS.len() - 1 {
            return format!("{:.1}{letter} tok", tenths / 10.0);
        }
    }
    "—".into()
}

/// `cacheHitPercent`: an honest share, never `100` unless every token hit and
/// never `0` unless none did.
pub fn cache_hit_percent(read: f64, prompt: f64, decimals: usize) -> Option<String> {
    let (read, prompt) = (observed(read)?, observed(prompt)?);
    if prompt <= 0.0 || read > prompt {
        return None;
    }
    if prompt - read <= 0.0 {
        return Some("100".into());
    }
    let ratio = read / prompt * 100.0;
    let mut places = decimals.min(6);
    if read > 0.0 && (ratio * 10f64.powi(places as i32)).round() == 0.0 {
        return Some(format!(
            "<{}",
            trimmed(10f64.powi(-(places as i32)), places)
        ));
    }
    while places <= 9 {
        let scale = 10f64.powi(places as i32);
        let rounded = (ratio * scale).round() / scale;
        if rounded < 100.0 {
            return Some(trimmed(rounded, places));
        }
        places += 1;
    }
    Some("99.999999999".into())
}

/// `paddedCacheHitPercent`: `50.00`, `75.94`, `100.00`.
pub fn padded_cache_hit_percent(read: f64, prompt: f64, decimals: usize) -> Option<String> {
    let text = cache_hit_percent(read, prompt, decimals)?;
    if text.starts_with('<') {
        return Some(text);
    }
    let (integer, fraction) = text.split_once('.').unwrap_or((&text, ""));
    if fraction.len() >= decimals {
        return Some(text);
    }
    Some(format!(
        "{integer}.{fraction}{}",
        "0".repeat(decimals - fraction.len())
    ))
}

/// `occupancyPercent`: the context ring's reading without its sign.
pub fn occupancy_percent(fraction: f64, decimals: usize) -> Option<String> {
    if !(fraction.is_finite() && fraction >= 0.0) {
        return None;
    }
    let text = cache_hit_percent(fraction.min(1.0) * 1_000_000.0, 1_000_000.0, decimals)?;
    Some(if text == "0" && fraction > 0.0 {
        "<1".into()
    } else {
        text
    })
}

/// `latency`: `92 ms`, `1.2s`, `12s`.
pub fn latency(milliseconds: f64) -> String {
    let Some(ms) = observed(milliseconds).filter(|v| *v < i64::MAX as f64) else {
        return "—".into();
    };
    if ms.round() < 1_000.0 {
        return whole(ms.round()) + " ms";
    }
    let seconds = ms / 1000.0;
    (if seconds < 10.0 {
        trimmed((seconds * 10.0).round() / 10.0, 1)
    } else {
        whole(seconds.round())
    }) + "s"
}

/// `throughputValue`.
pub fn throughput_value(tokens_per_second: f64) -> String {
    let Some(value) = observed(tokens_per_second) else {
        return "—".into();
    };
    if value >= 10.0 {
        whole(value.round())
    } else {
        trimmed((value * 10.0).round() / 10.0, 1)
    }
}

/// `34 tok/s`, `3.4 tok/s`.
pub fn throughput(tokens_per_second: f64) -> String {
    let value = throughput_value(tokens_per_second);
    if value == "—" {
        value
    } else {
        value + " tok/s"
    }
}

/// A non-negative decimal digit string (no exponent): `"0.000421875"`.
fn digits_of(value: f64) -> String {
    format!("{value}")
}

/// Half-up rounding of a plain decimal string at `places`, written as
/// `NSDecimalNumber.stringValue` writes it: no trailing zeros, `0` for zero.
fn half_up(text: &str, places: usize) -> String {
    let (integer, fraction) = text.split_once('.').unwrap_or((text, ""));
    let mut digits: Vec<u8> = integer
        .bytes()
        .chain(fraction.bytes().chain(std::iter::repeat(b'0')).take(places))
        .map(|b| b - b'0')
        .collect();
    let round_up = fraction.as_bytes().get(places).is_some_and(|d| *d >= b'5');
    if round_up {
        let mut index = digits.len();
        loop {
            if index == 0 {
                digits.insert(0, 1);
                break;
            }
            index -= 1;
            if digits[index] == 9 {
                digits[index] = 0;
            } else {
                digits[index] += 1;
                break;
            }
        }
    }
    let split = digits.len() - places;
    let mut whole: String = digits[..split]
        .iter()
        .map(|d| char::from(b'0' + d))
        .collect();
    let mut frac: String = digits[split..]
        .iter()
        .map(|d| char::from(b'0' + d))
        .collect();
    while frac.ends_with('0') {
        frac.pop();
    }
    let trimmed = whole.trim_start_matches('0');
    whole = if trimmed.is_empty() {
        "0".into()
    } else {
        trimmed.into()
    };
    if frac.is_empty() {
        whole
    } else {
        format!("{whole}.{frac}")
    }
}

/// `preciseDecimal`: up to twelve places, half-up; six significant digits
/// for a nonzero amount below 10^-12.
pub fn precise_decimal(value: f64) -> String {
    if !(value.is_finite() && value >= 0.0) {
        return "—".into();
    }
    if value > 0.0 && value < 0.000_000_000_001 {
        return c_g6(value);
    }
    half_up(&digits_of(value), 12)
}

/// C's `%.6g` for a tiny positive value: `1.23457e-13`.
fn c_g6(value: f64) -> String {
    let text = format!("{value:.5e}");
    let (mantissa, exponent) = text.split_once('e').unwrap_or((&text, "0"));
    let mut mantissa = mantissa.to_owned();
    if mantissa.contains('.') {
        while mantissa.ends_with('0') {
            mantissa.pop();
        }
        if mantissa.ends_with('.') {
            mantissa.pop();
        }
    }
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let sign = if exponent < 0 { '-' } else { '+' };
    format!("{mantissa}e{sign}{:02}", exponent.abs())
}

/// `atLeastCents`: `1.5` is `1.50`, `0` is `0.00`; more places stay.
pub fn at_least_cents(digits: &str) -> String {
    if digits.contains(['e', 'E']) {
        return digits.into();
    }
    let (integer, fraction) = digits.split_once('.').unwrap_or((digits, ""));
    if fraction.len() >= 2 {
        return digits.into();
    }
    format!("{integer}.{fraction}{}", "0".repeat(2 - fraction.len()))
}

/// Three significant digits and an exponent, half-up: `1.23e-9`, and
/// 9.999e-9 is `1.00e-8`.
fn scientific(value: f64) -> String {
    let digits = digits_of(value);
    let (integer, fraction) = digits.split_once('.').unwrap_or((&digits, ""));
    let all = format!("{integer}{fraction}");
    let Some(first) = all.bytes().position(|b| b != b'0') else {
        return "0.00e0".into();
    };
    let mut exponent = integer.len() as i32 - 1 - first as i32;
    let significant = &all[first..];
    let mantissa = format!("{}.{}", &significant[..1], &significant[1..]);
    let mut rounded = half_up(&mantissa, 2);
    if rounded.starts_with("10") {
        rounded = "1".into();
        exponent += 1;
    }
    format!("{}e{exponent}", fixed(&rounded, 2))
}

/// `exactUSD`: `$0.00042188 USD`.
pub fn exact_usd(value: f64, unit: bool) -> String {
    let amount = if value == 0.0 {
        "0".to_owned()
    } else if value < 0.000_000_01 {
        scientific(value)
    } else {
        half_up(&digits_of(value), 8)
    };
    format!(
        "${}{}",
        at_least_cents(&amount),
        if unit { " USD" } else { "" }
    )
}

/// `gatewayUSD`.
pub fn gateway_usd(value: Option<f64>) -> String {
    match value.filter(|v| v.is_finite() && *v >= 0.0) {
        Some(value) => exact_usd(value, true),
        None => "Cost unavailable".into(),
    }
}

/// `compactGatewayUSD`: `$0.00`, `$0.50`, `$0.0042`.
pub fn compact_gateway_usd(value: Option<f64>) -> String {
    match value.filter(|v| v.is_finite() && *v >= 0.0) {
        Some(value) => format!(
            "${}",
            at_least_cents(&if value == 0.0 {
                "0".into()
            } else {
                precise_decimal(value)
            })
        ),
        None => "cost n/a".into(),
    }
}

/// A rounded amount with exactly `places` decimals: `4.10`, `0.0050`.
fn fixed(text: &str, places: usize) -> String {
    let (integer, fraction) = text.split_once('.').unwrap_or((text, ""));
    format!(
        "{integer}.{fraction}{}",
        "0".repeat(places.saturating_sub(fraction.len()))
    )
}

/// `centsUSD`: `$4.13`, `$0.0042`, `<$0.0001`. `value` is finite and above zero.
pub fn cents_usd(value: f64, places: usize, padded: bool) -> String {
    let digits = digits_of(value);
    let small = half_up(&digits, places);
    let small_value: f64 = small.parse().unwrap_or(0.0);
    if small_value >= 0.01 {
        return format!("${}", fixed(&half_up(&digits, 2), 2));
    }
    if small_value == 0.0 {
        return format!("<$0.{}1", "0".repeat(places.saturating_sub(1)));
    }
    format!("${}", if padded { fixed(&small, places) } else { small })
}

/// `menuBarTokens`: `15,800`, or `Unavailable`.
pub fn menu_bar_tokens(value: Option<f64>) -> String {
    match value.filter(|v| v.is_finite() && *v >= 0.0) {
        Some(value) => grouped(value),
        None => "Unavailable".into(),
    }
}

/// `compactTokens`: `812`, `1.2K`, `12K`, `1.2M`, or `n/a`.
pub fn compact_tokens(value: Option<f64>) -> String {
    let Some(value) = value.filter(|v| v.is_finite() && *v >= 0.0) else {
        return "n/a".into();
    };
    if value >= 1_000_000.0 {
        return format!("{:.1}M", value / 1_000_000.0).replace(".0M", "M");
    }
    if value >= 10_000.0 {
        return format!("{:.0}K", value / 1000.0);
    }
    if value >= 1_000.0 {
        return format!("{:.1}K", value / 1000.0).replace(".0K", "K");
    }
    format!("{value:.0}")
}

#[cfg(test)]
#[path = "metric_format_tests.rs"]
mod tests;
