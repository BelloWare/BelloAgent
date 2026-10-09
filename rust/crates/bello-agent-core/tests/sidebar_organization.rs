use bello_agent_core::{
    Lane,
    workspace::{ChatRecord, DraftRecord, QueuedDraft, SubmissionIntent, WorkspaceStore},
};
use std::path::{Path, PathBuf};
use uuid::Uuid;
fn record(root: &Path, order: u64, title: &str) -> ChatRecord {
    let id = Uuid::new_v4().to_string();
    ChatRecord {
        tool_mode: Default::default(),
        connection_id: None,
        materialization: bello_agent_core::workspace::ChatMaterialization::CheckpointRequired,
        snapshot: root.join(format!("{id}.json")),
        id,
        title: title.into(),
        last_activity_at: None,
        sidebar_order: Some(order),
        pinned_at: None,
        archived_at: None,
        topic_id: None,
        topic_revision: 0,
    }
}
fn fixture() -> (tempfile::TempDir, PathBuf, WorkspaceStore) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workspace.json");
    let store = WorkspaceStore::open(&path, dir.path()).unwrap();
    (dir, path, store)
}
#[test]
fn source_order_and_repeated_pin_keep_original_timestamp() {
    let (dir, path, mut store) = fixture();
    let old = record(dir.path(), 1, "old");
    let new = record(dir.path(), 2, "new");
    let newest = record(dir.path(), 3, "newest");
    for chat in [&old, &new, &newest] {
        store
            .register(chat.clone(), DraftRecord::default())
            .unwrap();
    }
    store
        .set_pinned(new.clone(), DraftRecord::default(), true, 10)
        .unwrap();
    store
        .set_pinned(old.clone(), DraftRecord::default(), true, 20)
        .unwrap();
    let bytes = std::fs::read(&path).unwrap();
    let repeated = store
        .set_pinned(new.clone(), DraftRecord::default(), true, 99)
        .unwrap();
    assert_eq!(repeated.pinned_at, Some(10));
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    let mut rows = store.snapshot().chats;
    rows.sort_by(ChatRecord::sidebar_cmp);
    assert_eq!(
        rows.iter().map(|r| r.title.as_str()).collect::<Vec<_>>(),
        ["new", "old", "newest"]
    );
    store
        .set_pinned(old.clone(), DraftRecord::default(), false, 30)
        .unwrap();
    store
        .set_pinned(new.clone(), DraftRecord::default(), false, 30)
        .unwrap();
    let mut rows = store.snapshot().chats;
    rows.sort_by(ChatRecord::sidebar_cmp);
    assert_eq!(
        rows.iter().map(|r| r.title.as_str()).collect::<Vec<_>>(),
        ["newest", "new", "old"]
    );
    let mut a = new;
    let mut b = old;
    a.sidebar_order = Some(1);
    b.sidebar_order = Some(1);
    a.pinned_at = Some(5);
    b.pinned_at = Some(5);
    assert_eq!(a.sidebar_cmp(&b), a.id.cmp(&b.id));
}
#[test]
fn pending_chat_pin_atomically_materializes_draft_without_a_transcript() {
    let (dir, path, mut store) = fixture();
    let chat = record(dir.path(), 7, "New chat");
    let draft = DraftRecord {
        skills: Vec::new(),
        attachments: Vec::new(),
        revision: 4,
        text: "unsent 你好".into(),
        queued_edit: Some(QueuedDraft {
            edit_id: "edit".into(),
            turn_id: "turn".into(),
            rewrite: "rewrite".into(),
            original_text: Some("original".into()),
        }),
    };
    let saved = store
        .set_pinned(chat.clone(), draft.clone(), true, 11)
        .unwrap();
    assert_eq!(saved.id, chat.id);
    assert!(!chat.snapshot.exists());
    drop(store);
    let store = WorkspaceStore::open(path, dir.path()).unwrap();
    assert_eq!(store.snapshot().chats, vec![saved]);
    assert_eq!(store.snapshot().drafts[&chat.id], draft);
}
#[test]
fn pin_patches_only_organization_not_newer_title_draft_receipt_or_selection() {
    let (dir, _path, mut store) = fixture();
    let chat = record(dir.path(), 1, "before");
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    store.name_chat(&chat.id, "streaming title").unwrap();
    let draft = DraftRecord {
        skills: Vec::new(),
        attachments: Vec::new(),
        revision: 4,
        text: "new typing".into(),
        queued_edit: None,
    };
    store.save_draft(&chat.id, draft.clone()).unwrap();
    let intent = SubmissionIntent {
        skills: Vec::new(),
        attachments: Vec::new(),
        id: Uuid::new_v4().to_string(),
        chat_id: chat.id.clone(),
        text: "accepted maybe".into(),
        lane: Lane::FollowUp,
        draft_revision: 1,
    };
    store.begin_submission(intent.clone()).unwrap();
    store.select(&chat.id, 9).unwrap();
    let saved = store
        .set_pinned(chat.clone(), DraftRecord::default(), true, 10)
        .unwrap();
    let state = store.snapshot();
    assert_eq!(saved.title, "streaming title");
    assert_eq!(state.drafts[&chat.id], draft);
    assert_eq!(state.intents[&intent.id], intent);
    assert_eq!(state.selected.as_deref(), Some(chat.id.as_str()));
    assert_eq!(state.selection_revision, 9);
}
#[test]
fn failed_pending_pin_is_not_materialized_and_can_retry() {
    let (dir, path, mut store) = fixture();
    let chat = record(dir.path(), 1, "pending");
    let before = serde_json::to_vec(&store.snapshot()).unwrap();
    std::fs::create_dir(&path).unwrap();
    assert!(
        store
            .set_pinned(chat.clone(), DraftRecord::default(), true, 2)
            .is_err()
    );
    assert_eq!(serde_json::to_vec(&store.snapshot()).unwrap(), before);
    std::fs::remove_dir(path).unwrap();
    assert!(
        store
            .set_pinned(chat, DraftRecord::default(), true, 2)
            .is_ok()
    );
}
#[test]
fn wrong_identity_and_project_are_rejected_without_overwriting_catalog() {
    let (dir, path, mut store) = fixture();
    let mut chat = record(dir.path(), 1, "saved");
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    let before = std::fs::read(&path).unwrap();
    chat.snapshot = dir.path().join("different.json");
    assert!(
        store
            .set_pinned(chat, DraftRecord::default(), true, 1)
            .is_err()
    );
    assert_eq!(std::fs::read(&path).unwrap(), before);
    drop(store);
    let other = tempfile::tempdir().unwrap();
    assert!(WorkspaceStore::open(&path, other.path()).is_err());
    assert_eq!(std::fs::read(path).unwrap(), before);
}
#[test]
fn legacy_catalog_without_organization_fields_opens_without_rewrite() {
    let (dir, path, mut store) = fixture();
    let mut chat = record(dir.path(), 1, "legacy");
    chat.sidebar_order = None;
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    drop(store);
    let mut legacy: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    legacy["version"] = 1.into();
    legacy["chats"][0]
        .as_object_mut()
        .unwrap()
        .remove("tool_mode");
    legacy["chats"][0]
        .as_object_mut()
        .unwrap()
        .remove("connection_id");
    legacy["chats"][0]
        .as_object_mut()
        .unwrap()
        .remove("materialization");
    let before = serde_json::to_vec(&legacy).unwrap();
    std::fs::write(&path, &before).unwrap();
    assert!(!String::from_utf8_lossy(&before).contains("pinned_at"));
    assert!(!String::from_utf8_lossy(&before).contains("sidebar_order"));
    let store = WorkspaceStore::open(&path, dir.path()).unwrap();
    assert_eq!(store.snapshot().version, 1);
    assert_eq!(store.snapshot().chats, vec![chat]);
    assert_eq!(std::fs::read(path).unwrap(), before);
}

