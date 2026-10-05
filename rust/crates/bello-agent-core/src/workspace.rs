//! Rust-only chat catalog and small draft records. This is intentionally separate
//! from streamed transcripts: typing never rewrites a whole conversation.
use crate::{Error, Lane, Result, invalid};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};
use uuid::Uuid;
const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_CHATS: usize = 512;
const MAX_DRAFT_BYTES: usize = 262_144;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct QueuedDraft {
    pub edit_id: String,
    pub turn_id: String,
    pub rewrite: String,
    #[serde(default)]
    pub original_text: Option<String>,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftRecord {
    pub revision: u64,
    pub text: String,
    pub queued_edit: Option<QueuedDraft>,
}
impl DraftRecord {
    pub fn is_empty(&self) -> bool {
        self.text.trim().is_empty() && self.queued_edit.is_none()
    }
    /// Pure-model comparison for callers that already own a certain model.
    /// Never pass a cached UI snapshot here for persistence recovery; query
    /// Controller::edit_status and use reconcile_queued_status instead.
    pub fn reconcile_queued(&mut self, session: &crate::Session) -> Result<bool> {
        let Some(edit) = self.queued_edit.as_ref() else {
            return Ok(false);
        };
        self.reconcile_queued_status(&session.queue_edit_status(&edit.edit_id)?)
    }
    /// A prior Save/Cancel/Remove may be durable while this draft still names
    /// its old hold. Keep genuinely unsaved rewriting ahead of the displaced
    /// draft. Identity conflicts or invalid merged drafts leave all text intact.
    pub fn reconcile_queued_status(&mut self, status: &crate::QueueEditStatus) -> Result<bool> {
        let mut next = self.clone();
        let changed = next.reconcile_queued_status_inner(status)?;
        if changed {
            *self = next;
        }
        Ok(changed)
    }
    fn reconcile_queued_status_inner(&mut self, status: &crate::QueueEditStatus) -> Result<bool> {
        let Some(edit) = self.queued_edit.as_ref() else {
            return Ok(false);
        };
        if status.edit_id != edit.edit_id {
            return Err(invalid("Queued edit status belongs to another edit"));
        }
        if let crate::QueueEditState::Active { turn_id, .. } = &status.state {
            if turn_id != &edit.turn_id {
                return Err(invalid("Queued edit status belongs to another message"));
            }
            self.validate()?;
            return Ok(false);
        }
        use sha2::{Digest, Sha256};
        let keep = if let crate::QueueEditState::Saved { digest } = &status.state {
            digest != &format!("{:x}", Sha256::digest(edit.rewrite.as_bytes()))
        } else {
            edit.original_text
                .as_ref()
                .is_none_or(|original| original.trim() != edit.rewrite.trim())
        };
        if keep && !edit.rewrite.trim().is_empty() {
            self.text = if self.text.is_empty() {
                edit.rewrite.clone()
            } else {
                format!("{}\n\n{}", edit.rewrite, self.text)
            };
        }
        self.queued_edit = None;
        self.revision = self
            .revision
            .checked_add(1)
            .ok_or_else(|| invalid("Draft revision overflow"))?;
        self.validate()?;
        Ok(true)
    }
    fn validate(&self) -> Result<()> {
        if self.text.len() > MAX_DRAFT_BYTES
            || self.queued_edit.as_ref().is_some_and(|v| {
                v.rewrite.len() > MAX_DRAFT_BYTES
                    || v.original_text
                        .as_ref()
                        .is_some_and(|text| text.len() > MAX_DRAFT_BYTES)
                    || v.edit_id.is_empty()
                    || v.edit_id.len() > 128
                    || v.turn_id.is_empty()
                    || v.turn_id.len() > 128
            })
        {
            return Err(invalid(
                "Draft exceeds its supported limits; existing text is preserved",
            ));
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChatRecord {
    pub id: String,
    pub title: String,
    pub snapshot: PathBuf,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sidebar_order: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned_at: Option<u64>,
}
impl ChatRecord {
    pub fn new(id: String, title: String, snapshot: PathBuf) -> Self {
        Self {
            id,
            title,
            snapshot,
            sidebar_order: Some(organization_timestamp()),
            pinned_at: None,
        }
    }
    /// Source ChatRecord.sidebarPrecedes, without the unported manual drag order.
    pub fn sidebar_cmp(&self, other: &Self) -> std::cmp::Ordering {
        other
            .pinned_at
            .is_some()
            .cmp(&self.pinned_at.is_some())
            .then_with(|| match (self.pinned_at, other.pinned_at) {
                (Some(a), Some(b)) => a.cmp(&b),
                _ => std::cmp::Ordering::Equal,
            })
            .then_with(|| {
                other
                    .sidebar_order
                    .unwrap_or(0)
                    .cmp(&self.sidebar_order.unwrap_or(0))
            })
            .then_with(|| self.id.cmp(&other.id))
    }
}
pub fn organization_timestamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_micros().min(u128::from(u64::MAX)) as u64)
        .unwrap_or(0)
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SubmissionIntent {
    pub id: String,
    pub chat_id: String,
    pub text: String,
    pub lane: Lane,
    pub draft_revision: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkspaceSnapshot {
    pub version: u32,
    pub project: PathBuf,
    pub revision: u64,
    pub chats: Vec<ChatRecord>,
    pub drafts: BTreeMap<String, DraftRecord>,
    pub intents: BTreeMap<String, SubmissionIntent>,
    pub selected: Option<String>,
    pub selection_revision: u64,
    #[serde(default)]
    pub settled_submissions: BTreeMap<String, u64>,
}
impl WorkspaceSnapshot {
    fn new(project: PathBuf) -> Self {
        Self {
            version: 1,
            project,
            revision: 0,
            chats: Vec::new(),
            drafts: BTreeMap::new(),
            intents: BTreeMap::new(),
            selected: None,
            selection_revision: 0,
            settled_submissions: BTreeMap::new(),
        }
    }
    fn validate(&self) -> Result<()> {
        if !matches!(self.version, 1 | 2)
            || self.chats.len() > MAX_CHATS
            || self.intents.len() > MAX_CHATS
        {
            return Err(invalid("Unsupported or oversized Rust workspace catalog"));
        }
        if self.version == 1
            && self
                .chats
                .iter()
                .any(|chat| chat.sidebar_order.is_some() || chat.pinned_at.is_some())
        {
            return Err(invalid(
                "Organization metadata requires Rust workspace catalog version 2",
            ));
        }
        let mut ids = std::collections::HashSet::new();
        for chat in &self.chats {
            if Uuid::parse_str(&chat.id).is_err()
                || !ids.insert(&chat.id)
                || !chat.snapshot.is_absolute()
                || chat.title.len() > 512
            {
                return Err(invalid("Invalid Rust chat catalog record"));
            }
        }
        if self.drafts.keys().any(|id| !ids.contains(id))
            || self.selected.as_ref().is_some_and(|id| !ids.contains(id))
        {
            return Err(invalid("Workspace refers to an unknown chat"));
        }
        if self.settled_submissions.keys().any(|id| !ids.contains(id)) {
            return Err(invalid("Submission receipt names an unknown chat"));
        }
        for draft in self.drafts.values() {
            draft.validate()?;
        }
        for (id, intent) in &self.intents {
            if id != &intent.id
                || Uuid::parse_str(id).is_err()
                || !ids.contains(&intent.chat_id)
                || intent.text.trim().is_empty()
                || intent.text.len() > MAX_DRAFT_BYTES
            {
                return Err(invalid("Invalid retained submission intent"));
            }
        }
        Ok(())
    }
}
/// Single writer, atomic small-file transactions. Revision receipts reject stale
/// debounce work independently of wall-clock changes and task cancellation.
pub struct WorkspaceStore {
    path: PathBuf,
    _lock: File,
    state: WorkspaceSnapshot,
    uncertain: bool,
    #[cfg(test)]
    fault: Fault,
}
#[cfg(test)]
#[derive(Default, Clone, Copy)]
enum Fault {
    #[default]
    None,
    BeforeRename,
    AfterRename,
}
impl WorkspaceStore {
    pub fn open(path: impl AsRef<Path>, project: impl AsRef<Path>) -> Result<Self> {
        let path = absolute(path.as_ref())?;
        let project = fs::canonicalize(project)?;
        if !project.is_dir() {
            return Err(invalid("The project is not a directory"));
        }
        let parent = path
            .parent()
            .ok_or_else(|| invalid("Catalog needs a directory"))?;
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(parent)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let lock = options.open(path.with_extension("workspace.lock"))?;
        lock.try_lock()
            .map_err(|_| invalid("This Rust workspace is already open elsewhere"))?;
        let state = if path.exists() {
            if fs::metadata(&path)?.len() > MAX_BYTES as u64 {
                return Err(invalid("Rust workspace catalog exceeds 16 MiB"));
            }
            let state: WorkspaceSnapshot = serde_json::from_slice(&fs::read(&path)?)?;
            state.validate()?;
            if state.project != project {
                return Err(invalid("This Rust chat catalog belongs to another project"));
            }
            state
        } else {
            WorkspaceSnapshot::new(project)
        };
        Ok(Self {
            path,
            _lock: lock,
            state,
            uncertain: false,
            #[cfg(test)]
            fault: Fault::None,
        })
    }
    pub fn snapshot(&self) -> WorkspaceSnapshot {
        self.state.clone()
    }
    pub fn chat_path(&self, id: &str) -> Result<PathBuf> {
        Uuid::parse_str(id).map_err(|_| invalid("Invalid chat identity"))?;
        Ok(self
            .path
            .parent()
            .expect("validated parent")
            .join("chats")
            .join(format!("{id}.json")))
    }
    pub fn register(&mut self, chat: ChatRecord, draft: DraftRecord) -> Result<()> {
        draft.validate()?;
        self.transact(|state| {
            if let Some(existing) = state.chats.iter().find(|v| v.id == chat.id) {
                if existing.snapshot != chat.snapshot {
                    return Err(invalid("Chat identity is already registered differently"));
                }
                return Ok(());
            }
            if state.chats.len() >= MAX_CHATS {
                return Err(invalid(
                    "This development workspace supports up to 512 chats",
                ));
            }
            state.drafts.insert(chat.id.clone(), draft);
            state.chats.push(chat);
            Ok(())
        })
    }
    pub fn name_chat(&mut self, id: &str, title: &str) -> Result<()> {
        if title.len() > 512 {
            return Err(invalid("Chat title exceeds 512 bytes"));
        }
        self.transact(|state| {
            let chat = state
                .chats
                .iter_mut()
                .find(|chat| chat.id == id)
                .ok_or_else(|| invalid("Chat is no longer registered"))?;
            chat.title = title.into();
            Ok(())
        })
    }
    /// Commit only organization metadata for existing chats. A pending chat's
    /// record, captured draft and pin are materialized together, with no transient
    /// empty saved chat and no transcript/controller mutation.
    pub fn set_pinned(
        &mut self,
        record: ChatRecord,
        draft: DraftRecord,
        pinned: bool,
        at: u64,
    ) -> Result<ChatRecord> {
        if self.uncertain {
            return Err(invalid(
                "Workspace persistence is uncertain. Reopen before continuing.",
            ));
        }
        if let Some(existing) = self.state.chats.iter().find(|chat| chat.id == record.id) {
            if existing.snapshot != record.snapshot {
                return Err(invalid("Chat identity is already registered differently"));
            }
            if existing.pinned_at.is_some() == pinned {
                return Ok(existing.clone());
            }
        } else {
            draft.validate()?;
        }
        self.transact(|state| {
            let index =
                if let Some(index) = state.chats.iter().position(|chat| chat.id == record.id) {
                    index
                } else {
                    if state.chats.len() >= MAX_CHATS {
                        return Err(invalid(
                            "This development workspace supports up to 512 chats",
                        ));
                    }
                    state.drafts.insert(record.id.clone(), draft);
                    state.chats.push(record.clone());
                    state.chats.len() - 1
                };
            let chat = &mut state.chats[index];
            // Legacy Rust catalogs appended records in creation order. A caller
            // may have reconstructed that order without rewriting the old file.
            if chat.sidebar_order.is_none() {
                chat.sidebar_order = record.sidebar_order;
            }
            chat.pinned_at = if pinned {
                Some(chat.pinned_at.unwrap_or(at))
            } else {
                None
            };
            Ok(chat.clone())
        })
    }
    /// Returns false for obsolete writes without changing the current draft.
    pub fn save_draft(&mut self, id: &str, draft: DraftRecord) -> Result<bool> {
        if self.uncertain {
            return Err(invalid(
                "Workspace persistence is uncertain. Reopen before continuing.",
            ));
        }
        draft.validate()?;
        if self
            .state
            .drafts
            .get(id)
            .is_some_and(|saved| saved.revision >= draft.revision)
        {
            return Ok(false);
        }
        self.transact(|state| {
            if !state.chats.iter().any(|v| v.id == id) {
                return Err(invalid("Draft has no saved chat"));
            }
            state.drafts.insert(id.into(), draft);
            Ok(true)
        })
    }
    pub fn select(&mut self, id: &str, revision: u64) -> Result<bool> {
        if self.uncertain {
            return Err(invalid(
                "Workspace persistence is uncertain. Reopen before continuing.",
            ));
        }
        if revision <= self.state.selection_revision {
            return Ok(false);
        }
        self.transact(|state| {
            if !state.chats.iter().any(|v| v.id == id) {
                return Err(invalid("Selection has no saved chat"));
            }
            state.selected = Some(id.into());
            state.selection_revision = revision;
            Ok(true)
        })
    }
    /// Preserve the exact submitted text before dispatch. Clearing the captured
    /// draft and retaining this receipt are one durable transaction.
    pub fn begin_submission(&mut self, intent: SubmissionIntent) -> Result<()> {
        self.transact(|state| {
            if let Some(existing) = state.intents.get(&intent.id) {
                return if existing == &intent {
                    Ok(())
                } else {
                    Err(invalid(
                        "Submission identity conflicts with a saved receipt",
                    ))
                };
            }
            if state
                .settled_submissions
                .get(&intent.chat_id)
                .is_some_and(|revision| *revision >= intent.draft_revision)
            {
                return Err(invalid("This submission has already settled"));
            }
            let draft = state
                .drafts
                .get_mut(&intent.chat_id)
                .ok_or_else(|| invalid("Submission has no saved chat"))?;
            if draft.revision == intent.draft_revision
                && draft.text == intent.text
                && draft.queued_edit.is_none()
            {
                draft.revision = draft
                    .revision
                    .checked_add(1)
                    .ok_or_else(|| invalid("Draft revision overflow"))?;
                draft.text.clear();
            }
            state.intents.insert(intent.id.clone(), intent);
            Ok(())
        })
    }
    /// Any debounce from an in-flight Send retains its receipt atomically with
    /// newer typing. It cannot erase the captured text before intent persistence.
    pub fn save_submitting_draft(
        &mut self,
        chat: ChatRecord,
        draft: DraftRecord,
        intent: SubmissionIntent,
    ) -> Result<()> {
        draft.validate()?;
        if chat.id != intent.chat_id {
            return Err(invalid("Submission draft belongs to another chat"));
        }
        self.transact(|state| {
            if let Some(existing) = state.chats.iter().find(|item| item.id == chat.id) {
                if existing.snapshot != chat.snapshot {
                    return Err(invalid("Chat snapshot identity changed"));
                }
            } else {
                state.chats.push(chat.clone());
            }
            if !state
                .settled_submissions
                .get(&chat.id)
                .is_some_and(|revision| *revision >= intent.draft_revision)
            {
                if let Some(existing) = state.intents.get(&intent.id) {
                    if existing != &intent {
                        return Err(invalid(
                            "Submission identity conflicts with a saved receipt",
                        ));
                    }
                } else {
                    state.intents.insert(intent.id.clone(), intent);
                }
            }
            if state
                .drafts
                .get(&chat.id)
                .is_none_or(|saved| saved.revision < draft.revision)
            {
                state.drafts.insert(chat.id, draft);
            }
            Ok(())
        })
    }
    /// The caller proves acceptance using the same turn ID in the session.
    pub fn acknowledge_submission(&mut self, id: &str) -> Result<()> {
        self.transact(|state| {
            if let Some(intent) = state.intents.remove(id) {
                state
                    .settled_submissions
                    .entry(intent.chat_id)
                    .and_modify(|revision| *revision = (*revision).max(intent.draft_revision))
                    .or_insert(intent.draft_revision);
            }
            Ok(())
        })
    }
    pub fn withdraw_submission(&mut self, id: &str, restored: DraftRecord) -> Result<()> {
        restored.validate()?;
        self.transact(|state| {
            let Some(intent) = state.intents.remove(id) else {
                return Ok(());
            };
            state
                .settled_submissions
                .entry(intent.chat_id.clone())
                .and_modify(|revision| *revision = (*revision).max(intent.draft_revision))
                .or_insert(intent.draft_revision);
            if state
                .drafts
                .get(&intent.chat_id)
                .is_none_or(|draft| draft.revision <= restored.revision)
            {
                state.drafts.insert(intent.chat_id, restored);
            }
            Ok(())
        })
    }
    /// A definitively rejected Send settles its captured identity even if the
    /// original preparation failed before recording it. Delayed debounce work
    /// cannot later turn that rejection back into an unconfirmed submission.
    pub fn settle_rejected(
        &mut self,
        chat: ChatRecord,
        intent: SubmissionIntent,
        restored: DraftRecord,
    ) -> Result<()> {
        restored.validate()?;
        if chat.id != intent.chat_id || Uuid::parse_str(&intent.id).is_err() {
            return Err(invalid("Rejected submission identity mismatch"));
        }
        self.transact(|state| {
            if let Some(existing) = state.chats.iter().find(|item| item.id == chat.id) {
                if existing.snapshot != chat.snapshot {
                    return Err(invalid("Chat snapshot identity changed"));
                }
            } else {
                state.chats.push(chat.clone());
            }
            if let Some(existing) = state.intents.get(&intent.id)
                && existing != &intent
            {
                return Err(invalid(
                    "Submission identity conflicts with a saved receipt",
                ));
            }
            state.intents.remove(&intent.id);
            state
                .settled_submissions
                .entry(chat.id.clone())
                .and_modify(|revision| *revision = (*revision).max(intent.draft_revision))
                .or_insert(intent.draft_revision);
            if state
                .drafts
                .get(&chat.id)
                .is_none_or(|draft| draft.revision <= restored.revision)
            {
                state.drafts.insert(chat.id, restored);
            }
            Ok(())
        })
    }
    fn transact<T>(
        &mut self,
        change: impl FnOnce(&mut WorkspaceSnapshot) -> Result<T>,
    ) -> Result<T> {
        if self.uncertain {
            return Err(invalid(
                "Workspace persistence is uncertain. Reopen before continuing.",
            ));
        }
        let mut state = self.state.clone();
        let result = change(&mut state)?;
        if state
            .chats
            .iter()
            .any(|chat| chat.sidebar_order.is_some() || chat.pinned_at.is_some())
        {
            state.version = 2;
        }
        state.revision = state
            .revision
            .checked_add(1)
            .ok_or_else(|| invalid("Workspace revision overflow"))?;
        state.validate()?;
        let mut bytes = serde_json::to_vec(&state)?;
        bytes.push(b'\n');
        if bytes.len() > MAX_BYTES {
            return Err(invalid(
                "Workspace catalog exceeds 16 MiB; previous data is preserved",
            ));
        }
        let parent = self.path.parent().expect("validated parent");
        let temporary = parent.join(format!(".workspace-{}.tmp", Uuid::new_v4()));
        let commit = (|| -> Result<()> {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            #[cfg(test)]
            if matches!(self.fault, Fault::BeforeRename) {
                return Err(std::io::Error::other("injected catalog failure").into());
            }
            fs::rename(&temporary, &self.path)?;
            #[cfg(test)]
            if matches!(self.fault, Fault::AfterRename) {
                return Err(Error::PersistenceUncertain(
                    "injected catalog uncertainty".into(),
                ));
            }
            File::open(parent)
                .and_then(|dir| dir.sync_all())
                .map_err(|error| Error::PersistenceUncertain(error.to_string()))?;
            Ok(())
        })();
        if let Err(error) = commit {
            if matches!(error, Error::PersistenceUncertain(_)) {
                self.uncertain = true;
            }
            let _ = fs::remove_file(temporary);
            return Err(error);
        }
        self.state = state;
        Ok(result)
    }
}
fn absolute(path: &Path) -> Result<PathBuf> {
    Ok(if path.is_absolute() {
        path.to_owned()
    } else {
        std::env::current_dir()?.join(path)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, WorkspaceStore, ChatRecord) {
        let dir = tempfile::tempdir().unwrap();
        let store = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
        let id = Uuid::new_v4().to_string();
        let chat = ChatRecord {
            sidebar_order: None,
            pinned_at: None,
            snapshot: store.chat_path(&id).unwrap(),
            id,
            title: "New chat".into(),
        };
        (dir, store, chat)
    }
    #[test]
    fn pending_creation_has_no_catalog_and_atomic_materialization_keeps_draft() {
        let (dir, mut store, chat) = fixture();
        assert!(!dir.path().join("workspace.json").exists());
        let draft = DraftRecord {
            revision: 1,
            text: "Half a thought".into(),
            queued_edit: None,
        };
        store.register(chat.clone(), draft.clone()).unwrap();
        drop(store);
        let state = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path())
            .unwrap()
            .snapshot();
        assert_eq!(state.chats, vec![chat.clone()]);
        assert_eq!(state.drafts[&chat.id], draft);
    }
    #[test]
    fn stale_draft_and_selection_writes_never_replace_newer_records() {
        let (_dir, mut store, chat) = fixture();
        store
            .register(chat.clone(), DraftRecord::default())
            .unwrap();
        let mut draft = DraftRecord {
            revision: 1000,
            text: "new".into(),
            queued_edit: None,
        };
        assert!(store.save_draft(&chat.id, draft.clone()).unwrap());
        draft.revision = 1;
        draft.text = "old".into();
        assert!(!store.save_draft(&chat.id, draft).unwrap());
        assert_eq!(store.snapshot().drafts[&chat.id].text, "new");
        assert!(store.select(&chat.id, 9).unwrap());
        assert!(!store.select(&chat.id, 8).unwrap());
    }
    #[test]
    fn submission_receipt_and_clear_are_atomic_and_do_not_clear_newer_typing() {
        let (_dir, mut store, chat) = fixture();
        store
            .register(
                chat.clone(),
                DraftRecord {
                    revision: 3,
                    text: "first".into(),
                    queued_edit: None,
                },
            )
            .unwrap();
        let mut intent = SubmissionIntent {
            id: Uuid::new_v4().to_string(),
            chat_id: chat.id.clone(),
            text: "first".into(),
            lane: Lane::FollowUp,
            draft_revision: 3,
        };
        store.begin_submission(intent.clone()).unwrap();
        assert!(store.snapshot().drafts[&chat.id].text.is_empty());
        assert_eq!(store.snapshot().intents.len(), 1);
        store
            .save_draft(
                &chat.id,
                DraftRecord {
                    revision: 5,
                    text: "newer".into(),
                    queued_edit: None,
                },
            )
            .unwrap();
        intent.id = Uuid::new_v4().to_string();
        store.begin_submission(intent).unwrap();
        assert_eq!(store.snapshot().drafts[&chat.id].text, "newer");
    }
    #[test]
    fn failures_preserve_memory_and_postrename_uncertainty_blocks_writes() {
        let (dir, mut store, chat) = fixture();
        store.fault = Fault::BeforeRename;
        assert!(
            store
                .register(chat.clone(), DraftRecord::default())
                .is_err()
        );
        assert!(store.snapshot().chats.is_empty());
        store.fault = Fault::AfterRename;
        assert!(matches!(
            store.register(chat.clone(), DraftRecord::default()),
            Err(Error::PersistenceUncertain(_))
        ));
        store.fault = Fault::None;
        assert!(
            store
                .register(chat.clone(), DraftRecord::default())
                .is_err()
        );
        drop(store);
        let restored = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
        assert_eq!(restored.snapshot().chats, vec![chat]);
    }
    #[test]
    fn clearing_debounce_carries_intent_and_late_debounce_cannot_resurrect_settled_send() {
        let (_dir, mut store, chat) = fixture();
        store
            .register(
                chat.clone(),
                DraftRecord {
                    revision: 3,
                    text: "first".into(),
                    queued_edit: None,
                },
            )
            .unwrap();
        let intent = SubmissionIntent {
            id: Uuid::new_v4().to_string(),
            chat_id: chat.id.clone(),
            text: "first".into(),
            lane: Lane::FollowUp,
            draft_revision: 3,
        };
        let second = DraftRecord {
            revision: 5,
            text: "second".into(),
            queued_edit: None,
        };
        store
            .save_submitting_draft(chat.clone(), second.clone(), intent.clone())
            .unwrap();
        assert_eq!(store.snapshot().drafts[&chat.id].text, "second");
        assert_eq!(store.snapshot().intents[&intent.id].text, "first");
        store.begin_submission(intent.clone()).unwrap(); // the earlier debounce won, without preventing dispatch
        store.acknowledge_submission(&intent.id).unwrap();
        store
            .save_submitting_draft(
                chat.clone(),
                DraftRecord {
                    revision: 6,
                    ..second
                },
                intent.clone(),
            )
            .unwrap();
        assert!(store.snapshot().intents.is_empty());
        assert!(store.begin_submission(intent).is_err());
        assert_eq!(store.snapshot().drafts[&chat.id].text, "second");
    }
    #[test]
    fn rejected_preparation_without_receipt_cannot_be_resurrected_by_late_debounce() {
        let (_dir, mut store, chat) = fixture();
        store.fault = Fault::BeforeRename;
        assert!(
            store
                .register(
                    chat.clone(),
                    DraftRecord {
                        revision: 3,
                        text: "first".into(),
                        queued_edit: None
                    }
                )
                .is_err()
        );
        assert!(store.snapshot().chats.is_empty());
        store.fault = Fault::None;
        let intent = SubmissionIntent {
            id: Uuid::new_v4().to_string(),
            chat_id: chat.id.clone(),
            text: "first".into(),
            lane: Lane::FollowUp,
            draft_revision: 3,
        };
        let restored = DraftRecord {
            revision: 6,
            text: "first\n\nsecond".into(),
            queued_edit: None,
        };
        store
            .settle_rejected(chat.clone(), intent.clone(), restored.clone())
            .unwrap();
        store
            .save_submitting_draft(
                chat.clone(),
                DraftRecord {
                    revision: 5,
                    text: "second".into(),
                    queued_edit: None,
                },
                intent,
            )
            .unwrap();
        assert!(store.snapshot().intents.is_empty());
        assert_eq!(store.snapshot().drafts[&chat.id], restored);
    }
    #[test]
    fn failed_intent_commit_keeps_text_or_durable_receipt_at_each_rename_boundary() {
        let (dir, mut store, chat) = fixture();
        let draft = DraftRecord {
            revision: 3,
            text: "first".into(),
            queued_edit: None,
        };
        store.register(chat.clone(), draft.clone()).unwrap();
        let intent = SubmissionIntent {
            id: Uuid::new_v4().to_string(),
            chat_id: chat.id.clone(),
            text: "first".into(),
            lane: Lane::FollowUp,
            draft_revision: 3,
        };
        store.fault = Fault::BeforeRename;
        assert!(store.begin_submission(intent.clone()).is_err());
        assert_eq!(store.snapshot().drafts[&chat.id], draft);
        assert!(store.snapshot().intents.is_empty());
        drop(store);
        let mut reopened =
            WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
        assert_eq!(reopened.snapshot().drafts[&chat.id], draft);
        reopened.fault = Fault::AfterRename;
        assert!(matches!(
            reopened.begin_submission(intent.clone()),
            Err(Error::PersistenceUncertain(_))
        ));
        assert_eq!(reopened.snapshot().drafts[&chat.id], draft);
        assert!(
            reopened
                .save_draft(
                    &chat.id,
                    DraftRecord {
                        revision: 10,
                        text: "must wait".into(),
                        queued_edit: None
                    }
                )
                .is_err()
        );
        drop(reopened);
        let restored = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path())
            .unwrap()
            .snapshot();
        assert!(restored.drafts[&chat.id].text.is_empty());
        assert_eq!(restored.intents[&intent.id], intent);
    }
    #[test]
    fn pin_commit_failure_preserves_old_state_or_marks_uncertain_until_reopen() {
        let (dir, mut store, chat) = fixture();
        let draft = DraftRecord {
            revision: 3,
            text: "keep draft".into(),
            queued_edit: None,
        };
        store.register(chat.clone(), draft.clone()).unwrap();
        let path = dir.path().join("workspace.json");
        let before = std::fs::read(&path).unwrap();
        store.fault = Fault::BeforeRename;
        assert!(
            store
                .set_pinned(chat.clone(), draft.clone(), true, 7)
                .is_err()
        );
        assert!(store.snapshot().chats[0].pinned_at.is_none());
        assert_eq!(std::fs::read(&path).unwrap(), before);
        store.fault = Fault::AfterRename;
        assert!(matches!(
            store.set_pinned(chat.clone(), draft.clone(), true, 9),
            Err(Error::PersistenceUncertain(_))
        ));
        assert!(store.snapshot().chats[0].pinned_at.is_none());
        assert!(
            store
                .set_pinned(chat.clone(), draft.clone(), false, 10)
                .is_err()
        );
        drop(store);
        let restored = WorkspaceStore::open(path, dir.path()).unwrap().snapshot();
        assert_eq!(restored.version, 2);
        assert_eq!(restored.chats[0].pinned_at, Some(9));
        assert_eq!(restored.drafts[&chat.id], draft);
    }
    #[test]
    fn lock_and_project_binding_are_checked() {
        let (dir, _store, _) = fixture();
        assert!(WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).is_err());
    }
}
