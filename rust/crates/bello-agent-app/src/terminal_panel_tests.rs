//! The terminal panel in a window, as Swift's TerminalPanelView behaves: ⌃`,
//! the View menu and the starter's Terminal button show it between the queue
//! and the composer; keys reach a real `/bin/sh` (never the user's shell) in
//! the fixture's temporary project; tabs, New, Rename, Restart, Close, Hide,
//! the resize line, copy, paste and the scrollback work; closing the window
//! leaves no shell behind.
use super::*;
use crate::AgentView;
use crate::application_menus::ToggleTerminal;
use crate::transcript_view_tests::fixture_with;
use ::core::prelude::v1::test;
use gpui::{TestAppContext, VisualTestContext, WindowHandle};
use std::time::{Duration, Instant};

fn panel(view: &Entity<AgentView>, cx: &TestAppContext) -> Entity<TerminalPanel> {
    cx.read(|cx| view.read(cx).terminal.panel.clone())
}
fn screen(panel: &Entity<TerminalPanel>, cx: &TestAppContext) -> String {
    cx.read(|cx| {
        let panel = panel.read(cx);
        let Some(session) = panel.selected_session() else {
            return String::new();
        };
        let e = &session.emulator;
        (0..e.line_count())
            .map(|i| e.text_at_line(i))
            .collect::<Vec<_>>()
            .join("\n")
    })
}
/// Runs the app and real time until `done` holds (a shell answers on its own threads).
fn wait(cx: &mut TestAppContext, what: &str, mut done: impl FnMut(&mut TestAppContext) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        cx.run_until_parked();
        if done(cx) {
            return;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn wait_screen(cx: &mut TestAppContext, panel: &Entity<TerminalPanel>, text: &str) {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        cx.run_until_parked();
        let shown = screen(panel, cx);
        // od pads its columns differently on macOS and Linux.
        let words = shown
            .split(' ')
            .filter(|w| !w.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        if shown.contains(text) || words.contains(text) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {text:?} in:\n{shown}"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn pid(panel: &Entity<TerminalPanel>, cx: &TestAppContext) -> libc::pid_t {
    cx.read(|cx| {
        panel
            .read(cx)
            .selected_session()
            .and_then(|s| s.process.as_ref())
            .map(|p| p.process_id())
            .unwrap()
    })
}
fn alive(pid: libc::pid_t) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}
fn centre(bounds: Bounds<Pixels>) -> Point<Pixels> {
    bounds.center()
}
fn open(
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    WindowHandle<AgentView>,
    Entity<AgentView>,
    Entity<TerminalPanel>,
) {
    let (dir, window, view) = fixture_with(cx, Vec::new(), 0, None, false);
    let panel = panel(&view, cx);
    window
        .update(cx, |view, window, cx| view.toggle_terminal(window, cx))
        .unwrap();
    wait_screen(cx, &panel, "$");
    (dir, window, view, panel)
}
fn typed(cx: &mut TestAppContext, window: WindowHandle<AgentView>, text: &str) {
    cx.simulate_input(window.into(), text);
}

#[gpui::test]
fn control_backtick_the_menu_and_the_starter_show_and_hide_it(cx: &mut TestAppContext) {
    let (_dir, window, view) = fixture_with(cx, Vec::new(), 0, None, false);
    let panel = panel(&view, cx);
    assert!(!cx.read(|cx| view.read(cx).terminal.visible));
    cx.simulate_keystrokes(window.into(), "ctrl-`");
    assert!(cx.read(|cx| view.read(cx).terminal.visible));
    assert!(cx.read(|cx| view.read(cx).menu_state().terminal_visible));
    wait_screen(cx, &panel, "$");
    assert_eq!(cx.read(|cx| panel.read(cx).sessions().len()), 1);
    // The shell has the keyboard.
    assert!(cx.update(|cx| {
        window
            .update(cx, |_, window, cx| panel.read(cx).focus.is_focused(window))
            .unwrap()
    }));
    cx.simulate_keystrokes(window.into(), "ctrl-`");
    assert!(!cx.read(|cx| view.read(cx).terminal.visible));
    // Hidden, the composer takes the keyboard back and the shell keeps running.
    let shell = pid(&panel, cx);
    assert!(alive(shell));
    assert!(cx.update(|cx| {
        window
            .update(cx, |view, window, cx| {
                view.composer.read(cx).focus_handle(cx).is_focused(window)
            })
            .unwrap()
    }));
    // The View menu's Show Terminal.
    window
        .update(cx, |_, window, cx| {
            window.dispatch_action(Box::new(ToggleTerminal), cx)
        })
        .unwrap();
    cx.run_until_parked();
    assert!(cx.read(|cx| view.read(cx).terminal.visible));
    assert_eq!(pid(&panel, cx), shell, "the same shell comes back");
    cx.simulate_keystrokes(window.into(), "ctrl-`");
    // The starter's Terminal button.
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let button = visual
        .debug_bounds("starter-terminal")
        .expect("starter button");
    visual.simulate_click(centre(button), Modifiers::none());
    assert!(cx.read(|cx| view.read(cx).terminal.visible));
}

#[gpui::test]
fn the_panel_sits_between_the_transcript_and_the_composer(cx: &mut TestAppContext) {
    let (_dir, window, view, panel) = open(cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let slot = visual.debug_bounds("terminal-slot").unwrap();
    let composer = visual.debug_bounds("queue-measured-composer").unwrap();
    let header = visual.debug_bounds("terminal-header").unwrap();
    let grid = visual.debug_bounds("terminal-grid").unwrap();
    // Its ideal height when the pane has the room: chrome and 240 points.
    assert_eq!(f32::from(slot.size.height), CHROME_HEIGHT + DEFAULT_HEIGHT);
    assert_eq!(f32::from(header.size.height), CHROME_HEIGHT - 1.);
    assert_eq!(header.top(), slot.top() + px(1.));
    assert_eq!(grid.top(), header.bottom());
    assert_eq!(grid.bottom(), slot.bottom());
    assert_eq!(
        composer.top(),
        slot.bottom() + px(crate::queue_geometry::COMPOSER_TOP)
    );
    // The queue's room reserves the terminal; the composer field's ceiling drops.
    cx.read(|cx| {
        let view = view.read(cx);
        assert!(view.queue_geometry.unwrap().terminal);
        assert_eq!(view.composer_ceiling(), COMPOSER_BESIDE_TERMINAL);
    });
    // The grid fills the body at the measured cell.
    let (columns, rows, metrics) = cx.read(|cx| {
        let panel = panel.read(cx);
        let e = &panel.selected_session().unwrap().emulator;
        (e.columns(), e.rows(), panel.metrics.unwrap())
    });
    assert_eq!(
        metrics.grid(f32::from(grid.size.width), f32::from(grid.size.height)),
        Some((columns, rows))
    );
    // A short window: the terminal gives way down to its minimum, and the
    // transcript keeps the rest.
    visual.simulate_resize(size(px(1180.), px(520.)));
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let slot = visual.debug_bounds("terminal-slot").unwrap();
    let height = f32::from(slot.size.height);
    assert!(
        (CHROME_HEIGHT + MINIMUM_HEIGHT..CHROME_HEIGHT + DEFAULT_HEIGHT).contains(&height),
        "{height}"
    );
}

#[gpui::test]
fn keys_reach_the_shell_in_the_project_folder(cx: &mut TestAppContext) {
    let (dir, window, _view, panel) = open(cx);
    typed(cx, window, "pwd -P");
    cx.simulate_keystrokes(window.into(), "enter");
    let project = std::fs::canonicalize(dir.path()).unwrap();
    wait_screen(cx, &panel, &project.display().to_string());
    // A program that reads raw keys sees the arrow's sequence and ^C.
    typed(
        cx,
        window,
        "stty raw -echo; dd bs=1 count=4 2>/dev/null | od -An -tx1; stty sane",
    );
    cx.simulate_keystrokes(window.into(), "enter");
    std::thread::sleep(Duration::from_millis(200));
    cx.simulate_keystrokes(window.into(), "up ctrl-c");
    wait_screen(cx, &panel, "1b 5b 41 03");
    // Option sends ESC first; Tab and Backspace their own bytes.
    typed(
        cx,
        window,
        "stty raw -echo; dd bs=1 count=4 2>/dev/null | od -An -tx1; stty sane",
    );
    cx.simulate_keystrokes(window.into(), "enter");
    std::thread::sleep(Duration::from_millis(200));
    cx.simulate_keystrokes(window.into(), "alt-b tab backspace");
    wait_screen(cx, &panel, "1b 62 09 7f");
}

#[gpui::test]
fn tabs_new_rename_restart_and_close_follow_swift(cx: &mut TestAppContext) {
    let (dir, window, _view, panel) = open(cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("terminal-tab-Terminal 1").is_some());
    // New: Terminal 2, shown at once.
    let new = visual.debug_bounds("terminal-new").unwrap();
    visual.simulate_click(centre(new), Modifiers::none());
    cx.run_until_parked();
    let names = |cx: &TestAppContext| {
        cx.read(|cx| {
            panel
                .read(cx)
                .sessions()
                .iter()
                .map(|s| s.display_name())
                .collect::<Vec<_>>()
        })
    };
    assert_eq!(names(cx), ["Terminal 1", "Terminal 2"]);
    let selected =
        |cx: &TestAppContext| cx.read(|cx| panel.read(cx).selected_session().unwrap().number);
    assert_eq!(selected(cx), 2);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let first = visual.debug_bounds("terminal-tab-Terminal 1").unwrap();
    visual.simulate_click(centre(first), Modifiers::none());
    assert_eq!(selected(cx), 1);

    // Rename: the name, trimmed; empty gives the number back.
    let rename = visual.debug_bounds("terminal-rename").unwrap();
    visual.simulate_click(centre(rename), Modifiers::none());
    let title = cx.read(|cx| {
        panel
            .read(cx)
            .question
            .as_ref()
            .map(|q| (q.title.clone(), q.detail.clone()))
    });
    assert_eq!(
        title,
        Some((
            "Rename “Terminal 1”".into(),
            "Up to 64 characters. Leave it empty for “Terminal 1”.".into()
        ))
    );
    assert!(cx.read(|cx| view_asking(&_view, cx)));
    typed(cx, window, "  logs  ");
    cx.simulate_keystrokes(window.into(), "enter");
    assert!(cx.read(|cx| panel.read(cx).question.is_none()));
    assert_eq!(names(cx), ["logs", "Terminal 2"]);

    // Restart of a live shell asks first; Escape (and Return) cancel.
    let old = pid(&panel, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let restart = visual.debug_bounds("terminal-restart").unwrap();
    visual.simulate_click(centre(restart), Modifiers::none());
    let project = dir
        .path()
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let asked = cx.read(|cx| {
        panel
            .read(cx)
            .question
            .as_ref()
            .map(|q| (q.title.clone(), q.action))
    });
    assert_eq!(
        asked,
        Some((
            format!("Restart “logs” in “{project}”?"),
            "Restart Terminal"
        ))
    );
    cx.simulate_keystrokes(window.into(), "escape");
    assert!(cx.read(|cx| panel.read(cx).question.is_none()));
    visual.simulate_click(centre(restart), Modifiers::none());
    cx.simulate_keystrokes(window.into(), "enter");
    assert!(cx.read(|cx| panel.read(cx).question.is_none()));
    assert_eq!(pid(&panel, cx), old, "Return is Cancel");
    visual.simulate_click(centre(restart), Modifiers::none());
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let go = visual.debug_bounds("terminal-question-action").unwrap();
    visual.simulate_click(centre(go), Modifiers::none());
    wait_screen(cx, &panel, "$");
    let fresh = pid(&panel, cx);
    assert_ne!(fresh, old);
    let (name, generation, number) = cx.read(|cx| {
        let s = panel.read(cx).selected_session().unwrap();
        (s.display_name(), s.generation, s.number)
    });
    assert_eq!((name.as_str(), generation, number), ("logs", 1, 1));
    wait(cx, "the old shell to end", |_| !alive(old));

    // An exited shell closes without asking; the one after it is shown.
    typed(cx, window, "exit");
    cx.simulate_keystrokes(window.into(), "enter");
    let p = panel.clone();
    wait(cx, "the shell to exit", |cx| {
        cx.read(|cx| p.read(cx).selected_session().unwrap().exited)
    });
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("terminal-badge").is_some());
    let close = visual.debug_bounds("terminal-close").unwrap();
    visual.simulate_click(centre(close), Modifiers::none());
    assert!(cx.read(|cx| panel.read(cx).question.is_none()));
    assert_eq!(names(cx), ["Terminal 2"]);
    assert_eq!(selected(cx), 2);
}

fn view_asking(view: &Entity<AgentView>, cx: &App) -> bool {
    view.read(cx).terminal_asking(cx)
}

#[gpui::test]
fn closing_every_terminal_leaves_the_empty_state(cx: &mut TestAppContext) {
    let (_dir, window, _view, panel) = open(cx);
    let shell = pid(&panel, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let close = visual.debug_bounds("terminal-close").unwrap();
    visual.simulate_click(centre(close), Modifiers::none());
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let go = visual.debug_bounds("terminal-question-action").unwrap();
    visual.simulate_click(centre(go), Modifiers::none());
    cx.run_until_parked();
    assert!(cx.read(|cx| panel.read(cx).sessions().is_empty()));
    wait(cx, "the shell to end", |_| !alive(shell));
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let new = visual.debug_bounds("terminal-empty-new").unwrap();
    visual.simulate_click(centre(new), Modifiers::none());
    wait_screen(cx, &panel, "$");
    assert_eq!(
        cx.read(|cx| panel.read(cx).selected_session().unwrap().number),
        2
    );
}

#[gpui::test]
fn the_resize_line_drags_and_is_remembered(cx: &mut TestAppContext) {
    let (dir, window, _view, panel) = open(cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let handle = visual.debug_bounds("terminal-resize").unwrap();
    assert_eq!(f32::from(handle.size.height), 9.);
    let start = centre(handle);
    visual.simulate_mouse_down(start, MouseButton::Left, Modifiers::none());
    visual.simulate_mouse_move(
        start - point(px(0.), px(100.)),
        MouseButton::Left,
        Modifiers::none(),
    );
    assert_eq!(
        cx.read(|cx| panel.read(cx).terminal_height()),
        DEFAULT_HEIGHT + 100.
    );
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_mouse_up(
        start - point(px(0.), px(100.)),
        MouseButton::Left,
        Modifiers::none(),
    );
    cx.run_until_parked();
    assert_eq!(
        cx.read(|cx| panel.read(cx).terminal_height()),
        DEFAULT_HEIGHT + 100.
    );
    let path = dir.path().join("terminal.json");
    wait(cx, "the height to be saved", |_| {
        std::fs::read_to_string(&path).is_ok_and(|text| text.contains("340"))
    });
    // Clamped to Swift's 120...700.
    assert_eq!(clamp_height(10.), MINIMUM_HEIGHT);
    assert_eq!(clamp_height(9_000.), MAXIMUM_HEIGHT);
    assert_eq!(clamp_height(f32::NAN), DEFAULT_HEIGHT);
}

#[gpui::test]
fn copy_paste_and_the_scrollback(cx: &mut TestAppContext) {
    let (_dir, window, _view, panel) = open(cx);
    typed(
        cx,
        window,
        "i=0; while [ $i -lt 80 ]; do echo row$i; i=$((i+1)); done",
    );
    cx.simulate_keystrokes(window.into(), "enter");
    wait_screen(cx, &panel, "row79");
    // The wheel reads back; typing returns to the newest output.
    window
        .update(cx, |_, _, cx| {
            panel.update(cx, |panel, cx| {
                panel.scrolled(ScrollDelta::Lines(point(0., 2.)), cx)
            })
        })
        .unwrap();
    assert_eq!(cx.read(|cx| panel.read(cx).scrolled_back()), 6);
    let modifier = if cfg!(target_os = "macos") {
        "cmd"
    } else {
        "ctrl-shift"
    };
    cx.simulate_keystrokes(window.into(), &format!("{modifier}-a {modifier}-c"));
    let copied = cx
        .read_from_clipboard()
        .and_then(|item| item.text())
        .unwrap();
    assert!(copied.contains("row0\nrow1\n"), "{copied}");
    assert!(!copied.ends_with(' '));
    // A paste is one write, with line ends as Return.
    cx.write_to_clipboard(ClipboardItem::new_string("echo pas\nted".into()));
    cx.simulate_keystrokes(window.into(), &format!("{modifier}-v"));
    assert_eq!(cx.read(|cx| panel.read(cx).scrolled_back()), 0);
    wait_screen(cx, &panel, "pas");
}

#[gpui::test]
fn closing_the_window_ends_its_shells(cx: &mut TestAppContext) {
    let (_dir, window, _view, panel) = open(cx);
    let shell = pid(&panel, cx);
    drop(panel);
    drop(_view);
    window
        .update(cx, |_, window, _| window.remove_window())
        .unwrap();
    wait(cx, "the shell to end with its window", |_| !alive(shell));
}
