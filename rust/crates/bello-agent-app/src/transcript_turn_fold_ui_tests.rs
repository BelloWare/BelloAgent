//! Swift's end-of-turn fold: a finished turn's work behind one line above
//! its answer, opened by a click and by a reveal, never while it runs.
use super::*;
use bello_agent_core::{
    provider::ToolCall,
    tool_history::{
        AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
    },
};

fn with_calls(mut assistant: Message, calls: &[(&str, &str)]) -> Vec<Message> {
    let owner = assistant.id.clone();
    assistant.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
        tool_batch_timing: None,
        completion: Completion::Complete,
        calls: calls
            .iter()
            .map(|(id, name)| ToolCall {
                id: (*id).into(),
                name: (*name).into(),
                arguments: serde_json::json!({"command": "true"}),
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
    let results = calls.iter().map(|(id, _)| {
        let mut result = message(&format!("{owner}-{id}-result"), "toolResult", "ok");
        result.tool_record = Some(ToolRecord::Result(ResultRecord {
            duration_us: None,
            assistant_id: owner.clone(),
            call_id: (*id).into(),
            is_error: false,
            outcome: ToolOutcome::Completed,
            content: None,
        }));
        result
    });
    std::iter::once(assistant).chain(results).collect()
}

/// A question, a reply that narrates and runs two commands and a subagent,
/// and an answer that thought first; then a plain question and answer.
fn finished_turns() -> Vec<Message> {
    let mut working = message("working", "assistant", "Looking at the parser.");
    working.reasoning = "Plan the change.".into();
    let mut answer = message("answer", "assistant", "Done: the parser keeps its offsets.");
    answer.reasoning = "Checked the result.".into();
    let mut rows = vec![message("question", "user", "Fix the parser.")];
    rows.extend(with_calls(
        working,
        &[("c0", "bash"), ("c1", "bash"), ("c2", "subagent_review")],
    ));
    rows.extend([
        answer,
        message("thanks", "user", "Thanks."),
        message("welcome", "assistant", "You're welcome."),
    ]);
    rows
}

fn host_rows(
    rows: Vec<Message>,
    state: RunState,
    cx: &mut TestAppContext,
) -> (
    tempfile::TempDir,
    VisualTestContext,
    Entity<TranscriptView>,
    TranscriptInput,
) {
    let (directory, _window, root) = fixture(cx, messages(1), 0);
    let mut changed = input(&root, cx);
    let mut session = (*changed.session).clone();
    session.messages = rows;
    session.state = state;
    changed.session = Arc::new(session);
    changed.visible_messages = usize::MAX;
    let (visual, child) = host(&root, changed.clone(), cx);
    (directory, visual, child, changed)
}

fn bounds(visual: &mut VisualTestContext, selector: &str) -> Option<Bounds<Pixels>> {
    visual.debug_bounds(Box::leak(selector.to_owned().into_boxed_str()))
}

const FOLD: &str = "transcript-fold-Fold(Message(\"question\"))";

#[gpui::test]
fn a_finished_turns_work_folds_behind_one_line_above_its_answer(cx: &mut TestAppContext) {
    let (_directory, mut visual, child, _) = host_rows(finished_turns(), RunState::Paused, cx);
    // The control stands where the work began; the plain turn has nothing
    // to fold.
    let ids = row_ids(&child, cx);
    assert_eq!(ids[0], "question");
    assert_eq!(ids[1], "@fold:Message(\"question\")");
    assert_eq!(ids.iter().filter(|id| id.starts_with("@fold")).count(), 1);
    assert_eq!(
        cx.read(|cx| child.read(cx).fold_lines()),
        vec![("2 tool calls · 1 message · 1 subagent".to_owned(), false)]
    );
    let control = bounds(&mut visual, FOLD).expect("the fold's line");
    assert_eq!(control.size.height, px(32.));
    // Closed: the work was never drawn, nor the answer's thought; the
    // answer's words were.
    assert!(bounds(&mut visual, "transcript-text-working").is_none());
    assert!(bounds(&mut visual, "transcript-row-answer-think").is_none());
    let words = bounds(&mut visual, "transcript-text-answer").expect("the answer");
    assert!(cx.read(|cx| child.read(cx).tool_card_selectors()).len() == 3);

    visual.simulate_click(control.center(), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(
        cx.read(|cx| child.read(cx).fold_lines()),
        vec![("2 tool calls · 1 message · 1 subagent".to_owned(), true)]
    );
    let narrated = bounds(&mut visual, "transcript-text-working").expect("the work, open");
    assert!(bounds(&mut visual, "transcript-row-answer-think").is_some());
    let opened = bounds(&mut visual, "transcript-text-answer").unwrap();
    assert!(narrated.top() > control.bottom());
    assert!(
        opened.top() > words.top() + px(3. * 24.),
        "the work stands above the answer"
    );

    visual.simulate_click(control.center(), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(
        bounds(&mut visual, "transcript-text-answer").unwrap().top(),
        words.top(),
        "closing gives the room back"
    );
}

#[gpui::test]
fn a_turn_still_running_or_stopped_in_its_work_does_not_fold(cx: &mut TestAppContext) {
    let (_directory, _visual, child, _) = host_rows(finished_turns(), RunState::Running, cx);
    // Only the turn the host is running stays loose.
    let ids = row_ids(&child, cx);
    assert!(ids.contains(&"@fold:Message(\"question\")".to_owned()));
    let mut rows = finished_turns();
    rows.truncate(rows.len() - 2);
    let (_directory, _visual, child, _) = host_rows(rows, RunState::Running, cx);
    assert!(cx.read(|cx| child.read(cx).fold_lines()).is_empty());

    // A turn whose last reply made a call ended in its work, not an answer.
    let mut rows = finished_turns();
    rows.truncate(rows.len() - 3);
    let (_directory, _visual, child, _) = host_rows(rows, RunState::Paused, cx);
    assert!(cx.read(|cx| child.read(cx).fold_lines()).is_empty());
}

#[gpui::test]
fn revealing_folded_work_opens_its_turn(cx: &mut TestAppContext) {
    let (_directory, mut visual, child, input) = host_rows(finished_turns(), RunState::Paused, cx);
    assert!(child.update(cx, |view, cx| view.reveal_message(input, "working", cx)));
    cx.run_until_parked();
    assert_eq!(cx.read(|cx| child.read(cx).fold_lines())[0].1, true);
    assert!(bounds(&mut visual, "transcript-text-working").is_some());
}
