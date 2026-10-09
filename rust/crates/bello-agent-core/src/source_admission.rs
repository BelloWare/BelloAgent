//! Revocable, process-local evidence for accepted loaded search content.
//!
//! This is neither runtime/tool authority nor an unloaded-file durability receipt.
//! Capture is deliberately on demand; updates publish small stamps, not transcripts.
use crate::Session;
use std::{
    fmt,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock, Weak},
};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SourceStatus {
    Pending,
    Changing,
    Certain,
    Uncertain,
    Retired,
    Unavailable,
}
impl SourceStatus {
    fn terminal(self) -> bool {
        matches!(self, Self::Uncertain | Self::Retired | Self::Unavailable)
    }
}

/// Exact accepted-store boundary. Private constructors prevent fabricated receipts.
#[derive(Clone, Eq, PartialEq)]
pub struct LoadedSourceStamp {
    incarnation: Uuid,
    admission_epoch: u64,
    session_id: String,
    checkpoint_path: PathBuf,
    revision: u64,
    stream_generation: String,
    stream_sequence: u64,
}
impl LoadedSourceStamp {
    pub fn incarnation(&self) -> Uuid {
        self.incarnation
    }
    pub fn admission_epoch(&self) -> u64 {
        self.admission_epoch
    }
    pub fn session_id(&self) -> &str {
        &self.session_id
    }
    pub fn checkpoint_path(&self) -> &Path {
        &self.checkpoint_path
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn stream_generation(&self) -> &str {
        &self.stream_generation
    }
    pub fn stream_sequence(&self) -> u64 {
        self.stream_sequence
    }
}
impl fmt::Debug for LoadedSourceStamp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LoadedSourceStamp")
            .field("incarnation", &self.incarnation)
            .field("admission_epoch", &self.admission_epoch)
            .field("revision", &self.revision)
            .field("stream_sequence", &self.stream_sequence)
            .finish_non_exhaustive()
    }
}

