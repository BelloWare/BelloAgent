//! Selected-workspace query owner. Only the shared inspection dispatcher runs
//! source work. Cached data never substitutes for a fresh reconciliation pass.
use crate::AgentView;
use crate::sidebar_cache_cleanup::{CleanupIntents, CleanupKind, CleanupRetry};
use bello_agent_core::{
    sidebar_search::{
        OwnedHit, SearchError, SearchOutcome, SearchRequest,
        reconciliation::{ObservationFailure, ReconciliationPass, SearchWork, SourceRoute},
    },
    workspace::{ChatMaterialization, WorkspaceStore},
};
use gpui::{App, Context};
use std::collections::BTreeSet;
use uuid::Uuid;

#[derive(Default)]
pub(crate) struct WorkerCache {
    pub(crate) cache: Option<bello_agent_core::sidebar_search::cache::PrivateCache>,
    binding: Option<bello_agent_core::sidebar_search::cache::CacheBinding>,
    disposal: Option<gpui::BackgroundExecutor>,
    registered: BTreeSet<String>,
}
impl WorkerCache {
    fn ensure(
        &mut self,
        binding: bello_agent_core::sidebar_search::cache::CacheBinding,
    ) -> Result<(), SearchError> {
        self.ensure_with(
            binding,
            bello_agent_core::sidebar_search::cache::PrivateCache::open,
        )
    }
    fn ensure_with(
        &mut self,
        binding: bello_agent_core::sidebar_search::cache::CacheBinding,
        open: impl FnOnce(
            bello_agent_core::sidebar_search::cache::CacheBinding,
        ) -> Result<
            bello_agent_core::sidebar_search::cache::PrivateCache,
            bello_agent_core::sidebar_search::cache::CacheError,
        >,
    ) -> Result<(), SearchError> {
        if self.disposal.is_none() {
            return Err(SearchError::Unavailable);
        }
        if self.binding.as_ref() != Some(&binding) || self.cache.is_none() {
            // Called on the membership worker, never on the UI thread.
            self.cache = None;
            self.binding = None;
            self.registered.clear();
            self.cache = Some(open(binding.clone()).map_err(|_| SearchError::Unavailable)?);
            self.binding = Some(binding);
        }
        if self.cache.is_none() {
            return Err(SearchError::Unavailable);
        }
        Ok(())
    }
}
impl Drop for WorkerCache {
    fn drop(&mut self) {
        if let Some(cache) = self.cache.take() {
            // This executor is installed before opening the connection. Use the
            // application's existing background ownership, not a fallible new
            // OS thread created from a foreground release callback.
            if let Some(executor) = self.disposal.take() {
                executor
                    .spawn(async move {
                        drop(cache);
                    })
                    .detach();
            }
        }
    }
}
#[derive(Clone)]
pub(crate) struct RevealAdmission {
    revoked: std::sync::Arc<std::sync::atomic::AtomicBool>,
    cache: bello_agent_core::sidebar_search::cache::CacheQueryHandle,
}
impl RevealAdmission {
    pub(crate) fn is_current(&self) -> bool {
        !self.revoked.load(std::sync::atomic::Ordering::Acquire)
            && self.cache.readiness().is_ready()
    }
}
pub(crate) struct SidebarSearch {
    request: Option<SearchRequest>,
    reveal_revoked: std::sync::Arc<std::sync::atomic::AtomicBool>,
    generation: u64,
    exhausted: bool,
    pub(crate) pass: Option<ReconciliationPass>,
    pending: BTreeSet<String>,
    served: BTreeSet<String>,
    changed_during_capture: BTreeSet<String>,
    cleanup: CleanupIntents,
    cleanup_retry: CleanupRetry,
    cleanup_timer: Option<Uuid>,
    shown: BTreeSet<String>,
    explicit_results: bool,
    routes: crate::sidebar_search_state::SearchLifecycles,
    pub(super) query: String,
    pub(super) epoch: Uuid,
    preparing: bool,
    completion_checked: bool,
    debounce: Option<Uuid>,
    composing: bool,
    // This is deliberately fail-closed until the integrated cache/privacy and
    // platform acceptance receipt is installed. No environment-variable bypass.
    readiness: bello_agent_core::sidebar_search::cache::CacheReadiness,
    live_cache: Option<bello_agent_core::sidebar_search::cache::CacheQueryHandle>,
    pub(crate) cache: WorkerCache,
    pub(crate) status: &'static str,
}
impl Default for SidebarSearch {
    fn default() -> Self {
        Self {
            request: None,
            reveal_revoked: Default::default(),
            generation: 0,
            exhausted: false,
            pass: None,
            pending: BTreeSet::new(),
            served: BTreeSet::new(),
            changed_during_capture: BTreeSet::new(),
            cleanup: Default::default(),
            cleanup_retry: Default::default(),
            cleanup_timer: None,
            shown: BTreeSet::new(),
            explicit_results: false,
            routes: Default::default(),
            query: String::new(),
            epoch: Uuid::new_v4(),
            preparing: false,
            completion_checked: false,
            debounce: None,
            composing: false,
            readiness: bello_agent_core::sidebar_search::cache::CacheReadiness::production(),
            live_cache: None,
            cache: Default::default(),
            status: bello_agent_core::sidebar_search::cache::CacheReadiness::production().reason(),
        }
    }
}
impl SidebarSearch {
    #[cfg(test)]
    pub(crate) fn test_route(&self, id: &str) -> Option<SourceRoute> {
        self.routes.route(id)
    }
    pub(crate) fn cancel(&mut self) {
        self.reveal_revoked
            .store(true, std::sync::atomic::Ordering::Release);
        self.reveal_revoked = Default::default();
        if let Some(request) = self.request.take() {
            request.cancel();
        }
        self.pass = None;
        self.pending.clear();
        self.served.clear();
        self.changed_during_capture.clear();
        self.epoch = Uuid::new_v4();
        self.preparing = false;
        self.debounce = None;
        self.completion_checked = false;
    }
    pub(crate) fn block(&mut self, id: &str) {
        self.routes.block(id);
        self.cleanup.insert(id.into(), CleanupKind::Invalidate);
        self.cleanup_retry.reset();
        self.cleanup_timer = None;
        // Also revokes an in-flight membership capture that has not installed a
        // pass yet. The shared dispatch lease remains owned until worker exit.
        self.cancel();
    }
    pub(crate) fn block_all(&mut self) -> crate::sidebar_search_state::SearchRestore {
        for id in self.routes.ids() {
            self.cleanup.insert(id.into(), CleanupKind::Invalidate);
        }
        self.cleanup_retry.reset();
        self.cleanup_timer = None;
        let restore = self.routes.block_all();
        self.cancel();
        restore
    }
    pub(crate) fn restore_operation(
        &mut self,
        restore: crate::sidebar_search_state::SearchRestore,
        only_unloaded: bool,
    ) {
        self.routes.restore(restore, only_unloaded);
        self.cancel();
    }
    pub(crate) fn block_members(
        &mut self,
        members: Vec<(String, bool)>,
    ) -> crate::sidebar_search_state::SearchRestore {
        for (id, loaded) in &members {
            if self.routes.route(id).is_none() {
                self.routes.set(
                    id.clone(),
                    if *loaded {
                        SourceRoute::Loaded
                    } else {
                        SourceRoute::Unloaded
                    },
                );
            }
            self.cleanup.insert(id.clone(), CleanupKind::Invalidate);
        }
        let restore = self
            .routes
            .block_members(members.into_iter().map(|(id, _)| id));
        self.cancel();
        self.cleanup_retry.reset();
        self.cleanup_timer = None;
        restore
    }
    pub(crate) fn installed(&mut self, id: &str) {
        self.routes.loaded(id);
        self.cancel();
    }
    pub(crate) fn restore_cache(&mut self, cache: WorkerCache) {
        self.live_cache = cache.cache.as_ref().map(|value| value.query_handle());
        if let Some(value) = &cache.cache {
            self.readiness = value.readiness();
            if !self.readiness.is_ready() {
                self.cancel();
                self.status = "Private content cache cleanup is pending";
            }
        }
        self.cache = cache;
    }
    pub(crate) fn can_refresh(&self) -> bool {
        self.readiness.is_ready() || self.cache.cache.is_some()
    }
    pub(crate) fn request(&self) -> Option<SearchRequest> {
        self.request.clone()
    }
    pub(crate) fn next_id(&self) -> Option<&str> {
        // A repeatedly changing loaded row cannot overtake never-visited members.
        self.pending
            .iter()
            .find(|id| !self.served.contains(*id))
            .or_else(|| self.pending.first())
            .map(String::as_str)
    }
    pub(crate) fn source_changed(&mut self, id: &str) {
        self.completion_checked = false;
        let route = self.routes.route(id).unwrap_or(SourceRoute::Blocked);
        if let Some(pass) = &mut self.pass {
            if pass.transition(id, route).is_err() {
                // Membership itself changed or resource generation exhausted.
                self.cancel();
                return;
            }
            if route != SourceRoute::Blocked {
                self.pending.insert(id.into());
            }
        } else if self.request.is_some() {
            self.changed_during_capture.insert(id.into());
        }
    }
    fn apply_captured_changes(&mut self) {
        for id in std::mem::take(&mut self.changed_during_capture) {
            self.source_changed(&id);
        }
    }
    pub(crate) fn take_work(&mut self, id: &str) -> Option<SearchWork> {
        if !self.pending.remove(id) {
            return None;
        }
        self.served.insert(id.into());
        self.pass.as_mut()?.work(id).ok()
    }
    pub(crate) fn failed(&mut self, work: &SearchWork) {
        if let Some(pass) = &mut self.pass {
            let _ = pass.record_failure(work, ObservationFailure::Invalid);
        }
    }
    fn sync_results(&mut self, ids: impl IntoIterator<Item = String>, held: bool) {
        let Some(pass) = &self.pass else {
            return;
        };
        let mut valid = BTreeSet::new();
        for id in ids {
            // Preserve only admission credit while a previously visible member
            // is rechecked. `hit` still requires a fresh Match and live barrier.
            match pass.outcome(&id) {
                Ok(Some(SearchOutcome::Match(_)))
                    if !held || self.explicit_results || self.shown.contains(&id) =>
                {
                    valid.insert(id);
                }
                Ok(None) if self.shown.contains(&id) => {
                    valid.insert(id);
                }
                Err(_) if pass.failure(&id).is_none() && self.shown.contains(&id) => {
                    valid.insert(id);
                }
                _ => {}
            }
        }
        self.shown = valid;
    }
    pub(crate) fn reveal_admission(&self) -> Option<RevealAdmission> {
        let cache = self.live_cache.clone()?;
        cache.readiness().is_ready().then(|| RevealAdmission {
            revoked: self.reveal_revoked.clone(),
            cache,
        })
    }
    pub(crate) fn reveal_settled(&self) -> bool {
        self.completion_checked
            && !self.preparing
            && self.pending.is_empty()
            && self.cleanup.is_empty()
            && self.pass.is_some()
            && self.cache_ready()
    }
    pub(crate) fn cache_ready(&self) -> bool {
        self.live_cache
            .as_ref()
            .is_some_and(|handle| handle.readiness().is_ready())
    }
    pub(crate) fn hit(&self, id: &str) -> Option<&OwnedHit> {
        if !self.cache_ready() || !self.cleanup.is_empty() || !self.shown.contains(id) {
            return None;
        }
        match self.pass.as_ref()?.outcome(id).ok()?? {
            SearchOutcome::Match(hit) => Some(hit),
            SearchOutcome::NoMatch => None,
        }
    }
}
impl Drop for SidebarSearch {
    fn drop(&mut self) {
        self.cancel();
    }
}

