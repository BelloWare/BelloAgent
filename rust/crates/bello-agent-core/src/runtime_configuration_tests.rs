//! Actor-boundary contracts in addition to public vault/loopback integration.
use super::*;
use crate::project_authority::{
    ProjectAuthority,
    connections::{ConnectionDraft, SYNTHETIC_KEY, SyntheticConnectionRuntime},
    synthetic::SyntheticAuthorityControl,
};
use std::time::Duration;

fn fixture() -> (
    tempfile::TempDir,
    SyntheticAuthorityControl,
    SyntheticConnectionRuntime,
    Arc<Controller>,
) {
    let dir = tempfile::tempdir().unwrap();
    let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
    let loaded = authority.load_connections().unwrap();
    let profile=serde_json::from_value(serde_json::json!({"id":"00000000-0000-4000-8000-000000000001","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":"http://127.0.0.1:3333","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let mut form = ConnectionDraft::new(profile, "Fixture".into());
    form.key_input = SYNTHETIC_KEY.into();
    let saved = authority.save_connection(&loaded, &form).unwrap();
    let runtime =
        SyntheticConnectionRuntime::confirm(&control, &saved.loaded, &saved.profile.profile.id)
            .unwrap();
    let controller = runtime
        .open(
            SessionStore::open(dir.path().join("session.json")).unwrap(),
            RuntimeOptions::default(),
        )
        .unwrap();
    (dir, control, runtime, controller)
}
#[test]
fn revoked_generation_is_checked_under_actor_after_prior_fresh_confirmation() {
    let (_dir, _control, runtime, controller) = fixture();
    controller.confirm_resources().unwrap();
    let _actor = controller.inner.lock().unwrap();
    runtime.revoke();
    assert!(controller.require_admission().is_err());
}
#[tokio::test]
async fn revoked_reserved_worker_does_not_dequeue_or_request() {
    let (_dir, _control, runtime, controller) = fixture();
    {
        let mut actor = controller.inner.lock().unwrap();
        actor
            .store
            .transact(|s| s.submit(Submission::new("keep queued".into(), Lane::FollowUp)))
            .unwrap();
        runtime.revoke();
        controller.launch(&mut actor, None);
    }
    tokio::time::timeout(Duration::from_secs(5), controller.shutdown())
        .await
        .unwrap()
        .unwrap();
    let actor = controller.inner.lock().unwrap();
    assert_eq!(actor.store.snapshot_ref().pending.len(), 1);
    assert!(actor.store.snapshot_ref().messages.is_empty());
    assert!(!actor.worker_running);
}
#[test]
fn fresh_configuration_confirmation_never_holds_actor_lock() {
    let (_dir, control, runtime, controller) = fixture();
    let gate = control.pause_next_read().unwrap();
    let other = controller.clone();
    let configuration = runtime.configuration();
    let worker = std::thread::spawn(move || other.configure(configuration));
    assert!(gate.wait_until_started(Duration::from_secs(1)));
    assert!(controller.inner.try_lock().is_ok());
    runtime.revoke();
    gate.release();
    assert!(worker.join().unwrap().is_err());
}
#[test]
fn settlement_applies_only_latest_pending_configuration_and_notifies_observers() {
    let (_dir, control, _runtime, controller) = fixture();
    let authority = control.authority();
    let mut loaded = authority.load_connections().unwrap();
    controller.inner.lock().unwrap().worker_running = true;
    for effort in ["medium", "high"] {
        let mut form = loaded.edit("00000000-0000-4000-8000-000000000001").unwrap();
        form.profile.thinking_level = effort.into();
        loaded = authority.save_connection(&loaded, &form).unwrap().loaded;
        let runtime = SyntheticConnectionRuntime::confirm(
            &control,
            &loaded,
            "00000000-0000-4000-8000-000000000001",
        )
        .unwrap();
        assert!(!controller.configure(runtime.configuration()).unwrap());
    }
    let revision = controller.revision();
    {
        let mut actor = controller.inner.lock().unwrap();
        controller.worker_finished(&mut actor);
    }
    assert_eq!(controller.profile().unwrap().thinking_level, "high");
    assert!(!controller.settings_pending());
    assert!(controller.revision() > revision);
}

#[tokio::test]
async fn deleted_connection_is_rechecked_before_dequeue_and_keeps_accepted_text() {
    let (_dir, control, _runtime, controller) = fixture();
    let authority = control.authority();
    let loaded = authority.load_connections().unwrap();
    {
        let mut actor = controller.inner.lock().unwrap();
        actor
            .store
            .transact(|s| {
                s.submit(Submission::new(
                    "preserve accepted input".into(),
                    Lane::FollowUp,
                ))
            })
            .unwrap();
    }
    authority
        .delete_connection(&loaded, "00000000-0000-4000-8000-000000000001")
        .unwrap();
    {
        let mut actor = controller.inner.lock().unwrap();
        controller.launch(&mut actor, None);
    }
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if !controller.inner.lock().unwrap().worker_running {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    let snapshot = controller.snapshot();
    assert_eq!(snapshot.pending.len(), 1);
    assert!(snapshot.messages.is_empty());
    assert_eq!(snapshot.state, RunState::Error);
    controller.retire_and_wait().await.unwrap();
}

#[test]
fn active_confirmation_cannot_cross_worker_settlement_or_a_new_worker_epoch() {
    let (_dir, _control, _runtime, controller) = fixture();
    controller.inner.lock().unwrap().worker_running = true;
    let confirmed = controller.confirm_resources().unwrap();
    {
        let mut actor = controller.inner.lock().unwrap();
        controller.worker_finished(&mut actor);
        assert!(
            controller
                .require_confirmed_admission(&actor, &confirmed)
                .is_err()
        );
        actor.worker_running = true;
        actor.worker_epoch = Arc::new(());
        assert!(
            controller
                .require_confirmed_admission(&actor, &confirmed)
                .is_err()
        );
        controller.worker_finished(&mut actor);
    }
}
#[test]
fn synthetic_resource_runtime_cannot_be_reconfigured_from_ordinary_cli_credentials() {
    struct Allow;
    impl SyntheticRuntimeGuard for Allow {
        fn check(&self) -> Result<()> {
            Ok(())
        }
    }
    let mut profile: Profile=serde_json::from_value(serde_json::json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":"http://127.0.0.1:3333","contextWindow":32000,"maxOutputTokens":4096})).unwrap();
    let controller = Controller::new_with_synthetic_resources(
        SessionStore::pending(),
        Some((
            profile.clone(),
            Credential::new("synthetic-project-fixture-only".into()).unwrap(),
        )),
        RuntimeOptions::default(),
        SyntheticResources::new(None, Arc::new(Allow)),
    )
    .unwrap();
    profile
        .headers
        .insert("X-Fixture".into(), "ordinary-cli-header".into());
    let ordinary = Controller::new(
        SessionStore::pending(),
        Some((profile, Credential::new("ordinary-cli-key".into()).unwrap())),
    )
    .unwrap();
    assert!(
        controller
            .configure(ordinary.configuration().unwrap())
            .is_err()
    );
}

#[test]
fn delayed_older_configuration_cannot_replace_newer_applied_or_pending_save() {
    for active in [false, true] {
        let (_dir, control, old, controller) = fixture();
        controller.inner.lock().unwrap().worker_running = active;
        let gate = control.pause_next_read().unwrap();
        let other = controller.clone();
        let older = old.configuration();
        let worker = std::thread::spawn(move || other.configure(older));
        assert!(gate.wait_until_started(Duration::from_secs(1)));
        let authority = control.authority();
        let loaded = authority.load_connections().unwrap();
        let mut form = loaded.edit("00000000-0000-4000-8000-000000000001").unwrap();
        form.profile.thinking_level = "high".into();
        let saved = authority.save_connection(&loaded, &form).unwrap();
        let latest = SyntheticConnectionRuntime::confirm(
            &control,
            &saved.loaded,
            "00000000-0000-4000-8000-000000000001",
        )
        .unwrap();
        assert_eq!(
            controller.configure(latest.configuration()).unwrap(),
            !active
        );
        gate.release();
        assert!(worker.join().unwrap().is_err());
        if active {
            let mut actor = controller.inner.lock().unwrap();
            controller.worker_finished(&mut actor);
        }
        assert_eq!(controller.profile().unwrap().thinking_level, "high");
    }
}

#[test]
fn capability_badge_is_nonblocking_and_rejects_empty_fatal_uncertain_and_legacy_state() {
    struct Current;
    impl RuntimeAuthorityGuard for Current {
        fn check(&self) -> Result<()> {
            Ok(())
        }
        fn confirm(&self) -> Result<()> {
            panic!("A presentation query must not confirm authority")
        }
    }
    fn promptly_false<G>(controller: &Arc<Controller>, guard: G) {
        let copy = controller.clone();
        let (sent, received) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            let _ = sent.send(copy.has_available_tool_definitions());
        });
        let result = received.recv_timeout(Duration::from_secs(1));
        drop(guard);
        worker.join().unwrap();
        assert!(!result.unwrap());
    }
    let (dir, _control, _runtime, mut actor) = fixture();
    let options = RuntimeOptions {
        instructions: String::new(),
        tools: Some(
            TrustedReadOnlyTools::new(dir.path().to_owned(), vec![], dir.path().to_owned())
                .unwrap(),
        ),
    };
    assert!(!actor.has_available_tool_definitions());
    {
        let actor = Arc::get_mut(&mut actor).unwrap();
        actor.authority = Some(Arc::new(Current));
        actor.options = options.clone();
    }
    assert!(actor.has_available_tool_definitions());
    promptly_false(&actor, actor.inner.lock().unwrap());
    promptly_false(&actor, actor.config.write().unwrap());
    actor.inner.lock().unwrap().fatal = Some("unavailable".into());
    assert!(!actor.has_available_tool_definitions());
    actor.inner.lock().unwrap().fatal = None;
    Arc::get_mut(&mut actor).unwrap().options.tools = None;
    assert!(!actor.has_available_tool_definitions());
    Arc::get_mut(&mut actor).unwrap().options = options.clone();
    let legacy = Controller::new_with_options(
        SessionStore::pending(),
        Some((
            actor.profile().unwrap(),
            Credential::new("ordinary-test-key".into()).unwrap(),
        )),
        options,
    )
    .unwrap();
    assert!(!legacy.has_available_tool_definitions());
    {
        let mut inner = actor.inner.lock().unwrap();
        inner.store.fault = crate::session::WriteFault::AfterRename;
        assert!(
            inner
                .store
                .transact(|session| {
                    session.queue_paused = true;
                    Ok(())
                })
                .is_err()
        );
    }
    assert!(!actor.has_available_tool_definitions());
    actor.retire().unwrap();
    assert!(!actor.has_available_tool_definitions());
}
