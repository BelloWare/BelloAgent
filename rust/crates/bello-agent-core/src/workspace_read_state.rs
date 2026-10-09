//! Durable reply obligations and pure read-state transitions. Presentation grace
//! never removes an obligation from this model; callers may hide only its new
//! portion for 600 ms and must persist the complete transition before admission.
use crate::read_observation::{AcceptedReadObservation, OutputProjection, OutputSummary};
use crate::workspace::{ChatMaterialization, ChatRecord};
use crate::{Result, invalid};
use serde::{Deserialize, Serialize};

pub const MAX_READ_OUTPUTS: u64 = 100_000;
pub const VISIBLE_REPLY_GRACE_MS: u64 = 600;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ChatReadState {
    pub observed_count: u64,
    pub latest_id: Option<String>,
    pub unread_count: u64,
    pub unread_target_id: Option<String>,
    pub manual_unread: bool,
    pub baseline_pending: bool,
    pub unread_failure: bool,
    pub revision: u64,
    /// Controller lifetime, not a session identity or a source of authority.
    pub consumed_generation: Option<String>,
    pub consumed_terminal_sequence: u64,
    pub consumed_failure_sequence: u64,
    pub source_revision: u64,
}
impl Default for ChatReadState {
    fn default() -> Self {
        Self {
            observed_count: 0,
            latest_id: None,
            unread_count: 0,
            unread_target_id: None,
            manual_unread: false,
            baseline_pending: true,
            unread_failure: false,
            revision: 0,
            consumed_generation: None,
            consumed_terminal_sequence: 0,
            consumed_failure_sequence: 0,
            source_revision: 0,
        }
    }
}
impl ChatReadState {
    pub fn validate(&self) -> Result<()> {
        validate_summary(&OutputSummary {
            count: self.observed_count,
            latest_id: self.latest_id.clone(),
        })?;
        if self.unread_count > MAX_READ_OUTPUTS
            || (self.unread_count == 0) != self.unread_target_id.is_none()
            || self
                .unread_target_id
                .as_deref()
                .is_some_and(|id| !valid_output_id(id))
            || (self.baseline_pending && (self.observed_count != 0 || self.unread_count != 0))
            || self
                .consumed_generation
                .as_ref()
                .is_some_and(|id| uuid::Uuid::parse_str(id).is_err())
            || (self.consumed_generation.is_none()
                && (self.consumed_terminal_sequence != 0
                    || self.consumed_failure_sequence != 0
                    || self.source_revision != 0))
            || self.consumed_failure_sequence > self.consumed_terminal_sequence
        {
            return Err(invalid("Invalid workspace read state"));
        }
        Ok(())
    }
    pub fn row_count(&self, archived: bool) -> u64 {
        if archived {
            0
        } else {
            self.unread_count.max(u64::from(self.manual_unread))
        }
    }
    pub fn has_attention(&self, archived: bool) -> bool {
        !archived && (self.row_count(false) != 0 || self.unread_failure)
    }
    pub fn dock_chat(&self, archived: bool) -> bool {
        !archived && (self.manual_unread || (self.unread_count != 0 && !self.unread_failure))
    }
    pub fn manual_only(&self, archived: bool) -> bool {
        !archived && self.manual_unread && self.unread_count == 0
    }
}

pub fn can_mark_read(
    record: Option<&ChatRecord>,
    restored: bool,
    state: Option<&ChatReadState>,
) -> bool {
    restored && eligible(record) && state.is_some_and(|state| state.has_attention(false))
}
pub fn can_mark_unread(
    record: Option<&ChatRecord>,
    restored: bool,
    state: Option<&ChatReadState>,
) -> bool {
    restored && eligible(record) && !state.is_some_and(|state| state.has_attention(false))
}
fn eligible(record: Option<&ChatRecord>) -> bool {
    record.is_some_and(|record| {
        record.archived_at.is_none()
            && record.materialization == ChatMaterialization::CheckpointRequired
    })
}
fn valid_output_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 256 && !id.chars().any(char::is_control)
}
fn validate_summary(summary: &OutputSummary) -> Result<()> {
    if summary.count > MAX_READ_OUTPUTS
        || (summary.count == 0) != summary.latest_id.is_none()
        || summary
            .latest_id
            .as_deref()
            .is_some_and(|id| !valid_output_id(id))
    {
        return Err(invalid("Invalid assistant output summary"));
    }
    Ok(())
}

