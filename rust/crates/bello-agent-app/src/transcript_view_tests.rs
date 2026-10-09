//! Fake-platform regression tests for the retained, visible-row transcript.
//! Cache-hit assertions use production notifications, never Window::refresh:
//! GPUI deliberately bypasses AnyView caching during a forced refresh.
use crate::{
    AgentView, LaunchState, Palette,
    transcript_actions::MessageKey,
    transcript_view::{TranscriptInput, TranscriptView},
};
use bello_agent_core::{
    Controller, Lane, Message, RunState, Session, SessionStore, Submission,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
use gpui::{
    AnyView, Bounds, ClipboardItem, Entity, EntityInputHandler, Focusable, ListOffset, ListState,
    Modifiers, MouseButton, Pixels, Point, ScrollDelta, ScrollWheelEvent, StyleRefinement,
    TestAppContext, VisualTestContext, Window, WindowAppearance, WindowHandle, div, point,
    prelude::*, px, size,
};
use std::sync::{Arc, Mutex};

fn message(id: &str, role: &str, text: &str) -> Message {
    Message {
        task_root_id: None,
        user_content: None,
        id: id.into(),
        role: role.into(),
        text: text.into(),
        reasoning: String::new(),
        replay_eligible: true,
        state: "complete".into(),
        usage: serde_json::Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
    }
}

fn messages(count: usize) -> Vec<Message> {
    (0..count)
        .map(|index| {
            message(
                &format!("message-{index}"),
                if index % 2 == 0 { "user" } else { "assistant" },
                &format!("Transcript row {index}: 日本語 e\u{301}"),
            )
        })
        .collect()
}

fn fixture_with_visible(
    cx: &mut TestAppContext,
    rows: Vec<Message>,
    queued: usize,
    visible_messages: Option<usize>,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    let directory = tempfile::tempdir().unwrap();
    let project = std::fs::canonicalize(directory.path()).unwrap();
    let path = project.join("session.json");
    let mut store = SessionStore::open(&path).unwrap();
    store
        .transact(|session| {
            session.messages = rows;
            session.state = RunState::Paused;
            session.queue_paused = true;
            session.pending = (0..queued)
                .map(|index| Submission::new(format!("queued {index}"), Lane::FollowUp))
                .collect();
            Ok(())
        })
        .unwrap();
    let snapshot = store.snapshot();
    let record = ChatRecord::new(snapshot.id, "Transcript fixture".into(), path);
    let draft = DraftRecord {
        skills: Vec::new(),
        attachments: Vec::new(),
        text: "draft".into(),
        ..Default::default()
    };
    let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project).unwrap();
    workspace.register(record.clone(), draft.clone()).unwrap();
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        project,
        workspace: Arc::new(Mutex::new(workspace)),
        record,
        draft,
        pending: false,
    };
    let window = cx.add_window(|window, cx| {
        let mut view = AgentView::new(launch, window, cx);
        if let Some(visible_messages) = visible_messages {
            view.visible_messages = visible_messages;
        }
        view
    });
    let root = window.root(cx).unwrap();
    let visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(1180.), px(812.)));
    cx.run_until_parked();
    (directory, window, root)
}

fn fixture(
    cx: &mut TestAppContext,
    rows: Vec<Message>,
    queued: usize,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
) {
    fixture_with_visible(cx, rows, queued, None)
}

fn transcript(root: &Entity<AgentView>, cx: &TestAppContext) -> Entity<TranscriptView> {
    cx.read(|cx| {
        root.read(cx)
            .transcript
            .clone()
            .expect("populated transcript")
    })
}

fn renders(child: &Entity<TranscriptView>, cx: &TestAppContext) -> usize {
    cx.read(|cx| child.read(cx).render_count())
}

fn scroll(child: &Entity<TranscriptView>, cx: &TestAppContext) -> ListState {
    // Resizing replaces GPUI's ListState because its overdraw is immutable.
    // Never retain this handle across geometry changes.
    cx.read(|cx| child.read(cx).list_state())
}

fn row_ids(child: &Entity<TranscriptView>, cx: &TestAppContext) -> Vec<String> {
    cx.read(|cx| child.read(cx).logical_row_ids())
}

fn materialized(child: &Entity<TranscriptView>, cx: &TestAppContext) -> Vec<usize> {
    cx.read(|cx| child.read(cx).materialized_indexes())
}

fn anchor(child: &Entity<TranscriptView>, cx: &TestAppContext) -> (String, Pixels) {
    let offset = scroll(child, cx).logical_scroll_top();
    (
        row_ids(child, cx)[offset.item_ix].clone(),
        offset.offset_in_item,
    )
}

fn jump_to(child: &Entity<TranscriptView>, index: usize, offset: f32, cx: &mut TestAppContext) {
    scroll(child, cx).scroll_to(ListOffset {
        item_ix: index,
        offset_in_item: px(offset),
    });
    child.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
}

fn reveal_all(root: &Entity<AgentView>, cx: &mut TestAppContext) {
    root.update(cx, |view, cx| {
        view.visible_messages = usize::MAX;
        cx.notify();
    });
    cx.run_until_parked();
}

fn current_row_bounds(
    visual: &mut VisualTestContext,
    child: &Entity<TranscriptView>,
    id: &str,
    cx: &TestAppContext,
) -> Bounds<Pixels> {
    let index = row_ids(child, cx).iter().position(|row| row == id).unwrap();
    assert!(
        materialized(child, cx).contains(&index),
        "{id} was not materialized this frame"
    );
    assert!(
        cx.read(|cx| child.read(cx).painted_indexes())
            .contains(&index),
        "{id} was measured for overdraw but was not painted in this frame"
    );
    // VisualTestContext's selector API requires a static string. This leaks only
    // the handful of selector names used by these finite regression cases.
    let selector = Box::leak(format!("transcript-row-{id}").into_boxed_str());
    let bounds = visual.debug_bounds(selector).unwrap();
    let viewport = scroll(child, cx).viewport_bounds();
    assert!(
        bounds.bottom() > viewport.top() && bounds.top() < viewport.bottom(),
        "{id} debug selector is not in the current viewport: {bounds:?}, {viewport:?}"
    );
    bounds
}

fn snapshot_change(
    root: &Entity<AgentView>,
    cx: &mut TestAppContext,
    change: impl FnOnce(&mut Session),
) {
    root.update(cx, |view, cx| {
        let mut session = (*view.session).clone();
        change(&mut session);
        let id = view.record.id.clone();
        view.receive_snapshot(
            &id,
            &Arc::downgrade(&view.controller),
            Arc::new(session),
            cx,
        );
    });
    cx.run_until_parked();
}

fn input(root: &Entity<AgentView>, cx: &TestAppContext) -> TranscriptInput {
    cx.read(|cx| {
        let view = root.read(cx);
        TranscriptInput {
            controller: Arc::downgrade(&view.controller),
            chat_id: view.record.id.clone(),
            session: view.session.clone(),
            visible_messages: view.visible_messages,
            palette: view.palette,
            pane_width: view.pane_width,
            loading: view.loading,
            load_failed: view.load_failed,
        }
    })
}

// A fixed-size cached host isolates the explicit input contract from the
// production root's appearance normalization and pane-width calculation.
struct TranscriptHost(Entity<TranscriptView>);
impl Render for TranscriptHost {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().flex().child(
            AnyView::from(self.0.clone())
                .cached(StyleRefinement::default().flex_1().min_h_0().w_full()),
        )
    }
}

// A one-shot capture hook installs new presentation input during a real wheel
// dispatch, before the previous frame's List bubble listener handles that wheel.
struct WheelInputHost {
    child: Entity<TranscriptView>,
    pending: std::rc::Rc<std::cell::RefCell<Option<TranscriptInput>>>,
}

impl Render for WheelInputHost {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let child = self.child.downgrade();
        let pending = self.pending.clone();
        div()
            .relative()
            .size_full()
            .flex()
            .child(
                AnyView::from(self.child.clone())
                    .cached(StyleRefinement::default().flex_1().min_h_0().w_full()),
            )
            .child(
                gpui::canvas(
                    |_, _, _| (),
                    move |_, _, window, _| {
                        window.on_mouse_event(move |_: &ScrollWheelEvent, phase, _, cx| {
                            if phase == gpui::DispatchPhase::Capture
                                && let Some(input) = pending.borrow_mut().take()
                            {
                                child
                                    .update(cx, |view, cx| view.update_inputs(input, cx))
                                    .unwrap();
                            }
                        });
                    },
                )
                .absolute()
                .inset_0(),
            )
    }
}

fn host(
    root: &Entity<AgentView>,
    input: TranscriptInput,
    cx: &mut TestAppContext,
) -> (VisualTestContext, Entity<TranscriptView>) {
    let parent = root.downgrade();
    let window =
        cx.add_window(|_, cx| TranscriptHost(cx.new(|_| TranscriptView::new(parent, input))));
    let host = window.root(cx).unwrap();
    let child = cx.read(|cx| host.read(cx).0.clone());
    let visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(700.), px(620.)));
    cx.run_until_parked();
    (visual, child)
}

fn first_child_target(child: &Entity<TranscriptView>, cx: &TestAppContext) -> Point<Pixels> {
    let handle = scroll(child, cx);
    let bounds = handle.bounds_for_item(0).expect("available first child");
    let target = bounds.center();
    assert!(bounds.size.width > px(0.) && bounds.size.height > px(0.));
    assert!(
        handle.viewport_bounds().contains(&target),
        "target must be in viewport"
    );
    target
}

fn click_first_copy(
    visual: &mut VisualTestContext,
    child: &Entity<TranscriptView>,
    cx: &TestAppContext,
) {
    // GPUI retains debug selectors across cached frames. Pick the hover point
    // from the current scroll children, then inspect fresh hover-render bounds.
    let handle = scroll(child, cx);
    let current_row = current_row_bounds(visual, child, "message-0", cx);
    let hover = current_row.origin + point(px(10.), px(10.));
    assert!(current_row.contains(&hover) && handle.viewport_bounds().contains(&hover));
    let before = renders(child, cx);
    visual.simulate_mouse_move(hover, None::<MouseButton>, Modifiers::none());
    assert!(
        renders(child, cx) > before,
        "row hover must reveal its Copy action"
    );
    let row = visual
        .debug_bounds("transcript-row-message-0")
        .expect("hover-rendered first row");
    let viewport = handle.viewport_bounds();
    let pill = visual
        .debug_bounds("copy-pill-message-0")
        .expect("rendered Copy target");
    assert!(pill.size.width > px(0.) && pill.size.height > px(0.));
    assert!(
        row.contains(&pill.center()) && viewport.contains(&pill.center()),
        "Copy target outside available row/viewport: pill {pill:?}, row {row:?}, viewport {viewport:?}"
    );
    visual.simulate_mouse_move(pill.center(), None::<MouseButton>, Modifiers::none());
    visual.simulate_click(pill.center(), Modifiers::none());
}

