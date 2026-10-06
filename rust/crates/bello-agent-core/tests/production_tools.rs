use bello_agent_core::{
    Controller, Credential, Lane, Profile, RunState, Session, SessionStore,
    runtime::{RuntimeOptions, TrustedReadOnlyTools},
    tool_history::{ToolOutcome, ToolRecord},
};
use serde_json::{Value, json};
use std::{path::Path, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};
const DEADLINE: Duration = Duration::from_secs(5);

async fn request(listener: &TcpListener) -> (TcpStream, Value) {
    timeout(DEADLINE, async {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut bytes = vec![];
        loop {
            let mut chunk = [0; 4096];
            let n = socket.read(&mut chunk).await.unwrap();
            assert_ne!(n, 0);
            bytes.extend_from_slice(&chunk[..n]);
            if let Some(end) = bytes.windows(4).position(|x| x == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&bytes[..end]).to_lowercase();
                let length: usize = headers
                    .lines()
                    .find_map(|x| x.strip_prefix("content-length: "))
                    .unwrap()
                    .parse()
                    .unwrap();
                if bytes.len() >= end + 4 + length {
                    return (
                        socket,
                        serde_json::from_slice(&bytes[end + 4..end + 4 + length]).unwrap(),
                    );
                }
            }
        }
    })
    .await
    .unwrap()
}
async fn reply(mut socket: TcpStream, response: Value) {
    let bytes = serde_json::to_vec(&response).unwrap();
    socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", bytes.len()).as_bytes()).await.unwrap();
    socket.write_all(&bytes).await.unwrap();
    socket.shutdown().await.unwrap();
}
fn call(id: &str, name: &str, args: Value) -> Value {
    json!({"type":"function_call", "call_id":id,"name":name,"arguments":serde_json::to_string(&args).unwrap()})
}
fn terminal(output: Vec<Value>) -> Value {
    json!({"status":"completed","output":output,"usage":{}})
}
fn final_text() -> Value {
    terminal(vec![
        json!({"type":"message","content":[{"type":"output_text","text":"Finished fixture"}]}),
    ])
}
fn controller(path: &Path, root: &Path, listener: &TcpListener, enabled: bool) -> Arc<Controller> {
    let profile: Profile = serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":format!("http://{}",listener.local_addr().unwrap()),"contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    Controller::new_with_options(
        SessionStore::open(path).unwrap(),
        Some((profile, Credential::new("fixture-only".into()).unwrap())),
        RuntimeOptions {
            instructions: "Frozen fixture instructions".into(),
            tools: enabled.then(|| {
                TrustedReadOnlyTools::new(root.to_owned(), vec![], root.to_owned()).unwrap()
            }),
        },
    )
    .unwrap()
}
async fn wait(controller: &Controller, predicate: impl Fn(&Session) -> bool) -> Session {
    let mut changes = controller.subscribe();
    timeout(DEADLINE, async {
        loop {
            let snapshot = changes.borrow_and_update().clone();
            if predicate(&snapshot) {
                return (*snapshot).clone();
            }
            changes.changed().await.unwrap();
        }
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn trusted_controller_executes_ordered_batch_and_replays_results_after_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("project");
    std::fs::create_dir(&project).unwrap();
    std::fs::write(project.join("zeta"), "fixture").unwrap();
    std::fs::write(project.join("alpha"), "fixture").unwrap();
    let path = dir.path().join("session.json");
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let control = controller(&path, &project, &listener, true);
    let server = tokio::spawn(async move {
        let (socket, first) = request(&listener).await;
        assert_eq!(first["input"][0]["content"], "Frozen fixture instructions");
        assert_eq!(first["tools"].as_array().unwrap().len(), 1);
        assert_eq!(first["tools"][0]["name"], "ls");
        assert!(first["tools"][0].get("strict").is_none());
        reply(
            socket,
            terminal(vec![
                call("one", "ls", json!({})),
                call("two", "ls", json!({"limit":"1"})),
                call("three", "bash", json!({"command":"must not run"})),
            ]),
        )
        .await;
        let (socket, next) = request(&listener).await;
        let outputs: Vec<_> = next["input"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|row| row["type"] == "function_call_output")
            .collect();
        assert_eq!(
            outputs
                .iter()
                .map(|row| row["call_id"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["one", "two", "three"]
        );
        assert_eq!(outputs[0]["output"], "alpha\nzeta");
        assert_eq!(outputs[1]["output"], "alpha\n[Truncated; 2 entries]");
        assert_eq!(outputs[2]["output"], "Tool bash not found");
        reply(socket, final_text()).await;
    });
    control
        .submit("list fixture".into(), Lane::FollowUp)
        .unwrap();
    let complete = wait(&control, |s| {
        s.state == RunState::Idle
            && s.messages
                .last()
                .is_some_and(|row| row.text == "Finished fixture")
    })
    .await;
    server.await.unwrap();
    assert_eq!(complete.messages.len(), 6);
    control.shutdown().await.unwrap();
    let settled_state = control.snapshot().state;
    drop(control);
    let reopened = SessionStore::open(&path).unwrap().snapshot();
    assert_eq!(reopened.messages.len(), complete.messages.len());
    // Shutdown may win the queue worker's final boundary and durably pause it.
    assert_eq!(reopened.state, settled_state);
    assert_eq!(reopened.version, 3);
}

#[tokio::test]
async fn default_controller_offers_no_tools_and_never_executes_unexpected_call() {
    let dir = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let control = controller(
        &dir.path().join("session.json"),
        dir.path(),
        &listener,
        false,
    );
    let server = tokio::spawn(async move {
        let (socket, body) = request(&listener).await;
        assert!(body.get("tools").is_none());
        reply(socket, terminal(vec![call("one", "ls", json!({}))])).await;
    });
    control.submit("fixture".into(), Lane::FollowUp).unwrap();
    let snapshot = wait(&control, |s| s.state == RunState::Error).await;
    assert!(snapshot.error.unwrap().contains("No tool was executed"));
    assert!(!snapshot.messages.iter().any(|row| row.role == "toolResult"));
    control.shutdown().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn malformed_incomplete_and_opaque_calls_fail_before_file_dispatch() {
    for mode in ["malformed", "incomplete", "opaque"] {
        let dir = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let control = controller(
            &dir.path().join("session.json"),
            dir.path(),
            &listener,
            true,
        );
        let server = tokio::spawn(async move {
            let (socket, _) = request(&listener).await;
            let mut response = terminal(vec![call("one", "ls", json!({}))]);
            match mode {
                "malformed" => response["output"][0]["arguments"] = json!("{broken"),
                "incomplete" => {
                    response["status"] = json!("incomplete");
                    response["incomplete_details"] = json!({"reason":"max_output_tokens"});
                }
                "opaque" => response["output"].as_array_mut().unwrap().insert(
                    0,
                    json!({"type":"reasoning","encrypted_content":"synthetic opaque fixture"}),
                ),
                _ => unreachable!(),
            }
            reply(socket, response).await;
        });
        control.submit("fixture".into(), Lane::FollowUp).unwrap();
        let snapshot = wait(&control, |s| s.state == RunState::Error).await;
        assert!(
            !snapshot.messages.iter().any(|row| row.role == "toolResult"),
            "{mode}"
        );
        let notice = snapshot.error.unwrap();
        assert!(
            notice.contains(match mode {
                "malformed" => "malformed tool arguments",
                "incomplete" => "Incomplete tool response",
                _ => "verified replay policy",
            }),
            "{notice}"
        );
        control.shutdown().await.unwrap();
        server.await.unwrap();
    }
}

#[tokio::test]
async fn stop_cancels_a_queued_read_without_dispatch_or_continuation() {
    use bello_agent_core::tools::BlockingWorkExecutor;
    use tokio_util::sync::CancellationToken;
    let dir = tempfile::tempdir().unwrap();
    let executor = BlockingWorkExecutor::new(1, 1);
    let (entered, entering) = tokio::sync::oneshot::channel();
    let (release, blocked) = std::sync::mpsc::channel();
    let occupied = executor.clone();
    let blocker = tokio::spawn(async move {
        occupied
            .run(CancellationToken::new(), move |_| {
                let _ = entered.send(());
                blocked.recv().unwrap();
                Ok(())
            })
            .await
    });
    entering.await.unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let profile: Profile = serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":format!("http://{}",listener.local_addr().unwrap()),"contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let control = Controller::new_with_options(
        SessionStore::open(dir.path().join("session.json")).unwrap(),
        Some((profile, Credential::new("fixture-only".into()).unwrap())),
        RuntimeOptions {
            instructions: String::new(),
            tools: Some(
                TrustedReadOnlyTools::new(dir.path().to_owned(), vec![], dir.path().to_owned())
                    .unwrap()
                    .with_executor(executor.clone()),
            ),
        },
    )
    .unwrap();
    let server = tokio::spawn(async move {
        let (socket, _) = request(&listener).await;
        reply(socket, terminal(vec![call("one", "ls", json!({}))])).await;
    });
    control.submit("fixture".into(), Lane::FollowUp).unwrap();
    timeout(DEADLINE, async {
        while executor.occupancy().waiting != 1 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    control.stop().unwrap();
    control.shutdown().await.unwrap();
    let snapshot = control.snapshot();
    assert_eq!(snapshot.state, RunState::Paused);
    assert_eq!(executor.occupancy().active, 1);
    assert_eq!(executor.occupancy().waiting, 0);
    assert!(snapshot.messages.iter().any(|row| matches!(row.tool_record, Some(ToolRecord::Result(ref result)) if result.outcome == ToolOutcome::Unknown)));
    release.send(()).unwrap();
    blocker.await.unwrap().unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn large_ls_output_is_retained_before_following_request_and_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("project");
    std::fs::create_dir(&project).unwrap();
    for index in 0..300 {
        std::fs::write(project.join(format!("{index:03}-{}", "x".repeat(230))), "").unwrap();
    }
    let path = dir.path().join("session.json");
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let control = controller(&path, &project, &listener, true);
    let server = tokio::spawn(async move {
        let (socket, _) = request(&listener).await;
        reply(
            socket,
            terminal(vec![call("big", "ls", json!({"limit":2000}))]),
        )
        .await;
        let (socket, body) = request(&listener).await;
        let output = body["input"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["type"] == "function_call_output")
            .unwrap()["output"]
            .as_str()
            .unwrap()
            .to_owned();
        assert!(output.len() < 34000);
        let filename = output
            .split("[Output truncated. Full output: ")
            .nth(1)
            .unwrap()
            .trim_end_matches(']');
        let full = std::fs::read_to_string(filename).unwrap();
        assert!(full.len() > 65536);
        assert_eq!(full.lines().count(), 300);
        reply(socket, final_text()).await;
        output
    });
    control.submit("fixture".into(), Lane::FollowUp).unwrap();
    wait(&control, |s| {
        s.state == RunState::Idle
            && s.messages
                .last()
                .is_some_and(|row| row.text == "Finished fixture")
    })
    .await;
    let output = server.await.unwrap();
    control.shutdown().await.unwrap();
    drop(control);
    let restored = SessionStore::open(&path).unwrap().snapshot();
    assert_eq!(
        restored
            .messages
            .iter()
            .find(|row| row.role == "toolResult")
            .unwrap()
            .text,
        output
    );
}

#[tokio::test]
async fn streamed_argument_fallback_retains_the_call_used_for_execution_and_replay() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("project");
    std::fs::create_dir(&project).unwrap();
    std::fs::write(project.join("alpha"), "").unwrap();
    std::fs::write(project.join("beta"), "").unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let control = controller(&dir.path().join("session.json"), &project, &listener, true);
    let server = tokio::spawn(async move {
        let (mut socket, _) = request(&listener).await;
        socket
            .write_all(
                b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
            )
            .await
            .unwrap();
        for event in [
            json!({"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_streamed","call_id":"streamed","name":"ls","arguments":""}}),
            json!({"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"lim"}),
            json!({"type":"response.function_call_arguments.delta","output_index":0,"delta":"it\":1}"}),
            json!({"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_streamed","call_id":"streamed","name":"ls","arguments":"","status":"completed"}}),
            json!({"type":"response.completed","response":{"status":"completed","output":[],"usage":{}}}),
        ] {
            socket
                .write_all(format!("data: {event}\n\n").as_bytes())
                .await
                .unwrap();
        }
        socket.shutdown().await.unwrap();
        let (socket, next) = request(&listener).await;
        let rows = next["input"].as_array().unwrap();
        let call = rows
            .iter()
            .find(|row| row["type"] == "function_call")
            .unwrap();
        assert_eq!(call["arguments"], "{\"limit\":1}");
        assert_eq!(
            rows.iter()
                .find(|row| row["type"] == "function_call_output")
                .unwrap()["output"],
            "alpha\n[Truncated; 2 entries]"
        );
        reply(socket, final_text()).await;
    });
    control.submit("fixture".into(), Lane::FollowUp).unwrap();
    let snapshot = wait(&control, |s| {
        s.state == RunState::Idle
            && s.messages
                .last()
                .is_some_and(|row| row.text == "Finished fixture")
    })
    .await;
    let record = snapshot
        .messages
        .iter()
        .find_map(|row| match &row.tool_record {
            Some(ToolRecord::Assistant(record)) => Some(record),
            _ => None,
        })
        .unwrap();
    assert_eq!(record.calls[0].arguments, json!({"limit":1}));
    assert_eq!(record.provider_items[0]["arguments"], "{\"limit\":1}");
    server.await.unwrap();
    control.shutdown().await.unwrap();
}
