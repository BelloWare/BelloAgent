//! Fake-platform controls/identity checks; actual actor delivery has loopback tests.
use super::*;
use crate::LaunchState;
use bello_agent_core::{
    SessionStore, Submission,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
use gpui::{
    Entity, EntityInputHandler, Focusable, TestAppContext, VisualTestContext, WindowHandle,
};
use std::sync::Mutex;

fn fixture(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
    String,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let store = SessionStore::pending();
    let snapshot = store.snapshot();
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        project: project.clone(),
        workspace: Arc::new(Mutex::new(
            WorkspaceStore::open(project.join("catalog.json"), &project).unwrap(),
        )),
        record: ChatRecord::new(snapshot.id, "Fixture".into(), project.join("session.json")),
        draft: DraftRecord {
            attachments: Vec::new(),
            text: "keep draft e\u{301} 日本語".into(),
            ..Default::default()
        },
        pending: true,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    let item = Submission::new("queued text".into(), Lane::FollowUp);
    let id = item.id.clone();
    root.update(cx, |view, cx| {
        // Presentation-only Running snapshot; Controller remains idle and must
        // reject an attempted promotion. No provider/request is fabricated.
        let session = Arc::make_mut(&mut view.session);
        session.state = RunState::Running;
        session.pending.push(item);
        cx.notify();
    });
    cx.run_until_parked();
    (dir, window, root, id)
}

#[gpui::test]
fn queue_promotion_visibility_matches_source_and_control_is_22_points(cx: &mut TestAppContext) {
    let (_dir, window, root, id) = fixture(cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    for (width, height) in [(1180., 812.), (920., 600.)] {
        visual.simulate_resize(gpui::size(gpui::px(width), gpui::px(height)));
        cx.run_until_parked();
        let bounds = visual.debug_bounds("queue-promote").unwrap();
        assert_eq!(bounds.size.width, gpui::px(22.));
        assert_eq!(bounds.size.height, gpui::px(22.));
    }
    root.update(cx, |view, cx| {
        assert!(offers_promotion(&view.chat, &id));
        assert!(!offers_promotion(&view.chat, "gone"));
        for state in [RunState::Idle, RunState::Paused, RunState::Error] {
            Arc::make_mut(&mut view.session).state = state;
            assert!(!offers_promotion(&view.chat, &id));
        }
        let session = Arc::make_mut(&mut view.session);
        session.state = RunState::Running;
        session.begin_edit(&id, "hold").unwrap();
        assert!(!offers_promotion(&view.chat, &id));
        let session = Arc::make_mut(&mut view.session);
        session.resolve_edit("hold", "cancelled", None).unwrap();
        session.pending[0].lane = Lane::Steering;
        assert!(!offers_promotion(&view.chat, &id));
        cx.notify();
    });
    cx.run_until_parked();
    // GPUI 0.2.2 retains debug_bounds entries across frames, so absence is
    // established by the shared visibility policy above, not a stale map.
}

#[gpui::test]
fn queue_promotion_rejection_never_freezes_or_rewrites_composition(cx: &mut TestAppContext) {
    let (_dir, window, root, id) = fixture(cx);
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.focus(window);
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx);
            });
            let before = view.composer.read(cx).text().to_owned();
            let chat_id = view.record.id.clone();
            view.promote_queued("different chat", &id, cx);
            assert!(view.queue_operation.is_none());
            view.promote_queued(&chat_id, &id, cx);
            let token = view.queue_operation.unwrap();
            view.promote_queued(&chat_id, &id, cx);
            assert_eq!(view.queue_operation, Some(token));
            assert!(view.composer.read(cx).has_marked_text());
            assert_eq!(view.composer.read(cx).text(), before);
            assert!(!view.busy);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert!(view.queue_operation.is_none());
            assert!(
                view.error
                    .as_deref()
                    .unwrap()
                    .starts_with("Queued message could not be promoted:")
            );
            assert!(view.composer.read(cx).has_marked_text());
            assert!(view.composer.read(cx).focus_handle(cx).is_focused(window));
        })
        .unwrap();
    assert!(cx.read(|cx| root.read(cx).controller.snapshot().pending.is_empty()));
}

