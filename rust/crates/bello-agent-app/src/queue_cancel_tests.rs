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
        skills: Vec::new(),
        attachments: Vec::new(),
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

#[test]
fn archive_cancel_deferral_is_exactly_scoped_and_only_terminal_or_explicitly_released() {
    let project = Path::new("/project");
    let receipt = QueuedCancelReceipt::pending(0, "edit-a".into(), "turn-a".into()).unwrap();
    let other = QueuedCancelReceipt::pending(0, "edit-b".into(), "turn-a".into()).unwrap();
    let mut deferrals = ArchiveCancelDeferrals::default();
    deferrals.remember(project, "chat-a", &receipt);
    assert!(deferrals.blocks(project, "chat-a", &receipt));
    assert!(!deferrals.blocks(Path::new("/other"), "chat-a", &receipt));
    assert!(!deferrals.blocks(project, "chat-b", &receipt));
    assert!(!deferrals.blocks(project, "chat-a", &other));
    deferrals.allow_explicit(project, "chat-a", &other);
    deferrals.observe(project, "chat-a", &receipt);
    deferrals.observe(
        project,
        "chat-a",
        &QueuedCancelReceipt {
            revision: receipt.revision,
            state: QueuedCancelState::Settled,
        },
    );
    assert!(deferrals.blocks(project, "chat-a", &receipt));
    deferrals.allow_explicit(project, "chat-a", &receipt);
    assert!(!deferrals.blocks(project, "chat-a", &receipt));
    deferrals.remember(project, "chat-a", &receipt);
    deferrals.observe(
        project,
        "chat-a",
        &QueuedCancelReceipt {
            revision: receipt.revision + 1,
            state: QueuedCancelState::Settled,
        },
    );
    assert!(!deferrals.blocks(project, "chat-a", &receipt));
}

#[gpui::test]
fn cancel_archive_readiness_distinguishes_parked_and_live_ownership(cx: &mut TestAppContext) {
    let (_dir, _window, root, id) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        let edit = view.saved_draft(cx).queued_edit.unwrap();
        let receipt = QueuedCancelReceipt::pending(0, edit.edit_id, edit.turn_id).unwrap();
        let key = Key {
            token: Uuid::new_v4(),
            chat: id.clone(),
            project: view.project.clone(),
            controller: view.controller.clone(),
        };
        for (phase, live) in [
            (Phase::Running, true),
            (Phase::Settling, true),
            (Phase::Deferred, false),
            (Phase::Retry, false),
        ] {
            view.queue_operation = if phase == Phase::Retry {
                None
            } else {
                Some(key.token)
            };
            view.cancel_operation = Some(CancelOperation {
                key: key.clone(),
                receipt: receipt.clone(),
                owned: false,
                phase,
                deferred: None,
                recheck: false,
            });
            assert_eq!(view.archive_chat_work_live(&id), live);
        }
        view.cancel_operation = None;
        view.queue_operation = Some(Uuid::new_v4());
        assert!(view.archive_chat_work_live(&id));
        view.queue_operation = None;
        view.queued_cancellations.insert(id.clone(), receipt);
        view.edit_recovery.blocked = true;
        view.load_failed = true;
        assert!(!view.archive_chat_work_live(&id));
    });
}

#[gpui::test]
fn archived_direct_cancel_keeps_owned_rewrite_and_receipt_unstarted(cx: &mut TestAppContext) {
    let (_dir, _window, root, id) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        let before = view.saved_draft(cx);
        let edit = before.queued_edit.as_ref().unwrap();
        let receipt =
            QueuedCancelReceipt::pending(0, edit.edit_id.clone(), edit.turn_id.clone()).unwrap();
        view.records
            .iter_mut()
            .find(|record| record.id == id)
            .unwrap()
            .archived_at = Some(1);
        assert!(!view.can_cancel_owned_edit());
        view.cancel_owned_edit(&id, cx);
        view.start_cancel(&id, receipt.clone(), true, RetryCause::Automatic, cx);
        view.start_cancel(&id, receipt.clone(), true, RetryCause::Explicit, cx);
        assert!(view.queue_operation.is_none());
        assert!(view.cancel_operation.is_none());
        assert_eq!(view.saved_draft(cx), before);
        assert!(
            view.archive_cancel_deferrals
                .blocks(&view.project, &id, &receipt)
        );
        assert!(
            !view
                .workspace
                .lock()
                .unwrap()
                .snapshot()
                .queued_cancellations
                .contains_key(&id)
        );
        assert!(matches!(
            view.controller.edit_status(&edit.edit_id).unwrap().state,
            QueueEditState::Active { .. }
        ));
    });
}

