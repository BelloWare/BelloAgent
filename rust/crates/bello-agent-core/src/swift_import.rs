//! A Swift chat as a Rust session: the rows `swift_journal` replays, carried
//! into the Rust model so the chat reads as it did in Swift and can go on in
//! Rust. The Swift files are never written; the import is a new Rust chat.
//!
//! Carried: the rows Swift shows (user messages, replies with their reasoning,
//! tool calls and results, compaction summaries as Rust checkpoints) and the
//! queue as a paused queue. Left out, and counted: progress rows and edit
//! markers (Rust has neither), rows an edit hid (they stay in the Swift
//! journal), results that answer no call of the reply before them, and queued
//! input with attachments or skills. Provider items are not carried: Rust
//! replays a chat from another connection by its text and calls (the portable
//! path), as it would any chat moved between connections. Rust's own checks
//! accept the session before it is returned.
use crate::compaction::{self, Checkpoint, REPLAY_PREFIX};
use crate::provider::ToolCall;
use crate::swift_journal::{Replay, Row};
use crate::tool_history::{
    AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
};
use crate::{Lane, Message, Result, RunState, Session, Submission, invalid};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// What an import left out, by kind.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Left {
    /// A compaction's or a request's progress rows.
    pub progress: usize,
    /// The marker an edit leaves where it branched.
    pub edit_markers: usize,
    /// Rows an edit hid, which Swift keeps as earlier versions.
    pub hidden: usize,
    /// Tool results that answer no call of the reply before them.
    pub unowned_results: usize,
    /// Compaction summaries Rust cannot check against the rows before them:
    /// shown, but the model is sent the rows they summarized.
    pub unchecked_summaries: usize,
    /// Queued input with attachments or skills.
    pub queued_with_content: usize,
    pub other: usize,
}

pub struct Imported {
    pub session: Session,
    pub left: Left,
}

