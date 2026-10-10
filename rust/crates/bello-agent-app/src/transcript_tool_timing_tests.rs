//! Synthetic timing-only redraws preserve the existing retained UI state.
use super::*;
use bello_agent_core::{tool_history::ToolRecord, tool_timing::DurationUs};

#[gpui::test]
fn duration_only_redraw_preserves_selection_expansion_and_scroll(cx: &mut TestAppContext) {
    crate::transcript_view::open_tool_rows_for_test();
    let (_directory, _window, root) = fixture(cx, messages(1), 0);
    let mut changed = input(&root, cx);
    let mut session = (*changed.session).clone();
    session.messages = retained_tool_rows(30, "retained timing output");
    changed.session = Arc::new(session);
    changed.visible_messages = usize::MAX;
    let (mut visual, child) = host(&root, changed.clone(), cx);
    jump_to(&child, 10, 8., cx);
    let before = anchor(&child, cx);
    let rows = row_ids(&child, cx);
    let selectors = cx.read(|cx| child.read(cx).tool_card_selectors());
    let selector = &selectors[10];
    let card_selector: &'static str = Box::leak(selector.clone().into_boxed_str());
    let output_selector: &'static str = Box::leak(format!("{selector}-OUT").into_boxed_str());
    let duration_selector: &'static str =
        Box::leak(format!("{selector}-disclosure-trailing").into_boxed_str());
    let disclosure_selector: &'static str =
        Box::leak(format!("{selector}-disclosure").into_boxed_str());
    assert!(visual.debug_bounds(duration_selector).is_none());
    let editors: Vec<_> = cx
        .read(|cx| child.read(cx).tool_section_editors())
        .iter()
        .map(|(_, e)| e.entity_id())
        .collect();
    let target = visual.debug_bounds(output_selector).unwrap().center();
    visual.simulate_click(target, Modifiers::none());
    visual.simulate_keystrokes("cmd-a cmd-c");
    let copied = cx.read(|cx| cx.read_from_clipboard().unwrap().text());
    assert_eq!(copied.as_deref(), Some("retained timing output"));
    let invalidations = cx.read(|cx| child.read(cx).tool_height_invalidation_count());
    let mut session = (*changed.session).clone();
    if let Some(ToolRecord::Result(record)) = &mut session.messages[21].tool_record {
        record.duration_us = Some(DurationUs::new(990_000));
    }
    changed.session = Arc::new(session);
    child.update(cx, |view, cx| view.update_inputs(changed.clone(), cx));
    cx.run_until_parked();
    assert!(visual.debug_bounds(duration_selector).is_some());
    assert!(
        visual.debug_bounds(output_selector).is_some(),
        "expanded stays expanded"
    );
    assert!(cx.read(|cx| child.read(cx).tool_height_invalidation_count()) > invalidations);
    assert_eq!(anchor(&child, cx), before);
    assert_eq!(row_ids(&child, cx), rows);
    let after: Vec<_> = cx
        .read(|cx| child.read(cx).tool_section_editors())
        .iter()
        .map(|(_, e)| e.entity_id())
        .collect();
    assert!(editors.iter().all(|id| after.contains(id)));
    cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_string("sentinel".into())));
    visual.simulate_keystrokes("cmd-c");
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text()),
        copied
    );

    let expanded_height = visual.debug_bounds(card_selector).unwrap().size.height;
    let target = visual.debug_bounds(disclosure_selector).unwrap().center();
    visual.simulate_click(target, Modifiers::none());
    cx.run_until_parked();
    let collapsed_height = visual.debug_bounds(card_selector).unwrap().size.height;
    assert!(collapsed_height < expanded_height);
    let collapsed_anchor = anchor(&child, cx);
    let mut session = (*changed.session).clone();
    if let Some(ToolRecord::Result(record)) = &mut session.messages[21].tool_record {
        record.duration_us = None;
    }
    changed.session = Arc::new(session);
    child.update(cx, |view, cx| view.update_inputs(changed.clone(), cx));
    cx.run_until_parked();
    assert_eq!(
        visual.debug_bounds(card_selector).unwrap().size.height,
        collapsed_height,
        "collapsed stays collapsed"
    );
    assert_eq!(anchor(&child, cx), collapsed_anchor);
}
