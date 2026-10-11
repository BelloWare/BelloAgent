use super::*;
use crate::{Message, compaction::Phase, session::WriteFault};
use serde_json::{Value, json};
use std::{path::Path, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};
const DEADLINE: Duration = Duration::from_secs(8);
fn profile(endpoint: String) -> Profile {
    serde_json::from_value(json!({"id":"compaction-fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":endpoint,"contextWindow":65536,"maxOutputTokens":4096})).unwrap()
}
fn row(id: &str, role: &str, text: String) -> Message {
    Message {
        task_root_id: None,
        user_content: None,
        id: id.into(),
        role: role.into(),
        text,
        reasoning: String::new(),
        replay_eligible: true,
        state: "complete".into(),
        usage: Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
    }
}
fn controller(path: &Path, endpoint: String) -> Arc<Controller> {
    let mut store = SessionStore::open(path).unwrap();
    store
        .transact(|session| {
            session.messages = vec![
                row("u1", "user", "Objective constraints. ".repeat(1800)),
                row(
                    "a1",
                    "assistant",
                    "Verified progress evidence. ".repeat(1800),
                ),
            ];
            Ok(())
        })
        .unwrap();
    Controller::new_with_options(
        store,
        Some((
            profile(endpoint),
            Credential::new("synthetic-compaction-key".into()).unwrap(),
        )),
        RuntimeOptions {
            instructions: "Frozen fixture instructions".into(),
            tools: None,
        },
    )
    .unwrap()
}
async fn request(socket: &mut TcpStream) -> Value {
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let count = socket.read(&mut chunk).await.unwrap();
        assert!(count > 0);
        bytes.extend_from_slice(&chunk[..count]);
        if let Some(end) = bytes.windows(4).position(|value| value == b"\r\n\r\n") {
            let header = String::from_utf8_lossy(&bytes[..end]);
            let size: usize = header
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .map(str::trim)
                        .map(str::to_owned)
                })
                .unwrap()
                .parse()
                .unwrap();
            if bytes.len() >= end + 4 + size {
                return serde_json::from_slice(&bytes[end + 4..end + 4 + size]).unwrap();
            }
        }
    }
}
async fn respond(socket: &mut TcpStream, status: &str, text: &str) {
    let value=json!({"id":"response_fixture","status":status,"incomplete_details":if status=="incomplete"{json!({"reason":"max_output_tokens"})}else{Value::Null},"output":[{"id":"msg_fixture","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":text}]}],"usage":{"input_tokens":100,"output_tokens":10}}).to_string();
    socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{value}",value.len()).as_bytes()).await.unwrap();
}
async fn wait(controller: &Controller, predicate: impl Fn(&Session) -> bool) -> Session {
    timeout(DEADLINE, async {
        let mut updates = controller.subscribe();
        loop {
            let snapshot = updates.borrow_and_update().clone();
            if predicate(&snapshot) {
                return (*snapshot).clone();
            }
            updates.changed().await.unwrap();
        }
    })
    .await
    .unwrap()
}
async fn settled(controller: &Controller) -> Session {
    let snapshot = wait(controller, |session| {
        session
            .compaction
            .as_ref()
            .is_some_and(|operation| !operation.is_running())
    })
    .await;
    timeout(DEADLINE, async {
        while controller.worker_active.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    // worker_finished clears its atomic activity flag while still holding the
    // actor through final publication. Cross that actual settlement barrier
    // before testing a deliberately nonblocking Context preview.
    drop(controller.inner.lock().unwrap());
    snapshot
}

#[tokio::test]
async fn manual_checkpoint_reopens_and_next_request_inspector_share_exact_projection() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let actor = controller(&path, endpoint.clone());
    {
        let mut inner = actor.inner.lock().unwrap();
        inner
            .store
            .transact(|session| {
                session.tool_timing = Some(crate::tool_timing::SessionToolTiming {
                    total_us: Some(crate::tool_timing::DurationUs::new(75_000)),
                });
                Ok(())
            })
            .unwrap();
        actor.publish(&inner);
    }
    let original = actor.snapshot().messages;
    let (sent, mut requests) = tokio::sync::mpsc::channel(2);
    let server = tokio::spawn(async move {
        for text in [
            "Objective retained. Evidence verified. Next step remains.",
            "Continuation complete",
        ] {
            let (mut socket, _) = listener.accept().await.unwrap();
            sent.send(request(&mut socket).await).await.unwrap();
            respond(&mut socket, "completed", text).await;
        }
    });
    actor.compact(None).unwrap();
    let summary_request = timeout(DEADLINE, requests.recv()).await.unwrap().unwrap();
    assert_eq!(summary_request["tool_choice"], "none");
    let snapshot = settled(&actor).await;
    assert_eq!(snapshot.version, 9);
    assert_eq!(
        snapshot.tool_timing.unwrap().total_us,
        Some(crate::tool_timing::DurationUs::new(75_000))
    );
    assert_eq!(
        snapshot.compaction.as_ref().unwrap().phase,
        Phase::Completed
    );
    assert_eq!(snapshot.messages.len(), 4);
    assert_eq!(
        serde_json::to_value(&snapshot.messages[..2]).unwrap(),
        serde_json::to_value(&original).unwrap()
    );
    let preview = actor.prepare_context("Continue from checkpoint").unwrap();
    let prepared: Value = serde_json::from_str(preview.request_json()).unwrap();
    assert_eq!(
        preview.metadata().context_messages,
        crate::compaction::active_context(&snapshot.messages)
            .unwrap()
            .len()
    );
    assert!(prepared.to_string().contains("<summary>"));
    assert!(
        !prepared
            .to_string()
            .contains("Objective constraints. Objective")
    );
    actor.retire_and_wait().await.unwrap();
    drop(actor);
    let reopened = Controller::new_with_options(
        SessionStore::open(&path).unwrap(),
        Some((
            profile(endpoint),
            Credential::new("synthetic-compaction-key".into()).unwrap(),
        )),
        RuntimeOptions {
            instructions: "Frozen fixture instructions".into(),
            tools: None,
        },
    )
    .unwrap();
    assert_eq!(
        prepared,
        serde_json::from_str::<Value>(
            reopened
                .prepare_context("Continue from checkpoint")
                .unwrap()
                .request_json()
        )
        .unwrap()
    );
    reopened
        .submit("Continue from checkpoint".into(), Lane::FollowUp)
        .unwrap();
    let dispatched = timeout(DEADLINE, requests.recv()).await.unwrap().unwrap();
    assert_eq!(dispatched, prepared);
    wait(&reopened, |session| {
        session
            .messages
            .last()
            .is_some_and(|row| row.text == "Continuation complete" && row.replay_eligible)
    })
    .await;
    reopened.retire_and_wait().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn incomplete_summary_keeps_partial_text_and_original_history_queue_and_hold() {
    let dir = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let actor = controller(
        &dir.path().join("s.json"),
        format!("http://{}", listener.local_addr().unwrap()),
    );
    let pending = Submission::new("Held text remains".into(), Lane::FollowUp);
    let pending_id = pending.id.clone();
    {
        let mut inner = actor.inner.lock().unwrap();
        inner
            .store
            .transact(|session| {
                session.submit(pending)?;
                session.begin_edit(&pending_id, "held-edit")?;
                Ok(())
            })
            .unwrap();
        actor.publish(&inner);
    }
    let before = actor.snapshot();
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        request(&mut socket).await;
        respond(&mut socket, "incomplete", "Incomplete checkpoint preserved").await;
    });
    actor.compact(None).unwrap();
    let snapshot = settled(&actor).await;
    assert_eq!(snapshot.compaction.as_ref().unwrap().phase, Phase::Failed);
    assert!(
        snapshot
            .messages
            .last()
            .unwrap()
            .text
            .contains("Incomplete checkpoint")
    );
    assert!(!snapshot.messages.last().unwrap().replay_eligible);
    assert_eq!(snapshot.pending[0].text, before.pending[0].text);
    assert_eq!(snapshot.edit, before.edit);
    assert_eq!(
        crate::compaction::active_context(&snapshot.messages)
            .unwrap()
            .len(),
        2
    );
    actor.retire_and_wait().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn stop_during_summary_retains_stream_and_held_queue_without_adoption() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("s.json");
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let actor = controller(&path, format!("http://{}", listener.local_addr().unwrap()));
    let (ready, started) = tokio::sync::oneshot::channel();
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        request(&mut socket).await;
        let chunk = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial checkpoint evidence\"}\n\n";
        socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n{chunk}\r\n",chunk.len()).as_bytes()).await.unwrap();
        ready.send(()).unwrap();
        let mut byte = [0];
        let _ = socket.read(&mut byte).await;
    });
    actor.compact(None).unwrap();
    started.await.unwrap();
    wait(&actor, |session| {
        session
            .messages
            .last()
            .is_some_and(|row| row.text.contains("Partial checkpoint"))
    })
    .await;
    // A watch notification precedes stream_delta releasing the actor mutex.
    // The server sends no more chunks: acquiring this lock is an explicit
    // publication-settlement barrier before checking the semantic refusal.
    {
        let inner = actor.inner.lock().unwrap();
        assert_eq!(
            inner
                .store
                .snapshot_ref()
                .compaction
                .as_ref()
                .unwrap()
                .phase,
            Phase::Summarizing
        );
        let busy = actor.prepare_context("").unwrap_err().to_string();
        assert_eq!(
            busy,
            "The conversation is changing. Refresh the context preview."
        );
        eprintln!("Context preview while actor lock is held: {busy}");
    }
    let error = actor.prepare_context("").unwrap_err().to_string();
    assert!(
        error.contains("Compaction"),
        "Unexpected preview refusal: {error}"
    );
    actor
        .submit("Never drop queued input".into(), Lane::FollowUp)
        .unwrap();
    actor.stop().unwrap();
    actor.shutdown().await.unwrap();
    let snapshot = actor.snapshot();
    assert_eq!(
        snapshot.compaction.as_ref().unwrap().phase,
        Phase::Cancelled
    );
    assert_eq!(snapshot.pending.len(), 1);
    assert!(snapshot.queue_paused);
    assert!(
        snapshot
            .messages
            .last()
            .unwrap()
            .text
            .contains("Partial checkpoint")
    );
    actor.retire_and_wait().await.unwrap();
    drop(actor);
    let reopened = SessionStore::open(&path).unwrap();
    assert_eq!(reopened.snapshot().pending.len(), 1);
    assert_eq!(
        crate::compaction::active_context(&reopened.snapshot().messages)
            .unwrap()
            .len(),
        2
    );
    server.await.unwrap();
}

