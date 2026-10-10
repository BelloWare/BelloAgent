//! A Swift Bello Agent chat list (`desktop.sqlite`), read as Swift 0.1.122's
//! sidebar reads it (`MetadataStore.loadChats`): which chats it lists, in its
//! order, with their projects, topics and unsent drafts. Read from a copy the
//! importer made; nothing here opens a Swift app's own store.
//!
//! The store is one table of JSON records by kind. A chat row is listed when
//! it is at most 512 KiB and decodes as Swift's `ChatRecord`: synthesized
//! Codable needs every non-optional property's key (a default value does not
//! stand in for a missing one), and a present optional key must hold its type.
//! A chat with no creation order takes its row revision. The order: pinned
//! first, then the newest activity, then the id. An oracle built from the
//! Swift sources pins it (`swift_catalog_tests.rs`).
use rusqlite::{Connection, OpenFlags, types::ValueRef};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

/// `loadChats`: rows past this many bytes are not decoded.
const MAXIMUM_CHAT_BYTES: usize = 524_288;
/// Seconds from 1970 to 2001, where Foundation's `Date` counts from.
const REFERENCE_DATE_UNIX: f64 = 978_307_200.0;

#[derive(Clone, Debug, PartialEq)]
pub struct Workspace {
    pub id: String,
    /// The primary folder: the project's path.
    pub path: String,
    pub trusted: bool,
    /// Further trusted folders.
    pub paths: Vec<String>,
}

/// A listed chat: Swift's `ChatRecord` fields, checked.
#[derive(Clone, Debug, PartialEq)]
pub struct Chat {
    /// Every field the record holds that Swift's `ChatRecord` has, by its
    /// key, as decoded (the creation order filled in from the revision).
    pub fields: Map<String, Value>,
}

