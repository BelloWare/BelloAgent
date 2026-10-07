//! Durable catalog/actor cancellation protocol with no provider or GUI. Dropping
//! and reopening at each cut reads real committed files, rather than UI snapshots.
use bello_agent_core::{
    Controller, Lane, QueueEditState, SessionStore, Submission,
    workspace::{
        ChatRecord, DraftRecord, QueuedCancelReceipt, QueuedCancelState, QueuedDraft,
        WorkspaceStore,
    },
};
use std::sync::Arc;

struct Fixture {
    dir: tempfile::TempDir,
    chat: ChatRecord,
    draft: DraftRecord,
    receipt: QueuedCancelReceipt,
    catalog: WorkspaceStore,
    controller: Arc<Controller>,
}
fn fixture(retain_rewrite: bool) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let session_path = dir.path().join("session.json");
    let mut session = SessionStore::open(&session_path).unwrap();
    let item = Submission::new("original queued message".into(), Lane::FollowUp);
    session
        .transact(|s| {
            s.submit(item.clone())?;
            s.begin_edit(&item.id, "held-edit")?;
            Ok(())
        })
        .unwrap();
    let chat = ChatRecord {
        tool_mode: Default::default(),
        connection_id: None,
        id: session.snapshot().id,
        title: "Durable Cancel fixture".into(),
        snapshot: session_path,
        sidebar_order: Some(1),
        pinned_at: None,
        archived_at: None,
    };
    let draft = DraftRecord {
        revision: 8,
        text: "displaced ordinary draft".into(),
        queued_edit: retain_rewrite.then(|| QueuedDraft {
            edit_id: "held-edit".into(),
            turn_id: item.id.clone(),
            rewrite: "genuinely unsaved rewrite".into(),
            original_text: Some(item.text),
        }),
    };
    let receipt = QueuedCancelReceipt::pending(0, "held-edit".into(), item.id).unwrap();
    let mut catalog = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
    catalog.register(chat.clone(), draft.clone()).unwrap();
    let controller = Controller::new(session, None).unwrap();
    Fixture {
        dir,
        chat,
        draft,
        receipt,
        catalog,
        controller,
    }
}

#[test]
fn prepared_cancel_reopens_and_retries_cancel_at_each_actor_and_settlement_crash_cut() {
    for cut in ["prepared", "actor", "postmerge_autosave", "settled"] {
        let Fixture {
            dir,
            chat,
            draft,
            receipt,
            mut catalog,
            controller,
        } = fixture(true);
        catalog
            .prepare_queued_cancel(&chat.id, receipt.clone(), draft.clone())
            .unwrap();
        if cut != "prepared" {
            controller
                .resolve_edit("held-edit", "cancelled", None)
                .unwrap();
            assert_eq!(
                controller.edit_status("held-edit").unwrap().state,
                QueueEditState::Cancelled
            );
            assert!(controller.snapshot().edit.is_none());
        }
        let mut merged = draft.clone();
        if matches!(cut, "postmerge_autosave" | "settled") {
            assert!(
                merged
                    .reconcile_queued_status(&controller.edit_status("held-edit").unwrap())
                    .unwrap()
            );
            if cut == "postmerge_autosave" {
                merged.revision += 1;
                merged.text.push_str("\nnew typing after reconciliation");
                catalog.save_draft(&chat.id, merged.clone()).unwrap();
            } else {
                assert!(
                    catalog
                        .settle_queued_cancel(&chat.id, &receipt, &draft, merged.clone())
                        .unwrap()
                );
            }
        }
        drop((catalog, controller));

        let mut catalog =
            WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
        let controller =
            Controller::new(SessionStore::open(&chat.snapshot).unwrap(), None).unwrap();
        let recovered = catalog.snapshot();
        let observed = &recovered.queued_cancellations[&chat.id];
        if matches!(observed.state, QueuedCancelState::Pending { .. }) {
            // Recovery retries the retained cancellation. In particular, it never
            // calls Begin to restore UI ownership after the durable preparation.
            let current = recovered.drafts[&chat.id].clone();
            catalog
                .prepare_queued_cancel(&chat.id, observed.clone(), current.clone())
                .unwrap();
            controller
                .resolve_edit("held-edit", "cancelled", None)
                .unwrap();
            let status = controller.edit_status("held-edit").unwrap();
            assert_eq!(status.state, QueueEditState::Cancelled);
            let mut reconciled = current.clone();
            reconciled.reconcile_queued_status(&status).unwrap();
            assert!(
                catalog
                    .settle_queued_cancel(&chat.id, observed, &current, reconciled)
                    .unwrap()
            );
        } else {
            assert_eq!(cut, "settled");
        }
        assert!(
            controller
                .begin_edit(&controller.snapshot().pending[0].id, "held-edit")
                .is_err()
        );
        assert_eq!(
            controller.snapshot().pending[0].text,
            "original queued message"
        );
        assert!(controller.snapshot().edit.is_none());
        assert_eq!(
            catalog.snapshot().queued_cancellations[&chat.id],
            QueuedCancelReceipt {
                revision: 2,
                state: QueuedCancelState::Settled,
            }
        );
        let expected = if cut == "postmerge_autosave" {
            merged
        } else {
            let mut expected = draft.clone();
            expected
                .reconcile_queued_status(&controller.edit_status("held-edit").unwrap())
                .unwrap();
            expected
        };
        assert_eq!(catalog.snapshot().drafts[&chat.id], expected);
        assert!(
            catalog
                .prepare_queued_cancel(&chat.id, receipt, draft)
                .is_err()
        );
        drop((catalog, controller));
        let final_catalog =
            WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
        assert_eq!(final_catalog.snapshot().drafts[&chat.id], expected);
    }
}

