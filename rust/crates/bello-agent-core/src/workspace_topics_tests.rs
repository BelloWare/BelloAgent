use super::*;

fn fixture() -> (tempfile::TempDir, WorkspaceStore, ChatRecord) {
    let dir = tempfile::tempdir().unwrap();
    let store = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
    let id = Uuid::new_v4().to_string();
    let mut chat = ChatRecord::new(id.clone(), "Unsent".into(), store.chat_path(&id).unwrap());
    chat.materialization = ChatMaterialization::Pending;
    (dir, store, chat)
}
fn draft(text: &str, revision: u64) -> DraftRecord {
    DraftRecord {
        text: text.into(),
        revision,
        ..Default::default()
    }
}
fn bytes(store: &WorkspaceStore) -> Vec<u8> {
    fs::read(&store.path).unwrap()
}

#[test]
fn topics_normalize_foundation_whitespace_and_extended_graphemes() {
    assert!(TopicRecord::normalized_title(" \t\n\u{200b}\u{85}").is_err());
    assert_eq!(
        TopicRecord::normalized_title(" A\u{200b}\u{a0} B\r\nC ").unwrap(),
        "A B C"
    );
    let cluster = "👩🏽‍💻";
    assert_eq!(
        TopicRecord::normalized_title(&cluster.repeat(121)).unwrap(),
        cluster.repeat(120)
    );
    assert_eq!(
        TopicRecord::normalized_title(&"e\u{301}".repeat(121)).unwrap(),
        "e\u{301}".repeat(120)
    );
    assert_eq!(
        TopicRecord::normalized_title("\u{feff}").unwrap(),
        "\u{feff}"
    );
}
#[test]
fn topics_create_rename_expand_reopen_and_stale_callbacks() {
    let (dir, mut store, _) = fixture();
    assert_eq!(store.snapshot().project_id, None);
    let first = store.create_topic("  Work\n topics ").unwrap();
    let other = store.create_topic("Work topics").unwrap();
    assert_ne!(first.id, other.id); // Duplicate titles are valid.
    assert_eq!(first.title, "Work topics");
    assert!(first.expanded);
    assert_eq!(first.revision, 0);
    assert_eq!(store.snapshot().version, CURRENT_VERSION);
    let unchanged = bytes(&store);
    assert_eq!(
        store.rename_topic(&first.id, "Work topics", 0).unwrap(),
        first
    );
    assert_eq!(store.set_topic_expanded(&first.id, true, 0).unwrap(), first);
    assert_eq!(bytes(&store), unchanged);
    let renamed = store.rename_topic(&first.id, "Renamed", 0).unwrap();
    assert_eq!(renamed.revision, 1);
    assert!(store.rename_topic(&first.id, "stale", 0).is_err());
    assert!(store.delete_topic(&first.id, 0).is_err());
    assert!(store.set_topic_expanded(&first.id, false, 0).is_err());
    let collapsed = store.set_topic_expanded(&first.id, false, 1).unwrap();
    assert_eq!(collapsed.revision, 2);
    let path = store.path.clone();
    drop(store);
    let reopened = WorkspaceStore::open(path, dir.path()).unwrap();
    assert_eq!(reopened.snapshot().topics, [collapsed, other]);
}
#[test]
fn topics_pending_move_is_atomic_and_never_creates_session_files() {
    let (_dir, mut store, chat) = fixture();
    let topic = store.create_topic("Planning").unwrap();
    let before = bytes(&store);
    store.fault = Fault::BeforeRename;
    assert!(
        store
            .move_chat_to_topic(chat.clone(), draft("keep me", 3), Some(&topic.id), 0)
            .is_err()
    );
    assert_eq!(bytes(&store), before);
    assert!(store.snapshot().chats.is_empty());
    assert!(!chat.snapshot.exists());
    assert!(!chat.snapshot.parent().unwrap().exists());
    store.fault = Fault::None;
    let moved = store
        .move_chat_to_topic(chat.clone(), draft("keep me", 3), Some(&topic.id), 0)
        .unwrap();
    assert_eq!(moved.topic_id.as_deref(), Some(topic.id.as_str()));
    assert_eq!(moved.topic_revision, 1);
    assert_eq!(moved.materialization, ChatMaterialization::Pending);
    let state = store.snapshot();
    assert_eq!(state.drafts[&chat.id], draft("keep me", 3));
    assert_eq!(state.selected, None);
    assert!(state.intents.is_empty());
    assert!(!chat.snapshot.parent().unwrap().exists());
}
#[test]
fn topics_moves_and_deletion_preserve_latest_metadata_draft_and_journal() {
    let (_dir, mut store, stale) = fixture();
    let first = store.create_topic("First").unwrap();
    let second = store.create_topic("Second").unwrap();
    store.register(stale.clone(), draft("initial", 1)).unwrap();
    store.name_chat(&stale.id, "latest title").unwrap();
    store
        .save_draft(&stale.id, draft("latest typing", 4))
        .unwrap();
    store
        .set_pinned(stale.clone(), DraftRecord::default(), true, 8)
        .unwrap();
    store
        .set_archived(stale.clone(), DraftRecord::default(), true, 9)
        .unwrap();
    // Stand-ins are never opened by topic operations, even for archived chats.
    fs::create_dir_all(stale.snapshot.parent().unwrap()).unwrap();
    fs::write(&stale.snapshot, b"checkpoint sentinel").unwrap();
    let journal = stale.snapshot.with_extension("journal");
    fs::write(&journal, b"journal sentinel").unwrap();
    let moved = store
        .move_chat_to_topic(stale.clone(), draft("stale", 0), Some(&first.id), 0)
        .unwrap();
    assert_eq!(moved.title, "latest title");
    assert_eq!(moved.pinned_at, Some(8));
    assert_eq!(moved.archived_at, Some(9));
    assert_eq!(
        store.snapshot().drafts[&stale.id],
        draft("latest typing", 4)
    );
    assert!(
        store
            .move_chat_to_topic(stale.clone(), DraftRecord::default(), Some(&second.id), 0)
            .is_err()
    );
    let snapshot = store.delete_topic(&first.id, 0).unwrap();
    assert_eq!(snapshot.chats[0].topic_id, None);
    assert_eq!(snapshot.chats[0].topic_revision, 2);
    assert!(
        store
            .move_chat_to_topic(moved.clone(), DraftRecord::default(), Some(&second.id), 1)
            .is_err()
    );
    assert!(
        store
            .move_chat_to_topic(moved, DraftRecord::default(), Some(&first.id), 2)
            .is_err()
    );
    assert_eq!(snapshot.drafts[&stale.id], draft("latest typing", 4));
    assert_eq!(fs::read(&stale.snapshot).unwrap(), b"checkpoint sentinel");
    assert_eq!(fs::read(journal).unwrap(), b"journal sentinel");
}
#[test]
fn topics_before_rename_failures_and_after_rename_uncertainty_fence_all_writes() {
    for fault in [Fault::BeforeRename, Fault::AfterRename] {
        let (_dir, mut store, chat) = fixture();
        let topic = store.create_topic("Original").unwrap();
        let moved = store
            .move_chat_to_topic(chat, draft("draft", 1), Some(&topic.id), 0)
            .unwrap();
        let before = bytes(&store);
        store.fault = fault;
        assert!(store.delete_topic(&topic.id, 0).is_err());
        assert_eq!(
            store.snapshot().topics.as_slice(),
            std::slice::from_ref(&topic)
        );
        assert_eq!(
            store.snapshot().chats.as_slice(),
            std::slice::from_ref(&moved)
        );
        if matches!(fault, Fault::BeforeRename) {
            assert_eq!(bytes(&store), before);
            assert!(!store.is_uncertain());
            store.fault = Fault::None;
            store.delete_topic(&topic.id, 0).unwrap();
        } else {
            assert_ne!(bytes(&store), before);
            assert!(store.is_uncertain());
            store.fault = Fault::None;
            assert!(store.create_topic("New").is_err());
            assert!(store.rename_topic(&topic.id, "Original", 0).is_err());
            assert!(store.set_topic_expanded(&topic.id, true, 0).is_err());
            assert!(store.delete_topic(&topic.id, 0).is_err());
            assert!(
                store
                    .move_chat_to_topic(moved, DraftRecord::default(), Some(&topic.id), 1)
                    .is_err()
            );
        }
    }
}
#[test]
fn topics_schema_presence_gates_all_old_versions_and_reads_preserve_bytes() {
    let (dir, mut store, chat) = fixture();
    store.register(chat, draft("kept", 1)).unwrap();
    let path = store.path.clone();
    let base = serde_json::to_value(store.snapshot()).unwrap();
    drop(store);
    for version in 1..=9 {
        let mut old = base.clone();
        old["version"] = version.into();
        let row = old["chats"][0].as_object_mut().unwrap();
        if version < 7 {
            row.remove("materialization");
        }
        if version < 6 {
            row.remove("connection_id");
        }
        if version < 5 {
            row.remove("tool_mode");
        }
        if version < 2 {
            row.remove("sidebar_order");
        }
        let original = format!(" \n{}\n", serde_json::to_string_pretty(&old).unwrap()).into_bytes();
        fs::write(&path, &original).unwrap();
        let reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
        assert_eq!(reopened.snapshot().version, version);
        assert!(reopened.snapshot().topics.is_empty());
        assert_eq!(reopened.snapshot().chats[0].topic_revision, 0);
        assert_eq!(bytes(&reopened), original);
        drop(reopened);
        for (field, value, row_field) in [
            ("topics", serde_json::json!([]), false),
            ("topics", serde_json::Value::Null, false),
            ("topic_id", serde_json::Value::Null, true),
            ("topic_revision", serde_json::json!(0), true),
        ] {
            let mut invalid = old.clone();
            if row_field {
                invalid["chats"][0][field] = value;
            } else {
                invalid[field] = value;
            }
            let invalid_bytes = serde_json::to_vec(&invalid).unwrap();
            fs::write(&path, &invalid_bytes).unwrap();
            assert!(
                WorkspaceStore::open(&path, dir.path()).is_err(),
                "v{version} accepts {field}"
            );
            assert_eq!(fs::read(&path).unwrap(), invalid_bytes);
        }
    }
}
#[test]
fn topics_missing_or_other_catalog_memberships_fall_back_without_hiding_chats() {
    let (_dir, mut store, mut chat) = fixture();
    let (_other_dir, mut other, _) = fixture();
    let foreign = other.create_topic("Other project").unwrap();
    chat.topic_id = Some(foreign.id.clone());
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    assert_eq!(store.snapshot().effective_topic_id(&chat), None);
    assert_eq!(store.snapshot().chats.len(), 1);
    assert!(
        store
            .move_chat_to_topic(chat.clone(), DraftRecord::default(), Some(&foreign.id), 0)
            .is_err()
    );
    let moved = store
        .move_chat_to_topic(chat, DraftRecord::default(), None, 0)
        .unwrap();
    assert_eq!(moved.topic_id, None);
    assert_eq!(moved.topic_revision, 1);
}
#[test]
fn topics_reject_invalid_records_future_versions_and_revision_overflow_atomically() {
    let (_dir, mut store, chat) = fixture();
    let topic = store.create_topic("Valid").unwrap();
    let moved = store
        .move_chat_to_topic(chat, DraftRecord::default(), Some(&topic.id), 0)
        .unwrap();
    store.state.chats[0].topic_revision = u64::MAX;
    let before = bytes(&store);
    assert!(store.delete_topic(&topic.id, 0).is_err());
    assert_eq!(bytes(&store), before);
    assert_eq!(store.snapshot().topics.len(), 1);
    assert_eq!(store.snapshot().chats[0].topic_id, moved.topic_id);
    store.state.topics[0].revision = u64::MAX;
    assert!(store.rename_topic(&topic.id, "overflow", u64::MAX).is_err());
    assert_eq!(bytes(&store), before);
    for invalid in [
        serde_json::json!({"id": topic.id, "title":" Bad ","created_at":0,"expanded":true,"revision":0}),
        serde_json::json!({"id": topic.id, "title":"Valid","created_at":0,"expanded":true,"revision":-1}),
        serde_json::json!({"id": topic.id, "title":"Valid","created_at":0,"expanded":true,"revision":0,"project_id":"foreign"}),
    ] {
        let mut value = serde_json::to_value(store.snapshot()).unwrap();
        value["topics"] = serde_json::json!([invalid]);
        let parsed = serde_json::from_value::<WorkspaceSnapshot>(value);
        assert!(parsed.is_err() || parsed.unwrap().validate().is_err());
    }
    let mut value = serde_json::to_value(store.snapshot()).unwrap();
    value["version"] = (CURRENT_VERSION + 1).into();
    assert!(serde_json::from_value::<WorkspaceSnapshot>(value).is_err());
}

