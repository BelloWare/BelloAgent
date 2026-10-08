//! Connections Settings coordinator. Vault writes are distinct from runtime
//! publication; no save implicitly sends a provider request.
use crate::{AgentView, Palette, connection_settings_view::*};
#[path = "connection_model_catalog.rs"]
mod model_catalog;
#[cfg(feature = "synthetic-authority")]
use bello_agent_core::project_authority::synthetic::SyntheticAuthorityControl;
use bello_agent_core::{
    Controller, Profile,
    project_authority::{
        AuthorityError, ProjectAuthority,
        connections::{ConnectionDraft, LoadedConnections, SavedConnection},
    },
    workspace::ChatRecord,
};
use gpui::{AppContext, Context, Entity, Subscription, Window};
use model_catalog::CatalogState;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
};

pub(crate) struct LaunchLegacyConfiguration(
    pub Option<Arc<bello_agent_core::runtime::Configuration>>,
);
impl gpui::Global for LaunchLegacyConfiguration {}

#[cfg(feature = "synthetic-authority")]
pub(crate) struct LaunchConnectionAuthority(pub SyntheticAuthorityControl);
#[cfg(feature = "synthetic-authority")]
impl gpui::Global for LaunchConnectionAuthority {}

#[derive(Clone)]
struct RetainedForm {
    draft: ConnectionDraft,
    fields: ConnectionFields,
    baseline: ConnectionFields,
}
impl RetainedForm {
    fn new(draft: ConnectionDraft) -> Self {
        let fields = fields(&draft);
        Self {
            draft,
            baseline: fields.clone(),
            fields,
        }
    }
    fn dirty(&self) -> bool {
        let mut visible = self.fields.clone();
        visible
            .catalog_search
            .clone_from(&self.baseline.catalog_search);
        visible != self.baseline || self.draft.has_changes()
    }
    fn update_fields(&mut self, fields: ConnectionFields) {
        // Every manual alias edit invalidates earlier catalog selection metadata,
        // even when the user later types the old alias again before saving.
        if fields.model != self.fields.model {
            self.draft.profile.model_id = fields.model.clone();
            self.draft.profile.model_output_limit = None;
            self.draft.profile.input = vec!["text".into()];
        }
        self.fields = fields;
    }
    fn model_metadata(&self) -> String {
        let profile = &self.draft.profile;
        let ceiling = profile
            .model_output_limit
            .filter(|_| profile.model_id == self.fields.model);
        format!(
            "Model output ceiling: {} · Effort: {}. Budget stays separate; choosing a model never raises it.",
            ceiling.map_or_else(|| "unknown".into(), |n| n.to_string()),
            profile.thinking_level
        )
    }
    fn capture(&self) -> Result<ConnectionDraft, String> {
        let mut draft = self.draft.clone();
        draft.name = self.fields.name.clone();
        draft.profile.api = self.fields.api.clone();
        draft.profile.base_url = self.fields.base_url.clone();
        draft.catalog_url = self.fields.catalog_url.clone();
        if draft.profile.model_id != self.fields.model {
            draft.profile.model_output_limit = None;
            draft.profile.input = vec!["text".into()];
        }
        draft.profile.model_id = self.fields.model.clone();
        draft.profile.context_window = self
            .fields
            .context_window
            .parse()
            .map_err(|_| "Context capacity must be a positive whole number".to_owned())?;
        draft.profile.max_output_tokens = self
            .fields
            .output_budget
            .parse()
            .map_err(|_| "Output budget must be a positive whole number".to_owned())?;
        draft.key_input = self.fields.key.clone();
        draft.headers_input = self.fields.headers.clone();
        Ok(draft)
    }
}
fn fields(draft: &ConnectionDraft) -> ConnectionFields {
    ConnectionFields {
        name: draft.name.clone(),
        api: draft.profile.api.clone(),
        base_url: draft.profile.base_url.clone(),
        model: draft.profile.model_id.clone(),
        catalog_url: draft.catalog_url.clone(),
        catalog_search: String::new(),
        context_window: draft.profile.context_window.to_string(),
        output_budget: draft.profile.max_output_tokens.to_string(),
        key: draft.key_input.clone(),
        headers: draft.headers_input.clone(),
    }
}
fn new_form(mode: crate::launch_authority::AuthorityMode) -> RetainedForm {
    let mut profile: Profile = serde_json::from_value(serde_json::json!({"id":uuid::Uuid::new_v4().to_string(),"api":"openai-responses","providerId":"litellm","baseUrl":"http://127.0.0.1:47831","modelId":"local-test-fixture","contextWindow":32000,"maxOutputTokens":4096})).expect("fixture profile shape");
    if !mode.is_fixture() {
        profile.base_url.clear();
        profile.model_id.clear();
    }
    // Establish the actual blank Native baseline before metadata dirty tracking.
    RetainedForm::new(ConnectionDraft::new(profile, "New connection".into()))
}

