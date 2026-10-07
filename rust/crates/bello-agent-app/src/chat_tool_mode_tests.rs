use super::*;
use bello_agent_core::{SessionStore, project_authority::ProjectAuthority, workspace::DraftRecord};
use std::{
    future::pending,
    pin::pin,
    task::{Context, Poll, Wake, Waker},
};

struct TestWake(std::thread::Thread);
impl Wake for TestWake {
    fn wake(self: Arc<Self>) {
        self.0.unpark();
    }
    fn wake_by_ref(self: &Arc<Self>) {
        self.0.unpark();
    }
}
fn run<F: Future>(future: F) -> F::Output {
    let waker = Waker::from(Arc::new(TestWake(std::thread::current())));
    let mut context = Context::from_waker(&waker);
    let mut future = pin!(future);
    loop {
        match future.as_mut().poll(&mut context) {
            Poll::Ready(result) => return result,
            Poll::Pending => std::thread::park(),
        }
    }
}
fn fixture() -> (tempfile::TempDir, ChatModeChange) {
    let directory = tempfile::tempdir().unwrap();
    let primary = std::fs::canonicalize(directory.path()).unwrap();
    let path = primary.join("chat.json");
    let mut session = SessionStore::open(&path).unwrap();
    session
        .transact(|session| {
            session.title = "history retained".into();
            Ok(())
        })
        .unwrap();
    let mut record = ChatRecord::new(session.snapshot().id, "saved read-only".into(), path);
    record.tool_mode = ChatToolMode::ReadOnly;
    let mut workspace = WorkspaceStore::open(primary.join("catalog.json"), &primary).unwrap();
    workspace
        .register(
            record.clone(),
            DraftRecord {
                skills: Vec::new(),
                attachments: Vec::new(),
                text: "unsent 日本語".into(),
                revision: 1,
                ..Default::default()
            },
        )
        .unwrap();
    let controller = Controller::new(session, None).unwrap();
    let workspace = Arc::new(Mutex::new(workspace));
    let runtime = crate::saved_runtime_adapter::AppRuntime::new(
        ProjectAuthority::new(),
        workspace.clone(),
        crate::saved_runtime_adapter::AppRuntime::options(primary.clone(), false),
        None,
    );
    (
        directory,
        ChatModeChange {
            workspace,
            runtime,
            primary,
            record,
            controller: Some(controller),
        },
    )
}

#[test]
fn closes_before_mode_save_and_preserves_latest_metadata_and_drafts() {
    let (_directory, change) = fixture();
    let old = change.controller.as_ref().unwrap().clone();
    let workspace = change.workspace.clone();
    let id = change.record.id.clone();
    let path = change.record.snapshot.clone();
    let result = run(change.apply_using(
        |controller| async move {
            assert_eq!(
                workspace.lock().unwrap().snapshot().chats[0].tool_mode,
                ChatToolMode::ReadOnly
            );
            controller.retire_and_wait().await?;
            let mut store = workspace.lock().unwrap();
            store.name_chat(&id, "renamed while closing")?;
            store.save_draft(
                &id,
                DraftRecord {
                    skills: Vec::new(),
                    attachments: Vec::new(),
                    text: "newer unsent".into(),
                    revision: 2,
                    ..Default::default()
                },
            )?;
            store.select(&id, 8)?;
            Ok(())
        },
        |store, id| {
            assert!(old.is_retired());
            assert!(old.reorder(&[]).is_err());
            assert!(
                SessionStore::open(&path).is_ok(),
                "old writer joined before metadata save"
            );
            store.enable_editing_after_confirmation(id)
        },
    ))
    .unwrap_or_else(|error| panic!("{}", error.message));
    assert_eq!(result.record.tool_mode, ChatToolMode::Editing);
    assert_eq!(result.record.title, "renamed while closing");
    let replacement = result.replacement.unwrap();
    assert_eq!(replacement.controller.snapshot().title, "history retained");
    assert!(!Arc::ptr_eq(&replacement.previous, &replacement.controller));
    replacement.controller.reorder(&[]).unwrap();
    let bytes: serde_json::Value =
        serde_json::from_slice(&std::fs::read(_directory.path().join("catalog.json")).unwrap())
            .unwrap();
    assert_eq!(bytes["drafts"][&result.record.id]["text"], "newer unsent");
    assert_eq!(bytes["selection_revision"], 8);
    let reopened =
        WorkspaceStore::open(_directory.path().join("catalog.json"), _directory.path()).unwrap();
    assert_eq!(
        reopened.snapshot().chats[0].tool_mode,
        ChatToolMode::Editing
    );
}

