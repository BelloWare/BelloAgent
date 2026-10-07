use super::*;
use crate::{
    Credential, Delta, Error, Lane, Profile, Reply, RunState, SessionStore, Submission,
    provider::{ToolCall, request_body_with_tools},
    runtime::{RuntimeOptions, TrustedReadOnlyTools},
    session::WriteFault,
};
use serde_json::json;
use std::{collections::BTreeMap, ffi::OsString, path::Path, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};

const DEADLINE: Duration = Duration::from_secs(5);
const CREDENTIAL: &str = "preview-fixture-secret-abc";

fn fixture_profile() -> Profile {
    serde_json::from_value(json!({
        "id": "test", "api": "openai-responses", "providerId": "litellm",
        "modelId": "fixture", "baseUrl": "http://127.0.0.1:3333",
        "contextWindow": 32000, "maxOutputTokens": 4096
    }))
    .unwrap()
}

fn controller(path: &Path, profile: Profile, options: RuntimeOptions) -> Arc<Controller> {
    Controller::new_with_options(
        SessionStore::open(path).unwrap(),
        Some((profile, Credential::new(CREDENTIAL.into()).unwrap())),
        options,
    )
    .unwrap()
}

fn files(path: &Path) -> BTreeMap<OsString, Vec<u8>> {
    std::fs::read_dir(path)
        .unwrap()
        .map(|entry| {
            let entry = entry.unwrap();
            (entry.file_name(), std::fs::read(entry.path()).unwrap())
        })
        .collect()
}

fn staged_turn(controller: &Controller, model: &str, effort: &str) -> Submission {
    let mut inner = controller.inner.lock().unwrap();
    let mut item = Submission::new("Delivered user input".into(), Lane::FollowUp);
    item.model = Some(model.into());
    item.effort = Some(effort.into());
    inner
        .store
        .transact(|session| {
            session.submit(item.clone())?;
            session.start_next()?;
            Ok(())
        })
        .unwrap();
    inner.worker_running = true;
    controller.publish(&inner);
    item
}

fn body(preview: &ContextPreview) -> Value {
    serde_json::from_str(preview.request_json()).unwrap()
}

#[test]
fn idle_preview_matches_provider_body_without_sends_writes_or_resource_reads() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().join("root");
    std::fs::create_dir(&root).unwrap();
    let options = RuntimeOptions {
        instructions: "Literal frozen instructions, not a path lookup.".into(),
        tools: Some(TrustedReadOnlyTools::new(root.clone(), vec![], root.clone()).unwrap()),
    };
    // Definitions remain readable even after their explicitly configured root
    // disappears. Inspection must never try a native file operation.
    std::fs::remove_dir(root).unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let mut profile = fixture_profile();
    profile.base_url = format!("http://{}", listener.local_addr().unwrap());
    profile.reasoning = true;
    profile.thinking_level = "low".into();
    profile.model_output_limit = Some(2048);
    let controller = controller(
        &directory.path().join("session.json"),
        profile.clone(),
        options.clone(),
    );
    let before = files(directory.path());
    let revision = controller.revision();
    let snapshot = controller.snapshot_shared();
    let draft = "  An unsent question 🙂\n";
    let preview = controller.prepare_context(draft).unwrap();
    let metadata = preview.metadata();
    assert_eq!(metadata.mode, ContextPreviewMode::PreparedNextRequest);
    assert!(metadata.draft_included);
    assert!(!metadata.draft_deferred);
    assert_eq!(metadata.model, profile.model_id);
    assert_eq!(metadata.thinking_level, "low");
    assert_eq!(metadata.context_window, 32000);
    assert_eq!(metadata.output_budget, 4096);
    assert_eq!(metadata.output_cap, Some(2048));
    assert_eq!(metadata.tokens, None);
    assert!(metadata.count_source.contains("unavailable"));
    assert_eq!(metadata.input_items, 1);
    assert_eq!(metadata.context_messages, 0);
    let message = Message {
        user_content: None,
        id: "expected".into(),
        role: "user".into(),
        text: draft.into(),
        reasoning: String::new(),
        replay_eligible: true,
        state: "complete".into(),
        usage: Value::Null,
        model: Some(profile.model_id.clone()),
        tool_record: None,
        compaction: None,
    };
    let expected = request_body_with_tools(
        &profile,
        &[message],
        &options.instructions,
        &snapshot.id,
        &options.definitions(),
    )
    .unwrap();
    assert_eq!(body(&preview), expected);
    assert_eq!(body(&preview)["tools"][0]["name"], "ls");
    assert!(controller.context_preview_is_current(&preview));
    assert_eq!(files(directory.path()), before);
    assert_eq!(controller.revision(), revision);
    assert!(Arc::ptr_eq(&snapshot, &controller.snapshot_shared()));
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    assert!(
        !controller
            .prepare_context("")
            .unwrap()
            .metadata()
            .draft_included
    );
    assert!(
        controller
            .prepare_context(" \n")
            .unwrap()
            .metadata()
            .draft_included
    );
}

