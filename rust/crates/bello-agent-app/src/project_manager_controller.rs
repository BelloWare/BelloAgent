//! Current-primary Projects coordinator. Source: WorkspaceManagerView.swift and
//! WorkspaceFolders.swift. Draft folders are never runtime authority.
use crate::{
    AgentView, Palette,
    project_host::{ChangedProject, LoadedChat, ProjectChange, ProjectChangeFailure},
    project_manager_view::{
        ProjectFolderTarget, ProjectManagerAvailability as Availability, ProjectManagerEvent,
        ProjectManagerIntent as Intent, ProjectManagerNotice, ProjectManagerPresentation,
        ProjectManagerStage as Stage, ProjectManagerView, ProjectTrustKind,
    },
    transcript_view::ToolFocusRestore,
    workspace_lifetime::WindowBinding,
};
use bello_agent_core::{
    Controller, RunState,
    project_authority::{AuthorityError, LoadedProjects, ProjectAuthority},
};
use gpui::*;
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use uuid::Uuid;

/// Installed only by an explicit debug/test launch flag or a test fixture.
pub(crate) struct LaunchProjectAuthority {
    pub authority: Arc<ProjectAuthority>,
    pub synthetic: bool,
}
impl Global for LaunchProjectAuthority {}

struct FocusRestore {
    previous: Option<FocusHandle>,
    tool: Option<ToolFocusRestore>,
    transcript_owner: Option<EntityId>,
    binding: Option<WindowBinding>,
    project: PathBuf,
    chat: String,
    controller: Arc<Controller>,
    route: (u64, bool, Option<u64>, bool),
}

pub(crate) struct ProjectManagerController {
    pub view: Entity<ProjectManagerView>,
    pub presentation: ProjectManagerPresentation,
    authority: Arc<ProjectAuthority>,
    baseline: Option<LoadedProjects>,
    pub operation: Option<Uuid>,
    admission_blocked: bool,
    load: Option<Uuid>,
    load_previous: Option<Availability>,
    picker: Option<Uuid>,
    open: bool,
    focus: Option<FocusRestore>,
    events: Option<Subscription>,
}

impl ProjectManagerController {
    pub fn new(primary: PathBuf, palette: Palette, cx: &mut Context<AgentView>) -> Self {
        let (authority, synthetic) = cx
            .try_global::<LaunchProjectAuthority>()
            .map(|launch| (launch.authority.clone(), launch.synthetic))
            .unwrap_or_else(|| (Arc::new(ProjectAuthority::new()), false));
        let presentation = ProjectManagerPresentation {
            revision: 1,
            primary,
            project_id: None,
            trusted: false,
            extra_roots: Vec::new(),
            stage: Stage::Current,
            availability: Availability::Loading,
            notice: None,
            synthetic,
        };
        let view = cx.new(|cx| ProjectManagerView::new(presentation.clone(), palette, cx));
        Self {
            view,
            presentation,
            authority,
            baseline: None,
            operation: None,
            admission_blocked: false,
            load: None,
            load_previous: None,
            picker: None,
            open: false,
            focus: None,
            events: None,
        }
    }

    /// Publishing consumes even rejected intentions and cancelled pickers.
    pub(crate) fn publish(&mut self, cx: &mut Context<AgentView>) {
        self.presentation.revision = self
            .presentation
            .revision
            .checked_add(1)
            .expect("Projects presentation revision exhausted");
        let presentation = self.presentation.clone();
        self.view
            .update(cx, |view, cx| view.set_presentation(presentation, cx));
        cx.notify();
    }

    fn notice(&mut self, message: impl Into<String>, is_error: bool) {
        self.presentation.notice = Some(ProjectManagerNotice {
            text: message.into(),
            is_error,
        });
    }

    fn cancel_load(&mut self) {
        self.load = None;
        if let Some(previous) = self.load_previous.take() {
            self.presentation.availability = previous;
        }
    }

