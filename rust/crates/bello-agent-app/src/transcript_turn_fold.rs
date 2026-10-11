//! Swift 0.1.122's end-of-turn fold (`TranscriptTurnFold`, compact display,
//! Swift's default): when a turn ends with an actual answer, everything that
//! produced the answer — every reply before it, every call, the answer's own
//! thought — folds behind one line above the answer, and the answer is what
//! the reader sees. Every clause is a refusal to hide something the reader
//! might still need: the turn must have ended, ended with words, asked for
//! nothing more, and its own question must be on the page.
use super::{LogicalRow, ProjectedRow, RowKey};
use bello_agent_core::{Message, RunState, Session, tool_history::ToolRecord};
use std::collections::HashSet;

/// How a finished turn reads (Swift's `TranscriptDisplayMode`): Settings'
/// own value, so the transcript follows Settings without translating it.
pub(crate) use crate::app_settings::TranscriptDisplayMode;

/// Where a row stands in a finished turn's fold.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct RowFold {
    /// The turn whose fold holds this row: the row of the question that
    /// opened it (Swift's `foldGroup`, the reader's message id).
    pub group: Option<RowKey>,
    /// The fold is closed: the row draws nothing.
    pub hidden: bool,
    /// The answer's own Think line folds with its turn; its words never do.
    pub think_hidden: bool,
    /// The answer's own header line folds with the work it summarises, so a
    /// folded turn reads as one line and the answer.
    pub header_hidden: bool,
    /// Set on the one row that is a turn's fold control.
    pub control: Option<Control>,
}

/// A fold control's line (`TurnFoldSpec`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Control {
    pub label: String,
    pub open: bool,
}

/// `TurnFoldSpec.label`: "3 tool calls · 1 message", "2 subagents", and for
/// a turn that only thought, the line that says so without counting.
pub(super) fn label(tool_calls: usize, messages: usize, subagents: usize) -> String {
    let plural = |n: usize, one: &str| format!("{n} {one}{}", if n == 1 { "" } else { "s" });
    let parts: Vec<String> = [
        (tool_calls, "tool call"),
        (messages, "message"),
        (subagents, "subagent"),
    ]
    .into_iter()
    .filter(|(n, _)| *n > 0)
    .map(|(n, one)| plural(n, one))
    .collect();
    if parts.is_empty() {
        "Thought for a while".into()
    } else {
        parts.join(" · ")
    }
}

/// `TurnFoldSpec.isSubagent`: a delegation call is a subagent, not a tool call.
pub(super) fn subagent(name: &str) -> bool {
    name == "subagent" || name.starts_with("subagent_")
}

/// Whether text holds anything but whitespace.
fn visible(text: &str) -> bool {
    text.chars().any(|c| !c.is_whitespace())
}

/// Rows no fold touches: the reader's own messages and the compaction record.
fn independent(message: &Message) -> bool {
    matches!(message.role.as_str(), "user" | "system") || message.compaction.is_some()
}

fn made_calls(message: &Message) -> bool {
    matches!(&message.tool_record, Some(ToolRecord::Assistant(record)) if !record.calls.is_empty())
}

/// What the turn did or said, as opposed to the rows no fold touches.
/// Words that are only whitespace say nothing.
fn content(session: &Session, row: &LogicalRow) -> bool {
    match row.projected {
        Some(ProjectedRow::Message(index)) => {
            let message = &session.messages[index];
            !independent(message)
                && (message.role != "assistant"
                    || visible(&message.text)
                    || visible(&message.reasoning))
        }
        Some(_) => true,
        None => false,
    }
}

/// A row still being produced keeps its whole turn loose.
fn live(session: &Session, row: &LogicalRow) -> bool {
    row.message_index
        .is_some_and(|index| session.messages[index].state == "streaming")
        || row.projected.is_some_and(|projected| {
            matches!(
                super::tool_presentation::status(session, projected),
                super::tool_presentation::Status::Running
                    | super::tool_presentation::Status::Awaiting
            )
        })
}

