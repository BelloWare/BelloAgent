use super::*;
use crate::{Lane, Profile, Reply, SessionStore, Submission, provider::ToolCall};
use serde_json::json;
use tokio_util::sync::CancellationToken;
fn fixture_profile() -> Profile {
    serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":"http://127.0.0.1:12345","contextWindow":32000,"maxOutputTokens":4096})).unwrap()
}
fn calls(count: usize) -> Vec<ToolCall> {
    (0..count)
        .map(|index| ToolCall {
            id: if index == 0 {
                "reused-call".into()
            } else {
                format!("call-{index}")
            },
            name: if index % 2 == 0 {
                "mcp".into()
            } else {
                "ls".into()
            },
            arguments: json!({}),
        })
        .collect()
}
fn active() -> (tempfile::TempDir, Arc<Controller>, Identity) {
    active_with_calls(calls(1))
}
fn active_with_calls(calls: Vec<ToolCall>) -> (tempfile::TempDir, Arc<Controller>, Identity) {
    let root = tempfile::tempdir().unwrap();
    let mut store = SessionStore::open(root.path().join("session.json")).unwrap();
    let profile = fixture_profile();
    store
        .transact(|session| {
            session.submit(Submission::new("test".into(), Lane::FollowUp))?;
            session.start_next()?;
            Ok(())
        })
        .unwrap();
    let assistant = store.snapshot().active_reply.unwrap();
    store
        .transact(|session| {
            session.begin_tools(
                &assistant,
                &Reply {
                    text: String::new(),
                    reasoning: String::new(),
                    calls,
                    usage: serde_json::Value::Null,
                    status: "completed".into(),
                    provider_items: vec![],
                },
                &profile,
            )
        })
        .unwrap();
    let controller = Controller::new(store, None).unwrap();
    {
        let mut inner = controller.inner.lock().unwrap();
        inner.worker_running = true;
        let token = CancellationToken::new();
        inner.cancel = Some(token.clone());
        *controller.active_cancel.write().unwrap() = Some(token);
        controller.worker_active.store(true, Ordering::Release);
    }
    let identity = controller
        .live_tool_identity(&assistant, "reused-call")
        .unwrap();
    (root, controller, identity)
}
#[test]
fn rejects_delayed_out_of_order_terminal_stop_and_configuration_updates() {
    let (_root, controller, identity) = active();
    identity.update(0, "".into());
    identity.update(2, "hello".into());
    identity.update(1, "late old output".into());
    assert_eq!(&*controller.snapshot().live_tools[0].preview, "hello");
    identity.finish("Exit code: 3", ToolOutcome::Failed);
    identity.update(3, "late revival".into());
    assert_eq!(
        controller.snapshot().live_tools[0].outcome,
        Some(ToolOutcome::Failed)
    );
    let saved = serde_json::to_value(controller.snapshot()).unwrap();
    assert!(saved.get("live_tools").is_none());
    let (_root, controller, identity) = active();
    controller.stop().unwrap();
    identity.update(1, "late".into());
    assert!(controller.snapshot().live_tools.is_empty());
    let (_root, controller, identity) = active();
    controller.inner.lock().unwrap().configuration_epoch = Arc::new(());
    identity.update(1, "late".into());
    assert!(controller.snapshot().live_tools.is_empty());
}
#[test]
fn rejects_retired_controller_and_reused_call_on_new_worker_or_assistant() {
    let (_root, controller, identity) = active();
    controller.retire().unwrap();
    identity.update(1, "late".into());
    assert!(controller.snapshot().live_tools.is_empty());
    let (_root, controller, identity) = active();
    controller.inner.lock().unwrap().worker_epoch = Arc::new(());
    identity.update(1, "late".into());
    assert!(controller.snapshot().live_tools.is_empty());
    let (_root, controller, identity) = active();
    let mut wrong = identity.clone();
    wrong.assistant = "later-assistant".into();
    wrong.update(1, "late".into());
    assert!(controller.snapshot().live_tools.is_empty());
}

#[test]
fn lossy_utf8_preview_may_shrink_when_a_split_scalar_completes() {
    let (_root, controller, identity) = active();
    identity.update(1, "\u{fffd}".into());
    identity.update(2, "é".into());
    assert_eq!(&*controller.snapshot().live_tools[0].preview, "é");
}

#[test]
fn publication_rechecks_stop_inside_watch_barrier_after_preparation() {
    let (_root, controller, identity) = active();
    identity.update(1, "before stop".into());
    controller.stop().unwrap();
    let before = controller.revision();
    let mut inner = controller.inner.lock().unwrap();
    inner.live_tools[0].preview = "late prepared snapshot".into();
    controller.publish_live(&inner, identity.stop);
    assert_eq!(controller.revision(), before);
    assert_eq!(&*controller.snapshot().live_tools[0].preview, "before stop");
    controller.publish(&inner);
    assert!(controller.snapshot().live_tools.is_empty());
}

#[test]
fn prepared_generic_publication_after_stop_preserves_durable_state_but_strips_live_output() {
    let (_root, controller, identity) = active();
    identity.update(1, "before stop".into());
    let inner = controller.inner.lock().unwrap();
    let mut prepared = controller.prepare_find_publication(&inner);
    prepared.session.title = "legitimate queue/durable update".into();
    drop(inner);
    controller.stop().unwrap();
    controller.publish_prepared(prepared, identity.stop, false);
    let shown = controller.snapshot();
    assert_eq!(shown.title, "legitimate queue/durable update");
    assert!(shown.live_tools.is_empty());
}

