mod assets;
mod chat;
mod chat_navigation;
mod file_tab;
mod layout;
mod queue_detail;
mod queue_presentation;
mod quick_open;
mod theme;
use bello_agent_core::workspace::{ChatRecord, DraftRecord, SubmissionIntent, WorkspaceStore};
use bello_agent_core::{Controller, Credential, Lane, Profile, RunState, SessionStore};
use bello_workbench_ui::{
    EditorAppearance, EditorView, WorkbenchAppearance, WorkbenchPanel, WorkbenchView,
};
use chat::ChatState;
use file_tab::{FileTabEvent, FileTabView};
use gpui::{prelude::*, *};
use quick_open::{QuickOpenEvent, QuickOpenView};
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    io::{Read, Write},
    ops::{Deref, DerefMut},
    path::PathBuf,
    sync::{Arc, Mutex, OnceLock},
    time::Instant,
};
use theme::Palette;

static START: OnceLock<Instant> = OnceLock::new();
static PERF: OnceLock<Option<Mutex<File>>> = OnceLock::new();
fn perf(event: &str, duration_us: u128) {
    if let Some(file) = PERF.get_or_init(|| {
        std::env::var_os("BELLO_PERF_LOG")
            .and_then(|path| OpenOptions::new().create(true).append(true).open(path).ok())
            .map(Mutex::new)
    }) && let Ok(mut file) = file.lock()
    {
        let _ = writeln!(
            file,
            "{}",
            serde_json::json!({"app":"bello-agent","event":event,"duration_us":duration_us,"elapsed_ms":START.get().map(|t|t.elapsed().as_secs_f64()*1000.0).unwrap_or(0.0),"measurement":"CPU callback; not presentation latency"})
        );
    }
}

// Process-local QA overrides. They do not change system or saved appearance.
fn current_palette(window: &Window) -> Palette {
    let appearance = match std::env::var("BELLO_TEST_APPEARANCE").ok().as_deref() {
        Some("dark") => WindowAppearance::Dark,
        Some("light") => WindowAppearance::Light,
        _ => window.appearance(),
    };
    Palette::for_appearance(appearance)
}
fn initial_size() -> Size<Pixels> {
    let requested = std::env::var("BELLO_TEST_WINDOW_SIZE").ok().and_then(|s| {
        s.split_once('x')
            .and_then(|(w, h)| Some((w.parse::<f32>().ok()?, h.parse::<f32>().ok()?)))
    });
    let (w, h) = requested
        .filter(|(w, h)| w.is_finite() && h.is_finite())
        .unwrap_or((1280., 840.));
    size(px(w.max(920.)), px(h.max(600.)))
}

struct FileEntry {
    id: u64,
    path: PathBuf,
    view: Entity<FileTabView>,
    dirty: bool,
    _events: Subscription,
}

struct LaunchState {
    controller: Arc<Controller>,
    project: PathBuf,
    workspace: Arc<Mutex<WorkspaceStore>>,
    record: ChatRecord,
    draft: DraftRecord,
    pending: bool,
}

