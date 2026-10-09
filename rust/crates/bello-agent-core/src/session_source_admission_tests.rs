use super::*;
use crate::source_admission::SourceStatus;

fn active(path: &Path) -> SessionStore {
    let mut store = SessionStore::open(path).unwrap();
    store
        .transact(|session| {
            session.submit(Submission::new("source fixture".into(), Lane::FollowUp))?;
            session.start_next()?;
            Ok(())
        })
        .unwrap();
    store
}
fn json(session: &Session) -> serde_json::Value {
    serde_json::to_value(session).unwrap()
}
#[test]
fn pending_materialization_retains_witness_and_notifies() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("session.json");
    let mut store = SessionStore::pending();
    let witness = store.source_witness();
    let changes = witness.subscribe_changes().unwrap();
    assert_eq!(witness.status(), SourceStatus::Pending);
    assert!(store.capture_search_source().is_err());
    store.persist_to(&path).unwrap();
    let first = store.capture_search_source().unwrap();
    assert!(witness.is_current(first.stamp()));
    assert_eq!(first.stamp().checkpoint_path(), path);
    assert!(changes.has_changed().unwrap());
    let changes = witness.subscribe_changes().unwrap();
    store
        .transact(|s| {
            s.title = "renamed".into();
            Ok(())
        })
        .unwrap();
    let next = store.capture_search_source().unwrap();
    assert_eq!(first.stamp().incarnation(), next.stamp().incarnation());
    assert!(!first.is_current());
    assert!(witness.is_current(next.stamp()));
    assert!(changes.has_changed().unwrap());
}
#[test]
fn failed_materialization_fences_original_witness() {
    for fault in [WriteFault::BeforeRename, WriteFault::AfterRename] {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session.json");
        let mut store = SessionStore::pending();
        let witness = store.source_witness();
        SOURCE_OPEN_FAULT.with(|value| value.set(fault));
        let result = store.persist_to(&path);
        SOURCE_OPEN_FAULT.with(|value| value.set(WriteFault::None));
        assert!(result.is_err());
        assert!(store.capture_search_source().is_err());
        if matches!(fault, WriteFault::BeforeRename) {
            assert_eq!(witness.status(), SourceStatus::Pending);
            store.persist_to(&path).unwrap();
            assert!(witness.is_current(store.capture_search_source().unwrap().stamp()));
        } else {
            assert_eq!(witness.status(), SourceStatus::Uncertain);
            assert!(store.persist_to(&path).is_err());
            assert_eq!(witness.status(), SourceStatus::Uncertain);
        }
    }
}
#[test]
fn checkpoint_failure_receipts_are_revoked_without_revision_change() {
    for fault in [WriteFault::BeforeRename, WriteFault::AfterRename] {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session.json");
        let mut store = active(&path);
        let before = store.capture_search_source().unwrap();
        store.fault = fault;
        let result = store.transact(|s| {
            s.title = "changed".into();
            Ok(())
        });
        assert!(result.is_err());
        assert!(!before.is_current());
        assert_eq!(json(before.session()), json(&store.snapshot()));
        store.fault = WriteFault::None;
        if matches!(fault, WriteFault::BeforeRename) {
            let after = store.capture_search_source().unwrap();
            assert_eq!(before.stamp().revision(), after.stamp().revision());
            assert!(after.stamp().admission_epoch() > before.stamp().admission_epoch());
            assert!(after.is_current());
        } else {
            assert_eq!(store.source_witness().status(), SourceStatus::Uncertain);
            assert!(store.capture_search_source().is_err());
            assert!(store.transact(|_| Ok(())).is_err());
        }
    }
}
#[test]
fn every_uncertain_stream_failure_revokes_and_rejects_retries() {
    for fault in [
        WriteFault::StreamMetadata,
        WriteFault::StreamAppend,
        WriteFault::StreamPartialAppend,
        WriteFault::StreamSync,
        WriteFault::StreamDirectorySync,
    ] {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session.json");
        let mut store = active(&path);
        let before = store.capture_search_source().unwrap();
        let reply = store.snapshot().active_reply.unwrap();
        store.fault = fault;
        assert!(matches!(
            store.append_delta(&reply, Delta::Text("attempted".into())),
            Err(Error::PersistenceUncertain(_))
        ));
        assert!(!before.is_current());
        assert_eq!(json(before.session()), json(&store.snapshot()));
        assert_eq!(store.source_witness().status(), SourceStatus::Uncertain);
        assert!(store.capture_search_source().is_err());
        store.fault = WriteFault::None;
        assert!(
            store
                .append_delta(&reply, Delta::Text("retry".into()))
                .is_err()
        );
        assert_eq!(store.source_witness().status(), SourceStatus::Uncertain);
    }
}
#[test]
fn accepted_active_text_generation_sequence_and_checkpoint_are_paired() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("session.json");
    let mut store = active(&path);
    let before = store.capture_search_source().unwrap();
    let reply = store.snapshot().active_reply.unwrap();
    store
        .append_delta(&reply, Delta::Text("accepted active text".into()))
        .unwrap();
    let streamed = store.capture_search_source().unwrap();
    assert!(!before.is_current());
    assert_eq!(
        streamed.session().messages.last().unwrap().text,
        "accepted active text"
    );
    assert_eq!(streamed.stamp().revision(), streamed.session().revision);
    assert_eq!(streamed.stamp().stream_sequence(), 1);
    assert_eq!(
        streamed.stamp().stream_generation(),
        before.stamp().stream_generation()
    );
    store.transact(|_| Ok(())).unwrap();
    let checkpointed = store.capture_search_source().unwrap();
    assert!(!streamed.is_current());
    assert_eq!(checkpointed.stamp().stream_sequence(), 0);
    assert_ne!(
        streamed.stamp().stream_generation(),
        checkpointed.stamp().stream_generation()
    );
    assert_eq!(
        checkpointed.session().messages.last().unwrap().text,
        "accepted active text"
    );
}
#[test]
fn preflight_create_and_capacity_failures_preserve_accepted_source_under_new_epoch() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("session.json");
    let mut store = active(&path);
    let reply = store.snapshot().active_reply.unwrap();
    for kind in 0..3 {
        let before = store.capture_search_source().unwrap();
        let journal = crate::stream_journal::path(&path, &store.session.stream_generation).unwrap();
        let result = match kind {
            0 => store.append_delta("stale", Delta::Text("no".into())),
            1 => {
                store.snapshot_limit = store.encoded_bytes + RECOVERY_RESERVE_BYTES;
                store.append_delta(&reply, Delta::Text("no".into()))
            }
            _ => {
                store.snapshot_limit = MAX_SNAPSHOT_BYTES;
                fs::write(&journal, b"existing collision").unwrap();
                store.append_delta(&reply, Delta::Text("no".into()))
            }
        };
        assert!(result.is_err());
        assert!(!before.is_current());
        let after = store.capture_search_source().unwrap();
        assert_eq!(json(before.session()), json(after.session()));
        assert!(after.stamp().admission_epoch() > before.stamp().admission_epoch());
    }
}
#[test]
fn dropped_store_revokes_and_reopen_gets_new_incarnation() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("session.json");
    let store = SessionStore::open(&path).unwrap();
    let before = store.capture_search_source().unwrap();
    drop(store);
    assert!(!before.is_current());
    let reopened = SessionStore::open(&path).unwrap();
    let after = reopened.capture_search_source().unwrap();
    assert_eq!(before.stamp().session_id(), after.stamp().session_id());
    assert_eq!(before.stamp().revision(), after.stamp().revision());
    assert_ne!(before.stamp().incarnation(), after.stamp().incarnation());
}
#[test]
fn accepted_complete_and_torn_journal_recovery_require_new_opened_actor() {
    for torn in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session.json");
        let mut store = active(&path);
        let reply = store.session.active_reply.clone().unwrap();
        store
            .append_delta(&reply, Delta::Text("complete prefix".into()))
            .unwrap();
        let before = store.capture_search_source().unwrap();
        if torn {
            store.fault = WriteFault::StreamPartialAppend;
            assert!(
                store
                    .append_delta(&reply, Delta::Text("unaccepted tail".into()))
                    .is_err()
            );
            assert!(store.capture_search_source().is_err());
        }
        drop(store);
        assert!(!before.is_current());
        let reopened = SessionStore::open(&path).unwrap();
        let after = reopened.capture_search_source().unwrap();
        assert_eq!(
            after.session().messages.last().unwrap().text,
            "complete prefix"
        );
        assert_ne!(before.stamp().incarnation(), after.stamp().incarnation());
        assert_eq!(after.session().state, RunState::Paused);
    }
}
#[test]
fn malformed_complete_journal_never_issues_a_reopened_receipt() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("session.json");
    let store = active(&path);
    let journal = crate::stream_journal::path(&path, &store.session.stream_generation).unwrap();
    let before = store.capture_search_source().unwrap();
    drop(store);
    fs::write(&journal, b"malformed complete\n").unwrap();
    assert!(SessionStore::open(&path).is_err());
    assert!(!before.is_current());
}
#[test]
fn mutation_unwind_revokes_search_without_changing_persistence_behavior() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("session.json");
    let mut store = SessionStore::open(&path).unwrap();
    let before = store.capture_search_source().unwrap();
    assert!(
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _: Result<()> = store.transact(|_| panic!("fixture mutation panic"));
        }))
        .is_err()
    );
    assert!(!before.is_current());
    assert_eq!(store.source_witness().status(), SourceStatus::Unavailable);
    // Search failure does not introduce a new write refusal.
    store
        .transact(|s| {
            s.title = "still writable".into();
            Ok(())
        })
        .unwrap();
    assert!(store.capture_search_source().is_err());
}

