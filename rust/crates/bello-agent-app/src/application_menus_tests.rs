use super::*;
use crate::transcript_view_tests::fixture_with;
use ::core::prelude::v1::test;

#[::core::prelude::v1::test]
fn source_menu_subset_has_only_implemented_actions() {
    let menus = menus();
    assert_eq!(
        menus.iter().map(|m| m.name.as_ref()).collect::<Vec<_>>(),
        [
            "Bello Agent",
            "File",
            "Edit",
            "View",
            "Conversation",
            "Window"
        ]
    );
    assert_eq!(
        menus[2]
            .items
            .iter()
            .filter_map(|item| match item {
                MenuItem::Action {
                    name, os_action, ..
                } => {
                    assert!(os_action.is_none());
                    Some(name.as_ref())
                }
                _ => None,
            })
            .collect::<Vec<_>>(),
        ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"]
    );
    let titles = menus
        .iter()
        .flat_map(|m| &m.items)
        .filter_map(|item| match item {
            MenuItem::Action { name, .. } => Some(name.as_ref()),
            _ => None,
        })
        .collect::<Vec<_>>();
    for missing in [
        "Check for Updates…",
        "Usage Report",
        "Background Requests",
        "Open Side",
        "Import Pi Session…",
    ] {
        assert!(!titles.contains(&missing));
    }
}

// TestPlatform drops native menus/callbacks. Reproduce MacWindow's window-first
// performKeyEquivalent order, then use the installed bindings and availability
// checks and Window action dispatch used by GPUI's native menu callback.
fn equivalent(window: WindowHandle<AgentView>, key: &str, cx: &mut TestAppContext) -> bool {
    let key = Keystroke::parse(key).unwrap();
    let handled = cx
        .update_window(window.into(), |_, w, cx| {
            w.dispatch_keystroke(key.clone(), cx)
        })
        .unwrap();
    cx.run_until_parked();
    if handled {
        return true;
    }
    let action = cx.read(|cx| {
        let keymap = cx.key_bindings();
        let keymap = keymap.borrow();
        menus().iter().flat_map(|m| &m.items).find_map(|item| {
            let MenuItem::Action { action, .. } = item else {
                return None;
            };
            keymap
                .bindings_for_action(action.as_ref())
                .next()
                .filter(|b| {
                    b.keystrokes().len() == 1
                        && b.keystrokes()[0].key() == key.key
                        && *b.keystrokes()[0].modifiers() == key.modifiers
                })
                .map(|_| action.boxed_clone())
        })
    });
    if let Some(action) = action
        && cx
            .update_window(window.into(), |_, w, cx| {
                w.is_action_available(action.as_ref(), cx)
            })
            .unwrap()
    {
        cx.update_window(window.into(), |_, w, cx| w.dispatch_action(action, cx))
            .unwrap();
        cx.run_until_parked();
        return true;
    }
    false
}

#[gpui::test]
fn menu_clicks_use_focused_editor_clipboard_and_undo_history(cx: &mut TestAppContext) {
    cx.update(install);
    let (_dir, window, root) = fixture_with(cx, vec![], 0, None, false);
    window
        .update(cx, |v, w, cx| v.composer.read(cx).focus(w))
        .unwrap();
    cx.run_until_parked();
    cx.dispatch_action(window.into(), SelectAll);
    cx.dispatch_action(window.into(), Copy);
    cx.read(|cx| {
        assert_eq!(
            cx.read_from_clipboard().unwrap().text().as_deref(),
            Some("draft")
        )
    });
    cx.dispatch_action(window.into(), Cut);
    cx.read(|cx| assert_eq!(root.read(cx).composer.read(cx).text(), ""));
    cx.dispatch_action(window.into(), Undo);
    cx.read(|cx| assert_eq!(root.read(cx).composer.read(cx).text(), "draft"));
    cx.dispatch_action(window.into(), Redo);
    cx.read(|cx| assert_eq!(root.read(cx).composer.read(cx).text(), ""));
    cx.dispatch_action(window.into(), Paste);
    cx.read(|cx| assert_eq!(root.read(cx).composer.read(cx).text(), "draft"));
    assert!(equivalent(window, "cmd-a", cx));
    assert!(equivalent(window, "cmd-c", cx));
}

#[gpui::test]
fn key_equivalent_routes_find_settings_new_chat_and_preserves_composer_keys(
    cx: &mut TestAppContext,
) {
    cx.update(install);
    let (_dir, window, root) = fixture_with(cx, vec![], 0, None, true);
    window
        .update(cx, |v, w, cx| v.composer.read(cx).focus(w))
        .unwrap();
    cx.run_until_parked();
    assert!(equivalent(window, "cmd-f", cx));
    cx.read(|cx| assert!(root.read(cx).transcript_find.is_some()));
    window
        .update(cx, |v, w, cx| {
            v.close_transcript_find(w, cx);
            v.composer.read(cx).focus(w);
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    // Paused fixture queues inputs, never contacts its discard endpoint.
    assert!(equivalent(window, "cmd-enter", cx));
    cx.read(|cx| assert_eq!(root.read(cx).session.pending.len(), 1));
    assert!(equivalent(window, "cmd-,", cx));
    cx.read(|cx| assert!(root.read(cx).connections.open));
    window
        .update(cx, |v, w, cx| v.request_connection_close(w, cx))
        .unwrap();
    cx.run_until_parked();
    let old = cx.read(|cx| root.read(cx).record.id.clone());
    assert!(equivalent(window, "cmd-n", cx));
    cx.read(|cx| assert_ne!(root.read(cx).record.id, old));
    cx.read(|cx| {
        for binding in cx.key_bindings().borrow().bindings() {
            assert!(!binding.keystrokes().iter().any(|key| key.key() == "enter"));
        }
    });
}

#[gpui::test]
fn menu_availability_and_edit_routing_follow_focus_and_modal_owner(cx: &mut TestAppContext) {
    cx.update(install);
    let (_dir, window, root) = fixture_with(cx, vec![], 0, None, false);
    window
        .update(cx, |v, w, cx| {
            v.filter
                .update(cx, |e, cx| e.set_text("filter text".into(), cx));
            v.filter.read(cx).focus(w);
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    cx.dispatch_action(window.into(), SelectAll);
    cx.dispatch_action(window.into(), Cut);
    cx.read(|cx| {
        assert_eq!(root.read(cx).filter.read(cx).text(), "");
        assert_eq!(root.read(cx).composer.read(cx).text(), "draft");
    });
    window
        .update(cx, |v, w, cx| v.open_connections(w, cx))
        .unwrap();
    cx.run_until_parked();
    cx.update_window(window.into(), |_, w, cx| {
        assert!(!w.is_action_available(&NewChat, cx));
        assert!(!w.is_action_available(&Find, cx));
        assert!(!w.is_action_available(&EditorTarget, cx));
    })
    .unwrap();
}
