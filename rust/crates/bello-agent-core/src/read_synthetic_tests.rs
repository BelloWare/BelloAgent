//! Nested in synthetic_project_runtime's test module: existing fixture trust,
//! loopback transport and writer lifecycle, with actual macOS read execution.
use super::*;
use crate::tool_content::TOOL_IMAGE_PLACEHOLDER;
use base64::Engine;

fn read_options(fixture: &Fixture) -> SyntheticChatOptions {
    let mut options = fixture.options();
    options.capabilities = vec![Capability::Read];
    options
}
fn read_profile(endpoint: &str, images: bool) -> Profile {
    let mut profile = profile(endpoint);
    profile.input = if images {
        vec!["text".into(), "image".into()]
    } else {
        vec!["text".into()]
    };
    profile
}
async fn ask_read(request: Request, path: &str, args: Value) {
    let mut arguments = args;
    arguments["path"] = json!(path);
    request.respond(json!({"status":"completed","output":[{"type":"function_call","call_id":"fixture-read","name":"read","arguments":arguments.to_string()}]})).await;
}
fn output(body: &Value) -> &Value {
    &body["input"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["type"] == "function_call_output")
        .unwrap()["output"]
}

#[tokio::test]
async fn trusted_project_read_text_persists_stats_and_replays_after_source_removal() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let path = fixture.root.join("read-fixture.txt");
    std::fs::write(&path, "a\r\nb\rc\n").unwrap();
    let runtime = fixture.runtime();
    let (listener, endpoint) = listener().await;
    let controller = runtime
        .open_chat(
            &fixture.record.id,
            read_profile(&endpoint, false),
            read_options(&fixture),
        )
        .unwrap();
    controller
        .submit("Read the synthetic file".into(), Lane::FollowUp)
        .unwrap();
    let request = Request::accept(&listener).await;
    assert_eq!(request.body["tools"][0]["name"], "read");
    assert_eq!(request.body["tools"].as_array().unwrap().len(), 1);
    ask_read(request, "read-fixture.txt", json!({"offset":2,"limit":1})).await;
    let continuation = Request::accept(&listener).await;
    let expected = json!("b\rc\n[Truncated. 3 total lines; read another range.]");
    assert_eq!(output(&continuation.body), &expected);
    continuation.complete("Read fixture").await;
    let state = settled(&controller, |s| s.state == RunState::Idle).await;
    let record = state
        .messages
        .iter()
        .find_map(|m| match &m.tool_record {
            Some(ToolRecord::Result(r)) => Some(r),
            _ => None,
        })
        .unwrap();
    assert_eq!(record.outcome, ToolOutcome::Completed);
    let stats = record.content.as_ref().unwrap().stats.as_ref().unwrap();
    assert_eq!((stats.line, stats.last_line), (Some(2), Some(3)));
    assert_eq!(
        std::fs::canonicalize(&stats.path).unwrap(),
        path.canonicalize().unwrap()
    );
    assert_eq!(state.version, 11);
    controller.retire_and_wait().await.unwrap();
    std::fs::remove_file(&path).unwrap();
    let reopened = fixture
        .runtime()
        .open_chat(
            &fixture.record.id,
            read_profile(&endpoint, false),
            read_options(&fixture),
        )
        .unwrap();
    reopened
        .submit("Continue without rereading".into(), Lane::FollowUp)
        .unwrap();
    let replay = Request::accept(&listener).await;
    assert_eq!(output(&replay.body), &expected);
    replay.complete("Replayed stored text").await;
    settled(&reopened, |s| s.state == RunState::Idle).await;
    reopened.retire_and_wait().await.unwrap();
}

#[tokio::test]
async fn trusted_project_read_image_persists_original_bytes_and_replays_with_capability_projection()
{
    const GIF: &str = "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==";
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let path = fixture.root.join("fixture.gif");
    std::fs::write(
        &path,
        base64::engine::general_purpose::STANDARD
            .decode(GIF)
            .unwrap(),
    )
    .unwrap();
    let runtime = fixture.runtime();
    let (listener, endpoint) = listener().await;
    let controller = runtime
        .open_chat(
            &fixture.record.id,
            read_profile(&endpoint, true),
            read_options(&fixture),
        )
        .unwrap();
    controller
        .submit("Read the synthetic image".into(), Lane::FollowUp)
        .unwrap();
    ask_read(
        Request::accept(&listener).await,
        "fixture.gif",
        json!({"offset":-1,"limit":0}),
    )
    .await;
    let continuation = Request::accept(&listener).await;
    let expected = json!([{"type":"input_text","text":"Read image file [image/gif]"},{"type":"input_image","detail":"auto","image_url":format!("data:image/gif;base64,{GIF}")}]);
    assert_eq!(output(&continuation.body), &expected);
    continuation.complete("Read image").await;
    let state = settled(&controller, |s| s.state == RunState::Idle).await;
    assert_eq!(state.version, 11);
    controller.retire_and_wait().await.unwrap();
    std::fs::remove_file(path).unwrap();
    for images in [true, false] {
        let reopened = fixture
            .runtime()
            .open_chat(
                &fixture.record.id,
                read_profile(&endpoint, images),
                read_options(&fixture),
            )
            .unwrap();
        reopened
            .submit("Continue with retained image".into(), Lane::FollowUp)
            .unwrap();
        let replay = Request::accept(&listener).await;
        if images {
            assert_eq!(output(&replay.body), &expected);
        } else {
            assert_eq!(
                output(&replay.body),
                &json!(format!(
                    "Read image file [image/gif]\n{TOOL_IMAGE_PLACEHOLDER}"
                ))
            );
        }
        replay.complete("Replayed stored image").await;
        settled(&reopened, |s| s.state == RunState::Idle).await;
        reopened.retire_and_wait().await.unwrap();
    }
}

#[tokio::test]
async fn revoked_project_never_executes_a_new_read_result() {
    let fixture = Fixture::new(true, ChatToolMode::ReadOnly);
    let runtime = fixture.runtime();
    let (listener, endpoint) = listener().await;
    let controller = runtime
        .open_chat(
            &fixture.record.id,
            read_profile(&endpoint, false),
            read_options(&fixture),
        )
        .unwrap();
    controller
        .submit("Read a fixture".into(), Lane::FollowUp)
        .unwrap();
    let request = Request::accept(&listener).await;
    fixture.replace_authority(|value| value["workspaces"][0]["trusted"] = json!(false));
    ask_read(request, "visible-fixture.txt", json!({})).await;
    let state = settled(&controller, |s| s.state != RunState::Running).await;
    assert!(state.messages.iter().any(|m|matches!(&m.tool_record,Some(ToolRecord::Result(r)) if r.outcome==ToolOutcome::NotExecuted && r.content.is_none())));
    assert!(
        !state
            .messages
            .iter()
            .any(|m| m.role == "toolResult" && m.text == "fixture-only")
    );
    controller.retire_and_wait().await.unwrap();
}
