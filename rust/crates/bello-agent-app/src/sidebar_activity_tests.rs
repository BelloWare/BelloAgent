use super::*;

fn record(id: &str, stamp: u64) -> ChatRecord {
    let mut record = ChatRecord::new(id.into(), id.into(), format!("{id}.json").into());
    record.sidebar_order = Some(stamp);
    record
}

#[test]
fn holds_only_activity_keys_and_requires_final_reason_release() {
    let mut hold = SidebarActivityHold::default();
    let mut a = record("a", 1);
    let b = record("b", 2);
    hold.set_pointer(true);
    hold.before_activity_change(&a);
    a.last_activity_at = Some(9);
    let first = uuid::Uuid::new_v4();
    let second = uuid::Uuid::new_v4();
    hold.begin_menu(first);
    hold.begin_menu(second);
    assert!(!hold.end_menu(first));
    assert!(!hold.set_pointer(false));
    assert_eq!(hold.key(&a), Some(1));
    assert!(
        a.sidebar_cmp_with_activity(&b, hold.key(&a), hold.key(&b))
            .is_gt()
    );
    a.pinned_at = Some(1);
    assert!(
        a.sidebar_cmp_with_activity(&b, hold.key(&a), hold.key(&b))
            .is_lt()
    );
    assert_eq!(hold.key(&record("new", 10)), None);
    assert!(hold.end_menu(second));
    assert_eq!(hold.key(&a), None);
}

#[test]
fn background_detach_and_identity_replacement_release_held_keys() {
    let mut hold = SidebarActivityHold::default();
    let a = record("a", 1);
    hold.set_pointer(true);
    hold.before_activity_change(&a);
    let mut replacement = a.clone();
    replacement.snapshot = "replacement.json".into();
    assert_eq!(hold.key(&replacement), None);
    hold.prune(&[replacement]);
    assert!(hold.held.is_empty());
    hold.before_activity_change(&a);
    hold.begin_menu(uuid::Uuid::new_v4());
    assert!(hold.release_all());
    assert!(!hold.active());
}

#[test]
fn newer_dirty_stamp_survives_old_receipt_and_registration() {
    let mut state = ActivityWriteState::default();
    assert!(state.observe(10));
    assert_eq!(state.begin(false), None);
    state.acknowledge(8);
    let first = state.begin(true).unwrap();
    assert!(state.observe(20));
    assert_eq!(state.begin(true), None);
    assert!(state.confirm(first, 10));
    assert_eq!(state.dirty, Some(20));
    let second = state.begin(true).unwrap();
    assert!(!state.confirm(first, 100));
    assert!(state.confirm(second, 20));
    assert!(!state.is_pending());
    assert!(!state.observe(19));
}

#[test]
fn definite_failure_retries_are_bounded_and_uncertainty_never_retries() {
    let mut state = ActivityWriteState::default();
    state.observe(10);
    for _ in 0..ActivityWriteState::MAX_FAILURES {
        let write = state.begin(true).unwrap();
        assert!(state.fail(write, false));
    }
    assert_eq!(state.begin(true), None);
    assert_eq!(state.dirty, Some(10));
    state.flush();
    let write = state.begin(true).unwrap();
    state.fail(write, true);
    state.flush();
    assert_eq!(state.begin(true), None);
    assert!(state.is_pending());
}

