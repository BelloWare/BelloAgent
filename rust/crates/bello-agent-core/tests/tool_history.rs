use bello_agent_core::{
    Message, Profile, SessionStore,
    provider::{ToolCall, request_body},
    tool_history::{
        self, AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
    },
};
use serde_json::{Value, json};

fn profile() -> Profile {
    serde_json::from_value(json!({"id":"fixture-connection","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":"http://127.0.0.1:12345","contextWindow":32000,"maxOutputTokens":4096})).unwrap()
}
fn message(id: &str, role: &str, text: &str) -> Message {
    Message {
        id: id.into(),
        role: role.into(),
        text: text.into(),
        reasoning: String::new(),
        replay_eligible: true,
        state: "completed".into(),
        usage: Value::Null,
        model: None,
        tool_record: None,
    }
}
fn assistant(id: &str, calls: &[&str]) -> Message {
    let mut message = message(id, "assistant", "");
    message.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
        completion: Completion::Complete,
        calls: calls
            .iter()
            .map(|id| ToolCall {
                id: (*id).into(),
                name: "ls".into(),
                arguments: json!({"path":"fixture-only"}),
            })
            .collect(),
        binding: ReplayBinding::from_profile(&profile()).unwrap(),
        provider_items: vec![],
    }));
    message
}
fn result(id: &str, owner: &str, call: &str, text: &str) -> Message {
    let mut message = message(id, "toolResult", text);
    message.tool_record = Some(ToolRecord::Result(ResultRecord {
        assistant_id: owner.into(),
        call_id: call.into(),
        is_error: false,
        outcome: ToolOutcome::Completed,
    }));
    message
}
fn record(message: &mut Message) -> &mut AssistantRecord {
    match message.tool_record.as_mut().unwrap() {
        ToolRecord::Assistant(record) => record,
        _ => panic!("assistant expected"),
    }
}
fn with_opaque(mut message: Message) -> Message {
    let record = record(&mut message);
    record
        .provider_items
        .push(json!({"type":"reasoning","encrypted_content":"synthetic-opaque-fixture"}));
    for call in &record.calls {
        record.provider_items.push(json!({"type":"function_call","call_id":call.id,"id":format!("fc_{}",call.id),"name":call.name,"arguments":serde_json::to_string(&call.arguments).unwrap()}));
    }
    message
}

