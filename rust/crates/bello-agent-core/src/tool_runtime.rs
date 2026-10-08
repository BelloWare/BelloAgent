//! Opt-in Controller integration for source read-only file capabilities.
//! Desktop constructors stay disabled. This is an explicit host trust assertion,
//! not a filesystem sandbox or a saved authorization inferred from conversation.
use super::Controller;
use crate::{
    Error, Lane, Message, Profile, Reply, Result, RunState, Session, Submission, invalid,
    provider::{ToolCall, request_body_with_tools},
    tool_history::{
        AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
    },
    tools::{BlockingWorkExecutor, Capability, NativeTools, ToolError},
};
use futures_util::future::join_all;
use serde_json::Value;
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

/// Frozen for this Controller's lifetime. Empty/disabled is the compatibility
/// default. Instructions are already-resolved text, not a discovery request.
#[derive(Clone, Default)]
pub struct RuntimeOptions {
    pub instructions: String,
    pub tools: Option<TrustedReadOnlyTools>,
}
impl RuntimeOptions {
    pub(super) fn definitions(&self) -> Vec<crate::tools::ToolDefinition> {
        let mut definitions = self
            .tools
            .as_ref()
            .map(|tools| tools.native.definitions())
            .unwrap_or_default();
        if self.tools.as_ref().is_some_and(|tools| tools.mcp.is_some()) {
            definitions.push(crate::mcp::definition());
        }
        definitions
    }
}

/// Submission overrides apply only after delivery, including an explicit Retry.
/// Preview and dispatch use this same profile selection.
pub(super) fn effective_profile(base: &Profile, item: Option<&Submission>) -> Profile {
    let mut profile = base.clone();
    if let Some(item) = item {
        if let Some(model) = &item.model {
            if profile.model_id != *model {
                profile.input = vec!["text".into()];
            }
            profile.model_id = model.clone();
        }
        if let Some(effort) = &item.effort {
            profile.thinking_level = effort.clone();
        }
    }
    profile
}

/// Construct only after the host has obtained explicit project trust and chosen
/// read-only tools. Roots resolve relative paths; absolute/parent/tilde/symlink
/// paths may leave them, exactly as in the source. Construction performs no
/// discovery; explicit macOS file searches may resolve named-user paths when invoked.
#[derive(Clone)]
pub struct TrustedReadOnlyTools {
    pub(super) native: NativeTools,
    pub(super) mcp: Option<McpTools>,
}
#[derive(Clone)]
pub(super) struct McpTools {
    pub manager: Arc<crate::mcp::McpManager>,
    pub read_only: bool,
}
impl TrustedReadOnlyTools {
    #[cfg(all(test, unix))]
    pub(crate) fn with_shell_environment(
        mut self,
        environment: crate::tools::bash::Environment,
    ) -> Self {
        self.native = self.native.with_shell_environment(environment);
        self
    }
    pub(crate) fn with_mcp(
        mut self,
        manager: Arc<crate::mcp::McpManager>,
        read_only: bool,
    ) -> Self {
        self.mcp = Some(McpTools { manager, read_only });
        self
    }

    pub fn new(cwd: PathBuf, additional_roots: Vec<PathBuf>, home: PathBuf) -> Result<Self> {
        Self::new_with_capabilities(cwd, additional_roots, home, [Capability::Ls])
    }
    /// Explicit immutable tool selection after host trust and read-only mode.
    /// Unsupported platform capabilities fail rather than being silently offered.
    pub fn new_with_capabilities(
        cwd: PathBuf,
        additional_roots: Vec<PathBuf>,
        home: PathBuf,
        capabilities: impl IntoIterator<Item = Capability>,
    ) -> Result<Self> {
        let capabilities: Vec<_> = capabilities.into_iter().collect();
        if capabilities.iter().any(|capability| {
            matches!(
                capability,
                Capability::Write | Capability::Edit | Capability::Bash
            )
        }) {
            return Err(invalid(
                "Read-only tool authority cannot offer write, edit or bash",
            ));
        }
        Ok(Self {
            mcp: None,
            native: NativeTools::new(cwd, additional_roots, home, capabilities)
                .map_err(|error| invalid(error.to_string()))?,
        })
    }
    /// Crate-private factory composition after a saved Editing mode and
    /// current project trust have been checked. No default native caller.
    pub(crate) fn new_with_editing_capabilities(
        cwd: PathBuf,
        additional_roots: Vec<PathBuf>,
        home: PathBuf,
        capabilities: impl IntoIterator<Item = Capability>,
    ) -> Result<Self> {
        Ok(Self {
            mcp: None,
            native: NativeTools::new(cwd, additional_roots, home, capabilities)
                .map_err(|error| invalid(error.to_string()))?,
        })
    }

    #[cfg(all(test, not(target_os = "macos"), feature = "synthetic-authority"))]
    pub(crate) fn synthetic_mutation_fixture(
        cwd: PathBuf,
        roots: Vec<PathBuf>,
        home: PathBuf,
        capabilities: Vec<Capability>,
    ) -> Result<Self> {
        Ok(Self {
            mcp: None,
            native: NativeTools::synthetic_mutation_fixture(cwd, roots, home, capabilities)
                .map_err(|error| invalid(error.to_string()))?,
        })
    }

    /// Allows deterministic worker admission tests without using real files or
    /// changing the shared production executor's four-worker/64-waiting limits.
    pub fn with_executor(mut self, executor: BlockingWorkExecutor) -> Self {
        self.native = self.native.with_executor(executor);
        self
    }
}

#[derive(Clone, Debug)]
pub(crate) struct ToolResultRow {
    pub duration_us: Option<crate::tool_timing::DurationUs>,
    pub text: String,
    pub content: Option<Arc<crate::tool_content::ToolContent>>,
    pub outcome: ToolOutcome,
}
impl ToolResultRow {
    fn error(text: impl Into<String>, outcome: ToolOutcome) -> Self {
        Self {
            duration_us: None,
            text: text.into(),
            content: None,
            outcome,
        }
    }
}

/// One immutable observation, cloned only into disposable candidate snapshots.
#[derive(Clone, Debug)]
pub(crate) struct CompletedToolBatch {
    pub rows: Vec<ToolResultRow>,
    pub timing: crate::tool_timing::BatchTiming,
}
impl CompletedToolBatch {
    fn unobserved(rows: Vec<ToolResultRow>) -> Self {
        Self {
            rows,
            timing: crate::tool_timing::BatchTiming { wall_us: None },
        }
    }
}

fn message(role: &str, text: String, model: Option<String>) -> Message {
    Message {
        task_root_id: None,
        user_content: None,
        id: Uuid::new_v4().to_string(),
        role: role.into(),
        text,
        reasoning: String::new(),
        replay_eligible: true,
        state: "completed".into(),
        usage: Value::Null,
        model,
        tool_record: None,
        compaction: None,
    }
}

