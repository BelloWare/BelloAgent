use super::*;
use crate::{Delta, Error, Lane, Reply, SessionStore, Submission, session::WriteFault};

fn bundle(store: &SessionStore) -> FindSnapshot {
    FindSnapshot::new(Arc::new(store.snapshot()), store.find_token())
}
fn active() -> (tempfile::TempDir, SessionStore, String) {
    let dir = tempfile::tempdir().unwrap();
    let mut store = SessionStore::open(dir.path().join("session.json")).unwrap();
    store
        .transact(|session| {
            session.submit(Submission::new("retained needle".into(), Lane::FollowUp))?;
            session.start_next()?;
            Ok(())
        })
        .unwrap();
    let reply = store.snapshot().active_reply.unwrap();
    (dir, store, reply)
}
fn finished(text: &str) -> Reply {
    Reply {
        text: text.into(),
        reasoning: String::new(),
        calls: vec![],
        usage: serde_json::Value::Null,
        status: "completed".into(),
        provider_items: vec![],
    }
}

#[test]
fn excluded_streaming_deltas_do_not_compare_history_or_rotate_content() {
    let (_dir, mut store, reply) = active();
    let before = bundle(&store);
    COMPARISONS.with(|count| count.set(0));
    for _ in 0..64 {
        store
            .append_delta(&reply, Delta::Text("needle".into()))
            .unwrap();
        store
            .append_delta(&reply, Delta::Reasoning("thought".into()))
            .unwrap();
        assert!(before.same_content(&bundle(&store)));
    }
    assert_eq!(COMPARISONS.with(|count| count.get()), 0);
    assert_ne!(before.session().revision, store.snapshot_revision());
    store
        .transact(|session| session.finish(&reply, Ok(finished("needle"))))
        .unwrap();
    assert!(!before.same_content(&bundle(&store)));
    assert_eq!(COMPARISONS.with(|count| count.get()), 1);
}

#[test]
fn full_transaction_identity_is_exact_and_aba_never_reuses_tokens() {
    let (_dir, mut store, _reply) = active();
    let a = bundle(&store);
    store
        .transact(|s| {
            s.messages[0].text = "retained NEEDLE".into();
            Ok(())
        })
        .unwrap();
    let b = bundle(&store);
    assert!(!a.same_content(&b));
    store
        .transact(|s| {
            s.messages[0].text = "retained needle".into();
            Ok(())
        })
        .unwrap();
    let again = bundle(&store);
    assert!(!a.same_content(&again));
    assert!(!b.same_content(&again));
    assert!(same_projection(a.session(), again.session()));
    store
        .transact(|s| {
            s.messages[0].id = uuid::Uuid::new_v4().to_string();
            s.messages[0].task_root_id = Some(s.messages[0].id.clone());
            Ok(())
        })
        .unwrap();
    let id_changed = bundle(&store);
    assert!(!again.same_content(&id_changed));
    store
        .transact(|s| {
            s.id = uuid::Uuid::new_v4().to_string();
            Ok(())
        })
        .unwrap();
    assert!(!id_changed.same_content(&bundle(&store)));
}

#[test]
fn queue_metadata_and_excluded_row_edits_preserve_content() {
    let (_dir, mut store, _) = active();
    let before = bundle(&store);
    store
        .transact(|s| {
            s.submit(Submission::new("queued only".into(), Lane::FollowUp))?;
            s.messages[1].text = "excluded changed".into();
            s.messages[0].reasoning = "not searched".into();
            Ok(())
        })
        .unwrap();
    assert!(before.same_content(&bundle(&store)));
}

#[test]
fn empty_completion_and_failed_partial_change_membership() {
    for failed in [false, true] {
        let (_dir, mut store, reply) = active();
        let before = bundle(&store);
        if failed {
            store
                .append_delta(&reply, Delta::Text("partial".into()))
                .unwrap();
        }
        store
            .transact(|s| {
                s.finish(
                    &reply,
                    if failed {
                        Err(Error::Cancelled)
                    } else {
                        Ok(finished(""))
                    },
                )
            })
            .unwrap();
        assert!(!before.same_content(&bundle(&store)));
    }
}

#[test]
fn retained_active_context_rejected_text_rotates_but_reasoning_and_empty_do_not() {
    let (_dir, mut store, reply) = active();
    store
        .transact(|s| {
            s.begin_context_recovery(
                "find-recovery",
                &reply,
                crate::provider_failure::Failure {
                    category: crate::provider_failure::Category::InputContextExceeded,
                    status: Some(400),
                    message: "fixture context rejection".into(),
                    attempt_id: None,
                    reported_usage: None,
                },
                "a".repeat(64),
            )
        })
        .unwrap();
    let before = bundle(&store);
    store
        .append_delta(&reply, Delta::Text(String::new()))
        .unwrap();
    store
        .append_delta(&reply, Delta::Reasoning("thought".into()))
        .unwrap();
    assert!(before.same_content(&bundle(&store)));
    store
        .append_delta(&reply, Delta::Text("retained".into()))
        .unwrap();
    assert!(!before.same_content(&bundle(&store)));
}

