//! Actual sidebar and Move panel layout, with raw-title/storage invariants.
use crate::{AgentView, LaunchState};
use bello_agent_core::{
    Controller, SessionStore,
    workspace::{ChatRecord, DraftRecord, TopicRecord, WorkspaceStore},
};
use gpui::{Entity, TestAppContext, VisualTestContext, WindowHandle, px, size};
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
        .transact(|s| {
            s.title = "Existing\nraw title".into();
            Ok(())
        })
        .unwrap();
    let record = ChatRecord::new(
        store.snapshot().id,
        store.snapshot().title,
        project.join("session.json"),
    );
    let launch = LaunchState {
        controller: Controller::new(store, None).unwrap(),
        project: project.clone(),
        workspace: Arc::new(Mutex::new(
            WorkspaceStore::open(project.join("catalog.json"), &project).unwrap(),
        )),
        record,
        draft: DraftRecord::default(),
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    (dir, window, root)
}
fn selector(prefix: &str, id: &str) -> &'static str {
    Box::leak(format!("{prefix}-{id}").into_boxed_str())
}
fn set_title(window: WindowHandle<AgentView>, title: &str, cx: &mut TestAppContext) {
    window
        .update(cx, |view, _, cx| {
            Arc::make_mut(&mut view.session).title = title.into();
            view.record.title = title.into();
            let id = view.record.id.clone();
            view.records.iter_mut().find(|r| r.id == id).unwrap().title = title.into();
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
}
#[gpui::test]
fn sidebar_title_geometry_is_single_line_across_raw_title_sources(cx: &mut TestAppContext) {
    let (dir, window, root) = fixture(cx);
    let before = std::fs::read(dir.path().join("session.json")).unwrap();
    let id = cx.read(|cx| root.read(cx).record.id.clone());
    let title_selector = selector("chat-title", &id);
    let row_selector = selector("chat-row", &id);
    for width in [1178., 920., 480.] {
        let visual = VisualTestContext::from_window(window.into(), cx);
        visual.simulate_resize(size(px(width), px(814.)));
        for source in ["live", "loading", "failed", "topic", "archived", "pinned"] {
            window
                .update(cx, |view, _, cx| {
                    view.loading = source == "loading";
                    view.load_failed = source == "failed";
                    view.topics.clear();
                    view.record.archived_at = (source == "archived").then_some(1);
                    view.record.pinned_at = (source == "pinned").then_some(1);
                    view.record.topic_id = (source == "topic").then(|| "topic".into());
                    if source == "topic" {
                        view.topics.push(TopicRecord {
                            id: "topic".into(),
                            title: "Topic".into(),
                            created_at: 1,
                            expanded: true,
                            revision: 0,
                        });
                    }
                    view.records = vec![view.record.clone()];
                    // Exercise the renderer at a narrower sidebar width too.
                    view.layout.sidebar = if width == 480. { 210. } else { 260. };
                    view.show_archived = true;
                    cx.notify();
                })
                .unwrap();
            set_title(window, "one line", cx);
            let mut visual = VisualTestContext::from_window(window.into(), cx);
            let line = visual.debug_bounds(title_selector).unwrap().size.height;
            let row = visual.debug_bounds(row_selector).unwrap().size.height;
            for text in [
                format!("oversize{}\nend", "\nx".repeat(45)),
                "x".repeat(400),
            ] {
                set_title(window, &text, cx);
                let mut visual = VisualTestContext::from_window(window.into(), cx);
                assert_eq!(
                    visual.debug_bounds(title_selector).unwrap().size.height,
                    line,
                    "title {source} at {width}"
                );
                assert_eq!(
                    visual.debug_bounds(row_selector).unwrap().size.height,
                    row,
                    "row {source} at {width}"
                );
                cx.read(|cx| {
                    let view = root.read(cx);
                    assert_eq!(view.sidebar_title(&view.records[0]), text);
                });
            }
        }
    }
    assert_eq!(
        std::fs::read(dir.path().join("session.json")).unwrap(),
        before
    );
}
#[gpui::test]
fn move_panel_title_geometry_preserves_raw_filter_and_disk(cx: &mut TestAppContext) {
    let (dir, window, root) = fixture(cx);
    let before = std::fs::read(dir.path().join("session.json")).unwrap();
    window
        .update(cx, |view, window, cx| {
            let id = view.record.id.clone();
            view.open_topics(&id, window, cx);
        })
        .unwrap();
    for width in [1178., 920., 480.] {
        let visual = VisualTestContext::from_window(window.into(), cx);
        visual.simulate_resize(size(px(width), px(814.)));
        set_title(window, "one line", cx);
        let mut visual = VisualTestContext::from_window(window.into(), cx);
        let heading = visual
            .debug_bounds("topics-chat-title")
            .unwrap()
            .size
            .height;
        let panel = visual.debug_bounds("topics-panel").unwrap().size.height;
        for text in [
            format!("oversize{}\nneedle", "\nx".repeat(45)),
            "x".repeat(400),
        ] {
            set_title(window, &text, cx);
            let mut visual = VisualTestContext::from_window(window.into(), cx);
            assert_eq!(
                visual
                    .debug_bounds("topics-chat-title")
                    .unwrap()
                    .size
                    .height,
                heading,
                "heading {width}"
            );
            assert_eq!(
                visual.debug_bounds("topics-panel").unwrap().size.height,
                panel,
                "panel {width}"
            );
            let bounds = visual.debug_bounds("topics-panel").unwrap();
            assert!(bounds.contains(&visual.debug_bounds("topics-save").unwrap().center()));
            assert!(bounds.contains(&visual.debug_bounds("topics-close").unwrap().center()));
        }
    }
    set_title(window, "first\nlater-token", cx);
    window
        .update(cx, |view, _, cx| {
            view.filter.update(cx, |filter, cx| {
                filter.set_text("first\nlater-token".into(), cx)
            });
            assert_eq!(view.visible_sidebar_records(cx).len(), 1);
            view.filter.update(cx, |filter, cx| {
                filter.set_text("first later-token".into(), cx)
            });
            assert!(view.visible_sidebar_records(cx).is_empty());
            assert_eq!(view.sidebar_title(&view.records[0]), "first\nlater-token");
        })
        .unwrap();
    assert_eq!(
        std::fs::read(dir.path().join("session.json")).unwrap(),
        before
    );
    cx.read(|cx| assert!(root.read(cx).session.messages.is_empty()));
}

#[gpui::test]
fn unselected_retained_title_does_not_displace_next_row_or_footer(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    let id = "retained-title";
    window
        .update(cx, |view, _, cx| {
            let mut record = ChatRecord::new(
                id.into(),
                "one line".into(),
                view.project.join("unloaded.json"),
            );
            record.pinned_at = Some(1);
            view.records.insert(0, record);
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    let selected = cx.read(|cx| root.read(cx).record.id.clone());
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let next = visual
        .debug_bounds(selector("chat-row", &selected))
        .unwrap();
    let row = visual.debug_bounds(selector("chat-row", id)).unwrap();
    let footer = visual.debug_bounds("sidebar-title-test-footer").unwrap();
    window
        .update(cx, |view, _, cx| {
            view.records.iter_mut().find(|r| r.id == id).unwrap().title =
                format!("oversize{}\nlast", "\nx".repeat(45));
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert_eq!(visual.debug_bounds(selector("chat-row", id)).unwrap(), row);
    assert_eq!(
        visual
            .debug_bounds(selector("chat-row", &selected))
            .unwrap(),
        next
    );
    assert_eq!(
        visual.debug_bounds("sidebar-title-test-footer").unwrap(),
        footer
    );
    assert!(next.bottom() < footer.top());
}
