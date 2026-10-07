//! Explicit, fixture-only project/Controller composition.
//!
//! Source: WorkspaceHosts.swift's saved project, per-chat mode and connection
//! ownership checks, and WorkspaceRefresh.swift's stale connection fence.
//! There is deliberately no production caller, default opt-in, native vault,
//! environment/home discovery or second host registry here. Existing owners
//! still retire and join Controllers before reopening their session writers.
//! Confirmation is point-in-time metadata, not a filesystem sandbox or a lease
//! against another authority writer. Recheck at each asynchronous boundary.
use crate::{
    Controller, Credential, Profile, Result, SessionStore,
    instructions::InstructionOptions,
    invalid,
    project_authority::{
        LoadedProjects, ProjectAuthority, SavedProject, synthetic::SyntheticAuthorityControl,
    },
    runtime::{RuntimeOptions, SyntheticResources, SyntheticRuntimeGuard, TrustedReadOnlyTools},
    tools::Capability,
    workspace::{ChatRecord, ChatToolMode, WorkspaceStore},
};
use std::{
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

/// Explicit fixture inputs. No capability, home or instruction source is
/// inferred. These paths, like the source's roots, are not a filesystem sandbox.
pub struct SyntheticChatOptions {
    pub home: PathBuf,
    pub capabilities: Vec<Capability>,
    pub instructions: Option<InstructionOptions>,
}

struct Generation {
    live: AtomicBool,
}
impl Generation {
    fn check(&self) -> Result<()> {
        if self.live.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(invalid(
                "The synthetic project runtime generation was revoked",
            ))
        }
    }
}

/// One confirmed project revision and its generation. Clones share revocation;
/// confirming a replacement produces a new owner and never revives the old one.
#[derive(Clone)]
pub struct SyntheticProjectRuntime {
    binding: Arc<Binding>,
    generation: Arc<Generation>,
}
struct Binding {
    authority: ProjectAuthority,
    expected: LoadedProjects,
    project: SavedProject,
    workspace: Arc<Mutex<WorkspaceStore>>,
}
impl SyntheticProjectRuntime {
    /// Require an already-bound catalog and freshly confirmed saved authority.
    /// This never creates/retrusts a project or adopts an unbound legacy root.
    pub fn confirm(
        control: &SyntheticAuthorityControl,
        workspace: Arc<Mutex<WorkspaceStore>>,
    ) -> Result<Self> {
        let (project_id, primary) = {
            let store = workspace
                .lock()
                .map_err(|_| invalid("Workspace is unavailable"))?;
            if store.is_uncertain() {
                return Err(invalid("Workspace identity has an unconfirmed save"));
            }
            let state = store.snapshot();
            (
                state
                    .project_id
                    .ok_or_else(|| invalid("A confirmed saved project binding is required"))?,
                state.project,
            )
        };
        let authority = control.authority();
        let expected = authority
            .load()
            .map_err(|error| invalid(error.to_string()))?;
        let project = expected
            .projects()
            .iter()
            .find(|project| project.id == project_id && project.path == primary)
            .ok_or_else(|| invalid("The saved project ID and original root disagree"))?
            .clone();
        authority
            .confirm_project_binding(&expected, &project)
            .map_err(|error| invalid(error.to_string()))?;
        let runtime = Self {
            binding: Arc::new(Binding {
                authority,
                expected,
                project,
                workspace,
            }),
            generation: Arc::new(Generation {
                live: AtomicBool::new(true),
            }),
        };
        runtime.binding.check_catalog(None)?;
        Ok(runtime)
    }

    pub fn project_id(&self) -> &str {
        &self.binding.project.id
    }
    pub fn authority_revision(&self) -> i64 {
        self.binding.expected.revision()
    }

    /// Fence stale controller Arcs immediately. The owner must still call
    /// retire_and_wait on each Controller to join entered work/release writers.
    pub fn revoke(&self) {
        self.generation.live.store(false, Ordering::Release);
    }

