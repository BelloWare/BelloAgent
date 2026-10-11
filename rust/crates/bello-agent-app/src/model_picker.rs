//! The composer's per-chat model and reasoning-effort choices, after Swift
//! ModelSwitchControls.swift (`ModelSwitchPills`), CatalogModelPickerView.swift
//! and ModelCatalog.swift (`setModel`, `setThinkingLevel`, `refreshModels`).
//!
//! A choice is saved for the chat and remembered for the next new chat on its
//! connection; it is sent with the chat's next submissions and never rewrites
//! the saved connection. Listing reads only the chat's own saved connection
//! (its catalog source and, for a same-origin catalog, its key) off the UI
//! thread, and never sends a turn.
use crate::AgentView;
use bello_agent_core::{
    model_catalog::{CancellationToken, CatalogError, ModelDescriptor, SharedCatalog},
    model_choice::{ModelChoice, ModelChoiceStore, ThinkingLevel, offered_levels},
    project_authority::connections::LoadedConnections,
};
use bello_workbench_ui::{EditorEvent, EditorView};
use gpui::{AppContext, Context, Entity, Focusable, KeyDownEvent, Subscription, Window};
use std::{
    collections::BTreeMap,
    path::Path,
    sync::Arc,
    time::{Duration, Instant, SystemTime},
};

/// Swift `ModelCatalog.catalogTTL` and `failureRetry`.
const CATALOG_TTL: Duration = Duration::from_secs(300);
const FAILURE_RETRY: Duration = Duration::from_secs(30);
/// The catalog of a chat on the CLI-configured legacy route: the bundled list.
const LEGACY_SOURCE: &str = "";

/// Swift `ModelCatalogRefreshFailure`: fixed words, since vault failures can
/// carry private detail.
pub(crate) const REFRESH_CONFIGURATION: &str =
    "Couldn't reload the saved connection. Open Settings, reload the vault, then try again.";
pub(crate) const REFRESH_MISSING: &str =
    "This chat's connection is no longer saved. Open Settings to restore the connection.";
pub(crate) const REFRESH_UNSUPPORTED: &str =
    "This connection is for Messages history only. Choose a Responses connection in Settings.";

