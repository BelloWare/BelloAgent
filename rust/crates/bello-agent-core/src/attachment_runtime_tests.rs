use super::*;
use crate::{Credential, Profile, SessionStore, attachments::AttachmentRecord};
use serde_json::{Value, json};
use std::{path::Path, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};
const DEADLINE: Duration = Duration::from_secs(5);
const GIF:&[u8]=b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x01L\x00;";
fn profile(endpoint: &str, images: bool) -> Profile {
    serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":endpoint,"contextWindow":32000,"maxOutputTokens":4096,"input":if images{vec!["text","image"]}else{vec!["text"]}})).unwrap()
}
async fn listener() -> (TcpListener, String) {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", l.local_addr().unwrap());
    (l, url)
}
fn controller(path: &Path, endpoint: &str, images: bool) -> Arc<Controller> {
    let mut c = Controller::new(
        SessionStore::open(path).unwrap(),
        Some((
            profile(endpoint, images),
            Credential::new("fixture-only-not-a-secret".into()).unwrap(),
        )),
    )
    .unwrap();
    let inner = Arc::get_mut(&mut c).unwrap();
    inner.attachment_workers = crate::tools::BlockingWorkExecutor::new(1, 8);
    c.fixture_images.store(true, Ordering::Release);
    c
}
fn item(path: &Path, text: &str) -> Submission {
    std::fs::write(path, GIF).unwrap();
    let mut s = Submission::new(text.into(), Lane::FollowUp);
    s.attachments = vec![AttachmentRecord::inspect(path).unwrap()];
    s
}
async fn request(listener: &TcpListener) -> (TcpStream, Value) {
    timeout(DEADLINE, async {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut bytes = Vec::new();
        let mut buf = [0; 4096];
        loop {
            let n = socket.read(&mut buf).await.unwrap();
            assert!(n > 0);
            bytes.extend_from_slice(&buf[..n]);
            if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                let header = String::from_utf8_lossy(&bytes[..end]);
                let len = header
                    .lines()
                    .find_map(|line| {
                        let (k, v) = line.split_once(':')?;
                        k.eq_ignore_ascii_case("content-length")
                            .then(|| v.trim().parse::<usize>().unwrap())
                    })
                    .unwrap();
                if bytes.len() >= end + 4 + len {
                    return (
                        socket,
                        serde_json::from_slice(&bytes[end + 4..end + 4 + len]).unwrap(),
                    );
                }
            }
        }
    })
    .await
    .unwrap()
}
async fn complete(mut socket: TcpStream) {
    socket.write_all(b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}]}}\n\n").await.unwrap();
    socket.shutdown().await.unwrap();
}
async fn settled(c: &Arc<Controller>, state: RunState) -> Arc<Session> {
    timeout(DEADLINE, async {
        let mut updates = c.subscribe();
        loop {
            let value = updates.borrow_and_update().clone();
            if value.state == state {
                return value;
            }
            updates.changed().await.unwrap();
        }
    })
    .await
    .unwrap()
}
fn users(body: &Value) -> Vec<&Value> {
    body["input"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| row["role"] == "user")
        .collect()
}

