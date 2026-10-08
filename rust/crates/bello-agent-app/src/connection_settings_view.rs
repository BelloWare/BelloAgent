//! Connections-only Settings surface, following ProfileSettings.swift and
//! ConnectionSettingsController.swift. The owner retains drafts and serializes
//! vault/runtime work. This view never reads credentials, saves, or sends requests.
//!
//! Key/header replacement inputs use an isolated bounded, masked entity. Ordinary
//! metadata retains the shared editor's 8 MiB cap and roughly 16 MiB Undo budget.
//! Form/coordinator clones are additional memory; no whole-Settings memory bound
//! or native secure keyboard/accessibility acceptance is claimed.
#[path = "connection_secure_input.rs"]
pub(crate) mod secure_input;
use crate::theme::Palette;
use bello_workbench_ui::{EditorAppearance, EditorEvent, EditorView};
use gpui::{
    AnyElement, App, Bounds, Context, Div, ElementId, Entity, EventEmitter, FocusHandle, Focusable,
    FontWeight, IntoElement, KeyDownEvent, MouseButton, Pixels, Point, Render, ScrollHandle,
    Stateful, Subscription, Window, canvas, div, prelude::*, px, rgb,
};
use secure_input::{HEADER_BYTES, KEY_BYTES, SecureInput, SecureInputEvent};
use std::{cell::Cell, collections::BTreeMap, fmt, rc::Rc};

const FIXTURE_NOTICE: &str = "Fixture-only · In-memory connections. Use only numeric loopback URLs, the key synthetic-project-fixture-only, and header values synthetic-header-fixture-only. Do not enter real keys. Nothing is saved to Keychain.";
const NATIVE_NOTICE: &str = "Experimental native authority · Connections are stored in the separate Bello Agent Rust Keychain vault. No Swift settings are imported. Native signing, credential input and no-prompt acceptance remain under validation. Chats can send to your explicitly saved endpoint; model tools, MCP and project resources remain unavailable.";
const SCOPE_NOTICE: &str = "This Rust preview covers Connections only. Model catalog discovery, Mini models, routing/reasoning controls and the other Settings sections are not available here. Saving does not send a request; send explicitly from a chat.";

/// Only user-typed replacements belong in key/headers. Never populate these
/// fields from saved authority, including the synthetic saved authority.
#[derive(Clone, Default, PartialEq, Eq)]
pub(crate) struct ConnectionFields {
    pub(crate) name: String,
    pub(crate) api: String,
    pub(crate) base_url: String,
    pub(crate) model: String,
    pub(crate) context_window: String,
    pub(crate) output_budget: String,
    pub(crate) key: String,
    pub(crate) headers: String,
}

