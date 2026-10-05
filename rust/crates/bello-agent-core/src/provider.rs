use crate::{
    Credential, Error, Message, Profile, Result, invalid, profile::correlation_value, sse::Parser,
};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::BTreeMap, time::Duration};
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
/// This vertical slice intentionally offers no tools. Typed tool-history replay
/// is non-executing groundwork; the live Controller still rejects tool calls.
pub fn request_body(
    profile: &Profile,
    messages: &[Message],
    instructions: &str,
    session_id: &str,
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
    Ok(body)
}

#[derive(Default)]
pub struct Accumulator {
    root: Option<Value>,
    items: BTreeMap<usize, Value>,
    arguments: BTreeMap<usize, String>,
    thinking: BTreeMap<usize, String>,
}
impl Accumulator {
    pub fn consume(&mut self, value: Value) -> Result<Vec<Delta>> {
        let kind = value["type"].as_str().unwrap_or("");
        if kind == "error"
            || kind == "response.failed"
            || kind.is_empty() && !value["error"].is_null()
        {
            return Err(provider_failure(&value));
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
        if !matches!(value["status"].as_str(), Some("completed" | "incomplete")) {
            return Err(provider_failure(&value));
        }
        self.root = Some(value);
        Ok(())
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
        for (index, item) in indexed {
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
                        .unwrap_or("{}");
                    reply.calls.push(ToolCall {
                        id,
                        name,
                        arguments: serde_json::from_str(args).unwrap_or_else(|_| json!({})),
                    });
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
fn provider_failure(value: &Value) -> Error {
    let detail = if !value["response"]["error"].is_null() {
        &value["response"]["error"]
    } else {
        &value["error"]
    };
    Error::Provider(
        detail["message"]
            .as_str()
            .or(detail.as_str())
            .or(value["message"].as_str())
            .unwrap_or("Provider reported an unsuccessful response")
            .into(),
    )
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
        mut on_delta: impl FnMut(Delta) -> Result<()>,
    ) -> Result<Reply> {
        let body = request_body(profile, messages, instructions, session_id)?;
        let bytes = serde_json::to_vec(&body)?;
        if bytes.len() > 32 * 1024 * 1024 {
            return Err(invalid("Serialized request exceeds 32 MiB"));
        }
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
        let response = tokio::select! { biased; _=cancel.cancelled()=>return Err(Error::Cancelled), response=request.send()=>response.map_err(|e|Error::Provider(profile.safe_error(credential,&format!("Transport failure: {e}"))))? };
        let status = response.status();
        let json_body = response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.contains("application/json"));
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
                let deltas = acc
                    .consume(value)
                    .map_err(|e| Error::Provider(profile.safe_error(credential, &e.to_string())))?;
                for delta in deltas {
                    on_delta(delta)?;
                }
            }
        }
        if !status.is_success() {
            return Err(Error::Provider(profile.safe_error(
                credential,
                &format!(
                    "HTTP {}: {}",
                    status.as_u16(),
                    String::from_utf8_lossy(&raw)
                ),
            )));
        }
        if json_body {
            let value = serde_json::from_slice(&raw)
                .map_err(|_| invalid("Provider emitted invalid JSON"))?;
            acc.accept_json(value)
                .map_err(|e| Error::Provider(profile.safe_error(credential, &e.to_string())))?;
        }
        acc.finish().map_err(|e| match e {
            Error::Provider(_) => Error::Provider(profile.safe_error(credential, &e.to_string())),
            _ => e,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
}
