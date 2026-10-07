use bello_agent_core::{Credential, Delta, Error, Profile, ResponsesClient};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::oneshot,
};
use tokio_util::sync::CancellationToken;
fn profile(url: String) -> Profile {
    serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":url,"contextWindow":32000,"maxOutputTokens":4096})).unwrap()
}

fn typed_fixture_history(profile: &Profile) -> Vec<bello_agent_core::Message> {
    use bello_agent_core::{
        Message,
        provider::ToolCall,
        tool_history::{
            AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
        },
    };
    let mut assistant: Message = serde_json::from_value(json!({"id":"fixture-assistant","role":"assistant","text":"","reasoning":"","replay_eligible":true,"state":"completed","usage":null,"model":null})).unwrap();
    assistant.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
        completion: Completion::Complete,
        calls: vec![ToolCall {
            id: "fixture-call".into(),
            name: "ls".into(),
            arguments: json!({"path":"fixture-only"}),
        }],
        binding: ReplayBinding::from_profile(profile).unwrap(),
        provider_items: vec![],
    }));
    let mut result: Message = serde_json::from_value(json!({"id":"fixture-result","role":"toolResult","text":"世界\n😀","reasoning":"","replay_eligible":true,"state":"completed","usage":null,"model":null})).unwrap();
    result.tool_record = Some(ToolRecord::Result(ResultRecord {
        assistant_id: "fixture-assistant".into(),
        call_id: "fixture-call".into(),
        is_error: false,
        outcome: ToolOutcome::Completed,
        content: None,
    }));
    vec![assistant, result]
}
async fn server(
    body: String,
    content_type: &'static str,
    status: &'static str,
) -> (String, oneshot::Receiver<Vec<u8>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (tx, rx) = oneshot::channel();
    tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut raw = Vec::new();
        let mut buf = [0; 4096];
        loop {
            let n = socket.read(&mut buf).await.unwrap();
            if n == 0 {
                break;
            }
            raw.extend_from_slice(&buf[..n]);
            if let Some(end) = raw.windows(4).position(|v| v == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&raw[..end]).to_lowercase();
                let length = headers
                    .lines()
                    .find_map(|l| l.strip_prefix("content-length: "))
                    .unwrap_or("0")
                    .parse::<usize>()
                    .unwrap();
                if raw.len() >= end + 4 + length {
                    break;
                }
            }
        }
        let _ = tx.send(raw);
        let response = format!(
            "HTTP/1.1 {status}\r\ncontent-type: {content_type}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
            body.len()
        );
        socket.write_all(response.as_bytes()).await.unwrap();
        // Every byte may be its own transport chunk, including UTF-8 and CRLF.
        for byte in body.bytes() {
            if socket.write_all(&[byte]).await.is_err() {
                break;
            }
        }
    });
    (url, rx)
}