impl fmt::Debug for ConnectionFields {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ConnectionFields")
            .field("name", &self.name)
            .field("api", &self.api)
            .field("base_url", &"[typed endpoint redacted]")
            .field("model", &self.model)
            .field("context_window", &self.context_window)
            .field("output_budget", &self.output_budget)
            .field("key", &"[typed replacement redacted]")
            .field("headers", &"[typed replacement redacted]")
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ConnectionForm {
    pub(crate) id: String,
    pub(crate) saved: bool,
    pub(crate) fields: ConnectionFields,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ConnectionTab {
    pub(crate) id: String,
    pub(crate) label: String,
    pub(crate) saved: bool,
    pub(crate) dirty: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ConnectionSettingsAvailability {
    Loading,
    Ready,
    Busy(String),
    Unavailable(String),
    Failed(String),
    Unconfirmed(String),
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) enum ConnectionConfirmation {
    #[default]
    None,
    Delete {
        summary: String,
    },
    Close,
    Reload,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ConnectionSettingsNotice {
    pub(crate) text: String,
    pub(crate) is_error: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ConnectionSettingsPresentation {
    /// Monotonic coordinator revision, including completed operations and edits.
    pub(crate) revision: u64,
    pub(crate) mode: crate::launch_authority::AuthorityMode,
    pub(crate) availability: ConnectionSettingsAvailability,
    /// Loading is busy but may close. Saving/deleting must finish before close.
    pub(crate) saving: bool,
    pub(crate) tabs: Vec<ConnectionTab>,
    pub(crate) active: Option<ConnectionForm>,
    pub(crate) dirty: bool,
    pub(crate) confirmation: ConnectionConfirmation,
    pub(crate) notice: Option<ConnectionSettingsNotice>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ConnectionSettingsIntent {
    Edited,
    Select(String),
    New,
    SaveAll,
    Cancel,
    Reload,
    DiscardCurrent,
    RequestDelete,
    ConfirmDelete,
    Keep,
    RequestClose,
    SaveAndClose,
    DiscardAndClose,
    KeepEditing,
    DiscardAndReload,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ConnectionSettingsEvent {
    Intent {
        revision: u64,
        active_id: Option<String>,
        /// Capture typing and the action together. A final edit notification
        /// need not have arrived before Save, tab selection, or close.
        fields: Option<Box<ConnectionFields>>,
        intent: ConnectionSettingsIntent,
    },
    Dismissed {
        revision: u64,
    },
}

impl ConnectionSettingsPresentation {
    fn busy(&self) -> bool {
        self.saving
            || matches!(
                self.availability,
                ConnectionSettingsAvailability::Loading | ConnectionSettingsAvailability::Busy(_)
            )
    }

    fn editable(&self) -> bool {
        self.mode.editable()
            && !self.busy()
            && self.availability == ConnectionSettingsAvailability::Ready
            && self.confirmation == ConnectionConfirmation::None
            && self.active.is_some()
    }

    /// Conservative UI affordances only; the coordinator rechecks revision,
    /// authority, active work and its actual draft before acting.
    pub(crate) fn allows(&self, intent: &ConnectionSettingsIntent) -> bool {
        use ConnectionConfirmation as Confirmation;
        use ConnectionSettingsIntent as Intent;
        if self.saving {
            return false;
        }
        if matches!(intent, Intent::RequestClose | Intent::Cancel) {
            return self.confirmation == Confirmation::None;
        }
        match &self.confirmation {
            Confirmation::Close => {
                return match intent {
                    Intent::KeepEditing | Intent::DiscardAndClose => true,
                    Intent::SaveAndClose => {
                        self.mode.editable()
                            && !self.busy()
                            && self.availability == ConnectionSettingsAvailability::Ready
                    }
                    _ => false,
                };
            }
            Confirmation::Reload => {
                return match intent {
                    Intent::KeepEditing => true,
                    Intent::DiscardAndReload => !self.busy(),
                    _ => false,
                };
            }
            Confirmation::Delete { .. } => {
                return match intent {
                    Intent::Keep => !self.busy(),
                    Intent::ConfirmDelete => {
                        self.mode.editable()
                            && !self.busy()
                            && self.availability == ConnectionSettingsAvailability::Ready
                            && self.active.as_ref().is_some_and(|form| form.saved)
                    }
                    _ => false,
                };
            }
            Confirmation::None => {}
        }
        if matches!(intent, Intent::Reload) {
            return !self.busy();
        }
        if !self.editable() {
            return false;
        }
        match intent {
            Intent::Edited | Intent::New | Intent::SaveAll => true,
            Intent::Select(id) => {
                self.tabs.iter().any(|tab| &tab.id == id)
                    && self.active.as_ref().is_some_and(|form| &form.id != id)
            }
            Intent::DiscardCurrent => self.active.as_ref().is_some_and(|form| !form.saved),
            Intent::RequestDelete => self.active.as_ref().is_some_and(|form| form.saved),
            _ => false,
        }
    }

    fn status(&self) -> Option<(&str, bool)> {
        use ConnectionSettingsAvailability as Availability;
        match &self.availability {
            Availability::Loading => Some(("Loading connections… Nothing has been sent.", false)),
            Availability::Busy(message) => Some((message, false)),
            Availability::Unavailable(message)
            | Availability::Failed(message)
            | Availability::Unconfirmed(message) => Some((message, true)),
            Availability::Ready => self
                .notice
                .as_ref()
                .map(|notice| (notice.text.as_str(), notice.is_error)),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Field {
    Name,
    BaseUrl,
    Key,
    Headers,
    Model,
    ContextWindow,
    OutputBudget,
}

impl Field {
    const ALL: [Self; 7] = [
        Self::Name,
        Self::BaseUrl,
        Self::Key,
        Self::Headers,
        Self::Model,
        Self::ContextWindow,
        Self::OutputBudget,
    ];
    fn value(self, fields: &ConnectionFields) -> &str {
        match self {
            Self::Name => &fields.name,
            Self::BaseUrl => &fields.base_url,
            Self::Key => &fields.key,
            Self::Headers => &fields.headers,
            Self::Model => &fields.model,
            Self::ContextWindow => &fields.context_window,
            Self::OutputBudget => &fields.output_budget,
        }
    }
    fn assign(self, fields: &mut ConnectionFields, value: String) {
        match self {
            Self::Name => fields.name = value,
            Self::BaseUrl => fields.base_url = value,
            Self::Key => fields.key = value,
            Self::Headers => fields.headers = value,
            Self::Model => fields.model = value,
            Self::ContextWindow => fields.context_window = value,
            Self::OutputBudget => fields.output_budget = value,
        }
    }
    fn id(self) -> &'static str {
        match self {
            Self::Name => "settings-connection-name",
            Self::BaseUrl => "settings-base-url",
            Self::Key => "settings-api-key",
            Self::Headers => "settings-custom-headers",
            Self::Model => "settings-model-alias",
            Self::ContextWindow => "settings-context-window",
            Self::OutputBudget => "settings-output-budget",
        }
    }
}

struct FormEditors {
    last_presented: ConnectionFields,
    fields: BTreeMap<Field, Entity<EditorView>>,
    secrets: BTreeMap<Field, Entity<SecureInput>>,
    _subscriptions: Vec<Subscription>,
}

impl FormEditors {
    fn focus(&self, field: Field, cx: &App) -> Option<FocusHandle> {
        self.fields
            .get(&field)
            .map(|input| input.read(cx).focus_handle(cx))
            .or_else(|| {
                self.secrets
                    .get(&field)
                    .map(|input| input.read(cx).focus_handle(cx))
            })
    }
    fn empty(&self, field: Field, cx: &App) -> bool {
        self.fields.get(&field).map_or_else(
            || self.secrets[&field].read(cx).text().is_empty(),
            |input| input.read(cx).text().is_empty(),
        )
    }
    fn element(&self, field: Field) -> AnyElement {
        match self.fields.get(&field) {
            Some(input) => input.clone().into_any_element(),
            None => self.secrets[&field].clone().into_any_element(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Control {
    Intent(ConnectionSettingsIntent),
    Field(Field),
}

struct ControlFocus {
    control: Control,
    focus: FocusHandle,
    token: RenderToken,
    in_body: bool,
    bounds: Rc<Cell<Option<ControlGeometry>>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct RenderToken {
    revision: u64,
    opening: u64,
}

#[derive(Clone, Copy)]
struct ControlGeometry {
    bounds: Bounds<Pixels>,
    scroll_offset: Point<Pixels>,
}

pub(crate) struct ConnectionSettingsView {
    presentation: ConnectionSettingsPresentation,
    palette: Palette,
    focus: FocusHandle,
    previous_focus: Option<FocusHandle>,
    open: bool,
    opening: u64,
    pending_revision: Option<u64>,
    editors: BTreeMap<String, FormEditors>,
    controls: Vec<ControlFocus>,
    body_scroll: ScrollHandle,
    tab_scroll: ScrollHandle,
}

impl EventEmitter<ConnectionSettingsEvent> for ConnectionSettingsView {}
impl Focusable for ConnectionSettingsView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl ConnectionSettingsView {
    pub(crate) fn new(
        presentation: ConnectionSettingsPresentation,
        palette: Palette,
        cx: &mut Context<Self>,
    ) -> Self {
        Self {
            presentation,
            palette,
            focus: cx.focus_handle(),
            previous_focus: None,
            open: false,
            opening: 0,
            pending_revision: None,
            editors: BTreeMap::new(),
            controls: Vec::new(),
            body_scroll: ScrollHandle::new(),
            tab_scroll: ScrollHandle::new(),
        }
    }

    pub(crate) fn set_presentation(
        &mut self,
        presentation: ConnectionSettingsPresentation,
        cx: &mut Context<Self>,
    ) {
        if presentation.revision <= self.presentation.revision {
            return;
        }
        let replace_local = self.pending_revision.is_some()
            || self.presentation.active.as_ref().map(|form| &form.id)
                != presentation.active.as_ref().map(|form| &form.id);
        let active_changed = self.presentation.active.as_ref().map(|form| &form.id)
            != presentation.active.as_ref().map(|form| &form.id);
        self.presentation = presentation;
        if active_changed {
            self.reveal_active_tab();
        }
        self.pending_revision = None;
        self.editors.retain(|id, _| {
            self.presentation.tabs.iter().any(|tab| &tab.id == id)
                || self
                    .presentation
                    .active
                    .as_ref()
                    .is_some_and(|form| &form.id == id)
        });
        self.sync_existing_editors(replace_local, cx);
        // A delayed acknowledgement may describe an earlier edit. Publish any
        // newer local text against the new revision after preserving it below.
        self.edited(cx);
        cx.notify();
    }

    fn appearance(p: Palette, mono: bool) -> EditorAppearance {
        EditorAppearance {
            font_family: if mono {
                if cfg!(target_os = "macos") {
                    "Menlo"
                } else {
                    "DejaVu Sans Mono"
                }
            } else if cfg!(target_os = "macos") {
                ".SystemUIFont"
            } else {
                "DejaVu Sans"
            }
            .into(),
            font_size: 12.,
            line_height: 19.,
            padding_x: 8.,
            padding_y: 5.,
            text: rgb(p.ink).into(),
            selection: p.accent_soft(),
            caret: rgb(p.accent).into(),
            wrap_lines: false,
            ..EditorAppearance::plain()
        }
    }

    pub(crate) fn set_palette(&mut self, palette: Palette, cx: &mut Context<Self>) {
        if self.palette == palette {
            return;
        }
        self.palette = palette;
        for editors in self.editors.values() {
            for (field, editor) in &editors.fields {
                editor.update(cx, |editor, cx| {
                    editor.set_appearance(Self::appearance(palette, *field != Field::Name), cx)
                });
            }
            for editor in editors.secrets.values() {
                editor.update(cx, |editor, cx| {
                    editor.set_appearance(Self::appearance(palette, false), cx)
                });
            }
        }
        cx.notify();
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
        self.opening = self.opening.wrapping_add(1);
        self.open = true;
        self.pending_revision = None;
        self.ensure_editors(window, cx);
        self.reveal_active_tab();
        self.sync_existing_editors(true, cx);
        self.focus.focus(window);
        cx.notify();
    }

    /// Only the coordinator calls close, after deciding what to do with edits.
    /// Hiding the view itself neither saves nor discards any form.
    pub(crate) fn close(
        &mut self,
        restore_focus: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.open {
            return;
        }
        self.open = false;
        self.opening = self.opening.wrapping_add(1);
        self.pending_revision = None;
        if restore_focus
            && self.owns_focus(window, cx)
            && let Some(previous) = self.previous_focus.take()
        {
            previous.focus(window);
        }
        self.previous_focus = None;
        self.set_editors_read_only(true, cx);
        cx.emit(ConnectionSettingsEvent::Dismissed {
            revision: self.presentation.revision,
        });
        cx.notify();
    }

    fn reveal_active_tab(&self) {
        if let Some(active) = &self.presentation.active
            && let Some(index) = self
                .presentation
                .tabs
                .iter()
                .position(|tab| tab.id == active.id)
        {
            self.tab_scroll.scroll_to_item(index);
        }
    }

    fn token(&self) -> RenderToken {
        RenderToken {
            revision: self.presentation.revision,
            opening: self.opening,
        }
    }

    fn ensure_editors(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(form) = &self.presentation.active else {
            return;
        };
        if !self.editors.contains_key(&form.id) {
            let id = form.id.clone();
            let mut fields = BTreeMap::new();
            let mut secrets = BTreeMap::new();
            let mut subscriptions = Vec::new();
            for field in Field::ALL {
                let value = field.value(&form.fields).to_owned();
                if matches!(field, Field::Key | Field::Headers) {
                    let editor = cx.new(|cx| {
                        let mut editor = SecureInput::new(
                            if field == Field::Key {
                                KEY_BYTES
                            } else {
                                HEADER_BYTES
                            },
                            Self::appearance(self.palette, false),
                            cx,
                        );
                        editor.set_text(value, cx);
                        editor.set_read_only(!self.open || !self.presentation.editable(), cx);
                        editor
                    });
                    let id = id.clone();
                    subscriptions.push(cx.subscribe(&editor, move |view, _, event, cx| {
                        if view
                            .presentation
                            .active
                            .as_ref()
                            .is_none_or(|form| form.id != id)
                        {
                            return;
                        }
                        match event {
                            SecureInputEvent::Changed => view.edited(cx),
                            SecureInputEvent::Rejected => cx.notify(),
                        }
                    }));
                    secrets.insert(field, editor);
                    continue;
                }
                let editor = cx.new(|cx| {
                    let mut editor = EditorView::new(value, window, cx);
                    editor.set_compact(true, cx);
                    editor.set_read_only(!self.open || !self.presentation.editable(), cx);
                    editor.set_appearance(Self::appearance(self.palette, field != Field::Name), cx);
                    editor
                });
                let id = id.clone();
                subscriptions.push(cx.subscribe(&editor, move |view, _, event, cx| {
                    if view
                        .presentation
                        .active
                        .as_ref()
                        .is_none_or(|form| form.id != id)
                    {
                        return;
                    }
                    match event {
                        EditorEvent::Changed => view.edited(cx),
                        // Save belongs to the revision/opening-scoped root key
                        // handler. Editor events carry no generation token.
                        EditorEvent::SaveRequested | EditorEvent::LayoutChanged => {}
                    }
                }));
                fields.insert(field, editor);
            }
            self.editors.insert(
                id,
                FormEditors {
                    last_presented: form.fields.clone(),
                    fields,
                    secrets,
                    _subscriptions: subscriptions,
                },
            );
        }
    }

    fn set_editors_read_only(&self, read_only: bool, cx: &mut Context<Self>) {
        for editors in self.editors.values() {
            for editor in editors.fields.values() {
                editor.update(cx, |editor, cx| editor.set_read_only(read_only, cx));
            }
            for editor in editors.secrets.values() {
                editor.update(cx, |editor, cx| editor.set_read_only(read_only, cx));
            }
        }
    }

    fn sync_existing_editors(&mut self, replace_local: bool, cx: &mut Context<Self>) {
        let editable = self.open && self.presentation.editable() && self.pending_revision.is_none();
        for (id, editors) in &mut self.editors {
            let active = self
                .presentation
                .active
                .as_ref()
                .filter(|form| &form.id == id);
            for (field, editor) in &editors.fields {
                editor.update(cx, |editor, cx| {
                    if let Some(form) = active {
                        let value = field.value(&form.fields);
                        // Status revisions and delayed edit acknowledgements
                        // must not erase newer local typing/IME. Explicit action
                        // acknowledgements and tab changes replace it deliberately.
                        if editor.text() != value
                            && (replace_local
                                || editor.text() == field.value(&editors.last_presented))
                        {
                            editor.set_text(value.to_owned(), cx);
                        }
                    }
                    editor.set_read_only(!editable || active.is_none(), cx);
                });
            }
            for (field, editor) in &editors.secrets {
                editor.update(cx, |editor, cx| {
                    if let Some(form) = active {
                        let value = field.value(&form.fields);
                        if editor.text() != value
                            && (replace_local
                                || (!editor.has_marked_text()
                                    && editor.text() == field.value(&editors.last_presented)))
                        {
                            editor.set_text(value.to_owned(), cx);
                        }
                    }
                    editor.set_read_only(!editable || active.is_none(), cx);
                });
            }
            if let Some(form) = active {
                editors.last_presented = form.fields.clone();
            }
        }
    }

    pub(crate) fn captured_fields(&self, cx: &App) -> Option<ConnectionFields> {
        let form = self.presentation.active.as_ref()?;
        let mut fields = form.fields.clone();
        if let Some(editors) = self.editors.get(&form.id) {
            for (field, editor) in &editors.fields {
                field.assign(&mut fields, editor.read(cx).text().to_owned());
            }
            for (field, editor) in &editors.secrets {
                if let Some(value) = editor.read(cx).captured_text() {
                    field.assign(&mut fields, value.to_owned());
                }
            }
        }
        Some(fields)
    }

    fn composing(&self, cx: &App) -> bool {
        self.presentation
            .active
            .as_ref()
            .and_then(|form| self.editors.get(&form.id))
            .is_some_and(|editors| {
                editors
                    .fields
                    .values()
                    .any(|editor| editor.read(cx).has_marked_text())
                    || editors
                        .secrets
                        .values()
                        .any(|editor| editor.read(cx).has_marked_text())
            })
    }

    fn edited(&mut self, cx: &mut Context<Self>) {
        if !self.enabled(&ConnectionSettingsIntent::Edited) || self.composing(cx) {
            return;
        }
        let Some(fields) = self.captured_fields(cx) else {
            return;
        };
        if self
            .presentation
            .active
            .as_ref()
            .is_some_and(|form| form.fields == fields)
        {
            return;
        }
        self.dispatch(self.token(), ConnectionSettingsIntent::Edited, cx);
    }

    fn enabled(&self, intent: &ConnectionSettingsIntent) -> bool {
        self.open && self.pending_revision.is_none() && self.presentation.allows(intent)
    }

    fn dispatch(
        &mut self,
        token: RenderToken,
        intent: ConnectionSettingsIntent,
        cx: &mut Context<Self>,
    ) {
        if token != self.token() || !self.enabled(&intent) || self.composing(cx) {
            return;
        }
        let fields = self.captured_fields(cx).map(Box::new);
        let active_id = self
            .presentation
            .active
            .as_ref()
            .map(|form| form.id.clone());
        if intent != ConnectionSettingsIntent::Edited {
            self.pending_revision = Some(token.revision);
            self.set_editors_read_only(true, cx);
        }
        cx.emit(ConnectionSettingsEvent::Intent {
            revision: token.revision,
            active_id,
            fields,
            intent,
        });
        cx.notify();
    }

    /// Native/window close must capture the editor just like the Done button.
    /// The coordinator cannot infer cleanliness from an older acknowledged form.
    pub(crate) fn request_close(&mut self, cx: &mut Context<Self>) {
        self.dispatch(self.token(), ConnectionSettingsIntent::RequestClose, cx);
    }

    pub(crate) fn key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.open || self.composing(cx) {
            return false;
        }
        let mods = event.keystroke.modifiers;
        let command = mods.platform || (cfg!(target_os = "linux") && mods.control);
        let intent = match event.keystroke.key.as_str() {
            "escape" if !mods.platform && !mods.control && !mods.alt => {
                Some(match self.presentation.confirmation {
                    ConnectionConfirmation::Close | ConnectionConfirmation::Reload => {
                        ConnectionSettingsIntent::KeepEditing
                    }
                    ConnectionConfirmation::Delete { .. } => ConnectionSettingsIntent::Keep,
                    ConnectionConfirmation::None => ConnectionSettingsIntent::RequestClose,
                })
            }
            "w" if command => Some(ConnectionSettingsIntent::RequestClose),
            "s" if command => Some(
                if self.presentation.confirmation == ConnectionConfirmation::Close {
                    ConnectionSettingsIntent::SaveAndClose
                } else {
                    ConnectionSettingsIntent::SaveAll
                },
            ),
            _ => None,
        };
        if let Some(intent) = intent {
            if !event.is_held {
                self.dispatch(self.token(), intent, cx);
            }
            return true;
        }
        if event.keystroke.key == "tab" && !mods.platform && !mods.control && !mods.alt {
            self.move_focus(mods.shift, window, cx);
            return true;
        }
        if matches!(event.keystroke.key.as_str(), "enter" | "space")
            && !mods.platform
            && !mods.control
            && !mods.alt
            && !mods.shift
            && let Some(control) = self
                .controls
                .iter()
                .find(|control| control.focus.is_focused(window))
            && let Control::Intent(intent) = &control.control
        {
            let intent = intent.clone();
            let token = control.token;
            if !event.is_held {
                self.dispatch(token, intent, cx);
            }
            return true;
        }
        false
    }

    fn current_controls(&self) -> Vec<Control> {
        use ConnectionSettingsIntent as Intent;
        let mut controls: Vec<_> = self
            .presentation
            .tabs
            .iter()
            .map(|tab| Control::Intent(Intent::Select(tab.id.clone())))
            .collect();
        controls.extend([
            Control::Intent(Intent::New),
            Control::Intent(Intent::Reload),
        ]);
        if self.presentation.active.is_some() {
            controls.push(Control::Field(Field::Name));
            controls.extend(Field::ALL.into_iter().skip(1).map(Control::Field));
        }
        match self.presentation.confirmation {
            ConnectionConfirmation::None => {
                if let Some(form) = &self.presentation.active {
                    controls.push(Control::Intent(if form.saved {
                        Intent::RequestDelete
                    } else {
                        Intent::DiscardCurrent
                    }));
                }
                controls.extend([
                    Control::Intent(Intent::Cancel),
                    Control::Intent(Intent::RequestClose),
                    Control::Intent(Intent::SaveAll),
                ]);
            }
            ConnectionConfirmation::Delete { .. } => controls.extend([
                Control::Intent(Intent::Keep),
                Control::Intent(Intent::ConfirmDelete),
            ]),
            ConnectionConfirmation::Close => controls.extend([
                Control::Intent(Intent::KeepEditing),
                Control::Intent(Intent::DiscardAndClose),
                Control::Intent(Intent::SaveAndClose),
            ]),
            ConnectionConfirmation::Reload => controls.extend([
                Control::Intent(Intent::KeepEditing),
                Control::Intent(Intent::DiscardAndReload),
            ]),
        }
        controls
    }

    fn control_enabled(&self, control: &Control) -> bool {
        match control {
            Control::Intent(intent) => self.enabled(intent),
            Control::Field(_) => {
                self.open && self.pending_revision.is_none() && self.presentation.editable()
            }
        }
    }

    fn sync_controls(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let current = self.current_controls();
        let lost_focus = self.controls.iter().any(|control| {
            let field_rebound = match control.control {
                Control::Field(field) => self
                    .presentation
                    .active
                    .as_ref()
                    .and_then(|form| self.editors.get(&form.id))
                    .and_then(|editors| editors.focus(field, cx))
                    .is_none_or(|focus| focus != control.focus),
                Control::Intent(_) => false,
            };
            control.focus.is_focused(window)
                && (field_rebound
                    || !current.contains(&control.control)
                    || !self.control_enabled(&control.control))
        });
        let mut previous = std::mem::take(&mut self.controls);
        let token = self.token();
        self.controls = current
            .into_iter()
            .map(|control| {
                let field_focus = match control {
                    Control::Field(field) => self
                        .presentation
                        .active
                        .as_ref()
                        .and_then(|form| self.editors.get(&form.id))
                        .and_then(|editors| editors.focus(field, cx)),
                    _ => None,
                };
                if let Some(index) = previous.iter().position(|old| old.control == control) {
                    let mut retained = previous.remove(index);
                    retained.token = token;
                    if let Some(focus) = field_focus {
                        retained.focus = focus;
                    }
                    retained
                } else {
                    let in_body = matches!(control, Control::Field(_));
                    ControlFocus {
                        control,
                        focus: field_focus.unwrap_or_else(|| cx.focus_handle()),
                        token,
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
        if let Control::Intent(ConnectionSettingsIntent::Select(id)) = &enabled[next].control
            && let Some(index) = self.presentation.tabs.iter().position(|tab| &tab.id == id)
        {
            self.tab_scroll.scroll_to_item(index);
        }
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

    fn button(
        &self,
        id: impl Into<ElementId>,
        label: impl Into<String>,
        intent: ConnectionSettingsIntent,
        primary: bool,
        danger: bool,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let p = self.palette;
        let enabled = self.enabled(&intent);
        let token = self.token();
        let control = self
            .controls
            .iter()
            .find(|control| control.control == Control::Intent(intent.clone()))
            .expect("rendered settings control");
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
                rgb(if danger { p.danger } else { p.ink }).into()
            })
            .flex_shrink_0()
            .when(!enabled, |button| button.opacity(0.45))
            .when(enabled, |button| {
                button
                    .track_focus(&control.focus)
                    .tab_index(0)
                    .cursor_pointer()
                    .focus(|style| {
                        style
                            .border_color(rgb(p.accent))
                            .bg(p.accent_soft())
                            .text_color(rgb(p.ink))
                    })
                    .hover(|style| style.opacity(0.82))
            })
            .on_click(cx.listener(move |view, _, _, cx| view.dispatch(token, intent.clone(), cx)))
            .child(label.into())
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

    fn field_row(
        &self,
        field: Field,
        label: &'static str,
        detail: &'static str,
        placeholder: &'static str,
        cx: &mut Context<Self>,
    ) -> Div {
        let p = self.palette;
        let form = self
            .presentation
            .active
            .as_ref()
            .expect("active settings form");
        let editors = &self.editors[&form.id];
        let editor = editors.element(field);
        let empty = editors.empty(field, cx);
        let focus_editor = editors.focus(field, cx).expect("field input focus");
        let rejection = editors
            .secrets
            .get(&field)
            .and_then(|input| input.read(cx).rejection());
        let enabled = self.control_enabled(&Control::Field(field));
        let control = self
            .controls
            .iter()
            .find(|control| control.control == Control::Field(field))
            .expect("field control");
        let bounds = control.bounds.clone();
        let scroll = self.body_scroll.clone();
        let token = self.token();
        let id = form.id.clone();
        div()
            .flex_shrink_0()
            .flex()
            .flex_wrap()
            .items_start()
            .gap(px(12.))
            .px(px(14.))
            .py(px(12.))
            .when(field != Field::Name, |row| {
                row.border_t_1().border_color(p.hairline())
            })
            .child(
                div()
                    .w(px(215.))
                    .flex_shrink_0()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
                    .child(
                        div()
                            .text_size(px(12.))
                            .font_weight(FontWeight::MEDIUM)
                            .child(label),
                    )
                    .child(
                        div()
                            .text_size(px(10.5))
                            .text_color(rgb(p.secondary))
                            .child(detail),
                    )
                    .when_some(rejection, |label, message| {
                        label.child(
                            div()
                                .id("settings-secret-rejection")
                                .debug_selector(move || format!("{}-rejection", field.id()))
                                .text_size(px(10.5))
                                .text_color(rgb(p.danger))
                                .child(message),
                        )
                    }),
            )
            .child(
                div()
                    .id(field.id())
                    .debug_selector(move || field.id().into())
                    .relative()
                    .flex_1()
                    .min_w(px(210.))
                    .h(px(31.))
                    .rounded(px(6.))
                    .border_1()
                    .border_color(p.hairline())
                    .bg(rgb(p.sunken))
                    .overflow_hidden()
                    .when(!enabled, |field| field.opacity(0.5))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |view, _, window, _cx| {
                            if view.token() == token
                                && view
                                    .presentation
                                    .active
                                    .as_ref()
                                    .is_some_and(|form| form.id == id)
                                && view.control_enabled(&Control::Field(field))
                            {
                                focus_editor.focus(window);
                            }
                        }),
                    )
                    .child(editor)
                    .when(empty, |field| {
                        field.child(
                            div()
                                .absolute()
                                .inset_0()
                                .px(px(8.))
                                .py(px(5.))
                                .text_size(px(12.))
                                .text_color(rgb(p.tertiary))
                                .child(placeholder),
                        )
                    })
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
                    ),
            )
    }
}

impl Render for ConnectionSettingsView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.ensure_editors(window, cx);
        self.sync_controls(window, cx);
        let p = self.palette;
        let presentation = &self.presentation;
        let mut tabs = div()
            .id("settings-connection-tabs")
            .debug_selector(|| "settings-connection-tabs".into())
            .flex_1()
            .min_w_0()
            .h(px(33.))
            .overflow_x_scroll()
            .track_scroll(&self.tab_scroll)
            .flex()
            .items_center()
            .gap(px(6.));
        for (index, tab) in presentation.tabs.iter().enumerate() {
            let selected = presentation
                .active
                .as_ref()
                .is_some_and(|form| form.id == tab.id);
            let label = format!(
                "{}{}{}",
                tab.label,
                if tab.dirty { " •" } else { "" },
                if tab.saved { "" } else { " · new" }
            );
            tabs = tabs.child(
                self.button(
                    ("settings-tab", index),
                    label,
                    ConnectionSettingsIntent::Select(tab.id.clone()),
                    false,
                    false,
                    cx,
                )
                .when(selected, |tab| {
                    tab.opacity(1.)
                        .bg(p.accent_soft())
                        .border_color(rgb(p.accent))
                })
                .debug_selector(move || format!("settings-tab-{index}")),
            );
        }
        let tab_bar = div()
            .flex()
            .items_center()
            .gap(px(8.))
            .child(tabs)
            .child(
                self.button(
                    "settings-new-connection",
                    "+ New",
                    ConnectionSettingsIntent::New,
                    false,
                    false,
                    cx,
                )
                .debug_selector(|| "settings-new-connection".into()),
            )
            .child(
                self.button(
                    "settings-reload",
                    "Reload",
                    ConnectionSettingsIntent::Reload,
                    false,
                    false,
                    cx,
                )
                .debug_selector(|| "settings-reload".into()),
            );
        let mut body = div()
            .id("settings-body")
            .debug_selector(|| "settings-body".into())
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .track_scroll(&self.body_scroll)
            .p(px(24.))
            .flex()
            .flex_col()
            .gap(px(16.));
        if presentation.mode.is_fixture() {
            body = body.child(
                div()
                    .id("settings-fixture-notice")
                    .debug_selector(|| "settings-fixture-notice".into())
                    .flex_shrink_0()
                    .p(px(12.))
                    .rounded(px(8.))
                    .bg(p.accent_soft())
                    .text_size(px(11.5))
                    .child(FIXTURE_NOTICE),
            );
        }
        if presentation.mode == crate::launch_authority::AuthorityMode::Native {
            body = body.child(
                div()
                    .id("settings-native-notice")
                    .debug_selector(|| "settings-native-notice".into())
                    .flex_shrink_0()
                    .p(px(12.))
                    .rounded(px(8.))
                    .bg(p.accent_soft())
                    .text_size(px(11.5))
                    .child(NATIVE_NOTICE),
            );
        }
        if let Some(form) = &presentation.active {
            let mut fields = div()
                .flex_shrink_0()
                .rounded(px(8.))
                .border_1()
                .border_color(p.hairline())
                .overflow_hidden()
                .child(self.field_row(
                    Field::Name,
                    "Name",
                    "Rename freely: the connection keeps its identity and earlier chats.",
                    if presentation.mode.is_fixture() { "Fixture router" } else { "Connection name" },
                    cx,
                ))
                .child(
                    div()
                        .px(px(14.))
                        .py(px(12.))
                        .border_t_1()
                        .border_color(p.hairline())
                        .flex()
                        .flex_wrap()
                        .items_center()
                        .gap(px(12.))
                        .child(
                            div()
                                .w(px(215.))
                                .text_size(px(12.))
                                .font_weight(FontWeight::MEDIUM)
                                .child("LiteLLM API"),
                        )
                        .child(div().text_size(px(12.)).text_color(rgb(p.secondary)).child(
                            if form.fields.api == "openai-responses" {
                                "Responses"
                            } else {
                                "Messages / unsupported API · history only"
                            },
                        ))
                        .when(form.fields.api != "openai-responses", |row| {
                            row.child(div().id("settings-history-only-api")
                                .debug_selector(|| "settings-history-only-api".into())
                                .text_size(px(11.5)).text_color(rgb(p.secondary))
                                .child("History-only connection; conversion is unavailable in this preview."))
                        }),
                );
            for (field, label, detail, placeholder) in [
                (
                    Field::BaseUrl,
                    "Base URL or full API route",
                    if presentation.mode.is_fixture() {
                        "Fixture-only: numeric loopback endpoint. Route changes save a new identity; earlier chats keep the original."
                    } else {
                        "HTTPS is required except for loopback. Route changes save a new identity; earlier chats keep the original."
                    },
                    if presentation.mode.is_fixture() {
                        "http://127.0.0.1:PORT"
                    } else {
                        "Your HTTPS endpoint"
                    },
                ),
                (
                    Field::Key,
                    if presentation.mode.is_fixture() {
                        "Fixture API key"
                    } else {
                        "API key"
                    },
                    if presentation.mode.is_fixture() {
                        "Blank keeps the saved key. Only synthetic-project-fixture-only is accepted. Saved keys are never shown."
                    } else {
                        "Enter a key for a new connection. Blank keeps the saved key. Saved keys are never shown."
                    },
                    if presentation.mode.is_fixture() {
                        "Blank preserves saved fake key"
                    } else {
                        "Blank preserves saved key"
                    },
                ),
                (
                    Field::Headers,
                    "Custom headers JSON",
                    if presentation.mode.is_fixture() {
                        "Blank preserves saved headers; {} clears them. Values must be synthetic-header-fixture-only."
                    } else {
                        "Blank preserves saved headers; {} clears them. Saved values are never shown."
                    },
                    "Blank preserves; {} clears",
                ),
                (
                    Field::Model,
                    "Requested model / router alias",
                    if presentation.mode.is_fixture() {
                        "Type the fixture model alias. Changing it saves a new connection for new chats."
                    } else {
                        "Type your model or router alias. Changing it saves a new connection for new chats."
                    },
                    if presentation.mode.is_fixture() {
                        "fixture-model"
                    } else {
                        "Model or router alias"
                    },
                ),
                (
                    Field::ContextWindow,
                    "Configured context capacity",
                    "Tokens. Runtime compaction and accounting remain outside this Connections preview.",
                    "32000",
                ),
                (
                    Field::OutputBudget,
                    "Output budget",
                    "Tokens set aside for a reply. This budget is not a request output limit.",
                    "4096",
                ),
            ] {
                fields = fields.child(self.field_row(field, label, detail, placeholder, cx));
            }
            body = body.child(div().flex_shrink_0().text_size(px(14.)).font_weight(FontWeight::SEMIBOLD)
                .child(if form.saved { "Connection" } else { "New connection" })).child(fields)
                .child(div().flex_shrink_0().text_size(px(11.5)).text_color(rgb(p.secondary)).child("Leave the key and headers empty to keep saved values. Save All saves edited tabs one at a time; if one fails, earlier successful saves remain saved."));
        }
        body = body.child(
            div()
                .flex_shrink_0()
                .text_size(px(11.5))
                .text_color(rgb(p.secondary))
                .child(SCOPE_NOTICE),
        );
        let mut footer = div()
            .flex_shrink_0()
            .px(px(20.))
            .py(px(12.))
            .border_t_1()
            .border_color(p.hairline())
            .flex()
            .flex_col()
            .gap(px(10.));
        if let Some((message, error)) = presentation.status() {
            footer = footer.child(
                div()
                    .id("settings-status")
                    .debug_selector(|| "settings-status".into())
                    .text_size(px(11.5))
                    .text_color(rgb(if error { p.danger } else { p.secondary }))
                    .child(message.to_owned()),
            );
        }
        let mut actions = div().flex().flex_wrap().items_center().gap(px(8.));
        use ConnectionSettingsIntent as Intent;
        let buttons: Vec<(&str, &str, Intent, bool, bool)> = match &presentation.confirmation {
            ConnectionConfirmation::Delete { summary } => {
                footer = footer.child(
                    div()
                        .id("settings-delete-connection-question")
                        .debug_selector(|| "settings-delete-connection-question".into())
                        .text_size(px(12.))
                        .text_color(rgb(p.danger))
                        .child(format!(
                            "Delete “{}”? {}",
                            presentation
                                .active
                                .as_ref()
                                .map_or("Unnamed", |form| form.fields.name.as_str()),
                            summary
                        )),
                );
                vec![
                    (
                        "settings-keep-connection",
                        "Keep",
                        Intent::Keep,
                        false,
                        false,
                    ),
                    (
                        "settings-confirm-delete-connection",
                        "Delete Connection",
                        Intent::ConfirmDelete,
                        false,
                        true,
                    ),
                ]
            }
            ConnectionConfirmation::Close => {
                footer = footer.child(div().id("settings-unsaved-question").debug_selector(|| "settings-unsaved-question".into()).text_size(px(12.))
                    .child("Save your Settings changes? Unsaved changes in Connections. Discarding keeps the saved connections."));
                vec![
                    (
                        "settings-keep-editing",
                        "Keep Editing",
                        Intent::KeepEditing,
                        false,
                        false,
                    ),
                    (
                        "settings-discard-close",
                        "Discard Changes",
                        Intent::DiscardAndClose,
                        false,
                        true,
                    ),
                    (
                        "settings-save-close",
                        "Save All",
                        Intent::SaveAndClose,
                        true,
                        false,
                    ),
                ]
            }
            ConnectionConfirmation::Reload => {
                footer = footer.child(div().id("settings-reload-question").debug_selector(|| "settings-reload-question".into()).text_size(px(12.))
                    .child("Discard unsaved changes and reload? This drops edits on every connection tab."));
                vec![
                    (
                        "settings-keep-editing",
                        "Keep Editing",
                        Intent::KeepEditing,
                        false,
                        false,
                    ),
                    (
                        "settings-discard-reload",
                        "Discard and Reload",
                        Intent::DiscardAndReload,
                        false,
                        true,
                    ),
                ]
            }
            ConnectionConfirmation::None => {
                let mut buttons = Vec::new();
                if let Some(form) = &presentation.active {
                    buttons.push(if form.saved {
                        (
                            "settings-delete-connection",
                            "Delete Connection…",
                            Intent::RequestDelete,
                            false,
                            true,
                        )
                    } else {
                        (
                            "settings-discard-connection",
                            "Discard",
                            Intent::DiscardCurrent,
                            false,
                            false,
                        )
                    });
                }
                buttons.extend([
                    ("settings-cancel", "Cancel", Intent::Cancel, false, false),
                    ("settings-done", "Done", Intent::RequestClose, false, false),
                    ("settings-save", "Save All", Intent::SaveAll, true, false),
                ]);
                buttons
            }
        };
        if presentation.dirty {
            actions = actions.child(
                div()
                    .id("settings-unsaved")
                    .debug_selector(|| "settings-unsaved".into())
                    .text_size(px(10.5))
                    .text_color(rgb(p.accent))
                    .child("Unsaved changes"),
            );
        }
        actions = actions.child(div().flex_1());
        for (id, label, intent, primary, danger) in buttons {
            let selector = id.to_owned();
            actions = actions.child(
                self.button(id, label, intent, primary, danger, cx)
                    .debug_selector(move || selector.clone()),
            );
        }
        footer = footer.child(actions);
        div()
            .id("connection-settings-panel")
            .debug_selector(|| "connection-settings-panel".into())
            .track_focus(&self.focus)
            .tab_group()
            .tab_stop(false)
            .w_full()
            .h_full()
            .rounded(px(14.))
            .border_1()
            .border_color(p.hairline())
            .bg(rgb(p.surface))
            .overflow_hidden()
            .text_color(rgb(p.ink))
            .flex()
            .flex_col()
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .capture_key_down(cx.listener(|view, event, window, cx| {
                if view.key(event, window, cx) {
                    cx.stop_propagation();
                }
            }))
            .child(
                div()
                    .flex_shrink_0()
                    .px(px(24.))
                    .py(px(18.))
                    .border_b_1()
                    .border_color(p.hairline())
                    .flex()
                    .flex_col()
                    .gap(px(10.))
                    .child(
                        div()
                            .text_size(px(19.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("Settings"),
                    )
                    .child(
                        div()
                            .text_size(px(12.))
                            .text_color(rgb(p.secondary))
                            .child(format!(
                                "Connections · {} saved",
                                presentation.tabs.iter().filter(|tab| tab.saved).count()
                            )),
                    )
                    .child(tab_bar),
            )
            .child(body)
            .child(footer)
    }
}

#[cfg(test)]
#[path = "connection_settings_view_tests.rs"]
mod tests;
