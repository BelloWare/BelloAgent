use super::*;
use crate::{Session, SessionStore, session::SessionInspectionLease};
use std::{
    collections::BTreeMap,
    fs,
    path::Path,
    sync::atomic::{AtomicUsize, Ordering},
};
fn snapshot_files(path: &Path) -> BTreeMap<std::path::PathBuf, Vec<u8>> {
    fs::read_dir(path)
        .unwrap()
        .map(|entry| {
            let path = entry.unwrap().path();
            let bytes = fs::read(&path).unwrap();
            (path, bytes)
        })
        .collect()
}
fn fixture(text: &str) -> (tempfile::TempDir, std::path::PathBuf, Session) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let store = SessionStore::open(&path).unwrap();
    let mut session = store.snapshot();
    drop(store);
    session.messages.push(crate::Message {
        task_root_id: None,
        user_content: None,
        id: "user".into(),
        role: "user".into(),
        text: text.into(),
        reasoning: String::new(),
        replay_eligible: true,
        state: "complete".into(),
        usage: serde_json::Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
    });
    fs::write(&path, serde_json::to_vec(&session).unwrap()).unwrap();
    (dir, path, session)
}
#[tokio::test]
async fn selected_priority_cancels_but_does_not_overlap_old_permit() {
    let lane = InspectionCoordinator::default();
    let clone = lane.clone();
    let active = lane.try_background().unwrap().unwrap();
    let selected = clone.selected_open().unwrap();
    assert!(active.cancellation().is_cancelled());
    assert!(clone.try_background().unwrap().is_none());
    let future = selected.acquire();
    tokio::pin!(future);
    assert!(futures_util::poll!(future.as_mut()).is_pending());
    drop(active); // notify after registered waiter
    let selected = future.await.unwrap();
    assert!(lane.try_background().unwrap().is_none());
    drop(selected);
    assert!(lane.try_background().unwrap().is_some());
}
#[tokio::test]
async fn release_before_first_poll_is_not_a_lost_wakeup() {
    let lane = InspectionCoordinator::default();
    let active = lane.try_background().unwrap().unwrap();
    let selected = lane.selected_open().unwrap();
    drop(active);
    let acquired = selected.acquire().await.unwrap();
    drop(acquired);
    assert!(lane.try_background().unwrap().is_some());
}
#[tokio::test]
async fn selected_fifo_and_dropped_waiter_release_priority() {
    let lane = InspectionCoordinator::default();
    let active = lane.try_background().unwrap().unwrap();
    let first = lane.selected_open().unwrap();
    let second = lane.selected_open().unwrap();
    let third = lane.selected_open().unwrap();
    drop(second);
    drop(active);
    let third_future = third.acquire();
    tokio::pin!(third_future);
    assert!(futures_util::poll!(third_future.as_mut()).is_pending());
    let first = first.acquire().await.unwrap();
    assert!(futures_util::poll!(third_future.as_mut()).is_pending());
    drop(first);
    let third = third_future.await.unwrap();
    drop(third);
    let waiting = lane.selected_open().unwrap();
    drop(waiting);
    assert!(lane.try_background().unwrap().is_some());
}
#[tokio::test]
async fn dropping_polled_future_removes_queue_and_scope_cancel_keeps_permit() {
    let lane = InspectionCoordinator::default();
    let active = lane.try_background().unwrap().unwrap();
    {
        let future = lane.selected_open().unwrap().acquire();
        tokio::pin!(future);
        assert!(futures_util::poll!(future.as_mut()).is_pending());
    }
    lane.cancel_background().unwrap();
    assert!(active.cancellation().is_cancelled());
    assert!(lane.try_background().unwrap().is_none());
    drop(active);
    assert!(lane.try_background().unwrap().is_some());
}
#[test]
fn workspace_clones_share_lane_without_holding_catalog_mutex() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("project");
    fs::create_dir(&project).unwrap();
    let store = Arc::new(Mutex::new(
        crate::workspace::WorkspaceStore::open(dir.path().join("workspace.json"), &project)
            .unwrap(),
    ));
    let first = store.lock().unwrap().inspection_coordinator();
    let second = store.clone().lock().unwrap().inspection_coordinator();
    let permit = first.try_background().unwrap().unwrap();
    assert!(second.try_background().unwrap().is_none());
    let selected = second.selected_open().unwrap();
    assert!(permit.cancellation().is_cancelled());
    drop(selected);
    drop(permit);
    assert!(second.try_background().unwrap().is_some());
}
#[test]
fn parser_cancels_inside_large_string_without_relabeling_typed_errors() {
    let bytes = serde_json::to_vec(&"x".repeat(1_000_000)).unwrap();
    let token = CancellationToken::new();
    let signal = token.clone();
    let checks = Arc::new(AtomicUsize::new(0));
    let seen = checks.clone();
    PARSE_CHECK_HOOK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move || {
            if seen.fetch_add(1, Ordering::SeqCst) == 2 {
                signal.cancel();
            }
        }))
    });
    let parsed = parse::<String>(&bytes, Some(&token));
    PARSE_CHECK_HOOK.with(|hook| hook.borrow_mut().take());
    assert!(matches!(parsed, Err(Error::Cancelled)));
    assert_eq!(checks.load(Ordering::SeqCst), 3);
    for cancel in [None, Some(CancellationToken::new())] {
        assert!(matches!(
            parse::<String>(b"{broken", cancel.as_ref()),
            Err(Error::Json(_))
        ));
    }
}
#[test]
fn cancelled_lease_drops_writer_lock_and_preserves_every_byte() {
    let (dir, path, session) = fixture(&"retained ".repeat(20_000));
    let before = snapshot_files(dir.path());
    let token = CancellationToken::new();
    let signal = token.clone();
    PARSE_CHECK_HOOK.with(|hook| *hook.borrow_mut() = Some(Box::new(move || signal.cancel())));
    let lease = SessionInspectionLease::acquire_cancelled(&path, &session.id, &token);
    PARSE_CHECK_HOOK.with(|hook| hook.borrow_mut().take());
    assert!(matches!(lease, Err(Error::Cancelled)));
    assert_eq!(snapshot_files(dir.path()), before);
    let next = SessionInspectionLease::acquire(&path, &session.id).unwrap();
    assert_eq!(next.snapshot().messages[0].text, session.messages[0].text);
    drop(next);
    assert_eq!(snapshot_files(dir.path()), before);
}
#[test]
fn cancelled_and_ordinary_read_keep_same_schema_guards_and_success() {
    let (_dir, path, session) = fixture("retained");
    let bytes = fs::read(&path).unwrap();
    let token = CancellationToken::new();
    let ordinary = crate::context_recovery::parse_snapshot(&bytes).unwrap();
    let cancelled =
        crate::context_recovery::parse_snapshot_cancelled(&bytes, Some(&token)).unwrap();
    assert_eq!(
        serde_json::to_value(ordinary).unwrap(),
        serde_json::to_value(cancelled).unwrap()
    );
    for (version, key) in [(9, "context_recoveries"), (8, "tool_timing")] {
        let mut value = serde_json::to_value(&session).unwrap();
        value["version"] = serde_json::json!(version);
        value[key] = serde_json::Value::Null;
        let bytes = serde_json::to_vec(&value).unwrap();
        let original = crate::context_recovery::parse_snapshot(&bytes).unwrap_err();
        let cancellable =
            crate::context_recovery::parse_snapshot_cancelled(&bytes, Some(&token)).unwrap_err();
        assert!(matches!(original, Error::Invalid(_)));
        assert_eq!(original.to_string(), cancellable.to_string());
    }
}
#[test]
fn coordinated_lease_is_read_only_and_cancelled_background_cannot_restart() {
    let (dir, path, session) = fixture("retained");
    let before = snapshot_files(dir.path());
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    let token = permit.cancellation().clone();
    let lease = permit.inspect(&path, &session.id).unwrap();
    assert_eq!(lease.snapshot().id, session.id);
    let selected = lane.selected_open().unwrap();
    assert!(token.is_cancelled());
    assert!(lane.try_background().unwrap().is_none());
    drop(lease);
    assert!(matches!(
        permit.inspect(&path, &session.id),
        Err(Error::Cancelled)
    ));
    drop(permit);
    drop(selected);
    assert_eq!(snapshot_files(dir.path()), before);
}
#[tokio::test]
async fn notify_between_condition_check_and_await_is_not_lost() {
    let lane = InspectionCoordinator::default();
    let active = lane.try_background().unwrap().unwrap();
    let selected = lane.selected_open().unwrap();
    WAIT_CHECK_HOOK.with(|hook| *hook.borrow_mut() = Some(Box::new(move || drop(active))));
    let future = selected.acquire();
    tokio::pin!(future);
    assert!(
        futures_util::poll!(future.as_mut()).is_ready(),
        "lost notification between condition check and await"
    );
    WAIT_CHECK_HOOK.with(|hook| hook.borrow_mut().take());
}
#[test]
fn checkpoint_read_checks_cancellation_before_retaining_chunk() {
    struct CancelReader {
        token: CancellationToken,
        calls: usize,
    }
    impl Read for CancelReader {
        fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
            self.calls += 1;
            assert_eq!(self.calls, 1);
            bytes.fill(b'x');
            self.token.cancel();
            Ok(bytes.len())
        }
    }
    let token = CancellationToken::new();
    assert!(matches!(
        read_checkpoint(
            CancelReader {
                token: token.clone(),
                calls: 0
            },
            1024 * 1024,
            Some(&token)
        ),
        Err(Error::Cancelled)
    ));
    assert_eq!(read_checkpoint(&b"abcdef"[..], 3, None).unwrap(), b"abcd");
}
#[test]
fn journal_parser_cancellation_preserves_disk_and_does_not_apply_partial_record() {
    use crate::{Delta, Lane, Submission};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    let mut session = Session::new();
    session
        .submit(Submission::new("input".into(), Lane::FollowUp))
        .unwrap();
    session.start_next().unwrap();
    let reply = session.active_reply.clone().unwrap();
    let journal = crate::stream_journal::path(&path, &session.stream_generation).unwrap();
    let mut file = crate::stream_journal::create(&journal).unwrap();
    crate::stream_journal::append(
        &mut file,
        &crate::stream_journal::encode(&session, &reply, &Delta::Text("x".repeat(256 * 1024)))
            .unwrap(),
    )
    .unwrap();
    drop(file);
    let before = snapshot_files(dir.path());
    let original = serde_json::to_value(&session).unwrap();
    let token = CancellationToken::new();
    let signal = token.clone();
    PARSE_CHECK_HOOK.with(|hook| *hook.borrow_mut() = Some(Box::new(move || signal.cancel())));
    let result = crate::stream_journal::replay_read_only_cancelled(&path, &mut session, &token);
    PARSE_CHECK_HOOK.with(|hook| hook.borrow_mut().take());
    assert!(matches!(result, Err(Error::Cancelled)));
    assert_eq!(serde_json::to_value(&session).unwrap(), original);
    assert_eq!(snapshot_files(dir.path()), before);
    let replay = crate::stream_journal::replay_read_only_cancelled(
        &path,
        &mut session,
        &CancellationToken::new(),
    )
    .unwrap();
    assert_eq!(replay.records, 1);
    assert_eq!(session.messages.last().unwrap().text.len(), 256 * 1024);
    assert_eq!(snapshot_files(dir.path()), before);
}
#[test]
fn cancellable_inspection_preserves_torn_tail_corrupt_and_foreign_refusals() {
    use std::io::Write;
    let (dir, path, mut session) = fixture("retained");
    session
        .submit(crate::Submission::new(
            "input".into(),
            crate::Lane::FollowUp,
        ))
        .unwrap();
    session.start_next().unwrap();
    fs::write(&path, serde_json::to_vec(&session).unwrap()).unwrap();
    let journal = crate::stream_journal::path(&path, &session.stream_generation).unwrap();
    let mut file = crate::stream_journal::create(&journal).unwrap();
    file.write_all(b"{partial").unwrap();
    drop(file);
    let before = snapshot_files(dir.path());
    let token = CancellationToken::new();
    let original = SessionInspectionLease::acquire(&path, &session.id)
        .err()
        .unwrap();
    let cancellable = SessionInspectionLease::acquire_cancelled(&path, &session.id, &token)
        .err()
        .unwrap();
    assert_eq!(original.to_string(), cancellable.to_string());
    assert!(matches!(cancellable, Error::Invalid(_)));
    assert_eq!(snapshot_files(dir.path()), before);
    fs::write(&journal, b"{broken}\n").unwrap();
    let original = SessionInspectionLease::acquire(&path, &session.id)
        .err()
        .unwrap();
    let cancellable = SessionInspectionLease::acquire_cancelled(&path, &session.id, &token)
        .err()
        .unwrap();
    assert_eq!(original.to_string(), cancellable.to_string());
    assert!(matches!(
        SessionInspectionLease::acquire_cancelled(&path, &uuid::Uuid::new_v4().to_string(), &token),
        Err(Error::Invalid(_))
    ));
}
#[test]
fn reader_and_slice_preserve_json_lexemes_unicode_duplicates_depth_and_errors() {
    use serde_json::Value;
    let token = CancellationToken::new();
    let mut cases=vec![
        r#"{"arguments":{"large":123456789012345678901234567890,"decimal":1.2300000000000000000000,"exponent":1e400,"negative_zero":-0}}"#.to_owned(),
        r#"{"arguments":{"tiny":1e-400,"exp":1E+20,"integer":18446744073709551616}}"#.to_owned(),
        r#"{"text":"\u0065\u0301 \uD83C\uDF0D \\ \" \n"}"#.to_owned(),
        r#"{"duplicate":1,"duplicate":2}"#.to_owned(),
        r#"{"text":"\uD800"}"#.to_owned(),
        r#"{"text":"\uDF00"}"#.to_owned(),
        r#"{"value":1} trailing"#.to_owned(),
        r#"{"value":1}{"value":2}"#.to_owned(),
        r#"{"value":01}"#.to_owned(),
    ];
    for depth in [125, 126, 127, 128, 129, 130] {
        cases.push(format!("{}0{}", "[".repeat(depth), "]".repeat(depth)));
    }
    for text in cases {
        let slice = serde_json::from_slice::<Value>(text.as_bytes());
        let reader = parse::<Value>(text.as_bytes(), Some(&token));
        match (slice, reader) {
            (Ok(a), Ok(b)) => assert_eq!(
                serde_json::to_vec(&a).unwrap(),
                serde_json::to_vec(&b).unwrap(),
                "JSON pathway representation drift"
            ),
            (Err(a), Err(Error::Json(b))) => assert_eq!(
                a.classify(),
                b.classify(),
                "JSON pathway error category drift"
            ),
            _ => panic!("JSON pathway acceptance differs"),
        }
    }
    #[derive(serde::Deserialize)]
    struct Field {
        #[serde(rename = "n")]
        _n: Value,
    }
    for text in [
        br#"{"n":1,"n":2}"#.as_slice(),
        br#"{"n":"\uD800"}"#.as_slice(),
    ] {
        assert!(serde_json::from_slice::<Field>(text).is_err());
        assert!(matches!(
            parse::<Field>(text, Some(&token)),
            Err(Error::Json(_))
        ));
    }
}
#[test]
fn all_snapshot_schema_passes_preserve_duplicate_version_and_trailing_rejection() {
    let (_dir, path, _) = fixture("escaped é 🌍");
    let bytes = fs::read(path).unwrap();
    let text = String::from_utf8(bytes).unwrap();
    let duplicate = format!("{},\"version\":9}}", text.strip_suffix('}').unwrap());
    for text in [duplicate, format!("{text} trailing")] {
        let a = crate::context_recovery::parse_snapshot(text.as_bytes());
        let b = crate::context_recovery::parse_snapshot_cancelled(
            text.as_bytes(),
            Some(&CancellationToken::new()),
        );
        assert!(matches!(a, Err(Error::Json(_))));
        assert!(matches!(b, Err(Error::Json(_))));
    }
}
#[tokio::test]
async fn queued_background_is_notification_driven_and_scope_cancel_reaches_parse() {
    let lane = InspectionCoordinator::default();
    let selected = lane.selected_open().unwrap().acquire().await.unwrap();
    let scope = CancellationToken::new();
    let waiting = lane.background(&scope);
    tokio::pin!(waiting);
    assert!(futures_util::poll!(waiting.as_mut()).is_pending());
    drop(selected);
    let permit = waiting.await.unwrap();
    assert!(!permit.cancellation().is_cancelled());
    scope.cancel();
    assert!(permit.cancellation().is_cancelled());
    drop(permit);
    let scope = CancellationToken::new();
    let first = lane.background(&scope).await.unwrap();
    let selected = lane.selected_open().unwrap();
    assert!(first.cancellation().is_cancelled());
    assert!(!scope.is_cancelled());
    drop(first);
    drop(selected);
    assert!(
        !lane
            .background(&scope)
            .await
            .unwrap()
            .cancellation()
            .is_cancelled()
    );
}
#[tokio::test]
async fn cancellation_removes_selected_waiter_and_does_not_spin_background() {
    let lane = InspectionCoordinator::default();
    let active = lane.try_background().unwrap().unwrap();
    let cancel = CancellationToken::new();
    let request = lane.selected_open().unwrap();
    let future = request.acquire_cancelled(&cancel);
    tokio::pin!(future);
    assert!(futures_util::poll!(future.as_mut()).is_pending());
    cancel.cancel();
    assert!(matches!(future.await, Err(Error::Cancelled)));
    drop(active);
    assert!(lane.try_background().unwrap().is_some());
    let active = lane.selected_open().unwrap().acquire().await.unwrap();
    let cancel = CancellationToken::new();
    let background = lane.background(&cancel);
    tokio::pin!(background);
    assert!(futures_util::poll!(background.as_mut()).is_pending());
    cancel.cancel();
    assert!(matches!(background.await, Err(Error::Cancelled)));
    drop(active);
}