#[tokio::test]
async fn a_later_stop_while_previous_worker_winds_down_cancels_compaction_before_send() {
    let dir = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let actor = controller(
        &dir.path().join("s.json"),
        format!("http://{}", listener.local_addr().unwrap()),
    );
    let before = actor.snapshot();
    let (release, waiting) = tokio::sync::oneshot::channel();
    {
        let mut inner = actor.inner.lock().unwrap();
        inner.worker_running = true;
        actor.worker_active.store(true, Ordering::Release);
        *actor.worker.lock().unwrap() = Some(actor.runtime.spawn(async move {
            let _ = waiting.await;
        }));
    }
    actor.compact(None).unwrap();
    assert!(actor.compact(None).is_err());
    actor.stop().unwrap();
    release.send(()).unwrap();
    actor.shutdown().await.unwrap();
    let after = actor.snapshot();
    assert!(after.compaction.is_none());
    assert!(after.revision > before.revision);
    assert!(after.queue_paused);
    assert_eq!(after.state, RunState::Paused);
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    actor.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn stopped_active_turn_is_preserved_and_followup_runs_after_compaction() {
    let dir = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let actor = controller(
        &dir.path().join("s.json"),
        format!("http://{}", listener.local_addr().unwrap()),
    );
    let (sent, mut requests) = tokio::sync::mpsc::channel(3);
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        sent.send(request(&mut socket).await).await.unwrap();
        let chunk =
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial old answer\"}\n\n";
        socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n{chunk}\r\n",chunk.len()).as_bytes()).await.unwrap();
        let mut byte = [0];
        let _ = socket.read(&mut byte).await;
        for text in ["Checkpoint after interrupted work", "Queued response"] {
            let (mut socket, _) = listener.accept().await.unwrap();
            sent.send(request(&mut socket).await).await.unwrap();
            respond(&mut socket, "completed", text).await;
        }
    });
    actor
        .submit("Continue old task".into(), Lane::FollowUp)
        .unwrap();
    requests.recv().await.unwrap();
    wait(&actor, |session| {
        session
            .messages
            .last()
            .is_some_and(|row| row.text == "Partial old answer")
    })
    .await;
    actor
        .submit("Follow up after checkpoint".into(), Lane::FollowUp)
        .unwrap();
    actor.compact(None).unwrap();
    let summary = timeout(DEADLINE, requests.recv()).await.unwrap().unwrap();
    assert_eq!(summary["tool_choice"], "none");
    assert!(!summary.to_string().contains("Partial old answer"));
    let continuation = timeout(DEADLINE, requests.recv()).await.unwrap().unwrap();
    assert!(
        continuation
            .to_string()
            .contains("Checkpoint after interrupted work")
    );
    assert!(
        continuation
            .to_string()
            .contains("Follow up after checkpoint")
    );
    let snapshot = wait(&actor, |session| {
        session
            .messages
            .last()
            .is_some_and(|row| row.text == "Queued response" && row.replay_eligible)
    })
    .await;
    assert!(
        snapshot
            .messages
            .iter()
            .any(|row| row.text == "Partial old answer" && !row.replay_eligible)
    );
    assert!(snapshot.pending.is_empty());
    actor.retire_and_wait().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn adoption_write_fault_never_acknowledges_an_unconfirmed_checkpoint() {
    for fault in [WriteFault::BeforeRename, WriteFault::AfterRename] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.json");
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let actor = controller(&path, format!("http://{}", listener.local_addr().unwrap()));
        let (ready, started) = tokio::sync::oneshot::channel();
        let (release, proceed) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            request(&mut socket).await;
            ready.send(()).unwrap();
            proceed.await.unwrap();
            respond(&mut socket, "completed", "Validated checkpoint candidate").await;
        });
        actor.compact(None).unwrap();
        started.await.unwrap();
        actor.inner.lock().unwrap().store.fault = fault;
        release.send(()).unwrap();
        wait(&actor, |session| session.state == RunState::Error).await;
        assert_ne!(
            actor.snapshot().compaction.as_ref().unwrap().phase,
            Phase::Completed
        );
        assert!(actor.prepare_context("").is_err());
        assert!(
            actor
                .submit("No uncertain mutation".into(), Lane::FollowUp)
                .is_err()
        );
        actor.inner.lock().unwrap().store.fault = WriteFault::None;
        actor.retire_and_wait().await.unwrap();
        drop(actor);
        let recovered = SessionStore::open(&path).unwrap().snapshot();
        assert!(
            recovered
                .messages
                .iter()
                .filter(|row| row.compaction.is_some())
                .count()
                <= 1
        );
        assert!(recovered.messages.iter().any(|row| row.id == "u1"));
        server.await.unwrap();
    }
}

