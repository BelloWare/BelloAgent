use super::*;
use crate::{Delta, Error, Lane, Message, Profile, Reply, SessionStore, Submission};
use serde_json::{Value, json};

fn reply(text: &str, status: &str) -> Reply {
    Reply {
        text: text.into(),
        reasoning: String::new(),
        calls: vec![],
        usage: Value::Null,
        status: status.into(),
        provider_items: vec![],
    }
}
fn tool_result(
    text: String,
    outcome: crate::tool_history::ToolOutcome,
) -> crate::runtime::tool_runtime::ToolResultRow {
    crate::runtime::tool_runtime::ToolResultRow {
        text,
        outcome,
        duration_us: None,
        content: None,
    }
}
fn profile() -> Profile {
    serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":"http://127.0.0.1:12345","contextWindow":32000,"maxOutputTokens":4096})).unwrap()
}
fn start(session: &mut Session) -> String {
    session
        .submit(Submission::new("request".into(), Lane::FollowUp))
        .unwrap();
    session.start_next().unwrap();
    session.active_reply.clone().unwrap()
}
fn expect(session: &Session, count: u64, latest: Option<&str>) {
    assert_eq!(
        project_outputs(session),
        OutputProjection::Known(OutputSummary {
            count,
            latest_id: latest.map(str::to_owned)
        })
    );
}
fn store() -> (tempfile::TempDir, SessionStore, String) {
    let dir = tempfile::tempdir().unwrap();
    let mut store = SessionStore::open(dir.path().join("session.json")).unwrap();
    let id = store.transact(|session| Ok(start(session))).unwrap();
    (dir, store, id)
}
#[test]
fn empty_success_and_output_limited_success_are_outputs() {
    for status in ["completed", "incomplete"] {
        let mut session = Session::new();
        let id = start(&mut session);
        expect(&session, 0, None);
        session.finish(&id, Ok(reply("", status))).unwrap();
        expect(&session, 1, Some(&id));
    }
}
#[test]
fn retained_interrupted_partial_uses_nonempty_not_trimmed() {
    for (text, reasoning, count) in [("", "", 0), (" ", "", 1), ("", "\n", 1), ("partial", "", 1)] {
        for cancelled in [false, true] {
            let mut session = Session::new();
            let id = start(&mut session);
            session.delta(&id, Delta::Text(text.into())).unwrap();
            session
                .delta(&id, Delta::Reasoning(reasoning.into()))
                .unwrap();
            expect(&session, 0, None);
            session
                .finish(
                    &id,
                    Err(if cancelled {
                        Error::Cancelled
                    } else {
                        crate::invalid("failed")
                    }),
                )
                .unwrap();
            expect(&session, count, (count != 0).then_some(id.as_str()));
        }
    }
}
#[test]
fn discarded_tool_timeline_only_failure_has_no_retained_output_evidence() {
    let mut session = Session::new();
    let id = start(&mut session);
    session
        .delta(
            &id,
            Delta::Tool {
                id: "call".into(),
                name: "ls".into(),
                arguments: "{}".into(),
            },
        )
        .unwrap();
    session.finish(&id, Err(crate::invalid("failed"))).unwrap();
    expect(&session, 0, None);
}
#[test]
fn tool_only_accepted_round_counts_once_after_stop() {
    let mut session = Session::new();
    let id = start(&mut session);
    let mut response = reply("", "completed");
    response.calls.push(crate::provider::ToolCall {
        id: "call".into(),
        name: "ls".into(),
        arguments: json!({}),
    });
    session.begin_tools(&id, &response, &profile()).unwrap();
    expect(&session, 1, Some(&id));
    session
        .settle_tools(
            &id,
            vec![tool_result(
                "Stopped".into(),
                crate::tool_history::ToolOutcome::Cancelled,
            )],
            true,
        )
        .unwrap();
    expect(&session, 1, Some(&id));
}
#[test]
fn multiple_tool_rounds_and_final_reply_have_distinct_identities() {
    let mut session = Session::new();
    let mut id = start(&mut session);
    for round in 1..=3 {
        let mut response = reply("", "completed");
        response.calls.push(crate::provider::ToolCall {
            id: format!("call-{round}"),
            name: "ls".into(),
            arguments: json!({}),
        });
        session.begin_tools(&id, &response, &profile()).unwrap();
        expect(&session, round, Some(&id));
        session
            .settle_tools(
                &id,
                vec![tool_result(
                    "Not executed".into(),
                    crate::tool_history::ToolOutcome::NotExecuted,
                )],
                false,
            )
            .unwrap();
        expect(&session, round, Some(&id));
        id = session.active_reply.clone().unwrap();
    }
    session.finish(&id, Ok(reply("done", "completed"))).unwrap();
    expect(&session, 4, Some(&id));
}
#[test]
fn unknown_contradictory_and_duplicate_representations_refuse_projection() {
    let mut session = Session::new();
    let id = start(&mut session);
    session.finish(&id, Ok(reply("done", "completed"))).unwrap();
    for state in [
        "complete",
        "mystery",
        "streaming",
        "context-rejected",
        "context-recovery-complete",
        "compaction-complete",
    ] {
        let mut invalid = session.clone();
        invalid.messages.last_mut().unwrap().state = state.into();
        assert_eq!(
            project_outputs(&invalid),
            OutputProjection::Unknown,
            "{state}"
        );
    }
    let mut invalid = session.clone();
    invalid.messages.last_mut().unwrap().replay_eligible = false;
    assert_eq!(project_outputs(&invalid), OutputProjection::Unknown);
    for id in ["", "bad\nidentity"] {
        let mut invalid = session.clone();
        invalid.messages.last_mut().unwrap().id = id.into();
        assert_eq!(project_outputs(&invalid), OutputProjection::Unknown);
    }
    session
        .messages
        .push(session.messages.last().unwrap().clone());
    assert_eq!(project_outputs(&session), OutputProjection::Unknown);
}
#[test]
fn legacy_plain_production_shape_remains_projectable() {
    let mut session = Session::new();
    let id = start(&mut session);
    session.finish(&id, Ok(reply("", "completed"))).unwrap();
    session.version = 1;
    session.stream_generation.clear();
    session.stream_sequence = 0;
    session.tool_timing = None;
    for row in &mut session.messages {
        row.task_root_id = None;
    }
    expect(&session, 1, Some(&id));
}
#[test]
fn receipt_owned_context_partial_counts_but_progress_and_summary_do_not() {
    let mut session = Session::new();
    let previous = start(&mut session);
    session
        .finish(&previous, Ok(reply("old answer", "completed")))
        .unwrap();
    let id = start(&mut session);
    session.delta(&id, Delta::Reasoning(" ".into())).unwrap();
    session
        .begin_context_recovery(
            "recovery",
            &id,
            crate::provider_failure::Failure {
                category: crate::provider_failure::Category::InputContextExceeded,
                status: Some(400),
                message: "Input context exceeded".into(),
                attempt_id: None,
                reported_usage: None,
            },
            "a".repeat(64),
        )
        .unwrap();
    expect(&session, 2, Some(&id));
    let progress = session.context_recoveries[0].progress_id.clone();
    session
        .messages
        .iter_mut()
        .find(|row| row.id == progress)
        .unwrap()
        .text = "summary draft".into();
    expect(&session, 2, Some(&id));
    session.mark_recovery_summarizing("recovery").unwrap();
    let source_ids = crate::compaction::active_context(&session.messages)
        .unwrap()
        .iter()
        .map(|row| row.id.clone())
        .collect();
    let turn = session.active.as_ref().unwrap().id.clone();
    let summary = Message::compaction_summary(
        "summary".into(),
        "summary content".into(),
        Some(crate::compaction::Checkpoint {
            version: 1,
            operation_id: "recovery".into(),
            source_ids,
            kept_ids: vec![turn.clone()],
            protected_ids: vec![turn],
            before_estimated_tokens: 500,
            after_estimated_tokens: 100,
        }),
    );
    session
        .adopt_recovery_checkpoint("recovery", summary, &reply("summary text", "completed"))
        .unwrap();
    expect(&session, 2, Some(&id));
    let retry = session.begin_recovery_retry("recovery").unwrap();
    session.finish_context_recovery(&retry, true).unwrap();
    session
        .finish(&retry, Ok(reply("answer", "completed")))
        .unwrap();
    expect(&session, 3, Some(&retry));
}
#[test]
fn receipt_owned_manual_compaction_progress_is_excluded_even_with_partial_content() {
    let mut session = Session::new();
    let original = start(&mut session);
    session
        .finish(&original, Ok(reply("answer", "completed")))
        .unwrap();
    let progress = session
        .begin_compaction("compact", &profile(), false)
        .unwrap();
    session
        .delta(&progress, Delta::Text("summary stream".into()))
        .unwrap();
    expect(&session, 1, Some(&original));
    session
        .fail_compaction(
            "compact",
            crate::invalid("summary failed"),
            Some(&reply("retained summary", "incomplete")),
        )
        .unwrap();
    expect(&session, 1, Some(&original));
    session
        .compaction_history
        .push(session.compaction.take().unwrap());
    expect(&session, 1, Some(&original));
    session.compaction_history.clear();
    assert_eq!(project_outputs(&session), OutputProjection::Unknown);
}
#[test]
fn accepted_terminal_survives_completion_then_next_start_without_observation() {
    let (_dir, mut store, id) = store();
    store
        .transact(|session| session.finish(&id, Ok(reply("", "completed"))))
        .unwrap();
    let finished = store.read_observation();
    store.transact(|session| Ok(start(session))).unwrap();
    let running = store.read_observation();
    assert!(running.busy);
    assert_eq!(running.terminal, finished.terminal);
    assert_eq!(
        running.terminal.unwrap().history,
        OutputProjection::Known(OutputSummary {
            count: 1,
            latest_id: Some(id)
        })
    );
}
#[test]
fn failure_retry_and_success_do_not_erase_failure_occurrence() {
    let (_dir, mut store, id) = store();
    store
        .transact(|session| session.finish(&id, Err(crate::invalid("failed"))))
        .unwrap();
    let failed = store.read_observation();
    assert_eq!(failed.failure_sequence, 1);
    store.transact(|session| session.retry_turn()).unwrap();
    assert_eq!(store.read_observation().failure_sequence, 1);
    assert_eq!(store.read_observation().terminal, failed.terminal);
    let id = store.snapshot_ref().active_reply.clone().unwrap();
    store
        .transact(|session| session.finish(&id, Ok(reply("done", "completed"))))
        .unwrap();
    assert_eq!(store.read_observation().failure_sequence, 1);
    assert_eq!(store.read_observation().terminal.unwrap().sequence, 2);
    // A consumer that cleared sequence 1 must not reinterpret it as a new error.
    assert!(!(store.read_observation().failure_sequence > failed.failure_sequence));
}
#[test]
fn failed_and_uncertain_checkpoints_never_accept_a_terminal() {
    for fault in [
        crate::session::WriteFault::BeforeRename,
        crate::session::WriteFault::AfterRename,
    ] {
        let (_dir, mut store, id) = store();
        let before = store.read_observation();
        store.fault = fault;
        assert!(
            store
                .transact(|session| session.finish(&id, Err(crate::invalid("failed"))))
                .is_err()
        );
        let after = store.read_observation();
        assert_eq!(after.terminal, None);
        assert_eq!(after.failure_sequence, 0);
        assert_eq!(after.source_revision, before.source_revision);
        if matches!(fault, crate::session::WriteFault::BeforeRename) {
            assert_eq!(after, before);
        } else {
            assert_eq!(after.history, OutputProjection::Unknown);
        }
    }
}
#[test]
fn journal_tokens_do_not_advance_observation_or_projection() {
    let (_dir, mut store, id) = store();
    let before = store.read_observation();
    for _ in 0..25 {
        store
            .append_delta(&id, Delta::Text("token".into()))
            .unwrap();
    }
    assert_eq!(store.read_observation(), before);
    store
        .transact(|session| session.finish(&id, Err(Error::Cancelled)))
        .unwrap();
    assert_eq!(
        store.read_observation().terminal.unwrap().history,
        OutputProjection::Known(OutputSummary {
            count: 1,
            latest_id: Some(id)
        })
    );
}
#[test]
fn reopen_baselines_retained_history_and_resets_lifetime_sequences() {
    let (dir, mut store, id) = store();
    store
        .transact(|session| session.finish(&id, Err(crate::invalid("failed"))))
        .unwrap();
    let old = store.read_observation();
    drop(store);
    let reopened = SessionStore::open(dir.path().join("session.json")).unwrap();
    let new = reopened.read_observation();
    assert_ne!(new.generation, old.generation);
    assert_eq!(new.failure_sequence, 0);
    assert_eq!(new.terminal, None);
    assert_eq!(new.history, old.history);
}

