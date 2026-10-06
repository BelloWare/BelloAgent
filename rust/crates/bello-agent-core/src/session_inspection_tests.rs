use super::*;
use std::{
    collections::BTreeMap,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

fn fixture() -> (tempfile::TempDir, PathBuf, Session) {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("session.json");
    let store = SessionStore::open(&path).unwrap();
    let session = store.snapshot();
    drop(store);
    (directory, path, session)
}

fn files(directory: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    fs::read_dir(directory)
        .unwrap()
        .map(|entry| {
            let path = entry.unwrap().path();
            let bytes = fs::read(&path).unwrap();
            (path, bytes)
        })
        .collect()
}

fn write_snapshot(path: &Path, session: &Session) {
    fs::write(path, serde_json::to_vec(session).unwrap()).unwrap();
}

fn active(session: &mut Session) -> String {
    session
        .submit(Submission::new("accepted input".into(), Lane::FollowUp))
        .unwrap();
    session.start_next().unwrap();
    session.active_reply.clone().unwrap()
}

#[test]
fn known_idle_formats_are_observed_without_migration_or_file_changes() {
    let (directory, path, mut session) = fixture();
    for version in [1, 2, 3] {
        session.version = version;
        session.stream_generation = if version == 1 {
            String::new()
        } else {
            Uuid::new_v4().to_string()
        };
        write_snapshot(&path, &session);
        if version != 1 {
            fs::write(
                crate::stream_journal::path(&path, &session.stream_generation).unwrap(),
                b"",
            )
            .unwrap();
        }
        let before = files(directory.path());
        let lease = SessionInspectionLease::acquire(&path, &session.id).unwrap();
        lease.require_idle().unwrap();
        assert_eq!(lease.snapshot().version, version);
        assert_eq!(
            lease.snapshot().stream_generation,
            session.stream_generation
        );
        assert_eq!(files(directory.path()), before);
        drop(lease);
        assert_eq!(files(directory.path()), before);
    }
}

#[test]
fn stopped_failed_and_paused_empty_chats_are_idle_without_clearing_retry() {
    let (directory, path, mut session) = fixture();
    for state in [RunState::Idle, RunState::Paused, RunState::Error] {
        session.state = state.clone();
        session.queue_paused = true;
        session.retry = Some(Submission::new("retry later".into(), Lane::FollowUp));
        session.error = Some("ordinary stopped or failed request".into());
        write_snapshot(&path, &session);
        let before = files(directory.path());
        let lease = SessionInspectionLease::acquire(&path, &session.id).unwrap();
        lease.require_idle().unwrap();
        assert_eq!(lease.snapshot().state, state);
        assert!(lease.snapshot().retry.is_some());
        assert!(lease.snapshot().queue_paused);
        assert_eq!(files(directory.path()), before);
    }
}

#[test]
fn unloaded_queued_and_held_chats_are_rejected_even_when_state_claims_idle() {
    let (directory, path, mut session) = fixture();
    let item = Submission::new("queued input".into(), Lane::FollowUp);
    session.submit(item.clone()).unwrap();
    for held in [false, true] {
        if held {
            session.begin_edit(&item.id, "held-edit").unwrap();
        }
        write_snapshot(&path, &session);
        let before = files(directory.path());
        let lease = SessionInspectionLease::acquire(&path, &session.id).unwrap();
        assert_eq!(lease.snapshot().state, RunState::Idle);
        assert!(lease.require_idle().is_err());
        assert_eq!(lease.snapshot().pending[0].text, "queued input");
        assert_eq!(files(directory.path()), before);
    }
}

#[test]
fn complete_journal_replays_only_in_memory_and_running_work_stays_nonidle() {
    let (directory, path, mut session) = fixture();
    let reply = active(&mut session);
    write_snapshot(&path, &session);
    let journal = crate::stream_journal::path(&path, &session.stream_generation).unwrap();
    fs::write(
        &journal,
        crate::stream_journal::encode(&session, &reply, &Delta::Text("retained fragment".into()))
            .unwrap(),
    )
    .unwrap();
    let before = files(directory.path());
    let lease = SessionInspectionLease::acquire(&path, &session.id).unwrap();
    assert!(lease.require_idle().is_err());
    assert_eq!(lease.snapshot().state, RunState::Running);
    assert_eq!(
        lease.snapshot().active_reply.as_deref(),
        Some(reply.as_str())
    );
    assert_eq!(lease.snapshot().stream_sequence, 1);
    assert_eq!(lease.snapshot().revision, session.revision + 1);
    assert_eq!(
        lease.snapshot().messages.last().unwrap().text,
        "retained fragment"
    );
    assert_eq!(files(directory.path()), before);
    drop(lease);
    assert_eq!(files(directory.path()), before);
}

#[test]
fn incomplete_journal_is_never_recovered_or_admitted() {
    let (directory, path, mut session) = fixture();
    let reply = active(&mut session);
    write_snapshot(&path, &session);
    let journal = crate::stream_journal::path(&path, &session.stream_generation).unwrap();
    let mut bytes =
        crate::stream_journal::encode(&session, &reply, &Delta::Text("prefix".into())).unwrap();
    bytes.extend_from_slice(b"{incomplete");
    fs::write(&journal, bytes).unwrap();
    let before = files(directory.path());
    assert!(SessionInspectionLease::acquire(&path, &session.id).is_err());
    assert_eq!(files(directory.path()), before);
    // Failure returns ownership immediately, without requiring recovery to run.
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path.with_extension("lock"))
        .unwrap();
    lock.try_lock().unwrap();
}

