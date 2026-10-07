//! Compatibility entry point for fixed-key numeric-loopback fixture connections.
//! The same saved connection lease and validator are used by the shared factory.
use super::*;
use crate::project_authority::synthetic::SyntheticAuthorityControl;
use crate::{
    Controller, Result, SessionStore,
    runtime::{Configuration, RuntimeOptions},
};
#[derive(Clone)]
pub struct SyntheticConnectionRuntime(SavedConnectionRuntime);
impl SyntheticConnectionRuntime {
    pub fn confirm(
        control: &SyntheticAuthorityControl,
        expected: &LoadedConnections,
        id: &str,
    ) -> Result<Self> {
        SavedConnectionRuntime::confirm(&control.authority(), expected, id).map(Self)
    }
    pub fn metadata(&self) -> &SavedConnection {
        self.0.metadata()
    }
    pub fn configuration(&self) -> Arc<Configuration> {
        self.0.configuration()
    }
    pub fn revoke(&self) {
        self.0.revoke();
    }
    pub fn open(&self, store: SessionStore, options: RuntimeOptions) -> Result<Arc<Controller>> {
        self.0.open(store, options)
    }
}
