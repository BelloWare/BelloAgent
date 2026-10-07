use super::*;
use crate::{
    Controller, Lane, Submission,
    project_authority::{
        ProjectAuthority,
        connections::{ConnectionDraft, SYNTHETIC_KEY},
        synthetic::SyntheticAuthorityControl,
    },
    saved_runtime::{SavedChatOptions, SavedRuntimeFactory},
    tool_history::{ToolOutcome, ToolRecord},
    tools::Capability,
    workspace::{ChatRecord, ChatToolMode, DraftRecord, SubmissionIntent, WorkspaceStore},
};
use std::{
    sync::{
        Mutex as StdMutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};
const DEADLINE: Duration = Duration::from_secs(5);
const IMAGE: &str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aU1EAAAAASUVORK5CYII=";
struct Fixture {
    _dir: tempfile::TempDir,
    authority: ProjectAuthority,
    control: SyntheticAuthorityControl,
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
        let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
        let profile=serde_json::from_value(json!({"id":uuid::Uuid::new_v4().to_string(),"api":"openai-responses","providerId":"litellm","baseUrl":endpoint,"modelId":"fixture-model","contextWindow":32000,"maxOutputTokens":4096,"input":["text","image"]})).unwrap();
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
            control,
            project,
            workspace,
            factory,
            connection,
        }
    }
    fn manager(&self) -> Arc<McpManager> {
        self.factory.mcp_manager().unwrap()
    }
    fn into_directory(self) -> tempfile::TempDir {
        self._dir
    }
    fn second_catalog_factory(&self) -> SavedRuntimeFactory {
        let directory = self.workspace.lock().unwrap().state_directory();
        let mut workspace = WorkspaceStore::open(
            directory.join("alternate.workspace.json"),
            &self.project.path,
        )
        .unwrap();
        workspace
            .bind_project_identity(
                self.authority
                    .confirm_project_binding(&self.authority.load().unwrap(), &self.project)
                    .unwrap(),
            )
            .unwrap();
        SavedRuntimeFactory::new(
            self.authority.clone(),
            Arc::new(StdMutex::new(workspace)),
            self.factory.options_for_mcp_test(),
        )
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
        actor.submit_identified(item).unwrap();
    }
    fn config(&self, value: Value) -> LoadedMcp {
        let old = self.authority.load_mcp(&self.project).unwrap();
        self.authority
            .save_mcp(&old, &value.to_string(), &BTreeMap::new())
            .unwrap()
    }
}
struct Request {
    body: Value,
    headers: String,
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
                            headers,
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
        self.socket.write_all(format!("HTTP/1.1 {status} Fixture\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n{extra}\r\n{body}",body.len()).as_bytes()).await.unwrap();
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
struct ServerFixture {
    url: String,
    requests: Arc<StdMutex<Vec<Value>>>,
    calls: Arc<AtomicUsize>,
    lists: Arc<AtomicUsize>,
    starts: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for ServerFixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl ServerFixture {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/mcp", listener.local_addr().unwrap());
        let requests = Arc::new(StdMutex::new(vec![]));
        let calls = Arc::new(AtomicUsize::new(0));
        let lists = Arc::new(AtomicUsize::new(0));
        let starts = Arc::new(AtomicUsize::new(0));
        let (log, c, l, s) = (
            requests.clone(),
            calls.clone(),
            lists.clone(),
            starts.clone(),
        );
        let task = tokio::spawn(async move {
            let mut expired_once = false;
            loop {
                let request = Request::accept(&listener).await;
                log.lock().unwrap().push(request.body.clone());
                match request.body["method"].as_str().unwrap() {
                    "initialize" => {
                        s.fetch_add(1, Ordering::SeqCst);
                        assert!(!request.headers.contains("mcp-protocol-version:"));
                        let body=json!({"jsonrpc":"2.0","id":request.body["id"],"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":true}}}}).to_string();
                        request
                            .raw(
                                200,
                                "application/json",
                                &body,
                                "Mcp-Session-Id: fixture-session\r\n",
                            )
                            .await;
                    }
                    "notifications/initialized" => {
                        assert!(request.headers.contains("mcp-protocol-version: 2025-11-25"));
                        assert!(request.headers.contains("mcp-session-id: fixture-session"));
                        request.raw(202, "application/json", "", "").await;
                    }
                    "tools/list" => {
                        l.fetch_add(1, Ordering::SeqCst);
                        request.json(json!({"tools":[{"name":"echo","description":"Fixture echo","inputSchema":{"type":"object"}},{"name":"blocked","inputSchema":{"type":"object"}}]})).await;
                    }
                    "tools/call" => {
                        c.fetch_add(1, Ordering::SeqCst);
                        let mode = request.body["params"]["arguments"]["mode"]
                            .as_str()
                            .unwrap_or("")
                            .to_owned();
                        match mode.as_str() {
                            "disconnect"=>drop(request),
                            "500"=>request.raw(500,"application/json","{}","").await,
                            "reject"=>{let body=json!({"jsonrpc":"2.0","id":request.body["id"],"error":{"code":-32602,"message":SYNTHETIC_KEY}}).to_string();request.raw(200,"application/json",&body,"").await;},
                            "expire" if !expired_once=>{expired_once=true;request.raw(404,"application/json","{}","").await;},
                            "wrong-id"=>request.raw(200,"application/json",r#"{"jsonrpc":"2.0","id":"wrong","result":{}}"#,"").await,
                            "malformed"=>request.raw(200,"application/json","{bad","").await,
                            "large"=>request.raw(200,"application/json",&" ".repeat(4*1024*1024+1),"").await,
                            "delay"=>{tokio::time::sleep(Duration::from_millis(150)).await;request.json(json!({"content":[{"type":"text","text":"delayed success"}]})).await;},
                            "timeout"=>{tokio::time::sleep(Duration::from_secs(2)).await;drop(request);},
                            "sse"|"changed"=>{
                                let notice=if mode=="changed" {"data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n"}else{""};
                                let body=format!("id: prime\r\ndata:\r\n\r\n: heartbeat\n\ndata:  \n\n{notice}data: {}\n\n",json!({"jsonrpc":"2.0","id":request.body["id"],"result":{"content":[{"type":"text","text":"échø ✓"}]}}));
                                let mut socket=request.socket;socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n").await.unwrap();
                                for piece in body.as_bytes().chunks(3) { socket.write_all(format!("{:x}\r\n",piece.len()).as_bytes()).await.unwrap();socket.write_all(piece).await.unwrap();socket.write_all(b"\r\n").await.unwrap(); }
                                let _=socket.write_all(b"0\r\n\r\n").await;
                            },
                            "error-content"=>request.json(json!({"content":[{"type":"text","text":"remote failure"},{"type":"image","data":IMAGE,"mimeType":"image/png"},{"type":"audio","mimeType":"audio/wav","data":"YWJj"}],"structuredContent":{"reason":"fixture"},"isError":true})).await,
                            "secret"=>request.json(json!({"content":[{"type":"text","text":format!("Bearer {SYNTHETIC_KEY}")}],"structuredContent":{"secret":SYNTHETIC_KEY}})).await,
                            _=>request.json(json!({"content":[{"type":"text","text":"echo success"}],"isError":false})).await,
                        }
                    }
                    other => panic!("unexpected {other}"),
                }
            }
        });
        Self {
            url,
            requests,
            calls,
            lists,
            starts,
            task,
        }
    }
}
async fn invoke(manager: &McpManager, mode: &str) -> McpResult<Performed> {
    manager
        .perform(
            &json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{"mode":mode}}),
            false,
            CancellationToken::new(),
            || async { Ok(()) },
        )
        .await
}
async fn settle(performed: Performed) {
    if let Some(ticket) = performed.ticket {
        ticket.settle().unwrap();
    }
}

