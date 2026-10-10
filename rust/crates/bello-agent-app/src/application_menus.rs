//! Swift ApplicationMenus.swift's implemented subset. Display-only key bindings
//! let the existing window/editor key path run before AppKit's menu fallback.
use crate::AgentView;
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
        CloseWindow,
        Undo,
        Redo,
        Cut,
        Copy,
        Paste,
        SelectAll,
        Changes,
        NextChat,
        PreviousChat,
        Find,
        FindNext,
        FindPrevious,
        Minimize,
        Zoom,
        BringAllToFront,
        Hide,
        HideOthers,
        ShowAll,
        Quit
    ]
);

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
        "cmd-shift-g" => Changes, "cmd-alt-down" => NextChat,
        "cmd-alt-up" => PreviousChat, "cmd-f" => Find, "cmd-g" => FindNext,
        "cmd-shift-g" => FindPrevious, "cmd-m" => Minimize,
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
    cx.set_menus(menus());
}

fn menu(name: &'static str, items: Vec<MenuItem>) -> Menu {
    Menu {
        name: name.into(),
        items,
    }
}
fn menus() -> Vec<Menu> {
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
                MenuItem::action("Changes and History…", Changes),
                MenuItem::separator(),
                MenuItem::action("Next Chat", NextChat),
                MenuItem::action("Previous Chat", PreviousChat),
            ],
        ),
        menu(
            "Conversation",
            vec![
                MenuItem::action("Find…", Find),
                MenuItem::action("Find Next", FindNext),
                MenuItem::action("Find Previous", FindPrevious),
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

impl AgentView {
    pub(crate) fn menu_actions(
        &self,
        mut element: Div,
        window: &Window,
        cx: &Context<Self>,
    ) -> Div {
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
        let conversation = !modal
            && !self.show_files
            && !self.changes_open
            && !self.loading
            && !self.load_failed
            && self.record.archived_at.is_none();
        let editor = window.focused(cx).is_some_and(|focus| {
            window
                .highest_precedence_binding_for_action_in(&EditorTarget, &focus)
                .is_some()
        });
        macro_rules! route {
            ($available:expr, $action:ident, $body:expr) => {
                if $available {
                    element = element.on_action(cx.listener(|view, _: &$action, window, cx| {
                        ($body)(view, window, cx);
                    }));
                }
            };
        }
        route!(
            !modal && !self.known_catalog_uncertainty,
            NewChat,
            |v: &mut Self, w: &mut Window, cx: &mut Context<Self>| v.new_chat(w, cx)
        );
        route!(
            !modal,
            OpenFile,
            |v: &mut Self, w: &mut Window, cx: &mut Context<Self>| {
                if v.advance_navigation(cx) {
                    v.close_queue_detail(true, w, cx);
                    v.quick_open.update(cx, |view, cx| view.show(w, cx));
                    cx.notify();
                }
            }
        );
        route!(
            !modal || self.connections.open,
            Settings,
            |v: &mut Self, w: &mut Window, cx: &mut Context<Self>| v.open_connections(w, cx)
        );
        route!(
            true,
            CloseWindow,
            |v: &mut Self, w: &mut Window, cx: &mut Context<Self>| {
                if v.request_close(w, cx) {
                    w.remove_window();
                }
            }
        );
        // Quit uses the same dirty-buffer/running-chat shutdown barrier as close.
        // The existing last-window callback quits after that barrier settles.
        route!(
            true,
            Quit,
            |v: &mut Self, w: &mut Window, cx: &mut Context<Self>| {
                if v.request_close(w, cx) {
                    cx.quit();
                }
            }
        );
        route!(
            !modal,
            Changes,
            |v: &mut Self, _: &mut Window, cx: &mut Context<Self>| v.open_changes(cx)
        );
        route!(
            !modal,
            NextChat,
            |v: &mut Self, w: &mut Window, cx: &mut Context<Self>| v
                .select_adjacent_chat(true, w, cx)
        );
        route!(
            !modal,
            PreviousChat,
            |v: &mut Self, w: &mut Window, cx: &mut Context<Self>| v
                .select_adjacent_chat(false, w, cx)
        );
        route!(
            conversation,
            Find,
            |v: &mut Self, w: &mut Window, cx: &mut Context<Self>| v.show_transcript_find(w, cx)
        );
        route!(
            conversation && self.transcript_find.is_some(),
            FindNext,
            |v: &mut Self, _: &mut Window, cx: &mut Context<Self>| v
                .step_transcript_find(false, cx)
        );
        route!(
            conversation && self.transcript_find.is_some(),
            FindPrevious,
            |v: &mut Self, _: &mut Window, cx: &mut Context<Self>| v.step_transcript_find(true, cx)
        );
        macro_rules! edit {
            ($($action:ident => $key:literal),* $(,)?) => {$(
                route!(editor, $action, |_: &mut Self, w: &mut Window, cx: &mut Context<Self>| editor_key($key, w, cx));
            )*};
        }
        edit!(Undo => "cmd-z", Redo => "cmd-shift-z", Cut => "cmd-x", Copy => "cmd-c", Paste => "cmd-v", SelectAll => "cmd-a");
        route!(
            true,
            Minimize,
            |_: &mut Self, w: &mut Window, _: &mut Context<Self>| w.minimize_window()
        );
        route!(
            true,
            Zoom,
            |_: &mut Self, w: &mut Window, _: &mut Context<Self>| w.zoom_window()
        );
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

#[cfg(test)]
#[path = "application_menus_tests.rs"]
mod tests;
