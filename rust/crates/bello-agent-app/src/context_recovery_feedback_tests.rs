//! GPUI test-platform state/projection tests, not an interactive GUI validation.
use super::{progress_label, row_label, tests::fixture};
use bello_agent_core::{
    Controller, Lane, Message, RunState, Session, SessionStore, Submission,
    compaction::Checkpoint,
    context_recovery::{DEFERRED_STATE, Phase, Reason, Receipt},
    provider_failure::{Category, Failure},
};
use gpui::{TestAppContext, VisualTestContext};
use std::sync::Arc;

fn recovery(mut session: Session) -> Session {
    session
        .submit(Submission::new("Keep my task".into(), Lane::FollowUp))
        .unwrap();
    session.start_next().unwrap();
    let failed_id = session.active_reply.clone().unwrap();
    let failed = session
        .messages
        .iter_mut()
        .find(|row| row.id == failed_id)
        .unwrap();
    failed.state = "context-rejected".into();
    failed.text = "Retained partial response".into();
    failed.replay_eligible = false;
    let mut progress = failed.clone();
    progress.id = "recovery-progress".into();
    progress.text.clear();
    progress.state = "context-recovery-preparing".into();
    session.messages.push(progress);
    session.context_recoveries.push(Receipt {
        id: "recovery".into(),
        turn_id: session.active.as_ref().unwrap().id.clone(),
        failed_reply_id: failed_id,
        progress_id: "recovery-progress".into(),
        retry_reply_id: None,
        retry_turn_id: None,
        resolved_reply_id: None,
        summary_rejection: None,
        retry_rejection: None,
        request_fingerprint: "a".repeat(64),
        reason: Reason::ContextRejection,
        failure: Some(Failure {
            category: Category::InputContextExceeded,
            status: Some(400),
            message: "secret provider URL and request text".into(),
            attempt_id: None,
            reported_usage: None,
        }),
        phase: Phase::Preparing,
        summary_id: None,
        summary_failure: None,
        summary_attempts: 0,
        retry_attempts: 0,
    });
    session.version = 10;
    session
}

fn row<'a>(session: &'a Session, id: &str) -> &'a Message {
    session.messages.iter().find(|row| row.id == id).unwrap()
}

#[::core::prelude::v1::test]
fn context_recovery_feedback_distinguishes_every_phase_without_disclosing_provider_text() {
    let mut session = recovery(Session::new());
    for (phase, expected) in [
        (Phase::Preparing, "Context rejected · Preparing summary…"),
        (Phase::Summarizing, "Context rejected · Summarizing…"),
        (
            Phase::RetryReady,
            "Context rejected · Summary adopted; preparing retry…",
        ),
        (Phase::Retrying, "Retrying after compaction…"),
        (
            Phase::Completed,
            "Context recovery · Retry completed; summary response retained",
        ),
        (
            Phase::Failed,
            "Context rejected · Summary failed; original context retained",
        ),
        (
            Phase::Cancelled,
            "Context recovery · Stopped; original context retained",
        ),
        (
            Phase::Interrupted,
            "Context recovery · Interrupted; original context retained",
        ),
    ] {
        session.context_recoveries[0].phase = phase.clone();
        session.context_recoveries[0].summary_attempts = 1;
        session.context_recoveries[0].summary_failure = Some("secret summary request".into());
        assert_eq!(
            row_label(row(&session, "recovery-progress"), &session),
            Some(expected)
        );
        if phase.is_running() {
            assert_eq!(progress_label(&session), expected);
        } else {
            assert_eq!(progress_label(&session), "Working · Generating response…");
        }
        let failed = row(&session, &session.context_recoveries[0].failed_reply_id);
        let label = row_label(failed, &session).unwrap();
        assert!(label.contains("Context rejected"));
        assert!(label.contains("failed attempt retained"));
        assert!(!label.contains("secret"));
        assert!(!expected.contains("secret"));
        assert_eq!(failed.text, "Retained partial response");
        assert!(!failed.replay_eligible);
    }
    session.context_recoveries[0]
        .failure
        .as_mut()
        .unwrap()
        .category = Category::InputPlusOutputContextExceeded;
    let failed = row(&session, &session.context_recoveries[0].failed_reply_id);
    assert!(
        row_label(failed, &session)
            .unwrap()
            .contains("Input plus output")
    );
    session.context_recoveries[0].phase = Phase::Preparing;
    session.active_reply = Some("newer-reply".into());
    assert_eq!(progress_label(&session), "Working · Generating response…");
    session.active_reply = Some(session.context_recoveries[0].failed_reply_id.clone());
    session.state = RunState::Paused;
    assert_eq!(progress_label(&session), "Working · Generating response…");
}

