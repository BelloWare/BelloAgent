use super::*;
use std::cmp::Ordering;

fn fixture() -> (tempfile::TempDir, WorkspaceStore, ChatRecord) {
    let dir = tempfile::tempdir().unwrap();
    let store = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
    let id = Uuid::new_v4().to_string();
    let mut chat = ChatRecord::new(id.clone(), "Activity".into(), store.chat_path(&id).unwrap());
    chat.sidebar_order = None;
    (dir, store, chat)
}
fn bytes(store: &WorkspaceStore) -> Vec<u8> {
    fs::read(&store.path).unwrap()
}
fn legacy(state: &WorkspaceSnapshot, version: u32) -> serde_json::Value {
    let mut value = serde_json::to_value(state).unwrap();
    value["version"] = version.into();
    for chat in value["chats"].as_array_mut().unwrap() {
        let fields = chat.as_object_mut().unwrap();
        fields.remove("last_activity_at");
        if version < 7 {
            fields.remove("materialization");
        }
        if version < 6 {
            fields.remove("connection_id");
        }
        if version < 5 {
            fields.remove("tool_mode");
        }
    }
    value
}

#[test]
fn activity_order_uses_pin_boolean_recency_creation_fallback_and_id_ties() {
    let (_dir, _store, mut a) = fixture();
    let mut b = a.clone();
    a.id = "a".into();
    b.id = "b".into();
    a.sidebar_order = Some(10);
    b.sidebar_order = Some(20);
    assert_eq!(a.sidebar_cmp(&b), Ordering::Greater);
    a.last_activity_at = Some(30);
    assert_eq!(a.sidebar_cmp(&b), Ordering::Less);
    b.last_activity_at = Some(1);
    assert_eq!(b.activity_stamp(), 20);
    b.pinned_at = Some(999);
    assert_eq!(a.sidebar_cmp(&b), Ordering::Greater);
    a.pinned_at = Some(u64::MAX);
    assert_eq!(a.sidebar_cmp(&b), Ordering::Less);
    a.pinned_at = Some(0);
    b.pinned_at = Some(0);
    assert_eq!(a.sidebar_cmp(&b), Ordering::Less);
    b.last_activity_at = Some(30);
    assert_eq!(a.sidebar_cmp(&b), Ordering::Less);
    assert_eq!(
        a.sidebar_cmp_with_activity(&b, Some(1), Some(2)),
        Ordering::Greater
    );
    a.pinned_at = None;
    assert_eq!(
        a.sidebar_cmp_with_activity(&b, Some(100), Some(2)),
        Ordering::Greater
    );
}

#[test]
fn activity_all_old_versions_read_sort_and_noop_without_rewrite_then_promote() {
    for version in 1..CURRENT_VERSION {
        let (dir, mut store, chat) = fixture();
        store
            .register(chat.clone(), DraftRecord::default())
            .unwrap();
        let value = legacy(&store.snapshot(), version);
        let path = store.path.clone();
        drop(store);
        let original =
            format!(" \n{}\n", serde_json::to_string_pretty(&value).unwrap()).into_bytes();
        fs::write(&path, &original).unwrap();
        let mut store = WorkspaceStore::open(&path, dir.path()).unwrap();
        let mut rows = store.snapshot().chats;
        rows.sort_by(ChatRecord::sidebar_cmp);
        assert_eq!(rows[0].last_activity_at, None);
        assert!(
            !store
                .record_activity(&chat.id, &chat.snapshot, 0)
                .unwrap()
                .changed
        );
        assert_eq!(store.snapshot().version, version);
        assert_eq!(bytes(&store), original);
        assert!(
            store
                .record_activity(&chat.id, &chat.snapshot, 7)
                .unwrap()
                .changed
        );
        assert_eq!(store.snapshot().version, CURRENT_VERSION);
        assert_eq!(store.snapshot().chats[0].last_activity_at, Some(7));
    }
}