struct State {
    incarnation: Uuid,
    epoch: u64,
    status: SourceStatus,
    stamp: Option<LoadedSourceStamp>,
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
pub struct SourceWitness(Arc<Shared>);
impl fmt::Debug for SourceWitness {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SourceWitness")
            .field("status", &self.status())
            .finish_non_exhaustive()
    }
}
impl SourceWitness {
    pub(crate) fn new(session: &Session, path: &Path, status: SourceStatus) -> Self {
        let witness = Self(Arc::new(Shared {
            state: Mutex::new(State {
                incarnation: Uuid::new_v4(),
                epoch: 0,
                status,
                stamp: None,
                change_token: Arc::new(()),
            }),
            changed: tokio::sync::Notify::new(),
            owner: OnceLock::new(),
        }));
        witness.finish(session, path, status);
        witness
    }
    /// Bind before the Controller escapes. The weak probe cannot retain the
    /// actor or form a cycle through its SessionStore's own witness.
    pub(crate) fn bind_owner<T: Send + 'static>(&self, owner: &Arc<Mutex<T>>) {
        let erased: Arc<dyn OwnerHealth> = owner.clone();
        if self.0.owner.set(Arc::downgrade(&erased)).is_err() {
            self.unavailable();
        }
    }
    fn owner_healthy(&self) -> bool {
        self.0
            .owner
            .get()
            .is_none_or(|owner| owner.upgrade().is_some_and(|owner| !owner.poisoned()))
    }
    pub fn status(&self) -> SourceStatus {
        // This never acquires the actor mutex; inspect health before witness lock.
        let healthy = self.owner_healthy();
        self.0
            .state
            .lock()
            .map_or(SourceStatus::Unavailable, |state| {
                if state.status == SourceStatus::Retired || healthy {
                    state.status
                } else {
                    SourceStatus::Unavailable
                }
            })
    }
    pub fn is_current(&self, stamp: &LoadedSourceStamp) -> bool {
        if !self.owner_healthy() {
            return false;
        }
        self.0.state.lock().is_ok_and(|state| {
            state.status == SourceStatus::Certain && state.stamp.as_ref() == Some(stamp)
        })
    }
    /// No publicly held borrow guard can delay revocation or persistence.
    /// Changes are coalesced; always recheck the exact receipt after waking.
    pub fn subscribe_changes(&self) -> Result<SourceChanges, SourceUnavailable> {
        let observed = self.change_token()?;
        Ok(SourceChanges {
            witness: self.clone(),
            observed,
        })
    }
    fn change_token(&self) -> Result<Arc<()>, SourceUnavailable> {
        self.0
            .state
            .lock()
            .map(|state| state.change_token.clone())
            .map_err(|_| SourceUnavailable)
    }
    fn notify(&self) {
        // No external code can hold this guard. Release it before waking tasks.
        if let Ok(mut state) = self.0.state.lock() {
            state.change_token = Arc::new(());
        }
        self.0.changed.notify_waiters();
    }
    pub(crate) fn begin(&self) -> SourceMutation {
        if let Ok(mut state) = self.0.state.lock()
            && !state.status.terminal()
        {
            state.stamp = None;
            if let Some(epoch) = state.epoch.checked_add(1) {
                state.epoch = epoch;
                state.status = SourceStatus::Changing;
            } else {
                state.status = SourceStatus::Unavailable;
            }
        }
        self.notify();
        SourceMutation {
            witness: self.clone(),
            finished: false,
        }
    }
    fn finish(&self, session: &Session, path: &Path, status: SourceStatus) {
        if let Ok(mut state) = self.0.state.lock()
            && !state.status.terminal()
        {
            state.status = status;
            state.stamp = (status == SourceStatus::Certain).then(|| LoadedSourceStamp {
                incarnation: state.incarnation,
                admission_epoch: state.epoch,
                session_id: session.id.clone(),
                checkpoint_path: path.to_owned(),
                revision: session.revision,
                stream_generation: session.stream_generation.clone(),
                stream_sequence: session.stream_sequence,
            });
        }
        self.notify();
    }
    pub(crate) fn retire(&self) {
        if let Ok(mut state) = self.0.state.lock() {
            // Retirement dominates even uncertainty/exhaustion, permanently.
            state.status = SourceStatus::Retired;
            state.stamp = None;
        }
        self.notify();
    }
    pub(crate) fn unavailable(&self) {
        if let Ok(mut state) = self.0.state.lock()
            && !state.status.terminal()
        {
            state.status = SourceStatus::Unavailable;
            state.stamp = None;
        }
        self.notify();
    }
    pub(crate) fn capture(
        &self,
        session: &Session,
    ) -> Result<LoadedSourceSnapshot, SourceUnavailable> {
        if !self.owner_healthy() {
            return Err(SourceUnavailable);
        }
        let stamp = {
            let state = self.0.state.lock().map_err(|_| SourceUnavailable)?;
            if state.status != SourceStatus::Certain {
                return Err(SourceUnavailable);
            }
            let stamp = state.stamp.clone().ok_or(SourceUnavailable)?;
            if stamp.session_id != session.id
                || stamp.revision != session.revision
                || stamp.stream_generation != session.stream_generation
                || stamp.stream_sequence != session.stream_sequence
            {
                return Err(SourceUnavailable);
            }
            stamp
        };
        // Caller retains the actor mutex, but never the witness lock, while
        // cloning. Retirement can revoke concurrently, so recheck afterward.
        let session = Arc::new(session.clone());
        #[cfg(test)]
        CAPTURE_HOOK.with(|hook| {
            if let Some(hook) = hook.borrow_mut().as_mut() {
                hook();
            }
        });
        if !self.is_current(&stamp) {
            return Err(SourceUnavailable);
        }
        Ok(LoadedSourceSnapshot {
            session,
            stamp,
            witness: self.clone(),
        })
    }
}