#[tokio::test]
async fn changed_configuration_rejects_candidate_and_retains_pending_input() {
    let dir = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let actor = controller(&dir.path().join("s.json"), endpoint.clone());
    let (ready, started) = tokio::sync::oneshot::channel();
    let (release, proceed) = tokio::sync::oneshot::channel();
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        request(&mut socket).await;
        ready.send(()).unwrap();
        proceed.await.unwrap();
        respond(&mut socket, "completed", "A candidate for stale settings").await;
    });
    actor.compact(None).unwrap();
    started.await.unwrap();
    actor
        .submit("Retain after stale settings".into(), Lane::FollowUp)
        .unwrap();
    let mut updated = profile(endpoint);
    updated.max_output_tokens = 2048;
    let configuration = Arc::new(Configuration {
        profile: updated,
        credential: Credential::new("synthetic-compaction-key".into()).unwrap(),
        connection: None,
    });
    assert!(!actor.configure(configuration).unwrap());
    release.send(()).unwrap();
    let snapshot = settled(&actor).await;
    assert_eq!(snapshot.compaction.as_ref().unwrap().phase, Phase::Failed);
    assert!(snapshot.messages.iter().all(|row| row.compaction.is_none()));
    assert_eq!(snapshot.pending.len(), 1);
    assert!(snapshot.queue_paused);
    assert_eq!(actor.profile().unwrap().max_output_tokens, 2048);
    actor.retire_and_wait().await.unwrap();
    server.await.unwrap();
}

