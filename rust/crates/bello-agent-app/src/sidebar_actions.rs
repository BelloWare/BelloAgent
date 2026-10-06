//! Source sidebar organization and reference actions; neither owns navigation.
use crate::{AgentView, workspace_lifetime::WindowBinding};
use bello_agent_core::workspace::{ChatRecord, organization_timestamp};
use gpui::{prelude::*, *};
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SidebarAction {
    SetPinned(bool),
    CopySessionId,
}

#[derive(Clone)]
pub(crate) struct PinError {
    target_id: String,
    message: String,
}

#[derive(Clone)]
pub(crate) struct SidebarMenu {
    token: uuid::Uuid,
    chat_id: String,
    project: PathBuf,
    binding: Option<WindowBinding>,
    pinned: bool,
    selected: SidebarAction,
    #[cfg(not(target_os = "macos"))]
    position: Point<Pixels>,
}
impl AgentView {
    pub(super) fn sidebar_title<'a>(&'a self, record: &'a ChatRecord) -> &'a str {
        self.chat_ref(&record.id)
            .map(|chat| {
                if chat.loading || chat.load_failed {
                    chat.record.title.as_str()
                } else {
                    chat.session.title.as_str()
                }
            })
            .unwrap_or(record.title.as_str())
    }

    // Rendering and keyboard traversal must share the currently visible order.
    pub(super) fn visible_sidebar_records(&self, cx: &App) -> Vec<&ChatRecord> {
        let filter = self.filter.read(cx).text().trim().to_lowercase();
        let mut records: Vec<_> = self
            .records
            .iter()
            .filter(|record| {
                filter.is_empty() || self.sidebar_title(record).to_lowercase().contains(&filter)
            })
            .collect();
        records.sort_by(|a, b| a.sidebar_cmp(b));
        records
    }