/// A notification subscription owns no lock or transcript. Safe to retain while
/// calling retirement/mutation. Notifications can coalesce; receipts are authority.
pub struct SourceChanges {
    witness: SourceWitness,
    observed: Arc<()>,
}
impl SourceChanges {
    pub fn has_changed(&self) -> Result<bool, SourceUnavailable> {
        Ok(!Arc::ptr_eq(&self.observed, &self.witness.change_token()?))
    }
    pub async fn changed(&mut self) -> Result<(), SourceUnavailable> {
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

pub(crate) struct SourceMutation {
    witness: SourceWitness,
    finished: bool,
}
impl SourceMutation {
    pub(crate) fn finish(mut self, session: &Session, path: &Path, status: SourceStatus) {
        self.witness.finish(session, path, status);
        self.finished = true;
    }
}
impl Drop for SourceMutation {
    fn drop(&mut self) {
        if !self.finished {
            self.witness.unavailable();
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
#[error("Loaded search source is unavailable or changed")]
pub struct SourceUnavailable;

/// A paired raw accepted Session and receipt; revalidation is always required.
#[derive(Clone)]
pub struct LoadedSourceSnapshot {
    session: Arc<Session>,
    stamp: LoadedSourceStamp,
    witness: SourceWitness,
}
impl LoadedSourceSnapshot {
    pub fn session(&self) -> &Session {
        &self.session
    }
    pub fn stamp(&self) -> &LoadedSourceStamp {
        &self.stamp
    }
    pub fn is_current(&self) -> bool {
        self.witness.is_current(&self.stamp)
    }
}
impl fmt::Debug for LoadedSourceSnapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LoadedSourceSnapshot")
            .field("stamp", &self.stamp)
            .field("current", &self.is_current())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
thread_local! {
    static CAPTURE_HOOK: std::cell::RefCell<Option<Box<dyn FnMut()>>> = std::cell::RefCell::new(None);
}
#[cfg(test)]
mod tests {
    use super::*;
    fn source() -> (Session, SourceWitness) {
        let session = Session::new();
        let witness = SourceWitness::new(
            &session,
            Path::new("/private/fixture"),
            SourceStatus::Certain,
        );
        (session, witness)
    }
    #[test]
    fn epoch_exhaustion_is_search_only_and_permanent() {
        let (session, witness) = source();
        let old = witness.capture(&session).unwrap();
        witness.0.state.lock().unwrap().epoch = u64::MAX;
        witness.begin().finish(
            &session,
            Path::new("/private/fixture"),
            SourceStatus::Certain,
        );
        assert_eq!(witness.status(), SourceStatus::Unavailable);
        assert!(!old.is_current());
        witness.begin().finish(
            &session,
            Path::new("/private/fixture"),
            SourceStatus::Certain,
        );
        assert!(witness.capture(&session).is_err());
    }
    #[test]
    fn poisoned_witness_refuses_capture_and_does_not_panic() {
        let (session, witness) = source();
        let old = witness.capture(&session).unwrap();
        let worker = witness.clone();
        assert!(
            std::thread::spawn(move || {
                let _held = worker.0.state.lock().unwrap();
                panic!("fixture poison");
            })
            .join()
            .is_err()
        );
        assert_eq!(witness.status(), SourceStatus::Unavailable);
        assert!(!old.is_current());
        witness.begin().finish(
            &session,
            Path::new("/private/fixture"),
            SourceStatus::Certain,
        );
        witness.retire();
        assert!(witness.capture(&session).is_err());
    }
    #[test]
    fn unfinished_guard_and_terminal_states_never_revive() {
        for terminal in [
            SourceStatus::Uncertain,
            SourceStatus::Retired,
            SourceStatus::Unavailable,
        ] {
            let (session, witness) = source();
            let old = witness.capture(&session).unwrap();
            let guard = witness.begin();
            if terminal == SourceStatus::Retired {
                witness.retire();
            } else if terminal == SourceStatus::Unavailable {
                witness.unavailable();
            } else {
                witness.finish(&session, Path::new("/private/fixture"), terminal);
            }
            guard.finish(
                &session,
                Path::new("/private/fixture"),
                SourceStatus::Certain,
            );
            assert_eq!(witness.status(), terminal);
            assert!(!old.is_current());
        }
        let (session, witness) = source();
        drop(witness.begin());
        assert_eq!(witness.status(), SourceStatus::Unavailable);
        assert!(witness.capture(&session).is_err());
    }
    #[test]
    fn capture_rechecks_retirement_after_clone() {
        let (session, witness) = source();
        let retiring = witness.clone();
        CAPTURE_HOOK.with(|hook| *hook.borrow_mut() = Some(Box::new(move || retiring.retire())));
        let result = witness.capture(&session);
        CAPTURE_HOOK.with(|hook| *hook.borrow_mut() = None);
        assert!(result.is_err());
    }
    #[test]
    fn diagnostics_and_notifications_never_contain_source() {
        let (mut session, witness) = source();
        session.title = "DO-NOT-LOG-CONTENT".into();
        let changes = witness.subscribe_changes().unwrap();
        let source = witness.capture(&session).unwrap();
        let debug = format!("{source:?} {witness:?} {:?}", source.stamp());
        assert!(!debug.contains("DO-NOT-LOG"));
        assert!(!debug.contains("/private"));
        witness.begin().finish(
            &session,
            Path::new("/private/fixture"),
            SourceStatus::Certain,
        );
        assert!(changes.has_changed().unwrap());
        assert!(!source.is_current());
    }
}
