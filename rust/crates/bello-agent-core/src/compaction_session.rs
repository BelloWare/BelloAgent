//! Durable compaction state transitions. SessionStore applies these to a copy,
//! validates and syncs it before publishing, like all ordinary actor commands.
use crate::compaction::{self, Checkpoint, Operation, Phase};
use crate::{Error, Lane, Message, Profile, Reply, Result, RunState, Session, Submission, invalid};

impl Message {
    pub(crate) fn compaction_summary(
        id: String,
        text: String,
        checkpoint: Option<Checkpoint>,
    ) -> Self {
        Self {
            user_content: None,
            id,
            role: "system".into(),
            text: format!("{}{text}", compaction::REPLAY_PREFIX),
            reasoning: String::new(),
            replay_eligible: true,
            state: "complete".into(),
            usage: serde_json::Value::Null,
            model: None,
            tool_record: None,
            compaction: checkpoint,
        }
    }
}
impl Session {
    pub(crate) fn validate_compaction(&self) -> Result<()> {
        if self.version < 5
            && (self.compaction.is_some()
                || !self.compaction_history.is_empty()
                || self.messages.iter().any(|row| row.compaction.is_some()))
        {
            return Err(invalid(
                "Compaction history requires Rust snapshot version 5",
            ));
        }
        compaction::active_context(&self.messages)?;
        if self.compaction.is_none() && self.compaction_history.is_empty() {
            return Ok(());
        }
        let by_id: std::collections::BTreeMap<_, _> = self
            .messages
            .iter()
            .map(|row| (row.id.as_str(), row))
            .collect();
        let mut operation_ids = std::collections::BTreeSet::new();
        let mut progress_ids = std::collections::BTreeSet::new();
        if self.compaction_history.iter().any(Operation::is_running) {
            return Err(invalid("Historical compaction cannot remain active"));
        }
        for operation in self.compaction_history.iter().chain(self.compaction.iter()) {
            if !operation_ids.insert(&operation.id) || !progress_ids.insert(&operation.progress_id)
            {
                return Err(invalid("Duplicate compaction operation receipt"));
            }
            let progress = by_id
                .get(operation.progress_id.as_str())
                .ok_or_else(|| invalid("Compaction operation is missing its retained progress"))?;
            if operation.id.is_empty()
                || operation.id.len() > 256
                || progress.role != "assistant"
                || progress.replay_eligible
                || progress.compaction.is_some()
                || progress.tool_record.is_some()
            {
                return Err(invalid("Invalid retained compaction operation"));
            }
            if operation.is_running() {
                if self.state != RunState::Running
                    || self.active_reply.as_ref() != Some(&operation.progress_id)
                    || self
                        .active
                        .as_ref()
                        .is_none_or(|active| active.id != format!("compaction:{}", operation.id))
                    || operation.summary_id.is_some()
                {
                    return Err(invalid(
                        "Running compaction does not own its active progress",
                    ));
                }
            } else if operation.phase == Phase::Completed {
                if !operation
                    .summary_id
                    .as_ref()
                    .and_then(|id| by_id.get(id.as_str()))
                    .is_some_and(|row| {
                        row.compaction
                            .as_ref()
                            .is_some_and(|checkpoint| checkpoint.operation_id == operation.id)
                    })
                {
                    return Err(invalid("Completed compaction lacks its durable checkpoint"));
                }
            } else if operation.summary_id.is_some() {
                return Err(invalid("Failed compaction cannot claim a checkpoint"));
            }
        }
        Ok(())
    }

    pub(crate) fn begin_compaction(
        &mut self,
        operation_id: &str,
        profile: &Profile,
        release_queue: bool,
    ) -> Result<String> {
        if self.state == RunState::Running || self.active.is_some() || self.active_reply.is_some() {
            return Err(invalid(
                "The running turn did not stop, so the chat was not compacted",
            ));
        }
        self.version = self.version.max(5);
        if release_queue && self.state != RunState::Error {
            self.queue_paused = false;
        }
        let mut intent = Submission::new("[Compact now]".into(), Lane::FollowUp);
        intent.id = format!("compaction:{operation_id}");
        intent.model = Some(profile.model_id.clone());
        intent.effort = Some(profile.thinking_level.clone());
        self.activate(intent);
        let progress_id = self.active_reply.clone().expect("activated progress");
        if let Some(previous) = self.compaction.take() {
            self.compaction_history.push(previous);
        }
        self.compaction = Some(Operation {
            id: operation_id.into(),
            phase: Phase::Planning,
            progress_id: progress_id.clone(),
            summary_id: None,
            error: None,
            summary_output_allowance: 0,
            http_attempts: 0,
        });
        Ok(progress_id)
    }

