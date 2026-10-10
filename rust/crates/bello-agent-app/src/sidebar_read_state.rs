//! Workspace-owned attention. History baselines are memory-only until an output
//! admission or a real reader mutation. Grace affects presentation, never debt.
use crate::{AgentView, chat_organization::catalog_operation};
use bello_agent_core::{
    Controller, Error, Result,
    read_observation::{AcceptedReadObservation, OutputProjection, OutputSummary},
    workspace::{ChatMaterialization, ChatRecord, WorkspaceSnapshot, WorkspaceStore},
    workspace_read_state::{ChatReadState, ReadEvent, reduce_read_state},
};
use gpui::{App, Context, Task, Window};
use std::{
    collections::BTreeMap,
    path::PathBuf,
    sync::{Arc, Mutex, Weak},
    time::{Duration, Instant},
};

pub(crate) type SharedReadStates = Arc<Mutex<ReadCoordinator>>;
#[derive(Clone)]
struct Entry {
    path: PathBuf,
    state: ChatReadState,
    saved_revision: Option<u64>,
    dirty: bool,
    hold: Option<(uuid::Uuid, u64, Instant)>,
}
/// The coordinator is shared with admission and shutdown workers. Its mutex
/// serializes only small metadata mutations/flushes, never a provider await.
#[derive(Clone)]
pub(crate) struct ReadCoordinator {
    project: PathBuf,
    project_id: Option<String>,
    entries: BTreeMap<String, Entry>,
    fenced: bool,
    failures: u8,
    pub(crate) error: Option<String>,
}
impl ReadCoordinator {
    pub(crate) fn restore(snapshot: &WorkspaceSnapshot) -> SharedReadStates {
        Arc::new(Mutex::new(Self {
            project: snapshot.project.clone(),
            project_id: snapshot.project_id.clone(),
            entries: snapshot
                .read_states
                .iter()
                .filter_map(|(id, state)| {
                    snapshot.chats.iter().find(|r| &r.id == id).map(|r| {
                        (
                            id.clone(),
                            Entry {
                                path: r.snapshot.clone(),
                                state: state.clone(),
                                saved_revision: Some(state.revision),
                                dirty: false,
                                hold: None,
                            },
                        )
                    })
                })
                .collect(),
            fenced: false,
            failures: 0,
            error: None,
        }))
    }
    fn entry(&self, record: &ChatRecord) -> Option<&Entry> {
        self.entries
            .get(&record.id)
            .filter(|e| e.path == record.snapshot)
    }
    fn apply(
        &mut self,
        record: &ChatRecord,
        event: ReadEvent<'_>,
        persist: bool,
        grace: bool,
    ) -> Result<bool> {
        if self.fenced {
            return Err(Error::PersistenceUncertain(
                "Read-state storage is unconfirmed".into(),
            ));
        }
        let old = self.entry(record).cloned();
        let next =
            reduce_read_state(old.as_ref().map(|e| &e.state), event).inspect_err(|error| {
                self.error = Some(read_error_notice(error));
            })?;
        let Some(next) = next else {
            return Ok(false);
        };
        if old.as_ref().is_some_and(|e| e.state == next) {
            return Ok(false);
        }
        let previous_count = old.as_ref().map_or(0, |e| e.state.unread_count);
        let prior_hold = old.as_ref().and_then(|e| e.hold);
        let mut hold = if old.as_ref().is_some_and(|e| {
            e.state.consumed_generation != next.consumed_generation
                || next.observed_count < e.state.observed_count
        }) {
            None
        } else {
            prior_hold
        };
        if next.unread_count == 0 {
            hold = None;
        } else if grace && next.unread_count > previous_count {
            let hidden = hold
                .filter(|(_, _, until)| *until > Instant::now())
                .map_or(0, |(_, n, _)| n);
            hold = Some((
                uuid::Uuid::new_v4(),
                hidden.saturating_add(next.unread_count - previous_count),
                Instant::now() + Duration::from_millis(600),
            ));
        }
        let attention_changed = old.as_ref().map_or(
            next.unread_count > 0 || next.unread_failure || next.manual_unread,
            |e| {
                e.state.unread_count != next.unread_count
                    || e.state.unread_failure != next.unread_failure
                    || e.state.manual_unread != next.manual_unread
            },
        );
        let dirty = old.as_ref().is_some_and(|e| {
            e.dirty
                || (e.saved_revision.is_some()
                    && (e.state.observed_count != next.observed_count
                        || e.state.latest_id != next.latest_id))
        }) || persist
            || attention_changed;
        self.entries.insert(
            record.id.clone(),
            Entry {
                path: record.snapshot.clone(),
                state: next,
                saved_revision: old.as_ref().and_then(|e| e.saved_revision),
                dirty,
                hold,
            },
        );
        Ok(true)
    }
    pub(crate) fn observe(
        &mut self,
        record: &ChatRecord,
        observation: &AcceptedReadObservation,
        grace: bool,
    ) -> Result<bool> {
        self.apply(
            record,
            ReadEvent::Observe {
                observation,
                reader_present: false,
            },
            false,
            grace,
        )
    }
    #[cfg(test)]
    pub(crate) fn baseline(
        &mut self,
        record: &ChatRecord,
        summary: &OutputSummary,
    ) -> Result<bool> {
        self.apply(record, ReadEvent::Baseline(summary), false, false)
    }
    pub(crate) fn dock_badge(&self, records: &[ChatRecord]) -> Option<String> {
        crate::notifications::dock_badge(records.iter().map(|r| (r, self.presentation(r))))
    }
    fn presentation(&self, record: &ChatRecord) -> Option<ChatReadState> {
        let entry = self.entry(record)?;
        let mut state = entry.state.clone();
        if let Some((_, held, until)) = entry.hold
            && until > Instant::now()
        {
            state.unread_count = state.unread_count.saturating_sub(held);
        }
        Some(state)
    }
    fn flush(&mut self, store: &mut WorkspaceStore, force: bool) -> Result<()> {
        if self.fenced {
            return Err(Error::PersistenceUncertain(
                "Read-state storage is unconfirmed".into(),
            ));
        }
        if force {
            self.failures = 0;
        }
        if self.failures >= 3 {
            return Err(Error::Invalid(
                "Read-state save failed; retry the action or close to retry".into(),
            ));
        }
        // Project binding can be confirmed during this workspace lifetime. The
        // root must remain identical; UUID may advance only from absent to bound.
        let snapshot = store.snapshot();
        if snapshot.project != self.project
            || self
                .project_id
                .as_ref()
                .is_some_and(|id| Some(id) != snapshot.project_id.as_ref())
        {
            return Err(Error::Invalid(
                "Read-state workspace identity changed".into(),
            ));
        }
        self.project_id = snapshot.project_id;
        self.entries.retain(|id, entry| {
            !entry.dirty
                || snapshot
                    .chats
                    .iter()
                    .any(|r| &r.id == id && r.snapshot == entry.path)
        });
        for (id, entry) in &mut self.entries {
            if !entry.dirty {
                continue;
            }
            // Never create a row from attention metadata. A removed or replaced
            // row cannot receive a stale write.
            if !snapshot
                .chats
                .iter()
                .any(|r| &r.id == id && r.snapshot == entry.path)
            {
                continue;
            }
            match store.save_read_state(
                &self.project,
                self.project_id.as_deref(),
                id,
                &entry.path,
                entry.saved_revision,
                &entry.state,
            ) {
                Ok(receipt) => {
                    entry.saved_revision = Some(receipt.state.revision);
                    entry.dirty = false;
                }
                Err(error) => {
                    self.fenced =
                        store.is_uncertain() || matches!(error, Error::PersistenceUncertain(_));
                    self.failures = self.failures.saturating_add(1);
                    self.error = Some(read_error_notice(&error));
                    return Err(error);
                }
            }
        }
        self.failures = 0;
        self.error = None;
        Ok(())
    }
}

