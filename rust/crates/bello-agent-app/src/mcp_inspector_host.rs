//! Save-before-apply transaction. Loaded idle guards, unloaded writer leases and
//! the manager's project reservation are acquired before the whole-vault CAS.
use crate::project_host::LoadedChat;
use bello_agent_core::{
    mcp::{CancellationToken, McpManager},
    project_authority::{AuthorityError, ProjectAuthority, SavedProject, mcp::LoadedMcp},
    runtime::IdleAdmissionGuard,
    session::SessionInspectionLease,
    workspace::{ChatMaterialization, ChatRecord, WorkspaceStore},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, Mutex},
};

pub(crate) struct McpConfigurationSave {
    pub authority: Arc<ProjectAuthority>,
    pub baseline: LoadedMcp,
    pub project: SavedProject,
    pub manager: Arc<McpManager>,
    pub workspace: Arc<Mutex<WorkspaceStore>>,
    pub configuration: String,
    pub headers: BTreeMap<String, String>,
    pub loaded: Vec<LoadedChat>,
    pub unloaded: Vec<ChatRecord>,
}
impl Drop for McpConfigurationSave {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        for value in self.headers.values_mut() {
            value.zeroize();
        }
    }
}
pub(crate) struct McpSaveFailure {
    pub message: String,
    pub keep_blocked: bool,
    pub unconfirmed: bool,
}
impl McpSaveFailure {
    fn before(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            keep_blocked: false,
            unconfirmed: false,
        }
    }
    fn after(message: impl Into<String>, unconfirmed: bool) -> Self {
        Self {
            message: message.into(),
            keep_blocked: true,
            unconfirmed,
        }
    }
}
/// Once persistence may have changed, cancellation/panic cannot silently resume
/// old actors before the shared manager has accepted the exact saved revision.
struct AdmissionSet {
    guards: Vec<IdleAdmissionGuard>,
    saved: bool,
    applied: bool,
}
impl Drop for AdmissionSet {
    fn drop(&mut self) {
        if self.saved && !self.applied {
            for guard in self.guards.drain(..) {
                guard.retain_fence();
            }
        }
    }
}
impl McpConfigurationSave {
    fn validate_catalog(&self) -> Result<(), McpSaveFailure> {
        let catalog = self
            .workspace
            .lock()
            .map_err(|_| McpSaveFailure::before("The workspace is unavailable."))?;
        if catalog.is_uncertain() {
            return Err(McpSaveFailure::after(
                "The workspace has an unconfirmed save. MCP changes remain blocked.",
                true,
            ));
        }
        let snapshot = catalog.snapshot();
        if snapshot.project != self.project.path
            || snapshot.project_id.as_deref() != Some(&self.project.id)
            || self.baseline.project_id() != self.project.id
            || self.manager.project_id() != self.project.id
        {
            return Err(McpSaveFailure::before(
                "The selected saved project changed. Reopen its MCP Inspector.",
            ));
        }
        let mut supplied = BTreeMap::new();
        for record in self
            .loaded
            .iter()
            .map(|chat| &chat.record)
            .chain(self.unloaded.iter())
        {
            if supplied.insert(record.id.clone(), record).is_some() {
                return Err(McpSaveFailure::before(
                    "The project's chat identity changed.",
                ));
            }
        }
        for record in &snapshot.chats {
            let Some(captured) = supplied.get(&record.id) else {
                return Err(McpSaveFailure::before(
                    "The project's chat list changed. Review it before saving MCP.",
                ));
            };
            if captured.snapshot != record.snapshot
                || captured.connection_id != record.connection_id
                || captured.tool_mode != record.tool_mode
                || captured.materialization != record.materialization
            {
                return Err(McpSaveFailure::before(
                    "A saved chat identity changed before MCP could be saved.",
                ));
            }
        }
        let registered: BTreeSet<_> = snapshot.chats.iter().map(|c| c.id.as_str()).collect();
        if self
            .unloaded
            .iter()
            .any(|r| !registered.contains(r.id.as_str()))
            || self.loaded.iter().any(|c| {
                !registered.contains(c.record.id.as_str())
                    && (c.record.materialization != ChatMaterialization::Pending
                        || !c.controller.is_never_materialized())
            })
        {
            return Err(McpSaveFailure::before(
                "A chat is no longer registered in this project.",
            ));
        }
        Ok(())
    }
    pub async fn apply(mut self, cancel: CancellationToken) -> Result<LoadedMcp, McpSaveFailure> {
        self.validate_catalog()?;
        self.loaded.sort_by(|a, b| {
            a.record
                .snapshot
                .cmp(&b.record.snapshot)
                .then(a.record.id.cmp(&b.record.id))
        });
        self.unloaded
            .sort_by(|a, b| a.snapshot.cmp(&b.snapshot).then(a.id.cmp(&b.id)));
        let mut admissions = AdmissionSet {
            guards: vec![],
            saved: false,
            applied: false,
        };
        for chat in &self.loaded {
            if chat.controller.snapshot_shared().id != chat.record.id {
                return Err(McpSaveFailure::before("A chat runtime identity changed."));
            }
            admissions
                .guards
                .push(chat.controller.suspend_idle_admission().map_err(|_| {
                McpSaveFailure::before(
                    "Stop this project's work and finish queued or held edits before changing MCP.",
                )
            })?);
        }
        let mut leases = Vec::new();
        for record in &self.unloaded {
            if record.materialization == ChatMaterialization::Pending {
                return Err(McpSaveFailure::before(
                    "Open the project's unsent chats before changing MCP configuration.",
                ));
            }
            let lease=SessionInspectionLease::acquire(&record.snapshot,&record.id)
                .and_then(|lease|lease.into_idle_lease())
                .map_err(|_|McpSaveFailure::before("An unopened chat has active work, a held edit, or another writer. MCP was not saved."))?;
            leases.push(lease);
        }
        let reservation=self.manager.begin_configuration_change().map_err(|_|McpSaveFailure::before("Wait for this project's MCP operation and pending result checkpoint before saving."))?;
        self.validate_catalog()?;
        if cancel.is_cancelled() {
            return Err(McpSaveFailure::before("MCP save cancelled before writing."));
        }
        let saved = match self.authority.save_mcp(
            &self.baseline,
            &self.configuration,
            &self.headers,
        ) {
            Ok(saved) => saved,
            Err(error) => {
                if error == AuthorityError::Unconfirmed {
                    admissions.saved = true;
                    return Err(McpSaveFailure::after(
                        "The MCP vault write was not confirmed. Your draft is retained; project actions remain blocked.",
                        true,
                    ));
                }
                return Err(McpSaveFailure::before(error.to_string()));
            }
        };
        admissions.saved = true;
        reservation.apply_configuration(saved.clone(),cancel).await.map_err(|_|McpSaveFailure::after("MCP configuration was saved, but the runtime could not apply it. Your draft is retained; project actions remain blocked.",false))?;
        admissions.applied = true;
        drop(leases);
        Ok(saved)
    }
}

#[cfg(all(test, feature = "synthetic-authority"))]
#[path = "mcp_inspector_host_tests.rs"]
mod tests;