impl AgentView {
    #[cfg(all(debug_assertions, target_os = "linux", feature = "synthetic-authority"))]
    pub(crate) fn install_synthetic_sidebar_cache(
        &mut self,
        prepared: crate::synthetic_sidebar_fixture::PreparedCache,
        cx: &mut Context<Self>,
    ) -> bool {
        if !prepared.matches_workspace(&self.workspace) {
            cx.background_executor()
                .spawn(async move {
                    drop(prepared);
                })
                .detach();
            return false;
        }
        let (binding, cache) = prepared.into_parts();
        self.sidebar_search.restore_cache(WorkerCache {
            cache: Some(cache),
            binding: Some(binding),
            disposal: Some(cx.background_executor().clone()),
            registered: BTreeSet::new(),
        });
        self.sidebar_search.status = "Synthetic validation: private fixture content cache ready";
        cx.notify();
        true
    }
    pub(crate) fn finish_sidebar_cache_owner(
        &mut self,
        owner: &std::sync::Weak<std::sync::Mutex<WorkspaceStore>>,
        cache: WorkerCache,
    ) -> bool {
        if !owner.ptr_eq(&std::sync::Arc::downgrade(&self.workspace)) {
            return false;
        }
        self.sidebar_search.restore_cache(cache);
        true
    }
    pub(crate) fn sidebar_search_scope_blocked(&self) -> bool {
        self.shutting_down
            || self.close_ready
            || self.known_catalog_uncertainty
            || self.window_binding.is_none()
            || self.project_actions_blocked_without_load()
            || self.projects.operation.is_some()
            || self.connections.uncertain
            || self.connections.operation.is_some()
            || !self.chat_mode_operations.is_empty()
    }
    pub(crate) fn sidebar_content_hit(&self, id: &str) -> Option<&OwnedHit> {
        if self.sidebar_search_scope_blocked() || !self.sidebar_search.cleanup.is_empty() {
            return None;
        }
        self.sidebar_search.hit(id)
    }
    pub(crate) fn refresh_sidebar_search(&mut self, cx: &mut Context<Self>) {
        // Revoke reveal before any cleanup/debounce/length early return. Text
        // replacement and global admission changes invalidate geometry too.
        if self.filter.read(cx).text() != self.sidebar_search.query
            || self.filter.read(cx).has_marked_text()
            || self.sidebar_search_scope_blocked()
            || !self.sidebar_search.readiness.is_ready()
        {
            self.cancel_sidebar_reveal(cx);
        }
        if !self.sidebar_search.cache_ready() {
            self.suspend_sidebar_cache_reveal(cx);
        }
        self.sidebar_search.sync_results(
            self.records.iter().map(|record| record.id.clone()),
            self.sidebar_activity_hold.active(),
        );
        if !self.sidebar_search.cleanup.is_empty()
            && self.sidebar_search.cache.cache.is_some()
            && self.sidebar_run_states.is_idle()
            && !self.sidebar_search.cleanup_retry.waiting
        {
            let operation = Uuid::new_v4();
            if self.sidebar_run_states.reserve_reveal(operation) {
                let mut cache = std::mem::take(&mut self.sidebar_search.cache);
                let mut cleanup = std::mem::take(&mut self.sidebar_search.cleanup);
                let owner = std::sync::Arc::downgrade(&self.workspace);
                let task = cx.background_executor().spawn(async move {
                    if let Some(cache) = cache.cache.as_mut() {
                        cleanup.drain(cache);
                    }
                    (cache, cleanup)
                });
                cx.spawn(async move |view, cx| {
                    let (cache, cleanup) = task.await;
                    let _ = view.update(cx, |view, cx| {
                        view.sidebar_run_states.finish_reveal(operation);
                        if !view.finish_sidebar_cache_owner(&owner, cache) {
                            return;
                        }
                        view.sidebar_search.cleanup.merge(cleanup);
                        if view.sidebar_search.cleanup.is_empty() {
                            view.sidebar_search.cleanup_retry.reset();
                        } else {
                            view.sidebar_search.status =
                                "Private cache cleanup is pending; change the query to retry";
                            if let Some(delay) = view.sidebar_search.cleanup_retry.failed() {
                                view.sidebar_search.cleanup_timer = Some(operation);
                                let timer = cx
                                    .background_executor()
                                    .timer(std::time::Duration::from_millis(delay));
                                cx.spawn(async move |view, cx| {
                                    timer.await;
                                    let _ = view.update(cx, |view, cx| {
                                        if view.sidebar_search.cleanup_timer == Some(operation) {
                                            view.sidebar_search.cleanup_timer = None;
                                            view.sidebar_search.cleanup_retry.waiting = false;
                                            cx.notify();
                                        }
                                    });
                                })
                                .detach();
                            }
                        }
                        cx.notify();
                    });
                })
                .detach();
            }
            return;
        }
        if self.filter.read(cx).has_marked_text() {
            self.sidebar_search.composing = true;
            self.sidebar_search.cancel();
            return;
        }
        let committed_after_composition = std::mem::take(&mut self.sidebar_search.composing);
        if self.filter.read(cx).text().len()
            > bello_agent_core::sidebar_search::projection::MAX_QUERY_BYTES
        {
            self.sidebar_search.cancel();
            self.sidebar_search.status = "Search phrase exceeds the supported limit";
            return;
        }
        let query = self.filter.read(cx).text().to_owned();
        if query != self.sidebar_search.query || committed_after_composition {
            self.sidebar_search.cleanup_retry.reset();
            self.sidebar_search.cleanup_timer = None;
            self.sidebar_search.shown.clear();
            self.sidebar_search.explicit_results = true;
            self.cancel_sidebar_reveal(cx);
            self.sidebar_search.cancel();
            let Some(generation) = self.sidebar_search.generation.checked_add(1) else {
                self.sidebar_search.exhausted = true;
                self.sidebar_search.status = "Search generation is exhausted";
                return;
            };
            self.sidebar_search.generation = generation;
            self.sidebar_search.query = query.clone();
            self.sidebar_search.debounce = Some(self.sidebar_search.epoch);
            let epoch = self.sidebar_search.epoch;
            let timer = cx
                .background_executor()
                .timer(std::time::Duration::from_millis(120));
            cx.spawn(async move |view, cx| {
                timer.await;
                let _ = view.update(cx, |view, cx| {
                    if view.sidebar_search.epoch == epoch {
                        view.sidebar_search.debounce = None;
                        view.refresh_sidebar_search(cx);
                        cx.notify();
                    }
                });
            })
            .detach();
        }
        if !self.sidebar_search.cleanup.is_empty() {
            return;
        }
        if self.sidebar_search.exhausted
            || !self.sidebar_search.readiness.is_ready()
            || self.sidebar_search_scope_blocked()
        {
            self.sidebar_search.cancel();
            return;
        }
        if self.filter.read(cx).has_marked_text() {
            self.sidebar_search.cancel();
            return;
        }
        if self.sidebar_search.debounce.is_some() {
            return;
        }
        let stale: Vec<_> = self
            .sidebar_search
            .pass
            .as_ref()
            .map(|pass| {
                self.records
                    .iter()
                    .filter(|record| {
                        matches!(
                            pass.outcome(&record.id),
                            Err(SearchError::Stale | SearchError::WrongRequest)
                        )
                    })
                    .map(|record| record.id.clone())
                    .collect()
            })
            .unwrap_or_default();
        for id in stale {
            self.sidebar_search.source_changed(&id);
        }
        if self.sidebar_search.request.is_some() {
            if !self.sidebar_search.preparing
                && !self.sidebar_search.completion_checked
                && self.sidebar_search.pending.is_empty()
                && self.sidebar_run_states.is_idle()
                && let Some(pass) = self.sidebar_search.pass.take()
            {
                self.sidebar_search.preparing = true;
                let workspace = self.workspace.clone();
                let epoch = self.sidebar_search.epoch;
                let task = cx.background_executor().spawn(async move {
                    let coverage = WorkspaceStore::search_membership_snapshot(&workspace)
                        .map_err(|_| SearchError::Unavailable)
                        .and_then(|membership| pass.finish(&membership));
                    (pass, coverage)
                });
                cx.spawn(async move |view, cx| {
                    let (pass, coverage) = task.await;
                    let _ = view.update(cx, |view, cx| {
                        if view.sidebar_search.epoch != epoch {
                            return;
                        }
                        view.sidebar_search.preparing = false;
                        view.sidebar_search.completion_checked = true;
                        view.sidebar_search.explicit_results = false;
                        match coverage {
                            Ok(coverage) => {
                                use bello_agent_core::sidebar_search::reconciliation::CoverageState;
                                view.sidebar_search.status = match coverage.state {
                                    CoverageState::CompleteAsOf => {
                                        "Saved content checked as of this pass"
                                    }
                                    CoverageState::Pending => "Checking saved chat content…",
                                    CoverageState::Unavailable => {
                                        "Some saved content is unavailable"
                                    }
                                };
                                view.sidebar_search.pass = Some(pass);
                                view.sidebar_search.apply_captured_changes();
                            }
                            Err(_) => {
                                view.sidebar_search.cancel();
                                view.sidebar_search.status =
                                    "Saved content changed; checking again…";
                            }
                        }
                        cx.notify();
                    });
                })
                .detach();
            }
            return;
        }
        if self.sidebar_search.preparing || !self.sidebar_run_states.is_idle() {
            return;
        }
        let request = match SearchRequest::new(&query, self.sidebar_search.generation) {
            Ok(request) => request,
            Err(_) => {
                self.sidebar_search.status = "Enter a searchable phrase";
                return;
            }
        };
        // Populate known ownership before acquiring membership. Map absence never
        // removes a sticky retirement/failure record from this separate ledger.
        for record in &self.records {
            let route = if let Some(chat) = self.chat_ref(&record.id) {
                if chat.loading
                    || chat.load_failed
                    || chat.pending
                    || self.sidebar_search.routes.route(&record.id) == Some(SourceRoute::Blocked)
                {
                    SourceRoute::Blocked
                } else {
                    SourceRoute::Loaded
                }
            } else if record.materialization != ChatMaterialization::CheckpointRequired {
                SourceRoute::Blocked
            } else {
                self.sidebar_search
                    .routes
                    .route(&record.id)
                    .unwrap_or(SourceRoute::Unloaded)
            };
            self.sidebar_search.routes.set(record.id.clone(), route);
        }
        let routes = self.sidebar_search.routes.clone();
        let operation = Uuid::new_v4();
        if !self.sidebar_run_states.reserve_reveal(operation) {
            return;
        }
        // A new binding may replace the cache. Release this reader lease before
        // the worker closes/reopens its namespace; the canceled pass admits no hits.
        self.sidebar_search.live_cache = None;
        let mut cache = std::mem::take(&mut self.sidebar_search.cache);
        cache.disposal = Some(cx.background_executor().clone());
        let workspace = self.workspace.clone();
        let owner = std::sync::Arc::downgrade(&workspace);
        let epoch = self.sidebar_search.epoch;
        let binding = self.window_binding;
        self.sidebar_search.preparing = true;
        self.sidebar_search.request = Some(request.clone());
        self.sidebar_search.status = "Checking saved chat content…";
        let task = cx.background_executor().spawn(async move {
            let mut cleanup = CleanupIntents::default();
            let result = (|| {
                let membership = WorkspaceStore::search_membership_snapshot(&workspace)
                    .map_err(|_| SearchError::Unavailable)?;
                let cache_binding =
                    bello_agent_core::sidebar_search::cache::CacheBinding::from_membership(
                        membership.stamp(),
                    )
                    .map_err(|_| SearchError::Unavailable)?;
                cache.ensure(cache_binding)?;
                let registered: BTreeSet<_> = membership
                    .members()
                    .iter()
                    .map(|member| member.chat_id().to_owned())
                    .collect();
                for id in cache.registered.difference(&registered) {
                    cleanup.insert(id.clone(), CleanupKind::Delete);
                }
                if !cleanup.drain(cache.cache.as_mut().ok_or(SearchError::Unavailable)?) {
                    return Err(SearchError::Unavailable);
                }
                let mut pass = ReconciliationPass::begin(&request, &membership)?;
                let mut pending = BTreeSet::new();
                for member in membership.members() {
                    if member.materialization() != ChatMaterialization::CheckpointRequired {
                        continue;
                    }
                    let route = routes
                        .route(member.chat_id())
                        .unwrap_or(SourceRoute::Blocked);
                    pass.transition(member.chat_id(), route)?;
                    if route != SourceRoute::Blocked {
                        pending.insert(member.chat_id().to_owned());
                    }
                }
                cache.registered = registered;
                Ok::<_, SearchError>((pass, pending))
            })();
            (cache, cleanup, result)
        });
        cx.spawn(async move |view, cx| {
            let (cache, cleanup, result) = task.await;
            let _ = view.update(cx, |view, cx| {
                view.sidebar_run_states.finish_reveal(operation);
                // Cache disposal and cleanup ownership belong to the workspace,
                // even if a new query or window superseded result publication.
                if !view.finish_sidebar_cache_owner(&owner, cache) {
                    return;
                }
                view.sidebar_search.cleanup.merge(cleanup);
                if view.sidebar_search.epoch != epoch || view.window_binding != binding {
                    cx.notify();
                    return;
                }
                view.sidebar_search.preparing = false;
                match result {
                    Ok((pass, pending)) => {
                        view.sidebar_search.pass = Some(pass);
                        view.sidebar_search.pending = pending;
                        view.sidebar_search.apply_captured_changes();
                    }
                    Err(_) => {
                        view.sidebar_search.status = "Saved content is unavailable";
                    }
                }
                view.refresh_sidebar_run_states(cx);
                cx.notify();
            });
        })
        .detach();
    }
    pub(crate) fn refresh_saved_content(&mut self, cx: &mut Context<Self>) {
        if !self.sidebar_search.can_refresh() {
            return;
        }
        self.sidebar_search.cancel();
        self.sidebar_search.explicit_results = true;
        self.sidebar_search.cleanup_retry.reset();
        self.sidebar_search.cleanup_timer = None;
        self.refresh_sidebar_search(cx);
        cx.notify();
    }
    pub(crate) fn sidebar_search_matches(&self, id: &str, _cx: &App) -> bool {
        self.sidebar_content_hit(id).is_some()
    }
}

#[cfg(test)]
#[path = "sidebar_search_controller_tests.rs"]
mod tests;
