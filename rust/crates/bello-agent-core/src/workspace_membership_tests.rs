use super::*;
use crate::workspace_membership::{MembershipSnapshot, MembershipStatus};
use std::sync::{Arc, Mutex};
fn fixture() -> (tempfile::TempDir, Arc<Mutex<WorkspaceStore>>, ChatRecord) {
    let dir = tempfile::tempdir().unwrap();
    let store = WorkspaceStore::open(dir.path().join("catalog.json"), dir.path()).unwrap();
    let id = Uuid::new_v4().to_string();
    let mut chat = ChatRecord::new(
        id.clone(),
        "PRIVATE-TITLE".into(),
        store.chat_path(&id).unwrap(),
    );
    chat.sidebar_order = None;
    (dir, Arc::new(Mutex::new(store)), chat)
}
fn capture(owner: &Arc<Mutex<WorkspaceStore>>) -> MembershipSnapshot {
    WorkspaceStore::search_membership_snapshot(owner).unwrap()
}
fn register(owner: &Arc<Mutex<WorkspaceStore>>, chat: ChatRecord) {
    owner
        .lock()
        .unwrap()
        .register(chat, DraftRecord::default())
        .unwrap();
}
#[test]
fn empty_new_catalog_is_membership_not_file_durability_or_project_authority() {
    let (dir, owner, _) = fixture();
    let snapshot = capture(&owner);
    assert!(snapshot.members().is_empty());
    assert_eq!(snapshot.stamp().revision(), 0);
    assert_eq!(snapshot.stamp().project_id(), None);
    assert_eq!(
        snapshot.stamp().project_path(),
        fs::canonicalize(dir.path()).unwrap()
    );
    assert_eq!(
        snapshot.stamp().catalog_path(),
        dir.path().join("catalog.json")
    );
    assert!(!snapshot.stamp().catalog_path().exists());
    assert!(snapshot.is_current());
    assert_eq!(owner.lock().unwrap().state.project_id, None);
}
#[test]
fn exact_membership_pair_and_private_diagnostics() {
    let (_dir, owner, mut chat) = fixture();
    chat.materialization = ChatMaterialization::Pending;
    owner
        .lock()
        .unwrap()
        .register(
            chat.clone(),
            DraftRecord {
                text: "PRIVATE-DRAFT".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let before = fs::read(owner.lock().unwrap().path.clone()).unwrap();
    let snapshot = capture(&owner);
    assert_eq!(snapshot.members().len(), 1);
    let member = &snapshot.members()[0];
    assert_eq!(member.chat_id(), chat.id);
    assert_eq!(member.checkpoint_path(), chat.snapshot);
    assert_eq!(member.materialization(), ChatMaterialization::Pending);
    assert_eq!(snapshot.stamp().revision(), 1);
    let witness = WorkspaceStore::search_membership_witness(&owner).unwrap();
    let diagnostics = format!("{snapshot:?} {member:?} {witness:?} {:?}", snapshot.stamp());
    for private in [
        "PRIVATE-TITLE",
        "PRIVATE-DRAFT",
        &chat.id,
        chat.snapshot.to_str().unwrap(),
    ] {
        assert!(!diagnostics.contains(private));
    }
    assert_eq!(fs::read(snapshot.stamp().catalog_path()).unwrap(), before);
    assert!(!chat.snapshot.exists());
}
#[test]
fn legacy_capture_preserves_bytes_and_absent_project_uuid() {
    let (dir, owner, chat) = fixture();
    register(&owner, chat);
    let path = owner.lock().unwrap().path.clone();
    let mut value = serde_json::to_value(&owner.lock().unwrap().state).unwrap();
    value["version"] = 4.into();
    value.as_object_mut().unwrap().remove("project_id");
    for chat in value["chats"].as_array_mut().unwrap() {
        let row = chat.as_object_mut().unwrap();
        for key in [
            "tool_mode",
            "connection_id",
            "materialization",
            "last_activity_at",
        ] {
            row.remove(key);
        }
    }
    drop(owner);
    let bytes = serde_json::to_vec_pretty(&value).unwrap();
    fs::write(&path, &bytes).unwrap();
    let owner = Arc::new(Mutex::new(WorkspaceStore::open(&path, dir.path()).unwrap()));
    let snapshot = capture(&owner);
    assert_eq!(snapshot.stamp().project_id(), None);
    assert_eq!(fs::read(path).unwrap(), bytes);
}
#[test]
fn existing_project_uuid_is_paired_without_new_authority() {
    let (_dir, owner, chat) = fixture();
    register(&owner, chat);
    let old = capture(&owner);
    let id = Uuid::new_v4().to_string();
    owner
        .lock()
        .unwrap()
        .transact(|state| {
            state.project_id = Some(id.clone());
            Ok(())
        })
        .unwrap();
    let next = capture(&owner);
    assert!(!old.is_current());
    assert_eq!(next.stamp().project_id(), Some(id.as_str()));
}
#[test]
fn membership_remove_rebind_and_materialization_revoke_receipts() {
    let (_dir, owner, mut chat) = fixture();
    chat.materialization = ChatMaterialization::Pending;
    register(&owner, chat.clone());
    let pending = capture(&owner);
    owner
        .lock()
        .unwrap()
        .transact(|state| {
            state.chats[0].materialization = ChatMaterialization::CheckpointRequired;
            Ok(())
        })
        .unwrap();
    let saved = capture(&owner);
    assert!(!pending.is_current());
    assert_eq!(
        saved.members()[0].materialization(),
        ChatMaterialization::CheckpointRequired
    );
    let new_path = chat.snapshot.with_file_name("replacement.json");
    owner
        .lock()
        .unwrap()
        .transact(|state| {
            state.chats[0].snapshot = new_path.clone();
            Ok(())
        })
        .unwrap();
    let rebound = capture(&owner);
    assert!(!saved.is_current());
    assert_eq!(rebound.members()[0].checkpoint_path(), new_path);
    owner
        .lock()
        .unwrap()
        .transact(|state| {
            state.chats.clear();
            state.drafts.clear();
            Ok(())
        })
        .unwrap();
    assert!(!rebound.is_current());
    assert!(capture(&owner).members().is_empty());
}
#[test]
fn draft_only_and_archive_changes_conservatively_invalidate_membership() {
    let (_dir, owner, chat) = fixture();
    register(&owner, chat.clone());
    let old = capture(&owner);
    owner
        .lock()
        .unwrap()
        .save_draft(
            &chat.id,
            DraftRecord {
                revision: 1,
                text: "new private draft".into(),
                ..Default::default()
            },
        )
        .unwrap();
    let next = capture(&owner);
    assert!(!old.is_current());
    assert_eq!(old.members(), next.members());
    owner
        .lock()
        .unwrap()
        .transact(|state| {
            state.chats[0].archived_at = Some(1);
            Ok(())
        })
        .unwrap();
    let archived = capture(&owner);
    assert!(!next.is_current());
    assert_eq!(archived.members(), next.members());
}
#[test]
fn definite_before_rename_error_keeps_old_state_under_fresh_epoch() {
    let (_dir, owner, chat) = fixture();
    register(&owner, chat);
    let old = capture(&owner);
    let bytes = fs::read(old.stamp().catalog_path()).unwrap();
    let mut store = owner.lock().unwrap();
    store.fault = Fault::BeforeRename;
    assert!(
        store
            .transact(|state| {
                state.chats[0].title = "attempt".into();
                Ok(())
            })
            .is_err()
    );
    assert!(!store.uncertain);
    drop(store);
    let next = capture(&owner);
    assert!(!old.is_current());
    assert_eq!(old.stamp().revision(), next.stamp().revision());
    assert!(next.stamp().admission_epoch() > old.stamp().admission_epoch());
    assert_eq!(old.members(), next.members());
    assert_eq!(bytes, fs::read(next.stamp().catalog_path()).unwrap());
}
#[test]
fn after_rename_error_immediately_revokes_without_accepted_revision_change() {
    let (_dir, owner, chat) = fixture();
    register(&owner, chat);
    let old = capture(&owner);
    let witness = WorkspaceStore::search_membership_witness(&owner).unwrap();
    let mut store = owner.lock().unwrap();
    store.fault = Fault::AfterRename;
    assert!(matches!(
        store.transact(|state| {
            state.chats[0].title = "attempt".into();
            Ok(())
        }),
        Err(Error::PersistenceUncertain(_))
    ));
    assert_eq!(store.state.revision, old.stamp().revision());
    assert!(!old.is_current()); // No later acquisition is needed to discover uncertainty.
    assert_eq!(witness.status(), MembershipStatus::Uncertain);
    assert!(store.transact(|_| Ok(())).is_err());
    assert!(!old.is_current());
    drop(store);
    assert!(WorkspaceStore::search_membership_snapshot(&owner).is_err());
}
#[test]
fn every_early_transact_error_finalizes_with_new_epoch() {
    let (_dir, owner, chat) = fixture();
    register(&owner, chat);
    for kind in 0..3 {
        let old = capture(&owner);
        let mut store = owner.lock().unwrap();
        let result: Result<()> = store.transact(|state| {
            match kind {
                0 => return Err(invalid("early closure error")),
                1 => state.revision = u64::MAX,
                _ => state.chats[0].id = "invalid".into(),
            }
            Ok(())
        });
        assert!(result.is_err());
        assert!(!store.uncertain);
        drop(store);
        let next = capture(&owner);
        assert!(!old.is_current());
        assert_eq!(next.stamp().revision(), old.stamp().revision());
        assert!(next.stamp().admission_epoch() > old.stamp().admission_epoch());
    }
}
#[test]
fn unwind_with_mutex_remaining_healthy_still_revokes_forever() {
    let (_dir, owner, chat) = fixture();
    register(&owner, chat);
    let old = capture(&owner);
    let mut store = owner.lock().unwrap();
    assert!(
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _: Result<()> = store.transact(|_| panic!("fixture unwind"));
        }))
        .is_err()
    );
    assert!(!owner.is_poisoned());
    assert!(!old.is_current());
    store.transact(|_| Ok(())).unwrap(); // Search fence must not alter persistence policy.
    drop(store);
    assert!(WorkspaceStore::search_membership_snapshot(&owner).is_err());
}
#[test]
fn external_owner_poison_rejects_retained_receipt_before_any_capture() {
    let (_dir, owner, _) = fixture();
    let old = capture(&owner);
    let witness = WorkspaceStore::search_membership_witness(&owner).unwrap();
    let other = owner.clone();
    assert!(
        std::thread::spawn(move || {
            let _guard = other.lock().unwrap();
            panic!("external poison");
        })
        .join()
        .is_err()
    );
    assert!(!old.is_current());
    assert_eq!(witness.status(), MembershipStatus::Unavailable);
    assert!(WorkspaceStore::search_membership_snapshot(&owner).is_err());
    assert!(WorkspaceStore::search_membership_witness(&owner).is_err());
}
#[test]
fn repeated_same_owner_binding_and_different_owner_refusal() {
    let (_dir, owner, _) = fixture();
    let old = capture(&owner);
    assert!(capture(&owner).is_current());
    assert!(old.is_current());
    let store = Arc::try_unwrap(owner).ok().unwrap().into_inner().unwrap();
    let other = Arc::new(Mutex::new(store));
    assert!(!old.is_current());
    assert!(WorkspaceStore::search_membership_snapshot(&other).is_err());
    assert!(WorkspaceStore::search_membership_witness(&other).is_err());
    other.lock().unwrap().transact(|_| Ok(())).unwrap();
    assert!(WorkspaceStore::search_membership_snapshot(&other).is_err());
}
#[test]
fn drop_and_reopen_same_revision_get_new_incarnation() {
    let (dir, owner, chat) = fixture();
    register(&owner, chat);
    let old = capture(&owner);
    let witness = WorkspaceStore::search_membership_witness(&owner).unwrap();
    let path = old.stamp().catalog_path().to_owned();
    drop(owner);
    assert!(!old.is_current());
    assert_eq!(witness.status(), MembershipStatus::Retired);
    let owner = Arc::new(Mutex::new(WorkspaceStore::open(path, dir.path()).unwrap()));
    let next = capture(&owner);
    assert_eq!(next.stamp().revision(), old.stamp().revision());
    assert_ne!(next.stamp().incarnation(), old.stamp().incarnation());
    assert_eq!(next.members(), old.members());
}
#[test]
fn changing_is_visible_without_waiting_for_catalog_lock() {
    let (_dir, owner, _) = fixture();
    let old = capture(&owner);
    let witness = WorkspaceStore::search_membership_witness(&owner).unwrap();
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let other = owner.clone();
    let worker = std::thread::spawn(move || {
        other.lock().unwrap().transact(|_| {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        })
    });
    started_rx
        .recv_timeout(std::time::Duration::from_secs(2))
        .unwrap();
    assert_eq!(witness.status(), MembershipStatus::Changing);
    assert!(!old.is_current());
    release_tx.send(()).unwrap();
    worker.join().unwrap().unwrap();
    assert!(capture(&owner).is_current());
    assert!(!old.is_current());
}
#[tokio::test]
async fn notifications_are_coalesced_multi_subscriber_and_borrow_free() {
    let (_dir, owner, chat) = fixture();
    let witness = WorkspaceStore::search_membership_witness(&owner).unwrap();
    let mut first = witness.subscribe_changes().unwrap();
    let mut second = witness.subscribe_changes().unwrap();
    assert!(!first.has_changed().unwrap());
    register(&owner, chat);
    for changes in [&mut first, &mut second] {
        assert!(changes.has_changed().unwrap());
        tokio::time::timeout(std::time::Duration::from_secs(2), changes.changed())
            .await
            .unwrap()
            .unwrap();
        assert!(!changes.has_changed().unwrap());
    }
    // A cancelled wait consumes no notification and carries no guard.
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(5), first.changed())
            .await
            .is_err()
    );
    drop(owner);
    for changes in [&mut first, &mut second] {
        tokio::time::timeout(std::time::Duration::from_secs(2), changes.changed())
            .await
            .unwrap()
            .unwrap();
    }
    assert_eq!(witness.status(), MembershipStatus::Retired);
}