#[tokio::test]
async fn shared_factory_manager_catalog_wrapper_and_explicit_receipts() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = f.manager();
    let other = SavedRuntimeFactory::new(
        f.authority.clone(),
        f.workspace.clone(),
        f.factory.options_for_mcp_test(),
    );
    assert!(Arc::ptr_eq(&manager, &other.mcp_manager().unwrap()));
    let (_, actor) = f.chat(ChatToolMode::ReadOnly);
    assert_eq!(
        actor
            .mcp_definitions_for_test()
            .iter()
            .filter(|d| d.name == "mcp")
            .count(),
        1
    );
    let before = server.calls.load(Ordering::SeqCst);
    let listed = manager
        .list_tools("fixture", CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(listed["tools"].as_array().unwrap().len(), 1);
    assert!(listed["tools"][0].get("inputSchema").is_none());
    let described = manager
        .describe(
            json!([{"server":"fixture","tool":"echo"}]),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(
        described["tools"][0]["schema"]["inputSchema"]["type"],
        "object"
    );
    assert_eq!(server.calls.load(Ordering::SeqCst), before);
    let result = invoke(&manager, "").await.unwrap();
    assert_eq!(result.normalized.content.text(), "echo success");
    assert_eq!(manager.status().pending_results, 1);
    assert!(manager.begin_configuration_change().is_err());
    settle(result).await;
    assert_eq!(manager.status().pending_results, 0);
    assert_eq!(server.lists.load(Ordering::SeqCst), 1);
    assert_eq!(server.starts.load(Ordering::SeqCst), 1);
    actor.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn sse_notifications_expiry_and_known_rejection_never_quarantine() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = f.manager();
    for mode in ["sse", "changed", ""] {
        let result = invoke(&manager, mode).await.unwrap();
        settle(result).await;
    }
    assert_eq!(server.lists.load(Ordering::SeqCst), 2);
    let error = invoke(&manager, "reject").await.err().unwrap();
    assert!(error.not_executed);
    assert!(!error.message.contains(SYNTHETIC_KEY));
    assert!(!manager.status().outcome_unknown);
    settle(invoke(&manager, "expire").await.unwrap()).await;
    assert_eq!(server.starts.load(Ordering::SeqCst), 2);
    assert_eq!(server.calls.load(Ordering::SeqCst), 6);
}
#[tokio::test]
async fn interrupted_and_malformed_results_quarantine_without_retry_until_exact_ack() {
    for mode in [
        "disconnect",
        "500",
        "wrong-id",
        "malformed",
        "large",
        "timeout",
    ] {
        let server = ServerFixture::start().await;
        let f = Fixture::new("http://127.0.0.1:9", &server.url);
        let manager = f.manager();
        assert!(invoke(&manager, mode).await.is_err());
        assert!(manager.status().outcome_unknown, "{mode}");
        assert!(invoke(&manager, "").await.is_err());
        assert_eq!(server.calls.load(Ordering::SeqCst), 1);
        let status = manager.status();
        assert!(manager.acknowledge_unknown("wrong", true).is_err());
        assert!(
            manager
                .acknowledge_unknown(status.unknown_id.as_ref().unwrap(), false)
                .is_err()
        );
        let loaded = f.authority.load_mcp(&f.project).unwrap();
        let (directory, gate) = {
            let workspace = f.workspace.lock().unwrap();
            (workspace.state_directory(), workspace.editing_gate())
        };
        // A restart cannot acquire the outcome writer while any prior owner
        // remains live, even when the workspace catalog itself is different.
        assert!(McpManager::new(loaded.clone(), &directory, gate.clone()).is_err());
        let _directory_owner = f.into_directory();
        drop(manager);
        let reopened = McpManager::new(loaded, &directory, gate).unwrap();
        assert!(reopened.status().outcome_unknown);
        assert_eq!(status.unknown_id, reopened.status().unknown_id);
        reopened
            .acknowledge_unknown(status.unknown_id.as_ref().unwrap(), true)
            .unwrap();
        assert!(!reopened.status().outcome_unknown);
    }
}
#[tokio::test]
async fn dropped_success_receipt_and_marker_faults_survive_restart() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = f.manager();
    let result = invoke(&manager, "").await.unwrap();
    drop(result);
    assert!(manager.status().outcome_unknown);
    let status = manager.status();
    manager
        .acknowledge_unknown(status.unknown_id.as_ref().unwrap(), true)
        .unwrap();
    for fault in [1, 2] {
        manager.ledger.set_fault(fault);
        assert!(invoke(&manager, "").await.is_err());
        assert_eq!(server.calls.load(Ordering::SeqCst), 1);
        assert!(manager.status().outcome_unknown);
        manager.ledger.set_fault(0);
        let status = manager.status();
        manager
            .acknowledge_unknown(status.unknown_id.as_ref().unwrap(), true)
            .unwrap();
    }
}
#[tokio::test]
async fn invoke_wait_cancel_and_postgate_authority_recheck_are_not_dispatched() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = f.manager();
    let gate = f.workspace.lock().unwrap().editing_gate();
    let held = gate.lock().await;
    let cancel = CancellationToken::new();
    let token = cancel.clone();
    let m = manager.clone();
    let task = tokio::spawn(async move {
        m.perform(
            &json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{}}),
            false,
            token,
            || async { Ok(()) },
        )
        .await
    });
    tokio::task::yield_now().await;
    cancel.cancel();
    assert!(task.await.unwrap().err().unwrap().not_executed);
    drop(held);
    assert!(!manager.status().outcome_unknown);
    assert_eq!(server.calls.load(Ordering::SeqCst), 0);
    let result = manager
        .perform(
            &json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{}}),
            false,
            CancellationToken::new(),
            || async { Err(invalid("revoked")) },
        )
        .await;
    assert!(result.err().unwrap().not_executed);
    assert_eq!(server.starts.load(Ordering::SeqCst), 0);
}
#[tokio::test]
async fn read_only_unknown_tool_and_invalid_actions_send_no_invocations() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = f.manager();
    let invoke = json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{}});
    assert!(
        manager
            .perform(&invoke, true, CancellationToken::new(), || async { Ok(()) })
            .await
            .err()
            .unwrap()
            .not_executed
    );
    for params in [
        json!([]),
        json!({"action":"invoke","server":"fixture","tool":"blocked","arguments":{}}),
        json!({"action":"invoke","server":"fixture","tool":"echo","arguments":[]}),
        json!({"action":"describe","targets":[]}),
        json!({"action":"list","secret":"extra"}),
    ] {
        assert!(
            manager
                .perform(&params, false, CancellationToken::new(), || async {
                    Ok(())
                })
                .await
                .is_err()
        );
    }
    assert_eq!(server.calls.load(Ordering::SeqCst), 0);
    assert!(!manager.status().outcome_unknown);
}
#[tokio::test]
async fn inspector_requires_current_editing_and_retains_one_canonical_receipt() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let (_, read) = f.chat(ChatToolMode::ReadOnly);
    assert!(
        read.mcp_invoke_once(
            "fixture".into(),
            "echo".into(),
            json!({}),
            true,
            CancellationToken::new()
        )
        .await
        .is_err()
    );
    assert_eq!(server.calls.load(Ordering::SeqCst), 0);
    let (_, edit) = f.chat(ChatToolMode::Editing);
    assert!(
        edit.mcp_invoke_once(
            "fixture".into(),
            "echo".into(),
            json!({}),
            false,
            CancellationToken::new()
        )
        .await
        .is_err()
    );
    let result = edit
        .mcp_invoke_once(
            "fixture".into(),
            "echo".into(),
            json!({"mode":"error-content"}),
            true,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(result["isError"], true);
    assert!(result.to_string().contains("Structured content:"));
    assert!(result.to_string().contains("audio/wav result, 3 bytes"));
    assert!(!result.to_string().contains("YWJj"));
    let manager = f.manager();
    assert!(!manager.status().outcome_unknown);
    assert_eq!(manager.status().pending_results, 0);
    let bytes = std::fs::read(manager.ledger.receipt_path()).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains(SYNTHETIC_KEY));
    read.retire_and_wait().await.unwrap();
    edit.retire_and_wait().await.unwrap();
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
async fn actual_controller_wrapper_failed_images_structured_replay_and_reopen() {
    let mcp = ServerFixture::start().await;
    let provider = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let f = Fixture::new(
        &format!("http://{}", provider.local_addr().unwrap()),
        &mcp.url,
    );
    let (record, actor) = f.chat(ChatToolMode::Editing);
    f.submit(&record, &actor, "MCP fixture");
    let request = Request::accept(&provider).await;
    assert_eq!(
        request.body["tools"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|v| v["name"] == "mcp")
            .count(),
        1
    );
    assert!(
        !request.body["tools"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["name"] == "echo")
    );
    request.provider(json!([{"type":"function_call","call_id":"mcp-fixture","name":"mcp","arguments":json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{"mode":"error-content"}}).to_string()}])).await;
    let continuation = Request::accept(&provider).await;
    let result = continuation.body["input"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["type"] == "function_call_output")
        .unwrap();
    assert!(result["output"].is_array());
    let rendered = result.to_string();
    assert!(rendered.contains("Structured content:"));
    assert!(rendered.contains("remote failure"));
    assert!(rendered.contains("data:image/png;base64,"));
    assert!(!rendered.contains("YWJj"));
    continuation
        .provider(json!([{"type":"message","content":[{"type":"output_text","text":"retained"}]}]))
        .await;
    settled(&actor).await;
    let snapshot = actor.snapshot();
    assert_eq!(snapshot.version, 8);
    // V6 is narrow: only a matching MCP owner can retain an explicit Failed
    // result. It never legitimizes an unknown or mispaired payload.
    for mutation in [
        "native-owner",
        "unknown",
        "error-flag",
        "assistant-id",
        "call-id",
    ] {
        let mut messages = snapshot.messages.clone();
        if mutation == "native-owner" {
            for message in &mut messages {
                if let Some(ToolRecord::Assistant(record)) = &mut message.tool_record {
                    record.calls[0].name = "ls".into();
                    record.provider_items.clear();
                }
            }
        } else {
            let result = messages
                .iter_mut()
                .find_map(|message| match &mut message.tool_record {
                    Some(ToolRecord::Result(result)) => Some(result),
                    _ => None,
                })
                .unwrap();
            match mutation {
                "unknown" => result.outcome = ToolOutcome::Unknown,
                "error-flag" => result.is_error = false,
                "assistant-id" => result.assistant_id = "wrong-owner".into(),
                "call-id" => result.call_id = "wrong-call".into(),
                _ => unreachable!(),
            }
        }
        assert!(
            crate::tool_history::validate(&messages).is_err(),
            "{mutation}"
        );
    }
    let mut older = snapshot.clone();
    older.version = 5;
    let old_bytes = serde_json::to_vec(&older).unwrap();
    let old_path = f._dir.path().join("invalid-v5.json");
    std::fs::write(&old_path, &old_bytes).unwrap();
    assert!(crate::SessionStore::open(&old_path).is_err());
    assert_eq!(std::fs::read(&old_path).unwrap(), old_bytes);
    assert!(snapshot.messages.iter().any(|m|matches!(&m.tool_record,Some(ToolRecord::Result(r)) if r.outcome==ToolOutcome::Failed && r.is_error && r.content.is_some())));
    assert!(!f.manager().status().outcome_unknown);
    actor.retire_and_wait().await.unwrap();
    let saved = f
        .workspace
        .lock()
        .unwrap()
        .snapshot()
        .chats
        .into_iter()
        .find(|r| r.id == record.id)
        .unwrap();
    let reopened = f.factory.open_registered(&saved).unwrap();
    assert_eq!(reopened.snapshot().version, 8);
    assert_eq!(mcp.calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        mcp.requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r["method"] == "tools/call")
            .count(),
        1
    );
    reopened.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn saved_config_apply_is_reserved_exact_and_secret_echo_is_redacted() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = f.manager();
    let lease = manager.begin_configuration_change().unwrap();
    assert!(manager.status().busy);
    assert!(manager.begin_configuration_change().is_err());
    let loaded = f.authority.load_mcp(&f.project).unwrap();
    let mut replacements = BTreeMap::new();
    replacements.insert(
        "fixture".into(),
        json!({"Authorization":format!("Bearer {SYNTHETIC_KEY}")}).to_string(),
    );
    let saved = f
        .authority
        .save_mcp(
            &loaded,
            &loaded.configuration_json_without_headers(),
            &replacements,
        )
        .unwrap();
    assert_eq!(saved.configured_header_servers(), vec!["fixture"]);
    assert!(
        !saved
            .configuration_json_without_headers()
            .contains(SYNTHETIC_KEY)
    );
    lease
        .apply_configuration(saved, CancellationToken::new())
        .await
        .unwrap();
    let result = invoke(&manager, "secret").await.unwrap();
    assert!(!result.normalized.content.text().contains(SYNTHETIC_KEY));
    assert!(result.normalized.content.text().contains("[redacted]"));
    settle(result).await;
    f.config(json!({"servers":{}}));
    assert!(invoke(&manager, "").await.err().unwrap().not_executed);
    assert_eq!(server.calls.load(Ordering::SeqCst), 1);
}
#[tokio::test]
async fn marker_is_not_cleared_when_controller_result_checkpoint_fails() {
    for fault in [1, 2] {
        let mcp = ServerFixture::start().await;
        let provider = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let f = Fixture::new(
            &format!("http://{}", provider.local_addr().unwrap()),
            &mcp.url,
        );
        let (record, actor) = f.chat(ChatToolMode::Editing);
        f.submit(&record, &actor, "fault fixture");
        let request = Request::accept(&provider).await;
        request.provider(json!([{"type":"function_call","call_id":"fault-call","name":"mcp","arguments":json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{"mode":"delay"}}).to_string()}])).await;
        timeout(DEADLINE, async {
            while mcp.calls.load(Ordering::SeqCst) == 0 {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .unwrap();
        actor.mcp_checkpoint_fault_for_test(fault);
        settled(&actor).await;
        assert!(f.manager().status().outcome_unknown);
        assert_eq!(mcp.calls.load(Ordering::SeqCst), 1);
        actor.mcp_checkpoint_fault_for_test(0);
        actor.retire_and_wait().await.unwrap();
        let record = f
            .workspace
            .lock()
            .unwrap()
            .snapshot()
            .chats
            .into_iter()
            .find(|r| r.id == record.id)
            .unwrap();
        let reopened = f.factory.open_registered(&record).unwrap();
        assert_eq!(mcp.calls.load(Ordering::SeqCst), 1);
        let expected = if fault == 1 {
            ToolOutcome::Unknown
        } else {
            ToolOutcome::Completed
        };
        assert!(
            reopened.snapshot().messages.iter().any(
                |m| matches!(&m.tool_record,Some(ToolRecord::Result(r)) if r.outcome==expected)
            )
        );
        assert!(f.manager().status().outcome_unknown);
        reopened.retire_and_wait().await.unwrap();
    }
}
#[tokio::test]
async fn inspector_stop_and_retirement_join_dispatched_unknown_but_waiting_is_not_executed() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let (_, actor) = f.chat(ChatToolMode::Editing);
    let running = actor.clone();
    let task = tokio::spawn(async move {
        running
            .mcp_invoke_once(
                "fixture".into(),
                "echo".into(),
                json!({"mode":"timeout"}),
                true,
                CancellationToken::new(),
            )
            .await
    });
    timeout(DEADLINE, async {
        while server.calls.load(Ordering::SeqCst) == 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
    timeout(DEADLINE, actor.retire_and_wait())
        .await
        .unwrap()
        .unwrap();
    assert!(task.await.unwrap().is_err());
    assert!(f.manager().status().outcome_unknown);
    assert_eq!(server.calls.load(Ordering::SeqCst), 1);
}
#[test]
fn vault_config_validation_preservation_destination_and_cas() {
    let f = Fixture::new("http://127.0.0.1:9", "http://127.0.0.1:9/mcp");
    let loaded = f.authority.load_mcp(&f.project).unwrap();
    for config in [
        r#"{"servers":{"a":{"transport":"stdio","command":"anything"}}}"#,
        r#"{"servers":{"a":{"url":"https://example.invalid/mcp"}}}"#,
        r#"{"servers":{"a":{"url":"http://localhost/mcp"}}}"#,
        r#"{"servers":{"a":{"url":"http://127.0.0.1/mcp?secret=x"}}}"#,
        r#"{"servers":{"a":{"url":"http://127.0.0.1/mcp","headers":{}}}}"#,
        r#"{"servers":{"a":{"url":"http://127.0.0.1/mcp","enabled":1}}}"#,
        r#"{"servers":{"a":{"url":"http://127.0.0.1/mcp","timeoutSeconds":0}}}"#,
        r#"{"servers":{"a":{"url":"http://127.0.0.1/mcp","url":"http://127.0.0.1/other"}}}"#,
    ] {
        assert!(
            f.authority
                .save_mcp(&loaded, config, &BTreeMap::new())
                .is_err(),
            "{config}"
        );
    }
    let mut headers = BTreeMap::new();
    headers.insert(
        "fixture".into(),
        json!({"x-fixture":SYNTHETIC_KEY}).to_string(),
    );
    let saved = f
        .authority
        .save_mcp(
            &loaded,
            &loaded.configuration_json_without_headers(),
            &headers,
        )
        .unwrap();
    assert!(
        f.authority
            .save_mcp(
                &loaded,
                &loaded.configuration_json_without_headers(),
                &headers
            )
            .is_err()
    );
    let saved = f
        .authority
        .save_mcp(
            &saved,
            &saved.configuration_json_without_headers(),
            &BTreeMap::new(),
        )
        .unwrap();
    assert_eq!(saved.configured_header_servers(), vec!["fixture"]);
    let moved = json!({"servers":{"fixture":{"url":"http://127.0.0.1:10/mcp"}}}).to_string();
    assert!(
        f.authority
            .save_mcp(&saved, &moved, &BTreeMap::new())
            .is_err()
    );
    headers.insert("fixture".into(), "{}".into());
    let cleared = f.authority.save_mcp(&saved, &moved, &headers).unwrap();
    assert!(cleared.configured_header_servers().is_empty());
    let before = f.control.snapshot_bytes().unwrap().unwrap();
    let mut raw: BTreeMap<String, Box<serde_json::value::RawValue>> =
        serde_json::from_slice(&before).unwrap();
    raw.insert(
        "future".into(),
        serde_json::value::RawValue::from_string(
            r#"{ "n": 123456789012345678901234567890, "s":"\u0061" }"#.into(),
        )
        .unwrap(),
    );
    f.control
        .replace_bytes(Some(serde_json::to_vec(&raw).unwrap()))
        .unwrap();
    let future = raw["future"].get().to_owned();
    let current = f.authority.load_mcp(&f.project).unwrap();
    f.authority
        .save_mcp(
            &current,
            &current.configuration_json_without_headers(),
            &BTreeMap::new(),
        )
        .unwrap();
    let raw: BTreeMap<String, Box<serde_json::value::RawValue>> =
        serde_json::from_slice(&f.control.snapshot_bytes().unwrap().unwrap()).unwrap();
    assert_eq!(raw["future"].get(), future);
}
#[tokio::test]
async fn catalog_schema_cursor_duplicate_and_page_types_fail_closed() {
    for pages in [
        vec![json!({"tools":[{"name":"echo"}]})],
        vec![json!({"tools":[{"name":"echo","inputSchema":{}},{"name":"echo","inputSchema":{}}]})],
        vec![json!({"tools":"not an array"})],
        vec![json!({"tools":[],"nextCursor":7})],
        vec![
            json!({"tools":[],"nextCursor":"repeat"}),
            json!({"tools":[],"nextCursor":"repeat"}),
        ],
    ] {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let f = Fixture::new(
            "http://127.0.0.1:9",
            &format!("http://{}/mcp", listener.local_addr().unwrap()),
        );
        let manager = f.manager();
        let m = manager.clone();
        let task =
            tokio::spawn(async move { m.list_tools("fixture", CancellationToken::new()).await });
        let hello = Request::accept(&listener).await;
        assert_eq!(hello.body["method"], "initialize");
        hello
            .json(json!({"protocolVersion":"2025-06-18","capabilities":{"tools":{}}}))
            .await;
        let initialized = Request::accept(&listener).await;
        assert!(
            initialized
                .headers
                .contains("mcp-protocol-version: 2025-06-18")
        );
        initialized.raw(202, "application/json", "", "").await;
        for page in pages {
            let list = Request::accept(&listener).await;
            assert_eq!(list.body["method"], "tools/list");
            list.json(page).await;
        }
        assert!(task.await.unwrap().is_err());
        assert!(!manager.status().outcome_unknown);
    }
}
#[tokio::test]
async fn redirect_is_not_followed_and_unknown_cannot_be_cleared_by_config_removal() {
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let f = Fixture::new(
        "http://127.0.0.1:9",
        &format!("http://{}/mcp", listener.local_addr().unwrap()),
    );
    let manager = f.manager();
    let m = manager.clone();
    let task = tokio::spawn(async move { invoke(&m, "").await });
    Request::accept(&listener)
        .await
        .json(json!({"protocolVersion":"2025-11-25","capabilities":{"tools":{}}}))
        .await;
    Request::accept(&listener)
        .await
        .raw(202, "application/json", "", "")
        .await;
    Request::accept(&listener)
        .await
        .json(json!({"tools":[{"name":"echo","inputSchema":{}}]}))
        .await;
    Request::accept(&listener)
        .await
        .raw(
            307,
            "application/json",
            "",
            &format!(
                "Location: http://{}/other\r\n",
                target.local_addr().unwrap()
            ),
        )
        .await;
    assert!(!task.await.unwrap().err().unwrap().not_executed);
    assert!(
        timeout(Duration::from_millis(50), target.accept())
            .await
            .is_err()
    );
    let unknown = manager.status().unknown_id;
    let lease = manager.begin_configuration_change().unwrap();
    let loaded = f.config(json!({"servers":{}}));
    lease
        .apply_configuration(loaded, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(manager.status().unknown_id, unknown);
    assert!(manager.status().outcome_unknown);
}
#[tokio::test]
async fn configured_proxy_environment_is_ignored_in_disposable_child() {
    if std::env::var_os("BELLO_MCP_PROXY_CHILD").is_some() {
        return;
    }
    let server = ServerFixture::start().await;
    let proxy = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy_url = format!("http://{}", proxy.local_addr().unwrap());
    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "mcp::tests::proxy_child", "--nocapture"])
        .env("BELLO_MCP_PROXY_CHILD", &server.url)
        .env("HTTP_PROXY", &proxy_url)
        .env("http_proxy", &proxy_url)
        .env("HTTPS_PROXY", &proxy_url)
        .env("https_proxy", &proxy_url)
        .env("ALL_PROXY", &proxy_url)
        .env("all_proxy", &proxy_url)
        .env("NO_PROXY", "")
        .env("no_proxy", "")
        .spawn()
        .unwrap();
    let status = tokio::task::spawn_blocking(move || child.wait().unwrap())
        .await
        .unwrap();
    assert!(status.success());
    assert_eq!(server.calls.load(Ordering::SeqCst), 1);
    assert!(
        timeout(Duration::from_millis(50), proxy.accept())
            .await
            .is_err()
    );
}
#[tokio::test]
async fn proxy_child() {
    let Ok(url) = std::env::var("BELLO_MCP_PROXY_CHILD") else {
        return;
    };
    let f = Fixture::new("http://127.0.0.1:9", &url);
    settle(invoke(&f.manager(), "").await.unwrap()).await;
}
#[test]
fn explicit_content_normalization_never_dumps_unsupported_payloads() {
    let normalized=content::normalize(json!({"content":[{"type":"audio","data":"YWJj","mimeType":"audio/wav"},{"type":"resource","resource":{"text":"embedded secret not in description","blob":"YWJj"}},{"type":"image","data":"not-base64","mimeType":"image/png"}],"structuredContent":{"typed":42},"isError":true}),&[]).unwrap();
    let text = normalized.content.text();
    assert!(text.contains("audio/wav result, 3 bytes"));
    assert!(text.contains("[resource result]"));
    assert!(text.contains("Image omitted"));
    assert!(text.contains("Structured content:"));
    assert!(!text.contains("YWJj"));
    assert!(!text.contains("embedded secret"));
    assert!(normalized.is_error);
    assert!(content::normalize(json!({"content":{},"isError":false}), &[]).is_err());
    assert!(content::normalize(json!({"isError":"false"}), &[]).is_err());
}
#[tokio::test]
async fn multiple_mcp_calls_in_one_controller_batch_settle_only_their_receipts() {
    let server = ServerFixture::start().await;
    let provider = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let f = Fixture::new(
        &format!("http://{}", provider.local_addr().unwrap()),
        &server.url,
    );
    let (record, actor) = f.chat(ChatToolMode::Editing);
    f.submit(&record, &actor, "two calls");
    let request = Request::accept(&provider).await;
    let args =
        json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{}}).to_string();
    request.provider(json!([{"type":"function_call","call_id":"first","name":"mcp","arguments":args},{"type":"function_call","call_id":"second","name":"mcp","arguments":args}])).await;
    let continuation = Request::accept(&provider).await;
    assert_eq!(
        continuation.body["input"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|v| v["type"] == "function_call_output")
            .count(),
        2
    );
    assert_eq!(server.calls.load(Ordering::SeqCst), 2);
    assert_eq!(f.manager().status().pending_results, 0);
    assert!(!f.manager().status().outcome_unknown);
    continuation
        .provider(
            json!([{"type":"message","content":[{"type":"output_text","text":"both settled"}]}]),
        )
        .await;
    settled(&actor).await;
    actor.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn second_chat_cancelled_behind_first_invocation_never_dispatches_or_quarantines() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let (_, first) = f.chat(ChatToolMode::Editing);
    let (_, second) = f.chat(ChatToolMode::Editing);
    let first_copy = first.clone();
    let one = tokio::spawn(async move {
        first_copy
            .mcp_invoke_once(
                "fixture".into(),
                "echo".into(),
                json!({"mode":"delay"}),
                true,
                CancellationToken::new(),
            )
            .await
    });
    timeout(DEADLINE, async {
        while server.calls.load(Ordering::SeqCst) == 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
    let token = CancellationToken::new();
    let cancel = token.clone();
    let second_copy = second.clone();
    let two = tokio::spawn(async move {
        second_copy
            .mcp_invoke_once("fixture".into(), "echo".into(), json!({}), true, cancel)
            .await
    });
    tokio::time::sleep(Duration::from_millis(20)).await;
    assert_eq!(server.calls.load(Ordering::SeqCst), 1);
    token.cancel();
    assert!(
        two.await
            .unwrap()
            .unwrap_err()
            .to_string()
            .contains("Not executed")
    );
    assert!(one.await.unwrap().is_ok());
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert_eq!(server.calls.load(Ordering::SeqCst), 1);
    assert!(!f.manager().status().outcome_unknown);
    first.retire_and_wait().await.unwrap();
    second.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn abandoned_inspector_waiter_still_joins_and_releases_guard_without_dispatch() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let (_, actor) = f.chat(ChatToolMode::Editing);
    let gate = f.workspace.lock().unwrap().editing_gate();
    let held = gate.lock().await;
    let copy = actor.clone();
    let task = tokio::spawn(async move {
        copy.mcp_invoke_once(
            "fixture".into(),
            "echo".into(),
            json!({}),
            true,
            CancellationToken::new(),
        )
        .await
    });
    tokio::time::sleep(Duration::from_millis(20)).await;
    task.abort();
    assert!(task.await.is_err());
    timeout(DEADLINE, actor.retire_and_wait())
        .await
        .unwrap()
        .unwrap();
    drop(held);
    assert_eq!(server.calls.load(Ordering::SeqCst), 0);
    assert!(!f.manager().status().outcome_unknown);
}
#[tokio::test]
async fn latest_inspector_result_reopens_without_clearing_later_unknown_evidence() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let (_, actor) = f.chat(ChatToolMode::Editing);
    let manager = f.manager();
    assert!(
        manager
            .latest_result(CancellationToken::new())
            .await
            .unwrap()
            .is_none()
    );
    actor
        .mcp_invoke_once(
            "fixture".into(),
            "echo".into(),
            json!({}),
            true,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let prior = manager
        .latest_result(CancellationToken::new())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(prior["server"], "fixture");
    assert_eq!(prior["tool"], "echo");
    assert_eq!(prior["outcomeUnknown"], false);
    assert!(
        actor
            .mcp_invoke_once(
                "fixture".into(),
                "echo".into(),
                json!({"mode":"disconnect"}),
                true,
                CancellationToken::new()
            )
            .await
            .is_err()
    );
    let unknown = manager.status().unknown_id.clone();
    let recovered = manager
        .latest_result(CancellationToken::new())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(recovered["result"], prior["result"]);
    assert_eq!(recovered["outcomeUnknown"], true);
    assert_eq!(manager.status().unknown_id, unknown);
    assert_eq!(server.calls.load(Ordering::SeqCst), 2);
    let (directory, gate) = {
        let workspace = f.workspace.lock().unwrap();
        (workspace.state_directory(), workspace.editing_gate())
    };
    let loaded = f.authority.load_mcp(&f.project).unwrap();
    actor.retire_and_wait().await.unwrap();
    drop(actor);
    let _directory_owner = f.into_directory();
    drop(manager);
    let reopened = McpManager::new(loaded, &directory, gate).unwrap();
    assert_eq!(
        reopened
            .latest_result(CancellationToken::new())
            .await
            .unwrap()
            .unwrap()["invocation"],
        prior["invocation"]
    );
    assert_eq!(reopened.status().unknown_id, unknown);
    assert_eq!(server.calls.load(Ordering::SeqCst), 2);
}
#[tokio::test]
async fn inspector_receipt_and_marker_settlement_crash_cuts_are_distinct() {
    for receipt_failure in [false, true] {
        for fault in [1, 2] {
            let server = ServerFixture::start().await;
            let f = Fixture::new("http://127.0.0.1:9", &server.url);
            let manager = f.manager();
            let (_, actor) = f.chat(ChatToolMode::Editing);
            let copy = actor.clone();
            let task = tokio::spawn(async move {
                copy.mcp_invoke_once(
                    "fixture".into(),
                    "echo".into(),
                    json!({"mode":"delay"}),
                    true,
                    CancellationToken::new(),
                )
                .await
            });
            timeout(DEADLINE, async {
                while server.calls.load(Ordering::SeqCst) == 0 {
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
            })
            .await
            .unwrap();
            if receipt_failure {
                manager.ledger.set_receipt_fault(fault);
            } else {
                manager.ledger.set_fault(fault);
            }
            assert!(task.await.unwrap().is_err());
            assert!(manager.status().outcome_unknown);
            let unknown = manager.status().unknown_id.clone();
            let receipt = manager
                .latest_result(CancellationToken::new())
                .await
                .unwrap();
            assert_eq!(receipt.is_some(), !receipt_failure || fault == 2);
            assert_eq!(manager.status().unknown_id, unknown);
            let (directory, gate) = {
                let workspace = f.workspace.lock().unwrap();
                (workspace.state_directory(), workspace.editing_gate())
            };
            let loaded = f.authority.load_mcp(&f.project).unwrap();
            actor.retire_and_wait().await.unwrap();
            drop(actor);
            let _directory_owner = f.into_directory();
            drop(manager);
            let reopened = McpManager::new(loaded, &directory, gate).unwrap();
            // Only a positively durable canonical receipt permits a possibly
            // committed empty housekeeping ledger to recover as settled-known.
            assert_eq!(
                reopened.status().outcome_unknown,
                receipt_failure || fault == 1
            );
            assert_eq!(server.calls.load(Ordering::SeqCst), 1);
        }
    }
}
#[tokio::test]
async fn status_never_blocks_ui_behind_held_durable_ledger_lock() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = f.manager();
    assert!(invoke(&manager, "disconnect").await.is_err());
    let expected = manager.status().unknown_id;
    let (started, ready) = std::sync::mpsc::channel();
    let (release, wait) = std::sync::mpsc::channel();
    let ledger = manager.ledger.clone();
    let worker = std::thread::spawn(move || ledger.hold_write_lock_for_test(started, wait));
    ready.recv_timeout(Duration::from_secs(1)).unwrap();
    let (sent, received) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || sent.send(manager.status()).unwrap());
    let result = received.recv_timeout(Duration::from_millis(200));
    // Always release the simulated fsync lock before either join or assertion,
    // so the old blocking implementation fails promptly rather than hanging.
    release.send(()).unwrap();
    worker.join().unwrap();
    reader.join().unwrap();
    let status = result.expect("status must not wait for durable ledger I/O");
    assert!(status.outcome_unknown);
    assert_eq!(status.unknown_id, expected);
}