/// Catalog mutex must be held by the caller. A snapshot releases the UI's
/// metadata lock before fsync. Receipts acknowledge only their own revision;
/// mutations arriving during I/O remain dirty and are picked up by the one writer.
fn flush_shared(shared: &SharedReadStates, store: &mut WorkspaceStore, force: bool) -> Result<()> {
    let mut batch = shared
        .lock()
        .map_err(|_| Error::Invalid("Read-state lock poisoned".into()))?
        .clone();
    let previous_failures = batch.failures;
    let result = batch.flush(store, force);
    if result.is_err() && batch.failures <= previous_failures {
        batch.failures = previous_failures.saturating_add(1);
    }
    let registered = store.snapshot().chats;
    let mut live = shared
        .lock()
        .map_err(|_| Error::Invalid("Read-state lock poisoned".into()))?;
    merge_saved_batch(&mut live, batch, &registered, store.is_uncertain());
    result
}

fn merge_saved_batch(
    live: &mut ReadCoordinator,
    batch: ReadCoordinator,
    registered: &[ChatRecord],
    uncertain: bool,
) {
    live.fenced |= batch.fenced || uncertain;
    live.failures = batch.failures;
    live.error = batch.error;
    live.project_id = batch.project_id;
    live.entries.retain(|id, entry| {
        !entry.dirty
            || registered
                .iter()
                .any(|r| &r.id == id && r.snapshot == entry.path)
    });
    for (id, saved) in batch.entries {
        if let Some(entry) = live.entries.get_mut(&id).filter(|e| e.path == saved.path) {
            if saved.saved_revision > entry.saved_revision {
                entry.saved_revision = saved.saved_revision;
            }
            if entry.saved_revision == Some(entry.state.revision) {
                entry.dirty = false;
            }
        }
    }
}

