use super::read;
use serde_json::{Value, json};
use std::path::PathBuf;

/// `desktop.sqlite` as Swift 0.1.122's own `MetadataStore` wrote it (projects,
/// a topic, a draft and chats of every kind, plus rows another version left)
/// and Swift's listing of it (`loadChats`): harness in
/// rust/docs/validation/swift-import-oracle-2026-10-10/metadata.
fn data(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data/swift-catalog")
        .join(name)
}

/// A private copy of the store, as the importer reads one.
fn copy() -> (tempfile::TempDir, PathBuf) {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("desktop.sqlite");
    std::fs::copy(data("desktop.sqlite"), &path).unwrap();
    (directory, path)
}

/// Equal as Swift's JSON is equal: every number a double.
fn same(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Number(a), Value::Number(b)) => a.as_f64() == b.as_f64(),
        (Value::Object(a), Value::Object(b)) => {
            a.len() == b.len()
                && a.iter()
                    .all(|(key, value)| b.get(key).is_some_and(|other| same(value, other)))
        }
        _ => left == right,
    }
}

#[test]
fn chats_are_listed_as_swifts_sidebar_lists_them() {
    let (_directory, path) = copy();
    let catalog = read(&path).unwrap();
    let swift: Value =
        serde_json::from_slice(&std::fs::read(data("swift-listing.json")).unwrap()).unwrap();
    let expected = swift["chats"].as_array().unwrap();
    let ids: Vec<&str> = catalog.chats.iter().map(|chat| chat.id()).collect();
    let swift_ids: Vec<&str> = expected
        .iter()
        .map(|chat| chat["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, swift_ids);
    for (chat, swift) in catalog.chats.iter().zip(expected) {
        assert!(
            same(&Value::Object(chat.fields.clone()), swift),
            "{}\n  swift: {swift}\n  rust:  {:?}",
            chat.id(),
            chat.fields
        );
    }
    assert_eq!(
        catalog.unlisted,
        swift["unlisted"].as_u64().unwrap() as usize
    );
}

#[test]
fn a_row_past_swifts_size_limit_is_not_listed() {
    let (_directory, path) = copy();
    let before = read(&path).unwrap().unlisted;
    let connection = rusqlite::Connection::open(&path).unwrap();
    let huge = json!({"id": "C-huge", "workspaceID": "W-A", "title": "x".repeat(600_000),
        "profileID": "P-1", "toolMode": "editing", "imported": false});
    connection
        .execute(
            "INSERT INTO records(kind, id, value, revision) VALUES('chat', 'C-huge', ?1, 1)",
            [serde_json::to_vec(&huge).unwrap()],
        )
        .unwrap();
    drop(connection);
    let catalog = read(&path).unwrap();
    assert_eq!(catalog.unlisted, before + 1);
    assert!(catalog.chats.iter().all(|chat| chat.id() != "C-huge"));
}

#[test]
fn projects_topics_and_drafts_are_read() {
    let (_directory, path) = copy();
    let catalog = read(&path).unwrap();
    let mut workspaces: Vec<(&str, &str, bool, Vec<String>)> = catalog
        .workspaces
        .iter()
        .map(|w| (w.id.as_str(), w.path.as_str(), w.trusted, w.paths.clone()))
        .collect();
    workspaces.sort();
    assert_eq!(
        workspaces,
        [
            (
                "W-A",
                "/Users/someone/project-a",
                true,
                vec!["/Users/someone/shared".to_owned()]
            ),
            ("W-B", "/Users/someone/project-b", false, vec![]),
            ("scratch", "/Users/someone/Library/Scratch", true, vec![]),
        ]
    );
    assert_eq!(catalog.topics.len(), 1);
    assert_eq!(catalog.topics[0].title, "Parser work");
    assert!(!catalog.topics[0].expanded);
    assert_eq!(catalog.drafts["C-plain"].text, "Unsent words");
    let chat = |id: &str| catalog.chats.iter().find(|chat| chat.id() == id).unwrap();
    // Foundation dates count seconds from 2001: 780,000,060 s is 2025-09-19.
    assert_eq!(
        chat("C-pinned").pinned_at(),
        Some((780_000_060 + 978_307_200) * 1_000_000)
    );
    assert_eq!(
        chat("C-archived").archived_at(),
        Some((780_000_120 + 978_307_200) * 1_000_000)
    );
    assert!(chat("C-title").is_utility() && chat("C-test").is_utility());
    assert_eq!(chat("C-side").parent(), Some("C-plain"));
    assert_eq!(chat("C-pathless").path(), None);
    assert!(chat("C-title").read_only());
}