#[test]
fn interrupted_compaction_reopens_with_original_context_and_durable_partial_progress() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("s.json");
    let mut store = SessionStore::open(&path).unwrap();
    let p = profile("http://127.0.0.1:9".into());
    let id = store
        .transact(|session| {
            session.messages = vec![
                row("u1", "user", "Original user text".into()),
                row("a1", "assistant", "Original response".into()),
            ];
            session.submit(Submission::new("Queued input".into(), Lane::FollowUp))?;
            session.begin_compaction("operation", &p, false)
        })
        .unwrap();
    store
        .append_delta(&id, crate::Delta::Text("Durable partial summary".into()))
        .unwrap();
    drop(store);
    let reopened = SessionStore::open(&path).unwrap();
    let snapshot = reopened.snapshot();
    assert_eq!(snapshot.state, RunState::Paused);
    assert!(snapshot.queue_paused);
    assert_eq!(snapshot.pending.len(), 1);
    assert!(
        snapshot
            .messages
            .last()
            .unwrap()
            .text
            .contains("Durable partial summary")
    );
    assert!(snapshot.messages.iter().all(|row| row.compaction.is_none()));
    assert_eq!(
        crate::compaction::active_context(&snapshot.messages)
            .unwrap()
            .len(),
        2
    );
    assert!(snapshot.retry.is_none());
}

