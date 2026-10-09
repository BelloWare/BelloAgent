use super::*;
use crate::{
    Message, SessionStore,
    source_admission::SourceStatus,
    workspace::{ChatRecord, DraftRecord},
};
use serde_json::Value;
struct Fixture {
    _dir: tempfile::TempDir,
    workspace: Arc<Mutex<WorkspaceStore>>,
    controller: Arc<Controller>,
    id: String,
}
fn row(text: &str) -> Message {
    Message {
        id: Uuid::new_v4().to_string(),
        role: "user".into(),
        text: text.into(),
        reasoning: "HIDDEN_REASONING_MARKER".into(),
        replay_eligible: false,
        state: "complete".into(),
        usage: Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
        task_root_id: None,
        user_content: None,
    }
}
fn fixture(text: &str) -> Fixture {
    fixture_store(|store| {
        store
            .transact(|s| {
                s.messages.push(row(text));
                Ok(())
            })
            .unwrap();
    })
}
fn fixture_store(initialize: impl FnOnce(&mut SessionStore)) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let mut workspace = WorkspaceStore::open(dir.path().join("catalog.json"), dir.path()).unwrap();
    let id = Uuid::new_v4().to_string();
    let path = workspace.chat_path(&id).unwrap();
    let mut store = SessionStore::pending_with_id(&id).unwrap();
    store.persist_to(&path).unwrap();
    initialize(&mut store);
    workspace
        .register(
            ChatRecord::new(id.clone(), "private title".into(), path),
            DraftRecord::default(),
        )
        .unwrap();
    Fixture {
        _dir: dir,
        workspace: Arc::new(Mutex::new(workspace)),
        controller: Controller::new(store, None).unwrap(),
        id,
    }
}
fn capture(f: &Fixture, request: &SearchRequest) -> LoadedSearchEvidence {
    LoadedSearchEvidence::capture(&f.workspace, &Arc::downgrade(&f.controller), &f.id, request)
        .unwrap()
}
fn prepared(f: &Fixture, request: &SearchRequest) -> Arc<PreparedSearchCandidate> {
    capture(f, request).prepare().unwrap()
}
fn hit(candidate: &PreparedSearchCandidate) -> &OwnedHit {
    match candidate.outcome() {
        SearchOutcome::Match(hit) => hit,
        _ => panic!("expected match"),
    }
}
#[test]
fn exact_loaded_binding_and_bounded_result_without_storage_changes() {
    let f = fixture("before needle after");
    let request = SearchRequest::new("needle", 7).unwrap();
    let membership = WorkspaceStore::search_membership_snapshot(&f.workspace).unwrap();
    let catalog = std::fs::read(membership.stamp().catalog_path()).unwrap();
    let checkpoint = std::fs::read(membership.members()[0].checkpoint_path()).unwrap();
    let candidate = prepared(&f, &request);
    assert_eq!(candidate.generation(), 7);
    assert_eq!(candidate.member().chat_id(), f.id);
    assert_eq!(
        candidate.source_stamp().checkpoint_path(),
        candidate.member().checkpoint_path()
    );
    assert_eq!(
        &hit(&candidate).excerpt()[hit(&candidate).highlight().unwrap()],
        "needle"
    );
    let slot = SearchAdmissionSlot::new(&request);
    slot.try_install(candidate.clone()).unwrap();
    assert!(Arc::ptr_eq(&slot.current().unwrap().unwrap(), &candidate));
    assert_eq!(
        std::fs::read(membership.stamp().catalog_path()).unwrap(),
        catalog
    );
    assert_eq!(
        std::fs::read(membership.members()[0].checkpoint_path()).unwrap(),
        checkpoint
    );
}
#[test]
fn wrong_id_pending_member_and_exact_path_mismatch_are_not_empty_answers() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 0).unwrap();
    assert_eq!(
        LoadedSearchEvidence::capture(
            &f.workspace,
            &Arc::downgrade(&f.controller),
            "absent",
            &request
        )
        .unwrap_err(),
        SearchError::BindingMismatch
    );
    let other = fixture("needle");
    assert_eq!(
        LoadedSearchEvidence::capture(
            &f.workspace,
            &Arc::downgrade(&other.controller),
            &f.id,
            &request
        )
        .unwrap_err(),
        SearchError::BindingMismatch
    );
    let mut chat = f.workspace.lock().unwrap().snapshot().chats[0].clone();
    chat.materialization = ChatMaterialization::Pending;
    // Distinct catalog with same ID/path but pending provenance.
    let pending_dir = tempfile::tempdir().unwrap();
    let mut pending =
        WorkspaceStore::open(pending_dir.path().join("catalog.json"), pending_dir.path()).unwrap();
    chat.snapshot = pending.chat_path(&f.id).unwrap();
    pending.register(chat, DraftRecord::default()).unwrap();
    let pending = Arc::new(Mutex::new(pending));
    assert_eq!(
        LoadedSearchEvidence::capture(&pending, &Arc::downgrade(&f.controller), &f.id, &request)
            .unwrap_err(),
        SearchError::BindingMismatch
    );
    // Same ID and materialization, but another exact authorized checkpoint path.
    let mut store = SessionStore::pending_with_id(&f.id).unwrap();
    store
        .persist_to(pending_dir.path().join("other.json"))
        .unwrap();
    let other = Controller::new(store, None).unwrap();
    assert_eq!(
        LoadedSearchEvidence::capture(&f.workspace, &Arc::downgrade(&other), &f.id, &request)
            .unwrap_err(),
        SearchError::BindingMismatch
    );
}
#[test]
fn cancellation_and_request_identity_are_explicit() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 1).unwrap();
    let candidate = prepared(&f, &request);
    let other = SearchRequest::new("needle", 1).unwrap();
    assert_eq!(
        SearchAdmissionSlot::new(&other).try_install(candidate.clone()),
        Err(SearchError::WrongRequest)
    );
    let slot = SearchAdmissionSlot::new(&request);
    slot.try_install(candidate.clone()).unwrap();
    let pending = capture(&f, &request);
    request.cancel();
    assert_eq!(pending.prepare().unwrap_err(), SearchError::Cancelled);
    assert_eq!(slot.try_install(candidate), Err(SearchError::Cancelled));
    assert_eq!(slot.current().unwrap_err(), SearchError::Cancelled);
    assert_eq!(
        LoadedSearchEvidence::capture(
            &f.workspace,
            &Arc::downgrade(&f.controller),
            &f.id,
            &request
        )
        .unwrap_err(),
        SearchError::Cancelled
    );
}
#[test]
fn source_and_membership_changes_invalidate_prepared_and_installed_answers() {
    for source in [false, true] {
        let f = fixture("needle");
        let request = SearchRequest::new("needle", 1).unwrap();
        let pending = capture(&f, &request);
        let candidate = prepared(&f, &request);
        let slot = SearchAdmissionSlot::new(&request);
        slot.try_install(candidate.clone()).unwrap();
        if source {
            f.controller.search_source_witness().retire();
        } else {
            f.workspace
                .lock()
                .unwrap()
                .name_chat(&f.id, "new title")
                .unwrap();
        }
        assert_eq!(pending.prepare().unwrap_err(), SearchError::Stale);
        assert_eq!(slot.try_install(candidate), Err(SearchError::Stale));
        assert_eq!(slot.current().unwrap_err(), SearchError::Stale);
    }
}
#[test]
fn unavailable_loaded_owner_never_falls_back_to_readable_checkpoint() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 1).unwrap();
    let old = prepared(&f, &request);
    let weak = Arc::downgrade(&f.controller);
    let slot = SearchAdmissionSlot::new(&request);
    slot.try_install(old).unwrap();
    f.controller.search_source_witness().retire();
    assert_eq!(
        LoadedSearchEvidence::capture(&f.workspace, &weak, &f.id, &request).unwrap_err(),
        SearchError::Unavailable
    );
    assert!(
        f.workspace.lock().unwrap().snapshot().chats[0]
            .snapshot
            .is_file()
    );
    drop(f.controller);
    assert!(weak.upgrade().is_none());
    assert_eq!(
        LoadedSearchEvidence::capture(&f.workspace, &weak, &f.id, &request).unwrap_err(),
        SearchError::Unavailable
    );
    assert_eq!(slot.current().unwrap_err(), SearchError::Stale);
}
#[test]
fn projection_errors_are_not_no_match_and_hidden_data_is_excluded() {
    let f = fixture("ordinary body");
    let hidden = SearchRequest::new("HIDDEN_REASONING_MARKER", 1).unwrap();
    assert!(matches!(
        prepared(&f, &hidden).outcome(),
        SearchOutcome::NoMatch
    ));
    let nul = fixture("retained\0invalid");
    assert_eq!(
        capture(&nul, &hidden).prepare().unwrap_err(),
        SearchError::Projection(projection::Error::UnsupportedNul)
    );
}
#[test]
fn huge_collapsed_envelope_is_bounded_and_honestly_unhighlighted() {
    let f = fixture(&format!("前a{}bc終", " ".repeat(20_000)));
    let request = SearchRequest::new("a bc", 1).unwrap();
    let candidate = prepared(&f, &request);
    let hit = hit(&candidate);
    assert!(hit.excerpt().len() <= MAX_EXCERPT_BYTES);
    assert_eq!(hit.coverage(), ExcerptCoverage::MatchEnvelopeExceedsBudget);
    assert_eq!(hit.highlight(), None);
    assert!(hit.occurrence().source.len() > MAX_EXCERPT_BYTES);
    assert_eq!(hit.excerpt_source().start, "前".len());
}
#[test]
fn diagnostics_do_not_log_query_source_paths_or_keys() {
    let f = fixture("SECRET_TRANSCRIPT needle");
    let request = SearchRequest::new("SECRET_TRANSCRIPT", 1).unwrap();
    let evidence = capture(&f, &request);
    let diagnostic = format!("{request:?} {evidence:?}");
    let candidate = evidence.prepare().unwrap();
    let diagnostic = format!("{diagnostic} {candidate:?} {:?}", hit(&candidate).key());
    for secret in ["SECRET", f.id.as_str(), f._dir.path().to_str().unwrap()] {
        assert!(!diagnostic.contains(secret));
    }
}
#[test]
fn pending_controller_and_owner_poison_fail_closed() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 1).unwrap();
    let pending = Controller::new(SessionStore::pending_with_id(&f.id).unwrap(), None).unwrap();
    assert_eq!(
        LoadedSearchEvidence::capture(&f.workspace, &Arc::downgrade(&pending), &f.id, &request)
            .unwrap_err(),
        SearchError::Unavailable
    );
    let candidate = prepared(&f, &request);
    let owner = f.workspace.clone();
    assert!(
        std::thread::spawn(move || {
            let _guard = owner.lock().unwrap();
            panic!("fixture poison");
        })
        .join()
        .is_err()
    );
    assert_eq!(
        SearchAdmissionSlot::new(&request).try_install(candidate),
        Err(SearchError::Stale)
    );
}
#[test]
fn preparation_retains_no_full_session_controller_or_membership_list() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 1).unwrap();
    let evidence = capture(&f, &request);
    assert_eq!(Arc::strong_count(&f.controller), 1);
    let weak_session = Arc::downgrade(&evidence.session);
    let candidate = evidence.prepare().unwrap();
    assert!(weak_session.upgrade().is_none());
    let slot = SearchAdmissionSlot::new(&request);
    slot.try_install(candidate).unwrap();
    let weak_controller = Arc::downgrade(&f.controller);
    drop(f.controller);
    assert!(weak_controller.upgrade().is_none());
    assert_eq!(slot.current().unwrap_err(), SearchError::Stale);
}
#[test]
fn source_changes_even_without_content_changes_revoke_old_candidate() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 1).unwrap();
    let candidate = prepared(&f, &request);
    let snapshot = f.controller.loaded_search_source().unwrap();
    f.controller.search_source_witness().begin().finish(
        snapshot.session(),
        snapshot.stamp().checkpoint_path(),
        SourceStatus::Certain,
    );
    assert_eq!(
        SearchAdmissionSlot::new(&request).try_install(candidate),
        Err(SearchError::Stale)
    );
}
#[test]
fn unicode_excerpt_contains_original_not_normalized_spelling() {
    let f = fixture("前 Cafe\u{301}\t\nNEEDLE 後");
    let request = SearchRequest::new("café needle", 1).unwrap();
    let candidate = prepared(&f, &request);
    let hit = hit(&candidate);
    assert_eq!(
        &hit.excerpt()[hit.highlight().unwrap()],
        "Cafe\u{301}\t\nNEEDLE"
    );
    assert_eq!(hit.coverage(), ExcerptCoverage::ExactHighlight);
}