    fn install_loaded(&mut self, loaded: LoadedProjects, trusted: bool) {
        let saved = loaded
            .projects()
            .iter()
            .find(|p| p.path == self.presentation.primary);
        self.presentation.project_id = saved.map(|p| p.id.clone());
        self.presentation.extra_roots = saved.map(|p| p.paths.clone()).unwrap_or_default();
        self.presentation.trusted = trusted;
        self.baseline = Some(loaded);
    }
}

impl AgentView {
    pub(crate) fn project_actions_blocked(&self) -> bool {
        self.projects.admission_blocked || self.projects.open
    }

    pub(crate) fn bind_projects(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // A detached window cannot retain its picker, load, or focus ownership.
        self.projects.cancel_load();
        if self.projects.picker.take().is_some() {
            self.projects.presentation.availability = Availability::Ready;
        }
        self.projects.focus = None;
        self.projects.open = false;
        self.projects
            .view
            .update(cx, |view, cx| view.close(false, window, cx));
        self.projects.publish(cx);
        let binding = self.window_binding;
        self.projects.events = Some(cx.subscribe_in(
            &self.projects.view,
            window,
            move |view, _, event, window, cx| {
                if view.window_binding != binding {
                    return;
                }
                match event {
                    ProjectManagerEvent::Intent { revision, intent } => {
                        view.project_intent(*revision, intent.clone(), window, cx);
                    }
                    ProjectManagerEvent::Dismissed { .. } => {
                        view.projects_dismissed(window, cx);
                    }
                }
            },
        ));
    }

    pub(crate) fn open_projects(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.shutting_down || self.close_dialog || self.projects.open {
            return;
        }
        self.cancel_queue_drag(window, cx);
        self.close_queue_detail(true, window, cx);
        self.sidebar_menu = None;
        self.quick_open
            .update(cx, |view, cx| view.close(true, window, cx));
        let previous = window.focused(cx);
        let transcript_owner = previous.as_ref().and_then(|previous| {
            self.transcript
                .as_ref()
                .filter(|view| view.read(cx).owned_focus_handles(cx).contains(previous))
                .map(|view| view.entity_id())
        });
        let tool = previous.as_ref().and_then(|previous| {
            self.transcript
                .as_ref()
                .and_then(|view| ToolFocusRestore::capture(view, previous, window, cx))
        });
        self.projects.focus = Some(FocusRestore {
            previous,
            tool,
            transcript_owner,
            binding: self.window_binding,
            project: self.project.clone(),
            chat: self.record.id.clone(),
            controller: self.controller.clone(),
            route: (
                self.navigation_generation,
                self.show_files,
                self.selected_file,
                self.changes_open,
            ),
        });
        self.projects.open = true;
        self.projects
            .view
            .update(cx, |view, cx| view.show(window, cx));
        if self.projects.operation.is_none() && !self.projects.admission_blocked {
            self.reload_projects(cx);
        } else {
            self.projects.publish(cx);
        }
    }