#[gpui::test]
fn archive_deferred_cancel_first_recheck_after_restore_stays_parked_until_explicit_recovery(
    cx: &mut TestAppContext,
) {
    use gpui::EntityInputHandler;
    let (_dir, window, root, id) = fixture(cx, true, false, "ordinary".into(), "rewrite".into(), 5);
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx)
            });
        })
        .unwrap();
    cx.run_until_parked();
    let mut original = String::new();
    window
        .update(cx, |view, window, cx| {
            assert!(view.cancel_operation.as_ref().unwrap().is_deferred());
            assert!(!view.archive_chat_work_live(&id));
            view.defer_cancel_for_archive(&id);
            let receipt = view.pending_cancel_receipt(&id).unwrap();
            view.records
                .iter_mut()
                .find(|record| record.id == id)
                .unwrap()
                .archived_at = Some(1);
            view.resume_durable_cancel_explicit(&id, cx);
            assert!(
                view.archive_cancel_deferrals
                    .blocks(&view.project, &id, &receipt)
            );
            original = view.composer.read(cx).text().to_owned();
            // The old status becomes invalid, but the first attempted actor retry
            // comes from the restored composer's own deferred notification.
            view.cancel_operation.as_mut().unwrap().recheck = true;
            view.records
                .iter_mut()
                .find(|record| record.id == id)
                .unwrap()
                .archived_at = None;
            view.composer.update(cx, |editor, cx| {
                editor.set_read_only(false, cx);
                editor.unmark_text(window, cx);
            });
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(
            view.cancel_operation
                .as_ref()
                .is_some_and(|operation| operation.phase == Phase::Retry)
        );
        assert!(view.queue_operation.is_none());
        assert!(!view.archive_chat_work_live(&id));
        assert_eq!(view.composer.read(cx).text(), original);
        assert!(view.has_pending_cancel(&id));
        view.reconcile_edit(&id, cx);
        view.resume_durable_cancel(&id, cx);
        assert!(view.queue_operation.is_none());
        view.resume_durable_cancel_explicit(&id, cx);
        assert!(view.queue_operation.is_some());
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(!view.has_pending_cancel(&id));
        assert_eq!(
            view.composer.read(cx).text(),
            format!("rewrite\n\n{original}")
        );
    });
}

#[gpui::test]
fn archive_cancel_deferral_survives_controller_replacement_and_explicit_cancel_releases_it(
    cx: &mut TestAppContext,
) {
    let (_dir, _window, root, id) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        let draft = view.saved_draft(cx);
        let edit = draft.queued_edit.as_ref().unwrap();
        let receipt =
            QueuedCancelReceipt::pending(0, edit.edit_id.clone(), edit.turn_id.clone()).unwrap();
        view.workspace
            .lock()
            .unwrap()
            .prepare_queued_cancel(&id, receipt.clone(), draft)
            .unwrap();
        view.queued_cancellations
            .insert(id.clone(), receipt.clone());
        view.defer_cancel_for_archive(&id);
        let controller = view.controller.clone();
        let placeholder = Controller::new(SessionStore::pending(), None).unwrap();
        view.chat.replace_controller(placeholder, cx);
        view.chat.replace_controller(controller, cx);
        assert!(view.cancel_operation.is_none());
        view.reconcile_edit(&id, cx);
        assert!(view.queue_operation.is_none());
        assert!(
            view.archive_cancel_deferrals
                .blocks(&view.project, &id, &receipt)
        );
        view.cancel_owned_edit(&id, cx);
        assert!(view.queue_operation.is_some());
        assert!(
            !view
                .archive_cancel_deferrals
                .blocks(&view.project, &id, &receipt)
        );
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(!view.has_pending_cancel(&id));
        assert_eq!(view.composer.read(cx).text(), "ordinary");
    });
}

