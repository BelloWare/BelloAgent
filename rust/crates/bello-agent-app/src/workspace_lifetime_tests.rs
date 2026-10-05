//! Real GPUI entity/window tests with a fake platform. Direct window removal
//! below models ownership detachment only; production Close still shuts down.
use super::WorkspaceLifetime;
use crate::{AgentView, FileTabEvent, LaunchState, QuickOpenEvent};
use bello_agent_core::{
    Controller, SessionStore,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
#[cfg(not(target_os = "macos"))]
use gpui::Focusable;
use gpui::{Entity, TestAppContext, VisualTestContext, WindowHandle};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};

fn fixture(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let directory = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(directory.path()).unwrap();
    let store = SessionStore::pending();
    let snapshot = store.snapshot();
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        project: project.clone(),
        workspace: Arc::new(Mutex::new(
            WorkspaceStore::open(project.join("session.workspace.json"), &project).unwrap(),
        )),
        record: ChatRecord {
            sidebar_order: None,
            pinned_at: None,
            id: snapshot.id,
            title: snapshot.title,
            snapshot: project.join("session.json"),
        },
        draft: DraftRecord::default(),
        pending: true,
    };
    let window = cx
        .update(|cx| WorkspaceLifetime::launch(launch, cx))
        .unwrap();
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    (directory, window, root)
}

fn detach(window: WindowHandle<AgentView>, cx: &mut TestAppContext) {
    // This deliberately bypasses request_close: ownership and policy are
    // separate. The current real close policy is checked in another test.
    window
        .update(cx, |_, window, _| window.remove_window())
        .unwrap();
    cx.run_until_parked();
}

#[gpui::test]
fn retains_real_chat_entity_draft_and_undo_across_detach(cx: &mut TestAppContext) {
    let (_dir, first, root) = fixture(cx);
    let composer = cx.read(|cx| root.read(cx).composer.clone());
    let controller = cx.read(|cx| root.read(cx).controller.clone());
    cx.simulate_input(first.into(), "draft");
    assert_eq!(cx.read(|cx| composer.read(cx).text().to_owned()), "draft");
    let releases = Arc::new(AtomicUsize::new(0));
    let observed = releases.clone();
    let _release = root.update(cx, |_, cx| {
        cx.on_release(move |_, _| {
            observed.fetch_add(1, Ordering::SeqCst);
        })
    });
    let root_id = root.entity_id();
    let weak = root.downgrade();
    drop(root); // The app owner must be the remaining strong parent reference.
    detach(first, cx);
    assert!(weak.upgrade().is_some());
    assert_eq!(releases.load(Ordering::SeqCst), 0);
    assert!(cx.read(|cx| cx.windows().is_empty()));
    let second = cx.update(WorkspaceLifetime::ensure_window).unwrap();
    cx.run_until_parked();
    assert_ne!(first.window_id(), second.window_id());
    let root = second.root(cx).unwrap();
    assert_eq!(root.entity_id(), root_id);
    assert_eq!(
        cx.read(|cx| root.read(cx).composer.entity_id()),
        composer.entity_id()
    );
    assert!(cx.read(|cx| Arc::ptr_eq(&root.read(cx).controller, &controller)));
    assert_eq!(cx.read(|cx| composer.read(cx).text().to_owned()), "draft");
    cx.simulate_keystrokes(second.into(), "cmd-z");
    assert_ne!(cx.read(|cx| composer.read(cx).text().to_owned()), "draft");
    assert_eq!(releases.load(Ordering::SeqCst), 0);
}

