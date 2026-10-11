//! Rename and delete for one saved chat (Swift WorkspaceChatLifecycle.swift,
//! WorkspaceSessionOrganization.setSessionTitle and MetadataStore's
//! changeOrganization(.title)). Deletion removes the chat's own catalog rows
//! and names only the files of its own managed storage; it never touches a
//! file outside the catalog's `chats` directory or another chat's rows.
use super::*;
use unicode_segmentation::UnicodeSegmentation;

/// Refused while the chat still has work the app owns (Swift's
/// `hasWork`/`loading` guard in `deleteChat`).
pub const DELETE_WORK_NOTICE: &str =
    "Stop work and remove queued submissions before deleting this chat";

impl ChatRecord {
    /// Swift ChatRecord.normalizedTitle: whitespace runs collapse to one
    /// space and the title keeps its first 120 characters (graphemes).
    pub fn normalized_title(title: &str) -> Result<String> {
        // Foundation CharacterSet.whitespacesAndNewlines includes U+200B;
        // Rust's White_Space property does not (as TopicRecord).
        let normalized = title
            .split(|c: char| c.is_whitespace() || c == '\u{200b}')
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        if normalized.is_empty() {
            return Err(invalid("Enter a title for this chat."));
        }
        // The catalog keeps titles to 512 bytes: whole graphemes only.
        let mut title = String::new();
        for grapheme in normalized.graphemes(true).take(120) {
            if title.len() + grapheme.len() > 512 {
                break;
            }
            title.push_str(grapheme);
        }
        Ok(title)
    }
}

impl DraftRecord {
    /// Swift DraftRecord.holdsUnsentDraft: the draft marker's test. Text,
    /// an image or a skill in the composer, or a queued message being
    /// rewritten to something other than its original.
    pub fn holds_unsent(&self) -> bool {
        let trimmed = |text: &str| {
            text.trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}')
                .to_owned()
        };
        if !trimmed(&self.text).is_empty()
            || !self.attachments.is_empty()
            || !self.skills.is_empty()
        {
            return true;
        }
        self.queued_edit.as_ref().is_some_and(|queued| {
            queued
                .original_text
                .as_deref()
                .is_none_or(|original| trimmed(original) != trimmed(&queued.rewrite))
        })
    }
}

/// What a confirmed deletion removed, and the chat's own files for the caller
/// to move to the Trash after its writer has been retired.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeletedChat {
    pub record: ChatRecord,
    /// The managed conversation checkpoint and its stream journals. Empty
    /// when the record's snapshot is not this catalog's managed path for the
    /// chat (an imported original stays where it is, as in Swift).
    pub managed_files: Vec<PathBuf>,
    /// The checkpoint's empty writer-lock sidecar, removed after the files.
    pub lock_file: Option<PathBuf>,
}

impl WorkspaceStore {
    /// The saved project identity this catalog is bound to, if any.
    pub fn project_id(&self) -> Option<&str> {
        self.state.project_id.as_deref()
    }
    /// Rename a registered chat's catalog row. The caller has already
    /// written the same title to the chat's own checkpoint, which stays the
    /// source the sidebar reads once the chat is loaded.
    pub fn rename_chat(
        &mut self,
        id: &str,
        expected_snapshot: &Path,
        title: &str,
    ) -> Result<ChatRecord> {
        self.ensure_certain()?;
        let title = ChatRecord::normalized_title(title)?;
        let chat = self
            .state
            .chats
            .iter()
            .find(|chat| chat.id == id)
            .ok_or_else(|| invalid("This saved chat is unavailable."))?;
        if chat.snapshot != expected_snapshot {
            return Err(invalid("Chat identity is already registered differently"));
        }
        if chat.title == title {
            return Ok(chat.clone());
        }
        self.transact(|state| {
            let chat = state
                .chats
                .iter_mut()
                .find(|chat| chat.id == id)
                .expect("checked chat");
            chat.title = title;
            Ok(chat.clone())
        })
    }

