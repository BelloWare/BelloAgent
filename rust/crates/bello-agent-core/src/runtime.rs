use crate::{
    Credential, Error, Lane, Profile, ResponsesClient, Result, RunState, Session, SessionStore,
    Submission, invalid,
};
use std::sync::{
    Arc, Mutex, OnceLock, RwLock,
    atomic::{AtomicBool, AtomicU64, Ordering},
};
use tokio_util::sync::CancellationToken;

struct Inner {
    store: SessionStore,
    worker_running: bool,
    cancel: Option<CancellationToken>,
    fatal: Option<String>,
}
pub struct Configuration {
    profile: Profile,
    credential: Credential,
}
/// One provider worker per conversation. UI commands and response completion
/// serialize through the same mutex; disk commits precede acknowledging commands.
pub struct Controller {
    inner: Mutex<Inner>,
    published: tokio::sync::watch::Sender<Arc<Session>>,
    published_revision: AtomicU64,
    active_cancel: RwLock<Option<CancellationToken>>,
    stop_requested: AtomicBool,
    worker_active: AtomicBool,
    config: Option<Arc<Configuration>>,
    client: ResponsesClient,
    runtime: tokio::runtime::Handle,
    worker: Mutex<Option<tokio::task::JoinHandle<()>>>,
}
impl Controller {
    pub fn new(
        store: SessionStore,
        configuration: Option<(Profile, Credential)>,
    ) -> Result<Arc<Self>> {
        let configuration = configuration.map(|(profile, credential)| {
            Arc::new(Configuration {
                profile,
                credential,
            })
        });
        Self::with_configuration(store, configuration)
    }
    pub fn with_configuration(
        store: SessionStore,
        configuration: Option<Arc<Configuration>>,
    ) -> Result<Arc<Self>> {
        if let Some(configuration) = &configuration {
            configuration.profile.validate()?;
        }
        let initial = Arc::new(store.snapshot());
        Ok(Arc::new(Self {
            published: tokio::sync::watch::channel(initial).0,
            published_revision: AtomicU64::new(0),
            active_cancel: RwLock::new(None),
            stop_requested: AtomicBool::new(false),
            worker_active: AtomicBool::new(false),
            inner: Mutex::new(Inner {
                store,
                worker_running: false,
                cancel: None,
                fatal: None,
            }),
            config: configuration,
            client: ResponsesClient::new()?,
            runtime: shared_runtime()?.handle().clone(),
            worker: Mutex::new(None),
        }))
    }
    pub fn configuration(&self) -> Option<Arc<Configuration>> {
        self.config.clone()
    }
    pub fn is_persistent(&self) -> bool {
        self.inner
            .lock()
            .is_ok_and(|inner| inner.store.is_persistent())
    }
    pub fn materialize(&self, path: &std::path::Path) -> Result<()> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        inner.store.persist_to(path)?;
        self.publish(&inner);
        Ok(())
    }
    pub fn configured(&self) -> bool {
        self.config.is_some()
    }
    pub fn profile(&self) -> Option<&Profile> {
        self.config.as_ref().map(|v| &v.profile)
    }
    pub fn revision(&self) -> u64 {
        self.published_revision.load(Ordering::Acquire)
    }
    pub fn snapshot(&self) -> Session {
        (*self.snapshot_shared()).clone()
    }
    /// UI reads never take the persistence/actor mutex or wait for fsync.
    pub fn snapshot_shared(&self) -> Arc<Session> {
        self.published.borrow().clone()
    }
    pub fn subscribe(&self) -> tokio::sync::watch::Receiver<Arc<Session>> {
        self.published.subscribe()
    }
    fn publish(&self, inner: &Inner) {
        let mut snapshot = inner.store.snapshot();
        if let Some(error) = &inner.fatal {
            snapshot.error = Some(error.clone());
            snapshot.state = RunState::Error;
            snapshot.queue_paused = true;
        }
        self.published.send_replace(Arc::new(snapshot));
        self.published_revision.fetch_add(1, Ordering::Release);
    }
    fn worker_finished(&self, inner: &mut Inner) {
        inner.worker_running = false;
        inner.cancel = None;
        self.worker_active.store(false, Ordering::Release);
        *self
            .active_cancel
            .write()
            .expect("cancellation lock poisoned") = None;
    }
    pub fn submit(self: &Arc<Self>, text: String, lane: Lane) -> Result<()> {
        self.submit_identified(Submission::new(text, lane))
    }
    pub fn submit_identified(self: &Arc<Self>, mut item: Submission) -> Result<()> {
        let config=self.config.as_ref().ok_or_else(||invalid("No connection configured. Launch with --profile and --credential-stdin; no credentials are discovered automatically."))?;
        item.model = Some(config.profile.model_id.clone());
        item.effort = Some(config.profile.thinking_level.clone());
        self.change(|s| s.submit(item))?;
        self.launch(None);
        Ok(())
    }
    pub fn stop(&self) -> Result<()> {
        if self.worker_active.load(Ordering::Acquire) {
            self.stop_requested.store(true, Ordering::Release);
        }
        if let Some(cancel) = self
            .active_cancel
            .read()
            .map_err(|_| invalid("Session is unavailable"))?
            .as_ref()
        {
            cancel.cancel();
        }
        Ok(())
    }
    /// Cancel and await the current worker before dropping or reopening storage.
    /// Callers should prevent new submissions during shutdown.
    pub async fn shutdown(&self) -> Result<()> {
        self.stop()?;
        let worker = self
            .worker
            .lock()
            .map_err(|_| invalid("Worker is unavailable"))?
            .take();
        if let Some(worker) = worker {
            worker
                .await
                .map_err(|_| invalid("Session worker terminated unexpectedly"))?;
        }
        Ok(())
    }
    pub fn resume(self: &Arc<Self>) -> Result<()> {
        self.require_config()?;
        self.change(Session::resume)?;
        self.launch(None);
        Ok(())
    }
    pub fn retry(self: &Arc<Self>) -> Result<()> {
        self.require_config()?;
        let item = self.change(Session::retry_turn)?;
        self.launch(Some(item));
        Ok(())
    }
    pub fn begin_edit(&self, turn_id: &str, edit_id: &str) -> Result<String> {
        self.change(|s| s.begin_edit(turn_id, edit_id))
    }
    pub fn resolve_edit(
        self: &Arc<Self>,
        edit_id: &str,
        outcome: &str,
        text: Option<&str>,
    ) -> Result<()> {
        self.change(|s| s.resolve_edit(edit_id, outcome, text))?;
        self.launch(None);
        Ok(())
    }
    pub fn remove(self: &Arc<Self>, id: &str) -> Result<()> {
        self.change(|s| s.remove(id))?;
        self.launch(None);
        Ok(())
    }
    pub fn reorder(&self, ids: &[String]) -> Result<()> {
        self.change(|s| s.reorder(ids))
    }
    /// Persist the lane change without interrupting or relaunching the worker.
    pub fn promote_to_steering(&self, id: &str) -> Result<()> {
        self.change_checked(
            |inner| {
                if !inner.worker_running {
                    return Err(invalid(
                        "Steering requires an active run; the message stays queued",
                    ));
                }
                Ok(())
            },
            |s| s.promote_to_steering(id),
        )
    }
    fn require_config(&self) -> Result<()> {
        if self.config.is_none() {
            return Err(invalid("No connection configured"));
        }
        Ok(())
    }
    fn change<T>(&self, action: impl FnOnce(&mut Session) -> Result<T>) -> Result<T> {
        self.change_checked(|_| Ok(()), action)
    }
    fn change_checked<T>(
        &self,
        check: impl FnOnce(&Inner) -> Result<()>,
        action: impl FnOnce(&mut Session) -> Result<T>,
    ) -> Result<T> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        if let Some(error) = &inner.fatal {
            return Err(invalid(error.clone()));
        }
        check(&inner)?;
        let result = inner.store.transact(action);
        if result.is_ok() {
            self.publish(&inner);
        }
        result
    }
    fn stream_delta(&self, reply_id: &str, delta: crate::Delta) -> Result<()> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        if let Some(error) = &inner.fatal {
            return Err(invalid(error.clone()));
        }
        inner.store.append_delta(reply_id, delta)?;
        self.publish(&inner);
        Ok(())
    }
    fn launch(self: &Arc<Self>, first: Option<Submission>) {
        if self.config.is_none() {
            return;
        }
        {
            let mut inner = self.inner.lock().expect("session mutex poisoned");
            if inner.worker_running || inner.fatal.is_some() {
                return;
            }
            if first.is_none() {
                let snapshot = inner.store.snapshot();
                if snapshot.state == RunState::Running
                    || snapshot.queue_paused
                    || snapshot.edit.is_some()
                    || snapshot.pending.is_empty()
                {
                    return;
                }
            }
            inner.worker_running = true;
            self.worker_active.store(true, Ordering::Release);
        }
        let this = Arc::clone(self);
        let worker = self.runtime.spawn(async move {
            this.run(first).await;
        });
        *self.worker.lock().expect("worker handle lock poisoned") = Some(worker);
    }
    async fn run(self: Arc<Self>, mut first: Option<Submission>) {
        loop {
            let prepared = {
                let mut inner = self.inner.lock().expect("session mutex poisoned");
                if first.is_none() && self.stop_requested.swap(false, Ordering::AcqRel) {
                    let result = inner.store.transact(|session| {
                        session.queue_paused = true;
                        session.state = RunState::Paused;
                        Ok(())
                    });
                    if let Err(error) = result {
                        inner.fatal = Some(error.to_string());
                    }
                    self.worker_finished(&mut inner);
                    self.publish(&inner);
                    return;
                }
                let next = match first.take() {
                    Some(item) => Ok(Some(item)),
                    None => inner.store.transact(Session::start_next),
                };
                match next {
                    Ok(Some(item)) => {
                        let snapshot = inner.store.snapshot();
                        let cancel = CancellationToken::new();
                        if self.stop_requested.swap(false, Ordering::AcqRel) {
                            cancel.cancel();
                        }
                        inner.cancel = Some(cancel.clone());
                        *self
                            .active_cancel
                            .write()
                            .expect("cancellation lock poisoned") = Some(cancel.clone());
                        self.publish(&inner);
                        Some((item, snapshot, cancel))
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
            let Some((item, snapshot, cancel)) = prepared else {
                return;
            };
            let reply_id = snapshot
                .active_reply
                .clone()
                .expect("active reply assigned");
            let config = self.config.as_ref().expect("configuration checked");
            let mut profile = config.profile.clone();
            if let Some(model) = item.model {
                profile.model_id = model;
            }
            if let Some(effort) = item.effort {
                profile.thinking_level = effort;
            }
            let callback_id = reply_id.clone();
            let callback_self = Arc::clone(&self);
            let result = self
                .client
                .complete(
                    &profile,
                    &config.credential,
                    &snapshot.messages,
                    "",
                    &snapshot.id,
                    &item.id,
                    cancel.clone(),
                    move |delta| callback_self.stream_delta(&callback_id, delta),
                )
                .await;
            // Stop wins the race with a provider terminal event already in flight.
            let mut inner = self.inner.lock().expect("session mutex poisoned");
            let result = if cancel.is_cancelled() {
                Err(Error::Cancelled)
            } else {
                result
            };
            if let Err(error) = inner
                .store
                .transact(|session| session.finish(&reply_id, result))
            {
                inner.fatal = Some(error.to_string());
                self.worker_finished(&mut inner);
                self.publish(&inner);
                return;
            }
            inner.cancel = None;
            self.publish(&inner);
            if inner.store.snapshot().state != RunState::Idle {
                self.worker_finished(&mut inner);
                self.stop_requested.store(false, Ordering::Release);
                return;
            }
        }
    }
}

fn shared_runtime() -> Result<&'static tokio::runtime::Runtime> {
    static RUNTIME: OnceLock<std::result::Result<tokio::runtime::Runtime, String>> =
        OnceLock::new();
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .map_err(|error| error.to_string())
        })
        .as_ref()
        .map_err(|error| invalid(error.clone()))
}