#[test]
fn definite_prewrite_failure_reopens_read_only_without_reviving_old_arc() {
    let (_directory, change) = fixture();
    let old = change.controller.as_ref().unwrap().clone();
    let workspace = change.workspace.clone();
    let failure = run(change.apply_using(
        |controller| async move { controller.retire_and_wait().await },
        |_store, _id| Err(std::io::Error::other("known prewrite failure").into()),
    ))
    .err()
    .unwrap();
    assert!(!failure.keep_blocked && !failure.uncertain);
    assert!(old.is_retired());
    assert!(old.reorder(&[]).is_err());
    let replacement = failure.recovery.unwrap();
    replacement.controller.reorder(&[]).unwrap();
    assert_eq!(
        workspace.lock().unwrap().snapshot().chats[0].tool_mode,
        ChatToolMode::ReadOnly
    );
}

#[test]
fn uncertain_mode_write_never_reopens_the_old_read_only_session() {
    let (_directory, change) = fixture();
    let old = change.controller.as_ref().unwrap().clone();
    let failure = run(change.apply_using(
        |controller| async move { controller.retire_and_wait().await },
        |store, id| {
            store.enable_editing_after_confirmation(id)?;
            Err(Error::PersistenceUncertain(
                "injected missing save confirmation".into(),
            ))
        },
    ))
    .err()
    .unwrap();
    assert!(failure.keep_blocked && failure.uncertain && failure.recovery.is_none());
    assert!(old.reorder(&[]).is_err());
}

#[test]
fn interrupted_close_keeps_old_arc_fenced_and_mode_unpublished() {
    let (_directory, change) = fixture();
    let old = change.controller.as_ref().unwrap().clone();
    let workspace = change.workspace.clone();
    let mut operation = Box::pin(change.apply_using(
        |controller| async move {
            controller.retire_and_wait().await?;
            pending::<Result<()>>().await
        },
        |_store, _id| panic!("an abandoned close must never save the mode"),
    ));
    let waker = Waker::from(Arc::new(TestWake(std::thread::current())));
    assert!(
        operation
            .as_mut()
            .poll(&mut Context::from_waker(&waker))
            .is_pending()
    );
    drop(operation);
    assert!(old.is_retired());
    assert!(old.reorder(&[]).is_err());
    assert_eq!(
        workspace.lock().unwrap().snapshot().chats[0].tool_mode,
        ChatToolMode::ReadOnly
    );
}

#[test]
fn cancelling_before_transaction_starts_leaves_mode_runtime_and_bytes_unchanged() {
    let (directory, change) = fixture();
    let old = change.controller.as_ref().unwrap().clone();
    let catalog = directory.path().join("catalog.json");
    let before = std::fs::read(&catalog).unwrap();
    // A declined source confirmation never schedules this transaction. Dropping
    // an unpolled operation likewise performs no close, fence or catalog write.
    drop(change.apply());
    assert!(!old.is_retired());
    old.reorder(&[]).unwrap();
    assert_eq!(std::fs::read(catalog).unwrap(), before);
}

#[test]
fn failed_close_never_writes_mode_or_releases_unjoined_writer() {
    let (_directory, change) = fixture();
    let old = change.controller.as_ref().unwrap().clone();
    let path = change.record.snapshot.clone();
    let workspace = change.workspace.clone();
    let failure = run(change.apply_using(
        |_controller| async { Err(Error::Invalid("join failed".into())) },
        |_store, _id| panic!("failed close must not save"),
    ))
    .err()
    .unwrap();
    assert!(failure.keep_blocked && failure.recovery.is_none());
    assert!(SessionStore::open(path).is_err());
    assert!(old.reorder(&[]).is_err());
    assert_eq!(
        workspace.lock().unwrap().snapshot().chats[0].tool_mode,
        ChatToolMode::ReadOnly
    );
}

#[test]
fn unloaded_saved_chat_changes_mode_without_opening_runtime() {
    let (_directory, mut change) = fixture();
    drop(change.controller.take());
    let result = run(change.apply()).unwrap_or_else(|error| panic!("{}", error.message));
    assert!(result.replacement.is_none());
    assert_eq!(result.record.tool_mode, ChatToolMode::Editing);
}

#[test]
fn queued_and_pending_chats_fail_before_close_or_metadata_write() {
    let (_directory, mut change) = fixture();
    run(change.controller.take().unwrap().retire_and_wait()).unwrap();
    let mut session = SessionStore::open(&change.record.snapshot).unwrap();
    session
        .transact(|session| {
            session.submit(bello_agent_core::Submission::new(
                "queued input".into(),
                bello_agent_core::Lane::FollowUp,
            ))
        })
        .unwrap();
    let old = Controller::new(session, None).unwrap();
    change.controller = Some(old.clone());
    assert!(run(change.apply()).is_err());
    assert!(!old.is_retired());
    let (_directory, mut pending) = fixture();
    pending.controller = Some(
        Controller::new(
            SessionStore::pending_with_id(&pending.record.id).unwrap(),
            None,
        )
        .unwrap(),
    );
    let old = pending.controller.as_ref().unwrap().clone();
    assert!(run(pending.apply()).is_err());
    assert!(!old.is_retired());
}
