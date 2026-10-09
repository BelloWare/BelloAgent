//! Source queue actions. Persistence never owns composer or navigation.
use crate::{AgentView, ChatState};
use bello_agent_core::{Controller, Lane, RunState};
use gpui::{Context, SharedString};
use std::{path::Path, sync::Arc};

pub(crate) fn offers_promotion(chat: &ChatState, turn_id: &str) -> bool {
    chat.session.state == RunState::Running
        && chat.session.edit.is_none()
        && chat
            .session
            .pending
            .iter()
            .any(|item| item.id == turn_id && item.lane == Lane::FollowUp)
}

/// SessionDisplay.canResumeQueue, within the existing nonempty queue panel.
pub(crate) fn offers_resume(chat: &ChatState) -> bool {
    chat.session.state != RunState::Running
        && (!chat.session.pending.is_empty()
            || chat.session.queue_paused
            || matches!(chat.session.state, RunState::Paused | RunState::Error))
}

pub(crate) fn resume_label(chat: &ChatState) -> &'static str {
    if chat.session.queue_paused {
        "Resume"
    } else {
        "Send queued"
    }
}

impl AgentView {
    /// Only work still in flight delays Archive. IME-deferred adoption and
    /// retained recovery errors keep their identity without holding admission.
    pub(crate) fn archive_chat_work_live(&self, chat_id: &str) -> bool {
        self.chat_ref(chat_id).is_some_and(|chat| {
            chat.busy
                || chat.loading
                || chat.inflight_submission.is_some()
                || chat
                    .cancel_operation
                    .as_ref()
                    .is_some_and(|operation| operation.is_live())
                || chat
                    .begin_operation
                    .as_ref()
                    .is_some_and(|operation| !operation.is_deferred())
                || chat.edit_recovery.has_live_check()
                || chat.queue_operation.is_some_and(|token| {
                    // A token not positively owned by a completed/deferred
                    // operation is conservatively still live (Resume, etc.).
                    !chat.cancel_operation.as_ref().is_some_and(|operation| {
                        operation.is_deferred() && operation.owns_queue_token(token)
                    }) && !chat.begin_operation.as_ref().is_some_and(|operation| {
                        operation.is_deferred() && operation.owns_queue_token(token)
                    }) && !(chat.edit_recovery.is_deferred()
                        && chat.edit_recovery.owns_queue_token(token))
                })
        })
    }

