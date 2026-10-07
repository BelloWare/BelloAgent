//! File fixtures only. Source contract: MetadataStore.swift ChatRecord and
//! WorkspaceRecord, WorkspaceChatLifecycle.swift, WorkspaceSides.swift:622-649.
//! Imported/utility/side lifecycle and actual tool admission remain unported.
use super::*;
use serde_json::{Value, json};

fn fixture(mode: ChatToolMode) -> (tempfile::TempDir, WorkspaceStore, ChatRecord) {
    let dir = tempfile::tempdir().unwrap();
    let mut store = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
    let id = Uuid::new_v4().to_string();
    let mut chat = ChatRecord::new(
        id.clone(),
        "retained chat".into(),
        store.chat_path(&id).unwrap(),
    );
    chat.tool_mode = mode;
    let draft = DraftRecord {
        attachments: Vec::new(),
        revision: 4,
        text: "unsent ordinary draft".into(),
        queued_edit: Some(QueuedDraft {
            edit_id: "edit".into(),
            turn_id: "turn".into(),
            rewrite: "unsent queued rewrite".into(),
            original_text: Some("original queued text".into()),
        }),
    };
    store.register(chat.clone(), draft).unwrap();
    (dir, store, chat)
}

fn bytes(store: &WorkspaceStore) -> Vec<u8> {
    serde_json::to_vec(&store.snapshot()).unwrap()
}

fn legacy(mut value: Value, version: u32) -> Value {
    value["version"] = version.into();
    if version < 5 {
        value.as_object_mut().unwrap().remove("project_id");
    }
    for chat in value["chats"].as_array_mut().unwrap() {
        if version < 5 {
            chat.as_object_mut().unwrap().remove("tool_mode");
        }
        chat.as_object_mut().unwrap().remove("connection_id");
        chat.as_object_mut().unwrap().remove("materialization");
        if version == 1 {
            chat.as_object_mut().unwrap().remove("sidebar_order");
            chat.as_object_mut().unwrap().remove("pinned_at");
        }
    }
    value
}

#[test]
fn source_ordinary_default_and_two_exact_wire_modes_do_not_create_tools() {
    let dir = tempfile::tempdir().unwrap();
    let chat = ChatRecord::new(
        Uuid::new_v4().to_string(),
        "new".into(),
        dir.path().join("chat.json"),
    );
    assert_eq!(chat.tool_mode, ChatToolMode::Editing);
    assert_eq!(ChatToolMode::default(), ChatToolMode::Editing);
    assert_eq!(
        serde_json::to_value(ChatToolMode::Editing).unwrap(),
        "editing"
    );
    assert_eq!(
        serde_json::to_value(ChatToolMode::ReadOnly).unwrap(),
        "read-only"
    );
    for invalid in [
        json!("disabled"),
        json!("read_only"),
        json!("future"),
        json!(null),
        json!(false),
    ] {
        assert!(serde_json::from_value::<ChatToolMode>(invalid).is_err());
    }
    assert!(fs::read_dir(dir.path()).unwrap().next().is_none());
    assert!(matches!(
        crate::project_authority::ProjectAuthority::new().load(),
        Err(crate::project_authority::AuthorityError::Unavailable)
    ));
}

