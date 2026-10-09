use super::*;
use crate::{Delta, Reply, read_observation::OutputProjection};
fn controller() -> (tempfile::TempDir, Arc<Controller>) {
    let directory = tempfile::tempdir().unwrap();
    let controller = Controller::new(
        SessionStore::open(directory.path().join("session.json")).unwrap(),
        None,
    )
    .unwrap();
    (directory, controller)
}
fn start(controller: &Controller) -> String {
    let mut inner = controller.inner.lock().unwrap();
    inner
        .store
        .transact(|session| {
            session.submit(Submission::new("fixture".into(), Lane::FollowUp))?;
            session.start_next()?;
            Ok(())
        })
        .unwrap();
    controller.publish(&inner);
    inner.store.snapshot_ref().active_reply.clone().unwrap()
}
fn finish(controller: &Controller, id: &str, success: bool, publish: bool) {
    let mut inner = controller.inner.lock().unwrap();
    inner
        .store
        .transact(|session| {
            session.finish(
                id,
                if success {
                    Ok(Reply {
                        text: "done".into(),
                        reasoning: String::new(),
                        calls: vec![],
                        usage: serde_json::Value::Null,
                        status: "completed".into(),
                        provider_items: vec![],
                    })
                } else {
                    Err(invalid("failed"))
                },
            )
        })
        .unwrap();
    if publish {
        controller.publish(&inner);
    }
}
#[test]
fn completion_before_subscription_and_start_coalescence_retain_terminal() {
    let (_directory, controller) = controller();
    let id = start(&controller);
    finish(&controller, &id, true, true);
    let expected = controller.read_observation();
    let mut watch = controller.subscribe_read_observation();
    assert_eq!(*watch.borrow_and_update(), expected);
    start(&controller);
    assert!(watch.borrow_and_update().busy);
    assert_eq!(watch.borrow().terminal, expected.terminal);
}
#[test]
fn failure_retry_before_watch_read_retains_occurrence() {
    let (_directory, controller) = controller();
    let id = start(&controller);
    let mut watch = controller.subscribe_read_observation();
    finish(&controller, &id, false, true);
    {
        let mut inner = controller.inner.lock().unwrap();
        inner
            .store
            .transact(|session| session.retry_turn())
            .unwrap();
        controller.publish(&inner);
    }
    let observation = watch.borrow_and_update().clone();
    assert!(observation.busy);
    assert_eq!(observation.failure_sequence, 1);
    assert_eq!(observation.terminal.unwrap().sequence, 1);
}
#[test]
fn streamed_tokens_and_live_tool_publications_do_not_notify_read_watch() {
    let (_directory, controller) = controller();
    let id = start(&controller);
    let mut watch = controller.subscribe_read_observation();
    let expected = watch.borrow_and_update().clone();
    for _ in 0..25 {
        controller
            .stream_delta(&id, Delta::Text("x".into()))
            .unwrap();
    }
    let inner = controller.inner.lock().unwrap();
    for _ in 0..25 {
        controller.publish_live(&inner, controller.stop_epoch.load(Ordering::Acquire));
    }
    drop(inner);
    assert!(!watch.has_changed().unwrap());
    assert_eq!(controller.read_observation(), expected);
}
#[test]
fn display_fatal_is_not_an_accepted_failure() {
    let (_directory, controller) = controller();
    let id = start(&controller);
    let expected = controller.read_observation();
    {
        let mut inner = controller.inner.lock().unwrap();
        inner.fatal = Some("display-only persistence problem".into());
        controller.publish(&inner);
    }
    assert_eq!(controller.snapshot_shared().state, RunState::Error);
    assert_eq!(controller.read_observation(), expected);
    assert_eq!(controller.read_observation().failure_sequence, 0);
    assert!(!id.is_empty());
}
#[test]
fn direct_final_capture_does_not_require_queued_publication() {
    let (_directory, controller) = controller();
    let id = start(&controller);
    let watch = controller.subscribe_read_observation();
    finish(&controller, &id, true, false);
    assert!(watch.borrow().terminal.is_none());
    let final_capture = controller.read_observation();
    assert_eq!(final_capture.terminal.as_ref().unwrap().sequence, 1);
    assert!(!final_capture.busy);
    // Writer retirement leaves the already accepted evidence available for the
    // shutdown barrier after joins, without reviving mutation authority.
    controller.inner.lock().unwrap().store.retire_writer();
    assert_eq!(controller.read_observation(), final_capture);
}
#[test]
fn uncertain_checkpoint_invalidates_current_and_published_projection() {
    let (_directory, controller) = controller();
    let id = start(&controller);
    {
        let mut inner = controller.inner.lock().unwrap();
        inner.store.fault = crate::session::WriteFault::AfterRename;
        assert!(
            inner
                .store
                .transact(|session| session.finish(&id, Err(invalid("failed"))))
                .is_err()
        );
        inner.fatal = Some("uncertain commit".into());
        controller.publish(&inner);
    }
    let observed = controller.read_observation();
    assert_eq!(observed.history, OutputProjection::Unknown);
    assert_eq!(observed.failure_sequence, 0);
    assert!(observed.terminal.is_none());
    assert_eq!(*controller.subscribe_read_observation().borrow(), observed);
}
