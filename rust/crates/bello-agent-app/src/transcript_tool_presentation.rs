//! Read-only projection of retained tool history. Source: SessionTools.swift's
//! assistant/call index, TranscriptActivity.swift and TranscriptCards.swift.
//! The model's bytes stay untouched; only visible card previews are copied.
use bello_agent_core::{
    Message, RunState, Session,
    provider::ToolCall,
    tool_content::ContentBlock,
    tool_history::{Completion, ToolOutcome, ToolRecord},
};
use std::{
    borrow::Cow,
    collections::{HashMap, HashSet},
    fmt::Write as _,
    io::{self, Write},
};

/// SessionTools.swift's displayText / ToolView.output: the retained textual
/// projection followed by one short descriptor per image. Source/provider text
/// never acquires these UI-only lines. Validated canonical base64 supplies the
/// decoded byte count from length/padding without decoding or scanning its data.
pub(super) fn display_text(message: &Message) -> Cow<'_, str> {
    let Some(ToolRecord::Result(record)) = &message.tool_record else {
        return Cow::Borrowed(&message.text);
    };
    let Some(content) = &record.content else {
        return Cow::Borrowed(&message.text);
    };
    let mut shown = Cow::Borrowed(message.text.as_str());
    for block in &content.blocks {
        if let ContentBlock::Image { data, mime_type } = block {
            let padding = if data.ends_with("==") {
                2
            } else {
                usize::from(data.ends_with('='))
            };
            let bytes = (data.len() / 4 * 3).saturating_sub(padding);
            let shown = shown.to_mut();
            if !shown.is_empty() {
                shown.push('\n');
            }
            write!(shown, "[{mime_type} result, {bytes} bytes]").expect("writing a String");
        }
    }
    shown
}

pub(super) fn has_display_text(message: &Message) -> bool {
    !message.text.is_empty()
        || matches!(&message.tool_record,
        Some(ToolRecord::Result(record)) if record.content.as_ref().is_some_and(|content|
            content.blocks.iter().any(|block| matches!(block, ContentBlock::Image { .. }))))
}

pub(super) const PREVIEW_BYTES: usize = 8 * 1024;
pub(super) const SECTION_CAP: f32 = 150.;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ProjectedRow {
    Message(usize),
    Call {
        assistant: usize,
        call: usize,
        result: Option<usize>,
    },
    Result(usize),
}

impl ProjectedRow {
    pub(super) fn source(self) -> usize {
        match self {
            Self::Message(i) | Self::Result(i) => i,
            Self::Call { assistant, .. } => assistant,
        }
    }
    pub(super) fn result(self) -> Option<usize> {
        match self {
            Self::Result(i) => Some(i),
            Self::Call { result, .. } => result,
            _ => None,
        }
    }
}

/// Pair only explicit, unique identities. A result is hidden only when the
/// owning call is in this displayed page. Ambiguous legacy data stays visible.
pub(super) fn project(session: &Session, first: usize) -> Vec<ProjectedRow> {
    let mut owners = HashMap::<(&str, &str), Option<(usize, usize)>>::new();
    let mut results = HashMap::<(&str, &str), Option<usize>>::new();
    for (index, message) in session.messages.iter().enumerate() {
        match &message.tool_record {
            Some(ToolRecord::Assistant(record)) if message.role == "assistant" => {
                for (call_index, call) in record.calls.iter().enumerate() {
                    owners
                        .entry((&message.id, &call.id))
                        .and_modify(|entry| *entry = None)
                        .or_insert(Some((index, call_index)));
                }
            }
            Some(ToolRecord::Result(record)) => {
                results
                    .entry((&record.assistant_id, &record.call_id))
                    .and_modify(|entry| *entry = None)
                    .or_insert(Some(index));
            }
            _ => {}
        }
    }
    let paired: HashMap<(usize, usize), usize> = owners
        .into_iter()
        .filter_map(|(key, owner)| {
            let (assistant, call) = owner?;
            let result = results.get(&key).copied().flatten()?;
            (assistant >= first && result > assistant).then_some(((assistant, call), result))
        })
        .collect();
    let suppressed: HashSet<usize> = paired.values().copied().collect();
    // A reply deferred by an automatic compaction was never requested; Swift
    // shows only the compaction row and the reply after it.
    let deferred = crate::compaction_actions::deferred_replies(session);
    let mut rows = Vec::new();
    for (index, message) in session.messages.iter().enumerate().skip(first) {
        match &message.tool_record {
            Some(ToolRecord::Assistant(record))
                if message.role == "assistant" && !record.calls.is_empty() =>
            {
                if !message.text.is_empty() || !message.reasoning.is_empty() {
                    rows.push(ProjectedRow::Message(index));
                }
                for call in 0..record.calls.len() {
                    rows.push(ProjectedRow::Call {
                        assistant: index,
                        call,
                        result: paired.get(&(index, call)).copied(),
                    });
                }
            }
            Some(ToolRecord::Result(_)) if !suppressed.contains(&index) => {
                rows.push(ProjectedRow::Result(index))
            }
            Some(ToolRecord::Result(_)) => {}
            _ if message.role == "toolResult" => rows.push(ProjectedRow::Result(index)),
            None if deferred.contains(message.id.as_str()) => {}
            _ => rows.push(ProjectedRow::Message(index)),
        }
    }
    rows
}

