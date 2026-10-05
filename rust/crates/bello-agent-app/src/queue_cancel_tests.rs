//! Fake-platform reconciliation; storage faults are exercised in core tests.
use super::*;
use crate::LaunchState;
use bello_agent_core::{
    Lane, SessionStore, Submission,
    workspace::{ChatRecord, DraftRecord, QueuedDraft, WorkspaceStore},
};
use gpui::{Entity, TestAppContext, WindowHandle};
use std::sync::Mutex;

fn fixture(
    cx: &mut TestAppContext,
    pending: bool,
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
    if pending {
        let edit = draft.queued_edit.as_ref().unwrap();
        workspace
            .prepare_queued_cancel(
                &record.id,
                QueuedCancelReceipt::pending(0, edit.edit_id.clone(), edit.turn_id.clone())
                    .unwrap(),
                draft.clone(),
            )
            .unwrap();
    }
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
fn durable_cancel_owned_discards_rewrite_after_receipt_settlement(cx: &mut TestAppContext) {
    let (_dir, _window, root, id) = fixture(
        cx,
        false,
        false,
        "ordinary 🦀 é".into(),
        "rewrite 漢字".into(),
        5,
    );
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(v.can_cancel_owned_edit());
        v.cancel_owned_edit(&id, cx);
        assert!(v.busy);
        assert!(v.queue_operation.is_some());
        assert_eq!(v.composer.read(cx).text(), "rewrite 漢字");
    });
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), "ordinary 🦀 é");
        assert!(v.editing.is_none());
        assert!(!v.busy);
        assert!(!v.edit_recovery.blocked);
        assert!(!v.has_pending_cancel(&id));
        assert_eq!(
            v.controller.edit_status("edit-fixture").unwrap().state,
            QueueEditState::Cancelled
        );
        let saved = v.workspace.lock().unwrap().snapshot();
        assert!(matches!(
            saved.queued_cancellations[&id].state,
            QueuedCancelState::Settled
        ));
        assert_eq!(saved.drafts[&id].text, "ordinary 🦀 é");
        assert!(saved.drafts[&id].queued_edit.is_none());
    });
}

#[gpui::test]
fn durable_cancel_restart_retries_and_preserves_unowned_rewrite(cx: &mut TestAppContext) {
    let (_dir, _window, root, id) = fixture(
        cx,
        true,
        false,
        "ordinary 🦀 é".into(),
        "rewrite 漢字".into(),
        5,
    );
    root.update(cx, |v, cx| {
        assert!(v.editing.is_none());
        assert_eq!(v.composer.read(cx).text(), "ordinary 🦀 é");
        assert!(!v.busy);
    });
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), "rewrite 漢字\n\nordinary 🦀 é");
        assert!(!v.has_pending_cancel(&id));
        assert!(v.retained_edit.is_none());
        assert_eq!(
            v.controller.edit_status("edit-fixture").unwrap().state,
            QueueEditState::Cancelled
        );
        let saved = v.workspace.lock().unwrap().snapshot();
        assert_eq!(saved.drafts[&id].text, v.composer.read(cx).text());
        assert!(saved.drafts[&id].queued_edit.is_none());
    });
}

#[gpui::test]
fn durable_cancel_terminal_restart_preserves_unsaved_text_once(cx: &mut TestAppContext) {
    let (_dir, _window, root, id) = fixture(
        cx,
        true,
        true,
        "ordinary 🦀 é".into(),
        "rewrite 漢字".into(),
        5,
    );
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), "rewrite 漢字\n\nordinary 🦀 é");
        assert!(!v.has_pending_cancel(&id));
        assert_eq!(
            v.controller.edit_status("edit-fixture").unwrap().state,
            QueueEditState::Cancelled
        );
        v.reconcile_edit(&id, cx);
    });
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), "rewrite 漢字\n\nordinary 🦀 é")
    });
}

