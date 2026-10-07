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
const CURRENT_VERSION: u32 = 6;

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
/// Saved chat metadata only. Neither value grants a controller any tools.
/// Ordinary source chats start with editing tools; source sides explicitly
/// start read-only. Imported originals are separately blocked in the source,
/// and are not represented by this Rust catalog slice.
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub enum ChatToolMode {
    #[default]
    #[serde(rename = "editing")]
    Editing,
    #[serde(rename = "read-only")]
    ReadOnly,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ChatRecord {
    pub id: String,
    pub title: String,
    pub snapshot: PathBuf,
    pub tool_mode: ChatToolMode,
    /// Explicit saved connection identity; None keeps the legacy CLI-only route.
    #[serde(deserialize_with = "present_connection_id")]
    pub connection_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sidebar_order: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archived_at: Option<u64>,
}
impl ChatRecord {
    pub fn new(id: String, title: String, snapshot: PathBuf) -> Self {
        Self {
            id,
            title,
            snapshot,
            tool_mode: ChatToolMode::Editing,
            connection_id: None,
            sidebar_order: Some(organization_timestamp()),
            pinned_at: None,
            archived_at: None,
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
/// The confirmed metadata patch and whether this operation changed archive state.
/// An idempotent Archive must not trigger another navigation fallback.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveChange {
    pub record: ChatRecord,
    pub changed: bool,
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
/// A per-chat cancellation fence, independent of debounced draft writes.
/// Settled receipts are retained to reject delayed preparation of an old Cancel.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct QueuedCancelReceipt {
    pub revision: u64,
    pub state: QueuedCancelState,
}
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum QueuedCancelState {
    Pending { edit_id: String, turn_id: String },
    Settled,
}
impl<'de> Deserialize<'de> for QueuedCancelState {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        // Serde's internally tagged unit variants otherwise ignore unknown
        // fields, even with deny_unknown_fields on the enum. An empty struct
        // variant enforces the settled record's exact shape.
        #[derive(Deserialize)]
        #[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
        enum Record {
            Pending { edit_id: String, turn_id: String },
            Settled {},
        }
        Ok(match Record::deserialize(deserializer)? {
            Record::Pending { edit_id, turn_id } => Self::Pending { edit_id, turn_id },
            Record::Settled {} => Self::Settled,
        })
    }
}
impl QueuedCancelReceipt {
    /// Allocate after the last retained receipt (or zero for the first Cancel).
    /// Leave room for settlement before dispatching any actor operation. The
    /// identity can name an unowned hold with no retained queued rewrite.
    pub fn pending(previous_revision: u64, edit_id: String, turn_id: String) -> Result<Self> {
        let receipt = Self {
            revision: previous_revision
                .checked_add(1)
                .ok_or_else(|| invalid("Cancellation revision overflow"))?,
            state: QueuedCancelState::Pending { edit_id, turn_id },
        };
        receipt.validate()?;
        Ok(receipt)
    }
    fn validate(&self) -> Result<()> {
        if self.revision == 0 {
            return Err(invalid("Invalid cancellation revision"));
        }
        match &self.state {
            QueuedCancelState::Pending { edit_id, turn_id } => {
                if self.revision == u64::MAX {
                    return Err(invalid("Cancellation revision overflow"));
                }
                if edit_id.is_empty()
                    || edit_id.len() > 128
                    || turn_id.is_empty()
                    || turn_id.len() > 128
                {
                    return Err(invalid("Invalid cancellation identity"));
                }
            }
            QueuedCancelState::Settled if self.revision < 2 => {
                return Err(invalid("Invalid settled cancellation revision"));
            }
            QueuedCancelState::Settled => {}
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct WorkspaceSnapshot {
    pub version: u32,
    pub project: PathBuf,
    /// Absent until an explicit, freshly confirmed SavedProject binding. This
    /// is its existing UUID, never an independently generated catalog identity.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    pub revision: u64,
    pub chats: Vec<ChatRecord>,
    pub drafts: BTreeMap<String, DraftRecord>,
    pub intents: BTreeMap<String, SubmissionIntent>,
    pub selected: Option<String>,
    pub selection_revision: u64,
    #[serde(default, skip_serializing_if = "is_false")]
    pub show_archived: bool,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub archive_visibility_revision: u64,
    #[serde(default)]
    pub settled_submissions: BTreeMap<String, u64>,
    #[serde(default)]
    pub queued_cancellations: BTreeMap<String, QueuedCancelReceipt>,
}
impl<'de> Deserialize<'de> for WorkspaceSnapshot {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        // Decode rows by catalog version: a v5 missing mode must not silently
        // acquire editing permissions. Only old Rust v1-v4 rows infer Editing.
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Record {
            version: u32,
            project: PathBuf,
            #[serde(default, deserialize_with = "present_project_id")]
            project_id: Option<String>,
            revision: u64,
            chats: Vec<Box<serde_json::value::RawValue>>,
            drafts: BTreeMap<String, DraftRecord>,
            intents: BTreeMap<String, SubmissionIntent>,
            selected: Option<String>,
            selection_revision: u64,
            #[serde(default)]
            show_archived: bool,
            #[serde(default)]
            archive_visibility_revision: u64,
            #[serde(default)]
            settled_submissions: BTreeMap<String, u64>,
            #[serde(default)]
            queued_cancellations: BTreeMap<String, QueuedCancelReceipt>,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct LegacyChat {
            id: String,
            title: String,
            snapshot: PathBuf,
            #[serde(default)]
            sidebar_order: Option<u64>,
            #[serde(default)]
            pinned_at: Option<u64>,
            #[serde(default)]
            archived_at: Option<u64>,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct V5Chat {
            id: String,
            title: String,
            snapshot: PathBuf,
            tool_mode: ChatToolMode,
            #[serde(default)]
            sidebar_order: Option<u64>,
            #[serde(default)]
            pinned_at: Option<u64>,
            #[serde(default)]
            archived_at: Option<u64>,
        }
        let record = Record::deserialize(deserializer)?;
        if !(1..=CURRENT_VERSION).contains(&record.version)
            || (record.version < 5 && record.project_id.is_some())
        {
            return Err(serde::de::Error::custom(
                "Unsupported Rust workspace catalog version",
            ));
        }
        let chats = record
            .chats
            .into_iter()
            .map(|raw| {
                if record.version >= 6 {
                    serde_json::from_str(raw.get())
                } else if record.version == 5 {
                    serde_json::from_str::<V5Chat>(raw.get()).map(|chat| ChatRecord {
                        id: chat.id,
                        title: chat.title,
                        snapshot: chat.snapshot,
                        tool_mode: chat.tool_mode,
                        connection_id: None,
                        sidebar_order: chat.sidebar_order,
                        pinned_at: chat.pinned_at,
                        archived_at: chat.archived_at,
                    })
                } else {
                    serde_json::from_str::<LegacyChat>(raw.get()).map(|chat| ChatRecord {
                        id: chat.id,
                        title: chat.title,
                        snapshot: chat.snapshot,
                        tool_mode: ChatToolMode::Editing,
                        connection_id: None,
                        sidebar_order: chat.sidebar_order,
                        pinned_at: chat.pinned_at,
                        archived_at: chat.archived_at,
                    })
                }
            })
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(serde::de::Error::custom)?;
        Ok(Self {
            version: record.version,
            project: record.project,
            project_id: record.project_id,
            revision: record.revision,
            chats,
            drafts: record.drafts,
            intents: record.intents,
            selected: record.selected,
            selection_revision: record.selection_revision,
            show_archived: record.show_archived,
            archive_visibility_revision: record.archive_visibility_revision,
            settled_submissions: record.settled_submissions,
            queued_cancellations: record.queued_cancellations,
        })
    }
}
fn present_connection_id<'de, D>(deserializer: D) -> std::result::Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer)
}
fn present_project_id<'de, D>(deserializer: D) -> std::result::Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    // Missing means explicitly unbound; null or a malformed value is not a
    // supported way to clear a previously persisted binding.
    String::deserialize(deserializer).map(Some)
}
impl WorkspaceSnapshot {
    fn new(project: PathBuf) -> Self {
        Self {
            version: 1,
            project,
            project_id: None,
            revision: 0,
            chats: Vec::new(),
            drafts: BTreeMap::new(),
            intents: BTreeMap::new(),
            selected: None,
            selection_revision: 0,
            show_archived: false,
            archive_visibility_revision: 0,
            settled_submissions: BTreeMap::new(),
            queued_cancellations: BTreeMap::new(),
        }
    }
    fn validate(&self) -> Result<()> {
        if !(1..=CURRENT_VERSION).contains(&self.version)
            || self.chats.len() > MAX_CHATS
            || self.intents.len() > MAX_CHATS
            || self.queued_cancellations.len() > MAX_CHATS
        {
            return Err(invalid("Unsupported or oversized Rust workspace catalog"));
        }
        if self
            .project_id
            .as_ref()
            .is_some_and(|id| Uuid::parse_str(id).is_err())
        {
            return Err(invalid("Invalid saved project identity"));
        }
        if self.version < 6 && self.chats.iter().any(|chat| chat.connection_id.is_some()) {
            return Err(invalid(
                "Saved connections require Rust workspace catalog version 6",
            ));
        }
        if self.version < 5
            && (self.project_id.is_some()
                || self
                    .chats
                    .iter()
                    .any(|chat| chat.tool_mode != ChatToolMode::Editing))
        {
            return Err(invalid(
                "Project identity and tool modes require Rust workspace catalog version 5",
            ));
        }
        if self.version < 4
            && (self.show_archived
                || self.archive_visibility_revision != 0
                || self.chats.iter().any(|chat| chat.archived_at.is_some()))
        {
            return Err(invalid(
                "Archive metadata requires Rust workspace catalog version 4",
            ));
        }
        if self.version < 3 && !self.queued_cancellations.is_empty() {
            return Err(invalid(
                "Cancellation receipts require Rust workspace catalog version 3",
            ));
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
                || chat
                    .connection_id
                    .as_ref()
                    .is_some_and(|id| Uuid::parse_str(id).is_err())
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
        for (id, receipt) in &self.queued_cancellations {
            if !ids.contains(id) {
                return Err(invalid("Cancellation receipt names an unknown chat"));
            }
            receipt.validate()?;
            if receipt.revision > self.revision {
                return Err(invalid(
                    "Cancellation revision exceeds its catalog revision",
                ));
            }
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
        Self::open_with_confirmation(path.as_ref(), project.as_ref(), confirm_existing_catalog)
    }
    fn open_with_confirmation(
        path: &Path,
        project: &Path,
        confirm: impl FnOnce(&Path) -> Result<()>,
    ) -> Result<Self> {
        let path = absolute(path)?;
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
            // An existing post-rename file is not authoritative merely because
            // its bytes can be read. Confirm file and directory without a rewrite.
            confirm(&path)?;
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
    /// Query while holding the writer mutex alongside an operation's result.
    /// A later refused mutation returns Invalid even when a prior write made the
    /// catalog uncertain; callers must not infer certainty from that error alone.
    pub fn is_uncertain(&self) -> bool {
        self.uncertain
    }
    /// Consume fresh metadata confirmation minted outside the catalog mutex.
    /// This does not write authority, relocate roots, or grant runtime tools.
    /// Once authority has been saved, a caller must retain its admission fence
    /// on any binding failure, even a definite pre-rename catalog error.
    pub fn bind_project_identity(
        &mut self,
        binding: crate::project_authority::ConfirmedProjectBinding,
    ) -> Result<bool> {
        self.ensure_certain()?;
        if binding.project_path() != self.state.project {
            return Err(invalid(
                "The saved project does not match this catalog's original root",
            ));
        }
        if let Some(id) = &self.state.project_id {
            return if id == binding.project_id() {
                Ok(false)
            } else {
                Err(invalid(
                    "This catalog is already bound to another saved project",
                ))
            };
        }
        self.transact(|state| {
            state.project_id = Some(binding.project_id().into());
            Ok(true)
        })
    }
    /// Persist the source's one-way mode change after the host has confirmed
    /// consent and eligibility, checked idle state, and closed the old session.
    /// Publish the returned row only after success. This metadata operation
    /// does not itself check authority, create a controller, or enable tools.
    pub fn enable_editing_after_confirmation(&mut self, id: &str) -> Result<ChatRecord> {
        self.ensure_certain()?;
        let chat = self
            .state
            .chats
            .iter()
            .find(|chat| chat.id == id)
            .ok_or_else(|| invalid("Chat is no longer registered"))?;
        if chat.tool_mode == ChatToolMode::Editing {
            return Ok(chat.clone());
        }
        self.transact(|state| {
            let chat = state
                .chats
                .iter_mut()
                .find(|chat| chat.id == id)
                .ok_or_else(|| invalid("Chat is no longer registered"))?;
            chat.tool_mode = ChatToolMode::Editing;
            Ok(chat.clone())
        })
    }
    /// Patch a saved chat only after the host has fenced admission, confirmed
    /// the target connection and retired/joined the previous controller. Pending
    /// chats change their in-memory row instead; this must not materialize them.
    /// The expected identity rejects a delayed switch; unrelated metadata stays.
    pub fn set_connection_after_retirement(
        &mut self,
        id: &str,
        expected: Option<&str>,
        connection_id: &str,
    ) -> Result<ChatRecord> {
        self.ensure_certain()?;
        Uuid::parse_str(connection_id).map_err(|_| invalid("Invalid saved connection identity"))?;
        let chat = self
            .state
            .chats
            .iter()
            .find(|chat| chat.id == id)
            .ok_or_else(|| invalid("Chat is no longer registered"))?;
        if chat.connection_id.as_deref() != expected {
            return Err(invalid("The chat connection changed before this switch"));
        }
        if chat.connection_id.as_deref() == Some(connection_id) {
            return Ok(chat.clone());
        }
        self.transact(|state| {
            let chat = state
                .chats
                .iter_mut()
                .find(|chat| chat.id == id)
                .ok_or_else(|| invalid("Chat is no longer registered"))?;
            chat.connection_id = Some(connection_id.into());
            Ok(chat.clone())
        })
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
    /// Patch only archive metadata, atomically registering a pending chat and its
    /// captured draft if needed. Existing title, pin, draft and receipts remain
    /// authoritative. This never opens or writes the transcript.
    pub fn set_archived(
        &mut self,
        record: ChatRecord,
        draft: DraftRecord,
        archived: bool,
        at: u64,
    ) -> Result<ArchiveChange> {
        self.ensure_certain()?;
        if let Some(existing) = self.state.chats.iter().find(|chat| chat.id == record.id) {
            if existing.snapshot != record.snapshot {
                return Err(invalid("Chat identity is already registered differently"));
            }
            if existing.archived_at.is_some() == archived {
                return Ok(ArchiveChange {
                    record: existing.clone(),
                    changed: false,
                });
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
            let changed = chat.archived_at.is_some() != archived;
            // Match Pin's reconstructed legacy order without replacing a saved
            // order or importing stale title, pin, or draft values from the UI.
            if chat.sidebar_order.is_none() {
                chat.sidebar_order = record.sidebar_order;
            }
            chat.archived_at = if archived {
                Some(chat.archived_at.unwrap_or(at))
            } else {
                None
            };
            let record = chat.clone();
            state.version = state.version.max(4);
            Ok(ArchiveChange { record, changed })
        })
    }
    /// Confirm the exact visibility intent, or return false when superseded.
    /// Its revision is independent of catalog/selection revisions; callers must
    /// allocate a newer revision with checked arithmetic before accepting intent.
    pub fn set_archive_visibility(&mut self, shown: bool, revision: u64) -> Result<bool> {
        self.ensure_certain()?;
        if revision < self.state.archive_visibility_revision {
            return Ok(false);
        }
        if revision == self.state.archive_visibility_revision {
            return if shown == self.state.show_archived {
                Ok(true)
            } else {
                Err(invalid(
                    "Archive visibility revision conflicts with saved contents",
                ))
            };
        }
        self.transact(|state| {
            state.show_archived = shown;
            state.archive_visibility_revision = revision;
            state.version = state.version.max(4);
            Ok(true)
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
    /// Barrier before Save/Remove. Success proves that this exact payload is
    /// durable. Unlike ordinary debounce writes, stale or conflicting payloads
    /// are errors and must never authorize dispatching the actor command.
    pub fn flush_draft_exact(&mut self, id: &str, draft: DraftRecord) -> Result<()> {
        self.ensure_certain()?;
        draft.validate()?;
        require_chat(&self.state, id)?;
        if exact_draft_current(&self.state, id, &draft)? {
            return Ok(());
        }
        self.transact(|state| {
            state.drafts.insert(id.into(), draft);
            Ok(())
        })
    }
    /// Atomically preserve the latest draft and cancellation intent before any
    /// actor dispatch. Only an exact retained Pending retry is idempotent; older,
    /// conflicting and superseding preparations fail without changing anything.
    pub fn prepare_queued_cancel(
        &mut self,
        id: &str,
        pending: QueuedCancelReceipt,
        draft: DraftRecord,
    ) -> Result<()> {
        self.ensure_certain()?;
        require_chat(&self.state, id)?;
        pending.validate()?;
        draft.validate()?;
        let QueuedCancelState::Pending { edit_id, turn_id } = &pending.state else {
            return Err(invalid("Cancellation preparation requires Pending state"));
        };
        let retry = self.state.queued_cancellations.get(id) == Some(&pending);
        for retained in [Some(&draft), self.state.drafts.get(id)]
            .into_iter()
            .flatten()
        {
            if let Some(edit) = &retained.queued_edit
                && &edit.edit_id == edit_id
                && &edit.turn_id != turn_id
            {
                return Err(invalid(
                    "Cancellation preparation belongs to another queued turn",
                ));
            }
        }
        if !retry
            && draft
                .queued_edit
                .as_ref()
                .is_some_and(|edit| &edit.edit_id != edit_id)
        {
            return Err(invalid(
                "Cancellation preparation belongs to another queued draft",
            ));
        }
        if let Some(existing) = self.state.queued_cancellations.get(id) {
            if existing == &pending {
                // The same durable Cancel remains authorized after newer typing.
                // Never restore its older draft, but reject ambiguous equal revisions.
                if let Some(saved) = self.state.drafts.get(id) {
                    if saved.revision > draft.revision {
                        return Ok(());
                    }
                    if saved.revision == draft.revision {
                        return if saved == &draft {
                            Ok(())
                        } else {
                            Err(invalid("Draft revision conflicts with saved contents"))
                        };
                    }
                }
                return self.transact(|state| {
                    state.drafts.insert(id.into(), draft);
                    Ok(())
                });
            }
            if matches!(existing.state, QueuedCancelState::Pending { .. }) {
                return Err(invalid("Another cancellation is still pending"));
            }
        }
        let previous = self
            .state
            .queued_cancellations
            .get(id)
            .map_or(0, |v| v.revision);
        if previous.checked_add(1) != Some(pending.revision) {
            return Err(invalid(
                "Cancellation preparation is obsolete or conflicts with its fence",
            ));
        }
        exact_draft_current(&self.state, id, &draft)?;
        self.transact(|state| {
            state.drafts.insert(id.into(), draft);
            state.queued_cancellations.insert(id.into(), pending);
            state.version = state.version.max(3);
            Ok(())
        })
    }
    /// Settle only the exact Pending identity and operation revision.
    /// `source` is the latest draft used to compute `reconciled`, not a cached
    /// catalog snapshot. A newer postmerge autosave wins; newer held text needs
    /// reconciliation again. Never replace a live editor with the returned store.
    ///
    /// Returns false only when a strictly newer receipt already fences this
    /// completion, including an already settled retry. It performs no write in
    /// that case. Equal-revision different receipts and absent receipts are errors.
    pub fn settle_queued_cancel(
        &mut self,
        id: &str,
        expected: &QueuedCancelReceipt,
        source: &DraftRecord,
        reconciled: DraftRecord,
    ) -> Result<bool> {
        self.ensure_certain()?;
        require_chat(&self.state, id)?;
        expected.validate()?;
        let QueuedCancelState::Pending { edit_id, turn_id } = &expected.state else {
            return Err(invalid("Cancellation settlement requires Pending state"));
        };
        let existing = self
            .state
            .queued_cancellations
            .get(id)
            .ok_or_else(|| invalid("Cancellation has no saved receipt"))?;
        if existing.revision > expected.revision {
            return Ok(false);
        }
        if existing != expected {
            return Err(invalid(
                "Cancellation settlement conflicts with its saved receipt",
            ));
        }
        source.validate()?;
        reconciled.validate()?;
        if let Some(edit) = &source.queued_edit {
            if &edit.edit_id == edit_id {
                if &edit.turn_id != turn_id {
                    return Err(invalid(
                        "Cancellation reconciliation belongs to another queued turn",
                    ));
                }
                if reconciled.queued_edit.is_some()
                    || source.revision.checked_add(1) != Some(reconciled.revision)
                {
                    return Err(invalid(
                        "Cancellation reconciliation needs the next cleared draft revision",
                    ));
                }
            } else if source != &reconciled {
                return Err(invalid("Cancellation cannot change another queued edit"));
            }
        } else if source != &reconciled {
            return Err(invalid("An already reconciled draft must remain unchanged"));
        }
        let saved = self
            .state
            .drafts
            .get(id)
            .ok_or_else(|| invalid("Cancellation has no saved draft"))?;
        let preserve_newer = if saved.revision > reconciled.revision {
            if saved.queued_edit.is_some() {
                return Err(invalid(
                    "Newer queued draft needs cancellation reconciliation",
                ));
            }
            true
        } else if saved.revision == reconciled.revision {
            if saved != &reconciled {
                return Err(invalid("Draft revision conflicts with saved contents"));
            }
            true
        } else {
            if saved.revision > source.revision
                || (saved.revision == source.revision && saved != source)
            {
                return Err(invalid(
                    "Cancellation source conflicts with the saved draft",
                ));
            }
            false
        };
        let settled = QueuedCancelReceipt {
            revision: expected
                .revision
                .checked_add(1)
                .ok_or_else(|| invalid("Cancellation revision overflow"))?,
            state: QueuedCancelState::Settled,
        };
        self.transact(|state| {
            if !preserve_newer {
                state.drafts.insert(id.into(), reconciled);
            }
            state.queued_cancellations.insert(id.into(), settled);
            Ok(true)
        })
    }
    fn ensure_certain(&self) -> Result<()> {
        if self.uncertain {
            return Err(invalid(
                "Workspace persistence is uncertain. Reopen before continuing.",
            ));
        }
        Ok(())
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
        // All writers, including draft/queue recovery, preserve project and
        // connection bindings and explicit chat modes. Reading older files never rewrites them.
        state.version = state.version.max(CURRENT_VERSION);
        if state.show_archived
            || state.archive_visibility_revision != 0
            || state.chats.iter().any(|chat| chat.archived_at.is_some())
        {
            state.version = state.version.max(4);
        }
        if state
            .chats
            .iter()
            .any(|chat| chat.sidebar_order.is_some() || chat.pinned_at.is_some())
        {
            state.version = state.version.max(2);
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
fn is_false(value: &bool) -> bool {
    !value
}
fn is_zero(value: &u64) -> bool {
    *value == 0
}
fn require_chat(state: &WorkspaceSnapshot, id: &str) -> Result<()> {
    if !state.chats.iter().any(|chat| chat.id == id) {
        return Err(invalid("Draft has no saved chat"));
    }
    Ok(())
}
/// Return true only for equal revision and equal contents. Lower revisions and
/// equal-revision conflicts cannot serve as an exact-payload persistence barrier.
fn exact_draft_current(state: &WorkspaceSnapshot, id: &str, draft: &DraftRecord) -> Result<bool> {
    if let Some(saved) = state.drafts.get(id) {
        if saved.revision > draft.revision {
            return Err(invalid("Draft is older than the saved draft"));
        }
        if saved.revision == draft.revision {
            return if saved == draft {
                Ok(true)
            } else {
                Err(invalid("Draft revision conflicts with saved contents"))
            };
        }
    }
    Ok(false)
}
fn confirm_existing_catalog(path: &Path) -> Result<()> {
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|error| Error::PersistenceUncertain(error.to_string()))?;
    File::open(
        path.parent()
            .ok_or_else(|| invalid("Catalog needs a directory"))?,
    )
    .and_then(|directory| directory.sync_all())
    .map_err(|error| Error::PersistenceUncertain(error.to_string()))
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
    fn legacy_catalog_value(state: &WorkspaceSnapshot, version: u32) -> serde_json::Value {
        let mut value = serde_json::to_value(state).unwrap();
        value["version"] = version.into();
        if version < 6 {
            for chat in value["chats"].as_array_mut().unwrap() {
                chat.as_object_mut().unwrap().remove("connection_id");
            }
        }
        if version < 5 {
            value.as_object_mut().unwrap().remove("project_id");
            for chat in value["chats"].as_array_mut().unwrap() {
                chat.as_object_mut().unwrap().remove("tool_mode");
            }
        }
        value
    }
    fn fixture() -> (tempfile::TempDir, WorkspaceStore, ChatRecord) {
        let dir = tempfile::tempdir().unwrap();
        let store = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
        let id = Uuid::new_v4().to_string();
        let chat = ChatRecord {
            tool_mode: ChatToolMode::Editing,
            connection_id: None,
            sidebar_order: None,
            pinned_at: None,
            archived_at: None,
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
        assert_eq!(restored.version, CURRENT_VERSION);
        assert_eq!(restored.chats[0].pinned_at, Some(9));
        assert_eq!(restored.drafts[&chat.id], draft);
    }
    #[test]
    fn archive_repeated_state_preserves_timestamp_pin_order_and_bytes() {
        let (dir, mut store, mut chat) = fixture();
        chat.sidebar_order = Some(42);
        chat.pinned_at = Some(7);
        store.register(chat.clone(), held_draft(4)).unwrap();
        let saved = store
            .set_archived(chat.clone(), DraftRecord::default(), true, 0)
            .unwrap();
        assert!(saved.changed);
        assert_eq!(saved.record.archived_at, Some(0));
        assert_eq!(saved.record.pinned_at, Some(7));
        assert_eq!(saved.record.sidebar_order, Some(42));
        let path = dir.path().join("workspace.json");
        let before = fs::read(&path).unwrap();
        store.fault = Fault::BeforeRename;
        let repeated = store
            .set_archived(chat.clone(), DraftRecord::default(), true, 99)
            .unwrap();
        assert!(!repeated.changed);
        assert_eq!(repeated.record, saved.record);
        assert_eq!(fs::read(&path).unwrap(), before);
        store.fault = Fault::None;
        let restored = store
            .set_archived(chat.clone(), DraftRecord::default(), false, 100)
            .unwrap();
        assert!(restored.changed);
        assert_eq!(restored.record, chat);
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        let before = fs::read(&path).unwrap();
        store.fault = Fault::BeforeRename;
        assert!(
            !store
                .set_archived(chat, DraftRecord::default(), false, 101)
                .unwrap()
                .changed
        );
        assert_eq!(fs::read(&path).unwrap(), before);
    }
    #[test]
    fn archive_patches_only_metadata_and_preserves_pending_and_settled_receipts() {
        for settle in [false, true] {
            let (_dir, mut store, mut chat) = fixture();
            chat.sidebar_order = Some(4);
            let draft = held_draft(5);
            store.register(chat.clone(), draft.clone()).unwrap();
            store.name_chat(&chat.id, "new streamed title").unwrap();
            store
                .set_pinned(chat.clone(), DraftRecord::default(), true, 9)
                .unwrap();
            store.select(&chat.id, 30).unwrap();
            let pending = pending_cancel(0);
            store
                .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
                .unwrap();
            if settle {
                store
                    .settle_queued_cancel(&chat.id, &pending, &draft, reconciled(&draft))
                    .unwrap();
            }
            let mut intent = SubmissionIntent {
                id: Uuid::new_v4().to_string(),
                chat_id: chat.id.clone(),
                text: "retained receipt".into(),
                lane: Lane::FollowUp,
                draft_revision: 1,
            };
            store.begin_submission(intent.clone()).unwrap();
            store.acknowledge_submission(&intent.id).unwrap();
            intent.id = Uuid::new_v4().to_string();
            intent.draft_revision = 2;
            store.begin_submission(intent).unwrap();
            let mut expected = store.snapshot();
            expected.version = CURRENT_VERSION;
            expected.revision += 1;
            expected.chats[0].archived_at = Some(11);
            // A stale UI copy cannot undo newer pin/order/title or draft state.
            chat.sidebar_order = Some(100);
            let saved = store
                .set_archived(chat.clone(), DraftRecord::default(), true, 11)
                .unwrap();
            assert!(saved.changed);
            assert_eq!(saved.record, expected.chats[0]);
            assert_eq!(
                serde_json::to_value(store.snapshot()).unwrap(),
                serde_json::to_value(&expected).unwrap()
            );
            expected.revision += 1;
            expected.chats[0].archived_at = None;
            store
                .set_archived(chat, DraftRecord::default(), false, 12)
                .unwrap();
            assert_eq!(
                serde_json::to_value(store.snapshot()).unwrap(),
                serde_json::to_value(expected).unwrap()
            );
        }
    }
    #[test]
    fn archive_pending_materialization_is_atomic_without_transcript_and_can_retry() {
        let (dir, mut store, mut chat) = fixture();
        chat.sidebar_order = Some(42);
        chat.pinned_at = Some(9);
        let draft = held_draft(4);
        let before = serde_json::to_value(store.snapshot()).unwrap();
        let path = dir.path().join("workspace.json");
        store.fault = Fault::BeforeRename;
        assert!(
            store
                .set_archived(chat.clone(), draft.clone(), true, 7)
                .is_err()
        );
        assert!(!path.exists());
        assert!(!store.is_uncertain());
        assert_eq!(serde_json::to_value(store.snapshot()).unwrap(), before);
        assert!(!chat.snapshot.exists());
        assert!(!fs::read_dir(dir.path()).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".tmp")
        }));
        store.fault = Fault::AfterRename;
        assert!(matches!(
            store.set_archived(chat.clone(), draft.clone(), true, 7),
            Err(Error::PersistenceUncertain(_))
        ));
        assert!(store.is_uncertain());
        assert_eq!(serde_json::to_value(store.snapshot()).unwrap(), before);
        assert!(!chat.snapshot.exists());
        let bytes = fs::read(&path).unwrap();
        drop(store);
        let mut reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
        assert!(!reopened.is_uncertain());
        assert_eq!(reopened.snapshot().drafts[&chat.id], draft);
        assert_eq!(reopened.snapshot().chats[0].archived_at, Some(7));
        assert!(
            !reopened
                .set_archived(chat.clone(), DraftRecord::default(), true, 99)
                .unwrap()
                .changed
        );
        assert_eq!(fs::read(&path).unwrap(), bytes);
        assert!(!chat.snapshot.exists());
    }
    #[test]
    fn archive_restore_of_pending_active_chat_materializes_without_state_transition() {
        let (_dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        let result = store
            .set_archived(chat.clone(), draft.clone(), false, 7)
            .unwrap();
        assert!(!result.changed);
        assert_eq!(result.record, chat);
        assert_eq!(store.snapshot().drafts[&chat.id], draft);
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        assert!(!chat.snapshot.exists());
    }
    #[test]
    fn archive_and_restore_fault_boundaries_preserve_memory_until_confirmed_reopen() {
        for initial_archived in [false, true] {
            let (dir, mut store, chat) = fixture();
            let draft = held_draft(4);
            store.register(chat.clone(), draft.clone()).unwrap();
            if initial_archived {
                store
                    .set_archived(chat.clone(), draft.clone(), true, 1)
                    .unwrap();
            }
            let path = dir.path().join("workspace.json");
            let old_bytes = fs::read(&path).unwrap();
            let old_state = serde_json::to_value(store.snapshot()).unwrap();
            store.fault = Fault::BeforeRename;
            assert!(
                store
                    .set_archived(chat.clone(), draft.clone(), !initial_archived, 2)
                    .is_err()
            );
            assert!(!store.is_uncertain());
            assert_eq!(fs::read(&path).unwrap(), old_bytes);
            assert_eq!(serde_json::to_value(store.snapshot()).unwrap(), old_state);
            store.fault = Fault::AfterRename;
            assert!(matches!(
                store.set_archived(chat.clone(), draft.clone(), !initial_archived, 2),
                Err(Error::PersistenceUncertain(_))
            ));
            assert!(store.is_uncertain());
            assert_eq!(serde_json::to_value(store.snapshot()).unwrap(), old_state);
            let committed_bytes = fs::read(&path).unwrap();
            assert_ne!(committed_bytes, old_bytes);
            // Even an apparent no-op against the stale in-memory state is refused.
            assert!(matches!(
                store.set_archived(chat.clone(), draft.clone(), initial_archived, 3),
                Err(Error::Invalid(_))
            ));
            drop(store);
            assert!(matches!(
                WorkspaceStore::open_with_confirmation(&path, dir.path(), |_| Err(
                    Error::PersistenceUncertain("confirmation failed".into())
                )),
                Err(Error::PersistenceUncertain(_))
            ));
            assert_eq!(fs::read(&path).unwrap(), committed_bytes);
            let mut reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
            assert_eq!(reopened.snapshot().version, CURRENT_VERSION);
            assert_eq!(
                reopened.snapshot().chats[0].archived_at,
                if initial_archived { None } else { Some(2) }
            );
            assert_eq!(reopened.snapshot().drafts[&chat.id], draft);
            assert!(
                !reopened
                    .set_archived(chat, draft, !initial_archived, 3)
                    .unwrap()
                    .changed
            );
            assert_eq!(fs::read(&path).unwrap(), committed_bytes);
        }
    }
    #[test]
    fn archive_uncertainty_refuses_every_mutation_including_noop_and_stale_paths() {
        let (dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        let pending = pending_cancel(0);
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        let intent = SubmissionIntent {
            id: Uuid::new_v4().to_string(),
            chat_id: chat.id.clone(),
            text: "receipt".into(),
            lane: Lane::FollowUp,
            draft_revision: 1,
        };
        store.begin_submission(intent.clone()).unwrap();
        store.select(&chat.id, 1).unwrap();
        store.fault = Fault::AfterRename;
        assert!(matches!(
            store.set_archived(chat.clone(), draft.clone(), true, 7),
            Err(Error::PersistenceUncertain(_))
        ));
        let path = dir.path().join("workspace.json");
        let bytes = fs::read(&path).unwrap();
        let state = serde_json::to_value(store.snapshot()).unwrap();
        store.fault = Fault::None;
        assert!(matches!(
            store.set_archived(chat.clone(), draft.clone(), false, 0),
            Err(Error::Invalid(_))
        ));
        assert!(store.set_archive_visibility(false, 0).is_err());
        assert!(store.set_archive_visibility(true, 1).is_err());
        assert!(store.register(chat.clone(), draft.clone()).is_err());
        assert!(store.name_chat(&chat.id, "no mutation").is_err());
        assert!(
            store
                .set_pinned(chat.clone(), draft.clone(), false, 0)
                .is_err()
        );
        assert!(store.save_draft(&chat.id, draft.clone()).is_err());
        assert!(store.flush_draft_exact(&chat.id, draft.clone()).is_err());
        assert!(
            store
                .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
                .is_err()
        );
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &draft, reconciled(&draft))
                .is_err()
        );
        assert!(store.select(&chat.id, 0).is_err());
        assert!(store.begin_submission(intent.clone()).is_err());
        assert!(
            store
                .save_submitting_draft(chat.clone(), draft.clone(), intent.clone())
                .is_err()
        );
        assert!(store.acknowledge_submission(&intent.id).is_err());
        assert!(
            store
                .withdraw_submission(&intent.id, draft.clone())
                .is_err()
        );
        assert!(store.settle_rejected(chat, intent, draft).is_err());
        assert!(store.is_uncertain());
        assert_eq!(serde_json::to_value(store.snapshot()).unwrap(), state);
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }
    #[test]
    fn archive_visibility_exact_revision_fence_is_independent_and_monotonic() {
        let (dir, mut store, chat) = fixture();
        store.register(chat.clone(), held_draft(4)).unwrap();
        store.select(&chat.id, 7).unwrap();
        let path = dir.path().join("workspace.json");
        assert!(store.set_archive_visibility(true, 1000).unwrap());
        let state = store.snapshot();
        assert_eq!(state.version, CURRENT_VERSION);
        assert!(state.archive_visibility_revision > state.revision);
        assert_eq!(state.selection_revision, 7);
        assert_eq!(state.chats, vec![chat.clone()]);
        let bytes = fs::read(&path).unwrap();
        store.fault = Fault::BeforeRename;
        assert!(!store.set_archive_visibility(false, 999).unwrap());
        assert!(store.set_archive_visibility(true, 1000).unwrap());
        assert!(store.set_archive_visibility(false, 1000).is_err());
        assert_eq!(fs::read(&path).unwrap(), bytes);
        store.fault = Fault::None;
        assert!(store.set_archive_visibility(false, 1002).unwrap());
        assert!(!store.set_archive_visibility(true, 1001).unwrap());
        assert!(store.set_archive_visibility(false, u64::MAX).unwrap());
        assert!(
            store
                .snapshot()
                .archive_visibility_revision
                .checked_add(1)
                .is_none()
        );
        assert!(store.set_archive_visibility(true, u64::MAX).is_err());
        let before = fs::read(&path).unwrap();
        drop(store);
        let mut reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
        assert_eq!(reopened.snapshot().version, CURRENT_VERSION);
        assert!(!reopened.snapshot().show_archived);
        assert_eq!(reopened.snapshot().archive_visibility_revision, u64::MAX);
        assert_eq!(reopened.snapshot().chats, vec![chat]);
        assert!(reopened.set_archive_visibility(false, u64::MAX).unwrap());
        assert_eq!(fs::read(&path).unwrap(), before);
    }
    #[test]
    fn archive_visibility_fault_boundaries_require_confirmed_reopen() {
        for initial_shown in [false, true] {
            let (dir, mut store, chat) = fixture();
            store.register(chat.clone(), held_draft(4)).unwrap();
            store.set_archive_visibility(initial_shown, 1).unwrap();
            let path = dir.path().join("workspace.json");
            let old_bytes = fs::read(&path).unwrap();
            let old_state = serde_json::to_value(store.snapshot()).unwrap();
            store.fault = Fault::BeforeRename;
            assert!(store.set_archive_visibility(!initial_shown, 2).is_err());
            assert!(!store.is_uncertain());
            assert_eq!(serde_json::to_value(store.snapshot()).unwrap(), old_state);
            assert_eq!(fs::read(&path).unwrap(), old_bytes);
            store.fault = Fault::AfterRename;
            assert!(matches!(
                store.set_archive_visibility(!initial_shown, 2),
                Err(Error::PersistenceUncertain(_))
            ));
            assert!(store.is_uncertain());
            assert_eq!(serde_json::to_value(store.snapshot()).unwrap(), old_state);
            assert!(store.set_archive_visibility(initial_shown, 1).is_err());
            assert!(store.set_archive_visibility(false, 0).is_err());
            let bytes = fs::read(&path).unwrap();
            drop(store);
            assert!(
                WorkspaceStore::open_with_confirmation(&path, dir.path(), |_| Err(
                    Error::PersistenceUncertain("unconfirmed".into())
                ))
                .is_err()
            );
            assert_eq!(fs::read(&path).unwrap(), bytes);
            let mut reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
            assert_eq!(reopened.snapshot().show_archived, !initial_shown);
            assert_eq!(reopened.snapshot().archive_visibility_revision, 2);
            assert_eq!(reopened.snapshot().chats, vec![chat]);
            assert!(reopened.set_archive_visibility(!initial_shown, 2).unwrap());
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
    }
    #[test]
    fn archive_old_versions_open_without_rewrite_then_promote_only_on_mutation() {
        for version in [1, 2, 3] {
            let (dir, mut store, chat) = fixture();
            store.register(chat.clone(), held_draft(4)).unwrap();
            let value = legacy_catalog_value(&store.snapshot(), version);
            assert!(value.get("show_archived").is_none());
            assert!(value.get("archive_visibility_revision").is_none());
            assert!(value["chats"][0].get("archived_at").is_none());
            let path = dir.path().join("workspace.json");
            drop(store);
            let bytes =
                format!(" \n{}\n  ", serde_json::to_string_pretty(&value).unwrap()).into_bytes();
            fs::write(&path, &bytes).unwrap();
            let mut reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
            assert_eq!(reopened.snapshot().version, version);
            assert!(!reopened.snapshot().show_archived);
            assert_eq!(reopened.snapshot().archive_visibility_revision, 0);
            assert!(
                !reopened
                    .set_archived(chat.clone(), DraftRecord::default(), false, 1)
                    .unwrap()
                    .changed
            );
            assert!(reopened.set_archive_visibility(false, 0).unwrap());
            assert_eq!(fs::read(&path).unwrap(), bytes);
            reopened
                .set_archived(chat.clone(), DraftRecord::default(), true, 2)
                .unwrap();
            assert_eq!(reopened.snapshot().version, CURRENT_VERSION);
            reopened
                .set_archived(chat, DraftRecord::default(), false, 3)
                .unwrap();
            assert_eq!(reopened.snapshot().version, CURRENT_VERSION);
            reopened.set_archive_visibility(true, 10).unwrap();
            reopened.set_archive_visibility(false, 11).unwrap();
            assert_eq!(reopened.snapshot().version, CURRENT_VERSION);
        }
    }
    #[test]
    fn archive_malformed_metadata_and_future_versions_fail_before_confirmation() {
        use serde_json::{Value, json};
        let (dir, mut store, chat) = fixture();
        store.register(chat, held_draft(4)).unwrap();
        let base_state = store.snapshot();
        let base = serde_json::to_value(&base_state).unwrap();
        let path = dir.path().join("workspace.json");
        drop(store);
        let mut cases: Vec<Value> = Vec::new();
        for version in [1, 2, 3] {
            for field in [
                "archived_at",
                "show_archived",
                "archive_visibility_revision",
            ] {
                let mut value = legacy_catalog_value(&base_state, version);
                match field {
                    "archived_at" => value["chats"][0][field] = json!(0),
                    "show_archived" => value[field] = json!(true),
                    _ => value[field] = json!(1),
                }
                cases.push(value);
            }
        }
        for version in [0, CURRENT_VERSION + 1, u32::MAX] {
            let mut value = base.clone();
            value["version"] = version.into();
            cases.push(value);
        }
        for (field, values) in [
            (
                "archived_at",
                vec![
                    json!(-1),
                    json!("1"),
                    json!(true),
                    json!([]),
                    json!({}),
                    json!(1.5),
                ],
            ),
            (
                "show_archived",
                vec![json!(null), json!(1), json!("true"), json!([])],
            ),
            (
                "archive_visibility_revision",
                vec![json!(null), json!(-1), json!("1"), json!(1.5)],
            ),
        ] {
            for invalid in values {
                let mut value = legacy_catalog_value(&base_state, 4);
                if field == "archived_at" {
                    value["chats"][0][field] = invalid;
                } else {
                    value[field] = invalid;
                }
                cases.push(value);
            }
        }
        for (index, value) in cases.into_iter().enumerate() {
            let bytes =
                format!(" \n{}\n  ", serde_json::to_string_pretty(&value).unwrap()).into_bytes();
            fs::write(&path, &bytes).unwrap();
            assert!(
                WorkspaceStore::open_with_confirmation(&path, dir.path(), |_| panic!(
                    "invalid archive catalog {index} reached confirmation"
                ))
                .is_err()
            );
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
    }
    #[test]
    fn archive_identity_validation_and_catalog_overflow_preserve_exact_bytes() {
        let (dir, mut store, chat) = fixture();
        store.register(chat.clone(), held_draft(4)).unwrap();
        let path = dir.path().join("workspace.json");
        let before = fs::read(&path).unwrap();
        let mut wrong = chat.clone();
        wrong.snapshot = dir.path().join("other.json");
        for archived in [false, true] {
            assert!(
                store
                    .set_archived(wrong.clone(), DraftRecord::default(), archived, 1)
                    .is_err()
            );
        }
        for case in 0..3 {
            let mut pending = chat.clone();
            pending.id = Uuid::new_v4().to_string();
            match case {
                0 => pending.snapshot = PathBuf::from("relative.json"),
                1 => pending.id = "invalid-identity".into(),
                _ => pending.title = "x".repeat(513),
            }
            assert!(store.set_archived(pending, held_draft(4), true, 1).is_err());
        }
        let mut pending = chat.clone();
        pending.id = Uuid::new_v4().to_string();
        let oversized = DraftRecord {
            text: "x".repeat(MAX_DRAFT_BYTES + 1),
            ..DraftRecord::default()
        };
        assert!(
            store
                .set_archived(pending, oversized.clone(), true, 1)
                .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), before);
        // Existing draft data, rather than a stale caller's draft, is authoritative.
        assert!(
            !store
                .set_archived(chat.clone(), oversized, false, 1)
                .unwrap()
                .changed
        );
        let mut state = store.snapshot();
        state.revision = u64::MAX;
        drop(store);
        let before = serde_json::to_vec(&state).unwrap();
        fs::write(&path, &before).unwrap();
        let mut store = WorkspaceStore::open(&path, dir.path()).unwrap();
        assert!(
            store
                .set_archived(chat, DraftRecord::default(), true, 1)
                .is_err()
        );
        assert!(store.set_archive_visibility(true, 1).is_err());
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        assert_eq!(fs::read(&path).unwrap(), before);
        assert!(!store.is_uncertain());
    }
    #[test]
    fn archive_pending_success_retains_draft_pin_and_capacity_rejects_new_record() {
        let (dir, mut store, mut chat) = fixture();
        chat.pinned_at = Some(3);
        chat.sidebar_order = Some(7);
        let draft = held_draft(4);
        store.fault = Fault::BeforeRename;
        assert!(
            store
                .set_archived(chat.clone(), draft.clone(), true, 9)
                .is_err()
        );
        store.fault = Fault::None;
        let saved = store
            .set_archived(chat.clone(), draft.clone(), true, 9)
            .unwrap();
        assert!(saved.changed);
        assert_eq!(saved.record.pinned_at, Some(3));
        assert_eq!(saved.record.sidebar_order, Some(7));
        assert_eq!(store.snapshot().drafts[&chat.id], draft);
        assert!(!chat.snapshot.exists());
        let mut state = store.snapshot();
        for _ in 1..MAX_CHATS {
            let id = Uuid::new_v4().to_string();
            state.chats.push(ChatRecord::new(
                id.clone(),
                "saved".into(),
                store.chat_path(&id).unwrap(),
            ));
        }
        let path = dir.path().join("workspace.json");
        drop(store);
        let bytes = serde_json::to_vec(&state).unwrap();
        fs::write(&path, &bytes).unwrap();
        let mut reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
        let id = Uuid::new_v4().to_string();
        let pending = ChatRecord::new(
            id.clone(),
            "pending".into(),
            reopened.chat_path(&id).unwrap(),
        );
        assert!(
            reopened
                .set_archived(pending, draft.clone(), true, 10)
                .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), bytes);
        assert!(
            reopened
                .set_archived(chat.clone(), DraftRecord::default(), false, 10)
                .unwrap()
                .changed
        );
        assert_eq!(reopened.snapshot().drafts[&chat.id], draft);
    }
    #[test]
    fn archive_metadata_survives_every_existing_writer_including_cancel_preparation() {
        let (dir, mut store, mut chat) = fixture();
        let project_id = Uuid::new_v4().to_string();
        // A previously bound v5 fixture; ordinary metadata writers must keep
        // its exact identity and mode without borrowing a stale UI copy.
        store.state.version = CURRENT_VERSION;
        store.state.project_id = Some(project_id.clone());
        chat.tool_mode = ChatToolMode::ReadOnly;
        let draft = held_draft(4);
        store
            .set_archived(chat.clone(), draft.clone(), true, 1)
            .unwrap();
        // A delayed ordinary UI row cannot broaden a retained read-only chat
        // while pin/archive/submission/draft operations patch other metadata.
        chat.tool_mode = ChatToolMode::Editing;
        store
            .set_archived(chat.clone(), draft.clone(), false, 2)
            .unwrap();
        store
            .register(chat.clone(), DraftRecord::default())
            .unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        store.name_chat(&chat.id, "renamed").unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        store
            .set_pinned(chat.clone(), DraftRecord::default(), true, 3)
            .unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        store.select(&chat.id, 2).unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        let pending = pending_cancel(0);
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        let merged = reconciled(&draft);
        store
            .settle_queued_cancel(&chat.id, &pending, &draft, merged.clone())
            .unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        let later = DraftRecord {
            revision: merged.revision + 1,
            text: "later".into(),
            queued_edit: None,
        };
        store.save_draft(&chat.id, later.clone()).unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        store
            .flush_draft_exact(
                &chat.id,
                DraftRecord {
                    revision: later.revision + 1,
                    ..later.clone()
                },
            )
            .unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        let mut intent = SubmissionIntent {
            id: Uuid::new_v4().to_string(),
            chat_id: chat.id.clone(),
            text: "send".into(),
            lane: Lane::FollowUp,
            draft_revision: 1,
        };
        store.begin_submission(intent.clone()).unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        store.acknowledge_submission(&intent.id).unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        intent.id = Uuid::new_v4().to_string();
        intent.draft_revision = 2;
        store
            .save_submitting_draft(chat.clone(), later.clone(), intent.clone())
            .unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        store
            .withdraw_submission(&intent.id, later.clone())
            .unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        intent.id = Uuid::new_v4().to_string();
        intent.draft_revision = 3;
        store.settle_rejected(chat.clone(), intent, later).unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        store.set_archive_visibility(true, 20).unwrap();
        store.set_archive_visibility(false, 21).unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        drop(store);
        let reopened = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
        assert_eq!(reopened.snapshot().version, CURRENT_VERSION);
        assert_eq!(reopened.snapshot().chats[0].archived_at, None);
        assert_eq!(reopened.snapshot().chats[0].pinned_at, Some(3));
        assert_eq!(reopened.snapshot().archive_visibility_revision, 21);
        assert_eq!(reopened.snapshot().project_id, Some(project_id));
        assert_eq!(
            reopened.snapshot().chats[0].tool_mode,
            ChatToolMode::ReadOnly
        );
    }
    #[test]
    fn lock_and_project_binding_are_checked() {
        let (dir, _store, _) = fixture();
        assert!(WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).is_err());
    }
    fn held_draft(revision: u64) -> DraftRecord {
        DraftRecord {
            revision,
            text: "displaced draft".into(),
            queued_edit: Some(QueuedDraft {
                edit_id: "cancel-this-edit".into(),
                turn_id: "cancel-this-turn".into(),
                rewrite: "unsaved rewrite".into(),
                original_text: Some("original".into()),
            }),
        }
    }
    fn pending_cancel(previous_revision: u64) -> QueuedCancelReceipt {
        QueuedCancelReceipt::pending(
            previous_revision,
            "cancel-this-edit".into(),
            "cancel-this-turn".into(),
        )
        .unwrap()
    }
    fn reconciled(source: &DraftRecord) -> DraftRecord {
        let mut next = source.clone();
        next.reconcile_queued_status(&crate::QueueEditStatus {
            edit_id: source.queued_edit.as_ref().unwrap().edit_id.clone(),
            state: crate::QueueEditState::Cancelled,
            current_hold: None,
            session_revision: 1,
        })
        .unwrap();
        next
    }
    fn state_bytes(store: &WorkspaceStore) -> Vec<u8> {
        serde_json::to_vec(&store.snapshot()).unwrap()
    }
    #[test]
    fn cancellation_prepare_is_atomic_at_real_rename_boundaries_and_reopen_confirms() {
        for (fault, committed) in [(Fault::BeforeRename, false), (Fault::AfterRename, true)] {
            let (dir, mut store, chat) = fixture();
            let initial = held_draft(4);
            store.register(chat.clone(), initial.clone()).unwrap();
            let path = dir.path().join("workspace.json");
            let old_bytes = fs::read(&path).unwrap();
            let before = state_bytes(&store);
            let mut latest = initial.clone();
            latest.revision += 1;
            latest
                .queued_edit
                .as_mut()
                .unwrap()
                .rewrite
                .push_str(" latest");
            let pending = pending_cancel(0);
            store.fault = fault;
            let error = store
                .prepare_queued_cancel(&chat.id, pending.clone(), latest.clone())
                .unwrap_err();
            assert_eq!(matches!(error, Error::PersistenceUncertain(_)), committed);
            assert_eq!(state_bytes(&store), before);
            if committed {
                store.fault = Fault::None;
                assert!(
                    store
                        .prepare_queued_cancel(&chat.id, pending.clone(), latest.clone())
                        .is_err()
                );
                assert!(store.flush_draft_exact(&chat.id, initial.clone()).is_err());
                assert!(
                    store
                        .settle_queued_cancel(&chat.id, &pending, &latest, reconciled(&latest))
                        .is_err()
                );
            } else {
                assert_eq!(fs::read(&path).unwrap(), old_bytes);
            }
            drop(store);
            let retained = fs::read(&path).unwrap();
            let confirmed = std::cell::Cell::new(false);
            let reopened = WorkspaceStore::open_with_confirmation(&path, dir.path(), |existing| {
                assert_eq!(fs::read(existing).unwrap(), retained);
                confirm_existing_catalog(existing)?;
                confirmed.set(true);
                Ok(())
            })
            .unwrap();
            assert!(confirmed.get());
            assert_eq!(
                reopened.snapshot().drafts[&chat.id],
                if committed { latest } else { initial }
            );
            assert_eq!(
                reopened.snapshot().queued_cancellations.get(&chat.id),
                committed.then_some(&pending)
            );
            assert_eq!(fs::read(&path).unwrap(), retained);
        }
    }
    #[test]
    fn cancellation_settlement_is_atomic_at_real_rename_boundaries() {
        for (fault, committed) in [(Fault::BeforeRename, false), (Fault::AfterRename, true)] {
            let (dir, mut store, chat) = fixture();
            let draft = held_draft(4);
            store.register(chat.clone(), draft.clone()).unwrap();
            let pending = pending_cancel(0);
            store
                .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
                .unwrap();
            let path = dir.path().join("workspace.json");
            let old_bytes = fs::read(&path).unwrap();
            let before = state_bytes(&store);
            let merged = reconciled(&draft);
            store.fault = fault;
            let error = store
                .settle_queued_cancel(&chat.id, &pending, &draft, merged.clone())
                .unwrap_err();
            assert_eq!(matches!(error, Error::PersistenceUncertain(_)), committed);
            assert_eq!(state_bytes(&store), before);
            if committed {
                store.fault = Fault::None;
                assert!(
                    store
                        .settle_queued_cancel(&chat.id, &pending, &draft, merged.clone())
                        .is_err()
                );
                assert!(
                    store
                        .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
                        .is_err()
                );
                assert!(store.save_draft(&chat.id, merged.clone()).is_err());
            } else {
                assert_eq!(fs::read(&path).unwrap(), old_bytes);
            }
            drop(store);
            let mut reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
            assert_eq!(
                reopened.snapshot().drafts[&chat.id],
                if committed {
                    merged.clone()
                } else {
                    draft.clone()
                }
            );
            assert_eq!(
                reopened.snapshot().queued_cancellations[&chat.id],
                if committed {
                    QueuedCancelReceipt {
                        revision: 2,
                        state: QueuedCancelState::Settled,
                    }
                } else {
                    pending.clone()
                }
            );
            assert_eq!(
                reopened
                    .settle_queued_cancel(&chat.id, &pending, &draft, merged)
                    .unwrap(),
                !committed
            );
            assert!(
                reopened
                    .prepare_queued_cancel(&chat.id, pending, draft.clone())
                    .is_err()
            );
        }
    }
    #[test]
    fn existing_catalog_confirmation_is_required_without_opening_rewrite_for_all_versions() {
        for version in [1, 2, 3, 4, 5] {
            let (dir, mut store, chat) = fixture();
            let draft = held_draft(4);
            store.register(chat.clone(), draft.clone()).unwrap();
            if version >= 3 {
                store
                    .prepare_queued_cancel(&chat.id, pending_cancel(0), draft.clone())
                    .unwrap();
            }
            if version >= 4 {
                store
                    .set_archived(chat.clone(), draft.clone(), true, 0)
                    .unwrap();
                store.set_archive_visibility(true, 100).unwrap();
            }
            let mut state = store.snapshot();
            state.version = version;
            let mut value = legacy_catalog_value(&state, version);
            if version < 3 {
                value
                    .as_object_mut()
                    .unwrap()
                    .remove("queued_cancellations");
            }
            let path = dir.path().join("workspace.json");
            drop(store);
            let bytes =
                format!(" \n{}\n  ", serde_json::to_string_pretty(&value).unwrap()).into_bytes();
            fs::write(&path, &bytes).unwrap();
            for fail_after_file_sync in [false, true] {
                let result =
                    WorkspaceStore::open_with_confirmation(&path, dir.path(), |existing| {
                        assert_eq!(fs::read(existing).unwrap(), bytes);
                        if fail_after_file_sync {
                            File::open(existing)?.sync_all()?;
                        }
                        Err(Error::PersistenceUncertain(
                            "injected confirmation failure".into(),
                        ))
                    });
                assert!(matches!(result, Err(Error::PersistenceUncertain(_))));
                assert_eq!(fs::read(&path).unwrap(), bytes);
            }
            let confirmed = std::cell::Cell::new(false);
            let reopened = WorkspaceStore::open_with_confirmation(&path, dir.path(), |existing| {
                confirm_existing_catalog(existing)?;
                confirmed.set(true);
                Ok(())
            })
            .unwrap();
            assert!(confirmed.get());
            assert_eq!(reopened.snapshot().version, version);
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
        let dir = tempfile::tempdir().unwrap();
        let store = WorkspaceStore::open_with_confirmation(
            &dir.path().join("missing.json"),
            dir.path(),
            |_| panic!("pending workspace has no existing file to confirm"),
        )
        .unwrap();
        assert!(store.snapshot().chats.is_empty());
        assert!(matches!(
            confirm_existing_catalog(&dir.path().join("missing.json")),
            Err(Error::PersistenceUncertain(_))
        ));
    }
    #[test]
    fn cancel_receipt_fence_and_draft_fence_remain_independent_across_retries() {
        let (dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        let pending = pending_cancel(0);
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        let bytes = fs::read(dir.path().join("workspace.json")).unwrap();
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        store.flush_draft_exact(&chat.id, draft.clone()).unwrap();
        assert_eq!(fs::read(dir.path().join("workspace.json")).unwrap(), bytes);
        let merged = reconciled(&draft);
        store.save_draft(&chat.id, merged.clone()).unwrap();
        let newer = DraftRecord {
            revision: merged.revision + 1,
            text: "new postmerge typing".into(),
            queued_edit: None,
        };
        store.save_draft(&chat.id, newer.clone()).unwrap();
        assert_eq!(store.snapshot().queued_cancellations[&chat.id], pending);
        // Exact persisted Pending still authorizes an idempotent actor retry,
        // even after autosave has independently persisted reconciled/newer text.
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &draft, merged.clone())
                .unwrap()
        );
        assert_eq!(store.snapshot().drafts[&chat.id], newer);
        assert!(!store.save_draft(&chat.id, draft.clone()).unwrap());
        let after = state_bytes(&store);
        assert!(
            !store
                .settle_queued_cancel(&chat.id, &pending, &draft, merged)
                .unwrap()
        );
        assert!(
            store
                .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
                .is_err()
        );
        // A delayed prepare with a freshly captured current draft must still
        // fail on the operation fence, independently of the draft revision.
        assert!(
            store
                .prepare_queued_cancel(&chat.id, pending.clone(), newer.clone())
                .is_err()
        );
        assert_eq!(state_bytes(&store), after);
        let mut next = held_draft(newer.revision + 1);
        next.queued_edit.as_mut().unwrap().edit_id = "second-operation".into();
        let next_pending =
            QueuedCancelReceipt::pending(2, "second-operation".into(), "cancel-this-turn".into())
                .unwrap();
        store
            .prepare_queued_cancel(&chat.id, next_pending.clone(), next.clone())
            .unwrap();
        assert!(
            !store
                .settle_queued_cancel(&chat.id, &pending, &draft, reconciled(&draft))
                .unwrap()
        );
        assert_eq!(
            store.snapshot().queued_cancellations[&chat.id],
            next_pending
        );
        assert_eq!(store.snapshot().drafts[&chat.id], next);
    }
    #[test]
    fn exact_flush_and_cancel_reject_equal_revision_different_contents_without_writes() {
        let (dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        let path = dir.path().join("workspace.json");
        let before = fs::read(&path).unwrap();
        let mut conflicting = draft.clone();
        conflicting.text = "same revision but another payload".into();
        assert!(
            store
                .flush_draft_exact(&chat.id, conflicting.clone())
                .is_err()
        );
        assert!(
            store
                .prepare_queued_cancel(&chat.id, pending_cancel(0), conflicting.clone())
                .is_err()
        );
        let mut old = draft.clone();
        old.revision -= 1;
        assert!(store.flush_draft_exact(&chat.id, old.clone()).is_err());
        assert!(
            store
                .prepare_queued_cancel(&chat.id, pending_cancel(0), old.clone())
                .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), before);
        let pending = pending_cancel(0);
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        let mut actual = reconciled(&draft);
        actual.text.push_str(" different");
        store.save_draft(&chat.id, actual.clone()).unwrap();
        let before = fs::read(&path).unwrap();
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &draft, reconciled(&draft))
                .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), before);
        assert_eq!(store.snapshot().drafts[&chat.id], actual);
        assert_eq!(store.snapshot().queued_cancellations[&chat.id], pending);
    }
    #[test]
    fn newer_held_draft_must_be_reconciled_before_cancellation_can_settle() {
        let (dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        let pending = pending_cancel(0);
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        let mut latest = held_draft(7);
        latest.queued_edit.as_mut().unwrap().rewrite = "latest unsaved rewrite".into();
        store.save_draft(&chat.id, latest.clone()).unwrap();
        let before = fs::read(dir.path().join("workspace.json")).unwrap();
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &draft, reconciled(&draft))
                .is_err()
        );
        assert_eq!(fs::read(dir.path().join("workspace.json")).unwrap(), before);
        let merged = reconciled(&latest);
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &latest, merged.clone())
                .unwrap()
        );
        assert_eq!(store.snapshot().drafts[&chat.id], merged);
    }
    #[test]
    fn settlement_accepts_an_exact_already_reconciled_source_and_validates_the_whole_merge() {
        let (_dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        let pending = pending_cancel(0);
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        let before = state_bytes(&store);
        let mut invalid = reconciled(&draft);
        invalid.text = "x".repeat(MAX_DRAFT_BYTES + 1);
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &draft, invalid)
                .is_err()
        );
        let mut overflow = draft.clone();
        overflow.revision = u64::MAX;
        assert!(
            store
                .settle_queued_cancel(
                    &chat.id,
                    &pending,
                    &overflow,
                    DraftRecord {
                        revision: 0,
                        text: String::new(),
                        queued_edit: None
                    }
                )
                .is_err()
        );
        assert_eq!(state_bytes(&store), before);
        let merged = reconciled(&draft);
        store.save_draft(&chat.id, merged.clone()).unwrap();
        let mut different = merged.clone();
        different.text.push_str(" changed without a new revision");
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &merged, different)
                .is_err()
        );
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &merged, merged.clone())
                .unwrap()
        );
        assert_eq!(store.snapshot().drafts[&chat.id], merged);
    }
    #[test]
    fn cancel_revision_allocation_and_catalog_overflow_leave_original_recovery_material() {
        let (dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        assert!(QueuedCancelReceipt::pending(u64::MAX, "edit".into(), "turn".into()).is_err());
        assert!(QueuedCancelReceipt::pending(u64::MAX - 1, "edit".into(), "turn".into()).is_err());
        let path = dir.path().join("workspace.json");
        let mut state = store.snapshot();
        state.revision = u64::MAX;
        state.version = CURRENT_VERSION;
        state.queued_cancellations.insert(
            chat.id.clone(),
            QueuedCancelReceipt {
                revision: u64::MAX - 1,
                state: QueuedCancelState::Settled,
            },
        );
        drop(store);
        let bytes = serde_json::to_vec(&state).unwrap();
        fs::write(&path, &bytes).unwrap();
        let mut store = WorkspaceStore::open(&path, dir.path()).unwrap();
        assert!(
            store
                .prepare_queued_cancel(
                    &chat.id,
                    QueuedCancelReceipt {
                        revision: u64::MAX,
                        state: QueuedCancelState::Pending {
                            edit_id: "cancel-this-edit".into(),
                            turn_id: "cancel-this-turn".into()
                        }
                    },
                    draft.clone()
                )
                .is_err()
        );
        let mut later = draft;
        later.revision += 1;
        assert!(store.flush_draft_exact(&chat.id, later).is_err());
        assert_eq!(fs::read(&path).unwrap(), bytes);
        assert_eq!(state_bytes(&store), serde_json::to_vec(&state).unwrap());
    }
    #[test]
    fn wrong_cancel_identity_revision_payload_and_unknown_chat_never_mutate_catalog() {
        let (dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        let pending = pending_cancel(0);
        assert!(
            store
                .prepare_queued_cancel("unknown-chat", pending.clone(), draft.clone())
                .is_err()
        );
        assert!(
            store
                .flush_draft_exact("unknown-chat", draft.clone())
                .is_err()
        );
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        let before = fs::read(dir.path().join("workspace.json")).unwrap();
        for change in ["edit", "turn", "revision"] {
            let mut wrong = pending.clone();
            match &mut wrong.state {
                QueuedCancelState::Pending { edit_id, turn_id } => match change {
                    "edit" => *edit_id = "different".into(),
                    "turn" => *turn_id = "different".into(),
                    _ => wrong.revision += 1,
                },
                _ => unreachable!(),
            }
            assert!(
                store
                    .prepare_queued_cancel(&chat.id, wrong.clone(), draft.clone())
                    .is_err()
            );
            assert!(
                store
                    .settle_queued_cancel(&chat.id, &wrong, &draft, reconciled(&draft))
                    .is_err()
            );
        }
        let mut wrong_draft = draft.clone();
        wrong_draft.queued_edit.as_mut().unwrap().turn_id = "different-turn".into();
        assert!(
            store
                .prepare_queued_cancel(&chat.id, pending.clone(), wrong_draft)
                .is_err()
        );
        assert!(
            store
                .settle_queued_cancel("unknown-chat", &pending, &draft, reconciled(&draft))
                .is_err()
        );
        assert_eq!(fs::read(dir.path().join("workspace.json")).unwrap(), before);
    }
    #[test]
    fn catalog_promotion_is_monotonic_and_other_transactions_preserve_cancel_receipts() {
        let (dir, mut store, mut chat) = fixture();
        chat.sidebar_order = Some(9);
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        let pending = pending_cancel(0);
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        store.name_chat(&chat.id, "renamed").unwrap();
        store.select(&chat.id, 3).unwrap();
        store
            .set_pinned(chat.clone(), DraftRecord::default(), true, 1)
            .unwrap();
        let intent = SubmissionIntent {
            id: Uuid::new_v4().to_string(),
            chat_id: chat.id.clone(),
            text: "another retained send".into(),
            lane: Lane::FollowUp,
            draft_revision: 1,
        };
        store.begin_submission(intent.clone()).unwrap();
        store.acknowledge_submission(&intent.id).unwrap();
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        assert_eq!(store.snapshot().queued_cancellations[&chat.id], pending);
        let merged = reconciled(&draft);
        store
            .settle_queued_cancel(&chat.id, &pending, &draft, merged.clone())
            .unwrap();
        let settled = store.snapshot().queued_cancellations[&chat.id].clone();
        let later = DraftRecord {
            revision: merged.revision + 1,
            text: "later".into(),
            queued_edit: None,
        };
        store.save_draft(&chat.id, later.clone()).unwrap();
        store
            .save_submitting_draft(chat.clone(), later, intent.clone())
            .unwrap();
        store.name_chat(&chat.id, "renamed again").unwrap();
        assert!(store.snapshot().intents.is_empty());
        assert_eq!(
            store.snapshot().settled_submissions[&chat.id],
            intent.draft_revision
        );
        assert_eq!(store.snapshot().queued_cancellations[&chat.id], settled);
        drop(store);
        let reopened = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
        assert_eq!(reopened.snapshot().version, CURRENT_VERSION);
        assert_eq!(reopened.snapshot().queued_cancellations[&chat.id], settled);
    }

    #[test]
    fn malformed_cancel_receipts_fail_before_confirmation_and_preserve_exact_bytes() {
        use serde_json::{Value, json};
        let (dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        store
            .prepare_queued_cancel(&chat.id, pending_cancel(0), draft)
            .unwrap();
        let base_state = store.snapshot();
        let base = serde_json::to_value(&base_state).unwrap();
        let path = dir.path().join("workspace.json");
        drop(store);
        let mut cases: Vec<Value> = Vec::new();
        for version in [1, 2, CURRENT_VERSION + 1] {
            let value = legacy_catalog_value(&base_state, version);
            cases.push(value);
        }
        for receipt in [
            json!({"state":{"kind":"pending","edit_id":"edit","turn_id":"turn"}}),
            json!({"revision":1}),
            json!({"revision":1,"state":null}),
            json!({"revision":1,"state":{"edit_id":"edit","turn_id":"turn"}}),
            json!({"revision":1,"state":{"kind":"unknown","edit_id":"edit","turn_id":"turn"}}),
            json!({"revision":1,"state":{"kind":"pending","turn_id":"turn"}}),
            json!({"revision":1,"state":{"kind":"pending","edit_id":"edit"}}),
            json!({"revision":1,"state":{"kind":"pending","edit_id":"","turn_id":"turn"}}),
            json!({"revision":1,"state":{"kind":"pending","edit_id":"edit","turn_id":""}}),
            json!({"revision":1,"state":{"kind":"pending","edit_id":"e".repeat(129),"turn_id":"turn"}}),
            json!({"revision":1,"state":{"kind":"pending","edit_id":"edit","turn_id":"t".repeat(129)}}),
            json!({"revision":1,"extra":"hidden","state":{"kind":"pending","edit_id":"edit","turn_id":"turn"}}),
            json!({"revision":1,"state":{"kind":"pending","edit_id":"edit","turn_id":"turn","extra":"hidden"}}),
            json!({"revision":2,"state":{"kind":"settled","edit_id":"forbidden"}}),
            json!({"revision":0,"state":{"kind":"pending","edit_id":"edit","turn_id":"turn"}}),
            json!({"revision":u64::MAX,"state":{"kind":"pending","edit_id":"edit","turn_id":"turn"}}),
            json!({"revision":1,"state":{"kind":"settled"}}),
            json!({"revision":3,"state":{"kind":"settled"}}), // exceeds catalog revision
            json!({"revision":-1,"state":{"kind":"settled"}}),
        ] {
            let mut value = base.clone();
            value["queued_cancellations"][&chat.id] = receipt;
            cases.push(value);
        }
        let mut unknown = base.clone();
        unknown["queued_cancellations"][Uuid::new_v4().to_string()] =
            json!({"revision":2,"state":{"kind":"settled"}});
        cases.push(unknown);
        let mut oversized = base.clone();
        for _ in 0..MAX_CHATS {
            oversized["queued_cancellations"][Uuid::new_v4().to_string()] =
                json!({"revision":2,"state":{"kind":"settled"}});
        }
        cases.push(oversized);
        for (index, value) in cases.into_iter().enumerate() {
            let bytes =
                format!(" \n{}\n  ", serde_json::to_string_pretty(&value).unwrap()).into_bytes();
            fs::write(&path, &bytes).unwrap();
            assert!(
                WorkspaceStore::open_with_confirmation(&path, dir.path(), |_| {
                    panic!("malformed catalog {index} must fail before confirmation")
                })
                .is_err(),
                "accepted malformed catalog {index}"
            );
            assert_eq!(
                fs::read(&path).unwrap(),
                bytes,
                "rewrote malformed catalog {index}"
            );
        }
    }
    #[test]
    fn cancel_without_a_retained_queued_draft_preserves_ordinary_typing() {
        let (dir, mut store, chat) = fixture();
        let initial = DraftRecord {
            revision: 7,
            text: "ordinary draft".into(),
            queued_edit: None,
        };
        store.register(chat.clone(), initial.clone()).unwrap();
        let pending = pending_cancel(0);
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), initial.clone())
            .unwrap();
        let latest = DraftRecord {
            revision: 8,
            text: "newer ordinary typing".into(),
            queued_edit: None,
        };
        store.save_draft(&chat.id, latest.clone()).unwrap();
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), initial.clone())
            .unwrap();
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &initial, initial.clone())
                .unwrap()
        );
        assert_eq!(store.snapshot().drafts[&chat.id], latest);
        drop(store);
        let reopened = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
        assert_eq!(reopened.snapshot().drafts[&chat.id], latest);
        assert_eq!(
            reopened.snapshot().queued_cancellations[&chat.id].state,
            QueuedCancelState::Settled
        );
    }
    #[test]
    fn exact_pending_retry_updates_only_newer_valid_draft_and_rejects_payload_conflict() {
        let (dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        let pending = pending_cancel(0);
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        let mut same_revision = draft.clone();
        same_revision.text.push_str(" conflicting");
        let before = fs::read(dir.path().join("workspace.json")).unwrap();
        assert!(
            store
                .prepare_queued_cancel(&chat.id, pending.clone(), same_revision)
                .is_err()
        );
        assert_eq!(fs::read(dir.path().join("workspace.json")).unwrap(), before);
        let mut latest = draft.clone();
        latest.revision += 1;
        latest.queued_edit.as_mut().unwrap().rewrite = "updated rewrite".into();
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), latest.clone())
            .unwrap();
        assert_eq!(store.snapshot().drafts[&chat.id], latest);
        assert_eq!(store.snapshot().queued_cancellations[&chat.id], pending);
        store
            .prepare_queued_cancel(&chat.id, pending, draft)
            .unwrap();
        assert_eq!(store.snapshot().drafts[&chat.id], latest);
    }

    #[test]
    fn exact_retry_and_settlement_preserve_a_different_newer_held_draft() {
        let (dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        let pending = pending_cancel(0);
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        let mut next = held_draft(5);
        next.queued_edit.as_mut().unwrap().edit_id = "another-edit".into();
        next.queued_edit.as_mut().unwrap().turn_id = "another-turn".into();
        store.save_draft(&chat.id, next.clone()).unwrap();
        let before = fs::read(dir.path().join("workspace.json")).unwrap();
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), next.clone())
            .unwrap();
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        assert_eq!(fs::read(dir.path().join("workspace.json")).unwrap(), before);
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &next, reconciled(&next))
                .is_err()
        );
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &next, next.clone())
                .unwrap()
        );
        assert_eq!(store.snapshot().drafts[&chat.id], next);
        assert_eq!(
            store.snapshot().queued_cancellations[&chat.id].state,
            QueuedCancelState::Settled
        );
        let later = pending_cancel(2);
        assert!(
            store
                .prepare_queued_cancel(&chat.id, later, next.clone())
                .is_err()
        );
        assert_eq!(store.snapshot().drafts[&chat.id], next);
    }
    #[test]
    fn same_edit_with_a_different_turn_conflicts_even_on_exact_pending_retry() {
        let (_dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        let pending = pending_cancel(0);
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        let mut conflict = draft.clone();
        conflict.revision += 1;
        conflict.queued_edit.as_mut().unwrap().turn_id = "wrong-turn".into();
        let before = state_bytes(&store);
        assert!(
            store
                .prepare_queued_cancel(&chat.id, pending.clone(), conflict.clone())
                .is_err()
        );
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &conflict, conflict.clone())
                .is_err()
        );
        assert_eq!(state_bytes(&store), before);
        // Ordinary draft semantics remain unchanged, but such an inconsistent
        // retained source must not authorize an old captured Cancel either.
        store.save_draft(&chat.id, conflict).unwrap();
        let before = state_bytes(&store);
        assert!(
            store
                .prepare_queued_cancel(&chat.id, pending, draft)
                .is_err()
        );
        assert_eq!(state_bytes(&store), before);
    }
    #[test]
    fn exact_flush_failure_never_authorizes_dispatch_before_reopen_confirmation() {
        for (fault, committed) in [(Fault::BeforeRename, false), (Fault::AfterRename, true)] {
            let (dir, mut store, chat) = fixture();
            let draft = held_draft(4);
            store.register(chat.clone(), draft.clone()).unwrap();
            let mut latest = draft.clone();
            latest.revision += 1;
            latest.queued_edit.as_mut().unwrap().rewrite = "latest Save payload".into();
            let path = dir.path().join("workspace.json");
            let before = fs::read(&path).unwrap();
            store.fault = fault;
            assert!(store.flush_draft_exact(&chat.id, latest.clone()).is_err());
            assert_eq!(store.snapshot().drafts[&chat.id], draft);
            if committed {
                store.fault = Fault::None;
                assert!(store.flush_draft_exact(&chat.id, latest.clone()).is_err());
            } else {
                assert_eq!(fs::read(&path).unwrap(), before);
            }
            drop(store);
            let mut reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
            assert_eq!(
                reopened.snapshot().drafts[&chat.id],
                if committed { latest.clone() } else { draft }
            );
            reopened
                .flush_draft_exact(&chat.id, latest.clone())
                .unwrap();
            assert_eq!(reopened.snapshot().drafts[&chat.id], latest);
        }
    }
    #[test]
    fn cancellation_settlement_catalog_revision_overflow_rolls_back_every_change() {
        let (dir, mut store, chat) = fixture();
        let draft = held_draft(4);
        store.register(chat.clone(), draft.clone()).unwrap();
        let pending = pending_cancel(0);
        store
            .prepare_queued_cancel(&chat.id, pending.clone(), draft.clone())
            .unwrap();
        let mut state = store.snapshot();
        state.revision = u64::MAX;
        let path = dir.path().join("workspace.json");
        drop(store);
        let bytes = serde_json::to_vec(&state).unwrap();
        fs::write(&path, &bytes).unwrap();
        let mut store = WorkspaceStore::open(&path, dir.path()).unwrap();
        assert!(
            store
                .settle_queued_cancel(&chat.id, &pending, &draft, reconciled(&draft))
                .is_err()
        );
        assert_eq!(state_bytes(&store), bytes);
        assert_eq!(fs::read(&path).unwrap(), bytes);
        assert_eq!(store.snapshot().queued_cancellations[&chat.id], pending);
    }
}

#[cfg(test)]
#[path = "workspace_identity_tests.rs"]
mod identity_tests;

#[cfg(test)]
#[path = "workspace_connection_tests.rs"]
mod connection_tests;