#[test]
fn old_text_snapshot_and_wire_shape_are_unchanged() {
    let old = json!({"id":"old-user","role":"user","text":"old text","reasoning":"","replay_eligible":true,"state":"complete","usage":null,"model":null});
    let user: Message = serde_json::from_value(old.clone()).unwrap();
    assert!(user.tool_record.is_none());
    assert_eq!(serde_json::to_value(&user).unwrap(), old);
    let answer = message("old-answer", "assistant", "reply");
    let mut interrupted = message("partial", "assistant", "not replayed");
    interrupted.replay_eligible = false;
    let body = request_body(
        &profile(),
        &[user, answer, interrupted],
        "instruction",
        "session",
    )
    .unwrap();
    assert_eq!(
        body["input"],
        json!([
            {"role":"system","content":"instruction"},
            {"role":"user","content":[{"type":"input_text","text":"old text"}]},
            {"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"reply","annotations":[]}]}
        ])
    );
    assert!(body.get("tools").is_none());
}

#[test]
fn calls_and_unicode_results_project_in_call_order_without_offering_tools() {
    let history = vec![
        assistant("a", &["one", "two"]),
        result("r1", "a", "one", "世界\n😀"),
        result("r2", "a", "two", "second"),
    ];
    let original = serde_json::to_value(&history).unwrap();
    let body = request_body(&profile(), &history, "", "session").unwrap();
    let items = body["input"].as_array().unwrap();
    assert_eq!(items.len(), 4);
    assert_eq!(items[0]["type"], "function_call");
    assert_eq!(items[1]["call_id"], "two");
    assert_eq!(
        items[2],
        json!({"type":"function_call_output","call_id":"one","output":"世界\n😀"})
    );
    assert_eq!(items[3]["output"], "second");
    assert_eq!(serde_json::to_value(&history).unwrap(), original);
    assert!(body.get("tools").is_none());
}

#[test]
fn missing_results_are_explicit_placeholders_not_execution() {
    let history = vec![
        assistant("a", &["one", "two"]),
        result("r2", "a", "two", "retained"),
        message("u", "user", "continue"),
    ];
    let items = tool_history::project(&history, &profile()).unwrap();
    assert_eq!(items[2]["output"], tool_history::MISSING_RESULT);
    assert_eq!(items[3]["output"], "retained");
    assert_eq!(items[4]["role"], "user");
    assert_eq!(
        tool_history::project(&[assistant("a", &["one"])], &profile()).unwrap()[1]["output"],
        "No result provided"
    );
}

#[test]
fn reused_call_ids_are_scoped_to_their_assistant_message() {
    let history = vec![
        assistant("a", &["same"]),
        result("r1", "a", "same", "first"),
        assistant("b", &["same"]),
        result("r2", "b", "same", "second"),
    ];
    let items = tool_history::project(&history, &profile()).unwrap();
    assert_eq!(items[1]["output"], "first");
    assert_eq!(items[3]["output"], "second");
    let mut wrong = history;
    if let Some(ToolRecord::Result(result)) = &mut wrong[3].tool_record {
        result.assistant_id = "a".into();
    }
    assert!(tool_history::project(&wrong, &profile()).is_err());
}

#[test]
fn orphan_duplicate_and_out_of_order_results_are_rejected() {
    for history in [
        vec![result("orphan", "a", "one", "no owner")],
        vec![
            assistant("a", &["one"]),
            result("r", "a", "unknown", "wrong"),
        ],
        vec![
            assistant("a", &["one"]),
            result("r1", "a", "one", "first"),
            result("r2", "a", "one", "again"),
        ],
        vec![
            assistant("a", &["one", "two"]),
            result("r2", "a", "two", "second"),
            result("r1", "a", "one", "first"),
        ],
        vec![assistant("a", &["one", "one"])],
        vec![message("missing-metadata", "toolResult", "unowned")],
    ] {
        assert!(tool_history::project(&history, &profile()).is_err());
    }
}

#[test]
fn incomplete_and_cancelled_tool_history_cannot_leak_into_replay() {
    for completion in [Completion::Incomplete, Completion::Cancelled] {
        let mut call = assistant("a", &["one"]);
        record(&mut call).completion = completion;
        assert!(tool_history::validate(&[call.clone()]).is_err());
        call.replay_eligible = false;
        let history = vec![
            call,
            result("r", "a", "one", "retained but excluded"),
            message("u", "user", "next"),
        ];
        let items = tool_history::project(&history, &profile()).unwrap();
        assert_eq!(
            items,
            json!([{ "role":"user","content":[{"type":"input_text","text":"next"}]}])
                .as_array()
                .unwrap()
                .clone()
        );
    }
}

#[test]
fn opaque_replay_follows_source_default_ask_before_model_change_fallback() {
    let history = [with_opaque(assistant("a", &["one"]))];
    assert!(tool_history::project(&history, &profile()).is_err());
    let mut changed_model = profile();
    changed_model.model_id = "different-model".into();
    assert!(tool_history::project(&history, &changed_model).is_err());
    let mut changed_endpoint = profile();
    changed_endpoint.base_url = "http://127.0.0.1:23456".into();
    assert!(tool_history::project(&history, &changed_endpoint).is_err());
    let mut other_connection = profile();
    other_connection.id = "explicit-other-connection".into();
    let portable = tool_history::project(&history, &other_connection).unwrap();
    assert_eq!(portable[0]["type"], "function_call");
    assert!(portable[0].get("id").is_none());
    assert!(
        !serde_json::to_string(&portable)
            .unwrap()
            .contains("synthetic-opaque-fixture")
    );
}

#[test]
fn provider_item_identity_binding_and_unknown_fields_fail_closed() {
    let mut invalid_binding = assistant("a", &["one"]);
    record(&mut invalid_binding).binding.endpoint_sha256 = "not-a-hash".into();
    assert!(tool_history::validate(&[invalid_binding]).is_err());
    let mut unknown = assistant("a", &["one"]);
    record(&mut unknown).provider_items =
        vec![json!({"type":"web_search_call","id":"server-tool"})];
    assert!(tool_history::validate(&[unknown]).is_err());
    let mut mismatch = with_opaque(assistant("a", &["one"]));
    record(&mut mismatch).provider_items[1]["arguments"] = json!("{\"path\":\"different\"}");
    assert!(tool_history::validate(&[mismatch]).is_err());
    let mut raw = serde_json::to_value(assistant("a", &["one"])).unwrap();
    raw["tool_record"]["binding"]["credential"] = json!("must-not-be-a-binding-field");
    assert!(serde_json::from_value::<Message>(raw).is_err());
}

#[test]
fn bindings_omit_headers_and_credentials_and_do_not_copy_foreign_item_ids() {
    let mut p = profile();
    p.headers
        .insert("x-fixture-private".into(), "fixture-secret-value".into());
    let binding = serde_json::to_string(&ReplayBinding::from_profile(&p).unwrap()).unwrap();
    assert!(!binding.contains("fixture-secret-value"));
    assert!(!binding.contains("127.0.0.1"));
    let mut call = assistant("a", &["one"]);
    record(&mut call).provider_items = vec![
        json!({"type":"function_call","call_id":"one","id":"fc_one","name":"ls","arguments":"{\"path\":\"fixture-only\"}"}),
    ];
    assert_eq!(
        tool_history::project(&[call.clone()], &profile()).unwrap()[0]["id"],
        "fc_one"
    );
    let mut changed = profile();
    changed.id = "another-connection".into();
    assert!(
        tool_history::project(&[call], &changed).unwrap()[0]
            .get("id")
            .is_none()
    );
}

#[test]
fn typed_snapshots_upgrade_to_v3_while_plain_snapshots_stay_v2() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("fixture.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|s| {
            s.messages.push(message("u", "user", "plain"));
            Ok(())
        })
        .unwrap();
    assert_eq!(store.snapshot().version, 2);
    assert!(
        !std::fs::read_to_string(&path)
            .unwrap()
            .contains("tool_record")
    );
    store
        .transact(|s| {
            s.messages.extend([
                assistant("a", &["one"]),
                result("r", "a", "one", "fixture output"),
            ]);
            Ok(())
        })
        .unwrap();
    let expected = serde_json::to_value(store.snapshot()).unwrap();
    assert_eq!(expected["version"], 3);
    drop(store);
    let reopened = SessionStore::open(&path).unwrap();
    assert_eq!(serde_json::to_value(reopened.snapshot()).unwrap(), expected);
    assert_eq!(
        tool_history::project(&reopened.snapshot().messages, &profile()).unwrap()[2]["output"],
        "fixture output"
    );
}

