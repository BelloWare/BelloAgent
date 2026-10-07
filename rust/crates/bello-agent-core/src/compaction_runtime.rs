//! Serialized manual-compaction lifecycle. The worker is registered with the
//! ordinary session join owner before admission returns; shutdown never detaches it.
use super::*;
use crate::compaction::{self, Phase};
use uuid::Uuid;

impl Controller {
    /// Stop any active turn, retain its partial response, then compact its stable
    /// replay path. Follow-ups/held edits stay owned by the existing queue.
    pub fn compact(self: &Arc<Self>, focus: Option<&str>) -> Result<()> {
        let focus = compaction::focus(focus)?;
        #[cfg(feature = "synthetic-authority")]
        if self.resources.is_some() {
            return Err(invalid(
                "Manual compaction is not yet available for synthetic dynamic-resource runtimes",
            ));
        }
        let confirmed = self.confirm_resources()?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        self.require_confirmed_admission(&inner, &confirmed)?;
        inner.store.require_certain()?;
        if let Some(error) = &inner.fatal {
            return Err(invalid(error.clone()));
        }
        if inner.compaction_pending
            || inner
                .store
                .snapshot_ref()
                .compaction
                .as_ref()
                .is_some_and(|operation| operation.is_running())
        {
            return Err(invalid("A compaction is already active"));
        }
        let configuration = self
            .configuration()
            .ok_or_else(|| invalid("No connection configured"))?;
        configuration.profile.validate()?;
        let release_queue = inner.worker_running && !inner.store.snapshot_ref().queue_paused;
        // This own Stop is distinguished from any later user Stop, including
        // one while the previous worker is still winding down.
        let stop_epoch = self.stop_with_epoch()?;
        inner.compaction_pending = true;
        self.worker_active.store(true, Ordering::Release);
        let mut worker = self
            .worker
            .lock()
            .map_err(|_| invalid("Worker is unavailable"))?;
        let predecessor = worker.take().map(|previous| {
            let id = previous.id();
            let joined = async move {
                previous
                    .await
                    .map_err(|_| "Session worker terminated unexpectedly".to_owned())
            }
            .boxed()
            .shared();
            self.worker_joins
                .lock()
                .expect("worker joins lock poisoned")
                .push((id, joined.clone()));
            joined
        });
        let this = self.clone();
        *worker = Some(self.runtime.spawn(async move {
            if let Some(predecessor) = predecessor
                && let Err(error) = predecessor.await
            {
                let mut inner = this.inner.lock().expect("session mutex poisoned");
                inner.fatal = Some(error);
                inner.compaction_pending = false;
                this.worker_finished(&mut inner);
                this.publish(&inner);
                return;
            }
            this.run_compaction(configuration, focus, release_queue, stop_epoch)
                .await;
        }));
        Ok(())
    }