    /// Open exactly the registered saved chat. This does not replay work; a
    /// caller must explicitly submit, Retry or Resume, as with normal Controllers.
    /// SessionStore ownership rejects overlapping opens. Reopen follows the
    /// existing retire_and_wait path, without a separate startup registry.
    pub fn open_chat(
        &self,
        chat_id: &str,
        profile: Profile,
        options: SyntheticChatOptions,
    ) -> Result<Arc<Controller>> {
        self.generation.check()?;
        profile.validate()?;
        let endpoint = profile.endpoint()?;
        if !matches!(endpoint.host(), Some(url::Host::Ipv4(ip)) if ip.is_loopback())
            && !matches!(endpoint.host(), Some(url::Host::Ipv6(ip)) if ip.is_loopback())
        {
            return Err(invalid(
                "Synthetic project requests require a numeric loopback endpoint",
            ));
        }
        if !profile.headers.is_empty() {
            return Err(invalid(
                "Synthetic project requests do not accept custom credentials or headers",
            ));
        }
        if !options.home.is_absolute() || !options.home.is_dir() {
            return Err(invalid("An explicit fixture home directory is required"));
        }
        let home = std::fs::canonicalize(&options.home)?;
        if options.capabilities.is_empty() {
            return Err(invalid(
                "An explicit read-only capability selection is required",
            ));
        }
        let roots: Vec<_> = self.binding.project.roots().map(PathBuf::from).collect();
        if options
            .instructions
            .as_ref()
            .is_some_and(|options| options.roots != roots)
        {
            return Err(invalid(
                "Instruction roots must exactly match the confirmed project roots",
            ));
        }
        let record = self
            .binding
            .check_catalog(Some(chat_id))?
            .ok_or_else(|| invalid("The chat is no longer registered"))?;
        let guard = Arc::new(ChatGuard {
            binding: self.binding.clone(),
            generation: self.generation.clone(),
            record,
            valid: AtomicBool::new(true),
        });
        guard.confirm()?;
        let tools = TrustedReadOnlyTools::new_with_capabilities(
            self.binding.project.path.clone(),
            self.binding.project.paths.clone(),
            home,
            options.capabilities,
        )?;
        // Check identity under the writer lock before any migration/recovery.
        // Missing saved checkpoints and locks must never be created here.
        let store = SessionStore::open_existing_with_id(&guard.record.snapshot, &guard.record.id)?;
        guard.confirm()?;
        Controller::new_with_synthetic_resources(
            store,
            Some((
                profile,
                Credential::new("synthetic-project-fixture-only".into())?,
            )),
            RuntimeOptions {
                instructions: String::new(),
                tools: Some(tools),
            },
            SyntheticResources::new(options.instructions, guard),
        )
    }
}

impl Binding {
    /// No authority operations occur while the catalog mutex is held.
    fn check_catalog(&self, chat_id: Option<&str>) -> Result<Option<ChatRecord>> {
        let store = self
            .workspace
            .lock()
            .map_err(|_| invalid("Workspace is unavailable"))?;
        if store.is_uncertain() {
            return Err(invalid("Workspace identity has an unconfirmed save"));
        }
        let state = store.snapshot();
        if state.project_id.as_deref() != Some(self.project.id.as_str())
            || state.project != self.project.path
        {
            return Err(invalid("The bound project identity changed"));
        }
        let Some(chat_id) = chat_id else {
            return Ok(None);
        };
        let record = state
            .chats
            .into_iter()
            .find(|record| record.id == chat_id)
            .ok_or_else(|| invalid("The chat is no longer registered"))?;
        if record.tool_mode != ChatToolMode::ReadOnly || record.archived_at.is_some() {
            return Err(invalid(
                "Synthetic tools require an active explicitly read-only chat",
            ));
        }
        Ok(Some(record))
    }
}

struct ChatGuard {
    binding: Arc<Binding>,
    generation: Arc<Generation>,
    record: ChatRecord,
    valid: AtomicBool,
}
impl SyntheticRuntimeGuard for ChatGuard {
    /// The actor-safe half is only an atomic generation/failure witness.
    fn check(&self) -> Result<()> {
        self.generation.check()?;
        if self.valid.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(invalid(
                "The synthetic chat runtime authority is no longer current",
            ))
        }
    }

    /// Full point-in-time confirmation must be called outside actor/catalog
    /// locks. Failure is sticky for this Controller, even if trust later returns.
    fn confirm(&self) -> Result<()> {
        let result = (|| {
            self.check()?;
            self.binding
                .authority
                .confirm_project_binding(&self.binding.expected, &self.binding.project)
                .map_err(|error| invalid(error.to_string()))?;
            let current = self
                .binding
                .check_catalog(Some(&self.record.id))?
                .ok_or_else(|| invalid("The chat is no longer registered"))?;
            if current.snapshot != self.record.snapshot
                || current.tool_mode != self.record.tool_mode
            {
                return Err(invalid("The saved chat runtime binding changed"));
            }
            self.check()
        })();
        if result.is_err() {
            self.valid.store(false, Ordering::Release);
        }
        result
    }
}

#[cfg(test)]
#[path = "synthetic_project_runtime_tests.rs"]
mod tests;
