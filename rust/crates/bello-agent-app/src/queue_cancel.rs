//! Durable Cancel boundary. Begin's nonfreezing adoption is a later slice.
use crate::{AgentView, queue_edit::EditRecovery};
use bello_agent_core::{
    Controller, QueueEditState, QueueEditStatus,
    workspace::{DraftRecord, QueuedCancelReceipt, QueuedCancelState},
};
use gpui::Context;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Arc,
};
use uuid::Uuid;

#[derive(Clone)]
struct Key {
    token: Uuid,
    chat: String,
    project: PathBuf,
    controller: Arc<Controller>,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Running,
    Deferred,
    Settling,
    Retry,
}
struct Settlement {
    source: DraftRecord,
    reconciled: DraftRecord,
    owned: bool,
    changed: bool,
}
pub(crate) struct CancelOperation {
    key: Key,
    receipt: QueuedCancelReceipt,
    owned: bool,
    phase: Phase,
    deferred: Option<QueueEditStatus>,
    recheck: bool,
}
impl CancelOperation {
    pub(crate) fn is_live(&self) -> bool {
        matches!(self.phase, Phase::Running | Phase::Settling)
    }
    pub(crate) fn is_deferred(&self) -> bool {
        self.phase == Phase::Deferred
    }
    pub(crate) fn owns_queue_token(&self, token: Uuid) -> bool {
        self.key.token == token
    }
}

