//! Synthetic GPUI read-card regressions. No model calls or real user files.
use super::*;
use bello_agent_core::{
    tool_content::{ContentBlock, ReadStats, ToolContent},
    tool_history::{ToolOutcome, ToolRecord},
};
use serde_json::json;

fn read_rows(text: &str, arguments: serde_json::Value, stats: Option<ReadStats>) -> Vec<Message> {
    let mut rows = retained_tool_rows(1, text);
    let Some(ToolRecord::Assistant(record)) = &mut rows[0].tool_record else {
        panic!()
    };
    record.calls[0].name = "read".into();
    record.calls[0].arguments = arguments;
    let Some(ToolRecord::Result(record)) = &mut rows[1].tool_record else {
        panic!()
    };
    record.content = Some(Arc::new(ToolContent {
        blocks: vec![ContentBlock::Text { text: text.into() }],
        stats,
    }));
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
fn output(
    child: &Entity<TranscriptView>,
    cx: &TestAppContext,
) -> Entity<bello_workbench_ui::EditorView> {
    cx.read(|cx| {
        child
            .read(cx)
            .tool_section_editors()
            .into_iter()
            .find(|(label, _)| *label == "OUT")
            .unwrap()
            .1
    })
}
fn click(visual: &mut VisualTestContext, selector: &'static str, cx: &mut TestAppContext) {
    let bounds = visual.debug_bounds(selector).expect("visible read control");
    visual.simulate_click(bounds.center(), Modifiers::none());
    cx.run_until_parked();
}

#[gpui::test]
fn read_ui_repeated_expansion_keeps_full_text_notes_focus_and_identity(cx: &mut TestAppContext) {
    crate::transcript_view::open_tool_rows_for_test();
    let text = (1..=14)
        .map(|n| {
            if n == 7 {
                format!("line-{n} {}", "界".repeat(3000))
            } else {
                format!("line-{n}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n[Truncated. 90 total lines; read another range.]";
    let (_directory, window, root) = fixture(
        cx,
        read_rows(&text, json!({"path":"fixture.txt", "offset":20}), None),
        0,
    );
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let more = selector(&child, "read-disclosure", cx);
    let disclosure = selector(&child, "disclosure", cx);
    let editor = output(&child, cx);
    let initial = cx.read(|cx| editor.read(cx).text().to_owned());
    // The head's six lines in their editor, numbered in their gutter; the
    // middle line; the tail's six.
    assert_eq!(initial, "line-1\nline-2\nline-3\nline-4\nline-5\nline-6");
    let card = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    let drawn = cx.read(|cx| child.read(cx).drawn_lines(&card)).unwrap();
    assert_eq!(drawn.more.as_deref(), Some("… 2 more lines"));
    let numbers = |run: &(&str, Vec<(String, bool)>)| -> Vec<String> {
        run.1.iter().map(|(mark, _)| mark.clone()).collect()
    };
    assert_eq!(
        numbers(&drawn.runs[0]),
        ["20", "21", "22", "23", "24", "25"]
    );
    assert_eq!(
        numbers(&drawn.runs[1]),
        ["28", "29", "30", "31", "32", "33"]
    );
    assert!(
        drawn
            .runs
            .iter()
            .flat_map(|run| &run.1)
            .all(|(_, tint)| !tint)
    );
    let tail = cx.read(|cx| {
        child
            .read(cx)
            .tool_section_editors()
            .into_iter()
            .find(|(label, _)| *label == "OUT-tail")
            .unwrap()
            .1
    });
    assert!(cx.read(|cx| tail.read(cx).text().starts_with("line-9\n")));
    assert!(cx.read(|cx| tail.read(cx).text().ends_with("line-14")));
    // The numbers end at the right of their 34-point gutter; the text
    // starts 12 past it.
    let marks = visual
        .debug_bounds(selector(&child, "OUT-marks", cx))
        .unwrap();
    let lines = visual.debug_bounds(selector(&child, "OUT", cx)).unwrap();
    let words = visual
        .debug_bounds(selector(&child, "OUT-text", cx))
        .unwrap();
    assert_eq!(marks.left() - lines.left(), px(16.));
    assert_eq!(marks.size.width, px(34.));
    assert_eq!(words.left() - marks.right(), px(12.));
    assert!(
        visual
            .debug_bounds(selector(&child, "read-note", cx))
            .is_some()
    );
    for _ in 0..3 {
        let invalidations = cx.read(|cx| child.read(cx).tool_height_invalidation_count());
        click(&mut visual, more, cx);
        assert!(cx.read(|cx| child.read(cx).tool_height_invalidation_count()) > invalidations);
        let expanded = cx.read(|cx| editor.read(cx).text().to_owned());
        assert!(
            expanded.len() > 8192 && expanded.contains("line-7") && expanded.ends_with("line-14")
        );
        let drawn = cx.read(|cx| child.read(cx).drawn_lines(&card)).unwrap();
        assert_eq!(drawn.more.as_deref(), Some("Show fewer lines"));
        assert_eq!(drawn.runs.len(), 1);
        assert_eq!(drawn.runs[0].1.len(), 14);
        click(&mut visual, disclosure, cx);
        click(&mut visual, disclosure, cx);
        assert_eq!(output(&child, cx).entity_id(), editor.entity_id());
        assert_eq!(
            cx.read(|cx| editor.read(cx).text().to_owned()),
            expanded,
            "details disclosure must retain the read window's expansion"
        );
        click(&mut visual, more, cx);
        assert_eq!(cx.read(|cx| editor.read(cx).text().to_owned()), initial);
    }
    let bounds = visual.debug_bounds(selector(&child, "OUT", cx)).unwrap();
    visual.simulate_click(bounds.center(), Modifiers::none());
    click(&mut visual, disclosure, cx);
    assert!(
        !window
            .update(cx, |_, window, cx| editor
                .read(cx)
                .focus_handle(cx)
                .is_focused(window))
            .unwrap()
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
        Some(text),
        "raw Copy must not acquire UI numbering or omit middle lines"
    );
}

#[gpui::test]
fn read_ui_content_only_changes_and_reopen_retain_text_without_image_decode(
    cx: &mut TestAppContext,
) {
    crate::transcript_view::open_tool_rows_for_test();
    let text = "Read image file [image/png]";
    let mut rows = read_rows(
        text,
        json!({"path":"original.png", "offset":2}),
        Some(ReadStats {
            path: "/synthetic/resolved.png".into(),
            line: None,
            last_line: None,
            added: None,
            removed: None,
        }),
    );
    let Some(ToolRecord::Result(record)) = &mut rows[1].tool_record else {
        panic!()
    };
    Arc::make_mut(record.content.as_mut().unwrap())
        .blocks
        .push(ContentBlock::Image {
            data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGxkAAAAASUVORK5CYII=".into(),
            mime_type: "image/png".into(),
        });
    let (_directory, _window, root) = fixture(cx, rows, 0);
    let child = transcript(&root, cx);
    let editor = output(&child, cx);
    assert_eq!(
        cx.read(|cx| editor.read(cx).text().to_owned()),
        "Read image file [image/png]\n[image/png result, 68 bytes]"
    );
    let card = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    assert_eq!(
        cx.read(|cx| child.read(cx).drawn_lines(&card))
            .unwrap()
            .runs[0]
            .1,
        [("2".to_owned(), false), ("3".to_owned(), false)]
    );
    let invalidations = cx.read(|cx| child.read(cx).tool_height_invalidation_count());
    snapshot_change(&root, cx, |session| {
        let Some(ToolRecord::Result(record)) = &mut session.messages[1].tool_record else {
            panic!()
        };
        let content = Arc::make_mut(record.content.as_mut().unwrap());
        content.stats.as_mut().unwrap().path = "/synthetic/changed.png".into();
        content.blocks[1] = ContentBlock::Image {
            data: "RUZHSA==".into(),
            mime_type: "image/png".into(),
        };
    });
    assert!(cx.read(|cx| child.read(cx).tool_height_invalidation_count()) > invalidations);
    assert_eq!(output(&child, cx).entity_id(), editor.entity_id());
    let mut reopened = input(&root, cx);
    reopened.session =
        Arc::new(serde_json::from_slice(&serde_json::to_vec(&*reopened.session).unwrap()).unwrap());
    let (_visual, reopened_child) = host(&root, reopened, cx);
    assert_eq!(
        cx.read(|app| output(&reopened_child, cx).read(app).text().to_owned()),
        cx.read(|cx| editor.read(cx).text().to_owned())
    );
    for (_, editor) in cx.read(|cx| reopened_child.read(cx).tool_section_editors()) {
        let text = cx.read(|cx| editor.read(cx).text().to_owned());
        assert!(
            !text.contains("iVBORw0KGgo")
                && !text.contains("RUZHSA==")
                && !text.contains("data:image")
        );
    }
    let key = MessageKey::new(
        cx.read(|cx| root.read(cx).record.id.clone()),
        "tool-result-0".into(),
    );
    root.update(cx, |view, cx| {
        view.copy_transcript_message(&key, &Arc::downgrade(&view.controller), cx)
    });
    assert_eq!(
        cx.read(|cx| cx.read_from_clipboard().unwrap().text())
            .as_deref(),
        Some(text),
        "image descriptors are display-only and must not change raw Copy"
    );
    for outcome in [ToolOutcome::Cancelled, ToolOutcome::Failed] {
        snapshot_change(&root, cx, |session| {
            let Some(ToolRecord::Result(record)) = &mut session.messages[1].tool_record else {
                panic!()
            };
            record.outcome = outcome;
            record.is_error = true;
        });
        assert!(
            cx.read(|app| output(&child, cx).read(app).text().to_owned())
                .contains("[image/png result, 4 bytes]")
        );
    }
    let omission = "Read image file [image/png]\n[Image omitted: fixture conversion failed.]";
    snapshot_change(&root, cx, |session| {
        session.messages[1].text = omission.into();
        let Some(ToolRecord::Result(record)) = &mut session.messages[1].tool_record else {
            panic!()
        };
        Arc::make_mut(record.content.as_mut().unwrap()).blocks = vec![ContentBlock::Text {
            text: omission.into(),
        }];
    });
    let displayed = cx.read(|cx| editor.read(cx).text().to_owned());
    assert!(displayed.contains("Image omitted: fixture conversion failed."));
    assert!(!displayed.contains("result,") && !displayed.contains("bytes]"));
}

#[gpui::test]
fn read_ui_resolved_path_opens_viewer_stats_first_line_and_reuses_tab(cx: &mut TestAppContext) {
    crate::transcript_view::open_tool_rows_for_test();
    let (_directory, window, root) = fixture(
        cx,
        read_rows(
            "model line a\rmodel line b\nmodel line c",
            json!({"path":"wrong-name.txt", "offset":2}),
            None,
        ),
        0,
    );
    let path = cx.read(|cx| root.read(cx).project.join("read-fixture.txt"));
    let file_text = (1..=25)
        .map(|n| format!("viewer line {n}\n"))
        .collect::<String>();
    std::fs::write(&path, &file_text).unwrap();
    snapshot_change(&root, cx, |session| {
        let Some(ToolRecord::Result(record)) = &mut session.messages[1].tool_record else {
            panic!()
        };
        Arc::make_mut(record.content.as_mut().unwrap()).stats = Some(ReadStats {
            path: path.to_str().unwrap().into(),
            line: Some(7),
            last_line: Some(9),
            added: None,
            removed: None,
        });
    });
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let link = selector(&child, "read-path", cx);
    click(&mut visual, link, cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(view.files.len(), 1);
        assert_eq!(view.files[0].path, path);
        let editor = view.files[0].view.read(cx).editor_for_test();
        let editor = editor.read(cx);
        assert_eq!(editor.text(), file_text);
        assert_eq!(
            editor.engine.cursor,
            editor.engine.buffer.line_start(6),
            "reveal must use host viewer line 7, not model offset 2"
        );
    });
    click(&mut visual, link, cx);
    assert_eq!(cx.read(|cx| root.read(cx).files.len()), 1);
}

#[gpui::test]
fn read_ui_stale_controller_path_cannot_open_file(cx: &mut TestAppContext) {
    crate::transcript_view::open_tool_rows_for_test();
    let (_directory, _window, root) = fixture(
        cx,
        read_rows(
            "retained text",
            json!({"path":"fixture.txt", "offset":2}),
            None,
        ),
        0,
    );
    let old_input = input(&root, cx);
    let old_controller = cx.read(|cx| root.read(cx).controller.clone());
    let (mut visual, stale_child) = host(&root, old_input.clone(), cx);
    let link = selector(&stale_child, "read-path", cx);
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
    assert!(
        cx.read(|cx| root.read(cx).files.is_empty()),
        "old read-card callbacks must fail the live controller guard"
    );
    let mut changed = old_input;
    changed.chat_id = "newer-chat".into();
    stale_child.update(cx, |view, cx| view.update_inputs(changed, cx));
    cx.run_until_parked();
    click(&mut visual, link, cx);
    assert!(
        cx.read(|cx| root.read(cx).files.is_empty()),
        "another chat's read card cannot open in the active chat"
    );
}

#[gpui::test]
fn read_ui_page_reveal_retains_expansion_and_unrelated_updates_retain_anchor(
    cx: &mut TestAppContext,
) {
    crate::transcript_view::open_tool_rows_for_test();
    let text = (1..=16)
        .map(|n| format!("line-{n}"))
        .collect::<Vec<_>>()
        .join("\n");
    let (_directory, _window, root) = fixture(
        cx,
        read_rows(&text, json!({"path":"fixture.txt", "offset":3}), None),
        0,
    );
    let mut changed = input(&root, cx);
    changed.visible_messages = 1;
    let (mut visual, child) = host(&root, changed.clone(), cx);
    assert_eq!(row_ids(&child, cx)[1], "tool-result-0");
    let more = selector(&child, "read-disclosure", cx);
    click(&mut visual, more, cx);
    assert!(cx.read(|app| output(&child, cx).read(app).text().contains("line-7")));
    changed.visible_messages = usize::MAX;
    child.update(cx, |view, cx| view.update_inputs(changed.clone(), cx));
    cx.run_until_parked();
    assert!(row_ids(&child, cx)[0].contains("@tool:"));
    assert!(
        cx.read(|app| output(&child, cx).read(app).text().contains("line-7")),
        "pairing an existing result must not lose its expansion state"
    );
    let editor = output(&child, cx);
    let before = anchor(&child, cx);
    let mut session = (*changed.session).clone();
    session
        .messages
        .push(message("later", "assistant", "Unrelated later reply"));
    changed.session = Arc::new(session);
    child.update(cx, |view, cx| view.update_inputs(changed.clone(), cx));
    cx.run_until_parked();
    assert_eq!(anchor(&child, cx), before);
    assert_eq!(output(&child, cx).entity_id(), editor.entity_id());
    // A new source result has a new expansion identity even with identical text.
    let mut session = (*changed.session).clone();
    session.messages[1].id = "replacement-result".into();
    changed.session = Arc::new(session);
    child.update(cx, |view, cx| view.update_inputs(changed, cx));
    cx.run_until_parked();
    assert!(!cx.read(|cx| editor.read(cx).text().contains("line-7")));
    let card = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    assert_eq!(
        cx.read(|cx| child.read(cx).drawn_lines(&card))
            .unwrap()
            .more
            .as_deref(),
        Some("… 4 more lines")
    );
}

#[gpui::test]
fn read_ui_newer_result_before_repaint_rejects_stale_path(cx: &mut TestAppContext) {
    crate::transcript_view::open_tool_rows_for_test();
    let (_directory, _window, root) = fixture(
        cx,
        read_rows(
            "retained text",
            json!({"path":"old-file.txt", "offset":2}),
            None,
        ),
        0,
    );
    let (mut visual, stale_child) = host(&root, input(&root, cx), cx);
    let link = selector(&stale_child, "read-path", cx);
    snapshot_change(&root, cx, |session| {
        let Some(ToolRecord::Result(record)) = &mut session.messages[1].tool_record else {
            panic!()
        };
        Arc::make_mut(record.content.as_mut().unwrap()).stats = Some(ReadStats {
            path: "/synthetic/new-file.txt".into(),
            line: Some(8),
            last_line: Some(8),
            added: None,
            removed: None,
        });
    });
    click(&mut visual, link, cx);
    assert!(
        cx.read(|cx| root.read(cx).files.is_empty()),
        "a live chat/controller still cannot open a replaced result's stale target"
    );
}

#[gpui::test]
fn read_ui_result_replaces_focused_arguments_with_visible_keyboard_owner(cx: &mut TestAppContext) {
    crate::transcript_view::open_tool_rows_for_test();
    let mut rows = read_rows(
        "retained text",
        json!({"path":"fixture.txt", "offset":2}),
        None,
    );
    let result = rows.pop().unwrap();
    let (_directory, window, root) = fixture(cx, rows, 0);
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let input = cx.read(|cx| {
        child
            .read(cx)
            .tool_section_editors()
            .into_iter()
            .find(|(label, _)| *label == "IN")
            .unwrap()
            .1
    });
    let input_bounds = visual.debug_bounds(selector(&child, "IN", cx)).unwrap();
    visual.simulate_click(input_bounds.center(), Modifiers::none());
    assert!(
        window
            .update(cx, |_, window, cx| input
                .read(cx)
                .focus_handle(cx)
                .is_focused(window))
            .unwrap()
    );
    snapshot_change(&root, cx, |session| session.messages.push(result));
    assert!(
        !window
            .update(cx, |_, window, cx| input
                .read(cx)
                .focus_handle(cx)
                .is_focused(window))
            .unwrap(),
        "read-card completion must not leave hidden argument-editor focus"
    );
    let shortcut = if cfg!(target_os = "macos") {
        "cmd-shift-g"
    } else {
        "ctrl-shift-g"
    };
    cx.simulate_keystrokes(window.into(), shortcut);
    assert!(cx.read(|cx| root.read(cx).changes_open));
}

#[gpui::test]
fn read_ui_image_only_descriptor_window_can_expand(cx: &mut TestAppContext) {
    crate::transcript_view::open_tool_rows_for_test();
    let mut rows = read_rows("", json!({"path":"fixture.png"}), None);
    let Some(ToolRecord::Result(record)) = &mut rows[1].tool_record else {
        panic!()
    };
    Arc::make_mut(record.content.as_mut().unwrap()).blocks = (0..14)
        .map(|_| ContentBlock::Image {
            data: "YQ==".into(),
            mime_type: "image/png".into(),
        })
        .collect();
    let (_directory, window, root) = fixture(cx, rows, 0);
    let child = transcript(&root, cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let editor = output(&child, cx);
    let card = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    let more_line = |cx: &TestAppContext| {
        cx.read(|cx| child.read(cx).drawn_lines(&card))
            .unwrap()
            .more
    };
    assert_eq!(more_line(cx).as_deref(), Some("… 2 more lines"));
    let more = selector(&child, "read-disclosure", cx);
    click(&mut visual, more, cx);
    assert_eq!(
        cx.read(|cx| editor.read(cx).text().lines().nth(6).map(str::to_owned)),
        Some("[image/png result, 1 bytes]".to_owned())
    );
    assert_eq!(more_line(cx).as_deref(), Some("Show fewer lines"));
    click(&mut visual, more, cx);
    assert_eq!(more_line(cx).as_deref(), Some("… 2 more lines"));
}

#[cfg(feature = "synthetic-authority")]
#[path = "transcript_read_native_ui_tests.rs"]
mod native_workflow;
