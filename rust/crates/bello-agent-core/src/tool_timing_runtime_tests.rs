use super::tests::{active_store, profile, reply, result};
use super::*;
use crate::{
    SessionStore,
    session::{SessionInspectionLease, WriteFault},
    tool_timing::{BatchTiming, DurationUs, SessionToolTiming},
};
use serde_json::json;

fn observed(wall: Option<u64>, duration: Option<u64>) -> CompletedToolBatch {
    let mut rows = result();
    rows[0].duration_us = duration.map(DurationUs::new);
    CompletedToolBatch {
        rows,
        timing: BatchTiming {
            wall_us: wall.map(DurationUs::new),
        },
    }
}
fn begin(store: &mut SessionStore, id: &str) {
    store
        .transact(|s| s.begin_tools(id, &reply(), &profile()))
        .unwrap();
}
fn total(session: &Session) -> Option<u64> {
    session
        .tool_timing
        .and_then(|t| t.total_us)
        .map(DurationUs::get)
}

#[test]
fn tool_timing_projection_commit_reopen_and_retry_charge_batch_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let (mut store, id) = active_store(&path);
    let mut two = reply();
    let mut second = two.calls[0].clone();
    second.id = "call-two".into();
    two.calls.push(second);
    store
        .transact(|s| s.begin_tools(&id, &two, &profile()))
        .unwrap();
    let mut batch = observed(Some(140_000), Some(120_000));
    batch.rows.push(batch.rows[0].clone());
    batch.rows[1].text = "second result".into();
    let mut projection = store.snapshot();
    projection
        .settle_completed_tool_batch(&id, batch.clone(), true, None, None)
        .unwrap();
    assert_eq!(total(&projection), Some(140_000));
    assert_eq!(total(&store.snapshot()), Some(0));
    store
        .transact(|s| s.settle_completed_tool_batch(&id, batch.clone(), true, None, None))
        .unwrap();
    assert_eq!(total(&store.snapshot()), Some(140_000));
    assert!(
        store
            .transact(|s| s.settle_completed_tool_batch(&id, batch, true, None, None))
            .is_err()
    );
    let ids = store
        .snapshot()
        .messages
        .into_iter()
        .filter_map(|row| match row.tool_record {
            Some(ToolRecord::Result(record)) => Some(record.call_id),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(ids, ["call-one", "call-two"]);
    drop(store);
    let mut reopened = SessionStore::open(&path).unwrap();
    assert_eq!(total(&reopened.snapshot()), Some(140_000));
    reopened.transact(|s| s.retry_turn().map(|_| ())).unwrap();
    assert_eq!(total(&reopened.snapshot()), Some(140_000));
}

#[test]
fn tool_timing_rename_faults_recover_exact_observation_or_unknown_never_zero() {
    for (fault, committed) in [
        (WriteFault::BeforeRename, false),
        (WriteFault::AfterRename, true),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let (mut store, id) = active_store(&path);
        begin(&mut store, &id);
        let before = fs::read(&path).unwrap();
        store.fault = fault;
        assert!(
            store
                .transact(|s| s.settle_completed_tool_batch(
                    &id,
                    observed(Some(80_000), Some(60_000)),
                    true,
                    None,
                    None
                ))
                .is_err()
        );
        assert_eq!(total(&store.snapshot()), Some(0));
        if !committed {
            assert_eq!(fs::read(&path).unwrap(), before);
        } else {
            assert!(
                store
                    .transact(|s| s.settle_completed_tool_batch(
                        &id,
                        observed(Some(80_000), Some(60_000)),
                        true,
                        None,
                        None
                    ))
                    .is_err()
            );
        }
        drop(store);
        let reopened = SessionStore::open(&path).unwrap();
        assert_eq!(
            total(&reopened.snapshot()),
            if committed { Some(80_000) } else { None }
        );
        let values = reopened
            .snapshot()
            .messages
            .into_iter()
            .filter_map(|r| match r.tool_record {
                Some(ToolRecord::Result(r)) => Some(r.duration_us),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(
            values,
            vec![if committed {
                Some(DurationUs::new(60_000))
            } else {
                None
            }]
        );
    }
}

#[test]
fn tool_timing_unknown_and_checked_overflow_are_sticky() {
    let batch = |n: Option<u64>| BatchTiming {
        wall_us: n.map(DurationUs::new),
    };
    assert_eq!(
        SessionToolTiming::adding(None, batch(Some(5))).total_us,
        None
    );
    let unknown = SessionToolTiming::adding(Some(SessionToolTiming::ZERO), batch(None));
    assert_eq!(
        SessionToolTiming::adding(Some(unknown), batch(Some(5))).total_us,
        None
    );
    let huge = SessionToolTiming {
        total_us: Some(DurationUs::new(u64::MAX)),
    };
    assert_eq!(
        SessionToolTiming::adding(Some(huge), batch(Some(1))).total_us,
        None
    );
    assert_eq!(DurationUs::from_duration(std::time::Duration::MAX), None);
    assert_eq!(
        DurationUs::from_duration(std::time::Duration::ZERO),
        Some(DurationUs::ZERO)
    );
}

#[test]
fn tool_timing_legacy_reads_are_unknown_and_byte_preserving_and_presence_is_gated() {
    for version in 1..=8 {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        let mut legacy = Session::new();
        legacy.version = version;
        legacy.tool_timing = None;
        if version == 1 {
            legacy.stream_generation.clear();
        }
        let raw = serde_json::to_value(&legacy).unwrap();
        let bytes = serde_json::to_vec_pretty(&raw).unwrap();
        fs::write(&path, &bytes).unwrap();
        if version != 1 {
            let store = SessionStore::open(&path).unwrap();
            assert_eq!(total(&store.snapshot()), None);
            drop(store);
        } else {
            fs::write(path.with_extension("lock"), b"").unwrap();
        }
        let lease = SessionInspectionLease::acquire(&path, &legacy.id).unwrap();
        assert_eq!(total(lease.snapshot()), None);
        drop(lease);
        assert_eq!(fs::read(&path).unwrap(), bytes);
        for value in [
            Value::Null,
            json!({}),
            json!({"total_us":null}),
            json!({"total_us":0}),
        ] {
            let mut malformed = raw.clone();
            malformed["tool_timing"] = value;
            let bytes = serde_json::to_vec(&malformed).unwrap();
            fs::write(&path, &bytes).unwrap();
            assert!(SessionStore::open(&path).is_err());
            assert!(SessionInspectionLease::acquire(&path, &legacy.id).is_err());
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
        for field in ["duration_us", "tool_batch_timing"] {
            let mut malformed = raw.clone();
            malformed["messages"] = json!([{"tool_record":{field:null}}]);
            let bytes = serde_json::to_vec(&malformed).unwrap();
            assert!(
                crate::skill_schema::parse_snapshot(&bytes)
                    .unwrap_err()
                    .to_string()
                    .contains("version 9")
            );
        }
    }
}

#[test]
fn tool_timing_malformed_observations_fail_and_provider_replay_is_unchanged() {
    for invalid in [json!(-1), json!(1.5), json!("1"), json!({}), json!([])] {
        assert!(serde_json::from_value::<DurationUs>(invalid.clone()).is_err());
        assert!(serde_json::from_value::<SessionToolTiming>(json!({"total_us":invalid})).is_err());
    }
    assert!(serde_json::from_value::<BatchTiming>(json!({})).is_err());
    assert!(serde_json::from_value::<SessionToolTiming>(json!({})).is_err());
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let (mut store, id) = active_store(&path);
    begin(&mut store, &id);
    store
        .transact(|s| {
            s.settle_completed_tool_batch(
                &id,
                observed(Some(75_000), Some(55_000)),
                true,
                None,
                None,
            )
        })
        .unwrap();
    let measured = store.snapshot();
    let mut legacy = measured.clone();
    legacy.tool_timing = None;
    for row in &mut legacy.messages {
        match &mut row.tool_record {
            Some(ToolRecord::Assistant(r)) => r.tool_batch_timing = None,
            Some(ToolRecord::Result(r)) => r.duration_us = None,
            None => {}
        }
    }
    let body = |s: &Session| {
        serde_json::to_vec(
            &request_body_with_tools(&profile(), &s.messages, "", &s.id, &[]).unwrap(),
        )
        .unwrap()
    };
    assert_eq!(body(&measured), body(&legacy));
}

#[tokio::test]
async fn tool_timing_explicit_entry_distinguishes_pre_cancel_refusal_and_invoked_failure() {
    let root = tempfile::tempdir().unwrap();
    let tools = NativeTools::new(
        root.path().to_owned(),
        [],
        root.path().to_owned(),
        [Capability::Ls],
    )
    .unwrap();
    let call = reply().calls.remove(0);
    let token = CancellationToken::new();
    token.cancel();
    let cancelled = run_call(&tools, &call, root.path(), token).await;
    assert_eq!(cancelled.duration_us, None);
    assert_eq!(cancelled.outcome, ToolOutcome::NotExecuted);
    let refused = run_call_with_admission(
        &tools,
        &call,
        root.path(),
        CancellationToken::new(),
        Arc::new(BatchContentBudget::default()),
        async { Err(ToolError::NotExecuted("fixture refusal".into())) },
    )
    .await;
    assert_eq!(refused.duration_us, None);
    let mut invalid = call.clone();
    invalid.name = "not-offered".into();
    let failed = run_call(&tools, &invalid, root.path(), CancellationToken::new()).await;
    assert_eq!(failed.outcome, ToolOutcome::Failed);
    assert!(failed.duration_us.is_some());
    let good = run_call(&tools, &call, root.path(), CancellationToken::new()).await;
    assert_eq!(good.outcome, ToolOutcome::Completed);
    assert!(good.duration_us.is_some());
}

#[tokio::test]
async fn tool_timing_normalization_fallback_is_unmeasured_but_effect_is_retained() {
    let root = tempfile::tempdir().unwrap();
    #[cfg(target_os = "macos")]
    let tools = NativeTools::new(
        root.path().into(),
        [],
        root.path().into(),
        [Capability::Write],
    )
    .unwrap();
    #[cfg(not(target_os = "macos"))]
    let tools = NativeTools::synthetic_mutation_fixture(
        root.path().into(),
        vec![],
        root.path().into(),
        vec![Capability::Write],
    )
    .unwrap();
    let call = ToolCall {
        id: "generated-write".into(),
        name: "write".into(),
        arguments: json!({"path":"effect","content":"retained synthetic effect"}),
    };
    let result = run_call_with_budget(
        &tools,
        &call,
        root.path(),
        CancellationToken::new(),
        Arc::new(BatchContentBudget {
            used: AtomicUsize::new(0),
            maximum: 0,
        }),
    )
    .await;
    assert_eq!(
        fs::read_to_string(root.path().join("effect")).unwrap(),
        "retained synthetic effect"
    );
    assert_eq!(result.outcome, ToolOutcome::Unknown);
    assert!(result.content.is_none());
    assert_eq!(
        result.duration_us, None,
        "record construction failed, so fallback has no per-call observation"
    );
    assert!(result.text.contains("could not be retained"));
}
