//! The picker is explicit: typing, filtering, inspecting, and argument editing
//! never submit input. Search text is never parsed as a command or skill name.
use crate::{
    AgentView, Palette,
    composer_skills::policy_label,
    project_skills_controller::{CatalogState, SkillTarget},
};
use bello_agent_core::{project_resources::ProjectResourceSnapshot, skills::SkillChip};
use bello_workbench_ui::{EditorEvent, EditorView};
use gpui::{prelude::*, *};
use std::{collections::BTreeMap, sync::Arc};

pub(crate) enum PickerMode {
    Browse,
    Arguments(Box<SkillChip>),
}
#[derive(Clone)]
pub(crate) enum SkillControl {
    Refresh,
    Close,
    Save,
    Add(Arc<ProjectResourceSnapshot>, Box<SkillChip>),
}
pub(crate) struct SkillPicker {
    pub token: uuid::Uuid,
    pub target: SkillTarget,
    pub mode: PickerMode,
    pub editor: Entity<EditorView>,
    pub notice: Option<String>,
    focuses: BTreeMap<String, FocusHandle>,
    actions: Vec<(SkillControl, FocusHandle)>,
    pub(crate) scroll: ScrollHandle,
    rows: BTreeMap<String, usize>,
    _events: Subscription,
}
impl SkillPicker {
    pub fn new(
        target: SkillTarget,
        mode: PickerMode,
        palette: Palette,
        window: &mut Window,
        cx: &mut Context<AgentView>,
    ) -> Self {
        let text = match &mode {
            PickerMode::Browse => String::new(),
            PickerMode::Arguments(chip) => chip.selection.arguments.clone(),
        };
        let editor = cx.new(|cx| {
            let mut view = EditorView::new(text, window, cx);
            view.set_composer_mode(cx);
            view.set_appearance(AgentView::composer_style(palette), cx);
            view
        });
        editor.read(cx).focus(window);
        let events = cx.subscribe(&editor, |_, _, event, cx| {
            if matches!(event, EditorEvent::Changed) {
                cx.notify();
            }
        });
        Self {
            token: uuid::Uuid::new_v4(),
            target,
            mode,
            editor,
            notice: None,
            focuses: BTreeMap::new(),
            actions: Vec::new(),
            scroll: ScrollHandle::new(),
            rows: BTreeMap::new(),
            _events: events,
        }
    }
    fn button(
        &mut self,
        id: String,
        label: &'static str,
        control: SkillControl,
        enabled: bool,
        palette: Palette,
        cx: &mut Context<AgentView>,
    ) -> Stateful<Div> {
        let focus = self
            .focuses
            .entry(id.clone())
            .or_insert_with(|| cx.focus_handle())
            .clone();
        if enabled {
            self.actions.push((control.clone(), focus.clone()));
        }
        let token = self.token;
        let selector = id.clone();
        div()
            .id(SharedString::from(id))
            .debug_selector(move || selector.clone())
            .px(px(10.))
            .py(px(5.))
            .rounded(px(7.))
            .border_1()
            .border_color(palette.hairline())
            .text_size(px(12.))
            .flex_shrink_0()
            .child(label)
            .when(!enabled, |button| button.opacity(0.45))
            .when(enabled, |button| {
                button
                    .track_focus(&focus)
                    .tab_index(0)
                    .cursor_pointer()
                    .hover(|style| style.bg(palette.accent_soft()))
                    .focus(|style| style.border_color(rgb(palette.accent)))
            })
            .on_click(cx.listener(move |view, _, window, cx| {
                if enabled {
                    view.activate_skill_control(token, control.clone(), window, cx);
                }
            }))
    }
}
impl AgentView {
    pub(crate) fn activate_skill_control(
        &mut self,
        token: uuid::Uuid,
        control: SkillControl,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.skill_picker_matches(token) {
            return;
        }
        match control {
            SkillControl::Refresh => {
                let target = self.skill_picker.as_ref().unwrap().target.clone();
                self.refresh_project_skills(&target, cx);
            }
            SkillControl::Close => self.close_skill_picker(token, window, cx),
            SkillControl::Save => {
                self.save_skill_arguments(token, cx);
                if self.skill_picker.is_none() {
                    self.focus_visible_composer(window, cx);
                }
            }
            SkillControl::Add(snapshot, chip) => {
                self.add_presented_skill(token, &snapshot, &chip, cx);
                if let Some(picker) = &self.skill_picker {
                    picker.editor.read(cx).focus(window);
                }
            }
        }
    }
    pub(crate) fn skill_picker_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(picker) = self.skill_picker.as_ref() else {
            return;
        };
        let token = picker.token;
        if !picker.target.matches(self, true) {
            self.skill_picker = None;
            cx.notify();
            return;
        }
        let key = &event.keystroke;
        let command = key.modifiers.platform || key.modifiers.control;
        if key.key == "escape" && !picker.editor.read(cx).has_marked_text() {
            self.close_skill_picker(token, window, cx);
            self.cancelled_prompt_key = Some(key.key.clone());
            cx.stop_propagation();
            return;
        }
        if key.key == "tab" && !command && !key.modifiers.alt {
            let mut focuses = vec![picker.editor.read(cx).focus_handle(cx)];
            focuses.extend(picker.actions.iter().map(|(_, focus)| focus.clone()));
            let current = focuses.iter().position(|focus| focus.is_focused(window));
            let index = match current {
                Some(index) if key.modifiers.shift => (index + focuses.len() - 1) % focuses.len(),
                Some(index) => (index + 1) % focuses.len(),
                None if key.modifiers.shift => focuses.len() - 1,
                None => 0,
            };
            if index > 0
                && let SkillControl::Add(_, chip) = &picker.actions[index - 1].0
                && let Some(row) = picker.rows.get(&chip.selection.id)
            {
                picker.scroll.scroll_to_item(*row);
            }
            focuses[index].focus(window);
            cx.notify();
            cx.stop_propagation();
        } else if !command
            && !key.modifiers.alt
            && matches!(key.key.as_str(), "enter" | "space")
            && let Some(control) = picker
                .actions
                .iter()
                .find(|(_, focus)| focus.is_focused(window))
                .map(|(control, _)| control.clone())
        {
            if !event.is_held {
                self.activate_skill_control(token, control, window, cx);
            }
            self.cancelled_prompt_key = Some(key.key.clone());
            cx.stop_propagation();
        }
    }
    pub(crate) fn skill_picker_element(
        &mut self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<Div> {
        let mut picker = self.skill_picker.take()?;
        if !picker.target.matches(self, true) {
            return None;
        }
        let p = self.palette;
        let height = f32::from(window.viewport_size().height);
        picker.actions.clear();
        picker.rows.clear();
        let token = picker.token;
        let mut panel = div()
            .id("project-skills-picker")
            .debug_selector(|| "project-skills-picker".into())
            .w(px(660.))
            .max_h(px((height - 40.).max(300.)))
            .m(px(20.))
            .p(px(20.))
            .rounded(px(14.))
            .bg(rgb(p.surface))
            .border_1()
            .border_color(p.hairline())
            .flex()
            .flex_col()
            .gap(px(10.))
            .occlude()
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation());
        let title = match &picker.mode {
            PickerMode::Browse => "Project skills".into(),
            PickerMode::Arguments(chip) => format!("Arguments for /{}", chip.name),
        };
        panel = panel.child(div().text_size(px(17.)).font_weight(FontWeight::SEMIBOLD).child(title))
            .child(div().text_size(px(12.)).text_color(rgb(p.secondary)).child("Selecting a skill adds a prompt resource. It sends nothing, runs no scripts, and grants no additional tools."));
        let is_browse = matches!(picker.mode, PickerMode::Browse);
        panel = panel
            .child(div().text_size(px(12.)).child(if is_browse {
                "Filter by name, description, or canonical path"
            } else {
                "Literal arguments (up to 16 KiB)"
            }))
            .child(
                div()
                    .id("skill-picker-editor")
                    .debug_selector(|| "skill-picker-editor".into())
                    .h(px(if is_browse { 42. } else { 160. }))
                    .border_1()
                    .border_color(p.hairline())
                    .rounded(px(7.))
                    .child(picker.editor.clone()),
            );
        if is_browse {
            let state = self.skill_catalog.state;
            let snapshot = self.skill_catalog.snapshot.clone();
            let current = self.skill_catalog.authorizes()
                && snapshot.as_ref().is_some_and(|snapshot| {
                    self.controller.project_skills_catalog_current(snapshot)
                });
            let status = match state {
                CatalogState::Unloaded => "Project skills have not been discovered yet.",
                CatalogState::Loading => {
                    "Loading project skills… Selection is unavailable until discovery finishes."
                }
                CatalogState::Failed => "Discovery failed. Retry to select skills.",
                CatalogState::Partial => {
                    "Some sources could not be read. Successfully discovered skills remain selectable."
                }
                CatalogState::Ready if !current => {
                    "The project or tools changed. Refresh before selecting skills."
                }
                CatalogState::Ready => {
                    "Choose explicitly for this message. Same-name skills are distinguished by their canonical paths."
                }
            };
            panel = panel.child(
                div()
                    .debug_selector(|| "skill-catalog-status".into())
                    .text_size(px(12.))
                    .text_color(rgb(p.secondary))
                    .child(status),
            );
            if let Some(notice) = &self.skill_catalog.notice {
                panel = panel.child(
                    div()
                        .id("skill-discovery-diagnostics")
                        .max_h(px(72.))
                        .overflow_y_scroll()
                        .text_size(px(12.))
                        .text_color(rgb(p.secondary))
                        .child(notice.clone()),
                );
            }
            let query = picker.editor.read(cx).text().trim().to_lowercase();
            let mut list = div()
                .id("skill-catalog-list")
                .max_h(px((height - 360.).clamp(80., 300.)))
                .min_h_0()
                .overflow_y_scroll()
                .track_scroll(&picker.scroll)
                .flex()
                .flex_col()
                .gap(px(8.));
            let mut count = 0;
            if let Some(snapshot) = snapshot {
                for (index, descriptor) in snapshot.skills.iter().enumerate() {
                    if !query.is_empty()
                        && ![&descriptor.name, &descriptor.description, &descriptor.path]
                            .iter()
                            .any(|text| text.to_lowercase().contains(&query))
                    {
                        continue;
                    }
                    picker.rows.insert(descriptor.id.clone(), count);
                    count += 1;
                    let chip = descriptor.chip(String::new());
                    let selected = self
                        .skills
                        .iter()
                        .any(|selected| selected.selection.id == chip.selection.id);
                    let enabled = current
                        && descriptor.selectable(&snapshot.dependencies)
                        && !selected
                        && self.skills.len() < 8
                        && self.can_choose_skills();
                    let add = picker.button(
                        format!("skill-add-{index}"),
                        if selected { "Selected" } else { "Add" },
                        SkillControl::Add(snapshot.clone(), Box::new(chip)),
                        enabled,
                        p,
                        cx,
                    );
                    let mut row = div()
                        .debug_selector(move || format!("skill-catalog-row-{index}"))
                        .p(px(10.))
                        .rounded(px(8.))
                        .border_1()
                        .border_color(p.hairline())
                        .flex()
                        .flex_col()
                        .gap(px(4.))
                        .child(
                            div()
                                .flex()
                                .gap(px(8.))
                                .items_center()
                                .child(
                                    div()
                                        .flex_1()
                                        .text_size(px(14.))
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .child(format!("/{}", descriptor.name)),
                                )
                                .child(add),
                        )
                        .child(
                            div()
                                .text_size(px(12.))
                                .child(descriptor.description.clone()),
                        )
                        .child(div().text_size(px(11.)).text_color(rgb(p.secondary)).child(
                            format!(
                                "{} · Project\n{}\nSource root: {}",
                                policy_label(descriptor.policy),
                                descriptor.path,
                                descriptor.source_root
                            ),
                        ));
                    for reason in &descriptor.reasons {
                        row = row.child(
                            div()
                                .text_size(px(12.))
                                .text_color(rgb(p.danger))
                                .child(reason.clone()),
                        );
                    }
                    let missing = descriptor.missing_dependencies(&snapshot.dependencies);
                    if !missing.is_empty() {
                        row = row.child(div().text_size(px(12.)).text_color(rgb(p.danger)).child(
                            format!(
                                    "Unavailable dependencies: {}",
                                    missing
                                        .iter()
                                        .map(|dependency| format!(
                                            "{}: {}",
                                            dependency.kind, dependency.value
                                        ))
                                        .collect::<Vec<_>>()
                                        .join(", ")
                                ),
                        ));
                    }
                    list = list.child(row);
                }
            }
            if count == 0 && matches!(state, CatalogState::Ready | CatalogState::Partial) {
                list = list.child(
                    div()
                        .debug_selector(|| "skill-catalog-empty".into())
                        .text_size(px(12.))
                        .child(if query.is_empty() {
                            "No project skills were found in .agents/skills."
                        } else {
                            "No skills match this filter."
                        }),
                );
            }
            panel = panel.child(list);
        } else if let PickerMode::Arguments(chip) = &picker.mode {
            panel = panel.child(
                div()
                    .text_size(px(11.))
                    .text_color(rgb(p.secondary))
                    .child(chip.path.clone()),
            );
        }
        if let Some(notice) = &picker.notice {
            panel = panel.child(
                div()
                    .text_size(px(12.))
                    .text_color(rgb(p.danger))
                    .child(notice.clone()),
            );
        }
        let mut footer = div().flex().gap(px(8.));
        if is_browse {
            footer = footer.child(picker.button(
                "skill-refresh".into(),
                if self.skill_catalog.state == CatalogState::Failed {
                    "Retry"
                } else {
                    "Refresh"
                },
                SkillControl::Refresh,
                true,
                p,
                cx,
            ));
        } else {
            footer = footer.child(picker.button(
                "skill-arguments-save".into(),
                "Save arguments",
                SkillControl::Save,
                self.can_choose_skills(),
                p,
                cx,
            ));
        }
        footer = footer.child(div().flex_1()).child(picker.button(
            "skill-picker-close".into(),
            if is_browse { "Done" } else { "Cancel" },
            SkillControl::Close,
            true,
            p,
            cx,
        ));
        panel = panel.child(footer);
        self.skill_picker = Some(picker);
        Some(
            div()
                .absolute()
                .inset_0()
                .occlude()
                .flex()
                .items_center()
                .justify_center()
                .bg(rgba(0x00000055))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |view, _, window, cx| {
                        view.close_skill_picker(token, window, cx)
                    }),
                )
                .child(panel),
        )
    }
}