#[test]
fn generic_terminal_result_is_bounded_utf8_and_image_payload_is_never_copied() {
    use crate::tool_content::ToolContent;
    let (_root, controller, identity) = active();
    let result = ToolResultRow {
        duration_us: Some(crate::tool_timing::DurationUs::new(125_000)),
        text: "🦀".repeat(MAX_LIVE_PREVIEW_BYTES),
        content: Some(Arc::new(ToolContent {
            blocks: vec![ContentBlock::Image {
                mime_type: "image/png".into(),
                data: "secret-base64-payload".repeat(100_000),
            }],
            stats: None,
        })),
        outcome: ToolOutcome::Completed,
    };
    identity.finish_result(&result);
    let snapshot = controller.snapshot();
    assert_eq!(snapshot.live_tools[0].duration_us, result.duration_us);
    let preview = &snapshot.live_tools[0].preview;
    assert!(preview.starts_with("[Image: image/png]\n🦀"));
    assert!(preview.len() <= MAX_LIVE_PREVIEW_BYTES);
    assert!(!preview.contains("secret-base64"));
    assert!(snapshot.messages.iter().all(|row| !matches!(
        row.tool_record,
        Some(crate::tool_history::ToolRecord::Result(_))
    )));
    identity.finish("late failure", ToolOutcome::Failed);
    assert_eq!(controller.snapshot().live_tools, snapshot.live_tools);

    let mut image_only = result.clone();
    image_only.text.clear();
    assert_eq!(terminal_preview(&image_only), "[Image: image/png]\n");
    let empty = ToolResultRow {
        duration_us: None,
        text: String::new(),
        content: None,
        outcome: ToolOutcome::NotExecuted,
    };
    assert_eq!(terminal_preview(&empty), "");
}

#[test]
fn many_calls_and_batches_have_fixed_collection_bounds_without_retired_reinsertion() {
    let count = MAX_LIVE_TOOL_CARDS * 3;
    let (_root, controller, first) = active_with_calls(calls(count));
    let mut retired = Vec::new();
    let mut assistant = first.assistant.clone();
    for batch in 0..20 {
        for (index, call) in calls(count).iter().enumerate() {
            let identity = controller.live_tool_identity(&assistant, &call.id);
            assert_eq!(identity.is_some(), index < MAX_LIVE_TOOL_CARDS);
            if let Some(identity) = identity {
                identity.update(1, "🦀".repeat(MAX_LIVE_PREVIEW_BYTES / 4));
                identity.finish(&"é".repeat(MAX_LIVE_PREVIEW_BYTES), ToolOutcome::Completed);
                retired.push(identity);
            }
        }
        let inner = controller.inner.lock().unwrap();
        assert_eq!(inner.live_tools.len(), MAX_LIVE_TOOL_CARDS);
        assert!(
            inner
                .live_tools
                .iter()
                .all(|view| view.assistant_id == assistant)
        );
        assert!(
            inner
                .live_tools
                .iter()
                .map(|view| view.preview.len())
                .sum::<usize>()
                <= MAX_LIVE_TOTAL_PREVIEW_BYTES
        );
        drop(inner);
        if batch == 19 {
            break;
        }
        let next = {
            let mut inner = controller.inner.lock().unwrap();
            inner
                .store
                .transact(|session| {
                    session.settle_tools(
                        &assistant,
                        (0..count)
                            .map(|_| ToolResultRow {
                                duration_us: None,
                                text: "durable".into(),
                                content: None,
                                outcome: ToolOutcome::Completed,
                            })
                            .collect(),
                        false,
                    )?;
                    let next = session.active_reply.clone().unwrap();
                    session.begin_tools(
                        &next,
                        &Reply {
                            text: String::new(),
                            reasoning: String::new(),
                            calls: calls(count),
                            usage: serde_json::Value::Null,
                            status: "completed".into(),
                            provider_items: vec![],
                        },
                        &fixture_profile(),
                    )?;
                    Ok(next)
                })
                .unwrap()
        };
        assistant = next;
        let current = controller
            .live_tool_identity(&assistant, "reused-call")
            .unwrap();
        current.finish("current", ToolOutcome::Unknown);
        for old in &retired {
            old.update(99, "stale stream".into());
            old.finish("stale terminal", ToolOutcome::Completed);
        }
        let inner = controller.inner.lock().unwrap();
        assert_eq!(inner.live_tools.len(), 1);
        assert_eq!(inner.live_tools[0].assistant_id, assistant);
        assert_eq!(&*inner.live_tools[0].preview, "current");
    }
}

#[test]
fn terminal_generic_results_reject_stop_retirement_configuration_and_new_worker() {
    for fence in 0..4 {
        let (_root, controller, identity) = active();
        match fence {
            0 => controller.stop().unwrap(),
            1 => controller.retire().unwrap(),
            2 => controller.inner.lock().unwrap().configuration_epoch = Arc::new(()),
            _ => controller.inner.lock().unwrap().worker_epoch = Arc::new(()),
        }
        identity.finish("late terminal", ToolOutcome::Completed);
        assert!(controller.snapshot().live_tools.is_empty());
    }
}

#[test]
fn terminal_outcome_classification_is_preserved_for_generic_calls() {
    for outcome in [
        ToolOutcome::Completed,
        ToolOutcome::Failed,
        ToolOutcome::Unknown,
        ToolOutcome::NotExecuted,
        ToolOutcome::Cancelled,
    ] {
        let (_root, controller, identity) = active();
        identity.update(1, "x".repeat(MAX_LIVE_PREVIEW_BYTES + 1));
        assert!(controller.snapshot().live_tools.is_empty());
        identity.finish_result(&ToolResultRow {
            duration_us: None,
            text: String::new(),
            content: None,
            outcome,
        });
        let shown = controller.snapshot();
        assert_eq!(shown.live_tools.len(), 1);
        assert_eq!(shown.live_tools[0].outcome, Some(outcome));
        assert!(shown.live_tools[0].preview.is_empty());
    }
}
