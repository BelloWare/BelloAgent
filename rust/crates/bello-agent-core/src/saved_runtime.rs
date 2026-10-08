//! Shared saved-settings → trusted-project → chat composition. No constructor
//! discovers credentials, home paths or native storage. Fixture provenance uses
//! this same factory with enforced fake credentials and loopback transport.
use crate::{
    Controller, Result, SessionStore, invalid,
    project_authority::{ProjectAuthority, SavedProject, connections::SavedConnectionRuntime},
    runtime::{Configuration, RuntimeAuthorityGuard, RuntimeOptions, TrustedReadOnlyTools},
    tools::Capability,
    workspace::{ChatMaterialization, ChatRecord, ChatToolMode, WorkspaceStore},
};
use std::{
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};
#[derive(Clone)]
pub struct SavedChatOptions {
    pub home: PathBuf,
    pub read_only_capabilities: Vec<Capability>,
    pub editing_capabilities: Vec<Capability>,
    pub instructions: String,
}
/// Owns no session writer and sends nothing. Opens obtain fresh authority;
/// clones share the project MCP manager, not a second registry.
#[derive(Clone)]
pub struct SavedRuntimeFactory {
    authority: ProjectAuthority,
    workspace: Arc<Mutex<WorkspaceStore>>,
    options: SavedChatOptions,
    connection_only: bool,
    #[cfg(all(test, unix))]
    shell_environment: Option<crate::tools::bash::Environment>,
    #[cfg(test)]
    confirmations: Arc<std::sync::atomic::AtomicUsize>,
    #[cfg(all(test, feature = "synthetic-authority", not(target_os = "macos")))]
    synthetic_mutations: bool,
}
impl SavedRuntimeFactory {
    /// Synthetic-only mixed-tool acceptance uses the same saved runtime route.
    #[cfg(all(test, feature = "synthetic-authority", unix))]
    pub(crate) fn with_mixed_mcp_test_tools(mut self) -> Self {
        self.options.editing_capabilities =
            vec![Capability::Ls, Capability::Write, Capability::Bash];
        self.shell_environment = Some(crate::tools::bash::Environment {
            home: self.options.home.clone(),
            path: "/usr/bin:/bin".into(),
            lang: "C".into(),
            temporary: self.options.home.clone(),
        });
        #[cfg(not(target_os = "macos"))]
        {
            self.synthetic_mutations = true;
        }
        self
    }

