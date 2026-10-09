//! Search-only lifecycle records, retained independently of Controller map gaps.
use bello_agent_core::sidebar_search::reconciliation::SourceRoute;
#[cfg(test)]
use bello_agent_core::sidebar_search::{SearchError, reconciliation::ReconciliationPass};
use std::collections::BTreeMap;

#[derive(Clone, Default)]
pub(crate) struct SearchLifecycles {
    rows: BTreeMap<String, (SourceRoute, uuid::Uuid)>,
}
pub(crate) struct SearchRestore(Vec<(String, SourceRoute, uuid::Uuid)>);
impl SearchLifecycles {
    pub(crate) fn ids(&self) -> impl Iterator<Item = &str> {
        self.rows.keys().map(String::as_str)
    }
    pub(crate) fn route(&self, id: &str) -> Option<SourceRoute> {
        self.rows.get(id).map(|(route, _)| *route)
    }
    pub(crate) fn set(&mut self, id: String, route: SourceRoute) {
        if self.route(&id) != Some(route) {
            self.rows.insert(id, (route, uuid::Uuid::new_v4()));
        }
    }
    pub(crate) fn block_all(&mut self) -> SearchRestore {
        let ids: Vec<_> = self.rows.keys().cloned().collect();
        self.block_members(ids)
    }
    pub(crate) fn block_members(&mut self, ids: impl IntoIterator<Item = String>) -> SearchRestore {
        let mut previous = Vec::new();
        for id in ids {
            let old = self.route(&id).unwrap_or(SourceRoute::Blocked);
            let token = uuid::Uuid::new_v4();
            self.rows.insert(id.clone(), (SourceRoute::Blocked, token));
            previous.push((id, old, token));
        }
        SearchRestore(previous)
    }
    pub(crate) fn restore(&mut self, previous: SearchRestore, only_unloaded: bool) {
        for (id, route, token) in previous.0 {
            if only_unloaded && route != SourceRoute::Unloaded {
                continue;
            }
            if self
                .rows
                .get(&id)
                .is_some_and(|(_, current)| *current == token)
            {
                self.rows.insert(id, (route, uuid::Uuid::new_v4()));
            }
        }
    }

    /// Loading, pending, uncertainty, retirement, failed cleanup and replacement
    /// all use Blocked; removal from the Controller map never calls this away.
    pub(crate) fn block(&mut self, id: &str) {
        self.rows
            .insert(id.into(), (SourceRoute::Blocked, uuid::Uuid::new_v4()));
    }
    pub(crate) fn loaded(&mut self, id: &str) {
        self.rows
            .insert(id.into(), (SourceRoute::Loaded, uuid::Uuid::new_v4()));
    }
    /// Only an explicit successful lifecycle transition may establish unloading.
    #[cfg(test)]
    pub(crate) fn unloaded(&mut self, id: &str) {
        self.rows
            .insert(id.into(), (SourceRoute::Unloaded, uuid::Uuid::new_v4()));
    }
    #[cfg(test)]
    pub(crate) fn apply(
        &self,
        pass: &mut ReconciliationPass,
        ids: impl IntoIterator<Item = String>,
    ) -> Result<(), SearchError> {
        for id in ids {
            if let Some((route, _)) = self.rows.get(&id) {
                pass.transition(&id, *route)?;
            }
        }
        Ok(())
    }
}
