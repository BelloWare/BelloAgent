//! Delete Chat… (Swift WorkspaceChatLifecycle.deleteChat/performDelete).
//! A chat that exists only on screen is dropped without a question. A saved
//! chat is asked about, its writer retired, its catalog rows removed, and only
//! then its own managed checkpoint and journals moved to the Trash; a
//! checkpoint outside the catalog's managed path stays where it is.
use crate::AgentView;
use bello_agent_core::workspace::{ChatRecord, DELETE_WORK_NOTICE, DeletedChat, DraftRecord};
use gpui::{prelude::*, *};
use std::path::{Path, PathBuf};

pub(crate) struct DeleteQuestion {
    pub(crate) token: uuid::Uuid,
    pub(crate) chat_id: String,
    snapshot: PathBuf,
    title: String,
    detail: &'static str,
}

/// What a background deletion hands back to the window.
struct DeleteOutcome {
    catalog: crate::chat_organization::CatalogOutcome<DeletedChat>,
    retire_error: Option<String>,
    trash_error: Option<String>,
}

impl AgentView {
    /// Why `id` cannot be deleted now, or None when it can.
    pub(crate) fn delete_refusal(&self, id: &str) -> Option<&'static str> {
        if self.shutting_down || self.project_actions_blocked() || self.known_catalog_uncertainty {
            return Some("Wait for project changes to finish before deleting this chat.");
        }
        if self.organization_operations.contains_key(id)
            || self.topic_owns_chat(id)
            || self.picker_owns_chat(id)
            || self.chat_mode_blocked.contains(id)
            || self.connections.switches.contains_key(id)
            || self.connections.blocked.contains(id)
            || self.sidebar_chats.busy.contains(id)
        {
            return Some("Wait for this chat's changes to finish before deleting it.");
        }
        let work = self.chat_ref(id).is_some_and(|chat| {
            chat.busy
                || chat.loading
                || chat.inflight_submission.is_some()
                || chat.queue_operation.is_some()
                || chat.editing.is_some()
                || chat.begin_operation.is_some()
                || chat.cancel_operation.is_some()
                || !chat.session.pending.is_empty()
                || chat.session.edit.is_some()
                || chat.session.state == bello_agent_core::RunState::Running
                || chat.session.active.is_some()
                || chat.session.active_reply.is_some()
        }) || self.recoveries.values().any(|intent| intent.chat_id == id)
            || self.has_pending_cancel(id);
        if work {
            return Some(DELETE_WORK_NOTICE);
        }
        if self.record.id == id && !self.records.iter().any(|record| record.id != id) {
            return Some("Create another chat before deleting this one.");
        }
        None
    }
    /// WorkspaceModel.deleteChat(_:).
    pub(crate) fn ask_delete_chat(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(record) = self.records.iter().find(|record| record.id == id).cloned() else {
            return;
        };
        if self.sidebar_chats.modal_open() || self.topic_panel.is_some() {
            return;
        }
        if let Some(refusal) = self.delete_refusal(id) {
            self.error = Some(refusal.into());
            cx.notify();
            return;
        }
        let managed = self
            .workspace
            .try_lock()
            .ok()
            .and_then(|store| store.chat_path(id).ok())
            .is_none_or(|path| path == record.snapshot)
            || record.snapshot == crate::default_session();
        let title = if record.archived_at.is_some() {
            format!(
                "Delete the archived chat “{}”?",
                self.sidebar_title(&record).replace('\n', " ")
            )
        } else {
            "Delete this chat?".into()
        };
        if let Some(menu) = self.sidebar_menu.take() {
            self.sidebar_activity_hold.end_menu(menu.token);
        }
        self.sidebar_chats.delete = Some(DeleteQuestion {
            token: uuid::Uuid::new_v4(),
            chat_id: id.to_owned(),
            snapshot: record.snapshot.clone(),
            title,
            detail: if managed {
                "Move its managed conversation file to Trash and remove its draft and current memory traces, and locally retained traces."
            } else {
                "Remove its app index and draft. The imported original stays in place."
            },
        });
        cx.notify();
    }
    pub(crate) fn dismiss_delete_question(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.sidebar_chats.delete.take().is_some() {
            self.focus_visible_composer(window, cx);
            self.refresh_read_geometry_route(cx);
            cx.notify();
        }
    }
    /// The question's Delete Chat: performDelete.
    pub(crate) fn confirm_delete_chat(
        &mut self,
        token: uuid::Uuid,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(question) = self
            .sidebar_chats
            .delete
            .take_if(|question| question.token == token)
        else {
            return;
        };
        self.refresh_read_geometry_route(cx);
        cx.notify();
        let id = question.chat_id;
        let Some(record) = self
            .records
            .iter()
            .find(|record| record.id == id && record.snapshot == question.snapshot)
            .cloned()
        else {
            return;
        };
        if let Some(refusal) = self.delete_refusal(&id) {
            self.error = Some(refusal.into());
            return;
        }
        // The open chat steps aside first, to the chat Archive would open.
        if self.record.id == id {
            let destination = self
                .records
                .iter()
                .filter(|other| other.id != id)
                .min_by(|a, b| {
                    a.archived_at
                        .is_some()
                        .cmp(&b.archived_at.is_some())
                        .then_with(|| a.sidebar_cmp(b))
                })
                .map(|other| other.id.clone());
            if let Some(destination) = destination {
                self.select_chat_internal(&destination, false, window, cx);
            }
            if self.record.id == id {
                self.error = Some("The chat could not be closed for deletion.".into());
                return;
            }
        }
        let chat = self.inactive.remove(&id);
        // Navigation itself drops an empty chat that exists only on screen.
        if chat.as_ref().is_some_and(|chat| chat.pending)
            || !self.records.iter().any(|row| row.id == id)
        {
            // discardPendingChat: nothing was written.
            self.records.retain(|record| record.id != id);
            self.forget_deleted_chat(&id);
            self.focus_visible_composer(window, cx);
            return;
        }
        // The draft this window holds, restored if the catalog refuses.
        let draft = chat
            .as_ref()
            .map(|chat| chat.saved_draft(cx))
            .or_else(|| self.unloaded_drafts.get(&id).cloned())
            .unwrap_or_default();
        let controller = chat.map(|chat| chat.controller.clone());
        let index = self.records.iter().position(|row| row.id == id);
        self.records.retain(|row| row.id != id);
        self.sidebar_chats.busy.insert(id.clone());
        self.focus_visible_composer(window, cx);
        let workspace = self.workspace.clone();
        let snapshot = record.snapshot.clone();
        let saved_id = id.clone();
        let trash_root = self.deleted_chats_directory(&record);
        let anchor = Some(crate::default_session());
        let task = cx.background_executor().spawn(async move {
            // session.forget: the chat's writer releases its checkpoint.
            // Only a verified persistent writer speaks for the checkpoint; a
            // placeholder left by a failed load does not.
            let loaded = controller
                .as_ref()
                .is_some_and(|controller| controller.is_persistent());
            let retire_error = match controller {
                Some(controller) => controller
                    .retire_and_wait()
                    .await
                    .err()
                    .map(|error| error.to_string()),
                None => None,
            };
            // An unloaded (or never verified) chat's checkpoint is the
            // authority on its queue: inspect it read-only under its writer
            // lock, and keep that lock until the catalog has let go.
            let mut _writer = None;
            if !loaded && snapshot.exists() {
                let lease = bello_agent_core::session::SessionInspectionLease::acquire(
                    &snapshot, &saved_id,
                )
                .and_then(|lease| {
                    lease
                        .into_idle_lease()
                        .map_err(|_| bello_agent_core::Error::Invalid(DELETE_WORK_NOTICE.into()))
                });
                match lease {
                    Ok(lease) => _writer = Some(lease),
                    Err(error) => {
                        return DeleteOutcome {
                            catalog: crate::chat_organization::CatalogOutcome {
                                result: Err(error),
                                uncertain: false,
                            },
                            retire_error: None,
                            trash_error: None,
                        };
                    }
                }
            }
            let catalog = crate::chat_organization::catalog_operation(&workspace, |store| {
                store.delete_chat(&saved_id, &snapshot, anchor.as_deref())
            });
            drop(_writer);
            let trash_error = match (&catalog.result, &retire_error) {
                (Ok(deleted), None) => trash_chat_files(deleted, trash_root.as_deref()).err(),
                (Ok(deleted), Some(_)) if !deleted.managed_files.is_empty() => Some(
                    "Its writer did not stop, so its conversation file was left in place.".into(),
                ),
                _ => None,
            };
            DeleteOutcome {
                catalog,
                retire_error,
                trash_error,
            }
        });
        cx.spawn(async move |view, cx| {
            let outcome = task.await;
            let _ = view.update(cx, |view, cx| {
                view.finish_delete_chat(&id, record, index, draft, outcome, cx)
            });
        })
        .detach();
    }
    fn finish_delete_chat(
        &mut self,
        id: &str,
        record: ChatRecord,
        index: Option<usize>,
        draft: DraftRecord,
        outcome: DeleteOutcome,
        cx: &mut Context<Self>,
    ) {
        self.sidebar_chats.busy.remove(id);
        self.observe_catalog_uncertainty(outcome.catalog.uncertain, cx);
        match outcome.catalog.display_result() {
            Ok(_) => {
                self.read_states.lock().unwrap().forget(id);
                self.forget_deleted_chat(id);
                if let Some(error) = outcome.trash_error {
                    self.error = Some(format!(
                        "The chat was deleted, but its conversation file could not be moved to the Trash. {error}"
                    ));
                }
            }
            Err(error) => {
                // Nothing was removed: the row and its draft come back.
                if !self.records.iter().any(|row| row.id == id) {
                    let at = index.unwrap_or(0).min(self.records.len());
                    self.records.insert(at, record);
                }
                if !draft.is_empty() && self.chat_ref(id).is_none() {
                    self.unloaded_drafts.insert(id.to_owned(), draft);
                }
                let retire = outcome
                    .retire_error
                    .map(|error| format!(" {error}"))
                    .unwrap_or_default();
                self.error = Some(format!("Chat deletion did not complete. {error}{retire}"));
            }
        }
        cx.notify();
    }
    fn forget_deleted_chat(&mut self, id: &str) {
        self.unloaded_drafts.remove(id);
        self.queued_cancellations.remove(id);
        self.sidebar_chats.forget(id);
        self.organization_errors
            .retain(|display, error| display != id && error.target_id() != id);
        self.sidebar_activity_hold.prune(&self.records);
        self.sidebar_search.cancel();
    }
    /// Where deleted files go when there is no system Trash to move them to.
    fn deleted_chats_directory(&self, record: &ChatRecord) -> Option<PathBuf> {
        record
            .snapshot
            .parent()
            .and_then(Path::parent)
            .map(|state| state.join("Deleted Chats"))
    }
    pub(crate) fn delete_question_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let key = &event.keystroke;
        let command =
            key.modifiers.platform || (cfg!(target_os = "linux") && key.modifiers.control);
        if key.key == "escape" || (command && key.key == "w") {
            self.dismiss_delete_question(window, cx);
            self.cancelled_prompt_key = Some(key.key.clone());
        } else if key.key == "enter" {
            // A destructive question is never answered by Return alone.
            self.cancelled_prompt_key = Some(key.key.clone());
        }
        // The question owns the keyboard: nothing reaches the composer.
        cx.stop_propagation();
    }
    pub(crate) fn delete_question_element(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let question = self.sidebar_chats.delete.as_ref()?;
        let p = self.palette;
        let token = question.token;
        let width = 440f32.min((f32::from(window.viewport_size().width) - 32.).max(240.));
        let body = div()
            .id("delete-chat-question")
            .debug_selector(|| "delete-chat-question".into())
            .w(px(width))
            .p(px(24.))
            .rounded(px(16.))
            .bg(rgb(p.surface))
            .border_1()
            .border_color(p.hairline())
            .shadow_lg()
            .flex()
            .flex_col()
            .gap(px(16.))
            .occlude()
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(
                div()
                    .debug_selector(|| "delete-chat-title".into())
                    .text_size(px(17.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(rgb(p.ink))
                    .child(question.title.clone()),
            )
            .child(
                div()
                    .debug_selector(|| "delete-chat-detail".into())
                    .text_size(px(13.))
                    .text_color(rgb(p.secondary))
                    .child(question.detail),
            )
            .child(
                div()
                    .flex()
                    .gap(px(12.))
                    .justify_end()
                    .child(
                        div()
                            .id("delete-chat-cancel")
                            .debug_selector(|| "delete-chat-cancel".into())
                            .px(px(14.))
                            .py(px(6.))
                            .rounded(px(8.))
                            .border_1()
                            .border_color(p.hairline())
                            .text_size(px(13.))
                            .text_color(rgb(p.ink))
                            .cursor_pointer()
                            .child("Cancel")
                            .on_click(cx.listener(move |view, _, window, cx| {
                                if view
                                    .sidebar_chats
                                    .delete
                                    .as_ref()
                                    .is_some_and(|question| question.token == token)
                                {
                                    view.dismiss_delete_question(window, cx);
                                }
                            })),
                    )
                    .child(
                        div()
                            .id("delete-chat-confirm")
                            .debug_selector(|| "delete-chat-confirm".into())
                            .px(px(14.))
                            .py(px(6.))
                            .rounded(px(8.))
                            .bg(rgb(p.danger))
                            .text_size(px(13.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(0xffffff))
                            .cursor_pointer()
                            .child("Delete Chat")
                            .on_click(cx.listener(move |view, _, window, cx| {
                                view.confirm_delete_chat(token, window, cx)
                            })),
                    ),
            );
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

/// Move the chat's own files to the Trash, then drop its empty lock sidecar.
fn trash_chat_files(deleted: &DeletedChat, fallback: Option<&Path>) -> Result<(), String> {
    for path in &deleted.managed_files {
        move_to_trash(path, fallback).map_err(|error| error.to_string())?;
    }
    if let Some(lock) = &deleted.lock_file {
        match std::fs::remove_file(lock) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                return Err(error.to_string());
            }
            _ => {}
        }
    }
    Ok(())
}

/// NSWorkspace.recycle's equivalent: NSFileManager's trashItemAtURL.
#[cfg(all(target_os = "macos", not(test)))]
fn move_to_trash(path: &Path, _fallback: Option<&Path>) -> std::io::Result<()> {
    use cocoa::{
        base::{BOOL, YES, id, nil},
        foundation::NSString,
    };
    use objc::{class, msg_send, sel, sel_impl};
    let Some(path) = path.to_str() else {
        return Err(std::io::Error::other("The file path is not valid UTF-8."));
    };
    unsafe {
        let pool: id = msg_send![class!(NSAutoreleasePool), new];
        let string = NSString::alloc(nil).init_str(path);
        let url: id = msg_send![class!(NSURL), fileURLWithPath: string];
        let manager: id = msg_send![class!(NSFileManager), defaultManager];
        let mut error: id = nil;
        let moved: BOOL = msg_send![manager,
            trashItemAtURL: url resultingItemURL: nil error: &mut error
        ];
        let message = if moved == YES {
            None
        } else if error != nil {
            let description: id = msg_send![error, localizedDescription];
            let utf8: *const std::os::raw::c_char = msg_send![description, UTF8String];
            Some(if utf8.is_null() {
                "The file could not be moved to the Trash.".to_owned()
            } else {
                std::ffi::CStr::from_ptr(utf8)
                    .to_string_lossy()
                    .into_owned()
            })
        } else {
            Some("The file could not be moved to the Trash.".to_owned())
        };
        let _: () = msg_send![string, release];
        let _: () = msg_send![pool, drain];
        message.map_or(Ok(()), |message| Err(std::io::Error::other(message)))
    }
}

/// Without a system Trash (and in tests): keep the file, under the state
/// directory's "Deleted Chats" folder, never removing it.
#[cfg(any(not(target_os = "macos"), test))]
fn move_to_trash(path: &Path, fallback: Option<&Path>) -> std::io::Result<()> {
    let directory = fallback.ok_or_else(|| std::io::Error::other("No folder for deleted chats"))?;
    std::fs::create_dir_all(directory)?;
    let name = path
        .file_name()
        .ok_or_else(|| std::io::Error::other("The file has no name"))?;
    let mut target = directory.join(name);
    let mut copy = 1;
    while target.exists() {
        copy += 1;
        target = directory.join(format!("{} {copy}", name.to_string_lossy()));
    }
    std::fs::rename(path, target)
}

#[cfg(test)]
#[path = "sidebar_chat_delete_tests.rs"]
mod tests;
