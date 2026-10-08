//! End-to-end coverage of the Rust chat catalog and independently owned workers.
//! Every provider request stays on an ephemeral loopback listener with fake credentials.
use bello_agent_core::{
    Controller, Credential, Lane, Profile, RunState, Session, SessionStore, Submission,
    workspace::{ChatRecord, DraftRecord, QueuedDraft, SubmissionIntent, WorkspaceStore},
};
use serde_json::{Value, json};
use std::{collections::BTreeMap, path::Path, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::mpsc,
    task::JoinHandle,
    time::timeout,
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

const DEADLINE: Duration = Duration::from_secs(5);

struct Request {
    headers: BTreeMap<String, String>,
    body: Value,
    socket: TcpStream,
    streaming: bool,
}
impl Request {
    async fn read(mut socket: TcpStream) -> Self {
        let mut bytes = Vec::new();
        let (body_start, body_len) = loop {
            let mut buf = [0; 4096];
            let count = socket.read(&mut buf).await.unwrap();
            assert_ne!(count, 0, "provider disconnected before its request body");
            bytes.extend_from_slice(&buf[..count]);
            assert!(
                bytes.len() < 1024 * 1024,
                "unexpectedly large fixture request"
            );
            if let Some(end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                let head = String::from_utf8_lossy(&bytes[..end]).to_lowercase();
                let len: usize = head
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length: "))
                    .expect("JSON request must have a content length")
                    .parse()
                    .unwrap();
                if bytes.len() >= end + 4 + len {
                    break (end + 4, len);
                }
            }
        };
        let headers = String::from_utf8_lossy(&bytes[..body_start - 4])
            .lines()
            .skip(1)
            .map(|line| {
                let (name, value) = line.split_once(':').unwrap();
                (name.to_lowercase(), value.trim().to_owned())
            })
            .collect();
        Self {
            headers,
            body: serde_json::from_slice(&bytes[body_start..body_start + body_len]).unwrap(),
            socket,
            streaming: false,
        }
    }
    fn assert_identity(&self, session_id: &str, turn_id: &str) {
        for header in ["x-session-id", "session_id", "x-client-request-id"] {
            assert_eq!(self.headers[header], session_id, "wrong {header}");
        }
        assert_eq!(self.headers["x-turn-id"], turn_id);
        assert_eq!(
            self.headers["authorization"],
            "Bearer fixture-only-not-a-secret"
        );
        assert_eq!(self.body["metadata"]["session_id"], session_id);
        assert_eq!(self.body["prompt_cache_key"], session_id);
    }
    fn input_texts(&self) -> Vec<&str> {
        self.body["input"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|item| item["content"].as_array().unwrap())
            .map(|part| part["text"].as_str().unwrap())
            .collect()
    }
    async fn event(&mut self, value: Value) {
        timeout(DEADLINE, async {
            if !self.streaming {
                self.socket
                    .write_all(b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n")
                    .await
                    .unwrap();
                self.streaming = true;
            }
            self.socket
                .write_all(format!("data: {value}\n\n").as_bytes())
                .await
                .unwrap();
            self.socket.flush().await.unwrap();
        })
        .await
        .expect("fixture response write timed out");
    }
    async fn delta(&mut self, text: &str) {
        self.event(json!({"type":"response.output_text.delta", "delta":text}))
            .await;
    }
    async fn complete(&mut self, text: &str) {
        self.event(json!({
            "type":"response.completed",
            "response": {
                "status":"completed",
                "output":[{"type":"message","content":[{"type":"output_text","text":text}]}]
            }
        }))
        .await;
        self.socket.shutdown().await.unwrap();
    }
}

struct Provider {
    url: String,
    requests: mpsc::UnboundedReceiver<Request>,
    cancel: CancellationToken,
    server: JoinHandle<()>,
}
impl Provider {
    async fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (send, requests) = mpsc::unbounded_channel();
        let cancel = CancellationToken::new();
        let stop = cancel.clone();
        let server = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = stop.cancelled() => return,
                    accepted = listener.accept() => {
                        let (socket, _) = accepted.unwrap();
                        let request = timeout(DEADLINE, Request::read(socket)).await
                            .expect("provider request body timed out");
                        if send.send(request).is_err() {
                            return;
                        }
                    }
                }
            }
        });
        Self {
            url,
            requests,
            cancel,
            server,
        }
    }
    fn controller(&self, store: SessionStore) -> Arc<Controller> {
        let profile: Profile = serde_json::from_value(json!({
            "id":"chat-workspace-fixture", "api":"openai-responses", "providerId":"litellm",
            "modelId":"local-fixture", "baseUrl":self.url,
            "contextWindow":32000, "maxOutputTokens":4096
        }))
        .unwrap();
        Controller::new(
            store,
            Some((
                profile,
                Credential::new("fixture-only-not-a-secret".into()).unwrap(),
            )),
        )
        .unwrap()
    }
    async fn next(&mut self) -> Request {
        timeout(DEADLINE, self.requests.recv())
            .await
            .expect("expected provider request timed out")
            .expect("provider listener stopped")
    }
    // Check the bounded quiet window as well as persisted paused state. This is
    // a deadline on an observable channel, never a sleep/count-of-polls test.
    async fn assert_quiet(&mut self) {
        assert!(
            timeout(Duration::from_millis(100), self.requests.recv())
                .await
                .is_err(),
            "paused, pending, or reopened chat unexpectedly dispatched input"
        );
    }
    async fn finish(mut self) {
        self.cancel.cancel();
        timeout(DEADLINE, self.server).await.unwrap().unwrap();
        assert!(
            self.requests.try_recv().is_err(),
            "unexpected extra provider request"
        );
    }
}

