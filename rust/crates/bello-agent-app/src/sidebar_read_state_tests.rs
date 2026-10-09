//! Independent coordinator/catalog and real-entity regressions. Synthetic GPUI
//! visibility is not native occlusion evidence; Linux acknowledgements stay closed.
use super::*;
use bello_agent_core::{SessionStore, read_observation::AcceptedTerminal, workspace::DraftRecord};
use gpui::{Entity, TestAppContext, WindowHandle};
use std::fs;

fn summary(count: u64) -> OutputSummary {
    OutputSummary {
        count,
        latest_id: (count > 0).then(|| format!("reply-{count}")),
    }
}
fn observation(
    generation: &str,
    count: u64,
    sequence: u64,
    failure: u64,
    busy: bool,
) -> AcceptedReadObservation {
    AcceptedReadObservation {
        generation: generation.into(),
        source_revision: sequence + 1,
        history: OutputProjection::Known(summary(count)),
        busy,
        terminal: (sequence > 0).then(|| AcceptedTerminal {
            sequence,
            source_revision: sequence + 1,
            history: OutputProjection::Known(summary(count)),
        }),
        failure_sequence: failure,
    }
}
fn stores() -> (
    tempfile::TempDir,
    WorkspaceStore,
    ChatRecord,
    Arc<Controller>,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = fs::canonicalize(dir.path()).unwrap();
    let path = project.join("session.json");
    let controller = Controller::new(SessionStore::open(&path).unwrap(), None).unwrap();
    let mut record = ChatRecord::new(controller.snapshot().id, "Read fixture".into(), path);
    record.last_activity_at = Some(123);
    let mut store = WorkspaceStore::open(project.join("catalog.json"), &project).unwrap();
    store
        .register(
            record.clone(),
            DraftRecord {
                text: "preserve 日本語".into(),
                revision: 7,
                ..Default::default()
            },
        )
        .unwrap();
    (dir, store, record, controller)
}

#[::core::prelude::v1::test]
fn initial_baseline_is_byte_preserving_until_admission_and_does_not_touch_session() {
    let (dir, mut store, record, controller) = stores();
    let catalog = fs::read(dir.path().join("catalog.json")).unwrap();
    let session = fs::read(&record.snapshot).unwrap();
    let before = store.snapshot();
    let states = ReadCoordinator::restore(&before);
    states
        .lock()
        .unwrap()
        .observe(&record, &controller.read_observation(), false)
        .unwrap();
    states.lock().unwrap().flush(&mut store, false).unwrap();
    assert_eq!(fs::read(dir.path().join("catalog.json")).unwrap(), catalog);
    assert!(store.snapshot().read_states.is_empty());
    prepare_admission(&states, &mut store, &record, &controller).unwrap();
    assert!(!store.snapshot().read_states[&record.id].baseline_pending);
    assert_eq!(store.snapshot().drafts, before.drafts);
    assert_eq!(store.snapshot().chats, before.chats);
    assert_eq!(fs::read(&record.snapshot).unwrap(), session);
    assert!(!controller.configured());
    assert_eq!(controller.activity().timestamp_micros, None);
}

#[::core::prelude::v1::test]
fn baseline_write_failure_retains_draft_and_never_reaches_dispatch() {
    let (dir, mut store, record, controller) = stores();
    let states = ReadCoordinator::restore(&store.snapshot());
    let before = store.snapshot();
    let session = fs::read(&record.snapshot).unwrap();
    let catalog = dir.path().join("catalog.json");
    fs::rename(&catalog, dir.path().join("saved-catalog.json")).unwrap();
    fs::create_dir(&catalog).unwrap(); // deterministic pre-rename destination fault
    let mut dispatched = 0;
    for _operation in ["Send", "Retry", "Resume"] {
        let result = prepare_admission(&states, &mut store, &record, &controller).map(|()| {
            dispatched += 1;
        });
        assert!(result.is_err());
    }
    assert_eq!(dispatched, 0);
    assert!(store.snapshot().read_states.is_empty());
    assert_eq!(store.snapshot().drafts, before.drafts);
    assert_eq!(fs::read(&record.snapshot).unwrap(), session);
    assert!(states.lock().unwrap().entry(&record).unwrap().dirty);
    fs::remove_dir(&catalog).unwrap();
    fs::rename(dir.path().join("saved-catalog.json"), &catalog).unwrap();
    prepare_admission(&states, &mut store, &record, &controller).unwrap();
    assert!(!states.lock().unwrap().entry(&record).unwrap().dirty);
}

#[::core::prelude::v1::test]
fn grace_hides_only_new_delta_and_relaunch_recovers_entire_obligation() {
    let (dir, mut store, record, _) = stores();
    let states = ReadCoordinator::restore(&store.snapshot());
    let generation = uuid::Uuid::new_v4().to_string();
    {
        let mut states = states.lock().unwrap();
        states
            .observe(&record, &observation(&generation, 0, 0, 0, false), false)
            .unwrap();
        states
            .observe(&record, &observation(&generation, 1, 1, 0, false), false)
            .unwrap();
        states
            .observe(&record, &observation(&generation, 2, 2, 0, false), true)
            .unwrap();
        assert_eq!(states.presentation(&record).unwrap().unread_count, 1);
        assert_eq!(states.entry(&record).unwrap().state.unread_count, 2);
        assert!(states.entry(&record).unwrap().hold.is_some());
        states.flush(&mut store, true).unwrap();
    }
    let saved = store.snapshot().read_states[&record.id].clone();
    assert_eq!(saved.observed_count, 2);
    assert_eq!(saved.unread_target_id.as_deref(), Some("reply-2"));
    drop(store);
    let reopened = WorkspaceStore::open(dir.path().join("catalog.json"), dir.path()).unwrap();
    let restored = ReadCoordinator::restore(&reopened.snapshot());
    assert_eq!(
        restored
            .lock()
            .unwrap()
            .presentation(&record)
            .unwrap()
            .unread_count,
        2
    );
    assert_eq!(reopened.snapshot().read_states[&record.id], saved);
}

