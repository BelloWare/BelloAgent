//! Actual fake-platform controls, bounded diff/editor/cache behavior and links.
use super::*;
use bello_agent_core::{
    tool_content::{ContentBlock, ReadStats, ToolContent},
    tool_history::{ToolOutcome, ToolRecord},
};
use serde_json::json;
fn edit_rows(
    name: &str,
    arguments: serde_json::Value,
    outcome: ToolOutcome,
    stats: Option<ReadStats>,
) -> Vec<Message> {
    let text = if outcome == ToolOutcome::Completed {
        "Edited fixture (+20 -1)"
    } else {
        "Tool interrupted. Effects may already have occurred; inspect before retrying. No automatic replay."
    };
    let mut rows = retained_tool_rows(1, text);
    let Some(ToolRecord::Assistant(record)) = &mut rows[0].tool_record else {
        panic!()
    };
    record.calls[0].name = name.into();
    record.calls[0].arguments = arguments;
    let Some(ToolRecord::Result(record)) = &mut rows[1].tool_record else {
        panic!()
    };
    record.outcome = outcome;
    record.is_error = outcome != ToolOutcome::Completed;
    if outcome == ToolOutcome::Completed {
        record.content = Some(Arc::new(ToolContent {
            blocks: vec![ContentBlock::Text { text: text.into() }],
            stats,
        }));
    }
    rows
}
fn selector(child: &Entity<TranscriptView>, suffix: &str, cx: &TestAppContext) -> &'static str {
    Box::leak(
        format!(
            "{}-{suffix}",
            cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone())
        )
        .into_boxed_str(),
    )
}
fn editor(
    child: &Entity<TranscriptView>,
    label: &str,
    cx: &TestAppContext,
) -> Entity<bello_workbench_ui::EditorView> {
    cx.read(|cx| {
        child
            .read(cx)
            .tool_section_editors()
            .into_iter()
            .find(|(name, _)| *name == label)
            .unwrap()
            .1
    })
}
fn click(visual: &mut VisualTestContext, selector: &'static str, cx: &mut TestAppContext) {
    let bounds = visual.debug_bounds(selector).expect("visible edit control");
    visual.simulate_click(bounds.center(), Modifiers::none());
    cx.run_until_parked();
}
fn stats(path: &str) -> ReadStats {
    ReadStats {
        path: path.into(),
        line: Some(3),
        last_line: Some(4),
        added: Some(20),
        removed: Some(1),
    }
}