fn fixture(
    cx: &mut gpui::TestAppContext,
    pending: bool,
) -> (
    tempfile::TempDir,
    gpui::WindowHandle<AgentView>,
    gpui::Entity<AgentView>,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let controller = Controller::new(bello_agent_core::SessionStore::pending(), None).unwrap();
    let record = ChatRecord::new(
        controller.snapshot().id,
        "Activity fixture".into(),
        project.join("session.json"),
    );
    let workspace = Arc::new(Mutex::new(
        WorkspaceStore::open(project.join("catalog.json"), &project).unwrap(),
    ));
    if !pending {
        workspace
            .lock()
            .unwrap()
            .register(record.clone(), Default::default())
            .unwrap();
    }
    let launch = crate::LaunchState {
        controller,
        record,
        project,
        workspace,
        draft: Default::default(),
        pending,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let view = window.root(cx).unwrap();
    cx.run_until_parked();
    (dir, window, view)
}

#[gpui::test]
fn pending_activity_never_materializes_and_newer_registration_race_drains(
    cx: &mut gpui::TestAppContext,
) {
    let (dir, window, view) = fixture(cx, true);
    window
        .update(cx, |view, _, cx| {
            let workspace = view.workspace.clone();
            let record = view.record.clone();
            let source = Arc::downgrade(&view.controller);
            view.receive_activity(
                &workspace,
                &record.id,
                &record.snapshot,
                &source,
                SemanticActivity {
                    sequence: 1,
                    timestamp_micros: Some(10),
                },
                cx,
            );
            assert!(view.pending);
            assert!(workspace.lock().unwrap().snapshot().chats.is_empty());
            let captured = view.record.clone();
            view.receive_activity(
                &workspace,
                &record.id,
                &record.snapshot,
                &source,
                SemanticActivity {
                    sequence: 2,
                    timestamp_micros: Some(20),
                },
                cx,
            );
            workspace
                .lock()
                .unwrap()
                .register(captured, Default::default())
                .unwrap();
            view.pending = false;
            view.request_activity_drain(cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = view.read(cx);
        assert_eq!(
            view.workspace.lock().unwrap().snapshot().chats[0].last_activity_at,
            Some(20)
        );
        assert!(!view.activity_write.is_pending());
    });
    assert!(!dir.path().join("session.json").exists());
}

#[gpui::test]
fn stale_actor_snapshot_and_workspace_cannot_promote_activity(cx: &mut gpui::TestAppContext) {
    let (_dir, window, _) = fixture(cx, false);
    window
        .update(cx, |view, _, cx| {
            let workspace = view.workspace.clone();
            let record = view.record.clone();
            let source = Arc::downgrade(&view.controller);
            let stranger =
                Controller::new(bello_agent_core::SessionStore::pending(), None).unwrap();
            view.receive_activity(
                &workspace,
                &record.id,
                &record.snapshot,
                &Arc::downgrade(&stranger),
                SemanticActivity {
                    sequence: 1,
                    timestamp_micros: Some(99),
                },
                cx,
            );
            view.receive_activity(
                &workspace,
                &record.id,
                std::path::Path::new("wrong.json"),
                &source,
                SemanticActivity {
                    sequence: 2,
                    timestamp_micros: Some(99),
                },
                cx,
            );
            let other_dir = tempfile::tempdir().unwrap();
            let other_project = std::fs::canonicalize(other_dir.path()).unwrap();
            let other_workspace = Arc::new(Mutex::new(
                WorkspaceStore::open(other_project.join("catalog.json"), &other_project).unwrap(),
            ));
            view.receive_activity(
                &other_workspace,
                &record.id,
                &record.snapshot,
                &source,
                SemanticActivity {
                    sequence: 3,
                    timestamp_micros: Some(99),
                },
                cx,
            );
            assert_eq!(view.record.last_activity_at, None);
            assert!(!view.activity_write.is_pending());
        })
        .unwrap();
}

#[gpui::test]
fn visible_order_uses_held_keys_but_keeps_pin_archive_and_new_rows_live(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window, _) = fixture(cx, true);
    window
        .update(cx, |view, _, cx| {
            let mut first = view.record.clone();
            first.sidebar_order = Some(1);
            let second = record("second", 2);
            view.records = vec![first.clone(), second.clone()];
            view.sidebar_activity_hold.set_pointer(true);
            view.merge_activity(&first.id, &first.snapshot, 10);
            assert_eq!(view.visible_sidebar_records(cx)[0].id, "second");
            view.records[0].pinned_at = Some(1);
            assert_eq!(view.visible_sidebar_records(cx)[0].id, first.id);
            view.records[0].archived_at = Some(1);
            assert_eq!(view.visible_sidebar_records(cx).len(), 1);
            view.records.push(record("new", 20));
            assert_eq!(view.visible_sidebar_records(cx)[0].id, "new");
            view.records[0].archived_at = None;
            view.records[0].pinned_at = None;
            view.sidebar_activity_hold.release_all();
            assert_eq!(view.visible_sidebar_records(cx)[1].id, first.id);
        })
        .unwrap();
}

#[test]
fn snapshot_replacement_cannot_settle_old_write_or_inherit_dirty_activity() {
    let a = record("a", 1);
    let mut state = ActivityWriteState::for_record(&a);
    state.observe(10);
    let old = state.begin(true).unwrap();
    assert!(state.adopt_record(&a));
    assert!(state.is_pending());
    let mut replacement = a.clone();
    replacement.snapshot = "new-snapshot.json".into();
    assert!(!state.adopt_record(&replacement));
    assert!(!state.confirm(old, 10));
    assert!(!state.is_pending());
}

#[test]
fn stale_uncertain_completion_fences_even_without_matching_write_token() {
    let mut state = ActivityWriteState::default();
    state.observe(10);
    let current = state.begin(true).unwrap();
    let stale = ActivityWrite {
        token: uuid::Uuid::new_v4(),
        stamp: 1,
    };
    assert!(!state.fail(stale, true));
    assert!(state.confirm(current, 10));
    state.observe(20);
    state.flush();
    assert_eq!(state.begin(true), None);
}

#[gpui::test]
fn already_active_constructor_captures_watermark_without_a_later_event(
    cx: &mut gpui::TestAppContext,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let path = project.join("session.json");
    let mut store = bello_agent_core::SessionStore::open(&path).unwrap();
    let item = bello_agent_core::Submission::new("queued".into(), bello_agent_core::Lane::FollowUp);
    let id = item.id.clone();
    store.transact(|session| session.submit(item)).unwrap();
    let controller = Controller::new(store, None).unwrap();
    controller.begin_edit(&id, "accepted-save").unwrap();
    controller
        .resolve_edit("accepted-save", "saved", Some("queued"))
        .unwrap();
    let stamp = controller.activity().timestamp_micros.unwrap();
    let record = ChatRecord::new(controller.snapshot().id, controller.snapshot().title, path);
    let workspace = Arc::new(Mutex::new(
        WorkspaceStore::open(project.join("catalog.json"), &project).unwrap(),
    ));
    workspace
        .lock()
        .unwrap()
        .register(record.clone(), Default::default())
        .unwrap();
    let launch = crate::LaunchState {
        controller,
        record,
        project,
        workspace: workspace.clone(),
        draft: Default::default(),
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    assert_eq!(
        workspace.lock().unwrap().snapshot().chats[0].last_activity_at,
        Some(stamp)
    );
    cx.read(|cx| assert!(!root.read(cx).activity_write.is_pending()));
}

#[gpui::test]
fn connection_result_preserves_late_activity_only_for_matching_snapshot(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window, _) = fixture(cx, true);
    window
        .update(cx, |view, _, _| {
            let mut captured = view.record.clone();
            captured.connection_id = Some("new-connection".into());
            let id = captured.id.clone();
            let path = captured.snapshot.clone();
            view.merge_activity(&id, &path, 100);
            view.preserve_connection_activity(&mut captured);
            assert_eq!(captured.last_activity_at, Some(100));
            assert_eq!(captured.connection_id.as_deref(), Some("new-connection"));
            let mut replacement = captured.clone();
            replacement.snapshot = "another-snapshot.json".into();
            replacement.last_activity_at = None;
            view.preserve_connection_activity(&mut replacement);
            assert_eq!(replacement.last_activity_at, None);
        })
        .unwrap();
}

#[gpui::test]
fn actual_list_hover_menu_topic_background_and_detach_release(cx: &mut gpui::TestAppContext) {
    use gpui::{Modifiers, VisualTestContext, point, px};
    let (_dir, window, root) = fixture(cx, true);
    window
        .update(cx, |_, window, _| window.activate_window())
        .unwrap();
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let bounds = visual.debug_bounds("sidebar-activity-list").unwrap();
    let inside = bounds.origin + point(px(15.), px(15.));
    visual.simulate_mouse_move(inside, None, Modifiers::none());
    window
        .update(cx, |view, window, cx| {
            assert!(
                view.sidebar_activity_hold.pointer,
                "active={} bounds={bounds:?} mouse={:?}",
                window.is_window_active(),
                window.mouse_position()
            );
            let record = view.record.clone();
            view.sidebar_activity_hold.before_activity_change(&record);
            view.open_sidebar_menu(&record.id, inside, window, cx);
            assert!(view.sidebar_activity_hold.menu.is_some());
            view.recheck_sidebar_pointer(None);
            assert!(
                view.sidebar_activity_hold.pointer,
                "unknown native location cannot manufacture exit"
            );
            view.open_topics(&record.id, window, cx);
            assert!(view.sidebar_menu.is_none());
            assert!(view.sidebar_activity_hold.menu.is_none());
            assert!(view.sidebar_activity_hold.pointer);
        })
        .unwrap();
    visual.deactivate_window();
    cx.run_until_parked();
    cx.read(|cx| assert!(!root.read(cx).sidebar_activity_hold.active()));
    window
        .update(cx, |view, window, _| {
            view.sidebar_activity_hold.set_pointer(true);
            let record = view.record.clone();
            view.sidebar_activity_hold.before_activity_change(&record);
            window.remove_window();
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        assert!(!root.read(cx).sidebar_activity_hold.active());
        assert!(root.read(cx).sidebar_activity_hold.held.is_empty());
    });
}

#[gpui::test]
fn receiver_baseline_delivers_event_without_constructor_capture_or_later_event(
    cx: &mut gpui::TestAppContext,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let path = project.join("session.json");
    let mut store = bello_agent_core::SessionStore::open(&path).unwrap();
    let item = bello_agent_core::Submission::new("queued".into(), bello_agent_core::Lane::FollowUp);
    let item_id = item.id.clone();
    store.transact(|session| session.submit(item)).unwrap();
    let controller = Controller::new(store, None).unwrap();
    let record = ChatRecord::new(controller.snapshot().id, controller.snapshot().title, path);
    let workspace = Arc::new(Mutex::new(
        WorkspaceStore::open(project.join("catalog.json"), &project).unwrap(),
    ));
    workspace
        .lock()
        .unwrap()
        .register(record.clone(), Default::default())
        .unwrap();
    let launch = crate::LaunchState {
        controller,
        record,
        project,
        workspace: workspace.clone(),
        draft: Default::default(),
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    cx.run_until_parked();
    let stamp = window
        .update(cx, |view, _, cx| {
            view._activity_poll = Task::ready(());
            assert_eq!(view.record.last_activity_at, None);
            view.controller
                .begin_edit(&item_id, "subscription-gap")
                .unwrap();
            view.controller
                .resolve_edit("subscription-gap", "saved", Some("queued"))
                .unwrap();
            let stamp = view.controller.activity().timestamp_micros.unwrap();
            view._activity_poll = subscribe(&view.controller, &view.record, workspace.clone(), cx);
            assert_eq!(
                view.record.last_activity_at, None,
                "no direct capture took place"
            );
            stamp
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(
        workspace.lock().unwrap().snapshot().chats[0].last_activity_at,
        Some(stamp)
    );
}

#[gpui::test]
fn first_activity_after_scope_reset_holds_existing_pointer_without_new_hover(
    cx: &mut gpui::TestAppContext,
) {
    use gpui::{Modifiers, VisualTestContext, point, px};
    let (_dir, window, root) = fixture(cx, true);
    window
        .update(cx, |_, window, _| window.activate_window())
        .unwrap();
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let bounds = visual.debug_bounds("sidebar-activity-list").unwrap();
    visual.simulate_mouse_move(
        bounds.origin + point(px(15.), px(15.)),
        None,
        Modifiers::none(),
    );
    window
        .update(cx, |view, window, cx| {
            assert!(view.sidebar_activity_hold.pointer);
            view.bind_window(window, cx);
            // No move/hover event follows the rebind. The first activity still
            // retains the old visible key before fresh layout can run.
            let record = view.record.clone();
            let previous = record.activity_stamp();
            view.merge_activity(&record.id, &record.snapshot, previous + 10);
            assert_eq!(view.sidebar_activity_hold.key(&view.record), Some(previous));
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| assert!(root.read(cx).sidebar_activity_hold.active()));
    visual.simulate_mouse_move(point(px(1.), px(1.)), None, Modifiers::none());
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.sidebar_activity_hold.pointer);
        assert!(view.sidebar_activity_hold.held.is_empty());
    });
}

#[gpui::test]
fn keyboard_traversal_matches_held_and_released_visible_order(cx: &mut gpui::TestAppContext) {
    let (_dir, window, _) = fixture(cx, true);
    window
        .update(cx, |view, window, cx| {
            let first = view.record.id.clone();
            view.composer.update(cx, |editor, cx| {
                editor.set_text("preserved first draft".into(), cx)
            });
            view.new_chat(window, cx);
            let second = view.record.id.clone();
            view.composer.update(cx, |editor, cx| {
                editor.set_text("preserved second draft".into(), cx)
            });
            assert_ne!(first, second);
            for record in &mut view.records {
                record.sidebar_order = Some(if record.id == first { 1 } else { 2 });
            }
            let target = view
                .records
                .iter()
                .find(|record| record.id == first)
                .unwrap()
                .clone();
            view.sidebar_activity_hold.set_pointer(true);
            view.merge_activity(&first, &target.snapshot, 3);
            assert_eq!(view.visible_sidebar_records(cx)[0].id, second);
            view.select_adjacent_chat(true, window, cx);
            assert_eq!(view.record.id, first);
            view.sidebar_activity_hold.release_all();
            assert_eq!(view.visible_sidebar_records(cx)[0].id, first);
            view.select_adjacent_chat(true, window, cx);
            assert_eq!(view.record.id, second);
        })
        .unwrap();
}

#[gpui::test]
fn cached_outside_point_cannot_resolve_unknown_after_rebind(cx: &mut gpui::TestAppContext) {
    use gpui::{Modifiers, VisualTestContext, point, px};
    let (_dir, window, root) = fixture(cx, true);
    window
        .update(cx, |_, window, _| window.activate_window())
        .unwrap();
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_mouse_move(point(px(1.), px(1.)), None, Modifiers::none());
    window
        .update(cx, |view, window, cx| {
            assert!(!view.sidebar_activity_hold.pointer);
            view.bind_window(window, cx);
            assert!(view.sidebar_activity_hold.pointer_unknown);
            let record = view.record.clone();
            view.merge_activity(&record.id, &record.snapshot, record.activity_stamp() + 10);
            assert!(view.sidebar_activity_hold.key(&view.record).is_some());
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(view.sidebar_activity_hold.pointer_unknown);
        assert!(view.sidebar_activity_hold.key(&view.record).is_some());
    });
    visual.simulate_mouse_move(point(px(1.), px(1.)), None, Modifiers::none());
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(!view.sidebar_activity_hold.active());
        assert!(view.sidebar_activity_hold.held.is_empty());
    });
}