struct AgentView {
    chat: ChatState,
    inactive: BTreeMap<String, ChatState>,
    records: Vec<ChatRecord>,
    workspace: Arc<Mutex<WorkspaceStore>>,
    selection_revision: u64,
    shutting_down: bool,
    close_ready: bool,
    chat_directory: PathBuf,
    unloaded_drafts: BTreeMap<String, DraftRecord>,
    recoveries: BTreeMap<String, SubmissionIntent>,
    palette: Palette,
    layout: layout::Layout,
    layout_store: Arc<layout::LayoutStore>,
    resizing: Option<bool>,
    pane_width: f32,
    pane_history: bool,
    changes_open: bool,
    files: Vec<FileEntry>,
    selected_file: Option<u64>,
    next_file_id: u64,
    quick_open: Entity<QuickOpenView>,
    _quick_events: Subscription,
    project: PathBuf,
    icon: Arc<Image>,
    filter: Entity<EditorView>,
    _editor_events: Vec<Subscription>,
    workbench: Entity<WorkbenchView>,
    show_files: bool,
    close_dialog: bool,
    _release: Subscription,
}
impl Deref for AgentView {
    type Target = ChatState;
    fn deref(&self) -> &Self::Target {
        &self.chat
    }
}
impl DerefMut for AgentView {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.chat
    }
}
impl AgentView {
    fn new(launch: LaunchState, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let LaunchState {
            controller,
            project,
            workspace,
            record,
            draft,
            pending,
        } = launch;
        let palette = current_palette(window);
        let state = workspace.lock().expect("workspace lock").snapshot();
        let chat_directory = workspace
            .lock()
            .expect("workspace lock")
            .chat_path(&record.id)
            .expect("valid chat id")
            .parent()
            .unwrap()
            .to_owned();
        let mut records = state.chats.clone();
        if !records.iter().any(|item| item.id == record.id) {
            records.insert(0, record.clone());
        }
        let layout_store = Arc::new(layout::LayoutStore::new(
            record.snapshot.parent().unwrap().join("layout.json"),
        ));
        let layout = layout_store.load();
        let chat = ChatState::new(controller, record, draft, pending, palette, window, cx);
        let filter = cx.new(|cx| {
            let mut view = EditorView::new(String::new(), window, cx);
            let mut style = Self::composer_style(palette);
            style.font_size = 13.;
            style.line_height = 19.;
            style.padding_x = 2.;
            style.padding_y = 4.;
            view.set_appearance(style, cx);
            view
        });
        let editor_events = vec![cx.subscribe(&filter, |_, _, _, cx| cx.notify())];
        let workbench = cx.new(|cx| WorkbenchView::new(project.clone(), window, cx));
        workbench.update(cx, |view, cx| {
            view.set_appearance(Self::workbench_style(palette), cx);
            view.set_panel(WorkbenchPanel::Changes, cx);
        });
        let quick_open = cx.new(|cx| QuickOpenView::new(project.clone(), palette, window, cx));
        let quick_events =
            cx.subscribe_in(
                &quick_open,
                window,
                |view, _, event, window, cx| match event {
                    QuickOpenEvent::Open { path, line } => {
                        view.open_file(path.clone(), *line, window, cx)
                    }
                    QuickOpenEvent::Dismissed => cx.notify(),
                },
            );
        let icon = Arc::new(Image::from_bytes(
            ImageFormat::Png,
            include_bytes!("../../../../assets/branding/bello-agent-icon-128.png").to_vec(),
        ));
        let release = cx.on_release(|view, _| {
            let _ = view.controller.stop();
            for chat in view.inactive.values() {
                let _ = chat.controller.stop();
            }
        });
        let weak = cx.weak_entity();
        window.on_window_should_close(cx, move |window, cx| {
            weak.update(cx, |view, cx| view.request_close(window, cx))
                .unwrap_or(true)
        });
        let initial_view = cx.weak_entity();
        cx.defer(move |cx| {
            let _ = initial_view.update(cx, |view, cx| {
                let id = view.record.id.clone();
                if view.controller.is_persistent() {
                    view.receive_snapshot(&id, view.session.clone(), cx);
                }
                view.reconcile_edit(&id, cx);
                view.reconcile_intents(&id, cx);
            });
        });
        // Match WorkspaceSelection's selected-chat composer focus. The source
        // Open File command is window-wide; it must work before any mouse click.
        chat.composer.read(cx).focus(window);
        Self {
            chat,
            inactive: BTreeMap::new(),
            records,
            chat_directory,
            unloaded_drafts: state.drafts,
            recoveries: state.intents,
            workspace,
            selection_revision: state.selection_revision,
            shutting_down: false,
            close_ready: false,
            palette,
            layout,
            layout_store,
            resizing: None,
            pane_width: 980.,
            pane_history: false,
            changes_open: false,
            files: Vec::new(),
            selected_file: None,
            next_file_id: 1,
            quick_open,
            _quick_events: quick_events,
            project,
            icon,
            filter,
            _editor_events: editor_events,
            workbench,
            show_files: false,
            close_dialog: false,
            _release: release,
        }
    }
    fn refresh(&mut self, cx: &mut Context<Self>) {
        self.last_revision = self.controller.revision();
        self.session = self.controller.snapshot_shared();
        if self.error.is_none() && self.session.error.is_none() {
            self.dismissed_error = None;
            self.error_expanded = false;
        }
        cx.notify();
    }
    fn result(&mut self, result: bello_agent_core::Result<()>, cx: &mut Context<Self>) {
        self.error = result.err().map(|e| e.to_string());
        self.refresh(cx);
    }
    fn command<R: Send + 'static>(
        &mut self,
        cx: &mut Context<Self>,
        command: impl FnOnce(Arc<Controller>) -> bello_agent_core::Result<R> + Send + 'static,
        apply: impl FnOnce(&mut ChatState, R, &mut Context<Self>) + 'static,
    ) {
        if self.busy || self.loading || self.load_failed || self.shutting_down {
            return;
        }
        self.busy = true;
        self.error = None;
        self.dismissed_error = None;
        self.error_expanded = false;
        let id = self.record.id.clone();
        let controller = self.controller.clone();
        self.composer
            .update(cx, |editor, cx| editor.set_read_only(true, cx));
        let task = cx
            .background_executor()
            .spawn(async move { command(controller) });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, move |view, cx| {
                if let Some(chat) = view.chat_mut(&id) {
                    chat.busy = false;
                    chat.composer
                        .update(cx, |editor, cx| editor.set_read_only(false, cx));
                    chat.session = chat.controller.snapshot_shared();
                    match result {
                        Ok(value) => apply(chat, value, cx),
                        Err(error) => chat.error = Some(error.to_string()),
                    }
                    chat.session = chat.controller.snapshot_shared();
                }
                view.draft_changed(&id, cx);
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    fn submit(&mut self, lane: Lane, cx: &mut Context<Self>) {
        self.submit_chat(lane, cx);
    }
    fn edit(&mut self, turn_id: &str, cx: &mut Context<Self>) {
        if self.editing.is_some() {
            return;
        }
        let edit_id = self
            .session
            .edit
            .as_ref()
            .filter(|edit| edit.turn_id == turn_id)
            .map(|edit| edit.edit_id.clone())
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let turn_id = turn_id.to_owned();
        let requested_edit = edit_id.clone();
        self.command(
            cx,
            move |controller| controller.begin_edit(&turn_id, &requested_edit),
            move |view, text, cx| {
                view.draft_before_edit = view.composer.read(cx).text().to_owned();
                view.queued_original = Some(text.clone());
                view.composer
                    .update(cx, |editor, cx| editor.set_text(text, cx));
                view.queued_turn_id = view.session.edit.as_ref().map(|edit| edit.turn_id.clone());
                view.editing = Some(edit_id);
            },
        );
    }
    fn resolve_edit(&mut self, outcome: &str, cx: &mut Context<Self>) {
        let Some(id) = self
            .editing
            .clone()
            .or_else(|| self.session.edit.as_ref().map(|edit| edit.edit_id.clone()))
        else {
            return;
        };
        let text = self.composer.read(cx).text().to_owned();
        let outcome = outcome.to_owned();
        self.command(
            cx,
            move |controller| {
                controller.resolve_edit(
                    &id,
                    &outcome,
                    (outcome == "saved").then_some(text.as_str()),
                )
            },
            |view, (), cx| {
                view.editing = None;
                view.queued_turn_id = None;
                view.queued_original = None;
                let draft = std::mem::take(&mut view.draft_before_edit);
                view.composer
                    .update(cx, |editor, cx| editor.set_text(draft, cx));
            },
        );
    }
    fn remove_queue(&mut self, id: String, cx: &mut Context<Self>) {
        let removes_edit = self
            .session
            .edit
            .as_ref()
            .is_some_and(|edit| edit.turn_id == id);
        self.command(
            cx,
            move |controller| controller.remove(&id),
            move |view, (), cx| {
                if removes_edit && view.editing.is_some() {
                    view.editing = None;
                    view.queued_turn_id = None;
                    view.queued_original = None;
                    let draft = std::mem::take(&mut view.draft_before_edit);
                    view.composer
                        .update(cx, |editor, cx| editor.set_text(draft, cx));
                }
            },
        );
    }
    fn request_close(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if self.close_ready {
            return true;
        }
        if self.shutting_down {
            return false;
        }
        if self.session.state == RunState::Running
            || self
                .inactive
                .values()
                .any(|chat| chat.session.state == RunState::Running)
            || self.workbench.read(cx).has_unsaved_changes(cx)
            || self
                .files
                .iter()
                .any(|entry| entry.view.read(cx).is_dirty(cx) || entry.view.read(cx).is_saving())
        {
            self.close_dialog = true;
            cx.notify();
        } else {
            self.begin_shutdown(window, cx);
        }
        false
    }
    fn open_changes(&mut self, cx: &mut Context<Self>) {
        self.changes_open = true;
        self.selected_file = None;
        self.show_files = true;
        cx.notify();
    }
    fn open_file(
        &mut self,
        path: PathBuf,
        line: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.show_files = true;
        if let Some(entry) = self.files.iter().find(|entry| entry.path == path) {
            self.selected_file = Some(entry.id);
            entry.view.update(cx, |view, cx| {
                if let Some(line) = line {
                    view.reveal_line(line, window, cx);
                }
                view.focus(window, cx);
            });
            cx.notify();
            return;
        }
        let id = self.next_file_id;
        self.next_file_id += 1;
        let file = cx.new(|cx| {
            FileTabView::new(
                self.project.clone(),
                path.clone(),
                line,
                self.palette,
                window,
                cx,
            )
        });
        let events = cx.subscribe_in(
            &file,
            window,
            move |view, file, event, window, cx| match event {
                FileTabEvent::CloseReady => view.file_closed(id, window, cx),
                FileTabEvent::Changed => {
                    let dirty = file.read(cx).is_dirty(cx);
                    if let Some(entry) = view.files.iter_mut().find(|entry| entry.id == id)
                        && entry.dirty != dirty
                    {
                        entry.dirty = dirty;
                        cx.notify();
                    }
                }
            },
        );
        file.read(cx).focus(window, cx);
        self.files.push(FileEntry {
            id,
            path,
            view: file,
            dirty: false,
            _events: events,
        });
        self.selected_file = Some(id);
        cx.notify();
    }
    fn file_closed(&mut self, id: u64, window: &mut Window, cx: &mut Context<Self>) {
        self.files.retain(|entry| entry.id != id);
        if self.selected_file == Some(id) {
            self.selected_file = self.files.last().map(|entry| entry.id);
        }
        self.show_files = self.changes_open || !self.files.is_empty();
        if let Some(selected) = self.selected_file
            && let Some(entry) = self.files.iter().find(|entry| entry.id == selected)
        {
            entry.view.read(cx).focus(window, cx);
        } else if !self.show_files {
            self.composer.read(cx).focus(window);
        }
        cx.notify();
    }
    fn close_selected_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(id) = self.selected_file {
            if let Some(entry) = self.files.iter().find(|entry| entry.id == id) {
                entry.view.update(cx, |view, cx| view.request_close(cx));
            }
        } else {
            self.changes_open = false;
            self.selected_file = self.files.last().map(|entry| entry.id);
            self.show_files = !self.files.is_empty();
            if !self.show_files {
                self.composer.read(cx).focus(window);
            }
            cx.notify();
        }
    }
    fn global_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if self.shutting_down {
            cx.stop_propagation();
            return;
        }
        let mods = &event.keystroke.modifiers;
        let command = mods.platform || (cfg!(target_os = "linux") && mods.control);
        if self.queue_detail.is_some() && event.keystroke.key == "escape" {
            self.close_queue_detail(true, window, cx);
            cx.stop_propagation();
            return;
        }
        if self.close_dialog {
            if matches!(event.keystroke.key.as_str(), "escape" | "enter") {
                self.close_dialog = false;
                cx.notify();
            }
            cx.stop_propagation();
            return;
        }
        if self.quick_open.read(cx).is_open() {
            let handled = self
                .quick_open
                .update(cx, |view, cx| view.key(event, window, cx));
            if handled {
                cx.stop_propagation();
            }
            return;
        }
        if command && event.keystroke.key == "n" {
            self.new_chat(window, cx);
            cx.stop_propagation();
        } else if command && event.keystroke.key == "p" {
            self.close_queue_detail(true, window, cx);
            self.quick_open.update(cx, |view, cx| view.show(window, cx));
            cx.stop_propagation();
            cx.notify();
        } else if command && event.keystroke.key == "w" {
            if self.show_files {
                self.close_selected_tab(window, cx);
            } else if self.request_close(window, cx) {
                window.remove_window();
            }
            cx.stop_propagation();
        }
    }
    fn side_pane(&mut self, width: f32, window: &mut Window, cx: &mut Context<Self>) -> Div {
        let p = self.palette;
        let mut tabs = div()
            .id("side-tabs")
            .h(px(36.))
            .flex_shrink_0()
            .px(px(8.))
            .border_b_1()
            .border_color(p.hairline())
            .flex()
            .gap(px(3.))
            .items_center()
            .overflow_x_scroll();
        if self.changes_open {
            tabs = tabs.child(
                div()
                    .id("changes-tab")
                    .h(px(28.))
                    .px(px(8.))
                    .rounded(px(8.))
                    .flex()
                    .gap(px(6.))
                    .items_center()
                    .when(self.selected_file.is_none(), |d| d.bg(p.fill()))
                    .cursor_pointer()
                    .on_click(cx.listener(|view, _, _, cx| {
                        view.selected_file = None;
                        cx.notify();
                    }))
                    .child(self.icon("branch", 12.))
                    .child(div().text_size(px(12.)).child(format!(
                            "Changes · {}",
                            self.project
                                .file_name()
                                .unwrap_or_default()
                                .to_string_lossy()
                        )))
                    .child(
                        self.icon_button("close-changes-tab", "close", 18.)
                            .on_click(cx.listener(|view, _, window, cx| {
                                cx.stop_propagation();
                                view.selected_file = None;
                                view.close_selected_tab(window, cx);
                            })),
                    ),
            );
        }
        for entry in &self.files {
            let id = entry.id;
            let selected = self.selected_file == Some(id);
            let title = format!(
                "{}{}",
                entry.view.read(cx).title(),
                if entry.dirty { " •" } else { "" }
            );
            tabs = tabs.child(
                div()
                    .id(("file-tab", id))
                    .h(px(28.))
                    .px(px(8.))
                    .rounded(px(8.))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .when(selected, |d| d.bg(p.fill()))
                    .cursor_pointer()
                    .on_click(cx.listener(move |view, _, window, cx| {
                        view.selected_file = Some(id);
                        if let Some(entry) = view.files.iter().find(|entry| entry.id == id) {
                            entry.view.read(cx).focus(window, cx);
                        }
                        cx.notify();
                    }))
                    .child(self.icon("book", 12.))
                    .child(
                        div()
                            .max_w(px(170.))
                            .text_size(px(12.))
                            .truncate()
                            .child(title),
                    )
                    .child(
                        self.icon_button(("close-file-tab", id), "close", 18.)
                            .on_click(cx.listener(move |view, _, _, cx| {
                                cx.stop_propagation();
                                if let Some(entry) = view.files.iter().find(|entry| entry.id == id)
                                {
                                    entry.view.update(cx, |file, cx| file.request_close(cx));
                                }
                            })),
                    ),
            );
        }
        let mut pane = div()
            .w(px(width))
            .flex_shrink_0()
            .h_full()
            .min_w_0()
            .flex()
            .flex_col()
            .bg(rgb(p.content))
            .child(tabs);
        if let Some(id) = self.selected_file
            && let Some(entry) = self.files.iter().find(|entry| entry.id == id)
        {
            pane = pane.child(entry.view.clone());
        } else {
            pane = pane
                .child(
                    div()
                        .px(px(12.))
                        .py(px(8.))
                        .border_b_1()
                        .border_color(p.hairline())
                        .flex()
                        .gap(px(8.))
                        .child(
                            self.button("git-changes", "Changes")
                                .when(!self.pane_history, |d| d.bg(p.accent_soft()))
                                .on_click(cx.listener(|view, _, _, cx| {
                                    view.pane_history = false;
                                    view.workbench.update(cx, |w, cx| {
                                        w.set_panel(WorkbenchPanel::Changes, cx)
                                    });
                                    cx.notify();
                                })),
                        )
                        .child(
                            self.button("git-history", "History")
                                .when(self.pane_history, |d| d.bg(p.accent_soft()))
                                .on_click(cx.listener(|view, _, _, cx| {
                                    view.pane_history = true;
                                    view.workbench.update(cx, |w, cx| {
                                        w.set_panel(WorkbenchPanel::History, cx)
                                    });
                                    cx.notify();
                                })),
                        ),
                )
                .child(self.workbench.clone());
        }
        let _ = window;
        pane
    }
    fn workbench_style(p: Palette) -> WorkbenchAppearance {
        let mut style = if p.dark {
            WorkbenchAppearance::dark()
        } else {
            WorkbenchAppearance::light()
        };
        style.show_tree = false;
        style.show_toolbar = false;
        style
    }
    fn finish_resize(&mut self, cx: &mut Context<Self>) {
        if self.resizing.take().is_none() {
            return;
        }
        let store = self.layout_store.clone();
        let revision = store.reserve();
        let layout = self.layout;
        let task = cx
            .background_executor()
            .spawn(async move { store.save(revision, layout) });
        cx.spawn(async move |view, cx| {
            if let Err(error) = task.await {
                let _ = view.update(cx, |view, cx| {
                    view.error = Some(format!("Layout could not be saved: {error}"));
                    cx.notify();
                });
            }
        })
        .detach();
    }
    fn resize_handle(
        &self,
        id: &'static str,
        sidebar: bool,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        div()
            .id(id)
            .relative()
            .w(px(1.))
            .h_full()
            .flex_shrink_0()
            .bg(self.palette.hairline())
            .child(
                div()
                    .absolute()
                    .left(px(-4.))
                    .w(px(9.))
                    .h_full()
                    .cursor(CursorStyle::ResizeLeftRight)
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |view, _, _, cx| {
                            view.resizing = Some(sidebar);
                            cx.stop_propagation();
                        }),
                    ),
            )
    }
    fn composer_style(p: Palette) -> EditorAppearance {
        let mut style = EditorAppearance::plain();
        style.font_family = if cfg!(target_os = "macos") {
            ".SystemUIFont"
        } else {
            "DejaVu Sans"
        }
        .into();
        style.font_size = 14.;
        style.line_height = 21.;
        style.padding_x = 15.;
        style.padding_y = 9.;
        style.text = rgb(p.ink).into();
        style.caret = rgb(p.accent).into();
        style.selection = p.accent_soft();
        style
    }
    fn icon(&self, name: &'static str, size: f32) -> Svg {
        svg()
            .path(name)
            .size(px(size))
            .text_color(rgb(self.palette.secondary))
    }
    fn icon_button(
        &self,
        id: impl Into<ElementId>,
        name: &'static str,
        size: f32,
    ) -> Stateful<Div> {
        let p = self.palette;
        div()
            .id(id)
            .size(px(size))
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(6.))
            .cursor_pointer()
            .hover(move |d| d.bg(p.fill()))
            .child(self.icon(name, 14.))
    }
    fn button(&self, id: impl Into<ElementId>, label: impl Into<SharedString>) -> Stateful<Div> {
        let p = self.palette;
        div()
            .id(id)
            .px(px(10.))
            .py(px(5.))
            .rounded(px(8.))
            .border_1()
            .border_color(p.hairline())
            .bg(rgb(p.surface))
            .text_size(px(11.5))
            .text_color(rgb(p.secondary))
            .cursor_pointer()
            .hover(move |d| d.bg(p.fill()))
            .child(label.into())
    }
    fn badge(&self, label: String, name: &'static str) -> Div {
        div()
            .flex()
            .items_center()
            .gap(px(4.))
            .px(px(7.))
            .py(px(3.))
            .rounded_full()
            .bg(self.palette.fill())
            .text_color(rgb(self.palette.secondary))
            .text_size(px(10.5))
            .child(self.icon(name, 11.))
            .child(label)
    }
    fn unavailable(&mut self, feature: &str, cx: &mut Context<Self>) {
        self.dismissed_error = None;
        self.error_expanded = false;
        self.error = Some(format!(
            "{feature} is not implemented in the Rust migration yet."
        ));
        cx.notify();
    }
    fn queue(&mut self, cx: &mut Context<Self>) -> Div {
        let p = self.palette;
        let timing = queue_presentation::QueueTiming::new(
            self.session.edit.is_some(),
            self.session.state == RunState::Error,
            self.session.queue_paused || self.session.state == RunState::Paused,
            self.session.state == RunState::Running,
        );
        let mut panel = div()
            .mx(px(16.))
            .mb(px(8.))
            .p(px(12.))
            .rounded(px(12.))
            .border_1()
            .border_color(p.hairline())
            .bg(rgb(p.sunken))
            .flex()
            .flex_col()
            .gap(px(8.));
        if self.session.pending.is_empty() {
            return div();
        }
        panel = panel.child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .text_size(px(11.5))
                        .text_color(rgb(p.secondary))
                        .child(timing.header(self.session.pending.len())),
                )
                .child(
                    self.icon_button(
                        "toggle-queue",
                        if self.queue_open { "down" } else { "chevron" },
                        22.,
                    )
                    .on_click(cx.listener(|view, _, _, cx| {
                        view.queue_open = !view.queue_open;
                        cx.notify();
                    })),
                ),
        );
        if !self.queue_open {
            return panel;
        }
        let ordered = queue_presentation::grouped_rows(
            self.session
                .pending
                .iter()
                .map(|item| item.lane == Lane::Steering),
        );
        let sections = usize::from(ordered.iter().any(|row| row.follow_up_number.is_none()))
            + usize::from(ordered.iter().any(|row| row.follow_up_number.is_some()));
        let mut rows = div()
            .id("queue-list")
            .max_h(px(queue_presentation::list_height(ordered.len(), sections)))
            .overflow_y_scroll()
            .flex()
            .flex_col();
        let mut last_lane = None;
        for row in ordered {
            let item = &self.session.pending[row.source_index];
            if last_lane.as_ref() != Some(&item.lane) {
                rows = rows.child(
                    div()
                        .h(px(queue_presentation::SECTION_HEIGHT))
                        .flex_shrink_0()
                        .flex()
                        .items_center()
                        .text_size(px(10.5))
                        .text_color(rgb(p.tertiary))
                        .child(if item.lane == Lane::Steering {
                            timing.steering()
                        } else {
                            timing.follow_ups()
                        }),
                );
                last_lane = Some(item.lane.clone());
            }
            let id = item.id.clone();
            let remove = id.clone();
            let detail = id.clone();
            rows = rows.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .h(px(queue_presentation::ROW_HEIGHT))
                    .flex_shrink_0()
                    .child(
                        div()
                            .w(px(14.))
                            .text_size(px(11.5))
                            .text_color(rgb(p.tertiary))
                            .when_some(row.follow_up_number, |d, number| {
                                d.child(number.to_string())
                            })
                            .when(row.follow_up_number.is_none(), |d| {
                                d.child(self.icon("steering", 12.).text_color(rgb(p.accent)))
                            }),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .overflow_hidden()
                            .text_size(px(13.))
                            .child(
                                item.text
                                    .lines()
                                    .next()
                                    .unwrap_or("")
                                    .chars()
                                    .take(100)
                                    .collect::<String>(),
                            ),
                    )
                    .child(
                        self.icon_button(
                            SharedString::from(format!("detail-{detail}")),
                            "info",
                            22.,
                        )
                        .on_click(cx.listener(
                            move |view, event: &ClickEvent, window, cx| {
                                view.open_queue_detail(
                                    detail.clone(),
                                    event.position(),
                                    window,
                                    cx,
                                );
                                cx.stop_propagation();
                            },
                        )),
                    )
                    .child(
                        self.icon_button(SharedString::from(format!("edit-{id}")), "pencil", 22.)
                            .on_click(cx.listener(move |v, _, _, cx| v.edit(&id, cx))),
                    )
                    .child(
                        self.icon_button(
                            SharedString::from(format!("remove-{remove}")),
                            "close",
                            22.,
                        )
                        .on_click(
                            cx.listener(move |v, _, _, cx| v.remove_queue(remove.clone(), cx)),
                        ),
                    ),
            );
        }
        panel.child(rows)
    }
    fn open_queue_detail(
        &mut self,
        turn_id: String,
        anchor: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.close_queue_detail(true, window, cx);
        self.queue_detail = Some(queue_detail::QueueDetail::new(
            &self.session,
            turn_id,
            anchor,
            self.palette,
            window,
            cx,
        ));
        cx.notify();
    }
    fn close_queue_detail(
        &mut self,
        restore_focus: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(key) = self.queue_detail.as_ref().map(|detail| detail.key.clone()) {
            self.close_queue_detail_if(&key, restore_focus, window, cx);
        }
    }
    fn close_queue_detail_if(
        &mut self,
        key: &queue_detail::DetailKey,
        restore_focus: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let detail = self.chat_mut(&key.chat_id).and_then(|chat| {
            if chat
                .queue_detail
                .as_ref()
                .is_some_and(|detail| &detail.key == key)
            {
                chat.queue_detail.take()
            } else {
                None
            }
        });
        if let Some(detail) = detail {
            if restore_focus {
                detail.restore_focus(window, cx);
            }
            cx.notify();
        }
    }
    fn starter(&self, cx: &mut Context<Self>) -> Div {
        let p = self.palette;
        let name = self
            .project
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        div().w_full().flex().justify_center().pt(px(24.)).child(
            div()
                .w_full()
                .max_w(px(560.))
                .p(px(16.))
                .rounded(px(12.))
                .border_1()
                .border_color(p.hairline())
                .bg(rgb(p.surface))
                .flex()
                .flex_col()
                .gap(px(12.))
                .child(
                    div()
                        .w_full()
                        .flex()
                        .justify_center()
                        .child(img(self.icon.clone()).size(px(48.))),
                )
                .child(
                    div()
                        .flex()
                        .gap(px(8.))
                        .items_center()
                        .child(
                            div()
                                .size(px(28.))
                                .rounded(px(8.))
                                .bg(p.accent_soft())
                                .flex()
                                .items_center()
                                .justify_center()
                                .child(self.icon("folder", 16.)),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_col()
                                .gap(px(2.))
                                .child(
                                    div()
                                        .text_size(px(14.))
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .child(name),
                                )
                                .child(
                                    div()
                                        .text_size(px(10.5))
                                        .text_color(rgb(p.tertiary))
                                        .child(self.project.display().to_string()),
                                ),
                        ),
                )
                .child(
                    div()
                        .flex()
                        .flex_wrap()
                        .gap(px(8.))
                        .child(
                            self.badge(
                                self.controller
                                    .profile()
                                    .map(|v| v.id.clone())
                                    .unwrap_or_else(|| "No connection".into()),
                                "antenna",
                            ),
                        )
                        .child(
                            self.badge(
                                self.controller
                                    .profile()
                                    .map(|v| v.model_id.clone())
                                    .unwrap_or_else(|| "catalog default".into()),
                                "cpu",
                            ),
                        )
                        .child(self.badge("Tools unavailable".into(), "pencil")),
                )
                .child(
                    div()
                        .text_size(px(11.5))
                        .text_color(rgb(p.secondary))
                        .child("Type below to start. Your first message creates the chat."),
                )
                .child(
                    div()
                        .flex()
                        .flex_wrap()
                        .gap(px(8.))
                        .child(
                            self.button("starter-changes", "")
                                .flex()
                                .items_center()
                                .gap(px(6.))
                                .child(self.icon("branch", 12.))
                                .child("Changes")
                                .on_click(cx.listener(|v, _, _, cx| {
                                    v.open_changes(cx);
                                })),
                        )
                        .child(
                            self.button("starter-terminal", "")
                                .flex()
                                .items_center()
                                .gap(px(6.))
                                .child(self.icon("terminal", 12.))
                                .child("Terminal")
                                .opacity(0.45),
                        )
                        .child(
                            self.button("starter-skills", "")
                                .flex()
                                .items_center()
                                .gap(px(6.))
                                .child(self.icon("command", 12.))
                                .child("Skills")
                                .opacity(0.45),
                        )
                        .child(
                            self.button("starter-side", "")
                                .flex()
                                .items_center()
                                .gap(px(6.))
                                .child(self.icon("branch", 12.))
                                .child("Open a side")
                                .opacity(0.45),
                        ),
                ),
        )
    }
    fn conversation(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Div {
        let p = self.palette;
        let mut transcript = div()
            .id("transcript")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .px(px(24.))
            .pb(px(13.))
            .flex()
            .flex_col()
            .gap(px(16.));
        if self.loading {
            transcript = transcript.child(
                div()
                    .py(px(24.))
                    .text_color(rgb(p.secondary))
                    .child("Preparing…"),
            );
        } else if self.load_failed {
            transcript = transcript.child(
                self.button("retry-chat-load", "Retry opening chat")
                    .on_click(cx.listener(|view, _, _, cx| {
                        let id = view.record.id.clone();
                        view.load_chat(&id, cx);
                    })),
            );
        } else if self.session.messages.is_empty() {
            transcript = transcript.child(self.starter(cx));
        }
        let start = self
            .session
            .messages
            .len()
            .saturating_sub(self.visible_messages);
        if start > 0 {
            transcript = transcript.child(
                self.button("earlier", format!("Show earlier messages ({start})"))
                    .on_click(cx.listener(|v, _, _, cx| {
                        v.visible_messages += 100;
                        cx.notify();
                    })),
            );
        }
        for message in self.session.messages.iter().skip(start) {
            let user = message.role == "user";
            let mut body = div()
                .min_w_0()
                .when(!user, |d| d.w_full())
                .max_w(px(640.))
                .flex()
                .flex_col()
                .gap(px(6.))
                .when(user, |d| {
                    d.w(px(layout::user_bubble_width(self.pane_width)))
                        .px(px(14.))
                        .py(px(9.))
                        .rounded(px(14.))
                        .bg(rgb(p.user))
                });
            if !message.reasoning.is_empty() {
                body = body.child(
                    div()
                        .text_size(px(12.))
                        .text_color(rgb(p.secondary))
                        .child(message.reasoning.clone()),
                );
            }
            body = body.child(
                div()
                    .min_w_0()
                    .max_w_full()
                    .text_size(px(14.5))
                    .line_height(px(21.))
                    .child(if message.text.is_empty() && message.state == "streaming" {
                        "Generating response…".into()
                    } else {
                        message.text.clone()
                    }),
            );
            if message.state == "interrupted" {
                body = body.child(
                    div()
                        .text_size(px(11.5))
                        .text_color(rgb(p.secondary))
                        .child("Interrupted"),
                );
            }
            transcript = transcript.child(
                div().w_full().flex().justify_center().child(
                    div()
                        .w_full()
                        .max_w(px(840.))
                        .min_w_0()
                        .pt(px(12.))
                        .flex()
                        .when(user, |d| d.justify_end().pl(px(40.)))
                        .child(body),
                ),
            );
        }
        let queue = self.queue(cx);
        let field_height = self
            .composer
            .update(cx, |editor, _| {
                editor.measured_content_height((self.pane_width - 34.).max(1.), window)
            })
            .clamp(44., 240.);
        let mut field = div()
            .relative()
            .h(px(field_height))
            .child(self.composer.clone())
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|view, _, window, cx| view.composer.read(cx).focus(window)),
            )
            .capture_key_down(cx.listener(|v, event: &KeyDownEvent, _, cx| {
                if event.keystroke.key == "enter"
                    && !event.keystroke.modifiers.shift
                    && !v.composer.read(cx).has_marked_text()
                {
                    cx.stop_propagation();
                    if v.editing.is_some() {
                        v.resolve_edit("saved", cx);
                    } else {
                        let steering = v.session.state == RunState::Running
                            && (event.keystroke.modifiers.platform
                                || event.keystroke.modifiers.control);
                        v.submit(
                            if steering {
                                Lane::Steering
                            } else {
                                Lane::FollowUp
                            },
                            cx,
                        );
                    }
                }
            }));
        if self.composer.read(cx).text().is_empty() {
            field = field.child(
                div()
                    .absolute()
                    .left(px(15.))
                    .top(px(9.))
                    .text_size(px(14.))
                    .text_color(rgb(p.tertiary))
                    .child("Message… ↩ Send · ⇧↩ New line"),
            );
        }
        let mut bar = div()
            .flex()
            .items_center()
            .gap(px(4.))
            .px(px(10.))
            .pb(px(8.))
            .child(
                self.icon_button("attach-image", "photo", 28.)
                    .bg(p.fill())
                    .opacity(0.45),
            )
            .child(
                self.icon_button("skills", "command", 28.)
                    .bg(p.fill())
                    .opacity(0.45),
            )
            .child(div().flex_1());
        if self.editing.is_some() {
            bar = bar.child(
                self.button("cancel-edit", "Cancel")
                    .on_click(cx.listener(|v, _, _, cx| v.resolve_edit("cancelled", cx))),
            );
        }
        if self.session.state == RunState::Running {
            bar = bar.child(
                self.button(
                    "steer",
                    if self.pane_width < 620. {
                        "↱"
                    } else {
                        "Steer run"
                    },
                )
                .on_click(cx.listener(|v, _, _, cx| v.submit(Lane::Steering, cx))),
            );
        }
        if self.session.queue_paused {
            bar = bar.child(self.button("resume", "Resume").on_click(cx.listener(
                |v, _, _, cx| v.command(cx, |controller| controller.resume(), |_, (), _| {}),
            )));
        }
        if self.session.retry.is_some() && self.session.state != RunState::Running {
            bar = bar.child(
                self.button("retry", "Retry")
                    .on_click(cx.listener(|v, _, _, cx| {
                        v.command(cx, |controller| controller.retry(), |_, (), _| {})
                    })),
            );
        }
        bar = bar
            .child(
                self.icon_button("changes", "branch", 28.)
                    .bg(p.fill())
                    .on_click(cx.listener(|v, _, _, cx| {
                        v.open_changes(cx);
                    })),
            )
            .child(self.icon_button("usage", "chart", 28.).opacity(0.45))
            .child(self.icon_button("actions", "dots", 28.).opacity(0.45));
        let compact = self.pane_width < 620.;
        let icons = self.pane_width < 480.;
        let model = self
            .controller
            .profile()
            .map(|profile| profile.model_id.clone())
            .unwrap_or_else(|| "No model".into());
        let effort = self
            .controller
            .profile()
            .map(|profile| profile.thinking_level.clone())
            .unwrap_or_else(|| "Default".into());
        let mut model_pill = div()
            .flex()
            .items_center()
            .gap(px(5.))
            .px(px(7.))
            .py(px(4.))
            .rounded_full()
            .bg(p.fill())
            .text_size(px(12.))
            .text_color(rgb(p.secondary))
            .child(self.icon("cpu", 11.));
        if !icons {
            model_pill = model_pill.child(
                div()
                    .max_w(px(if compact { 110. } else { 170. }))
                    .truncate()
                    .child(model),
            );
        }
        model_pill = model_pill.child(self.icon("down", 9.));
        let mut effort_pill = div()
            .flex()
            .items_center()
            .gap(px(5.))
            .px(px(7.))
            .py(px(4.))
            .rounded_full()
            .bg(p.fill())
            .text_size(px(12.))
            .text_color(rgb(p.secondary))
            .child(self.icon("sparkles", 11.));
        if !compact {
            effort_pill = effort_pill.child(effort);
        }
        bar = bar
            .child(model_pill)
            .child(effort_pill.child(self.icon("down", 9.)));
        let can_send = !self.busy
            && !self.loading
            && !self.shutting_down
            && !self.composer.read(cx).text().trim().is_empty();
        bar = bar.child(
            div()
                .id("send")
                .size(px(30.))
                .flex()
                .items_center()
                .justify_center()
                .rounded_full()
                .bg(if can_send {
                    rgb(p.brand).into()
                } else {
                    p.fill()
                })
                .cursor_pointer()
                .child(svg().path("send").size(px(16.)).text_color(if can_send {
                    p.on_accent()
                } else {
                    rgb(p.tertiary).into()
                }))
                .on_click(cx.listener(|v, _, _, cx| {
                    if v.editing.is_some() {
                        v.resolve_edit("saved", cx);
                    } else {
                        v.submit(Lane::FollowUp, cx);
                    }
                })),
        );
        if self.session.state == RunState::Running {
            bar = bar.child(
                div()
                    .id("stop")
                    .size(px(30.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded_full()
                    .bg(rgb(p.danger))
                    .cursor_pointer()
                    .child(svg().path("stop").size(px(15.)).text_color(p.on_accent()))
                    .on_click(cx.listener(|v, _, _, cx| {
                        let result = v.controller.stop();
                        v.result(result, cx);
                    })),
            );
        }
        let mut composer = div()
            .mx(px(16.))
            .mt(px(8.))
            .mb(px(6.))
            .rounded(px(16.))
            .border_1()
            .border_color(p.hairline())
            .bg(rgb(p.surface))
            .overflow_hidden()
            .flex()
            .flex_col();
        for intent in self
            .recoveries
            .values()
            .filter(|intent| intent.chat_id == self.record.id)
        {
            let restore = intent.id.clone();
            let dismiss = intent.id.clone();
            let actions = div()
                .flex()
                .gap(px(8.))
                .child(
                    self.button(
                        SharedString::from(format!("restore-{restore}")),
                        "Insert in draft",
                    )
                    .on_click(
                        cx.listener(move |view, _, _, cx| view.resolve_intent(&restore, true, cx)),
                    ),
                )
                .child(
                    self.button(SharedString::from(format!("dismiss-{dismiss}")), "Dismiss")
                        .on_click(cx.listener(move |view, _, _, cx| {
                            view.resolve_intent(&dismiss, false, cx)
                        })),
                );
            composer = composer.child(div().px(px(12.)).py(px(8.)).bg(p.accent_soft()).flex().flex_col().gap(px(6.))
                .child(div().text_size(px(11.5)).child("Unconfirmed submission · It may have been accepted. Review before sending again."))
                .child(div().text_size(px(12.)).max_h(px(60.)).overflow_hidden().child(intent.text.chars().take(300).collect::<String>()))
                .child(actions));
        }
        if self.editing.is_some() {
            composer = composer.child(
                div()
                    .px(px(12.))
                    .py(px(6.))
                    .bg(p.accent_soft())
                    .text_size(px(11.5))
                    .text_color(rgb(p.accent))
                    .child("Editing queued message · Save keeps its place in the queue"),
            );
        }
        composer = composer.child(field).child(bar);
        let view = div()
            .flex_1()
            .min_w_0()
            .min_h_0()
            .flex()
            .flex_col()
            .bg(rgb(p.content))
            .child(transcript)
            .child(queue);
        let reported: Vec<_> = self
            .session
            .messages
            .iter()
            .filter(|m| !m.usage.is_null())
            .collect();
        let tokens = if reported.is_empty() {
            "Tokens n/a".into()
        } else {
            format!(
                "{} in · {} out",
                reported
                    .iter()
                    .filter_map(|m| m.usage["input_tokens"].as_u64())
                    .sum::<u64>(),
                reported
                    .iter()
                    .filter_map(|m| m.usage["output_tokens"].as_u64())
                    .sum::<u64>()
            )
        };
        view.child(composer).child(
            div()
                .px(px(16.))
                .pt(px(2.))
                .pb(px(6.))
                .flex()
                .items_center()
                .gap(px(12.))
                .text_size(px(11.5))
                .text_color(rgb(p.secondary))
                .flex_wrap()
                .child(self.badge(tokens, "chart"))
                .child(self.badge("Cost n/a".into(), "chart"))
                .child(self.badge("Context n/a".into(), "cpu"))
                .child(div().flex_1())
                .when(self.session.state == RunState::Running, |d| {
                    d.child("Working · Generating response…")
                })
                .child(self.badge("Capture off".into(), "bug")),
        )
    }
    fn sidebar(&self, cx: &mut Context<Self>) -> Div {
        let p = self.palette;
        let name = self
            .project
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        let mut list = div()
            .flex_1()
            .min_h_0()
            .px(px(8.))
            .pt(px(3.))
            .flex()
            .flex_col()
            .gap(px(9.))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .px(px(7.))
                    .py(px(3.))
                    .child(self.icon("down", 10.))
                    .child(self.icon("folder", 12.))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(12.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(name),
                    )
                    .child(self.icon_button("project-changes", "branch", 22.).on_click(
                        cx.listener(|v, _, _, cx| {
                            v.open_changes(cx);
                        }),
                    ))
                    .child(
                        self.icon_button("new-project-chat", "plus", 22.)
                            .on_click(cx.listener(|view, _, window, cx| view.new_chat(window, cx))),
                    )
                    .child(
                        self.icon_button("project-actions", "dots", 22.)
                            .opacity(0.45),
                    ),
            );
        let filter = self.filter.read(cx).text().trim().to_lowercase();
        for record in &self.records {
            let chat = self.chat_ref(&record.id);
            let title = chat
                .map(|chat| {
                    if chat.loading || chat.load_failed {
                        chat.record.title.as_str()
                    } else {
                        chat.session.title.as_str()
                    }
                })
                .unwrap_or(record.title.as_str());
            if !filter.is_empty() && !title.to_lowercase().contains(&filter) {
                continue;
            }
            let id = record.id.clone();
            let selected = id == self.record.id;
            let status = chat
                .map(|chat| {
                    if chat.loading {
                        "Preparing…"
                    } else {
                        match chat.session.state {
                            RunState::Idle => "Ready",
                            RunState::Running => "Working",
                            RunState::Paused => "Paused",
                            RunState::Error => "Failed",
                        }
                    }
                })
                .unwrap_or("Ready");
            list = list.child(
                div()
                    .id(SharedString::from(format!("chat-row-{id}")))
                    .mx(px(4.))
                    .px(px(10.))
                    .py(px(9.))
                    .rounded(px(8.))
                    .when(selected, |d| d.bg(p.accent_soft()))
                    .flex()
                    .gap(px(8.))
                    .items_center()
                    .cursor_pointer()
                    .on_click(
                        cx.listener(move |view, _, window, cx| view.select_chat(&id, window, cx)),
                    )
                    .child(self.icon("chat", 16.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(px(13.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .truncate()
                                    .child(title.to_owned()),
                            )
                            .child(
                                div()
                                    .text_size(px(10.5))
                                    .text_color(rgb(p.secondary))
                                    .child(status),
                            ),
                    ),
            );
        }
        let mut footer = div()
            .h(px(41.))
            .flex_shrink_0()
            .border_t_1()
            .border_color(p.hairline())
            .px(px(8.))
            .py(px(6.))
            .flex()
            .gap(px(2.))
            .items_center();
        for (id, icon) in [
            ("report", "chart"),
            ("inspector", "bug"),
            ("resources", "book"),
            ("background", "sparkles"),
            ("archived", "archive"),
        ] {
            footer = footer.child(self.icon_button(id, icon, 28.).opacity(0.45));
        }
        footer = footer.child(div().flex_1()).child(
            self.icon_button("settings", "gear", 28.)
                .on_click(cx.listener(|v, _, _, cx| v.unavailable("Connection settings", cx))),
        );
        div()
            .w(px(self.layout.sidebar))
            .flex_shrink_0()
            .h_full()
            .bg(rgb(p.window))
            .border_r_1()
            .border_color(p.hairline())
            .flex()
            .flex_col()
            .child(div().h(px(36.)).flex_shrink_0())
            .child(
                div()
                    .px(px(16.))
                    .pt(px(10.))
                    .pb(px(4.))
                    .flex()
                    .gap(px(4.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(10.5))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(p.tertiary))
                            .child("PROJECTS"),
                    )
                    .child(
                        self.icon_button("new-chat", "new-chat", 24.)
                            .bg(p.accent_soft())
                            .on_click(cx.listener(|view, _, window, cx| view.new_chat(window, cx))),
                    )
                    .child(
                        self.icon_button("manage-projects", "folder", 24.)
                            .opacity(0.45),
                    ),
            )
            .child(
                div()
                    .mx(px(12.))
                    .mb(px(6.))
                    .h(px(30.))
                    .px(px(7.))
                    .rounded(px(8.))
                    .border_1()
                    .border_color(p.hairline())
                    .bg(rgb(p.surface))
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .child(self.icon("search", 13.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .relative()
                            .h_full()
                            .on_mouse_down(
                                MouseButton::Left,
                                cx.listener(|view, _, window, cx| {
                                    view.filter.read(cx).focus(window)
                                }),
                            )
                            .capture_key_down(cx.listener(|_, event: &KeyDownEvent, _, cx| {
                                if event.keystroke.key == "enter" {
                                    cx.stop_propagation();
                                }
                            }))
                            .child(self.filter.clone())
                            .when(self.filter.read(cx).text().is_empty(), |d| {
                                d.child(
                                    div()
                                        .absolute()
                                        .top(px(5.))
                                        .left(px(2.))
                                        .text_size(px(13.))
                                        .text_color(rgb(p.tertiary))
                                        .child("Filter chats and topics"),
                                )
                            }),
                    ),
            )
            .child(list)
            .child(footer)
    }
}
impl Render for AgentView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let started = Instant::now();
        let palette = current_palette(window);
        if self.palette != palette {
            self.palette = palette;
            self.composer.update(cx, |editor, cx| {
                editor.set_appearance(Self::composer_style(palette), cx)
            });
            for chat in self.inactive.values() {
                chat.composer.update(cx, |editor, cx| {
                    editor.set_appearance(Self::composer_style(palette), cx)
                });
            }
            self.filter.update(cx, |editor, cx| {
                let mut style = Self::composer_style(palette);
                style.font_size = 13.;
                style.line_height = 19.;
                style.padding_x = 2.;
                style.padding_y = 4.;
                editor.set_appearance(style, cx);
            });
            self.workbench.update(cx, |view, cx| {
                view.set_appearance(Self::workbench_style(palette), cx)
            });
            self.quick_open
                .update(cx, |view, cx| view.set_palette(palette, cx));
            for entry in &self.files {
                entry
                    .view
                    .update(cx, |view, cx| view.set_palette(palette, cx));
            }
        }
        let p = self.palette;
        let width = f32::from(window.viewport_size().width);
        self.pane_width = if self.show_files {
            self.layout.panes(width).0
        } else {
            (width - self.layout.sidebar - 1.).max(0.)
        };
        let sidebar = self.sidebar(cx);
        let conversation = self.conversation(window, cx);
        let mut content = div()
            .flex_1()
            .min_w_0()
            .min_h_0()
            .flex()
            .child(conversation);
        if self.show_files {
            content = content
                .child(self.resize_handle("pane-resize", false, cx))
                .child(self.side_pane(self.layout.panes(width).1, window, cx));
        }
        if let Some(error) = self
            .error
            .as_ref()
            .or(self.session.error.as_ref())
            .filter(|error| self.dismissed_error.as_ref() != Some(*error))
        {
            let text = error.clone();
            let copied = text.clone();
            let dismissed = text.clone();
            let body = div()
                .flex_1()
                .min_w_0()
                .text_size(px(11.5))
                .text_color(rgb(p.danger))
                .when(!self.error_expanded, |d| d.line_clamp(3))
                .child(text);
            let body = if self.error_expanded {
                div()
                    .id("error-full-text")
                    .flex_1()
                    .max_h(px(180.))
                    .overflow_y_scroll()
                    .child(body)
                    .into_any_element()
            } else {
                body.into_any_element()
            };
            let strip = div()
                .px(px(16.))
                .py(px(8.))
                .bg(p.accent_soft())
                .flex()
                .items_start()
                .gap(px(8.))
                .child(body)
                .child(
                    self.button(
                        "expand-error",
                        if self.error_expanded { "Less" } else { "More" },
                    )
                    .on_click(cx.listener(|view, _, _, cx| {
                        view.error_expanded = !view.error_expanded;
                        cx.notify();
                    })),
                )
                .child(self.button("copy-error", "Copy").on_click(move |_, _, cx| {
                    cx.write_to_clipboard(ClipboardItem::new_string(copied.clone()))
                }))
                .child(
                    self.icon_button("dismiss-error", "close", 22.)
                        .on_click(cx.listener(move |view, _, _, cx| {
                            view.dismissed_error = Some(dismissed.clone());
                            view.error_expanded = false;
                            cx.notify();
                        })),
                );
            content = div()
                .flex_1()
                .min_w_0()
                .min_h_0()
                .flex()
                .flex_col()
                .child(strip)
                .child(content);
        }
        let mut element = div()
            .relative()
            .size_full()
            .flex()
            .bg(rgb(p.content))
            .text_color(rgb(p.ink))
            .font_family(if cfg!(target_os = "macos") {
                ".SystemUIFont"
            } else {
                "DejaVu Sans"
            })
            .child(sidebar)
            .child(self.resize_handle("sidebar-resize", true, cx))
            .child(content)
            .capture_key_down(cx.listener(Self::global_key))
            .on_mouse_move(cx.listener(|view, event: &MouseMoveEvent, window, cx| {
                if event.dragging()
                    && let Some(sidebar) = view.resizing
                {
                    let x = f32::from(event.position.x);
                    if sidebar {
                        view.layout.sidebar = x.clamp(200., 420.);
                    } else {
                        let total =
                            f32::from(window.viewport_size().width) - view.layout.sidebar - 1.;
                        view.layout.fraction =
                            ((x - view.layout.sidebar) / total).clamp(0.30, 0.70);
                    }
                    cx.notify();
                }
            }))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|view, _, _, cx| view.finish_resize(cx)),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(|view, _, _, cx| view.finish_resize(cx)),
            );
        if let Some(mut detail) = self.queue_detail.take() {
            let key = detail.key.clone();
            let body = detail
                .render(&self.session, p, window, cx)
                .id("queue-detail-popover")
                .occlude()
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .on_mouse_down_out(cx.listener(move |view, _, window, cx| {
                    view.close_queue_detail_if(&key, false, window, cx);
                }));
            element = element.child(
                deferred(
                    anchored()
                        .position(detail.anchor)
                        .anchor(Corner::BottomRight)
                        .snap_to_window_with_margin(px(8.))
                        .child(body),
                )
                .with_priority(10),
            );
            self.queue_detail = Some(detail);
        }
        if self.quick_open.read(cx).is_open() {
            element = element.child(
                div()
                    .absolute()
                    .inset_0()
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|view, _, window, cx| {
                            view.quick_open
                                .update(cx, |quick, cx| quick.close(true, window, cx))
                        }),
                    )
                    .child(
                        div()
                            .absolute()
                            .top(px(56.))
                            .left(px((width - (width - 80.).clamp(320., 640.)) / 2.))
                            .w(px((width - 80.).clamp(320., 640.)))
                            .child(self.quick_open.clone()),
                    ),
            );
        }
        if self.close_dialog {
            element=element.child(div().absolute().inset_0().occlude().flex().items_center().justify_center().bg(rgba(0x00000055)).child(div().w(px(440.)).p(px(24.)).rounded(px(16.)).bg(rgb(p.surface)).border_1().border_color(p.hairline()).flex().flex_col().gap(px(16.)).child(div().text_size(px(17.)).font_weight(FontWeight::SEMIBOLD).child("Close this workspace?")).child(div().text_size(px(13.)).text_color(rgb(p.secondary)).child("Active responses will stop. Unsaved file drafts will be discarded. Chat drafts, accepted messages, and queued input will be saved before closing.")).child(div().flex().gap(px(12.)).child(self.button("keep-working","Keep working").on_click(cx.listener(|v,_,_,cx|{v.close_dialog=false;cx.notify();}))).child(self.button("close-discard","Close workspace").on_click(cx.listener(|v,_,window,cx|v.begin_shutdown(window,cx)))))));
        }
        if self.shutting_down {
            element = element.child(
                div()
                    .absolute()
                    .inset_0()
                    .occlude()
                    .flex()
                    .items_center()
                    .justify_center()
                    .bg(rgba(0x00000044))
                    .child(
                        div()
                            .p(px(20.))
                            .rounded(px(16.))
                            .bg(rgb(p.surface))
                            .child("Saving drafts…"),
                    ),
            );
        }
        perf("render_callback", started.elapsed().as_micros());
        element
    }
}

