//! One app composition boundary for saved authority and explicit legacy CLI chats.
//! A saved ID never borrows the launch route, even when its vault is unavailable.
use bello_agent_core::{
    Controller, Error, Result, SessionStore,
    project_authority::ProjectAuthority,
    runtime::Configuration,
    saved_runtime::{SavedChatOptions, SavedRuntimeFactory},
    workspace::{ChatMaterialization, ChatRecord, ChatToolMode, WorkspaceStore},
};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
};

#[derive(Clone)]
pub(crate) struct AppRuntime {
    saved: SavedRuntimeFactory,
    workspace: Arc<Mutex<WorkspaceStore>>,
    legacy: Option<Arc<Configuration>>,
}
impl AppRuntime {
    pub fn new(
        authority: ProjectAuthority,
        workspace: Arc<Mutex<WorkspaceStore>>,
        options: SavedChatOptions,
        legacy: Option<Arc<Configuration>>,
    ) -> Self {
        Self {
            saved: SavedRuntimeFactory::new(authority, workspace.clone(), options),
            workspace,
            legacy,
        }
    }
    pub fn options(home: PathBuf, fixture: bool) -> SavedChatOptions {
        // Only the explicit fake-vault launch opts in. Native production startup
        // remains disabled until the separate signing/Keychain acceptance gate.
        let read_only_capabilities = if fixture {
            #[cfg(target_os = "macos")]
            {
                vec![
                    bello_agent_core::tools::Capability::Read,
                    bello_agent_core::tools::Capability::Ls,
                    bello_agent_core::tools::Capability::Find,
                    bello_agent_core::tools::Capability::Grep,
                ]
            }
            #[cfg(not(target_os = "macos"))]
            {
                vec![bello_agent_core::tools::Capability::Ls]
            }
        } else {
            vec![]
        };
        let editing_capabilities = read_only_capabilities.clone();
        #[cfg(target_os = "macos")]
        let editing_capabilities = if fixture {
            let mut capabilities = editing_capabilities;
            capabilities.extend([
                bello_agent_core::tools::Capability::Write,
                bello_agent_core::tools::Capability::Edit,
            ]);
            capabilities
        } else {
            editing_capabilities
        };
        SavedChatOptions {
            home,
            read_only_capabilities,
            editing_capabilities,
            instructions: String::new(),
        }
    }
    pub fn mcp_manager(&self) -> Result<Arc<bello_agent_core::mcp::McpManager>> {
        self.saved.mcp_manager()
    }
    pub fn preflight(&self, id: &str) -> Result<()> {
        self.saved.preflight(id)
    }
    pub fn new_chat(
        &self,
        connection: Option<&str>,
        mode: ChatToolMode,
    ) -> Result<(ChatRecord, Arc<Controller>)> {
        if let Some(id) = connection {
            return self.saved.new_chat(id, mode);
        }
        let store = SessionStore::pending();
        let snapshot = store.snapshot();
        let path = self
            .workspace
            .lock()
            .map_err(|_| unavailable())?
            .chat_path(&snapshot.id)?;
        let mut record = ChatRecord::new(snapshot.id, snapshot.title, path);
        record.materialization = ChatMaterialization::Pending;
        record.tool_mode = mode;
        Ok((
            record,
            Controller::with_configuration(store, self.legacy.clone())?,
        ))
    }
    /// A loader can never dispatch while the authoritative open is outstanding.
    pub fn placeholder(record: &ChatRecord) -> Result<Arc<Controller>> {
        Controller::new(SessionStore::pending_with_id(&record.id)?, None)
    }
    fn registered(&self, record: &ChatRecord) -> Result<ChatRecord> {
        let catalog = self.workspace.lock().map_err(|_| unavailable())?;
        if catalog.is_uncertain() {
            return Err(Error::PersistenceUncertain(
                "The workspace save is unconfirmed".into(),
            ));
        }
        catalog
            .snapshot()
            .chats
            .into_iter()
            .find(|current| {
                current.id == record.id
                    && current.snapshot == record.snapshot
                    && current.connection_id == record.connection_id
                    && current.tool_mode == record.tool_mode
            })
            .ok_or_else(|| {
                Error::Invalid("The saved chat identity, connection or mode changed".into())
            })
    }
    fn store(record: &ChatRecord) -> Result<SessionStore> {
        match record.materialization {
            ChatMaterialization::CheckpointRequired => {
                SessionStore::open_existing_with_id(&record.snapshot, &record.id)
            }
            ChatMaterialization::Pending => {
                // Explicit provenance allows an empty actor; absent files do not.
                match std::fs::symlink_metadata(&record.snapshot) {
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                        SessionStore::pending_with_id(&record.id)
                    }
                    Ok(_) => Err(Error::Invalid(
                        "A pending chat unexpectedly has a checkpoint; review its saved state"
                            .into(),
                    )),
                    Err(error) => Err(error.into()),
                }
            }
        }
    }
    pub fn open_registered(&self, record: &ChatRecord) -> Result<Arc<Controller>> {
        let record = self.registered(record)?;
        if record.connection_id.is_some() {
            return self.saved.open_registered(&record);
        }
        Controller::with_configuration(Self::store(&record)?, self.legacy.clone())
    }
    pub fn reopen(
        &self,
        record: &ChatRecord,
        previous: &Arc<Controller>,
    ) -> Result<Arc<Controller>> {
        if !previous.is_retired() || previous.snapshot_shared().id != record.id {
            return Err(Error::Invalid(
                "The previous chat runtime must retire before reopening".into(),
            ));
        }
        if record.connection_id.is_some() {
            return self.saved.reopen(record, previous);
        }
        let catalog = self.workspace.lock().map_err(|_| unavailable())?;
        let registered = catalog.snapshot().chats.iter().any(|r| r.id == record.id);
        drop(catalog);
        if registered {
            return self.open_registered(record);
        }
        if !previous.is_never_materialized()
            || record.materialization != ChatMaterialization::Pending
        {
            return Err(Error::Invalid(
                "An unregistered chat cannot reopen saved history".into(),
            ));
        }
        Controller::with_configuration(Self::store(record)?, self.legacy.clone())
    }
    /// Missing credentials may leave existing history inspectable. This actor
    /// has no provider configuration and cannot send, Retry, Resume or run tools.
    pub fn disconnected(
        &self,
        record: &ChatRecord,
        previous: Option<&Arc<Controller>>,
    ) -> Result<Arc<Controller>> {
        let registered = self
            .workspace
            .lock()
            .map_err(|_| unavailable())?
            .snapshot()
            .chats
            .iter()
            .any(|r| r.id == record.id);
        let record = if registered {
            self.registered(record)?
        } else {
            let previous =
                previous.ok_or_else(|| Error::Invalid("The chat is not registered".into()))?;
            if !previous.is_retired()
                || !previous.is_never_materialized()
                || previous.snapshot_shared().id != record.id
                || record.materialization != ChatMaterialization::Pending
            {
                return Err(Error::Invalid(
                    "The pending chat runtime identity changed".into(),
                ));
            }
            record.clone()
        };
        Controller::new(Self::store(&record)?, None)
    }
}
fn unavailable() -> Error {
    Error::Invalid("The workspace is unavailable".into())
}

/// Presentation derives from the actual, currently admitted factory capability
/// set. Saved IDs or profile metadata alone never imply available tools.
pub(crate) fn tool_runtime_label(controller: &Controller, fixture: bool) -> &'static str {
    if fixture && controller.has_available_tool_definitions() {
        "Fixture tool runtime"
    } else {
        "Tools unavailable"
    }
}

#[cfg(test)]
mod presentation_tests {
    #[::core::prelude::v1::test]
    fn default_and_inert_fixture_have_no_tool_runtime_badge() {
        let controller =
            bello_agent_core::Controller::new(bello_agent_core::SessionStore::pending(), None)
                .unwrap();
        assert_eq!(
            super::tool_runtime_label(&controller, false),
            "Tools unavailable"
        );
        assert_eq!(
            super::tool_runtime_label(&controller, true),
            "Tools unavailable"
        );
    }
}