#[gpui::test]
fn visible_rows_keep_exact_source_gutters_gap_bottom_and_max_width(cx: &mut TestAppContext) {
    let (_directory, _window, root) = fixture(cx, messages(30), 0);
    let (mut visual, child) = host(&root, input(&root, cx), cx);
    for width in [700., 1100., 700.] {
        visual.simulate_resize(size(px(width), px(620.)));
        cx.run_until_parked();
        jump_to(&child, 0, 0., cx);
        let viewport = scroll(&child, cx).viewport_bounds();
        let first = current_row_bounds(&mut visual, &child, "message-0", cx);
        let second = current_row_bounds(&mut visual, &child, "message-1", cx);
        assert_eq!(first.top(), viewport.top(), "no new top padding");
        assert_eq!(first.size.width, px((width - 48.).min(840.)));
        assert_eq!(
            first.left() - viewport.left(),
            (viewport.size.width - first.size.width) / 2.
        );
        if width == 700. {
            assert_eq!(first.left() - viewport.left(), px(24.));
            assert_eq!(viewport.right() - first.right(), px(24.));
        }
        assert_eq!(second.top() - first.bottom(), px(16.));
        jump_to(&child, 29, 0., cx);
        let last = current_row_bounds(&mut visual, &child, "message-29", cx);
        assert_eq!(
            viewport.bottom() - last.bottom(),
            px(13.),
            "no trailing row gap"
        );
    }
}

#[gpui::test]
fn initial_list_stays_top_aligned_and_parent_notifications_preserve_it(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, messages(100), 0);
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert_eq!(anchor(&child, cx), ("message-0".into(), px(0.)));
    assert_eq!(
        current_row_bounds(&mut visual, &child, "message-0", cx).top(),
        scroll(&child, cx).viewport_bounds().top()
    );
    assert!(!materialized(&child, cx).contains(&99));
    let before = renders(&child, cx);
    for _ in 0..3 {
        root.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
        assert_eq!(renders(&child, cx), before);
        assert_eq!(anchor(&child, cx), ("message-0".into(), px(0.)));
    }
}

#[gpui::test]
fn splice_and_same_identity_height_changes_preserve_row_and_pixel_anchor(cx: &mut TestAppContext) {
    let (_directory, _window, root) = fixture(cx, messages(80), 0);
    reveal_all(&root, cx);
    let child = transcript(&root, cx);
    jump_to(&child, 40, 11., cx);
    let expected = ("message-40".into(), px(11.));
    assert_eq!(anchor(&child, cx), expected);
    snapshot_change(&root, cx, |session| {
        session.messages.splice(
            0..0,
            [
                message("inserted-a", "system", "A"),
                message("inserted-b", "user", "B"),
            ],
        );
    });
    assert_eq!(anchor(&child, cx), expected);
    assert_eq!(scroll(&child, cx).logical_scroll_top().item_ix, 42);
    snapshot_change(&root, cx, |session| {
        session.messages[42].text = "same ID, taller line 日本語\n".repeat(12);
    });
    assert_eq!(
        anchor(&child, cx),
        expected,
        "GPUI splice resets offsets unless restored explicitly"
    );
    snapshot_change(&root, cx, |session| {
        session.messages.drain(0..2);
        session.messages[40].text = "short again".into();
    });
    assert_eq!(anchor(&child, cx), expected);
    assert_eq!(scroll(&child, cx).logical_scroll_top().item_ix, 40);
}

#[gpui::test]
fn resize_updates_half_viewport_buffer_without_losing_anchor(cx: &mut TestAppContext) {
    let (_directory, _window, root) = fixture(cx, messages(100), 0);
    let (visual, child) = host(&root, input(&root, cx), cx);
    jump_to(&child, 40, 9., cx);
    let expected = anchor(&child, cx);
    for (width, height) in [
        (700., 360.),
        (700., 1000.),
        (460., 620.),
        (1100., 480.),
        (700., 620.),
    ] {
        visual.simulate_resize(size(px(width), px(height)));
        cx.run_until_parked();
        let viewport = scroll(&child, cx).viewport_bounds();
        assert_eq!(
            cx.read(|cx| child.read(cx).buffer_margin()),
            (viewport.size.height / 2.).max(px(240.))
        );
        assert_eq!(
            anchor(&child, cx),
            expected,
            "resize {width}x{height} changed row/pixel anchor"
        );
        assert!(
            materialized(&child, cx).len() < 40,
            "resizing materialized the full history"
        );
        let before = renders(&child, cx);
        // A later explicit invalidation must not restore an older offset.
        child.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
        assert!(renders(&child, cx) > before);
        assert_eq!(anchor(&child, cx), expected);
    }
}

#[gpui::test]
fn width_only_resize_remeasures_wrapped_rows_and_preserves_anchor(cx: &mut TestAppContext) {
    let mut rows = messages(160);
    for row in &mut rows {
        row.role = "assistant".into();
        row.text = "Wrapping width proof 日本語 e\u{301} and ordinary words. ".repeat(40);
    }
    let (_directory, _window, root) = fixture_with_visible(cx, rows, 0, Some(160));
    let (mut visual, child) = host(&root, input(&root, cx), cx);
    jump_to(&child, 2, 0., cx);
    current_row_bounds(&mut visual, &child, "message-2", cx);
    let wide_height = visual
        .debug_bounds("transcript-text-message-2")
        .unwrap()
        .size
        .height;
    jump_to(&child, 80, 13., cx);
    let expected = anchor(&child, cx);
    let buffer = cx.read(|cx| child.read(cx).buffer_margin());
    // Height remains fixed: the overdraw-replacement path cannot accidentally
    // make this test pass by discarding all of GPUI's cached measurements.
    visual.simulate_resize(size(px(460.), px(620.)));
    cx.run_until_parked();
    assert_eq!(cx.read(|cx| child.read(cx).buffer_margin()), buffer);
    assert_eq!(anchor(&child, cx), expected);
    assert!(materialized(&child, cx).len() < 20);
    jump_to(&child, 2, 0., cx);
    current_row_bounds(&mut visual, &child, "message-2", cx);
    assert!(
        visual
            .debug_bounds("transcript-text-message-2")
            .unwrap()
            .size
            .height
            > wide_height,
        "offscreen row retained its pre-resize wrapping measurement"
    );
    jump_to(&child, 80, 13., cx);
    for width in [1000., 700.] {
        visual.simulate_resize(size(px(width), px(620.)));
        cx.run_until_parked();
        assert_eq!(cx.read(|cx| child.read(cx).buffer_margin()), buffer);
        assert_eq!(anchor(&child, cx), expected);
    }
    jump_to(&child, 2, 0., cx);
    current_row_bounds(&mut visual, &child, "message-2", cx);
    assert_eq!(
        visual
            .debug_bounds("transcript-text-message-2")
            .unwrap()
            .size
            .height,
        wide_height
    );
}

#[gpui::test]
fn cold_first_middle_last_rows_are_reachable_with_bounded_materialization(cx: &mut TestAppContext) {
    for count in [100, 1_000, 10_000] {
        let (_directory, window, root) = fixture_with_visible(cx, messages(count), 0, Some(count));
        let child = transcript(&root, cx);
        let mut visual = VisualTestContext::from_window(window.into(), cx);
        assert_eq!(scroll(&child, cx).item_count(), count);
        assert_eq!(row_ids(&child, cx).len(), count);
        assert_eq!(anchor(&child, cx), ("message-0".into(), px(0.)));
        assert!(!materialized(&child, cx).contains(&(count - 1)));
        for index in [0, count / 2, count - 1, 0] {
            jump_to(&child, index, 0., cx);
            let id = format!("message-{index}");
            current_row_bounds(&mut visual, &child, &id, cx);
            let built = materialized(&child, cx);
            assert!(
                built.contains(&index),
                "{count}-row list did not build {id}"
            );
            assert!(
                built.len() < 40,
                "{count}-row list built {} rows for one viewport",
                built.len()
            );
            let texts = cx.read(|cx| child.read(cx).materialized_texts());
            assert!(texts.iter().any(|(row, text)| *row == index
                && text == &format!("Transcript row {index}: 日本語 e\u{301}")));
        }
    }
}

#[gpui::test]
fn same_identity_edits_above_inside_and_below_viewport_remeasure_on_reach(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, messages(200), 0);
    reveal_all(&root, cx);
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    jump_to(&child, 80, 7., cx);
    let expected = anchor(&child, cx);
    for index in [2, 80, 150] {
        snapshot_change(&root, cx, |session| {
            session.messages[index].text =
                format!("Edited row {index}: 你好 👩🏽‍💻 e\u{301}\n").repeat(7);
            session.messages[index].reasoning = "Visible reasoning\nsecond reasoning line".into();
            session.messages[index].state = "interrupted".into();
        });
        assert_eq!(
            anchor(&child, cx),
            expected,
            "edit at {index} moved reading position"
        );
        assert!(materialized(&child, cx).len() < 40);
    }
    for index in [2, 80, 150] {
        jump_to(&child, index, 0., cx);
        let row = current_row_bounds(&mut visual, &child, &format!("message-{index}"), cx);
        assert!(
            row.size.height > px(200.),
            "edited offscreen height was stale: {row:?}"
        );
        let expected_text = cx.read(|cx| root.read(cx).session.messages[index].text.clone());
        let texts = cx.read(|cx| child.read(cx).materialized_texts());
        assert!(
            texts
                .iter()
                .any(|(row, text)| *row == index && text == &expected_text)
        );
    }
}

#[gpui::test]
fn reorder_and_anchor_deletion_use_stable_identity_then_surviving_neighbor(
    cx: &mut TestAppContext,
) {
    let (_directory, _window, root) = fixture(cx, messages(100), 0);
    reveal_all(&root, cx);
    let child = transcript(&root, cx);
    jump_to(&child, 40, 9., cx);
    let expected = anchor(&child, cx);
    snapshot_change(&root, cx, |session| session.messages.swap(40, 60));
    assert_eq!(anchor(&child, cx), expected);
    assert_eq!(scroll(&child, cx).logical_scroll_top().item_ix, 60);
    snapshot_change(&root, cx, |session| session.messages.swap(40, 60));
    assert_eq!(anchor(&child, cx), expected);
    snapshot_change(&root, cx, |session| {
        session.messages.remove(40);
    });
    assert_eq!(anchor(&child, cx), ("message-41".into(), px(0.)));
    snapshot_change(&root, cx, |session| {
        session
            .messages
            .retain(|message| !["message-41", "message-42"].contains(&message.id.as_str()));
    });
    assert_eq!(anchor(&child, cx), ("message-43".into(), px(0.)));
}

#[gpui::test]
fn deleting_last_anchor_falls_back_to_previous_surviving_row(cx: &mut TestAppContext) {
    let mut rows = messages(100);
    rows[98].text = "previous tall row\n".repeat(100);
    rows[99].text = "last tall row\n".repeat(100);
    let (_directory, _window, root) = fixture(cx, rows, 0);
    let child = transcript(&root, cx);
    jump_to(&child, 99, 9., cx);
    assert_eq!(anchor(&child, cx), ("message-99".into(), px(9.)));
    snapshot_change(&root, cx, |session| {
        session.messages.pop();
    });
    assert_eq!(anchor(&child, cx), ("message-98".into(), px(0.)));
}

#[gpui::test]
fn loading_retry_earlier_and_streaming_rows_have_distinct_logical_slots(cx: &mut TestAppContext) {
    let mut rows = messages(6);
    rows[5].text.clear();
    rows[5].state = "streaming".into();
    let (_directory, _window, root) = fixture(cx, rows, 0);
    let mut changed = input(&root, cx);
    changed.visible_messages = 2;
    changed.loading = true;
    changed.load_failed = true;
    let (mut visual, child) = host(&root, changed, cx);
    assert_eq!(
        row_ids(&child, cx),
        ["@loading", "@earlier", "message-4", "message-5"]
    );
    assert_eq!(scroll(&child, cx).item_count(), 4);
    current_row_bounds(&mut visual, &child, "message-5", cx);
    assert!(
        visual
            .debug_bounds("transcript-text-message-5")
            .unwrap()
            .size
            .height
            >= px(21.)
    );
    assert!(
        cx.read(|cx| child.read(cx).materialized_texts())
            .iter()
            .any(|(index, text)| *index == 3 && text.is_empty()),
        "placeholder must not change source text"
    );
    let mut changed = input(&root, cx);
    changed.visible_messages = 2;
    changed.load_failed = true;
    child.update(cx, |view, cx| view.update_inputs(changed, cx));
    cx.run_until_parked();
    assert_eq!(
        row_ids(&child, cx),
        ["@retry", "@earlier", "message-4", "message-5"]
    );
    assert_eq!(scroll(&child, cx).item_count(), 4);
}