#[gpui::test]
fn one_window_and_stale_close_generation_are_preserved(cx: &mut TestAppContext) {
    let (_dir, first, root) = fixture(cx);
    let original_binding = cx.read(|cx| root.read(cx).window_binding.unwrap());
    assert_eq!(cx.update(WorkspaceLifetime::ensure_window).unwrap(), first);
    assert_eq!(
        cx.read(|cx| root.read(cx).window_binding.unwrap()),
        original_binding
    );
    detach(first, cx);
    let second = cx.update(WorkspaceLifetime::ensure_window).unwrap();
    assert_ne!(
        cx.read(|cx| root.read(cx).window_binding.unwrap()),
        original_binding
    );
    // A queued callback from the old window cannot shut down the new binding.
    second
        .update(cx, |view, window, cx| {
            assert!(view.request_close_for(original_binding, window, cx));
            assert!(!view.shutting_down);
            assert!(!view.close_dialog);
        })
        .unwrap();
    assert_eq!(cx.update(WorkspaceLifetime::ensure_window).unwrap(), second);
    assert_eq!(cx.read(|cx| cx.windows().len()), 1);
}

#[gpui::test]
fn unsaved_file_undo_and_both_window_scoped_subscriptions_survive_detach(cx: &mut TestAppContext) {
    let (dir, first, root) = fixture(cx);
    let path = dir.path().join("one.txt");
    let other = dir.path().join("two.txt");
    std::fs::write(&path, "original").unwrap();
    std::fs::write(&other, "second").unwrap();
    first
        .update(cx, |view, window, cx| {
            view.open_file(path.clone(), None, window, cx)
        })
        .unwrap();
    cx.run_until_parked();
    let file = cx.read(|cx| root.read(cx).files[0].view.clone());
    cx.simulate_input(first.into(), "X");
    assert!(cx.read(|cx| file.read(cx).is_dirty(cx)));
    assert!(cx.read(|cx| root.read(cx).files[0].dirty));
    detach(first, cx);
    let second = cx.update(WorkspaceLifetime::ensure_window).unwrap();
    cx.run_until_parked();
    assert_eq!(
        cx.read(|cx| root.read(cx).files[0].view.entity_id()),
        file.entity_id()
    );
    assert!(cx.read(|cx| file.read(cx).is_dirty(cx)));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "original");
    cx.simulate_keystrokes(second.into(), "cmd-z");
    assert!(!cx.read(|cx| file.read(cx).is_dirty(cx)));
    // Changed must reach the parent through the replacement window binding.
    assert!(!cx.read(|cx| root.read(cx).files[0].dirty));
    let quick = cx.read(|cx| root.read(cx).quick_open.clone());
    quick.update(cx, |_, cx| {
        cx.emit(QuickOpenEvent::Open {
            path: other.clone(),
            line: None,
        })
    });
    cx.run_until_parked();
    assert_eq!(cx.read(|cx| root.read(cx).files.len()), 2);
    assert!(cx.read(|cx| root.read(cx).files.iter().any(|entry| entry.path == other)));
    // CloseReady must also reach the replacement window rather than a dead one.
    file.update(cx, |_, cx| cx.emit(FileTabEvent::CloseReady));
    cx.run_until_parked();
    assert_eq!(cx.read(|cx| root.read(cx).files.len()), 1);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "original");
}

#[gpui::test]
fn existing_close_still_flushes_and_blocks_reattach_after_shutdown(cx: &mut TestAppContext) {
    let (_dir, first, root) = fixture(cx);
    cx.simulate_input(first.into(), "saved draft");
    let mut visual = VisualTestContext::from_window(first.into(), cx);
    assert!(!visual.simulate_close()); // Existing asynchronous close owns removal.
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).close_ready));
    assert!(cx.read(|cx| cx.windows().is_empty()));
    assert!(cx.update(WorkspaceLifetime::ensure_window).is_err());
    let saved = cx.read(|cx| {
        let view = root.read(cx);
        view.workspace.lock().unwrap().snapshot().drafts[&view.record.id]
            .text
            .clone()
    });
    assert_eq!(saved, "saved draft");
}