#[test]
fn no_configuration_and_disabled_tools_are_truthful() {
    let controller = Controller::new(SessionStore::pending(), None).unwrap();
    assert!(controller.prepare_context("").is_err());
    let controller = Controller::new(
        SessionStore::pending(),
        Some((
            fixture_profile(),
            Credential::new(CREDENTIAL.into()).unwrap(),
        )),
    )
    .unwrap();
    let preview = controller.prepare_context("").unwrap();
    assert!(body(&preview).get("tools").is_none());
    assert_eq!(body(&preview)["input"], json!([]));
    assert!(!controller.is_persistent());
    assert!(controller.snapshot().messages.is_empty());
}

#[test]
fn active_and_waiting_tools_use_delivered_profile_and_original_request_boundary() {
    let directory = tempfile::tempdir().unwrap();
    let profile = fixture_profile();
    let controller = controller(
        &directory.path().join("session.json"),
        profile.clone(),
        RuntimeOptions::default(),
    );
    staged_turn(&controller, "captured-model", "high");
    let expected = {
        let snapshot = controller.snapshot();
        request_body_with_tools(
            &effective_profile(&profile, snapshot.active.as_ref()),
            &snapshot.messages,
            "",
            &snapshot.id,
            &[],
        )
        .unwrap()
    };
    let streaming = controller.prepare_context("Unsent draft").unwrap();
    let reply_id = controller.snapshot().active_reply.unwrap();
    controller
        .stream_delta(&reply_id, Delta::Text("Retained streamed partial".into()))
        .unwrap();
    {
        let mut inner = controller.inner.lock().unwrap();
        inner
            .store
            .transact(|session| {
                session.submit(Submission::new(
                    "Queued future input".into(),
                    Lane::Steering,
                ))
            })
            .unwrap();
        controller.publish(&inner);
    }
    assert!(
        controller.context_preview_is_current(&streaming),
        "partial output and queue edits do not change provider inputs"
    );
    {
        let mut inner = controller.inner.lock().unwrap();
        inner
            .store
            .transact(|session| {
                let id = session.pending[0].id.clone();
                session.begin_edit(&id, "held-preview-edit")?;
                Ok(())
            })
            .unwrap();
        controller.publish(&inner);
    }
    assert!(
        controller.context_preview_is_current(&streaming),
        "holding an undelivered queue edit does not change active provider inputs"
    );
    let active = controller.prepare_context("Unsent draft").unwrap();
    assert_eq!(body(&active), expected);
    assert_eq!(active.metadata().model, "captured-model");
    assert_eq!(active.metadata().thinking_level, "high");
    assert_eq!(active.metadata().queue_count, 1);
    assert!(active.metadata().draft_deferred);
    assert!(!active.metadata().draft_included);
    let call = ToolCall {
        id: "fixture-call".into(),
        name: "ls".into(),
        arguments: json!({}),
    };
    {
        let mut inner = controller.inner.lock().unwrap();
        let effective = effective_profile(&profile, inner.store.snapshot().active.as_ref());
        inner
            .store
            .transact(|session| {
                session.begin_tools(
                    &reply_id,
                    &Reply {
                        text: String::new(),
                        reasoning: String::new(),
                        calls: vec![call],
                        usage: Value::Null,
                        status: "completed".into(),
                        provider_items: vec![],
                    },
                    &effective,
                )
            })
            .unwrap();
        controller.publish(&inner);
    }
    let files_before = files(directory.path());
    let waiting = controller.prepare_context("Still unsent").unwrap();
    assert_eq!(
        body(&waiting),
        expected,
        "waitingTool uses the boundary before the current assistant tool call"
    );
    assert!(controller.context_preview_is_current(&streaming));
    assert!(!waiting.request_json().contains("No result provided"));
    assert!(!waiting.request_json().contains("fixture-call"));
    assert_eq!(files(directory.path()), files_before);
    {
        let mut inner = controller.inner.lock().unwrap();
        inner
            .store
            .transact(|session| session.resolve_edit("held-preview-edit", "cancelled", None))
            .unwrap();
        inner
            .store
            .transact(|session| {
                session.settle_tools(
                    &reply_id,
                    vec![super::super::tool_runtime::ToolResultRow {
                        content: None,
                        text: "Retained result".into(),
                        outcome: crate::tool_history::ToolOutcome::Completed,
                    }],
                    false,
                )
            })
            .unwrap();
        controller.publish(&inner);
    }
    assert!(!controller.context_preview_is_current(&waiting));
    let continuation = controller.prepare_context("").unwrap();
    assert!(continuation.request_json().contains("Retained result"));
    assert!(
        continuation.request_json().contains("Queued future input"),
        "steering is included only once actually delivered"
    );
}

