//! Deletion over a disposable catalog. In tests the Trash is the state
//! directory's "Deleted Chats" folder, so nothing leaves the temporary root.
use crate::sidebar_chats::tests::{app_fixture, select};
use bello_agent_core::workspace::{DELETE_WORK_NOTICE, WorkspaceSnapshot};
use gpui::TestAppContext;

fn catalog(dir: &tempfile::TempDir) -> WorkspaceSnapshot {
    serde_json::from_slice(&std::fs::read(dir.path().join("workspace.json")).unwrap()).unwrap()
}

#[gpui::test]
fn deleting_an_unloaded_chat_moves_only_its_own_files(cx: &mut TestAppContext) {
    let (dir, window, root, chats) = app_fixture(cx, &[("Keep", "kept draft"), ("Delete", "gone")]);
    let target = &chats[1];
    let journal = target.snapshot.with_file_name(format!(
        "{}.json.{}.stream.jsonl",
        target.id,
        uuid::Uuid::new_v4()
    ));
    std::fs::write(&journal, b"").unwrap();
    window
        .update(cx, |view, _, cx| {
            view.ask_delete_chat(&target.id, cx);
            let question = view.sidebar_chats.delete.as_ref().unwrap();
            assert_eq!(question.title, "Delete this chat?");
            assert_eq!(
                question.detail,
                "Move its managed conversation file to Trash and remove its draft and current memory traces, and locally retained traces."
            );
        })
        .unwrap();
    window
        .update(cx, |view, window, cx| {
            let token = view.sidebar_chats.delete.as_ref().unwrap().token;
            view.confirm_delete_chat(token, window, cx);
            // The row leaves at once; the work finishes in the background.
            assert!(!view.records.iter().any(|r| r.id == target.id));
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.error, None);
        assert!(view.sidebar_chats.busy.is_empty());
        assert!(!view.shows_draft_mark(&target.id));
    });
    let saved = catalog(&dir);
    assert_eq!(
        saved.chats.iter().map(|c| &c.id).collect::<Vec<_>>(),
        [&chats[0].id]
    );
    assert!(!saved.drafts.contains_key(&target.id));
    assert_eq!(saved.drafts[&chats[0].id].text, "kept draft");
    assert!(!target.snapshot.exists() && !journal.exists());
    assert!(!target.snapshot.with_extension("lock").exists());
    assert!(chats[0].snapshot.exists());
    let deleted = dir.path().join("Deleted Chats");
    assert!(deleted.join(target.snapshot.file_name().unwrap()).exists());
    assert!(deleted.join(journal.file_name().unwrap()).exists());
}

#[gpui::test]
fn deleting_the_open_archived_chat_steps_aside_and_retires_its_writer(cx: &mut TestAppContext) {
    let (dir, window, root, chats) = app_fixture(cx, &[("Other", ""), ("Open", "")]);
    let target = &chats[1];
    select(window, &target.id, cx);
    window
        .update(cx, |view, _, cx| {
            assert!(view.controller.is_persistent());
            view.records
                .iter_mut()
                .find(|r| r.id == target.id)
                .unwrap()
                .archived_at = Some(1);
            view.ask_delete_chat(&target.id, cx);
            assert_eq!(
                view.sidebar_chats.delete.as_ref().unwrap().title,
                "Delete the archived chat “Open”?"
            );
        })
        .unwrap();
    window
        .update(cx, |view, window, cx| {
            let token = view.sidebar_chats.delete.as_ref().unwrap().token;
            view.confirm_delete_chat(token, window, cx);
            assert_eq!(view.record.id, chats[0].id);
            assert!(view.chat_ref(&target.id).is_none());
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(cx.read(|cx| root.read(cx).error.clone()), None);
    assert!(!target.snapshot.exists());
    assert_eq!(catalog(&dir).chats.len(), 1);
}

#[gpui::test]
fn work_refuses_and_escape_cancels_without_touching_anything(cx: &mut TestAppContext) {
    let (dir, window, root, chats) = app_fixture(cx, &[("Busy", ""), ("Idle", "")]);
    select(window, &chats[0].id, cx);
    window
        .update(cx, |view, _, cx| {
            view.busy = true;
            view.ask_delete_chat(&chats[0].id, cx);
            assert!(view.sidebar_chats.delete.is_none());
            assert_eq!(view.error.as_deref(), Some(DELETE_WORK_NOTICE));
            view.busy = false;
            view.ask_delete_chat(&chats[1].id, cx);
            assert!(view.sidebar_chats.delete.is_some());
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), "enter");
    // Return alone never answers a destructive question.
    assert!(cx.read(|cx| root.read(cx).sidebar_chats.delete.is_some()));
    cx.simulate_keystrokes(window.into(), "escape");
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).sidebar_chats.delete.is_none()));
    assert_eq!(catalog(&dir).chats.len(), 2);
    assert!(chats.iter().all(|chat| chat.snapshot.exists()));
}