/// The chat `replay` read, as a Rust session with id `id` and title `title`.
pub fn session(replay: &Replay, id: &str, title: &str) -> Result<Imported> {
    let binding = replay_binding(replay.binding.as_ref());
    let mut left = Left {
        hidden: replay
            .history
            .iter()
            .filter(|row| !replay.visible.iter().any(|shown| shown.id == row.id))
            .count(),
        ..Left::default()
    };
    let mut messages: Vec<Message> = Vec::new();
    let mut task: Option<String> = None;
    // The reply whose calls the next results answer, and its call ids.
    let mut owner: Option<(String, Vec<String>)> = None;
    for row in &replay.visible {
        match (row.role.as_str(), row.kind.as_deref()) {
            (_, Some("execution" | "requestLedger")) => left.progress += 1,
            (_, Some("branch")) => left.edit_markers += 1,
            ("user", _) => {
                owner = None;
                // Rust's task rule: a root on user rows only, each its own
                // or the task in progress (a steering message's).
                let root = match row.task_root_id.as_deref() {
                    Some(root) if task.as_deref() == Some(root) && root != row.id => {
                        root.to_owned()
                    }
                    _ => row.id.clone(),
                };
                task = Some(root.clone());
                let mut message = message(row, "user", "complete");
                message.text = row.display_text.clone().unwrap_or_else(|| row.text());
                message.task_root_id = Some(root);
                messages.push(message);
            }
            ("assistant", _) => {
                let state = if row.replay_eligible {
                    "completed"
                } else {
                    "interrupted"
                };
                let mut message = message(row, "assistant", state);
                message.reasoning = row.thinking();
                message.usage = usage(row.usage.as_ref());
                message.model = Some(binding.model.clone());
                let calls: Vec<ToolCall> = row
                    .tool_calls()
                    .filter_map(|call| {
                        Some(ToolCall {
                            id: call["id"].as_str()?.to_owned(),
                            name: call["name"].as_str()?.to_owned(),
                            arguments: call["arguments"].clone(),
                        })
                    })
                    .collect();
                owner = (!calls.is_empty()).then(|| {
                    (
                        row.id.clone(),
                        calls.iter().map(|call| call.id.clone()).collect(),
                    )
                });
                if !calls.is_empty() {
                    message.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
                        tool_batch_timing: None,
                        completion: if row.replay_eligible {
                            Completion::Complete
                        } else {
                            Completion::Incomplete
                        },
                        calls,
                        binding: binding.clone(),
                        provider_items: Vec::new(),
                    }));
                }
                messages.push(message);
            }
            ("toolResult", _) => {
                let call = row.tool_call_id.clone().unwrap_or_default();
                let Some((assistant, _)) =
                    owner.as_ref().filter(|(_, calls)| calls.contains(&call))
                else {
                    left.unowned_results += 1;
                    continue;
                };
                // Swift's card states (`AgentSession.cardState`); Rust keeps
                // the error flag true for every outcome but a completed one.
                let outcome = match row
                    .tool_stats
                    .as_ref()
                    .and_then(|stats| stats["outcome"].as_str())
                {
                    Some("completed") => ToolOutcome::Completed,
                    Some("unknown") => ToolOutcome::Unknown,
                    Some("not_executed") => ToolOutcome::NotExecuted,
                    Some("failed") => ToolOutcome::Failed,
                    _ if row.is_error => ToolOutcome::Failed,
                    _ => ToolOutcome::Completed,
                };
                let mut message = message(row, "toolResult", "completed");
                message.tool_record = Some(ToolRecord::Result(ResultRecord {
                    duration_us: None,
                    assistant_id: assistant.clone(),
                    call_id: call,
                    is_error: outcome != ToolOutcome::Completed,
                    outcome,
                    content: None,
                }));
                messages.push(message);
            }
            ("system", Some("compaction")) => {
                owner = None;
                let text = row.text();
                let summary = text
                    .strip_prefix(REPLAY_PREFIX)
                    .or_else(|| text.strip_prefix("Conversation summary:\n"))
                    .unwrap_or(&text)
                    .to_owned();
                let checked = checkpoint(row, &messages, &summary)
                    .map(|checkpoint| {
                        Message::compaction_summary(
                            row.id.clone(),
                            summary.clone(),
                            Some(checkpoint),
                        )
                    })
                    .filter(|summary| {
                        let mut candidate: Vec<Message> = messages.clone();
                        candidate.push(summary.clone());
                        compaction::active_context(&candidate).is_ok()
                    });
                match checked {
                    Some(summary) => messages.push(summary),
                    None => {
                        // Shown, never sent: the model keeps the rows it summarized.
                        left.unchecked_summaries += 1;
                        let mut shown = Message::compaction_summary(row.id.clone(), summary, None);
                        shown.replay_eligible = false;
                        messages.push(shown);
                    }
                }
            }
            _ => left.other += 1,
        }
    }
    let mut session = Session::new();
    session.id = id.to_owned();
    session.title = title.to_owned();
    session.messages = messages;
    // The queue comes paused: nothing imported runs until the reader resumes it.
    if let Some(state) = &replay.state {
        for (key, lane) in [("steering", Lane::Steering), ("queue", Lane::FollowUp)] {
            for item in state[key].as_array().into_iter().flatten() {
                let has_content = item["attachments"]
                    .as_array()
                    .is_some_and(|list| !list.is_empty())
                    || item["skills"]
                        .as_array()
                        .is_some_and(|list| !list.is_empty());
                let (Some(id), Some(text), false) = (
                    item["commandID"].as_str(),
                    item["text"].as_str(),
                    has_content,
                ) else {
                    left.queued_with_content += usize::from(has_content);
                    continue;
                };
                let mut submission = Submission::new(text.to_owned(), lane.clone());
                submission.id = id.to_owned();
                submission.model = item["model"].as_str().map(str::to_owned);
                session.pending.push(submission);
            }
        }
    }
    session.queue_paused = !session.pending.is_empty();
    session.state = RunState::Idle;
    session
        .validate_checkpoint()
        .map_err(|error| invalid(format!("The imported chat does not check out: {error}")))?;
    Ok(Imported { session, left })
}

