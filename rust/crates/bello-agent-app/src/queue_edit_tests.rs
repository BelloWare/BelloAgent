//! Fake-platform reconciliation; storage faults are exercised in core tests.
use super::*;
use crate::LaunchState;
use bello_agent_core::{
    Lane, SessionStore, Submission,
    workspace::{ChatRecord, DraftRecord, QueuedDraft, WorkspaceStore},
};
use gpui::{Entity, EntityInputHandler, Focusable, TestAppContext, WindowHandle};
use std::sync::Mutex;

fn fixture(
    cx: &mut TestAppContext,
    resolved: bool,
    text: String,
    rewrite: String,
    revision: u64,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
    String,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let path = project.join("session.json");
    let mut store = SessionStore::open(&path).unwrap();
    let turn = Submission::new("original queued text".into(), Lane::FollowUp);
    let turn_id = turn.id.clone();
    store
        .transact(|session| {
            session.pending.push(turn);
            session.queue_paused = true;
            session.begin_edit(&turn_id, "edit-fixture")?;
            if resolved {
                session.resolve_edit("edit-fixture", "cancelled", None)?;
            }
            Ok(())
        })
        .unwrap();
    let record = ChatRecord::new(store.snapshot().id, "Recovery fixture".into(), path);
    let draft = DraftRecord {
        revision,
        text,
        queued_edit: Some(QueuedDraft {
            edit_id: "edit-fixture".into(),
            turn_id,
            rewrite,
            original_text: Some("original queued text".into()),
        }),
    };
    let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project).unwrap();
    workspace.register(record.clone(), draft.clone()).unwrap();
    let id = record.id.clone();
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        project,
        workspace: Arc::new(Mutex::new(workspace)),
        record,
        draft,
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    (dir, window, root, id)
}

#[gpui::test]
fn edit_recovery_uses_certain_actor_status_instead_of_cached_hold_absence(cx: &mut TestAppContext) {
    let (_dir, _window, root, _) = fixture(
        cx,
        false,
        "ordinary draft".into(),
        "unsaved rewrite".into(),
        5,
    );
    root.update(cx, |view, _| {
        Arc::make_mut(&mut view.session).edit = None;
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert_eq!(view.editing.as_deref(), Some("edit-fixture"));
        assert_eq!(view.composer.read(cx).text(), "unsaved rewrite");
        assert_eq!(view.draft_before_edit, "ordinary draft");
        assert_eq!(view.draft_revision, 5);
        assert!(!view.edit_recovery.blocked);
        assert!(view.queue_operation.is_none());
    });
}

#[gpui::test]
fn edit_recovery_merges_latest_rewrite_only_after_authoritative_resolution(
    cx: &mut TestAppContext,
) {
    let (_dir, _window, root, _) = fixture(
        cx,
        true,
        "ordinary draft".into(),
        "unsaved rewrite".into(),
        5,
    );
    // The stale presentation claims the hold remains active; it cannot prevent
    // or authorize settlement. Only the actor's typed answer is used.
    root.update(cx, |view, _| {
        let turn_id = view.queued_turn_id.clone().unwrap();
        let cached = Arc::make_mut(&mut view.session);
        cached.outcomes.clear();
        cached.begin_edit(&turn_id, "edit-fixture").unwrap();
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(view.editing.is_none());
        assert!(!view.edit_recovery.blocked);
        assert_eq!(
            view.composer.read(cx).text(),
            "unsaved rewrite\n\nordinary draft"
        );
        assert_eq!(view.draft_revision, 6);
        let draft = view.saved_draft(cx);
        assert!(draft.queued_edit.is_none());
    });
}

#[gpui::test]
fn edit_recovery_defers_replacement_until_unmark_notification_and_keeps_latest_text(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, _) = fixture(
        cx,
        true,
        "ordinary draft".into(),
        "unsaved rewrite".into(),
        5,
    );
    let mut marked = String::new();
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.focus(window);
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx);
            });
            marked = view.composer.read(cx).text().to_owned();
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert_eq!(view.editing.as_deref(), Some("edit-fixture"));
            assert!(view.edit_recovery.blocked);
            assert!(view.edit_recovery.deferred.is_some());
            assert_eq!(view.composer.read(cx).text(), marked);
            assert!(view.composer.read(cx).has_marked_text());
            view.resolve_edit("saved", cx);
            view.remove_queue(view.queued_turn_id.clone().unwrap(), cx);
            view.submit_chat(Lane::FollowUp, cx);
            assert!(!view.busy);
            view.composer
                .update(cx, |editor, cx| editor.unmark_text(window, cx));
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert!(view.editing.is_none());
            assert!(!view.edit_recovery.blocked);
            assert_eq!(
                view.composer.read(cx).text(),
                format!("{marked}\n\nordinary draft")
            );
            assert!(view.composer.read(cx).focus_handle(cx).is_focused(window));
        })
        .unwrap();
    assert!(cx.read(|cx| root.read(cx).queue_operation.is_none()));
}

