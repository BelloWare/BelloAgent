//! Fake-platform geometry observations. Native screenshots are separate proof.
use super::*;
use crate::{LaunchState, queue_presentation};
use bello_agent_core::{
    Controller, Lane, RunState, SessionStore, Submission,
    workspace::{ChatRecord, DraftRecord, SubmissionIntent, WorkspaceStore},
};
use gpui::{Entity, Focusable, TestAppContext, VisualTestContext, WindowHandle, point, px, size};
use std::sync::{Arc, Mutex};

fn fixture(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let dir = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(dir.path()).unwrap();
    let mut store = SessionStore::open(project.join("session.json")).unwrap();
    store
        .transact(|session| {
            session.state = RunState::Paused;
            session.queue_paused = true;
            for index in 0..9 {
                session.pending.push(Submission::new(
                    format!("queued {index}"),
                    if index == 0 {
                        Lane::Steering
                    } else {
                        Lane::FollowUp
                    },
                ));
            }
            Ok(())
        })
        .unwrap();
    let session = store.snapshot();
    let record = ChatRecord::new(
        session.id,
        "Geometry fixture".into(),
        project.join("session.json"),
    );
    let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project).unwrap();
    workspace
        .register(record.clone(), DraftRecord::default())
        .unwrap();
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        project,
        workspace: Arc::new(Mutex::new(workspace)),
        record,
        draft: DraftRecord::default(),
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    (dir, window, root)
}
fn assert_measured(
    root: &Entity<AgentView>,
    visual: &mut VisualTestContext,
    cx: &mut TestAppContext,
) {
    cx.run_until_parked();
    let pane = visual.debug_bounds("queue-measured-pane").unwrap();
    let composer = visual.debug_bounds("queue-measured-composer").unwrap();
    let footer = visual.debug_bounds("queue-measured-footer").unwrap();
    let transcript = visual.debug_bounds("queue-measured-transcript").unwrap();
    let context = visual.debug_bounds("session-stats-context").unwrap();
    assert!(
        context.left() >= footer.left() && context.right() <= footer.right(),
        "The context pill must stay readable inside the footer"
    );
    assert!(context.top() >= footer.top() && context.bottom() <= footer.bottom());
    assert!(
        context.size.height <= px(28.),
        "The context pill must not wrap internally"
    );
    cx.read(|cx| {
        let view = root.read(cx);
        let measured = view
            .queue_geometry
            .expect("deferred measurement should settle");
        assert_eq!(measured.pane_height, f32::from(pane.size.height));
        assert_eq!(measured.pane_width, f32::from(pane.size.width));
        assert_eq!(measured.footer_height, f32::from(footer.size.height));
        assert_eq!(
            measured.room(),
            queue_presentation::room(measured.pane_height, measured.composer_height, 0.)
                - (measured.footer_height - queue_presentation::FOOTER_HEIGHT).max(0.)
        );
        assert_eq!(
            measured.composer_height,
            f32::from(composer.size.height) + COMPOSER_TOP + COMPOSER_BOTTOM
        );
        assert_eq!(
            view.queue_scroll.bounds().size.height,
            px(queue_presentation::list_height(9, 2, measured.room()))
        );
        assert!(
            footer.bottom() <= pane.bottom() + px(1.),
            "footer escaped pane: {footer:?} {pane:?}"
        );
        assert!(
            composer.bottom() <= footer.top(),
            "composer overlaps footer"
        );
        assert!(transcript.size.height >= px(0.));
        if measured.room() >= 52. {
            assert!(
                transcript.size.height >= px(150.),
                "reading reserve lost: {transcript:?} room {}",
                measured.room()
            );
        }
    });
}

#[test]
fn measured_composer_adds_source_outer_space_once() {
    let mut bounds = vec![gpui::Bounds::default(); 5];
    bounds[2] = gpui::Bounds::new(point(px(10.), px(200.)), size(px(500.), px(100.)));
    bounds[4] = gpui::Bounds::new(point(px(0.), px(0.)), size(px(620.), px(600.)));
    let measured = QueueGeometry::from_children(&bounds).unwrap();
    assert_eq!(measured.composer_height, 114.);
    assert_eq!(measured.room(), 234.);
    bounds[3].size.height = px(36.);
    assert_eq!(QueueGeometry::from_children(&bounds).unwrap().room(), 234.);
    bounds[3].size.height = px(60.);
    assert_eq!(QueueGeometry::from_children(&bounds).unwrap().room(), 210.);
    assert!(QueueGeometry::from_children(&bounds[..4]).is_none());
    // An open terminal is one more child before the composer, and the
    // queue's room keeps its minimum and chrome (Swift's QueuePanel.room).
    let mut with_terminal = bounds.clone();
    with_terminal.insert(2, gpui::Bounds::default());
    let open = QueueGeometry::from_children(&with_terminal).unwrap();
    assert!(open.terminal);
    assert_eq!(open.composer_height, 114.);
    assert_eq!(open.room(), 210. - 162.);
    assert!(
        QueueGeometry::from_children(&[with_terminal.clone(), vec![Default::default()]].concat())
            .is_none()
    );
    bounds[4].size.height = px(f32::NAN);
    assert!(QueueGeometry::from_children(&bounds).is_none());
}