#[test]
fn startup_recovery_counts_retained_partial_without_inventing_terminal_events() {
    let (dir, mut store, id) = store();
    store
        .append_delta(&id, Delta::Reasoning("kept".into()))
        .unwrap();
    drop(store);
    let reopened = SessionStore::open(dir.path().join("session.json")).unwrap();
    expect(reopened.snapshot_ref(), 1, Some(&id));
    assert!(reopened.read_observation().terminal.is_none());
    assert_eq!(reopened.read_observation().failure_sequence, 0);
}
#[test]
fn exhausted_sequences_never_wrap_or_resume_known_observations() {
    let mut before = Session::new();
    let id = start(&mut before);
    let mut observation = AcceptedReadObservation::initial(&before);
    observation.failure_sequence = u64::MAX;
    let mut after = before.clone();
    after.finish(&id, Err(crate::invalid("failed"))).unwrap();
    observation.accept(&before, &after);
    assert_eq!(observation.failure_sequence, u64::MAX);
    assert_eq!(observation.history, OutputProjection::Unknown);
    let before = after.clone();
    after.retry_turn().unwrap();
    observation.accept(&before, &after);
    assert_eq!(observation.history, OutputProjection::Unknown);
}

#[test]
fn materialization_preserves_empty_lifetime_without_regressing_accepted_events() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("session.json");
    let mut store = SessionStore::pending();
    let pending = store.read_observation();
    assert!(store.transact(|session| Ok(start(session))).is_err());
    assert!(
        store
            .append_delta("reply", Delta::Text("unaccepted".into()))
            .is_err()
    );
    assert_eq!(store.read_observation(), pending);
    store.persist_to(&path).unwrap();
    assert_eq!(store.read_observation().generation, pending.generation);
    assert_eq!(store.read_observation().terminal, None);
    assert_eq!(store.read_observation().failure_sequence, 0);
    let id = store.transact(|session| Ok(start(session))).unwrap();
    store
        .transact(|session| session.finish(&id, Err(crate::invalid("failed"))))
        .unwrap();
    let finished = store.read_observation();
    store.persist_to(&path).unwrap();
    assert_eq!(store.read_observation(), finished);
    assert!(
        store
            .persist_to(directory.path().join("other.json"))
            .is_err()
    );
    assert_eq!(store.read_observation(), finished);
}

