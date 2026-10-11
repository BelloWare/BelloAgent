#[path = "semantic_activity.rs"]
mod semantic_activity;
pub use semantic_activity::SemanticActivity;

#[cfg(all(test, feature = "synthetic-authority"))]
#[path = "context_recovery_mcp_tests.rs"]
mod context_recovery_mcp_tests;

#[path = "context_recovery_runtime.rs"]
mod context_recovery_runtime;

#[path = "live_tool_runtime.rs"]
mod live_tool_runtime;

#[path = "attachment_runtime.rs"]
mod attachment_runtime;
#[path = "project_input_runtime.rs"]
pub(crate) mod project_input_runtime;

#[path = "compaction_runtime.rs"]
mod compaction_runtime;

#[path = "runtime_admission.rs"]
mod admission;
#[path = "mcp_inspector_runtime.rs"]
mod mcp_inspector_runtime;
pub use admission::IdleAdmissionGuard;

#[path = "tool_runtime.rs"]
pub(crate) mod tool_runtime;
pub use tool_runtime::{RuntimeOptions, TrustedReadOnlyTools};

#[cfg(feature = "synthetic-authority")]
#[path = "resource_runtime.rs"]
mod resource_runtime;
#[cfg(feature = "synthetic-authority")]
pub use resource_runtime::{AppliedInstructionSnapshot, SyntheticResources, SyntheticRuntimeGuard};

#[path = "context_preview.rs"]
mod context_preview;
pub use context_preview::{ContextPreview, ContextPreviewMetadata, ContextPreviewMode};

use crate::{
    Credential, Lane, Profile, QueueEditState, QueueEditStatus, ResponsesClient, Result, RunState,
    Session, SessionStore, Submission, invalid,
};
use futures_util::{
    FutureExt,
    future::{BoxFuture, Shared, join_all},
};
use std::sync::{
    Arc, Mutex, OnceLock, RwLock,
    atomic::{AtomicBool, AtomicU64, Ordering},
};
use tokio_util::sync::CancellationToken;

struct Inner {
    live_tools: Vec<crate::tool_history::LiveToolView>,
    store: SessionStore,
    applied_project: Option<project_input_runtime::AppliedProjectResources>,
    worker_running: bool,
    compaction_pending: bool,
    worker_epoch: Arc<()>,
    cancel: Option<CancellationToken>,
    fatal: Option<String>,
    pending_configuration: Option<Arc<Configuration>>,
    configuration_epoch: Arc<()>,
    #[cfg(feature = "synthetic-authority")]
    applied_instructions: Option<Arc<AppliedInstructionSnapshot>>,
}
/// Full confirmation is made outside the actor; this token rejects a delayed
/// active-run result once that worker settles or its applied config changes.
struct AdmissionConfirmation {
    configuration: Option<Arc<Configuration>>,
    active_epoch: Option<Arc<()>>,
}
type WorkerJoin = Shared<BoxFuture<'static, std::result::Result<(), String>>>;

/// The actor-safe half is an atomic witness only. Full confirmation may read
/// vault/catalog/files, so callers must run it outside all actor/catalog locks.
pub trait RuntimeAuthorityGuard: Send + Sync {
    fn check(&self) -> Result<()>;
    fn confirm(&self) -> Result<()>;
    fn confirm_materialization(&self, _path: &std::path::Path) -> Result<()> {
        Err(invalid("This authority cannot create a checkpoint"))
    }
}
pub struct Configuration {
    profile: Profile,
    credential: Credential,
    connection: Option<Arc<crate::project_authority::connections::ConnectionLease>>,
}
impl Configuration {
    pub(crate) fn effective_profile(&self, item: Option<&Submission>) -> Profile {
        match &self.connection {
            Some(connection) => connection.effective_profile(&self.profile, item),
            None => tool_runtime::effective_profile(&self.profile, item),
        }
    }
    pub(crate) fn saved_connection(
        profile: Profile,
        credential: Credential,
        connection: Arc<crate::project_authority::connections::ConnectionLease>,
    ) -> Self {
        Self {
            profile,
            credential,
            connection: Some(connection),
        }
    }
    fn check(&self) -> Result<()> {
        if let Some(connection) = &self.connection {
            connection.check()?;
        }
        Ok(())
    }
    fn confirm(&self, exact: bool) -> Result<()> {
        if let Some(connection) = &self.connection {
            return connection.confirm(exact);
        }
        Ok(())
    }
    async fn confirm_for_request(self: &Arc<Self>) -> Result<()> {
        if self.connection.is_some() {
            let configuration = self.clone();
            return tokio::task::spawn_blocking(move || configuration.confirm(false))
                .await
                .map_err(|_| invalid("Connection confirmation worker failed"))?;
        }
        self.check()
    }
    fn has_saved_connection(&self) -> bool {
        self.connection.is_some()
    }
    fn same_route(&self, other: &Self) -> bool {
        self.profile.id == other.profile.id
            && self.profile.api == other.profile.api
            && self.profile.base_url == other.profile.base_url
            && self.profile.model_id == other.profile.model_id
    }
    fn compatible_authority(&self, other: &Self) -> bool {
        match (&self.connection, &other.connection) {
            (Some(left), Some(right)) => left.same_authority(right),
            (None, None) => true,
            _ => false,
        }
    }
}
// Constructed only from one actor/store boundary; never pair independent reads.
struct PreparedFindPublication {
    session: Session,
    token: crate::retained_find::ContentToken,
}

