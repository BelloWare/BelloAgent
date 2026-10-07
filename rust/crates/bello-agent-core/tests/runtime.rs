use bello_agent_core::{
    Controller, Credential, Error, Lane, Profile, RunState, Session, SessionStore, Submission,
};
use serde_json::json;
use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::{Arc, mpsc},
    thread,
    time::Duration,
};
fn await_state(controller: &Controller, predicate: impl Fn(&Session) -> bool) {
    let mut updates = controller.subscribe();
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(async {
            tokio::time::timeout(Duration::from_secs(5), async {
                loop {
                    if predicate(&updates.borrow_and_update()) {
                        break;
                    }
                    updates.changed().await.expect("controller closed");
                }
            })
            .await
            .expect("expected session transition timed out");
        });
}
fn request(socket: &mut std::net::TcpStream) -> Vec<u8> {
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut raw = Vec::new();
    let mut buf = [0; 4096];
    loop {
        let n = socket.read(&mut buf).unwrap();
        if n == 0 {
            break;
        }
        raw.extend_from_slice(&buf[..n]);
        if let Some(end) = raw.windows(4).position(|v| v == b"\r\n\r\n") {
            let header = String::from_utf8_lossy(&raw[..end]).to_lowercase();
            let length = header
                .lines()
                .find_map(|l| l.strip_prefix("content-length: "))
                .unwrap_or("0")
                .parse::<usize>()
                .unwrap();
            if raw.len() >= end + 4 + length {
                break;
            }
        }
    }
    raw
}
#[test]
fn stop_retry_held_queue_and_resume_are_serialized() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (events, requests) = mpsc::channel();
    let (release, wait_release) = mpsc::channel();
    let server = thread::spawn(move || {
        for n in 0..3 {
            let (mut socket, _) = listener.accept().unwrap();
            let raw = request(&mut socket);
            events.send(raw).unwrap();
            if n == 0 {
                socket.write_all(b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n").unwrap();
                socket.flush().unwrap();
                wait_release.recv_timeout(Duration::from_secs(5)).unwrap();
            } else {
                let body=json!({"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":format!("reply {n}")}]}]}).to_string();
                let response = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(response.as_bytes()).unwrap();
            }
        }
    });
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let profile:Profile=serde_json::from_value(json!({"id":"test","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":url,"contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let controller = Controller::new(
        SessionStore::open(&path).unwrap(),
        Some((profile, Credential::new("fake-only".into()).unwrap())),
    )
    .unwrap();
    controller.submit("first".into(), Lane::FollowUp).unwrap();
    requests.recv_timeout(Duration::from_secs(5)).unwrap();
    await_state(&controller, |s| {
        s.messages.last().is_some_and(|m| m.text == "partial")
    });
    controller.submit("waiting".into(), Lane::FollowUp).unwrap();
    let id = controller.snapshot().pending[0].id.clone();
    controller.begin_edit(&id, "hold").unwrap();
    controller.stop().unwrap();
    await_state(&controller, |s| s.state == RunState::Paused);
    assert!(
        !controller
            .snapshot()
            .messages
            .last()
            .unwrap()
            .replay_eligible
    );
    assert!(controller.retry().is_err());
    controller
        .resolve_edit("hold", "saved", Some("edited waiting"))
        .unwrap();
    assert_eq!(controller.snapshot().state, RunState::Paused);
    assert!(controller.snapshot().queue_paused);
    release.send(()).unwrap();
    controller.retry().unwrap();
    requests.recv_timeout(Duration::from_secs(5)).unwrap();
    requests.recv_timeout(Duration::from_secs(5)).unwrap();
    await_state(&controller, |s| {
        s.state == RunState::Idle && s.messages.last().is_some_and(|m| m.text == "reply 2")
    });
    let snapshot = controller.snapshot();
    assert_eq!(
        snapshot
            .messages
            .iter()
            .filter(|m| m.role == "user")
            .count(),
        2
    );
    assert!(snapshot.messages.iter().any(|m| m.text == "edited waiting"));
    assert_eq!(
        snapshot
            .messages
            .iter()
            .filter(|m| m.state == "interrupted")
            .count(),
        1
    );
    server.join().unwrap();
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(controller.shutdown())
        .unwrap();
    drop(controller);
    let reopened = SessionStore::open(path).unwrap().snapshot();
    assert_eq!(reopened.messages.len(), snapshot.messages.len());
}
#[test]
fn published_snapshot_does_not_wait_for_persistence_lock() {
    let dir = tempfile::tempdir().unwrap();
    let controller =
        Controller::new(SessionStore::open(dir.path().join("s.json")).unwrap(), None).unwrap();
    let snapshot = controller.snapshot_shared();
    assert_eq!(snapshot.revision, 0);
    assert!(Arc::ptr_eq(&snapshot, &controller.snapshot_shared()));
}

fn shutdown_fixture(controller: &Controller) {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(controller.shutdown())
        .unwrap();
}

#[test]
fn live_unoffered_call_fails_once_and_reopens_without_execution_or_resubmission() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (captured, requests) = mpsc::channel();
    let (finished, wait_finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        captured.send(request(&mut socket)).unwrap();
        let body = json!({"status":"completed","output":[{"type":"function_call","call_id":"unoffered-call","name":"ls","arguments":"{\"path\":\"fixture-only\"}"}]}).to_string();
        let response = format!(
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
            body.len()
        );
        socket.write_all(response.as_bytes()).unwrap();
        drop(socket);
        // The caller signals only after the actor's worker has joined. This is
        // a completion barrier, not a timing guess that no second request ran.
        wait_finished.recv_timeout(Duration::from_secs(5)).unwrap();
        listener.set_nonblocking(true).unwrap();
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
    });
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let profile: Profile = serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":url,"contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let controller = Controller::new(
        SessionStore::open(&path).unwrap(),
        Some((profile, Credential::new("fake-only".into()).unwrap())),
    )
    .unwrap();
    controller
        .submit("synthetic request".into(), Lane::FollowUp)
        .unwrap();
    let raw = requests.recv_timeout(Duration::from_secs(5)).unwrap();
    let raw = String::from_utf8(raw).unwrap();
    let body: serde_json::Value =
        serde_json::from_str(raw.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert!(body.get("tools").is_none());
    await_state(&controller, |s| s.state == RunState::Error);
    let snapshot = controller.snapshot();
    assert_eq!(
        snapshot.error.as_deref(),
        Some(
            "Provider requested tools, which are not enabled in this Rust slice. No tool was executed."
        )
    );
    assert!(snapshot.queue_paused);
    assert!(
        snapshot
            .messages
            .iter()
            .all(|message| message.tool_record.is_none())
    );
    assert!(!snapshot.messages.last().unwrap().replay_eligible);
    shutdown_fixture(&controller);
    drop(controller);
    let reopened = SessionStore::open(&path).unwrap().snapshot();
    assert_eq!(reopened.state, RunState::Error);
    assert_eq!(reopened.messages.len(), snapshot.messages.len());
    assert_eq!(reopened.version, 2);
    finished.send(()).unwrap();
    server.join().unwrap();
}