pub(super) fn call_at(session: &Session, assistant: usize, call: usize) -> &ToolCall {
    let Some(ToolRecord::Assistant(record)) = &session.messages[assistant].tool_record else {
        unreachable!("projected assistant")
    };
    &record.calls[call]
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Status {
    Completed,
    Failed,
    NotExecuted,
    Unknown,
    Cancelled,
    Missing,
    Awaiting,
    Running,
}
impl Status {
    pub(super) fn label(self, name: &str) -> &'static str {
        match (self, name == "ls") {
            (Self::Completed, true) => "Listed directory",
            (Self::Failed, true) => "Failed listing",
            (Self::NotExecuted, true) => "Skipped listing",
            (Self::Unknown, true) => "Stopped listing; outcome unknown",
            (Self::Completed, _) => "Completed",
            (Self::Failed, _) => "Failed",
            (Self::NotExecuted, _) => "Not executed",
            (Self::Unknown, _) => "Outcome unknown",
            (Self::Cancelled, _) => "Cancelled; no result retained",
            (Self::Missing, _) => "Outcome not recorded",
            (Self::Awaiting, _) => "Awaiting result",
            (Self::Running, _) => "Running",
        }
    }
    pub(super) fn is_error(self) -> bool {
        matches!(self, Self::Failed | Self::Unknown)
    }
}

pub(super) fn status(session: &Session, row: ProjectedRow) -> Status {
    if let Some(index) = row.result()
        && let Some(ToolRecord::Result(record)) = &session.messages[index].tool_record
    {
        return match record.outcome {
            ToolOutcome::Completed => Status::Completed,
            ToolOutcome::Failed => Status::Failed,
            ToolOutcome::NotExecuted => Status::NotExecuted,
            ToolOutcome::Unknown => Status::Unknown,
            ToolOutcome::Cancelled => Status::Cancelled,
        };
    }
    if let Some(live) = live(session, row) {
        return match live.outcome {
            None => Status::Running,
            Some(ToolOutcome::Completed) => Status::Completed,
            Some(ToolOutcome::Failed) => Status::Failed,
            Some(ToolOutcome::Unknown) => Status::Unknown,
            Some(ToolOutcome::NotExecuted) => Status::NotExecuted,
            Some(ToolOutcome::Cancelled) => Status::Cancelled,
        };
    }
    if let ProjectedRow::Call { assistant, .. } = row {
        let message = &session.messages[assistant];
        // The batch is admitted, not necessarily this call. No start time,
        // per-call progress or completion can be inferred from an active batch.
        if session.state == RunState::Running
            && session.active_reply.as_deref() == Some(&message.id)
            && assistant + 1 == session.messages.len()
            && message.state == "completed"
            && message.replay_eligible
            && matches!(&message.tool_record, Some(ToolRecord::Assistant(record)) if record.completion == Completion::Complete)
        {
            return Status::Awaiting;
        }
    }
    Status::Missing
}

