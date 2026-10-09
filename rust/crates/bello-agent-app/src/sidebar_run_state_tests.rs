use super::{Observation, SavedRunState, Scope, Target, inspect, inspect_then};
use crate::{AgentView, LaunchState};
use bello_agent_core::{
    Controller, Delta, Lane, RunState, Session, SessionStore, Submission,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
use gpui::{Entity, TestAppContext, WindowHandle};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use uuid::Uuid;

fn saved(directory: &Path) -> (ChatRecord, SessionStore) {
    let path = directory.join(format!("{}.json", Uuid::new_v4()));
    let store = SessionStore::open(&path).unwrap();
    let record = ChatRecord::new(store.snapshot().id, "Saved".into(), path);
    (record, store)
}
fn files(directory: &Path) -> BTreeMap<PathBuf, (Vec<u8>, super::FileIdentity)> {
    fs::read_dir(directory)
        .unwrap()
        .map(|entry| {
            let path = entry.unwrap().path();
            let bytes = fs::read(&path).unwrap();
            let identity = super::FileIdentity::read(&path).unwrap();
            (path, (bytes, identity))
        })
        .collect()
}
fn active(store: &mut SessionStore) {
    store
        .transact(|session| {
            session.submit(Submission::new("Do not replay me".into(), Lane::FollowUp))?;
            session.start_next()?;
            Ok(())
        })
        .unwrap();
}

#[test]
fn swift_hold_projection_keeps_stopped_empty_and_pending_work_paused() {
    let mut session = Session::new();
    assert_eq!(SavedRunState::from_session(&session), SavedRunState::Ready);
    session.queue_paused = true;
    assert_eq!(SavedRunState::from_session(&session), SavedRunState::Paused);
    session.queue_paused = false;
    session.state = RunState::Paused;
    assert_eq!(SavedRunState::from_session(&session), SavedRunState::Paused);
    session.state = RunState::Idle;
    session
        .submit(Submission::new("queued".into(), Lane::FollowUp))
        .unwrap();
    assert_eq!(SavedRunState::from_session(&session), SavedRunState::Paused);
    let turn = session.pending[0].id.clone();
    session.begin_edit(&turn, "held").unwrap();
    assert_eq!(SavedRunState::from_session(&session), SavedRunState::Paused);
    session.state = RunState::Error;
    assert_eq!(SavedRunState::from_session(&session), SavedRunState::Failed);
}

#[test]
fn active_checkpoint_and_journal_are_observed_without_recovery_replay_or_writes() {
    let directory = tempfile::tempdir().unwrap();
    let (record, mut store) = saved(directory.path());
    active(&mut store);
    let reply = store.snapshot().active_reply.unwrap();
    store
        .append_delta(&reply, Delta::Text("partial preserved".into()))
        .unwrap();
    let persisted = store.snapshot();
    drop(store);
    let before = files(directory.path());
    assert_eq!(inspect(&record), SavedRunState::Interrupted);
    assert_eq!(files(directory.path()), before);
    // The writer is released; inspection did not convert active into paused,
    // write an interruption receipt, rotate the journal, or clear pending work.
    let lease =
        bello_agent_core::session::SessionInspectionLease::acquire(&record.snapshot, &record.id)
            .unwrap();
    assert_eq!(lease.snapshot().state, RunState::Running);
    assert_eq!(
        lease.snapshot().active.as_ref().unwrap().id,
        persisted.active.as_ref().unwrap().id
    );
    assert_eq!(
        lease.snapshot().messages.last().unwrap().text,
        "partial preserved"
    );
    assert_eq!(files(directory.path()), before);
}

#[test]
fn held_writer_missing_checkpoint_and_foreign_identity_never_claim_ready() {
    let directory = tempfile::tempdir().unwrap();
    let (record, store) = saved(directory.path());
    let before = files(directory.path());
    assert_eq!(inspect(&record), SavedRunState::Unknown);
    assert_eq!(files(directory.path()), before);
    drop(store);
    assert_eq!(inspect(&record), SavedRunState::Ready);
    let mut wrong = record.clone();
    wrong.id = Uuid::new_v4().to_string();
    assert_eq!(inspect(&wrong), SavedRunState::Unknown);
    fs::remove_file(&record.snapshot).unwrap();
    let before = files(directory.path());
    assert_eq!(inspect(&record), SavedRunState::Unknown);
    assert_eq!(files(directory.path()), before);
}

#[test]
fn incomplete_or_damaged_journal_is_unknown_and_byte_preserved() {
    let directory = tempfile::tempdir().unwrap();
    let (record, mut store) = saved(directory.path());
    active(&mut store);
    let generation = store.snapshot().stream_generation;
    drop(store);
    let journal = record.snapshot.with_file_name(format!(
        "{}.{}.stream.jsonl",
        record.snapshot.file_name().unwrap().to_str().unwrap(),
        generation
    ));
    for bytes in [
        b"{\"version\":1".as_slice(),
        b"{\"wrong\":true}\n".as_slice(),
    ] {
        fs::write(&journal, bytes).unwrap();
        let before = files(directory.path());
        assert_eq!(inspect(&record), SavedRunState::Unknown);
        assert_eq!(files(directory.path()), before);
    }
}

#[test]
fn same_length_checkpoint_replacement_after_inspection_is_unknown() {
    let directory = tempfile::tempdir().unwrap();
    let (record, store) = saved(directory.path());
    drop(store);
    let bytes = fs::read(&record.snapshot).unwrap();
    let replacement = directory.path().join("replacement.json");
    fs::write(&replacement, &bytes).unwrap();
    // Match length, content and mtime: inode identity must still reject this.
    let original_time = fs::metadata(&record.snapshot).unwrap().modified().unwrap();
    fs::File::options()
        .write(true)
        .open(&replacement)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(original_time))
        .unwrap();
    assert_eq!(
        inspect_then(&record, || fs::rename(&replacement, &record.snapshot)
            .unwrap()),
        SavedRunState::Unknown
    );
    assert_eq!(fs::read(&record.snapshot).unwrap(), bytes);
    assert_eq!(inspect(&record), SavedRunState::Ready);
}

