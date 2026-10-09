//! App-owned organization FIFO. Intent admission is synchronous; disk writes and
//! navigation are distinct confirmation boundaries, and neither resumes work.
use crate::{AgentView, workspace_lifetime::WindowBinding};
use bello_agent_core::workspace::{ChatRecord, organization_timestamp};
use gpui::*;
use std::{collections::VecDeque, path::PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum OrganizationAction {
    SetPinned(bool),
    SetArchived(bool),
}
#[derive(Clone)]
pub(crate) struct OrganizationIntent {
    pub token: uuid::Uuid,
    pub action: OrganizationAction,
    project: PathBuf,
    id: String,
    snapshot: PathBuf,
    navigation: u64,
    selected: String,
    binding: Option<WindowBinding>,
    window: Option<AnyWindowHandle>,
    running: bool,
}
#[derive(Default)]
pub(crate) struct OrganizationQueue {
    pub intents: VecDeque<OrganizationIntent>,
}
#[derive(Clone)]
pub(crate) struct OrganizationError {
    target_id: String,
    action: Option<OrganizationAction>,
    message: String,
}
/// Retain both the typed error and certainty of the locked catalog, including
/// Invalid refusals after another writer first made that catalog uncertain.
pub(crate) struct CatalogOutcome<T> {
    pub result: bello_agent_core::Result<T>,
    pub uncertain: bool,
}
pub(crate) fn catalog_error(error: &bello_agent_core::Error, uncertain: bool) -> String {
    if uncertain {
        "Workspace save is unconfirmed. Live drafts are preserved in this app; new chat actions are blocked.".into()
    } else {
        error.to_string()
    }
}
impl<T> CatalogOutcome<T> {
    pub(crate) fn display_result(self) -> Result<T, String> {
        self.result
            .map_err(|error| catalog_error(&error, self.uncertain))
    }
}
pub(crate) fn catalog_operation<T>(
    workspace: &std::sync::Mutex<bello_agent_core::workspace::WorkspaceStore>,
    operation: impl FnOnce(
        &mut bello_agent_core::workspace::WorkspaceStore,
    ) -> bello_agent_core::Result<T>,
) -> CatalogOutcome<T> {
    match workspace.lock() {
        Ok(mut store) => {
            let result = operation(&mut store);
            CatalogOutcome {
                result,
                uncertain: store.is_uncertain(),
            }
        }
        Err(_) => CatalogOutcome {
            result: Err(bello_agent_core::Error::Invalid(
                "Workspace is unavailable".into(),
            )),
            uncertain: false,
        },
    }
}

impl AgentView {
    pub(crate) fn chat_is_archived(&self, id: &str) -> bool {
        self.records
            .iter()
            .find(|record| record.id == id)
            .is_some_and(|record| record.archived_at.is_some())
    }
    pub(crate) fn has_pending_archive(&self, id: &str) -> bool {
        self.organization_operations.get(id).is_some_and(|queue| {
            queue
                .intents
                .iter()
                .any(|intent| intent.action == OrganizationAction::SetArchived(true))
        })
    }
    pub(crate) fn actor_mutation_blocked(&self, id: &str) -> bool {
        self.project_actions_blocked()
            || self.connections.uncertain
            || self.connections.blocked.contains(id)
            || self.connections.switches.contains_key(id)
            || self.chat_mode_blocked.contains(id)
            || self.known_catalog_uncertainty
            || self.chat_is_archived(id)
            || self.has_pending_archive(id)
    }
    pub(crate) fn advance_navigation(&mut self, cx: &mut Context<Self>) -> bool {
        // A normal in-progress loader queues subsequent chat opens. Only its
        // failed cleanup fences navigation; other project gates are unchanged.
        if self.project_actions_blocked_without_load() || self.load_retirement.failed() {
            return false;
        }
        let Some(next) = self.navigation_generation.checked_add(1) else {
            self.error =
                Some("Navigation revision limit reached; the current chat is preserved.".into());
            cx.notify();
            return false;
        };
        self.clear_transcript_find(cx);
        self.navigation_generation = next;
        true
    }
    pub(crate) fn focus_visible_composer(&self, window: &mut Window, cx: &App) {
        if !self.chat_is_archived(&self.record.id) {
            self.composer.read(cx).focus(window);
        } else {
            #[cfg(not(target_os = "macos"))]
            self.root_focus.focus(window);
        }
    }
    pub(crate) fn set_chat_pinned(&mut self, id: &str, pinned: bool, cx: &mut Context<Self>) {
        self.enqueue_organization(id, OrganizationAction::SetPinned(pinned), cx);
    }
    pub(crate) fn set_chat_archived(&mut self, id: &str, archived: bool, cx: &mut Context<Self>) {
        self.enqueue_organization(id, OrganizationAction::SetArchived(archived), cx);
    }
    pub(crate) fn enqueue_organization(
        &mut self,
        id: &str,
        action: OrganizationAction,
        cx: &mut Context<Self>,
    ) {
        if self.shutting_down
            || self.project_actions_blocked()
            || self.chat_mode_blocked.contains(id)
            || self.connections.switches.contains_key(id)
            || self.connections.blocked.contains(id)
        {
            return;
        }
        let Some(record) = self.records.iter().find(|record| record.id == id) else {
            return;
        };
        if self.known_catalog_uncertainty {
            self.organization_failure(id, Some(action), "Chat change was not confirmed: the workspace has an unconfirmed save. Your live drafts are preserved.".into());
            cx.notify();
            return;
        }
        let intent = OrganizationIntent {
            token: uuid::Uuid::new_v4(),
            action,
            project: self.project.clone(),
            id: id.into(),
            snapshot: record.snapshot.clone(),
            navigation: self.navigation_generation,
            selected: self.record.id.clone(),
            binding: self.window_binding,
            window: self.organization_window,
            running: false,
        };
        if action == OrganizationAction::SetArchived(true) {
            self.defer_cancel_for_archive(id);
        }
        self.organization_operations
            .entry(id.into())
            .or_default()
            .intents
            .push_back(intent);
        self.request_organization_drain(cx);
        cx.notify();
    }
    pub(crate) fn request_organization_drain(&mut self, cx: &mut Context<Self>) {
        if self.organization_drain_scheduled || self.organization_operations.is_empty() {
            return;
        }
        self.organization_drain_scheduled = true;
        let owner = cx.weak_entity();
        cx.defer(move |cx| {
            let _ = owner.update(cx, |view, cx| {
                view.organization_drain_scheduled = false;
                view.drain_organization(cx);
            });
        });
    }
    fn drain_organization(&mut self, cx: &mut Context<Self>) {
        if self.known_catalog_uncertainty {
            self.block_queued_organization(cx);
            return;
        }
        let heads: Vec<_> = self
            .organization_operations
            .values()
            .filter_map(|queue| queue.intents.front())
            .filter(|intent| !intent.running)
            .cloned()
            .collect();
        for intent in heads {
            if intent.project != self.project
                || !self
                    .records
                    .iter()
                    .any(|record| record.id == intent.id && record.snapshot == intent.snapshot)
            {
                self.release_organization(&intent, cx);
                continue;
            }
            if intent.action == OrganizationAction::SetArchived(true)
                && self.archive_chat_work_live(&intent.id)
            {
                continue;
            }
            let record = self
                .records
                .iter()
                .find(|record| record.id == intent.id)
                .unwrap()
                .clone();
            let draft = self
                .chat_ref(&intent.id)
                .map(|chat| chat.saved_draft(cx))
                .unwrap_or_else(|| {
                    self.unloaded_drafts
                        .get(&intent.id)
                        .cloned()
                        .unwrap_or_default()
                });
            self.organization_operations
                .get_mut(&intent.id)
                .unwrap()
                .intents
                .front_mut()
                .unwrap()
                .running = true;
            // Stop is a request, not a provider acknowledgement. Retained loaded
            // controllers cover even the reserved-worker interval.
            if intent.action == OrganizationAction::SetArchived(true)
                && let Some(chat) = self.chat_mut(&intent.id)
                && let Err(error) = chat.controller.stop()
            {
                chat.archive_stop_warning =
                    Some(format!("Archive requested, but Stop failed: {error}"));
            }
            let workspace = self.workspace.clone();
            let action = intent.action;
            let task = cx.background_executor().spawn(async move {
                catalog_operation(&workspace, |store| match action {
                    OrganizationAction::SetPinned(pinned) => store
                        .set_pinned(record, draft, pinned, organization_timestamp())
                        .map(|record| (record, false)),
                    OrganizationAction::SetArchived(archived) => store
                        .set_archived(record, draft, archived, organization_timestamp())
                        .map(|change| (change.record, change.changed)),
                })
            });
            cx.spawn(async move |owner, cx| {
                let outcome = task.await;
                let fallback = owner
                    .update(cx, |view, cx| {
                        view.finish_organization(&intent, outcome, cx)
                    })
                    .ok()
                    .flatten();
                if let Some(destination) = fallback {
                    if let Some(window) = intent.window {
                        let _ = window.update(cx, |_, window, cx| {
                            let _ = owner.update(cx, |view, cx| {
                                if view.organization_owns_navigation(&intent)
                                    && view.records.iter().any(|record| {
                                        record.id == destination && record.archived_at.is_none()
                                    })
                                {
                                    view.select_chat_internal(&destination, false, window, cx);
                                }
                                view.release_organization(&intent, cx);
                            });
                        });
                    }
                    // A removed native window must not retain a FIFO head.
                    let _ = owner.update(cx, |view, cx| view.release_organization(&intent, cx));
                }
            })
            .detach();
        }
    }
    fn current_organization(&self, intent: &OrganizationIntent) -> bool {
        self.project == intent.project
            && self
                .organization_operations
                .get(&intent.id)
                .and_then(|queue| queue.intents.front())
                .is_some_and(|head| head.token == intent.token)
    }
    fn organization_owns_navigation(&self, intent: &OrganizationIntent) -> bool {
        self.current_organization(intent)
            && self.window_binding == intent.binding
            && self.navigation_generation == intent.navigation
            && self.record.id == intent.selected
            && self.record.id == intent.id
            && !self.shutting_down
    }
    pub(crate) fn finish_organization(
        &mut self,
        intent: &OrganizationIntent,
        outcome: CatalogOutcome<(ChatRecord, bool)>,
        cx: &mut Context<Self>,
    ) -> Option<String> {
        if !self.current_organization(intent) {
            self.release_organization(intent, cx);
            return None;
        }
        self.observe_catalog_uncertainty(outcome.uncertain, cx);
        let mut fallback = None;
        match outcome.result {
            Ok((saved, changed))
                if saved.id == intent.id
                    && saved.snapshot == intent.snapshot
                    && self.records.iter().any(|record| {
                        record.id == saved.id && record.snapshot == saved.snapshot
                    }) =>
            {
                self.clear_organization_errors(&intent.id, intent.action);
                if let Some(record) = self.records.iter_mut().find(|record| record.id == saved.id) {
                    record.pinned_at = saved.pinned_at;
                    record.archived_at = saved.archived_at;
                    record.sidebar_order = saved.sidebar_order;
                }
                let mut materialized = false;
                if let Some(chat) = self.chat_mut(&saved.id) {
                    chat.record.pinned_at = saved.pinned_at;
                    chat.record.archived_at = saved.archived_at;
                    chat.record.sidebar_order = saved.sidebar_order;
                    materialized = chat.pending;
                    chat.pending = false;
                    // Setting the editor guard never consumes marked text.
                    if matches!(intent.action, OrganizationAction::SetArchived(_)) {
                        chat.composer.update(cx, |editor, cx| {
                            editor.set_read_only(saved.archived_at.is_some() || chat.busy, cx)
                        });
                    }
                }
                if materialized {
                    self.draft_changed(&saved.id, cx);
                    if self.record.id == saved.id {
                        self.remember_selection(cx);
                    }
                }
                if changed
                    && intent.action == OrganizationAction::SetArchived(true)
                    && self.organization_owns_navigation(intent)
                {
                    fallback = self
                        .records
                        .iter()
                        .filter(|record| record.id != saved.id && record.archived_at.is_none())
                        .min_by(|a, b| a.sidebar_cmp(b))
                        .map(|record| record.id.clone());
                }
            }
            Ok(_) => {}
            Err(error) => {
                let label = match intent.action {
                    OrganizationAction::SetPinned(_) => "pin",
                    OrganizationAction::SetArchived(true) => "archive",
                    OrganizationAction::SetArchived(false) => "restore",
                };
                let stop = if intent.action == OrganizationAction::SetArchived(true) {
                    " A Stop request may already have taken effect."
                } else {
                    ""
                };
                let message = catalog_error(&error, outcome.uncertain);
                self.organization_failure(
                    &intent.id,
                    Some(intent.action),
                    format!("Chat {label} could not be saved: {message}{stop}"),
                );
            }
        }
        #[cfg(not(target_os = "macos"))]
        if self.record.id == intent.id && self.chat_is_archived(&intent.id) {
            let binding = intent.binding;
            let id = intent.id.clone();
            if let Some(window) = intent.window {
                let owner = cx.weak_entity();
                cx.defer(move |cx| {
                    let _ = window.update(cx, |_, window, cx| {
                        let _ = owner.update(cx, |view, cx| {
                            if view.window_binding == binding
                                && view.record.id == id
                                && view.chat_is_archived(&id)
                                && !view.close_dialog
                                && !view.quick_open.read(cx).is_open()
                                && view.composer.read(cx).focus_handle(cx).is_focused(window)
                            {
                                view.root_focus.focus(window);
                            }
                        });
                    });
                });
            }
        }
        if fallback.is_none() {
            self.release_organization(intent, cx);
        }
        cx.notify();
        fallback
    }
    fn release_organization(&mut self, intent: &OrganizationIntent, cx: &mut Context<Self>) {
        if !self
            .organization_operations
            .get(&intent.id)
            .and_then(|queue| queue.intents.front())
            .is_some_and(|head| {
                head.token == intent.token
                    && head.project == intent.project
                    && head.snapshot == intent.snapshot
            })
        {
            return;
        }
        let queue = self.organization_operations.get_mut(&intent.id).unwrap();
        queue.intents.pop_front();
        if queue.intents.is_empty() {
            self.organization_operations.remove(&intent.id);
        }
        self.request_organization_drain(cx);
        cx.notify();
    }
    pub(crate) fn observe_catalog_uncertainty(&mut self, uncertain: bool, cx: &mut Context<Self>) {
        if uncertain {
            let changed = !self.known_catalog_uncertainty;
            let blocked_before = self.blocked_organization_count;
            self.known_catalog_uncertainty = true;
            self.block_queued_organization(cx);
            if changed || self.blocked_organization_count != blocked_before {
                cx.notify();
            }
        }
    }
    fn block_queued_organization(&mut self, cx: &mut Context<Self>) {
        let ids: Vec<_> = self
            .organization_operations
            .iter_mut()
            .filter_map(|(id, queue)| {
                let blocked = queue
                    .intents
                    .iter()
                    .filter(|intent| !intent.running)
                    .count();
                queue.intents.retain(|intent| intent.running);
                (blocked > 0).then_some((id.clone(), blocked))
            })
            .collect();
        self.organization_operations
            .retain(|_, queue| !queue.intents.is_empty());
        for (id, count) in ids {
            self.blocked_organization_count += count;
            self.organization_failure(&id, None, format!("{count} queued chat change(s) were not confirmed because the workspace has an unconfirmed save. Live drafts are preserved."));
        }
        // Never notify from an unchanged waiting drain.
        let _ = cx;
    }
    fn organization_failure(
        &mut self,
        id: &str,
        action: Option<OrganizationAction>,
        message: String,
    ) {
        let display = self.record.id.clone();
        self.organization_errors.insert(
            display,
            OrganizationError {
                target_id: id.into(),
                action,
                message: message.clone(),
            },
        );
        self.error = Some(message);
    }
    fn clear_organization_errors(&mut self, target: &str, action: OrganizationAction) {
        let errors: Vec<_> = self
            .organization_errors
            .iter()
            .filter(|(_, error)| error.target_id == target && error.action == Some(action))
            .map(|(id, error)| (id.clone(), error.message.clone()))
            .collect();
        for (id, message) in errors {
            self.organization_errors.remove(&id);
            if let Some(chat) = self.chat_mut(&id)
                && chat.error.as_ref() == Some(&message)
            {
                chat.error = None;
            }
        }
    }
    pub(crate) fn effective_archive_visibility(&self) -> bool {
        self.show_archived || self.launch_archive_reveal
    }
    pub(crate) fn set_archive_visibility(&mut self, shown: bool, cx: &mut Context<Self>) {
        if self.shutting_down || self.project_actions_blocked() {
            return;
        }
        let Some(revision) = self.archive_visibility_revision.checked_add(1) else {
            self.error = Some("Archive visibility revision limit reached.".into());
            cx.notify();
            return;
        };
        self.archive_visibility_revision = revision;
        self.show_archived = shown;
        self.launch_archive_reveal = false;
        self.archive_visibility_writes += 1;
        let project = self.project.clone();
        let workspace = self.workspace.clone();
        let task = cx.background_executor().spawn(async move {
            catalog_operation(&workspace, |store| {
                store.set_archive_visibility(shown, revision)
            })
        });
        cx.spawn(async move |owner,cx| {
            let outcome = task.await;
            let _ = owner.update(cx, |view,cx| {
                if view.project != project { return; }
                view.archive_visibility_writes -= 1;
                view.observe_catalog_uncertainty(outcome.uncertain, cx);
                if view.archive_visibility_revision == revision {
                    match outcome.display_result() {
                        Ok(true) => {
                            let warnings = std::mem::take(&mut view.archive_visibility_errors);
                            for (id, message) in warnings {
                                if let Some(chat) = view.chat_mut(&id) && chat.error.as_ref() == Some(&message) {
                                    chat.error = None;
                                }
                            }
                        }
                        Ok(false) => {},
                        Err(error) => {
                            let message = format!("Archive visibility could not be saved: {error}. This choice is only visible in this window.");
                            let display = view.record.id.clone();
                            view.archive_visibility_errors.insert(display, message.clone());
                            view.error = Some(message);
                        }
                    }
                }
                cx.notify();
            });
        }).detach();
        cx.notify();
    }
}

#[cfg(test)]
impl AgentView {
    pub(crate) fn test_seed_pin(&mut self, id: &str, token: uuid::Uuid, cx: &mut Context<Self>) {
        let record = self
            .records
            .iter()
            .find(|record| record.id == id)
            .unwrap_or(&self.record)
            .clone();
        let intent = OrganizationIntent {
            token,
            action: OrganizationAction::SetPinned(true),
            project: self.project.clone(),
            id: id.into(),
            snapshot: record.snapshot,
            navigation: self.navigation_generation,
            selected: self.record.id.clone(),
            binding: self.window_binding,
            window: self.organization_window,
            running: true,
        };
        self.organization_operations
            .entry(id.into())
            .or_default()
            .intents
            .push_back(intent);
        cx.notify();
    }
    pub(crate) fn test_finish_pin(
        &mut self,
        id: &str,
        project: &std::path::Path,
        token: uuid::Uuid,
        result: Result<ChatRecord, String>,
        cx: &mut Context<Self>,
    ) {
        let Some(mut intent) = self
            .organization_operations
            .get(id)
            .and_then(|queue| queue.intents.front())
            .cloned()
        else {
            return;
        };
        intent.token = token;
        intent.project = project.into();
        self.finish_organization(
            &intent,
            CatalogOutcome {
                result: result
                    .map(|record| (record, false))
                    .map_err(bello_agent_core::Error::Invalid),
                uncertain: false,
            },
            cx,
        );
    }
}

#[cfg(test)]
#[path = "chat_organization_tests.rs"]
mod tests;
