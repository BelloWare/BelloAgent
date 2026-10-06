//! A temporary idle-only fence for save-before-retire project changes.
//! No actor mutex is retained across a configuration write or asynchronous join.
use super::*;

/// Single-owner admission suspension. Dropping before a confirmed/uncertain
/// configuration write reopens admission only for this exact generation.
/// After a write may have committed, retain_fence keeps old Arcs fail-closed
/// until permanent retirement; it never releases writer ownership itself.
pub struct IdleAdmissionGuard {
    controller: Arc<Controller>,
    generation: u64,
    resume_on_drop: bool,
    persistent: bool,
}
impl IdleAdmissionGuard {
    /// Writer kind captured atomically with admission suspension.
    pub fn is_persistent(&self) -> bool {
        self.persistent
    }
    pub fn retain_fence(mut self) {
        self.resume_on_drop = false;
    }
}
impl Drop for IdleAdmissionGuard {
    fn drop(&mut self) {
        if self.resume_on_drop && !self.controller.is_retired() {
            let _ = self.controller.admission_suspension.compare_exchange(
                self.generation,
                0,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
        }
        if self
            .controller
            .suspension_owner
            .compare_exchange(self.generation, 0, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            self.controller.suspension_released.notify_waiters();
        }
    }
}
impl Controller {
    pub(super) async fn wait_for_idle_guard_release(&self) {
        loop {
            let released = self.suspension_released.notified();
            tokio::pin!(released);
            released.as_mut().enable();
            if self.suspension_owner.load(Ordering::Acquire) == 0 {
                return;
            }
            released.await;
        }
    }
    pub fn suspend_idle_admission(self: &Arc<Self>) -> Result<IdleAdmissionGuard> {
        let inner = self
            .inner
            .lock()
            .map_err(|_| invalid("Session is unavailable"))?;
        self.require_admission()?;
        if self.suspension_owner.load(Ordering::Acquire) != 0 {
            return Err(invalid(
                "A previous project admission guard is still releasing.",
            ));
        }
        inner.store.require_certain()?;
        inner.store.require_idle_for_host_change()?;
        if inner.fatal.is_some()
            || inner.worker_running
            || self.worker_active.load(Ordering::Acquire)
        {
            return Err(invalid(
                "Stop this project's work and finish queued edits before changing its folders.",
            ));
        }
        let generation = self
            .suspension_generation
            .load(Ordering::Relaxed)
            .checked_add(1)
            .ok_or_else(|| invalid("Project admission generation is exhausted"))?;
        self.suspension_generation
            .store(generation, Ordering::Relaxed);
        self.suspension_owner.store(generation, Ordering::Release);
        self.admission_suspension
            .store(generation, Ordering::Release);
        Ok(IdleAdmissionGuard {
            controller: self.clone(),
            generation,
            resume_on_drop: true,
            persistent: inner.store.is_persistent(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture_controller() -> (tempfile::TempDir, Arc<Controller>) {
        let directory = tempfile::tempdir().unwrap();
        let controller = Controller::new(
            SessionStore::open(directory.path().join("session.json")).unwrap(),
            None,
        )
        .unwrap();
        (directory, controller)
    }

    #[test]
    fn idle_suspension_rejects_direct_old_arc_mutations_and_nested_owner() {
        let (_directory, controller) = fixture_controller();
        let stale = controller.clone();
        let before = controller.snapshot();
        let guard = controller.suspend_idle_admission().unwrap();
        assert!(controller.suspend_idle_admission().is_err());
        assert!(stale.submit("do not admit".into(), Lane::FollowUp).is_err());
        assert!(stale.resume().is_err());
        assert!(stale.retry().is_err());
        assert!(stale.begin_edit("turn", "edit").is_err());
        assert!(stale.cancel_edit_certain("edit", "turn").is_err());
        assert!(stale.remove("turn").is_err());
        assert!(stale.reorder(&[]).is_err());
        assert!(stale.promote_to_steering("turn").is_err());
        assert!(stale.edit_status("edit").is_err());
        assert_eq!(stale.snapshot().revision, before.revision);
        stale.stop().unwrap();
        drop(guard);
        stale.reorder(&[]).unwrap();
        assert!(!stale.is_retired());
    }

    #[test]
    fn idle_suspension_allows_empty_paused_and_ordinary_failed_sessions() {
        for state in [RunState::Paused, RunState::Error] {
            let (_directory, controller) = fixture_controller();
            controller
                .inner
                .lock()
                .unwrap()
                .store
                .transact(|s| {
                    s.state = state;
                    s.queue_paused = true;
                    s.error = Some("ordinary provider failure".into());
                    Ok(())
                })
                .unwrap();
            drop(controller.suspend_idle_admission().unwrap());
        }
    }

    #[test]
    fn idle_suspension_cannot_overtake_admitted_queued_work() {
        let (_directory, controller) = fixture_controller();
        let mut inner = controller.inner.lock().unwrap();
        let contender = controller.clone();
        let (entered, ready) = std::sync::mpsc::channel();
        let join = std::thread::spawn(move || {
            entered.send(()).unwrap();
            contender.suspend_idle_admission().is_err()
        });
        ready.recv().unwrap();
        inner
            .store
            .transact(|s| s.submit(Submission::new("queued".into(), Lane::FollowUp)))
            .unwrap();
        drop(inner);
        assert!(join.join().unwrap());
        assert_eq!(controller.snapshot().pending.len(), 0); // cached publication is not admission evidence
        assert_eq!(
            controller
                .inner
                .lock()
                .unwrap()
                .store
                .snapshot()
                .pending
                .len(),
            1
        );
    }

    #[test]
    fn idle_suspension_stale_drop_cannot_resume_a_newer_generation() {
        let (_directory, controller) = fixture_controller();
        let old = controller.suspend_idle_admission().unwrap();
        let generation = old.generation;
        drop(old);
        let current = controller.suspend_idle_admission().unwrap();
        drop(IdleAdmissionGuard {
            controller: controller.clone(),
            generation,
            resume_on_drop: true,
            persistent: current.is_persistent(),
        });
        assert!(controller.reorder(&[]).is_err());
        drop(current);
        controller.reorder(&[]).unwrap();
    }

    #[tokio::test]
    async fn idle_suspension_committed_fence_survives_guard_drop_and_retirement() {
        let (_directory, controller) = fixture_controller();
        controller.suspend_idle_admission().unwrap().retain_fence();
        assert!(controller.reorder(&[]).is_err());
        controller.retire_and_wait().await.unwrap();
        assert!(controller.reorder(&[]).is_err());
        let (_other_directory, other) = fixture_controller();
        let guard = other.suspend_idle_admission().unwrap();
        other.retire().unwrap();
        drop(guard);
        other.retire_and_wait().await.unwrap();
        assert!(other.reorder(&[]).is_err());
    }
    #[test]
    fn idle_suspension_keeps_uncertain_writer_fenced_and_pending_materialization_blocked() {
        let (_directory, controller) = fixture_controller();
        let mut inner = controller.inner.lock().unwrap();
        inner.store.fault = crate::session::WriteFault::AfterRename;
        assert!(
            inner
                .store
                .transact(|session| {
                    session.title = "possibly saved".into();
                    Ok(())
                })
                .is_err()
        );
        drop(inner);
        assert!(controller.suspend_idle_admission().is_err());
        assert!(controller.reorder(&[]).is_err());
        let pending = Controller::new(SessionStore::pending(), None).unwrap();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("pending.json");
        let guard = pending.suspend_idle_admission().unwrap();
        assert!(pending.materialize(&path).is_err());
        assert!(!path.exists());
        drop(guard);
        pending.materialize(&path).unwrap();
    }

    #[tokio::test]
    async fn idle_suspension_failed_join_never_reopens_admission_or_writer() {
        let (directory, controller) = fixture_controller();
        let guard = controller.suspend_idle_admission().unwrap();
        *controller.worker.lock().unwrap() = Some(tokio::spawn(async {
            panic!("injected joined worker failure")
        }));
        assert!(controller.retire_and_wait().await.is_err());
        drop(guard);
        assert!(controller.reorder(&[]).is_err());
        assert!(SessionStore::open(directory.path().join("session.json")).is_err());
    }
    #[tokio::test]
    async fn idle_suspension_retains_atomic_writer_kind_after_external_retirement() {
        let (_directory, controller) = fixture_controller();
        let guard = controller.suspend_idle_admission().unwrap();
        assert!(guard.is_persistent());
        let mut retiring = Box::pin(controller.retire_and_wait());
        assert!(futures_util::poll!(&mut retiring).is_pending());
        assert!(controller.is_persistent());
        assert!(guard.is_persistent());
        guard.retain_fence();
        retiring.await.unwrap();
        assert!(!controller.is_persistent());
    }

    #[tokio::test]
    async fn idle_suspension_abandoned_retirement_waiter_wakes_after_guard_drop() {
        let (directory, controller) = fixture_controller();
        let guard = controller.suspend_idle_admission().unwrap();
        let mut first = Box::pin(controller.retire_and_wait());
        assert!(futures_util::poll!(&mut first).is_pending());
        drop(first);
        assert!(SessionStore::open(directory.path().join("session.json")).is_err());
        let mut second = Box::pin(controller.retire_and_wait());
        assert!(futures_util::poll!(&mut second).is_pending());
        drop(guard);
        tokio::time::timeout(std::time::Duration::from_secs(2), second)
            .await
            .unwrap()
            .unwrap();
        assert!(SessionStore::open(directory.path().join("session.json")).is_ok());
        assert!(controller.reorder(&[]).is_err());
    }
}