#[gpui::test]
fn save_failure_keeps_current_window_draft_and_retryable_close(cx: &mut TestAppContext) {
    let (dir, first, root) = fixture(cx);
    cx.simulate_input(first.into(), "keep");
    let destination = dir.path().join("session.workspace.json");
    // Disposable fixture collision forces atomic rename to fail, not a user file.
    std::fs::create_dir(&destination).unwrap();
    let mut visual = VisualTestContext::from_window(first.into(), cx);
    assert!(!visual.simulate_close());
    cx.run_until_parked();
    assert_eq!(cx.read(|cx| cx.windows().len()), 1);
    assert!(cx.read(|cx| {
        root.read(cx)
            .error
            .as_ref()
            .unwrap()
            .contains("Could not save drafts")
    }));
    assert!(!cx.read(|cx| root.read(cx).shutting_down));
    assert_eq!(cx.update(WorkspaceLifetime::ensure_window).unwrap(), first);
    cx.simulate_input(first.into(), "!");
    assert_eq!(
        cx.read(|cx| root.read(cx).composer.read(cx).text().to_owned()),
        "keep!"
    );
    std::fs::remove_dir(destination).unwrap();
    assert!(!visual.simulate_close());
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).close_ready));
    assert!(cx.read(|cx| cx.windows().is_empty()));
}

#[gpui::test]
fn app_shutdown_releases_retained_workspace_at_the_original_cleanup_boundary(
    cx: &mut TestAppContext,
) {
    let (_dir, _window, root) = fixture(cx);
    let releases = Arc::new(AtomicUsize::new(0));
    let observed = releases.clone();
    let _release = root.update(cx, |_, cx| {
        cx.on_release(move |_, _| {
            observed.fetch_add(1, Ordering::SeqCst);
        })
    });
    let weak = root.downgrade();
    drop(root);
    cx.update(|cx| cx.shutdown());
    assert!(!cx.read(|cx| cx.has_global::<WorkspaceLifetime>()));
    assert!(cx.read(|cx| cx.windows().is_empty()));
    assert!(weak.upgrade().is_none());
    assert_eq!(releases.load(Ordering::SeqCst), 1);
    cx.update(|cx| cx.shutdown());
    assert_eq!(releases.load(Ordering::SeqCst), 1);
}

#[gpui::test]
fn detached_save_failure_still_thaws_retained_workspace_and_reopens(cx: &mut TestAppContext) {
    let (dir, first, root) = fixture(cx);
    cx.simulate_input(first.into(), "keep detached");
    std::fs::create_dir(dir.path().join("session.workspace.json")).unwrap();
    first
        .update(cx, |view, window, cx| {
            view.begin_shutdown(window, cx);
            let operation = view.shutdown_operation;
            view.begin_shutdown(window, cx);
            assert_eq!(view.shutdown_operation, operation); // Duplicate close is idempotent.
            window.remove_window();
        })
        .unwrap();
    cx.run_until_parked();
    assert!(!cx.read(|cx| root.read(cx).shutting_down));
    assert!(cx.read(|cx| root.read(cx).shutdown_operation.is_none()));
    assert!(cx.read(|cx| {
        root.read(cx)
            .error
            .as_ref()
            .unwrap()
            .contains("Could not save drafts")
    }));
    let second = cx.update(WorkspaceLifetime::ensure_window).unwrap();
    cx.run_until_parked();
    cx.simulate_input(second.into(), "!");
    assert_eq!(
        cx.read(|cx| root.read(cx).composer.read(cx).text().to_owned()),
        "keep detached!"
    );
}

#[gpui::test]
fn stale_barrier_outcome_cannot_thaw_or_mark_new_operation_complete(cx: &mut TestAppContext) {
    let (_dir, _first, root) = fixture(cx);
    let current = uuid::Uuid::new_v4();
    root.update(cx, |view, cx| {
        view.shutting_down = true;
        view.shutdown_operation = Some(current);
        let id = view.record.id.clone();
        assert!(!view.finish_shutdown(
            uuid::Uuid::new_v4(),
            crate::shutdown_barrier::ShutdownOutcome {
                registered: vec![id],
                result: Err("stale failure".into()),
            },
            cx
        ));
        assert!(view.pending);
        assert!(view.shutting_down);
        assert_eq!(view.shutdown_operation, Some(current));
        assert!(view.error.is_none());
        assert!(!view.close_ready);
    });
}

