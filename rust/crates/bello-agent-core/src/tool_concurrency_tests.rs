//! Main 0.1.121 concurrency contracts. Synchronization proves physical overlap;
//! elapsed time alone never establishes that editing calls ran concurrently.
use super::*;
use serde_json::json;
use std::{
    sync::{Mutex, mpsc},
    time::Duration,
};

fn mutations(root: &Path) -> NativeTools {
    #[cfg(target_os = "macos")]
    {
        NativeTools::new(
            root.into(),
            [],
            root.into(),
            [Capability::Write, Capability::Edit],
        )
        .unwrap()
    }
    #[cfg(not(target_os = "macos"))]
    {
        NativeTools::synthetic_mutation_fixture(
            root.into(),
            vec![],
            root.into(),
            vec![Capability::Write, Capability::Edit],
        )
        .unwrap()
    }
}
fn write(id: &str, content: &str) -> ToolCall {
    ToolCall {
        id: id.into(),
        name: "write".into(),
        arguments: json!({"path":"same-file","content":content}),
    }
}

#[tokio::test]
async fn same_file_writes_both_enter_physical_workers_before_either_is_released() {
    let root = tempfile::tempdir().unwrap();
    let executor = BlockingWorkExecutor::new(2, 4);
    let (entered, arrivals) = mpsc::channel();
    let (release, released) = mpsc::channel();
    let released = Arc::new(Mutex::new(released));
    let tools = mutations(root.path())
        .with_executor(executor.clone())
        .before_read(Arc::new(move || {
            entered.send(()).unwrap();
            released
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_secs(5))
                .unwrap();
        }));
    let a = tools.clone();
    let b = tools;
    let first = tokio::spawn(async move {
        a.invoke(&write("a", "first"), CancellationToken::new())
            .await
    });
    let second = tokio::spawn(async move {
        b.invoke(&write("b", "second"), CancellationToken::new())
            .await
    });
    tokio::task::spawn_blocking(move || {
        arrivals.recv_timeout(Duration::from_secs(3)).unwrap();
        arrivals
            .recv_timeout(Duration::from_secs(3))
            .expect("both same-file writes must enter independently");
    })
    .await
    .unwrap();
    assert_eq!(executor.occupancy().active, 2);
    assert!(!root.path().join("same-file").exists());
    release.send(()).unwrap();
    release.send(()).unwrap();
    first.await.unwrap().unwrap();
    second.await.unwrap().unwrap();
    let result = fs::read_to_string(root.path().join("same-file")).unwrap();
    assert!(matches!(result.as_str(), "first" | "second"));
    // Deliberately no winner/order or compare-and-swap guarantee.
}

#[tokio::test]
async fn editing_capacity_rejection_is_failed_without_effect_and_waiting_cancellation_is_unknown() {
    for waiting_slots in [0, 1] {
        let root = tempfile::tempdir().unwrap();
        let executor = BlockingWorkExecutor::new(1, waiting_slots);
        let (entered, arrival) = mpsc::channel();
        let (release, released) = mpsc::channel();
        let released = Arc::new(Mutex::new(released));
        let reader = NativeTools::new(root.path().into(), [], root.path().into(), [Capability::Ls])
            .unwrap()
            .with_executor(executor.clone())
            .before_read(Arc::new(move || {
                entered.send(()).unwrap();
                released
                    .lock()
                    .unwrap()
                    .recv_timeout(Duration::from_secs(5))
                    .unwrap();
            }));
        let running = tokio::spawn(async move {
            reader
                .invoke(
                    &ToolCall {
                        id: "reader".into(),
                        name: "ls".into(),
                        arguments: json!({}),
                    },
                    CancellationToken::new(),
                )
                .await
        });
        tokio::task::spawn_blocking(move || arrival.recv_timeout(Duration::from_secs(3)).unwrap())
            .await
            .unwrap();
        let tools = mutations(root.path()).with_executor(executor.clone());
        let call = write("waiting", "must not be written");
        let directory = root.path().join("retained");
        let token = CancellationToken::new();
        let mut result = Box::pin(run_call(&tools, &call, &directory, token.clone()));
        if waiting_slots == 1 {
            assert!(futures_util::poll!(&mut result).is_pending());
            assert_eq!(executor.occupancy().waiting, 1);
            token.cancel();
        }
        let result = result.await;
        assert_eq!(
            result.outcome,
            if waiting_slots == 0 {
                ToolOutcome::Failed
            } else {
                ToolOutcome::Unknown
            }
        );
        assert!(!root.path().join("same-file").exists());
        assert_eq!(executor.occupancy().active, 1);
        assert_eq!(executor.occupancy().waiting, 0);
        release.send(()).unwrap();
        running.await.unwrap().unwrap();
    }
}