#[cfg(all(test, feature = "synthetic-authority"))]
impl Controller {
    pub(crate) fn pause_native_admission_for_test(
        &self,
    ) -> Arc<crate::tools::TestAdmissionBarrier> {
        self.options
            .tools
            .as_ref()
            .expect("fixture native tools")
            .native
            .pause_admission_for_test()
    }
}

impl Session {
    /// The durable phase discriminator. No new execution is inferred from a
    /// historical call: it must be the current active completed assistant.
    pub(crate) fn active_tool_calls(&self) -> Option<&[ToolCall]> {
        let active = self.active_reply.as_deref()?;
        let message = self
            .messages
            .last()
            .filter(|message| message.id == active)?;
        match &message.tool_record {
            Some(ToolRecord::Assistant(record))
                if record.completion == Completion::Complete
                    && message.state == "completed"
                    && message.replay_eligible =>
            {
                Some(&record.calls)
            }
            _ => None,
        }
    }

    pub(crate) fn begin_tools(
        &mut self,
        reply_id: &str,
        reply: &Reply,
        profile: &Profile,
    ) -> Result<()> {
        if self.active_reply.as_deref() != Some(reply_id) || self.active_tool_calls().is_some() {
            return Err(invalid("Stale tool response completion"));
        }
        if reply.status != "completed" || reply.calls.is_empty() {
            return Err(invalid(
                "Incomplete tool response was not executed; retry with complete arguments",
            ));
        }
        let row = self
            .messages
            .iter_mut()
            .find(|row| row.id == reply_id)
            .ok_or_else(|| invalid("Missing active tool reply"))?;
        row.text = reply.text.clone();
        row.reasoning = reply.reasoning.clone();
        row.usage = reply.usage.clone();
        row.state = "completed".into();
        row.replay_eligible = true;
        row.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
            tool_batch_timing: None,
            completion: Completion::Complete,
            calls: reply.calls.clone(),
            binding: ReplayBinding::from_profile(profile)?,
            provider_items: reply.provider_items.clone(),
        }));
        self.version = self.version.max(3);
        crate::tool_history::validate(&self.messages)
    }

    /// Results and the next response placeholder are one checkpoint. Steering
    /// joins only after the whole batch, and an edit hold leaves both lanes alone.
    pub(crate) fn settle_tools(
        &mut self,
        reply_id: &str,
        results: Vec<ToolResultRow>,
        stop: bool,
    ) -> Result<()> {
        let steering = self
            .pending
            .iter()
            .find(|item| item.lane == Lane::Steering)
            .map(|item| item.id.clone());
        self.settle_tools_with_steering(reply_id, results, stop, steering.as_deref())
    }

    /// Synthetic delivery prepares one captured steering candidate before this
    /// atomic checkpoint. Later arrivals must not be implicitly consumed here.
    pub(crate) fn settle_tools_with_steering(
        &mut self,
        reply_id: &str,
        results: Vec<ToolResultRow>,
        stop: bool,
        steering: Option<&str>,
    ) -> Result<()> {
        self.settle_tools_with_prepared_steering(reply_id, results, stop, steering, None)
    }
    pub(crate) fn settle_tools_with_prepared_steering(
        &mut self,
        reply_id: &str,
        results: Vec<ToolResultRow>,
        stop: bool,
        steering: Option<&str>,
        prepared: Option<crate::session::PreparedUserInput>,
    ) -> Result<()> {
        self.settle_completed_tool_batch(
            reply_id,
            CompletedToolBatch::unobserved(results),
            stop,
            steering,
            prepared,
        )
    }
    pub(crate) fn settle_completed_tool_batch(
        &mut self,
        reply_id: &str,
        batch: CompletedToolBatch,
        stop: bool,
        steering: Option<&str>,
        prepared: Option<crate::session::PreparedUserInput>,
    ) -> Result<()> {
        if self.active_reply.as_deref() != Some(reply_id) {
            return Err(invalid("Stale tool batch completion"));
        }
        let results = batch.rows;
        // Validate before appending any tool rows in this pure state operation.
        let content = if !stop && self.edit.is_none() && !self.queue_paused {
            if let Some(item) = self
                .pending
                .iter()
                .find(|item| item.lane == Lane::Steering && Some(item.id.as_str()) == steering)
            {
                crate::session::checked_prepared(item, prepared)?
            } else {
                None
            }
        } else {
            None
        };
        let calls = self
            .active_tool_calls()
            .ok_or_else(|| invalid("No active tool batch"))?
            .to_vec();
        if calls.len() != results.len() {
            return Err(invalid("Tool batch results do not match its calls"));
        }
        {
            let timing = batch.timing;
            let owner = self
                .messages
                .iter_mut()
                .find(|row| row.id == reply_id)
                .and_then(|row| row.tool_record.as_mut())
                .ok_or_else(|| invalid("Missing tool batch owner"))?;
            let ToolRecord::Assistant(owner) = owner else {
                return Err(invalid("Invalid tool batch owner"));
            };
            if owner.tool_batch_timing.is_some() {
                return Err(invalid("Tool batch timing already recorded"));
            }
            owner.tool_batch_timing = Some(timing);
            self.tool_timing = Some(crate::tool_timing::SessionToolTiming::adding(
                self.tool_timing,
                timing,
            ));
            self.version = self.version.max(9);
        }
        let model = self.active.as_ref().and_then(|item| item.model.clone());
        for (call, result) in calls.iter().zip(results) {
            let mut row = message("toolResult", result.text, model.clone());
            row.tool_record = Some(ToolRecord::Result(ResultRecord {
                assistant_id: reply_id.into(),
                call_id: call.id.clone(),
                is_error: result.outcome != ToolOutcome::Completed,
                outcome: result.outcome,
                content: result.content,
                duration_us: result.duration_us,
            }));
            self.messages.push(row);
        }
        if stop {
            self.retry = self.active.take();
            self.active_reply = None;
            self.state = RunState::Paused;
            self.queue_paused = true;
            self.error = Some("Tool work stopped. Retained results are kept; pending messages are paused. No tool is automatically replayed.".into());
            return Ok(());
        }
        let mut item = self
            .active
            .clone()
            .ok_or_else(|| invalid("Missing active tool turn"))?;
        if self.edit.is_none()
            && !self.queue_paused
            && let Some(index) = self
                .pending
                .iter()
                .position(|item| item.lane == Lane::Steering && Some(item.id.as_str()) == steering)
        {
            let root = self
                .messages
                .iter()
                .find(|row| row.role == "user" && row.id == item.id)
                .and_then(|row| row.task_root_id.clone())
                .unwrap_or_else(|| item.id.clone());
            self.version = self.version.max(8);
            if let Some(row) = self
                .messages
                .iter_mut()
                .find(|row| row.role == "user" && row.id == root)
            {
                row.task_root_id = Some(root.clone());
            }
            item = self.pending.remove(index);
            let mut user = message("user", item.text.clone(), item.model.clone());
            user.id = item.id.clone();
            user.task_root_id = Some(root);
            user.user_content = content;
            self.messages.push(user);
        }
        self.activate(item);
        Ok(())
    }

    pub(crate) fn recover_tools(&mut self) -> bool {
        let Some(calls) = self.active_tool_calls() else {
            return false;
        };
        let results = calls.iter().map(|_| ToolResultRow::error(
            "Interrupted before a tool result was durably recorded. Its output is unknown. No automatic replay.",
            ToolOutcome::Unknown,
        )).collect();
        let id = self.active_reply.clone().expect("active tool reply");
        self.settle_tools(&id, results, true)
            .expect("validated active tool checkpoint");
        true
    }
}