async fn await_state(controller: &Controller, predicate: impl Fn(&Session) -> bool) {
    let mut updates = controller.subscribe();
    timeout(DEADLINE, async {
        loop {
            if predicate(&updates.borrow_and_update()) {
                return;
            }
            updates
                .changed()
                .await
                .expect("controller subscription closed");
        }
    })
    .await
    .unwrap_or_else(|_| panic!("session transition timed out: {:?}", controller.snapshot()));
}
async fn shutdown(controller: &Controller) {
    timeout(DEADLINE, controller.shutdown())
        .await
        .unwrap()
        .unwrap();
}
fn register(
    workspace: &mut WorkspaceStore,
    controller: &Controller,
    draft: DraftRecord,
) -> ChatRecord {
    let session = controller.snapshot();
    let chat = ChatRecord {
        tool_mode: Default::default(),
        connection_id: None,
        materialization: bello_agent_core::workspace::ChatMaterialization::CheckpointRequired,
        sidebar_order: None,
        pinned_at: None,
        archived_at: None,
        topic_id: None,
        topic_revision: 0,
        snapshot: workspace.chat_path(&session.id).unwrap(),
        id: session.id,
        title: session.title,
    };
    controller.materialize(&chat.snapshot).unwrap();
    workspace.register(chat.clone(), draft).unwrap();
    chat
}
fn draft(revision: u64, text: &str) -> DraftRecord {
    DraftRecord {
        skills: Vec::new(),
        attachments: Vec::new(),
        revision,
        text: text.into(),
        queued_edit: None,
    }
}
fn intent(chat: &ChatRecord, revision: u64, text: &str) -> SubmissionIntent {
    SubmissionIntent {
        skills: Vec::new(),
        attachments: Vec::new(),
        id: Uuid::new_v4().to_string(),
        chat_id: chat.id.clone(),
        text: text.into(),
        lane: Lane::FollowUp,
        draft_revision: revision,
    }
}
fn reopen_workspace(path: &Path, project: &Path) -> WorkspaceStore {
    WorkspaceStore::open(path, project).unwrap()
}