#[test]
fn all_legacy_versions_open_without_binding_or_rewrite_then_migrate_on_draft_write() {
    for version in 1..=4 {
        let (dir, mut store, chat) = fixture(ChatToolMode::Editing);
        let draft = store.snapshot().drafts[&chat.id].clone();
        store.select(&chat.id, 3).unwrap();
        if version >= 3 {
            let pending = QueuedCancelReceipt::pending(0, "edit".into(), "turn".into()).unwrap();
            store
                .prepare_queued_cancel(&chat.id, pending, draft.clone())
                .unwrap();
        }
        if version >= 4 {
            store
                .set_archived(chat.clone(), draft.clone(), true, 9)
                .unwrap();
            store.set_archive_visibility(true, 4).unwrap();
        }
        let value = legacy(serde_json::to_value(store.snapshot()).unwrap(), version);
        let before =
            format!(" \n{}\n ", serde_json::to_string_pretty(&value).unwrap()).into_bytes();
        let path = dir.path().join("workspace.json");
        drop(store);
        fs::write(&path, &before).unwrap();
        let mut reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
        let old = reopened.snapshot();
        assert_eq!(old.version, version);
        assert_eq!(old.project_id, None);
        assert_eq!(old.chats[0].tool_mode, ChatToolMode::Editing);
        assert_eq!(fs::read(&path).unwrap(), before);
        // A no-op mode request is not an implicit migration or trust operation.
        reopened
            .enable_editing_after_confirmation(&chat.id)
            .unwrap();
        assert_eq!(fs::read(&path).unwrap(), before);
        let newer = DraftRecord {
            attachments: Vec::new(),
            revision: draft.revision + 1,
            ..draft
        };
        reopened.save_draft(&chat.id, newer.clone()).unwrap();
        let migrated = reopened.snapshot();
        assert_eq!(migrated.version, CURRENT_VERSION);
        assert_eq!(migrated.project_id, None);
        assert_eq!(migrated.chats, old.chats);
        assert_eq!(migrated.selected, old.selected);
        assert_eq!(migrated.selection_revision, old.selection_revision);
        assert_eq!(migrated.queued_cancellations, old.queued_cancellations);
        assert_eq!(
            migrated.archive_visibility_revision,
            old.archive_visibility_revision
        );
        assert_eq!(migrated.show_archived, old.show_archived);
        assert_eq!(migrated.drafts[&chat.id], newer);
        let on_disk: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(on_disk["chats"][0]["tool_mode"], "editing");
        drop(reopened);
        let restored = WorkspaceStore::open(&path, dir.path()).unwrap();
        assert_eq!(bytes(&restored), serde_json::to_vec(&migrated).unwrap());
    }
}

#[test]
fn invalid_v5_and_future_metadata_fail_before_confirmation_without_rewriting() {
    let (dir, store, _chat) = fixture(ChatToolMode::ReadOnly);
    let base = serde_json::to_value(store.snapshot()).unwrap();
    let path = dir.path().join("workspace.json");
    drop(store);
    let mut cases = vec![];
    let mut missing = base.clone();
    missing["chats"][0]
        .as_object_mut()
        .unwrap()
        .remove("tool_mode");
    cases.push(missing);
    for mode in [
        json!(null),
        json!("disabled"),
        json!("EDITING"),
        json!("future"),
        json!(0),
        json!({}),
    ] {
        let mut value = base.clone();
        value["chats"][0]["tool_mode"] = mode;
        cases.push(value);
    }
    for id in [
        json!(null),
        json!(""),
        json!("not-a-uuid"),
        json!(0),
        json!([]),
    ] {
        let mut value = base.clone();
        value["project_id"] = id;
        cases.push(value);
    }
    for field in [
        "imported",
        "connection_test",
        "parent_session_id",
        "future_tool_authority",
    ] {
        let mut value = base.clone();
        value["chats"][0][field] = json!(true);
        cases.push(value);
    }
    let mut unknown = base.clone();
    unknown["future_project_authority"] = json!({"trusted": true});
    cases.push(unknown);
    for version in [0, CURRENT_VERSION + 1, u32::MAX] {
        let mut value = base.clone();
        value["version"] = version.into();
        cases.push(value);
    }
    for version in 1..=4 {
        let old = legacy(base.clone(), version);
        for field in ["tool_mode", "project_id"] {
            let mut value = old.clone();
            if field == "tool_mode" {
                value["chats"][0][field] = json!("editing");
            } else {
                value[field] = json!(Uuid::new_v4().to_string());
            }
            cases.push(value);
        }
    }
    for (index, value) in cases.into_iter().enumerate() {
        let before =
            format!(" \n{}\n ", serde_json::to_string_pretty(&value).unwrap()).into_bytes();
        fs::write(&path, &before).unwrap();
        assert!(
            WorkspaceStore::open_with_confirmation(&path, dir.path(), |_| {
                panic!("invalid identity/mode fixture {index} reached confirmation")
            })
            .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), before);
    }
}