    pub fn new(
        authority: ProjectAuthority,
        workspace: Arc<Mutex<WorkspaceStore>>,
        options: SavedChatOptions,
    ) -> Self {
        Self {
            authority,
            workspace,
            options,
            connection_only: false,
            #[cfg(all(test, unix))]
            shell_environment: None,
            #[cfg(test)]
            confirmations: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            #[cfg(all(test, feature = "synthetic-authority", not(target_os = "macos")))]
            synthetic_mutations: false,
        }
    }
    /// Saved provider chat with the same project/catalog admission, but no
    /// builtin tools, MCP manager, project instructions or skill discovery.
    /// This is explicit host policy, never inferred from saved metadata.
    pub fn connection_only(
        authority: ProjectAuthority,
        workspace: Arc<Mutex<WorkspaceStore>>,
    ) -> Self {
        let mut factory = Self::new(
            authority,
            workspace,
            SavedChatOptions {
                home: PathBuf::new(),
                read_only_capabilities: Vec::new(),
                editing_capabilities: Vec::new(),
                instructions: String::new(),
            },
        );
        factory.connection_only = true;
        factory
    }
    /// The workspace owner holds exactly one manager for its current saved
    /// project. Multiple factory instances/clones and chats reuse that manager.
    pub fn mcp_manager(&self) -> Result<Arc<crate::mcp::McpManager>> {
        if self.connection_only {
            return Err(invalid(
                "MCP tools are unavailable for connection-only chats",
            ));
        }
        let binding = ProjectBinding::confirm(self.authority.clone(), self.workspace.clone())?;
        self.project_mcp(&binding)
    }
    fn project_mcp(&self, binding: &ProjectBinding) -> Result<Arc<crate::mcp::McpManager>> {
        // Serialize construction outside the catalog mutex: opening the stable
        // outcome-file lease must not race another factory for this workspace.
        let creation = self
            .workspace
            .lock()
            .map_err(|_| invalid("Workspace is unavailable"))?
            .mcp_creation_gate
            .clone();
        let _creation = creation
            .lock()
            .map_err(|_| invalid("MCP manager construction is unavailable"))?;
        let loaded = self
            .authority
            .load_mcp(&binding.project)
            .map_err(|e| invalid(e.to_string()))?;
        let (directory, previous) = {
            let catalog = self
                .workspace
                .lock()
                .map_err(|_| invalid("Workspace is unavailable"))?;
            if let Some(manager) = &catalog.mcp_manager
                && manager.matches_project(&binding.project)
            {
                if !manager.matches_authority(&loaded) {
                    return Err(invalid("MCP workspace authority changed"));
                }
                return Ok(manager.clone());
            }
            (catalog.state_directory(), catalog.mcp_manager.clone())
        };
        let manager = match previous {
            Some(previous) if previous.project_id() == binding.project.id => {
                previous.rebind(loaded.clone())?
            }
            _ => crate::mcp::McpManager::new(loaded.clone(), &directory)?,
        };
        let mut catalog = self
            .workspace
            .lock()
            .map_err(|_| invalid("Workspace is unavailable"))?;
        let state = catalog.snapshot();
        if catalog.is_uncertain()
            || state.project_id.as_deref() != Some(binding.project.id.as_str())
            || state.project != binding.project.path
        {
            return Err(invalid(
                "MCP workspace identity changed during construction",
            ));
        }
        if let Some(existing) = &catalog.mcp_manager
            && existing.matches_project(&binding.project)
        {
            if !existing.matches_authority(&loaded) {
                return Err(invalid("MCP workspace authority changed"));
            }
            return Ok(existing.clone());
        }
        catalog.mcp_manager = Some(manager.clone());
        Ok(manager)
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub(crate) fn options_for_mcp_test(&self) -> SavedChatOptions {
        self.options.clone()
    }
    pub fn configuration_for(&self, id: &str) -> Result<Arc<Configuration>> {
        let loaded = self
            .authority
            .load_connections()
            .map_err(|e| invalid(e.to_string()))?;
        SavedConnectionRuntime::confirm(&self.authority, &loaded, id)
            .map(|runtime| runtime.configuration())
    }
    /// Read-only preflight before a host fences an old actor. Full confirmation
    /// still runs after retirement and durable selection; this opens no writer.
    pub fn preflight(&self, connection_id: &str) -> Result<()> {
        let binding = ProjectBinding::confirm(self.authority.clone(), self.workspace.clone())?;
        self.configuration_for(connection_id)?;
        binding.confirm_current()
    }
    pub fn new_chat(
        &self,
        connection_id: &str,
        mode: ChatToolMode,
    ) -> Result<(ChatRecord, Arc<Controller>)> {
        let id = uuid::Uuid::new_v4().to_string();
        let path = self
            .workspace
            .lock()
            .map_err(|_| invalid("Workspace is unavailable"))?
            .chat_path(&id)?;
        let mut record = ChatRecord::new(id, "New chat".into(), path);
        record.materialization = ChatMaterialization::Pending;
        record.connection_id = Some(connection_id.into());
        record.tool_mode = mode;
        let controller = self.open(&record, true)?;
        Ok((record, controller))
    }
    pub fn open_registered(&self, record: &ChatRecord) -> Result<Arc<Controller>> {
        self.open(record, false)
    }
    /// Never borrows the previous writer. Only a joined nonpersistent pending
    /// identity can replace an unregistered placeholder under a managed path.
    pub fn reopen(
        &self,
        record: &ChatRecord,
        previous: &Arc<Controller>,
    ) -> Result<Arc<Controller>> {
        if !previous.is_retired() || previous.snapshot_shared().id != record.id {
            return Err(invalid(
                "Retire and join the previous chat before reopening",
            ));
        }
        let registered = self
            .workspace
            .lock()
            .map_err(|_| invalid("Workspace is unavailable"))?
            .snapshot()
            .chats
            .iter()
            .any(|chat| chat.id == record.id);
        if registered {
            return self.open_registered(record);
        }
        if !previous.is_never_materialized()
            || record.materialization != ChatMaterialization::Pending
        {
            return Err(invalid(
                "An unregistered persistent chat cannot be recreated",
            ));
        }
        self.open(record, true)
    }
    fn open(&self, record: &ChatRecord, pending_origin: bool) -> Result<Arc<Controller>> {
        let connection_id = record
            .connection_id
            .as_deref()
            .ok_or_else(|| invalid("Choose an explicit saved connection"))?;
        let binding = ProjectBinding::confirm(self.authority.clone(), self.workspace.clone())?;
        let guard = Arc::new(ChatAuthority {
            binding,
            record: record.clone(),
            permit_unregistered: pending_origin,
            registered: AtomicBool::new(false),
            valid: AtomicBool::new(true),
            #[cfg(test)]
            confirmations: self.confirmations.clone(),
        });
        guard.confirm()?;
        guard.confirm_open_provenance()?;
        let configuration = self.configuration_for(connection_id)?;
        let project = &guard.binding.project;
        let tools = if self.connection_only {
            None
        } else {
            let capabilities = match record.tool_mode {
                ChatToolMode::ReadOnly => self.options.read_only_capabilities.clone(),
                ChatToolMode::Editing => self.options.editing_capabilities.clone(),
            };
            if !self.options.home.is_absolute() || !self.options.home.is_dir() {
                return Err(invalid(
                    "An explicit existing tool home directory is required",
                ));
            }
            if capabilities.is_empty() {
                return Err(invalid("An explicit capability selection is required"));
            }
            let home = std::fs::canonicalize(&self.options.home)?;
            let tools = match record.tool_mode {
                ChatToolMode::ReadOnly => TrustedReadOnlyTools::new_with_capabilities(
                    project.path.clone(),
                    project.paths.clone(),
                    home,
                    capabilities,
                )?,
                ChatToolMode::Editing => {
                    #[cfg(all(test, feature = "synthetic-authority", not(target_os = "macos")))]
                    if self.synthetic_mutations {
                        TrustedReadOnlyTools::synthetic_mutation_fixture(
                            project.path.clone(),
                            project.paths.clone(),
                            home,
                            capabilities,
                        )?
                    } else {
                        TrustedReadOnlyTools::new_with_editing_capabilities(
                            project.path.clone(),
                            project.paths.clone(),
                            home,
                            capabilities,
                        )?
                    }
                    #[cfg(not(all(
                        test,
                        feature = "synthetic-authority",
                        not(target_os = "macos")
                    )))]
                    TrustedReadOnlyTools::new_with_editing_capabilities(
                        project.path.clone(),
                        project.paths.clone(),
                        home,
                        capabilities,
                    )?
                }
            };
            #[cfg(all(test, unix))]
            let tools = if let Some(environment) = &self.shell_environment {
                tools.with_shell_environment(environment.clone())
            } else {
                tools
            };
            let tools = tools.with_mcp(
                self.project_mcp(&guard.binding)?,
                record.tool_mode == ChatToolMode::ReadOnly,
            );
            Some(tools)
        };
        // Permission errors/symlinks/FIFOs are not absence. Existing-only opening
        // checks identity under its existing writer lock before recovery writes.
        let store = match std::fs::symlink_metadata(&record.snapshot) {
            Err(error)
                if error.kind() == std::io::ErrorKind::NotFound
                    && record.materialization == ChatMaterialization::Pending =>
            {
                SessionStore::pending_with_id(&record.id)?
            }
            Ok(_) if record.materialization == ChatMaterialization::Pending => {
                return Err(invalid(
                    "A pending chat has an unexpected checkpoint; inspect it before continuing",
                ));
            }
            _ => SessionStore::open_existing_with_id(&record.snapshot, &record.id)?,
        };
        guard.confirm()?;
        guard.confirm_open_provenance()?;
        let binding = crate::runtime::project_input_runtime::ProjectRuntimeBinding {
            project_id: project.id.clone(),
            roots: std::iter::once(project.path.clone())
                .chain(project.paths.clone())
                .collect(),
            chat_id: record.id.clone(),
            controller_id: uuid::Uuid::new_v4().to_string(),
            tool_mode: match record.tool_mode {
                ChatToolMode::Editing => "editing",
                ChatToolMode::ReadOnly => "read-only",
            }
            .into(),
        };
        let controller = Controller::with_authority(
            store,
            Some(configuration),
            RuntimeOptions {
                instructions: self.options.instructions.clone(),
                tools,
            },
            Some(guard),
        )?;
        if self.connection_only {
            Ok(controller)
        } else {
            Ok(controller.with_project_resources(binding))
        }
    }
}
/// The complete original project identity remains equal. Unrelated envelope
/// edits may advance, but unknown future authority/policy fields are refused.
pub(crate) struct ProjectBinding {
    pub(crate) authority: ProjectAuthority,
    pub(crate) workspace: Arc<Mutex<WorkspaceStore>>,
    pub(crate) project: SavedProject,
}
impl ProjectBinding {
    pub(crate) fn confirm(
        authority: ProjectAuthority,
        workspace: Arc<Mutex<WorkspaceStore>>,
    ) -> Result<Arc<Self>> {
        let state = {
            let catalog = workspace
                .lock()
                .map_err(|_| invalid("Workspace is unavailable"))?;
            if catalog.is_uncertain() {
                return Err(invalid("Workspace identity has an unconfirmed save"));
            }
            catalog.snapshot()
        };
        let id = state
            .project_id
            .ok_or_else(|| invalid("Trust and bind this saved project before opening its chat"))?;
        let saved = authority.load().map_err(|e| invalid(e.to_string()))?;
        let project = saved
            .projects()
            .iter()
            .find(|p| p.id == id && p.path == state.project)
            .ok_or_else(|| invalid("The saved project identity and original root disagree"))?
            .clone();
        authority
            .confirm_current_project_binding(&project)
            .map_err(|e| invalid(e.to_string()))?;
        Ok(Arc::new(Self {
            authority,
            workspace,
            project,
        }))
    }
    pub(crate) fn confirm_current(&self) -> Result<()> {
        self.authority
            .confirm_current_project_binding(&self.project)
            .map_err(|e| invalid(e.to_string()))?;
        Ok(())
    }
}
struct ChatAuthority {
    binding: Arc<ProjectBinding>,
    record: ChatRecord,
    permit_unregistered: bool,
    registered: AtomicBool,
    valid: AtomicBool,
    #[cfg(test)]
    confirmations: Arc<std::sync::atomic::AtomicUsize>,
}
impl ChatAuthority {
    fn confirm_open_provenance(&self) -> Result<()> {
        let catalog = self
            .binding
            .workspace
            .lock()
            .map_err(|_| invalid("Workspace is unavailable"))?;
        if catalog
            .snapshot()
            .chats
            .iter()
            .find(|chat| chat.id == self.record.id)
            .is_some_and(|chat| chat.materialization != self.record.materialization)
        {
            return Err(invalid(
                "The chat checkpoint requirement changed while opening",
            ));
        }
        Ok(())
    }
    fn catalog(&self, materializing: bool) -> Result<()> {
        let catalog = self
            .binding
            .workspace
            .lock()
            .map_err(|_| invalid("Workspace is unavailable"))?;
        if catalog.is_uncertain() {
            return Err(invalid("Workspace identity has an unconfirmed save"));
        }
        let state = catalog.snapshot();
        if state.project_id.as_deref() != Some(self.binding.project.id.as_str())
            || state.project != self.binding.project.path
        {
            return Err(invalid("The bound project identity changed"));
        }
        if let Some(current) = state.chats.iter().find(|chat| chat.id == self.record.id) {
            if current.snapshot != self.record.snapshot
                || current.connection_id != self.record.connection_id
                || current.tool_mode != self.record.tool_mode
                || current.archived_at.is_some()
            {
                return Err(invalid("The saved chat runtime binding changed"));
            }
            self.registered.store(true, Ordering::Release);
            if materializing
                && (current.materialization != ChatMaterialization::CheckpointRequired
                    || !state
                        .intents
                        .values()
                        .any(|intent| intent.chat_id == current.id))
            {
                return Err(invalid(
                    "Save the first submission receipt before creating this checkpoint",
                ));
            }
        } else if materializing
            || self.registered.load(Ordering::Acquire)
            || !self.permit_unregistered
            || self.record.materialization != ChatMaterialization::Pending
            || catalog.chat_path(&self.record.id)? != self.record.snapshot
        {
            return Err(invalid(
                "The chat is no longer registered with its original pending identity",
            ));
        }
        Ok(())
    }
}
impl RuntimeAuthorityGuard for ChatAuthority {
    fn check(&self) -> Result<()> {
        if self.valid.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(invalid(
                "This chat's saved runtime authority was revoked; reopen it explicitly",
            ))
        }
    }
    fn confirm(&self) -> Result<()> {
        let result = (|| {
            self.check()?;
            self.binding.confirm_current()?;
            let connections = self
                .binding
                .authority
                .load_connections()
                .map_err(|e| invalid(e.to_string()))?;
            if !connections.profiles().iter().any(|connection| {
                connection.available
                    && Some(connection.profile.id.as_str()) == self.record.connection_id.as_deref()
            }) {
                return Err(invalid(
                    "This chat's saved connection was deleted or is unavailable",
                ));
            }
            self.catalog(false)?;
            self.check()
        })();
        if result.is_err() {
            self.valid.store(false, Ordering::Release);
        }
        #[cfg(test)]
        if result.is_ok() {
            self.confirmations.fetch_add(1, Ordering::SeqCst);
        }
        result
    }
    fn confirm_materialization(&self, path: &Path) -> Result<()> {
        self.confirm()?;
        if path != self.record.snapshot {
            return Err(invalid("Pending chat checkpoint path changed"));
        }
        self.catalog(true)
    }
}
#[cfg(all(test, feature = "synthetic-authority"))]
#[path = "saved_runtime_tests.rs"]
mod tests;