impl Controller {
    pub(super) async fn run_turn(
        self: &Arc<Self>,
        mut item: Submission,
        mut snapshot: Session,
        cancel: CancellationToken,
    ) {
        let config = self.configuration().expect("configuration checked");
        let definitions = self.options.definitions();
        loop {
            if self.is_retired() {
                cancel.cancel();
            }
            let reply_id = snapshot
                .active_reply
                .clone()
                .expect("active reply assigned");
            let profile = effective_profile(&config.profile, Some(&item));
            let callback_id = reply_id.clone();
            let callback_self = Arc::clone(self);
            let instructions = self.turn_instructions(&item);
            let ready = async {
                config.confirm_for_request().await?;
                self.confirm_turn_resources(cancel.clone()).await
            }
            .await;
            let response = match ready {
                Err(error) => Err(error),
                Ok(()) => {
                    self.client
                        .complete_with_tools(
                            &profile,
                            &config.credential,
                            &snapshot.messages,
                            &instructions,
                            &snapshot.id,
                            &item.id,
                            &definitions,
                            cancel.clone(),
                            move |delta| callback_self.stream_delta(&callback_id, delta),
                        )
                        .await
                }
            };
            let prepared = {
                let mut inner = self.inner.lock().expect("session mutex poisoned");
                // Stop wins a terminal response already in flight.
                let response = if self.is_retired() || cancel.is_cancelled() {
                    Err(Error::Cancelled)
                } else {
                    response
                };
                match response {
                    Ok(reply) if !reply.calls.is_empty() && self.options.tools.is_some() => {
                        let attempt = inner.store.transact(|session| {
                            session.begin_tools(&reply_id, &reply, &profile)?;
                            // Fail closed before any filesystem invocation if existing
                            // opaque history cannot be replayed or the request is too big.
                            let body = request_body_with_tools(
                                &profile,
                                &session.messages,
                                &instructions,
                                &session.id,
                                &definitions,
                            )?;
                            crate::provider::serialize_request(&body)?;
                            Ok(())
                        });
                        match attempt {
                            Ok(()) => {
                                let directory = inner.store.tool_output_directory();
                                self.publish(&inner);
                                Some((reply.calls, directory))
                            }
                            Err(error) => {
                                // An uncertain write cannot be followed by another
                                // mutation or an invocation. Reopen is authoritative.
                                if matches!(error, Error::PersistenceUncertain(_)) {
                                    inner.fatal = Some(error.to_string());
                                } else if let Err(error) = inner.store.transact(|session| {
                                    if let Some(row) =
                                        session.messages.iter_mut().find(|row| row.id == reply_id)
                                    {
                                        row.text = reply.text.clone();
                                        row.reasoning = reply.reasoning.clone();
                                        row.usage = reply.usage.clone();
                                    }
                                    session.finish(&reply_id, Err(error))
                                }) {
                                    inner.fatal = Some(error.to_string());
                                }
                                None
                            }
                        }
                    }
                    response => {
                        if let Err(error) = inner
                            .store
                            .transact(|session| session.finish(&reply_id, response))
                        {
                            inner.fatal = Some(error.to_string());
                        }
                        None
                    }
                }
            };
            let Some((calls, output_directory)) = prepared else {
                return;
            };
            let tools = self.options.tools.as_ref().expect("tools checked");
            // A fixture authority change after the provider completed may not
            // authorize even a read-only invocation. Retain explicit results.
            if let Err(error) = self.confirm_turn_resources(cancel.clone()).await {
                let results = calls
                    .iter()
                    .map(|_| {
                        ToolResultRow::error(
                            format!("Not executed: {error}"),
                            ToolOutcome::NotExecuted,
                        )
                    })
                    .collect();
                let mut inner = self.inner.lock().expect("session mutex poisoned");
                if let Err(error) = inner.store.transact(|session| {
                    session.settle_tools(&reply_id, results, true)?;
                    session.error = Some(error.to_string());
                    Ok(())
                }) {
                    inner.fatal = Some(error.to_string());
                }
                self.publish(&inner);
                return;
            }
            // Source SessionTools runs editing calls in original call order
            // beside concurrent readers, and joins every entered worker on Stop.
            let content_budget = Arc::new(BatchContentBudget::default());
            let execute = |index: usize| {
                let call = &calls[index];
                let budget = content_budget.clone();
                let token = cancel.clone();
                let directory = &output_directory;
                let reply_id = &reply_id;
                async move {
                    let live = self.live_tool_identity(reply_id, &call.id);
                    let (result, receipt) = if call.name == "mcp"
                        && let Some(mcp) = &tools.mcp
                    {
                        run_mcp_call(mcp, call, directory, token.clone(), budget, || async {
                            self.confirm_turn_resources(token.clone()).await
                        })
                        .await
                    } else {
                        #[cfg(unix)]
                        let native = tools.native.clone().with_shell_update(
                            (call.name == "bash")
                                .then(|| live.clone())
                                .flatten()
                                .map(|identity| {
                                    Arc::new(move |update: crate::tools::bash::Update| {
                                        identity.update(update.sequence, update.preview)
                                    })
                                        as crate::tools::bash::OnUpdate
                                }),
                        );
                        #[cfg(not(unix))]
                        let native = tools.native.clone();
                        let result = run_call_with_admission(
                            &native,
                            call,
                            directory,
                            token.clone(),
                            budget,
                            async {
                                let confirmation = if tools.native.editing_call(call) {
                                    self.confirm_turn_resources(token.clone()).await
                                } else {
                                    self.check_resources()
                                };
                                confirmation.map_err(|error| {
                                    ToolError::NotExecuted(if token.is_cancelled() {
                                        "Not executed: cancelled before invocation".into()
                                    } else {
                                        format!("Not executed: {error}")
                                    })
                                })
                            },
                        )
                        .await;
                        (result, None)
                    };
                    // Publish only display state. The Ticket and canonical rows
                    // remain owned by ordered whole-batch settlement below.
                    if let Some(live) = live {
                        live.finish_result(&result);
                    }
                    (index, result, receipt)
                }
            };
            // Every call, including same-file edits and MCP invocations, starts
            // independently. Durable rows still follow original reply order.
            let batch_started = std::time::Instant::now();
            let mut completed = join_all((0..calls.len()).map(execute)).await;
            let timing = crate::tool_timing::BatchTiming {
                wall_us: crate::tool_timing::DurationUs::since(batch_started),
            };
            completed.sort_by_key(|(index, _, _)| *index);
            let mut receipts = Vec::new();
            let results = completed
                .into_iter()
                .map(|(_, result, receipt)| {
                    receipts.extend(receipt);
                    result
                })
                .collect();
            let results = CompletedToolBatch {
                rows: results,
                timing,
            };
            #[cfg(feature = "synthetic-authority")]
            if self.resources.is_some() {
                let Some((next_item, next_snapshot)) = self
                    .settle_resource_tools(&reply_id, results, cancel.clone())
                    .await
                else {
                    return;
                };
                if let Err(error) = settle_mcp_receipts(receipts).await {
                    let mut inner = self.inner.lock().expect("session mutex poisoned");
                    inner.fatal = Some(error.to_string());
                    self.publish(&inner);
                    return;
                }
                item = next_item;
                snapshot = next_snapshot;
                if snapshot.state != RunState::Running {
                    return;
                }
                continue;
            }
            let Some((next_item, next_snapshot)) = self
                .settle_image_tools(&reply_id, results, cancel.clone())
                .await
            else {
                return;
            };
            item = next_item;
            snapshot = next_snapshot;
            if let Err(error) = settle_mcp_receipts(receipts).await {
                let mut inner = self.inner.lock().expect("session mutex poisoned");
                inner.fatal = Some(error.to_string());
                self.publish(&inner);
                return;
            }
            if snapshot.state != RunState::Running {
                return;
            }
        }
    }