#[gpui::test]
fn durable_cancel_revision_exhaustion_keeps_owned_rewrite_and_hold(cx: &mut TestAppContext) {
    let (_dir, _window, root, id) = fixture(
        cx,
        false,
        false,
        "ordinary".into(),
        "rewrite".into(),
        u64::MAX - 1,
    );
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        let before = v.saved_draft(cx);
        v.cancel_owned_edit(&id, cx);
        assert_eq!(v.saved_draft(cx), before);
        assert!(!v.busy);
        assert!(v.queue_operation.is_none());
        assert!(v.error.as_deref().unwrap().contains("revision limit"));
        assert!(matches!(
            v.controller.edit_status("edit-fixture").unwrap().state,
            QueueEditState::Active { .. }
        ));
        assert!(
            !v.workspace
                .lock()
                .unwrap()
                .snapshot()
                .queued_cancellations
                .contains_key(&id)
        );
    });
}

#[gpui::test]
fn durable_cancel_stale_chat_click_does_not_cancel_selected_edit(cx: &mut TestAppContext) {
    let (_dir, _window, root, _id) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        v.cancel_owned_edit("a-different-chat", cx);
        assert!(v.cancel_operation.is_none());
        assert!(v.editing.is_some());
        assert_eq!(v.composer.read(cx).text(), "rewrite");
    });
}

#[gpui::test]
fn durable_cancel_catalog_failure_keeps_rewrite_and_retry_settles(cx: &mut TestAppContext) {
    let (dir, _window, root, id) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    let catalog = dir.path().join("workspace.json");
    let backup = dir.path().join("catalog-backup.json");
    std::fs::rename(&catalog, &backup).unwrap();
    std::fs::create_dir(&catalog).unwrap();
    root.update(cx, |v, cx| v.cancel_owned_edit(&id, cx));
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), "rewrite");
        assert!(!v.busy);
        assert!(v.edit_recovery.blocked);
        assert!(v.can_cancel_owned_edit());
        assert!(matches!(
            v.controller.edit_status("edit-fixture").unwrap().state,
            QueueEditState::Active { .. }
        ));
        assert!(
            v.error
                .as_deref()
                .unwrap()
                .contains("cancellation is still pending")
        );
    });
    std::fs::remove_dir(&catalog).unwrap();
    std::fs::rename(&backup, &catalog).unwrap();
    root.update(cx, |v, cx| v.cancel_owned_edit(&id, cx));
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), "ordinary");
        assert!(!v.has_pending_cancel(&id));
        assert!(!v.edit_recovery.blocked);
        assert!(v.error.is_none());
    });
}

#[gpui::test]
fn durable_cancel_recovered_merge_waits_for_marked_text_and_uses_latest_draft(
    cx: &mut TestAppContext,
) {
    use gpui::{EntityInputHandler, Focusable};
    let (_dir, window, root, id) = fixture(cx, true, false, "ordinary".into(), "rewrite".into(), 5);
    let mut marked = String::new();
    window
        .update(cx, |v, window, cx| {
            v.composer.update(cx, |editor, cx| {
                editor.focus(window);
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx);
            });
            marked = v.composer.read(cx).text().to_owned();
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            assert_eq!(v.composer.read(cx).text(), marked);
            assert!(v.composer.read(cx).has_marked_text());
            assert!(
                v.cancel_operation
                    .as_ref()
                    .is_some_and(|op| op.phase == Phase::Deferred)
            );
            assert!(!v.busy);
            assert!(v.edit_recovery.blocked);
            let before = v.controller.snapshot();
            v.submit_chat(Lane::FollowUp, cx);
            v.remove_queue(before.pending[0].id.clone(), cx);
            v.resolve_edit("saved", cx);
            assert_eq!(v.controller.snapshot().pending.len(), 1);
            v.composer
                .update(cx, |editor, cx| editor.unmark_text(window, cx));
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            assert_eq!(v.composer.read(cx).text(), format!("rewrite\n\n{marked}"));
            assert!(v.composer.read(cx).focus_handle(cx).is_focused(window));
            assert!(!v.has_pending_cancel(&id));
        })
        .unwrap();
    assert!(cx.read(|cx| root.read(cx).retained_edit.is_none()));
}