#[test]
fn full_checkpoint_faults_and_stale_or_failed_journal_never_bless_content() {
    for fault in [WriteFault::BeforeRename, WriteFault::AfterRename] {
        let (dir, mut store, _) = active();
        let before = bundle(&store);
        store.fault = fault;
        assert!(
            store
                .transact(|s| {
                    s.messages[0].text = "changed".into();
                    Ok(())
                })
                .is_err()
        );
        assert!(before.same_content(&bundle(&store)));
        assert_eq!(
            before.session().messages[0].text,
            store.snapshot().messages[0].text
        );
        if matches!(fault, WriteFault::AfterRename) {
            assert!(store.require_certain().is_err());
            assert!(store.transact(|_| Ok(())).is_err());
        }
        drop(store);
        let reopened = SessionStore::open(dir.path().join("session.json")).unwrap();
        assert!(!before.same_content(&bundle(&reopened)));
        assert_eq!(
            reopened.snapshot().messages[0].text,
            if matches!(fault, WriteFault::AfterRename) {
                "changed"
            } else {
                "retained needle"
            }
        );
    }
    let (_dir, mut store, reply) = active();
    store
        .transact(|s| {
            s.begin_context_recovery(
                "find-recovery",
                &reply,
                crate::provider_failure::Failure {
                    category: crate::provider_failure::Category::InputContextExceeded,
                    status: Some(400),
                    message: "fixture context rejection".into(),
                    attempt_id: None,
                    reported_usage: None,
                },
                "a".repeat(64),
            )
        })
        .unwrap();
    let before = bundle(&store);
    assert!(
        store
            .append_delta("wrong", Delta::Text("bad".into()))
            .is_err()
    );
    assert!(before.same_content(&bundle(&store)));
    store.fault = WriteFault::StreamMetadata;
    assert!(
        store
            .append_delta(&reply, Delta::Text("bad".into()))
            .is_err()
    );
    assert!(before.same_content(&bundle(&store)));
    assert!(store.require_certain().is_err());
    assert_eq!(
        before.session().messages[1].text,
        store.snapshot().messages[1].text
    );
}

#[test]
fn materialization_preserves_only_equal_projection_and_failed_identity_is_unchanged() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("empty.json");
    let mut pending = SessionStore::pending();
    let before = bundle(&pending);
    pending.persist_to(&path).unwrap();
    assert!(before.same_content(&bundle(&pending)));
    let (history_dir, history, _) = active();
    let id = history.snapshot().id;
    drop(history);
    let mut pending = SessionStore::pending_with_id(&id).unwrap();
    let before = bundle(&pending);
    pending
        .persist_to(history_dir.path().join("session.json"))
        .unwrap();
    assert!(!before.same_content(&bundle(&pending)));
    drop(pending);
    let mut wrong = SessionStore::pending();
    let before = bundle(&wrong);
    assert!(
        wrong
            .persist_to(history_dir.path().join("session.json"))
            .is_err()
    );
    assert!(before.same_content(&bundle(&wrong)));
}

#[test]
fn comparator_tracks_order_identity_membership_but_not_raw_indices() {
    let (_dir, store, _) = active();
    let original = store.snapshot();
    let mut shifted = original.clone();
    shifted.messages.swap(0, 1);
    assert!(same_projection(&original, &shifted));
    let id = &original.messages[0].id;
    assert_eq!(shifted.messages.iter().position(|m| &m.id == id), Some(1));
    shifted.messages[0].state = "complete".into();
    assert!(!same_projection(&original, &shifted));
    let mut original = shifted.clone();
    original.messages.swap(0, 1);
    assert!(!same_projection(&original, &shifted));
    shifted.messages[0].text = "equal length".into();
    original = shifted.clone();
    shifted.messages[0].text = "EQUAL LENGTH".into();
    assert!(!same_projection(&original, &shifted));
}

#[test]
fn queue_reorder_promotion_and_rejected_closure_or_encoding_preserve_identity() {
    let (_dir, mut store, _) = active();
    let first = Submission::new("one".into(), Lane::FollowUp);
    let second = Submission::new("two".into(), Lane::FollowUp);
    let before = bundle(&store);
    store
        .transact(|s| {
            s.submit(first.clone())?;
            s.submit(second.clone())
        })
        .unwrap();
    store
        .transact(|s| s.reorder(&[second.id.clone(), first.id.clone()]))
        .unwrap();
    store
        .transact(|s| s.promote_to_steering(&first.id))
        .unwrap();
    assert!(before.same_content(&bundle(&store)));
    assert!(
        store
            .transact(|s| {
                s.messages[0].text = "unaccepted".into();
                Err::<(), _>(crate::invalid("closure rejected"))
            })
            .is_err()
    );
    assert!(before.same_content(&bundle(&store)));
    assert!(
        store
            .transact(|s| {
                s.messages[0].task_root_id = Some("foreign".into());
                Ok(())
            })
            .is_err()
    );
    assert!(before.same_content(&bundle(&store)));
}

