use super::*;
use crate::project_authority::synthetic::SyntheticAuthorityControl;
use crate::{Controller, Credential, Lane, SessionStore, runtime::RuntimeOptions};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};

fn profile() -> Profile {
    serde_json::from_value(json!({"id":"00000000-0000-4000-8000-000000000001","api":"openai-responses","providerId":"litellm","modelId":"fixture","baseUrl":"http://127.0.0.1:3333","contextWindow":32000,"maxOutputTokens":4096})).unwrap()
}
fn draft() -> ConnectionDraft {
    let mut draft = ConnectionDraft::new(profile(), "Fixture A".into());
    draft.key_input = SYNTHETIC_KEY.into();
    draft
}
fn fixture() -> (
    ProjectAuthority,
    SyntheticAuthorityControl,
    LoadedConnections,
) {
    let (authority, control) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
    let loaded = authority.load_connections().unwrap();
    (authority, control, loaded)
}
fn save() -> (
    ProjectAuthority,
    SyntheticAuthorityControl,
    LoadedConnections,
) {
    let (authority, control, loaded) = fixture();
    let saved = authority.save_connection(&loaded, &draft()).unwrap();
    (authority, control, saved.loaded)
}
#[test]
fn save_metadata_preserves_blank_secrets_and_empty_object_clears_headers() {
    let (authority, control, loaded) = fixture();
    let mut form = draft();
    form.headers_input = format!(r#"{{"X-Fixture":"{SYNTHETIC_HEADER}"}}"#);
    let saved = authority.save_connection(&loaded, &form).unwrap();
    assert!(!saved.forked);
    assert!(saved.profile.profile.headers.is_empty());
    let old_revision = saved.profile.revision;
    let mut edit = saved
        .loaded
        .edit("00000000-0000-4000-8000-000000000001")
        .unwrap();
    edit.name = "Renamed".into();
    let renamed = authority.save_connection(&saved.loaded, &edit).unwrap();
    assert_eq!(
        renamed.profile.profile.id,
        "00000000-0000-4000-8000-000000000001"
    );
    assert_ne!(old_revision, renamed.profile.revision);
    let bytes: Value = serde_json::from_slice(&control.snapshot_bytes().unwrap().unwrap()).unwrap();
    assert_eq!(
        bytes["profiles"][0]["headers"]["X-Fixture"],
        SYNTHETIC_HEADER
    );
    assert_eq!(bytes["profiles"][0]["apiKey"], SYNTHETIC_KEY);
    let mut clear = renamed
        .loaded
        .edit("00000000-0000-4000-8000-000000000001")
        .unwrap();
    clear.headers_input = "{}".into();
    let cleared = authority.save_connection(&renamed.loaded, &clear).unwrap();
    assert_eq!(secrets(&cleared.loaded.entries[0]).unwrap().1.len(), 0);
    assert!(!format!("{:?}", cleared.profile).contains(SYNTHETIC_KEY));
}
#[test]
fn route_edits_fork_but_budget_reasoning_and_name_keep_identity() {
    for route in ["model", "url"] {
        let (authority, _, loaded) = save();
        let mut edit = loaded.edit("00000000-0000-4000-8000-000000000001").unwrap();
        if route == "model" {
            edit.profile.model_id = "other".into();
        } else {
            edit.profile.base_url = "http://127.0.0.1:3334".into();
        }
        let result = authority.save_connection(&loaded, &edit).unwrap();
        assert!(result.forked);
        assert_ne!(
            result.profile.profile.id,
            "00000000-0000-4000-8000-000000000001"
        );
        assert_eq!(result.loaded.profiles().len(), 2);
        assert_eq!(result.loaded.profiles()[0].profile.model_id, "fixture");
    }
    let (authority, _, loaded) = save();
    let mut edit = loaded.edit("00000000-0000-4000-8000-000000000001").unwrap();
    edit.profile.max_output_tokens = 8192;
    edit.profile.reasoning = true;
    edit.name = "new".into();
    let result = authority.save_connection(&loaded, &edit).unwrap();
    assert!(!result.forked);
    assert_eq!(result.loaded.profiles().len(), 1);
    let mut unsupported = result
        .loaded
        .edit("00000000-0000-4000-8000-000000000001")
        .unwrap();
    unsupported.profile.api = "anthropic-messages".into();
    assert!(
        authority
            .save_connection(&result.loaded, &unsupported)
            .is_err()
    );
}
#[test]
fn project_and_connection_writes_share_cas_and_preserve_opaque_raw_values() {
    let bytes=br#"{"schema":1,"revision":0,"workspaces":[],"captureKey":"opaque-key","future":{"huge":1234567890123456789012345678901234567890,"escaped":"\u0061","unknown":[ true , null ]}}"#.to_vec();
    let (authority, control) = ProjectAuthority::with_synthetic_bytes(Some(bytes)).unwrap();
    let loaded = authority.load_connections().unwrap();
    let mut roots = authority.load().unwrap().edit();
    let dir = tempfile::tempdir().unwrap();
    roots
        .trust_project(&uuid::Uuid::new_v4().to_string(), dir.path(), &[])
        .unwrap();
    authority.save(&mut roots).unwrap();
    assert!(matches!(
        authority.save_connection(&loaded, &draft()),
        Err(AuthorityError::Conflict)
    ));
    let loaded = authority.load_connections().unwrap();
    authority.save_connection(&loaded, &draft()).unwrap();
    assert!(matches!(
        authority.save(&mut roots),
        Err(AuthorityError::Conflict)
    ));
    let output = String::from_utf8(control.snapshot_bytes().unwrap().unwrap()).unwrap();
    assert!(output.contains(r#"{"huge":1234567890123456789012345678901234567890,"escaped":"\u0061","unknown":[ true , null ]}"#));
    assert!(output.contains("opaque-key"));
    assert_eq!(authority.load().unwrap().projects().len(), 1);
}
#[test]
fn distinct_backend_identical_bytes_and_same_revision_changed_bytes_conflict() {
    let (authority, control, loaded) = save();
    let bytes = control.snapshot_bytes().unwrap();
    let (other, _) = ProjectAuthority::with_synthetic_bytes(bytes.clone()).unwrap();
    let mut edit = loaded.edit("00000000-0000-4000-8000-000000000001").unwrap();
    edit.name = "changed".into();
    assert!(matches!(
        other.save_connection(&loaded, &edit),
        Err(AuthorityError::Conflict)
    ));
    assert!(
        other
            .confirm_connection(&loaded, "00000000-0000-4000-8000-000000000001")
            .is_err()
    );
    let mut changed = bytes.unwrap();
    changed.push(b' ');
    control.replace_bytes(Some(changed)).unwrap();
    assert!(matches!(
        authority.save_connection(&loaded, &edit),
        Err(AuthorityError::Conflict)
    ));
    assert!(edit.has_changes());
}
#[test]
fn denied_conflict_and_possible_commit_keep_exact_draft_and_baseline() {
    for error in [
        AuthorityError::Denied,
        AuthorityError::Conflict,
        AuthorityError::Unconfirmed,
    ] {
        let (authority, control, loaded) = save();
        let before = control.snapshot_bytes().unwrap();
        let mut edit = loaded.edit("00000000-0000-4000-8000-000000000001").unwrap();
        edit.name = "Retain my draft".into();
        control.fail_next_write(error.clone()).unwrap();
        assert!(matches!(authority.save_connection(&loaded,&edit),Err(actual) if actual==error));
        assert_eq!(edit.name, "Retain my draft");
        assert!(edit.has_changes());
        assert_eq!(loaded.revision(), 1);
        if error == AuthorityError::Unconfirmed {
            assert_ne!(before, control.snapshot_bytes().unwrap());
            assert!(matches!(
                authority.save_connection(&loaded, &edit),
                Err(AuthorityError::Conflict)
            ));
        } else {
            assert_eq!(before, control.snapshot_bytes().unwrap());
        }
    }
}
#[test]
fn sequential_tabs_report_partial_via_individual_results_and_preserve_remaining_edits() {
    let (authority, control, loaded) = save();
    let mut one = loaded.edit("00000000-0000-4000-8000-000000000001").unwrap();
    one.name = "first committed".into();
    let mut two = draft();
    two.profile.id = "00000000-0000-4000-8000-000000000002".into();
    two.name = "second draft".into();
    let first = authority.save_connection(&loaded, &one).unwrap();
    control
        .fail_next_write(AuthorityError::Unconfirmed)
        .unwrap();
    assert!(matches!(
        authority.save_connection(&first.loaded, &two),
        Err(AuthorityError::Unconfirmed)
    ));
    assert_eq!(first.loaded.profiles()[0].name, "first committed");
    assert_eq!(two.name, "second draft");
    assert!(two.has_changes());
    assert_eq!(authority.load_connections().unwrap().profiles().len(), 2);
}
#[test]
fn unsupported_profile_and_opaque_future_fields_are_retained_unavailable() {
    let (authority, control, loaded) = save();
    let mut fields: Fields =
        serde_json::from_slice(&control.snapshot_bytes().unwrap().unwrap()).unwrap();
    let mut entries: Vec<Fields> = parse(fields.0.get("profiles").unwrap()).unwrap();
    let mut saved: Fields = field(&entries[0], "profile").unwrap();
    saved.0.insert(
        "futurePolicy".into(),
        serde_json::value::RawValue::from_string(
            r#"{"huge":99999999999999999999999999999}"#.into(),
        )
        .unwrap(),
    );
    entries[0].0.insert("profile".into(), raw(&saved).unwrap());
    fields.0.insert("profiles".into(), raw(&entries).unwrap());
    control
        .replace_bytes(Some(serde_json::to_vec(&fields).unwrap()))
        .unwrap();
    let current = authority.load_connections().unwrap();
    assert!(!current.profiles()[0].available);
    assert!(
        authority
            .confirm_connection(&current, "00000000-0000-4000-8000-000000000001")
            .is_err()
    );
    let mut next = draft();
    next.profile.id = "00000000-0000-4000-8000-000000000003".into();
    let result = authority.save_connection(&current, &next).unwrap();
    assert_eq!(result.loaded.profiles().len(), 2);
    assert!(
        String::from_utf8(control.snapshot_bytes().unwrap().unwrap())
            .unwrap()
            .contains(r#"{"huge":99999999999999999999999999999}"#)
    );
    assert_eq!(
        loaded.profiles()[0].profile.id,
        "00000000-0000-4000-8000-000000000001"
    );
}
#[test]
fn synthetic_inputs_cannot_accept_real_keys_headers_nonloopback_or_header_bypass() {
    let (authority, control, loaded) = fixture();
    for key in ["real-key", "", "synthetic-project-fixture-only\t", "\u{7f}"] {
        let mut form = draft();
        form.key_input = key.into();
        assert!(authority.save_connection(&loaded, &form).is_err());
    }
    for url in [
        "https://example.test",
        "http://localhost:3333",
        "http://127.0.0.1:3333?secret=x",
    ] {
        let mut form = draft();
        form.profile.base_url = url.into();
        assert!(authority.save_connection(&loaded, &form).is_err());
    }
    for headers in [
        r#"{"X-Fixture":"real-header"}"#,
        r#"{"X-Fixture":"a","X-Fixture":"b"}"#,
        r#"{"X-Fixture":true}"#,
    ] {
        let mut form = draft();
        form.headers_input = headers.into();
        assert!(authority.save_connection(&loaded, &form).is_err());
    }
    let mut form = draft();
    form.profile
        .headers
        .insert("X-Fixture".into(), SYNTHETIC_HEADER.into());
    assert!(authority.save_connection(&loaded, &form).is_err());
    assert!(control.snapshot_bytes().unwrap().is_none());
}
#[test]
fn every_ascii_control_key_and_header_is_rejected_and_headers_are_bounded() {
    for byte in (0_u8..32).chain(std::iter::once(127)) {
        assert!(Credential::new(format!("prefix{}suffix", char::from(byte))).is_err());
        let mut p = profile();
        p.headers
            .insert("X-Test".into(), format!("prefix{}suffix", char::from(byte)));
        assert!(p.validate().is_err());
    }
    let mut p = profile();
    for index in 0..64 {
        p.headers
            .insert(format!("X-{index}"), SYNTHETIC_HEADER.into());
    }
    p.validate().unwrap();
    p.headers.insert("X-65".into(), SYNTHETIC_HEADER.into());
    assert!(p.validate().is_err());
}
#[test]
fn default_authority_stays_unavailable_and_deletion_preserves_unrelated_envelope() {
    assert!(matches!(
        ProjectAuthority::new().load_connections(),
        Err(AuthorityError::Unavailable)
    ));
    let (authority, control, loaded) = save();
    authority
        .delete_connection(&loaded, "00000000-0000-4000-8000-000000000001")
        .unwrap();
    assert!(authority.load_connections().unwrap().profiles().is_empty());
    assert!(
        authority
            .confirm_connection(&loaded, "00000000-0000-4000-8000-000000000001")
            .is_err()
    );
    assert!(control.snapshot_bytes().unwrap().is_some());
}

async fn request(socket: &mut TcpStream) -> Value {
    let mut bytes = vec![];
    timeout(Duration::from_secs(5), async {
        loop {
            let mut chunk = [0; 4096];
            let n = socket.read(&mut chunk).await.unwrap();
            assert!(n > 0);
            bytes.extend_from_slice(&chunk[..n]);
            if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&bytes[..end]);
                let length = headers
                    .lines()
                    .find_map(|line| {
                        line.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .and_then(|v| v.trim().parse::<usize>().ok())
                    })
                    .unwrap();
                if bytes.len() >= end + 4 + length {
                    break serde_json::from_slice(&bytes[end + 4..end + 4 + length]).unwrap();
                }
            }
        }
    })
    .await
    .unwrap()
}
async fn complete(socket: &mut TcpStream) {
    let body = r#"{"id":"fixture","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"done"}]}]}"#;
    socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).as_bytes()).await.unwrap();
}
async fn settled(controller: &Arc<Controller>) {
    timeout(Duration::from_secs(5), async {
        loop {
            let check = controller.suspend_idle_admission();
            if let Ok(guard) = check {
                drop(guard);
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
}
#[tokio::test]
async fn active_worker_keeps_original_configuration_until_settled_then_next_run_uses_saved() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (authority, control, loaded) = fixture();
    let mut form = draft();
    form.profile.base_url = format!("http://{}", listener.local_addr().unwrap());
    form.profile.reasoning = true;
    form.profile.thinking_level = "low".into();
    form.profile.model_output_limit = Some(512);
    let saved = authority.save_connection(&loaded, &form).unwrap();
    let old = SyntheticConnectionRuntime::confirm(
        &control,
        &saved.loaded,
        "00000000-0000-4000-8000-000000000001",
    )
    .unwrap();
    let controller = old
        .open(SessionStore::pending(), RuntimeOptions::default())
        .unwrap();
    let directory = tempfile::tempdir().unwrap();
    controller
        .materialize(&directory.path().join("session.json"))
        .unwrap();
    controller.submit("first".into(), Lane::FollowUp).unwrap();
    let (mut socket, _) = timeout(Duration::from_secs(5), listener.accept())
        .await
        .unwrap()
        .unwrap();
    let first = request(&mut socket).await;
    assert_eq!(first["reasoning"]["effort"], "low");
    assert_eq!(first["max_output_tokens"], 512);
    let active_preview = controller.prepare_context("").unwrap();
    let mut changed = saved
        .loaded
        .edit("00000000-0000-4000-8000-000000000001")
        .unwrap();
    changed.profile.thinking_level = "high".into();
    changed.profile.model_output_limit = Some(1024);
    let saved2 = authority.save_connection(&saved.loaded, &changed).unwrap();
    let new = SyntheticConnectionRuntime::confirm(
        &control,
        &saved2.loaded,
        "00000000-0000-4000-8000-000000000001",
    )
    .unwrap();
    assert!(!controller.configure(new.configuration()).unwrap());
    assert!(controller.settings_pending());
    assert_eq!(controller.profile().unwrap().thinking_level, "low");
    assert!(controller.context_preview_is_current(&active_preview));
    complete(&mut socket).await;
    settled(&controller).await;
    assert!(!controller.settings_pending());
    assert_eq!(controller.profile().unwrap().thinking_level, "high");
    assert!(!controller.context_preview_is_current(&active_preview));
    controller.submit("second".into(), Lane::FollowUp).unwrap();
    let (mut socket, _) = timeout(Duration::from_secs(5), listener.accept())
        .await
        .unwrap()
        .unwrap();
    let next = request(&mut socket).await;
    assert_eq!(next["reasoning"]["effort"], "high");
    assert_eq!(next["max_output_tokens"], 1024);
    complete(&mut socket).await;
    settled(&controller).await;
    controller.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn idle_configuration_refresh_invalidates_preview_and_route_or_authority_rebind_is_rejected()
{
    let (authority, control, loaded) = save();
    let runtime = SyntheticConnectionRuntime::confirm(
        &control,
        &loaded,
        "00000000-0000-4000-8000-000000000001",
    )
    .unwrap();
    let controller = runtime
        .open(SessionStore::pending(), RuntimeOptions::default())
        .unwrap();
    let preview = controller.prepare_context("unsent").unwrap();
    let mut edit = loaded.edit("00000000-0000-4000-8000-000000000001").unwrap();
    edit.profile.max_output_tokens = 8192;
    let saved = authority.save_connection(&loaded, &edit).unwrap();
    assert!(controller.submit("stale".into(), Lane::FollowUp).is_err());
    assert!(controller.snapshot().messages.is_empty());
    let next = SyntheticConnectionRuntime::confirm(
        &control,
        &saved.loaded,
        "00000000-0000-4000-8000-000000000001",
    )
    .unwrap();
    assert!(controller.configure(next.configuration()).unwrap());
    assert!(!controller.context_preview_is_current(&preview));
    let mut fork = saved
        .loaded
        .edit("00000000-0000-4000-8000-000000000001")
        .unwrap();
    fork.profile.model_id = "other".into();
    let forked = authority.save_connection(&saved.loaded, &fork).unwrap();
    let other =
        SyntheticConnectionRuntime::confirm(&control, &forked.loaded, &forked.profile.profile.id)
            .unwrap();
    assert!(controller.configure(other.configuration()).is_err());
    let (different, different_control) =
        ProjectAuthority::with_synthetic_bytes(control.snapshot_bytes().unwrap()).unwrap();
    let foreign = SyntheticConnectionRuntime::confirm(
        &different_control,
        &different.load_connections().unwrap(),
        "00000000-0000-4000-8000-000000000001",
    )
    .unwrap();
    assert!(controller.configure(foreign.configuration()).is_err());
    next.revoke();
    assert!(controller.submit("revoked".into(), Lane::FollowUp).is_err());
    assert!(controller.retry().is_err());
    assert!(controller.resume().is_err());
    controller.stop().unwrap();
    controller.retire_and_wait().await.unwrap();
}
#[tokio::test]
async fn delete_revocation_can_stop_join_active_worker_and_reject_stale_arcs() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (authority, control, loaded) = fixture();
    let mut form = draft();
    form.profile.base_url = format!("http://{}", listener.local_addr().unwrap());
    let saved = authority.save_connection(&loaded, &form).unwrap();
    let runtime = SyntheticConnectionRuntime::confirm(
        &control,
        &saved.loaded,
        "00000000-0000-4000-8000-000000000001",
    )
    .unwrap();
    let controller = runtime
        .open(SessionStore::pending(), RuntimeOptions::default())
        .unwrap();
    let directory = tempfile::tempdir().unwrap();
    controller
        .materialize(&directory.path().join("session.json"))
        .unwrap();
    controller.submit("active".into(), Lane::FollowUp).unwrap();
    let (mut socket, _) = timeout(Duration::from_secs(5), listener.accept())
        .await
        .unwrap()
        .unwrap();
    request(&mut socket).await;
    runtime.revoke();
    assert!(controller.submit("late".into(), Lane::FollowUp).is_err());
    timeout(Duration::from_secs(5), controller.retire_and_wait())
        .await
        .unwrap()
        .unwrap();
    authority
        .delete_connection(&saved.loaded, "00000000-0000-4000-8000-000000000001")
        .unwrap();
    assert!(
        runtime
            .open(SessionStore::pending(), RuntimeOptions::default())
            .is_err()
    );
    assert!(
        controller
            .submit("stale arc".into(), Lane::FollowUp)
            .is_err()
    );
    assert!(controller.snapshot().queue_paused);
}

#[test]
fn saved_connection_client_ignores_process_proxy_in_bounded_subprocess() {
    const CHILD: &str = "BELLO_SAVED_CONNECTION_PROXY_CHILD";
    if std::env::var_os(CHILD).is_some() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
                let (authority, control, loaded) = fixture();
                let mut form = draft();
                form.profile.base_url = format!("http://{}", listener.local_addr().unwrap());
                let saved = authority.save_connection(&loaded, &form).unwrap();
                let runtime = SyntheticConnectionRuntime::confirm(
                    &control,
                    &saved.loaded,
                    &saved.profile.profile.id,
                )
                .unwrap();
                let directory = tempfile::tempdir().unwrap();
                let controller = runtime
                    .open(
                        SessionStore::open(directory.path().join("session.json")).unwrap(),
                        RuntimeOptions::default(),
                    )
                    .unwrap();
                controller
                    .submit("proxy isolation".into(), Lane::FollowUp)
                    .unwrap();
                let (mut socket, _) = timeout(Duration::from_secs(5), listener.accept())
                    .await
                    .unwrap()
                    .unwrap();
                let body = request(&mut socket).await;
                assert_eq!(body["input"][0]["content"][0]["text"], "proxy isolation");
                complete(&mut socket).await;
                settled(&controller).await;
                controller.retire_and_wait().await.unwrap();
            });
        return;
    }
    let proxy = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    proxy.set_nonblocking(true).unwrap();
    let proxy_url = format!("http://{}", proxy.local_addr().unwrap());
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command.args(["--exact","project_authority::connections::tests::saved_connection_client_ignores_process_proxy_in_bounded_subprocess","--nocapture"])
        .env(CHILD,"1").env("NO_PROXY","").env("no_proxy","").stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    for name in [
        "HTTP_PROXY",
        "http_proxy",
        "HTTPS_PROXY",
        "https_proxy",
        "ALL_PROXY",
        "all_proxy",
    ] {
        command.env(name, &proxy_url);
    }
    let mut child = command.spawn().unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if std::time::Instant::now() >= deadline {
            child.kill().unwrap();
            panic!(
                "proxy child timed out: {:?}",
                child.wait_with_output().unwrap()
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
    assert!(matches!(proxy.accept(),Err(error) if error.kind()==std::io::ErrorKind::WouldBlock));
}
#[tokio::test]
async fn saved_connection_client_never_follows_redirect_to_another_listener() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let redirected = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (authority, control, loaded) = fixture();
    let mut form = draft();
    form.profile.base_url = format!("http://{}", listener.local_addr().unwrap());
    let saved = authority.save_connection(&loaded, &form).unwrap();
    let runtime =
        SyntheticConnectionRuntime::confirm(&control, &saved.loaded, &saved.profile.profile.id)
            .unwrap();
    let dir = tempfile::tempdir().unwrap();
    let controller = runtime
        .open(
            SessionStore::open(dir.path().join("session.json")).unwrap(),
            RuntimeOptions::default(),
        )
        .unwrap();
    controller
        .submit("do not redirect".into(), Lane::FollowUp)
        .unwrap();
    let (mut socket, _) = timeout(Duration::from_secs(5), listener.accept())
        .await
        .unwrap()
        .unwrap();
    request(&mut socket).await;
    socket.write_all(format!("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://{}/v1/responses\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",redirected.local_addr().unwrap()).as_bytes()).await.unwrap();
    settled(&controller).await;
    assert_eq!(controller.snapshot().state, crate::RunState::Error);
    assert!(
        timeout(Duration::from_millis(50), redirected.accept())
            .await
            .is_err()
    );
    controller.retire_and_wait().await.unwrap();
}

#[test]
fn duplicate_stored_headers_and_secret_bearing_invalid_urls_are_unavailable_without_echo() {
    let (authority, control, _loaded) = save();
    let mut fields: Fields =
        serde_json::from_slice(&control.snapshot_bytes().unwrap().unwrap()).unwrap();
    let mut entries: Vec<Fields> = parse(fields.0.get("profiles").unwrap()).unwrap();
    entries[0].0.insert(
        "headers".into(),
        serde_json::value::RawValue::from_string(format!(
            r#"{{"X-Fixture":"opaque-not-for-display","X-Fixture":"{SYNTHETIC_HEADER}"}}"#
        ))
        .unwrap(),
    );
    fields.0.insert("profiles".into(), raw(&entries).unwrap());
    control
        .replace_bytes(Some(serde_json::to_vec(&fields).unwrap()))
        .unwrap();
    let current = authority.load_connections().unwrap();
    assert!(!current.profiles()[0].available);
    assert!(!format!("{:?}", current.profiles()[0]).contains("opaque-not-for-display"));
    entries[0].0.insert(
        "headers".into(),
        raw(&BTreeMap::<String, String>::new()).unwrap(),
    );
    let mut profile: Fields = field(&entries[0], "profile").unwrap();
    profile.0.insert(
        "baseUrl".into(),
        raw(&"https://user:opaque-password@example.test/?key=opaque-query").unwrap(),
    );
    entries[0]
        .0
        .insert("profile".into(), raw(&profile).unwrap());
    fields.0.insert("profiles".into(), raw(&entries).unwrap());
    control
        .replace_bytes(Some(serde_json::to_vec(&fields).unwrap()))
        .unwrap();
    let current = authority.load_connections().unwrap();
    assert!(!current.profiles()[0].available);
    assert!(current.profiles()[0].profile.base_url.is_empty());
    assert!(!format!("{:?}", current.profiles()[0]).contains("opaque-password"));
    assert!(!format!("{:?}", current.profiles()[0]).contains("opaque-query"));
}

#[tokio::test]
async fn successful_empty_queue_settlement_needs_no_additional_vault_read() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (authority, control, loaded) = fixture();
    let mut form = draft();
    form.profile.base_url = format!("http://{}", listener.local_addr().unwrap());
    let saved = authority.save_connection(&loaded, &form).unwrap();
    let runtime =
        SyntheticConnectionRuntime::confirm(&control, &saved.loaded, &saved.profile.profile.id)
            .unwrap();
    let dir = tempfile::tempdir().unwrap();
    let controller = runtime
        .open(
            SessionStore::open(dir.path().join("session.json")).unwrap(),
            RuntimeOptions::default(),
        )
        .unwrap();
    controller
        .submit("finish successfully".into(), Lane::FollowUp)
        .unwrap();
    let (mut socket, _) = timeout(Duration::from_secs(5), listener.accept())
        .await
        .unwrap()
        .unwrap();
    request(&mut socket).await;
    control.fail_next_read(AuthorityError::Denied).unwrap();
    complete(&mut socket).await;
    settled(&controller).await;
    assert_eq!(controller.snapshot().state, crate::RunState::Idle);
    assert!(controller.snapshot().error.is_none());
    assert!(
        matches!(authority.load_connections(), Err(AuthorityError::Denied)),
        "settlement must not consume the next vault read"
    );
    controller.retire_and_wait().await.unwrap();
}

#[test]
fn explicit_image_input_metadata_survives_vault_save_reload_and_name_edit() {
    let (authority, _, loaded) = fixture();
    let mut form = draft();
    form.profile.input = vec!["text".into(), "image".into()];
    let saved = authority.save_connection(&loaded, &form).unwrap();
    assert!(saved.profile.available);
    assert!(saved.profile.profile.supports_images());
    let loaded = authority.load_connections().unwrap();
    let mut renamed = loaded.edit(&saved.profile.profile.id).unwrap();
    renamed.name = "Image fixture renamed".into();
    let saved = authority.save_connection(&loaded, &renamed).unwrap();
    assert!(saved.profile.available);
    assert!(saved.profile.profile.supports_images());
}
