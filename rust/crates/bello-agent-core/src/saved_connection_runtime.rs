//! Saved connection composition with storage-bound authority provenance.
use super::*;
use crate::{
    Controller, Credential, Result, SessionStore, invalid,
    runtime::{Configuration, RuntimeOptions},
};
use std::sync::atomic::{AtomicBool, Ordering};

pub(crate) struct ConnectionLease {
    authority: ProjectAuthority,
    entry: Fields,
    profile: Profile,
    live: AtomicBool,
    catalog: Option<CatalogBinding>,
}
impl ConnectionLease {
    /// Swift's `modelInput(for:)` and `applyModelChoice`: the chat's model is
    /// its own choice or the connection's. Declared input always applies and
    /// the catalog's input for that model adds to it. Only a chosen model takes
    /// the catalog's limits and a compatible effort; the connection's own
    /// model keeps the limits and reasoning saved with it.
    pub(crate) fn effective_profile(
        &self,
        base: &Profile,
        item: Option<&crate::Submission>,
    ) -> Profile {
        let Some(catalog) = &self.catalog else {
            return crate::runtime::tool_runtime::effective_profile(base, item);
        };
        let mut profile = base.clone();
        let chosen = item.and_then(|item| item.model.as_ref());
        if let Some(model) = chosen {
            profile.model_id.clone_from(model);
        }
        if let Some(effort) = item.and_then(|item| item.effort.as_ref()) {
            profile.thinking_level.clone_from(effort);
        }
        let Some(descriptor) = catalog.descriptor(&profile.model_id) else {
            return profile;
        };
        if chosen.is_some() {
            if descriptor.context_window.is_some() || descriptor.max_output_tokens.is_some() {
                let mut limits = base.clone();
                descriptor.applying(&mut limits);
                profile.context_window = limits.context_window;
                profile.max_output_tokens = limits.max_output_tokens;
                profile.model_output_limit = limits.model_output_limit;
            }
            if let Some(efforts) = &descriptor.reasoning {
                profile.reasoning = !efforts.is_empty();
                if efforts.is_empty()
                    || profile.thinking_level != "default"
                        && !efforts.contains(&profile.thinking_level)
                {
                    profile.thinking_level = "default".into();
                }
            }
        }
        if let Some(listed) = descriptor.input {
            profile.input = ["text", "image"]
                .into_iter()
                .filter(|kind| {
                    profile.input.iter().any(|declared| declared == kind)
                        || listed.iter().any(|listed| listed == kind)
                })
                .map(str::to_owned)
                .collect();
        }
        profile
    }
    /// A passive listing for this chat's catalog source, as Swift's model
    /// pill lists when a chat shows: nothing for the bundled catalog, a fresh
    /// or loading list, a fixture, or a revoked runtime. The source's key is
    /// read from the vault only now, and only when the catalog shares the
    /// gateway's origin. A changed source yields nothing: the saved
    /// connection's next runtime lists its own.
    pub(crate) fn catalog_stale(&self) -> bool {
        self.check().is_ok()
            && self
                .catalog
                .as_ref()
                .is_some_and(CatalogBinding::needs_load)
    }
    pub(crate) fn catalog_request(&self) -> Option<crate::model_catalog::CatalogRequest> {
        let binding = self.catalog.as_ref()?;
        if self.check().is_err() || !binding.needs_load() {
            return None;
        }
        let current = self.authority.load_connections().ok()?;
        let (current_binding, request) =
            catalog_source(&self.authority, &current, &self.profile.id).ok()?;
        if !current_binding.same_source(binding) {
            return None;
        }
        let (source_id, url, key) = request?;
        Some(crate::model_catalog::CatalogRequest::native(
            Some(source_id),
            url,
            key,
            current_binding,
        ))
    }
    pub(crate) fn check(&self) -> Result<()> {
        if self.live.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(invalid("This saved connection runtime was revoked"))
        }
    }
    pub(crate) fn is_fixture(&self) -> bool {
        #[cfg(feature = "synthetic-authority")]
        {
            self.authority.provenance == super::super::AuthorityProvenance::Fixture
        }
        #[cfg(not(feature = "synthetic-authority"))]
        {
            false
        }
    }
    pub(crate) fn same_authority(&self, other: &Self) -> bool {
        matches!((&self.authority.storage,&other.authority.storage), (Some(a),Some(b)) if Arc::ptr_eq(a,b))
    }
    pub(crate) fn confirm(&self, exact: bool) -> Result<()> {
        self.check()?;
        let current = self
            .authority
            .load_connections()
            .map_err(|e| invalid(e.to_string()))?;
        let index = current
            .index(&self.profile.id)
            .map_err(|_| invalid("The saved connection was deleted or is unavailable"))?;
        let saved = &current.profiles[index];
        if !saved.available || !same_route(&saved.profile, &self.profile) {
            return Err(invalid("The saved connection route is no longer current"));
        }
        let (key, headers) =
            secrets(&current.entries[index]).map_err(|e| invalid(e.to_string()))?;
        let mut profile = saved.profile.clone();
        profile.headers = headers;
        validate_connection(&self.authority, &profile, &key).map_err(|e| invalid(e.to_string()))?;
        if exact
            && raw(&self.entry).map_err(|e| invalid(e.to_string()))?.get()
                != raw(&current.entries[index])
                    .map_err(|e| invalid(e.to_string()))?
                    .get()
        {
            return Err(invalid(
                "The saved connection changed. Apply its current settings before sending",
            ));
        }
        self.check()
    }
}