#[gpui::test]
fn queue_geometry_short_tall_minimum_and_split_panes_use_actual_bounds(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    for (width, height, split) in [
        (1180., 812., false),
        (920., 600., false),
        (1180., 812., true),
        (920., 600., true),
    ] {
        root.update(cx, |view, cx| {
            view.show_files = split;
            view.layout.fraction = 0.5;
            cx.notify();
        });
        visual.simulate_resize(size(px(width), px(height)));
        cx.run_until_parked();
        for text in [
            "short".to_owned(),
            "long draft line with Unicode 日本語 e\u{301}\n".repeat(30),
        ] {
            root.update(cx, |view, cx| {
                view.composer
                    .update(cx, |editor, cx| editor.set_text(text, cx))
            });
            assert_measured(&root, &mut visual, cx);
        }
        // Swift's footer (the session pills) fits one row here; only a
        // footer that wraps reaches the floor below.
        let wrapped = cx.read(|cx| {
            root.read(cx).queue_geometry.unwrap().footer_height > queue_presentation::FOOTER_HEIGHT
        });
        if split && height == 600. && wrapped {
            cx.read(|cx| {
                let view = root.read(cx);
                let geometry = view.queue_geometry.unwrap();
                assert!(geometry.room() < 52.);
                assert_eq!(view.queue_scroll.bounds().size.height, px(52.));
            });
            // The source floor wins when a wrapped footer plus tall composer
            // leaves less than one row's room. Do not claim 150pt in this case.
            assert!(
                visual
                    .debug_bounds("queue-measured-transcript")
                    .unwrap()
                    .size
                    .height
                    < px(150.)
            );
        }
    }
}

#[gpui::test]
fn queue_geometry_edit_and_recovery_banners_are_measured_and_floor_stays_reachable(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = fixture(cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(920.), px(600.)));
    root.update(cx, |view, cx| {
        view.editing = Some("synthetic-edit".into());
        view.composer.update(cx, |editor, cx| {
            editor.set_text("editing line\n".repeat(30), cx)
        });
    });
    assert_measured(&root, &mut visual, cx);
    root.update(cx, |view, cx| {
        view.editing = None;
        let intent = SubmissionIntent {
            skills: Vec::new(),
            attachments: Vec::new(),
            id: "synthetic-recovery".into(),
            chat_id: view.record.id.clone(),
            text: "retained unconfirmed input ".repeat(20),
            lane: Lane::FollowUp,
            draft_revision: 1,
        };
        view.recoveries.insert(intent.id.clone(), intent);
        cx.notify();
    });
    assert_measured(&root, &mut visual, cx);
    // Exact live regression: tall draft + recovery banner + minimum half-pane.
    // Baseline composer shrink must keep the status strip and input reachable.
    let draft = cx.read(|cx| root.read(cx).composer.read(cx).text().to_owned());
    let revision = cx.read(|cx| root.read(cx).draft_revision);
    let focused = window
        .update(cx, |view, window, cx| {
            view.composer.read(cx).focus(window);
            view.composer.read(cx).focus_handle(cx).is_focused(window)
        })
        .unwrap();
    assert!(focused);
    root.update(cx, |view, cx| {
        view.show_files = true;
        view.layout.fraction = 0.5;
        cx.notify();
    });
    assert_measured(&root, &mut visual, cx);
    let field = visual.debug_bounds("queue-measured-field").unwrap();
    let composer = visual.debug_bounds("queue-measured-composer").unwrap();
    assert!(field.size.height >= px(44.));
    assert!(field.bottom() <= composer.bottom());
    assert_eq!(
        cx.read(|cx| root.read(cx).composer.read(cx).text().to_owned()),
        draft
    );
    assert_eq!(cx.read(|cx| root.read(cx).draft_revision), revision);
    assert_eq!(
        window
            .update(cx, |view, window, cx| view
                .composer
                .read(cx)
                .focus_handle(cx)
                .is_focused(window))
            .unwrap(),
        focused
    );
    let stable = cx.read(|cx| root.read(cx).queue_geometry);
    for _ in 0..3 {
        root.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
    }
    assert_eq!(cx.read(|cx| root.read(cx).queue_geometry), stable);
    assert_eq!(
        cx.read(|cx| root.read(cx).queue_scroll.bounds().size.height),
        px(52.)
    );
    root.update(cx, |view, cx| {
        view.queue_scroll.scroll_to_bottom();
        cx.notify();
    });
    cx.run_until_parked();
    cx.read(|cx| {
        let view = root.read(cx);
        let viewport = view.queue_scroll.bounds();
        let mut last = view.queue_scroll.bounds_for_item(10).unwrap();
        last.origin += view.queue_scroll.offset();
        assert!(last.bottom() <= viewport.bottom() + px(1.));
        assert!(last.top() >= viewport.top());
    });
}

#[gpui::test]
fn queue_geometry_collapse_and_stale_measurements_do_not_change_drafts(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(920.), px(600.)));
    assert_measured(&root, &mut visual, cx);
    let before = visual
        .debug_bounds("queue-measured-transcript")
        .unwrap()
        .size
        .height;
    root.update(cx, |view, cx| {
        view.queue_open = false;
        cx.notify();
    });
    cx.run_until_parked();
    assert!(
        visual
            .debug_bounds("queue-measured-transcript")
            .unwrap()
            .size
            .height
            > before
    );
    window
        .update(cx, |view, window, cx| {
            let geometry = view.queue_geometry.unwrap();
            let binding = view.window_binding;
            let id = view.record.id.clone();
            let revision = view.draft_revision;
            let stale = QueueGeometry {
                pane_height: 1.,
                pane_width: 1.,
                composer_height: 999.,
                footer_height: 36.,
                terminal: false,
            };
            view.record_queue_geometry("other chat", binding, stale, cx);
            assert_eq!(view.queue_geometry, Some(geometry));
            view.bind_window(window, cx);
            assert!(view.queue_geometry.is_none());
            view.record_queue_geometry(&id, binding, stale, cx);
            assert!(view.queue_geometry.is_none());
            assert_eq!(view.draft_revision, revision);
            view.queue_open = true;
            cx.notify();
        })
        .unwrap();
    assert_measured(&root, &mut visual, cx);
}