#[test]
fn both_witnesses_are_held_through_final_install_and_current_checks() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 1).unwrap();
    let candidate = prepared(&f, &request);
    let membership = candidate.evidence.membership_witness.clone();
    let source = candidate.evidence.source_witness.clone();
    let observed = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let count = observed.clone();
    ADMISSION_TEST_HOOK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move |stage| {
            if matches!(stage, TestStage::InstallFinal | TestStage::CurrentFinal) {
                assert!(membership.admission_locked_for_test());
                assert!(source.admission_locked_for_test());
                count.fetch_add(1, Ordering::SeqCst);
            }
        }))
    });
    let slot = SearchAdmissionSlot::new(&request);
    slot.try_install(candidate).unwrap();
    slot.current().unwrap().unwrap();
    ADMISSION_TEST_HOOK.with(|hook| *hook.borrow_mut() = None);
    assert_eq!(observed.load(Ordering::SeqCst), 2);
}
#[test]
fn poison_between_initial_owner_check_and_final_admission_is_rejected() {
    for stage in [TestStage::InstallFinal, TestStage::CurrentFinal] {
        let f = fixture("needle");
        let request = SearchRequest::new("needle", 1).unwrap();
        let candidate = prepared(&f, &request);
        let slot = SearchAdmissionSlot::new(&request);
        if stage == TestStage::CurrentFinal {
            slot.try_install(candidate.clone()).unwrap();
        }
        let owner = f.workspace.clone();
        ADMISSION_TEST_HOOK.with(|hook| {
            *hook.borrow_mut() = Some(Box::new(move |observed| {
                if observed == stage {
                    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        let _held = owner.lock().unwrap();
                        panic!("deterministic poison after witness checks");
                    }));
                }
            }))
        });
        let result = if stage == TestStage::InstallFinal {
            slot.try_install(candidate)
        } else {
            slot.current().map(|_| ())
        };
        ADMISSION_TEST_HOOK.with(|hook| *hook.borrow_mut() = None);
        assert_eq!(result, Err(SearchError::Stale));
        f.workspace.clear_poison();
        assert!(WorkspaceStore::search_membership_snapshot(&f.workspace).is_err());
    }
}
#[test]
fn current_rechecks_same_installed_pointer_after_releasing_initial_slot_lock() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 1).unwrap();
    let old = prepared(&f, &request);
    let new = prepared(&f, &request);
    let slot = Arc::new(SearchAdmissionSlot::new(&request));
    slot.try_install(old).unwrap();
    let replacing = slot.clone();
    ADMISSION_TEST_HOOK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move |stage| {
            if stage == TestStage::CurrentCloned {
                // Avoid recursive hooks: replace only the slot's bounded reference.
                let previous = replacing.installed.lock().unwrap().replace(new.clone());
                drop(previous);
            }
        }))
    });
    assert_eq!(slot.current().unwrap_err(), SearchError::Stale);
    ADMISSION_TEST_HOOK.with(|hook| *hook.borrow_mut() = None);
    assert!(slot.current().unwrap().is_some());
}
#[test]
fn cancellation_at_final_install_and_current_is_not_success() {
    for stage in [TestStage::InstallFinal, TestStage::CurrentFinal] {
        let f = fixture("needle");
        let request = SearchRequest::new("needle", 1).unwrap();
        let candidate = prepared(&f, &request);
        let slot = SearchAdmissionSlot::new(&request);
        if stage == TestStage::CurrentFinal {
            slot.try_install(candidate.clone()).unwrap();
        }
        let cancel = request.clone();
        ADMISSION_TEST_HOOK.with(|hook| {
            *hook.borrow_mut() = Some(Box::new(move |observed| {
                if observed == stage {
                    cancel.cancel();
                }
            }))
        });
        let result = if stage == TestStage::InstallFinal {
            slot.try_install(candidate)
        } else {
            slot.current().map(|_| ())
        };
        ADMISSION_TEST_HOOK.with(|hook| *hook.borrow_mut() = None);
        assert_eq!(result, Err(SearchError::Cancelled));
    }
}
#[test]
fn cancellation_token_probe_matches_existing_atomic_bool_projection_contract() {
    let token = tokio_util::sync::CancellationToken::new();
    let query = Query::new("needle", &token).unwrap();
    assert_eq!(
        query.ranges("before needle", 0, 1, &token).unwrap().total,
        1
    );
    token.cancel();
    assert_eq!(
        query.ranges("before needle", 0, 1, &token),
        Err(projection::Error::Cancelled)
    );
    assert_eq!(
        Query::new("needle", &token).unwrap_err(),
        projection::Error::Cancelled
    );
}

