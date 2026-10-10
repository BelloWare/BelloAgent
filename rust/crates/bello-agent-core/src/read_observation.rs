//! Read attention evidence for the representations actually retained by Rust.
//!
//! Streaming tool/timeline-only partials discarded by Session::delta cannot be
//! reconstructed here. Accepted failure occurrences are retained for this writer
//! lifetime, not crash-durable events. Neither limitation warrants guessing from
//! usage, a display Error overlay, or the existence of a streaming placeholder.
use crate::{RunState, Session, tool_history::ToolRecord};
use std::collections::BTreeSet;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OutputSummary {
    pub count: u64,
    pub latest_id: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OutputProjection {
    Known(OutputSummary),
    Unknown,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AcceptedTerminal {
    /// Monotonic within generation. Zero is never an accepted terminal.
    pub sequence: u64,
    pub source_revision: u64,
    pub history: OutputProjection,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AcceptedReadObservation {
    /// New writer lifetime, not a durable session generation or catalog cursor.
    pub generation: String,
    pub source_revision: u64,
    pub history: OutputProjection,
    pub busy: bool,
    /// Retained across Retry/Resume/start and later live publications.
    pub terminal: Option<AcceptedTerminal>,
    /// Cumulative accepted transitions into Error; never reset by Retry/opening.
    /// Consumers remember a per-generation consumed sequence when clearing it.
    pub failure_sequence: u64,
}

/// Exact count/latest identity for authoritative, validated retained history.
/// Unknown is a refusal to baseline or acknowledge, never an empty history.
/// Receipt ownership, rather than state-name prefixes, identifies utility rows.
pub fn project_outputs(session: &Session) -> OutputProjection {
    project_checked(session).map_or(OutputProjection::Unknown, OutputProjection::Known)
}
fn project_checked(session: &Session) -> Option<OutputSummary> {
    session.validate_checkpoint().ok()?;
    if !(1..=10).contains(&session.version) || uuid::Uuid::parse_str(&session.id).is_err() {
        return None;
    }
    let progress: BTreeSet<&str> = session
        .context_recoveries
        .iter()
        .map(|receipt| receipt.progress_id.as_str())
        .chain(
            session
                .compaction
                .iter()
                .chain(&session.compaction_history)
                .map(|operation| operation.progress_id.as_str()),
        )
        .collect();
    let rejected: BTreeSet<&str> = session
        .context_recoveries
        .iter()
        .map(|receipt| receipt.failed_reply_id.as_str())
        .collect();
    let mut identities = BTreeSet::new();
    let mut summary = OutputSummary::default();
    for row in &session.messages {
        if row.id.is_empty()
            || row.id.len() > 256
            || row.id.chars().any(char::is_control)
            || !identities.insert(row.id.as_str())
        {
            return None;
        }
        if row.role != "assistant" {
            continue;
        }
        if progress.contains(row.id.as_str()) {
            continue;
        }
        let count = match &row.tool_record {
            Some(ToolRecord::Assistant(record)) => {
                // Production begin_tools (including its original v3 writer)
                // accepts only complete calls. Stop/recovery retains that row;
                // a later image-delivery failure may finish it as interrupted.
                // The replay validator alone deliberately admits broader inert
                // fixture/import shapes, which do not prove accepted output.
                if record.completion != crate::tool_history::Completion::Complete {
                    return None;
                }
                match (row.state.as_str(), row.replay_eligible) {
                    ("completed", true) | ("interrupted", false) => true,
                    _ => return None,
                }
            }
            Some(ToolRecord::Result(_)) => return None,
            None if row.compaction.is_some() || row.user_content.is_some() => return None,
            None => match row.state.as_str() {
                "completed" | "incomplete" if row.replay_eligible => true,
                "interrupted" if !row.replay_eligible => {
                    !row.text.is_empty() || !row.reasoning.is_empty()
                }
                "context-rejected"
                    if !row.replay_eligible && rejected.contains(row.id.as_str()) =>
                {
                    !row.text.is_empty() || !row.reasoning.is_empty()
                }
                // A reply deferred by a threshold compaction was never requested.
                crate::context_recovery::DEFERRED_STATE
                    if !row.replay_eligible && rejected.contains(row.id.as_str()) =>
                {
                    false
                }
                "streaming"
                    if !row.replay_eligible
                        && session.state == RunState::Running
                        && session.active_reply.as_deref() == Some(row.id.as_str()) =>
                {
                    false
                }
                _ => return None,
            },
        };
        if count {
            summary.count = summary.count.checked_add(1)?;
            if summary.count > 100_000 {
                return None;
            }
            summary.latest_id = Some(row.id.clone());
        }
    }
    Some(summary)
}

impl AcceptedReadObservation {
    pub(crate) fn initial(session: &Session) -> Self {
        Self {
            generation: uuid::Uuid::new_v4().to_string(),
            source_revision: session.revision,
            history: project_outputs(session),
            busy: session.state == RunState::Running,
            terminal: None,
            failure_sequence: 0,
        }
    }
    /// Only SessionStore's confirmed-checkpoint success branch calls this.
    /// Every checkpoint is an accepted boundary; stream journal deltas are not.
    pub(crate) fn accept(&mut self, before: &Session, after: &Session) {
        self.source_revision = after.revision;
        // Exhausted sequences remain fail-closed on all later checkpoints.
        if self.failure_sequence == u64::MAX
            || self
                .terminal
                .as_ref()
                .is_some_and(|terminal| terminal.sequence == u64::MAX)
        {
            self.invalidate();
            return;
        }
        self.history = project_outputs(after);
        self.busy = after.state == RunState::Running;
        let failed = before.state != RunState::Error && after.state == RunState::Error;
        let terminal = (before.state == RunState::Running && !self.busy) || failed;
        if failed {
            match self.failure_sequence.checked_add(1) {
                Some(sequence) => self.failure_sequence = sequence,
                None => {
                    self.invalidate();
                    return;
                }
            }
        }
        if terminal {
            let sequence = self
                .terminal
                .as_ref()
                .map_or(0, |terminal| terminal.sequence)
                .checked_add(1);
            match sequence {
                Some(sequence) => {
                    self.terminal = Some(AcceptedTerminal {
                        sequence,
                        source_revision: after.revision,
                        history: self.history.clone(),
                    })
                }
                None => self.invalidate(),
            }
        }
    }
    pub(crate) fn invalidate(&mut self) {
        self.history = OutputProjection::Unknown;
        if let Some(terminal) = &mut self.terminal {
            terminal.history = OutputProjection::Unknown;
        }
    }
}

#[cfg(test)]
#[path = "read_observation_tests.rs"]
mod tests;
