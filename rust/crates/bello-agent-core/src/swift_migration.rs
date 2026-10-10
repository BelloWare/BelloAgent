//! Bringing a Swift Bello Agent project's chats into this Rust workspace, with
//! a way back. Swift's files are copied, never written: the Swift app keeps
//! every chat as it was, so going back to it is always possible. Before the
//! Rust workspace changes its catalog file is copied aside; the chats and
//! topics then arrive in one commit, and a manifest names exactly what came,
//! so `undo` takes out those chats again (one continued in Rust since stays)
//! and sets their files aside rather than deleting them.
//!
//! What a chat carries is `swift_import`'s; which chats, `swift_catalog`'s:
//! the project's listed chats, less the app's own (title requests, connection
//! tests) and chats never sent. Kept sides come as chats of their own.
use crate::swift_catalog::{self, Chat as SwiftChat};
use crate::swift_import::{self, Left};
use crate::swift_journal;
use crate::workspace::{
    ChatRecord, ChatToolMode, DraftRecord, TopicRecord, WorkspaceStore, organization_timestamp,
};
use crate::{Result, SessionStore, invalid};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

/// What an import did, as its manifest keeps it.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Manifest {
    pub version: u32,
    /// When it ran, in microseconds since 1970.
    pub at: u64,
    /// The Swift data folder it read.
    pub source: PathBuf,
    pub project: PathBuf,
    /// The Rust catalog file as it was before, copied aside; none when the
    /// project had no Rust catalog yet.
    pub backup: Option<PathBuf>,
    pub chats: Vec<Brought>,
    /// Topics it added.
    pub topics: Vec<String>,
    pub skipped: Vec<Skipped>,
    /// Chat rows Swift itself does not list (another version's shape).
    pub unlisted: usize,
}

/// A chat the import brought.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Brought {
    pub rust_id: String,
    pub swift_id: String,
    pub title: String,
    pub snapshot: PathBuf,
    /// The snapshot as written: a chat whose file still reads so was not
    /// continued in Rust.
    pub sha256: String,
    /// What of it stayed behind, by kind.
    pub left: Vec<(String, usize)>,
}

/// A chat the import did not bring, and why.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Skipped {
    pub swift_id: String,
    pub title: String,
    pub reason: String,
}

/// What `undo` did.
#[derive(Clone, Debug, PartialEq)]
pub struct Undone {
    pub removed: Vec<String>,
    /// Chats continued in Rust since the import, which stay.
    pub kept: Vec<String>,
    /// Where their files were set aside.
    pub set_aside: PathBuf,
}

/// A Rust chat or topic identity for a Swift one: the same UUID when it is
/// one, else one derived from it, so a second import finds the first.
pub fn rust_identity(swift_id: &str) -> String {
    match Uuid::parse_str(swift_id) {
        Ok(uuid) => uuid.to_string(),
        Err(_) => {
            let digest = Sha256::digest(format!("bello-swift-import:{swift_id}").as_bytes());
            let mut bytes = [0u8; 16];
            bytes.copy_from_slice(&digest[..16]);
            bytes[6] = (bytes[6] & 0x0f) | 0x50;
            bytes[8] = (bytes[8] & 0x3f) | 0x80;
            Uuid::from_bytes(bytes).to_string()
        }
    }
}

fn private_directory(path: &Path) -> Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path)?;
    Ok(())
}

fn sha256(path: &Path) -> Result<String> {
    Ok(format!("{:x}", Sha256::digest(fs::read(path)?)))
}

fn same_folder(swift: &str, project: &Path) -> bool {
    let swift = Path::new(swift);
    fs::canonicalize(swift).map_or_else(|_| swift == project, |canonical| canonical == project)
}

fn left_counts(left: &Left) -> Vec<(String, usize)> {
    [
        ("progress rows", left.progress),
        ("edit markers", left.edit_markers),
        ("rows an edit hid", left.hidden),
        ("unowned tool results", left.unowned_results),
        ("unchecked summaries", left.unchecked_summaries),
        (
            "queued input with images or skills",
            left.queued_with_content,
        ),
        ("other rows", left.other),
    ]
    .into_iter()
    .filter(|(_, count)| *count > 0)
    .map(|(kind, count)| (kind.to_owned(), count))
    .collect()
}

