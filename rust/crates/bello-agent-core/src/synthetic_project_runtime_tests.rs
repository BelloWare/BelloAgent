use super::*;
use crate::{
    Delta, Lane, RunState, Session, Submission,
    instructions::DEFAULT_INSTRUCTION_BYTES,
    project_authority::AuthorityError,
    tool_history::{ToolOutcome, ToolRecord},
    workspace::DraftRecord,
};
use serde_json::{Value, json};
use std::{collections::BTreeMap, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};

const DEADLINE: Duration = Duration::from_secs(5);

struct Fixture {
    _directory: tempfile::TempDir,
    home: PathBuf,
    root: PathBuf,
    control: SyntheticAuthorityControl,
    workspace: Arc<Mutex<WorkspaceStore>>,
    record: ChatRecord,
}
impl Fixture {
    fn new(bound: bool, mode: ChatToolMode) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let base = std::fs::canonicalize(directory.path()).unwrap();
        let root = base.join("project");
        let home = base.join("fixture-home");
        std::fs::create_dir_all(root.join(".git")).unwrap();
        std::fs::create_dir(&home).unwrap();
        std::fs::write(root.join("visible-fixture.txt"), "fixture-only").unwrap();
        let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
        let mut draft = authority.load().unwrap().edit();
        let project = draft
            .trust_project(&uuid::Uuid::new_v4().to_string(), &root, &[])
            .unwrap();
        let saved = authority.save(&mut draft).unwrap();
        let mut workspace = WorkspaceStore::open(base.join("state/catalog.json"), &root).unwrap();
        if bound {
            workspace
                .bind_project_identity(authority.confirm_project_binding(&saved, &project).unwrap())
                .unwrap();
        }
        let id = uuid::Uuid::new_v4().to_string();
        let snapshot = workspace.chat_path(&id).unwrap();
        let mut session = SessionStore::pending_with_id(&id).unwrap();
        session.persist_to(&snapshot).unwrap();
        drop(session);
        let mut record = ChatRecord::new(id, "Synthetic chat".into(), snapshot);
        record.tool_mode = mode;
        workspace
            .register(record.clone(), DraftRecord::default())
            .unwrap();
        Self {
            _directory: directory,
            home,
            root,
            control,
            workspace: Arc::new(Mutex::new(workspace)),
            record,
        }
    }
    fn runtime(&self) -> SyntheticProjectRuntime {
        SyntheticProjectRuntime::confirm(&self.control, self.workspace.clone()).unwrap()
    }
    fn options(&self) -> SyntheticChatOptions {
        SyntheticChatOptions {
            home: self.home.clone(),
            capabilities: vec![Capability::Ls],
            instructions: None,
        }
    }
    fn instructions(&self) -> InstructionOptions {
        InstructionOptions {
            roots: vec![self.root.clone()],
            codex_home: self.home.clone(),
            limit: DEFAULT_INSTRUCTION_BYTES,
            fallback_names: vec![],
            additional_paths: vec![],
        }
    }
    fn open(&self, runtime: &SyntheticProjectRuntime, endpoint: &str) -> Arc<Controller> {
        runtime
            .open_chat(&self.record.id, profile(endpoint), self.options())
            .unwrap()
    }
    fn replace_authority(&self, edit: impl FnOnce(&mut Value)) {
        let mut bytes: Value =
            serde_json::from_slice(&self.control.snapshot_bytes().unwrap().unwrap()).unwrap();
        edit(&mut bytes);
        self.control
            .replace_bytes(Some(serde_json::to_vec(&bytes).unwrap()))
            .unwrap();
    }
}
fn profile(endpoint: &str) -> Profile {
    Profile {
        id: "synthetic-profile".into(),
        api: "openai-responses".into(),
        provider_id: "litellm".into(),
        model_id: "fixture-model".into(),
        base_url: endpoint.into(),
        context_window: 8192,
        max_output_tokens: 1024,
        model_output_limit: None,
        output_cap: None,
        reasoning: false,
        thinking_level: "off".into(),
        headers: BTreeMap::new(),
        compat: Default::default(),
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
            let mut raw = Vec::new();
            loop {
                let mut bytes = [0; 4096];
                let count = socket.read(&mut bytes).await.unwrap();
                assert_ne!(count, 0, "request ended early");
                raw.extend_from_slice(&bytes[..count]);
                assert!(raw.len() < 1024 * 1024);
                if let Some(end) = raw.windows(4).position(|part| part == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&raw[..end]).to_lowercase();
                    let length: usize = headers
                        .lines()
                        .find_map(|line| line.strip_prefix("content-length: "))
                        .unwrap()
                        .parse()
                        .unwrap();
                    if raw.len() >= end + 4 + length {
                        let body = serde_json::from_slice(&raw[end + 4..end + 4 + length]).unwrap();
                        return Self { body, socket };
                    }
                }
            }
        })
        .await
        .expect("loopback request timed out")
    }
    async fn respond(mut self, body: Value) {
        let body = body.to_string();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        timeout(DEADLINE, self.socket.write_all(response.as_bytes()))
            .await
            .unwrap()
            .unwrap();
    }
    async fn complete(self, text: &str) {
        self.respond(json!({"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":text}]}]})).await;
    }
    async fn ls(self) {
        self.respond(json!({"status":"completed","output":[{"type":"function_call","call_id":"fixture-ls","name":"ls","arguments":"{}"}]})).await;
    }
}
async fn listener() -> (TcpListener, String) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    (listener, endpoint)
}
async fn settled(controller: &Controller, predicate: impl Fn(&Session) -> bool) -> Arc<Session> {
    let mut changes = controller.subscribe();
    timeout(DEADLINE, async {
        loop {
            let snapshot = changes.borrow_and_update().clone();
            if predicate(&snapshot) {
                return snapshot;
            }
            changes.changed().await.unwrap();
        }
    })
    .await
    .expect("controller did not reach expected state")
}

