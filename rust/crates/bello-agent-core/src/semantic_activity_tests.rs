use super::*;
use crate::{Delta, Lane, SessionStore, Submission};
use std::sync::Arc;

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

#[test]
fn coalesced_start_finish_retains_latest_semantic_boundary() {
    let (_directory, controller) = controller();
    let mut sessions = controller.subscribe();
    let mut activity = controller.subscribe_activity();
    let reply = start(&controller);
    let started = controller.activity();
    assert_eq!(started.sequence, 1);
    {
        let mut inner = controller.inner.lock().unwrap();
        inner
            .store
            .transact(|session| {
                session.finish(
                    &reply,
                    Ok(crate::Reply {
                        provider_items: Vec::new(),
                        text: "done".into(),
                        reasoning: String::new(),
                        calls: Vec::new(),
                        usage: serde_json::Value::Null,
                        status: "completed".into(),
                    }),
                )
            })
            .unwrap();
        controller.publish(&inner);
    }
    // Neither receiver observed the intermediate Running state.
    assert_eq!(sessions.borrow_and_update().state, RunState::Idle);
    let finished = *activity.borrow_and_update();
    assert_eq!(finished.sequence, 2);
    assert!(finished.timestamp_micros >= started.timestamp_micros);
    assert!(finished.timestamp_micros.is_some());
}

#[test]
fn thousand_stream_updates_and_inspection_have_no_activity() {
    let (_directory, controller) = controller();
    let reply = start(&controller);
    let before = controller.activity();
    for index in 0..1000 {
        let delta = match index % 3 {
            0 => Delta::Text("x".into()),
            1 => Delta::Reasoning("y".into()),
            _ => Delta::Tool {
                id: "call".into(),
                name: "ls".into(),
                arguments: "{}".into(),
            },
        };
        controller.stream_delta(&reply, delta).unwrap();
        let _ = controller.snapshot_shared();
        let _ = controller.revision();
    }
    // Live tool output/timing uses the same running hold and live-only publisher.
    let inner = controller.inner.lock().unwrap();
    for _ in 0..1000 {
        controller.publish_live(
            &inner,
            controller
                .stop_epoch
                .load(std::sync::atomic::Ordering::Acquire),
        );
    }
    assert_eq!(controller.activity(), before);
}

#[test]
fn reopened_baseline_and_noop_stop_retry_are_activity_neutral() {
    let (directory, controller) = controller();
    start(&controller);
    drop(controller);
    let reopened = Controller::new(
        SessionStore::open(directory.path().join("session.json")).unwrap(),
        None,
    )
    .unwrap();
    assert_eq!(reopened.snapshot_shared().state, RunState::Paused);
    assert_eq!(reopened.activity(), SemanticActivity::default());
    reopened.stop().unwrap();
    reopened.stop().unwrap();
    assert!(reopened.retry().is_err());
    assert!(reopened.resume().is_err());
    let inner = reopened.inner.lock().unwrap();
    reopened.publish(&inner);
    assert_eq!(reopened.activity(), SemanticActivity::default());
}

#[test]
fn accepted_unchanged_save_counts_once_but_open_cancel_and_duplicate_do_not() {
    let (_directory, controller) = controller();
    let item = Submission::new("unchanged".into(), Lane::FollowUp);
    let id = item.id.clone();
    {
        let mut inner = controller.inner.lock().unwrap();
        inner
            .store
            .transact(|session| session.submit(item))
            .unwrap();
        controller.publish(&inner);
    }
    controller.begin_edit(&id, "edit").unwrap();
    assert_eq!(controller.activity(), SemanticActivity::default());
    controller
        .resolve_edit("edit", "saved", Some("unchanged"))
        .unwrap();
    let saved = controller.activity();
    assert_eq!(saved.sequence, 1);
    controller
        .resolve_edit("edit", "saved", Some("unchanged"))
        .unwrap();
    controller.edit_status("edit").unwrap();
    controller.begin_edit(&id, "cancel").unwrap();
    controller
        .resolve_edit("cancel", "cancelled", None)
        .unwrap();
    assert_eq!(controller.activity(), saved);
}

#[test]
fn failed_save_never_emits_an_accepted_activity_event() {
    for fault in [
        crate::session::WriteFault::BeforeRename,
        crate::session::WriteFault::AfterRename,
    ] {
        let (_directory, controller) = controller();
        let item = Submission::new("original".into(), Lane::FollowUp);
        let id = item.id.clone();
        {
            let mut inner = controller.inner.lock().unwrap();
            inner
                .store
                .transact(|session| session.submit(item))
                .unwrap();
            controller.publish(&inner);
        }
        controller.begin_edit(&id, "edit").unwrap();
        controller.inner.lock().unwrap().store.fault = fault;
        assert!(
            controller
                .resolve_edit("edit", "saved", Some("updated"))
                .is_err()
        );
        assert_eq!(controller.activity(), SemanticActivity::default());
    }
}