#[::core::prelude::v1::test]
fn failure_retry_coalescence_clears_once_and_rejects_old_observation() {
    let (_dir, mut store, record, _) = stores();
    let states = ReadCoordinator::restore(&store.snapshot());
    let generation = uuid::Uuid::new_v4().to_string();
    let mut states = states.lock().unwrap();
    states
        .observe(&record, &observation(&generation, 0, 0, 0, false), false)
        .unwrap();
    // Only the coalesced running observation is delivered: its retained failure
    // must survive even though no Error snapshot was delivered to the UI.
    let coalesced = observation(&generation, 0, 1, 1, true);
    states.observe(&record, &coalesced, false).unwrap();
    assert!(states.entry(&record).unwrap().state.unread_failure);
    states
        .apply(
            &record,
            ReadEvent::Opened {
                changed_focus: false,
            },
            true,
            false,
        )
        .unwrap();
    states.flush(&mut store, true).unwrap();
    let before = states.entry(&record).unwrap().state.clone();
    assert!(!states.observe(&record, &coalesced, false).unwrap());
    assert!(
        !states
            .observe(&record, &observation(&generation, 0, 0, 0, false), false)
            .unwrap()
    );
    assert_eq!(states.entry(&record).unwrap().state, before);
    assert!(!before.unread_failure);
}

#[::core::prelude::v1::test]
fn stale_catalog_revision_cannot_clear_newer_dirty_state() {
    let (_dir, mut store, record, controller) = stores();
    let states = ReadCoordinator::restore(&store.snapshot());
    prepare_admission(&states, &mut store, &record, &controller).unwrap();
    let snapshot = store.snapshot();
    let old = snapshot.read_states[&record.id].clone();
    let newer = reduce_read_state(Some(&old), ReadEvent::MarkUnread)
        .unwrap()
        .unwrap();
    store
        .save_read_state(
            &snapshot.project,
            snapshot.project_id.as_deref(),
            &record.id,
            &record.snapshot,
            Some(old.revision),
            &newer,
        )
        .unwrap();
    {
        let mut states = states.lock().unwrap();
        states
            .apply(&record, ReadEvent::MarkUnread, true, false)
            .unwrap();
        assert!(states.flush(&mut store, false).is_err());
        assert!(states.entry(&record).unwrap().dirty);
        assert_eq!(
            states.entry(&record).unwrap().saved_revision,
            Some(old.revision)
        );
    }
    assert_eq!(store.snapshot().read_states[&record.id], newer);
}

#[::core::prelude::v1::test]
fn unknown_history_preserves_manual_baseline_until_known_observation() {
    let (_dir, mut store, record, _) = stores();
    let states = ReadCoordinator::restore(&store.snapshot());
    let mut states = states.lock().unwrap();
    states
        .apply(&record, ReadEvent::MarkUnread, true, false)
        .unwrap();
    let before = states.entry(&record).unwrap().state.clone();
    let mut unknown = observation(&uuid::Uuid::new_v4().to_string(), 9, 1, 0, false);
    unknown.history = OutputProjection::Unknown;
    assert!(!states.observe(&record, &unknown, false).unwrap());
    assert_eq!(states.entry(&record).unwrap().state, before);
    states.baseline(&record, &summary(9)).unwrap();
    states.flush(&mut store, true).unwrap();
    let state = &store.snapshot().read_states[&record.id];
    assert!(state.manual_unread);
    assert!(!state.baseline_pending);
    assert_eq!(state.unread_count, 0);
    assert_eq!(state.observed_count, 9);
}

