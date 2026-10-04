//! Rust-only chat catalog and small draft records. This is intentionally separate
//! from streamed transcripts: typing never rewrites a whole conversation.
use crate::{Error, Lane, Result, invalid};
use fs2::FileExt;
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
    /// A prior Save/Cancel/Remove may be durable while this draft still names
    /// its old hold. Keep only genuinely unsaved rewriting, ahead of the draft
    /// that the edit displaced, and never leave a resolved edit stuck open.
    pub fn reconcile_queued(&mut self, session: &crate::Session) -> Result<bool> {
        let mut next = self.clone();
        let changed = next.reconcile_queued_inner(session)?;
        if changed {
            *self = next;
        }
        Ok(changed)
    }
    fn reconcile_queued_inner(&mut self, session: &crate::Session) -> Result<bool> {
        let Some(edit) = self.queued_edit.as_ref() else {
            return Ok(false);
        };
        if session
            .edit
            .as_ref()
            .is_some_and(|held| held.edit_id == edit.edit_id && held.turn_id == edit.turn_id)
        {
            return Ok(false);
        }
        use sha2::{Digest, Sha256};
        let outcome = session
            .outcomes
            .iter()
            .find(|outcome| outcome.edit_id == edit.edit_id);
        let keep = if let Some(outcome) = outcome.filter(|outcome| outcome.outcome == "saved") {
            outcome.digest.as_deref()
                != Some(format!("{:x}", Sha256::digest(edit.rewrite.as_bytes())).as_str())
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
        if self.version != 1 || self.chats.len() > MAX_CHATS || self.intents.len() > MAX_CHATS {
            return Err(invalid("Unsupported or oversized Rust workspace catalog"));
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
        lock.try_lock_exclusive()
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
    fn lock_and_project_binding_are_checked() {
        let (dir, _store, _) = fixture();
        assert!(WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).is_err());
    }
}