/// One catalog source as the chat's pickers see it (Swift `ModelCatalog.Entry`).
#[derive(Default)]
pub(crate) struct ChatCatalog {
    pub models: Vec<ModelDescriptor>,
    pub loading: bool,
    pub error: Option<String>,
    pub fetched: Option<(Instant, SystemTime)>,
    /// Whether a custom catalog URL replaces the bundled list.
    pub configured: bool,
    /// The source connection's name and its host and path, never its query.
    pub source_name: String,
    pub source_label: String,
    /// The saved connections' revision and the source this list was read
    /// from: either changing makes the list stale.
    revision: Option<i64>,
    identity: Option<String>,
    generation: uuid::Uuid,
    cancel: Option<CancellationToken>,
}
impl ChatCatalog {
    fn fresh(&self, now: Instant, revision: Option<i64>) -> bool {
        (revision.is_none() || revision == self.revision)
            && self.fetched.is_some_and(|(at, _)| {
                now.saturating_duration_since(at)
                    < if self.error.is_some() {
                        FAILURE_RETRY
                    } else {
                        CATALOG_TTL
                    }
            })
    }
    pub(crate) fn descriptor(&self, model: &str) -> Option<&ModelDescriptor> {
        self.models.iter().find(|row| row.id == model)
    }
    /// Swift `Entry.offered(current:)`: catalog order without deprecated
    /// models, unless one is the current choice.
    pub(crate) fn offered(&self, current: Option<&str>) -> Vec<&ModelDescriptor> {
        self.models
            .iter()
            .filter(|row| !row.deprecated || Some(row.id.as_str()) == current)
            .collect()
    }
}
impl Drop for ChatCatalog {
    fn drop(&mut self) {
        if let Some(cancel) = self.cancel.take() {
            cancel.cancel();
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PickerKind {
    Model,
    Effort,
}

/// The open list under a pill. It belongs to one chat; another chat closes it.
pub(crate) struct OpenPicker {
    pub kind: PickerKind,
    pub chat: String,
    pub token: uuid::Uuid,
    pub search: Option<Entity<EditorView>>,
    pub alias: Option<Entity<EditorView>>,
    pub entering_alias: bool,
    /// The effort list's keyboard row.
    pub highlighted: usize,
    /// Swift `ModelCatalogRefreshState`: Refresh's own error, including the
    /// vault reload before the fetch.
    pub refresh_error: Option<String>,
    pub refreshing: bool,
    _events: Vec<Subscription>,
}

/// Everything the pills show for the selected chat (Swift `ModelSwitchPills.Reading`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PillReading {
    pub model: String,
    pub model_active: bool,
    pub model_help: String,
    pub effort: String,
    pub effort_active: bool,
    pub effort_name: &'static str,
    pub loading: bool,
    pub disabled: bool,
}

pub(crate) struct ModelPickers {
    pub(crate) choices: Arc<ModelChoiceStore>,
    /// New chats' remembered choices until their first send saves them.
    adopted: BTreeMap<String, ModelChoice>,
    pub(crate) catalogs: BTreeMap<String, ChatCatalog>,
    pub(crate) open: Option<OpenPicker>,
    /// Where the pill was pressed: the list opens above it.
    pub(crate) anchor: gpui::Point<gpui::Pixels>,
    /// The saved connections the last listing read (Refresh rereads them).
    loaded: Option<LoadedConnections>,
}
impl ModelPickers {
    pub(crate) fn open(directory: &Path) -> Self {
        Self {
            choices: Arc::new(ModelChoiceStore::open(directory.join("chat-models.json"))),
            adopted: BTreeMap::new(),
            catalogs: BTreeMap::new(),
            open: None,
            anchor: gpui::Point::default(),
            loaded: None,
        }
    }
    /// A new chat starts from its connection's last deliberate choice
    /// (Swift `ChatModelDefaults` in `newChat`). Nothing is written yet.
    pub(crate) fn adopt(&mut self, record: &bello_agent_core::workspace::ChatRecord) {
        if self.choices.has_chat(&record.id) {
            return;
        }
        let choice = self
            .choices
            .adopt_defaults(&record.id, record.connection_id.as_deref());
        if choice != ModelChoice::default() {
            self.adopted.insert(record.id.clone(), choice);
        }
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub(crate) fn adopted_for_test(&mut self, chat: &str, choice: ModelChoice) {
        self.adopted.insert(chat.to_owned(), choice);
    }
    pub(crate) fn choice(&self, chat: &str) -> ModelChoice {
        if self.choices.has_chat(chat) {
            self.choices.chat(chat)
        } else {
            self.adopted.get(chat).cloned().unwrap_or_default()
        }
    }
    /// The choice a chat's first send carries is kept with the chat from then
    /// on, without changing the connection's next-chat default.
    /// A failed save keeps the choice in memory, so the pills and later
    /// sends still use it, and says why.
    pub(crate) fn settle_adopted(&mut self, chat: &str) -> Option<String> {
        let choice = self.adopted.get(chat)?.clone();
        if !self.choices.has_chat(chat)
            && let Err(error) = self.choices.save(chat, None, choice)
        {
            return Some(format!("The model choice could not be saved. {error}"));
        }
        self.adopted.remove(chat);
        None
    }
}

/// "Included with Bello Agent", or the catalog URL's host, port and path.
/// Query values are never shown: catalog URLs may contain access tokens.
pub(crate) fn source_label(url: Option<&str>) -> String {
    let Some(url) = url else {
        return "Included with Bello Agent".into();
    };
    match url::Url::parse(url.trim()) {
        Ok(parsed) if parsed.host_str().is_some() => format!(
            "{}{}{}",
            parsed.host_str().unwrap_or_default(),
            parsed.port().map(|p| format!(":{p}")).unwrap_or_default(),
            parsed.path()
        ),
        _ => "Saved connection source".into(),
    }
}
/// Swift `ModelSwitchPills.menuTitle`.
pub(crate) fn menu_title(item: &ModelDescriptor) -> String {
    let mut parts = vec![item.display_name().to_owned()];
    if item.display_name() != item.id {
        parts.push(item.id.clone());
    }
    if let Some(context) = context_label(item) {
        parts.push(context);
    }
    if item.deprecated {
        parts.push("deprecated".into());
    }
    parts.join(" · ")
}
/// Swift `ModelDescriptor.contextLabel`: "400K ctx", "1M ctx", "1.5M ctx".
pub(crate) fn context_label(item: &ModelDescriptor) -> Option<String> {
    let window = item.context_window?;
    Some(if window >= 1_000_000 {
        format!("{:.1}M ctx", f64::from(window) / 1_000_000.).replace(".0M", "M")
    } else if window >= 1_000 {
        format!("{}K ctx", window / 1000)
    } else {
        format!("{window} ctx")
    })
}
/// Swift `outputLimitLabel`: "up to 8,192 output".
pub(crate) fn output_limit_label(item: &ModelDescriptor) -> Option<String> {
    let limit = item.max_output_tokens?.to_string();
    let mut grouped = String::new();
    for (index, digit) in limit.chars().enumerate() {
        if index > 0 && (limit.len() - index).is_multiple_of(3) {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    Some(format!("up to {grouped} output"))
}
/// Swift `filtered(_:query:)`: id, name or description, ignoring case.
pub(crate) fn filtered<'a>(
    models: Vec<&'a ModelDescriptor>,
    query: &str,
) -> Vec<&'a ModelDescriptor> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return models;
    }
    models
        .into_iter()
        .filter(|row| {
            row.id.to_lowercase().contains(&query)
                || row.name.to_lowercase().contains(&query)
                || row.description.to_lowercase().contains(&query)
        })
        .collect()
}
/// "Updated 3:04:05 PM", in local time (Swift `time: .standard`).
pub(crate) fn clock_time(at: SystemTime) -> String {
    let seconds = at
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs() as libc::time_t)
        .unwrap_or_default();
    // SAFETY: localtime_r writes only into the zeroed tm owned here.
    let (hour, minute, second) = unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&seconds, &mut tm).is_null() {
            return String::new();
        }
        (tm.tm_hour, tm.tm_min, tm.tm_sec)
    };
    let twelve = if hour % 12 == 0 { 12 } else { hour % 12 };
    format!(
        "{twelve}:{minute:02}:{second:02}\u{202f}{}",
        if hour < 12 { "AM" } else { "PM" }
    )
}