#[test]
fn enable_editing_patches_only_mode_and_stale_rows_cannot_take_it_back() {
    let (dir, mut store, chat) = fixture(ChatToolMode::ReadOnly);
    store
        .set_archived(chat.clone(), DraftRecord::default(), true, 7)
        .unwrap();
    let before = store.snapshot();
    let saved = store.enable_editing_after_confirmation(&chat.id).unwrap();
    assert_eq!(saved.tool_mode, ChatToolMode::Editing);
    let after = store.snapshot();
    let mut expected = before.clone();
    expected.revision += 1;
    expected.chats[0].tool_mode = ChatToolMode::Editing;
    assert_eq!(
        serde_json::to_value(&after).unwrap(),
        serde_json::to_value(expected).unwrap()
    );
    let path = dir.path().join("workspace.json");
    let committed = fs::read(&path).unwrap();
    store.enable_editing_after_confirmation(&chat.id).unwrap();
    assert_eq!(fs::read(&path).unwrap(), committed);
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    store
        .set_pinned(chat.clone(), DraftRecord::default(), true, 2)
        .unwrap();
    store
        .set_archived(chat.clone(), DraftRecord::default(), false, 3)
        .unwrap();
    assert_eq!(store.snapshot().chats[0].tool_mode, ChatToolMode::Editing);
    assert_eq!(store.snapshot().drafts, before.drafts);
    let committed = fs::read(&path).unwrap();
    assert!(
        store
            .enable_editing_after_confirmation(&Uuid::new_v4().to_string())
            .is_err()
    );
    assert_eq!(fs::read(&path).unwrap(), committed);
    drop(store);
    let reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
    assert_eq!(
        reopened.snapshot().chats[0].tool_mode,
        ChatToolMode::Editing
    );
    assert!(!chat.snapshot.exists());
}

#[test]
fn mode_pre_and_post_rename_failures_preserve_recovery_material_and_fence_writes() {
    for fault in [Fault::BeforeRename, Fault::AfterRename] {
        let (dir, mut store, chat) = fixture(ChatToolMode::ReadOnly);
        let draft = store.snapshot().drafts[&chat.id].clone();
        let pending = QueuedCancelReceipt::pending(0, "edit".into(), "turn".into()).unwrap();
        store
            .prepare_queued_cancel(&chat.id, pending, draft.clone())
            .unwrap();
        store
            .set_archived(chat.clone(), draft.clone(), true, 7)
            .unwrap();
        store.set_archive_visibility(true, 2).unwrap();
        let before = store.snapshot();
        let before_memory = bytes(&store);
        let path = dir.path().join("workspace.json");
        let before_disk = fs::read(&path).unwrap();
        store.fault = fault;
        let result = store.enable_editing_after_confirmation(&chat.id);
        assert!(result.is_err());
        assert_eq!(bytes(&store), before_memory);
        if matches!(fault, Fault::BeforeRename) {
            assert!(!store.is_uncertain());
            assert_eq!(fs::read(&path).unwrap(), before_disk);
        } else {
            assert!(matches!(result, Err(Error::PersistenceUncertain(_))));
            assert!(store.is_uncertain());
            assert!(store.enable_editing_after_confirmation(&chat.id).is_err());
            assert!(
                store
                    .save_draft(
                        &chat.id,
                        DraftRecord {
                            attachments: Vec::new(),
                            revision: 5,
                            ..draft
                        }
                    )
                    .is_err()
            );
            assert!(store.set_archive_visibility(false, 3).is_err());
        }
        drop(store);
        let reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
        let after = reopened.snapshot();
        assert_eq!(
            after.chats[0].tool_mode,
            if matches!(fault, Fault::AfterRename) {
                ChatToolMode::Editing
            } else {
                ChatToolMode::ReadOnly
            }
        );
        assert_eq!(after.drafts, before.drafts);
        assert_eq!(after.queued_cancellations, before.queued_cancellations);
        assert_eq!(after.chats[0].archived_at, before.chats[0].archived_at);
        assert_eq!(after.show_archived, before.show_archived);
        assert_eq!(
            after.archive_visibility_revision,
            before.archive_visibility_revision
        );
        assert!(!chat.snapshot.exists());
    }
}

