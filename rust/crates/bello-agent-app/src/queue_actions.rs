//! Source queue.steer action. Persistence never owns composer or navigation.
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

impl AgentView {
    pub(crate) fn promote_queued(&mut self, chat_id: &str, turn_id: &str, cx: &mut Context<Self>) {
        // A rendered row belongs to one chat, even if its callback outlives a
        // selection change. Completion below still addresses its original chat.
        if self.record.id != chat_id
            || self.shutting_down
            || self.busy
            || self.loading
            || self.load_failed
            || self.queue_promotion.is_some()
            || !offers_promotion(&self.chat, turn_id)
        {
            return;
        }
        let operation = uuid::Uuid::new_v4();
        self.queue_promotion = Some(operation);
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

    pub(crate) fn finish_queue_promotion(
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
        if chat.queue_promotion != Some(operation) || !Arc::ptr_eq(&chat.controller, controller) {
            return;
        }
        chat.queue_promotion = None;
        chat.session = controller.snapshot_shared();
        match result {
            Ok(()) => {
                if chat
                    .queue_promotion_error
                    .as_ref()
                    .is_some_and(|owned| chat.error.as_ref() == Some(owned))
                {
                    chat.error = None;
                }
                chat.queue_promotion_error = None;
            }
            Err(error) => {
                let notice = format!("Queued message could not be promoted: {error}");
                chat.queue_promotion_error = Some(notice.clone());
                chat.error = Some(notice);
                chat.dismissed_error = None;
                chat.error_expanded = false;
            }
        }
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

#[cfg(test)]
#[path = "queue_actions_tests.rs"]
mod tests;
