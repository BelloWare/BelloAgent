//! Search-only lifecycle records. Deliberately not wired to production demand:
//! the real pre-retirement call sites must adopt these before UI enablement.
use bello_agent_core::sidebar_search::{
    SearchError,
    reconciliation::{ReconciliationPass, SourceRoute},
};
use std::collections::BTreeMap;

#[derive(Default)]
#[allow(dead_code)] // Callable adapter contract, not yet a production search service.
pub(crate) struct SearchLifecycles {
    rows: BTreeMap<String, SourceRoute>,
}
#[allow(dead_code)]
impl SearchLifecycles {
    /// Loading, pending, uncertainty, retirement, failed cleanup and replacement
    /// all use Blocked; removal from the Controller map never calls this away.
    pub(crate) fn block(&mut self, id: &str) {
        self.rows.insert(id.into(), SourceRoute::Blocked);
    }
    pub(crate) fn loaded(&mut self, id: &str) {
        self.rows.insert(id.into(), SourceRoute::Loaded);
    }
    /// Only an explicit successful lifecycle transition may establish unloading.
    pub(crate) fn unloaded(&mut self, id: &str) {
        self.rows.insert(id.into(), SourceRoute::Unloaded);
    }
    pub(crate) fn apply(
        &self,
        pass: &mut ReconciliationPass,
        ids: impl IntoIterator<Item = String>,
    ) -> Result<(), SearchError> {
        for id in ids {
            if let Some(route) = self.rows.get(&id) {
                pass.transition(&id, *route)?;
            }
        }
        Ok(())
    }
}