#[test]
fn paused_or_error_preview_is_idle_and_retry_is_not_implicitly_delivered() {
    for error in [Error::Cancelled, Error::Provider("fixture failure".into())] {
        let directory = tempfile::tempdir().unwrap();
        let controller = controller(
            &directory.path().join("session.json"),
            fixture_profile(),
            RuntimeOptions::default(),
        );
        let delivered = staged_turn(&controller, "earlier-model", "high");
        let active = controller.prepare_context("").unwrap();
        let reply_id = controller.snapshot().active_reply.unwrap();
        controller
            .stream_delta(&reply_id, Delta::Text("Interrupted output".into()))
            .unwrap();
        {
            let mut inner = controller.inner.lock().unwrap();
            inner
                .store
                .transact(|session| session.finish(&reply_id, Err(error)))
                .unwrap();
            inner.worker_running = false;
            controller.publish(&inner);
        }
        let before = files(directory.path());
        let preview = controller.prepare_context("Next draft").unwrap();
        assert_eq!(
            preview.metadata().mode,
            ContextPreviewMode::PreparedNextRequest
        );
        assert_eq!(preview.metadata().model, "fixture");
        assert_eq!(preview.metadata().thinking_level, "default");
        assert!(preview.metadata().draft_included);
        let request = body(&preview);
        assert_eq!(request["input"].as_array().unwrap().len(), 2);
        assert_eq!(request["input"][0]["content"][0]["text"], delivered.text);
        assert_eq!(request["input"][1]["content"][0]["text"], "Next draft");
        assert!(!preview.request_json().contains("Interrupted output"));
        assert!(!controller.context_preview_is_current(&active));
        assert_eq!(files(directory.path()), before);
        assert_eq!(controller.snapshot().retry.unwrap().id, delivered.id);
    }
}