#[test]
fn invalid_typed_load_never_rewrites_the_original_bytes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("fixture.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|s| {
            s.messages.push(assistant("a", &["one"]));
            Ok(())
        })
        .unwrap();
    drop(store);
    let valid: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    for version in [1, 2] {
        let mut malformed = valid.clone();
        malformed["version"] = json!(version);
        let bytes = serde_json::to_vec(&malformed).unwrap();
        std::fs::write(&path, &bytes).unwrap();
        assert!(SessionStore::open(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }
    let mut malformed = valid;
    malformed["messages"][0]["tool_record"]["binding"]["endpoint_sha256"] = json!("bad");
    let bytes = serde_json::to_vec(&malformed).unwrap();
    std::fs::write(&path, &bytes).unwrap();
    assert!(SessionStore::open(&path).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
}

#[test]
fn bound_item_order_and_typed_text_must_agree() {
    let mut call = assistant("a", &["one", "two"]);
    call.text = "between".into();
    record(&mut call).provider_items = vec![
        json!({"type":"function_call","call_id":"one","name":"ls","arguments":"{\"path\":\"fixture-only\"}"}),
        json!({"type":"message","phase":"commentary","content":[{"type":"output_text","text":"between"}]}),
        json!({"type":"function_call","call_id":"two","name":"ls","arguments":"{\"path\":\"fixture-only\"}"}),
    ];
    let items = tool_history::project(&[call.clone()], &profile()).unwrap();
    assert_eq!(items[0]["call_id"], "one");
    assert_eq!(items[1]["content"][0]["text"], "between");
    assert_eq!(items[1]["phase"], "commentary");
    assert_eq!(items[2]["call_id"], "two");
    let mut changed = profile();
    changed.id = "another-connection".into();
    changed.model_id = "another-model".into();
    let portable = tool_history::project(&[call.clone()], &changed).unwrap();
    assert_eq!(portable[0]["call_id"], "one");
    assert_eq!(portable[1]["content"][0]["text"], "between");
    assert_eq!(portable[2]["call_id"], "two");
    let mut mismatched = call.clone();
    mismatched.text = "different".into();
    assert!(tool_history::validate(&[mismatched]).is_err());
    record(&mut call).provider_items.swap(0, 2);
    assert!(tool_history::validate(&[call]).is_err());
}

#[test]
fn changed_connection_and_model_keep_only_portable_reasoning_summary() {
    let mut call = with_opaque(assistant("a", &["one"]));
    call.reasoning = "Synthetic visible summary".into();
    let mut target = profile();
    target.id = "another-connection".into();
    target.model_id = "another-model".into();
    let items = tool_history::project(&[call], &target).unwrap();
    assert_eq!(items[0]["content"][0]["text"], "Synthetic visible summary");
    assert!(
        !serde_json::to_string(&items)
            .unwrap()
            .contains("synthetic-opaque-fixture")
    );
}

#[test]
fn incomplete_items_unknown_call_fields_and_oversize_payloads_are_rejected() {
    let mut call = with_opaque(assistant("a", &["one"]));
    record(&mut call).provider_items[1]["status"] = json!("in_progress");
    assert!(tool_history::validate(&[call]).is_err());
    let mut raw = serde_json::to_value(assistant("a", &["one"])).unwrap();
    raw["tool_record"]["calls"][0]["unexpected"] = json!(true);
    assert!(serde_json::from_value::<Message>(raw).is_err());
    let mut call = assistant("a", &["one"]);
    record(&mut call).calls[0].arguments = json!({"path":"x".repeat(2 * 1024 * 1024)});
    assert!(tool_history::validate(&[call]).is_err());
    let huge = result("r", "a", "one", &"x".repeat(16 * 1024 * 1024 + 1));
    assert!(tool_history::validate(&[assistant("a", &["one"]), huge]).is_err());
}

#[test]
fn production_session_still_fails_visibly_on_unexpected_calls() {
    use bello_agent_core::{Lane, Reply, RunState, Session, Submission};
    let mut session = Session::new();
    session
        .submit(Submission::new("synthetic request".into(), Lane::FollowUp))
        .unwrap();
    session.start_next().unwrap();
    let reply_id = session.active_reply.clone().unwrap();
    session
        .finish(
            &reply_id,
            Ok(Reply {
                text: String::new(),
                reasoning: String::new(),
                calls: vec![ToolCall {
                    id: "unexpected".into(),
                    name: "ls".into(),
                    arguments: json!({}),
                }],
                usage: Value::Null,
                status: "completed".into(),
                provider_items: vec![],
            }),
        )
        .unwrap();
    assert_eq!(session.state, RunState::Error);
    assert_eq!(
        session.error.as_deref(),
        Some(
            "Provider requested tools, which are not enabled in this Rust slice. No tool was executed."
        )
    );
    assert!(
        session
            .messages
            .iter()
            .all(|message| message.tool_record.is_none())
    );
    assert!(!session.messages.last().unwrap().replay_eligible);
}

#[test]
fn refusal_replay_uses_the_validated_refusal_field() {
    let mut call = assistant("a", &["one"]);
    call.text = "Retained refusal".into();
    record(&mut call).provider_items = vec![
        json!({"type":"message","content":[{"type":"refusal","refusal":"Retained refusal","text":"not the refusal field"}]}),
        json!({"type":"function_call","call_id":"one","name":"ls","arguments":"{\"path\":\"fixture-only\"}"}),
    ];
    let items = tool_history::project(&[call], &profile()).unwrap();
    assert_eq!(items[0]["content"][0]["text"], "Retained refusal");
}

#[test]
fn empty_output_is_distinct_from_missing_output_and_whitespace_is_literal() {
    let history = vec![
        assistant("a", &["one", "two", "three"]),
        result("r1", "a", "one", ""),
        result("r2", "a", "two", " "),
    ];
    let items = tool_history::project(&history, &profile()).unwrap();
    assert_eq!(items[3]["output"], "(no tool output)");
    assert_eq!(items[4]["output"], " ");
    assert_eq!(items[5]["output"], "No result provided");
}

#[test]
fn contradictory_replay_eligible_states_are_rejected() {
    for state in [
        "streaming",
        "interrupted",
        "incomplete",
        "failed",
        "cancelled",
    ] {
        let mut call = assistant("a", &["one"]);
        call.state = state.into();
        assert!(tool_history::project(&[call.clone()], &profile()).is_err());
        call.replay_eligible = false;
        assert!(
            tool_history::project(&[call], &profile())
                .unwrap()
                .is_empty()
        );
        let mut output = result("r", "a", "one", "unfinished");
        output.state = state.into();
        assert!(tool_history::validate(&[assistant("a", &["one"]), output]).is_err());
    }
}
