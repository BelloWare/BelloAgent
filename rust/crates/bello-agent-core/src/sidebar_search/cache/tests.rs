use super::*;
use crate::{
    Message, SessionStore,
    inspection::InspectionCoordinator,
    sidebar_search::{SearchOutcome, SearchRequest, reconciliation::ReconciliationPass},
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
    workspace_membership::MembershipSnapshot,
};
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    sync::Mutex,
};
struct Fixture {
    _source: tempfile::TempDir,
    cache: tempfile::TempDir,
    owner: Arc<Mutex<WorkspaceStore>>,
    id: String,
}
fn message(text: &str) -> Message {
    Message {
        id: uuid::Uuid::new_v4().to_string(),
        role: "user".into(),
        text: text.into(),
        reasoning: "EXCLUDED_PRIVATE_REASONING".into(),
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
fn private_root() -> tempfile::TempDir {
    tempfile::Builder::new()
        .permissions(fs::Permissions::from_mode(0o700))
        .tempdir()
        .unwrap()
}
fn fixture(text: &str) -> Fixture {
    let source = tempfile::tempdir().unwrap();
    let cache = private_root();
    let mut owner =
        WorkspaceStore::open(source.path().join("catalog.json"), source.path()).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let path = owner.chat_path(&id).unwrap();
    let mut session = SessionStore::pending_with_id(&id).unwrap();
    session.persist_to(&path).unwrap();
    session
        .transact(|s| {
            s.messages.push(message(text));
            Ok(())
        })
        .unwrap();
    drop(session);
    owner
        .register(
            ChatRecord::new(id.clone(), "synthetic".into(), path),
            DraftRecord::default(),
        )
        .unwrap();
    Fixture {
        _source: source,
        cache,
        owner: Arc::new(Mutex::new(owner)),
        id,
    }
}
fn membership(f: &Fixture) -> MembershipSnapshot {
    WorkspaceStore::search_membership_snapshot(&f.owner).unwrap()
}
fn open(f: &Fixture, vfs: Option<&str>) -> PrivateCache {
    let binding = CacheBinding::from_membership(membership(f).stamp()).unwrap();
    let dir = privacy::PrivateDirectory::fixture(f.cache.path(), &binding).unwrap();
    PrivateCache::open_admitted(binding, dir, vfs).unwrap()
}
fn stage(
    cache: &mut PrivateCache,
    work: &crate::sidebar_search::reconciliation::SearchWork,
) -> UnloadedObserved {
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    let lease = permit.inspect_search(work).unwrap();
    let mut replacement = cache.begin_replacement_for_work(work).unwrap();
    let observed = lease
        .prepare_search_with_cache(work, &mut replacement)
        .unwrap();
    drop(lease);
    drop(permit);
    replacement.commit_observed(&observed).unwrap();
    cache.cleanup().unwrap();
    observed
}
#[test]
fn production_gate_is_closed_and_binding_is_full_length_delimited() {
    assert!(!CacheReadiness::production().is_ready());
    let a = CacheBinding::encode(&[b"ab", b"c"]).unwrap();
    let b = CacheBinding::encode(&[b"a", b"bc"]).unwrap();
    assert_ne!(a.namespace(), b.namespace());
    assert!(matches!(
        PrivateCache::open(a),
        Err(CacheError::PrivacyGatePending | CacheError::PlatformPending)
    ));
    runtime::probe().unwrap();
}
#[test]
fn actual_unloaded_staging_query_negative_and_startup_are_receipt_bound() {
    let f = fixture(&format!("{}rare needle late", "x".repeat(100_000)));
    let m = membership(&f);
    let before = fs::read(m.members()[0].checkpoint_path()).unwrap();
    let request = SearchRequest::new("rare needle", 1).unwrap();
    let mut pass = ReconciliationPass::begin(&request, &m).unwrap();
    let work = pass.work(&f.id).unwrap();
    let mut cache = open(&f, None);
    let observed = stage(&mut cache, &work);
    let hint = cache
        .query_handle()
        .query_observed(&observed, Arc::new(AtomicBool::new(false)))
        .unwrap()
        .unwrap();
    assert!(hint.normalized_start > 90_000);
    assert!(matches!(observed.outcome(), SearchOutcome::Match(_)));
    assert_eq!(fs::read(m.members()[0].checkpoint_path()).unwrap(), before);
    assert_eq!(cache.connection.query_row("SELECT count(*) FROM pieces WHERE normalized_text LIKE '%EXCLUDED_PRIVATE_REASONING%'",[],|r|r.get::<_,i64>(0)).unwrap(),0);
    request.cancel();
    assert!(
        cache
            .query_handle()
            .query_observed(&observed, Arc::new(AtomicBool::new(false)))
            .is_err()
    );
    drop(observed);
    drop(pass);
    drop(cache);
    let cache = open(&f, None);
    assert_eq!(
        cache
            .connection
            .query_row("SELECT count(*) FROM pieces", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    // Reopening conservatively purges persisted rows before they can participate.
}
#[test]
fn rollback_and_tombstone_keep_cleanup_closed_and_forbid_resurrection() {
    let f = fixture("needle retained");
    let request = SearchRequest::new("needle", 1).unwrap();
    let mut pass = ReconciliationPass::begin(&request, &membership(&f)).unwrap();
    let work = pass.work(&f.id).unwrap();
    let mut cache = open(&f, None);
    let observed = stage(&mut cache, &work);
    let old: i64 = cache
        .connection
        .query_row("SELECT count(*) FROM pieces", [], |r| r.get(0))
        .unwrap();
    {
        let _aborted = cache.begin_replacement(work.member()).unwrap();
    }
    assert_eq!(
        cache
            .connection
            .query_row("SELECT count(*) FROM pieces", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        old
    );
    assert_eq!(
        cache
            .query_handle()
            .query_observed(&observed, Arc::new(AtomicBool::new(false))),
        Err(CacheError::CleanupPending)
    );
    cache.cleanup().unwrap();
    cache.delete(&f.id).unwrap();
    assert!(matches!(
        cache.begin_replacement(work.member()),
        Err(CacheError::BindingMismatch)
    ));
    cache.cleanup().unwrap();
    cache
        .connection
        .execute_batch("INSERT INTO docs(docs,rank) VALUES('integrity-check',1)")
        .unwrap();
}
#[test]
fn stale_attempt_cannot_commit_or_admit_even_after_successful_staging() {
    let f = fixture("needle retained");
    let request = SearchRequest::new("needle", 1).unwrap();
    let mut pass = ReconciliationPass::begin(&request, &membership(&f)).unwrap();
    let work = pass.work(&f.id).unwrap();
    let mut cache = open(&f, None);
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    let lease = permit.inspect_search(&work).unwrap();
    let mut replacement = cache.begin_replacement(work.member()).unwrap();
    let observed = lease
        .prepare_search_with_cache(&work, &mut replacement)
        .unwrap();
    drop(lease);
    drop(permit);
    pass.remove(&f.id);
    assert_eq!(
        replacement.commit_observed(&observed),
        Err(CacheError::Cancelled)
    );
    assert!(cache.barrier.cleanup.load(Ordering::SeqCst));
    cache.cleanup().unwrap();
    assert_eq!(
        cache
            .connection
            .query_row("SELECT count(*) FROM pieces", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
}
#[test]
fn reader_barrier_and_real_busy_wal_never_claim_cleanup() {
    let f = fixture("needle retained");
    let request = SearchRequest::new("needle", 1).unwrap();
    let mut pass = ReconciliationPass::begin(&request, &membership(&f)).unwrap();
    let work = pass.work(&f.id).unwrap();
    let mut cache = open(&f, None);
    let observed = stage(&mut cache, &work);
    let reader = Connection::open(cache.directory.path.join("cache.sqlite3")).unwrap();
    runtime::configure(&reader, true).unwrap();
    reader
        .execute_batch("BEGIN; SELECT * FROM pieces;")
        .unwrap();
    assert_eq!(cache.delete(&f.id), Err(CacheError::CleanupPending));
    assert!(
        cache
            .query_handle()
            .query_observed(&observed, Arc::new(AtomicBool::new(false)))
            .is_err()
    );
    reader.execute_batch("ROLLBACK").unwrap();
    drop(reader);
    cache.cleanup().unwrap();
    assert_eq!(
        fs::metadata(cache.directory.path.join("cache.sqlite3-wal"))
            .unwrap()
            .len(),
        0
    );
    cache.barrier.readers.fetch_add(1, Ordering::SeqCst);
    assert_eq!(cache.cleanup(), Err(CacheError::Busy));
    cache.barrier.readers.fetch_sub(1, Ordering::SeqCst);
    cache.cleanup().unwrap();
}
#[test]
fn private_admission_rejects_links_modes_unknown_siblings_and_second_owner() {
    for mode in [0o755, 0o777] {
        let f = fixture("needle");
        fs::set_permissions(f.cache.path(), fs::Permissions::from_mode(mode)).unwrap();
        let b = CacheBinding::from_membership(membership(&f).stamp()).unwrap();
        assert!(privacy::PrivateDirectory::fixture(f.cache.path(), &b).is_err());
    }
    let f = fixture("needle");
    let cache = open(&f, None);
    let path = cache.directory.path.clone();
    let binding = cache.binding.clone();
    assert!(matches!(
        privacy::PrivateDirectory::fixture(f.cache.path(), &binding),
        Err(CacheError::Busy)
    ));
    drop(cache);
    for kind in ["symlink", "hardlink", "mode", "unknown"] {
        let target = path.join(if kind == "unknown" {
            "unrecognized"
        } else {
            "cache.sqlite3-wal"
        });
        if target.exists() {
            fs::remove_file(&target).unwrap();
        }
        match kind {
            "symlink" => symlink(path.join("cache.sqlite3"), &target).unwrap(),
            "hardlink" => fs::hard_link(path.join("cache.sqlite3"), &target).unwrap(),
            _ => {
                fs::write(&target, []).unwrap();
                fs::set_permissions(&target, fs::Permissions::from_mode(0o644)).unwrap();
            }
        }
        assert!(privacy::PrivateDirectory::fixture(f.cache.path(), &binding).is_err());
        fs::remove_file(target).unwrap();
    }
}
#[test]
fn chunk_seams_match_canonical_normalization_and_keep_scalar_overlap() {
    let cancel = AtomicBool::new(false);
    for start in [32_512, 32_767, 32_768, 65_023] {
        let query = "é".repeat(256);
        let text = format!("{}{} end", "界".repeat(start), query);
        let mut chunks = Vec::new();
        projection::normalized_chunks::<CacheError>(&text, &cancel, |offset, text| {
            chunks.push((offset, text.to_owned()));
            Ok(())
        })
        .unwrap();
        assert!(chunks.iter().all(|(_, s)| s.chars().count() <= 32_768));
        let found = chunks
            .iter()
            .filter_map(|(offset, text)| text.find(&query).map(|n| offset + n))
            .min()
            .unwrap();
        assert_eq!(found, start * 3);
    }
}

// Exactly one process owns the observer registration. No tests in its child run
// concurrently, and no non-synthetic path or data enters the observer.
#[test]
fn supported_vfs_observer_product_repository_no_spill_and_live_controls() {
    let key = "BELLO_SYNTHETIC_VFS_CHILD";
    if std::env::var_os(key).is_none() {
        let out=std::process::Command::new(std::env::current_exe().unwrap()).args(["--exact","sidebar_search::cache::tests::supported_vfs_observer_product_repository_no_spill_and_live_controls","--nocapture"]).env(key,"1").output().unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let f = fixture(&format!("{} needle", "abcdefgh界 ".repeat(250_000)));
    let mut observer = observer::Observer::register(f.cache.path());
    observer.live_temp_control();
    let mut cache = open(&f, Some(observer.name()));
    let request = SearchRequest::new("needle", 1).unwrap();
    let mut pass = ReconciliationPass::begin(&request, &membership(&f)).unwrap();
    let work = pass.work(&f.id).unwrap();
    let observed = stage(&mut cache, &work);
    let before = observer.counts().0;
    let reads = observer.reads();
    assert!(
        cache
            .query_handle()
            .query_observed(&observed, Arc::new(AtomicBool::new(false)))
            .unwrap()
            .is_some()
    );
    assert!(observer.counts().0 > before && observer.reads() > reads);
    let reader = Connection::open_with_flags_and_vfs(
        cache.directory.path.join("cache.sqlite3"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE,
        observer.name(),
    )
    .unwrap();
    runtime::configure(&reader, true).unwrap();
    reader
        .execute_batch("BEGIN; SELECT * FROM pieces;")
        .unwrap();
    assert_eq!(cache.invalidate(&f.id), Err(CacheError::CleanupPending));
    reader.execute_batch("ROLLBACK").unwrap();
    drop(reader);
    cache.cleanup().unwrap();
    stage(&mut cache, &work);
    // The actual reader query runs through this VFS and a low test-only budget
    // forces its own progress-handler path; the same normal-budget query passes.
    let common = SearchRequest::new("abcdefgh", 2).unwrap();
    let mut common_pass = ReconciliationPass::begin(&common, &membership(&f)).unwrap();
    let common_work = common_pass.work(&f.id).unwrap();
    let common_observed = stage(&mut cache, &common_work);
    let mut limited = cache.query_handle();
    limited.instruction_budget = 0;
    assert!(
        limited
            .query_observed(&common_observed, Arc::new(AtomicBool::new(false)))
            .is_err()
    );
    assert!(
        cache
            .query_handle()
            .query_observed(&common_observed, Arc::new(AtomicBool::new(false)))
            .unwrap()
            .is_some()
    );
    // Inject failure after the actual replacement starts, while chunk staging
    // writes through the observer. Old complete rows must survive rollback.
    let lane = InspectionCoordinator::default();
    let mut permit = lane.try_background().unwrap().unwrap();
    let lease = permit.inspect_search(&common_work).unwrap();
    let mut replacement = cache.begin_replacement_for_work(&common_work).unwrap();
    observer.faults_after(0);
    assert!(
        lease
            .prepare_search_with_cache(&common_work, &mut replacement)
            .is_err()
    );
    observer.faults_after(-1);
    drop(replacement);
    drop(lease);
    drop(permit);
    cache.cleanup().unwrap();
    assert!(
        cache
            .query_handle()
            .query_observed(&common_observed, Arc::new(AtomicBool::new(false)))
            .unwrap()
            .is_some()
    );
    cache.connection.execute_batch("CREATE TEMP TABLE stress(value TEXT UNIQUE); WITH RECURSIVE n(x) AS(VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<20000) INSERT INTO stress SELECT printf('%08d',x)||printf('%0200d',x) FROM n;").unwrap();
    let n:i64=cache.connection.query_row("SELECT sum(length(value)) FROM (SELECT value FROM stress ORDER BY substr(value,4) DESC)",[],|r|r.get(0)).unwrap();
    assert!(n > 4_000_000);
    assert!(
        cache
            .connection
            .execute_batch("UPDATE stress SET value='duplicate';")
            .is_err()
    );
    assert_eq!(
        cache
            .connection
            .query_row("SELECT count(*) FROM stress", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        20000
    );
    observer.faults_after(0);
    assert!(cache.delete(&f.id).is_err());
    assert!(cache.barrier.cleanup.load(Ordering::SeqCst));
    observer.faults_after(-1);
    cache.cleanup().unwrap();
    assert!(cache.pending_suppression.is_empty());
    assert_eq!(
        cache
            .connection
            .query_row("SELECT count(*) FROM pieces", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        cache
            .connection
            .query_row("SELECT count(*) FROM tombstones", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
    cache.directory.validate_siblings().unwrap();
    let counts = observer.counts();
    assert!(counts.0 > 0 && counts.1 > 0 && counts.2 > 0 && counts.3 > 0);
    observer.assert_private_no_spill();
    drop(cache);
    observer.assert_private_no_spill();
}

#[test]
fn crash_before_and_after_commit_restarts_unavailable_and_scrubs() {
    const CHILD: &str = "BELLO_CACHE_CRASH_CHILD";
    if let Some(mode) = std::env::var_os(CHILD) {
        let root = PathBuf::from(std::env::var_os("BELLO_CACHE_CRASH_ROOT").unwrap());
        let binding =
            CacheBinding::encode(&[b"synthetic-crash-catalog", b"synthetic-project"]).unwrap();
        let observer = observer::Observer::register(&root);
        let directory = privacy::PrivateDirectory::fixture(&root, &binding).unwrap();
        let mut cache =
            PrivateCache::open_admitted(binding, directory, Some(observer.name())).unwrap();
        cache.mark_pending().unwrap();
        let tx = cache
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .unwrap();
        tx.execute("INSERT INTO chats VALUES('synthetic',zeroblob(32))", [])
            .unwrap();
        let payload = "SYNTHETIC_CRASH_MARKER ".repeat(4000);
        for n in 0..80i64 {
            tx.execute("INSERT INTO pieces(chat_id,piece_index,message_position,piece_ordinal,chunk_start,normalized_text) VALUES('synthetic',?1,?1,0,0,?2)",params![n,payload]).unwrap();
        }
        if mode == "commit" {
            tx.commit().unwrap();
        } else {
            std::mem::forget(tx);
        }
        assert!(
            fs::metadata(cache.directory.path.join("cache.sqlite3-wal"))
                .unwrap()
                .len()
                > 0
        );
        observer.assert_private_no_spill();
        eprintln!(
            "synthetic crash observer exercised: {:?}",
            observer.counts()
        );
        std::process::exit(73);
    }
    for mode in ["uncommitted", "commit"] {
        let root = private_root();
        let out=std::process::Command::new(std::env::current_exe().unwrap()).args(["--exact","sidebar_search::cache::tests::crash_before_and_after_commit_restarts_unavailable_and_scrubs","--nocapture"]).env(CHILD,mode).env("BELLO_CACHE_CRASH_ROOT",root.path()).output().unwrap();
        assert_eq!(
            out.status.code(),
            Some(73),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(
            String::from_utf8_lossy(&out.stderr).contains("synthetic crash observer exercised")
        );
        let binding =
            CacheBinding::encode(&[b"synthetic-crash-catalog", b"synthetic-project"]).unwrap();
        let directory = privacy::PrivateDirectory::fixture(root.path(), &binding).unwrap();
        let cache = PrivateCache::open_admitted(binding, directory, None).unwrap();
        assert_eq!(
            cache
                .connection
                .query_row("SELECT count(*) FROM pieces", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            fs::metadata(cache.directory.path.join("cache.sqlite3-wal"))
                .unwrap()
                .len(),
            0
        );
    }
}
#[test]
fn corrupt_owned_cache_refuses_startup_without_source_recovery() {
    const KEY: &str = "BELLO_CORRUPT_OBSERVER_CHILD";
    if std::env::var_os(KEY).is_none() {
        let out=std::process::Command::new(std::env::current_exe().unwrap()).args(["--exact","sidebar_search::cache::tests::corrupt_owned_cache_refuses_startup_without_source_recovery","--nocapture"]).env(KEY,"1").output().unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    use std::io::{Seek, Write};
    let f = fixture("needle");
    let observer = observer::Observer::register(f.cache.path());
    let cache = open(&f, Some(observer.name()));
    let binding = cache.binding.clone();
    let path = cache.directory.path.join("cache.sqlite3");
    drop(cache);
    let mut file = fs::OpenOptions::new().write(true).open(path).unwrap();
    file.seek(std::io::SeekFrom::Start(0)).unwrap();
    file.write_all(b"invalid synthetic cache header!!").unwrap();
    drop(file);
    let directory = privacy::PrivateDirectory::fixture(f.cache.path(), &binding).unwrap();
    assert!(PrivateCache::open_admitted(binding, directory, Some(observer.name())).is_err());
    observer.assert_private_no_spill();
}
#[test]
fn keyset_refinement_continues_past_false_candidates_and_cancel_is_not_empty() {
    let f = fixture("abc");
    let mut cache = open(&f, None);
    let digest = [7u8; 32];
    cache.mark_pending().unwrap();
    cache
        .connection
        .execute(
            "INSERT INTO chats VALUES(?1,?2)",
            params![f.id, digest.as_slice()],
        )
        .unwrap();
    // NUL is forbidden by production projection. Synthetic corruption/candidate
    // control verifies the reader still cannot call an FTS false-positive exact.
    for position in 0..34i64 {
        let text = if position == 0 { "abc" } else { "a\0bc" };
        cache.connection.execute("INSERT INTO pieces(chat_id,piece_index,message_position,piece_ordinal,chunk_start,normalized_text) VALUES(?1,?2,?2,0,0,?3)",params![f.id,position,text]).unwrap();
    }
    cache.cleanup().unwrap();
    let query = SearchRequest::new("abc", 0).unwrap();
    let handle = cache.query_handle();
    assert_eq!(
        handle
            .lookup(&f.id, digest, &query, Arc::new(AtomicBool::new(false)))
            .unwrap()
            .unwrap()
            .piece_index,
        0
    );
    assert_eq!(
        handle.lookup(&f.id, digest, &query, Arc::new(AtomicBool::new(true))),
        Err(CacheError::Cancelled)
    );
    cache.invalidate(&f.id).unwrap();
    let m = membership(&f);
    assert!(cache.begin_replacement(&m.members()[0]).is_ok());
}
#[test]
fn barrier_exhaustion_is_sticky_and_close_revokes_old_handles() {
    let f = fixture("needle");
    let mut cache = open(&f, None);
    let handle = cache.query_handle();
    let request = SearchRequest::new("needle", 1).unwrap();
    cache.barrier.epoch.store(u64::MAX, Ordering::SeqCst);
    assert_eq!(cache.cleanup(), Err(CacheError::ResourceLimit));
    assert_eq!(cache.barrier.epoch.load(Ordering::SeqCst), u64::MAX);
    assert!(!cache.readiness().is_ready());
    assert!(
        handle
            .lookup(&f.id, [0; 32], &request, Arc::new(AtomicBool::new(false)))
            .is_err()
    );
    drop(cache);
    assert!(
        handle
            .lookup(&f.id, [0; 32], &request, Arc::new(AtomicBool::new(false)))
            .is_err()
    );
}
#[cfg(target_os = "macos")]
#[test]
fn native_live_allow_acl_is_rejected_without_changing_other_paths() {
    let root = private_root();
    let add = std::process::Command::new("/bin/chmod")
        .args(["+a", "everyone allow read"])
        .arg(root.path())
        .status()
        .unwrap();
    assert!(add.success());
    let binding = CacheBinding::encode(&[b"synthetic-acl-catalog", b"synthetic-project"]).unwrap();
    let result = privacy::PrivateDirectory::fixture(root.path(), &binding);
    let remove = std::process::Command::new("/bin/chmod")
        .args(["-a", "everyone allow read"])
        .arg(root.path())
        .status()
        .unwrap();
    assert!(remove.success());
    assert!(result.is_err());
    assert!(privacy::PrivateDirectory::fixture(root.path(), &binding).is_ok());
}
#[test]
fn writer_sql_cancellation_rolls_back_and_does_not_cancel_the_next_job() {
    let f = fixture("needle");
    let request = SearchRequest::new("needle", 1).unwrap();
    let mut pass = ReconciliationPass::begin(&request, &membership(&f)).unwrap();
    let work = pass.work(&f.id).unwrap();
    let mut cache = open(&f, None);
    let replacement = cache.begin_replacement_for_work(&work).unwrap();
    request.cancel();
    let result=replacement.transaction.as_ref().unwrap().query_row("WITH RECURSIVE n(x) AS(VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000) SELECT sum(x) FROM n",[],|r|r.get::<_,i64>(0));
    assert!(
        matches!(result,Err(rusqlite::Error::SqliteFailure(error,_)) if error.code==rusqlite::ErrorCode::OperationInterrupted)
    );
    drop(replacement);
    cache.cleanup().unwrap();
    let next = SearchRequest::new("needle", 2).unwrap();
    let mut pass = ReconciliationPass::begin(&next, &membership(&f)).unwrap();
    let work = pass.work(&f.id).unwrap();
    let observed = stage(&mut cache, &work);
    assert!(matches!(observed.outcome(), SearchOutcome::Match(_)));
}
#[test]
fn corrupt_numeric_metadata_fails_closed_without_overflow_or_false_empty() {
    const KEY: &str = "BELLO_NUMERIC_CORRUPTION_CHILD";
    if std::env::var_os(KEY).is_none() {
        let out=std::process::Command::new(std::env::current_exe().unwrap()).args(["--exact","sidebar_search::cache::tests::corrupt_numeric_metadata_fails_closed_without_overflow_or_false_empty","--nocapture"]).env(KEY,"1").output().unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let f = fixture("abc");
    let observer = observer::Observer::register(f.cache.path());
    let mut cache = open(&f, Some(observer.name()));
    let digest = [9u8; 32];
    cache
        .connection
        .execute(
            "INSERT INTO chats VALUES(?1,?2)",
            params![f.id, digest.as_slice()],
        )
        .unwrap();
    let request = SearchRequest::new("abc", 1).unwrap();
    for (piece, position, ordinal, start) in [
        (-1, 0, 0, 0),
        (0, -1, 0, 0),
        (0, 0, -1, 0),
        (0, 0, 0, -1),
        (i64::MAX, 0, 0, 0),
        (0, 0, 0, i64::MAX),
    ] {
        cache.mark_pending().unwrap();
        cache.connection.execute("DELETE FROM pieces", []).unwrap();
        cache.connection.execute("INSERT INTO pieces(chat_id,piece_index,message_position,piece_ordinal,chunk_start,normalized_text) VALUES(?1,?2,?3,?4,?5,'xabc')",params![f.id,piece,position,ordinal,start]).unwrap();
        cache.cleanup().unwrap();
        assert_eq!(
            cache
                .query_handle()
                .lookup(&f.id, digest, &request, Arc::new(AtomicBool::new(false))),
            Err(CacheError::Database)
        );
    }
    observer.assert_private_no_spill();
    assert!(observer.reads() > 0);
}
#[test]
fn lifecycle_only_loaded_revocation_refuses_commit_with_still_current_source() {
    use crate::{
        Controller,
        sidebar_search::{LoadedSearchEvidence, reconciliation::SourceRoute},
    };
    let f = fixture("needle");
    let m = membership(&f);
    let request = SearchRequest::new("needle", 1).unwrap();
    let controller = Controller::new(
        SessionStore::open(m.members()[0].checkpoint_path()).unwrap(),
        None,
    )
    .unwrap();
    let mut pass = ReconciliationPass::begin(&request, &m).unwrap();
    pass.transition(&f.id, SourceRoute::Loaded).unwrap();
    let work = pass.work(&f.id).unwrap();
    let mut cache = open(&f, None);
    let evidence =
        LoadedSearchEvidence::capture(&f.owner, &Arc::downgrade(&controller), &f.id, &request)
            .unwrap();
    let mut replacement = cache.begin_replacement_for_work(&work).unwrap();
    let candidate = evidence.prepare_with_cache(&mut replacement).unwrap();
    pass.transition(&f.id, SourceRoute::Blocked).unwrap();
    assert!(candidate.cache_check().is_ok());
    assert_eq!(
        replacement.commit_loaded(&candidate),
        Err(CacheError::Cancelled)
    );
    cache.cleanup().unwrap();
    assert_eq!(
        cache
            .connection
            .query_row("SELECT count(*) FROM pieces", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
}
#[test]
fn query_worker_bound_and_close_between_admission_checks_are_enforced() {
    let f = fixture("needle");
    let cache = open(&f, None);
    let handle = cache.query_handle();
    let request = SearchRequest::new("needle", 1).unwrap();
    cache.barrier.readers.store(1, Ordering::SeqCst);
    assert_eq!(
        handle.lookup(&f.id, [0; 32], &request, Arc::new(AtomicBool::new(false))),
        Err(CacheError::Busy)
    );
    cache.barrier.readers.store(0, Ordering::SeqCst);
    let closing = cache.barrier.clone();
    query::on_reader_entry(move || {
        closing.closed.store(true, Ordering::SeqCst);
    });
    assert_eq!(
        handle.lookup(&f.id, [0; 32], &request, Arc::new(AtomicBool::new(false))),
        Err(CacheError::CleanupPending)
    );
    assert_eq!(cache.barrier.readers.load(Ordering::SeqCst), 0);
}
#[test]
fn incompatible_persisted_versions_refuse_before_reconciliation() {
    let f = fixture("needle");
    let cache = open(&f, None);
    let binding = cache.binding.clone();
    cache
        .connection
        .execute("UPDATE meta SET projection_version=999", [])
        .unwrap();
    drop(cache);
    let directory = privacy::PrivateDirectory::fixture(f.cache.path(), &binding).unwrap();
    assert!(matches!(
        PrivateCache::open_admitted(binding, directory, None),
        Err(CacheError::BindingMismatch)
    ));
}