    /// Remove one chat's catalog rows: its record, draft, read state and
    /// settled receipts. A retained submission or cancellation receipt is
    /// unfinished work, refused like Swift's busy/queued guard. Nothing is
    /// removed from disk here.
    /// `startup_anchor` is the app's own first-chat checkpoint (not a chat
    /// path, but app-managed all the same); a relaunch would re-register it
    /// if it stayed.
    pub fn delete_chat(
        &mut self,
        id: &str,
        expected_snapshot: &Path,
        startup_anchor: Option<&Path>,
    ) -> Result<DeletedChat> {
        self.ensure_certain()?;
        let chat = self
            .state
            .chats
            .iter()
            .find(|chat| chat.id == id)
            .ok_or_else(|| invalid("This saved chat is unavailable."))?
            .clone();
        if chat.snapshot != expected_snapshot {
            return Err(invalid("Chat identity is already registered differently"));
        }
        // A held queued rewrite is unsent work even without its checkpoint.
        if self
            .state
            .drafts
            .get(id)
            .is_some_and(|draft| draft.queued_edit.is_some())
            || self
                .state
                .intents
                .values()
                .any(|intent| intent.chat_id == id)
            || self
                .state
                .queued_cancellations
                .get(id)
                .is_some_and(|receipt| matches!(receipt.state, QueuedCancelState::Pending { .. }))
        {
            return Err(invalid(DELETE_WORK_NOTICE));
        }
        let managed =
            self.chat_path(id)? == chat.snapshot || startup_anchor == Some(chat.snapshot.as_path());
        self.transact(|state| {
            state.chats.retain(|chat| chat.id != id);
            state.drafts.remove(id);
            state.read_states.remove(id);
            state.settled_submissions.remove(id);
            state.queued_cancellations.remove(id);
            if state.selected.as_deref() == Some(id) {
                state.selected = None;
            }
            Ok(())
        })?;
        let (managed_files, lock_file) = if managed {
            (
                managed_chat_files(&chat.snapshot),
                Some(chat.snapshot.with_extension("lock")),
            )
        } else {
            (Vec::new(), None)
        };
        Ok(DeletedChat {
            record: chat,
            managed_files,
            lock_file,
        })
    }
}

/// Rename a chat that has no loaded writer: take its checkpoint's writer lock
/// (refused while another writer holds it), check its identity and write the
/// title, as a loaded chat's `Controller::rename` does.
pub fn rename_saved_checkpoint(snapshot: &Path, id: &str, title: &str) -> Result<()> {
    let title = ChatRecord::normalized_title(title)?;
    let mut store = crate::SessionStore::open_existing_with_id(snapshot, id)?;
    // The first turn names a chat with no messages and would overwrite this.
    if store.snapshot().messages.is_empty() {
        return Err(invalid("Send a first message before renaming this chat."));
    }
    if store.snapshot().title == title {
        return Ok(());
    }
    store.transact(|session| {
        session.title = title;
        Ok(())
    })
}

/// The checkpoint and its `<name>.<generation>.stream.jsonl` journals, the
/// files `SessionStore` writes for one chat. Only exact names in the
/// checkpoint's own directory are listed; nothing is followed or globbed.
fn managed_chat_files(snapshot: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    if snapshot.is_file() {
        files.push(snapshot.to_owned());
    }
    let (Some(directory), Some(name)) = (snapshot.parent(), snapshot.file_name()) else {
        return files;
    };
    let prefix = format!("{}.", name.to_string_lossy());
    let Ok(entries) = fs::read_dir(directory) else {
        return files;
    };
    let mut journals: Vec<_> = entries
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_prefix(&prefix))
                .and_then(|rest| rest.strip_suffix(".stream.jsonl"))
                .is_some_and(|generation| Uuid::parse_str(generation).is_ok())
        })
        .collect();
    journals.sort();
    files.extend(journals);
    files
}

#[cfg(test)]
#[path = "workspace_chat_lifecycle_tests.rs"]
mod tests;