/// One provider worker per conversation. UI commands and response completion
/// serialize through the same mutex; disk commits precede acknowledging commands.
pub struct Controller {
    source_witness: crate::source_admission::SourceWitness,
    inner: Arc<Mutex<Inner>>,
    published: tokio::sync::watch::Sender<Arc<Session>>,
    find_published: RwLock<crate::FindSnapshot>,
    published_revision: AtomicU64,
    semantic_activity: tokio::sync::watch::Sender<SemanticActivity>,
    accepted_read: tokio::sync::watch::Sender<crate::read_observation::AcceptedReadObservation>,
    active_cancel: RwLock<Option<CancellationToken>>,
    stop_requested: AtomicBool,
    stop_epoch: AtomicU64,
    retired: AtomicBool,
    admission_suspension: AtomicU64,
    suspension_generation: AtomicU64,
    suspension_owner: AtomicU64,
    suspension_released: tokio::sync::Notify,
    worker_active: AtomicBool,
    config: RwLock<Option<Arc<Configuration>>>,
    configuration_generation: AtomicU64,
    project_resources: Option<project_input_runtime::ProjectRuntimeBinding>,
    pending_settings: AtomicBool,
    options: RuntimeOptions,
    attachment_workers: crate::tools::BlockingWorkExecutor,
    attachment_jobs: Arc<attachment_runtime::AttachmentJobs>,
    #[cfg(test)]
    fixture_images: AtomicBool,
    #[cfg(test)]
    attachment_processor_barrier: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    resource_preparation_barrier: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    input_commit_gate: Mutex<Option<(String, Arc<project_input_runtime::InputCommitGate>)>>,
    authority: Option<Arc<dyn RuntimeAuthorityGuard>>,
    #[cfg(feature = "synthetic-authority")]
    resources: Option<SyntheticResources>,
    client: ResponsesClient,
    runtime: tokio::runtime::Handle,
    worker: Mutex<Option<tokio::task::JoinHandle<()>>>,
    worker_joins: Mutex<Vec<(tokio::task::Id, WorkerJoin)>>,
}
impl Drop for Controller {
    fn drop(&mut self) {
        // Revoke even if an internal health probe briefly upgraded the actor.
        self.source_witness.retire();
    }
}
impl Controller {
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub(crate) fn mcp_checkpoint_fault_for_test(&self, fault: u8) {
        self.inner.lock().unwrap().store.fault = match fault {
            1 => crate::session::WriteFault::BeforeRename,
            2 => crate::session::WriteFault::AfterRename,
            _ => crate::session::WriteFault::None,
        };
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub(crate) fn mcp_definitions_for_test(&self) -> Vec<crate::tools::ToolDefinition> {
        self.options.definitions()
    }
    pub fn new(
        store: SessionStore,
        configuration: Option<(Profile, Credential)>,
    ) -> Result<Arc<Self>> {
        Self::new_with_options(store, configuration, RuntimeOptions::default())
    }
    pub fn new_with_options(
        store: SessionStore,
        configuration: Option<(Profile, Credential)>,
        options: RuntimeOptions,
    ) -> Result<Arc<Self>> {
        let configuration = configuration.map(|(profile, credential)| {
            Arc::new(Configuration {
                profile,
                credential,
                connection: None,
            })
        });
        Self::with_configuration_and_options(store, configuration, options)
    }
    pub fn with_configuration(
        store: SessionStore,
        configuration: Option<Arc<Configuration>>,
    ) -> Result<Arc<Self>> {
        Self::with_configuration_and_options(store, configuration, RuntimeOptions::default())
    }
    pub fn with_configuration_and_options(
        store: SessionStore,
        configuration: Option<Arc<Configuration>>,
        options: RuntimeOptions,
    ) -> Result<Arc<Self>> {
        Self::with_authority(store, configuration, options, None)
    }
    pub(crate) fn with_authority(
        store: SessionStore,
        configuration: Option<Arc<Configuration>>,
        options: RuntimeOptions,
        authority: Option<Arc<dyn RuntimeAuthorityGuard>>,
    ) -> Result<Arc<Self>> {
        if let Some(guard) = &authority {
            guard.confirm()?;
        }
        if let Some(configuration) = &configuration {
            configuration.profile.validate()?;
            configuration.confirm(true)?;
            if configuration.connection.is_some() && options.tools.is_some() && authority.is_none()
            {
                return Err(invalid(
                    "Saved connections require the trusted project runtime factory for tools",
                ));
            }
        }
        let client = ResponsesClient::new()?;
        let client = if configuration.as_ref().is_some_and(|c| {
            c.connection
                .as_ref()
                .is_some_and(|lease| lease.is_fixture())
        }) {
            ResponsesClient::new_synthetic_fixture()?
        } else {
            client
        };
        let initial = Arc::new(store.snapshot());
        let controller = Arc::new(Self {
            source_witness: store.source_witness(),
            accepted_read: tokio::sync::watch::channel(store.read_observation()).0,
            find_published: RwLock::new(crate::FindSnapshot::new(
                initial.clone(),
                store.find_token(),
            )),
            published: tokio::sync::watch::channel(initial).0,
            published_revision: AtomicU64::new(0),
            semantic_activity: tokio::sync::watch::channel(SemanticActivity::default()).0,
            active_cancel: RwLock::new(None),
            stop_requested: AtomicBool::new(false),
            stop_epoch: AtomicU64::new(0),
            retired: AtomicBool::new(false),
            admission_suspension: AtomicU64::new(0),
            suspension_generation: AtomicU64::new(0),
            suspension_owner: AtomicU64::new(0),
            suspension_released: tokio::sync::Notify::new(),
            worker_active: AtomicBool::new(false),
            inner: Arc::new(Mutex::new(Inner {
                live_tools: Vec::new(),
                store,
                worker_running: false,
                compaction_pending: false,
                worker_epoch: Arc::new(()),
                cancel: None,
                fatal: None,
                pending_configuration: None,
                applied_project: None,
                configuration_epoch: Arc::new(()),
                #[cfg(feature = "synthetic-authority")]
                applied_instructions: None,
            })),
            config: RwLock::new(configuration),
            configuration_generation: AtomicU64::new(0),
            project_resources: None,
            pending_settings: AtomicBool::new(false),
            options,
            attachment_workers: crate::tools::BlockingWorkExecutor::shared(),
            attachment_jobs: Arc::new(attachment_runtime::AttachmentJobs::default()),
            #[cfg(test)]
            fixture_images: AtomicBool::new(false),
            #[cfg(test)]
            attachment_processor_barrier: Mutex::new(None),
            #[cfg(test)]
            resource_preparation_barrier: Mutex::new(None),
            #[cfg(test)]
            input_commit_gate: Mutex::new(None),
            authority,
            #[cfg(feature = "synthetic-authority")]
            resources: None,
            client,
            runtime: shared_runtime()?.handle().clone(),
            worker: Mutex::new(None),
            worker_joins: Mutex::new(Vec::new()),
        });
        controller.source_witness.bind_owner(&controller.inner);
        Ok(controller)
    }
    pub fn configuration(&self) -> Option<Arc<Configuration>> {
        self.config.read().ok()?.clone()
    }
    /// Pending provenance survives retirement; releasing a writer lock cannot
    /// turn a previously materialized actor back into an unsaved placeholder.
    pub fn is_never_materialized(&self) -> bool {
        self.inner
            .lock()
            .is_ok_and(|inner| inner.store.is_never_materialized())
    }
    pub fn is_persistent(&self) -> bool {
        self.inner
            .lock()
            .is_ok_and(|inner| inner.store.is_persistent())
    }
    pub fn materialize(&self, path: &std::path::Path) -> Result<()> {
        if !self.is_persistent()
            && let Some(authority) = &self.authority
        {
            authority.confirm_materialization(path)?;
        }
        let confirmed = self.confirm_resources()?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        self.require_confirmed_admission(&inner, &confirmed)?;
        inner.store.persist_to(path)?;
        self.publish(&inner);
        Ok(())
    }
    pub fn configured(&self) -> bool {
        self.configuration().is_some()
    }
    /// Presentation-only view of the applied factory runtime. This never reads
    /// vault/catalog/files or grants admission. Contended state is unavailable;
    /// external changes become known through the normal full-confirmation path.
    pub fn has_available_tool_definitions(&self) -> bool {
        if self.authority.is_none()
            || self.is_retired()
            || self.admission_suspension.load(Ordering::Acquire) != 0
            || self.check_resources().is_err()
        {
            return false;
        }
        let Ok(inner) = self.inner.try_lock() else {
            return false;
        };
        if inner.fatal.is_some() || inner.store.require_certain().is_err() {
            return false;
        }
        let Ok(configuration) = self.config.try_read() else {
            return false;
        };
        configuration.as_ref().is_some_and(|configuration| {
            configuration.has_saved_connection() && configuration.check().is_ok()
        }) && !self.options.definitions().is_empty()
            && !self.is_retired()
            && self.admission_suspension.load(Ordering::Acquire) == 0
            && self.check_resources().is_ok()
    }
    pub fn profile(&self) -> Option<Profile> {
        let mut profile = self.configuration()?.profile.clone();
        profile.headers.clear();
        Some(profile)
    }
    pub fn settings_pending(&self) -> bool {
        self.pending_settings.load(Ordering::Acquire)
    }
    /// Same route only. Never changes an entered worker's configuration; the
    /// latest pending save takes effect at full settlement, including Stop/error.
    pub fn configure(&self, configuration: Arc<Configuration>) -> Result<bool> {
        #[cfg(feature = "synthetic-authority")]
        if self.resources.is_some() {
            return Err(invalid(
                "Synthetic resource runtime configuration is immutable",
            ));
        }
        configuration.profile.validate()?;
        let expected_epoch = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?
            .configuration_epoch
            .clone();
        configuration.confirm(true)?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        self.require_admission()?;
        if !Arc::ptr_eq(&expected_epoch, &inner.configuration_epoch) {
            return Err(invalid(
                "A newer connection configuration already took effect; this completion was not applied",
            ));
        }
        inner.store.require_certain()?;
        if let Some(error) = &inner.fatal {
            return Err(invalid(error.clone()));
        }
        let current = self
            .configuration()
            .ok_or_else(|| invalid("This session has no bound connection"))?;
        if !current.same_route(&configuration) || !current.compatible_authority(&configuration) {
            return Err(invalid(
                "Changed connection, API, endpoint or model requires a separately bound session",
            ));
        }
        configuration.check()?;
        inner.configuration_epoch = Arc::new(());
        if inner.worker_running {
            inner.pending_configuration = Some(configuration);
            self.pending_settings.store(true, Ordering::Release);
            self.publish(&inner);
            return Ok(false);
        }
        *self
            .config
            .write()
            .map_err(|_| invalid("Connection is unavailable"))? = Some(configuration);
        self.configuration_generation.fetch_add(1, Ordering::AcqRel);
        self.publish(&inner);
        Ok(true)
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub(crate) fn test_has_active_worker(&self) -> bool {
        // The atomic can clear before the terminal snapshot is published under
        // this mutex. Test callers treating false as settled must cross that
        // publication barrier. This is not a physical worker/task join.
        let _publication = self.inner.lock().expect("session mutex poisoned");
        self.worker_active.load(Ordering::Acquire)
    }
    /// Captures final accepted evidence directly, including after worker joins.
    pub fn read_observation(&self) -> crate::read_observation::AcceptedReadObservation {
        self.inner
            .lock()
            .expect("session mutex poisoned")
            .store
            .read_observation()
    }
    /// Nonblocking last publication for rendering; use read_observation after
    /// joins/admission when the exact latest accepted actor boundary is needed.
    pub fn published_read_observation(&self) -> crate::read_observation::AcceptedReadObservation {
        self.accepted_read.borrow().clone()
    }
    pub fn subscribe_read_observation(
        &self,
    ) -> tokio::sync::watch::Receiver<crate::read_observation::AcceptedReadObservation> {
        self.accepted_read.subscribe()
    }
    pub fn revision(&self) -> u64 {
        self.published_revision.load(Ordering::Acquire)
    }
    /// Small revocation publication; no actor mutex, filesystem or transcript clone.
    pub fn search_source_witness(&self) -> crate::source_admission::SourceWitness {
        if self.inner.is_poisoned() {
            self.source_witness.unavailable();
        }
        self.source_witness.clone()
    }
    /// Capture raw accepted state under the actor lock. Run on a background
    /// worker: it can wait for persistence and clone a large history. This is
    /// search-content evidence only, never runtime, membership or tool authority.
    pub fn loaded_search_source(
        &self,
    ) -> std::result::Result<
        crate::source_admission::LoadedSourceSnapshot,
        crate::source_admission::SourceUnavailable,
    > {
        let source = {
            let inner = self.inner.lock().map_err(|_| {
                self.source_witness.unavailable();
                crate::source_admission::SourceUnavailable
            })?;
            if self.is_retired() {
                return Err(crate::source_admission::SourceUnavailable);
            }
            inner.store.capture_search_source()?
        };
        #[cfg(test)]
        SOURCE_CAPTURE_HOOK.with(|hook| {
            if let Some(hook) = hook.borrow_mut().as_mut() {
                hook();
            }
        });
        if self.is_retired() || !source.is_current() {
            return Err(crate::source_admission::SourceUnavailable);
        }
        Ok(source)
    }
    pub fn snapshot(&self) -> Session {
        (*self.snapshot_shared()).clone()
    }
    /// UI reads never take the persistence/actor mutex or wait for fsync.
    pub fn snapshot_shared(&self) -> Arc<Session> {
        self.published.borrow().clone()
    }
    /// Clone a complete, atomically paired Find snapshot without the actor lock.
    /// Poisoned publication has no usable content evidence; never mix with legacy data.
    pub fn find_snapshot(&self) -> Option<crate::FindSnapshot> {
        self.find_published
            .read()
            .ok()
            .map(|snapshot| snapshot.clone())
    }
    pub fn subscribe(&self) -> tokio::sync::watch::Receiver<Arc<Session>> {
        self.published.subscribe()
    }
    fn display_snapshot(&self, inner: &Inner) -> Session {
        let mut snapshot = inner.store.snapshot();
        // Only current, unfenced invocation state is eligible for display.
        if !self.is_retired()
            && !self.stop_requested.load(Ordering::Acquire)
            && inner
                .cancel
                .as_ref()
                .is_none_or(|cancel| !cancel.is_cancelled())
        {
            snapshot.live_tools = inner
                .live_tools
                .iter()
                .filter(|view| {
                    snapshot.active_reply.as_deref() == Some(&view.assistant_id)
                        && snapshot
                            .active_tool_calls()
                            .is_some_and(|calls| calls.iter().any(|call| call.id == view.call_id))
                })
                .cloned()
                .collect();
        }
        if let Some(error) = &inner.fatal {
            snapshot.error = Some(error.clone());
            snapshot.state = RunState::Error;
            snapshot.queue_paused = true;
        }
        snapshot
    }
    fn publish(&self, inner: &Inner) {
        let observation = inner.store.read_observation();
        self.accepted_read.send_if_modified(|current| {
            if *current == observation {
                return false;
            }
            *current = observation;
            true
        });
        let stop = self.stop_epoch.load(Ordering::Acquire);
        self.publish_prepared(self.prepare_find_publication(inner), stop, false);
    }
    fn publish_live(&self, inner: &Inner, stop: u64) {
        self.publish_prepared(self.prepare_find_publication(inner), stop, true);
    }
    fn prepare_find_publication(&self, inner: &Inner) -> PreparedFindPublication {
        PreparedFindPublication {
            session: self.display_snapshot(inner),
            token: inner.store.find_token(),
        }
    }
    fn publish_prepared(&self, prepared: PreparedFindPublication, stop: u64, live_only: bool) {
        let PreparedFindPublication { mut session, token } = prepared;
        // All preparation is outside the watch critical section. Generic queue
        // or durable publications can race Stop too: they still publish required
        // state but must strip a live preview prepared before the fence.
        let mut hold_changed = false;
        if self.published.send_if_modified(|current| {
            if self.is_retired()
                || self.stop_requested.load(Ordering::Acquire)
                || self.stop_epoch.load(Ordering::Acquire) != stop
            {
                if live_only {
                    return false;
                }
                session.live_tools.clear();
            }
            hold_changed =
                semantic_activity::run_hold(current) != semantic_activity::run_hold(&session);
            // Lock order is legacy watch -> paired publication. No accessor holds
            // a paired guard or acquires the legacy watch under this lock.
            let Ok(mut paired) = self.find_published.write() else {
                return false;
            };
            let snapshot = Arc::new(session);
            *paired = crate::FindSnapshot::new(snapshot.clone(), token);
            *current = snapshot;
            true
        }) {
            self.published_revision.fetch_add(1, Ordering::Release);
            if hold_changed {
                self.note_semantic_activity();
            }
        }
    }
    fn worker_finished(&self, inner: &mut Inner) {
        let configured = if let Some(configuration) = inner.pending_configuration.take() {
            *self.config.write().expect("configuration lock poisoned") = Some(configuration);
            self.configuration_generation.fetch_add(1, Ordering::AcqRel);
            true
        } else {
            false
        };
        self.pending_settings.store(false, Ordering::Release);
        inner.worker_running = false;
        inner.cancel = None;
        self.worker_active
            .store(inner.compaction_pending, Ordering::Release);
        *self
            .active_cancel
            .write()
            .expect("cancellation lock poisoned") = None;
        if configured {
            self.publish(inner);
        }
    }
    /// A published completed reply can outlive its worker by one queue-scan
    /// iteration. Late Stop/retirement must not create a durable pause for that
    /// empty tail. Keep any intentional pause/error and all transcript bytes;
    /// unfinished or accepted queued work still takes the cancellation path.
    fn settle_empty_completed_tail(&self, inner: &mut Inner) -> bool {
        let session = inner.store.snapshot_ref();
        if session.state != RunState::Idle
            || !session.pending.is_empty()
            || session.active.is_some()
            || session.active_reply.is_some()
            || session.edit.is_some()
            || session.retry.is_some()
        {
            return false;
        }
        self.worker_finished(inner);
        self.stop_requested.store(false, Ordering::Release);
        self.publish(inner);
        true
    }

    pub fn submit(self: &Arc<Self>, text: String, lane: Lane) -> Result<()> {
        self.submit_identified(Submission::new(text, lane))
    }
    pub fn submit_identified(self: &Arc<Self>, mut item: Submission) -> Result<()> {
        if !item.attachments.is_empty() || !item.frozen_skills.is_empty() {
            return Err(invalid(
                "Image submissions require asynchronous attachment preparation",
            ));
        }
        let confirmed = self.confirm_resources()?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        self.require_confirmed_admission(&inner, &confirmed)?;
        if let Some(error) = &inner.fatal {
            return Err(invalid(error.clone()));
        }
        inner.store.require_certain()?;
        if self.authority.is_some() && !inner.store.is_persistent() {
            return Err(invalid(
                "Materialize this saved chat with its durable submission receipt before sending",
            ));
        }
        let config = self.configuration().ok_or_else(|| invalid("No connection configured. Launch with --profile and --credential-stdin; no credentials are discovered automatically."))?;
        item.model = Some(config.profile.model_id.clone());
        item.effort = Some(config.profile.thinking_level.clone());
        inner.store.transact(|session| session.submit(item))?;
        self.note_semantic_activity();
        self.publish(&inner);
        self.launch(&mut inner, None);
        Ok(())
    }
    pub fn stop(&self) -> Result<()> {
        self.stop_with_epoch().map(|_| ())
    }
    fn stop_with_epoch(&self) -> Result<u64> {
        let epoch = self
            .stop_epoch
            .fetch_add(1, Ordering::AcqRel)
            .wrapping_add(1);
        self.attachment_jobs.cancel();
        if let Some(tools) = &self.options.tools {
            tools.native.cancel_processes();
        }
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
        // Any live publication that won the watch lock happened before this
        // barrier; a later one rechecks stop_epoch under that lock and refuses.
        // No persistence or process wait is performed while this lock is held.
        drop(self.published.borrow());
        Ok(epoch)
    }
    /// Permanently reject new commands and worker continuations on this controller.
    /// This synchronous fence never releases its SessionStore ownership. Already
    /// admitted work may settle; retire_and_wait releases the writer only after
    /// every worker successfully joins, even when stale Arcs still exist.
    pub fn retire(&self) -> Result<()> {
        self.source_witness.retire();
        self.retired.store(true, Ordering::Release);
        let stopped = self.stop();
        // Admission, checkpointing, reservation and handle registration share the
        // actor lock. Cross that barrier after fencing, so no admitted launch can
        // register behind the join snapshot. Never hold it while awaiting a task.
        let admitted = self
            .inner
            .lock()
            .map(|_| ())
            .map_err(|_| invalid("Session is unavailable"));
        stopped.and(admitted)
    }
    pub fn is_retired(&self) -> bool {
        self.retired.load(Ordering::Acquire)
    }
    /// Joins workers, then waits for temporary idle-admission owners before
    /// releasing the writer. Drop or seal your own IdleAdmissionGuard before
    /// awaiting this method; retaining it intentionally keeps the writer leased.
    pub async fn retire_and_wait(&self) -> Result<()> {
        let retired = self.retire();
        // Even a cancellation failure must not skip joining an owned worker.
        let joined = self.join_workers().await;
        joined?;
        retired?;
        self.attachment_jobs.join().await?;
        if let Some(tools) = &self.options.tools {
            tools.native.join_processes().await?;
        }
        self.wait_for_idle_guard_release().await;
        self.inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?
            .store
            .retire_writer();
        Ok(())
    }
    /// Cancel and await existing workers, retaining admission for ordinary
    /// window close/reopen. Callers must prevent new commands during shutdown.
    /// Permanent replacement instead requires retire_and_wait.
    pub async fn shutdown(&self) -> Result<()> {
        let stopped = self.stop();
        // Include already-admitted commands still checkpointing/registering.
        let admitted = self
            .inner
            .lock()
            .map(|_| ())
            .map_err(|_| invalid("Session is unavailable"));
        let stopped_after_admission = self.stop();
        // A failed stop/barrier must not abandon a still-owned worker handle.
        self.join_workers().await?;
        self.attachment_jobs.join().await?;
        if let Some(tools) = &self.options.tools {
            tools.native.join_processes().await?;
        }
        {
            let inner = self
                .inner
                .lock()
                .map_err(|_| invalid("Session is unavailable"))?;
            // Stop may observe an active worker just before its final exit and
            // set the flag just after worker_finished. A joined idle generation
            // must not carry that late flag into an explicit reopen/Resume.
            if !inner.worker_running {
                self.stop_requested.store(false, Ordering::Release);
            }
        }
        stopped.and(admitted).and(stopped_after_admission)
    }
    async fn join_workers(&self) -> Result<()> {
        let joins = {
            // Lock order is actor -> worker -> joins; no lock crosses await.
            let mut worker = self
                .worker
                .lock()
                .map_err(|_| invalid("Worker is unavailable"))?;
            let mut joins = self
                .worker_joins
                .lock()
                .map_err(|_| invalid("Worker is unavailable"))?;
            if let Some(worker) = worker.take() {
                Self::remember_worker(&mut joins, worker);
            }
            joins.clone()
        };
        // A caller dropping this future cannot detach or consume the only join.
        // Concurrent callers see the same result, including a worker panic.
        let results = join_all(joins.iter().map(|(_, join)| join.clone())).await;
        self.worker_joins
            .lock()
            .map_err(|_| invalid("Worker is unavailable"))?
            .retain(|(id, _)| {
                !joins
                    .iter()
                    .zip(&results)
                    .any(|((joined, _), result)| id == joined && result.is_ok())
            });
        for result in results {
            result.map_err(invalid)?;
        }
        Ok(())
    }
    fn remember_worker(
        joins: &mut Vec<(tokio::task::Id, WorkerJoin)>,
        worker: tokio::task::JoinHandle<()>,
    ) {
        // Polling a completed join is nonblocking. Keep errors and unfinished
        // tails; errors remain sticky, while successful old tails can be freed.
        joins.retain(|(_, join)| !matches!(join.clone().now_or_never(), Some(Ok(()))));
        let id = worker.id();
        let joined = async move {
            worker
                .await
                .map_err(|_| "Session worker terminated unexpectedly".to_owned())
        }
        .boxed()
        .shared();
        if !matches!(joined.clone().now_or_never(), Some(Ok(()))) {
            joins.push((id, joined));
        }
    }
    pub fn resume(self: &Arc<Self>) -> Result<()> {
        self.require_config()?;
        #[cfg(feature = "synthetic-authority")]
        if self.resources.is_some() {
            return self.resume_with_resources();
        }
        self.change_and_launch(|session| session.resume().map(|()| None))
    }
    pub fn retry(self: &Arc<Self>) -> Result<()> {
        self.require_config()?;
        #[cfg(feature = "synthetic-authority")]
        if self.resources.is_some() {
            return self.retry_with_resources();
        }
        self.change_and_launch(|session| session.retry_turn().map(Some))
    }
    /// Recovery reads serialize with edits and commits. Published snapshots may
    /// remain stale after an uncertain write and are never used for this answer.
    pub fn edit_status(&self, edit_id: &str) -> Result<QueueEditStatus> {
        let inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        self.require_admission()?;
        if let Some(error) = &inner.fatal {
            return Err(invalid(error.clone()));
        }
        inner.store.edit_status(edit_id)
    }
    pub fn begin_edit(&self, turn_id: &str, edit_id: &str) -> Result<String> {
        self.change(|s| s.begin_edit(turn_id, edit_id))
    }
    /// Cancel one edit against certain actor state. Only releasing this exact
    /// active hold may reserve an idle queue worker; tombstones and previously
    /// resolved identities never start pending work.
    pub fn cancel_edit_certain(
        self: &Arc<Self>,
        edit_id: &str,
        turn_id: &str,
    ) -> Result<QueueEditStatus> {
        let confirmed = self.confirm_resources()?;
        {
            let mut inner = self
                .inner
                .lock()
                .map_err(|_| invalid("Session is unavailable"))?;
            self.require_confirmed_admission(&inner, &confirmed)?;
            if let Some(error) = &inner.fatal {
                return Err(invalid(error.clone()));
            }
            inner.store.require_certain()?;
            if turn_id.is_empty() || turn_id.len() > 128 {
                return Err(invalid("Invalid held turn identity"));
            }
            let status = inner.store.edit_status(edit_id)?;
            let released_hold = match &status.state {
                QueueEditState::Active { turn_id: held, .. } => {
                    if held != turn_id {
                        return Err(invalid("This queued edit belongs to another turn"));
                    }
                    true
                }
                QueueEditState::Unknown => false,
                QueueEditState::Saved { .. }
                | QueueEditState::Cancelled
                | QueueEditState::Removed => return Ok(status),
            };
            inner
                .store
                .transact(|session| session.resolve_edit(edit_id, "cancelled", None))?;
            let status = inner.store.edit_status(edit_id)?;
            self.publish(&inner);
            let snapshot = inner.store.snapshot();
            let launch = released_hold
                && self.configuration().is_some()
                && !inner.worker_running
                && snapshot.state == RunState::Idle
                && !snapshot.queue_paused
                && snapshot.edit.is_none()
                && !snapshot.pending.is_empty();
            if launch {
                self.launch(&mut inner, None);
            }
            Ok(status)
        }
    }
    pub fn resolve_edit(
        self: &Arc<Self>,
        edit_id: &str,
        outcome: &str,
        text: Option<&str>,
    ) -> Result<()> {
        self.change_and_launch_activity(|session| {
            // Only the first accepted Save is activity, even if its text is
            // unchanged. Replaying a resolved identity is an acknowledgment.
            let saved = outcome == "saved"
                && session
                    .edit
                    .as_ref()
                    .is_some_and(|edit| edit.edit_id == edit_id);
            session.resolve_edit(edit_id, outcome, text)?;
            Ok((None, saved))
        })
    }
    pub fn remove(self: &Arc<Self>, id: &str) -> Result<()> {
        self.change_and_launch(|session| session.remove(id).map(|()| None))
    }
    pub fn reorder(&self, ids: &[String]) -> Result<()> {
        self.change(|s| s.reorder(ids))
    }
    /// Rename Chat…: persist a reader-chosen, already normalized title in
    /// this chat's own checkpoint, from which the sidebar and catalog follow.
    pub fn rename(&self, title: &str) -> Result<()> {
        self.change(|session| {
            session.title = title.to_owned();
            Ok(())
        })
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
    fn require_admission(&self) -> Result<()> {
        if self.is_retired() {
            return Err(invalid("This session controller is permanently retired"));
        }
        if self.admission_suspension.load(Ordering::Acquire) != 0 {
            return Err(invalid(
                "Chat admission is suspended while project configuration changes.",
            ));
        }
        self.check_resources()?;
        if let Some(config) = self.configuration() {
            config.check()?;
        }
        Ok(())
    }
    fn require_config(&self) -> Result<()> {
        self.require_admission()?;
        if self.configuration().is_none() {
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
        let confirmed = self.confirm_resources()?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        self.require_confirmed_admission(&inner, &confirmed)?;
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
    fn change_and_launch(
        self: &Arc<Self>,
        action: impl FnOnce(&mut Session) -> Result<Option<Submission>>,
    ) -> Result<()> {
        self.change_and_launch_activity(|session| action(session).map(|first| (first, false)))
    }
    fn change_and_launch_activity(
        self: &Arc<Self>,
        action: impl FnOnce(&mut Session) -> Result<(Option<Submission>, bool)>,
    ) -> Result<()> {
        let confirmed = self.confirm_resources()?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        self.require_confirmed_admission(&inner, &confirmed)?;
        if let Some(error) = &inner.fatal {
            return Err(invalid(error.clone()));
        }
        inner.store.require_certain()?;
        if inner.compaction_pending {
            return Err(invalid(
                "Compaction is waiting for the current run to stop. Try this action after it settles; queued input is retained.",
            ));
        }
        let (first, activity) = inner.store.transact(action)?;
        if activity {
            self.note_semantic_activity();
        }
        self.publish(&inner);
        self.launch(&mut inner, first);
        Ok(())
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
    /// The caller has admitted its command and still owns the actor lock.
    /// A concurrent retirement joins even a worker registered after its fence;
    /// that worker sees retirement before it can start any external request.
    fn launch(self: &Arc<Self>, inner: &mut Inner, first: Option<Submission>) {
        if self.configuration().is_none()
            || inner.worker_running
            || inner.compaction_pending
            || inner.fatal.is_some()
        {
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
        inner.live_tools.clear();
        inner.worker_epoch = Arc::new(());
        self.worker_active.store(true, Ordering::Release);
        let mut worker = self.worker.lock().expect("worker handle lock poisoned");
        if let Some(previous) = worker.take() {
            Self::remember_worker(
                &mut self
                    .worker_joins
                    .lock()
                    .expect("worker joins lock poisoned"),
                previous,
            );
        }
        let this = Arc::clone(self);
        *worker = Some(self.runtime.spawn(async move {
            this.run(first).await;
        }));
    }
    async fn run(self: Arc<Self>, first: Option<Submission>) {
        #[cfg(feature = "synthetic-authority")]
        if self.resources.is_some() {
            self.run_with_resources(first).await;
            return;
        }
        self.run_with_images(first).await;
    }

    // Defaults remain inert. Synthetic confirmation may inspect fixture paths
    // and therefore must be called before acquiring the actor mutex.
    fn confirm_resources(&self) -> Result<AdmissionConfirmation> {
        let confirmed = {
            let inner = self
                .inner
                .lock()
                .map_err(|_| invalid("Session is unavailable"))?;
            let configuration = self.configuration();
            let saved_active = inner.worker_running
                && configuration
                    .as_ref()
                    .is_some_and(|config| config.has_saved_connection());
            AdmissionConfirmation {
                configuration,
                active_epoch: saved_active.then(|| inner.worker_epoch.clone()),
            }
        };
        if let Some(authority) = &self.authority {
            authority.confirm()?;
        }
        #[cfg(feature = "synthetic-authority")]
        if let Some(resources) = &self.resources {
            resources.guard.confirm()?;
        }
        if let Some(config) = &confirmed.configuration {
            config.confirm(confirmed.active_epoch.is_none())?;
        }
        Ok(confirmed)
    }
    fn require_confirmed_admission(
        &self,
        inner: &Inner,
        confirmed: &AdmissionConfirmation,
    ) -> Result<()> {
        self.require_admission()?;
        let current = self.configuration();
        let same_configuration = match (&confirmed.configuration, &current) {
            (Some(left), Some(right)) => Arc::ptr_eq(left, right),
            (None, None) => true,
            _ => false,
        };
        if !same_configuration
            || confirmed.active_epoch.as_ref().is_some_and(|epoch| {
                !inner.worker_running || !Arc::ptr_eq(epoch, &inner.worker_epoch)
            })
        {
            return Err(invalid(
                "The run or connection changed while confirming. Your input was not accepted; try again with the current settings",
            ));
        }
        Ok(())
    }
    async fn confirm_runtime_authority(&self, cancel: CancellationToken) -> Result<()> {
        let Some(authority) = &self.authority else {
            return Ok(());
        };
        let authority = authority.clone();
        crate::tools::BlockingWorkExecutor::shared()
            .run(cancel, move |_| Ok(authority.confirm()))
            .await
            .map_err(|error| invalid(error.to_string()))??;
        self.check_resources()
    }

    fn check_resources(&self) -> Result<()> {
        if let Some(authority) = &self.authority {
            authority.check()?;
        }
        #[cfg(feature = "synthetic-authority")]
        if let Some(resources) = &self.resources {
            return resources.guard.check();
        }
        Ok(())
    }
}

pub(crate) fn shared_runtime() -> Result<&'static tokio::runtime::Runtime> {
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
    use crate::{Error, QueueEditState, session::WriteFault};
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

    #[cfg(feature = "synthetic-authority")]
    #[test]
    fn test_worker_observation_crosses_the_terminal_publication_barrier() {
        let dir = tempfile::tempdir().unwrap();
        let controller = Controller::new(
            SessionStore::open(dir.path().join("session.json")).unwrap(),
            None,
        )
        .unwrap();
        let before = controller.snapshot_shared().title.clone();
        let mut inner = controller.inner.lock().unwrap();
        inner.worker_running = true;
        controller.worker_active.store(true, Ordering::Release);
        inner
            .store
            .transact(|session| {
                session.title = "terminal checkpoint published".into();
                Ok(())
            })
            .unwrap();
        controller.worker_finished(&mut inner);
        assert!(!controller.worker_active.load(Ordering::Acquire));
        assert_eq!(controller.snapshot_shared().title, before);
        let (started, start) = std::sync::mpsc::channel();
        let (sent, result) = std::sync::mpsc::channel();
        let observer = controller.clone();
        let reader = std::thread::spawn(move || {
            started.send(()).unwrap();
            let active = observer.test_has_active_worker();
            sent.send((active, observer.snapshot_shared().title.clone()))
                .unwrap();
        });
        start.recv_timeout(Duration::from_secs(3)).unwrap();
        // Hold the real final-publication boundary. This timeout is only a
        // bounded test observation, never a delay added to worker settlement.
        let early = result.recv_timeout(Duration::from_millis(100));
        controller.publish(&inner);
        drop(inner);
        let observed =
            early.unwrap_or_else(|_| result.recv_timeout(Duration::from_secs(3)).unwrap());
        reader.join().unwrap();
        assert_eq!(
            observed,
            (false, "terminal checkpoint published".into()),
            "idle observation escaped before its terminal snapshot was published"
        );
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

    fn configured_fixture(store: SessionStore) -> (Arc<Controller>, std::net::TcpListener) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let profile: Profile = serde_json::from_value(serde_json::json!({
            "id":"certain-cancel-fixture", "api":"openai-responses", "providerId":"litellm",
            "modelId":"local-fixture", "baseUrl":format!("http://{}", listener.local_addr().unwrap()),
            "contextWindow":32000, "maxOutputTokens":4096
        })).unwrap();
        let controller = Controller::new(
            store,
            Some((profile, Credential::new("fixture-only".into()).unwrap())),
        )
        .unwrap();
        (controller, listener)
    }

    fn assert_never_launched(controller: &Controller, listener: &std::net::TcpListener) {
        assert!(!controller.inner.lock().unwrap().worker_running);
        assert!(!controller.worker_active.load(Ordering::Acquire));
        assert!(controller.worker.lock().unwrap().is_none());
        assert!(controller.active_cancel.read().unwrap().is_none());
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
    }

    async fn complete_fixture(socket: &mut TcpStream) {
        timeout(DEADLINE, async {
            socket.write_all(concat!(
                "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
                "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}]}}\n\n"
            ).as_bytes()).await.unwrap();
            socket.shutdown().await.unwrap();
        })
        .await
        .expect("fixture completion timed out");
    }

    #[test]
    fn cancel_edit_certain_terminal_is_read_only_with_configured_idle_pending_work() {
        for outcome in ["saved", "cancelled", "removed"] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("session.json");
            let mut store = SessionStore::open(&path).unwrap();
            let turn = Submission::new("original".into(), Lane::FollowUp);
            store
                .transact(|session| {
                    session.submit(turn.clone())?;
                    session.submit(Submission::new("still pending".into(), Lane::FollowUp))?;
                    session.begin_edit(&turn.id, "edit")?;
                    session.resolve_edit(
                        "edit",
                        outcome,
                        (outcome == "saved").then_some("saved text"),
                    )
                })
                .unwrap();
            let (controller, listener) = configured_fixture(store);
            let authoritative = controller.edit_status("edit").unwrap();
            let cached = controller.snapshot_shared();
            let bytes = retained_files(dir.path());
            let revision = controller.revision();
            let updates = controller.subscribe();
            assert_eq!(cached.state, RunState::Idle);
            assert!(!cached.pending.is_empty());
            assert!(!cached.queue_paused);
            for _ in 0..2 {
                assert_eq!(
                    controller.cancel_edit_certain("edit", &turn.id).unwrap(),
                    authoritative
                );
                assert_eq!(retained_files(dir.path()), bytes);
                assert_eq!(controller.revision(), revision);
                assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
                assert!(!updates.has_changed().unwrap());
                assert_never_launched(&controller, &listener);
            }
        }
    }

    #[test]
    fn cancel_edit_certain_unknown_fences_begin_once_without_releasing_or_dispatching() {
        for other_hold in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("session.json");
            let mut store = SessionStore::open(&path).unwrap();
            let turn = Submission::new("untouched original".into(), Lane::FollowUp);
            store
                .transact(|session| {
                    session.submit(turn.clone())?;
                    if other_hold {
                        session.begin_edit(&turn.id, "other-edit")?;
                    }
                    Ok(())
                })
                .unwrap();
            let (controller, listener) = configured_fixture(store);
            let before = controller.snapshot_shared();
            let mut updates = controller.subscribe();
            let status = controller
                .cancel_edit_certain("delayed-edit", &turn.id)
                .unwrap();
            assert_eq!(status.state, QueueEditState::Cancelled);
            assert_eq!(status.current_hold, before.edit);
            assert_eq!(status.session_revision, before.revision + 1);
            assert_eq!(controller.revision(), 1);
            assert!(updates.has_changed().unwrap());
            updates.borrow_and_update();
            assert_eq!(
                controller.snapshot_shared().pending[0].text,
                "untouched original"
            );
            assert_never_launched(&controller, &listener);
            let bytes = retained_files(dir.path());
            let cached = controller.snapshot_shared();
            assert_eq!(
                controller
                    .cancel_edit_certain("delayed-edit", &turn.id)
                    .unwrap(),
                status
            );
            assert!(controller.begin_edit(&turn.id, "delayed-edit").is_err());
            assert_eq!(retained_files(dir.path()), bytes);
            assert_eq!(controller.revision(), 1);
            assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
            assert!(!updates.has_changed().unwrap());
            assert_never_launched(&controller, &listener);
        }
    }

    #[test]
    fn cancel_edit_certain_wrong_turn_invalid_identities_and_fatal_never_mutate() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let (controller, turn_id) = held_controller(&path);
        let bytes = retained_files(dir.path());
        let cached = controller.snapshot_shared();
        let revision = controller.revision();
        let updates = controller.subscribe();
        for (edit, turn) in [
            ("edit".into(), "wrong-turn".into()),
            (String::new(), turn_id.clone()),
            ("x".repeat(129), turn_id.clone()),
            ("edit".into(), String::new()),
            ("unknown".into(), "x".repeat(129)),
        ] {
            assert!(controller.cancel_edit_certain(&edit, &turn).is_err());
        }
        controller.inner.lock().unwrap().fatal = Some("fatal fixture".into());
        for edit in ["edit", "unknown"] {
            assert!(controller.cancel_edit_certain(edit, &turn_id).is_err());
        }
        assert_eq!(retained_files(dir.path()), bytes);
        assert_eq!(controller.revision(), revision);
        assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
        assert!(!updates.has_changed().unwrap());
        assert!(controller.worker.lock().unwrap().is_none());
    }

    #[test]
    fn cancel_edit_certain_without_configuration_commits_but_never_launches() {
        let dir = tempfile::tempdir().unwrap();
        let (controller, turn_id) = held_controller(&dir.path().join("session.json"));
        let before = controller.snapshot_shared();
        let status = controller.cancel_edit_certain("edit", &turn_id).unwrap();
        assert_eq!(status.state, QueueEditState::Cancelled);
        assert_eq!(status.session_revision, before.revision + 1);
        assert!(status.current_hold.is_none());
        assert_eq!(
            controller.snapshot_shared().pending[0].text,
            before.pending[0].text
        );
        assert!(!controller.inner.lock().unwrap().worker_running);
        assert!(controller.worker.lock().unwrap().is_none());
        let pending = Controller::new(SessionStore::pending(), None).unwrap();
        let cached = pending.snapshot_shared();
        assert!(pending.cancel_edit_certain("unknown", "turn").is_err());
        assert!(Arc::ptr_eq(&cached, &pending.snapshot_shared()));
        assert_eq!(pending.revision(), 0);
    }

    #[tokio::test]
    async fn cancel_edit_certain_active_idle_release_dispatches_exactly_once() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = SessionStore::open(dir.path().join("session.json")).unwrap();
        let turn = Submission::new("released original".into(), Lane::FollowUp);
        store
            .transact(|session| {
                session.submit(turn.clone())?;
                session.begin_edit(&turn.id, "edit")?;
                Ok(())
            })
            .unwrap();
        let before = store.snapshot_revision();
        let (controller, listener) = configured_fixture(store);
        let accepts = TcpListener::from_std(listener.try_clone().unwrap()).unwrap();
        let status = controller.cancel_edit_certain("edit", &turn.id).unwrap();
        assert_eq!(status.state, QueueEditState::Cancelled);
        assert_eq!(status.session_revision, before + 1);
        assert!(status.current_hold.is_none());
        let (mut socket, _) = timeout(DEADLINE, accepts.accept()).await.unwrap().unwrap();
        let request = read_fixture_request(&mut socket).await;
        assert_eq!(
            request["input"][0]["content"][0]["text"],
            "released original"
        );
        let worker_id = controller.worker.lock().unwrap().as_ref().unwrap().id();
        let cancel = controller.active_cancel.read().unwrap().clone().unwrap();
        let cached = controller.snapshot_shared();
        let bytes = retained_files(dir.path());
        let revision = controller.revision();
        assert_eq!(
            controller
                .cancel_edit_certain("edit", &turn.id)
                .unwrap()
                .state,
            QueueEditState::Cancelled
        );
        assert_eq!(
            controller.worker.lock().unwrap().as_ref().unwrap().id(),
            worker_id
        );
        assert!(!cancel.is_cancelled());
        assert_eq!(retained_files(dir.path()), bytes);
        assert_eq!(controller.revision(), revision);
        assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
        complete_fixture(&mut socket).await;
        await_session(&controller, |session| {
            session.state == RunState::Idle && session.pending.is_empty()
        })
        .await;
        timeout(DEADLINE, controller.shutdown())
            .await
            .unwrap()
            .unwrap();
        assert!(!controller.inner.lock().unwrap().worker_running);
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
        assert_eq!(
            controller
                .snapshot_shared()
                .messages
                .iter()
                .filter(|message| message.role == "user")
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn cancel_edit_certain_keeps_gated_worker_until_its_normal_queue_boundary() {
        let dir = tempfile::tempdir().unwrap();
        let (controller, listener) =
            configured_fixture(SessionStore::open(dir.path().join("session.json")).unwrap());
        let accepts = TcpListener::from_std(listener.try_clone().unwrap()).unwrap();
        controller
            .submit("first gated request".into(), Lane::FollowUp)
            .unwrap();
        let (mut first, _) = timeout(DEADLINE, accepts.accept()).await.unwrap().unwrap();
        read_fixture_request(&mut first).await;
        let turn = Submission::new("queued original".into(), Lane::FollowUp);
        controller.submit_identified(turn.clone()).unwrap();
        controller.begin_edit(&turn.id, "edit").unwrap();
        let worker_id = controller.worker.lock().unwrap().as_ref().unwrap().id();
        let cancel = controller.active_cancel.read().unwrap().clone().unwrap();
        let status = controller.cancel_edit_certain("edit", &turn.id).unwrap();
        assert_eq!(status.state, QueueEditState::Cancelled);
        assert!(status.current_hold.is_none());
        assert_eq!(controller.snapshot_shared().state, RunState::Running);
        assert_eq!(controller.snapshot_shared().pending[0].id, turn.id);
        assert_eq!(
            controller.worker.lock().unwrap().as_ref().unwrap().id(),
            worker_id
        );
        assert!(controller.inner.lock().unwrap().worker_running);
        assert!(!cancel.is_cancelled());
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
        complete_fixture(&mut first).await;
        let (mut second, _) = timeout(DEADLINE, accepts.accept()).await.unwrap().unwrap();
        let request = read_fixture_request(&mut second).await;
        assert!(
            request["input"]
                .as_array()
                .unwrap()
                .iter()
                .any(|message| message["role"] == "user"
                    && message["content"][0]["text"] == "queued original")
        );
        assert_eq!(
            controller.worker.lock().unwrap().as_ref().unwrap().id(),
            worker_id
        );
        complete_fixture(&mut second).await;
        await_session(&controller, |session| {
            session.state == RunState::Idle && session.pending.is_empty()
        })
        .await;
        timeout(DEADLINE, controller.shutdown())
            .await
            .unwrap()
            .unwrap();
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
        assert_eq!(
            controller
                .snapshot_shared()
                .messages
                .iter()
                .filter(|message| message.role == "user")
                .count(),
            2
        );
    }

    #[test]
    fn cancel_edit_certain_paused_reopened_and_error_queues_never_dispatch() {
        for mode in ["paused", "paused-flag", "reopened", "error-unpaused"] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("session.json");
            let mut store = SessionStore::open(&path).unwrap();
            let turn = Submission::new("original".into(), Lane::FollowUp);
            store
                .transact(|session| {
                    session.submit(turn.clone())?;
                    session.begin_edit(&turn.id, "edit")?;
                    match mode {
                        "paused" => {
                            session.state = RunState::Paused;
                            session.queue_paused = false;
                        }
                        "paused-flag" => {
                            session.queue_paused = true;
                        }
                        "error-unpaused" => {
                            session.state = RunState::Error;
                            session.queue_paused = false;
                            session.error = Some("retained failure".into());
                        }
                        _ => {}
                    }
                    Ok(())
                })
                .unwrap();
            if mode == "reopened" {
                drop(store);
                store = SessionStore::open(&path).unwrap();
                assert_eq!(store.snapshot().state, RunState::Paused);
                assert!(store.snapshot().queue_paused);
            }
            let (controller, listener) = configured_fixture(store);
            let before = controller.snapshot_shared();
            let status = controller.cancel_edit_certain("edit", &turn.id).unwrap();
            assert_eq!(status.state, QueueEditState::Cancelled);
            assert!(status.current_hold.is_none());
            assert_eq!(controller.snapshot_shared().state, before.state);
            assert_eq!(
                controller.snapshot_shared().queue_paused,
                before.queue_paused
            );
            assert_eq!(controller.snapshot_shared().pending[0].text, "original");
            assert_never_launched(&controller, &listener);
        }
    }

    #[test]
    fn cancel_edit_certain_real_pre_and_post_rename_failures_fence_all_further_actions() {
        for active in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("session.json");
            let mut store = SessionStore::open(&path).unwrap();
            let turn = Submission::new("original".into(), Lane::FollowUp);
            store
                .transact(|session| {
                    session.submit(turn.clone())?;
                    if active {
                        session.begin_edit(&turn.id, "edit")?;
                    }
                    Ok(())
                })
                .unwrap();
            let (controller, listener) = configured_fixture(store);
            let cached = controller.snapshot_shared();
            let bytes = std::fs::read(&path).unwrap();
            let updates = controller.subscribe();
            controller.inner.lock().unwrap().store.fault = WriteFault::BeforeRename;
            assert!(controller.cancel_edit_certain("edit", &turn.id).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
            assert_eq!(
                controller.edit_status("edit").unwrap().state,
                if active {
                    QueueEditState::Active {
                        turn_id: turn.id.clone(),
                        text: "original".into(),
                    }
                } else {
                    QueueEditState::Unknown
                }
            );
            assert_eq!(controller.revision(), 0);
            assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
            assert!(!updates.has_changed().unwrap());
            assert_never_launched(&controller, &listener);
            controller.inner.lock().unwrap().store.fault = WriteFault::AfterRename;
            assert!(matches!(
                controller.cancel_edit_certain("edit", &turn.id),
                Err(Error::PersistenceUncertain(_))
            ));
            controller.inner.lock().unwrap().store.fault = WriteFault::None;
            let retained = retained_files(dir.path());
            let committed: Session =
                serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            assert!(committed.edit.is_none());
            assert_eq!(
                committed.queue_edit_status("edit").unwrap().state,
                QueueEditState::Cancelled
            );
            for edit in ["edit", "unknown"] {
                assert!(matches!(
                    controller.cancel_edit_certain(edit, &turn.id),
                    Err(Error::PersistenceUncertain(_))
                ));
            }
            assert_eq!(retained_files(dir.path()), retained);
            assert_eq!(controller.revision(), 0);
            assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
            assert!(!updates.has_changed().unwrap());
            assert_never_launched(&controller, &listener);
            drop(controller);
            let (reopened, listener) = configured_fixture(SessionStore::open(&path).unwrap());
            let status = reopened.cancel_edit_certain("edit", &turn.id).unwrap();
            assert_eq!(status.state, QueueEditState::Cancelled);
            assert_eq!(retained_files(dir.path()), retained);
            assert_never_launched(&reopened, &listener);
        }
    }

    #[test]
    fn cancel_edit_certain_terminal_status_still_requires_certain_fatal_free_storage() {
        for outcome in ["saved", "cancelled", "removed"] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("session.json");
            let mut store = SessionStore::open(&path).unwrap();
            let turn = Submission::new("original".into(), Lane::FollowUp);
            let queued = Submission::new("still pending".into(), Lane::FollowUp);
            store
                .transact(|session| {
                    session.submit(turn.clone())?;
                    session.submit(queued.clone())?;
                    session.begin_edit(&turn.id, "edit")?;
                    session.resolve_edit(
                        "edit",
                        outcome,
                        (outcome == "saved").then_some("saved text"),
                    )
                })
                .unwrap();
            let (controller, listener) = configured_fixture(store);
            let expected = controller.edit_status("edit").unwrap();
            // Even a plausible presentation value is never cancellation authority.
            controller.published.send_replace(Arc::new(Session::new()));
            let cached = controller.snapshot_shared();
            assert_eq!(
                controller.cancel_edit_certain("edit", &turn.id).unwrap(),
                expected
            );
            assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
            let updates = controller.subscribe();
            controller.inner.lock().unwrap().fatal = Some("fatal checkpoint".into());
            assert!(controller.cancel_edit_certain("edit", &turn.id).is_err());
            controller.inner.lock().unwrap().fatal = None;
            controller.inner.lock().unwrap().store.fault = WriteFault::AfterRename;
            assert!(matches!(
                controller.begin_edit(&queued.id, "uncertain-edit"),
                Err(Error::PersistenceUncertain(_))
            ));
            controller.inner.lock().unwrap().store.fault = WriteFault::None;
            let bytes = retained_files(dir.path());
            for edit in ["edit", "uncertain-edit", "unknown"] {
                assert!(matches!(
                    controller.cancel_edit_certain(edit, &turn.id),
                    Err(Error::PersistenceUncertain(_))
                ));
            }
            assert_eq!(retained_files(dir.path()), bytes);
            assert_eq!(controller.revision(), 0);
            assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
            assert!(!updates.has_changed().unwrap());
            assert_never_launched(&controller, &listener);
        }
    }

    #[test]
    fn cancel_edit_certain_concurrent_identity_commands_have_one_serialized_commit() {
        let dir = tempfile::tempdir().unwrap();
        let (controller, turn_id) = held_controller(&dir.path().join("session.json"));
        let before = controller.snapshot_shared().revision;
        let barrier = Arc::new(std::sync::Barrier::new(3));
        let results = std::thread::scope(|scope| {
            let mut joins = Vec::new();
            for _ in 0..2 {
                let controller = Arc::clone(&controller);
                let barrier = Arc::clone(&barrier);
                let turn_id = turn_id.clone();
                joins.push(scope.spawn(move || {
                    barrier.wait();
                    controller.cancel_edit_certain("edit", &turn_id).unwrap()
                }));
            }
            barrier.wait();
            joins
                .into_iter()
                .map(|join| join.join().unwrap())
                .collect::<Vec<_>>()
        });
        assert_eq!(results[0], results[1]);
        assert_eq!(results[0].session_revision, before + 1);
        assert_eq!(controller.snapshot_shared().outcomes.len(), 1);
        assert_eq!(controller.revision(), 2); // Begin, then the sole Cancel commit.
        assert!(controller.begin_edit(&turn_id, "edit").is_err());
        // Competing unknown Cancel and delayed Begin have the same terminal
        // result in either actor order, without leaving a reacquired hold.
        let barrier = Arc::new(std::sync::Barrier::new(3));
        std::thread::scope(|scope| {
            let controller = &controller;
            let turn_id = &turn_id;
            let begin_barrier = Arc::clone(&barrier);
            let begin = scope.spawn(move || {
                begin_barrier.wait();
                controller.begin_edit(turn_id, "raced-edit")
            });
            let cancel_barrier = Arc::clone(&barrier);
            let cancel = scope.spawn(move || {
                cancel_barrier.wait();
                controller.cancel_edit_certain("raced-edit", turn_id)
            });
            barrier.wait();
            let _ = begin.join().unwrap();
            assert_eq!(
                cancel.join().unwrap().unwrap().state,
                QueueEditState::Cancelled
            );
        });
        assert!(controller.snapshot_shared().edit.is_none());
        assert!(controller.begin_edit(&turn_id, "raced-edit").is_err());
        assert_eq!(controller.snapshot_shared().outcomes.len(), 2);
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

    #[tokio::test]
    async fn retirement_rejects_every_mutation_and_releases_only_joined_writer() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        let queued = Submission::new("queued original 日本語".into(), Lane::FollowUp);
        store
            .transact(|session| {
                session.submit(queued.clone())?;
                session.retry = Some(Submission::new("retry original".into(), Lane::FollowUp));
                session.begin_edit(&queued.id, "held-edit")?;
                Ok(())
            })
            .unwrap();
        let (controller, listener) = configured_fixture(store);
        let stale_owner = controller.clone();
        let cached = controller.snapshot_shared();
        let bytes = retained_files(dir.path());
        let revision = controller.revision();
        controller.retire().unwrap();
        assert!(controller.is_retired());
        assert!(
            SessionStore::open(&path).is_err(),
            "fencing alone must retain the writer"
        );
        for result in [
            controller.submit("late submit".into(), Lane::FollowUp),
            controller.submit_identified(Submission::new("late identified".into(), Lane::Steering)),
            controller.resume(),
            controller.retry(),
            controller.begin_edit(&queued.id, "late-edit").map(|_| ()),
            controller.resolve_edit("held-edit", "saved", Some("late rewrite")),
            controller.resolve_edit("held-edit", "cancelled", None),
            controller.resolve_edit("held-edit", "removed", None),
            controller
                .cancel_edit_certain("held-edit", &queued.id)
                .map(|_| ()),
            controller
                .cancel_edit_certain("unknown", &queued.id)
                .map(|_| ()),
            controller.remove(&queued.id),
            controller.reorder(std::slice::from_ref(&queued.id)),
            controller.promote_to_steering(&queued.id),
            controller.materialize(&path),
        ] {
            assert!(
                matches!(result, Err(Error::Invalid(message)) if message.contains("permanently retired"))
            );
        }
        controller.stop().unwrap();
        controller.retire().unwrap();
        assert_never_launched(&controller, &listener);
        assert_eq!(retained_files(dir.path()), bytes);
        assert_eq!(controller.revision(), revision);
        assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
        // Ordinary stop/join must not release a retired writer accidentally.
        controller.shutdown().await.unwrap();
        assert!(SessionStore::open(&path).is_err());
        controller.retire_and_wait().await.unwrap();
        assert!(controller.edit_status("held-edit").is_err());
        let reopened = Controller::with_configuration(
            SessionStore::open(&path).unwrap(),
            controller.configuration(),
        )
        .unwrap();
        assert!(!reopened.is_retired());
        stale_owner.retire_and_wait().await.unwrap();
        assert!(
            SessionStore::open(&path).is_err(),
            "repeated old retirement must not release replacement ownership"
        );
        assert_eq!(
            reopened.snapshot().pending[0].text,
            "queued original 日本語"
        );
        assert_eq!(
            reopened.snapshot().edit.as_ref().unwrap().edit_id,
            "held-edit"
        );
        assert!(stale_owner.resume().is_err());
        assert!(Arc::ptr_eq(&cached, &stale_owner.snapshot_shared()));
        reopened
            .cancel_edit_certain("held-edit", &queued.id)
            .unwrap();
        reopened.resume().unwrap();
        let listener = TcpListener::from_std(listener).unwrap();
        let (mut socket, _) = timeout(DEADLINE, listener.accept()).await.unwrap().unwrap();
        let request = read_fixture_request(&mut socket).await;
        assert_eq!(
            request["input"][0]["content"][0]["text"],
            "queued original 日本語"
        );
        complete_fixture(&mut socket).await;
        await_session(&reopened, |session| session.state == RunState::Idle).await;
        reopened.shutdown().await.unwrap();
        assert!(
            !reopened.is_retired(),
            "ordinary shutdown must remain reusable"
        );
        assert!(
            SessionStore::open(&path).is_err(),
            "ordinary shutdown retains ownership"
        );
        // Stop can pause the idle tail; explicit Resume preserves that policy.
        reopened.resume().unwrap();
        reopened
            .submit("after ordinary shutdown".into(), Lane::FollowUp)
            .unwrap();
        let (mut socket, _) = timeout(DEADLINE, listener.accept()).await.unwrap().unwrap();
        read_fixture_request(&mut socket).await;
        complete_fixture(&mut socket).await;
        await_session(&reopened, |session| session.state == RunState::Idle).await;
        reopened.shutdown().await.unwrap();
        // Direct storage entry points also fail closed after ownership transfer.
        let mut inner = stale_owner.inner.lock().unwrap();
        assert!(inner.store.persist_to(&path).is_err());
        assert!(inner.store.transact(|_| Ok(())).is_err());
        assert!(
            inner
                .store
                .append_delta("stale", crate::Delta::Text("late".into()))
                .is_err()
        );
        assert!(inner.store.edit_status("held-edit").is_err());
    }

    #[tokio::test]
    async fn retirement_waits_for_admitted_reservation_before_collecting_join() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let (controller, listener) = configured_fixture(SessionStore::open(&path).unwrap());
        // Freeze real handle registration after the submit transaction and
        // worker reservation, while the submitting thread owns the actor lock.
        let registering = controller.clone();
        let (entered, registration_ready) = tokio::sync::oneshot::channel();
        let (release_registration, release) = std::sync::mpsc::channel();
        let registration = std::thread::spawn(move || {
            let _guard = registering.worker.lock().unwrap();
            entered.send(()).unwrap();
            // Dropping the sender during a failing assertion also opens the gate.
            let _ = release.recv();
        });
        timeout(DEADLINE, registration_ready)
            .await
            .unwrap()
            .unwrap();
        let submitting = controller.clone();
        let submit = std::thread::spawn(move || {
            submitting.submit("admitted before retirement".into(), Lane::FollowUp)
        });
        timeout(DEADLINE, async {
            while !controller.worker_active.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let retiring = controller.clone();
        let (done, mut completion) = tokio::sync::oneshot::channel();
        let retirement = std::thread::spawn(move || {
            let result = retiring.retire();
            done.send(result).unwrap();
        });
        timeout(DEADLINE, async {
            while !controller.is_retired() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert!(matches!(
            completion.try_recv(),
            Err(tokio::sync::oneshot::error::TryRecvError::Empty)
        ));
        release_registration.send(()).unwrap();
        registration.join().unwrap();
        submit.join().unwrap().unwrap();
        timeout(DEADLINE, completion)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        retirement.join().unwrap();
        timeout(DEADLINE, controller.retire_and_wait())
            .await
            .unwrap()
            .unwrap();
        assert_never_launched(&controller, &listener);
        assert_eq!(controller.snapshot().state, RunState::Paused);
        assert_eq!(
            controller.snapshot().pending[0].text,
            "admitted before retirement"
        );
        assert!(SessionStore::open(&path).is_ok());
    }

    #[tokio::test]
    async fn retirement_joins_real_provider_and_preserves_partial_and_pending_input() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let (controller, listener) = configured_fixture(SessionStore::open(&path).unwrap());
        let listener = TcpListener::from_std(listener).unwrap();
        controller
            .submit("active provider".into(), Lane::FollowUp)
            .unwrap();
        let (mut socket, _) = timeout(DEADLINE, listener.accept()).await.unwrap().unwrap();
        read_fixture_request(&mut socket).await;
        socket.write_all(concat!(
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"retained partial\"}\n\n"
        ).as_bytes()).await.unwrap();
        await_session(&controller, |session| {
            session
                .messages
                .last()
                .is_some_and(|row| row.text == "retained partial")
        })
        .await;
        let queued = Submission::new("never dispatched".into(), Lane::FollowUp);
        controller.submit_identified(queued.clone()).unwrap();
        controller.retire().unwrap();
        assert!(SessionStore::open(&path).is_err());
        timeout(DEADLINE, controller.retire_and_wait())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(controller.snapshot().state, RunState::Paused);
        assert_eq!(controller.snapshot().pending[0].id, queued.id);
        assert_eq!(
            controller.snapshot().messages.last().unwrap().text,
            "retained partial"
        );
        let mut byte = [0];
        assert_eq!(
            timeout(DEADLINE, socket.read(&mut byte))
                .await
                .unwrap()
                .unwrap(),
            0
        );
        let listener = listener.into_std().unwrap();
        assert_never_launched(&controller, &listener);
        let replacement = Controller::new(SessionStore::open(&path).unwrap(), None).unwrap();
        assert_eq!(replacement.snapshot().pending[0].id, queued.id);
        assert_eq!(
            replacement.snapshot().messages.last().unwrap().text,
            "retained partial"
        );
        assert!(controller.retry().is_err());
    }

    #[tokio::test]
    async fn retirement_releases_uncertain_writer_without_clearing_or_rewriting_uncertainty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let (controller, turn_id) = held_controller(&path);
        let cached = controller.snapshot_shared();
        controller.inner.lock().unwrap().store.fault = WriteFault::AfterRename;
        assert!(matches!(
            controller.resolve_edit("edit", "saved", Some("disk has saved rewrite")),
            Err(Error::PersistenceUncertain(_))
        ));
        let bytes = retained_files(dir.path());
        controller.retire_and_wait().await.unwrap();
        assert_eq!(retained_files(dir.path()), bytes);
        assert!(Arc::ptr_eq(&cached, &controller.snapshot_shared()));
        assert!(controller.edit_status("edit").is_err());
        assert!(controller.cancel_edit_certain("edit", &turn_id).is_err());
        let reopened = Controller::new(SessionStore::open(&path).unwrap(), None).unwrap();
        assert_eq!(
            reopened.snapshot().pending[0].text,
            "disk has saved rewrite"
        );
        assert!(matches!(
            reopened.edit_status("edit").unwrap().state,
            QueueEditState::Saved { .. }
        ));
    }

    #[tokio::test]
    async fn retirement_join_failure_survives_cancelled_and_concurrent_waiters() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let controller = Controller::new(SessionStore::open(&path).unwrap(), None).unwrap();
        let (release, gate) = tokio::sync::oneshot::channel();
        *controller.worker.lock().unwrap() = Some(tokio::spawn(async move {
            gate.await.unwrap();
            panic!("injected retirement worker panic");
        }));
        let mut abandoned = Box::pin(controller.retire_and_wait());
        assert!(futures_util::poll!(&mut abandoned).is_pending());
        let mut second = Box::pin(controller.retire_and_wait());
        assert!(futures_util::poll!(&mut second).is_pending());
        drop(abandoned);
        assert!(futures_util::poll!(&mut second).is_pending());
        assert!(SessionStore::open(&path).is_err());
        release.send(()).unwrap();
        let result = timeout(DEADLINE, second).await.unwrap();
        assert!(
            matches!(result, Err(Error::Invalid(message)) if message == "Session worker terminated unexpectedly")
        );
        let result = controller.retire_and_wait().await;
        assert!(
            matches!(result, Err(Error::Invalid(message)) if message == "Session worker terminated unexpectedly")
        );
        assert!(controller.is_retired());
        assert!(
            SessionStore::open(&path).is_err(),
            "failed join must not transfer ownership"
        );
        assert!(controller.materialize(&path).is_err());
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

#[cfg(all(test, feature = "synthetic-authority"))]
#[path = "runtime_configuration_tests.rs"]
mod configuration_tests;

#[cfg(all(test, feature = "synthetic-authority"))]
#[path = "worker_tail_test_gate.rs"]
pub(crate) mod worker_tail_test_gate;

#[cfg(test)]
#[path = "runtime_read_observation_tests.rs"]
mod read_observation_tests;

#[cfg(test)]
#[path = "retained_find_runtime_tests.rs"]
mod retained_find_tests;

#[cfg(test)]
thread_local! {
    static SOURCE_CAPTURE_HOOK: std::cell::RefCell<Option<Box<dyn FnMut()>>> = std::cell::RefCell::new(None);
}
#[cfg(test)]
#[path = "runtime_source_admission_tests.rs"]
mod source_admission_tests;
