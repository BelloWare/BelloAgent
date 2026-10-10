//! Swift ApplicationMenus.swift, limited to the commands Rust implements.
//! Display-only key bindings let the existing window/editor key path run
//! before AppKit's menu fallback, so menus never steal composer keys.
use crate::{AgentView, RunState, transcript_view::TranscriptView};
use bello_agent_core::session::Lane;
use gpui::{prelude::*, *};

// These are distinct types: GPUI validates availability by action type.
actions!(
    application_menus,
    [
        EditorTarget,
        About,
        Settings,
        NewChat,
        OpenFile,
        ToggleArchived,
        TogglePinned,
        MarkRead,
        MarkUnread,
        CloseWindow,
        Undo,
        Redo,
        Cut,
        Copy,
        Paste,
        SelectAll,
        ToggleArchivedChats,
        SessionInspector,
        Changes,
        NextChat,
        PreviousChat,
        WidenSidebar,
        NarrowSidebar,
        SendFollowUp,
        SendSteer,
        Stop,
        ResumeFollowUps,
        CompactNow,
        LatestMessages,
        Find,
        FindNext,
        FindPrevious,
        SearchConversation,
        Minimize,
        Zoom,
        BringAllToFront,
        Hide,
        HideOthers,
        ShowAll,
        Quit
    ]
);

/// Move to Topic's entries carry their destination; `None` is Project root.
#[derive(Clone, PartialEq, Debug, Action)]
#[action(namespace = application_menus, no_json)]
pub struct MoveToTopic {
    pub topic: Option<String>,
}

/// Swift's WindowChrome.widthStep for Widen/Narrow Sidebar.
pub(crate) const SIDEBAR_STEP: f32 = 24.;

/// What the menus' titles and topic choices read. GPUI menus are static, so a
/// change rebuilds them (Swift retitles its items in menuNeedsUpdate).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct MenuState {
    pub(crate) pinned: bool,
    pub(crate) archived: bool,
    pub(crate) archived_shown: bool,
    pub(crate) topics: Vec<(String, String)>,
}

/// The state the menu bar was last built from (or is about to be).
pub(crate) struct InstalledMenus(pub(crate) MenuState);
impl Global for InstalledMenus {}

pub(crate) fn install(cx: &mut App) {
    // This context is never placed on a view. GPUI still uses these bindings
    // for native key equivalents, without preempting capture_key_down or IME.
    macro_rules! keys {
        ($($key:literal => $action:ident),* $(,)?) => {
            cx.bind_keys([$ (KeyBinding::new($key, $action, Some("BelloMenuEquivalent"))),*]);
        };
    }
    keys!("cmd-," => Settings, "cmd-n" => NewChat, "cmd-p" => OpenFile,
        "cmd-w" => CloseWindow, "cmd-z" => Undo, "cmd-shift-z" => Redo,
        "cmd-x" => Cut, "cmd-c" => Copy, "cmd-v" => Paste, "cmd-a" => SelectAll,
        "cmd-alt-i" => SessionInspector, "cmd-shift-g" => Changes,
        "cmd-alt-down" => NextChat, "cmd-alt-up" => PreviousChat,
        "ctrl-cmd-right" => WidenSidebar, "ctrl-cmd-left" => NarrowSidebar,
        "cmd-enter" => SendSteer, "cmd-." => Stop,
        "cmd-f" => Find, "cmd-g" => FindNext, "cmd-shift-g" => FindPrevious,
        "cmd-alt-f" => SearchConversation, "cmd-m" => Minimize,
        "cmd-h" => Hide, "cmd-alt-h" => HideOthers, "cmd-q" => Quit);
    // An unhandled marker lets the safe focus-specific API query editor
    // context even during the first render (context_stack would panic then).
    // With no listener it always falls through to the editor key handler.
    cx.bind_keys([KeyBinding::new("cmd-a", EditorTarget, Some("BelloEditor"))]);
    cx.on_action(|_: &Hide, cx| cx.hide());
    cx.on_action(|_: &HideOthers, cx| cx.hide_other_apps());
    cx.on_action(|_: &ShowAll, cx| cx.unhide_other_apps());
    cx.on_action(|_: &About, _| native_application("orderFrontStandardAboutPanel:"));
    cx.on_action(|_: &BringAllToFront, _| native_application("arrangeInFront:"));
    // Quit works from any key window and passes the workspace close barrier.
    cx.on_action(|_: &Quit, cx| crate::workspace_lifetime::WorkspaceLifetime::request_quit(cx));
    let state = MenuState::default();
    rebuild(&state, cx);
    cx.set_global(InstalledMenus(state));
}

