//! Source-style nonfreezing Begin. The actor owns the hold; this operation owns
//! only the right to adopt it into the retained chat's composer after a reply.
use crate::{AgentView, queue_edit::EditRecovery, workspace_lifetime::WindowBinding};
use bello_agent_core::{Controller, QueueEditState, QueueEditStatus, workspace::QueuedDraft};
use gpui::{Context, FocusHandle, Window, WindowHandle};
use std::{path::PathBuf, sync::Arc};
use uuid::Uuid;

#[derive(Clone)]
struct Key {
    token: Uuid,
    chat: String,
    turn: String,
    edit: String,
    project: PathBuf,
    controller: Arc<Controller>,
    binding: Option<WindowBinding>,
    window: WindowHandle<AgentView>,
    focus: Option<FocusHandle>,
}
pub(crate) struct BeginFailure {
    turn: String,
    controller: Arc<Controller>,
    message: String,
}
impl crate::chat::ChatState {
    fn note_begin_failure(&mut self, turn: &str, message: String) {
        self.error = Some(message.clone());
        self.begin_error = Some(BeginFailure {
            turn: turn.into(),
            controller: self.controller.clone(),
            message,
        });
        self.dismissed_error = None;
    }
    fn clear_confirmed_begin_failure(&mut self, turn: &str) {
        if self.begin_error.as_ref().is_some_and(|failure| {
            failure.turn == turn && Arc::ptr_eq(&failure.controller, &self.controller)
        }) {
            let failure = self.begin_error.take().unwrap();
            if self.error.as_ref() == Some(&failure.message) {
                self.error = None;
            }
        }
    }
}
pub(crate) struct BeginOperation {
    key: Key,
    deferred: Option<QueueEditStatus>,
    recheck: bool,
}
impl BeginOperation {
    pub(crate) fn matches(&self, edit: &str, turn: &str) -> bool {
        self.key.edit == edit && self.key.turn == turn
    }
    pub(crate) fn turn(&self) -> &str {
        &self.key.turn
    }
}

