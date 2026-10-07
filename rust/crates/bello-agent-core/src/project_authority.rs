//! Portable contracts for the isolated Rust project-authority vault.
//!
//! Source: ConfigurationVault.swift, KeychainVaultStorage.swift, WorkspaceRecord
//! and WorkspaceFolders.swift. The default constructor remains unavailable.
//! The nondefault `native-authority` feature exposes a separate explicit macOS
//! composition boundary; it never accesses the source vault or a fallback.
//! Unit tests and the explicit, nondefault `synthetic-authority` QA feature may
//! inject in-memory storage. Values describe saved configuration, not an execution
//! grant; the host still owns lifecycle and admission fencing.
use serde::{
    Deserialize, Serialize,
    de::{self, MapAccess, Visitor},
};
use serde_json::value::RawValue;
use std::{
    collections::{BTreeMap, HashSet},
    fmt, fs,
    path::{Path, PathBuf},
    sync::Arc,
};

const MAX_BYTES: usize = 2_097_152;
const MAX_PROJECTS: usize = 1000;

#[path = "connection_vault.rs"]
pub mod connections;

#[cfg(feature = "native-authority")]
mod native;

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum AuthorityError {
    #[error("Native project authority is unavailable until its signing identity is configured.")]
    Unavailable,
    #[error("Project authority requires the approved signed Bello Agent Rust application.")]
    Unsigned,
    #[error("The project authority configuration lock could not be opened.")]
    LockUnavailable,
    #[error("The native project authority store is locked or denied.")]
    Denied,
    #[error("Another operation is updating project authority.")]
    Busy,
    #[error(
        "Project authority has an unsupported or corrupt envelope; saved bytes were not replaced."
    )]
    Corrupt,
    #[error("Project authority changed. Reload and review before saving.")]
    Conflict,
    #[error("Project roots or identifiers are invalid.")]
    InvalidProject,
    #[error(
        "The connection is invalid or unsupported. Use an explicit supported Responses connection."
    )]
    InvalidConnection,
    #[error("This saved connection is unavailable for new requests.")]
    UnsupportedConnection,
    #[error("The project is not currently saved and trusted.")]
    Untrusted,
    #[error("The saved project contains unsupported authority fields.")]
    UnsupportedProject,
    #[error(
        "The native write was not confirmed. Your draft remains available; do not assume it was saved."
    )]
    Unconfirmed,
}
pub type AuthorityResult<T> = Result<T, AuthorityError>;

