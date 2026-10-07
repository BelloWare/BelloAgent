//! Bounded Next request reader from MetricsFooter / SessionInspectorWindow /
//! InspectorNextRequestPage / PagedTextView.swift. This is a prepared request,
//! not captured HTTP, a token estimate, or the source's full request archive.
use crate::{AgentView, Palette, current_palette, workspace_lifetime::WindowBinding};
use bello_agent_core::{
    Controller,
    runtime::{ContextPreview, ContextPreviewMetadata, ContextPreviewMode},
    workspace::WorkspaceStore,
};
use bello_workbench_ui::{EditorAppearance, EditorView};
use gpui::{prelude::*, *};
use std::{
    ops::Range,
    path::PathBuf,
    sync::{Arc, Mutex, Weak},
};

const DEFAULT_SIZE: (f32, f32) = (1120., 820.);
const MINIMUM_SIZE: (f32, f32) = (700., 520.);
const PAGE_BYTES: usize = 64 * 1024;
const CHANGED: &str =
    "The conversation or draft changed. Prepare it again to see the current request.";
const COUNT_UNAVAILABLE: &str = "Token count unavailable · context occupancy unavailable";

/// Captured by the footer, never reconstructed from the selected chat when its
/// callback runs. Weak runtime/storage references cannot prolong writer locks.
#[derive(Clone)]
pub(crate) struct ContextInspectorTarget {
    project: PathBuf,
    workspace: Weak<Mutex<WorkspaceStore>>,
    window: Option<WindowBinding>,
    chat: String,
    controller: Weak<Controller>,
}

impl ContextInspectorTarget {
    fn same_scope(&self, other: &Self) -> bool {
        self.project == other.project
            && self.workspace.ptr_eq(&other.workspace)
            && self.window == other.window
            && self.chat == other.chat
            && self.controller.ptr_eq(&other.controller)
    }

    fn matches(&self, owner: &AgentView) -> bool {
        !owner.shutting_down
            && !owner.close_ready
            && self.window.is_some()
            && owner.window_binding == self.window
            && owner.project == self.project
            && self.workspace.ptr_eq(&Arc::downgrade(&owner.workspace))
            && owner.chat_ref(&self.chat).is_some_and(|chat| {
                self.controller.ptr_eq(&Arc::downgrade(&chat.controller))
                    && chat.session.id == self.chat
                    && !chat.controller.is_retired()
            })
    }

    fn input(&self, owner: &AgentView, cx: &App) -> Result<PreviewInput, String> {
        if !self.matches(owner) {
            return Err("This chat's workspace or runtime is no longer available.".into());
        }
        let chat = owner.chat_ref(&self.chat).expect("matched chat");
        if chat.loading || chat.load_failed {
            return Err(
                "Wait for the chat to finish loading before inspecting its context.".into(),
            );
        }
        if chat.editing.is_some()
            || chat.retained_edit.is_some()
            || chat.begin_operation.is_some()
            || chat.cancel_operation.is_some()
            || chat.session.edit.is_some()
        {
            return Err(
                "Save or cancel the message you are rewriting before previewing context.".into(),
            );
        }
        if chat.busy || chat.inflight_submission.is_some() {
            return Err("Wait for the chat operation to finish before previewing context.".into());
        }
        Ok(PreviewInput {
            controller: chat.controller.clone(),
            draft: chat.composer.read(cx).text().to_owned(),
            attachments: chat.attachments.clone(),
            skills: chat
                .skills
                .iter()
                .map(|chip| chip.selection.clone())
                .collect(),
            draft_revision: chat.draft_revision,
        })
    }
}

pub(crate) struct InspectorWindow {
    target: ContextInspectorTarget,
    handle: WindowHandle<ContextInspector>,
}

impl AgentView {
    pub(crate) fn context_inspector_target(&self) -> ContextInspectorTarget {
        ContextInspectorTarget {
            project: self.project.clone(),
            workspace: Arc::downgrade(&self.workspace),
            window: self.window_binding,
            chat: self.record.id.clone(),
            controller: Arc::downgrade(&self.controller),
        }
    }