/// Invoked after registration and before every output-producing dispatch.
/// A failed baseline write preserves the caller's existing draft/intent fence.
pub(crate) fn prepare_admission(
    shared: &SharedReadStates,
    store: &mut WorkspaceStore,
    record: &ChatRecord,
    controller: &Controller,
) -> Result<()> {
    if !store
        .snapshot()
        .chats
        .iter()
        .any(|r| r.id == record.id && r.snapshot == record.snapshot)
    {
        return Err(Error::Invalid(
            "Read baseline requires the exact registered chat path".into(),
        ));
    }
    if controller.snapshot_shared().id != record.id {
        return Err(Error::Invalid(
            "Read baseline Controller identity changed".into(),
        ));
    }
    let observation = controller.read_observation();
    if !matches!(&observation.history, OutputProjection::Known(_)) {
        return Err(Error::Invalid(
            "Output history is unknown; read baseline cannot be saved".into(),
        ));
    }
    let mut states = shared
        .lock()
        .map_err(|_| Error::Invalid("Read-state lock poisoned".into()))?;
    states.observe(record, &observation, false)?;
    if let Some(entry) = states.entries.get_mut(&record.id) {
        entry.dirty = true;
    }
    drop(states);
    flush_shared(shared, store, true)?;
    let saved = store.snapshot();
    if saved
        .read_states
        .get(&record.id)
        .is_none_or(|state| state.baseline_pending)
    {
        return Err(Error::Invalid("Read baseline was not confirmed".into()));
    }
    Ok(())
}
/// Post-join capture is independent of any queued foreground watch callback.
pub(crate) fn capture_and_flush(
    shared: &SharedReadStates,
    store: &mut WorkspaceStore,
    controllers: &[(ChatRecord, Arc<Controller>)],
) -> Result<()> {
    let mut states = shared
        .lock()
        .map_err(|_| Error::Invalid("Read-state lock poisoned".into()))?;
    for (record, controller) in controllers {
        if controller.is_persistent() {
            states.observe(record, &controller.read_observation(), false)?;
        }
    }
    drop(states);
    flush_shared(shared, store, true)
}