#[gpui::test]
fn queue_promotion_completion_stays_with_original_chat_and_rejects_stale_owners(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, _id) = fixture(cx);
    window
        .update(cx, |view, window, cx| {
            let chat_id = view.record.id.clone();
            let project = view.project.clone();
            let controller = view.controller.clone();
            let token = uuid::Uuid::new_v4();
            view.queue_operation = Some(token);
            view.new_chat(window, cx);
            let selected = view.record.id.clone();
            assert_ne!(selected, chat_id);
            view.finish_queue_promotion(
                &chat_id,
                &project,
                &controller,
                uuid::Uuid::new_v4(),
                Err("stale".into()),
                cx,
            );
            assert!(view.inactive[&chat_id].error.is_none());
            let replacement = Controller::new(SessionStore::pending(), None).unwrap();
            view.finish_queue_promotion(
                &chat_id,
                &project,
                &replacement,
                token,
                Err("replacement".into()),
                cx,
            );
            view.finish_queue_promotion(
                &chat_id,
                &project.join("other"),
                &controller,
                token,
                Err("wrong project".into()),
                cx,
            );
            assert!(view.inactive[&chat_id].error.is_none());
            view.finish_queue_promotion(
                &chat_id,
                &project,
                &controller,
                token,
                Err("write failed".into()),
                cx,
            );
            assert_eq!(view.record.id, selected);
            assert!(view.error.is_none());
            assert!(
                view.inactive[&chat_id]
                    .error
                    .as_deref()
                    .unwrap()
                    .contains("write failed")
            );
            assert_eq!(
                view.inactive[&chat_id].composer.read(cx).text(),
                "keep draft e\u{301} 日本語"
            );
        })
        .unwrap();
    assert!(cx.read(|cx| root.read(cx).queue_operation.is_none()));
}

#[gpui::test]
fn queue_promotion_success_clears_only_its_owned_error(cx: &mut TestAppContext) {
    let (_dir, window, _root, _id) = fixture(cx);
    window
        .update(cx, |view, _, cx| {
            let id = view.record.id.clone();
            let project = view.project.clone();
            let controller = view.controller.clone();
            for overwritten in [false, true] {
                let token = uuid::Uuid::new_v4();
                view.queue_operation = Some(token);
                view.finish_queue_promotion(
                    &id,
                    &project,
                    &controller,
                    token,
                    Err("fixture error".into()),
                    cx,
                );
                if overwritten {
                    view.error = Some("newer unrelated error".into());
                }
                let retry = uuid::Uuid::new_v4();
                view.queue_operation = Some(retry);
                view.finish_queue_promotion(&id, &project, &controller, retry, Ok(()), cx);
                assert_eq!(
                    view.error.as_deref(),
                    overwritten.then_some("newer unrelated error")
                );
                assert!(view.queue_operation_error.is_none());
            }
        })
        .unwrap();
}

#[gpui::test]
fn queue_promotion_controller_replacement_invalidates_old_operation_without_touching_draft(
    cx: &mut TestAppContext,
) {
    let (_dir, window, _root, _id) = fixture(cx);
    window
        .update(cx, |view, _, cx| {
            let old = view.controller.clone();
            let id = view.record.id.clone();
            let project = view.project.clone();
            let token = uuid::Uuid::new_v4();
            view.queue_operation = Some(token);
            view.chat.replace_controller(old.clone(), cx);
            assert_eq!(view.queue_operation, Some(token));
            view.queue_operation_error = Some("older promotion notice".into());
            view.error = Some("newer unrelated error".into());
            let replacement =
                Controller::new(SessionStore::pending_with_id(&id).unwrap(), None).unwrap();
            view.chat.replace_controller(replacement, cx);
            assert!(view.queue_operation.is_none());
            assert!(view.queue_operation_error.is_none());
            view.finish_queue_promotion(
                &id,
                &project,
                &old,
                token,
                Err("late old failure".into()),
                cx,
            );
            assert_eq!(view.error.as_deref(), Some("newer unrelated error"));
            assert_eq!(view.composer.read(cx).text(), "keep draft e\u{301} 日本語");
        })
        .unwrap();
}

