use super::*;
use crate::{Lane, Message, context_recovery::Phase, session::WriteFault};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};
const DEADLINE: Duration = Duration::from_secs(10);

fn row(id: &str, role: &str, text: String) -> Message {
    Message {
        id: id.into(),
        role: role.into(),
        text,
        reasoning: String::new(),
        replay_eligible: true,
        state: "complete".into(),
        usage: Value::Null,
        model: None,
        task_root_id: None,
        user_content: None,
        tool_record: None,
        compaction: None,
    }
}
struct Fixture {
    actor: Arc<Controller>,
    directory: tempfile::TempDir,
    requests: tokio::sync::mpsc::Receiver<Value>,
    responses: tokio::sync::mpsc::Sender<String>,
    server: tokio::task::JoinHandle<()>,
    tool_calls: Arc<std::sync::atomic::AtomicUsize>,
}
impl Fixture {
    async fn new() -> Self {
        Self::with_tools(false).await
    }
    async fn with_tools(enabled: bool) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let profile: Profile = serde_json::from_value(json!({"id":"recovery-fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":format!("http://{}",listener.local_addr().unwrap()),"contextWindow":65536,"maxOutputTokens":4096})).unwrap();
        let mut store = SessionStore::open(directory.path().join("session.json")).unwrap();
        store
            .transact(|session| {
                session.messages = vec![
                    row("old-user", "user", "Objective constraints. ".repeat(1800)),
                    row(
                        "old-answer",
                        "assistant",
                        "Verified progress evidence. ".repeat(1800),
                    ),
                ];
                Ok(())
            })
            .unwrap();
        let tool_calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let tools = if enabled {
            let mut trusted = TrustedReadOnlyTools::new(
                directory.path().to_owned(),
                vec![],
                directory.path().to_owned(),
            )
            .unwrap();
            let count = tool_calls.clone();
            trusted.native = trusted.native.before_read(Arc::new(move || {
                count.fetch_add(1, Ordering::SeqCst);
            }));
            Some(trusted)
        } else {
            None
        };
        let mut actor = Controller::new_with_options(
            store,
            Some((
                profile,
                Credential::new("fixture-secret-only".into()).unwrap(),
            )),
            RuntimeOptions {
                instructions: "Frozen fixture instructions".into(),
                tools,
            },
        )
        .unwrap();
        Arc::get_mut(&mut actor)
            .expect("fresh fixture controller is exclusively owned")
            .client = ResponsesClient::new_synthetic_fixture().unwrap();
        let (request_send, requests) = tokio::sync::mpsc::channel(8);
        let (responses, mut response_read) = tokio::sync::mpsc::channel::<String>(8);
        let server = tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let body = read_request(&mut socket).await;
                if request_send.send(body).await.is_err() {
                    break;
                }
                let Some(response) = response_read.recv().await else {
                    break;
                };
                let _ = socket.write_all(response.as_bytes()).await;
            }
        });
        Self {
            actor,
            directory,
            requests,
            responses,
            server,
            tool_calls,
        }
    }
    async fn next(&mut self) -> Value {
        timeout(DEADLINE, self.requests.recv())
            .await
            .unwrap()
            .unwrap()
    }
    async fn reply(&self, body: Value) {
        let body = body.to_string();
        self.responses.send(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len())).await.unwrap();
    }
    async fn reject(&self) {
        self.reply(json!({"error":{"code":"context_length_exceeded","message":"Input exceeds the context window fixture-secret-only"},"usage":{"input_tokens":111}})).await;
    }
    async fn summary(&self) {
        self.reply(completed(
            "Objective retained. Evidence verified. Next step remains.",
        ))
        .await;
    }
    async fn settle(&self) -> Session {
        timeout(DEADLINE, async {
            loop {
                let session = self.actor.snapshot();
                if session.state != RunState::Running
                    && !self.actor.worker_active.load(Ordering::Acquire)
                {
                    drop(self.actor.inner.lock().unwrap());
                    return self.actor.snapshot();
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap()
    }
    async fn no_request(&mut self) {
        assert!(
            timeout(Duration::from_millis(120), self.requests.recv())
                .await
                .is_err()
        );
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.server.abort();
    }
}
async fn read_request(socket: &mut TcpStream) -> Value {
    timeout(DEADLINE, async {
        let mut bytes = Vec::new();
        loop {
            let mut buffer = [0; 8192];
            let count = socket.read(&mut buffer).await.unwrap();
            assert!(count > 0);
            bytes.extend_from_slice(&buffer[..count]);
            if let Some(end) = bytes.windows(4).position(|v| v == b"\r\n\r\n") {
                let head = String::from_utf8_lossy(&bytes[..end]).to_ascii_lowercase();
                let len: usize = head
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length: "))
                    .unwrap()
                    .parse()
                    .unwrap();
                if bytes.len() >= end + 4 + len {
                    return serde_json::from_slice(&bytes[end + 4..end + 4 + len]).unwrap();
                }
            }
        }
    })
    .await
    .unwrap()
}
fn completed(text: &str) -> Value {
    json!({"id":"response-fixture","status":"completed","output":[{"id":"msg-fixture","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":text}]}],"usage":{"input_tokens":100,"output_tokens":10}})
}

#[tokio::test]
async fn rejection_summary_retry_is_exactly_three_requests_and_keeps_original_submission() {
    let mut f = Fixture::new().await;
    let submission = Submission::new("Continue original task".into(), Lane::FollowUp);
    let id = submission.id.clone();
    f.actor.submit_identified(submission).unwrap();
    let original = f.next().await;
    f.reject().await;
    let summary = f.next().await;
    assert_ne!(summary, original);
    f.summary().await;
    let retry = f.next().await;
    assert_ne!(retry, original);
    assert!(retry.to_string().contains("Continue original task"));
    assert!(!retry.to_string().contains("context-rejected"));
    f.reply(completed("Done after compaction")).await;
    let done = f.settle().await;
    assert_eq!(done.version, 11);
    assert_eq!(done.context_recoveries.len(), 1);
    let receipt = &done.context_recoveries[0];
    assert_eq!(receipt.turn_id, id);
    assert_eq!(receipt.phase, Phase::Completed);
    assert_eq!((receipt.summary_attempts, receipt.retry_attempts), (1, 1));
    assert!(receipt.summary_id.is_some());
    assert_eq!(
        receipt
            .failure
            .as_ref()
            .unwrap()
            .reported_usage
            .as_ref()
            .unwrap()["input_tokens"],
        111
    );
    assert!(
        !serde_json::to_string(&done)
            .unwrap()
            .contains("fixture-secret-only")
    );
    assert_eq!(done.messages.iter().filter(|row| row.id == id).count(), 1);
    f.no_request().await;
    f.actor.retire_and_wait().await.unwrap();
    let reopened = SessionStore::open(f.directory.path().join("session.json"))
        .unwrap()
        .snapshot();
    assert_eq!(reopened.context_recoveries[0].phase, Phase::Completed);
}

#[tokio::test]
async fn repeated_rejection_and_explicit_retry_never_gain_another_summary() {
    let mut f = Fixture::new().await;
    f.actor.submit("Continue".into(), Lane::FollowUp).unwrap();
    f.next().await;
    f.reject().await;
    f.next().await;
    f.summary().await;
    f.next().await;
    f.reject().await;
    let failed = f.settle().await;
    assert_eq!(failed.state, RunState::Error);
    assert_eq!(failed.context_recoveries[0].phase, Phase::Failed);
    assert!(failed.context_recoveries[0].retry_rejection.is_some());
    f.no_request().await;
    f.actor.retry().unwrap();
    let manual_reply = f.actor.snapshot().active_reply.unwrap();
    f.next().await;
    f.reject().await;
    let again = f.settle().await;
    assert_eq!(
        again
            .messages
            .iter()
            .filter(|row| row.id == manual_reply)
            .count(),
        1
    );
    assert_eq!(
        again
            .messages
            .iter()
            .find(|row| row.id == manual_reply)
            .unwrap()
            .usage["input_tokens"],
        111
    );
    assert_eq!(
        again
            .messages
            .iter()
            .filter_map(|row| row.usage["input_tokens"].as_u64())
            .sum::<u64>(),
        433
    );
    assert_eq!(again.context_recoveries.len(), 1);
    assert_eq!(again.context_recoveries[0].summary_attempts, 1);
    f.no_request().await;
}

#[tokio::test]
async fn rejected_summary_preserves_reported_usage_without_retry_or_fallback() {
    let mut f = Fixture::new().await;
    f.actor.submit("Continue".into(), Lane::FollowUp).unwrap();
    f.next().await;
    f.reject().await;
    f.next().await;
    f.reply(json!({"error":{"code":"rate_limit_exceeded","message":"Summary rate limited"},"usage":{"input_tokens":222}})).await;
    let failed = f.settle().await;
    assert_eq!(failed.context_recoveries[0].retry_attempts, 0);
    assert_eq!(
        failed.context_recoveries[0]
            .summary_rejection
            .as_ref()
            .unwrap()
            .reported_usage
            .as_ref()
            .unwrap()["input_tokens"],
        222
    );
    assert!(failed.messages.iter().all(|row| row.compaction.is_none()));
    f.no_request().await;
}

#[tokio::test]
async fn summary_with_tools_is_never_executed_or_adopted() {
    let mut f = Fixture::new().await;
    f.actor.submit("Continue".into(), Lane::FollowUp).unwrap();
    f.next().await;
    f.reject().await;
    f.next().await;
    f.reply(json!({"id":"bad-summary","status":"completed","output":[{"type":"function_call","id":"call","call_id":"call","name":"bash","arguments":"{\"command\":\"false\"}"}],"usage":{"input_tokens":100,"output_tokens":10}})).await;
    let failed = f.settle().await;
    assert_eq!(failed.context_recoveries[0].retry_attempts, 0);
    assert!(failed.messages.iter().all(|row| row.compaction.is_none()));
    f.no_request().await;
}

#[tokio::test]
async fn stop_during_summary_keeps_original_retry_and_consumption_on_reopen() {
    let mut f = Fixture::new().await;
    f.actor
        .submit("Original retry identity".into(), Lane::FollowUp)
        .unwrap();
    f.next().await;
    f.reject().await;
    f.next().await;
    let original = f.actor.snapshot().active.unwrap().id;
    f.actor.stop().unwrap();
    f.summary().await;
    let stopped = f.settle().await;
    assert_eq!(stopped.state, RunState::Paused);
    assert_eq!(stopped.retry.as_ref().unwrap().id, original);
    assert_eq!(stopped.context_recoveries[0].phase, Phase::Cancelled);
    assert_eq!(stopped.context_recoveries[0].retry_attempts, 0);
    f.no_request().await;
    f.actor.retire_and_wait().await.unwrap();
    let store = SessionStore::open(f.directory.path().join("session.json")).unwrap();
    assert_eq!(store.snapshot().retry.unwrap().id, original);
    assert_eq!(
        store.snapshot().context_recoveries[0].phase,
        Phase::Cancelled
    );
}

#[tokio::test]
async fn steering_delivered_after_summary_once_followups_remain_queued() {
    let mut f = Fixture::new().await;
    f.actor
        .submit("Original task".into(), Lane::FollowUp)
        .unwrap();
    f.next().await;
    f.reject().await;
    f.next().await;
    let steer = Submission::new("Steer this task".into(), Lane::Steering);
    let id = steer.id.clone();
    f.actor.submit_identified(steer).unwrap();
    f.actor
        .submit("Later followup".into(), Lane::FollowUp)
        .unwrap();
    f.summary().await;
    let retry = f.next().await;
    assert!(retry.to_string().contains("Steer this task"));
    assert!(!retry.to_string().contains("Later followup"));
    f.reject().await;
    let failed = f.settle().await;
    assert_eq!(failed.context_recoveries.len(), 1);
    assert_eq!(
        failed.context_recoveries[0].retry_turn_id.as_ref(),
        Some(&id)
    );
    assert_eq!(failed.messages.iter().filter(|row| row.id == id).count(), 1);
    assert_eq!(failed.pending.len(), 1);
    f.no_request().await;
}

#[tokio::test]
async fn consumption_write_fault_sends_no_summary() {
    for fault in [WriteFault::BeforeRename, WriteFault::AfterRename] {
        let mut f = Fixture::new().await;
        f.actor.submit("Continue".into(), Lane::FollowUp).unwrap();
        f.next().await;
        f.actor.inner.lock().unwrap().store.fault = fault;
        f.reject().await;
        timeout(DEADLINE, async {
            while f.actor.worker_active.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        f.no_request().await;
        f.actor.inner.lock().unwrap().store.fault = WriteFault::None;
    }
}

#[tokio::test]
async fn oversized_intact_history_refuses_threshold_and_recovery_without_summary_or_model_switch() {
    let mut f = Fixture::new().await;
    let config = f.actor.configuration().unwrap();
    let mut profile = config.profile.clone();
    profile.context_window = 1024;
    profile.max_output_tokens = 128;
    f.actor
        .configure(Arc::new(Configuration {
            profile,
            credential: Credential::new("fixture-secret-only".into()).unwrap(),
            connection: None,
        }))
        .unwrap();
    f.actor.submit("Continue".into(), Lane::FollowUp).unwrap();
    // Far past the threshold, the automatic compaction refuses locally before
    // any request and consumes nothing.
    let refused = f.settle().await;
    assert!(refused.error.as_ref().unwrap().contains("intact history"));
    assert!(refused.context_recoveries.is_empty());
    f.no_request().await;
    // An explicit Retry repeats the request without the threshold check.
    f.actor.retry().unwrap();
    let original = f.next().await;
    assert_eq!(original["model"], "fixture");
    f.reject().await;
    let failed = f.settle().await;
    assert_eq!(failed.context_recoveries[0].summary_attempts, 0);
    assert!(failed.error.as_ref().unwrap().contains("intact history"));
    f.no_request().await;
}

#[tokio::test]
async fn rejected_partial_output_remains_once_and_is_excluded_from_summary_and_retry() {
    let mut f = Fixture::new().await;
    f.actor.submit("Continue".into(), Lane::FollowUp).unwrap();
    f.next().await;
    let body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"REJECTED_PARTIAL_SENTINEL\"}\n\ndata: {\"type\":\"error\",\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"input too long\"}}\n\n";
    f.responses.send(format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len())).await.unwrap();
    let summary = f.next().await;
    assert!(!summary.to_string().contains("REJECTED_PARTIAL_SENTINEL"));
    f.summary().await;
    let retry = f.next().await;
    assert!(!retry.to_string().contains("REJECTED_PARTIAL_SENTINEL"));
    f.reply(completed("Done")).await;
    let done = f.settle().await;
    let rows: Vec<_> = done
        .messages
        .iter()
        .filter(|row| row.text.contains("REJECTED_PARTIAL_SENTINEL"))
        .collect();
    assert_eq!(rows.len(), 1);
    assert!(!rows[0].replay_eligible);
}

#[cfg(feature = "synthetic-authority")]
#[tokio::test]
async fn stop_at_each_durable_recovery_boundary_prevents_following_http() {
    for phase in ["recovery-consume", "recovery-adopt", "recovery-retry"] {
        let mut f = Fixture::new().await;
        let gate = f.actor.set_input_commit_gate_for_test(phase);
        f.actor.submit("Original".into(), Lane::FollowUp).unwrap();
        f.next().await;
        f.reject().await;
        if phase != "recovery-consume" {
            f.next().await;
            f.summary().await;
        }
        timeout(DEADLINE, gate.entered.notified()).await.unwrap();
        f.actor.stop().unwrap();
        assert!(f.actor.worker_active.load(Ordering::Acquire));
        gate.released.notify_one();
        let stopped = f.settle().await;
        assert_eq!(stopped.state, RunState::Paused);
        assert!(stopped.retry.is_some());
        assert_eq!(
            stopped
                .messages
                .iter()
                .filter(|row| row.compaction.is_some())
                .count(),
            usize::from(phase == "recovery-retry")
        );
        f.no_request().await;
    }
}

#[cfg(feature = "synthetic-authority")]
#[tokio::test]
async fn adoption_and_retry_write_faults_fence_all_following_sends() {
    for phase in ["recovery-adopt", "recovery-retry"] {
        for fault in [WriteFault::BeforeRename, WriteFault::AfterRename] {
            let mut f = Fixture::new().await;
            let gate = f.actor.set_input_commit_gate_for_test(phase);
            f.actor.submit("Original".into(), Lane::FollowUp).unwrap();
            f.next().await;
            f.reject().await;
            f.next().await;
            f.summary().await;
            timeout(DEADLINE, gate.entered.notified()).await.unwrap();
            f.actor.inner.lock().unwrap().store.fault = fault;
            gate.released.notify_one();
            timeout(DEADLINE, async {
                while f.actor.worker_active.load(Ordering::Acquire) {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap();
            assert!(f.actor.inner.lock().unwrap().fatal.is_some());
            f.no_request().await;
            f.actor.inner.lock().unwrap().store.fault = WriteFault::None;
        }
    }
}

fn tool_reply() -> Value {
    json!({"id":"tool-response","status":"completed","output":[{"type":"function_call","id":"ls-item","call_id":"ls-call","name":"ls","arguments":"{\"path\":\".\"}"}],"usage":{"input_tokens":100,"output_tokens":10}})
}

#[tokio::test]
async fn completed_tool_is_not_replayed_when_its_continuation_is_compacted() {
    let mut f = Fixture::with_tools(true).await;
    f.actor
        .submit("Inspect and continue".into(), Lane::FollowUp)
        .unwrap();
    f.next().await;
    f.reply(tool_reply()).await;
    let continuation = f.next().await;
    assert!(continuation.to_string().contains("function_call_output"));
    assert_eq!(f.tool_calls.load(Ordering::SeqCst), 1);
    f.reject().await;
    f.next().await;
    f.summary().await;
    f.next().await;
    f.reply(completed("Done")).await;
    let done = f.settle().await;
    assert_eq!(f.tool_calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        done.messages
            .iter()
            .filter(|row| matches!(
                row.tool_record,
                Some(crate::tool_history::ToolRecord::Result(_))
            ))
            .count(),
        1
    );
    assert_eq!(done.context_recoveries[0].phase, Phase::Completed);
    f.no_request().await;
}

#[tokio::test]
async fn manual_retry_success_with_tools_establishes_new_recoverable_logical_request() {
    let mut f = Fixture::with_tools(true).await;
    f.actor
        .submit("Inspect and continue".into(), Lane::FollowUp)
        .unwrap();
    f.next().await;
    f.reject().await;
    f.next().await;
    f.reply(json!({"error":{"code":"rate_limit_exceeded","message":"Summary unavailable"}}))
        .await;
    f.settle().await;
    f.actor.retry().unwrap();
    f.next().await;
    f.reply(tool_reply()).await;
    f.next().await;
    f.reject().await;
    f.next().await;
    f.summary().await;
    f.next().await;
    f.reply(completed("Done")).await;
    let done = f.settle().await;
    assert_eq!(done.context_recoveries.len(), 2);
    assert_eq!(done.context_recoveries[0].phase, Phase::Failed);
    assert!(done.context_recoveries[0].resolved_reply_id.is_some());
    let resolved = done.context_recoveries[0]
        .resolved_reply_id
        .as_ref()
        .unwrap();
    assert_eq!(
        done.messages
            .iter()
            .filter(|row| &row.id == resolved)
            .count(),
        1
    );
    assert_eq!(
        done.messages
            .iter()
            .find(|row| &row.id == resolved)
            .unwrap()
            .usage["input_tokens"],
        100
    );
    assert_eq!(
        done.messages
            .iter()
            .find(|row| &row.id == resolved)
            .unwrap()
            .usage["output_tokens"],
        10
    );
    assert_eq!(done.context_recoveries[1].phase, Phase::Completed);
    assert_eq!(f.tool_calls.load(Ordering::SeqCst), 1);
    f.no_request().await;
}

#[tokio::test]
async fn unsuccessful_retry_replies_never_resolve_consumed_request_or_fence_storage() {
    for kind in ["disabled-tools", "incomplete", "empty", "incomplete-tools"] {
        let mut f = Fixture::with_tools(kind == "incomplete-tools").await;
        f.actor.submit("Continue".into(), Lane::FollowUp).unwrap();
        f.next().await;
        f.reject().await;
        f.next().await;
        f.summary().await;
        f.next().await;
        let reply = match kind {
            "disabled-tools" => tool_reply(),
            "incomplete-tools" => {
                let mut reply = tool_reply();
                reply["status"] = json!("incomplete");
                reply["incomplete_details"] = json!({"reason":"max_output_tokens"});
                reply
            }
            "incomplete" => {
                let mut reply = completed("partial answer");
                reply["status"] = json!("incomplete");
                reply["incomplete_details"] = json!({"reason":"max_output_tokens"});
                reply
            }
            _ => completed(""),
        };
        f.reply(reply).await;
        let done = f.settle().await;
        assert!(f.actor.inner.lock().unwrap().fatal.is_none(), "{kind}");
        assert_eq!(done.context_recoveries[0].phase, Phase::Failed, "{kind}");
        assert!(
            done.context_recoveries[0].resolved_reply_id.is_none(),
            "{kind}"
        );
        assert_eq!(f.tool_calls.load(Ordering::SeqCst), 0);
        if done.retry.is_some() {
            f.actor.retry().unwrap();
            f.next().await;
            f.reject().await;
            f.settle().await;
            assert_eq!(f.actor.snapshot().context_recoveries.len(), 1);
        }
        f.no_request().await;
    }
}

#[tokio::test]
async fn stop_during_automatic_retry_keeps_adopted_checkpoint_and_retry_identity() {
    let mut f = Fixture::new().await;
    f.actor.submit("Original".into(), Lane::FollowUp).unwrap();
    f.next().await;
    f.reject().await;
    f.next().await;
    f.summary().await;
    f.next().await;
    f.actor.stop().unwrap();
    f.reply(completed("late ignored response")).await;
    let done = f.settle().await;
    assert_eq!(done.context_recoveries[0].phase, Phase::Cancelled);
    assert!(done.context_recoveries[0].summary_id.is_some());
    assert!(done.retry.is_some());
    f.no_request().await;
}

#[cfg(feature = "synthetic-authority")]
#[tokio::test]
async fn stop_after_observed_rejection_keeps_summary_and_retry_usage() {
    for summary in [true, false] {
        let mut f = Fixture::new().await;
        f.actor.submit("Original".into(), Lane::FollowUp).unwrap();
        f.next().await;
        f.reject().await;
        f.next().await;
        if !summary {
            f.summary().await;
            f.next().await;
        }
        let phase = if summary {
            "recovery-summary-response"
        } else {
            "recovery-model-response"
        };
        let gate = f.actor.set_input_commit_gate_for_test(phase);
        f.reject().await;
        timeout(DEADLINE, gate.entered.notified()).await.unwrap();
        f.actor.stop().unwrap();
        gate.released.notify_one();
        let stopped = f.settle().await;
        let receipt = &stopped.context_recoveries[0];
        assert_eq!(receipt.phase, Phase::Cancelled);
        let observation = if summary {
            receipt.summary_rejection.as_ref()
        } else {
            receipt.retry_rejection.as_ref()
        }
        .unwrap();
        assert_eq!(
            observation.reported_usage.as_ref().unwrap()["input_tokens"],
            111
        );
        let row_id = if summary {
            &receipt.progress_id
        } else {
            receipt.retry_reply_id.as_ref().unwrap()
        };
        assert_eq!(
            stopped
                .messages
                .iter()
                .find(|row| &row.id == row_id)
                .unwrap()
                .usage["input_tokens"],
            111
        );
        f.no_request().await;
    }
}

// Swift SessionRun's pre-request threshold (compactContext(reason: "threshold")).
fn set_window(f: &Fixture, window: u32) {
    let config = f.actor.configuration().unwrap();
    let mut profile = config.profile.clone();
    profile.context_window = window;
    f.actor
        .configure(Arc::new(Configuration {
            profile,
            credential: Credential::new("fixture-secret-only".into()).unwrap(),
            connection: None,
        }))
        .unwrap();
}
fn is_summary_request(request: &Value) -> bool {
    request["tool_choice"] == "none"
        && request["input"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()
            .to_string()
            .contains("Create a concise continuation checkpoint")
}
const COMPACTED: &str = "The conversation history before this point was compacted";

#[tokio::test]
async fn crossing_the_threshold_summarizes_before_the_request_and_keeps_the_submission() {
    let mut f = Fixture::new().await;
    // About 23k estimated tokens of history cross a 40k window's threshold
    // (40000 - (10000 + instruction) - 400 - 10000) but fit beside the summary.
    set_window(&f, 40_000);
    let submission = Submission::new("Continue original task".into(), Lane::FollowUp);
    let id = submission.id.clone();
    f.actor.submit_identified(submission).unwrap();
    let summary = f.next().await;
    assert!(is_summary_request(&summary));
    assert!(summary.to_string().contains("Optional user focus: none"));
    // The summary sees the intact history, including the new input.
    assert!(summary.to_string().contains("Objective constraints."));
    assert!(summary.to_string().contains("Continue original task"));
    let running = f.actor.snapshot();
    let receipt = &running.context_recoveries[0];
    assert_eq!(receipt.reason, crate::context_recovery::Reason::Threshold);
    assert_eq!(receipt.phase, Phase::Summarizing);
    f.summary().await;
    let request = f.next().await;
    assert!(!is_summary_request(&request));
    let text = request.to_string();
    assert!(text.contains(COMPACTED) && text.contains("Objective retained."));
    assert!(text.contains("Continue original task"));
    assert!(!text.contains("Objective constraints."));
    f.reply(completed("Done after automatic compaction")).await;
    let done = f.settle().await;
    assert_eq!(done.state, RunState::Idle);
    assert_eq!(done.context_recoveries.len(), 1);
    let receipt = &done.context_recoveries[0];
    assert_eq!(receipt.turn_id, id);
    assert!(receipt.failure.is_none());
    assert_eq!(receipt.phase, Phase::Completed);
    assert_eq!((receipt.summary_attempts, receipt.retry_attempts), (1, 1));
    let deferred = done
        .messages
        .iter()
        .find(|row| row.id == receipt.failed_reply_id)
        .unwrap();
    assert_eq!(deferred.state, crate::context_recovery::DEFERRED_STATE);
    assert!(deferred.text.is_empty() && !deferred.replay_eligible);
    assert_eq!(
        done.messages
            .iter()
            .filter(|row| row.compaction.is_some())
            .count(),
        1
    );
    assert_eq!(done.messages.iter().filter(|row| row.id == id).count(), 1);
    assert_eq!(
        done.messages.last().unwrap().text,
        "Done after automatic compaction"
    );
    // The original transcript is retained; only replay changed.
    assert!(done.messages.iter().any(|row| row.id == "old-user"));
    f.no_request().await;
    f.actor.retire_and_wait().await.unwrap();
    let reopened = SessionStore::open(f.directory.path().join("session.json"))
        .unwrap()
        .snapshot();
    assert_eq!(reopened.context_recoveries[0].phase, Phase::Completed);
}

#[tokio::test]
async fn a_request_below_the_threshold_is_sent_without_compaction() {
    let mut f = Fixture::new().await;
    f.actor
        .submit("Short follow-up".into(), Lane::FollowUp)
        .unwrap();
    let request = f.next().await;
    assert!(!is_summary_request(&request));
    assert!(request.to_string().contains("Objective constraints."));
    f.reply(completed("Done")).await;
    let done = f.settle().await;
    assert!(done.context_recoveries.is_empty());
    f.no_request().await;
}

#[tokio::test]
async fn nothing_compactable_sends_the_intact_request() {
    let mut f = Fixture::new().await;
    f.actor
        .inner
        .lock()
        .unwrap()
        .store
        .transact(|session| {
            session.messages.clear();
            Ok(())
        })
        .unwrap();
    set_window(&f, 40_000);
    // One unanswered input over the threshold is required and cannot be summarized.
    f.actor
        .submit("Large input. ".repeat(6500), Lane::FollowUp)
        .unwrap();
    let request = f.next().await;
    assert!(!is_summary_request(&request));
    f.reply(completed("Done")).await;
    let done = f.settle().await;
    assert_eq!(done.state, RunState::Idle);
    assert!(done.context_recoveries.is_empty());
    f.no_request().await;
}

#[tokio::test]
async fn stop_during_the_automatic_summary_keeps_history_and_retry_resends_intact() {
    let mut f = Fixture::new().await;
    set_window(&f, 40_000);
    f.actor
        .submit("Original retry identity".into(), Lane::FollowUp)
        .unwrap();
    assert!(is_summary_request(&f.next().await));
    let original = f.actor.snapshot().active.unwrap().id;
    f.actor.stop().unwrap();
    f.summary().await;
    let stopped = f.settle().await;
    assert_eq!(stopped.state, RunState::Paused);
    assert_eq!(stopped.retry.as_ref().unwrap().id, original);
    assert_eq!(stopped.context_recoveries[0].phase, Phase::Cancelled);
    assert!(stopped.messages.iter().all(|row| row.compaction.is_none()));
    f.no_request().await;
    // Swift's resumingFailedRequest: an explicit Retry repeats the request
    // without compacting first.
    f.actor.retry().unwrap();
    let request = f.next().await;
    assert!(!is_summary_request(&request));
    assert!(request.to_string().contains("Objective constraints."));
    f.reply(completed("Done")).await;
    let done = f.settle().await;
    assert_eq!(done.state, RunState::Idle);
    assert_eq!(done.context_recoveries.len(), 1);
    f.no_request().await;
}

#[tokio::test]
async fn crash_during_the_automatic_summary_reopens_with_original_history() {
    let mut f = Fixture::new().await;
    set_window(&f, 40_000);
    f.actor
        .submit("Interrupted by a crash".into(), Lane::FollowUp)
        .unwrap();
    assert!(is_summary_request(&f.next().await));
    // The summary request was admitted after its durable receipt: this is
    // exactly what a crash leaves on disk.
    let crashed = f.directory.path().join("crashed.json");
    std::fs::copy(f.directory.path().join("session.json"), &crashed).unwrap();
    let reopened = SessionStore::open(&crashed).unwrap().snapshot();
    let receipt = &reopened.context_recoveries[0];
    assert_eq!(receipt.reason, crate::context_recovery::Reason::Threshold);
    assert_eq!(receipt.phase, Phase::Interrupted);
    assert_eq!(reopened.state, RunState::Paused);
    assert!(reopened.queue_paused && reopened.active.is_none());
    assert!(reopened.messages.iter().all(|row| row.compaction.is_none()));
    assert!(
        crate::compaction::active_context(&reopened.messages)
            .unwrap()
            .iter()
            .any(|row| row.id == "old-user")
    );
    f.actor.stop().unwrap();
    f.summary().await;
    f.settle().await;
}

#[tokio::test]
async fn a_tool_continuation_crossing_the_threshold_compacts_without_replaying_the_tool() {
    let mut f = Fixture::with_tools(true).await;
    // A long listing: about 10k estimated tokens of tool output.
    for index in 0..200 {
        std::fs::write(
            f.directory
                .path()
                .join(format!("{}{index}", "Observed-evidence-".repeat(10))),
            "",
        )
        .unwrap();
    }
    f.actor
        .submit("Inspect and continue".into(), Lane::FollowUp)
        .unwrap();
    let first = f.next().await;
    assert!(!is_summary_request(&first));
    f.reply(json!({"id":"tool-response","status":"completed","output":[{"type":"function_call","id":"read-item","call_id":"read-call","name":"ls","arguments":"{\"path\":\".\"}"}]}))
        .await;
    let summary = f.next().await;
    assert!(is_summary_request(&summary));
    assert!(summary.to_string().contains("Observed-evidence"));
    assert_eq!(f.tool_calls.load(Ordering::SeqCst), 1);
    f.summary().await;
    let continuation = f.next().await;
    assert!(!is_summary_request(&continuation));
    assert!(continuation.to_string().contains(COMPACTED));
    f.reply(completed("Done")).await;
    let done = f.settle().await;
    assert_eq!(f.tool_calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        done.messages
            .iter()
            .filter(|row| matches!(
                row.tool_record,
                Some(crate::tool_history::ToolRecord::Result(_))
            ))
            .count(),
        1
    );
    assert_eq!(done.context_recoveries[0].phase, Phase::Completed);
    assert_eq!(
        done.context_recoveries[0].reason,
        crate::context_recovery::Reason::Threshold
    );
    f.no_request().await;
}

#[tokio::test]
async fn a_replayable_history_compaction_cannot_group_still_sends_its_request() {
    use crate::tool_history::{AssistantRecord, Completion, ReplayBinding, ToolRecord};
    let mut f = Fixture::new().await;
    let profile = f.actor.configuration().unwrap().profile.clone();
    f.actor
        .inner
        .lock()
        .unwrap()
        .store
        .transact(|session| {
            // A retained call whose result never arrived replays as pi's
            // "No result provided" but cannot be grouped for compaction.
            let mut call = row("call-owner", "assistant", String::new());
            call.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
                tool_batch_timing: None,
                completion: Completion::Complete,
                calls: vec![crate::provider::ToolCall {
                    id: "lost-call".into(),
                    name: "ls".into(),
                    arguments: json!({"path":"."}),
                }],
                binding: ReplayBinding::from_profile(&profile)?,
                provider_items: vec![],
            }));
            session.messages.push(call);
            Ok(())
        })
        .unwrap();
    f.actor
        .submit("Short follow-up".into(), Lane::FollowUp)
        .unwrap();
    let request = f.next().await;
    assert!(!is_summary_request(&request));
    assert!(request.to_string().contains("No result provided"));
    f.reply(completed("Done")).await;
    assert_eq!(f.settle().await.state, RunState::Idle);
}

fn large_usage(text: &str) -> Value {
    let mut reply = completed(text);
    reply["usage"] = json!({"input_tokens":60000,"output_tokens":100,"total_tokens":60100});
    reply
}

/// Swift sizes the next request from the last reply's reported tokens when
/// that reply measured the same prefix (`RequestContextCounter.count`): a
/// reported 60K-token context crosses the threshold that ~23K estimated
/// characters do not.
#[tokio::test]
async fn the_last_reply_reported_usage_sizes_the_threshold_check() {
    let mut f = Fixture::new().await;
    f.actor.submit("First".into(), Lane::FollowUp).unwrap();
    let first = f.next().await;
    assert!(!is_summary_request(&first));
    f.reply(large_usage("Reported a large context")).await;
    let done = f.settle().await;
    let record = done.requests.last().unwrap();
    assert!(record.usage_binding.is_some());
    assert_eq!(record.usage.input, Some(60_000));
    f.actor.submit("Second".into(), Lane::FollowUp).unwrap();
    let second = f.next().await;
    assert!(
        is_summary_request(&second),
        "usage baseline crossed the threshold"
    );
    f.summary().await;
    let request = f.next().await;
    assert!(!is_summary_request(&request));
    f.reply(completed("Done")).await;
    let done = f.settle().await;
    let purposes: Vec<_> = done.requests.iter().map(|r| r.purpose.as_str()).collect();
    assert_eq!(purposes, ["turn", "compaction", "turn"]);
}

/// A reply whose request had another prefix (here other request headers) does
/// not measure the next request: its size falls back to the character estimate.
#[tokio::test]
async fn a_usage_baseline_from_another_prefix_is_not_used() {
    let mut f = Fixture::new().await;
    f.actor.submit("First".into(), Lane::FollowUp).unwrap();
    f.next().await;
    f.reply(large_usage("Reported a large context")).await;
    f.settle().await;
    let config = f.actor.configuration().unwrap();
    let mut profile = config.profile.clone();
    profile
        .headers
        .insert("x-fixture-route".into(), "other".into());
    f.actor
        .configure(Arc::new(Configuration {
            profile,
            credential: Credential::new("fixture-secret-only".into()).unwrap(),
            connection: None,
        }))
        .unwrap();
    f.actor.submit("Second".into(), Lane::FollowUp).unwrap();
    let second = f.next().await;
    assert!(!is_summary_request(&second));
    f.reply(completed("Done")).await;
    f.settle().await;
}

/// Every request the chat made is kept with it, failed ones included, and
/// survives reopening (version 11).
#[tokio::test]
async fn each_request_is_recorded_with_its_usage_and_survives_reopen() {
    let mut f = Fixture::new().await;
    let submission = Submission::new("Continue original task".into(), Lane::FollowUp);
    let id = submission.id.clone();
    f.actor.submit_identified(submission).unwrap();
    f.next().await;
    f.reject().await;
    f.next().await;
    f.summary().await;
    f.next().await;
    f.reply(completed("Done after compaction")).await;
    let done = f.settle().await;
    assert_eq!(done.version, 11);
    let outcomes: Vec<_> = done
        .requests
        .iter()
        .map(|r| (r.purpose.as_str(), r.outcome.as_str(), r.usage.input))
        .collect();
    assert_eq!(
        outcomes,
        [
            ("turn", "failed", Some(111)),
            ("compaction", "completed", Some(100)),
            ("turn", "completed", Some(100)),
        ]
    );
    assert!(
        done.requests
            .iter()
            .all(|r| r.turn.as_deref() == Some(id.as_str()))
    );
    let reply = done.messages.last().unwrap();
    assert_eq!(done.requests[2].reply.as_deref(), Some(reply.id.as_str()));
    assert!(
        done.requests
            .iter()
            .all(|r| r.ttft_ms.is_some() && r.wall > 0.0)
    );
    let totals = done.request_totals();
    assert_eq!((totals.requests, totals.turn_count), (3, 1));
    assert_eq!(totals.output.value(), Some(20.0));
    f.actor.retire_and_wait().await.unwrap();
    let reopened = SessionStore::open(f.directory.path().join("session.json"))
        .unwrap()
        .snapshot();
    let identity = |s: &Session| {
        s.requests
            .iter()
            .map(|r| {
                (
                    r.id.clone(),
                    r.outcome.clone(),
                    r.usage,
                    r.usage_binding.clone(),
                )
            })
            .collect::<Vec<_>>()
    };
    assert_eq!(identity(&reopened), identity(&done));
    assert_eq!(reopened.request_totals().requests, 3);
}
