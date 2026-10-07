use super::*;
use crate::{
    Lane, Submission,
    project_authority::{
        connections::{ConnectionDraft, SYNTHETIC_KEY},
        synthetic::SyntheticAuthorityControl,
    },
    tool_history::{ToolOutcome, ToolRecord},
    workspace::{DraftRecord, SubmissionIntent},
};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};
const DEADLINE: Duration = Duration::from_secs(5);
struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    authority: ProjectAuthority,
    control: SyntheticAuthorityControl,
    workspace: Arc<Mutex<WorkspaceStore>>,
    factory: SavedRuntimeFactory,
    connection: String,
}
impl Fixture {
    fn new(endpoint: &str) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap().join("project");
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("visible.txt"), "kept file").unwrap();
        let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
        let profile = serde_json::from_value(json!({"id":uuid::Uuid::new_v4().to_string(),"api":"openai-responses","providerId":"litellm","baseUrl":endpoint,"modelId":"fixture-model","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
        let mut draft = ConnectionDraft::new(profile, "Fixture connection".into());
        draft.key_input = SYNTHETIC_KEY.into();
        let saved = authority
            .save_connection(&authority.load_connections().unwrap(), &draft)
            .unwrap();
        let connection = saved.profile.profile.id;
        let mut draft = authority.load().unwrap().edit();
        let project = draft
            .trust_project(&uuid::Uuid::new_v4().to_string(), &root, &[])
            .unwrap();
        let saved = authority.save(&mut draft).unwrap();
        let mut workspace =
            WorkspaceStore::open(dir.path().join("state/catalog.json"), &root).unwrap();
        workspace
            .bind_project_identity(authority.confirm_project_binding(&saved, &project).unwrap())
            .unwrap();
        let workspace = Arc::new(Mutex::new(workspace));
        let factory = SavedRuntimeFactory::new(
            authority.clone(),
            workspace.clone(),
            SavedChatOptions {
                home: root.clone(),
                read_only_capabilities: vec![Capability::Ls],
                editing_capabilities: vec![Capability::Ls],
                instructions: "Explicit fixture instructions".into(),
            },
        );
        Self {
            _dir: dir,
            root,
            authority,
            control,
            workspace,
            factory,
            connection,
        }
    }
    fn pending(&self) -> (ChatRecord, Arc<Controller>) {
        self.factory
            .new_chat(&self.connection, ChatToolMode::ReadOnly)
            .unwrap()
    }
    fn registered(&self) -> (ChatRecord, Arc<Controller>) {
        let (record, actor) = self.pending();
        self.workspace
            .lock()
            .unwrap()
            .register(record.clone(), DraftRecord::default())
            .unwrap();
        (record, actor)
    }
    fn prepare(&self, record: &ChatRecord, actor: &Arc<Controller>, text: &str) -> Submission {
        let item = Submission::new(text.into(), Lane::FollowUp);
        let intent = SubmissionIntent {
            skills: Vec::new(),
            attachments: Vec::new(),
            id: item.id.clone(),
            chat_id: record.id.clone(),
            text: text.into(),
            lane: item.lane.clone(),
            draft_revision: 0,
        };
        let mut workspace = self.workspace.lock().unwrap();
        workspace
            .register(record.clone(), DraftRecord::default())
            .unwrap();
        workspace.begin_submission(intent).unwrap();
        drop(workspace);
        actor.materialize(&record.snapshot).unwrap();
        item
    }
    fn current(&self, id: &str) -> ChatRecord {
        self.workspace
            .lock()
            .unwrap()
            .snapshot()
            .chats
            .into_iter()
            .find(|r| r.id == id)
            .unwrap()
    }
    fn change(&self, f: impl FnOnce(&mut Value)) {
        let bytes = self.control.snapshot_bytes().unwrap().unwrap();
        let original: std::collections::BTreeMap<String, Box<serde_json::value::RawValue>> =
            serde_json::from_slice(&bytes).unwrap();
        let mut value: Value = serde_json::from_slice(&bytes).unwrap();
        f(&mut value);
        let mut changed: std::collections::BTreeMap<String, Box<serde_json::value::RawValue>> =
            serde_json::from_slice(&serde_json::to_vec(&value).unwrap()).unwrap();
        // Project-only fixture edits preserve exact opaque connection entries,
        // just like a real ProjectDraft save, so connection CAS is not the cause.
        changed.insert("profiles".into(), original["profiles"].clone());
        self.control
            .replace_bytes(Some(serde_json::to_vec(&changed).unwrap()))
            .unwrap();
    }
}
struct Request {
    body: Value,
    socket: TcpStream,
}
impl Request {
    async fn accept(listener: &TcpListener) -> Self {
        timeout(DEADLINE, async {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut raw = vec![];
            loop {
                let mut buf = [0; 4096];
                let n = socket.read(&mut buf).await.unwrap();
                assert!(n > 0);
                raw.extend_from_slice(&buf[..n]);
                if let Some(end) = raw.windows(4).position(|s| s == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&raw[..end]).to_lowercase();
                    let len: usize = headers
                        .lines()
                        .find_map(|line| line.strip_prefix("content-length: "))
                        .unwrap()
                        .parse()
                        .unwrap();
                    if raw.len() >= end + 4 + len {
                        return Self {
                            body: serde_json::from_slice(&raw[end + 4..end + 4 + len]).unwrap(),
                            socket,
                        };
                    }
                }
            }
        })
        .await
        .unwrap()
    }
    async fn respond(mut self, output: Value) {
        let body = json!({"status":"completed","output":output}).to_string();
        self.socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).as_bytes()).await.unwrap();
    }
    async fn complete(self, text: &str) {
        self.respond(json!([{"type":"message","content":[{"type":"output_text","text":text}]}]))
            .await;
    }
    async fn call(self, name: &str, args: Value) {
        self.respond(json!([{"type":"function_call","call_id":"fixture-call","name":name,"arguments":args.to_string()}])).await;
    }
}
async fn listener() -> (TcpListener, String) {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", l.local_addr().unwrap());
    (l, url)
}
async fn settled(actor: &Arc<Controller>) {
    timeout(DEADLINE, async {
        loop {
            if !actor.test_has_active_worker() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn settings_trust_new_and_reopened_pending_chats_send_nothing() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    let (record, actor) = f.registered();
    assert!(!record.snapshot.exists());
    assert!(
        actor
            .submit("not materialized".into(), Lane::FollowUp)
            .is_err()
    );
    assert!(actor.materialize(&record.snapshot).is_err());
    assert!(actor.materialize(&f.root.join("foreign.json")).is_err());
    actor.retire_and_wait().await.unwrap();
    assert!(actor.is_never_materialized());
    let reopened = f.factory.open_registered(&record).unwrap();
    assert!(reopened.configured());
    assert!(!reopened.is_persistent());
    assert!(!record.snapshot.exists());
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    reopened.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn one_factory_sends_tools_persists_results_and_reopens_without_execution() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    let (record, actor) = f.pending();
    let item = f.prepare(&record, &actor, "list fixture");
    actor.submit_identified(item).unwrap();
    let request = Request::accept(&listener).await;
    assert_eq!(request.body["tools"][0]["name"], "ls");
    request.call("ls", json!({})).await;
    let request = Request::accept(&listener).await;
    assert!(
        request.body["input"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["type"] == "function_call_output"
                && v["output"].as_str().unwrap_or("").contains("visible.txt"))
    );
    request.complete("listed").await;
    settled(&actor).await;
    assert!(actor.snapshot().messages.iter().any(|m|matches!(&m.tool_record,Some(ToolRecord::Result(r)) if r.outcome==ToolOutcome::Completed)));
    actor.retire_and_wait().await.unwrap();
    assert!(!actor.is_never_materialized());
    let reopened = f.factory.open_registered(&f.current(&record.id)).unwrap();
    assert_eq!(
        reopened.snapshot().messages.len(),
        actor.snapshot().messages.len()
    );
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    reopened.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn same_route_settings_change_does_not_revoke_project_and_keeps_active_configuration() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    let (record, actor) = f.pending();
    let item = f.prepare(&record, &actor, "first");
    actor.submit_identified(item).unwrap();
    let request = Request::accept(&listener).await;
    let before = actor.prepare_context("").unwrap();
    let loaded = f.authority.load_connections().unwrap();
    let mut draft = loaded.edit(&f.connection).unwrap();
    draft.profile.output_cap = Some(77);
    draft.name = "renamed".into();
    let saved = f.authority.save_connection(&loaded, &draft).unwrap();
    assert!(!saved.forked);
    assert!(
        !actor
            .configure(f.factory.configuration_for(&f.connection).unwrap())
            .unwrap()
    );
    request.call("ls", json!({})).await;
    let continuation = Request::accept(&listener).await;
    assert_ne!(continuation.body["max_output_tokens"], 77);
    continuation.complete("first done").await;
    settled(&actor).await;
    assert!(!actor.context_preview_is_current(&before));
    assert!(!actor.settings_pending());
    actor.submit("second".into(), Lane::FollowUp).unwrap();
    let second = Request::accept(&listener).await;
    assert_eq!(second.body["max_output_tokens"], 77);
    second.complete("second done").await;
    settled(&actor).await;
    actor.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn deletion_during_provider_request_blocks_returned_tool_and_keeps_truthful_result() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    let (record, actor) = f.pending();
    let item = f.prepare(&record, &actor, "list");
    actor.submit_identified(item).unwrap();
    let request = Request::accept(&listener).await;
    f.authority
        .delete_connection(&f.authority.load_connections().unwrap(), &f.connection)
        .unwrap();
    request.call("ls", json!({})).await;
    settled(&actor).await;
    assert!(actor.snapshot().messages.iter().any(|m|matches!(&m.tool_record,Some(ToolRecord::Result(r)) if r.outcome==ToolOutcome::NotExecuted)));
    assert!(actor.submit("no fallback".into(), Lane::FollowUp).is_err());
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    actor.retire_and_wait().await.unwrap();
    assert!(f.factory.open_registered(&f.current(&record.id)).is_err());
}
#[tokio::test]
async fn trust_roots_future_policy_and_catalog_mode_fail_sticky_without_sending() {
    for kind in ["trust", "roots", "policy", "mode"] {
        let f = Fixture::new("http://127.0.0.1:9");
        let (record, actor) = f.pending();
        f.prepare(&record, &actor, "retained");
        let original = f.control.snapshot_bytes().unwrap();
        match kind {
            "trust" => f.change(|v| v["workspaces"][0]["trusted"] = false.into()),
            "roots" => f.change(|v| v["workspaces"][0]["paths"] = json!([f.root])),
            "policy" => f.change(|v| v["workspaces"][0]["futurePolicy"] = json!({"allow":true})),
            _ => {
                f.workspace
                    .lock()
                    .unwrap()
                    .enable_editing_after_confirmation(&record.id)
                    .unwrap();
            }
        }
        assert!(
            actor
                .submit("must remain unsent".into(), Lane::FollowUp)
                .is_err(),
            "{kind}"
        );
        f.control.replace_bytes(original).unwrap();
        assert!(actor.prepare_context("").is_err());
        assert!(actor.resume().is_err());
        actor.retire_and_wait().await.unwrap();
    }
}
#[tokio::test]
async fn receipt_transition_crash_requires_checkpoint_and_preserves_text() {
    let f = Fixture::new("http://127.0.0.1:9");
    let (record, actor) = f.registered();
    let item = Submission::new("recover this exact text".into(), Lane::FollowUp);
    f.workspace
        .lock()
        .unwrap()
        .begin_submission(SubmissionIntent {
            skills: Vec::new(),
            attachments: Vec::new(),
            id: item.id.clone(),
            chat_id: record.id.clone(),
            text: item.text.clone(),
            lane: item.lane,
            draft_revision: 0,
        })
        .unwrap();
    let current = f.current(&record.id);
    assert_eq!(
        current.materialization,
        ChatMaterialization::CheckpointRequired
    );
    actor.retire_and_wait().await.unwrap();
    assert!(f.factory.open_registered(&current).is_err());
    assert!(f.factory.open_registered(&record).is_err());
    assert!(!record.snapshot.exists());
    assert!(!record.snapshot.with_extension("lock").exists());
    assert_eq!(
        f.workspace.lock().unwrap().snapshot().intents[&item.id].text,
        item.text
    );
}
#[tokio::test]
async fn pending_unexpected_checkpoint_and_wrong_existing_identity_never_mutate_bytes() {
    for pending in [true, false] {
        let f = Fixture::new("http://127.0.0.1:9");
        let (record, actor) = f.registered();
        actor.retire_and_wait().await.unwrap();
        let mut foreign = if pending {
            SessionStore::pending_with_id(&record.id).unwrap()
        } else {
            SessionStore::pending()
        };
        foreign.persist_to(&record.snapshot).unwrap();
        drop(foreign);
        let checkpoint = std::fs::read(&record.snapshot).unwrap();
        let lock = std::fs::read(record.snapshot.with_extension("lock")).unwrap();
        let mut target = record.clone();
        if !pending {
            f.workspace
                .lock()
                .unwrap()
                .begin_submission(SubmissionIntent {
                    skills: Vec::new(),
                    attachments: Vec::new(),
                    id: uuid::Uuid::new_v4().to_string(),
                    chat_id: record.id.clone(),
                    text: "kept".into(),
                    lane: Lane::FollowUp,
                    draft_revision: 0,
                })
                .unwrap();
            target = f.current(&record.id);
        }
        assert!(f.factory.open_registered(&target).is_err());
        assert_eq!(std::fs::read(&record.snapshot).unwrap(), checkpoint);
        assert_eq!(
            std::fs::read(record.snapshot.with_extension("lock")).unwrap(),
            lock
        );
    }
}
#[tokio::test]
async fn retired_persistent_actor_cannot_be_recast_as_unregistered_pending() {
    let f = Fixture::new("http://127.0.0.1:9");
    let (record, actor) = f.pending();
    f.prepare(&record, &actor, "retained");
    actor.retire_and_wait().await.unwrap();
    assert!(!actor.is_persistent());
    assert!(!actor.is_never_materialized());
    let other = Fixture::new("http://127.0.0.1:9");
    let mut false_record = record;
    false_record.snapshot = other
        .workspace
        .lock()
        .unwrap()
        .chat_path(&false_record.id)
        .unwrap();
    false_record.connection_id = Some(other.connection.clone());
    assert!(other.factory.reopen(&false_record, &actor).is_err());
    assert!(!false_record.snapshot.exists());
}

#[cfg(not(target_os = "macos"))]
#[tokio::test]
async fn queued_mutation_reconfirms_after_shared_workspace_gate() {
    let (listener, url) = listener().await;
    let mut f = Fixture::new(&url);
    f.factory.options.editing_capabilities = vec![Capability::Write];
    f.factory.synthetic_mutations = true;
    let (record, actor) = f
        .factory
        .new_chat(&f.connection, ChatToolMode::Editing)
        .unwrap();
    let gate = f.workspace.lock().unwrap().editing_gate();
    let held = gate.lock_owned().await;
    let item = f.prepare(&record, &actor, "write once");
    actor.submit_identified(item).unwrap();
    let request = Request::accept(&listener).await;
    let confirmations = f.factory.confirmations.load(Ordering::SeqCst);
    request
        .call(
            "write",
            json!({"path":"must-not-exist.txt","content":"not authorized after revocation"}),
        )
        .await;
    // A successful pre-batch full confirmation has finished; the held gate
    // prevents the per-invocation confirmation from passing until released.
    timeout(DEADLINE, async {
        while f.factory.confirmations.load(Ordering::SeqCst) <= confirmations {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    f.change(|v| v["workspaces"][0]["trusted"] = false.into());
    drop(held);
    settled(&actor).await;
    assert!(!f.root.join("must-not-exist.txt").exists());
    assert!(actor.snapshot().messages.iter().any(|m|matches!(&m.tool_record,Some(ToolRecord::Result(r)) if r.outcome==ToolOutcome::NotExecuted)));
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    actor.retire_and_wait().await.unwrap();
}
async fn compaction_actor(f: &Fixture, listener: &TcpListener) -> (ChatRecord, Arc<Controller>) {
    let (record, actor) = f.pending();
    let item = f.prepare(&record, &actor, &"Objective constraints. ".repeat(1700));
    actor.submit_identified(item).unwrap();
    Request::accept(listener)
        .await
        .complete(&"Verified progress evidence. ".repeat(1700))
        .await;
    settled(&actor).await;
    (record, actor)
}
#[tokio::test]
async fn compaction_revalidates_trust_before_summary_dispatch() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    let (_record, actor) = compaction_actor(&f, &listener).await;
    let original = actor.snapshot().messages;
    let gate = f.control.pause_next_read().unwrap();
    let copy = actor.clone();
    let admitted = std::thread::spawn(move || copy.compact(None));
    assert!(gate.wait_until_started(DEADLINE));
    f.change(|v| v["workspaces"][0]["trusted"] = false.into());
    gate.release();
    admitted.join().unwrap().unwrap();
    settled(&actor).await;
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    assert_eq!(
        actor.snapshot().compaction.as_ref().unwrap().phase,
        crate::compaction::Phase::Failed
    );
    assert_eq!(
        crate::compaction::active_context(&actor.snapshot().messages)
            .unwrap()
            .len(),
        original.len()
    );
    actor.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn compaction_revalidates_trust_after_summary_before_checkpoint_adoption() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    let (_record, actor) = compaction_actor(&f, &listener).await;
    let original = actor.snapshot().messages;
    actor.compact(None).unwrap();
    let request = Request::accept(&listener).await;
    assert_eq!(request.body["tool_choice"], "none");
    f.change(|v| v["workspaces"][0]["trusted"] = false.into());
    request
        .complete("Objective retained. Continue with next step.")
        .await;
    settled(&actor).await;
    assert_eq!(
        actor.snapshot().compaction.as_ref().unwrap().phase,
        crate::compaction::Phase::Failed
    );
    assert_eq!(
        crate::compaction::active_context(&actor.snapshot().messages)
            .unwrap()
            .len(),
        original.len()
    );
    assert!(actor.prepare_context("").is_err());
    actor.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn connection_deleted_during_delayed_open_never_acquires_or_recovers_writer() {
    let f = Fixture::new("http://127.0.0.1:9");
    let (record, actor) = f.pending();
    f.prepare(&record, &actor, "retained");
    actor.retire_and_wait().await.unwrap();
    let record = f.current(&record.id);
    let bytes = std::fs::read(&record.snapshot).unwrap();
    let gate = f.control.pause_next_read().unwrap();
    let factory = f.factory.clone();
    let captured = record.clone();
    let opening = std::thread::spawn(move || factory.open_registered(&captured));
    assert!(gate.wait_until_started(DEADLINE));
    f.authority
        .delete_connection(&f.authority.load_connections().unwrap(), &f.connection)
        .unwrap();
    gate.release();
    assert!(opening.join().unwrap().is_err());
    assert_eq!(std::fs::read(&record.snapshot).unwrap(), bytes);
    drop(SessionStore::open_existing_with_id(&record.snapshot, &record.id).unwrap());
}
#[tokio::test]
async fn stale_connection_mode_and_path_records_fail_before_snapshot_open() {
    let f = Fixture::new("http://127.0.0.1:9");
    let (record, actor) = f.pending();
    f.prepare(&record, &actor, "retained");
    actor.retire_and_wait().await.unwrap();
    let current = f.current(&record.id);
    let before = std::fs::read(&current.snapshot).unwrap();
    for kind in ["connection", "mode", "path"] {
        let mut stale = current.clone();
        match kind {
            "connection" => stale.connection_id = Some(uuid::Uuid::new_v4().to_string()),
            "mode" => stale.tool_mode = ChatToolMode::Editing,
            _ => stale.snapshot = f.root.join("not-created.json"),
        }
        assert!(f.factory.open_registered(&stale).is_err(), "{kind}");
        assert_eq!(std::fs::read(&current.snapshot).unwrap(), before);
        assert!(!f.root.join("not-created.json").exists());
    }
}

#[tokio::test]
async fn factory_recovers_dangling_tool_as_unknown_without_reexecution() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    let (record, actor) = f.pending();
    f.prepare(&record, &actor, "retain before crash");
    let profile = actor.profile().unwrap();
    actor.retire_and_wait().await.unwrap();
    let mut store = SessionStore::open_existing_with_id(&record.snapshot, &record.id).unwrap();
    store
        .transact(|session| {
            session.submit(Submission::new("lost tool result".into(), Lane::FollowUp))?;
            session.start_next()?;
            let reply_id = session.active_reply.clone().unwrap();
            session.begin_tools(
                &reply_id,
                &crate::Reply {
                    text: String::new(),
                    reasoning: String::new(),
                    calls: vec![crate::provider::ToolCall {
                        id: "dangling-write".into(),
                        name: "write".into(),
                        arguments: json!({"path":"never-reexecuted.txt","content":"unobserved"}),
                    }],
                    usage: Value::Null,
                    status: "completed".into(),
                    provider_items: vec![],
                },
                &profile,
            )
        })
        .unwrap();
    drop(store);
    let reopened = f.factory.open_registered(&f.current(&record.id)).unwrap();
    assert!(reopened.snapshot().messages.iter().any(
        |m| matches!(&m.tool_record,Some(ToolRecord::Result(r)) if r.outcome==ToolOutcome::Unknown)
    ));
    assert!(!f.root.join("never-reexecuted.txt").exists());
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    reopened.retry().unwrap();
    let request = Request::accept(&listener).await;
    assert!(request.body["input"].as_array().unwrap().iter().any(|row| {
        row["type"] == "function_call_output"
            && row["output"]
                .as_str()
                .unwrap_or("")
                .contains("No automatic replay")
    }));
    request.complete("Historical effect remains unknown").await;
    settled(&reopened).await;
    assert!(!f.root.join("never-reexecuted.txt").exists());
    reopened.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn capability_badge_uses_factory_definitions_and_known_revocation_without_vault_io() {
    let f = Fixture::new("http://127.0.0.1:9");
    let (_record, actor) = f.pending();
    assert!(actor.has_available_tool_definitions());
    f.control
        .fail_next_read(crate::project_authority::AuthorityError::Denied)
        .unwrap();
    assert!(actor.has_available_tool_definitions());
    assert!(matches!(
        f.authority.load(),
        Err(crate::project_authority::AuthorityError::Denied)
    ));
    let disconnected = Controller::new(SessionStore::pending(), None).unwrap();
    assert!(!disconnected.has_available_tool_definitions());
    let config_only = Controller::with_configuration(
        SessionStore::pending(),
        Some(f.factory.configuration_for(&f.connection).unwrap()),
    )
    .unwrap();
    assert!(!config_only.has_available_tool_definitions());
    let suspended = actor.suspend_idle_admission().unwrap();
    assert!(!actor.has_available_tool_definitions());
    drop(suspended);
    assert!(actor.has_available_tool_definitions());
    f.authority
        .delete_connection(&f.authority.load_connections().unwrap(), &f.connection)
        .unwrap();
    assert!(
        actor
            .submit("observe deletion".into(), Lane::FollowUp)
            .is_err()
    );
    assert!(!actor.has_available_tool_definitions());
    actor.retire_and_wait().await.unwrap();
    assert!(!actor.has_available_tool_definitions());
}

#[tokio::test]
async fn completed_saved_runtime_tail_late_stop_or_retirement_preserves_checkpoint_and_explicit_pause()
 {
    use crate::runtime::worker_tail_test_gate as tail;
    for retire in [true, false] {
        for paused in [false, true] {
            let (listener, url) = listener().await;
            let f = Fixture::new(&url);
            let (record, actor) = f.registered();
            let item = f.prepare(&record, &actor, "Complete this turn");
            let (entered, release) = tail::hold(&actor);
            actor.submit_identified(item).unwrap();
            Request::accept(&listener).await.complete("Complete").await;
            timeout(DEADLINE, entered).await.unwrap().unwrap();
            assert_eq!(actor.snapshot_shared().state, crate::RunState::Idle);
            assert!(actor.snapshot_shared().active.is_none());
            if paused {
                tail::set_intentional_pause(&actor);
            }
            let bytes = std::fs::read(&record.snapshot).unwrap();
            let before = actor.snapshot_shared();
            if retire {
                actor.retire().unwrap();
            } else {
                actor.stop().unwrap();
            }
            release.send(()).unwrap();
            tail::wait_done(&actor).await;
            if retire {
                actor.retire_and_wait().await.unwrap();
            }
            let after = actor.snapshot_shared();
            assert_eq!(
                after.state,
                crate::RunState::Idle,
                "late completion-tail cancellation must not invent a stopped run"
            );
            assert_eq!(after.queue_paused, paused);
            assert_eq!(after.error, before.error);
            assert_eq!(after.revision, before.revision);
            assert_eq!(
                std::fs::read(&record.snapshot).unwrap(),
                bytes,
                "completed tail settlement performs no checkpoint write"
            );
            let next = if retire {
                f.factory.open_registered(&f.current(&record.id)).unwrap()
            } else {
                actor.clone()
            };
            next.submit("Explicit next request".into(), Lane::FollowUp)
                .unwrap();
            if paused {
                assert!(!next.test_has_active_worker());
                next.resume().unwrap();
            }
            let request = Request::accept(&listener).await;
            assert!(request.body.to_string().contains("Explicit next request"));
            request.complete("Done").await;
            tail::wait_done(&next).await;
            next.retire_and_wait().await.unwrap();
        }
    }
}

#[tokio::test]
async fn saved_runtime_tail_stop_or_retirement_keeps_accepted_pending_work_paused_until_resume() {
    use crate::runtime::worker_tail_test_gate as tail;
    for retire in [true, false] {
        for held in [false, true] {
            let (listener, url) = listener().await;
            let f = Fixture::new(&url);
            let (record, actor) = f.registered();
            let item = f.prepare(&record, &actor, "Complete first");
            let (entered, release) = tail::hold(&actor);
            actor.submit_identified(item).unwrap();
            Request::accept(&listener).await.complete("Complete").await;
            timeout(DEADLINE, entered).await.unwrap().unwrap();
            actor
                .submit("Accepted while tail waits".into(), Lane::FollowUp)
                .unwrap();
            if held {
                let turn = actor.snapshot_shared().pending[0].id.clone();
                assert_eq!(
                    actor.begin_edit(&turn, "held-tail-edit").unwrap(),
                    "Accepted while tail waits"
                );
            }
            if retire {
                actor.retire().unwrap();
            } else {
                actor.stop().unwrap();
            }
            release.send(()).unwrap();
            tail::wait_done(&actor).await;
            if retire {
                actor.retire_and_wait().await.unwrap();
            }
            let state = actor.snapshot_shared();
            assert_eq!(state.state, crate::RunState::Paused);
            assert!(state.queue_paused);
            assert_eq!(state.edit.is_some(), held);
            assert_eq!(state.pending.len(), 1);
            assert_eq!(state.pending[0].text, "Accepted while tail waits");
            let next = if retire {
                f.factory.open_registered(&f.current(&record.id)).unwrap()
            } else {
                actor.clone()
            };
            assert!(!next.test_has_active_worker());
            if held {
                next.resolve_edit("held-tail-edit", "saved", Some("Accepted while tail waits"))
                    .unwrap();
                assert!(next.snapshot_shared().queue_paused);
                assert!(!next.test_has_active_worker());
            }
            next.resume().unwrap();
            let request = Request::accept(&listener).await;
            assert!(
                request
                    .body
                    .to_string()
                    .contains("Accepted while tail waits")
            );
            request.complete("Done").await;
            tail::wait_done(&next).await;
            next.retire_and_wait().await.unwrap();
        }
    }
}

#[tokio::test]
async fn saved_factory_image_receipt_delivery_and_reopen_use_the_normal_trusted_route() {
    let (listener, url) = listener().await;
    let f = Fixture::new(&url);
    let loaded = f.authority.load_connections().unwrap();
    let mut draft = loaded.edit(&f.connection).unwrap();
    draft.profile.input = vec!["text".into(), "image".into()];
    let saved = f.authority.save_connection(&loaded, &draft).unwrap();
    assert!(!saved.forked);
    let (record, actor) = f.pending();
    assert!(actor.supports_image_attachments());
    let source = f.root.join("fixture.gif");
    std::fs::write(&source,b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x01L\x00;").unwrap();
    let mut item = Submission::new(String::new(), Lane::FollowUp);
    item.attachments = vec![crate::attachments::AttachmentRecord::inspect(&source).unwrap()];
    let intent = SubmissionIntent {
        skills: Vec::new(),
        id: item.id.clone(),
        chat_id: record.id.clone(),
        text: item.text.clone(),
        lane: item.lane.clone(),
        draft_revision: 1,
        attachments: item.attachments.clone(),
    };
    {
        let mut catalog = f.workspace.lock().unwrap();
        catalog
            .register(
                record.clone(),
                DraftRecord {
                    skills: Vec::new(),
                    revision: 1,
                    text: String::new(),
                    queued_edit: None,
                    attachments: item.attachments.clone(),
                },
            )
            .unwrap();
        catalog.begin_submission(intent.clone()).unwrap();
    }
    actor.materialize(&record.snapshot).unwrap();
    actor
        .submit_identified_with_attachments(item)
        .await
        .unwrap();
    assert!(actor.submission_intent_status(&intent).unwrap());
    let request = Request::accept(&listener).await;
    let expected = request.body["input"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["role"] == "user")
        .unwrap()["content"]
        .clone();
    assert_eq!(expected[0]["type"], "input_image");
    request.complete("retained").await;
    settled(&actor).await;
    f.workspace
        .lock()
        .unwrap()
        .acknowledge_submission(&intent.id)
        .unwrap();
    actor.retire_and_wait().await.unwrap();
    std::fs::remove_file(source).unwrap();
    let reopened = f.factory.open_registered(&f.current(&record.id)).unwrap();
    reopened.submit("continue".into(), Lane::FollowUp).unwrap();
    let replay = Request::accept(&listener).await;
    assert_eq!(
        replay.body["input"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["role"] == "user")
            .unwrap()["content"],
        expected
    );
    replay.complete("replayed retained bytes").await;
    settled(&reopened).await;
    reopened.retire_and_wait().await.unwrap();
}

#[path = "saved_runtime_skill_tests.rs"]
mod skills;

#[cfg(unix)]
#[path = "bash_saved_runtime_tests.rs"]
mod bash_tests;