fn default_session() -> PathBuf {
    #[cfg(target_os = "macos")]
    let base = PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
        .join("Library/Application Support");
    #[cfg(not(target_os = "macos"))]
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share")
        });
    base.join("BelloAgent-rust/sessions/default.json")
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    START.set(Instant::now()).ok();
    let mut args = std::env::args().skip(1);
    let mut project = std::env::current_dir()?;
    let mut session = default_session();
    let mut profile_path = None;
    let mut credential_stdin = false;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--project" => {
                project = PathBuf::from(args.next().ok_or("--project needs a directory")?)
            }
            "--session" => session = PathBuf::from(args.next().ok_or("--session needs a file")?),
            "--profile" => {
                profile_path = Some(PathBuf::from(args.next().ok_or("--profile needs a file")?))
            }
            "--credential-stdin" => credential_stdin = true,
            "--help" | "-h" => {
                println!(
                    "BelloAgent Rust GPUI preview\n  --project DIR\n  --session FILE    isolated Rust snapshot (never a Swift journal)\n  --profile FILE    explicit non-secret LiteLLM Responses JSON\n  --credential-stdin  read an in-memory key until EOF; never stored\n  BELLO_PERF_LOG=FILE  optional real CPU callback JSONL telemetry"
                );
                return Ok(());
            }
            _ => return Err(format!("Unknown argument: {arg}").into()),
        }
    }
    let configuration = if let Some(path) = profile_path {
        if !credential_stdin {
            return Err("--profile requires --credential-stdin; no automatic key discovery".into());
        }
        let profile: Profile = serde_json::from_slice(&std::fs::read(path)?)?;
        let mut key = String::new();
        std::io::stdin().take(16_385).read_to_string(&mut key)?;
        let length = key.trim_end_matches(['\n', '\r']).len();
        key.truncate(length);
        Some((profile, Credential::new(key)?))
    } else {
        if credential_stdin {
            return Err("--credential-stdin requires --profile".into());
        }
        None
    };
    project = std::fs::canonicalize(project)?;
    if !session.is_absolute() {
        session = std::env::current_dir()?.join(session);
    }
    let mut workspace = WorkspaceStore::open(session.with_extension("workspace.json"), &project)?;
    let state = workspace.snapshot();
    let selected = state
        .selected
        .as_ref()
        .and_then(|id| state.chats.iter().find(|chat| &chat.id == id))
        .or(state.chats.first())
        .cloned();
    let (store, record, pending) = if let Some(record) = selected {
        let store = if record.snapshot.exists() {
            SessionStore::open(&record.snapshot)?
        } else {
            SessionStore::pending_with_id(&record.id)?
        };
        if store.snapshot().id != record.id {
            return Err("Catalog and session identity disagree".into());
        }
        (store, record, false)
    } else {
        let existing = session.exists();
        let store = if existing {
            SessionStore::open(&session)?
        } else {
            SessionStore::pending()
        };
        let snapshot = store.snapshot();
        let record = ChatRecord {
            id: snapshot.id,
            title: snapshot.title,
            snapshot: session,
        };
        if existing {
            workspace.register(record.clone(), DraftRecord::default())?;
        }
        (store, record, !existing)
    };
    let draft = workspace
        .snapshot()
        .drafts
        .get(&record.id)
        .cloned()
        .unwrap_or_default();
    let workspace = Arc::new(Mutex::new(workspace));
    let controller = Controller::new(store, configuration)?;
    perf(
        "startup_initialized",
        START.get().unwrap().elapsed().as_micros(),
    );
    Application::new()
        .with_assets(assets::Assets)
        .run(move |cx: &mut App| {
            bello_workbench_ui::init(cx);
            let bounds = Bounds::centered(None, initial_size(), cx);
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    window_min_size: Some(size(px(920.), px(600.))),
                    ..Default::default()
                },
                move |window, cx| {
                    window.set_window_title("Bello Agent");
                    cx.new(|cx| {
                        AgentView::new(
                            LaunchState {
                                controller,
                                project,
                                workspace,
                                record,
                                draft,
                                pending,
                            },
                            window,
                            cx,
                        )
                    })
                },
            )
            .expect("Could not create native GPUI window");
            cx.on_window_closed(|cx| {
                if cx.windows().is_empty() {
                    cx.quit();
                }
            })
            .detach();
            cx.activate(true);
        });
    Ok(())
}
