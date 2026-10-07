//! The v4 media payload and result outcome share one atomic checkpoint. Failed
//! publication never turns an executed read into a replayable filesystem action.
use super::*;
use crate::{
    provider::ToolCall,
    runtime::tool_runtime::ToolResultRow,
    tool_content::{ContentBlock, ToolContent},
    tool_history::{ToolOutcome, ToolRecord},
};
use serde_json::json;
use std::sync::Arc;

fn active(path: &Path) -> (SessionStore, String) {
    let mut store = SessionStore::open(path).unwrap();
    store
        .transact(|s| {
            s.submit(Submission::new("fixture".into(), Lane::FollowUp))?;
            s.start_next()?;
            Ok(())
        })
        .unwrap();
    let id = store.snapshot().active_reply.unwrap();
    let profile=serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":"http://127.0.0.1:9","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let reply = Reply {
        text: String::new(),
        reasoning: String::new(),
        calls: vec![ToolCall {
            id: "read-fixture".into(),
            name: "read".into(),
            arguments: json!({"path":"does-not-exist"}),
        }],
        usage: Value::Null,
        status: "completed".into(),
        provider_items: vec![],
    };
    store
        .transact(|s| s.begin_tools(&id, &reply, &profile))
        .unwrap();
    (store, id)
}
fn result(data: String) -> ToolResultRow {
    let text = "Read image file [image/png]".to_owned();
    ToolResultRow {
        text: text.clone(),
        outcome: ToolOutcome::Completed,
        content: Some(Arc::new(ToolContent {
            blocks: vec![
                ContentBlock::Text { text },
                ContentBlock::Image {
                    data,
                    mime_type: "image/png".into(),
                },
            ],
            stats: None,
        })),
    }
}
#[test]
fn image_outcome_payload_and_version_share_before_after_rename_certainty() {
    for (fault, committed) in [
        (WriteFault::BeforeRename, false),
        (WriteFault::AfterRename, true),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let (mut store, id) = active(&path);
        let before = fs::read(&path).unwrap();
        store.fault = fault;
        assert!(
            store
                .transact(|s| s.settle_tools(&id, vec![result("YWJj".into())], true))
                .is_err()
        );
        assert_eq!(store.snapshot().version, 3);
        assert!(store.snapshot().active_tool_calls().is_some());
        if committed {
            assert!(store.uncertain);
            store.fault = WriteFault::None;
            assert!(store.transact(|_| Ok(())).is_err());
        } else {
            assert_eq!(fs::read(&path).unwrap(), before);
        }
        drop(store);
        let restored = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(restored.version, if committed { 4 } else { 3 });
        let record = restored
            .messages
            .iter()
            .find_map(|m| match &m.tool_record {
                Some(ToolRecord::Result(record)) => Some(record),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            record.outcome,
            if committed {
                ToolOutcome::Completed
            } else {
                ToolOutcome::Unknown
            }
        );
        assert_eq!(record.content.is_some(), committed);
        assert!(restored.active_tool_calls().is_none());
    }
}
#[test]
fn snapshot_capacity_failure_preserves_admitted_calls_for_unknown_recovery() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let (mut store, id) = active(&path);
    let before = fs::read(&path).unwrap();
    store.snapshot_limit = store.encoded_bytes + RECOVERY_RESERVE_BYTES + 1024;
    assert!(
        store
            .transact(|s| s.settle_tools(&id, vec![result("A".repeat(256 * 1024))], true))
            .is_err()
    );
    assert_eq!(fs::read(&path).unwrap(), before);
    drop(store);
    let restored = SessionStore::open(&path).unwrap().snapshot();
    assert_eq!(restored.version, 3);
    assert!(restored.messages.iter().any(|m|matches!(&m.tool_record,Some(ToolRecord::Result(record)) if record.outcome==ToolOutcome::Unknown&&record.content.is_none())));
}

#[test]
fn snapshot_writer_bounds_escaped_bytes_and_final_newline_exactly() {
    let session = Session::new();
    let encoded = encode_snapshot(&session).unwrap();
    assert!(encoded.ends_with(b"\n"));
    assert_eq!(
        encode_snapshot_with_limit(&session, encoded.len()).unwrap(),
        encoded
    );
    assert!(encode_snapshot_with_limit(&session, encoded.len() - 1).is_err());
    assert!(encode_snapshot_with_limit(&session, 0).is_err());
    let mut escaped = session.clone();
    escaped.title = "\u{0000}".repeat(2048);
    assert!(encode_snapshot_with_limit(&escaped, encoded.len() + 4096).is_err());
    let exact = encode_snapshot(&escaped).unwrap();
    assert_eq!(
        encode_snapshot_with_limit(&escaped, exact.len()).unwrap(),
        exact
    );
}