#[gpui::test]
fn queue_promotion_close_barrier_waits_for_active_and_inactive_completion(cx: &mut TestAppContext) {
    for inactive in [false, true] {
        for failed in [false, true] {
            let (_dir, window, root, _id) = fixture(cx);
            window
                .update(cx, |view, window, cx| {
                    let id = view.record.id.clone();
                    let project = view.project.clone();
                    let controller = view.controller.clone();
                    let token = uuid::Uuid::new_v4();
                    view.queue_operation = Some(token);
                    if inactive {
                        view.new_chat(window, cx);
                    }
                    view.composer.update(cx, |editor, cx| {
                        editor.focus(window);
                        editor.replace_and_mark_text_in_range(
                            None,
                            "未確定",
                            Some(3..3),
                            window,
                            cx,
                        );
                    });
                    let before = view.composer.read(cx).text().to_owned();
                    let revision = view.draft_revision;
                    view.begin_shutdown(window, cx);
                    assert!(!view.shutting_down);
                    assert!(view.shutdown_operation.is_none());
                    assert_eq!(view.draft_revision, revision);
                    assert_eq!(view.composer.read(cx).text(), before);
                    assert!(view.composer.read(cx).has_marked_text());
                    assert!(view.composer.read(cx).focus_handle(cx).is_focused(window));
                    assert_eq!(view.chat_ref(&id).unwrap().queue_operation, Some(token));
                    view.finish_queue_promotion(
                        &id,
                        &project,
                        &controller,
                        token,
                        if failed {
                            Err("fixture write failed".into())
                        } else {
                            Ok(())
                        },
                        cx,
                    );
                    assert!(view.chat_ref(&id).unwrap().queue_operation.is_none());
                    // Composition during actual Close remains a separate audited
                    // policy gap. Only blocked-close preservation is tested here.
                    view.composer
                        .update(cx, |editor, cx| editor.unmark_text(window, cx));
                    view.begin_shutdown(window, cx);
                    assert!(view.shutting_down);
                })
                .unwrap();
            cx.run_until_parked();
            assert!(cx.read(|cx| root.read(cx).close_ready));
        }
    }
}

#[gpui::test]
fn queue_resume_source_visibility_labels_and_edit_guard(cx: &mut TestAppContext) {
    let (_dir, window, root, turn) = fixture(cx);
    window
        .update(cx, |view, _, cx| {
            assert!(!offers_resume(&view.chat));
            for state in [RunState::Idle, RunState::Paused, RunState::Error] {
                Arc::make_mut(&mut view.session).state = state;
                assert!(offers_resume(&view.chat));
            }
            assert_eq!(resume_label(&view.chat), "Send queued");
            Arc::make_mut(&mut view.session).queue_paused = true;
            assert_eq!(resume_label(&view.chat), "Resume");
            Arc::make_mut(&mut view.session)
                .begin_edit(&turn, "held")
                .unwrap();
            assert!(offers_resume(&view.chat)); // Visible, disabled, with original help.
            let id = view.record.id.clone();
            view.resume_queued(&id, cx);
            assert!(view.queue_operation.is_none());
        })
        .unwrap();
    assert!(cx.read(|cx| root.read(cx).error.is_none()));
}

#[gpui::test]
fn queue_resume_failure_preserves_marked_draft_focus_and_rejects_duplicate_click(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, _) = fixture(cx);
    window
        .update(cx, |view, window, cx| {
            Arc::make_mut(&mut view.session).state = RunState::Paused;
            view.composer.update(cx, |editor, cx| {
                editor.focus(window);
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx);
            });
            let draft = view.composer.read(cx).text().to_owned();
            let revision = view.draft_revision;
            let id = view.record.id.clone();
            view.resume_queued("stale chat", cx);
            assert!(view.queue_operation.is_none());
            view.resume_queued(&id, cx);
            let operation = view.queue_operation.unwrap();
            view.resume_queued(&id, cx);
            assert_eq!(view.queue_operation, Some(operation));
            assert!(!view.busy);
            assert_eq!(view.composer.read(cx).text(), draft);
            assert_eq!(view.draft_revision, revision);
            assert!(view.composer.read(cx).has_marked_text());
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert!(view.queue_operation.is_none());
            assert!(
                view.error
                    .as_deref()
                    .unwrap()
                    .starts_with("Queued messages could not be resumed:")
            );
            assert!(view.composer.read(cx).has_marked_text());
            assert!(view.composer.read(cx).focus_handle(cx).is_focused(window));
            assert!(!view.busy);
        })
        .unwrap();
    assert!(cx.read(|cx| root.read(cx).controller.snapshot().pending.is_empty()));
}