#[gpui::test]
fn duplicate_legacy_ids_keep_separate_rows_and_exact_source(cx: &mut TestAppContext) {
    let rows = vec![
        message("duplicate", "user", "first duplicate"),
        message("unique", "assistant", "unique row"),
        message("duplicate", "assistant", "second duplicate 你好"),
    ];
    let (_directory, _window, root) = fixture(cx, rows, 0);
    let child = transcript(&root, cx);
    assert_eq!(
        row_ids(&child, cx),
        ["duplicate#0", "unique", "duplicate#1"]
    );
    assert_eq!(scroll(&child, cx).item_count(), 3);
    let texts = cx.read(|cx| child.read(cx).materialized_texts());
    assert!(
        texts
            .iter()
            .any(|(index, text)| *index == 0 && text == "first duplicate")
    );
    assert!(
        texts
            .iter()
            .any(|(index, text)| *index == 2 && text == "second duplicate 你好")
    );
    snapshot_change(&root, cx, |session| session.messages.reverse());
    jump_to(&child, 0, 0., cx);
    let texts = cx.read(|cx| child.read(cx).materialized_texts());
    assert!(
        texts
            .iter()
            .any(|(index, text)| *index == 0 && text == "second duplicate 你好")
    );
    assert!(
        texts
            .iter()
            .any(|(index, text)| *index == 2 && text == "first duplicate")
    );
}

#[gpui::test]
fn wheel_after_snapshot_and_resize_wins_over_restored_anchor(cx: &mut TestAppContext) {
    let (_directory, _window, root) = fixture(cx, messages(100), 0);
    let (mut visual, child) = host(&root, input(&root, cx), cx);
    jump_to(&child, 40, 9., cx);
    let mut changed = input(&root, cx);
    let mut session = (*changed.session).clone();
    session.messages[40].text.push_str("\nstreamed line");
    changed.session = Arc::new(session);
    child.update(cx, |view, cx| view.update_inputs(changed, cx));
    visual.simulate_resize(size(px(700.), px(480.)));
    let before = anchor(&child, cx);
    let target = scroll(&child, cx).viewport_bounds().center();
    visual.simulate_event(ScrollWheelEvent {
        position: target,
        delta: ScrollDelta::Pixels(point(px(0.), px(-100.))),
        ..Default::default()
    });
    cx.run_until_parked();
    let after = anchor(&child, cx);
    assert_ne!(after, before, "user wheel must take effect");
    child.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    assert_eq!(
        anchor(&child, cx),
        after,
        "a later frame must not restore the old anchor"
    );
}

#[gpui::test]
fn wheel_between_new_input_and_prepaint_uses_live_old_mapping_then_reconciles(
    cx: &mut TestAppContext,
) {
    // Cover both an insertion around a message anchor and removal of a
    // Show earlier header after the user has already wheeled into a message.
    for (count, visible, start_index, start_pixels, insert_prefix) in
        [(100, 100, 40, 9., true), (220, 200, 0, 0., false)]
    {
        let (_directory, _window, root) = fixture(cx, messages(count), 0);
        let pending = std::rc::Rc::new(std::cell::RefCell::new(None));
        let parent = root.downgrade();
        let mut initial = input(&root, cx);
        initial.visible_messages = visible;
        let window = cx.add_window(|_, cx| WheelInputHost {
            child: cx.new(|_| TranscriptView::new(parent, initial)),
            pending: pending.clone(),
        });
        let host = window.root(cx).unwrap();
        let child = cx.read(|cx| host.read(cx).child.clone());
        let mut visual = VisualTestContext::from_window(window.into(), cx);
        visual.simulate_resize(size(px(700.), px(620.)));
        cx.run_until_parked();
        jump_to(&child, start_index, start_pixels, cx);
        let old_list = scroll(&child, cx);
        let old_ids = row_ids(&child, cx);
        let old_count = old_ids.len();
        let old_offset = old_list.logical_scroll_top();
        let before_renders = renders(&child, cx);
        let target = old_list.viewport_bounds().center();
        let mut changed = input(&root, cx);
        changed.visible_messages = usize::MAX;
        let mut session = (*changed.session).clone();
        if insert_prefix {
            session.messages.splice(
                0..0,
                [
                    message("before-a", "user", "A"),
                    message("before-b", "assistant", "B"),
                ],
            );
        }
        let next_count = session.messages.len();
        changed.session = Arc::new(session);
        // Calculate the exact wheel result against the old frame's measurements.
        let mut expected_index = old_offset.item_ix;
        let mut expected_pixels = old_offset.offset_in_item + px(100.);
        loop {
            let height = old_list
                .bounds_for_item(expected_index)
                .unwrap()
                .size
                .height;
            if expected_pixels < height {
                break;
            }
            expected_pixels -= height;
            expected_index += 1;
        }
        let expected = (old_ids[expected_index].clone(), expected_pixels);
        if !insert_prefix {
            assert!(expected.0.starts_with("message-"));
            assert_ne!(expected.0, "message-0");
        }
        let old_frame_received_wheel = std::rc::Rc::new(std::cell::Cell::new(false));
        let witness = old_frame_received_wheel.clone();
        let observed_child = child.downgrade();
        old_list.set_scroll_handler(move |event, _, cx| {
            assert_eq!(
                event.count, old_count,
                "wheel reached reconciled rows instead of the old mapping"
            );
            assert_eq!(
                observed_child.upgrade().unwrap().read(cx).render_count(),
                before_renders,
                "a render occurred between the new input and the real wheel listener"
            );
            witness.set(true);
        });
        *pending.borrow_mut() = Some(changed);
        assert_eq!(renders(&child, cx), before_renders);
        assert_eq!(old_list.item_count(), old_count);
        // The capture hook installs input while this event is already being
        // dispatched. The List bubble witness proves the old frame handles it
        // before the pending presentation can be rendered and reconciled.
        visual.simulate_event(ScrollWheelEvent {
            position: target,
            delta: ScrollDelta::Pixels(point(px(0.), px(-100.))),
            ..Default::default()
        });
        assert!(
            pending.borrow().is_none(),
            "capture hook did not install pending input"
        );
        assert!(
            old_frame_received_wheel.get(),
            "old painted wheel listener did not receive the gesture"
        );
        cx.run_until_parked();
        assert_eq!(scroll(&child, cx).item_count(), next_count);
        assert_eq!(
            anchor(&child, cx),
            expected,
            "reconciliation restored an anchor captured before the user's gesture"
        );
        child.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
        assert_eq!(
            anchor(&child, cx),
            expected,
            "deferred restoration overwrote the user's gesture"
        );
    }
}

#[gpui::test]
fn huge_unicode_row_is_materialized_without_truncating_source(cx: &mut TestAppContext) {
    let source = "  **source** 你好 👩🏽‍💻 e\u{301}\r\n\t".repeat(4_096);
    let mut rows = messages(100);
    rows[50].text = source.clone();
    rows[50].role = "system".into();
    let (_directory, window, root) = fixture(cx, rows, 0);
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(!materialized(&child, cx).contains(&50));
    jump_to(&child, 50, 0., cx);
    let texts = cx.read(|cx| child.read(cx).materialized_texts());
    assert!(
        texts
            .iter()
            .any(|(index, text)| *index == 50 && text.as_bytes() == source.as_bytes())
    );
    // Source instrumentation alone cannot prove the display did not truncate.
    // Every original newline must also contribute its full 21px shaped line.
    current_row_bounds(&mut visual, &child, "message-50", cx);
    assert!(
        visual
            .debug_bounds("transcript-text-message-50")
            .unwrap()
            .size
            .height
            >= px(4_096. * 21.)
    );
    assert!(materialized(&child, cx).len() < 40);
    let id = cx.read(|cx| root.read(cx).record.id.clone());
    let controller = cx.read(|cx| Arc::downgrade(&root.read(cx).controller));
    root.update(cx, |view, cx| {
        view.copy_transcript_message(&MessageKey::new(id, "message-50".into()), &controller, cx)
    });
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text())
            .as_deref(),
        Some(source.as_str())
    );
}

#[gpui::test]
fn shrinking_huge_anchor_clamps_within_row_without_materializing_phantom_offset(
    cx: &mut TestAppContext,
) {
    let mut rows = messages(10_000);
    rows[5_000].text = "Huge anchor 日本語 👩🏽‍💻 e\u{301}\n".repeat(2_048);
    let (_directory, _window, root) = fixture_with_visible(cx, rows, 0, Some(10_000));
    let child = transcript(&root, cx);
    jump_to(&child, 5_000, 30_000., cx);
    assert_eq!(anchor(&child, cx), ("message-5000".into(), px(30_000.)));
    assert!(materialized(&child, cx).len() < 40);
    snapshot_change(&root, cx, |session| {
        session.messages[5_000].text = "short replacement".into()
    });
    assert_eq!(scroll(&child, cx).item_count(), 10_000);
    let (id, pixels) = anchor(&child, cx);
    assert_eq!(
        id, "message-5000",
        "same-ID replacement must retain the reading row"
    );
    let current = scroll(&child, cx).bounds_for_item(5_000).unwrap();
    assert!(
        pixels >= px(0.) && pixels < current.size.height,
        "within-row offset must be clamped when its old pixel no longer exists: {pixels:?}, height {:?}",
        current.size.height
    );
    assert!(
        materialized(&child, cx).len() < 40,
        "stale offset caused {} row trees to be built",
        materialized(&child, cx).len()
    );
    let settled = anchor(&child, cx);
    child.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    assert_eq!(anchor(&child, cx), settled);
    assert!(materialized(&child, cx).len() < 40);
}

#[gpui::test]
fn cached_hover_copy_resolves_current_controller_text_after_same_id_redraw(
    cx: &mut TestAppContext,
) {
    let source = "  **current source**\n你好 👩🏽‍💻 e\u{301}\r\n\t";
    let mut rows = messages(30);
    rows[0].text = source.into();
    let (_directory, window, root) = fixture(cx, rows, 0);
    let child = transcript(&root, cx);
    // Model a published controller snapshot arriving after the displayed input.
    // The click must look up the controller's current text, not close over this
    // deliberately stale presentation string.
    snapshot_change(&root, cx, |session| {
        session.messages[0].text = "stale presentation".into()
    });
    let before = renders(&child, cx);
    root.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    assert_eq!(renders(&child, cx), before);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    click_first_copy(&mut visual, &child, cx);
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text())
            .as_deref(),
        Some(source)
    );
}

