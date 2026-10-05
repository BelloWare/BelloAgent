use bello_agent_core::{Controller, Credential, Lane, Profile, RunState, Session, SessionStore};
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