#[tokio::test]
async fn saved_bound_read_only_project_composes_real_ls_request_and_result() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let runtime = fixture.runtime();
    assert_eq!(runtime.authority_revision(), 1);
    assert_eq!(
        Some(runtime.project_id().to_owned()),
        fixture.workspace.lock().unwrap().snapshot().project_id
    );
    let (listener, endpoint) = listener().await;
    let controller = fixture.open(&runtime, &endpoint);
    controller
        .submit("List this fixture".into(), Lane::FollowUp)
        .unwrap();
    let request = Request::accept(&listener).await;
    assert_eq!(request.body["tools"].as_array().unwrap().len(), 1);
    assert_eq!(request.body["tools"][0]["name"], "ls");
    request.ls().await;
    let continuation = Request::accept(&listener).await;
    let result = continuation.body["input"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["type"] == "function_call_output")
        .unwrap();
    assert_eq!(result["call_id"], "fixture-ls");
    assert!(
        result["output"]
            .as_str()
            .unwrap()
            .contains("visible-fixture.txt")
    );
    continuation.complete("Listed fixture").await;
    let state = settled(&controller, |state| {
        state.state == RunState::Idle
            && state
                .messages
                .last()
                .is_some_and(|row| row.text == "Listed fixture")
    })
    .await;
    assert!(state.messages.iter().any(|row| matches!(&row.tool_record, Some(ToolRecord::Result(result)) if result.outcome == ToolOutcome::Completed)));
    controller.retire_and_wait().await.unwrap();
    let reopened = SessionStore::open(&fixture.record.snapshot).unwrap();
    assert!(
        reopened
            .snapshot()
            .messages
            .iter()
            .any(|row| row.text.contains("visible-fixture.txt"))
    );
}

#[test]
fn unbound_wrong_id_wrong_root_and_untrusted_authority_fail_closed() {
    let unbound = Fixture::new(false, ChatToolMode::ReadOnly);
    assert!(SyntheticProjectRuntime::confirm(&unbound.control, unbound.workspace.clone()).is_err());
    for change in ["id", "root", "trusted", "unknown"] {
        let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
        fixture.replace_authority(|value| match change {
            "id" => value["workspaces"][0]["id"] = uuid::Uuid::new_v4().to_string().into(),
            "root" => value["workspaces"][0]["path"] = fixture.home.to_str().unwrap().into(),
            "trusted" => value["workspaces"][0]["trusted"] = false.into(),
            _ => value["workspaces"][0]["futureAuthority"] = true.into(),
        });
        assert!(
            SyntheticProjectRuntime::confirm(&fixture.control, fixture.workspace.clone()).is_err(),
            "accepted {change}"
        );
    }
}

