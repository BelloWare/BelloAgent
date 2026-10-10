//! Every tool row and work summary in the corpus, held to what Swift 0.1.122's
//! own code says of it (docs/validation/tool-row-swift-oracle-2026-10-10).
use super::*;
use serde_json::{Value, json};

const CORPUS: &str =
    include_str!("../../../docs/validation/tool-row-swift-oracle-2026-10-10/corpus.json");
const SWIFT: &str =
    include_str!("../../../docs/validation/tool-row-swift-oracle-2026-10-10/swift-tool-rows.json");

fn text(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}
fn number(value: &Value, key: &str) -> Option<u32> {
    value.get(key).and_then(Value::as_u64).map(|n| n as u32)
}

fn rust_row(tool: &Value) -> Value {
    let input = tool["input"].as_str().unwrap();
    let arguments: Value =
        serde_json::from_str(input).unwrap_or_else(|_| Value::String(input.to_owned()));
    let path = text(tool, "path");
    let facts = ToolFacts {
        name: tool["name"].as_str().unwrap(),
        arguments: &arguments,
        state: tool["state"].as_str().unwrap(),
        output: tool["output"].as_str().unwrap(),
        duration_us: tool["durationMs"]
            .as_f64()
            .map(|ms| (ms * 1000.).round() as u64),
        path: path.as_deref(),
        added: number(tool, "added"),
        removed: number(tool, "removed"),
        line: tool
            .get("line")
            .and_then(Value::as_i64)
            .map(|n| n.max(0) as u32),
        last_line: tool
            .get("lastLine")
            .and_then(Value::as_i64)
            .map(|n| n.max(0) as u32),
        input_truncated: tool.get("inputTruncated").and_then(Value::as_bool) == Some(true),
    };
    let m = model(&facts);
    let mut row = json!({
        "icon": m.icon, "title": m.title, "summary": m.summary, "state": m.state.name(),
        "help": m.help, "linksSummary": m.links_summary, "kind": m.kind.name(), "verb": m.verb,
        "object": m.object, "outcome": m.outcome.name(),
    });
    let object = row.as_object_mut().unwrap();
    for (key, value) in [
        ("suffix", m.suffix),
        ("trailing", m.trailing),
        ("path", m.path),
    ] {
        if let Some(value) = value {
            object.insert(key.into(), value.into());
        }
    }
    if let Some(file) = m.file {
        object.insert("filePath".into(), file.path.into());
        if let Some(lines) = file.lines {
            object.insert("fileLines".into(), json!([lines.start(), lines.end()]));
        }
    }
    row
}

#[test]
fn every_tool_row_reads_as_swift_reads_it() {
    let corpus: Value = serde_json::from_str(CORPUS).unwrap();
    let swift: Value = serde_json::from_str(SWIFT).unwrap();
    let tools = corpus["tools"].as_array().unwrap();
    let expected = swift["rows"].as_array().unwrap();
    assert_eq!(tools.len(), expected.len());
    assert!(tools.len() > 600, "the corpus covers every rule");
    let mismatches: Vec<String> = tools
        .iter()
        .zip(expected)
        .filter_map(|(tool, swift)| {
            let rust = rust_row(tool);
            (&rust != swift).then(|| format!("{tool}\n  rust:  {rust}\n  swift: {swift}"))
        })
        .collect();
    assert!(
        mismatches.is_empty(),
        "{} of {} rows differ:\n{}",
        mismatches.len(),
        tools.len(),
        mismatches.join("\n")
    );
}

#[test]
fn every_work_summary_reads_as_swift_reads_it() {
    let corpus: Value = serde_json::from_str(CORPUS).unwrap();
    let swift: Value = serde_json::from_str(SWIFT).unwrap();
    let cases = corpus["summaries"].as_array().unwrap();
    let expected = swift["summaries"].as_array().unwrap();
    assert_eq!(cases.len(), expected.len());
    for (case, swift) in cases.iter().zip(expected) {
        let mut summary = CallSummary::default();
        let mut owners = std::collections::HashSet::new();
        for row in case["rows"].as_array().unwrap() {
            // Swift counts each reply once.
            if !owners.insert(row["id"].as_str().unwrap()) {
                continue;
            }
            summary.add_reply(
                row["tools"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|tool| tool["state"].as_str().unwrap()),
                row.get("toolCallCount").and_then(Value::as_i64),
                row.get("truncated").and_then(Value::as_bool) == Some(true),
            );
        }
        let label = summary.label(case["reasoned"].as_bool().unwrap());
        assert_eq!(label.as_deref(), swift.as_str(), "{case}");
    }
}