#[test]
fn successful_manual_compaction_retains_output_count_and_latest_identity() {
    let mut session = Session::new();
    let id = start(&mut session);
    session
        .finish(&id, Ok(reply("answer", "completed")))
        .unwrap();
    session
        .begin_compaction("compact", &profile(), false)
        .unwrap();
    let before = session.clone();
    let mut observation = AcceptedReadObservation::initial(&session);
    let source_ids = crate::compaction::active_context(&session.messages)
        .unwrap()
        .iter()
        .map(|row| row.id.clone())
        .collect();
    let summary = Message::compaction_summary(
        "summary".into(),
        "summary content".into(),
        Some(crate::compaction::Checkpoint {
            version: 1,
            operation_id: "compact".into(),
            source_ids,
            kept_ids: vec![],
            protected_ids: vec![],
            before_estimated_tokens: 500,
            after_estimated_tokens: 100,
        }),
    );
    session
        .adopt_compaction("compact", summary, &reply("summary", "completed"))
        .unwrap();
    expect(&session, 1, Some(&id));
    observation.accept(&before, &session);
    assert_eq!(observation.completed_task_sequence, 0);
}
#[test]
fn failed_retry_preserves_each_retained_partial_and_failure_occurrence() {
    let (_directory, mut store, first) = store();
    store
        .append_delta(&first, Delta::Text("first partial".into()))
        .unwrap();
    store
        .transact(|session| session.finish(&first, Err(crate::invalid("failed"))))
        .unwrap();
    store.transact(|session| session.retry_turn()).unwrap();
    let second = store.snapshot_ref().active_reply.clone().unwrap();
    store
        .append_delta(&second, Delta::Reasoning("second partial".into()))
        .unwrap();
    store
        .transact(|session| session.finish(&second, Err(crate::invalid("failed again"))))
        .unwrap();
    expect(store.snapshot_ref(), 2, Some(&second));
    assert_eq!(store.read_observation().failure_sequence, 2);
    assert_eq!(store.read_observation().terminal.unwrap().sequence, 2);
}