struct Prepared {
    configured: bool,
    identity: String,
    source_name: String,
    label: String,
    request: bello_agent_core::model_catalog::CatalogRequest,
}

enum Listed {
    Unprepared(&'static str),
    Done {
        loaded: Box<LoadedConnections>,
        revision: i64,
        identity: String,
        configured: bool,
        source_name: String,
        source_label: String,
        retained: Option<Vec<ModelDescriptor>>,
        result: Result<Vec<ModelDescriptor>, CatalogError>,
    },
}

impl AgentView {
    /// The key of the chat's catalog: its saved connection, or the legacy route.
    pub(crate) fn chat_catalog_key(&self) -> String {
        self.record
            .connection_id
            .clone()
            .unwrap_or_else(|| LEGACY_SOURCE.into())
    }
    pub(crate) fn chat_model_choice(&self) -> ModelChoice {
        self.model_pickers.choice(&self.record.id)
    }
    pub(crate) fn chat_catalog(&self) -> Option<&ChatCatalog> {
        self.model_pickers.catalogs.get(&self.chat_catalog_key())
    }
    pub(crate) fn chat_descriptor(&self, model: &str) -> Option<&ModelDescriptor> {
        self.chat_catalog()?.descriptor(model)
    }
    /// Swift `ModelSwitchPills.reading`.
    pub(crate) fn model_pill_reading(&self) -> PillReading {
        let choice = self.chat_model_choice();
        let profile = self.controller.profile();
        let level = ThinkingLevel::of(&choice);
        let model = choice
            .model
            .clone()
            .or_else(|| profile.as_ref().map(|p| p.model_id.clone()))
            .unwrap_or_else(|| "Model".into());
        let default = profile
            .as_ref()
            .map(|p| p.model_id.clone())
            .unwrap_or_default();
        let model_help = choice.model.as_ref().map_or_else(
            || "Model from the profile.".to_owned(),
            |chosen| format!("Model override for this chat: {chosen}. Profile default: {default}."),
        ) + " Your choice is remembered for new chats using this connection.";
        PillReading {
            model,
            model_active: choice.model.is_some(),
            model_help,
            effort: level.pill_label(),
            effort_active: level != ThinkingLevel::ProfileDefault,
            effort_name: level.label(),
            loading: self.chat_catalog().is_some_and(|c| c.loading),
            disabled: self.loading || self.shutting_down || profile.is_none(),
        }
    }
    /// Efforts the effective model offers (Swift `offeredLevels`).
    pub(crate) fn offered_effort_levels(&self) -> Vec<ThinkingLevel> {
        let Some(profile) = self.controller.profile() else {
            return ThinkingLevel::ALL.to_vec();
        };
        let choice = self.chat_model_choice();
        let model = choice.model.unwrap_or_else(|| profile.model_id.clone());
        offered_levels(&profile, self.chat_descriptor(&model))
    }
    /// The effort list's note (Swift `effortContents`).
    pub(crate) fn effort_note(&self) -> Option<&'static str> {
        let levels = self.offered_effort_levels();
        let level = ThinkingLevel::of(&self.chat_model_choice());
        if !levels.contains(&level) {
            Some("Current effort is unavailable for this model. Choose another level.")
        } else if levels.len() < ThinkingLevel::ALL.len() {
            Some("Levels from the model catalog")
        } else {
            None
        }
    }