#[::core::prelude::v1::test]
fn context_recovery_feedback_never_claims_original_context_after_adoption() {
    let mut session = recovery(Session::new());
    for phase in [Phase::Failed, Phase::Cancelled, Phase::Interrupted] {
        session.context_recoveries[0].phase = phase;
        session.context_recoveries[0].summary_id = Some("adopted".into());
        let label = row_label(row(&session, "recovery-progress"), &session).unwrap();
        assert!(label.contains("checkpoint retained"));
        assert!(!label.contains("original context retained"));
    }
    session.context_recoveries[0].phase = Phase::Failed;
    session.context_recoveries[0].retry_reply_id = Some("retry".into());
    assert!(
        row_label(row(&session, "recovery-progress"), &session)
            .unwrap()
            .contains("Retry failed")
    );
    session.context_recoveries[0].summary_id = None;
    session.context_recoveries[0].retry_reply_id = None;
    assert!(
        row_label(row(&session, "recovery-progress"), &session)
            .unwrap()
            .contains("Preparation failed")
    );
}

#[gpui::test]
fn context_recovery_feedback_publishes_real_transcript_rows_and_preserves_composer(
    cx: &mut TestAppContext,
) {
    let (_directory, window, root) = fixture(cx);
    let (controller, composer, draft) = root.read_with(cx, |view, cx| {
        (
            view.controller.clone(),
            view.composer.clone(),
            view.composer.read(cx).text().to_owned(),
        )
    });
    let mut snapshot = recovery(controller.snapshot());
    let id = snapshot.id.clone();
    let failed_id = snapshot.context_recoveries[0].failed_reply_id.clone();
    let visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(gpui::size(gpui::px(1180.), gpui::px(812.)));
    cx.run_until_parked();
    for phase in [Phase::Preparing, Phase::Summarizing] {
        snapshot.context_recoveries[0].phase = phase;
        snapshot.revision += 1;
        root.update(cx, |view, cx| {
            view.visible_messages = usize::MAX;
            view.receive_fixture_snapshot(
                &id,
                &Arc::downgrade(&controller),
                Arc::new(snapshot.clone()),
                cx,
            );
            assert!(progress_label(&view.session).starts_with("Context rejected"));
            assert!(
                !view
                    .session
                    .messages
                    .iter()
                    .any(|row| row.compaction.is_some())
            );
            assert_eq!(view.composer.entity_id(), composer.entity_id());
            assert_eq!(view.composer.read(cx).text(), draft);
            assert!(view.queue_operation.is_none());
        });
        cx.run_until_parked();
        let mut visual = VisualTestContext::from_window(window.into(), cx);
        root.read_with(cx, |view, cx| {
            let transcript = view.transcript.as_ref().unwrap().read(cx);
            let ids = transcript.logical_row_ids();
            for id in [&failed_id, &"recovery-progress".to_owned()] {
                let index = ids.iter().position(|row| row == id).unwrap();
                assert!(transcript.painted_indexes().contains(&index));
            }
        });
        assert!(visual.debug_bounds("composer-send").is_some());
    }
    let mut checkpoint = row(&snapshot, "recovery-progress").clone();
    checkpoint.id = "adopted-checkpoint".into();
    checkpoint.role = "system".into();
    checkpoint.text = "Adopted summary".into();
    checkpoint.state = "complete".into();
    checkpoint.replay_eligible = true;
    checkpoint.compaction = Some(Checkpoint {
        version: 1,
        operation_id: "recovery".into(),
        source_ids: vec![],
        kept_ids: vec![],
        protected_ids: vec![],
        before_estimated_tokens: 100,
        after_estimated_tokens: 20,
    });
    snapshot.messages.push(checkpoint);
    let mut retry = row(&snapshot, "recovery-progress").clone();
    retry.id = "retry-reply".into();
    retry.state = "streaming".into();
    snapshot.messages.push(retry);
    snapshot.active_reply = Some("retry-reply".into());
    let receipt = &mut snapshot.context_recoveries[0];
    receipt.phase = Phase::Retrying;
    receipt.summary_id = Some("adopted-checkpoint".into());
    receipt.retry_reply_id = Some("retry-reply".into());
    receipt.retry_turn_id = Some(receipt.turn_id.clone());
    root.update(cx, |view, cx| {
        view.receive_fixture_snapshot(
            &id,
            &Arc::downgrade(&controller),
            Arc::new(snapshot.clone()),
            cx,
        );
        assert_eq!(progress_label(&view.session), "Retrying after compaction…");
        assert_eq!(
            row_label(row(&view.session, "adopted-checkpoint"), &view.session),
            Some("Compaction · Checkpoint durably adopted")
        );
        assert_eq!(
            row_label(row(&view.session, "retry-reply"), &view.session),
            Some("Retried after compaction")
        );
        assert!(
            !row_label(row(&view.session, "recovery-progress"), &view.session)
                .unwrap()
                .contains("Checkpoint durably adopted")
        );
        assert_eq!(view.composer.read(cx).text(), draft);
    });
    cx.run_until_parked();
    root.read_with(cx, |view, cx| {
        let transcript = view.transcript.as_ref().unwrap().read(cx);
        let ids = transcript.logical_row_ids();
        for id in [&failed_id, &"adopted-checkpoint".to_owned()] {
            let index = ids.iter().position(|row| row == id).unwrap();
            assert!(transcript.painted_indexes().contains(&index));
        }
    });
}

