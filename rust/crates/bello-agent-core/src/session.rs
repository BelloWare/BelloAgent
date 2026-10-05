use crate::{Delta, Error, Reply, Result, invalid};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Lane {
    FollowUp,
    Steering,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum RunState {
    Idle,
    Running,
    Paused,
    Error,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Submission {
    pub id: String,
    pub text: String,
    pub lane: Lane,
    pub model: Option<String>,
    pub effort: Option<String>,
}
impl Submission {
    pub fn new(text: String, lane: Lane) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            text,
            lane,
            model: None,
            effort: None,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    pub role: String,
    pub text: String,
    pub reasoning: String,
    pub replay_eligible: bool,
    pub state: String,
    pub usage: Value,
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_record: Option<crate::tool_history::ToolRecord>,
}
impl Message {
    fn new(
        id: String,
        role: &str,
        text: String,
        replay_eligible: bool,
        state: &str,
        model: Option<String>,
    ) -> Self {
        Self {
            id,
            role: role.into(),
            text,
            reasoning: String::new(),
            replay_eligible,
            state: state.into(),
            usage: Value::Null,
            model,
            tool_record: None,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct QueueEdit {
    pub edit_id: String,
    pub turn_id: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EditOutcome {
    pub edit_id: String,
    pub outcome: String,
    pub digest: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Session {
    pub version: u32,
    #[serde(default)]
    pub stream_generation: String,
    #[serde(default)]
    pub stream_sequence: u64,
    pub id: String,
    pub title: String,
    pub messages: Vec<Message>,
    pub pending: Vec<Submission>,
    pub state: RunState,
    pub queue_paused: bool,
    pub edit: Option<QueueEdit>,
    pub outcomes: Vec<EditOutcome>,
    pub active: Option<Submission>,
    pub active_reply: Option<String>,
    pub retry: Option<Submission>,
    pub error: Option<String>,
    pub revision: u64,
}
impl Session {
    pub fn new() -> Self {
        Self {
            version: 2,
            stream_generation: Uuid::new_v4().to_string(),
            stream_sequence: 0,
            id: Uuid::new_v4().to_string(),
            title: "New chat".into(),
            messages: Vec::new(),
            pending: Vec::new(),
            state: RunState::Idle,
            queue_paused: false,
            edit: None,
            outcomes: Vec::new(),
            active: None,
            active_reply: None,
            retry: None,
            error: None,
            revision: 0,
        }
    }
    pub fn submit(&mut self, item: Submission) -> Result<()> {
        validate_text(&item.text)?;
        if self.pending.len() >= 64 {
            return Err(invalid("The queue limit is 64 messages"));
        }
        if self.pending.iter().any(|v| v.id == item.id)
            || self.messages.iter().any(|v| v.id == item.id)
        {
            return Err(invalid("Turn identity was already accepted"));
        }
        if item.lane == Lane::Steering && self.state != RunState::Running {
            return Err(invalid("Steering requires an active run"));
        }
        self.pending.push(item);
        Ok(())
    }
    pub fn begin_edit(&mut self, turn_id: &str, edit_id: &str) -> Result<String> {
        if edit_id.is_empty() || edit_id.len() > 128 {
            return Err(invalid("Invalid edit identity"));
        }
        if self.outcomes.iter().any(|v| v.edit_id == edit_id) {
            return Err(invalid("This edit was already resolved"));
        }
        if let Some(edit) = &self.edit
            && (edit.edit_id != edit_id || edit.turn_id != turn_id)
        {
            return Err(invalid("Finish or cancel the queued edit first"));
        }
        let item = self
            .pending
            .iter()
            .find(|v| v.id == turn_id)
            .ok_or_else(|| invalid("Message is no longer pending"))?;
        let text = item.text.clone();
        self.edit = Some(QueueEdit {
            edit_id: edit_id.into(),
            turn_id: turn_id.into(),
        });
        Ok(text)
    }
    pub fn resolve_edit(&mut self, edit_id: &str, outcome: &str, text: Option<&str>) -> Result<()> {
        if !["saved", "cancelled", "removed"].contains(&outcome) {
            return Err(invalid("Invalid edit outcome"));
        }
        let digest = text.map(|text| format!("{:x}", Sha256::digest(text.as_bytes())));
        if let Some(previous) = self.outcomes.iter().find(|v| v.edit_id == edit_id) {
            if previous.outcome == outcome && previous.digest == digest {
                return Ok(());
            }
            return Err(invalid("This edit was resolved differently"));
        }
        let turn_id = match &self.edit {
            Some(edit) if edit.edit_id == edit_id => edit.turn_id.clone(),
            None if outcome == "cancelled" => String::new(),
            _ => return Err(invalid("This queued edit is no longer open")),
        };
        if outcome == "saved" {
            let text = text.ok_or_else(|| invalid("Save requires text"))?;
            validate_text(text)?;
            self.pending
                .iter_mut()
                .find(|v| v.id == turn_id)
                .ok_or_else(|| invalid("Message is no longer pending"))?
                .text = text.into();
        } else if outcome == "removed" {
            self.pending.retain(|v| v.id != turn_id);
        }
        self.edit = None;
        self.outcomes.push(EditOutcome {
            edit_id: edit_id.into(),
            outcome: outcome.into(),
            digest,
        });
        // Keep every edit identity for this initial format so delayed commands
        // cannot reacquire a forgotten hold. Bounded compaction is not ported.
        Ok(())
    }
    pub fn remove(&mut self, id: &str) -> Result<()> {
        if let Some(edit) = &self.edit
            && edit.turn_id == id
        {
            let id = edit.edit_id.clone();
            return self.resolve_edit(&id, "removed", None);
        }
        let n = self.pending.len();
        self.pending.retain(|v| v.id != id);
        if n == self.pending.len() {
            return Err(invalid("Message is no longer pending"));
        }
        Ok(())
    }
    pub fn reorder(&mut self, ids: &[String]) -> Result<()> {
        if self.edit.is_some() {
            return Err(invalid("Finish or cancel the queued edit first"));
        }
        let following: Vec<_> = self
            .pending
            .iter()
            .filter(|v| v.lane == Lane::FollowUp)
            .collect();
        if ids.len() != following.len()
            || ids.iter().collect::<std::collections::HashSet<_>>().len() != ids.len()
            || ids.iter().any(|id| !following.iter().any(|v| &v.id == id))
        {
            return Err(invalid("List each pending follow-up exactly once"));
        }
        let ordered: Vec<_> = ids
            .iter()
            .map(|id| (*following.iter().find(|v| &v.id == id).unwrap()).clone())
            .collect();
        self.pending.retain(|v| v.lane == Lane::Steering);
        self.pending.extend(ordered);
        Ok(())
    }
    pub fn start_next(&mut self) -> Result<Option<Submission>> {
        if self.state == RunState::Running
            || self.queue_paused
            || self.edit.is_some()
            || self.pending.is_empty()
        {
            return Ok(None);
        }
        let index = self
            .pending
            .iter()
            .position(|v| v.lane == Lane::Steering)
            .unwrap_or(0);
        let item = self.pending.remove(index);
        if self.messages.is_empty() {
            self.title = item.text.chars().take(60).collect();
        }
        self.messages.push(Message::new(
            item.id.clone(),
            "user",
            item.text.clone(),
            true,
            "complete",
            item.model.clone(),
        ));
        self.activate(item.clone());
        Ok(Some(item))
    }
    fn activate(&mut self, item: Submission) {
        let id = Uuid::new_v4().to_string();
        self.messages.push(Message::new(
            id.clone(),
            "assistant",
            String::new(),
            false,
            "streaming",
            item.model.clone(),
        ));
        self.active = Some(item);
        self.active_reply = Some(id);
        self.state = RunState::Running;
        self.error = None;
    }
    pub fn retry_turn(&mut self) -> Result<Submission> {
        if self.state == RunState::Running || self.edit.is_some() {
            return Err(invalid("A run or queued edit is already active"));
        }
        let item = self
            .retry
            .clone()
            .ok_or_else(|| invalid("There is no failed or stopped request to retry"))?;
        self.queue_paused = false;
        self.activate(item.clone());
        Ok(item)
    }
    pub fn delta(&mut self, reply_id: &str, delta: Delta) -> Result<()> {
        if self.active_reply.as_deref() != Some(reply_id) {
            return Err(invalid("Stale response delta"));
        }
        let message = self
            .messages
            .iter_mut()
            .find(|v| v.id == reply_id)
            .ok_or_else(|| invalid("Missing active reply"))?;
        match delta {
            Delta::Text(text) => message.text.push_str(&text),
            Delta::Reasoning(text) => message.reasoning.push_str(&text),
            Delta::Tool { .. } => {}
        }
        Ok(())
    }
    pub fn finish(&mut self, reply_id: &str, result: Result<Reply>) -> Result<()> {
        if self.active_reply.as_deref() != Some(reply_id) {
            return Err(invalid("Stale response completion"));
        }
        let message = self
            .messages
            .iter_mut()
            .find(|v| v.id == reply_id)
            .ok_or_else(|| invalid("Missing active reply"))?;
        match result {
            Ok(reply) if reply.calls.is_empty() => {
                message.text = reply.text;
                message.reasoning = reply.reasoning;
                message.usage = reply.usage;
                message.state = reply.status;
                message.replay_eligible = true;
                self.state = RunState::Idle;
                self.retry = None;
            }
            result => {
                let error = match result {
                    Ok(reply) => {
                        message.text = reply.text;
                        message.reasoning = reply.reasoning;
                        message.usage = reply.usage;
                        invalid(
                            "Provider requested tools, which are not enabled in this Rust slice. No tool was executed.",
                        )
                    }
                    Err(error) => error,
                };
                self.state = if matches!(error, Error::Cancelled) {
                    RunState::Paused
                } else {
                    RunState::Error
                };
                self.queue_paused = true;
                self.error = Some(error.to_string());
                self.retry = self.active.clone();
                message.state = "interrupted".into();
                message.replay_eligible = false;
            }
        }
        self.active = None;
        self.active_reply = None;
        Ok(())
    }
    pub fn resume(&mut self) -> Result<()> {
        if self.state == RunState::Running || self.edit.is_some() {
            return Err(invalid("Finish the current run or queued edit first"));
        }
        self.queue_paused = false;
        self.state = RunState::Idle;
        self.error = None;
        Ok(())
    }
    fn validate_tool_history(&self) -> Result<()> {
        if self.version < 3
            && self
                .messages
                .iter()
                .any(|message| message.tool_record.is_some())
        {
            return Err(invalid(
                "Typed tool history requires Rust snapshot version 3",
            ));
        }
        crate::tool_history::validate(&self.messages)
    }
    fn validate_checkpoint(&self) -> Result<()> {
        self.validate_tool_history()?;
        let active = self.active.is_some();
        let reply = self.active_reply.is_some();
        if self.state == RunState::Running {
            if !active || !reply {
                return Err(invalid(
                    "Running checkpoint is missing its active turn or reply",
                ));
            }
            let reply_id = self.active_reply.as_deref().expect("reply checked");
            if !self.messages.iter().any(|message| {
                message.id == reply_id
                    && message.role == "assistant"
                    && !message.replay_eligible
                    && message.state == "streaming"
            }) {
                return Err(invalid("Running checkpoint has an invalid streaming reply"));
            }
        } else if active || reply {
            return Err(invalid(
                "Inactive checkpoint unexpectedly contains an active turn",
            ));
        }
        Ok(())
    }
    fn recover(&mut self) -> bool {
        if self.state != RunState::Running && self.edit.is_none() {
            return false;
        }
        if let Some(id) = &self.active_reply
            && let Some(message) = self.messages.iter_mut().find(|v| &v.id == id)
        {
            message.state = "interrupted".into();
            message.replay_eligible = false;
        }
        self.retry = self.active.take().or(self.retry.take());
        self.active_reply = None;
        self.state = RunState::Paused;
        self.queue_paused = true;
        self.error=Some("Recovered after an interruption. Pending messages are paused; finish or cancel any held edit, then choose Resume or Retry.".into());
        true
    }
}
impl Default for Session {
    fn default() -> Self {
        Self::new()
    }
}
fn validate_text(text: &str) -> Result<()> {
    if text.trim().is_empty() {
        return Err(invalid("Enter a message"));
    }
    if text.len() > 262_144 {
        return Err(invalid("Message exceeds 256 KiB"));
    }
    Ok(())
}

/// Single-owner, atomic, synced snapshots. A failure never silently commits an
/// in-memory mutation, and an uncertain post-rename sync blocks further writes.
#[cfg(test)]
#[derive(Clone, Copy, Default)]
enum WriteFault {
    #[default]
    None,
    BeforeRename,
    AfterRename,
    StreamMetadata,
}
const MAX_SNAPSHOT_BYTES: usize = 256 * 1024 * 1024;
// Kept outside streamed text admission so cancellation/recovery can always
// write its small notice and state changes without making history unreadable.
const RECOVERY_RESERVE_BYTES: usize = 128 * 1024;
pub struct SessionStore {
    #[cfg(test)]
    fault: WriteFault,
    path: PathBuf,
    _lock: Option<File>,
    session: Session,
    uncertain: bool,
    journal: Option<File>,
    encoded_bytes: usize,
    snapshot_limit: usize,
}
impl SessionStore {
    /// An on-screen New chat has no file, lock, accepted input, or running work.
    pub fn pending() -> Self {
        let session = Session::new();
        let encoded_bytes = encode_snapshot(&session)
            .expect("empty session encodes")
            .len();
        Self {
            #[cfg(test)]
            fault: WriteFault::None,
            path: PathBuf::new(),
            _lock: None,
            session,
            uncertain: false,
            journal: None,
            encoded_bytes,
            snapshot_limit: MAX_SNAPSHOT_BYTES,
        }
    }
    pub fn pending_with_id(id: &str) -> Result<Self> {
        Uuid::parse_str(id).map_err(|_| invalid("Invalid pending chat identity"))?;
        let mut store = Self::pending();
        store.session.id = id.into();
        store.encoded_bytes = encode_snapshot(&store.session)?.len();
        Ok(store)
    }
    pub fn is_persistent(&self) -> bool {
        self._lock.is_some()
    }
    pub fn persist_to(&mut self, path: impl AsRef<Path>) -> Result<()> {
        if self.is_persistent() {
            let requested = if path.as_ref().is_absolute() {
                path.as_ref().to_owned()
            } else {
                std::env::current_dir()?.join(path.as_ref())
            };
            if requested != self.path {
                return Err(invalid("This chat is already stored at a different path"));
            }
            return Ok(());
        }
        if self.uncertain {
            return Err(invalid(
                "Session persistence is uncertain. Reopen before continuing.",
            ));
        }
        match Self::open_seeded(path.as_ref(), Some(self.session.clone())) {
            Ok(store) => {
                *self = store;
                Ok(())
            }
            Err(error) => {
                if matches!(error, Error::PersistenceUncertain(_)) {
                    self.uncertain = true;
                }
                Err(error)
            }
        }
    }
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_seeded(path.as_ref(), None)
    }
    fn open_seeded(path: &Path, initial: Option<Session>) -> Result<Self> {
        let path = if path.is_absolute() {
            path.to_owned()
        } else {
            std::env::current_dir()?.join(path)
        };
        let parent = path
            .parent()
            .ok_or_else(|| invalid("Session path has no parent"))?;
        let mut directories = fs::DirBuilder::new();
        directories.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            directories.mode(0o700);
        }
        directories.create(parent)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let lock = options.open(path.with_extension("lock"))?;
        lock.try_lock_exclusive()
            .map_err(|_| invalid("This Rust session is already open elsewhere"))?;
        let exists = path.exists();
        let mut session: Session = if exists {
            let metadata = fs::metadata(&path)?;
            if metadata.len() > 256 * 1024 * 1024 {
                return Err(invalid("Session exceeds 256 MiB safety limit"));
            }
            serde_json::from_slice(&fs::read(&path)?)?
        } else {
            initial.clone().unwrap_or_default()
        };
        if initial
            .as_ref()
            .is_some_and(|expected| expected.id != session.id)
        {
            return Err(invalid("The session file belongs to another chat"));
        }
        if ![1, 2, 3].contains(&session.version) {
            return Err(invalid(
                "Unsupported Rust session format. Swift journals are not imported automatically.",
            ));
        }
        let migrated = session.version == 1;
        if migrated {
            session.version = 2;
            session.stream_generation = Uuid::new_v4().to_string();
            session.stream_sequence = 0;
        }
        session.validate_checkpoint()?;
        let old_generation = session.stream_generation.clone();
        let replay = crate::stream_journal::replay(&path, &mut session)?;
        let recovered = session.recover();
        if replay.incomplete_tail {
            session.error=Some("Recovered complete streamed text. An incomplete final record is preserved in the prior stream journal; pending messages are paused.".into());
            session.queue_paused = true;
            session.state = RunState::Paused;
        }
        let checkpoint = !exists || migrated || recovered || replay.exists;
        if checkpoint {
            session.stream_generation = Uuid::new_v4().to_string();
            session.stream_sequence = 0;
        }

        let encoded_bytes = encode_snapshot(&session)?.len();
        let store = Self {
            #[cfg(test)]
            fault: WriteFault::None,
            path,
            _lock: Some(lock),
            session,
            uncertain: false,
            journal: None,
            encoded_bytes,
            snapshot_limit: MAX_SNAPSHOT_BYTES,
        };
        if checkpoint {
            store.write(&store.session, false)?;
            if replay.exists && !replay.incomplete_tail {
                let _ = fs::remove_file(crate::stream_journal::path(&store.path, &old_generation)?);
            }
        }
        Ok(store)
    }
    pub fn snapshot_revision(&self) -> u64 {
        self.session.revision
    }
    pub fn snapshot(&self) -> Session {
        self.session.clone()
    }
    pub fn transact<T>(&mut self, change: impl FnOnce(&mut Session) -> Result<T>) -> Result<T> {
        if !self.is_persistent() {
            return Err(invalid("Materialize this New chat before accepting input"));
        }
        if self.uncertain {
            return Err(invalid(
                "Session persistence is uncertain. Reopen before continuing.",
            ));
        }
        let mut next = self.session.clone();
        let result = change(&mut next)?;
        if next
            .messages
            .iter()
            .any(|message| message.tool_record.is_some())
        {
            next.version = 3;
        }
        next.revision = next
            .revision
            .checked_add(1)
            .ok_or_else(|| invalid("Session revision overflow"))?;
        let old_generation = self.session.stream_generation.clone();
        next.stream_generation = Uuid::new_v4().to_string();
        next.stream_sequence = 0;
        let encoded_bytes = match self.write(
            &next,
            next.state == RunState::Running || next.edit.is_some(),
        ) {
            Ok(bytes) => bytes,
            Err(error) => {
                if matches!(error, Error::PersistenceUncertain(_)) {
                    self.uncertain = true;
                }
                return Err(error);
            }
        };
        self.session = next;
        self.encoded_bytes = encoded_bytes;
        self.journal = None;
        // Cleanup is optional: the durable checkpoint names the new generation.
        // A failed removal leaves an unreachable old journal, never a lost input.
        let _ = fs::remove_file(crate::stream_journal::path(&self.path, &old_generation)?);
        Ok(result)
    }
    /// Append and synchronize only the new stream fragment. Accepted input and
    /// queue/edit commands still use atomic full checkpoints through transact.
    pub fn append_delta(&mut self, reply_id: &str, delta: Delta) -> Result<()> {
        if !self.is_persistent() {
            return Err(invalid("Materialize this New chat before accepting output"));
        }
        if self.uncertain {
            return Err(invalid(
                "Session persistence is uncertain. Reopen before continuing.",
            ));
        }
        if self.session.active_reply.as_deref() != Some(reply_id)
            || !self
                .session
                .messages
                .iter()
                .any(|message| message.id == reply_id)
        {
            return Err(invalid("Stale response delta"));
        }
        let growth = encoded_delta_growth(&self.session, &delta)?;
        let next_size = self
            .encoded_bytes
            .checked_add(growth)
            .ok_or_else(|| invalid("Session size overflow"))?;
        if next_size > self.snapshot_limit.saturating_sub(RECOVERY_RESERVE_BYTES) {
            return Err(invalid(
                "Session is at its streaming capacity; accepted text is preserved with room for recovery",
            ));
        }
        let bytes = crate::stream_journal::encode(&self.session, reply_id, &delta)?;
        let created = self.journal.is_none();
        if created {
            self.journal = Some(crate::stream_journal::create(
                &crate::stream_journal::path(&self.path, &self.session.stream_generation)?,
            )?);
        }
        let file = self.journal.as_mut().expect("journal initialized");
        #[cfg(test)]
        let metadata = if matches!(self.fault, WriteFault::StreamMetadata) {
            Err(std::io::Error::other("injected journal metadata failure"))
        } else {
            file.metadata()
        };
        #[cfg(not(test))]
        let metadata = file.metadata();
        let length = match metadata {
            Ok(metadata) => metadata.len(),
            Err(error) => {
                self.uncertain = true;
                return Err(Error::PersistenceUncertain(format!(
                    "Cannot verify stream journal metadata: {error}"
                )));
            }
        };
        if length.saturating_add(bytes.len() as u64) > crate::stream_journal::MAX_JOURNAL_BYTES {
            return Err(invalid(
                "Stream journal exceeds 512 MiB; previous data is preserved",
            ));
        }
        if let Err(error) = crate::stream_journal::append(file, &bytes) {
            self.uncertain = true;
            return Err(Error::PersistenceUncertain(error.to_string()));
        }
        if created
            && let Err(error) =
                sync_committed_directory(self.path.parent().expect("snapshot directory checked"))
        {
            self.uncertain = true;
            return Err(error);
        }
        self.session.delta(reply_id, delta)?;
        self.session.stream_sequence += 1;
        self.session.revision += 1;
        self.encoded_bytes = next_size;
        Ok(())
    }
    fn write(&self, session: &Session, reserve_recovery: bool) -> Result<usize> {
        let parent = self
            .path
            .parent()
            .ok_or_else(|| invalid("Missing snapshot directory"))?;
        // Serialize before opening the destination. serde_json::to_writer on
        // an unbuffered File issued thousands of syscalls per tiny delta.
        // One complete byte buffer keeps the same write -> fsync -> rename ->
        // directory fsync durability order without relying on a Drop flush.
        let bytes = encode_snapshot(session)?;
        let limit = self.snapshot_limit.saturating_sub(if reserve_recovery {
            RECOVERY_RESERVE_BYTES
        } else {
            0
        });
        if bytes.len() > limit {
            return Err(invalid(
                "Session checkpoint needs reserved room for interruption recovery; previous data is preserved",
            ));
        }
        let temporary = parent.join(format!(".bello-agent-{}.tmp", Uuid::new_v4()));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let result = (|| -> Result<()> {
            let mut file = options.open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            #[cfg(test)]
            if matches!(self.fault, WriteFault::BeforeRename) {
                return Err(std::io::Error::other("injected pre-rename failure").into());
            }
            fs::rename(&temporary, &self.path)?;
            #[cfg(test)]
            if matches!(self.fault, WriteFault::AfterRename) {
                return Err(Error::PersistenceUncertain(
                    "injected post-rename failure".into(),
                ));
            }
            sync_committed_directory(parent)?;
            Ok(())
        })();
        if result.is_err() && temporary.exists() {
            let _ = fs::remove_file(temporary);
        }
        result.map(|()| bytes.len())
    }
}

fn encoded_delta_growth(session: &Session, delta: &Delta) -> Result<usize> {
    let text = match delta {
        Delta::Text(text) | Delta::Reasoning(text) => Some(text),
        Delta::Tool { .. } => None,
    };
    let text_bytes = if let Some(text) = text {
        serde_json::to_vec(text)?.len() - 2
    } else {
        0
    };
    let revision = session
        .revision
        .checked_add(1)
        .ok_or_else(|| invalid("Session revision overflow"))?;
    let sequence = session
        .stream_sequence
        .checked_add(1)
        .ok_or_else(|| invalid("Stream journal sequence overflow"))?;
    Ok(
        text_bytes + revision.to_string().len() - session.revision.to_string().len()
            + sequence.to_string().len()
            - session.stream_sequence.to_string().len(),
    )
}

/// Once rename has succeeded, both opening and syncing the parent can fail.
/// Either leaves the commit outcome uncertain and must block future writes.
fn sync_committed_directory(parent: &Path) -> Result<()> {
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| Error::PersistenceUncertain(error.to_string()))
}

fn encode_snapshot(session: &Session) -> Result<Vec<u8>> {
    session.validate_tool_history()?;
    let mut bytes = serde_json::to_vec(session)?;
    bytes.push(b'\n');
    if bytes.len() > MAX_SNAPSHOT_BYTES {
        return Err(invalid(
            "Session exceeds 256 MiB safety limit; previous snapshot is preserved",
        ));
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pending_chat_accepts_nothing_until_materialized_and_keeps_identity() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("new.json");
        let mut store = SessionStore::pending();
        let id = store.snapshot().id;
        assert!(!store.is_persistent());
        assert!(!path.exists());
        assert!(
            store
                .transact(|session| session
                    .submit(Submission::new("must not accept".into(), Lane::FollowUp)))
                .is_err()
        );
        assert!(store.snapshot().pending.is_empty());
        store.persist_to(&path).unwrap();
        assert_eq!(store.snapshot().id, id);
        store
            .transact(|session| session.submit(Submission::new("accepted".into(), Lane::FollowUp)))
            .unwrap();
        drop(store);
        assert_eq!(SessionStore::open(path).unwrap().snapshot().id, id);
    }
    #[test]
    fn hold_blocks_every_lane_and_preserves_identity() {
        let mut s = Session::new();
        let one = Submission::new("first".into(), Lane::FollowUp);
        let id = one.id.clone();
        s.submit(one).unwrap();
        s.begin_edit(&id, "edit").unwrap();
        assert!(s.start_next().unwrap().is_none());
        s.submit(Submission::new("second".into(), Lane::FollowUp))
            .unwrap();
        s.resolve_edit("edit", "saved", Some("changed")).unwrap();
        s.resolve_edit("edit", "saved", Some("changed")).unwrap();
        assert!(s.resolve_edit("edit", "saved", Some("other")).is_err());
        let item = s.start_next().unwrap().unwrap();
        assert_eq!(item.id, id);
        assert_eq!(item.text, "changed");
    }
    #[test]
    fn unknown_cancel_cannot_later_acquire_hold() {
        let mut s = Session::new();
        let item = Submission::new("hi".into(), Lane::FollowUp);
        let id = item.id.clone();
        s.submit(item).unwrap();
        s.resolve_edit("cancelled-early", "cancelled", None)
            .unwrap();
        assert!(s.begin_edit(&id, "cancelled-early").is_err());
    }
    #[test]
    fn stop_keeps_partial_out_of_replay_and_queue_paused() {
        let mut s = Session::new();
        s.submit(Submission::new("hi".into(), Lane::FollowUp))
            .unwrap();
        s.start_next().unwrap();
        let id = s.active_reply.clone().unwrap();
        s.delta(&id, Delta::Text("partial".into())).unwrap();
        s.submit(Submission::new("later".into(), Lane::FollowUp))
            .unwrap();
        s.finish(&id, Err(Error::Cancelled)).unwrap();
        assert!(s.start_next().unwrap().is_none());
        assert!(!s.messages.last().unwrap().replay_eligible);
        s.retry_turn().unwrap();
        assert_eq!(s.messages.iter().filter(|v| v.role == "user").count(), 1);
    }
    #[test]
    fn restart_pauses_active_run_and_retains_held_edit() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        {
            let mut store = SessionStore::open(&path).unwrap();
            store
                .transact(|s| {
                    s.submit(Submission::new("hi".into(), Lane::FollowUp))?;
                    s.start_next()?;
                    let item = Submission::new("waiting".into(), Lane::FollowUp);
                    let id = item.id.clone();
                    s.submit(item)?;
                    s.begin_edit(&id, "edit")?;
                    Ok(())
                })
                .unwrap();
        }
        let store = SessionStore::open(&path).unwrap();
        let s = store.snapshot();
        assert_eq!(s.state, RunState::Paused);
        assert!(s.queue_paused);
        assert_eq!(s.edit.unwrap().edit_id, "edit");
        assert!(!s.messages.last().unwrap().replay_eligible);
    }
    #[test]
    fn mutation_validation_rolls_back_and_lock_excludes_second_owner() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        assert!(SessionStore::open(&path).is_err());
        let rev = store.snapshot().revision;
        assert!(
            store
                .transact(|s| {
                    s.title = "bad".into();
                    Err::<(), _>(invalid("rejected"))
                })
                .is_err()
        );
        assert_eq!(store.snapshot().title, "New chat");
        assert_eq!(store.snapshot().revision, rev);
    }
    #[test]
    fn reorder_rejects_omissions_duplicates_and_held_edit() {
        let mut s = Session::new();
        s.submit(Submission::new("a".into(), Lane::FollowUp))
            .unwrap();
        s.submit(Submission::new("b".into(), Lane::FollowUp))
            .unwrap();
        let a = s.pending[0].id.clone();
        let b = s.pending[1].id.clone();
        assert!(s.reorder(&[a.clone(), a.clone()]).is_err());
        s.reorder(&[b.clone(), a.clone()]).unwrap();
        assert_eq!(s.pending[0].id, b);
        s.begin_edit(&a, "edit").unwrap();
        assert!(s.reorder(&[a, b]).is_err());
    }
    #[test]
    fn failed_write_preserves_memory_and_disk_then_uncertain_write_blocks() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        store.fault = WriteFault::BeforeRename;
        assert!(
            store
                .transact(|s| {
                    s.title = "not committed".into();
                    Ok(())
                })
                .is_err()
        );
        assert_eq!(store.snapshot().title, "New chat");
        let disk: Session = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(disk.title, "New chat");
        store.fault = WriteFault::AfterRename;
        assert!(matches!(
            store.transact(|s| {
                s.title = "uncertain".into();
                Ok(())
            }),
            Err(Error::PersistenceUncertain(_))
        ));
        store.fault = WriteFault::None;
        assert!(
            store
                .transact(|s| {
                    s.title = "must not overwrite".into();
                    Ok(())
                })
                .is_err()
        );
        drop(store);
        let reopened = SessionStore::open(&path).unwrap();
        assert_eq!(reopened.snapshot().title, "uncertain");
    }
    #[cfg(unix)]
    #[test]
    fn snapshots_and_locks_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let _store = SessionStore::open(&path).unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(path.with_extension("lock"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    #[test]
    fn encoding_finishes_json_and_newline_before_any_disk_write() {
        let mut session = Session::new();
        session
            .submit(Submission::new(
                "Unicode héllo\nsecond line".into(),
                Lane::FollowUp,
            ))
            .unwrap();
        let bytes = encode_snapshot(&session).unwrap();
        assert_eq!(bytes.last(), Some(&b'\n'));
        let reopened: Session = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(reopened.pending[0].text, session.pending[0].text);
        assert_eq!(reopened.id, session.id);
    }
    #[test]
    fn missing_directory_after_rename_is_also_uncertain() {
        let dir = tempfile::tempdir().unwrap();
        assert!(matches!(
            sync_committed_directory(&dir.path().join("missing")),
            Err(Error::PersistenceUncertain(_))
        ));
    }
    fn active_store(path: &Path) -> SessionStore {
        let mut store = SessionStore::open(path).unwrap();
        store
            .transact(|session| {
                session.submit(Submission::new("input".into(), Lane::FollowUp))?;
                session.start_next()?;
                Ok(())
            })
            .unwrap();
        store
    }
    #[test]
    fn stream_fragments_do_not_rewrite_checkpoint_and_recover_after_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let original = fs::read(&path).unwrap();
        let reply = store.snapshot().active_reply.unwrap();
        let generation = store.snapshot().stream_generation;
        store
            .append_delta(&reply, Delta::Text("héllo\nworld".into()))
            .unwrap();
        assert_eq!(fs::read(&path).unwrap(), original);
        let journal = crate::stream_journal::path(&path, &generation).unwrap();
        assert!(journal.exists());
        drop(store);
        let reopened = SessionStore::open(&path).unwrap();
        let session = reopened.snapshot();
        assert_eq!(session.messages.last().unwrap().text, "héllo\nworld");
        assert!(!session.messages.last().unwrap().replay_eligible);
        assert_eq!(session.state, RunState::Paused);
        assert!(session.queue_paused);
        assert!(!journal.exists());
        assert_ne!(session.stream_generation, generation);
    }
    #[test]
    fn command_checkpoint_rotates_stream_generation_without_duplicate_text() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let reply = store.snapshot().active_reply.unwrap();
        let before = store.snapshot().stream_generation;
        store
            .append_delta(&reply, Delta::Text("first".into()))
            .unwrap();
        store
            .transact(|session| session.submit(Submission::new("queued".into(), Lane::FollowUp)))
            .unwrap();
        assert_ne!(store.snapshot().stream_generation, before);
        assert!(
            !crate::stream_journal::path(&path, &before)
                .unwrap()
                .exists()
        );
        store
            .append_delta(&reply, Delta::Text("second".into()))
            .unwrap();
        drop(store);
        let restored = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(restored.messages.last().unwrap().text, "firstsecond");
        assert_eq!(restored.pending[0].text, "queued");
    }
    #[test]
    fn uncertain_checkpoint_never_replays_prior_generation_twice() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let reply = store.snapshot().active_reply.unwrap();
        store
            .append_delta(&reply, Delta::Text("once".into()))
            .unwrap();
        store.fault = WriteFault::AfterRename;
        assert!(matches!(
            store.transact(|session| {
                session.title = "maybe saved".into();
                Ok(())
            }),
            Err(Error::PersistenceUncertain(_))
        ));
        assert!(
            store
                .append_delta(&reply, Delta::Text("blocked".into()))
                .is_err()
        );
        drop(store);
        let restored = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(restored.messages.last().unwrap().text, "once");
        assert_eq!(restored.title, "maybe saved");
    }
    #[test]
    fn failed_checkpoint_preserves_live_journal_and_later_appends() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let reply = store.snapshot().active_reply.unwrap();
        let generation = store.snapshot().stream_generation;
        store.append_delta(&reply, Delta::Text("a".into())).unwrap();
        store.fault = WriteFault::BeforeRename;
        assert!(
            store
                .transact(|session| {
                    session.title = "uncommitted".into();
                    Ok(())
                })
                .is_err()
        );
        assert_eq!(store.snapshot().stream_generation, generation);
        store.append_delta(&reply, Delta::Text("b".into())).unwrap();
        drop(store);
        let restored = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(restored.messages.last().unwrap().text, "ab");
        assert_ne!(restored.title, "uncommitted");
    }
    #[test]
    fn torn_unacknowledged_tail_is_preserved_while_valid_prefix_recovers() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let reply = store.snapshot().active_reply.unwrap();
        store
            .append_delta(&reply, Delta::Text("complete prefix".into()))
            .unwrap();
        let journal =
            crate::stream_journal::path(&path, &store.snapshot().stream_generation).unwrap();
        drop(store);
        OpenOptions::new()
            .append(true)
            .open(&journal)
            .unwrap()
            .write_all(b"{torn")
            .unwrap();
        let old = fs::read(&journal).unwrap();
        let restored = SessionStore::open(&path).unwrap().snapshot();
        assert_eq!(restored.messages.last().unwrap().text, "complete prefix");
        assert_eq!(restored.state, RunState::Paused);
        assert_eq!(fs::read(&journal).unwrap(), old);
        assert!(restored.error.unwrap().contains("incomplete final record"));
    }
    #[test]
    fn stale_delta_is_rejected_before_any_journal_write() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let journal =
            crate::stream_journal::path(&path, &store.snapshot().stream_generation).unwrap();
        let revision = store.snapshot().revision;
        assert!(
            store
                .append_delta("stale", Delta::Text("wrong".into()))
                .is_err()
        );
        assert!(!journal.exists());
        assert_eq!(store.snapshot().revision, revision);
    }
    #[test]
    fn rust_v1_snapshot_migrates_without_swift_import() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut old = serde_json::to_value(Session::new()).unwrap();
        old["version"] = serde_json::json!(1);
        old.as_object_mut().unwrap().remove("stream_generation");
        old.as_object_mut().unwrap().remove("stream_sequence");
        fs::write(&path, serde_json::to_vec(&old).unwrap()).unwrap();
        let store = SessionStore::open(&path).unwrap();
        assert_eq!(store.snapshot().version, 2);
        assert!(Uuid::parse_str(&store.snapshot().stream_generation).is_ok());
    }
    #[test]
    fn incremental_size_matches_json_for_escapes_unicode_and_counter_boundaries() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        store
            .transact(|session| {
                session.revision = 8;
                Ok(())
            })
            .unwrap();
        let reply = store.snapshot().active_reply.unwrap();
        for index in 0..105 {
            let delta = match index % 3 {
                0 => Delta::Text("\"\\\n\r\t\u{0001}é🙂".into()),
                1 => Delta::Reasoning("\"\\\n\u{0000}α".into()),
                _ => Delta::Tool {
                    id: "call".into(),
                    name: "read".into(),
                    arguments: "{}".into(),
                },
            };
            store.append_delta(&reply, delta).unwrap();
            assert_eq!(
                store.encoded_bytes,
                encode_snapshot(&store.snapshot()).unwrap().len(),
                "after delta {index}"
            );
        }
        assert_eq!(store.snapshot().stream_sequence, 105);
    }
    #[test]
    fn stream_capacity_rejects_before_creation_or_append_and_reopens() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let reply = store.snapshot().active_reply.unwrap();
        let journal =
            crate::stream_journal::path(&path, &store.snapshot().stream_generation).unwrap();
        store.snapshot_limit = store.encoded_bytes + RECOVERY_RESERVE_BYTES + 20;
        let before = store.snapshot();
        assert!(
            store
                .append_delta(&reply, Delta::Text("x".repeat(21)))
                .is_err()
        );
        assert!(!journal.exists());
        assert_eq!(store.snapshot().revision, before.revision);
        store
            .append_delta(&reply, Delta::Text("accepted".into()))
            .unwrap();
        let bytes = fs::read(&journal).unwrap();
        let before = store.snapshot();
        assert!(
            store
                .append_delta(&reply, Delta::Reasoning("x".repeat(21)))
                .is_err()
        );
        assert_eq!(fs::read(&journal).unwrap(), bytes);
        assert_eq!(store.snapshot().revision, before.revision);
        assert_eq!(store.snapshot().stream_sequence, before.stream_sequence);
        drop(store);
        let restored = SessionStore::open(path).unwrap().snapshot();
        assert_eq!(restored.messages.last().unwrap().text, "accepted");
        assert!(restored.messages.last().unwrap().reasoning.is_empty());
        assert_eq!(restored.state, RunState::Paused);
    }
    #[test]
    fn metadata_failure_after_journal_creation_blocks_later_unsynced_append() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = active_store(&path);
        let reply = store.snapshot().active_reply.unwrap();
        let revision = store.snapshot().revision;
        store.fault = WriteFault::StreamMetadata;
        assert!(matches!(
            store.append_delta(&reply, Delta::Text("unpublished".into())),
            Err(Error::PersistenceUncertain(_))
        ));
        store.fault = WriteFault::None;
        assert!(
            store
                .append_delta(&reply, Delta::Text("blocked".into()))
                .is_err()
        );
        assert_eq!(store.snapshot().revision, revision);
        assert!(store.snapshot().messages.last().unwrap().text.is_empty());
        drop(store);
        let restored = SessionStore::open(path).unwrap().snapshot();
        assert!(restored.messages.last().unwrap().text.is_empty());
        assert_eq!(restored.state, RunState::Paused);
    }
    #[test]
    fn every_held_edit_command_preserves_recovery_headroom() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        store
            .transact(|session| {
                session.submit(Submission::new("waiting".into(), Lane::FollowUp))?;
                let id = session.pending[0].id.clone();
                session.begin_edit(&id, "held")?;
                Ok(())
            })
            .unwrap();
        let limit = store.encoded_bytes + RECOVERY_RESERVE_BYTES + 32;
        store.snapshot_limit = limit;
        let before = fs::read(&path).unwrap();
        assert!(store.transact(|session|session.submit(Submission::new("x".repeat(100),Lane::FollowUp))).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
        assert_eq!(store.snapshot().pending.len(), 1);
        drop(store);
        let mut restored = SessionStore::open(&path).unwrap();
        assert_eq!(restored.snapshot().state, RunState::Paused);
        assert!(restored.encoded_bytes <= limit);
        restored.snapshot_limit = limit;
        assert!(restored.transact(|session|session.submit(Submission::new("x".repeat(100),Lane::FollowUp))).is_err());
        restored
            .transact(|session| session.resolve_edit("held", "cancelled", None))
            .unwrap();
        assert!(restored.snapshot().edit.is_none());
    }
}