#[test]
fn tool_argument_edits_old_rows_and_roles_revoke_independently_of_find() {
    use crate::{provider::ToolCall, tool_history::ToolRecord};
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("session.json");
    let mut store = active(&path);
    let reply = store.session.active_reply.clone().unwrap();
    let profile: crate::Profile = serde_json::from_value(serde_json::json!({
        "id":"fixture", "api":"openai-responses", "providerId":"litellm", "modelId":"fixture",
        "baseUrl":"http://127.0.0.1:1234", "contextWindow":65536, "maxOutputTokens":4096
    }))
    .unwrap();
    let completed = crate::Reply {
        text: "tool owner".into(),
        reasoning: String::new(),
        calls: vec![ToolCall {
            id: "call".into(),
            name: "ls".into(),
            arguments: serde_json::json!({"path":"aaaa"}),
        }],
        usage: serde_json::Value::Null,
        status: "completed".into(),
        provider_items: vec![],
    };
    store
        .transact(|s| s.begin_tools(&reply, &completed, &profile))
        .unwrap();
    let before = store.capture_search_source().unwrap();
    let find = crate::FindSnapshot::new(std::sync::Arc::new(store.snapshot()), store.find_token());
    store
        .transact(|s| {
            let Some(ToolRecord::Assistant(record)) =
                &mut s.messages.last_mut().unwrap().tool_record
            else {
                panic!("fixture owner")
            };
            record.calls[0].arguments = serde_json::json!({"path":"bbbb"});
            Ok(())
        })
        .unwrap();
    let args = store.capture_search_source().unwrap();
    assert!(!before.is_current());
    assert!(find.same_content(&crate::FindSnapshot::new(
        std::sync::Arc::new(store.snapshot()),
        store.find_token()
    )));
    assert_eq!(args.stamp().revision(), args.session().revision);
    store
        .transact(|s| {
            s.messages[0].text = "same old row changed".into();
            Ok(())
        })
        .unwrap();
    assert!(!args.is_current());
    let old_row = store.capture_search_source().unwrap();
    store
        .transact(|s| {
            s.messages[0].role = "assistant".into();
            s.messages[0].task_root_id = None;
            Ok(())
        })
        .unwrap();
    assert!(!old_row.is_current());
}

