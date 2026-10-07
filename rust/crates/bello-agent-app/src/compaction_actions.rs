//! ConversationPane.swift's implemented Compact Now action. Opening/dismissing
//! this menu never changes the composer, starts a model request or retargets a chat.
use crate::{AgentView, workspace_lifetime::WindowBinding};
use bello_agent_core::{Controller, compaction::Phase};
use gpui::{prelude::*, *};
use std::{path::PathBuf, sync::Arc};

#[derive(Clone)]
pub(crate) struct CompactionMenu {
    chat_id: String,
    controller: Arc<Controller>,
    project: PathBuf,
    binding: Option<WindowBinding>,
    anchor: Point<Pixels>,
}
impl AgentView {
    pub(crate) fn open_compaction_menu(&mut self, anchor: Point<Pixels>, cx: &mut Context<Self>) {
        if self.shutting_down || self.loading || self.load_failed {
            return;
        }
        self.compaction_menu = Some(CompactionMenu {
            chat_id: self.record.id.clone(),
            controller: self.controller.clone(),
            project: self.project.clone(),
            binding: self.window_binding,
            anchor,
        });
        cx.notify();
    }
    fn compact_from_menu(&mut self, cx: &mut Context<Self>) {
        let Some(menu) = self.compaction_menu.take() else {
            return;
        };
        cx.notify();
        if menu.chat_id != self.record.id
            || menu.project != self.project
            || menu.binding != self.window_binding
            || !Arc::ptr_eq(&menu.controller, &self.controller)
        {
            return;
        }
        self.compact_current(cx);
    }
    pub(crate) fn compact_current(&mut self, cx: &mut Context<Self>) {
        let id = self.record.id.clone();
        if self.shutting_down
            || self.loading
            || self.load_failed
            || self.busy
            || self.actor_mutation_blocked(&id)
            || self.edit_recovery.blocked
            || self.queue_operation.is_some()
            || self.has_pending_cancel(&id)
            || self
                .session
                .compaction
                .as_ref()
                .is_some_and(|operation| operation.is_running())
        {
            return;
        }
        let operation = uuid::Uuid::new_v4();
        self.queue_operation = Some(operation);
        let controller = self.controller.clone();
        let worker = controller.clone();
        let project = self.project.clone();
        let task = cx.background_executor().spawn(async move {
            worker
                .compact(None)
                .map_err(|error| format!("Chat could not be compacted: {error}"))
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
    pub(crate) fn compaction_menu_key(
        &mut self,
        event: &KeyDownEvent,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.compaction_menu.is_none() {
            return false;
        }
        if self.close_dialog
            || self.connections.view.read(cx).is_open()
            || self.projects.view.read(cx).is_open()
            || self.quick_open.read(cx).is_open()
        {
            self.compaction_menu = None;
            return false;
        }
        match event.keystroke.key.as_str() {
            "escape" => {
                self.compaction_menu = None;
                cx.notify();
                true
            }
            "enter" if !self.composer.read(cx).has_marked_text() => {
                self.compact_from_menu(cx);
                true
            }
            _ => false,
        }
    }
    pub(crate) fn compaction_menu_element(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let menu = self.compaction_menu.as_ref()?;
        let p = self.palette;
        Some(
            deferred(
                anchored()
                    .position(menu.anchor)
                    .anchor(Corner::BottomRight)
                    .snap_to_window_with_margin(px(8.))
                    .child(
                        div()
                            .id("conversation-actions-menu")
                            .debug_selector(|| "conversation-actions-menu".into())
                            .occlude()
                            .min_w(px(180.))
                            .p(px(4.))
                            .rounded(px(7.))
                            .border_1()
                            .border_color(p.hairline())
                            .bg(rgb(p.surface))
                            .shadow_lg()
                            .on_mouse_down_out(cx.listener(|view, _, _, cx| {
                                view.compaction_menu = None;
                                cx.notify();
                            }))
                            .child(
                                div()
                                    .id("compact-now")
                                    .debug_selector(|| "compact-now".into())
                                    .px(px(8.))
                                    .py(px(6.))
                                    .rounded(px(4.))
                                    .text_size(px(13.))
                                    .text_color(rgb(p.ink))
                                    .cursor_pointer()
                                    .hover(|style| style.bg(p.accent_soft()))
                                    .child("Compact Now")
                                    .on_click(
                                        cx.listener(|view, _, _, cx| view.compact_from_menu(cx)),
                                    ),
                            ),
                    ),
            )
            .with_priority(11)
            .into_any_element(),
        )
    }
}

pub(crate) fn progress_label(session: &bello_agent_core::Session) -> &'static str {
    match session
        .compaction
        .as_ref()
        .map(|operation| &operation.phase)
    {
        Some(Phase::Planning) => "Compacting · Preparing checkpoint…",
        Some(Phase::Summarizing) => "Compacting · Summarizing…",
        _ => "Working · Generating response…",
    }
}

pub(crate) fn row_label<'a>(
    message: &bello_agent_core::Message,
    session: &'a bello_agent_core::Session,
) -> Option<&'a str> {
    if message.compaction.is_some() {
        return Some("Compaction · Checkpoint durably adopted");
    }
    if let Some(operation) = session
        .compaction
        .iter()
        .chain(session.compaction_history.iter().rev())
        .find(|operation| operation.progress_id == message.id)
    {
        if let Some(error) = &operation.error {
            return Some(error);
        }
        return Some(match operation.phase {
            Phase::Planning => "Compaction · Preparing",
            Phase::Summarizing => "Compaction · Summary request",
            Phase::Completed => "Compaction · Summary response retained",
            Phase::Cancelled => "Compaction · Cancelled; original context retained",
            Phase::Interrupted => "Compaction · Interrupted; no terminal receipt",
            Phase::Failed => "Compaction · Failed; original context retained",
        });
    }
    match message.state.as_str() {
        "compaction-complete" => Some("Compaction · Summary response retained"),
        "compaction-cancelled" => Some("Compaction · Cancelled; original context retained"),
        "compaction-failed" => Some("Compaction · Failed; original context retained"),
        "compaction-interrupted" => Some("Compaction · Interrupted; no terminal receipt"),
        _ => None,
    }
}

#[cfg(test)]
#[path = "compaction_actions_tests.rs"]
mod tests;