fn fixture(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let (dir, store, record, controller) = stores();
    let draft = store.snapshot().drafts[&record.id].clone();
    let launch = crate::LaunchState {
        project: dir.path().to_path_buf(),
        record,
        controller,
        workspace: Arc::new(Mutex::new(store)),
        draft,
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let view = window.root(cx).unwrap();
    cx.run_until_parked();
    (dir, window, view)
}

#[gpui::test]
fn explicit_same_row_and_changed_focus_have_distinct_manual_semantics(cx: &mut TestAppContext) {
    let (_dir, window, _) = fixture(cx);
    window
        .update(cx, |view, window, cx| {
            let id = view.record.id.clone();
            view.mark_chat_read_state(&id, true, cx);
            assert_eq!(view.read_status(&view.record).as_deref(), Some("Unread"));
            view.select_chat_internal(&id, false, window, cx);
            assert_eq!(
                view.read_attention(&view.record).0,
                1,
                "startup is not a reader opening"
            );
            view.select_chat_internal(&id, true, window, cx);
            assert_eq!(
                view.read_attention(&view.record).0,
                1,
                "same-row reselection retains manual unread"
            );
            view.reader_opened(&id, true, cx);
            assert_eq!(view.read_attention(&view.record).0, 0);
        })
        .unwrap();
    cx.run_until_parked();
}

#[gpui::test]
fn manual_actions_preserve_activity_draft_controller_and_checkpoint(cx: &mut TestAppContext) {
    let (_dir, window, _) = fixture(cx);
    window
        .update(cx, |view, _, cx| {
            let record = view.record.clone();
            let source = view.controller.clone();
            let bytes = fs::read(&record.snapshot).unwrap();
            let before = view.workspace.lock().unwrap().snapshot();
            let draft = view.composer.read(cx).text().to_owned();
            for _ in 0..3 {
                view.mark_chat_read_state(&record.id, true, cx);
                view.mark_chat_read_state(&record.id, false, cx);
            }
            assert_eq!(view.composer.read(cx).text(), draft);
            assert!(Arc::ptr_eq(&source, &view.controller));
            assert_eq!(view.controller.activity().timestamp_micros, None);
            assert!(!view.controller.configured());
            assert_eq!(fs::read(&record.snapshot).unwrap(), bytes);
            let after = view.workspace.lock().unwrap().snapshot();
            assert_eq!(after.chats, before.chats);
            assert_eq!(after.drafts, before.drafts);
            assert_eq!(after.intents, before.intents);
        })
        .unwrap();
    cx.run_until_parked();
}

#[gpui::test]
fn stale_controller_path_and_workspace_callbacks_cannot_create_attention(cx: &mut TestAppContext) {
    let (_dir, window, _) = fixture(cx);
    window
        .update(cx, |view, _, cx| {
            let record = view.record.clone();
            let workspace = view.workspace.clone();
            let source = Arc::downgrade(&view.controller);
            let before = view
                .read_states
                .lock()
                .unwrap()
                .entry(&record)
                .unwrap()
                .state
                .clone();
            let update = observation(&uuid::Uuid::new_v4().to_string(), 8, 1, 1, false);
            let stranger = Controller::new(SessionStore::pending(), None).unwrap();
            view.receive_read_observation(
                &workspace,
                &record,
                &Arc::downgrade(&stranger),
                update.clone(),
                cx,
            );
            let mut replaced = record.clone();
            replaced.snapshot = record.snapshot.with_file_name("replacement.json");
            view.receive_read_observation(&workspace, &replaced, &source, update.clone(), cx);
            let other_dir = tempfile::tempdir().unwrap();
            let other = Arc::new(Mutex::new(
                WorkspaceStore::open(other_dir.path().join("catalog.json"), other_dir.path())
                    .unwrap(),
            ));
            view.receive_read_observation(&other, &record, &source, update, cx);
            assert_eq!(
                view.read_states
                    .lock()
                    .unwrap()
                    .entry(&record)
                    .unwrap()
                    .state,
                before
            );
        })
        .unwrap();
}

#[gpui::test]
fn manual_action_exclusions_cover_loading_failed_pending_archived_and_missing(
    cx: &mut TestAppContext,
) {
    let (_dir, window, _) = fixture(cx);
    window
        .update(cx, |view, _, _| {
            let id = view.record.id.clone();
            assert!(view.can_read_action(&id, true));
            assert!(!view.can_read_action("missing", true));
            view.loading = true;
            assert!(!view.can_read_action(&id, true));
            view.loading = false;
            view.load_failed = true;
            assert!(!view.can_read_action(&id, true));
            view.load_failed = false;
            view.pending = true;
            assert!(!view.can_read_action(&id, true));
            view.pending = false;
            view.records
                .iter_mut()
                .find(|r| r.id == id)
                .unwrap()
                .archived_at = Some(1);
            assert!(!view.can_read_action(&id, true));
        })
        .unwrap();
}

#[cfg(not(target_os = "macos"))]
#[gpui::test]
fn linux_native_evidence_gate_cannot_acknowledge_even_exact_target(cx: &mut TestAppContext) {
    let (_dir, window, _) = fixture(cx);
    window
        .update(cx, |_, window, _| window.activate_window())
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            let record = view.record.clone();
            let source = Arc::downgrade(&view.controller);
            let generation = view.controller.read_observation().generation;
            {
                let mut states = view.read_states.lock().unwrap();
                states
                    .observe(&record, &observation(&generation, 1, 1, 0, false), false)
                    .unwrap();
            }
            let before = view.read_attention(&record);
            assert_eq!(before.0, 1);
            assert!(
                !native_readable(Some(window.window_handle()), cx),
                "the test platform has no verified native occlusion proof"
            );
            assert!(
                window.is_window_active(),
                "explicit synthetic activation is present"
            );
            let current = view.controller.read_observation();
            view.acknowledge_reply_end(
                &record.id,
                &source,
                "reply-1",
                current.source_revision,
                &current.generation,
                true,
                window,
                cx,
            );
            assert_eq!(view.read_attention(&record), before);
        })
        .unwrap();
}

// Real Tokio worker wakes an OS thread, not GPUI's deterministic fake executor.
fn block_external<T>(future: impl std::future::Future<Output = T>) -> T {
    struct WakeThread(std::thread::Thread);
    impl std::task::Wake for WakeThread {
        fn wake(self: Arc<Self>) {
            self.0.unpark();
        }
    }
    let waker = std::task::Waker::from(Arc::new(WakeThread(std::thread::current())));
    let mut context = std::task::Context::from_waker(&waker);
    let mut future = std::pin::pin!(future);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let std::task::Poll::Ready(value) = future.as_mut().poll(&mut context) {
            return value;
        }
        std::thread::park_timeout(
            deadline
                .checked_duration_since(Instant::now())
                .expect("worker timed out"),
        );
    }
}

