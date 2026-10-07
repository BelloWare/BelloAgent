use super::*;
use crate::{SessionStore, session::WriteFault};
use serde_json::json;
fn tools(root: &Path) -> NativeTools {
    NativeTools::new(root.into(), [], root.into(), [Capability::Bash])
        .unwrap()
        .with_shell_environment(crate::tools::bash::Environment {
            home: root.into(),
            path: "/usr/bin:/bin".into(),
            lang: "C".into(),
            temporary: root.into(),
        })
}
fn call(command: &str, timeout: u64) -> ToolCall {
    ToolCall {
        id: "bash-call".into(),
        name: "bash".into(),
        arguments: json!({"command":command,"timeout":timeout}),
    }
}
#[tokio::test]
async fn failed_bash_status_survives_long_lossy_output_generic_retention_reopen_and_replay() {
    let root = tempfile::tempdir().unwrap();
    let profile: Profile = serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":"http://127.0.0.1:12345","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    for command in [
        "printf failed; exit 9",
        "head -c 32768 /dev/zero | tr '\\0' '\\377'; exit 9",
    ] {
        let path = root.path().join(format!("{}.json", Uuid::new_v4()));
        let mut store = SessionStore::open(&path).unwrap();
        store
            .transact(|s| {
                s.submit(Submission::new("fixture".into(), Lane::FollowUp))?;
                s.start_next()?;
                Ok(())
            })
            .unwrap();
        let id = store.snapshot().active_reply.unwrap();
        let call = call(command, 3);
        let reply = Reply {
            text: String::new(),
            reasoning: String::new(),
            calls: vec![call.clone()],
            usage: Value::Null,
            status: "completed".into(),
            provider_items: vec![],
        };
        store
            .transact(|s| s.begin_tools(&id, &reply, &profile))
            .unwrap();
        let result = run_call(
            &tools(root.path()),
            &call,
            &root.path().join("outputs"),
            CancellationToken::new(),
        )
        .await;
        assert_eq!(result.outcome, ToolOutcome::Failed);
        if command.starts_with("head") {
            assert!(result.text.contains("Full output:"));
        }
        store
            .transact(|s| s.settle_tools(&id, vec![result], true))
            .unwrap();
        drop(store);
        let reopened = SessionStore::open(&path).unwrap();
        assert!(reopened.snapshot().messages.iter().any(|m| matches!(&m.tool_record,Some(ToolRecord::Result(r)) if r.is_error && r.outcome == ToolOutcome::Failed)));
        let snapshot = reopened.snapshot();
        let body =
            request_body_with_tools(&profile, &snapshot.messages, "", &snapshot.id, &[]).unwrap();
        assert!(
            body["input"]
                .as_array()
                .unwrap()
                .iter()
                .any(|row| row["type"] == "function_call_output"
                    && !row["output"].as_str().unwrap_or("").is_empty())
        );
    }
}
#[tokio::test]
async fn checkpoint_failure_after_shell_effect_recovers_unknown_without_automatic_reexecution() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("session.json");
    let profile: Profile = serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":"http://127.0.0.1:12345","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|s| {
            s.submit(Submission::new("fixture".into(), Lane::FollowUp))?;
            s.start_next()?;
            Ok(())
        })
        .unwrap();
    let id = store.snapshot().active_reply.unwrap();
    let call = call("printf effect >> effect.txt", 3);
    let reply = Reply {
        text: String::new(),
        reasoning: String::new(),
        calls: vec![call.clone()],
        usage: Value::Null,
        status: "completed".into(),
        provider_items: vec![],
    };
    store
        .transact(|s| s.begin_tools(&id, &reply, &profile))
        .unwrap();
    let result = run_call(
        &tools(root.path()),
        &call,
        &root.path().join("output"),
        CancellationToken::new(),
    )
    .await;
    assert_eq!(result.outcome, ToolOutcome::Completed);
    store.fault = WriteFault::BeforeRename;
    assert!(
        store
            .transact(|s| s.settle_tools(&id, vec![result], false))
            .is_err()
    );
    drop(store);
    let reopened = SessionStore::open(&path).unwrap();
    assert!(reopened.snapshot().messages.iter().any(
        |m| matches!(&m.tool_record,Some(ToolRecord::Result(r)) if r.outcome==ToolOutcome::Unknown)
    ));
    assert_eq!(
        fs::read_to_string(root.path().join("effect.txt")).unwrap(),
        "effect"
    );
}

