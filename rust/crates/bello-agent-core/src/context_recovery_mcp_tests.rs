//! Real saved-runtime/MCP recovery contracts. Every endpoint is numeric loopback.
use super::*;
use crate::{
    Message,
    context_recovery::Phase,
    mcp::McpManager,
    project_authority::{
        ProjectAuthority, SavedProject,
        connections::{ConnectionDraft, SYNTHETIC_KEY},
    },
    saved_runtime::{SavedChatOptions, SavedRuntimeFactory},
    tool_history::{ToolOutcome, ToolRecord},
    tools::Capability,
    workspace::{ChatRecord, ChatToolMode, DraftRecord, SubmissionIntent, WorkspaceStore},
};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    sync::{Mutex as StdMutex, atomic::AtomicUsize},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};
const DEADLINE: Duration = Duration::from_secs(10);
struct Fixture {
    _dir: tempfile::TempDir,
    authority: ProjectAuthority,
    project: SavedProject,
    workspace: Arc<StdMutex<WorkspaceStore>>,
    factory: SavedRuntimeFactory,
    connection: String,
}
impl Fixture {
    fn new(endpoint: &str, mcp: &str) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("project");
        std::fs::create_dir(&root).unwrap();
        let (authority, _control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
        let profile=serde_json::from_value(json!({"id":uuid::Uuid::new_v4().to_string(),"api":"openai-responses","providerId":"litellm","baseUrl":endpoint,"modelId":"fixture-model","contextWindow":65536,"maxOutputTokens":4096,"input":["text","image"]})).unwrap();
        let mut connection = ConnectionDraft::new(profile, "Fixture".into());
        connection.key_input = SYNTHETIC_KEY.into();
        let connection = authority
            .save_connection(&authority.load_connections().unwrap(), &connection)
            .unwrap()
            .profile
            .profile
            .id;
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
        let loaded = authority.load_mcp(&project).unwrap();
        authority.save_mcp(&loaded,&json!({"servers":{"fixture":{"url":mcp,"allowedTools":["echo"],"timeoutSeconds":1}}}).to_string(),&BTreeMap::new()).unwrap();
        let workspace = Arc::new(StdMutex::new(workspace));
        let factory = SavedRuntimeFactory::new(
            authority.clone(),
            workspace.clone(),
            SavedChatOptions {
                home: root,
                read_only_capabilities: vec![Capability::Ls],
                editing_capabilities: vec![Capability::Ls],
                instructions: String::new(),
            },
        );
        Self {
            _dir: dir,
            authority,
            project,
            workspace,
            factory,
            connection,
        }
    }
    fn manager(&self) -> Arc<McpManager> {
        self.factory.mcp_manager().unwrap()
    }
    fn chat(&self, mode: ChatToolMode) -> (ChatRecord, Arc<Controller>) {
        let (record, actor) = self.factory.new_chat(&self.connection, mode).unwrap();
        self.workspace
            .lock()
            .unwrap()
            .register(record.clone(), DraftRecord::default())
            .unwrap();
        (record, actor)
    }
    fn submit(&self, record: &ChatRecord, actor: &Arc<Controller>, text: &str) {
        let item = Submission::new(text.into(), Lane::FollowUp);
        self.workspace
            .lock()
            .unwrap()
            .begin_submission(SubmissionIntent {
                skills: Vec::new(),
                attachments: Vec::new(),
                id: item.id.clone(),
                chat_id: record.id.clone(),
                text: text.into(),
                lane: item.lane.clone(),
                draft_revision: 0,
            })
            .unwrap();
        actor.materialize(&record.snapshot).unwrap();
        seed_history(actor);
        actor.submit_identified(item).unwrap();
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
                assert!(
                    raw.len() <= 2 * 1024 * 1024,
                    "Fixture request exceeded its bound"
                );
                if let Some(end) = raw.windows(4).position(|b| b == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&raw[..end]).to_ascii_lowercase();
                    let size: usize = headers
                        .lines()
                        .find_map(|l| l.strip_prefix("content-length: "))
                        .unwrap()
                        .parse()
                        .unwrap();
                    if raw.len() >= end + 4 + size {
                        return Request {
                            body: serde_json::from_slice(&raw[end + 4..end + 4 + size]).unwrap(),
                            socket,
                        };
                    }
                }
            }
        })
        .await
        .unwrap()
    }
    async fn raw(mut self, status: u16, kind: &str, body: &str, extra: &str) {
        let response = format!(
            "HTTP/1.1 {status} Fixture\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n{extra}\r\n{body}",
            body.len()
        );
        timeout(DEADLINE, self.socket.write_all(response.as_bytes()))
            .await
            .unwrap()
            .unwrap();
    }
    async fn json(self, result: Value) {
        let body = json!({"jsonrpc":"2.0","id":self.body["id"],"result":result}).to_string();
        self.raw(200, "application/json", &body, "").await;
    }
    async fn provider(self, output: Value) {
        self.raw(
            200,
            "application/json",
            &json!({"status":"completed","output":output}).to_string(),
            "",
        )
        .await;
    }
}