    fn projects_dismissed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.projects.open {
            return;
        }
        self.projects.open = false;
        self.projects.cancel_load();
        if self.projects.picker.take().is_some() {
            self.projects.presentation.availability = Availability::Ready;
        }
        self.projects.publish(cx);
        let Some(focus) = self.projects.focus.take() else {
            return;
        };
        if self.window_binding != focus.binding
            || self.project != focus.project
            || self.shutting_down
            || self.close_dialog
            || self.quick_open.read(cx).is_open()
        {
            return;
        }
        // The component may already have restored its handle. A newer focus
        // owner wins; only fix up our own modal or the captured old editor.
        let current = window.focused(cx);
        if !self.projects.view.read(cx).owns_focus(window, cx)
            && current.as_ref() != focus.previous.as_ref()
        {
            return;
        }
        let same_owner = self.record.id == focus.chat
            && focus.route
                == (
                    self.navigation_generation,
                    self.show_files,
                    self.selected_file,
                    self.changes_open,
                )
            // Controller replacement preserves ordinary editor entities. Only
            // transcript-owned handles depend on that runtime and child.
            && focus.transcript_owner.is_none_or(|owner| {
                Arc::ptr_eq(&self.controller, &focus.controller)
                    && self.transcript.as_ref().is_some_and(|view| view.entity_id() == owner)
            });
        if same_owner && let Some(previous) = &focus.previous {
            if let Some(tool) = &focus.tool {
                if tool.restore(previous, self.transcript.as_ref(), window, cx) {
                    return;
                }
            } else if !(self.chat_is_archived(&self.record.id)
                && previous == &self.composer.read(cx).focus_handle(cx))
            {
                previous.focus(window);
                return;
            }
        }
        if self
            .transcript
            .as_ref()
            .is_some_and(|view| view.read(cx).focus_fallback(window))
        {
            return;
        }
        self.focus_visible_composer(window, cx);
    }

    fn reload_projects(&mut self, cx: &mut Context<Self>) {
        if self.projects.operation.is_some() || self.projects.load.is_some() {
            self.projects.publish(cx);
            return;
        }
        let token = Uuid::new_v4();
        self.projects.load_previous = Some(self.projects.presentation.availability.clone());
        self.projects.load = Some(token);
        self.projects.picker = None;
        self.projects.presentation.availability = Availability::Loading;
        self.projects.presentation.notice = None;
        self.projects.publish(cx);
        let authority = self.projects.authority.clone();
        let project = self.project.clone();
        let primary = project.clone();
        let binding = self.window_binding;
        let task = cx.background_executor().spawn(async move {
            let loaded = authority.load()?;
            let trust = loaded
                .projects()
                .iter()
                .find(|saved| saved.path == primary)
                .filter(|saved| saved.trusted)
                .map(|saved| authority.confirm_project(&loaded, saved))
                .transpose();
            Ok::<_, AuthorityError>((loaded, trust))
        });
        cx.spawn(async move |owner, cx| {
            let result = task.await;
            let _ = owner.update(cx, |view, cx| {
                if view.projects.load != Some(token)
                    || view.project != project
                    || view.window_binding != binding
                    || !view.projects.open
                {
                    return;
                }
                view.projects.load = None;
                view.projects.load_previous = None;
                match result {
                    Ok((loaded, trust)) => {
                        let trusted = trust.as_ref().is_ok_and(|saved| saved.is_some());
                            view.projects.install_loaded(loaded, trusted);
                            if view.projects.admission_blocked {
                                view.projects.presentation.trusted = false;
                            }
                            view.projects.presentation.availability = if view.projects.admission_blocked {
                                Availability::Unconfirmed("Saved projects were reloaded. New chat actions remain blocked because the previous runtime change was not confirmed; live chat drafts are preserved.".into())
                            } else { Availability::Ready };
                        if let Err(error) = trust {
                            view.projects.notice(error.to_string(), true);
                        }
                    }
                    Err(error) => {
                        view.projects.presentation.availability = match error {
                            AuthorityError::Unavailable => {
                                Availability::Unavailable(error.to_string())
                            }
                            AuthorityError::Unconfirmed => {
                                Availability::Unconfirmed(error.to_string())
                            }
                            _ => Availability::Failed(error.to_string()),
                        };
                    }
                }
                view.projects.publish(cx);
            });
        })
        .detach();
    }

    pub(crate) fn project_intent(
        &mut self,
        revision: u64,
        intent: Intent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let allowed = self.projects.open
            && revision == self.projects.presentation.revision
            && self.projects.presentation.allows(&intent)
            && !self.shutting_down
            && self.projects.operation.is_none()
            && (!self.projects.admission_blocked
                || matches!(intent, Intent::Reload | Intent::CancelDraft));
        self.projects.publish(cx);
        if !allowed {
            return;
        }
        self.projects.presentation.notice = None;
        match intent {
            Intent::BeginCreate | Intent::BeginRetrust => {
                let kind = if matches!(intent, Intent::BeginCreate) {
                    ProjectTrustKind::Create
                } else {
                    ProjectTrustKind::Retrust
                };
                self.projects.presentation.stage = Stage::TrustDraft {
                    kind,
                    extras: self.projects.presentation.extra_roots.clone(),
                };
            }
            Intent::CancelDraft => {
                self.projects.presentation.stage = Stage::Current;
            }
            Intent::Reload => {
                self.reload_projects(cx);
                return;
            }
            Intent::ChooseAdditionalFolders(target) => {
                self.choose_project_folders(target, window, cx);
                return;
            }
            Intent::RemoveAdditionalFolder { target, path } => {
                match (&mut self.projects.presentation.stage, target) {
                    (Stage::TrustDraft { extras, .. }, ProjectFolderTarget::Draft) => {
                        extras.retain(|p| p != &path)
                    }
                    (Stage::Current, ProjectFolderTarget::Current) => {
                        let extras = self
                            .projects
                            .presentation
                            .extra_roots
                            .iter()
                            .filter(|p| **p != path)
                            .cloned()
                            .collect();
                        self.save_project_folders(extras, cx);
                        return;
                    }
                    _ => {}
                }
            }
            Intent::ConfirmTrust => {
                if let Stage::TrustDraft { extras, .. } = &self.projects.presentation.stage {
                    self.save_project_folders(extras.clone(), cx);
                    return;
                }
            }
        }
        self.projects.publish(cx);
    }

    fn choose_project_folders(
        &mut self,
        target: ProjectFolderTarget,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let token = Uuid::new_v4();
        self.projects.picker = Some(token);
        self.projects.presentation.availability =
            Availability::Busy("Choose additional project folders…".into());
        self.projects.publish(cx);
        let binding = self.window_binding;
        let project = self.project.clone();
        let dialog = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: true,
            prompt: Some("Choose additional project folders".into()),
        });
        cx.spawn(async move |owner, cx| {
            let result = match dialog.await {
                Ok(Ok(Some(paths))) => {
                    cx.background_executor()
                        .spawn(async move {
                            paths
                                .into_iter()
                                .map(|path| {
                                    if !path.is_absolute() {
                                        return Err(
                                            "Project folders must have absolute paths.".to_owned()
                                        );
                                    }
                                    let canonical = std::fs::canonicalize(&path).map_err(|_| {
                                        format!("{} is not an existing folder.", path.display())
                                    })?;
                                    if !canonical.is_dir() {
                                        return Err(format!(
                                            "{} is not an existing folder.",
                                            path.display()
                                        ));
                                    }
                                    Ok(canonical)
                                })
                                .collect::<Result<Vec<_>, _>>()
                                .map(Some)
                        })
                        .await
                }
                Ok(Ok(None)) => Ok(None),
                Ok(Err(error)) => Err(format!("The folder chooser could not be opened: {error:#}")),
                Err(error) => Err(format!("The folder chooser was interrupted: {error}")),
            };
            let _ = owner.update(cx, |view, cx| {
                view.finish_project_picker(token, binding, project, target, result, cx)
            });
        })
        .detach();
    }

    fn finish_project_picker(
        &mut self,
        token: Uuid,
        binding: Option<WindowBinding>,
        project: PathBuf,
        target: ProjectFolderTarget,
        result: Result<Option<Vec<PathBuf>>, String>,
        cx: &mut Context<Self>,
    ) {
        if self.projects.picker != Some(token)
            || self.window_binding != binding
            || self.project != project
            || !self.projects.open
        {
            return;
        }
        self.projects.picker = None;
        self.projects.presentation.availability = Availability::Ready;
        self.projects.publish(cx);
        match result {
            Ok(Some(paths)) if !paths.is_empty() => {
                let mut extras = match (&self.projects.presentation.stage, target) {
                    (Stage::TrustDraft { extras, .. }, ProjectFolderTarget::Draft) => {
                        extras.clone()
                    }
                    (Stage::Current, ProjectFolderTarget::Current) => {
                        self.projects.presentation.extra_roots.clone()
                    }
                    _ => return,
                };
                for path in paths {
                    if path != self.project && !extras.contains(&path) {
                        extras.push(path);
                    }
                }
                if target == ProjectFolderTarget::Current
                    && extras == self.projects.presentation.extra_roots
                {
                    self.projects
                        .notice("Those folders are already part of this project.", true);
                    self.projects.publish(cx);
                    return;
                }
                if extras.len() > 15 {
                    self.projects.notice(
                        "A project can have at most 16 folders including its primary folder.",
                        true,
                    );
                } else if target == ProjectFolderTarget::Current {
                    self.save_project_folders(extras, cx);
                    return;
                } else if let Stage::TrustDraft { extras: draft, .. } =
                    &mut self.projects.presentation.stage
                {
                    *draft = extras;
                }
            }
            Ok(_) => {}
            Err(error) => self.projects.notice(error, true),
        }
        self.projects.publish(cx);
    }

    fn project_idle_error(&self) -> Option<String> {
        if self.shutting_down
            || !self.organization_operations.is_empty()
            || self.archive_visibility_writes != 0
            || self.known_catalog_uncertainty
            || !self.recoveries.is_empty()
            || self
                .queued_cancellations
                .keys()
                .any(|id| self.has_pending_cancel(id))
        {
            return Some(
                "Finish pending chat or workspace changes before changing project folders.".into(),
            );
        }
        match self.workspace.try_lock() {
            Ok(store) if !store.is_uncertain() => {}
            _ => return Some("The workspace has an unfinished or unconfirmed save. Project folders were not changed.".into()),
        }
        for chat in std::iter::once(&self.chat).chain(self.inactive.values()) {
            let snapshot = chat.controller.snapshot_shared();
            if chat.busy
                || chat.loading
                || chat.load_failed
                || chat.inflight_submission.is_some()
                || chat.queue_operation.is_some()
                || chat.cancel_operation.is_some()
                || chat.begin_operation.is_some()
                || chat.editing.is_some()
                || chat.retained_edit.is_some()
                || chat.edit_recovery.blocked
                || snapshot.state == RunState::Running
                || !snapshot.pending.is_empty()
                || snapshot.active.is_some()
                || snapshot.active_reply.is_some()
                || snapshot.edit.is_some()
            {
                return Some(format!(
                    "Finish active work, queued messages, or held edits in “{}” before changing project folders.",
                    chat.record.title
                ));
            }
        }
        None
    }

    fn save_project_folders(&mut self, extras: Vec<PathBuf>, cx: &mut Context<Self>) {
        if let Some(error) = self.project_idle_error() {
            self.projects.notice(error, true);
            self.projects.publish(cx);
            return;
        }
        let Some(baseline) = self.projects.baseline.clone() else {
            self.projects
                .notice("Reload saved projects before changing folders.", true);
            self.projects.publish(cx);
            return;
        };
        let operation = Uuid::new_v4();
        // This foreground admission fence precedes scheduling any worker.
        self.projects.operation = Some(operation);
        self.projects.admission_blocked = true;
        self.projects.presentation.availability =
            Availability::Busy("Saving project folders and restarting idle chats…".into());
        self.projects.publish(cx);
        let project = self.project.clone();
        let loaded: Vec<_> = std::iter::once(&self.chat)
            .chain(self.inactive.values())
            .map(|chat| LoadedChat {
                record: chat.record.clone(),
                controller: chat.controller.clone(),
            })
            .collect();
        let unloaded = self
            .records
            .iter()
            .filter(|record| !loaded.iter().any(|chat| chat.record.id == record.id))
            .cloned()
            .collect();
        let change = ProjectChange {
            authority: self.projects.authority.clone(),
            baseline,
            primary: project.clone(),
            extras,
            loaded,
            unloaded,
        };
        let task = cx.background_executor().spawn(change.apply());
        cx.spawn(async move |owner, cx| {
            let result = task.await;
            let _ = owner.update(cx, |view, cx| {
                view.finish_project_change(operation, &project, result, cx)
            });
        })
        .detach();
    }

    fn finish_project_change(
        &mut self,
        operation: Uuid,
        project: &Path,
        result: Result<ChangedProject, ProjectChangeFailure>,
        cx: &mut Context<Self>,
    ) {
        // The mutation belongs to the retained workspace, not its window or
        // selected chat. A new window still receives correctly owned results.
        if self.projects.operation != Some(operation) || self.project != project {
            return;
        }
        self.projects.operation = None;
        if self.error.as_deref()
            == Some("Wait for the project folder change to finish before closing.")
        {
            self.error = None;
        }
        match result {
            Ok(changed) => {
                if changed.replacements.len() != self.inactive.len() + 1
                    || changed.replacements.iter().any(|replacement| {
                        self.chat_ref(&replacement.id).is_none_or(|chat| {
                            !Arc::ptr_eq(&chat.controller, &replacement.previous)
                        })
                    })
                {
                    self.projects.presentation.trusted = false;
                    self.projects.presentation.availability = Availability::Failed("Project folders were saved, but a chat runtime changed. New chat actions remain blocked; live drafts are preserved.".into());
                    self.projects.publish(cx);
                    return;
                }
                let retiring_focus = self
                    .transcript
                    .as_ref()
                    .map(|view| view.read(cx).owned_focus_handles(cx))
                    .unwrap_or_default();
                for replacement in changed.replacements {
                    if let Some(chat) = self.chat_mut(&replacement.id) {
                        chat.replace_controller(replacement.controller, cx);
                    }
                }
                self.projects
                    .install_loaded(changed.loaded, changed.project.trusted);
                self.projects.presentation.stage = Stage::Current;
                self.projects.presentation.availability = Availability::Ready;
                self.projects.notice(
                    "Project folders saved. Chat tools remain unavailable in this preview.",
                    false,
                );
                self.projects.admission_blocked = false;
                self.repair_retired_transcript_focus(retiring_focus, cx);
            }
            Err(error) => {
                self.projects.admission_blocked = error.keep_blocked;
                if error.keep_blocked {
                    self.projects.presentation.trusted = false;
                    self.projects.presentation.availability = if error.unconfirmed {
                        Availability::Unconfirmed("The project folder save is unconfirmed. New chat actions remain blocked; live chat drafts are preserved. Do not assume the folder change was saved.".into())
                    } else {
                        Availability::Failed(error.message)
                    };
                } else {
                    self.projects.presentation.availability = Availability::Ready;
                    self.projects.notice(error.message, true);
                }
            }
        }
        self.projects.publish(cx);
    }

    fn repair_retired_transcript_focus(&self, handles: Vec<FocusHandle>, cx: &mut Context<Self>) {
        let Some(window) = self.organization_window.filter(|_| !handles.is_empty()) else {
            return;
        };
        let owner = cx.weak_entity();
        let binding = self.window_binding;
        let project = self.project.clone();
        let selected = self.record.id.clone();
        let controller = Arc::downgrade(&self.controller);
        cx.defer(move |cx| {
            let _ = window.update(cx, |_, window, cx| {
                let _ = owner.update(cx, |view, cx| {
                    if view.window_binding != binding
                        || view.project != project
                        || view.record.id != selected
                        || !controller.ptr_eq(&Arc::downgrade(&view.controller))
                        || view.shutting_down
                        || view.close_dialog
                        || view.projects.open
                        || view.quick_open.read(cx).is_open()
                        || !handles.iter().any(|handle| handle.is_focused(window))
                    {
                        return;
                    }
                    // The old dispatch subtree may already be gone. Exact
                    // retained handles distinguish it from a newer editor.
                    if !view
                        .transcript
                        .as_ref()
                        .is_some_and(|view| view.read(cx).focus_fallback(window))
                    {
                        view.focus_visible_composer(window, cx);
                    }
                });
            });
        });
    }
}

#[cfg(all(test, feature = "synthetic-authority"))]
#[path = "project_manager_controller_tests.rs"]
mod tests;
