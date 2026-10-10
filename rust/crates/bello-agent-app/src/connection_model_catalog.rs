//! Form-scoped catalog state. Lists never change dispatch routing, write the
//! vault or submit a turn. Publication is source-fenced.
use super::*;
use bello_agent_core::model_catalog::{CancellationToken, ModelDescriptor};
use std::time::{Duration, Instant};

const PAGE_SIZE: usize = 40;
const TTL: Duration = Duration::from_secs(300);
const FAILURE_BACKOFF: Duration = Duration::from_secs(30);

// Deliberately no Debug. Typed key material belongs only to this in-memory form.
#[derive(Clone, PartialEq, Eq)]
struct SourceIdentity {
    revision: Option<i64>,
    api: String,
    base: String,
    url: String,
    key: String,
    headers: String,
}
impl SourceIdentity {
    fn of(form: &RetainedForm, loaded: Option<&LoadedConnections>) -> Self {
        Self {
            revision: loaded.map(LoadedConnections::revision),
            api: form.fields.api.clone(),
            base: form.fields.base_url.clone(),
            url: form.fields.catalog_url.clone(),
            key: form.fields.key.clone(),
            headers: form.fields.headers.clone(),
        }
    }
}

pub(super) struct CatalogState {
    identity: SourceIdentity,
    pub(super) opened: bool,
    pub(super) page: usize,
    query: String,
    generation: uuid::Uuid,
    source: String,
    bundled: bool,
    models: Vec<ModelDescriptor>,
    error: Option<String>,
    fetched: Option<Instant>,
    cancel: Option<CancellationToken>,
}
impl CatalogState {
    fn new(identity: SourceIdentity) -> Self {
        Self {
            source: if identity.url.trim().is_empty() {
                "Bundled Bello catalog"
            } else {
                "Custom catalog"
            }
            .into(),
            bundled: identity.url.trim().is_empty(),
            identity,
            opened: false,
            page: 0,
            query: String::new(),
            generation: uuid::Uuid::new_v4(),
            models: vec![],
            error: None,
            fetched: None,
            cancel: None,
        }
    }
    fn cancel(&mut self) {
        if let Some(cancel) = self.cancel.take() {
            cancel.cancel();
            self.generation = uuid::Uuid::new_v4();
        }
    }
    pub(super) fn close(&mut self) {
        self.cancel();
        self.opened = false;
    }
    fn fresh(&self, now: Instant) -> bool {
        self.fetched.is_some_and(|fetched| {
            if self.error.is_some() {
                now.saturating_duration_since(fetched) < FAILURE_BACKOFF
            } else {
                self.bundled || now.saturating_duration_since(fetched) < TTL
            }
        })
    }
}
impl Drop for CatalogState {
    fn drop(&mut self) {
        self.cancel();
    }
}
impl ConnectionSettingsController {
    pub(super) fn sync_catalog_sources(&mut self) {
        self.catalogs.retain(|id, _| self.forms.contains_key(id));
        for (id, form) in &self.forms {
            let identity = SourceIdentity::of(form, self.loaded.as_ref());
            if let Some(state) = self.catalogs.get_mut(id) {
                if state.identity != identity {
                    let opened = state.opened;
                    *state = CatalogState::new(identity);
                    state.opened = opened;
                    state.error = opened.then(|| "The catalog source changed. Choose model or Refresh to load this source.".into());
                }
                if state.query != form.fields.catalog_search {
                    state.query.clone_from(&form.fields.catalog_search);
                    state.page = 0;
                }
            }
        }
    }
    pub(crate) fn cancel_catalog_loads(&mut self) {
        for state in self.catalogs.values_mut() {
            state.cancel();
        }
    }
    pub(super) fn catalog_presentation(
        &self,
        id: &str,
        form: &RetainedForm,
    ) -> ConnectionCatalogPresentation {
        let Some(state) = self.catalogs.get(id) else {
            return ConnectionCatalogPresentation::default();
        };
        let query = form.fields.catalog_search.trim().to_lowercase();
        let matches: Vec<_> = state
            .models
            .iter()
            .filter(|model| {
                (!model.deprecated || model.id == form.fields.model)
                    && (query.is_empty()
                        || model.id.to_lowercase().contains(&query)
                        || model.name.to_lowercase().contains(&query)
                        || model.description.to_lowercase().contains(&query))
            })
            .collect();
        let total = matches.len();
        let pages = total.div_ceil(PAGE_SIZE).max(1);
        let page = state.page.min(pages - 1);
        ConnectionCatalogPresentation {
            opened: state.opened,
            loading: state.cancel.is_some(),
            error: state.error.clone(),
            source: state.source.clone(),
            generation: state.generation,
            models: matches
                .into_iter()
                .skip(page * PAGE_SIZE)
                .take(PAGE_SIZE)
                .cloned()
                .collect(),
            total,
            page,
            pages,
        }
    }
}
impl AgentView {
    pub(super) fn load_connection_catalog(&mut self, force: bool, cx: &mut Context<Self>) {
        if !self.connections.open
            || self.connections.operation.is_some()
            || self.connections.uncertain
        {
            return;
        }
        self.connections.sync_catalog_sources();
        let Some(id) = self.connections.active.clone() else {
            return;
        };
        let Some(form) = self.connections.forms.get(&id) else {
            return;
        };
        let identity = SourceIdentity::of(form, self.connections.loaded.as_ref());
        let state = self
            .connections
            .catalogs
            .entry(id.clone())
            .or_insert_with(|| CatalogState::new(identity.clone()));
        state.opened = true;
        if state.cancel.is_some() || (!force && state.fresh(Instant::now())) {
            self.connections.publish(cx);
            return;
        }
        // Listing ignores incomplete model/budget edits. Only the explicit catalog
        // origin/key fields participate in preparation, not dispatch configuration.
        let mut draft = form.draft.clone();
        draft.profile.api.clone_from(&form.fields.api);
        draft.profile.base_url.clone_from(&form.fields.base_url);
        draft.catalog_url.clone_from(&form.fields.catalog_url);
        draft.key_input.clone_from(&form.fields.key);
        draft.headers_input.clone_from(&form.fields.headers);
        let Some(loaded) = self.connections.loaded.clone() else {
            return;
        };
        // Identify inherited sources even when preparation fails before a GET.
        // A missing credential must not make a custom source look bundled.
        if draft.catalog_url.trim().is_empty()
            && loaded
                .catalog_source(&id)
                .ok()
                .is_some_and(|source| source.catalog_url.is_some())
        {
            state.source = "Saved connection's catalog".into();
            state.bundled = false;
        }
        let request = match self.connections.authority.prepare_catalog(&loaded, &draft) {
            Ok(request) => request,
            Err(_) => {
                // A failed authority/source preparation is not a same-source
                // HTTP refresh failure. The saved revision may have changed.
                state.models.clear();
                state.generation = uuid::Uuid::new_v4();
                state.page = 0;
                state.error = Some(if self.connections.presentation.mode.is_fixture() {
                    "Couldn't load this catalog. Use a numeric loopback URL and the fixture key for a same-origin catalog; reload saved connections if they changed."
                } else {
                    "Couldn't load this catalog. Use HTTPS or explicit loopback HTTP and a valid key for a same-origin catalog; reload saved connections if they changed."
                }.into());
                state.fetched = Some(Instant::now());
                self.connections.publish(cx);
                return;
            }
        };
        state.bundled = request.is_bundled();
        state.source = if request.is_bundled() {
            "Bundled Bello catalog"
        } else if request.source_id().is_some_and(|source| source != id) {
            "Saved connection's catalog"
        } else {
            "Custom catalog"
        }
        .into();
        let cancel = CancellationToken::new();
        state.cancel = Some(cancel.clone());
        state.error = None;
        state.generation = uuid::Uuid::new_v4();
        let generation = state.generation;
        let binding = self.window_binding;
        self.connections.publish(cx);
        let task = cx
            .background_executor()
            .spawn(async move { request.load(cancel).await });
        cx.spawn(async move |owner, cx| {
            let result = task.await;
            let _ = owner.update(cx, |view, cx| {
                view.finish_connection_catalog(&id, generation, &identity, binding, result, cx);
            });
        })
        .detach();
    }
    fn finish_connection_catalog(
        &mut self,
        id: &str,
        generation: uuid::Uuid,
        identity: &SourceIdentity,
        binding: Option<crate::workspace_lifetime::WindowBinding>,
        result: Result<Vec<ModelDescriptor>, bello_agent_core::model_catalog::CatalogError>,
        cx: &mut Context<Self>,
    ) {
        self.connections.sync_catalog_sources();
        if !self.connections.open
            || self.shutting_down
            || self.connections.operation.is_some()
            || self.connections.load.is_some()
            || self.connections.uncertain
            || self.connections.active.as_deref() != Some(id)
            || self.window_binding != binding
        {
            return;
        }
        let Some(state) = self.connections.catalogs.get_mut(id) else {
            return;
        };
        if state.generation != generation || state.identity != *identity || state.cancel.is_none() {
            return;
        }
        state.cancel = None;
        state.fetched = Some(Instant::now());
        match result {
            Ok(models) => {
                state.models = models;
                state.error = None;
                state.page = 0;
            }
            Err(error) => {
                state.error = Some(format!(
                    "{error}{}",
                    if state.models.is_empty() {
                        " You can still type an alias."
                    } else {
                        " Previous results remain available."
                    }
                ))
            }
        }
        self.connections.publish(cx);
    }
    pub(super) fn choose_connection_model(&mut self, selected: &str, generation: uuid::Uuid) {
        self.connections.sync_catalog_sources();
        let Some(id) = self.connections.active.clone() else {
            return;
        };
        let Some(state) = self.connections.catalogs.get(&id) else {
            return;
        };
        if !state.opened || state.generation != generation {
            return;
        }
        let Some(model) = state
            .models
            .iter()
            .find(|model| model.id == selected)
            .cloned()
        else {
            return;
        };
        let Some(form) = self.connections.forms.get_mut(&id) else {
            return;
        };
        match form.capture() {
            Ok(mut draft) => {
                let changed_alias = draft.profile.model_id != model.id;
                model.applying(&mut draft.profile);
                if changed_alias && !form.preserve_declared_input {
                    draft.profile.input = vec!["text".into()];
                }
                let search = form.fields.catalog_search.clone();
                form.fields = fields(&draft);
                form.fields.catalog_search = search;
                form.draft = draft;
                self.connections.notice("Model metadata applied to this form. Save All to retain it; no chat request was sent.", false);
                self.connections.draft_notice_owner = Some(id);
            }
            Err(message) => self.connections.notice(message, true),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity() -> SourceIdentity {
        SourceIdentity::of(
            &new_form(crate::launch_authority::AuthorityMode::Fixture),
            None,
        )
    }
    #[::core::prelude::v1::test]
    fn catalog_cache_ttl_backoff_and_inherited_remote_do_not_become_permanent() {
        let now = Instant::now();
        let mut state = CatalogState::new(identity());
        assert!(!state.fresh(now));
        state.fetched = Some(now);
        assert!(state.fresh(now + Duration::from_secs(1_000)));
        // An inherited custom source has an empty own-URL field, but remote TTL.
        state.bundled = false;
        assert!(state.fresh(now + Duration::from_secs(299)));
        assert!(!state.fresh(now + TTL));
        state.error = Some("Unavailable".into());
        assert!(state.fresh(now + Duration::from_secs(29)));
        assert!(!state.fresh(now + FAILURE_BACKOFF));
    }
    #[::core::prelude::v1::test]
    fn cancellation_fences_old_completion_without_cancelling_a_new_request() {
        let mut state = CatalogState::new(identity());
        let old_generation = state.generation;
        let old = CancellationToken::new();
        state.cancel = Some(old.clone());
        state.cancel();
        assert!(old.is_cancelled());
        assert_ne!(state.generation, old_generation);
        let next = CancellationToken::new();
        state.cancel = Some(next.clone());
        assert!(!next.is_cancelled());
        drop(state);
        assert!(next.is_cancelled());
    }
    #[::core::prelude::v1::test]
    fn source_identity_covers_typed_key_url_route_and_saved_revision_not_search() {
        let mut form = new_form(crate::launch_authority::AuthorityMode::Fixture);
        let initial = SourceIdentity::of(&form, None);
        form.fields.catalog_search = "model search".into();
        assert!(initial == SourceIdentity::of(&form, None));
        for (field, value) in [
            ("key", "synthetic-project-fixture-only"),
            ("url", "http://127.0.0.1:1/catalog?token=fixture"),
            ("base", "http://127.0.0.1:2"),
            ("headers", "{}"),
            ("api", "other"),
        ] {
            let mut changed = form.clone();
            match field {
                "key" => changed.fields.key = value.into(),
                "url" => changed.fields.catalog_url = value.into(),
                "base" => changed.fields.base_url = value.into(),
                "headers" => changed.fields.headers = value.into(),
                _ => changed.fields.api = value.into(),
            }
            assert!(initial != SourceIdentity::of(&changed, None), "{field}");
        }
    }
    #[::core::prelude::v1::test]
    fn transient_search_is_clean_and_manual_alias_roundtrip_does_not_resurrect_metadata() {
        let mut form = new_form(crate::launch_authority::AuthorityMode::Fixture);
        form.fields.catalog_search = "anything".into();
        assert!(!form.dirty());
        let original = form.fields.model.clone();
        form.draft.profile.model_output_limit = Some(8000);
        form.draft.profile.input = vec!["text".into(), "image".into()];
        assert!(form.dirty(), "metadata-only edits are tracked");
        let mut changed = form.fields.clone();
        changed.model = "manual-alias".into();
        form.update_fields(changed);
        let mut changed = form.fields.clone();
        changed.model = original;
        form.update_fields(changed);
        assert_eq!(form.draft.profile.model_output_limit, None);
        assert_eq!(form.draft.profile.input, ["text"]);
    }
    #[::core::prelude::v1::test]
    fn native_manual_alias_edits_preserve_declared_input_while_fixture_edits_reset_it() {
        use crate::launch_authority::AuthorityMode;
        for mode in [AuthorityMode::Native, AuthorityMode::Fixture] {
            let mut form = new_form(mode);
            form.draft.profile.input = vec!["text".into(), "image".into()];
            form.draft.profile.model_output_limit = Some(128);
            let mut changed = form.fields.clone();
            changed.model = "manual-fake-alias".into();
            form.update_fields(changed);
            let captured = form.capture().unwrap();
            assert_eq!(
                captured.profile.supports_images(),
                mode == AuthorityMode::Native
            );
            assert_eq!(captured.profile.model_output_limit, None);
        }
    }
}

#[cfg(all(test, feature = "synthetic-authority"))]
#[path = "connection_catalog_lifecycle_tests.rs"]
mod lifecycle_tests;