/// Admission cause outlives transient operation objects and placeholder
/// controllers. A Restore/composer/load notification cannot authorize a new
/// actor cancellation for the exact receipt parked by Archive.
#[derive(Default)]
pub(crate) struct ArchiveCancelDeferrals {
    receipts: HashMap<(PathBuf, String), QueuedCancelReceipt>,
}
impl ArchiveCancelDeferrals {
    fn remember(&mut self, project: &Path, id: &str, receipt: &QueuedCancelReceipt) {
        if matches!(receipt.state, QueuedCancelState::Pending { .. }) {
            self.receipts
                .insert((project.to_owned(), id.to_owned()), receipt.clone());
        }
    }
    fn blocks(&self, project: &Path, id: &str, receipt: &QueuedCancelReceipt) -> bool {
        self.receipts.get(&(project.to_owned(), id.to_owned())) == Some(receipt)
    }
    fn allow_explicit(&mut self, project: &Path, id: &str, receipt: &QueuedCancelReceipt) {
        if self.blocks(project, id, receipt) {
            self.receipts.remove(&(project.to_owned(), id.to_owned()));
        }
    }
    fn observe(&mut self, project: &Path, id: &str, receipt: &QueuedCancelReceipt) {
        let key = (project.to_owned(), id.to_owned());
        if matches!(receipt.state, QueuedCancelState::Settled)
            && self
                .receipts
                .get(&key)
                .is_some_and(|pending| pending.revision < receipt.revision)
        {
            self.receipts.remove(&key);
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum RetryCause {
    Automatic,
    Explicit,
}

impl AgentView {
    fn pending_cancel_receipt(&self, id: &str) -> Option<QueuedCancelReceipt> {
        self.queued_cancellations
            .get(id)
            .filter(|receipt| matches!(receipt.state, QueuedCancelState::Pending { .. }))
            .cloned()
            .or_else(|| {
                self.chat_ref(id).and_then(|chat| {
                    chat.cancel_operation
                        .as_ref()
                        .map(|operation| operation.receipt.clone())
                })
            })
    }
    /// Called synchronously when Archive is accepted, including when a Cancel
    /// is still Deferred and its first recheck will only arrive after Restore.
    pub(crate) fn defer_cancel_for_archive(&mut self, id: &str) {
        if let Some(receipt) = self.pending_cancel_receipt(id) {
            self.archive_cancel_deferrals
                .remember(&self.project, id, &receipt);
        }
    }
    pub(crate) fn has_pending_cancel(&self, id: &str) -> bool {
        self.queued_cancellations
            .get(id)
            .is_some_and(|receipt| matches!(receipt.state, QueuedCancelState::Pending { .. }))
            || self
                .chat_ref(id)
                .is_some_and(|chat| chat.cancel_operation.is_some())
    }
    /// A later known actor failure invalidates a previously read answer, even
    /// when no published revision changed. Durable identity remains retained.
    pub(crate) fn invalidate_cancel_check(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(chat) = self.chat_mut(id) else {
            return;
        };
        let Some(operation) = chat.cancel_operation.as_mut() else {
            return;
        };
        operation.recheck = true;
        operation.deferred = None;
        if operation.phase == Phase::Deferred {
            operation.phase = Phase::Retry;
            chat.queue_operation = None;
            self.resume_durable_cancel(id, cx);
        }
        cx.notify();
    }
    fn restart_cancel_check(&mut self, key: &Key, cx: &mut Context<Self>) {
        let read_only = self.chat_is_archived(&key.chat);
        let chat = self.chat_mut(&key.chat).unwrap();
        chat.queue_operation = None;
        chat.busy = false;
        chat.composer
            .update(cx, |editor, cx| editor.set_read_only(read_only, cx));
        chat.cancel_operation.as_mut().unwrap().phase = Phase::Retry;
        self.resume_durable_cancel(&key.chat, cx);
        cx.notify();
    }
    pub(crate) fn can_cancel_owned_edit(&self) -> bool {
        self.editing.is_some()
            && !self.actor_mutation_blocked(&self.record.id)
            && !self.busy
            && !self.loading
            && !self.load_failed
            && !self.shutting_down
            && self.queue_operation.is_none()
            && (!self.edit_recovery.blocked
                || self.has_pending_cancel(&self.record.id)
                || self
                    .cancel_operation
                    .as_ref()
                    .is_some_and(|operation| operation.phase == Phase::Retry))
    }
    pub(crate) fn cancel_owned_edit(&mut self, chat_id: &str, cx: &mut Context<Self>) {
        if self.record.id != chat_id || !self.can_cancel_owned_edit() {
            return;
        }
        let Some(edit_id) = self.editing.clone() else {
            return;
        };
        let Some(turn_id) = self.queued_turn_id.clone() else {
            return;
        };
        let receipt = if let Some(operation) = &self.cancel_operation {
            operation.receipt.clone()
        } else if let Some(receipt) = self
            .queued_cancellations
            .get(chat_id)
            .filter(|r| matches!(r.state, QueuedCancelState::Pending { .. }))
        {
            receipt.clone()
        } else {
            let previous = self
                .queued_cancellations
                .get(chat_id)
                .map_or(0, |r| r.revision);
            match QueuedCancelReceipt::pending(previous, edit_id.clone(), turn_id.clone()) {
                Ok(receipt) => receipt,
                Err(error) => {
                    self.error = Some(error.to_string());
                    cx.notify();
                    return;
                }
            }
        };
        if !matches!(&receipt.state, QueuedCancelState::Pending { edit_id: edit, turn_id: turn } if edit == &edit_id && turn == &turn_id)
        {
            self.error = Some("An earlier queued cancellation must finish first.".into());
            cx.notify();
            return;
        }
        self.start_cancel(chat_id, receipt, true, RetryCause::Explicit, cx);
    }
    /// Only explicit current-chat reselection uses this route. In particular,
    /// archive fallback and load/composer callbacks keep their automatic cause.
    pub(crate) fn resume_durable_cancel_explicit(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.record.id != id || self.actor_mutation_blocked(id) || self.shutting_down {
            return;
        }
        let Some(receipt) = self.pending_cancel_receipt(id) else {
            return;
        };
        self.archive_cancel_deferrals
            .allow_explicit(&self.project, id, &receipt);
        self.resume_durable_cancel(id, cx);
    }
    pub(crate) fn resume_durable_cancel(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(receipt) = self.pending_cancel_receipt(id) else {
            return;
        };
        let QueuedCancelState::Pending { ref edit_id, .. } = receipt.state else {
            return;
        };
        let owned = self
            .chat_ref(id)
            .is_some_and(|chat| chat.editing.as_ref() == Some(edit_id));
        self.start_cancel(id, receipt, owned, RetryCause::Automatic, cx);
    }
    fn start_cancel(
        &mut self,
        id: &str,
        receipt: QueuedCancelReceipt,
        owned: bool,
        cause: RetryCause,
        cx: &mut Context<Self>,
    ) {
        if self.shutting_down {
            return;
        }
        if self.actor_mutation_blocked(id) {
            self.archive_cancel_deferrals
                .remember(&self.project, id, &receipt);
            return;
        }
        if cause == RetryCause::Automatic
            && self
                .archive_cancel_deferrals
                .blocks(&self.project, id, &receipt)
        {
            return;
        }
        let project = self.project.clone();
        let workspace = self.workspace.clone();
        let Some(chat) = self.chat_mut(id) else {
            return;
        };
        if chat.busy || chat.loading || chat.load_failed || chat.queue_operation.is_some() {
            return;
        }
        if owned && chat.composer.read(cx).has_marked_text() {
            chat.error = Some("Finish composing text before cancelling the queued edit.".into());
            cx.notify();
            return;
        }
        // One capture and one settlement revision must both be representable.
        let Some(next) = chat
            .draft_revision
            .checked_add(2)
            .map(|_| chat.draft_revision + 1)
        else {
            chat.error = Some("Draft revision limit reached; the rewrite is preserved.".into());
            cx.notify();
            return;
        };
        chat.draft_revision = next;
        let draft = chat.saved_draft(cx);
        let captured_revision = draft.revision;
        let key = Key {
            token: Uuid::new_v4(),
            chat: id.into(),
            project,
            controller: chat.controller.clone(),
        };
        chat.queue_operation = Some(key.token);
        chat.edit_recovery = EditRecovery::new(true);
        chat.busy = owned;
        if owned {
            chat.composer
                .update(cx, |editor, cx| editor.set_read_only(true, cx));
        }
        chat.cancel_operation = Some(CancelOperation {
            key: key.clone(),
            receipt: receipt.clone(),
            owned,
            phase: Phase::Running,
            deferred: None,
            recheck: false,
        });
        if cause == RetryCause::Explicit {
            self.archive_cancel_deferrals
                .allow_explicit(&self.project, id, &receipt);
        }
        let worker = key.controller.clone();
        let worker_id = id.to_owned();
        let pending = receipt.clone();
        let task = cx.background_executor().spawn(async move {
            let mut observed = None;
            let prepared = crate::chat_organization::catalog_operation(&workspace, |store| {
                let result = store.prepare_queued_cancel(&worker_id, pending.clone(), draft);
                observed = store
                    .snapshot()
                    .queued_cancellations
                    .get(&worker_id)
                    .cloned();
                result
            });
            let confirmed_revision = prepared.result.as_ref().ok().map(|()| captured_revision);
            let result = prepared.result.and_then(|()| {
                let QueuedCancelState::Pending { edit_id, turn_id } = &pending.state else {
                    unreachable!()
                };
                worker.cancel_edit_certain(edit_id, turn_id)
            });
            (observed, confirmed_revision, result, prepared.uncertain)
        });
        cx.spawn(async move |view, cx| {
            let (observed, confirmed_revision, result, uncertain) = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.project == key.project {
                    view.observe_catalog_uncertainty(uncertain, cx);
                }
                if let Some(revision) = confirmed_revision
                    && view.accept_cancel_key(&key)
                {
                    let chat = view.chat_mut(&key.chat).unwrap();
                    chat.draft_save_status.confirm(revision, &mut chat.error);
                }
                view.finish_cancel_read(
                    key,
                    observed,
                    result.map_err(|error| {
                        crate::chat_organization::catalog_error(&error, uncertain)
                    }),
                    cx,
                )
            });
        })
        .detach();
        cx.notify();
    }
    fn accept_cancel_key(&self, key: &Key) -> bool {
        self.project == key.project
            && self.chat_ref(&key.chat).is_some_and(|chat| {
                chat.queue_operation == Some(key.token)
                    && Arc::ptr_eq(&chat.controller, &key.controller)
                    && chat
                        .cancel_operation
                        .as_ref()
                        .is_some_and(|operation| operation.key.token == key.token)
            })
    }
    fn observe_cancel_receipt(&mut self, key: &Key, receipt: Option<QueuedCancelReceipt>) {
        if self.project != key.project {
            return;
        }
        if let Some(receipt) = receipt {
            let replace = self
                .queued_cancellations
                .get(&key.chat)
                .is_none_or(|old| old.revision < receipt.revision || old == &receipt);
            if replace {
                self.archive_cancel_deferrals
                    .observe(&self.project, &key.chat, &receipt);
                self.queued_cancellations.insert(key.chat.clone(), receipt);
            }
        }
    }
    fn fail_cancel(&mut self, key: &Key, error: String, cx: &mut Context<Self>) {
        if !self.accept_cancel_key(key) {
            return;
        }
        let read_only = self.chat_is_archived(&key.chat);
        let chat = self.chat_mut(&key.chat).unwrap();
        chat.queue_operation = None;
        chat.busy = false;
        chat.edit_recovery.blocked = true;
        chat.composer
            .update(cx, |editor, cx| editor.set_read_only(read_only, cx));
        if let Some(operation) = &mut chat.cancel_operation {
            operation.phase = Phase::Retry;
            operation.deferred = None;
        }
        let message =
            format!("Queued cancellation is still pending: {error}. Your text is preserved.");
        if chat.error.is_none()
            || chat
                .queue_operation_error
                .as_ref()
                .is_some_and(|owned| chat.error.as_ref() == Some(owned))
        {
            chat.error = Some(message.clone());
        }
        chat.queue_operation_error = Some(message);
        chat.dismissed_error = None;
        cx.notify();
    }
    fn finish_cancel_read(
        &mut self,
        key: Key,
        observed: Option<QueuedCancelReceipt>,
        result: Result<QueueEditStatus, String>,
        cx: &mut Context<Self>,
    ) {
        self.observe_cancel_receipt(&key, observed);
        if !self.accept_cancel_key(&key) {
            return;
        }
        if self
            .chat_ref(&key.chat)
            .unwrap()
            .cancel_operation
            .as_ref()
            .unwrap()
            .recheck
        {
            self.restart_cancel_check(&key, cx);
            return;
        }
        let status = match result {
            Ok(status) => status,
            Err(error) => {
                self.fail_cancel(&key, error, cx);
                return;
            }
        };
        let chat = self.chat_mut(&key.chat).unwrap();
        let operation = chat.cancel_operation.as_ref().unwrap();
        let QueuedCancelState::Pending { edit_id, turn_id } = &operation.receipt.state else {
            unreachable!()
        };
        if status.edit_id != *edit_id {
            self.fail_cancel(&key, "Edit identity changed".into(), cx);
            return;
        }
        let receipt = operation.receipt.clone();
        let owned = operation.owned;
        let source = chat.saved_draft(cx);
        let matches_edit = source
            .queued_edit
            .as_ref()
            .is_some_and(|edit| edit.edit_id == *edit_id && edit.turn_id == *turn_id);
        let mut reconciled = source.clone();
        let changed = if owned && matches_edit && matches!(status.state, QueueEditState::Cancelled)
        {
            let Some(revision) = source.revision.checked_add(1) else {
                self.fail_cancel(&key, "Draft revision overflow".into(), cx);
                return;
            };
            reconciled.queued_edit = None;
            reconciled.revision = revision;
            true
        } else if matches_edit {
            match reconciled.reconcile_queued_status(&status) {
                Ok(changed) => changed,
                Err(error) => {
                    self.fail_cancel(&key, error.to_string(), cx);
                    return;
                }
            }
        } else {
            false
        };
        if !owned && changed && chat.composer.read(cx).has_marked_text() {
            let operation = chat.cancel_operation.as_mut().unwrap();
            operation.phase = Phase::Deferred;
            operation.deferred = Some(status);
            cx.notify();
            return;
        }
        chat.cancel_operation.as_mut().unwrap().phase = Phase::Settling;
        // Recovered text is merged into live state before persistence, so every
        // later autosave already contains it. Owned Cancel stays read-only until
        // its ordinary-draft settlement is durable, retaining a retryable editor.
        if !owned && changed {
            chat.retained_edit = None;
            chat.editing = None;
            chat.queued_turn_id = None;
            chat.queued_original = None;
            chat.draft_before_edit.clear();
            chat.composer.update(cx, |editor, cx| {
                editor.set_text(reconciled.text.clone(), cx)
            });
        }
        let workspace = self.workspace.clone();
        let id = key.chat.clone();
        let expected = receipt.clone();
        let saved_source = source.clone();
        let saved = reconciled.clone();
        let task = cx.background_executor().spawn(async move {
            let mut observed = None;
            let outcome = crate::chat_organization::catalog_operation(&workspace, |store| {
                let result = store.settle_queued_cancel(&id, &expected, &saved_source, saved);
                observed = store.snapshot().queued_cancellations.get(&id).cloned();
                result
            });
            (observed, outcome)
        });
        cx.spawn(async move |view, cx| {
            let (observed, outcome) = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.project == key.project {
                    view.observe_catalog_uncertainty(outcome.uncertain, cx);
                }
                view.finish_cancel_settlement(
                    key,
                    observed,
                    outcome.display_result(),
                    Settlement {
                        source,
                        reconciled,
                        owned,
                        changed,
                    },
                    cx,
                )
            });
        })
        .detach();
        cx.notify();
    }
    fn finish_cancel_settlement(
        &mut self,
        key: Key,
        observed: Option<QueuedCancelReceipt>,
        result: Result<bool, String>,
        settlement: Settlement,
        cx: &mut Context<Self>,
    ) {
        let Settlement {
            source,
            reconciled,
            owned,
            changed,
        } = settlement;
        self.observe_cancel_receipt(&key, observed);
        if !self.accept_cancel_key(&key) {
            return;
        }
        let applied = match result {
            Ok(applied) => applied,
            Err(error) => {
                self.fail_cancel(&key, error, cx);
                return;
            }
        };
        let read_only = self.chat_is_archived(&key.chat);
        let chat = self.chat_mut(&key.chat).unwrap();
        if applied {
            chat.draft_save_status
                .confirm(reconciled.revision, &mut chat.error);
        }
        let recheck = chat.cancel_operation.as_ref().unwrap().recheck;
        let receipt = chat.cancel_operation.as_ref().unwrap().receipt.clone();
        let unchanged = chat.saved_draft(cx) == source;
        chat.queue_operation = None;
        chat.cancel_operation = None;
        chat.busy = false;
        chat.edit_recovery = EditRecovery::new(false);
        chat.composer
            .update(cx, |editor, cx| editor.set_read_only(read_only, cx));
        chat.session = chat.controller.snapshot_shared();
        if applied && owned && changed && unchanged {
            chat.editing = None;
            chat.retained_edit = None;
            chat.queued_turn_id = None;
            chat.queued_original = None;
            chat.draft_before_edit.clear();
            chat.composer
                .update(cx, |editor, cx| editor.set_text(reconciled.text, cx));
        }
        if chat
            .queue_operation_error
            .as_ref()
            .is_some_and(|error| chat.error.as_ref() == Some(error))
        {
            chat.error = None;
        }
        chat.queue_operation_error = None;
        if recheck {
            let QueuedCancelState::Pending { edit_id, .. } = receipt.state else {
                unreachable!()
            };
            self.recheck_edit_after_failure(&key.chat, Some(edit_id), cx);
        } else if !applied || (owned && changed && !unchanged) {
            self.reconcile_edit(&key.chat, cx);
        }
        cx.notify();
    }
    pub(crate) fn resume_deferred_cancel(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(chat) = self.chat_mut(id) else {
            return;
        };
        if chat.composer.read(cx).has_marked_text() {
            return;
        }
        let Some(operation) = chat
            .cancel_operation
            .as_mut()
            .filter(|op| op.phase == Phase::Deferred)
        else {
            return;
        };
        let Some(status) = operation.deferred.take() else {
            return;
        };
        let key = operation.key.clone();
        operation.phase = Phase::Running;
        self.finish_cancel_read(key, None, Ok(status), cx);
    }
}