#[gpui::test]
fn successful_barrier_cannot_remove_a_rebound_window_generation(cx: &mut TestAppContext) {
    let (_dir, first, root) = fixture(cx);
    first
        .update(cx, |view, window, cx| {
            view.begin_shutdown(window, cx);
            // Model a newer native binding before the old completion is delivered.
            view.bind_window(window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).close_ready));
    assert_eq!(cx.read(|cx| cx.windows().len()), 1);
}

#[cfg(not(target_os = "macos"))]
#[gpui::test]
fn pin_context_menu_keeps_other_chat_selection_focus_and_draft(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    cx.simulate_input(window.into(), "first draft");
    let first_id = cx.read(|cx| root.read(cx).record.id.clone());
    window
        .update(cx, |view, window, cx| view.new_chat(window, cx))
        .unwrap();
    cx.run_until_parked();
    let second_id = cx.read(|cx| root.read(cx).record.id.clone());
    assert_ne!(first_id, second_id);
    window
        .update(cx, |view, window, cx| {
            view.open_sidebar_menu(
                &first_id,
                gpui::point(gpui::px(80.), gpui::px(150.)),
                window,
                cx,
            )
        })
        .unwrap();
    assert_eq!(cx.read(|cx| root.read(cx).record.id.clone()), second_id);
    cx.simulate_keystrokes(window.into(), "x");
    assert!(cx.read(|cx| root.read(cx).composer.read(cx).text().is_empty()));
    cx.simulate_keystrokes(window.into(), "escape");
    assert!(cx.read(|cx| root.read(cx).sidebar_menu.is_none()));
    assert!(cx.read(|cx| root.read(cx).pin_operations.is_empty()));
    window
        .update(cx, |view, window, cx| {
            assert!(view.composer.read(cx).focus_handle(cx).is_focused(window));
            view.open_sidebar_menu(
                &first_id,
                gpui::point(gpui::px(80.), gpui::px(150.)),
                window,
                cx,
            );
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), "enter");
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.record.id, second_id);
        assert!(view.composer.read(cx).text().is_empty());
        assert!(
            view.records
                .iter()
                .find(|record| record.id == first_id)
                .unwrap()
                .pinned_at
                .is_some()
        );
        assert_eq!(
            view.inactive[&first_id].composer.read(cx).text(),
            "first draft"
        );
        assert!(!view.inactive[&first_id].pending);
    });
}

#[gpui::test]
fn pending_pin_survives_navigation_and_does_not_steal_new_chat(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    let original = cx.read(|cx| root.read(cx).record.id.clone());
    window
        .update(cx, |view, window, cx| {
            view.set_chat_pinned(&original, true, cx);
            let token = view.pin_operations[&original];
            view.set_chat_pinned(&original, false, cx);
            assert_eq!(view.pin_operations[&original], token);
            view.new_chat(window, cx);
            assert_ne!(view.record.id, original);
        })
        .unwrap();
    let next = cx.read(|cx| root.read(cx).record.id.clone());
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.record.id, next);
        assert!(view.records.iter().any(|record| record.id == original));
        assert!(!view.inactive[&original].pending);
        let state = view.workspace.lock().unwrap().snapshot();
        assert!(
            state
                .chats
                .iter()
                .any(|record| record.id == original && record.pinned_at.is_some())
        );
        assert!(!state.chats.iter().any(|record| record.id == next));
    });
}

