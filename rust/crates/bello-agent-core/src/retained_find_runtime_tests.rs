use super::*;
use crate::{Delta, Lane, SessionStore, Submission};

fn active() -> (tempfile::TempDir, Arc<Controller>, String) {
    let dir = tempfile::tempdir().unwrap();
    let mut store = SessionStore::open(dir.path().join("session.json")).unwrap();
    store
        .transact(|session| {
            session.submit(Submission::new("retained needle".into(), Lane::FollowUp))?;
            session.start_next()?;
            Ok(())
        })
        .unwrap();
    let reply = store.snapshot().active_reply.unwrap();
    (dir, Controller::new(store, None).unwrap(), reply)
}

#[test]
fn in_flight_find_installs_during_streaming_without_history_rescan_or_arc_equality() {
    let (_dir, controller, reply) = active();
    let prepared = controller.find_snapshot().unwrap();
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (continue_tx, continue_rx) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        continue_rx.recv().unwrap();
        let hits: Vec<_> = prepared
            .session()
            .messages
            .iter()
            .filter(|m| crate::retained_find::is_retained(prepared.session(), m))
            .filter(|m| m.text.contains("needle"))
            .map(|m| m.id.clone())
            .collect();
        (prepared, hits)
    });
    started_rx.recv().unwrap();
    crate::retained_find::COMPARISONS.with(|count| count.set(0));
    let mut prior = controller.snapshot_shared();
    for _ in 0..32 {
        let mut inner = controller.inner.lock().unwrap();
        inner
            .store
            .append_delta(&reply, Delta::Text("stream".into()))
            .unwrap();
        controller.publish(&inner);
        let current = controller.snapshot_shared();
        assert!(!Arc::ptr_eq(&prior, &current));
        prior = current;
    }
    continue_tx.send(()).unwrap();
    let (prepared, hits) = worker.join().unwrap();
    let current = controller.find_snapshot().unwrap();
    assert!(prepared.same_content(&current));
    assert_eq!(hits, vec![current.session().messages[0].id.clone()]);
    assert!(!Arc::ptr_eq(
        &prepared.session_shared(),
        &current.session_shared()
    ));
    assert_eq!(
        crate::retained_find::COMPARISONS.with(|count| count.get()),
        0
    );
    // Another token arrives after the worker result can already be installed.
    let mut inner = controller.inner.lock().unwrap();
    inner
        .store
        .append_delta(&reply, Delta::Reasoning("more".into()))
        .unwrap();
    controller.publish(&inner);
    assert!(prepared.same_content(&controller.find_snapshot().unwrap()));
}

#[test]
fn rejected_live_publication_changes_neither_bundle_and_generic_stop_keeps_pair() {
    let (_dir, controller, _) = active();
    let inner = controller.inner.lock().unwrap();
    let stale = controller.prepare_find_publication(&inner);
    let before = controller.find_snapshot().unwrap();
    let legacy = controller.snapshot_shared();
    controller.stop_epoch.fetch_add(1, Ordering::AcqRel);
    controller.publish_prepared(stale, 0, true);
    assert!(Arc::ptr_eq(&legacy, &controller.snapshot_shared()));
    assert!(Arc::ptr_eq(
        &before.session_shared(),
        &controller.find_snapshot().unwrap().session_shared()
    ));
    let generic = controller.prepare_find_publication(&inner);
    controller.publish_prepared(generic, 0, false);
    let after = controller.find_snapshot().unwrap();
    assert!(before.same_content(&after));
    assert!(Arc::ptr_eq(
        &after.session_shared(),
        &controller.snapshot_shared()
    ));
    controller.retired.store(true, Ordering::Release);
    controller.publish_prepared(controller.prepare_find_publication(&inner), 1, true);
    assert!(Arc::ptr_eq(
        &after.session_shared(),
        &controller.find_snapshot().unwrap().session_shared()
    ));
}

#[test]
fn snapshot_pair_is_consistent_under_concurrent_readers_and_publications() {
    let (_dir, controller, _) = active();
    let reader = controller.clone();
    let done = Arc::new(AtomicBool::new(false));
    let reader_done = done.clone();
    let worker = std::thread::spawn(move || {
        let mut prior = reader.find_snapshot().unwrap();
        while !reader_done.load(Ordering::Acquire) {
            let next = reader.find_snapshot().unwrap();
            if prior.same_content(&next) {
                assert!(crate::retained_find::same_projection(
                    prior.session(),
                    next.session()
                ));
            }
            prior = next;
        }
    });
    for value in 0..32 {
        let mut inner = controller.inner.lock().unwrap();
        inner
            .store
            .transact(|s| {
                s.messages[0].text = value.to_string();
                Ok(())
            })
            .unwrap();
        controller.publish(&inner);
        let pair = controller.find_snapshot().unwrap();
        assert_eq!(pair.session().messages[0].text, value.to_string());
        assert!(Arc::ptr_eq(
            &pair.session_shared(),
            &controller.snapshot_shared()
        ));
    }
    done.store(true, Ordering::Release);
    worker.join().unwrap();
}

#[test]
fn poisoned_find_lock_fails_closed_and_suppresses_legacy_publication() {
    let (_dir, controller, _) = active();
    let legacy = controller.snapshot_shared();
    let poison = controller.clone();
    assert!(
        std::thread::spawn(move || {
            let _guard = poison.find_published.write().unwrap();
            panic!("intentional publication poison");
        })
        .join()
        .is_err()
    );
    assert!(controller.find_snapshot().is_none());
    let mut inner = controller.inner.lock().unwrap();
    inner
        .store
        .transact(|s| {
            s.messages[0].text = "accepted but no publication".into();
            Ok(())
        })
        .unwrap();
    controller.publish(&inner);
    assert!(controller.find_snapshot().is_none());
    assert!(Arc::ptr_eq(&legacy, &controller.snapshot_shared()));
}

#[test]
fn replacement_controller_with_identical_bytes_has_distinct_identity() {
    let (_dir, first, _) = active();
    let before = first.find_snapshot().unwrap();
    let pending = SessionStore::pending_with_id(&before.session().id).unwrap();
    let second = Controller::new(pending, None).unwrap();
    assert!(!before.same_content(&second.find_snapshot().unwrap()));
    let empty = Controller::new(SessionStore::pending(), None).unwrap();
    let equal = SessionStore::pending_with_id(&empty.snapshot().id).unwrap();
    let replacement = Controller::new(equal, None).unwrap();
    assert!(crate::retained_find::same_projection(
        &empty.snapshot(),
        &replacement.snapshot()
    ));
    assert!(
        !empty
            .find_snapshot()
            .unwrap()
            .same_content(&replacement.find_snapshot().unwrap())
    );
}
