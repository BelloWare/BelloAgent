//! Context rejection recovery stays inside the existing turn worker. Every
//! additional network admission is preceded by a durable consumed receipt.
use super::*;
use crate::{Error, compaction, provider_failure::Failure, session::same_submission};
use sha2::{Digest, Sha256};
use uuid::Uuid;

struct Binding {
    turn: Submission,
    reply_id: String,
    stop: u64,
    generation: u64,
    worker: Arc<()>,
    applied: Option<project_input_runtime::AppliedProjectResources>,
}

impl Controller {
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn recover_context_rejection(
        &self,
        configuration: &Arc<Configuration>,
        item: &Submission,
        snapshot: &Session,
        profile: &Profile,
        instructions: &str,
        definitions: &[crate::tools::ToolDefinition],
        failure: &Failure,
        cancel: CancellationToken,
    ) -> Result<Option<Session>> {
        if !failure.category.context_rejection() {
            return Ok(None);
        }
        // This legacy fixture constructor resolves resources differently. Keep
        // the existing explicit compaction refusal until equivalent binding is ported.
        #[cfg(feature = "synthetic-authority")]
        if self.resources.is_some() {
            return Ok(None);
        }
        let reply_id = snapshot
            .active_reply
            .as_deref()
            .ok_or_else(|| invalid("Missing rejected reply"))?;
        let binding = {
            let inner = self
                .inner
                .lock()
                .map_err(|_| invalid("Session is unavailable"))?;
            if !inner.store.snapshot_ref().can_recover_context(reply_id) {
                return Ok(None);
            }
            Binding {
                turn: item.clone(),
                reply_id: reply_id.into(),
                stop: self.stop_epoch.load(Ordering::Acquire),
                generation: self.suspension_generation.load(Ordering::Acquire),
                worker: inner.worker_epoch.clone(),
                applied: inner.applied_project.clone(),
            }
        };
        let request = crate::provider::request_body_with_tools(
            profile,
            &snapshot.messages,
            instructions,
            &snapshot.id,
            definitions,
        )?;
        let fingerprint = format!(
            "{:x}",
            Sha256::digest(crate::provider::serialize_request(&request)?)
        );
        let operation_id = Uuid::new_v4().to_string();
        #[cfg(test)]
        self.pause_input_commit_for_test("recovery-consume").await;
        {
            let mut inner = self
                .inner
                .lock()
                .map_err(|_| invalid("Session is unavailable"))?;
            self.check_recovery_binding(&inner, configuration, &binding, &cancel)?;
            inner.store.transact(|session| {
                session.begin_context_recovery(
                    &operation_id,
                    reply_id,
                    failure.clone(),
                    fingerprint,
                )
            })?;
            self.publish(&inner);
        }
        let mut observed = None;
        let partial = Mutex::new((String::new(), String::new()));
        let outcome = async {
            configuration.confirm_for_request().await?;
            self.confirm_runtime_authority(cancel.clone()).await?;
            let resources = self
                .prepare_project_snapshot(configuration, None, cancel.clone())
                .await?;
            self.confirm_dependency_snapshot(binding.applied.as_ref())?;
            let frozen = {
                let inner = self
                    .inner
                    .lock()
                    .map_err(|_| invalid("Session is unavailable"))?;
                self.check_recovery_binding(&inner, configuration, &binding, &cancel)?;
                inner.store.snapshot()
            };
            let preparation_profile = profile.clone();
            let preparation_instructions = instructions.to_owned();
            let preparation_definitions = definitions.to_vec();
            let preparation_id = operation_id.clone();
            let preparation_cancel = cancel.clone();
            let prepared = tokio::task::spawn_blocking(move || {
                compaction::prepare_recovery_checked(
                    &frozen.messages,
                    &preparation_profile,
                    &preparation_instructions,
                    &frozen.id,
                    &preparation_definitions,
                    &preparation_id,
                    || {
                        if preparation_cancel.is_cancelled() {
                            Err(Error::Cancelled)
                        } else {
                            Ok(())
                        }
                    },
                )
            })
            .await
            .map_err(|_| invalid("Recovery preparation worker failed"))??;
            configuration.confirm_for_request().await?;
            self.confirm_runtime_authority(cancel.clone()).await?;
            self.confirm_recovery_resources(
                configuration,
                &binding,
                resources.as_ref(),
                cancel.clone(),
            )
            .await?;
            {
                let mut inner = self
                    .inner
                    .lock()
                    .map_err(|_| invalid("Session is unavailable"))?;
                self.check_recovery_binding(&inner, configuration, &binding, &cancel)?;
                inner
                    .store
                    .transact(|session| session.mark_recovery_summarizing(&operation_id))?;
                self.publish(&inner);
            }
            let (candidate, reply) = self
                .summarize_prepared(
                    configuration,
                    &prepared,
                    profile,
                    instructions,
                    &snapshot.id,
                    definitions,
                    &format!("recovery:{operation_id}"),
                    cancel.clone(),
                    |delta| {
                        let mut partial = partial
                            .lock()
                            .map_err(|_| invalid("Summary observation is unavailable"))?;
                        match delta {
                            crate::Delta::Text(text) => partial.0.push_str(&text),
                            crate::Delta::Reasoning(text) => partial.1.push_str(&text),
                            crate::Delta::Tool { .. } => {}
                        }
                        Ok(())
                    },
                )
                .await;
            observed = reply;
            #[cfg(test)]
            self.pause_input_commit_for_test("recovery-summary-response")
                .await;
            let candidate = candidate?;
            #[cfg(test)]
            self.pause_input_commit_for_test("recovery-adopt").await;
            configuration.confirm_for_request().await?;
            self.confirm_runtime_authority(cancel.clone()).await?;
            self.confirm_recovery_resources(
                configuration,
                &binding,
                resources.as_ref(),
                cancel.clone(),
            )
            .await?;
            {
                let mut inner = self
                    .inner
                    .lock()
                    .map_err(|_| invalid("Session is unavailable"))?;
                self.check_recovery_binding(&inner, configuration, &binding, &cancel)?;
                inner.store.transact(|session| {
                    session.adopt_recovery_checkpoint(
                        &operation_id,
                        candidate,
                        observed
                            .as_ref()
                            .expect("validated summary has terminal reply"),
                    )
                })?;
                self.publish(&inner);
            }
            // Reuse ordinary input preparation for one captured steering item.
            // Follow-ups and held edits remain untouched; later arrivals cannot
            // substitute themselves after preparation.
            let steering = {
                let inner = self
                    .inner
                    .lock()
                    .map_err(|_| invalid("Session is unavailable"))?;
                attachment_runtime::steering_candidate(inner.store.snapshot_ref()).cloned()
            };
            let prepared_input = if let Some(steering) = &steering {
                let resources = self
                    .prepare_delivery_resources(steering, configuration, false, cancel.clone())
                    .await?;
                let content = self
                    .prepare_user_input(steering, configuration, cancel.clone(), false)
                    .await?;
                self.confirm_dependency_snapshot(resources.as_ref())?;
                Some((content, resources))
            } else {
                None
            };
            configuration.confirm_for_request().await?;
            self.confirm_runtime_authority(cancel.clone()).await?;
            self.confirm_recovery_resources(
                configuration,
                &binding,
                resources.as_ref(),
                cancel.clone(),
            )
            .await?;
            #[cfg(test)]
            self.pause_input_commit_for_test("recovery-retry").await;
            let mut inner = self
                .inner
                .lock()
                .map_err(|_| invalid("Session is unavailable"))?;
            self.check_recovery_binding(&inner, configuration, &binding, &cancel)?;
            let selected = steering.as_ref().filter(|captured| {
                attachment_runtime::steering_candidate(inner.store.snapshot_ref())
                    .is_some_and(|current| same_submission(captured, current))
            });
            let (content, applied) = prepared_input.unwrap_or((None, None));
            if selected.is_some()
                && applied
                    .as_ref()
                    .is_some_and(|value| !self.project_skills_catalog_current(&value.snapshot))
            {
                return Err(invalid("Steering resources changed before recovery retry"));
            }
            inner.store.transact(|session| {
                if selected.is_some() {
                    session.begin_recovery_retry_with_steering(
                        &operation_id,
                        selected.map(|item| item.id.as_str()),
                        content,
                    )?;
                } else {
                    session.begin_recovery_retry(&operation_id)?;
                }
                let active = session
                    .active
                    .as_ref()
                    .ok_or_else(|| invalid("Missing recovery retry"))?;
                self.validate_recovery_request(
                    active,
                    session,
                    configuration,
                    applied.as_ref().filter(|_| selected.is_some()),
                    instructions,
                    definitions,
                )?;
                Ok(())
            })?;
            if selected.is_some() {
                inner.applied_project = applied;
            }
            self.publish(&inner);
            Ok(inner.store.snapshot())
        }
        .await;
        match outcome {
            Ok(snapshot) => Ok(Some(snapshot)),
            Err(error) => {
                let cancelled =
                    cancel.is_cancelled() || self.is_retired() || matches!(error, Error::Cancelled);
                let mut inner = self
                    .inner
                    .lock()
                    .map_err(|_| invalid("Session is unavailable"))?;
                // A failed/uncertain write cannot be repaired by an extra mutation.
                if let Err(write_error) = inner.store.require_certain() {
                    inner.fatal = Some(write_error.to_string());
                    return Err(write_error);
                }
                if let Err(write_error) = inner.store.transact(|session| {
                    session.fail_context_recovery(&operation_id, &error, observed.as_ref())?;
                    if cancelled {
                        let receipt = session
                            .context_recoveries
                            .iter_mut()
                            .find(|receipt| receipt.id == operation_id)
                            .expect("owned recovery");
                        receipt.phase = crate::context_recovery::Phase::Cancelled;
                        if let Some(row) = session
                            .messages
                            .iter_mut()
                            .find(|row| row.id == receipt.progress_id)
                        {
                            row.state = "context-recovery-cancelled".into();
                        }
                    }
                    if observed.is_none() {
                        let progress_id = session
                            .context_recoveries
                            .iter()
                            .find(|receipt| receipt.id == operation_id)
                            .map(|receipt| receipt.progress_id.clone());
                        if let Some(row) = session
                            .messages
                            .iter_mut()
                            .find(|row| Some(&row.id) == progress_id.as_ref())
                        {
                            let partial = partial
                                .lock()
                                .map_err(|_| invalid("Summary observation is unavailable"))?;
                            row.text = partial.0.clone();
                            row.reasoning = partial.1.clone();
                        }
                    }
                    Ok(())
                }) {
                    inner.fatal = Some(write_error.to_string());
                    return Err(write_error);
                }
                self.publish(&inner);
                if cancelled {
                    Err(Error::Cancelled)
                } else {
                    Err(invalid(format!(
                        "{}; context recovery stopped: {error}",
                        failure.message
                    )))
                }
            }
        }
    }

