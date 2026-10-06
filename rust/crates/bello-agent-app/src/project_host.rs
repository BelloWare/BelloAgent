//! Current-project configuration transaction. Source: WorkspaceFolders.swift.
//! The host blocks app intents before scheduling this work. Actor suspensions
//! and inspection leases close direct-call/external-writer races before saving.
use bello_agent_core::{
    Controller, SessionStore,
    project_authority::{AuthorityError, LoadedProjects, ProjectAuthority, SavedProject},
    runtime::IdleAdmissionGuard,
    session::SessionInspectionLease,
    workspace::{ChatRecord, WorkspaceSnapshot, WorkspaceStore},
};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

pub(crate) struct LoadedChat {
    pub record: ChatRecord,
    pub controller: Arc<Controller>,
}
pub(crate) struct Replacement {
    pub id: String,
    pub previous: Arc<Controller>,
    pub controller: Arc<Controller>,
}
pub(crate) struct ProjectChange {
    pub authority: Arc<ProjectAuthority>,
    pub workspace: Arc<Mutex<WorkspaceStore>>,
    pub baseline: LoadedProjects,
    pub primary: PathBuf,
    pub extras: Vec<PathBuf>,
    pub loaded: Vec<LoadedChat>,
    pub unloaded: Vec<ChatRecord>,
}

/// A bound catalog must resolve its immutable ID and exact original root.
/// Legacy unbound catalogs may display a unique saved root, but loading never
/// binds them or turns that display into runtime authority.
pub(crate) fn resolve_saved_project<'a>(
    loaded: &'a LoadedProjects,
    primary: &Path,
    project_id: Option<&str>,
) -> Result<Option<&'a SavedProject>, AuthorityError> {
    if let Some(id) = project_id {
        return loaded
            .projects()
            .iter()
            .find(|saved| saved.id == id)
            .filter(|saved| saved.path == primary)
            .map(Some)
            .ok_or(AuthorityError::Conflict);
    }
    let mut matches = loaded
        .projects()
        .iter()
        .filter(|saved| saved.path == primary);
    let saved = matches.next();
    if matches.next().is_some() {
        return Err(AuthorityError::Conflict);
    }
    Ok(saved)
}
pub(crate) struct ChangedProject {
    pub loaded: LoadedProjects,
    pub project: SavedProject,
    pub replacements: Vec<Replacement>,
}
pub(crate) struct ProjectChangeFailure {
    pub message: String,
    /// A write may have committed or a runtime was retired. Admission must
    /// remain blocked; a refresh alone cannot revive old controllers.
    pub keep_blocked: bool,
    pub unconfirmed: bool,
}
impl ProjectChangeFailure {
    fn before_write(message: impl ToString) -> Self {
        Self {
            message: message.to_string(),
            keep_blocked: false,
            unconfirmed: false,
        }
    }
    fn after_write(message: impl ToString, unconfirmed: bool) -> Self {
        Self {
            message: message.to_string(),
            keep_blocked: true,
            unconfirmed,
        }
    }
    fn catalog_binding(error: bello_agent_core::Error, uncertain: bool) -> Self {
        let unconfirmed =
            uncertain || matches!(error, bello_agent_core::Error::PersistenceUncertain(_));
        Self::after_write(
            format!("Project folders were saved; workspace identity could not be saved: {error}"),
            unconfirmed,
        )
    }
}

fn validate_catalog_identity(
    primary: &Path,
    catalog: &WorkspaceSnapshot,
    uncertain: bool,
) -> Result<(), ProjectChangeFailure> {
    if uncertain {
        return Err(ProjectChangeFailure::after_write(
            "The workspace has an unconfirmed save. New chat actions remain blocked.",
            true,
        ));
    }
    if catalog.project != primary {
        return Err(ProjectChangeFailure::before_write(
            "The workspace identity changed.",
        ));
    }
    Ok(())
}