    pub(crate) fn open_context_inspector(
        &mut self,
        target: &ContextInspectorTarget,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !target.matches(self)
            || self.close_dialog
            || self.quick_open.read(cx).is_open()
            || self.projects.view.read(cx).is_open()
        {
            return;
        }
        self.inspector_windows.retain(|entry| {
            cx.windows()
                .iter()
                .any(|window| window.window_id() == entry.handle.window_id())
        });
        if let Some(entry) = self
            .inspector_windows
            .iter()
            .find(|entry| entry.target.same_scope(target))
        {
            let _ = entry
                .handle
                .update(cx, |_, window, _| window.activate_window());
            return;
        }
        let title = self
            .chat_ref(&target.chat)
            .expect("matched chat")
            .record
            .title
            .clone();
        let owner = cx.weak_entity();
        let scope = target.clone();
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                None,
                size(px(DEFAULT_SIZE.0), px(DEFAULT_SIZE.1)),
                cx,
            ))),
            window_min_size: Some(size(px(MINIMUM_SIZE.0), px(MINIMUM_SIZE.1))),
            ..Default::default()
        };
        match cx.open_window(options, move |window, cx| {
            cx.new(|cx| ContextInspector::new(owner, scope, title, window, cx))
        }) {
            Ok(handle) => self.inspector_windows.push(InspectorWindow {
                target: target.clone(),
                handle,
            }),
            Err(error) => {
                self.error = Some(format!(
                    "The Session Inspector could not be opened: {error}"
                ));
                cx.notify();
            }
        }
    }

    /// Called before the owner is rebound or successfully closed. Removing
    /// inspector windows must never reactivate or refocus the workspace.
    pub(crate) fn close_context_inspectors(&mut self, cx: &mut Context<Self>) {
        for entry in std::mem::take(&mut self.inspector_windows) {
            let _ = entry
                .handle
                .update(cx, |view, window, cx| view.close(window, cx));
        }
    }
}

struct PreviewInput {
    controller: Arc<Controller>,
    draft: String,
    attachments: Vec<bello_agent_core::attachments::AttachmentRecord>,
    skills: Vec<bello_agent_core::skills::SkillSelection>,
    draft_revision: u64,
}

struct PreparedDocument {
    preview: ContextPreview,
    pages: Vec<Range<usize>>,
}

impl PreparedDocument {
    fn new(preview: ContextPreview) -> Self {
        let pages = page_ranges(preview.request_json());
        Self { preview, pages }
    }
}

