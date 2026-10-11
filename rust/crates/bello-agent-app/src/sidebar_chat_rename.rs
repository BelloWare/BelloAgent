//! Rename Chat… (Swift RenameChatSheet.swift, WorkspaceSessionOrganization
//! .presentRename/.setSessionTitle). The title lives in the chat's own
//! checkpoint, which the sidebar and catalog follow: a loaded chat renames
//! through its controller, an unloaded one through its saved checkpoint and
//! then its catalog row. Title suggestions need a mini model, which this
//! build does not have, so the sheet shows Swift's no-mini-model state.
use crate::{AgentView, chat_organization::catalog_operation};
use bello_agent_core::workspace::{ChatMaterialization, ChatRecord};
use bello_workbench_ui::{EditorEvent, EditorView};
use gpui::{prelude::*, *};

pub(crate) struct RenameSheet {
    pub(crate) token: uuid::Uuid,
    pub(crate) chat_id: String,
    snapshot: std::path::PathBuf,
    /// The title when the sheet opened: its subtitle.
    original: String,
    pub(crate) editor: Entity<EditorView>,
    pub(crate) saving: bool,
    pub(crate) notice: Option<String>,
    _events: Subscription,
}

/// RenameChatSheetView.size.
const SHEET_WIDTH: f32 = 520.;
const SHEET_HEIGHT: f32 = 400.;