#[test]
fn accepted_tool_round_remains_output_after_terminal_error_or_cancellation() {
    for error in [crate::invalid("delivery failed"), Error::Cancelled] {
        let mut session = Session::new();
        let id = start(&mut session);
        let mut response = reply("", "completed");
        response.calls.push(crate::provider::ToolCall {
            id: "call".into(),
            name: "ls".into(),
            arguments: json!({}),
        });
        session.begin_tools(&id, &response, &profile()).unwrap();
        session.finish(&id, Err(error)).unwrap();
        assert_eq!(session.messages.last().unwrap().state, "interrupted");
        assert!(!session.messages.last().unwrap().replay_eligible);
        expect(&session, 1, Some(&id));
    }
}
#[test]
fn original_v3_tool_writer_shape_is_supported_but_inert_or_contradictory_shapes_are_unknown() {
    let mut session = Session::new();
    let id = start(&mut session);
    session.version = 3;
    session.tool_timing = None;
    for row in &mut session.messages {
        row.task_root_id = None;
    }
    let mut response = reply("", "completed");
    response.calls.push(crate::provider::ToolCall {
        id: "call".into(),
        name: "ls".into(),
        arguments: json!({}),
    });
    session.begin_tools(&id, &response, &profile()).unwrap();
    assert_eq!(session.version, 3);
    expect(&session, 1, Some(&id));
    // Finish the tool round before varying historical shapes, so the separate
    // active-checkpoint validator does not mask these projector rejections.
    session
        .settle_tools(
            &id,
            vec![tool_result(
                "stopped".into(),
                crate::tool_history::ToolOutcome::Cancelled,
            )],
            true,
        )
        .unwrap();
    for (state, eligible) in [
        ("mystery", false),
        ("streaming", false),
        ("completed", false),
        ("interrupted", true),
        ("complete", true),
    ] {
        let mut invalid = session.clone();
        let row = invalid
            .messages
            .iter_mut()
            .find(|row| row.id == id)
            .unwrap();
        row.state = state.into();
        row.replay_eligible = eligible;
        assert_eq!(
            project_outputs(&invalid),
            OutputProjection::Unknown,
            "{state}/{eligible}"
        );
    }
    for completion in [
        crate::tool_history::Completion::Incomplete,
        crate::tool_history::Completion::Cancelled,
    ] {
        let mut invalid = session.clone();
        let row = invalid
            .messages
            .iter_mut()
            .find(|row| row.id == id)
            .unwrap();
        row.replay_eligible = false;
        if let Some(ToolRecord::Assistant(record)) = &mut row.tool_record {
            record.completion = completion;
            record.tool_batch_timing = None; // inert legacy validator fixture
        }
        assert!(crate::tool_history::validate(&invalid.messages).is_ok());
        assert_eq!(project_outputs(&invalid), OutputProjection::Unknown);
    }
}