#[test]
fn activity_version_gate_rejects_presence_including_null_and_malformed_values() {
    let (_dir, mut store, chat) = fixture();
    store.register(chat, DraftRecord::default()).unwrap();
    for version in 1..CURRENT_VERSION {
        for activity in [
            serde_json::json!(null),
            serde_json::json!(0),
            serde_json::json!(1),
        ] {
            let mut value = legacy(&store.snapshot(), version);
            value["chats"][0]["last_activity_at"] = activity;
            assert!(serde_json::from_value::<WorkspaceSnapshot>(value).is_err());
        }
    }
    for invalid in [
        serde_json::json!(-1),
        serde_json::json!(1.5),
        serde_json::json!("3"),
        serde_json::json!(true),
        serde_json::json!({}),
        serde_json::from_str("18446744073709551616").unwrap(),
    ] {
        let mut value = serde_json::to_value(store.snapshot()).unwrap();
        value["chats"][0]["last_activity_at"] = invalid;
        assert!(serde_json::from_value::<WorkspaceSnapshot>(value).is_err());
    }
    let mut value = serde_json::to_value(store.snapshot()).unwrap();
    value["version"] = (CURRENT_VERSION + 1).into();
    assert!(serde_json::from_value::<WorkspaceSnapshot>(value).is_err());
}

#[test]
fn activity_max_semantics_do_not_create_rows_or_manufacture_clock_ticks() {
    let (_dir, mut store, chat) = fixture();
    assert!(
        store
            .record_activity(&chat.id, &chat.snapshot, 100)
            .is_err()
    );
    assert!(store.snapshot().chats.is_empty());
    assert!(!store.path.exists());
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    let before = bytes(&store);
    assert!(
        store
            .record_activity(&chat.id, Path::new("wrong"), 0)
            .is_err()
    );
    assert_eq!(bytes(&store), before);
    let receipt = store
        .record_activity(&chat.id, &chat.snapshot, 100)
        .unwrap();
    assert_eq!(receipt.last_activity_at, Some(100));
    let unchanged = bytes(&store);
    for at in [100, 99, 0] {
        let receipt = store.record_activity(&chat.id, &chat.snapshot, at).unwrap();
        assert!(!receipt.changed);
        assert_eq!(receipt.last_activity_at, Some(100));
        assert_eq!(bytes(&store), unchanged);
    }
    store
        .record_activity(&chat.id, &chat.snapshot, u64::MAX)
        .unwrap();
    assert!(
        !store
            .record_activity(&chat.id, &chat.snapshot, u64::MAX)
            .unwrap()
            .changed
    );
}

#[test]
fn activity_faults_preserve_memory_and_uncertain_commit_fences_even_noops() {
    for fault in [Fault::BeforeRename, Fault::AfterRename] {
        let (dir, mut store, chat) = fixture();
        store
            .register(chat.clone(), DraftRecord::default())
            .unwrap();
        let original = bytes(&store);
        let state = store.snapshot();
        store.fault = fault;
        let result = store.record_activity(&chat.id, &chat.snapshot, 8);
        assert!(result.is_err());
        assert_eq!(
            serde_json::to_value(store.snapshot()).unwrap(),
            serde_json::to_value(state).unwrap()
        );
        if matches!(fault, Fault::BeforeRename) {
            assert_eq!(bytes(&store), original);
            store.fault = Fault::None;
            assert!(
                store
                    .record_activity(&chat.id, &chat.snapshot, 8)
                    .unwrap()
                    .changed
            );
        } else {
            assert!(matches!(result, Err(Error::PersistenceUncertain(_))));
            assert!(store.record_activity(&chat.id, &chat.snapshot, 0).is_err());
            assert!(
                store
                    .set_pinned(chat.clone(), DraftRecord::default(), false, 0)
                    .is_err()
            );
            assert!(store.create_topic("blocked").is_err());
            let path = store.path.clone();
            drop(store);
            let reopened = WorkspaceStore::open(path, dir.path()).unwrap();
            assert_eq!(reopened.snapshot().chats[0].last_activity_at, Some(8));
        }
    }
}

