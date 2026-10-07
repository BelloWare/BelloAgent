//! Non-executing tool history groundwork. Source: ResponsesInput.swift,
//! Routing.swift and SessionTools.swift. Nothing here offers or invokes a tool.
use crate::{Message, Profile, Result, invalid, provider::ToolCall};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

pub const MISSING_RESULT: &str = "No result provided";
pub const EMPTY_RESULT: &str = "(no tool output)";
const MAX_ARGUMENT_BYTES: usize = 2 * 1024 * 1024;
const MAX_RESULT_BYTES: usize = 16 * 1024 * 1024;
const MAX_PROVIDER_BYTES: usize = 64 * 1024 * 1024;

/// The non-secret subset of Profile.binding / ProviderClient.replayBinding.
/// There is deliberately no credential/header hash or fabricated route proof.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReplayBinding {
    pub profile_id: String,
    pub api: String,
    pub provider: String,
    pub model: String,
    pub endpoint_sha256: String,
}
impl ReplayBinding {
    pub fn from_profile(profile: &Profile) -> Result<Self> {
        profile.validate()?;
        Ok(Self {
            profile_id: profile.id.clone(),
            api: profile.api.clone(),
            provider: profile.provider_id.clone(),
            model: profile.model_id.clone(),
            endpoint_sha256: format!(
                "{:x}",
                Sha256::digest(profile.endpoint()?.as_str().as_bytes())
            ),
        })
    }
    fn validate(&self) -> Result<()> {
        for value in [&self.profile_id, &self.api, &self.provider, &self.model] {
            identity(value)?;
        }
        if self.api != "openai-responses"
            || self.provider != "litellm"
            || self.endpoint_sha256.len() != 64
            || !self
                .endpoint_sha256
                .bytes()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
        {
            return Err(invalid("Invalid recorded Responses binding"));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Completion {
    Complete,
    Incomplete,
    Cancelled,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantRecord {
    pub completion: Completion,
    pub calls: Vec<ToolCall>,
    pub binding: ReplayBinding,
    #[serde(default)]
    pub provider_items: Vec<Value>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ToolOutcome {
    Completed,
    Failed,
    Cancelled,
    Unknown,
    NotExecuted,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResultRecord {
    pub assistant_id: String,
    pub call_id: String,
    pub is_error: bool,
    pub outcome: ToolOutcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<std::sync::Arc<crate::tool_content::ToolContent>>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub enum ToolRecord {
    Assistant(AssistantRecord),
    Result(ResultRecord),
}

fn identity(value: &str) -> Result<()> {
    if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
        return Err(invalid("Invalid recorded tool identity"));
    }
    Ok(())
}

fn validate_assistant(record: &AssistantRecord, text: &str) -> Result<()> {
    record.binding.validate()?;
    if record.calls.is_empty() {
        return Err(invalid("Recorded tool assistant has no calls"));
    }
    let mut ids = BTreeSet::new();
    for call in &record.calls {
        identity(&call.id)?;
        identity(&call.name)?;
        if !ids.insert(&call.id) {
            return Err(invalid("Duplicate call identity in one assistant message"));
        }
        if serde_json::to_vec(&call.arguments)?.len() > MAX_ARGUMENT_BYTES {
            return Err(invalid("Recorded tool arguments exceed 2 MiB"));
        }
    }
    if serde_json::to_vec(&record.provider_items)?.len() > MAX_PROVIDER_BYTES {
        return Err(invalid("Recorded provider items exceed 64 MiB"));
    }
    let mut item_calls = BTreeSet::new();
    let mut item_order = Vec::new();
    let mut provider_text = String::new();
    for item in &record.provider_items {
        if record.completion == Completion::Complete
            && item
                .get("status")
                .is_some_and(|status| status != "completed")
        {
            return Err(invalid(
                "Complete tool history contains an incomplete provider item",
            ));
        }
        match item["type"].as_str() {
            Some("reasoning") => {
                if !item.is_object() {
                    return Err(invalid("Invalid recorded reasoning item"));
                }
            }
            Some("message") => {
                let parts = item["content"]
                    .as_array()
                    .ok_or_else(|| invalid("Recorded message lacks content"))?;
                for part in parts {
                    match part["type"].as_str() {
                        Some("output_text") if part["text"].is_string() => {
                            provider_text.push_str(part["text"].as_str().unwrap())
                        }
                        Some("refusal") if part["refusal"].is_string() => {
                            provider_text.push_str(part["refusal"].as_str().unwrap())
                        }
                        _ => return Err(invalid("Unsupported recorded message content")),
                    }
                }
            }
            Some("function_call") => {
                let id = item["call_id"]
                    .as_str()
                    .ok_or_else(|| invalid("Recorded call item lacks identity"))?;
                let call = record
                    .calls
                    .iter()
                    .find(|call| call.id == id)
                    .ok_or_else(|| invalid("Recorded provider call has no typed owner"))?;
                if item["name"].as_str() != Some(call.name.as_str()) || !item_calls.insert(id) {
                    return Err(invalid("Recorded provider call identity disagrees"));
                }
                item_order.push(id);
                let arguments: Value = serde_json::from_str(
                    item["arguments"]
                        .as_str()
                        .ok_or_else(|| invalid("Recorded provider arguments are not text"))?,
                )?;
                if arguments != call.arguments {
                    return Err(invalid("Recorded provider arguments disagree"));
                }
            }
            _ => return Err(invalid("Unsupported recorded provider item")),
        }
    }
    if !record.provider_items.is_empty()
        && item_order
            != record
                .calls
                .iter()
                .map(|call| call.id.as_str())
                .collect::<Vec<_>>()
    {
        return Err(invalid("Recorded provider items omit typed calls"));
    }
    if !record.provider_items.is_empty() && provider_text != text {
        return Err(invalid(
            "Recorded provider text disagrees with retained assistant text",
        ));
    }
    Ok(())
}

/// Validate on write, load and projection. A malformed record is an error, not
/// something to drop from a user's retained history or rewrite during recovery.
pub fn validate(messages: &[Message]) -> Result<()> {
    if !messages
        .iter()
        .any(|message| message.tool_record.is_some() || message.role == "toolResult")
    {
        return Ok(());
    }
    let mut message_ids = BTreeSet::new();
    let mut current: Option<(&str, &AssistantRecord)> = None;
    let mut last_result = None;
    for message in messages {
        identity(&message.id)?;
        if !message_ids.insert(&message.id) {
            return Err(invalid("Duplicate message identity in tool history"));
        }
        match &message.tool_record {
            Some(ToolRecord::Assistant(record)) => {
                if message.role != "assistant" {
                    return Err(invalid("Tool assistant has an incompatible role"));
                }
                validate_assistant(record, &message.text)?;
                if message.replay_eligible
                    && (record.completion != Completion::Complete
                        || !matches!(message.state.as_str(), "complete" | "completed"))
                {
                    return Err(invalid(
                        "Incomplete or cancelled tool assistant cannot be replay eligible",
                    ));
                }
                current = Some((&message.id, record));
                last_result = None;
            }
            Some(ToolRecord::Result(record)) => {
                if message.role != "toolResult" {
                    return Err(invalid("Tool result has an incompatible role"));
                }
                if message.replay_eligible
                    && !matches!(message.state.as_str(), "complete" | "completed")
                {
                    return Err(invalid("Incomplete tool result cannot be replay eligible"));
                }
                identity(&record.assistant_id)?;
                identity(&record.call_id)?;
                let (owner, assistant) = current
                    .ok_or_else(|| invalid("Tool result has no preceding assistant owner"))?;
                if owner != record.assistant_id {
                    return Err(invalid("Tool result belongs to another assistant message"));
                }
                let index = assistant
                    .calls
                    .iter()
                    .position(|call| call.id == record.call_id)
                    .ok_or_else(|| invalid("Tool result refers to an unknown call"))?;
                if last_result.is_some_and(|last| index <= last) {
                    return Err(invalid("Tool results are duplicated or out of call order"));
                }
                last_result = Some(index);
                if let Some(content) = &record.content {
                    content.validate()?;
                    if content.text() != message.text
                        || !(record.outcome == ToolOutcome::Completed
                            || (record.outcome == ToolOutcome::Failed
                                && assistant.calls[index].name == "mcp"
                                && record.is_error
                                && content.stats.is_none()))
                    {
                        return Err(invalid(
                            "Retained tool content disagrees with result text or outcome",
                        ));
                    }
                }
                if message.text.len() > MAX_RESULT_BYTES {
                    return Err(invalid("Recorded tool result exceeds 16 MiB"));
                }
                if record.is_error == (record.outcome == ToolOutcome::Completed) {
                    return Err(invalid("Tool outcome and error flag disagree"));
                }
            }
            None => {
                if message.role == "toolResult" {
                    return Err(invalid("Tool result lacks typed identity"));
                }
                current = None;
                last_result = None;
            }
        }
    }
    Ok(())
}

fn assistant_items(
    message: &Message,
    record: &AssistantRecord,
    profile: &Profile,
) -> Result<Vec<Value>> {
    let current = ReplayBinding::from_profile(profile)?;
    let opaque = record
        .provider_items
        .iter()
        .any(|item| item["type"] == "reasoning");
    // Routing.swift permits an early portable path across saved connections.
    // Same-connection opaque replay requires a verified pinned route contract,
    // revision and observed effective model; Rust has none, so never invent it.
    if opaque && record.binding.profile_id == current.profile_id {
        return Err(invalid(
            "Provider-specific reasoning requires a verified replay policy; original history is retained",
        ));
    }
    let mut output = Vec::new();
    if !record.provider_items.is_empty() {
        // Preserve interleaved message/call order, not just the call order.
        // Validation established exact agreement with typed text and calls.
        let show_summary = record.binding.model != current.model && !message.reasoning.is_empty();
        if show_summary && !opaque {
            output.push(text_item(&message.reasoning));
        }
        let mut summary_shown = !opaque;
        for item in &record.provider_items {
            match item["type"].as_str() {
                Some("reasoning") => {
                    if show_summary && !summary_shown {
                        output.push(text_item(&message.reasoning));
                        summary_shown = true;
                    }
                }
                Some("message") => {
                    let text = item["content"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|part| {
                            if part["type"] == "refusal" {
                                part["refusal"].as_str().unwrap()
                            } else {
                                part["text"].as_str().unwrap()
                            }
                        })
                        .collect::<String>();
                    let mut projected = text_item(&text);
                    if matches!(item["phase"].as_str(), Some("commentary" | "final_answer")) {
                        projected["phase"] = item["phase"].clone();
                    }
                    output.push(projected);
                }
                Some("function_call") => {
                    let call = record
                        .calls
                        .iter()
                        .find(|call| item["call_id"] == call.id)
                        .unwrap();
                    let provider_id = (record.binding == current)
                        .then(|| item["id"].as_str())
                        .flatten();
                    output.push(call_item(call, provider_id)?);
                }
                _ => unreachable!("item types validated above"),
            }
        }
        return Ok(output);
    }
    if record.binding.model != current.model && !message.reasoning.is_empty() {
        output.push(text_item(&message.reasoning));
    }
    if !message.text.is_empty() {
        output.push(text_item(&message.text));
    }
    for call in &record.calls {
        output.push(call_item(call, None)?);
    }
    Ok(output)
}

fn text_item(text: &str) -> Value {
    json!({"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":text,"annotations":[]}]})
}
fn call_item(call: &ToolCall, provider_id: Option<&str>) -> Result<Value> {
    let mut item = json!({"type":"function_call","call_id":call.id,"name":call.name,"arguments":serde_json::to_string(&call.arguments)?});
    if let Some(id) = provider_id.filter(|id| id.starts_with("fc_")) {
        item["id"] = json!(id);
    }
    Ok(item)
}

/// Canonical call-order projection. Missing outputs are explicit historical
/// placeholders, not queued work and never instructions to invoke anything.
pub fn project(messages: &[Message], profile: &Profile) -> Result<Vec<Value>> {
    validate(messages)?;
    let active = crate::compaction::active_context(messages)?;
    project_active(&active, profile)
}

pub(crate) fn project_active(messages: &[&Message], profile: &Profile) -> Result<Vec<Value>> {
    let mut image_bytes = 0usize;
    let mut output = Vec::new();
    let mut pending: Vec<String> = Vec::new();
    let mut results = BTreeMap::<String, Value>::new();
    let mut active_owner: Option<&str> = None;
    fn settle(
        output: &mut Vec<Value>,
        pending: &mut Vec<String>,
        results: &mut BTreeMap<String, Value>,
    ) {
        for call in pending.drain(..) {
            let value = match results.remove(&call) {
                Some(Value::String(text)) if text.is_empty() => json!(EMPTY_RESULT),
                Some(value) => value,
                None => json!(MISSING_RESULT),
            };
            output.push(json!({"type":"function_call_output","call_id":call,"output":value}));
        }
        results.clear();
    }
    for message in messages {
        if let Some(ToolRecord::Result(record)) = &message.tool_record {
            if message.replay_eligible && active_owner == Some(record.assistant_id.as_str()) {
                // Count only content that is actually projected. An ineligible
                // historical assistant/result must not consume wire capacity.
                if profile.supports_images()
                    && let Some(content) = &record.content
                {
                    for block in &content.blocks {
                        if let crate::tool_content::ContentBlock::Image { data, .. } = block {
                            image_bytes = image_bytes.saturating_add(data.len());
                            if image_bytes > crate::provider::MAX_REQUEST_BYTES {
                                return Err(invalid("Serialized request exceeds 32 MiB"));
                            }
                        }
                    }
                }
                results.insert(
                    record.call_id.clone(),
                    record.content.as_ref().map_or_else(
                        || json!(message.text),
                        |content| content.provider_output(profile.supports_images()),
                    ),
                );
            }
            continue;
        }
        settle(&mut output, &mut pending, &mut results);
        active_owner = None;
        if !message.replay_eligible {
            continue;
        }
        if let Some(ToolRecord::Assistant(record)) = &message.tool_record {
            output.extend(assistant_items(message, record, profile)?);
            pending = record.calls.iter().map(|call| call.id.clone()).collect();
            active_owner = Some(&message.id);
            continue;
        }
        if message.compaction.is_some() {
            output.push(crate::compaction::provider_summary(message));
            continue;
        }
        match message.role.as_str() {
            "user" => output.push(json!({"role":"user","content":[{"type":"input_text","text":message.text}]})),
            "assistant" => output.push(json!({"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":message.text,"annotations":[]}]})),
            _ => return Err(invalid("Unsupported replay role in Rust session")),
        }
    }
    settle(&mut output, &mut pending, &mut results);
    Ok(output)
}
