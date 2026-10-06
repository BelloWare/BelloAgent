//! Authoritative queued-edit recovery. Cached snapshots are presentation only.
use crate::AgentView;
use bello_agent_core::{Controller, QueueEditStatus};
use gpui::Context;
use std::{path::PathBuf, sync::Arc};
use uuid::Uuid;

#[derive(Clone)]
struct Check {
    operation: Uuid,
    chat_id: String,
    edit_id: String,
    project: PathBuf,
    controller: Arc<Controller>,
    binding: Option<crate::workspace_lifetime::WindowBinding>,
    owned_edit: Option<String>,
}

#[derive(Default)]
pub(crate) struct EditRecovery {
    pub(crate) blocked: bool,
    pending: Option<Check>,
    deferred: Option<QueueEditStatus>,
    error: Option<String>,
    requested: Option<String>,
}
impl EditRecovery {
    pub(crate) fn is_deferred(&self) -> bool {
        self.pending.is_some() && self.deferred.is_some()
    }
    pub(crate) fn has_live_check(&self) -> bool {
        self.pending.is_some() && self.deferred.is_none()
    }
    pub(crate) fn owns_queue_token(&self, token: Uuid) -> bool {
        self.pending
            .as_ref()
            .is_some_and(|check| check.operation == token)
    }
    pub(crate) fn new(blocked: bool) -> Self {
        Self {
            blocked,
            ..Self::default()
        }
    }
}

impl AgentView {
    /// A known later command failure invalidates even a previously successful
    /// read: uncertain writes need not advance the published snapshot revision.
    pub(crate) fn recheck_edit_after_failure(
        &mut self,
        id: &str,
        edit_id: Option<String>,
        cx: &mut Context<Self>,
    ) {
        if self
            .chat_ref(id)
            .is_some_and(|chat| chat.begin_operation.is_some())
        {
            self.invalidate_begin_check(id, cx);
            return;
        }
        if self.has_pending_cancel(id) {
            self.invalidate_cancel_check(id, cx);
            self.resume_durable_cancel(id, cx);
            return;
        }
        let Some(chat) = self.chat_mut(id) else {
            return;
        };
        let identity = edit_id
            .or_else(|| chat.editing.clone())
            .or_else(|| chat.session.edit.as_ref().map(|hold| hold.edit_id.clone()))
            .or_else(|| chat.edit_recovery.requested.clone());
        let Some(identity) = identity else { return };
        if let Some(pending) = chat.edit_recovery.pending.take()
            && chat.queue_operation == Some(pending.operation)
        {
            chat.queue_operation = None;
        }
        chat.edit_recovery.deferred = None;
        chat.edit_recovery.blocked = true;
        chat.edit_recovery.requested = Some(identity.clone());
        self.reconcile_edit_identity(id, identity, cx);
    }

    pub(crate) fn drain_edit_recheck(&mut self, id: &str, cx: &mut Context<Self>) {
        let ready = self.chat_ref(id).is_some_and(|chat| {
            chat.edit_recovery.blocked
                && chat.edit_recovery.requested.is_some()
                && chat.edit_recovery.pending.is_none()
                && !chat.busy
                && !chat.loading
                && chat.queue_operation.is_none()
        });
        if ready {
            self.reconcile_edit(id, cx);
        }
    }

    pub(crate) fn reconcile_edit(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.has_pending_cancel(id) {
            self.resume_durable_cancel(id, cx);
            return;
        }
        let edit_id = self.chat_ref(id).and_then(|chat| {
            chat.editing
                .clone()
                .or_else(|| chat.retained_edit.as_ref().map(|edit| edit.edit_id.clone()))
                .or_else(|| chat.session.edit.as_ref().map(|hold| hold.edit_id.clone()))
                .or_else(|| chat.edit_recovery.requested.clone())
        });
        if let Some(edit_id) = edit_id {
            self.reconcile_edit_identity(id, edit_id, cx);
        }
    }