    async fn run_compaction(
        self: Arc<Self>,
        configuration: Arc<Configuration>,
        focus: Option<String>,
        release_queue: bool,
        stop_epoch: u64,
    ) {
        let operation_id = Uuid::new_v4().to_string();
        let started = {
            let mut inner = self.inner.lock().expect("session mutex poisoned");
            // Consume only the winding-down worker's flag before checking the
            // monotonic Stop identity. A later Stop is checked again after the
            // new cancellation token has been installed.
            self.stop_requested.store(false, Ordering::Release);
            let admitted = self.require_admission().and_then(|()| {
                if self.stop_epoch.load(Ordering::Acquire) != stop_epoch { return Err(crate::Error::Cancelled); }
                if inner.fatal.is_some() || !self.configuration().as_ref().is_some_and(|current| Arc::ptr_eq(current, &configuration)) { return Err(invalid("The session or connection changed before compaction; original context is unchanged")); }
                inner.store.require_certain()
            });
            let result = admitted.and_then(|()| {
                inner.store.transact(|session| {
                    session.begin_compaction(&operation_id, &configuration.profile, release_queue)
                })
            });
            inner.compaction_pending = false;
            match result {
                Ok(reply_id) => {
                    inner.worker_running = true;
                    inner.worker_epoch = Arc::new(());
                    self.worker_active.store(true, Ordering::Release);
                    let cancel = CancellationToken::new();
                    inner.cancel = Some(cancel.clone());
                    *self
                        .active_cancel
                        .write()
                        .expect("cancellation lock poisoned") = Some(cancel.clone());
                    if self.stop_epoch.load(Ordering::Acquire) != stop_epoch || self.is_retired() {
                        cancel.cancel();
                    }
                    let snapshot = inner.store.snapshot();
                    self.publish(&inner);
                    Some((reply_id, snapshot, cancel))
                }
                Err(error) => {
                    if inner.store.snapshot_ref().active.is_some() || inner.store.snapshot_ref().active_reply.is_some() {
                        // Never write an inactive state while a foreign active
                        // reply remains. Preserve a recoverable checkpoint.
                        inner.fatal = Some(error.to_string());
                    } else if let Err(write_error) = inner.store.transact(|session| {
                        session.queue_paused = true;
                        session.state = if matches!(error, crate::Error::Cancelled) { RunState::Paused } else { RunState::Error };
                        session.error = Some(if matches!(error, crate::Error::Cancelled) {
                            "Compaction cancelled before its summary request. Original context and queued input are retained.".into()
                        } else { error.to_string() });
                        Ok(())
                    }) { inner.fatal = Some(write_error.to_string()); }
                    self.worker_finished(&mut inner);
                    self.stop_requested.store(false, Ordering::Release);
                    self.publish(&inner);
                    None
                }
            }
        };
        let Some((reply_id, snapshot, cancel)) = started else {
            return;
        };
        let instructions = self.options.instructions.clone();
        let definitions = self.options.definitions();
        let preparation_profile = configuration.profile.clone();
        let preparation_instructions = instructions.clone();
        let preparation_definitions = definitions.clone();
        let preparation_id = operation_id.clone();
        let session_id = snapshot.id.clone();
        let preparation_cancel = cancel.clone();
        let prepared = tokio::task::spawn_blocking(move || {
            compaction::prepare_checked(
                &snapshot.messages,
                &preparation_profile,
                &preparation_instructions,
                &snapshot.id,
                &preparation_definitions,
                &preparation_id,
                focus.as_deref(),
                || {
                    if preparation_cancel.is_cancelled() {
                        Err(crate::Error::Cancelled)
                    } else {
                        Ok(())
                    }
                },
            )
        })
        .await
        .map_err(|_| invalid("Compaction preparation worker failed"))
        .and_then(|result| result);
        let mut observed_reply = None;
        let outcome = async {
            let prepared = prepared?;
            if cancel.is_cancelled() {
                return Err(crate::Error::Cancelled);
            }
            configuration.confirm_for_request().await?;
            {
                let mut inner = self
                    .inner
                    .lock()
                    .map_err(|_| invalid("Session is unavailable"))?;
                self.check_compaction_binding(&inner, &configuration, &operation_id, &cancel)?;
                inner.store.transact(|session| {
                    let operation = session
                        .compaction
                        .as_mut()
                        .ok_or_else(|| invalid("Missing compaction operation"))?;
                    operation.phase = Phase::Summarizing;
                    operation.summary_output_allowance = prepared.profile.max_output_tokens;
                    operation.http_attempts = 1;
                    Ok(())
                })?;
                self.publish(&inner);
            }
            let reply = self
                .client
                .complete_prepared(
                    &prepared.profile,
                    &configuration.credential,
                    &prepared.request,
                    &session_id,
                    &format!("compaction:{operation_id}"),
                    cancel.clone(),
                    |delta| self.stream_delta(&reply_id, delta),
                )
                .await?;
            observed_reply = Some(reply.clone());
            let summary_id = Uuid::new_v4().to_string();
            let candidate = compaction::validate_candidate(
                &prepared,
                summary_id,
                &reply,
                &configuration.profile,
                &instructions,
                &session_id,
                &definitions,
            )?;
            configuration.confirm_for_request().await?;
            let mut inner = self
                .inner
                .lock()
                .map_err(|_| invalid("Session is unavailable"))?;
            self.check_compaction_binding(&inner, &configuration, &operation_id, &cancel)?;
            inner
                .store
                .transact(|session| session.adopt_compaction(&operation_id, candidate, &reply))?;
            self.publish(&inner);
            Ok::<(), crate::Error>(())
        }
        .await;
        let mut inner = self.inner.lock().expect("session mutex poisoned");
        if let Err(error) = outcome
            && let Err(write_error) = inner.store.transact(|session| {
                session.fail_compaction(&operation_id, error, observed_reply.as_ref())
            })
        {
            inner.fatal = Some(write_error.to_string());
        }
        let stopped = self.stop_requested.swap(false, Ordering::AcqRel);
        if stopped
            && inner.fatal.is_none()
            && inner.store.snapshot_ref().state == RunState::Idle
            && let Err(error) = inner.store.transact(|session| {
                session.queue_paused = true;
                session.state = RunState::Paused;
                Ok(())
            })
        {
            inner.fatal = Some(error.to_string());
        }
        self.worker_finished(&mut inner);
        self.publish(&inner);
        if !self.is_retired() && !stopped && inner.fatal.is_none() {
            self.launch(&mut inner, None);
        }
    }

    fn check_compaction_binding(
        &self,
        inner: &Inner,
        configuration: &Arc<Configuration>,
        operation_id: &str,
        cancel: &CancellationToken,
    ) -> Result<()> {
        if cancel.is_cancelled() || self.is_retired() {
            return Err(crate::Error::Cancelled);
        }
        self.require_admission()?;
        inner.store.require_certain()?;
        if inner.fatal.is_some()
            || inner.pending_configuration.is_some()
            || !self
                .configuration()
                .as_ref()
                .is_some_and(|current| Arc::ptr_eq(current, configuration))
            || !inner
                .store
                .snapshot_ref()
                .compaction
                .as_ref()
                .is_some_and(|operation| operation.id == operation_id && operation.is_running())
        {
            return Err(invalid(
                "Context or configuration changed while summarizing; original context is retained",
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "compaction_runtime_tests.rs"]
mod tests;