#[test]
fn acquisition_rejects_receipts_that_were_never_jointly_valid() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 1).unwrap();
    let owner = f.workspace.clone();
    let id = f.id.clone();
    let source = f.controller.loaded_search_source().unwrap();
    let witness = f.controller.search_source_witness();
    ADMISSION_TEST_HOOK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move |stage| {
            if stage == TestStage::CapturedMembership {
                // Old membership is permanently invalid before the new source epoch
                // exists. Sequential acquisition must not turn these into authority.
                owner
                    .lock()
                    .unwrap()
                    .name_chat(&id, "changed between captures")
                    .unwrap();
                witness.begin().finish(
                    source.session(),
                    source.stamp().checkpoint_path(),
                    SourceStatus::Certain,
                );
            }
        }))
    });
    let result = LoadedSearchEvidence::capture(
        &f.workspace,
        &Arc::downgrade(&f.controller),
        &f.id,
        &request,
    );
    ADMISSION_TEST_HOOK.with(|hook| *hook.borrow_mut() = None);
    assert_eq!(result.unwrap_err(), SearchError::Stale);
}
#[test]
fn simultaneous_catalog_and_source_writers_and_slot_readers_finish_without_lock_inversion() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 1).unwrap();
    let candidate = prepared(&f, &request);
    let slot = Arc::new(SearchAdmissionSlot::new(&request));
    slot.try_install(candidate).unwrap();
    let start = Arc::new(std::sync::Barrier::new(4));
    let owner = f.workspace.clone();
    let id = f.id.clone();
    let barrier = start.clone();
    let catalog = std::thread::spawn(move || {
        barrier.wait();
        owner
            .lock()
            .unwrap()
            .name_chat(&id, "concurrent change")
            .unwrap();
    });
    let witness = f.controller.search_source_witness();
    let barrier = start.clone();
    let source = std::thread::spawn(move || {
        barrier.wait();
        witness.retire();
    });
    let reading = slot.clone();
    let barrier = start.clone();
    let reader = std::thread::spawn(move || {
        barrier.wait();
        for _ in 0..100 {
            let _ = reading.current();
        }
    });
    start.wait();
    catalog.join().unwrap();
    source.join().unwrap();
    reader.join().unwrap();
    assert_eq!(slot.current().unwrap_err(), SearchError::Stale);
}