#[test]
fn topics_noop_move_does_not_promote_old_catalog_but_real_move_does() {
    let (dir, mut store, chat) = fixture();
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    let path = store.path.clone();
    let mut old = serde_json::to_value(store.snapshot()).unwrap();
    old["version"] = 9.into();
    drop(store);
    let original = format!(" \n{}\n", serde_json::to_string_pretty(&old).unwrap()).into_bytes();
    fs::write(&path, &original).unwrap();
    let mut reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
    reopened
        .move_chat_to_topic(chat, DraftRecord::default(), None, 0)
        .unwrap();
    assert_eq!(reopened.snapshot().version, 9);
    assert_eq!(bytes(&reopened), original);
    reopened.create_topic("First topic").unwrap();
    assert_eq!(reopened.snapshot().version, CURRENT_VERSION);
}
#[test]
fn topics_all_mutations_are_transactional_at_both_failure_boundaries() {
    for operation in 0..4 {
        for fault in [Fault::BeforeRename, Fault::AfterRename] {
            let (_dir, mut store, chat) = fixture();
            let topic = store.create_topic("Original").unwrap();
            let before = bytes(&store);
            let original = serde_json::to_value(store.snapshot()).unwrap();
            store.fault = fault;
            let result = match operation {
                0 => store.create_topic("New").map(|_| ()),
                1 => store.rename_topic(&topic.id, "Changed", 0).map(|_| ()),
                2 => store.set_topic_expanded(&topic.id, false, 0).map(|_| ()),
                _ => store
                    .move_chat_to_topic(chat.clone(), draft("retained", 1), Some(&topic.id), 0)
                    .map(|_| ()),
            };
            assert!(result.is_err());
            assert_eq!(serde_json::to_value(store.snapshot()).unwrap(), original);
            assert!(!chat.snapshot.exists());
            if matches!(fault, Fault::BeforeRename) {
                assert_eq!(bytes(&store), before);
                assert!(!store.is_uncertain());
            } else {
                assert_ne!(bytes(&store), before);
                assert!(store.is_uncertain());
                assert!(store.create_topic("Refused").is_err());
            }
        }
    }
}