    fn turn_instructions(&self, item: &Submission) -> String {
        if self.project_resources.is_some() {
            return self
                .inner
                .lock()
                .expect("session mutex poisoned")
                .applied_project
                .as_ref()
                .filter(|applied| applied.turn_id == item.id)
                .expect("delivered project turn has applied resources")
                .instructions
                .clone();
        }
        #[cfg(feature = "synthetic-authority")]
        if self.resources.is_some() {
            return self
                .applied_instruction_snapshot()
                .filter(|snapshot| snapshot.turn_id == item.id)
                .expect("delivered synthetic turn has an applied snapshot")
                .instructions
                .clone();
        }
        let _ = item;
        self.options.instructions.clone()
    }

    async fn confirm_turn_resources(&self, cancel: CancellationToken) -> Result<()> {
        if self.authority.is_some()
            && let Some(configuration) = self.configuration()
        {
            configuration.confirm_for_request().await?;
        }
        self.confirm_runtime_authority(cancel.clone()).await?;
        #[cfg(feature = "synthetic-authority")]
        if self.resources.is_some() {
            return self.confirm_resources_async(cancel).await;
        }
        let _ = cancel;
        Ok(())
    }
}

async fn settle_mcp_receipts(receipts: Vec<crate::mcp::Ticket>) -> Result<()> {
    if receipts.is_empty() {
        return Ok(());
    }
    crate::mcp::persistence(move || {
        for receipt in receipts {
            receipt.settle()?;
        }
        Ok(())
    })
    .await
    .map_err(|_| invalid("MCP result receipt worker failed; project remains quarantined"))?
}
async fn run_mcp_call<F, Fut>(
    tools: &McpTools,
    call: &ToolCall,
    directory: &Path,
    cancel: CancellationToken,
    budget: Arc<BatchContentBudget>,
    admission: F,
) -> (ToolResultRow, Option<crate::mcp::Ticket>)
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<()>>,
{
    let started = std::time::Instant::now();
    if cancel.is_cancelled() {
        return (
            ToolResultRow::error(
                "Not executed: cancelled before invocation",
                ToolOutcome::NotExecuted,
            ),
            None,
        );
    }
    // Invocation means entering the MCP wrapper, not proof of remote effects.
    // In particular HTTP rejections/404 recovery can truthfully have elapsed
    // time even when their outcome contract says no remote action executed.
    let (mut result, receipt, recorded) =
        run_mcp_call_observed(tools, call, directory, cancel, budget, admission).await;
    if recorded {
        result.duration_us = crate::tool_timing::DurationUs::since(started);
    }
    (result, receipt)
}
async fn run_mcp_call_observed<F, Fut>(
    tools: &McpTools,
    call: &ToolCall,
    directory: &Path,
    cancel: CancellationToken,
    budget: Arc<BatchContentBudget>,
    admission: F,
) -> (ToolResultRow, Option<crate::mcp::Ticket>, bool)
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<()>>,
{
    let performed = match tools
        .manager
        .perform(&call.arguments, tools.read_only, cancel.clone(), admission)
        .await
    {
        Ok(result) => result,
        Err(error) => {
            let outcome = if error.not_executed {
                ToolOutcome::NotExecuted
            } else if call.arguments["action"] == "invoke" {
                ToolOutcome::Unknown
            } else {
                ToolOutcome::Failed
            };
            return (
                ToolResultRow::error(error.message, outcome),
                None,
                !error.recording_failed,
            );
        }
    };
    let mut ticket = performed.ticket;
    let has_effect_ticket = ticket.is_some();
    let mut content = performed.normalized.content;
    let mut text = content.text();
    if text.len() > 65_536 {
        let path = directory.to_owned();
        let whole = text;
        // Receipt/OS lease ownership moves with physical output retention.
        // Caller cancellation cannot abandon a started persistence operation.
        match crate::mcp::persistence(move || (retain_output(&path, &whole), ticket)).await {
            Ok((Ok(preview), retained_ticket)) => {
                ticket = retained_ticket;
                text = preview.clone();
                let mut blocks = vec![crate::tool_content::ContentBlock::Text { text: preview }];
                blocks.extend(
                    content
                        .blocks
                        .iter()
                        .filter(|b| matches!(b, crate::tool_content::ContentBlock::Image { .. }))
                        .cloned(),
                );
                content = Arc::new(crate::tool_content::ToolContent {
                    blocks,
                    stats: None,
                });
            }
            _ => {
                return (
                    ToolResultRow::error(
                        "MCP result could not be retained; inspect effects before retrying. No automatic replay.",
                        if has_effect_ticket {
                            ToolOutcome::Unknown
                        } else {
                            ToolOutcome::Failed
                        },
                    ),
                    None,
                    false,
                );
            }
        }
    }
    let charged = content
        .encoded_len()
        .ok()
        .and_then(|n| n.checked_add(text.len()));
    if charged.is_none_or(|n| !budget.reserve(n)) {
        return (
            ToolResultRow::error(
                "MCP result exceeds the batch retention limit; inspect effects before retrying. No automatic replay.",
                if has_effect_ticket {
                    ToolOutcome::Unknown
                } else {
                    ToolOutcome::Failed
                },
            ),
            None,
            false,
        );
    }
    (
        ToolResultRow {
            duration_us: None,
            text,
            content: Some(content),
            outcome: if performed.normalized.is_error {
                ToolOutcome::Failed
            } else {
                ToolOutcome::Completed
            },
        },
        ticket,
        true,
    )
}