#[tokio::test]
async fn image_only_retains_exact_bytes_retry_and_reopen_never_reread_source() {
    let d = tempfile::tempdir().unwrap();
    let path = d.path().join("session.json");
    let source = d.path().join("image.gif");
    let (l, url) = listener().await;
    let c = controller(&path, &url, true);
    let input = item(&source, "");
    let id = input.id.clone();
    c.submit_identified_with_attachments(input).await.unwrap();
    let (mut socket, body) = request(&l).await;
    assert_eq!(users(&body)[0]["content"].as_array().unwrap().len(), 1);
    assert_eq!(users(&body)[0]["content"][0]["type"], "input_image");
    std::fs::remove_file(&source).unwrap();
    socket
        .write_all(
            b"HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
        )
        .await
        .unwrap();
    drop(socket);
    let failed = settled(&c, RunState::Error).await;
    let image = failed
        .messages
        .iter()
        .find(|m| m.id == id)
        .unwrap()
        .user_content
        .as_ref()
        .unwrap()
        .clone();
    assert_eq!(failed.version, 11);
    assert_eq!(image.image_count(), 1);
    c.retry().unwrap();
    let (socket, retry) = request(&l).await;
    assert_eq!(users(&body), users(&retry));
    complete(socket).await;
    settled(&c, RunState::Idle).await;
    c.retire_and_wait().await.unwrap();
    let reopened = controller(&path, &url, false);
    reopened.submit("next".into(), Lane::FollowUp).unwrap();
    let (socket, replay) = request(&l).await;
    assert_eq!(
        users(&replay)[0]["content"][0]["text"],
        crate::user_content::USER_IMAGE_PLACEHOLDER
    );
    complete(socket).await;
    settled(&reopened, RunState::Idle).await;
    assert_eq!(
        reopened
            .snapshot()
            .messages
            .iter()
            .find(|m| m.id == id)
            .unwrap()
            .user_content
            .as_ref()
            .unwrap()
            .as_ref(),
        image.as_ref()
    );
    reopened.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn acceptance_rejects_changed_files_and_undeclared_models_without_history() {
    let d = tempfile::tempdir().unwrap();
    let (l, url) = listener().await;
    for images in [true, false] {
        let c = controller(&d.path().join(format!("{images}.json")), &url, images);
        let source = d.path().join("file.gif");
        let input = item(&source, "caption");
        if images {
            std::fs::write(&source, b"GIF89a-changed").unwrap();
        }
        assert!(c.submit_identified_with_attachments(input).await.is_err());
        assert!(c.snapshot().messages.is_empty());
        assert!(c.snapshot().pending.is_empty());
        assert!(
            timeout(Duration::from_millis(50), l.accept())
                .await
                .is_err()
        );
        c.retire_and_wait().await.unwrap();
    }
}
#[tokio::test]
async fn queued_delivery_revalidates_without_dequeue_and_empty_held_rewrite_keeps_images() {
    let d = tempfile::tempdir().unwrap();
    let (l, url) = listener().await;
    let c = controller(&d.path().join("session.json"), &url, true);
    c.submit("first".into(), Lane::FollowUp).unwrap();
    let (socket, _) = request(&l).await;
    let source = d.path().join("image.gif");
    let input = item(&source, "caption");
    let id = input.id.clone();
    c.submit_identified_with_attachments(input.clone())
        .await
        .unwrap();
    c.begin_edit(&id, "held").unwrap();
    c.resolve_edit("held", "saved", Some("")).unwrap();
    c.resolve_edit("held", "saved", Some("")).unwrap();
    assert!(c.snapshot().pending[0].text.is_empty());
    assert_eq!(c.snapshot().pending[0].attachments, input.attachments);
    std::fs::remove_file(source).unwrap();
    complete(socket).await;
    let failed = settled(&c, RunState::Error).await;
    assert_eq!(failed.pending.len(), 1);
    assert!(!failed.messages.iter().any(|m| m.id == id));
    assert!(
        timeout(Duration::from_millis(100), l.accept())
            .await
            .is_err()
    );
    c.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn idle_context_includes_image_only_without_empty_text_and_active_defers_missing_file() {
    let d = tempfile::tempdir().unwrap();
    let (l, url) = listener().await;
    let c = controller(&d.path().join("session.json"), &url, true);
    let source = d.path().join("image.gif");
    let input = item(&source, "");
    let preview = c
        .prepare_context_with_attachments("", &input.attachments)
        .await
        .unwrap();
    let body: Value = serde_json::from_str(preview.request_json()).unwrap();
    assert_eq!(users(&body)[0]["content"].as_array().unwrap().len(), 1);
    assert_eq!(users(&body)[0]["content"][0]["type"], "input_image");
    assert!(c.snapshot().messages.is_empty());
    assert!(
        timeout(Duration::from_millis(50), l.accept())
            .await
            .is_err()
    );
    c.submit("first".into(), Lane::FollowUp).unwrap();
    let (socket, _) = request(&l).await;
    std::fs::remove_file(source).unwrap();
    let preview = c
        .prepare_context_with_attachments("", &input.attachments)
        .await
        .unwrap();
    assert!(preview.metadata().draft_deferred);
    assert!(!preview.metadata().draft_included);
    complete(socket).await;
    settled(&c, RunState::Idle).await;
    c.retire_and_wait().await.unwrap();
}

async fn occupy(c: &Arc<Controller>) -> (std::sync::mpsc::Sender<()>, tokio::task::JoinHandle<()>) {
    let (release, wait) = std::sync::mpsc::channel();
    let (entered, ready) = tokio::sync::oneshot::channel();
    let workers = c.attachment_workers.clone();
    let handle = tokio::spawn(async move {
        workers
            .run(CancellationToken::new(), move |_| {
                let _ = entered.send(());
                wait.recv().unwrap();
                Ok(())
            })
            .await
            .unwrap();
    });
    ready.await.unwrap();
    (release, handle)
}
async fn queued(c: &Arc<Controller>) {
    timeout(DEADLINE, async {
        while c.attachment_workers.occupancy().waiting == 0 {
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    })
    .await
    .unwrap();
}
#[tokio::test]
async fn stop_and_configuration_changes_during_acceptance_never_accept_late_images() {
    let d = tempfile::tempdir().unwrap();
    let (l, url) = listener().await;
    for stop in [true, false] {
        let c = controller(&d.path().join(format!("{stop}.json")), &url, true);
        let input = item(&d.path().join("image.gif"), "keep draft");
        let (release, worker) = occupy(&c).await;
        let owner = c.clone();
        let pending =
            tokio::spawn(async move { owner.submit_identified_with_attachments(input).await });
        queued(&c).await;
        assert!(c.inner.try_lock().is_ok());
        if stop {
            c.stop().unwrap();
        } else {
            let mut config = profile(&url, true);
            config.thinking_level = "high".into();
            c.configure(Arc::new(Configuration {
                profile: config,
                credential: Credential::new("fixture-only-not-a-secret".into()).unwrap(),
                connection: None,
            }))
            .unwrap();
        }
        release.send(()).unwrap();
        worker.await.unwrap();
        assert!(pending.await.unwrap().is_err());
        assert!(c.snapshot().pending.is_empty());
        assert!(c.snapshot().messages.is_empty());
        assert!(
            timeout(Duration::from_millis(50), l.accept())
                .await
                .is_err()
        );
        c.retire_and_wait().await.unwrap();
    }
}
#[tokio::test]
async fn queued_hold_and_remove_during_delivery_preparation_do_not_consume_new_candidate() {
    let d = tempfile::tempdir().unwrap();
    let (l, url) = listener().await;
    for remove in [false, true] {
        let c = controller(&d.path().join(format!("{remove}.json")), &url, true);
        c.submit("first".into(), Lane::FollowUp).unwrap();
        let (socket, _) = request(&l).await;
        let input = item(&d.path().join("image.gif"), "queued");
        let id = input.id.clone();
        c.submit_identified_with_attachments(input).await.unwrap();
        let (release, worker) = occupy(&c).await;
        complete(socket).await;
        queued(&c).await;
        assert!(c.inner.try_lock().is_ok());
        if remove {
            c.remove(&id).unwrap();
        } else {
            c.begin_edit(&id, "hold").unwrap();
        }
        release.send(()).unwrap();
        worker.await.unwrap();
        timeout(DEADLINE, async {
            while c.worker_active.load(Ordering::Acquire) {
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        })
        .await
        .unwrap();
        let state = c.snapshot();
        assert!(!state.messages.iter().any(|m| m.id == id));
        assert_eq!(state.pending.len(), usize::from(!remove));
        assert!(
            timeout(Duration::from_millis(50), l.accept())
                .await
                .is_err()
        );
        c.retire_and_wait().await.unwrap();
    }
}
#[tokio::test]
async fn dropped_acceptance_cancels_waiting_work_and_retirement_rejects_stale_publish() {
    let d = tempfile::tempdir().unwrap();
    let (l, url) = listener().await;
    let c = controller(&d.path().join("session.json"), &url, true);
    let (release, worker) = occupy(&c).await;
    let input = item(&d.path().join("image.gif"), "not sent");
    let owner = c.clone();
    let pending =
        tokio::spawn(async move { owner.submit_identified_with_attachments(input).await });
    queued(&c).await;
    pending.abort();
    assert!(pending.await.is_err());
    timeout(DEADLINE, c.retire_and_wait())
        .await
        .unwrap()
        .unwrap();
    release.send(()).unwrap();
    worker.await.unwrap();
    assert!(c.snapshot().messages.is_empty());
    assert!(
        timeout(Duration::from_millis(50), l.accept())
            .await
            .is_err()
    );
    assert!(SessionStore::open(d.path().join("session.json")).is_ok());
}

#[tokio::test]
async fn committed_stopped_tool_boundary_is_returned_for_ticket_settlement_but_uncertainty_is_not()
{
    tool_boundary_timing_fixture(true).await;
}
#[tokio::test]
async fn tool_timing_actual_image_steering_projection_charges_only_real_checkpoint() {
    tool_boundary_timing_fixture(false).await;
}
async fn tool_boundary_timing_fixture(missing_image: bool) {
    use crate::{Reply, provider::ToolCall, session::WriteFault, tool_history::ToolOutcome};
    for fault in [
        WriteFault::None,
        WriteFault::BeforeRename,
        WriteFault::AfterRename,
    ] {
        let d = tempfile::tempdir().unwrap();
        let (_l, url) = listener().await;
        let c = controller(&d.path().join("session.json"), &url, true);
        let source = d.path().join("image.gif");
        let mut queued_input = item(&source, "");
        queued_input.lane = Lane::Steering;
        let reply_id = {
            let mut inner = c.inner.lock().unwrap();
            inner
                .store
                .transact(|s| {
                    s.submit(Submission::new("active".into(), Lane::FollowUp))?;
                    s.start_next()?;
                    let reply = s.active_reply.clone().unwrap();
                    s.begin_tools(
                        &reply,
                        &Reply {
                            text: String::new(),
                            reasoning: String::new(),
                            calls: vec![ToolCall {
                                id: "fixture-call".into(),
                                name: "mcp".into(),
                                arguments: json!({"action":"invoke"}),
                            }],
                            usage: Value::Null,
                            status: "completed".into(),
                            provider_items: vec![],
                        },
                        &profile(&url, true),
                    )?;
                    s.submit(queued_input.clone())?;
                    Ok(reply)
                })
                .unwrap()
        };
        if missing_image {
            std::fs::remove_file(&source).unwrap();
        }
        c.inner.lock().unwrap().store.fault = fault;
        let settled = c
            .settle_image_tools(
                &reply_id,
                super::super::tool_runtime::CompletedToolBatch {
                    timing: crate::tool_timing::BatchTiming {
                        wall_us: Some(crate::tool_timing::DurationUs::new(20_000)),
                    },
                    rows: vec![super::super::tool_runtime::ToolResultRow {
                        duration_us: None,
                        text: "completed result".into(),
                        content: None,
                        outcome: ToolOutcome::Completed,
                    }],
                },
                CancellationToken::new(),
            )
            .await;
        if matches!(fault, WriteFault::None) {
            let (_, state) =
                settled.expect("durably committed results must allow ticket settlement");
            assert_eq!(
                state.state,
                if missing_image {
                    RunState::Paused
                } else {
                    RunState::Running
                }
            );
            assert_eq!(state.pending.len(), usize::from(missing_image));
            assert_eq!(
                state.tool_timing.unwrap().total_us,
                Some(crate::tool_timing::DurationUs::new(20_000))
            );
            assert!(
                state
                    .messages
                    .iter()
                    .any(|row| row.role == "toolResult" && row.text == "completed result")
            );
        } else {
            assert!(
                settled.is_none(),
                "failed or uncertain checkpoint must not acknowledge ticket"
            );
            assert!(c.inner.lock().unwrap().fatal.is_some());
            assert_eq!(
                c.snapshot().tool_timing.unwrap().total_us,
                Some(crate::tool_timing::DurationUs::ZERO),
                "failed checkpoint must not publish the disposable projection's charge"
            );
        }
        c.retire_and_wait().await.unwrap();
    }
}
#[tokio::test]
async fn retirement_waits_for_the_actual_image_closure_lease() {
    let d = tempfile::tempdir().unwrap();
    let (_l, url) = listener().await;
    let path = d.path().join("session.json");
    let c = controller(&path, &url, true);
    let lease = c
        .attachment_jobs
        .register(CancellationToken::new())
        .unwrap();
    let mut retire = Box::pin(c.retire_and_wait());
    assert!(futures_util::poll!(&mut retire).is_pending());
    assert!(SessionStore::open(&path).is_err());
    drop(lease);
    timeout(DEADLINE, retire).await.unwrap().unwrap();
    assert!(SessionStore::open(&path).is_ok());
}

#[test]
fn certain_submission_receipt_compares_metadata_and_never_calls_absence_on_conflict() {
    let d = tempfile::tempdir().unwrap();
    let c = controller(&d.path().join("session.json"), "http://127.0.0.1:9", true);
    let input = item(&d.path().join("image.gif"), "");
    let mut receipt = crate::workspace::SubmissionIntent {
        skills: Vec::new(),
        id: input.id.clone(),
        chat_id: c.snapshot().id,
        text: input.text.clone(),
        lane: input.lane.clone(),
        draft_revision: 1,
        attachments: input.attachments.clone(),
    };
    assert!(!c.submission_intent_status(&receipt).unwrap());
    c.inner
        .lock()
        .unwrap()
        .store
        .transact(|s| s.submit(input))
        .unwrap();
    assert!(c.submission_intent_status(&receipt).unwrap());
    receipt.lane = Lane::Steering;
    assert!(c.submission_intent_status(&receipt).unwrap());
    receipt.attachments[0].sha256 = "b".repeat(64);
    assert!(c.submission_intent_status(&receipt).is_err());
    c.inner.lock().unwrap().store.fault = crate::session::WriteFault::AfterRename;
    assert!(
        c.inner
            .lock()
            .unwrap()
            .store
            .transact(|s| {
                s.title = "uncertain".into();
                Ok(())
            })
            .is_err()
    );
    assert!(c.submission_intent_status(&receipt).is_err());
}

#[tokio::test]
async fn dropped_awaiter_during_live_image_processing_keeps_writer_until_real_worker_exit() {
    let d = tempfile::tempdir().unwrap();
    let (l, url) = listener().await;
    let path = d.path().join("session.json");
    let c = controller(&path, &url, true);
    let input = item(&d.path().join("image.gif"), "keep draft");
    let (entered, ready) = tokio::sync::oneshot::channel();
    let entered = Mutex::new(Some(entered));
    let (release, wait) = std::sync::mpsc::channel();
    let wait = Mutex::new(wait);
    *c.attachment_processor_barrier.lock().unwrap() = Some(Arc::new(move || {
        if let Some(entered) = entered.lock().unwrap().take() {
            let _ = entered.send(());
            wait.lock().unwrap().recv().unwrap();
        }
    }));
    let owner = c.clone();
    let pending =
        tokio::spawn(async move { owner.submit_identified_with_attachments(input).await });
    timeout(DEADLINE, ready).await.unwrap().unwrap();
    assert!(c.inner.try_lock().is_ok());
    pending.abort();
    assert!(pending.await.is_err());
    let mut retire = Box::pin(c.retire_and_wait());
    assert!(futures_util::poll!(&mut retire).is_pending());
    assert!(SessionStore::open(&path).is_err());
    assert_eq!(c.attachment_workers.occupancy().active, 1);
    release.send(()).unwrap();
    timeout(DEADLINE, retire).await.unwrap().unwrap();
    assert!(SessionStore::open(&path).is_ok());
    assert!(c.snapshot().messages.is_empty());
    assert!(
        timeout(Duration::from_millis(50), l.accept())
            .await
            .is_err()
    );
}
#[tokio::test]
async fn retirement_fence_wins_when_admission_is_waiting_to_register_image_work() {
    let d = tempfile::tempdir().unwrap();
    let (_l, url) = listener().await;
    let path = d.path().join("session.json");
    let c = controller(&path, &url, true);
    let input = item(&d.path().join("image.gif"), "not accepted");
    let actor = c.inner.lock().unwrap();
    let owner = c.clone();
    let admission = std::thread::spawn(move || {
        super::super::shared_runtime()
            .unwrap()
            .block_on(owner.submit_identified_with_attachments(input))
    });
    let owner = c.clone();
    let retiring = std::thread::spawn(move || owner.retire());
    let end = std::time::Instant::now() + DEADLINE;
    while !c.is_retired() {
        assert!(std::time::Instant::now() < end);
        std::thread::yield_now();
    }
    drop(actor);
    retiring.join().unwrap().unwrap();
    assert!(admission.join().unwrap().is_err());
    assert!(c.attachment_jobs.pending.lock().unwrap().is_empty());
    c.retire_and_wait().await.unwrap();
    assert!(SessionStore::open(&path).is_ok());
    assert!(c.snapshot().messages.is_empty());
}