#[gpui::test]
fn queue_resume_completion_keeps_original_chat_and_close_barrier(cx: &mut TestAppContext) {
    let (_dir, window, root, _) = fixture(cx);
    window
        .update(cx, |view, window, cx| {
            Arc::make_mut(&mut view.session).state = RunState::Paused;
            let id = view.record.id.clone();
            view.resume_queued(&id, cx);
            let token = view.queue_operation.unwrap();
            let controller = view.controller.clone();
            let project = view.project.clone();
            view.new_chat(window, cx);
            let selected = view.record.id.clone();
            view.begin_shutdown(window, cx);
            assert!(!view.shutting_down);
            view.finish_queue_operation(
                &id,
                &project,
                &controller,
                uuid::Uuid::new_v4(),
                Ok(()),
                cx,
            );
            assert_eq!(view.inactive[&id].queue_operation, Some(token));
            view.finish_queue_operation(
                &id,
                &project.join("wrong"),
                &controller,
                token,
                Ok(()),
                cx,
            );
            assert_eq!(view.inactive[&id].queue_operation, Some(token));
            assert_eq!(view.record.id, selected);
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        let original = view.inactive.values().next().unwrap();
        assert!(original.queue_operation.is_none());
        assert!(
            original
                .error
                .as_deref()
                .unwrap()
                .starts_with("Queued messages could not be resumed:")
        );
        assert_eq!(
            original.composer.read(cx).text(),
            "keep draft e\u{301} 日本語"
        );
        assert!(!view.shutting_down);
    });
}

#[gpui::test]
fn queue_resume_header_and_paused_split_send_remain_reachable(cx: &mut TestAppContext) {
    let (_dir, window, root, _) = fixture(cx);
    root.update(cx, |view, cx| {
        Arc::make_mut(&mut view.session).state = RunState::Paused;
        Arc::make_mut(&mut view.session).queue_paused = true;
        Arc::make_mut(&mut view.session)
            .pending
            .push(Submission::new("second queued".into(), Lane::FollowUp));
        view.show_files = true;
        view.layout.fraction = 0.5;
        cx.notify();
    });
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(gpui::size(gpui::px(920.), gpui::px(600.)));
    for expanded in [true, false, true] {
        root.update(cx, |view, cx| {
            view.queue_open = expanded;
            cx.notify();
        });
        cx.run_until_parked();
        let header = visual.debug_bounds("queue-header").unwrap();
        let resume = visual.debug_bounds("queue-resume").unwrap();
        let pane = visual.debug_bounds("queue-measured-pane").unwrap();
        let send = visual.debug_bounds("composer-send").unwrap();
        assert!(
            resume.left() >= header.left() && resume.right() <= header.right(),
            "resume={resume:?} header={header:?}"
        );
        assert!(resume.top() >= header.top() && resume.bottom() <= header.bottom());
        assert!(
            send.left() >= pane.left() && send.right() <= pane.right(),
            "send={send:?} pane={pane:?}"
        );
        assert!(send.bottom() <= pane.bottom());
    }
    for held in [false, true] {
        root.update(cx, |view, cx| {
            let session = Arc::make_mut(&mut view.session);
            session.state = RunState::Error;
            session.queue_paused = false;
            session.retry = Some(Submission::new(
                "failed active message".into(),
                Lane::FollowUp,
            ));
            if held {
                let id = session.pending[0].id.clone();
                session.begin_edit(&id, "held").unwrap();
            }
            cx.notify();
        });
        cx.run_until_parked();
        let header = visual.debug_bounds("queue-header").unwrap();
        let resume = visual.debug_bounds("queue-resume").unwrap();
        assert!(
            resume.left() >= header.left() && resume.right() <= header.right(),
            "resume={resume:?} header={header:?}"
        );
        assert!(resume.top() >= header.top() && resume.bottom() <= header.bottom());
        // Retry adds separate composer furniture; this slice only promises
        // the formerly clipped paused (no Retry) Send geometry above.
    }
}