/// Folds every finished turn of the page: marks the rows each fold holds and
/// inserts each fold's control above the first of them.
/// `opened` holds the reader's choices: an open fold is its control's key.
pub(super) fn apply(rows: &mut Vec<LogicalRow>, session: &Session, opened: &HashSet<RowKey>) {
    let questions: Vec<usize> = rows
        .iter()
        .enumerate()
        .filter(|(_, row)| {
            matches!(row.projected, Some(ProjectedRow::Message(index))
                if session.messages[index].role == "user")
        })
        .map(|(index, _)| index)
        .collect();
    let mut inserts = Vec::new();
    for (n, &question) in questions.iter().enumerate() {
        let end = questions.get(n + 1).copied().unwrap_or(rows.len());
        // The turn the host is running keeps every row it has: a fold is what
        // the end of a turn does, never something a reader watches happen.
        let running = end == rows.len() && session.state == RunState::Running;
        if running {
            continue;
        }
        if let Some(control) = fold(rows, session, question, question + 1..end, opened) {
            inserts.push(control);
        }
    }
    for (at, row) in inserts.into_iter().rev() {
        rows.insert(at, row);
    }
}

fn fold(
    rows: &mut [LogicalRow],
    session: &Session,
    question: usize,
    range: std::ops::Range<usize>,
    opened: &HashSet<RowKey>,
) -> Option<(usize, LogicalRow)> {
    if range.is_empty() || rows[range.clone()].iter().any(|row| live(session, row)) {
        return None;
    }
    // The answer is the reply the turn's last content belongs to. It must
    // have said something and asked for nothing more: a reply that made a
    // call did not end its turn.
    let last = range
        .clone()
        .rev()
        .find(|&index| content(session, &rows[index]))?;
    let Some(ProjectedRow::Message(answer)) = rows[last].projected else {
        return None;
    };
    let reply = &session.messages[answer];
    if reply.role != "assistant" || made_calls(reply) || !visible(&reply.text) {
        return None;
    }
    let group = rows[question].key.clone();
    let key = RowKey::Fold(Box::new(group.clone()));
    let mut members = Vec::new();
    let (mut tool_calls, mut subagents) = (0, 0);
    let mut messages = HashSet::new();
    for index in range.clone() {
        let row = &rows[index];
        match row.projected {
            Some(ProjectedRow::Message(source)) => {
                let message = &session.messages[source];
                if independent(message) || index == last {
                    continue;
                }
                // Another reply that said something before the answer.
                if message.role == "assistant" && visible(&message.text) {
                    messages.insert(source);
                }
            }
            Some(ProjectedRow::Call {
                assistant, call, ..
            }) => {
                let name = &super::tool_presentation::call_at(session, assistant, call).name;
                if subagent(name) {
                    subagents += 1;
                } else {
                    tool_calls += 1;
                }
            }
            Some(ProjectedRow::Result(_)) => {}
            None => continue,
        }
        members.push(index);
    }
    let thought = visible(&reply.reasoning);
    // An answer with no work under it has nothing to fold.
    if members.is_empty() && !thought {
        return None;
    }
    let closed = !opened.contains(&key);
    for &index in &members {
        rows[index].fold = RowFold {
            group: Some(group.clone()),
            hidden: closed,
            ..RowFold::default()
        };
    }
    rows[last].fold = RowFold {
        // Only a thought ties the answer's row to its fold: a find in the
        // answer's words never opens the work above it.
        group: thought.then(|| group.clone()),
        think_hidden: thought && closed,
        header_hidden: closed,
        ..RowFold::default()
    };
    let at = members.first().copied().unwrap_or(last);
    Some((
        at,
        LogicalRow {
            key,
            message_index: None,
            projected: None,
            expanded: false,
            read_expanded: false,
            read_key: None,
            response: Default::default(),
            fold: RowFold {
                control: Some(Control {
                    label: label(tool_calls, messages.len(), subagents),
                    open: !closed,
                }),
                ..RowFold::default()
            },
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::{TranscriptDisplayMode, label};

    #[test]
    fn a_fold_line_counts_as_swift_counts() {
        assert_eq!(label(0, 0, 0), "Thought for a while");
        assert_eq!(label(1, 0, 0), "1 tool call");
        assert_eq!(label(3, 1, 0), "3 tool calls · 1 message");
        assert_eq!(label(0, 2, 2), "2 messages · 2 subagents");
        assert_eq!(label(2, 0, 1), "2 tool calls · 1 subagent");
    }

    #[test]
    fn the_display_modes_read_as_swifts_and_compact_is_the_default() {
        assert_eq!(
            TranscriptDisplayMode::default(),
            TranscriptDisplayMode::Compact
        );
        assert_eq!(TranscriptDisplayMode::Normal.label(), "Normal");
        assert_eq!(TranscriptDisplayMode::Compact.label(), "Compact");
        assert_eq!(
            TranscriptDisplayMode::Normal.detail(),
            "A finished turn keeps every tool call and thought on screen."
        );
        assert_eq!(
            TranscriptDisplayMode::Compact.detail(),
            "A finished turn folds its work behind one line above the answer."
        );
    }
}