#[test]
fn stopping_streamed_call_arguments_never_creates_executable_history() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (captured, requests) = mpsc::channel();
    let (finished, wait_finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        captured.send(request(&mut socket)).unwrap();
        socket.write_all(concat!(
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"partial-call\",\"name\":\"ls\"}}\n\n",
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\"}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"waiting for terminal\"}\n\n"
        ).as_bytes()).unwrap();
        socket.flush().unwrap();
        wait_finished.recv_timeout(Duration::from_secs(5)).unwrap();
        drop(socket);
        listener.set_nonblocking(true).unwrap();
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
    });
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let profile: Profile = serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":url,"contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let controller = Controller::new(
        SessionStore::open(&path).unwrap(),
        Some((profile, Credential::new("fake-only".into()).unwrap())),
    )
    .unwrap();
    controller
        .submit("synthetic request".into(), Lane::FollowUp)
        .unwrap();
    requests.recv_timeout(Duration::from_secs(5)).unwrap();
    await_state(&controller, |s| {
        s.messages
            .last()
            .is_some_and(|message| message.text == "waiting for terminal")
    });
    controller.stop().unwrap();
    shutdown_fixture(&controller);
    let snapshot = controller.snapshot();
    assert_eq!(snapshot.state, RunState::Paused);
    assert!(
        snapshot
            .messages
            .iter()
            .all(|message| message.tool_record.is_none())
    );
    assert!(!snapshot.messages.last().unwrap().replay_eligible);
    drop(controller);
    let reopened = SessionStore::open(&path).unwrap().snapshot();
    assert_eq!(
        reopened.messages.last().unwrap().text,
        "waiting for terminal"
    );
    assert!(reopened.queue_paused);
    assert_eq!(reopened.version, 2);
    finished.send(()).unwrap();
    server.join().unwrap();
}

struct PromotionGateway {
    url: String,
    requests: mpsc::Receiver<Vec<u8>>,
    release: mpsc::Sender<bool>,
    finished: mpsc::Sender<()>,
    server: thread::JoinHandle<()>,
}
impl PromotionGateway {
    fn new(count: usize) -> Self {
        Self::from_listener(TcpListener::bind("127.0.0.1:0").unwrap(), count)
    }
    fn from_listener(listener: TcpListener, count: usize) -> Self {
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (captured, requests) = mpsc::channel();
        let (release, wait_release) = mpsc::channel();
        let (finished, wait_finished) = mpsc::channel();
        let server = thread::spawn(move || {
            for n in 0..count {
                let (mut socket, _) = listener.accept().unwrap();
                captured.send(request(&mut socket)).unwrap();
                let reply = json!({"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":format!("reply {n}")}]}]});
                if n == 0 {
                    socket.write_all(concat!(
                        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
                        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"blocked partial\"}\n\n"
                    ).as_bytes()).unwrap();
                    socket.flush().unwrap();
                    // No terminal response is emitted until the test has
                    // durably promoted a queued item (or cancelled the run).
                    if wait_release.recv_timeout(Duration::from_secs(5)).unwrap() {
                        let terminal = json!({"type":"response.completed","response":reply});
                        socket
                            .write_all(
                                format!(
                                    "data: {{\"type\":\"response.output_text.delta\",\"delta\":\" after promotion\"}}\n\ndata: {terminal}\n\n"
                                )
                                .as_bytes(),
                            )
                            .unwrap();
                    }
                } else {
                    let body = reply.to_string();
                    let response = format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    socket.write_all(response.as_bytes()).unwrap();
                }
            }
            // Joining the provider worker is the barrier for checking that
            // promotion/restart never sent a duplicate or an extra request.
            wait_finished.recv_timeout(Duration::from_secs(5)).unwrap();
            listener.set_nonblocking(true).unwrap();
            assert!(
                matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
            );
        });
        Self {
            url,
            requests,
            release,
            finished,
            server,
        }
    }
    fn profile(&self) -> Profile {
        serde_json::from_value(json!({"id":"promotion-fixture","api":"openai-responses","providerId":"litellm","modelId":"captured-model","reasoning":true,"thinkingLevel":"low","baseUrl":self.url,"contextWindow":32000,"maxOutputTokens":4096})).unwrap()
    }
    fn assert_request(&self, id: &str, user_texts: &[&str]) -> serde_json::Value {
        self.assert_request_with_choices(id, user_texts, "captured-model", "low")
    }
    fn assert_request_with_choices(
        &self,
        id: &str,
        user_texts: &[&str],
        model: &str,
        effort: &str,
    ) -> serde_json::Value {
        let raw =
            String::from_utf8(self.requests.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
        let (headers, body) = raw.split_once("\r\n\r\n").unwrap();
        assert!(
            headers
                .lines()
                .any(|line| line.eq_ignore_ascii_case(&format!("x-turn-id: {id}")))
        );
        let body: serde_json::Value = serde_json::from_str(body).unwrap();
        assert_eq!(body["model"], model);
        assert_eq!(body["reasoning"]["effort"], effort);
        assert!(body.get("tools").is_none());
        assert_eq!(
            body["input"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|item| item["role"] == "user")
                .map(|item| item["content"][0]["text"].as_str().unwrap())
                .collect::<Vec<_>>(),
            user_texts
        );
        body
    }
    fn finish(self) {
        self.finished.send(()).unwrap();
        self.server.join().unwrap();
    }
}

