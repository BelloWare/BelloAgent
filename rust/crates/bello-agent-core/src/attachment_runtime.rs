//! Out-of-actor preparation for actual user image admission and delivery.
use super::{Configuration, Controller, Inner};
use crate::{
    Error, Lane, Result, RunState, Session, Submission, invalid,
    session::{PreparedUserInput, same_submission},
    user_content::UserContent,
};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicU64, Ordering},
};
use tokio_util::sync::CancellationToken;

/// The guard is owned by the actual file closure, not only its awaiter. Dropping
/// a caller cancels queued work but cannot pretend a running native call joined.
#[derive(Default)]
pub(super) struct AttachmentJobs {
    next: AtomicU64,
    pending: Mutex<std::collections::BTreeMap<u64, CancellationToken>>,
    released: tokio::sync::Notify,
}
struct AttachmentJob {
    owner: Arc<AttachmentJobs>,
    id: u64,
}
impl AttachmentJobs {
    fn register(self: &Arc<Self>, token: CancellationToken) -> Result<AttachmentJob> {
        let mut id = self.next.load(Ordering::Acquire);
        loop {
            let next = id
                .checked_add(1)
                .ok_or_else(|| invalid("Image worker identity exhausted"))?;
            match self
                .next
                .compare_exchange_weak(id, next, Ordering::AcqRel, Ordering::Acquire)
            {
                Ok(_) => break,
                Err(current) => id = current,
            }
        }
        self.pending
            .lock()
            .map_err(|_| invalid("Image workers unavailable"))?
            .insert(id, token);
        Ok(AttachmentJob {
            owner: self.clone(),
            id,
        })
    }
    pub(super) fn cancel(&self) {
        if let Ok(pending) = self.pending.lock() {
            for token in pending.values() {
                token.cancel();
            }
        }
    }
    pub(super) async fn join(&self) -> Result<()> {
        loop {
            let released = self.released.notified();
            tokio::pin!(released);
            released.as_mut().enable();
            if self
                .pending
                .lock()
                .map_err(|_| invalid("Image worker ownership is unavailable"))?
                .is_empty()
            {
                return Ok(());
            }
            released.await;
        }
    }
}
impl Drop for AttachmentJob {
    fn drop(&mut self) {
        if let Ok(mut pending) = self.owner.pending.lock() {
            pending.remove(&self.id);
        }
        self.owner.released.notify_waiters();
    }
}

pub(super) fn pending_candidate(session: &Session) -> Option<&Submission> {
    if session.state == RunState::Running || session.queue_paused || session.edit.is_some() {
        return None;
    }
    session
        .pending
        .iter()
        .find(|item| item.lane == Lane::Steering)
        .or_else(|| session.pending.first())
}
pub(super) fn steering_candidate(session: &Session) -> Option<&Submission> {
    if session.queue_paused || session.edit.is_some() {
        return None;
    }
    session
        .pending
        .iter()
        .find(|item| item.lane == Lane::Steering)
}

