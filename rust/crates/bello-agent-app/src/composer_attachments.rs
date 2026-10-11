//! Picker-selected images belong to the originating chat and runtime, even if
//! navigation changes while the platform chooser or file inspection is pending.
//! GPUI's generic chooser has no image filter or owning-window sheet contract;
//! signatures and limits are therefore checked after selection, off the UI thread.
use crate::AgentView;
use bello_agent_core::{
    Controller, Message,
    attachments::{self, AttachmentRecord},
};
use gpui::{prelude::*, *};
use std::{
    borrow::Cow,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, Weak},
};

#[derive(Clone)]
pub(crate) struct PickerOperation {
    token: uuid::Uuid,
    chat: String,
}

/// A rendered chip acts on its exact source, never a later selected chat,
/// replacement runtime, rebound window, or same-ID record with changed metadata.
#[derive(Clone)]
struct AttachmentTarget {
    project: PathBuf,
    workspace: Weak<Mutex<bello_agent_core::workspace::WorkspaceStore>>,
    window: Option<crate::workspace_lifetime::WindowBinding>,
    chat: String,
    controller: Weak<Controller>,
    attachment: AttachmentRecord,
}

/// Let the URL library encode local paths. Never interpolate a filename into a
/// URI or a shell command; reserved bytes and Unicode must round-trip exactly.
fn attachment_file_url(path: &str) -> Option<gpui::http_client::Url> {
    let path = Path::new(path);
    if !path.is_absolute() || path.as_os_str().as_encoded_bytes().contains(&0) {
        return None;
    }
    let url = gpui::http_client::Url::from_file_path(path).ok()?;
    (url.scheme() == "file"
        && url.host_str().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && url.to_file_path().ok().as_deref() == Some(path))
    .then_some(url)
}

/// Labels are presentation only. Ordinary Copy still reads Message.text and
/// never serializes retained content or the attachment paths.
pub(crate) fn input_label(text: &str, images: usize) -> Cow<'_, str> {
    if text.is_empty() && images != 0 {
        Cow::Owned(if images == 1 {
            "Image".into()
        } else {
            format!("{images} images")
        })
    } else {
        Cow::Borrowed(text)
    }
}
pub(crate) fn message_label(message: &Message) -> Cow<'_, str> {
    if message.text.is_empty() && message.state == "streaming" {
        Cow::Borrowed("Generating response…")
    } else {
        crate::composer_skills::input_label(
            &message.text,
            message
                .user_content
                .as_ref()
                .map_or(0, |content| content.attachments.len()),
            message
                .user_content
                .as_ref()
                .into_iter()
                .flat_map(|content| content.skills.iter().map(|s| s.name.as_str())),
        )
    }
}

/// A tooltip of plain text: an image's path, a notice in full.
pub(crate) struct TextHint {
    pub(crate) text: String,
    pub(crate) palette: crate::Palette,
}
impl Render for TextHint {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .max_w(px(480.))
            .px(px(8.))
            .py(px(5.))
            .rounded(px(6.))
            .bg(rgb(self.palette.surface))
            .text_color(rgb(self.palette.ink))
            .text_size(px(12.))
            .child(self.text.clone())
    }
}

