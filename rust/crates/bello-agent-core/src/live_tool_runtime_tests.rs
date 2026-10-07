use super::*;
use crate::{Lane, Profile, Reply, SessionStore, Submission, provider::ToolCall};
use serde_json::json;
use tokio_util::sync::CancellationToken;
fn active() -> (tempfile::TempDir, Arc<Controller>, Identity) {
    let root = tempfile::tempdir().unwrap();
    let mut store = SessionStore::open(root.path().join("session.json")).unwrap();
    let profile: Profile = serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":"http://127.0.0.1:12345","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
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
                    calls: vec![ToolCall {
                        id: "reused-call".into(),
                        name: "bash".into(),
                        arguments: json!({"command":"printf test"}),
                    }],
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
    let mut prepared = controller.display_snapshot(&inner);
    prepared.title = "legitimate queue/durable update".into();
    drop(inner);
    controller.stop().unwrap();
    controller.publish_prepared(prepared, identity.stop, false);
    let shown = controller.snapshot();
    assert_eq!(shown.title, "legitimate queue/durable update");
    assert!(shown.live_tools.is_empty());
}
