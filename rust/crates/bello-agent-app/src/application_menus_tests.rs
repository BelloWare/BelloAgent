use super::*;
use crate::transcript_view_tests::fixture_with;
use ::core::prelude::v1::test;

fn labels(menu: &Menu) -> Vec<String> {
    menu.items
        .iter()
        .map(|item| match item {
            MenuItem::Separator => "-".into(),
            MenuItem::Submenu(menu) => format!("{} ▸", menu.name),
            MenuItem::SystemMenu(menu) => format!("{} ▸", menu.name),
            MenuItem::Action { name, .. } => name.to_string(),
        })
        .collect()
}

fn actions(menus: &[Menu]) -> Vec<(String, Box<dyn Action>)> {
    fn walk(items: &[MenuItem], out: &mut Vec<(String, Box<dyn Action>)>) {
        for item in items {
            match item {
                MenuItem::Action { name, action, .. } => {
                    out.push((name.to_string(), action.boxed_clone()))
                }
                MenuItem::Submenu(menu) => walk(&menu.items, out),
                _ => {}
            }
        }
    }
    let mut out = Vec::new();
    for menu in menus {
        walk(&menu.items, &mut out);
    }
    out
}

#[::core::prelude::v1::test]
fn menu_bar_follows_swift_order_titles_and_omits_unimplemented_commands() {
    let menus = menus(&MenuState::default());
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
    let expected: [&[&str]; 6] = [
        &[
            "About Bello Agent",
            "-",
            "Settings…",
            "-",
            "Services ▸",
            "-",
            "Hide Bello Agent",
            "Hide Others",
            "Show All",
            "-",
            "Quit Bello Agent",
        ],
        &[
            "New Chat",
            "Open File…",
            "-",
            "Archive Chat",
            "Pin Chat",
            "Move to Topic ▸",
            "Mark as Read",
            "Mark as Unread",
            "-",
            "Close Window",
        ],
        &["Undo", "Redo", "-", "Cut", "Copy", "Paste", "Select All"],
        &[
            "Show Archived Chats",
            "Session Inspector…",
            "Changes and History…",
            "-",
            "Next Chat",
            "Previous Chat",
            "-",
            "Widen Sidebar",
            "Narrow Sidebar",
        ],
        &[
            "Send / Queue Follow-up",
            "Send / Steer Current Run",
            "Stop",
            "Resume Follow-ups",
            "Compact Now",
            "Latest Messages",
            "-",
            "Find…",
            "Find Next",
            "Find Previous",
            "Search and Copy Conversation…",
        ],
        &["Minimize", "Zoom", "-", "Bring All to Front"],
    ];
    for (menu, expected) in menus.iter().zip(expected) {
        assert_eq!(labels(menu), expected, "{}", menu.name);
    }
    // Edit routes through GPUI, never AppKit selectors the editor lacks.
    for item in &menus[2].items {
        if let MenuItem::Action { os_action, .. } = item {
            assert!(os_action.is_none());
        }
    }
    // Swift commands whose feature Rust lacks are omitted, never dead items.
    let titles = actions(&menus)
        .into_iter()
        .map(|(title, _)| title)
        .collect::<Vec<_>>();
    for missing in [
        "Check for Updates…",
        "Open Project…",
        "Import Pi Session…",
        "Rename Chat…",
        "Delete Chat…",
        "Usage Report",
        "Background Requests",
        "Show Terminal",
        "Open Side",
        "Fold This Turn",
        "Fold Every Turn",
        "Fold This Response to One Line",
    ] {
        assert!(!titles.iter().any(|t| t == missing), "{missing}");
    }

    let state = MenuState {
        pinned: true,
        archived: true,
        archived_shown: true,
        topics: vec![("t1".into(), "Alpha".into()), ("t2".into(), "Beta".into())],
    };
    let menus = super::menus(&state);
    assert_eq!(labels(&menus[1])[3..5], ["Restore Chat", "Unpin Chat"]);
    assert_eq!(labels(&menus[3])[0], "Hide Archived Chats");
    let MenuItem::Submenu(topics) = &menus[1].items[5] else {
        panic!("Move to Topic is a submenu");
    };
    assert_eq!(labels(topics), ["Project root", "Alpha", "Beta"]);
    let MenuItem::Action { action, .. } = &topics.items[2] else {
        panic!()
    };
    assert!(action.partial_eq(&MoveToTopic {
        topic: Some("t2".into())
    }));
}