#[test]
fn malformed_future_and_foreign_checkpoints_fail_closed_without_writes() {
    let (directory, path, session) = fixture();
    let original = serde_json::to_value(&session).unwrap();
    let mut cases = vec![b"{broken".to_vec()];
    for (field, value) in [
        ("version", serde_json::json!(99)),
        ("state", serde_json::json!("future-active-state")),
        ("state", serde_json::json!("running")),
        ("id", serde_json::json!(Uuid::new_v4().to_string())),
        ("stream_generation", serde_json::json!("../../foreign")),
        ("active_reply", serde_json::json!("orphan")),
        (
            "edit",
            serde_json::json!({"edit_id":"held","turn_id":"missing"}),
        ),
    ] {
        let mut invalid = original.clone();
        invalid[field] = value;
        cases.push(serde_json::to_vec(&invalid).unwrap());
    }
    for bytes in cases {
        fs::write(&path, bytes).unwrap();
        let before = files(directory.path());
        assert!(SessionInspectionLease::acquire(&path, &session.id).is_err());
        assert_eq!(files(directory.path()), before);
    }
    assert!(SessionInspectionLease::acquire(&path, "not-an-id").is_err());
}

#[test]
fn journal_identity_sequence_format_and_revision_overflow_fail_closed() {
    let (directory, path, mut session) = fixture();
    let reply = active(&mut session);
    write_snapshot(&path, &session);
    let journal = crate::stream_journal::path(&path, &session.stream_generation).unwrap();
    let original: Value = serde_json::from_slice(
        &crate::stream_journal::encode(&session, &reply, &Delta::Text("text".into())).unwrap(),
    )
    .unwrap();
    for (field, value) in [
        ("version", serde_json::json!(2)),
        ("session", serde_json::json!(Uuid::new_v4().to_string())),
        ("generation", serde_json::json!(Uuid::new_v4().to_string())),
        ("sequence", serde_json::json!(2)),
        ("reply", serde_json::json!("foreign-reply")),
    ] {
        let mut invalid = original.clone();
        invalid[field] = value;
        let mut bytes = serde_json::to_vec(&invalid).unwrap();
        bytes.push(b'\n');
        fs::write(&journal, bytes).unwrap();
        let before = files(directory.path());
        assert!(SessionInspectionLease::acquire(&path, &session.id).is_err());
        assert_eq!(files(directory.path()), before);
    }
    session.revision = u64::MAX;
    write_snapshot(&path, &session);
    fs::write(
        &journal,
        crate::stream_journal::encode(&session, &reply, &Delta::Text("text".into())).unwrap(),
    )
    .unwrap();
    let before = files(directory.path());
    assert!(SessionInspectionLease::acquire(&path, &session.id).is_err());
    assert_eq!(files(directory.path()), before);
}

#[test]
fn absent_files_and_missing_parent_are_not_created() {
    let directory = tempfile::tempdir().unwrap();
    let id = Uuid::new_v4().to_string();
    let path = directory.path().join("session.json");
    for missing in [&path, &directory.path().join("missing/session.json")] {
        assert!(SessionInspectionLease::acquire(missing, &id).is_err());
        assert!(files(directory.path()).is_empty());
    }
    // A saved checkpoint without its original writer lock also fails closed.
    let session = Session::new();
    write_snapshot(&path, &session);
    let before = files(directory.path());
    assert!(SessionInspectionLease::acquire(&path, &session.id).is_err());
    assert_eq!(files(directory.path()), before);

    let missing = tempfile::tempdir().unwrap();
    let absent = missing.path().join("session.json");
    fs::write(absent.with_extension("lock"), b"").unwrap();
    let before = files(missing.path());
    assert!(SessionInspectionLease::acquire(&absent, &id).is_err());
    assert_eq!(files(missing.path()), before);
}

