//! Real GPUI mouse dispatch against a paused, durable synthetic queue.
use crate::{AgentView, LaunchState};
use bello_agent_core::{
    Controller, Lane, RunState, SessionStore, Submission,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
use gpui::{
    Entity, Focusable, Modifiers, MouseButton, Pixels, Point, TestAppContext, VisualTestContext,
    WindowHandle, point, px,
};
use std::sync::{Arc, Mutex};

fn fixture(
    cx: &mut TestAppContext,
    count: usize,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
    Vec<String>,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let path = project.join("queue.json");
    let mut store = SessionStore::open(&path).unwrap();
    let mut ids = Vec::new();
    store
        .transact(|session| {
            session.state = RunState::Paused;
            session.queue_paused = true;
            let mut steering = Submission::new("existing steering".into(), Lane::Steering);
            steering.id = "steering".into();
            session.pending.push(steering);
            for index in 0..count {
                let mut item =
                    Submission::new(format!("follow {index} e\u{301} 日本語"), Lane::FollowUp);
                item.model = Some("captured".into());
                item.effort = Some("high".into());
                ids.push(item.id.clone());
                session.pending.push(item);
            }
            Ok(())
        })
        .unwrap();
    let snapshot = store.snapshot();
    let record = ChatRecord::new(snapshot.id, snapshot.title, path);
    let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project).unwrap();
    let draft = DraftRecord {
        text: "untouched draft".into(),
        ..Default::default()
    };
    workspace.register(record.clone(), draft.clone()).unwrap();
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
    cx.run_until_parked();
    (dir, window, root, ids)
}
fn row_point(
    root: &Entity<AgentView>,
    cx: &TestAppContext,
    index: usize,
    after: bool,
) -> Point<Pixels> {
    cx.read(|cx| {
        let view = root.read(cx);
        let bounds = view.queue_scroll.bounds_for_item(3 + index).unwrap();
        point(
            bounds.left() + px(55.),
            bounds.top() + if after { px(24.) } else { px(6.) },
        ) + view.queue_scroll.offset()
    })
}
fn begin(visual: &mut VisualTestContext, start: Point<Pixels>) {
    visual.simulate_mouse_move(start, None, Modifiers::none());
    visual.simulate_mouse_down(start, MouseButton::Left, Modifiers::none());
    visual.simulate_mouse_move(
        start + point(px(0.), px(9.)),
        MouseButton::Left,
        Modifiers::none(),
    );
}
fn order(root: &Entity<AgentView>, cx: &TestAppContext) -> Vec<String> {
    cx.read(|cx| {
        root.read(cx)
            .controller
            .snapshot()
            .pending
            .iter()
            .filter(|item| item.lane == Lane::FollowUp)
            .map(|item| item.id.clone())
            .collect()
    })
}

#[gpui::test]
fn queue_drag_mouse_drop_reorders_durably_without_touching_composer(cx: &mut TestAppContext) {
    let (_dir, window, root, ids) = fixture(cx, 3);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let start = row_point(&root, cx, 0, false);
    let end = row_point(&root, cx, 1, true);
    begin(&mut visual, start);
    assert!(cx.read(|cx| root.read(cx).queue_drag.is_some()));
    visual.simulate_mouse_move(end, MouseButton::Left, Modifiers::none());
    visual.simulate_mouse_up(end, MouseButton::Left, Modifiers::none());
    cx.run_until_parked();
    assert_eq!(
        order(&root, cx),
        vec![ids[1].clone(), ids[0].clone(), ids[2].clone()]
    );
    window
        .update(cx, |view, window, cx| {
            assert_eq!(view.composer.read(cx).text(), "untouched draft");
            assert!(view.composer.read(cx).focus_handle(cx).is_focused(window));
            assert!(view.queue_operation.is_none());
            assert!(view.queue_drag.is_none());
            assert!(!view.busy);
            assert_eq!(view.session.pending[0].id, "steering");
        })
        .unwrap();
}