// No Debug implementation: opaque future fields may contain sensitive data.
#[derive(Clone, Serialize)]
struct Fields(BTreeMap<String, Box<RawValue>>);
impl<'de> Deserialize<'de> for Fields {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Object;
        impl<'de> Visitor<'de> for Object {
            type Value = Fields;
            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("an object with unique fields")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Fields, A::Error> {
                let mut fields = BTreeMap::new();
                while let Some((key, value)) = map.next_entry::<String, Box<RawValue>>()? {
                    if fields.insert(key, value).is_some() {
                        return Err(de::Error::custom("duplicate envelope field"));
                    }
                }
                Ok(Fields(fields))
            }
        }
        deserializer.deserialize_map(Object)
    }
}
fn raw(value: &impl Serialize) -> AuthorityResult<Box<RawValue>> {
    serde_json::value::to_raw_value(value).map_err(|_| AuthorityError::Corrupt)
}
fn parse<T: for<'de> Deserialize<'de>>(value: &RawValue) -> AuthorityResult<T> {
    serde_json::from_str(value.get()).map_err(|_| AuthorityError::Corrupt)
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedProject {
    pub id: String,
    pub path: PathBuf,
    pub trusted: bool,
    #[serde(default, deserialize_with = "nullable_paths")]
    pub paths: Vec<PathBuf>,
}
fn nullable_paths<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Vec<PathBuf>, D::Error> {
    Ok(Option::<Vec<PathBuf>>::deserialize(deserializer)?.unwrap_or_default())
}
impl SavedProject {
    pub fn roots(&self) -> impl Iterator<Item = &Path> {
        std::iter::once(self.path.as_path()).chain(self.paths.iter().map(PathBuf::as_path))
    }
    fn validate(&self) -> AuthorityResult<()> {
        if uuid::Uuid::parse_str(&self.id).is_err() || self.paths.len() >= 16 {
            return Err(AuthorityError::InvalidProject);
        }
        let mut seen = HashSet::new();
        for path in self.roots() {
            let Some(text) = path.to_str() else {
                return Err(AuthorityError::InvalidProject);
            };
            if !path.is_absolute() || text.len() > 4096 || text.contains('\0') || !seen.insert(path)
            {
                return Err(AuthorityError::InvalidProject);
            }
        }
        Ok(())
    }
}

/// Freshly confirmed metadata for binding a Rust catalog to a saved project.
/// This is point-in-time evidence, not an execution grant or a security lease.
/// Mint it outside the catalog mutex; admission must still revalidate authority
/// after asynchronous boundaries. It deliberately cannot be constructed or
/// cloned by callers, and binding it never changes the saved project or roots.
pub struct ConfirmedProjectBinding {
    project: SavedProject,
}
impl ConfirmedProjectBinding {
    pub fn project_id(&self) -> &str {
        &self.project.id
    }
    pub fn project_path(&self) -> &Path {
        &self.project.path
    }
}

/// A loaded, immutable point-in-time view. No opaque envelope bytes are exposed
/// or formatted. A caller must revalidate before authority-dependent admission.
#[derive(Clone)]
pub struct LoadedProjects {
    previous: Option<Vec<u8>>,
    fields: Fields,
    entries: Vec<Fields>,
    projects: Vec<SavedProject>,
    revision: i64,
}
impl LoadedProjects {
    fn decode(bytes: Option<Vec<u8>>) -> AuthorityResult<Self> {
        if bytes.as_ref().is_some_and(|bytes| bytes.len() > MAX_BYTES) {
            return Err(AuthorityError::Corrupt);
        }
        let fields: Fields = serde_json::from_slice(
            bytes
                .as_deref()
                .unwrap_or(b"{\"schema\":1,\"revision\":0,\"workspaces\":[]}"),
        )
        .map_err(|_| AuthorityError::Corrupt)?;
        let schema: i64 = parse(fields.0.get("schema").ok_or(AuthorityError::Corrupt)?)?;
        let revision: i64 = parse(fields.0.get("revision").ok_or(AuthorityError::Corrupt)?)?;
        if schema != 1 || revision < 0 {
            return Err(AuthorityError::Corrupt);
        }
        // Existing envelopes must contain the nonoptional project list. Only
        // an actually absent backend item receives the explicit fresh envelope.
        let entries: Vec<Fields> =
            parse(fields.0.get("workspaces").ok_or(AuthorityError::Corrupt)?)?;
        if entries.len() > MAX_PROJECTS {
            return Err(AuthorityError::Corrupt);
        }
        let mut projects = vec![];
        let mut ids = HashSet::new();
        for entry in &entries {
            let project: SavedProject = parse(&raw(entry)?)?;
            project.validate()?;
            if !ids.insert(project.id.clone()) {
                return Err(AuthorityError::Corrupt);
            }
            projects.push(project);
        }
        Ok(Self {
            previous: bytes,
            fields,
            entries,
            projects,
            revision,
        })
    }
    pub fn revision(&self) -> i64 {
        self.revision
    }
    pub fn projects(&self) -> &[SavedProject] {
        &self.projects
    }
    pub fn edit(&self) -> ProjectDraft {
        ProjectDraft {
            baseline: self.clone(),
            entries: self.entries.clone(),
        }
    }
}

/// An uncommitted edit. Dropping/cancelling it has no storage side effects.
/// The host must enforce idle/no-chat removal and lifecycle restrictions; this
/// contract has no knowledge of chats and cannot grant runtime permission.
#[derive(Clone)]
pub struct ProjectDraft {
    baseline: LoadedProjects,
    entries: Vec<Fields>,
}
impl ProjectDraft {
    /// The last confirmed baseline, unchanged by failed or unconfirmed saves.
    pub fn baseline_revision(&self) -> i64 {
        self.baseline.revision()
    }
    /// Known fields of the current draft, including unsaved create/retrust/root
    /// edits. This exposes neither opaque envelope values nor an execution grant.
    pub fn projects(&self) -> AuthorityResult<Vec<SavedProject>> {
        self.entries
            .iter()
            .map(|entry| parse(&raw(entry)?))
            .collect()
    }
    pub fn trust_project(
        &mut self,
        id: &str,
        primary: &Path,
        additional: &[PathBuf],
    ) -> AuthorityResult<SavedProject> {
        let mut roots = vec![];
        for input in std::iter::once(primary).chain(additional.iter().map(PathBuf::as_path)) {
            if !input.is_absolute() {
                return Err(AuthorityError::InvalidProject);
            }
            let path = fs::canonicalize(input).map_err(|_| AuthorityError::InvalidProject)?;
            if !path.is_dir() {
                return Err(AuthorityError::InvalidProject);
            }
            if !roots.contains(&path) {
                roots.push(path);
            }
        }
        let project = SavedProject {
            id: id.into(),
            path: roots.remove(0),
            paths: roots,
            trusted: true,
        };
        project.validate()?;
        let mut existing = None;
        for (index, entry) in self.entries.iter().enumerate() {
            let old: SavedProject = parse(&raw(entry)?)?;
            if old.id == id {
                existing = Some(index);
                break;
            }
        }
        if existing.is_none() && self.entries.len() >= MAX_PROJECTS {
            return Err(AuthorityError::InvalidProject);
        }
        let mut entry = existing
            .map(|index| self.entries[index].clone())
            .unwrap_or_else(|| Fields(BTreeMap::new()));
        // Patch only known project fields; preserve every unknown raw value.
        entry.0.insert("id".into(), raw(&project.id)?);
        entry.0.insert("path".into(), raw(&project.path)?);
        entry.0.insert("trusted".into(), raw(&project.trusted)?);
        entry.0.insert("paths".into(), raw(&project.paths)?);
        if let Some(index) = existing {
            self.entries[index] = entry;
        } else {
            self.entries.push(entry);
        }
        Ok(project)
    }
    pub fn forget_project(&mut self, id: &str) -> AuthorityResult<()> {
        let mut retained = vec![];
        for entry in &self.entries {
            let project: SavedProject = parse(&raw(entry)?)?;
            if project.id != id {
                retained.push(entry.clone());
            }
        }
        self.entries = retained;
        Ok(())
    }
    pub fn has_changes(&self) -> bool {
        raw(&self.entries).ok().map(|r| r.get().to_owned())
            != raw(&self.baseline.entries).ok().map(|r| r.get().to_owned())
    }
}

// The backend must provide source-equivalent locked whole-byte CAS. The native
// adapter verifies its approved signed identity before BOTH operations.
// Synthetic implementations are never available as a production fallback.
// Every replace error except Unconfirmed guarantees no write by this operation:
// the host treats those errors as pre-write failures when restoring its state.
trait VaultStorage: Send + Sync {
    fn read(&self) -> AuthorityResult<Option<Vec<u8>>>;
    fn replace(&self, expected: Option<&[u8]>, replacement: &[u8]) -> AuthorityResult<()>;
}
/// Provenance is installed only by the explicit storage constructors, never
/// inferred from a profile, endpoint, feature flag, or caller-supplied credential.
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(crate) enum AuthorityProvenance {
    #[default]
    Unavailable,
    #[cfg_attr(not(any(target_os = "macos", test)), allow(dead_code))]
    Production,
    #[cfg(feature = "synthetic-authority")]
    Fixture,
}
#[derive(Clone, Default)]
pub struct ProjectAuthority {
    storage: Option<Arc<dyn VaultStorage>>,
    provenance: AuthorityProvenance,
}
impl ProjectAuthority {
    pub fn new() -> Self {
        Self::default()
    }
    /// Explicit composition boundary for the isolated native Rust vault.
    /// Construction performs no identity, filesystem, or Keychain operations.
    /// The caller must run load/save/confirmation on its existing background
    /// path; enabling this feature never changes `new()` or `Default`.
    #[cfg(feature = "native-authority")]
    pub fn with_native_storage() -> AuthorityResult<Self> {
        native::authority()
    }
    /// Explicit in-memory QA injection. `None` represents an absent item. Raw
    /// malformed fixtures are accepted within the byte limit so `load` exercises
    /// the production decoder. This neither enables tools nor accesses a native
    /// store, disk, environment variables, or credentials.
    #[cfg(feature = "synthetic-authority")]
    pub fn with_synthetic_bytes(
        bytes: Option<Vec<u8>>,
    ) -> AuthorityResult<(Self, synthetic::SyntheticAuthorityControl)> {
        let control = synthetic::SyntheticAuthorityControl::new(bytes)?;
        let authority = Self {
            storage: Some(control.storage.clone()),
            provenance: AuthorityProvenance::Fixture,
        };
        Ok((authority, control))
    }
    #[cfg(test)]
    fn with_test_storage(storage: Arc<dyn VaultStorage>) -> Self {
        Self {
            storage: Some(storage),
            provenance: AuthorityProvenance::Production,
        }
    }
    fn storage(&self) -> AuthorityResult<&dyn VaultStorage> {
        self.storage.as_deref().ok_or(AuthorityError::Unavailable)
    }
    pub fn load(&self) -> AuthorityResult<LoadedProjects> {
        LoadedProjects::decode(self.storage()?.read()?)
    }
    /// Success alone advances the editable baseline. Every error leaves the
    /// user's draft intact; no automatic retry, reset, or rollback is attempted.
    pub fn save(&self, draft: &mut ProjectDraft) -> AuthorityResult<LoadedProjects> {
        let storage = self.storage()?;
        let previous = storage.read()?;
        let current = LoadedProjects::decode(previous.clone())?;
        if current.revision != draft.baseline.revision || previous != draft.baseline.previous {
            return Err(AuthorityError::Conflict);
        }
        let next = current
            .revision
            .checked_add(1)
            .ok_or(AuthorityError::Conflict)?;
        let mut fields = current.fields;
        fields.0.insert("revision".into(), raw(&next)?);
        fields.0.insert("workspaces".into(), raw(&draft.entries)?);
        let bytes = serde_json::to_vec(&fields).map_err(|_| AuthorityError::Corrupt)?;
        let confirmed = LoadedProjects::decode(Some(bytes.clone()))?;
        storage.replace(previous.as_deref(), &bytes)?;
        *draft = confirmed.edit();
        Ok(confirmed)
    }
    /// Fresh full-record membership check. This is a point-in-time configuration
    /// confirmation, not a lease or a sandbox. Host generation/admission fencing
    /// remains required after async boundaries and throughout Controller changes.
    pub fn confirm_project(
        &self,
        expected: &LoadedProjects,
        project: &SavedProject,
    ) -> AuthorityResult<SavedProject> {
        let current = self.load()?;
        if current.previous != expected.previous {
            return Err(AuthorityError::Conflict);
        }
        Self::project_membership(&current, project)
    }
    fn project_membership(
        current: &LoadedProjects,
        project: &SavedProject,
    ) -> AuthorityResult<SavedProject> {
        let index = current
            .projects
            .iter()
            .position(|saved| saved == project && saved.trusted)
            .ok_or(AuthorityError::Untrusted)?;
        if current.entries[index]
            .0
            .keys()
            .any(|key| !["id", "path", "trusted", "paths"].contains(&key.as_str()))
        {
            return Err(AuthorityError::UnsupportedProject);
        }
        if project.roots().any(|root| !root.is_dir()) {
            return Err(AuthorityError::InvalidProject);
        }
        Ok(project.clone())
    }
    /// Runtime continuation needs current exact project membership, not a CAS
    /// against an unrelated connection save. This performs one fresh vault read
    /// and retains full known/unknown policy and root validation.
    pub fn confirm_current_project_binding(
        &self,
        project: &SavedProject,
    ) -> AuthorityResult<ConfirmedProjectBinding> {
        let current = self.load()?;
        let project = Self::project_membership(&current, project)?;
        if fs::canonicalize(&project.path).map_err(|_| AuthorityError::InvalidProject)?
            != project.path
        {
            return Err(AuthorityError::InvalidProject);
        }
        Ok(ConfirmedProjectBinding { project })
    }

    /// Confirm saved authority before taking a workspace catalog lock. The
    /// catalog remains bound to its original canonical primary path; an ID
    /// alone never authorizes relocation or adopting another folder.
    pub fn confirm_project_binding(
        &self,
        expected: &LoadedProjects,
        project: &SavedProject,
    ) -> AuthorityResult<ConfirmedProjectBinding> {
        let project = self.confirm_project(expected, project)?;
        if fs::canonicalize(&project.path).map_err(|_| AuthorityError::InvalidProject)?
            != project.path
        {
            return Err(AuthorityError::InvalidProject);
        }
        Ok(ConfirmedProjectBinding { project })
    }
}

/// Explicit QA controls, absent from default builds. All state lives in memory;
/// construction cannot change the host's tool mode or production authority.
#[cfg(feature = "synthetic-authority")]
pub mod synthetic {
    use super::*;
    use std::{
        sync::{Condvar, Mutex},
        time::Duration,
    };

    /// A forgotten gate fails the pending operation closed after this bound.
    pub const MAX_PAUSE: Duration = Duration::from_secs(5);

    #[derive(Default)]
    struct PauseState {
        started: bool,
        released: bool,
    }
    #[derive(Default)]
    struct Pause {
        state: Mutex<PauseState>,
        changed: Condvar,
    }
    impl Pause {
        fn begin(&self) -> AuthorityResult<()> {
            let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
            state.started = true;
            self.changed.notify_all();
            let (state, _) = self
                .changed
                .wait_timeout_while(state, MAX_PAUSE, |state| !state.released)
                .unwrap_or_else(|error| error.into_inner());
            if state.released {
                Ok(())
            } else {
                Err(AuthorityError::Busy)
            }
        }
        fn release(&self) {
            self.state
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .released = true;
            self.changed.notify_all();
        }
    }

    /// A one-shot completion gate. Dropping it releases pending work, including
    /// when a test exits early. The backend never waits longer than `MAX_PAUSE`.
    /// Release permits the normal operation/error/CAS path; it does not grant
    /// authority or guarantee that an injected write will succeed.
    pub struct SyntheticOperationGate {
        pause: Arc<Pause>,
    }
    impl SyntheticOperationGate {
        /// Wait for the operation to reach this gate, capped at `MAX_PAUSE`.
        pub fn wait_until_started(&self, timeout: Duration) -> bool {
            let state = self
                .pause
                .state
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            let (state, _) = self
                .pause
                .changed
                .wait_timeout_while(state, timeout.min(MAX_PAUSE), |state| !state.started)
                .unwrap_or_else(|error| error.into_inner());
            state.started
        }
        pub fn release(&self) {
            self.pause.release();
        }
    }
    impl Drop for SyntheticOperationGate {
        fn drop(&mut self) {
            self.pause.release();
        }
    }

    #[derive(Default)]
    struct NextOperation {
        pause: Option<Arc<Pause>>,
        error: Option<AuthorityError>,
    }
    impl NextOperation {
        fn pause(&mut self) -> AuthorityResult<SyntheticOperationGate> {
            if self.pause.is_some() {
                return Err(AuthorityError::Busy);
            }
            let pause = Arc::new(Pause::default());
            self.pause = Some(pause.clone());
            Ok(SyntheticOperationGate { pause })
        }
        fn fail(&mut self, error: AuthorityError) -> AuthorityResult<()> {
            if self.error.is_some() {
                return Err(AuthorityError::Busy);
            }
            self.error = Some(error);
            Ok(())
        }
        fn begin(&self) -> AuthorityResult<()> {
            if let Some(pause) = &self.pause {
                pause.begin()?;
            }
            Ok(())
        }
    }

    #[derive(Default)]
    struct State {
        bytes: Option<Vec<u8>>,
        read: NextOperation,
        write: NextOperation,
    }
    #[derive(Default)]
    pub(super) struct MemoryStorage {
        state: Mutex<State>,
    }
    impl VaultStorage for MemoryStorage {
        fn read(&self) -> AuthorityResult<Option<Vec<u8>>> {
            // Capture before pausing completion so QA can deterministically
            // deliver an older snapshot after a newer host generation exists.
            let (bytes, operation) = {
                let mut state = self.state.lock().map_err(|_| AuthorityError::Busy)?;
                (state.bytes.clone(), std::mem::take(&mut state.read))
            };
            operation.begin()?;
            match operation.error {
                Some(error) => Err(error),
                None => Ok(bytes),
            }
        }
        fn replace(&self, expected: Option<&[u8]>, replacement: &[u8]) -> AuthorityResult<()> {
            check_size(Some(replacement))?;
            let operation = {
                let mut state = self.state.lock().map_err(|_| AuthorityError::Busy)?;
                std::mem::take(&mut state.write)
            };
            operation.begin()?;
            // The pause never holds the storage lock. Competing fixture writes
            // remain possible, and the exact-byte CAS still runs atomically.
            let mut state = self.state.lock().map_err(|_| AuthorityError::Busy)?;
            if state.bytes.as_deref() != expected {
                return Err(AuthorityError::Conflict);
            }
            if let Some(error) = operation.error {
                if error == AuthorityError::Unconfirmed {
                    state.bytes = Some(replacement.to_vec());
                }
                return Err(error);
            }
            state.bytes = Some(replacement.to_vec());
            Ok(())
        }
    }
    fn check_size(bytes: Option<&[u8]>) -> AuthorityResult<()> {
        if bytes.is_some_and(|bytes| bytes.len() > MAX_BYTES) {
            return Err(AuthorityError::Corrupt);
        }
        Ok(())
    }

    /// A handle to synthetic fixture bytes and one-shot operation controls.
    /// No Debug implementation: raw fixture values need not be loggable.
    #[derive(Clone)]
    pub struct SyntheticAuthorityControl {
        pub(super) storage: Arc<MemoryStorage>,
    }
    impl SyntheticAuthorityControl {
        /// An authority bound to this in-memory fixture only. A synthetic host
        /// accepts this handle instead of an arbitrary native authority.
        pub fn authority(&self) -> ProjectAuthority {
            ProjectAuthority {
                storage: Some(self.storage.clone()),
                provenance: AuthorityProvenance::Fixture,
            }
        }
        pub(super) fn new(bytes: Option<Vec<u8>>) -> AuthorityResult<Self> {
            check_size(bytes.as_deref())?;
            Ok(Self {
                storage: Arc::new(MemoryStorage {
                    state: Mutex::new(State {
                        bytes,
                        ..State::default()
                    }),
                }),
            })
        }
        /// Replace exact fixture bytes, simulating another writer or a malformed
        /// item. No decoding or normalization occurs here; `load` validates them.
        pub fn replace_bytes(&self, bytes: Option<Vec<u8>>) -> AuthorityResult<()> {
            check_size(bytes.as_deref())?;
            self.storage
                .state
                .lock()
                .map_err(|_| AuthorityError::Busy)?
                .bytes = bytes;
            Ok(())
        }
        pub fn snapshot_bytes(&self) -> AuthorityResult<Option<Vec<u8>>> {
            Ok(self
                .storage
                .state
                .lock()
                .map_err(|_| AuthorityError::Busy)?
                .bytes
                .clone())
        }
        /// Pause the next backend read completion (load, confirm, or save's read).
        pub fn pause_next_read(&self) -> AuthorityResult<SyntheticOperationGate> {
            self.storage
                .state
                .lock()
                .map_err(|_| AuthorityError::Busy)?
                .read
                .pause()
        }
        /// Pause the next replace before its atomic exact-byte comparison.
        pub fn pause_next_write(&self) -> AuthorityResult<SyntheticOperationGate> {
            self.storage
                .state
                .lock()
                .map_err(|_| AuthorityError::Busy)?
                .write
                .pause()
        }
        pub fn fail_next_read(&self, error: AuthorityError) -> AuthorityResult<()> {
            self.storage
                .state
                .lock()
                .map_err(|_| AuthorityError::Busy)?
                .read
                .fail(error)
        }
        /// `Unconfirmed` commits bytes and reports uncertainty. Every other
        /// injected failure leaves bytes untouched. Each hook is consumed once.
        pub fn fail_next_write(&self, error: AuthorityError) -> AuthorityResult<()> {
            self.storage
                .state
                .lock()
                .map_err(|_| AuthorityError::Busy)?
                .write
                .fail(error)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    const ID: &str = "00000000-0000-4000-8000-000000000001";
    #[derive(Default)]
    struct MemoryStore {
        bytes: Mutex<Option<Vec<u8>>>,
        read_error: Mutex<Option<AuthorityError>>,
        write_error: Mutex<Option<AuthorityError>>,
        race: Mutex<Option<Vec<u8>>>,
        writes: Mutex<usize>,
    }
    impl VaultStorage for MemoryStore {
        fn read(&self) -> AuthorityResult<Option<Vec<u8>>> {
            if let Some(error) = self.read_error.lock().unwrap().clone() {
                return Err(error);
            }
            Ok(self.bytes.lock().unwrap().clone())
        }
        fn replace(&self, expected: Option<&[u8]>, replacement: &[u8]) -> AuthorityResult<()> {
            let mut bytes = self.bytes.lock().unwrap();
            if let Some(race) = self.race.lock().unwrap().take() {
                *bytes = Some(race);
            }
            if bytes.as_deref() != expected {
                return Err(AuthorityError::Conflict);
            }
            if let Some(error) = self.write_error.lock().unwrap().clone() {
                if error == AuthorityError::Unconfirmed {
                    *bytes = Some(replacement.to_vec());
                    *self.writes.lock().unwrap() += 1;
                }
                return Err(error);
            }
            *bytes = Some(replacement.to_vec());
            *self.writes.lock().unwrap() += 1;
            Ok(())
        }
    }
    fn fixture() -> (tempfile::TempDir, Arc<MemoryStore>, ProjectAuthority) {
        let directory = tempfile::tempdir().unwrap();
        let storage = Arc::new(MemoryStore::default());
        let authority = ProjectAuthority::with_test_storage(storage.clone());
        (directory, storage, authority)
    }
    #[test]
    fn production_authority_has_no_native_identity_or_storage_fallback() {
        assert!(matches!(
            ProjectAuthority::new().load(),
            Err(AuthorityError::Unavailable)
        ));
    }
    #[test]
    fn trust_requires_confirmed_save_and_cancel_has_no_side_effect() {
        let (directory, storage, authority) = fixture();
        let initial = authority.load().unwrap();
        assert_eq!(initial.revision(), 0);
        let mut draft = initial.edit();
        let project = draft.trust_project(ID, directory.path(), &[]).unwrap();
        assert_eq!(draft.baseline_revision(), 0);
        assert_eq!(draft.projects().unwrap(), vec![project.clone()]);
        assert!(matches!(
            authority.confirm_project(&initial, &project),
            Err(AuthorityError::Untrusted)
        ));
        assert!(draft.has_changes());
        drop(draft);
        assert_eq!(*storage.writes.lock().unwrap(), 0);
        assert!(storage.bytes.lock().unwrap().is_none());
        let mut draft = initial.edit();
        let project = draft.trust_project(ID, directory.path(), &[]).unwrap();
        let saved = authority.save(&mut draft).unwrap();
        assert_eq!(saved.revision(), 1);
        assert_eq!(draft.baseline_revision(), 1);
        assert!(!draft.has_changes());
        let reopened = ProjectAuthority::with_test_storage(storage.clone());
        let loaded = reopened.load().unwrap();
        assert_eq!(
            reopened.confirm_project(&loaded, &project).unwrap(),
            project
        );
        assert!(matches!(
            authority.confirm_project(&initial, &project),
            Err(AuthorityError::Conflict)
        ));
    }
    #[test]
    fn every_untouched_opaque_value_survives_without_number_or_escape_reencoding() {
        let (directory, storage, authority) = fixture();
        let opaque = r#"{ "large": 184467440737095516160000000000000001, "exponent": 1e9999, "nested": [ {"escaped":"\u0061", "fraction":0.12345678901234567890123456789} ] }"#;
        let bytes = format!(r#"{{"schema":1,"revision":0,"workspaces":[],"future":{opaque},"profiles":[{{"apiKey":"synthetic-only","unrecognized":42}}],"captureKey":"synthetic-legacy"}}"#).into_bytes();
        *storage.bytes.lock().unwrap() = Some(bytes);
        let mut draft = authority.load().unwrap().edit();
        draft.trust_project(ID, directory.path(), &[]).unwrap();
        authority.save(&mut draft).unwrap();
        let saved = storage.bytes.lock().unwrap().clone().unwrap();
        let fields: Fields = serde_json::from_slice(&saved).unwrap();
        assert_eq!(fields.0["future"].get(), opaque);
        assert_eq!(
            fields.0["profiles"].get(),
            r#"[{"apiKey":"synthetic-only","unrecognized":42}]"#
        );
        assert_eq!(fields.0["captureKey"].get(), "\"synthetic-legacy\"");
    }
    #[test]
    fn revision_and_whole_byte_conflicts_preserve_edits_and_existing_contents() {
        let (directory, storage, authority) = fixture();
        let initial = authority.load().unwrap();
        let mut first = initial.edit();
        let mut second = initial.edit();
        first.trust_project(ID, directory.path(), &[]).unwrap();
        second.trust_project(ID, directory.path(), &[]).unwrap();
        authority.save(&mut first).unwrap();
        let before = storage.bytes.lock().unwrap().clone();
        assert!(matches!(
            authority.save(&mut second),
            Err(AuthorityError::Conflict)
        ));
        assert!(second.has_changes());
        assert_eq!(*storage.bytes.lock().unwrap(), before);
        let mut draft = authority.load().unwrap().edit();
        draft.forget_project(ID).unwrap();
        let mut changed = before.unwrap();
        changed.push(b' ');
        *storage.bytes.lock().unwrap() = Some(changed.clone());
        assert!(matches!(
            authority.save(&mut draft),
            Err(AuthorityError::Conflict)
        ));
        assert_eq!(*storage.bytes.lock().unwrap(), Some(changed));
        assert!(draft.has_changes());
    }
    #[test]
    fn backend_cas_race_and_failed_initial_creation_never_overwrite_other_writer() {
        let (directory, storage, authority) = fixture();
        let mut draft = authority.load().unwrap().edit();
        draft.trust_project(ID, directory.path(), &[]).unwrap();
        let other = br#"{"schema":1,"revision":1,"workspaces":[],"owner":"other-writer"}"#.to_vec();
        *storage.race.lock().unwrap() = Some(other.clone());
        assert!(matches!(
            authority.save(&mut draft),
            Err(AuthorityError::Conflict)
        ));
        assert_eq!(*storage.bytes.lock().unwrap(), Some(other));
        assert_eq!(*storage.writes.lock().unwrap(), 0);
        assert!(draft.has_changes());
    }
    #[test]
    fn denied_and_busy_saves_never_advance_draft_baseline() {
        let (directory, storage, authority) = fixture();
        for error in [AuthorityError::Denied, AuthorityError::Busy] {
            let mut draft = authority.load().unwrap().edit();
            draft.trust_project(ID, directory.path(), &[]).unwrap();
            *storage.write_error.lock().unwrap() = Some(error.clone());
            assert!(matches!(authority.save(&mut draft), Err(actual) if actual == error));
            assert!(draft.has_changes());
            assert_eq!(draft.baseline.revision(), 0);
            assert!(storage.bytes.lock().unwrap().is_none());
        }
        *storage.read_error.lock().unwrap() = Some(AuthorityError::Denied);
        assert!(matches!(authority.load(), Err(AuthorityError::Denied)));
        assert_eq!(*storage.writes.lock().unwrap(), 0);
    }
    #[test]
    fn corrupt_future_duplicate_oversized_and_revision_overflow_fail_without_writes() {
        let (_, storage, authority) = fixture();
        for bytes in [
            b"not json".to_vec(),
            br#"{"schema":2,"revision":0,"workspaces":[]}"#.to_vec(),
            br#"{"schema":1,"revision":0}"#.to_vec(),
            br#"{"schema":1,"revision":-1,"workspaces":[]}"#.to_vec(),
            br#"{"schema":1,"schema":1,"revision":0,"workspaces":[]}"#.to_vec(),
            vec![b' '; MAX_BYTES + 1],
        ] {
            *storage.bytes.lock().unwrap() = Some(bytes.clone());
            assert!(authority.load().is_err());
            assert_eq!(*storage.bytes.lock().unwrap(), Some(bytes));
        }
        let bytes =
            format!(r#"{{"schema":1,"revision":{},"workspaces":[]}}"#, i64::MAX).into_bytes();
        *storage.bytes.lock().unwrap() = Some(bytes.clone());
        let mut draft = authority.load().unwrap().edit();
        assert!(matches!(
            authority.save(&mut draft),
            Err(AuthorityError::Conflict)
        ));
        assert_eq!(*storage.bytes.lock().unwrap(), Some(bytes));
        assert_eq!(*storage.writes.lock().unwrap(), 0);
    }
    #[test]
    fn roots_are_canonical_ordered_deduplicated_and_invalid_edits_are_atomic() {
        let (directory, _, authority) = fixture();
        let other = directory.path().join("other");
        fs::create_dir(&other).unwrap();
        let mut draft = authority.load().unwrap().edit();
        let project = draft
            .trust_project(
                ID,
                directory.path(),
                &[other.clone(), directory.path().into(), other.clone()],
            )
            .unwrap();
        assert_eq!(project.path, fs::canonicalize(directory.path()).unwrap());
        assert_eq!(project.paths, vec![fs::canonicalize(other).unwrap()]);
        let before = raw(&draft.entries).unwrap().get().to_owned();
        let many: Vec<_> = (0..16)
            .map(|index| {
                let path = directory.path().join(format!("extra-{index}"));
                fs::create_dir(&path).unwrap();
                path
            })
            .collect();
        for (id, path, roots) in [
            ("invalid", directory.path(), vec![]),
            (ID, Path::new("relative"), vec![]),
            (ID, directory.path(), many),
        ] {
            assert!(draft.trust_project(id, path, &roots).is_err());
            assert_eq!(raw(&draft.entries).unwrap().get(), before);
        }
    }
    #[test]
    fn unknown_project_fields_are_preserved_but_never_silently_authorize_future_policy() {
        let (directory, storage, authority) = fixture();
        let project = SavedProject {
            id: ID.into(),
            path: fs::canonicalize(directory.path()).unwrap(),
            paths: vec![],
            trusted: true,
        };
        let mut entry: Fields = parse(&raw(&project).unwrap()).unwrap();
        entry.0.insert(
            "futurePolicy".into(),
            RawValue::from_string(
                r#"{"required":true,"number":999999999999999999999999999999999}"#.into(),
            )
            .unwrap(),
        );
        *storage.bytes.lock().unwrap() = Some(
            format!(
                r#"{{"schema":1,"revision":0,"workspaces":{}}}"#,
                raw(&vec![entry]).unwrap()
            )
            .into_bytes(),
        );
        let loaded = authority.load().unwrap();
        assert!(matches!(
            authority.confirm_project(&loaded, &project),
            Err(AuthorityError::UnsupportedProject)
        ));
        let mut draft = loaded.edit();
        draft.trust_project(ID, directory.path(), &[]).unwrap();
        let saved = authority.save(&mut draft).unwrap();
        assert_eq!(
            saved.entries[0].0["futurePolicy"].get(),
            loaded.entries[0].0["futurePolicy"].get()
        );
        assert!(matches!(
            authority.confirm_project(&saved, &project),
            Err(AuthorityError::UnsupportedProject)
        ));
    }
    #[test]
    fn legacy_project_paths_accept_absent_and_null_without_rewriting_on_read() {
        let (directory, storage, authority) = fixture();
        for paths in ["", ",\"paths\":null"] {
            let bytes = format!(r#"{{"schema":1,"revision":0,"workspaces":[{{"id":"{ID}","path":{},"trusted":true{paths}}}]}}"#, serde_json::to_string(&fs::canonicalize(directory.path()).unwrap()).unwrap()).into_bytes();
            *storage.bytes.lock().unwrap() = Some(bytes.clone());
            let loaded = authority.load().unwrap();
            assert!(loaded.projects()[0].paths.is_empty());
            assert!(
                authority
                    .confirm_project(&loaded, &loaded.projects()[0])
                    .is_ok()
            );
            assert_eq!(*storage.bytes.lock().unwrap(), Some(bytes));
            assert_eq!(*storage.writes.lock().unwrap(), 0);
        }
    }
    #[test]
    fn unconfirmed_write_keeps_draft_and_cannot_be_silently_retried() {
        let (directory, storage, authority) = fixture();
        let mut draft = authority.load().unwrap().edit();
        draft.trust_project(ID, directory.path(), &[]).unwrap();
        *storage.write_error.lock().unwrap() = Some(AuthorityError::Unconfirmed);
        assert!(matches!(
            authority.save(&mut draft),
            Err(AuthorityError::Unconfirmed)
        ));
        assert!(draft.has_changes());
        assert_eq!(draft.baseline.revision(), 0);
        let bytes = storage.bytes.lock().unwrap().clone();
        *storage.write_error.lock().unwrap() = None;
        assert!(matches!(
            authority.save(&mut draft),
            Err(AuthorityError::Conflict)
        ));
        assert_eq!(*storage.bytes.lock().unwrap(), bytes);
        assert_eq!(*storage.writes.lock().unwrap(), 1);
        assert_eq!(authority.load().unwrap().revision(), 1);
    }
    #[test]
    fn malformed_project_collections_and_save_growth_preserve_existing_bytes() {
        let (directory, storage, authority) = fixture();
        let project = SavedProject {
            id: ID.into(),
            path: fs::canonicalize(directory.path()).unwrap(),
            paths: vec![],
            trusted: true,
        };
        let mut many = Vec::new();
        for _ in 0..=MAX_PROJECTS {
            let mut p = project.clone();
            p.id = uuid::Uuid::new_v4().to_string();
            many.push(p);
        }
        let duplicate_key = format!(r#"{{"schema":1,"revision":0,"workspaces":[{{"id":"{ID}","id":"{ID}","path":{},"trusted":true}}]}}"#, raw(&project.path).unwrap()).into_bytes();
        for bytes in [
            serde_json::to_vec(&serde_json::json!({"schema":1,"revision":0,"workspaces":[project.clone(),project.clone()]})).unwrap(),
            serde_json::to_vec(&serde_json::json!({"schema":1,"revision":0,"workspaces":many})).unwrap(),
            duplicate_key,
        ] {
            *storage.bytes.lock().unwrap() = Some(bytes.clone()); assert!(authority.load().is_err());
            assert_eq!(*storage.bytes.lock().unwrap(), Some(bytes));
        }
        let empty = serde_json::json!({"schema":1,"revision":0,"workspaces":[],"opaque":""});
        let overhead = serde_json::to_vec(&empty).unwrap().len();
        let mut large = empty;
        large["opaque"] = serde_json::Value::String("x".repeat(MAX_BYTES - overhead));
        let bytes = serde_json::to_vec(&large).unwrap();
        assert_eq!(bytes.len(), MAX_BYTES);
        *storage.bytes.lock().unwrap() = Some(bytes.clone());
        let mut draft = authority.load().unwrap().edit();
        draft.trust_project(ID, directory.path(), &[]).unwrap();
        assert!(authority.save(&mut draft).is_err());
        assert!(draft.has_changes());
        assert_eq!(*storage.bytes.lock().unwrap(), Some(bytes));
        assert_eq!(*storage.writes.lock().unwrap(), 0);
    }
    #[test]
    fn membership_checks_complete_record_and_existing_item_cas_is_atomic() {
        let (directory, storage, authority) = fixture();
        let mut draft = authority.load().unwrap().edit();
        let project = draft.trust_project(ID, directory.path(), &[]).unwrap();
        let loaded = authority.save(&mut draft).unwrap();
        let mut forged = project.clone();
        forged.path = directory.path().join("elsewhere");
        assert!(matches!(
            authority.confirm_project(&loaded, &forged),
            Err(AuthorityError::Untrusted)
        ));
        forged = project;
        forged.trusted = false;
        assert!(matches!(
            authority.confirm_project(&loaded, &forged),
            Err(AuthorityError::Untrusted)
        ));
        draft.forget_project(ID).unwrap();
        let competing = br#"{"schema":1,"revision":2,"workspaces":[],"owner":"newer"}"#.to_vec();
        *storage.race.lock().unwrap() = Some(competing.clone());
        assert!(matches!(
            authority.save(&mut draft),
            Err(AuthorityError::Conflict)
        ));
        assert!(draft.has_changes());
        assert_eq!(*storage.bytes.lock().unwrap(), Some(competing));
        assert_eq!(*storage.writes.lock().unwrap(), 1);
    }

    #[cfg(feature = "synthetic-authority")]
    mod synthetic_tests {
        use super::*;
        use std::{thread, time::Duration};

        const EMPTY: &[u8] = br#"{"schema":1,"revision":0,"workspaces":[]}"#;

        #[test]
        fn fixture_is_explicit_bounded_and_uses_the_unchanged_decoder() {
            let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
            assert_eq!(authority.load().unwrap().revision(), 0);
            assert!(control.snapshot_bytes().unwrap().is_none());
            assert!(matches!(
                ProjectAuthority::new().load(),
                Err(AuthorityError::Unavailable)
            ));
            for bytes in [
                b"not json".to_vec(),
                br#"{"schema":2,"revision":0,"workspaces":[]}"#.to_vec(),
                br#"{"schema":1,"revision":0}"#.to_vec(),
            ] {
                control.replace_bytes(Some(bytes.clone())).unwrap();
                assert!(matches!(authority.load(), Err(AuthorityError::Corrupt)));
                assert_eq!(control.snapshot_bytes().unwrap(), Some(bytes));
            }
            let before = control.snapshot_bytes().unwrap();
            assert!(matches!(
                control.replace_bytes(Some(vec![b' '; MAX_BYTES + 1])),
                Err(AuthorityError::Corrupt)
            ));
            assert_eq!(control.snapshot_bytes().unwrap(), before);
            assert!(matches!(
                ProjectAuthority::with_synthetic_bytes(Some(vec![b' '; MAX_BYTES + 1])),
                Err(AuthorityError::Corrupt)
            ));
        }

        #[test]
        fn read_gate_returns_older_snapshot_and_drop_releases_pending_work() {
            let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
            thread::scope(|scope| {
                let gate = control.pause_next_read().unwrap();
                assert!(matches!(
                    control.pause_next_read(),
                    Err(AuthorityError::Busy)
                ));
                let load = scope.spawn(|| authority.load());
                assert!(gate.wait_until_started(Duration::from_secs(2)));
                control
                    .replace_bytes(Some(
                        br#"{"schema":1,"revision":1,"workspaces":[]}"#.to_vec(),
                    ))
                    .unwrap();
                drop(gate);
                assert_eq!(load.join().unwrap().unwrap().revision(), 0);
            });
            assert_eq!(authority.load().unwrap().revision(), 1);
            control.fail_next_read(AuthorityError::Denied).unwrap();
            assert!(matches!(
                control.fail_next_read(AuthorityError::Busy),
                Err(AuthorityError::Busy)
            ));
            assert!(matches!(authority.load(), Err(AuthorityError::Denied)));
            assert_eq!(authority.load().unwrap().revision(), 1);
        }

        #[test]
        fn paused_write_detects_same_revision_byte_race_and_retains_draft() {
            let directory = tempfile::tempdir().unwrap();
            let (authority, control) =
                ProjectAuthority::with_synthetic_bytes(Some(EMPTY.to_vec())).unwrap();
            let mut draft = authority.load().unwrap().edit();
            let project = draft.trust_project(ID, directory.path(), &[]).unwrap();
            thread::scope(|scope| {
                let gate = control.pause_next_write().unwrap();
                let save = scope.spawn(|| authority.save(&mut draft));
                assert!(gate.wait_until_started(Duration::from_secs(2)));
                let mut raced = EMPTY.to_vec();
                raced.push(b' ');
                control.replace_bytes(Some(raced.clone())).unwrap();
                gate.release();
                assert!(matches!(
                    save.join().unwrap(),
                    Err(AuthorityError::Conflict)
                ));
                assert_eq!(control.snapshot_bytes().unwrap(), Some(raced));
            });
            assert_eq!(draft.baseline_revision(), 0);
            assert_eq!(draft.projects().unwrap(), vec![project]);
            assert!(draft.has_changes());
        }

        #[test]
        fn failures_are_one_shot_and_unconfirmed_write_retains_old_baseline() {
            let directory = tempfile::tempdir().unwrap();
            let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
            let mut draft = authority.load().unwrap().edit();
            let project = draft.trust_project(ID, directory.path(), &[]).unwrap();
            for error in [AuthorityError::Denied, AuthorityError::Busy] {
                control.fail_next_write(error.clone()).unwrap();
                assert!(matches!(authority.save(&mut draft), Err(actual) if actual == error));
                assert!(control.snapshot_bytes().unwrap().is_none());
                assert_eq!(draft.baseline_revision(), 0);
                assert_eq!(draft.projects().unwrap(), vec![project.clone()]);
            }
            control
                .fail_next_write(AuthorityError::Unconfirmed)
                .unwrap();
            assert!(matches!(
                authority.save(&mut draft),
                Err(AuthorityError::Unconfirmed)
            ));
            assert_eq!(draft.baseline_revision(), 0);
            assert!(draft.has_changes());
            let committed = control.snapshot_bytes().unwrap();
            assert_eq!(authority.load().unwrap().revision(), 1);
            assert!(matches!(
                authority.save(&mut draft),
                Err(AuthorityError::Conflict)
            ));
            assert_eq!(control.snapshot_bytes().unwrap(), committed);
        }

        #[test]
        fn opaque_values_survive_synthetic_save_and_fixture_grants_no_membership() {
            let directory = tempfile::tempdir().unwrap();
            let opaque = r#"{ "large": 184467440737095516160000000000000001, "escaped":"\u0061" }"#;
            let bytes = format!(r#"{{"schema":1,"revision":0,"workspaces":[],"future":{opaque}}}"#)
                .into_bytes();
            let (authority, control) = ProjectAuthority::with_synthetic_bytes(Some(bytes)).unwrap();
            let loaded = authority.load().unwrap();
            let mut draft = loaded.edit();
            let project = draft.trust_project(ID, directory.path(), &[]).unwrap();
            assert!(matches!(
                authority.confirm_project(&loaded, &project),
                Err(AuthorityError::Untrusted)
            ));
            let saved = authority.save(&mut draft).unwrap();
            assert_eq!(
                authority.confirm_project(&saved, &project).unwrap(),
                project
            );
            let fields: Fields =
                serde_json::from_slice(&control.snapshot_bytes().unwrap().unwrap()).unwrap();
            assert_eq!(fields.0["future"].get(), opaque);
            assert!(!draft.has_changes());
        }

        #[test]
        fn unreleased_write_times_out_without_mutation_or_baseline_advance() {
            let directory = tempfile::tempdir().unwrap();
            let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
            let mut draft = authority.load().unwrap().edit();
            draft.trust_project(ID, directory.path(), &[]).unwrap();
            thread::scope(|scope| {
                let gate = control.pause_next_write().unwrap();
                let save = scope.spawn(|| authority.save(&mut draft));
                assert!(gate.wait_until_started(Duration::from_secs(2)));
                assert!(matches!(save.join().unwrap(), Err(AuthorityError::Busy)));
                gate.release();
            });
            assert!(control.snapshot_bytes().unwrap().is_none());
            assert_eq!(draft.baseline_revision(), 0);
            assert!(draft.has_changes());
            // The timed-out one-shot hook cannot hold a later reviewed save.
            assert_eq!(authority.save(&mut draft).unwrap().revision(), 1);
        }
    }
}