type SourceRequest = (String, CatalogUrl, Option<Credential>);
/// The catalog a saved route lists through (its own or its recorded source)
/// and, for a custom URL, what a listing would send. A gateway key goes only
/// to the gateway's own origin, as Swift's `usesGatewayCredential`.
fn catalog_source(
    authority: &ProjectAuthority,
    loaded: &LoadedConnections,
    id: &str,
) -> AuthorityResult<(CatalogBinding, Option<SourceRequest>)> {
    let source = loaded.catalog_source(id)?;
    let key = match &source.catalog_url {
        Some(url) if url.uses_gateway_credential(&source.profile) => Some(field::<String>(
            &loaded.entries[loaded.index(&source.profile.id)?],
            "apiKey",
        )?),
        _ => None,
    };
    let binding = CatalogBinding::new(
        authority.catalogs.clone(),
        source.catalog_url.as_ref(),
        &source.profile,
        key.as_deref().unwrap_or(""),
    );
    let request = match (&source.catalog_url, key) {
        (None, _) => None,
        (Some(url), None) => Some((source.profile.id.clone(), url.clone(), None)),
        (Some(url), Some(key)) => Credential::new(key)
            .ok()
            .map(|key| (source.profile.id.clone(), url.clone(), Some(key))),
    };
    Ok((binding, request))
}

/// Shared immediate revocation plus an opaque confirmed configuration. A saved
/// update creates a fresh runtime; it never reactivates an older revoked handle.
#[derive(Clone)]
pub struct SavedConnectionRuntime {
    metadata: SavedConnection,
    configuration: Arc<Configuration>,
    lease: Arc<ConnectionLease>,
}
impl SavedConnectionRuntime {
    pub fn confirm(
        authority: &ProjectAuthority,
        expected: &LoadedConnections,
        id: &str,
    ) -> Result<Self> {
        let confirmed = authority
            .confirm_connection(expected, id)
            .map_err(|e| invalid(e.to_string()))?;
        let (key, headers) = secrets(&confirmed.entry).map_err(|e| invalid(e.to_string()))?;
        let mut profile = confirmed.metadata.profile.clone();
        profile.headers = headers;
        validate_connection(authority, &profile, &key).map_err(|e| invalid(e.to_string()))?;
        let catalog = if authority.provenance == super::super::AuthorityProvenance::Production {
            Some(
                catalog_source(authority, expected, id)
                    .map_err(|e| invalid(e.to_string()))?
                    .0,
            )
        } else {
            None
        };
        let lease = Arc::new(ConnectionLease {
            authority: confirmed.authority,
            entry: confirmed.entry,
            profile: profile.clone(),
            live: AtomicBool::new(true),
            catalog,
        });
        let configuration = Arc::new(Configuration::saved_connection(
            profile,
            Credential::new(key)?,
            lease.clone(),
        ));
        lease.confirm(true)?;
        Ok(Self {
            metadata: confirmed.metadata,
            configuration,
            lease,
        })
    }
    pub fn metadata(&self) -> &SavedConnection {
        &self.metadata
    }
    pub fn configuration(&self) -> Arc<Configuration> {
        self.configuration.clone()
    }
    pub fn revoke(&self) {
        self.lease.live.store(false, Ordering::Release);
    }
    pub fn open(&self, store: SessionStore, options: RuntimeOptions) -> Result<Arc<Controller>> {
        self.lease.confirm(true)?;
        if options.tools.is_some() {
            return Err(invalid(
                "Saved connections require the trusted project runtime factory for tools",
            ));
        }
        Controller::with_configuration_and_options(store, Some(self.configuration()), options)
    }
}
