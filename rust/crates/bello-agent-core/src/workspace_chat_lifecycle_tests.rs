use super::*;
use crate::workspace_read_state::ChatReadState;

fn fixture() -> (tempfile::TempDir, WorkspaceStore, ChatRecord, ChatRecord) {
    let dir = tempfile::tempdir().unwrap();
    let mut store = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
    let mut chats = Vec::new();
    for title in ["First", "Second"] {
        let id = Uuid::new_v4().to_string();
        let chat = ChatRecord::new(id.clone(), title.into(), store.chat_path(&id).unwrap());
        store
            .register(
                chat.clone(),
                DraftRecord {
                    text: format!("{title} draft"),
                    revision: 1,
                    ..Default::default()
                },
            )
            .unwrap();
        chats.push(chat);
    }
    let second = chats.pop().unwrap();
    let first = chats.pop().unwrap();
    (dir, store, first, second)
}

#[test]
fn chat_titles_normalize_like_swift_chat_record() {
    assert_eq!(
        ChatRecord::normalized_title(" \t\n\u{200b}")
            .unwrap_err()
            .to_string(),
        invalid("Enter a title for this chat.").to_string()
    );
    assert_eq!(
        ChatRecord::normalized_title("  Plan\u{a0}the \r\n release ").unwrap(),
        "Plan the release"
    );
    let cluster = "👩🏽‍💻";
    assert_eq!(
        ChatRecord::normalized_title(&"e\u{301}".repeat(130)).unwrap(),
        "e\u{301}".repeat(120)
    );
    // Whole graphemes within the catalog's 512-byte title limit.
    let long = ChatRecord::normalized_title(&cluster.repeat(130)).unwrap();
    assert_eq!(long, cluster.repeat(512 / cluster.len()));
}

#[test]
fn draft_marker_follows_swift_holds_unsent_draft() {
    let mut draft = DraftRecord::default();
    assert!(!draft.holds_unsent());
    draft.text = " \n\u{200b} ".into();
    assert!(!draft.holds_unsent());
    draft.text = "half a thought".into();
    assert!(draft.holds_unsent());
    draft.text.clear();
    draft.queued_edit = Some(QueuedDraft {
        edit_id: "e".into(),
        turn_id: "t".into(),
        rewrite: " original ".into(),
        original_text: Some("original".into()),
    });
    // Opening a queued message is not unsent work; rewriting it is.
    assert!(!draft.holds_unsent());
    draft.queued_edit.as_mut().unwrap().rewrite = "rewritten".into();
    assert!(draft.holds_unsent());
}

#[test]
fn rename_patches_only_the_title_and_survives_reopen() {
    let (dir, mut store, first, second) = fixture();
    let renamed = store
        .rename_chat(&first.id, &first.snapshot, "  Release   notes ")
        .unwrap();
    assert_eq!(renamed.title, "Release notes");
    assert_eq!(renamed.pinned_at, first.pinned_at);
    assert!(
        store
            .rename_chat(&first.id, &second.snapshot, "Other")
            .is_err()
    );
    assert!(store.rename_chat(&first.id, &first.snapshot, "  ").is_err());
    drop(store);
    let state = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path())
        .unwrap()
        .snapshot();
    assert_eq!(state.chats[0].title, "Release notes");
    assert_eq!(state.chats[1].title, "Second");
}

#[test]
fn delete_removes_only_the_chats_own_rows_and_lists_its_own_files() {
    let (dir, mut store, first, second) = fixture();
    store.select(&first.id, 1).unwrap();
    store.state.read_states.insert(
        first.id.clone(),
        ChatReadState {
            revision: 1,
            ..Default::default()
        },
    );
    store.state.settled_submissions.insert(first.id.clone(), 3);
    let chats = first.snapshot.parent().unwrap().to_owned();
    fs::create_dir_all(&chats).unwrap();
    let generation = Uuid::new_v4();
    let journal = chats.join(format!("{}.json.{generation}.stream.jsonl", first.id));
    for path in [
        &first.snapshot,
        &second.snapshot,
        &journal,
        &chats.join(format!("{}.json.not-a-uuid.stream.jsonl", first.id)),
        &chats.join(format!("{}.json.{generation}.stream.jsonl", second.id)),
    ] {
        fs::write(path, b"{}").unwrap();
    }
    fs::write(first.snapshot.with_extension("lock"), b"").unwrap();

    assert!(
        store
            .delete_chat(&first.id, &second.snapshot, None)
            .is_err()
    );
    let deleted = store.delete_chat(&first.id, &first.snapshot, None).unwrap();
    assert_eq!(deleted.record.id, first.id);
    assert_eq!(deleted.managed_files, vec![first.snapshot.clone(), journal]);
    assert_eq!(
        deleted.lock_file,
        Some(first.snapshot.with_extension("lock"))
    );
    // Nothing is removed from disk by the catalog.
    assert!(first.snapshot.exists());
    drop(store);
    let state = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path())
        .unwrap()
        .snapshot();
    assert_eq!(
        state.chats.iter().map(|c| &c.id).collect::<Vec<_>>(),
        [&second.id]
    );
    assert!(!state.drafts.contains_key(&first.id));
    assert_eq!(state.drafts[&second.id].text, "Second draft");
    assert!(state.read_states.is_empty());
    assert!(state.settled_submissions.is_empty());
    assert_eq!(state.selected, None);
}