impl AgentView {
    /// Why `id` cannot be renamed now, or None when it can.
    pub(crate) fn rename_refusal(&self, id: &str) -> Option<&'static str> {
        let record = self.records.iter().find(|record| record.id == id)?;
        if self.shutting_down || self.project_actions_blocked() || self.known_catalog_uncertainty {
            return Some("Wait for project changes to finish before renaming this chat.");
        }
        if record.materialization == ChatMaterialization::Pending
            || self.chat_ref(id).is_some_and(|chat| chat.pending)
        {
            return Some("Send a first message before renaming this chat.");
        }
        if self
            .chat_ref(id)
            .is_some_and(|chat| chat.loading || chat.load_failed)
        {
            return Some("Wait for this chat to finish loading before renaming it.");
        }
        if self.sidebar_chats.busy.contains(id) {
            return Some("Wait for this chat's change to finish.");
        }
        None
    }
    /// WorkspaceModel.presentRename, from a place with no window at hand
    /// (a menu's completion): the sheet opens on the next turn.
    pub(crate) fn present_rename(&mut self, id: &str, cx: &mut Context<Self>) {
        let (Some(handle), id) = (self.organization_window, id.to_owned()) else {
            return;
        };
        let owner = cx.weak_entity();
        cx.defer(move |cx| {
            let _ = handle.update(cx, |_, window, cx| {
                let _ = owner.update(cx, |view, cx| view.open_rename_sheet(&id, window, cx));
            });
        });
    }
    pub(crate) fn open_rename_sheet(
        &mut self,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(record) = self.records.iter().find(|record| record.id == id).cloned() else {
            return;
        };
        if self.sidebar_chats.modal_open() || self.topic_panel.is_some() {
            return;
        }
        if let Some(refusal) = self.rename_refusal(id) {
            self.error = Some(refusal.into());
            cx.notify();
            return;
        }
        if let Some(menu) = self.sidebar_menu.take() {
            self.sidebar_activity_hold.end_menu(menu.token);
        }
        let title = self.sidebar_title(&record).to_owned();
        let palette = self.palette;
        let editor = cx.new(|cx| {
            let mut editor = EditorView::new(title.clone(), window, cx);
            let mut style = Self::composer_style(palette);
            style.font_size = 13.;
            style.line_height = 19.;
            style.padding_x = 8.;
            style.padding_y = 6.;
            editor.set_appearance(style, cx);
            editor
        });
        editor.update(cx, |editor, cx| {
            let _ = editor.select_all(cx);
        });
        editor.read(cx).focus(window);
        let events = cx.subscribe(&editor, |view, _, event, cx| {
            if matches!(event, EditorEvent::Changed) {
                if let Some(sheet) = view.sidebar_chats.rename.as_mut() {
                    sheet.notice = None;
                }
                cx.notify();
            }
        });
        self.sidebar_chats.rename = Some(RenameSheet {
            token: uuid::Uuid::new_v4(),
            chat_id: id.to_owned(),
            snapshot: record.snapshot.clone(),
            original: title,
            editor,
            saving: false,
            notice: None,
            _events: events,
        });
        cx.notify();
    }
    pub(crate) fn close_rename_sheet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self
            .sidebar_chats
            .rename
            .as_ref()
            .is_some_and(|sheet| !sheet.saving)
        {
            self.sidebar_chats.rename = None;
            self.focus_visible_composer(window, cx);
            self.refresh_read_geometry_route(cx);
            cx.notify();
        }
    }
    /// RenameChatSheetView.save: the trimmed title, once.
    pub(crate) fn save_rename(&mut self, cx: &mut Context<Self>) {
        let Some(sheet) = self.sidebar_chats.rename.as_ref() else {
            return;
        };
        if sheet.saving || sheet.editor.read(cx).has_marked_text() {
            return;
        }
        let (token, id, snapshot) = (sheet.token, sheet.chat_id.clone(), sheet.snapshot.clone());
        let title = match ChatRecord::normalized_title(sheet.editor.read(cx).text()) {
            Ok(title) => title,
            Err(_) => return,
        };
        let refusal = if self
            .records
            .iter()
            .any(|record| record.id == id && record.snapshot == snapshot)
        {
            self.rename_refusal(&id)
        } else {
            Some("This saved chat is unavailable.")
        };
        if let Some(refusal) = refusal {
            self.sidebar_chats.rename.as_mut().unwrap().notice = Some(refusal.into());
            cx.notify();
            return;
        }
        self.sidebar_chats.rename.as_mut().unwrap().saving = true;
        self.sidebar_chats.busy.insert(id.clone());
        let controller = self.chat_ref(&id).map(|chat| chat.controller.clone());
        let workspace = self.workspace.clone();
        let saved_title = title.clone();
        let saved_id = id.clone();
        let task = cx.background_executor().spawn(async move {
            match controller {
                // The loaded chat's snapshot carries the title to its row and
                // catalog (adopt_snapshot), as a first-message title does.
                Some(controller) => crate::chat_organization::CatalogOutcome {
                    result: controller.rename(&saved_title).map(|()| None),
                    uncertain: false,
                },
                None => {
                    if let Err(error) = bello_agent_core::workspace::rename_saved_checkpoint(
                        &snapshot,
                        &saved_id,
                        &saved_title,
                    ) {
                        return crate::chat_organization::CatalogOutcome {
                            result: Err(error),
                            uncertain: false,
                        };
                    }
                    catalog_operation(&workspace, |store| {
                        store
                            .rename_chat(&saved_id, &snapshot, &saved_title)
                            .map(Some)
                    })
                }
            }
        });
        cx.spawn(async move |view, cx| {
            let outcome = task.await;
            let _ = view.update(cx, |view, cx| view.finish_rename(token, &id, outcome, cx));
        })
        .detach();
        cx.notify();
    }
    fn finish_rename(
        &mut self,
        token: uuid::Uuid,
        id: &str,
        outcome: crate::chat_organization::CatalogOutcome<Option<ChatRecord>>,
        cx: &mut Context<Self>,
    ) {
        self.sidebar_chats.busy.remove(id);
        self.observe_catalog_uncertainty(outcome.uncertain, cx);
        let result = outcome.display_result();
        if let Ok(Some(saved)) = &result
            && let Some(record) = self
                .records
                .iter_mut()
                .find(|record| record.id == saved.id && record.snapshot == saved.snapshot)
        {
            record.title = saved.title.clone();
        }
        let current = self
            .sidebar_chats
            .rename
            .as_ref()
            .is_some_and(|sheet| sheet.token == token);
        match result {
            Ok(_) if current => {
                self.sidebar_chats.rename = None;
                self.refresh_read_geometry_route(cx);
                if let Some(handle) = self.organization_window {
                    let owner = cx.weak_entity();
                    cx.defer(move |cx| {
                        let _ = handle.update(cx, |_, window, cx| {
                            let _ = owner.update(cx, |view, cx| {
                                if !view.sidebar_chats.modal_open() && view.topic_panel.is_none() {
                                    view.focus_visible_composer(window, cx);
                                }
                            });
                        });
                    });
                }
            }
            Ok(_) => {}
            Err(error) if current => {
                let sheet = self.sidebar_chats.rename.as_mut().unwrap();
                sheet.saving = false;
                sheet.notice = Some(error);
            }
            Err(error) => self.error = Some(format!("The chat could not be renamed: {error}")),
        }
        cx.notify();
    }
    pub(crate) fn rename_sheet_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(sheet) = self.sidebar_chats.rename.as_ref() else {
            return;
        };
        let key = &event.keystroke;
        let marked = sheet.editor.read(cx).has_marked_text();
        let command =
            key.modifiers.platform || (cfg!(target_os = "linux") && key.modifiers.control);
        if key.key == "escape" || (command && key.key == "w") {
            if !marked || key.key != "escape" {
                self.close_rename_sheet(window, cx);
                self.cancelled_prompt_key = Some(key.key.clone());
                cx.stop_propagation();
            }
        } else if key.key == "enter" && !marked && !key.modifiers.shift {
            // Return submits; the field never takes a newline.
            if !event.is_held {
                self.save_rename(cx);
            }
            self.cancelled_prompt_key = Some(key.key.clone());
            cx.stop_propagation();
        } else if key.key == "tab" {
            cx.stop_propagation();
        }
    }
    pub(crate) fn rename_sheet_element(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let sheet = self.sidebar_chats.rename.as_ref()?;
        let p = self.palette;
        let token = sheet.token;
        let saving = sheet.saving;
        let can_rename =
            !saving && ChatRecord::normalized_title(sheet.editor.read(cx).text()).is_ok();
        let viewport = window.viewport_size();
        let width = SHEET_WIDTH.min((f32::from(viewport.width) - 32.).max(240.));
        let height = SHEET_HEIGHT.min((f32::from(viewport.height) - 32.).max(240.));
        let button = |id: &'static str, label: &'static str, primary: bool, enabled: bool| {
            div()
                .id(id)
                .debug_selector(move || id.into())
                .px(px(14.))
                .py(px(6.))
                .rounded(px(8.))
                .text_size(px(13.))
                .font_weight(FontWeight::MEDIUM)
                .when(primary, |button| {
                    button.bg(rgb(p.accent)).text_color(p.on_accent())
                })
                .when(!primary, |button| {
                    button
                        .border_1()
                        .border_color(p.hairline())
                        .bg(rgb(p.surface))
                        .text_color(rgb(p.ink))
                })
                .when(enabled, |button| button.cursor_pointer())
                .when(!enabled, |button| button.opacity(0.45))
                .child(label)
        };
        let header = div()
            .flex()
            .items_start()
            .gap(px(12.))
            .child(
                div()
                    .size(px(32.))
                    .rounded(px(8.))
                    .bg(p.accent_soft())
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(self.icon("pencil", 15.).text_color(rgb(p.accent))),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(px(17.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(rgb(p.ink))
                            .child("Rename chat"),
                    )
                    .child(
                        div()
                            .debug_selector(|| "rename-chat-subtitle".into())
                            .text_size(px(12.))
                            .text_color(rgb(p.secondary))
                            .truncate()
                            .child(sheet.original.replace('\n', " ")),
                    ),
            );
        let field = div()
            .id("rename-chat-field")
            .debug_selector(|| "rename-chat-field".into())
            .relative()
            .h(px(32.))
            .rounded(px(8.))
            .border_1()
            .border_color(p.hairline())
            .bg(rgb(p.sunken))
            .flex()
            .items_center()
            .gap(px(4.))
            .pl(px(8.))
            .child(self.icon("pencil.line", 13.))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .child(sheet.editor.clone()),
            )
            .when(sheet.editor.read(cx).text().is_empty(), |field| {
                field.child(
                    div()
                        .absolute()
                        .left(px(35.))
                        .top(px(7.))
                        .text_size(px(13.))
                        .text_color(rgb(p.tertiary))
                        .child("Chat title"),
                )
            });
        let suggestions = div()
            .flex()
            .items_center()
            .gap(px(8.))
            .child(
                div()
                    .flex_1()
                    .text_size(px(10.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(rgb(p.tertiary))
                    .child("SUGGESTIONS"),
            )
            .child(
                div()
                    .id("rename-chat-suggest")
                    .debug_selector(|| "rename-chat-suggest".into())
                    .flex()
                    .items_center()
                    .gap(px(5.))
                    .px(px(10.))
                    .py(px(4.))
                    .rounded(px(7.))
                    .border_1()
                    .border_color(p.hairline())
                    .text_size(px(12.))
                    .text_color(rgb(p.ink))
                    .opacity(0.45)
                    .tooltip(|_, cx| {
                        cx.new(|_| {
                            crate::sidebar_actions::ArchiveVisibilityHint(
                                "Suggestions need a mini model for this connection; choose one in Settings.",
                            )
                        })
                        .into()
                    })
                    .child(self.icon("sparkles", 12.))
                    .child("Suggest titles"),
            );
        let explainer = div()
            .text_size(px(12.))
            .text_color(rgb(p.secondary))
            .child("Choose a mini model for this connection in Settings to get suggestions.");
        let notice = sheet.notice.clone().map(|notice| {
            div()
                .debug_selector(|| "rename-chat-notice".into())
                .text_size(px(12.))
                .text_color(rgb(p.danger))
                .child(notice)
        });
        let footer = div()
            .flex()
            .items_center()
            .gap(px(8.))
            .child(div().flex_1())
            .child(
                button("rename-chat-cancel", "Cancel", false, !saving).on_click(cx.listener(
                    move |view, _, window, cx| {
                        if view
                            .sidebar_chats
                            .rename
                            .as_ref()
                            .is_some_and(|sheet| sheet.token == token)
                        {
                            view.close_rename_sheet(window, cx);
                        }
                    },
                )),
            )
            .child(
                button(
                    "rename-chat-save",
                    if saving { "Renaming…" } else { "Rename" },
                    true,
                    can_rename,
                )
                .on_click(cx.listener(move |view, _, _, cx| {
                    if view
                        .sidebar_chats
                        .rename
                        .as_ref()
                        .is_some_and(|sheet| sheet.token == token)
                    {
                        view.save_rename(cx);
                    }
                })),
            );
        let body = div()
            .id("rename-chat-sheet")
            .debug_selector(|| "rename-chat-sheet".into())
            .w(px(width))
            .h(px(height))
            .p(px(24.))
            .rounded(px(16.))
            .bg(rgb(p.surface))
            .border_1()
            .border_color(p.hairline())
            .shadow_lg()
            .flex()
            .flex_col()
            .gap(px(12.))
            .occlude()
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(header)
            .child(field)
            .child(suggestions)
            .child(explainer)
            .children(notice)
            .child(div().flex_1())
            .child(footer);
        Some(
            div()
                .absolute()
                .inset_0()
                .bg(rgba(0x00000055))
                .flex()
                .items_center()
                .justify_center()
                .occlude()
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .child(body)
                .into_any_element(),
        )
    }
}
