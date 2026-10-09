use super::reconciliation::*;
use super::*;
use crate::{
    Delta, Lane, Message, Session, SessionStore, Submission,
    inspection::InspectionCoordinator,
    observed_source::ObservedJournal,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
    workspace_membership::MembershipSnapshot,
};
use std::{
    fs,
    io::Write,
    sync::{Arc, Mutex},
};
use uuid::Uuid;
struct Fixture {
    dir: tempfile::TempDir,
    owner: Arc<Mutex<WorkspaceStore>>,
    id: String,
    path: std::path::PathBuf,
}
fn row(text: &str) -> Message {
    Message {
        id: Uuid::new_v4().to_string(),
        role: "user".into(),
        text: text.into(),
        reasoning: "EXCLUDED_REASONING".into(),
        replay_eligible: false,
        state: "complete".into(),
        usage: serde_json::Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
        task_root_id: None,
        user_content: None,
    }
}
fn fixture(text: &str) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let mut owner = WorkspaceStore::open(root.join("catalog.json"), &root).unwrap();
    let id = Uuid::new_v4().to_string();
    let path = owner.chat_path(&id).unwrap();
    let mut store = SessionStore::pending_with_id(&id).unwrap();
    store.persist_to(&path).unwrap();
    store
        .transact(|s| {
            s.messages.push(row(text));
            Ok(())
        })
        .unwrap();
    drop(store);
    owner
        .register(
            ChatRecord::new(id.clone(), "private".into(), path.clone()),
            DraftRecord::default(),
        )
        .unwrap();
    Fixture {
        dir,
        owner: Arc::new(Mutex::new(owner)),
        id,
        path,
    }
}
fn membership(f: &Fixture) -> MembershipSnapshot {
    WorkspaceStore::search_membership_snapshot(&f.owner).unwrap()
}
fn pass(f: &Fixture) -> ReconciliationPass {
    ReconciliationPass::begin(&SearchRequest::new("needle", 1).unwrap(), &membership(f)).unwrap()
}
fn observe(work: &SearchWork) -> UnloadedObserved {
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    let lease = permit.inspect_search(work).unwrap();
    lease.prepare_search(work).unwrap()
}
fn journal(f: &Fixture, text: &str) -> (Session, std::path::PathBuf) {
    let mut store = SessionStore::open(&f.path).unwrap();
    store
        .transact(|s| {
            s.submit(Submission::new("prompt".into(), Lane::FollowUp))?;
            s.start_next()?;
            Ok(())
        })
        .unwrap();
    let reply = store.snapshot().active_reply.unwrap();
    store
        .append_delta(&reply, Delta::Text(text.into()))
        .unwrap();
    let s = store.snapshot();
    let path = crate::stream_journal::path(&f.path, &s.stream_generation).unwrap();
    drop(store);
    (s, path)
}
#[test]
fn observed_checkpoint_journal_receipt_is_complete_bounded_and_read_only() {
    let f = fixture("old");
    let (session, journal) = journal(&f, "needle");
    let before = (
        fs::read(&f.path).unwrap(),
        fs::read(&journal).unwrap(),
        fs::read(f.dir.path().join("catalog.json")).unwrap(),
    );
    let mut p = pass(&f);
    let work = p.work(&f.id).unwrap();
    let value = observe(&work);
    assert!(matches!(value.outcome(), SearchOutcome::Match(_)));
    match value.source().journal() {
        ObservedJournal::Present {
            file,
            bytes_consumed,
            complete_records,
            first_sequence,
            last_sequence,
            final_record_end,
        } => {
            assert_eq!(*bytes_consumed, before.1.len() as u64);
            assert_eq!(*final_record_end, *bytes_consumed);
            assert_eq!(*complete_records, 1);
            assert_eq!(*first_sequence, Some(1));
            assert_eq!(*last_sequence, Some(session.stream_sequence));
            use sha2::Digest;
            assert_eq!(
                file.digest(),
                <[u8; 32]>::from(sha2::Sha256::digest(&before.1))
            );
        }
        _ => panic!("missing journal"),
    }
    assert_eq!(value.source().final_revision().revision(), session.revision);
    assert!(value.source().interval().0 <= value.source().interval().1);
    p.record_observed(value).unwrap();
    assert_eq!(
        p.finish(&membership(&f)).unwrap().state,
        CoverageState::CompleteAsOf
    );
    assert_eq!(
        before,
        (
            fs::read(&f.path).unwrap(),
            fs::read(&journal).unwrap(),
            fs::read(f.dir.path().join("catalog.json")).unwrap()
        )
    );
}
#[test]
fn absent_empty_and_legacy_are_distinct_and_rechecked_at_closure() {
    let f = fixture("needle");
    let session: Session = serde_json::from_slice(&fs::read(&f.path).unwrap()).unwrap();
    let path = crate::stream_journal::path(&f.path, &session.stream_generation).unwrap();
    let mut p = pass(&f);
    let w = p.work(&f.id).unwrap();
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    let lease = permit.inspect_search(&w).unwrap();
    assert_eq!(
        lease.observed_source().unwrap().journal(),
        &ObservedJournal::Absent
    );
    fs::write(&path, []).unwrap();
    assert!(lease.prepare_search(&w).is_err());
    drop(lease);
    let lease = permit.inspect_search(&w).unwrap();
    assert!(matches!(
        lease.observed_source().unwrap().journal(),
        ObservedJournal::Present {
            complete_records: 0,
            bytes_consumed: 0,
            ..
        }
    ));
    drop(lease);
    let mut s = session;
    s.version = 1;
    s.stream_generation.clear();
    s.stream_sequence = 0;
    s.messages.clear();
    let mut legacy = serde_json::to_value(&s).unwrap();
    legacy.as_object_mut().unwrap().remove("tool_timing");
    fs::write(&f.path, serde_json::to_vec(&legacy).unwrap()).unwrap();
    let lease = permit.inspect_search(&w).unwrap();
    assert_eq!(
        lease.observed_source().unwrap().journal(),
        &ObservedJournal::LegacyNotApplicable
    );
}
#[test]
fn journal_append_turns_previous_negative_positive_and_new_pass_rechecks_all() {
    let f = fixture("old");
    let (s, journal) = journal(&f, "old");
    let checkpoint = fs::read(&f.path).unwrap();
    let mut p = pass(&f);
    let w = p.work(&f.id).unwrap();
    let no = observe(&w);
    assert!(matches!(no.outcome(), SearchOutcome::NoMatch));
    let first = no.source().journal().clone();
    p.record_observed(no).unwrap();
    let bytes = crate::stream_journal::encode(
        &s,
        s.active_reply.as_ref().unwrap(),
        &Delta::Text("needle".into()),
    )
    .unwrap();
    fs::OpenOptions::new()
        .append(true)
        .open(&journal)
        .unwrap()
        .write_all(&bytes)
        .unwrap();
    let mut next = pass(&f);
    assert_eq!(next.finish(&membership(&f)).unwrap().pending, 1);
    let w = next.work(&f.id).unwrap();
    let yes = observe(&w);
    assert!(matches!(yes.outcome(), SearchOutcome::Match(_)));
    assert_ne!(yes.source().journal(), &first);
    next.record_observed(yes).unwrap();
    assert_eq!(fs::read(&f.path).unwrap(), checkpoint);
}
#[test]
fn verified_negative_replaces_positive_and_same_metadata_cannot_hide_byte_change() {
    let f = fixture("needle");
    let mut p = pass(&f);
    let w = p.work(&f.id).unwrap();
    let yes = observe(&w);
    let digest = yes.source().checkpoint().digest();
    p.record_observed(yes).unwrap();
    let time = fs::metadata(&f.path).unwrap().modified().unwrap();
    let text = fs::read_to_string(&f.path)
        .unwrap()
        .replace("needle", "absent");
    fs::write(&f.path, text).unwrap();
    fs::File::options()
        .write(true)
        .open(&f.path)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(time))
        .unwrap();
    let w = p.work(&f.id).unwrap();
    assert!(p.outcome(&f.id).unwrap().is_none());
    let no = observe(&w);
    assert!(matches!(no.outcome(), SearchOutcome::NoMatch));
    assert_ne!(no.source().checkpoint().digest(), digest);
    p.record_observed(no).unwrap();
    assert!(matches!(
        p.outcome(&f.id).unwrap(),
        Some(SearchOutcome::NoMatch)
    ));
}
#[test]
fn torn_prefix_foreign_generation_gap_and_malformed_complete_records_never_escape() {
    for tail in [b"torn".as_slice(), b"garbage\n".as_slice()] {
        let f = fixture("old");
        let (_, journal) = journal(&f, "needle");
        fs::OpenOptions::new()
            .append(true)
            .open(journal)
            .unwrap()
            .write_all(tail)
            .unwrap();
        let mut p = pass(&f);
        let w = p.work(&f.id).unwrap();
        let lane = InspectionCoordinator::default();
        let mut permit = lane.try_background().unwrap().unwrap();
        assert!(permit.inspect_search(&w).is_err());
        assert!(p.outcome(&f.id).unwrap().is_none());
    }
    for key in ["generation", "sequence", "session"] {
        let f = fixture("old");
        let (_, journal) = journal(&f, "needle");
        let mut record: serde_json::Value =
            serde_json::from_slice(&fs::read(&journal).unwrap()).unwrap();
        record[key] = if key == "sequence" {
            serde_json::json!(99)
        } else {
            serde_json::json!(Uuid::new_v4().to_string())
        };
        let mut bytes = serde_json::to_vec(&record).unwrap();
        bytes.push(b'\n');
        fs::write(journal, bytes).unwrap();
        let mut p = pass(&f);
        let w = p.work(&f.id).unwrap();
        let lane = InspectionCoordinator::default();
        let mut permit = lane.try_background().unwrap().unwrap();
        assert!(permit.inspect_search(&w).is_err());
    }
}
#[test]
fn final_checkpoint_journal_and_lock_replacements_are_rejected() {
    for target in ["checkpoint", "journal", "lock"] {
        let f = fixture("old");
        let (_, journal) = journal(&f, "needle");
        let mut p = pass(&f);
        let w = p.work(&f.id).unwrap();
        let lane = InspectionCoordinator::default();
        let mut permit = lane.try_background().unwrap().unwrap();
        let lease = permit.inspect_search(&w).unwrap();
        let path = match target {
            "checkpoint" => f.path.clone(),
            "journal" => journal,
            _ => f.path.with_extension("lock"),
        };
        let bytes = fs::read(&path).unwrap();
        fs::rename(&path, path.with_extension("moved")).unwrap();
        fs::write(&path, bytes).unwrap();
        assert!(lease.prepare_search(&w).is_err());
    }
}
#[test]
fn source_lock_survives_projection_and_releases_on_drop_and_cancel() {
    let f = fixture("needle");
    let mut p = pass(&f);
    let w = p.work(&f.id).unwrap();
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    let lease = permit.inspect_search(&w).unwrap();
    let _value = lease.prepare_search(&w).unwrap();
    assert!(SessionStore::open(&f.path).is_err());
    let selected = lane.selected_open().unwrap();
    assert!(matches!(
        lease.prepare_search(&w),
        Err(SearchError::Cancelled)
    ));
    assert!(SessionStore::open(&f.path).is_err());
    drop(lease);
    drop(permit);
    drop(selected);
    drop(SessionStore::open(&f.path).unwrap());
}
#[test]
fn lifecycle_replacement_and_loaded_routes_cannot_use_disk_or_old_attempts() {
    let f = fixture("needle");
    let mut p = pass(&f);
    let old = p.work(&f.id).unwrap();
    let value = observe(&old);
    p.transition(&f.id, SourceRoute::Blocked).unwrap();
    assert!(p.record_observed(value).is_err());
    assert!(p.work(&f.id).is_err());
    assert_eq!(
        p.finish(&membership(&f)).unwrap().state,
        CoverageState::Unavailable
    );
    p.transition(&f.id, SourceRoute::Loaded).unwrap();
    let loaded = p.work(&f.id).unwrap();
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    assert!(permit.inspect_search(&loaded).is_err());
    p.transition(&f.id, SourceRoute::Unloaded).unwrap();
    let first = p.work(&f.id).unwrap();
    let stale = observe(&first);
    let second = p.work(&f.id).unwrap();
    assert!(p.record_observed(stale).is_err());
    p.record_observed(observe(&second)).unwrap();
}
#[test]
fn failure_is_unavailable_not_negative_and_query_or_pass_reuse_is_stale() {
    let f = fixture("needle");
    let mut p = pass(&f);
    let w = p.work(&f.id).unwrap();
    p.record_failure(&w, ObservationFailure::Torn).unwrap();
    assert!(p.outcome(&f.id).is_err());
    assert_eq!(p.failure(&f.id), Some(ObservationFailure::Torn));
    assert_eq!(p.finish(&membership(&f)).unwrap().unavailable, 1);
    let value = observe(&w);
    let mut next = pass(&f);
    assert!(next.record_observed(value).is_err());
    let request = SearchRequest::new("needle", 1).unwrap();
    let mut cancelled = ReconciliationPass::begin(&request, &membership(&f)).unwrap();
    let w = cancelled.work(&f.id).unwrap();
    request.cancel();
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    assert!(permit.inspect_search(&w).is_err());
    assert!(cancelled.finish(&membership(&f)).is_err());
}
#[test]
fn new_members_and_removal_require_fresh_complete_membership() {
    let f = fixture("needle");
    let mut p = pass(&f);
    let w = p.work(&f.id).unwrap();
    p.record_observed(observe(&w)).unwrap();
    let mut owner = f.owner.lock().unwrap();
    let id = Uuid::new_v4().to_string();
    let path = owner.chat_path(&id).unwrap();
    let mut store = SessionStore::pending_with_id(&id).unwrap();
    store.persist_to(&path).unwrap();
    drop(store);
    owner
        .register(
            ChatRecord::new(id.clone(), "new".into(), path),
            DraftRecord::default(),
        )
        .unwrap();
    drop(owner);
    assert!(p.finish(&membership(&f)).is_err());
    assert!(p.outcome(&f.id).is_err());
    let next = pass(&f);
    assert_eq!(next.finish(&membership(&f)).unwrap().pending, 2);
    p.remove(&f.id);
    assert!(p.outcome(&f.id).is_err());
    assert!(w.check().is_err());
}
#[cfg(unix)]
#[test]
fn symlink_and_retargeted_ancestor_are_rejected_without_following_alias() {
    use std::os::unix::fs::symlink;
    let f = fixture("needle");
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    let alias = f.dir.path().join("alias");
    symlink(f.path.parent().unwrap(), &alias).unwrap();
    assert!(
        permit
            .inspect_observed(alias.join(f.path.file_name().unwrap()), &f.id)
            .is_err()
    );
    let mut p = pass(&f);
    let w = p.work(&f.id).unwrap();
    let lease = permit.inspect_search(&w).unwrap();
    let parent = f.path.parent().unwrap();
    let moved = parent.with_extension("moved");
    fs::rename(parent, &moved).unwrap();
    fs::create_dir(parent).unwrap();
    assert!(lease.prepare_search(&w).is_err());
}