#[test]
fn all_exposed_fields_redact_known_credentials_and_custom_header_values() {
    let directory = tempfile::tempdir().unwrap();
    let mut profile = fixture_profile();
    profile.model_id = CREDENTIAL.into();
    let header = "private-header-\"\\-日本語";
    profile
        .headers
        .insert("X-Custom-Route".into(), header.into());
    let options = RuntimeOptions {
        instructions: format!("Instruction contains {header}"),
        tools: None,
    };
    let controller = controller(&directory.path().join("session.json"), profile, options);
    let draft = format!("Never expose {CREDENTIAL}");
    let preview = controller.prepare_context(&draft).unwrap();
    assert!(preview.metadata().credentials_redacted);
    assert_eq!(
        preview.metadata().model,
        format!("[sha256:{:x}]", Sha256::digest(CREDENTIAL.as_bytes()))
    );
    for exposed in [preview.request_json().to_owned(), format!("{preview:?}")] {
        assert!(!exposed.contains(CREDENTIAL));
        assert!(!exposed.contains(header));
        assert!(!exposed.contains("X-Custom-Route"));
        assert!(exposed.contains("sha256:"));
    }
    let request = body(&preview);
    assert_eq!(
        request["input"][1]["content"][0]["text"],
        format!("[sha256:{:x}]", Sha256::digest(draft.as_bytes()))
    );
    assert_eq!(controller.snapshot().messages.len(), 0);
    // Literal secrets in arbitrary JSON keys are also never exposed.
    let mut changed = false;
    let mut raw = serde_json::Map::new();
    raw.insert(CREDENTIAL.into(), json!([header]));
    let safe = redact_value(Value::Object(raw), &[CREDENTIAL, header], &mut changed).unwrap();
    assert!(changed);
    assert!(!safe.to_string().contains(CREDENTIAL));
    assert!(!safe.to_string().contains("private-header"));
}

#[test]
fn proxy_authorization_suffix_is_redacted_from_retained_history_and_draft() {
    assert_eq!(
        header_credential("pRoXy-AuThOrIzAtIoN", "BeArEr proxy-secret"),
        "proxy-secret"
    );
    assert_eq!(
        header_credential("Authorization", "A+.-9 proxy-secret"),
        "proxy-secret"
    );
    let longest_scheme = format!("{} proxy-secret", "A".repeat(32));
    assert_eq!(
        header_credential("Proxy-Authorization", &longest_scheme),
        "proxy-secret"
    );
    for invalid in [
        "1Bearer proxy-secret",
        "Bad_scheme proxy-secret",
        "Bearer\tproxy-secret",
    ] {
        assert_eq!(header_credential("Proxy-Authorization", invalid), invalid);
    }
    let too_long = format!("{} proxy-secret", "A".repeat(33));
    assert_eq!(
        header_credential("Proxy-Authorization", &too_long),
        too_long
    );
    assert_eq!(
        header_credential("X-Custom-Route", "Bearer proxy-secret"),
        "Bearer proxy-secret"
    );

    let directory = tempfile::tempdir().unwrap();
    let mut profile = fixture_profile();
    profile
        .headers
        .insert("pRoXy-AuThOrIzAtIoN".into(), "Bearer proxy-secret".into());
    let controller = controller(
        &directory.path().join("session.json"),
        profile,
        RuntimeOptions::default(),
    );
    let retained = "Retained history contains only proxy-secret";
    {
        let mut inner = controller.inner.lock().unwrap();
        inner
            .store
            .transact(|session| {
                session.messages.push(Message {
                    user_content: None,
                    id: "retained-proxy-fixture".into(),
                    role: "user".into(),
                    text: retained.into(),
                    reasoning: String::new(),
                    replay_eligible: true,
                    state: "complete".into(),
                    usage: Value::Null,
                    model: None,
                    tool_record: None,
                    compaction: None,
                });
                Ok(())
            })
            .unwrap();
        controller.publish(&inner);
    }
    let before = files(directory.path());
    let draft = "Draft contains only proxy-secret";
    let preview = controller.prepare_context(draft).unwrap();
    assert!(preview.metadata().credentials_redacted);
    assert!(!preview.request_json().contains("proxy-secret"));
    assert!(!format!("{preview:?}").contains("proxy-secret"));
    let request = body(&preview);
    for (index, original) in [retained, draft].into_iter().enumerate() {
        assert_eq!(
            request["input"][index]["content"][0]["text"],
            format!("[sha256:{:x}]", Sha256::digest(original.as_bytes()))
        );
    }
    assert_eq!(files(directory.path()), before);
    assert_eq!(controller.snapshot().messages[0].text, retained);
}

