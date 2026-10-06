//! Fake-platform clipboard/menu ownership checks; no native AppKit tracking claim.
use super::{SidebarAction, SidebarMenu};
use crate::{AgentView, LaunchState};
use bello_agent_core::{
    Controller, SessionStore,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
use gpui::{ClipboardItem, Entity, EntityInputHandler, Focusable, TestAppContext, WindowHandle};
#[cfg(not(target_os = "macos"))]
use gpui::{Modifiers, VisualTestContext, point, px};
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
            text: "first draft 日本語".into(),
            ..Default::default()
        },
        pending: true,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).unwrap();
    cx.run_until_parked();
    (dir, window, root)
}
fn clipboard(cx: &TestAppContext) -> String {
    cx.read(|cx| cx.read_from_clipboard().unwrap().text().unwrap())
}
fn sentinel(cx: &mut TestAppContext) {
    cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_string("unchanged sentinel".into())));
}
fn install_menu(view: &mut AgentView, id: &str) -> uuid::Uuid {
    let token = uuid::Uuid::new_v4();
    view.sidebar_menu = Some(SidebarMenu {
        token,
        chat_id: id.into(),
        project: view.project.clone(),
        binding: view.window_binding,
        pinned: false,
        selected: SidebarAction::SetPinned(true),
        #[cfg(not(target_os = "macos"))]
        position: point(px(80.), px(100.)),
    });
    token
}

#[gpui::test]
fn sidebar_copy_id_targets_nonselected_pending_record_without_saving_or_focusing(
    cx: &mut TestAppContext,
) {
    let (dir, window, root) = fixture(cx);
    let first = cx.read(|cx| root.read(cx).record.id.clone());
    window
        .update(cx, |view, window, cx| view.new_chat(window, cx))
        .unwrap();
    let second = cx.read(|cx| root.read(cx).record.id.clone());
    assert_ne!(first, second);
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.replace_and_mark_text_in_range(None, "marked 漢字", Some(2..2), window, cx)
            });
            let text = view.composer.read(cx).text().to_owned();
            let revision = view.draft_revision;
            let token = install_menu(view, &first);
            view.finish_sidebar_menu(token, Some(SidebarAction::CopySessionId), cx);
            assert_eq!(view.record.id, second);
            assert_eq!(view.composer.read(cx).text(), text);
            assert_eq!(view.draft_revision, revision);
            assert!(view.composer.read(cx).has_marked_text());
            assert!(view.composer.read(cx).focus_handle(cx).is_focused(window));
            assert!(view.pin_operations.is_empty());
            assert!(view.records.iter().all(|record| record.pinned_at.is_none()));
            assert!(!view.inactive[&first].controller.is_persistent());
        })
        .unwrap();
    assert_eq!(clipboard(cx), first);
    assert!(!dir.path().join("catalog.json").exists());
    assert!(!dir.path().join("session.json").exists());
}

#[gpui::test]
fn sidebar_copy_id_rejects_stale_token_project_window_shutdown_and_removed_record(
    cx: &mut TestAppContext,
) {
    let (_dir, window, root) = fixture(cx);
    let id = cx.read(|cx| root.read(cx).record.id.clone());
    sentinel(cx);
    window
        .update(cx, |view, _, cx| {
            let old = install_menu(view, &id);
            let current = install_menu(view, &id);
            view.finish_sidebar_menu(old, Some(SidebarAction::CopySessionId), cx);
            assert_eq!(view.sidebar_menu.as_ref().unwrap().token, current);
            assert_eq!(
                cx.read_from_clipboard().unwrap().text().as_deref(),
                Some("unchanged sentinel")
            );
            view.finish_sidebar_menu(current, None, cx);
            assert!(view.sidebar_menu.is_none());
            for guard in 0..3 {
                let token = install_menu(view, &id);
                let project = view.project.clone();
                let binding = view.window_binding;
                match guard {
                    0 => view.project = project.join("different-project"),
                    1 => view.window_binding = None,
                    _ => view.shutting_down = true,
                }
                view.finish_sidebar_menu(token, Some(SidebarAction::CopySessionId), cx);
                assert!(view.sidebar_menu.is_none());
                assert_eq!(
                    cx.read_from_clipboard().unwrap().text().as_deref(),
                    Some("unchanged sentinel")
                );
                view.project = project;
                view.window_binding = binding;
                view.shutting_down = false;
            }
            let token = install_menu(view, &id);
            view.records.clear();
            view.finish_sidebar_menu(token, Some(SidebarAction::CopySessionId), cx);
            assert_eq!(
                view.error.as_deref(),
                Some("That chat is no longer available to copy.")
            );
        })
        .unwrap();
    assert_eq!(clipboard(cx), "unchanged sentinel");
}

#[cfg(not(target_os = "macos"))]
#[gpui::test]
fn sidebar_copy_id_keyboard_selection_and_escape_preserve_pin_behavior(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    let id = cx.read(|cx| root.read(cx).record.id.clone());
    sentinel(cx);
    window
        .update(cx, |view, window, cx| {
            view.open_sidebar_menu(&id, point(px(80.), px(100.)), window, cx)
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), "down down");
    assert_eq!(
        cx.read(|cx| root.read(cx).sidebar_menu.as_ref().unwrap().selected),
        SidebarAction::CopySessionId
    );
    cx.simulate_keystrokes(window.into(), "escape");
    assert_eq!(clipboard(cx), "unchanged sentinel");
    window
        .update(cx, |view, window, cx| {
            view.open_sidebar_menu(&id, point(px(80.), px(100.)), window, cx)
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), "down enter");
    assert_eq!(clipboard(cx), id);
    assert!(cx.read(|cx| root.read(cx).pin_operations.is_empty()));
    window
        .update(cx, |view, window, cx| {
            view.open_sidebar_menu(&id, point(px(80.), px(100.)), window, cx)
        })
        .unwrap();
    cx.simulate_keystrokes(window.into(), "down up up enter");
    cx.run_until_parked();
    assert!(cx.read(|cx| {
        root.read(cx)
            .records
            .iter()
            .find(|record| record.id == id)
            .unwrap()
            .pinned_at
            .is_some()
    }));
    assert_eq!(clipboard(cx), id);
}

#[cfg(not(target_os = "macos"))]
#[gpui::test]
fn sidebar_copy_id_mouse_uses_real_menu_row_and_keeps_other_chat_selected(cx: &mut TestAppContext) {
    let (_dir, window, root) = fixture(cx);
    let first = cx.read(|cx| root.read(cx).record.id.clone());
    window
        .update(cx, |view, window, cx| view.new_chat(window, cx))
        .unwrap();
    let second = cx.read(|cx| root.read(cx).record.id.clone());
    window
        .update(cx, |view, window, cx| {
            view.open_sidebar_menu(&first, point(px(80.), px(100.)), window, cx)
        })
        .unwrap();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let bounds = visual.debug_bounds("sidebar-copy-id-choice").unwrap();
    visual.simulate_click(bounds.center(), Modifiers::none());
    assert_eq!(clipboard(cx), first);
    assert_eq!(cx.read(|cx| root.read(cx).record.id.clone()), second);
    assert!(cx.read(|cx| root.read(cx).sidebar_menu.is_none()));
    assert!(cx.read(|cx| root.read(cx).pin_operations.is_empty()));
}
