//! Swift TranscriptReadCard's numbered window and separate truncation note.
//! These are presentation projections only; the durable/provider bytes do not
//! gain numbers, and images use source textual notes and payload descriptors.
use super::tool_presentation::{self, ProjectedRow, Status};
use bello_agent_core::{Session, provider::ToolCall, tool_history::ToolRecord};
use serde_json::Value;

/// The host supplies viewer line numbers, which can differ from the model's
/// LF-only numbering. Preserve the full range even though today's file editor
/// reveals its first line rather than selecting the entire range.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ReadFileLink {
    pub path: String,
    pub lines: Option<std::ops::RangeInclusive<usize>>,
}

pub(super) fn read_call(session: &Session, row: ProjectedRow) -> Option<&ToolCall> {
    let call = match row {
        ProjectedRow::Call {
            assistant, call, ..
        } => tool_presentation::call_at(session, assistant, call),
        ProjectedRow::Result(index) => {
            // Paging may hide the owning assistant. Only recover an unambiguous
            // explicit owner; duplicated legacy IDs must not guess a file.
            let Some(ToolRecord::Result(result)) = &session.messages[index].tool_record else {
                return None;
            };
            let mut owners = session
                .messages
                .iter()
                .enumerate()
                .filter(|(_, message)| message.id == result.assistant_id);
            let (owner_index, owner) = owners.next()?;
            if owners.next().is_some() || owner.role != "assistant" || owner_index >= index {
                return None;
            }
            let Some(ToolRecord::Assistant(record)) = &owner.tool_record else {
                return None;
            };
            let mut calls = record.calls.iter().filter(|call| call.id == result.call_id);
            let call = calls.next()?;
            if calls.next().is_some() {
                return None;
            }
            call
        }
        _ => return None,
    };
    (call.name == "read").then_some(call)
}

pub(super) fn file_link(session: &Session, row: ProjectedRow) -> Option<ReadFileLink> {
    let call = read_call(session, row)?;
    let status = tool_presentation::status(session, row);
    let result = row.result().map(|index| &session.messages[index]);
    let stats = result.and_then(|message| match &message.tool_record {
        Some(ToolRecord::Result(record)) => record.content.as_ref()?.stats.as_ref(),
        _ => None,
    });
    let shown = result.map(tool_presentation::display_text);
    let text = shown.as_deref().unwrap_or("");
    let path = stats
        .map(|stats| stats.path.as_str())
        .filter(|path| !path.is_empty())
        .or_else(|| {
            (status != Status::Awaiting)
                .then(|| call.arguments["path"].as_str())
                .flatten()
        })?;
    if path.is_empty() {
        return None;
    }
    let mut lines = None;
    if status == Status::Completed
        && (call.arguments.get("offset").is_some() || call.arguments.get("limit").is_some())
        && !text.starts_with("Read image file [")
    {
        if let Some(first) = stats
            .and_then(|stats| stats.line)
            .filter(|first| *first > 0)
        {
            let last = stats
                .and_then(|stats| stats.last_line)
                .unwrap_or(first)
                .max(first);
            lines = Some(first as usize..=last as usize);
        } else {
            let window = ReadWindow::new(text, &call.arguments);
            if !window.lines.is_empty() {
                lines = Some(window.first_line..=window.first_line + window.lines.len() - 1);
            }
        }
    }
    Some(ReadFileLink {
        path: path.into(),
        lines,
    })
}

/// `TranscriptCardMetrics.readLines`.
pub(super) const READ_LINES: usize = super::card_lines::MAX_LINES;

/// `TranscriptReadCardText.window(shown:total:)`: "Showing 12 of 340
/// lines", and only the count when every line shows.
pub(super) fn window(shown: usize, total: usize) -> String {
    if shown >= total {
        format!("{total} line{}", if total == 1 { "" } else { "s" })
    } else {
        format!("Showing {shown} of {total} lines")
    }
}

pub(super) struct ReadWindow<'a> {
    /// The result's text the lines are slices of.
    pub text: &'a str,
    pub lines: Vec<&'a str>,
    pub note: Option<&'a str>,
    pub first_line: usize,
}

/// One run of the window's lines the card shows: which lines, and where they
/// stand in the result's text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Part {
    pub lines: std::ops::Range<usize>,
    pub bytes: std::ops::Range<usize>,
}

impl<'a> ReadWindow<'a> {
    pub fn new(text: &'a str, arguments: &Value) -> Self {
        let mut lines = if text.is_empty() {
            vec![]
        } else {
            text.split('\n').collect()
        };
        let note = lines
            .last()
            .copied()
            .filter(|last| last.starts_with("[Truncated.") && last.ends_with(']'))
            .map(|last| &last[1..last.len() - 1]);
        if note.is_some() {
            lines.pop();
        }
        let first_line = arguments["offset"]
            .as_f64()
            .filter(|n| n.is_finite() && n.fract() == 0. && *n >= 1. && *n <= 10_000_000.)
            .unwrap_or(1.) as usize;
        Self {
            text,
            lines,
            note,
            first_line,
        }
    }