#[::core::prelude::v1::test]
fn shutdown_joins_real_partial_worker_then_captures_without_foreground_watch() {
    use bello_agent_core::{Credential, Lane, RunState};
    use std::io::{Read, Write};
    let (dir, mut store, record, old_controller) = stores();
    drop(old_controller);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let server = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let mut raw = Vec::new();
        let mut buffer = [0; 4096];
        loop {
            let n = socket.read(&mut buffer).unwrap();
            assert_ne!(n, 0);
            raw.extend_from_slice(&buffer[..n]);
            if let Some(end) = raw.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
                let header = String::from_utf8_lossy(&raw[..end]).to_lowercase();
                let length: usize = header
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length: "))
                    .unwrap_or("0")
                    .parse()
                    .unwrap();
                if raw.len() >= end + 4 + length {
                    break;
                }
            }
        }
        socket.write_all(b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"retained during join\"}\n\n").unwrap();
        socket.flush().unwrap();
        release_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    });
    let profile = serde_json::from_value(serde_json::json!({
        "id":"read-shutdown-loopback", "api":"openai-responses", "providerId":"litellm", "modelId":"fixture",
        "baseUrl":format!("http://{address}"), "contextWindow":32000, "maxOutputTokens":4096
    })).unwrap();
    let controller = Controller::new(
        SessionStore::open(&record.snapshot).unwrap(),
        Some((
            profile,
            Credential::new("fake-loopback-only".into()).unwrap(),
        )),
    )
    .unwrap();
    let states = ReadCoordinator::restore(&store.snapshot());
    prepare_admission(&states, &mut store, &record, &controller).unwrap();
    controller
        .submit("bounded shutdown fixture".into(), Lane::FollowUp)
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !controller
        .snapshot()
        .messages
        .iter()
        .any(|row| row.text == "retained during join")
    {
        assert!(Instant::now() < deadline, "partial never arrived");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(controller.snapshot().state, RunState::Running);
    assert!(controller.read_observation().terminal.is_none());
    let workspace = Arc::new(Mutex::new(store));
    let plan = crate::shutdown_barrier::ShutdownPlan {
        // Deliberately no draft records: dirty read state and post-join capture
        // must not depend on the draft list or a delivered UI callback.
        drafts: Vec::new(),
        controllers: vec![controller.clone()],
        read_states: Some(states.clone()),
        read_controllers: vec![(record.clone(), controller.clone())],
        selected: record.id.clone(),
        selection_revision: 20,
        workspace: workspace.clone(),
    };
    let outcome = block_external(plan.execute());
    release_tx.send(()).unwrap();
    server.join().unwrap();
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_ne!(controller.snapshot().state, RunState::Running);
    let final_observation = controller.read_observation();
    assert!(final_observation.terminal.is_some());
    let persisted = workspace.lock().unwrap().snapshot().read_states[&record.id].clone();
    assert_eq!(persisted.observed_count, 1);
    assert_eq!(persisted.unread_count, 1);
    assert_eq!(
        persisted.unread_target_id,
        controller
            .snapshot()
            .messages
            .last()
            .map(|row| row.id.clone())
    );
    assert_eq!(
        workspace.lock().unwrap().snapshot().drafts[&record.id].text,
        "preserve 日本語"
    );
    drop(workspace);
    let reopened = WorkspaceStore::open(dir.path().join("catalog.json"), dir.path()).unwrap();
    assert_eq!(reopened.snapshot().read_states[&record.id], persisted);
}

#[gpui::test]
fn quit_during_grace_flushes_unloaded_dirty_entry_without_draft_record(cx: &mut TestAppContext) {
    let (_dir, store, record, controller) = stores();
    let states = ReadCoordinator::restore(&store.snapshot());
    let generation = uuid::Uuid::new_v4().to_string();
    {
        let mut states = states.lock().unwrap();
        states
            .observe(&record, &observation(&generation, 0, 0, 0, false), false)
            .unwrap();
        states
            .observe(&record, &observation(&generation, 1, 1, 0, false), true)
            .unwrap();
        assert_eq!(states.presentation(&record).unwrap().unread_count, 0);
    }
    let workspace = Arc::new(Mutex::new(store));
    let outcome = cx.background_executor.block_test(
        crate::shutdown_barrier::ShutdownPlan {
            drafts: Vec::new(),
            controllers: vec![controller],
            read_states: Some(states.clone()),
            read_controllers: Vec::new(),
            selected: record.id.clone(),
            selection_revision: 20,
            workspace: workspace.clone(),
        }
        .execute(),
    );
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    let snapshot = workspace.lock().unwrap().snapshot();
    assert_eq!(snapshot.read_states[&record.id].unread_count, 1);
    assert_eq!(snapshot.read_states[&record.id].observed_count, 1);
    let restored = ReadCoordinator::restore(&snapshot);
    assert_eq!(
        restored
            .lock()
            .unwrap()
            .presentation(&record)
            .unwrap()
            .unread_count,
        1
    );
}

#[::core::prelude::v1::test]
fn admission_rejects_unregistered_path_replacement_and_foreign_controller() {
    let (_dir, mut store, record, controller) = stores();
    let states = ReadCoordinator::restore(&store.snapshot());
    let before = store.snapshot();
    let mut replacement = record.clone();
    replacement.snapshot = replacement.snapshot.with_file_name("replaced.json");
    assert!(prepare_admission(&states, &mut store, &replacement, &controller).is_err());
    let mut absent = record.clone();
    absent.id = uuid::Uuid::new_v4().to_string();
    assert!(prepare_admission(&states, &mut store, &absent, &controller).is_err());
    let foreign = Controller::new(SessionStore::pending(), None).unwrap();
    assert!(prepare_admission(&states, &mut store, &record, &foreign).is_err());
    assert_eq!(store.snapshot().read_states, before.read_states);
    assert_eq!(store.snapshot().drafts, before.drafts);
    assert!(states.lock().unwrap().entries.is_empty());
}

#[gpui::test]
fn durable_manual_restore_precedes_startup_and_real_reader_open(cx: &mut TestAppContext) {
    let (dir, mut store, record, controller) = stores();
    let states = ReadCoordinator::restore(&store.snapshot());
    {
        let mut states = states.lock().unwrap();
        states
            .apply(&record, ReadEvent::MarkUnread, true, false)
            .unwrap();
        states.flush(&mut store, true).unwrap();
    }
    let draft = store.snapshot().drafts[&record.id].clone();
    let launch = crate::LaunchState {
        project: dir.path().to_path_buf(),
        record: record.clone(),
        controller,
        workspace: Arc::new(Mutex::new(store)),
        draft,
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert_eq!(view.read_status(&record).as_deref(), Some("Unread"));
            assert!(!view.can_read_action(&record.id, true));
            assert!(view.can_read_action(&record.id, false));
            view.select_chat_internal(&record.id, false, window, cx);
            assert_eq!(view.read_attention(&record).0, 1);
            view.reader_opened(&record.id, true, cx);
            assert_eq!(view.read_attention(&record).0, 0);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, _, _| {
            assert!(
                !view.workspace.lock().unwrap().snapshot().read_states[&record.id].manual_unread
            );
        })
        .unwrap();
}