#[gpui::test]
fn failed_pin_keeps_pending_draft_editable_and_retry_succeeds(cx: &mut TestAppContext) {
    let (dir, window, root) = fixture(cx);
    cx.simulate_input(window.into(), "keep pin draft");
    let collision = dir.path().join("session.workspace.json");
    std::fs::create_dir(&collision).unwrap();
    window
        .update(cx, |view, _, cx| {
            view.set_chat_pinned(&view.record.id.clone(), true, cx)
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.pending);
        assert!(view.record.pinned_at.is_none());
        assert!(view.pin_operations.is_empty());
        assert!(
            view.error
                .as_ref()
                .unwrap()
                .contains("Chat pin could not be saved")
        );
    });
    cx.simulate_input(window.into(), "!");
    std::fs::remove_dir(collision).unwrap();
    window
        .update(cx, |view, _, cx| {
            view.set_chat_pinned(&view.record.id.clone(), true, cx)
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.pending);
        assert!(view.record.pinned_at.is_some());
        assert!(
            view.error.is_none(),
            "successful retry must clear its stale pin error"
        );
        assert_eq!(view.composer.read(cx).text(), "keep pin draft!");
        assert_eq!(
            view.workspace.lock().unwrap().snapshot().drafts[&view.record.id].text,
            "keep pin draft!"
        );
    });
}

#[gpui::test]
fn stale_pin_completion_cannot_replace_title_or_project_and_close_waits(cx: &mut TestAppContext) {
    let (_dir, window, _root) = fixture(cx);
    window
        .update(cx, |view, window, cx| {
            let id = view.record.id.clone();
            let project = view.project.clone();
            let operation = uuid::Uuid::new_v4();
            view.pin_operations.insert(id.clone(), operation);
            let mut saved = view.record.clone();
            saved.pinned_at = Some(10);
            saved.title = "stale title".into();
            view.record.title = "latest title".into();
            view.records[0].title = "latest title".into();
            view.finish_pin(&id, &project, uuid::Uuid::new_v4(), Ok(saved.clone()), cx);
            assert!(view.record.pinned_at.is_none());
            view.finish_pin(
                &id,
                &project.join("other-project"),
                operation,
                Ok(saved.clone()),
                cx,
            );
            assert!(view.record.pinned_at.is_none());
            view.begin_shutdown(window, cx);
            assert!(!view.shutting_down);
            assert!(
                view.error
                    .as_ref()
                    .unwrap()
                    .contains("Wait for chat operations")
            );
            view.finish_pin(&id, &project, operation, Ok(saved), cx);
            assert!(view.pin_operations.is_empty());
            assert_eq!(view.record.pinned_at, Some(10));
            assert_eq!(view.record.title, "latest title");
            assert_eq!(view.records[0].title, "latest title");
        })
        .unwrap();
}

#[gpui::test]
fn edits_during_pending_pin_are_durable_after_idle_even_after_navigation(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    let original = cx.read(|cx| root.read(cx).record.id.clone());
    window
        .update(cx, |view, window, cx| {
            view.set_chat_pinned(&original, true, cx); // Captures the empty pending draft.
            view.composer.update(cx, |editor, cx| {
                editor.set_text("typed while pinning 你好".into(), cx)
            });
            view.draft_changed(&original, cx);
            view.new_chat(window, cx);
        })
        .unwrap();
    let selected = cx.read(|cx| root.read(cx).record.id.clone());
    assert_ne!(selected, original);
    cx.run_until_parked();
    cx.executor()
        .advance_clock(std::time::Duration::from_millis(200));
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.record.id, selected);
        assert_eq!(
            view.inactive[&original].composer.read(cx).text(),
            "typed while pinning 你好"
        );
        let saved = view.workspace.lock().unwrap().snapshot();
        assert_eq!(saved.drafts[&original].text, "typed while pinning 你好");
        assert!(saved.drafts[&original].revision > 0);
    });
}

#[gpui::test]
fn successful_pin_does_not_clear_a_newer_unrelated_error(cx: &mut TestAppContext) {
    let (_dir, window, _root) = fixture(cx);
    window
        .update(cx, |view, _, cx| {
            let id = view.record.id.clone();
            let project = view.project.clone();
            let first = uuid::Uuid::new_v4();
            view.pin_operations.insert(id.clone(), first);
            view.finish_pin(&id, &project, first, Err("old pin failure".into()), cx);
            assert!(view.error.as_ref().unwrap().contains("old pin failure"));
            view.error = Some("newer unrelated failure".into());
            let retry = uuid::Uuid::new_v4();
            view.pin_operations.insert(id.clone(), retry);
            let mut saved = view.record.clone();
            saved.pinned_at = Some(4);
            view.finish_pin(&id, &project, retry, Ok(saved), cx);
            assert_eq!(view.error.as_deref(), Some("newer unrelated failure"));
        })
        .unwrap();
}