#[test]
fn paused_failed_and_legacy_idle_states_are_inspected_without_migration() {
    let directory = tempfile::tempdir().unwrap();
    let (record, store) = saved(directory.path());
    let mut session = store.snapshot();
    drop(store);
    for (state, paused, expected) in [
        (RunState::Idle, true, SavedRunState::Paused),
        (RunState::Paused, false, SavedRunState::Paused),
        (RunState::Error, true, SavedRunState::Failed),
        (RunState::Idle, false, SavedRunState::Ready),
    ] {
        session.version = 1;
        session.tool_timing = None;
        session.stream_generation.clear();
        session.state = state;
        session.queue_paused = paused;
        fs::write(&record.snapshot, serde_json::to_vec(&session).unwrap()).unwrap();
        let before = files(directory.path());
        assert_eq!(inspect(&record), expected);
        assert_eq!(files(directory.path()), before);
    }
}

fn fixture(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let directory = tempfile::tempdir().unwrap();
    let project = fs::canonicalize(directory.path()).unwrap();
    let store = SessionStore::pending();
    let record = ChatRecord::new(
        store.snapshot().id,
        "Loaded".into(),
        project.join("loaded.json"),
    );
    let launch = LaunchState {
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
    (directory, window, view)
}
fn arm(view: &mut AgentView, record: ChatRecord) -> Target {
    view.sidebar_run_states.scope = Some(Scope::capture(view));
    view.sidebar_run_states.epoch = Uuid::new_v4();
    let target = Target {
        request: Uuid::new_v4(),
        epoch: view.sidebar_run_states.epoch,
        record,
    };
    view.sidebar_run_states.in_flight = Some(target.request);
    target
}

#[gpui::test]
async fn unloaded_rows_restore_sequentially_without_loading_controllers(cx: &mut TestAppContext) {
    let (directory, window, view) = fixture(cx);
    let (record, mut store) = saved(directory.path());
    active(&mut store);
    drop(store);
    let (busy, _writer) = saved(directory.path());
    let before = files(directory.path());
    window
        .update(cx, |view, _, cx| {
            view.records.extend([record.clone(), busy.clone()]);
            assert_eq!(view.sidebar_run_status(&record), "Unavailable");
            view.refresh_sidebar_run_states(cx);
            let request = view.sidebar_run_states.in_flight;
            assert!(request.is_some());
            view.refresh_sidebar_run_states(cx);
            assert_eq!(view.sidebar_run_states.in_flight, request);
        })
        .unwrap();
    cx.condition(&view, |view, _| {
        view.sidebar_run_states.observations.len() == 2
    })
    .await;
    window
        .update(cx, |view, _, cx| {
            assert_eq!(view.sidebar_run_status(&record), "Interrupted");
            assert_eq!(view.sidebar_run_status(&busy), "Unavailable");
            assert!(view.inactive.is_empty());
            assert!(view.chat_ref(&record.id).is_none());
            assert!(view.sidebar_run_states.in_flight.is_none());
            view.refresh_sidebar_run_states(cx);
            assert!(
                view.sidebar_run_states.in_flight.is_none(),
                "unknown is not retried on every redraw"
            );
        })
        .unwrap();
    assert_eq!(files(directory.path()), before);
}

#[gpui::test]
fn stale_completions_cannot_publish_across_identity_or_lifecycle_changes(cx: &mut TestAppContext) {
    for change in 0..12 {
        let (directory, window, _) = fixture(cx);
        let (record, store) = saved(directory.path());
        drop(store);
        window
            .update(cx, |view, window, _| {
                view.records.push(record.clone());
                let target = arm(view, record.clone());
                match change {
                    0 => view.navigation_generation += 1,
                    1 => view.load_generation += 1,
                    2 => view.project = directory.path().join("different-project"),
                    3 => {
                        view.records.last_mut().unwrap().snapshot =
                            directory.path().join("different.json")
                    }
                    4 => {
                        view.window_binding = Some(crate::workspace_lifetime::WindowBinding::new(
                            window.window_handle().window_id(),
                        ))
                    }
                    5 => view.shutting_down = true,
                    6 => view.known_catalog_uncertainty = true,
                    7 => view.sidebar_run_states.epoch = Uuid::new_v4(),
                    8 => {
                        view.records.pop();
                    }
                    9 => view.close_ready = true,
                    10 => {
                        view.workspace = Arc::new(Mutex::new(
                            WorkspaceStore::open(
                                directory.path().join("replacement-workspace.json"),
                                directory.path(),
                            )
                            .unwrap(),
                        ));
                    }
                    11 => {
                        view.records.last_mut().unwrap().materialization =
                            bello_agent_core::workspace::ChatMaterialization::Pending
                    }
                    _ => unreachable!(),
                }
                view.finish_sidebar_run_state(target, SavedRunState::Ready);
                assert!(
                    view.sidebar_run_states.observations.is_empty(),
                    "change {change}"
                );
                assert_eq!(
                    view.sidebar_run_status(&record),
                    "Unavailable",
                    "change {change}"
                );
            })
            .unwrap();
    }
}

#[gpui::test]
fn loaded_controller_always_wins_over_saved_ready_and_stale_completion(cx: &mut TestAppContext) {
    let (_directory, window, _) = fixture(cx);
    window
        .update(cx, |view, _, _| {
            let record = view.record.clone();
            let target = arm(view, record.clone());
            view.finish_sidebar_run_state(target, SavedRunState::Ready);
            assert!(view.sidebar_run_states.observations.is_empty());
            view.sidebar_run_states.observations.insert(
                record.id.clone(),
                Observation {
                    record: record.clone(),
                    state: SavedRunState::Ready,
                },
            );
            let mut snapshot = (*view.session).clone();
            snapshot.state = RunState::Error;
            snapshot.error = Some("Persistence outcome is uncertain".into());
            view.session = Arc::new(snapshot);
            assert_eq!(view.sidebar_run_status(&record), "Failed");
            view.loading = true;
            assert_eq!(view.sidebar_run_status(&record), "Preparing…");
            view.loading = false;
            view.load_failed = true;
            assert_eq!(view.sidebar_run_status(&record), "Unavailable");
        })
        .unwrap();
}

#[gpui::test]
async fn navigation_retries_unknown_storage_without_opening_its_controller(
    cx: &mut TestAppContext,
) {
    let (directory, window, view) = fixture(cx);
    let (record, writer) = saved(directory.path());
    window
        .update(cx, |view, _, cx| {
            view.records.push(record.clone());
            view.refresh_sidebar_run_states(cx);
        })
        .unwrap();
    cx.condition(&view, |view, _| {
        view.sidebar_run_states.observations.len() == 1
    })
    .await;
    window
        .update(cx, |view, _, _| {
            assert_eq!(view.sidebar_run_status(&record), "Unavailable");
        })
        .unwrap();
    drop(writer);
    let before = files(directory.path());
    window
        .update(cx, |view, window, cx| {
            let selected = view.record.id.clone();
            view.select_chat(&selected, window, cx);
            assert_eq!(view.sidebar_run_status(&record), "Unavailable");
            view.refresh_sidebar_run_states(cx);
        })
        .unwrap();
    cx.condition(&view, |view, _| {
        view.sidebar_run_states.observations.len() == 1
    })
    .await;
    window
        .update(cx, |view, _, _| {
            assert_eq!(view.sidebar_run_status(&record), "Ready");
            assert!(view.chat_ref(&record.id).is_none());
            assert!(view.inactive.is_empty());
        })
        .unwrap();
    assert_eq!(files(directory.path()), before);
}

#[gpui::test]
fn older_request_cannot_clear_new_in_flight_or_overwrite_newer_observation(
    cx: &mut TestAppContext,
) {
    let (directory, window, _) = fixture(cx);
    let (record, store) = saved(directory.path());
    drop(store);
    window
        .update(cx, |view, _, _| {
            view.records.push(record.clone());
            let old = arm(view, record.clone());
            let new = arm(view, record.clone());
            let request = new.request;
            view.finish_sidebar_run_state(old, SavedRunState::Ready);
            assert_eq!(view.sidebar_run_states.in_flight, Some(request));
            assert!(view.sidebar_run_states.observations.is_empty());
            view.finish_sidebar_run_state(new, SavedRunState::Paused);
            assert_eq!(view.sidebar_run_status(&record), "Paused");
        })
        .unwrap();
}

#[gpui::test]
async fn cold_view_reads_catalog_rows_without_opening_or_recovering_saved_chats(
    cx: &mut TestAppContext,
) {
    let directory = tempfile::tempdir().unwrap();
    let project = fs::canonicalize(directory.path()).unwrap();
    let (paused, mut stopped) = saved(&project);
    stopped
        .transact(|session| {
            session.state = RunState::Paused;
            session.queue_paused = true;
            Ok(())
        })
        .unwrap();
    drop(stopped);
    let (interrupted, mut active_store) = saved(&project);
    active(&mut active_store);
    drop(active_store);
    let (ready, idle_store) = saved(&project);
    drop(idle_store);
    let (unavailable, _writer) = saved(&project);
    let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project).unwrap();
    for record in [&paused, &interrupted, &ready, &unavailable] {
        workspace
            .register(record.clone(), DraftRecord::default())
            .unwrap();
    }
    let pending = SessionStore::pending();
    let launch = LaunchState {
        record: ChatRecord::new(
            pending.snapshot().id,
            "Unsent".into(),
            project.join("unsent.json"),
        ),
        controller: Controller::new(pending, None).unwrap(),
        project,
        workspace: Arc::new(Mutex::new(workspace)),
        draft: DraftRecord::default(),
        pending: true,
    };
    let before = files(directory.path());
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let view = window.root(cx).unwrap();
    cx.condition(&view, |view, _| {
        view.sidebar_run_states.observations.len() == 4
    })
    .await;
    window
        .update(cx, |view, _, _| {
            for (record, expected) in [
                (&paused, "Paused"),
                (&interrupted, "Interrupted"),
                (&ready, "Ready"),
                (&unavailable, "Unavailable"),
            ] {
                assert_eq!(view.sidebar_run_status(record), expected);
                assert!(view.chat_ref(&record.id).is_none());
            }
            assert!(view.inactive.is_empty());
            assert!(view.sidebar_run_states.in_flight.is_none());
        })
        .unwrap();
    assert_eq!(files(directory.path()), before);
}
