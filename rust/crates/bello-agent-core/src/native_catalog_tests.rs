//! Native provenance with in-memory storage and loopback fake HTTP only.
use super::*;
use crate::{Lane, SessionStore, Submission, model_catalog::CancellationToken};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::{Duration, timeout},
};

const DEADLINE: Duration = Duration::from_secs(5);
async fn read(socket: &mut TcpStream) -> (String, Value) {
    let mut bytes = Vec::new();
    loop {
        let mut chunk = [0; 4096];
        let count = socket.read(&mut chunk).await.unwrap();
        assert!(count > 0);
        bytes.extend_from_slice(&chunk[..count]);
        assert!(bytes.len() < 512 * 1024);
        if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
            let headers = String::from_utf8(bytes[..end].to_vec())
                .unwrap()
                .to_ascii_lowercase();
            let size: usize = headers
                .lines()
                .find_map(|row| {
                    row.strip_prefix("content-length:")
                        .map(|v| v.trim().parse().unwrap())
                })
                .unwrap_or(0);
            if bytes.len() >= end + 4 + size {
                let body = if size == 0 {
                    Value::Null
                } else {
                    serde_json::from_slice(&bytes[end + 4..end + 4 + size]).unwrap()
                };
                return (headers, body);
            }
        }
    }
}
async fn catalog_reply(listener: &TcpListener, body: &str) -> String {
    let (mut socket, _) = timeout(DEADLINE, listener.accept()).await.unwrap().unwrap();
    let (headers, _) = timeout(DEADLINE, read(&mut socket)).await.unwrap();
    socket
        .write_all(
            format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    headers
}
async fn load(
    authority: &ProjectAuthority,
    loaded: &LoadedConnections,
    draft: &ConnectionDraft,
    listener: &TcpListener,
    body: &str,
) -> String {
    let request = authority.prepare_catalog(loaded, draft).unwrap();
    let (models, headers) = tokio::join!(
        request.load(CancellationToken::new()),
        catalog_reply(listener, body)
    );
    assert!(models.is_ok());
    headers
}

#[tokio::test]
async fn native_save_is_offline_explicit_catalog_refresh_updates_existing_chat_images_and_dispatch()
{
    let (authority, storage) = setup();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let mut form = draft(1);
    form.profile.base_url = base.clone();
    form.catalog_url = format!("{base}/catalog?fake=1");
    form.headers_input = r#"{"X-Provider-Only":"fake-header"}"#.into();
    let saved = authority
        .save_connection(&authority.load_connections().unwrap(), &form)
        .unwrap();
    let runtime =
        SavedConnectionRuntime::confirm(&authority, &saved.loaded, &form.profile.id).unwrap();
    let directory = tempfile::tempdir().unwrap();
    let controller = runtime
        .open(
            SessionStore::open(directory.path().join("chat.json")).unwrap(),
            Default::default(),
        )
        .unwrap();
    assert!(!controller.supports_image_attachments());
    assert!(
        timeout(Duration::from_millis(40), listener.accept())
            .await
            .is_err(),
        "Save and confirmation do not send GET or POST"
    );
    let before = storage.bytes.lock().unwrap().clone();
    let saved_form = saved.loaded.edit(&form.profile.id).unwrap();
    let headers = load(&authority, &saved.loaded, &saved_form, &listener, r#"[{"id":"fixture","input":["image"],"contextWindow":16000,"maxOutputTokens":1000,"reasoning":["low"]},{"id":"other","input":[],"contextWindow":2048,"maxOutputTokens":128,"reasoning":[]}]"#).await;
    assert!(headers.starts_with("get /catalog?fake=1 http/1.1"));
    assert!(headers.contains("authorization: bearer synthetic-project-fixture-only"));
    assert!(
        headers.contains("accept: application/json") && headers.contains("cache-control: no-cache")
    );
    for forbidden in ["x-provider-only", "cookie:", "x-api-key", "/models"] {
        assert!(!headers.contains(forbidden));
    }
    assert_eq!(*storage.bytes.lock().unwrap(), before);
    assert_eq!(saved.profile.profile.input, ["text"]);
    assert!(
        controller.supports_image_attachments(),
        "existing native chat observes explicit catalog load"
    );
    let mut override_item = Submission::new("override".into(), Lane::FollowUp);
    override_item.model = Some("other".into());
    override_item.effort = Some("high".into());
    let effective = runtime
        .configuration()
        .effective_profile(Some(&override_item));
    assert!(!effective.supports_images());
    assert_eq!(effective.context_window, 2048);
    assert_eq!(effective.max_output_tokens, 128);
    assert_eq!(effective.model_output_limit, Some(128));
    assert_eq!(effective.thinking_level, "default");
    assert!(!effective.reasoning);
    // Catalog input belongs to its model, while declared input applies across
    // aliases exactly as Swift's modelInput(for:) does.
    let mut declared = saved_form.clone();
    declared.profile.input = vec!["text".into(), "image".into()];
    let declared = authority.save_connection(&saved.loaded, &declared).unwrap();
    let declared_runtime =
        SavedConnectionRuntime::confirm(&authority, &declared.loaded, &form.profile.id).unwrap();
    assert!(
        declared_runtime
            .configuration()
            .effective_profile(Some(&override_item))
            .supports_images()
    );
    #[cfg(target_os = "macos")]
    {
        let source = directory.path().join("image.gif");
        std::fs::write(&source, b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x01L\x00;").unwrap();
        let mut item = Submission::new(String::new(), Lane::FollowUp);
        item.attachments
            .push(crate::attachments::AttachmentRecord::inspect(&source).unwrap());
        // Exercise catalog-only input, rather than the declaration added above.
        // Its exact vault lease needs the latest declaration; remove it again.
        let mut text_only = declared.loaded.edit(&form.profile.id).unwrap();
        text_only.profile.input = vec!["text".into()];
        let text_only = authority
            .save_connection(&declared.loaded, &text_only)
            .unwrap();
        let current =
            SavedConnectionRuntime::confirm(&authority, &text_only.loaded, &form.profile.id)
                .unwrap();
        controller.configure(current.configuration()).unwrap();
        controller
            .submit_identified_with_attachments(item)
            .await
            .unwrap();
        let (mut socket, _) = timeout(DEADLINE, listener.accept()).await.unwrap().unwrap();
        let (headers, body) = timeout(DEADLINE, read(&mut socket)).await.unwrap();
        assert!(headers.starts_with("post /v1/responses http/1.1"));
        assert!(headers.contains("x-provider-only: fake-header"));
        assert_eq!(body["model"], "fixture");
        assert!(body["input"].as_array().unwrap().iter().any(|row| {
            row["content"]
                .as_array()
                .is_some_and(|content| content.iter().any(|part| part["type"] == "input_image"))
        }));
        socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n").await.unwrap();
        socket.shutdown().await.unwrap();
        timeout(DEADLINE, async {
            let mut updates = controller.subscribe();
            while updates.borrow_and_update().state == crate::RunState::Running {
                updates.changed().await.unwrap();
            }
        })
        .await
        .unwrap();
    }
    let latest = authority.load_connections().unwrap();
    let current = SavedConnectionRuntime::confirm(&authority, &latest, &form.profile.id).unwrap();
    controller.configure(current.configuration()).unwrap();
    let mut text_only = latest.edit(&form.profile.id).unwrap();
    text_only.profile.input = vec!["text".into()];
    let text_only = authority.save_connection(&latest, &text_only).unwrap();
    let current =
        SavedConnectionRuntime::confirm(&authority, &text_only.loaded, &form.profile.id).unwrap();
    controller.configure(current.configuration()).unwrap();
    let headers = load(
        &authority,
        &text_only.loaded,
        &text_only.loaded.edit(&form.profile.id).unwrap(),
        &listener,
        r#"[{"id":"fixture","input":[]}]"#,
    )
    .await;
    assert!(headers.starts_with("get /catalog?fake=1"));
    assert!(!controller.supports_image_attachments());
    assert!(
        timeout(Duration::from_millis(40), listener.accept())
            .await
            .is_err(),
        "Refresh sends no turn"
    );
    current.revoke();
    assert!(controller.submit("revoked".into(), Lane::FollowUp).is_err());
}

#[tokio::test]
async fn native_public_catalog_is_anonymous_and_custom_failure_never_falls_back_to_bundled() {
    let (authority, _) = setup();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut form = draft(1);
    form.catalog_url = format!("http://{}/public", listener.local_addr().unwrap());
    form.profile.model_id = "gemini-3.8-flash".into();
    let saved = authority
        .save_connection(&authority.load_connections().unwrap(), &form)
        .unwrap();
    let runtime =
        SavedConnectionRuntime::confirm(&authority, &saved.loaded, &form.profile.id).unwrap();
    let controller = runtime
        .open(SessionStore::pending(), Default::default())
        .unwrap();
    assert!(!controller.supports_image_attachments());
    assert!(
        !runtime.configuration().effective_profile(None).reasoning,
        "custom failure cannot use bundled reasoning metadata"
    );
    let edit = saved.loaded.edit(&form.profile.id).unwrap();
    reset_key_reads();
    let request = authority.prepare_catalog(&saved.loaded, &edit).unwrap();
    assert_eq!(key_reads(), 0);
    let (result, headers) = tokio::join!(
        request.load(CancellationToken::new()),
        catalog_reply(&listener, "private malformed detail")
    );
    assert_eq!(result, Err(crate::model_catalog::CatalogError::Malformed));
    assert!(!headers.contains("authorization:"));
    assert!(!controller.supports_image_attachments());
    let headers = load(
        &authority,
        &saved.loaded,
        &edit,
        &listener,
        &json!([{"id":form.profile.model_id,"input":["image"]}]).to_string(),
    )
    .await;
    assert!(!headers.contains("authorization:"));
    assert!(controller.supports_image_attachments());
    let request = authority.prepare_catalog(&saved.loaded, &edit).unwrap();
    let (result, _) = tokio::join!(
        request.load(CancellationToken::new()),
        catalog_reply(&listener, "bad")
    );
    assert!(result.is_err());
    assert!(
        controller.supports_image_attachments(),
        "failed same-source refresh retains previous descriptors"
    );
    let mut changed = edit.clone();
    changed.catalog_url.push_str("-changed");
    let changed = authority.save_connection(&saved.loaded, &changed).unwrap();
    let changed_runtime =
        SavedConnectionRuntime::confirm(&authority, &changed.loaded, &form.profile.id).unwrap();
    assert!(
        !changed_runtime
            .configuration()
            .effective_profile(None)
            .supports_images()
    );
    let (foreign, _) = setup();
    assert!(matches!(
        foreign.prepare_catalog(&saved.loaded, &edit),
        Err(AuthorityError::Conflict)
    ));
}

#[test]
fn native_bundled_models_merge_declared_inputs_offline_and_fixture_provenance_stays_text_only() {
    let (authority, _) = setup();
    let mut form = draft(1);
    form.catalog_url.clear();
    form.profile.model_id = "gemini-3.8-flash".into();
    let saved = authority
        .save_connection(&authority.load_connections().unwrap(), &form)
        .unwrap();
    let native =
        SavedConnectionRuntime::confirm(&authority, &saved.loaded, &form.profile.id).unwrap();
    assert!(
        !native
            .configuration()
            .effective_profile(None)
            .supports_images()
    );
    assert_eq!(native.metadata().profile.input, ["text"]);
    // The shipped Swift catalog has no input fields; retain that exact file.
    let mut declared = saved.loaded.edit(&form.profile.id).unwrap();
    declared.profile.input = vec!["text".into(), "image".into()];
    let declared = authority.save_connection(&saved.loaded, &declared).unwrap();
    let native =
        SavedConnectionRuntime::confirm(&authority, &declared.loaded, &form.profile.id).unwrap();
    assert!(
        native
            .configuration()
            .effective_profile(None)
            .supports_images()
    );
    #[cfg(feature = "synthetic-authority")]
    {
        let (fixture, _) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
        let saved = fixture
            .save_connection(&fixture.load_connections().unwrap(), &form)
            .unwrap();
        let runtime =
            SavedConnectionRuntime::confirm(&fixture, &saved.loaded, &form.profile.id).unwrap();
        assert!(
            !runtime
                .configuration()
                .effective_profile(None)
                .supports_images()
        );
    }
}

#[tokio::test]
async fn native_inherited_catalog_uses_source_credential_and_keeps_route_and_declared_input() {
    let (authority, _) = setup();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let mut route = draft(1);
    route.profile.input = vec!["image".into()];
    route.key_input = "fake-route-key".into();
    let route_saved = authority
        .save_connection(&authority.load_connections().unwrap(), &route)
        .unwrap();
    let mut source = draft(2);
    source.profile.base_url = base.clone();
    source.catalog_url = format!("{base}/source");
    source.key_input = "fake-source-key".into();
    source.headers_input = r#"{"X-Source-Private":"fake-source-header"}"#.into();
    let source_saved = authority
        .save_connection(&route_saved.loaded, &source)
        .unwrap();
    let linked = authority
        .use_catalog_source(&source_saved.loaded, &route.profile.id, &source.profile.id)
        .unwrap();
    let edit = linked.edit(&route.profile.id).unwrap();
    let request = authority.prepare_catalog(&linked, &edit).unwrap();
    assert_eq!(request.source_id(), Some(source.profile.id.as_str()));
    let (result, headers) = tokio::join!(
        request.load(CancellationToken::new()),
        catalog_reply(
            &listener,
            r#"[{"id":"fixture","input":["text"],"reasoning":[]}]"#
        )
    );
    assert!(result.is_ok());
    assert!(headers.starts_with("get /source http/1.1"));
    assert!(headers.contains("authorization: bearer fake-source-key"));
    assert!(!headers.contains("fake-route-key") && !headers.contains("x-source-private"));
    let runtime = SavedConnectionRuntime::confirm(&authority, &linked, &route.profile.id).unwrap();
    let effective = runtime.configuration().effective_profile(None);
    assert_eq!(effective.base_url, route.profile.base_url);
    assert_eq!(effective.id, route.profile.id);
    assert_eq!(
        effective.input,
        ["text", "image"],
        "Swift orders merged kinds"
    );
    // Invalid typed native key falls back to the saved key by id, as Swift does.
    // Typing a replacement detaches the inherited listing from its source.
    let mut own = linked.edit(&source.profile.id).unwrap();
    own.key_input = "invalid\nkey".into();
    reset_key_reads();
    let request = authority.prepare_catalog(&linked, &own).unwrap();
    assert_eq!(key_reads(), 1);
    let (result, headers) = tokio::join!(
        request.load(CancellationToken::new()),
        catalog_reply(&listener, r#"[{"id":"fixture"}]"#)
    );
    assert!(result.is_ok());
    assert!(headers.contains("authorization: bearer fake-source-key"));
}

#[tokio::test]
async fn native_chat_lists_its_custom_catalog_passively_once_per_freshness_window() {
    let (authority, _) = setup();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let mut form = draft(1);
    form.profile.base_url = base.clone();
    form.catalog_url = format!("{base}/chat-catalog");
    form.headers_input = r#"{"X-Provider-Only":"fake-header"}"#.into();
    let saved = authority
        .save_connection(&authority.load_connections().unwrap(), &form)
        .unwrap();
    let runtime =
        SavedConnectionRuntime::confirm(&authority, &saved.loaded, &form.profile.id).unwrap();
    let controller = runtime
        .open(SessionStore::pending(), Default::default())
        .unwrap();
    assert!(!controller.supports_image_attachments());
    assert!(
        timeout(Duration::from_millis(40), listener.accept())
            .await
            .is_err(),
        "opening a chat sends nothing by itself"
    );
    assert!(controller.model_catalog_stale());
    let request = controller.model_catalog_request(false).unwrap();
    assert!(
        !controller.model_catalog_stale(),
        "a listing in flight is joined"
    );
    assert!(controller.model_catalog_request(false).is_none());
    let (result, headers) = tokio::join!(
        request.load(CancellationToken::new()),
        catalog_reply(&listener, r#"[{"id":"fixture","input":["text","image"]}]"#)
    );
    assert!(result.is_ok());
    assert!(headers.starts_with("get /chat-catalog http/1.1"));
    assert!(headers.contains("authorization: bearer synthetic-project-fixture-only"));
    assert!(!headers.contains("x-provider-only"));
    assert!(controller.supports_image_attachments());
    assert_eq!(
        runtime.configuration().effective_profile(None).input,
        ["text", "image"]
    );
    assert!(!controller.model_catalog_stale(), "fresh for five minutes");
    let settings = authority
        .prepare_catalog(&saved.loaded, &saved.loaded.edit(&form.profile.id).unwrap())
        .unwrap();
    assert!(
        settings.fresh_models().is_some_and(
            |models| models[0].input.as_deref() == Some(&["text".into(), "image".into()][..])
        ),
        "an unforced Settings listing reuses the chat's fresh list"
    );
    drop(settings);
    assert!(
        !controller.model_catalog_stale(),
        "an unused request claims nothing"
    );
    assert!(controller.model_catalog_request(false).is_none());
    // Another chat on the same source shares the list without a request.
    let other = SavedConnectionRuntime::confirm(&authority, &saved.loaded, &form.profile.id)
        .unwrap()
        .open(SessionStore::pending(), Default::default())
        .unwrap();
    assert!(other.supports_image_attachments() && !other.model_catalog_stale());
    // A failed passive listing keeps the list and waits before retrying.
    let mut changed = saved.loaded.edit(&form.profile.id).unwrap();
    changed.catalog_url = format!("{base}/changed-catalog");
    let changed = authority.save_connection(&saved.loaded, &changed).unwrap();
    let changed_runtime =
        SavedConnectionRuntime::confirm(&authority, &changed.loaded, &form.profile.id).unwrap();
    let changed_chat = changed_runtime
        .open(SessionStore::pending(), Default::default())
        .unwrap();
    assert!(
        !changed_chat.supports_image_attachments(),
        "a new URL lists anew"
    );
    let request = changed_chat.model_catalog_request(false).unwrap();
    let (result, _) = tokio::join!(
        request.load(CancellationToken::new()),
        catalog_reply(&listener, "not a catalog")
    );
    assert!(result.is_err());
    assert!(!changed_chat.model_catalog_stale(), "failure retry is 30 s");
    // The older runtime's source is no longer saved: it never lists it again.
    assert!(controller.model_catalog_request(false).is_none() || controller.is_retired());
    // Bundled-catalog chats never list over the network; revoked ones never list.
    let mut bundled = draft(2);
    bundled.catalog_url.clear();
    let bundled = authority
        .save_connection(&changed.loaded, &bundled)
        .unwrap();
    let bundled_chat = SavedConnectionRuntime::confirm(
        &authority,
        &bundled.loaded,
        "00000000-0000-4000-8000-000000000002",
    )
    .unwrap()
    .open(SessionStore::pending(), Default::default())
    .unwrap();
    assert!(!bundled_chat.model_catalog_stale());
    assert!(bundled_chat.model_catalog_request(false).is_none());
    let mut public = draft(3);
    public.catalog_url = "https://catalog.invalid/never".into();
    let public = authority.save_connection(&bundled.loaded, &public).unwrap();
    let revoked = SavedConnectionRuntime::confirm(
        &authority,
        &public.loaded,
        "00000000-0000-4000-8000-000000000003",
    )
    .unwrap();
    let revoked_chat = revoked
        .open(SessionStore::pending(), Default::default())
        .unwrap();
    assert!(revoked_chat.model_catalog_stale());
    revoked.revoke();
    assert!(!revoked_chat.model_catalog_stale());
    assert!(revoked_chat.model_catalog_request(false).is_none());
    assert!(
        timeout(Duration::from_millis(40), listener.accept())
            .await
            .is_err()
    );
    #[cfg(feature = "synthetic-authority")]
    {
        let (fixture, _) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
        let mut fixture_form = draft(4);
        fixture_form.profile.base_url = base.clone();
        fixture_form.catalog_url = format!("{base}/fixture");
        let saved = fixture
            .save_connection(&fixture.load_connections().unwrap(), &fixture_form)
            .unwrap();
        let chat =
            SavedConnectionRuntime::confirm(&fixture, &saved.loaded, &fixture_form.profile.id)
                .unwrap()
                .open(SessionStore::pending(), Default::default())
                .unwrap();
        assert!(
            !chat.model_catalog_stale(),
            "fixture chats keep declared input"
        );
        assert!(chat.model_catalog_request(false).is_none());
    }
}

#[tokio::test]
async fn native_captured_default_model_keeps_saved_limits_and_followers_resync_their_source() {
    let (authority, _) = setup();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let mut route = draft(1);
    route.catalog_url.clear();
    let route_saved = authority
        .save_connection(&authority.load_connections().unwrap(), &route)
        .unwrap();
    let mut source = draft(2);
    source.profile.base_url = base.clone();
    source.catalog_url = format!("{base}/first");
    let source_saved = authority
        .save_connection(&route_saved.loaded, &source)
        .unwrap();
    let linked = authority
        .use_catalog_source(&source_saved.loaded, &route.profile.id, &source.profile.id)
        .unwrap();
    let runtime = SavedConnectionRuntime::confirm(&authority, &linked, &route.profile.id).unwrap();
    let controller = runtime
        .open(SessionStore::pending(), Default::default())
        .unwrap();
    let request = controller.model_catalog_request(false).unwrap();
    let (result, headers) = tokio::join!(
        request.load(CancellationToken::new()),
        catalog_reply(
            &listener,
            r#"[{"id":"fixture","input":["image"],"contextWindow":1000,"maxOutputTokens":10,"reasoning":[]}]"#
        )
    );
    assert!(result.is_ok());
    assert!(headers.starts_with("get /first http/1.1"));
    assert!(controller.supports_image_attachments());
    // A send captures the connection's own model and effort; that is not a
    // model choice, so the saved limits and reasoning stay.
    let mut captured = Submission::new("captured".into(), Lane::FollowUp);
    captured.model = Some(route.profile.model_id.clone());
    captured.effort = Some(route.profile.thinking_level.clone());
    let effective = runtime.configuration().effective_profile(Some(&captured));
    assert_eq!(effective.context_window, route.profile.context_window);
    assert_eq!(effective.max_output_tokens, route.profile.max_output_tokens);
    assert_eq!(effective.thinking_level, route.profile.thinking_level);
    assert!(effective.supports_images());
    // The followed source's URL changes; the follower's runtime is unchanged.
    let mut changed = linked.edit(&source.profile.id).unwrap();
    changed.catalog_url = format!("{base}/second");
    authority.save_connection(&linked, &changed).unwrap();
    assert!(
        controller.model_catalog_request(false).is_none(),
        "fresh list"
    );
    let request = controller.model_catalog_request(true).unwrap();
    let (result, headers) = tokio::join!(
        request.load(CancellationToken::new()),
        catalog_reply(&listener, r#"[{"id":"fixture","input":["text"]}]"#)
    );
    assert!(result.is_ok());
    assert!(headers.starts_with("get /second http/1.1"));
    assert!(!controller.supports_image_attachments());
    assert_eq!(
        runtime.configuration().effective_profile(None).base_url,
        route.profile.base_url,
        "the source never becomes the route"
    );
}