#[tokio::test]
async fn typed_history_reaches_loopback_as_ordered_wire_data_without_tool_schema() {
    let response = json!({"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"fixture answer"}]}]}).to_string();
    let (url, captured) = server(response, "application/json", "200 OK").await;
    let profile = profile(url);
    let history = typed_fixture_history(&profile);
    let before = serde_json::to_value(&history).unwrap();
    let reply = ResponsesClient::new()
        .unwrap()
        .complete(
            &profile,
            &Credential::new("fake-only".into()).unwrap(),
            &history,
            "",
            "fixture-session",
            "fixture-turn",
            CancellationToken::new(),
            |_| Ok(()),
        )
        .await
        .unwrap();
    assert_eq!(reply.text, "fixture answer");
    assert!(reply.calls.is_empty());
    let request = String::from_utf8(captured.await.unwrap()).unwrap();
    let body: Value = serde_json::from_str(request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert!(body.get("tools").is_none());
    assert_eq!(
        body["input"],
        json!([
            {"type":"function_call","call_id":"fixture-call","name":"ls","arguments":"{\"path\":\"fixture-only\"}"},
            {"type":"function_call_output","call_id":"fixture-call","output":"世界\n😀"}
        ])
    );
    assert_eq!(serde_json::to_value(history).unwrap(), before);
}

#[tokio::test]
async fn same_profile_opaque_replay_fails_before_any_http_connection() {
    use bello_agent_core::tool_history::ToolRecord;
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let profile = profile(format!("http://{}", listener.local_addr().unwrap()));
    let mut history = typed_fixture_history(&profile);
    if let Some(ToolRecord::Assistant(record)) = &mut history[0].tool_record {
        record.provider_items = vec![
            json!({"type":"reasoning","encrypted_content":"synthetic opaque bytes"}),
            json!({"type":"function_call","call_id":"fixture-call","name":"ls","arguments":"{\"path\":\"fixture-only\"}"}),
        ];
    }
    let before = serde_json::to_value(&history).unwrap();
    let error = ResponsesClient::new()
        .unwrap()
        .complete(
            &profile,
            &Credential::new("fake-only".into()).unwrap(),
            &history,
            "",
            "fixture-session",
            "fixture-turn",
            CancellationToken::new(),
            |_| Ok(()),
        )
        .await
        .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("Provider-specific reasoning requires")
    );
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    assert_eq!(serde_json::to_value(history).unwrap(), before);
}
#[tokio::test]
async fn real_loopback_stream_and_request_contract() {
    let body = concat!(
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"héllo\"}\r\n\r\n",
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"héllo\"}]}],\"usage\":{\"input_tokens\":12,\"output_tokens\":2}}}\n\n"
    );
    let (url, request) = server(body.into(), "text/event-stream", "200 OK").await;
    let profile = profile(url);
    let secret = Credential::new("fake-only".into()).unwrap();
    let mut deltas = Vec::new();
    let reply = ResponsesClient::new()
        .unwrap()
        .complete(
            &profile,
            &secret,
            &[],
            "instruction",
            "session-1",
            "turn-1",
            CancellationToken::new(),
            |d| {
                deltas.push(d);
                Ok(())
            },
        )
        .await
        .unwrap();
    assert_eq!(reply.text, "héllo");
    assert_eq!(deltas, vec![Delta::Text("héllo".into())]);
    let request = request.await.unwrap();
    let raw = String::from_utf8(request).unwrap();
    assert!(raw.starts_with("POST /v1/responses "));
    assert!(raw.contains("x-session-id: session-1"));
    assert!(raw.contains("x-turn-id: turn-1"));
    let value: Value = serde_json::from_str(raw.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(value["store"], false);
    assert_eq!(value["disable_fallbacks"], true);
    assert!(value["max_output_tokens"].is_null());
    assert_eq!(value["metadata"]["session_id"], "session-1");
    assert_eq!(value["input"][0]["role"], "system");
}
#[tokio::test]
async fn eof_without_terminal_is_error_even_after_text() {
    let (url, _) = server(
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".into(),
        "text/event-stream",
        "200 OK",
    )
    .await;
    let result = ResponsesClient::new()
        .unwrap()
        .complete(
            &profile(url),
            &Credential::new("fake".into()).unwrap(),
            &[],
            "",
            "session",
            "turn",
            CancellationToken::new(),
            |_| Ok(()),
        )
        .await;
    assert!(matches!(result, Err(Error::IncompleteStream)));
}
#[tokio::test]
async fn errors_redact_credential_and_custom_headers() {
    let (url, _) = server(
        "bad secret-key and header-value".into(),
        "text/plain",
        "401 Unauthorized",
    )
    .await;
    let mut profile = profile(url);
    profile
        .headers
        .insert("x-fixture".into(), "header-value".into());
    let error = ResponsesClient::new()
        .unwrap()
        .complete(
            &profile,
            &Credential::new("secret-key".into()).unwrap(),
            &[],
            "",
            "session",
            "turn",
            CancellationToken::new(),
            |_| Ok(()),
        )
        .await
        .unwrap_err()
        .to_string();
    assert!(!error.contains("secret-key"));
    assert!(!error.contains("header-value"));
    assert!(error.contains("401"));
}
#[tokio::test]
async fn json_response_fallback_requires_success_terminal() {
    let (url,_)=server(json!({"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"JSON answer"}]}]}).to_string(),"application/json","200 OK").await;
    let reply = ResponsesClient::new()
        .unwrap()
        .complete(
            &profile(url),
            &Credential::new("fake".into()).unwrap(),
            &[],
            "",
            "session",
            "turn",
            CancellationToken::new(),
            |_| Ok(()),
        )
        .await
        .unwrap();
    assert_eq!(reply.text, "JSON answer");
}
#[tokio::test]
async fn cancellation_interrupts_waiting_for_response_head() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (accepted, ready) = oneshot::channel();
    let server = tokio::spawn(async move {
        let (_socket, _) = listener.accept().await.unwrap();
        accepted.send(()).unwrap();
        std::future::pending::<()>().await;
    });
    let cancel = CancellationToken::new();
    let stop = cancel.clone();
    tokio::spawn(async move {
        ready.await.unwrap();
        stop.cancel();
    });
    let result = tokio::time::timeout(
        Duration::from_secs(2),
        ResponsesClient::new().unwrap().complete(
            &profile(url),
            &Credential::new("fake".into()).unwrap(),
            &[],
            "",
            "session",
            "turn",
            cancel,
            |_| Ok(()),
        ),
    )
    .await
    .unwrap();
    assert!(matches!(result, Err(Error::Cancelled)));
    server.abort();
}
