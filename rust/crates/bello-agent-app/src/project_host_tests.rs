use super::*;
use bello_agent_core::{
    Lane, RunState, SessionStore, Submission,
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
    let mut context = Context::from_waker(&waker);
    let mut future = pin!(future);
    loop {
        match future.as_mut().poll(&mut context) {
            Poll::Ready(result) => return result,
            Poll::Pending => std::thread::park(),
        }
    }
}

fn fixture() -> (tempfile::TempDir, ProjectChange, SyntheticAuthorityControl) {
    let dir = tempfile::tempdir().unwrap();
    let primary = std::fs::canonicalize(dir.path()).unwrap();
    let extra = primary.join("extra");
    std::fs::create_dir(&extra).unwrap();
    let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
    let baseline = authority.load().unwrap();
    let path = primary.join("a.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|s| {
            s.title = "preserved history".into();
            Ok(())
        })
        .unwrap();
    let record = ChatRecord::new(store.snapshot().id, "saved".into(), path);
    let mut workspace = WorkspaceStore::open(primary.join("catalog.json"), &primary).unwrap();
    workspace
        .register(record.clone(), DraftRecord::default())
        .unwrap();
    let controller = Controller::new(store, None).unwrap();
    let workspace = Arc::new(Mutex::new(workspace));
    let runtime = crate::saved_runtime_adapter::AppRuntime::new(
        authority.clone(),
        workspace.clone(),
        crate::saved_runtime_adapter::AppRuntime::options(primary.clone(), false),
        None,
    );
    let plan = ProjectChange {
        runtime,
        authority: Arc::new(authority),
        workspace,
        baseline,
        primary,
        extras: vec![extra],
        loaded: vec![LoadedChat { record, controller }],
        unloaded: vec![],
    };
    (dir, plan, control)
}
#[test]
fn project_change_saves_then_retires_old_arc_and_reopens_same_writer() {
    let (_dir, plan, control) = fixture();
    let old = plan.loaded[0].controller.clone();
    let id = plan.loaded[0].record.id.clone();
    let outcome = run(plan.apply()).unwrap_or_else(|e| panic!("{}", e.message));
    assert_eq!(outcome.replacements[0].id, id);
    assert!(old.is_retired());
    assert!(old.reorder(&[]).is_err());
    let current = &outcome.replacements[0].controller;
    assert_eq!(current.snapshot().title, "preserved history");
    assert!(current.is_persistent());
    current.reorder(&[]).unwrap();
    assert_eq!(outcome.project.paths.len(), 1);
    assert_eq!(outcome.loaded.revision(), 1);
    assert!(control.snapshot_bytes().unwrap().is_some());
}
#[test]
fn project_change_prewrite_failure_restores_admission_without_saving() {
    let (_dir, plan, control) = fixture();
    let old = plan.loaded[0].controller.clone();
    control.fail_next_write(AuthorityError::Denied).unwrap();
    let gate = control.pause_next_write().unwrap();
    let check = old.clone();
    let observer = std::thread::spawn(move || {
        assert!(gate.wait_until_started(Duration::from_secs(3)));
        assert!(
            check.reorder(&[]).is_err(),
            "direct old Arc must be fenced before save"
        );
        gate.release();
    });
    let error = run(plan.apply()).err().expect("denied");
    observer.join().unwrap();
    assert!(!error.keep_blocked);
    assert!(!old.is_retired());
    old.reorder(&[]).unwrap();
    assert!(control.snapshot_bytes().unwrap().is_none());
}
#[test]
fn project_change_unconfirmed_write_never_reopens_old_admission() {
    let (_dir, plan, control) = fixture();
    let old = plan.loaded[0].controller.clone();
    control
        .fail_next_write(AuthorityError::Unconfirmed)
        .unwrap();
    let error = run(plan.apply()).err().expect("unconfirmed");
    assert!(error.keep_blocked && error.unconfirmed);
    assert!(
        control.snapshot_bytes().unwrap().is_some(),
        "synthetic write committed despite missing confirmation"
    );
    assert!(old.reorder(&[]).is_err());
    assert!(!old.is_retired());
    old.stop().unwrap();
}
#[test]
fn project_change_unloaded_queue_rejects_before_write_and_releases_all_guards() {
    let (_dir, mut plan, control) = fixture();
    let old = plan.loaded[0].controller.clone();
    let path = plan.primary.join("z.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|s| s.submit(Submission::new("queued retained".into(), Lane::FollowUp)))
        .unwrap();
    let record = ChatRecord::new(store.snapshot().id, "inactive queued".into(), path.clone());
    drop(store);
    let before = std::fs::read(&path).unwrap();
    plan.unloaded.push(record);
    let error = run(plan.apply()).err().expect("queued");
    assert!(!error.keep_blocked);
    old.reorder(&[]).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert!(control.snapshot_bytes().unwrap().is_none());
    assert!(SessionStore::open(&path).is_ok());
}
#[test]
fn project_change_partial_guard_acquisition_rolls_back() {
    let (_dir, mut plan, control) = fixture();
    let old = plan.loaded[0].controller.clone();
    let path = plan.primary.join("z.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|s| s.submit(Submission::new("queued".into(), Lane::FollowUp)))
        .unwrap();
    let record = ChatRecord::new(store.snapshot().id, "other".into(), path);
    plan.loaded.push(LoadedChat {
        record,
        controller: Controller::new(store, None).unwrap(),
    });
    assert!(run(plan.apply()).is_err());
    old.reorder(&[]).unwrap();
    assert!(control.snapshot_bytes().unwrap().is_none());
}
#[test]
fn project_change_idle_failed_unloaded_chat_needs_no_recovery_write() {
    let (_dir, mut plan, _) = fixture();
    let path = plan.primary.join("z.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|s| {
            s.state = RunState::Error;
            s.error = Some("ordinary failure".into());
            s.queue_paused = true;
            Ok(())
        })
        .unwrap();
    plan.unloaded.push(ChatRecord::new(
        store.snapshot().id,
        "failed idle".into(),
        path.clone(),
    ));
    drop(store);
    let before = std::fs::read(&path).unwrap();
    assert!(run(plan.apply()).is_ok());
    assert_eq!(std::fs::read(&path).unwrap(), before);
}
#[test]
fn project_change_lost_postsave_confirmation_keeps_old_actors_fenced() {
    let (_dir, plan, control) = fixture();
    let old = plan.loaded[0].controller.clone();
    let gate = control.pause_next_write().unwrap();
    let observer = std::thread::spawn(move || {
        assert!(gate.wait_until_started(Duration::from_secs(3)));
        control.fail_next_read(AuthorityError::Denied).unwrap();
        gate.release();
    });
    let error = run(plan.apply()).err().expect("confirmation denied");
    observer.join().unwrap();
    assert!(error.keep_blocked);
    assert!(error.message.contains("were saved"));
    assert!(old.reorder(&[]).is_err());
}

#[test]
fn project_change_keeps_unloaded_lease_through_save_and_releases_afterward() {
    let (_dir, mut plan, control) = fixture();
    let path = plan.primary.join("z.json");
    let store = SessionStore::open(&path).unwrap();
    plan.unloaded.push(ChatRecord::new(
        store.snapshot().id,
        "idle unloaded".into(),
        path.clone(),
    ));
    drop(store);
    let before = std::fs::read(&path).unwrap();
    let gate = control.pause_next_write().unwrap();
    let observed = path.clone();
    let observer = std::thread::spawn(move || {
        assert!(gate.wait_until_started(Duration::from_secs(3)));
        assert!(
            SessionStore::open(&observed).is_err(),
            "unloaded writer must stay leased through save"
        );
        gate.release();
    });
    assert!(run(plan.apply()).is_ok());
    observer.join().unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert!(SessionStore::open(&path).is_ok());
}

#[test]
fn project_change_rolls_back_earlier_inspection_leases_when_later_chat_is_busy() {
    let (_dir, mut plan, control) = fixture();
    let first_path = plan.primary.join("y.json");
    let first = SessionStore::open(&first_path).unwrap();
    plan.unloaded.push(ChatRecord::new(
        first.snapshot().id,
        "first idle".into(),
        first_path.clone(),
    ));
    drop(first);
    let last_path = plan.primary.join("z.json");
    let mut last = SessionStore::open(&last_path).unwrap();
    last.transact(|s| s.submit(Submission::new("pending".into(), Lane::FollowUp)))
        .unwrap();
    plan.unloaded.push(ChatRecord::new(
        last.snapshot().id,
        "last queued".into(),
        last_path,
    ));
    drop(last);
    assert!(run(plan.apply()).is_err());
    assert!(control.snapshot_bytes().unwrap().is_none());
    assert!(SessionStore::open(&first_path).is_ok());
}

#[test]
fn project_change_replaces_loaded_pending_chat_without_materializing_it() {
    let (_dir, mut plan, _) = fixture();
    let controller = Controller::new(SessionStore::pending(), None).unwrap();
    let id = controller.snapshot().id;
    let path = plan.primary.join("never-materialized.json");
    let mut record = ChatRecord::new(id.clone(), "pending draft".into(), path.clone());
    record.materialization = ChatMaterialization::Pending;
    plan.loaded = vec![LoadedChat {
        record,
        controller: controller.clone(),
    }];
    let changed = run(plan.apply()).unwrap_or_else(|e| panic!("{}", e.message));
    assert!(controller.is_retired());
    assert_eq!(changed.replacements[0].controller.snapshot().id, id);
    assert!(!changed.replacements[0].controller.is_persistent());
    assert!(!path.exists());
}

#[test]
fn project_change_final_confirmation_rejects_authority_changed_during_restart() {
    let (_dir, plan, control) = fixture();
    let old = plan.loaded[0].controller.clone();
    let path = plan.loaded[0].record.snapshot.clone();
    let write_gate = control.pause_next_write().unwrap();
    let observer = std::thread::spawn(move || {
        assert!(write_gate.wait_until_started(Duration::from_secs(3)));
        let read_gate = control.pause_next_read().unwrap();
        write_gate.release();
        assert!(read_gate.wait_until_started(Duration::from_secs(3)));
        let mut value: serde_json::Value =
            serde_json::from_slice(&control.snapshot_bytes().unwrap().unwrap()).unwrap();
        value["revision"] = serde_json::json!(900);
        control
            .replace_bytes(Some(serde_json::to_vec(&value).unwrap()))
            .unwrap();
        read_gate.release();
    });
    let error = run(plan.apply()).err().expect("changed authority");
    observer.join().unwrap();
    assert!(error.keep_blocked);
    assert!(error.message.contains("during runtime restart"));
    assert!(old.is_retired());
    assert!(old.reorder(&[]).is_err());
    assert!(
        SessionStore::open(&path).is_ok(),
        "uninstalled replacements must release their locks"
    );
}

#[test]
fn project_change_binds_once_and_restart_resolves_exact_id() {
    let (directory, plan, _) = fixture();
    let old = plan.loaded[0].controller.clone();
    let outcome = run(plan.apply()).unwrap_or_else(|error| panic!("{}", error.message));
    assert!(old.is_retired());
    let workspace =
        WorkspaceStore::open(directory.path().join("catalog.json"), directory.path()).unwrap();
    let snapshot = workspace.snapshot();
    assert_eq!(
        snapshot.project_id.as_deref(),
        Some(outcome.project.id.as_str())
    );
    assert_eq!(
        resolve_saved_project(
            &outcome.loaded,
            &snapshot.project,
            snapshot.project_id.as_deref()
        )
        .unwrap(),
        Some(&outcome.project)
    );
}

#[test]
fn catalog_binding_failure_after_authority_save_keeps_admission_blocked() {
    let (_directory, plan, control) = fixture();
    let old = plan.loaded[0].controller.clone();
    let workspace = plan.workspace.clone();
    let path = plan.primary.join("catalog.json");
    std::fs::remove_file(&path).unwrap();
    std::fs::create_dir(&path).unwrap();
    let failure = run(plan.apply()).err().unwrap();
    assert!(failure.keep_blocked);
    assert!(control.snapshot_bytes().unwrap().is_some());
    assert!(workspace.lock().unwrap().snapshot().project_id.is_none());
    assert!(old.reorder(&[]).is_err());
    assert!(
        !old.is_retired(),
        "catalog bind follows authority save and precedes retirement"
    );
}

#[test]
fn authority_write_never_holds_catalog_mutex_and_binding_keeps_concurrent_draft() {
    let (_directory, plan, control) = fixture();
    let workspace = plan.workspace.clone();
    let id = plan.loaded[0].record.id.clone();
    let gate = control.pause_next_write().unwrap();
    let observer = std::thread::spawn(move || {
        assert!(gate.wait_until_started(Duration::from_secs(3)));
        workspace
            .try_lock()
            .expect("no authority I/O while holding catalog mutex")
            .save_draft(
                &id,
                DraftRecord {
                    attachments: Vec::new(),
                    text: "concurrent draft".into(),
                    revision: 4,
                    ..Default::default()
                },
            )
            .unwrap();
        gate.release();
    });
    let workspace = plan.workspace.clone();
    let id = plan.loaded[0].record.id.clone();
    assert!(run(plan.apply()).is_ok());
    observer.join().unwrap();
    assert_eq!(
        workspace.lock().unwrap().snapshot().drafts[&id].text,
        "concurrent draft"
    );
}

#[test]
fn bound_identity_mismatch_rejects_before_authority_mutation() {
    let (_directory, plan, control) = fixture();
    let (bound_authority, _) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
    let mut draft = bound_authority.load().unwrap().edit();
    let saved = draft
        .trust_project(&uuid::Uuid::new_v4().to_string(), &plan.primary, &[])
        .unwrap();
    let loaded = bound_authority.save(&mut draft).unwrap();
    let binding = bound_authority
        .confirm_project_binding(&loaded, &saved)
        .unwrap();
    plan.workspace
        .lock()
        .unwrap()
        .bind_project_identity(binding)
        .unwrap();
    let old = plan.loaded[0].controller.clone();
    let failure = run(plan.apply()).err().unwrap();
    assert!(!failure.keep_blocked);
    assert!(control.snapshot_bytes().unwrap().is_none());
    old.reorder(&[]).unwrap();
}

#[test]
fn saved_project_resolution_rejects_unbound_ambiguity_and_bound_missing_or_moved_id() {
    let directory = tempfile::tempdir().unwrap();
    let primary = std::fs::canonicalize(directory.path()).unwrap();
    let first = uuid::Uuid::new_v4().to_string();
    let second = uuid::Uuid::new_v4().to_string();
    let bytes = serde_json::to_vec(&serde_json::json!({
        "schema": 1, "revision": 1,
        "workspaces": [
            { "id": first, "path": primary, "trusted": true },
            { "id": second, "path": primary, "trusted": true }
        ]
    }))
    .unwrap();
    let (authority, _) = ProjectAuthority::with_synthetic_bytes(Some(bytes)).unwrap();
    let loaded = authority.load().unwrap();
    assert_eq!(
        resolve_saved_project(&loaded, &primary, None),
        Err(AuthorityError::Conflict)
    );
    assert_eq!(
        resolve_saved_project(&loaded, &primary, Some(&second))
            .unwrap()
            .unwrap()
            .id,
        second
    );
    assert_eq!(
        resolve_saved_project(&loaded, &primary, Some(&uuid::Uuid::new_v4().to_string())),
        Err(AuthorityError::Conflict)
    );
    assert_eq!(
        resolve_saved_project(&loaded, &primary.join("moved"), Some(&second)),
        Err(AuthorityError::Conflict)
    );
}

#[test]
fn catalog_uncertainty_remains_fenced_before_authority_and_after_refused_binding() {
    let (_directory, plan, _) = fixture();
    let snapshot = plan.workspace.lock().unwrap().snapshot();
    let failure = validate_catalog_identity(&plan.primary, &snapshot, true)
        .err()
        .unwrap();
    assert!(failure.keep_blocked && failure.unconfirmed);
    let root_failure = validate_catalog_identity(&plan.primary.join("different"), &snapshot, false)
        .err()
        .unwrap();
    assert!(!root_failure.keep_blocked && !root_failure.unconfirmed);
    // ensure_certain refuses a subsequent bind with Invalid; that variant does
    // not erase the catalog writer's already-observed uncertainty.
    let failure = ProjectChangeFailure::catalog_binding(
        bello_agent_core::Error::Invalid("Workspace persistence is uncertain".into()),
        true,
    );
    assert!(failure.keep_blocked && failure.unconfirmed);
    let confirmed_failure = ProjectChangeFailure::catalog_binding(
        std::io::Error::other("known pre-rename failure").into(),
        false,
    );
    assert!(confirmed_failure.keep_blocked && !confirmed_failure.unconfirmed);
}
