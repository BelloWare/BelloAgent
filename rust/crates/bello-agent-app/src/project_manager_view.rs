//! Current-primary subset of WorkspaceManagerView.swift / WorkspaceFolders.swift.
//! The coordinator owns authority, drafts, folder pickers and asynchronous work.
//! This view only renders snapshots and emits revision-scoped user intentions.
use crate::theme::Palette;
use gpui::{
    App, Bounds, Context, Div, ElementId, EventEmitter, FocusHandle, FontWeight, IntoElement,
    KeyDownEvent, MouseButton, Pixels, Point, Render, ScrollHandle, SharedString, Stateful, Window,
    canvas, div, prelude::*, px, rgb, svg,
};
use std::{
    cell::Cell,
    path::{Path, PathBuf},
    rc::Rc,
};

const MAXIMUM_ROOTS: usize = 16;
const TRUST_WARNING: &str = "Trusting a project allows editing chats to read files, run shell commands and change files with your account's permissions. Project folders are working locations, not a security boundary.";
const TOOLS_NOTICE: &str = "Chat tool execution remains unavailable in this Rust preview. Saving project trust does not enable tools.";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ProjectTrustKind {
    Create,
    Retrust,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ProjectManagerStage {
    Current,
    TrustDraft {
        kind: ProjectTrustKind,
        extras: Vec<PathBuf>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ProjectManagerAvailability {
    Loading,
    Ready,
    Unavailable(String),
    Busy(String),
    Failed(String),
    Unconfirmed(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ProjectManagerNotice {
    pub(crate) text: String,
    pub(crate) is_error: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ProjectManagerPresentation {
    /// Increases for every coordinator change, including operation completion.
    pub(crate) revision: u64,
    pub(crate) primary: PathBuf,
    pub(crate) project_id: Option<String>,
    /// Confirmed saved trust only. A selected folder or draft is never trust.
    pub(crate) trusted: bool,
    pub(crate) extra_roots: Vec<PathBuf>,
    pub(crate) stage: ProjectManagerStage,
    pub(crate) availability: ProjectManagerAvailability,
    pub(crate) notice: Option<ProjectManagerNotice>,
    pub(crate) mode: crate::launch_authority::AuthorityMode,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ProjectFolderTarget {
    Current,
    Draft,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ProjectManagerIntent {
    BeginCreate,
    BeginRetrust,
    ChooseAdditionalFolders(ProjectFolderTarget),
    RemoveAdditionalFolder {
        target: ProjectFolderTarget,
        path: PathBuf,
    },
    ConfirmTrust,
    CancelDraft,
    Reload,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ProjectManagerEvent {
    Intent {
        revision: u64,
        intent: ProjectManagerIntent,
    },
    Dismissed {
        revision: u64,
    },
}

impl ProjectManagerPresentation {
    fn target(&self) -> ProjectFolderTarget {
        match self.stage {
            ProjectManagerStage::Current => ProjectFolderTarget::Current,
            ProjectManagerStage::TrustDraft { .. } => ProjectFolderTarget::Draft,
        }
    }

    fn displayed_extras(&self) -> &[PathBuf] {
        match &self.stage {
            ProjectManagerStage::Current => &self.extra_roots,
            ProjectManagerStage::TrustDraft { extras, .. } => extras,
        }
    }

    /// Affordance checks are deliberately conservative. The coordinator must
    /// recheck the authoritative project, revision and active work on receipt.
    pub(crate) fn allows(&self, intent: &ProjectManagerIntent) -> bool {
        use ProjectManagerAvailability as Availability;
        use ProjectManagerIntent as Intent;
        if matches!(intent, Intent::Reload) {
            return !matches!(
                self.availability,
                Availability::Loading | Availability::Busy(_)
            );
        }
        if matches!(intent, Intent::CancelDraft) {
            return self.target() == ProjectFolderTarget::Draft
                && !matches!(
                    self.availability,
                    Availability::Loading | Availability::Busy(_)
                );
        }
        if self.availability != Availability::Ready {
            return false;
        }
        match intent {
            Intent::BeginCreate => {
                self.target() == ProjectFolderTarget::Current && self.project_id.is_none()
            }
            Intent::BeginRetrust => {
                self.target() == ProjectFolderTarget::Current && self.project_id.is_some()
            }
            Intent::ChooseAdditionalFolders(target) => {
                *target == self.target()
                    && (*target == ProjectFolderTarget::Draft
                        || (self.trusted && self.project_id.is_some()))
                    && self.displayed_extras().len() + 1 < MAXIMUM_ROOTS
            }
            Intent::RemoveAdditionalFolder { target, path } => {
                *target == self.target()
                    && (*target == ProjectFolderTarget::Draft
                        || (self.trusted && self.project_id.is_some()))
                    && path != &self.primary
                    && self.displayed_extras().contains(path)
            }
            Intent::ConfirmTrust => {
                matches!(self.stage, ProjectManagerStage::TrustDraft { .. })
            }
            Intent::CancelDraft | Intent::Reload => unreachable!("handled above"),
        }
    }

    fn status(&self) -> Option<(&str, bool)> {
        use ProjectManagerAvailability as Availability;
        match &self.availability {
            Availability::Loading => Some(("Loading saved project trust…", false)),
            Availability::Unavailable(message)
            | Availability::Failed(message)
            | Availability::Unconfirmed(message) => Some((message, true)),
            Availability::Busy(message) => Some((message, false)),
            Availability::Ready => self
                .notice
                .as_ref()
                .map(|notice| (notice.text.as_str(), notice.is_error)),
        }
    }
}

pub(crate) struct ProjectManagerView {
    presentation: ProjectManagerPresentation,
    palette: Palette,
    focus: FocusHandle,
    previous_focus: Option<FocusHandle>,
    open: bool,
    /// A click remains consumed until the coordinator publishes a new snapshot.
    /// Repaints and repeated opening cannot turn it into a second operation.
    pending_revision: Option<u64>,
    controls: Vec<ControlFocus>,
    body_scroll: ScrollHandle,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum ProjectControl {
    Intent(ProjectManagerIntent),
    Done,
}

struct ControlFocus {
    control: ProjectControl,
    focus: FocusHandle,
    rendered_revision: u64,
    in_body: bool,
    // Retain the measured scroll offset as well as the rectangle so rapid Tab
    // events can reveal a control even before the next frame has been drawn.
    bounds: Rc<Cell<Option<ControlGeometry>>>,
}

#[derive(Clone, Copy)]
struct ControlGeometry {
    bounds: Bounds<Pixels>,
    scroll_offset: Point<Pixels>,
}

struct FolderPathHint(String, Palette);

impl Render for FolderPathHint {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .max_w(px(560.))
            .p(px(8.))
            .rounded(px(6.))
            .border_1()
            .border_color(self.1.hairline())
            .bg(rgb(self.1.surface))
            .text_size(px(11.5))
            .text_color(rgb(self.1.ink))
            .child(self.0.clone())
    }
}

impl EventEmitter<ProjectManagerEvent> for ProjectManagerView {}

impl ProjectManagerView {
    pub(crate) fn new(
        presentation: ProjectManagerPresentation,
        palette: Palette,
        cx: &mut Context<Self>,
    ) -> Self {
        Self {
            presentation,
            palette,
            focus: cx.focus_handle(),
            previous_focus: None,
            open: false,
            pending_revision: None,
            controls: Vec::new(),
            body_scroll: ScrollHandle::new(),
        }
    }

    pub(crate) fn set_presentation(
        &mut self,
        presentation: ProjectManagerPresentation,
        cx: &mut Context<Self>,
    ) {
        if presentation.revision <= self.presentation.revision {
            return;
        }
        self.presentation = presentation;
        self.pending_revision = None;
        cx.notify();
    }

    pub(crate) fn set_palette(&mut self, palette: Palette, cx: &mut Context<Self>) {
        if self.palette != palette {
            self.palette = palette;
            cx.notify();
        }
    }

    pub(crate) fn is_open(&self) -> bool {
        self.open
    }

    pub(crate) fn owns_focus(&self, window: &Window, cx: &App) -> bool {
        self.focus.contains_focused(window, cx)
    }

    pub(crate) fn show(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.open {
            return;
        }
        self.previous_focus = window.focused(cx);
        self.open = true;
        self.focus.focus(window);
        cx.notify();
    }

    /// Closing hides the view; it never commits or discards the coordinator's
    /// draft. The owner decides how to fence a picker/save and preserve drafts.
    pub(crate) fn close(&mut self, restore: bool, window: &mut Window, cx: &mut Context<Self>) {
        if !self.open {
            return;
        }
        self.open = false;
        if restore
            && self.owns_focus(window, cx)
            && let Some(previous) = self.previous_focus.take()
        {
            previous.focus(window);
        }
        self.previous_focus = None;
        cx.emit(ProjectManagerEvent::Dismissed {
            revision: self.presentation.revision,
        });
        cx.notify();
    }

    pub(crate) fn key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.open {
            return false;
        }
        let mods = event.keystroke.modifiers;
        let command = mods.platform || (cfg!(target_os = "linux") && mods.control);
        if event.keystroke.key == "escape" || (event.keystroke.key == "w" && command) {
            self.close(true, window, cx);
            return true;
        }
        if event.keystroke.key == "tab" && !mods.platform && !mods.control && !mods.alt {
            self.move_focus(mods.shift, window, cx);
            return true;
        }
        // The source Create Project button has no defaultAction shortcut.
        // Enter/Space activate only a deliberately focused, current control.
        if matches!(event.keystroke.key.as_str(), "enter" | "space")
            && !mods.platform
            && !mods.control
            && !mods.alt
            && !mods.shift
            && let Some(control) = self
                .controls
                .iter()
                .find(|control| control.focus.is_focused(window))
        {
            let control = control.control.clone();
            if !event.is_held {
                self.activate_control(control, window, cx);
            }
            return true;
        }
        false
    }

    fn current_controls(&self) -> Vec<ProjectControl> {
        let mut controls: Vec<_> = self
            .presentation
            .displayed_extras()
            .iter()
            .map(|path| {
                ProjectControl::Intent(ProjectManagerIntent::RemoveAdditionalFolder {
                    target: self.presentation.target(),
                    path: path.clone(),
                })
            })
            .collect();
        controls.push(ProjectControl::Intent(
            ProjectManagerIntent::ChooseAdditionalFolders(self.presentation.target()),
        ));
        if matches!(
            self.presentation.stage,
            ProjectManagerStage::TrustDraft { .. }
        ) {
            controls.push(ProjectControl::Intent(ProjectManagerIntent::CancelDraft));
            controls.push(ProjectControl::Intent(ProjectManagerIntent::ConfirmTrust));
        } else {
            controls.push(ProjectControl::Intent(
                if self.presentation.project_id.is_some() {
                    ProjectManagerIntent::BeginRetrust
                } else {
                    ProjectManagerIntent::BeginCreate
                },
            ));
        }
        controls.push(ProjectControl::Intent(ProjectManagerIntent::Reload));
        controls.push(ProjectControl::Done);
        controls
    }

    fn control_enabled(&self, control: &ProjectControl) -> bool {
        match control {
            ProjectControl::Intent(intent) => self.enabled(intent),
            ProjectControl::Done => self.open,
        }
    }

    fn sync_controls(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let current = self.current_controls();
        let lost_focus = self.controls.iter().any(|control| {
            control.focus.is_focused(window)
                && (!current.contains(&control.control) || !self.control_enabled(&control.control))
        });
        let mut previous = std::mem::take(&mut self.controls);
        self.controls = current
            .into_iter()
            .map(|control| {
                if let Some(index) = previous.iter().position(|old| old.control == control) {
                    let mut retained = previous.remove(index);
                    retained.rendered_revision = self.presentation.revision;
                    retained
                } else {
                    let in_body = !matches!(
                        control,
                        ProjectControl::Done | ProjectControl::Intent(ProjectManagerIntent::Reload)
                    );
                    ControlFocus {
                        control,
                        focus: cx.focus_handle(),
                        rendered_revision: self.presentation.revision,
                        in_body,
                        bounds: Rc::new(Cell::new(None)),
                    }
                }
            })
            .collect();
        if lost_focus && self.open {
            self.focus.focus(window);
        }
    }

    fn move_focus(&self, backwards: bool, window: &mut Window, cx: &mut Context<Self>) {
        let enabled: Vec<_> = self
            .controls
            .iter()
            .filter(|control| self.control_enabled(&control.control))
            .collect();
        if enabled.is_empty() {
            return;
        }
        let focused = enabled
            .iter()
            .position(|control| control.focus.is_focused(window));
        let next = match (focused, backwards) {
            (Some(index), true) => (index + enabled.len() - 1) % enabled.len(),
            (Some(index), false) => (index + 1) % enabled.len(),
            (None, true) => enabled.len() - 1,
            (None, false) => 0,
        };
        enabled[next].focus.focus(window);
        if enabled[next].in_body
            && let Some(measured) = enabled[next].bounds.get()
        {
            let mut offset = self.body_scroll.offset();
            let bounds = Bounds::new(
                measured.bounds.origin + offset - measured.scroll_offset,
                measured.bounds.size,
            );
            let viewport = self.body_scroll.bounds();
            if bounds.top() < viewport.top() {
                offset.y += viewport.top() - bounds.top();
            } else if bounds.bottom() > viewport.bottom() {
                offset.y += viewport.bottom() - bounds.bottom();
            }
            self.body_scroll.set_offset(offset);
        }
        cx.notify();
    }

    fn activate_control(
        &mut self,
        control: ProjectControl,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(rendered) = self
            .controls
            .iter()
            .find(|rendered| rendered.control == control)
        else {
            return;
        };
        if rendered.rendered_revision != self.presentation.revision
            || !self.control_enabled(&control)
        {
            return;
        }
        match control {
            ProjectControl::Intent(intent) => self.dispatch(rendered.rendered_revision, intent, cx),
            ProjectControl::Done => self.close(true, window, cx),
        }
    }

    fn enabled(&self, intent: &ProjectManagerIntent) -> bool {
        self.open && self.pending_revision.is_none() && self.presentation.allows(intent)
    }

    fn dispatch(&mut self, revision: u64, intent: ProjectManagerIntent, cx: &mut Context<Self>) {
        if revision != self.presentation.revision || !self.enabled(&intent) {
            return;
        }
        self.pending_revision = Some(revision);
        cx.emit(ProjectManagerEvent::Intent { revision, intent });
        cx.notify();
    }

    fn button(
        &self,
        id: impl Into<ElementId>,
        label: &'static str,
        intent: ProjectManagerIntent,
        primary: bool,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let p = self.palette;
        let enabled = self.enabled(&intent);
        let revision = self.presentation.revision;
        let control = self
            .controls
            .iter()
            .find(|control| control.control == ProjectControl::Intent(intent.clone()))
            .expect("rendered project control");
        let bounds = control.bounds.clone();
        let scroll = self.body_scroll.clone();
        div()
            .id(id)
            .relative()
            .px(px(11.))
            .py(px(6.))
            .rounded(px(7.))
            .border_1()
            .border_color(if primary {
                rgb(p.accent).into()
            } else {
                p.hairline()
            })
            .bg(if primary {
                rgb(p.accent)
            } else {
                rgb(p.surface)
            })
            .text_size(px(12.))
            .text_color(if primary {
                p.on_accent()
            } else {
                rgb(p.ink).into()
            })
            .flex_shrink_0()
            .when(!enabled, |button| button.opacity(0.45))
            .when(enabled, |button| {
                button
                    .track_focus(&control.focus)
                    .tab_index(0)
                    .focus(|style| {
                        style
                            .border_color(rgb(p.accent))
                            .bg(p.accent_soft())
                            .text_color(rgb(p.ink))
                    })
                    .cursor_pointer()
                    .hover(|button| button.opacity(0.82))
            })
            .on_click(cx.listener(move |view, _, _, cx| {
                view.dispatch(revision, intent.clone(), cx);
            }))
            .child(label)
            .child(
                canvas(
                    move |rectangle, _, _| {
                        bounds.set(Some(ControlGeometry {
                            bounds: rectangle,
                            scroll_offset: scroll.offset(),
                        }))
                    },
                    |_, _, _, _| {},
                )
                .absolute()
                .inset_0(),
            )
    }

    fn badge(&self, label: impl Into<SharedString>) -> Div {
        div()
            .px(px(7.))
            .py(px(2.))
            .rounded(px(5.))
            .bg(self.palette.accent_soft())
            .text_color(rgb(self.palette.accent))
            .text_size(px(10.5))
            .flex_shrink_0()
            .child(label.into())
    }

    fn folder_row(&self, path: &Path, primary: bool, index: usize, cx: &mut Context<Self>) -> Div {
        let p = self.palette;
        let path_text = path.display().to_string();
        let full_path = path_text.clone();
        let mut row = div()
            .px(px(12.))
            .py(px(7.))
            .flex()
            .items_center()
            .gap(px(8.))
            .when(!primary, |row| row.border_t_1().border_color(p.hairline()))
            .child(
                svg()
                    .path("folder")
                    .size(px(13.))
                    .flex_shrink_0()
                    .text_color(rgb(if primary { p.accent } else { p.secondary })),
            )
            .child(
                div()
                    .id(("project-folder-path", index + usize::from(!primary)))
                    .flex_1()
                    .min_w_0()
                    .text_size(px(11.5))
                    .font_family(if cfg!(target_os = "macos") {
                        "Menlo"
                    } else {
                        "DejaVu Sans Mono"
                    })
                    .truncate()
                    .tooltip(move |_, cx| cx.new(|_| FolderPathHint(full_path.clone(), p)).into())
                    .child(path_text),
            );
        if primary {
            row = row.child(self.badge("Primary"));
        } else {
            row = row.child(
                self.button(
                    ("project-remove-extra", index),
                    "Remove",
                    ProjectManagerIntent::RemoveAdditionalFolder {
                        target: self.presentation.target(),
                        path: path.to_owned(),
                    },
                    false,
                    cx,
                )
                .debug_selector(move || format!("project-remove-extra-{index}")),
            );
        }
        row
    }
}

impl Render for ProjectManagerView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.sync_controls(window, cx);
        let p = self.palette;
        let presentation = &self.presentation;
        let target = presentation.target();
        let draft = matches!(presentation.stage, ProjectManagerStage::TrustDraft { .. });
        let name = presentation
            .primary
            .file_name()
            .filter(|name| !name.is_empty())
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| presentation.primary.display().to_string());
        let mut folders = div()
            .flex_shrink_0()
            .rounded(px(8.))
            .border_1()
            .border_color(p.hairline())
            .bg(rgb(p.sunken))
            .overflow_hidden()
            .child(self.folder_row(&presentation.primary, true, 0, cx));
        for (index, path) in presentation.displayed_extras().iter().enumerate() {
            folders = folders.child(self.folder_row(path, false, index, cx));
        }
        let count = presentation.displayed_extras().len() + 1;
        let mut body = div()
            .id("project-manager-body")
            .debug_selector(|| "project-manager-body".into())
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .track_scroll(&self.body_scroll)
            .p(px(24.))
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(div().flex().flex_wrap().items_center().gap(px(8.))
                .child(div().text_size(px(17.)).font_weight(FontWeight::SEMIBOLD).child(name))
                .child(self.badge("Current"))
                .when(presentation.trusted && presentation.availability == ProjectManagerAvailability::Ready, |row| row.child(self.badge("Trusted")))
                .when(matches!(presentation.availability, ProjectManagerAvailability::Unconfirmed(_)), |row| row.child(self.badge("Trust unconfirmed")))
                .when(presentation.mode.is_fixture(), |row| row.child(self.badge("Memory-only fixture")))
                .when(presentation.mode == crate::launch_authority::AuthorityMode::Native, |row| row.child(self.badge("Rust Keychain vault · experimental"))))
            .child(div().flex().flex_col().gap(px(4.))
                .child(div().text_size(px(13.)).font_weight(FontWeight::SEMIBOLD).child(if draft { "Review project folders" } else { "Folders" }))
                .child(div().text_size(px(11.5)).text_color(rgb(p.secondary)).child("The primary folder is the working directory. Extra folders are additional locations for the same project.")))
            .child(folders)
            .child(div().flex().flex_wrap().items_center().gap(px(8.))
                .child(self.button("project-add-folders", "Add Folders…", ProjectManagerIntent::ChooseAdditionalFolders(target), false, cx)
                    .debug_selector(|| "project-add-folders".into()))
                .child(div().text_size(px(11.5)).text_color(rgb(p.tertiary)).child(format!("{count} {} · Up to {MAXIMUM_ROOTS} folders", if count == 1 { "folder" } else { "folders" }))))
            .child(div().text_size(px(11.5)).text_color(rgb(p.secondary)).child("Confirmed folder changes apply when the project host reopens on the next message."));
        if matches!(
            presentation.stage,
            ProjectManagerStage::TrustDraft {
                kind: ProjectTrustKind::Retrust,
                ..
            }
        ) {
            body = body.child(div().text_size(px(12.)).text_color(rgb(p.accent)).child("This folder is already a project. Trusting it again replaces its extra folders with the list above."));
        }
        if draft || !presentation.trusted {
            body = body.child(
                div()
                    .id("project-trust-warning")
                    .debug_selector(|| "project-trust-warning".into())
                    .flex_shrink_0()
                    .p(px(12.))
                    .rounded(px(8.))
                    .bg(p.accent_soft())
                    .text_size(px(12.))
                    .child(TRUST_WARNING),
            );
        }
        body = body.child(
            div()
                .text_size(px(11.5))
                .text_color(rgb(p.secondary))
                .child(if presentation.mode.is_fixture() { "Fixture-only tools require a saved loopback connection and confirmed project trust. Trusting or selecting never sends a request. Native production tools remain disabled." } else { TOOLS_NOTICE }),
        );
        if draft {
            body = body.child(
                div()
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap(px(8.))
                    .child(
                        self.button(
                            "project-cancel-draft",
                            "Cancel",
                            ProjectManagerIntent::CancelDraft,
                            false,
                            cx,
                        )
                        .debug_selector(|| "project-cancel-draft".into()),
                    )
                    .child(div().flex_1())
                    .child(
                        self.button(
                            "project-confirm-trust",
                            if matches!(
                                presentation.stage,
                                ProjectManagerStage::TrustDraft {
                                    kind: ProjectTrustKind::Create,
                                    ..
                                }
                            ) {
                                "Create Project"
                            } else {
                                "Trust Project"
                            },
                            ProjectManagerIntent::ConfirmTrust,
                            true,
                            cx,
                        )
                        .debug_selector(|| "project-confirm-trust".into()),
                    ),
            );
        } else {
            body = body.child(
                self.button(
                    "project-review-trust",
                    if presentation.project_id.is_some() {
                        "Review Project Trust…"
                    } else {
                        "Create Project…"
                    },
                    if presentation.project_id.is_some() {
                        ProjectManagerIntent::BeginRetrust
                    } else {
                        ProjectManagerIntent::BeginCreate
                    },
                    false,
                    cx,
                )
                .debug_selector(|| "project-review-trust".into()),
            );
        }
        let mut footer = div()
            .flex_shrink_0()
            .px(px(20.))
            .py(px(12.))
            .border_t_1()
            .border_color(p.hairline())
            .flex()
            .items_center()
            .gap(px(10.));
        if let Some((message, error)) = presentation.status() {
            footer = footer.child(
                div()
                    .id("project-manager-status")
                    .debug_selector(|| "project-manager-status".into())
                    .flex_1()
                    .min_w_0()
                    .text_size(px(11.5))
                    .text_color(rgb(if error { p.danger } else { p.secondary }))
                    .child(message.to_owned()),
            );
        } else {
            footer = footer.child(div().flex_1());
        }
        footer = footer
            .child(
                self.button(
                    "project-reload",
                    "Reload",
                    ProjectManagerIntent::Reload,
                    false,
                    cx,
                )
                .debug_selector(|| "project-reload".into()),
            )
            .child(
                div()
                    .id("project-manager-done")
                    .debug_selector(|| "project-manager-done".into())
                    .track_focus(
                        &self
                            .controls
                            .iter()
                            .find(|control| control.control == ProjectControl::Done)
                            .expect("Done control")
                            .focus,
                    )
                    .tab_index(0)
                    .px(px(11.))
                    .py(px(6.))
                    .rounded(px(7.))
                    .border_1()
                    .border_color(p.hairline())
                    .bg(rgb(p.surface))
                    .text_size(px(12.))
                    .cursor_pointer()
                    .flex_shrink_0()
                    .focus(|style| style.border_color(rgb(p.accent)).bg(p.accent_soft()))
                    .hover(|button| button.bg(p.fill()))
                    .on_click(cx.listener(|view, _, window, cx| view.close(true, window, cx)))
                    .child("Done"),
            );
        div().id("project-manager-panel").debug_selector(|| "project-manager-panel".into())
            .track_focus(&self.focus).tab_group().tab_stop(false).w_full().h_full().rounded(px(14.)).border_1().border_color(p.hairline()).bg(rgb(p.surface)).overflow_hidden().text_color(rgb(p.ink)).flex().flex_col()
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .on_key_down(cx.listener(|view, event, window, cx| { if view.key(event, window, cx) { cx.stop_propagation(); } }))
            .child(div().flex_shrink_0().px(px(24.)).py(px(18.)).border_b_1().border_color(p.hairline()).flex().flex_col().gap(px(5.))
                .child(div().text_size(px(19.)).font_weight(FontWeight::SEMIBOLD).child("Projects"))
                .child(div().text_size(px(12.)).text_color(rgb(p.secondary)).child("Current project · Review trust and additional folders for the primary folder opened in this window.")))
            .child(body).child(footer)
    }
}

#[cfg(test)]
#[path = "project_manager_view_tests.rs"]
mod tests;
