//! Reading and acting on replies: a reply's text selects as one text across
//! its blocks, copies as Swift copies it, and quotes into the draft.
use super::turn_fold_ui::{bounds, host_rows};
use super::*;

const REPLY: &str = "First paragraph here.\n\n- one item\n- two item\n\n| a | b |\n|---|---|\n| 1 | 2 |";

fn reply_rows() -> Vec<Message> {
    vec![
        message("question", "user", "Explain."),
        message("reply", "assistant", REPLY),
    ]
}

fn clipboard(cx: &TestAppContext) -> Option<String> {
    cx.read(|cx| cx.read_from_clipboard().and_then(|item| item.text()))
}

fn copy(visual: &mut VisualTestContext, cx: &mut TestAppContext) -> Option<String> {
    cx.write_to_clipboard(ClipboardItem::new_string("before".into()));
    visual.dispatch_action(crate::application_menus::Copy);
    cx.run_until_parked();
    clipboard(cx).filter(|text| text != "before")
}

fn element(visual: &mut VisualTestContext, path: &str) -> Bounds<Pixels> {
    bounds(visual, &format!("transcript-text-reply")).unwrap_or_else(|| panic!("{path}"))
}

/// A drag from inside the first paragraph to the table copies what it
/// covers as Swift's text view copies it: blocks a blank line apart, items
/// with their markers, cells split by a tab.
#[gpui::test]
fn a_drag_selects_across_blocks_and_copy_gives_the_text_as_it_reads(cx: &mut TestAppContext) {
    let (_directory, mut visual, _child, _) = host_rows(reply_rows(), RunState::Paused, cx);
    let text = element(&mut visual, "reply");
    // From the paragraph's start to the reply's end.
    let start = point(text.left() + px(1.), text.top() + px(5.));
    let end = point(text.right() - px(2.), text.bottom() - px(2.));
    visual.simulate_mouse_down(start, MouseButton::Left, Modifiers::none());
    visual.simulate_mouse_move(end, Some(MouseButton::Left), Modifiers::none());
    visual.simulate_mouse_up(end, MouseButton::Left, Modifiers::none());
    cx.run_until_parked();
    assert_eq!(
        copy(&mut visual, cx).as_deref(),
        Some("First paragraph here.\n\n- one item\n- two item\n\na\tb\n1\t2")
    );
    // The quote bar stands over the selection.
    assert!(bounds(&mut visual, "quote-in-draft").is_some());
}

