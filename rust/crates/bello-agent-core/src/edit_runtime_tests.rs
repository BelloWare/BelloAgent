//! Actual temporary-file mutation and durable uncertainty/cancellation tests.
use super::*;
use crate::{SessionStore, session::WriteFault};
use serde_json::json;
use std::sync::{Mutex, mpsc};

fn tools(root: &Path) -> NativeTools {
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
fn write_call() -> ToolCall {
    ToolCall {
        id: "write-fixture".into(),
        name: "write".into(),
        arguments: json!({"path":"output","content":"mutated"}),
    }
}
fn profile() -> Profile {
    serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":"http://127.0.0.1:12345","contextWindow":32000,"maxOutputTokens":4096})).unwrap()
}

#[tokio::test]
async fn actual_mutation_result_checkpoint_fault_recovers_unknown_or_completed_without_reexecution()
{
    for fault in [WriteFault::BeforeRename, WriteFault::AfterRename] {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        store
            .transact(|s| {
                s.submit(Submission::new(
                    "Mutate temporary fixture".into(),
                    Lane::FollowUp,
                ))?;
                s.start_next()?;
                Ok(())
            })
            .unwrap();
        let id = store.snapshot().active_reply.unwrap();
        let call = write_call();
        let reply = Reply {
            text: String::new(),
            reasoning: String::new(),
            calls: vec![call.clone()],
            usage: Value::Null,
            status: "completed".into(),
            provider_items: vec![],
        };
        store
            .transact(|s| s.begin_tools(&id, &reply, &profile()))
            .unwrap();
        let output = run_call(
            &tools(root.path()),
            &call,
            &root.path().join("outputs"),
            CancellationToken::new(),
        )
        .await;
        assert_eq!(output.outcome, ToolOutcome::Completed);
        assert_eq!(
            fs::read_to_string(root.path().join("output")).unwrap(),
            "mutated"
        );
        store.fault = fault;
        let result = store.transact(|s| s.settle_tools(&id, vec![output], false));
        assert!(result.is_err());
        if matches!(fault, WriteFault::AfterRename) {
            assert!(matches!(result, Err(Error::PersistenceUncertain(_))));
        }
        drop(store);
        fs::write(root.path().join("output"), "external replacement").unwrap();
        let mut reopened = SessionStore::open(&path).unwrap();
        let state = reopened.snapshot();
        let rows: Vec<_> = state
            .messages
            .iter()
            .filter_map(|m| match &m.tool_record {
                Some(ToolRecord::Result(r)) => Some(r),
                _ => None,
            })
            .collect();
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].outcome,
            if matches!(fault, WriteFault::AfterRename) {
                ToolOutcome::Completed
            } else {
                ToolOutcome::Unknown
            }
        );
        assert_eq!(
            rows[0].content.is_some(),
            matches!(fault, WriteFault::AfterRename)
        );
        reopened
            .transact(|s| {
                s.retry_turn()?;
                Ok(())
            })
            .unwrap();
        let state = reopened.snapshot();
        assert!(state.active_tool_calls().is_none());
        let body =
            request_body_with_tools(&profile(), &state.messages, "", &state.id, &[]).unwrap();
        assert!(
            body["input"]
                .as_array()
                .unwrap()
                .iter()
                .any(|i| i["type"] == "function_call_output")
        );
        assert_eq!(
            fs::read_to_string(root.path().join("output")).unwrap(),
            "external replacement"
        );
    }
}

#[tokio::test]
async fn cancellation_after_actual_atomic_mutation_is_unknown_and_joins_worker() {
    let root = tempfile::tempdir().unwrap();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let release = Arc::new(Mutex::new(release_rx));
    let tools = tools(root.path()).after_mutation(Arc::new(move || {
        entered_tx.send(()).unwrap();
        release
            .lock()
            .unwrap()
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
    }));
    let cancellation = CancellationToken::new();
    let token = cancellation.clone();
    let directory = root.path().join("results");
    let task =
        tokio::spawn(async move { run_call(&tools, &write_call(), &directory, token).await });
    tokio::task::spawn_blocking(move || entered_rx.recv_timeout(std::time::Duration::from_secs(5)))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        fs::read_to_string(root.path().join("output")).unwrap(),
        "mutated"
    );
    cancellation.cancel();
    tokio::task::yield_now().await;
    assert!(
        !task.is_finished(),
        "entered mutation must be joined before completion"
    );
    release_tx.send(()).unwrap();
    let result = tokio::time::timeout(std::time::Duration::from_secs(5), task)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(result.outcome, ToolOutcome::Unknown);
    assert!(result.content.is_none());
    assert!(result.text.contains("Effects may already have occurred"));
    assert!(result.text.contains("No automatic replay"));
}

#[test]
fn postwrite_permission_and_retention_errors_are_unknown_but_rejections_are_failed() {
    for error in [
        ToolError::Native {
            domain: "NSCocoaErrorDomain".into(),
            code: 513,
            message: "permission restoration".into(),
        },
        ToolError::Io(std::io::Error::other("permission restoration")),
        ToolError::Failure {
            code: "tool_result",
            message: "retention failed".into(),
        },
    ] {
        assert_eq!(
            failed_tool_result_with_editing(error, false, true).outcome,
            ToolOutcome::Unknown
        );
    }
    for code in [
        "tool_arguments",
        "invalid_params",
        "edit_match",
        "file_unavailable",
        "not_regular_file",
        "file_too_large",
        "tool_unavailable",
    ] {
        assert_eq!(
            failed_tool_result_with_editing(
                ToolError::Failure {
                    code,
                    message: "rejected".into()
                },
                false,
                true
            )
            .outcome,
            ToolOutcome::Failed
        );
    }
}