#[test]
fn clock_rollback_and_sequence_exhaustion_do_not_regress_or_wrap() {
    let mut activity = SemanticActivity::default();
    activity.record(None);
    assert_eq!(activity.sequence, 1);
    assert_eq!(activity.timestamp_micros, None);
    activity.record(Some(300));
    activity.record(Some(200));
    activity.record(None);
    assert_eq!(activity.timestamp_micros, Some(300));
    activity.sequence = u64::MAX;
    activity.record(Some(400));
    assert_eq!(activity.sequence, u64::MAX);
    assert_eq!(activity.timestamp_micros, Some(400));
}

#[test]
fn accepted_followup_and_steering_signal_but_duplicate_and_rejected_input_do_not() {
    let directory = tempfile::tempdir().unwrap();
    let mut store = SessionStore::open(directory.path().join("session.json")).unwrap();
    store
        .transact(|session| {
            session.submit(Submission::new("active fixture".into(), Lane::FollowUp))?;
            session.start_next()?;
            Ok(())
        })
        .unwrap();
    let profile = serde_json::from_value(serde_json::json!({
        "id": "activity-fixture", "api": "openai-responses", "providerId": "litellm",
        "modelId": "local-fixture", "baseUrl": "http://127.0.0.1:1",
        "contextWindow": 32000, "maxOutputTokens": 4096
    }))
    .unwrap();
    let controller = Controller::new(
        store,
        Some((
            profile,
            crate::Credential::new("fixture-only".into()).unwrap(),
        )),
    )
    .unwrap();
    // Existing Running state prevents launch. This fixture performs no requests.
    assert_eq!(controller.activity(), SemanticActivity::default());
    for lane in [Lane::FollowUp, Lane::Steering] {
        let item = Submission::new("accepted".into(), lane);
        let before = controller.activity().sequence;
        controller.submit_identified(item.clone()).unwrap();
        assert_eq!(controller.activity().sequence, before + 1);
        let accepted = controller.activity();
        assert!(controller.submit_identified(item).is_err());
        assert_eq!(controller.activity(), accepted);
    }
    let accepted = controller.activity();
    assert!(controller.submit(" ".into(), Lane::FollowUp).is_err());
    controller
        .reorder(
            &controller
                .snapshot_shared()
                .pending
                .iter()
                .filter(|item| item.lane == Lane::FollowUp)
                .map(|item| item.id.clone())
                .collect::<Vec<_>>(),
        )
        .unwrap();
    assert_eq!(controller.activity(), accepted);
    assert!(controller.worker.lock().unwrap().is_none());
}

#[test]
fn stop_request_is_neutral_until_the_committed_pause_and_failure_changes_hold() {
    for cancelled in [true, false] {
        let (_directory, controller) = controller();
        let reply = start(&controller);
        let started = controller.activity();
        controller.stop().unwrap();
        assert_eq!(controller.activity(), started);
        let mut inner = controller.inner.lock().unwrap();
        inner
            .store
            .transact(|session| {
                session.finish(
                    &reply,
                    Err(if cancelled {
                        crate::Error::Cancelled
                    } else {
                        crate::invalid("fixture failure")
                    }),
                )
            })
            .unwrap();
        controller.publish(&inner);
        assert_eq!(controller.activity().sequence, started.sequence + 1);
        let finished = controller.activity();
        controller.publish(&inner);
        assert_eq!(controller.activity(), finished);
    }
}

#[test]
fn paused_without_queue_is_a_hold_but_idle_empty_queue_flag_is_not() {
    // Exact Swift runHold prioritizes explicit paused state even with no queue;
    // its later queuePaused fallback explicitly requires a nonempty queue.
    let mut session = Session::new();
    session.queue_paused = true;
    assert!(matches!(run_hold(&session), RunHold::None));
    session.state = RunState::Paused;
    assert!(matches!(run_hold(&session), RunHold::Paused));
    session.state = RunState::Running;
    assert!(matches!(run_hold(&session), RunHold::Active));
    session.state = RunState::Idle;
    session
        .pending
        .push(Submission::new("held".into(), Lane::FollowUp));
    assert!(matches!(run_hold(&session), RunHold::Paused));
    session.state = RunState::Error;
    assert!(matches!(run_hold(&session), RunHold::None));
}