#[gpui::test]
fn queue_drag_escape_and_outside_release_never_reorder(cx: &mut TestAppContext) {
    let (_dir, window, root, ids) = fixture(cx, 3);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    for escape in [true, false] {
        begin(&mut visual, row_point(&root, cx, 0, false));
        assert!(cx.read(|cx| root.read(cx).queue_drag.is_some()));
        if escape {
            visual.simulate_keystrokes("escape");
        }
        let outside = point(px(15.), px(15.));
        visual.simulate_mouse_move(outside, MouseButton::Left, Modifiers::none());
        visual.simulate_mouse_up(outside, MouseButton::Left, Modifiers::none());
        cx.run_until_parked();
        assert_eq!(order(&root, cx), ids);
        assert!(cx.read(|cx| root.read(cx).queue_drag.is_none()));
    }
}

#[gpui::test]
fn queue_drag_changed_membership_reports_source_notice_without_reordering(cx: &mut TestAppContext) {
    let (_dir, window, root, ids) = fixture(cx, 3);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    begin(&mut visual, row_point(&root, cx, 0, false));
    cx.read(|cx| root.read(cx).controller.remove(&ids[2]).unwrap());
    cx.run_until_parked();
    let end = row_point(&root, cx, 1, true);
    visual.simulate_mouse_move(end, MouseButton::Left, Modifiers::none());
    visual.simulate_mouse_up(end, MouseButton::Left, Modifiers::none());
    cx.run_until_parked();
    assert_eq!(order(&root, cx), ids[..2]);
    assert_eq!(
        cx.read(|cx| root.read(cx).error.clone()).as_deref(),
        Some("The queue changed while you were dragging, so nothing was moved. Drag again.")
    );
}

#[gpui::test]
fn queue_drag_navigation_cancels_old_origin_and_keeps_draft(cx: &mut TestAppContext) {
    let (_dir, window, root, ids) = fixture(cx, 3);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let old = cx.read(|cx| root.read(cx).record.id.clone());
    begin(&mut visual, row_point(&root, cx, 0, false));
    window
        .update(cx, |view, window, cx| view.new_chat(window, cx))
        .unwrap();
    cx.run_until_parked();
    assert!(!cx.read(|cx| cx.has_active_drag()));
    let end = point(px(350.), px(250.));
    visual.simulate_mouse_up(end, MouseButton::Left, Modifiers::none());
    cx.read(|cx| {
        let view = root.read(cx);
        assert_ne!(view.record.id, old);
        assert!(view.queue_drag.is_none());
        assert!(view.inactive[&old].queue_drag.is_none());
        assert_eq!(
            view.inactive[&old]
                .controller
                .snapshot()
                .pending
                .iter()
                .filter(|item| item.lane == Lane::FollowUp)
                .map(|item| item.id.clone())
                .collect::<Vec<_>>(),
            ids
        );
        assert_eq!(
            view.inactive[&old].composer.read(cx).text(),
            "untouched draft"
        );
    });
}

#[gpui::test]
fn queue_drag_keeps_row_buttons_clickable_and_edit_hold_disables_drag(cx: &mut TestAppContext) {
    let (_dir, window, root, ids) = fixture(cx, 3);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let point = cx.read(|cx| {
        let view = root.read(cx);
        let bounds = view.queue_scroll.bounds_for_item(3).unwrap();
        point(
            view.queue_scroll.bounds().right() - px(41.),
            bounds.top() + px(15.),
        ) + view.queue_scroll.offset()
    });
    visual.simulate_click(point, Modifiers::none());
    cx.run_until_parked();
    assert!(cx.read(|cx| root.read(cx).editing.is_some()));
    assert_eq!(
        cx.read(|cx| root.read(cx).session.edit.as_ref().unwrap().turn_id.clone()),
        ids[0]
    );
    begin(&mut visual, row_point(&root, cx, 1, false));
    assert!(!cx.read(|cx| cx.has_active_drag()));
    assert!(cx.read(|cx| root.read(cx).queue_drag.is_none()));
    visual.simulate_mouse_up(
        row_point(&root, cx, 1, true),
        MouseButton::Left,
        Modifiers::none(),
    );
    assert_eq!(order(&root, cx), ids);
}