#[test]
fn actor_poison_between_initial_owner_check_and_final_admission_is_rejected() {
    for stage in [TestStage::InstallFinal, TestStage::CurrentFinal] {
        let f = fixture("needle");
        let request = SearchRequest::new("needle", 1).unwrap();
        let candidate = prepared(&f, &request);
        let slot = SearchAdmissionSlot::new(&request);
        if stage == TestStage::CurrentFinal {
            slot.try_install(candidate.clone()).unwrap();
        }
        let owner = candidate.evidence.source_witness.pin_owner().unwrap();
        ADMISSION_TEST_HOOK.with(|hook| {
            *hook.borrow_mut() = Some(Box::new(move |observed| {
                if observed == stage {
                    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        owner.poison_for_test()
                    }));
                }
            }))
        });
        let result = if stage == TestStage::InstallFinal {
            slot.try_install(candidate)
        } else {
            slot.current().map(|_| ())
        };
        ADMISSION_TEST_HOOK.with(|hook| *hook.borrow_mut() = None);
        assert_eq!(result, Err(SearchError::Stale));
    }
}

#[test]
fn accepted_active_journal_text_is_searchable_without_display_publication() {
    let f = fixture_store(|store| {
        store
            .transact(|session| {
                session.submit(crate::Submission::new(
                    "ordinary prompt".into(),
                    crate::Lane::FollowUp,
                ))?;
                session.start_next()?;
                Ok(())
            })
            .unwrap();
        let reply = store.snapshot().active_reply.unwrap();
        store
            .append_delta(&reply, crate::Delta::Text("accepted active needle".into()))
            .unwrap();
        store
            .append_delta(
                &reply,
                crate::Delta::Reasoning("hidden active marker".into()),
            )
            .unwrap();
    });
    let request = SearchRequest::new("active needle", 1).unwrap();
    let candidate = prepared(&f, &request);
    assert_eq!(hit(&candidate).key().kind, PieceKind::Assistant);
    assert!(candidate.source_stamp().stream_sequence() > 0);
    assert!(matches!(
        prepared(&f, &SearchRequest::new("hidden active marker", 2).unwrap()).outcome(),
        SearchOutcome::NoMatch
    ));
}
#[test]
fn all_four_loaded_kinds_and_full_tool_input_have_exact_owners() {
    use crate::tool_history::{
        AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
    };
    let f = fixture_store(|store| {
        store.transact(|session| {
            let user = row("user_marker");
            let mut assistant = row("assistant_marker");
            assistant.role = "assistant".into();
            assistant.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
                tool_batch_timing: None, completion: Completion::Complete,
                calls: vec![crate::provider::ToolCall { id: "fixture-call".into(), name: "read".into(), arguments: serde_json::json!({"path":format!("{}input_marker", "a".repeat(9000))}) }],
                binding: ReplayBinding { profile_id: "fixture".into(), api: "openai-responses".into(), provider: "litellm".into(), model: "fixture".into(), endpoint_sha256: "0".repeat(64) }, provider_items: vec![],
            }));
            let mut output = row("output_marker"); output.role = "toolResult".into();
            output.tool_record = Some(ToolRecord::Result(ResultRecord { assistant_id: assistant.id.clone(), call_id: "fixture-call".into(), is_error: false, outcome: ToolOutcome::Completed, duration_us: None, content: None }));
            session.messages = vec![user, assistant, output]; Ok(())
        }).unwrap();
    });
    for (query, kind) in [
        ("user_marker", PieceKind::User),
        ("assistant_marker", PieceKind::Assistant),
        ("input_marker", PieceKind::ToolInput),
        ("output_marker", PieceKind::ToolOutput),
    ] {
        let candidate = prepared(&f, &SearchRequest::new(query, 1).unwrap());
        let hit = hit(&candidate);
        assert_eq!(hit.key().kind, kind);
        if matches!(kind, PieceKind::ToolInput | PieceKind::ToolOutput) {
            assert_eq!(hit.key().call_id.as_deref(), Some("fixture-call"));
            assert!(hit.key().assistant_id.is_some());
        }
        if kind == PieceKind::ToolInput {
            assert!(hit.occurrence().source.start > 8192);
            assert!(matches!(hit.target(), SourceTarget::ToolInput(_)));
        }
        if kind == PieceKind::ToolOutput {
            assert_ne!(
                hit.key().message_id,
                hit.key().assistant_id.as_ref().unwrap().as_str()
            );
        }
    }
}