fn submit_queue_item(controller: &Arc<Controller>, id: &str, text: &str, lane: Lane) {
    let mut item = Submission::new(text.into(), lane);
    item.id = id.into();
    controller.submit_identified(item).unwrap();
}

fn assert_rejected_promotion(controller: &Controller, path: &std::path::Path, id: &str) {
    let before = serde_json::to_value(controller.snapshot()).unwrap();
    let bytes = std::fs::read(path).unwrap();
    let revision = controller.revision();
    assert!(controller.promote_to_steering(id).is_err());
    assert_eq!(serde_json::to_value(controller.snapshot()).unwrap(), before);
    assert_eq!(std::fs::read(path).unwrap(), bytes);
    assert_eq!(controller.revision(), revision);
}

#[test]
fn promotion_waits_for_active_response_then_drains_existing_steering_before_followups() {
    let gateway = PromotionGateway::new(6);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("promotion.json");
    let controller = Controller::new(
        SessionStore::open(&path).unwrap(),
        Some((
            gateway.profile(),
            Credential::new("fake-only".into()).unwrap(),
        )),
    )
    .unwrap();
    submit_queue_item(&controller, "active", "active", Lane::FollowUp);
    gateway.assert_request("active", &["active"]);
    await_state(&controller, |s| {
        s.messages
            .last()
            .is_some_and(|m| m.text == "blocked partial")
    });
    let full_text = format!("{}\nfull promoted text 🦋", "x".repeat(2048));
    for (id, text, lane) in [
        ("follow-before", "follow before", Lane::FollowUp),
        ("steer-before", "steer before", Lane::Steering),
        ("promoted", full_text.as_str(), Lane::FollowUp),
        ("steer-after", "steer after", Lane::Steering),
        ("follow-after", "follow after", Lane::FollowUp),
    ] {
        submit_queue_item(&controller, id, text, lane);
    }
    controller.begin_edit("follow-before", "hold").unwrap();
    assert_rejected_promotion(&controller, &path, "promoted");
    controller.resolve_edit("hold", "cancelled", None).unwrap();
    for id in ["missing", "active", "steer-before"] {
        assert_rejected_promotion(&controller, &path, id);
    }
    let before = controller.snapshot();
    let mut expected_pending = before.pending.clone();
    let mut promoted = expected_pending.remove(2);
    promoted.lane = Lane::Steering;
    expected_pending.push(promoted);
    controller.promote_to_steering("promoted").unwrap();
    let promoted = controller.snapshot();
    assert_eq!(promoted.state, RunState::Running);
    assert_eq!(promoted.active_reply, before.active_reply);
    assert_eq!(
        serde_json::to_value(&promoted.active).unwrap(),
        serde_json::to_value(before.active).unwrap()
    );
    assert_eq!(
        serde_json::to_value(&promoted.messages).unwrap(),
        serde_json::to_value(before.messages).unwrap()
    );
    assert_eq!(
        serde_json::to_value(&promoted.pending).unwrap(),
        serde_json::to_value(expected_pending).unwrap()
    );
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&std::fs::read(&path).unwrap()).unwrap(),
        serde_json::to_value(&promoted).unwrap()
    );
    assert_rejected_promotion(&controller, &path, "promoted");
    gateway.release.send(true).unwrap();
    let mut texts = vec!["active"];
    for (id, text) in [
        ("steer-before", "steer before"),
        ("steer-after", "steer after"),
        ("promoted", full_text.as_str()),
        ("follow-before", "follow before"),
        ("follow-after", "follow after"),
    ] {
        texts.push(text);
        gateway.assert_request(id, &texts);
    }
    await_state(&controller, |s| {
        s.state == RunState::Idle && s.pending.is_empty()
    });
    shutdown_fixture(&controller);
    let final_snapshot = controller.snapshot();
    assert_eq!(final_snapshot.messages.len(), 12);
    assert!(final_snapshot.messages.iter().all(|m| m.replay_eligible));
    assert_eq!(final_snapshot.messages[1].text, "reply 0");
    assert!(final_snapshot.retry.is_none());
    assert_rejected_promotion(&controller, &path, "promoted");
    drop(controller);
    assert_eq!(
        serde_json::to_value(SessionStore::open(path).unwrap().snapshot()).unwrap(),
        serde_json::to_value(final_snapshot).unwrap()
    );
    gateway.finish();
}