#[test]
fn concurrent_chat_debounces_keep_independent_revisions_after_interleaved_saves() {
    use std::sync::{Mutex, mpsc};

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workspace.json");
    let mut workspace = WorkspaceStore::open(&path, dir.path()).unwrap();
    let chats: Vec<_> = ["A", "B"]
        .into_iter()
        .map(|title| ChatRecord {
            tool_mode: Default::default(),
            connection_id: None,
            materialization: bello_agent_core::workspace::ChatMaterialization::CheckpointRequired,
            sidebar_order: None,
            pinned_at: None,
            archived_at: None,
            topic_id: None,
            topic_revision: 0,
            id: Uuid::new_v4().to_string(),
            title: title.into(),
            snapshot: dir.path().join(format!("{title}.json")),
        })
        .collect();
    for chat in &chats {
        workspace
            .register(chat.clone(), draft(1, "initial"))
            .unwrap();
    }
    let workspace = Arc::new(Mutex::new(workspace));
    let (receipts, received) = mpsc::channel();
    let mut workers = Vec::new();
    let mut commands = Vec::new();
    for chat in &chats {
        let (send, receive) = mpsc::channel::<DraftRecord>();
        commands.push(send);
        let workspace = Arc::clone(&workspace);
        let receipts = receipts.clone();
        let id = chat.id.clone();
        workers.push(std::thread::spawn(move || {
            for _ in 0..2 {
                let draft = receive
                    .recv_timeout(DEADLINE)
                    .expect("missing debounce release");
                let saved = workspace.lock().unwrap().save_draft(&id, draft);
                receipts.send((id.clone(), saved)).unwrap();
            }
        }));
    }
    // Receipts are explicit barriers: A's newer callback commits, then B's.
    // B's lower numeric revision must still be accepted independently of A.
    commands[0].send(draft(200, "A latest typing")).unwrap();
    let (id, saved) = received.recv_timeout(DEADLINE).unwrap();
    assert_eq!(id, chats[0].id);
    assert!(saved.unwrap());
    commands[1].send(draft(2, "B latest typing")).unwrap();
    let (id, saved) = received.recv_timeout(DEADLINE).unwrap();
    assert_eq!(id, chats[1].id);
    assert!(saved.unwrap());

    // Both obsolete callbacks are now released concurrently. Either lock order
    // must leave both chat drafts intact, with no aggregate catalog mutation.
    let revision = workspace.lock().unwrap().snapshot().revision;
    commands[0].send(draft(199, "A stale typing")).unwrap();
    commands[1].send(draft(1, "B stale typing")).unwrap();
    for _ in 0..2 {
        assert!(!received.recv_timeout(DEADLINE).unwrap().1.unwrap());
    }
    for worker in workers {
        worker.join().unwrap();
    }
    assert_eq!(workspace.lock().unwrap().snapshot().revision, revision);
    drop(workspace);
    let workspace = reopen_workspace(&path, dir.path());
    assert_eq!(
        workspace.snapshot().drafts[&chats[0].id],
        draft(200, "A latest typing")
    );
    assert_eq!(
        workspace.snapshot().drafts[&chats[1].id],
        draft(2, "B latest typing")
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hidden_chat_keeps_streaming_while_visible_chat_queues_and_stops() {
    let dir = tempfile::tempdir().unwrap();
    let mut provider = Provider::new().await;
    let mut workspace =
        WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
    let hidden = provider.controller(SessionStore::pending());
    let visible =
        Controller::with_configuration(SessionStore::pending(), hidden.configuration()).unwrap();
    assert!(Arc::ptr_eq(
        &hidden.configuration().unwrap(),
        &visible.configuration().unwrap()
    ));
    let a = register(&mut workspace, &hidden, draft(1, "unfinished hidden draft"));
    let b = register(
        &mut workspace,
        &visible,
        draft(1, "unfinished visible draft"),
    );
    assert_ne!(a.id, b.id);
    workspace.select(&a.id, 1).unwrap();
    let first = Submission::new("hidden first".into(), Lane::FollowUp);
    hidden.submit_identified(first.clone()).unwrap();
    let mut hidden_request = provider.next().await;
    hidden_request.assert_identity(&a.id, &first.id);
    assert_eq!(hidden_request.input_texts(), vec!["hidden first"]);
    hidden_request.delta("hidden partial").await;
    await_state(&hidden, |s| {
        s.messages
            .last()
            .is_some_and(|m| m.text == "hidden partial")
    })
    .await;

    workspace.select(&b.id, 2).unwrap();
    let selection_revision = workspace.snapshot().revision;
    assert!(!workspace.select(&a.id, 1).unwrap());
    assert!(!workspace.select(&a.id, 2).unwrap());
    assert_eq!(workspace.snapshot().revision, selection_revision);
    let second = Submission::new("visible first".into(), Lane::FollowUp);
    visible.submit_identified(second.clone()).unwrap();
    let mut visible_request = provider.next().await;
    visible_request.assert_identity(&b.id, &second.id);
    assert_eq!(visible_request.input_texts(), vec!["visible first"]);
    visible_request.delta("visible partial").await;
    await_state(&visible, |s| {
        s.messages
            .last()
            .is_some_and(|m| m.text == "visible partial")
    })
    .await;
    let queued = Submission::new("visible queued".into(), Lane::FollowUp);
    visible.submit_identified(queued.clone()).unwrap();
    visible.stop().unwrap();
    await_state(&visible, |s| s.state == RunState::Paused).await;
    shutdown(&visible).await;
    assert_eq!(visible.snapshot().pending[0].id, queued.id);
    assert!(visible.snapshot().queue_paused);
    assert_eq!(hidden.snapshot().state, RunState::Running);

    // A provider delta after the other chat's Stop must still reach only A.
    hidden_request.delta(" while hidden").await;
    await_state(&hidden, |s| {
        s.messages
            .last()
            .is_some_and(|m| m.text == "hidden partial while hidden")
    })
    .await;
    hidden_request.complete("hidden complete").await;
    await_state(&hidden, |s| s.state == RunState::Idle).await;
    shutdown(&hidden).await;
    let a_state = hidden.snapshot();
    let b_state = visible.snapshot();
    assert_eq!(a_state.messages.last().unwrap().text, "hidden complete");
    assert!(a_state.messages.last().unwrap().replay_eligible);
    assert_eq!(b_state.messages.last().unwrap().text, "visible partial");
    assert!(!b_state.messages.last().unwrap().replay_eligible);
    assert!(a_state.pending.is_empty());
    assert_eq!(
        a_state.messages.iter().filter(|m| m.role == "user").count(),
        1
    );
    assert_eq!(
        b_state.messages.iter().filter(|m| m.role == "user").count(),
        1
    );
    assert_eq!(
        workspace.snapshot().selected.as_deref(),
        Some(b.id.as_str())
    );
    assert_eq!(
        workspace.snapshot().drafts[&a.id].text,
        "unfinished hidden draft"
    );
    assert_eq!(
        workspace.snapshot().drafts[&b.id].text,
        "unfinished visible draft"
    );
    drop((hidden, visible, hidden_request, visible_request, workspace));
    assert_eq!(SessionStore::open(&a.snapshot).unwrap().snapshot().id, a.id);
    let reopened = SessionStore::open(&b.snapshot).unwrap().snapshot();
    assert_eq!(reopened.id, b.id);
    assert_eq!(reopened.pending[0].id, queued.id);
    assert_eq!(reopened.state, RunState::Paused);
    provider.finish().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn pending_controller_rejects_submission_until_materialized_with_same_identity() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("chat.json");
    let mut provider = Provider::new().await;
    let id = Uuid::new_v4().to_string();
    let controller = provider.controller(SessionStore::pending_with_id(&id).unwrap());
    let submission = Submission::new("submit once after materialization".into(), Lane::FollowUp);
    let error = controller
        .submit_identified(submission.clone())
        .unwrap_err();
    assert!(error.to_string().contains("Materialize"));
    assert!(!controller.is_persistent());
    assert!(!path.exists());
    assert!(!path.with_extension("lock").exists());
    assert_eq!(controller.snapshot().id, id);
    assert!(controller.snapshot().messages.is_empty());
    assert!(controller.snapshot().pending.is_empty());
    assert_eq!(controller.revision(), 0);
    provider.assert_quiet().await;
    controller.materialize(&path).unwrap();
    assert!(controller.is_persistent());
    assert_eq!(controller.snapshot().id, id);
    controller.submit_identified(submission.clone()).unwrap();
    let mut request = provider.next().await;
    request.assert_identity(&id, &submission.id);
    request.complete("accepted once").await;
    await_state(&controller, |s| {
        s.state == RunState::Idle && !s.messages.is_empty()
    })
    .await;
    assert!(controller.submit_identified(submission).is_err());
    shutdown(&controller).await;
    drop(controller);
    let reopened = SessionStore::open(&path).unwrap().snapshot();
    assert_eq!(reopened.id, id);
    assert_eq!(
        reopened
            .messages
            .iter()
            .filter(|m| m.role == "user")
            .count(),
        1
    );
    provider.finish().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn held_edit_preserves_rewrite_and_displaced_drafts_across_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workspace.json");
    let mut provider = Provider::new().await;
    let mut workspace = WorkspaceStore::open(&path, dir.path()).unwrap();
    let controller = provider.controller(SessionStore::pending());
    let chat = register(
        &mut workspace,
        &controller,
        draft(1, "displaced composer thought"),
    );
    let other = Controller::with_configuration(SessionStore::pending(), controller.configuration())
        .unwrap();
    let other_chat = register(&mut workspace, &other, draft(3, "independent other draft"));
    controller
        .submit("active first".into(), Lane::FollowUp)
        .unwrap();
    let mut request = provider.next().await;
    request.delta("interrupted partial").await;
    await_state(&controller, |s| {
        s.messages
            .last()
            .is_some_and(|m| m.text == "interrupted partial")
    })
    .await;
    let queued = Submission::new("original queued text".into(), Lane::FollowUp);
    controller.submit_identified(queued.clone()).unwrap();
    assert_eq!(
        controller.begin_edit(&queued.id, "held-edit").unwrap(),
        queued.text
    );
    let held = DraftRecord {
        skills: Vec::new(),
        attachments: Vec::new(),
        revision: 2,
        text: "displaced composer thought".into(),
        queued_edit: Some(QueuedDraft {
            edit_id: "held-edit".into(),
            turn_id: queued.id.clone(),
            rewrite: "unfinished queued rewrite".into(),
            original_text: Some(queued.text.clone()),
        }),
    };
    workspace.save_draft(&chat.id, held.clone()).unwrap();
    workspace.select(&other_chat.id, 7).unwrap();
    controller.stop().unwrap();
    await_state(&controller, |s| s.state == RunState::Paused).await;
    shutdown(&controller).await;
    shutdown(&other).await;
    let configuration = controller.configuration();
    drop((controller, other, workspace, request));

    let mut workspace = reopen_workspace(&path, dir.path());
    let controller =
        Controller::with_configuration(SessionStore::open(&chat.snapshot).unwrap(), configuration)
            .unwrap();
    assert_eq!(workspace.snapshot().drafts[&chat.id], held);
    assert_eq!(
        workspace.snapshot().drafts[&other_chat.id],
        draft(3, "independent other draft")
    );
    assert_eq!(
        workspace.snapshot().selected.as_deref(),
        Some(other_chat.id.as_str())
    );
    let restored = controller.snapshot();
    assert_eq!(restored.edit.as_ref().unwrap().edit_id, "held-edit");
    assert_eq!(restored.edit.as_ref().unwrap().turn_id, queued.id);
    assert_eq!(restored.pending[0].text, "original queued text");
    assert_eq!(restored.state, RunState::Paused);
    assert!(restored.queue_paused);
    assert!(controller.resume().is_err());
    assert!(controller.retry().is_err());
    provider.assert_quiet().await;

    // Cancel restores the original queued text; the rewrite was never sent.
    controller
        .resolve_edit("held-edit", "cancelled", None)
        .unwrap();
    workspace
        .save_draft(&chat.id, draft(3, "displaced composer thought"))
        .unwrap();
    assert!(controller.begin_edit(&queued.id, "held-edit").is_err());
    assert!(controller.snapshot().edit.is_none());
    assert_eq!(controller.snapshot().pending[0].text, queued.text);
    assert!(controller.snapshot().queue_paused);
    provider.assert_quiet().await;
    shutdown(&controller).await;
    drop((controller, workspace));
    let workspace = reopen_workspace(&path, dir.path());
    assert_eq!(
        workspace.snapshot().drafts[&chat.id],
        draft(3, "displaced composer thought")
    );
    let restored = SessionStore::open(&chat.snapshot).unwrap().snapshot();
    assert_eq!(restored.pending[0].id, queued.id);
    assert!(restored.edit.is_none());
    assert!(
        restored
            .outcomes
            .iter()
            .any(|o| o.edit_id == "held-edit" && o.outcome == "cancelled")
    );
    assert!(restored.queue_paused);
    provider.finish().await;
}

#[test]
fn submission_receipt_and_draft_clear_persist_together_without_overwriting_newer_input() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workspace.json");
    let mut workspace = WorkspaceStore::open(&path, dir.path()).unwrap();
    let chat = ChatRecord {
        tool_mode: Default::default(),
        connection_id: None,
        materialization: bello_agent_core::workspace::ChatMaterialization::CheckpointRequired,
        sidebar_order: None,
        pinned_at: None,
        archived_at: None,
        topic_id: None,
        topic_revision: 0,
        id: Uuid::new_v4().to_string(),
        title: "Chat".into(),
        snapshot: dir.path().join("chat.json"),
    };
    workspace
        .register(chat.clone(), draft(8, "captured text"))
        .unwrap();
    let first = intent(&chat, 8, "captured text");
    workspace.begin_submission(first.clone()).unwrap();
    drop(workspace);
    let mut workspace = reopen_workspace(&path, dir.path());
    assert_eq!(workspace.snapshot().drafts[&chat.id], draft(9, ""));
    assert_eq!(
        workspace.snapshot().intents[&first.id].text,
        "captured text"
    );
    assert_eq!(workspace.snapshot().intents[&first.id].draft_revision, 8);
    assert_eq!(workspace.snapshot().intents[&first.id].lane, Lane::FollowUp);
    let revision = workspace.snapshot().revision;
    assert!(
        !workspace
            .save_draft(&chat.id, draft(8, "late debounce"))
            .unwrap()
    );
    assert!(
        !workspace
            .save_draft(&chat.id, draft(9, "same revision cannot resurrect input"))
            .unwrap()
    );
    assert_eq!(workspace.snapshot().revision, revision);
    workspace
        .save_draft(&chat.id, draft(10, "newer typing"))
        .unwrap();
    let second = intent(&chat, 8, "captured text");
    workspace.begin_submission(second.clone()).unwrap();
    assert_eq!(
        workspace.snapshot().drafts[&chat.id],
        draft(10, "newer typing")
    );
    // A draft debounce may persist this exact receipt before dispatch prepares
    // it, so replay must succeed without clearing newer typing or duplicating it.
    let before_replay = workspace.snapshot();
    workspace.begin_submission(first.clone()).unwrap();
    assert_eq!(workspace.snapshot().drafts, before_replay.drafts);
    assert_eq!(workspace.snapshot().intents, before_replay.intents);
    let mut conflict = first.clone();
    conflict.text = "different text for the same receipt".into();
    let revision = workspace.snapshot().revision;
    assert!(workspace.begin_submission(conflict).is_err());
    assert_eq!(workspace.snapshot().revision, revision);
    let mut conflict = first.clone();
    conflict.lane = Lane::Steering;
    assert!(workspace.begin_submission(conflict).is_err());
    assert_eq!(workspace.snapshot().drafts, before_replay.drafts);
    assert_eq!(workspace.snapshot().intents, before_replay.intents);
    // Invalid receipts must roll back both the clear and intent insertion.
    let mut invalid = intent(&chat, 10, "newer typing");
    invalid.id = "not-a-uuid".into();
    let revision = workspace.snapshot().revision;
    assert!(workspace.begin_submission(invalid).is_err());
    assert_eq!(workspace.snapshot().revision, revision);
    assert_eq!(
        workspace.snapshot().drafts[&chat.id],
        draft(10, "newer typing")
    );
    workspace.acknowledge_submission(&first.id).unwrap();
    drop(workspace);
    let mut workspace = reopen_workspace(&path, dir.path());
    assert!(!workspace.snapshot().intents.contains_key(&first.id));
    assert!(workspace.snapshot().intents.contains_key(&second.id));
    workspace
        .withdraw_submission(&second.id, draft(9, "obsolete restore"))
        .unwrap();
    assert_eq!(
        workspace.snapshot().drafts[&chat.id],
        draft(10, "newer typing")
    );
    assert!(workspace.snapshot().intents.is_empty());
    drop(workspace);
    let workspace = reopen_workspace(&path, dir.path());
    assert_eq!(
        workspace.snapshot().drafts[&chat.id],
        draft(10, "newer typing")
    );
    assert!(workspace.snapshot().intents.is_empty());
}

#[test]
fn submitted_receipt_cannot_clear_a_held_edit_or_a_different_same_revision_draft() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workspace.json");
    let mut workspace = WorkspaceStore::open(&path, dir.path()).unwrap();
    let chat = ChatRecord {
        tool_mode: Default::default(),
        connection_id: None,
        materialization: bello_agent_core::workspace::ChatMaterialization::CheckpointRequired,
        sidebar_order: None,
        pinned_at: None,
        archived_at: None,
        topic_id: None,
        topic_revision: 0,
        id: Uuid::new_v4().to_string(),
        title: "Held chat".into(),
        snapshot: dir.path().join("chat.json"),
    };
    let held = DraftRecord {
        skills: Vec::new(),
        attachments: Vec::new(),
        revision: 6,
        text: "displaced composer".into(),
        queued_edit: Some(QueuedDraft {
            edit_id: "still-held".into(),
            turn_id: Uuid::new_v4().to_string(),
            rewrite: "queued rewrite".into(),
            original_text: Some("original queued text".into()),
        }),
    };
    workspace.register(chat.clone(), held.clone()).unwrap();
    let pending = intent(&chat, 6, "displaced composer");
    workspace.begin_submission(pending.clone()).unwrap();
    drop(workspace);
    let mut workspace = reopen_workspace(&path, dir.path());
    assert_eq!(workspace.snapshot().drafts[&chat.id], held);
    assert_eq!(
        workspace.snapshot().intents[&pending.id].text,
        "displaced composer"
    );
    workspace.acknowledge_submission(&pending.id).unwrap();

    workspace
        .save_draft(&chat.id, draft(7, "current text"))
        .unwrap();
    let mismatched = intent(&chat, 7, "different captured text");
    workspace.begin_submission(mismatched.clone()).unwrap();
    assert_eq!(
        workspace.snapshot().drafts[&chat.id],
        draft(7, "current text")
    );
    workspace
        .withdraw_submission(&mismatched.id, draft(6, "stale restore"))
        .unwrap();
    // Repeated stale cancellation must not recreate an already removed receipt.
    workspace
        .withdraw_submission(&mismatched.id, draft(100, "duplicate restore"))
        .unwrap();
    drop(workspace);
    let workspace = reopen_workspace(&path, dir.path());
    assert_eq!(
        workspace.snapshot().drafts[&chat.id],
        draft(7, "current text")
    );
    assert!(workspace.snapshot().intents.is_empty());
}