async fn invoke_during_status_read(manager: &McpManager) -> McpResult<Performed> {
    use std::task::Poll;

    let mut invocation = Box::pin(invoke(manager, "ok"));
    // Suspend another presentation reader while it owns the cached snapshot.
    // The action must consult durable outcome state, not interpret contention
    // with this harmless read as evidence of an earlier unknown invocation.
    let first_poll = futures_util::future::poll_fn(|cx| {
        Poll::Ready(
            manager
                .ledger
                .during_status_read_for_test(|| invocation.as_mut().poll(cx)),
        )
    })
    .await;
    match first_poll {
        Poll::Ready(result) => result,
        Poll::Pending => timeout(DEADLINE, invocation).await.unwrap(),
    }
}

#[tokio::test]
async fn concurrent_status_reader_cannot_invent_an_unknown_invocation_outcome() {
    let server = ServerFixture::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    assert!(!manager.status().outcome_unknown);
    let performed = invoke_during_status_read(&manager)
        .await
        .expect("an idle presentation reader must not reject an authorized invocation");
    settle(performed).await;
    assert_eq!(server.calls.load(Ordering::SeqCst), 1);
    assert!(!manager.status().outcome_unknown);

    assert!(invoke(&manager, "disconnect").await.is_err());
    let unknown_id = manager.status().unknown_id.unwrap();
    let rejected = invoke_during_status_read(&manager)
        .await
        .err()
        .expect("a genuine unknown outcome must still block invocation");
    assert_eq!(rejected.code, "mcp_outcome_unknown");
    assert!(rejected.not_executed);
    assert_eq!(server.calls.load(Ordering::SeqCst), 2);
    assert_eq!(
        manager.status().unknown_id.as_deref(),
        Some(unknown_id.as_str())
    );
}

