use super::*;
use crate::{LaunchState, connection_settings_controller::LaunchConnectionAuthority};
use bello_agent_core::{
    Profile, SessionStore,
    project_authority::{
        AuthorityError,
        connections::{ConnectionDraft, SYNTHETIC_KEY},
        synthetic::SyntheticAuthorityControl,
    },
    workspace::{ChatRecord, DraftRecord},
};
use gpui::{TestAppContext, WindowHandle};

fn configuration() -> String {
    r#"{"servers":{"fixture":{"transport":"http","url":"http://127.0.0.1:9","timeoutSeconds":1}}}"#
        .into()
}
fn config_draft(configuration: String) -> McpInput {
    let mut input = McpInput::default();
    input.configuration = configuration;
    input
}
fn argument_draft(arguments: String) -> McpInput {
    let mut input = McpInput::default();
    input.arguments = arguments;
    input
}
fn inspector_state(view: &AgentView) -> String {
    format!(
        "presentation={:?}; mode={:?}; configured={}; retired={}; loading={}; load_failed={}; chat_busy={}; mode_pending={}; mode_operations={:?}; mode_blocked={:?}; error={:?}; manager={:?}; configuration_matches={:?}",
        view.mcp.presentation,
        view.record.tool_mode,
        view.controller.configured(),
        view.controller.is_retired(),
        view.loading,
        view.load_failed,
        view.busy,
        view.mcp.mode_pending,
        view.chat_mode_operations,
        view.chat_mode_blocked,
        view.error,
        view.mcp.manager.as_ref().map(|manager| manager.status()),
        view.mcp
            .manager
            .as_ref()
            .zip(view.mcp.loaded.as_ref())
            .map(|(manager, loaded)| manager.configuration_matches(loaded)),
    )
}
#[test]
fn general_configuration_rejects_secret_headers_stdio_and_oversize_without_echo() {
    for config in [
        r#"{"servers":{"fixture":{"headers":{"X-Key":"private-marker"}}}}"#.into(),
        r#"{"servers":{"fixture":{"transport":"stdio","command":"private-marker"}}}"#.into(),
        "private-marker".into(),
        "x".repeat(262_145),
    ] {
        let error = config_input(&config_draft(config)).unwrap_err();
        assert!(!error.contains("private-marker"));
    }
    assert!(config_input(&config_draft(configuration())).is_ok());
}
#[test]
fn one_shot_arguments_are_bounded_objects_and_errors_are_fixed() {
    for args in ["[]", "null", "private-marker"] {
        let error = arguments_input(&argument_draft(args.into())).unwrap_err();
        assert!(!error.contains("private-marker"));
    }
    assert!(arguments_input(&argument_draft("{}".into())).is_ok());
}
fn wait_for(
    root: &Entity<AgentView>,
    cx: &mut TestAppContext,
    predicate: impl Fn(&AgentView) -> bool,
) {
    let end = std::time::Instant::now() + std::time::Duration::from_secs(6);
    loop {
        cx.run_until_parked();
        if cx.read(|cx| predicate(root.read(cx))) {
            return;
        }
        assert!(
            std::time::Instant::now() < end,
            "MCP operation did not settle"
        );
        std::thread::sleep(std::time::Duration::from_millis(3));
    }
}
async fn fixture(
    cx: &mut TestAppContext,
    trusted: bool,
) -> (
    tempfile::TempDir,
    SyntheticAuthorityControl,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
    cx.update(|cx| cx.set_global(LaunchConnectionAuthority(control.clone())));
    let profile:Profile=serde_json::from_value(json!({"id":uuid::Uuid::new_v4().to_string(),"api":"openai-responses","providerId":"litellm","baseUrl":"http://127.0.0.1:9","modelId":"local-test-fixture","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let mut connection = ConnectionDraft::new(profile, "Fixture connection".into());
    connection.key_input = SYNTHETIC_KEY.into();
    let saved = authority
        .save_connection(&authority.load_connections().unwrap(), &connection)
        .unwrap();
    let connection_id = saved.profile.profile.id.clone();
    let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project).unwrap();
    if trusted {
        let mut draft = authority.load().unwrap().edit();
        let saved_project = draft
            .trust_project(&uuid::Uuid::new_v4().to_string(), &project, &[])
            .unwrap();
        let loaded = authority.save(&mut draft).unwrap();
        workspace
            .bind_project_identity(
                authority
                    .confirm_project_binding(&loaded, &saved_project)
                    .unwrap(),
            )
            .unwrap();
    }
    let store = SessionStore::open(project.join("session.json")).unwrap();
    let snapshot = store.snapshot();
    let mut record = ChatRecord::new(
        snapshot.id,
        "MCP test chat".into(),
        project.join("session.json"),
    );
    record.connection_id = Some(connection_id);
    record.tool_mode = ChatToolMode::ReadOnly;
    workspace
        .register(record.clone(), DraftRecord::default())
        .unwrap();
    drop(store);
    let workspace = Arc::new(Mutex::new(workspace));
    let runtime = crate::saved_runtime_adapter::AppRuntime::new(
        authority,
        workspace.clone(),
        crate::saved_runtime_adapter::AppRuntime::options(project.clone(), true),
        None,
    );
    let controller = if trusted {
        runtime.open_registered(&record).unwrap()
    } else {
        Controller::new(
            SessionStore::open_existing_with_id(&record.snapshot, &record.id).unwrap(),
            None,
        )
        .unwrap()
    };
    let launch = LaunchState {
        controller,
        workspace,
        project,
        record,
        draft: DraftRecord {
            attachments: Vec::new(),
            text: "retained composer 日本語".into(),
            ..Default::default()
        },
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    window
        .update(cx, |view, window, cx| view.open_mcp(window, cx))
        .unwrap();
    wait_for(&root, cx, |v| !v.mcp.busy());
    (dir, control, window, root)
}
fn act(window: WindowHandle<AgentView>, intent: McpIntent, cx: &mut TestAppContext) {
    window
        .update(cx, |view, window, cx| {
            let token = view.mcp.view.read(cx).token();
            let input = view.mcp.view.read(cx).input(cx);
            view.mcp_intent(token, intent, input, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
}
fn edit(root: &Entity<AgentView>, text: String, cx: &mut TestAppContext) {
    root.update(cx, |view, cx| {
        view.mcp
            .view
            .update(cx, |v, cx| v.replace_configuration_draft(text, cx))
    });
}
#[gpui::test]
async fn unbound_project_is_explicit_and_cannot_save_or_invoke(cx: &mut TestAppContext) {
    let (_dir, control, window, root) = fixture(cx, false).await;
    let before = control.snapshot_bytes().unwrap();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.mcp.presentation.ready);
        assert!(view.mcp.presentation.project_id.is_none());
        assert!(!view.mcp.presentation.allows(&McpIntent::Invoke));
    });
    act(window, McpIntent::Save, cx);
    assert_eq!(control.snapshot_bytes().unwrap(), before);
}
#[gpui::test]
async fn save_needs_explicit_trust_and_cancel_preserves_the_final_draft(cx: &mut TestAppContext) {
    let (_dir, control, window, root) = fixture(cx, true).await;
    let before = control.snapshot_bytes().unwrap();
    edit(&root, configuration(), cx);
    act(window, McpIntent::Save, cx);
    assert_eq!(control.snapshot_bytes().unwrap(), before);
    cx.read(|cx| assert!(root.read(cx).mcp.presentation.confirmation.is_some()));
    act(window, McpIntent::CancelConfirmation, cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.mcp.view.read(cx).dirty(cx));
        assert_eq!(
            view.mcp.view.read(cx).input(cx).unwrap().configuration,
            configuration()
        );
    });
    assert_eq!(control.snapshot_bytes().unwrap(), before);
}
#[gpui::test]
async fn confirmed_save_applies_exact_revision_preserving_composer_and_saved_id(
    cx: &mut TestAppContext,
) {
    let (_dir, _, window, root) = fixture(cx, true).await;
    let (old, composer, id) = cx.read(|cx| {
        let v = root.read(cx);
        (
            v.controller.clone(),
            v.composer.entity_id(),
            v.record.id.clone(),
        )
    });
    edit(&root, configuration(), cx);
    act(window, McpIntent::Save, cx);
    act(window, McpIntent::Confirm, cx);
    wait_for(&root, cx, |v| !v.mcp.busy());
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.mcp.presentation.notice.contains("saved and applied"));
        assert!(!view.mcp.view.read(cx).dirty(cx));
        assert_eq!(view.record.id, id);
        assert_eq!(view.composer.entity_id(), composer);
        assert_eq!(view.composer.read(cx).text(), "retained composer 日本語");
        assert!(Arc::ptr_eq(&old, &view.controller));
        assert_eq!(view.mcp.presentation.servers, vec!["fixture"]);
    });
    old.reorder(&[]).unwrap();
}
#[gpui::test]
async fn stale_duplicate_and_reopened_confirmation_cannot_save(cx: &mut TestAppContext) {
    let (_dir, control, window, root) = fixture(cx, true).await;
    edit(&root, configuration(), cx);
    let before = control.snapshot_bytes().unwrap();
    act(window, McpIntent::Save, cx);
    let stale = cx.read(|cx| root.read(cx).mcp.view.read(cx).token());
    act(window, McpIntent::CancelConfirmation, cx);
    window
        .update(cx, |view, window, cx| {
            view.mcp_intent(stale, McpIntent::Confirm, None, window, cx);
            view.close_mcp(window, cx);
            view.open_mcp(window, cx);
            view.mcp_intent(stale, McpIntent::Confirm, None, window, cx);
        })
        .unwrap();
    assert_eq!(control.snapshot_bytes().unwrap(), before);
}
#[gpui::test]
async fn denial_and_cas_conflict_keep_draft_without_admission_uncertainty(cx: &mut TestAppContext) {
    for conflict in [false, true] {
        let (_dir, control, window, root) = fixture(cx, true).await;
        edit(&root, configuration(), cx);
        act(window, McpIntent::Save, cx);
        if conflict {
            let mut raw: Value =
                serde_json::from_slice(&control.snapshot_bytes().unwrap().unwrap()).unwrap();
            raw["revision"] = json!(raw["revision"].as_i64().unwrap() + 1);
            control
                .replace_bytes(Some(serde_json::to_vec(&raw).unwrap()))
                .unwrap();
        } else {
            control.fail_next_write(AuthorityError::Denied).unwrap();
        }
        act(window, McpIntent::Confirm, cx);
        wait_for(&root, cx, |v| !v.mcp.busy());
        cx.read(|cx| {
            let v = root.read(cx);
            assert!(v.mcp.view.read(cx).dirty(cx));
            assert!(!v.mcp.admission_blocked);
            v.controller.reorder(&[]).unwrap();
        });
    }
}
#[gpui::test]
async fn unconfirmed_mcp_save_fences_all_chat_actions_and_retains_draft(cx: &mut TestAppContext) {
    let (_dir, control, window, root) = fixture(cx, true).await;
    edit(&root, configuration(), cx);
    act(window, McpIntent::Save, cx);
    control
        .fail_next_write(AuthorityError::Unconfirmed)
        .unwrap();
    act(window, McpIntent::Confirm, cx);
    wait_for(&root, cx, |v| !v.mcp.busy());
    cx.read(|cx| {
        let v = root.read(cx);
        assert!(v.mcp.admission_blocked);
        assert!(v.actor_mutation_blocked(&v.record.id));
        assert!(v.controller.reorder(&[]).is_err());
        assert!(v.mcp.view.read(cx).dirty(cx));
    });
}
#[gpui::test]
async fn close_and_reopen_keeps_configuration_draft_and_never_saves_implicitly(
    cx: &mut TestAppContext,
) {
    let (_dir, control, window, root) = fixture(cx, true).await;
    let before = control.snapshot_bytes().unwrap();
    edit(&root, configuration(), cx);
    act(window, McpIntent::Close, cx);
    cx.read(|cx| assert!(root.read(cx).mcp.presentation.close_confirmation));
    act(window, McpIntent::KeepDraftClose, cx);
    cx.read(|cx| assert!(!root.read(cx).mcp.open));
    window
        .update(cx, |view, window, cx| view.open_mcp(window, cx))
        .unwrap();
    cx.read(|cx| {
        let v = root.read(cx);
        assert!(v.mcp.view.read(cx).dirty(cx));
        assert_eq!(
            v.mcp.view.read(cx).input(cx).unwrap().configuration,
            configuration()
        );
    });
    assert_eq!(control.snapshot_bytes().unwrap(), before);
}
#[gpui::test]
async fn visible_enable_editing_confirmation_uses_existing_retire_persist_reopen(
    cx: &mut TestAppContext,
) {
    let (_dir, _, window, root) = fixture(cx, true).await;
    let (old, composer) = cx.read(|cx| {
        let v = root.read(cx);
        assert!(v.mcp.presentation.can_enable_editing);
        (v.controller.clone(), v.composer.entity_id())
    });
    act(window, McpIntent::EnableEditing, cx);
    act(window, McpIntent::CancelConfirmation, cx);
    cx.read(|cx| assert_eq!(root.read(cx).record.tool_mode, ChatToolMode::ReadOnly));
    act(window, McpIntent::EnableEditing, cx);
    act(window, McpIntent::Confirm, cx);
    wait_for(&root, cx, |v| v.chat_mode_operations.is_empty());
    window.update(cx, |v, _, cx| v.sync_mcp_status(cx)).unwrap();
    cx.read(|cx| {
        let v = root.read(cx);
        assert_eq!(v.record.tool_mode, ChatToolMode::Editing);
        assert!(v.mcp.presentation.editing);
        assert_eq!(v.composer.entity_id(), composer);
        assert_eq!(v.composer.read(cx).text(), "retained composer 日本語");
    });
    assert!(old.is_retired());
    assert!(old.reorder(&[]).is_err());
}
#[gpui::test]
async fn enable_editing_confirmation_is_bound_to_the_captured_controller(cx: &mut TestAppContext) {
    let (_dir, _, window, root) = fixture(cx, true).await;
    act(window, McpIntent::EnableEditing, cx);
    root.update(cx, |view, cx| {
        let replacement = Controller::new(
            SessionStore::pending_with_id(&view.record.id).unwrap(),
            None,
        )
        .unwrap();
        view.chat.replace_controller(replacement, cx);
    });
    act(window, McpIntent::Confirm, cx);
    cx.read(|cx| {
        let v = root.read(cx);
        assert_eq!(v.record.tool_mode, ChatToolMode::ReadOnly);
        assert!(v.chat_mode_operations.is_empty());
        assert!(v.mcp.presentation.notice.contains("changed"));
    });
}