fn rebuild(state: &MenuState, cx: &mut App) {
    cx.set_menus(menus(state));
    native_system_menus();
}

fn menu(name: &'static str, items: Vec<MenuItem>) -> Menu {
    Menu {
        name: name.into(),
        items,
    }
}
pub(crate) fn menus(state: &MenuState) -> Vec<Menu> {
    let mut topics = vec![MenuItem::action(
        "Project root",
        MoveToTopic { topic: None },
    )];
    topics.extend(state.topics.iter().map(|(id, title)| {
        MenuItem::action(
            title.clone(),
            MoveToTopic {
                topic: Some(id.clone()),
            },
        )
    }));
    vec![
        menu(
            "Bello Agent",
            vec![
                MenuItem::action("About Bello Agent", About),
                MenuItem::separator(),
                MenuItem::action("Settings…", Settings),
                MenuItem::separator(),
                MenuItem::os_submenu("Services", SystemMenuType::Services),
                MenuItem::separator(),
                MenuItem::action("Hide Bello Agent", Hide),
                MenuItem::action("Hide Others", HideOthers),
                MenuItem::action("Show All", ShowAll),
                MenuItem::separator(),
                MenuItem::action("Quit Bello Agent", Quit),
            ],
        ),
        menu(
            "File",
            vec![
                MenuItem::action("New Chat", NewChat),
                MenuItem::action("Open File…", OpenFile),
                MenuItem::separator(),
                MenuItem::action(
                    if state.archived {
                        "Restore Chat"
                    } else {
                        "Archive Chat"
                    },
                    ToggleArchived,
                ),
                MenuItem::action(
                    if state.pinned {
                        "Unpin Chat"
                    } else {
                        "Pin Chat"
                    },
                    TogglePinned,
                ),
                MenuItem::submenu(Menu {
                    name: "Move to Topic".into(),
                    items: topics,
                }),
                MenuItem::action("Mark as Read", MarkRead),
                MenuItem::action("Mark as Unread", MarkUnread),
                MenuItem::separator(),
                MenuItem::action("Close Window", CloseWindow),
            ],
        ),
        // Use GPUI dispatch for all six. The editor has no native NSTextView
        // responder; assigning AppKit cut:/copy: selectors would bypass it.
        menu(
            "Edit",
            vec![
                MenuItem::action("Undo", Undo),
                MenuItem::action("Redo", Redo),
                MenuItem::separator(),
                MenuItem::action("Cut", Cut),
                MenuItem::action("Copy", Copy),
                MenuItem::action("Paste", Paste),
                MenuItem::action("Select All", SelectAll),
            ],
        ),
        menu(
            "View",
            vec![
                MenuItem::action(
                    if state.archived_shown {
                        "Hide Archived Chats"
                    } else {
                        "Show Archived Chats"
                    },
                    ToggleArchivedChats,
                ),
                MenuItem::action("Session Inspector…", SessionInspector),
                MenuItem::action("Changes and History…", Changes),
                MenuItem::separator(),
                MenuItem::action("Next Chat", NextChat),
                MenuItem::action("Previous Chat", PreviousChat),
                MenuItem::separator(),
                MenuItem::action("Widen Sidebar", WidenSidebar),
                MenuItem::action("Narrow Sidebar", NarrowSidebar),
            ],
        ),
        menu(
            "Conversation",
            vec![
                MenuItem::action("Send / Queue Follow-up", SendFollowUp),
                MenuItem::action("Send / Steer Current Run", SendSteer),
                MenuItem::action("Stop", Stop),
                MenuItem::action("Resume Follow-ups", ResumeFollowUps),
                MenuItem::action("Compact Now", CompactNow),
                MenuItem::action("Latest Messages", LatestMessages),
                MenuItem::separator(),
                MenuItem::action("Find…", Find),
                MenuItem::action("Find Next", FindNext),
                MenuItem::action("Find Previous", FindPrevious),
                MenuItem::action("Search and Copy Conversation…", SearchConversation),
            ],
        ),
        menu(
            "Window",
            vec![
                MenuItem::action("Minimize", Minimize),
                MenuItem::action("Zoom", Zoom),
                MenuItem::separator(),
                MenuItem::action("Bring All to Front", BringAllToFront),
            ],
        ),
    ]
}

