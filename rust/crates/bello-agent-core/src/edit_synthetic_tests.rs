//! Whole synthetic trust/mode -> loopback -> file mutation -> durable replay.
//! macOS uses Foundation. Linux uses an explicit cfg(test)-only ASCII adapter.
use super::*;

fn options(fixture: &Fixture) -> SyntheticChatOptions {
    let mut options = fixture.options();
    options.capabilities = vec![Capability::Ls, Capability::Write, Capability::Edit];
    #[cfg(not(target_os = "macos"))]
    {
        options.synthetic_mutations = true;
    }
    options
}
fn open(fixture: &Fixture, runtime: &SyntheticProjectRuntime, endpoint: &str) -> Arc<Controller> {
    runtime
        .open_editing_chat(&fixture.record.id, profile(endpoint), options(fixture))
        .unwrap()
}
async fn ask(request: Request, calls: &[(&str, &str, Value)]) {
    request.respond(json!({"status":"completed","output":calls.iter().map(|(id,name,args)| json!({"type":"function_call","call_id":id,"name":name,"arguments":args.to_string()})).collect::<Vec<_>>()})).await;
}
fn outputs(body: &Value) -> Vec<&Value> {
    body["input"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| item["type"] == "function_call_output")
        .map(|item| &item["output"])
        .collect()
}
fn outcomes(state: &Session) -> Vec<ToolOutcome> {
    state
        .messages
        .iter()
        .filter_map(|message| match &message.tool_record {
            Some(ToolRecord::Result(result)) => Some(result.outcome),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn saved_editing_mode_preserves_reply_order_and_replays_without_reexecution() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    // Existing confirmed one-way catalog operation, no mode inference from text.
    fixture
        .workspace
        .lock()
        .unwrap()
        .enable_editing_after_confirmation(&fixture.record.id)
        .unwrap();
    std::fs::write(fixture.root.join("edit-a"), "one\n").unwrap();
    std::fs::write(fixture.root.join("edit-b"), "two\n").unwrap();
    let runtime = fixture.runtime();
    let (listener, endpoint) = listener().await;
    let controller = open(&fixture, &runtime, &endpoint);
    controller
        .submit("Change only the temporary fixture".into(), Lane::FollowUp)
        .unwrap();
    let first = Request::accept_case(&listener, "initial", Some(&controller)).await;
    assert_eq!(
        first.body["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["ls", "write", "edit"]
    );
    ask(
        first,
        &[
            (
                "write",
                "write",
                json!({"path":"nested/file","content":"one\n"}),
            ),
            (
                "edit-1",
                "edit",
                json!({"path":"edit-a","oldText":"one","newText":"two"}),
            ),
            ("list", "ls", json!({"path":"."})),
            (
                "edit-2",
                "edit",
                json!({"path":"edit-b","oldText":"two","newText":"three"}),
            ),
        ],
    )
    .await;
    let continuation =
        Request::accept_case(&listener, "tool continuation", Some(&controller)).await;
    assert_eq!(
        std::fs::read_to_string(fixture.root.join("nested/file")).unwrap(),
        "one\n"
    );
    let kept: Vec<Value> = outputs(&continuation.body).into_iter().cloned().collect();
    assert!(kept[0].as_str().unwrap().starts_with("Wrote "));
    assert!(kept[1].as_str().unwrap().starts_with("Edited "));
    assert!(kept[3].as_str().unwrap().starts_with("Edited "));
    continuation.complete("Changed fixture").await;
    let state = settled(&controller, |s| s.state == RunState::Idle).await;
    assert_eq!(outcomes(&state), vec![ToolOutcome::Completed; 4]);
    assert_eq!(state.version, 8);
    let stats: Vec<_> = state
        .messages
        .iter()
        .filter_map(|message| match &message.tool_record {
            Some(ToolRecord::Result(record)) => record.content.as_ref()?.stats.as_ref(),
            _ => None,
        })
        .collect();
    assert_eq!(stats.len(), 3);
    assert_eq!(
        (stats[0].added, stats[0].removed, stats[0].line),
        (Some(2), Some(0), None)
    );
    assert_eq!(
        (
            stats[2].added,
            stats[2].removed,
            stats[2].line,
            stats[2].last_line
        ),
        (Some(1), Some(1), Some(1), Some(1))
    );
    controller.retire_and_wait().await.unwrap();
    std::fs::write(fixture.root.join("nested/file"), "external replacement").unwrap();
    let reopened = open(&fixture, &fixture.runtime(), &endpoint);
    reopened
        .submit("Continue from durable results".into(), Lane::FollowUp)
        .unwrap();
    let replay = Request::accept_case(&listener, "reopened replay", Some(&reopened)).await;
    assert_eq!(outputs(&replay.body), kept.iter().collect::<Vec<_>>());
    assert_eq!(
        std::fs::read_to_string(fixture.root.join("nested/file")).unwrap(),
        "external replacement"
    );
    replay.complete("Retained results only").await;
    settled(&reopened, |s| s.state == RunState::Idle).await;
    reopened.retire_and_wait().await.unwrap();
}

#[test]
fn mutation_tools_require_explicit_editing_entry_and_preserve_default_readonly_gates() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let runtime = fixture.runtime();
    assert!(
        runtime
            .open_editing_chat(
                &fixture.record.id,
                profile("http://127.0.0.1:1"),
                options(&fixture)
            )
            .is_err()
    );
    assert!(
        runtime
            .open_chat(
                &fixture.record.id,
                profile("http://127.0.0.1:1"),
                options(&fixture)
            )
            .is_err()
    );
    assert!(
        crate::runtime::TrustedReadOnlyTools::new_with_capabilities(
            fixture.root.clone(),
            vec![],
            fixture.home.clone(),
            [Capability::Write]
        )
        .is_err()
    );
    assert!(crate::runtime::RuntimeOptions::default().tools.is_none());
    assert_eq!(
        fixture.workspace.lock().unwrap().snapshot().chats[0].tool_mode,
        ChatToolMode::ReadOnly
    );
    assert!(!fixture.root.join("nested").exists());
}

#[tokio::test]
async fn stop_while_waiting_for_admission_records_not_executed_and_keeps_files() {
    let fixture = Fixture::new(true, ChatToolMode::Editing);
    let (listener, endpoint) = listener().await;
    let controller = open(&fixture, &fixture.runtime(), &endpoint);
    let held = controller.pause_native_admission_for_test();
    controller
        .submit("Synthetic waiting mutation".into(), Lane::FollowUp)
        .unwrap();
    ask(
        Request::accept(&listener).await,
        &[("write", "write", json!({"path":"blocked","content":"new"}))],
    )
    .await;
    tokio::time::timeout(std::time::Duration::from_secs(5), held.entered.notified())
        .await
        .unwrap();
    controller.stop().unwrap();
    let state = settled(&controller, |s| s.state == RunState::Paused).await;
    assert_eq!(outcomes(&state), [ToolOutcome::NotExecuted]);
    assert!(!fixture.root.join("blocked").exists());
    // Stop need not wait for an unrelated pre-effect admission barrier.
    held.release();
    controller.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn stale_trust_or_archival_after_wait_never_mutates() {
    for archive_chat in [false, true] {
        let fixture = Fixture::new(true, ChatToolMode::Editing);
        let (listener, endpoint) = listener().await;
        let controller = open(&fixture, &fixture.runtime(), &endpoint);
        let held = controller.pause_native_admission_for_test();
        controller
            .submit("Wait for source editing admission".into(), Lane::FollowUp)
            .unwrap();
        ask(
            Request::accept(&listener).await,
            &[("write", "write", json!({"path":"blocked","content":"new"}))],
        )
        .await;
        tokio::time::timeout(std::time::Duration::from_secs(5), held.entered.notified())
            .await
            .unwrap();
        if archive_chat {
            let mut workspace = fixture.workspace.lock().unwrap();
            workspace
                .set_archived(fixture.record.clone(), DraftRecord::default(), true, 1)
                .unwrap();
        } else {
            fixture.replace_authority(|value| value["workspaces"][0]["trusted"] = json!(false));
        }
        held.release();
        let state = settled(&controller, |s| s.state != RunState::Running).await;
        assert_eq!(outcomes(&state), [ToolOutcome::NotExecuted]);
        assert!(!fixture.root.join("blocked").exists());
        controller.retire_and_wait().await.unwrap();
    }
}

#[tokio::test]
async fn rejections_are_failed_but_filesystem_mutation_failures_are_unknown() {
    let fixture = Fixture::new(true, ChatToolMode::Editing);
    std::fs::create_dir(fixture.root.join("directory")).unwrap();
    let (listener, endpoint) = listener().await;
    let controller = open(&fixture, &fixture.runtime(), &endpoint);
    controller
        .submit("Exercise synthetic failures".into(), Lane::FollowUp)
        .unwrap();
    ask(
        Request::accept(&listener).await,
        &[
            (
                "missing",
                "edit",
                json!({"path":"missing","oldText":"x","newText":"y"}),
            ),
            (
                "ambiguous",
                "edit",
                json!({"path":"visible-fixture.txt","oldText":"absent","newText":"new"}),
            ),
            (
                "directory",
                "write",
                json!({"path":"directory","content":"new"}),
            ),
        ],
    )
    .await;
    let continuation = Request::accept(&listener).await;
    assert_eq!(outputs(&continuation.body).len(), 3);
    continuation.complete("Failed safely").await;
    let state = settled(&controller, |s| s.state == RunState::Idle).await;
    assert_eq!(
        outcomes(&state),
        [
            ToolOutcome::Failed,
            ToolOutcome::Failed,
            ToolOutcome::Unknown
        ]
    );
    assert!(fixture.root.join("directory").is_dir());
    assert_eq!(
        std::fs::read_to_string(fixture.root.join("visible-fixture.txt")).unwrap(),
        "fixture-only"
    );
    controller.retire_and_wait().await.unwrap();
}

#[test]
fn confirmations_keep_one_workspace_writer_across_generations() {
    let fixture = Fixture::new(true, ChatToolMode::Editing);
    let first = fixture.runtime();
    let second = fixture.runtime();
    assert!(Arc::ptr_eq(
        &first.binding.workspace,
        &second.binding.workspace
    ));
}