#[test]
fn resolved_queue_edit_recovery_preserves_only_unsaved_rewriting_and_is_idempotent() {
    // outcome, saved text, rewrite captured in the draft, original known to old
    // clients, expected composer text after recovering the settled queue command.
    let cases = [
        (
            "saved",
            Some("saved rewrite"),
            "saved rewrite",
            Some("original"),
            "displaced draft",
        ),
        (
            "saved",
            Some("older saved rewrite"),
            "newer unsaved rewrite",
            Some("original"),
            "newer unsaved rewrite\n\ndisplaced draft",
        ),
        (
            "removed",
            None,
            "changed before removal",
            Some("original"),
            "changed before removal\n\ndisplaced draft",
        ),
        (
            "removed",
            None,
            "original",
            Some("original"),
            "displaced draft",
        ),
        (
            "cancelled",
            None,
            "original",
            Some("original"),
            "displaced draft",
        ),
        (
            "cancelled",
            None,
            "unsaved after cancellation",
            Some("original"),
            "unsaved after cancellation\n\ndisplaced draft",
        ),
        (
            "cancelled",
            None,
            "legacy unknown original",
            None,
            "legacy unknown original\n\ndisplaced draft",
        ),
    ];
    for (outcome, saved_text, rewrite, original_text, expected_text) in cases {
        let dir = tempfile::tempdir().unwrap();
        let catalog = dir.path().join("workspace.json");
        let session_path = dir.path().join("session.json");
        let mut session = SessionStore::open(&session_path).unwrap();
        let item = Submission::new("original".into(), Lane::FollowUp);
        session
            .transact(|s| {
                s.submit(item.clone())?;
                s.begin_edit(&item.id, "recover-edit")?;
                Ok(())
            })
            .unwrap();
        let chat = ChatRecord {
            tool_mode: Default::default(),
            connection_id: None,
            materialization: bello_agent_core::workspace::ChatMaterialization::CheckpointRequired,
            sidebar_order: None,
            pinned_at: None,
            archived_at: None,
            topic_id: None,
            topic_revision: 0,
            id: session.snapshot().id,
            title: "Recovery fixture".into(),
            snapshot: session_path.clone(),
        };
        let held = DraftRecord {
            skills: Vec::new(),
            attachments: Vec::new(),
            revision: 11,
            text: "displaced draft".into(),
            queued_edit: Some(QueuedDraft {
                edit_id: "recover-edit".into(),
                turn_id: item.id.clone(),
                rewrite: rewrite.into(),
                original_text: original_text.map(str::to_owned),
            }),
        };
        let mut live = held.clone();
        assert!(
            !live
                .reconcile_queued_status(&session.edit_status("recover-edit").unwrap())
                .unwrap()
        );
        assert_eq!(live, held, "active hold changed for {outcome}");
        let mut workspace = WorkspaceStore::open(&catalog, dir.path()).unwrap();
        workspace.register(chat.clone(), held.clone()).unwrap();
        // The queue operation commits, but a crash precedes the draft update.
        session
            .transact(|s| s.resolve_edit("recover-edit", outcome, saved_text))
            .unwrap();
        drop((session, workspace));

        let restored = SessionStore::open(&session_path).unwrap();
        let snapshot = restored.snapshot();
        assert!(snapshot.edit.is_none());
        if outcome == "removed" {
            assert!(snapshot.pending.is_empty());
        } else {
            assert_eq!(snapshot.pending[0].id, item.id);
            assert_eq!(snapshot.pending[0].text, saved_text.unwrap_or("original"));
        }
        let mut workspace = reopen_workspace(&catalog, dir.path());
        let mut recovered = workspace.snapshot().drafts[&chat.id].clone();
        assert!(
            recovered
                .reconcile_queued_status(&restored.edit_status("recover-edit").unwrap())
                .unwrap()
        );
        assert_eq!(
            recovered,
            draft(12, expected_text),
            "wrong recovery for {outcome}"
        );
        assert!(
            !recovered
                .reconcile_queued_status(&restored.edit_status("recover-edit").unwrap())
                .unwrap()
        );
        assert!(workspace.save_draft(&chat.id, recovered.clone()).unwrap());
        assert!(!workspace.save_draft(&chat.id, held).unwrap());
        drop(workspace);
        let workspace = reopen_workspace(&catalog, dir.path());
        assert_eq!(workspace.snapshot().drafts[&chat.id], recovered);
    }
}