#[cfg(test)]
#[path = "queue_cancel_tests.rs"]
mod tests;

impl AgentView {
    pub(crate) fn cancel_held_edit(
        &mut self,
        chat_id: &str,
        turn_id: &str,
        edit_id: &str,
        cx: &mut Context<Self>,
    ) {
        if self.record.id != chat_id
            || self.actor_mutation_blocked(chat_id)
            || self.shutting_down
            || self.busy
            || self.loading
            || self.load_failed
            || self.editing.is_some()
        {
            return;
        }
        let beginning = self
            .begin_operation
            .as_ref()
            .is_some_and(|operation| operation.matches(edit_id, turn_id));
        let held = self
            .session
            .edit
            .as_ref()
            .is_some_and(|hold| hold.edit_id == edit_id && hold.turn_id == turn_id);
        if !beginning && !held {
            return;
        }
        if self.queue_operation.is_some() && !beginning {
            return;
        }
        let receipt = self
            .cancel_operation
            .as_ref()
            .map(|operation| operation.receipt.clone())
            .or_else(|| {
                self.queued_cancellations
                    .get(chat_id)
                    .filter(|receipt| matches!(receipt.state, QueuedCancelState::Pending { .. }))
                    .cloned()
            });
        let receipt = match receipt {
            Some(receipt) => receipt,
            None => match QueuedCancelReceipt::pending(
                self.queued_cancellations
                    .get(chat_id)
                    .map_or(0, |receipt| receipt.revision),
                edit_id.into(),
                turn_id.into(),
            ) {
                Ok(receipt) => receipt,
                Err(error) => {
                    self.error = Some(error.to_string());
                    cx.notify();
                    return;
                }
            },
        };
        if !matches!(&receipt.state, QueuedCancelState::Pending { edit_id: edit, turn_id: turn } if edit == edit_id && turn == turn_id)
        {
            self.error = Some("An earlier queued cancellation must finish first.".into());
            cx.notify();
            return;
        }
        // Abandon adoption immediately, before catalog preparation or an actor
        // reply can run. The receipt then fences a Begin not yet executed.
        self.abandon_begin_for_cancel(chat_id, edit_id, turn_id);
        self.start_cancel(chat_id, receipt, false, RetryCause::Explicit, cx);
    }
}