#[test]
fn revision_sequence_and_record_limits_do_not_accept_partial_source() {
    for kind in 0..3 {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session.json");
        let mut store = active(&path);
        let reply = store.session.active_reply.clone().unwrap();
        if kind == 0 {
            // Reach the final representable revision through a valid transaction.
            store
                .transact(|s| {
                    s.revision = u64::MAX - 1;
                    Ok(())
                })
                .unwrap();
        } else if kind == 1 {
            // Test-only impossible-to-reach-in-a-small-fixture sequence boundary.
            store.session.stream_sequence = u64::MAX;
        }
        let before = store.snapshot();
        let result = store.append_delta(
            &reply,
            Delta::Text(if kind == 2 {
                "x".repeat(16 * 1024 * 1024)
            } else {
                "no".into()
            }),
        );
        assert!(result.is_err());
        assert_eq!(json(&before), json(&store.snapshot()));
        let source = store.capture_search_source().unwrap();
        assert_eq!(source.stamp().revision(), source.session().revision);
        assert_eq!(
            source.stamp().stream_sequence(),
            source.session().stream_sequence
        );
    }
}

#[test]
fn recovery_checkpoint_failures_cannot_mint_loaded_receipts() {
    for fault in [WriteFault::BeforeRename, WriteFault::AfterRename] {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session.json");
        let mut store = active(&path);
        let reply = store.session.active_reply.clone().unwrap();
        store
            .append_delta(&reply, Delta::Text("retained".into()))
            .unwrap();
        let before = store.capture_search_source().unwrap();
        drop(store);
        SOURCE_OPEN_FAULT.with(|value| value.set(fault));
        let result = SessionStore::open(&path);
        SOURCE_OPEN_FAULT.with(|value| value.set(WriteFault::None));
        assert!(result.is_err());
        assert!(!before.is_current());
        let reopened = SessionStore::open(&path).unwrap();
        let source = reopened.capture_search_source().unwrap();
        assert_eq!(source.session().messages.last().unwrap().text, "retained");
        assert_ne!(before.stamp().incarnation(), source.stamp().incarnation());
    }
}