#[gpui::test]
fn same_size_composer_and_root_notifications_reuse_populated_transcript(cx: &mut TestAppContext) {
    let source = "  **copy source**\n你好 👩🏽‍💻 e\u{301}\r\n\t";
    let mut rows = messages(30);
    rows[0].text = source.into();
    let (_directory, window, root) = fixture(cx, rows, 0);
    let child = transcript(&root, cx);
    let before = renders(&child, cx);
    assert!(before > 0);
    let viewport = scroll(&child, cx).viewport_bounds();
    for _ in 0..3 {
        root.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
        assert_eq!(renders(&child, cx), before, "root notify missed cache");
    }
    for text in ["other", "again", "日本語"] {
        root.update(cx, |view, cx| {
            view.composer
                .update(cx, |editor, cx| editor.set_text(text.into(), cx));
        });
        cx.run_until_parked();
        assert_eq!(scroll(&child, cx).viewport_bounds(), viewport);
        assert_eq!(
            renders(&child, cx),
            before,
            "same-height composer missed cache"
        );
        assert_eq!(transcript(&root, cx).entity_id(), child.entity_id());
    }
    assert!(
        window
            .update(cx, |view, window, cx| view
                .composer
                .read(cx)
                .focus_handle(cx)
                .is_focused(window))
            .unwrap()
    );
    // The reused cached paint must retain working hover and Copy listeners.
    cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_string("sentinel".into())));
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    click_first_copy(&mut visual, &child, cx);
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text())
            .as_deref(),
        Some(source)
    );
    let handle = scroll(&child, cx);
    let wheel_target = handle.viewport_bounds().center();
    assert!(handle.item_count() > 10);
    visual.simulate_mouse_move(wheel_target, None::<MouseButton>, Modifiers::none());
    let count = renders(&child, cx);
    root.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    assert_eq!(renders(&child, cx), count);
    let offset = anchor(&child, cx);
    visual.simulate_event(ScrollWheelEvent {
        position: wheel_target,
        delta: ScrollDelta::Pixels(point(px(0.), px(-100.))),
        ..Default::default()
    });
    let scrolled = anchor(&child, cx);
    assert_ne!(scrolled, offset, "cached wheel listener must scroll");
    let count = renders(&child, cx);
    root.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    assert_eq!(renders(&child, cx), count);
    assert_eq!(anchor(&child, cx), scrolled);
    // Explicit negative control: GPUI refresh deliberately bypasses its cache.
    // It must not be confused with a production parent-notification cache hit.
    visual.update(|window, _| window.refresh());
    cx.run_until_parked();
    assert!(renders(&child, cx) > count);
    assert_eq!(anchor(&child, cx), scrolled);
}

#[gpui::test]
fn fresh_session_arc_same_ids_reasoning_state_and_order_invalidate(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(
        cx,
        vec![
            message("first", "user", "First"),
            message("second", "assistant", "Second"),
        ],
        0,
    );
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let before = renders(&child, cx);
    snapshot_change(&root, cx, |_| {});
    assert!(
        renders(&child, cx) > before,
        "new Arc with equal values must invalidate"
    );
    let count = renders(&child, cx);
    root.update(cx, |view, cx| {
        let id = view.record.id.clone();
        view.receive_snapshot(
            &id,
            &Arc::downgrade(&view.controller),
            view.session.clone(),
            cx,
        );
    });
    cx.run_until_parked();
    assert_eq!(
        renders(&child, cx),
        count,
        "same session Arc must remain cached"
    );
    let short = visual
        .debug_bounds("transcript-text-second")
        .unwrap()
        .size
        .height;
    snapshot_change(&root, cx, |session| {
        session.messages[1].text = "Second\nnew line\nthird line".into()
    });
    assert!(renders(&child, cx) > count);
    assert!(
        visual
            .debug_bounds("transcript-text-second")
            .unwrap()
            .size
            .height
            > short
    );
    let count = renders(&child, cx);
    let plain = visual
        .debug_bounds("transcript-row-second")
        .unwrap()
        .size
        .height;
    snapshot_change(&root, cx, |session| {
        session.messages[1].reasoning = "Reasoning is also visible".into()
    });
    assert!(renders(&child, cx) > count);
    let reasoned = visual
        .debug_bounds("transcript-row-second")
        .unwrap()
        .size
        .height;
    assert!(reasoned > plain);
    let count = renders(&child, cx);
    snapshot_change(&root, cx, |session| {
        session.messages[1].state = "interrupted".into()
    });
    assert!(renders(&child, cx) > count);
    assert!(
        visual
            .debug_bounds("transcript-row-second")
            .unwrap()
            .size
            .height
            > reasoned
    );
    let count = renders(&child, cx);
    snapshot_change(&root, cx, |session| session.messages.swap(0, 1));
    assert!(renders(&child, cx) > count);
    jump_to(&child, 0, 0., cx);
    assert!(
        visual.debug_bounds("transcript-row-second").unwrap().top()
            < visual.debug_bounds("transcript-row-first").unwrap().top()
    );
    snapshot_change(&root, cx, |session| {
        session.messages.remove(1);
    });
    // Logical identity/count are authoritative: GPUI retains old debug selectors.
    assert_eq!(scroll(&child, cx).item_count(), 1);
    assert_eq!(row_ids(&child, cx), ["second"]);
    assert_eq!(transcript(&root, cx).entity_id(), child.entity_id());
}

#[gpui::test]
fn every_explicit_input_invalidates_but_equal_input_does_not(cx: &mut TestAppContext) {
    let (_directory, _window, root) = fixture(cx, messages(2), 0);
    let (_visual, child) = host(&root, input(&root, cx), cx);
    let before = renders(&child, cx);
    let equal = input(&root, cx);
    child.update(cx, |view, cx| view.update_inputs(equal, cx));
    cx.run_until_parked();
    assert_eq!(renders(&child, cx), before);
    for field in [
        "palette",
        "width",
        "visible",
        "loading",
        "failure",
        "chat",
        "controller",
    ] {
        let mut changed = input(&root, cx);
        let replacement = Controller::new(SessionStore::pending(), None).unwrap();
        match field {
            "palette" => {
                changed.palette = Palette::for_appearance(if changed.palette.dark {
                    WindowAppearance::Light
                } else {
                    WindowAppearance::Dark
                })
            }
            "width" => changed.pane_width += 40.,
            "visible" => changed.visible_messages = 1,
            "loading" => changed.loading = true,
            "failure" => changed.load_failed = true,
            "chat" => changed.chat_id.push_str("-different"),
            "controller" => changed.controller = Arc::downgrade(&replacement),
            _ => unreachable!(),
        }
        let before = renders(&child, cx);
        child.update(cx, |view, cx| view.update_inputs(changed, cx));
        cx.run_until_parked();
        assert!(renders(&child, cx) > before, "{field} did not invalidate");
        let original = input(&root, cx);
        child.update(cx, |view, cx| view.update_inputs(original, cx));
        cx.run_until_parked();
    }
}

#[gpui::test]
fn earlier_button_expands_current_prefix_and_retains_child(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, messages(5), 0);
    root.update(cx, |view, cx| {
        view.visible_messages = 2;
        cx.notify();
    });
    cx.run_until_parked();
    let child = transcript(&root, cx);
    let handle = scroll(&child, cx);
    assert_eq!(handle.item_count(), 3);
    assert_eq!(row_ids(&child, cx), ["@earlier", "message-3", "message-4"]);
    let before = renders(&child, cx);
    let target = first_child_target(&child, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_click(target, Modifiers::none());
    cx.run_until_parked();
    assert_eq!(cx.read(|cx| root.read(cx).visible_messages), 102);
    assert!(renders(&child, cx) > before);
    assert_eq!(transcript(&root, cx).entity_id(), child.entity_id());
    assert_eq!(scroll(&child, cx).item_count(), 5);
    assert_eq!(
        row_ids(&child, cx),
        (0..5)
            .map(|index| format!("message-{index}"))
            .collect::<Vec<_>>()
    );
    jump_to(&child, 0, 0., cx);
    current_row_bounds(&mut visual, &child, "message-0", cx);
    jump_to(&child, 4, 0., cx);
    current_row_bounds(&mut visual, &child, "message-4", cx);
}

#[gpui::test]
fn repeated_earlier_clicks_reveal_first_message_when_header_disappears(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, messages(220), 0);
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert_eq!(cx.read(|cx| root.read(cx).visible_messages), 100);
    assert_eq!(anchor(&child, cx), ("@earlier".into(), px(0.)));
    visual.simulate_click(first_child_target(&child, cx), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(cx.read(|cx| root.read(cx).visible_messages), 200);
    assert_eq!(anchor(&child, cx), ("@earlier".into(), px(0.)));
    assert_eq!(row_ids(&child, cx)[1], "message-20");
    current_row_bounds(&mut visual, &child, "message-20", cx);
    // The last reveal removes the header. The newly revealed first message
    // must be reachable from this click without an artificial test scroll.
    visual.simulate_click(first_child_target(&child, cx), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(cx.read(|cx| root.read(cx).visible_messages), 300);
    assert_eq!(scroll(&child, cx).item_count(), 220);
    assert_eq!(anchor(&child, cx), ("message-0".into(), px(0.)));
    assert_eq!(
        current_row_bounds(&mut visual, &child, "message-0", cx).top(),
        scroll(&child, cx).viewport_bounds().top()
    );
    assert_eq!(transcript(&root, cx).entity_id(), child.entity_id());
    assert!(materialized(&child, cx).len() < 40);
}

#[gpui::test]
fn queue_composer_and_window_geometry_relayout_cached_viewport(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, messages(12), 6);
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let queued = scroll(&child, cx).viewport_bounds();
    let before = renders(&child, cx);
    root.update(cx, |view, cx| {
        view.queue_open = false;
        cx.notify();
    });
    cx.run_until_parked();
    let collapsed = scroll(&child, cx).viewport_bounds();
    assert!(collapsed.size.height > queued.size.height);
    assert!(
        renders(&child, cx) > before,
        "viewport-height change must miss cache"
    );
    let before = renders(&child, cx);
    root.update(cx, |view, cx| {
        view.composer.update(cx, |editor, cx| {
            editor.set_text("long composer line\n".repeat(20), cx)
        });
    });
    cx.run_until_parked();
    let tall = scroll(&child, cx).viewport_bounds();
    assert!(tall.size.height < collapsed.size.height);
    assert!(renders(&child, cx) > before);
    for (width, height, split) in [(920., 600., false), (1180., 812., true), (920., 600., true)] {
        root.update(cx, |view, cx| {
            view.show_files = split;
            view.layout.fraction = 0.5;
            cx.notify();
        });
        visual.simulate_resize(size(px(width), px(height)));
        cx.run_until_parked();
        let viewport = scroll(&child, cx).viewport_bounds();
        let composer = visual.debug_bounds("queue-measured-composer").unwrap();
        let footer = visual.debug_bounds("queue-measured-footer").unwrap();
        assert!(viewport.size.height >= px(0.));
        assert!(viewport.bottom() <= composer.top() + px(1.));
        assert!(composer.bottom() <= footer.top() + px(1.));
        assert_eq!(
            viewport,
            visual.debug_bounds("queue-measured-transcript").unwrap()
        );
        assert_eq!(transcript(&root, cx).entity_id(), child.entity_id());
        let count = renders(&child, cx);
        root.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
        assert_eq!(
            renders(&child, cx),
            count,
            "settled geometry must cache again"
        );
    }
}