impl Chat {
    fn text(&self, key: &str) -> Option<&str> {
        self.fields.get(key).and_then(Value::as_str)
    }
    pub fn id(&self) -> &str {
        self.text("id").unwrap_or_default()
    }
    pub fn workspace_id(&self) -> &str {
        self.text("workspaceID").unwrap_or_default()
    }
    pub fn title(&self) -> &str {
        self.text("title").unwrap_or_default()
    }
    /// The chat's journal, once it has one.
    pub fn path(&self) -> Option<&str> {
        self.text("path")
    }
    pub fn read_only(&self) -> bool {
        self.text("toolMode") == Some("read-only")
    }
    /// A chat the app ran for itself: a background request or a connection test.
    pub fn is_utility(&self) -> bool {
        self.fields.contains_key("backgroundTask")
            || self.fields.get("connectionTest").and_then(Value::as_bool) == Some(true)
    }
    /// A kept side chat's parent.
    pub fn parent(&self) -> Option<&str> {
        self.text("parentSessionID")
    }
    pub fn topic(&self) -> Option<&str> {
        self.text("topicID")
    }
    /// Microseconds since 1970.
    pub fn sidebar_order(&self) -> Option<i64> {
        self.fields.get("sidebarOrder").and_then(Value::as_i64)
    }
    pub fn last_activity_at(&self) -> Option<i64> {
        self.fields.get("lastActivityAt").and_then(Value::as_i64)
    }
    /// A `Date`, as microseconds since 1970.
    fn date(&self, key: &str) -> Option<i64> {
        let seconds = self.fields.get(key)?.as_f64()?;
        Some(((seconds + REFERENCE_DATE_UNIX) * 1_000_000.0).round() as i64)
    }
    pub fn pinned_at(&self) -> Option<i64> {
        self.date("pinnedAt")
    }
    pub fn archived_at(&self) -> Option<i64> {
        self.date("archivedAt")
    }
    /// `activityStamp`: its last activity, else when it was made.
    fn activity(&self) -> i64 {
        self.last_activity_at()
            .unwrap_or(0)
            .max(self.sidebar_order().unwrap_or(0))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Topic {
    pub id: String,
    pub workspace_id: String,
    pub title: String,
    /// Seconds since 2001, as Swift keeps it.
    pub created_at: f64,
    pub expanded: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Draft {
    pub text: String,
    /// Images or skills in the composer, which the import does not carry.
    pub has_content: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Catalog {
    pub workspaces: Vec<Workspace>,
    /// The listed chats, in the sidebar's order.
    pub chats: Vec<Chat>,
    /// Chat rows Swift does not list: too large, or of another shape.
    pub unlisted: usize,
    pub topics: Vec<Topic>,
    pub drafts: BTreeMap<String, Draft>,
}

#[derive(Clone, Copy)]
enum Kind {
    Text,
    Flag,
    /// An integer (`Int`, `Int64`).
    Integer,
    /// A `Date` or `Double`.
    Number,
    /// `CostLimit`: dollars, or "none".
    CostLimit,
}

/// `ChatRecord`'s properties: required ones need their key.
const CHAT_FIELDS: &[(&str, Kind, bool)] = &[
    ("id", Kind::Text, true),
    ("workspaceID", Kind::Text, true),
    ("title", Kind::Text, true),
    ("path", Kind::Text, false),
    ("profileID", Kind::Text, true),
    ("toolMode", Kind::Text, true),
    ("imported", Kind::Flag, true),
    ("connectionTest", Kind::Flag, false),
    ("model", Kind::Text, false),
    ("thinkingLevel", Kind::Text, false),
    ("contextWindow", Kind::Integer, false),
    ("maxOutputTokens", Kind::Integer, false),
    ("modelOutputLimit", Kind::Integer, false),
    ("outputBudgetVersion", Kind::Integer, false),
    ("sidebarOrder", Kind::Integer, false),
    ("lastActivityAt", Kind::Integer, false),
    ("pinnedAt", Kind::Number, false),
    ("archivedAt", Kind::Number, false),
    ("titleWasEdited", Kind::Flag, false),
    ("titleWasGenerated", Kind::Flag, false),
    ("titleTaskSessionID", Kind::Text, false),
    ("backgroundTask", Kind::Text, false),
    ("sourceSessionID", Kind::Text, false),
    ("backgroundTaskNotice", Kind::Text, false),
    ("backgroundTaskStartedAt", Kind::Number, false),
    ("backgroundTaskEndedAt", Kind::Number, false),
    ("backgroundTaskOutcome", Kind::Text, false),
    ("backgroundTaskResult", Kind::Text, false),
    ("organizationRevision", Kind::Integer, false),
    ("topicID", Kind::Text, false),
    ("parentSessionID", Kind::Text, false),
    ("costLimit", Kind::CostLimit, false),
    ("webhookOff", Kind::Flag, false),
    ("connectionRevision", Kind::Integer, false),
    ("journalRebind", Kind::Flag, false),
];

fn holds(value: &Value, kind: Kind) -> bool {
    match kind {
        Kind::Text => value.is_string(),
        Kind::Flag => value.is_boolean(),
        Kind::Integer => value.is_i64() || value.is_u64(),
        Kind::Number => value.is_number(),
        Kind::CostLimit => value.is_number() || value.as_str() == Some("none"),
    }
}

/// `JSONDecoder().decode(ChatRecord.self, ...)`: the fields, or nil.
fn decode_chat(bytes: &[u8]) -> Option<Chat> {
    let Value::Object(object) = serde_json::from_slice::<Value>(bytes).ok()? else {
        return None;
    };
    let mut fields = Map::new();
    for &(key, kind, required) in CHAT_FIELDS {
        match object.get(key) {
            None | Some(Value::Null) if required => return None,
            None | Some(Value::Null) => {}
            Some(value) if holds(value, kind) => {
                fields.insert(key.to_owned(), value.clone());
            }
            Some(_) => return None,
        }
    }
    Some(Chat { fields })
}

fn blob(value: ValueRef<'_>) -> Option<Vec<u8>> {
    match value {
        ValueRef::Blob(bytes) | ValueRef::Text(bytes) => Some(bytes.to_vec()),
        _ => None,
    }
}

fn records(connection: &Connection, kind: &str) -> rusqlite::Result<Vec<(String, Vec<u8>)>> {
    let mut statement = connection.prepare("SELECT id, value FROM records WHERE kind = ?1")?;
    let rows = statement.query_map([kind], |row| {
        Ok((
            row.get::<_, String>(0)?,
            blob(row.get_ref(1)?).unwrap_or_default(),
        ))
    })?;
    rows.collect()
}

/// Reads a copy of a Swift store that the caller owns: `desktop.sqlite`
/// copied with its `-wal` file, which opening the copy replays into it (a
/// Swift store keeps its newest writes there). Never the Swift app's own file.
pub fn read(path: &Path) -> crate::Result<Catalog> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|error| {
        crate::invalid(format!(
            "The Bello Agent chat list cannot be opened: {error}"
        ))
    })?;
    read_from(&connection).map_err(|error| {
        crate::invalid(format!("The Bello Agent chat list cannot be read: {error}"))
    })
}

fn read_from(connection: &Connection) -> rusqlite::Result<Catalog> {
    let mut chats = Vec::new();
    {
        let mut statement = connection.prepare(
            "SELECT value, revision FROM records WHERE kind = 'chat' ORDER BY revision DESC, id ASC LIMIT 10000",
        )?;
        let mut rows = statement.query([])?;
        while let Some(row) = rows.next()? {
            let Some(bytes) =
                blob(row.get_ref(0)?).filter(|bytes| bytes.len() <= MAXIMUM_CHAT_BYTES)
            else {
                continue;
            };
            let Some(mut chat) = decode_chat(&bytes) else {
                continue;
            };
            if !chat.fields.contains_key("sidebarOrder") {
                chat.fields
                    .insert("sidebarOrder".into(), row.get::<_, i64>(1)?.into());
            }
            chats.push(chat);
        }
    }
    let total: i64 = connection.query_row(
        "SELECT COUNT(*) FROM records WHERE kind = 'chat'",
        [],
        |row| row.get(0),
    )?;
    // `ChatRecord.sidebarPrecedes`.
    chats.sort_by(|a, b| {
        b.pinned_at()
            .is_some()
            .cmp(&a.pinned_at().is_some())
            .then(b.activity().cmp(&a.activity()))
            .then(a.id().cmp(b.id()))
    });
    let workspaces = records(connection, "workspace")?
        .into_iter()
        .filter_map(|(_, bytes)| {
            let value: Value = serde_json::from_slice(&bytes).ok()?;
            Some(Workspace {
                id: value["id"].as_str()?.to_owned(),
                path: value["path"].as_str()?.to_owned(),
                trusted: value["trusted"].as_bool()?,
                paths: match &value["paths"] {
                    Value::Null => Vec::new(),
                    paths => paths
                        .as_array()?
                        .iter()
                        .map(|path| path.as_str().map(str::to_owned))
                        .collect::<Option<_>>()?,
                },
            })
        })
        .collect();
    let deleted: BTreeSet<String> = records(connection, "topic-deleted")?
        .into_iter()
        .map(|(id, _)| id)
        .collect();
    let mut topics: Vec<Topic> = records(connection, "topic")?
        .into_iter()
        .filter(|(id, _)| !deleted.contains(id))
        .filter_map(|(_, bytes)| {
            let value: Value = serde_json::from_slice(&bytes).ok()?;
            // `TopicRecord` decodes every key, the revision included.
            if !(value["revision"].is_i64() || value["revision"].is_u64()) {
                return None;
            }
            Some(Topic {
                id: value["id"].as_str()?.to_owned(),
                workspace_id: value["workspaceID"].as_str()?.to_owned(),
                title: value["title"].as_str()?.to_owned(),
                created_at: value["createdAt"].as_f64()?,
                expanded: value["expanded"].as_bool()?,
            })
        })
        .collect();
    topics.sort_by(|a, b| a.created_at.total_cmp(&b.created_at).then(a.id.cmp(&b.id)));
    let drafts = records(connection, "draft")?
        .into_iter()
        .filter_map(|(id, bytes)| {
            let value: Value = serde_json::from_slice(&bytes).ok()?;
            let listed = |key: &str| value[key].as_array().is_some_and(|items| !items.is_empty());
            Some((
                id,
                Draft {
                    text: value["text"].as_str()?.to_owned(),
                    has_content: listed("attachments") || listed("skills"),
                },
            ))
        })
        .collect();
    Ok(Catalog {
        workspaces,
        unlisted: usize::try_from(total)
            .unwrap_or(0)
            .saturating_sub(chats.len()),
        chats,
        topics,
        drafts,
    })
}

#[cfg(test)]
#[path = "swift_catalog_tests.rs"]
mod tests;
