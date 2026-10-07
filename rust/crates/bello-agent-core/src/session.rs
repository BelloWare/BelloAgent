use crate::{Delta, Error, Reply, Result, invalid};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Lane {
    FollowUp,
    Steering,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum RunState {
    Idle,
    Running,
    Paused,
    Error,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Submission {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub frozen_skills: Vec<crate::skills::FrozenSkill>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<crate::attachments::AttachmentRecord>,
    pub id: String,
    pub text: String,
    pub lane: Lane,
    pub model: Option<String>,
    pub effort: Option<String>,
}
impl Submission {
    pub fn new(text: String, lane: Lane) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            frozen_skills: Vec::new(),
            attachments: Vec::new(),
            text,
            lane,
            model: None,
            effort: None,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Message {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_root_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_content: Option<std::sync::Arc<crate::user_content::UserContent>>,
    pub id: String,
    pub role: String,
    pub text: String,
    pub reasoning: String,
    pub replay_eligible: bool,
    pub state: String,
    pub usage: Value,
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_record: Option<crate::tool_history::ToolRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compaction: Option<crate::compaction::Checkpoint>,
}
impl Message {
    fn new(
        id: String,
        role: &str,
        text: String,
        replay_eligible: bool,
        state: &str,
        model: Option<String>,
    ) -> Self {
        Self {
            id,
            role: role.into(),
            text,
            reasoning: String::new(),
            replay_eligible,
            state: state.into(),
            usage: Value::Null,
            model,
            task_root_id: None,
            user_content: None,
            tool_record: None,
            compaction: None,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct QueueEdit {
    pub edit_id: String,
    pub turn_id: String,
}
/// A certainty-checked answer for one edit identity. Cached Session snapshots
/// are for presentation and cannot establish this answer after a failed write.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueueEditStatus {
    pub edit_id: String,
    pub current_hold: Option<QueueEdit>,
    pub session_revision: u64,
    pub state: QueueEditState,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QueueEditState {
    Active { turn_id: String, text: String },
    Saved { digest: String },
    Cancelled,
    Removed,
    Unknown,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EditOutcome {
    pub edit_id: String,
    pub outcome: String,
    pub digest: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Session {
    #[serde(skip)]
    pub live_tools: Vec<crate::tool_history::LiveToolView>,
    pub version: u32,
    #[serde(default)]
    pub stream_generation: String,
    #[serde(default)]
    pub stream_sequence: u64,
    pub id: String,
    pub title: String,
    pub messages: Vec<Message>,
    pub pending: Vec<Submission>,
    pub state: RunState,
    pub queue_paused: bool,
    pub edit: Option<QueueEdit>,
    pub outcomes: Vec<EditOutcome>,
    pub active: Option<Submission>,
    pub active_reply: Option<String>,
    pub retry: Option<Submission>,
    pub error: Option<String>,
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compaction: Option<crate::compaction::Operation>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub compaction_history: Vec<crate::compaction::Operation>,
}
impl Session {
    pub fn new() -> Self {
        Self {
            live_tools: Vec::new(),
            version: 2,
            stream_generation: Uuid::new_v4().to_string(),
            stream_sequence: 0,
            id: Uuid::new_v4().to_string(),
            title: "New chat".into(),
            messages: Vec::new(),
            pending: Vec::new(),
            state: RunState::Idle,
            queue_paused: false,
            edit: None,
            outcomes: Vec::new(),
            active: None,
            active_reply: None,
            retry: None,
            error: None,
            revision: 0,
            compaction: None,
            compaction_history: Vec::new(),
        }
    }
    pub fn submit(&mut self, item: Submission) -> Result<()> {
        validate_submission(&item)?;
        if self.pending.len() >= 64 {
            return Err(invalid("The queue limit is 64 messages"));
        }
        if self.pending.iter().any(|v| v.id == item.id)
            || self.messages.iter().any(|v| v.id == item.id)
        {
            return Err(invalid("Turn identity was already accepted"));
        }
        if item.lane == Lane::Steering && self.state != RunState::Running {
            return Err(invalid("Steering requires an active run"));
        }
        self.pending.push(item);
        Ok(())
    }
    pub fn begin_edit(&mut self, turn_id: &str, edit_id: &str) -> Result<String> {
        validate_edit_identity(edit_id)?;
        validate_turn_identity(turn_id)?;
        self.validate_edits()?;
        if self.outcomes.iter().any(|v| v.edit_id == edit_id) {
            return Err(invalid("This edit was already resolved"));
        }
        if let Some(edit) = &self.edit
            && (edit.edit_id != edit_id || edit.turn_id != turn_id)
        {
            return Err(invalid("Finish or cancel the queued edit first"));
        }
        let item = self
            .pending
            .iter()
            .find(|v| v.id == turn_id)
            .ok_or_else(|| invalid("Message is no longer pending"))?;
        let text = item.text.clone();
        self.edit = Some(QueueEdit {
            edit_id: edit_id.into(),
            turn_id: turn_id.into(),
        });
        Ok(text)
    }
    pub fn resolve_edit(&mut self, edit_id: &str, outcome: &str, text: Option<&str>) -> Result<()> {
        validate_edit_identity(edit_id)?;
        self.validate_edits()?;
        if !["saved", "cancelled", "removed"].contains(&outcome) {
            return Err(invalid("Invalid edit outcome"));
        }
        if outcome == "saved" {
            let text = text.ok_or_else(|| invalid("Save requires text"))?;
            let attachments = self
                .edit
                .as_ref()
                .and_then(|edit| self.pending.iter().find(|item| item.id == edit.turn_id))
                .map(|item| (item.attachments.as_slice(), item.frozen_skills.as_slice()))
                .unwrap_or((&[], &[]));
            if self
                .outcomes
                .iter()
                .any(|outcome| outcome.edit_id == edit_id)
            {
                if text.len() > 262_144 {
                    return Err(invalid("Message exceeds 256 KiB"));
                }
            } else {
                validate_skill_input(text, attachments.0, !attachments.1.is_empty())?;
            }
        } else if text.is_some() {
            return Err(invalid("Cancel and Remove do not accept text"));
        }
        let digest = text.map(|text| format!("{:x}", Sha256::digest(text.as_bytes())));
        if let Some(previous) = self.outcomes.iter().find(|v| v.edit_id == edit_id) {
            if previous.outcome == outcome && previous.digest == digest {
                return Ok(());
            }
            return Err(invalid("This edit was resolved differently"));
        }
        let turn_id = match &self.edit {
            Some(edit) if edit.edit_id == edit_id => Some(edit.turn_id.clone()),
            _ if outcome == "cancelled" => None,
            _ => return Err(invalid("This queued edit is no longer open")),
        };
        if outcome == "saved" {
            let text = text.expect("Save text validated");
            self.pending
                .iter_mut()
                .find(|v| Some(v.id.as_str()) == turn_id.as_deref())
                .ok_or_else(|| invalid("Message is no longer pending"))?
                .text = text.into();
        } else if outcome == "removed" {
            self.pending
                .retain(|v| Some(v.id.as_str()) != turn_id.as_deref());
        }
        // An unknown Cancel fences a delayed Begin for only this identity.
        // It must never release a different edit's existing hold.
        if turn_id.is_some() {
            self.edit = None;
        }
        self.outcomes.push(EditOutcome {
            edit_id: edit_id.into(),
            outcome: outcome.into(),
            digest,
        });
        // Keep every edit identity for this initial format so delayed commands
        // cannot reacquire a forgotten hold. Bounded compaction is not ported.
        Ok(())
    }
    pub fn remove(&mut self, id: &str) -> Result<()> {
        if let Some(edit) = &self.edit
            && edit.turn_id == id
        {
            let id = edit.edit_id.clone();
            return self.resolve_edit(&id, "removed", None);
        }
        let n = self.pending.len();
        self.pending.retain(|v| v.id != id);
        if n == self.pending.len() {
            return Err(invalid("Message is no longer pending"));
        }
        Ok(())
    }
    pub fn reorder(&mut self, ids: &[String]) -> Result<()> {
        let following: Vec<_> = self
            .pending
            .iter()
            .filter(|v| v.lane == Lane::FollowUp)
            .collect();
        if ids.len() != following.len()
            || ids.iter().collect::<std::collections::HashSet<_>>().len() != ids.len()
            || ids.iter().any(|id| !following.iter().any(|v| &v.id == id))
        {
            return Err(Error::QueueOrder);
        }
        if self.edit.is_some() {
            return Err(invalid("Finish or cancel the queued edit first"));
        }
        let ordered: Vec<_> = ids
            .iter()
            .map(|id| (*following.iter().find(|v| &v.id == id).unwrap()).clone())
            .collect();
        self.pending.retain(|v| v.lane == Lane::Steering);
        self.pending.extend(ordered);
        Ok(())
    }
    /// Move the same pending follow-up behind all existing steering messages.
    /// The active request continues unchanged; this slice consumes steering at
    /// its next response boundary because production tools remain disabled.
    pub fn promote_to_steering(&mut self, id: &str) -> Result<()> {
        let index = self
            .pending
            .iter()
            .position(|item| item.id == id && item.lane == Lane::FollowUp)
            .ok_or_else(|| invalid("Message is no longer a pending follow-up"))?;
        if self.state != RunState::Running {
            return Err(invalid(
                "Steering requires an active run; the message stays queued",
            ));
        }
        if self.edit.is_some() {
            return Err(invalid("Finish or cancel the queued edit first"));
        }
        let mut item = self.pending.remove(index);
        item.lane = Lane::Steering;
        self.pending.push(item);
        Ok(())
    }
    pub fn start_next(&mut self) -> Result<Option<Submission>> {
        self.start_next_with_content(None)
    }
    pub(crate) fn start_next_with_content(
        &mut self,
        prepared: Option<PreparedUserInput>,
    ) -> Result<Option<Submission>> {
        if self.state == RunState::Running
            || self.queue_paused
            || self.edit.is_some()
            || self.pending.is_empty()
        {
            return Ok(None);
        }
        let index = self
            .pending
            .iter()
            .position(|v| v.lane == Lane::Steering)
            .unwrap_or(0);
        let item = self.pending[index].clone();
        let content = checked_prepared(&item, prepared)?;
        self.pending.remove(index);
        if self.messages.is_empty() {
            self.title = if item.text.is_empty() {
                submission_label(&item)
            } else {
                item.text.chars().take(60).collect()
            };
        }
        let mut message = Message::new(
            item.id.clone(),
            "user",
            item.text.clone(),
            true,
            "complete",
            item.model.clone(),
        );
        message.task_root_id = Some(item.id.clone());
        self.version = self.version.max(8);
        message.user_content = content;
        self.messages.push(message);
        self.activate(item.clone());
        Ok(Some(item))
    }
    pub(crate) fn activate(&mut self, item: Submission) {
        let id = Uuid::new_v4().to_string();
        self.messages.push(Message::new(
            id.clone(),
            "assistant",
            String::new(),
            false,
            "streaming",
            item.model.clone(),
        ));
        self.active = Some(item);
        self.active_reply = Some(id);
        self.state = RunState::Running;
        self.error = None;
    }
    pub fn retry_turn(&mut self) -> Result<Submission> {
        if self.state == RunState::Running || self.edit.is_some() {
            return Err(invalid("A run or queued edit is already active"));
        }
        let item = self
            .retry
            .clone()
            .ok_or_else(|| invalid("There is no failed or stopped request to retry"))?;
        self.queue_paused = false;
        self.activate(item.clone());
        Ok(item)
    }
    pub fn delta(&mut self, reply_id: &str, delta: Delta) -> Result<()> {
        if self.active_reply.as_deref() != Some(reply_id) {
            return Err(invalid("Stale response delta"));
        }
        let message = self
            .messages
            .iter_mut()
            .find(|v| v.id == reply_id)
            .ok_or_else(|| invalid("Missing active reply"))?;
        match delta {
            Delta::Text(text) => message.text.push_str(&text),
            Delta::Reasoning(text) => message.reasoning.push_str(&text),
            Delta::Tool { .. } => {}
        }
        Ok(())
    }
    pub fn finish(&mut self, reply_id: &str, result: Result<Reply>) -> Result<()> {
        if self.active_reply.as_deref() != Some(reply_id) {
            return Err(invalid("Stale response completion"));
        }
        let message = self
            .messages
            .iter_mut()
            .find(|v| v.id == reply_id)
            .ok_or_else(|| invalid("Missing active reply"))?;
        match result {
            Ok(reply) if reply.calls.is_empty() => {
                message.text = reply.text;
                message.reasoning = reply.reasoning;
                message.usage = reply.usage;
                message.state = reply.status;
                message.replay_eligible = true;
                self.state = RunState::Idle;
                self.retry = None;
            }
            result => {
                let error = match result {
                    Ok(reply) => {
                        message.text = reply.text;
                        message.reasoning = reply.reasoning;
                        message.usage = reply.usage;
                        invalid(
                            "Provider requested tools, which are not enabled in this Rust slice. No tool was executed.",
                        )
                    }
                    Err(error) => error,
                };
                self.state = if matches!(error, Error::Cancelled) {
                    RunState::Paused
                } else {
                    RunState::Error
                };
                self.queue_paused = true;
                self.error = Some(error.to_string());
                self.retry = self.active.clone();
                message.state = "interrupted".into();
                message.replay_eligible = false;
            }
        }
        self.active = None;
        self.active_reply = None;
        Ok(())
    }
    pub fn resume(&mut self) -> Result<()> {
        if self.state == RunState::Running || self.edit.is_some() {
            return Err(invalid("Finish the current run or queued edit first"));
        }
        self.queue_paused = false;
        self.state = RunState::Idle;
        self.error = None;
        Ok(())
    }
    fn has_retained_tool_content(&self) -> bool {
        self.messages
            .iter()
            .any(|message| match &message.tool_record {
                Some(crate::tool_history::ToolRecord::Result(record)) => record.content.is_some(),
                _ => false,
            })
    }
    fn has_mutation_tool_stats(&self) -> bool {
        self.messages
            .iter()
            .any(|message| match &message.tool_record {
                Some(crate::tool_history::ToolRecord::Result(record)) => record
                    .content
                    .as_ref()
                    .and_then(|content| content.stats.as_ref())
                    .is_some_and(|stats| stats.added.is_some() || stats.removed.is_some()),
                _ => false,
            })
    }
    fn has_failed_tool_content(&self) -> bool {
        self.messages.iter().any(|message| matches!(&message.tool_record,
            Some(crate::tool_history::ToolRecord::Result(record)) if record.content.is_some() && record.outcome == crate::tool_history::ToolOutcome::Failed))
    }
    fn has_user_attachments(&self) -> bool {
        self.messages.iter().any(|m| m.user_content.is_some())
            || self
                .pending
                .iter()
                .chain(self.active.iter())
                .chain(self.retry.iter())
                .any(|s| !s.attachments.is_empty())
    }
    fn has_skill_fields(&self) -> bool {
        self.messages.iter().any(|row| {
            row.task_root_id.is_some()
                || row
                    .user_content
                    .as_ref()
                    .is_some_and(|content| !content.skills.is_empty())
        }) || self
            .pending
            .iter()
            .chain(self.active.iter())
            .chain(self.retry.iter())
            .any(|item| !item.frozen_skills.is_empty())
    }
    fn validate_task_roots(&self) -> Result<()> {
        validate_task_provenance(&self.messages).map(|_| ())
    }
    fn validate_tool_history(&self) -> Result<()> {
        if self.version < 8 && self.has_skill_fields() {
            return Err(invalid(
                "Skills and task roots require Rust snapshot version 8",
            ));
        }
        self.validate_task_roots()?;
        if self.version < 7 && self.has_user_attachments() {
            return Err(invalid("User images require Rust snapshot version 7"));
        }
        for item in self
            .pending
            .iter()
            .chain(self.active.iter())
            .chain(self.retry.iter())
        {
            validate_submission(item)?;
        }
        for item in self
            .active
            .iter()
            .chain(self.retry.iter())
            .filter(|item| !item.attachments.is_empty() || !item.frozen_skills.is_empty())
        {
            if !self.messages.iter().any(|row| {
                row.id == item.id
                    && row.role == "user"
                    && row
                        .user_content
                        .as_ref()
                        .is_some_and(|content| content.validate_submission(item).is_ok())
            }) {
                return Err(invalid(
                    "Active image submission disagrees with retained user input",
                ));
            }
        }
        for row in &self.messages {
            if let Some(content) = &row.user_content {
                if row.role != "user" || row.tool_record.is_some() || row.compaction.is_some() {
                    return Err(invalid("Retained image content has no user owner"));
                }
                content.validate_display(&row.text)?;
            }
        }

        if self.version < 6 && self.has_failed_tool_content() {
            return Err(invalid(
                "Retained failed MCP content requires Rust snapshot version 6",
            ));
        }
        if self.version < 5 && self.has_mutation_tool_stats() {
            return Err(invalid(
                "Mutation tool statistics require Rust snapshot version 5",
            ));
        }
        if self.version < 4 && self.has_retained_tool_content() {
            return Err(invalid(
                "Retained tool content requires Rust snapshot version 4",
            ));
        }
        if self.version < 3
            && self
                .messages
                .iter()
                .any(|message| message.tool_record.is_some())
        {
            return Err(invalid(
                "Typed tool history requires Rust snapshot version 3",
            ));
        }
        crate::tool_history::validate(&self.messages)
    }
    fn validate_edits(&self) -> Result<()> {
        let mut ids = std::collections::HashSet::new();
        for outcome in &self.outcomes {
            validate_edit_identity(&outcome.edit_id)?;
            if !ids.insert(outcome.edit_id.as_str()) {
                return Err(invalid("Duplicate edit outcome identity"));
            }
            match outcome.outcome.as_str() {
                "saved" if outcome.digest.as_deref().is_some_and(valid_edit_digest) => {}
                "cancelled" | "removed" if outcome.digest.is_none() => {}
                _ => return Err(invalid("Invalid edit outcome or text digest")),
            }
        }
        if let Some(held) = &self.edit {
            validate_edit_identity(&held.edit_id)?;
            validate_turn_identity(&held.turn_id)?;
            if ids.contains(held.edit_id.as_str()) {
                return Err(invalid("Held edit identity already has an outcome"));
            }
            let mut pending = self.pending.iter().filter(|item| item.id == held.turn_id);
            let item = pending
                .next()
                .ok_or_else(|| invalid("Held edit has no pending message"))?;
            if pending.next().is_some() {
                return Err(invalid("Held edit has duplicate pending messages"));
            }
            validate_submission(item)?;
        }
        Ok(())
    }
    /// Pure model projection used by tests and draft comparison. Storage-backed
    /// callers must use Controller::edit_status or SessionStore::edit_status.
    pub(crate) fn queue_edit_status(&self, edit_id: &str) -> Result<QueueEditStatus> {
        validate_edit_identity(edit_id)?;
        self.validate_edits()?;
        let state = if let Some(held) = self.edit.as_ref().filter(|held| held.edit_id == edit_id) {
            let item = self
                .pending
                .iter()
                .find(|item| item.id == held.turn_id)
                .expect("held pending identity validated");
            QueueEditState::Active {
                turn_id: held.turn_id.clone(),
                text: item.text.clone(),
            }
        } else if let Some(outcome) = self
            .outcomes
            .iter()
            .find(|outcome| outcome.edit_id == edit_id)
        {
            match outcome.outcome.as_str() {
                "saved" => QueueEditState::Saved {
                    digest: outcome.digest.clone().expect("saved digest validated"),
                },
                "cancelled" => QueueEditState::Cancelled,
                "removed" => QueueEditState::Removed,
                _ => unreachable!("outcome validated"),
            }
        } else {
            QueueEditState::Unknown
        };
        Ok(QueueEditStatus {
            edit_id: edit_id.into(),
            current_hold: self.edit.clone(),
            session_revision: self.revision,
            state,
        })
    }
    fn validate_checkpoint(&self) -> Result<()> {
        self.validate_compaction()?;
        self.validate_tool_history()?;
        self.validate_edits()?;
        let active = self.active.is_some();
        let reply = self.active_reply.is_some();
        if self.state == RunState::Running {
            if !active || !reply {
                return Err(invalid(
                    "Running checkpoint is missing its active turn or reply",
                ));
            }
            let reply_id = self.active_reply.as_deref().expect("reply checked");
            if !self.messages.iter().any(|message| {
                message.id == reply_id
                    && message.role == "assistant"
                    && ((!message.replay_eligible && message.state == "streaming")
                        || self.active_tool_calls().is_some())
            }) {
                return Err(invalid("Running checkpoint has an invalid streaming reply"));
            }
        } else if active || reply {
            return Err(invalid(
                "Inactive checkpoint unexpectedly contains an active turn",
            ));
        }
        Ok(())
    }
    fn require_idle_for_host_change(&self) -> Result<()> {
        if self.state == RunState::Running
            || !self.pending.is_empty()
            || self.edit.is_some()
            || self.active.is_some()
            || self.active_reply.is_some()
        {
            return Err(invalid(
                "Finish active work, queued messages and held edits before changing project roots",
            ));
        }
        Ok(())
    }
    fn recover(&mut self) -> bool {
        if self.state != RunState::Running && self.edit.is_none() {
            return false;
        }
        if self
            .compaction
            .as_ref()
            .is_some_and(|operation| operation.is_running())
        {
            return self.recover_compaction().is_ok();
        }
        if self.recover_tools() {
            return true;
        }
        if let Some(id) = &self.active_reply
            && let Some(message) = self.messages.iter_mut().find(|v| &v.id == id)
        {
            message.state = "interrupted".into();
            message.replay_eligible = false;
        }
        self.retry = self.active.take().or(self.retry.take());
        self.active_reply = None;
        self.state = RunState::Paused;
        self.queue_paused = true;
        self.error=Some("Recovered after an interruption. Pending messages are paused; finish or cancel any held edit, then choose Resume or Retry.".into());
        true
    }
}
impl Default for Session {
    fn default() -> Self {
        Self::new()
    }
}
fn validate_edit_identity(edit_id: &str) -> Result<()> {
    if edit_id.is_empty() || edit_id.len() > 128 {
        return Err(invalid("Invalid edit identity"));
    }
    Ok(())
}
fn validate_turn_identity(turn_id: &str) -> Result<()> {
    if turn_id.is_empty() || turn_id.len() > 128 {
        return Err(invalid("Invalid held turn identity"));
    }
    Ok(())
}
fn valid_edit_digest(digest: &str) -> bool {
    digest.len() == 64
        && digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
pub(crate) fn validate_skill_input(
    text: &str,
    attachments: &[crate::attachments::AttachmentRecord],
    has_skills: bool,
) -> Result<()> {
    if text.trim().is_empty() && attachments.is_empty() && !has_skills {
        return Err(invalid("Enter a message or select an image"));
    }
    if text.len() > 262_144 {
        return Err(invalid("Message exceeds 256 KiB"));
    }
    crate::attachments::validate_selection(attachments)
}
pub(crate) fn validate_submission(item: &Submission) -> Result<()> {
    validate_skill_input(
        &item.text,
        &item.attachments,
        !item.frozen_skills.is_empty(),
    )?;
    crate::skills::validate_frozen_skills(&item.frozen_skills)
}
/// A legacy rootless prefix is readable. Once explicit provenance begins,
/// user rows form contiguous tasks; unknown steering may never erase a root.
pub(crate) fn validate_task_provenance(messages: &[Message]) -> Result<Option<&str>> {
    let mut current = None;
    for row in messages {
        if let Some(root) = row.task_root_id.as_deref() {
            if row.role != "user" || root.is_empty() || root.len() > 128 {
                return Err(invalid("Invalid user task-root provenance"));
            }
            if root == row.id {
                current = Some(root);
            } else if current != Some(root) {
                return Err(invalid("Foreign or noncontiguous user task root"));
            }
        } else if row.role == "user" && current.is_some() {
            return Err(invalid(
                "Missing user task-root provenance after skill adoption",
            ));
        }
        if row
            .user_content
            .as_ref()
            .is_some_and(|content| !content.skills.is_empty())
            && row.task_root_id.is_none()
        {
            return Err(invalid("Skill-bearing input requires task-root provenance"));
        }
    }
    Ok(current)
}
pub(crate) fn same_submission(a: &Submission, b: &Submission) -> bool {
    a.id == b.id
        && a.text == b.text
        && a.lane == b.lane
        && a.model == b.model
        && a.effort == b.effort
        && a.attachments == b.attachments
        && a.frozen_skills == b.frozen_skills
}
pub fn submission_label(item: &Submission) -> String {
    if !item.text.is_empty() {
        item.text.chars().take(60).collect()
    } else if !item.frozen_skills.is_empty() {
        item.frozen_skills
            .iter()
            .map(|s| format!("/{}", s.name))
            .collect::<Vec<_>>()
            .join(" ")
    } else {
        image_label(item.attachments.len())
    }
}
pub fn image_label(count: usize) -> String {
    if count == 1 {
        "Image".into()
    } else {
        format!("{count} images")
    }
}
/// Prepared bytes are inseparably bound to their exact captured input.
#[derive(Clone)]
pub(crate) struct PreparedUserInput {
    pub item: Submission,
    pub content: std::sync::Arc<crate::user_content::UserContent>,
}
pub(crate) fn checked_prepared(
    item: &Submission,
    prepared: Option<PreparedUserInput>,
) -> Result<Option<std::sync::Arc<crate::user_content::UserContent>>> {
    match prepared {
        Some(value)
            if same_submission(item, &value.item)
                && value.content.attachments == item.attachments =>
        {
            value.content.validate_submission(item)?;
            Ok(Some(value.content))
        }
        None if item.attachments.is_empty() && item.frozen_skills.is_empty() => Ok(None),
        _ => Err(invalid(
            "Image delivery requires preparation for this exact submission",
        )),
    }
}

/// Single-owner, atomic, synced snapshots. A failure never silently commits an
/// in-memory mutation, and an uncertain post-rename sync blocks further writes.
#[cfg(test)]
#[derive(Clone, Copy, Default)]
pub(crate) enum WriteFault {
    #[default]
    None,
    BeforeRename,
    AfterRename,
    StreamMetadata,
}
const MAX_SNAPSHOT_BYTES: usize = 256 * 1024 * 1024;
// Kept outside streamed text admission so cancellation/recovery can always
// write its small notice and state changes without making history unreadable.
const RECOVERY_RESERVE_BYTES: usize = 128 * 1024;

// Closing a descriptor alone can leave an advisory lock held by a descriptor
// inherited during another thread's fork/exec. Release ownership explicitly;
// the file close remains the fallback if unlock fails.
struct SessionLock(File);
impl SessionLock {
    fn acquire(file: File) -> Result<Self> {
        file.try_lock()
            .map_err(|_| invalid("This Rust session is already open elsewhere"))?;
        Ok(Self(file))
    }
}
impl Drop for SessionLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

/// A read-only observation of an existing, unloaded saved session while holding
/// its writer lock. Keep this lease alive through the host operation it admits.
/// Acquiring it never creates files, recovers interrupted work, confirms
/// durability, or writes a checkpoint or journal.
///
/// Known persistence uncertainty belongs to the live store/controller and must
/// stay fenced there: inspecting readable bytes cannot clear that uncertainty.
/// Hosts must reuse loaded controllers instead of replacing them with a lease.
#[must_use = "Keep the inspection lease alive through the admitted host operation"]
pub struct SessionInspectionLease {
    _lock: SessionLock,
    session: Session,
}
/// An idle inspection reduced to writer ownership only. Converting drops the
/// parsed history so inspecting many unloaded chats does not retain them all.
#[must_use = "Keep this idle lease alive through the admitted host operation"]
pub struct IdleSessionLease {
    _lock: SessionLock,
}
impl SessionInspectionLease {
    pub fn acquire(path: impl AsRef<Path>, expected_session_id: &str) -> Result<Self> {
        Uuid::parse_str(expected_session_id)
            .map_err(|_| invalid("Invalid inspected session identity"))?;
        let path = if path.as_ref().is_absolute() {
            path.as_ref().to_owned()
        } else {
            std::env::current_dir()?.join(path)
        };
        // Unlike opening a writer, inspection requires the existing lock and
        // checkpoint. A missing file is unknown state, never an empty chat.
        let lock_path = path.with_extension("lock");
        let lock = SessionLock::acquire(open_inspection_file(&lock_path, true)?)?;
        verify_inspection_file(&lock_path, &lock.0, &lock.0.metadata()?)?;

        let file = open_inspection_file(&path, false)?;
        let before = file.metadata()?;
        if before.len() > MAX_SNAPSHOT_BYTES as u64 {
            return Err(invalid("Session exceeds 256 MiB safety limit"));
        }
        let mut bytes = Vec::new();
        (&file)
            .take(MAX_SNAPSHOT_BYTES as u64 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > MAX_SNAPSHOT_BYTES {
            return Err(invalid("Session exceeds 256 MiB safety limit"));
        }
        verify_inspection_file(&path, &file, &before)?;
        let mut session: Session = crate::skill_schema::parse_snapshot(&bytes)?;
        if session.id != expected_session_id {
            return Err(invalid("The session file belongs to another chat"));
        }
        if ![1, 2, 3, 4, 5, 6, 7, 8].contains(&session.version) {
            return Err(invalid(
                "Unsupported Rust session format. Swift journals are not imported automatically.",
            ));
        }
        session.validate_checkpoint()?;
        if session.version == 1 {
            // Legacy snapshots predate the append journal. Observe the legacy
            // shape without the migration performed by SessionStore::open.
            if !session.stream_generation.is_empty() || session.stream_sequence != 0 {
                return Err(invalid("Legacy session has unknown stream journal state"));
            }
        } else {
            let replay = crate::stream_journal::replay_read_only(&path, &mut session)?;
            if replay.incomplete_tail {
                return Err(invalid(
                    "Session has an incomplete stream journal; reopen it before changing project roots",
                ));
            }
        }
        session.validate_checkpoint()?;
        Ok(Self {
            _lock: lock,
            session,
        })
    }

    /// Presentation and idle admission only; this is not a durability receipt.
    pub fn snapshot(&self) -> &Session {
        &self.session
    }

    /// Mirrors the source's busy-or-queued work check, including held edits.
    /// A stopped or failed chat with no active, queued or held work is idle.
    pub fn require_idle(&self) -> Result<()> {
        self.session.require_idle_for_host_change()
    }

    pub fn into_idle_lease(self) -> Result<IdleSessionLease> {
        self.require_idle()?;
        Ok(IdleSessionLease { _lock: self._lock })
    }
}

fn open_inspection_file(path: &Path, writable: bool) -> Result<File> {
    let before = fs::symlink_metadata(path)?;
    if !before.is_file() || before.file_type().is_symlink() {
        return Err(invalid(
            "Session inspection requires existing regular files",
        ));
    }
    let mut options = OpenOptions::new();
    options.read(true).write(writable);
    // A regular path can be replaced by a FIFO between metadata and open.
    // Never wait for its peer before descriptor identity/type validation.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        #[cfg(target_os = "linux")]
        const O_NONBLOCK: i32 = 0x800;
        #[cfg(target_os = "macos")]
        const O_NONBLOCK: i32 = 0x4;
        options.custom_flags(O_NONBLOCK);
    }
    let file = options.open(path)?;
    verify_inspection_file(path, &file, &before)?;
    Ok(file)
}

pub(crate) fn verify_inspection_file(
    path: &Path,
    file: &File,
    before: &fs::Metadata,
) -> Result<()> {
    let opened = file.metadata()?;
    let current = fs::symlink_metadata(path)?;
    for after in [&opened, &current] {
        if !after.is_file()
            || after.file_type().is_symlink()
            || after.len() != before.len()
            || after.modified()? != before.modified()?
        {
            return Err(invalid("Session file changed during inspection"));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if after.dev() != before.dev() || after.ino() != before.ino() {
                return Err(invalid("Session file identity changed during inspection"));
            }
        }
    }
    Ok(())
}

pub struct SessionStore {
    #[cfg(test)]
    pub(crate) fault: WriteFault,
    path: PathBuf,
    _lock: Option<SessionLock>,
    session: Session,
    uncertain: bool,
    retired: bool,
    journal: Option<File>,
    encoded_bytes: usize,
    snapshot_limit: usize,
}
impl SessionStore {
    /// An on-screen New chat has no file, lock, accepted input, or running work.
    pub fn pending() -> Self {
        let session = Session::new();
        let encoded_bytes = encode_snapshot(&session)
            .expect("empty session encodes")
            .len();
        Self {
            #[cfg(test)]
            fault: WriteFault::None,
            path: PathBuf::new(),
            _lock: None,
            session,
            uncertain: false,
            retired: false,
            journal: None,
            encoded_bytes,
            snapshot_limit: MAX_SNAPSHOT_BYTES,
        }
    }
    pub fn pending_with_id(id: &str) -> Result<Self> {
        Uuid::parse_str(id).map_err(|_| invalid("Invalid pending chat identity"))?;
        let mut store = Self::pending();
        store.session.id = id.into();
        store.encoded_bytes = encode_snapshot(&store.session)?.len();
        Ok(store)
    }
    pub(crate) fn tool_output_directory(&self) -> PathBuf {
        self.path
            .parent()
            .expect("persistent session parent")
            .join("tool-output")
    }
    pub(crate) fn is_never_materialized(&self) -> bool {
        self.path.as_os_str().is_empty() && !self.uncertain
    }
    pub fn is_persistent(&self) -> bool {
        self._lock.is_some()
    }
    pub fn persist_to(&mut self, path: impl AsRef<Path>) -> Result<()> {
        self.require_live_writer()?;
        if self.is_persistent() {
            let requested = if path.as_ref().is_absolute() {
                path.as_ref().to_owned()
            } else {
                std::env::current_dir()?.join(path.as_ref())
            };
            if requested != self.path {
                return Err(invalid("This chat is already stored at a different path"));
            }
            return Ok(());
        }
        if self.uncertain {
            return Err(invalid(
                "Session persistence is uncertain. Reopen before continuing.",
            ));
        }
        match Self::open_seeded(path.as_ref(), Some(self.session.clone())) {
            Ok(store) => {
                *self = store;
                Ok(())
            }
            Err(error) => {
                if matches!(error, Error::PersistenceUncertain(_)) {
                    self.uncertain = true;
                }
                Err(error)
            }
        }
    }
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_seeded(path.as_ref(), None)
    }
    /// Authority-aware composition must not create a missing saved chat or recover a
    /// different chat before checking its identity. Both checkpoint and lock
    /// must already exist; validate the ID under the same writer lock used by
    /// normal recovery, before migration, journal replay or checkpoint writes.
    pub fn open_existing_with_id(path: &Path, expected_id: &str) -> Result<Self> {
        Uuid::parse_str(expected_id).map_err(|_| invalid("Invalid saved chat identity"))?;
        if !path.is_absolute() {
            return Err(invalid("A saved chat requires an absolute checkpoint path"));
        }
        Self::open_seeded_checked(path, None, Some(expected_id), confirm_existing_checkpoint)
    }
    fn open_seeded(path: &Path, initial: Option<Session>) -> Result<Self> {
        Self::open_seeded_with_confirmation(path, initial, confirm_existing_checkpoint)
    }
    fn open_seeded_with_confirmation(
        path: &Path,
        initial: Option<Session>,
        confirm: impl FnOnce(&Path) -> Result<()>,
    ) -> Result<Self> {
        Self::open_seeded_checked(path, initial, None, confirm)
    }
    fn open_seeded_checked(
        path: &Path,
        initial: Option<Session>,
        existing_id: Option<&str>,
        confirm: impl FnOnce(&Path) -> Result<()>,
    ) -> Result<Self> {
        let path = if path.is_absolute() {
            path.to_owned()
        } else {
            std::env::current_dir()?.join(path)
        };
        let parent = path
            .parent()
            .ok_or_else(|| invalid("Session path has no parent"))?;
        if existing_id.is_none() {
            let mut directories = fs::DirBuilder::new();
            directories.recursive(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                directories.mode(0o700);
            }
            directories.create(parent)?;
        }
        let mut options = OpenOptions::new();
        options
            .read(true)
            .write(true)
            .create(existing_id.is_none())
            .truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let lock_path = path.with_extension("lock");
        let lock = if existing_id.is_some() {
            let lock = SessionLock::acquire(open_inspection_file(&lock_path, true)?)?;
            verify_inspection_file(&lock_path, &lock.0, &lock.0.metadata()?)?;
            lock
        } else {
            SessionLock::acquire(options.open(lock_path)?)?
        };
        let existing_file = if existing_id.is_some() {
            let file = open_inspection_file(&path, false)?;
            let before = file.metadata()?;
            Some((file, before))
        } else {
            None
        };
        let exists = existing_file.is_some() || path.exists();
        let mut session: Session = if let Some((file, before)) = &existing_file {
            if before.len() > MAX_SNAPSHOT_BYTES as u64 {
                return Err(invalid("Session exceeds 256 MiB safety limit"));
            }
            let mut bytes = Vec::new();
            file.take(MAX_SNAPSHOT_BYTES as u64 + 1)
                .read_to_end(&mut bytes)?;
            if bytes.len() > MAX_SNAPSHOT_BYTES {
                return Err(invalid("Session exceeds 256 MiB safety limit"));
            }
            verify_inspection_file(&path, file, before)?;
            crate::skill_schema::parse_snapshot(&bytes)?
        } else if exists {
            let metadata = fs::metadata(&path)?;
            if metadata.len() > 256 * 1024 * 1024 {
                return Err(invalid("Session exceeds 256 MiB safety limit"));
            }
            crate::skill_schema::parse_snapshot(&fs::read(&path)?)?
        } else {
            initial.clone().unwrap_or_default()
        };
        if existing_id.is_some_and(|expected| expected != session.id)
            || initial
                .as_ref()
                .is_some_and(|expected| expected.id != session.id)
        {
            return Err(invalid("The session file belongs to another chat"));
        }
        if ![1, 2, 3, 4, 5, 6, 7, 8].contains(&session.version) {
            return Err(invalid(
                "Unsupported Rust session format. Swift journals are not imported automatically.",
            ));
        }
        let migrated = session.version == 1;
        if migrated {
            session.version = 2;
            session.stream_generation = Uuid::new_v4().to_string();
            session.stream_sequence = 0;
        }
        session.validate_checkpoint()?;
        if let Some((file, before)) = &existing_file {
            // Confirm the validated descriptor instead of reopening a pathname
            // which could now name a different file or a blocking FIFO.
            verify_inspection_file(&path, file, before)?;
            file.sync_all()
                .map_err(|error| Error::PersistenceUncertain(error.to_string()))?;
            sync_committed_directory(parent)?;
            verify_inspection_file(&path, file, before)?;
        } else if exists {
            // Reading bytes after an uncertain rename does not prove durability.
            // Confirm the validated file and its directory without rewriting it.
            confirm(&path)?;
        }
        let old_generation = session.stream_generation.clone();
        let replay = crate::stream_journal::replay(&path, &mut session)?;
        let recovered = session.recover();
        if replay.incomplete_tail {
            session.error=Some("Recovered complete streamed text. An incomplete final record is preserved in the prior stream journal; pending messages are paused.".into());
            session.queue_paused = true;
            session.state = RunState::Paused;
        }
        let checkpoint = !exists || migrated || recovered || replay.exists;
        if checkpoint {
            session.stream_generation = Uuid::new_v4().to_string();
            session.stream_sequence = 0;
        }

        let encoded_bytes = encode_snapshot(&session)?.len();
        let store = Self {
            #[cfg(test)]
            fault: WriteFault::None,
            path,
            _lock: Some(lock),
            session,
            uncertain: false,
            retired: false,
            journal: None,
            encoded_bytes,
            snapshot_limit: MAX_SNAPSHOT_BYTES,
        };
        if checkpoint {
            store.write(&store.session, false)?;
            if replay.exists && !replay.incomplete_tail {
                let _ = fs::remove_file(crate::stream_journal::path(&store.path, &old_generation)?);
            }
        }
        Ok(store)
    }
    /// Authoritative only while this store is certain. A pending, unmaterialized
    /// empty chat is certain without a file; a failed commit is not.
    pub fn edit_status(&self, edit_id: &str) -> Result<QueueEditStatus> {
        self.require_certain()?;
        self.session.queue_edit_status(edit_id)
    }
    pub(crate) fn require_certain(&self) -> Result<()> {
        self.require_live_writer()?;
        if self.uncertain {
            return Err(Error::PersistenceUncertain(
                "Reopen the session before checking or changing a queued edit".into(),
            ));
        }
        Ok(())
    }
    pub(crate) fn require_idle_for_host_change(&self) -> Result<()> {
        self.require_certain()?;
        self.session.require_idle_for_host_change()
    }
    /// Controller-only ownership transfer: admission must already be fenced and
    /// every worker successfully joined. Cached snapshots remain readable, but
    /// this store can never regain write or authoritative recovery access.
    pub(crate) fn retire_writer(&mut self) {
        self.retired = true;
        self.journal = None;
        self._lock = None;
    }
    fn require_live_writer(&self) -> Result<()> {
        if self.retired {
            return Err(invalid("This session writer is permanently retired"));
        }
        Ok(())
    }
    pub fn snapshot_revision(&self) -> u64 {
        self.session.revision
    }
    pub fn snapshot(&self) -> Session {
        self.session.clone()
    }
    /// Borrow authoritative in-memory actor state without cloning history.
    /// Callers must hold the Controller's actor lock and check certainty.
    pub(crate) fn snapshot_ref(&self) -> &Session {
        &self.session
    }
    pub fn transact<T>(&mut self, change: impl FnOnce(&mut Session) -> Result<T>) -> Result<T> {
        self.require_live_writer()?;
        if !self.is_persistent() {
            return Err(invalid("Materialize this New chat before accepting input"));
        }
        if self.uncertain {
            return Err(invalid(
                "Session persistence is uncertain. Reopen before continuing.",
            ));
        }
        let mut next = self.session.clone();
        let result = change(&mut next)?;
        if next.has_skill_fields() {
            next.version = next.version.max(8);
        }
        if next.has_user_attachments() {
            next.version = next.version.max(7);
        }
        if next
            .messages
            .iter()
            .any(|message| message.tool_record.is_some())
        {
            let required_version = if next.has_failed_tool_content() {
                6
            } else if next.has_mutation_tool_stats() {
                5
            } else if next.has_retained_tool_content() {
                4
            } else {
                3
            };
            next.version = next.version.max(required_version);
        }
        next.revision = next
            .revision
            .checked_add(1)
            .ok_or_else(|| invalid("Session revision overflow"))?;
        let old_generation = self.session.stream_generation.clone();
        next.stream_generation = Uuid::new_v4().to_string();
        next.stream_sequence = 0;
        let encoded_bytes = match self.write(
            &next,
            next.state == RunState::Running || next.edit.is_some(),
        ) {
            Ok(bytes) => bytes,
            Err(error) => {
                if matches!(error, Error::PersistenceUncertain(_)) {
                    self.uncertain = true;
                }
                return Err(error);
            }
        };
        self.session = next;
        self.encoded_bytes = encoded_bytes;
        self.journal = None;
        // Cleanup is optional: the durable checkpoint names the new generation.
        // A failed removal leaves an unreachable old journal, never a lost input.
        let _ = fs::remove_file(crate::stream_journal::path(&self.path, &old_generation)?);
        Ok(result)
    }
    /// Append and synchronize only the new stream fragment. Accepted input and
    /// queue/edit commands still use atomic full checkpoints through transact.
    pub fn append_delta(&mut self, reply_id: &str, delta: Delta) -> Result<()> {
        self.require_live_writer()?;
        if !self.is_persistent() {
            return Err(invalid("Materialize this New chat before accepting output"));
        }
        if self.uncertain {
            return Err(invalid(
                "Session persistence is uncertain. Reopen before continuing.",
            ));
        }
        if self.session.active_reply.as_deref() != Some(reply_id)
            || !self
                .session
                .messages
                .iter()
                .any(|message| message.id == reply_id)
        {
            return Err(invalid("Stale response delta"));
        }
        let growth = encoded_delta_growth(&self.session, &delta)?;
        let next_size = self
            .encoded_bytes
            .checked_add(growth)
            .ok_or_else(|| invalid("Session size overflow"))?;
        if next_size > self.snapshot_limit.saturating_sub(RECOVERY_RESERVE_BYTES) {
            return Err(invalid(
                "Session is at its streaming capacity; accepted text is preserved with room for recovery",
            ));
        }
        let bytes = crate::stream_journal::encode(&self.session, reply_id, &delta)?;
        let created = self.journal.is_none();
        if created {
            self.journal = Some(crate::stream_journal::create(
                &crate::stream_journal::path(&self.path, &self.session.stream_generation)?,
            )?);
        }
        let file = self.journal.as_mut().expect("journal initialized");
        #[cfg(test)]
        let metadata = if matches!(self.fault, WriteFault::StreamMetadata) {
            Err(std::io::Error::other("injected journal metadata failure"))
        } else {
            file.metadata()
        };
        #[cfg(not(test))]
        let metadata = file.metadata();
        let length = match metadata {
            Ok(metadata) => metadata.len(),
            Err(error) => {
                self.uncertain = true;
                return Err(Error::PersistenceUncertain(format!(
                    "Cannot verify stream journal metadata: {error}"
                )));
            }
        };
        if length.saturating_add(bytes.len() as u64) > crate::stream_journal::MAX_JOURNAL_BYTES {
            return Err(invalid(
                "Stream journal exceeds 512 MiB; previous data is preserved",
            ));
        }
        if let Err(error) = crate::stream_journal::append(file, &bytes) {
            self.uncertain = true;
            return Err(Error::PersistenceUncertain(error.to_string()));
        }
        if created
            && let Err(error) =
                sync_committed_directory(self.path.parent().expect("snapshot directory checked"))
        {
            self.uncertain = true;
            return Err(error);
        }
        self.session.delta(reply_id, delta)?;
        self.session.stream_sequence += 1;
        self.session.revision += 1;
        self.encoded_bytes = next_size;
        Ok(())
    }
    fn write(&self, session: &Session, reserve_recovery: bool) -> Result<usize> {
        self.require_live_writer()?;
        let parent = self
            .path
            .parent()
            .ok_or_else(|| invalid("Missing snapshot directory"))?;
        // Serialize before opening the destination. serde_json::to_writer on
        // an unbuffered File issued thousands of syscalls per tiny delta.
        // One complete byte buffer keeps the same write -> fsync -> rename ->
        // directory fsync durability order without relying on a Drop flush.
        let bytes = encode_snapshot(session)?;
        let limit = self.snapshot_limit.saturating_sub(if reserve_recovery {
            RECOVERY_RESERVE_BYTES
        } else {
            0
        });
        if bytes.len() > limit {
            return Err(invalid(
                "Session checkpoint needs reserved room for interruption recovery; previous data is preserved",
            ));
        }
        if session.active_tool_calls().is_some() {
            // One Unknown result per call can exceed the fixed metadata
            // reserve. Admit the actual recovery shape before any invocation
            // (and again for every queue/edit checkpoint during the batch).
            let mut recovered = session.clone();
            recovered.recover_tools();
            if encode_snapshot(&recovered)?.len() > limit {
                return Err(invalid(
                    "Tool checkpoint needs room for every interrupted result; no new tool was executed",
                ));
            }
        }
        let temporary = parent.join(format!(".bello-agent-{}.tmp", Uuid::new_v4()));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let result = (|| -> Result<()> {
            let mut file = options.open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            #[cfg(test)]
            if matches!(self.fault, WriteFault::BeforeRename) {
                return Err(std::io::Error::other("injected pre-rename failure").into());
            }
            fs::rename(&temporary, &self.path)?;
            #[cfg(test)]
            if matches!(self.fault, WriteFault::AfterRename) {
                return Err(Error::PersistenceUncertain(
                    "injected post-rename failure".into(),
                ));
            }
            sync_committed_directory(parent)?;
            Ok(())
        })();
        if result.is_err() && temporary.exists() {
            let _ = fs::remove_file(temporary);
        }
        result.map(|()| bytes.len())
    }
}

fn encoded_delta_growth(session: &Session, delta: &Delta) -> Result<usize> {
    let text = match delta {
        Delta::Text(text) | Delta::Reasoning(text) => Some(text),
        Delta::Tool { .. } => None,
    };
    let text_bytes = if let Some(text) = text {
        serde_json::to_vec(text)?.len() - 2
    } else {
        0
    };
    let revision = session
        .revision
        .checked_add(1)
        .ok_or_else(|| invalid("Session revision overflow"))?;
    let sequence = session
        .stream_sequence
        .checked_add(1)
        .ok_or_else(|| invalid("Stream journal sequence overflow"))?;
    Ok(
        text_bytes + revision.to_string().len() - session.revision.to_string().len()
            + sequence.to_string().len()
            - session.stream_sequence.to_string().len(),
    )
}

/// Once rename has succeeded, both opening and syncing the parent can fail.
/// Either leaves the commit outcome uncertain and must block future writes.
fn sync_committed_directory(parent: &Path) -> Result<()> {
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| Error::PersistenceUncertain(error.to_string()))
}

fn confirm_existing_checkpoint(path: &Path) -> Result<()> {
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|error| Error::PersistenceUncertain(error.to_string()))?;
    sync_committed_directory(
        path.parent()
            .ok_or_else(|| invalid("Session path has no parent"))?,
    )
}

fn encode_snapshot(session: &Session) -> Result<Vec<u8>> {
    encode_snapshot_with_limit(session, MAX_SNAPSHOT_BYTES)
}

fn encode_snapshot_with_limit(session: &Session, maximum: usize) -> Result<Vec<u8>> {
    session.validate_tool_history()?;
    session.validate_edits()?;
    session.validate_compaction()?;
    struct BoundedBytes {
        bytes: Vec<u8>,
        maximum: usize,
    }
    impl std::io::Write for BoundedBytes {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if bytes.len() > self.maximum.saturating_sub(self.bytes.len()) {
                return Err(std::io::Error::other("snapshot byte limit"));
            }
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut bytes = BoundedBytes {
        bytes: Vec::new(),
        maximum: maximum.min(MAX_SNAPSHOT_BYTES),
    };
    if let Err(error) = serde_json::to_writer(&mut bytes, session) {
        if !error.is_io() {
            return Err(error.into());
        }
        return Err(invalid(
            "Session exceeds 256 MiB safety limit; previous snapshot is preserved",
        ));
    }
    std::io::Write::write_all(&mut bytes, b"\n").map_err(|_| {
        invalid("Session exceeds 256 MiB safety limit; previous snapshot is preserved")
    })?;
    Ok(bytes.bytes)
}

#[cfg(test)]
#[path = "session_inspection_tests.rs"]
mod inspection_tests;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unknown_cancel_tombstone_is_atomic_before_begin_and_beside_another_hold() {
        for unrelated_hold in [false, true] {
            for post_rename in [false, true] {
                let dir = tempfile::tempdir().unwrap();
                let path = dir.path().join("session.json");
                let mut store = SessionStore::open(&path).unwrap();
                let item = Submission::new("original".into(), Lane::FollowUp);
                store
                    .transact(|session| {
                        session.submit(item.clone())?;
                        if unrelated_hold {
                            session.begin_edit(&item.id, "unrelated")?;
                        }
                        Ok(())
                    })
                    .unwrap();
                let hold = store.snapshot().edit;
                let bytes = fs::read(&path).unwrap();
                store.fault = if post_rename {
                    WriteFault::AfterRename
                } else {
                    WriteFault::BeforeRename
                };
                let result = store.transact(|session| {
                    session.resolve_edit("cancel-before-begin", "cancelled", None)
                });
                assert!(result.is_err());
                assert_eq!(store.snapshot().edit, hold);
                assert!(store.snapshot().outcomes.is_empty());
                if post_rename {
                    assert!(matches!(result, Err(Error::PersistenceUncertain(_))));
                    assert!(store.edit_status("cancel-before-begin").is_err());
                } else {
                    assert_eq!(fs::read(&path).unwrap(), bytes);
                    assert_eq!(
                        store.edit_status("cancel-before-begin").unwrap().state,
                        QueueEditState::Unknown
                    );
                }
                drop(store);
                let mut reopened = SessionStore::open(&path).unwrap();
                assert_eq!(reopened.snapshot().edit, hold);
                if !post_rename {
                    reopened
                        .transact(|session| {
                            session.resolve_edit("cancel-before-begin", "cancelled", None)
                        })
                        .unwrap();
                }
                let status = reopened.edit_status("cancel-before-begin").unwrap();
                assert_eq!(status.state, QueueEditState::Cancelled);
                assert_eq!(status.current_hold, hold);
                assert!(
                    reopened
                        .transact(|session| session.begin_edit(&item.id, "cancel-before-begin"))
                        .is_err()
                );
                reopened
                    .transact(|session| {
                        session.resolve_edit("cancel-before-begin", "cancelled", None)
                    })
                    .unwrap();
                assert_eq!(reopened.snapshot().outcomes.len(), 1);
                assert_eq!(reopened.snapshot().edit, hold);
            }
        }
    }

    #[test]
    fn typed_edit_status_and_unknown_cancel_preserve_an_unrelated_hold() {
        let mut session = Session::new();
        let first = Submission::new("first".into(), Lane::FollowUp);
        let second = Submission::new("second".into(), Lane::FollowUp);
        session.submit(first.clone()).unwrap();
        session.submit(second.clone()).unwrap();
        session.begin_edit(&first.id, "held").unwrap();
        let held = session.edit.clone();
        session
            .resolve_edit("late-begin", "cancelled", None)
            .unwrap();
        assert_eq!(session.edit, held);
        assert_eq!(
            session.queue_edit_status("late-begin").unwrap().state,
            QueueEditState::Cancelled
        );
        assert_eq!(
            session
                .queue_edit_status("late-begin")
                .unwrap()
                .current_hold,
            held
        );
        assert_eq!(
            session.queue_edit_status("never-granted").unwrap().state,
            QueueEditState::Unknown
        );
        session
            .resolve_edit("late-begin", "cancelled", None)
            .unwrap();
        assert_eq!(session.outcomes.len(), 1);
        assert!(session.begin_edit(&second.id, "late-begin").is_err());
        assert!(session.start_next().unwrap().is_none());
        session
            .resolve_edit("held", "saved", Some("changed"))
            .unwrap();
        assert_eq!(
            session.queue_edit_status("held").unwrap().state,
            QueueEditState::Saved {
                digest: format!("{:x}", Sha256::digest(b"changed"))
            }
        );
        assert!(session.resolve_edit("held", "cancelled", None).is_err());
        session.begin_edit(&second.id, "removed").unwrap();
        session.resolve_edit("removed", "removed", None).unwrap();
        assert_eq!(
            session.queue_edit_status("removed").unwrap().state,
            QueueEditState::Removed
        );
        assert_eq!(session.pending.len(), 1);
        assert_eq!(session.pending[0].id, first.id);
    }

    #[test]
    fn edit_commands_reject_invalid_identities_and_cancel_remove_text_without_mutation() {
        let mut session = Session::new();
        let item = Submission::new("original".into(), Lane::FollowUp);
        session.submit(item.clone()).unwrap();
        session.begin_edit(&item.id, "held").unwrap();
        for (id, outcome, text) in [
            ("", "cancelled", None),
            ("held", "cancelled", Some("unexpected")),
            ("held", "removed", Some("")),
            ("held", "saved", None),
            ("held", "saved", Some("  ")),
            ("unknown", "saved", Some("rewrite")),
            ("unknown", "removed", None),
            ("unknown", "cancelled", Some("unexpected")),
        ] {
            let before = serde_json::to_value(&session).unwrap();
            assert!(session.resolve_edit(id, outcome, text).is_err());
            assert_eq!(serde_json::to_value(&session).unwrap(), before);
        }
        assert!(
            session
                .resolve_edit(&"x".repeat(129), "cancelled", None)
                .is_err()
        );
        assert!(session.begin_edit("", "other").is_err());
        assert!(session.begin_edit(&"x".repeat(129), "other").is_err());
        session.resolve_edit("held", "cancelled", None).unwrap();
        let before = serde_json::to_value(&session).unwrap();
        assert!(
            session
                .resolve_edit("held", "cancelled", Some("unexpected"))
                .is_err()
        );
        assert_eq!(serde_json::to_value(&session).unwrap(), before);
    }

    #[test]
    fn malformed_edit_checkpoints_are_rejected_on_open_and_encode_without_changing_bytes() {
        let item = Submission::new("original".into(), Lane::FollowUp);
        let mut session = Session::new();
        session.submit(item.clone()).unwrap();
        session.begin_edit(&item.id, "held").unwrap();
        let base = serde_json::to_value(&session).unwrap();
        let mut invalid = Vec::new();
        for id in ["".into(), "x".repeat(129)] {
            let mut value = base.clone();
            value["edit"]["edit_id"] = serde_json::json!(id);
            invalid.push(value);
        }
        for id in ["".into(), "x".repeat(129), "missing-turn".into()] {
            let mut value = base.clone();
            value["edit"]["turn_id"] = serde_json::json!(id);
            invalid.push(value);
        }
        let mut duplicate_pending = base.clone();
        duplicate_pending["pending"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::to_value(item).unwrap());
        invalid.push(duplicate_pending);
        let mut blank_held = base.clone();
        blank_held["pending"][0]["text"] = serde_json::json!("  ");
        invalid.push(blank_held);
        for (id, outcome, digest) in [
            ("", "cancelled", None),
            ("held", "cancelled", None),
            ("settled", "unknown", None),
            ("settled", "saved", None),
            ("settled", "saved", Some("not-a-digest".into())),
            ("settled", "saved", Some("A".repeat(64))),
            ("settled", "saved", Some("g".repeat(64))),
            ("settled", "cancelled", Some("0".repeat(64))),
            ("settled", "removed", Some("0".repeat(64))),
        ] {
            let mut value = base.clone();
            value["outcomes"] =
                serde_json::json!([{ "edit_id": id, "outcome": outcome, "digest": digest }]);
            invalid.push(value);
        }
        let mut duplicate_outcome = base.clone();
        duplicate_outcome["outcomes"] = serde_json::json!([
            { "edit_id": "settled", "outcome": "cancelled", "digest": null },
            { "edit_id": "settled", "outcome": "cancelled", "digest": null }
        ]);
        invalid.push(duplicate_outcome);
        for (index, value) in invalid.into_iter().enumerate() {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("invalid.json");
            let bytes = serde_json::to_vec_pretty(&value).unwrap();
            fs::write(&path, &bytes).unwrap();
            assert!(
                SessionStore::open_seeded_with_confirmation(&path, None, |_| {
                    panic!("invalid checkpoint {index} must be rejected before confirmation")
                })
                .is_err()
            );
            assert_eq!(fs::read(&path).unwrap(), bytes, "case {index}");
            let malformed: Session = serde_json::from_value(value).unwrap();
            assert!(encode_snapshot(&malformed).is_err(), "case {index}");
        }
    }

    #[test]
    fn invalid_edit_transaction_preserves_snapshot_and_remains_certain() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        let bytes = fs::read(&path).unwrap();
        assert!(
            store
                .transact(|session| {
                    session.outcomes.push(EditOutcome {
                        edit_id: "bad".into(),
                        outcome: "saved".into(),
                        digest: None,
                    });
                    Ok(())
                })
                .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), bytes);
        assert!(store.snapshot().outcomes.is_empty());
        assert_eq!(
            store.edit_status("bad").unwrap().state,
            QueueEditState::Unknown
        );
    }

    #[test]
    fn reopen_confirms_existing_bytes_and_propagates_sync_failure_without_rewrite() {
        for version in [2, 3] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("session.json");
            let mut session = Session::new();
            session.version = version;
            session
                .resolve_edit("cancelled-before-begin", "cancelled", None)
                .unwrap();
            let bytes =
                format!(" \n{}\n  ", serde_json::to_string_pretty(&session).unwrap()).into_bytes();
            fs::write(&path, &bytes).unwrap();
            let confirmed = std::cell::Cell::new(false);
            let store = SessionStore::open_seeded_with_confirmation(&path, None, |existing| {
                assert_eq!(fs::read(existing).unwrap(), bytes);
                confirm_existing_checkpoint(existing)?;
                confirmed.set(true);
                Ok(())
            })
            .unwrap();
            assert!(confirmed.get());
            assert_eq!(
                store.edit_status("cancelled-before-begin").unwrap().state,
                QueueEditState::Cancelled
            );
            assert_eq!(fs::read(&path).unwrap(), bytes);
            drop(store);
            for failure in ["file fsync", "directory fsync"] {
                let result = SessionStore::open_seeded_with_confirmation(&path, None, |existing| {
                    if failure == "directory fsync" {
                        File::open(existing)?.sync_all()?;
                    }
                    Err(Error::PersistenceUncertain(format!("injected {failure}")))
                });
                assert!(matches!(result, Err(Error::PersistenceUncertain(_))));
                assert_eq!(fs::read(&path).unwrap(), bytes);
            }
            let reopened = SessionStore::open(&path).unwrap();
            assert_eq!(
                reopened
                    .edit_status("cancelled-before-begin")
                    .unwrap()
                    .state,
                QueueEditState::Cancelled
            );
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
        let dir = tempfile::tempdir().unwrap();
        assert!(matches!(
            confirm_existing_checkpoint(&dir.path().join("missing.json")),
            Err(Error::PersistenceUncertain(_))
        ));
    }

    fn typed_fixture_profile() -> crate::Profile {
        serde_json::from_value(serde_json::json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":"http://127.0.0.1:12345","contextWindow":32000,"maxOutputTokens":4096})).unwrap()
    }
    fn typed_fixture_pair() -> Vec<Message> {
        use crate::tool_history::{
            AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
        };
        let mut assistant = Message::new(
            "tool-assistant".into(),
            "assistant",
            String::new(),
            true,
            "completed",
            None,
        );
        assistant.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
            completion: Completion::Complete,
            calls: vec![crate::provider::ToolCall {
                id: "fixture-call".into(),
                name: "ls".into(),
                arguments: serde_json::json!({"path":"fixture-only"}),
            }],
            binding: ReplayBinding::from_profile(&typed_fixture_profile()).unwrap(),
            provider_items: vec![],
        }));
        let mut result = Message::new(
            "tool-result".into(),
            "toolResult",
            "fixture result".into(),
            true,
            "completed",
            None,
        );
        result.tool_record = Some(ToolRecord::Result(ResultRecord {
            assistant_id: "tool-assistant".into(),
            call_id: "fixture-call".into(),
            is_error: false,
            outcome: ToolOutcome::Completed,
            content: None,
        }));
        vec![assistant, result]
    }

    #[test]
    fn typed_result_rename_failures_preserve_prior_or_committed_pair_exactly() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("typed.json");
        let mut store = SessionStore::open(&path).unwrap();
        store
            .transact(|s| {
                s.messages.push(typed_fixture_pair().remove(0));
                Ok(())
            })
            .unwrap();
        let before = serde_json::to_value(store.snapshot()).unwrap();
        let bytes = fs::read(&path).unwrap();
        store.fault = WriteFault::BeforeRename;
        assert!(
            store
                .transact(|s| {
                    s.messages.push(typed_fixture_pair().remove(1));
                    Ok(())
                })
                .is_err()
        );
        assert_eq!(serde_json::to_value(store.snapshot()).unwrap(), before);
        assert_eq!(fs::read(&path).unwrap(), bytes);
        store.fault = WriteFault::AfterRename;
        assert!(matches!(
            store.transact(|s| {
                s.messages.push(typed_fixture_pair().remove(1));
                Ok(())
            }),
            Err(Error::PersistenceUncertain(_))
        ));
        assert_eq!(serde_json::to_value(store.snapshot()).unwrap(), before);
        store.fault = WriteFault::None;
        assert!(
            store
                .transact(|s| {
                    s.messages.clear();
                    Ok(())
                })
                .is_err()
        );
        drop(store);
        let reopened = SessionStore::open(&path).unwrap();
        let snapshot = reopened.snapshot();
        assert_eq!(snapshot.version, 3);
        assert_eq!(snapshot.messages.len(), 2);
        let projection =
            crate::tool_history::project(&snapshot.messages, &typed_fixture_profile()).unwrap();
        assert_eq!(projection.len(), 2);
        assert_eq!(projection[1]["output"], "fixture result");
        drop(reopened);
        assert_eq!(
            serde_json::to_value(SessionStore::open(&path).unwrap().snapshot()).unwrap(),
            serde_json::to_value(snapshot).unwrap()
        );
    }

    #[test]
    fn typed_version_upgrade_and_pair_are_one_atomic_checkpoint() {
        for (fault, committed) in [
            (WriteFault::BeforeRename, false),
            (WriteFault::AfterRename, true),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("typed.json");
            let mut store = SessionStore::open(&path).unwrap();
            let before = fs::read(&path).unwrap();
            store.fault = fault;
            assert!(
                store
                    .transact(|s| {
                        s.messages.extend(typed_fixture_pair());
                        Ok(())
                    })
                    .is_err()
            );
            assert_eq!(store.snapshot().version, 2);
            assert!(store.snapshot().messages.is_empty());
            if !committed {
                assert_eq!(fs::read(&path).unwrap(), before);
            }
            drop(store);
            let recovered = SessionStore::open(&path).unwrap().snapshot();
            assert_eq!(recovered.version, if committed { 3 } else { 2 });
            assert_eq!(recovered.messages.len(), if committed { 2 } else { 0 });
        }
    }

    #[test]
    fn malformed_typed_transaction_never_changes_memory_or_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("typed.json");
        let mut store = SessionStore::open(&path).unwrap();
        store
            .transact(|s| {
                s.messages.extend(typed_fixture_pair());
                Ok(())
            })
            .unwrap();
        let before = serde_json::to_value(store.snapshot()).unwrap();
        let bytes = fs::read(&path).unwrap();
        assert!(
            store
                .transact(|s| {
                    if let Some(crate::tool_history::ToolRecord::Result(result)) =
                        &mut s.messages[1].tool_record
                    {
                        result.assistant_id = "wrong-owner".into();
                    }
                    Ok(())
                })
                .is_err()
        );
        assert_eq!(serde_json::to_value(store.snapshot()).unwrap(), before);
        assert_eq!(fs::read(&path).unwrap(), bytes);
        store
            .transact(|s| {
                s.title = "still writable".into();
                Ok(())
            })
            .unwrap();
    }

    #[test]
    fn typed_history_survives_torn_stream_tail_without_replaying_partial_reply() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("typed.json");
        let mut store = SessionStore::open(&path).unwrap();
        store
            .transact(|s| {
                s.messages.extend(typed_fixture_pair());
                s.submit(Submission::new("next".into(), Lane::FollowUp))?;
                s.start_next()?;
                Ok(())
            })
            .unwrap();
        let reply = store.snapshot().active_reply.unwrap();
        store
            .append_delta(&reply, Delta::Text("retained partial".into()))
            .unwrap();
        let journal =
            crate::stream_journal::path(&path, &store.snapshot().stream_generation).unwrap();
        drop(store);
        OpenOptions::new()
            .append(true)
            .open(&journal)
            .unwrap()
            .write_all(b"{torn")
            .unwrap();
        let original = fs::read(&journal).unwrap();
        let snapshot = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(snapshot.version, 8);
        assert_eq!(snapshot.state, RunState::Paused);
        assert_eq!(snapshot.messages.last().unwrap().text, "retained partial");
        assert!(!snapshot.messages.last().unwrap().replay_eligible);
        assert_eq!(fs::read(&journal).unwrap(), original);
        let projected =
            crate::tool_history::project(&snapshot.messages, &typed_fixture_profile()).unwrap();
        assert_eq!(projected.len(), 3);
        assert_eq!(projected[1]["output"], "fixture result");
        assert!(
            !serde_json::to_string(&projected)
                .unwrap()
                .contains("retained partial")
        );
    }

    #[test]
    fn torn_typed_snapshot_is_preserved_and_never_reset_to_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("typed.json");
        let mut store = SessionStore::open(&path).unwrap();
        store
            .transact(|s| {
                s.messages.extend(typed_fixture_pair());
                Ok(())
            })
            .unwrap();
        drop(store);
        let mut bytes = fs::read(&path).unwrap();
        bytes.truncate(bytes.len() / 2);
        fs::write(&path, &bytes).unwrap();
        assert!(SessionStore::open(&path).is_err());
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }
    #[test]
    fn pending_chat_accepts_nothing_until_materialized_and_keeps_identity() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("new.json");
        let mut store = SessionStore::pending();
        let id = store.snapshot().id;
        assert!(!store.is_persistent());
        assert!(!path.exists());
        assert!(
            store
                .transact(|session| session
                    .submit(Submission::new("must not accept".into(), Lane::FollowUp)))
                .is_err()
        );
        assert!(store.snapshot().pending.is_empty());
        store.persist_to(&path).unwrap();
        assert_eq!(store.snapshot().id, id);
        store
            .transact(|session| session.submit(Submission::new("accepted".into(), Lane::FollowUp)))
            .unwrap();
        drop(store);
        assert_eq!(SessionStore::open(path).unwrap().snapshot().id, id);
    }
    #[test]
    fn hold_blocks_every_lane_and_preserves_identity() {
        let mut s = Session::new();
        let one = Submission::new("first".into(), Lane::FollowUp);
        let id = one.id.clone();
        s.submit(one).unwrap();
        s.begin_edit(&id, "edit").unwrap();
        assert!(s.start_next().unwrap().is_none());
        s.submit(Submission::new("second".into(), Lane::FollowUp))
            .unwrap();
        s.resolve_edit("edit", "saved", Some("changed")).unwrap();
        s.resolve_edit("edit", "saved", Some("changed")).unwrap();
        assert!(s.resolve_edit("edit", "saved", Some("other")).is_err());
        let item = s.start_next().unwrap().unwrap();
        assert_eq!(item.id, id);
        assert_eq!(item.text, "changed");
    }
    #[test]
    fn unknown_cancel_cannot_later_acquire_hold() {
        let mut s = Session::new();
        let item = Submission::new("hi".into(), Lane::FollowUp);
        let id = item.id.clone();
        s.submit(item).unwrap();
        s.resolve_edit("cancelled-early", "cancelled", None)
            .unwrap();
        assert!(s.begin_edit(&id, "cancelled-early").is_err());
    }
    #[test]
    fn stop_keeps_partial_out_of_replay_and_queue_paused() {
        let mut s = Session::new();
        s.submit(Submission::new("hi".into(), Lane::FollowUp))
            .unwrap();
        s.start_next().unwrap();
        let id = s.active_reply.clone().unwrap();
        s.delta(&id, Delta::Text("partial".into())).unwrap();
        s.submit(Submission::new("later".into(), Lane::FollowUp))
            .unwrap();
        s.finish(&id, Err(Error::Cancelled)).unwrap();
        assert!(s.start_next().unwrap().is_none());
        assert!(!s.messages.last().unwrap().replay_eligible);
        s.retry_turn().unwrap();
        assert_eq!(s.messages.iter().filter(|v| v.role == "user").count(), 1);
    }
    #[test]
    fn restart_pauses_active_run_and_retains_held_edit() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        {
            let mut store = SessionStore::open(&path).unwrap();
            store
                .transact(|s| {
                    s.submit(Submission::new("hi".into(), Lane::FollowUp))?;
                    s.start_next()?;
                    let item = Submission::new("waiting".into(), Lane::FollowUp);
                    let id = item.id.clone();
                    s.submit(item)?;
                    s.begin_edit(&id, "edit")?;
                    Ok(())
                })
                .unwrap();
        }
        let store = SessionStore::open(&path).unwrap();
        let s = store.snapshot();
        assert_eq!(s.state, RunState::Paused);
        assert!(s.queue_paused);
        assert_eq!(s.edit.unwrap().edit_id, "edit");
        assert!(!s.messages.last().unwrap().replay_eligible);
    }
    #[test]
    fn mutation_validation_rolls_back_and_lock_excludes_second_owner() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        assert!(SessionStore::open(&path).is_err());
        let rev = store.snapshot().revision;
        assert!(
            store
                .transact(|s| {
                    s.title = "bad".into();
                    Err::<(), _>(invalid("rejected"))
                })
                .is_err()
        );
        assert_eq!(store.snapshot().title, "New chat");
        assert_eq!(store.snapshot().revision, rev);
    }
    fn reordered_ids() -> Vec<String> {
        ["follow-after", "follow-before", "promoted"]
            .map(String::from)
            .to_vec()
    }
    fn expected_reordered_pending(session: &Session) -> Vec<Submission> {
        // Explicit indices independently check both the stable steering lane
        // and the exact requested follow-up order, including every payload.
        [1, 3, 4, 0, 2]
            .map(|index| session.pending[index].clone())
            .to_vec()
    }
    #[test]
    fn reorder_preserves_full_submissions_steering_and_active_run() {
        let mut session = promotion_fixture();
        for (item, effort) in session
            .pending
            .iter_mut()
            .zip(["low", "medium", "high", "medium", "low"])
        {
            item.effort = Some(effort.into());
        }
        let mut expected = session.clone();
        expected.pending = expected_reordered_pending(&session);
        session.reorder(&reordered_ids()).unwrap();
        assert_eq!(
            serde_json::to_vec(&session).unwrap(),
            serde_json::to_vec(&expected).unwrap()
        );
        // An identical repeated order is valid and retains the full payload.
        session.reorder(&reordered_ids()).unwrap();
        assert_eq!(
            serde_json::to_vec(&session).unwrap(),
            serde_json::to_vec(&expected).unwrap()
        );
        Session::new().reorder(&[]).unwrap();
    }
    #[test]
    fn reorder_uses_typed_queue_order_for_every_membership_mismatch_without_mutation() {
        for ids in [
            vec![],
            vec!["follow-before", "promoted"],
            vec!["follow-before", "promoted", "follow-after", "extra"],
            vec!["follow-before", "follow-before", "follow-after"],
            vec!["follow-before", "missing", "follow-after"],
            vec!["follow-before", "steer-before", "follow-after"],
        ] {
            let mut session = promotion_fixture();
            let before = serde_json::to_vec(&session).unwrap();
            let ids = ids.into_iter().map(String::from).collect::<Vec<_>>();
            let error = session.reorder(&ids).unwrap_err();
            assert!(matches!(error, Error::QueueOrder));
            assert_eq!(
                error.to_string(),
                "The queue changed while you were dragging, so nothing was moved. Drag again."
            );
            assert_eq!(serde_json::to_vec(&session).unwrap(), before);
        }
        for held_id in ["follow-before", "steer-before"] {
            let mut session = promotion_fixture();
            session.begin_edit(held_id, "held-edit").unwrap();
            let before = serde_json::to_vec(&session).unwrap();
            assert!(matches!(
                session.reorder(&reordered_ids()),
                Err(Error::Invalid(message)) if message == "Finish or cancel the queued edit first"
            ));
            assert_eq!(serde_json::to_vec(&session).unwrap(), before);
            // Like the Swift queue, a stale drag takes precedence over an
            // edit acquired in either lane while that drag was in progress.
            let captured_order = reordered_ids();
            session.remove("promoted").unwrap();
            let before = serde_json::to_vec(&session).unwrap();
            assert!(matches!(
                session.reorder(&captured_order),
                Err(Error::QueueOrder)
            ));
            assert_eq!(serde_json::to_vec(&session).unwrap(), before);
        }
    }
    #[test]
    fn stale_reorder_after_removal_delivery_promotion_or_addition_preserves_committed_bytes() {
        for change in ["remove", "deliver", "promote", "add"] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("reorder.json");
            let mut store = SessionStore::open(&path).unwrap();
            store
                .transact(|session| {
                    *session = promotion_fixture();
                    Ok(())
                })
                .unwrap();
            let captured_order = reordered_ids();
            store
                .transact(|session| {
                    match change {
                        "remove" => session.remove("promoted")?,
                        "promote" => session.promote_to_steering("promoted")?,
                        "add" => session
                            .submit(Submission::new("added during drag".into(), Lane::FollowUp))?,
                        "deliver" => {
                            for id in ["steer-before", "steer-after", "follow-before"] {
                                let reply = session.active_reply.clone().unwrap();
                                session.finish(&reply, Err(Error::Cancelled))?;
                                session.resume()?;
                                assert_eq!(session.start_next()?.unwrap().id, id);
                            }
                        }
                        _ => unreachable!(),
                    }
                    Ok(())
                })
                .unwrap();
            let before = serde_json::to_vec(&store.snapshot()).unwrap();
            let bytes = fs::read(&path).unwrap();
            assert!(matches!(
                store.transact(|session| session.reorder(&captured_order)),
                Err(Error::QueueOrder)
            ));
            assert_eq!(serde_json::to_vec(&store.snapshot()).unwrap(), before);
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
    }
    #[test]
    fn reorder_rename_failures_preserve_prior_or_committed_order_and_stream_on_reopen() {
        for (fault, committed) in [
            (WriteFault::BeforeRename, false),
            (WriteFault::AfterRename, true),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("reorder.json");
            let mut store = SessionStore::open(&path).unwrap();
            store
                .transact(|session| {
                    *session = promotion_fixture();
                    Ok(())
                })
                .unwrap();
            let reply = store.snapshot().active_reply.unwrap();
            store
                .append_delta(&reply, Delta::Text("retained once".into()))
                .unwrap();
            let before = store.snapshot();
            let bytes = fs::read(&path).unwrap();
            let journal_path =
                crate::stream_journal::path(&path, &before.stream_generation).unwrap();
            let journal_bytes = fs::read(&journal_path).unwrap();
            store.fault = fault;
            let error = store
                .transact(|session| session.reorder(&reordered_ids()))
                .unwrap_err();
            assert_eq!(matches!(error, Error::PersistenceUncertain(_)), committed);
            assert_eq!(
                serde_json::to_vec(&store.snapshot()).unwrap(),
                serde_json::to_vec(&before).unwrap()
            );
            assert_eq!(fs::read(&journal_path).unwrap(), journal_bytes);
            store.fault = WriteFault::None;
            let expected_pending = if committed {
                assert!(
                    store
                        .transact(|session| session.reorder(&reordered_ids()))
                        .is_err()
                );
                assert!(
                    store
                        .append_delta(&reply, Delta::Text("must not append".into()))
                        .is_err()
                );
                let persisted: Session = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
                assert_eq!(
                    serde_json::to_vec(&persisted.pending).unwrap(),
                    serde_json::to_vec(&expected_reordered_pending(&before)).unwrap()
                );
                expected_reordered_pending(&before)
            } else {
                assert_eq!(fs::read(&path).unwrap(), bytes);
                store
                    .append_delta(&reply, Delta::Text(" after failure".into()))
                    .unwrap();
                before.pending.clone()
            };
            drop(store);
            let reopened = SessionStore::open(&path).unwrap().snapshot();
            assert_eq!(
                serde_json::to_vec(&reopened.pending).unwrap(),
                serde_json::to_vec(&expected_pending).unwrap()
            );
            assert_eq!(reopened.state, RunState::Paused);
            assert!(reopened.queue_paused);
            assert_eq!(
                serde_json::to_vec(&reopened.retry).unwrap(),
                serde_json::to_vec(&before.active).unwrap()
            );
            assert_eq!(reopened.messages.len(), 2);
            assert_eq!(
                reopened.messages.last().unwrap().text,
                if committed {
                    "retained once"
                } else {
                    "retained once after failure"
                }
            );
            assert!(!reopened.messages.last().unwrap().replay_eligible);
            assert_eq!(
                serde_json::to_vec(&SessionStore::open(&path).unwrap().snapshot()).unwrap(),
                serde_json::to_vec(&reopened).unwrap()
            );
        }
    }
    fn promotion_fixture() -> Session {
        let mut session = Session::new();
        session
            .submit(Submission::new("active".into(), Lane::FollowUp))
            .unwrap();
        session.start_next().unwrap().unwrap();
        for (id, lane) in [
            ("follow-before", Lane::FollowUp),
            ("steer-before", Lane::Steering),
            ("promoted", Lane::FollowUp),
            ("steer-after", Lane::Steering),
            ("follow-after", Lane::FollowUp),
        ] {
            session
                .submit(Submission {
                    frozen_skills: Vec::new(),
                    attachments: Vec::new(),
                    id: id.into(),
                    text: format!("{id}: {}\ncomplete Unicode text 🦋", "x".repeat(2048)),
                    lane,
                    model: Some(format!("captured-{id}")),
                    effort: Some("high".into()),
                })
                .unwrap();
        }
        session
    }
    #[test]
    fn promotion_moves_same_submission_to_steering_tail_without_touching_active_run() {
        let mut session = promotion_fixture();
        let mut expected = session.clone();
        let mut promoted = expected.pending.remove(2);
        promoted.lane = Lane::Steering;
        expected.pending.push(promoted);
        session.promote_to_steering("promoted").unwrap();
        assert_eq!(
            serde_json::to_value(&session).unwrap(),
            serde_json::to_value(expected).unwrap()
        );
        assert_eq!(
            session
                .pending
                .iter()
                .filter(|item| item.lane == Lane::Steering)
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            ["steer-before", "steer-after", "promoted"]
        );
        assert_eq!(
            session
                .pending
                .iter()
                .filter(|item| item.lane == Lane::FollowUp)
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            ["follow-before", "follow-after"]
        );
    }
    #[test]
    fn promotion_rejects_stale_steering_inactive_and_any_edit_hold_without_mutation() {
        for (id, state, hold) in [
            ("missing", RunState::Running, None),
            ("steer-before", RunState::Running, None),
            ("promoted", RunState::Idle, None),
            ("promoted", RunState::Paused, None),
            ("promoted", RunState::Error, None),
            ("promoted", RunState::Running, Some("promoted")),
            ("promoted", RunState::Running, Some("follow-before")),
            ("promoted", RunState::Running, Some("steer-before")),
        ] {
            let mut session = promotion_fixture();
            if state != RunState::Running {
                let reply = session.active_reply.clone().unwrap();
                session.finish(&reply, Err(Error::Cancelled)).unwrap();
                session.state = state;
                session.queue_paused = session.state != RunState::Idle;
            }
            if let Some(hold) = hold {
                session.begin_edit(hold, "held-edit").unwrap();
            }
            let before = serde_json::to_value(&session).unwrap();
            assert!(session.promote_to_steering(id).is_err());
            assert_eq!(serde_json::to_value(session).unwrap(), before);
        }
        let mut session = promotion_fixture();
        let active = session.active.as_ref().unwrap().id.clone();
        let before = serde_json::to_value(&session).unwrap();
        assert!(session.promote_to_steering(&active).is_err());
        assert_eq!(serde_json::to_value(session).unwrap(), before);
    }
    #[test]
    fn promotion_rename_failures_keep_memory_atomic_and_reopen_exact_durable_lane() {
        for (fault, committed) in [
            (WriteFault::BeforeRename, false),
            (WriteFault::AfterRename, true),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("promotion.json");
            let mut store = SessionStore::open(&path).unwrap();
            store
                .transact(|session| {
                    *session = promotion_fixture();
                    Ok(())
                })
                .unwrap();
            let reply = store.snapshot().active_reply.unwrap();
            store
                .append_delta(&reply, Delta::Text("retained once".into()))
                .unwrap();
            let before = store.snapshot();
            let bytes = fs::read(&path).unwrap();
            store.fault = fault;
            let failure = store
                .transact(|session| session.promote_to_steering("promoted"))
                .unwrap_err();
            assert_eq!(matches!(failure, Error::PersistenceUncertain(_)), committed);
            assert_eq!(
                serde_json::to_value(store.snapshot()).unwrap(),
                serde_json::to_value(&before).unwrap()
            );
            store.fault = WriteFault::None;
            if committed {
                assert!(
                    store
                        .transact(|session| session.promote_to_steering("follow-before"))
                        .is_err()
                );
                assert!(
                    store
                        .append_delta(&reply, Delta::Text("must not append".into()))
                        .is_err()
                );
            } else {
                assert_eq!(fs::read(&path).unwrap(), bytes);
                // A rejected checkpoint leaves the original stream writable.
                store
                    .append_delta(&reply, Delta::Text(" after failure".into()))
                    .unwrap();
            }
            drop(store);
            let reopened = SessionStore::open(&path).unwrap().snapshot();
            let mut expected_pending = before.pending;
            if committed {
                let mut promoted = expected_pending.remove(2);
                promoted.lane = Lane::Steering;
                expected_pending.push(promoted);
            }
            assert_eq!(
                serde_json::to_value(&reopened.pending).unwrap(),
                serde_json::to_value(expected_pending).unwrap()
            );
            assert_eq!(reopened.state, RunState::Paused);
            assert!(reopened.queue_paused);
            assert_eq!(
                serde_json::to_value(&reopened.retry).unwrap(),
                serde_json::to_value(before.active).unwrap()
            );
            assert_eq!(reopened.messages.len(), 2);
            assert_eq!(
                reopened.messages.last().unwrap().text,
                if committed {
                    "retained once"
                } else {
                    "retained once after failure"
                }
            );
            assert!(!reopened.messages.last().unwrap().replay_eligible);
            assert_eq!(
                serde_json::to_value(SessionStore::open(&path).unwrap().snapshot()).unwrap(),
                serde_json::to_value(reopened).unwrap()
            );
        }
    }
    #[test]
    fn failed_write_preserves_memory_and_disk_then_uncertain_write_blocks() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        store.fault = WriteFault::BeforeRename;
        assert!(
            store
                .transact(|s| {
                    s.title = "not committed".into();
                    Ok(())
                })
                .is_err()
        );
        assert_eq!(store.snapshot().title, "New chat");
        let disk: Session = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(disk.title, "New chat");
        store.fault = WriteFault::AfterRename;
        assert!(matches!(
            store.transact(|s| {
                s.title = "uncertain".into();
                Ok(())
            }),
            Err(Error::PersistenceUncertain(_))
        ));
        store.fault = WriteFault::None;
        assert!(
            store
                .transact(|s| {
                    s.title = "must not overwrite".into();
                    Ok(())
                })
                .is_err()
        );
        drop(store);
        let reopened = SessionStore::open(&path).unwrap();
        assert_eq!(reopened.snapshot().title, "uncertain");
    }
    #[cfg(unix)]
    #[test]
    fn snapshots_and_locks_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let _store = SessionStore::open(&path).unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(path.with_extension("lock"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    #[test]
    fn encoding_finishes_json_and_newline_before_any_disk_write() {
        let mut session = Session::new();
        session
            .submit(Submission::new(
                "Unicode héllo\nsecond line".into(),
                Lane::FollowUp,
            ))
            .unwrap();
        let bytes = encode_snapshot(&session).unwrap();
        assert_eq!(bytes.last(), Some(&b'\n'));
        let reopened: Session = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(reopened.pending[0].text, session.pending[0].text);
        assert_eq!(reopened.id, session.id);
    }
    #[test]
    fn missing_directory_after_rename_is_also_uncertain() {
        let dir = tempfile::tempdir().unwrap();
        assert!(matches!(
            sync_committed_directory(&dir.path().join("missing")),
            Err(Error::PersistenceUncertain(_))
        ));
    }
    fn active_store(path: &Path) -> SessionStore {
        let mut store = SessionStore::open(path).unwrap();
        store
            .transact(|session| {
                session.submit(Submission::new("input".into(), Lane::FollowUp))?;
                session.start_next()?;
                Ok(())
            })
            .unwrap();
        store
    }
    #[test]
    fn stream_fragments_do_not_rewrite_checkpoint_and_recover_after_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let original = fs::read(&path).unwrap();
        let reply = store.snapshot().active_reply.unwrap();
        let generation = store.snapshot().stream_generation;
        store
            .append_delta(&reply, Delta::Text("héllo\nworld".into()))
            .unwrap();
        assert_eq!(fs::read(&path).unwrap(), original);
        let journal = crate::stream_journal::path(&path, &generation).unwrap();
        assert!(journal.exists());
        drop(store);
        let reopened = SessionStore::open(&path).unwrap();
        let session = reopened.snapshot();
        assert_eq!(session.messages.last().unwrap().text, "héllo\nworld");
        assert!(!session.messages.last().unwrap().replay_eligible);
        assert_eq!(session.state, RunState::Paused);
        assert!(session.queue_paused);
        assert!(!journal.exists());
        assert_ne!(session.stream_generation, generation);
    }
    #[test]
    fn command_checkpoint_rotates_stream_generation_without_duplicate_text() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let reply = store.snapshot().active_reply.unwrap();
        let before = store.snapshot().stream_generation;
        store
            .append_delta(&reply, Delta::Text("first".into()))
            .unwrap();
        store
            .transact(|session| session.submit(Submission::new("queued".into(), Lane::FollowUp)))
            .unwrap();
        assert_ne!(store.snapshot().stream_generation, before);
        assert!(
            !crate::stream_journal::path(&path, &before)
                .unwrap()
                .exists()
        );
        store
            .append_delta(&reply, Delta::Text("second".into()))
            .unwrap();
        drop(store);
        let restored = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(restored.messages.last().unwrap().text, "firstsecond");
        assert_eq!(restored.pending[0].text, "queued");
    }
    #[test]
    fn uncertain_checkpoint_never_replays_prior_generation_twice() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let reply = store.snapshot().active_reply.unwrap();
        store
            .append_delta(&reply, Delta::Text("once".into()))
            .unwrap();
        store.fault = WriteFault::AfterRename;
        assert!(matches!(
            store.transact(|session| {
                session.title = "maybe saved".into();
                Ok(())
            }),
            Err(Error::PersistenceUncertain(_))
        ));
        assert!(
            store
                .append_delta(&reply, Delta::Text("blocked".into()))
                .is_err()
        );
        drop(store);
        let restored = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(restored.messages.last().unwrap().text, "once");
        assert_eq!(restored.title, "maybe saved");
    }
    #[test]
    fn failed_checkpoint_preserves_live_journal_and_later_appends() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let reply = store.snapshot().active_reply.unwrap();
        let generation = store.snapshot().stream_generation;
        store.append_delta(&reply, Delta::Text("a".into())).unwrap();
        store.fault = WriteFault::BeforeRename;
        assert!(
            store
                .transact(|session| {
                    session.title = "uncommitted".into();
                    Ok(())
                })
                .is_err()
        );
        assert_eq!(store.snapshot().stream_generation, generation);
        store.append_delta(&reply, Delta::Text("b".into())).unwrap();
        drop(store);
        let restored = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(restored.messages.last().unwrap().text, "ab");
        assert_ne!(restored.title, "uncommitted");
    }
    #[test]
    fn torn_unacknowledged_tail_is_preserved_while_valid_prefix_recovers() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let reply = store.snapshot().active_reply.unwrap();
        store
            .append_delta(&reply, Delta::Text("complete prefix".into()))
            .unwrap();
        let journal =
            crate::stream_journal::path(&path, &store.snapshot().stream_generation).unwrap();
        drop(store);
        OpenOptions::new()
            .append(true)
            .open(&journal)
            .unwrap()
            .write_all(b"{torn")
            .unwrap();
        let old = fs::read(&journal).unwrap();
        let restored = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(restored.messages.last().unwrap().text, "complete prefix");
        assert_eq!(restored.state, RunState::Paused);
        assert_eq!(fs::read(&journal).unwrap(), old);
        assert!(restored.error.unwrap().contains("incomplete final record"));
    }
    #[test]
    fn stale_delta_is_rejected_before_any_journal_write() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let journal =
            crate::stream_journal::path(&path, &store.snapshot().stream_generation).unwrap();
        let revision = store.snapshot().revision;
        assert!(
            store
                .append_delta("stale", Delta::Text("wrong".into()))
                .is_err()
        );
        assert!(!journal.exists());
        assert_eq!(store.snapshot().revision, revision);
    }
    #[test]
    fn rust_v1_snapshot_migrates_without_swift_import() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut old = serde_json::to_value(Session::new()).unwrap();
        old["version"] = serde_json::json!(1);
        old.as_object_mut().unwrap().remove("stream_generation");
        old.as_object_mut().unwrap().remove("stream_sequence");
        fs::write(&path, serde_json::to_vec(&old).unwrap()).unwrap();
        let store = SessionStore::open(&path).unwrap();
        assert_eq!(store.snapshot().version, 2);
        assert!(Uuid::parse_str(&store.snapshot().stream_generation).is_ok());
    }
    #[test]
    fn incremental_size_matches_json_for_escapes_unicode_and_counter_boundaries() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        store
            .transact(|session| {
                session.revision = 8;
                Ok(())
            })
            .unwrap();
        let reply = store.snapshot().active_reply.unwrap();
        for index in 0..105 {
            let delta = match index % 3 {
                0 => Delta::Text("\"\\\n\r\t\u{0001}é🙂".into()),
                1 => Delta::Reasoning("\"\\\n\u{0000}α".into()),
                _ => Delta::Tool {
                    id: "call".into(),
                    name: "read".into(),
                    arguments: "{}".into(),
                },
            };
            store.append_delta(&reply, delta).unwrap();
            assert_eq!(
                store.encoded_bytes,
                encode_snapshot(&store.snapshot()).unwrap().len(),
                "after delta {index}"
            );
        }
        assert_eq!(store.snapshot().stream_sequence, 105);
    }
    #[test]
    fn stream_capacity_rejects_before_creation_or_append_and_reopens() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let reply = store.snapshot().active_reply.unwrap();
        let journal =
            crate::stream_journal::path(&path, &store.snapshot().stream_generation).unwrap();
        store.snapshot_limit = store.encoded_bytes + RECOVERY_RESERVE_BYTES + 20;
        let before = store.snapshot();
        assert!(
            store
                .append_delta(&reply, Delta::Text("x".repeat(21)))
                .is_err()
        );
        assert!(!journal.exists());
        assert_eq!(store.snapshot().revision, before.revision);
        store
            .append_delta(&reply, Delta::Text("accepted".into()))
            .unwrap();
        let bytes = fs::read(&journal).unwrap();
        let before = store.snapshot();
        assert!(
            store
                .append_delta(&reply, Delta::Reasoning("x".repeat(21)))
                .is_err()
        );
        assert_eq!(fs::read(&journal).unwrap(), bytes);
        assert_eq!(store.snapshot().revision, before.revision);
        assert_eq!(store.snapshot().stream_sequence, before.stream_sequence);
        drop(store);
        let restored = SessionStore::open(path).unwrap().snapshot();
        assert_eq!(restored.messages.last().unwrap().text, "accepted");
        assert!(restored.messages.last().unwrap().reasoning.is_empty());
        assert_eq!(restored.state, RunState::Paused);
    }
    #[test]
    fn metadata_failure_after_journal_creation_blocks_later_unsynced_append() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let reply = store.snapshot().active_reply.unwrap();
        let revision = store.snapshot().revision;
        store.fault = WriteFault::StreamMetadata;
        assert!(matches!(
            store.append_delta(&reply, Delta::Text("unpublished".into())),
            Err(Error::PersistenceUncertain(_))
        ));
        store.fault = WriteFault::None;
        assert!(
            store
                .append_delta(&reply, Delta::Text("blocked".into()))
                .is_err()
        );
        assert_eq!(store.snapshot().revision, revision);
        assert!(store.snapshot().messages.last().unwrap().text.is_empty());
        drop(store);
        let restored = SessionStore::open(path).unwrap().snapshot();
        assert!(restored.messages.last().unwrap().text.is_empty());
        assert_eq!(restored.state, RunState::Paused);
    }
    #[test]
    fn every_held_edit_command_preserves_recovery_headroom() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        store
            .transact(|session| {
                session.submit(Submission::new("waiting".into(), Lane::FollowUp))?;
                let id = session.pending[0].id.clone();
                session.begin_edit(&id, "held")?;
                Ok(())
            })
            .unwrap();
        let limit = store.encoded_bytes + RECOVERY_RESERVE_BYTES + 32;
        store.snapshot_limit = limit;
        let before = fs::read(&path).unwrap();
        assert!(store.transact(|session|session.submit(Submission::new("x".repeat(100),Lane::FollowUp))).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
        assert_eq!(store.snapshot().pending.len(), 1);
        drop(store);
        let mut restored = SessionStore::open(&path).unwrap();
        assert_eq!(restored.snapshot().state, RunState::Paused);
        assert!(restored.encoded_bytes <= limit);
        restored.snapshot_limit = limit;
        assert!(restored.transact(|session|session.submit(Submission::new("x".repeat(100),Lane::FollowUp))).is_err());
        restored
            .transact(|session| session.resolve_edit("held", "cancelled", None))
            .unwrap();
        assert!(restored.snapshot().edit.is_none());
    }
}