#[gpui::test]
fn edit_recovery_failed_status_keeps_text_and_blocks_all_resolution_routes(
    cx: &mut TestAppContext,
) {
    let (_dir, _window, root, id) = fixture(
        cx,
        false,
        "ordinary draft".into(),
        "unsaved rewrite".into(),
        5,
    );
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        let check = Check {
            operation: Uuid::new_v4(),
            chat_id: id.clone(),
            edit_id: "edit-fixture".into(),
            project: view.project.clone(),
            controller: view.controller.clone(),
            binding: view.window_binding,
            owned_edit: view.editing.clone(),
        };
        view.queue_operation = Some(check.operation);
        view.edit_recovery.pending = Some(check.clone());
        view.finish_edit_reconciliation(check, Err("synthetic uncertain checkpoint".into()), cx);
        assert!(view.edit_recovery.blocked);
        assert!(view.queue_operation.is_none());
        assert_eq!(view.composer.read(cx).text(), "unsaved rewrite");
        let before = serde_json::to_value(view.controller.snapshot()).unwrap();
        view.resolve_edit("saved", cx);
        view.resolve_edit("cancelled", cx);
        view.remove_queue(view.queued_turn_id.clone().unwrap(), cx);
        view.resume_queued(&id, cx);
        view.submit_chat(Lane::FollowUp, cx);
        assert!(!view.busy);
        assert_eq!(
            serde_json::to_value(view.controller.snapshot()).unwrap(),
            before
        );
    });
}

#[gpui::test]
fn edit_recovery_overflow_preserves_owned_rewrite_and_displaced_draft(cx: &mut TestAppContext) {
    for (text, revision) in [
        ("x".repeat(262_144), 5),
        ("ordinary draft".into(), u64::MAX),
    ] {
        let (_dir, _window, root, _) =
            fixture(cx, true, text.clone(), "unsaved rewrite".into(), revision);
        cx.run_until_parked();
        root.update(cx, |view, cx| {
            assert!(view.edit_recovery.blocked);
            assert_eq!(view.editing.as_deref(), Some("edit-fixture"));
            assert_eq!(view.composer.read(cx).text(), "unsaved rewrite");
            assert_eq!(view.draft_before_edit, text);
            assert_eq!(view.draft_revision, revision);
            assert!(
                view.error
                    .as_deref()
                    .unwrap()
                    .contains("could not be applied")
            );
        });
    }
}

#[gpui::test]
fn edit_recovery_completion_stays_with_original_chat_and_rejects_old_controller(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, id) = fixture(
        cx,
        false,
        "ordinary draft".into(),
        "unsaved rewrite".into(),
        5,
    );
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            let check = Check {
                operation: Uuid::new_v4(),
                chat_id: id.clone(),
                edit_id: "edit-fixture".into(),
                project: view.project.clone(),
                controller: view.controller.clone(),
                binding: view.window_binding,
                owned_edit: view.editing.clone(),
            };
            let status = check.controller.edit_status(&check.edit_id).unwrap();
            view.queue_operation = Some(check.operation);
            view.edit_recovery.pending = Some(check.clone());
            view.edit_recovery.blocked = true;
            view.new_chat(window, cx);
            let selected = view.record.id.clone();
            view.finish_edit_reconciliation(check.clone(), Ok(status.clone()), cx);
            assert_eq!(view.record.id, selected);
            assert!(!view.inactive[&id].edit_recovery.blocked);
            assert_eq!(
                view.inactive[&id].composer.read(cx).text(),
                "unsaved rewrite"
            );
            let chat = view.chat_mut(&id).unwrap();
            chat.replace_controller(Controller::new(SessionStore::pending(), None).unwrap(), cx);
            view.finish_edit_reconciliation(check, Err("old controller".into()), cx);
            assert!(view.inactive[&id].error.is_none());
            assert_eq!(view.record.id, selected);
        })
        .unwrap();
    assert!(cx.read(|cx| root.read(cx).composer.read(cx).text().is_empty()));
}

