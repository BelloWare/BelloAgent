//! Fixed-credential loopback-only saved connection composition; tools stay disabled.
use super::*;
use crate::project_authority::synthetic::SyntheticAuthorityControl;
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
}
impl ConnectionLease {
    pub(crate) fn check(&self) -> Result<()> {
        if self.live.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(invalid("This saved connection runtime was revoked"))
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
        validate_synthetic(&profile, &key).map_err(|e| invalid(e.to_string()))?;
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
pub struct SyntheticConnectionRuntime {
    metadata: SavedConnection,
    configuration: Arc<Configuration>,
    lease: Arc<ConnectionLease>,
}
impl SyntheticConnectionRuntime {
    pub fn confirm(
        control: &SyntheticAuthorityControl,
        expected: &LoadedConnections,
        id: &str,
    ) -> Result<Self> {
        let confirmed = control
            .authority()
            .confirm_connection(expected, id)
            .map_err(|e| invalid(e.to_string()))?;
        let (key, headers) = secrets(&confirmed.entry).map_err(|e| invalid(e.to_string()))?;
        let mut profile = confirmed.metadata.profile.clone();
        profile.headers = headers;
        validate_synthetic(&profile, &key).map_err(|e| invalid(e.to_string()))?;
        let lease = Arc::new(ConnectionLease {
            authority: confirmed.authority,
            entry: confirmed.entry,
            profile: profile.clone(),
            live: AtomicBool::new(true),
        });
        let configuration = Arc::new(Configuration::synthetic_connection(
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
                "Saved synthetic connections do not enable model tools",
            ));
        }
        Controller::with_configuration_and_options(store, Some(self.configuration()), options)
    }
}
