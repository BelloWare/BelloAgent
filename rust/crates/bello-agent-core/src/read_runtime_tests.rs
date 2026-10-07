//! Actual macOS read invocation cancellation; only disposable synthetic files.
use super::*;
use std::sync::{Mutex, mpsc};

#[tokio::test]
async fn cancelled_admitted_read_retains_unknown_outcome_and_no_late_content() {
    let fixture = tempfile::tempdir().unwrap();
    let path = fixture.path().join("input");
    std::fs::write(&path, "fixture unchanged").unwrap();
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let release = Arc::new(Mutex::new(release_rx));
    let tools = NativeTools::new(
        fixture.path().into(),
        [],
        fixture.path().into(),
        [Capability::Read],
    )
    .unwrap()
    .before_read(Arc::new(move || {
        started_tx.send(()).unwrap();
        release
            .lock()
            .unwrap()
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
    }));
    let token = CancellationToken::new();
    let cancel = token.clone();
    let output = fixture.path().join("outputs");
    let task = tokio::spawn(async move {
        run_call(
            &tools,
            &ToolCall {
                id: "read-cancel".into(),
                name: "read".into(),
                arguments: serde_json::json!({"path":"input"}),
            },
            &output,
            cancel,
        )
        .await
    });
    tokio::task::spawn_blocking(move || started_rx.recv_timeout(std::time::Duration::from_secs(5)))
        .await
        .unwrap()
        .unwrap();
    token.cancel();
    release_tx.send(()).unwrap();
    let result = tokio::time::timeout(std::time::Duration::from_secs(5), task)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(result.outcome, ToolOutcome::Unknown);
    assert!(result.content.is_none());
    assert!(result.text.contains("No automatic replay"));
    assert_eq!(std::fs::read_to_string(path).unwrap(), "fixture unchanged");
}

#[tokio::test]
async fn explicit_read_file_error_wins_over_paging_and_is_durable_failure_text() {
    let fixture = tempfile::tempdir().unwrap();
    let tools = NativeTools::new(
        fixture.path().into(),
        [],
        fixture.path().into(),
        [Capability::Read],
    )
    .unwrap();
    let result = run_call(
        &tools,
        &ToolCall {
            id: "read-fail".into(),
            name: "read".into(),
            arguments: serde_json::json!({"path":"missing","offset":-1}),
        },
        &fixture.path().join("outputs"),
        CancellationToken::new(),
    )
    .await;
    assert_eq!(result.outcome, ToolOutcome::Failed);
    assert!(result.content.is_none());
    assert!(result.text.starts_with("Cannot open "));
}