#[tokio::test]
async fn cancellation_during_async_authority_admission_is_not_executed() {
    let root = tempfile::tempdir().unwrap();
    let tools = mutations(root.path());
    let call = write("never-entered", "forbidden");
    let token = CancellationToken::new();
    let mut invocation = Box::pin(tools.invoke_mapped_with_admission(
        &call,
        token.clone(),
        Ok,
        std::future::pending(),
    ));
    assert!(futures_util::poll!(&mut invocation).is_pending());
    token.cancel();
    assert!(matches!(invocation.await, Err(ToolError::NotExecuted(_))));
    assert!(!root.path().join("same-file").exists());
}

async fn provider_request(listener: &tokio::net::TcpListener) -> (tokio::net::TcpStream, Value) {
    use tokio::io::AsyncReadExt;
    let (mut socket, _) = tokio::time::timeout(Duration::from_secs(5), listener.accept())
        .await
        .unwrap()
        .unwrap();
    let mut raw = Vec::new();
    loop {
        let mut bytes = [0; 4096];
        let n = socket.read(&mut bytes).await.unwrap();
        assert!(n > 0);
        raw.extend_from_slice(&bytes[..n]);
        if let Some(end) = raw.windows(4).position(|v| v == b"\r\n\r\n") {
            let headers = String::from_utf8_lossy(&raw[..end]).to_lowercase();
            let size: usize = headers
                .lines()
                .find_map(|v| v.strip_prefix("content-length: "))
                .unwrap()
                .parse()
                .unwrap();
            if raw.len() >= end + 4 + size {
                return (
                    socket,
                    serde_json::from_slice(&raw[end + 4..end + 4 + size]).unwrap(),
                );
            }
        }
    }
}
async fn respond(mut socket: tokio::net::TcpStream, output: Value) {
    use tokio::io::AsyncWriteExt;
    let body = json!({"status":"completed", "output":output}).to_string();
    socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
}

#[tokio::test]
async fn controller_batch_overlaps_mutations_then_commits_ordered_results_and_replays_without_effects()
 {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("session.json");
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let profile: Profile = serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":format!("http://{}", listener.local_addr().unwrap()),"contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let (entered, arrivals) = mpsc::channel();
    let (release, released) = mpsc::channel();
    let released = Arc::new(Mutex::new(released));
    let executor = BlockingWorkExecutor::new(2, 4);
    let native = mutations(root.path())
        .with_executor(executor.clone())
        .before_read(Arc::new(move || {
            entered.send(()).unwrap();
            released
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_secs(5))
                .unwrap();
        }));
    let options = RuntimeOptions {
        instructions: String::new(),
        tools: Some(TrustedReadOnlyTools { native, mcp: None }),
    };
    let controller = Controller::new_with_options(
        crate::SessionStore::open(&path).unwrap(),
        Some((
            profile.clone(),
            crate::Credential::new("fixture-only".into()).unwrap(),
        )),
        options,
    )
    .unwrap();
    controller
        .submit("write independent fixture files".into(), Lane::FollowUp)
        .unwrap();
    let (socket, _) = provider_request(&listener).await;
    respond(socket, json!([
        {"type":"function_call","call_id":"first","name":"write","arguments":json!({"path":"a","content":"first"}).to_string()},
        {"type":"function_call","call_id":"second","name":"write","arguments":json!({"path":"b","content":"second"}).to_string()}
    ])).await;
    tokio::task::spawn_blocking(move || {
        arrivals.recv_timeout(Duration::from_secs(3)).unwrap();
        arrivals
            .recv_timeout(Duration::from_secs(3))
            .expect("Controller must start its second mutation before the first ends");
    })
    .await
    .unwrap();
    assert_eq!(executor.occupancy().active, 2);
    assert!(!root.path().join("a").exists());
    assert!(!root.path().join("b").exists());
    release.send(()).unwrap();
    release.send(()).unwrap();
    let (socket, continuation) = provider_request(&listener).await;
    let results: Vec<_> = continuation["input"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|v| v["type"] == "function_call_output")
        .cloned()
        .collect();
    assert_eq!(results.len(), 2);
    assert_eq!(results[0]["call_id"], "first");
    assert_eq!(results[1]["call_id"], "second");
    assert_eq!(fs::read_to_string(root.path().join("a")).unwrap(), "first");
    assert_eq!(fs::read_to_string(root.path().join("b")).unwrap(), "second");
    respond(socket, json!([{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}])).await;
    tokio::time::timeout(Duration::from_secs(5), async {
        while controller.snapshot().state != RunState::Idle {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    controller.retire_and_wait().await.unwrap();
    fs::write(root.path().join("a"), "external replacement").unwrap();
    let reopened = crate::SessionStore::open(&path).unwrap();
    let snapshot = reopened.snapshot();
    let replay =
        request_body_with_tools(&profile, &snapshot.messages, "", &snapshot.id, &[]).unwrap();
    let replayed: Vec<_> = replay["input"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|v| v["type"] == "function_call_output")
        .cloned()
        .collect();
    assert_eq!(replayed, results);
    assert_eq!(
        fs::read_to_string(root.path().join("a")).unwrap(),
        "external replacement"
    );
    assert!(
        tokio::time::timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
}