#[test]
fn promoted_queue_survives_stop_reopen_and_retry_with_captured_choices_and_no_duplicates() {
    let gateway = PromotionGateway::new(5);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("promotion.json");
    let controller = Controller::new(
        SessionStore::open(&path).unwrap(),
        Some((
            gateway.profile(),
            Credential::new("fake-only".into()).unwrap(),
        )),
    )
    .unwrap();
    submit_queue_item(&controller, "active", "active", Lane::FollowUp);
    gateway.assert_request("active", &["active"]);
    await_state(&controller, |s| {
        s.messages
            .last()
            .is_some_and(|m| m.text == "blocked partial")
    });
    submit_queue_item(&controller, "follow", "follow", Lane::FollowUp);
    submit_queue_item(&controller, "promoted", "promoted", Lane::FollowUp);
    submit_queue_item(&controller, "steer", "steer", Lane::Steering);
    controller.promote_to_steering("promoted").unwrap();
    let pending = serde_json::to_value(controller.snapshot().pending).unwrap();
    controller.stop().unwrap();
    shutdown_fixture(&controller);
    assert_eq!(controller.snapshot().state, RunState::Paused);
    assert_rejected_promotion(&controller, &path, "follow");
    let stopped = controller.snapshot();
    drop(controller);
    gateway.release.send(false).unwrap();
    let mut changed_profile = gateway.profile();
    changed_profile.model_id = "different-current-model".into();
    changed_profile.thinking_level = "high".into();
    let reopened = Controller::new(
        SessionStore::open(&path).unwrap(),
        Some((
            changed_profile,
            Credential::new("fake-only".into()).unwrap(),
        )),
    )
    .unwrap();
    assert_eq!(
        serde_json::to_value(reopened.snapshot()).unwrap(),
        serde_json::to_value(stopped).unwrap()
    );
    assert_eq!(
        serde_json::to_value(reopened.snapshot().pending).unwrap(),
        pending
    );
    assert!(reopened.snapshot().queue_paused);
    assert_rejected_promotion(&reopened, &path, "follow");
    reopened.retry().unwrap();
    let retry = gateway.assert_request("active", &["active"]);
    assert!(!retry.to_string().contains("blocked partial"));
    gateway.assert_request("steer", &["active", "steer"]);
    gateway.assert_request("promoted", &["active", "steer", "promoted"]);
    gateway.assert_request("follow", &["active", "steer", "promoted", "follow"]);
    await_state(&reopened, |s| {
        s.state == RunState::Idle && s.pending.is_empty()
    });
    shutdown_fixture(&reopened);
    let snapshot = reopened.snapshot();
    assert_eq!(
        snapshot
            .messages
            .iter()
            .filter(|m| m.role == "user")
            .count(),
        4
    );
    assert_eq!(snapshot.messages.len(), 9);
    assert_eq!(snapshot.messages[1].text, "blocked partial");
    assert_eq!(snapshot.messages[1].state, "interrupted");
    assert!(!snapshot.messages[1].replay_eligible);
    assert!(snapshot.messages.iter().skip(2).all(|m| m.replay_eligible));
    assert!(snapshot.retry.is_none());
    drop(reopened);
    assert_eq!(
        serde_json::to_value(SessionStore::open(path).unwrap().snapshot()).unwrap(),
        serde_json::to_value(snapshot).unwrap()
    );
    gateway.finish();
}

#[test]
fn promotion_requires_a_controller_worker_even_with_a_running_checkpoint() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("promotion.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|session| {
            session.submit(Submission::new("active".into(), Lane::FollowUp))?;
            session.start_next()?;
            let mut pending = Submission::new("pending".into(), Lane::FollowUp);
            pending.id = "pending".into();
            session.submit(pending)
        })
        .unwrap();
    let controller = Controller::new(store, None).unwrap();
    assert_eq!(controller.snapshot().state, RunState::Running);
    assert_rejected_promotion(&controller, &path, "pending");
}

#[derive(Clone, Copy)]
enum PublicationObservation {
    Quiescent,
    Streaming,
}

fn assert_rejected_reorder(
    controller: &Controller,
    path: &std::path::Path,
    ids: &[String],
    held: bool,
    publication: PublicationObservation,
) {
    let before = serde_json::to_vec(&controller.snapshot()).unwrap();
    let bytes = std::fs::read(path).unwrap();
    // publish() sends the immutable snapshot before incrementing its counter.
    // Seeing the gated stream's partial text does not prove that increment has
    // completed. The gateway blocks further deltas, so exact snapshot/disk
    // invariants remain meaningful; counter equality requires no publisher.
    let revision = match publication {
        PublicationObservation::Quiescent => Some(controller.revision()),
        PublicationObservation::Streaming => None,
    };
    let error = controller.reorder(ids).unwrap_err();
    if held {
        assert!(
            matches!(error, Error::Invalid(message) if message == "Finish or cancel the queued edit first")
        );
    } else {
        assert!(matches!(error, Error::QueueOrder));
    }
    assert_eq!(serde_json::to_vec(&controller.snapshot()).unwrap(), before);
    assert_eq!(std::fs::read(path).unwrap(), bytes);
    if let Some(revision) = revision {
        assert_eq!(controller.revision(), revision);
    }
}

