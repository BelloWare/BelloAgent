//! All values are fake. No native keychain, credential lookup, or provider use.
use super::{HEADER_BYTES, KEY_BYTES, MASK, MAX_VISIBLE_MASKS, SecureInput, SecureInputEvent};
use bello_workbench_ui::EditorAppearance;
use gpui::{
    ClipboardItem, EntityInputHandler, Focusable, KeyDownEvent, Keystroke, Modifiers,
    TestAppContext, VisualTestContext, WindowHandle, px, size,
};

fn fixture(cx: &mut TestAppContext, limit: usize) -> WindowHandle<SecureInput> {
    let window = cx.add_window(|_, cx| SecureInput::new(limit, EditorAppearance::plain(), cx));
    let visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(380.), px(35.)));
    window
        .update(cx, |input, window, cx| input.focus_handle(cx).focus(window))
        .unwrap();
    cx.run_until_parked();
    window
}
fn key(name: &str, command: bool, shift: bool) -> KeyDownEvent {
    KeyDownEvent {
        keystroke: Keystroke {
            modifiers: Modifiers {
                platform: command,
                shift,
                ..Modifiers::none()
            },
            key: name.into(),
            key_char: None,
        },
        is_held: false,
    }
}

#[::core::prelude::v1::test]
fn utf16_ranges_are_bounded_ordered_and_never_split_scalars() {
    let text = "a🧪日";
    assert_eq!(SecureInput::utf16_range(text, 2..2), Some(1..1));
    assert_eq!(SecureInput::utf16_range(text, 2..3), Some(1..5));
    assert_eq!(
        SecureInput::utf16_range(text, 0..usize::MAX),
        Some(0..text.len())
    );
    assert_eq!(
        SecureInput::utf16_range(text, std::ops::Range { start: 4, end: 1 }),
        None
    );
    assert_eq!(
        SecureInput::utf16_range(text, usize::MAX..usize::MAX),
        Some(text.len()..text.len())
    );
}