#[gpui::test]
fn send_retry_command_and_resume_routes_stop_at_failed_baseline(cx: &mut TestAppContext) {
    use bello_agent_core::Lane;
    use std::sync::atomic::{AtomicUsize, Ordering};
    for route in ["send", "retry", "resume"] {
        let (_dir, window, root) = fixture(cx);
        let dispatches = Arc::new(AtomicUsize::new(0));
        let dispatched = dispatches.clone();
        let (bytes, original_draft) = window
            .update(cx, |view, _, cx| {
                let bytes = fs::read(&view.record.snapshot).unwrap();
                let draft = view.composer.read(cx).text().to_owned();
                // A real coordinator admission fence, independent of the UI's
                // catalog flag, proves each command reaches the shared boundary.
                view.read_states.lock().unwrap().fenced = true;
                match route {
                    "send" => view.submit_chat(Lane::FollowUp, cx),
                    "retry" => view.command(
                        cx,
                        None,
                        false,
                        move |_| {
                            dispatched.fetch_add(1, Ordering::SeqCst);
                            Ok(())
                        },
                        |_, (), _| {},
                    ),
                    "resume" => {
                        Arc::make_mut(&mut view.session).queue_paused = true;
                        view.resume_queued(&view.record.id.clone(), cx);
                    }
                    _ => unreachable!(),
                }
                (bytes, draft)
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(200));
        cx.run_until_parked();
        cx.read(|cx| {
            let view = root.read(cx);
            assert_eq!(dispatches.load(Ordering::SeqCst), 0, "{route}");
            assert!(
                view.error
                    .as_deref()
                    .is_some_and(|error| error.contains("Read-state storage is unconfirmed")),
                "{route}: {:?}",
                view.error
            );
            assert_eq!(view.composer.read(cx).text(), original_draft, "{route}");
            assert_eq!(
                view.workspace.lock().unwrap().snapshot().drafts[&view.record.id].text,
                original_draft,
                "{route}: delayed draft save must preserve original input"
            );
            assert_eq!(fs::read(&view.record.snapshot).unwrap(), bytes, "{route}");
            assert!(!view.busy, "{route}");
            assert!(view.queue_operation.is_none(), "{route}");
            assert!(
                view.workspace
                    .lock()
                    .unwrap()
                    .snapshot()
                    .read_states
                    .is_empty()
            );
        });
    }
}

#[gpui::test]
fn cancel_edit_cannot_release_held_queue_when_baseline_is_fenced(cx: &mut TestAppContext) {
    use bello_agent_core::{Lane, Submission, workspace::QueuedDraft};
    let dir = tempfile::tempdir().unwrap();
    let project = fs::canonicalize(dir.path()).unwrap();
    let path = project.join("session.json");
    let mut session = SessionStore::open(&path).unwrap();
    let turn = Submission::new("original queued text".into(), Lane::FollowUp);
    let turn_id = turn.id.clone();
    session
        .transact(|session| {
            session.pending.push(turn);
            session.queue_paused = true;
            session.begin_edit(&turn_id, "read-baseline-edit")?;
            Ok(())
        })
        .unwrap();
    let record = ChatRecord::new(session.snapshot().id, "Held queue".into(), path);
    let draft = DraftRecord {
        text: "ordinary draft".into(),
        revision: 7,
        queued_edit: Some(QueuedDraft {
            edit_id: "read-baseline-edit".into(),
            turn_id,
            rewrite: "preserve unsaved rewrite".into(),
            original_text: Some("original queued text".into()),
        }),
        ..Default::default()
    };
    let mut store = WorkspaceStore::open(project.join("catalog.json"), &project).unwrap();
    store.register(record.clone(), draft.clone()).unwrap();
    let launch = crate::LaunchState {
        project,
        record: record.clone(),
        draft,
        pending: false,
        controller: Controller::new(session, None).unwrap(),
        workspace: Arc::new(Mutex::new(store)),
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    cx.run_until_parked();
    let before = fs::read(&record.snapshot).unwrap();
    window
        .update(cx, |view, _, cx| {
            assert!(view.can_cancel_owned_edit());
            view.read_states.lock().unwrap().fenced = true;
            view.cancel_owned_edit(&record.id, cx);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, _, cx| {
            assert!(
                view.error
                    .as_deref()
                    .is_some_and(|error| error.contains("Read-state storage is unconfirmed")),
                "{:?}",
                view.error
            );
            assert_eq!(fs::read(&record.snapshot).unwrap(), before);
            assert!(view.controller.snapshot().edit.is_some());
            assert_eq!(view.composer.read(cx).text(), "preserve unsaved rewrite");
            assert!(
                view.has_pending_cancel(&record.id),
                "durable cancellation receipt remains retryable"
            );
            assert!(
                view.workspace
                    .lock()
                    .unwrap()
                    .snapshot()
                    .read_states
                    .is_empty()
            );
        })
        .unwrap();
}

#[::core::prelude::v1::test]
fn native_read_evidence_predicate_requires_every_independent_visibility_fact() {
    // Explicit supplied evidence only. This does not exercise AppKit or grant
    // the Linux test platform any native visibility/occlusion authority.
    let valid = NativeReadEvidence {
        active: true,
        key: true,
        visible: true,
        minimized: false,
        occlusion_visible: true,
        attached_sheet: false,
        hidden_view: false,
        view_rect: [0., 0., 920., 600.],
    };
    assert!(valid.readable());
    for rejected in [
        NativeReadEvidence {
            active: false,
            ..valid
        },
        NativeReadEvidence {
            key: false,
            ..valid
        },
        NativeReadEvidence {
            visible: false,
            ..valid
        },
        NativeReadEvidence {
            minimized: true,
            ..valid
        },
        NativeReadEvidence {
            occlusion_visible: false,
            ..valid
        },
        NativeReadEvidence {
            attached_sheet: true,
            ..valid
        },
        NativeReadEvidence {
            hidden_view: true,
            ..valid
        },
    ] {
        assert!(!rejected.readable());
    }
    for dimension in [2, 3] {
        for value in [0., -1., f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut evidence = valid;
            evidence.view_rect[dimension] = value;
            assert!(!evidence.readable(), "dimension {dimension}, value {value}");
        }
    }
    for coordinate in [0, 1] {
        for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut evidence = valid;
            evidence.view_rect[coordinate] = value;
            assert!(
                !evidence.readable(),
                "coordinate {coordinate}, value {value}"
            );
        }
    }
    // Negative screen coordinates can be legitimate on an adjacent display.
    assert!(
        NativeReadEvidence {
            view_rect: [-920., -10., 920., 600.],
            ..valid
        }
        .readable()
    );
}

#[::core::prelude::v1::test]
fn completed_old_batch_receipt_does_not_clear_newer_live_mutation() {
    let (_dir, mut store, record, controller) = stores();
    let states = ReadCoordinator::restore(&store.snapshot());
    prepare_admission(&states, &mut store, &record, &controller).unwrap();
    let mut live = states.lock().unwrap();
    live.apply(&record, ReadEvent::MarkUnread, true, false)
        .unwrap();
    let mut batch = live.clone();
    let old_revision = batch.entry(&record).unwrap().state.revision;
    live.apply(&record, ReadEvent::MarkRead, true, false)
        .unwrap();
    let newer = live.entry(&record).unwrap().state.clone();
    assert!(newer.revision > old_revision);
    batch.flush(&mut store, false).unwrap();
    merge_saved_batch(&mut live, batch, &store.snapshot().chats, false);
    let entry = live.entry(&record).unwrap();
    assert_eq!(entry.state, newer);
    assert_eq!(entry.saved_revision, Some(old_revision));
    assert!(entry.dirty);
    assert!(store.snapshot().read_states[&record.id].manual_unread);
    drop(live);
    flush_shared(&states, &mut store, false).unwrap();
    assert_eq!(store.snapshot().read_states[&record.id], newer);
    assert!(!states.lock().unwrap().entry(&record).unwrap().dirty);
}

#[::core::prelude::v1::test]
fn completed_batch_receipt_cannot_acknowledge_same_id_replacement_path() {
    let (_dir, mut store, record, controller) = stores();
    let states = ReadCoordinator::restore(&store.snapshot());
    prepare_admission(&states, &mut store, &record, &controller).unwrap();
    let mut live = states.lock().unwrap();
    live.apply(&record, ReadEvent::MarkUnread, true, false)
        .unwrap();
    let mut batch = live.clone();
    let mut replacement = record.clone();
    replacement.snapshot = replacement.snapshot.with_file_name("new-session.json");
    live.apply(&replacement, ReadEvent::MarkUnread, true, false)
        .unwrap();
    let next = live.entry(&replacement).unwrap().state.clone();
    batch.flush(&mut store, false).unwrap();
    merge_saved_batch(&mut live, batch, &[replacement.clone()], false);
    assert!(live.entry(&record).is_none());
    let entry = live.entry(&replacement).unwrap();
    assert_eq!(entry.state, next);
    assert_eq!(entry.saved_revision, None);
    assert!(entry.dirty);
}

#[::core::prelude::v1::test]
fn uncertain_batch_receipt_preserves_newer_dirty_state_and_admission_fence() {
    let (_dir, mut store, record, controller) = stores();
    let states = ReadCoordinator::restore(&store.snapshot());
    prepare_admission(&states, &mut store, &record, &controller).unwrap();
    {
        let mut live = states.lock().unwrap();
        live.apply(&record, ReadEvent::MarkUnread, true, false)
            .unwrap();
        let batch = live.clone(); // no confirmed save receipt
        live.apply(&record, ReadEvent::MarkRead, true, false)
            .unwrap();
        let newer = live.entry(&record).unwrap().state.clone();
        merge_saved_batch(&mut live, batch, &store.snapshot().chats, true);
        assert!(live.fenced);
        assert_eq!(live.entry(&record).unwrap().state, newer);
        assert!(live.entry(&record).unwrap().dirty);
    }
    assert!(prepare_admission(&states, &mut store, &record, &controller).is_err());
    assert!(states.lock().unwrap().fenced);
    assert!(states.lock().unwrap().entry(&record).unwrap().dirty);
}

#[::core::prelude::v1::test]
fn authoritative_ack_target_revision_and_generation_must_all_match() {
    let generation = uuid::Uuid::new_v4().to_string();
    let accepted = observation(&generation, 2, 2, 0, false);
    assert!(reply_observation_matches(
        &accepted,
        "reply-2",
        accepted.source_revision,
        &generation
    ));
    assert!(!reply_observation_matches(
        &accepted,
        "reply-1",
        accepted.source_revision,
        &generation
    ));
    assert!(!reply_observation_matches(
        &accepted,
        "reply-2",
        accepted.source_revision - 1,
        &generation
    ));
    assert!(!reply_observation_matches(
        &accepted,
        "reply-2",
        accepted.source_revision + 1,
        &generation
    ));
    assert!(!reply_observation_matches(
        &accepted,
        "reply-2",
        accepted.source_revision,
        &uuid::Uuid::new_v4().to_string()
    ));
    // The actor has accepted a newer reply, but the previous frame/watch has
    // not arrived. Its formerly correct visible target must now be rejected.
    let newer = observation(&generation, 3, 3, 0, false);
    assert!(!reply_observation_matches(
        &newer,
        "reply-2",
        accepted.source_revision,
        &generation
    ));
    let mut unknown = accepted.clone();
    unknown.history = OutputProjection::Unknown;
    assert!(!reply_observation_matches(
        &unknown,
        "reply-2",
        unknown.source_revision,
        &generation
    ));
}

#[gpui::test]
async fn unloaded_manual_action_rechecks_missing_and_replaced_checkpoint_after_scan(
    cx: &mut TestAppContext,
) {
    for replace in [false, true] {
        let (dir, window, root) = fixture(cx);
        let path = dir.path().join(if replace {
            "unloaded-replace.json"
        } else {
            "unloaded-remove.json"
        });
        let session = SessionStore::open(&path).unwrap();
        let record = ChatRecord::new(session.snapshot().id, "Unloaded".into(), path.clone());
        drop(session);
        window
            .update(cx, |view, _, cx| {
                view.workspace
                    .lock()
                    .unwrap()
                    .register(record.clone(), DraftRecord::default())
                    .unwrap();
                view.records.push(record.clone());
                view.refresh_sidebar_run_states(cx);
            })
            .unwrap();
        cx.condition(&root, |view, _| view.can_read_action(&record.id, true))
            .await;
        window
            .update(cx, |view, _, _| {
                assert!(view.chat_ref(&record.id).is_none());
                assert!(view.sidebar_saved_identity(&record).is_some());
                assert!(view.can_read_action(&record.id, true));
            })
            .unwrap();
        if replace {
            let temporary = path.with_file_name("replacement-inode.json");
            fs::write(&temporary, fs::read(&path).unwrap()).unwrap();
            let modified = fs::metadata(&path).unwrap().modified().unwrap();
            fs::File::options()
                .write(true)
                .open(&temporary)
                .unwrap()
                .set_times(fs::FileTimes::new().set_modified(modified))
                .unwrap();
            fs::rename(&temporary, &path).unwrap();
        } else {
            fs::remove_file(&path).unwrap();
        }
        window
            .update(cx, |view, _, cx| {
                view.mark_chat_read_state(&record.id, true, cx)
            })
            .unwrap();
        cx.run_until_parked();
        cx.condition(&root, |view, _| view.read_manual_operations.is_empty())
            .await;
        window
            .update(cx, |view, _, _| {
                assert_eq!(view.read_attention(&record).0, 0);
                assert!(
                    !view
                        .workspace
                        .lock()
                        .unwrap()
                        .snapshot()
                        .read_states
                        .contains_key(&record.id)
                );
                assert!(
                    view.chat_ref(&record.id).is_none(),
                    "manual metadata action cannot open a Controller"
                );
            })
            .unwrap();
    }
}

#[gpui::test]
fn undispatched_uncertain_send_merges_newer_typing_and_keeps_durable_input(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = fixture(cx);
    window
        .update(cx, |view, _, cx| {
            view.read_states.lock().unwrap().fenced = true;
            view.submit_chat(bello_agent_core::Lane::FollowUp, cx);
            assert!(view.busy);
            assert_eq!(view.composer.read(cx).text(), "");
            view.composer.update(cx, |editor, cx| {
                editor.set_text("newer 日本語 🦀".into(), cx)
            });
        })
        .unwrap();
    cx.run_until_parked();
    cx.executor().advance_clock(Duration::from_millis(200));
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        let expected = "preserve 日本語\n\nnewer 日本語 🦀";
        assert_eq!(view.composer.read(cx).text(), expected);
        assert_eq!(
            view.workspace.lock().unwrap().snapshot().drafts[&view.record.id].text,
            expected
        );
        assert!(view.controller.snapshot().messages.is_empty());
        assert!(view.read_states.lock().unwrap().fenced);
        assert!(
            view.recoveries
                .values()
                .any(|receipt| receipt.chat_id == view.record.id
                    && receipt.text == "preserve 日本語")
        );
    });
}