#[test]
fn busy_fatal_uncertain_and_replaced_sessions_fail_without_mutation() {
    let directory = tempfile::tempdir().unwrap();
    let controller = controller(
        &directory.path().join("session.json"),
        fixture_profile(),
        RuntimeOptions::default(),
    );
    let preview = controller.prepare_context("").unwrap();
    {
        let mut inner = controller.inner.lock().unwrap();
        let other = controller.clone();
        let captured = preview.clone();
        let (sent, received) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            let result = (
                other.prepare_context(""),
                other.context_preview_current(&captured),
                other.context_preview_is_current(&captured),
            );
            let _ = sent.send(result);
        });
        let result = received.recv_timeout(std::time::Duration::from_secs(1));
        if result.is_err() {
            // Release the intentional lock before joining: a regression fails
            // with a deadline instead of hanging the entire suite forever.
            drop(inner);
            worker.join().unwrap();
            panic!("Context inspection blocked on a busy actor");
        }
        let (prepared, current, is_current) = result.unwrap();
        worker.join().unwrap();
        assert!(prepared.unwrap_err().to_string().contains("changing"));
        assert!(current.is_err());
        assert!(!is_current);
        inner.fatal = Some(format!("unsafe error {CREDENTIAL}"));
    }
    let failure = controller.prepare_context("").unwrap_err().to_string();
    assert!(failure.contains("unavailable"));
    assert!(!failure.contains(CREDENTIAL));
    {
        let mut inner = controller.inner.lock().unwrap();
        inner.fatal = None;
        inner.store.fault = WriteFault::AfterRename;
        assert!(matches!(
            inner.store.transact(|session| {
                session.queue_paused = true;
                Ok(())
            }),
            Err(Error::PersistenceUncertain(_))
        ));
    }
    let before = files(directory.path());
    assert!(matches!(
        controller.prepare_context(""),
        Err(Error::PersistenceUncertain(_))
    ));
    assert!(!controller.context_preview_is_current(&preview));
    assert_eq!(files(directory.path()), before);
    controller.retire().unwrap();
    assert!(!controller.context_preview_current(&preview).unwrap());
    assert!(
        controller
            .prepare_context("")
            .unwrap_err()
            .to_string()
            .contains("replaced")
    );
    assert_eq!(files(directory.path()), before);
}

#[test]
fn retained_preview_does_not_own_the_writer_or_match_a_reopened_controller() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("session.json");
    let original = controller(&path, fixture_profile(), RuntimeOptions::default());
    let preview = original.prepare_context("Retained snapshot").unwrap();
    let session_id = preview.metadata().session_id.clone();
    drop(original);
    let reopened = controller(&path, fixture_profile(), RuntimeOptions::default());
    assert_eq!(reopened.snapshot().id, session_id);
    assert!(!reopened.context_preview_current(&preview).unwrap());
    assert_eq!(
        body(&preview),
        body(&reopened.prepare_context("Retained snapshot").unwrap())
    );
}

#[test]
fn committed_completion_invalidates_before_outer_worker_publishes() {
    let directory = tempfile::tempdir().unwrap();
    let controller = controller(
        &directory.path().join("session.json"),
        fixture_profile(),
        RuntimeOptions::default(),
    );
    staged_turn(&controller, "fixture", "default");
    let preview = controller.prepare_context("").unwrap();
    let published = controller.snapshot_shared();
    let reply_id = published.active_reply.clone().unwrap();
    {
        let mut inner = controller.inner.lock().unwrap();
        inner
            .store
            .transact(|session| {
                session.finish(
                    &reply_id,
                    Ok(Reply {
                        text: "Completed before publication".into(),
                        reasoning: String::new(),
                        calls: vec![],
                        usage: Value::Null,
                        status: "completed".into(),
                        provider_items: vec![],
                    }),
                )
            })
            .unwrap();
        // run_turn releases the actor lock before run() publishes this result.
    }
    assert!(Arc::ptr_eq(&published, &controller.snapshot_shared()));
    assert!(!controller.context_preview_current(&preview).unwrap());
}

