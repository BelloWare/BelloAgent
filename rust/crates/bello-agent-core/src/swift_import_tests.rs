use super::{Left, session};
use crate::compaction;
use crate::swift_journal::replay;
use crate::tool_history::{ToolOutcome, ToolRecord};
use crate::{Lane, RunState};
use serde_json::Value;
use std::path::PathBuf;

fn data(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data/swift-journal")
        .join(name)
}

fn imported(scenario: &str) -> (super::Imported, crate::swift_journal::Replay) {
    let swift: Value =
        serde_json::from_slice(&std::fs::read(data(&format!("{scenario}.swift.json"))).unwrap())
            .unwrap();
    let bytes = std::fs::read(data(&format!("{scenario}.jsonl"))).unwrap();
    let replay = replay(&bytes, swift["id"].as_str().unwrap()).unwrap();
    let imported = session(&replay, "00000000-0000-4000-8000-000000000001", scenario)
        .unwrap_or_else(|error| panic!("{scenario}: {error}"));
    (imported, replay)
}

/// Every chat Swift wrote imports as a session Rust's own checks accept, shows
/// what Swift showed (less progress rows and edit markers) and sends the
/// model exactly the context Swift would send.
#[test]
fn swift_chats_import_with_swifts_rows_and_model_context() {
    let scenarios: Vec<String> =
        serde_json::from_slice(&std::fs::read(data("scenarios.json")).unwrap()).unwrap();
    for scenario in scenarios {
        let (imported, replay) = imported(&scenario);
        let shown: Vec<&str> = replay
            .visible
            .iter()
            .filter(|row| !row.is_progress() && row.kind.as_deref() != Some("branch"))
            .map(|row| row.id.as_str())
            .collect();
        let messages: Vec<&str> = imported
            .session
            .messages
            .iter()
            .map(|message| message.id.as_str())
            .collect();
        assert_eq!(messages, shown, "{scenario}: rows");
        let context: Vec<&str> = compaction::active_context(&imported.session.messages)
            .unwrap()
            .into_iter()
            .map(|message| message.id.as_str())
            .collect();
        let swift_context: Vec<&str> = replay.context.iter().map(|row| row.id.as_str()).collect();
        assert_eq!(context, swift_context, "{scenario}: model context");
        assert_eq!(imported.left.unowned_results, 0, "{scenario}");
        assert_eq!(imported.left.unchecked_summaries, 0, "{scenario}");
        assert_eq!(imported.session.state, RunState::Idle);
    }
}

#[test]
fn tool_rounds_keep_their_calls_results_and_failures() {
    let (imported, _) = imported("tools");
    let results: Vec<(String, ToolOutcome, bool)> = imported
        .session
        .messages
        .iter()
        .filter_map(|message| match &message.tool_record {
            Some(ToolRecord::Result(result)) => {
                Some((message.text.clone(), result.outcome, result.is_error))
            }
            _ => None,
        })
        .collect();
    assert_eq!(
        results,
        [
            ("done first\nline two".into(), ToolOutcome::Completed, false),
            ("failed second".into(), ToolOutcome::Failed, true),
            ("done read\nline two".into(), ToolOutcome::Completed, false),
        ]
    );
    let calls: Vec<usize> = imported
        .session
        .messages
        .iter()
        .filter_map(|message| match &message.tool_record {
            Some(ToolRecord::Assistant(record)) => Some(record.calls.len()),
            _ => None,
        })
        .collect();
    assert_eq!(calls, [2, 1]);
    assert_eq!(imported.left.progress, 3, "the three tool-start rows");
}

#[test]
fn a_compaction_summary_becomes_a_rust_checkpoint() {
    let (imported, _) = imported("compaction");
    let summary = imported
        .session
        .messages
        .iter()
        .find(|message| message.compaction.is_some())
        .expect("a checkpoint");
    let checkpoint = summary.compaction.as_ref().unwrap();
    assert!(summary.text.starts_with(compaction::REPLAY_PREFIX));
    assert!(checkpoint.before_estimated_tokens > checkpoint.after_estimated_tokens);
    assert_eq!(checkpoint.source_ids.len(), 4);
    assert_eq!(imported.left.progress, 1);
}

#[test]
fn an_edited_chat_imports_its_current_branch() {
    let (imported, _) = imported("edit");
    let texts: Vec<&str> = imported
        .session
        .messages
        .iter()
        .map(|message| message.text.as_str())
        .collect();
    assert_eq!(
        texts,
        [
            "Question one",
            "Answer one.",
            "Question two, edited",
            "Answer to the edit."
        ]
    );
    assert_eq!(
        imported.left,
        Left {
            edit_markers: 1,
            hidden: 2,
            ..Left::default()
        }
    );
}

#[test]
fn steering_joins_the_task_it_steered() {
    let (imported, _) = imported("steer");
    let roots: Vec<(&str, Option<&str>)> = imported
        .session
        .messages
        .iter()
        .filter(|message| message.role == "user")
        .map(|message| (message.text.as_str(), message.task_root_id.as_deref()))
        .collect();
    assert_eq!(
        roots,
        [("Start", Some("t1")), ("Change course", Some("t1"))]
    );
}

#[test]
fn a_queued_message_comes_paused() {
    let bytes = std::fs::read(data("stopped.jsonl")).unwrap();
    let replay = replay(&bytes, "stopped").unwrap();
    let mut state = replay.state.clone().unwrap_or(Value::Null);
    state["queue"] = serde_json::json!([
        {"attachments": [], "commandID": "q1", "skills": [], "text": "Next, please", "turnID": "q1"},
        {"attachments": [{"kind": "image"}], "commandID": "q2", "skills": [], "text": "With a picture", "turnID": "q2"}
    ]);
    let replay = crate::swift_journal::Replay {
        state: Some(state),
        ..replay
    };
    let imported = session(&replay, "00000000-0000-4000-8000-000000000002", "stopped").unwrap();
    let pending: Vec<(&str, Lane)> = imported
        .session
        .pending
        .iter()
        .map(|item| (item.text.as_str(), item.lane.clone()))
        .collect();
    assert_eq!(pending, [("Next, please", Lane::FollowUp)]);
    assert!(imported.session.queue_paused);
    assert_eq!(imported.left.queued_with_content, 1);
}
