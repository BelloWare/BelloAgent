use super::{BRANCH_MARKER_TEXT, oracle_row, replay};
use serde_json::{Value, json};
use std::path::PathBuf;

/// Journals written by Swift 0.1.122's own session code driving scripted
/// chats, and Swift's replay of each (`AgentSession.replay`): harness in
/// rust/docs/validation/swift-import-oracle-2026-10-10.
fn data(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data/swift-journal")
        .join(name)
}

/// Equal as Swift's `JSON` is equal: every number a double.
fn same(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Number(a), Value::Number(b)) => a.as_f64() == b.as_f64(),
        (Value::Array(a), Value::Array(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(a, b)| same(a, b))
        }
        (Value::Object(a), Value::Object(b)) => {
            a.len() == b.len()
                && a.iter()
                    .all(|(key, value)| b.get(key).is_some_and(|other| same(value, other)))
        }
        _ => left == right,
    }
}

fn scenarios() -> Vec<String> {
    serde_json::from_slice(&std::fs::read(data("scenarios.json")).unwrap()).unwrap()
}

#[test]
fn journals_replay_as_swift_replays_them() {
    let mut different = Vec::new();
    for scenario in scenarios() {
        let swift: Value = serde_json::from_slice(
            &std::fs::read(data(&format!("{scenario}.swift.json"))).unwrap(),
        )
        .unwrap();
        let bytes = std::fs::read(data(&format!("{scenario}.jsonl"))).unwrap();
        let replay = replay(&bytes, swift["id"].as_str().unwrap())
            .unwrap_or_else(|error| panic!("{scenario}: {error}"));
        let visible = Value::Array(replay.visible.iter().map(oracle_row).collect());
        let context = json!(replay.context.iter().map(|row| &row.id).collect::<Vec<_>>());
        let state = replay.state.unwrap_or(Value::Null);
        for (what, rust, expected) in [
            ("visible", visible, swift["visible"].clone()),
            ("context", context, swift["context"].clone()),
            ("parent", replay.parent, swift["parent"].clone()),
            ("queue", state["queue"].clone(), swift["queue"].clone()),
            (
                "steering",
                state["steering"].clone(),
                swift["steering"].clone(),
            ),
            (
                "paused",
                state["queuePaused"].clone(),
                swift["queuePaused"].clone(),
            ),
        ] {
            if !same(&rust, &expected) {
                different.push(format!(
                    "{scenario} {what}\n  swift: {expected}\n  rust:  {rust}"
                ));
            }
        }
    }
    assert!(different.is_empty(), "{}", different.join("\n"));
}

#[test]
fn an_edit_leaves_swifts_marker_and_hides_the_old_turn() {
    let bytes = std::fs::read(data("edit.jsonl")).unwrap();
    let replay = replay(&bytes, "edit").unwrap();
    let shown: Vec<(&str, String)> = replay
        .visible
        .iter()
        .map(|row| {
            (
                row.role.as_str(),
                row.display_text.clone().unwrap_or(row.text()),
            )
        })
        .collect();
    assert_eq!(
        shown,
        [
            ("user", "Question one".to_owned()),
            ("assistant", "Answer one.".to_owned()),
            ("system", BRANCH_MARKER_TEXT.to_owned()),
            ("user", "Question two, edited".to_owned()),
            ("assistant", "Answer to the edit.".to_owned()),
        ]
    );
    // The abandoned turn stays in the history.
    assert!(replay.history.iter().any(|row| row.text() == "Answer two."));
}

fn refusal(bytes: &[u8], id: &str) -> String {
    match replay(bytes, id) {
        Ok(_) => panic!("accepted"),
        Err(error) => format!("{}: {}", error.code, error.message),
    }
}

#[test]
fn journals_swift_would_not_open_are_refused_with_its_reason() {
    let bytes = std::fs::read(data("plain.jsonl")).unwrap();
    // An unfinished last record.
    let torn = &bytes[..bytes.len() - 1];
    assert!(refusal(torn, "plain").contains("Incomplete journal tail"));
    // Another chat's journal.
    assert!(refusal(&bytes, "other").starts_with("session_identity"));
    // A record whose parent is not the record before it.
    let text = String::from_utf8(bytes.clone()).unwrap();
    let mut lines: Vec<&str> = text.lines().collect();
    lines.swap(5, 6);
    let swapped = lines.join("\n") + "\n";
    assert!(refusal(swapped.as_bytes(), "plain").contains("valid single branch"));
    // Pi history without the native marker.
    let header = text.lines().next().unwrap();
    let bare = format!("{header}\n");
    assert!(refusal(bare.as_bytes(), "plain").starts_with("legacy_session"));
}