#[tokio::test]
async fn cancelled_retirement_waiter_keeps_writer_and_gate_after_logical_shell_result() {
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("session.json");
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let profile:Profile=serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":format!("http://{}",listener.local_addr().unwrap()),"contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let gate = Arc::new(tokio::sync::Mutex::new(()));
    let started = Arc::new(tokio::sync::Notify::new());
    let cleanup = Arc::new(tokio::sync::Notify::new());
    let (release, released) = std::sync::mpsc::channel();
    let released = Arc::new(std::sync::Mutex::new(released));
    let notice = started.clone();
    let at_cleanup = cleanup.clone();
    let native = tools(root.path())
        .with_editing_gate(gate.clone())
        .with_shell_update(Some(Arc::new(move |update| {
            if update.preview.contains("started") {
                notice.notify_one();
            }
        })))
        .with_pending_shell_cleanup(Arc::new(move || {
            at_cleanup.notify_one();
            let _ = released
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_secs(15));
        }));
    let controller = Controller::new_with_options(
        SessionStore::open(&path).unwrap(),
        Some((
            profile,
            crate::Credential::new("fixture-only".into()).unwrap(),
        )),
        RuntimeOptions {
            instructions: String::new(),
            tools: Some(TrustedReadOnlyTools { native, mcp: None }),
        },
    )
    .unwrap();
    // Controller supplies its own identity-owned callback, so await live state.
    controller
        .submit("hold a fixture".into(), Lane::FollowUp)
        .unwrap();
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut raw = Vec::new();
        loop {
            let mut bytes = [0; 4096];
            let n = socket.read(&mut bytes).await.unwrap();
            assert!(n > 0);
            raw.extend_from_slice(&bytes[..n]);
            if let Some(end) = raw.windows(4).position(|v| v == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&raw[..end]).to_lowercase();
                let n: usize = headers
                    .lines()
                    .find_map(|v| v.strip_prefix("content-length: "))
                    .unwrap()
                    .parse()
                    .unwrap();
                if raw.len() >= end + 4 + n {
                    break;
                }
            }
        }
        let body=json!({"status":"completed","output":[{"type":"function_call","call_id":"held-shell","name":"bash","arguments":json!({"command":"printf started; sleep 10","timeout":20}).to_string()}]}).to_string();
        socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).as_bytes()).await.unwrap();
    });
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if controller
                .snapshot()
                .live_tools
                .iter()
                .any(|v| v.preview.contains("started"))
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    controller.stop().unwrap();
    tokio::time::timeout(Duration::from_secs(5), cleanup.notified())
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if !controller.inner.lock().unwrap().worker_running {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(controller.snapshot().state, RunState::Paused);
    assert!(controller.snapshot().messages.iter().any(
        |m| matches!(&m.tool_record,Some(ToolRecord::Result(r)) if r.outcome==ToolOutcome::Unknown)
    ));
    let mut first = Box::pin(controller.retire_and_wait());
    assert!(futures_util::poll!(&mut first).is_pending());
    drop(first);
    assert!(SessionStore::open(&path).is_err());
    assert!(gate.try_lock().is_err());
    let mut second = Box::pin(controller.retire_and_wait());
    assert!(futures_util::poll!(&mut second).is_pending());
    release.send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(5), second)
        .await
        .unwrap()
        .unwrap();
    assert!(gate.try_lock().is_ok());
    let reopened = SessionStore::open(&path).unwrap();
    assert_eq!(reopened.snapshot().state, RunState::Paused);
    server.await.unwrap();
}
