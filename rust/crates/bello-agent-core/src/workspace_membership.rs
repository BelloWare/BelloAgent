//! Revocable, process-local catalog membership evidence for future search.
//! This is neither runtime/tool authority nor a checkpoint durability receipt.
//! Capture is on demand; mutations publish small stamps, never catalog copies.
use crate::workspace::{ChatMaterialization, WorkspaceSnapshot, WorkspaceStore};
use std::{
    fmt,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock, Weak},
};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MembershipStatus {
    Changing,
    Certain,
    Uncertain,
    Retired,
    Unavailable,
}
impl MembershipStatus {
    fn terminal(self) -> bool {
        matches!(self, Self::Uncertain | Self::Retired | Self::Unavailable)
    }
}

/// Exact accepted-store boundary. Private constructors prevent fabricated receipts.
#[derive(Clone, Eq, PartialEq)]
pub struct MembershipStamp {
    incarnation: Uuid,
    admission_epoch: u64,
    catalog_path: PathBuf,
    project_path: PathBuf,
    project_id: Option<String>,
    revision: u64,
}
impl MembershipStamp {
    pub fn incarnation(&self) -> Uuid {
        self.incarnation
    }
    pub fn admission_epoch(&self) -> u64 {
        self.admission_epoch
    }
    pub fn catalog_path(&self) -> &Path {
        &self.catalog_path
    }
    pub fn project_path(&self) -> &Path {
        &self.project_path
    }
    pub fn project_id(&self) -> Option<&str> {
        self.project_id.as_deref()
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
}
impl fmt::Debug for MembershipStamp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MembershipStamp")
            .field("incarnation", &self.incarnation)
            .field("admission_epoch", &self.admission_epoch)
            .field("revision", &self.revision)
            .finish_non_exhaustive()
    }
}