/// Only bounded page text enters the editor. UTF-8 boundaries preserve exact
/// reconstruction; the full immutable body is separately available to Copy.
fn page_ranges(text: &str) -> Vec<Range<usize>> {
    let mut pages = Vec::new();
    let mut start = 0;
    while start < text.len() {
        let mut end = (start + PAGE_BYTES).min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        pages.push(start..end);
        start = end;
    }
    if pages.is_empty() {
        pages.push(0..0);
    }
    pages
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Control {
    Refresh,
    Copy,
    Previous,
    Next,
    Close,
}

pub(crate) struct ContextInspector {
    owner: WeakEntity<AgentView>,
    target: ContextInspectorTarget,
    title: String,
    reader: Entity<EditorView>,
    palette: Palette,
    controls: Vec<(Control, FocusHandle)>,
    document: Option<Arc<PreparedDocument>>,
    draft: String,
    attachments: Vec<bello_agent_core::attachments::AttachmentRecord>,
    skills: Vec<bello_agent_core::skills::SkillSelection>,
    draft_revision: u64,
    page: usize,
    generation: uuid::Uuid,
    loading: bool,
    copying: bool,
    closed: bool,
    notice: Option<String>,
    task: Option<Task<()>>,
    copy_task: Option<Task<()>>,
    _observations: Vec<Subscription>,
}

impl ContextInspector {
    fn new(
        owner: WeakEntity<AgentView>,
        target: ContextInspectorTarget,
        title: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        window.set_window_title(&format!("{title} — Session Inspector"));
        let palette = current_palette(window);
        let reader = cx.new(|cx| {
            let mut reader = EditorView::new(String::new(), window, cx);
            reader.set_appearance(Self::appearance(palette), cx);
            reader.set_read_only(true, cx);
            reader
        });
        reader.read(cx).focus(window);
        let mut observations = Vec::new();
        if let Some(entity) = owner.upgrade() {
            observations.push(cx.observe_in(&entity, window, |view, _, window, cx| {
                view.owner_changed(window, cx);
            }));
            observations.push(
                cx.observe_release_in(&entity, window, |view, _, window, cx| {
                    view.close(window, cx);
                }),
            );
        }
        let weak = cx.weak_entity();
        window.on_window_should_close(cx, move |_, cx| {
            let _ = weak.update(cx, |view, cx| view.clear(cx));
            true
        });
        // The owner's entity is borrowed while creating this window. Defer its
        // first read until that borrow ends; no composer focus callback follows.
        cx.defer_in(window, |view, _, cx| view.refresh(cx));
        let controls = [
            Control::Refresh,
            Control::Copy,
            Control::Previous,
            Control::Next,
            Control::Close,
        ]
        .into_iter()
        .map(|control| (control, cx.focus_handle()))
        .collect();
        Self {
            owner,
            target,
            title,
            reader,
            palette,
            controls,
            document: None,
            draft: String::new(),
            attachments: Vec::new(),
            skills: Vec::new(),
            draft_revision: 0,
            page: 0,
            generation: uuid::Uuid::new_v4(),
            loading: false,
            copying: false,
            closed: false,
            notice: None,
            task: None,
            copy_task: None,
            _observations: observations,
        }
    }

    fn appearance(p: Palette) -> EditorAppearance {
        EditorAppearance {
            font_size: 12.,
            line_height: 18.,
            padding_x: 12.,
            padding_y: 12.,
            text: rgb(p.ink).into(),
            selection: p.accent_soft(),
            caret: rgb(p.accent).into(),
            ..EditorAppearance::plain()
        }
    }

    fn input(&self, cx: &App) -> Result<PreviewInput, String> {
        let owner = self
            .owner
            .upgrade()
            .ok_or("This chat's workspace is no longer available.")?;
        self.target.input(owner.read(cx), cx)
    }

    fn refresh(&mut self, cx: &mut Context<Self>) {
        if self.closed {
            return;
        }
        self.generation = uuid::Uuid::new_v4();
        self.task = None;
        self.copy_task = None;
        self.copying = false;
        self.document = None;
        self.page = 0;
        self.reader
            .update(cx, |reader, cx| reader.set_text(String::new(), cx));
        let input = match self.input(cx) {
            Ok(input) => input,
            Err(error) => {
                self.loading = false;
                self.notice = Some(error);
                cx.notify();
                return;
            }
        };
        let generation = self.generation;
        self.draft = input.draft.clone();
        self.attachments = input.attachments.clone();
        self.skills = input.skills.clone();
        self.draft_revision = input.draft_revision;
        self.loading = true;
        self.notice = None;
        let task = cx.background_executor().spawn(async move {
            input
                .controller
                .prepare_context_with_inputs(&input.draft, &input.attachments, &input.skills)
                .await
                .map(PreparedDocument::new)
                .map(Arc::new)
                .map_err(|error| error.to_string())
        });
        self.task = Some(cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| view.install(generation, result, cx));
        }));
        cx.notify();
    }

    fn current(&self, document: &PreparedDocument, cx: &App) -> Result<bool, String> {
        let input = self.input(cx)?;
        if input.draft != self.draft
            || input.attachments != self.attachments
            || input.skills != self.skills
            || input.draft_revision != self.draft_revision
        {
            return Ok(false);
        }
        input
            .controller
            .context_preview_current(&document.preview)
            .map_err(|error| error.to_string())
    }

    fn install(
        &mut self,
        generation: uuid::Uuid,
        result: Result<Arc<PreparedDocument>, String>,
        cx: &mut Context<Self>,
    ) {
        if self.closed || self.generation != generation {
            return;
        }
        self.loading = false;
        match result {
            Ok(document) => match self.current(&document, cx) {
                Ok(true) => {
                    self.document = Some(document);
                    self.notice = None;
                    self.show_page(0, cx);
                }
                Ok(false) => self.notice = Some(CHANGED.into()),
                Err(error) => self.notice = Some(error),
            },
            Err(error) => self.notice = Some(error),
        }
        cx.notify();
    }

    fn owner_changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.closed {
            return;
        }
        let Some(owner) = self.owner.upgrade() else {
            self.close(window, cx);
            return;
        };
        if !self.target.matches(owner.read(cx)) {
            self.close(window, cx);
            return;
        }
        let title = owner
            .read(cx)
            .chat_ref(&self.target.chat)
            .expect("matched chat")
            .record
            .title
            .clone();
        if self.title != title {
            window.set_window_title(&format!("{title} — Session Inspector"));
            self.title = title;
            cx.notify();
        }
        if let Some(document) = &self.document {
            // Source NextRequestModel retains the prepared document until an
            // explicit refresh/close. Later typing preserves selection/scroll;
            // temporary actor contention is not evidence of changed input.
            let notice = match self.current(document, cx) {
                Ok(true) => None,
                Ok(false) => Some(format!("Showing the captured snapshot. {CHANGED}")),
                Err(error) => Some(format!("Showing the captured snapshot. {error}")),
            };
            if self.notice != notice {
                self.notice = notice;
                cx.notify();
            }
        }
    }

    fn show_page(&mut self, page: usize, cx: &mut Context<Self>) {
        let Some(document) = &self.document else {
            return;
        };
        let Some(range) = document.pages.get(page) else {
            return;
        };
        let text = document.preview.request_json()[range.clone()].to_owned();
        self.page = page;
        self.reader
            .update(cx, |reader, cx| reader.set_text(text, cx));
        cx.notify();
    }

    fn copy_request(&mut self, cx: &mut Context<Self>) {
        if self.closed || self.copying || !self.owner_matches(cx) {
            return;
        }
        let Some(document) = self.document.as_ref().cloned() else {
            return;
        };
        self.copying = true;
        let generation = self.generation;
        let task = cx
            .background_executor()
            .spawn(async move { document.preview.request_json().to_owned() });
        self.copy_task = Some(cx.spawn(async move |view, cx| {
            let text = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.closed || view.generation != generation {
                    return;
                }
                view.copying = false;
                if view.document.is_some() && view.owner_matches(cx) {
                    cx.write_to_clipboard(ClipboardItem::new_string(text));
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    fn owner_matches(&self, cx: &App) -> bool {
        self.owner
            .upgrade()
            .is_some_and(|owner| self.target.matches(owner.read(cx)))
    }

    fn clear(&mut self, cx: &mut Context<Self>) {
        self.closed = true;
        self.generation = uuid::Uuid::new_v4();
        self.task = None;
        self.copy_task = None;
        self.document = None;
        self.draft.clear();
        self.attachments.clear();
        self.skills.clear();
        self.loading = false;
        self.copying = false;
        self.reader
            .update(cx, |reader, cx| reader.set_text(String::new(), cx));
    }

    fn close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.clear(cx);
        window.remove_window();
    }

    fn enabled(&self, control: Control) -> bool {
        !self.closed
            && match control {
                Control::Refresh | Control::Close => true,
                Control::Copy => self.document.is_some() && !self.copying,
                Control::Previous => self.document.is_some() && self.page > 0,
                Control::Next => self
                    .document
                    .as_ref()
                    .is_some_and(|document| self.page + 1 < document.pages.len()),
            }
    }

    fn activate(
        &mut self,
        control: Control,
        generation: uuid::Uuid,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.generation != generation || !self.enabled(control) {
            return;
        }
        match control {
            Control::Refresh => self.refresh(cx),
            Control::Copy => self.copy_request(cx),
            Control::Previous => self.show_page(self.page.saturating_sub(1), cx),
            Control::Next => self.show_page(self.page + 1, cx),
            Control::Close => self.close(window, cx),
        }
    }

    fn key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let key = &event.keystroke;
        let command =
            key.modifiers.platform || (cfg!(target_os = "linux") && key.modifiers.control);
        if command && key.key == "w" {
            self.close(window, cx);
            cx.stop_propagation();
            return;
        }
        if key.key == "tab" && !command && !key.modifiers.alt {
            let mut focuses: Vec<_> = self
                .controls
                .iter()
                .filter(|(control, _)| self.enabled(*control))
                .map(|(_, focus)| focus.clone())
                .collect();
            focuses.push(self.reader.read(cx).focus_handle(cx));
            let current = focuses.iter().position(|focus| focus.is_focused(window));
            let index = match current {
                Some(index) if key.modifiers.shift => (index + focuses.len() - 1) % focuses.len(),
                Some(index) => (index + 1) % focuses.len(),
                None if key.modifiers.shift => focuses.len() - 1,
                None => 0,
            };
            focuses[index].focus(window);
            cx.stop_propagation();
        } else if !command
            && !key.modifiers.alt
            && matches!(key.key.as_str(), "enter" | "space")
            && let Some(control) = self
                .controls
                .iter()
                .find(|(_, focus)| focus.is_focused(window))
                .map(|(control, _)| *control)
        {
            if !event.is_held {
                self.activate(control, self.generation, window, cx);
            }
            cx.stop_propagation();
        }
    }

    fn button(
        &self,
        control: Control,
        id: &'static str,
        label: &'static str,
        cx: &Context<Self>,
    ) -> Stateful<Div> {
        let p = self.palette;
        let enabled = self.enabled(control);
        let focus = &self
            .controls
            .iter()
            .find(|(value, _)| *value == control)
            .expect("control")
            .1;
        let generation = self.generation;
        div()
            .id(id)
            .debug_selector(move || id.into())
            .px(px(10.))
            .py(px(5.))
            .rounded(px(7.))
            .border_1()
            .border_color(p.hairline())
            .text_size(px(12.))
            .flex_shrink_0()
            .child(label)
            .when(!enabled, |button| button.opacity(0.45))
            .when(enabled, |button| {
                button
                    .track_focus(focus)
                    .tab_index(0)
                    .cursor_pointer()
                    .hover(|style| style.bg(p.accent_soft()))
                    .focus(|style| style.border_color(rgb(p.accent)))
            })
            .on_click(cx.listener(move |view, _, window, cx| {
                view.activate(control, generation, window, cx)
            }))
    }
}

fn summary(metadata: &ContextPreviewMetadata) -> Vec<String> {
    vec![
        COUNT_UNAVAILABLE.into(),
        format!(
            "Model: {} · Reasoning: {}",
            metadata.model, metadata.thinking_level
        ),
        format!(
            "Configured context limit: {} · Output budget: {}",
            metadata.context_window, metadata.output_budget
        ),
        if metadata.mode == ContextPreviewMode::ActiveContext {
            format!(
                "Active context · draft excluded · {} queued message(s) excluded at preparation",
                metadata.queue_count
            )
        } else {
            format!(
                "{} · {} queued message(s) excluded at preparation",
                if metadata.draft_included {
                    "Draft included"
                } else {
                    "No draft included"
                },
                metadata.queue_count
            )
        },
    ]
}

impl Render for ContextInspector {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = current_palette(window);
        if p != self.palette {
            self.palette = p;
            self.reader.update(cx, |reader, cx| {
                reader.set_appearance(Self::appearance(p), cx)
            });
        }
        let metadata = self
            .document
            .as_ref()
            .map(|document| document.preview.metadata());
        let active =
            metadata.is_some_and(|metadata| metadata.mode == ContextPreviewMode::ActiveContext);
        let mut header = div()
            .flex_shrink_0()
            .px(px(24.))
            .py(px(16.))
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(
                div()
                    .text_size(px(20.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(if active {
                        "Active context"
                    } else {
                        "Next request"
                    }),
            )
            .child(
                div()
                    .text_size(px(13.))
                    .text_color(rgb(p.secondary))
                    .child("Prepared request snapshot. Nothing is sent to the model."),
            );
        if let Some(metadata) = metadata {
            let mut metrics = div()
                .p(px(12.))
                .rounded(px(8.))
                .bg(rgb(p.surface))
                .border_1()
                .border_color(p.hairline())
                .text_size(px(12.))
                .text_color(rgb(p.secondary))
                .flex()
                .flex_col()
                .gap(px(3.));
            for line in summary(metadata) {
                metrics = metrics.child(line);
            }
            if metadata.credentials_redacted {
                metrics = metrics.child("Configured credentials are redacted from this preview.");
            }
            header = header.child(metrics);
        }
        let page_label = self
            .document
            .as_ref()
            .map(|document| {
                let range = &document.pages[self.page];
                format!(
                    "Page {} of {} · bytes {}–{} of {}",
                    self.page + 1,
                    document.pages.len(),
                    if range.is_empty() { 0 } else { range.start + 1 },
                    range.end,
                    document.preview.request_json().len()
                )
            })
            .unwrap_or_default();
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(rgb(p.content))
            .text_color(rgb(p.ink))
            .font_family(if cfg!(target_os = "macos") {
                ".SystemUIFont"
            } else {
                "DejaVu Sans"
            })
            .capture_key_down(cx.listener(Self::key))
            .child(
                div()
                    .h(px(48.))
                    .flex_shrink_0()
                    .px(px(24.))
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(px(14.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(format!("Session Inspector · {}", self.title)),
                    )
                    .child(self.button(
                        Control::Refresh,
                        "context-inspector-refresh",
                        "Prepare it again",
                        cx,
                    ))
                    .child(self.button(Control::Close, "context-inspector-close", "Close", cx)),
            )
            .child(header)
            .when(self.loading || self.notice.is_some(), |view| {
                view.child(
                    div()
                        .px(px(24.))
                        .py(px(8.))
                        .text_size(px(13.))
                        .text_color(rgb(p.secondary))
                        .child(
                            self.notice
                                .clone()
                                .unwrap_or_else(|| "Preparing the next request…".into()),
                        ),
                )
            })
            .child(
                div()
                    .flex_shrink_0()
                    .px(px(24.))
                    .pb(px(8.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(px(11.5))
                            .text_color(rgb(p.secondary))
                            .child(page_label),
                    )
                    .child(self.button(
                        Control::Previous,
                        "context-inspector-previous",
                        "Previous",
                        cx,
                    ))
                    .child(self.button(Control::Next, "context-inspector-next", "Next", cx))
                    .child(self.button(
                        Control::Copy,
                        "context-inspector-copy",
                        if self.copying {
                            "Copying…"
                        } else {
                            "Copy request"
                        },
                        cx,
                    )),
            )
            .child(
                div()
                    .debug_selector(|| "context-inspector-reader".into())
                    .flex_1()
                    .min_h_0()
                    .mx(px(24.))
                    .mb(px(16.))
                    .border_1()
                    .border_color(p.hairline())
                    .rounded(px(8.))
                    .overflow_hidden()
                    .child(self.reader.clone()),
            )
    }
}

#[cfg(test)]
#[path = "context_inspector_tests.rs"]
mod tests;
