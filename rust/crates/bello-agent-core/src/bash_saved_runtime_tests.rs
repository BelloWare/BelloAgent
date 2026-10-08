//! Normal saved-project trust/mode route with actual bounded Bash processes.
use super::*;
fn fixture(url: &str) -> Fixture {
    let mut f = Fixture::new(url);
    f.factory
        .options
        .editing_capabilities
        .push(Capability::Bash);
    f.factory.shell_environment = Some(crate::tools::bash::Environment {
        home: f.root.clone(),
        path: "/usr/bin:/bin".into(),
        lang: "C".into(),
        temporary: f.root.clone(),
    });
    f
}
#[tokio::test]
async fn saved_editing_two_calls_live_failure_continuation_and_reopen() {
    let (listener, url) = listener().await;
    let f = fixture(&url);
    let (record, actor) = f
        .factory
        .new_chat(&f.connection, ChatToolMode::Editing)
        .unwrap();
    let item = f.prepare(&record, &actor, "run two harmless commands");
    actor.submit_identified(item).unwrap();
    let request = Request::accept(&listener).await;
    assert!(
        request.body["tools"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["name"] == "bash")
    );
    request.respond(json!([
        {"type":"function_call","call_id":"first","name":"bash","arguments":json!({"command":"printf first; : > first-start; while [ ! -f second-start ]; do sleep 0.01; done; printf second; while [ ! -f allow-first-finish ]; do printf .; sleep 0.08; done; exit 7","timeout":3}).to_string()},
        {"type":"function_call","call_id":"second","name":"bash","arguments":json!({"command":": > second-start; printf next","timeout":3}).to_string()}
    ])).await;
    timeout(DEADLINE, async {
        loop {
            if actor
                .snapshot()
                .live_tools
                .iter()
                .any(|v| v.call_id == "first" && v.outcome.is_none() && v.preview.contains("first"))
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    // Live publication is explicitly observed before allowing physical exit;
    // previews are intentionally lossy under actor contention, so the fixture
    // keeps producing bounded output until an update is actually observed.
    std::fs::write(f.root.join("allow-first-finish"), b"release").unwrap();
    let request = Request::accept(&listener).await;
    let results: Vec<_> = request.body["input"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|v| v["type"] == "function_call_output")
        .collect();
    assert_eq!(results.len(), 2);
    assert!(
        results[0]["output"]
            .as_str()
            .unwrap()
            .contains("Exit code: 7")
    );
    assert!(results[1]["output"].as_str().unwrap().contains("next"));
    request.complete("done").await;
    settled(&actor).await;
    assert!(actor.snapshot().live_tools.is_empty());
    let outcomes: Vec<_> = actor
        .snapshot()
        .messages
        .iter()
        .filter_map(|m| match &m.tool_record {
            Some(ToolRecord::Result(r)) => Some(r.outcome),
            _ => None,
        })
        .collect();
    assert_eq!(outcomes, vec![ToolOutcome::Failed, ToolOutcome::Completed]);
    actor.retire_and_wait().await.unwrap();
    let reopened = f.factory.open_registered(&f.current(&record.id)).unwrap();
    assert!(reopened.snapshot().live_tools.is_empty());
    assert_eq!(
        reopened.snapshot().messages.len(),
        actor.snapshot().messages.len()
    );
    assert!(
        timeout(Duration::from_millis(60), listener.accept())
            .await
            .is_err()
    );
    reopened.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn stop_retains_unknown_and_paused_queue_then_reopen_never_replays() {
    let (listener, url) = listener().await;
    let f = fixture(&url);
    let (record, actor) = f
        .factory
        .new_chat(&f.connection, ChatToolMode::Editing)
        .unwrap();
    let item = f.prepare(&record, &actor, "start fixture");
    actor.submit_identified(item).unwrap();
    Request::accept(&listener)
        .await
        .call(
            "bash",
            json!({"command":"printf started; sleep 20","timeout":30}),
        )
        .await;
    timeout(DEADLINE, async {
        loop {
            if actor
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
    let queued = Submission::new("keep queued".into(), Lane::FollowUp);
    actor.submit_identified(queued.clone()).unwrap();
    actor.stop().unwrap();
    settled(&actor).await;
    assert_eq!(actor.snapshot().state, crate::RunState::Paused);
    assert!(actor.snapshot().queue_paused);
    assert_eq!(actor.snapshot().pending[0].id, queued.id);
    assert!(actor.snapshot().messages.iter().any(
        |m| matches!(&m.tool_record,Some(ToolRecord::Result(r)) if r.outcome==ToolOutcome::Unknown)
    ));
    actor.retire_and_wait().await.unwrap();
    let reopened = f.factory.open_registered(&f.current(&record.id)).unwrap();
    assert_eq!(reopened.snapshot().pending[0].id, queued.id);
    assert!(
        timeout(Duration::from_millis(60), listener.accept())
            .await
            .is_err()
    );
    reopened.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn saved_readonly_bash_is_not_offered_and_cannot_spawn() {
    let (listener, url) = listener().await;
    let f = fixture(&url);
    let (record, actor) = f.pending();
    let item = f.prepare(&record, &actor, "readonly");
    actor.submit_identified(item).unwrap();
    let request = Request::accept(&listener).await;
    assert!(
        !request.body["tools"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["name"] == "bash")
    );
    request
        .call(
            "bash",
            json!({"command":"printf forbidden > must-not-exist"}),
        )
        .await;
    Request::accept(&listener).await.complete("refused").await;
    settled(&actor).await;
    assert!(!f.root.join("must-not-exist").exists());
    actor.retire_and_wait().await.unwrap();
}