#[test]
fn task_completion_sequence_survives_followup_and_reopen_is_silent() {
    let (dir, mut store, id) = store();
    assert_eq!(store.read_observation().completed_task_sequence, 0);
    store
        .transact(|s| s.finish(&id, Ok(reply("", "completed"))))
        .unwrap();
    store
        .transact(|s| {
            start(s);
            Ok(())
        })
        .unwrap();
    let next = store.read_observation();
    assert!(next.busy);
    assert_eq!(next.completed_task_sequence, 1);
    let id = store.snapshot().active_reply.unwrap();
    store
        .transact(|s| s.finish(&id, Ok(reply("limited", "incomplete"))))
        .unwrap();
    assert_eq!(store.read_observation().completed_task_sequence, 2);
    drop(store);
    let reopened = SessionStore::open(dir.path().join("session.json")).unwrap();
    assert_eq!(reopened.read_observation().completed_task_sequence, 0);
}

#[test]
fn task_completion_sequence_ignores_stream_tool_round_failure_stop_and_refused_write() {
    let (_dir, mut store, id) = store();
    store
        .append_delta(&id, Delta::Text("partial".into()))
        .unwrap();
    assert_eq!(store.read_observation().completed_task_sequence, 0);
    let mut response = reply("", "completed");
    response.calls.push(crate::provider::ToolCall {
        id: "call".into(),
        name: "ls".into(),
        arguments: json!({}),
    });
    store
        .transact(|s| s.begin_tools(&id, &response, &profile()))
        .unwrap();
    assert_eq!(store.read_observation().completed_task_sequence, 0);
    store
        .transact(|s| {
            s.settle_tools(
                &id,
                vec![tool_result(
                    "Stopped".into(),
                    crate::tool_history::ToolOutcome::Cancelled,
                )],
                true,
            )
        })
        .unwrap();
    assert_eq!(store.read_observation().completed_task_sequence, 0);
    store
        .transact(|s| {
            s.resume()?;
            start(s);
            Ok(())
        })
        .unwrap();
    let id = store.snapshot().active_reply.unwrap();
    store
        .transact(|s| s.finish(&id, Err(crate::invalid("fixture failure"))))
        .unwrap();
    assert_eq!(store.read_observation().completed_task_sequence, 0);
    store
        .transact(|s| {
            s.resume()?;
            start(s);
            Ok(())
        })
        .unwrap();
    let id = store.snapshot().active_reply.unwrap();
    store.fault = crate::session::WriteFault::BeforeRename;
    assert!(
        store
            .transact(|s| s.finish(&id, Ok(reply("done", "completed"))))
            .is_err()
    );
    assert_eq!(store.read_observation().completed_task_sequence, 0);
}
