use super::*;

fn fixture() -> (tempfile::TempDir, WorkspaceStore, ChatRecord) {
    let dir = tempfile::tempdir().unwrap();
    let mut store = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
    let id = Uuid::new_v4().to_string();
    let chat = ChatRecord::new(
        id.clone(),
        "Saved history".into(),
        store.chat_path(&id).unwrap(),
    );
    store
        .register(
            chat.clone(),
            DraftRecord {
                skills: Vec::new(),
                attachments: Vec::new(),
                revision: 3,
                text: "unsent 日本語".into(),
                queued_edit: None,
            },
        )
        .unwrap();
    (dir, store, chat)
}

#[test]
fn old_catalogs_do_not_invent_connections_or_rewrite_on_read() {
    for version in 1..=5 {
        let (dir, store, _) = fixture();
        let mut value = serde_json::to_value(store.snapshot()).unwrap();
        value["version"] = version.into();
        if version < 5 {
            value.as_object_mut().unwrap().remove("project_id");
        }
        for row in value["chats"].as_array_mut().unwrap() {
            let row = row.as_object_mut().unwrap();
            row.remove("connection_id");
            row.remove("materialization");
            if version < 5 {
                row.remove("tool_mode");
            }
            if version < 2 {
                row.remove("sidebar_order");
            }
        }
        let path = dir.path().join("workspace.json");
        drop(store);
        let bytes = serde_json::to_vec_pretty(&value).unwrap();
        fs::write(&path, &bytes).unwrap();
        let reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
        assert_eq!(reopened.snapshot().version, version);
        assert!(reopened.snapshot().chats[0].connection_id.is_none());
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }
}

#[test]
fn v6_requires_explicit_connection_field_and_valid_saved_identity() {
    let (_, store, _) = fixture();
    let value = serde_json::to_value(store.snapshot()).unwrap();
    for invalid in [
        serde_json::json!(""),
        serde_json::json!("not-a-uuid"),
        serde_json::json!(42),
    ] {
        let mut bad = value.clone();
        bad["chats"][0]["connection_id"] = invalid;
        let parsed = serde_json::from_value::<WorkspaceSnapshot>(bad);
        assert!(parsed.is_err() || parsed.unwrap().validate().is_err());
    }
    let mut absent = value.clone();
    absent["chats"][0]
        .as_object_mut()
        .unwrap()
        .remove("connection_id");
    assert!(serde_json::from_value::<WorkspaceSnapshot>(absent).is_err());
    for version in 1..=5 {
        let mut old = value.clone();
        old["version"] = version.into();
        assert!(serde_json::from_value::<WorkspaceSnapshot>(old).is_err());
    }
}

#[test]
fn connection_switch_patches_identity_only_and_rejects_stale_expected_route() {
    let (dir, mut store, original) = fixture();
    let first = Uuid::new_v4().to_string();
    let second = Uuid::new_v4().to_string();
    let before = store.snapshot();
    let changed = store
        .set_connection_after_retirement(&original.id, None, &first)
        .unwrap();
    assert_eq!(changed.connection_id.as_deref(), Some(first.as_str()));
    let after = store.snapshot();
    assert_eq!(after.drafts, before.drafts);
    assert_eq!(after.intents, before.intents);
    assert_eq!(changed.title, original.title);
    assert_eq!(changed.snapshot, original.snapshot);
    let bytes = fs::read(dir.path().join("workspace.json")).unwrap();
    assert!(
        store
            .set_connection_after_retirement(&original.id, None, &second)
            .is_err()
    );
    assert_eq!(fs::read(dir.path().join("workspace.json")).unwrap(), bytes);
    store
        .set_pinned(original.clone(), DraftRecord::default(), true, 7)
        .unwrap();
    assert_eq!(store.snapshot().chats[0].connection_id, Some(first.clone()));
    store
        .set_connection_after_retirement(&original.id, Some(&first), &second)
        .unwrap();
    drop(store);
    let reopened = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
    assert_eq!(reopened.snapshot().chats[0].connection_id, Some(second));
    assert_eq!(reopened.snapshot().drafts, before.drafts);
}

#[test]
fn switch_never_materializes_an_unknown_pending_chat() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
    assert!(
        store
            .set_connection_after_retirement(
                &Uuid::new_v4().to_string(),
                None,
                &Uuid::new_v4().to_string()
            )
            .is_err()
    );
    assert!(!dir.path().join("workspace.json").exists());
}

#[test]
fn uncertain_connection_commit_never_claims_rollback_or_accepts_more_writes() {
    for (fault, committed) in [(Fault::BeforeRename, false), (Fault::AfterRename, true)] {
        let (dir, mut store, chat) = fixture();
        let id = Uuid::new_v4().to_string();
        store.fault = fault;
        assert!(
            store
                .set_connection_after_retirement(&chat.id, None, &id)
                .is_err()
        );
        assert!(store.snapshot().chats[0].connection_id.is_none());
        assert_eq!(store.is_uncertain(), committed);
        store.fault = Fault::None;
        if committed {
            assert!(
                store
                    .set_connection_after_retirement(&chat.id, None, &id)
                    .is_err()
            );
        }
        drop(store);
        let reopened = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
        assert_eq!(
            reopened.snapshot().chats[0].connection_id,
            committed.then_some(id)
        );
    }
}