#[cfg(test)]
mod tool_recovery_capacity_tests {
    use super::*;
    use crate::{
        provider::ToolCall, runtime::tool_runtime::ToolResultRow, tool_history::ToolOutcome,
    };
    use serde_json::json;

    #[test]
    fn active_tool_admission_reserves_every_unknown_result_before_execution() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        store
            .transact(|s| {
                s.submit(Submission::new("fixture".into(), Lane::FollowUp))?;
                s.start_next()?;
                Ok(())
            })
            .unwrap();
        let id = store.snapshot().active_reply.unwrap();
        let profile = serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":"http://127.0.0.1:12345","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
        let reply = Reply {
            text: String::new(),
            reasoning: String::new(),
            calls: (0..400)
                .map(|i| ToolCall {
                    id: format!("{i:04}{}", "x".repeat(252)),
                    name: "ls".into(),
                    arguments: json!({}),
                })
                .collect(),
            usage: Value::Null,
            status: "completed".into(),
            provider_items: vec![],
        };
        let mut batch = store.snapshot();
        batch.begin_tools(&id, &reply, &profile).unwrap();
        let mut recovered = batch.clone();
        assert!(recovered.recover_tools());
        let admitted_size = encode_snapshot(&batch).unwrap().len();
        let recovered_size = encode_snapshot(&recovered).unwrap().len();
        assert!(recovered_size > admitted_size + RECOVERY_RESERVE_BYTES);
        store.snapshot_limit = admitted_size + RECOVERY_RESERVE_BYTES + 1024;
        let before = fs::read(&path).unwrap();
        assert!(
            store
                .transact(|s| s.begin_tools(&id, &reply, &profile))
                .unwrap_err()
                .to_string()
                .contains("every interrupted result")
        );
        assert_eq!(fs::read(&path).unwrap(), before);
        assert!(store.snapshot().active_tool_calls().is_none());
        store.snapshot_limit = recovered_size + RECOVERY_RESERVE_BYTES + 1024;
        store
            .transact(|s| s.begin_tools(&id, &reply, &profile))
            .unwrap();
        let accepted = fs::read(&path).unwrap();
        // A failed result checkpoint leaves the admitted call phase recoverable.
        store.fault = WriteFault::BeforeRename;
        let results = reply
            .calls
            .iter()
            .map(|_| ToolResultRow {
                text: "result".into(),
                outcome: ToolOutcome::Completed,
                content: None,
            })
            .collect();
        assert!(
            store
                .transact(|s| s.settle_tools(&id, results, false))
                .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), accepted);
        drop(store);
        let restored = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(restored.state, RunState::Paused);
        assert_eq!(
            restored
                .messages
                .iter()
                .filter(|m| m.role == "toolResult")
                .count(),
            400
        );
        assert!(encode_snapshot(&restored).unwrap().len() <= recovered_size + 1024);
    }
}

#[cfg(test)]
#[path = "read_storage_tests.rs"]
mod read_storage_tests;

#[cfg(test)]
#[path = "attachment_storage_tests.rs"]
mod attachment_storage_tests;

#[cfg(test)]
#[path = "skill_storage_tests.rs"]
mod skill_storage_tests;
