//! Durable, one-shot recovery receipts. Recovery never replaces the user's
//! active submission and its progress row is never replayed to the provider.
use crate::provider_failure::Failure;
use crate::{Error, Message, Reply, Result, RunState, Session, invalid};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

pub const MAX_RECEIPTS: usize = 256;

pub(crate) fn deserialize_receipts<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<Vec<Receipt>, D::Error> {
    struct Receipts;
    impl<'de> serde::de::Visitor<'de> for Receipts {
        type Value = Vec<Receipt>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("at most 256 context recovery receipts")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut seq: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            let mut receipts = Vec::with_capacity(seq.size_hint().unwrap_or(0).min(MAX_RECEIPTS));
            while receipts.len() < MAX_RECEIPTS {
                match seq.next_element()? {
                    Some(receipt) => receipts.push(receipt),
                    None => return Ok(receipts),
                }
            }
            if seq.next_element::<serde::de::IgnoredAny>()?.is_some() {
                return Err(serde::de::Error::custom(
                    "Context recovery receipt limit exceeded",
                ));
            }
            Ok(receipts)
        }
    }
    d.deserialize_seq(Receipts)
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Phase {
    Preparing,
    Summarizing,
    RetryReady,
    Retrying,
    Completed,
    Failed,
    Cancelled,
    Interrupted,
}
impl Phase {
    pub fn is_running(&self) -> bool {
        matches!(
            self,
            Self::Preparing | Self::Summarizing | Self::RetryReady | Self::Retrying
        )
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Receipt {
    pub id: String,
    pub turn_id: String,
    /// Stable logical-request key; retry reply IDs/fingerprints never reset it.
    pub failed_reply_id: String,
    pub progress_id: String,
    pub retry_reply_id: Option<String>,
    pub retry_turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolved_reply_id: Option<String>,
    pub request_fingerprint: String,
    pub failure: Failure,
    pub phase: Phase,
    pub summary_id: Option<String>,
    pub summary_failure: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary_rejection: Option<Failure>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_rejection: Option<Failure>,
    pub summary_attempts: u32,
    pub retry_attempts: u32,
}
impl Receipt {
    pub fn is_running(&self) -> bool {
        self.phase.is_running()
    }
}
fn project_failure_usage(row: &mut Message, failure: &Failure) {
    row.usage = crate::provider_failure::merge_usage(
        (!row.usage.is_null()).then(|| row.usage.clone()),
        failure.reported_usage.clone(),
    )
    .unwrap_or(serde_json::Value::Null);
}

fn identity(value: &str) -> Result<()> {
    if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
        return Err(invalid("Invalid context recovery identity"));
    }
    Ok(())
}

fn fingerprint(value: &str) -> Result<()> {
    if value.len() != 64 || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(invalid(
            "Context recovery requires a SHA-256 request fingerprint",
        ));
    }
    Ok(())
}

/// Even an empty/null new field must not be silently accepted under an old
/// marker. Inspect presence without copying any retained transcript bodies.
pub(crate) fn parse_snapshot(bytes: &[u8]) -> Result<Session> {
    parse_snapshot_cancelled(bytes, None)
}
pub(crate) fn parse_snapshot_cancelled(
    bytes: &[u8],
    cancel: Option<&dyn crate::sidebar_search::CancellationProbe>,
) -> Result<Session> {
    fn present<'de, D: serde::Deserializer<'de>>(d: D) -> std::result::Result<bool, D::Error> {
        serde::de::IgnoredAny::deserialize(d)?;
        Ok(true)
    }
    #[derive(Deserialize)]
    struct Presence {
        version: u32,
        #[serde(default, deserialize_with = "present")]
        context_recoveries: bool,
    }
    let presence: Presence = crate::inspection::parse(bytes, cancel)?;
    if presence.version < 10 && presence.context_recoveries {
        return Err(invalid(
            "Context recovery requires Rust snapshot version 10",
        ));
    }
    match cancel {
        Some(cancel) => crate::skill_schema::parse_snapshot_cancelled(bytes, Some(cancel)),
        None => crate::skill_schema::parse_snapshot(bytes),
    }
}