/// The shown chat's passive model listing, as Swift's model pill lists when a
/// chat appears or its catalog source changes: once per installed runtime or
/// configuration, again after saved connections change (a followed source may
/// have a new URL or key), and only when its saved native connection uses a
/// custom catalog that is not fresh. The list it loads tells the composer
/// whether the chat's model takes images. Nothing is saved and no turn is
/// sent. A listing is shared by every chat on its source, so switching chats
/// never cancels one; closing the view does.
#[derive(Default)]
pub(crate) struct ChatModelListing {
    controller: Option<Weak<Controller>>,
    configuration: Option<Weak<bello_agent_core::runtime::Configuration>>,
    revision: Option<i64>,
    cancel: bello_agent_core::model_catalog::CancellationToken,
}
impl Drop for ChatModelListing {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

impl AgentView {
    pub(crate) fn list_chat_models(&mut self, cx: &mut Context<Self>) {
        if self.shutting_down {
            self.chat_models = Default::default();
            return;
        }
        let controller = self.controller.clone();
        let configuration = controller.configuration();
        let revision = self.connections.saved_revision();
        let listing = &mut self.chat_models;
        let same_controller = listing
            .controller
            .as_ref()
            .is_some_and(|listed| std::ptr::eq(listed.as_ptr(), Arc::as_ptr(&controller)));
        let same_configuration = match (&listing.configuration, &configuration) {
            (Some(listed), Some(current)) => std::ptr::eq(listed.as_ptr(), Arc::as_ptr(current)),
            (None, None) => true,
            _ => false,
        };
        let revised = revision.is_some() && revision != listing.revision;
        if revision.is_some() {
            listing.revision = revision;
        }
        if same_controller && same_configuration && !revised {
            return;
        }
        listing.controller = Some(Arc::downgrade(&controller));
        listing.configuration = configuration.as_ref().map(Arc::downgrade);
        // Each chat remembers the saved revision it resolved its source at, so
        // a source changed while this chat was hidden is resolved again when
        // it shows. Otherwise a fresh or bundled source is settled without
        // leaving the UI thread.
        if configuration.is_none() || !controller.model_catalog_stale(revision) {
            return;
        }
        let cancel = listing.cancel.clone();
        cx.spawn(async move |view, cx| {
            // Resolving reads the vault (a same-origin key): off the UI thread.
            let request = cx
                .background_executor()
                .spawn(async move { controller.model_catalog_request(revision) })
                .await;
            if let Some(request) = request {
                let _ = request.load(cancel).await;
            }
            // Resolving alone can rebind the source to a list already held.
            let _ = view.update(cx, |_, cx| cx.notify());
        })
        .detach();
    }
    pub(crate) fn picker_owns_chat(&self, chat: &str) -> bool {
        self.attachment_picker
            .as_ref()
            .is_some_and(|picker| picker.chat == chat)
    }
    pub(crate) fn can_attach_images(&self) -> bool {
        !self.shutting_down
            && !self.close_ready
            && !self.loading
            && !self.load_failed
            && !self.actor_mutation_blocked(&self.record.id)
            && self.attachment_picker.is_none()
            && self.editing.is_none()
            && self.session.edit.is_none()
            && self.retained_edit.is_none()
            && self.begin_operation.is_none()
            && self.cancel_operation.is_none()
            && !self.edit_recovery.blocked
            && (!self.busy || self.inflight_submission.is_some())
            && self
                .controller
                .supports_image_attachments_for(&self.chat_model_choice())
    }
    pub(crate) fn held_input_has_images(&self) -> bool {
        self.editing.is_some()
            && self.queued_turn_id.as_ref().is_some_and(|id| {
                self.session
                    .pending
                    .iter()
                    .any(|item| &item.id == id && !item.attachments.is_empty())
            })
    }
    pub(crate) fn composer_has_input(&self, cx: &App) -> bool {
        !self.composer.read(cx).text().trim().is_empty()
            || if self.editing.is_some() {
                self.held_input_has_images() || self.held_input_has_skills()
            } else {
                !self.attachments.is_empty() || !self.skills.is_empty()
            }
    }
    pub(crate) fn choose_images(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        if !self.can_attach_images() {
            return;
        }
        let token = uuid::Uuid::new_v4();
        let chat = self.record.id.clone();
        self.attachment_picker = Some(PickerOperation {
            token,
            chat: chat.clone(),
        });
        let source = Arc::downgrade(&self.controller);
        let binding = self.window_binding;
        let project = self.project.clone();
        let chooser = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: true,
            prompt: Some("Choose PNG, JPEG, GIF or WebP images".into()),
        });
        cx.spawn(async move |owner, cx| {
            let result = match chooser.await {
                Ok(Ok(Some(paths))) => {
                    cx.background_executor()
                        .spawn(async move {
                            if paths.len() > attachments::MAX_ATTACHMENTS {
                                return Err(
                                    "A submission supports four images and 16 MiB in total"
                                        .to_owned(),
                                );
                            }
                            paths
                                .iter()
                                .map(|path| {
                                    AttachmentRecord::inspect(path).map_err(|e| e.to_string())
                                })
                                .collect::<Result<Vec<_>, _>>()
                        })
                        .await
                }
                Ok(Ok(None)) => Ok(Vec::new()),
                Ok(Err(error)) => Err(format!("The image chooser could not be opened: {error:#}")),
                Err(error) => Err(format!("The image chooser was interrupted: {error}")),
            };
            let _ = owner.update(cx, |view, cx| {
                view.finish_image_picker(token, binding, &project, &chat, &source, result, cx);
            });
        })
        .detach();
        cx.notify();
    }
    #[allow(clippy::too_many_arguments)]
    fn finish_image_picker(
        &mut self,
        token: uuid::Uuid,
        binding: Option<crate::workspace_lifetime::WindowBinding>,
        project: &std::path::Path,
        chat: &str,
        source: &Weak<Controller>,
        result: Result<Vec<AttachmentRecord>, String>,
        cx: &mut Context<Self>,
    ) {
        if self
            .attachment_picker
            .as_ref()
            .is_none_or(|picker| picker.token != token || picker.chat != chat)
        {
            return;
        }
        self.attachment_picker = None;
        cx.notify();
        if self.shutting_down
            || self.close_ready
            || self.window_binding != binding
            || self.project != project
        {
            return;
        }
        self.receive_images(chat, source, result, cx);
    }
    pub(crate) fn receive_images(
        &mut self,
        id: &str,
        source: &Weak<Controller>,
        result: Result<Vec<AttachmentRecord>, String>,
        cx: &mut Context<Self>,
    ) {
        if self.shutting_down || self.close_ready || self.actor_mutation_blocked(id) {
            return;
        }
        let Some(chat) = self.chat_mut(id).filter(|chat| {
            source.ptr_eq(&Arc::downgrade(&chat.controller)) && !chat.loading && !chat.load_failed
        }) else {
            return;
        };
        let items = match result {
            Ok(items) => items,
            Err(error) => {
                chat.error = Some(error);
                cx.notify();
                return;
            }
        };
        // Cancelling a chooser does not touch the current draft or its error.
        if items.is_empty() {
            return;
        }
        if !chat.controller.supports_image_attachments() {
            chat.error = Some(attachments::IMAGES_UNSUPPORTED.into());
            cx.notify();
            return;
        }
        let target = if chat.editing.is_some() {
            &mut chat.draft_before_edit_attachments
        } else {
            &mut chat.attachments
        };
        let mut next = target.clone();
        next.extend(items);
        if let Err(error) = attachments::validate_selection(&next) {
            chat.error = Some(error.to_string());
            cx.notify();
            return;
        }
        if chat.draft_revision == u64::MAX {
            chat.error =
                Some("Draft revision limit reached; existing images are preserved.".into());
            cx.notify();
            return;
        }
        *target = next;
        self.draft_changed(id, cx);
        cx.notify();
    }
    pub(crate) fn remove_attachment(
        &mut self,
        chat: &str,
        source: &Weak<Controller>,
        attachment: &str,
        cx: &mut Context<Self>,
    ) {
        if self.shutting_down || self.close_ready || self.actor_mutation_blocked(chat) {
            return;
        }
        let Some(target) = self.chat_mut(chat).filter(|chat| {
            source.ptr_eq(&Arc::downgrade(&chat.controller))
                && chat.editing.is_none()
                && (!chat.busy || chat.inflight_submission.is_some())
        }) else {
            return;
        };
        if target.draft_revision == u64::MAX {
            target.error =
                Some("Draft revision limit reached; existing images are preserved.".into());
            cx.notify();
            return;
        }
        let previous = target.attachments.len();
        target.attachments.retain(|record| record.id != attachment);
        if previous != target.attachments.len() {
            self.draft_changed(chat, cx);
            cx.notify();
        }
    }
    fn attachment_target(&self, attachment: &AttachmentRecord) -> AttachmentTarget {
        AttachmentTarget {
            project: self.project.clone(),
            workspace: Arc::downgrade(&self.workspace),
            window: self.window_binding,
            chat: self.record.id.clone(),
            controller: Arc::downgrade(&self.controller),
            attachment: attachment.clone(),
        }
    }
    fn attachment_target_matches(&self, target: &AttachmentTarget) -> bool {
        !self.shutting_down
            && !self.close_ready
            && !self.loading
            && target.window.is_some()
            && target.window == self.window_binding
            && target.project == self.project
            && target.workspace.ptr_eq(&Arc::downgrade(&self.workspace))
            && target.chat == self.record.id
            && target.controller.ptr_eq(&Arc::downgrade(&self.controller))
            && self
                .attachments
                .iter()
                .any(|record| record == &target.attachment)
    }
    fn open_attachment(&mut self, target: &AttachmentTarget, cx: &mut Context<Self>) -> bool {
        if !self.attachment_target_matches(target) {
            return false;
        }
        let Some(url) = target
            .attachment
            .validate()
            .ok()
            .and_then(|()| attachment_file_url(&target.attachment.path))
        else {
            self.error = Some("The selected image path cannot be opened.".into());
            cx.notify();
            return false;
        };
        cx.open_url(url.as_str());
        true
    }
    fn remove_presented_attachment(&mut self, target: &AttachmentTarget, cx: &mut Context<Self>) {
        if !self.attachment_target_matches(target) {
            return;
        }
        self.remove_attachment(&target.chat, &target.controller, &target.attachment.id, cx);
    }
    pub(crate) fn attachment_chips(&self, cx: &Context<Self>) -> Div {
        let mut row = div().flex().flex_wrap().gap(px(6.)).px(px(12.)).pt(px(8.));
        for record in &self.attachments {
            let open = self.attachment_target(record);
            let remove = open.clone();
            let p = self.palette;
            let path = record.path.clone();
            row = row.child(
                div()
                    .id(SharedString::from(format!("image-chip-{}", record.id)))
                    .debug_selector({
                        let id = record.id.clone();
                        move || format!("image-chip-{id}")
                    })
                    .flex()
                    .items_center()
                    .gap(px(5.))
                    .px(px(7.))
                    .py(px(4.))
                    .rounded(px(7.))
                    .bg(p.fill())
                    .text_size(px(12.))
                    .max_w(px(240.))
                    .cursor_pointer()
                    .on_click(cx.listener(move |view, _, _, cx| {
                        view.open_attachment(&open, cx);
                    }))
                    .tooltip(move |_, cx| {
                        cx.new(|_| TextHint {
                            text: path.clone(),
                            palette: p,
                        })
                        .into()
                    })
                    .child(self.icon("photo", 12.))
                    .child(div().truncate().child(record.filename().to_owned()))
                    .child(
                        div()
                            .id(SharedString::from(format!("remove-image-{}", record.id)))
                            .debug_selector({
                                let id = record.id.clone();
                                move || format!("remove-image-{id}")
                            })
                            .cursor_pointer()
                            .px(px(3.))
                            .child("×")
                            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                            .on_click(cx.listener(move |view, _, _, cx| {
                                cx.stop_propagation();
                                view.remove_presented_attachment(&remove, cx);
                            })),
                    ),
            );
        }
        row
    }
}

#[cfg(test)]
#[path = "composer_attachments_tests.rs"]
mod tests;