#[test]
fn unowned_cancel_has_durable_identity_without_inventing_a_queued_draft() {
    let Fixture {
        dir,
        chat,
        draft,
        receipt,
        mut catalog,
        controller,
    } = fixture(false);
    catalog
        .prepare_queued_cancel(&chat.id, receipt.clone(), draft.clone())
        .unwrap();
    drop((catalog, controller));
    let mut catalog = WorkspaceStore::open(dir.path().join("workspace.json"), dir.path()).unwrap();
    let controller = Controller::new(SessionStore::open(&chat.snapshot).unwrap(), None).unwrap();
    assert!(matches!(
        controller.edit_status("held-edit").unwrap().state,
        QueueEditState::Active { .. }
    ));
    let mut typed = draft.clone();
    typed.revision += 1;
    typed.text.push_str(" with newer typing");
    catalog.save_draft(&chat.id, typed.clone()).unwrap();
    catalog
        .prepare_queued_cancel(&chat.id, receipt.clone(), draft.clone())
        .unwrap();
    controller
        .resolve_edit("held-edit", "cancelled", None)
        .unwrap();
    assert!(
        catalog
            .settle_queued_cancel(&chat.id, &receipt, &draft, draft.clone())
            .unwrap()
    );
    assert_eq!(catalog.snapshot().drafts[&chat.id], typed);
    assert_eq!(
        controller.edit_status("held-edit").unwrap().state,
        QueueEditState::Cancelled
    );
    assert!(controller.snapshot().edit.is_none());
}

#[test]
fn owned_live_cancel_discards_its_rewrite_but_keeps_the_ordinary_draft() {
    let Fixture {
        dir: _dir,
        chat,
        draft,
        receipt,
        mut catalog,
        controller,
    } = fixture(true);
    catalog
        .prepare_queued_cancel(&chat.id, receipt.clone(), draft.clone())
        .unwrap();
    controller
        .resolve_edit("held-edit", "cancelled", None)
        .unwrap();
    let restored = DraftRecord {
        revision: draft.revision.checked_add(1).unwrap(),
        text: draft.text.clone(),
        queued_edit: None,
    };
    assert!(
        catalog
            .settle_queued_cancel(&chat.id, &receipt, &draft, restored.clone())
            .unwrap()
    );
    assert_eq!(catalog.snapshot().drafts[&chat.id], restored);
    assert_eq!(
        controller.snapshot().pending[0].text,
        "original queued message"
    );
}

#[test]
fn cancelling_an_abandoned_identity_does_not_erase_a_different_held_edit() {
    let Fixture {
        dir: _dir,
        chat,
        draft,
        mut catalog,
        controller,
        ..
    } = fixture(true);
    let abandoned =
        QueuedCancelReceipt::pending(0, "abandoned-before-begin".into(), "old-turn".into())
            .unwrap();
    let ordinary = DraftRecord {
        revision: draft.revision + 1,
        text: "ordinary pending adoption".into(),
        queued_edit: None,
    };
    catalog
        .prepare_queued_cancel(&chat.id, abandoned.clone(), ordinary.clone())
        .unwrap();
    let mut current = draft.clone();
    current.revision = ordinary.revision + 1;
    catalog.save_draft(&chat.id, current.clone()).unwrap();
    catalog
        .prepare_queued_cancel(&chat.id, abandoned.clone(), current.clone())
        .unwrap();
    controller
        .resolve_edit("abandoned-before-begin", "cancelled", None)
        .unwrap();
    let status = controller.edit_status("abandoned-before-begin").unwrap();
    assert_eq!(status.state, QueueEditState::Cancelled);
    assert_eq!(status.current_hold.as_ref().unwrap().edit_id, "held-edit");
    assert!(
        catalog
            .settle_queued_cancel(&chat.id, &abandoned, &current, current.clone())
            .unwrap()
    );
    assert_eq!(catalog.snapshot().drafts[&chat.id], current);
    assert_eq!(controller.snapshot().edit.unwrap().edit_id, "held-edit");
    assert!(
        controller
            .begin_edit("old-turn", "abandoned-before-begin")
            .is_err()
    );
}

#[test]
fn exact_flush_blocks_save_or_remove_with_same_revision_different_contents() {
    for outcome in ["saved", "removed"] {
        let Fixture {
            dir: _dir,
            chat,
            draft,
            mut catalog,
            controller,
            ..
        } = fixture(true);
        let mut conflicting = draft.clone();
        conflicting.queued_edit.as_mut().unwrap().rewrite = "not the saved payload".into();
        let flushed = catalog.flush_draft_exact(&chat.id, conflicting.clone());
        // This is the app's dispatch boundary: an obsolete/equal-conflicting
        // ordinary debounce result must not masquerade as a successful flush.
        if flushed.is_ok() {
            controller
                .resolve_edit(
                    "held-edit",
                    outcome,
                    (outcome == "saved").then_some("not the saved payload"),
                )
                .unwrap();
        }
        assert!(flushed.is_err());
        assert!(matches!(
            controller.edit_status("held-edit").unwrap().state,
            QueueEditState::Active { .. }
        ));
        assert_eq!(catalog.snapshot().drafts[&chat.id], draft);
        conflicting.revision += 1;
        catalog
            .flush_draft_exact(&chat.id, conflicting.clone())
            .unwrap();
        controller
            .resolve_edit(
                "held-edit",
                outcome,
                (outcome == "saved").then_some("not the saved payload"),
            )
            .unwrap();
        assert!(!matches!(
            controller.edit_status("held-edit").unwrap().state,
            QueueEditState::Active { .. }
        ));
        assert_eq!(catalog.snapshot().drafts[&chat.id], conflicting);
    }
}