#[test]
fn authority_denial_and_mode_and_explicit_option_failures_do_not_open_a_writer() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let runtime = fixture.runtime();
    fixture
        .control
        .fail_next_read(AuthorityError::Denied)
        .unwrap();
    assert!(
        runtime
            .open_chat(
                &fixture.record.id,
                profile("http://127.0.0.1:9"),
                fixture.options()
            )
            .is_err()
    );
    assert!(SessionStore::open(&fixture.record.snapshot).is_ok());
    for endpoint in ["https://example.com", "http://localhost:9"] {
        assert!(
            runtime
                .open_chat(&fixture.record.id, profile(endpoint), fixture.options())
                .is_err()
        );
    }
    let mut options = fixture.options();
    options.capabilities.clear();
    assert!(
        runtime
            .open_chat(&fixture.record.id, profile("http://127.0.0.1:9"), options)
            .is_err()
    );
    let mut options = fixture.options();
    options.home = "relative-fixture-home".into();
    assert!(
        runtime
            .open_chat(&fixture.record.id, profile("http://127.0.0.1:9"), options)
            .is_err()
    );
    let mut options = fixture.options();
    let mut instructions = fixture.instructions();
    instructions.roots.push(fixture.home.clone());
    options.instructions = Some(instructions);
    assert!(
        runtime
            .open_chat(&fixture.record.id, profile("http://127.0.0.1:9"), options)
            .is_err()
    );
    let editing = Fixture::new(true, ChatToolMode::Editing);
    assert!(
        editing
            .runtime()
            .open_chat(
                &editing.record.id,
                profile("http://127.0.0.1:9"),
                editing.options()
            )
            .is_err()
    );
    let mut headers = profile("http://127.0.0.1:9");
    headers
        .headers
        .insert("x-private-fixture".into(), "unused".into());
    assert!(
        runtime
            .open_chat(&fixture.record.id, headers, fixture.options())
            .is_err()
    );
    fixture
        .workspace
        .lock()
        .unwrap()
        .set_archived(fixture.record.clone(), DraftRecord::default(), true, 1)
        .unwrap();
    assert!(
        runtime
            .open_chat(
                &fixture.record.id,
                profile("http://127.0.0.1:9"),
                fixture.options()
            )
            .is_err()
    );
}

#[test]
fn missing_or_mismatched_saved_session_is_not_created_or_adopted() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let runtime = fixture.runtime();
    std::fs::remove_file(&fixture.record.snapshot).unwrap();
    assert!(
        runtime
            .open_chat(
                &fixture.record.id,
                profile("http://127.0.0.1:9"),
                fixture.options()
            )
            .is_err()
    );
    assert!(!fixture.record.snapshot.exists());

    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let runtime = fixture.runtime();
    let mut saved: Value =
        serde_json::from_slice(&std::fs::read(&fixture.record.snapshot).unwrap()).unwrap();
    saved["id"] = uuid::Uuid::new_v4().to_string().into();
    std::fs::write(
        &fixture.record.snapshot,
        serde_json::to_vec(&saved).unwrap(),
    )
    .unwrap();
    assert!(
        runtime
            .open_chat(
                &fixture.record.id,
                profile("http://127.0.0.1:9"),
                fixture.options()
            )
            .is_err()
    );
    let reopened = SessionStore::open(&fixture.record.snapshot).unwrap();
    assert_ne!(reopened.snapshot().id, fixture.record.id);
}