impl Session {
    pub(crate) fn can_recover_context(&self, reply_id: &str) -> bool {
        self.state == RunState::Running
            && self.active_reply.as_deref() == Some(reply_id)
            && self.active.as_ref().is_some_and(|active| {
                !self.context_recoveries.iter().any(|r| {
                    r.failed_reply_id == reply_id
                        || r.retry_reply_id.as_deref() == Some(reply_id)
                        || ((r.turn_id == active.id
                            || r.retry_turn_id.as_ref() == Some(&active.id))
                            && r.phase != Phase::Completed
                            && r.resolved_reply_id.is_none())
                })
            })
            && self.messages.iter().any(|r| {
                r.id == reply_id
                    && r.role == "assistant"
                    && r.state == "streaming"
                    && !r.replay_eligible
                    && r.tool_record.is_none()
            })
            && self.context_recoveries.len() < MAX_RECEIPTS
            && !self.compaction.as_ref().is_some_and(|r| r.is_running())
    }
    pub(crate) fn is_context_rejected_active(&self, reply_id: &str) -> bool {
        self.messages.iter().any(|row| {
            row.id == reply_id
                && row.state == "context-rejected"
                && !row.replay_eligible
                && row.tool_record.is_none()
        }) && self.context_recoveries.iter().any(|r| {
            r.failed_reply_id == reply_id
                && r.retry_reply_id.is_none()
                && self.active.as_ref().is_some_and(|a| a.id == r.turn_id)
        })
    }
    pub(crate) fn begin_context_recovery(
        &mut self,
        operation_id: &str,
        reply_id: &str,
        failure: Failure,
        request_fingerprint: String,
    ) -> Result<()> {
        identity(operation_id)?;
        fingerprint(&request_fingerprint)?;
        if !failure.category.context_rejection()
            || !self.can_recover_context(reply_id)
            || self.context_recoveries.iter().any(|r| r.id == operation_id)
            || self
                .compaction
                .iter()
                .chain(&self.compaction_history)
                .any(|r| r.id == operation_id)
            || self.messages.iter().any(|r| r.id == operation_id)
        {
            return Err(invalid(
                "Context recovery was already consumed or is unavailable",
            ));
        }
        let active = self.active.as_ref().expect("checked active");
        let progress_id = uuid::Uuid::new_v4().to_string();
        let receipt = Receipt {
            id: operation_id.into(),
            turn_id: active.id.clone(),
            failed_reply_id: reply_id.into(),
            progress_id: progress_id.clone(),
            retry_reply_id: None,
            retry_turn_id: None,
            resolved_reply_id: None,
            request_fingerprint,
            failure,
            phase: Phase::Preparing,
            summary_id: None,
            summary_failure: None,
            summary_rejection: None,
            retry_rejection: None,
            summary_attempts: 0,
            retry_attempts: 0,
        };
        let row = self
            .messages
            .iter_mut()
            .find(|r| r.id == reply_id)
            .expect("checked reply");
        row.state = "context-rejected".into();
        row.replay_eligible = false;
        project_failure_usage(row, &receipt.failure);
        self.messages.push(Message {
            id: progress_id,
            role: "assistant".into(),
            text: String::new(),
            reasoning: String::new(),
            replay_eligible: false,
            state: "context-recovery-preparing".into(),
            usage: serde_json::Value::Null,
            model: active.model.clone(),
            task_root_id: None,
            user_content: None,
            tool_record: None,
            compaction: None,
        });
        self.context_recoveries.push(receipt);
        self.version = self.version.max(10);
        Ok(())
    }
    fn recovery_index(&self, id: &str, phase: Phase) -> Result<usize> {
        self.context_recoveries
            .iter()
            .position(|r| {
                r.id == id
                    && r.phase == phase
                    && self
                        .active
                        .as_ref()
                        .is_some_and(|a| a.id == *r.retry_turn_id.as_ref().unwrap_or(&r.turn_id))
                    && self.active_reply.as_deref()
                        == Some(r.retry_reply_id.as_deref().unwrap_or(&r.failed_reply_id))
            })
            .ok_or_else(|| invalid("Stale context recovery transition"))
    }
    pub(crate) fn mark_recovery_summarizing(&mut self, id: &str) -> Result<()> {
        let i = self.recovery_index(id, Phase::Preparing)?;
        self.recovery_progress(i, None, "context-recovery-summarizing")?;
        self.context_recoveries[i].phase = Phase::Summarizing;
        self.context_recoveries[i].summary_attempts = 1;
        Ok(())
    }
    pub(crate) fn adopt_recovery_checkpoint(
        &mut self,
        id: &str,
        summary: Message,
        reply: &Reply,
    ) -> Result<()> {
        let i = self.recovery_index(id, Phase::Summarizing)?;
        let checkpoint = summary
            .compaction
            .as_ref()
            .ok_or_else(|| invalid("Missing recovery checkpoint"))?;
        let active = crate::compaction::active_context(&self.messages)?;
        if checkpoint.operation_id != id
            || active
                .iter()
                .map(|r| r.id.as_str())
                .ne(checkpoint.source_ids.iter().map(String::as_str))
            || self.messages.iter().any(|r| r.id == summary.id)
        {
            return Err(invalid(
                "Context changed while summarizing; original context is retained",
            ));
        }
        // Validate before mutating, including protected IDs and complete tool groups.
        let mut prospective = self.messages.clone();
        prospective.push(summary.clone());
        crate::compaction::active_context(&prospective)?;
        self.recovery_progress(i, Some(reply), "context-recovery-retry-ready")?;
        self.context_recoveries[i].summary_id = Some(summary.id.clone());
        self.context_recoveries[i].phase = Phase::RetryReady;
        self.messages.push(summary);
        Ok(())
    }
    pub(crate) fn begin_recovery_retry(&mut self, id: &str) -> Result<String> {
        self.begin_recovery_retry_with_steering(id, None, None)
    }
    pub(crate) fn begin_recovery_retry_with_steering(
        &mut self,
        id: &str,
        steering: Option<&str>,
        prepared: Option<crate::session::PreparedUserInput>,
    ) -> Result<String> {
        let i = self.recovery_index(id, Phase::RetryReady)?;
        let mut item = self.active.clone().expect("checked active");
        if self.edit.is_none()
            && !self.queue_paused
            && let Some(index) = self.pending.iter().position(|item| {
                item.lane == crate::Lane::Steering && Some(item.id.as_str()) == steering
            })
        {
            let content = crate::session::checked_prepared(&self.pending[index], prepared)?;
            let root = self
                .messages
                .iter()
                .find(|row| row.role == "user" && row.id == item.id)
                .and_then(|row| row.task_root_id.clone())
                .unwrap_or_else(|| item.id.clone());
            if let Some(row) = self
                .messages
                .iter_mut()
                .find(|row| row.role == "user" && row.id == root)
            {
                row.task_root_id = Some(root.clone());
            }
            item = self.pending.remove(index);
            self.messages.push(Message {
                id: item.id.clone(),
                role: "user".into(),
                text: item.text.clone(),
                reasoning: String::new(),
                replay_eligible: true,
                state: "complete".into(),
                usage: serde_json::Value::Null,
                model: item.model.clone(),
                task_root_id: Some(root),
                user_content: content,
                tool_record: None,
                compaction: None,
            });
        }
        self.context_recoveries[i].retry_turn_id = Some(item.id.clone());
        self.activate(item);
        let reply_id = self.active_reply.clone().expect("activated reply");
        self.context_recoveries[i].retry_reply_id = Some(reply_id.clone());
        self.context_recoveries[i].retry_attempts = 1;
        self.context_recoveries[i].phase = Phase::Retrying;
        Ok(reply_id)
    }
    pub(crate) fn fail_context_recovery(
        &mut self,
        id: &str,
        error: &Error,
        reply: Option<&Reply>,
    ) -> Result<()> {
        let phase = self
            .context_recoveries
            .iter()
            .find(|r| r.id == id && r.is_running())
            .map(|r| r.phase.clone())
            .ok_or_else(|| invalid("Stale context recovery failure"))?;
        let i = self.recovery_index(id, phase)?;
        let cancelled = matches!(error, Error::Cancelled);
        self.recovery_progress(
            i,
            reply,
            if cancelled {
                "context-recovery-cancelled"
            } else {
                "context-recovery-failed"
            },
        )?;
        if reply.is_none()
            && self.context_recoveries[i].summary_id.is_none()
            && let Error::ProviderFailure(failure) = error
        {
            let progress_id = &self.context_recoveries[i].progress_id;
            let row = self
                .messages
                .iter_mut()
                .find(|row| &row.id == progress_id)
                .ok_or_else(|| invalid("Missing context recovery progress"))?;
            project_failure_usage(row, failure);
        }
        let receipt = &mut self.context_recoveries[i];
        if let Error::ProviderFailure(failure) = error {
            receipt.summary_rejection = Some(failure.as_ref().clone());
        }
        receipt.phase = if cancelled {
            Phase::Cancelled
        } else {
            Phase::Failed
        };
        // Typed provider failures were redacted at the HTTP boundary. Untyped
        // transport errors may still contain request URLs or credentials.
        receipt.summary_failure = Some(match error {
            Error::ProviderFailure(failure) => failure.message.chars().take(1024).collect(),
            Error::Invalid(message) => message.chars().take(1024).collect(),
            Error::Cancelled => "Context recovery stopped".into(),
            Error::IncompleteStream => error.to_string(),
            _ => "Context recovery failed".into(),
        });
        Ok(())
    }
    pub(crate) fn record_recovery_retry_failure(
        &mut self,
        reply_id: &str,
        error: &Error,
    ) -> Result<()> {
        if let Some(i) = self
            .context_recoveries
            .iter()
            .position(|r| r.retry_reply_id.as_deref() == Some(reply_id))
        {
            let id = self.context_recoveries[i].id.clone();
            self.recovery_index(&id, Phase::Retrying)?;
            if let Error::ProviderFailure(failure) = error {
                self.context_recoveries[i].retry_rejection = Some(failure.as_ref().clone());
                let row = self
                    .messages
                    .iter_mut()
                    .find(|row| row.id == reply_id)
                    .ok_or_else(|| invalid("Missing context recovery retry reply"))?;
                project_failure_usage(row, failure);
            }
        }
        Ok(())
    }
    pub(crate) fn finish_context_recovery(&mut self, reply_id: &str, success: bool) -> Result<()> {
        if self.active_reply.as_deref() != Some(reply_id) {
            return Err(invalid("Stale context recovery completion"));
        }
        if let Some(i) = self
            .context_recoveries
            .iter()
            .position(|r| r.retry_reply_id.as_deref() == Some(reply_id))
        {
            if self.context_recoveries[i].phase != Phase::Retrying {
                return Err(invalid("Context recovery retry already finished"));
            }
            self.recovery_progress(
                i,
                None,
                if success {
                    "context-recovery-complete"
                } else {
                    "context-recovery-failed"
                },
            )?;
            self.context_recoveries[i].phase = if success {
                Phase::Completed
            } else {
                Phase::Failed
            };
        }
        // A genuine successful manual retry resolves the consumed logical
        // request, but its historical failed/interrupted receipt stays intact.
        if success
            && let Some(turn) = self.active.as_ref()
            && let Some(receipt) = self.context_recoveries.iter_mut().rev().find(|r| {
                r.resolved_reply_id.is_none()
                    && (r.turn_id == turn.id || r.retry_turn_id.as_ref() == Some(&turn.id))
            })
        {
            receipt.resolved_reply_id = Some(reply_id.into());
        }
        Ok(())
    }
    pub(crate) fn cancel_context_recovery_retry(&mut self, reply_id: &str) -> Result<()> {
        if let Some(i) = self
            .context_recoveries
            .iter()
            .position(|r| r.retry_reply_id.as_deref() == Some(reply_id))
        {
            let id = self.context_recoveries[i].id.clone();
            self.recovery_index(&id, Phase::Failed)?;
            self.recovery_progress(i, None, "context-recovery-cancelled")?;
            self.context_recoveries[i].phase = Phase::Cancelled;
        }
        Ok(())
    }
    fn recovery_progress(&mut self, i: usize, reply: Option<&Reply>, state: &str) -> Result<()> {
        let row = self
            .messages
            .iter_mut()
            .find(|r| r.id == self.context_recoveries[i].progress_id)
            .ok_or_else(|| invalid("Missing context recovery progress"))?;
        if let Some(reply) = reply {
            row.text = reply.text.clone();
            row.reasoning = reply.reasoning.clone();
            row.usage = reply.usage.clone();
        }
        row.state = state.into();
        row.replay_eligible = false;
        Ok(())
    }
    pub(crate) fn interrupt_context_recoveries(&mut self) {
        for receipt in &mut self.context_recoveries {
            if receipt.is_running() {
                receipt.phase = Phase::Interrupted;
                receipt.summary_failure = Some("Context recovery interrupted".into());
                if let Some(row) = self
                    .messages
                    .iter_mut()
                    .find(|r| r.id == receipt.progress_id)
                {
                    row.state = "context-recovery-interrupted".into();
                    row.replay_eligible = false;
                }
            }
        }
    }
    pub(crate) fn validate_context_recoveries(&self) -> Result<()> {
        if (self.version < 10 && !self.context_recoveries.is_empty())
            || self.context_recoveries.len() > MAX_RECEIPTS
        {
            return Err(invalid("Invalid context recovery version or receipt bound"));
        }
        let mut operations = BTreeSet::new();
        let mut used_rows = BTreeSet::new();
        let mut running = 0;
        for r in &self.context_recoveries {
            fingerprint(&r.request_fingerprint)?;
            for id in [
                &r.id,
                &r.turn_id,
                &r.failed_reply_id,
                &r.progress_id,
                &r.request_fingerprint,
            ]
            .into_iter()
            .chain(r.retry_reply_id.iter())
            .chain(r.retry_turn_id.iter())
            .chain(r.resolved_reply_id.iter())
            .chain(r.summary_id.iter())
            {
                identity(id)?;
            }
            if !operations.insert(&r.id)
                || self.messages.iter().any(|row| row.id == r.id)
                || !used_rows.insert(&r.failed_reply_id)
                || !used_rows.insert(&r.progress_id)
                || self
                    .compaction
                    .iter()
                    .chain(&self.compaction_history)
                    .any(|op| op.id == r.id)
                || !r.failure.category.context_rejection()
                || r.summary_attempts > 1
                || r.retry_attempts > 1
                || r.summary_failure.as_ref().is_some_and(|s| s.len() > 4096)
            {
                return Err(invalid("Invalid context recovery receipt"));
            }
            let find = |id: &str| -> Result<&Message> {
                let mut rows = self.messages.iter().filter(|row| row.id == id);
                let row = rows
                    .next()
                    .ok_or_else(|| invalid("Missing context recovery reference"))?;
                if rows.next().is_some() {
                    return Err(invalid("Duplicate context recovery reference"));
                }
                Ok(row)
            };
            let position = |id: &str| self.messages.iter().position(|row| row.id == id);
            if position(&r.turn_id) >= position(&r.failed_reply_id)
                || position(&r.failed_reply_id) >= position(&r.progress_id)
                || r.summary_id
                    .as_ref()
                    .is_some_and(|id| position(&r.progress_id) >= position(id))
                || r.retry_reply_id.as_ref().is_some_and(|id| {
                    r.summary_id
                        .as_ref()
                        .is_none_or(|summary| position(summary) >= position(id))
                })
            {
                return Err(invalid("Out-of-order context recovery references"));
            }
            let preceding_user = |id: &str| {
                self.messages
                    .iter()
                    .take_while(|row| row.id != id)
                    .filter(|row| row.role == "user")
                    .last()
            };
            if preceding_user(&r.failed_reply_id).is_none_or(|row| row.id != r.turn_id) {
                return Err(invalid(
                    "Context recovery original turn does not own the failed reply",
                ));
            }
            let turn = find(&r.turn_id)?;
            let failed = find(&r.failed_reply_id)?;
            let progress = find(&r.progress_id)?;
            if turn.role != "user"
                || failed.role != "assistant"
                || failed.replay_eligible
                || failed.tool_record.is_some()
                || !["context-rejected", "interrupted"].contains(&failed.state.as_str())
                || progress.role != "assistant"
                || progress.replay_eligible
                || progress.tool_record.is_some()
                || progress.compaction.is_some()
                || progress.user_content.is_some()
                || progress.task_root_id.is_some()
                || !progress.state.starts_with("context-recovery-")
            {
                return Err(invalid("Invalid context recovery transcript rows"));
            }
            if let Some(id) = &r.summary_id
                && (!used_rows.insert(id)
                    || r.summary_attempts != 1
                    || !find(id)?
                        .compaction
                        .as_ref()
                        .is_some_and(|c| c.operation_id == r.id))
            {
                return Err(invalid("Invalid context recovery checkpoint reference"));
            }
            if let Some(id) = &r.retry_reply_id {
                if !used_rows.insert(id)
                    || r.summary_id.is_none()
                    || r.retry_attempts != 1
                    || find(id)?.role != "assistant"
                    || r.retry_turn_id
                        .as_ref()
                        .is_none_or(|id| find(id).map_or(true, |row| row.role != "user"))
                {
                    return Err(invalid("Invalid context recovery retry reference"));
                }
                let retry_turn = r.retry_turn_id.as_ref().expect("validated retry turn");
                if preceding_user(id).is_none_or(|row| &row.id != retry_turn) {
                    return Err(invalid(
                        "Context recovery retry turn does not own the retry reply",
                    ));
                }
                if retry_turn != &r.turn_id {
                    let steering = find(retry_turn)?;
                    let root = turn.task_root_id.as_ref().unwrap_or(&turn.id);
                    if steering.task_root_id.as_ref() != Some(root)
                        || r.summary_id
                            .as_ref()
                            .is_none_or(|summary| position(summary) >= position(retry_turn))
                        || position(retry_turn) >= position(id)
                    {
                        return Err(invalid("Invalid context recovery steering provenance"));
                    }
                }
            } else if r.retry_attempts != 0 || r.retry_turn_id.is_some() {
                return Err(invalid("Missing context recovery retry"));
            }
            let accepted = |row: &Message| {
                row.role == "assistant"
                    && row.replay_eligible
                    && matches!(row.state.as_str(), "complete" | "completed")
                    && row.compaction.is_none()
                    && (!row.text.trim().is_empty()
                        || matches!(&row.tool_record,
                        Some(crate::tool_history::ToolRecord::Assistant(record))
                            if record.completion == crate::tool_history::Completion::Complete
                                && !record.calls.is_empty()))
            };
            if r.phase == Phase::Completed
                && !r
                    .retry_reply_id
                    .as_ref()
                    .is_some_and(|id| find(id).is_ok_and(accepted))
            {
                return Err(invalid(
                    "Completed recovery lacks an accepted retry response",
                ));
            }
            if let Some(id) = &r.resolved_reply_id {
                let preceding_user = self
                    .messages
                    .iter()
                    .take_while(|row| &row.id != id)
                    .filter(|row| row.role == "user")
                    .last();
                if !accepted(find(id)?)
                    || position(id) <= position(&r.progress_id)
                    || preceding_user.is_none_or(|row| {
                        row.id != r.turn_id && r.retry_turn_id.as_ref() != Some(&row.id)
                    })
                    || r.is_running()
                {
                    return Err(invalid("Invalid context recovery resolution response"));
                }
            }
            let progress_state = match r.phase {
                Phase::Preparing => "context-recovery-preparing",
                Phase::Summarizing => "context-recovery-summarizing",
                Phase::RetryReady | Phase::Retrying => "context-recovery-retry-ready",
                Phase::Completed => "context-recovery-complete",
                Phase::Failed => "context-recovery-failed",
                Phase::Cancelled => "context-recovery-cancelled",
                Phase::Interrupted => "context-recovery-interrupted",
            };
            if progress.state != progress_state
                || (r.summary_rejection.is_some() && r.summary_attempts != 1)
                || (r.retry_rejection.is_some() && r.retry_attempts != 1)
                || ((r.is_running() || r.phase == Phase::Completed) && r.summary_failure.is_some())
            {
                return Err(invalid("Context recovery phase and evidence disagree"));
            }
            let valid_phase = match r.phase {
                Phase::Preparing => {
                    r.summary_attempts == 0 && r.summary_id.is_none() && r.retry_reply_id.is_none()
                }
                Phase::Summarizing => {
                    r.summary_attempts == 1 && r.summary_id.is_none() && r.retry_reply_id.is_none()
                }
                Phase::RetryReady => {
                    r.summary_attempts == 1 && r.summary_id.is_some() && r.retry_reply_id.is_none()
                }
                Phase::Retrying | Phase::Completed => {
                    r.summary_id.is_some() && r.retry_reply_id.is_some()
                }
                Phase::Failed | Phase::Cancelled | Phase::Interrupted => true,
            };
            if !valid_phase {
                return Err(invalid("Invalid context recovery phase"));
            }
            if r.is_running() {
                running += 1;
                if self.state != RunState::Running
                    || self
                        .active
                        .as_ref()
                        .is_none_or(|a| a.id != *r.retry_turn_id.as_ref().unwrap_or(&r.turn_id))
                    || self.active_reply.as_deref()
                        != Some(r.retry_reply_id.as_deref().unwrap_or(&r.failed_reply_id))
                {
                    return Err(invalid("Running context recovery lost its original turn"));
                }
            }
        }
        if running > 1 {
            return Err(invalid("Multiple active context recoveries"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::WriteFault;
    use crate::{Lane, SessionStore, Submission};
    use serde_json::{Value, json};

    fn failure() -> Failure {
        Failure {
            category: crate::provider_failure::Category::InputContextExceeded,
            status: Some(400),
            message: "Input context exceeded".into(),
            attempt_id: Some("request-1".into()),
            reported_usage: None,
        }
    }
    fn reply() -> Reply {
        Reply {
            text: "Summary".into(),
            reasoning: String::new(),
            calls: vec![],
            usage: json!({"output_tokens":3}),
            status: "complete".into(),
            provider_items: vec![],
        }
    }
    fn running() -> Session {
        let mut s = Session::new();
        s.submit(Submission::new("Old history".into(), Lane::FollowUp))
            .unwrap();
        s.start_next().unwrap();
        s.finish(&s.active_reply.clone().unwrap(), Ok(reply()))
            .unwrap();
        s.submit(Submission::new("Current request".into(), Lane::FollowUp))
            .unwrap();
        s.start_next().unwrap();
        s
    }
    fn begin(s: &mut Session) {
        s.begin_context_recovery(
            "recovery-1",
            &s.active_reply.clone().unwrap(),
            failure(),
            "a".repeat(64),
        )
        .unwrap();
    }
    fn checkpoint(s: &Session) -> Message {
        let source_ids = crate::compaction::active_context(&s.messages)
            .unwrap()
            .iter()
            .map(|r| r.id.clone())
            .collect();
        let current = s.active.as_ref().unwrap().id.clone();
        Message::compaction_summary(
            "summary-1".into(),
            "Historical summary".into(),
            Some(crate::compaction::Checkpoint {
                version: 1,
                operation_id: "recovery-1".into(),
                source_ids,
                kept_ids: vec![current.clone()],
                protected_ids: vec![current],
                before_estimated_tokens: 500,
                after_estimated_tokens: 100,
            }),
        )
    }
    fn adopt(s: &mut Session) {
        s.mark_recovery_summarizing("recovery-1").unwrap();
        s.adopt_recovery_checkpoint("recovery-1", checkpoint(s), &reply())
            .unwrap();
    }
    #[test]
    fn schema_presence_gate_rejects_even_empty_under_all_old_versions() {
        for version in 1..=9 {
            for value in [json!([]), Value::Null] {
                let mut s = serde_json::to_value(Session::new()).unwrap();
                s["version"] = json!(version);
                s["context_recoveries"] = value;
                assert!(parse_snapshot(&serde_json::to_vec(&s).unwrap()).is_err());
            }
        }
        let s = Session::new();
        assert_eq!(s.version, 9);
        assert!(
            serde_json::to_value(&s)
                .unwrap()
                .get("context_recoveries")
                .is_none()
        );
    }
    #[test]
    fn receipt_consumes_once_and_preserves_active_queue_edit_and_timing() {
        let mut s = running();
        let queued = Submission::new("Queued".into(), Lane::FollowUp);
        s.submit(queued.clone()).unwrap();
        s.begin_edit(&queued.id, "held-edit").unwrap();
        let active = s.active.as_ref().unwrap().id.clone();
        let failed = s.active_reply.clone().unwrap();
        let timing = serde_json::to_value(s.tool_timing).unwrap();
        begin(&mut s);
        assert_eq!(s.version, 10);
        assert_eq!(s.active.as_ref().unwrap().id, active);
        assert_eq!(s.active_reply.as_ref().unwrap(), &failed);
        assert!(!s.can_recover_context(&failed));
        assert!(
            s.begin_context_recovery("again", &failed, failure(), "a".repeat(64))
                .is_err()
        );
        adopt(&mut s);
        let retry = s.begin_recovery_retry("recovery-1").unwrap();
        assert_ne!(retry, failed);
        assert_eq!(s.active.as_ref().unwrap().id, active);
        assert_eq!(s.pending.len(), 1);
        assert_eq!(s.edit.as_ref().unwrap().edit_id, "held-edit");
        assert_eq!(serde_json::to_value(s.tool_timing).unwrap(), timing);
        assert!(!s.can_recover_context(&retry));
        s.finish_context_recovery(&retry, true).unwrap();
        s.finish(&retry, Ok(reply())).unwrap();
        s.validate_context_recoveries().unwrap();
        assert_eq!(s.context_recoveries[0].phase, Phase::Completed);
        assert!(
            s.messages
                .iter()
                .filter(|r| r.id == failed || r.id == s.context_recoveries[0].progress_id)
                .all(|r| !r.replay_eligible)
        );
    }
    #[test]
    fn completed_recovery_allows_later_tool_continuation_but_failure_does_not() {
        let mut s = running();
        begin(&mut s);
        adopt(&mut s);
        let retry = s.begin_recovery_retry("recovery-1").unwrap();
        let mut failed = s.clone();
        let active = s.active.clone().unwrap();
        s.finish_context_recovery(&retry, true).unwrap();
        s.finish(&retry, Ok(reply())).unwrap();
        s.validate_context_recoveries().unwrap();
        s.activate(active);
        assert!(s.can_recover_context(s.active_reply.as_deref().unwrap()));
        failed.finish_context_recovery(&retry, false).unwrap();
        failed.finish(&retry, Err(Error::IncompleteStream)).unwrap();
        failed.retry_turn().unwrap();
        failed.validate_context_recoveries().unwrap();
        assert!(!failed.can_recover_context(failed.active_reply.as_deref().unwrap()));
    }
    #[test]
    fn malformed_receipt_and_changed_checkpoint_fail_closed_without_mutating() {
        let mut s = running();
        begin(&mut s);
        let before = serde_json::to_value(&s).unwrap();
        assert!(s.begin_recovery_retry("recovery-1").is_err());
        assert_eq!(serde_json::to_value(&s).unwrap(), before);
        s.mark_recovery_summarizing("recovery-1").unwrap();
        let mut summary = checkpoint(&s);
        summary.compaction.as_mut().unwrap().source_ids.reverse();
        let before = serde_json::to_value(&s).unwrap();
        assert!(
            s.adopt_recovery_checkpoint("recovery-1", summary, &reply())
                .is_err()
        );
        assert_eq!(serde_json::to_value(&s).unwrap(), before);
        for corruption in 0..7 {
            let mut bad = s.clone();
            let r = &mut bad.context_recoveries[0];
            match corruption {
                0 => r.progress_id = r.failed_reply_id.clone(),
                1 => r.turn_id = "missing".into(),
                2 => r.summary_attempts = 2,
                3 => r.phase = Phase::Completed,
                4 => r.retry_attempts = 1,
                5 => r.failure.category = crate::provider_failure::Category::RateLimited,
                _ => bad.context_recoveries = vec![r.clone(); MAX_RECEIPTS + 1],
            }
            assert!(
                bad.validate_context_recoveries().is_err(),
                "case {corruption}"
            );
        }
    }
    #[test]
    fn reopen_interrupts_each_running_phase_retaining_committed_checkpoint_and_original_retry() {
        for stage in 0..4 {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("session.json");
            let mut store = SessionStore::open(&path).unwrap();
            store
                .transact(|s| {
                    *s = running();
                    begin(s);
                    if stage > 0 {
                        s.mark_recovery_summarizing("recovery-1")?;
                    }
                    if stage > 1 {
                        s.adopt_recovery_checkpoint("recovery-1", checkpoint(s), &reply())?;
                    }
                    if stage > 2 {
                        s.begin_recovery_retry("recovery-1")?;
                    }
                    Ok(())
                })
                .unwrap();
            let before = store.snapshot();
            let turn = before.active.as_ref().unwrap().id.clone();
            drop(store);
            let reopened = SessionStore::open(&path).unwrap().snapshot();
            assert_eq!(reopened.context_recoveries[0].phase, Phase::Interrupted);
            assert_eq!(reopened.retry.as_ref().unwrap().id, turn);
            assert_eq!(
                reopened.context_recoveries[0].summary_id.is_some(),
                stage > 1
            );
            assert!(reopened.queue_paused);
            assert!(reopened.active.is_none());
            reopened.validate_context_recoveries().unwrap();
        }
    }
    #[test]
    fn receipt_consumption_and_version_promotion_are_atomic_at_both_write_faults() {
        for (fault, committed) in [
            (WriteFault::BeforeRename, false),
            (WriteFault::AfterRename, true),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("session.json");
            let mut store = SessionStore::open(&path).unwrap();
            store
                .transact(|s| {
                    *s = running();
                    Ok(())
                })
                .unwrap();
            let before = std::fs::read(&path).unwrap();
            store.fault = fault;
            assert!(
                store
                    .transact(|s| {
                        begin(s);
                        Ok(())
                    })
                    .is_err()
            );
            assert!(store.snapshot().context_recoveries.is_empty());
            assert_eq!(store.snapshot().version, 9);
            if !committed {
                assert_eq!(std::fs::read(&path).unwrap(), before);
            }
            drop(store);
            let s = SessionStore::open(&path).unwrap().snapshot();
            assert_eq!(s.context_recoveries.len(), usize::from(committed));
            assert_eq!(s.version, if committed { 10 } else { 9 });
        }
    }
    #[test]
    fn failure_retains_original_active_and_uses_no_raw_error_text() {
        let mut s = running();
        begin(&mut s);
        let active = s.active.as_ref().unwrap().id.clone();
        s.fail_context_recovery(
            "recovery-1",
            &Error::Provider("secret-provider-token".into()),
            None,
        )
        .unwrap();
        assert_eq!(s.active.as_ref().unwrap().id, active);
        assert!(
            !serde_json::to_string(&s.context_recoveries)
                .unwrap()
                .contains("secret-provider-token")
        );
        s.validate_context_recoveries().unwrap();
    }
    #[test]
    fn retry_steering_is_exact_once_and_keeps_original_task_root() {
        let mut s = running();
        begin(&mut s);
        adopt(&mut s);
        let original = s.active.as_ref().unwrap().id.clone();
        let steering = Submission::new("Steer".into(), Lane::Steering);
        s.submit(steering.clone()).unwrap();
        let reply = s
            .begin_recovery_retry_with_steering("recovery-1", Some(&steering.id), None)
            .unwrap();
        assert_eq!(s.active.as_ref().unwrap().id, steering.id);
        assert_eq!(s.context_recoveries[0].turn_id, original);
        assert_eq!(
            s.context_recoveries[0].retry_turn_id.as_deref(),
            Some(steering.id.as_str())
        );
        assert_eq!(s.messages.iter().filter(|r| r.id == steering.id).count(), 1);
        assert_eq!(
            s.messages
                .iter()
                .find(|r| r.id == steering.id)
                .unwrap()
                .task_root_id
                .as_ref(),
            Some(&original)
        );
        assert!(!s.can_recover_context(&reply));
        assert!(s.pending.is_empty());
        s.validate_context_recoveries().unwrap();
    }
    #[test]
    fn bounded_deserialization_and_failure_usage_are_retained() {
        let mut s = running();
        begin(&mut s);
        let mut value = serde_json::to_value(&s).unwrap();
        value["context_recoveries"] =
            json!(vec![s.context_recoveries[0].clone(); MAX_RECEIPTS + 1]);
        assert!(parse_snapshot(&serde_json::to_vec(&value).unwrap()).is_err());
        s.mark_recovery_summarizing("recovery-1").unwrap();
        let mut rejected = failure();
        rejected.reported_usage = Some(json!({"input_tokens": 999, "output_tokens": 3}));
        s.fail_context_recovery(
            "recovery-1",
            &Error::ProviderFailure(Box::new(rejected.clone())),
            None,
        )
        .unwrap();
        assert_eq!(
            s.context_recoveries[0].summary_rejection.as_ref(),
            Some(&rejected)
        );
        assert_eq!(
            s.context_recoveries[0].summary_failure.as_deref(),
            Some(rejected.message.as_str())
        );
        let mut s = running();
        begin(&mut s);
        adopt(&mut s);
        let reply = s.begin_recovery_retry("recovery-1").unwrap();
        s.record_recovery_retry_failure(
            &reply,
            &Error::ProviderFailure(Box::new(rejected.clone())),
        )
        .unwrap();
        s.finish_context_recovery(&reply, false).unwrap();
        assert_eq!(
            s.context_recoveries[0].retry_rejection.as_ref(),
            Some(&rejected)
        );
        s.validate_context_recoveries().unwrap();
    }
    #[test]
    fn opening_unchanged_legacy_idle_snapshots_does_not_promote_or_rewrite() {
        for version in 2..=9 {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("session.json");
            let mut s = Session::new();
            s.version = version;
            s.tool_timing = None;
            let bytes = serde_json::to_vec_pretty(&s).unwrap();
            std::fs::write(&path, &bytes).unwrap();
            let store = SessionStore::open(&path).unwrap();
            assert_eq!(store.snapshot().version, version);
            assert!(store.snapshot().context_recoveries.is_empty());
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
        }
    }
    #[test]
    fn genuine_manual_retry_success_releases_later_logical_requests() {
        let mut s = running();
        begin(&mut s);
        adopt(&mut s);
        let automatic = s.begin_recovery_retry("recovery-1").unwrap();
        s.finish_context_recovery(&automatic, false).unwrap();
        s.finish(&automatic, Err(Error::IncompleteStream)).unwrap();
        s.retry_turn().unwrap();
        let manual = s.active_reply.clone().unwrap();
        assert!(!s.can_recover_context(&manual));
        let active = s.active.clone().unwrap();
        s.finish_context_recovery(&manual, true).unwrap();
        s.finish(&manual, Ok(reply())).unwrap();
        s.validate_context_recoveries().unwrap();
        assert_eq!(s.context_recoveries[0].phase, Phase::Failed);
        assert_eq!(
            s.context_recoveries[0].resolved_reply_id.as_deref(),
            Some(manual.as_str())
        );
        s.activate(active);
        assert!(s.can_recover_context(s.active_reply.as_deref().unwrap()));
        let resolved = s.messages.iter_mut().find(|row| row.id == manual).unwrap();
        resolved.text.clear();
        assert!(s.validate_context_recoveries().is_err());
        s.messages
            .iter_mut()
            .find(|row| row.id == manual)
            .unwrap()
            .text = "Accepted".into();
        s.context_recoveries[0].resolved_reply_id = Some(automatic);
        assert!(s.validate_context_recoveries().is_err());
    }
    #[test]
    fn cancelled_automatic_retry_retains_checkpoint_and_consumption() {
        let mut s = running();
        begin(&mut s);
        adopt(&mut s);
        let retry = s.begin_recovery_retry("recovery-1").unwrap();
        s.finish_context_recovery(&retry, false).unwrap();
        s.cancel_context_recovery_retry(&retry).unwrap();
        s.finish(&retry, Err(Error::Cancelled)).unwrap();
        s.validate_context_recoveries().unwrap();
        assert_eq!(s.context_recoveries[0].phase, Phase::Cancelled);
        assert_eq!(
            s.context_recoveries[0].summary_id.as_deref(),
            Some("summary-1")
        );
        assert!(s.context_recoveries[0].resolved_reply_id.is_none());
        s.retry_turn().unwrap();
        assert!(!s.can_recover_context(s.active_reply.as_deref().unwrap()));
    }
    #[test]
    fn reported_rejection_usage_is_projected_once_to_owned_rows() {
        let mut s = running();
        let failed_id = s.active_reply.clone().unwrap();
        let mut evidence = failure();
        evidence.reported_usage = Some(json!({"input_tokens": 42}));
        s.begin_context_recovery("recovery-1", &failed_id, evidence.clone(), "a".repeat(64))
            .unwrap();
        assert_eq!(
            s.messages
                .iter()
                .find(|row| row.id == failed_id)
                .unwrap()
                .usage,
            json!({"input_tokens":42})
        );
        s.mark_recovery_summarizing("recovery-1").unwrap();
        let mut summary_failed = s.clone();
        summary_failed
            .fail_context_recovery(
                "recovery-1",
                &Error::ProviderFailure(Box::new(evidence.clone())),
                None,
            )
            .unwrap();
        let progress = &summary_failed.context_recoveries[0].progress_id;
        assert_eq!(
            summary_failed
                .messages
                .iter()
                .find(|row| &row.id == progress)
                .unwrap()
                .usage,
            json!({"input_tokens":42})
        );
        s.adopt_recovery_checkpoint("recovery-1", checkpoint(&s), &reply())
            .unwrap();
        let mut later_failed = s.clone();
        later_failed
            .fail_context_recovery(
                "recovery-1",
                &Error::ProviderFailure(Box::new(evidence.clone())),
                None,
            )
            .unwrap();
        let progress = &later_failed.context_recoveries[0].progress_id;
        assert_eq!(
            later_failed
                .messages
                .iter()
                .find(|row| &row.id == progress)
                .unwrap()
                .usage,
            reply().usage
        );
        let retry = s.begin_recovery_retry("recovery-1").unwrap();
        s.record_recovery_retry_failure(&retry, &Error::ProviderFailure(Box::new(evidence)))
            .unwrap();
        assert_eq!(
            s.messages.iter().find(|row| row.id == retry).unwrap().usage,
            json!({"input_tokens":42})
        );
        s.finish_context_recovery(&retry, false).unwrap();
        s.finish(&retry, Err(Error::IncompleteStream)).unwrap();
        s.validate_context_recoveries().unwrap();
    }
    #[test]
    fn receipt_turn_retargeting_cannot_release_the_consumed_request() {
        fn rejects_without_rewrite(s: &Session) {
            assert!(s.validate_context_recoveries().is_err());
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("session.json");
            let bytes = serde_json::to_vec_pretty(s).unwrap();
            std::fs::write(&path, &bytes).unwrap();
            // A malformed receipt cannot be opened by an actor, so it cannot
            // admit any provider/summary request, and recovery does not repair it.
            assert!(SessionStore::open(&path).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
        }
        let mut s = running();
        begin(&mut s);
        adopt(&mut s);
        let steering = Submission::new("Steering".into(), Lane::Steering);
        s.submit(steering.clone()).unwrap();
        let retry = s
            .begin_recovery_retry_with_steering("recovery-1", Some(&steering.id), None)
            .unwrap();
        s.finish_context_recovery(&retry, false).unwrap();
        s.finish(&retry, Err(Error::IncompleteStream)).unwrap();
        s.validate_context_recoveries().unwrap();
        let unrelated = s.messages.first().unwrap().id.clone();
        let mut bad_original = s.clone();
        bad_original.context_recoveries[0].turn_id = unrelated.clone();
        rejects_without_rewrite(&bad_original);
        let mut bad_retry = s.clone();
        bad_retry.context_recoveries[0].retry_turn_id = Some(unrelated.clone());
        rejects_without_rewrite(&bad_retry);
        let mut bad_root = s.clone();
        bad_root
            .messages
            .iter_mut()
            .find(|row| row.id == steering.id)
            .unwrap()
            .task_root_id = Some(unrelated);
        rejects_without_rewrite(&bad_root);
        let mut later_user = s
            .messages
            .iter()
            .find(|row| row.id == steering.id)
            .unwrap()
            .clone();
        later_user.id = "later-unrelated-user".into();
        later_user.task_root_id = Some(later_user.id.clone());
        s.context_recoveries[0].retry_turn_id = Some(later_user.id.clone());
        s.messages.push(later_user);
        rejects_without_rewrite(&s);
    }
    #[test]
    fn sparse_failure_usage_preserves_existing_observations_on_all_owned_rows() {
        let richer = json!({"input_tokens":42,"output_tokens":7});
        let mut evidence = failure();
        evidence.reported_usage = Some(json!({"input_tokens":42}));
        let mut s = running();
        let failed = s.active_reply.clone().unwrap();
        s.messages
            .iter_mut()
            .find(|row| row.id == failed)
            .unwrap()
            .usage = richer.clone();
        s.begin_context_recovery("recovery-1", &failed, evidence.clone(), "a".repeat(64))
            .unwrap();
        assert_eq!(
            s.messages
                .iter()
                .find(|row| row.id == failed)
                .unwrap()
                .usage,
            richer
        );
        s.mark_recovery_summarizing("recovery-1").unwrap();
        let mut summary_failed = s.clone();
        let progress = summary_failed.context_recoveries[0].progress_id.clone();
        summary_failed
            .messages
            .iter_mut()
            .find(|row| row.id == progress)
            .unwrap()
            .usage = richer.clone();
        summary_failed
            .fail_context_recovery(
                "recovery-1",
                &Error::ProviderFailure(Box::new(evidence.clone())),
                None,
            )
            .unwrap();
        assert_eq!(
            summary_failed
                .messages
                .iter()
                .find(|row| row.id == progress)
                .unwrap()
                .usage,
            richer
        );
        s.adopt_recovery_checkpoint("recovery-1", checkpoint(&s), &reply())
            .unwrap();
        let retry = s.begin_recovery_retry("recovery-1").unwrap();
        s.messages
            .iter_mut()
            .find(|row| row.id == retry)
            .unwrap()
            .usage = richer.clone();
        s.record_recovery_retry_failure(
            &retry,
            &Error::ProviderFailure(Box::new(evidence.clone())),
        )
        .unwrap();
        assert_eq!(
            s.messages.iter().find(|row| row.id == retry).unwrap().usage,
            richer
        );
        evidence.reported_usage = Some(json!({"input_tokens":43}));
        s.record_recovery_retry_failure(&retry, &Error::ProviderFailure(Box::new(evidence)))
            .unwrap();
        assert_eq!(
            s.messages.iter().find(|row| row.id == retry).unwrap().usage,
            json!({"input_tokens":null,"output_tokens":7})
        );
    }
}