#[tokio::test]
async fn cancellation_during_authoritative_outcome_read_never_dispatches() {
    use std::task::Poll;

    let server = ServerFixture::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    let (started, ready) = std::sync::mpsc::channel();
    let (release, wait) = std::sync::mpsc::channel();
    let ledger = manager.ledger.clone();
    let writer = std::thread::spawn(move || ledger.hold_write_lock_for_test(started, wait));
    ready.recv_timeout(Duration::from_secs(1)).unwrap();
    let cancel = CancellationToken::new();
    let parameters = json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{}});
    let mut invocation =
        Box::pin(manager.perform(&parameters, false, cancel.clone(), || async { Ok(()) }));
    let pending =
        futures_util::future::poll_fn(|cx| Poll::Ready(invocation.as_mut().poll(cx).is_pending()))
            .await;
    cancel.cancel();
    let cancelled = timeout(Duration::from_secs(1), invocation).await;
    // Release the simulated fsync even if cancellation regresses, before
    // asserting, so the test cannot strand the pool worker or writer lease.
    release.send(()).unwrap();
    writer.join().unwrap();
    assert!(pending);
    let error = cancelled
        .expect("cancellation must not wait behind durable outcome I/O")
        .err()
        .expect("a cancelled outcome read must not authorize dispatch");
    assert_eq!(error.code, "mcp_cancelled");
    assert!(error.not_executed);
    assert_eq!(server.calls.load(Ordering::SeqCst), 0);
    assert!(!manager.status().outcome_unknown);
}