#[cfg(feature = "synthetic-authority")]
mod binding {
    use super::*;
    use crate::project_authority::{
        AuthorityError, LoadedProjects, ProjectAuthority, SavedProject,
        synthetic::SyntheticAuthorityControl,
    };

    fn authority(
        root: &Path,
    ) -> (
        ProjectAuthority,
        LoadedProjects,
        SavedProject,
        SyntheticAuthorityControl,
    ) {
        let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
        let mut draft = authority.load().unwrap().edit();
        let project = draft
            .trust_project(&Uuid::new_v4().to_string(), root, &[])
            .unwrap();
        let loaded = authority.save(&mut draft).unwrap();
        (authority, loaded, project, control)
    }

    #[test]
    fn binding_consumes_confirmed_existing_id_without_authority_io_or_retrust() {
        let (dir, mut store, chat) = fixture(ChatToolMode::ReadOnly);
        let (authority, loaded, project, control) = authority(dir.path());
        let vault_before = control.snapshot_bytes().unwrap();
        let before = store.snapshot();
        let binding = authority
            .confirm_project_binding(&loaded, &project)
            .unwrap();
        assert_eq!(binding.project_id(), project.id);
        assert_eq!(binding.project_path(), project.path);
        control.fail_next_read(AuthorityError::Denied).unwrap();
        assert!(store.bind_project_identity(binding).unwrap());
        // The pending backend error was not consumed under the catalog mutex.
        assert!(matches!(authority.load(), Err(AuthorityError::Denied)));
        assert_eq!(control.snapshot_bytes().unwrap(), vault_before);
        let mut expected = before;
        expected.project_id = Some(project.id.clone());
        expected.revision += 1;
        assert_eq!(bytes(&store), serde_json::to_vec(&expected).unwrap());
        let path = dir.path().join("workspace.json");
        let committed = fs::read(&path).unwrap();
        let binding = authority
            .confirm_project_binding(&loaded, &project)
            .unwrap();
        assert!(!store.bind_project_identity(binding).unwrap());
        assert_eq!(fs::read(&path).unwrap(), committed);
        drop(store);
        let reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
        assert_eq!(reopened.snapshot().project_id, Some(project.id));
        assert_eq!(
            reopened.snapshot().chats[0].tool_mode,
            ChatToolMode::ReadOnly
        );
        assert!(!chat.snapshot.exists());
    }

    #[test]
    fn mismatched_root_rebinding_and_same_id_relocation_fail_without_catalog_write() {
        let (dir, mut store, _chat) = fixture(ChatToolMode::Editing);
        let (authority, loaded, project, _control) = authority(dir.path());
        store
            .bind_project_identity(
                authority
                    .confirm_project_binding(&loaded, &project)
                    .unwrap(),
            )
            .unwrap();
        let path = dir.path().join("workspace.json");
        let before = fs::read(&path).unwrap();
        let other = tempfile::tempdir().unwrap();
        let mut draft = loaded.edit();
        let another_id = draft
            .trust_project(&Uuid::new_v4().to_string(), dir.path(), &[])
            .unwrap();
        let later = authority.save(&mut draft).unwrap();
        assert!(
            store
                .bind_project_identity(
                    authority
                        .confirm_project_binding(&later, &another_id)
                        .unwrap()
                )
                .is_err()
        );
        let relocated = draft.trust_project(&project.id, other.path(), &[]).unwrap();
        let latest = authority.save(&mut draft).unwrap();
        assert!(
            store
                .bind_project_identity(
                    authority
                        .confirm_project_binding(&latest, &relocated)
                        .unwrap()
                )
                .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), before);
        drop(store);
        assert!(WorkspaceStore::open(&path, other.path()).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
    }

