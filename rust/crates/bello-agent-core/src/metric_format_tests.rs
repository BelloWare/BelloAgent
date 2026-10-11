use super::*;
use serde_json::Value;

fn swift() -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../docs/validation/accounting-2026-10-11/swift-app.json");
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}
fn text(value: Option<String>) -> Value {
    value.map_or(Value::Null, Value::String)
}

/// Every figure is written exactly as Swift's `MetricFormat` writes it.
#[test]
fn formats_match_the_swift_oracle() {
    let swift = swift();
    let formats = &swift["formats"];
    for case in formats["tokens"].as_array().unwrap() {
        let value = case["value"].as_f64().unwrap();
        assert_eq!(tokens(value), case["tokens"], "{value}");
        assert_eq!(token_count(value), case["tokenCount"], "{value}");
        assert_eq!(row_token_count(value), case["rowTokenCount"], "{value}");
        assert_eq!(
            compact_tokens(Some(value)),
            case["compactTokens"],
            "{value}"
        );
        assert_eq!(
            menu_bar_tokens(Some(value)),
            case["menuBarTokens"],
            "{value}"
        );
        assert_eq!(latency(value), case["latency"], "{value}");
        assert_eq!(throughput(value), case["throughput"], "{value}");
        assert_eq!(
            crate::accounting::compact_rate(value),
            case["compactRate"],
            "{value}"
        );
    }
    for case in formats["money"].as_array().unwrap() {
        let value = case["value"].as_f64().unwrap();
        assert_eq!(exact_usd(value, true), case["exactUSD"], "{value}");
        assert_eq!(gateway_usd(Some(value)), case["gatewayUSD"], "{value}");
        assert_eq!(
            compact_gateway_usd(Some(value)),
            case["compactGatewayUSD"],
            "{value}"
        );
        assert_eq!(precise_decimal(value), case["preciseDecimal"], "{value}");
        assert_eq!(
            text((value > 0.0).then(|| cents_usd(value, 4, true))),
            case["centsUSD"],
            "{value}"
        );
    }
    for case in formats["cacheHit"].as_array().unwrap() {
        let (read, prompt) = (
            case["read"].as_f64().unwrap(),
            case["prompt"].as_f64().unwrap(),
        );
        assert_eq!(
            text(cache_hit_percent(read, prompt, 0)),
            case["percent"],
            "{read}/{prompt}"
        );
        assert_eq!(
            text(padded_cache_hit_percent(read, prompt, 2)),
            case["padded"],
            "{read}/{prompt}"
        );
    }
    for case in formats["occupancy"].as_array().unwrap() {
        let fraction = case["fraction"].as_f64().unwrap();
        assert_eq!(
            text(occupancy_percent(fraction, 0)),
            case["percent"],
            "{fraction}"
        );
        assert_eq!(
            text(occupancy_percent(fraction, 1)),
            case["detail"],
            "{fraction}"
        );
    }
}

#[test]
fn unavailable_values_never_read_as_zero() {
    assert_eq!(tokens(f64::NAN), "—");
    assert_eq!(gateway_usd(None), "Cost unavailable");
    assert_eq!(compact_gateway_usd(Some(-1.0)), "cost n/a");
    assert_eq!(compact_tokens(None), "n/a");
    assert_eq!(menu_bar_tokens(None), "Unavailable");
    assert_eq!(cache_hit_percent(1.0, 0.0, 0), None);
}