#[test]
fn new_organization_format_is_explicit_and_mislabeled_v1_is_preserved() {
    let (dir, path, mut store) = fixture();
    let mut chat = record(dir.path(), 1, "legacy");
    chat.sidebar_order = None;
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    assert_eq!(store.snapshot().version, 11);
    store
        .set_pinned(chat.clone(), DraftRecord::default(), true, 4)
        .unwrap();
    assert_eq!(store.snapshot().version, 11);
    store
        .set_pinned(chat.clone(), DraftRecord::default(), false, 5)
        .unwrap();
    assert_eq!(store.snapshot().version, 11); // Never downgrade after metadata use.
    store
        .set_pinned(chat, DraftRecord::default(), true, 6)
        .unwrap();
    drop(store);
    let mut value: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    value["version"] = 1.into();
    // Keep this case focused on mislabeled organization metadata; v5 mode
    // fields in legacy catalogs have their own rejection fixtures.
    value["chats"][0]
        .as_object_mut()
        .unwrap()
        .remove("tool_mode");
    value["chats"][0]
        .as_object_mut()
        .unwrap()
        .remove("connection_id");
    value["chats"][0]
        .as_object_mut()
        .unwrap()
        .remove("materialization");
    let malformed = serde_json::to_vec(&value).unwrap();
    std::fs::write(&path, &malformed).unwrap();
    assert!(WorkspaceStore::open(&path, dir.path()).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), malformed);
}