#[gpui::test]
fn navigation_preserves_chat_child_identity_and_scroll_offset(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, messages(30), 0);
    let child = transcript(&root, cx);
    let first_id = cx.read(|cx| root.read(cx).record.id.clone());
    let composer = cx.read(|cx| root.read(cx).composer.clone());
    jump_to(&child, 3, 7., cx);
    let offset = anchor(&child, cx);
    assert_eq!(offset, ("message-3".into(), px(7.)));
    window
        .update(cx, |view, window, cx| view.new_chat(window, cx))
        .unwrap();
    cx.run_until_parked();
    assert_ne!(cx.read(|cx| root.read(cx).record.id.clone()), first_id);
    assert!(cx.read(|cx| root.read(cx).transcript.is_none()));
    assert_eq!(
        cx.read(|cx| root.read(cx).inactive[&first_id]
            .transcript
            .as_ref()
            .unwrap()
            .entity_id()),
        child.entity_id()
    );
    window
        .update(cx, |view, window, cx| {
            view.select_chat(&first_id, window, cx)
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(transcript(&root, cx).entity_id(), child.entity_id());
    assert_eq!(
        cx.read(|cx| root.read(cx).composer.entity_id()),
        composer.entity_id()
    );
    assert_eq!(anchor(&child, cx), offset);
    assert_eq!(cx.read(|cx| composer.read(cx).text().to_owned()), "draft");
}

#[gpui::test]
fn controller_replacement_discards_child_and_rejects_old_copy_identity(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, messages(2), 0);
    let old_child = transcript(&root, cx);
    let old_controller = cx.read(|cx| root.read(cx).controller.clone());
    let id = cx.read(|cx| root.read(cx).record.id.clone());
    let key = MessageKey::new(id.clone(), "message-0".into());
    let path = cx.read(|cx| root.read(cx).record.snapshot.clone());
    // Retain the old controller to exercise the stale identity guard without
    // attempting to acquire its still-owned session-file lock a second time.
    let mut replacement_store = SessionStore::pending_with_id(&id).unwrap();
    replacement_store
        .persist_to(path.with_file_name("replacement.json"))
        .unwrap();
    replacement_store
        .transact(|session| {
            *session = old_controller.snapshot();
            session.messages[0].text =
                "  **replacement controller**\n你好 👩🏽‍💻 e\u{301}\r\n\t".into();
            Ok(())
        })
        .unwrap();
    let replacement = Controller::new(replacement_store, None).unwrap();
    root.update(cx, |view, cx| {
        view.chat.replace_controller(replacement, cx);
        cx.notify();
    });
    cx.run_until_parked();
    assert_ne!(transcript(&root, cx).entity_id(), old_child.entity_id());
    cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_string("sentinel".into())));
    root.update(cx, |view, cx| {
        assert!(!view.active_transcript_matches(&id, &Arc::downgrade(&old_controller)));
        view.copy_transcript_message(&key, &Arc::downgrade(&old_controller), cx);
    });
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text()),
        Some("sentinel".into())
    );
    let child = transcript(&root, cx);
    let count = renders(&child, cx);
    for _ in 0..3 {
        root.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
        assert_eq!(renders(&child, cx), count);
    }
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    click_first_copy(&mut visual, &child, cx);
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text()),
        Some("  **replacement controller**\n你好 👩🏽‍💻 e\u{301}\r\n\t".into())
    );
}

#[gpui::test]
fn empty_populated_loading_and_failure_prefixes_preserve_rows(cx: &mut TestAppContext) {
    let (_directory, _window, root) = fixture(cx, Vec::new(), 0);
    assert!(cx.read(|cx| root.read(cx).transcript.is_none()));
    for (loading, failed) in [(true, false), (false, true), (false, false)] {
        root.update(cx, |view, cx| {
            view.loading = loading;
            view.load_failed = failed;
            cx.notify();
        });
        cx.run_until_parked();
        assert!(cx.read(|cx| root.read(cx).transcript.is_none()));
    }
    snapshot_change(&root, cx, |session| session.messages = messages(2));
    let child = transcript(&root, cx);
    assert_eq!(scroll(&child, cx).item_count(), 2);
    assert_eq!(row_ids(&child, cx), ["message-0", "message-1"]);
    for (loading, failed) in [(true, false), (false, true), (true, true)] {
        let count = renders(&child, cx);
        root.update(cx, |view, cx| {
            view.loading = loading;
            view.load_failed = failed;
            cx.notify();
        });
        cx.run_until_parked();
        assert!(renders(&child, cx) > count);
        let handle = scroll(&child, cx);
        assert_eq!(
            handle.item_count(),
            3,
            "only one status prefix plus both rows"
        );
        assert_eq!(
            row_ids(&child, cx),
            [
                if loading { "@loading" } else { "@retry" },
                "message-0",
                "message-1"
            ]
        );
        assert_eq!(transcript(&root, cx).entity_id(), child.entity_id());
    }
    let weak = child.downgrade();
    drop(child);
    snapshot_change(&root, cx, |session| session.messages.clear());
    assert!(cx.read(|cx| root.read(cx).transcript.is_none()));
    assert!(
        weak.upgrade().is_none(),
        "cleared history must release its child"
    );
    snapshot_change(&root, cx, |session| session.messages = messages(1));
    assert!(renders(&transcript(&root, cx), cx) > 0);
}

#[gpui::test]
fn stale_and_dropped_parent_callbacks_do_not_expand_other_chat(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, messages(4), 0);
    let mut old_input = input(&root, cx);
    let controller = old_input.controller.clone();
    let owners = controller.strong_count();
    let path = cx.read(|cx| root.read(cx).record.snapshot.clone());
    old_input.visible_messages = 1;
    let (mut visual, child) = host(&root, old_input, cx);
    assert_eq!(controller.strong_count(), owners);
    let target = first_child_target(&child, cx);
    window
        .update(cx, |view, window, cx| view.new_chat(window, cx))
        .unwrap();
    cx.run_until_parked();
    let active = cx.read(|cx| {
        (
            root.read(cx).record.id.clone(),
            root.read(cx).visible_messages,
        )
    });
    visual.simulate_click(target, Modifiers::none());
    assert_eq!(
        cx.read(|cx| (
            root.read(cx).record.id.clone(),
            root.read(cx).visible_messages
        )),
        active
    );
    let weak = root.downgrade();
    window
        .update(cx, |_, window, _| window.remove_window())
        .unwrap();
    drop(root);
    // Dropping the last Entity handle invalidates WeakEntity immediately, but
    // GPUI drops its stored value during the next App::flush_effects cycle.
    cx.update(|_| {});
    cx.run_until_parked();
    assert!(
        weak.upgrade().is_none(),
        "retained transcript callback must not retain parent"
    );
    assert!(
        controller.upgrade().is_none(),
        "retained transcript must not retain controller"
    );
    let reopened = SessionStore::open(&path).expect("retained child must not retain the file lock");
    assert_eq!(reopened.snapshot().messages.len(), 4);
    visual.simulate_click(first_child_target(&child, cx), Modifiers::none());
    assert!(weak.upgrade().is_none());
}

#[gpui::test]
fn cached_redraw_and_stream_update_preserve_synthetic_ime_and_selection(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, messages(2), 0);
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.focus(window);
                editor.replace_and_mark_text_in_range(None, "未確定", Some(1..2), window, cx);
            });
        })
        .unwrap();
    cx.run_until_parked();
    let child = transcript(&root, cx);
    let composer = cx.read(|cx| root.read(cx).composer.clone());
    let draft = cx.read(|cx| composer.read(cx).text().to_owned());
    let revision = cx.read(|cx| root.read(cx).draft_revision);
    let before = window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                (
                    editor.selected_text_range(false, window, cx).unwrap().range,
                    editor.marked_text_range(window, cx).unwrap(),
                )
            })
        })
        .unwrap();
    let count = renders(&child, cx);
    root.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    assert_eq!(renders(&child, cx), count);
    snapshot_change(&root, cx, |session| {
        session.messages[1].text = "Streaming update 你好".into();
        session.messages[1].state = "streaming".into();
    });
    assert!(renders(&child, cx) > count);
    window
        .update(cx, |view, window, cx| {
            assert_eq!(view.composer.entity_id(), composer.entity_id());
            assert!(view.composer.read(cx).focus_handle(cx).is_focused(window));
            view.composer.update(cx, |editor, cx| {
                assert_eq!(editor.text(), draft);
                assert!(editor.has_marked_text());
                assert_eq!(
                    editor.selected_text_range(false, window, cx).unwrap().range,
                    before.0
                );
                assert_eq!(editor.marked_text_range(window, cx).unwrap(), before.1);
            });
            assert_eq!(view.draft_revision, revision);
        })
        .unwrap();
}

// A native delta must travel beyond the initially measured viewport/buffer.
// Equal one-line assistant rows make the expected pixel distance exact.
#[gpui::test]
fn single_large_native_wheel_preserves_requested_distance(cx: &mut TestAppContext) {
    let rows = (0..220)
        .map(|index| message(&format!("wheel-{index}"), "assistant", "one line"))
        .collect();
    let (_directory, _window, root) = fixture_with_visible(cx, rows, 0, Some(usize::MAX));
    let (mut visual, child) = host(&root, input(&root, cx), cx);
    let handle = scroll(&child, cx);
    let row_height = handle.bounds_for_item(0).unwrap().size.height;
    let target = handle.viewport_bounds().center();
    visual.simulate_mouse_move(target, None::<MouseButton>, Modifiers::none());
    visual.simulate_event(ScrollWheelEvent {
        position: target,
        delta: ScrollDelta::Pixels(point(px(0.), px(-5000.))),
        ..Default::default()
    });
    cx.run_until_parked();
    let offset = scroll(&child, cx).logical_scroll_top();
    let travelled = row_height * offset.item_ix as f32 + offset.offset_in_item;
    assert_eq!(
        travelled,
        px(5000.),
        "native delta was clamped to the measured-only extent: {offset:?}, row height {row_height:?}"
    );
    assert!(
        materialized(&child, cx).len() < 40,
        "large wheel must not build crossed row trees"
    );
}

#[gpui::test]
fn large_native_wheels_reverse_and_clamp_at_real_document_edges(cx: &mut TestAppContext) {
    let rows = (0..220)
        .map(|index| message(&format!("wheel-{index}"), "assistant", "one line"))
        .collect();
    let (_directory, _window, root) = fixture_with_visible(cx, rows, 0, Some(usize::MAX));
    let (mut visual, child) = host(&root, input(&root, cx), cx);
    let handle = scroll(&child, cx);
    let row_height = handle.bounds_for_item(0).unwrap().size.height;
    let target = handle.viewport_bounds().center();
    visual.simulate_mouse_move(target, None::<MouseButton>, Modifiers::none());
    for (delta, expected) in [
        (-5000., 5000.),
        (3500., 1500.),
        (
            -100_000.,
            220. * f32::from(row_height) - 16. + 13.
                - f32::from(handle.viewport_bounds().size.height),
        ),
        (100_000., 0.),
    ] {
        visual.simulate_event(ScrollWheelEvent {
            position: target,
            delta: ScrollDelta::Pixels(point(px(0.), px(delta))),
            ..Default::default()
        });
        cx.run_until_parked();
        let offset = scroll(&child, cx).logical_scroll_top();
        assert_eq!(
            row_height * offset.item_ix as f32 + offset.offset_in_item,
            px(expected)
        );
        assert!(materialized(&child, cx).len() < 40);
    }
}