#[test]
fn expected_id_is_checked_before_migration_recovery_or_stream_journal_cleanup() {
    for kind in ["v1", "running", "replay"] {
        let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
        let mut store = SessionStore::open(&fixture.record.snapshot).unwrap();
        if kind != "v1" {
            store
                .transact(|session| {
                    session.submit(Submission::new(
                        "interrupted fixture".into(),
                        Lane::FollowUp,
                    ))?;
                    session.start_next()?;
                    Ok(())
                })
                .unwrap();
        }
        let journal = crate::stream_journal::path(
            &fixture.record.snapshot,
            &store.snapshot().stream_generation,
        )
        .unwrap();
        if kind == "replay" {
            store
                .append_delta(
                    &store.snapshot().active_reply.unwrap(),
                    Delta::Text("preserved streamed fixture".into()),
                )
                .unwrap();
        }
        drop(store);
        if kind == "v1" {
            let mut saved: Value =
                serde_json::from_slice(&std::fs::read(&fixture.record.snapshot).unwrap()).unwrap();
            saved["version"] = 1.into();
            std::fs::write(
                &fixture.record.snapshot,
                serde_json::to_vec(&saved).unwrap(),
            )
            .unwrap();
        }
        let checkpoint = std::fs::read(&fixture.record.snapshot).unwrap();
        let streamed = journal.exists().then(|| std::fs::read(&journal).unwrap());
        let foreign_id = uuid::Uuid::new_v4().to_string();
        assert!(
            SessionStore::open_existing_with_id(&fixture.record.snapshot, &foreign_id).is_err()
        );
        assert_eq!(
            std::fs::read(&fixture.record.snapshot).unwrap(),
            checkpoint,
            "wrong-ID {kind} checkpoint changed"
        );
        assert_eq!(
            journal.exists().then(|| std::fs::read(&journal).unwrap()),
            streamed,
            "wrong-ID {kind} stream changed"
        );

        let recovered =
            SessionStore::open_existing_with_id(&fixture.record.snapshot, &fixture.record.id)
                .unwrap()
                .snapshot();
        assert_eq!(recovered.id, fixture.record.id);
        assert_eq!(recovered.version, 2);
        if kind != "v1" {
            assert_eq!(recovered.state, RunState::Paused);
        }
        if kind == "replay" {
            assert_eq!(
                recovered.messages.last().unwrap().text,
                "preserved streamed fixture"
            );
            assert!(!recovered.messages.last().unwrap().replay_eligible);
            assert!(!journal.exists());
        }
    }
}

#[test]
fn existing_only_open_creates_no_missing_checkpoint_lock_or_parent() {
    for missing in ["checkpoint", "lock", "both"] {
        let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
        let lock = fixture.record.snapshot.with_extension("lock");
        if missing != "lock" {
            std::fs::remove_file(&fixture.record.snapshot).unwrap();
        }
        if missing != "checkpoint" {
            std::fs::remove_file(&lock).unwrap();
        }
        assert!(
            fixture
                .runtime()
                .open_chat(
                    &fixture.record.id,
                    profile("http://127.0.0.1:9"),
                    fixture.options()
                )
                .is_err()
        );
        assert_eq!(fixture.record.snapshot.exists(), missing == "lock");
        assert_eq!(lock.exists(), missing == "checkpoint");
    }
    let directory = tempfile::tempdir().unwrap();
    let absent_parent = directory.path().join("must-stay-absent");
    assert!(
        SessionStore::open_existing_with_id(
            &absent_parent.join("chat.json"),
            &uuid::Uuid::new_v4().to_string()
        )
        .is_err()
    );
    assert!(!absent_parent.exists());
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn existing_only_open_rejects_fifo_directory_and_symlink_with_a_process_deadline() {
    const CHILD: &str = "BELLO_SYNTHETIC_CHECKPOINT_KIND_CHILD";
    if std::env::var_os(CHILD).is_none() {
        // A future blocking-open regression must fail this test, not hang the
        // whole suite. The parent owns and removes all child fixture files.
        let directory = tempfile::tempdir().unwrap();
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "synthetic_project_runtime::tests::existing_only_open_rejects_fifo_directory_and_symlink_with_a_process_deadline", "--nocapture"])
            .env(CHILD, "1")
            .env("TMPDIR", directory.path())
            .spawn().unwrap();
        let deadline = std::time::Instant::now() + DEADLINE;
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success(), "nonregular-file child test failed");
                return;
            }
            if std::time::Instant::now() >= deadline {
                child.kill().unwrap();
                child.wait().unwrap();
                panic!("opening a nonregular checkpoint or lock did not finish");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    use std::os::unix::fs::{FileTypeExt, symlink};
    for target in ["checkpoint", "lock"] {
        for kind in ["fifo", "directory", "symlink"] {
            let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
            let runtime = fixture.runtime();
            let path = if target == "checkpoint" {
                fixture.record.snapshot.clone()
            } else {
                fixture.record.snapshot.with_extension("lock")
            };
            let preserved = fixture.home.join("untouched-target.json");
            let bytes = std::fs::read(&path).unwrap();
            std::fs::write(&preserved, &bytes).unwrap();
            std::fs::remove_file(&path).unwrap();
            match kind {
                "fifo" => assert!(
                    std::process::Command::new("mkfifo")
                        .arg(&path)
                        .status()
                        .unwrap()
                        .success()
                ),
                "directory" => std::fs::create_dir(&path).unwrap(),
                _ => symlink(&preserved, &path).unwrap(),
            }
            assert!(
                runtime
                    .open_chat(
                        &fixture.record.id,
                        profile("http://127.0.0.1:9"),
                        fixture.options()
                    )
                    .is_err()
            );
            let file_type = std::fs::symlink_metadata(&path).unwrap().file_type();
            assert!(match kind {
                "fifo" => file_type.is_fifo(),
                "directory" => file_type.is_dir(),
                _ => file_type.is_symlink(),
            });
            assert_eq!(std::fs::read(&preserved).unwrap(), bytes);
        }
    }
}