pub(super) fn live(
    session: &Session,
    row: ProjectedRow,
) -> Option<&bello_agent_core::tool_history::LiveToolView> {
    let ProjectedRow::Call {
        assistant,
        call,
        result: None,
    } = row
    else {
        return None;
    };
    let owner = &session.messages[assistant].id;
    let id = &call_at(session, assistant, call).id;
    session
        .live_tools
        .iter()
        .find(|view| &view.assistant_id == owner && &view.call_id == id)
}

/// Canonical results, including an unknown observation, always replace live data.
pub(super) fn duration(
    session: &Session,
    row: ProjectedRow,
) -> Option<bello_agent_core::tool_timing::DurationUs> {
    if let Some(index) = row.result() {
        return match &session.messages[index].tool_record {
            Some(ToolRecord::Result(record)) => record.duration_us,
            _ => None,
        };
    }
    let view = live(session, row)?;
    view.outcome.and(view.duration_us)
}

pub(super) fn elapsed(session: &Session, row: ProjectedRow) -> Option<String> {
    crate::tool_timing_presentation::elapsed(duration(session, row))
}

pub(super) fn same_content(
    a: &Session,
    a_row: ProjectedRow,
    b: &Session,
    b_row: ProjectedRow,
) -> bool {
    if std::mem::discriminant(&a_row) != std::mem::discriminant(&b_row)
        || status(a, a_row) != status(b, b_row)
        || live(a, a_row) != live(b, b_row)
    {
        return false;
    }
    if let (
        ProjectedRow::Call {
            assistant: ai,
            call: ac,
            ..
        },
        ProjectedRow::Call {
            assistant: bi,
            call: bc,
            ..
        },
    ) = (a_row, b_row)
    {
        let (a_call, b_call) = (call_at(a, ai, ac), call_at(b, bi, bc));
        if a_call.id != b_call.id
            || a_call.name != b_call.name
            || a_call.arguments != b_call.arguments
        {
            return false;
        }
    }
    let same_message = |a: &Message, b: &Message| {
        a.id == b.id
            && a.role == b.role
            && a.text == b.text
            && a.reasoning == b.reasoning
            && a.state == b.state
            && match (&a.tool_record, &b.tool_record) {
                (Some(ToolRecord::Result(a)), Some(ToolRecord::Result(b))) => {
                    a.assistant_id == b.assistant_id
                        && a.call_id == b.call_id
                        && a.outcome == b.outcome
                        && a.is_error == b.is_error
                        && a.duration_us == b.duration_us
                        && match (&a.content, &b.content) {
                            // Payloads are immutable and may retain megabytes of images.
                            // New/reopened allocations remeasure rather than comparing
                            // their bytes synchronously on the UI thread.
                            (Some(a), Some(b)) => std::sync::Arc::ptr_eq(a, b),
                            (None, None) => true,
                            _ => false,
                        }
                }
                (Some(ToolRecord::Assistant(a)), Some(ToolRecord::Assistant(b))) => {
                    a.completion == b.completion
                }
                (None, None) => true,
                _ => false,
            }
    };
    same_message(&a.messages[a_row.source()], &b.messages[b_row.source()])
        && match (a_row.result(), b_row.result()) {
            (Some(ai), Some(bi)) => same_message(&a.messages[ai], &b.messages[bi]),
            (None, None) => true,
            _ => false,
        }
}

#[derive(Debug)]
pub(super) struct Preview {
    pub text: String,
    pub truncated: bool,
}
pub(super) fn preview(text: &str) -> Preview {
    let mut end = text.len().min(PREVIEW_BYTES);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    Preview {
        text: text[..end].into(),
        truncated: end < text.len(),
    }
}