#[gpui::test]
fn queue_drag_edge_scroll_reaches_later_rows_at_minimum_size(cx: &mut TestAppContext) {
    let (_dir, window, root, ids) = fixture(cx, 8);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(gpui::size(px(920.), px(600.)));
    cx.run_until_parked();
    begin(&mut visual, row_point(&root, cx, 0, false));
    let edge = cx.read(|cx| {
        let b = root.read(cx).queue_scroll.bounds();
        point(b.left() + px(55.), b.bottom() - px(3.))
    });
    visual.simulate_mouse_move(edge, MouseButton::Left, Modifiers::none());
    for _ in 0..35 {
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(34));
        cx.run_until_parked();
    }
    assert!(cx.read(|cx| root.read(cx).queue_scroll.offset().y) < px(-100.));
    visual.simulate_mouse_move(edge, MouseButton::Left, Modifiers::none());
    let target = cx.read(|cx| {
        root.read(cx)
            .queue_drag
            .as_ref()
            .unwrap()
            .target
            .clone()
            .unwrap()
    });
    let expected = super::reordered(&ids, &ids[0], &target.0, target.1).unwrap();
    visual.simulate_mouse_up(edge, MouseButton::Left, Modifiers::none());
    cx.run_until_parked();
    assert_eq!(order(&root, cx), expected);
    assert_ne!(expected, ids);
    assert!(cx.read(|cx| root.read(cx).queue_drag_task.is_none()));
}

#[gpui::test]
fn queue_drag_preserves_composition_and_window_rebind_cancels_old_payload(cx: &mut TestAppContext) {
    use gpui::EntityInputHandler;
    let (_dir, window, root, ids) = fixture(cx, 3);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.focus(window);
                editor.replace_and_mark_text_in_range(None, "未確定", Some(3..3), window, cx);
            })
        })
        .unwrap();
    begin(&mut visual, row_point(&root, cx, 0, false));
    let drag = window
        .update(cx, |view, window, cx| {
            assert!(view.composer.read(cx).has_marked_text());
            let drag = view.queue_drag_payload(&ids[0], 1, "fixture");
            assert!(view.accepts_queue_drag(&drag));
            view.bind_window(window, cx);
            assert!(!view.accepts_queue_drag(&drag));
            assert!(view.queue_drag.is_none());
            assert!(view.queue_drag_task.is_none());
            assert!(view.composer.read(cx).has_marked_text());
            drag
        })
        .unwrap();
    assert!(!cx.read(|cx| cx.has_active_drag()));
    window
        .update(cx, |view, window, cx| view.drop_queued(&drag, window, cx))
        .unwrap();
    assert_eq!(order(&root, cx), ids);
}

#[gpui::test]
fn archive_rejects_a_previously_captured_drag_without_reordering(cx: &mut TestAppContext) {
    let (_dir, window, root, ids) = fixture(cx, 3);
    let before = order(&root, cx);
    window
        .update(cx, |view, window, cx| {
            let drag = view.queue_drag_payload(&ids[0], 1, "follow 0");
            assert!(view.accepts_queue_drag(&drag));
            let id = view.record.id.clone();
            view.records
                .iter_mut()
                .find(|record| record.id == id)
                .unwrap()
                .archived_at = Some(1);
            assert!(!view.accepts_queue_drag(&drag));
            view.start_queue_drag(&drag, window, cx);
            assert!(view.queue_drag.is_none());
            view.reorder_queued(&drag, ids.iter().rev().cloned().collect(), cx);
            assert!(view.queue_operation.is_none());
            view.drop_queued(&drag, window, cx);
            assert!(view.queue_operation.is_none());
            assert_eq!(view.composer.read(cx).text(), "untouched draft");
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(order(&root, cx), before);
}