#[test]
fn draft_wire_and_pretty_preview_have_independent_byte_limits() {
    let directory = tempfile::tempdir().unwrap();
    let controller = controller(
        &directory.path().join("session.json"),
        fixture_profile(),
        RuntimeOptions::default(),
    );
    assert!(
        controller
            .prepare_context(&"🙂".repeat(MAX_DRAFT_BYTES / 4))
            .is_ok()
    );
    assert!(
        controller
            .prepare_context(&"🙂".repeat(MAX_DRAFT_BYTES / 4 + 1))
            .is_err()
    );
    staged_turn(&controller, "fixture", "default");
    assert!(
        controller
            .prepare_context(&"x".repeat(MAX_DRAFT_BYTES + 1))
            .is_err(),
        "active drafts are bounded even though deferred"
    );
    let limit = crate::provider::MAX_REQUEST_BYTES;
    let pretty_too_large = json!(["x".repeat(limit - 5)]);
    assert!(crate::provider::serialize_request(&pretty_too_large).is_ok());
    assert!(crate::provider::serialize_bounded(&pretty_too_large, true).is_err());
    drop(pretty_too_large);
    let options = RuntimeOptions {
        instructions: "x".repeat(limit),
        tools: None,
    };
    let oversized = Controller::new_with_options(
        SessionStore::pending(),
        Some((fixture_profile(), Credential::new("x".into()).unwrap())),
        options,
    )
    .unwrap();
    assert!(
        oversized
            .prepare_context("")
            .unwrap_err()
            .to_string()
            .contains("32 MiB"),
        "the original wire body must fit even if redaction would shrink it"
    );
}