#[gpui::test]
fn stale_painted_pointer_callback_cannot_release_invalidated_geometry(
    cx: &mut gpui::TestAppContext,
) {
    use gpui::{Bounds, point, px, size};
    let (_dir, window, _) = fixture(cx, true);
    window
        .update(cx, |view, _, _| {
            let old = Bounds::new(point(px(0.), px(0.)), size(px(100.), px(100.)));
            let newer = Bounds::new(point(px(0.), px(0.)), size(px(200.), px(200.)));
            let record = view.record.clone();
            view.sidebar_activity_hold.set_pointer(true);
            view.sidebar_activity_hold.before_activity_change(&record);
            view.sidebar_activity_hold.bounds.set(None);
            view.sidebar_activity_hold.pointer_unknown = true;
            let outside = point(px(500.), px(500.));
            assert!(!view.sidebar_pointer_moved(view.window_binding, old, outside, true));
            assert!(view.sidebar_activity_hold.key(&record).is_some());
            view.sidebar_activity_hold.bounds.set(Some(newer));
            assert!(!view.sidebar_pointer_moved(view.window_binding, old, outside, true));
            assert!(view.sidebar_activity_hold.key(&record).is_some());
            assert!(view.sidebar_pointer_moved(view.window_binding, newer, outside, true));
            assert!(!view.sidebar_activity_hold.active());
        })
        .unwrap();
}