#[gpui::test]
fn native_line_pixel_and_outside_wheels_keep_delta_and_hitbox_semantics(cx: &mut TestAppContext) {
    let rows = (0..220)
        .map(|index| message(&format!("wheel-{index}"), "assistant", "one line"))
        .collect();
    let (_directory, _window, root) = fixture_with_visible(cx, rows, 0, Some(usize::MAX));
    let (mut visual, child) = host(&root, input(&root, cx), cx);
    let handle = scroll(&child, cx);
    let row_height = handle.bounds_for_item(0).unwrap().size.height;
    let target = handle.viewport_bounds().center();
    visual.simulate_mouse_move(target, None::<MouseButton>, Modifiers::none());
    let line_distance = f32::from(visual.update(|window, _| window.line_height())) * 150.;
    for (delta, expected) in [
        (ScrollDelta::Lines(point(0., -150.)), line_distance),
        (
            ScrollDelta::Pixels(point(px(0.), px(-2000.))),
            line_distance + 2000.,
        ),
        (
            ScrollDelta::Pixels(point(px(0.), px(300.))),
            line_distance + 1700.,
        ),
        (
            ScrollDelta::Pixels(point(px(100.), px(0.))),
            line_distance + 1600.,
        ),
    ] {
        visual.simulate_event(ScrollWheelEvent {
            position: target,
            delta,
            ..Default::default()
        });
        cx.run_until_parked();
        let offset = scroll(&child, cx).logical_scroll_top();
        assert_eq!(
            row_height * offset.item_ix as f32 + offset.offset_in_item,
            px(expected)
        );
    }
    let before = anchor(&child, cx);
    let outside = point(px(900.), px(900.));
    visual.simulate_mouse_move(outside, None::<MouseButton>, Modifiers::none());
    visual.simulate_event(ScrollWheelEvent {
        position: outside,
        delta: ScrollDelta::Pixels(point(px(0.), px(-5000.))),
        ..Default::default()
    });
    cx.run_until_parked();
    assert_eq!(anchor(&child, cx), before);
}

#[gpui::test]
fn estimated_target_normalizes_real_height_without_losing_residual(cx: &mut TestAppContext) {
    let mut rows: Vec<_> = (0..220)
        .map(|index| message(&format!("mixed-{index}"), "assistant", "one line"))
        .collect();
    rows[20].text = "short\nrow".into();
    let (_directory, _window, root) = fixture_with_visible(cx, rows, 0, Some(usize::MAX));
    let (_visual, child) = host(&root, input(&root, cx), cx);
    let height = scroll(&child, cx).bounds_for_item(0).unwrap().size.height;
    // NoopTextSystem gives every glyph equal advance. Inject the logical target
    // produced by a real-font overestimate, so this regression tests residual
    // normalization independently of platform font metrics.
    child.update(cx, |view, _| view.override_navigation_estimate(px(5000.)));
    scroll(&child, cx).scroll_to(ListOffset {
        item_ix: 20,
        offset_in_item: px(150.),
    });
    child.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    let handle = scroll(&child, cx);
    let offset = handle.logical_scroll_top();
    assert!(offset.item_ix > 20);
    let actual = height + px(21.);
    let travelled = height * (offset.item_ix - 1) as f32 + actual + offset.offset_in_item;
    assert_eq!(travelled, height * 20. + px(150.));
    assert!(offset.offset_in_item < handle.bounds_for_item(offset.item_ix).unwrap().size.height);
    assert!(materialized(&child, cx).len() < 40);
}

#[gpui::test]
fn native_large_wheel_preserves_mixed_height_distance(cx: &mut TestAppContext) {
    let rows = (0..220)
        .map(|index| {
            message(
                &format!("mixed-{index}"),
                if index % 2 == 0 { "user" } else { "assistant" },
                if index % 3 == 0 {
                    "one\ntwo\nthree"
                } else {
                    "one"
                },
            )
        })
        .collect();
    let (_directory, _window, root) = fixture_with_visible(cx, rows, 0, Some(usize::MAX));
    let (mut visual, child) = host(&root, input(&root, cx), cx);
    let target = scroll(&child, cx).viewport_bounds().center();
    visual.simulate_mouse_move(target, None::<MouseButton>, Modifiers::none());
    for (delta, expected) in [(-5000., 5000.), (3500., 1500.)] {
        visual.simulate_event(ScrollWheelEvent {
            position: target,
            delta: ScrollDelta::Pixels(point(px(0.), px(delta))),
            ..Default::default()
        });
        cx.run_until_parked();
        let offset = scroll(&child, cx).logical_scroll_top();
        let prefix: f32 = (0..offset.item_ix)
            .map(|index| {
                77. + if index % 2 == 0 { 18. } else { 0. } + if index % 3 == 0 { 42. } else { 0. }
            })
            .sum();
        assert_eq!(px(prefix) + offset.offset_in_item, px(expected));
        assert!(materialized(&child, cx).len() < 40);
    }
}

#[gpui::test]
fn reverse_wheel_uses_exact_leading_overdraw_height(cx: &mut TestAppContext) {
    let mut rows: Vec<_> = (0..100)
        .map(|index| message(&format!("leading-{index}"), "assistant", "one line"))
        .collect();
    rows[29].text = "i".repeat(5000);
    let (_directory, _window, root) = fixture_with_visible(cx, rows, 0, Some(usize::MAX));
    let (mut visual, child) = host(&root, input(&root, cx), cx);
    jump_to(&child, 30, 0., cx);
    assert!(
        materialized(&child, cx).contains(&29),
        "leading buffer must measure row29"
    );
    let target = scroll(&child, cx).viewport_bounds().center();
    visual.simulate_mouse_move(target, None::<MouseButton>, Modifiers::none());
    visual.simulate_event(ScrollWheelEvent {
        position: target,
        delta: ScrollDelta::Pixels(point(px(0.), px(100.))),
        ..Default::default()
    });
    cx.run_until_parked();
    let handle = scroll(&child, cx);
    let offset = handle.logical_scroll_top();
    assert_eq!(offset.item_ix, 29);
    let actual = handle.bounds_for_item(29).unwrap().size.height;
    assert_eq!(offset.offset_in_item, actual - px(100.));
}

#[gpui::test]
fn pathological_estimates_normalize_with_bounded_per_frame_work(cx: &mut TestAppContext) {
    let rows = (0..220)
        .map(|index| message(&format!("bounded-{index}"), "assistant", "one line"))
        .collect();
    let (_directory, _window, root) = fixture_with_visible(cx, rows, 0, Some(usize::MAX));
    let (_visual, child) = host(&root, input(&root, cx), cx);
    let height = scroll(&child, cx).bounds_for_item(0).unwrap().size.height;
    // A test-only estimate override models arbitrarily poor real-font estimates
    // without pretending NoopTextSystem shapes zero-width Unicode correctly.
    child.update(cx, |view, _| view.override_navigation_estimate(px(5000.)));
    scroll(&child, cx).scroll_to(ListOffset {
        item_ix: 20,
        offset_in_item: px(2500.),
    });
    child.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    // TestPlatform intentionally does not deliver animation-frame callbacks.
    // Drive those frames explicitly, while checking the production pending state.
    let mut frames = 0;
    while cx.read(|cx| child.read(cx).has_pending_navigation()) {
        frames += 1;
        assert!(
            frames < 220,
            "each normalization frame must make forward progress"
        );
        child.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
        assert!(materialized(&child, cx).len() < 40);
    }
    let offset = scroll(&child, cx).logical_scroll_top();
    assert_eq!(
        height * offset.item_ix as f32 + offset.offset_in_item,
        height * 20. + px(2500.)
    );
    let counts = cx.read(|cx| child.read(cx).target_preflight_counts());
    assert!(
        counts.iter().filter(|&&count| count > 0).count() > 2,
        "fixture must require deferred normalization: {counts:?}"
    );
    assert!(
        counts.iter().all(|&count| count <= 2),
        "unbounded target work: {counts:?}"
    );
    assert!(materialized(&child, cx).len() < 40);
}

#[gpui::test]
fn newer_wheel_and_resize_supersede_deferred_navigation(cx: &mut TestAppContext) {
    let rows = (0..220)
        .map(|index| message(&format!("pending-{index}"), "assistant", "one line"))
        .collect();
    let (_directory, _window, root) = fixture_with_visible(cx, rows, 0, Some(usize::MAX));
    let (mut visual, child) = host(&root, input(&root, cx), cx);
    child.update(cx, |view, _| view.override_navigation_estimate(px(5000.)));
    for resize in [false, true] {
        scroll(&child, cx).scroll_to(ListOffset {
            item_ix: 100,
            offset_in_item: px(2500.),
        });
        child.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
        assert!(cx.read(|cx| child.read(cx).has_pending_navigation()));
        if resize {
            visual.simulate_resize(size(px(600.), px(500.)));
        } else {
            let target = scroll(&child, cx).viewport_bounds().center();
            visual.simulate_mouse_move(target, None::<MouseButton>, Modifiers::none());
            visual.simulate_event(ScrollWheelEvent {
                position: target,
                delta: ScrollDelta::Pixels(point(px(0.), px(-20.))),
                ..Default::default()
            });
        }
        cx.run_until_parked();
        assert!(!cx.read(|cx| child.read(cx).has_pending_navigation()));
        let after = anchor(&child, cx);
        child.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
        assert_eq!(
            anchor(&child, cx),
            after,
            "old animation callback must not restore stale navigation"
        );
    }
}

#[test]
fn mixed_native_wheel_units_and_reversals_match_original_div_semantics() {
    let mut distance = px(0.);
    for (delta, expected) in [
        (ScrollDelta::Lines(point(0., -3.)), 78.),
        (ScrollDelta::Pixels(point(px(0.), px(-22.))), 100.),
        (ScrollDelta::Lines(point(0., 1.)), 74.),
        (ScrollDelta::Pixels(point(px(-10.), px(0.))), 84.),
        (ScrollDelta::Pixels(point(px(100.), px(-16.))), 100.),
    ] {
        distance += crate::transcript_view::vertical_wheel_distance(delta, px(26.));
        assert_eq!(distance, px(expected));
    }
}