#[gpui::test]
fn menu_key_equivalents_are_swifts(cx: &mut TestAppContext) {
    cx.update(install);
    let expected = [
        ("Settings…", "cmd-,"),
        ("Hide Bello Agent", "cmd-h"),
        ("Hide Others", "cmd-alt-h"),
        ("Quit Bello Agent", "cmd-q"),
        ("New Chat", "cmd-n"),
        ("Open File…", "cmd-p"),
        ("Close Window", "cmd-w"),
        ("Undo", "cmd-z"),
        ("Redo", "cmd-shift-z"),
        ("Cut", "cmd-x"),
        ("Copy", "cmd-c"),
        ("Paste", "cmd-v"),
        ("Select All", "cmd-a"),
        ("Session Inspector…", "cmd-alt-i"),
        ("Changes and History…", "cmd-shift-g"),
        ("Next Chat", "cmd-alt-down"),
        ("Previous Chat", "cmd-alt-up"),
        ("Widen Sidebar", "ctrl-cmd-right"),
        ("Narrow Sidebar", "ctrl-cmd-left"),
        ("Send / Steer Current Run", "cmd-enter"),
        ("Stop", "cmd-."),
        ("Find…", "cmd-f"),
        ("Find Next", "cmd-g"),
        ("Find Previous", "cmd-shift-g"),
        ("Search and Copy Conversation…", "cmd-alt-f"),
        ("Minimize", "cmd-m"),
    ];
    cx.read(|cx| {
        let keymap = cx.key_bindings();
        let keymap = keymap.borrow();
        for (title, action) in actions(&menus(&MenuState::default())) {
            let shown = keymap
                .bindings_for_action(action.as_ref())
                .next()
                .map(|binding| {
                    assert_eq!(binding.keystrokes().len(), 1, "{title}");
                    let key = &binding.keystrokes()[0];
                    (key.key().to_owned(), *key.modifiers())
                });
            let want = expected.iter().find(|(t, _)| *t == title).map(|(_, key)| {
                let key = Keystroke::parse(key).unwrap();
                (key.key, key.modifiers)
            });
            assert_eq!(shown, want, "{title}");
        }
    });
}

// TestPlatform drops native menus/callbacks. Reproduce MacWindow's window-first
// performKeyEquivalent order, then AppKit's first enabled matching menu item
// (by GPUI's availability check), dispatched as GPUI's menu callback does.
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
    let state = cx.read(|cx| cx.global::<InstalledMenus>().0.clone());
    let candidates = cx.read(|cx| {
        let keymap = cx.key_bindings();
        let keymap = keymap.borrow();
        actions(&menus(&state))
            .into_iter()
            .filter(|(_, action)| {
                keymap
                    .bindings_for_action(action.as_ref())
                    .next()
                    .is_some_and(|b| {
                        b.keystrokes().len() == 1
                            && b.keystrokes()[0].key() == key.key
                            && *b.keystrokes()[0].modifiers() == key.modifiers
                    })
            })
            .map(|(_, action)| action)
            .collect::<Vec<_>>()
    });
    for action in candidates {
        let available = cx
            .update_window(window.into(), |_, w, cx| {
                w.is_action_available(action.as_ref(), cx)
            })
            .unwrap();
        if available {
            cx.update_window(window.into(), |_, w, cx| w.dispatch_action(action, cx))
                .unwrap();
            cx.run_until_parked();
            return true;
        }
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
    // With the find bar open the window takes ⇧⌘G before Changes and History.
    assert!(equivalent(window, "cmd-shift-g", cx));
    cx.read(|cx| assert!(!root.read(cx).changes_open));
    window
        .update(cx, |v, w, cx| {
            v.close_transcript_find(w, cx);
            v.composer.read(cx).focus(w);
            cx.notify();
        })
        .unwrap();
    cx.run_until_parked();
    // The composer owns ⌘↩ although Send / Steer shows it: one queued input,
    // not a second menu submission. The paused fixture never contacts its
    // discard endpoint.
    assert!(equivalent(window, "cmd-enter", cx));
    cx.read(|cx| {
        assert_eq!(root.read(cx).session.pending.len(), 1);
        assert_eq!(root.read(cx).composer.read(cx).text(), "");
    });
    assert!(equivalent(window, "cmd-,", cx));
    cx.read(|cx| assert!(root.read(cx).connections.open));
    window
        .update(cx, |v, w, cx| v.request_connection_close(w, cx))
        .unwrap();
    cx.run_until_parked();
    let old = cx.read(|cx| root.read(cx).record.id.clone());
    assert!(equivalent(window, "cmd-n", cx));
    cx.read(|cx| assert_ne!(root.read(cx).record.id, old));
}

#[gpui::test]
fn menu_only_key_equivalents_reach_their_commands(cx: &mut TestAppContext) {
    cx.update(install);
    let (_dir, window, root) = fixture_with(cx, vec![], 0, None, false);
    window
        .update(cx, |v, w, cx| v.composer.read(cx).focus(w))
        .unwrap();
    cx.run_until_parked();
    // The window takes ⌃⌘→/⌃⌘← before the focused composer's caret keys.
    assert!(equivalent(window, "ctrl-cmd-right", cx));
    cx.read(|cx| assert_eq!(root.read(cx).layout.sidebar, 324.));
    assert!(equivalent(window, "ctrl-cmd-left", cx));
    assert!(equivalent(window, "ctrl-cmd-left", cx));
    cx.read(|cx| assert_eq!(root.read(cx).layout.sidebar, 276.));
    for _ in 0..12 {
        assert!(equivalent(window, "ctrl-cmd-right", cx));
    }
    cx.read(|cx| assert_eq!(root.read(cx).layout.sidebar, 420.));
    cx.read(|cx| {
        assert!(root.read(cx).inspector_windows.is_empty());
        assert_eq!(root.read(cx).composer.read(cx).text(), "draft");
    });
    // No window handler takes ⌥⌘I; AppKit's menu fallback does.
    assert!(equivalent(window, "cmd-alt-i", cx));
    cx.read(|cx| assert_eq!(root.read(cx).inspector_windows.len(), 1));
    window
        .update(cx, |v, _, cx| v.close_context_inspectors(cx))
        .unwrap();
    cx.run_until_parked();
    // Without a find bar the window opens Changes and History for ⇧⌘G.
    assert!(equivalent(window, "cmd-shift-g", cx));
    cx.read(|cx| assert!(root.read(cx).changes_open));
}