#[tokio::test]
async fn real_worker_terminal_checkpoint_fault_emits_failure_without_accepting_state_or_commands() {
    use crate::session::WriteFault;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::time::{Duration, timeout};

    for after_rename in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session.json");
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let profile = serde_json::from_value(serde_json::json!({
            "id": "activity-terminal-fault", "api": "openai-responses", "providerId": "litellm",
            "modelId": "local-fixture", "baseUrl": format!("http://{}", listener.local_addr().unwrap()),
            "contextWindow": 32000, "maxOutputTokens": 4096
        })).unwrap();
        let controller = Controller::new(
            SessionStore::open(&path).unwrap(),
            Some((
                profile,
                crate::Credential::new("fixture-only".into()).unwrap(),
            )),
        )
        .unwrap();
        controller
            .submit("real worker".into(), Lane::FollowUp)
            .unwrap();
        let (mut socket, _) = timeout(Duration::from_secs(5), listener.accept())
            .await
            .unwrap()
            .unwrap();
        timeout(Duration::from_secs(5), async {
            let mut request = Vec::new();
            loop {
                let mut chunk = [0u8; 4096];
                let count = socket.read(&mut chunk).await.unwrap();
                assert_ne!(count, 0, "request ended before its complete body");
                request.extend_from_slice(&chunk[..count]);
                if let Some(end) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
                    let head = std::str::from_utf8(&request[..end]).unwrap();
                    let length: usize = head
                        .lines()
                        .find_map(|line| {
                            let (name, value) = line.split_once(':')?;
                            name.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse().unwrap())
                        })
                        .unwrap();
                    if request.len() >= end + 4 + length {
                        break;
                    }
                }
            }
        })
        .await
        .unwrap();
        // A held edit gives the failed post-terminal Save a real valid target.
        let queued = Submission::new("held original".into(), Lane::FollowUp);
        let queued_id = queued.id.clone();
        controller.submit_identified(queued).unwrap();
        controller.begin_edit(&queued_id, "held-edit").unwrap();
        let before_activity = controller.activity();
        let before_bytes = std::fs::read(&path).unwrap();
        let before_session = {
            let mut inner = controller.inner.lock().unwrap();
            assert_eq!(inner.store.snapshot_ref().state, RunState::Running);
            let snapshot = serde_json::to_value(inner.store.snapshot_ref()).unwrap();
            inner.store.fault = if after_rename {
                WriteFault::AfterRename
            } else {
                WriteFault::BeforeRename
            };
            snapshot
        };
        // Exercise the actual run_turn terminal transaction in tool_runtime.rs,
        // not a direct fatal assignment or synthetic publish-only state change.
        socket.write_all(concat!(
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}]}}\n\n"
        ).as_bytes()).await.unwrap();
        socket.shutdown().await.unwrap();
        timeout(Duration::from_secs(5), controller.join_workers())
            .await
            .unwrap()
            .unwrap();

        let failure_activity = controller.activity();
        assert_eq!(failure_activity.sequence, before_activity.sequence + 1);
        assert!(failure_activity.timestamp_micros >= before_activity.timestamp_micros);
        assert_eq!(controller.snapshot_shared().state, RunState::Error);
        let fatal = {
            let mut inner = controller.inner.lock().unwrap();
            assert!(!inner.worker_running);
            // The live Error is not an acknowledgment of the failed checkpoint.
            assert_eq!(
                serde_json::to_value(inner.store.snapshot_ref()).unwrap(),
                before_session
            );
            let fatal = inner
                .fatal
                .clone()
                .expect("terminal fault must stay fenced");
            if after_rename {
                assert!(matches!(
                    inner.store.require_certain(),
                    Err(crate::Error::PersistenceUncertain(_))
                ));
                let disk: Session = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
                assert_eq!(disk.state, RunState::Idle);
            } else {
                inner.store.require_certain().unwrap();
                assert_eq!(std::fs::read(&path).unwrap(), before_bytes);
            }
            inner.store.fault = WriteFault::None;
            controller.publish(&inner);
            fatal
        };
        assert!(
            controller
                .submit("must stay blocked".into(), Lane::FollowUp)
                .is_err()
        );
        assert!(
            controller
                .resolve_edit("held-edit", "saved", Some("rewrite"))
                .is_err()
        );
        assert!(controller.retry().is_err());
        assert!(controller.resume().is_err());
        assert_eq!(controller.activity(), failure_activity);
        let inner = controller.inner.lock().unwrap();
        assert_eq!(inner.fatal.as_deref(), Some(fatal.as_str()));
        assert_eq!(
            serde_json::to_value(inner.store.snapshot_ref()).unwrap(),
            before_session
        );
        if after_rename {
            assert!(matches!(
                inner.store.require_certain(),
                Err(crate::Error::PersistenceUncertain(_))
            ));
        }
    }
}