#[test]
fn activity_and_stale_organization_topic_operations_preserve_each_others_columns() {
    let (_dir, mut store, mut stale) = fixture();
    stale.tool_mode = ChatToolMode::ReadOnly;
    let draft = DraftRecord {
        text: "retain typing".into(),
        revision: 4,
        ..Default::default()
    };
    store.register(stale.clone(), draft.clone()).unwrap();
    let topic = store.create_topic("Work").unwrap();
    store
        .record_activity(&stale.id, &stale.snapshot, 50)
        .unwrap();
    store
        .set_pinned(stale.clone(), DraftRecord::default(), true, 2)
        .unwrap();
    store
        .set_archived(stale.clone(), DraftRecord::default(), true, 3)
        .unwrap();
    store
        .move_chat_to_topic(stale.clone(), DraftRecord::default(), Some(&topic.id), 0)
        .unwrap();
    store.name_chat(&stale.id, "latest title").unwrap();
    let before = store.snapshot();
    store
        .record_activity(&stale.id, &stale.snapshot, 60)
        .unwrap();
    let after = store.snapshot();
    let mut expected = before;
    expected.revision += 1;
    expected.chats[0].last_activity_at = Some(60);
    assert_eq!(
        serde_json::to_value(after).unwrap(),
        serde_json::to_value(expected).unwrap()
    );
    store.delete_topic(&topic.id, 0).unwrap();
    store
        .record_activity(&stale.id, &stale.snapshot, 55)
        .unwrap();
    store
        .register(stale.clone(), DraftRecord::default())
        .unwrap();
    let after = store.snapshot();
    assert_eq!(after.chats[0].last_activity_at, Some(60));
    assert_eq!(after.chats[0].topic_id, None);
    assert_eq!(after.chats[0].topic_revision, 2);
    assert_eq!(after.chats[0].pinned_at, Some(2));
    assert_eq!(after.chats[0].archived_at, Some(3));
    assert_eq!(after.chats[0].tool_mode, ChatToolMode::ReadOnly);
    assert_eq!(after.drafts[&stale.id], draft);
}

#[test]
fn activity_mutex_serialization_keeps_concurrent_topic_and_organization_changes() {
    use std::sync::{Arc, Barrier, Mutex};
    let (_dir, mut store, mut chat) = fixture();
    chat.connection_id = Some(Uuid::new_v4().to_string());
    chat.materialization = ChatMaterialization::Pending;
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    let topic = store.create_topic("Concurrent").unwrap();
    let writer = Arc::new(Mutex::new(store));
    let barrier = Arc::new(Barrier::new(3));
    std::thread::scope(|scope| {
        {
            let writer = writer.clone();
            let barrier = barrier.clone();
            let chat = chat.clone();
            scope.spawn(move || {
                barrier.wait();
                for at in [9, 3, 15, 14] {
                    writer
                        .lock()
                        .unwrap()
                        .record_activity(&chat.id, &chat.snapshot, at)
                        .unwrap();
                }
            });
        }
        {
            let writer = writer.clone();
            let barrier = barrier.clone();
            let chat = chat.clone();
            scope.spawn(move || {
                barrier.wait();
                let mut store = writer.lock().unwrap();
                store
                    .set_pinned(chat.clone(), DraftRecord::default(), true, 2)
                    .unwrap();
                store
                    .set_archived(chat.clone(), DraftRecord::default(), true, 3)
                    .unwrap();
                store
                    .move_chat_to_topic(chat, DraftRecord::default(), Some(&topic.id), 0)
                    .unwrap();
                store.delete_topic(&topic.id, 0).unwrap();
            });
        }
        barrier.wait();
    });
    let store = writer.lock().unwrap();
    let row = &store.state.chats[0];
    assert_eq!(row.last_activity_at, Some(15));
    assert_eq!(row.pinned_at, Some(2));
    assert_eq!(row.archived_at, Some(3));
    assert_eq!(row.topic_id, None);
    assert_eq!(row.topic_revision, 2);
    assert_eq!(row.connection_id, chat.connection_id);
    assert_eq!(row.materialization, ChatMaterialization::Pending);
    assert!(!chat.snapshot.exists());
}

#[test]
fn activity_registration_preserves_captured_event_then_accepts_only_newer_activity() {
    let (dir, mut store, mut chat) = fixture();
    chat.materialization = ChatMaterialization::Pending;
    chat.last_activity_at = Some(42);
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    store.record_activity(&chat.id, &chat.snapshot, 60).unwrap();
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    let path = store.path.clone();
    drop(store);
    let mut reopened = WorkspaceStore::open(path, dir.path()).unwrap();
    assert_eq!(reopened.state.chats[0].last_activity_at, Some(60));
    assert!(
        !reopened
            .record_activity(&chat.id, &chat.snapshot, 42)
            .unwrap()
            .changed
    );
    assert!(!chat.snapshot.exists());
}