impl AgentView {
    pub(crate) fn begin_queued_edit(
        &mut self,
        chat_id: &str,
        turn_id: &str,
        resuming: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.record.id != chat_id
            || self.shutting_down
            || self.busy
            || self.loading
            || self.load_failed
            || self.editing.is_some()
            || self.begin_operation.is_some()
            || self.queue_operation.is_some()
            || self.edit_recovery.blocked
            || self.has_pending_cancel(chat_id)
        {
            return;
        }
        if !self.session.pending.iter().any(|item| item.id == turn_id) {
            return;
        }
        let edit = match (resuming, &self.session.edit) {
            (Some(edit), Some(hold)) if hold.edit_id == edit && hold.turn_id == turn_id => edit,
            (Some(_), _) => return,
            (None, None) => Uuid::new_v4().to_string(),
            (None, Some(_)) => return,
        };
        if let Some(earlier) = self
            .retained_edit
            .as_ref()
            .filter(|earlier| earlier.edit_id != edit)
        {
            let earlier_id = earlier.edit_id.clone();
            self.chat.note_begin_failure(
                turn_id,
                "Checking an earlier queued edit first; choose Edit again in a moment.".into(),
            );
            self.reconcile_edit_identity(chat_id, earlier_id, cx);
            return;
        }
        if self.draft_revision.checked_add(1).is_none() {
            self.chat.note_begin_failure(
                turn_id,
                "Draft revision limit reached; your text is preserved.".into(),
            );
            cx.notify();
            return;
        }
        let Some(handle) = window.window_handle().downcast::<AgentView>() else {
            return;
        };
        let key = Key {
            token: Uuid::new_v4(),
            chat: chat_id.into(),
            turn: turn_id.into(),
            edit,
            project: self.project.clone(),
            controller: self.controller.clone(),
            binding: self.window_binding,
            window: handle,
            focus: window.focused(cx),
        };
        // Own the operation synchronously before any background work. Typing
        // stays enabled; no displaced draft is captured until actual adoption.
        self.queue_operation = Some(key.token);
        self.edit_recovery = EditRecovery::new(true);
        self.begin_operation = Some(BeginOperation {
            key: key.clone(),
            deferred: None,
            recheck: false,
        });
        let worker = key.controller.clone();
        let turn = key.turn.clone();
        let edit = key.edit.clone();
        let task = cx.background_executor().spawn(async move {
            worker.begin_edit(&turn, &edit).map_err(|e| e.to_string())?;
            worker.edit_status(&edit).map_err(|e| e.to_string())
        });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| view.finish_begin_read(key, result, cx));
        })
        .detach();
        cx.notify();
    }
    fn accepts_begin(&self, key: &Key) -> bool {
        self.project == key.project
            && self.chat_ref(&key.chat).is_some_and(|chat| {
                chat.queue_operation == Some(key.token)
                    && Arc::ptr_eq(&chat.controller, &key.controller)
                    && chat
                        .begin_operation
                        .as_ref()
                        .is_some_and(|operation| operation.key.token == key.token)
            })
    }
    pub(crate) fn abandon_begin_for_cancel(&mut self, id: &str, edit: &str, turn: &str) -> bool {
        let Some(chat) = self.chat_mut(id) else {
            return false;
        };
        let Some(operation) = &chat.begin_operation else {
            return false;
        };
        if !operation.matches(edit, turn) {
            return false;
        }
        let token = operation.key.token;
        chat.begin_operation = None;
        if chat.queue_operation == Some(token) {
            chat.queue_operation = None;
        }
        true
    }
    pub(crate) fn invalidate_begin_check(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(chat) = self.chat_mut(id) else {
            return;
        };
        let Some(operation) = chat.begin_operation.as_mut() else {
            return;
        };
        operation.recheck = true;
        if operation.deferred.take().is_some() {
            let key = operation.key.clone();
            self.restart_begin_status(key, cx);
        }
    }
    fn restart_begin_status(&mut self, mut key: Key, cx: &mut Context<Self>) {
        if !self.accepts_begin(&key) {
            return;
        }
        key.token = Uuid::new_v4();
        let chat = self.chat_mut(&key.chat).unwrap();
        chat.queue_operation = Some(key.token);
        chat.begin_operation = Some(BeginOperation {
            key: key.clone(),
            deferred: None,
            recheck: false,
        });
        let worker = key.controller.clone();
        let edit = key.edit.clone();
        let task = cx
            .background_executor()
            .spawn(async move { worker.edit_status(&edit).map_err(|e| e.to_string()) });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| view.finish_begin_read(key, result, cx));
        })
        .detach();
    }
    fn finish_begin_read(
        &mut self,
        key: Key,
        result: Result<QueueEditStatus, String>,
        cx: &mut Context<Self>,
    ) {
        if !self.accepts_begin(&key) {
            return;
        }
        if self
            .chat_ref(&key.chat)
            .unwrap()
            .begin_operation
            .as_ref()
            .unwrap()
            .recheck
        {
            self.restart_begin_status(key, cx);
            return;
        }
        if self.window_binding != key.binding {
            let chat = self.chat_mut(&key.chat).unwrap();
            chat.queue_operation = None;
            chat.begin_operation = None;
            self.recheck_edit_after_failure(&key.chat, Some(key.edit), cx);
            return;
        }
        let status = match result {
            Ok(status) => status,
            Err(error) => {
                let chat = self.chat_mut(&key.chat).unwrap();
                chat.queue_operation = None;
                chat.begin_operation = None;
                chat.note_begin_failure(
                    &key.turn,
                    format!("Queued message could not be opened for editing: {error}"),
                );
                self.recheck_edit_after_failure(&key.chat, Some(key.edit), cx);
                cx.notify();
                return;
            }
        };
        let original = match &status.state {
            QueueEditState::Active { turn_id, text }
                if status.edit_id == key.edit && turn_id == &key.turn =>
            {
                text.clone()
            }
            _ => {
                let chat = self.chat_mut(&key.chat).unwrap();
                chat.queue_operation = None;
                chat.begin_operation = None;
                chat.note_begin_failure(
                    &key.turn,
                    "That queued edit is no longer open; the ordinary draft is preserved.".into(),
                );
                self.recheck_edit_after_failure(&key.chat, Some(key.edit), cx);
                cx.notify();
                return;
            }
        };
        let chat = self.chat_mut(&key.chat).unwrap();
        if chat.editing.is_some() {
            chat.queue_operation = None;
            chat.begin_operation = None;
            self.recheck_edit_after_failure(&key.chat, Some(key.edit), cx);
            return;
        }
        if chat.composer.read(cx).has_marked_text() {
            chat.begin_operation.as_mut().unwrap().deferred = Some(status);
            cx.notify();
            return;
        }
        let source = chat.saved_draft(cx);
        let Some(revision) = source.revision.checked_add(1) else {
            chat.note_begin_failure(
                &key.turn,
                "Draft revision limit reached; the held message and ordinary draft are preserved."
                    .into(),
            );
            chat.queue_operation = None;
            chat.begin_operation = None;
            chat.edit_recovery = EditRecovery::new(false);
            cx.notify();
            return;
        };
        let rewrite = source
            .queued_edit
            .as_ref()
            .filter(|edit| edit.edit_id == key.edit && edit.turn_id == key.turn)
            .map_or_else(|| original.clone(), |edit| edit.rewrite.clone());
        let mut candidate = source.clone();
        candidate.revision = revision;
        candidate.queued_edit = Some(QueuedDraft {
            edit_id: key.edit.clone(),
            turn_id: key.turn.clone(),
            rewrite: rewrite.clone(),
            original_text: Some(original.clone()),
        });
        // Active-status reconciliation validates this entire candidate and exact
        // hold identity without changing its payload or duplicating core limits.
        if let Err(error) = candidate.reconcile_queued_status(&status) {
            chat.note_begin_failure(
                &key.turn,
                format!("Queued message stays held; draft was not replaced: {error}"),
            );
            chat.queue_operation = None;
            chat.begin_operation = None;
            chat.edit_recovery = EditRecovery::new(false);
            cx.notify();
            return;
        }
        chat.clear_confirmed_begin_failure(&key.turn);
        chat.draft_before_edit = source.text;
        chat.editing = Some(key.edit.clone());
        chat.queued_turn_id = Some(key.turn.clone());
        chat.queued_original = Some(original);
        chat.retained_edit = None;
        chat.queue_operation = None;
        chat.begin_operation = None;
        chat.edit_recovery = EditRecovery::new(false);
        chat.session = chat.controller.snapshot_shared();
        chat.composer
            .update(cx, |editor, cx| editor.set_text(rewrite, cx));
        // Text adoption is per-chat. Focus is a separate, generation-checked
        // presentation effect and never follows a reader to a different control.
        cx.defer(move |cx| {
            let _ = key.window.update(cx, |view, window, cx| {
                if view.project == key.project
                    && view.record.id == key.chat
                    && view.window_binding == key.binding
                    && Arc::ptr_eq(&view.controller, &key.controller)
                    && view.editing.as_deref() == Some(key.edit.as_str())
                    && window.is_window_active()
                    && window.focused(cx) == key.focus
                {
                    view.composer.read(cx).focus(window);
                }
            });
        });
        cx.notify();
    }
    pub(crate) fn resume_deferred_begin(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(chat) = self.chat_mut(id) else {
            return;
        };
        if chat.composer.read(cx).has_marked_text() {
            return;
        }
        let Some(operation) = chat.begin_operation.as_mut() else {
            return;
        };
        let Some(status) = operation.deferred.take() else {
            return;
        };
        let key = operation.key.clone();
        self.finish_begin_read(key, Ok(status), cx);
    }
}

