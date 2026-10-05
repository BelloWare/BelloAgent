//! Real GPUI entity/window tests with a fake platform. Direct window removal
//! below models ownership detachment only; production Close still shuts down.
use super::WorkspaceLifetime;
use crate::{AgentView, FileTabEvent, LaunchState, QuickOpenEvent};
use bello_agent_core::{
    Controller, SessionStore,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
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