#[gpui::test]
fn edit_recovery_live_snapshot_resolution_is_checked_before_merging(cx: &mut TestAppContext) {
    let (_dir, _window, root, _) = fixture(
        cx,
        false,
        "ordinary draft".into(),
        "unsaved rewrite".into(),
        5,
    );
    cx.run_until_parked();
    root.update(cx, |view, _| {
        view.controller
            .resolve_edit("edit-fixture", "cancelled", None)
            .unwrap();
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(view.editing.is_none());
        assert!(!view.edit_recovery.blocked);
        assert_eq!(
            view.composer.read(cx).text(),
            "unsaved rewrite\n\nordinary draft"
        );
    });
}

#[gpui::test]
fn edit_recovery_definitive_save_and_held_remove_failures_can_retry_normally(
    cx: &mut TestAppContext,
) {
    for remove in [false, true] {
        let (dir, _window, root, _) = fixture(
            cx,
            false,
            "ordinary draft".into(),
            "unsaved rewrite".into(),
            5,
        );
        cx.run_until_parked();
        let path = dir.path().join("session.json");
        let backup = dir.path().join("snapshot-backup");
        let before = std::fs::read(&path).unwrap();
        std::fs::rename(&path, &backup).unwrap();
        std::fs::create_dir(&path).unwrap();
        root.update(cx, |view, cx| {
            if remove {
                view.remove_queue(view.queued_turn_id.clone().unwrap(), cx);
            } else {
                view.resolve_edit("saved", cx);
            }
        });
        cx.run_until_parked();
        root.update(cx, |view, cx| {
            assert_eq!(view.editing.as_deref(), Some("edit-fixture"));
            assert!(!view.busy);
            assert!(
                !view.edit_recovery.blocked,
                "definitive failure must not strand normal retry"
            );
            assert!(view.queue_operation.is_none());
            assert_eq!(view.composer.read(cx).text(), "unsaved rewrite");
        });
        assert_eq!(std::fs::read(&backup).unwrap(), before);
        std::fs::remove_dir(&path).unwrap(); // Only our own empty fixture collision.
        std::fs::rename(&backup, &path).unwrap();
        root.update(cx, |view, cx| {
            if remove {
                view.remove_queue(view.queued_turn_id.clone().unwrap(), cx);
            } else {
                view.resolve_edit("saved", cx);
            }
        });
        cx.run_until_parked();
        root.update(cx, |view, cx| {
            assert!(view.editing.is_none());
            assert!(!view.edit_recovery.blocked);
            assert_eq!(view.composer.read(cx).text(), "ordinary draft");
            let snapshot = view.controller.snapshot();
            if remove {
                assert!(snapshot.pending.is_empty());
            } else {
                assert_eq!(snapshot.pending[0].text, "unsaved rewrite");
            }
        });
    }
}

#[gpui::test]
fn edit_recovery_stale_window_reply_requeries_without_applying_old_status(cx: &mut TestAppContext) {
    let (_dir, window, root, id) = fixture(
        cx,
        false,
        "ordinary draft".into(),
        "unsaved rewrite".into(),
        5,
    );
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            let check = Check {
                operation: Uuid::new_v4(),
                chat_id: id.clone(),
                edit_id: "edit-fixture".into(),
                project: view.project.clone(),
                controller: view.controller.clone(),
                binding: view.window_binding,
                owned_edit: view.editing.clone(),
            };
            view.queue_operation = Some(check.operation);
            view.edit_recovery.pending = Some(check.clone());
            view.edit_recovery.blocked = true;
            view.window_binding = Some(crate::workspace_lifetime::WindowBinding::new(
                window.window_handle().window_id(),
            ));
            let old_status = QueueEditStatus {
                edit_id: "edit-fixture".into(),
                current_hold: None,
                session_revision: view.session.revision,
                state: bello_agent_core::QueueEditState::Cancelled,
            };
            view.finish_edit_reconciliation(check, Ok(old_status), cx);
            assert_eq!(view.composer.read(cx).text(), "unsaved rewrite");
            assert_eq!(view.editing.as_deref(), Some("edit-fixture"));
        })
        .unwrap();
    cx.run_until_parked();
    assert!(cx.read(|cx| !root.read(cx).edit_recovery.blocked));
    assert_eq!(
        cx.read(|cx| root.read(cx).editing.clone()),
        Some("edit-fixture".into())
    );
}