struct Gateway {
    url: String,
    calls: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}
impl Gateway {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/mcp", listener.local_addr().unwrap());
        let calls = Arc::new(AtomicUsize::new(0));
        let count = calls.clone();
        let task = tokio::spawn(async move {
            loop {
                let request = Request::accept(&listener).await;
                match request.body["method"].as_str().unwrap() {
                    "initialize" => request.json(json!({"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"recovery-fixture","version":"1"}})).await,
                    "notifications/initialized" => request.raw(202,"application/json","","").await,
                    "tools/list" => request.json(json!({"tools":[{"name":"echo","inputSchema":{"type":"object"}}]})).await,
                    "tools/call" => {
                        count.fetch_add(1, Ordering::SeqCst);
                        request.json(json!({"content":[{"type":"text","text":"DURABLE_REMOTE_RESULT"}],"isError":false})).await;
                    }
                    method => panic!("Unexpected fixture method {method}"),
                }
            }
        });
        Self { url, calls, task }
    }
}
impl Drop for Gateway {
    fn drop(&mut self) {
        self.task.abort();
    }
}
fn history_row(id: &str, role: &str, text: String) -> Message {
    Message {
        id: id.into(),
        role: role.into(),
        text,
        reasoning: String::new(),
        replay_eligible: true,
        state: "complete".into(),
        usage: Value::Null,
        model: None,
        task_root_id: None,
        user_content: None,
        tool_record: None,
        compaction: None,
    }
}
fn seed_history(actor: &Controller) {
    actor
        .inner
        .lock()
        .unwrap()
        .store
        .transact(|session| {
            session.messages = vec![
                history_row("old-user", "user", "Objective constraints. ".repeat(1600)),
                history_row(
                    "old-answer",
                    "assistant",
                    "Verified progress evidence. ".repeat(1600),
                ),
            ];
            Ok(())
        })
        .unwrap();
}
async fn reject(request: Request) {
    request.raw(200,"application/json", &json!({"error":{"code":"context_length_exceeded","message":"Input exceeds context window"}}).to_string(), "").await;
}
async fn complete(request: Request, text: &str) {
    request
        .provider(json!([{"type":"message","content":[{"type":"output_text","text":text}]}]))
        .await;
}
async fn settled(actor: &Controller) -> Session {
    timeout(DEADLINE, async {
        while actor.worker_active.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }
        drop(actor.inner.lock().unwrap());
        actor.snapshot()
    })
    .await
    .unwrap_or_else(|_| {
        let snapshot = actor.snapshot();
        panic!(
            "Worker did not settle: state={:?}, error={:?}, recovery={:?}",
            snapshot.state, snapshot.error, snapshot.context_recoveries
        );
    })
}
async fn no_request(listener: &TcpListener) {
    assert!(
        timeout(Duration::from_millis(120), listener.accept())
            .await
            .is_err()
    );
}
fn tool_rows(session: &Session) -> Vec<Value> {
    session
        .messages
        .iter()
        .filter(|row| row.tool_record.is_some())
        .map(|row| serde_json::to_value(row).unwrap())
        .collect()
}

#[tokio::test]
async fn completed_mcp_batch_survives_recovery_without_replay_or_ticket_regression() {
    let gateway = Gateway::start().await;
    let provider = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let fixture = Fixture::new(
        &format!("http://{}", provider.local_addr().unwrap()),
        &gateway.url,
    );
    let manager = fixture.manager();
    let (record, actor) = fixture.chat(ChatToolMode::Editing);
    fixture.submit(&record, &actor, "Inspect once and continue");
    let request = Request::accept(&provider).await;
    request.provider(json!([
        {"type":"function_call","call_id":"remote-once","name":"mcp","arguments":json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{}}).to_string()},
        {"type":"function_call","call_id":"native-once","name":"ls","arguments":"{\"path\":\".\"}"}
    ])).await;
    let continuation = Request::accept(&provider).await;
    let outputs: Vec<_> = continuation.body["input"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| item["type"] == "function_call_output")
        .map(|item| item["call_id"].as_str().unwrap())
        .collect();
    assert_eq!(outputs, vec!["remote-once", "native-once"]);
    let before = actor.snapshot();
    let retained = tool_rows(&before);
    assert_eq!(retained.len(), 3);
    let mut ids = vec![];
    for row in &before.messages {
        match &row.tool_record {
            Some(ToolRecord::Assistant(record)) => {
                assert!(record.tool_batch_timing.unwrap().wall_us.is_some())
            }
            Some(ToolRecord::Result(record)) => {
                assert_eq!(record.outcome, ToolOutcome::Completed);
                assert!(record.duration_us.is_some());
                ids.push(record.call_id.as_str());
            }
            None => {}
        }
    }
    assert_eq!(ids, vec!["remote-once", "native-once"]);
    assert_eq!(manager.status().pending_results, 0);
    assert!(!manager.status().outcome_unknown);
    let ledger = fixture
        .workspace
        .lock()
        .unwrap()
        .state_directory()
        .join(format!("mcp-outcomes-{}.json", fixture.project.id));
    let ledger_before = std::fs::read(&ledger).unwrap();
    let persisted: Value =
        serde_json::from_slice(&std::fs::read(&record.snapshot).unwrap()).unwrap();
    assert_eq!(
        persisted["tool_timing"],
        serde_json::to_value(before.tool_timing).unwrap()
    );
    assert!(
        String::from_utf8(std::fs::read(&record.snapshot).unwrap())
            .unwrap()
            .contains("DURABLE_REMOTE_RESULT")
    );
    reject(continuation).await;
    let summary = Request::accept(&provider).await;
    assert_eq!(gateway.calls.load(Ordering::SeqCst), 1);
    assert_eq!(manager.status().pending_results, 0);
    complete(
        summary,
        "Objective retained; remote result already completed. Continue without repeating tools.",
    )
    .await;
    let retry = Request::accept(&provider).await;
    assert_eq!(gateway.calls.load(Ordering::SeqCst), 1);
    complete(retry, "Done after recovery").await;
    let done = settled(&actor).await;
    assert_eq!(done.context_recoveries.len(), 1);
    assert_eq!(done.context_recoveries[0].phase, Phase::Completed);
    assert_eq!(tool_rows(&done), retained);
    assert_eq!(done.tool_timing, before.tool_timing);
    assert_eq!(gateway.calls.load(Ordering::SeqCst), 1);
    assert_eq!(manager.status().pending_results, 0);
    assert!(!manager.status().outcome_unknown);
    assert_eq!(std::fs::read(&ledger).unwrap(), ledger_before);
    no_request(&provider).await;
    timeout(DEADLINE, actor.retire_and_wait())
        .await
        .unwrap()
        .unwrap();
    let reopened = SessionStore::open(&record.snapshot).unwrap().snapshot();
    assert_eq!(tool_rows(&reopened), retained);
    assert_eq!(reopened.tool_timing, before.tool_timing);
    assert_eq!(reopened.context_recoveries[0].phase, Phase::Completed);
}