// Dispatch an ordinary window event, not a direct editor method. No matching
// GPUI binding exists for the display-only menu context, so this cannot recurse.
fn editor_key(key: &str, window: &mut Window, cx: &mut App) {
    let key = Keystroke::parse(key).expect("static menu key");
    // Leave the root action listener borrow before reentering its key capture.
    let focus = window.focused(cx);
    window.defer(cx, move |window, cx| {
        if window.focused(cx) == focus {
            window.dispatch_keystroke(key, cx);
        }
    });
}

type C<'a> = Context<'a, AgentView>;

impl AgentView {
    /// The selected chat's titles and the topic choices, as the menus show them.
    pub(crate) fn menu_state(&self) -> MenuState {
        let record = self.records.iter().find(|r| r.id == self.record.id);
        MenuState {
            pinned: record.is_some_and(|r| r.pinned_at.is_some()),
            archived: record.is_some_and(|r| r.archived_at.is_some()),
            archived_shown: self.effective_archive_visibility(),
            topics: self
                .topics
                .iter()
                .map(|t| (t.id.clone(), t.title.clone()))
                .collect(),
        }
    }
    /// Rebuild the menu bar after a render that changed what it shows. The
    /// rebuild is deferred out of render; a newer state supersedes it.
    pub(crate) fn sync_menus(&self, cx: &mut C) {
        let state = self.menu_state();
        match cx.try_global::<InstalledMenus>() {
            Some(installed) if installed.0 != state => {}
            _ => return,
        }
        cx.global_mut::<InstalledMenus>().0 = state.clone();
        cx.defer(move |cx| {
            if cx.global::<InstalledMenus>().0 == state {
                rebuild(&state, cx);
            }
        });
    }
    /// Swift's typingInATab: keys in a tab's editable text belong to the tab.
    fn typing_in_tab(&self, window: &Window, cx: &App) -> bool {
        self.files
            .iter()
            .any(|f| f.view.read(cx).has_focused_editable_text(window, cx))
            || (self.show_files
                && self.selected_file.is_none()
                && self
                    .workbench
                    .read(cx)
                    .has_focused_editable_text(window, cx))
    }
    fn menu_submit(&mut self, steer: bool, cx: &mut C) {
        if self.composer.read(cx).has_marked_text() {
            return;
        }
        // The composer's own Return path: an edit saves, otherwise send.
        if self.editing.is_some() {
            self.resolve_edit("saved", cx);
        } else if steer && self.session.state == RunState::Running {
            self.submit(Lane::Steering, cx);
        } else {
            self.submit(Lane::FollowUp, cx);
        }
    }
    pub(crate) fn adjust_sidebar(&mut self, delta: f32, cx: &mut C) {
        let width = (self.layout.sidebar + delta).clamp(200., 420.);
        if width != self.layout.sidebar {
            self.layout.sidebar = width;
            self.save_layout(cx);
            cx.notify();
        }
    }
    fn latest_messages(&mut self, cx: &mut C) {
        let Some(transcript) = self.transcript.clone() else {
            return;
        };
        self.abandon_find_navigation();
        transcript.update(cx, |view: &mut TranscriptView, cx| {
            view.cancel_find_navigation(cx);
            view.follow_latest(cx);
        });
    }
    pub(crate) fn menu_actions(&self, mut element: Div, window: &Window, cx: &C) -> Div {
        let modal = self.shutting_down
            || self.close_dialog
            || self.conversation_content.is_some()
            || self.skill_picker.is_some()
            || self.mcp.open
            || self.compaction_menu.is_some()
            || self.topic_panel.is_some()
            || self.connections.open
            || self.connections.picker
            || self.projects.view.read(cx).is_open()
            || self.quick_open.read(cx).is_open();
        let chat = !modal && self.records.iter().any(|r| r.id == self.record.id);
        // Swift's conversationCommandsEnabled, plus Rust's load state.
        let active = chat && !self.loading && !self.load_failed;
        let composer = active && self.record.archived_at.is_none();
        let find = active && !self.typing_in_tab(window, cx);
        let close_prompt = self
            .files
            .iter()
            .any(|entry| entry.view.read(cx).has_close_prompt());
        let editor = window.focused(cx).is_some_and(|focus| {
            window
                .highest_precedence_binding_for_action_in(&EditorTarget, &focus)
                .is_some()
        });
        macro_rules! route {
            ($available:expr, $action:ty, |$v:ident, $a:pat_param, $w:pat_param, $cx:ident| $body:expr) => {
                if $available {
                    element = element.on_action(cx.listener(
                        |$v: &mut AgentView, $a: &$action, $w: &mut Window, $cx: &mut C| {
                            $body;
                        },
                    ));
                }
            };
        }
        route!(
            !modal && !self.known_catalog_uncertainty,
            NewChat,
            |v, _, w, cx| v.new_chat(w, cx)
        );
        route!(!modal, OpenFile, |v, _, w, cx| {
            if v.advance_navigation(cx) {
                v.close_queue_detail(true, w, cx);
                v.quick_open.update(cx, |view, cx| view.show(w, cx));
                cx.notify();
            }
        });
        route!(!modal || self.connections.open, Settings, |v, _, w, cx| v
            .open_connections(w, cx));
        route!(chat, ToggleArchived, |v, _, _, cx| {
            let id = v.record.id.clone();
            let archived = v.chat_is_archived(&id);
            v.set_chat_archived(&id, !archived, cx);
        });
        route!(chat, TogglePinned, |v, _, _, cx| {
            let id = v.record.id.clone();
            let pinned = v
                .records
                .iter()
                .find(|r| r.id == id)
                .map(|r| r.pinned_at.is_some());
            if let Some(pinned) = pinned {
                v.set_chat_pinned(&id, !pinned, cx);
            }
        });
        route!(chat, MoveToTopic, |v, action, _, cx| {
            let id = v.record.id.clone();
            let revision = v
                .records
                .iter()
                .find(|r| r.id == id)
                .map(|r| r.topic_revision);
            if let Some(revision) = revision {
                let topic = action.topic.clone();
                v.apply_topic_action(crate::topics::TopicAction::Move(id, topic, revision), cx);
            }
        });
        route!(chat, MarkRead, |v, _, _, cx| {
            let id = v.record.id.clone();
            v.mark_chat_read_state(&id, false, cx);
        });
        route!(
            chat && self.can_read_action(&self.record.id, true),
            MarkUnread,
            |v, _, _, cx| {
                let id = v.record.id.clone();
                v.mark_chat_read_state(&id, true, cx);
            }
        );
        route!(true, CloseWindow, |v, _, w, cx| {
            if v.request_close(w, cx) {
                w.remove_window();
            }
        });
        route!(!modal, ToggleArchivedChats, |v, _, _, cx| {
            let shown = v.effective_archive_visibility();
            v.set_archive_visibility(!shown, cx);
        });
        route!(chat, SessionInspector, |v, _, w, cx| {
            let target = v.context_inspector_target();
            v.open_context_inspector(&target, w, cx);
        });
        route!(!modal && !close_prompt, Changes, |v, _, _, cx| v
            .open_changes(cx));
        route!(!modal, NextChat, |v, _, w, cx| v
            .select_adjacent_chat(true, w, cx));
        route!(!modal, PreviousChat, |v, _, w, cx| v
            .select_adjacent_chat(false, w, cx));
        route!(true, WidenSidebar, |v, _, _, cx| v
            .adjust_sidebar(SIDEBAR_STEP, cx));
        route!(true, NarrowSidebar, |v, _, _, cx| v
            .adjust_sidebar(-SIDEBAR_STEP, cx));
        route!(composer, SendFollowUp, |v, _, _, cx| v
            .menu_submit(false, cx));
        route!(composer, SendSteer, |v, _, _, cx| v.menu_submit(true, cx));
        route!(active, Stop, |v, _, w, cx| v.stop_from_shortcut(w, cx));
        route!(
            active && crate::queue_actions::offers_resume(&self.chat),
            ResumeFollowUps,
            |v, _, _, cx| {
                let id = v.record.id.clone();
                v.resume_queued(&id, cx);
            }
        );
        route!(active, CompactNow, |v, _, _, cx| v.compact_current(cx));
        route!(active, LatestMessages, |v, _, _, cx| v.latest_messages(cx));
        route!(find, Find, |v, _, w, cx| v.show_transcript_find(w, cx));
        route!(find, FindNext, |v, _, w, cx| {
            if v.transcript_find.is_some() {
                v.step_transcript_find(false, cx);
            } else {
                v.show_transcript_find(w, cx);
            }
        });
        // ⇧⌘G is Changes and History's too: Swift offers Find Previous only
        // while the find bar is open, and the window's key path takes it first.
        route!(
            find && self.transcript_find.is_some(),
            FindPrevious,
            |v, _, _, cx| v.step_transcript_find(true, cx)
        );
        route!(find, SearchConversation, |v, _, w, cx| v
            .open_conversation_content(w, cx));
        macro_rules! edit {
            ($($action:ident => $key:literal),* $(,)?) => {$(
                route!(editor, $action, |_v, _, w, cx| editor_key($key, w, cx));
            )*};
        }
        edit!(Undo => "cmd-z", Redo => "cmd-shift-z", Cut => "cmd-x", Copy => "cmd-c", Paste => "cmd-v", SelectAll => "cmd-a");
        route!(true, Minimize, |_v, _, w, _cx| w.minimize_window());
        route!(true, Zoom, |_v, _, w, _cx| w.zoom_window());
        element
    }
}