struct Gateway {
    url: String,
    calls: Arc<std::sync::atomic::AtomicUsize>,
    stop: Arc<std::sync::atomic::AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Gateway {
    fn new(disconnect_call: bool) -> Self {
        Self::with_mode(u8::from(disconnect_call))
    }
    fn with_mode(mode: u8) -> Self {
        use std::{
            io::{Read, Write},
            sync::atomic::{AtomicBool, AtomicUsize, Ordering},
            time::Duration,
        };
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}/mcp", listener.local_addr().unwrap());
        let calls = Arc::new(AtomicUsize::new(0));
        let count = calls.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let shutdown = stop.clone();
        let thread = std::thread::spawn(move || {
            while !shutdown.load(Ordering::SeqCst) {
                let (mut stream, _) = match listener.accept() {
                    Ok(v) => v,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(2));
                        continue;
                    }
                    Err(_) => break,
                };
                stream
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut data = Vec::new();
                let mut buffer = [0u8; 4096];
                let mut parsed = None;
                while data.len() < 262_144 {
                    let size = match stream.read(&mut buffer) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    };
                    data.extend_from_slice(&buffer[..size]);
                    if let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                        let headers = String::from_utf8_lossy(&data[..end]);
                        let length = headers
                            .lines()
                            .find_map(|line| {
                                let (k, v) = line.split_once(':')?;
                                k.eq_ignore_ascii_case("content-length")
                                    .then(|| v.trim().parse::<usize>().ok())
                                    .flatten()
                            })
                            .unwrap_or(0);
                        if data.len() >= end + 4 + length {
                            parsed =
                                serde_json::from_slice::<Value>(&data[end + 4..end + 4 + length])
                                    .ok();
                            break;
                        }
                    }
                }
                let Some(request) = parsed else {
                    continue;
                };
                let method = request["method"].as_str().unwrap_or("");
                if method == "notifications/initialized" {
                    let _ = stream.write_all(
                        b"HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    );
                    continue;
                }
                let result = match method {
                    "initialize" => {
                        json!({"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}})
                    }
                    "tools/list" => {
                        json!({"tools":[{"name":"echo","description":"Fixture echo tool","inputSchema":{"type":"object"}}]})
                    }
                    "tools/call" => {
                        count.fetch_add(1, Ordering::SeqCst);
                        if mode == 1 {
                            continue;
                        }
                        if mode == 2 {
                            while !shutdown.load(Ordering::SeqCst) {
                                std::thread::sleep(Duration::from_millis(2));
                            }
                        }
                        json!({"content":[{"type":"text","text":"one-shot fixture result"}],"isError":false})
                    }
                    _ => json!({}),
                };
                let body = serde_json::to_vec(
                    &json!({"jsonrpc":"2.0","id":request["id"],"result":result}),
                )
                .unwrap();
                let header = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(header.as_bytes());
                let _ = stream.write_all(&body);
            }
        });
        Self {
            url,
            calls,
            stop,
            thread: Some(thread),
        }
    }
    fn count(&self) -> usize {
        self.calls.load(std::sync::atomic::Ordering::SeqCst)
    }
}
impl Drop for Gateway {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
    }
}
async fn prepare_gateway(
    window: WindowHandle<AgentView>,
    root: &Entity<AgentView>,
    gateway: &Gateway,
    cx: &mut TestAppContext,
) {
    edit(root,json!({"servers":{"fixture":{"transport":"http","url":gateway.url,"allowedTools":["echo"],"timeoutSeconds":2}}}).to_string(),cx);
    act(window, McpIntent::Save, cx);
    act(window, McpIntent::Confirm, cx);
    wait_for(root, cx, |v| !v.mcp.busy());
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(
            view.mcp.presentation.notice.contains("saved and applied"),
            "Save: {}",
            inspector_state(view)
        );
    });
    act(window, McpIntent::ListTools, cx);
    wait_for(root, cx, |v| !v.mcp.busy());
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(
            view.mcp.presentation.tools.len(),
            1,
            "List tools: {}",
            inspector_state(view)
        );
    });
    act(window, McpIntent::SelectTool("echo".into()), cx);
    act(window, McpIntent::Describe, cx);
    wait_for(root, cx, |v| !v.mcp.busy());
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(
            view.mcp.presentation.notice.contains("Discovery completed"),
            "Describe: {}",
            inspector_state(view)
        );
    });
    assert_eq!(gateway.count(), 0);
    act(window, McpIntent::EnableEditing, cx);
    act(window, McpIntent::Confirm, cx);
    wait_for(root, cx, |v| v.chat_mode_operations.is_empty());
    window.update(cx, |v, _, cx| v.sync_mcp_status(cx)).unwrap();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(
            view.mcp.presentation.allows(&McpIntent::Invoke),
            "Enable editing: {}",
            inspector_state(view)
        );
    });
}
#[gpui::test]
async fn saved_inspector_discovery_description_and_exactly_one_confirmed_invocation(
    cx: &mut TestAppContext,
) {
    let gateway = Gateway::new(false);
    let (_dir, _, window, root) = fixture(cx, true).await;
    prepare_gateway(window, &root, &gateway, cx).await;
    act(window, McpIntent::Invoke, cx);
    assert_eq!(gateway.count(), 0);
    let token = cx.read(|cx| root.read(cx).mcp.view.read(cx).token());
    act(window, McpIntent::Confirm, cx);
    window
        .update(cx, |view, window, cx| {
            view.mcp_intent(token, McpIntent::Confirm, None, window, cx)
        })
        .unwrap();
    wait_for(&root, cx, |v| !v.mcp.busy());
    assert_eq!(gateway.count(), 1);
    cx.read(|cx| {
        let v = root.read(cx);
        assert!(
            v.mcp.presentation.notice.contains("Invocation settled"),
            "{}",
            v.mcp.presentation.notice
        );
        assert!(
            v.mcp
                .manager
                .as_ref()
                .unwrap()
                .status()
                .unknown_id
                .is_none()
        );
    });
}
#[gpui::test]
async fn disconnected_one_shot_blocks_reopen_until_explicit_exact_unknown_ack(
    cx: &mut TestAppContext,
) {
    let gateway = Gateway::new(true);
    let (_dir, _, window, root) = fixture(cx, true).await;
    prepare_gateway(window, &root, &gateway, cx).await;
    act(window, McpIntent::Invoke, cx);
    act(window, McpIntent::Confirm, cx);
    wait_for(&root, cx, |v| !v.mcp.busy());
    assert_eq!(gateway.count(), 1);
    cx.read(|cx| assert!(root.read(cx).mcp.presentation.unknown_id.is_some()));
    act(window, McpIntent::Close, cx);
    window
        .update(cx, |v, window, cx| v.open_mcp(window, cx))
        .unwrap();
    act(window, McpIntent::Invoke, cx);
    assert_eq!(gateway.count(), 1);
    act(window, McpIntent::Acknowledge, cx);
    act(window, McpIntent::CancelConfirmation, cx);
    cx.read(|cx| assert!(root.read(cx).mcp.presentation.unknown_id.is_some()));
    act(window, McpIntent::Acknowledge, cx);
    act(window, McpIntent::Confirm, cx);
    wait_for(&root, cx, |v| !v.mcp.busy());
    cx.read(|cx| assert!(root.read(cx).mcp.presentation.unknown_id.is_none()));
    assert_eq!(gateway.count(), 1);
}