struct State {
    incarnation: Uuid,
    epoch: u64,
    status: MembershipStatus,
    stamp: Option<MembershipStamp>,
    change_token: Arc<()>,
}
// Only this module can implement/bind probes. There is no externally supplied
// callback and the only operation is the standard mutex poison-bit read.
trait OwnerHealth: Send + Sync {
    fn poisoned(&self) -> bool;
}
impl<T: Send> OwnerHealth for Mutex<T> {
    fn poisoned(&self) -> bool {
        self.is_poisoned()
    }
}
struct Shared {
    state: Mutex<State>,
    changed: tokio::sync::Notify,
    owner: OnceLock<Weak<dyn OwnerHealth>>,
}
/// Cheap live revocation check. Observing a notification is never sufficient:
/// check the exact receipt again before installing or using worker output.
#[derive(Clone)]
pub struct MembershipWitness(Arc<Shared>);
impl fmt::Debug for MembershipWitness {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MembershipWitness")
            .field("status", &self.status())
            .finish_non_exhaustive()
    }
}
impl MembershipWitness {
    pub(crate) fn new(catalog: &WorkspaceSnapshot, path: &Path) -> Self {
        let witness = Self(Arc::new(Shared {
            state: Mutex::new(State {
                incarnation: Uuid::new_v4(),
                epoch: 0,
                status: MembershipStatus::Certain,
                stamp: None,
                change_token: Arc::new(()),
            }),
            changed: tokio::sync::Notify::new(),
            owner: OnceLock::new(),
        }));
        witness.finish(catalog, path, MembershipStatus::Certain);
        witness
    }
    // The public acquisition API holds this exact owner lock before binding.
    // Rebinding a moved store is refused; it cannot revive escaped receipts.
    pub(crate) fn bind_owner(
        &self,
        owner: &Arc<Mutex<WorkspaceStore>>,
    ) -> Result<(), MembershipUnavailable> {
        let erased: Arc<dyn OwnerHealth> = owner.clone();
        let weak = Arc::downgrade(&erased);
        let bound = self.0.owner.get_or_init(|| weak.clone());
        if !Weak::ptr_eq(bound, &weak) {
            self.unavailable();
            return Err(MembershipUnavailable);
        }
        Ok(())
    }
    fn owner_healthy(&self) -> bool {
        let healthy = self
            .0
            .owner
            .get()
            .is_some_and(|owner| owner.upgrade().is_some_and(|owner| !owner.poisoned()));
        if !healthy {
            // Observed poison/drop is sticky even if external code subsequently
            // clears the mutex poison bit. This never acquires the owner lock.
            self.unavailable();
        }
        healthy
    }
    pub fn status(&self) -> MembershipStatus {
        // This never acquires the catalog mutex; inspect health before witness lock.
        let healthy = self.owner_healthy();
        self.0
            .state
            .lock()
            .map_or(MembershipStatus::Unavailable, |state| {
                if state.status == MembershipStatus::Retired || healthy {
                    state.status
                } else {
                    MembershipStatus::Unavailable
                }
            })
    }
    pub fn is_current(&self, stamp: &MembershipStamp) -> bool {
        if !self.owner_healthy() {
            return false;
        }
        self.0.state.lock().is_ok_and(|state| {
            state.status == MembershipStatus::Certain && state.stamp.as_ref() == Some(stamp)
        })
    }
    /// No publicly held borrow guard can delay revocation or persistence.
    /// Changes are coalesced; always recheck the exact receipt after waking.
    pub fn subscribe_changes(&self) -> Result<MembershipChanges, MembershipUnavailable> {
        let observed = self.change_token()?;
        Ok(MembershipChanges {
            witness: self.clone(),
            observed,
        })
    }
    fn change_token(&self) -> Result<Arc<()>, MembershipUnavailable> {
        self.0
            .state
            .lock()
            .map(|state| state.change_token.clone())
            .map_err(|_| MembershipUnavailable)
    }
    fn notify(&self) {
        // No external code can hold this guard. Release it before waking tasks.
        if let Ok(mut state) = self.0.state.lock() {
            state.change_token = Arc::new(());
        }
        self.0.changed.notify_waiters();
    }
    pub(crate) fn begin(&self) -> MembershipMutation {
        if let Ok(mut state) = self.0.state.lock()
            && !state.status.terminal()
        {
            state.stamp = None;
            if let Some(epoch) = state.epoch.checked_add(1) {
                state.epoch = epoch;
                state.status = MembershipStatus::Changing;
            } else {
                state.status = MembershipStatus::Unavailable;
            }
        }
        self.notify();
        MembershipMutation {
            witness: self.clone(),
            finished: false,
        }
    }
    fn finish(&self, catalog: &WorkspaceSnapshot, path: &Path, status: MembershipStatus) {
        if let Ok(mut state) = self.0.state.lock()
            && !state.status.terminal()
        {
            state.status = status;
            state.stamp = (status == MembershipStatus::Certain).then(|| MembershipStamp {
                incarnation: state.incarnation,
                admission_epoch: state.epoch,
                catalog_path: path.to_owned(),
                project_path: catalog.project.clone(),
                project_id: catalog.project_id.clone(),
                revision: catalog.revision,
            });
        }
        self.notify();
    }
    pub(crate) fn retire(&self) {
        if let Ok(mut state) = self.0.state.lock() {
            // Retirement dominates even uncertainty/exhaustion, permanently.
            state.status = MembershipStatus::Retired;
            state.stamp = None;
        }
        self.notify();
    }
    pub(crate) fn unavailable(&self) {
        let changed = if let Ok(mut state) = self.0.state.lock()
            && !state.status.terminal()
        {
            state.status = MembershipStatus::Unavailable;
            state.stamp = None;
            true
        } else {
            false
        };
        // Repeated health checks must not create a notification feedback loop.
        if changed {
            self.notify();
        }
    }
    pub(crate) fn capture(
        &self,
        catalog: &WorkspaceSnapshot,
    ) -> Result<MembershipSnapshot, MembershipUnavailable> {
        if !self.owner_healthy() {
            return Err(MembershipUnavailable);
        }
        let stamp = {
            let state = self.0.state.lock().map_err(|_| MembershipUnavailable)?;
            if state.status != MembershipStatus::Certain {
                return Err(MembershipUnavailable);
            }
            let stamp = state.stamp.clone().ok_or(MembershipUnavailable)?;
            if stamp.revision != catalog.revision
                || stamp.project_path != catalog.project
                || stamp.project_id != catalog.project_id
            {
                return Err(MembershipUnavailable);
            }
            stamp
        };
        // The caller holds only the catalog owner lock while cloning the bounded
        // membership vector. No drafts, intents, titles or other containers escape.
        let members = catalog
            .chats
            .iter()
            .map(|chat| MembershipMember {
                chat_id: chat.id.clone(),
                checkpoint_path: chat.snapshot.clone(),
                materialization: chat.materialization,
            })
            .collect::<Vec<_>>()
            .into();
        if !self.is_current(&stamp) {
            return Err(MembershipUnavailable);
        }
        Ok(MembershipSnapshot {
            members,
            stamp,
            witness: self.clone(),
        })
    }
}