#[cfg(not(target_os = "macos"))]
#[gpui::test]
fn linux_platform_failure_attention_distinguishes_foreground_background_and_other_pages(
    cx: &mut TestAppContext,
) {
    for surface in ["foreground", "background", "files", "changes"] {
        let (_dir, window, _) = fixture(cx);
        window
            .update(cx, |_, window, _| window.activate_window())
            .unwrap();
        cx.run_until_parked();
        if surface == "background" {
            let mut visual = gpui::VisualTestContext::from_window(window.into(), cx);
            visual.deactivate_window();
            cx.run_until_parked();
        }
        window
            .update(cx, |view, window, cx| {
                view.show_files = surface == "files";
                view.changes_open = surface == "changes";
                assert_eq!(
                    window.is_window_active(),
                    surface != "background",
                    "{surface}"
                );
                assert_eq!(
                    view.failure_reader_present(cx),
                    surface == "foreground",
                    "{surface}"
                );
                // Synthetic application activation is sufficient for the failure
                // viewing rule, never for actual reply acknowledgement or grace.
                assert!(!native_readable(Some(window.window_handle()), cx));
                let record = view.record.clone();
                let workspace = view.workspace.clone();
                let source = Arc::downgrade(&view.controller);
                let generation = view.controller.read_observation().generation;
                let failed = observation(&generation, 0, 1, 1, false);
                view.receive_read_observation(&workspace, &record, &source, failed.clone(), cx);
                assert_eq!(
                    view.read_states
                        .lock()
                        .unwrap()
                        .entry(&record)
                        .unwrap()
                        .state
                        .unread_failure,
                    surface != "foreground",
                    "{surface}"
                );
                assert_eq!(
                    view.read_attention(&record).0,
                    0,
                    "failure alone is not a reply"
                );
                view.reader_opened(&record.id, false, cx);
                view.receive_read_observation(&workspace, &record, &source, failed, cx);
                assert!(
                    !view
                        .read_states
                        .lock()
                        .unwrap()
                        .entry(&record)
                        .unwrap()
                        .state
                        .unread_failure,
                    "old failure cannot reappear after explicit opening"
                );
            })
            .unwrap();
        cx.run_until_parked();
    }
}