pub(crate) fn subscribe(
    controller: &Arc<Controller>,
    record: &ChatRecord,
    workspace: Arc<Mutex<WorkspaceStore>>,
    cx: &mut Context<AgentView>,
) -> Task<()> {
    let mut updates = controller.subscribe_read_observation();
    let first = updates.borrow_and_update().clone();
    let source = Arc::downgrade(controller);
    let record = record.clone();
    cx.spawn(async move |owner, cx| {
        let mut next = Some(first);
        loop {
            if let Some(observation) = next.take()
                && owner
                    .update(cx, |view, cx| {
                        view.receive_read_observation(&workspace, &record, &source, observation, cx)
                    })
                    .is_err()
            {
                break;
            }
            if updates.changed().await.is_err() {
                break;
            }
            next = Some(updates.borrow_and_update().clone());
        }
    })
}
impl AgentView {
    pub(crate) fn receive_read_observation(
        &mut self,
        workspace: &Arc<Mutex<WorkspaceStore>>,
        record: &ChatRecord,
        source: &Weak<Controller>,
        observation: AcceptedReadObservation,
        cx: &mut Context<Self>,
    ) {
        if !Arc::ptr_eq(workspace, &self.workspace)
            || self.chat_ref(&record.id).is_none_or(|chat| {
                chat.record.snapshot != record.snapshot
                    || !source.ptr_eq(&Arc::downgrade(&chat.controller))
                    || (!chat.controller.is_persistent()
                        && chat.record.materialization != ChatMaterialization::Pending)
            })
        {
            return;
        }
        let grace = self.record.id == record.id
            && self.current_reader_present(cx)
            && self
                .chat
                .transcript
                .as_ref()
                .is_some_and(|t| t.read(cx).follows_bottom());
        let reader_present = failure_reader_evidence(
            self.record.id == record.id,
            !self.show_files && !self.changes_open && !self.shutting_down,
            application_active(cx),
        );
        let changed = self.read_states.lock().unwrap().apply(
            record,
            ReadEvent::Observe {
                observation: &observation,
                reader_present,
            },
            false,
            grace,
        );
        match changed {
            Ok(true) => {
                if self.record.id == record.id {
                    self.invalidate_read_geometry(cx);
                }
                self.flush_read_states(cx);
                self.schedule_read_grace(record, cx);
                cx.notify();
            }
            Ok(false) => {}
            Err(error) => {
                self.error = Some(read_error_notice(&error));
                cx.notify();
            }
        }
    }
    fn schedule_read_grace(&mut self, record: &ChatRecord, cx: &mut Context<Self>) {
        let hold = self
            .read_states
            .lock()
            .unwrap()
            .entry(record)
            .and_then(|e| e.hold);
        let Some((token, _, until)) = hold else {
            return;
        };
        let states = self.read_states.clone();
        let workspace = self.workspace.clone();
        let record = record.clone();
        cx.spawn(async move |view, cx| {
            cx.background_executor()
                .timer(until.saturating_duration_since(Instant::now()))
                .await;
            let _ = view.update(cx, |view, cx| {
                if !Arc::ptr_eq(&workspace, &view.workspace) {
                    return;
                }
                let released = {
                    let mut states = states.lock().unwrap();
                    if let Some(entry) = states.entries.get_mut(&record.id).filter(|entry| {
                        entry.path == record.snapshot
                            && entry.hold.is_some_and(|(held, _, _)| held == token)
                    }) {
                        entry.hold = None;
                        true
                    } else {
                        false
                    }
                };
                if released {
                    if view.record.id == record.id {
                        view.invalidate_read_geometry(cx);
                    }
                    cx.notify();
                }
            });
        })
        .detach();
    }
    pub(crate) fn sidebar_read_writes_pending(&self) -> bool {
        self.read_write_inflight || {
            let states = self.read_states.lock().unwrap();
            !states.fenced && states.failures < 3 && states.entries.values().any(|e| e.dirty)
        }
    }
    pub(crate) fn flush_read_states(&mut self, cx: &mut Context<Self>) {
        if self.read_write_inflight {
            return;
        }
        let pending = {
            let states = self.read_states.lock().unwrap();
            !states.fenced && states.failures < 3 && states.entries.values().any(|e| e.dirty)
        };
        if !pending {
            return;
        }
        self.read_write_inflight = true;
        let failures_before = self.read_states.lock().unwrap().failures;
        let shared = self.read_states.clone();
        let workspace = self.workspace.clone();
        let identity = workspace.clone();
        let task = cx.background_executor().spawn(async move {
            catalog_operation(&workspace, |store| flush_shared(&shared, store, false))
        });
        cx.spawn(async move |view, cx| {
            let outcome = task.await;
            let _ = view.update(cx, |view, cx| {
                if !Arc::ptr_eq(&identity, &view.workspace) {
                    return;
                }
                view.read_write_inflight = false;
                view.observe_catalog_uncertainty(outcome.uncertain, cx);
                if let Err(error) = outcome.display_result() {
                    let mut states = view.read_states.lock().unwrap();
                    // The catalog lock itself may fail before flush_shared runs.
                    // Account for that failure too, without double-counting an
                    // ordinary transaction error already recorded by the batch.
                    if states.failures <= failures_before {
                        states.failures = failures_before.saturating_add(1);
                    }
                    states.error = Some(error.clone());
                    drop(states);
                    view.error = Some(format!("Read state could not be saved: {error}"));
                    cx.notify();
                } else {
                    view.invalidate_read_geometry(cx);
                }
                cx.notify();
                view.flush_read_states(cx);
            });
        })
        .detach();
    }
    /// Chained admission/settlement callbacks must reject an old workspace
    /// before a storage-uncertainty result can fence the current workspace.
    pub(crate) fn observe_bound_catalog_uncertainty(
        &mut self,
        expected: &Arc<Mutex<WorkspaceStore>>,
        uncertain: bool,
        cx: &mut Context<Self>,
    ) -> bool {
        if !Arc::ptr_eq(expected, &self.workspace) {
            return false;
        }
        self.observe_catalog_uncertainty(uncertain, cx);
        true
    }
    pub(crate) fn inspect_read_baseline(
        &mut self,
        record: &ChatRecord,
        summary: &OutputSummary,
        idle: bool,
        cx: &mut Context<Self>,
    ) {
        let result = self.read_states.lock().unwrap().apply(
            record,
            if idle {
                ReadEvent::Inspect(summary)
            } else {
                ReadEvent::Baseline(summary)
            },
            false,
            false,
        );
        if let Err(error) = result {
            self.error = Some(read_error_notice(&error));
        } else {
            self.flush_read_states(cx);
        }
    }
    pub(crate) fn reader_opened(&mut self, id: &str, changed_focus: bool, cx: &mut Context<Self>) {
        if self.record.id == id {
            self.invalidate_read_geometry(cx);
        }
        let Some(record) = self.records.iter().find(|r| r.id == id).cloned() else {
            return;
        };
        let observation = self
            .chat_ref(id)
            .filter(|c| c.controller.is_persistent())
            .map(|c| c.controller.read_observation());
        let result = (|| {
            let mut states = self.read_states.lock().unwrap();
            if let Some(o) = observation {
                states.observe(&record, &o, false)?;
            }
            states.apply(&record, ReadEvent::Opened { changed_focus }, true, false)
        })();
        if let Err(error) = result {
            self.error = Some(read_error_notice(&error));
        } else {
            self.flush_read_states(cx);
        }
    }
    pub(crate) fn can_mark_read_state(&self, id: &str) -> bool {
        if self.read_states.lock().unwrap().fenced || self.read_manual_operations.contains_key(id) {
            return false;
        }
        let registered = self.workspace.try_lock().ok().is_some_and(|store| {
            !store.is_uncertain()
                && store.snapshot().chats.iter().any(|r| {
                    r.id == id
                        && self
                            .records
                            .iter()
                            .any(|row| row.id == r.id && row.snapshot == r.snapshot)
                })
        });
        if !registered {
            return false;
        }
        !self.shutting_down
            && !self.known_catalog_uncertainty
            && self.records.iter().any(|r| {
                r.id == id
                    && r.archived_at.is_none()
                    && r.materialization == ChatMaterialization::CheckpointRequired
            })
            && self.chat_ref(id).map_or_else(
                || {
                    self.records
                        .iter()
                        .find(|r| r.id == id)
                        .is_some_and(|r| self.sidebar_saved_identity(r).is_some())
                },
                |c| c.controller.is_persistent() && !c.pending && !c.loading && !c.load_failed,
            )
    }
    pub(crate) fn can_read_action(&self, id: &str, unread: bool) -> bool {
        if !self.can_mark_read_state(id) {
            return false;
        }
        let record = self.records.iter().find(|r| r.id == id);
        let states = self.read_states.lock().unwrap();
        let state = record.and_then(|r| states.entry(r)).map(|e| &e.state);
        if unread {
            bello_agent_core::workspace_read_state::can_mark_unread(record, true, state)
        } else {
            bello_agent_core::workspace_read_state::can_mark_read(record, true, state)
        }
    }
    pub(crate) fn mark_chat_read_state(&mut self, id: &str, unread: bool, cx: &mut Context<Self>) {
        if !self.can_read_action(id, unread) {
            return;
        }
        let record = self.records.iter().find(|r| r.id == id).unwrap().clone();
        if self.chat_ref(id).is_none() {
            let Some(identity) = self.sidebar_saved_identity(&record) else {
                return;
            };
            let token = uuid::Uuid::new_v4();
            self.read_manual_operations.insert(id.to_owned(), token);
            let navigation = self.navigation_generation;
            let revision = self
                .read_states
                .lock()
                .unwrap()
                .entry(&record)
                .map(|e| e.state.revision);
            let workspace = self.workspace.clone();
            let path = record.snapshot.clone();
            let task = cx.background_executor().spawn(async move {
                crate::sidebar_run_state::FileIdentity::read(&path).as_ref() == Some(&identity)
            });
            cx.spawn(async move |owner, cx| {
                let valid = task.await;
                let _ = owner.update(cx, |view, cx| {
                    if !Arc::ptr_eq(&workspace, &view.workspace)
                        || view.read_manual_operations.get(&record.id) != Some(&token)
                    {
                        return;
                    }
                    view.read_manual_operations.remove(&record.id);
                    cx.notify();
                    let current_path = view.records.iter().any(|current| {
                        current.id == record.id && current.snapshot == record.snapshot
                    });
                    if view.navigation_generation != navigation
                        || !current_path
                        || view.chat_ref(&record.id).is_some()
                    {
                        return;
                    }
                    if !valid {
                        view.invalidate_saved_read_target(&record);
                        view.error = Some("Chat checkpoint changed or is unavailable; read state was not changed.".into());
                        return;
                    }
                    let current_revision = view.read_states.lock().unwrap()
                        .entry(&record).map(|entry| entry.state.revision);
                    if current_revision != revision || !view.can_read_action(&record.id, unread) {
                        return;
                    }
                    view.apply_manual_read_state(&record, unread, cx);
                });
            }).detach();
            cx.notify();
            return;
        }
        self.apply_manual_read_state(&record, unread, cx);
    }
    fn apply_manual_read_state(
        &mut self,
        record: &ChatRecord,
        unread: bool,
        cx: &mut Context<Self>,
    ) {
        let id = &record.id;
        let observation = self
            .chat_ref(id)
            .filter(|c| c.controller.is_persistent())
            .map(|c| c.controller.read_observation());
        let result = (|| {
            let mut states = self.read_states.lock().unwrap();
            if let Some(o) = observation {
                states.observe(record, &o, false)?;
            }
            states.failures = 0;
            states.apply(
                record,
                if unread {
                    ReadEvent::MarkUnread
                } else {
                    ReadEvent::MarkRead
                },
                true,
                false,
            )
        })();
        match result {
            Ok(_) => self.flush_read_states(cx),
            Err(error) => self.error = Some(read_error_notice(&error)),
        }
        cx.notify();
    }
    pub(crate) fn read_attention(&self, record: &ChatRecord) -> (u64, bool, bool) {
        self.read_states
            .lock()
            .unwrap()
            .presentation(record)
            .map_or((0, false, false), |s| {
                (
                    s.row_count(record.archived_at.is_some()),
                    s.has_attention(record.archived_at.is_some()),
                    s.manual_only(record.archived_at.is_some()),
                )
            })
    }
    pub(crate) fn read_status(&self, record: &ChatRecord) -> Option<String> {
        let state = self.read_states.lock().unwrap().presentation(record)?;
        if record.archived_at.is_some() {
            return None;
        }
        let count = state.row_count(false);
        let mut label = if state.manual_only(false) {
            "Unread".to_owned()
        } else if count > 0 {
            format!(
                "{count} new {}",
                if count == 1 { "reply" } else { "replies" }
            )
        } else if state.unread_failure {
            "Needs attention".to_owned()
        } else {
            return None;
        };
        if count > 0 && state.unread_failure {
            label.push_str(" · Failed run");
        }
        Some(label)
    }
    // The independently fenced identities are deliberately explicit at this boundary.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn acknowledge_reply_end(
        &mut self,
        id: &str,
        source: &Weak<Controller>,
        target: &str,
        presentation_revision: u64,
        presentation_generation: &str,
        presentation_current: bool,
        window: &Window,
        cx: &mut Context<Self>,
    ) {
        if !presentation_current
            || !self.reading_surface(window, cx)
            || self.record.id != id
            || !source.ptr_eq(&Arc::downgrade(&self.controller))
            || self.loading
            || self.load_failed
        {
            return;
        }
        if !self
            .read_states
            .lock()
            .unwrap()
            .entry(&self.record)
            .is_some_and(|e| e.state.unread_count > 0 || e.state.unread_failure)
        {
            return;
        }
        if self.read_states.lock().unwrap().error.is_some() {
            return;
        }
        let observation = self.controller.read_observation();
        if !reply_observation_matches(
            &observation,
            target,
            presentation_revision,
            presentation_generation,
        ) {
            return;
        }
        let record = self.record.clone();
        let result = self.read_states.lock().unwrap().apply(
            &record,
            ReadEvent::Acknowledge { target },
            true,
            false,
        );
        match result {
            Ok(true) => {
                self.flush_read_states(cx);
                cx.notify();
            }
            Ok(false) => {}
            Err(error) => {
                self.error = Some(read_error_notice(&error));
                cx.notify();
            }
        }
    }
    fn invalidate_read_geometry(&self, cx: &mut Context<Self>) {
        let needs_proof = self
            .read_states
            .lock()
            .unwrap()
            .entry(&self.record)
            .is_some_and(|entry| entry.state.unread_count > 0 || entry.state.unread_failure);
        if needs_proof && let Some(transcript) = self.transcript.clone() {
            // Parent notification alone may reuse this cached child's paint.
            // Request a real post-layout proof, never infer visibility here.
            transcript.update(cx, |_, cx| cx.notify());
        }
    }
    pub(crate) fn refresh_read_geometry_route(&mut self, cx: &mut Context<Self>) {
        let ready = self.reading_route_ready(cx);
        let revealed = ready && !self.read_surface_ready;
        self.read_surface_ready = ready;
        if revealed {
            // Notifications issued inside parent render can be absorbed by the
            // current draw before the cached child's dirty set is consumed.
            // Invalidate after that render, with the exact surface identity.
            let owner = cx.weak_entity();
            let workspace = self.workspace.clone();
            let binding = self.window_binding;
            let id = self.record.id.clone();
            let source = Arc::downgrade(&self.controller);
            cx.defer(move |cx| {
                let _ = owner.update(cx, |view, cx| {
                    if Arc::ptr_eq(&view.workspace, &workspace)
                        && view.window_binding == binding
                        && view.record.id == id
                        && source.ptr_eq(&Arc::downgrade(&view.controller))
                        && view.reading_route_ready(cx)
                    {
                        view.invalidate_read_geometry(cx);
                    }
                });
            });
        }
    }
    #[cfg(all(test, not(target_os = "macos")))]
    pub(crate) fn failure_reader_present(&self, cx: &App) -> bool {
        failure_reader_evidence(
            true,
            !self.show_files && !self.changes_open && !self.shutting_down,
            application_active(cx),
        )
    }
    pub(crate) fn reading_surface(&self, window: &Window, cx: &App) -> bool {
        window.is_window_active() && self.current_reader_present(cx)
    }
    fn current_reader_present(&self, cx: &App) -> bool {
        native_readable(self.organization_window, cx) && self.reading_route_ready(cx)
    }
    fn reading_route_ready(&self, cx: &App) -> bool {
        !self.known_catalog_uncertainty
            && !self.read_states.lock().unwrap().fenced
            && self.record.archived_at.is_none()
            && !self.shutting_down
            && !self.close_ready
            && !self.close_dialog
            && !self.show_files
            && !self.changes_open
            && self.queue_detail.is_none()
            && self.sidebar_menu.is_none()
            && self.topic_panel.is_none()
            && self.compaction_menu.is_none()
            && self.conversation_content.is_none()
            && self.skill_picker.is_none()
            && self.attachment_picker.is_none()
            && !self.connections.picker
            && !self.quick_open.read(cx).is_open()
            && !self.projects.view.read(cx).is_open()
            && !self.connections.view.read(cx).is_open()
            && !self.mcp.view.read(cx).is_open()
    }
}

