#[cfg(any(target_os = "macos", test))]
mod application_menus;
mod assets;
#[cfg(all(feature = "synthetic-authority", debug_assertions))]
mod attachment_fixture;
mod chat;
mod chat_load;
mod chat_navigation;
mod chat_organization;
mod chat_tool_mode;
mod compaction_actions;
mod composer_attachments;
mod composer_skills;
mod connection_settings_controller;
mod connection_settings_view;
mod context_inspector;
mod conversation_content;
mod conversation_content_controller;
mod conversation_content_view;
mod draft_status;
mod file_tab;
mod launch_authority;
mod layout;
mod mcp_inspector_controller;
mod mcp_inspector_host;
mod mcp_inspector_view;
#[cfg(any(target_os = "macos", test))]
mod native_menu;
#[cfg(feature = "native-lifecycle-smoke")]
mod native_smoke;
mod notifications;
mod project_host;
mod project_manager_controller;
mod project_manager_view;
mod project_skills_controller;
mod project_skills_view;
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
mod saved_runtime_adapter;
mod shutdown_barrier;
mod sidebar_actions;
mod sidebar_activity;
mod sidebar_cache_cleanup;
mod sidebar_chat_delete;
mod sidebar_chat_rename;
mod sidebar_chats;
mod sidebar_inspection;
mod sidebar_read_state;
mod sidebar_run_state;
mod sidebar_search_controller;
mod sidebar_search_reveal;
mod sidebar_search_state;
#[cfg(test)]
mod sidebar_title_tests;
mod stop_shortcut;
#[cfg(all(debug_assertions, target_os = "linux", feature = "synthetic-authority"))]
mod synthetic_sidebar_fixture;
mod theme;
mod tool_timing_presentation;
mod topics;
mod topics_view;
mod transcript_actions;
#[cfg(test)]
#[path = "../../../benches/transcript.rs"]
mod transcript_benchmark;
mod transcript_find_controller;
mod transcript_find_numbered;
mod transcript_find_presentation;
mod transcript_find_search;
mod transcript_find_state;
mod transcript_skills;
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
    attachment_picker: Option<composer_attachments::PickerOperation>,
    chat_models: composer_attachments::ChatModelListing,
    skill_picker: Option<project_skills_view::SkillPicker>,
    inactive: BTreeMap<String, ChatState>,
    records: Vec<ChatRecord>,
    topics: Vec<bello_agent_core::workspace::TopicRecord>,
    topics_revision: u64,
    launch_topic_reveal: Option<String>,
    topic_write: Option<topics::TopicWrite>,
    topic_panel: Option<topics_view::TopicPanel>,
    workspace: Arc<Mutex<WorkspaceStore>>,
    selection_revision: u64,
    sidebar_selection_pending: Option<u64>,
    shutting_down: bool,
    close_ready: bool,
    shutdown_operation: Option<uuid::Uuid>,
    organization_operations: BTreeMap<String, chat_organization::OrganizationQueue>,
    organization_errors: BTreeMap<String, chat_organization::OrganizationError>,
    organization_drain_scheduled: bool,
    organization_window: Option<AnyWindowHandle>,
    archive_cancel_deferrals: queue_cancel::ArchiveCancelDeferrals,
    known_catalog_uncertainty: bool,
    blocked_organization_count: usize,
    navigation_generation: u64,
    show_archived: bool,
    launch_archive_reveal: bool,
    archive_visibility_revision: u64,
    archive_visibility_writes: usize,
    archive_visibility_errors: BTreeMap<String, String>,
    cancelled_prompt_key: Option<String>,
    sidebar_menu: Option<sidebar_actions::SidebarMenu>,
    sidebar_chats: sidebar_chats::SidebarChats,
    sidebar_activity_hold: sidebar_activity::SidebarActivityHold,
    sidebar_run_states: sidebar_run_state::SidebarRunStates,
    sidebar_search: sidebar_search_controller::SidebarSearch,
    sidebar_search_reveal: Option<sidebar_search_reveal::PendingReveal>,
    load_retirement: chat_load::LoadRetirementOwner,
    read_states: sidebar_read_state::SharedReadStates,
    read_write_inflight: bool,
    read_surface_ready: bool,
    read_manual_operations: BTreeMap<String, uuid::Uuid>,
    compaction_menu: Option<compaction_actions::CompactionMenu>,
    conversation_content: Option<conversation_content_view::ContentSheet>,
    transcript_find: Option<transcript_find_controller::FindBar>,
    #[cfg(not(target_os = "macos"))]
    root_focus: FocusHandle,
    #[cfg(not(target_os = "macos"))]
    sidebar_popup_focus: FocusHandle,
    #[cfg(test)]
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
    projects: project_manager_controller::ProjectManagerController,
    connections: connection_settings_controller::ConnectionSettingsController,
    mcp: mcp_inspector_controller::McpInspectorController,
    #[cfg(all(test, feature = "synthetic-authority"))]
    legacy_configuration: Option<Arc<bello_agent_core::runtime::Configuration>>,
    runtime: saved_runtime_adapter::AppRuntime,
    inspector_windows: Vec<context_inspector::InspectorWindow>,
    chat_mode_operations: BTreeMap<String, uuid::Uuid>,
    chat_mode_blocked: std::collections::BTreeSet<String>,
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
        if !cx.has_global::<notifications::Notifications>() {
            cx.set_global(notifications::Notifications::new(None));
        }
        let palette = current_palette(window);
        let mut state = workspace.lock().expect("workspace lock").snapshot();
        state
            .topics
            .sort_by(bello_agent_core::workspace::TopicRecord::sidebar_cmp);
        #[cfg(test)]
        let chat_directory = workspace
            .lock()
            .expect("workspace lock")
            .chat_path(&record.id)
            .expect("valid chat id")
            .parent()
            .unwrap()
            .to_owned();
        let read_states = sidebar_read_state::ReadCoordinator::restore(&state);
        let mut records = state.chats.clone();
        // Legacy catalogs appended records in creation order. Recover a stable
        // ordering for presentation without rewriting those files on open.
        for (index, record) in records.iter_mut().enumerate() {
            record.sidebar_order.get_or_insert(index as u64 + 1);
        }
        let mut record = records
            .iter()
            .find(|item| item.id == record.id)
            .cloned()
            .unwrap_or(record);
        if pending && controller.is_never_materialized() {
            record.materialization = bello_agent_core::workspace::ChatMaterialization::Pending;
        }
        if !records.iter().any(|item| item.id == record.id) {
            records.insert(0, record.clone());
        }
        let layout_store = Arc::new(layout::LayoutStore::new(
            record.snapshot.parent().unwrap().join("layout.json"),
        ));
        let layout = layout_store.load();
        let legacy_configuration = cx
            .try_global::<connection_settings_controller::LaunchLegacyConfiguration>()
            .map(|source| source.0.clone())
            .unwrap_or_else(|| {
                if record.connection_id.is_none() {
                    controller.configuration()
                } else {
                    None
                }
            });
        let cancel_receipt = state.queued_cancellations.get(&record.id).cloned();
        let mut chat = ChatState::new(
            controller,
            crate::chat::ChatSource {
                record,
                workspace: workspace.clone(),
                read_states: read_states.clone(),
            },
            chat::RestoredDraft {
                draft,
                cancellation: cancel_receipt.as_ref(),
            },
            pending,
            palette,
            window,
            cx,
        );
        if chat.record.connection_id.is_some() && !chat.controller.configured() {
            chat.error = Some("This saved connection or trusted project is unavailable. History and drafts are retained; choose a saved connection after confirming the project.".into());
            chat.load_failed = !chat.controller.is_persistent();
        }
        if !pending
            && !chat.controller.is_persistent()
            && chat.record.materialization
                == bello_agent_core::workspace::ChatMaterialization::CheckpointRequired
        {
            chat.load_failed = true;
            chat.error = Some("The saved checkpoint is unavailable. Recover any retained submission into the draft below; no empty session will replace the missing history.".into());
        }
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
            // IME unmark can notify without emitting an EditorEvent. Observe
            // the retained filter so identical committed bytes still debounce.
            cx.observe(&filter, |view, _, cx| {
                view.refresh_sidebar_search(cx);
                cx.notify();
            }),
            cx.subscribe(&filter, |view, _, _, cx| {
                view.refresh_sidebar_search(cx);
                cx.notify();
            }),
            // Notify the retained transcript before GPUI starts drawing. A
            // notify issued from Render is too late for that frame's cache key.
            cx.observe_self(|view, cx| view.sync_transcript_inputs(cx)),
            cx.observe_self(|view, cx| view.request_organization_drain(cx)),
            cx.observe_self(|view, cx| view.request_activity_drain(cx)),
        ];
        let workbench = cx.new(|cx| WorkbenchView::new(project.clone(), window, cx));
        workbench.update(cx, |view, cx| {
            view.set_appearance(Self::workbench_style(palette), cx);
            view.set_panel(WorkbenchPanel::Changes, cx);
        });
        let quick_open = cx.new(|cx| QuickOpenView::new(project.clone(), palette, window, cx));
        let projects =
            project_manager_controller::ProjectManagerController::new(project.clone(), palette, cx);
        let connections =
            connection_settings_controller::ConnectionSettingsController::new(palette, cx);
        let mcp = mcp_inspector_controller::McpInspectorController::new(
            palette,
            connections.authority().clone(),
            connections.presentation.mode.is_fixture(),
            cx,
        );
        let runtime = saved_runtime_adapter::AppRuntime::for_launch(
            connections.authority().as_ref().clone(),
            workspace.clone(),
            project.clone(),
            connections.presentation.mode,
            legacy_configuration.clone(),
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
        let initial_view = cx.weak_entity();
        let initial_controller = Arc::downgrade(&chat.controller);
        let initial_chat = chat.record.id.clone();
        let native_startup = connections.presentation.mode
            == launch_authority::AuthorityMode::Native
            && !pending
            && !chat.controller.is_persistent();
        cx.defer(move |cx| {
            let _ = initial_view.update(cx, |view, cx| {
                if native_startup {
                    view.load_chat(&initial_chat, cx);
                    return;
                }
                let Some(chat) = view
                    .chat_ref(&initial_chat)
                    .filter(|chat| initial_controller.ptr_eq(&Arc::downgrade(&chat.controller)))
                else {
                    return;
                };
                if chat.controller.is_persistent() {
                    let snapshot = chat.session.clone();
                    view.receive_snapshot(&initial_chat, &initial_controller, snapshot, cx);
                }
                view.reconcile_edit(&initial_chat, cx);
                view.reconcile_intents(&initial_chat, cx);
            });
        });
        // Match WorkspaceSelection's selected-chat composer focus. The source
        // Open File command is window-wide; it must work before any mouse click.
        if chat.record.archived_at.is_none() {
            chat.composer.read(cx).focus(window);
        }
        #[cfg(not(target_os = "macos"))]
        let root_focus = cx.focus_handle();
        #[cfg(not(target_os = "macos"))]
        if chat.record.archived_at.is_some() {
            root_focus.focus(window);
        }
        let launch_archive_reveal = chat.record.archived_at.is_some() && !state.show_archived;
        let launch_topic_reveal = state.effective_topic_id(&chat.record).map(str::to_owned);
        let chats_directory = workspace
            .lock()
            .expect("workspace lock")
            .chat_path(&chat.record.id)
            .ok()
            .and_then(|path| path.parent().map(std::path::Path::to_owned));
        let sidebar_chats = sidebar_chats::SidebarChats::restore(
            &state.drafts,
            &records,
            &chat.record,
            chats_directory.as_deref(),
        );
        let mut view = Self {
            attachment_picker: None,
            chat_models: Default::default(),
            skill_picker: None,
            chat,
            inactive: BTreeMap::new(),
            records,
            topics: state.topics.clone(),
            topics_revision: state.revision,
            launch_topic_reveal,
            topic_write: None,
            topic_panel: None,
            #[cfg(test)]
            chat_directory,
            unloaded_drafts: state.drafts,
            recoveries: state.intents,
            queued_cancellations: state.queued_cancellations,
            workspace,
            selection_revision: state.selection_revision,
            sidebar_selection_pending: None,
            shutting_down: false,
            close_ready: false,
            shutdown_operation: None,
            organization_operations: BTreeMap::new(),
            organization_errors: BTreeMap::new(),
            organization_drain_scheduled: false,
            organization_window: Some(window.window_handle()),
            archive_cancel_deferrals: Default::default(),
            known_catalog_uncertainty: false,
            blocked_organization_count: 0,
            navigation_generation: 0,
            show_archived: state.show_archived,
            launch_archive_reveal,
            archive_visibility_revision: state.archive_visibility_revision,
            archive_visibility_writes: 0,
            archive_visibility_errors: BTreeMap::new(),
            cancelled_prompt_key: None,
            sidebar_menu: None,
            sidebar_chats,
            sidebar_activity_hold: Default::default(),
            sidebar_run_states: Default::default(),
            sidebar_search: Default::default(),
            sidebar_search_reveal: None,
            load_retirement: Default::default(),
            read_states,
            read_write_inflight: false,
            read_surface_ready: false,
            read_manual_operations: BTreeMap::new(),
            compaction_menu: None,
            conversation_content: None,
            transcript_find: None,
            #[cfg(not(target_os = "macos"))]
            root_focus,
            #[cfg(not(target_os = "macos"))]
            sidebar_popup_focus: cx.focus_handle(),
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
            projects,
            connections,
            mcp,
            #[cfg(all(test, feature = "synthetic-authority"))]
            legacy_configuration,
            runtime,
            inspector_windows: Vec::new(),
            chat_mode_operations: BTreeMap::new(),
            chat_mode_blocked: std::collections::BTreeSet::new(),
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
        self.sidebar_search.cancel();
        self.sidebar_search_reveal = None;
        self.read_surface_ready = false;
        self.close_context_inspectors(cx);
        self.topic_panel = None;
        self.attachment_picker = None;
        self.skill_picker = None;
        self.cancel_queue_drag(window, cx);
        self.queue_geometry = None;
        self.sidebar_menu = None;
        self.compaction_menu = None;
        self.conversation_content = None;
        self.clear_transcript_find(cx);
        if let Some(transcript) = &self.transcript {
            transcript.update(cx, |view, _| view.clear_content_reveal());
        }
        let binding = workspace_lifetime::WindowBinding::new(window.window_handle().window_id());
        self.window_binding = Some(binding);
        self.organization_window = Some(window.window_handle());
        self.bind_activity_window(window, cx);
        self.bind_projects(window, cx);
        self.bind_connections(window, cx);
        self.bind_mcp(window, cx);
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
            self.focus_visible_composer(window, cx);
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
        if self.actor_mutation_blocked(&self.record.id)
            || self.busy
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
        let identity_workspace = workspace.clone();
        let read_record = self.record.clone();
        let read_states = self.read_states.clone();
        let flush_id = id.clone();
        let identity_controller = controller.clone();
        let identity_project = self.project.clone();
        self.composer
            .update(cx, |editor, cx| editor.set_read_only(true, cx));
        let task = cx.background_executor().spawn(async move {
            let flushed = if let Some(draft) = flush {
                let revision = draft.revision;
                let holds = draft.holds_unsent();
                let saved = chat_organization::catalog_operation(&workspace, |store| {
                    store.flush_draft_exact(&flush_id, draft)
                });
                if let Err(error) = saved.result {
                    return (None, Err(error), saved.uncertain);
                }
                Some((revision, holds))
            } else {
                None
            };
            let baseline = chat_organization::catalog_operation(&workspace, |store| {
                // Existing command routes can Resume/Retry or release queued work.
                crate::sidebar_read_state::prepare_admission(
                    &read_states,
                    store,
                    &read_record,
                    &controller,
                )
            });
            if let Err(error) = baseline.result {
                return (flushed, Err(error), baseline.uncertain);
            }
            (flushed, command(controller), false)
        });
        cx.spawn(async move |view, cx| {
            let (flushed, result, catalog_uncertain) = task.await;
            let failed = result.is_err();
            let _ = view.update(cx, move |view, cx| {
                if view.project != identity_project
                    || !Arc::ptr_eq(&view.workspace, &identity_workspace)
                {
                    return;
                }
                view.observe_catalog_uncertainty(catalog_uncertain, cx);
                if view
                    .chat_ref(&id)
                    .is_none_or(|chat| !Arc::ptr_eq(&chat.controller, &identity_controller))
                {
                    return;
                }
                let archived = view.chat_is_archived(&id);
                if let Some((_, holds)) = flushed {
                    view.note_draft_mark(&id, holds);
                }
                if let Some(chat) = view.chat_mut(&id) {
                    if let Some((revision, _)) = flushed {
                        chat.draft_save_status.confirm(revision, &mut chat.error);
                    }
                    chat.busy = false;
                    chat.composer
                        .update(cx, |editor, cx| editor.set_read_only(archived, cx));
                    chat.session = chat.controller.snapshot_shared();
                    match result {
                        Ok(value) => apply(chat, value, cx),
                        Err(error) => {
                            chat.error =
                                Some(chat_organization::catalog_error(&error, catalog_uncertain))
                        }
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
        if outcome == "saved" && !self.composer_has_input(cx) {
            self.error = Some("Type the message, or Cancel to keep it as it was.".into());
            cx.notify();
            return;
        }
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
                view.attachments = std::mem::take(&mut view.draft_before_edit_attachments);
                view.skills = std::mem::take(&mut view.draft_before_edit_skills);
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
                    view.attachments = std::mem::take(&mut view.draft_before_edit_attachments);
                    view.skills = std::mem::take(&mut view.draft_before_edit_skills);
                    view.composer
                        .update(cx, |editor, cx| editor.set_text(draft, cx));
                }
            },
        );
    }
    fn request_close(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if self.mcp.busy() {
            self.error = Some("Wait for the MCP operation to settle before closing.".into());
            cx.notify();
            return false;
        }
        if self.mcp.open || self.mcp.view.read(cx).dirty(cx) {
            if !self.mcp.open {
                self.open_mcp(window, cx);
            }
            self.request_mcp_close(cx);
            return false;
        }
        if self.connections.operation.is_some() || !self.connections.switches.is_empty() {
            self.error = Some("Wait for connection changes to finish before closing.".into());
            cx.notify();
            return false;
        }
        if self.connections.open || self.connections.presentation.dirty {
            if !self.connections.open {
                self.open_connections(window, cx);
            }
            self.request_connection_close(window, cx);
            return false;
        }
        if !self.chat_mode_operations.is_empty() {
            self.error =
                Some("Wait for the chat tool mode change to finish before closing.".into());
            cx.notify();
            return false;
        }
        if self.projects.operation.is_some() {
            self.error =
                Some("Wait for the project folder change to finish before closing.".into());
            self.projects.presentation.notice = Some(project_manager_view::ProjectManagerNotice {
                text: "Wait for the project folder change to finish before closing.".into(),
                is_error: true,
            });
            self.projects.publish(cx);
            return false;
        }
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
        if !self.advance_navigation(cx) {
            return;
        }
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
        if !self.advance_navigation(cx) {
            return;
        }
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
        if !self.advance_navigation(cx) {
            return;
        }
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
            self.focus_visible_composer(window, cx);
        }
        cx.notify();
    }
    fn close_selected_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.advance_navigation(cx) {
            return;
        }
        if let Some(id) = self.selected_file {
            if let Some(entry) = self.files.iter().find(|entry| entry.id == id) {
                entry.view.update(cx, |view, cx| view.request_close(cx));
            }
        } else {
            self.changes_open = false;
            self.selected_file = self.files.last().map(|entry| entry.id);
            self.show_files = !self.files.is_empty();
            if !self.show_files {
                self.focus_visible_composer(window, cx);
            }
            cx.notify();
        }
    }
    fn global_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if self.conversation_content.is_some() {
            self.conversation_content_key(event, window, cx);
            return;
        }
        if self.skill_picker.is_some() {
            self.skill_picker_key(event, window, cx);
            return;
        }
        if self.mcp.open {
            if self
                .mcp
                .view
                .update(cx, |view, cx| view.key(event, window, cx))
            {
                if matches!(event.keystroke.key.as_str(), "enter" | "escape" | "space") {
                    self.cancelled_prompt_key = Some(event.keystroke.key.clone());
                }
                cx.stop_propagation();
            }
            return;
        }
        if self.compaction_menu_key(event, cx) {
            self.cancelled_prompt_key = Some(event.keystroke.key.clone());
            cx.stop_propagation();
            return;
        }
        // Preserve a consumed menu/dialog press, even if the menu or file pane
        // closes or focus changes before a repeat. A fresh press owns its
        // normal behavior. Native macOS/Wayland report repeats via is_held;
        // pinned GPUI X11 does not, so physical X11 repeat protection is limited.
        if self.cancelled_prompt_key.as_deref() == Some(event.keystroke.key.as_str()) {
            if event.is_held {
                cx.stop_propagation();
                return;
            }
            // A different fresh key must not rearm a still-held confirmation.
            self.cancelled_prompt_key = None;
        }
        if self.topic_panel.is_some() {
            self.topics_key(event, window, cx);
            return;
        }
        if self.sidebar_chats.modal_open() {
            self.sidebar_chats_key(event, window, cx);
            return;
        }
        if self.connections.view.read(cx).is_open() {
            if self
                .connections
                .view
                .update(cx, |view, cx| view.key(event, window, cx))
            {
                cx.stop_propagation();
            }
            return;
        }
        if self.connections.picker {
            self.connection_picker_key(event, window, cx);
            return;
        }
        if self.projects.view.read(cx).is_open() {
            // Modal ownership is decided before routing the key. Dismissal or
            // an unfocused Enter must never fall through to composer Send.
            self.projects
                .view
                .update(cx, |view, cx| view.key(event, window, cx));
            let command = event.keystroke.modifiers.platform
                || (cfg!(target_os = "linux") && event.keystroke.modifiers.control);
            if matches!(event.keystroke.key.as_str(), "enter" | "escape" | "space")
                || (command && event.keystroke.key == "w")
            {
                self.cancelled_prompt_key = Some(event.keystroke.key.clone());
            }
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
            if event.keystroke.key == "enter" {
                self.cancelled_prompt_key = Some(event.keystroke.key.clone());
            }
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
        if self.transcript_find_key(event, window, cx) {
            return;
        }
        let navigation_command = if cfg!(target_os = "macos") {
            mods.platform && !mods.control
        } else {
            mods.control && !mods.platform
        };
        if navigation_command
            && !mods.alt
            && !mods.shift
            && !mods.function
            && event.keystroke.key == "."
        {
            self.stop_from_shortcut(window, cx);
            cx.stop_propagation();
        } else if navigation_command
            && mods.alt
            && !mods.shift
            && matches!(event.keystroke.key.as_str(), "up" | "down")
        {
            self.select_adjacent_chat(event.keystroke.key == "down", window, cx);
            cx.stop_propagation();
        } else if cfg!(target_os = "macos")
            && mods.platform
            && mods.control
            && !mods.alt
            && !mods.shift
            && matches!(event.keystroke.key.as_str(), "left" | "right")
        {
            // Swift's Widen/Narrow Sidebar (⌃⌘→/⌃⌘←). AppKit's menu reaches
            // these before a text view; take them before the editor here.
            #[cfg(any(target_os = "macos", test))]
            self.adjust_sidebar(
                if event.keystroke.key == "right" {
                    application_menus::SIDEBAR_STEP
                } else {
                    -application_menus::SIDEBAR_STEP
                },
                cx,
            );
            cx.stop_propagation();
        } else if navigation_command
            && mods.shift
            && !mods.alt
            && !mods.function
            && event.keystroke.key == "g"
        {
            // PiApp's Changes and History command opens/reuses the tab even
            // from editable tab text; it is not a focused-chat command. Keep
            // the existing Rust dirty-file safety prompt visible until resolved.
            if !self
                .files
                .iter()
                .any(|entry| entry.view.read(cx).has_close_prompt())
            {
                self.open_changes(cx);
            }
            cx.stop_propagation();
        } else if command && event.keystroke.key == "n" {
            self.new_chat(window, cx);
            cx.stop_propagation();
        } else if command && event.keystroke.key == "p" {
            if !self.advance_navigation(cx) {
                return;
            }
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
                        if !view.advance_navigation(cx) {
                            return;
                        }
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
                                if !view.advance_navigation(cx) {
                                    return;
                                }
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
                        if !view.advance_navigation(cx) {
                            return;
                        }
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
            .debug_selector(|| "adjacent-pane".into())
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
                                    if !view.advance_navigation(cx) {
                                        return;
                                    }
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
                                    if !view.advance_navigation(cx) {
                                        return;
                                    }
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
        self.save_layout(cx);
    }
    /// Store the current layout, as ending a sidebar or pane drag does.
    fn save_layout(&mut self, cx: &mut Context<Self>) {
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
    /// The chat's connection by its saved name, as Swift's starter card
    /// names it.
    fn connection_label(&self) -> String {
        self.controller
            .profile()
            .map(|profile| self.connections.name_of(&profile.id).unwrap_or(profile.id))
            .unwrap_or_else(|| "No connection".into())
    }
    /// Swift's `FooterNotice`: an info symbol and the notice in secondary
    /// caption type from the trailing edge, cut with "…" to the room the row
    /// leaves (at most 640), whole in its help.
    fn footer_notice(&self, notice: String) -> Div {
        let (help, palette) = (notice.clone(), self.palette);
        div().flex_1().min_w_0().flex().justify_end().child(
            div()
                .id("footer-notice")
                .debug_selector(|| "footer-notice".into())
                .flex()
                .items_center()
                .gap(px(5.))
                .min_w_0()
                .max_w(px(640.))
                .text_size(px(11.5))
                .text_color(rgb(self.palette.secondary))
                .child(self.icon("info", 10.5).flex_none())
                .child(div().min_w_0().truncate().child(notice))
                .tooltip(move |_, cx| {
                    cx.new(|_| composer_attachments::TextHint {
                        text: help.clone(),
                        palette,
                    })
                    .into()
                }),
        )
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
        let reorder_enabled = !self.actor_mutation_blocked(&self.record.id)
            && follow_up_count > 1
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
        let resume_enabled = self.controller.configured()
            && !self.actor_mutation_blocked(&self.record.id)
            && self.session.edit.is_none()
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
        let has_hint = reorder_enabled
            && self.queue_open
            && follow_up_count > 1
            && self.session.edit.is_none();
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
            let item_label = composer_skills::submission_label(item);
            let preview_text = item_label
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
            let remove_enabled = !self.actor_mutation_blocked(&self.record.id)
                && !matches!(
                    edit_state,
                    queue_edit_controls::QueueEditRowState::Held { .. }
                )
                && !self.busy
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
                    .map(|number| self.queue_drag_payload(&id, number, &item_label))
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
            let promotion_enabled = !self.actor_mutation_blocked(&self.record.id)
                && self.queue_operation.is_none()
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
            self.transcript.as_ref(),
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
            if restore_focus
                && self.record.id == key.chat_id
                && !self.chat_is_archived(&key.chat_id)
                && detail.restore_focus(self.transcript.as_ref(), window, cx)
                && !self
                    .transcript
                    .as_ref()
                    .is_some_and(|view| view.read(cx).focus_fallback(window))
            {
                self.composer.read(cx).focus(window);
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
                        .child(self.badge(self.connection_label(), "antenna"))
                        .child(
                            self.badge(
                                self.controller
                                    .profile()
                                    .map(|v| v.model_id.clone())
                                    .unwrap_or_else(|| "catalog default".into()),
                                "cpu",
                            ),
                        )
                        .child(
                            self.badge(
                                saved_runtime_adapter::tool_runtime_label(
                                    &self.controller,
                                    self.connections.presentation.mode,
                                    self.record.tool_mode,
                                )
                                .into(),
                                "pencil",
                            ),
                        ),
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
            find_binding: self
                .display_find_binding
                .as_ref()
                .filter(|binding| Arc::ptr_eq(&self.session, &binding.session_shared()))
                .cloned(),
        }
    }
    fn sync_transcript_inputs(&mut self, cx: &mut Context<Self>) {
        self.refresh_find_content(cx);
        if self.session.messages.is_empty() {
            self.transcript = None;
        } else if let Some(view) = self.transcript.clone() {
            let input = self.transcript_input();
            view.update(cx, |view, cx| view.update_inputs(input, cx));
        }
    }
    fn conversation(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Div {
        let p = self.palette;
        let inspector_target = self.context_inspector_target();
        let content_target = conversation_content_controller::Target::capture(self);
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
        // Keep the aggregate first slot stable for queue geometry.
        let transcript = div()
            .flex_1()
            .min_w_0()
            .min_h_0()
            .w_full()
            .flex()
            .flex_col()
            .children(self.find_bar_element(cx))
            .child(transcript);
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
                cx.listener(|view, _, window, cx| view.focus_visible_composer(window, cx)),
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
            .flex_wrap()
            .items_center()
            .gap(px(4.))
            .px(px(10.))
            .pb(px(8.))
            .child(
                self.icon_button("attach-image", "photo", 28.)
                    .bg(p.fill())
                    .opacity(if self.can_attach_images() { 1. } else { 0.45 })
                    .on_click(cx.listener(|view, _, window, cx| view.choose_images(window, cx))),
            )
            .child(
                self.icon_button("skills", "command", 28.)
                    .debug_selector(|| "skills-open".into())
                    .bg(p.fill())
                    .opacity(if self.can_choose_skills() { 1. } else { 0.45 })
                    .on_click(
                        cx.listener(|view, _, window, cx| view.open_skill_picker(window, cx)),
                    ),
            )
            .child(div().flex_1());
        if self.load_retirement.occupied() {
            bar = bar.child(
                self.button("retry-workspace-load-cleanup", "Retry workspace cleanup")
                    .on_click(cx.listener(|view, _, _, cx| view.retry_workspace_load_cleanup(cx))),
            );
        }
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
                .opacity(
                    if self.actor_mutation_blocked(&self.record.id)
                        || self.busy
                        || self.editing.is_some()
                        || !self.composer_has_input(cx)
                    {
                        0.45
                    } else {
                        1.
                    },
                )
                .on_click(cx.listener(|v, _, _, cx| v.submit(Lane::Steering, cx))),
            );
        }
        if self.session.retry.is_some() && self.session.state != RunState::Running {
            bar = bar.child(
                self.button("retry", "Retry")
                    .opacity(
                        if !self.controller.configured()
                            || self.edit_recovery.blocked
                            || self.actor_mutation_blocked(&self.record.id)
                        {
                            0.45
                        } else {
                            1.
                        },
                    )
                    .on_click(cx.listener(|v, _, _, cx| {
                        if !v.controller.configured() {
                            return;
                        }
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
            .child(
                self.icon_button("actions", "dots", 28.)
                    .debug_selector(|| "conversation-actions-open".into())
                    .on_click(cx.listener(|view, event: &ClickEvent, _, cx| {
                        view.open_compaction_menu(event.position(), cx)
                    })),
            );
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
        let connection_choices = self.connections.choices();
        if connection_choices.len() > 1
            || !self.controller.configured()
            || (self.record.connection_id.is_none() && !connection_choices.is_empty())
        {
            let name = connection_choices
                .into_iter()
                .find(|p| Some(&p.profile.id) == self.record.connection_id.as_ref())
                .map(|p| p.name)
                .unwrap_or_else(|| "No saved connection".into());
            let choice = div()
                .id("session-connection-picker")
                .debug_selector(|| "session-connection-picker".into())
                .flex()
                .flex_shrink_0()
                .items_center()
                .gap(px(5.))
                .px(px(7.))
                .py(px(4.))
                .rounded_full()
                .bg(p.fill())
                .text_size(px(12.))
                .text_color(rgb(p.secondary))
                .child(self.icon("antenna", 11.))
                .when(!icons, |choice| {
                    choice.child(
                        div()
                            .max_w(px(if compact { 90. } else { 150. }))
                            .truncate()
                            .child(name),
                    )
                })
                .child(self.icon("down", 9.))
                .on_click(
                    cx.listener(|view, _, window, cx| view.open_connection_picker(window, cx)),
                );
            bar = bar.child(choice);
        }
        bar = bar
            .child(model_pill)
            .child(effort_pill.child(self.icon("down", 9.)));
        let can_send = self.controller.configured()
            && !self.load_failed
            && !self.actor_mutation_blocked(&self.record.id)
            && !self.busy
            && !self.edit_recovery.blocked
            && !self.loading
            && !self.shutting_down
            && !self.has_pending_cancel(&self.record.id)
            && self.queue_operation.is_none()
            && self.composer_has_input(cx);
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
                        v.stop_current_run(cx);
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
                .child(div().text_size(px(12.)).max_h(px(60.)).overflow_hidden().child(composer_skills::input_label(&intent.text, intent.attachments.len(), intent.skills.iter().map(|s| s.name.as_str())).chars().take(300).collect::<String>()))
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
        if !self.attachments.is_empty() {
            composer = composer.child(self.attachment_chips(cx));
        }
        if !self.skills.is_empty() {
            composer = composer.child(self.skill_chips(cx));
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
        let tokens = if let Some(label) = compaction_actions::recovery_usage_label(&self.session) {
            label
        } else if reported.is_empty() {
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
        let composer = if self.chat_is_archived(&self.record.id) {
            let id = self.record.id.clone();
            div()
                .debug_selector(|| "archived-read-only-footer".into())
                .mx(px(16.))
                .mt(px(queue_geometry::COMPOSER_TOP))
                .mb(px(queue_geometry::COMPOSER_BOTTOM))
                .px(px(14.))
                .py(px(12.))
                .rounded(px(12.))
                .border_1()
                .border_color(p.hairline())
                .bg(rgb(p.surface))
                .flex()
                .flex_col()
                .gap(px(6.))
                .child(
                    div()
                        .text_size(px(13.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .child("Archived · Read-only"),
                )
                .child(
                    div()
                        .text_size(px(12.))
                        .text_color(rgb(p.secondary))
                        .child("Restore the chat to send messages, steer or resume its queue."),
                )
                .child(
                    self.button("restore-archived-chat", "Restore Chat")
                        .on_click(cx.listener(move |view, _, _, cx| {
                            view.set_chat_archived(&id, false, cx)
                        })),
                )
                .child(
                    self.button("archived-search-copy", "Search and Copy Conversation")
                        .debug_selector(|| "archived-search-copy".into())
                        .on_click(cx.listener(move |view, _, window, cx| {
                            if content_target.matches(view) {
                                view.open_conversation_content(window, cx);
                            }
                        })),
                )
                .when(self.session.state == RunState::Running, |footer| {
                    footer.child(
                        self.button("stop-archived-chat", "Stop")
                            .on_click(cx.listener(|view, _, _, cx| view.stop_current_run(cx))),
                    )
                })
        } else {
            composer
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
                    // Wrapped metric rows need less vertical space than their
                    // horizontal separation, especially in minimum-width splits.
                    .gap_x(px(12.))
                    .gap_y(px(4.))
                    .text_size(px(11.5))
                    .text_color(rgb(p.secondary))
                    .flex_wrap()
                    .child(
                        self.badge(tokens, "chart")
                            .min_w_0()
                            .max_w_full()
                            .debug_selector(|| "composer-reported-tokens".into()),
                    )
                    .child(self.badge("Cost n/a".into(), "chart"))
                    .child(
                        self.badge(
                            tool_timing_presentation::total_label(&self.session),
                            "chart",
                        )
                        .debug_selector(|| "composer-tool-time".into()),
                    )
                    .child(
                        self.badge("Context n/a".into(), "cpu")
                            .id("context-inspector-open")
                            .debug_selector(|| "context-inspector-open".into())
                            .cursor_pointer()
                            .on_click(cx.listener(move |view, _, window, cx| {
                                view.open_context_inspector(&inspector_target, window, cx);
                            })),
                    )
                    // The notice takes the room the row leaves, cut to fit,
                    // so it never wraps the footer under the composer.
                    .child(match self.notice.clone() {
                        Some(notice) => self.footer_notice(notice).into_any_element(),
                        None => div().flex_1().into_any_element(),
                    })
                    .when(self.session.state == RunState::Running, |d| {
                        d.child(compaction_actions::progress_label(&self.session))
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
                            .child(format!(
                                "{}{}",
                                name,
                                if self.records.iter().any(|r| self.read_attention(r).1) {
                                    " · Attention"
                                } else {
                                    ""
                                }
                            )),
                    )
                    .child(
                        self.button("project-topics", "Topics")
                            .on_click(cx.listener(|view, _, window, cx| {
                                let id = view.record.id.clone();
                                view.open_topics(&id, window, cx);
                            })),
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
                    .child(self.icon_button("project-actions", "dots", 22.).on_click(
                        cx.listener(|view, _, window, cx| view.open_projects(window, cx)),
                    )),
            );
        let visible = self.visible_sidebar_records(cx);
        let displayed_first = visible
            .first()
            .map(|record| (record.id.clone(), self.sidebar_search_ticket(&record.id)));
        let displayed_query = self.filter.read(cx).text().to_owned();
        let mut archive_heading = false;
        for entry in self.sidebar_entries(cx) {
            let record = match entry {
                sidebar_actions::SidebarEntry::Root => {
                    archive_heading = false;
                    list = list.child(
                        div()
                            .px(px(10.))
                            .text_size(px(12.))
                            .child("Project top level"),
                    );
                    continue;
                }
                sidebar_actions::SidebarEntry::Topic(topic) => {
                    archive_heading = false;
                    let id = topic.id.clone();
                    let revision = topic.revision;
                    let expanded = !self.filter.read(cx).text().trim().is_empty()
                        || topic.expanded
                        || self.launch_topic_reveal.as_deref() == Some(topic.id.as_str());
                    list = list.child(
                        self.button(
                            SharedString::from(format!("topic-header-{id}")),
                            format!(
                                "{} {}{}",
                                if expanded { "▾" } else { "▸" },
                                topic.title,
                                if self
                                    .records
                                    .iter()
                                    .any(|r| self.effective_topic_id(r) == Some(topic.id.as_str())
                                        && self.read_attention(r).1)
                                {
                                    " · Attention"
                                } else {
                                    ""
                                }
                            ),
                        )
                        .on_click(cx.listener(move |view, _, _, cx| {
                            if view.launch_topic_reveal.as_deref() == Some(id.as_str()) {
                                view.launch_topic_reveal = None;
                            }
                            view.apply_topic_action(
                                topics::TopicAction::Expand(id.clone(), !expanded, revision),
                                cx,
                            );
                        })),
                    );
                    continue;
                }
                sidebar_actions::SidebarEntry::Chat(record) => record,
            };
            if record.archived_at.is_some() && !archive_heading {
                let archived_count = visible
                    .iter()
                    .filter(|candidate| {
                        candidate.archived_at.is_some()
                            && self.effective_topic_id(candidate) == self.effective_topic_id(record)
                    })
                    .count();
                archive_heading = true;
                list = list.child(
                    div()
                        .px(px(10.))
                        .pt(px(6.))
                        .pb(px(2.))
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .text_size(px(11.))
                        .text_color(rgb(p.tertiary))
                        .child(self.icon("archive", 11.))
                        .child(format!("Archived · {archived_count}"))
                        .child(div().flex_1().h(px(1.)).bg(p.hairline())),
                );
            }
            let title = self.sidebar_title(record);
            let id = record.id.clone();
            let selected = id == self.record.id;
            let move_id = id.clone();
            let menu_id = id.clone();
            let ticket = self.sidebar_search_ticket(&record.id);
            let snippet = self.sidebar_content_hit(&record.id).map(|hit| {
                use bello_agent_core::sidebar_search::projection::PieceKind;
                let role = match hit.key().kind {
                    PieceKind::User => "You",
                    PieceKind::Assistant => "Assistant",
                    PieceKind::ToolInput => "Tool input",
                    PieceKind::ToolOutput => "Tool output",
                };
                let prefix = format!("{role}: ");
                let range = hit
                    .highlight()
                    .map(|range| range.start + prefix.len()..range.end + prefix.len());
                (
                    format!("{prefix}{}", hit.excerpt().replace('\n', " ")),
                    range,
                )
            });
            let status = self.sidebar_run_status(record);
            let attention = self.read_status(record);
            list = list.child(
                div()
                    .id(SharedString::from(format!("chat-row-{id}")))
                    .debug_selector({
                        let id = id.clone();
                        move || format!("chat-row-{id}")
                    })
                    .mx(px(4.))
                    .px(px(10.))
                    .py(px(9.))
                    .rounded(px(8.))
                    .when(selected, |d| d.bg(p.accent_soft()))
                    .when(attention.is_some(), |d| {
                        d.border_l_2().border_color(rgb(p.accent))
                    })
                    .flex()
                    .gap(px(8.))
                    .items_center()
                    .cursor_pointer()
                    .map(|row| self.decorate_sidebar_row(&record.id, selected, row))
                    .on_click(cx.listener(move |view, event: &ClickEvent, window, cx| {
                        if view.sidebar_row_clicked(&id, event, window, cx) {
                            return;
                        }
                        view.open_sidebar_result(&id, ticket.clone(), window, cx);
                        // Reselecting the focused row also refreshes saved
                        // status without opening any unloaded controller.
                        view.refresh_sidebar_run_states(cx);
                        cx.notify();
                    }))
                    .on_mouse_down(
                        MouseButton::Right,
                        cx.listener(move |view, event: &MouseDownEvent, window, cx| {
                            view.open_sidebar_menu(&menu_id, event.position, window, cx);
                            cx.stop_propagation();
                        }),
                    )
                    .child(
                        self.button(
                            SharedString::from(format!("chat-topics-{}", record.id)),
                            "Move",
                        )
                        .on_click(cx.listener(
                            move |view, _, window, cx| {
                                cx.stop_propagation();
                                view.open_topics(&move_id, window, cx);
                            },
                        )),
                    )
                    .child(self.icon(
                        if record.archived_at.is_some() {
                            "archive"
                        } else {
                            "chat"
                        },
                        16.,
                    ))
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
                                            .debug_selector({
                                                let id = record.id.clone();
                                                move || format!("chat-title-{id}")
                                            })
                                            .min_w_0()
                                            .text_size(px(13.))
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .truncate()
                                            .child(title.replace('\n', " ")),
                                    )
                                    .when(self.shows_draft_mark(&record.id), |row| {
                                        row.child(
                                            div()
                                                .id(SharedString::from(format!(
                                                    "chat-draft-{}",
                                                    record.id
                                                )))
                                                .debug_selector({
                                                    let id = record.id.clone();
                                                    move || format!("chat-draft-{id}")
                                                })
                                                .tooltip(|_, cx| {
                                                    cx.new(|_| {
                                                        sidebar_actions::ArchiveVisibilityHint(
                                                            "Unsent draft",
                                                        )
                                                    })
                                                    .into()
                                                })
                                                .child(
                                                    self.icon("pencil", 10.)
                                                        .text_color(rgb(p.secondary)),
                                                ),
                                        )
                                    })
                                    .when(record.pinned_at.is_some(), |row| {
                                        row.child(self.icon("pin", 9.).text_color(rgb(p.tertiary)))
                                    }),
                            )
                            .when_some(snippet, |row, (text, range)| {
                                row.child(
                                    div()
                                        .text_size(px(11.))
                                        .text_color(rgb(p.secondary))
                                        .truncate()
                                        .child(StyledText::new(text).with_highlights(
                                            range.into_iter().map(|range| {
                                                (
                                                    range,
                                                    HighlightStyle {
                                                        background_color: Some(p.accent_soft()),
                                                        ..Default::default()
                                                    },
                                                )
                                            }),
                                        )),
                                )
                            })
                            .child(
                                div()
                                    .text_size(px(10.5))
                                    .text_color(rgb(p.secondary))
                                    .child(match &attention {
                                        Some(attention) => format!("{status} · {attention}"),
                                        None => status.to_owned(),
                                    }),
                            ),
                    ),
            );
        }
        let selected_unread = !self.can_read_action(&self.record.id, false);
        let selected_read_enabled = self.can_read_action(&self.record.id, selected_unread);
        let mut footer = div()
            .debug_selector(|| "sidebar-title-test-footer".into())
            .h(px(41.))
            .flex_shrink_0()
            .border_t_1()
            .border_color(p.hairline())
            .px(px(8.))
            .py(px(6.))
            .flex()
            .gap(px(2.))
            .items_center();
        let selected_read_id = self.record.id.clone();
        let selected_read_path = self.record.snapshot.clone();
        let selected_read_controller = Arc::downgrade(&self.controller);
        let read_action = div().px(px(8.)).py(px(3.)).child(
            self.button(
                "selected-mark-read-state",
                if selected_unread {
                    "Mark as Unread"
                } else {
                    "Mark as Read"
                },
            )
            .opacity(if selected_read_enabled { 1. } else { 0.45 })
            .on_click(cx.listener(move |view, _, _, cx| {
                if view.record.id == selected_read_id
                    && view.record.snapshot == selected_read_path
                    && selected_read_controller.ptr_eq(&Arc::downgrade(&view.controller))
                {
                    view.mark_chat_read_state(&selected_read_id, selected_unread, cx);
                }
            })),
        );
        for (id, icon) in [
            ("report", "chart"),
            ("inspector", "bug"),
            ("resources", "book"),
            ("background", "sparkles"),
        ] {
            let button = self.icon_button(id, icon, 28.);
            footer = footer.child(if id == "inspector" {
                let target = self.context_inspector_target();
                button.on_click(cx.listener(move |view, _, window, cx| {
                    view.open_context_inspector(&target, window, cx);
                }))
            } else {
                button.opacity(0.45)
            });
        }
        let archive_label = if self.effective_archive_visibility() {
            "Hide archived chats"
        } else {
            "Show archived chats"
        };
        footer = footer.child(
            self.icon_button("archived", "archive", 28.)
                .when(self.effective_archive_visibility(), |button| {
                    button.bg(p.accent_soft())
                })
                .tooltip(move |_, cx| {
                    cx.new(|_| sidebar_actions::ArchiveVisibilityHint(archive_label))
                        .into()
                })
                .on_click(cx.listener(|view, _, _, cx| {
                    view.set_archive_visibility(!view.effective_archive_visibility(), cx)
                })),
        );
        footer = footer
            .child(div().flex_1())
            .child(
                self.button("mcp-inspector", "MCP")
                    .on_click(cx.listener(|view, _, window, cx| view.open_mcp(window, cx))),
            )
            .child(
                self.icon_button("settings", "gear", 28.)
                    .on_click(cx.listener(|v, _, window, cx| v.open_connections(window, cx))),
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
                    .child(self.icon_button("manage-projects", "folder", 24.).on_click(
                        cx.listener(|view, _, window, cx| view.open_projects(window, cx)),
                    )),
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
                            .capture_key_down(cx.listener(
                                move |view, event: &KeyDownEvent, window, cx| {
                                    if event.keystroke.key == "enter"
                                        && !view.filter.read(cx).has_marked_text()
                                        && view.filter.read(cx).text() == displayed_query
                                    {
                                        if let Some((id, ticket)) = &displayed_first {
                                            view.open_sidebar_result(
                                                id,
                                                ticket.clone(),
                                                window,
                                                cx,
                                            );
                                        }
                                        cx.stop_propagation();
                                    }
                                },
                            ))
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
            .when(!self.filter.read(cx).text().trim().is_empty(), |sidebar| {
                sidebar.child(
                    div()
                        .px(px(12.))
                        .py(px(3.))
                        .text_size(px(10.5))
                        .text_color(rgb(p.secondary))
                        .child(self.sidebar_search.status)
                        .when(self.sidebar_search.can_refresh(), |row| {
                            row.child(
                                self.button("sidebar-content-refresh", "Check again")
                                    .on_click(
                                        cx.listener(|view, _, _, cx| {
                                            view.refresh_saved_content(cx)
                                        }),
                                    ),
                            )
                        }),
                )
            })
            .child(self.activity_held_sidebar_list(list, cx))
            .child(read_action)
            .child(footer)
    }
}
impl Render for AgentView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let started = Instant::now();
        self.refresh_read_geometry_route(cx);
        self.resume_sidebar_reveal(cx);
        self.refresh_sidebar_search(cx);
        self.refresh_sidebar_run_states(cx);
        self.refresh_dock_badge(cx);
        #[cfg(any(target_os = "macos", test))]
        self.sync_menus(cx);
        self.list_chat_models(cx);
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
            self.projects
                .view
                .update(cx, |view, cx| view.set_palette(palette, cx));
            self.connections
                .view
                .update(cx, |view, cx| view.set_palette(palette, cx));
            self.mcp
                .view
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
        self.sync_mcp_status(cx);
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
        if self.known_catalog_uncertainty {
            content = div().flex_1().min_w_0().min_h_0().flex().flex_col()
                .child(div().px(px(16.)).py(px(8.)).text_size(px(12.)).text_color(rgb(p.danger)).child(format!("Workspace save is unconfirmed. New chat actions are blocked; live drafts are preserved. {} queued organization change(s) were not confirmed.", self.blocked_organization_count)))
                .child(content);
        }
        if let Some(warning) = &self.archive_stop_warning {
            content = div()
                .flex_1()
                .min_w_0()
                .min_h_0()
                .flex()
                .flex_col()
                .child(
                    div()
                        .px(px(16.))
                        .py(px(8.))
                        .text_size(px(12.))
                        .text_color(rgb(p.danger))
                        .child(warning.clone()),
                )
                .child(content);
        }
        let mut element = div()
            .map(|element| {
                #[cfg(not(target_os = "macos"))]
                let element = element
                    .track_focus(&self.root_focus)
                    // This is a programmatic fallback, not a mouse focus target.
                    // Bubbling runs after child handlers; keep their click/focus
                    // behavior while suppressing this root's automatic transfer.
                    .on_any_mouse_down(|_, window, _| window.prevent_default());
                element
            })
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
            .map(|element| {
                #[cfg(target_os = "macos")]
                let element = self.menu_actions(element, window, cx);
                #[cfg(all(test, not(target_os = "macos")))]
                let element = self.menu_actions(element, window, cx);
                element
            })
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
        if let Some(menu) = self.compaction_menu_element(cx) {
            element = element.child(menu);
        }
        if let Some(menu) = self.sidebar_menu_element(cx) {
            element = element.child(menu);
        }
        if let Some(panel) = self.topics_element(window, cx) {
            element = element.child(panel);
        }
        if let Some(sheet) = self.sidebar_chats_element(window, cx) {
            element = element.child(sheet);
        }
        if let Some(picker) = self.skill_picker_element(window, cx) {
            element = element.child(picker);
        }
        if let Some(sheet) = self.conversation_content_element(window, cx) {
            element = element.child(sheet);
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
        if self.projects.view.read(cx).is_open() {
            element = element.child(
                div()
                    .absolute()
                    .inset_0()
                    .occlude()
                    .flex()
                    .items_center()
                    .justify_center()
                    .bg(rgba(0x00000044))
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .child(
                        div()
                            .w(px((width - 48.).clamp(320., 760.)))
                            .h(px(
                                (f32::from(window.viewport_size().height) - 48.).clamp(300., 720.)
                            ))
                            .child(self.projects.view.clone()),
                    ),
            );
        }
        if self.connections.picker {
            element = element.child(self.connection_picker_element(cx));
        }
        if self.connections.view.read(cx).is_open() {
            element = element.child(
                div()
                    .absolute()
                    .inset_0()
                    .occlude()
                    .flex()
                    .items_center()
                    .justify_center()
                    .bg(rgba(0x00000044))
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .child(
                        div()
                            .w(px((width - 48.).clamp(320., 1000.)))
                            .h(px(
                                (f32::from(window.viewport_size().height) - 48.).clamp(300., 820.)
                            ))
                            .child(self.connections.view.clone()),
                    ),
            );
        }
        if self.mcp.view.read(cx).is_open() {
            element = element.child(
                div()
                    .absolute()
                    .inset_0()
                    .occlude()
                    .flex()
                    .items_center()
                    .justify_center()
                    .bg(rgba(0x00000044))
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .child(
                        div()
                            .w(px((width - 32.).clamp(700., 1120.)))
                            .h(px(
                                (f32::from(window.viewport_size().height) - 32.).clamp(420., 840.)
                            ))
                            .child(self.mcp.view.clone()),
                    ),
            );
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

/// A command-line migration step, run instead of opening the window.
enum Migration {
    Import(PathBuf),
    Undo(PathBuf),
}

/// Bello Agent's (Swift) data folder on this Mac.
fn default_swift_data() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        Some(
            PathBuf::from(std::env::var_os("HOME")?)
                .join("Library/Application Support/com.belloware.PiApp"),
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

/// Runs an import or its undo against this project's Rust workspace and
/// prints what happened. Bello Agent's own files are only read.
fn run_migration(
    migration: Migration,
    workspace: &mut WorkspaceStore,
) -> Result<(), Box<dyn std::error::Error>> {
    use bello_agent_core::swift_migration;
    match migration {
        Migration::Import(source) => {
            let (path, manifest) = swift_migration::import(&source, workspace)?;
            println!(
                "Imported {} chat(s) and {} topic(s) from {} into {}.",
                manifest.chats.len(),
                manifest.topics.len(),
                source.display(),
                manifest.project.display()
            );
            for chat in &manifest.chats {
                let left: Vec<String> = chat
                    .left
                    .iter()
                    .map(|(kind, count)| format!("{count} {kind}"))
                    .collect();
                if left.is_empty() {
                    println!("  + {}", chat.title);
                } else {
                    println!("  + {} (not carried: {})", chat.title, left.join(", "));
                }
            }
            for skipped in &manifest.skipped {
                println!("  - {}: {}", skipped.title, skipped.reason);
            }
            if manifest.unlisted > 0 {
                println!(
                    "  {} record(s) Bello Agent itself does not list were left alone.",
                    manifest.unlisted
                );
            }
            if let Some(backup) = &manifest.backup {
                println!("The Rust catalog as it was: {}", backup.display());
            }
            println!(
                "To take these chats out again: --undo-swift-import {}",
                path.display()
            );
        }
        Migration::Undo(manifest) => {
            let undone = swift_migration::undo(workspace, &manifest)?;
            println!(
                "Took out {} imported chat(s); their files are in {}.",
                undone.removed.len(),
                undone.set_aside.display()
            );
            if !undone.kept.is_empty() {
                println!(
                    "Kept {} chat(s) continued in Rust since the import.",
                    undone.kept.len()
                );
            }
        }
    }
    Ok(())
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
fn open_startup_chat(
    workspace: &mut WorkspaceStore,
    session: &std::path::Path,
) -> Result<(SessionStore, ChatRecord, bool), Box<dyn std::error::Error>> {
    let state = workspace.snapshot();
    let selected = state
        .selected
        .as_ref()
        .and_then(|id| state.chats.iter().find(|chat| &chat.id == id))
        .or_else(|| {
            state
                .chats
                .iter()
                .filter(|chat| chat.archived_at.is_none())
                .min_by(|a, b| a.sidebar_cmp(b))
        })
        .cloned();
    if let Some(record) = selected {
        let store = SessionStore::pending_with_id(&record.id)?;
        Ok((store, record, false))
    } else if !state.chats.is_empty() {
        // All saved chats are archived: never reopen the original anchor as a
        // supposedly new active chat. Allocate a genuinely new pending identity.
        let store = SessionStore::pending();
        let snapshot = store.snapshot();
        let path = workspace.chat_path(&snapshot.id)?;
        let mut record = ChatRecord::new(snapshot.id, snapshot.title, path);
        record.materialization = bello_agent_core::workspace::ChatMaterialization::Pending;
        Ok((store, record, true))
    } else {
        let existing = session.exists();
        let store = if existing {
            SessionStore::open(session)?
        } else {
            SessionStore::pending()
        };
        let snapshot = store.snapshot();
        let mut record = ChatRecord::new(snapshot.id, snapshot.title, session.to_owned());
        if !existing {
            record.materialization = bello_agent_core::workspace::ChatMaterialization::Pending;
        }
        if existing {
            workspace.register(record.clone(), DraftRecord::default())?;
        }
        Ok((store, record, !existing))
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    START.set(Instant::now()).ok();
    #[cfg(all(debug_assertions, target_os = "linux", feature = "synthetic-authority"))]
    if let Some(root) =
        synthetic_sidebar_fixture::requested(&std::env::args_os().skip(1).collect::<Vec<_>>())?
    {
        return synthetic_sidebar_fixture::run(root);
    }
    #[cfg(feature = "native-lifecycle-smoke")]
    native_smoke::validate_launch()?;
    let mut args = std::env::args().skip(1);
    let mut project = std::env::current_dir()?;
    let mut session = default_session();
    let mut profile_path = None;
    let mut credential_stdin = false;
    let mut native_authority = false;
    let mut migration: Option<Migration> = None;
    #[cfg(all(feature = "synthetic-authority", debug_assertions))]
    let mut synthetic_authority = false;
    #[cfg(all(feature = "synthetic-authority", debug_assertions))]
    let mut synthetic_connections = false;
    #[cfg(all(feature = "synthetic-authority", debug_assertions))]
    let mut attachment_fixture_path = None;
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
            "--native-authority" => native_authority = true,
            "--import-swift" => {
                migration = Some(Migration::Import(
                    default_swift_data()
                        .ok_or("--import-swift needs --import-swift-from DIR here")?,
                ))
            }
            "--import-swift-from" => {
                migration = Some(Migration::Import(PathBuf::from(
                    args.next().ok_or("--import-swift-from needs a folder")?,
                )))
            }
            "--undo-swift-import" => {
                migration = Some(Migration::Undo(PathBuf::from(
                    args.next().ok_or("--undo-swift-import needs a manifest")?,
                )))
            }
            #[cfg(all(feature = "synthetic-authority", debug_assertions))]
            "--synthetic-project-authority" => synthetic_authority = true,
            #[cfg(all(feature = "synthetic-authority", debug_assertions))]
            "--synthetic-connections" => {
                synthetic_authority = true;
                synthetic_connections = true;
            }
            #[cfg(all(feature = "synthetic-authority", debug_assertions))]
            "--synthetic-attachment-fixture" => {
                if attachment_fixture_path.is_some() {
                    return Err("Only one synthetic attachment fixture is allowed".into());
                }
                attachment_fixture_path = Some(PathBuf::from(
                    args.next()
                        .ok_or("--synthetic-attachment-fixture needs a profile file")?,
                ));
            }
            "--help" | "-h" => {
                println!(
                    "BelloAgent Rust GPUI preview\n  --project DIR\n  --session FILE    isolated Rust snapshot (never a Swift journal)\n  --profile FILE    explicit non-secret LiteLLM Responses JSON\n  --credential-stdin  read an in-memory key until EOF; never stored\n  --import-swift    copy this project's chats from Bello Agent (Swift) into the Rust workspace, then exit;\n                    Bello Agent's own files are only read\n  --import-swift-from DIR  the same, from a Bello Agent data folder\n  --undo-swift-import MANIFEST  take an import's chats out again (not ones continued since), then exit\n  BELLO_PERF_LOG=FILE  optional real CPU callback JSONL telemetry"
                );
                #[cfg(all(debug_assertions, target_os = "linux", feature = "synthetic-authority"))]
                println!(
                    "  --synthetic-sidebar-search-fixture ROOT  isolated synthetic Linux GUI validation; exact arguments only; private disposable root; no provider"
                );
                #[cfg(feature = "native-authority")]
                println!(
                    "  --native-authority  experimental separate Rust Keychain vault; saved chats offer a trusted project's tools by their mode; requires approved signed macOS identity"
                );
                #[cfg(all(feature = "synthetic-authority", debug_assertions))]
                println!(
                    "  --synthetic-project-authority  debug QA only; in-memory trust and fixture Connections/tools, never native storage\n  --synthetic-connections  same isolated fixture; fixed fake key and numeric loopback only\n  --synthetic-attachment-fixture PROFILE  debug QA saved image connection; requires --synthetic-connections; select and trust through the UI"
                );
                return Ok(());
            }
            _ => return Err(format!("Unknown argument: {arg}").into()),
        }
    }
    #[cfg(all(feature = "synthetic-authority", debug_assertions))]
    let (fixture_requested, attachment_requested) =
        (synthetic_authority, attachment_fixture_path.is_some());
    #[cfg(not(all(feature = "synthetic-authority", debug_assertions)))]
    let (fixture_requested, attachment_requested) = (false, false);
    let authority_mode = launch_authority::AuthorityMode::for_launch(
        native_authority,
        fixture_requested,
        profile_path.is_some(),
        credential_stdin,
        attachment_requested,
    )?;
    #[cfg(all(feature = "synthetic-authority", debug_assertions))]
    let attachment_fixture = if let Some(path) = attachment_fixture_path {
        if profile_path.is_some() {
            return Err(
                "--synthetic-attachment-fixture cannot be combined with legacy --profile".into(),
            );
        }
        if !synthetic_connections {
            return Err(
                "--synthetic-attachment-fixture requires explicit --synthetic-connections".into(),
            );
        }
        let key = if credential_stdin {
            let mut key = zeroize::Zeroizing::new(String::new());
            std::io::stdin().take(16_385).read_to_string(&mut key)?;
            let length = key.trim_end_matches(['\n', '\r']).len();
            key.truncate(length);
            credential_stdin = false;
            Some(key)
        } else {
            None
        };
        Some(attachment_fixture::AttachmentFixture::read(
            &path,
            synthetic_connections,
            key.as_deref().map(String::as_str),
        )?)
    } else {
        None
    };
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
    if let Some(migration) = migration {
        return run_migration(migration, &mut workspace);
    }
    let (store, record, pending) = open_startup_chat(&mut workspace, &session)?;
    let draft = workspace
        .snapshot()
        .drafts
        .get(&record.id)
        .cloned()
        .unwrap_or_default();
    let workspace = Arc::new(Mutex::new(workspace));
    // Keep the explicitly supplied CLI route separate from all saved identities.
    // A temporary pending controller constructs this immutable configuration only;
    // it has no journal, provider worker or network side effects.
    let legacy_configuration =
        Controller::new(SessionStore::pending(), configuration)?.configuration();
    #[cfg(all(feature = "synthetic-authority", debug_assertions))]
    let synthetic = if synthetic_authority {
        Some(bello_agent_core::project_authority::ProjectAuthority::with_synthetic_bytes(None)?)
    } else {
        None
    };
    #[cfg(all(feature = "synthetic-authority", debug_assertions))]
    let authority = synthetic
        .as_ref()
        .map(|(authority, _)| authority.clone())
        .unwrap_or_default();
    #[cfg(not(all(feature = "synthetic-authority", debug_assertions)))]
    let authority = bello_agent_core::project_authority::ProjectAuthority::new();
    #[cfg(feature = "native-authority")]
    let authority = if authority_mode == launch_authority::AuthorityMode::Native {
        bello_agent_core::project_authority::ProjectAuthority::with_native_storage()?
    } else {
        authority
    };
    #[cfg(all(feature = "synthetic-authority", debug_assertions))]
    if let Some(fixture) = attachment_fixture {
        fixture.seed(&authority)?;
    }
    let runtime = saved_runtime_adapter::AppRuntime::for_launch(
        authority.clone(),
        workspace.clone(),
        project.clone(),
        authority_mode,
        legacy_configuration.clone(),
    );
    let controller = if pending {
        Controller::with_configuration(store, legacy_configuration.clone())?
    } else if authority_mode == launch_authority::AuthorityMode::Native {
        // Real authority operations belong to the existing background loader.
        drop(store);
        saved_runtime_adapter::AppRuntime::placeholder(&record)?
    } else {
        drop(store);
        match runtime.open_registered(&record) {
            Ok(controller) => controller,
            Err(error) => {
                eprintln!("Saved chat is unavailable: {error}");
                runtime
                    .disconnected(&record, None)
                    .or_else(|_| saved_runtime_adapter::AppRuntime::placeholder(&record))?
            }
        }
    };
    perf(
        "startup_initialized",
        START.get().unwrap().elapsed().as_micros(),
    );
    Application::new()
        .with_assets(assets::Assets)
        .run(move |cx: &mut App| {
            bello_workbench_ui::init(cx);
            cx.set_global(notifications::Notifications::new(Some(
                default_session()
                    .parent()
                    .unwrap()
                    .parent()
                    .unwrap()
                    .join("notifications.json"),
            )));
            #[cfg(target_os = "macos")]
            application_menus::install(cx);
            cx.set_global(connection_settings_controller::LaunchLegacyConfiguration(
                legacy_configuration,
            ));
            #[cfg(all(feature = "synthetic-authority", debug_assertions))]
            if let Some((_, control)) = synthetic {
                cx.set_global(connection_settings_controller::LaunchConnectionAuthority(
                    control,
                ));
            }
            cx.set_global(project_manager_controller::LaunchProjectAuthority {
                authority: Arc::new(authority),
                mode: authority_mode,
            });
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