#[test]
fn final_admission_lease_pins_last_workspace_owner_until_all_guards_release() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 1).unwrap();
    let candidate = prepared(&f, &request);
    let slot = SearchAdmissionSlot::new(&request);
    let weak = Arc::downgrade(&f.workspace);
    let weak_in_hook = weak.clone();
    let mut external_owner = Some(f.workspace);
    ADMISSION_TEST_HOOK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move |stage| {
            if stage == TestStage::InstallFinal {
                drop(external_owner.take());
                // The private lease is the sole remaining strong workspace owner.
                assert_eq!(weak_in_hook.strong_count(), 1);
            }
        }))
    });
    slot.try_install(candidate).unwrap();
    ADMISSION_TEST_HOOK.with(|hook| *hook.borrow_mut() = None);
    assert!(weak.upgrade().is_none());
    assert_eq!(slot.current().unwrap_err(), SearchError::Stale);
}
#[test]
fn controller_drop_racing_final_admission_retires_without_guard_destruction_deadlock() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 1).unwrap();
    let candidate = prepared(&f, &request);
    let slot = SearchAdmissionSlot::new(&request);
    let weak = Arc::downgrade(&f.controller);
    let witness = f.controller.search_source_witness();
    let (release, wait) = std::sync::mpsc::channel();
    let controller = f.controller;
    let worker = std::thread::spawn(move || {
        wait.recv().unwrap();
        drop(controller);
    });
    ADMISSION_TEST_HOOK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move |stage| {
            if stage == TestStage::InstallFinal {
                release.send(()).unwrap();
            }
        }))
    });
    slot.try_install(candidate).unwrap();
    ADMISSION_TEST_HOOK.with(|hook| *hook.borrow_mut() = None);
    worker.join().unwrap();
    assert!(weak.upgrade().is_none());
    assert!(!witness.owner_alive_for_test());
    assert_eq!(slot.current().unwrap_err(), SearchError::Stale);
}
