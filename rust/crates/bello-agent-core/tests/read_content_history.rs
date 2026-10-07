//! Synthetic content only: durability/projection never rereads a filesystem path.
use bello_agent_core::{
    Message, Profile, SessionStore,
    provider::{ToolCall, request_body},
    tool_content::{ContentBlock, ReadStats, TOOL_IMAGE_PLACEHOLDER, ToolContent},
    tool_history::{
        AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
    },
};
use serde_json::{Value, json};
use std::sync::Arc;

fn profile(images: bool) -> Profile {
    serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":"http://127.0.0.1:12345","contextWindow":32000,"maxOutputTokens":4096,"input":if images{vec!["text","image"]}else{vec!["text"]}})).unwrap()
}
fn row(id: &str, role: &str, text: &str) -> Message {
    Message {
        task_root_id: None,
        user_content: None,
        id: id.into(),
        role: role.into(),
        text: text.into(),
        reasoning: String::new(),
        replay_eligible: true,
        state: "completed".into(),
        usage: Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
    }
}
fn history() -> Vec<Message> {
    let mut assistant = row("assistant", "assistant", "");
    assistant.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
        completion: Completion::Complete,
        calls: vec![ToolCall {
            id: "read-call".into(),
            name: "read".into(),
            arguments: json!({"path":"never-reread-fixture.png"}),
        }],
        binding: ReplayBinding::from_profile(&profile(true)).unwrap(),
        provider_items: vec![],
    }));
    let note = "Read image file [image/png]";
    let content = ToolContent {
        blocks: vec![
            ContentBlock::Text { text: note.into() },
            ContentBlock::Image {
                data: "YWJj".into(),
                mime_type: "image/png".into(),
            },
        ],
        stats: Some(ReadStats {
            path: "/synthetic/never-reread-fixture.png".into(),
            line: None,
            last_line: None,
            added: None,
            removed: None,
        }),
    };
    let mut result = row("result", "toolResult", note);
    result.tool_record = Some(ToolRecord::Result(ResultRecord {
        assistant_id: "assistant".into(),
        call_id: "read-call".into(),
        is_error: false,
        outcome: ToolOutcome::Completed,
        content: Some(Arc::new(content)),
    }));
    vec![assistant, result]
}
#[test]
fn durable_image_content_survives_reopen_and_replays_by_model_capability() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|session| {
            session.messages = history();
            Ok(())
        })
        .unwrap();
    assert_eq!(store.snapshot().version, 4);
    let expected = serde_json::to_value(&store.snapshot().messages).unwrap();
    drop(store);
    let reopened = SessionStore::open(&path).unwrap();
    let messages = reopened.snapshot().messages;
    assert_eq!(serde_json::to_value(&messages).unwrap(), expected);
    let capable = request_body(&profile(true), &messages, "", "session").unwrap();
    assert_eq!(
        capable["input"][1]["output"],
        json!([
            {"type":"input_text","text":"Read image file [image/png]"},
            {"type":"input_image","detail":"auto","image_url":"data:image/png;base64,YWJj"}
        ])
    );
    let text = request_body(&profile(false), &messages, "", "session").unwrap();
    assert_eq!(
        text["input"][1]["output"],
        format!("Read image file [image/png]\n{TOOL_IMAGE_PLACEHOLDER}")
    );
    assert!(text.get("tools").is_none());
}
#[test]
fn content_disagreement_or_invalid_payload_fails_without_rewriting_history() {
    let mut messages = history();
    let original = serde_json::to_value(&messages).unwrap();
    messages[1].text = "Different visible output".into();
    assert!(request_body(&profile(true), &messages, "", "session").is_err());
    messages = serde_json::from_value(original).unwrap();
    let Some(ToolRecord::Result(record)) = &mut messages[1].tool_record else {
        unreachable!()
    };
    let content = Arc::make_mut(record.content.as_mut().unwrap());
    let ContentBlock::Image { data, .. } = &mut content.blocks[1] else {
        unreachable!()
    };
    *data = "not base64".into();
    assert!(request_body(&profile(true), &messages, "", "session").is_err());
}
#[test]
fn result_payload_is_shared_across_immutable_snapshot_clones() {
    let messages = history();
    let copied = messages.clone();
    let (Some(ToolRecord::Result(a)), Some(ToolRecord::Result(b))) =
        (&messages[1].tool_record, &copied[1].tool_record)
    else {
        unreachable!()
    };
    assert!(Arc::ptr_eq(
        a.content.as_ref().unwrap(),
        b.content.as_ref().unwrap()
    ));
}
#[test]
fn legacy_result_serialization_has_no_new_empty_content_field() {
    let raw = json!({"kind":"result","assistant_id":"a","call_id":"c","is_error":false,"outcome":"completed"});
    let record: ToolRecord = serde_json::from_value(raw.clone()).unwrap();
    assert_eq!(serde_json::to_value(record).unwrap(), raw);
}

#[test]
fn version_four_content_cannot_be_loaded_as_legacy_and_failed_read_preserves_bytes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|session| {
            session.messages = history();
            Ok(())
        })
        .unwrap();
    store
        .transact(|session| {
            session.error = Some("fixture".into());
            Ok(())
        })
        .unwrap();
    assert_eq!(store.snapshot().version, 4);
    drop(store);
    let mut raw: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    raw["version"] = json!(3);
    let bytes = serde_json::to_vec(&raw).unwrap();
    std::fs::write(&path, &bytes).unwrap();
    assert!(SessionStore::open(&path).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
}

#[test]
fn aggregate_image_projection_refuses_wire_overflow_but_text_only_projection_stays_small() {
    let mut template = history();
    let Some(ToolRecord::Result(record)) = &mut template[1].tool_record else {
        unreachable!()
    };
    let content = Arc::make_mut(record.content.as_mut().unwrap());
    let ContentBlock::Image { data, .. } = &mut content.blocks[1] else {
        unreachable!()
    };
    *data = "A".repeat(4 * 1024 * 1024);
    let mut messages = Vec::new();
    for index in 0..9 {
        let mut pair = template.clone();
        pair[0].id = format!("assistant-{index}");
        pair[1].id = format!("result-{index}");
        let Some(ToolRecord::Result(record)) = &mut pair[1].tool_record else {
            unreachable!()
        };
        record.assistant_id = format!("assistant-{index}");
        messages.extend(pair);
    }
    assert!(request_body(&profile(true), &messages, "", "session").is_err());
    let text = request_body(&profile(false), &messages, "", "session").unwrap();
    assert!(serde_json::to_vec(&text).unwrap().len() < 10_000);
    for message in messages
        .iter_mut()
        .filter(|message| message.role == "assistant")
    {
        message.replay_eligible = false;
    }
    assert_eq!(
        request_body(&profile(true), &messages, "", "session").unwrap()["input"],
        json!([])
    );
}