    pub(crate) fn resume_queued(&mut self, chat_id: &str, cx: &mut Context<Self>) {
        if self.record.id != chat_id
            || (self.record.connection_id.is_some() && !self.controller.configured())
            || self.actor_mutation_blocked(chat_id)
            || self.shutting_down
            || self.busy
            || self.loading
            || self.load_failed
            || self.edit_recovery.blocked
            || self.queue_operation.is_some()
            || self.session.edit.is_some()
            || !offers_resume(&self.chat)
        {
            return;
        }
        let operation = uuid::Uuid::new_v4();
        self.queue_operation = Some(operation);
        let controller = self.controller.clone();
        let worker = controller.clone();
        let chat_id = chat_id.to_owned();
        let project = self.project.clone();
        let read_states = self.read_states.clone();
        let workspace = self.workspace.clone();
        let record = self.record.clone();
        let task = cx.background_executor().spawn(async move {
            let baseline = crate::chat_organization::catalog_operation(&workspace, |store| {
                crate::sidebar_read_state::prepare_admission(&read_states, store, &record, &worker)
            });
            let uncertain = baseline.uncertain;
            let result = baseline.display_result().and_then(|()| {
                worker
                    .resume()
                    .map_err(|error| format!("Queued messages could not be resumed: {error}"))
            });
            (result, uncertain)
        });
        cx.spawn(async move |view, cx| {
            let (result, uncertain) = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.project == project {
                    view.observe_catalog_uncertainty(uncertain, cx);
                }
                view.finish_queue_operation(&chat_id, &project, &controller, operation, result, cx)
            });
        })
        .detach();
        cx.notify();
    }

    pub(crate) fn promote_queued(&mut self, chat_id: &str, turn_id: &str, cx: &mut Context<Self>) {
        // A rendered row belongs to one chat, even if its callback outlives a
        // selection change. Completion below still addresses its original chat.
        if self.record.id != chat_id
            || self.actor_mutation_blocked(chat_id)
            || self.shutting_down
            || self.busy
            || self.loading
            || self.load_failed
            || self.edit_recovery.blocked
            || self.queue_operation.is_some()
            || !offers_promotion(&self.chat, turn_id)
        {
            return;
        }
        let operation = uuid::Uuid::new_v4();
        self.queue_operation = Some(operation);
        let controller = self.controller.clone();
        let worker = controller.clone();
        let chat_id = chat_id.to_owned();
        let turn_id = turn_id.to_owned();
        let project = self.project.clone();
        let task = cx.background_executor().spawn(async move {
            worker
                .promote_to_steering(&turn_id)
                .map_err(|error| error.to_string())
        });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                view.finish_queue_promotion(&chat_id, &project, &controller, operation, result, cx)
            });
        })
        .detach();
        cx.notify();
    }

    pub(crate) fn reorder_queued(
        &mut self,
        drag: &crate::queue_drag::QueueDrag,
        order: Vec<String>,
        cx: &mut Context<Self>,
    ) {
        if !self.accepts_queue_drag(drag)
            || self.actor_mutation_blocked(&drag.chat_id)
            || self.queue_operation.is_some()
            || self.busy
            || self.loading
            || self.load_failed
            || self.edit_recovery.blocked
            || self.shutting_down
        {
            return;
        }
        let operation = uuid::Uuid::new_v4();
        self.queue_operation = Some(operation);
        let controller = self.controller.clone();
        let worker = controller.clone();
        let id = self.record.id.clone();
        let project = self.project.clone();
        let task = cx.background_executor().spawn(async move {
            worker.reorder(&order).map_err(|error| match error {
                bello_agent_core::Error::QueueOrder => error.to_string(),
                _ => format!("The queue was not reordered. {error}"),
            })
        });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                view.finish_queue_operation(&id, &project, &controller, operation, result, cx)
            });
        })
        .detach();
        cx.notify();
    }

    pub(crate) fn finish_queue_promotion(
        &mut self,
        chat_id: &str,
        project: &Path,
        controller: &Arc<Controller>,
        operation: uuid::Uuid,
        result: Result<(), String>,
        cx: &mut Context<Self>,
    ) {
        self.finish_queue_operation(
            chat_id,
            project,
            controller,
            operation,
            result.map_err(|error| format!("Queued message could not be promoted: {error}")),
            cx,
        );
    }

    pub(crate) fn finish_queue_operation(
        &mut self,
        chat_id: &str,
        project: &Path,
        controller: &Arc<Controller>,
        operation: uuid::Uuid,
        result: Result<(), String>,
        cx: &mut Context<Self>,
    ) {
        if self.project != project {
            return;
        }
        let Some(chat) = self.chat_mut(chat_id) else {
            return;
        };
        if chat.queue_operation != Some(operation) || !Arc::ptr_eq(&chat.controller, controller) {
            return;
        }
        chat.queue_operation = None;
        chat.session = controller.snapshot_shared();
        match result {
            Ok(()) => {
                if chat
                    .queue_operation_error
                    .as_ref()
                    .is_some_and(|owned| chat.error.as_ref() == Some(owned))
                {
                    chat.error = None;
                }
                chat.queue_operation_error = None;
            }
            Err(notice) => {
                chat.queue_operation_error = Some(notice.clone());
                chat.error = Some(notice);
                chat.dismissed_error = None;
                chat.error_expanded = false;
            }
        }
        self.drain_edit_recheck(chat_id, cx);
        cx.notify();
    }
}

pub(crate) fn promotion_control_id(turn_id: &str) -> SharedString {
    format!("promote-{turn_id}").into()
}

pub(crate) struct PromotionHint(pub(crate) crate::theme::Palette);
impl gpui::Render for PromotionHint {
    fn render(&mut self, _: &mut gpui::Window, _: &mut Context<Self>) -> impl gpui::IntoElement {
        use gpui::{prelude::*, *};
        div()
            .px(px(8.))
            .py(px(5.))
            .rounded(px(6.))
            .border_1()
            .border_color(self.0.hairline())
            .bg(rgb(self.0.surface))
            .text_color(rgb(self.0.ink))
            .text_size(px(11.5))
            .child("Deliver after the current response, before follow-ups")
    }
}

pub(crate) struct ResumeEditHint(pub(crate) crate::theme::Palette);
impl gpui::Render for ResumeEditHint {
    fn render(&mut self, _: &mut gpui::Window, _: &mut Context<Self>) -> impl gpui::IntoElement {
        use gpui::{prelude::*, *};
        div()
            .px(px(8.))
            .py(px(5.))
            .rounded(px(6.))
            .bg(rgb(self.0.surface))
            .text_color(rgb(self.0.ink))
            .text_size(px(11.5))
            .child("Finish or cancel the queued edit first")
    }
}

#[cfg(test)]
#[path = "queue_actions_tests.rs"]
mod tests;