#[test]
fn oversized_checkpoint_and_journal_are_refused_before_unbounded_reads() {
    for journal in [false, true] {
        let (_directory, path, session) = fixture();
        let (target, length) = if journal {
            (
                crate::stream_journal::path(&path, &session.stream_generation).unwrap(),
                crate::stream_journal::MAX_JOURNAL_BYTES + 1,
            )
        } else {
            (path.clone(), MAX_SNAPSHOT_BYTES as u64 + 1)
        };
        File::create(&target).unwrap().set_len(length).unwrap();
        assert!(SessionInspectionLease::acquire(&path, &session.id).is_err());
        assert_eq!(fs::metadata(target).unwrap().len(), length);
    }
}

#[test]
fn live_uncertain_writer_cannot_be_replaced_by_an_inspection_lease() {
    let (directory, path, session) = fixture();
    let mut writer = SessionStore::open(&path).unwrap();
    writer.fault = WriteFault::AfterRename;
    assert!(matches!(
        writer.transact(|session| {
            session.title = "uncertain rename".into();
            Ok(())
        }),
        Err(Error::PersistenceUncertain(_))
    ));
    let before = files(directory.path());
    assert!(SessionInspectionLease::acquire(&path, &session.id).is_err());
    assert!(writer.require_certain().is_err());
    assert!(writer.require_idle_for_host_change().is_err());
    assert_eq!(files(directory.path()), before);
}

#[cfg(unix)]
#[test]
fn symlinked_checkpoint_lock_and_journal_are_rejected() {
    use std::os::unix::fs::symlink;
    for kind in ["snapshot", "lock", "journal"] {
        let (directory, path, session) = fixture();
        let target = match kind {
            "snapshot" => path.clone(),
            "lock" => path.with_extension("lock"),
            "journal" => crate::stream_journal::path(&path, &session.stream_generation).unwrap(),
            _ => unreachable!(),
        };
        let saved = directory.path().join("retained-original");
        if target.exists() {
            fs::rename(&target, &saved).unwrap();
        } else {
            fs::write(&saved, b"").unwrap();
        }
        symlink(&saved, &target).unwrap();
        let before = files(directory.path());
        assert!(SessionInspectionLease::acquire(&path, &session.id).is_err());
        assert_eq!(files(directory.path()), before);
        assert!(
            fs::symlink_metadata(&target)
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }
}

// Invoked in a separate process by the parent test. Normal focused runs no-op.
#[test]
fn inspection_subprocess_lock_probe() {
    let Ok(path) = std::env::var("BELLO_INSPECTION_LOCK_PATH") else {
        return;
    };
    let id = std::env::var("BELLO_INSPECTION_LOCK_ID").unwrap();
    let before = fs::read(&path).unwrap();
    let kind = std::env::var("BELLO_INSPECTION_LOCK_KIND").unwrap();
    let error = match kind.as_str() {
        "writer" => SessionStore::open(&path)
            .err()
            .expect("lease must exclude writer"),
        "inspection" => SessionInspectionLease::acquire(&path, &id)
            .err()
            .expect("writer must exclude lease"),
        _ => panic!("unknown probe kind"),
    };
    assert_eq!(
        error.to_string(),
        "This Rust session is already open elsewhere"
    );
    assert_eq!(fs::read(&path).unwrap(), before);
}

fn external_probe(path: &Path, id: &str, kind: &str) {
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "session::inspection_tests::inspection_subprocess_lock_probe",
            "--nocapture",
        ])
        .env("BELLO_INSPECTION_LOCK_PATH", path)
        .env("BELLO_INSPECTION_LOCK_ID", id)
        .env("BELLO_INSPECTION_LOCK_KIND", kind)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let output = child.wait_with_output().unwrap();
            panic!(
                "inspection lock probe blocked: {}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("1 passed"));
}