#[test]
fn reorder_persists_while_active_request_continues_then_drains_steering_and_captured_order() {
    let gateway = PromotionGateway::new(6);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("reorder.json");
    let controller = Controller::new(
        SessionStore::open(&path).unwrap(),
        Some((
            gateway.profile(),
            Credential::new("fake-only".into()).unwrap(),
        )),
    )
    .unwrap();
    submit_queue_item(&controller, "active", "active", Lane::FollowUp);
    gateway.assert_request("active", &["active"]);
    await_state(&controller, |s| {
        s.messages
            .last()
            .is_some_and(|m| m.text == "blocked partial")
    });
    let full_text = format!("{}\nfull reordered text 🦋", "x".repeat(2048));
    for (id, text, lane) in [
        ("first", "first follow-up", Lane::FollowUp),
        ("steer-first", "first steering", Lane::Steering),
        ("middle", full_text.as_str(), Lane::FollowUp),
        ("steer-last", "last steering", Lane::Steering),
        ("last", "last follow-up", Lane::FollowUp),
    ] {
        submit_queue_item(&controller, id, text, lane);
    }
    let order = ["last", "first", "middle"].map(String::from);
    controller.begin_edit("steer-first", "hold").unwrap();
    assert_rejected_reorder(
        &controller,
        &path,
        &order,
        true,
        PublicationObservation::Streaming,
    );
    controller.resolve_edit("hold", "cancelled", None).unwrap();
    for invalid in [
        ["last", "first", "missing"],
        ["last", "first", "steer-first"],
        ["last", "first", "active"],
        ["last", "first", "first"],
    ] {
        assert_rejected_reorder(
            &controller,
            &path,
            &invalid.map(String::from),
            false,
            PublicationObservation::Streaming,
        );
    }
    let before = controller.snapshot();
    let expected_pending = [1, 3, 4, 0, 2].map(|index| before.pending[index].clone());
    controller.reorder(&order).unwrap();
    let reordered = controller.snapshot();
    assert_eq!(reordered.state, RunState::Running);
    assert_eq!(reordered.active_reply, before.active_reply);
    assert_eq!(
        serde_json::to_value(&reordered.active).unwrap(),
        serde_json::to_value(&before.active).unwrap()
    );
    assert_eq!(
        serde_json::to_value(&reordered.messages).unwrap(),
        serde_json::to_value(&before.messages).unwrap()
    );
    assert_eq!(
        serde_json::to_value(&reordered.pending).unwrap(),
        serde_json::to_value(expected_pending).unwrap()
    );
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&std::fs::read(&path).unwrap()).unwrap(),
        serde_json::to_value(&reordered).unwrap()
    );
    gateway.release.send(true).unwrap();
    let mut texts = vec!["active"];
    for (id, text) in [
        ("steer-first", "first steering"),
        ("steer-last", "last steering"),
        ("last", "last follow-up"),
        ("first", "first follow-up"),
        ("middle", full_text.as_str()),
    ] {
        texts.push(text);
        gateway.assert_request(id, &texts);
    }
    await_state(&controller, |s| {
        s.state == RunState::Idle && s.pending.is_empty()
    });
    shutdown_fixture(&controller);
    let final_snapshot = controller.snapshot();
    assert_eq!(final_snapshot.messages.len(), 12);
    assert!(
        final_snapshot
            .messages
            .iter()
            .all(|message| message.replay_eligible)
    );
    assert_eq!(final_snapshot.messages[1].text, "reply 0");
    assert!(final_snapshot.retry.is_none());
    assert_rejected_reorder(
        &controller,
        &path,
        &order,
        false,
        PublicationObservation::Quiescent,
    );
    drop(controller);
    assert_eq!(
        serde_json::to_value(SessionStore::open(path).unwrap().snapshot()).unwrap(),
        serde_json::to_value(final_snapshot).unwrap()
    );
    gateway.finish();
}

#[test]
fn reordered_queue_reopens_with_each_captured_model_effort_and_full_text() {
    let gateway = PromotionGateway::new(3);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("reorder.json");
    let full_text = format!("{}\nretained reordered text 🦋", "x".repeat(2048));
    let rows = [
        ("first", "first follow-up", "captured-first", "low"),
        ("middle", full_text.as_str(), "captured-middle", "medium"),
        ("last", "last follow-up", "captured-last", "high"),
    ];
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|session| {
            for (id, text, model, effort) in rows {
                session.submit(Submission {
                    attachments: Vec::new(),
                    id: id.into(),
                    text: text.into(),
                    lane: Lane::FollowUp,
                    model: Some(model.into()),
                    effort: Some(effort.into()),
                })?;
            }
            session.state = RunState::Paused;
            session.queue_paused = true;
            Ok(())
        })
        .unwrap();
    let controller = Controller::new(store, None).unwrap();
    let order = ["last", "first", "middle"].map(String::from);
    controller.reorder(&order).unwrap();
    let saved = controller.snapshot();
    assert!(saved.queue_paused);
    assert_eq!(saved.state, RunState::Paused);
    drop(controller);
    let mut changed_profile = gateway.profile();
    changed_profile.model_id = "different-current-model".into();
    changed_profile.thinking_level = "xhigh".into();
    let reopened = Controller::new(
        SessionStore::open(&path).unwrap(),
        Some((
            changed_profile,
            Credential::new("fake-only".into()).unwrap(),
        )),
    )
    .unwrap();
    assert_eq!(
        serde_json::to_value(reopened.snapshot()).unwrap(),
        serde_json::to_value(saved).unwrap()
    );
    reopened.resume().unwrap();
    gateway.assert_request_with_choices("last", &["last follow-up"], "captured-last", "high");
    await_state(&reopened, |s| {
        s.messages
            .last()
            .is_some_and(|m| m.text == "blocked partial")
    });
    // The first queued item has now been delivered, invalidating the old drag.
    assert_rejected_reorder(
        &reopened,
        &path,
        &order,
        false,
        PublicationObservation::Streaming,
    );
    gateway.release.send(true).unwrap();
    gateway.assert_request_with_choices(
        "first",
        &["last follow-up", "first follow-up"],
        "captured-first",
        "low",
    );
    gateway.assert_request_with_choices(
        "middle",
        &["last follow-up", "first follow-up", full_text.as_str()],
        "captured-middle",
        "medium",
    );
    await_state(&reopened, |s| {
        s.state == RunState::Idle && s.pending.is_empty()
    });
    shutdown_fixture(&reopened);
    let snapshot = reopened.snapshot();
    assert_eq!(snapshot.messages.len(), 6);
    assert!(
        snapshot
            .messages
            .iter()
            .all(|message| message.replay_eligible)
    );
    assert_eq!(
        snapshot
            .messages
            .iter()
            .filter(|message| message.role == "user")
            .map(|message| message.id.as_str())
            .collect::<Vec<_>>(),
        order.iter().map(String::as_str).collect::<Vec<_>>()
    );
    assert!(snapshot.retry.is_none());
    drop(reopened);
    assert_eq!(
        serde_json::to_value(SessionStore::open(path).unwrap().snapshot()).unwrap(),
        serde_json::to_value(snapshot).unwrap()
    );
    gateway.finish();
}