#[gpui::test]
fn a_double_click_takes_a_word_and_select_all_the_reply(cx: &mut TestAppContext) {
    let (_directory, mut visual, _child, _) = host_rows(reply_rows(), RunState::Paused, cx);
    let text = element(&mut visual, "reply");
    let at = point(text.left() + px(3.), text.top() + px(8.));
    visual.simulate_event(gpui::MouseDownEvent {
        button: MouseButton::Left,
        position: at,
        modifiers: Modifiers::none(),
        click_count: 2,
        first_mouse: false,
    });
    visual.simulate_mouse_up(at, MouseButton::Left, Modifiers::none());
    cx.run_until_parked();
    assert_eq!(copy(&mut visual, cx).as_deref(), Some("First"));
    visual.dispatch_action(crate::application_menus::SelectAll);
    cx.run_until_parked();
    assert_eq!(
        copy(&mut visual, cx).as_deref(),
        Some("First paragraph here.\n\n- one item\n- two item\n\na\tb\n1\t2")
    );
    // A press outside any text ends the selection.
    let row = bounds(&mut visual, "transcript-row-reply").unwrap();
    visual.simulate_click(point(row.right() - px(4.), row.bottom() - px(2.)), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(copy(&mut visual, cx), None);
}

/// A plain click selects nothing: Copy leaves the clipboard alone and no
/// bar comes up; a message the reader sent selects and copies too.
#[gpui::test]
fn a_click_selects_nothing_and_sent_text_selects(cx: &mut TestAppContext) {
    let (_directory, mut visual, _child, _) = host_rows(reply_rows(), RunState::Paused, cx);
    let text = element(&mut visual, "reply");
    visual.simulate_click(point(text.left() + px(3.), text.top() + px(8.)), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(copy(&mut visual, cx), None);
    assert!(bounds(&mut visual, "quote-in-draft").is_none());
    let sent = bounds(&mut visual, "transcript-text-question").unwrap();
    let start = point(sent.left() + px(1.), sent.top() + px(5.));
    visual.simulate_mouse_down(start, MouseButton::Left, Modifiers::none());
    visual.simulate_mouse_move(
        point(sent.right() + px(20.), sent.top() + px(5.)),
        Some(MouseButton::Left),
        Modifiers::none(),
    );
    visual.simulate_mouse_up(
        point(sent.right() + px(20.), sent.top() + px(5.)),
        MouseButton::Left,
        Modifiers::none(),
    );
    cx.run_until_parked();
    assert_eq!(copy(&mut visual, cx).as_deref(), Some("Explain."));
    // Only a reply can be quoted.
    assert!(bounds(&mut visual, "quote-in-draft").is_none());
}

/// The bar quotes the selection below the draft, each line after "> ", as
/// Swift quotes it into a side's draft; Return does what the bar does.
#[gpui::test]
fn the_quote_bar_quotes_the_selection_into_the_draft(cx: &mut TestAppContext) {
    let (_directory, _window, root) = fixture(cx, messages(1), 0);
    let mut changed = input(&root, cx);
    let mut session = (*changed.session).clone();
    session.messages = reply_rows();
    changed.session = Arc::new(session);
    changed.visible_messages = usize::MAX;
    let (mut visual, child) = host(&root, changed, cx);
    root.update(cx, |view, cx| {
        view.composer
            .update(cx, |editor, cx| editor.set_text("Draft".into(), cx))
    });
    let text = element(&mut visual, "reply");
    let start = point(text.left() + px(1.), text.top() + px(5.));
    let end = point(text.left() + px(60.), text.top() + px(30.));
    visual.simulate_mouse_down(start, MouseButton::Left, Modifiers::none());
    visual.simulate_mouse_move(end, Some(MouseButton::Left), Modifiers::none());
    visual.simulate_mouse_up(end, MouseButton::Left, Modifiers::none());
    cx.run_until_parked();
    let selected = copy(&mut visual, cx).expect("a selection");
    assert!(selected.starts_with("First paragraph here.\n\n- "), "{selected:?}");
    let bar = bounds(&mut visual, "quote-in-draft").expect("the quote bar");
    // Above the selection's first line, inside the transcript.
    assert!(bar.bottom() <= text.top() + px(1.) || bar.top() >= text.top());
    visual.simulate_click(bar.center(), Modifiers::none());
    cx.run_until_parked();
    let quoted = selected
        .split('\n')
        .map(|line| format!("> {line}"))
        .collect::<Vec<_>>()
        .join("\n");
    assert_eq!(
        cx.read(|cx| root.read(cx).composer.read(cx).text().to_owned()),
        format!("Draft\n\n{quoted}\n\n")
    );
    // The bar is gone, and the draft has the focus.
    assert!(!cx.read(|cx| child.read(cx).quote_bar_up()));
}

/// A code span naming a file of the project is a link that opens the file
/// in a tab at its line; one naming a file outside the project is not.
#[gpui::test]
fn a_code_span_that_names_a_project_file_opens_it(cx: &mut TestAppContext) {
    let (directory, _window, root) = fixture(cx, messages(1), 0);
    let project = std::fs::canonicalize(directory.path()).unwrap();
    std::fs::create_dir_all(project.join("src")).unwrap();
    std::fs::write(project.join("src/lib.rs"), "one\ntwo\nthree\n").unwrap();
    let outside = tempfile::tempdir().unwrap();
    let secret = std::fs::canonicalize(outside.path()).unwrap().join("secret.txt");
    std::fs::write(&secret, "x").unwrap();
    let mut changed = input(&root, cx);
    let mut session = (*changed.session).clone();
    session.messages = vec![
        message("question", "user", "Where?"),
        message(
            "reply",
            "assistant",
            &format!("Open `src/lib.rs:2` or `{}`", secret.display()),
        ),
    ];
    changed.session = Arc::new(session);
    changed.visible_messages = usize::MAX;
    let (mut visual, _child) = host(&root, changed, cx);
    cx.run_until_parked();
    let width = |text: &str, size: f32, visual: &mut VisualTestContext| {
        visual.update(|window, _| {
            let run = gpui::TextRun {
                len: text.len(),
                font: gpui::font(".SystemUIFont"),
                color: gpui::black(),
                background_color: None,
                underline: None,
                strikethrough: None,
            };
            window
                .text_system()
                .shape_line(text.to_owned().into(), px(size), &[run], None)
                .width
        })
    };
    let into = width("Open ", 14.5, &mut visual) + width("sr", 13.05, &mut visual);
    let opened = |cx: &TestAppContext| {
        cx.read(|cx| {
            root.read(cx)
                .files
                .iter()
                .map(|entry| entry.path.clone())
                .collect::<Vec<_>>()
        })
    };
    let text = bounds(&mut visual, "transcript-text-reply").unwrap();
    let not = width("Open ", 14.5, &mut visual)
        + width("src/lib.rs:2", 13.05, &mut visual)
        + width(" or ", 14.5, &mut visual)
        + width("/v", 13.05, &mut visual);
    visual.simulate_click(point(text.left() + not, text.top() + px(9.)), Modifiers::none());
    cx.run_until_parked();
    assert!(opened(cx).is_empty());
    visual.simulate_click(point(text.left() + into, text.top() + px(9.)), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(opened(cx), vec![project.join("src/lib.rs")]);
}

/// A settled reply's headings each copy their section, and its words copy
/// it whole from the Copy over their top corner, as the author wrote them.
#[gpui::test]
fn headings_and_the_reply_copy_their_markdown(cx: &mut TestAppContext) {
    let source = "Intro **bold**.\n\n# One\nfirst `x`\n## Two\nsecond\n# Three\nthird";
    let (_directory, mut visual, _child, _) = host_rows(
        vec![
            message("question", "user", "Explain."),
            message("reply", "assistant", source),
        ],
        RunState::Paused,
        cx,
    );
    let text = element(&mut visual, "reply");
    let press = |heading: usize, visual: &mut VisualTestContext, cx: &mut TestAppContext| {
        let line = bounds(visual, &format!("heading-transcript-row-reply.{heading}")).unwrap();
        visual.simulate_mouse_move(line.center(), None, Modifiers::none());
        cx.run_until_parked();
        let button = bounds(visual, &format!("heading-copy-transcript-row-reply.{heading}"))
            .expect("the heading's copy");
        // 30 points past the prose's 640, its 64 points before that.
        assert_eq!(button.left() - text.left(), px(640. + 30. - 64.));
        visual.simulate_mouse_move(button.center(), None, Modifiers::none());
        visual.simulate_click(button.center(), Modifiers::none());
        cx.run_until_parked();
        clipboard(cx)
    };
    assert_eq!(press(3, &mut visual, cx).as_deref(), Some("## Two\nsecond\n"));
    assert_eq!(
        press(1, &mut visual, cx).as_deref(),
        Some("# One\nfirst `x`\n## Two\nsecond\n")
    );
    visual.simulate_mouse_move(text.center(), None, Modifiers::none());
    cx.run_until_parked();
    let corner = bounds(&mut visual, "reply-copy-transcript-row-reply").unwrap();
    assert_eq!(corner.right(), text.right());
    assert_eq!(corner.top(), text.top() - px(3.));
    visual.simulate_mouse_move(corner.center(), None, Modifiers::none());
    visual.simulate_click(corner.center(), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(clipboard(cx).as_deref(), Some("Intro **bold**.\n\n"));
}

/// A large table's preview offers its whole table in a window: the grid,
/// the chosen cell's text and the TSV copy.
#[gpui::test]
fn open_full_table_shows_every_row(cx: &mut TestAppContext) {
    let rows: String = (0..45).map(|row| format!("| {row} | value {row} |\n")).collect();
    let (_directory, mut visual, _child, _) = host_rows(
        vec![
            message("question", "user", "Table?"),
            message("reply", "assistant", &format!("| n | v |\n|---|---|\n{rows}")),
        ],
        RunState::Paused,
        cx,
    );
    let open = bounds(&mut visual, "open-full-table-transcript-row-reply.0").expect("the control");
    let text = element(&mut visual, "reply");
    assert_eq!(open.right(), text.left() + px(640.));
    let before = cx.windows().len();
    visual.simulate_click(open.center(), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(cx.windows().len(), before + 1);
    let table = cx
        .windows()
        .into_iter()
        .find_map(|window| window.downcast::<crate::transcript_view::table_window::TableWindow>())
        .expect("the table window");
    let mut window = VisualTestContext::from_window(table.into(), cx);
    window.simulate_resize(size(px(880.), px(600.)));
    cx.run_until_parked();
    assert_eq!(
        cx.read(|cx| table.read(cx).unwrap().detail_text(cx)),
        crate::transcript_view::table_window::PLACEHOLDER
    );
    let row = bounds(&mut window, "markdown-table-row-2").expect("a row");
    window.simulate_click(point(row.left() + px(140.), row.center().y), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(cx.read(|cx| table.read(cx).unwrap().detail_text(cx)), "value 2");
    let copy = bounds(&mut window, "table-window-copy").unwrap();
    window.simulate_click(copy.center(), Modifiers::none());
    cx.run_until_parked();
    let tsv = clipboard(cx).unwrap();
    assert!(tsv.starts_with("n\tv\n0\tvalue 0\n"), "{tsv:?}");
    assert!(tsv.ends_with("44\tvalue 44"), "{tsv:?}");
}

/// While a reply is being written its caret follows its last paragraph or
/// heading; after a fence, a list or a table it shows nowhere.
#[::core::prelude::v1::test]
fn the_caret_follows_a_last_paragraph_or_heading() {
    use crate::transcript_view::caret_path_for_test as path;
    assert_eq!(path("one\n\ntwo").as_deref(), Some(".1"));
    assert_eq!(path("# Title").as_deref(), Some(".0"));
    assert_eq!(path("text\n\n```\ncode"), None);
    assert_eq!(path("- item"), None);
    assert_eq!(path(""), None);
}

#[gpui::test]
fn a_streaming_reply_draws_and_settles(cx: &mut TestAppContext) {
    let mut reply = message("reply", "assistant", "Still writing this");
    reply.state = "streaming".into();
    let (_directory, mut visual, _child, _) = host_rows(
        vec![message("question", "user", "Go."), reply],
        RunState::Running,
        cx,
    );
    let before = element(&mut visual, "reply");
    // Blinking asks for frames, and changes no layout.
    cx.executor().advance_clock(std::time::Duration::from_millis(1_600));
    cx.run_until_parked();
    assert_eq!(element(&mut visual, "reply"), before);
}