#[gpui::test]
fn context_recovery_feedback_rejects_stale_controller_publications(cx: &mut TestAppContext) {
    let (_directory, _window, root) = fixture(cx);
    root.update(cx, |view, cx| {
        let old = view.controller.clone();
        let old_id = view.record.id.clone();
        let stale = Arc::new(recovery(old.snapshot()));
        let replacement = Controller::new(SessionStore::pending(), None).unwrap();
        view.controller = replacement.clone();
        let before = view.session.clone();
        view.receive_snapshot(&old_id, &Arc::downgrade(&old), stale, cx);
        assert!(Arc::ptr_eq(&view.controller, &replacement));
        assert!(Arc::ptr_eq(&view.session, &before));
        assert!(view.session.context_recoveries.is_empty());
        assert_eq!(
            progress_label(&view.session),
            "Working · Generating response…"
        );
    });
}

#[gpui::test]
fn context_recovery_usage_narrow_footer_preserves_reading_composer_selection_and_scroll(
    cx: &mut TestAppContext,
) {
    use gpui::{EntityInputHandler, ListOffset, px, size};
    let (_directory, window, root) = fixture(cx);
    let controller = root.read_with(cx, |view, _| view.controller.clone());
    let mut snapshot = recovery(controller.snapshot());
    let template = snapshot.messages[0].clone();
    for index in (0..30).rev() {
        let mut message = template.clone();
        message.id = format!("earlier-{index}");
        message.text = "Earlier context".into();
        snapshot.messages.insert(0, message);
    }
    snapshot.context_recoveries[0].phase = Phase::Summarizing;
    snapshot.context_recoveries[0].summary_attempts = 1;
    let failed = snapshot.context_recoveries[0].failed_reply_id.clone();
    snapshot
        .messages
        .iter_mut()
        .find(|r| r.id == failed)
        .unwrap()
        .usage = serde_json::json!({
        "input_tokens": u64::MAX - 1, "output_tokens": u64::MAX - 1
    });
    for index in 0..9 {
        snapshot
            .pending
            .push(Submission::new(format!("Queued {index}"), Lane::FollowUp));
    }
    root.update(cx, |view, cx| {
        view.visible_messages = usize::MAX;
        view.receive_fixture_snapshot(
            &snapshot.id,
            &Arc::downgrade(&controller),
            Arc::new(snapshot.clone()),
            cx,
        );
    });
    window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                editor.set_text("Draft".into(), cx);
                editor.focus(window);
                editor.replace_and_mark_text_in_range(None, "未確定", Some(1..2), window, cx);
            });
        })
        .unwrap();
    cx.run_until_parked();
    let (composer, child) = root.read_with(cx, |view, _| {
        (view.composer.clone(), view.transcript.clone().unwrap())
    });
    let selection = window
        .update(cx, |view, window, cx| {
            view.composer.update(cx, |editor, cx| {
                (
                    editor.selected_text_range(false, window, cx).unwrap().range,
                    editor.marked_text_range(window, cx).unwrap(),
                )
            })
        })
        .unwrap();
    child
        .read_with(cx, |view, _| view.list_state())
        .scroll_to(ListOffset {
            item_ix: 3,
            offset_in_item: px(7.),
        });
    child.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    let anchor = child.read_with(cx, |view, _| {
        let top = view.list_state().logical_scroll_top();
        (
            view.logical_row_ids()[top.item_ix].clone(),
            top.offset_in_item,
        )
    });
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    for (width, height, split) in [(920., 600., false), (1180., 812., true), (920., 600., true)] {
        root.update(cx, |view, cx| {
            view.show_files = split;
            view.layout.fraction = 0.5;
            cx.notify();
        });
        visual.simulate_resize(size(px(width), px(height)));
        cx.run_until_parked();
        let pane = visual.debug_bounds("queue-measured-pane").unwrap();
        let footer = visual.debug_bounds("queue-measured-footer").unwrap();
        let field = visual.debug_bounds("queue-measured-composer").unwrap();
        let transcript = visual.debug_bounds("queue-measured-transcript").unwrap();
        let tokens = visual.debug_bounds("session-stats-context").unwrap();
        assert!(
            tokens.left() >= footer.left() && tokens.right() <= footer.right(),
            "usage escaped footer: {tokens:?} {footer:?}"
        );
        assert!(tokens.top() >= footer.top() && tokens.bottom() <= footer.bottom());
        assert!(footer.bottom() <= pane.bottom() + px(1.));
        assert!(field.bottom() <= footer.top() + px(1.));
        assert!(
            transcript.size.height >= px(150.),
            "reading reserve lost: {transcript:?}"
        );
        window
            .update(cx, |view, window, cx| {
                assert_eq!(view.composer.entity_id(), composer.entity_id());
                assert_eq!(
                    view.transcript.as_ref().unwrap().entity_id(),
                    child.entity_id()
                );
                view.composer.update(cx, |editor, cx| {
                    assert_eq!(
                        editor.selected_text_range(false, window, cx).unwrap().range,
                        selection.0
                    );
                    assert_eq!(editor.marked_text_range(window, cx).unwrap(), selection.1);
                });
            })
            .unwrap();
        child.read_with(cx, |view, _| {
            let top = view.list_state().logical_scroll_top();
            assert_eq!(
                (
                    view.logical_row_ids()[top.item_ix].clone(),
                    top.offset_in_item
                ),
                anchor
            );
        });
    }
}