impl Controller {
    /// Certain acceptance evidence, never a cached presentation snapshot. A
    /// same-ID conflict is not absence and must not authorize another Send.
    pub fn submission_intent_status(
        &self,
        intent: &crate::workspace::SubmissionIntent,
    ) -> Result<bool> {
        let inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        if self.is_retired() {
            return Err(invalid("This session controller is permanently retired"));
        }
        if let Some(error) = &inner.fatal {
            return Err(invalid(error.clone()));
        }
        inner.store.require_certain()?;
        let session = inner.store.snapshot_ref();
        if intent.chat_id != session.id || uuid::Uuid::parse_str(&intent.id).is_err() {
            return Err(invalid(
                "Submission receipt belongs to another chat or has invalid identity",
            ));
        }
        crate::session::validate_input(&intent.text, &intent.attachments)?;
        let mut found = false;
        for row in session.messages.iter().filter(|row| row.id == intent.id) {
            let attachments = row
                .user_content
                .as_ref()
                .map(|content| content.attachments.as_slice())
                .unwrap_or(&[]);
            if row.role != "user" || row.text != intent.text || attachments != intent.attachments {
                return Err(invalid(
                    "Accepted submission conflicts with its recovery receipt; review before sending again",
                ));
            }
            found = true;
        }
        for item in session
            .pending
            .iter()
            .chain(session.active.iter())
            .chain(session.retry.iter())
            .filter(|item| item.id == intent.id)
        {
            if item.text != intent.text || item.attachments != intent.attachments {
                return Err(invalid(
                    "Accepted submission conflicts with its recovery receipt; review before sending again",
                ));
            }
            found = true;
        }
        Ok(found)
    }
    pub fn supports_image_attachments(&self) -> bool {
        !self.is_retired()
            && self
                .configuration()
                .is_some_and(|config| config.profile.supports_images())
    }
    fn use_fixture_images(&self, config: &Configuration) -> bool {
        #[cfg(all(not(target_os = "macos"), any(test, feature = "synthetic-authority")))]
        {
            let fixture = config
                .connection
                .as_ref()
                .is_some_and(|lease| lease.is_fixture());
            #[cfg(test)]
            let fixture = fixture || self.fixture_images.load(Ordering::Acquire);
            fixture
                && config.profile.endpoint().ok().is_some_and(|url| {
                    matches!(url.host(), Some(url::Host::Ipv4(ip)) if ip.is_loopback())
                        || matches!(url.host(), Some(url::Host::Ipv6(ip)) if ip.is_loopback())
                })
        }
        #[cfg(any(target_os = "macos", not(any(test, feature = "synthetic-authority"))))]
        {
            let _ = config;
            false
        }
    }
    pub(super) async fn prepare_user_input(
        &self,
        item: &Submission,
        config: &Arc<Configuration>,
        cancel: CancellationToken,
        acceptance: bool,
    ) -> Result<Option<PreparedUserInput>> {
        crate::session::validate_submission(item)?;
        if item.attachments.is_empty() {
            return Ok(None);
        }
        let profile = super::tool_runtime::effective_profile(&config.profile, Some(item));
        if !profile.supports_images() {
            return Err(invalid(crate::attachments::IMAGES_UNSUPPORTED));
        }
        let fixture = self.use_fixture_images(config);
        #[cfg(test)]
        let barrier = self
            .attachment_processor_barrier
            .lock()
            .map_err(|_| invalid("Image fixture barrier unavailable"))?
            .clone();
        let captured = item.clone();
        let lease = {
            let _inner = self
                .inner
                .lock()
                .map_err(|_| invalid("Session is unavailable"))?;
            self.require_admission()?;
            self.attachment_jobs.register(cancel.clone())?
        };
        let prepared = self
            .attachment_workers
            .run(cancel, move |token| {
                let _lease = lease;
                let result = (|| {
                    let blocks = crate::attachments::load(
                        &captured.attachments,
                        &token,
                        |bytes, mime, token| {
                            #[cfg(test)]
                            if let Some(barrier) = &barrier {
                                barrier();
                            }
                            #[cfg(any(test, feature = "synthetic-authority"))]
                            if fixture {
                                return crate::tools::attachment_images::generated_fixture(
                                    bytes, mime, token,
                                );
                            }
                            let _ = fixture;
                            crate::tools::attachment_images::process(bytes, mime, token)
                        },
                    )?;
                    let content =
                        UserContent::new(&captured.text, captured.attachments.clone(), blocks)?;
                    if acceptance && content.image_count() != captured.attachments.len() {
                        return Err(invalid(
                            "An image could not be prepared for the model; select another",
                        ));
                    }
                    Ok(PreparedUserInput {
                        item: captured,
                        content: Arc::new(content),
                    })
                })();
                Ok(result)
            })
            .await
            .map_err(|error| match error {
                crate::tools::ToolError::Cancelled => Error::Cancelled,
                _ => invalid(error.to_string()),
            })??;
        Ok(Some(prepared))
    }
    /// The caller's background future may be dropped safely: no acceptance takes
    /// place until every file worker has returned and actor admission is rechecked.
    pub async fn submit_identified_with_attachments(
        self: &Arc<Self>,
        mut item: Submission,
    ) -> Result<()> {
        if item.attachments.is_empty() {
            return self.submit_identified(item);
        }
        let stop = self.stop_epoch.load(Ordering::Acquire);
        let generation = self.suspension_generation.load(Ordering::Acquire);
        let confirmed = self.confirm_resources()?;
        let config = confirmed
            .configuration
            .clone()
            .ok_or_else(|| invalid("No connection configured"))?;
        item.model = Some(config.profile.model_id.clone());
        item.effort = Some(config.profile.thinking_level.clone());
        self.prepare_user_input(&item, &config, CancellationToken::new(), true)
            .await?;
        // Native preparation can outlive a vault/catalog change. Repeat full
        // confirmation outside the actor, then bind both captured generations.
        let reconfirmed = self.confirm_resources()?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        self.require_confirmed_admission(&inner, &confirmed)?;
        self.require_confirmed_admission(&inner, &reconfirmed)?;
        if stop != self.stop_epoch.load(Ordering::Acquire)
            || generation != self.suspension_generation.load(Ordering::Acquire)
        {
            return Err(invalid(
                "Chat admission changed during image preparation; your input was not accepted",
            ));
        }
        if let Some(error) = &inner.fatal {
            return Err(invalid(error.clone()));
        }
        inner.store.require_certain()?;
        if self.authority.is_some() && !inner.store.is_persistent() {
            return Err(invalid("Materialize this saved chat before sending"));
        }
        inner.store.transact(|session| session.submit(item))?;
        self.publish(&inner);
        self.launch(&mut inner, None);
        Ok(())
    }
    pub(super) async fn run_with_images(self: Arc<Self>, mut first: Option<Submission>) {
        loop {
            let captured = {
                let mut inner = self.inner.lock().expect("session mutex poisoned");
                if first.is_none() && self.settle_empty_completed_tail(&mut inner) {
                    return;
                }
                if self.is_retired() || self.stop_requested.load(Ordering::Acquire) {
                    self.image_delivery_failure(&mut inner, Error::Cancelled);
                    return;
                }
                let session = inner.store.snapshot_ref();
                let selected = if let Some(retry) = &first {
                    session
                        .active
                        .as_ref()
                        .filter(|item| same_submission(item, retry))
                } else {
                    pending_candidate(session)
                };
                let Some(candidate) = selected.cloned() else {
                    self.worker_finished(&mut inner);
                    self.publish(&inner);
                    return;
                };
                let config = self.configuration().expect("configured");
                let generation = self.suspension_generation.load(Ordering::Acquire);
                let stop = self.stop_epoch.load(Ordering::Acquire);
                let cancel = self.register_image_cancel(&mut inner);
                (candidate, config, generation, stop, cancel)
            };
            let (candidate, config, generation, stop, cancel) = captured;
            let prepared = async {
                let content = if first.is_none() {
                    self.prepare_user_input(&candidate, &config, cancel.clone(), false)
                        .await?
                } else {
                    None
                };
                config.confirm_for_request().await?;
                self.confirm_runtime_authority(cancel.clone()).await?;
                Ok(content)
            }
            .await;
            let admitted = {
                let mut inner = self.inner.lock().expect("session mutex poisoned");
                let changed = generation != self.suspension_generation.load(Ordering::Acquire)
                    || stop != self.stop_epoch.load(Ordering::Acquire)
                    || !self
                        .configuration()
                        .is_some_and(|current| Arc::ptr_eq(&current, &config));
                if self.is_retired()
                    || cancel.is_cancelled()
                    || changed
                    || self.stop_requested.load(Ordering::Acquire)
                {
                    self.image_delivery_failure(&mut inner, Error::Cancelled);
                    return;
                }
                if let Err(error) = self.require_admission() {
                    self.image_delivery_failure(&mut inner, error);
                    return;
                }
                let selected = if first.is_some() {
                    inner.store.snapshot_ref().active.as_ref()
                } else {
                    pending_candidate(inner.store.snapshot_ref())
                };
                if !selected.is_some_and(|current| same_submission(current, &candidate)) {
                    continue;
                }
                let prepared = match prepared {
                    Ok(content) => content,
                    Err(error) => {
                        self.image_delivery_failure(&mut inner, error);
                        return;
                    }
                };
                let next = if let Some(item) = first.take() {
                    Ok(Some(item))
                } else {
                    inner
                        .store
                        .transact(|session| session.start_next_with_content(prepared))
                };
                match next {
                    Ok(Some(item)) => {
                        self.publish(&inner);
                        Some((item, inner.store.snapshot()))
                    }
                    Ok(None) => {
                        self.worker_finished(&mut inner);
                        self.publish(&inner);
                        None
                    }
                    Err(error) => {
                        inner.fatal = Some(error.to_string());
                        self.worker_finished(&mut inner);
                        self.publish(&inner);
                        None
                    }
                }
            };
            let Some((item, session)) = admitted else {
                return;
            };
            self.run_turn(item, session, cancel).await;
            {
                let mut inner = self.inner.lock().expect("session mutex poisoned");
                inner.cancel = None;
                self.publish(&inner);
                if inner.fatal.is_some()
                    || self.is_retired()
                    || inner.store.snapshot_ref().state != RunState::Idle
                {
                    self.worker_finished(&mut inner);
                    self.stop_requested.store(false, Ordering::Release);
                    return;
                }
            }
            #[cfg(all(test, feature = "synthetic-authority"))]
            super::worker_tail_test_gate::pause(&self).await;
        }
    }
    pub(super) fn register_image_cancel(&self, inner: &mut Inner) -> CancellationToken {
        let cancel = CancellationToken::new();
        inner.cancel = Some(cancel.clone());
        *self
            .active_cancel
            .write()
            .expect("cancellation lock poisoned") = Some(cancel.clone());
        cancel
    }
    pub(super) fn image_delivery_failure(&self, inner: &mut Inner, error: Error) {
        if let Err(error) = inner.store.transact(|session| {
            if let Some(reply) = session.active_reply.clone() {
                return session.finish(&reply, Err(error));
            }
            session.queue_paused = true;
            session.state = if matches!(error, Error::Cancelled) {
                RunState::Paused
            } else {
                RunState::Error
            };
            session.error = Some(error.to_string());
            Ok(())
        }) {
            inner.fatal = Some(error.to_string());
        }
        self.worker_finished(inner);
        self.stop_requested.store(false, Ordering::Release);
        self.publish(inner);
    }
    /// Completed tool results are durable even when a steering image no longer
    /// loads. That input stays queued; no later item is substituted implicitly.
    pub(super) async fn settle_image_tools(
        &self,
        reply: &str,
        results: Vec<super::tool_runtime::ToolResultRow>,
        cancel: CancellationToken,
    ) -> Option<(Submission, Session)> {
        let (candidate, config, generation, stop) = {
            let inner = self.inner.lock().expect("session mutex poisoned");
            (
                steering_candidate(inner.store.snapshot_ref()).cloned(),
                self.configuration().expect("configured"),
                self.suspension_generation.load(Ordering::Acquire),
                self.stop_epoch.load(Ordering::Acquire),
            )
        };
        let prepared = if let Some(item) = &candidate {
            self.prepare_user_input(item, &config, cancel.clone(), false)
                .await
        } else {
            Ok(None)
        };
        let confirmation = async {
            config.confirm_for_request().await?;
            self.confirm_runtime_authority(cancel.clone()).await
        }
        .await;
        let mut inner = self.inner.lock().expect("session mutex poisoned");
        let changed = generation != self.suspension_generation.load(Ordering::Acquire)
            || stop != self.stop_epoch.load(Ordering::Acquire)
            || !self
                .configuration()
                .is_some_and(|current| Arc::ptr_eq(&current, &config));
        let mut error = if self.is_retired()
            || cancel.is_cancelled()
            || changed
            || self.stop_requested.load(Ordering::Acquire)
        {
            Some(Error::Cancelled)
        } else {
            self.require_admission().err().or(confirmation.err())
        };
        let current = candidate.as_ref().filter(|captured| {
            steering_candidate(inner.store.snapshot_ref())
                .is_some_and(|now| same_submission(captured, now))
        });
        let prepared = match prepared {
            Ok(value) => value,
            Err(failure) => {
                if current.is_some() && error.is_none() {
                    error = Some(failure);
                }
                None
            }
        };
        let steering = current.map(|item| item.id.as_str());
        let stopped = error.is_some();
        let outcome = inner.store.transact(|session| {
            session
                .settle_tools_with_prepared_steering(reply, results, stopped, steering, prepared)?;
            if let Some(error) = &error {
                session.error = Some(error.to_string());
            }
            Ok(())
        });
        if let Err(error) = outcome {
            inner.fatal = Some(error.to_string());
            self.publish(&inner);
            return None;
        }
        self.publish(&inner);
        let session = inner.store.snapshot();
        let item = session
            .active
            .clone()
            .or_else(|| session.retry.clone())
            .expect("continuation or retry assigned");
        Some((item, session))
    }
}

#[cfg(test)]
#[path = "attachment_runtime_tests.rs"]
mod tests;
