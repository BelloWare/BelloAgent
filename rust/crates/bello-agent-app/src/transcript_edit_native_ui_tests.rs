//! Fake GPUI platform + real native edit + disposable loopback provider.
//! No native windows, permissions, credentials or existing project are accessed.
use super::*;
use bello_agent_core::{
    Profile,
    project_authority::ProjectAuthority,
    synthetic_project_runtime::{SyntheticChatOptions, SyntheticProjectRuntime},
    tools::Capability,
    workspace::ChatToolMode,
};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    thread,
    time::{Duration, Instant},
};

fn request(listener: &TcpListener) -> (TcpStream, serde_json::Value) {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut stream = loop {
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(Instant::now() < deadline, "fixture provider accept timeout");
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) => panic!("fixture accept: {error}"),
        }
    };
    stream.set_nonblocking(false).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut raw = Vec::new();
    loop {
        let mut bytes = [0; 4096];
        let count = stream.read(&mut bytes).unwrap();
        assert!(count > 0);
        raw.extend_from_slice(&bytes[..count]);
        assert!(raw.len() < 1024 * 1024);
        if let Some(end) = raw.windows(4).position(|part| part == b"\r\n\r\n") {
            let headers = String::from_utf8_lossy(&raw[..end]).to_ascii_lowercase();
            let length: usize = headers
                .lines()
                .find_map(|line| line.strip_prefix("content-length: "))
                .unwrap()
                .parse()
                .unwrap();
            if raw.len() >= end + 4 + length {
                return (
                    stream,
                    serde_json::from_slice(&raw[end + 4..end + 4 + length]).unwrap(),
                );
            }
        }
    }
}
fn response(mut stream: TcpStream, body: serde_json::Value) {
    let body = body.to_string();
    write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
}
fn output(body: &serde_json::Value) -> &serde_json::Value {
    &body["input"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["type"] == "function_call_output")
        .unwrap()["output"]
}
fn wait_idle(controller: &Controller, expected: &str, cx: &mut TestAppContext) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        cx.run_until_parked();
        let snapshot = controller.snapshot_shared();
        if snapshot.state == RunState::Idle
            && snapshot.pending.is_empty()
            && snapshot.active.is_none()
            && snapshot
                .messages
                .last()
                .is_some_and(|message| message.text == expected)
        {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "read fixture did not settle: {:?}",
            controller.snapshot_shared().error
        );
        thread::sleep(Duration::from_millis(5));
    }
}

#[gpui::test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Native editing requires macOS Foundation"
)]
async fn edit_native_workflow_trust_loopback_mutation_checkpoint_replay_and_diff_ui(
    cx: &mut TestAppContext,
) {
    crate::transcript_view::open_tool_rows_for_test();
    let directory = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(directory.path()).unwrap();
    let project = root.join("project");
    let home = root.join("fixture-home");
    std::fs::create_dir_all(project.join(".git")).unwrap();
    std::fs::create_dir(&home).unwrap();
    let original = project.join("input.txt");
    std::fs::write(&original, "first\nsecond\nthird").unwrap();
    let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
    let mut draft = authority.load().unwrap().edit();
    let saved_project = draft
        .trust_project(&uuid::Uuid::new_v4().to_string(), &project, &[])
        .unwrap();
    let saved = authority.save(&mut draft).unwrap();
    let mut workspace = WorkspaceStore::open(root.join("catalog.json"), &project).unwrap();
    workspace
        .bind_project_identity(
            authority
                .confirm_project_binding(&saved, &saved_project)
                .unwrap(),
        )
        .unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let path = workspace.chat_path(&id).unwrap();
    let mut store = SessionStore::pending_with_id(&id).unwrap();
    store.persist_to(&path).unwrap();
    drop(store);
    let mut record = ChatRecord::new(id.clone(), "Edit fixture".into(), path.clone());
    record.tool_mode = ChatToolMode::ReadOnly;
    workspace.register(record, DraftRecord::default()).unwrap();
    workspace.enable_editing_after_confirmation(&id).unwrap();
    let workspace = Arc::new(Mutex::new(workspace));
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let expected_path = original.clone();
    let server = thread::spawn(move || {
        let (stream, body) = request(&listener);
        assert_eq!(body["tools"][0]["name"], "write");
        assert_eq!(body["tools"][1]["name"], "edit");
        response(
            stream,
            json!({"status":"completed","output":[{"type":"function_call","call_id":"native-edit","name":"edit","arguments":json!({"path":"input.txt","oldText":"second","newText":"SECOND"}).to_string()}]}),
        );
        let mut retained = None;
        for answer in ["Edit complete", "Replay complete"] {
            let (stream, body) = request(&listener);
            let result = output(&body);
            if let Some(expected) = &retained {
                assert_eq!(result, expected);
            } else {
                let text = result.as_str().unwrap();
                let path = text
                    .strip_prefix("Edited ")
                    .unwrap()
                    .strip_suffix(" (+1 -1)")
                    .unwrap();
                assert_eq!(
                    std::fs::canonicalize(path).unwrap(),
                    std::fs::canonicalize(&expected_path).unwrap()
                );
                retained = Some(result.clone());
            }
            response(
                stream,
                json!({"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":answer}]}]}),
            );
        }
    });
    let profile:Profile=serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":endpoint,"contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let options = || SyntheticChatOptions {
        home: home.clone(),
        capabilities: vec![Capability::Write, Capability::Edit],
        instructions: None,
    };
    let runtime = SyntheticProjectRuntime::confirm(&control, workspace.clone()).unwrap();
    let controller = runtime
        .open_editing_chat(&id, profile.clone(), options())
        .unwrap();
    controller
        .submit("Edit synthetic file".into(), Lane::FollowUp)
        .unwrap();
    wait_idle(&controller, "Edit complete", cx);
    assert_eq!(
        std::fs::read_to_string(&original).unwrap(),
        "first\nSECOND\nthird"
    );
    controller.retire_and_wait().await.unwrap();
    std::fs::write(&original, "external replacement").unwrap();
    let runtime = SyntheticProjectRuntime::confirm(&control, workspace).unwrap();
    let reopened = runtime.open_editing_chat(&id, profile, options()).unwrap();
    reopened
        .submit("Replay without reading again".into(), Lane::FollowUp)
        .unwrap();
    wait_idle(&reopened, "Replay complete", cx);
    reopened.retire_and_wait().await.unwrap();
    server.join().unwrap();
    let restored = SessionStore::open(&path).unwrap();
    // This fixture creates a fresh session and records a completed tool batch.
    assert_eq!(restored.snapshot().version, 9);
    let rows = restored
        .snapshot()
        .messages
        .into_iter()
        .filter(|message| message.tool_record.is_some())
        .collect::<Vec<_>>();
    assert_eq!(rows.len(), 2);
    drop(restored);
    let (_ui_directory, window, view) = fixture(cx, rows, 0);
    let child = transcript(&view, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let editor = super::editor(&child, "IN", cx);
    assert_eq!(
        cx.read(|cx| editor.read(cx).text().to_owned()),
        "second\nSECOND"
    );
    let card = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    assert_eq!(
        cx.read(|cx| child.read(cx).drawn_lines(&card))
            .unwrap()
            .runs[0]
            .1,
        [("−".to_owned(), true), ("+".to_owned(), true)]
    );
    assert!(
        visual
            .debug_bounds(selector(&child, "edit-counts", cx))
            .is_some()
    );
    assert_eq!(
        std::fs::read_to_string(&original).unwrap(),
        "external replacement",
        "render/replay must not reapply a mutation"
    );
}