#[test]
fn rejected_reorder_without_a_worker_preserves_publication_counter() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("quiescent-reorder.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|session| {
            for id in ["first", "second"] {
                let mut item = Submission::new(id.into(), Lane::FollowUp);
                item.id = id.into();
                session.submit(item)?;
            }
            session.state = RunState::Paused;
            session.queue_paused = true;
            Ok(())
        })
        .unwrap();
    let controller = Controller::new(store, None).unwrap();
    let order = ["second", "first"].map(String::from);
    assert_rejected_reorder(
        &controller,
        &path,
        &["missing".into()],
        false,
        PublicationObservation::Quiescent,
    );
    controller.begin_edit("first", "held").unwrap();
    assert_rejected_reorder(
        &controller,
        &path,
        &order,
        true,
        PublicationObservation::Quiescent,
    );
    assert_rejected_reorder(
        &controller,
        &path,
        &["missing".into()],
        false,
        PublicationObservation::Quiescent,
    );
}

fn paused_resume_fixture(path: &std::path::Path) -> (SessionStore, Vec<Submission>) {
    let items = vec![
        Submission {
            attachments: Vec::new(),
            id: "resume-first".into(),
            text: "first persisted follow-up".into(),
            lane: Lane::FollowUp,
            model: Some("captured-first".into()),
            effort: Some("low".into()),
        },
        Submission {
            attachments: Vec::new(),
            id: "resume-middle".into(),
            text: format!("{}\nfull persisted follow-up 🦋", "x".repeat(2048)),
            lane: Lane::FollowUp,
            model: Some("captured-middle".into()),
            effort: Some("medium".into()),
        },
        Submission {
            attachments: Vec::new(),
            id: "resume-last".into(),
            text: "last persisted follow-up".into(),
            lane: Lane::FollowUp,
            model: Some("captured-last".into()),
            effort: Some("high".into()),
        },
    ];
    let mut store = SessionStore::open(path).unwrap();
    store
        .transact(|session| {
            for item in &items {
                session.submit(item.clone())?;
            }
            session.state = RunState::Paused;
            session.queue_paused = true;
            Ok(())
        })
        .unwrap();
    (store, items)
}

fn resume_controller(path: &std::path::Path, gateway: &PromotionGateway) -> Arc<Controller> {
    let mut profile = gateway.profile();
    // Resume must use each accepted item's choices, not today's composer profile.
    profile.model_id = "different-current-model".into();
    profile.thinking_level = "xhigh".into();
    Controller::new(
        SessionStore::open(path).unwrap(),
        Some((profile, Credential::new("fake-only".into()).unwrap())),
    )
    .unwrap()
}

fn assert_rejected_resume(
    controller: &Arc<Controller>,
    path: &std::path::Path,
    expected_error: &str,
    publication: PublicationObservation,
) {
    let before = serde_json::to_vec(&controller.snapshot()).unwrap();
    let bytes = std::fs::read(path).unwrap();
    // As in assert_rejected_reorder, a gated stream has stable snapshot/disk
    // contents but its most recent publication counter can still be advancing.
    let revision = match publication {
        PublicationObservation::Quiescent => Some(controller.revision()),
        PublicationObservation::Streaming => None,
    };
    assert!(
        matches!(controller.resume(), Err(Error::Invalid(message)) if message == expected_error)
    );
    assert_eq!(serde_json::to_vec(&controller.snapshot()).unwrap(), before);
    assert_eq!(std::fs::read(path).unwrap(), bytes);
    if let Some(revision) = revision {
        assert_eq!(controller.revision(), revision);
    }
}

fn assert_resumed_request(gateway: &PromotionGateway, items: &[Submission], index: usize) {
    let item = &items[index];
    gateway.assert_request_with_choices(
        &item.id,
        &items[..=index]
            .iter()
            .map(|item| item.text.as_str())
            .collect::<Vec<_>>(),
        item.model.as_deref().unwrap(),
        item.effort.as_deref().unwrap(),
    );
}

fn assert_resumed_user_messages(snapshot: &Session, items: &[Submission]) {
    let users = snapshot
        .messages
        .iter()
        .filter(|message| message.role == "user")
        .collect::<Vec<_>>();
    assert_eq!(users.len(), items.len());
    for (message, item) in users.into_iter().zip(items) {
        assert_eq!(message.id, item.id);
        assert_eq!(message.text, item.text);
        assert_eq!(message.model, item.model);
        assert!(message.replay_eligible);
    }
}

