use super::*;
use crate::read_observation::AcceptedTerminal;
fn summary(count: u64, id: &str) -> OutputSummary {
    OutputSummary {
        count,
        latest_id: (count != 0).then(|| id.to_owned()),
    }
}
fn reduce(current: Option<&ChatReadState>, event: ReadEvent<'_>) -> ChatReadState {
    reduce_read_state(current, event).unwrap().unwrap()
}
fn observation(count: u64, id: &str) -> AcceptedReadObservation {
    AcceptedReadObservation {
        generation: uuid::Uuid::new_v4().to_string(),
        source_revision: 1,
        history: OutputProjection::Known(summary(count, id)),
        busy: false,
        terminal: None,
        failure_sequence: 0,
    }
}
fn terminal(observation: &mut AcceptedReadObservation, count: u64, id: &str, failed: bool) {
    observation.source_revision += 1;
    observation.history = OutputProjection::Known(summary(count, id));
    observation.busy = false;
    observation.terminal = Some(AcceptedTerminal {
        sequence: observation.terminal.as_ref().map_or(1, |t| t.sequence + 1),
        source_revision: observation.source_revision,
        history: observation.history.clone(),
    });
    observation.failure_sequence += u64::from(failed);
}
fn observe(state: Option<&ChatReadState>, observation: &AcceptedReadObservation) -> ChatReadState {
    reduce(
        state,
        ReadEvent::Observe {
            observation,
            reader_present: false,
        },
    )
}
#[test]
fn historical_baseline_is_not_unread_and_unknown_never_baselines() {
    let mut o = observation(20, "old");
    o.history = OutputProjection::Unknown;
    assert_eq!(
        reduce_read_state(
            None,
            ReadEvent::Observe {
                observation: &o,
                reader_present: false
            }
        )
        .unwrap(),
        None
    );
    o.history = OutputProjection::Known(summary(20, "old"));
    let state = observe(None, &o);
    assert_eq!(state.observed_count, 20);
    assert_eq!(state.unread_count, 0);
    assert!(!state.baseline_pending);
    assert_eq!(observe(Some(&state), &o), state);
}
#[test]
fn manual_before_busy_observation_baselines_without_inventing_replies() {
    let state = reduce(None, ReadEvent::MarkUnread);
    assert!(state.baseline_pending && state.manual_unread);
    let mut o = observation(10, "round");
    o.busy = true;
    let state = observe(Some(&state), &o);
    assert!(!state.baseline_pending);
    assert!(state.manual_unread);
    assert_eq!(state.unread_count, 0);
    terminal(&mut o, 11, "final", false);
    let state = observe(Some(&state), &o);
    assert_eq!(state.unread_count, 1);
    assert_eq!(state.row_count(false), 1);
    let state = reduce(Some(&state), ReadEvent::Acknowledge { target: "final" });
    assert!(state.manual_unread);
    assert_eq!(state.unread_count, 0);
}
#[test]
fn tool_rounds_wait_for_terminal_and_completion_start_coalescing_is_lossless() {
    let mut o = observation(2, "old");
    let state = observe(None, &o);
    o.source_revision += 1;
    o.history = OutputProjection::Known(summary(4, "tool-round"));
    o.busy = true;
    let state = observe(Some(&state), &o);
    assert_eq!(state.observed_count, 2);
    assert_eq!(state.unread_count, 0);
    terminal(&mut o, 5, "final", false);
    o.busy = true;
    o.source_revision += 1;
    o.history = OutputProjection::Known(summary(6, "next-run-tool"));
    let state = observe(Some(&state), &o);
    assert_eq!(state.observed_count, 5);
    assert_eq!(state.unread_count, 3);
    assert_eq!(state.unread_target_id.as_deref(), Some("final"));
    assert_eq!(observe(Some(&state), &o), state);
    terminal(&mut o, 7, "next-final", false);
    let state = observe(Some(&state), &o);
    assert_eq!(state.unread_count, 5);
    assert_eq!(state.unread_target_id.as_deref(), Some("next-final"));
}
#[test]
fn failure_retry_coalescing_and_clear_does_not_recreate_old_failure() {
    let mut o = observation(0, "");
    let state = observe(None, &o);
    terminal(&mut o, 0, "", true);
    o.busy = true;
    o.source_revision += 1;
    let state = observe(Some(&state), &o);
    assert!(state.unread_failure);
    assert_eq!(state.row_count(false), 0);
    assert!(!state.dock_chat(false));
    let state = reduce(
        Some(&state),
        ReadEvent::Opened {
            changed_focus: false,
        },
    );
    assert!(!observe(Some(&state), &o).unread_failure);
    terminal(&mut o, 0, "", true);
    assert!(observe(Some(&state), &o).unread_failure);
    let visible = reduce(
        Some(&state),
        ReadEvent::Observe {
            observation: &o,
            reader_present: true,
        },
    );
    assert!(!visible.unread_failure);
    assert_eq!(visible.consumed_failure_sequence, 2);
}
#[test]
fn changed_focus_and_same_row_semantics_preserve_automatic_obligations() {
    let mut o = observation(0, "");
    let state = observe(None, &o);
    let state = reduce(Some(&state), ReadEvent::MarkUnread);
    terminal(&mut o, 1, "reply", true);
    let state = observe(Some(&state), &o);
    let same = reduce(
        Some(&state),
        ReadEvent::Opened {
            changed_focus: false,
        },
    );
    assert!(same.manual_unread && !same.unread_failure);
    assert_eq!(same.unread_count, 1);
    let changed = reduce(
        Some(&state),
        ReadEvent::Opened {
            changed_focus: true,
        },
    );
    assert!(!changed.manual_unread && !changed.unread_failure);
    assert_eq!(changed.unread_count, 1);
}
#[test]
fn exact_latest_ack_only_and_mark_read_clears_abandoned_target() {
    let state = reduce(None, ReadEvent::Baseline(&summary(1, "old")));
    let state = reduce(Some(&state), ReadEvent::Inspect(&summary(3, "new")));
    assert_eq!(
        reduce(Some(&state), ReadEvent::Acknowledge { target: "old" }),
        state
    );
    let rolled_back = reduce(Some(&state), ReadEvent::Inspect(&summary(1, "replacement")));
    assert_eq!(rolled_back.unread_count, 2);
    assert_eq!(rolled_back.observed_count, 1);
    assert_eq!(
        reduce(Some(&rolled_back), ReadEvent::Acknowledge { target: "new" }),
        rolled_back
    );
    assert_eq!(
        reduce(
            Some(&rolled_back),
            ReadEvent::Acknowledge {
                target: "replacement"
            }
        ),
        rolled_back
    );
    let cleared = reduce(Some(&rolled_back), ReadEvent::MarkRead);
    assert!(!cleared.has_attention(false));
    assert_eq!(cleared.unread_target_id, None);
}
#[test]
fn grace_is_presentation_only_and_full_obligation_survives_serialization() {
    let state = reduce(None, ReadEvent::Baseline(&summary(0, "")));
    let state = reduce(Some(&state), ReadEvent::Inspect(&summary(2, "previous")));
    let next = reduce(Some(&state), ReadEvent::Inspect(&summary(3, "held-newest")));
    let held = next.unread_count - state.unread_count;
    assert_eq!(held, 1);
    assert_eq!(next.unread_count - held, 2); // prior attention stays visible
    let restored: ChatReadState =
        serde_json::from_slice(&serde_json::to_vec(&next).unwrap()).unwrap();
    assert_eq!(restored.unread_count, 3);
    assert_eq!(restored.observed_count, 3);
    assert_eq!(restored.unread_target_id.as_deref(), Some("held-newest"));
    assert_eq!(VISIBLE_REPLY_GRACE_MS, 600);
}
#[test]
fn attention_matrix_archives_failures_manual_and_automatic() {
    for archived in [false, true] {
        for automatic in [0, 1, 7] {
            for manual in [false, true] {
                for failure in [false, true] {
                    let state = ChatReadState {
                        unread_count: automatic,
                        manual_unread: manual,
                        unread_failure: failure,
                        ..Default::default()
                    };
                    assert_eq!(
                        state.row_count(archived),
                        if archived {
                            0
                        } else {
                            automatic.max(u64::from(manual))
                        }
                    );
                    assert_eq!(
                        state.has_attention(archived),
                        !archived && (automatic > 0 || manual || failure)
                    );
                    assert_eq!(
                        state.dock_chat(archived),
                        !archived && (manual || (automatic > 0 && !failure))
                    );
                    assert_eq!(
                        state.manual_only(archived),
                        !archived && manual && automatic == 0
                    );
                }
            }
        }
    }
}
#[test]
fn manual_action_eligibility_matches_for_saved_pending_archived_and_unrestored() {
    let mut chat = ChatRecord::new(
        uuid::Uuid::new_v4().to_string(),
        "Chat".into(),
        "/tmp/chat.json".into(),
    );
    let unread = reduce(None, ReadEvent::MarkUnread);
    assert!(can_mark_unread(Some(&chat), true, None));
    assert!(can_mark_read(Some(&chat), true, Some(&unread)));
    assert!(!can_mark_unread(Some(&chat), true, Some(&unread)));
    for restored in [false, true] {
        assert!(!can_mark_unread(None, restored, None));
        assert!(!can_mark_read(None, restored, Some(&unread)));
    }
    assert!(!can_mark_unread(Some(&chat), false, None));
    chat.materialization = ChatMaterialization::Pending;
    assert!(!can_mark_unread(Some(&chat), true, None));
    assert!(!can_mark_read(Some(&chat), true, Some(&unread)));
    chat.materialization = ChatMaterialization::CheckpointRequired;
    chat.archived_at = Some(1);
    assert!(!can_mark_unread(Some(&chat), true, None));
    assert!(!can_mark_read(Some(&chat), true, Some(&unread)));
}
#[test]
fn malformed_and_overflow_transitions_are_atomic_and_noop_can_keep_max_revision() {
    let mut state = reduce(None, ReadEvent::Baseline(&summary(0, "")));
    state.revision = u64::MAX;
    assert_eq!(reduce(Some(&state), ReadEvent::MarkRead), state);
    assert!(reduce_read_state(Some(&state), ReadEvent::MarkUnread).is_err());
    assert!(
        reduce_read_state(
            None,
            ReadEvent::Baseline(&summary(MAX_READ_OUTPUTS + 1, "too-many"))
        )
        .is_err()
    );
    let invalid = OutputSummary {
        count: 0,
        latest_id: Some("bad".into()),
    };
    assert!(reduce_read_state(None, ReadEvent::Baseline(&invalid)).is_err());
    let state = reduce(None, ReadEvent::Baseline(&summary(1, "same")));
    assert!(reduce_read_state(Some(&state), ReadEvent::Inspect(&summary(2, "same"))).is_err());
    let mut full = reduce(
        Some(&state),
        ReadEvent::Inspect(&summary(MAX_READ_OUTPUTS, "maximum")),
    );
    full.unread_count = MAX_READ_OUTPUTS;
    let rollback = reduce(Some(&full), ReadEvent::Inspect(&summary(1, "replaced")));
    assert!(reduce_read_state(Some(&rollback), ReadEvent::Inspect(&summary(2, "more"))).is_err());
}
#[test]
fn stale_and_unknown_observations_preserve_every_field() {
    let mut o = observation(0, "");
    let state = observe(None, &o);
    terminal(&mut o, 1, "reply", true);
    let state = observe(Some(&state), &o);
    let mut stale = o.clone();
    stale.source_revision -= 1;
    assert_eq!(observe(Some(&state), &stale), state);
    o.history = OutputProjection::Unknown;
    assert_eq!(observe(Some(&state), &o), state);
}
#[test]
fn reopen_baseline_keeps_unread_and_does_not_infer_past_failures() {
    let mut o = observation(1, "old");
    let state = observe(None, &o);
    terminal(&mut o, 2, "new", true);
    let state = observe(Some(&state), &o);
    let state = reduce(
        Some(&state),
        ReadEvent::Opened {
            changed_focus: true,
        },
    );
    let reopened = observation(2, "new");
    let state = observe(Some(&state), &reopened);
    assert_eq!(state.unread_count, 1);
    assert!(!state.unread_failure);
    assert_eq!(state.consumed_failure_sequence, 0);
}