impl ProjectChange {
    pub async fn apply(mut self) -> Result<ChangedProject, ProjectChangeFailure> {
        let bound_id = {
            let catalog = self
                .workspace
                .lock()
                .map_err(|_| ProjectChangeFailure::before_write("The workspace is unavailable."))?;
            let snapshot = catalog.snapshot();
            validate_catalog_identity(&self.primary, &snapshot, catalog.is_uncertain())?;
            snapshot.project_id
        };
        // Reject ID/root disagreement before any authority mutation; a different
        // saved project with the same path cannot replace this binding.
        let existing = resolve_saved_project(&self.baseline, &self.primary, bound_id.as_deref())
            .map_err(ProjectChangeFailure::before_write)?;
        let id = existing
            .map(|p| p.id.clone())
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        // Nonblocking lock acquisition in stable order. Any prewrite error drops
        // already acquired guards and leases, so partial acquisition is harmless.
        self.loaded.sort_by(|a, b| {
            a.record
                .snapshot
                .cmp(&b.record.snapshot)
                .then(a.record.id.cmp(&b.record.id))
        });
        self.unloaded
            .sort_by(|a, b| a.snapshot.cmp(&b.snapshot).then(a.id.cmp(&b.id)));
        let mut persistent = Vec::with_capacity(self.loaded.len());
        let mut guards: Vec<IdleAdmissionGuard> = Vec::with_capacity(self.loaded.len());
        for chat in &self.loaded {
            if chat.controller.snapshot_shared().id != chat.record.id {
                return Err(ProjectChangeFailure::before_write(
                    "Chat runtime identity changed.",
                ));
            }
            let guard = chat
                .controller
                .suspend_idle_admission()
                .map_err(ProjectChangeFailure::before_write)?;
            persistent.push(guard.is_persistent());
            guards.push(guard);
        }
        let mut leases = Vec::with_capacity(self.unloaded.len());
        for chat in &self.unloaded {
            let lease =
                SessionInspectionLease::acquire(&chat.snapshot, &chat.id).map_err(|error| {
                    ProjectChangeFailure::before_write(format!(
                        "Cannot verify idle chat “{}”: {error}",
                        chat.title
                    ))
                })?;
            leases.push(
                lease
                    .into_idle_lease()
                    .map_err(ProjectChangeFailure::before_write)?,
            );
        }
        let mut draft = self.baseline.edit();
        let project = draft
            .trust_project(&id, &self.primary, &self.extras)
            .map_err(ProjectChangeFailure::before_write)?;
        let saved = match self.authority.save(&mut draft) {
            Ok(saved) => saved,
            Err(error) => {
                if error == AuthorityError::Unconfirmed {
                    for guard in guards {
                        guard.retain_fence();
                    }
                    return Err(ProjectChangeFailure::after_write(error, true));
                }
                return Err(ProjectChangeFailure::before_write(error));
            }
        };
        // Source saves roots before retirement. From this point, no failure or
        // cancelled waiter may reopen an old configuration's admission.
        for guard in guards {
            guard.retain_fence();
        }
        let binding = self
            .authority
            .confirm_project_binding(&saved, &project)
            .map_err(|error| {
                ProjectChangeFailure::after_write(
                    format!(
                        "Project folders were saved, but authority confirmation failed: {error}"
                    ),
                    error == AuthorityError::Unconfirmed,
                )
            })?;
        // Authority I/O has finished before taking the catalog mutex. Any
        // catalog error is post-authority-save and must retain admission fences.
        {
            let mut catalog = self.workspace.lock().map_err(|_| {
                ProjectChangeFailure::after_write(
                    "Project folders were saved; the workspace is unavailable.",
                    false,
                )
            })?;
            catalog.bind_project_identity(binding).map_err(|error| {
                ProjectChangeFailure::catalog_binding(error, catalog.is_uncertain())
            })?;
        }
        // Set every permanent fence before waiting for any one runtime.
        let mut retirement_error = None;
        for chat in &self.loaded {
            if let Err(error) = chat.controller.retire() {
                retirement_error.get_or_insert(error.to_string());
            }
        }
        for chat in &self.loaded {
            if let Err(error) = chat.controller.retire_and_wait().await {
                retirement_error.get_or_insert(error.to_string());
            }
        }
        if let Some(error) = retirement_error {
            return Err(ProjectChangeFailure::after_write(
                format!("Project folders were saved; runtime restart failed: {error}"),
                false,
            ));
        }
        let mut replacements = Vec::with_capacity(self.loaded.len());
        for (chat, persistent) in self.loaded.into_iter().zip(persistent) {
            // Opening the same path occurs only after every old worker joined.
            let store = if persistent {
                SessionStore::open(&chat.record.snapshot)
            } else {
                SessionStore::pending_with_id(&chat.record.id)
            }
            .map_err(|error| {
                ProjectChangeFailure::after_write(
                    format!("Project folders were saved; chat could not reopen: {error}"),
                    false,
                )
            })?;
            if store.snapshot().id != chat.record.id {
                return Err(ProjectChangeFailure::after_write(
                    "Project folders were saved; reopened chat identity disagrees.",
                    false,
                ));
            }
            // This slice never enables tools, including in synthetic authority QA.
            let controller = Controller::with_configuration(store, chat.controller.configuration())
                .map_err(|error| {
                    ProjectChangeFailure::after_write(
                        format!("Project folders were saved; chat could not reopen: {error}"),
                        false,
                    )
                })?;
            replacements.push(Replacement {
                id: chat.record.id,
                previous: chat.controller,
                controller,
            });
        }
        let confirmed = self.authority.confirm_project(&saved, &project)
            .map_err(|error| ProjectChangeFailure::after_write(format!("Project folders were saved; authority changed during runtime restart: {error}"), error == AuthorityError::Unconfirmed))?;
        drop(leases);
        Ok(ChangedProject {
            loaded: saved,
            project: confirmed,
            replacements,
        })
    }
}

#[cfg(all(test, feature = "synthetic-authority"))]
#[path = "project_host_tests.rs"]
mod tests;