#[cfg(feature = "synthetic-authority")]
#[gpui::test]
fn real_after_rename_baseline_uncertainty_preserves_input_and_blocks_dispatch(
    cx: &mut TestAppContext,
) {
    let (dir, window, root) = fixture(cx);
    let checkpoint = window
        .update(cx, |view, _, cx| {
            view.workspace
                .lock()
                .unwrap()
                .synthetic_fail_next_read_state_commit_after_rename()
                .unwrap();
            let checkpoint = fs::read(&view.record.snapshot).unwrap();
            view.submit_chat(bello_agent_core::Lane::FollowUp, cx);
            assert!(view.busy);
            view.composer.update(cx, |editor, cx| {
                editor.set_text("newer while save fails".into(), cx)
            });
            checkpoint
        })
        .unwrap();
    cx.run_until_parked();
    cx.executor().advance_clock(Duration::from_millis(200));
    cx.run_until_parked();
    let disk: WorkspaceSnapshot =
        serde_json::from_slice(&fs::read(dir.path().join("catalog.json")).unwrap()).unwrap();
    window
        .update(cx, |view, _, cx| {
            let store = view.workspace.lock().unwrap();
            assert!(
                store.is_uncertain(),
                "real post-rename outcome must fence the catalog"
            );
            let memory = store.snapshot();
            assert!(
                !memory.read_states.contains_key(&view.record.id),
                "unconfirmed mutation must not publish to memory"
            );
            assert!(
                !disk.read_states[&view.record.id].baseline_pending,
                "renamed disk contains the baseline"
            );
            assert_eq!(disk.read_states[&view.record.id].observed_count, 0);
            assert_eq!(disk.drafts[&view.record.id].text, "preserve 日本語");
            assert_eq!(memory.drafts[&view.record.id].text, "preserve 日本語");
            assert!(
                disk.intents.is_empty(),
                "baseline failed before submission intent creation"
            );
            drop(store);
            assert!(view.known_catalog_uncertainty);
            assert!(view.read_states.lock().unwrap().fenced);
            assert_eq!(
                view.composer.read(cx).text(),
                "preserve 日本語\n\nnewer while save fails"
            );
            assert_eq!(fs::read(&view.record.snapshot).unwrap(), checkpoint);
            assert!(view.controller.snapshot().messages.is_empty());
            assert!(!view.busy);
            view.submit_chat(bello_agent_core::Lane::FollowUp, cx);
            assert_eq!(
                view.composer.read(cx).text(),
                "preserve 日本語\n\nnewer while save fails"
            );
            assert!(view.controller.snapshot().messages.is_empty());
            assert!(
                prepare_admission(
                    &view.read_states,
                    &mut view.workspace.lock().unwrap(),
                    &view.record,
                    &view.controller
                )
                .is_err()
            );
        })
        .unwrap();
    cx.executor().advance_clock(Duration::from_millis(200));
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.workspace.lock().unwrap().is_uncertain());
        assert_eq!(
            view.composer.read(cx).text(),
            "preserve 日本語\n\nnewer while save fails"
        );
        let after: WorkspaceSnapshot =
            serde_json::from_slice(&fs::read(dir.path().join("catalog.json")).unwrap()).unwrap();
        assert_eq!(
            after.drafts, disk.drafts,
            "uncertain store must never overwrite durable input with later debounce"
        );
        assert_eq!(fs::read(&view.record.snapshot).unwrap(), checkpoint);
    });
}

