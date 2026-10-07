//! Keyed test-only scheduling seam between a completed turn's tail check and
//! the worker's next queue scan. No production delay, polling, or global pause.
use super::Controller;
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
};
use tokio::sync::oneshot;
type Pause = (oneshot::Sender<()>, oneshot::Receiver<()>);
fn pauses() -> &'static Mutex<HashMap<String, Pause>> {
    static PAUSES: OnceLock<Mutex<HashMap<String, Pause>>> = OnceLock::new();
    PAUSES.get_or_init(|| Mutex::new(HashMap::new()))
}
pub(crate) fn hold(controller: &Controller) -> (oneshot::Receiver<()>, oneshot::Sender<()>) {
    let (entered, waiting) = oneshot::channel();
    let (release, released) = oneshot::channel();
    assert!(
        pauses()
            .lock()
            .unwrap()
            .insert(controller.snapshot_shared().id.clone(), (entered, released))
            .is_none()
    );
    (waiting, release)
}
pub(super) async fn pause(controller: &Controller) {
    let pause = pauses()
        .lock()
        .unwrap()
        .remove(&controller.snapshot_shared().id);
    if let Some((entered, released)) = pause {
        let _ = entered.send(());
        let _ = released.await;
    }
}
pub(crate) fn set_intentional_pause(controller: &Controller) {
    let mut inner = controller.inner.lock().unwrap();
    inner
        .store
        .transact(|session| {
            session.queue_paused = true;
            Ok(())
        })
        .unwrap();
    controller.publish(&inner);
}
pub(crate) async fn wait_done(controller: &Controller) {
    let mut changed = controller.subscribe();
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            if !controller.test_has_active_worker() {
                return;
            }
            changed.changed().await.unwrap();
        }
    })
    .await
    .expect("worker did not settle");
}