#[gpui::test]
fn an_unsaved_chat_is_dropped_and_an_outside_checkpoint_stays(cx: &mut TestAppContext) {
    let (dir, window, root, chats) = app_fixture(cx, &[("Saved", "")]);
    let launch = cx.read(|cx| root.read(cx).record.id.clone());
    // The new chat that exists only on screen, with a draft so it stays listed.
    window
        .update(cx, |view, _, cx| {
            view.composer
                .update(cx, |editor, cx| editor.set_text("draft".into(), cx));
        })
        .unwrap();
    select(window, &chats[0].id, cx);
    window
        .update(cx, |view, window, cx| {
            assert!(view.chat_ref(&launch).is_some_and(|chat| chat.pending));
            view.ask_delete_chat(&launch, cx);
            let token = view.sidebar_chats.delete.as_ref().unwrap().token;
            view.confirm_delete_chat(token, window, cx);
            assert!(view.chat_ref(&launch).is_none());
            assert!(!view.records.iter().any(|r| r.id == launch));
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(catalog(&dir).chats.len(), 1);
    // A checkpoint outside the catalog's managed path stays where it is.
    let outside = tempfile::tempdir().unwrap();
    let original = outside.path().join("original.json");
    let id = uuid::Uuid::new_v4().to_string();
    let mut store = bello_agent_core::SessionStore::pending_with_id(&id).unwrap();
    store.persist_to(&original).unwrap();
    drop(store);
    let record = bello_agent_core::workspace::ChatRecord::new(
        id.clone(),
        "Imported".into(),
        original.clone(),
    );
    window
        .update(cx, |view, _, cx| {
            view.workspace
                .lock()
                .unwrap()
                .register(record.clone(), Default::default())
                .unwrap();
            view.records.push(record.clone());
            view.ask_delete_chat(&id, cx);
            assert_eq!(
                view.sidebar_chats.delete.as_ref().unwrap().detail,
                "Remove its app index and draft. The imported original stays in place."
            );
        })
        .unwrap();
    window
        .update(cx, |view, window, cx| {
            let token = view.sidebar_chats.delete.as_ref().unwrap().token;
            view.confirm_delete_chat(token, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    assert!(original.exists());
    assert!(!catalog(&dir).chats.iter().any(|c| c.id == id));
}

#[gpui::test]
fn an_unloaded_checkpoint_with_queued_messages_is_not_deleted(cx: &mut TestAppContext) {
    let (dir, window, root, chats) = app_fixture(cx, &[("Queued", ""), ("Other", "")]);
    let mut store =
        bello_agent_core::SessionStore::open_existing_with_id(&chats[0].snapshot, &chats[0].id)
            .unwrap();
    store
        .transact(|session| {
            session.pending.push(bello_agent_core::Submission::new(
                "later".into(),
                bello_agent_core::session::Lane::FollowUp,
            ));
            Ok(())
        })
        .unwrap();
    drop(store);
    window
        .update(cx, |view, window, cx| {
            view.ask_delete_chat(&chats[0].id, cx);
            let token = view.sidebar_chats.delete.as_ref().unwrap().token;
            view.confirm_delete_chat(token, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.error.as_deref().unwrap().contains(DELETE_WORK_NOTICE));
        assert!(view.records.iter().any(|r| r.id == chats[0].id));
        assert!(view.sidebar_chats.busy.is_empty());
    });
    assert_eq!(catalog(&dir).chats.len(), 2);
    assert!(chats[0].snapshot.exists());
}