#[test]
fn resume_persisted_followups_once_with_captured_choices_and_reject_active_resume() {
    let gateway = PromotionGateway::new(3);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("resume.json");
    let (store, items) = paused_resume_fixture(&path);
    let saved = store.snapshot();
    drop(store);
    let controller = resume_controller(&path, &gateway);
    assert_eq!(
        serde_json::to_value(controller.snapshot()).unwrap(),
        serde_json::to_value(saved).unwrap()
    );
    controller.resume().unwrap();
    assert_resumed_request(&gateway, &items, 0);
    await_state(&controller, |session| {
        session
            .messages
            .last()
            .is_some_and(|message| message.text == "blocked partial")
    });
    let active = controller.snapshot();
    assert_eq!(active.state, RunState::Running);
    assert!(!active.queue_paused);
    assert_eq!(
        serde_json::to_value(active.active).unwrap(),
        serde_json::to_value(&items[0]).unwrap()
    );
    assert_eq!(
        serde_json::to_value(active.pending).unwrap(),
        serde_json::to_value(&items[1..]).unwrap()
    );
    assert_rejected_resume(
        &controller,
        &path,
        "Finish the current run or queued edit first",
        PublicationObservation::Streaming,
    );
    // The same gated request must finish, with no cancellation or relaunch.
    gateway.release.send(true).unwrap();
    for index in 1..items.len() {
        assert_resumed_request(&gateway, &items, index);
    }
    await_state(&controller, |session| {
        session.state == RunState::Idle && session.pending.is_empty()
    });
    shutdown_fixture(&controller);
    let completed = controller.snapshot();
    assert_resumed_user_messages(&completed, &items);
    assert_eq!(completed.messages.len(), 2 * items.len());
    assert_eq!(completed.messages[1].text, "reply 0");
    assert!(
        completed
            .messages
            .iter()
            .all(|message| message.replay_eligible)
    );
    assert!(completed.retry.is_none());
    drop(controller);
    assert_eq!(
        serde_json::to_value(SessionStore::open(path).unwrap().snapshot()).unwrap(),
        serde_json::to_value(completed).unwrap()
    );
    gateway.finish();
}

#[test]
fn resume_without_connection_rejects_atomically_and_preserves_reopened_queue() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("disconnected-resume.json");
    let (store, _) = paused_resume_fixture(&path);
    let controller = Controller::new(store, None).unwrap();
    let saved = controller.snapshot();
    assert_rejected_resume(
        &controller,
        &path,
        "No connection configured",
        PublicationObservation::Quiescent,
    );
    shutdown_fixture(&controller);
    drop(controller);
    let reopened = Controller::new(SessionStore::open(&path).unwrap(), None).unwrap();
    assert_eq!(
        serde_json::to_value(reopened.snapshot()).unwrap(),
        serde_json::to_value(saved).unwrap()
    );
    assert_rejected_resume(
        &reopened,
        &path,
        "No connection configured",
        PublicationObservation::Quiescent,
    );
    shutdown_fixture(&reopened);
}