#[tokio::test]
async fn unavailable_outcome_evidence_cannot_borrow_a_known_presentation() {
    let server = ServerFixture::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    let ledger = manager.ledger.clone();
    assert!(
        std::thread::spawn(move || ledger.poison_state_for_test())
            .join()
            .is_err()
    );
    // A cached known result is only presentation. Unavailable authoritative
    // evidence must not grant an invocation or fabricate a new unknown marker.
    assert!(!manager.status().outcome_unknown);
    let error = invoke(&manager, "ok")
        .await
        .err()
        .expect("unavailable outcome evidence must fail closed");
    assert_eq!(error.code, "mcp_outcome_unavailable");
    assert!(error.not_executed);
    assert!(error.message.starts_with("Not executed:"));
    assert_eq!(server.calls.load(Ordering::SeqCst), 0);
    assert!(!manager.status().outcome_unknown);
}
#[tokio::test]
async fn allowlist_absent_empty_and_explicit_list_are_distinct_and_null_is_rejected() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = f.manager();
    for (allowlist, count) in [(None, 2), (Some(json!([])), 0), (Some(json!(["echo"])), 1)] {
        let mut config = json!({"servers":{"fixture":{"url":server.url}}});
        if let Some(value) = allowlist {
            config["servers"]["fixture"]["allowedTools"] = value;
        }
        let lease = manager.begin_configuration_change().unwrap();
        let loaded = f.config(config);
        lease
            .apply_configuration(loaded, CancellationToken::new())
            .await
            .unwrap();
        let listed = manager
            .list_tools("fixture", CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(listed["tools"].as_array().unwrap().len(), count);
    }
    let loaded = f.authority.load_mcp(&f.project).unwrap();
    let before = f.control.snapshot_bytes().unwrap();
    for value in [
        Value::Null,
        json!(false),
        json!(7),
        json!("echo"),
        json!({}),
        json!([7]),
    ] {
        let config = json!({"servers":{"fixture":{"url":server.url,"allowedTools":value}}});
        assert_eq!(
            f.authority
                .save_mcp(&loaded, &config.to_string(), &BTreeMap::new())
                .err(),
            Some(crate::project_authority::AuthorityError::InvalidMcp)
        );
        assert_eq!(f.control.snapshot_bytes().unwrap(), before);
    }
    assert_eq!(server.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn concurrent_first_factories_reuse_one_workspace_manager() {
    let f = Fixture::new("http://127.0.0.1:9", "http://127.0.0.1:9/mcp");
    let start = Arc::new(std::sync::Barrier::new(9));
    let workers: Vec<_> = (0..8)
        .map(|_| {
            let factory = SavedRuntimeFactory::new(
                f.authority.clone(),
                f.workspace.clone(),
                f.factory.options_for_mcp_test(),
            );
            let start = start.clone();
            std::thread::spawn(move || {
                start.wait();
                factory.mcp_manager().unwrap()
            })
        })
        .collect();
    start.wait();
    let managers: Vec<_> = workers
        .into_iter()
        .map(|worker| worker.join().unwrap())
        .collect();
    for manager in &managers {
        assert!(Arc::ptr_eq(manager, &managers[0]));
    }
    assert!(Arc::ptr_eq(&f.manager(), &managers[0]));
}

#[tokio::test]
async fn distinct_catalogs_share_one_outcome_writer_until_last_ticket_drops() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = f.manager();
    // Both independent catalog locks succeed. Their project outcome file is
    // nevertheless the same, so only one manager can own it.
    let second = f.second_catalog_factory();
    let performed = invoke(&manager, "").await.unwrap();
    let marker = f
        .workspace
        .lock()
        .unwrap()
        .state_directory()
        .join(format!("mcp-outcomes-{}.json", f.project.id));
    let before = std::fs::read(&marker).unwrap();
    let requests = server.requests.lock().unwrap().len();
    for _ in 0..2 {
        let error = second
            .mcp_manager()
            .err()
            .expect("different catalog must be excluded");
        assert!(error.to_string().contains("already open elsewhere"));
        assert_eq!(std::fs::read(&marker).unwrap(), before);
    }
    let _directory_owner = f.into_directory();
    // A bare public manager remains the writer after its factory/workspace drop.
    assert!(second.mcp_manager().is_err());
    assert_eq!(manager.status().pending_results, 1);
    drop(manager);
    // A late result ticket retains writer ownership even without a manager.
    assert!(second.mcp_manager().is_err());
    assert_eq!(std::fs::read(&marker).unwrap(), before);
    drop(performed);
    let recovered = second.mcp_manager().unwrap();
    assert!(recovered.status().outcome_unknown);
    assert!(invoke(&recovered, "").await.err().unwrap().not_executed);
    assert_eq!(server.requests.lock().unwrap().len(), requests);
    assert_eq!(server.calls.load(Ordering::SeqCst), 1);
    assert_eq!(std::fs::read(&marker).unwrap(), before);
    let unknown = recovered.status().unknown_id.unwrap();
    recovered.acknowledge_unknown(&unknown, true).unwrap();
    assert!(!recovered.status().outcome_unknown);
}

#[tokio::test]
async fn late_ticket_settlement_holds_outcome_writer_after_workspace_drop() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = f.manager();
    let second = f.second_catalog_factory();
    let performed = invoke(&manager, "").await.unwrap();
    let _directory_owner = f.into_directory();
    drop(manager);
    assert!(second.mcp_manager().is_err());
    // Move the last owner across the same blocking-worker boundary used by
    // real checkpoint settlement; no factory/workspace Arc keeps it alive.
    let (started, ready) = std::sync::mpsc::channel();
    let (release, wait) = std::sync::mpsc::channel();
    let (finished, done) = std::sync::mpsc::channel();
    let worker = tokio::task::spawn_blocking(move || {
        started.send(()).unwrap();
        wait.recv_timeout(DEADLINE).unwrap();
        finished.send(performed.ticket.unwrap().settle()).unwrap();
    });
    ready.recv_timeout(DEADLINE).unwrap();
    drop(worker); // Cancellation/dropping the waiter does not stop physical I/O.
    let excluded = second.mcp_manager().is_err();
    release.send(()).unwrap();
    done.recv_timeout(DEADLINE).unwrap().unwrap();
    assert!(excluded);
    let recovered = second.mcp_manager().unwrap();
    assert!(!recovered.status().outcome_unknown);
    assert_eq!(recovered.status().pending_results, 0);
    assert_eq!(server.calls.load(Ordering::SeqCst), 1);
}
#[tokio::test]
async fn same_workspace_root_retrust_rebinds_without_losing_lease_or_quarantine() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let previous = f.manager();
    previous
        .list_tools("fixture", CancellationToken::new())
        .await
        .unwrap();
    drop(previous.ledger.begin("fixture", "echo").unwrap());
    let unknown = previous.status().unknown_id.unwrap();
    let extra = f._dir.path().join("extra-root");
    std::fs::create_dir(&extra).unwrap();
    let mut draft = f.authority.load().unwrap().edit();
    let project = draft
        .trust_project(&f.project.id, &f.project.path, &[extra])
        .unwrap();
    f.authority.save(&mut draft).unwrap();
    let held = previous.gate.clone().lock_owned().await;
    let rebound = f.manager();
    assert!(!Arc::ptr_eq(&previous, &rebound));
    assert!(Arc::ptr_eq(&previous.ledger, &rebound.ledger));
    assert!(Arc::ptr_eq(&previous.gate, &rebound.gate));
    assert!(Arc::ptr_eq(&previous.editing_gate, &rebound.editing_gate));
    assert!(rebound.matches_project(&project));
    assert!(rebound.status().busy);
    assert_eq!(
        rebound.status().unknown_id.as_deref(),
        Some(unknown.as_str())
    );
    drop(held);
    assert!(previous.acknowledge_unknown(&unknown, true).is_err());
    assert!(previous.confirm().await.is_err());
    assert!(invoke(&rebound, "ok").await.is_err());
    assert_eq!(server.calls.load(Ordering::SeqCst), 0);
    rebound.acknowledge_unknown(&unknown, true).unwrap();
    settle(invoke(&rebound, "ok").await.unwrap()).await;
    assert_eq!(server.calls.load(Ordering::SeqCst), 1);
    // The rebound manager initializes fresh transport/catalog state, while the
    // old authority cannot dispatch even though an external Arc still exists.
    assert_eq!(server.starts.load(Ordering::SeqCst), 2);
    assert!(Arc::ptr_eq(&rebound, &f.manager()));
}

#[cfg(unix)]
#[path = "bash_tests.rs"]
mod bash_tests;