#[gpui::test]
async fn confirmed_save_cannot_cross_the_captured_project_scope(cx: &mut TestAppContext) {
    let (_dir, control, window, root) = fixture(cx, true).await;
    let before = control.snapshot_bytes().unwrap();
    edit(&root, configuration(), cx);
    act(window, McpIntent::Save, cx);
    root.update(cx, |view, _| {
        view.project = view.project.join("different-project")
    });
    act(window, McpIntent::Confirm, cx);
    assert_eq!(control.snapshot_bytes().unwrap(), before);
    cx.read(|cx| {
        let v = root.read(cx);
        assert!(v.mcp.view.read(cx).dirty(cx));
        assert!(
            v.mcp
                .presentation
                .notice
                .contains("different saved project")
        );
    });
}

#[gpui::test]
async fn cancel_inflight_one_shot_settles_unknown_without_auto_retry(cx: &mut TestAppContext) {
    let gateway = Gateway::with_mode(2);
    let (_dir, _, window, root) = fixture(cx, true).await;
    prepare_gateway(window, &root, &gateway, cx).await;
    act(window, McpIntent::Invoke, cx);
    act(window, McpIntent::Confirm, cx);
    wait_for(&root, cx, |_| gateway.count() == 1);
    act(window, McpIntent::CancelOperation, cx);
    wait_for(&root, cx, |v| !v.mcp.busy());
    assert_eq!(gateway.count(), 1);
    cx.read(|cx| assert!(root.read(cx).mcp.presentation.unknown_id.is_some()));
}

