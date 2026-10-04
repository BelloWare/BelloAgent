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