pub(crate) struct ConnectionSettingsController {
    pub view: Entity<ConnectionSettingsView>,
    pub presentation: ConnectionSettingsPresentation,
    authority: Arc<ProjectAuthority>,
    loaded: Option<LoadedConnections>,
    forms: BTreeMap<String, RetainedForm>,
    catalogs: BTreeMap<String, CatalogState>,
    draft_notice_owner: Option<String>,
    active: Option<String>,
    pub choice: Option<String>,
    pub operation: Option<uuid::Uuid>,
    pub switches: BTreeMap<String, uuid::Uuid>,
    pub blocked: BTreeSet<String>,
    pub uncertain: bool,
    load: Option<uuid::Uuid>,
    events: Option<Subscription>,
    bound_window: Option<crate::workspace_lifetime::WindowBinding>,
    pub open: bool,
    pub picker: bool,
    pub picker_index: usize,
}
impl ConnectionSettingsController {
    pub fn new(palette: Palette, cx: &mut Context<AgentView>) -> Self {
        #[cfg(feature = "synthetic-authority")]
        let control = cx
            .try_global::<LaunchConnectionAuthority>()
            .map(|v| v.0.clone());
        #[cfg(feature = "synthetic-authority")]
        let authority = cx
            .try_global::<crate::project_manager_controller::LaunchProjectAuthority>()
            .map(|launch| launch.authority.clone())
            .unwrap_or_else(|| {
                Arc::new(control.as_ref().map(|c| c.authority()).unwrap_or_default())
            });
        #[cfg(not(feature = "synthetic-authority"))]
        let authority = cx
            .try_global::<crate::project_manager_controller::LaunchProjectAuthority>()
            .map(|launch| launch.authority.clone())
            .unwrap_or_else(|| Arc::new(ProjectAuthority::new()));
        let mode = cx
            .try_global::<crate::project_manager_controller::LaunchProjectAuthority>()
            .map(|launch| launch.mode)
            .unwrap_or_else(|| {
                #[cfg(feature = "synthetic-authority")]
                if control.is_some() {
                    return crate::launch_authority::AuthorityMode::Fixture;
                }
                crate::launch_authority::AuthorityMode::Unavailable
            });
        let presentation = ConnectionSettingsPresentation {
            revision: 1,
            mode,
            availability: ConnectionSettingsAvailability::Loading,
            saving: false,
            tabs: vec![],
            active: None,
            dirty: false,
            confirmation: ConnectionConfirmation::None,
            notice: None,
        };
        let view = cx.new(|cx| ConnectionSettingsView::new(presentation.clone(), palette, cx));
        Self {
            view,
            presentation,
            authority,
            loaded: None,
            forms: BTreeMap::new(),
            catalogs: BTreeMap::new(),
            draft_notice_owner: None,
            active: None,
            choice: None,
            operation: None,
            switches: BTreeMap::new(),
            blocked: BTreeSet::new(),
            uncertain: false,
            load: None,
            events: None,
            bound_window: None,
            open: false,
            picker: false,
            picker_index: 0,
        }
    }
    fn saved(&self, id: &str) -> bool {
        self.loaded
            .as_ref()
            .is_some_and(|l| l.profiles().iter().any(|p| p.profile.id == id))
    }
    fn publish(&mut self, cx: &mut Context<AgentView>) {
        self.sync_catalog_sources();
        self.presentation.revision = self
            .presentation
            .revision
            .checked_add(1)
            .expect("Settings revision exhausted");
        let mut ordered: Vec<_> = self
            .loaded
            .as_ref()
            .map(|l| l.profiles().iter().map(|p| p.profile.id.clone()).collect())
            .unwrap_or_default();
        ordered.extend(self.forms.keys().filter(|id| !self.saved(id)).cloned());
        self.presentation.tabs = ordered
            .into_iter()
            .filter_map(|id| {
                self.forms.get(&id).map(|form| ConnectionTab {
                    label: form.fields.name.clone(),
                    saved: self.saved(&id),
                    dirty: form.dirty(),
                    id,
                })
            })
            .collect();
        self.presentation.active = self.active.as_ref().and_then(|id| {
            self.forms.get(id).map(|form| ConnectionForm {
                id: id.clone(),
                saved: self.saved(id),
                fields: form.fields.clone(),
                catalog: self.catalog_presentation(id, form),
                model_metadata: form.model_metadata(),
                inherited_catalog_name: self
                    .loaded
                    .as_ref()
                    .and_then(|loaded| loaded.catalog_source(id).ok())
                    .filter(|source| {
                        source.profile.id != *id
                            && form.fields.catalog_url.trim() == form.baseline.catalog_url.trim()
                            && form.fields.api == form.baseline.api
                            && form.fields.base_url == form.baseline.base_url
                            && form.fields.key.is_empty()
                    })
                    .map(|source| source.name.clone()),
            })
        });
        self.presentation.dirty = self.forms.values().any(RetainedForm::dirty);
        let p = self.presentation.clone();
        self.view.update(cx, |v, cx| v.set_presentation(p, cx));
        cx.notify();
    }
    fn notice(&mut self, text: impl Into<String>, error: bool) {
        self.draft_notice_owner = None;
        self.presentation.notice = Some(ConnectionSettingsNotice {
            text: text.into(),
            is_error: error,
        });
    }
    fn discard_draft_notice(&mut self, discarded: Option<&str>) {
        // Save/runtime notices have no draft owner and must survive Cancel,
        // including non-error recovery warnings and unconfirmed CAS results.
        if self
            .draft_notice_owner
            .as_deref()
            .is_some_and(|owner| discarded.is_none_or(|discarded| discarded == owner))
        {
            self.presentation.notice = None;
            self.draft_notice_owner = None;
        }
    }
    fn install(&mut self, loaded: LoadedConnections, discard: bool) {
        if discard {
            self.catalogs.clear();
            self.forms.clear();
        }
        for p in loaded.profiles() {
            if (discard || self.forms.get(&p.profile.id).is_none_or(|f| !f.dirty()))
                && let Ok(draft) = loaded.edit(&p.profile.id)
            {
                self.forms
                    .insert(p.profile.id.clone(), RetainedForm::new(draft));
            }
        }
        self.forms.retain(|id, form| {
            form.dirty() || loaded.profiles().iter().any(|p| p.profile.id == *id)
        });
        if self.forms.is_empty() {
            let f = new_form(self.presentation.mode);
            self.forms.insert(f.draft.profile.id.clone(), f);
        }
        if self
            .active
            .as_ref()
            .is_none_or(|id| !self.forms.contains_key(id))
        {
            self.active = self.forms.keys().next().cloned();
        }
        if self.choice.as_ref().is_none_or(|id| {
            !loaded
                .profiles()
                .iter()
                .any(|p| p.available && p.profile.id == *id)
        }) {
            self.choice = loaded
                .profiles()
                .iter()
                .find(|p| p.available)
                .map(|p| p.profile.id.clone());
        }
        self.loaded = Some(loaded);
        self.presentation.availability = if self.uncertain {
            ConnectionSettingsAvailability::Unconfirmed("Reloaded for review. An earlier save remains unconfirmed; connection admission is still blocked.".into())
        } else {
            ConnectionSettingsAvailability::Ready
        };
    }
    pub fn choices(&self) -> Vec<SavedConnection> {
        self.loaded
            .as_ref()
            .map(|l| {
                l.profiles()
                    .iter()
                    .filter(|p| p.available)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default()
    }
    pub(crate) fn authority(&self) -> &Arc<ProjectAuthority> {
        &self.authority
    }
}

impl AgentView {
    pub(crate) fn bind_connections(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.connections.picker = false;
        let binding = self.window_binding;
        if self.connections.bound_window != binding {
            // Preserve even unacknowledged local edits before invalidating all
            // intentions captured by an older native window binding.
            if let Some(fields) = self.connections.view.read(cx).captured_fields(cx)
                && let Some(form) = self
                    .connections
                    .active
                    .as_ref()
                    .and_then(|id| self.connections.forms.get_mut(id))
            {
                form.update_fields(fields);
            }
            self.connections.cancel_catalog_loads();
            self.connections.bound_window = binding;
            self.connections.publish(cx);
        }
        self.connections.events = Some(cx.subscribe_in(
            &self.connections.view,
            window,
            move |view, _, event, window, cx| {
                if view.window_binding != binding {
                    return;
                }
                if let ConnectionSettingsEvent::Intent {
                    revision,
                    active_id,
                    fields,
                    intent,
                } = event
                {
                    view.connection_intent(
                        *revision,
                        active_id.clone(),
                        fields.as_deref().cloned(),
                        intent.clone(),
                        window,
                        cx,
                    );
                }
            },
        ));
    }
    pub(crate) fn open_connections(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.mcp.open
            || self.mcp.busy()
            || self.shutting_down
            || self.close_dialog
            || self.projects.view.read(cx).is_open()
            || !self.connections.switches.is_empty()
        {
            return;
        }
        self.connections.picker = false;
        self.connections.open = true;
        self.cancel_queue_drag(window, cx);
        self.close_queue_detail(true, window, cx);
        self.sidebar_menu = None;
        self.quick_open
            .update(cx, |v, cx| v.close(false, window, cx));
        self.connections.view.update(cx, |v, cx| v.show(window, cx));
        if self.connections.loaded.is_none() {
            self.reload_connections(true, cx);
        } else {
            self.connections.publish(cx);
        }
    }
    fn reload_connections(&mut self, discard: bool, cx: &mut Context<Self>) {
        if self.connections.operation.is_some() {
            return;
        }
        let token = uuid::Uuid::new_v4();
        self.connections.cancel_catalog_loads();
        self.connections.load = Some(token);
        self.connections.presentation.availability = ConnectionSettingsAvailability::Loading;
        self.connections.presentation.confirmation = ConnectionConfirmation::None;
        self.connections.publish(cx);
        let authority = self.connections.authority.clone();
        let task = cx
            .background_executor()
            .spawn(async move { authority.load_connections() });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                if view.connections.load != Some(token) {
                    return;
                }
                view.connections.load = None;
                match result {
                    Ok(loaded) => {
                        view.connections.install(loaded, discard);
                        view.connections
                            .notice(view.connections.presentation.mode.loaded_notice(), false);
                    }
                    Err(e) => {
                        view.connections.presentation.availability =
                            if e == AuthorityError::Unavailable {
                                ConnectionSettingsAvailability::Unavailable(e.to_string())
                            } else {
                                ConnectionSettingsAvailability::Failed(e.to_string())
                            };
                    }
                }
                view.connections.publish(cx);
            });
        })
        .detach();
    }
    fn close_connections(&mut self, discard: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.connections.operation.is_some() {
            return;
        }
        self.connections.load = None;
        self.connections.cancel_catalog_loads();
        self.connections.open = false;
        self.connections.presentation.confirmation = ConnectionConfirmation::None;
        if discard {
            if let Some(loaded) = self.connections.loaded.clone() {
                self.connections.install(loaded, true);
            } else {
                self.connections.forms.clear();
                self.connections.active = None;
            }
            self.connections.discard_draft_notice(None);
        }
        self.connections.publish(cx);
        self.connections
            .view
            .update(cx, |v, cx| v.close(true, window, cx));
    }
    fn connection_intent(
        &mut self,
        revision: u64,
        id: Option<String>,
        fields: Option<ConnectionFields>,
        intent: ConnectionSettingsIntent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if revision != self.connections.presentation.revision
            || id != self.connections.active
            || self.shutting_down
        {
            return;
        }
        if !self.connections.presentation.allows(&intent) {
            return;
        }
        if let (Some(id), Some(fields)) = (id, fields)
            && let Some(form) = self.connections.forms.get_mut(&id)
        {
            form.update_fields(fields);
        }
        self.connections.presentation.confirmation = ConnectionConfirmation::None;
        use ConnectionSettingsIntent::*;
        match intent {
            Edited => {}
            BrowseCatalog | RefreshCatalog => {
                self.load_connection_catalog(matches!(intent, RefreshCatalog), cx);
                return;
            }
            CloseCatalog => {
                if let Some(id) = &self.connections.active
                    && let Some(catalog) = self.connections.catalogs.get_mut(id)
                {
                    catalog.close();
                }
            }
            CatalogPage(page) => {
                if let Some(id) = &self.connections.active
                    && let Some(catalog) = self.connections.catalogs.get_mut(id)
                {
                    catalog.page = page;
                }
            }
            ChooseCatalog { id, generation } => self.choose_connection_model(&id, generation),
            Select(id) => {
                self.connections.cancel_catalog_loads();
                if self.connections.forms.contains_key(&id) {
                    self.connections.active = Some(id);
                }
            }
            New => {
                self.connections.cancel_catalog_loads();
                let pending = self
                    .connections
                    .forms
                    .keys()
                    .find(|id| !self.connections.saved(id))
                    .cloned();
                let id = if let Some(id) = pending {
                    id
                } else {
                    let form = new_form(self.connections.presentation.mode);
                    let id = form.draft.profile.id.clone();
                    self.connections.forms.insert(id.clone(), form);
                    id
                };
                self.connections.active = Some(id);
            }
            Cancel | DiscardAndClose => {
                self.close_connections(true, window, cx);
                return;
            }
            RequestClose => {
                if self.connections.forms.values().any(RetainedForm::dirty) {
                    self.connections.presentation.confirmation = ConnectionConfirmation::Close;
                } else {
                    self.close_connections(false, window, cx);
                    return;
                }
            }
            Keep | KeepEditing => {}
            Reload => {
                if self.connections.forms.values().any(RetainedForm::dirty) {
                    self.connections.presentation.confirmation = ConnectionConfirmation::Reload;
                } else {
                    self.reload_connections(true, cx);
                    return;
                }
            }
            DiscardAndReload => {
                self.reload_connections(true, cx);
                return;
            }
            DiscardCurrent => {
                if let Some(id) = self.connections.active.clone() {
                    self.connections.forms.remove(&id);
                    self.connections.discard_draft_notice(Some(&id));
                    if let Some(loaded) = self.connections.loaded.clone() {
                        self.connections.install(loaded, false);
                    }
                }
            }
            RequestDelete => {
                self.connections.presentation.confirmation=ConnectionConfirmation::Delete{summary:"Its saved key will be removed from this vault. Chats keep history and paused queued input; running work stops. Inspect/remove queued input before choosing another connection.".into()};
            }
            SaveAll | SaveAndClose => {
                self.save_connections(window, cx);
                return;
            }
            ConfirmDelete => {
                self.delete_connection(cx);
                return;
            }
        }
        self.connections.publish(cx);
    }
}