#[gpui::test]
async fn reload_recovers_latest_durable_inspector_result_without_reexecution(
    cx: &mut TestAppContext,
) {
    let gateway = Gateway::new(false);
    let (_dir, _, window, root) = fixture(cx, true).await;
    prepare_gateway(window, &root, &gateway, cx).await;
    act(window, McpIntent::Invoke, cx);
    act(window, McpIntent::Confirm, cx);
    wait_for(&root, cx, |v| !v.mcp.busy());
    cx.read(|cx| {
        assert_eq!(
            gateway.count(),
            1,
            "Invoke: {}",
            inspector_state(root.read(cx))
        )
    });
    root.update(cx, |view, cx| {
        view.mcp
            .view
            .update(cx, |v, cx| v.set_output("old local output".into(), cx))
    });
    act(window, McpIntent::Reload, cx);
    wait_for(&root, cx, |v| !v.mcp.busy());
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.mcp.presentation.notice.contains("Latest retained"));
        let text = view.mcp.view.read(cx).output_text();
        assert!(text.contains("one-shot fixture result"));
        assert!(text.contains("invocation"));
        assert!(!text.contains("old local output"));
        assert!(view.mcp.presentation.unknown_id.is_none());
    });
    assert_eq!(gateway.count(), 1);
}

#[gpui::test]
async fn real_external_mcp_edit_reloads_reviewable_baseline_but_requires_explicit_apply(
    cx: &mut TestAppContext,
) {
    let (_dir, _, window, root) = fixture(cx, true).await;
    edit(&root, configuration(), cx);
    act(window, McpIntent::Save, cx);
    let (authority, project) = cx.read(|cx| {
        let v = root.read(cx);
        (
            v.mcp.authority.clone(),
            v.mcp.scope.as_ref().unwrap().project.clone(),
        )
    });
    let loaded = authority.load_mcp(&project).unwrap();
    authority
        .save_mcp(
            &loaded,
            r#"{"servers":{"external":{"transport":"http","url":"http://127.0.0.1:9"}}}"#,
            &Default::default(),
        )
        .unwrap();
    act(window, McpIntent::Confirm, cx);
    wait_for(&root, cx, |v| !v.mcp.busy());
    cx.read(|cx| assert!(root.read(cx).mcp.view.read(cx).dirty(cx)));
    act(window, McpIntent::Reload, cx);
    act(window, McpIntent::Confirm, cx);
    wait_for(&root, cx, |v| !v.mcp.busy());
    cx.read(|cx| {
        let v = root.read(cx);
        assert!(v.mcp.presentation.ready);
        assert!(!v.mcp.presentation.configuration_applied);
        assert!(
            v.mcp
                .view
                .read(cx)
                .input(cx)
                .unwrap()
                .configuration
                .contains("external")
        );
        assert!(!v.mcp.presentation.allows(&McpIntent::ListTools));
        assert!(v.mcp.presentation.allows(&McpIntent::Save));
        assert!(v.mcp.presentation.notice.contains("changed outside"));
    });
    act(window, McpIntent::Save, cx);
    act(window, McpIntent::Confirm, cx);
    wait_for(&root, cx, |v| !v.mcp.busy());
    cx.read(|cx| {
        let v = root.read(cx);
        assert!(v.mcp.presentation.configuration_applied);
        assert!(
            v.mcp
                .manager
                .as_ref()
                .unwrap()
                .configuration_matches(v.mcp.loaded.as_ref().unwrap())
        );
        assert!(v.mcp.presentation.allows(&McpIntent::ListTools));
    });
}