#[tokio::test]
async fn nothing_useful_to_compact_is_a_durable_failure_without_sending() {
    let dir = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let actor = controller(
        &dir.path().join("s.json"),
        format!("http://{}", listener.local_addr().unwrap()),
    );
    {
        let mut inner = actor.inner.lock().unwrap();
        inner
            .store
            .transact(|session| {
                session.messages = vec![row("u1", "user", "Unanswered input".into())];
                Ok(())
            })
            .unwrap();
        actor.publish(&inner);
    }
    actor.compact(None).unwrap();
    let snapshot = settled(&actor).await;
    assert_eq!(snapshot.compaction.as_ref().unwrap().phase, Phase::Failed);
    assert_eq!(snapshot.compaction.as_ref().unwrap().http_attempts, 0);
    assert_eq!(
        crate::compaction::active_context(&snapshot.messages).unwrap()[0].text,
        "Unanswered input"
    );
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    actor.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn pending_compaction_fences_retry_and_one_resume_after_stop_delivers_queue() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("s.json");
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let actor = controller(&path, format!("http://{}", listener.local_addr().unwrap()));
    let (release, waiting) = tokio::sync::oneshot::channel();
    {
        let mut inner = actor.inner.lock().unwrap();
        inner
            .store
            .transact(|session| {
                session.submit(Submission::new("Interrupted task".into(), Lane::FollowUp))?;
                session.start_next()?;
                let reply = session.active_reply.clone().unwrap();
                session.finish(&reply, Err(crate::Error::Cancelled))?;
                session.submit(Submission::new(
                    "Deliver once after Resume".into(),
                    Lane::FollowUp,
                ))?;
                Ok(())
            })
            .unwrap();
        inner.worker_running = true;
        actor.worker_active.store(true, Ordering::Release);
        *actor.worker.lock().unwrap() = Some(actor.runtime.spawn(async move {
            let _ = waiting.await;
        }));
        actor.publish(&inner);
    }
    actor.compact(None).unwrap();
    let mut accepted = Submission::new("Appended while compaction waits".into(), Lane::FollowUp);
    // The chat's chosen model is carried; effort left to the connection.
    accepted.model = Some(" chosen-at-admission ".into());
    let appended_id = accepted.id.clone();
    actor.submit_identified(accepted).unwrap();
    let admitted = actor.snapshot().pending.last().unwrap().clone();
    assert_eq!(admitted.id, appended_id);
    assert_eq!(admitted.text, "Appended while compaction waits");
    assert_eq!(admitted.model.as_deref(), Some("chosen-at-admission"));
    assert_eq!(admitted.effort.as_deref(), Some("default"));
    assert!(actor.snapshot().active_reply.is_none());
    let before = actor.snapshot();
    assert!(
        actor
            .retry()
            .unwrap_err()
            .to_string()
            .contains("Compaction is waiting")
    );
    assert!(actor.resume().is_err());
    assert_eq!(actor.snapshot().revision, before.revision);
    actor.stop().unwrap();
    release.send(()).unwrap();
    wait(&actor, |session| {
        session
            .error
            .as_ref()
            .is_some_and(|error| error.contains("cancelled before"))
    })
    .await;
    timeout(DEADLINE, async {
        while actor.worker_active.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert!(!actor.stop_requested.load(Ordering::Acquire));
    assert_eq!(actor.snapshot().state, RunState::Paused);
    assert!(actor.snapshot().active.is_none());
    assert!(actor.snapshot().active_reply.is_none());
    let pending = actor.snapshot().pending;
    assert_eq!(pending.len(), 2);
    assert_eq!(
        serde_json::to_value(&pending[1]).unwrap(),
        serde_json::to_value(&admitted).unwrap()
    );
    let server = tokio::spawn(async move {
        for (expected, text) in [
            ("Deliver once after Resume", "Resumed first"),
            ("Appended while compaction waits", "Resumed exactly once"),
        ] {
            let (mut socket, _) = listener.accept().await.unwrap();
            let body = request(&mut socket).await;
            assert!(body.get("tool_choice").is_none());
            assert!(
                body["input"]
                    .as_array()
                    .unwrap()
                    .last()
                    .unwrap()
                    .to_string()
                    .contains(expected)
            );
            respond(&mut socket, "completed", text).await;
        }
        assert!(
            timeout(Duration::from_millis(50), listener.accept())
                .await
                .is_err()
        );
    });
    actor.resume().unwrap();
    wait(&actor, |session| {
        session
            .messages
            .last()
            .is_some_and(|row| row.text == "Resumed exactly once" && row.replay_eligible)
    })
    .await;
    actor.retire_and_wait().await.unwrap();
    drop(actor);
    assert!(SessionStore::open(&path).is_ok());
    server.await.unwrap();
}

#[test]
fn failed_attempt_receipts_remain_durable_across_later_compaction_and_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("s.json");
    let mut store = SessionStore::open(&path).unwrap();
    let p = profile("http://127.0.0.1:9".into());
    store
        .transact(|session| {
            session
                .messages
                .push(row("u", "user", "Retained task".into()));
            session.begin_compaction("first", &p, false)?;
            session.fail_compaction("first", invalid("Specific first failure"), None)
        })
        .unwrap();
    store
        .transact(|session| {
            session.begin_compaction("second", &p, false)?;
            session.fail_compaction("second", crate::Error::Cancelled, None)
        })
        .unwrap();
    let snapshot = store.snapshot();
    assert_eq!(snapshot.compaction_history.len(), 1);
    assert!(
        snapshot.compaction_history[0]
            .error
            .as_ref()
            .unwrap()
            .contains("Specific first failure")
    );
    drop(store);
    let bytes = std::fs::read(&path).unwrap();
    let reopened = SessionStore::open(&path).unwrap();
    assert_eq!(reopened.snapshot().compaction_history[0].id, "first");
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    drop(reopened);
    let mut legacy: Value = serde_json::from_slice(&bytes).unwrap();
    legacy["version"] = json!(4);
    std::fs::write(&path, serde_json::to_vec(&legacy).unwrap()).unwrap();
    let malformed = std::fs::read(&path).unwrap();
    assert!(SessionStore::open(&path).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), malformed);
}

#[test]
fn malformed_historical_receipts_are_rejected_without_rewriting_evidence() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("s.json");
    let mut store = SessionStore::open(&path).unwrap();
    let p = profile("http://127.0.0.1:9".into());
    store
        .transact(|session| {
            session.begin_compaction("first", &p, false)?;
            session.fail_compaction("first", invalid("Retain this failure"), None)?;
            session.begin_compaction("second", &p, false)?;
            session.fail_compaction("second", crate::Error::Cancelled, None)
        })
        .unwrap();
    drop(store);
    let original: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    for variant in 0..3 {
        let mut damaged = original.clone();
        if variant == 2 {
            damaged["compaction_history"][0]["phase"] = json!("planning");
        } else {
            let mut duplicate = damaged["compaction_history"][0].clone();
            if variant == 1 {
                duplicate["id"] = json!("other-operation");
            }
            damaged["compaction_history"]
                .as_array_mut()
                .unwrap()
                .push(duplicate);
        }
        let bytes = serde_json::to_vec(&damaged).unwrap();
        std::fs::write(&path, &bytes).unwrap();
        assert!(SessionStore::open(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }
}
