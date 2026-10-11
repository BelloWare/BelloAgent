use super::*;

const ORACLE: &str = "../../docs/validation/accounting-2026-10-11";
fn oracle(name: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join(ORACLE)
        .join(name);
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}
fn number(value: Option<u64>) -> Option<f64> {
    value.map(|n| n as f64)
}

/// Every usage/cost observation matches Swift's `UsageObservation.normalized`,
/// `GatewayTelemetry` and `GatewayObservation` over the same input.
#[test]
fn usage_and_cost_match_the_swift_oracle() {
    let cases = oracle("usage-cases.json");
    let swift = oracle("swift-app.json");
    let expected = swift["observations"].as_array().unwrap();
    assert_eq!(cases.as_array().unwrap().len(), expected.len());
    for (case, expected) in cases.as_array().unwrap().iter().zip(expected) {
        let name = case["name"].as_str().unwrap();
        assert_eq!(expected["name"], name);
        let usage = RequestUsage::normalized(&case["raw"], case["api"].as_str().unwrap());
        assert_eq!(
            number(usage.input),
            expected["input"].as_f64(),
            "{name} input"
        );
        assert_eq!(
            number(usage.output),
            expected["output"].as_f64(),
            "{name} output"
        );
        assert_eq!(
            number(usage.cache_read),
            expected["cacheRead"].as_f64(),
            "{name} cacheRead"
        );
        assert_eq!(
            number(usage.cache_write),
            expected["cacheWrite"].as_f64(),
            "{name} cacheWrite"
        );
        assert_eq!(
            number(usage.reasoning),
            expected["reasoning"].as_f64(),
            "{name} reasoning"
        );
        let streaming = case["streaming"].as_bool().unwrap();
        let mut cost = CostEvidence::default();
        cost.head(
            case["headers"]["x-litellm-response-cost"].as_str(),
            streaming,
            &|_| false,
        );
        for event in case["events"].as_array().unwrap() {
            cost.body(event, streaming, &|_| false);
        }
        let cost = cost.cost();
        assert_eq!(cost.status, expected["costStatus"], "{name} cost status");
        assert_eq!(cost.usd, expected["costUSD"].as_f64(), "{name} cost");
    }
}

fn records(session: &Value) -> Vec<RequestRecord> {
    serde_json::from_value(session["records"].clone()).unwrap()
}

/// The totals match Swift's archive SQL (`gatewayAggregateSQL`, run in
/// SQLite by the oracle) read through `PayloadArchive.gatewayTotals`.
#[test]
fn session_totals_match_the_swift_archive_sql() {
    let sessions = oracle("sessions.json");
    let swift = oracle("swift-app.json");
    for (session, expected) in sessions
        .as_array()
        .unwrap()
        .iter()
        .zip(swift["sessions"].as_array().unwrap())
    {
        let name = session["name"].as_str().unwrap();
        let records = records(session);
        records.iter().for_each(|r| r.validate().unwrap());
        let totals = GatewayTotals::of(&records);
        assert_eq!(
            Some(totals.requests),
            expected["requests"].as_u64(),
            "{name}"
        );
        assert_eq!(
            Some(totals.turn_count),
            expected["turns"].as_u64(),
            "{name}"
        );
        assert_eq!(
            totals.billed_total_tokens(),
            expected["billedTotal"].as_f64(),
            "{name}"
        );
        assert_eq!(
            totals
                .cache_hit_percent()
                .map_or(Value::Null, Value::String),
            expected["cacheHit"],
            "{name}"
        );
        let close = |a: Option<f64>, b: &Value| match (a, b.as_f64()) {
            (None, None) => true,
            (Some(a), Some(b)) => (a - b).abs() <= 1e-9 * b.abs().max(1.0),
            _ => false,
        };
        assert!(
            close(
                totals.throughput.tokens_per_second(),
                &expected["throughput"]
            ),
            "{name} throughput {:?} vs {}",
            totals.throughput.tokens_per_second(),
            expected["throughput"]
        );
        assert!(
            close(totals.average_ttft_ms(), &expected["ttft"]),
            "{name} ttft"
        );
        assert_eq!(
            totals.last_activity,
            expected["lastActivity"].as_f64(),
            "{name}"
        );
        assert_eq!(
            latest_rate_label(&records).map_or(Value::Null, Value::String),
            expected["latestRate"],
            "{name}"
        );
    }
}