#[gpui::test]
fn edit_recovery_newer_stop_failure_invalidates_deferred_success_before_unmark(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, id) = fixture(
        cx,
        false,
        "ordinary draft".into(),
        "unsaved rewrite".into(),
        5,
    );
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx)
            });
            let check = Check {
                operation: Uuid::new_v4(),
                chat_id: id.clone(),
                edit_id: "edit-fixture".into(),
                project: view.project.clone(),
                controller: view.controller.clone(),
                binding: view.window_binding,
                owned_edit: view.editing.clone(),
            };
            view.queue_operation = Some(check.operation);
            view.edit_recovery.pending = Some(check.clone());
            view.edit_recovery.blocked = true;
            let stale = QueueEditStatus {
                edit_id: check.edit_id.clone(),
                current_hold: None,
                session_revision: view.session.revision,
                state: bello_agent_core::QueueEditState::Cancelled,
            };
            view.finish_edit_reconciliation(check.clone(), Ok(stale.clone()), cx);
            assert!(view.edit_recovery.deferred.is_some());
            let marked = view.composer.read(cx).text().to_owned();
            // A synthetic command error establishes the callback ordering. Core
            // fault tests separately prove truly poisoned status returns an error.
            view.result(
                Err(bello_agent_core::Error::PersistenceUncertain(
                    "synthetic later Stop failure".into(),
                )),
                cx,
            );
            assert_ne!(view.queue_operation, Some(check.operation));
            assert!(view.edit_recovery.deferred.is_none());
            view.finish_edit_reconciliation(check, Ok(stale), cx);
            assert_eq!(view.composer.read(cx).text(), marked);
            view.composer
                .update(cx, |editor, cx| editor.unmark_text(window, cx));
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        // The new read observes the real Active hold, so the old terminal read
        // cannot erase ownership or merge the ordinary draft.
        assert_eq!(view.editing.as_deref(), Some("edit-fixture"));
        assert!(!view.edit_recovery.blocked);
        assert!(!view.composer.read(cx).text().contains("ordinary draft"));
        assert_eq!(view.draft_before_edit, "ordinary draft");
    });
}

#[gpui::test]
fn edit_recovery_successful_save_completion_drains_newer_stop_failure(cx: &mut TestAppContext) {
    let (_dir, _window, root, _) = fixture(
        cx,
        false,
        "ordinary draft".into(),
        "unsaved rewrite".into(),
        5,
    );
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        view.resolve_edit("saved", cx);
        assert!(view.busy);
        view.result(
            Err(bello_agent_core::Error::PersistenceUncertain(
                "synthetic Stop failure while Save callback is pending".into(),
            )),
            cx,
        );
        assert!(view.edit_recovery.blocked);
        assert!(view.edit_recovery.requested.is_some());
        assert!(view.edit_recovery.pending.is_none());
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(!view.busy);
        assert!(!view.edit_recovery.blocked);
        assert!(view.edit_recovery.requested.is_none());
        assert!(view.editing.is_none());
        assert_eq!(view.composer.read(cx).text(), "ordinary draft");
        assert_eq!(
            view.controller.snapshot().pending[0].text,
            "unsaved rewrite"
        );
    });
}

#[gpui::test]
fn edit_recovery_rejected_submission_settlement_drains_unowned_hold_status(
    cx: &mut TestAppContext,
) {
    let (_dir, _window, root, _) = fixture(
        cx,
        false,
        "ordinary draft".into(),
        "unsaved rewrite".into(),
        5,
    );
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        // Presentation with an unowned hold, as a crash before adoption can leave.
        view.editing = None;
        view.queued_turn_id = None;
        view.queued_original = None;
        view.draft_before_edit.clear();
        view.composer.update(cx, |editor, cx| {
            editor.set_text("ordinary draft".into(), cx)
        });
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        view.submit_chat(Lane::FollowUp, cx); // No connection: definitive rejection.
        assert!(view.busy);
        view.result(
            Err(bello_agent_core::Error::PersistenceUncertain(
                "synthetic Stop failure while submission callback is pending".into(),
            )),
            cx,
        );
        assert!(view.edit_recovery.blocked);
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(!view.busy);
        assert!(!view.edit_recovery.blocked);
        assert!(view.edit_recovery.requested.is_none());
        assert!(view.editing.is_none());
        assert_eq!(view.composer.read(cx).text(), "ordinary draft");
        assert!(view.controller.snapshot().edit.is_some());
        assert!(view.inflight_submission.is_none());
    });
}
