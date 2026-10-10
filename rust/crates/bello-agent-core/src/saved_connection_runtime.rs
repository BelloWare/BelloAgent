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
    pub(crate) fn effective_profile(
        &self,
        base: &Profile,
        item: Option<&crate::Submission>,
    ) -> Profile {
        let Some(catalog) = &self.catalog else {
            return crate::runtime::tool_runtime::effective_profile(base, item);
        };
        let mut profile = base.clone();
        if let Some(model) = item.and_then(|item| item.model.as_ref()) {
            profile.model_id.clone_from(model);
        }
        if let Some(descriptor) = catalog.descriptor(&profile.model_id) {
            if profile.model_id != base.model_id {
                descriptor.applying(&mut profile);
            }
            if let Some(input) = descriptor.input {
                for kind in input {
                    if !profile.input.contains(&kind) {
                        profile.input.push(kind);
                    }
                }
            }
            if let Some(reasoning) = descriptor.reasoning {
                profile.reasoning = !reasoning.is_empty();
                let effort = item
                    .and_then(|item| item.effort.as_ref())
                    .unwrap_or(&profile.thinking_level);
                profile.thinking_level = if effort == "default" || reasoning.contains(effort) {
                    effort.clone()
                } else {
                    "default".into()
                };
                return profile;
            }
        }
        if let Some(effort) = item.and_then(|item| item.effort.as_ref()) {
            profile.thinking_level.clone_from(effort);
        }
        profile
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
            let source = expected
                .catalog_source(id)
                .map_err(|e| invalid(e.to_string()))?;
            let source_key = if source
                .catalog_url
                .as_ref()
                .is_some_and(|url| url.uses_gateway_credential(&source.profile))
            {
                field::<String>(
                    &expected.entries[expected
                        .index(&source.profile.id)
                        .map_err(|e| invalid(e.to_string()))?],
                    "apiKey",
                )
                .map_err(|e| invalid(e.to_string()))?
            } else {
                String::new()
            };
            Some(CatalogBinding::new(
                authority.catalogs.clone(),
                source.catalog_url.as_ref(),
                &source.profile,
                &source_key,
            ))
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
