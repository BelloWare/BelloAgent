use super::*;
use bello_agent_core::{
    Lane, RunState, Submission, project_authority::synthetic::SyntheticAuthorityControl,
};
use gpui::TestAppContext;
use std::time::Duration;

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
    let controller = Controller::new(store, None).unwrap();
    let plan = ProjectChange {
        authority: Arc::new(authority),
        baseline,
        primary,
        extras: vec![extra],
        loaded: vec![LoadedChat { record, controller }],
        unloaded: vec![],
    };
    (dir, plan, control)
}
#[gpui::test]
fn project_change_saves_then_retires_old_arc_and_reopens_same_writer(cx: &mut TestAppContext) {
    let (_dir, plan, control) = fixture();
    let old = plan.loaded[0].controller.clone();
    let id = plan.loaded[0].record.id.clone();
    let outcome = cx
        .background_executor
        .block_test(plan.apply())
        .unwrap_or_else(|e| panic!("{}", e.message));
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
#[gpui::test]
fn project_change_prewrite_failure_restores_admission_without_saving(cx: &mut TestAppContext) {
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
    let error = cx
        .background_executor
        .block_test(plan.apply())
        .err()
        .expect("denied");
    observer.join().unwrap();
    assert!(!error.keep_blocked);
    assert!(!old.is_retired());
    old.reorder(&[]).unwrap();
    assert!(control.snapshot_bytes().unwrap().is_none());
}
#[gpui::test]
fn project_change_unconfirmed_write_never_reopens_old_admission(cx: &mut TestAppContext) {
    let (_dir, plan, control) = fixture();
    let old = plan.loaded[0].controller.clone();
    control
        .fail_next_write(AuthorityError::Unconfirmed)
        .unwrap();
    let error = cx
        .background_executor
        .block_test(plan.apply())
        .err()
        .expect("unconfirmed");
    assert!(error.keep_blocked && error.unconfirmed);
    assert!(
        control.snapshot_bytes().unwrap().is_some(),
        "synthetic write committed despite missing confirmation"
    );
    assert!(old.reorder(&[]).is_err());
    assert!(!old.is_retired());
    old.stop().unwrap();
}
#[gpui::test]
fn project_change_unloaded_queue_rejects_before_write_and_releases_all_guards(
    cx: &mut TestAppContext,
) {
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
    let error = cx
        .background_executor
        .block_test(plan.apply())
        .err()
        .expect("queued");
    assert!(!error.keep_blocked);
    old.reorder(&[]).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert!(control.snapshot_bytes().unwrap().is_none());
    assert!(SessionStore::open(&path).is_ok());
}
#[gpui::test]
fn project_change_partial_guard_acquisition_rolls_back(cx: &mut TestAppContext) {
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
    assert!(cx.background_executor.block_test(plan.apply()).is_err());
    old.reorder(&[]).unwrap();
    assert!(control.snapshot_bytes().unwrap().is_none());
}
#[gpui::test]
fn project_change_idle_failed_unloaded_chat_needs_no_recovery_write(cx: &mut TestAppContext) {
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
    assert!(cx.background_executor.block_test(plan.apply()).is_ok());
    assert_eq!(std::fs::read(&path).unwrap(), before);
}
#[gpui::test]
fn project_change_lost_postsave_confirmation_keeps_old_actors_fenced(cx: &mut TestAppContext) {
    let (_dir, plan, control) = fixture();
    let old = plan.loaded[0].controller.clone();
    let gate = control.pause_next_write().unwrap();
    let observer = std::thread::spawn(move || {
        assert!(gate.wait_until_started(Duration::from_secs(3)));
        control.fail_next_read(AuthorityError::Denied).unwrap();
        gate.release();
    });
    let error = cx
        .background_executor
        .block_test(plan.apply())
        .err()
        .expect("confirmation denied");
    observer.join().unwrap();
    assert!(error.keep_blocked);
    assert!(error.message.contains("were saved"));
    assert!(old.reorder(&[]).is_err());
}

#[gpui::test]
fn project_change_keeps_unloaded_lease_through_save_and_releases_afterward(
    cx: &mut TestAppContext,
) {
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
    assert!(cx.background_executor.block_test(plan.apply()).is_ok());
    observer.join().unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert!(SessionStore::open(&path).is_ok());
}

#[gpui::test]
fn project_change_rolls_back_earlier_inspection_leases_when_later_chat_is_busy(
    cx: &mut TestAppContext,
) {
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
    assert!(cx.background_executor.block_test(plan.apply()).is_err());
    assert!(control.snapshot_bytes().unwrap().is_none());
    assert!(SessionStore::open(&first_path).is_ok());
}

#[gpui::test]
fn project_change_replaces_loaded_pending_chat_without_materializing_it(cx: &mut TestAppContext) {
    let (_dir, mut plan, _) = fixture();
    let controller = Controller::new(SessionStore::pending(), None).unwrap();
    let id = controller.snapshot().id;
    let path = plan.primary.join("never-materialized.json");
    plan.loaded = vec![LoadedChat {
        record: ChatRecord::new(id.clone(), "pending draft".into(), path.clone()),
        controller: controller.clone(),
    }];
    let changed = cx
        .background_executor
        .block_test(plan.apply())
        .unwrap_or_else(|e| panic!("{}", e.message));
    assert!(controller.is_retired());
    assert_eq!(changed.replacements[0].controller.snapshot().id, id);
    assert!(!changed.replacements[0].controller.is_persistent());
    assert!(!path.exists());
}

#[gpui::test]
fn project_change_final_confirmation_rejects_authority_changed_during_restart(
    cx: &mut TestAppContext,
) {
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
    let error = cx
        .background_executor
        .block_test(plan.apply())
        .err()
        .expect("changed authority");
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