#[gpui::test]
fn menu_commands_route_to_the_selected_chat_and_retitle(cx: &mut TestAppContext) {
    cx.update(install);
    let (_dir, window, root) = fixture_with(cx, vec![], 0, None, true);
    let installed = |cx: &mut TestAppContext| cx.read(|cx| cx.global::<InstalledMenus>().0.clone());
    assert_eq!(installed(cx), MenuState::default());

    cx.dispatch_action(window.into(), ToggleArchivedChats);
    cx.run_until_parked();
    cx.read(|cx| assert!(root.read(cx).effective_archive_visibility()));
    assert!(installed(cx).archived_shown);

    cx.dispatch_action(window.into(), TogglePinned);
    cx.run_until_parked();
    assert!(installed(cx).pinned, "Pin Chat retitles to Unpin Chat");
    cx.dispatch_action(window.into(), TogglePinned);
    cx.run_until_parked();
    assert!(!installed(cx).pinned);

    // The paused fixture queues a menu send; its endpoint is never contacted.
    cx.dispatch_action(window.into(), SendFollowUp);
    cx.read(|cx| {
        assert_eq!(root.read(cx).session.pending.len(), 1);
        assert_eq!(root.read(cx).composer.read(cx).text(), "");
    });
    cx.update_window(window.into(), |_, w, cx| {
        assert!(w.is_action_available(&ResumeFollowUps, cx));
        assert!(w.is_action_available(&Stop, cx));
        assert!(w.is_action_available(&CompactNow, cx));
        assert!(w.is_action_available(&LatestMessages, cx));
        assert!(w.is_action_available(&MoveToTopic { topic: None }, cx));
        assert!(w.is_action_available(&MarkUnread, cx));
        // Find Previous waits for an open find bar, as Swift's does.
        assert!(!w.is_action_available(&FindPrevious, cx));
        assert!(w.is_action_available(&FindNext, cx));
    })
    .unwrap();
    cx.dispatch_action(window.into(), FindNext);
    cx.read(|cx| assert!(root.read(cx).transcript_find.is_some()));
    cx.update_window(window.into(), |_, w, cx| {
        assert!(w.is_action_available(&FindPrevious, cx))
    })
    .unwrap();
    cx.dispatch_action(window.into(), MarkUnread);
    cx.run_until_parked();
    cx.read(|cx| {
        assert_eq!(
            cx.global::<crate::notifications::Notifications>()
                .badge_label(),
            Some("1")
        )
    });
    cx.dispatch_action(window.into(), MarkRead);
    cx.run_until_parked();
    cx.read(|cx| {
        assert_eq!(
            cx.global::<crate::notifications::Notifications>()
                .badge_label(),
            None
        )
    });

    cx.dispatch_action(window.into(), ToggleArchived);
    cx.run_until_parked();
    assert!(
        installed(cx).archived,
        "Archive Chat retitles to Restore Chat"
    );
    cx.update_window(window.into(), |_, w, cx| {
        // An archived chat has no composer to send from.
        assert!(!w.is_action_available(&SendFollowUp, cx));
        assert!(!w.is_action_available(&SendSteer, cx));
    })
    .unwrap();
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
        for action in [
            &NewChat as &dyn Action,
            &Find,
            &EditorTarget,
            &TogglePinned,
            &SendFollowUp,
            &Stop,
            &SessionInspector,
            &Changes,
        ] {
            assert!(!w.is_action_available(action, cx), "{}", action.name());
        }
        assert!(w.is_action_available(&Minimize, cx));
    })
    .unwrap();
    // App-wide commands stay available, as AppKit's own items do.
    assert!(cx.update(|cx| cx.is_action_available(&Quit)));
}

#[::core::prelude::v1::test]
fn in_place_retitles_name_the_titles_the_built_menus_show() {
    for bits in 0..8u8 {
        let state = MenuState {
            archived: bits & 1 != 0,
            pinned: bits & 2 != 0,
            archived_shown: bits & 4 != 0,
            topics: vec![],
        };
        let built = menus(&state);
        for (menu, titles, second) in retitles(&state) {
            let menu = built.iter().find(|m| m.name == menu).unwrap();
            let shown = labels(menu);
            assert!(shown.iter().any(|t| t == titles[usize::from(second)]));
            assert!(!shown.iter().any(|t| t == titles[usize::from(!second)]));
        }
    }
}
