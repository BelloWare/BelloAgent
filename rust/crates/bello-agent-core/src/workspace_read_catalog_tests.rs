use super::*;
use crate::read_observation::OutputSummary;
use crate::workspace_read_state::{ReadEvent, reduce_read_state};
fn fixture() -> (tempfile::TempDir, WorkspaceStore, ChatRecord) {
    let dir = tempfile::tempdir().unwrap();
    let store = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
    let id = Uuid::new_v4().to_string();
    let mut chat = ChatRecord::new(
        id.clone(),
        "Read state".into(),
        store.chat_path(&id).unwrap(),
    );
    chat.sidebar_order = None;
    (dir, store, chat)
}
fn baseline() -> ChatReadState {
    reduce_read_state(None, ReadEvent::Baseline(&OutputSummary::default()))
        .unwrap()
        .unwrap()
}
fn save(
    store: &mut WorkspaceStore,
    chat: &ChatRecord,
    expected: Option<u64>,
    next: &ChatReadState,
) -> Result<ReadStateChange> {
    let project = store.state.project.clone();
    let project_id = store.state.project_id.clone();
    store.save_read_state(
        &project,
        project_id.as_deref(),
        &chat.id,
        &chat.snapshot,
        expected,
        next,
    )
}
fn legacy(state: &WorkspaceSnapshot, version: u32) -> serde_json::Value {
    let mut value = serde_json::to_value(state).unwrap();
    value["version"] = version.into();
    value.as_object_mut().unwrap().remove("read_states");
    for chat in value["chats"].as_array_mut().unwrap() {
        let fields = chat.as_object_mut().unwrap();
        if version < 11 {
            fields.remove("last_activity_at");
        }
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
fn all_old_versions_remain_byte_identical_until_first_real_read_mutation() {
    for version in 1..12 {
        let (dir, mut store, chat) = fixture();
        store
            .register(chat.clone(), DraftRecord::default())
            .unwrap();
        let value = legacy(&store.state, version);
        let path = store.path.clone();
        drop(store);
        let original =
            format!(" \n{}\n", serde_json::to_string_pretty(&value).unwrap()).into_bytes();
        fs::write(&path, &original).unwrap();
        let mut store = WorkspaceStore::open(&path, dir.path()).unwrap();
        // Read-only initial baseline and absent-state no-op never transact.
        let read = baseline();
        assert!(
            reduce_read_state(None, ReadEvent::MarkRead)
                .unwrap()
                .is_none()
        );
        assert_eq!(fs::read(&path).unwrap(), original);
        assert_eq!(store.snapshot().version, version);
        let before = store.snapshot();
        let receipt = save(&mut store, &chat, None, &read).unwrap();
        assert!(receipt.changed);
        assert_eq!(receipt.state, read);
        assert_eq!(store.state.version, 12);
        assert_eq!(store.state.revision, before.revision + 1);
        let persisted = fs::read(&path).unwrap();
        let no_op = save(&mut store, &chat, Some(read.revision), &read).unwrap();
        assert!(!no_op.changed);
        assert_eq!(fs::read(&path).unwrap(), persisted);
        assert_eq!(store.state.revision, before.revision + 1);
    }
}
#[test]
fn old_version_read_field_presence_rejects_null_empty_and_every_value() {
    let (_dir, mut store, chat) = fixture();
    store.register(chat, DraftRecord::default()).unwrap();
    for version in 1..12 {
        for field in [
            serde_json::json!(null),
            serde_json::json!({}),
            serde_json::json!([]),
            serde_json::json!(false),
        ] {
            let mut value = legacy(&store.state, version);
            value["read_states"] = field;
            assert!(serde_json::from_value::<WorkspaceSnapshot>(value).is_err());
        }
    }
    let mut value = serde_json::to_value(&store.state).unwrap();
    value["version"] = 13.into();
    assert!(serde_json::from_value::<WorkspaceSnapshot>(value).is_err());
}
#[test]
fn read_metadata_rejects_unknown_chats_ids_bad_counts_revisions_and_shapes() {
    let (_dir, mut store, chat) = fixture();
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    save(&mut store, &chat, None, &baseline()).unwrap();
    let valid = serde_json::to_value(&store.state).unwrap();
    let mut value = valid.clone();
    value["read_states"] = serde_json::Value::Null;
    assert!(serde_json::from_value::<WorkspaceSnapshot>(value).is_err());
    for (field, value) in [
        ("revision", serde_json::json!(0)),
        ("revision", serde_json::json!(-1)),
        ("observed_count", serde_json::json!(100001)),
        ("unread_count", serde_json::json!(100001)),
        ("observed_count", serde_json::json!(1.5)),
        ("latest_id", serde_json::json!("")),
        ("latest_id", serde_json::json!("wrong-zero-count")),
        ("unread_target_id", serde_json::json!("without-obligation")),
        ("consumed_generation", serde_json::json!("not-uuid")),
        ("consumed_failure_sequence", serde_json::json!(1)),
        ("source_revision", serde_json::json!(1)),
        ("unexpected", serde_json::json!(true)),
    ] {
        let mut changed = valid.clone();
        changed["read_states"][&chat.id][field] = value;
        assert!(
            serde_json::from_value::<WorkspaceSnapshot>(changed).is_err(),
            "field {field}"
        );
    }
    for id in ["invalid".to_owned(), Uuid::new_v4().to_string()] {
        let mut changed = valid.clone();
        let entry = changed["read_states"]
            .as_object_mut()
            .unwrap()
            .remove(&chat.id)
            .unwrap();
        changed["read_states"][id] = entry;
        assert!(serde_json::from_value::<WorkspaceSnapshot>(changed).is_err());
    }
}
#[test]
fn exact_workspace_chat_path_and_revision_are_required_without_materializing() {
    let (_dir, mut store, mut chat) = fixture();
    let next = baseline();
    assert!(save(&mut store, &chat, None, &next).is_err());
    assert!(store.state.chats.is_empty());
    assert!(!chat.snapshot.exists());
    chat.materialization = ChatMaterialization::Pending;
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    let project = store.state.project.clone();
    assert!(
        store
            .save_read_state(
                Path::new("/wrong-project"),
                None,
                &chat.id,
                &chat.snapshot,
                None,
                &next
            )
            .is_err()
    );
    assert!(
        store
            .save_read_state(
                &project,
                Some(&Uuid::new_v4().to_string()),
                &chat.id,
                &chat.snapshot,
                None,
                &next
            )
            .is_err()
    );
    assert!(
        store
            .save_read_state(
                &project,
                None,
                &chat.id,
                Path::new("/wrong-chat"),
                None,
                &next
            )
            .is_err()
    );
    assert!(save(&mut store, &chat, Some(0), &next).is_err());
    save(&mut store, &chat, None, &next).unwrap();
    assert!(!chat.snapshot.exists());
    assert_eq!(
        store.state.chats[0].materialization,
        ChatMaterialization::Pending
    );
    let bytes = fs::read(&store.path).unwrap();
    assert!(save(&mut store, &chat, None, &next).is_err());
    let mut conflict = next.clone();
    conflict.manual_unread = true;
    assert!(save(&mut store, &chat, Some(next.revision), &conflict).is_err());
    assert_eq!(fs::read(&store.path).unwrap(), bytes);
    conflict.revision += 7; // optimistic mutations may coalesce
    save(&mut store, &chat, Some(next.revision), &conflict).unwrap();
    assert!(save(&mut store, &chat, Some(next.revision), &next).is_err());
    assert_eq!(store.state.read_states[&chat.id], conflict);
}
#[test]
fn baseline_and_full_unread_obligation_commit_together_and_reopen_intact() {
    let (dir, mut store, chat) = fixture();
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    let baseline = baseline();
    save(&mut store, &chat, None, &baseline).unwrap();
    let next = reduce_read_state(
        Some(&baseline),
        ReadEvent::Inspect(&OutputSummary {
            count: 2,
            latest_id: Some("newest".into()),
        }),
    )
    .unwrap()
    .unwrap();
    save(&mut store, &chat, Some(baseline.revision), &next).unwrap();
    let path = store.path.clone();
    drop(store);
    let reopened = WorkspaceStore::open(path, dir.path()).unwrap();
    assert_eq!(reopened.state.read_states[&chat.id], next);
    assert_eq!(next.observed_count, 2);
    assert_eq!(next.unread_count, 2);
}
#[test]
fn before_and_after_rename_failures_preserve_memory_and_uncertainty_fences_noops() {
    for fault in [Fault::BeforeRename, Fault::AfterRename] {
        let (dir, mut store, chat) = fixture();
        store
            .register(chat.clone(), DraftRecord::default())
            .unwrap();
        let first = baseline();
        save(&mut store, &chat, None, &first).unwrap();
        let before = store.state.clone();
        let bytes = fs::read(&store.path).unwrap();
        let next = reduce_read_state(Some(&first), ReadEvent::MarkUnread)
            .unwrap()
            .unwrap();
        store.fault = fault;
        let result = save(&mut store, &chat, Some(first.revision), &next);
        assert!(result.is_err());
        assert_eq!(
            serde_json::to_value(&store.state).unwrap(),
            serde_json::to_value(&before).unwrap()
        );
        if matches!(fault, Fault::BeforeRename) {
            assert_eq!(fs::read(&store.path).unwrap(), bytes);
            store.fault = Fault::None;
            save(&mut store, &chat, Some(first.revision), &next).unwrap();
        } else {
            assert!(matches!(result, Err(Error::PersistenceUncertain(_))));
            assert!(save(&mut store, &chat, Some(first.revision), &first).is_err());
            assert!(store.record_activity(&chat.id, &chat.snapshot, 0).is_err());
            let path = store.path.clone();
            drop(store);
            let reopened = WorkspaceStore::open(path, dir.path()).unwrap();
            assert_eq!(reopened.state.read_states[&chat.id], next);
        }
    }
}
#[test]
fn read_receipts_and_other_writers_preserve_all_unrelated_columns() {
    let (_dir, mut store, mut chat) = fixture();
    chat.connection_id = Some(Uuid::new_v4().to_string());
    chat.tool_mode = ChatToolMode::ReadOnly;
    let draft = DraftRecord {
        revision: 7,
        text: "preserve draft".into(),
        ..Default::default()
    };
    store.register(chat.clone(), draft.clone()).unwrap();
    let topic = store.create_topic("Topic").unwrap();
    store
        .set_pinned(chat.clone(), DraftRecord::default(), true, 5)
        .unwrap();
    store
        .set_archived(chat.clone(), DraftRecord::default(), true, 6)
        .unwrap();
    store
        .move_chat_to_topic(chat.clone(), DraftRecord::default(), Some(&topic.id), 0)
        .unwrap();
    store.record_activity(&chat.id, &chat.snapshot, 99).unwrap();
    store.state.queued_cancellations.insert(
        chat.id.clone(),
        QueuedCancelReceipt {
            revision: 2,
            state: QueuedCancelState::Settled,
        },
    );
    store.state.settled_submissions.insert(chat.id.clone(), 1);
    let intent = SubmissionIntent {
        id: Uuid::new_v4().to_string(),
        chat_id: chat.id.clone(),
        text: "retained submission".into(),
        lane: Lane::FollowUp,
        draft_revision: 3,
        skills: Vec::new(),
        attachments: Vec::new(),
    };
    store
        .state
        .intents
        .insert(intent.id.clone(), intent.clone());
    let before = store.state.clone();
    let read = baseline();
    let receipt = save(&mut store, &chat, None, &read).unwrap();
    let mut expected = before;
    expected.revision += 1;
    expected.read_states.insert(chat.id.clone(), read.clone());
    assert_eq!(
        serde_json::to_value(&store.state).unwrap(),
        serde_json::to_value(&expected).unwrap()
    );
    assert_eq!(receipt.state, read);
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    store
        .set_pinned(chat.clone(), DraftRecord::default(), false, 7)
        .unwrap();
    store
        .record_activity(&chat.id, &chat.snapshot, 101)
        .unwrap();
    store.delete_topic(&topic.id, 0).unwrap();
    assert_eq!(store.state.read_states[&chat.id], read);
    assert_eq!(store.state.drafts[&chat.id], draft);
    assert_eq!(store.state.intents[&intent.id], intent);
    assert_eq!(store.state.chats[0].last_activity_at, Some(101));
    assert_eq!(store.state.chats[0].archived_at, Some(6));
    assert_eq!(store.state.chats[0].connection_id, chat.connection_id);
    assert_eq!(
        store.state.queued_cancellations[&chat.id].state,
        QueuedCancelState::Settled
    );
}
#[test]
fn catalog_overflow_is_atomic_and_read_revision_cannot_wrap_or_move_backwards() {
    let (_dir, mut store, chat) = fixture();
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    let read = baseline();
    save(&mut store, &chat, None, &read).unwrap();
    store.state.revision = u64::MAX;
    let bytes = fs::read(&store.path).unwrap();
    let next = reduce_read_state(Some(&read), ReadEvent::MarkUnread)
        .unwrap()
        .unwrap();
    assert!(save(&mut store, &chat, Some(read.revision), &next).is_err());
    assert_eq!(store.state.read_states[&chat.id], read);
    assert_eq!(fs::read(&store.path).unwrap(), bytes);
    assert!(
        !save(&mut store, &chat, Some(read.revision), &read)
            .unwrap()
            .changed
    );
    store.state.revision = 100;
    let mut maximum = next;
    maximum.revision = u64::MAX;
    save(&mut store, &chat, Some(read.revision), &maximum).unwrap();
    assert!(reduce_read_state(Some(&maximum), ReadEvent::MarkRead).is_err());
    assert!(save(&mut store, &chat, Some(u64::MAX), &read).is_err());
}

#[test]
fn catalog_mutex_serializes_read_activity_and_organization_without_stale_row_overwrite() {
    use std::sync::{Arc, Barrier, Mutex};
    let (_dir, mut store, chat) = fixture();
    let draft = DraftRecord {
        revision: 4,
        text: "keep typing".into(),
        ..Default::default()
    };
    store.register(chat.clone(), draft.clone()).unwrap();
    let writer = Arc::new(Mutex::new(store));
    let barrier = Arc::new(Barrier::new(3));
    std::thread::scope(|scope| {
        {
            let writer = writer.clone();
            let barrier = barrier.clone();
            let chat = chat.clone();
            scope.spawn(move || {
                barrier.wait();
                let first = baseline();
                save(&mut writer.lock().unwrap(), &chat, None, &first).unwrap();
                let next = reduce_read_state(
                    Some(&first),
                    ReadEvent::Inspect(&OutputSummary {
                        count: 2,
                        latest_id: Some("newest".into()),
                    }),
                )
                .unwrap()
                .unwrap();
                save(
                    &mut writer.lock().unwrap(),
                    &chat,
                    Some(first.revision),
                    &next,
                )
                .unwrap();
            });
        }
        {
            let writer = writer.clone();
            let barrier = barrier.clone();
            let chat = chat.clone();
            scope.spawn(move || {
                barrier.wait();
                for at in [3, 10, 8] {
                    writer
                        .lock()
                        .unwrap()
                        .record_activity(&chat.id, &chat.snapshot, at)
                        .unwrap();
                }
                writer
                    .lock()
                    .unwrap()
                    .set_pinned(chat.clone(), DraftRecord::default(), true, 4)
                    .unwrap();
                writer
                    .lock()
                    .unwrap()
                    .set_archived(chat.clone(), DraftRecord::default(), true, 5)
                    .unwrap();
                writer
                    .lock()
                    .unwrap()
                    .register(chat, DraftRecord::default())
                    .unwrap();
            });
        }
        barrier.wait();
    });
    let store = writer.lock().unwrap();
    assert_eq!(store.state.read_states[&chat.id].unread_count, 2);
    assert_eq!(
        store.state.read_states[&chat.id]
            .unread_target_id
            .as_deref(),
        Some("newest")
    );
    assert_eq!(store.state.chats[0].last_activity_at, Some(10));
    assert_eq!(store.state.chats[0].pinned_at, Some(4));
    assert_eq!(store.state.chats[0].archived_at, Some(5));
    assert_eq!(store.state.drafts[&chat.id], draft);
}
