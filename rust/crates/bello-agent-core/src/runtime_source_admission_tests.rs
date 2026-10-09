use super::*;
use crate::{Delta, session::WriteFault, source_admission::SourceStatus};
use std::time::Duration;
fn controller() -> (tempfile::TempDir, Arc<Controller>) {
    let directory = tempfile::tempdir().unwrap();
    let controller = Controller::new(
        SessionStore::open(directory.path().join("session.json")).unwrap(),
        None,
    )
    .unwrap();
    (directory, controller)
}
fn start(controller: &Controller) -> String {
    let mut inner = controller.inner.lock().unwrap();
    inner
        .store
        .transact(|session| {
            session.submit(Submission::new("fixture".into(), Lane::FollowUp))?;
            session.start_next()?;
            Ok(())
        })
        .unwrap();
    controller.publish(&inner);
    inner.store.snapshot_ref().active_reply.clone().unwrap()
}
#[test]
fn direct_capture_does_not_require_display_publication_and_ignores_fatal_overlay() {
    let (_directory, controller) = controller();
    start(&controller);
    let display_before = controller.snapshot_shared();
    {
        let mut inner = controller.inner.lock().unwrap();
        inner
            .store
            .transact(|s| {
                s.title = "accepted without display update".into();
                Ok(())
            })
            .unwrap();
    }
    let captured = controller.loaded_search_source().unwrap();
    assert_eq!(captured.session().title, "accepted without display update");
    assert_eq!(controller.snapshot_shared().title, display_before.title);
    {
        let mut inner = controller.inner.lock().unwrap();
        inner.fatal = Some("display-only failure".into());
        controller.publish(&inner);
    }
    assert_eq!(controller.snapshot_shared().state, RunState::Error);
    assert_eq!(
        controller.loaded_search_source().unwrap().session().state,
        RunState::Running
    );
    assert!(captured.is_current());
}
#[test]
fn change_and_launch_failures_revoke_even_without_controller_publish() {
    for launch in [false, true] {
        let (_directory, controller) = controller();
        let before = controller.loaded_search_source().unwrap();
        let display = controller.snapshot_shared();
        controller.inner.lock().unwrap().store.fault = WriteFault::AfterRename;
        let result = if launch {
            controller.change_and_launch(|s| {
                s.title = "uncertain".into();
                Ok(None)
            })
        } else {
            controller.change(|s| {
                s.title = "uncertain".into();
                Ok(())
            })
        };
        assert!(matches!(result, Err(crate::Error::PersistenceUncertain(_))));
        assert!(Arc::ptr_eq(&display, &controller.snapshot_shared()));
        assert!(!before.is_current());
        assert_eq!(
            controller.search_source_witness().status(),
            SourceStatus::Uncertain
        );
        assert!(controller.loaded_search_source().is_err());
    }
}
#[test]
fn stream_failure_revokes_even_when_find_and_display_remain_old() {
    let (_directory, controller) = controller();
    let reply = start(&controller);
    let before = controller.loaded_search_source().unwrap();
    let find = controller.find_snapshot().unwrap();
    let display = controller.snapshot_shared();
    controller.inner.lock().unwrap().store.fault = WriteFault::StreamSync;
    assert!(
        controller
            .stream_delta(&reply, Delta::Text("unacknowledged".into()))
            .is_err()
    );
    assert!(Arc::ptr_eq(&display, &controller.snapshot_shared()));
    assert!(find.same_content(&controller.find_snapshot().unwrap()));
    assert!(!before.is_current());
    assert!(controller.loaded_search_source().is_err());
}
#[test]
fn active_text_and_hidden_revision_changes_do_not_depend_on_find_token() {
    let (_directory, controller) = controller();
    let reply = start(&controller);
    let find = controller.find_snapshot().unwrap();
    let before = controller.loaded_search_source().unwrap();
    controller
        .stream_delta(&reply, Delta::Text("accepted".into()))
        .unwrap();
    let text = controller.loaded_search_source().unwrap();
    assert!(find.same_content(&controller.find_snapshot().unwrap()));
    assert!(!before.is_current());
    assert_eq!(text.session().messages.last().unwrap().text, "accepted");
    controller
        .stream_delta(&reply, Delta::Reasoning("hidden".into()))
        .unwrap();
    let hidden = controller.loaded_search_source().unwrap();
    assert!(!text.is_current());
    assert!(find.same_content(&controller.find_snapshot().unwrap()));
    assert_eq!(hidden.session().messages.last().unwrap().text, "accepted");
}
#[test]
fn controller_final_check_rejects_mutation_after_actor_capture() {
    let (_directory, controller) = controller();
    let updating = Arc::downgrade(&controller);
    SOURCE_CAPTURE_HOOK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move || {
            updating
                .upgrade()
                .unwrap()
                .change(|s| {
                    s.title = "new boundary".into();
                    Ok(())
                })
                .unwrap();
        }))
    });
    let result = controller.loaded_search_source();
    SOURCE_CAPTURE_HOOK.with(|hook| *hook.borrow_mut() = None);
    assert!(result.is_err());
    assert_eq!(
        controller.loaded_search_source().unwrap().session().title,
        "new boundary"
    );
}
#[test]
fn controller_final_check_rejects_retirement_after_actor_capture() {
    let (_directory, controller) = controller();
    let retiring = Arc::downgrade(&controller);
    SOURCE_CAPTURE_HOOK.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move || {
            retiring.upgrade().unwrap().retire().unwrap();
        }))
    });
    let result = controller.loaded_search_source();
    SOURCE_CAPTURE_HOOK.with(|hook| *hook.borrow_mut() = None);
    assert!(result.is_err());
}
#[test]
fn retirement_revokes_before_waiting_for_actor_and_late_success_cannot_revive() {
    let (_directory, controller) = controller();
    let before = controller.loaded_search_source().unwrap();
    let witness = controller.search_source_witness();
    let mut actor = controller.inner.lock().unwrap();
    let retiring = controller.clone();
    let (done, finished) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || {
        done.send(retiring.retire()).unwrap();
    });
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while witness.status() != SourceStatus::Retired {
        assert!(std::time::Instant::now() < deadline);
        std::thread::yield_now();
    }
    assert!(!before.is_current());
    assert!(finished.try_recv().is_err());
    // An already admitted mutation may settle while retirement waits for actor.
    actor
        .store
        .transact(|s| {
            s.title = "settled after fence".into();
            Ok(())
        })
        .unwrap();
    assert_eq!(witness.status(), SourceStatus::Retired);
    drop(actor);
    finished
        .recv_timeout(Duration::from_secs(5))
        .unwrap()
        .unwrap();
    thread.join().unwrap();
    assert!(controller.loaded_search_source().is_err());
}
#[test]
fn stop_keeps_accepted_text_and_store_retirement_revokes() {
    let (_directory, controller) = controller();
    let reply = start(&controller);
    controller
        .stream_delta(&reply, Delta::Text("keep".into()))
        .unwrap();
    controller.stop().unwrap();
    let source = controller.loaded_search_source().unwrap();
    assert_eq!(source.session().messages.last().unwrap().text, "keep");
    controller.inner.lock().unwrap().store.retire_writer();
    assert!(!source.is_current());
    assert!(controller.loaded_search_source().is_err());
}
#[tokio::test]
async fn failed_join_keeps_writer_but_revokes_search_and_cancelled_waiter_stays_fenced() {
    let (directory, controller) = controller();
    let path = directory.path().join("session.json");
    let source = controller.loaded_search_source().unwrap();
    let (release, gate) = tokio::sync::oneshot::channel();
    *controller.worker.lock().unwrap() = Some(tokio::spawn(async move {
        gate.await.unwrap();
        panic!("fixture worker failure");
    }));
    let mut retirement = Box::pin(controller.retire_and_wait());
    assert!(futures_util::poll!(&mut retirement).is_pending());
    assert!(!source.is_current());
    drop(retirement);
    assert!(SessionStore::open(&path).is_err());
    assert!(controller.loaded_search_source().is_err());
    release.send(()).unwrap();
    assert!(
        tokio::time::timeout(Duration::from_secs(5), controller.retire_and_wait())
            .await
            .unwrap()
            .is_err()
    );
    assert!(SessionStore::open(&path).is_err());
    assert_eq!(
        controller.search_source_witness().status(),
        SourceStatus::Retired
    );
}
#[test]
fn poisoned_actor_refuses_capture_and_drop_revokes_existing_receipt() {
    let (_directory, controller) = controller();
    let source = controller.loaded_search_source().unwrap();
    let worker = controller.clone();
    assert!(
        std::thread::spawn(move || {
            let _actor = worker.inner.lock().unwrap();
            panic!("fixture actor poison");
        })
        .join()
        .is_err()
    );
    // Check retained evidence first: no Controller accessor may lazily repair it.
    assert!(!source.is_current());
    assert!(controller.loaded_search_source().is_err());
    drop(controller);
    assert!(!source.is_current());
}