#[gpui::test]
fn controller_snapshot_generation_rejects_late_selected_and_inactive_publications(
    cx: &mut TestAppContext,
) {
    let (directory, window, root) = fixture(cx, messages(2), 1);
    let old = cx.read(|cx| root.read(cx).controller.clone());
    let id = cx.read(|cx| root.read(cx).record.id.clone());
    let mut store = SessionStore::pending_with_id(&id).unwrap();
    store
        .persist_to(directory.path().join("replacement.json"))
        .unwrap();
    store
        .transact(|session| {
            *session = old.snapshot();
            session.messages[1].text = "replacement publication".into();
            Ok(())
        })
        .unwrap();
    let replacement = Controller::new(store, None).unwrap();
    let source = Arc::downgrade(&old);
    let mut stale = old.snapshot();
    stale.title = "late old title must never reach catalog".into();
    stale.error = Some("late old error".into());
    stale.state = RunState::Running;
    stale.pending.clear();
    stale.edit = None;
    let stale = Arc::new(stale);
    let token = uuid::Uuid::new_v4();
    window
        .update(cx, |view, window, cx| {
            view.chat.replace_controller(replacement.clone(), cx);
            view.queue_operation = Some(token);
            view.error = Some("current owned error".into());
            view.editing = Some("current deferred edit".into());
            view.edit_recovery.blocked = true;
            view.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "漢字", Some(2..2), window, cx);
            });
            let before = view.session.clone();
            let text = view.composer.read(cx).text().to_owned();
            let title = view.record.title.clone();
            let revision = view.last_revision;
            view.receive_snapshot(&id, &source, stale.clone(), cx);
            view.finish_snapshot_title(
                &id,
                &source,
                crate::chat_organization::CatalogOutcome {
                    result: Err(bello_agent_core::Error::Invalid(
                        "late title failure".into(),
                    )),
                    uncertain: false,
                },
                cx,
            );
            assert!(Arc::ptr_eq(&before, &view.session));
            assert_eq!(view.record.title, title);
            assert_eq!(view.last_revision, revision);
            assert_eq!(view.error.as_deref(), Some("current owned error"));
            assert_eq!(view.queue_operation, Some(token));
            assert_eq!(view.editing.as_deref(), Some("current deferred edit"));
            assert!(view.edit_recovery.blocked);
            assert!(!view.edit_recovery.has_live_check());
            assert!(view.composer.read(cx).has_marked_text());
            assert_eq!(view.composer.read(cx).text(), text);
            view.new_chat(window, cx);
            assert_ne!(view.record.id, id);
            let selected = view.session.clone();
            view.receive_snapshot(&id, &source, stale.clone(), cx);
            let chat = &view.inactive[&id];
            assert!(Arc::ptr_eq(&before, &chat.session));
            assert_eq!(chat.queue_operation, Some(token));
            assert!(chat.composer.read(cx).has_marked_text());
            assert!(Arc::ptr_eq(&selected, &view.session));
            // The replacement's publications still reach the captured background
            // chat, without changing selection or losing the deferred IME token.
            let mut fresh = replacement.snapshot();
            fresh.messages[1].text = "fresh current-controller update".into();
            view.receive_snapshot(&id, &Arc::downgrade(&replacement), Arc::new(fresh), cx);
            assert_eq!(
                view.inactive[&id].session.messages[1].text,
                "fresh current-controller update"
            );
            assert_eq!(view.inactive[&id].queue_operation, Some(token));
            assert!(Arc::ptr_eq(&selected, &view.session));
            view.finish_snapshot_title(
                &id,
                &Arc::downgrade(&replacement),
                crate::chat_organization::CatalogOutcome {
                    result: Err(bello_agent_core::Error::Invalid(
                        "current title failure".into(),
                    )),
                    uncertain: false,
                },
                cx,
            );
            assert!(
                view.inactive[&id]
                    .error
                    .as_deref()
                    .unwrap()
                    .contains("current title failure")
            );
            assert!(view.error.is_none());
        })
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, _| {
        assert_ne!(
            view.records
                .iter()
                .find(|record| record.id == id)
                .unwrap()
                .title,
            stale.title
        );
        assert_eq!(view.inactive[&id].queue_operation, Some(token));
        let catalog = view.workspace.lock().unwrap().snapshot();
        assert_ne!(
            catalog
                .chats
                .iter()
                .find(|record| record.id == id)
                .unwrap()
                .title,
            stale.title
        );
    });
}

fn retained_tool_rows(count: usize, output: &str) -> Vec<Message> {
    use bello_agent_core::{
        provider::ToolCall,
        tool_history::{
            AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
        },
    };
    (0..count)
        .flat_map(|i| {
            let mut assistant = message(&format!("tool-assistant-{i}"), "assistant", "");
            assistant.state = "completed".into();
            assistant.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
                tool_batch_timing: None,
                completion: Completion::Complete,
                calls: vec![ToolCall {
                    id: "reused".into(),
                    name: "ls".into(),
                    arguments: serde_json::json!({"path":"."}),
                }],
                binding: ReplayBinding {
                    profile_id: "fixture".into(),
                    api: "openai-responses".into(),
                    provider: "litellm".into(),
                    model: "fixture".into(),
                    endpoint_sha256: "0".repeat(64),
                },
                provider_items: vec![],
            }));
            let mut result = message(&format!("tool-result-{i}"), "toolResult", output);
            result.tool_record = Some(ToolRecord::Result(ResultRecord {
                duration_us: None,
                assistant_id: assistant.id.clone(),
                call_id: "reused".into(),
                is_error: false,
                outcome: ToolOutcome::Completed,
                content: None,
            }));
            [assistant, result]
        })
        .collect()
}

#[gpui::test]
fn retained_tool_cards_pair_and_cap_selectable_sections_without_eager_editors(
    cx: &mut TestAppContext,
) {
    let (_directory, _window, root) = fixture(cx, messages(1), 0);
    let mut changed = input(&root, cx);
    let mut session = (*changed.session).clone();
    session.messages = retained_tool_rows(180, &"retained output line\n".repeat(1000));
    session.messages[0].text = "Assistant prose survives".into();
    session.messages[0].reasoning = "Assistant reasoning survives".into();
    changed.session = Arc::new(session);
    changed.visible_messages = usize::MAX;
    let (mut visual, child) = host(&root, changed.clone(), cx);
    assert_eq!(row_ids(&child, cx).len(), 181);
    assert_eq!(row_ids(&child, cx)[0], "tool-assistant-0");
    assert!(
        visual
            .debug_bounds("transcript-text-tool-assistant-0")
            .is_some()
    );
    let selectors = cx.read(|cx| child.read(cx).tool_card_selectors());
    assert_ne!(
        selectors[0], selectors[1],
        "reused call IDs must retain distinct owners"
    );
    let output_bounds = visual
        .debug_bounds(Box::leak(format!("{}-OUT", selectors[0]).into_boxed_str()))
        .unwrap();
    assert!(output_bounds.size.height <= px(150.));
    assert!(
        cx.read(|cx| child.read(cx).retained_tool_editor_count()) < 20,
        "offscreen rows must not allocate editors"
    );
    let initial = cx.read(|cx| child.read(cx).tool_section_editors());
    assert!(initial.iter().all(|(_, editor)| {
        cx.read(|cx| editor.read(cx).engine.read_only && editor.read(cx).text().len() <= 8192)
    }));
    let initial_ids: Vec<_> = initial
        .iter()
        .map(|(_, editor)| editor.entity_id())
        .collect();
    visual.simulate_click(output_bounds.center(), Modifiers::none());
    visual.simulate_keystrokes("cmd-a cmd-c");
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text())
            .as_deref(),
        Some(&changed.session.messages[1].text[..8192])
    );
    cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_string("sentinel".into())));
    child.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    let repeated = cx.read(|cx| child.read(cx).tool_section_editors());
    visual.simulate_keystrokes("cmd-c");
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text())
            .as_deref(),
        Some(&changed.session.messages[1].text[..8192]),
        "selection must survive an unchanged transcript frame"
    );
    assert!(
        initial_ids
            .iter()
            .all(|id| repeated.iter().any(|(_, editor)| &editor.entity_id() == id)),
        "unchanged rows retain section selection/scroll entities"
    );
    let before = anchor(&child, cx);
    visual.simulate_event(ScrollWheelEvent {
        position: output_bounds.center(),
        delta: ScrollDelta::Pixels(point(px(0.), px(-60.))),
        ..Default::default()
    });
    cx.run_until_parked();
    assert_eq!(
        anchor(&child, cx),
        before,
        "a section wheel must not move the outer transcript"
    );
    for index in (20..180).step_by(20) {
        jump_to(&child, index, 0., cx);
    }
    assert!(cx.read(|cx| child.read(cx).retained_tool_editor_count()) <= 64);
    assert!(
        changed.session.messages[1].text.len() > 8192,
        "retained bytes must remain intact"
    );
}

#[gpui::test]
fn retained_tool_record_edits_and_disclosure_remeasure_without_losing_anchor(
    cx: &mut TestAppContext,
) {
    use bello_agent_core::tool_history::{ToolOutcome, ToolRecord};
    let (_directory, _window, root) = fixture(cx, messages(1), 0);
    let mut changed = input(&root, cx);
    let mut session = (*changed.session).clone();
    session.messages = retained_tool_rows(30, "one line");
    changed.session = Arc::new(session);
    changed.visible_messages = usize::MAX;
    let (mut visual, child) = host(&root, changed.clone(), cx);
    jump_to(&child, 10, 8., cx);
    let before = anchor(&child, cx);
    let selectors = cx.read(|cx| child.read(cx).tool_card_selectors());
    let selector: &'static str = Box::leak(selectors[10].clone().into_boxed_str());
    let short = visual.debug_bounds(selector).unwrap().size.height;
    let invalidations = cx.read(|cx| child.read(cx).tool_height_invalidation_count());
    let mut session = (*changed.session).clone();
    if let Some(ToolRecord::Assistant(record)) = &mut session.messages[20].tool_record {
        record.calls[0].arguments = serde_json::json!({"path":".","many":"argument\n".repeat(30)});
    }
    session.messages[21].text = "result\n".repeat(100);
    if let Some(ToolRecord::Result(record)) = &mut session.messages[21].tool_record {
        record.outcome = ToolOutcome::Failed;
        record.is_error = true;
    }
    changed.session = Arc::new(session);
    child.update(cx, |view, cx| view.update_inputs(changed.clone(), cx));
    cx.run_until_parked();
    assert_eq!(anchor(&child, cx), before);
    assert!(
        cx.read(|cx| child.read(cx).tool_height_invalidation_count()) > invalidations,
        "retained tool inputs must evict the old measured height"
    );
    let invalidations = cx.read(|cx| child.read(cx).tool_height_invalidation_count());
    assert!(
        visual.debug_bounds(selector).unwrap().size.height > short,
        "tool-record edits must invalidate measured row height"
    );
    let target = visual
        .debug_bounds(Box::leak(format!("{selector}-disclosure").into_boxed_str()))
        .unwrap()
        .center();
    visual.simulate_click(target, Modifiers::none());
    cx.run_until_parked();
    assert_eq!(anchor(&child, cx), before);
    let collapsed = visual.debug_bounds(selector).unwrap().size.height;
    assert!(
        cx.read(|cx| child.read(cx).tool_height_invalidation_count()) > invalidations,
        "disclosure must evict the old measured height"
    );
    assert!(
        collapsed < short,
        "collapse must invalidate the old expanded height"
    );
    let target = visual
        .debug_bounds(Box::leak(format!("{selector}-disclosure").into_boxed_str()))
        .unwrap()
        .center();
    visual.simulate_click(target, Modifiers::none());
    cx.run_until_parked();
    assert_eq!(anchor(&child, cx), before);
    assert!(visual.debug_bounds(selector).unwrap().size.height > collapsed);
    assert_eq!(
        cx.read(|cx| root.read(cx).record.id.clone()),
        changed.chat_id,
        "disclosure must not alter selected chat"
    );
}

#[gpui::test]
fn retained_tool_page_reveal_translates_standalone_result_anchor(cx: &mut TestAppContext) {
    let (_directory, _window, root) = fixture(cx, messages(1), 0);
    let mut changed = input(&root, cx);
    let mut session = (*changed.session).clone();
    session.messages = retained_tool_rows(40, "result\n".repeat(20).as_str());
    changed.session = Arc::new(session);
    changed.visible_messages = 61;
    let (_visual, child) = host(&root, changed.clone(), cx);
    assert_eq!(row_ids(&child, cx)[1], "tool-result-9");
    jump_to(&child, 1, 6., cx);
    changed.visible_messages = usize::MAX;
    child.update(cx, |view, cx| view.update_inputs(changed, cx));
    cx.run_until_parked();
    let after = anchor(&child, cx);
    assert!(after.0.contains("tool-assistant-9"));
    assert_eq!(after.1, px(6.));
}

#[gpui::test]
fn retained_tool_collapse_keeps_window_shortcuts_routable(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, retained_tool_rows(2, "selectable result"), 0);
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let selector = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    let output = visual
        .debug_bounds(Box::leak(format!("{selector}-OUT").into_boxed_str()))
        .unwrap();
    visual.simulate_click(output.center(), Modifiers::none());
    let toggle = visual
        .debug_bounds(Box::leak(format!("{selector}-disclosure").into_boxed_str()))
        .unwrap();
    visual.simulate_click(toggle.center(), Modifiers::none());
    cx.run_until_parked();
    let shortcut = if cfg!(target_os = "macos") {
        "cmd-shift-g"
    } else {
        "ctrl-shift-g"
    };
    cx.simulate_keystrokes(window.into(), shortcut);
    assert!(
        cx.read(|cx| root.read(cx).changes_open),
        "a collapsed preview must not keep hidden keyboard focus"
    );
}