#[test]
fn older_leases_cannot_be_relabelled_with_later_pass_or_attempt() {
    let f = fixture("needle");
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    let lease = permit.inspect_observed(&f.path, &f.id).unwrap();
    let mut later = pass(&f);
    let work = later.work(&f.id).unwrap();
    assert!(matches!(
        lease.prepare_search(&work),
        Err(SearchError::WrongRequest)
    ));
    drop(lease);
    let mut p = pass(&f);
    let first = p.work(&f.id).unwrap();
    let lease = permit.inspect_search(&first).unwrap();
    let fresh = later.work(&f.id).unwrap();
    assert!(matches!(
        lease.prepare_search(&fresh),
        Err(SearchError::WrongRequest)
    ));
}
#[test]
fn request_and_lifecycle_cancel_during_checkpoint_json_and_journal_acquisition() {
    for stage in ["checkpoint", "json", "journal"] {
        for lifecycle in [false, true] {
            let f = fixture(&"old ".repeat(4096));
            journal(&f, "needle");
            let visited = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let seen = visited.clone();
            let request = SearchRequest::new("needle", 1).unwrap();
            let mut p = ReconciliationPass::begin(&request, &membership(&f)).unwrap();
            let work = p.work(&f.id).unwrap();
            let captured = work.clone();
            let request = request.clone();
            crate::inspection::OBSERVATION_HOOK.with(|hook| {
                *hook.borrow_mut() = Some(Box::new(move |current| {
                    if current == stage {
                        seen.store(true, std::sync::atomic::Ordering::Release);
                        if lifecycle {
                            captured
                                .cancellation()
                                .store(true, std::sync::atomic::Ordering::Release);
                        } else {
                            request.cancel();
                        }
                    }
                }))
            });
            let lane = InspectionCoordinator::default();
            let mut permit = lane.try_background().unwrap().unwrap();
            let result = permit.inspect_search(&work);
            assert!(matches!(result, Err(crate::Error::Cancelled)));
            drop(result);
            crate::inspection::OBSERVATION_HOOK.with(|hook| *hook.borrow_mut() = None);
            assert!(
                visited.load(std::sync::atomic::Ordering::Acquire),
                "stage {stage} was not reached"
            );
            assert!(SessionStore::open(&f.path).is_ok());
        }
    }
}

