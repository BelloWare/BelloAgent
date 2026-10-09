use super::*;
use bello_agent_core::{SessionStore, inspection::InspectionCoordinator};
fn reserved() -> (
    tempfile::TempDir,
    std::path::PathBuf,
    LoadRetirementOwner,
    InspectionCoordinator,
    Arc<Entry>,
) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let controller = Controller::new(SessionStore::open(&path).unwrap(), None).unwrap();
    let lane = InspectionCoordinator::default();
    let permit = lane.try_background().unwrap().unwrap();
    let owner = LoadRetirementOwner::default();
    let entry = owner.reserve(permit).unwrap();
    assert!(entry.controller.set(controller).is_ok());
    (dir, path, owner, lane, entry)
}
#[test]
fn one_slot_retains_writer_and_permit_until_successful_retirement() {
    let (_dir, path, owner, lane, entry) = reserved();
    let old_token = owner.token().unwrap();
    gpui::TestAppContext::single()
        .background_executor
        .block(async {
            assert!(
                owner
                    .retry_with(|_| async { Err("injected cleanup failure".into()) })
                    .await
                    .is_err()
            );
            assert!(owner.occupied() && owner.failed());
            assert!(old_token.is_cancelled());
            assert!(owner.token().is_err());
            assert!(lane.try_background().unwrap().is_none());
            assert!(SessionStore::open(&path).is_err());
            owner.retry().await.unwrap();
            assert!(!owner.occupied());
            assert!(!owner.token().unwrap().is_cancelled());
            assert!(old_token.is_cancelled());
        });
    drop(entry);
    assert!(lane.try_background().unwrap().is_some());
    assert!(SessionStore::open(&path).is_ok());
}
#[test]
fn cancelled_cleanup_future_keeps_entry_and_allows_later_retry() {
    let (_dir, path, owner, lane, entry) = reserved();
    gpui::TestAppContext::single()
        .background_executor
        .block(async {
            let mut future =
                Box::pin(owner.retry_with(|_| std::future::pending::<Result<(), String>>()));
            // Poll with a no-op waker without an additional async dependency.
            let waker = std::task::Waker::noop();
            let mut cx = std::task::Context::from_waker(waker);
            assert!(future.as_mut().poll(&mut cx).is_pending());
            drop(future);
            assert!(owner.occupied());
            assert!(lane.try_background().unwrap().is_none());
            assert!(SessionStore::open(&path).is_err());
            owner.retry().await.unwrap();
        });
    drop(entry);
    assert!(lane.try_background().unwrap().is_some());
}
#[test]
fn installation_is_exact_operation_and_releases_only_the_matching_slot() {
    let (_dir, _path, owner, lane, entry) = reserved();
    let other_lane = InspectionCoordinator::default();
    let other = Arc::new(Entry {
        operation: Uuid::new_v4(),
        controller: OnceLock::new(),
        _permit: other_lane.try_background().unwrap().unwrap(),
    });
    assert!(owner.install(&other).is_none());
    assert!(owner.occupied());
    let controller = owner.install(&entry).unwrap();
    assert!(!owner.occupied());
    drop(entry);
    assert!(lane.try_background().unwrap().is_some());
    assert!(controller.is_persistent());
}
fn app_fixture(
    cx: &mut gpui::TestAppContext,
) -> (
    tempfile::TempDir,
    gpui::WindowHandle<AgentView>,
    gpui::Entity<AgentView>,
) {
    use bello_agent_core::workspace::{ChatRecord, DraftRecord, WorkspaceStore};
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let store = SessionStore::pending();
    let record = ChatRecord::new(
        store.snapshot().id,
        "Loaded".into(),
        project.join("loaded.json"),
    );
    let launch = crate::LaunchState {
        controller: Controller::new(store, None).unwrap(),
        workspace: Arc::new(Mutex::new(
            WorkspaceStore::open(project.join("workspace.json"), &project).unwrap(),
        )),
        project,
        record,
        draft: DraftRecord::default(),
        pending: true,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let view = window.root(cx).unwrap();
    cx.run_until_parked();
    (dir, window, view)
}
fn add_saved(
    view: &mut AgentView,
    root: &std::path::Path,
) -> bello_agent_core::workspace::ChatRecord {
    use bello_agent_core::workspace::{ChatRecord, DraftRecord};
    let path = root.join(format!("{}.json", Uuid::new_v4()));
    let store = SessionStore::open(&path).unwrap();
    let record = ChatRecord::new(store.snapshot().id, "Saved".into(), path);
    drop(store);
    view.workspace
        .lock()
        .unwrap()
        .register(record.clone(), DraftRecord::default())
        .unwrap();
    view.records.push(record.clone());
    record
}
#[gpui::test]
async fn queued_open_rejection_finishes_same_target_loading(cx: &mut gpui::TestAppContext) {
    let (dir, window, view) = app_fixture(cx);
    let (record, permit) = window
        .update(cx, |view, window, cx| {
            let record = add_saved(view, dir.path());
            let lane = view.workspace.lock().unwrap().inspection_coordinator();
            let permit = lane.try_background().unwrap().unwrap();
            view.select_chat(&record.id, window, cx);
            (record, permit)
        })
        .unwrap();
    cx.run_until_parked();
    assert!(view.read_with(cx, |v, _| v.chat_ref(&record.id).unwrap().loading));
    window
        .update(cx, |view, _, _| view.connections.open = true)
        .unwrap();
    drop(permit);
    cx.condition(&view, |v, _| !v.chat_ref(&record.id).unwrap().loading)
        .await;
    assert!(view.read_with(cx, |v, _| v.chat_ref(&record.id).unwrap().load_failed));
}
#[gpui::test]
async fn rapid_selected_opens_queue_during_normal_reserved_load(cx: &mut gpui::TestAppContext) {
    let (dir, window, view) = app_fixture(cx);
    let gate = InspectionCancellation::new();
    let entered = InspectionCancellation::new();
    let (first, second) = window
        .update(cx, |view, window, cx| {
            let first = add_saved(view, dir.path());
            let second = add_saved(view, dir.path());
            view.load_retirement.0.lock().unwrap().hold_after_open = Some(gate.clone());
            view.load_retirement.0.lock().unwrap().opened_signal = Some(entered.clone());
            view.select_chat(&first.id, window, cx);
            (first, second)
        })
        .unwrap();
    entered.cancelled().await;
    window
        .update(cx, |view, window, cx| {
            view.select_chat(&second.id, window, cx)
        })
        .unwrap();
    cx.run_until_parked();
    assert!(view.read_with(cx, |v, _| v.record.id == second.id && v.loading));
    assert!(view.read_with(cx, |v, _| v.chat_ref(&first.id).unwrap().loading));
    gate.cancel();
    cx.condition(&view, |v, _| {
        v.chat_ref(&first.id).is_some_and(|c| !c.loading)
            && v.chat_ref(&second.id).is_some_and(|c| !c.loading)
    })
    .await;
    assert!(view.read_with(
        cx,
        |v, _| v.chat_ref(&first.id).unwrap().controller.is_persistent()
            && v.chat_ref(&second.id).unwrap().controller.is_persistent()
    ));
}
#[gpui::test]
async fn stale_opened_controller_is_retired_without_install_and_owner_survives_rebind(
    cx: &mut gpui::TestAppContext,
) {
    let (dir, window, view) = app_fixture(cx);
    let gate = InspectionCancellation::new();
    let entered = InspectionCancellation::new();
    let record = window
        .update(cx, |view, window, cx| {
            let record = add_saved(view, dir.path());
            view.load_retirement.0.lock().unwrap().hold_after_open = Some(gate.clone());
            view.load_retirement.0.lock().unwrap().opened_signal = Some(entered.clone());
            view.select_chat(&record.id, window, cx);
            record
        })
        .unwrap();
    entered.cancelled().await;
    let (owner, opened) = view.read_with(cx, |v, _| {
        let owner = v.load_retirement.clone();
        let opened = owner
            .0
            .lock()
            .unwrap()
            .entry
            .as_ref()
            .unwrap()
            .controller
            .get()
            .unwrap()
            .clone();
        (owner, opened)
    });
    window
        .update(cx, |view, window, cx| {
            view.bind_window(window, cx);
            assert!(Arc::ptr_eq(&owner.0, &view.load_retirement.0));
            view.load_cancellation.cancel();
        })
        .unwrap();
    gate.cancel();
    cx.condition(&view, |v, _| !v.load_retirement.occupied())
        .await;
    assert!(opened.is_retired());
    assert!(!opened.is_persistent());
    assert!(SessionStore::open(&record.snapshot).is_ok());
    assert!(!view.read_with(cx, |v, _| Arc::ptr_eq(&v.controller, &opened)));
}
#[gpui::test]
async fn workspace_retry_and_shutdown_are_reachable_with_failed_holder_and_queued_loading(
    cx: &mut gpui::TestAppContext,
) {
    let (dir, window, view) = app_fixture(cx);
    let (owner, entry) = window
        .update(cx, |view, _, _| {
            let lane = view.workspace.lock().unwrap().inspection_coordinator();
            let permit = lane.try_background().unwrap().unwrap();
            let owner = view.load_retirement.clone();
            let entry = owner.reserve(permit).unwrap();
            let controller = Controller::new(
                SessionStore::open(dir.path().join("uninstalled.json")).unwrap(),
                None,
            )
            .unwrap();
            assert!(entry.controller.set(controller).is_ok());
            (owner, entry)
        })
        .unwrap();
    assert!(
        owner
            .retry_with(|controller| async move {
                controller.retire().unwrap();
                Err("injected cleanup failure".into())
            })
            .await
            .is_err()
    );
    drop(entry);
    window
        .update(cx, |view, window, cx| {
            view.loading = true;
            assert!(view.project_actions_blocked());
            assert!(!view.request_close(window, cx));
            assert!(!view.loading);
        })
        .unwrap();
    cx.condition(&view, |v, _| {
        v.close_ready || (!v.shutting_down && v.error.is_some())
    })
    .await;
    assert!(view.read_with(cx, |v, _| v.close_ready));
    assert!(!owner.occupied());
}
#[gpui::test]
async fn workspace_retry_is_independent_of_selected_loading_and_generation(
    cx: &mut gpui::TestAppContext,
) {
    let (dir, window, view) = app_fixture(cx);
    let (owner, entry) = window
        .update(cx, |view, _, _| {
            let lane = view.workspace.lock().unwrap().inspection_coordinator();
            let owner = view.load_retirement.clone();
            let entry = owner
                .reserve(lane.try_background().unwrap().unwrap())
                .unwrap();
            assert!(
                entry
                    .controller
                    .set(
                        Controller::new(
                            SessionStore::open(dir.path().join("failed-load.json")).unwrap(),
                            None
                        )
                        .unwrap()
                    )
                    .is_ok()
            );
            (owner, entry)
        })
        .unwrap();
    assert!(
        owner
            .retry_with(|controller| async move {
                controller.retire().unwrap();
                Err("injected failure".into())
            })
            .await
            .is_err()
    );
    drop(entry);
    window
        .update(cx, |view, _, cx| {
            view.loading = true;
            view.load_generation += 1;
            view.retry_workspace_load_cleanup(cx);
            assert!(!view.loading);
        })
        .unwrap();
    cx.condition(&view, |v, _| !v.load_retirement.occupied())
        .await;
    assert!(!owner.failed());
    assert!(SessionStore::open(dir.path().join("failed-load.json")).is_ok());
}