#[test]
fn active_typed_tool_row_nonempty_text_rotates_without_projection_scan() {
    let (_dir, mut store, reply) = active();
    let profile = serde_json::from_value(serde_json::json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":"http://127.0.0.1:12345","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let before_tool = bundle(&store);
    store
        .transact(|s| {
            s.begin_tools(
                &reply,
                &Reply {
                    calls: vec![crate::provider::ToolCall {
                        id: "call".into(),
                        name: "ls".into(),
                        arguments: serde_json::json!({}),
                    }],
                    ..finished("")
                },
                &profile,
            )
        })
        .unwrap();
    store.snapshot().validate_checkpoint().unwrap();
    let before = bundle(&store);
    assert!(!before_tool.same_content(&before));
    COMPARISONS.with(|count| count.set(0));
    store
        .append_delta(
            &reply,
            Delta::Tool {
                id: "call".into(),
                name: "ls".into(),
                arguments: "{}".into(),
            },
        )
        .unwrap();
    store
        .append_delta(&reply, Delta::Text(String::new()))
        .unwrap();
    store
        .append_delta(&reply, Delta::Reasoning("thought".into()))
        .unwrap();
    assert!(before.same_content(&bundle(&store)));
    store
        .append_delta(&reply, Delta::Text("additional visible text".into()))
        .unwrap();
    assert!(!before.same_content(&bundle(&store)));
    assert_eq!(COMPARISONS.with(|count| count.get()), 0);
}

#[test]
fn rejected_materialization_and_retired_store_preserve_prior_pair() {
    let dir = tempfile::tempdir().unwrap();
    let mut pending = SessionStore::pending();
    let before = bundle(&pending);
    // A directory cannot become an atomic session checkpoint.
    assert!(pending.persist_to(dir.path()).is_err());
    assert!(before.same_content(&bundle(&pending)));
    assert_eq!(before.session().id, pending.snapshot().id);
    let (_dir, mut store, reply) = active();
    let before = bundle(&store);
    store.retire_writer();
    assert!(
        store
            .transact(|s| {
                s.messages[0].text = "forbidden".into();
                Ok(())
            })
            .is_err()
    );
    assert!(
        store
            .append_delta(&reply, Delta::Text("forbidden".into()))
            .is_err()
    );
    assert!(before.same_content(&bundle(&store)));
    assert!(same_projection(before.session(), &store.snapshot()));
}

#[test]
fn journal_append_sync_and_directory_failures_keep_pair_and_reopen_has_fresh_recovered_identity() {
    for fault in [
        WriteFault::StreamAppend,
        WriteFault::StreamSync,
        WriteFault::StreamDirectorySync,
    ] {
        let (dir, mut store, reply) = active();
        let before = bundle(&store);
        store.fault = fault;
        assert!(
            store
                .append_delta(&reply, Delta::Text("recovered needle".into()))
                .is_err()
        );
        assert!(before.same_content(&bundle(&store)));
        assert!(same_projection(before.session(), &store.snapshot()));
        assert_eq!(store.snapshot().messages[1].text, "");
        assert!(store.require_certain().is_err());
        assert!(
            store
                .append_delta(&reply, Delta::Text("rejected".into()))
                .is_err()
        );
        drop(store);
        let reopened = SessionStore::open(dir.path().join("session.json")).unwrap();
        let recovered = bundle(&reopened);
        assert!(!before.same_content(&recovered));
        let row = recovered
            .session()
            .messages
            .iter()
            .find(|m| m.id == reply)
            .unwrap();
        assert_eq!(
            row.text,
            if matches!(fault, WriteFault::StreamAppend) {
                ""
            } else {
                "recovered needle"
            }
        );
        assert!(is_retained(recovered.session(), row));
        recovered.session().validate_checkpoint().unwrap();
    }
}

#[test]
fn accepted_retained_order_and_membership_transitions_rotate_exactly() {
    let (_dir, mut store, reply) = active();
    store
        .transact(|s| {
            s.begin_context_recovery(
                "find-recovery",
                &reply,
                crate::provider_failure::Failure {
                    category: crate::provider_failure::Category::InputContextExceeded,
                    status: Some(400),
                    message: "fixture".into(),
                    attempt_id: None,
                    reported_usage: None,
                },
                "a".repeat(64),
            )
        })
        .unwrap();
    let retained = bundle(&store);
    // Keep this accepted transition a valid plain active turn, with no dangling receipt.
    store
        .transact(|s| {
            s.context_recoveries.clear();
            for row in &mut s.messages {
                if row.state.starts_with("context-recovery-") {
                    row.state = "complete".into();
                }
            }
            s.messages.iter_mut().find(|m| m.id == reply).unwrap().state = "streaming".into();
            Ok(())
        })
        .unwrap();
    store.snapshot().validate_checkpoint().unwrap();
    assert!(!retained.same_content(&bundle(&store)));
    store
        .transact(|s| s.finish(&reply, Ok(finished("complete"))))
        .unwrap();
    let before = bundle(&store);
    store
        .transact(|s| {
            s.messages.swap(0, 1);
            Ok(())
        })
        .unwrap();
    store.snapshot().validate_checkpoint().unwrap();
    assert!(!before.same_content(&bundle(&store)));
}