#[cfg(all(target_os = "macos", not(test)))]
fn native_application(selector: &str) {
    use cocoa::base::{id, nil};
    use objc::{class, msg_send, runtime::Sel, sel, sel_impl};
    // App menu callbacks run on GPUI's foreground (AppKit main) thread.
    unsafe {
        let app: id = msg_send![class!(NSApplication), sharedApplication];
        let _: () = msg_send![app, performSelector: Sel::register(selector) withObject: nil];
    }
}
#[cfg(any(not(target_os = "macos"), test))]
fn native_application(_: &str) {}

// GPUI 0.2.2 only declares the Services menu and does not assign windowsMenu.
// AppKit expects the actual submenu for both registrations, not its parent item.
// GPUI also has no native name for Return: its "enter" binding would show as
// the literal key equivalent "ENTER", so Send / Steer gets Swift's "\r".
#[cfg(all(target_os = "macos", not(test)))]
fn native_system_menus() {
    use cocoa::{
        base::{id, nil},
        foundation::NSString,
    };
    use objc::{class, msg_send, sel, sel_impl};
    unsafe fn item(menu: id, title: &str) -> id {
        if menu == nil {
            return nil;
        }
        unsafe {
            let title = NSString::alloc(nil).init_str(title);
            let item: id = msg_send![menu, itemWithTitle: title];
            let _: () = msg_send![title, release];
            item
        }
    }
    unsafe fn submenu(menu: id, title: &str) -> id {
        unsafe {
            let item = item(menu, title);
            if item == nil {
                nil
            } else {
                msg_send![item, submenu]
            }
        }
    }
    unsafe {
        let app: id = msg_send![class!(NSApplication), sharedApplication];
        let main: id = msg_send![app, mainMenu];
        if main == nil {
            return;
        }
        let window = submenu(main, "Window");
        if window != nil {
            let _: () = msg_send![app, setWindowsMenu: window];
        }
        let services = submenu(submenu(main, "Bello Agent"), "Services");
        if services != nil {
            let _: () = msg_send![app, setServicesMenu: services];
        }
        let steer = item(submenu(main, "Conversation"), "Send / Steer Current Run");
        if steer != nil {
            let key = NSString::alloc(nil).init_str("\r");
            let _: () = msg_send![steer, setKeyEquivalent: key];
            let _: () = msg_send![key, release];
        }
    }
}
#[cfg(any(not(target_os = "macos"), test))]
fn native_system_menus() {}

#[cfg(test)]
#[path = "application_menus_tests.rs"]
mod tests;