async fn await_session(controller: &Controller, predicate: impl Fn(&Session) -> bool) {
    let mut updates = controller.subscribe();
    timeout(DEADLINE, async {
        loop {
            if predicate(&updates.borrow_and_update()) {
                break;
            }
            updates.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
}

async fn read_request(socket: &mut TcpStream) -> Value {
    timeout(DEADLINE, async {
        let mut raw = Vec::new();
        let mut buffer = [0; 4096];
        loop {
            let count = socket.read(&mut buffer).await.unwrap();
            assert!(count > 0);
            raw.extend_from_slice(&buffer[..count]);
            if let Some(end) = raw.windows(4).position(|window| window == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&raw[..end]).to_ascii_lowercase();
                let length: usize = headers
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length: "))
                    .unwrap()
                    .parse()
                    .unwrap();
                if raw.len() >= end + 4 + length {
                    return serde_json::from_slice(&raw[end + 4..end + 4 + length]).unwrap();
                }
            }
        }
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn prepared_draft_equals_actual_dispatch_and_active_stream_inspection_changes_nothing() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let directory = tempfile::tempdir().unwrap();
    let mut profile = fixture_profile();
    profile.base_url = format!("http://{}", listener.local_addr().unwrap());
    profile.reasoning = true;
    profile.thinking_level = "low".into();
    let options = RuntimeOptions {
        instructions: "Frozen literal instructions.".into(),
        tools: None,
    };
    let controller = controller(&directory.path().join("session.json"), profile, options);
    let draft = "Exact drafted input 🙂\n";
    let idle = controller.prepare_context(draft).unwrap();
    controller.submit(draft.into(), Lane::FollowUp).unwrap();
    let (mut socket, _) = timeout(DEADLINE, listener.accept()).await.unwrap().unwrap();
    let dispatched = read_request(&mut socket).await;
    assert_eq!(
        body(&idle),
        dispatched,
        "preview uses the actual dispatch builder and history projection"
    );
    assert!(!controller.context_preview_is_current(&idle));
    socket
        .write_all(
            concat!(
                "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"live partial\"}\n\n"
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    await_session(&controller, |session| {
        session
            .messages
            .last()
            .is_some_and(|row| row.text == "live partial")
    })
    .await;
    controller
        .submit("Undelivered queue entry".into(), Lane::FollowUp)
        .unwrap();
    let before = files(directory.path());
    let revision = controller.revision();
    let active = controller
        .prepare_context("Draft ignored during stream")
        .unwrap();
    assert_eq!(body(&active), dispatched);
    assert!(active.metadata().draft_deferred);
    assert_eq!(active.metadata().queue_count, 1);
    assert_eq!(files(directory.path()), before);
    assert_eq!(controller.revision(), revision);
    let listener = listener.into_std().unwrap();
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    controller.stop().unwrap();
    timeout(DEADLINE, controller.shutdown())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(controller.snapshot().state, RunState::Paused);
    assert!(!controller.context_preview_is_current(&active));
    let paused = controller.prepare_context("").unwrap();
    assert_eq!(body(&paused), dispatched);
    assert_eq!(
        paused.metadata().mode,
        ContextPreviewMode::PreparedNextRequest
    );
    assert!(!paused.request_json().contains("live partial"));
    assert!(!paused.request_json().contains("Undelivered queue entry"));
}

#[cfg(feature = "synthetic-authority")]
#[test]
fn synthetic_resource_runtime_cannot_report_lifetime_literal_as_current_context() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct Guard(Arc<AtomicUsize>);
    impl crate::runtime::SyntheticRuntimeGuard for Guard {
        fn check(&self) -> crate::Result<()> {
            Ok(())
        }
        fn confirm(&self) -> crate::Result<()> {
            self.0.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let confirmations = Arc::new(AtomicUsize::new(0));
    let controller = Controller::new_with_synthetic_resources(
        SessionStore::open(&path).unwrap(),
        Some((
            fixture_profile(),
            Credential::new(CREDENTIAL.into()).unwrap(),
        )),
        RuntimeOptions {
            instructions: "not the applied resource snapshot".into(),
            tools: None,
        },
        crate::runtime::SyntheticResources::new(None, Arc::new(Guard(confirmations.clone()))),
    )
    .unwrap();
    let before = files(dir.path());
    let confirmed_before = confirmations.load(Ordering::Relaxed);
    let snapshot = serde_json::to_value(controller.snapshot()).unwrap();
    let error = controller.prepare_context("unsent draft").unwrap_err();
    assert!(error.to_string().contains("synthetic resource runtimes"));
    assert_eq!(confirmations.load(Ordering::Relaxed), confirmed_before);
    assert_eq!(files(dir.path()), before);
    assert_eq!(
        serde_json::to_value(controller.snapshot()).unwrap(),
        snapshot
    );
}

#[cfg(feature = "synthetic-authority")]
#[test]
fn active_preview_confirmation_cannot_cross_worker_epoch_or_settlement() {
    use crate::project_authority::{
        ProjectAuthority,
        connections::{ConnectionDraft, SYNTHETIC_KEY, SavedConnectionRuntime},
    };
    for settled in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
        let mut profile = fixture_profile();
        profile.id = uuid::Uuid::new_v4().to_string();
        profile.base_url = "http://127.0.0.1:9".into();
        profile.headers.clear();
        let mut draft = ConnectionDraft::new(profile, "Preview fixture".into());
        draft.key_input = SYNTHETIC_KEY.into();
        let saved = authority
            .save_connection(&authority.load_connections().unwrap(), &draft)
            .unwrap();
        let runtime =
            SavedConnectionRuntime::confirm(&authority, &saved.loaded, &saved.profile.profile.id)
                .unwrap();
        let actor = Controller::with_configuration(
            SessionStore::open(directory.path().join("session.json")).unwrap(),
            Some(runtime.configuration()),
        )
        .unwrap();
        actor.inner.lock().unwrap().worker_running = true;
        let gate = control.pause_next_read().unwrap();
        let copy = actor.clone();
        let worker = std::thread::spawn(move || copy.prepare_context(""));
        assert!(gate.wait_until_started(std::time::Duration::from_secs(1)));
        let mut change = saved.loaded.edit(&saved.profile.profile.id).unwrap();
        change.profile.output_cap = Some(77);
        authority.save_connection(&saved.loaded, &change).unwrap();
        {
            let mut inner = actor.inner.lock().unwrap();
            inner.worker_running = !settled;
            inner.worker_epoch = Arc::new(());
        }
        gate.release();
        assert!(worker.join().unwrap().is_err());
        actor.inner.lock().unwrap().worker_running = false;
    }
}
