//! Tool calls as Swift 0.1.122's work rows: one 24-point line each, closed
//! until the reader opens it, a reply's calls stacked line on line, the card
//! opening under its line and pushing what follows down.
use super::*;
use bello_agent_core::{
    provider::ToolCall,
    tool_history::{
        AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
    },
};

/// One reply that made `count` calls, each with its result.
fn reply_with_calls(count: usize) -> Vec<Message> {
    let mut assistant = message("work-reply", "assistant", "");
    assistant.state = "completed".into();
    assistant.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
        tool_batch_timing: None,
        completion: Completion::Complete,
        calls: (0..count)
            .map(|i| ToolCall {
                id: format!("call-{i}"),
                name: "bash".into(),
                arguments: serde_json::json!({"command": format!("echo {i}")}),
            })
            .collect(),
        binding: ReplayBinding {
            profile_id: "fixture".into(),
            api: "openai-responses".into(),
            provider: "litellm".into(),
            model: "fixture".into(),
            endpoint_sha256: "0".repeat(64),
        },
        provider_items: vec![],
    }));
    let results = (0..count).map(|i| {
        let mut result = message(&format!("work-result-{i}"), "toolResult", &format!("{i}"));
        result.tool_record = Some(ToolRecord::Result(ResultRecord {
            duration_us: None,
            assistant_id: "work-reply".into(),
            call_id: format!("call-{i}"),
            is_error: false,
            outcome: ToolOutcome::Completed,
            content: None,
        }));
        result
    });
    std::iter::once(assistant).chain(results).collect()
}

fn bounds(visual: &mut VisualTestContext, selector: String) -> Option<Bounds<Pixels>> {
    visual.debug_bounds(Box::leak(selector.into_boxed_str()))
}

#[gpui::test]
fn a_replys_calls_are_closed_work_lines_stacked_and_open_on_click(cx: &mut TestAppContext) {
    let (_directory, _window, root) = fixture(cx, messages(1), 0);
    let mut changed = input(&root, cx);
    let mut session = (*changed.session).clone();
    session.messages = reply_with_calls(3);
    changed.session = Arc::new(session);
    changed.visible_messages = usize::MAX;
    let (mut visual, child) = host(&root, changed, cx);
    let selectors = cx.read(|cx| child.read(cx).tool_card_selectors());
    assert_eq!(selectors.len(), 3);
    let lines: Vec<_> = selectors
        .iter()
        .map(|s| bounds(&mut visual, format!("{s}-disclosure")).expect("a work line"))
        .collect();
    for line in &lines {
        assert_eq!(line.size.height, px(24.));
    }
    // Closed: no card was ever drawn, and the lines touch.
    for selector in &selectors {
        assert!(bounds(&mut visual, format!("{selector}-card")).is_none());
        assert!(bounds(&mut visual, format!("{selector}-disclosure-title")).is_some());
        assert!(bounds(&mut visual, format!("{selector}-disclosure-summary")).is_some());
    }
    assert_eq!(lines[1].top(), lines[0].bottom());
    assert_eq!(lines[2].top(), lines[1].bottom());
    // The line sits 4 points into the column; its title starts after the
    // 16-point leading box and its 6-point gap.
    let title = bounds(&mut visual, format!("{}-disclosure-title", selectors[0])).unwrap();
    assert_eq!(title.left() - lines[0].left(), px(4. + 22.));

    visual.simulate_click(lines[0].center(), Modifiers::none());
    cx.run_until_parked();
    let card = bounds(&mut visual, format!("{}-card", selectors[0])).expect("an open card");
    let line = bounds(&mut visual, format!("{}-disclosure", selectors[0])).unwrap();
    // Set in to the title, 2 under the line, and 8 above the next line.
    assert_eq!(card.left() - line.left(), px(4. + 22.));
    assert_eq!(card.top() - line.bottom(), px(2.));
    let next = bounds(&mut visual, format!("{}-disclosure", selectors[1])).unwrap();
    assert_eq!(next.top() - card.bottom(), px(8.));

    visual.simulate_click(line.center(), Modifiers::none());
    cx.run_until_parked();
    let next = bounds(&mut visual, format!("{}-disclosure", selectors[1])).unwrap();
    assert_eq!(next.top(), lines[0].bottom(), "closing gives the room back");
}