    fn check_recovery_binding(
        &self,
        inner: &Inner,
        configuration: &Arc<Configuration>,
        binding: &Binding,
        cancel: &CancellationToken,
    ) -> Result<()> {
        if cancel.is_cancelled()
            || self.is_retired()
            || self.stop_requested.load(Ordering::Acquire)
            || binding.stop != self.stop_epoch.load(Ordering::Acquire)
            || binding.generation != self.suspension_generation.load(Ordering::Acquire)
        {
            return Err(Error::Cancelled);
        }
        self.require_admission()?;
        inner.store.require_certain()?;
        if inner.fatal.is_some()
            || inner.pending_configuration.is_some()
            || !Arc::ptr_eq(&inner.worker_epoch, &binding.worker)
            || !self
                .configuration()
                .is_some_and(|current| Arc::ptr_eq(&current, configuration))
            || inner.store.snapshot_ref().active_reply.as_deref() != Some(&binding.reply_id)
            || !inner
                .store
                .snapshot_ref()
                .active
                .as_ref()
                .is_some_and(|item| same_submission(item, &binding.turn))
            || inner
                .applied_project
                .as_ref()
                .map(|value| (&value.turn_id, &value.snapshot.revision))
                != binding
                    .applied
                    .as_ref()
                    .map(|value| (&value.turn_id, &value.snapshot.revision))
        {
            return Err(invalid(
                "Session or connection changed during context recovery",
            ));
        }
        Ok(())
    }