#[gpui::test]
fn retained_tool_scroll_away_keeps_window_shortcuts_routable(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture_with_visible(
        cx,
        retained_tool_rows(100, "selectable result"),
        0,
        Some(usize::MAX),
    );
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let selector = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    let output = visual
        .debug_bounds(Box::leak(format!("{selector}-OUT").into_boxed_str()))
        .unwrap();
    visual.simulate_click(output.center(), Modifiers::none());
    jump_to(&child, 70, 0., cx);
    let shortcut = if cfg!(target_os = "macos") {
        "cmd-shift-g"
    } else {
        "ctrl-shift-g"
    };
    cx.simulate_keystrokes(window.into(), shortcut);
    assert!(
        cx.read(|cx| root.read(cx).changes_open),
        "a virtualized preview must not keep hidden keyboard focus"
    );
}

#[gpui::test]
fn retained_tool_page_repair_keeps_window_shortcuts_routable(cx: &mut TestAppContext) {
    let (_directory, window, root) =
        fixture_with_visible(cx, retained_tool_rows(40, "selectable result"), 0, Some(61));
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let selector = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    let output = visual
        .debug_bounds(Box::leak(format!("{selector}-OUT").into_boxed_str()))
        .unwrap();
    visual.simulate_click(output.center(), Modifiers::none());
    root.update(cx, |view, cx| {
        view.visible_messages = usize::MAX;
        cx.notify();
    });
    cx.run_until_parked();
    let shortcut = if cfg!(target_os = "macos") {
        "cmd-shift-g"
    } else {
        "ctrl-shift-g"
    };
    cx.simulate_keystrokes(window.into(), shortcut);
    assert!(
        cx.read(|cx| root.read(cx).changes_open),
        "a replaced orphan preview must not keep hidden keyboard focus"
    );
}

#[gpui::test]
fn retained_tool_removed_output_keeps_window_shortcuts_routable(cx: &mut TestAppContext) {
    let (_directory, window, root) = fixture(cx, retained_tool_rows(2, "selectable result"), 0);
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let selector = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    let output = visual
        .debug_bounds(Box::leak(format!("{selector}-OUT").into_boxed_str()))
        .unwrap();
    visual.simulate_click(output.center(), Modifiers::none());
    root.update(cx, |view, cx| {
        let mut session = (*view.session).clone();
        session.messages.remove(1);
        view.session = std::sync::Arc::new(session);
        cx.notify();
    });
    cx.run_until_parked();
    let shortcut = if cfg!(target_os = "macos") {
        "cmd-shift-g"
    } else {
        "ctrl-shift-g"
    };
    cx.simulate_keystrokes(window.into(), shortcut);
    assert!(
        cx.read(|cx| root.read(cx).changes_open),
        "a removed OUT section must not keep hidden keyboard focus"
    );
}

fn retained_tool_detail_restore_case(
    cx: &mut TestAppContext,
    evict: bool,
    newer_focus: bool,
    replace: bool,
) {
    let (_directory, window, root) = fixture_with_visible(
        cx,
        retained_tool_rows(100, "selectable result"),
        1,
        Some(usize::MAX),
    );
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let selector = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    let output = visual
        .debug_bounds(Box::leak(format!("{selector}-OUT").into_boxed_str()))
        .unwrap();
    visual.simulate_click(output.center(), Modifiers::none());
    let previous = window
        .update(cx, |view, window, cx| {
            let previous = window.focused(cx).unwrap();
            let id = view.session.pending[0].id.clone();
            view.open_queue_detail(id, point(px(400.), px(200.)), window, cx);
            previous
        })
        .unwrap();
    cx.run_until_parked();
    if evict {
        for index in (5..95).step_by(3) {
            jump_to(&child, index, 0., cx);
        }
        assert!(
            window
                .update(cx, |_, window, cx| {
                    crate::transcript_view::ToolFocusRestore::capture(&child, &previous, window, cx)
                        .is_none()
                })
                .unwrap(),
            "fixture must actually evict the previous editor"
        );
    } else {
        root.update(cx, |view, cx| {
            let mut session = (*view.session).clone();
            session.messages.remove(1);
            view.session = Arc::new(session);
            cx.notify();
        });
        cx.run_until_parked();
    }
    if replace {
        root.update(cx, |view, cx| {
            view.transcript = None;
            cx.notify();
        });
        cx.run_until_parked();
        assert_ne!(transcript(&root, cx).entity_id(), child.entity_id());
    }
    window
        .update(cx, |view, window, cx| {
            if newer_focus {
                view.composer.read(cx).focus(window);
            }
            view.close_queue_detail(true, window, cx);
            if newer_focus {
                assert!(view.composer.read(cx).focus_handle(cx).is_focused(window));
            } else {
                assert!(
                    !previous.is_focused(window),
                    "a removed or evicted editor must not regain focus"
                );
            }
        })
        .unwrap();
    cx.run_until_parked();
    let shortcut = if cfg!(target_os = "macos") {
        "cmd-shift-g"
    } else {
        "ctrl-shift-g"
    };
    cx.simulate_keystrokes(window.into(), shortcut);
    assert!(cx.read(|cx| root.read(cx).changes_open));
}

#[gpui::test]
fn retained_tool_detail_removed_output_restores_visible_owner(cx: &mut TestAppContext) {
    retained_tool_detail_restore_case(cx, false, false, false);
}
#[gpui::test]
fn retained_tool_detail_evicted_preview_restores_visible_owner(cx: &mut TestAppContext) {
    retained_tool_detail_restore_case(cx, true, false, false);
}
#[gpui::test]
fn retained_tool_detail_newer_composer_focus_wins(cx: &mut TestAppContext) {
    retained_tool_detail_restore_case(cx, false, true, false);
}

#[gpui::test]
fn retained_tool_detail_replaced_child_cannot_restore_old_editor(cx: &mut TestAppContext) {
    retained_tool_detail_restore_case(cx, false, false, true);
}

#[path = "transcript_read_ui_tests.rs"]
mod read_ui;

#[path = "transcript_edit_ui_tests.rs"]
mod edit_ui_tests;

#[gpui::test]
fn live_bash_output_remeasures_existing_card_then_settles_to_retained_result(
    cx: &mut TestAppContext,
) {
    use bello_agent_core::tool_history::{LiveToolView, ToolOutcome, ToolRecord};
    let (_directory, _window, root) = fixture(cx, messages(1), 0);
    let mut changed = input(&root, cx);
    let mut session = (*changed.session).clone();
    session.messages = retained_tool_rows(1, "pending");
    session.messages.truncate(1);
    session.state = bello_agent_core::RunState::Running;
    let assistant = session.messages[0].id.clone();
    session.active_reply = Some(assistant.clone());
    let call = if let Some(ToolRecord::Assistant(record)) = &mut session.messages[0].tool_record {
        record.calls[0].name = "bash".into();
        record.calls[0].arguments = serde_json::json!({"command":"printf fixture"});
        record.calls[0].id.clone()
    } else {
        panic!("fixture assistant")
    };
    session.live_tools.push(LiveToolView {
        duration_us: None,
        assistant_id: assistant,
        call_id: call,
        sequence: 1,
        preview: "first".into(),
        outcome: None,
    });
    changed.session = Arc::new(session);
    changed.visible_messages = usize::MAX;
    let (_visual, child) = host(&root, changed.clone(), cx);
    cx.run_until_parked();
    let invalidations = cx.read(|cx| child.read(cx).tool_height_invalidation_count());
    let mut next = (*changed.session).clone();
    next.live_tools[0].sequence = 2;
    next.live_tools[0].preview = "growing output\n".repeat(30).into();
    changed.session = Arc::new(next);
    child.update(cx, |view, cx| view.update_inputs(changed.clone(), cx));
    cx.run_until_parked();
    assert!(cx.read(|cx| child.read(cx).tool_height_invalidation_count()) > invalidations);
    let editors = cx.read(|cx| child.read(cx).tool_section_editors());
    assert!(
        editors
            .iter()
            .any(|(_, editor)| { cx.read(|cx| editor.read(cx).text().contains("growing output")) })
    );
    let mut next = (*changed.session).clone();
    next.live_tools[0].outcome = Some(ToolOutcome::Failed);
    next.live_tools[0].preview = "failed\nExit code: 7".into();
    changed.session = Arc::new(next);
    child.update(cx, |view, cx| view.update_inputs(changed.clone(), cx));
    cx.run_until_parked();
    assert!(
        cx.read(|cx| child.read(cx).tool_section_editors())
            .iter()
            .any(|(_, editor)| cx.read(|cx| editor.read(cx).text().contains("Exit code: 7")))
    );
}

#[path = "transcript_live_terminal_ui_tests.rs"]
mod live_terminal_ui;

#[path = "transcript_tool_timing_tests.rs"]
mod tool_timing_ui;

#[::core::prelude::v1::test]
fn unread_reply_end_requires_real_finite_viewport_not_first_line_or_overdraw() {
    use crate::transcript_view::reply_end_visible;
    let viewport = Bounds::new(point(px(10.), px(20.)), size(px(500.), px(300.)));
    let row = |top, height| Bounds::new(point(px(10.), px(top)), size(px(500.), px(height)));
    assert!(reply_end_visible(row(100., 220.), viewport));
    assert!(
        reply_end_visible(row(-100., 300.), viewport),
        "end visible even when first line is above viewport"
    );
    assert!(
        !reply_end_visible(row(30., 1000.), viewport),
        "first line of long reply is insufficient"
    );
    assert!(
        !reply_end_visible(row(321., 40.), viewport),
        "materialized lower overdraw is not seen"
    );
    assert!(
        !reply_end_visible(row(-80., 100.), viewport),
        "end exactly above viewport is not seen"
    );
    assert!(!reply_end_visible(row(0., f32::NAN), viewport));
    assert!(!reply_end_visible(row(30., 40.), Bounds::default()));
}

#[gpui::test]
fn unread_reply_end_uses_postlayout_measured_long_reply_and_rejects_overdraw(
    cx: &mut TestAppContext,
) {
    let mut rows = messages(25);
    rows[0] = message(
        "long-first",
        "assistant",
        &("A long readable line\n".repeat(100)),
    );
    let (_dir, _window, root) = fixture_with_visible(cx, rows, 0, Some(usize::MAX));
    let child = transcript(&root, cx);
    jump_to(&child, 0, 0., cx);
    let list = scroll(&child, cx);
    let viewport = list.viewport_bounds();
    let first = list
        .bounds_for_item(0)
        .expect("first long reply is measured");
    assert!(first.top() < viewport.bottom());
    assert!(first.bottom() > viewport.bottom());
    assert!(!crate::transcript_view::reply_end_visible(first, viewport));
    jump_to(
        &child,
        0,
        (first.size.height - viewport.size.height / 2.).to_f64() as f32,
        cx,
    );
    let list = scroll(&child, cx);
    let end = list
        .bounds_for_item(0)
        .expect("same long reply end is measured");
    assert!(crate::transcript_view::reply_end_visible(
        end,
        list.viewport_bounds()
    ));
    let overdraw = (1..25)
        .filter_map(|i| list.bounds_for_item(i))
        .find(|row| row.top() >= list.viewport_bounds().bottom())
        .expect("List measured its lower overdraw");
    assert!(!crate::transcript_view::reply_end_visible(
        overdraw,
        list.viewport_bounds()
    ));
}
