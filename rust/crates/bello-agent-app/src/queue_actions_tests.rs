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
            assert!(view.queue_promotion.is_none());
            view.promote_queued(&chat_id, &id, cx);
            let token = view.queue_promotion.unwrap();
            view.promote_queued(&chat_id, &id, cx);
            assert_eq!(view.queue_promotion, Some(token));
            assert!(view.composer.read(cx).has_marked_text());
            assert_eq!(view.composer.read(cx).text(), before);
            assert!(!view.busy);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |view, window, cx| {
            assert!(view.queue_promotion.is_none());
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
            view.queue_promotion = Some(token);
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
    assert!(cx.read(|cx| root.read(cx).queue_promotion.is_none()));
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
                view.queue_promotion = Some(token);
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
                view.queue_promotion = Some(retry);
                view.finish_queue_promotion(&id, &project, &controller, retry, Ok(()), cx);
                assert_eq!(
                    view.error.as_deref(),
                    overwritten.then_some("newer unrelated error")
                );
                assert!(view.queue_promotion_error.is_none());
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
            view.queue_promotion = Some(token);
            view.chat.replace_controller(old.clone(), cx);
            assert_eq!(view.queue_promotion, Some(token));
            view.queue_promotion_error = Some("older promotion notice".into());
            view.error = Some("newer unrelated error".into());
            let replacement =
                Controller::new(SessionStore::pending_with_id(&id).unwrap(), None).unwrap();
            view.chat.replace_controller(replacement, cx);
            assert!(view.queue_promotion.is_none());
            assert!(view.queue_promotion_error.is_none());
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
                    view.queue_promotion = Some(token);
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
                    assert_eq!(view.chat_ref(&id).unwrap().queue_promotion, Some(token));
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
                    assert!(view.chat_ref(&id).unwrap().queue_promotion.is_none());
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
