//! Bounded Streamable HTTP, source MCP.swift272–349. No GET channel, proxy,
//! redirect, client capability or implicit network retry is installed.
use super::{McpError, McpResult};
use crate::project_authority::mcp::ServerConfiguration;
use futures_util::StreamExt;
use reqwest::{
    Client,
    header::{HeaderMap, HeaderName, HeaderValue},
};
use serde_json::{Value, json};
use std::{sync::Mutex, time::Duration};
use tokio_util::sync::CancellationToken;
const MAX_BODY: usize = 4 * 1024 * 1024;

pub(super) struct Http {
    client: Client,
    url: String,
    headers: HeaderMap,
    timeout: Duration,
    state: Mutex<State>,
}
#[derive(Clone)]
struct State {
    session: Option<String>,
    version: String,
    expired: bool,
    generation: u64,
    epoch: u64,
}
impl Http {
    pub fn expired(&self) -> bool {
        self.state.lock().map_or(true, |s| s.expired)
    }
    pub fn generation(&self) -> u64 {
        self.state.lock().map_or(u64::MAX, |s| s.generation)
    }
    pub fn new(config: &ServerConfiguration) -> McpResult<Self> {
        let client = Client::builder()
            .retry(reqwest::retry::never())
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| McpError::rejected("mcp_unavailable", "MCP HTTP client is unavailable"))?;
        let mut headers = HeaderMap::new();
        for (key, value) in &config.headers {
            headers.insert(
                HeaderName::from_bytes(key.as_bytes()).map_err(|_| McpError::config())?,
                HeaderValue::from_str(value).map_err(|_| McpError::config())?,
            );
        }
        headers.insert("content-type", HeaderValue::from_static("application/json"));
        headers.insert(
            "accept",
            HeaderValue::from_static("application/json, text/event-stream"),
        );
        Ok(Self {
            client,
            url: config.url.clone(),
            headers,
            timeout: Duration::from_secs(config.timeout_seconds),
            state: Mutex::new(State {
                session: None,
                version: "2025-11-25".into(),
                expired: false,
                generation: 0,
                epoch: 0,
            }),
        })
    }
    pub async fn request(
        &self,
        method: &str,
        params: Value,
        cancel: &CancellationToken,
    ) -> McpResult<Value> {
        let id = uuid::Uuid::new_v4().to_string();
        let result = self
            .exchange(
                json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}),
                Some(&id),
                cancel,
            )
            .await?;
        if method == "initialize"
            && let Some(version) = result["protocolVersion"].as_str()
        {
            self.state.lock().map_err(|_| McpError::protocol())?.version = version.into();
        }
        Ok(result)
    }
    pub async fn notify(&self, method: &str, cancel: &CancellationToken) -> McpResult<()> {
        self.exchange(
            json!({"jsonrpc":"2.0","method":method,"params":{}}),
            None,
            cancel,
        )
        .await
        .map(|_| ())
    }
    async fn exchange(
        &self,
        message: Value,
        expected: Option<&str>,
        cancel: &CancellationToken,
    ) -> McpResult<Value> {
        if cancel.is_cancelled() {
            return Err(McpError::cancelled(false));
        }
        let timeout = self.timeout;
        tokio::select! {
            biased;
            _=cancel.cancelled()=>Err(McpError::cancelled(true)),
            result=tokio::time::timeout(timeout,self.exchange_inner(message,expected))=>result.unwrap_or_else(|_|Err(McpError::unknown("mcp_timeout","MCP request timed out; effects may have occurred. No automatic replay.")))
        }
    }
    async fn exchange_inner(&self, message: Value, expected: Option<&str>) -> McpResult<Value> {
        let initializing = message["method"] == "initialize";
        let bytes = serde_json::to_vec(&message).map_err(|_| McpError::config())?;
        if bytes.len() > MAX_BODY {
            return Err(McpError::rejected(
                "mcp_arguments",
                "MCP request exceeds 4 MiB",
            ));
        }
        let mut headers = self.headers.clone();
        let snapshot = self.state.lock().map_err(|_| McpError::protocol())?.clone();
        if snapshot.expired && !initializing {
            return Err(McpError::rejected(
                "mcp_session_expired",
                "MCP session expired before dispatch",
            ));
        }
        let sent_session = snapshot.session.is_some();
        if let Some(session) = &snapshot.session {
            headers.insert(
                "mcp-session-id",
                HeaderValue::from_str(session).map_err(|_| McpError::protocol())?,
            );
        }
        if !initializing {
            headers.insert(
                "mcp-protocol-version",
                HeaderValue::from_str(&snapshot.version).map_err(|_| McpError::protocol())?,
            );
        }
        let response=self.client.post(&self.url).headers(headers).body(bytes).send().await
            .map_err(|_|McpError::unknown("mcp_transport","MCP connection failed or disconnected; effects may have occurred. No automatic replay."))?;
        let status = response.status().as_u16();
        if !(200..300).contains(&status) {
            if status == 404 && sent_session && !initializing {
                let mut state = self.state.lock().map_err(|_| McpError::protocol())?;
                if state.epoch == snapshot.epoch && state.session == snapshot.session {
                    state.expired = true;
                    state.session = None;
                    state.epoch = state.epoch.checked_add(1).ok_or_else(McpError::limit)?;
                }
                return Err(McpError::rejected(
                    "mcp_session_expired",
                    "MCP server forgot this session (HTTP 404); this request was not processed",
                ));
            }
            if [400, 401, 403, 404, 405, 429].contains(&status) {
                return Err(McpError::rejected(
                    "mcp_rejected",
                    format!("MCP server rejected HTTP {status}; request was not executed"),
                ));
            }
            return Err(McpError::unknown(
                "mcp_http",
                format!("MCP HTTP {status}; effects may have occurred. No automatic replay."),
            ));
        }
        let mut response_epoch = snapshot.epoch;
        if let Some(session) = response.headers().get("mcp-session-id") {
            let session = session.to_str().map_err(|_| McpError::protocol())?;
            if session.is_empty()
                || session.len() > 1024
                || session.bytes().any(|b| !(33..=126).contains(&b))
            {
                return Err(McpError::protocol());
            }
            let mut state = self.state.lock().map_err(|_| McpError::protocol())?;
            if state.epoch == snapshot.epoch && state.session == snapshot.session && !state.expired
            {
                if state.session.as_deref() != Some(session) {
                    state.epoch = state.epoch.checked_add(1).ok_or_else(McpError::limit)?;
                    state.session = Some(session.into());
                }
                response_epoch = state.epoch;
            }
        }
        if expected.is_none() && [202, 204].contains(&status) {
            return Ok(json!({}));
        }
        if response
            .content_length()
            .is_some_and(|length| length > MAX_BODY as u64)
        {
            return Err(McpError::limit());
        }
        let sse = response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.to_ascii_lowercase().contains("text/event-stream"));
        let mut stream = response.bytes_stream();
        let mut parser = crate::sse::Parser::default();
        let mut body = Vec::new();
        let mut received = 0usize;
        let mut events = 0usize;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|_| {
                McpError::unknown(
                    "mcp_transport",
                    "MCP response disconnected; effects may have occurred. No automatic replay.",
                )
            })?;
            received = received
                .checked_add(chunk.len())
                .filter(|n| *n <= MAX_BODY)
                .ok_or_else(McpError::limit)?;
            if sse {
                for event in parser.feed(&chunk).map_err(|_| McpError::protocol())? {
                    events += 1;
                    if events > 2048 {
                        return Err(McpError::limit());
                    }
                    if event.data.trim().is_empty() {
                        continue;
                    }
                    let value: Value =
                        serde_json::from_str(&event.data).map_err(|_| McpError::protocol())?;
                    validate_message(&value)?;
                    if value.get("id").and_then(Value::as_str) == expected && expected.is_some() {
                        return response_value(value);
                    }
                    if value.get("method").is_some() {
                        if value.get("id").is_some_and(|v| !v.is_null()) {
                            return Err(McpError::unknown(
                                "mcp_capability",
                                "MCP server requested an unsupported client capability",
                            ));
                        }
                        if value["method"] == "notifications/tools/list_changed" {
                            let mut state = self.state.lock().map_err(|_| McpError::protocol())?;
                            if state.epoch == response_epoch && !state.expired {
                                state.generation = state
                                    .generation
                                    .checked_add(1)
                                    .ok_or_else(McpError::limit)?;
                            }
                        }
                    }
                }
            } else {
                body.extend_from_slice(&chunk)
            }
        }
        if expected.is_none() {
            return Ok(json!({}));
        }
        if sse || body.is_empty() {
            return Err(McpError::unknown(
                "mcp_incomplete",
                "MCP stream ended without its response; outcome is unknown. No automatic replay.",
            ));
        }
        let value: Value = serde_json::from_slice(&body).map_err(|_| McpError::protocol())?;
        if value.get("id").and_then(Value::as_str) != expected {
            return Err(McpError::protocol());
        }
        response_value(value)
    }
}
fn validate_message(value: &Value) -> McpResult<()> {
    if !value.is_object() || value["jsonrpc"] != "2.0" {
        return Err(McpError::protocol());
    }
    Ok(())
}
fn response_value(value: Value) -> McpResult<Value> {
    validate_message(&value)?;
    if value.get("method").is_some()
        || value.get("result").is_some() == value.get("error").is_some()
    {
        return Err(McpError::protocol());
    }
    if let Some(error) = value.get("error") {
        let code = error["code"].as_i64().ok_or_else(McpError::protocol)?;
        if [-32700, -32600, -32601, -32602].contains(&code) {
            return Err(McpError::rejected(
                "mcp_rejected",
                format!("MCP server rejected JSON-RPC {code}; request was not executed"),
            ));
        }
        return Err(McpError::unknown(
            "mcp_remote_error",
            format!("MCP JSON-RPC error {code}; effects may have occurred. No automatic replay."),
        ));
    }
    Ok(value["result"].clone())
}
