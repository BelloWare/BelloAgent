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
