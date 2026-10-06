//! Save/stop fault tests use disposable stores and an injected stop boundary.
use super::ShutdownPlan;
use bello_agent_core::{
    Controller, Lane, SessionStore,
    workspace::{ChatRecord, DraftRecord, QueuedDraft, SubmissionIntent, WorkspaceStore},
};
use gpui::TestAppContext;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};

fn fixture() -> (tempfile::TempDir, ShutdownPlan) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let controller = Controller::new(SessionStore::pending(), None).unwrap();
    let snapshot = controller.snapshot();
    let record = ChatRecord {
        sidebar_order: None,
        pinned_at: None,
        archived_at: None,
        tool_mode: Default::default(),
        id: snapshot.id,
        title: snapshot.title,
        snapshot: project.join("session.json"),
    };
    let plan = ShutdownPlan {
        selected: record.id.clone(),
        selection_revision: 20,
        drafts: vec![(
            record,
            DraftRecord {
                revision: 10,
                text: "latest".into(),
                queued_edit: None,
            },
        )],
        controllers: vec![controller],
        workspace: Arc::new(Mutex::new(
            WorkspaceStore::open(project.join("workspace.json"), &project).unwrap(),
        )),
    };
    (dir, plan)
}

#[gpui::test]
fn saved_capture_precedes_stop_and_rejects_late_draft_and_selection(cx: &mut TestAppContext) {
    let (_dir, plan) = fixture();
    let workspace = plan.workspace.clone();
    let selected = plan.selected.clone();
    let calls = AtomicUsize::new(0);
    let outcome = cx
        .background_executor
        .block_test(plan.execute_with_stop(|_| {
            calls.fetch_add(1, Ordering::SeqCst);
            let mut store = workspace.lock().unwrap();
            assert_eq!(store.snapshot().drafts[&selected].text, "latest");
            assert_eq!(store.snapshot().selected.as_ref(), Some(&selected));
            assert!(
                !store
                    .save_draft(
                        &selected,
                        DraftRecord {
                            revision: 9,
                            text: "late".into(),
                            queued_edit: None
                        }
                    )
                    .unwrap()
            );
            assert!(!store.select(&selected, 19).unwrap());
            async { Ok(()) }
        }));
    assert!(outcome.result.is_ok());
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        workspace.lock().unwrap().snapshot().drafts[&selected].text,
        "latest"
    );
}

#[gpui::test]
fn queued_edit_and_unsettled_receipt_survive_save_stop_and_reopen(cx: &mut TestAppContext) {
    let (dir, mut plan) = fixture();
    let id = plan.selected.clone();
    let intent = SubmissionIntent {
        id: uuid::Uuid::new_v4().to_string(),
        chat_id: id.clone(),
        text: "accepted maybe".into(),
        lane: Lane::FollowUp,
        draft_revision: 1,
    };
    {
        let mut store = plan.workspace.lock().unwrap();
        store
            .register(
                plan.drafts[0].0.clone(),
                DraftRecord {
                    revision: 1,
                    text: intent.text.clone(),
                    queued_edit: None,
                },
            )
            .unwrap();
        store.begin_submission(intent.clone()).unwrap();
    }
    plan.drafts[0].1.queued_edit = Some(QueuedDraft {
        edit_id: "edit".into(),
        turn_id: "turn".into(),
        rewrite: "queued rewrite".into(),
        original_text: Some("original".into()),
    });
    let expected = plan.drafts[0].1.clone();
    let outcome = cx.background_executor.block_test(plan.execute());
    assert!(outcome.result.is_ok());
    let store = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
    assert_eq!(store.snapshot().drafts[&id], expected);
    assert_eq!(store.snapshot().intents[&intent.id], intent);
}

