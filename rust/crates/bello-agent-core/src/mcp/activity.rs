//! Non-invasive presentation of queued/owned MCP admission. The Tokio lock
//! remains the authoritative exclusion mechanism; counters grant no authority.
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tokio::sync::{OwnedRwLockReadGuard, OwnedRwLockWriteGuard, RwLock, TryLockError};

#[derive(Default)]
pub(super) struct Gate {
    lock: Arc<RwLock<()>>,
    activity: Arc<AtomicUsize>,
}
struct Activity(Arc<AtomicUsize>);
impl Activity {
    fn new(count: &Arc<AtomicUsize>) -> Self {
        let mut current = count.load(Ordering::Acquire);
        loop {
            let next = current
                .checked_add(1)
                .expect("MCP activity count exhausted");
            match count.compare_exchange_weak(current, next, Ordering::AcqRel, Ordering::Acquire) {
                Ok(_) => break,
                Err(observed) => current = observed,
            }
        }
        Self(count.clone())
    }
}
impl Drop for Activity {
    fn drop(&mut self) {
        let previous = self.0.fetch_sub(1, Ordering::Release);
        debug_assert!(previous > 0, "MCP activity ownership dropped twice");
    }
}
// Rust drops fields in declaration order: release the actual lock before
// publishing the corresponding activity release. A cancelled waiter likewise
// drops its Activity even when it never acquires a lock.
pub(super) struct ReadGuard {
    _lock: OwnedRwLockReadGuard<()>,
    _activity: Activity,
}
pub(super) struct WriteGuard {
    _lock: OwnedRwLockWriteGuard<()>,
    _activity: Activity,
}
impl Gate {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn busy(&self) -> bool {
        self.activity.load(Ordering::Acquire) != 0
    }
    pub async fn read_owned(self: Arc<Self>) -> ReadGuard {
        let activity = Activity::new(&self.activity);
        let lock = self.lock.clone().read_owned().await;
        ReadGuard {
            _lock: lock,
            _activity: activity,
        }
    }
    #[cfg(test)]
    pub async fn write_owned(self: Arc<Self>) -> WriteGuard {
        let activity = Activity::new(&self.activity);
        let lock = self.lock.clone().write_owned().await;
        WriteGuard {
            _lock: lock,
            _activity: activity,
        }
    }
    pub fn try_write_owned(self: Arc<Self>) -> Result<WriteGuard, TryLockError> {
        let activity = Activity::new(&self.activity);
        let lock = self.lock.clone().try_write_owned()?;
        Ok(WriteGuard {
            _lock: lock,
            _activity: activity,
        })
    }
    #[cfg(test)]
    pub async fn read(&self) -> ReadGuard {
        let activity = Activity::new(&self.activity);
        let lock = self.lock.clone().read_owned().await;
        ReadGuard {
            _lock: lock,
            _activity: activity,
        }
    }
    #[cfg(test)]
    pub async fn write(&self) -> WriteGuard {
        let activity = Activity::new(&self.activity);
        let lock = self.lock.clone().write_owned().await;
        WriteGuard {
            _lock: lock,
            _activity: activity,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn real_readers_writers_queued_cancellation_and_failed_attempts_keep_activity_exact() {
        let gate = Arc::new(Gate::new());
        assert!(!gate.busy());
        let reader = gate.read().await;
        assert!(gate.busy());
        assert!(gate.clone().try_write_owned().is_err());
        let mut writer = Box::pin(gate.clone().write_owned());
        assert!(futures_util::poll!(&mut writer).is_pending());
        let mut late_reader = Box::pin(gate.clone().read_owned());
        assert!(futures_util::poll!(&mut late_reader).is_pending());
        drop(late_reader);
        drop(writer);
        assert!(gate.busy());
        assert_eq!(gate.activity.load(Ordering::Acquire), 1);
        drop(reader);
        assert!(!gate.busy());
        let writer = gate.write().await;
        let mut waiting = Box::pin(gate.clone().read_owned());
        assert!(futures_util::poll!(&mut waiting).is_pending());
        drop(waiting);
        assert!(gate.busy());
        drop(writer);
        assert!(!gate.busy());
    }
    #[tokio::test]
    async fn unwind_and_rebound_handle_release_the_same_owned_activity() {
        let gate = Arc::new(Gate::new());
        let rebound = gate.clone();
        let worker = tokio::spawn(async move {
            let _guard = rebound.write_owned().await;
            panic!("generated worker unwind");
        });
        assert!(worker.await.unwrap_err().is_panic());
        assert!(!gate.busy());
        let guard = gate.clone().try_write_owned().unwrap();
        assert!(gate.busy());
        drop(guard);
        assert!(!gate.busy());
    }
}
