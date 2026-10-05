use crate::{
    Credential, Error, Lane, Profile, QueueEditStatus, ResponsesClient, Result, RunState, Session,
    SessionStore, Submission, invalid,
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
    /// Recovery reads serialize with edits and commits. Published snapshots may
    /// remain stale after an uncertain write and are never used for this answer.
    pub fn edit_status(&self, edit_id: &str) -> Result<QueueEditStatus> {
        let inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        if let Some(error) = &inner.fatal {
            return Err(invalid(error.clone()));
        }
        inner.store.edit_status(edit_id)
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
        inner.store.require_certain()?;
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

#[cfg(test)]
mod edit_status_tests {
    use super::*;
    use crate::{QueueEditState, session::WriteFault};
    use std::{collections::BTreeMap, ffi::OsString, path::Path, time::Duration};
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
        time::timeout,
    };

    const DEADLINE: Duration = Duration::from_secs(5);

    fn retained_files(directory: &Path) -> BTreeMap<OsString, Vec<u8>> {
        std::fs::read_dir(directory)
            .unwrap()
            .map(|entry| {
                let entry = entry.unwrap();
                (entry.file_name(), std::fs::read(entry.path()).unwrap())
            })
            .collect()
    }

    async fn read_fixture_request(socket: &mut TcpStream) -> serde_json::Value {
        timeout(DEADLINE, async {
            let mut bytes = Vec::new();
            loop {
                let mut buffer = [0; 4096];
                let count = socket.read(&mut buffer).await.unwrap();
                assert_ne!(count, 0, "worker disconnected before its request");
                bytes.extend_from_slice(&buffer[..count]);
                assert!(bytes.len() < 1024 * 1024, "fixture request too large");
                if let Some(end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&bytes[..end]).to_lowercase();
                    assert_eq!(headers.lines().next(), Some("post /v1/responses http/1.1"));
                    assert!(headers.contains("authorization: bearer fixture-only\r\n"));
                    let length: usize = headers
                        .lines()
                        .find_map(|line| line.strip_prefix("content-length: "))
                        .expect("JSON request content length")
                        .parse()
                        .unwrap();
                    if bytes.len() >= end + 4 + length {
                        return serde_json::from_slice(&bytes[end + 4..end + 4 + length]).unwrap();
                    }
                }
            }
        })
        .await
        .expect("fixture request timed out")
    }

    async fn await_session(controller: &Controller, predicate: impl Fn(&Session) -> bool) {
        let mut updates = controller.subscribe();
        timeout(DEADLINE, async {
            loop {
                if predicate(&updates.borrow_and_update()) {
                    return;
                }
                updates.changed().await.expect("session updates closed");
            }
        })
        .await
        .expect("expected session transition timed out");
    }

    fn held_controller(path: &std::path::Path) -> (Arc<Controller>, String) {
        let mut store = SessionStore::open(path).unwrap();
        let item = Submission::new("original full text\nsecond line".into(), Lane::FollowUp);
        let turn_id = item.id.clone();
        store.transact(|session| session.submit(item)).unwrap();
        let controller = Controller::new(store, None).unwrap();
        controller.begin_edit(&turn_id, "edit").unwrap();
        (controller, turn_id)
    }

    #[test]
    fn status_reads_actor_state_instead_of_cached_presentation_and_rejects_fatal() {
        let dir = tempfile::tempdir().unwrap();
        let (controller, turn_id) = held_controller(&dir.path().join("session.json"));
        let cached = controller.snapshot_shared();
        let status = controller.edit_status("edit").unwrap();
        assert_eq!(status.edit_id, "edit");
        assert_eq!(status.session_revision, cached.revision);
        assert_eq!(status.current_hold, cached.edit);
        assert_eq!(
            status.state,
            QueueEditState::Active {
                turn_id,
                text: "original full text\nsecond line".into()
            }
        );
        // A separately published UI value is presentation only, even when its
        // revision and held identity appear plausible.
        controller.published.send_replace(Arc::new(Session::new()));
        assert!(controller.snapshot_shared().edit.is_none());
        assert_eq!(controller.edit_status("edit").unwrap(), status);
        controller.inner.lock().unwrap().fatal = Some("fixture fatal checkpoint".into());
        assert!(controller.edit_status("edit").is_err());
        assert!(controller.edit_status("unknown").is_err());
        assert!(controller.begin_edit("other-turn", "other").is_err());
        assert!(controller.resolve_edit("edit", "cancelled", None).is_err());
    }

    #[test]
    fn uncertain_save_cannot_be_reconciled_from_stale_cached_hold_until_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let (controller, turn_id) = held_controller(&path);
        let cached = controller.snapshot_shared();
        let bytes = std::fs::read(&path).unwrap();
        controller.inner.lock().unwrap().store.fault = WriteFault::BeforeRename;
        assert!(
            controller
                .resolve_edit("edit", "saved", Some("saved rewrite"))
                .is_err()
        );
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        assert!(matches!(
            controller.edit_status("edit").unwrap().state,
            QueueEditState::Active { .. }
        ));
        controller.inner.lock().unwrap().store.fault = WriteFault::AfterRename;
        assert!(matches!(
            controller.resolve_edit("edit", "saved", Some("saved rewrite")),
            Err(Error::PersistenceUncertain(_))
        ));
        assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
        assert_eq!(
            controller.snapshot_shared().edit.as_ref().unwrap().turn_id,
            turn_id
        );
        for id in ["edit", "unknown"] {
            assert!(matches!(
                controller.edit_status(id),
                Err(Error::PersistenceUncertain(_))
            ));
        }
        controller.inner.lock().unwrap().store.fault = WriteFault::None;
        assert!(matches!(
            controller.begin_edit(&turn_id, "edit"),
            Err(Error::PersistenceUncertain(_))
        ));
        assert!(matches!(
            controller.resolve_edit("edit", "cancelled", None),
            Err(Error::PersistenceUncertain(_))
        ));
        let committed_bytes = std::fs::read(&path).unwrap();
        drop(controller);
        let reopened = Controller::new(SessionStore::open(&path).unwrap(), None).unwrap();
        assert!(matches!(
            reopened.edit_status("edit").unwrap().state,
            QueueEditState::Saved { .. }
        ));
        assert!(reopened.edit_status("edit").unwrap().current_hold.is_none());
        assert_eq!(reopened.snapshot_shared().pending[0].text, "saved rewrite");
        assert_eq!(std::fs::read(path).unwrap(), committed_bytes);
    }

    #[tokio::test]
    async fn shutdown_of_idle_uncertain_store_preserves_bytes_until_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let (controller, turn_id) = held_controller(&path);
        let cached = controller.snapshot_shared();
        controller.inner.lock().unwrap().store.fault = WriteFault::AfterRename;
        assert!(matches!(
            controller.resolve_edit("edit", "saved", Some("saved despite lost acknowledgement")),
            Err(Error::PersistenceUncertain(_))
        ));
        // Removing the injected failure does not clear real store uncertainty.
        controller.inner.lock().unwrap().store.fault = WriteFault::None;
        let retained = retained_files(dir.path());
        let committed: Session = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert!(committed.edit.is_none());
        assert_eq!(
            committed.pending[0].text,
            "saved despite lost acknowledgement"
        );
        assert!(controller.worker.lock().unwrap().is_none());
        assert!(!controller.worker_active.load(Ordering::Acquire));

        timeout(DEADLINE, controller.shutdown())
            .await
            .expect("idle uncertain shutdown must not wait for storage recovery")
            .unwrap();

        assert_eq!(retained_files(dir.path()), retained);
        assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
        let inner = controller.inner.lock().unwrap();
        assert!(inner.fatal.is_none());
        assert!(matches!(
            inner.store.require_certain(),
            Err(Error::PersistenceUncertain(_))
        ));
        assert_eq!(inner.store.snapshot_revision(), cached.revision);
        drop(inner);
        for id in ["edit", "unknown"] {
            assert!(matches!(
                controller.edit_status(id),
                Err(Error::PersistenceUncertain(_))
            ));
        }
        drop(controller);

        let reopened = Controller::new(SessionStore::open(&path).unwrap(), None).unwrap();
        let status = reopened.edit_status("edit").unwrap();
        assert!(matches!(status.state, QueueEditState::Saved { .. }));
        assert!(status.current_hold.is_none());
        assert_eq!(reopened.snapshot_shared().pending[0].id, turn_id);
        assert_eq!(
            reopened.snapshot_shared().pending[0].text,
            "saved despite lost acknowledgement"
        );
        // This idle reopen only confirms the existing checkpoint; it need not rewrite it.
        assert_eq!(retained_files(dir.path()), retained);
    }

    #[tokio::test]
    async fn shutdown_joins_real_gated_worker_after_uncertain_checkpoint_without_more_writes() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let profile: Profile = serde_json::from_value(serde_json::json!({
            "id":"uncertain-shutdown-fixture", "api":"openai-responses", "providerId":"litellm",
            "modelId":"local-fixture", "baseUrl":format!("http://{}", listener.local_addr().unwrap()),
            "contextWindow":32000, "maxOutputTokens":4096
        })).unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let controller = Controller::new(
            SessionStore::open(&path).unwrap(),
            Some((profile, Credential::new("fixture-only".into()).unwrap())),
        )
        .unwrap();
        let first = Submission::new("active request".into(), Lane::FollowUp);
        let first_id = first.id.clone();
        controller.submit_identified(first).unwrap();
        let (mut socket, _) = timeout(DEADLINE, listener.accept()).await.unwrap().unwrap();
        let request = read_fixture_request(&mut socket).await;
        assert_eq!(request["input"][0]["content"][0]["text"], "active request");
        assert!(request.get("tools").is_none());

        // Admit the next item before streaming so the accepted delta has its own
        // journal, which the failed Begin checkpoint must retain unchanged.
        let queued = Submission::new("queued original\nsecond line".into(), Lane::FollowUp);
        let queued_id = queued.id.clone();
        controller.submit_identified(queued).unwrap();
        timeout(DEADLINE, async {
            socket.write_all(concat!(
                "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"durable partial\"}\n\n"
            ).as_bytes()).await.unwrap();
            socket.flush().await.unwrap();
        })
        .await
        .expect("fixture initial delta timed out");
        await_session(&controller, |session| {
            session
                .messages
                .last()
                .is_some_and(|message| message.text == "durable partial")
        })
        .await;
        let cached = controller.snapshot_shared();
        assert_eq!(cached.state, RunState::Running);
        assert_eq!(cached.stream_sequence, 1);
        assert_eq!(cached.pending.len(), 1);
        assert!(!cached.queue_paused);
        assert!(cached.edit.is_none());
        let reply_id = cached.active_reply.clone().unwrap();
        let journal = crate::stream_journal::path(&path, &cached.stream_generation).unwrap();
        let journal_bytes = std::fs::read(&journal).unwrap();
        let record: serde_json::Value = serde_json::from_slice(&journal_bytes).unwrap();
        assert_eq!(record["reply"], reply_id);
        assert_eq!(record["sequence"], 1);
        assert_eq!(
            record["delta"],
            serde_json::to_value(crate::Delta::Text("durable partial".into())).unwrap()
        );

        controller.inner.lock().unwrap().store.fault = WriteFault::AfterRename;
        assert!(matches!(
            controller.begin_edit(&queued_id, "uncertain-begin"),
            Err(Error::PersistenceUncertain(_))
        ));
        controller.inner.lock().unwrap().store.fault = WriteFault::None;
        assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
        assert!(matches!(
            controller.edit_status("uncertain-begin"),
            Err(Error::PersistenceUncertain(_))
        ));
        let retained = retained_files(dir.path());
        let committed: Session = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(committed.edit.as_ref().unwrap().edit_id, "uncertain-begin");
        assert_eq!(committed.messages.last().unwrap().text, "durable partial");
        assert_ne!(committed.stream_generation, cached.stream_generation);
        assert_eq!(std::fs::read(&journal).unwrap(), journal_bytes);
        let cancel = controller.active_cancel.read().unwrap().clone().unwrap();
        assert!(!cancel.is_cancelled());
        assert!(controller.worker_active.load(Ordering::Acquire));
        assert!(
            !controller
                .worker
                .lock()
                .unwrap()
                .as_ref()
                .unwrap()
                .is_finished()
        );

        // The test owns the provider gate: keep the socket open and never send
        // EOF or a terminal event until the actual production worker has joined.
        let retained_controller = Arc::clone(&controller);
        timeout(DEADLINE, controller.shutdown())
            .await
            .expect("uncertain storage must not prevent cancelling and joining the worker")
            .unwrap();

        assert!(cancel.is_cancelled());
        assert!(!controller.worker_active.load(Ordering::Acquire));
        assert!(controller.worker.lock().unwrap().is_none());
        assert!(controller.active_cancel.read().unwrap().is_none());
        {
            let inner = controller.inner.lock().unwrap();
            assert!(!inner.worker_running);
            assert!(inner.cancel.is_none());
            assert!(
                inner
                    .fatal
                    .as_ref()
                    .unwrap()
                    .contains("persistence is uncertain")
            );
            assert!(matches!(
                inner.store.require_certain(),
                Err(Error::PersistenceUncertain(_))
            ));
            assert_eq!(
                serde_json::to_value(inner.store.snapshot()).unwrap(),
                serde_json::to_value(&*cached).unwrap()
            );
        }
        assert_eq!(controller.snapshot_shared().state, RunState::Error);
        assert!(controller.snapshot_shared().queue_paused);
        for id in ["uncertain-begin", "unknown"] {
            assert!(controller.edit_status(id).is_err());
        }
        assert_eq!(retained_files(dir.path()), retained);

        let mut end = [0; 1];
        assert_eq!(
            timeout(DEADLINE, socket.read(&mut end))
                .await
                .unwrap()
                .unwrap(),
            0,
            "cancellation must drop the gated HTTP stream"
        );
        // Join is the completion barrier. No timer-based quiet period or mock
        // JoinHandle stands in for proving this worker cannot dispatch again.
        let listener = listener.into_std().unwrap();
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
        assert_eq!(retained_files(dir.path()), retained);
        // Joining does not drop the controller's writer lock or its poisoned
        // store. Reopen is possible only after every retained owner is gone.
        assert!(
            matches!(SessionStore::open(&path), Err(Error::Invalid(message)) if message == "This Rust session is already open elsewhere")
        );
        drop(controller);
        assert!(
            matches!(SessionStore::open(&path), Err(Error::Invalid(message)) if message == "This Rust session is already open elsewhere")
        );
        drop(retained_controller);

        let reopened = Controller::new(SessionStore::open(&path).unwrap(), None).unwrap();
        let recovered = reopened.snapshot_shared();
        assert_eq!(recovered.state, RunState::Paused);
        assert!(recovered.queue_paused);
        assert!(recovered.active.is_none());
        assert!(recovered.active_reply.is_none());
        assert_eq!(recovered.retry.as_ref().unwrap().id, first_id);
        assert_eq!(recovered.pending.len(), 1);
        assert_eq!(recovered.pending[0].id, queued_id);
        assert_eq!(recovered.pending[0].text, "queued original\nsecond line");
        assert_eq!(recovered.messages.len(), 2);
        let partial = recovered.messages.last().unwrap();
        assert_eq!(partial.id, reply_id);
        assert_eq!(partial.text, "durable partial");
        assert_eq!(partial.state, "interrupted");
        assert!(!partial.replay_eligible);
        let status = reopened.edit_status("uncertain-begin").unwrap();
        assert_eq!(
            status.state,
            QueueEditState::Active {
                turn_id: queued_id,
                text: "queued original\nsecond line".into(),
            }
        );
        assert_eq!(status.current_hold, committed.edit);
        // The old generation is retained, but never replays its text twice.
        assert_eq!(std::fs::read(&journal).unwrap(), journal_bytes);
        assert!(reopened.worker.lock().unwrap().is_none());
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
    }

    #[tokio::test]
    async fn shutdown_reports_worker_join_failure_separately_from_store_uncertainty() {
        let controller = Controller::new(SessionStore::pending(), None).unwrap();
        // A synthetic panicking task covers only JoinError propagation. The
        // gated-provider test above supplies evidence about the real worker.
        *controller.worker.lock().unwrap() = Some(tokio::spawn(async {
            panic!("injected worker task panic");
        }));
        let result = timeout(DEADLINE, controller.shutdown()).await.unwrap();
        assert!(
            matches!(result, Err(Error::Invalid(message)) if message == "Session worker terminated unexpectedly")
        );
        assert!(controller.worker.lock().unwrap().is_none());
        controller
            .inner
            .lock()
            .unwrap()
            .store
            .require_certain()
            .unwrap();
    }

    #[tokio::test]
    async fn shutdown_reports_poisoned_cancellation_and_worker_locks() {
        let controller = Controller::new(SessionStore::pending(), None).unwrap();
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let _guard = controller.active_cancel.write().unwrap();
                panic!("injected cancellation lock panic");
            }))
            .is_err()
        );
        let result = timeout(DEADLINE, controller.shutdown()).await.unwrap();
        assert!(
            matches!(result, Err(Error::Invalid(message)) if message == "Session is unavailable")
        );
        controller
            .inner
            .lock()
            .unwrap()
            .store
            .require_certain()
            .unwrap();

        let controller = Controller::new(SessionStore::pending(), None).unwrap();
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let _guard = controller.worker.lock().unwrap();
                panic!("injected worker lock panic");
            }))
            .is_err()
        );
        let result = timeout(DEADLINE, controller.shutdown()).await.unwrap();
        assert!(
            matches!(result, Err(Error::Invalid(message)) if message == "Worker is unavailable")
        );
        controller
            .inner
            .lock()
            .unwrap()
            .store
            .require_certain()
            .unwrap();
    }

    #[test]
    fn unmaterialized_empty_chat_has_certain_unknown_status() {
        let controller = Controller::new(SessionStore::pending(), None).unwrap();
        let status = controller.edit_status("not-granted").unwrap();
        assert_eq!(status.state, QueueEditState::Unknown);
        assert_eq!(status.session_revision, 0);
        assert!(status.current_hold.is_none());
        assert!(!controller.is_persistent());
        assert!(controller.edit_status("").is_err());
        assert!(controller.edit_status(&"x".repeat(129)).is_err());
    }
}