/// A notification subscription owns no lock or catalog content. Safe to retain while
/// calling retirement/mutation. Notifications can coalesce; receipts are authority.
pub struct MembershipChanges {
    witness: MembershipWitness,
    observed: Arc<()>,
}
impl MembershipChanges {
    pub fn has_changed(&self) -> Result<bool, MembershipUnavailable> {
        Ok(!Arc::ptr_eq(&self.observed, &self.witness.change_token()?))
    }
    pub async fn changed(&mut self) -> Result<(), MembershipUnavailable> {
        loop {
            let wake = self.witness.0.changed.notified();
            tokio::pin!(wake);
            // Register before checking the token to avoid a missed completion.
            wake.as_mut().enable();
            let current = self.witness.change_token()?;
            if !Arc::ptr_eq(&self.observed, &current) {
                self.observed = current;
                return Ok(());
            }
            wake.await;
        }
    }
}

pub(crate) struct MembershipMutation {
    witness: MembershipWitness,
    finished: bool,
}
impl MembershipMutation {
    pub(crate) fn finish(
        mut self,
        catalog: &WorkspaceSnapshot,
        path: &Path,
        status: MembershipStatus,
    ) {
        self.witness.finish(catalog, path, status);
        self.finished = true;
    }
}
impl Drop for MembershipMutation {
    fn drop(&mut self) {
        if !self.finished {
            self.witness.unavailable();
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
#[error("Search membership is unavailable or changed")]
pub struct MembershipUnavailable;

/// A paired membership-only snapshot and receipt; revalidation is always required.
#[derive(Clone)]
pub struct MembershipSnapshot {
    members: Arc<[MembershipMember]>,
    stamp: MembershipStamp,
    witness: MembershipWitness,
}
impl MembershipSnapshot {
    pub fn members(&self) -> &[MembershipMember] {
        &self.members
    }
    pub fn stamp(&self) -> &MembershipStamp {
        &self.stamp
    }
    pub fn is_current(&self) -> bool {
        self.witness.is_current(&self.stamp)
    }
}
impl fmt::Debug for MembershipSnapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MembershipSnapshot")
            .field("stamp", &self.stamp)
            .field("current", &self.is_current())
            .finish_non_exhaustive()
    }
}

/// The complete allowed membership payload. Debug deliberately omits private paths/IDs.
#[derive(Clone, Eq, PartialEq)]
pub struct MembershipMember {
    chat_id: String,
    checkpoint_path: PathBuf,
    materialization: ChatMaterialization,
}
impl MembershipMember {
    pub fn chat_id(&self) -> &str {
        &self.chat_id
    }
    pub fn checkpoint_path(&self) -> &Path {
        &self.checkpoint_path
    }
    pub fn materialization(&self) -> ChatMaterialization {
        self.materialization
    }
}
impl fmt::Debug for MembershipMember {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MembershipMember")
            .field("materialization", &self.materialization)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (
        tempfile::TempDir,
        Arc<Mutex<WorkspaceStore>>,
        MembershipWitness,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let owner = Arc::new(Mutex::new(
            WorkspaceStore::open(dir.path().join("catalog.json"), dir.path()).unwrap(),
        ));
        let witness = WorkspaceStore::search_membership_witness(&owner).unwrap();
        (dir, owner, witness)
    }
    #[test]
    fn epoch_exhaustion_is_permanent_search_only_failure() {
        let (_dir, owner, witness) = fixture();
        let old = WorkspaceStore::search_membership_snapshot(&owner).unwrap();
        witness.0.state.lock().unwrap().epoch = u64::MAX;
        let catalog = owner.lock().unwrap().snapshot();
        witness.begin().finish(
            &catalog,
            old.stamp().catalog_path(),
            MembershipStatus::Certain,
        );
        assert_eq!(witness.status(), MembershipStatus::Unavailable);
        assert!(!old.is_current());
        witness.begin().finish(
            &catalog,
            old.stamp().catalog_path(),
            MembershipStatus::Certain,
        );
        assert!(WorkspaceStore::search_membership_snapshot(&owner).is_err());
        let id = Uuid::new_v4().to_string();
        let mut store = owner.lock().unwrap();
        let chat = crate::workspace::ChatRecord::new(
            id.clone(),
            "test".into(),
            store.chat_path(&id).unwrap(),
        );
        store
            .register(chat, crate::workspace::DraftRecord::default())
            .unwrap();
        assert!(!store.is_uncertain());
    }
    #[test]
    fn witness_poison_fails_closed_without_changing_storage_errors() {
        let (_dir, owner, witness) = fixture();
        let old = WorkspaceStore::search_membership_snapshot(&owner).unwrap();
        let worker = witness.clone();
        assert!(
            std::thread::spawn(move || {
                let _held = worker.0.state.lock().unwrap();
                panic!("fixture poison");
            })
            .join()
            .is_err()
        );
        assert!(!old.is_current());
        assert_eq!(witness.status(), MembershipStatus::Unavailable);
        assert!(WorkspaceStore::search_membership_snapshot(&owner).is_err());
        witness.begin();
        witness.retire();
    }
    #[test]
    fn unfinished_mutation_and_retirement_cannot_be_overwritten() {
        let (_dir, owner, witness) = fixture();
        let old = WorkspaceStore::search_membership_snapshot(&owner).unwrap();
        let catalog = owner.lock().unwrap().snapshot();
        let mutation = witness.begin();
        witness.retire();
        mutation.finish(
            &catalog,
            old.stamp().catalog_path(),
            MembershipStatus::Certain,
        );
        assert_eq!(witness.status(), MembershipStatus::Retired);
        assert!(!old.is_current());
        let (_dir2, _owner2, witness2) = fixture();
        drop(witness2.begin());
        assert_eq!(witness2.status(), MembershipStatus::Unavailable);
    }
    #[tokio::test]
    async fn registered_waiters_and_cancelled_waits_do_not_lose_updates() {
        let (_dir, owner, witness) = fixture();
        let old = WorkspaceStore::search_membership_snapshot(&owner).unwrap();
        let catalog = owner.lock().unwrap().snapshot();
        let mut one = witness.subscribe_changes().unwrap();
        let mut two = witness.subscribe_changes().unwrap();
        let first = one.changed();
        let second = two.changed();
        tokio::pin!(first, second);
        assert!(futures_util::poll!(&mut first).is_pending());
        assert!(futures_util::poll!(&mut second).is_pending());
        witness.begin().finish(
            &catalog,
            old.stamp().catalog_path(),
            MembershipStatus::Certain,
        );
        for wait in [&mut first, &mut second] {
            tokio::time::timeout(std::time::Duration::from_secs(2), wait)
                .await
                .unwrap()
                .unwrap();
        }
    }
}