#[gpui::test]
async fn catalog_mutex_contention_does_not_abandon_a_discovery_completion(cx: &mut TestAppContext) {
    let gateway = Gateway::new(false);
    let (_dir, _, window, root) = fixture(cx, true).await;
    edit(
        &root,
        json!({"servers":{"fixture":{"transport":"http","url":gateway.url,"timeoutSeconds":2}}})
            .to_string(),
        cx,
    );
    act(window, McpIntent::Save, cx);
    act(window, McpIntent::Confirm, cx);
    wait_for(&root, cx, |v| !v.mcp.busy());
    let workspace = cx.read(|cx| root.read(cx).workspace.clone());
    let held = workspace.lock().unwrap();
    act(window, McpIntent::ListTools, cx);
    wait_for(&root, cx, |v| !v.mcp.busy());
    cx.read(|cx| {
        let v = root.read(cx);
        assert_eq!(v.mcp.presentation.tools.len(), 1);
        assert!(
            v.mcp
                .view
                .read(cx)
                .output_text()
                .contains("Fixture echo tool")
        );
    });
    drop(held);
    assert_eq!(gateway.count(), 0);
}

#[gpui::test]
async fn keyboard_close_consumes_held_enter_before_it_can_send_composer(cx: &mut TestAppContext) {
    let (_dir, _, window, root) = fixture(cx, true).await;
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            view.mcp
                .view
                .read(cx)
                .focus_intent(&McpIntent::Close, window);
            let key = gpui::KeyDownEvent {
                keystroke: gpui::Keystroke {
                    modifiers: gpui::Modifiers::none(),
                    key: "enter".into(),
                    key_char: None,
                },
                is_held: false,
            };
            view.global_key(&key, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert!(!view.mcp.open);
            let held = gpui::KeyDownEvent {
                keystroke: gpui::Keystroke {
                    modifiers: gpui::Modifiers::none(),
                    key: "enter".into(),
                    key_char: None,
                },
                is_held: true,
            };
            view.global_key(&held, window, cx);
            assert_eq!(view.composer.read(cx).text(), "retained composer 日本語");
            assert!(!view.busy);
            assert!(view.inflight_submission.is_none());
        })
        .unwrap();
    cx.read(|cx| {
        assert_eq!(
            root.read(cx).composer.read(cx).text(),
            "retained composer 日本語"
        )
    });
}