    pub(super) fn open_sidebar_menu(
        &mut self,
        id: &str,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.shutting_down || self.pin_operations.contains_key(id) {
            return;
        }
        let Some(record) = self.records.iter().find(|record| record.id == id) else {
            return;
        };
        let menu = SidebarMenu {
            token: uuid::Uuid::new_v4(),
            chat_id: id.into(),
            project: self.project.clone(),
            binding: self.window_binding,
            pinned: record.pinned_at.is_some(),
            selected: SidebarAction::SetPinned(record.pinned_at.is_none()),
            #[cfg(not(target_os = "macos"))]
            position,
        };
        self.sidebar_menu = Some(menu.clone());
        #[cfg(target_os = "macos")]
        {
            let owner = cx.weak_entity();
            crate::native_menu::show_sidebar_menu(
                cx,
                window.window_handle(),
                position,
                menu.pinned,
                move |choice, cx| {
                    let _ = owner.update(cx, |view, cx| {
                        view.finish_sidebar_menu(menu.token, choice, cx)
                    });
                },
            );
        }
        #[cfg(not(target_os = "macos"))]
        let _ = window;
        cx.notify();
    }
    fn finish_sidebar_menu(
        &mut self,
        token: uuid::Uuid,
        choice: Option<SidebarAction>,
        cx: &mut Context<Self>,
    ) {
        let Some(menu) = self
            .sidebar_menu
            .as_ref()
            .filter(|menu| menu.token == token)
            .cloned()
        else {
            return;
        };
        self.sidebar_menu = None;
        if menu.project == self.project
            && menu.binding == self.window_binding
            && !self.shutting_down
            && let Some(action) = choice
        {
            match action {
                SidebarAction::SetPinned(pinned) => self.set_chat_pinned(&menu.chat_id, pinned, cx),
                SidebarAction::CopySessionId => self.copy_sidebar_session_id(&menu.chat_id, cx),
            }
        }
        cx.notify();
    }
    pub(super) fn sidebar_menu_key(
        &mut self,
        event: &KeyDownEvent,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(menu) = self.sidebar_menu.clone() else {
            return false;
        };
        match event.keystroke.key.as_str() {
            "escape" => self.finish_sidebar_menu(menu.token, None, cx),
            "enter" => self.finish_sidebar_menu(menu.token, Some(menu.selected), cx),
            "up" | "down" => {
                if let Some(menu) = self.sidebar_menu.as_mut() {
                    menu.selected = if event.keystroke.key == "down" {
                        SidebarAction::CopySessionId
                    } else {
                        SidebarAction::SetPinned(!menu.pinned)
                    };
                }
                cx.notify();
            }
            // A context menu owns keyboard input until dismissal; do not type
            // into the still-focused composer or trigger a hidden chat action.
            _ => {}
        }
        true
    }
    fn copy_sidebar_session_id(&mut self, id: &str, cx: &mut Context<Self>) {
        // WorkspaceContent.copySessionID resolves the requested record again at
        // action time. Copying a nonselected/pending chat never selects or saves it.
        if self.records.iter().any(|record| record.id == id) {
            cx.write_to_clipboard(ClipboardItem::new_string(id.to_owned()));
        } else {
            self.error = Some("That chat is no longer available to copy.".into());
        }
    }
    pub(super) fn set_chat_pinned(&mut self, id: &str, pinned: bool, cx: &mut Context<Self>) {
        if self.shutting_down || self.pin_operations.contains_key(id) {
            return;
        }
        let Some(record) = self.records.iter().find(|record| record.id == id).cloned() else {
            return;
        };
        let draft = self
            .chat_ref(id)
            .map(|chat| chat.saved_draft(cx))
            .unwrap_or_else(|| self.unloaded_drafts.get(id).cloned().unwrap_or_default());
        let operation = uuid::Uuid::new_v4();
        self.pin_operations.insert(id.into(), operation);
        let project = self.project.clone();
        let id = id.to_owned();
        let workspace = self.workspace.clone();
        let task = cx.background_executor().spawn(async move {
            workspace
                .lock()
                .map_err(|_| "Workspace is unavailable".to_owned())?
                .set_pinned(record, draft, pinned, organization_timestamp())
                .map_err(|error| error.to_string())
        });
        cx.spawn(async move |owner, cx| {
            let result = task.await;
            let _ = owner.update(cx, |view, cx| {
                view.finish_pin(&id, &project, operation, result, cx)
            });
        })
        .detach();
        cx.notify();
    }
    pub(super) fn finish_pin(
        &mut self,
        id: &str,
        project: &std::path::Path,
        operation: uuid::Uuid,
        result: Result<ChatRecord, String>,
        cx: &mut Context<Self>,
    ) {
        if self.project != project || self.pin_operations.get(id) != Some(&operation) {
            return;
        }
        self.pin_operations.remove(id);
        match result {
            Ok(saved) => {
                if saved.id != id
                    || !self
                        .records
                        .iter()
                        .any(|record| record.id == id && record.snapshot == saved.snapshot)
                {
                    cx.notify();
                    return;
                }
                self.clear_pin_errors(id);
                // Publish only committed organization fields; a streaming title,
                // draft, or later navigation remains authoritative in its owner.
                if let Some(record) = self.records.iter_mut().find(|record| record.id == id) {
                    record.pinned_at = saved.pinned_at;
                    record.sidebar_order = saved.sidebar_order;
                }
                let mut materialized = false;
                if let Some(chat) = self.chat_mut(id) {
                    chat.record.pinned_at = saved.pinned_at;
                    chat.record.sidebar_order = saved.sidebar_order;
                    materialized = chat.pending;
                    chat.pending = false;
                }
                if materialized {
                    // Pending drafts intentionally skip autosave. Typing may have
                    // continued after the pin captured its initial draft, even
                    // in a now-inactive chat. Queue the current revision through
                    // the existing receipt-aware autosave path after registration.
                    self.draft_changed(id, cx);
                }
            }
            Err(error) => {
                let message = format!("Chat pin could not be saved: {error}");
                let display_id = self.record.id.clone();
                self.pin_errors.insert(
                    display_id,
                    PinError {
                        target_id: id.into(),
                        message: message.clone(),
                    },
                );
                self.error = Some(message);
            }
        }
        cx.notify();
    }
    fn clear_pin_errors(&mut self, target_id: &str) {
        let resolved: Vec<_> = self
            .pin_errors
            .iter()
            .filter(|(_, error)| error.target_id == target_id)
            .map(|(display_id, error)| (display_id.clone(), error.message.clone()))
            .collect();
        for (display_id, message) in resolved {
            self.pin_errors.remove(&display_id);
            if let Some(chat) = self.chat_mut(&display_id)
                && chat.error.as_ref() == Some(&message)
            {
                chat.error = None;
            }
        }
    }
    pub(super) fn sidebar_menu_element(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        #[cfg(target_os = "macos")]
        {
            let _ = cx;
            None
        }
        #[cfg(not(target_os = "macos"))]
        {
            let menu = self.sidebar_menu.clone()?;
            let token = menu.token;
            let pinned = !menu.pinned;
            let pin_selected = matches!(menu.selected, SidebarAction::SetPinned(_));
            let p = self.palette;
            let body = div()
                .id("sidebar-pin-menu")
                .occlude()
                .min_w(px(160.))
                .p(px(4.))
                .rounded(px(7.))
                .border_1()
                .border_color(p.hairline())
                .bg(rgb(p.surface))
                .shadow_lg()
                .on_mouse_down_out(
                    cx.listener(move |view, _, _, cx| view.finish_sidebar_menu(token, None, cx)),
                )
                .child(
                    div()
                        .id("sidebar-pin-choice")
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .px(px(8.))
                        .py(px(5.))
                        .rounded(px(4.))
                        .text_size(px(13.))
                        .text_color(rgb(p.ink))
                        .cursor_pointer()
                        .when(pin_selected, |style| style.bg(p.accent_soft()))
                        .on_hover(cx.listener(move |view, hover, _, cx| {
                            if *hover
                                && let Some(menu) =
                                    view.sidebar_menu.as_mut().filter(|m| m.token == token)
                            {
                                menu.selected = SidebarAction::SetPinned(pinned);
                                cx.notify();
                            }
                        }))
                        .on_click(cx.listener(move |view, _, _, cx| {
                            view.finish_sidebar_menu(
                                token,
                                Some(SidebarAction::SetPinned(pinned)),
                                cx,
                            )
                        }))
                        .child(self.icon(if pinned { "pin" } else { "unpin" }, 13.))
                        .child(if pinned { "Pin Chat" } else { "Unpin Chat" }),
                )
                // SidebarChatRow separates organization from reference actions.
                .child(div().h(px(1.)).my(px(4.)).bg(p.hairline()))
                .child(
                    div()
                        .id("sidebar-copy-id-choice")
                        .debug_selector(|| "sidebar-copy-id-choice".into())
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .px(px(8.))
                        .py(px(5.))
                        .rounded(px(4.))
                        .text_size(px(13.))
                        .text_color(rgb(p.ink))
                        .cursor_pointer()
                        .when(!pin_selected, |style| style.bg(p.accent_soft()))
                        .on_hover(cx.listener(move |view, hover, _, cx| {
                            if *hover
                                && let Some(menu) =
                                    view.sidebar_menu.as_mut().filter(|m| m.token == token)
                            {
                                menu.selected = SidebarAction::CopySessionId;
                                cx.notify();
                            }
                        }))
                        .on_click(cx.listener(move |view, _, _, cx| {
                            view.finish_sidebar_menu(token, Some(SidebarAction::CopySessionId), cx)
                        }))
                        .child(self.icon("number", 13.))
                        .child("Copy Session ID"),
                );
            Some(
                deferred(
                    anchored()
                        .position(menu.position)
                        .anchor(Corner::TopLeft)
                        .snap_to_window_with_margin(px(4.))
                        .child(body),
                )
                .with_priority(20)
                .into_any_element(),
            )
        }
    }
}

#[cfg(test)]
#[path = "sidebar_actions_tests.rs"]
mod tests;