#[gpui::test]
fn queue_resume_paused_labels_keep_readable_width_across_resize_and_snapshot_refresh(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root, _) = fixture(cx);
    root.update(cx, |view, cx| {
        let session = Arc::make_mut(&mut view.session);
        session.state = RunState::Paused;
        session.queue_paused = true;
        session
            .pending
            .push(Submission::new("remaining B".into(), Lane::FollowUp));
        cx.notify();
    });
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    for (width, height, split) in [
        (1180., 812., false),
        (920., 600., false),
        (920., 600., true),
        (1180., 812., false),
    ] {
        root.update(cx, |view, cx| {
            view.show_files = split;
            view.layout.fraction = 0.5;
            // A new immutable session publication must not change label sizing.
            view.session = Arc::new((*view.session).clone());
            cx.notify();
        });
        visual.simulate_resize(gpui::size(gpui::px(width), gpui::px(height)));
        cx.run_until_parked();
        let header = visual.debug_bounds("queue-header").unwrap();
        let status = visual.debug_bounds("queue-status-label").unwrap();
        let hint = visual.debug_bounds("queue-reorder-label").unwrap();
        let action = visual.debug_bounds("queue-resume").unwrap();
        assert!(
            status.size.width >= gpui::px(if split { 20. } else { 40. }),
            "{status:?}"
        );
        assert!(
            hint.size.width >= gpui::px(if split { 30. } else { 65. }),
            "{hint:?}"
        );
        assert!(
            header.size.height <= gpui::px(if split { 60. } else { 32. }),
            "{header:?}"
        );
        assert!(status.right() <= hint.left());
        assert!(hint.right() <= action.left());
        assert!(action.right() <= header.right());
    }
}

#[gpui::test]
fn archive_guard_blocks_direct_resume_promotion_and_reorder_from_current_records(
    cx: &mut TestAppContext,
) {
    let (_dir, _window, root, turn) = fixture(cx);
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        let draft = view.saved_draft(cx);
        let before = view.controller.snapshot();
        let drag = view.queue_drag_payload(&turn, 1, "queued text");
        view.records
            .iter_mut()
            .find(|record| record.id == id)
            .unwrap()
            .archived_at = Some(1);
        // A cached ChatState record must never reopen actor admission.
        assert!(view.record.archived_at.is_none());
        view.promote_queued(&id, &turn, cx);
        assert!(view.queue_operation.is_none());
        Arc::make_mut(&mut view.session).state = RunState::Paused;
        view.resume_queued(&id, cx);
        assert!(view.queue_operation.is_none());
        view.reorder_queued(&drag, vec![turn.clone()], cx);
        assert!(view.queue_operation.is_none());
        assert_eq!(view.saved_draft(cx), draft);
        assert_eq!(view.controller.snapshot().revision, before.revision);
        assert!(!view.archive_chat_work_live(&id));
        let token = uuid::Uuid::new_v4();
        view.queue_operation = Some(token);
        assert!(view.archive_chat_work_live(&id));
        view.queue_operation = None;
        view.load_failed = true;
        view.edit_recovery.blocked = true;
        assert!(!view.archive_chat_work_live(&id));
    });
}

#[gpui::test]
fn pending_archive_and_known_uncertainty_fence_direct_queue_commands(cx: &mut TestAppContext) {
    let (_dir, _window, root, turn) = fixture(cx);
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        let before = view.saved_draft(cx);
        for uncertain in [false, true] {
            view.known_catalog_uncertainty = uncertain;
            if !uncertain {
                view.set_chat_archived(&id, true, cx);
                assert!(view.has_pending_archive(&id));
            }
            let drag = view.queue_drag_payload(&turn, 1, "queued text");
            Arc::make_mut(&mut view.session).state = RunState::Running;
            view.promote_queued(&id, &turn, cx);
            assert!(view.queue_operation.is_none());
            Arc::make_mut(&mut view.session).state = RunState::Paused;
            view.resume_queued(&id, cx);
            view.reorder_queued(&drag, vec![turn.clone()], cx);
            assert!(view.queue_operation.is_none());
            assert_eq!(view.saved_draft(cx), before);
            assert!(!view.busy);
            view.organization_operations.clear();
        }
        view.known_catalog_uncertainty = false;
    });
}
