//! Portable contracts for the isolated Rust project-authority vault.
//!
//! Source: ConfigurationVault.swift, KeychainVaultStorage.swift, WorkspaceRecord
//! and WorkspaceFolders.swift. This does NOT access a Keychain, source vault,
//! credentials, environment, or plaintext fallback. The production constructor
//! is unavailable until an approved native identity/backend is implemented.
//! Only unit tests may inject storage. Values describe saved configuration, not
//! an execution grant; the host still owns lifecycle and admission fencing.
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

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum AuthorityError {
    #[error("Native project authority is unavailable until its signing identity is configured.")]
    Unavailable,
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

// The backend must provide source-equivalent locked whole-byte CAS. The future
// native adapter must verify its approved signed identity before BOTH operations.
// Test implementations are never available as a production fallback.
trait VaultStorage: Send + Sync {
    fn read(&self) -> AuthorityResult<Option<Vec<u8>>>;
    fn replace(&self, expected: Option<&[u8]>, replacement: &[u8]) -> AuthorityResult<()>;
}
#[derive(Default)]
pub struct ProjectAuthority {
    storage: Option<Arc<dyn VaultStorage>>,
}
impl ProjectAuthority {
    pub fn new() -> Self {
        Self::default()
    }
    #[cfg(test)]
    fn with_test_storage(storage: Arc<dyn VaultStorage>) -> Self {
        Self {
            storage: Some(storage),
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
}
