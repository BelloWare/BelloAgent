//! Synthetic generic terminal-card regressions. No tool execution or user files.
use super::*;
use bello_agent_core::{
    provider::ToolCall,
    tool_content::{ContentBlock, ToolContent},
    tool_history::{EMPTY_RESULT, LiveToolView, ResultRecord, ToolOutcome, ToolRecord},
};
use serde_json::json;

fn section_editor(
    child: &Entity<TranscriptView>,
    text: &str,
    cx: &TestAppContext,
) -> Entity<bello_workbench_ui::EditorView> {
    cx.read(|cx| {
        child
            .read(cx)
            .tool_section_editors()
            .into_iter()
            .find(|(label, editor)| *label == "OUT" && editor.read(cx).text() == text)
            .unwrap_or_else(|| panic!("missing terminal output: {text:?}"))
            .1
    })
}

fn terminal_cards_case(name: &str, cx: &mut TestAppContext) {
    let (_directory, _window, root) = fixture(cx, messages(1), 0);
    let mut changed = input(&root, cx);
    let mut session = (*changed.session).clone();
    session.messages = retained_tool_rows(1, "not yet retained");
    session.messages.truncate(1);
    session.state = RunState::Running;
    let assistant = session.messages[0].id.clone();
    session.active_reply = Some(assistant.clone());
    let Some(ToolRecord::Assistant(record)) = &mut session.messages[0].tool_record else {
        panic!("fixture assistant")
    };
    record.calls[0].name = name.into();
    record.calls[0].arguments = if name == "mcp" {
        json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{}})
    } else {
        json!({"pattern":"fixture","path":"."})
    };
    record.calls.extend([
        ToolCall {
            id: "awaiting-sibling".into(),
            name: "mcp".into(),
            arguments: json!({"action":"invoke","server":"fixture","tool":"held"}),
        },
        ToolCall {
            id: "running-sibling".into(),
            name: "bash".into(),
            arguments: json!({"command":"printf held"}),
        },
    ]);
    session.live_tools.push(LiveToolView {
        duration_us: None,
        assistant_id: assistant.clone(),
        call_id: "running-sibling".into(),
        sequence: 1,
        preview: "held sibling output".into(),
        outcome: None,
    });
    changed.session = Arc::new(session);
    changed.visible_messages = usize::MAX;
    let (mut visual, child) = host(&root, changed.clone(), cx);
    visual.simulate_resize(size(px(700.), px(1100.)));
    cx.run_until_parked();
    let rows = row_ids(&child, cx);
    let selectors = cx.read(|cx| child.read(cx).tool_card_selectors());
    assert_eq!(rows.len(), 3);
    assert_eq!(selectors.len(), 3);
    assert_eq!(
        cx.read(|cx| child.read(cx).tool_section_editors())
            .iter()
            .filter(|(label, _)| *label == "OUT")
            .count(),
        1,
        "awaiting calls must not acquire fabricated output"
    );
    let held = section_editor(&child, "held sibling output", cx);
    let output_selector: &'static str = Box::leak(format!("{}-OUT", selectors[0]).into_boxed_str());
    let awaiting_output_selector: &'static str =
        Box::leak(format!("{}-OUT", selectors[1]).into_boxed_str());
    let mut owner_editor = None;
    for (sequence, (outcome, preview, displayed)) in [
        (
            ToolOutcome::Failed,
            "normalized failure",
            "normalized failure",
        ),
        (
            ToolOutcome::Unknown,
            "effects may have occurred",
            "effects may have occurred",
        ),
        (
            ToolOutcome::NotExecuted,
            "rejected before execution",
            "rejected before execution",
        ),
        (
            ToolOutcome::Completed,
            "normalized result",
            "normalized result",
        ),
        (
            ToolOutcome::Cancelled,
            "cancelled before completion",
            "cancelled before completion",
        ),
        (ToolOutcome::Completed, "", EMPTY_RESULT),
        (
            ToolOutcome::Completed,
            "[Image: image/png]\n",
            "[Image: image/png]\n",
        ),
    ]
    .into_iter()
    .enumerate()
    {
        let invalidations = cx.read(|cx| child.read(cx).tool_height_invalidation_count());
        let mut next = (*changed.session).clone();
        next.live_tools.truncate(1);
        next.live_tools.push(LiveToolView {
            duration_us: None,
            assistant_id: assistant.clone(),
            call_id: "reused".into(),
            sequence: sequence as u64 + 1,
            preview: preview.into(),
            outcome: Some(outcome),
        });
        changed.session = Arc::new(next);
        child.update(cx, |view, cx| view.update_inputs(changed.clone(), cx));
        cx.run_until_parked();
        assert!(cx.read(|cx| child.read(cx).tool_height_invalidation_count()) > invalidations);
        assert_eq!(
            row_ids(&child, cx),
            rows,
            "terminal state must retain call identity"
        );
        assert_eq!(
            cx.read(|cx| child.read(cx).tool_card_selectors()),
            selectors
        );
        assert_eq!(
            changed.session.messages.len(),
            1,
            "the held batch has no durable results"
        );
        assert!(visual.debug_bounds(awaiting_output_selector).is_none());
        let bounds = visual
            .debug_bounds(output_selector)
            .expect("visible terminal output");
        assert!(bounds.size.height <= px(150.));
        let output = section_editor(&child, displayed, cx);
        assert!(cx.read(|cx| output.read(cx).engine.read_only));
        if let Some(id) = owner_editor {
            assert_eq!(
                output.entity_id(),
                id,
                "terminal revisions reuse the owning editor"
            );
        } else {
            owner_editor = Some(output.entity_id());
        }
        assert_eq!(
            section_editor(&child, "held sibling output", cx).entity_id(),
            held.entity_id()
        );
        assert!(changed.session.live_tools[0].outcome.is_none());
        assert_eq!(changed.session.live_tools[0].sequence, 1);
    }

    // A complete durable batch replaces previews in the same call cards. Leave
    // stale live data in the fixture to prove retained results are authoritative.
    let invalidations = cx.read(|cx| child.read(cx).tool_height_invalidation_count());
    let mut retained = (*changed.session).clone();
    for (index, call_id, text, outcome) in [
        (0, "reused", "durable replacement", ToolOutcome::Failed),
        (
            1,
            "awaiting-sibling",
            "held call completed",
            ToolOutcome::Completed,
        ),
        (
            2,
            "running-sibling",
            "held bash completed",
            ToolOutcome::Completed,
        ),
    ] {
        let mut result = message(&format!("durable-{index}"), "toolResult", text);
        result.tool_record = Some(ToolRecord::Result(ResultRecord {
            duration_us: None,
            assistant_id: assistant.clone(),
            call_id: call_id.into(),
            outcome,
            is_error: outcome == ToolOutcome::Failed,
            content: None,
        }));
        retained.messages.push(result);
    }
    retained.state = RunState::Idle;
    retained.active_reply = None;
    changed.session = Arc::new(retained);
    child.update(cx, |view, cx| view.update_inputs(changed.clone(), cx));
    cx.run_until_parked();
    assert_eq!(row_ids(&child, cx), rows);
    assert!(cx.read(|cx| child.read(cx).tool_height_invalidation_count()) > invalidations);
    let output = section_editor(&child, "durable replacement", cx);
    assert_eq!(Some(output.entity_id()), owner_editor);
    assert_eq!(
        section_editor(&child, "held bash completed", cx).entity_id(),
        held.entity_id()
    );
    section_editor(&child, "held call completed", cx);

    // A late preview cannot overwrite or even invalidate the retained card.
    let invalidations = cx.read(|cx| child.read(cx).tool_height_invalidation_count());
    let mut late = (*changed.session).clone();
    late.live_tools[1].sequence = u64::MAX;
    late.live_tools[1].preview = "late stale output".into();
    late.live_tools[1].outcome = Some(ToolOutcome::Unknown);
    changed.session = Arc::new(late);
    child.update(cx, |view, cx| view.update_inputs(changed.clone(), cx));
    cx.run_until_parked();
    assert_eq!(
        cx.read(|cx| child.read(cx).tool_height_invalidation_count()),
        invalidations
    );
    assert_eq!(
        section_editor(&child, "durable replacement", cx).entity_id(),
        output.entity_id()
    );

    // Display descriptors come from retained image content after commitment,
    // while the retained text remains empty and never exposes image bytes.
    let mut image = (*changed.session).clone();
    image.messages[1].text.clear();
    let Some(ToolRecord::Result(record)) = &mut image.messages[1].tool_record else {
        panic!("fixture result")
    };
    record.outcome = ToolOutcome::Completed;
    record.is_error = false;
    let content = ToolContent {
        blocks: vec![ContentBlock::Image {
            data: "YQ==".into(),
            mime_type: "image/png".into(),
        }],
        stats: None,
    };
    content.validate().unwrap();
    record.content = Some(Arc::new(content));
    image.live_tools.clear();
    changed.session = Arc::new(image);
    child.update(cx, |view, cx| view.update_inputs(changed.clone(), cx));
    cx.run_until_parked();
    assert_eq!(
        section_editor(&child, "[image/png result, 1 bytes]", cx).entity_id(),
        output.entity_id()
    );
    assert!(changed.session.messages[1].text.is_empty());
    for (_, editor) in cx.read(|cx| child.read(cx).tool_section_editors()) {
        assert!(!cx.read(|cx| editor.read(cx).text().contains("YQ==")));
    }
}

#[gpui::test]
fn generic_native_terminal_cards_render_while_siblings_wait_then_settle(cx: &mut TestAppContext) {
    crate::transcript_view::open_tool_rows_for_test();
    terminal_cards_case("grep", cx);
}

#[gpui::test]
fn generic_mcp_terminal_cards_render_while_siblings_wait_then_settle(cx: &mut TestAppContext) {
    crate::transcript_view::open_tool_rows_for_test();
    terminal_cards_case("mcp", cx);
}