thread_local! {
    pub(super) static CAPTURE_HOOK: std::cell::RefCell<Option<Box<dyn FnMut()>>> = std::cell::RefCell::new(None);
}
#[test]
fn capture_rechecks_after_releasing_catalog_mutex() {
    let (_dir, owner, _) = fixture();
    let other = owner.clone();
    CAPTURE_HOOK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move || {
            other.lock().unwrap().transact(|_| Ok(())).unwrap();
        }))
    });
    let result = WorkspaceStore::search_membership_snapshot(&owner);
    CAPTURE_HOOK.with(|hook| *hook.borrow_mut() = None);
    assert!(result.is_err());
    assert!(capture(&owner).is_current());
}
#[test]
fn replacing_store_revokes_old_witness_while_owner_mutex_remains_healthy() {
    let (_dir, owner, _) = fixture();
    let old = capture(&owner);
    let witness = WorkspaceStore::search_membership_witness(&owner).unwrap();
    let second = tempfile::tempdir().unwrap();
    *owner.lock().unwrap() =
        WorkspaceStore::open(second.path().join("other.json"), second.path()).unwrap();
    assert!(!owner.is_poisoned());
    assert!(!old.is_current());
    assert_eq!(witness.status(), MembershipStatus::Retired);
    let new = capture(&owner);
    assert_ne!(new.stamp().incarnation(), old.stamp().incarnation());
}
#[test]
fn observed_owner_poison_remains_revoked_after_external_clear() {
    for acquisition_observes in [false, true] {
        let (_dir, owner, _) = fixture();
        let old = capture(&owner);
        let other = owner.clone();
        assert!(
            std::thread::spawn(move || {
                let _held = other.lock().unwrap();
                panic!("fixture poison");
            })
            .join()
            .is_err()
        );
        if acquisition_observes {
            assert!(WorkspaceStore::search_membership_snapshot(&owner).is_err());
        } else {
            assert!(!old.is_current());
        }
        owner.clear_poison(); // Unsupported owner recovery must not resurrect observed receipts.
        assert!(!old.is_current());
        assert!(WorkspaceStore::search_membership_snapshot(&owner).is_err());
        owner.lock().unwrap().transact(|_| Ok(())).unwrap();
        assert!(!old.is_current());
    }
}