#[gpui::test]
async fn external_manager_work_and_atomic_ack_have_no_inspector_cancel_token(
    cx: &mut TestAppContext,
) {
    let (_dir, _, window, root) = fixture(cx, true).await;
    let manager = cx.read(|cx| root.read(cx).mcp.manager.as_ref().unwrap().clone());
    let reservation = manager.begin_configuration_change().unwrap();
    root.update(cx, |view, cx| {
        view.mcp.publish(cx);
        assert!(view.mcp.presentation.busy);
        assert!(!view.mcp.presentation.cancellable);
        assert!(!view.mcp.presentation.allows(&McpIntent::CancelOperation));
        assert!(!view.mcp.cancel());
    });
    drop(reservation);
    window
        .update(cx, |view, window, cx| {
            let cancel = CancellationToken::new();
            view.mcp.operation = Some(Operation {
                id: uuid::Uuid::new_v4(),
                kind: OperationKind::Acknowledge,
                cancel: cancel.clone(),
            });
            view.mcp.publish(cx);
            let token = view.mcp.view.read(cx).token();
            view.mcp_intent(token, McpIntent::Close, None, window, cx);
            assert!(!cancel.is_cancelled());
            assert!(!view.mcp.presentation.cancellable);
            assert!(view.mcp.presentation.notice.contains("acknowledgment"));
            assert!(
                !view
                    .mcp
                    .presentation
                    .notice
                    .contains("Cancellation requested")
            );
            view.mcp.operation = None;
            view.mcp.publish(cx);
        })
        .unwrap();
}