#[test]
fn failed_queue_edit_reconciliation_keeps_the_entire_original_draft() {
    for (revision, text) in [(u64::MAX, "displaced".into()), (5, "x".repeat(262_144))] {
        let mut record = DraftRecord {
            skills: Vec::new(),
            attachments: Vec::new(),
            revision,
            text,
            queued_edit: Some(QueuedDraft {
                edit_id: "unresolved-after-crash".into(),
                turn_id: Uuid::new_v4().to_string(),
                rewrite: "unsaved rewrite".into(),
                original_text: Some("original".into()),
            }),
        };
        let original = record.clone();
        assert!(
            record
                .reconcile_queued_status(
                    &SessionStore::pending()
                        .edit_status("unresolved-after-crash")
                        .unwrap()
                )
                .is_err()
        );
        assert_eq!(
            record, original,
            "failed reconciliation destroyed saved text"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancelled_and_retained_submissions_never_automatically_resubmit_on_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workspace.json");
    let mut provider = Provider::new().await;
    let mut workspace = WorkspaceStore::open(&path, dir.path()).unwrap();
    let controller = provider.controller(SessionStore::pending());
    let chat = register(
        &mut workspace,
        &controller,
        draft(1, "accepted then stopped"),
    );
    let accepted = intent(&chat, 1, "accepted then stopped");
    workspace.begin_submission(accepted.clone()).unwrap();
    controller
        .submit_identified(Submission {
            frozen_skills: Vec::new(),
            attachments: Vec::new(),
            id: accepted.id.clone(),
            text: accepted.text.clone(),
            lane: accepted.lane.clone(),
            model: None,
            effort: None,
        })
        .unwrap();
    let mut request = provider.next().await;
    request.assert_identity(&chat.id, &accepted.id);
    request.delta("stopped output").await;
    await_state(&controller, |s| {
        s.messages
            .last()
            .is_some_and(|m| m.text == "stopped output")
    })
    .await;
    controller
        .submit("queued before stop".into(), Lane::FollowUp)
        .unwrap();
    controller.stop().unwrap();
    await_state(&controller, |s| s.state == RunState::Paused).await;
    shutdown(&controller).await;
    workspace
        .save_draft(&chat.id, draft(3, "retained but never dispatched"))
        .unwrap();
    let retained = intent(&chat, 3, "retained but never dispatched");
    workspace.begin_submission(retained.clone()).unwrap();
    let config = controller.configuration();
    // Deliberately leave both receipts present, simulating shutdown between
    // session acceptance and catalog acknowledgment for the first one.
    drop((controller, workspace, request));

    let mut workspace = reopen_workspace(&path, dir.path());
    let controller =
        Controller::with_configuration(SessionStore::open(&chat.snapshot).unwrap(), config)
            .unwrap();
    let restored = controller.snapshot();
    assert_eq!(restored.state, RunState::Paused);
    assert!(restored.queue_paused);
    assert_eq!(
        restored
            .messages
            .iter()
            .filter(|m| m.id == accepted.id)
            .count(),
        1
    );
    assert_eq!(restored.retry.as_ref().unwrap().id, accepted.id);
    assert_eq!(restored.pending.len(), 1);
    assert!(restored.pending.iter().all(|s| s.id != retained.id));
    assert_eq!(workspace.snapshot().intents.len(), 2);
    assert!(
        controller
            .submit_identified(Submission {
                frozen_skills: Vec::new(),
                attachments: Vec::new(),
                id: accepted.id.clone(),
                text: accepted.text.clone(),
                lane: accepted.lane.clone(),
                model: None,
                effort: None,
            })
            .is_err()
    );
    provider.assert_quiet().await;
    workspace.acknowledge_submission(&accepted.id).unwrap();
    workspace
        .withdraw_submission(&retained.id, draft(5, "retained but never dispatched"))
        .unwrap();
    controller
        .submit("newly queued after reopen".into(), Lane::FollowUp)
        .unwrap();
    assert_eq!(controller.snapshot().pending.len(), 2);
    assert!(controller.snapshot().queue_paused);
    provider.assert_quiet().await;
    shutdown(&controller).await;
    drop((controller, workspace));
    let workspace = reopen_workspace(&path, dir.path());
    assert!(workspace.snapshot().intents.is_empty());
    assert_eq!(
        workspace.snapshot().drafts[&chat.id],
        draft(5, "retained but never dispatched")
    );
    let restored = SessionStore::open(&chat.snapshot).unwrap().snapshot();
    assert_eq!(
        restored
            .messages
            .iter()
            .filter(|m| m.id == accepted.id)
            .count(),
        1
    );
    assert_eq!(restored.pending.len(), 2);
    assert!(restored.queue_paused);
    provider.finish().await;
}

#[test]
fn typed_edit_status_reconciliation_preserves_identity_conflicts_and_unknown_rewrites() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = SessionStore::open(dir.path().join("session.json")).unwrap();
    let item = Submission::new("original".into(), Lane::FollowUp);
    store
        .transact(|session| {
            session.submit(item.clone())?;
            session.begin_edit(&item.id, "held")?;
            Ok(())
        })
        .unwrap();
    let controller = Controller::new(store, None).unwrap();
    let mut draft = DraftRecord {
        skills: Vec::new(),
        attachments: Vec::new(),
        revision: 9,
        text: "displaced".into(),
        queued_edit: Some(QueuedDraft {
            edit_id: "held".into(),
            turn_id: "different-turn".into(),
            rewrite: "unsaved rewrite".into(),
            original_text: Some("original".into()),
        }),
    };
    let before = draft.clone();
    assert!(
        draft
            .reconcile_queued_status(&controller.edit_status("held").unwrap())
            .is_err()
    );
    assert_eq!(draft, before);
    assert!(
        draft
            .reconcile_queued_status(&controller.edit_status("different-edit").unwrap())
            .is_err()
    );
    assert_eq!(draft, before);
    draft.queued_edit.as_mut().unwrap().edit_id = "never-granted".into();
    assert!(
        draft
            .reconcile_queued_status(&controller.edit_status("never-granted").unwrap())
            .unwrap()
    );
    assert_eq!(draft.text, "unsaved rewrite\n\ndisplaced");
    assert_eq!(draft.revision, 10);
    assert!(draft.queued_edit.is_none());
    assert_eq!(
        controller.snapshot_shared().edit.as_ref().unwrap().edit_id,
        "held"
    );
}