#[tokio::test]
async fn revoked_or_changed_authority_fences_direct_admission_and_never_revives() {
    for change in ["generation", "revision", "trust", "mode", "denied"] {
        let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
        let runtime = fixture.runtime();
        let controller = fixture.open(&runtime, "http://127.0.0.1:9");
        let original = fixture.control.snapshot_bytes().unwrap();
        match change {
            "generation" => runtime.revoke(),
            "revision" => fixture.replace_authority(|value| value["revision"] = 2.into()),
            "trust" => {
                fixture.replace_authority(|value| value["workspaces"][0]["trusted"] = false.into())
            }
            "mode" => {
                fixture
                    .workspace
                    .lock()
                    .unwrap()
                    .enable_editing_after_confirmation(&fixture.record.id)
                    .unwrap();
            }
            _ => fixture
                .control
                .fail_next_read(AuthorityError::Denied)
                .unwrap(),
        }
        let revision = controller.snapshot().revision;
        assert!(
            controller
                .submit("must remain unsent".into(), Lane::FollowUp)
                .is_err(),
            "accepted {change}"
        );
        fixture.control.replace_bytes(original).unwrap();
        assert!(controller.resume().is_err());
        assert!(controller.retry().is_err());
        assert!(controller.reorder(&[]).is_err());
        assert_eq!(controller.snapshot().revision, revision);
        controller.retire_and_wait().await.unwrap();
    }
}

#[tokio::test]
async fn newer_generation_and_retirement_reopen_exact_saved_chat_without_replaying() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let old_generation = fixture.runtime();
    let old = fixture.open(&old_generation, "http://127.0.0.1:9");
    old_generation.revoke();
    let replacement_generation = fixture.runtime();
    assert!(
        replacement_generation
            .open_chat(
                &fixture.record.id,
                profile("http://127.0.0.1:9"),
                fixture.options()
            )
            .is_err()
    );
    old.retire_and_wait().await.unwrap();
    let current = fixture.open(&replacement_generation, "http://127.0.0.1:9");
    assert_eq!(current.snapshot().id, fixture.record.id);
    assert!(current.snapshot().messages.is_empty());
    assert!(
        old.submit("stale generation".into(), Lane::FollowUp)
            .is_err()
    );
    current.reorder(&[]).unwrap();
    current.retire_and_wait().await.unwrap();
}

#[test]
fn revocation_during_open_rejects_delayed_completion_without_acquiring_writer() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let runtime = fixture.runtime();
    let opening = runtime.clone();
    let id = fixture.record.id.clone();
    let options = fixture.options();
    let gate = fixture.control.pause_next_read().unwrap();
    let worker =
        std::thread::spawn(move || opening.open_chat(&id, profile("http://127.0.0.1:9"), options));
    assert!(gate.wait_until_started(DEADLINE));
    runtime.revoke();
    gate.release();
    assert!(worker.join().unwrap().is_err());
    assert!(SessionStore::open(&fixture.record.snapshot).is_ok());
}