#[gpui::test]
fn render_platform_queries_and_debug_only_expose_masks(cx: &mut TestAppContext) {
    let window = fixture(cx, HEADER_BYTES);
    let fake = "{\"X-Fake\":\"fixture-secret-🧪-é\"}";
    window
        .update(cx, |input, _, cx| {
            assert!(input.set_text(fake.into(), cx));
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |input, window, cx| {
            assert_eq!(input.text(), fake);
            let mut actual = None;
            let returned = input
                .text_for_range(0..usize::MAX, &mut actual, window, cx)
                .unwrap();
            assert_eq!(returned, MASK.repeat(fake.encode_utf16().count()));
            assert_eq!(actual, Some(0..fake.encode_utf16().count()));
            assert!(
                input
                    .layout
                    .as_ref()
                    .unwrap()
                    .line
                    .text
                    .chars()
                    .all(|ch| ch == '•')
            );
            let debug = format!("{input:?}");
            assert!(!debug.contains("fixture-secret"));
            assert!(debug.contains("REDACTED"));
        })
        .unwrap();
}

#[gpui::test]
fn copy_cut_undo_and_redo_preserve_clipboard_and_clear_has_no_history(cx: &mut TestAppContext) {
    let window = fixture(cx, KEY_BYTES);
    window
        .update(cx, |input, window, cx| {
            input.set_text("synthetic-project-fixture-only".into(), cx);
            cx.write_to_clipboard(ClipboardItem::new_string(
                "fixture-clipboard-sentinel".into(),
            ));
            input.key(&key("a", true, false), window, cx);
            for action in ["c", "x", "z", "y", "insert"] {
                input.key(&key(action, true, false), window, cx);
                assert_eq!(input.text(), "synthetic-project-fixture-only");
                assert_eq!(
                    cx.read_from_clipboard().unwrap().text().unwrap(),
                    "fixture-clipboard-sentinel"
                );
            }
            input.key(&key("delete", false, true), window, cx);
            assert_eq!(input.text(), "synthetic-project-fixture-only");
            input.key(&key("backspace", false, false), window, cx);
            assert!(input.text().is_empty());
            input.key(&key("z", true, false), window, cx);
            input.key(&key("z", true, true), window, cx);
            assert!(input.text().is_empty());
            assert_eq!(
                cx.read_from_clipboard().unwrap().text().unwrap(),
                "fixture-clipboard-sentinel"
            );
        })
        .unwrap();
}

#[gpui::test]
fn paste_preserves_exact_json_whitespace_and_replaces_selection(cx: &mut TestAppContext) {
    let window = fixture(cx, HEADER_BYTES);
    let fake = "{\n  \"X-Fake\": \"synthetic-header-fixture-only\"\r\n}";
    window
        .update(cx, |input, window, cx| {
            input.set_text("older fake input".into(), cx);
            cx.write_to_clipboard(ClipboardItem::new_string(fake.into()));
            input.key(&key("a", true, false), window, cx);
            input.key(&key("v", true, false), window, cx);
            assert_eq!(input.text(), fake);
            input.key(&key("a", true, false), window, cx);
            cx.write_to_clipboard(ClipboardItem::new_string("{}".into()));
            input.key(&key("insert", false, true), window, cx);
            assert_eq!(input.text(), "{}");
        })
        .unwrap();
}

#[gpui::test]
fn selection_navigation_and_deletion_follow_extended_graphemes(cx: &mut TestAppContext) {
    let window = fixture(cx, KEY_BYTES);
    window
        .update(cx, |input, window, cx| {
            input.set_text("A👨‍👩‍👧‍👦é🇨🇦Z".into(), cx);
            input.key(&key("left", false, false), window, cx);
            input.key(&key("backspace", false, false), window, cx);
            assert_eq!(input.text(), "A👨‍👩‍👧‍👦éZ");
            input.key(&key("left", false, true), window, cx);
            assert_eq!(&input.text()[input.selection.clone()], "é");
            input.replace_text_in_range(None, "x", window, cx);
            assert_eq!(input.text(), "A👨‍👩‍👧‍👦xZ");
            input.key(&key("home", false, false), window, cx);
            input.key(&key("right", false, false), window, cx);
            input.key(&key("delete", false, false), window, cx);
            assert_eq!(input.text(), "AxZ");
            input.key(&key("end", false, true), window, cx);
            assert_eq!(&input.text()[input.selection.clone()], "xZ");
        })
        .unwrap();
}

#[gpui::test]
fn ime_ranges_are_relative_to_inserted_text_and_commits_do_not_duplicate(cx: &mut TestAppContext) {
    let window = fixture(cx, HEADER_BYTES);
    window
        .update(cx, |input, window, cx| {
            input.set_text("abcXYZ".into(), cx);
            input.replace_and_mark_text_in_range(Some(3..6), "a🧪日", Some(1..3), window, cx);
            assert_eq!(input.text(), "abca🧪日");
            assert_eq!(input.marked_text_range(window, cx), Some(3..7));
            assert_eq!(
                input.selected_text_range(false, window, cx).unwrap().range,
                4..6
            );
            assert_eq!(
                input.text_for_range(3..7, &mut None, window, cx),
                Some(MASK.repeat(4))
            );
            // Keyboard deletion, navigation, paste and Settings actions leave marked
            // text with the IME. Clipboard exports remain blocked while composing.
            input.key(&key("backspace", false, false), window, cx);
            assert_eq!(input.text(), "abca🧪日");
            input.replace_text_in_range(None, "確定", window, cx);
            assert_eq!(input.text(), "abc確定");
            assert!(!input.has_marked_text());
            input.replace_and_mark_text_in_range(None, "仮", Some(1..1), window, cx);
            input.replace_text_in_range(None, "", window, cx);
            assert_eq!(input.text(), "abc確定");
            assert!(!input.has_marked_text());
        })
        .unwrap();
}

#[gpui::test]
fn unmark_emits_completion_without_changing_value_or_retaining_composition(
    cx: &mut TestAppContext,
) {
    let window = fixture(cx, KEY_BYTES);
    let input = window.root(cx).unwrap();
    let observed = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let collected = observed.clone();
    let _subscription = cx.update(|cx| {
        cx.subscribe(&input, move |_, event: &SecureInputEvent, _| {
            collected.borrow_mut().push(*event)
        })
    });
    window
        .update(cx, |input, window, cx| {
            input.replace_and_mark_text_in_range(None, "fake-日", None, window, cx);
            input.unmark_text(window, cx);
            input.unmark_text(window, cx);
            assert_eq!(input.text(), "fake-日");
            assert!(!input.has_marked_text());
        })
        .unwrap();
    cx.run_until_parked();
    assert_eq!(
        observed.borrow().as_slice(),
        &[SecureInputEvent::Changed, SecureInputEvent::Changed]
    );
}

#[gpui::test]
fn oversized_replacements_are_atomic_for_each_field_including_composition(cx: &mut TestAppContext) {
    for limit in [KEY_BYTES, HEADER_BYTES] {
        let window = fixture(cx, limit);
        window
            .update(cx, |input, window, cx| {
                input.set_text("a".repeat(limit), cx);
                input.selection = 1..2;
                input.replace_text_in_range(None, "🧪", window, cx);
                assert_eq!(input.text().len(), limit);
                assert_eq!(input.selection, 1..2);
                assert!(input.rejection().is_some());
                input.selection = 0..4;
                input.replace_and_mark_text_in_range(None, "🧪", Some(0..2), window, cx);
                assert_eq!(input.text().len(), limit);
                assert_eq!(input.marked, Some(0..4));
                input.replace_and_mark_text_in_range(None, "🧪x", None, window, cx);
                assert_eq!(input.text().len(), limit);
                assert_eq!(input.marked, Some(0..4));
                assert_eq!(input.selection, 0..4);
                input.replace_text_in_range(None, "", window, cx);
                assert_eq!(input.text().len(), limit - 4);
                assert!(!input.has_marked_text());
                let before = input.text().to_owned();
                assert!(!input.set_text("b".repeat(limit + 1), cx));
                assert_eq!(input.text(), before);
            })
            .unwrap();
    }
}

#[gpui::test]
fn disabled_input_and_malformed_ranges_cannot_mutate(cx: &mut TestAppContext) {
    let window = fixture(cx, KEY_BYTES);
    window
        .update(cx, |input, window, cx| {
            input.set_text("fixture".into(), cx);
            input.replace_text_in_range(
                Some(std::ops::Range { start: 4, end: 1 }),
                "bad",
                window,
                cx,
            );
            input.replace_and_mark_text_in_range(
                Some(std::ops::Range { start: 4, end: 1 }),
                "bad",
                None,
                window,
                cx,
            );
            assert_eq!(input.text(), "fixture");
            input.set_read_only(true, cx);
            input.replace_text_in_range(None, "bad", window, cx);
            input.replace_and_mark_text_in_range(None, "bad", None, window, cx);
            cx.write_to_clipboard(ClipboardItem::new_string("bad".into()));
            input.key(&key("v", true, false), window, cx);
            input.key(&key("a", true, false), window, cx);
            input.key(&key("delete", false, false), window, cx);
            assert_eq!(input.text(), "fixture");
            assert!(!input.has_marked_text());
            assert!(input.selected_text_range(false, window, cx).is_none());
            assert!(input.selected_text_range(true, window, cx).is_some());
            assert_eq!(
                input.text_for_range(0..7, &mut None, window, cx),
                Some(MASK.repeat(7))
            );
        })
        .unwrap();
}

#[gpui::test]
fn large_inputs_shape_only_a_masked_viewport_with_visible_caret(cx: &mut TestAppContext) {
    let window = fixture(cx, HEADER_BYTES);
    window
        .update(cx, |input, _, cx| {
            input.set_text("a".repeat(HEADER_BYTES), cx);
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |input, window, cx| {
            let layout = input.layout.as_ref().unwrap();
            assert!(layout.line.text.len() <= MAX_VISIBLE_MASKS * MASK.len());
            assert!(layout.line.text.chars().all(|ch| ch == '•'));
            assert!(layout.first > 0);
            let bounds = input
                .bounds_for_range(HEADER_BYTES..HEADER_BYTES, layout.bounds, window, cx)
                .unwrap();
            assert!(bounds.left() >= input.layout.as_ref().unwrap().bounds.left());
            assert!(bounds.right() <= input.layout.as_ref().unwrap().bounds.right() + px(2.));
        })
        .unwrap();
}

#[gpui::test]
fn real_input_dispatch_pastes_masks_and_clears(cx: &mut TestAppContext) {
    let window = fixture(cx, KEY_BYTES);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_input("fake-🧪-secret");
    visual.simulate_keystrokes("cmd-a cmd-c");
    cx.run_until_parked();
    window
        .update(cx, |input, _, _| {
            assert_eq!(input.text(), "fake-🧪-secret");
            assert!(
                input
                    .layout
                    .as_ref()
                    .unwrap()
                    .line
                    .text
                    .chars()
                    .all(|ch| ch == '•')
            );
        })
        .unwrap();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_keystrokes("backspace cmd-z");
    cx.run_until_parked();
    window
        .update(cx, |input, _, _| assert!(input.text().is_empty()))
        .unwrap();
}

#[gpui::test]
fn maximum_input_repaints_reuse_boundary_cache_and_keep_shaping_bounded(cx: &mut TestAppContext) {
    let window = fixture(cx, HEADER_BYTES);
    let cache = window
        .update(cx, |input, _, cx| {
            input.set_text("a".repeat(HEADER_BYTES), cx);
            input.boundaries.clone()
        })
        .unwrap();
    for width in [240., 500., 900., 240., 1800., 300., 380.] {
        let visual = VisualTestContext::from_window(window.into(), cx);
        visual.simulate_resize(size(px(width), px(35.)));
        window
            .update(cx, |input, _, cx| {
                assert!(std::rc::Rc::ptr_eq(&input.boundaries, &cache));
                cx.notify();
            })
            .unwrap();
        cx.run_until_parked();
        window
            .update(cx, |input, _, _| {
                assert!(std::rc::Rc::ptr_eq(&input.boundaries, &cache));
                let layout = input.layout.as_ref().unwrap();
                assert!(std::rc::Rc::ptr_eq(&layout.boundaries, &cache));
                assert!(layout.line.text.len() <= MAX_VISIBLE_MASKS * MASK.len());
            })
            .unwrap();
    }
    window
        .update(cx, |input, window, cx| {
            input.key(&key("backspace", false, false), window, cx);
            assert!(!std::rc::Rc::ptr_eq(&input.boundaries, &cache));
        })
        .unwrap();
}