/// Brings the chats of this workspace's project from the Swift data folder
/// `source` (Bello Agent's Application Support folder). Writes the manifest
/// beside the catalog, in `imports/`, and returns it with its path.
pub fn import(source: &Path, workspace: &mut WorkspaceStore) -> Result<(PathBuf, Manifest)> {
    let state = workspace.snapshot();
    let at = organization_timestamp();
    let folder = workspace
        .file()
        .parent()
        .ok_or_else(|| invalid("The Rust workspace has no folder"))?
        .join("imports")
        .join(at.to_string());
    private_directory(&folder)?;
    let copies = folder.join("copies");
    private_directory(&copies)?;
    let result = bring(source, workspace, &state.project, at, &folder, &copies);
    // The copies were for reading; the Swift originals stay where they are.
    let _ = fs::remove_dir_all(&copies);
    result
}

fn bring(
    source: &Path,
    workspace: &mut WorkspaceStore,
    project: &Path,
    at: u64,
    folder: &Path,
    copies: &Path,
) -> Result<(PathBuf, Manifest)> {
    // The store with its newest writes: the WAL file goes with it.
    let store = source.join("desktop.sqlite");
    if !store.is_file() {
        return Err(invalid(format!(
            "No Bello Agent chats were found at {}",
            source.display()
        )));
    }
    let copy = copies.join("desktop.sqlite");
    fs::copy(&store, &copy)?;
    for suffix in ["-wal", "-shm"] {
        let side = source.join(format!("desktop.sqlite{suffix}"));
        if side.is_file() {
            fs::copy(&side, copies.join(format!("desktop.sqlite{suffix}")))?;
        }
    }
    let catalog = swift_catalog::read(&copy)?;
    let swift_project = catalog
        .workspaces
        .iter()
        .find(|workspace| same_folder(&workspace.path, project))
        .ok_or_else(|| {
            invalid(format!(
                "Bello Agent has no project at {}",
                project.display()
            ))
        })?;
    let existing: BTreeSet<String> = workspace
        .snapshot()
        .chats
        .iter()
        .map(|chat| chat.id.clone())
        .collect();
    let mut skipped = Vec::new();
    let mut prepared = Vec::new();
    let candidates: Vec<&SwiftChat> = catalog
        .chats
        .iter()
        .filter(|chat| chat.workspace_id() == swift_project.id && !chat.is_utility())
        .collect();
    for (index, chat) in candidates.into_iter().enumerate() {
        let skip = |reason: String| Skipped {
            swift_id: chat.id().to_owned(),
            title: chat.title().to_owned(),
            reason,
        };
        let rust_id = rust_identity(chat.id());
        if existing.contains(&rust_id) {
            skipped.push(skip("Already in this project (imported before)".into()));
            continue;
        }
        let Some(journal) = chat.path() else {
            skipped.push(skip("Never sent: there is no conversation yet".into()));
            continue;
        };
        let copied = copies.join(format!("chat-{index}.jsonl"));
        let bytes = match fs::copy(journal, &copied).and_then(|_| fs::read(&copied)) {
            Ok(bytes) => bytes,
            Err(error) => {
                skipped.push(skip(format!(
                    "The conversation file cannot be read: {error}"
                )));
                continue;
            }
        };
        let replay = match swift_journal::replay(&bytes, chat.id()) {
            Ok(replay) => replay,
            Err(refused) => {
                skipped.push(skip(format!(
                    "Bello Agent would not open it: {}",
                    refused.message
                )));
                continue;
            }
        };
        match swift_import::session(&replay, &rust_id, chat.title()) {
            Ok(imported) => prepared.push((chat, rust_id, imported)),
            Err(error) => skipped.push(skip(error.to_string())),
        }
    }
    let known_topics: BTreeSet<String> = workspace
        .snapshot()
        .topics
        .iter()
        .map(|topic| topic.id.clone())
        .collect();
    let topics: Vec<TopicRecord> = catalog
        .topics
        .iter()
        .filter(|topic| topic.workspace_id == swift_project.id)
        .filter_map(|topic| {
            let id = rust_identity(&topic.id);
            (!known_topics.contains(&id)).then_some(())?;
            Some(TopicRecord {
                id,
                title: TopicRecord::normalized_title(&topic.title).ok()?,
                created_at: ((topic.created_at + 978_307_200.0) * 1_000_000.0).max(0.0) as u64,
                expanded: topic.expanded,
                revision: 0,
            })
        })
        .collect();
    let topic_ids: BTreeSet<String> = topics
        .iter()
        .map(|topic| topic.id.clone())
        .chain(known_topics)
        .collect();
    // Aside first, then the chats' files, then one catalog commit.
    let backup = if workspace.file().exists() {
        let backup = folder.join("workspace.before.json");
        fs::copy(workspace.file(), &backup)?;
        Some(backup)
    } else {
        None
    };
    let mut records = Vec::new();
    let mut brought = Vec::new();
    for (chat, rust_id, imported) in prepared {
        let snapshot = workspace.chat_path(&rust_id)?;
        let left = left_counts(&imported.left);
        if let Err(error) = SessionStore::create_imported(&snapshot, imported.session) {
            skipped.push(Skipped {
                swift_id: chat.id().to_owned(),
                title: chat.title().to_owned(),
                reason: format!("The Rust chat could not be written: {error}"),
            });
            continue;
        }
        let mut record =
            ChatRecord::new(rust_id.clone(), chat.title().to_owned(), snapshot.clone());
        record.tool_mode = if chat.read_only() {
            ChatToolMode::ReadOnly
        } else {
            ChatToolMode::Editing
        };
        let micros = |value: Option<i64>| value.and_then(|value| u64::try_from(value).ok());
        record.sidebar_order = micros(chat.sidebar_order());
        record.last_activity_at = micros(chat.last_activity_at());
        record.pinned_at = micros(chat.pinned_at());
        record.archived_at = micros(chat.archived_at());
        record.topic_id = chat
            .topic()
            .map(rust_identity)
            .filter(|id| topic_ids.contains(id));
        let draft = catalog
            .drafts
            .get(chat.id())
            .map(|draft| DraftRecord {
                text: draft.text.clone(),
                ..DraftRecord::default()
            })
            .unwrap_or_default();
        brought.push(Brought {
            rust_id,
            swift_id: chat.id().to_owned(),
            title: chat.title().to_owned(),
            sha256: sha256(&snapshot)?,
            snapshot,
            left,
        });
        records.push((record, draft));
    }
    if let Err(error) = workspace.import_records(topics.clone(), records) {
        // Unregistered files are set aside, not left as strays or deleted.
        let aside = folder.join("not-registered");
        private_directory(&aside)?;
        for chat in &brought {
            set_aside(&chat.snapshot, &aside);
        }
        return Err(error);
    }
    let manifest = Manifest {
        version: 1,
        at,
        source: source.to_owned(),
        project: project.to_owned(),
        backup,
        chats: brought,
        topics: topics.into_iter().map(|topic| topic.id).collect(),
        skipped,
        unlisted: catalog.unlisted,
    };
    let path = folder.join("manifest.json");
    write_private(&path, &serde_json::to_vec_pretty(&manifest)?)?;
    Ok((path, manifest))
}

fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}

/// Moves a chat's files (its snapshot, lock and stream journals) into `aside`.
fn set_aside(snapshot: &Path, aside: &Path) {
    let (Some(folder), Some(name)) = (snapshot.parent(), snapshot.file_name()) else {
        return;
    };
    let stem = snapshot.with_extension("");
    let stem = stem
        .file_name()
        .map(|stem| stem.to_string_lossy().into_owned());
    let Ok(entries) = fs::read_dir(folder) else {
        return;
    };
    for entry in entries.flatten() {
        let file = entry.file_name();
        let text = file.to_string_lossy();
        let belongs = file == name
            || stem
                .as_ref()
                .is_some_and(|stem| text.starts_with(&format!("{stem}.")));
        if belongs {
            let _ = fs::rename(entry.path(), aside.join(&file));
        }
    }
}

/// Takes out what the import with this manifest brought: its chats whose
/// files still read as written, and its topics no chat is left in.
pub fn undo(workspace: &mut WorkspaceStore, manifest: &Path) -> Result<Undone> {
    let record: Manifest = serde_json::from_slice(&fs::read(manifest)?)?;
    let registered: BTreeSet<String> = workspace
        .snapshot()
        .chats
        .iter()
        .map(|chat| chat.id.clone())
        .collect();
    let mut removed = Vec::new();
    let mut kept = Vec::new();
    for chat in &record.chats {
        if !registered.contains(&chat.rust_id) {
            continue;
        }
        if sha256(&chat.snapshot).ok().as_deref() == Some(chat.sha256.as_str()) {
            removed.push(chat.rust_id.clone());
        } else {
            kept.push(chat.rust_id.clone());
        }
    }
    let ids: BTreeSet<String> = removed.iter().cloned().collect();
    let topics: BTreeSet<String> = record.topics.iter().cloned().collect();
    workspace.remove_imported(&ids, &topics)?;
    let aside = manifest
        .parent()
        .ok_or_else(|| invalid("The import record has no folder"))?
        .join("undone");
    private_directory(&aside)?;
    for chat in record
        .chats
        .iter()
        .filter(|chat| ids.contains(&chat.rust_id))
    {
        set_aside(&chat.snapshot, &aside);
    }
    Ok(Undone {
        removed,
        kept,
        set_aside: aside,
    })
}

#[cfg(test)]
#[path = "swift_migration_tests.rs"]
mod tests;
