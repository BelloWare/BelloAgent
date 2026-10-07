use super::*;
use bello_agent_core::{
    Controller, Lane, SessionStore, Submission,
    project_authority::synthetic::SyntheticAuthorityControl, workspace::DraftRecord,
};
use std::{
    future::Future,
    pin::pin,
    task::{Context, Poll, Wake, Waker},
    time::Duration,
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
    let mut cx = Context::from_waker(&waker);
    let mut future = pin!(future);
    loop {
        match future.as_mut().poll(&mut cx) {
            Poll::Ready(v) => return v,
            Poll::Pending => std::thread::park(),
        }
    }
}
fn fixture() -> (
    tempfile::TempDir,
    McpConfigurationSave,
    SyntheticAuthorityControl,
) {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
    let initial = authority.load().unwrap();
    let mut draft = initial.edit();
    let project = draft
        .trust_project(&uuid::Uuid::new_v4().to_string(), &root, &[])
        .unwrap();
    let saved = authority.save(&mut draft).unwrap();
    let mut workspace = WorkspaceStore::open(root.join("catalog.json"), &root).unwrap();
    workspace
        .bind_project_identity(authority.confirm_project_binding(&saved, &project).unwrap())
        .unwrap();
    let store = SessionStore::open(root.join("session.json")).unwrap();
    let record = ChatRecord::new(
        store.snapshot().id,
        "Saved fixture".into(),
        root.join("session.json"),
    );
    workspace
        .register(record.clone(), DraftRecord::default())
        .unwrap();
    let controller = Controller::new(store, None).unwrap();
    let workspace = Arc::new(Mutex::new(workspace));
    let runtime = crate::saved_runtime_adapter::AppRuntime::new(
        authority.clone(),
        workspace.clone(),
        crate::saved_runtime_adapter::AppRuntime::options(root, true),
        None,
    );
    let manager = runtime.mcp_manager().unwrap();
    let baseline = authority.load_mcp(&project).unwrap();
    let change = McpConfigurationSave {
        authority: Arc::new(authority),
        baseline,
        project,
        manager,
        workspace,
        configuration: r#"{"servers":{"fixture":{"transport":"http","url":"http://127.0.0.1:9"}}}"#
            .into(),
        headers: BTreeMap::new(),
        loaded: vec![LoadedChat { record, controller }],
        unloaded: vec![],
    };
    (dir, change, control)
}
#[test]
fn saves_then_applies_and_releases_same_actor_admission_without_network() {
    let (_dir, change, _) = fixture();
    let old = change.loaded[0].controller.clone();
    let manager = change.manager.clone();
    let saved =
        run(change.apply(CancellationToken::new())).unwrap_or_else(|e| panic!("{}", e.message));
    assert!(
        saved
            .configuration_json_without_headers()
            .contains("fixture")
    );
    assert!(!manager.status().busy);
    assert!(!old.is_retired());
    old.reorder(&[]).unwrap();
}
#[test]
fn denial_preserves_vault_bytes_and_releases_every_idle_guard() {
    let (_dir, change, control) = fixture();
    let bytes = control.snapshot_bytes().unwrap();
    let old = change.loaded[0].controller.clone();
    control.fail_next_write(AuthorityError::Denied).unwrap();
    let failure = run(change.apply(CancellationToken::new())).err().unwrap();
    assert!(!failure.keep_blocked);
    assert_eq!(control.snapshot_bytes().unwrap(), bytes);
    old.reorder(&[]).unwrap();
}
#[test]
fn uncertain_save_keeps_old_actor_fenced_and_preserves_durable_change() {
    let (_dir, change, control) = fixture();
    let bytes = control.snapshot_bytes().unwrap();
    let old = change.loaded[0].controller.clone();
    control
        .fail_next_write(AuthorityError::Unconfirmed)
        .unwrap();
    let failure = run(change.apply(CancellationToken::new())).err().unwrap();
    assert!(failure.keep_blocked && failure.unconfirmed);
    assert_ne!(control.snapshot_bytes().unwrap(), bytes);
    assert!(old.reorder(&[]).is_err());
    old.stop().unwrap();
}
#[test]
fn actor_and_manager_are_reserved_before_vault_compare_and_swap() {
    let (_dir, change, control) = fixture();
    let gate = control.pause_next_write().unwrap();
    let old = change.loaded[0].controller.clone();
    let manager = change.manager.clone();
    let check = old.clone();
    let observer = std::thread::spawn(move || {
        assert!(gate.wait_until_started(Duration::from_secs(3)));
        assert!(check.reorder(&[]).is_err());
        assert!(manager.begin_configuration_change().is_err());
        gate.release();
    });
    run(change.apply(CancellationToken::new())).unwrap_or_else(|e| panic!("{}", e.message));
    observer.join().unwrap();
    old.reorder(&[]).unwrap();
}
#[test]
fn cancellation_after_save_cannot_reopen_the_previous_actor() {
    let (_dir, change, control) = fixture();
    let before = control.snapshot_bytes().unwrap();
    let gate = control.pause_next_write().unwrap();
    let token = CancellationToken::new();
    let cancel = token.clone();
    let old = change.loaded[0].controller.clone();
    let observer = std::thread::spawn(move || {
        assert!(gate.wait_until_started(Duration::from_secs(3)));
        cancel.cancel();
        gate.release();
    });
    let failure = run(change.apply(token)).err().unwrap();
    observer.join().unwrap();
    assert!(failure.keep_blocked);
    assert_ne!(control.snapshot_bytes().unwrap(), before);
    assert!(old.reorder(&[]).is_err());
}
#[test]
fn cancellation_before_save_releases_reservations_without_writing() {
    let (_dir, change, control) = fixture();
    let bytes = control.snapshot_bytes().unwrap();
    let old = change.loaded[0].controller.clone();
    let token = CancellationToken::new();
    token.cancel();
    let failure = run(change.apply(token)).err().unwrap();
    assert!(!failure.keep_blocked);
    assert_eq!(control.snapshot_bytes().unwrap(), bytes);
    old.reorder(&[]).unwrap();
}
#[test]
fn unresolved_unloaded_queue_rejects_before_write_and_preserves_checkpoint() {
    let (_dir, mut change, control) = fixture();
    let before = control.snapshot_bytes().unwrap();
    let old = change.loaded[0].controller.clone();
    let path = change.project.path.join("queued.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|s| s.submit(Submission::new("queued input".into(), Lane::FollowUp)))
        .unwrap();
    let record = ChatRecord::new(store.snapshot().id, "Queued".into(), path.clone());
    drop(store);
    let checkpoint = std::fs::read(&path).unwrap();
    change
        .workspace
        .lock()
        .unwrap()
        .register(record.clone(), DraftRecord::default())
        .unwrap();
    change.unloaded.push(record);
    assert!(
        !run(change.apply(CancellationToken::new()))
            .err()
            .unwrap()
            .keep_blocked
    );
    assert_eq!(control.snapshot_bytes().unwrap(), before);
    assert_eq!(std::fs::read(path).unwrap(), checkpoint);
    old.reorder(&[]).unwrap();
}
#[test]
fn a_new_catalog_chat_cannot_be_omitted_from_the_project_idle_fence() {
    let (_dir, change, control) = fixture();
    let bytes = control.snapshot_bytes().unwrap();
    let path = change.project.path.join("new.json");
    let store = SessionStore::open(&path).unwrap();
    let record = ChatRecord::new(store.snapshot().id, "New".into(), path);
    drop(store);
    change
        .workspace
        .lock()
        .unwrap()
        .register(record, DraftRecord::default())
        .unwrap();
    assert!(
        !run(change.apply(CancellationToken::new()))
            .err()
            .unwrap()
            .keep_blocked
    );
    assert_eq!(control.snapshot_bytes().unwrap(), bytes);
}
#[test]
fn foreign_project_baseline_cannot_write_even_when_paths_match() {
    let (_dir, mut change, control) = fixture();
    let bytes = control.snapshot_bytes().unwrap();
    change.project.id = uuid::Uuid::new_v4().to_string();
    assert!(run(change.apply(CancellationToken::new())).is_err());
    assert_eq!(control.snapshot_bytes().unwrap(), bytes);
}
#[test]
fn postwrite_guard_drop_is_fail_closed_even_if_future_is_abandoned() {
    let (_dir, change, _) = fixture();
    let controller = change.loaded[0].controller.clone();
    let guards = vec![controller.suspend_idle_admission().unwrap()];
    drop(AdmissionSet {
        guards,
        saved: true,
        applied: false,
    });
    assert!(controller.reorder(&[]).is_err());
}