#[tokio::test]
async fn revoked_generation_after_provider_reply_does_not_execute_ls_or_continue() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let runtime = fixture.runtime();
    let (listener, endpoint) = listener().await;
    let controller = fixture.open(&runtime, &endpoint);
    controller
        .submit("List fixture".into(), Lane::FollowUp)
        .unwrap();
    let request = Request::accept(&listener).await;
    runtime.revoke();
    request.ls().await;
    let state = settled(&controller, |state| state.state != RunState::Running).await;
    assert!(!state.messages.iter().any(|row| matches!(&row.tool_record, Some(ToolRecord::Result(result)) if result.outcome == ToolOutcome::Completed)));
    assert!(
        timeout(Duration::from_millis(100), listener.accept())
            .await
            .is_err()
    );
    assert!(controller.retry().is_err());
    controller.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn idle_admission_guard_and_cancelled_retirement_waiter_preserve_writer_fences() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let runtime = fixture.runtime();
    let controller = fixture.open(&runtime, "http://127.0.0.1:9");
    let suspension = controller.suspend_idle_admission().unwrap();
    assert!(controller.submit("held".into(), Lane::FollowUp).is_err());
    let mut retirement = Box::pin(controller.retire_and_wait());
    assert!(futures_util::poll!(&mut retirement).is_pending());
    drop(retirement);
    assert!(SessionStore::open(&fixture.record.snapshot).is_err());
    drop(suspension);
    timeout(DEADLINE, controller.retire_and_wait())
        .await
        .unwrap()
        .unwrap();
    assert!(controller.reorder(&[]).is_err());
    let reopened = fixture.open(&runtime, "http://127.0.0.1:9");
    reopened.reorder(&[]).unwrap();
    reopened.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn default_constructor_stays_tool_disabled_despite_saved_trust_and_read_only_mode() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    std::fs::write(
        fixture.root.join("AGENTS.md"),
        "fixture instructions must remain unread",
    )
    .unwrap();
    let (listener, endpoint) = listener().await;
    let controller = Controller::new(
        SessionStore::open(&fixture.record.snapshot).unwrap(),
        Some((
            profile(&endpoint),
            Credential::new("fixture-only".into()).unwrap(),
        )),
    )
    .unwrap();
    controller
        .submit("Default controller".into(), Lane::FollowUp)
        .unwrap();
    let request = Request::accept(&listener).await;
    assert!(
        request
            .body
            .get("tools")
            .is_none_or(|tools| tools.as_array().is_some_and(Vec::is_empty))
    );
    assert!(
        !request
            .body
            .to_string()
            .contains("fixture instructions must remain unread")
    );
    request.complete("Default response").await;
    settled(&controller, |state| {
        state.state == RunState::Idle && !state.messages.is_empty()
    })
    .await;
    controller.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn source_retry_holds_instructions_and_reopen_resolves_current_fixture_bytes() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let runtime = fixture.runtime();
    let agents = fixture.root.join("AGENTS.md");
    std::fs::write(&agents, "FIRST FIXTURE INSTRUCTIONS").unwrap();
    let (listener, endpoint) = listener().await;
    let mut options = fixture.options();
    options.instructions = Some(fixture.instructions());
    let controller = runtime
        .open_chat(&fixture.record.id, profile(&endpoint), options)
        .unwrap();
    controller
        .submit("Use instructions".into(), Lane::FollowUp)
        .unwrap();
    let request = Request::accept(&listener).await;
    assert!(
        request
            .body
            .to_string()
            .contains("FIRST FIXTURE INSTRUCTIONS")
    );
    std::fs::write(&agents, "SECOND FIXTURE INSTRUCTIONS").unwrap();
    request
        .respond(json!({"status":"failed","error":{"message":"synthetic retry fixture"}}))
        .await;
    settled(&controller, |state| state.state == RunState::Error).await;
    controller.retry().unwrap();
    let retry = Request::accept(&listener).await;
    assert!(
        retry
            .body
            .to_string()
            .contains("FIRST FIXTURE INSTRUCTIONS")
    );
    assert!(
        !retry
            .body
            .to_string()
            .contains("SECOND FIXTURE INSTRUCTIONS")
    );
    retry
        .respond(json!({"status":"failed","error":{"message":"synthetic reopen fixture"}}))
        .await;
    settled(&controller, |state| state.state == RunState::Error).await;
    controller.retire_and_wait().await.unwrap();
    let mut options = fixture.options();
    options.instructions = Some(fixture.instructions());
    let reopened = runtime
        .open_chat(&fixture.record.id, profile(&endpoint), options)
        .unwrap();
    assert!(reopened.applied_instruction_snapshot().is_none());
    reopened.retry().unwrap();
    let retry = Request::accept(&listener).await;
    assert!(
        retry
            .body
            .to_string()
            .contains("SECOND FIXTURE INSTRUCTIONS")
    );
    assert!(
        !retry
            .body
            .to_string()
            .contains("FIRST FIXTURE INSTRUCTIONS")
    );
    retry.complete("Retried with fresh resources").await;
    settled(&reopened, |state| state.state == RunState::Idle).await;
    reopened.retire_and_wait().await.unwrap();
}