const MAX_BATCH_CONTENT_BYTES: usize = 32 * 1024 * 1024;

/// Charges successful durable content until the entire batch settles. This is
/// not a whole-process bound: four active native decoders have their own budgets.
struct BatchContentBudget {
    used: AtomicUsize,
    maximum: usize,
}
impl Default for BatchContentBudget {
    fn default() -> Self {
        Self {
            used: AtomicUsize::new(0),
            maximum: MAX_BATCH_CONTENT_BYTES,
        }
    }
}
impl BatchContentBudget {
    fn reserve(&self, bytes: usize) -> bool {
        let mut used = self.used.load(Ordering::Acquire);
        loop {
            let Some(next) = used
                .checked_add(bytes)
                .filter(|total| *total <= self.maximum)
            else {
                return false;
            };
            match self
                .used
                .compare_exchange_weak(used, next, Ordering::AcqRel, Ordering::Acquire)
            {
                Ok(_) => return true,
                Err(observed) => used = observed,
            }
        }
    }
}
struct NativeOutput {
    is_error: bool,
    text: String,
    content: Option<Arc<crate::tool_content::ToolContent>>,
}
fn retain_native_content(
    value: Value,
    budget: &BatchContentBudget,
) -> std::result::Result<NativeOutput, ToolError> {
    let text = value["content"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|part| part["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let content = if value.get("stats").is_some()
        || value["content"]
            .as_array()
            .is_some_and(|parts| parts.iter().any(|part| part["type"] == "image"))
    {
        let content = crate::tool_content::ToolContent::from_native(&value).map_err(|error| {
            ToolError::Failure {
                code: "tool_result",
                message: error.to_string(),
            }
        })?;
        let bytes = content
            .encoded_len()
            .ok()
            .and_then(|bytes| bytes.checked_add(text.len()))
            .ok_or_else(|| ToolError::Failure {
                code: "tool_result",
                message: "Tool result exceeds its retention limit".into(),
            })?;
        if !budget.reserve(bytes) {
            return Err(ToolError::Failure {code:"tool_result",message:"Tool result could not be retained: this batch exceeds the 32 MiB content limit. No automatic replay.".into()});
        }
        Some(Arc::new(content))
    } else {
        None
    };
    Ok(NativeOutput {
        is_error: value["isError"].as_bool().unwrap_or(false),
        text,
        content,
    })
}

#[cfg(test)]
async fn run_call(
    tools: &NativeTools,
    call: &ToolCall,
    directory: &Path,
    cancel: CancellationToken,
) -> ToolResultRow {
    run_call_with_budget(
        tools,
        call,
        directory,
        cancel,
        Arc::new(BatchContentBudget::default()),
    )
    .await
}

#[cfg(test)]
async fn run_call_with_budget(
    tools: &NativeTools,
    call: &ToolCall,
    directory: &Path,
    cancel: CancellationToken,
    budget: Arc<BatchContentBudget>,
) -> ToolResultRow {
    run_call_with_admission(tools, call, directory, cancel, budget, async { Ok(()) }).await
}

async fn run_call_with_admission(
    tools: &NativeTools,
    call: &ToolCall,
    directory: &Path,
    cancel: CancellationToken,
    budget: Arc<BatchContentBudget>,
    admission: impl std::future::Future<Output = crate::tools::ToolResult<()>>,
) -> ToolResultRow {
    let started = std::time::Instant::now();
    if cancel.is_cancelled() {
        return ToolResultRow::error(
            "Not executed: cancelled before invocation",
            ToolOutcome::NotExecuted,
        );
    }
    // Source SessionTools marks invocation begun before NativeTools worker
    // admission. Cancellation from this point has an unknown output, even
    // when a queued filesystem read never reached the operating system.
    let prepared = tools.prepare_call(call);
    if cancel.is_cancelled() {
        return ToolResultRow::error(
            "Not executed: cancelled before invocation",
            ToolOutcome::NotExecuted,
        );
    }
    #[cfg(unix)]
    let configured = tools.clone().with_shell_output(directory.to_owned());
    #[cfg(unix)]
    let tools = &configured;
    let retained_directory = directory.to_owned();
    let mut entered = false;
    let recording_failed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let recording_status = recording_failed.clone();
    let mut result = match tools
        .invoke_mapped_with_observed_admission(
            &prepared,
            cancel.clone(),
            move |value| {
                let normalized = (|| {
                    let mut output = retain_native_content(value, &budget)?;
                    if output.text.len() > 65_536 {
                        // Still inside the physical worker slot, including the
                        // malformed-UTF8 Bash preview's second retention layer.
                        output.text = retain_output(&retained_directory, &output.text)?;
                        output.content = None;
                    }
                    Ok(output)
                })();
                if normalized.is_err() {
                    recording_status.store(true, Ordering::Release);
                }
                normalized
            },
            admission,
            || entered = true,
        )
        .await
    {
        Ok(NativeOutput {
            text,
            content,
            is_error,
        }) => ToolResultRow {
            duration_us: None,
            text,
            content,
            outcome: if is_error {
                ToolOutcome::Failed
            } else {
                ToolOutcome::Completed
            },
        },
        Err(ToolError::NotExecuted(text)) => ToolResultRow::error(text, ToolOutcome::NotExecuted),
        Err(ToolError::Cancelled) => ToolResultRow::error(
            if tools.editing_call(call) {
                "Tool interrupted. Effects may already have occurred; inspect before retrying. No automatic replay."
            } else {
                "Tool interrupted. Its output is unknown. No automatic replay."
            },
            ToolOutcome::Unknown,
        ),
        Err(error) => {
            failed_tool_result_with_editing(error, cancel.is_cancelled(), tools.editing_call(call))
        }
    };
    if entered && !recording_failed.load(Ordering::Acquire) {
        result.duration_us = crate::tool_timing::DurationUs::since(started);
    }
    result
}

#[cfg(test)]
fn failed_tool_result(error: ToolError, cancelled: bool) -> ToolResultRow {
    failed_tool_result_with_editing(error, cancelled, false)
}

fn failed_tool_result_with_editing(
    error: ToolError,
    cancelled: bool,
    editing: bool,
) -> ToolResultRow {
    // Cancellation wins over a simultaneous synchronous native failure, just
    // as SessionTools checks Task.isCancelled before classifying its error.
    if cancelled {
        return ToolResultRow::error(
            if editing {
                "Tool interrupted. Effects may already have occurred; inspect before retrying. No automatic replay."
            } else {
                "Tool interrupted. Its output is unknown. No automatic replay."
            },
            ToolOutcome::Unknown,
        );
    }
    // Only the source's pre-effect rejection set can prove a begun mutation
    // failed without effects. Native filesystem/permission/retention failures
    // remain unknown, even if their localized error sounds definitive.
    let rejected = error.code().is_some_and(|code| {
        matches!(
            code,
            "tool_arguments"
                | "invalid_params"
                | "invalid_range"
                | "invalid_identity"
                | "tool_unavailable"
                | "read_only"
                | "edit_match"
                | "file_unavailable"
                | "not_regular_file"
                | "file_too_large"
                | "binary_file"
                | "missing_path"
                | "tool_output"
                | "missing_executable"
                | "tool_busy"
                | "process_spawn"
        )
    });
    let outcome = if editing && !rejected {
        ToolOutcome::Unknown
    } else {
        ToolOutcome::Failed
    };
    let text = match error {
        ToolError::Native { .. } => "Tool failed; inspect its effects before retrying.".to_owned(),
        other => other.to_string(),
    };
    ToolResultRow::error(text, outcome)
}

#[cfg(test)]
#[test]
fn native_tool_failure_uses_source_generic_text_and_failed_outcome() {
    let result = failed_tool_result(
        ToolError::Native {
            domain: "NSCocoaErrorDomain".into(),
            code: 2048,
            message: "localized regex details".into(),
        },
        false,
    );
    assert_eq!(
        result.text,
        "Tool failed; inspect its effects before retrying."
    );
    assert_eq!(result.outcome, ToolOutcome::Failed);
    let result = failed_tool_result(
        ToolError::Failure {
            code: "invalid_params",
            message: "Invalid pattern".into(),
        },
        false,
    );
    assert_eq!(result.text, "Invalid pattern");
    assert_eq!(result.outcome, ToolOutcome::Failed);
    let result = failed_tool_result(
        ToolError::Native {
            domain: "NSCocoaErrorDomain".into(),
            code: 2048,
            message: "localized regex details".into(),
        },
        true,
    );
    assert_eq!(result.outcome, ToolOutcome::Unknown);
    assert!(result.text.contains("No automatic replay"));
    assert!(!result.text.contains("localized regex"));
}

fn retain_output(directory: &Path, text: &str) -> crate::tools::ToolResult<String> {
    if text.len() > 16 * 1024 * 1024 {
        return Err(ToolError::Io(std::io::Error::other(
            "Tool result exceeds 16 MiB",
        )));
    }
    let mut dirs = fs::DirBuilder::new();
    dirs.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        dirs.mode(0o700);
    }
    dirs.create(directory)?;
    // Reject a substituted output directory rather than following its symlink.
    if fs::symlink_metadata(directory)?.file_type().is_symlink() {
        return Err(ToolError::Io(std::io::Error::other(
            "Tool output directory is a symbolic link",
        )));
    }
    let path = directory.join(format!("{}.txt", Uuid::new_v4()));
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&path)?;
    file.write_all(text.as_bytes())?;
    file.sync_all()?;
    fs::File::open(directory)?.sync_all()?;
    // Sync the new output directory entry before referencing a retained file.
    if let Some(parent) = directory.parent() {
        fs::File::open(parent)?.sync_all()?;
    }
    let mut end = 32768.min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    Ok(format!(
        "{}\n\n[Output truncated. Full output: {}]",
        &text[..end],
        path.display()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{SessionStore, session::WriteFault};
    use serde_json::json;

    pub(super) fn profile() -> Profile {
        serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture-model","baseUrl":"http://127.0.0.1:12345","contextWindow":32000,"maxOutputTokens":4096})).unwrap()
    }
    pub(super) fn reply() -> Reply {
        Reply {
            text: "Listing".into(),
            reasoning: String::new(),
            calls: vec![ToolCall {
                id: "call-one".into(),
                name: "ls".into(),
                arguments: json!({}),
            }],
            usage: Value::Null,
            status: "completed".into(),
            provider_items: vec![],
        }
    }
    pub(super) fn active_store(path: &Path) -> (SessionStore, String) {
        let mut store = SessionStore::open(path).unwrap();
        store
            .transact(|s| {
                s.submit(Submission::new("fixture".into(), Lane::FollowUp))?;
                s.start_next()?;
                Ok(())
            })
            .unwrap();
        let id = store.snapshot().active_reply.unwrap();
        (store, id)
    }
    pub(super) fn result() -> Vec<ToolResultRow> {
        vec![ToolResultRow {
            duration_us: None,
            text: "kept result".into(),
            outcome: ToolOutcome::Completed,
            content: None,
        }]
    }

    #[test]
    fn call_checkpoint_restart_preserves_calls_marks_unknown_and_never_reexecutes() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session.json");
        let (mut store, id) = active_store(&path);
        store
            .transact(|s| s.begin_tools(&id, &reply(), &profile()))
            .unwrap();
        let batch = store.snapshot();
        assert_eq!(batch.version, 9);
        assert_eq!(batch.state, RunState::Running);
        // Exact pre-integration v3 reader invariant. It rejects before the
        // existing open path's confirm/recover/write stages can run.
        assert!(!batch.messages.iter().any(|m| m.id == id
            && m.role == "assistant"
            && !m.replay_eligible
            && m.state == "streaming"));
        drop(store);
        let mut reopened = SessionStore::open(&path).unwrap();
        let recovered = reopened.snapshot();
        assert_eq!(recovered.state, RunState::Paused);
        assert!(recovered.queue_paused);
        assert!(recovered.messages[1].replay_eligible);
        assert!(
            matches!(recovered.messages[2].tool_record, Some(ToolRecord::Result(ref record)) if record.outcome == ToolOutcome::Unknown)
        );
        reopened
            .transact(|s| {
                s.retry_turn()?;
                Ok(())
            })
            .unwrap();
        let retried = reopened.snapshot();
        assert!(retried.active_tool_calls().is_none());
        let body =
            request_body_with_tools(&profile(), &retried.messages, "", &retried.id, &[]).unwrap();
        assert!(
            body["input"]
                .as_array()
                .unwrap()
                .iter()
                .find(|row| row["type"] == "function_call_output")
                .unwrap()["output"]
                .as_str()
                .unwrap()
                .contains("No automatic replay")
        );
        assert_eq!(
            retried
                .messages
                .iter()
                .filter(|m| m.role == "toolResult")
                .count(),
            1
        );
    }

    #[test]
    fn tool_result_checkpoint_failure_is_atomic_and_uncertain_reopen_never_duplicates_results() {
        for fault in [WriteFault::BeforeRename, WriteFault::AfterRename] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("session.json");
            let (mut store, id) = active_store(&path);
            store
                .transact(|s| s.begin_tools(&id, &reply(), &profile()))
                .unwrap();
            let before = fs::read(&path).unwrap();
            store.fault = fault;
            let outcome = store.transact(|s| s.settle_tools(&id, result(), false));
            assert!(outcome.is_err());
            assert_eq!(store.snapshot().messages.len(), 2);
            if matches!(fault, WriteFault::BeforeRename) {
                assert_eq!(fs::read(&path).unwrap(), before);
            } else {
                assert!(matches!(outcome, Err(Error::PersistenceUncertain(_))));
                assert!(
                    store
                        .transact(|s| s.settle_tools(&id, result(), false))
                        .is_err()
                );
            }
            drop(store);
            let mut reopened = SessionStore::open(&path).unwrap();
            let snapshot = reopened.snapshot();
            assert_eq!(snapshot.state, RunState::Paused);
            let results: Vec<_> = snapshot
                .messages
                .iter()
                .filter(|m| m.role == "toolResult")
                .collect();
            assert_eq!(results.len(), 1);
            if matches!(fault, WriteFault::AfterRename) {
                assert_eq!(results[0].text, "kept result");
            } else {
                assert!(results[0].text.contains("output is unknown"));
            }
            reopened
                .transact(|s| {
                    s.retry_turn()?;
                    Ok(())
                })
                .unwrap();
            assert!(reopened.snapshot().active_tool_calls().is_none());
        }
    }

    #[test]
    fn call_checkpoint_write_failure_keeps_no_accepted_execution_phase() {
        let dir = tempfile::tempdir().unwrap();
        let (mut store, id) = active_store(&dir.path().join("session.json"));
        store.fault = WriteFault::BeforeRename;
        assert!(
            store
                .transact(|s| s.begin_tools(&id, &reply(), &profile()))
                .is_err()
        );
        assert!(store.snapshot().active_tool_calls().is_none());
    }

    #[test]
    fn whole_batch_boundary_delivers_steering_only_when_edit_is_not_held() {
        for held in [false, true] {
            let mut s = Session::new();
            s.submit(Submission::new("initial".into(), Lane::FollowUp))
                .unwrap();
            s.start_next().unwrap();
            let id = s.active_reply.clone().unwrap();
            s.begin_tools(&id, &reply(), &profile()).unwrap();
            let following = Submission::new("following".into(), Lane::FollowUp);
            let steering = Submission::new("steering".into(), Lane::Steering);
            s.submit(following.clone()).unwrap();
            s.submit(steering.clone()).unwrap();
            if held {
                s.begin_edit(&following.id, "held-edit").unwrap();
            }
            s.settle_tools(&id, result(), false).unwrap();
            assert_eq!(s.pending.iter().any(|item| item.id == steering.id), held);
            assert!(s.pending.iter().any(|item| item.id == following.id));
            assert_eq!(
                s.active.as_ref().unwrap().text,
                if held { "initial" } else { "steering" }
            );
            let results = s
                .messages
                .iter()
                .position(|m| m.role == "toolResult")
                .unwrap();
            if !held {
                assert_eq!(s.messages[results + 1].id, steering.id);
            }
            assert!(s.active_tool_calls().is_none());
        }
    }

    #[test]
    fn retained_output_is_complete_private_and_utf8_preview_is_bounded() {
        let dir = tempfile::tempdir().unwrap();
        let output = dir.path().join("tool-output");
        let text = "😀".repeat(20000);
        let preview = retain_output(&output, &text).unwrap();
        assert!(preview.starts_with(&"😀".repeat(8192)));
        assert!(preview.contains("[Output truncated. Full output: "));
        let files: Vec<_> = fs::read_dir(&output)
            .unwrap()
            .map(|x| x.unwrap().path())
            .collect();
        assert_eq!(files.len(), 1);
        assert_eq!(fs::read_to_string(&files[0]).unwrap(), text);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&files[0]).unwrap().permissions().mode() & 0o777,
                0o600
            );
            assert_eq!(
                fs::metadata(&output).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
    }

    #[test]
    fn output_retention_failure_never_returns_a_false_full_output_reference() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("not-a-directory");
        fs::write(&file, "original").unwrap();
        assert!(retain_output(&file, &"x".repeat(70000)).is_err());
        assert_eq!(fs::read_to_string(file).unwrap(), "original");
        #[cfg(unix)]
        {
            let link = dir.path().join("linked-output");
            std::os::unix::fs::symlink(dir.path(), &link).unwrap();
            assert!(retain_output(&link, &"x".repeat(70000)).is_err());
        }
    }

    #[tokio::test]
    async fn cancellation_before_invocation_is_not_executed() {
        let directory = tempfile::tempdir().unwrap();
        let native = NativeTools::new(
            directory.path().to_owned(),
            [],
            directory.path().to_owned(),
            [Capability::Ls],
        )
        .unwrap()
        .before_read(Arc::new(|| panic!("pre-cancelled read must not enter")));
        let token = CancellationToken::new();
        token.cancel();
        let outcome = run_call(&native, &reply().calls[0], directory.path(), token).await;
        assert_eq!(outcome.outcome, ToolOutcome::NotExecuted);
        assert_eq!(outcome.text, "Not executed: cancelled before invocation");
    }

    #[tokio::test]
    async fn shutdown_awaits_an_entered_read_before_reporting_the_batch_settled() {
        joined_entered_read(false).await;
    }

    #[tokio::test]
    async fn retirement_joins_entered_read_for_concurrent_and_cancelled_waiters() {
        joined_entered_read(true).await;
    }

    async fn joined_entered_read(retire: bool) {
        use std::{
            io::{Read, Write},
            sync::{Condvar, Mutex},
            time::Duration,
        };
        struct Release(Arc<(Mutex<bool>, Condvar)>);
        impl Drop for Release {
            fn drop(&mut self) {
                *self.0.0.lock().unwrap() = true;
                self.0.1.notify_all();
            }
        }
        let dir = tempfile::tempdir().unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let mut profile = profile();
        profile.base_url = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut raw = vec![];
            loop {
                let mut chunk = [0; 4096];
                let count = socket.read(&mut chunk).unwrap();
                assert_ne!(count, 0);
                raw.extend_from_slice(&chunk[..count]);
                if let Some(end) = raw.windows(4).position(|part| part == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&raw[..end]).to_lowercase();
                    let length: usize = headers
                        .lines()
                        .find_map(|line| line.strip_prefix("content-length: "))
                        .unwrap()
                        .parse()
                        .unwrap();
                    if raw.len() >= end + 4 + length {
                        break;
                    }
                }
            }
            let body=json!({"status":"completed","output":[{"type":"function_call","call_id":"call-one","name":"ls","arguments":"{}"}]}).to_string();
            write!(socket,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
        });
        let barrier = Arc::new((Mutex::new(false), Condvar::new()));
        let release = Release(barrier.clone());
        let (entered, mut arrival) = tokio::sync::mpsc::unbounded_channel();
        let workers = BlockingWorkExecutor::new(1, 1);
        let mut trusted =
            TrustedReadOnlyTools::new(dir.path().to_owned(), vec![], dir.path().to_owned())
                .unwrap()
                .with_executor(workers.clone());
        trusted.native = trusted.native.before_read(Arc::new(move || {
            entered.send(()).unwrap();
            let (lock, signal) = &*barrier;
            let mut released = lock.lock().unwrap();
            while !*released {
                released = signal.wait(released).unwrap();
            }
        }));
        let control = Controller::new_with_options(
            SessionStore::open(dir.path().join("session.json")).unwrap(),
            Some((
                profile,
                crate::Credential::new("fixture-only".into()).unwrap(),
            )),
            RuntimeOptions {
                instructions: String::new(),
                tools: Some(trusted),
            },
        )
        .unwrap();
        control.submit("fixture".into(), Lane::FollowUp).unwrap();
        tokio::time::timeout(Duration::from_secs(5), arrival.recv())
            .await
            .unwrap()
            .unwrap();
        let path = dir.path().join("session.json");
        // Preserve queued/edit-held state while the entered syscall settles.
        let queued = Submission::new("queued after tool".into(), Lane::FollowUp);
        control.submit_identified(queued.clone()).unwrap();
        control.begin_edit(&queued.id, "tool-hold").unwrap();
        if retire {
            control.retire().unwrap();
            assert!(control.resume().is_err());
            assert!(control.retry().is_err());
            assert!(
                control
                    .cancel_edit_certain("tool-hold", &queued.id)
                    .is_err()
            );
            let mut abandoned = Box::pin(control.retire_and_wait());
            assert!(futures_util::poll!(&mut abandoned).is_pending());
            let mut second = Box::pin(control.retire_and_wait());
            assert!(futures_util::poll!(&mut second).is_pending());
            drop(abandoned);
            assert!(futures_util::poll!(&mut second).is_pending());
            assert_eq!(workers.occupancy().active, 1);
            assert_eq!(control.snapshot().state, RunState::Running);
            assert!(
                SessionStore::open(&path).is_err(),
                "entered read still owns storage"
            );
            assert!(
                control.inner.try_lock().is_ok(),
                "join must not hold actor lock"
            );
            assert!(
                control.worker.try_lock().is_ok(),
                "join must not hold handle lock"
            );
            drop(release);
            tokio::time::timeout(Duration::from_secs(5), second)
                .await
                .unwrap()
                .unwrap();
            let reopened = Controller::new(SessionStore::open(&path).unwrap(), None).unwrap();
            assert_eq!(reopened.snapshot().pending[0].id, queued.id);
            assert_eq!(
                reopened.snapshot().edit.as_ref().unwrap().edit_id,
                "tool-hold"
            );
            assert!(
                control
                    .submit("stale owner".into(), Lane::FollowUp)
                    .is_err()
            );
        } else {
            let mut shutdown = Box::pin(control.shutdown());
            // The real worker join must remain pending while the read is held.
            assert!(futures_util::poll!(&mut shutdown).is_pending());
            assert_eq!(workers.occupancy().active, 1);
            assert_eq!(control.snapshot().state, RunState::Running);
            drop(release);
            tokio::time::timeout(Duration::from_secs(5), shutdown)
                .await
                .unwrap()
                .unwrap();
            assert!(!control.is_retired());
            assert!(SessionStore::open(&path).is_err());
        }
        let snapshot = control.snapshot();
        assert_eq!(snapshot.state, RunState::Paused);
        assert!(snapshot.messages.iter().any(|row|matches!(&row.tool_record,Some(ToolRecord::Result(record)) if record.outcome==ToolOutcome::Unknown)));
        server.join().unwrap();
    }
}