#[test]
fn resume_checkpoint_failure_preserves_queue_and_retries_once_after_storage_is_restored() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let profile: Profile = serde_json::from_value(json!({"id":"resume-write-failure","api":"openai-responses","providerId":"litellm","modelId":"different-current-model","reasoning":true,"thinkingLevel":"xhigh","baseUrl":url,"contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("resume.json");
    let backup = dir.path().join("resume-backup.json");
    let (store, items) = paused_resume_fixture(&path);
    let controller = Controller::new(
        store,
        Some((profile, Credential::new("fake-only".into()).unwrap())),
    )
    .unwrap();
    let before = serde_json::to_vec(&controller.snapshot()).unwrap();
    let bytes = std::fs::read(&path).unwrap();
    let revision = controller.revision();
    // Only this disposable fixture is obstructed. Renaming a checkpoint file
    // onto a directory fails before commit, without relying on chmod or root.
    std::fs::rename(&path, &backup).unwrap();
    std::fs::create_dir(&path).unwrap();
    assert!(matches!(controller.resume(), Err(Error::Io(_))));
    shutdown_fixture(&controller);
    // No worker can still publish or connect after the shutdown barrier.
    assert_eq!(serde_json::to_vec(&controller.snapshot()).unwrap(), before);
    assert_eq!(controller.revision(), revision);
    assert_eq!(std::fs::read(&backup).unwrap(), bytes);
    assert!(path.is_dir());
    assert_eq!(std::fs::read_dir(&path).unwrap().count(), 0);
    listener.set_nonblocking(true).unwrap();
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    listener.set_nonblocking(false).unwrap();
    let gateway = PromotionGateway::from_listener(listener, items.len());

    std::fs::remove_dir(&path).unwrap();
    std::fs::rename(&backup, &path).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    // Retry Resume on the same controller: a failed checkpoint must not latch
    // a fatal state, discard accepted work, or require re-submitting its text.
    controller.resume().unwrap();
    assert_resumed_request(&gateway, &items, 0);
    await_state(&controller, |session| {
        session
            .messages
            .last()
            .is_some_and(|message| message.text == "blocked partial")
    });
    gateway.release.send(true).unwrap();
    for index in 1..items.len() {
        assert_resumed_request(&gateway, &items, index);
    }
    await_state(&controller, |session| {
        session.state == RunState::Idle && session.pending.is_empty()
    });
    shutdown_fixture(&controller);
    let completed = controller.snapshot();
    assert_resumed_user_messages(&completed, &items);
    assert_eq!(completed.messages.len(), 2 * items.len());
    assert!(
        completed
            .messages
            .iter()
            .all(|message| message.replay_eligible)
    );
    assert!(completed.retry.is_none());
    drop(controller);
    assert_eq!(
        serde_json::to_value(SessionStore::open(path).unwrap().snapshot()).unwrap(),
        serde_json::to_value(completed).unwrap()
    );
    gateway.finish();
}

#[test]
fn resume_held_edit_rejects_atomically_after_reopen_and_cancel_keeps_queue_paused() {
    let gateway = PromotionGateway::new(0);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("held-resume.json");
    let (store, items) = paused_resume_fixture(&path);
    drop(store);
    let controller = resume_controller(&path, &gateway);
    assert_eq!(
        controller.begin_edit(&items[1].id, "resume-hold").unwrap(),
        items[1].text
    );
    let held = controller.snapshot();
    assert_rejected_resume(
        &controller,
        &path,
        "Finish the current run or queued edit first",
        PublicationObservation::Quiescent,
    );
    shutdown_fixture(&controller);
    drop(controller);
    let reopened = resume_controller(&path, &gateway);
    let recovered = reopened.snapshot();
    assert_eq!(recovered.state, RunState::Paused);
    assert!(recovered.queue_paused);
    assert_eq!(
        serde_json::to_value(recovered.edit).unwrap(),
        serde_json::to_value(held.edit).unwrap()
    );
    assert_eq!(
        serde_json::to_value(recovered.pending).unwrap(),
        serde_json::to_value(&items).unwrap()
    );
    assert_rejected_resume(
        &reopened,
        &path,
        "Finish the current run or queued edit first",
        PublicationObservation::Quiescent,
    );
    reopened
        .resolve_edit("resume-hold", "cancelled", None)
        .unwrap();
    shutdown_fixture(&reopened);
    let cancelled = reopened.snapshot();
    assert!(cancelled.edit.is_none());
    assert!(cancelled.queue_paused);
    assert_eq!(cancelled.state, RunState::Paused);
    assert!(cancelled.messages.is_empty());
    assert_eq!(
        serde_json::to_value(&cancelled.pending).unwrap(),
        serde_json::to_value(items).unwrap()
    );
    drop(reopened);
    assert_eq!(
        serde_json::to_value(SessionStore::open(path).unwrap().snapshot()).unwrap(),
        serde_json::to_value(cancelled).unwrap()
    );
    gateway.finish();
}

fn assert_resume_recovers_remaining_queue_after_interruption(close_while_active: bool) {
    let gateway = PromotionGateway::new(3);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("interrupted-resume.json");
    let (store, items) = paused_resume_fixture(&path);
    drop(store);
    let controller = resume_controller(&path, &gateway);
    controller.resume().unwrap();
    assert_resumed_request(&gateway, &items, 0);
    await_state(&controller, |session| {
        session
            .messages
            .last()
            .is_some_and(|message| message.text == "blocked partial")
    });
    if close_while_active {
        // Closing awaits cancellation while the provider is still gated.
        shutdown_fixture(&controller);
        gateway.release.send(false).unwrap();
    } else {
        // EOF without a terminal event is a provider failure, not completion.
        gateway.release.send(false).unwrap();
        await_state(&controller, |session| session.state == RunState::Error);
        shutdown_fixture(&controller);
    }
    let interrupted = controller.snapshot();
    assert_eq!(
        interrupted.state,
        if close_while_active {
            RunState::Paused
        } else {
            RunState::Error
        }
    );
    assert!(interrupted.queue_paused);
    assert!(interrupted.active.is_none());
    assert!(interrupted.active_reply.is_none());
    assert!(interrupted.error.is_some());
    assert_eq!(
        serde_json::to_value(&interrupted.retry).unwrap(),
        serde_json::to_value(&items[0]).unwrap()
    );
    assert_eq!(
        serde_json::to_value(&interrupted.pending).unwrap(),
        serde_json::to_value(&items[1..]).unwrap()
    );
    assert_eq!(interrupted.messages.len(), 2);
    assert_eq!(interrupted.messages[1].text, "blocked partial");
    assert_eq!(interrupted.messages[1].state, "interrupted");
    assert!(!interrupted.messages[1].replay_eligible);
    drop(controller);
    let reopened = resume_controller(&path, &gateway);
    assert_eq!(
        serde_json::to_value(reopened.snapshot()).unwrap(),
        serde_json::to_value(interrupted).unwrap()
    );
    // Resume consumes only the remaining queue; Retry is a separate operation.
    reopened.resume().unwrap();
    for index in 1..items.len() {
        assert_resumed_request(&gateway, &items, index);
    }
    await_state(&reopened, |session| {
        session.state == RunState::Idle && session.pending.is_empty()
    });
    shutdown_fixture(&reopened);
    let completed = reopened.snapshot();
    assert_resumed_user_messages(&completed, &items);
    assert_eq!(completed.messages.len(), 2 * items.len());
    assert_eq!(
        completed
            .messages
            .iter()
            .filter(|message| message.state == "interrupted")
            .count(),
        1
    );
    assert!(completed.retry.is_none());
    drop(reopened);
    assert_eq!(
        serde_json::to_value(SessionStore::open(path).unwrap().snapshot()).unwrap(),
        serde_json::to_value(completed).unwrap()
    );
    gateway.finish();
}

#[test]
fn resume_after_provider_failure_and_reopen_keeps_remaining_queue_without_retrying() {
    assert_resume_recovers_remaining_queue_after_interruption(false);
}

#[test]
fn resume_after_active_close_and_reopen_keeps_remaining_queue_without_retrying() {
    assert_resume_recovers_remaining_queue_after_interruption(true);
}
