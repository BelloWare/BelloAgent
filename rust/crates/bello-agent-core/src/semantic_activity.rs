//! Nonpersistent, latest-value semantic activity. Session watches can coalesce a
//! complete run; this independent watermark retains its last accepted boundary.
//!
//! Event matrix (Swift 6319 WorkspaceRun/WorkspaceRunHolds/QueuePanel):
//! - accepted outgoing/follow-up/steering input, including attachments and skills;
//! - first accepted queued Save, even with unchanged text;
//! - live hold-category changes, including start, pause, completion and failure.
//!
//! Rejected/replayed Save, Stop requests without transition, stream/reasoning/tool
//! chunks, usage/timing, drafts, titles, queue reorder and inspection are neutral.
//! Construction/reopen establishes a baseline, never activity. Automatic context
//! recovery and tool continuation retain Active; their terminal changes still count.
//! The current Rust API has no independent transcript edit/resend workflow.
use super::Controller;
use crate::{RunState, Session};
use std::time::{SystemTime, UNIX_EPOCH};

/// An actor-local sequence and captured Unix-microsecond maximum. Construction
/// (including reopened/recovered sessions) starts empty. This is not a durable
/// journal cursor, stream revision, or evidence that catalog persistence finished.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SemanticActivity {
    pub sequence: u64,
    /// None until an event has a representable wall-clock timestamp. Clock
    /// rollback never lowers a prior timestamp; no artificial ordering is added.
    pub timestamp_micros: Option<u64>,
}
impl SemanticActivity {
    fn record(&mut self, timestamp_micros: Option<u64>) {
        // Exhaustion must not wrap to the initial baseline or prevent terminal
        // publication. Watch notification still occurs at the saturated value.
        if let Some(sequence) = self.sequence.checked_add(1) {
            self.sequence = sequence;
        }
        self.timestamp_micros = self.timestamp_micros.max(timestamp_micros);
    }
}

#[derive(PartialEq, Eq)]
pub(super) enum RunHold {
    None,
    Active,
    Paused,
}
/// Swift WorkspaceRunHolds.runHold categories supported by this runtime. Tool
/// waiting remains RunState::Running; tool chunks/timing never change the key.
/// Error ends the active hold. Recovery is baselined by Controller construction,
/// rather than inferred from journal contents or historical error strings.
/// This is intentionally narrower than sidebar status presentation: exact Swift
/// runHold requires queued work for its Idle + queuePaused fallback, whereas an
/// explicit Paused state remains held even with an empty queue. Do not substitute
/// a broader display-status classifier here.
pub(super) fn run_hold(session: &Session) -> RunHold {
    match session.state {
        RunState::Running => RunHold::Active,
        RunState::Paused => RunHold::Paused,
        RunState::Idle if session.queue_paused && !session.pending.is_empty() => RunHold::Paused,
        RunState::Idle | RunState::Error => RunHold::None,
    }
}

impl Controller {
    pub fn activity(&self) -> SemanticActivity {
        *self.semantic_activity.borrow()
    }
    pub fn subscribe_activity(&self) -> tokio::sync::watch::Receiver<SemanticActivity> {
        self.semantic_activity.subscribe()
    }
    /// Called under the existing actor serialization, only after acceptance or
    /// a genuine published live hold change. Never performs IO or grabs another
    /// actor lock. Timestamp capture precedes any asynchronous catalog write.
    pub(super) fn note_semantic_activity(&self) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()
            .and_then(|elapsed| u64::try_from(elapsed.as_micros()).ok());
        self.semantic_activity
            .send_modify(|activity| activity.record(now));
    }
}

#[cfg(test)]
#[path = "semantic_activity_tests.rs"]
mod tests;