#[::core::prelude::v1::test]
fn automatic_compaction_is_one_compaction_row_and_its_deferred_reply_is_hidden() {
    let mut session = recovery(Session::new());
    let deferred = session.context_recoveries[0].failed_reply_id.clone();
    let receipt = &mut session.context_recoveries[0];
    receipt.reason = Reason::Threshold;
    receipt.failure = None;
    let row_mut = session
        .messages
        .iter_mut()
        .find(|row| row.id == deferred)
        .unwrap();
    row_mut.state = DEFERRED_STATE.into();
    row_mut.text.clear();
    for (phase, label, status) in [
        (
            Phase::Preparing,
            "Compaction · Preparing · threshold",
            "Compacting · Preparing checkpoint…",
        ),
        (
            Phase::Summarizing,
            "Compaction · Summary request · attempt 1",
            "Compacting · Summarizing…",
        ),
        (
            Phase::Cancelled,
            "Compaction · Cancelled; original context retained",
            "Working · Generating response…",
        ),
        (
            Phase::Interrupted,
            "Compaction · Interrupted; original context retained",
            "Working · Generating response…",
        ),
    ] {
        session.context_recoveries[0].phase = phase;
        assert_eq!(
            row_label(row(&session, "recovery-progress"), &session),
            Some(label)
        );
        assert_eq!(progress_label(&session), status);
        assert_eq!(row_label(row(&session, &deferred), &session), None);
    }
    let hidden = super::deferred_replies(&session);
    assert!(hidden.contains(deferred.as_str()));
    assert!(!hidden.contains("recovery-progress"));
    // A rejection receipt's retained attempt stays visible.
    assert!(super::deferred_replies(&recovery(Session::new())).is_empty());
}