#[gpui::test]
fn durable_cancel_oversized_merge_keeps_pending_receipt_and_both_texts(cx: &mut TestAppContext) {
    let ordinary = "a".repeat(140_000);
    let rewrite = "b".repeat(140_000);
    let (_dir, _window, root, id) = fixture(cx, true, false, ordinary.clone(), rewrite.clone(), 5);
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), ordinary);
        assert_eq!(v.retained_edit.as_ref().unwrap().rewrite, rewrite);
        assert!(v.edit_recovery.blocked);
        assert!(v.has_pending_cancel(&id));
        let state = v.workspace.lock().unwrap().snapshot();
        assert!(matches!(
            state.queued_cancellations[&id].state,
            QueuedCancelState::Pending { .. }
        ));
        assert_eq!(
            state.drafts[&id].queued_edit.as_ref().unwrap().rewrite,
            rewrite
        );
    });
}

#[gpui::test]
fn durable_cancel_save_and_generic_remove_do_not_cross_exact_draft_failure(
    cx: &mut TestAppContext,
) {
    let (dir, _window, root, _id) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    let catalog = dir.path().join("workspace.json");
    let backup = dir.path().join("catalog-backup.json");
    std::fs::rename(&catalog, &backup).unwrap();
    std::fs::create_dir(&catalog).unwrap();
    for remove in [false, true] {
        root.update(cx, |v, cx| {
            if remove {
                v.remove_queue(v.queued_turn_id.clone().unwrap(), cx);
            } else {
                v.resolve_edit("saved", cx);
            }
        });
        cx.run_until_parked();
        root.update(cx, |v, cx| {
            assert_eq!(v.composer.read(cx).text(), "rewrite");
            assert_eq!(v.session.pending.len(), 1);
            assert_eq!(v.session.pending[0].text, "original queued text");
            assert!(matches!(
                v.controller.edit_status("edit-fixture").unwrap().state,
                QueueEditState::Active { .. }
            ));
            assert!(!v.busy);
            assert!(!v.edit_recovery.blocked);
        });
    }
    std::fs::remove_dir(&catalog).unwrap();
    std::fs::rename(&backup, &catalog).unwrap();
    root.update(cx, |v, cx| v.resolve_edit("saved", cx));
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.session.pending[0].text, "rewrite");
        assert_eq!(v.composer.read(cx).text(), "ordinary");
    });
}

#[gpui::test]
fn durable_cancel_terminal_saved_observation_keeps_saved_rewrite_out_of_ordinary_draft(
    cx: &mut TestAppContext,
) {
    let (_dir, _window, root, id) =
        fixture(cx, true, false, "ordinary".into(), "rewrite".into(), 5);
    root.update(cx, |v, _| {
        v.controller
            .resolve_edit("edit-fixture", "saved", Some("rewrite"))
            .unwrap()
    });
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), "ordinary");
        assert!(!v.has_pending_cancel(&id));
        assert!(matches!(
            v.controller.edit_status("edit-fixture").unwrap().state,
            QueueEditState::Saved { .. }
        ));
        assert_eq!(v.session.pending[0].text, "rewrite");
    });
}

#[gpui::test]
fn durable_cancel_later_failure_invalidates_marked_deferred_status(cx: &mut TestAppContext) {
    use gpui::EntityInputHandler;
    let (_dir, window, root, id) = fixture(cx, true, false, "ordinary".into(), "rewrite".into(), 5);
    window
        .update(cx, |v, window, cx| {
            v.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx)
            })
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            let old_key = v.cancel_operation.as_ref().unwrap().key.clone();
            let old_status = v
                .cancel_operation
                .as_ref()
                .unwrap()
                .deferred
                .clone()
                .unwrap();
            let before = v.composer.read(cx).text().to_owned();
            v.result(
                Err(bello_agent_core::Error::PersistenceUncertain(
                    "synthetic later failure".into(),
                )),
                cx,
            );
            assert_ne!(v.queue_operation, Some(old_key.token));
            assert!(v.cancel_operation.as_ref().unwrap().deferred.is_none());
            v.finish_cancel_read(old_key, None, Ok(old_status), cx);
            assert_eq!(v.composer.read(cx).text(), before);
            assert!(v.edit_recovery.blocked);
            v.composer
                .update(cx, |editor, cx| editor.unmark_text(window, cx));
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(!v.has_pending_cancel(&id));
        assert!(v.composer.read(cx).text().starts_with("rewrite\n\n"));
    });
}