    pub fn head_tail(&self, expanded: bool) -> super::card_lines::HeadTail {
        super::card_lines::head_tail(self.lines.len(), READ_LINES, expanded)
    }
    /// Whether the window hides enough to offer its middle line at all.
    pub fn collapsible(&self) -> bool {
        super::card_lines::collapses(self.head_tail(false).hidden)
    }
    /// `TranscriptReadCardText.window(shown:total:)`.
    pub fn window_label(&self, expanded: bool) -> String {
        let total = self.lines.len();
        let cap = self.head_tail(expanded);
        let shown = if cap.capped {
            cap.head + cap.tail
        } else {
            total
        };
        window(shown, total)
    }
    /// The head and, while capped, the tail: the runs of lines the card
    /// draws, each an exact slice of the result's text.
    pub fn parts(&self, expanded: bool) -> Vec<Part> {
        super::card_lines::runs(self.lines.len(), self.head_tail(expanded))
            .into_iter()
            .filter(|run| !run.is_empty())
            .map(|lines| {
                let offset = |line: &str| line.as_ptr() as usize - self.text.as_ptr() as usize;
                let last = self.lines[lines.end - 1];
                let bytes = offset(self.lines[lines.start])..offset(last) + last.len();
                Part { lines, bytes }
            })
            .collect()
    }
    /// Line `index`'s number in the file, as the card writes it.
    pub fn number(&self, index: usize) -> String {
        super::card_lines::number(self.first_line + index)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bello_agent_core::{
        Message,
        tool_content::{ContentBlock, ReadStats, ToolContent},
        tool_history::{AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome},
    };
    use serde_json::json;
    use std::sync::Arc;

    fn fixture(arguments: Value, text: &str, stats: Option<ReadStats>) -> Session {
        let base = Message {
            task_root_id: None,
            user_content: None,
            id: "owner".into(),
            role: "assistant".into(),
            text: String::new(),
            reasoning: String::new(),
            replay_eligible: true,
            state: "completed".into(),
            usage: Value::Null,
            model: None,
            tool_record: None,
            compaction: None,
        };
        let mut assistant = base.clone();
        assistant.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
            tool_batch_timing: None,
            completion: Completion::Complete,
            calls: vec![ToolCall {
                id: "call".into(),
                name: "read".into(),
                arguments,
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
        let mut result = base;
        result.id = "result".into();
        result.role = "toolResult".into();
        result.text = text.into();
        result.tool_record = Some(ToolRecord::Result(ResultRecord {
            duration_us: None,
            assistant_id: "owner".into(),
            call_id: "call".into(),
            is_error: false,
            outcome: ToolOutcome::Completed,
            content: stats.map(|stats| {
                Arc::new(ToolContent {
                    blocks: vec![ContentBlock::Text { text: text.into() }],
                    stats: Some(stats),
                })
            }),
        }));
        let mut session = Session::new();
        session.messages = vec![assistant, result];
        session
    }
    fn stats() -> ReadStats {
        ReadStats {
            path: "/resolved/name with spaces ".into(),
            line: Some(7),
            last_line: Some(11),
            added: None,
            removed: None,
        }
    }
    #[test]
    fn source_file_links_use_viewer_stats_and_preserve_path_bytes() {
        let session = fixture(
            json!({"path":"relative.txt", "offset":3}),
            "a\rb\nc",
            Some(stats()),
        );
        for row in [
            tool_presentation::project(&session, 0)[0],
            ProjectedRow::Result(1),
        ] {
            assert_eq!(
                file_link(&session, row),
                Some(ReadFileLink {
                    path: "/resolved/name with spaces ".into(),
                    lines: Some(7..=11),
                })
            );
        }
        let legacy = fixture(
            json!({"path":" relative.txt ", "offset":3}),
            "a\nb\n[Truncated. 20 total lines; read another range.]",
            None,
        );
        assert_eq!(
            file_link(&legacy, ProjectedRow::Result(1)),
            Some(ReadFileLink {
                path: " relative.txt ".into(),
                lines: Some(3..=4),
            })
        );
        // Viewer stats never change the card's model LF-based numbering.
        let read = ReadWindow::new(
            &session.messages[1].text,
            &read_call(&session, ProjectedRow::Result(1))
                .unwrap()
                .arguments,
        );
        assert_eq!(read.first_line, 3);
        assert_eq!(read.lines, ["a\rb", "c"]);
    }
    #[test]
    fn whole_files_images_and_failed_reads_do_not_reveal_a_line_range() {
        for (arguments, text, outcome) in [
            (json!({"path":"f"}), "text", ToolOutcome::Completed),
            (
                json!({"path":"f", "offset":3}),
                "Read image file [image/png]",
                ToolOutcome::Completed,
            ),
            (
                json!({"path":"f", "offset":3}),
                "File not found",
                ToolOutcome::Failed,
            ),
            (
                json!({"path":"f", "offset":3}),
                "Cancelled",
                ToolOutcome::Cancelled,
            ),
        ] {
            let mut session = fixture(arguments, text, Some(stats()));
            if let Some(ToolRecord::Result(record)) = &mut session.messages[1].tool_record {
                record.outcome = outcome;
            }
            assert!(
                file_link(&session, ProjectedRow::Result(1))
                    .unwrap()
                    .lines
                    .is_none()
            );
        }
        let mut session = fixture(json!({"path":"f", "offset":3}), "", None);
        session.messages.truncate(1);
        session.state = bello_agent_core::RunState::Running;
        session.active_reply = Some("owner".into());
        assert!(file_link(&session, tool_presentation::project(&session, 0)[0]).is_none());
    }
    #[test]
    fn retained_content_only_changes_and_reopened_allocations_invalidate_rows() {
        let session = fixture(
            json!({"path":"f", "limit":2}),
            "Read image file [image/png]",
            Some(stats()),
        );
        let row = tool_presentation::project(&session, 0)[0];
        let reopened: Session =
            serde_json::from_slice(&serde_json::to_vec(&session).unwrap()).unwrap();
        assert!(!tool_presentation::same_content(
            &session, row, &reopened, row
        ));
        assert!(tool_presentation::same_content(
            &session,
            row,
            &session.clone(),
            row
        ));
        for change in ["path", "range", "image", "missing"] {
            let mut changed = session.clone();
            let Some(ToolRecord::Result(record)) = &mut changed.messages[1].tool_record else {
                panic!()
            };
            if change == "missing" {
                record.content = None;
            } else {
                let content = Arc::make_mut(record.content.as_mut().unwrap());
                match change {
                    "path" => content.stats.as_mut().unwrap().path = "/other/path".into(),
                    "range" => content.stats.as_mut().unwrap().last_line = Some(12),
                    _ => content.blocks.push(ContentBlock::Image {
                        data: "AA==".into(),
                        mime_type: "image/png".into(),
                    }),
                }
            }
            assert!(
                !tool_presentation::same_content(&session, row, &changed, row),
                "{change}"
            );
        }
    }
    #[test]
    fn ambiguous_hidden_owner_does_not_guess_a_read_link() {
        let mut session = fixture(json!({"path":"f"}), "text", None);
        session.messages.push(session.messages[0].clone());
        assert!(file_link(&session, ProjectedRow::Result(1)).is_none());
        session.messages.pop();
        session.messages.swap(0, 1);
        assert!(file_link(&session, ProjectedRow::Result(0)).is_none());
    }

    #[test]
    fn source_note_is_not_a_numbered_file_line() {
        let value = ReadWindow::new(
            "a\nb\n[Truncated. 20 total lines; read another range.]",
            &json!({"offset":3}),
        );
        assert_eq!(value.lines, vec!["a", "b"]);
        assert_eq!(
            value.note,
            Some("Truncated. 20 total lines; read another range.")
        );
        let parts = value.parts(false);
        assert_eq!(parts.len(), 1);
        assert_eq!(&value.text[parts[0].bytes.clone()], "a\nb");
        assert_eq!((value.number(0), value.number(1)), ("3".into(), "4".into()));
    }
    #[test]
    fn head_tail_retains_source_numbers_and_one_extra_line_does_not_collapse() {
        let text = (1..=14)
            .map(|n| format!("row{n}"))
            .collect::<Vec<_>>()
            .join("\n");
        let value = ReadWindow::new(&text, &json!({"offset":20}));
        assert_eq!(value.window_label(false), "Showing 12 of 14 lines");
        assert_eq!(value.window_label(true), "14 lines");
        let parts = value.parts(false);
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0].lines, 0..6);
        assert_eq!(parts[1].lines, 8..14);
        assert!(value.text[parts[0].bytes.clone()].ends_with("row6"));
        assert!(value.text[parts[1].bytes.clone()].starts_with("row9"));
        assert!(value.text[parts[1].bytes.clone()].ends_with("row14"));
        assert_eq!(value.number(5), "25");
        let whole = value.parts(true);
        assert_eq!(whole.len(), 1);
        assert_eq!(&value.text[whole[0].bytes.clone()], text);
        let text = (0..13).map(|_| "a").collect::<Vec<_>>().join("\n");
        assert!(!ReadWindow::new(&text, &json!({})).collapsible());
    }
    #[test]
    fn source_offset_does_not_coerce_boolean_or_string_for_display() {
        for value in [
            json!(true),
            json!("2"),
            json!(-1),
            json!(1.5),
            json!(10_000_001),
        ] {
            assert_eq!(ReadWindow::new("a", &json!({"offset":value})).first_line, 1);
        }
        let value = ReadWindow::new("a\n", &json!({}));
        assert_eq!(value.lines, ["a", ""]);
        assert_eq!(value.parts(false)[0].bytes, 0..2);
        assert_eq!(
            ReadWindow::new("a", &json!({"offset":9999})).number(0),
            "9,999"
        );
        assert_eq!(
            ReadWindow::new("", &json!({})).window_label(false),
            "0 lines"
        );
    }
}