    async fn confirm_recovery_resources(
        &self,
        configuration: &Arc<Configuration>,
        binding: &Binding,
        original: Option<&Arc<crate::project_resources::ProjectResourceSnapshot>>,
        cancel: CancellationToken,
    ) -> Result<()> {
        self.confirm_dependency_snapshot(binding.applied.as_ref())?;
        if let Some(original) = original {
            let current = self
                .prepare_project_snapshot(configuration, None, cancel)
                .await?
                .ok_or_else(|| invalid("Project resources became unavailable during recovery"))?;
            if current.revision != original.revision
                || current.scope != original.scope
                || current.dependencies != original.dependencies
                || !self.project_skills_catalog_current(original)
            {
                return Err(invalid("Project resources changed during context recovery"));
            }
        }
        Ok(())
    }

    fn validate_recovery_request(
        &self,
        item: &Submission,
        session: &Session,
        configuration: &Configuration,
        applied: Option<&project_input_runtime::AppliedProjectResources>,
        previous_instructions: &str,
        definitions: &[crate::tools::ToolDefinition],
    ) -> Result<()> {
        let profile = tool_runtime::effective_profile(&configuration.profile, Some(item));
        let instructions = applied
            .map(|value| value.instructions.as_str())
            .unwrap_or(previous_instructions);
        let body = crate::provider::request_body_with_tools(
            &profile,
            &session.messages,
            instructions,
            &session.id,
            definitions,
        )?;
        crate::provider::serialize_request(&body)?;
        Ok(())
    }
}

#[cfg(test)]
#[path = "context_recovery_runtime_tests.rs"]
mod tests;