#[gpui::test]
fn durable_cancel_navigation_completion_keeps_current_draft_and_blocks_close_until_settled(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, id) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            v.cancel_owned_edit(&id, cx);
            v.new_chat(window, cx);
            v.composer.update(cx, |editor, cx| {
                editor.set_text("new chat draft".into(), cx)
            });
            v.begin_shutdown(window, cx);
            assert!(!v.shutting_down);
            assert!(
                v.error
                    .as_deref()
                    .unwrap()
                    .contains("Wait for chat operations")
            );
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_ne!(v.record.id, id);
        assert_eq!(v.composer.read(cx).text(), "new chat draft");
        let old = v.chat_ref(&id).unwrap();
        assert_eq!(old.composer.read(cx).text(), "ordinary");
        assert!(old.editing.is_none());
        assert!(old.queue_operation.is_none());
        assert!(!v.has_pending_cancel(&id));
    });
}

#[gpui::test]
fn durable_cancel_checked_typing_and_close_never_wrap_exhausted_draft_revision(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, _id) = fixture(
        cx,
        false,
        false,
        "ordinary".into(),
        "rewrite".into(),
        u64::MAX,
    );
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            let before = v.saved_draft(cx);
            v.begin_shutdown(window, cx);
            assert!(!v.shutting_down);
            assert!(!v.busy);
            assert_eq!(v.saved_draft(cx), before);
            v.composer.update(cx, |editor, cx| {
                editor.set_text("latest rewrite".into(), cx)
            });
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.draft_revision, u64::MAX);
        assert_eq!(v.composer.read(cx).text(), "latest rewrite");
        assert!(v.error.as_deref().unwrap().contains("revision limit"));
        assert_eq!(
            v.workspace.lock().unwrap().snapshot().drafts[&v.record.id]
                .queued_edit
                .as_ref()
                .unwrap()
                .rewrite,
            "rewrite"
        );
    });
}

#[gpui::test]
fn durable_cancel_settled_owned_discard_survives_later_error_then_rechecks(
    cx: &mut TestAppContext,
) {
    let (_dir, _window, root, id) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        let source = v.saved_draft(cx);
        let edit = source.queued_edit.as_ref().unwrap();
        let receipt =
            QueuedCancelReceipt::pending(0, edit.edit_id.clone(), edit.turn_id.clone()).unwrap();
        v.workspace
            .lock()
            .unwrap()
            .prepare_queued_cancel(&id, receipt.clone(), source.clone())
            .unwrap();
        v.controller
            .cancel_edit_certain(&edit.edit_id, &edit.turn_id)
            .unwrap();
        let mut reconciled = source.clone();
        reconciled.revision += 1;
        reconciled.queued_edit = None;
        v.workspace
            .lock()
            .unwrap()
            .settle_queued_cancel(&id, &receipt, &source, reconciled.clone())
            .unwrap();
        let observed = v
            .workspace
            .lock()
            .unwrap()
            .snapshot()
            .queued_cancellations
            .get(&id)
            .cloned();
        let key = Key {
            token: Uuid::new_v4(),
            chat: id.clone(),
            project: v.project.clone(),
            controller: v.controller.clone(),
        };
        v.queued_cancellations.insert(id.clone(), receipt.clone());
        v.queue_operation = Some(key.token);
        v.busy = true;
        v.cancel_operation = Some(CancelOperation {
            key: key.clone(),
            receipt,
            owned: true,
            phase: Phase::Settling,
            deferred: None,
            recheck: false,
        });
        v.result(
            Err(bello_agent_core::Error::PersistenceUncertain(
                "synthetic later worker failure".into(),
            )),
            cx,
        );
        assert!(v.cancel_operation.as_ref().unwrap().recheck);
        v.finish_cancel_settlement(
            key,
            observed,
            Ok(true),
            Settlement {
                source,
                reconciled,
                owned: true,
                changed: true,
            },
            cx,
        );
        assert_eq!(v.composer.read(cx).text(), "ordinary");
        assert!(v.edit_recovery.blocked);
        assert!(v.queue_operation.is_some());
    });
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), "ordinary");
        assert!(!v.edit_recovery.blocked);
        assert!(v.editing.is_none());
    });
}