struct SavedTabs {
    loaded: LoadedConnections,
    saved: Vec<(String, String, String)>,
    failure: Option<String>,
    failure_id: Option<String>,
    uncertain: bool,
    runtime_notices: Vec<String>,
}
impl AgentView {
    fn connection_controllers(&self) -> Vec<(String, Arc<Controller>)> {
        std::iter::once(&self.chat)
            .chain(self.inactive.values())
            .filter_map(|c| {
                c.record
                    .connection_id
                    .as_ref()
                    .map(|id| (id.clone(), c.controller.clone()))
            })
            .collect()
    }
    fn save_connections(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        {
            if !self.connections.presentation.mode.editable() {
                return;
            }
            if self.connections.operation.is_some()
                || self.connections.uncertain
                || self.shutting_down
            {
                return;
            }
            let (Some(mut loaded), Some(current)) = (
                self.connections.loaded.clone(),
                self.connections.active.clone(),
            ) else {
                return;
            };
            let mut order: Vec<_> = self
                .connections
                .forms
                .iter()
                .filter(|(id, f)| **id != current && f.dirty())
                .map(|(id, _)| id.clone())
                .collect();
            order.push(current.clone());
            let dirty_ids: BTreeSet<_> = order
                .iter()
                .filter(|id| self.connections.forms[*id].dirty())
                .cloned()
                .collect();
            if let Some(reason) = self.connection_change_busy(&dirty_ids) {
                self.connections.notice(reason, true);
                self.connections.publish(cx);
                return;
            }
            let drafts: Vec<_> = order
                .into_iter()
                .filter_map(|id| {
                    let form = &self.connections.forms[&id];
                    form.dirty().then(|| (id, form.capture()))
                })
                .collect();
            if drafts.is_empty() {
                self.close_connections(false, window, cx);
                return;
            }
            let authority = self.connections.authority.clone();
            let controllers = self.connection_controllers();
            let token = uuid::Uuid::new_v4();
            self.connections.cancel_catalog_loads();
            self.connections.operation = Some(token);
            self.connections.presentation.saving = true;
            self.connections.presentation.availability =
                ConnectionSettingsAvailability::Busy("Saving captured connection tabs…".into());
            self.connections.publish(cx);
            let binding = self.window_binding;
            let handle = window
                .window_handle()
                .downcast::<AgentView>()
                .expect("workspace window");
            let task=cx.background_executor().spawn(async move{
                let mut result=SavedTabs{loaded:loaded.clone(),saved:vec![],failure:None,failure_id:None,uncertain:false,runtime_notices:vec![]};
                for(id,draft)in drafts {
                    let draft=match draft {Ok(draft)=>draft,Err(message)=>{result.failure_id=Some(id);result.failure=Some(message);break;}};
                    match authority.save_connection(&loaded,&draft){
                        Ok(saved)=>{
                            let new_id=saved.profile.profile.id.clone();
                            if !saved.forked {
                                match bello_agent_core::project_authority::connections::SavedConnectionRuntime::confirm(&authority,&saved.loaded,&new_id){
                                    Ok(runtime)=>{for(profile,controller)in &controllers{if profile==&new_id{match controller.configure(runtime.configuration()){Ok(true)=>{},Ok(false)=>result.runtime_notices.push("A running turn keeps its original settings; the next run uses the saved settings.".into()),Err(_)=>result.runtime_notices.push("Settings were saved, but a chat could not apply them. That chat remains unavailable until explicitly recovered.".into())}}}},
                                    Err(_)=>result.runtime_notices.push("Settings were saved, but current connection confirmation failed. No replacement request was started.".into()),
                                }
                            }
                            result.saved.push((id,new_id,draft.name));loaded=saved.loaded;result.loaded=loaded.clone();
                        },
                        Err(error)=>{result.uncertain=error==AuthorityError::Unconfirmed;result.failure_id=Some(id);result.failure=Some(format!("{}: {error}",draft.name));break;}
                    }
                }
                if result.uncertain {for(_,c)in controllers{let _=c.retire();}}
                result
            });
            cx.spawn(async move|owner,cx|{
                let result=task.await;
                let should_close=owner.update(cx,|view,cx|{
                    if view.connections.operation!=Some(token){return false;}
                    view.connections.operation=None;view.connections.presentation.saving=false;
                    let mut forked=false;let mut last=None;
                    for(old,new,_)in &result.saved{view.connections.forms.remove(old);forked|=old!=new;if old==&current{last=Some(new.clone());}}
                    view.connections.install(result.loaded,false);
                    if let Some(id)=last{view.connections.active=Some(id.clone());view.connections.choice=Some(id);}
                    if let Some(id)=result.failure_id {view.connections.active=Some(id);}
                    let names=result.saved.iter().map(|(_,_,n)|n.as_str()).collect::<Vec<_>>().join(", ");
                    if result.uncertain {view.connections.uncertain=true;view.connections.presentation.availability=ConnectionSettingsAvailability::Unconfirmed("A vault write may have committed. Drafts are retained; new connection actions remain blocked.".into());}
                    let success=result.failure.is_none();
                    let mut message=if let Some(error)=result.failure{if names.is_empty(){format!("Connection save did not complete: {error}")}else{format!("Saved {names}. The following save did not complete: {error}")}}else{view.connections.presentation.mode.saved_notice().into()};
                    if forked {message.push_str(" Route changes created new connections; earlier chats keep their original connections.");}
                    for note in result.runtime_notices {message.push(' ');message.push_str(&note);}
                    view.connections.notice(message,!success);view.connections.publish(cx);
                    success&&!forked&&view.window_binding==binding
                }).unwrap_or(false);
                if should_close {let _=handle.update(cx,|view,window,cx|view.close_connections(false,window,cx));}
            }).detach();
        }
    }
    fn connection_change_busy(&self, ids: &BTreeSet<String>) -> Option<String> {
        if !self.connections.switches.is_empty()
            || self.projects.operation.is_some()
            || !self.chat_mode_operations.is_empty()
        {
            return Some("Wait for the connection, project or chat-mode change to finish.".into());
        }
        if self
            .records
            .iter()
            .filter(|r| r.connection_id.as_ref().is_some_and(|id| ids.contains(id)))
            .any(|r| {
                self.organization_operations.contains_key(&r.id)
                    || self.recoveries.values().any(|i| i.chat_id == r.id)
                    || self.chat_ref(&r.id).is_some_and(|c| {
                        c.loading
                            || c.busy
                            || c.inflight_submission.is_some()
                            || c.queue_operation.is_some()
                            || c.begin_operation.is_some()
                            || c.cancel_operation.is_some()
                            || c.edit_recovery.blocked
                    })
            })
        {
            return Some("Wait for this connection's chats to finish opening or saving their current edits before changing it.".into());
        }
        None
    }
    fn delete_connection(&mut self, cx: &mut Context<Self>) {
        if self.connections.operation.is_some() || self.connections.uncertain || self.shutting_down
        {
            return;
        }
        let (Some(loaded), Some(id)) = (
            self.connections.loaded.clone(),
            self.connections.active.clone(),
        ) else {
            return;
        };
        if !self.connections.saved(&id) {
            self.connections.publish(cx);
            return;
        }
        if let Some(reason) = self.connection_change_busy(&BTreeSet::from([id.clone()])) {
            self.connections.notice(reason, true);
            self.connections.publish(cx);
            return;
        }
        let affected: Vec<_> = std::iter::once(&self.chat)
            .chain(self.inactive.values())
            .filter(|c| c.record.connection_id.as_deref() == Some(&id))
            .map(|c| {
                (
                    c.record.clone(),
                    c.controller.clone(),
                    c.controller.is_persistent(),
                )
            })
            .collect();
        let all_ids: Vec<_> = self
            .records
            .iter()
            .filter(|r| r.connection_id.as_deref() == Some(&id))
            .map(|r| r.id.clone())
            .collect();
        self.connections.blocked.extend(all_ids);
        for (_, controller, _) in &affected {
            let _ = controller.retire();
        }
        let token = uuid::Uuid::new_v4();
        self.connections.cancel_catalog_loads();
        self.connections.operation = Some(token);
        self.connections.presentation.saving = true;
        self.connections.presentation.availability = ConnectionSettingsAvailability::Busy(
            "Stopping this connection's chats before deleting…".into(),
        );
        self.connections.publish(cx);
        let authority = self.connections.authority.clone();
        let removed = id.clone();
        let runtime = self.runtime.clone();
        let task = cx.background_executor().spawn(async move {
            for (_, controller, _) in &affected {
                controller
                    .retire_and_wait()
                    .await
                    .map_err(|_| AuthorityError::Unconfirmed)?;
            }
            let deletion = authority
                .delete_connection(&loaded, &removed)
                .and_then(|saved| {
                    let readback = authority
                        .load_connections()
                        .map_err(|_| AuthorityError::Unconfirmed)?;
                    if readback.profiles().iter().any(|p| p.profile.id == removed) {
                        return Err(AuthorityError::Unconfirmed);
                    }
                    Ok(saved)
                });
            let (saved, error) = match deletion {
                Ok(saved) => (Some(saved), None),
                Err(AuthorityError::Unconfirmed) => return Err(AuthorityError::Unconfirmed),
                Err(error) => (None, Some(error.to_string())),
            };
            let mut replacements = Vec::new();
            let mut failed = Vec::new();
            for (record, previous, _) in affected {
                match runtime.disconnected(&record, Some(&previous)) {
                    Ok(controller) => replacements.push((record.id, previous, controller)),
                    Err(_) => failed.push(record.id),
                }
            }
            Ok::<_, AuthorityError>((saved, replacements, failed, error))
        });
        cx.spawn(async move|owner,cx| { let result=task.await; let _=owner.update(cx,|view,cx| {
            if view.connections.operation!=Some(token){return;}
            view.connections.operation=None;view.connections.presentation.saving=false;
            match result {
                Ok((loaded,replacements,failed,error))=>{
                    let deletion_failed=error.is_some();
                    for (chat_id,previous,controller) in replacements {
                        if let Some(chat)=view.chat_mut(&chat_id)
                            && Arc::ptr_eq(&chat.controller,&previous) {
                            chat.load_generation=chat.load_generation.saturating_add(1);
                            chat.loading=false;chat.load_failed=false;
                            chat.replace_controller(controller,cx);
                            chat.error=Some(if deletion_failed {
                                "Connection deletion did not complete. This chat is disconnected; queued input remains paused for inspection or removal before choosing a saved connection."
                            } else {
                                "Connection deleted. Queued input stays paused: inspect or remove it before selecting another connection."
                            }.into());
                            view.connections.blocked.remove(&chat_id);
                        }
                    }
                    // Unloaded chats reopen disconnected by their missing saved ID.
                    let live: BTreeSet<_>=std::iter::once(&view.chat).chain(view.inactive.values()).map(|c|c.record.id.clone()).collect();
                    view.connections.blocked.retain(|chat|live.contains(chat));
                    if let Some(loaded)=loaded {view.connections.forms.remove(&id);view.connections.active=None;view.connections.install(loaded,false);}
                    else {view.connections.presentation.availability=ConnectionSettingsAvailability::Ready;}
                    let suffix=if failed.is_empty(){""}else{" Some disconnected chats could not reopen and remain blocked; their drafts are retained."};
                    let message=if let Some(error)=error {format!("Connection was not deleted: {error}. Its chats are disconnected with history and paused queued input retained. Inspect/remove queued input, then explicitly choose a saved connection.{suffix}")}else{format!("Connection deleted. Chats retain history and paused queued input. Inspect/remove queued input before choosing another connection.{suffix}")};
                    view.connections.notice(message,deletion_failed||!failed.is_empty());
                },
                Err(error)=>{
                    view.connections.presentation.availability=if error==AuthorityError::Unconfirmed {view.connections.uncertain=true;ConnectionSettingsAvailability::Unconfirmed(error.to_string())}else{ConnectionSettingsAvailability::Ready};
                    view.connections.notice(format!("Deletion did not complete: {error}. Affected runtimes remain stopped; drafts and queued input are retained."),true);
                }
            }
            view.connections.publish(cx);
        }); }).detach();
    }
}