fn failure_reader_evidence(
    selected: bool,
    conversation_page: bool,
    application_active: bool,
) -> bool {
    selected && conversation_page && application_active
}
pub(crate) fn read_error_notice(error: &Error) -> String {
    match error {
        Error::PersistenceUncertain(detail) => {
            format!("{detail}. Live drafts are preserved in this app; new output remains blocked.")
        }
        _ => error.to_string(),
    }
}

fn reply_observation_matches(
    observation: &AcceptedReadObservation,
    target: &str,
    presentation_revision: u64,
    presentation_generation: &str,
) -> bool {
    observation.source_revision == presentation_revision
        && observation.generation == presentation_generation
        && matches!(&observation.history,OutputProjection::Known(summary) if summary.latest_id.as_deref()==Some(target))
}

/// Pure acceptance of explicitly sampled native evidence. This is not a way to
/// synthesize missing platform evidence; Linux's production gate remains false.
#[cfg(any(target_os = "macos", test))]
#[derive(Clone, Copy, Debug)]
pub(crate) struct NativeReadEvidence {
    pub active: bool,
    pub key: bool,
    pub visible: bool,
    pub minimized: bool,
    pub occlusion_visible: bool,
    pub attached_sheet: bool,
    pub hidden_view: bool,
    pub view_rect: [f64; 4],
}
#[cfg(any(target_os = "macos", test))]
impl NativeReadEvidence {
    pub(crate) fn readable(self) -> bool {
        self.active
            && self.key
            && self.visible
            && !self.minimized
            && self.occlusion_visible
            && !self.attached_sheet
            && !self.hidden_view
            && self.view_rect.iter().all(|v| v.is_finite())
            && self.view_rect[2] > 0.
            && self.view_rect[3] > 0.
    }
}

fn application_active(cx: &App) -> bool {
    #[cfg(all(target_os = "macos", not(test)))]
    {
        let _ = cx;
        crate::native_menu::application_active()
    }
    #[cfg(all(target_os = "macos", test))]
    {
        // TestAppContext has no NSApplication evidence; never invoke AppKit.
        let _ = cx;
        false
    }
    #[cfg(not(target_os = "macos"))]
    {
        cx.active_window().is_some_and(|active| {
            cx.windows()
                .iter()
                .any(|window| window.window_id() == active.window_id())
        })
    }
}

fn native_readable(window: Option<gpui::AnyWindowHandle>, cx: &App) -> bool {
    #[cfg(all(target_os = "macos", not(test)))]
    {
        window.is_some_and(|window| crate::native_menu::readable_window(window, cx))
    }
    #[cfg(any(not(target_os = "macos"), test))]
    {
        let _ = (window, cx);
        false
    } // GPUI has no verified Linux occlusion evidence.
}

#[cfg(test)]
#[path = "sidebar_read_state_tests.rs"]
mod tests;