#[tokio::test]
async fn held_steering_edit_remains_pending_through_saved_chat_recovery() {
    let gateway = Gateway::start().await;
    let provider = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let fixture = Fixture::new(
        &format!("http://{}", provider.local_addr().unwrap()),
        &gateway.url,
    );
    let (record, actor) = fixture.chat(ChatToolMode::Editing);
    fixture.submit(&record, &actor, "Original task");
    reject(Request::accept(&provider).await).await;
    let summary = Request::accept(&provider).await;
    let item = Submission::new("HELD_STEERING_SENTINEL".into(), Lane::Steering);
    let held_id = item.id.clone();
    fixture
        .workspace
        .lock()
        .unwrap()
        .begin_submission(SubmissionIntent {
            skills: Vec::new(),
            attachments: Vec::new(),
            id: item.id.clone(),
            chat_id: record.id.clone(),
            text: item.text.clone(),
            lane: item.lane.clone(),
            draft_revision: 0,
        })
        .unwrap();
    actor.submit_identified(item).unwrap();
    actor.begin_edit(&held_id, "recovery-held-edit").unwrap();
    complete(summary, "Objective retained. Resume the original task.").await;
    let retry = Request::accept(&provider).await;
    assert!(!retry.body.to_string().contains("HELD_STEERING_SENTINEL"));
    complete(retry, "Original task completed").await;
    let done = settled(&actor).await;
    assert_eq!(done.context_recoveries[0].phase, Phase::Completed);
    assert_eq!(done.pending.len(), 1);
    assert_eq!(done.pending[0].id, held_id);
    assert_eq!(done.edit.as_ref().unwrap().edit_id, "recovery-held-edit");
    assert!(done.messages.iter().all(|row| row.id != held_id));
    assert_eq!(gateway.calls.load(Ordering::SeqCst), 0);
    no_request(&provider).await;
    timeout(DEADLINE, actor.retire_and_wait())
        .await
        .unwrap()
        .unwrap();
    let reopened = SessionStore::open(&record.snapshot).unwrap().snapshot();
    assert_eq!(reopened.pending[0].id, held_id);
    assert_eq!(
        reopened.edit.as_ref().unwrap().edit_id,
        "recovery-held-edit"
    );
}