#[test]
fn topics_explicit_move_expands_destination_atomically_including_same_membership() {
    let (_dir, mut store, chat) = fixture();
    let topic = store.create_topic("Closed").unwrap();
    store.set_topic_expanded(&topic.id, false, 0).unwrap();
    let moved = store
        .move_chat_to_topic(chat, draft("kept", 1), Some(&topic.id), 0)
        .unwrap();
    assert!(store.snapshot().topics[0].expanded);
    assert_eq!(store.snapshot().topics[0].revision, 2);
    store.set_topic_expanded(&topic.id, false, 2).unwrap();
    let before = bytes(&store);
    store.fault = Fault::BeforeRename;
    assert!(
        store
            .move_chat_to_topic(moved.clone(), DraftRecord::default(), Some(&topic.id), 1)
            .is_err()
    );
    assert_eq!(bytes(&store), before);
    assert!(!store.snapshot().topics[0].expanded);
    store.fault = Fault::None;
    let same = store
        .move_chat_to_topic(moved.clone(), DraftRecord::default(), Some(&topic.id), 1)
        .unwrap();
    assert_eq!(same, moved);
    assert!(store.snapshot().topics[0].expanded);
    assert_eq!(store.snapshot().topics[0].revision, 4);
    let before = bytes(&store);
    store
        .move_chat_to_topic(same, DraftRecord::default(), Some(&topic.id), 1)
        .unwrap();
    assert_eq!(bytes(&store), before);
}
