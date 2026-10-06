mod assets;
mod chat;
mod chat_navigation;
mod draft_status;
mod file_tab;
mod layout;
#[cfg(any(target_os = "macos", test))]
mod native_menu;
#[cfg(feature = "native-lifecycle-smoke")]
mod native_smoke;
mod queue_actions;
mod queue_begin;
mod queue_cancel;
mod queue_detail;
mod queue_drag;
mod queue_edit;
mod queue_edit_controls;
mod queue_geometry;
mod queue_presentation;
mod quick_open;
mod shutdown_barrier;
mod sidebar_actions;
mod theme;
mod transcript_actions;
#[cfg(test)]
#[path = "../../../benches/transcript.rs"]
mod transcript_benchmark;
mod transcript_view;
#[cfg(test)]
mod transcript_view_tests;
mod workspace_lifetime;
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
    shutdown_operation: Option<uuid::Uuid>,
    pin_operations: BTreeMap<String, uuid::Uuid>,
    pin_errors: BTreeMap<String, sidebar_actions::PinError>,
    cancelled_prompt_key: Option<String>,
    sidebar_menu: Option<sidebar_actions::SidebarMenu>,
    chat_directory: PathBuf,
    unloaded_drafts: BTreeMap<String, DraftRecord>,
    recoveries: BTreeMap<String, SubmissionIntent>,
    queued_cancellations: BTreeMap<String, bello_agent_core::workspace::QueuedCancelReceipt>,
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
    _quick_events: Option<Subscription>,
    window_binding: Option<workspace_lifetime::WindowBinding>,
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
        // Legacy catalogs appended records in creation order. Recover a stable
        // ordering for presentation without rewriting those files on open.
        for (index, record) in records.iter_mut().enumerate() {
            record.sidebar_order.get_or_insert(index as u64 + 1);
        }
        let record = records
            .iter()
            .find(|item| item.id == record.id)
            .cloned()
            .unwrap_or(record);
        if !records.iter().any(|item| item.id == record.id) {
            records.insert(0, record.clone());
        }
        let layout_store = Arc::new(layout::LayoutStore::new(
            record.snapshot.parent().unwrap().join("layout.json"),
        ));
        let layout = layout_store.load();
        let cancel_receipt = state.queued_cancellations.get(&record.id).cloned();
        let chat = ChatState::new(
            controller,
            record,
            chat::RestoredDraft {
                draft,
                cancellation: cancel_receipt.as_ref(),
            },
            pending,
            palette,
            window,
            cx,
        );
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
        let editor_events = vec![
            cx.subscribe(&filter, |_, _, _, cx| cx.notify()),
            // Notify the retained transcript before GPUI starts drawing. A
            // notify issued from Render is too late for that frame's cache key.
            cx.observe_self(|view, cx| view.sync_transcript_inputs(cx)),
        ];
        let workbench = cx.new(|cx| WorkbenchView::new(project.clone(), window, cx));
        workbench.update(cx, |view, cx| {
            view.set_appearance(Self::workbench_style(palette), cx);
            view.set_panel(WorkbenchPanel::Changes, cx);
        });
        let quick_open = cx.new(|cx| QuickOpenView::new(project.clone(), palette, window, cx));
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
        let mut view = Self {
            chat,
            inactive: BTreeMap::new(),
            records,
            chat_directory,
            unloaded_drafts: state.drafts,
            recoveries: state.intents,
            queued_cancellations: state.queued_cancellations,
            workspace,
            selection_revision: state.selection_revision,
            shutting_down: false,
            close_ready: false,
            shutdown_operation: None,
            pin_operations: BTreeMap::new(),
            pin_errors: BTreeMap::new(),
            cancelled_prompt_key: None,
            sidebar_menu: None,
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
            _quick_events: None,
            window_binding: None,
            project,
            icon,
            filter,
            _editor_events: editor_events,
            workbench,
            show_files: false,
            close_dialog: false,
            _release: release,
        };
        view.bind_window(window, cx);
        view
    }
    fn bind_window(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.cancel_queue_drag(window, cx);
        self.queue_geometry = None;
        self.sidebar_menu = None;
        let binding = workspace_lifetime::WindowBinding::new(window.window_handle().window_id());
        self.window_binding = Some(binding);
        let weak = cx.weak_entity();
        window.on_window_should_close(cx, move |window, cx| {
            weak.update(cx, |view, cx| view.request_close_for(binding, window, cx))
                .unwrap_or(true)
        });
        self._quick_events = Some(cx.subscribe_in(
            &self.quick_open,
            window,
            move |view, _, event, window, cx| {
                if view.window_binding != Some(binding) {
                    return;
                }
                match event {
                    QuickOpenEvent::Open { path, line } => {
                        view.open_file(path.clone(), *line, window, cx)
                    }
                    QuickOpenEvent::Dismissed => cx.notify(),
                }
            },
        ));
        for index in 0..self.files.len() {
            let id = self.files[index].id;
            let file = self.files[index].view.clone();
            let events = self.subscribe_file_events(id, &file, window, cx);
            self.files[index].dirty = file.read(cx).is_dirty(cx);
            self.files[index]._events = events;
        }
        if let Some(file) = self
            .selected_file
            .and_then(|id| self.files.iter().find(|file| file.id == id))
        {
            file.view.read(cx).focus(window, cx);
        } else {
            self.composer.read(cx).focus(window);
        }
    }
    fn request_close_for(
        &mut self,
        binding: workspace_lifetime::WindowBinding,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.window_binding != Some(binding) {
            return true;
        }
        self.request_close(window, cx)
    }
    fn subscribe_file_events(
        &self,
        id: u64,
        file: &Entity<FileTabView>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Subscription {
        let binding = self.window_binding;
        cx.subscribe_in(file, window, move |view, file, event, window, cx| {
            if view.window_binding != binding {
                return;
            }
            match event {
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
            }
        })
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
        let failed = result.is_err();
        self.error = result.err().map(|e| e.to_string());
        self.refresh(cx);
        if failed {
            let id = self.record.id.clone();
            self.recheck_edit_after_failure(&id, None, cx);
        }
    }
    fn command<R: Send + 'static>(
        &mut self,
        cx: &mut Context<Self>,
        recovery_edit: Option<String>,
        flush_current_draft: bool,
        command: impl FnOnce(Arc<Controller>) -> bello_agent_core::Result<R> + Send + 'static,
        apply: impl FnOnce(&mut ChatState, R, &mut Context<Self>) + 'static,
    ) {
        if self.busy
            || self.loading
            || self.load_failed
            || self.shutting_down
            || self.edit_recovery.blocked
            || self.has_pending_cancel(&self.record.id)
            || self.queue_operation.is_some()
        {
            return;
        }
        let flush = if flush_current_draft {
            if self.composer.read(cx).has_marked_text() {
                self.error = Some("Finish composing text before changing the queued edit.".into());
                cx.notify();
                return;
            }
            let Some(next) = self
                .draft_revision
                .checked_add(2)
                .map(|_| self.draft_revision + 1)
            else {
                self.error = Some("Draft revision limit reached; your text is preserved.".into());
                cx.notify();
                return;
            };
            self.draft_revision = next;
            Some(self.saved_draft(cx))
        } else {
            None
        };
        self.busy = true;
        self.error = None;
        self.dismissed_error = None;
        self.error_expanded = false;
        let id = self.record.id.clone();
        let controller = self.controller.clone();
        let workspace = self.workspace.clone();
        let flush_id = id.clone();
        let identity_controller = controller.clone();
        let identity_project = self.project.clone();
        self.composer
            .update(cx, |editor, cx| editor.set_read_only(true, cx));
        let task = cx.background_executor().spawn(async move {
            let flushed = if let Some(draft) = flush {
                let revision = draft.revision;
                let saved = workspace
                    .lock()
                    .map_err(|_| {
                        bello_agent_core::Error::Invalid("Workspace is unavailable".into())
                    })
                    .and_then(|mut store| store.flush_draft_exact(&flush_id, draft));
                if let Err(error) = saved {
                    return (None, Err(error));
                }
                Some(revision)
            } else {
                None
            };
            (flushed, command(controller))
        });
        cx.spawn(async move |view, cx| {
            let (flushed, result) = task.await;
            let failed = result.is_err();
            let _ = view.update(cx, move |view, cx| {
                if view.project != identity_project
                    || view
                        .chat_ref(&id)
                        .is_none_or(|chat| !Arc::ptr_eq(&chat.controller, &identity_controller))
                {
                    return;
                }
                if let Some(chat) = view.chat_mut(&id) {
                    if let Some(revision) = flushed {
                        chat.draft_save_status.confirm(revision, &mut chat.error);
                    }
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
                if failed && let Some(edit_id) = recovery_edit {
                    view.recheck_edit_after_failure(&id, Some(edit_id), cx);
                }
                view.drain_edit_recheck(&id, cx);
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    fn submit(&mut self, lane: Lane, cx: &mut Context<Self>) {
        self.submit_chat(lane, cx);
    }
    fn resolve_edit(&mut self, outcome: &str, cx: &mut Context<Self>) {
        if outcome == "cancelled" {
            let chat_id = self.record.id.clone();
            self.cancel_owned_edit(&chat_id, cx);
            return;
        }
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
            Some(id.clone()),
            true,
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
        let recovery_edit = self
            .session
            .edit
            .as_ref()
            .filter(|edit| edit.turn_id == id)
            .map(|edit| edit.edit_id.clone());
        self.command(
            cx,
            recovery_edit,
            true,
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
        let events = self.subscribe_file_events(id, &file, window, cx);
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
        // Preserve cancellation for the whole consumed press, even if the file
        // pane closes or focus changes before a repeat. A fresh press owns its
        // normal behavior. Native macOS/Wayland report repeats via is_held;
        // pinned GPUI X11 does not, so physical X11 repeat protection is limited.
        if !event.is_held {
            self.cancelled_prompt_key = None;
        } else if self.cancelled_prompt_key.as_deref() == Some(event.keystroke.key.as_str()) {
            cx.stop_propagation();
            return;
        }
        if event.keystroke.key == "escape" && self.cancel_queue_drag(window, cx) {
            cx.stop_propagation();
            return;
        }
        if self.shutting_down {
            cx.stop_propagation();
            return;
        }
        if self.sidebar_menu_key(event, cx) {
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
        // A pane tab can be closed while the composer still owns focus.
        // Route only the existing cancel keys to its visible safety prompt;
        // keep native text composition ahead of that cancellation intent.
        if self.show_files && matches!(event.keystroke.key.as_str(), "escape" | "enter") {
            let composing = [&self.composer, &self.filter].into_iter().any(|editor| {
                let editor = editor.read(cx);
                editor.focus_handle(cx).is_focused(window) && editor.has_marked_text()
            });
            if !composing
                && let Some(entry) = self
                    .files
                    .iter()
                    .find(|entry| Some(entry.id) == self.selected_file)
                && entry
                    .view
                    .update(cx, |view, cx| view.close_prompt_key(event, window, cx))
            {
                self.cancelled_prompt_key = Some(event.keystroke.key.clone());
                cx.stop_propagation();
                return;
            }
        }
        let navigation_command = if cfg!(target_os = "macos") {
            mods.platform && !mods.control
        } else {
            mods.control && !mods.platform
        };
        if navigation_command
            && mods.alt
            && !mods.shift
            && matches!(event.keystroke.key.as_str(), "up" | "down")
        {
            self.select_adjacent_chat(event.keystroke.key == "down", window, cx);
            cx.stop_propagation();
        } else if command && event.keystroke.key == "n" {
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
    fn queue(&mut self, window: &Window, cx: &mut Context<Self>) -> Div {
        let p = self.palette;
        let timing = queue_presentation::QueueTiming::new(
            self.session.edit.is_some(),
            self.session.state == RunState::Error,
            self.session.queue_paused || self.session.state == RunState::Paused,
            self.session.state == RunState::Running,
        );
        let follow_up_count = self
            .session
            .pending
            .iter()
            .filter(|item| item.lane == Lane::FollowUp)
            .count();
        let reorder_enabled = follow_up_count > 1
            && self.session.edit.is_none()
            && self.queue_operation.is_none()
            && !self.busy
            && !self.loading
            && !self.load_failed
            && !self.edit_recovery.blocked
            && !self.shutting_down;
        let mut panel = div()
            .flex_shrink_0()
            .mx(px(16.))
            .mb(px(8.))
            .p(px(12.))
            .rounded(px(12.))
            .border_1()
            .border_color(p.hairline())
            .bg(rgb(p.sunken))
            .flex()
            .flex_col()
            .gap(px(6.));
        if self.session.pending.is_empty() {
            return div();
        }
        let resume_enabled = self.session.edit.is_none()
            && self.queue_operation.is_none()
            && !self.busy
            && !self.loading
            && !self.load_failed
            && !self.edit_recovery.blocked
            && !self.shutting_down;
        let chat_id = self.record.id.clone();
        // The same source micro weight is used for shaping and both labels.
        let micro_weight = FontWeight::MEDIUM;
        let status_text = timing.header(self.session.pending.len());
        let has_hint = self.queue_open && follow_up_count > 1 && self.session.edit.is_none();
        let has_resume = queue_actions::offers_resume(&self.chat);
        let measure = |text: &str, size: f32, weight: FontWeight| {
            let mut font = gpui::font(if cfg!(target_os = "macos") {
                ".SystemUIFont"
            } else {
                "DejaVu Sans"
            });
            font.weight = weight;
            let run = TextRun {
                len: text.len(),
                font,
                color: rgb(p.ink).into(),
                background_color: None,
                underline: None,
                strikethrough: None,
            };
            f32::from(
                window
                    .text_system()
                    .shape_line(text.to_owned().into(), px(size), &[run], None)
                    .width,
            )
            .ceil()
        };
        let action_width = measure(
            queue_actions::resume_label(&self.chat),
            12.,
            FontWeight::MEDIUM,
        ) + 12.
            + 4.
            + 22.;
        let (status_width, hint_width) = queue_presentation::header_label_widths(
            self.queue_geometry.map_or(self.pane_width, |geometry| {
                geometry.pane_width.min(self.pane_width)
            }),
            measure(&status_text, 10.5, micro_weight),
            has_hint.then(|| measure("Drag to reorder", 10.5, micro_weight)),
            has_resume.then_some(action_width),
        );
        panel = panel.child(
            div()
                .flex()
                .items_center()
                .gap(px(8.))
                .debug_selector(|| "queue-header".to_string())
                .child(
                    self.icon_button(
                        "toggle-queue",
                        if self.queue_open { "down" } else { "chevron" },
                        20.,
                    )
                    .flex_shrink_0()
                    .on_click(cx.listener(|view, _, window, cx| {
                        view.queue_open = !view.queue_open;
                        view.cancel_queue_drag(window, cx);
                        cx.notify();
                    })),
                )
                .child(
                    div()
                        .w(px(status_width))
                        .flex_shrink_0()
                        .debug_selector(|| "queue-status-label".to_string())
                        .text_size(px(10.5))
                        .font_weight(micro_weight)
                        .text_color(rgb(p.secondary))
                        .child(status_text),
                )
                .when(has_hint, |header| {
                    header.child(
                        div()
                            .w(px(hint_width))
                            .flex_shrink_0()
                            .debug_selector(|| "queue-reorder-label".to_string())
                            .text_size(px(10.5))
                            .font_weight(micro_weight)
                            .text_color(rgb(p.tertiary))
                            .child("Drag to reorder"),
                    )
                })
                .child(div().flex_1())
                .when(has_resume, |header| {
                    header.child(
                        div()
                            .id("resume-queue")
                            .debug_selector(|| "queue-resume".to_string())
                            .w(px(action_width))
                            .relative()
                            .flex_shrink_0()
                            .flex()
                            .items_center()
                            .gap(px(4.))
                            .px(px(11.))
                            .py(px(5.))
                            .rounded_full()
                            .bg(p.fill())
                            .text_size(px(12.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(p.ink))
                            .opacity(if resume_enabled { 1. } else { 0.4 })
                            .when(resume_enabled, |button| {
                                button.cursor_pointer().hover(move |d| {
                                    d.bg(rgba(if p.dark { 0xffffff17 } else { 0x00000013 }))
                                })
                            })
                            .when(self.session.edit.is_some(), |button| {
                                button.tooltip(move |_, cx| {
                                    cx.new(|_| queue_actions::ResumeEditHint(p)).into()
                                })
                            })
                            .child(self.icon("play", 12.))
                            .child(queue_actions::resume_label(&self.chat))
                            .child(
                                div()
                                    .absolute()
                                    .inset_0()
                                    .rounded_full()
                                    .border_1()
                                    .border_color(p.hairline()),
                            )
                            .on_click(cx.listener(move |view, _, _, cx| {
                                view.resume_queued(&chat_id, cx);
                                cx.stop_propagation();
                            })),
                    )
                }),
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
        let row_count = ordered.len();
        let mut measured_content_height = sections as f32 * queue_presentation::SECTION_HEIGHT;
        let mut rows = div()
            .id("queue-list")
            .track_scroll(&self.queue_scroll)
            .on_drag_move(cx.listener(
                |view, event: &DragMoveEvent<queue_drag::QueueDrag>, window, cx| {
                    if view.accepts_queue_drag(event.drag(cx)) {
                        view.update_queue_drop_target(event.event.position, cx);
                    } else {
                        view.cancel_queue_drag(window, cx);
                    }
                },
            ))
            .on_drop(
                cx.listener(|view, drag: &queue_drag::QueueDrag, window, cx| {
                    view.drop_queued(drag, window, cx);
                    cx.stop_propagation();
                }),
            )
            .flex_shrink_0()
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
            let row_selector = format!("queue-row-{id}");
            let remove = id.clone();
            let remove_chat = self.record.id.clone();
            let edit_state = self.queue_edit_row_state(&id);
            let owned_row = matches!(
                edit_state,
                queue_edit_controls::QueueEditRowState::Owned { .. }
            );
            let content_width = (self.queue_geometry.map_or(self.pane_width, |geometry| {
                geometry.pane_width.min(self.pane_width)
            }) - 58.)
                .max(0.);
            let preview_text = item
                .text
                .lines()
                .next()
                .unwrap_or("")
                .chars()
                .take(100)
                .collect::<String>();
            let first_word = preview_text.split_whitespace().next().unwrap_or("…");
            let preview_requirement = measure(first_word, 13., FontWeight::NORMAL)
                + if first_word.len() < preview_text.len() {
                    measure("…", 13., FontWeight::NORMAL)
                } else {
                    0.
                };
            let held_plan = (self.show_files
                && matches!(
                    edit_state,
                    queue_edit_controls::QueueEditRowState::Held { .. }
                ))
            .then(|| {
                queue_edit_controls::held_row_plan(
                    content_width,
                    preview_requirement,
                    edit_state.natural_width(window),
                    edit_state.minimum_word_width(window),
                )
            });
            let second_line = held_plan.is_some_and(|plan| plan.second_line);
            let single_budget = (content_width - 90.).max(0.);
            let control_budget = held_plan.map_or_else(
                || {
                    if owned_row {
                        (single_budget - preview_requirement)
                            .max(edit_state.minimum_word_width(window))
                            .min(single_budget)
                    } else {
                        single_budget
                    }
                },
                |plan| plan.controls_width,
            );
            let control_height = edit_state.rendered_height(control_budget, window).max(22.);
            let row_height = if second_line {
                22. + 8. + control_height + 4.
            } else {
                control_height + 4.
            };
            measured_content_height += row_height.max(queue_presentation::ROW_HEIGHT);
            let remove_enabled = !matches!(
                edit_state,
                queue_edit_controls::QueueEditRowState::Held { .. }
            ) && !self.busy
                && !self.loading
                && !self.load_failed
                && !self.edit_recovery.blocked
                && self.queue_operation.is_none()
                && !self.shutting_down;
            let detail = id.clone();
            let promote = id.clone();
            let chat_id = self.record.id.clone();
            let offers_promotion = queue_actions::offers_promotion(&self.chat, &id);
            let drag = if reorder_enabled {
                row.follow_up_number
                    .map(|number| self.queue_drag_payload(&id, number, &item.text))
            } else {
                None
            };
            let insertion = self
                .queue_drag
                .as_ref()
                .and_then(|state| state.target.as_ref())
                .filter(|(target, _)| target == &id)
                .map(|(_, after)| *after);
            let drag_owner = cx.weak_entity();
            let promotion_enabled = self.queue_operation.is_none()
                && !self.busy
                && !self.loading
                && !self.load_failed
                && !self.edit_recovery.blocked
                && !self.shutting_down;
            let primary_selector = format!("queue-primary-{id}");
            let preview_selector = format!("queue-preview-{id}");
            let actions_selector = format!("queue-actions-{id}");
            let primary = div()
                .debug_selector(move || primary_selector)
                .flex()
                .items_center()
                .gap(px(8.))
                .when(second_line, |row| row.w_full().flex_shrink_0())
                .when(!second_line, |row| row.flex_1().min_w_0())
                .child(
                    div()
                        .w(px(14.))
                        .flex_shrink_0()
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
                        .debug_selector(move || preview_selector)
                        .flex_1()
                        .min_w_0()
                        .overflow_hidden()
                        .whitespace_nowrap()
                        .text_ellipsis()
                        .text_color(rgb(if owned_row { p.tertiary } else { p.ink }))
                        .text_size(px(13.))
                        .child(preview_text),
                )
                .child(
                    self.queue_icon_button(
                        SharedString::from(format!("detail-{detail}")),
                        "info",
                        true,
                    )
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .on_click(cx.listener(
                        move |view, event: &ClickEvent, window, cx| {
                            view.open_queue_detail(detail.clone(), event.position(), window, cx);
                            cx.stop_propagation();
                        },
                    )),
                );
            let actions = div()
                .debug_selector(move || actions_selector)
                .flex()
                .items_center()
                .gap(px(8.))
                .flex_shrink_0()
                .when(offers_promotion, |row| {
                    row.child(
                        self.queue_icon_button(
                            queue_actions::promotion_control_id(&promote),
                            "steering",
                            promotion_enabled,
                        )
                        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                        .debug_selector(|| "queue-promote".to_string())
                        .tooltip(move |_, cx| cx.new(|_| queue_actions::PromotionHint(p)).into())
                        .on_click(cx.listener(move |view, _, _, cx| {
                            view.promote_queued(&chat_id, &promote, cx);
                            cx.stop_propagation();
                        })),
                    )
                })
                .child(self.render_queue_edit_controls(
                    &self.record.id,
                    &id,
                    edit_state,
                    control_budget,
                    window,
                    cx,
                ))
                .child(
                    self.queue_icon_button(
                        SharedString::from(format!("remove-{remove}")),
                        "close",
                        remove_enabled,
                    )
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .on_click(cx.listener(move |v, _, _, cx| {
                        v.remove_queued_from_chat(&remove_chat, &remove, cx)
                    })),
                );
            rows = rows.child(
                div()
                    .id(SharedString::from(format!("queue-row-{id}")))
                    .debug_selector(move || row_selector)
                    .relative()
                    .when_some(drag, |row, drag| {
                        row.cursor(CursorStyle::OpenHand).on_drag(
                            drag,
                            move |drag, _, window, cx| {
                                let width = drag_owner
                                    .update(cx, |view, cx| {
                                        let width = view.queue_scroll.bounds().size.width;
                                        view.start_queue_drag(drag, window, cx);
                                        width
                                    })
                                    .unwrap_or(px(240.));
                                cx.new(|_| queue_drag::QueueDragPreview {
                                    drag: drag.clone(),
                                    width,
                                })
                            },
                        )
                    })
                    .when_some(insertion, |row, after| {
                        row.child(
                            div()
                                .absolute()
                                .left_0()
                                .right_0()
                                .h(px(1.))
                                .bg(rgb(p.accent))
                                .when(after, |line| line.bottom_0())
                                .when(!after, |line| line.top_0()),
                        )
                    })
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .when(second_line, |row| row.flex_col().items_start())
                    .min_h(px(queue_presentation::ROW_HEIGHT))
                    .py(px(2.))
                    .flex_shrink_0()
                    .child(primary)
                    .child(actions),
            );
        }
        let room = self
            .queue_geometry
            .map(|geometry| geometry.room())
            .unwrap_or(f32::INFINITY);
        let standard_content = row_count as f32 * queue_presentation::ROW_HEIGHT
            + sections as f32 * queue_presentation::SECTION_HEIGHT;
        let height =
            if measured_content_height.is_finite() && measured_content_height > standard_content {
                queue_presentation::list_height_for_content(measured_content_height, sections, room)
            } else {
                queue_presentation::list_height(row_count, sections, room)
            };
        panel.child(rows.h(px(height)))
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
    fn transcript_input(&self) -> transcript_view::TranscriptInput {
        transcript_view::TranscriptInput {
            controller: Arc::downgrade(&self.controller),
            chat_id: self.record.id.clone(),
            session: self.session.clone(),
            visible_messages: self.visible_messages,
            palette: self.palette,
            pane_width: self.pane_width,
            loading: self.loading,
            load_failed: self.load_failed,
        }
    }
    fn sync_transcript_inputs(&mut self, cx: &mut Context<Self>) {
        if self.session.messages.is_empty() {
            self.transcript = None;
        } else if let Some(view) = self.transcript.clone() {
            let input = self.transcript_input();
            view.update(cx, |view, cx| view.update_inputs(input, cx));
        }
    }
    fn conversation(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Div {
        let p = self.palette;
        let transcript = if self.session.messages.is_empty() {
            // Do not retain a removed/cleared history behind the starter.
            self.transcript = None;
            let mut transcript = div()
                .id("transcript")
                .debug_selector(|| "queue-measured-transcript".into())
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
            transcript.into_any_element()
        } else {
            let input = self.transcript_input();
            let view = if let Some(view) = self.transcript.clone() {
                view.update(cx, |view, cx| view.update_inputs(input, cx));
                view
            } else {
                let parent = cx.entity().downgrade();
                let view = cx.new(|_| transcript_view::TranscriptView::new(parent, input));
                self.transcript = Some(view.clone());
                view
            };
            // Cached views request their outer layout without rendering their
            // child. Preserve the original flexible scroll viewport explicitly.
            AnyView::from(view)
                .cached(StyleRefinement::default().flex_1().min_h_0().w_full())
                .into_any_element()
        };
        let queue = self.queue(window, cx);
        let field_height = self
            .composer
            .update(cx, |editor, _| {
                editor.measured_content_height((self.pane_width - 34.).max(1.), window)
            })
            .clamp(44., 240.);
        let mut field = div()
            .debug_selector(|| "queue-measured-field".into())
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
            let cancel_chat = self.record.id.clone();
            bar = bar.child(
                self.button("cancel-edit", "Cancel")
                    .opacity(if self.can_cancel_owned_edit() {
                        1.
                    } else {
                        0.45
                    })
                    .on_click(
                        cx.listener(move |v, _, _, cx| v.cancel_owned_edit(&cancel_chat, cx)),
                    ),
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
        if self.session.retry.is_some() && self.session.state != RunState::Running {
            bar = bar.child(
                self.button("retry", "Retry")
                    .opacity(if self.edit_recovery.blocked { 0.45 } else { 1. })
                    .on_click(cx.listener(|v, _, _, cx| {
                        v.command(
                            cx,
                            None,
                            false,
                            |controller| controller.retry(),
                            |_, (), _| {},
                        )
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
            && !self.edit_recovery.blocked
            && !self.loading
            && !self.shutting_down
            && !self.composer.read(cx).text().trim().is_empty();
        bar = bar.child(
            div()
                .id("send")
                .debug_selector(|| "composer-send".to_string())
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
            .debug_selector(|| "queue-measured-composer".into())
            .mx(px(16.))
            .mt(px(queue_geometry::COMPOSER_TOP))
            .mb(px(queue_geometry::COMPOSER_BOTTOM))
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
        let geometry_owner = cx.weak_entity();
        let geometry_chat = self.record.id.clone();
        let geometry_binding = self.window_binding;
        let view = div()
            .relative()
            .debug_selector(|| "queue-measured-pane".into())
            .flex_1()
            .min_w_0()
            .min_h_0()
            .flex()
            .flex_col()
            .bg(rgb(p.content))
            .on_children_prepainted(move |bounds, window, cx| {
                if let Some(geometry) = queue_geometry::QueueGeometry::from_children(&bounds) {
                    let owner = geometry_owner.clone();
                    let chat = geometry_chat.clone();
                    window.defer(cx, move |_, cx| {
                        let _ = owner.update(cx, |view, cx| {
                            view.record_queue_geometry(&chat, geometry_binding, geometry, cx)
                        });
                    });
                }
            })
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
        view.child(composer)
            .child(
                div()
                    .debug_selector(|| "queue-measured-footer".into())
                    .flex_shrink_0()
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
            .child(div().absolute().inset_0())
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
        for record in self.visible_sidebar_records(cx) {
            let chat = self.chat_ref(&record.id);
            let title = self.sidebar_title(record);
            let id = record.id.clone();
            let selected = id == self.record.id;
            let menu_id = id.clone();
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
                    .on_mouse_down(
                        MouseButton::Right,
                        cx.listener(move |view, event: &MouseDownEvent, window, cx| {
                            view.open_sidebar_menu(&menu_id, event.position, window, cx);
                            cx.stop_propagation();
                        }),
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
                                    .flex()
                                    .items_center()
                                    .gap(px(4.))
                                    .min_w_0()
                                    .child(
                                        div()
                                            .min_w_0()
                                            .text_size(px(13.))
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .truncate()
                                            .child(title.to_owned()),
                                    )
                                    .when(record.pinned_at.is_some(), |row| {
                                        row.child(self.icon("pin", 9.).text_color(rgb(p.tertiary)))
                                    }),
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
                cx.listener(|view, _, window, cx| {
                    view.finish_resize(cx);
                    cx.defer_in(window, |view, _, cx| view.clear_queue_drag_state(cx));
                }),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(|view, _, window, cx| {
                    view.finish_resize(cx);
                    cx.defer_in(window, |view, _, cx| view.clear_queue_drag_state(cx));
                }),
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
        if let Some(menu) = self.sidebar_menu_element(cx) {
            element = element.child(menu);
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
    #[cfg(feature = "native-lifecycle-smoke")]
    native_smoke::validate_launch()?;
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
        let record = ChatRecord::new(snapshot.id, snapshot.title, session);
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
            workspace_lifetime::WorkspaceLifetime::launch(
                LaunchState {
                    controller,
                    project,
                    workspace,
                    record,
                    draft,
                    pending,
                },
                cx,
            )
            .expect("Could not create native GPUI window");
            cx.on_window_closed(|cx| {
                if cx.windows().is_empty() {
                    // Leave the native close callback before quitting. X11
                    // still owns a backend borrow during this notification.
                    cx.spawn(async move |cx| {
                        let _ = cx.update(|cx| {
                            if cx.windows().is_empty() {
                                cx.quit();
                            }
                        });
                    })
                    .detach();
                }
            })
            .detach();
            cx.activate(true);
            #[cfg(feature = "native-lifecycle-smoke")]
            native_smoke::install(cx);
        });
    Ok(())
}