#[test]
fn delete_refuses_unfinished_work_and_lists_no_foreign_files() {
    let (_dir, mut store, first, second) = fixture();
    store.state.intents.insert(
        "intent".into(),
        SubmissionIntent {
            skills: Vec::new(),
            attachments: Vec::new(),
            id: "intent".into(),
            chat_id: first.id.clone(),
            text: "queued".into(),
            lane: Lane::FollowUp,
            draft_revision: 1,
        },
    );
    assert_eq!(
        store
            .delete_chat(&first.id, &first.snapshot, None)
            .unwrap_err()
            .to_string(),
        invalid(DELETE_WORK_NOTICE).to_string()
    );
    store.state.intents.clear();
    // A snapshot outside the catalog's managed path is kept, as Swift keeps
    // an imported original.
    let outside = tempfile::tempdir().unwrap();
    let original = outside.path().join("original.json");
    fs::write(&original, b"{}").unwrap();
    let mut imported = second.clone();
    imported.id = Uuid::new_v4().to_string();
    imported.snapshot = original.clone();
    store
        .register(imported.clone(), DraftRecord::default())
        .unwrap();
    let deleted = store.delete_chat(&imported.id, &original, None).unwrap();
    assert!(deleted.managed_files.is_empty());
    assert_eq!(deleted.lock_file, None);
    assert!(original.exists());
}

#[test]
fn unloaded_checkpoint_rename_writes_the_chats_own_title() {
    let dir = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4().to_string();
    let path = dir.path().join(format!("{id}.json"));
    let mut store = crate::SessionStore::pending_with_id(&id).unwrap();
    store.persist_to(&path).unwrap();
    // A live writer holds the checkpoint: the rename waits for it.
    assert!(rename_saved_checkpoint(&path, &id, "Busy").is_err());
    drop(store);
    assert!(rename_saved_checkpoint(&path, &Uuid::new_v4().to_string(), "Other").is_err());
    rename_saved_checkpoint(&path, &id, "  Renamed\nchat ").unwrap();
    let reopened = crate::SessionStore::open_existing_with_id(&path, &id).unwrap();
    assert_eq!(reopened.snapshot().title, "Renamed chat");
}

#[test]
fn settled_cancellation_receipts_do_not_block_and_leave_with_the_chat() {
    let (_dir, mut store, first, _second) = fixture();
    store.state.queued_cancellations.insert(
        first.id.clone(),
        QueuedCancelReceipt {
            revision: 0,
            state: QueuedCancelState::Settled,
        },
    );
    store.delete_chat(&first.id, &first.snapshot, None).unwrap();
    assert!(store.state.queued_cancellations.is_empty());
}

#[test]
fn the_apps_startup_anchor_is_managed_storage() {
    let (_dir, mut store, _first, second) = fixture();
    let outside = tempfile::tempdir().unwrap();
    let anchor = outside.path().join("default.json");
    fs::write(&anchor, b"{}").unwrap();
    let mut chat = second.clone();
    chat.id = Uuid::new_v4().to_string();
    chat.snapshot = anchor.clone();
    store
        .register(chat.clone(), DraftRecord::default())
        .unwrap();
    let deleted = store.delete_chat(&chat.id, &anchor, Some(&anchor)).unwrap();
    assert_eq!(deleted.managed_files, vec![anchor.clone()]);
    assert_eq!(deleted.lock_file, Some(anchor.with_extension("lock")));
}