/// Stop serialization at the display limit rather than first allocating a copy
/// of arbitrarily large retained arguments. The preview may end mid-JSON.
pub(super) fn arguments_preview(value: &serde_json::Value) -> Preview {
    struct Limit(Vec<u8>);
    impl Write for Limit {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            let room = PREVIEW_BYTES.saturating_sub(self.0.len());
            if room == 0 && !bytes.is_empty() {
                return Err(io::ErrorKind::WriteZero.into());
            }
            let take = room.min(bytes.len());
            self.0.extend_from_slice(&bytes[..take]);
            Ok(take)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    let mut writer = Limit(Vec::new());
    let truncated = serde_json::to_writer_pretty(&mut writer, value).is_err();
    while std::str::from_utf8(&writer.0).is_err() {
        writer.0.pop();
    }
    Preview {
        text: String::from_utf8(writer.0).expect("UTF-8 boundary"),
        truncated,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bello_agent_core::tool_history::{AssistantRecord, ReplayBinding, ResultRecord};
    use serde_json::json;

    pub(super) fn message(id: &str) -> Message {
        Message {
            task_root_id: None,
            user_content: None,
            id: id.into(),
            role: "assistant".into(),
            text: String::new(),
            reasoning: String::new(),
            replay_eligible: true,
            state: "completed".into(),
            usage: serde_json::Value::Null,
            model: None,
            tool_record: None,
            compaction: None,
        }
    }
    fn assistant(id: &str) -> Message {
        let mut message = message(id);
        message.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
            tool_batch_timing: None,
            completion: Completion::Complete,
            calls: vec![ToolCall {
                id: "same-call".into(),
                name: "ls".into(),
                arguments: json!({"path":"."}),
            }],
            binding: ReplayBinding {
                profile_id: "fixture".into(),
                api: "openai-responses".into(),
                provider: "litellm".into(),
                model: "fixture".into(),
                endpoint_sha256: "0".repeat(64),
            },
            provider_items: vec![],
        }));
        message
    }
    fn result(id: &str, owner: &str, outcome: ToolOutcome) -> Message {
        let mut message = message(id);
        message.role = "toolResult".into();
        message.text = format!("result for {owner}");
        message.tool_record = Some(ToolRecord::Result(ResultRecord {
            duration_us: None,
            assistant_id: owner.into(),
            call_id: "same-call".into(),
            is_error: outcome != ToolOutcome::Completed,
            outcome,
            content: None,
        }));
        message
    }
    #[test]
    fn source_image_descriptors_count_validated_payloads_without_changing_retained_text() {
        use bello_agent_core::tool_content::ToolContent;
        use std::sync::Arc;
        let mut message = result("r", "owner", ToolOutcome::Completed);
        message.text = "Read image file [image/png]".into();
        let original = message.text.clone();
        let content = ToolContent {
            blocks: vec![
                ContentBlock::Text {
                    text: original.clone(),
                },
                ContentBlock::Image {
                    data: "YQ==".into(),
                    mime_type: "image/png".into(),
                },
                ContentBlock::Image {
                    data: "YWI=".into(),
                    mime_type: "image/jpeg".into(),
                },
                ContentBlock::Image {
                    data: "YWJj".into(),
                    mime_type: "image/webp".into(),
                },
            ],
            stats: None,
        };
        content.validate().unwrap();
        let Some(ToolRecord::Result(record)) = &mut message.tool_record else {
            panic!()
        };
        record.content = Some(Arc::new(content));
        assert_eq!(
            display_text(&message),
            "Read image file [image/png]\n[image/png result, 1 bytes]\n[image/jpeg result, 2 bytes]\n[image/webp result, 3 bytes]"
        );
        assert_eq!(message.text, original);
        let Some(ToolRecord::Result(record)) = &message.tool_record else {
            panic!()
        };
        assert_eq!(record.content.as_ref().unwrap().text(), original);
        assert!(has_display_text(&message));
        message.text.clear();
        assert!(has_display_text(&message));
        assert!(display_text(&message).starts_with("[image/png result, 1 bytes]"));
    }

    #[test]
    fn omitted_images_and_legacy_text_do_not_invent_descriptors_or_allocate() {
        use bello_agent_core::tool_content::ToolContent;
        let mut message = result("r", "owner", ToolOutcome::Completed);
        message.text =
            "Read image file [image/png]\n[Image omitted: fixture conversion failed.]".into();
        assert!(matches!(display_text(&message), Cow::Borrowed(_)));
        let Some(ToolRecord::Result(record)) = &mut message.tool_record else {
            panic!()
        };
        record.content = Some(std::sync::Arc::new(ToolContent {
            blocks: vec![ContentBlock::Text {
                text: message.text.clone(),
            }],
            stats: None,
        }));
        assert!(matches!(display_text(&message), Cow::Borrowed(_)));
        assert_eq!(display_text(&message), message.text);
        message.text.clear();
        assert!(!has_display_text(&message));
    }

    #[test]
    fn pair_by_explicit_owner_preserve_prose_and_standalone_page_results() {
        let mut session = Session::new();
        let mut first = assistant("one");
        first.text = "Before listing".into();
        first.reasoning = "Retained reasoning".into();
        session.messages = vec![
            first,
            result("one-result", "one", ToolOutcome::Completed),
            assistant("two"),
            result("two-result", "two", ToolOutcome::Failed),
        ];
        assert_eq!(
            project(&session, 0),
            [
                ProjectedRow::Message(0),
                ProjectedRow::Call {
                    assistant: 0,
                    call: 0,
                    result: Some(1)
                },
                ProjectedRow::Call {
                    assistant: 2,
                    call: 0,
                    result: Some(3)
                }
            ]
        );
        assert_eq!(
            project(&session, 1),
            [
                ProjectedRow::Result(1),
                ProjectedRow::Call {
                    assistant: 2,
                    call: 0,
                    result: Some(3)
                }
            ]
        );
        assert_eq!(status(&session, project(&session, 0)[1]), Status::Completed);
        assert_eq!(status(&session, project(&session, 0)[2]), Status::Failed);
    }
    #[test]
    fn absent_results_do_not_claim_execution_or_turn_cancellation_into_skipped() {
        let mut session = Session::new();
        session.messages = vec![assistant("one")];
        let row = project(&session, 0)[0];
        assert_eq!(status(&session, row).label("ls"), "Outcome not recorded");
        session.state = RunState::Running;
        session.active_reply = Some("one".into());
        assert_eq!(status(&session, row).label("ls"), "Awaiting result");
        for (outcome, label) in [
            (ToolOutcome::Completed, "Listed directory"),
            (ToolOutcome::Failed, "Failed listing"),
            (ToolOutcome::NotExecuted, "Skipped listing"),
            (ToolOutcome::Unknown, "Stopped listing; outcome unknown"),
            (ToolOutcome::Cancelled, "Cancelled; no result retained"),
        ] {
            session.messages.truncate(1);
            session.messages.push(result("r", "one", outcome));
            assert_eq!(status(&session, project(&session, 0)[0]).label("ls"), label);
        }
    }
    #[test]
    fn previews_are_bounded_utf8_and_leave_retained_bytes_unchanged() {
        let text = format!("{}界\r\ntrailing", "a".repeat(PREVIEW_BYTES - 1));
        let output = preview(&text);
        assert!(output.truncated);
        assert!(output.text.len() <= PREVIEW_BYTES);
        assert!(text.ends_with("trailing"));
        let value = json!({"content": "界".repeat(PREVIEW_BYTES)});
        let before = value.clone();
        let input = arguments_preview(&value);
        assert!(input.truncated);
        assert!(input.text.len() <= PREVIEW_BYTES);
        assert_eq!(value, before);
        let small = json!({"path":"."});
        assert_eq!(
            arguments_preview(&small).text,
            serde_json::to_string_pretty(&small).unwrap()
        );
        assert!(!arguments_preview(&small).truncated);
    }
    #[test]
    fn arguments_result_identity_and_outcome_invalidate_equal_text() {
        let mut session = Session::new();
        session.messages = vec![assistant("one"), result("r", "one", ToolOutcome::Completed)];
        let row = project(&session, 0)[0];
        for change in ["arguments", "result-id", "outcome", "body"] {
            let mut next = session.clone();
            match change {
                "arguments" => {
                    if let Some(ToolRecord::Assistant(record)) = &mut next.messages[0].tool_record {
                        record.calls[0].arguments = json!({"path":"other"});
                    }
                }
                "result-id" => next.messages[1].id = "replacement".into(),
                "outcome" => {
                    if let Some(ToolRecord::Result(record)) = &mut next.messages[1].tool_record {
                        record.outcome = ToolOutcome::Failed;
                    }
                }
                _ => next.messages[1].text.push_str(" changed"),
            }
            assert!(
                !same_content(&session, row, &next, project(&next, 0)[0]),
                "{change}"
            );
        }
    }
    #[test]
    fn live_bash_projection_is_call_owned_bounded_and_invalidates_render_cache() {
        let mut session = Session::new();
        session.state = RunState::Running;
        session.active_reply = Some("one".into());
        session.messages = vec![assistant("one")];
        if let Some(ToolRecord::Assistant(record)) = &mut session.messages[0].tool_record {
            record.calls[0].name = "bash".into();
        }
        let row = project(&session, 0)[0];
        assert_eq!(status(&session, row), Status::Awaiting);
        let old = session.clone();
        session
            .live_tools
            .push(bello_agent_core::tool_history::LiveToolView {
                duration_us: None,
                assistant_id: "one".into(),
                call_id: "same-call".into(),
                sequence: 1,
                preview: "growing output".into(),
                outcome: None,
            });
        assert_eq!(status(&session, row).label("bash"), "Running");
        assert!(!same_content(&old, row, &session, row));
        let previous = session.clone();
        session.live_tools[0].sequence = 2;
        session.live_tools[0].preview = "\u{fffd}".repeat(32768).into();
        assert!(!same_content(&previous, row, &session, row));
        assert!(preview(&live(&session, row).unwrap().preview).text.len() <= PREVIEW_BYTES);
        session.live_tools[0].outcome = Some(ToolOutcome::Failed);
        assert_eq!(status(&session, row), Status::Failed);
        session.messages = vec![assistant("later")];
        assert!(live(&session, project(&session, 0)[0]).is_none());
    }
    #[test]
    fn retained_terminal_result_overrides_ephemeral_bash_display() {
        let mut session = Session::new();
        session.messages = vec![assistant("one"), result("r", "one", ToolOutcome::Unknown)];
        session
            .live_tools
            .push(bello_agent_core::tool_history::LiveToolView {
                duration_us: None,
                assistant_id: "one".into(),
                call_id: "same-call".into(),
                sequence: 99,
                preview: "late".into(),
                outcome: Some(ToolOutcome::Completed),
            });
        let row = project(&session, 0)[0];
        assert_eq!(status(&session, row), Status::Unknown);
        assert!(live(&session, row).is_none());
    }
    fn generic_live_batch(name: &str) -> Session {
        let mut session = Session::new();
        session.state = RunState::Running;
        session.active_reply = Some("one".into());
        session.messages = vec![assistant("one")];
        let Some(ToolRecord::Assistant(record)) = &mut session.messages[0].tool_record else {
            panic!("fixture assistant")
        };
        record.calls[0].name = name.into();
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
        session
            .live_tools
            .push(bello_agent_core::tool_history::LiveToolView {
                duration_us: None,
                assistant_id: "one".into(),
                call_id: "running-sibling".into(),
                sequence: 2,
                preview: "held sibling output".into(),
                outcome: None,
            });
        session
    }

    #[test]
    fn generic_terminal_projection_preserves_awaiting_and_running_siblings() {
        for name in ["grep", "mcp"] {
            let before = generic_live_batch(name);
            let rows = project(&before, 0);
            assert_eq!(rows.len(), 3);
            assert_eq!(status(&before, rows[0]), Status::Awaiting);
            assert_eq!(status(&before, rows[1]), Status::Awaiting);
            assert_eq!(status(&before, rows[2]), Status::Running);
            for (outcome, expected, label, is_error) in [
                (
                    ToolOutcome::Completed,
                    Status::Completed,
                    "Completed",
                    false,
                ),
                (ToolOutcome::Failed, Status::Failed, "Failed", true),
                (
                    ToolOutcome::Unknown,
                    Status::Unknown,
                    "Outcome unknown",
                    true,
                ),
                (
                    ToolOutcome::NotExecuted,
                    Status::NotExecuted,
                    "Not executed",
                    false,
                ),
                (
                    ToolOutcome::Cancelled,
                    Status::Cancelled,
                    "Cancelled; no result retained",
                    false,
                ),
            ] {
                for preview in ["normalized terminal output", "", "[Image: image/png]\n"] {
                    let mut terminal = before.clone();
                    terminal
                        .live_tools
                        .push(bello_agent_core::tool_history::LiveToolView {
                            duration_us: None,
                            assistant_id: "one".into(),
                            call_id: "same-call".into(),
                            sequence: 1,
                            preview: preview.into(),
                            outcome: Some(outcome),
                        });
                    assert_eq!(project(&terminal, 0), rows, "{name}: no durable result row");
                    assert_eq!(terminal.messages.len(), 1);
                    assert_eq!(status(&terminal, rows[0]), expected, "{name}: {outcome:?}");
                    assert_eq!(status(&terminal, rows[0]).label(name), label);
                    assert_eq!(status(&terminal, rows[0]).is_error(), is_error);
                    assert_eq!(live(&terminal, rows[0]).unwrap().preview.as_ref(), preview);
                    assert!(!same_content(&before, rows[0], &terminal, rows[0]));
                    assert_eq!(status(&terminal, rows[1]), Status::Awaiting);
                    assert!(live(&terminal, rows[1]).is_none());
                    assert_eq!(status(&terminal, rows[2]), Status::Running);
                    assert_eq!(live(&terminal, rows[2]), live(&before, rows[2]));
                    for row in &rows[1..] {
                        assert!(
                            same_content(&before, *row, &terminal, *row),
                            "{name}: held sibling changed"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn generic_terminal_display_changes_invalidate_only_the_owning_call() {
        for name in ["grep", "mcp"] {
            let mut before = generic_live_batch(name);
            before
                .live_tools
                .push(bello_agent_core::tool_history::LiveToolView {
                    duration_us: None,
                    assistant_id: "one".into(),
                    call_id: "same-call".into(),
                    sequence: 1,
                    preview: "same terminal text".into(),
                    outcome: Some(ToolOutcome::Completed),
                });
            let rows = project(&before, 0);
            assert!(same_content(&before, rows[0], &before.clone(), rows[0]));
            for change in ["preview", "sequence", "outcome", "removed", "owner", "call"] {
                let mut next = before.clone();
                match change {
                    "preview" => next.live_tools[1].preview = "changed terminal text".into(),
                    "sequence" => next.live_tools[1].sequence += 1,
                    "outcome" => next.live_tools[1].outcome = Some(ToolOutcome::Unknown),
                    "removed" => {
                        next.live_tools.pop();
                    }
                    "owner" => next.live_tools[1].assistant_id = "different-owner".into(),
                    "call" => next.live_tools[1].call_id = "different-call".into(),
                    _ => unreachable!(),
                }
                assert!(
                    !same_content(&before, rows[0], &next, rows[0]),
                    "{name}: {change}"
                );
                for row in &rows[1..] {
                    assert!(
                        same_content(&before, *row, &next, *row),
                        "{name}: {change} touched sibling"
                    );
                }
            }
        }
    }

    #[test]
    fn generic_retained_results_supersede_live_outcomes_and_ignore_late_previews() {
        for name in ["grep", "mcp"] {
            for (outcome, expected) in [
                (ToolOutcome::Completed, Status::Completed),
                (ToolOutcome::Failed, Status::Failed),
                (ToolOutcome::Unknown, Status::Unknown),
                (ToolOutcome::NotExecuted, Status::NotExecuted),
                (ToolOutcome::Cancelled, Status::Cancelled),
            ] {
                let mut before = generic_live_batch(name);
                before
                    .live_tools
                    .push(bello_agent_core::tool_history::LiveToolView {
                        duration_us: None,
                        assistant_id: "one".into(),
                        call_id: "same-call".into(),
                        sequence: 1,
                        preview: "ephemeral preview".into(),
                        outcome: Some(if outcome == ToolOutcome::Completed {
                            ToolOutcome::Failed
                        } else {
                            ToolOutcome::Completed
                        }),
                    });
                let old_row = project(&before, 0)[0];
                let mut retained = before.clone();
                retained.messages.push(result("durable", "one", outcome));
                let row = project(&retained, 0)[0];
                assert_eq!(row.result(), Some(1));
                assert_eq!(status(&retained, row), expected, "{name}: {outcome:?}");
                assert!(live(&retained, row).is_none());
                assert!(!same_content(&before, old_row, &retained, row));
                let mut late = retained.clone();
                late.live_tools[1].sequence = u64::MAX;
                late.live_tools[1].preview = "late replacement must not render".into();
                late.live_tools[1].outcome = Some(ToolOutcome::Unknown);
                assert!(same_content(&retained, row, &late, row));
                late.live_tools.clear();
                assert!(same_content(&retained, row, &late, row));
            }
        }
    }

    #[test]
    fn ambiguous_results_are_not_hidden_or_arbitrarily_paired() {
        let mut session = Session::new();
        session.messages = vec![
            assistant("one"),
            result("r1", "one", ToolOutcome::Completed),
            result("r2", "one", ToolOutcome::Failed),
        ];
        assert_eq!(
            project(&session, 0),
            [
                ProjectedRow::Call {
                    assistant: 0,
                    call: 0,
                    result: None
                },
                ProjectedRow::Result(1),
                ProjectedRow::Result(2)
            ]
        );
    }
    #[test]
    fn duration_only_updates_and_canonical_unknown_are_authoritative() {
        use bello_agent_core::tool_timing::DurationUs;
        let mut before = generic_live_batch("grep");
        before
            .live_tools
            .push(bello_agent_core::tool_history::LiveToolView {
                assistant_id: "one".into(),
                call_id: "same-call".into(),
                sequence: 1,
                preview: "same".into(),
                outcome: Some(ToolOutcome::Completed),
                duration_us: Some(DurationUs::new(990_000)),
            });
        let row = project(&before, 0)[0];
        assert_eq!(elapsed(&before, row).as_deref(), Some("1s"));
        let mut next = before.clone();
        next.live_tools[1].duration_us = Some(DurationUs::new(2_000_000));
        assert!(!same_content(&before, row, &next, row));
        next.live_tools[1].outcome = None;
        assert_eq!(elapsed(&next, row), None, "running has no clock");
        next.messages.push(result("r", "one", ToolOutcome::Unknown));
        let retained = project(&next, 0)[0];
        assert_eq!(
            duration(&next, retained),
            None,
            "canonical unknown replaces live known"
        );
        let mut timed = next.clone();
        if let Some(ToolRecord::Result(result)) = &mut timed.messages[1].tool_record {
            result.duration_us = Some(DurationUs::new(2_000_000));
        }
        assert!(!same_content(&next, retained, &timed, retained));
        assert_eq!(elapsed(&timed, retained).as_deref(), Some("2s"));
        for outcome in [
            ToolOutcome::Completed,
            ToolOutcome::Failed,
            ToolOutcome::Cancelled,
            ToolOutcome::NotExecuted,
            ToolOutcome::Unknown,
        ] {
            let mut terminal = timed.clone();
            if let Some(ToolRecord::Result(result)) = &mut terminal.messages[1].tool_record {
                result.outcome = outcome;
            }
            assert_eq!(elapsed(&terminal, retained).as_deref(), Some("2s"));
        }
        let mut stale = timed.clone();
        stale.live_tools[1].duration_us = Some(DurationUs::new(u64::MAX));
        assert!(same_content(&timed, retained, &stale, retained));
        assert_eq!(elapsed(&stale, retained).as_deref(), Some("2s"));
        before.live_tools[1].assistant_id = "older".into();
        assert_eq!(duration(&before, row), None);
    }
}