#[tokio::test]
async fn mutation_stats_require_v5_and_rejected_older_marker_does_not_rewrite_file() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("session.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|s| {
            s.submit(Submission::new("fixture".into(), Lane::FollowUp))?;
            s.start_next()?;
            Ok(())
        })
        .unwrap();
    let id = store.snapshot().active_reply.unwrap();
    let call = write_call();
    let reply = Reply {
        text: String::new(),
        reasoning: String::new(),
        calls: vec![call.clone()],
        usage: Value::Null,
        status: "completed".into(),
        provider_items: vec![],
    };
    store
        .transact(|s| s.begin_tools(&id, &reply, &profile()))
        .unwrap();
    let result = run_call(
        &tools(root.path()),
        &call,
        &root.path().join("results"),
        CancellationToken::new(),
    )
    .await;
    store
        .transact(|s| s.settle_tools(&id, vec![result], true))
        .unwrap();
    assert_eq!(store.snapshot().version, 8);
    drop(store);
    let mut bytes: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    bytes["version"] = json!(4);
    for row in bytes["messages"].as_array_mut().unwrap() {
        row.as_object_mut().unwrap().remove("task_root_id");
    }
    let bytes = serde_json::to_vec(&bytes).unwrap();
    fs::write(&path, &bytes).unwrap();
    assert!(SessionStore::open(&path).is_err());
    assert_eq!(fs::read(&path).unwrap(), bytes);
}

#[cfg(feature = "synthetic-authority")]
#[tokio::test]
async fn distinct_chat_tools_share_gate_until_entered_mutation_worker_settles() {
    let root = tempfile::tempdir().unwrap();
    let gate = Arc::new(tokio::sync::Mutex::new(()));
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let release = Arc::new(Mutex::new(release_rx));
    let first = tools(root.path())
        .with_editing_gate(gate.clone())
        .after_mutation(Arc::new(move || {
            entered_tx.send(()).unwrap();
            release
                .lock()
                .unwrap()
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap();
        }));
    let directory = root.path().join("results");
    let first_directory = directory.clone();
    let running = tokio::spawn(async move {
        run_call(
            &first,
            &write_call(),
            &first_directory,
            CancellationToken::new(),
        )
        .await
    });
    tokio::task::spawn_blocking(move || entered_rx.recv_timeout(std::time::Duration::from_secs(5)))
        .await
        .unwrap()
        .unwrap();
    let second = tools(root.path()).with_editing_gate(gate);
    let edit = ToolCall {
        id: "second-chat".into(),
        name: "edit".into(),
        arguments: json!({"path":"output","oldText":"mutated","newText":"second chat"}),
    };
    let mut waiting = Box::pin(run_call(
        &second,
        &edit,
        &directory,
        CancellationToken::new(),
    ));
    assert!(matches!(
        futures_util::poll!(&mut waiting),
        std::task::Poll::Pending
    ));
    assert_eq!(
        fs::read_to_string(root.path().join("output")).unwrap(),
        "mutated"
    );
    release_tx.send(()).unwrap();
    assert_eq!(running.await.unwrap().outcome, ToolOutcome::Completed);
    assert_eq!(waiting.await.outcome, ToolOutcome::Completed);
    assert_eq!(
        fs::read_to_string(root.path().join("output")).unwrap(),
        "second chat"
    );
}

#[cfg(feature = "synthetic-authority")]
#[tokio::test]
async fn dropped_mutation_future_keeps_workspace_gate_until_native_worker_returns() {
    let root = tempfile::tempdir().unwrap();
    let gate = Arc::new(tokio::sync::Mutex::new(()));
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let release = Arc::new(Mutex::new(release_rx));
    let first = tools(root.path())
        .with_editing_gate(gate.clone())
        .after_mutation(Arc::new(move || {
            entered_tx.send(()).unwrap();
            release
                .lock()
                .unwrap()
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap();
        }));
    let running =
        tokio::spawn(async move { first.invoke(&write_call(), CancellationToken::new()).await });
    tokio::task::spawn_blocking(move || entered_rx.recv_timeout(std::time::Duration::from_secs(5)))
        .await
        .unwrap()
        .unwrap();
    running.abort();
    assert!(running.await.unwrap_err().is_cancelled());
    assert!(
        gate.try_lock().is_err(),
        "aborted caller released an entered worker's mutation gate"
    );
    let second = tools(root.path()).with_editing_gate(gate);
    let edit = ToolCall {
        id: "after-abort".into(),
        name: "edit".into(),
        arguments: json!({"path":"output","oldText":"mutated","newText":"second"}),
    };
    let mut waiting = Box::pin(second.invoke(&edit, CancellationToken::new()));
    assert!(matches!(
        futures_util::poll!(&mut waiting),
        std::task::Poll::Pending
    ));
    assert_eq!(
        fs::read_to_string(root.path().join("output")).unwrap(),
        "mutated"
    );
    release_tx.send(()).unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(5), waiting)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        fs::read_to_string(root.path().join("output")).unwrap(),
        "second"
    );
}