#[gpui::test]
fn save_failure_never_calls_stop_and_partial_registration_is_returned(cx: &mut TestAppContext) {
    let (dir, plan) = fixture();
    std::fs::create_dir(dir.path().join("workspace.json")).unwrap();
    let calls = AtomicUsize::new(0);
    let outcome = cx
        .background_executor
        .block_test(plan.execute_with_stop(|_| {
            calls.fetch_add(1, Ordering::SeqCst);
            async { Ok(()) }
        }));
    assert!(outcome.result.is_err());
    assert!(outcome.registered.is_empty());
    assert_eq!(calls.load(Ordering::SeqCst), 0);

    let (_dir, mut plan) = fixture();
    let first = plan.selected.clone();
    let mut invalid = plan.drafts[0].clone();
    invalid.0.id = uuid::Uuid::new_v4().to_string();
    invalid.1.text = "x".repeat(262_145);
    plan.drafts.push(invalid);
    let outcome = cx
        .background_executor
        .block_test(plan.execute_with_stop(|_| {
            calls.fetch_add(1, Ordering::SeqCst);
            async { Ok(()) }
        }));
    assert!(outcome.result.is_err());
    assert_eq!(outcome.registered, vec![first]);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

#[test]
fn later_stop_failure_allows_retry_of_already_stopped_controller() {
    let (_dir, mut plan) = fixture();
    // A real loopback Responses worker is active before the first shutdown.
    // No model service or credential discovery is involved.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let server = std::thread::spawn(move || {
        use std::io::{Read, Write};
        let (mut socket, _) = listener.accept().unwrap();
        socket
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        let mut raw = Vec::new();
        let mut buffer = [0; 4096];
        loop {
            let n = socket.read(&mut buffer).unwrap();
            assert_ne!(n, 0);
            raw.extend_from_slice(&buffer[..n]);
            if let Some(end) = raw.windows(4).position(|part| part == b"\r\n\r\n") {
                let header = String::from_utf8_lossy(&raw[..end]).to_lowercase();
                let length: usize = header
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length: "))
                    .unwrap_or("0")
                    .parse()
                    .unwrap();
                if raw.len() >= end + 4 + length {
                    break;
                }
            }
        }
        socket
            .write_all(
                b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
            )
            .unwrap();
        socket.flush().unwrap();
        ready_tx.send(()).unwrap();
        release_rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
    });
    let profile = serde_json::from_value(serde_json::json!({"id":"shutdown-fixture", "api":"openai-responses", "providerId":"litellm", "modelId":"fixture", "baseUrl":format!("http://{address}"), "contextWindow":32000, "maxOutputTokens":4096})).unwrap();
    let first = Controller::new(
        SessionStore::open(_dir.path().join("active-session.json")).unwrap(),
        Some((
            profile,
            bello_agent_core::Credential::new("fake-loopback-only".into()).unwrap(),
        )),
    )
    .unwrap();
    first.submit("stop fixture".into(), Lane::FollowUp).unwrap();
    ready_rx
        .recv_timeout(std::time::Duration::from_secs(5))
        .unwrap();
    assert_eq!(first.snapshot().state, bello_agent_core::RunState::Running);
    plan.controllers[0] = first.clone();
    let second = Controller::new(SessionStore::pending(), None).unwrap();
    plan.controllers.push(second.clone());
    let retry = ShutdownPlan {
        drafts: plan.drafts.clone(),
        controllers: plan.controllers.clone(),
        selected: plan.selected.clone(),
        selection_revision: plan.selection_revision + 1,
        workspace: plan.workspace.clone(),
    };
    let calls = AtomicUsize::new(0);
    let outcome = block_external(plan.execute_with_stop(|controller| {
        let n = calls.fetch_add(1, Ordering::SeqCst);
        async move {
            if n == 1 {
                return Err("injected later worker failure".into());
            }
            controller
                .shutdown()
                .await
                .map_err(|error| error.to_string())
        }
    }));
    assert!(outcome.result.is_err());
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    assert_ne!(first.snapshot().state, bello_agent_core::RunState::Running);
    release_tx.send(()).unwrap();
    server.join().unwrap();
    let outcome = block_external(retry.execute());
    assert!(outcome.result.is_ok());
    // Repeated real shutdown remains safe after both the failed and retried barrier.
    block_external(async {
        first.shutdown().await.unwrap();
        second.shutdown().await.unwrap();
    });
}

// Tokio's real worker wakes an OS thread; GPUI's deterministic fake executor
// deliberately rejects such parked external work. Poll it with a bounded waker.
fn block_external<T>(future: impl std::future::Future<Output = T>) -> T {
    struct WakeThread(std::thread::Thread);
    impl std::task::Wake for WakeThread {
        fn wake(self: Arc<Self>) {
            self.0.unpark();
        }
    }
    let waker = std::task::Waker::from(Arc::new(WakeThread(std::thread::current())));
    let mut context = std::task::Context::from_waker(&waker);
    let mut future = std::pin::pin!(future);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        if let std::task::Poll::Ready(value) = future.as_mut().poll(&mut context) {
            return value;
        }
        let remaining = deadline
            .checked_duration_since(std::time::Instant::now())
            .expect("external worker timed out");
        std::thread::park_timeout(remaining);
    }
}