    pub(crate) fn toggle_model_picker(
        &mut self,
        kind: PickerKind,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(open) = &self.model_pickers.open {
            let same = open.kind == kind && open.chat == self.record.id;
            self.close_model_picker(window, cx);
            if same {
                return;
            }
        }
        if self.model_pill_reading().disabled || self.model_picker_suppressed(cx) {
            return;
        }
        let palette = self.palette;
        let mut events = Vec::new();
        let (search, alias) = if kind == PickerKind::Model {
            let search = cx.new(|cx| {
                let mut view = EditorView::new(String::new(), window, cx);
                let mut style = Self::composer_style(palette);
                style.font_size = 13.;
                style.line_height = 18.;
                style.padding_x = 6.;
                style.padding_y = 4.;
                view.set_appearance(style, cx);
                view
            });
            let alias = cx.new(|cx| {
                let mut view = EditorView::new(String::new(), window, cx);
                let mut style = Self::composer_style(palette);
                style.font_size = 12.;
                style.line_height = 17.;
                style.padding_x = 6.;
                style.padding_y = 4.;
                view.set_appearance(style, cx);
                view
            });
            for editor in [&search, &alias] {
                events.push(cx.subscribe(editor, |_, _, event, cx| {
                    if matches!(event, EditorEvent::Changed) {
                        cx.notify();
                    }
                }));
            }
            search.read(cx).focus(window);
            (Some(search), Some(alias))
        } else {
            (None, None)
        };
        let level = ThinkingLevel::of(&self.chat_model_choice());
        let highlighted = self
            .offered_effort_levels()
            .iter()
            .position(|l| *l == level)
            .unwrap_or(0);
        self.model_pickers.open = Some(OpenPicker {
            kind,
            chat: self.record.id.clone(),
            token: uuid::Uuid::new_v4(),
            search,
            alias,
            entering_alias: false,
            highlighted,
            refresh_error: None,
            refreshing: false,
            _events: events,
        });
        // Opening checks the source's freshness, by pointer or keyboard alike.
        self.load_chat_catalog(false, cx);
        cx.notify();
    }
    /// Another window-wide surface owns the keyboard and the pointer; an
    /// open list gives way to it.
    pub(crate) fn model_picker_suppressed(&self, cx: &gpui::App) -> bool {
        self.shutting_down
            || self.close_dialog
            || self.connections.open
            || self.connections.picker
            || self.mcp.open
            || self.topic_panel.is_some()
            || self.skill_picker.is_some()
            || self.conversation_content.is_some()
            || self.projects.view.read(cx).is_open()
            || self.quick_open.read(cx).is_open()
    }
    pub(crate) fn close_model_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.model_pickers.open.take().is_some() {
            self.focus_visible_composer(window, cx);
            cx.notify();
        }
    }
    /// The open picker, if it is still this chat's.
    pub(crate) fn open_model_picker(&self, token: uuid::Uuid) -> Option<&OpenPicker> {
        self.model_pickers
            .open
            .as_ref()
            .filter(|open| open.token == token && open.chat == self.record.id)
    }

    /// Lists the chat's catalog when it is not fresh, or always for Refresh,
    /// which first reloads the saved connections (Swift `refreshModels`).
    pub(crate) fn load_chat_catalog(&mut self, force: bool, cx: &mut Context<Self>) {
        if self.shutting_down || self.controller.profile().is_none() {
            return;
        }
        let key = self.chat_catalog_key();
        let token = self.model_pickers.open.as_ref().map(|open| open.token);
        if key == LEGACY_SOURCE {
            let catalog = self.model_pickers.catalogs.entry(key).or_default();
            if catalog.fetched.is_none() || force {
                let (models, error) = match bello_agent_core::model_catalog::bundled() {
                    Ok(models) => (models, None),
                    Err(error) => (catalog.models.clone(), Some(error.to_string())),
                };
                catalog.models = models;
                catalog.error = error;
                catalog.fetched = Some((Instant::now(), SystemTime::now()));
                catalog.source_label = source_label(None);
                catalog.source_name = "Command-line connection".into();
            }
            cx.notify();
            return;
        }
        let revision = self.connections.saved_revision().max(
            self.model_pickers
                .loaded
                .as_ref()
                .map(LoadedConnections::revision),
        );
        let catalog = self.model_pickers.catalogs.entry(key.clone()).or_default();
        if catalog.loading || (!force && catalog.fresh(Instant::now(), revision)) {
            return;
        }
        let cancel = CancellationToken::new();
        catalog.cancel = Some(cancel.clone());
        catalog.loading = true;
        catalog.generation = uuid::Uuid::new_v4();
        let generation = catalog.generation;
        if let Some(open) = self.model_pickers.open.as_mut().filter(|_| force) {
            open.refreshing = true;
            open.refresh_error = None;
        }
        let authority = self.connections.authority().clone();
        // The newest saved connections this window has read: Settings', or
        // the ones an earlier Refresh read. Refresh always reads them again.
        let loaded = (!force)
            .then(|| {
                [
                    self.connections.loaded(),
                    self.model_pickers.loaded.as_ref(),
                ]
                .into_iter()
                .flatten()
                .max_by_key(|loaded| loaded.revision())
                .cloned()
            })
            .flatten();
        let id = key.clone();
        let task = cx.background_executor().spawn(async move {
            let prepare = |loaded: &LoadedConnections| -> Result<Prepared, &'static str> {
                let saved = loaded
                    .profiles()
                    .iter()
                    .find(|p| p.profile.id == id)
                    .ok_or(REFRESH_MISSING)?;
                if saved.profile.api != "openai-responses" {
                    return Err(REFRESH_UNSUPPORTED);
                }
                let source = loaded.catalog_source(&id).map_err(|_| REFRESH_MISSING)?;
                let request = LoadedConnections::edit(loaded, &id)
                    .and_then(|draft| authority.prepare_catalog(loaded, &draft))
                    .map_err(|_| REFRESH_CONFIGURATION)?;
                Ok(Prepared {
                    configured: source.catalog_url.is_some(),
                    identity: format!(
                        "{}\n{}",
                        source.profile.id,
                        source.catalog_url.as_ref().map_or("", |url| url.as_str())
                    ),
                    source_name: source.name.clone(),
                    label: source_label(source.catalog_url.as_ref().map(|url| url.as_str())),
                    request,
                })
            };
            let reload = || {
                authority
                    .load_connections()
                    .map_err(|_| REFRESH_CONFIGURATION)
            };
            // A retained snapshot the vault has moved past is read again once.
            let attempt = match loaded {
                Some(loaded) => match prepare(&loaded) {
                    Ok(prepared) => Ok((loaded, prepared)),
                    Err(_) => reload().and_then(|loaded| prepare(&loaded).map(|p| (loaded, p))),
                },
                None => reload().and_then(|loaded| prepare(&loaded).map(|p| (loaded, p))),
            };
            let (loaded, prepared) = match attempt {
                Ok(found) => found,
                Err(message) => return Listed::Unprepared(message),
            };
            let Prepared {
                configured,
                identity,
                source_name,
                label,
                request,
            } = prepared;
            let revision = loaded.revision();
            let (retained, result) = match (force, request.shared()) {
                (false, Some(SharedCatalog::Fresh(models))) => (None, Ok(models)),
                (false, Some(SharedCatalog::Failed { models, error })) => {
                    (Some(models), Err(error))
                }
                (false, None) => (None, request.joining().load(cancel).await),
                (true, _) => (None, request.load(cancel).await),
            };
            Listed::Done {
                loaded: Box::new(loaded),
                revision,
                identity,
                configured,
                source_name,
                source_label: label,
                retained,
                result,
            }
        });
        cx.spawn(async move |view, cx| {
            let listed = task.await;
            let _ = view.update(cx, |view, cx| {
                view.finish_chat_catalog(&key, generation, token, force, listed, cx)
            });
        })
        .detach();
        cx.notify();
    }
    fn finish_chat_catalog(
        &mut self,
        key: &str,
        generation: uuid::Uuid,
        token: Option<uuid::Uuid>,
        force: bool,
        listed: Listed,
        cx: &mut Context<Self>,
    ) {
        let Some(catalog) = self.model_pickers.catalogs.get_mut(key) else {
            return;
        };
        if catalog.generation != generation || !catalog.loading {
            return;
        }
        catalog.loading = false;
        catalog.cancel = None;
        let mut refresh_error = None;
        match listed {
            Listed::Unprepared(message) => {
                refresh_error = Some(message.to_owned());
                if !force {
                    catalog.error = Some(message.to_owned());
                    catalog.fetched = Some((Instant::now(), SystemTime::now()));
                }
            }
            Listed::Done {
                loaded,
                revision,
                identity,
                configured,
                source_name,
                source_label,
                retained,
                result,
            } => {
                if self
                    .model_pickers
                    .loaded
                    .as_ref()
                    .is_none_or(|known| known.revision() <= revision)
                {
                    self.model_pickers.loaded = Some(*loaded);
                }
                // Another source's list is never shown for this one.
                if catalog
                    .identity
                    .as_ref()
                    .is_some_and(|known| *known != identity)
                {
                    catalog.models.clear();
                }
                catalog.identity = Some(identity);
                catalog.revision = Some(revision);
                catalog.configured = configured;
                catalog.source_name = source_name;
                catalog.source_label = source_label;
                if catalog.models.is_empty()
                    && let Some(models) = retained
                {
                    catalog.models = models;
                }
                match result {
                    Ok(models) => {
                        catalog.models = models;
                        catalog.error = None;
                    }
                    Err(CatalogError::Cancelled) => {}
                    Err(error) => catalog.error = Some(error.to_string()),
                }
                catalog.fetched = Some((Instant::now(), SystemTime::now()));
            }
        }
        if let Some(open) = self
            .model_pickers
            .open
            .as_mut()
            .filter(|open| Some(open.token) == token)
            && force
        {
            open.refreshing = false;
            open.refresh_error = refresh_error;
        }
        cx.notify();
    }

    /// Swift `setModel`: None restores the connection's model. A chosen model
    /// keeps only an effort its catalog offers.
    pub(crate) fn choose_chat_model(
        &mut self,
        token: uuid::Uuid,
        model: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.open_model_picker(token).is_none() {
            return;
        }
        let normalized = bello_agent_core::model_choice::normalized_model(model.as_deref());
        if model.is_some() && normalized.is_none() {
            self.error = Some("Enter a model alias of 1 to 200 printable characters.".into());
            cx.notify();
            return;
        }
        let Some(profile) = self.controller.profile() else {
            return;
        };
        let descriptor = self
            .chat_descriptor(normalized.as_deref().unwrap_or(&profile.model_id))
            .cloned();
        let next = self.chat_model_choice().choosing_model(
            normalized.as_deref(),
            &profile,
            descriptor.as_ref(),
        );
        self.close_model_picker(window, cx);
        self.save_chat_model_choice(next, cx);
    }
    /// Swift `setThinkingLevel`: Profile default restores the connection's.
    pub(crate) fn choose_chat_effort(
        &mut self,
        token: uuid::Uuid,
        level: ThinkingLevel,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.open_model_picker(token).is_none() {
            return;
        }
        let next = self.chat_model_choice().choosing_level(level);
        self.close_model_picker(window, cx);
        self.save_chat_model_choice(next, cx);
    }
    fn save_chat_model_choice(&mut self, choice: ModelChoice, cx: &mut Context<Self>) {
        let chat = self.record.id.clone();
        let connection = self.record.connection_id.clone();
        match self
            .model_pickers
            .choices
            .save(&chat, connection.as_deref(), choice)
        {
            Ok(()) => {
                self.model_pickers.adopted.remove(&chat);
            }
            Err(error) => {
                self.error = Some(format!("The model choice could not be saved. {error}"));
            }
        }
        cx.notify();
    }
    /// Swift `setConnection`: after a chat moves to another connection, its
    /// model choice survives only when that connection's catalog lists it,
    /// or the list is not known; the effort is checked against the model in
    /// force. Not remembered for new chats. True when the model was dropped.
    pub(crate) fn reconcile_model_choice_after_switch(
        &mut self,
        chat: &str,
        connection: Option<&str>,
        profile: Option<bello_agent_core::Profile>,
    ) -> Result<bool, String> {
        let choice = self.model_pickers.choice(chat);
        let Some(profile) = profile else {
            return Ok(false);
        };
        let catalog = self
            .model_pickers
            .catalogs
            .get(connection.unwrap_or(LEGACY_SOURCE));
        let known = catalog.is_some_and(|c| c.error.is_none() && !c.models.is_empty());
        let listed = choice
            .model
            .clone()
            .filter(|alias| !known || catalog.is_some_and(|c| c.descriptor(alias).is_some()));
        let descriptor = catalog
            .and_then(|c| c.descriptor(listed.as_deref().unwrap_or(&profile.model_id)))
            .cloned();
        let next = choice.choosing_model(listed.as_deref(), &profile, descriptor.as_ref());
        if next != choice {
            if self.model_pickers.choices.has_chat(chat) {
                // The saved choice stays in force; say so rather than
                // announce a model the next turn would not use.
                self.model_pickers
                    .choices
                    .save(chat, None, next.clone())
                    .map_err(|error| {
                        format!(
                            "The model choice could not be updated for this connection; the next turn still asks for {}. {error}",
                            choice.model.as_deref().unwrap_or("the connection's model")
                        )
                    })?;
            } else {
                self.model_pickers
                    .adopted
                    .insert(chat.to_owned(), next.clone());
            }
        }
        Ok(choice.model.is_some() && next.model.is_none())
    }
    pub(crate) fn submit_model_alias(
        &mut self,
        token: uuid::Uuid,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(alias) = self
            .open_model_picker(token)
            .and_then(|open| open.alias.as_ref())
            .map(|alias| alias.read(cx).text().trim().to_owned())
        else {
            return;
        };
        // Empty means the connection default.
        self.choose_chat_model(token, (!alias.is_empty()).then_some(alias), window, cx);
    }
    pub(crate) fn toggle_alias_entry(
        &mut self,
        token: uuid::Uuid,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(open) = self
            .model_pickers
            .open
            .as_mut()
            .filter(|open| open.token == token)
        {
            open.entering_alias = !open.entering_alias;
            if open.entering_alias
                && let Some(alias) = &open.alias
            {
                alias.read(cx).focus(window);
            }
            cx.notify();
        }
    }
    pub(crate) fn refresh_chat_catalog(&mut self, token: uuid::Uuid, cx: &mut Context<Self>) {
        if self
            .open_model_picker(token)
            .is_some_and(|open| !open.refreshing)
            && !self.chat_catalog().is_some_and(|c| c.loading)
        {
            self.load_chat_catalog(true, cx);
        }
    }

    /// Keys while a list is open: Escape closes; the effort list moves and
    /// chooses with the arrows and Return; Return in the alias field uses it.
    pub(crate) fn model_picker_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(open) = self.model_pickers.open.as_ref() else {
            return false;
        };
        if open.chat != self.record.id || self.model_picker_suppressed(cx) {
            self.model_pickers.open = None;
            cx.notify();
            return false;
        }
        let token = open.token;
        let key = event.keystroke.key.as_str();
        let composing = [&open.search, &open.alias]
            .into_iter()
            .flatten()
            .any(|editor| editor.read(cx).has_marked_text());
        if composing {
            return false;
        }
        match (open.kind, key) {
            (_, "escape") => {
                self.close_model_picker(window, cx);
                true
            }
            (PickerKind::Effort, "down" | "up") => {
                let count = self.offered_effort_levels().len().max(1);
                if let Some(open) = self.model_pickers.open.as_mut() {
                    open.highlighted = if key == "down" {
                        (open.highlighted + 1) % count
                    } else {
                        (open.highlighted + count - 1) % count
                    };
                }
                cx.notify();
                true
            }
            (PickerKind::Effort, "enter" | "space") => {
                if !event.is_held
                    && let Some(level) = self.offered_effort_levels().get(open.highlighted).copied()
                {
                    self.choose_chat_effort(token, level, window, cx);
                }
                true
            }
            // Return never types a line into the search or alias field; in
            // the alias field it uses the alias.
            (PickerKind::Model, "enter") => {
                let in_alias = open.entering_alias
                    && open
                        .alias
                        .as_ref()
                        .is_some_and(|alias| alias.read(cx).focus_handle(cx).is_focused(window));
                if in_alias && !event.is_held {
                    self.submit_model_alias(token, window, cx);
                }
                true
            }
            _ => false,
        }
    }
}

#[cfg(test)]
#[path = "model_picker_tests.rs"]
mod tests;