#[test]
fn final_closure_after_projection_rejects_changes_to_all_paths_and_absence() {
    for target in ["checkpoint", "journal", "lock", "absent"] {
        let f = fixture("needle");
        let journal_path = if target == "absent" {
            let s: Session = serde_json::from_slice(&fs::read(&f.path).unwrap()).unwrap();
            crate::stream_journal::path(&f.path, &s.stream_generation).unwrap()
        } else {
            journal(&f, "needle").1
        };
        let path = match target {
            "checkpoint" => f.path.clone(),
            "lock" => f.path.with_extension("lock"),
            _ => journal_path,
        };
        let mut p = pass(&f);
        let w = p.work(&f.id).unwrap();
        let lane = InspectionCoordinator::default();
        let mut permit = lane.try_background().unwrap().unwrap();
        let lease = permit.inspect_search(&w).unwrap();
        crate::inspection::OBSERVATION_HOOK.with(|hook| {
            *hook.borrow_mut() = Some(Box::new(move |stage| {
                if stage == "projection" {
                    if target == "absent" {
                        fs::write(&path, []).unwrap();
                    } else {
                        let bytes = fs::read(&path).unwrap();
                        fs::rename(&path, path.with_extension("after_projection")).unwrap();
                        fs::write(&path, bytes).unwrap();
                    }
                }
            }))
        });
        let result = lease.prepare_search(&w);
        crate::inspection::OBSERVATION_HOOK.with(|hook| *hook.borrow_mut() = None);
        assert!(result.is_err(), "{target}");
    }
}
#[test]
fn missing_lock_checkpoint_wrong_id_and_oversized_source_are_not_negative() {
    for target in ["lock", "checkpoint", "foreign", "oversize"] {
        let f = fixture("needle");
        let mut p = pass(&f);
        let w = p.work(&f.id).unwrap();
        match target {
            "lock" => fs::remove_file(f.path.with_extension("lock")).unwrap(),
            "checkpoint" => fs::remove_file(&f.path).unwrap(),
            "foreign" => {
                let mut s: Session = serde_json::from_slice(&fs::read(&f.path).unwrap()).unwrap();
                s.id = Uuid::new_v4().to_string();
                fs::write(&f.path, serde_json::to_vec(&s).unwrap()).unwrap();
            }
            _ => fs::File::options()
                .write(true)
                .open(&f.path)
                .unwrap()
                .set_len(256 * 1024 * 1024 + 1)
                .unwrap(),
        }
        let lane = InspectionCoordinator::default();
        let mut permit = lane.try_background().unwrap().unwrap();
        assert!(permit.inspect_search(&w).is_err());
        assert!(p.outcome(&f.id).unwrap().is_none());
    }
}