#[gpui::test]
fn successful_pin_does_not_clear_another_targets_identical_error(cx: &mut TestAppContext) {
    let (_dir, window, _root) = fixture(cx);
    window
        .update(cx, |view, _, cx| {
            let id = view.record.id.clone();
            let project = view.project.clone();
            let other = uuid::Uuid::new_v4().to_string();
            for target in [&id, &other] {
                let operation = uuid::Uuid::new_v4();
                view.pin_operations.insert(target.clone(), operation);
                view.finish_pin(
                    target,
                    &project,
                    operation,
                    Err("same storage failure".into()),
                    cx,
                );
            }
            let retry = uuid::Uuid::new_v4();
            view.pin_operations.insert(id.clone(), retry);
            let mut saved = view.record.clone();
            saved.pinned_at = Some(4);
            view.finish_pin(&id, &project, retry, Ok(saved), cx);
            assert_eq!(
                view.error.as_deref(),
                Some("Chat pin could not be saved: same storage failure")
            );
        })
        .unwrap();
}

fn navigation_key(forward: bool) -> &'static str {
    match (cfg!(target_os = "macos"), forward) {
        (true, true) => "cmd-alt-down",
        (true, false) => "cmd-alt-up",
        (false, true) => "ctrl-alt-down",
        (false, false) => "ctrl-alt-up",
    }
}

fn add_navigation_records(window: WindowHandle<AgentView>, cx: &mut TestAppContext) -> Vec<String> {
    window
        .update(cx, |view, _, cx| {
            let mut ids = Vec::new();
            for (title, order, pin) in [
                ("Alpha", 10, None),
                ("Beta", 20, None),
                ("Gamma", 30, Some(1)),
            ] {
                let id = uuid::Uuid::new_v4().to_string();
                let record = ChatRecord {
                    id: id.clone(),
                    title: title.into(),
                    snapshot: view.project.join(format!("{id}.json")),
                    sidebar_order: Some(order),
                    pinned_at: pin,
                };
                let draft = DraftRecord {
                    text: format!("{title} draft"),
                    ..Default::default()
                };
                view.workspace
                    .lock()
                    .unwrap()
                    .register(record.clone(), draft.clone())
                    .unwrap();
                view.unloaded_drafts.insert(id.clone(), draft);
                view.records.push(record);
                ids.push(id);
            }
            cx.notify();
            ids
        })
        .unwrap()
}

#[gpui::test]
fn adjacent_chat_uses_visible_pin_order_and_clamps_endpoints(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    let ids = add_navigation_records(window, cx);
    // Pending initial chat is newer than the legacy records. Select first pin.
    window
        .update(cx, |view, window, cx| view.select_chat(&ids[2], window, cx))
        .unwrap();
    cx.run_until_parked();
    cx.simulate_keystrokes(window.into(), navigation_key(false));
    assert_eq!(cx.read(|cx| root.read(cx).record.id.clone()), ids[2]);
    cx.simulate_keystrokes(window.into(), navigation_key(true));
    assert_eq!(cx.read(|cx| root.read(cx).record.id.clone()), ids[1]);
    cx.simulate_keystrokes(window.into(), navigation_key(true));
    assert_eq!(cx.read(|cx| root.read(cx).record.id.clone()), ids[0]);
    cx.simulate_keystrokes(window.into(), navigation_key(true));
    assert_eq!(cx.read(|cx| root.read(cx).record.id.clone()), ids[0]);
    cx.simulate_keystrokes(window.into(), navigation_key(false));
    assert_eq!(cx.read(|cx| root.read(cx).record.id.clone()), ids[1]);
}

