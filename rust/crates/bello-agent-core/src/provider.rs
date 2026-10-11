use crate::{
    Credential, Error, Message, Profile, Result, accounting::AttemptObservation, invalid,
    profile::correlation_value, sse::Parser,
};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::BTreeMap, io::Write, time::Duration};
use tokio_util::sync::CancellationToken;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum Delta {
    Text(String),
    Reasoning(String),
    Tool {
        id: String,
        name: String,
        arguments: String,
    },
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Reply {
    pub text: String,
    pub reasoning: String,
    pub calls: Vec<ToolCall>,
    pub usage: Value,
    pub status: String,
    pub provider_items: Vec<Value>,
}

/// The request preserves the source app's Responses correlation and budget rules.
/// This compatibility entry point intentionally offers no tools. The explicit
/// trusted Controller uses request_body_with_tools; history never dispatches work.
pub fn request_body(
    profile: &Profile,
    messages: &[Message],
    instructions: &str,
    session_id: &str,
) -> Result<Value> {
    request_body_with_tools(profile, messages, instructions, session_id, &[])
}

/// Definitions are supplied only by an explicitly trusted host configuration.
pub fn request_body_with_tools(
    profile: &Profile,
    messages: &[Message],
    instructions: &str,
    session_id: &str,
    tools: &[crate::tools::ToolDefinition],
) -> Result<Value> {
    profile.validate()?;
    let mut input = Vec::new();
    if !instructions.is_empty() {
        input.push(json!({"role":if profile.reasoning && profile.compat.supports_developer_role!=Some(false) {"developer"} else {"system"},"content":instructions}));
    }
    input.extend(crate::tool_history::project(messages, profile)?);
    let mut body = json!({"model":profile.model_id,"stream":true,"store":false,"metadata":{"session_id":correlation_value(session_id)},"prompt_cache_key":session_id.chars().take(64).collect::<String>(),"input":input});
    if !profile.compat.allow_fallbacks {
        body["disable_fallbacks"] = json!(true);
    }
    if let Some(cap) = profile.wire_output_limit() {
        body["max_output_tokens"] = json!(cap);
    }
    if profile.reasoning {
        match profile.thinking_level.as_str() {
            "default" => body["include"] = json!(["reasoning.encrypted_content"]),
            "off" => body["reasoning"] = json!({"effort":"none"}),
            effort => {
                body["reasoning"] = json!({"effort":effort,"summary":"auto"});
                body["include"] = json!(["reasoning.encrypted_content"]);
            }
        }
    }
    if !tools.is_empty() {
        body["tools"] = Value::Array(
            tools
                .iter()
                .map(|tool| {
                    json!({
                        "type":"function", "name":tool.name,
                        "description":tool.description, "parameters":tool.schema
                    })
                })
                .collect(),
        );
    }
    Ok(body)
}

pub(crate) const MAX_REQUEST_BYTES: usize = 32 * 1024 * 1024;

/// Apply the same wire-size bound to dispatch and read-only context previews.
/// Stop serialization at the limit rather than allocating an oversized buffer.
pub(crate) fn serialize_request(body: &Value) -> Result<Vec<u8>> {
    serialize_bounded(body, false)
}

pub(crate) fn serialize_bounded(body: &Value, pretty: bool) -> Result<Vec<u8>> {
    #[derive(Default)]
    struct BoundedBytes(Vec<u8>);
    impl Write for BoundedBytes {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if bytes.len() > MAX_REQUEST_BYTES.saturating_sub(self.0.len()) {
                return Err(std::io::Error::other("Serialized request exceeds 32 MiB"));
            }
            self.0.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut buffer = BoundedBytes::default();
    let result = if pretty {
        serde_json::to_writer_pretty(&mut buffer, body)
    } else {
        serde_json::to_writer(&mut buffer, body)
    };
    if let Err(error) = result {
        if error.is_io() {
            return Err(invalid("Serialized request exceeds 32 MiB"));
        }
        return Err(error.into());
    }
    Ok(buffer.0)
}

#[derive(Default)]
pub struct Accumulator {
    root: Option<Value>,
    items: BTreeMap<usize, Value>,
    arguments: BTreeMap<usize, String>,
    thinking: BTreeMap<usize, String>,
    reported_usage: Option<Value>,
}
impl Accumulator {
    pub fn consume(&mut self, value: Value) -> Result<Vec<Delta>> {
        let kind = value["type"].as_str().unwrap_or("");
        if kind.starts_with("response.")
            || kind == "error"
            || (kind.is_empty() && !value["error"].is_null())
        {
            self.observe_usage(&value);
        }
        if kind == "error"
            || kind == "response.failed"
            || kind.is_empty() && !value["error"].is_null()
        {
            return Err(self.rejection_with_usage(&value));
        }
        let mut out = Vec::new();
        match kind {
            "response.output_item.added" | "response.output_item.done" => {
                let index = value["output_index"]
                    .as_u64()
                    .ok_or_else(|| invalid("Missing output item index"))?
                    as usize;
                let item = value["item"].clone();
                if item["type"] == "function_call" {
                    out.push(Delta::Tool {
                        id: string(&item["call_id"]),
                        name: string(&item["name"]),
                        arguments: String::new(),
                    });
                }
                self.items.insert(index, item);
            }
            "response.output_text.delta" | "response.refusal.delta" => {
                out.push(Delta::Text(string(&value["delta"])))
            }
            "response.reasoning_summary_text.delta" | "response.reasoning_text.delta" => {
                let text = string(&value["delta"]);
                if let Some(index) = value["output_index"].as_u64() {
                    self.thinking
                        .entry(index as usize)
                        .or_default()
                        .push_str(&text);
                }
                out.push(Delta::Reasoning(text));
            }
            "response.reasoning_summary_part.done" => {
                if let Some(index) = value["output_index"].as_u64() {
                    self.thinking
                        .entry(index as usize)
                        .or_default()
                        .push_str("\n\n");
                }
            }
            "response.function_call_arguments.delta" => {
                let index = value["output_index"]
                    .as_u64()
                    .map(|n| n as usize)
                    .or_else(|| {
                        self.items
                            .iter()
                            .find(|(_, v)| v["id"] == value["item_id"])
                            .map(|(i, _)| *i)
                    })
                    .ok_or_else(|| invalid("Tool arguments preceded their item"))?;
                let item = self
                    .items
                    .get(&index)
                    .ok_or_else(|| invalid("Tool arguments preceded their item"))?;
                let text = string(&value["delta"]);
                let args = self.arguments.entry(index).or_default();
                args.push_str(&text);
                if args.len() > 2 * 1024 * 1024 {
                    return Err(invalid("Tool arguments exceed 2 MiB"));
                }
                out.push(Delta::Tool {
                    id: string(&item["call_id"]),
                    name: string(&item["name"]),
                    arguments: text,
                });
            }
            "response.function_call_arguments.done" => {
                if let (Some(index), Some(args)) =
                    (value["output_index"].as_u64(), value["arguments"].as_str())
                {
                    if args.len() > 2 * 1024 * 1024 {
                        return Err(invalid("Tool arguments exceed 2 MiB"));
                    }
                    self.arguments.insert(index as usize, args.into());
                }
            }
            "response.completed" | "response.incomplete" => {
                self.accept_json(value["response"].clone())?
            }
            _ => {}
        }
        Ok(out)
    }
    pub fn accept_json(&mut self, value: Value) -> Result<()> {
        if value["status"] == "failed"
            || !value["error"].is_null()
            || matches!(value["type"].as_str(), Some("error" | "response.failed"))
        {
            return Err(self.rejection_with_usage(&value));
        }
        if !matches!(value["status"].as_str(), Some("completed" | "incomplete")) {
            return Err(Error::Provider(
                "Provider reported an unsuccessful response".into(),
            ));
        }
        self.root = Some(value);
        Ok(())
    }
    fn observe_usage(&mut self, value: &Value) {
        for usage in [&value["usage"], &value["response"]["usage"]] {
            crate::provider_failure::merge_reported_usage(&mut self.reported_usage, usage);
        }
    }
    fn rejection_with_usage(&mut self, value: &Value) -> Error {
        let mut failure = crate::provider_failure::Failure::rejection(value, None);
        self.reported_usage = crate::provider_failure::merge_usage(
            self.reported_usage.take(),
            failure.reported_usage.take(),
        );
        failure.reported_usage = self.reported_usage.clone();
        Error::ProviderFailure(Box::new(failure))
    }
    pub fn is_terminal(&self) -> bool {
        self.root.is_some()
    }
    pub fn finish(self) -> Result<Reply> {
        let root = self.root.ok_or(Error::IncompleteStream)?;
        let status = string(&root["status"]);
        if status == "incomplete" && root["incomplete_details"]["reason"] != "max_output_tokens" {
            return Err(Error::Provider(format!(
                "Incomplete response: {}",
                string(&root["incomplete_details"]["reason"])
            )));
        }
        let listed = root["output"]
            .as_array()
            .ok_or_else(|| invalid("Missing terminal output array"))?;
        let indexed: Vec<(usize, Value)> = if listed.is_empty() {
            self.items.into_iter().collect()
        } else {
            listed.iter().cloned().enumerate().collect()
        };
        let mut reply = Reply {
            text: String::new(),
            reasoning: String::new(),
            calls: Vec::new(),
            usage: root["usage"].clone(),
            status,
            provider_items: Vec::new(),
        };
        for (index, mut item) in indexed {
            match item["type"].as_str().unwrap_or("") {
                "message" => {
                    for part in item["content"].as_array().into_iter().flatten() {
                        reply.text.push_str(
                            part["text"]
                                .as_str()
                                .or(part["refusal"].as_str())
                                .unwrap_or(""),
                        );
                    }
                }
                "reasoning" => {
                    let summary = item["summary"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|v| v["text"].as_str())
                        .collect::<Vec<_>>()
                        .join("\n\n");
                    reply.reasoning.push_str(if summary.is_empty() {
                        self.thinking.get(&index).map(String::as_str).unwrap_or("")
                    } else {
                        &summary
                    });
                }
                "function_call" => {
                    let id = string(&item["call_id"]);
                    let name = string(&item["name"]);
                    if id.is_empty() || name.is_empty() || reply.calls.iter().any(|c| c.id == id) {
                        return Err(invalid("Invalid or duplicate tool identity"));
                    }
                    let args = item["arguments"]
                        .as_str()
                        .filter(|s| !s.is_empty())
                        .or_else(|| self.arguments.get(&index).map(String::as_str))
                        .ok_or_else(|| {
                            invalid("Provider omitted tool arguments; no tool was executed")
                        })?
                        .to_owned();
                    reply.calls.push(ToolCall {
                        id,
                        name,
                        arguments: serde_json::from_str(&args).map_err(|_| {
                            invalid(
                                "Provider returned malformed tool arguments; no tool was executed",
                            )
                        })?,
                    });
                    // The terminal may omit its output array and the indexed
                    // item may still have empty arguments. Preserve the exact
                    // assembled stream text used above, so retained replay and
                    // the typed executable call have one validated meaning.
                    item["arguments"] = json!(args);
                }
                _ => {}
            }
            reply.provider_items.push(item);
        }
        Ok(reply)
    }
}
fn string(v: &Value) -> String {
    v.as_str().unwrap_or("").into()
}
/// Preserve typed evidence while redacting all externally reported strings.
fn safe_failure(
    error: Error,
    profile: &Profile,
    credential: &Credential,
    status: u16,
    attempt_id: &str,
) -> Error {
    match error {
        Error::ProviderFailure(mut failure) => {
            failure.message = profile.safe_error(credential, &failure.message);
            failure.status = failure.status.or(Some(status));
            failure.attempt_id = Some(attempt_id.to_owned());
            fn redact(value: &mut Value, profile: &Profile, credential: &Credential) {
                match value {
                    Value::String(text) => *text = profile.safe_error(credential, text),
                    Value::Array(values) => values
                        .iter_mut()
                        .for_each(|v| redact(v, profile, credential)),
                    Value::Object(values) => {
                        *values = std::mem::take(values)
                            .into_iter()
                            .map(|(key, mut value)| {
                                redact(&mut value, profile, credential);
                                (profile.safe_error(credential, &key), value)
                            })
                            .collect();
                    }
                    _ => {}
                }
            }
            if let Some(usage) = &mut failure.reported_usage {
                redact(usage, profile, credential);
            }
            Error::ProviderFailure(failure)
        }
        Error::Provider(message) => Error::Provider(profile.safe_error(credential, &message)),
        other => other,
    }
}

#[derive(Clone)]
pub struct ResponsesClient {
    client: reqwest::Client,
}
impl ResponsesClient {
    pub fn new() -> Result<Self> {
        Ok(Self {
            client: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(30))
                .read_timeout(Duration::from_secs(300))
                .build()
                .map_err(|_| invalid("Could not initialize HTTPS client"))?,
        })
    }
    /// Loopback fixtures must not inherit an HTTP proxy from the process. The
    /// synthetic Controller separately validates a numeric loopback endpoint;
    /// redirects stay disabled just as in the ordinary client.
    pub(crate) fn new_synthetic_fixture() -> Result<Self> {
        Ok(Self {
            client: reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(30))
                .read_timeout(Duration::from_secs(300))
                .build()
                .map_err(|_| invalid("Could not initialize fixture HTTP client"))?,
        })
    }
    // Mirrors the source ModelClient boundary; request and per-turn identities are explicit.
    #[allow(clippy::too_many_arguments)]
    pub async fn complete(
        &self,
        profile: &Profile,
        credential: &Credential,
        messages: &[Message],
        instructions: &str,
        session_id: &str,
        turn_id: &str,
        cancel: CancellationToken,
        on_delta: impl FnMut(Delta) -> Result<()>,
    ) -> Result<Reply> {
        self.complete_with_tools(
            profile,
            credential,
            messages,
            instructions,
            session_id,
            turn_id,
            &[],
            cancel,
            on_delta,
        )
        .await
    }
    #[allow(clippy::too_many_arguments)]
    pub async fn complete_with_tools(
        &self,
        profile: &Profile,
        credential: &Credential,
        messages: &[Message],
        instructions: &str,
        session_id: &str,
        turn_id: &str,
        tools: &[crate::tools::ToolDefinition],
        cancel: CancellationToken,
        on_delta: impl FnMut(Delta) -> Result<()>,
    ) -> Result<Reply> {
        let mut observation = AttemptObservation::default();
        self.complete_with_tools_observed(
            profile,
            credential,
            messages,
            instructions,
            session_id,
            turn_id,
            tools,
            cancel,
            on_delta,
            &mut observation,
        )
        .await
    }
    /// The same request, recording what it reported and when its output
    /// came into `observation` (also when it fails or is stopped).
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn complete_with_tools_observed(
        &self,
        profile: &Profile,
        credential: &Credential,
        messages: &[Message],
        instructions: &str,
        session_id: &str,
        turn_id: &str,
        tools: &[crate::tools::ToolDefinition],
        cancel: CancellationToken,
        on_delta: impl FnMut(Delta) -> Result<()>,
        observation: &mut AttemptObservation,
    ) -> Result<Reply> {
        let body = request_body_with_tools(profile, messages, instructions, session_id, tools)?;
        self.complete_observed(
            profile,
            credential,
            &body,
            session_id,
            turn_id,
            cancel,
            on_delta,
            observation,
        )
        .await
    }
    /// An already counted, immutable request, without accounting (tests).
    #[cfg(test)]
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn complete_prepared(
        &self,
        profile: &Profile,
        credential: &Credential,
        body: &Value,
        session_id: &str,
        turn_id: &str,
        cancel: CancellationToken,
        on_delta: impl FnMut(Delta) -> Result<()>,
    ) -> Result<Reply> {
        let mut observation = AttemptObservation::default();
        self.complete_observed(
            profile,
            credential,
            body,
            session_id,
            turn_id,
            cancel,
            on_delta,
            &mut observation,
        )
        .await
    }
    /// Sends `body` once and settles `observation`: its outcome, the usage
    /// and cost the response reported, and the request's timing.
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn complete_observed(
        &self,
        profile: &Profile,
        credential: &Credential,
        body: &Value,
        session_id: &str,
        turn_id: &str,
        cancel: CancellationToken,
        on_delta: impl FnMut(Delta) -> Result<()>,
        observation: &mut AttemptObservation,
    ) -> Result<Reply> {
        // A retry is a separate physical invocation, even within one turn.
        let attempt_id = uuid::Uuid::new_v4().to_string();
        *observation = AttemptObservation {
            id: attempt_id.clone(),
            api: profile.api.clone(),
            requested_model: profile.model_id.clone(),
            usage_binding: crate::compaction::usage_binding(body, profile).ok(),
            ..AttemptObservation::default()
        };
        let result = self
            .send(
                profile,
                credential,
                body,
                session_id,
                turn_id,
                cancel,
                on_delta,
                &attempt_id,
                observation,
            )
            .await;
        observation.outcome = Some(
            match &result {
                Ok(reply) if reply.status == "incomplete" => "truncated",
                Ok(_) => "completed",
                Err(Error::Cancelled) => "cancelled",
                Err(_) => "failed",
            }
            .into(),
        );
        match &result {
            Ok(reply) if !reply.usage.is_null() => observation.usage = Some(reply.usage.clone()),
            Err(Error::ProviderFailure(failure)) => {
                if let Some(usage) = &failure.reported_usage {
                    observation.usage = Some(usage.clone());
                }
            }
            _ => {}
        }
        result
    }
    #[allow(clippy::too_many_arguments)]
    async fn send(
        &self,
        profile: &Profile,
        credential: &Credential,
        body: &Value,
        session_id: &str,
        turn_id: &str,
        cancel: CancellationToken,
        mut on_delta: impl FnMut(Delta) -> Result<()>,
        attempt_id: &str,
        observation: &mut AttemptObservation,
    ) -> Result<Reply> {
        let bytes = serialize_request(body)?;
        let attempt_id = attempt_id.to_owned();
        let secret = |text: &str| {
            let key = credential.expose();
            !key.is_empty() && text.contains(key)
        };
        let mut request = self
            .client
            .post(profile.endpoint()?)
            .header("content-type", "application/json")
            .header("accept", "text/event-stream")
            .bearer_auth(credential.expose())
            .header("x-session-id", correlation_value(session_id))
            .header("x-turn-id", correlation_value(turn_id))
            .header("session_id", correlation_value(session_id))
            .header("x-client-request-id", correlation_value(session_id))
            .body(bytes);
        for (name, value) in &profile.headers {
            request = request.header(name, value);
        }
        observation.wall = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        observation.clock.dispatched();
        let response = tokio::select! { biased; _=cancel.cancelled()=>return Err(Error::Cancelled), response=request.send()=>response.map_err(|e|Error::Provider(profile.safe_error(credential,&format!("Transport failure: {e}"))))? };
        let status = response.status();
        let json_body = response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.to_ascii_lowercase().contains("application/json"));
        observation.cost.head(
            response
                .headers()
                .get("x-litellm-response-cost")
                .and_then(|v| v.to_str().ok()),
            !json_body,
            &secret,
        );
        let mut stream = response.bytes_stream();
        let mut parser = Parser::default();
        let mut acc = Accumulator::default();
        let mut raw = Vec::new();
        let mut received = 0;
        loop {
            let next = tokio::select! { biased; _=cancel.cancelled()=>return Err(Error::Cancelled), next=stream.next()=>next };
            let Some(chunk) = next else {
                break;
            };
            let chunk = chunk.map_err(|e| {
                Error::Provider(
                    profile.safe_error(credential, &format!("Stream transport failure: {e}")),
                )
            })?;
            received += chunk.len();
            if received > 64 * 1024 * 1024 {
                return Err(invalid("Response exceeds 64 MiB safety limit"));
            }
            if !status.is_success() {
                raw.extend_from_slice(&chunk[..chunk.len().min(65_536 - raw.len())]);
                if raw.len() >= 65_536 {
                    break;
                }
                continue;
            }
            if json_body {
                raw.extend_from_slice(&chunk);
                if raw.len() > 16 * 1024 * 1024 {
                    return Err(invalid("JSON response exceeds 16 MiB"));
                }
                continue;
            }
            for event in parser.feed(&chunk)? {
                if event.data == "[DONE]" {
                    continue;
                }
                let value: Value = serde_json::from_str(&event.data)
                    .map_err(|_| invalid("Provider emitted invalid SSE JSON"))?;
                observation.cost.body(&value, true, &secret);
                match value["type"].as_str().unwrap_or("") {
                    "response.output_item.added" => observation.clock.opened(),
                    "response.output_item.done" => observation.clock.produced(false),
                    "response.completed" | "response.incomplete" | "response.failed" => {
                        observation.clock.terminal()
                    }
                    _ => {}
                }
                if matches!(event.event.as_str(), "error" | "response.failed") {
                    return Err(safe_failure(
                        acc.rejection_with_usage(&value),
                        profile,
                        credential,
                        status.as_u16(),
                        &attempt_id,
                    ));
                }
                let deltas = acc.consume(value).map_err(|e| {
                    safe_failure(e, profile, credential, status.as_u16(), &attempt_id)
                })?;
                for delta in deltas {
                    let produced = match &delta {
                        Delta::Text(text) | Delta::Reasoning(text) => !text.is_empty(),
                        Delta::Tool {
                            name, arguments, ..
                        } => !name.is_empty() || !arguments.is_empty(),
                    };
                    if produced {
                        observation.clock.produced(true);
                    }
                    on_delta(delta)?;
                }
            }
        }
        if !status.is_success() {
            let value = serde_json::from_slice::<Value>(&raw)
                .unwrap_or_else(|_| json!({"message":String::from_utf8_lossy(&raw)}));
            let mut failure =
                crate::provider_failure::Failure::rejection(&value, Some(status.as_u16()));
            failure.message = format!("HTTP {}: {}", status.as_u16(), failure.message);
            return Err(safe_failure(
                Error::ProviderFailure(Box::new(failure)),
                profile,
                credential,
                status.as_u16(),
                &attempt_id,
            ));
        }
        if json_body {
            let value: Value = serde_json::from_slice(&raw)
                .map_err(|_| invalid("Provider emitted invalid JSON"))?;
            observation.cost.body(&value, false, &secret);
            observation.clock.final_content();
            observation.clock.terminal();
            acc.accept_json(value)
                .map_err(|e| safe_failure(e, profile, credential, status.as_u16(), &attempt_id))?;
        }
        acc.finish()
            .map_err(|e| safe_failure(e, profile, credential, status.as_u16(), &attempt_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture_profile() -> Profile {
        serde_json::from_value(json!({"id":"test","api":"openai-responses",
            "providerId":"litellm","modelId":"fixture","baseUrl":"http://127.0.0.1:3333",
            "contextWindow":32000,"maxOutputTokens":4096}))
        .unwrap()
    }
    #[test]
    fn terminal_required_and_incomplete_reason_checked() {
        assert!(matches!(
            Accumulator::default().finish(),
            Err(Error::IncompleteStream)
        ));
        let mut a = Accumulator::default();
        a.accept_json(json!({"status":"incomplete","incomplete_details":{"reason":"content_filter"},"output":[]})).unwrap();
        assert!(a.finish().is_err());
    }
    #[test]
    fn streamed_items_fallback_and_order() {
        let mut a = Accumulator::default();
        a.consume(json!({"type":"response.output_item.done","output_index":1,"item":{"type":"message","content":[{"type":"output_text","text":"two"}]}})).unwrap();
        a.consume(json!({"type":"response.output_item.done","output_index":0,"item":{"type":"message","content":[{"type":"output_text","text":"one"}]}})).unwrap();
        a.consume(json!({"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":2}}})).unwrap();
        let reply = a.finish().unwrap();
        assert_eq!(reply.text, "onetwo");
        assert_eq!(reply.usage["input_tokens"], 2);
    }
    #[test]
    fn streamed_tool_arguments_are_retained_in_the_assembled_provider_item() {
        let mut accumulator = Accumulator::default();
        accumulator.consume(json!({"type":"response.output_item.done","output_index":0,"item":{
            "type":"function_call","call_id":"fixture","name":"ls","arguments":"","status":"completed"
        }})).unwrap();
        accumulator.consume(json!({"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"limit\":1}"})).unwrap();
        accumulator
            .accept_json(json!({"status":"completed","output":[]}))
            .unwrap();
        let reply = accumulator.finish().unwrap();
        assert_eq!(reply.calls[0].arguments, json!({"limit":1}));
        assert_eq!(reply.provider_items[0]["arguments"], "{\"limit\":1}");
    }

    #[test]
    fn absent_empty_and_malformed_arguments_never_become_an_empty_object() {
        for arguments in [Value::Null, json!(""), json!("{broken")] {
            let mut accumulator = Accumulator::default();
            accumulator
                .accept_json(json!({"status":"completed","output":[{
                    "type":"function_call","call_id":"fixture","name":"ls","arguments":arguments
                }]}))
                .unwrap();
            assert!(accumulator.finish().is_err());
        }
        let mut accumulator = Accumulator::default();
        accumulator
            .consume(
                json!({"type":"response.output_item.added","output_index":0,"item":{
                    "type":"function_call","call_id":"fixture","name":"ls","arguments":""
                }}),
            )
            .unwrap();
        accumulator.consume(json!({"type":"response.function_call_arguments.delta","output_index":0,"delta":"{}"})).unwrap();
        accumulator
            .accept_json(json!({"status":"completed","output":[{
                "type":"function_call","call_id":"fixture","name":"ls","arguments":"{broken"
            }]}))
            .unwrap();
        // An explicitly malformed terminal string outranks a valid streamed
        // fallback. Never execute arguments different from that terminal item.
        assert!(accumulator.finish().is_err());
    }

    #[test]
    fn arguments_cannot_precede_item() {
        let mut a = Accumulator::default();
        assert!(a.consume(json!({"type":"response.function_call_arguments.delta","output_index":0,"delta":"x"})).is_err());
    }
    #[test]
    fn bare_gateway_error_is_failure() {
        assert!(
            Accumulator::default()
                .consume(json!({"error":{"message":"gateway overloaded"}}))
                .is_err()
        );
    }
    #[test]
    fn output_and_local_errors_never_gain_context_classification() {
        let mut acc = Accumulator::default();
        assert!(
            acc.consume(json!({"type":"response.output_text.delta","delta":"prompt is too long"}))
                .is_ok()
        );
        assert!(
            acc.consume(
                json!({"type":"response.output_item.done","output_index":0,"item":{
            "type":"message","content":[{"text":"context_length_exceeded"}]}})
            )
            .is_ok()
        );
        assert!(matches!(
            acc.accept_json(json!({"status":"unexpected","message":"prompt is too long"})),
            Err(Error::Provider(_))
        ));
        let profile = fixture_profile();
        let credential = Credential::new("fixture-secret".into()).unwrap();
        assert!(matches!(
            safe_failure(
                Error::Provider("Transport: prompt is too long".into()),
                &profile,
                &credential,
                200,
                "test"
            ),
            Error::Provider(_)
        ));
    }

    async fn rejected_fixture(
        status: u16,
        content_type: &str,
        body: String,
    ) -> crate::provider_failure::Failure {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut profile = fixture_profile();
        profile.base_url = format!("http://{}", listener.local_addr().unwrap());
        profile
            .headers
            .insert("x-fixture-secret".into(), "header-secret".into());
        // Classification must happen before this matching header value is redacted.
        profile
            .headers
            .insert("x-context-marker".into(), "context_length_exceeded".into());
        let response = format!(
            "HTTP/1.1 {status} Fixture\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut chunk = [0_u8; 4096];
            loop {
                let n = socket.read(&mut chunk).await.unwrap();
                assert!(n > 0);
                request.extend_from_slice(&chunk[..n]);
                if let Some(end) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                    let head = String::from_utf8_lossy(&request[..end]);
                    let length: usize = head
                        .lines()
                        .find_map(|line| {
                            let (key, value) = line.split_once(':')?;
                            key.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse().unwrap())
                        })
                        .unwrap_or(0);
                    if request.len() >= end + 4 + length {
                        break;
                    }
                }
            }
            socket.write_all(response.as_bytes()).await.unwrap();
        });
        let client = ResponsesClient::new_synthetic_fixture().unwrap();
        let error = tokio::time::timeout(
            Duration::from_secs(5),
            client.complete_prepared(
                &profile,
                &Credential::new("credential-secret".into()).unwrap(),
                &json!({}),
                "session",
                "same-turn",
                CancellationToken::new(),
                |_| Ok(()),
            ),
        )
        .await
        .unwrap()
        .unwrap_err();
        server.await.unwrap();
        match error {
            Error::ProviderFailure(failure) => *failure,
            other => panic!("Lost failure envelope: {other:?}"),
        }
    }

    #[tokio::test]
    async fn http_json_and_sse_preserve_typed_redacted_evidence() {
        use crate::provider_failure::Category;
        let error =
            json!({"code":"context_length_exceeded","message":"credential-secret header-secret"});
        let usage =
            json!({"input_tokens":77,"detail":"credential-secret","header-secret":"header-secret"});
        let cases = [
            (
                400,
                "application/json",
                json!({"error":error,"usage":usage}).to_string(),
            ),
            (
                200,
                "application/json",
                json!({"status":"failed","error":error,"usage":usage}).to_string(),
            ),
            (
                200,
                "text/event-stream",
                format!(
                    "data: {}\n\n",
                    json!({"type":"response.failed","response":{"error":error,"usage":usage}})
                ),
            ),
            (
                200,
                "text/event-stream",
                format!(
                    "event: error\ndata: {}\n\n",
                    json!({"code":"context_length_exceeded","message":"credential-secret header-secret","usage":usage})
                ),
            ),
        ];
        let mut attempts = std::collections::BTreeSet::new();
        for (status, content_type, body) in cases {
            let failure = rejected_fixture(status, content_type, body).await;
            assert_eq!(failure.category, Category::InputContextExceeded);
            assert_eq!(failure.status, Some(status));
            assert!(failure.message.contains("[REDACTED]"));
            assert_eq!(failure.reported_usage.as_ref().unwrap()["input_tokens"], 77);
            let serialized = serde_json::to_string(&failure).unwrap();
            assert!(!serialized.contains("credential-secret"));
            assert!(!serialized.contains("header-secret"));
            assert!(uuid::Uuid::parse_str(failure.attempt_id.as_ref().unwrap()).is_ok());
            assert!(attempts.insert(failure.attempt_id.unwrap()));
        }
    }

    #[tokio::test]
    async fn wire_non_context_vetoes_and_unknown_usage_survive_all_paths() {
        use crate::provider_failure::Category;
        for (status, code, expected) in [
            (401, "context_length_exceeded", Category::Authentication),
            (429, "context_length_exceeded", Category::RateLimited),
            (
                413,
                "context_length_exceeded",
                Category::RequestBodyTooLarge,
            ),
            (
                400,
                "invalid_max_output_tokens",
                Category::OutputLimitInvalid,
            ),
        ] {
            let error = json!({"code":code,"message":"prompt is too long"});
            let failure = rejected_fixture(
                status,
                "application/json",
                json!({"error":error}).to_string(),
            )
            .await;
            assert_eq!(failure.category, expected);
            assert_eq!(failure.reported_usage, None);
        }
        for content_type in ["application/json", "text/event-stream"] {
            let value = json!({"status":"failed","type":"response.failed","code":"context_length_exceeded",
                "error":{"type":"rate_limit_error","message":"prompt is too long"}});
            let body = if content_type == "application/json" {
                value.to_string()
            } else {
                format!("data: {value}\n\n")
            };
            let failure = rejected_fixture(200, content_type, body).await;
            assert_eq!(failure.category, Category::RateLimited);
            assert_eq!(failure.reported_usage, None);
        }
    }
    #[tokio::test]
    async fn earlier_stream_usage_survives_sparse_failure_and_conflicts_stay_unknown() {
        use crate::provider_failure::Category;
        for event in ["data:", "event: error\ndata:"] {
            let prior = json!({"type":"response.created","response":{"usage":{"input_tokens":100,"output_tokens":4}}});
            let failed = json!({"type":"response.failed","response":{"error":{"code":"context_length_exceeded"},"usage":{}}});
            let body = format!("data: {prior}\n\n{event} {failed}\n\n");
            let failure = rejected_fixture(200, "text/event-stream", body).await;
            assert_eq!(failure.category, Category::InputContextExceeded);
            assert_eq!(
                failure.reported_usage,
                Some(json!({"input_tokens":100,"output_tokens":4}))
            );
        }
        let mut acc = Accumulator::default();
        acc.consume(
            json!({"type":"response.created","usage":{"input_tokens":100,"output_tokens":4}}),
        )
        .unwrap();
        let error = acc.consume(json!({"type":"response.failed","response":{"error":{"code":"context_length_exceeded"},"usage":{"input_tokens":101}}})).unwrap_err();
        let Error::ProviderFailure(failure) = error else {
            panic!("expected typed rejection")
        };
        assert_eq!(
            failure.reported_usage,
            Some(json!({"input_tokens":null,"output_tokens":4}))
        );
    }
}