#[gpui::test]
fn edit_ui_diff_disclosure_cache_editor_identity_and_raw_copy(cx: &mut TestAppContext) {
    crate::transcript_view::open_tool_rows_for_test();
    let after = (0..20)
        .map(|n| format!("new-{n}"))
        .collect::<Vec<_>>()
        .join("\n");
    let (_directory, window, root) = fixture(
        cx,
        edit_rows(
            "edit",
            json!({"path":"fixture","oldText":"before","newText":after}),
            ToolOutcome::Completed,
            Some(stats("/synthetic/resolved")),
        ),
        0,
    );
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let input = editor(&child, "IN", cx);
    let collapsed = cx.read(|cx| input.read(cx).text().to_owned());
    // Swift's capped diff: six rows, the middle line, six rows; each row's
    // sign beside its text, the added and removed ones tinted.
    assert_eq!(collapsed, "before\nnew-0\nnew-1\nnew-2\nnew-3\nnew-4");
    let tail = editor(&child, "IN-tail", cx);
    assert!(cx.read(|cx| tail.read(cx).text().ends_with("new-19")));
    let card = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    let drawn = cx.read(|cx| child.read(cx).drawn_lines(&card)).unwrap();
    assert_eq!(drawn.more.as_deref(), Some("… 9 more lines"));
    assert_eq!(drawn.runs.len(), 2);
    assert_eq!(drawn.runs[0].0, "IN");
    assert_eq!(drawn.runs[0].1[0], ("−".to_owned(), true));
    assert_eq!(drawn.runs[0].1[1], ("+".to_owned(), true));
    assert_eq!(drawn.runs[1].0, "IN-tail");
    let head = visual.debug_bounds(selector(&child, "IN", cx)).unwrap();
    let more = visual
        .debug_bounds(selector(&child, "edit-disclosure", cx))
        .unwrap();
    let rest = visual
        .debug_bounds(selector(&child, "IN-tail", cx))
        .unwrap();
    assert_eq!(head.size.height, px(6. * 17.));
    assert_eq!(more.top(), head.bottom(), "the middle line stands between");
    assert_eq!(rest.top(), more.bottom());
    // The text stands past the sign's box, 34 points into the card.
    let text = visual
        .debug_bounds(selector(&child, "IN-text", cx))
        .unwrap();
    assert_eq!(text.left() - head.left(), px(34.));
    assert!(
        visual
            .debug_bounds(selector(&child, "edit-label", cx))
            .is_some()
    );
    assert!(
        visual
            .debug_bounds(selector(&child, "edit-counts", cx))
            .is_some()
    );
    assert!(visual.debug_bounds(selector(&child, "OUT", cx)).is_none());
    let computations = cx.read(|cx| child.read(cx).edit_cache_computations());
    for _ in 0..3 {
        click(&mut visual, selector(&child, "edit-disclosure", cx), cx);
        let full = cx.read(|cx| input.read(cx).text().to_owned());
        assert!(full.contains("new-10") && full.ends_with("new-19"));
        let drawn = cx.read(|cx| child.read(cx).drawn_lines(&card)).unwrap();
        assert_eq!(drawn.more.as_deref(), Some("Show fewer lines"));
        assert_eq!(drawn.runs.len(), 1);
        // Every row, in a scroll of its own past 224 points.
        let scroll = visual
            .debug_bounds(selector(&child, "IN-scroll", cx))
            .unwrap();
        assert_eq!(scroll.size.height, px(224.));
        click(&mut visual, selector(&child, "disclosure", cx), cx);
        click(&mut visual, selector(&child, "disclosure", cx), cx);
        assert_eq!(editor(&child, "IN", cx).entity_id(), input.entity_id());
        assert_eq!(cx.read(|cx| input.read(cx).text().to_owned()), full);
        click(&mut visual, selector(&child, "edit-disclosure", cx), cx);
        assert_eq!(cx.read(|cx| input.read(cx).text().to_owned()), collapsed);
    }
    assert_eq!(
        cx.read(|cx| child.read(cx).edit_cache_computations()),
        computations,
        "unchanged cached diff must not recompute during disclosure"
    );
    let key = MessageKey::new(
        cx.read(|cx| root.read(cx).record.id.clone()),
        "tool-result-0".into(),
    );
    root.update(cx, |view, cx| {
        view.copy_transcript_message(&key, &Arc::downgrade(&view.controller), cx)
    });
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text()),
        Some("Edited fixture (+20 -1)".into())
    );
}

#[gpui::test]
fn edit_ui_unknown_effects_never_claim_not_applied_and_large_content_is_explicit(
    cx: &mut TestAppContext,
) {
    crate::transcript_view::open_tool_rows_for_test();
    let text = "界".repeat(90_000);
    let (_directory, window, root) = fixture(
        cx,
        edit_rows(
            "write",
            json!({"path":"fixture","content":text}),
            ToolOutcome::Unknown,
            None,
        ),
        0,
    );
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let input = editor(&child, "IN", cx);
    assert!(cx.read(|cx| {
        input
            .read(cx)
            .text()
            .starts_with("Diff preview unavailable")
    }));
    let output = editor(&child, "OUT", cx);
    assert!(cx.read(|cx| {
        output
            .read(cx)
            .text()
            .contains("Effects may already have occurred")
    }));
    click(&mut visual, selector(&child, "edit-disclosure", cx), cx);
    assert_eq!(cx.read(|cx| input.read(cx).text().to_owned()), text);
    assert!(
        visual
            .debug_bounds(selector(&child, "IN", cx))
            .unwrap()
            .size
            .height
            <= px(150.)
    );
    assert_eq!(
        cx.read(|cx| child.read(cx).edit_card_labels()),
        ["Requested content · outcome unknown"]
    );
}