#[gpui::test]
fn adjacent_chat_filter_missing_current_selects_first_or_last_and_empty_is_noop(
    cx: &mut TestAppContext,
) {
    let (_dir, window, _root) = fixture(cx);
    let ids = add_navigation_records(window, cx);
    // Use saved titles while unloaded, matching exactly what the sidebar renders.
    window
        .update(cx, |view, window, cx| {
            view.filter
                .update(cx, |editor, cx| editor.set_text("a".into(), cx));
            view.select_adjacent_chat(false, window, cx);
            assert_eq!(view.record.id, ids[0]);
        })
        .unwrap();
    window
        .update(cx, |view, window, cx| {
            view.filter
                .update(cx, |editor, cx| editor.set_text("Gamma".into(), cx));
            view.select_adjacent_chat(true, window, cx);
            assert_eq!(view.record.id, ids[2]);
            view.filter.update(cx, |editor, cx| {
                editor.set_text("no matching chat".into(), cx)
            });
            view.select_adjacent_chat(false, window, cx);
            assert_eq!(view.record.id, ids[2]);
        })
        .unwrap();
}

#[gpui::test]
fn adjacent_chat_preserves_pending_unicode_draft_and_rapid_lazy_selection(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    cx.simulate_input(window.into(), "pending e\u{301} 日本語");
    let pending = cx.read(|cx| root.read(cx).record.id.clone());
    let ids = add_navigation_records(window, cx);
    window
        .update(cx, |view, window, cx| {
            view.select_chat(&ids[2], window, cx);
            view.select_chat(&ids[0], window, cx);
            view.select_chat(&ids[1], window, cx);
            view.select_chat(&pending, window, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.record.id, pending);
        assert_eq!(view.composer.read(cx).text(), "pending e\u{301} 日本語");
        assert!(view.pending);
        for (id, text) in ids.iter().zip(["Alpha draft", "Beta draft", "Gamma draft"]) {
            assert_eq!(view.inactive[id].composer.read(cx).text(), text);
            assert!(!view.inactive[id].loading);
        }
    });
}

#[gpui::test]
fn adjacent_chat_modal_and_exact_modifier_routing(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    let ids = add_navigation_records(window, cx);
    let current = cx.read(|cx| root.read(cx).record.id.clone());
    window
        .update(cx, |view, _, _| view.close_dialog = true)
        .unwrap();
    cx.simulate_keystrokes(window.into(), navigation_key(false));
    assert_eq!(cx.read(|cx| root.read(cx).record.id.clone()), current);
    window
        .update(cx, |view, window, cx| {
            view.close_dialog = false;
            view.quick_open
                .update(cx, |picker, cx| picker.show(window, cx));
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), navigation_key(false));
    assert_eq!(cx.read(|cx| root.read(cx).record.id.clone()), current);
    cx.simulate_keystrokes(window.into(), "escape");
    let shifted = if cfg!(target_os = "macos") {
        "cmd-alt-shift-up"
    } else {
        "ctrl-alt-shift-up"
    };
    cx.simulate_keystrokes(window.into(), shifted);
    assert_eq!(cx.read(|cx| root.read(cx).record.id.clone()), current);
    #[cfg(not(target_os = "macos"))]
    {
        window
            .update(cx, |view, window, cx| {
                view.open_sidebar_menu(
                    &ids[0],
                    gpui::point(gpui::px(80.), gpui::px(150.)),
                    window,
                    cx,
                )
            })
            .unwrap();
        cx.simulate_keystrokes(window.into(), navigation_key(false));
        assert_eq!(cx.read(|cx| root.read(cx).record.id.clone()), current);
        cx.simulate_keystrokes(window.into(), "escape");
    }
    for key in ["up", "alt-up", "ctrl-up", "cmd-up", "cmd-ctrl-alt-up"] {
        cx.simulate_keystrokes(window.into(), key);
        assert_eq!(cx.read(|cx| root.read(cx).record.id.clone()), current);
    }
    let _ = ids;
}