    pub(crate) fn reconcile_edit_identity(
        &mut self,
        id: &str,
        edit_id: String,
        cx: &mut Context<Self>,
    ) {
        if self.has_pending_cancel(id) {
            self.resume_durable_cancel(id, cx);
            return;
        }
        let project = self.project.clone();
        let binding = self.window_binding;
        let Some(chat) = self.chat_mut(id) else {
            return;
        };
        chat.edit_recovery.requested = Some(edit_id.clone());
        chat.edit_recovery.blocked = true;
        if chat.loading || chat.load_failed || chat.busy || chat.queue_operation.is_some() {
            return;
        }
        let check = Check {
            operation: Uuid::new_v4(),
            chat_id: id.to_owned(),
            edit_id,
            project,
            controller: chat.controller.clone(),
            binding,
            owned_edit: chat.editing.clone(),
        };
        chat.queue_operation = Some(check.operation);
        chat.edit_recovery.pending = Some(check.clone());
        chat.edit_recovery.deferred = None;
        let worker = check.controller.clone();
        let edit = check.edit_id.clone();
        let task = cx
            .background_executor()
            .spawn(async move { worker.edit_status(&edit).map_err(|error| error.to_string()) });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                view.finish_edit_reconciliation(check, result, cx)
            });
        })
        .detach();
        cx.notify();
    }

    fn finish_edit_reconciliation(
        &mut self,
        check: Check,
        result: Result<QueueEditStatus, String>,
        cx: &mut Context<Self>,
    ) {
        if self.project != check.project {
            return;
        }
        let binding = self.window_binding;
        let Some(chat) = self.chat_mut(&check.chat_id) else {
            return;
        };
        if chat.queue_operation != Some(check.operation)
            || !Arc::ptr_eq(&chat.controller, &check.controller)
            || chat
                .edit_recovery
                .pending
                .as_ref()
                .is_none_or(|pending| pending.operation != check.operation)
        {
            return;
        }
        if binding != check.binding {
            chat.queue_operation = None;
            chat.edit_recovery.pending = None;
            chat.edit_recovery.deferred = None;
            self.reconcile_edit_identity(&check.chat_id, check.edit_id, cx);
            cx.notify();
            return;
        }
        if chat.editing != check.owned_edit {
            chat.queue_operation = None;
            chat.edit_recovery = EditRecovery::new(chat.editing.is_some());
            cx.notify();
            return;
        }
        let result = result.and_then(|status| {
            if status.edit_id != check.edit_id {
                return Err("Queued edit status identity changed".into());
            }
            Ok(status)
        });
        let status = match result {
            Ok(status) => status,
            Err(error) => {
                chat.queue_operation = None;
                chat.edit_recovery.pending = None;
                chat.edit_recovery.deferred = None;
                chat.edit_recovery.blocked = true;
                let notice = format!(
                    "Queued edit recovery is not confirmed: {error}. The rewrite is preserved and edit actions remain blocked."
                );
                chat.edit_recovery.error = Some(notice.clone());
                chat.error = Some(notice);
                chat.dismissed_error = None;
                cx.notify();
                return;
            }
        };
        if chat.controller.snapshot_shared().revision > status.session_revision {
            chat.queue_operation = None;
            chat.edit_recovery.pending = None;
            self.reconcile_edit_identity(&check.chat_id, check.edit_id, cx);
            cx.notify();
            return;
        }
        let mut draft = chat.saved_draft(cx);
        let reconciliation = draft.reconcile_queued_status(&status);
        // Only an actual model replacement must wait for platform composition;
        // confirming an unchanged active hold does not change Close/IME policy.
        // unmark_text notifies without emitting Changed, hence the observer.
        if matches!(reconciliation, Ok(true)) && chat.composer.read(cx).has_marked_text() {
            chat.edit_recovery.deferred = Some(status);
            cx.notify();
            return;
        }
        match reconciliation {
            Ok(changed) => {
                chat.queue_operation = None;
                chat.edit_recovery.pending = None;
                chat.edit_recovery.deferred = None;
                chat.edit_recovery.blocked = false;
                if chat
                    .edit_recovery
                    .error
                    .as_ref()
                    .is_some_and(|owned| chat.error.as_ref() == Some(owned))
                {
                    chat.error = None;
                }
                chat.edit_recovery.error = None;
                chat.edit_recovery.requested = None;
                if changed {
                    // The pure helper validated the complete merge and checked
                    // the next revision before any live state changes. set_text
                    // emits Changed exactly once; that normal save allocates the
                    // validated next revision from this unchanged prior value.
                    debug_assert_eq!(chat.draft_revision.checked_add(1), Some(draft.revision));
                    chat.editing = None;
                    chat.retained_edit = None;
                    chat.queued_turn_id = None;
                    chat.queued_original = None;
                    chat.draft_before_edit.clear();
                    chat.composer
                        .update(cx, |editor, cx| editor.set_text(draft.text, cx));
                    if chat.error.is_none() {
                        chat.error = Some("The previous queued edit has ended. Any unsaved rewrite was kept in the composer.".into());
                    }
                }
            }
            Err(error) => {
                chat.queue_operation = None;
                chat.edit_recovery.pending = None;
                chat.edit_recovery.deferred = None;
                chat.edit_recovery.blocked = true;
                let notice = format!("Queued edit recovery could not be applied: {error}");
                chat.edit_recovery.error = Some(notice.clone());
                chat.error = Some(notice);
                chat.dismissed_error = None;
            }
        }
        cx.notify();
    }

    pub(crate) fn resume_edit_reconciliation(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(chat) = self.chat_mut(id) else {
            return;
        };
        if chat.composer.read(cx).has_marked_text() {
            return;
        }
        let Some(check) = chat.edit_recovery.pending.clone() else {
            return;
        };
        let Some(status) = chat.edit_recovery.deferred.take() else {
            return;
        };
        self.finish_edit_reconciliation(check, Ok(status), cx);
    }
}

#[cfg(test)]
#[path = "queue_edit_tests.rs"]
mod tests;