#[gpui::test]
fn edit_ui_uses_resolved_file_range(cx: &mut TestAppContext) {
    crate::transcript_view::open_tool_rows_for_test();
    let (directory, window, root) = fixture(
        cx,
        edit_rows(
            "edit",
            json!({"path":"wrong.txt","oldText":"before","newText":"after"}),
            ToolOutcome::Completed,
            None,
        ),
        0,
    );
    let file = directory.path().join("resolved.txt");
    std::fs::write(&file, "one\ntwo\nthree\nfour\n").unwrap();
    snapshot_change(&root, cx, |session| {
        let Some(ToolRecord::Result(record)) = &mut session.messages[1].tool_record else {
            panic!()
        };
        Arc::make_mut(record.content.as_mut().unwrap()).stats = Some(stats(file.to_str().unwrap()));
    });
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    click(&mut visual, selector(&child, "edit-path", cx), cx);
    assert!(cx.read(|cx| root.read(cx).files.iter().any(|opened| opened.path == file)));
    cx.read(|cx| {
        let view = root.read(cx);
        let editor = view.files[0].view.read(cx).editor_for_test();
        let editor = editor.read(cx);
        assert_eq!(editor.engine.cursor, editor.engine.buffer.line_start(2));
    });
}

#[gpui::test]
fn edit_ui_stale_controller_path_cannot_open_file(cx: &mut TestAppContext) {
    crate::transcript_view::open_tool_rows_for_test();
    let (_directory, _window, root) = fixture(
        cx,
        edit_rows(
            "edit",
            json!({"path":"fixture.txt","oldText":"before","newText":"after"}),
            ToolOutcome::Completed,
            None,
        ),
        0,
    );
    let old_input = input(&root, cx);
    let old_controller = cx.read(|cx| root.read(cx).controller.clone());
    let (mut visual, stale_child) = host(&root, old_input.clone(), cx);
    let link = selector(&stale_child, "edit-path", cx);
    let mut store = SessionStore::pending_with_id(&old_input.chat_id).unwrap();
    let path = cx.read(|cx| root.read(cx).project.join("replacement.json"));
    store.persist_to(path).unwrap();
    store
        .transact(|session| {
            *session = old_controller.snapshot();
            Ok(())
        })
        .unwrap();
    let replacement = Controller::new(store, None).unwrap();
    root.update(cx, |view, cx| {
        view.chat.replace_controller(replacement, cx);
        cx.notify();
    });
    cx.run_until_parked();
    click(&mut visual, link, cx);
    assert!(cx.read(|cx| root.read(cx).files.is_empty()));
}

#[cfg(feature = "synthetic-authority")]
#[path = "transcript_edit_native_ui_tests.rs"]
mod native_workflow;

#[gpui::test]
fn edit_ui_standalone_paged_result_preserves_disclosure_when_owner_is_revealed(
    cx: &mut TestAppContext,
) {
    crate::transcript_view::open_tool_rows_for_test();
    let text = (0..20)
        .map(|n| format!("line-{n}"))
        .collect::<Vec<_>>()
        .join("\n");
    let (_directory, _window, root) = fixture(
        cx,
        edit_rows(
            "edit",
            json!({"path":"fixture.txt","oldText":"before","newText":text}),
            ToolOutcome::Completed,
            None,
        ),
        0,
    );
    let mut changed = input(&root, cx);
    changed.visible_messages = 1;
    let (mut visual, child) = host(&root, changed.clone(), cx);
    assert_eq!(row_ids(&child, cx)[1], "tool-result-0");
    click(&mut visual, selector(&child, "edit-disclosure", cx), cx);
    assert!(cx.read(|app| {
        editor(&child, "IN", cx)
            .read(app)
            .text()
            .contains("line-10")
    }));
    changed.visible_messages = usize::MAX;
    child.update(cx, |view, cx| view.update_inputs(changed.clone(), cx));
    cx.run_until_parked();
    assert!(row_ids(&child, cx)[0].contains("@tool:"));
    assert!(
        cx.read(|app| editor(&child, "IN", cx)
            .read(app)
            .text()
            .contains("line-10")),
        "revealing the validated owning assistant must preserve requested-change expansion"
    );
}
