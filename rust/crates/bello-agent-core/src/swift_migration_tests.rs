use super::{import, rust_identity, undo};
use crate::SessionStore;
use crate::workspace::{ChatToolMode, WorkspaceStore};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

fn fixture(folder: &str, name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data")
        .join(folder)
        .join(name)
}

/// Swift chats with Swift-written journals, in a project: the scenario
/// journals, filed in the Swift chat list the way the app files them.
const CHATS: &[(&str, &str)] = &[
    ("plain", "Markdown and code"),
    ("tools", "Tools at work"),
    ("compaction", "A long chat, compacted"),
    ("edit", "An edited question"),
    ("steer", "Steered"),
    ("forked", "Before the fork"),
    ("fork", "The fork"),
    ("side", "A side, kept"),
];

struct Setup {
    _root: tempfile::TempDir,
    swift: PathBuf,
    project: PathBuf,
    catalog: PathBuf,
}

fn setup() -> Setup {
    let root = tempfile::tempdir().unwrap();
    let swift = root.path().join("com.belloware.PiApp");
    let sessions = swift.join("sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    let project = root.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    let project = std::fs::canonicalize(project).unwrap();
    let store = swift.join("desktop.sqlite");
    std::fs::copy(fixture("swift-catalog", "desktop.sqlite"), &store).unwrap();
    let connection = rusqlite::Connection::open(&store).unwrap();
    // Project A is this project.
    let workspace = json!({"id": "W-A", "path": project, "trusted": true, "paths": []});
    connection
        .execute(
            "UPDATE records SET value = ?1 WHERE kind = 'workspace' AND id = 'W-A'",
            [serde_json::to_vec(&workspace).unwrap()],
        )
        .unwrap();
    for (index, (id, title)) in CHATS.iter().enumerate() {
        let journal = sessions.join(format!("{id}.jsonl"));
        std::fs::copy(fixture("swift-journal", &format!("{id}.jsonl")), &journal).unwrap();
        let mut record = json!({
            "id": id, "workspaceID": "W-A", "title": title, "path": journal,
            "profileID": "P-1", "toolMode": "editing", "imported": false,
            "outputBudgetVersion": 1, "sidebarOrder": 1_795_000_000_000_000i64 - index as i64,
        });
        match *id {
            "plain" => record["pinnedAt"] = json!(790_000_000.5),
            "edit" => record["archivedAt"] = json!(790_000_100),
            "tools" => record["topicID"] = json!("T-1"),
            "side" => record["parentSessionID"] = json!("forked"),
            _ => {}
        }
        connection
            .execute(
                "INSERT INTO records(kind, id, value, revision) VALUES('chat', ?1, ?2, ?3)",
                rusqlite::params![id, serde_json::to_vec(&record).unwrap(), 10 + index as i64],
            )
            .unwrap();
    }
    connection
        .execute(
            "INSERT INTO records(kind, id, value, revision) VALUES('draft', 'plain', ?1, 1)",
            [serde_json::to_vec(&json!({"id": "plain", "text": "Next question"})).unwrap()],
        )
        .unwrap();
    drop(connection);
    let catalog = root.path().join("rust").join("workspace.json");
    Setup {
        _root: root,
        swift,
        project,
        catalog,
    }
}

fn workspace(setup: &Setup) -> WorkspaceStore {
    WorkspaceStore::open(&setup.catalog, &setup.project).unwrap()
}

#[test]
fn a_projects_swift_chats_arrive_as_rust_chats_and_go_back_out() {
    let setup = setup();
    let swift_before: Vec<(PathBuf, Vec<u8>)> = std::fs::read_dir(setup.swift.join("sessions"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .chain([setup.swift.join("desktop.sqlite")])
        .map(|path| {
            let bytes = std::fs::read(&path).unwrap();
            (path, bytes)
        })
        .collect();
    let mut store = workspace(&setup);
    let (manifest_path, manifest) = import(&setup.swift, &mut store).unwrap();

    // Every scenario chat came; the fixture's own chats (whose files are
    // elsewhere) and the one never sent are reported, the app's own and the
    // other project's are not candidates.
    let brought: Vec<&str> = manifest
        .chats
        .iter()
        .map(|chat| chat.swift_id.as_str())
        .collect();
    let mut expected: Vec<&str> = CHATS.iter().map(|(id, _)| *id).collect();
    expected.sort();
    let mut sorted = brought.clone();
    sorted.sort();
    assert_eq!(sorted, expected);
    let skipped: Vec<(&str, &str)> = manifest
        .skipped
        .iter()
        .map(|skip| (skip.swift_id.as_str(), skip.reason.as_str()))
        .collect();
    assert!(skipped.contains(&("C-pathless", "Never sent: there is no conversation yet")));
    assert!(skipped.iter().any(|(id, reason)| *id == "C-plain"
        && reason.starts_with("The conversation file cannot be read")));
    assert!(
        skipped
            .iter()
            .all(|(id, _)| !["C-title", "C-test", "C-other"].contains(id))
    );
    assert_eq!(manifest.unlisted, 2);

    // The catalog: titles, order, pin, archive, topic, draft and tool mode.
    let state = store.snapshot();
    let chat = |swift: &str| {
        state
            .chats
            .iter()
            .find(|chat| chat.id == rust_identity(swift))
            .unwrap()
            .clone()
    };
    assert_eq!(chat("plain").title, "Markdown and code");
    assert_eq!(chat("plain").pinned_at, Some(1_768_307_200_500_000));
    assert_eq!(chat("edit").archived_at, Some(1_768_307_300_000_000));
    assert_eq!(chat("tools").topic_id, Some(rust_identity("T-1")));
    assert!(
        state
            .topics
            .iter()
            .any(|topic| topic.title == "Parser work")
    );
    assert_eq!(state.drafts[&rust_identity("plain")].text, "Next question");
    assert_eq!(chat("steer").sidebar_order, Some(1_795_000_000_000_000 - 4));
    assert_eq!(chat("side").tool_mode, ChatToolMode::Editing);

    // Each chat opens through Rust's ordinary store, as written.
    for brought in &manifest.chats {
        let store = SessionStore::open_existing_with_id(&brought.snapshot, &brought.rust_id)
            .unwrap_or_else(|error| panic!("{}: {error}", brought.swift_id));
        assert!(
            !store.snapshot().messages.is_empty(),
            "{}",
            brought.swift_id
        );
    }

    // A second import finds every chat already here.
    let (_, again) = import(&setup.swift, &mut store).unwrap();
    assert!(again.chats.is_empty());
    assert_eq!(
        again
            .skipped
            .iter()
            .filter(|skip| skip.reason.starts_with("Already in this project"))
            .count(),
        CHATS.len()
    );

    // Undo: a chat continued in Rust stays; the rest go, files set aside.
    let mut record: Value =
        serde_json::from_slice(&std::fs::read(&manifest_path).unwrap()).unwrap();
    record["chats"][0]["sha256"] = json!("continued in Rust");
    let continued = record["chats"][0]["rust_id"].as_str().unwrap().to_owned();
    std::fs::write(&manifest_path, serde_json::to_vec(&record).unwrap()).unwrap();
    let undone = undo(&mut store, &manifest_path).unwrap();
    assert_eq!(undone.kept, std::slice::from_ref(&continued));
    assert_eq!(undone.removed.len(), CHATS.len() - 1);
    let state = store.snapshot();
    assert_eq!(state.chats.len(), 1);
    assert_eq!(state.chats[0].id, continued);
    for chat in manifest
        .chats
        .iter()
        .filter(|chat| chat.rust_id != continued)
    {
        assert!(!chat.snapshot.exists());
        assert!(
            undone
                .set_aside
                .join(chat.snapshot.file_name().unwrap())
                .exists()
        );
    }
    // The topic stays only while a chat is in it.
    assert_eq!(state.topics.is_empty(), state.chats[0].topic_id.is_none());

    // Swift's files read exactly as before.
    for (path, bytes) in swift_before {
        assert_eq!(std::fs::read(&path).unwrap(), bytes, "{}", path.display());
    }
}

#[test]
fn a_folder_bello_agent_never_opened_is_refused() {
    let setup = setup();
    let elsewhere = setup.project.parent().unwrap().join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    let mut store =
        WorkspaceStore::open(setup.catalog.with_file_name("other.json"), &elsewhere).unwrap();
    let error = import(&setup.swift, &mut store).err().unwrap();
    assert!(
        error.to_string().contains("Bello Agent has no project at"),
        "{error}"
    );
    let missing = import(Path::new("/nonexistent/swift"), &mut store)
        .err()
        .unwrap();
    assert!(
        missing
            .to_string()
            .contains("No Bello Agent chats were found"),
        "{missing}"
    );
}

#[test]
fn identities_are_kept_or_derived_stably() {
    let uuid = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
    assert_eq!(rust_identity(uuid), uuid.to_lowercase());
    assert_eq!(rust_identity("plain"), rust_identity("plain"));
    assert_ne!(rust_identity("plain"), rust_identity("tools"));
    assert!(uuid::Uuid::parse_str(&rust_identity("plain")).is_ok());
}