#[test]
fn inspection_and_external_writer_exclude_each_other_and_drop_releases() {
    let (directory, path, session) = fixture();
    let writer = SessionStore::open(&path).unwrap();
    let before = files(directory.path());
    external_probe(&path, &session.id, "inspection");
    drop(writer);
    let lease = SessionInspectionLease::acquire(&path, &session.id).unwrap();
    external_probe(&path, &session.id, "writer");
    assert!(SessionInspectionLease::acquire(&path, &session.id).is_err());
    assert_eq!(files(directory.path()), before);
    drop(lease);
    drop(SessionStore::open(&path).unwrap());
    let unwind = std::panic::catch_unwind(|| {
        let _lease = SessionInspectionLease::acquire(&path, &session.id).unwrap();
        panic!("release the read-only lease while unwinding");
    });
    assert!(unwind.is_err());
    drop(SessionStore::open(&path).unwrap());
    assert_eq!(files(directory.path()), before);
}

#[test]
fn live_store_idle_admission_shares_the_lease_predicate_and_rejects_retirement() {
    let mut store = SessionStore::pending();
    store.require_idle_for_host_change().unwrap();
    for state in [RunState::Paused, RunState::Error] {
        store.session.state = state;
        store.session.queue_paused = true;
        store.require_idle_for_host_change().unwrap();
    }
    let item = Submission::new("queued".into(), Lane::FollowUp);
    store.session.submit(item.clone()).unwrap();
    assert!(store.require_idle_for_host_change().is_err());
    store.session.pending.clear();
    store.session.edit = Some(QueueEdit {
        edit_id: "held".into(),
        turn_id: item.id.clone(),
    });
    assert!(store.require_idle_for_host_change().is_err());
    store.session.edit = None;
    store.session.active = Some(item);
    assert!(store.require_idle_for_host_change().is_err());
    store.session.active = None;
    store.session.active_reply = Some("reply".into());
    assert!(store.require_idle_for_host_change().is_err());
    store.session.active_reply = None;
    store.session.state = RunState::Running;
    assert!(store.require_idle_for_host_change().is_err());
    store.session.state = RunState::Idle;
    store.retire_writer();
    assert!(store.require_idle_for_host_change().is_err());
}

#[test]
fn idle_lock_only_conversion_keeps_ownership_without_snapshot_or_journal_writes() {
    let (directory, path, session) = fixture();
    let before = files(directory.path());
    let lease = SessionInspectionLease::acquire(&path, &session.id)
        .unwrap()
        .into_idle_lease()
        .unwrap();
    assert!(SessionStore::open(&path).is_err());
    assert_eq!(files(directory.path()), before);
    drop(lease);
    assert!(SessionStore::open(&path).is_ok());
    assert_eq!(files(directory.path()), before);
    let mut queued = session;
    queued
        .submit(Submission::new("pending".into(), Lane::FollowUp))
        .unwrap();
    write_snapshot(&path, &queued);
    assert!(
        SessionInspectionLease::acquire(&path, &queued.id)
            .unwrap()
            .into_idle_lease()
            .is_err()
    );
    assert!(SessionStore::open(&path).is_ok());
}

#[test]
fn writer_release_unlocks_even_while_an_inherited_descriptor_remains_open() {
    for retire in [false, true] {
        let (_directory, path, _session) = fixture();
        let mut writer = SessionStore::open(&path).unwrap();
        // A duplicate shares the open-file description, as an inherited child
        // descriptor does between fork and exec. Keep it alive deterministically.
        let inherited = writer._lock.as_ref().unwrap().0.try_clone().unwrap();
        assert!(SessionStore::open(&path).is_err());
        if retire {
            writer.retire_writer();
        } else {
            drop(writer);
        }
        let reopened = SessionStore::open(&path).unwrap();
        assert!(SessionStore::open(&path).is_err());
        drop(inherited);
        assert!(SessionStore::open(&path).is_err());
        drop(reopened);
    }
}

#[test]
fn inspection_release_unlocks_inherited_descriptor_and_idle_transfer_keeps_ownership() {
    for idle in [false, true] {
        let (_directory, path, session) = fixture();
        let lease = SessionInspectionLease::acquire(&path, &session.id).unwrap();
        let inherited = lease._lock.0.try_clone().unwrap();
        assert!(SessionStore::open(&path).is_err());
        if idle {
            let idle_lease = lease.into_idle_lease().unwrap();
            assert!(SessionStore::open(&path).is_err());
            drop(idle_lease);
        } else {
            drop(lease);
        }
        let reopened = SessionStore::open(&path).unwrap();
        drop(inherited);
        assert!(SessionStore::open(&path).is_err());
        drop(reopened);
    }
}