#[test]
fn exhausted_attempt_and_lifecycle_counters_stickily_suppress_previous_hits() {
    for transition in [false, true] {
        let f = fixture("needle");
        let mut p = pass(&f);
        let work = p.work(&f.id).unwrap();
        p.record_observed(observe(&work)).unwrap();
        assert!(matches!(
            p.outcome(&f.id).unwrap(),
            Some(SearchOutcome::Match(_))
        ));
        p.exhaust_for_test(&f.id);
        let result = if transition {
            p.transition(&f.id, SourceRoute::Unloaded)
        } else {
            p.work(&f.id).map(|_| ())
        };
        assert_eq!(result, Err(SearchError::Limit));
        assert!(work.check().is_err());
        assert!(p.outcome(&f.id).is_err());
        assert_eq!(p.failure(&f.id), Some(ObservationFailure::ResourceLimit));
        assert_eq!(
            p.finish(&membership(&f)).unwrap().state,
            CoverageState::Unavailable
        );
        assert!(p.work(&f.id).is_err());
        assert!(p.transition(&f.id, SourceRoute::Unloaded).is_err());
        assert!(p.outcome(&f.id).is_err());
    }
}

#[test]
fn ordinary_inspection_preserves_read_only_validation_without_observation_hashing() {
    let f = fixture("needle");
    journal(&f, "observed");
    let seen = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let count = seen.clone();
    crate::inspection::OBSERVATION_HOOK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move |stage| {
            if stage.ends_with("_hash") {
                count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            }
        }))
    });
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    let lease = permit.inspect(&f.path, &f.id).unwrap();
    assert!(lease.observed_source().is_err());
    drop(lease);
    assert_eq!(seen.load(std::sync::atomic::Ordering::Relaxed), 0);
    let mut p = pass(&f);
    let w = p.work(&f.id).unwrap();
    let lease = permit.inspect_search(&w).unwrap();
    lease.prepare_search(&w).unwrap();
    crate::inspection::OBSERVATION_HOOK.with(|hook| *hook.borrow_mut() = None);
    assert!(seen.load(std::sync::atomic::Ordering::Relaxed) > 0);
}