#[test]
fn read_only_inspection_after_uncertain_retirement_never_revives_loaded_evidence() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("session.json");
    let mut store = SessionStore::open(&path).unwrap();
    let before = store.capture_search_source().unwrap();
    let witness = store.source_witness();
    store.fault = WriteFault::AfterRename;
    assert!(
        store
            .transact(|s| {
                s.title = "readable but unconfirmed".into();
                Ok(())
            })
            .is_err()
    );
    assert_eq!(witness.status(), SourceStatus::Uncertain);
    store.retire_writer();
    let inspection = SessionInspectionLease::acquire(&path, before.stamp().session_id()).unwrap();
    assert_eq!(inspection.snapshot().title, "readable but unconfirmed");
    assert_eq!(witness.status(), SourceStatus::Retired);
    assert!(!before.is_current());
    assert!(store.capture_search_source().is_err());
}

#[test]
fn hypothetical_post_write_apply_failure_revokes_search_without_rewriting_error_semantics() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("session.json");
    let mut store = active(&path);
    let reply = store.session.active_reply.clone().unwrap();
    let before = store.capture_search_source().unwrap();
    store.fault = WriteFault::StreamApply;
    assert!(matches!(
        store.append_delta(&reply, Delta::Text("written before apply".into())),
        Err(Error::Invalid(_))
    ));
    assert!(!before.is_current());
    assert_eq!(store.source_witness().status(), SourceStatus::Unavailable);
    assert!(
        !store.uncertain,
        "search-only fail closure preserves store behavior"
    );
    assert_eq!(json(&store.snapshot()), json(before.session()));
    assert!(store.capture_search_source().is_err());
    drop(store);
    let reopened = SessionStore::open(&path).unwrap();
    assert_eq!(
        reopened
            .capture_search_source()
            .unwrap()
            .session()
            .messages
            .last()
            .unwrap()
            .text,
        "written before apply"
    );
}
