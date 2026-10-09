//! One app-lifetime owner for never-installed loaders. No provider/tool dispatch.
//! The owner has no view/task/runtime references, so Controller authority and
//! inspection permits cannot form cycles back through WorkspaceStore/Shared.
use crate::AgentView;
use bello_agent_core::{
    Controller, Error,
    inspection::{InspectionCancellation, InspectionPermit},
    workspace::WorkspaceStore,
};
use gpui::Context;
use std::{
    path::PathBuf,
    sync::{Arc, Mutex, OnceLock, Weak},
};
use uuid::Uuid;

pub(crate) const CLEANUP_BLOCKER: &str = "A previous chat opening has not closed safely. Retry workspace cleanup before opening another chat or closing.";
#[derive(Clone, Default)]
pub(crate) struct LoadRetirementOwner(Arc<Mutex<State>>);
#[derive(Default)]
struct State {
    entry: Option<Arc<Entry>>,
    retrying: Option<Uuid>,
    failed: bool,
    admission: InspectionCancellation,
    #[cfg(test)]
    hold_after_open: Option<InspectionCancellation>,
    #[cfg(test)]
    opened_signal: Option<InspectionCancellation>,
}
struct Entry {
    operation: Uuid,
    controller: OnceLock<Arc<Controller>>,
    _permit: InspectionPermit,
}
struct RetryGuard {
    owner: LoadRetirementOwner,
    operation: Uuid,
}
impl Drop for RetryGuard {
    fn drop(&mut self) {
        if let Ok(mut state) = self.owner.0.lock()
            && state.retrying == Some(self.operation)
        {
            state.retrying = None;
        }
    }
}
impl LoadRetirementOwner {
    pub(crate) fn occupied(&self) -> bool {
        self.0.lock().map_or(true, |s| s.entry.is_some())
    }
    pub(crate) fn failed(&self) -> bool {
        self.0.lock().map_or(true, |s| s.failed)
    }
    fn token(&self) -> Result<InspectionCancellation, String> {
        let state = self.0.lock().map_err(|_| CLEANUP_BLOCKER.to_owned())?;
        if state.failed {
            return Err(CLEANUP_BLOCKER.into());
        }
        Ok(state.admission.child_token())
    }
    fn reserve(&self, permit: InspectionPermit) -> Result<Arc<Entry>, String> {
        let mut state = self.0.lock().map_err(|_| CLEANUP_BLOCKER.to_owned())?;
        if state.entry.is_some() || state.failed {
            return Err(CLEANUP_BLOCKER.into());
        }
        let entry = Arc::new(Entry {
            operation: Uuid::new_v4(),
            controller: OnceLock::new(),
            _permit: permit,
        });
        state.entry = Some(entry.clone());
        Ok(entry)
    }
    fn abandon_empty(&self, entry: &Arc<Entry>) {
        if let Ok(mut state) = self.0.lock()
            && entry.controller.get().is_none()
            && state.entry.as_ref().is_some_and(|e| Arc::ptr_eq(e, entry))
        {
            state.entry = None;
        }
    }
    fn install(&self, entry: &Arc<Entry>) -> Option<Arc<Controller>> {
        let mut state = self.0.lock().ok()?;
        if state.failed
            || state.retrying.is_some()
            || !state.entry.as_ref().is_some_and(|e| Arc::ptr_eq(e, entry))
        {
            return None;
        }
        let controller = entry.controller.get()?.clone();
        state.entry = None;
        Some(controller)
    }
    pub(crate) async fn retry(&self) -> Result<(), String> {
        self.retry_with(|controller| async move {
            controller
                .retire_and_wait()
                .await
                .map_err(|_| CLEANUP_BLOCKER.to_owned())
        })
        .await
    }
    async fn retry_with<F, Fut>(&self, retire: F) -> Result<(), String>
    where
        F: FnOnce(Arc<Controller>) -> Fut,
        Fut: std::future::Future<Output = Result<(), String>>,
    {
        let (entry, controller) = {
            let mut state = self.0.lock().map_err(|_| CLEANUP_BLOCKER.to_owned())?;
            let Some(entry) = state.entry.clone() else {
                return Ok(());
            };
            if state.retrying.is_some() {
                return Err("Workspace cleanup is already running.".into());
            }
            let controller = entry.controller.get().cloned().ok_or_else(|| {
                "A chat opening is still settling. Retry workspace cleanup when it finishes."
                    .to_owned()
            })?;
            state.retrying = Some(entry.operation);
            (entry, controller)
        };
        let _guard = RetryGuard {
            owner: self.clone(),
            operation: entry.operation,
        };
        // Original controller and permit stay owned in the slot across await.
        let result = retire(controller).await;
        let mut state = self.0.lock().map_err(|_| CLEANUP_BLOCKER.to_owned())?;
        if !state.entry.as_ref().is_some_and(|e| Arc::ptr_eq(e, &entry)) {
            return Err(CLEANUP_BLOCKER.into());
        }
        match result {
            Ok(()) => {
                state.entry = None;
                if state.failed {
                    state.admission = InspectionCancellation::new();
                }
                state.failed = false;
                Ok(())
            }
            Err(_) => {
                state.failed = true;
                state.admission.cancel();
                Err(CLEANUP_BLOCKER.into())
            }
        }
    }
}
#[derive(Default)]
pub(crate) struct LoadCancellation(InspectionCancellation);
impl LoadCancellation {
    fn replace(&mut self, token: InspectionCancellation) {
        self.0.cancel();
        self.0 = token;
    }
    pub(crate) fn cancel(&self) {
        self.0.cancel();
    }
}
impl Drop for LoadCancellation {
    fn drop(&mut self) {
        self.cancel();
    }
}
struct Ticket {
    id: String,
    project: PathBuf,
    workspace: Weak<Mutex<WorkspaceStore>>,
    generation: u64,
    previous: Weak<Controller>,
    cancel: InspectionCancellation,
}
impl Ticket {
    fn same_target(&self, view: &AgentView) -> bool {
        self.project == view.project
            && self.workspace.ptr_eq(&Arc::downgrade(&view.workspace))
            && view.chat_ref(&self.id).is_some_and(|chat| {
                chat.load_generation == self.generation
                    && self.previous.ptr_eq(&Arc::downgrade(&chat.controller))
            })
    }
    fn admitted(&self, view: &AgentView) -> bool {
        self.same_target(view)
            && !self.cancel.is_cancelled()
            && !view.shutting_down
            && !view.close_ready
            && !view.known_catalog_uncertainty
            && !view.project_actions_blocked_without_load()
            && view.projects.operation.is_none()
            && !view.chat_mode_blocked.contains(&self.id)
            && !view.connections.switches.contains_key(&self.id)
    }
}
impl AgentView {
    pub(crate) fn cancel_queued_chat_loads(&mut self) {
        for chat in std::iter::once(&mut self.chat).chain(self.inactive.values_mut()) {
            chat.load_cancellation.cancel();
            if chat.loading {
                chat.loading = false;
                chat.load_failed = true;
                chat.error = Some(
                    "Chat opening was cancelled. Retry opening after workspace cleanup.".into(),
                );
            }
        }
    }
    /// Workspace-scoped recovery stays reachable regardless of selected chat's
    /// loading bit/generation. It cannot revive an old admission token.
    pub(crate) fn retry_workspace_load_cleanup(&mut self, cx: &mut Context<Self>) {
        self.cancel_queued_chat_loads();
        let owner = self.load_retirement.clone();
        let task = cx
            .background_executor()
            .spawn(async move { owner.retry().await });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                match result {
                    Err(error) if view.load_retirement.occupied() => view.error = Some(error),
                    Ok(())
                        if !view.load_retirement.occupied()
                            && view.error.as_deref() == Some(CLEANUP_BLOCKER) =>
                    {
                        view.error = None
                    }
                    _ => {}
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    pub(crate) fn begin_coordinated_chat_load(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.shutting_down
            || self.project_actions_blocked_without_load()
            || self.chat_mode_blocked.contains(id)
            || self.connections.switches.contains_key(id)
        {
            return;
        }
        if self
            .chat_ref(id)
            .is_none_or(|chat| chat.loading || chat.busy || chat.queue_operation.is_some())
        {
            return;
        }
        let token = match self.load_retirement.token() {
            Ok(token) => token,
            Err(error) => {
                if let Some(chat) = self.chat_mut(id) {
                    chat.loading = false;
                    chat.load_failed = true;
                    chat.error = Some(error.clone());
                }
                self.error = Some(error);
                cx.notify();
                return;
            }
        };
        self.sidebar_search.block(id);
        let runtime = self.runtime.clone();
        let workspace = self.workspace.clone();
        let project = self.project.clone();
        let owner = self.load_retirement.clone();
        let Some(chat) = self.chat_mut(id) else {
            return;
        };
        if chat.loading || chat.busy || chat.queue_operation.is_some() {
            return;
        }
        chat.load_generation = chat.load_generation.saturating_add(1);
        chat.loading = true;
        chat.load_failed = false;
        chat.error = None;
        chat.load_cancellation.replace(token.clone());
        let previous = chat.controller.clone();
        let record = chat.record.clone();
        let ticket = Arc::new(Ticket {
            id: id.into(),
            project,
            workspace: Arc::downgrade(&workspace),
            generation: chat.load_generation,
            previous: Arc::downgrade(&previous),
            cancel: token.clone(),
        });
        let executor = cx.background_executor().clone();
        let worker_previous = previous.clone();
        let acquire = executor.spawn(async move {
            let lane = workspace
                .lock()
                .map_err(|_| Error::Invalid("Workspace is unavailable".into()))?
                .inspection_coordinator();
            let request = lane.selected_open()?;
            worker_previous.retire_and_wait().await?;
            request.acquire_cancelled(&token).await
        });
        cx.spawn(async move |view, cx| {
            let permit = match acquire.await {
                Ok(permit) => permit,
                Err(error) => {
                    let _ = view.update(cx, |view, cx| {
                        finish_error(view, &ticket, error.to_string(), cx)
                    });
                    return;
                }
            };
            // Foreground admission recheck after potentially long queued wait.
            if !view
                .update(cx, |view, _| ticket.admitted(view))
                .unwrap_or(false)
            {
                drop(permit);
                let _=view.update(cx,|view,cx|finish_error(view,&ticket,"Chat opening was deferred because workspace admission changed. Retry opening when ready.".into(),cx));
                return;
            }
            let entry = match owner.reserve(permit) {
                Ok(entry) => entry,
                Err(error) => {
                    let _ = view.update(cx, |view, cx| finish_error(view, &ticket, error, cx));
                    return;
                }
            };
            let worker_entry = entry.clone();
            let worker_owner = owner.clone();
            let worker_ticket = ticket.clone();
            let opened = executor
                .spawn(async move {
                    if worker_ticket.cancel.is_cancelled() {
                        worker_owner.abandon_empty(&worker_entry);
                        return Err("Chat opening was cancelled.".into());
                    }
                    let result = match runtime.open_registered(&record) {
                        Ok(controller) => Ok((controller, None)),
                        Err(error) => {
                            runtime
                                .disconnected(&record, Some(&previous))
                                .map(|controller| {
                                    (controller, Some(format!("Chat is disconnected: {error}")))
                                })
                        }
                    };
                    match result {
                        Ok((controller, notice)) => {
                            // OnceLock is private to this single producer. The slot
                            // owns the fresh controller before any await/UI delivery.
                            if worker_entry.controller.set(controller).is_err() {
                                unreachable!("one producer per reserved loader")
                            }
                            #[cfg(test)]
                        {
                            let (gate, signal) = { let state = worker_owner.0.lock().unwrap(); (state.hold_after_open.clone(), state.opened_signal.clone()) };
                            if let Some(signal) = signal { signal.cancel(); }
                            if let Some(gate) = gate { gate.cancelled().await; }
                        }
                        Ok(notice)
                        }
                        Err(error) => {
                            worker_owner.abandon_empty(&worker_entry);
                            Err(error.to_string())
                        }
                    }
                })
                .await;
            let notice = match opened {
                Ok(notice) => notice,
                Err(error) => {
                    let _ = view.update(cx, |view, cx| finish_error(view, &ticket, error, cx));
                    return;
                }
            };
            let installed = view
                .update(cx, |view, cx| {
                    if !ticket.admitted(view) {
                        return false;
                    }
                    let Some(controller) = owner.install(&entry) else {
                        return false;
                    };
                    let Some(chat) = view.chat_mut(&ticket.id) else {
                        return false;
                    };
                    chat.loading = false;
                    chat.load_failed = false;
                    chat.replace_controller(controller, cx);
                    chat.error = notice;
                    view.sidebar_search.installed(&ticket.id);
                    let snapshot = view
                        .chat_ref(&ticket.id)
                        .filter(|chat| chat.controller.is_persistent())
                        .map(|chat| (Arc::downgrade(&chat.controller), chat.session.clone()));
                    if let Some((source, snapshot)) = snapshot {
                        view.receive_snapshot(&ticket.id, &source, snapshot, cx);
                    }
                    view.reconcile_edit(&ticket.id, cx);
                    view.reconcile_intents(&ticket.id, cx);
                    cx.notify();
                    true
                })
                .unwrap_or(false);
            if !installed {
                // A later UI invalidation can race the synchronous open. The
                // fresh actor was never installed or dispatched; retire it.
                let cleanup_owner=owner.clone();
                let cleanup = executor.spawn(async move {cleanup_owner.retry().await}).await;
                let _ = view.update(cx, |view, cx| {
                    if let Err(error) = cleanup {
                        if view.load_retirement.failed() {view.cancel_queued_chat_loads();view.error = Some(error);}
                    } else if ticket.same_target(view) {
                        finish_error(view, &ticket, "Chat opening was cancelled.".into(), cx);
                    }
                    cx.notify();
                });
            }
        })
        .detach();
        cx.notify();
    }
}
fn finish_error(view: &mut AgentView, ticket: &Ticket, error: String, cx: &mut Context<AgentView>) {
    if ticket.same_target(view)
        && let Some(chat) = view.chat_mut(&ticket.id)
    {
        chat.loading = false;
        chat.load_failed = true;
        chat.error = Some(format!("Chat could not be opened: {error}"));
        cx.notify();
    }
}
#[cfg(test)]
#[path = "chat_load_tests.rs"]
mod tests;