struct ConnectionSwitchResult {
    record: ChatRecord,
    controller: Arc<Controller>,
}
impl AgentView {
    pub(crate) fn connection_switch_blocker(&self) -> Option<String> {
        if self.shutting_down
            || self.connections.operation.is_some()
            || self.projects.operation.is_some()
        {
            return Some("Wait for configuration work to finish".into());
        }
        if self.connections.uncertain || self.known_catalog_uncertainty {
            return Some("An unconfirmed save keeps connection changes blocked".into());
        }
        if self.chat_is_archived(&self.record.id) {
            return Some("Restore this chat before changing its connection".into());
        }
        if self.connections.switches.contains_key(&self.record.id)
            || self.chat_mode_blocked.contains(&self.record.id)
            || self.organization_operations.contains_key(&self.record.id)
            || self.has_pending_archive(&self.record.id)
            || self
                .recoveries
                .values()
                .any(|intent| intent.chat_id == self.record.id)
            || self.edit_recovery.blocked
            || self.queue_operation.is_some()
            || self.loading
            || self.busy
            || self.inflight_submission.is_some()
        {
            return Some("Wait for this chat's operation to finish".into());
        }
        if self.session.state == bello_agent_core::RunState::Running
            || !self.session.pending.is_empty()
            || self.editing.is_some()
            || self.retained_edit.is_some()
            || self.session.edit.is_some()
            || self.begin_operation.is_some()
            || self.cancel_operation.is_some()
        {
            return Some(
                "Finish or remove pending work and held edits before changing this connection"
                    .into(),
            );
        }
        None
    }
    pub(crate) fn select_connection(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.connections.open {
            return;
        }
        if let Some(reason) = self.connection_switch_blocker() {
            self.error = Some(reason);
            cx.notify();
            return;
        }
        if self.connections.presentation.mode == crate::launch_authority::AuthorityMode::Native {
            // An explicit route selection supersedes an earlier background New
            // Chat request, even while its authority read is still pending.
            if !self.advance_navigation(cx) {
                return;
            }
            let runtime = self.runtime.clone();
            let selected = id.to_owned();
            let target = selected.clone();
            let old = self.record.clone();
            let chat_id = old.id.clone();
            let previous = Arc::downgrade(&self.controller);
            let project = self.project.clone();
            let generation = self.navigation_generation;
            let binding = self.window_binding;
            let token = uuid::Uuid::new_v4();
            self.connections.switches.insert(chat_id.clone(), token);
            self.connections.picker = false;
            cx.notify();
            let task = cx
                .background_executor()
                .spawn(async move { runtime.preflight(&target) });
            cx.spawn(async move |owner, cx| {
                let result = task.await;
                let _ = owner.update(cx, |view, cx| {
                    if view.connections.switches.get(&chat_id) != Some(&token) {
                        return;
                    }
                    view.connections.switches.remove(&chat_id);
                    if view.project != project
                        || view.record != old
                        || view.navigation_generation != generation
                        || view.window_binding != binding
                        || !previous.ptr_eq(&Arc::downgrade(&view.controller))
                    {
                        cx.notify();
                        return;
                    }
                    if let Err(error) = result {
                        view.error = Some(error.to_string());
                        cx.notify();
                        return;
                    }
                    // Admission is rechecked after async preflight. A failed or
                    // stale confirmation never retires the current actor.
                    view.select_connection_after_preflight(&selected, cx);
                });
            })
            .detach();
            return;
        }
        if let Err(error) = self.runtime.preflight(id) {
            self.error = Some(error.to_string());
            cx.notify();
            return;
        }
        self.select_connection_after_preflight(id, cx);
    }
    fn select_connection_after_preflight(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.connections.open {
            return;
        }
        if let Some(reason) = self.connection_switch_blocker() {
            self.error = Some(reason);
            cx.notify();
            return;
        }
        let mut target = self.record.clone();
        target.connection_id = Some(id.into());
        if self.pending && !self.controller.is_persistent() {
            // An unsent legacy anchor has no journal to move. Saved runtimes
            // mint only the workspace-derived path before first registration.
            match self
                .workspace
                .lock()
                .map_err(|_| "Workspace is unavailable".to_owned())
                .and_then(|store| store.chat_path(&target.id).map_err(|e| e.to_string()))
            {
                Ok(path) => target.snapshot = path,
                Err(error) => {
                    self.error = Some(error);
                    cx.notify();
                    return;
                }
            }
        }
        let controller = self.controller.clone();
        let guard = if controller.is_retired() {
            None
        } else {
            match controller.suspend_idle_admission() {
                Ok(g) => Some(g),
                Err(e) => {
                    self.error = Some(e.to_string());
                    cx.notify();
                    return;
                }
            }
        };
        if let Some(g) = guard {
            g.retain_fence();
        }
        if let Err(e) = controller.retire() {
            self.error = Some(e.to_string());
            self.connections.blocked.insert(self.record.id.clone());
            cx.notify();
            return;
        }
        let old = self.record.clone();
        let chat_id = old.id.clone();
        let pending = self.pending;
        let runtime = self.runtime.clone();
        let catalog = self.workspace.clone();
        let project = self.project.clone();
        let previous = Arc::downgrade(&controller);
        let operation = uuid::Uuid::new_v4();
        self.connections.switches.insert(chat_id.clone(), operation);
        self.connections.blocked.insert(chat_id.clone());
        self.connections.picker = false;
        cx.notify();
        let task = cx.background_executor().spawn(async move {
            controller
                .retire_and_wait()
                .await
                .map_err(|e| (e.to_string(), false, Some(old.clone())))?;
            let record = {
                let mut catalog = catalog
                    .lock()
                    .map_err(|_| ("Workspace is unavailable".into(), false, None))?;
                if catalog.is_uncertain() {
                    return Err(("Workspace save is unconfirmed".into(), true, None));
                }
                let state = catalog.snapshot();
                if state.project != project {
                    return Err(("Workspace identity changed".into(), false, None));
                }
                if let Some(latest) = state.chats.iter().find(|r| r.id == old.id) {
                    if latest.snapshot != old.snapshot || latest.connection_id != old.connection_id
                    {
                        return Err((
                            "The saved chat connection changed; review its current selection"
                                .into(),
                            false,
                            Some(latest.clone()),
                        ));
                    }
                    match catalog.set_connection_after_retirement(
                        &old.id,
                        old.connection_id.as_deref(),
                        target.connection_id.as_deref().expect("selected identity"),
                    ) {
                        Ok(record) => record,
                        Err(error) => {
                            return Err((
                                error.to_string(),
                                catalog.is_uncertain(),
                                Some(latest.clone()),
                            ));
                        }
                    }
                } else if pending {
                    target
                } else {
                    return Err(("The saved chat is no longer registered".into(), false, None));
                }
            };
            // Metadata is now authoritative, even if opening the new runtime
            // fails. Returning it prevents a retry from reviving the old route.
            let replacement = runtime
                .reopen(&record, &controller)
                .map_err(|e| (e.to_string(), false, Some(record.clone())))?;
            Ok(ConnectionSwitchResult {
                record,
                controller: replacement,
            })
        });
        let primary = self.project.clone();
        cx.spawn(async move|owner,cx|{let result=task.await;let _=owner.update(cx,|view,cx|{
            if view.project!=primary{return;}
            if let Err((_,true,_))=&result{view.observe_catalog_uncertainty(true,cx);}
            if view.connections.switches.get(&chat_id)!=Some(&operation){return;}
            view.connections.switches.remove(&chat_id);
            let valid=view.chat_ref(&chat_id).is_some_and(|c|previous.ptr_eq(&Arc::downgrade(&c.controller)));
            if !valid{return;}
            match result{
                Ok(changed)=>{
                    if let Some(record)=view.records.iter_mut().find(|r|r.id==chat_id){*record=changed.record.clone();}
                    if let Some(chat)=view.chat_mut(&chat_id){chat.record=changed.record;chat.loading=false;chat.load_failed=false;chat.replace_controller(changed.controller,cx);chat.error=Some("Next turn uses the selected saved connection and confirmed project settings.".into());}
                    view.connections.blocked.remove(&chat_id);
                },
                Err((message,uncertain,record))=>{
                    if !uncertain && let Some(record)=record {
                        if let Some(row)=view.records.iter_mut().find(|r|r.id==chat_id){*row=record.clone();}
                        if let Some(chat)=view.chat_mut(&chat_id){chat.record=record;}
                    }
                    if let Some(chat)=view.chat_mut(&chat_id){chat.error=Some(format!("Connection change did not complete: {message}. Drafts are retained; the old runtime remains stopped."));}
                }
            }
            cx.notify();
        });}).detach();
    }
    pub(crate) fn connection_picker_key(
        &mut self,
        event: &gpui::KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let count = self.connections.choices().len() + 1;
        match event.keystroke.key.as_str() {
            "escape" => self.connections.picker = false,
            "down" | "tab" => {
                self.connections.picker_index = (self.connections.picker_index + 1) % count
            }
            "up" => {
                self.connections.picker_index = (self.connections.picker_index + count - 1) % count
            }
            "enter" | "space" if !event.is_held => {
                let choices = self.connections.choices();
                if let Some(p) = choices.get(self.connections.picker_index) {
                    let id = p.profile.id.clone();
                    self.select_connection(&id, cx);
                } else {
                    self.open_connections(window, cx);
                }
            }
            _ => {}
        }
        cx.stop_propagation();
        cx.notify();
    }
    pub(crate) fn connection_picker_element(&self, cx: &Context<Self>) -> gpui::AnyElement {
        use gpui::{div, prelude::*, px, rgb, rgba};
        let mut body = div()
            .id("connection-choice-list")
            .overflow_y_scroll()
            .w(px(380.))
            .max_h(px(420.))
            .p(px(16.))
            .rounded(px(14.))
            .bg(rgb(self.palette.surface))
            .flex()
            .flex_col()
            .gap(px(8.))
            .child("Connection");
        if let Some(reason) = self.connection_switch_blocker() {
            body = body.child(div().text_size(px(12.)).child(reason));
        }
        for (index, profile) in self.connections.choices().into_iter().enumerate() {
            let id = profile.profile.id.clone();
            let active = self.record.connection_id.as_deref() == Some(&id);
            body = body.child(
                div()
                    .id(("connection-choice", index))
                    .px(px(10.))
                    .py(px(8.))
                    .rounded(px(6.))
                    .when(index == self.connections.picker_index, |d| {
                        d.bg(self.palette.accent_soft())
                    })
                    .child(format!(
                        "{}{} · {}",
                        if active { "✓ " } else { "" },
                        profile.name,
                        profile.profile.model_id
                    ))
                    .on_click(cx.listener(move |view, _, _, cx| view.select_connection(&id, cx))),
            );
        }
        body = body.child(
            self.button("manage-connections", "Manage Connections…")
                .on_click(cx.listener(|view, _, window, cx| view.open_connections(window, cx))),
        );
        div()
            .absolute()
            .inset_0()
            .occlude()
            .flex()
            .items_center()
            .justify_center()
            .bg(rgba(0x00000044))
            .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(body)
            .into_any_element()
    }
}

impl AgentView {
    pub(crate) fn request_connection_close(
        &mut self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.connections
            .view
            .update(cx, |view, cx| view.request_close(cx));
    }
    pub(crate) fn open_connection_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.shutting_down
            || self.projects.view.read(cx).is_open()
            || self.connections.operation.is_some()
        {
            return;
        }
        if self.connections.loaded.is_none() {
            self.open_connections(window, cx);
            return;
        }
        self.connections.picker = true;
        self.connections.picker_index = 0;
        cx.notify();
    }
}

#[cfg(all(test, feature = "synthetic-authority"))]
#[path = "connection_settings_controller_tests.rs"]
mod tests;
