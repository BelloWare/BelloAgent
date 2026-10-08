//! Bash owns its physical cleanup without serializing other tools.
use super::*;
use crate::tools::{NativeTools, bash::Environment};
#[tokio::test]
async fn bash_cleanup_does_not_serialize_mcp_or_another_chat() {
    let server = ServerFixture::start().await;
    let f = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = f.manager();
    let root = f.project.path.clone();
    let started = Arc::new(tokio::sync::Notify::new());
    let notice = started.clone();
    let tools = NativeTools::new(root.clone(), [], root.clone(), [Capability::Bash])
        .unwrap()
        .with_shell_output(root.join("out"))
        .with_shell_environment(Environment {
            home: root.clone(),
            temporary: root.clone(),
            path: "/usr/bin:/bin".into(),
            lang: "C".into(),
        })
        .with_shell_update(Some(Arc::new(move |update| {
            if update.preview.contains("started") {
                notice.notify_one();
            }
        })));
    let token = CancellationToken::new();
    let cancel = token.clone();
    let first = tools.clone();
    let running = tokio::spawn(async move {
        first.invoke(&crate::provider::ToolCall{id:"first".into(),name:"bash".into(),arguments:json!({"command":"trap '' TERM; printf started; sleep 10","timeout":20})},token).await
    });
    timeout(DEADLINE, started.notified()).await.unwrap();
    let m = manager.clone();
    let invoked = tokio::spawn(async move {
        m.perform(
            &json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{}}),
            false,
            CancellationToken::new(),
            || async { Ok(()) },
        )
        .await
    });
    let second = tools.clone();
    let edited = tokio::spawn(async move {
        second
            .invoke(
                &crate::provider::ToolCall {
                    id: "second-chat".into(),
                    name: "bash".into(),
                    arguments: json!({"command":"printf second > second-marker","timeout":1}),
                },
                CancellationToken::new(),
            )
            .await
    });
    let performed = timeout(DEADLINE, invoked).await.unwrap().unwrap().unwrap();
    if let Some(ticket) = performed.ticket {
        ticket.settle().unwrap();
    }
    assert_eq!(
        timeout(DEADLINE, edited).await.unwrap().unwrap().unwrap()["isError"],
        false
    );
    assert_eq!(
        std::fs::read_to_string(root.join("second-marker")).unwrap(),
        "second"
    );
    assert_eq!(server.calls.load(Ordering::SeqCst), 1);
    assert!(!running.is_finished());
    cancel.cancel();
    assert!(matches!(
        timeout(DEADLINE, running).await.unwrap().unwrap(),
        Err(crate::tools::ToolError::Cancelled)
    ));
    tools.join_processes().await.unwrap();
}