#[gpui::test]
fn durable_cancel_window_rebind_keeps_entity_owned_settlement_without_focus_change(
    cx: &mut TestAppContext,
) {
    use gpui::Focusable;
    let (_dir, window, root, id) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    let mut editor = None;
    window
        .update(cx, |v, window, cx| {
            v.composer.read(cx).focus(window);
            editor = Some(v.composer.clone());
            let binding = v.window_binding;
            v.cancel_owned_edit(&id, cx);
            v.bind_window(window, cx);
            assert_ne!(v.window_binding, binding);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |v, window, cx| {
            assert_eq!(v.composer, editor.take().unwrap());
            assert!(v.composer.read(cx).focus_handle(cx).is_focused(window));
            assert_eq!(v.composer.read(cx).text(), "ordinary");
            assert!(!v.has_pending_cancel(&id));
        })
        .unwrap();
    assert!(cx.read(|cx| root.read(cx).editing.is_none()));
}

#[gpui::test]
fn durable_cancel_generic_remove_flushes_even_when_cached_hold_is_missing(cx: &mut TestAppContext) {
    let (dir, _window, root, _) = fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    let catalog = dir.path().join("workspace.json");
    let backup = dir.path().join("catalog-backup.json");
    std::fs::rename(&catalog, &backup).unwrap();
    std::fs::create_dir(&catalog).unwrap();
    root.update(cx, |v, cx| {
        let turn = v.queued_turn_id.clone().unwrap();
        Arc::make_mut(&mut v.session).edit = None;
        v.remove_queue(turn, cx);
    });
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), "rewrite");
        assert!(matches!(
            v.controller.edit_status("edit-fixture").unwrap().state,
            QueueEditState::Active { .. }
        ));
    });
    std::fs::remove_dir(&catalog).unwrap();
    std::fs::rename(&backup, &catalog).unwrap();
}

#[gpui::test]
fn draft_save_warning_cancel_retry_clears_only_covered_failure(cx: &mut TestAppContext) {
    let (dir, _window, root, id) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    cx.executor()
        .advance_clock(std::time::Duration::from_millis(200));
    cx.run_until_parked();
    let catalog = dir.path().join("workspace.json");
    let backup = dir.path().join("catalog-backup.json");
    std::fs::rename(&catalog, &backup).unwrap();
    std::fs::create_dir(&catalog).unwrap();
    root.update(cx, |v, cx| v.cancel_owned_edit(&id, cx));
    cx.run_until_parked();
    cx.executor()
        .advance_clock(std::time::Duration::from_millis(200));
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        v.composer
            .update(cx, |editor, cx| editor.set_text("typed rewrite".into(), cx))
    });
    cx.run_until_parked();
    cx.executor()
        .advance_clock(std::time::Duration::from_millis(200));
    cx.run_until_parked();
    let failed_revision = root.update(cx, |v, _| {
        assert!(
            v.error
                .as_deref()
                .unwrap()
                .starts_with("Draft could not be saved:")
        );
        v.draft_revision
    });
    std::fs::remove_dir(&catalog).unwrap();
    std::fs::rename(&backup, &catalog).unwrap();
    root.update(cx, |v, cx| v.cancel_owned_edit(&id, cx));
    cx.run_until_parked();
    cx.executor()
        .advance_clock(std::time::Duration::from_millis(200));
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.composer.read(cx).text(), "ordinary");
        assert!(v.error.is_none());
        let chat = &mut v.chat;
        chat.draft_save_status.fail(
            failed_revision,
            "delayed old failure".into(),
            &mut chat.error,
            &None,
        );
        assert!(chat.error.is_none());
        assert!(!v.has_pending_cancel(&id));
    });
}