#[tokio::test]
async fn retained_notification_subscription_never_blocks_retirement_and_sees_early_change() {
    let (_directory, controller) = controller();
    let source = controller.loaded_search_source().unwrap();
    let witness = controller.search_source_witness();
    let mut changes = witness.subscribe_changes().unwrap();
    // Retain the subscription through synchronous retirement, then start waiting.
    // There is no user-held notification borrow guard or callback to deadlock.
    controller.retire().unwrap();
    assert!(!source.is_current());
    assert!(changes.has_changed().unwrap());
    tokio::time::timeout(Duration::from_secs(5), changes.changed())
        .await
        .unwrap()
        .unwrap();
    assert!(!changes.has_changed().unwrap());
}

#[tokio::test]
async fn pending_multi_subscriber_and_cancelled_notification_waits_do_not_lose_changes() {
    let (_directory, controller) = controller();
    let witness = controller.search_source_witness();
    let mut first = witness.subscribe_changes().unwrap();
    let mut second = witness.subscribe_changes().unwrap();
    let mut cancelled = witness.subscribe_changes().unwrap();
    let mut abandoned = Box::pin(cancelled.changed());
    assert!(futures_util::poll!(&mut abandoned).is_pending());
    drop(abandoned);
    let mut one = Box::pin(first.changed());
    let mut two = Box::pin(second.changed());
    assert!(futures_util::poll!(&mut one).is_pending());
    assert!(futures_util::poll!(&mut two).is_pending());
    controller
        .change(|s| {
            s.title = "first".into();
            Ok(())
        })
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), one)
        .await
        .unwrap()
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), two)
        .await
        .unwrap()
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), cancelled.changed())
        .await
        .unwrap()
        .unwrap();
    assert!(!first.has_changed().unwrap());
    assert!(!second.has_changed().unwrap());
    assert!(!cancelled.has_changed().unwrap());
    // Repeated changes coalesce without creating queued snapshots or losing the
    // final notification after a cancelled wait has registered and disappeared.
    controller
        .change(|s| {
            s.title = "second".into();
            Ok(())
        })
        .unwrap();
    controller.retire().unwrap();
    for subscription in [&mut first, &mut second, &mut cancelled] {
        tokio::time::timeout(Duration::from_secs(5), subscription.changed())
            .await
            .unwrap()
            .unwrap();
        assert!(!subscription.has_changed().unwrap());
    }
    assert_eq!(witness.status(), SourceStatus::Retired);
}

#[test]
fn bound_pending_materialization_keeps_probe_and_controller_drop_revokes_with_actor_retained() {
    let directory = tempfile::tempdir().unwrap();
    let controller = Controller::new(SessionStore::pending(), None).unwrap();
    let witness = controller.search_source_witness();
    controller
        .materialize(&directory.path().join("session.json"))
        .unwrap();
    let source = controller.loaded_search_source().unwrap();
    assert!(witness.is_current(source.stamp()));
    // Inner has no public strong-owner export; this fixture models a temporary
    // internal upgrade of the weak health probe at Controller destruction.
    let retained_actor = controller.inner.clone();
    drop(controller);
    assert!(!source.is_current());
    assert_eq!(witness.status(), SourceStatus::Retired);
    assert!(
        retained_actor
            .lock()
            .unwrap()
            .store
            .capture_search_source()
            .is_err()
    );
}