impl AgentView {
    pub(crate) fn queue_edit_row_state(
        &self,
        turn: &str,
    ) -> crate::queue_edit_controls::QueueEditRowState {
        use crate::queue_edit_controls::QueueEditRowState as Row;
        if self.editing.is_some() && self.queued_turn_id.as_deref() == Some(turn) {
            Row::Owned {
                resolving: self.busy || self.has_pending_cancel(&self.record.id),
            }
        } else if let Some(hold) = self
            .session
            .edit
            .as_ref()
            .filter(|hold| hold.turn_id == turn)
        {
            Row::Held {
                edit_id: hold.edit_id.clone(),
                cancelling: self.has_pending_cancel(&self.record.id),
            }
        } else if self
            .begin_operation
            .as_ref()
            .is_some_and(|operation| operation.turn() == turn)
        {
            Row::Preparing
        } else {
            Row::Available {
                enabled: self.session.edit.is_none()
                    && self.begin_operation.is_none()
                    && !self.busy
                    && !self.loading
                    && !self.load_failed
                    && !self.shutting_down
                    && self.queue_operation.is_none()
                    && !self.edit_recovery.blocked
                    && !self.has_pending_cancel(&self.record.id),
            }
        }
    }
    pub(crate) fn remove_queued_from_chat(
        &mut self,
        chat: &str,
        turn: &str,
        cx: &mut Context<Self>,
    ) {
        if self.record.id != chat
            || matches!(
                self.queue_edit_row_state(turn),
                crate::queue_edit_controls::QueueEditRowState::Held { .. }
            )
        {
            return;
        }
        self.remove_queue(turn.into(), cx);
    }
}

#[cfg(test)]
#[path = "queue_begin_tests.rs"]
mod tests;