#[::core::prelude::v1::test]
fn explicit_failure_reader_evidence_requires_selected_conversation_and_active_application() {
    // Platform-independent source-rule matrix. These explicit booleans do not
    // assert that TestAppContext supplies native NSApplication evidence.
    for selected in [false, true] {
        for conversation in [false, true] {
            for active in [false, true] {
                assert_eq!(
                    failure_reader_evidence(selected, conversation, active),
                    selected && conversation && active
                );
            }
        }
    }
}

#[::core::prelude::v1::test]
fn uncertain_read_notice_preserves_live_drafts_without_reopen_advice() {
    let notice = read_error_notice(&Error::PersistenceUncertain(
        "Read-state storage is unconfirmed".into(),
    ));
    assert!(notice.contains("Live drafts are preserved"));
    assert!(notice.contains("new output remains blocked"));
    assert!(!notice.to_lowercase().contains("reopen"));
    assert!(!notice.to_lowercase().contains("restart"));
}

#[gpui::test]
fn catalog_lock_failure_has_bounded_read_writer_retries(cx: &mut TestAppContext) {
    let (_dir, _window, root) = fixture(cx);
    let workspace = cx.read(|cx| root.read(cx).workspace.clone());
    let poisoned = workspace.clone();
    assert!(
        std::thread::spawn(move || {
            let _guard = poisoned.lock().unwrap();
            panic!("injected catalog mutex poison");
        })
        .join()
        .is_err()
    );
    root.update(cx, |view, cx| {
        let record = view.record.clone();
        view.read_states
            .lock()
            .unwrap()
            .apply(&record, ReadEvent::MarkUnread, true, false)
            .unwrap();
        view.flush_read_states(cx);
    });
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.read_write_inflight);
        let states = view.read_states.lock().unwrap();
        assert_eq!(states.failures, 3);
        assert!(states.entry(&view.record).unwrap().dirty);
        assert!(!view.close_ready);
    });
}

#[gpui::test]
fn chained_catalog_uncertainty_rejects_same_project_replacement_workspace(cx: &mut TestAppContext) {
    let (dir, _window, root) = fixture(cx);
    root.update(cx, |view, cx| {
        let previous = view.workspace.clone();
        let draft = view.composer.read(cx).text().to_owned();
        let replacement = Arc::new(Mutex::new(
            WorkspaceStore::open(dir.path().join("replacement-catalog.json"), &view.project)
                .unwrap(),
        ));
        view.workspace = replacement.clone();
        // Both rejected-Send recovery and Cancel settlement use this exact
        // adoption boundary before observing their captured outcome.
        assert!(!view.observe_bound_catalog_uncertainty(&previous, true, cx));
        assert!(!view.known_catalog_uncertainty);
        assert_eq!(view.composer.read(cx).text(), draft);
        assert!(view.observe_bound_catalog_uncertainty(&replacement, true, cx));
        assert!(view.known_catalog_uncertainty);
        assert_eq!(view.composer.read(cx).text(), draft);
    });
}