#[gpui::test]
fn adjacent_chat_keeps_focused_composer_and_filter_composition(cx: &mut TestAppContext) {
    use gpui::{EntityInputHandler, Focusable};
    let (_dir, window, root) = fixture(cx);
    add_navigation_records(window, cx);
    let current = cx.read(|cx| root.read(cx).record.id.clone());
    for filter in [false, true] {
        window
            .update(cx, |view, window, cx| {
                let editor = if filter {
                    view.filter.clone()
                } else {
                    view.composer.clone()
                };
                editor.update(cx, |editor, cx| {
                    editor.focus(window);
                    editor.replace_and_mark_text_in_range(
                        None,
                        if filter { "a" } else { "あ" },
                        Some(1..1),
                        window,
                        cx,
                    );
                });
            })
            .unwrap();
        cx.simulate_keystrokes(window.into(), navigation_key(false));
        window
            .update(cx, |view, window, cx| {
                assert_eq!(view.record.id, current);
                let editor = if filter {
                    view.filter.clone()
                } else {
                    view.composer.clone()
                };
                assert!(editor.read(cx).has_marked_text());
                assert!(editor.read(cx).focus_handle(cx).is_focused(window));
                editor.update(cx, |editor, cx| editor.unmark_text(window, cx));
            })
            .unwrap();
    }
}

#[gpui::test]
fn adjacent_chat_does_not_bypass_dirty_file_close_prompt(cx: &mut TestAppContext) {
    let (dir, window, root) = fixture(cx);
    add_navigation_records(window, cx);
    let current = cx.read(|cx| root.read(cx).record.id.clone());
    let path = dir.path().join("guard.txt");
    std::fs::write(&path, "original").unwrap();
    window
        .update(cx, |view, window, cx| {
            view.open_file(path.clone(), None, window, cx)
        })
        .unwrap();
    cx.run_until_parked();
    cx.simulate_input(window.into(), "unsaved");
    let file = cx.read(|cx| root.read(cx).files[0].view.clone());
    file.update(cx, |view, cx| view.request_close(cx));
    cx.simulate_keystrokes(window.into(), navigation_key(false));
    cx.read(|cx| {
        assert_eq!(root.read(cx).record.id, current);
        assert!(file.read(cx).has_close_prompt());
        assert!(file.read(cx).is_dirty(cx));
    });
    cx.simulate_keystrokes(window.into(), "escape");
    assert!(!cx.read(|cx| file.read(cx).has_close_prompt()));
    cx.simulate_keystrokes(window.into(), navigation_key(false));
    assert_ne!(cx.read(|cx| root.read(cx).record.id.clone()), current);
    assert_eq!(std::fs::read_to_string(path).unwrap(), "original");
}

#[gpui::test]
fn adjacent_chat_preserves_file_ime_through_actual_root_routing(cx: &mut TestAppContext) {
    use gpui::{EntityInputHandler, Focusable};
    let (dir, window, root) = fixture(cx);
    add_navigation_records(window, cx);
    let current = cx.read(|cx| root.read(cx).record.id.clone());
    let path = dir.path().join("ime.txt");
    std::fs::write(&path, "original").unwrap();
    window
        .update(cx, |view, window, cx| {
            view.open_file(path, None, window, cx)
        })
        .unwrap();
    cx.run_until_parked();
    let editor = cx.read(|cx| root.read(cx).files[0].view.read(cx).editor_for_test());
    window
        .update(cx, |_, window, cx| {
            editor.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx)
            })
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), navigation_key(false));
    window
        .update(cx, |view, window, cx| {
            assert_eq!(view.record.id, current);
            assert!(editor.read(cx).has_marked_text());
            assert!(editor.read(cx).focus_handle(cx).is_focused(window));
            editor.update(cx, |editor, cx| editor.unmark_text(window, cx));
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), navigation_key(false));
    assert_ne!(cx.read(|cx| root.read(cx).record.id.clone()), current);
}