#[gpui::test]
fn draft_save_warning_successful_debounce_clears_error_without_cancel(cx: &mut TestAppContext) {
    let (dir, _window, root, _) = fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    cx.executor()
        .advance_clock(std::time::Duration::from_millis(200));
    cx.run_until_parked();
    let catalog = dir.path().join("workspace.json");
    let backup = dir.path().join("catalog-backup.json");
    std::fs::rename(&catalog, &backup).unwrap();
    std::fs::create_dir(&catalog).unwrap();
    root.update(cx, |v, cx| {
        v.composer
            .update(cx, |editor, cx| editor.set_text("first edit".into(), cx))
    });
    cx.run_until_parked();
    cx.executor()
        .advance_clock(std::time::Duration::from_millis(200));
    cx.run_until_parked();
    root.update(cx, |v, _| {
        assert!(
            v.error
                .as_deref()
                .unwrap()
                .starts_with("Draft could not be saved:")
        )
    });
    std::fs::remove_dir(&catalog).unwrap();
    std::fs::rename(&backup, &catalog).unwrap();
    root.update(cx, |v, cx| {
        v.composer
            .update(cx, |editor, cx| editor.set_text("second edit".into(), cx))
    });
    cx.run_until_parked();
    cx.executor()
        .advance_clock(std::time::Duration::from_millis(200));
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert!(v.error.is_none());
        assert_eq!(v.composer.read(cx).text(), "second edit");
        assert_eq!(
            v.workspace.lock().unwrap().snapshot().drafts[&v.record.id]
                .queued_edit
                .as_ref()
                .unwrap()
                .rewrite,
            "second edit"
        );
    });
}

#[gpui::test]
fn draft_save_warning_cancel_confirmation_preserves_newer_unrelated_error(cx: &mut TestAppContext) {
    let (_dir, _window, root, id) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    cx.executor()
        .advance_clock(std::time::Duration::from_millis(200));
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        v.draft_revision += 1;
        let revision = v.draft_revision;
        let chat = &mut v.chat;
        chat.draft_save_status.fail(
            revision,
            "synthetic prior draft failure".into(),
            &mut chat.error,
            &None,
        );
        assert!(
            v.error
                .as_deref()
                .unwrap()
                .starts_with("Draft could not be saved:")
        );
        v.cancel_owned_edit(&id, cx);
        v.error = Some("A newer unrelated warning".into());
    });
    cx.run_until_parked();
    cx.executor()
        .advance_clock(std::time::Duration::from_millis(200));
    cx.run_until_parked();
    root.update(cx, |v, cx| {
        assert_eq!(v.error.as_deref(), Some("A newer unrelated warning"));
        assert_eq!(v.composer.read(cx).text(), "ordinary");
    });
}

#[gpui::test]
fn draft_save_warning_exact_flush_confirms_before_later_actor_failure(cx: &mut TestAppContext) {
    let (_dir, _window, root, _) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    cx.executor()
        .advance_clock(std::time::Duration::from_millis(200));
    cx.run_until_parked();
    let failed_revision = root.update(cx, |v, cx| {
        v.draft_revision += 1;
        let revision = v.draft_revision;
        let chat = &mut v.chat;
        chat.draft_save_status
            .fail(revision, "old failed save".into(), &mut chat.error, &None);
        v.command(
            cx,
            Some("edit-fixture".into()),
            true,
            |_| {
                Err::<(), _>(bello_agent_core::Error::Invalid(
                    "later actor failure".into(),
                ))
            },
            |_, (), _| panic!("failed actor must not apply"),
        );
        revision
    });
    cx.run_until_parked();
    cx.executor()
        .advance_clock(std::time::Duration::from_millis(200));
    cx.run_until_parked();
    root.update(cx, |v, _| {
        assert_eq!(v.error.as_deref(), Some("later actor failure"));
        let chat = &mut v.chat;
        chat.draft_save_status.fail(
            failed_revision,
            "delayed old failure".into(),
            &mut chat.error,
            &Some("later actor failure".into()),
        );
        assert_eq!(chat.error.as_deref(), Some("later actor failure"));
    });
}