/// The SQL the oracle ran is the archive's, verbatim; the Rust fold agrees
/// with it column by column over the same requests in SQLite here too.
#[test]
fn rust_fold_agrees_with_the_archive_sql_in_sqlite() {
    let sql = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(ORACLE)
            .join("gateway-aggregate.sql"),
    )
    .unwrap();
    for session in oracle("sessions.json").as_array().unwrap() {
        let records = records(session);
        let db = rusqlite::Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE attempts(outcome TEXT,turn TEXT,cost_usd REAL,cache_status TEXT,cache_read_tokens INTEGER,cache_write_tokens INTEGER,input_tokens INTEGER,output_tokens INTEGER,reasoning_tokens INTEGER,reasoning_cost_usd REAL,stream_ms REAL,ttft_ms REAL,wall REAL)").unwrap();
        for r in &records {
            let n = |v: Option<u64>| v.map(|n| n as i64);
            db.execute(
                "INSERT INTO attempts VALUES(?1,?2,?3,'unreported',?4,?5,?6,?7,?8,NULL,?9,?10,?11)",
                rusqlite::params![
                    r.outcome,
                    r.turn,
                    r.cost.usd,
                    n(r.usage.cache_read),
                    n(r.usage.cache_write),
                    n(r.usage.input),
                    n(r.usage.output),
                    n(r.usage.reasoning),
                    r.stream_ms,
                    r.ttft_ms,
                    r.wall
                ],
            )
            .unwrap();
        }
        let query = sql
            .lines()
            .filter(|line| !line.starts_with("--"))
            .collect::<Vec<_>>()
            .join("\n");
        let row: Vec<Option<f64>> = db
            .query_row(&query, [], |row| {
                (0..row.as_ref().column_count())
                    .map(|i| row.get::<_, Option<f64>>(i))
                    .collect()
            })
            .unwrap();
        let column = |name: &str| {
            let stmt = db.prepare(&query).unwrap();
            let index = stmt.column_index(name).unwrap();
            row[index]
        };
        let totals = GatewayTotals::of(&records);
        let name = session["name"].as_str().unwrap();
        let pairs = [
            (
                "cost_usd",
                totals.cost.value(),
                totals.cost.samples,
                "cost_samples",
            ),
            (
                "cache_read_tokens",
                totals.cache_read.value(),
                totals.cache_read.samples,
                "cache_read_samples",
            ),
            (
                "cache_write_tokens",
                totals.cache_write.value(),
                totals.cache_write.samples,
                "cache_write_samples",
            ),
            (
                "input_tokens",
                totals.input.value(),
                totals.input.samples,
                "input_samples",
            ),
            (
                "output_tokens",
                totals.output.value(),
                totals.output.samples,
                "output_samples",
            ),
            (
                "total_tokens",
                totals.total.value(),
                totals.total.samples,
                "token_samples",
            ),
            (
                "reasoning_tokens",
                totals.reasoning.value(),
                totals.reasoning.samples,
                "reasoning_samples",
            ),
            (
                "ttft_ms",
                totals.ttft.value(),
                totals.ttft.samples,
                "ttft_samples",
            ),
        ];
        for (sum, value, samples, count) in pairs {
            assert_eq!(column(sum), value, "{name} {sum}");
            assert_eq!(column(count), Some(samples as f64), "{name} {count}");
        }
        assert_eq!(column("requests"), Some(totals.requests as f64), "{name}");
        assert_eq!(
            column("turn_count"),
            Some(totals.turn_count as f64),
            "{name}"
        );
        assert_eq!(
            column("decode_samples"),
            Some(totals.throughput.samples as f64),
            "{name}"
        );
        assert_eq!(
            column("decode_ms"),
            (totals.throughput.samples > 0).then_some(totals.throughput.decode_ms),
            "{name}"
        );
        assert_eq!(
            column("split_input_total"),
            totals.input_split.map(|s| s.total),
            "{name}"
        );
        assert_eq!(column("last_wall"), totals.last_activity, "{name}");
    }
}

#[test]
fn a_record_round_trips_and_rejects_invalid_values() {
    let record = RequestRecord {
        id: "a".into(),
        purpose: "turn".into(),
        turn: Some("t".into()),
        reply: Some("r".into()),
        wall: 1.0,
        requested_model: "m".into(),
        outcome: "completed".into(),
        usage: RequestUsage {
            input: Some(1),
            ..Default::default()
        },
        cost: RequestCost {
            status: "reported".into(),
            usd: Some(0.5),
        },
        ttft_ms: Some(1.0),
        stream_ms: None,
        request_ms: None,
        usage_binding: None,
    };
    record.validate().unwrap();
    let text = serde_json::to_string(&record).unwrap();
    assert_eq!(
        serde_json::from_str::<RequestRecord>(&text).unwrap(),
        record
    );
    for change in [
        (|r: &mut RequestRecord| r.ttft_ms = Some(-1.0)) as fn(&mut RequestRecord),
        |r| r.ttft_ms = Some(f64::NAN),
        |r| r.cost.usd = None,
        |r| r.cost.status = "unreported".into(),
        |r| r.outcome = "running".into(),
        |r| r.purpose = "title".into(),
        |r| r.id = String::new(),
        |r| r.wall = f64::INFINITY,
    ] {
        let mut bad = record.clone();
        change(&mut bad);
        assert!(bad.validate().is_err(), "{bad:?}");
    }
}

#[test]
fn an_undispatched_attempt_is_no_request() {
    let observation = AttemptObservation {
        id: "a".into(),
        ..Default::default()
    };
    assert!(observation.record("turn", None, None).is_none());
    let mut sent = observation.clone();
    sent.clock.dispatched();
    let record = sent.record("turn", Some("t"), None).unwrap();
    assert_eq!(record.outcome, "failed");
    assert_eq!(record.cost.status, "unreported");
    assert!(record.ttft_ms.is_none() && record.stream_ms.is_none());
}