#[gpui::test]
fn explicit_held_row_cancel_releases_only_its_archive_deferred_receipt(cx: &mut TestAppContext) {
    let (_dir, _window, root, id) =
        fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        let draft = view.saved_draft(cx);
        let edit = draft.queued_edit.clone().unwrap();
        let receipt =
            QueuedCancelReceipt::pending(0, edit.edit_id.clone(), edit.turn_id.clone()).unwrap();
        view.workspace
            .lock()
            .unwrap()
            .prepare_queued_cancel(&id, receipt.clone(), draft)
            .unwrap();
        view.queued_cancellations
            .insert(id.clone(), receipt.clone());
        view.editing = None;
        view.retained_edit = Some(edit.clone());
        view.composer
            .update(cx, |editor, cx| editor.set_text("ordinary".into(), cx));
        view.defer_cancel_for_archive(&id);
        view.resume_durable_cancel(&id, cx);
        assert!(view.queue_operation.is_none());
        view.cancel_held_edit(&id, &edit.turn_id, &edit.edit_id, cx);
        assert!(view.queue_operation.is_some());
        assert!(
            !view
                .archive_cancel_deferrals
                .blocks(&view.project, &id, &receipt)
        );
    });
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert!(!view.has_pending_cancel(&id));
        assert_eq!(view.composer.read(cx).text(), "rewrite\n\nordinary");
    });
}

fn archive_deferred_cancel_close_round_trip(cx: &mut TestAppContext, inactive: bool) {
    use gpui::EntityInputHandler;
    let (_dir, window, root, id) = fixture(cx, true, false, "ordinary".into(), "rewrite".into(), 5);
    let mut marked = String::new();
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx)
            });
            marked = view.composer.read(cx).text().to_owned();
        })
        .unwrap();
    cx.run_until_parked();
    let mut selected = id.clone();
    let mut token = None;
    window
        .update(cx, |view, window, cx| {
            assert!(view.cancel_operation.as_ref().unwrap().is_deferred());
            token = view.queue_operation;
            assert!(token.is_some());
            if inactive {
                view.new_chat(window, cx);
                view.composer.update(cx, |editor, cx| {
                    editor.set_text("other chat draft".into(), cx)
                });
                selected = view.record.id.clone();
                assert_ne!(selected, id);
            }
            view.set_chat_archived(&id, true, cx);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert!(view.chat_is_archived(&id));
            assert!(view.organization_operations.is_empty());
            assert_eq!(view.record.id, selected);
            let chat = view.chat_ref(&id).unwrap();
            assert_eq!(chat.queue_operation, token);
            assert!(chat.composer.read(cx).has_marked_text());
            assert_eq!(chat.composer.read(cx).text(), marked);
            assert!(
                view.workspace
                    .lock()
                    .unwrap()
                    .snapshot()
                    .chats
                    .iter()
                    .any(|record| record.id == id && record.archived_at.is_some())
            );
            view.begin_shutdown(window, cx);
            assert!(!view.shutting_down);
            assert!(!view.close_ready);
            let message = view.error.as_deref().unwrap();
            assert!(message.contains("Restore") && message.contains("before closing"));
            assert_eq!(view.chat_ref(&id).unwrap().queue_operation, token);
            view.set_chat_archived(&id, false, cx);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert!(!view.chat_is_archived(&id));
            assert_eq!(view.record.id, selected);
            let chat = view.chat_mut(&id).unwrap();
            assert!(chat.cancel_operation.as_ref().unwrap().is_deferred());
            assert_eq!(chat.queue_operation, token);
            assert!(chat.composer.read(cx).has_marked_text());
            assert_eq!(chat.composer.read(cx).text(), marked);
            assert_ne!(chat.session.state, bello_agent_core::RunState::Running);
            chat.composer
                .update(cx, |editor, cx| editor.unmark_text(window, cx));
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert_eq!(view.record.id, selected);
            let chat = view.chat_ref(&id).unwrap();
            assert!(chat.queue_operation.is_none());
            assert!(chat.cancel_operation.is_none());
            assert!(!chat.composer.read(cx).has_marked_text());
            assert_eq!(
                chat.composer.read(cx).text(),
                format!("rewrite\n\n{marked}")
            );
            assert_ne!(chat.session.state, bello_agent_core::RunState::Running);
            assert!(!view.has_pending_cancel(&id));
            if inactive {
                assert_eq!(view.composer.read(cx).text(), "other chat draft");
            }
            view.begin_shutdown(window, cx);
            assert!(view.shutting_down);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, _| {
        assert!(view.close_ready);
        let snapshot = view.workspace.lock().unwrap().snapshot();
        assert!(
            snapshot
                .chats
                .iter()
                .any(|record| record.id == id && record.archived_at.is_none())
        );
        assert_eq!(snapshot.drafts[&id].text, format!("rewrite\n\n{marked}"));
        assert!(snapshot.drafts[&id].queued_edit.is_none());
        assert!(matches!(
            snapshot.queued_cancellations[&id].state,
            QueuedCancelState::Settled
        ));
    });
}