    #[test]
    fn untrusted_stale_denied_and_unsupported_authority_cannot_mint_binding() {
        let (dir, store, _chat) = fixture(ChatToolMode::Editing);
        let (authority, loaded, project, control) = authority(dir.path());
        let before = fs::read(dir.path().join("workspace.json")).unwrap();
        let mut forged = project.clone();
        forged.trusted = false;
        assert!(matches!(
            authority.confirm_project_binding(&loaded, &forged),
            Err(AuthorityError::Untrusted)
        ));
        control.fail_next_read(AuthorityError::Denied).unwrap();
        assert!(matches!(
            authority.confirm_project_binding(&loaded, &project),
            Err(AuthorityError::Denied)
        ));
        let valid = control.snapshot_bytes().unwrap().unwrap();
        for patch in ["untrusted", "unknown", "future"] {
            let mut value: Value = serde_json::from_slice(&valid).unwrap();
            match patch {
                "untrusted" => value["workspaces"][0]["trusted"] = json!(false),
                "unknown" => value["workspaces"][0]["future_permissions"] = json!(true),
                _ => value["schema"] = json!(2),
            }
            control
                .replace_bytes(Some(serde_json::to_vec(&value).unwrap()))
                .unwrap();
            assert!(
                authority
                    .confirm_project_binding(&loaded, &project)
                    .is_err()
            );
            if let Ok(current) = authority.load() {
                assert!(
                    authority
                        .confirm_project_binding(&current, &current.projects()[0])
                        .is_err()
                );
            }
            assert_eq!(fs::read(dir.path().join("workspace.json")).unwrap(), before);
            assert_eq!(store.snapshot().project_id, None);
        }
    }

    #[test]
    fn binding_pre_and_post_rename_failures_keep_drafts_archive_and_cancellation() {
        for version in [4, 5, CURRENT_VERSION] {
            for fault in [Fault::BeforeRename, Fault::AfterRename] {
                let (dir, mut store, chat) = fixture(ChatToolMode::ReadOnly);
                let draft = store.snapshot().drafts[&chat.id].clone();
                let pending =
                    QueuedCancelReceipt::pending(0, "edit".into(), "turn".into()).unwrap();
                store
                    .prepare_queued_cancel(&chat.id, pending, draft.clone())
                    .unwrap();
                store.set_archived(chat.clone(), draft, true, 7).unwrap();
                store.set_archive_visibility(true, 2).unwrap();
                if version < CURRENT_VERSION {
                    let value = legacy(serde_json::to_value(store.snapshot()).unwrap(), version);
                    let path = dir.path().join("workspace.json");
                    drop(store);
                    fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
                    store = WorkspaceStore::open(&path, dir.path()).unwrap();
                }
                let (authority, loaded, project, control) = authority(dir.path());
                let before = store.snapshot();
                let before_memory = bytes(&store);
                let path = dir.path().join("workspace.json");
                let before_disk = fs::read(&path).unwrap();
                let authority_bytes = control.snapshot_bytes().unwrap();
                store.fault = fault;
                let result = store.bind_project_identity(
                    authority
                        .confirm_project_binding(&loaded, &project)
                        .unwrap(),
                );
                assert!(result.is_err());
                assert_eq!(bytes(&store), before_memory);
                assert_eq!(control.snapshot_bytes().unwrap(), authority_bytes);
                if matches!(fault, Fault::BeforeRename) {
                    assert!(!store.is_uncertain());
                    assert_eq!(fs::read(&path).unwrap(), before_disk);
                } else {
                    assert!(matches!(result, Err(Error::PersistenceUncertain(_))));
                    assert!(store.is_uncertain());
                    assert!(
                        store
                            .bind_project_identity(
                                authority
                                    .confirm_project_binding(&loaded, &project)
                                    .unwrap()
                            )
                            .is_err()
                    );
                    assert!(store.enable_editing_after_confirmation(&chat.id).is_err());
                }
                drop(store);
                let reopened = WorkspaceStore::open(&path, dir.path()).unwrap();
                let after = reopened.snapshot();
                assert_eq!(
                    after.version,
                    if matches!(fault, Fault::AfterRename) {
                        CURRENT_VERSION
                    } else {
                        version
                    }
                );
                assert_eq!(
                    after.project_id,
                    if matches!(fault, Fault::AfterRename) {
                        Some(project.id)
                    } else {
                        None
                    }
                );
                assert_eq!(after.chats, before.chats);
                assert_eq!(after.drafts, before.drafts);
                assert_eq!(after.queued_cancellations, before.queued_cancellations);
                assert_eq!(after.show_archived, before.show_archived);
                assert_eq!(
                    after.archive_visibility_revision,
                    before.archive_visibility_revision
                );
            }
        }
    }
}