#[test]
fn receipt_preserves_nonzero_checkpoint_sequence_and_complete_replay_boundary() {
    let f = fixture("old");
    let (_, journal_path) = journal(&f, "old");
    let mut checkpoint: Session = serde_json::from_slice(&fs::read(&f.path).unwrap()).unwrap();
    checkpoint.stream_sequence = 9;
    checkpoint.revision += 9;
    fs::write(&f.path, serde_json::to_vec(&checkpoint).unwrap()).unwrap();
    let bytes = crate::stream_journal::encode(
        &checkpoint,
        checkpoint.active_reply.as_ref().unwrap(),
        &Delta::Text("needle".into()),
    )
    .unwrap();
    fs::write(journal_path, &bytes).unwrap();
    let mut p = pass(&f);
    let w = p.work(&f.id).unwrap();
    let value = observe(&w);
    assert_eq!(value.source().initial_revision().sequence(), 9);
    assert_eq!(value.source().final_revision().sequence(), 10);
    assert!(matches!(
        value.source().journal(),
        ObservedJournal::Present {
            complete_records: 1,
            first_sequence: Some(10),
            last_sequence: Some(10),
            ..
        }
    ));
    assert!(matches!(value.outcome(), SearchOutcome::Match(_)));
}
#[test]
fn archive_visibility_does_not_prune_corpus_and_pending_rows_create_no_sources() {
    let f = fixture("needle");
    let mut owner = f.owner.lock().unwrap();
    let record = owner
        .snapshot()
        .chats
        .into_iter()
        .find(|r| r.id == f.id)
        .unwrap();
    owner
        .set_archived(record, DraftRecord::default(), true, 1)
        .unwrap();
    let id = Uuid::new_v4().to_string();
    let path = owner.chat_path(&id).unwrap();
    let mut pending = ChatRecord::new(id.clone(), "pending".into(), path.clone());
    pending.materialization = crate::workspace::ChatMaterialization::Pending;
    owner.register(pending, DraftRecord::default()).unwrap();
    drop(owner);
    let mut p = pass(&f);
    assert_eq!(p.finish(&membership(&f)).unwrap().expected_members, 1);
    assert!(p.work(&id).is_err());
    let w = p.work(&f.id).unwrap();
    p.record_observed(observe(&w)).unwrap();
    assert_eq!(
        p.finish(&membership(&f)).unwrap().state,
        CoverageState::CompleteAsOf
    );
    assert!(!path.exists());
    assert!(!path.with_extension("lock").exists());
}
#[test]
fn loaded_reconciliation_rechecks_live_acceptance_and_never_falls_back_after_retirement() {
    let f = fixture("needle");
    let controller = crate::Controller::new(SessionStore::open(&f.path).unwrap(), None).unwrap();
    let request = SearchRequest::new("needle", 1).unwrap();
    let mut p = ReconciliationPass::begin(&request, &membership(&f)).unwrap();
    p.transition(&f.id, SourceRoute::Loaded).unwrap();
    let work = p.work(&f.id).unwrap();
    let candidate =
        LoadedSearchEvidence::capture(&f.owner, &Arc::downgrade(&controller), &f.id, &request)
            .unwrap()
            .prepare()
            .unwrap();
    p.record_loaded(&work, candidate).unwrap();
    assert_eq!(p.finish(&membership(&f)).unwrap().loaded_members, 1);
    controller.retire().unwrap();
    assert!(p.outcome(&f.id).is_err());
    assert_eq!(
        p.finish(&membership(&f)).unwrap().state,
        CoverageState::Unavailable
    );
    let work = p.work(&f.id).unwrap();
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    assert!(permit.inspect_search(&work).is_err());
}