pub enum ReadEvent<'a> {
    /// The caller may keep the first baseline entirely in memory. It must save
    /// that baseline before admitting any operation capable of producing output.
    Baseline(&'a OutputSummary),
    /// Authoritative, idle leased inspection. Unknown or busy inspections must
    /// not invoke this event. It never infers a historical failure occurrence.
    Inspect(&'a OutputSummary),
    Observe {
        observation: &'a AcceptedReadObservation,
        reader_present: bool,
    },
    MarkUnread,
    MarkRead,
    /// Automatic startup/recovery is not an opening. Same-row reselection is an
    /// opening for failures only; changed focus also clears the manual marker.
    Opened {
        changed_focus: bool,
    },
    /// Caller proves exact chat/controller/presentation identity and actual
    /// reply-end visibility on an active unobscured reading surface first.
    Acknowledge {
        target: &'a str,
    },
}

/// No I/O, clocks, materialization, or semantic activity. A no-op returns the
/// exact prior value. Revision allocation is checked and happens only on change.
pub fn reduce_read_state(
    current: Option<&ChatReadState>,
    event: ReadEvent<'_>,
) -> Result<Option<ChatReadState>> {
    if let Some(current) = current {
        current.validate()?;
    }
    let mut next = current.cloned().unwrap_or_default();
    match event {
        ReadEvent::Baseline(summary) => {
            validate_summary(summary)?;
            if !next.baseline_pending {
                return Ok(current.cloned());
            }
            baseline(&mut next, summary);
        }
        ReadEvent::Inspect(summary) => {
            validate_summary(summary)?;
            apply_summary(&mut next, summary)?;
        }
        ReadEvent::Observe {
            observation,
            reader_present,
        } => {
            // An unknown current history cannot manufacture either a baseline
            // or an acknowledgement, even when a prior terminal was known.
            let OutputProjection::Known(history) = &observation.history else {
                return Ok(current.cloned());
            };
            validate_summary(history)?;
            if uuid::Uuid::parse_str(&observation.generation).is_err() {
                return Err(invalid("Invalid read observation generation"));
            }
            let same_generation =
                next.consumed_generation.as_deref() == Some(observation.generation.as_str());
            if same_generation && observation.source_revision < next.source_revision {
                return Ok(current.cloned());
            }
            let terminal_sequence = observation
                .terminal
                .as_ref()
                .map_or(0, |terminal| terminal.sequence);
            if observation.failure_sequence > terminal_sequence
                || observation.terminal.as_ref().is_some_and(|terminal| {
                    terminal.sequence == 0 || terminal.source_revision > observation.source_revision
                })
                || (same_generation
                    && (terminal_sequence < next.consumed_terminal_sequence
                        || observation.failure_sequence < next.consumed_failure_sequence))
            {
                return Err(invalid("Invalid accepted read observation sequence"));
            }
            let was_pending = next.baseline_pending;
            if was_pending {
                baseline(&mut next, history);
            }
            let consumed_terminal = if same_generation {
                next.consumed_terminal_sequence
            } else {
                0
            };
            let consumed_failure = if same_generation {
                next.consumed_failure_sequence
            } else {
                0
            };
            if !was_pending {
                if terminal_sequence > consumed_terminal {
                    let terminal = observation
                        .terminal
                        .as_ref()
                        .expect("positive terminal sequence");
                    let OutputProjection::Known(summary) = &terminal.history else {
                        return Ok(current.cloned());
                    };
                    validate_summary(summary)?;
                    apply_summary(&mut next, summary)?;
                } else if !observation.busy {
                    apply_summary(&mut next, history)?;
                }
            }
            if observation.failure_sequence > consumed_failure && !reader_present {
                next.unread_failure = true;
            }
            next.consumed_generation = Some(observation.generation.clone());
            next.consumed_terminal_sequence = terminal_sequence;
            next.consumed_failure_sequence = observation.failure_sequence;
            next.source_revision = observation.source_revision;
        }
        ReadEvent::MarkUnread => {
            if next.has_attention(false) {
                return Ok(current.cloned());
            }
            next.manual_unread = true;
        }
        ReadEvent::MarkRead => {
            if current.is_none() {
                return Ok(None);
            }
            next.unread_count = 0;
            next.unread_target_id = None;
            next.manual_unread = false;
            next.unread_failure = false;
        }
        ReadEvent::Opened { changed_focus } => {
            if current.is_none() {
                return Ok(None);
            }
            if changed_focus {
                next.manual_unread = false;
            }
            next.unread_failure = false;
        }
        ReadEvent::Acknowledge { target } => {
            // Old rows, failed placeholders and unknown/replaced targets cannot
            // dismiss a newer obligation. Manual unread intentionally survives.
            if next.baseline_pending
                || next.latest_id.as_deref() != Some(target)
                || (next.unread_count != 0 && next.unread_target_id.as_deref() != Some(target))
            {
                return Ok(current.cloned());
            }
            next.unread_count = 0;
            next.unread_target_id = None;
            next.unread_failure = false;
        }
    }
    if current == Some(&next) {
        return Ok(current.cloned());
    }
    next.revision = next
        .revision
        .checked_add(1)
        .ok_or_else(|| invalid("Read-state revision overflow"))?;
    next.validate()?;
    Ok(Some(next))
}
fn baseline(state: &mut ChatReadState, summary: &OutputSummary) {
    state.observed_count = summary.count;
    state.latest_id = summary.latest_id.clone();
    state.baseline_pending = false;
}
fn apply_summary(state: &mut ChatReadState, summary: &OutputSummary) -> Result<()> {
    if state.baseline_pending {
        baseline(state, summary);
        return Ok(());
    }
    if summary.count > state.observed_count {
        if summary.latest_id == state.latest_id {
            return Err(invalid("Output count increased without a new identity"));
        }
        state.unread_count = state
            .unread_count
            .checked_add(summary.count - state.observed_count)
            .filter(|count| *count <= MAX_READ_OUTPUTS)
            .ok_or_else(|| invalid("Unread output count overflow"))?;
        state.unread_target_id = summary.latest_id.clone();
    }
    // A restored/replaced history never manufactures replies. Retain existing
    // obligations until explicit Mark as Read or a later exact newest target.
    baseline(state, summary);
    Ok(())
}

#[cfg(test)]
#[path = "workspace_read_state_tests.rs"]
mod tests;