#[gpui::test]
fn archived_selected_deferred_cancel_blocks_close_until_restore_and_composition_finish(
    cx: &mut TestAppContext,
) {
    archive_deferred_cancel_close_round_trip(cx, false);
}

#[gpui::test]
fn archived_inactive_deferred_cancel_blocks_close_without_stealing_selection_on_restore(
    cx: &mut TestAppContext,
) {
    archive_deferred_cancel_close_round_trip(cx, true);
}

#[gpui::test]
fn archive_waits_for_controlled_cancel_callback_and_drains_on_success_or_failure(
    cx: &mut TestAppContext,
) {
    for fails in [false, true] {
        let (_dir, _window, root, id) =
            fixture(cx, false, false, "ordinary".into(), "rewrite".into(), 5);
        cx.run_until_parked();
        let mut key = None;
        let mut status = None;
        root.update(cx, |view, cx| {
            // Materialize the same durable preparation as start_cancel, but
            // retain foreground ownership until the controlled callback below.
            let draft = view.saved_draft(cx);
            let edit = draft.queued_edit.clone().unwrap();
            let receipt =
                QueuedCancelReceipt::pending(0, edit.edit_id.clone(), edit.turn_id.clone())
                    .unwrap();
            view.workspace
                .lock()
                .unwrap()
                .prepare_queued_cancel(&id, receipt.clone(), draft)
                .unwrap();
            view.queued_cancellations
                .insert(id.clone(), receipt.clone());
            if !fails {
                status = Some(
                    view.controller
                        .cancel_edit_certain(&edit.edit_id, &edit.turn_id)
                        .unwrap(),
                );
            }
            let operation_key = Key {
                token: Uuid::new_v4(),
                chat: id.clone(),
                project: view.project.clone(),
                controller: view.controller.clone(),
            };
            view.queue_operation = Some(operation_key.token);
            view.busy = true;
            view.edit_recovery = EditRecovery::new(true);
            view.cancel_operation = Some(CancelOperation {
                key: operation_key.clone(),
                receipt,
                owned: true,
                phase: Phase::Running,
                deferred: None,
                recheck: false,
            });
            key = Some(operation_key);
            view.set_chat_archived(&id, true, cx);
            assert!(view.archive_chat_work_live(&id));
        });
        cx.run_until_parked();
        root.update(cx, |view, cx| {
            assert!(!view.chat_is_archived(&id));
            assert!(view.has_pending_archive(&id));
            assert!(!view.organization_drain_scheduled);
            assert!(
                view.workspace
                    .lock()
                    .unwrap()
                    .snapshot()
                    .chats
                    .iter()
                    .all(|record| record.archived_at.is_none())
            );
            let result = if fails {
                Err("controlled cancellation callback failure".into())
            } else {
                Ok(status.take().unwrap())
            };
            view.finish_cancel_read(key.take().unwrap(), None, result, cx);
            assert_eq!(view.archive_chat_work_live(&id), !fails);
        });
        cx.run_until_parked();
        root.update(cx, |view, cx| {
            assert!(view.chat_is_archived(&id));
            assert!(view.organization_operations.is_empty());
            assert!(!view.archive_chat_work_live(&id));
            if fails {
                assert!(
                    view.cancel_operation
                        .as_ref()
                        .is_some_and(|operation| operation.phase == Phase::Retry)
                );
                assert!(view.has_pending_cancel(&id));
                assert_eq!(view.composer.read(cx).text(), "rewrite");
            } else {
                assert!(view.cancel_operation.is_none());
                assert!(!view.has_pending_cancel(&id));
                assert_eq!(view.composer.read(cx).text(), "ordinary");
            }
        });
    }
}