fn message(row: &Row, role: &str, state: &str) -> Message {
    Message {
        task_root_id: None,
        user_content: None,
        id: row.id.clone(),
        role: role.to_owned(),
        text: row.text(),
        reasoning: String::new(),
        replay_eligible: row.replay_eligible,
        state: state.to_owned(),
        usage: Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
    }
}

/// Swift's usage (pi's shape: input without cached tokens) as the Responses
/// usage a Rust reply keeps.
fn usage(usage: Option<&Value>) -> Value {
    let Some(usage) = usage.filter(|usage| usage.is_object()) else {
        return Value::Null;
    };
    let count = |key: &str| usage[key].as_u64().unwrap_or(0);
    let (read, write) = (count("cacheRead"), count("cacheWrite"));
    json!({
        "input_tokens": count("input") + read + write,
        "output_tokens": count("output"),
        "total_tokens": count("totalTokens"),
        "input_tokens_details": {"cached_tokens": read, "cache_write_tokens": write},
    })
}

/// The connection a Swift chat was bound to, as Rust records a reply's: never
/// one of the reader's own connections, so its replies go back by text and
/// calls only.
fn replay_binding(binding: Option<&Value>) -> ReplayBinding {
    let binding = binding.cloned().unwrap_or(Value::Null);
    let endpoint = binding["endpointSHA256"]
        .as_str()
        .filter(|hash| {
            hash.len() == 64 && hash.bytes().all(|c| matches!(c, b'0'..=b'9' | b'a'..=b'f'))
        })
        .map_or_else(
            || format!("{:x}", Sha256::digest(b"swift-import")),
            str::to_owned,
        );
    let model = binding["model"]
        .as_str()
        .filter(|model| {
            !model.is_empty() && model.len() <= 256 && !model.chars().any(char::is_control)
        })
        .unwrap_or("swift-import");
    ReplayBinding {
        profile_id: "swift-import".into(),
        api: "openai-responses".into(),
        provider: "litellm".into(),
        model: model.to_owned(),
        endpoint_sha256: endpoint,
    }
}

/// A compaction summary's checkpoint in Rust's terms: the version 2 metadata
/// Swift wrote, or for a legacy summary the rows it kept against the context
/// before it, with character estimates where Swift recorded no counts.
fn checkpoint(row: &Row, messages: &[Message], summary: &str) -> Option<Checkpoint> {
    let ids = |value: &Value| -> Option<Vec<String>> {
        value
            .as_array()?
            .iter()
            .map(|id| id.as_str().map(str::to_owned))
            .collect()
    };
    let estimate = |text: &str| (text.chars().count() as u64).div_ceil(4);
    let metadata = row
        .compaction
        .as_ref()
        .filter(|metadata| !metadata.is_null());
    if let Some(metadata) = metadata {
        return Some(Checkpoint {
            version: 1,
            operation_id: metadata["operationId"]
                .as_str()
                .unwrap_or(&row.id)
                .to_owned(),
            source_ids: ids(&metadata["sourceIDs"])?,
            kept_ids: ids(&metadata["keptIDs"])?,
            protected_ids: ids(&metadata["protectedIDs"])?,
            before_estimated_tokens: metadata["before"]["tokens"].as_u64()?,
            after_estimated_tokens: metadata["after"]["tokens"].as_u64()?,
        });
    }
    let (kept, tokens) = row.kept.clone()?;
    let active = compaction::active_context(messages).ok()?;
    let after = estimate(summary)
        + active
            .iter()
            .filter(|message| kept.contains(&message.id))
            .map(|message| estimate(&message.text))
            .sum::<u64>();
    let before = tokens
        .and_then(|tokens| u64::try_from(tokens).ok())
        .unwrap_or_else(|| active.iter().map(|message| estimate(&message.text)).sum());
    Some(Checkpoint {
        version: 1,
        operation_id: row.id.clone(),
        source_ids: active.iter().map(|message| message.id.clone()).collect(),
        kept_ids: kept,
        protected_ids: Vec::new(),
        before_estimated_tokens: before,
        after_estimated_tokens: after,
    })
}

#[cfg(test)]
#[path = "swift_import_tests.rs"]
mod tests;