#[tokio::test]
async fn saved_connection_deletion_during_summary_fences_adoption_and_retry() {
    let gateway = Gateway::start().await;
    let provider = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let fixture = Fixture::new(
        &format!("http://{}", provider.local_addr().unwrap()),
        &gateway.url,
    );
    let (record, actor) = fixture.chat(ChatToolMode::Editing);
    fixture.submit(&record, &actor, "Original task");
    reject(Request::accept(&provider).await).await;
    let summary = Request::accept(&provider).await;
    let loaded = fixture.authority.load_connections().unwrap();
    fixture
        .authority
        .delete_connection(&loaded, &fixture.connection)
        .unwrap();
    complete(
        summary,
        "Objective retained. This stale summary must not be adopted.",
    )
    .await;
    let done = tokio::select! {
        done = settled(&actor) => done,
        unexpected = Request::accept(&provider) => {
            panic!("Unexpected provider request after connection deletion: model={}, recovery={:?}", unexpected.body["model"], actor.snapshot().context_recoveries);
        }
    };
    assert_eq!(done.context_recoveries.len(), 1);
    assert_eq!(done.context_recoveries[0].retry_attempts, 0);
    assert_eq!(done.context_recoveries[0].phase, Phase::Failed);
    assert!(done.messages.iter().all(|row| row.compaction.is_none()));
    assert_eq!(gateway.calls.load(Ordering::SeqCst), 0);
    no_request(&provider).await;
    timeout(DEADLINE, actor.retire_and_wait())
        .await
        .unwrap()
        .unwrap();
    let reopened = SessionStore::open(&record.snapshot).unwrap().snapshot();
    assert_eq!(reopened.context_recoveries[0].retry_attempts, 0);
    assert!(reopened.messages.iter().all(|row| row.compaction.is_none()));
}
