use super::*;
use crate::accounting::RequestRecord;
use serde_json::Value;

fn oracle(name: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../docs/validation/accounting-2026-10-11")
        .join(name);
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

/// The pills and the reference read as Swift's `SessionStatsPresentation`
/// and `SessionReference` read the archive's totals for the same requests.
#[test]
fn pills_and_reference_match_the_swift_oracle() {
    let sessions = oracle("sessions.json");
    let swift = oracle("swift-app.json");
    for (session, expected) in sessions
        .as_array()
        .unwrap()
        .iter()
        .zip(swift["sessions"].as_array().unwrap())
    {
        let name = session["name"].as_str().unwrap();
        let records: Vec<RequestRecord> =
            serde_json::from_value(session["records"].clone()).unwrap();
        let totals = GatewayTotals::of(&records);
        let stats = StatsPresentation { gateway: &totals };
        assert_eq!(stats.gauge_label(), expected["gauge"], "{name}");
        assert_eq!(stats.usage_label(), expected["usage"], "{name}");
        assert_eq!(stats.usage_face().label, expected["usageFace"], "{name}");
        assert_eq!(
            stats.compact_usage_face().label,
            expected["compactUsageFace"],
            "{name}"
        );
        assert_eq!(stats.has_usage(), expected["hasUsage"], "{name}");
        assert_eq!(
            stats.cost_figure().map_or(Value::Null, Value::String),
            expected["costFigure"],
            "{name}"
        );
        assert_eq!(
            Value::from(reference_usage_lines(&totals)),
            expected["referenceUsage"],
            "{name}"
        );
    }
}

#[test]
fn row_figures_follow_chat_row_stats() {
    let none = GatewayTotals::default();
    let row = RowStats { gateway: &none };
    assert_eq!(row.cost_label(), None);
    assert_eq!(row.tokens_label(), None);
    let records: Vec<RequestRecord> = serde_json::from_value(serde_json::json!([
        {"id":"a","purpose":"turn","wall":1.0,"requested_model":"m","outcome":"completed",
         "usage":{"input":12000,"output":300,"cache_read":8100},"cost":{"status":"reported","usd":0.00499}},
        {"id":"b","purpose":"turn","wall":2.0,"requested_model":"m","outcome":"failed",
         "usage":{},"cost":{"status":"unreported"}}
    ]))
    .unwrap();
    let totals = GatewayTotals::of(&records);
    let row = RowStats { gateway: &totals };
    assert_eq!(row.cost_label().as_deref(), Some("$0.0050"));
    assert_eq!(row.tokens_label().as_deref(), Some("12.3K tok"));
    assert_eq!(
        row.usage_help(),
        "Session tokens · input 12,000 (1/2 requests reported) · cached input 8,100 (1/2 reported) · output 300 (1/2 reported). Input counts cached tokens once; reasoning is included in output. Context size is shown below the composer."
    );
    let failed: Vec<RequestRecord> = records[1..].to_vec();
    let totals = GatewayTotals::of(&failed);
    let row = RowStats { gateway: &totals };
    assert_eq!(row.cost_label().as_deref(), Some("cost n/a"));
    assert_eq!(row.tokens_label().as_deref(), Some("tok n/a"));
}