    pub(crate) fn adopt_compaction(
        &mut self,
        operation_id: &str,
        summary: Message,
        reply: &Reply,
    ) -> Result<()> {
        let operation = self
            .compaction
            .as_ref()
            .filter(|operation| operation.id == operation_id && operation.is_running())
            .ok_or_else(|| invalid("Stale compaction completion"))?;
        let checkpoint = summary
            .compaction
            .as_ref()
            .ok_or_else(|| invalid("Missing completed checkpoint"))?;
        let active = compaction::active_context(&self.messages)?;
        if checkpoint.operation_id != operation_id
            || active
                .iter()
                .map(|row| row.id.as_str())
                .ne(checkpoint.source_ids.iter().map(String::as_str))
        {
            return Err(invalid(
                "Context changed while summarizing; original context is retained",
            ));
        }
        let progress_id = operation.progress_id.clone();
        self.finish_compaction_progress(&progress_id, Some(reply), "compaction-complete")?;
        let operation = self.compaction.as_mut().unwrap();
        operation.phase = Phase::Completed;
        operation.summary_id = Some(summary.id.clone());
        operation.error = None;
        self.messages.push(summary);
        self.retry = None;
        self.active = None;
        self.active_reply = None;
        self.state = RunState::Idle;
        self.error = None;
        Ok(())
    }

    pub(crate) fn fail_compaction(
        &mut self,
        operation_id: &str,
        error: Error,
        reply: Option<&Reply>,
    ) -> Result<()> {
        let operation = self
            .compaction
            .as_ref()
            .filter(|operation| operation.id == operation_id && operation.is_running())
            .ok_or_else(|| invalid("Stale compaction failure"))?;
        let progress_id = operation.progress_id.clone();
        let cancelled = matches!(error, Error::Cancelled);
        self.finish_compaction_progress(
            &progress_id,
            reply,
            if cancelled {
                "compaction-cancelled"
            } else {
                "compaction-failed"
            },
        )?;
        let description = format!(
            "Compaction {}: {error}. Original context is retained.",
            if cancelled { "cancelled" } else { "failed" }
        );
        let operation = self.compaction.as_mut().unwrap();
        operation.phase = if cancelled {
            Phase::Cancelled
        } else {
            Phase::Failed
        };
        operation.error = Some(description.clone());
        self.active = None;
        self.active_reply = None;
        self.state = if cancelled {
            RunState::Paused
        } else {
            RunState::Error
        };
        self.queue_paused = true;
        self.error = Some(description);
        Ok(())
    }
    pub(crate) fn recover_compaction(&mut self) -> Result<()> {
        let operation = self
            .compaction
            .as_ref()
            .ok_or_else(|| invalid("Missing interrupted compaction"))?;
        let id = operation.id.clone();
        let progress_id = operation.progress_id.clone();
        self.fail_compaction(&id, Error::Cancelled, None)?;
        let description = "Compaction interrupted · no terminal receipt. Original context and partial progress are retained; queued input is paused.".to_owned();
        let operation = self.compaction.as_mut().unwrap();
        operation.phase = Phase::Interrupted;
        operation.error = Some(description.clone());
        self.error = Some(description);
        self.finish_compaction_progress(&progress_id, None, "compaction-interrupted")
    }
    fn finish_compaction_progress(
        &mut self,
        progress_id: &str,
        reply: Option<&Reply>,
        state: &str,
    ) -> Result<()> {
        let progress = self
            .messages
            .iter_mut()
            .find(|row| row.id == progress_id)
            .ok_or_else(|| invalid("Missing compaction progress"))?;
        if let Some(reply) = reply {
            progress.text = reply.text.clone();
            progress.reasoning = reply.reasoning.clone();
            progress.usage = reply.usage.clone();
        }
        progress.replay_eligible = false;
        progress.state = state.into();
        Ok(())
    }
}
