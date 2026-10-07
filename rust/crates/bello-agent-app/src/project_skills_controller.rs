//! Explicit project-skill discovery and selection. Catalog reads are asynchronous;
//! neither rendering nor metadata chips read source files or confer tool authority.
use crate::{
    AgentView,
    project_skills_view::{PickerMode, SkillPicker},
};
use bello_agent_core::{
    Controller, project_resources::ProjectResourceSnapshot, skills::SkillChip,
    workspace::WorkspaceStore,
};
use gpui::{Context, Window};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex, Weak},
};

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(crate) enum CatalogState {
    #[default]
    Unloaded,
    Loading,
    Ready,
    Partial,
    Failed,
}
#[derive(Clone, Default)]
pub(crate) struct SkillCatalog {
    pub state: CatalogState,
    pub snapshot: Option<Arc<ProjectResourceSnapshot>>,
    pub request: Option<uuid::Uuid>,
    pub notice: Option<String>,
}
impl SkillCatalog {
    pub fn loading(&self) -> bool {
        self.state == CatalogState::Loading
    }
    pub fn authorizes(&self) -> bool {
        matches!(self.state, CatalogState::Ready | CatalogState::Partial)
    }
}

/// The UI lifetime is distinct from the resource snapshot's durable authority.
/// A returned catalog can update its original background chat; actions cannot.
#[derive(Clone)]
pub(crate) struct SkillTarget {
    project: PathBuf,
    workspace: Weak<Mutex<WorkspaceStore>>,
    window: Option<crate::workspace_lifetime::WindowBinding>,
    pub chat: String,
    controller: Weak<Controller>,
    navigation: u64,
    configuration: (u64, u64),
    connection: Option<String>,
    tool_mode: bello_agent_core::workspace::ChatToolMode,
    load_generation: u64,
}
impl SkillTarget {
    pub fn capture(view: &AgentView) -> Self {
        Self {
            project: view.project.clone(),
            workspace: Arc::downgrade(&view.workspace),
            window: view.window_binding,
            chat: view.record.id.clone(),
            controller: Arc::downgrade(&view.controller),
            navigation: view.navigation_generation,
            configuration: view.controller.project_skills_ui_generation(),
            connection: view.record.connection_id.clone(),
            tool_mode: view.record.tool_mode,
            load_generation: view.load_generation,
        }
    }
    pub fn matches(&self, view: &AgentView, selected: bool) -> bool {
        !view.shutting_down
            && !view.close_ready
            && self.window.is_some()
            && view.window_binding == self.window
            && view.project == self.project
            && self.workspace.ptr_eq(&Arc::downgrade(&view.workspace))
            && (!selected
                || (view.record.id == self.chat && view.navigation_generation == self.navigation))
            && view.chat_ref(&self.chat).is_some_and(|chat| {
                self.controller.ptr_eq(&Arc::downgrade(&chat.controller))
                    && chat.controller.project_skills_ui_generation() == self.configuration
                    && chat.record.connection_id == self.connection
                    && chat.record.tool_mode == self.tool_mode
                    && chat.load_generation == self.load_generation
                    && !chat.controller.is_retired()
                    && !chat.loading
                    && !chat.load_failed
            })
    }
}
impl AgentView {
    pub(crate) fn can_choose_skills(&self) -> bool {
        !self.shutting_down
            && !self.close_ready
            && !self.loading
            && !self.load_failed
            && !self.actor_mutation_blocked(&self.record.id)
            && self.editing.is_none()
            && self.session.edit.is_none()
            && self.retained_edit.is_none()
            && self.begin_operation.is_none()
            && self.cancel_operation.is_none()
            && !self.edit_recovery.blocked
            && (!self.busy || self.inflight_submission.is_some())
    }
    pub(crate) fn open_skill_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.can_choose_skills() {
            return;
        }
        let target = SkillTarget::capture(self);
        self.skill_picker = Some(SkillPicker::new(
            target.clone(),
            PickerMode::Browse,
            self.palette,
            window,
            cx,
        ));
        let current = self
            .skill_catalog
            .snapshot
            .as_ref()
            .is_some_and(|snapshot| {
                self.skill_catalog.authorizes()
                    && self.controller.project_skills_catalog_current(snapshot)
            });
        if !current {
            self.refresh_project_skills(&target, cx);
        }
        cx.notify();
    }
    pub(crate) fn refresh_project_skills(&mut self, target: &SkillTarget, cx: &mut Context<Self>) {
        if !target.matches(self, true) {
            return;
        }
        let token = uuid::Uuid::new_v4();
        if let Some(picker) = self.skill_picker.as_mut() {
            picker.token = uuid::Uuid::new_v4();
        }
        let controller = self.controller.clone();
        self.skill_catalog.state = CatalogState::Loading;
        self.skill_catalog.request = Some(token);
        self.skill_catalog.notice = Some(
            "Discovering project skills… Previous results cannot be selected while loading.".into(),
        );
        let target = target.clone();
        let task = cx.background_executor().spawn(async move {
            controller
                .discover_project_skills()
                .await
                .map_err(|error| error.to_string())
        });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                view.finish_project_skills(&target, token, result, cx)
            });
        })
        .detach();
        cx.notify();
    }
    pub(crate) fn finish_project_skills(
        &mut self,
        target: &SkillTarget,
        token: uuid::Uuid,
        result: Result<Arc<ProjectResourceSnapshot>, String>,
        cx: &mut Context<Self>,
    ) {
        if !target.matches(self, false) {
            return;
        }
        let Some(chat) = self.chat_mut(&target.chat) else {
            return;
        };
        if chat.skill_catalog.request != Some(token) {
            return;
        }
        chat.skill_catalog.request = None;
        match result {
            Ok(snapshot) if chat.controller.project_skills_catalog_current(&snapshot) => {
                chat.skill_catalog.state = if snapshot.partial {
                    CatalogState::Partial
                } else {
                    CatalogState::Ready
                };
                chat.skill_catalog.notice =
                    (!snapshot.diagnostics.is_empty()).then(|| snapshot.diagnostics.join("\n"));
                chat.skill_catalog.snapshot = Some(snapshot);
            }
            Ok(_) => {
                chat.skill_catalog.state = CatalogState::Failed;
                chat.skill_catalog.notice =
                    Some("The project, connection, or tools changed. Retry discovery.".into());
            }
            Err(error) => {
                chat.skill_catalog.state = CatalogState::Failed;
                chat.skill_catalog.notice = Some(error);
            }
        }
        cx.notify();
    }
    pub(crate) fn skill_picker_matches(&self, token: uuid::Uuid) -> bool {
        self.skill_picker
            .as_ref()
            .is_some_and(|picker| picker.token == token && picker.target.matches(self, true))
    }
    pub(crate) fn close_skill_picker(
        &mut self,
        token: uuid::Uuid,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.skill_picker_matches(token) {
            return;
        }
        self.skill_picker = None;
        self.focus_visible_composer(window, cx);
        cx.notify();
    }
    pub(crate) fn add_presented_skill(
        &mut self,
        token: uuid::Uuid,
        snapshot: &Arc<ProjectResourceSnapshot>,
        chip: &SkillChip,
        cx: &mut Context<Self>,
    ) {
        if !self.skill_picker_matches(token)
            || !self.can_choose_skills()
            || !self.skill_catalog.authorizes()
            || !matches!(
                self.skill_picker.as_ref().map(|picker| &picker.mode),
                Some(PickerMode::Browse)
            )
            || !self
                .skill_catalog
                .snapshot
                .as_ref()
                .is_some_and(|current| Arc::ptr_eq(current, snapshot))
            || !self.controller.project_skills_catalog_current(snapshot)
        {
            return;
        }
        let matches = snapshot.skills.iter().any(|descriptor| {
            descriptor.selectable(&snapshot.dependencies) && descriptor.chip(String::new()) == *chip
        });
        if !matches {
            return;
        }
        let mut next = self.skills.clone();
        if next.iter().any(|old| old.selection.id == chip.selection.id) {
            self.skill_picker.as_mut().unwrap().notice = Some("This skill is already selected. Edit its arguments separately, or remove it first.".into());
            cx.notify();
            return;
        }
        next.push(chip.clone());
        if let Err(error) = crate::composer_skills::validate_fresh(&next) {
            self.skill_picker.as_mut().unwrap().notice = Some(error.to_string());
            cx.notify();
            return;
        }
        if self.draft_revision == u64::MAX {
            return;
        }
        self.skills = next;
        self.skill_picker.as_mut().unwrap().notice = None;
        let id = self.record.id.clone();
        self.draft_changed(&id, cx);
        cx.notify();
    }
    pub(crate) fn save_skill_arguments(&mut self, token: uuid::Uuid, cx: &mut Context<Self>) {
        if !self.skill_picker_matches(token) || !self.can_choose_skills() {
            return;
        }
        let picker = self.skill_picker.as_ref().unwrap();
        let PickerMode::Arguments(original) = &picker.mode else {
            return;
        };
        let Some(index) = self
            .skills
            .iter()
            .position(|chip| chip == original.as_ref())
        else {
            return;
        };
        let arguments = picker.editor.read(cx).text().to_owned();
        if arguments.len() > 16 * 1024 {
            self.skill_picker.as_mut().unwrap().notice =
                Some("Skill arguments are limited to 16 KiB of UTF-8 text.".into());
            cx.notify();
            return;
        }
        if self.draft_revision == u64::MAX {
            return;
        }
        let mut next = self.skills.clone();
        next[index].selection.arguments = arguments;
        if let Err(error) = bello_agent_core::skills::validate_chips(&next, 16) {
            self.skill_picker.as_mut().unwrap().notice = Some(error.to_string());
            cx.notify();
            return;
        }
        self.skills = next;
        self.skill_picker = None;
        let id = self.record.id.clone();
        self.draft_changed(&id, cx);
        cx.notify();
    }
    pub(crate) fn edit_skill_arguments(
        &mut self,
        target: &SkillTarget,
        chip: &SkillChip,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !target.matches(self, true) || !self.can_choose_skills() || !self.skills.contains(chip) {
            return;
        }
        self.skill_picker = Some(SkillPicker::new(
            target.clone(),
            PickerMode::Arguments(Box::new(chip.clone())),
            self.palette,
            window,
            cx,
        ));
        cx.notify();
    }
    pub(crate) fn remove_presented_skill(
        &mut self,
        target: &SkillTarget,
        chip: &SkillChip,
        cx: &mut Context<Self>,
    ) {
        if !target.matches(self, true)
            || !self.can_choose_skills()
            || self.draft_revision == u64::MAX
        {
            return;
        }
        let Some(index) = self.skills.iter().position(|value| value == chip) else {
            return;
        };
        self.skills.remove(index);
        let id = self.record.id.clone();
        self.draft_changed(&id, cx);
        cx.notify();
    }
    pub(crate) fn held_input_has_skills(&self) -> bool {
        self.editing.is_some()
            && self.queued_turn_id.as_ref().is_some_and(|id| {
                self.session
                    .pending
                    .iter()
                    .any(|item| &item.id == id && !item.frozen_skills.is_empty())
            })
    }
}