#[cfg(test)]
#[test]
fn model_id_override_does_not_inherit_another_models_image_capability() {
    let profile: Profile = serde_json::from_value(serde_json::json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"image-fixture","baseUrl":"http://127.0.0.1:9","contextWindow":32000,"maxOutputTokens":4096,"input":["text","image"]})).unwrap();
    let mut item = Submission::new("fixture".into(), Lane::FollowUp);
    item.model = Some(profile.model_id.clone());
    assert!(effective_profile(&profile, Some(&item)).supports_images());
    item.model = Some("unknown-other-fixture".into());
    assert!(!effective_profile(&profile, Some(&item)).supports_images());
    assert!(profile.supports_images());
}

#[cfg(all(test, target_os = "macos"))]
#[path = "read_runtime_tests.rs"]
mod read_tests;

#[cfg(test)]
mod read_budget_tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn concurrent_content_reservation_bounds_completed_results_before_batch_settlement() {
        let value = json!({"content":[{"type":"text","text":"image note"},{"type":"image","mimeType":"image/png","data":"YWJj"}],"stats":{"path":"/fixture/image.png"},"isError":false});
        let bytes = crate::tool_content::ToolContent::from_native(&value)
            .unwrap()
            .encoded_len()
            .unwrap()
            + "image note".len();
        let budget = Arc::new(BatchContentBudget {
            used: AtomicUsize::new(0),
            maximum: bytes * 3,
        });
        let barrier = Arc::new(std::sync::Barrier::new(17));
        let results = std::thread::scope(|scope| {
            let workers = (0..16)
                .map(|_| {
                    let budget = budget.clone();
                    let barrier = barrier.clone();
                    let value = value.clone();
                    scope.spawn(move || {
                        barrier.wait();
                        retain_native_content(value, &budget)
                    })
                })
                .collect::<Vec<_>>();
            barrier.wait();
            workers
                .into_iter()
                .map(|worker| worker.join().unwrap())
                .collect::<Vec<_>>()
        });
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 3);
        assert_eq!(budget.used.load(Ordering::Acquire), bytes * 3);
        for error in results.into_iter().filter_map(|result| result.err()) {
            let row = failed_tool_result(error, false);
            assert_eq!(row.outcome, ToolOutcome::Failed);
            assert!(row.content.is_none());
            assert!(row.text.contains("32 MiB content limit"));
            assert!(row.text.contains("No automatic replay"));
        }
        // Charges live until the whole batch budget drops, not until a waiter
        // briefly releases its Arc or another native worker completes.
        assert_eq!(budget.used.load(Ordering::Acquire), bytes * 3);
        assert!(!budget.reserve(usize::MAX));
        assert!(!budget.reserve(1));
    }
    #[test]
    fn rejected_content_never_mutates_an_earlier_retained_result() {
        let value = json!({"content":[{"type":"text","text":"kept"}],"stats":{"path":"/fixture"}});
        let bytes = crate::tool_content::ToolContent::from_native(&value)
            .unwrap()
            .encoded_len()
            .unwrap()
            + 4;
        let budget = BatchContentBudget {
            used: AtomicUsize::new(0),
            maximum: bytes,
        };
        let first = retain_native_content(value.clone(), &budget).unwrap();
        let retained = serde_json::to_value(first.content.as_ref().unwrap()).unwrap();
        assert!(retain_native_content(value, &budget).is_err());
        assert_eq!(first.text, "kept");
        assert_eq!(
            serde_json::to_value(first.content.as_ref().unwrap()).unwrap(),
            retained
        );
    }
}

#[cfg(test)]
#[path = "edit_runtime_tests.rs"]
mod edit_runtime_tests;

#[cfg(all(test, unix))]
#[path = "bash_runtime_tests.rs"]
mod bash_tests;

#[cfg(test)]
#[path = "tool_concurrency_tests.rs"]
mod tool_concurrency_tests;

#[cfg(test)]
#[path = "tool_timing_runtime_tests.rs"]
mod timing_tests;
