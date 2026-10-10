//! Cost-free end-to-end catalog -> form -> vault -> route -> explicit send.
use super::*;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

#[derive(Clone, Debug)]
struct Receipt {
    method: String,
    bearer: bool,
    provider_header: bool,
    body: serde_json::Value,
}
struct Gateway {
    url: String,
    receipts: Arc<Mutex<Vec<Receipt>>>,
    fail: Arc<AtomicBool>,
    stalled: Arc<AtomicUsize>,
    cancelled: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl Gateway {
    fn new() -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let receipts = Arc::new(Mutex::new(Vec::new()));
        let fail = Arc::new(AtomicBool::new(false));
        let stalled = Arc::new(AtomicUsize::new(0));
        let cancelled = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let (seen, failing, stalling, closed, stopping) = (
            receipts.clone(),
            fail.clone(),
            stalled.clone(),
            cancelled.clone(),
            stop.clone(),
        );
        let worker = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(30);
            while !stopping.load(Ordering::SeqCst) {
                assert!(Instant::now() < deadline, "bounded catalog fixture");
                let mut stream = match listener.accept() {
                    Ok((stream, _)) => stream,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(2));
                        continue;
                    }
                    Err(e) => panic!("{e}"),
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut bytes = Vec::new();
                let mut buffer = [0u8; 4096];
                let (method, path, body, bearer, provider_header) = loop {
                    let n = stream.read(&mut buffer).unwrap();
                    assert!(n > 0);
                    bytes.extend_from_slice(&buffer[..n]);
                    assert!(bytes.len() < 256 * 1024);
                    if let Some(at) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                        let headers = String::from_utf8_lossy(&bytes[..at]).to_ascii_lowercase();
                        let length: usize = headers
                            .lines()
                            .find_map(|line| {
                                line.strip_prefix("content-length:")
                                    .map(|n| n.trim().parse().unwrap())
                            })
                            .unwrap_or(0);
                        if bytes.len() >= at + 4 + length {
                            let mut first = headers.lines().next().unwrap().split_whitespace();
                            let method = first.next().unwrap().to_owned();
                            let path = first.next().unwrap().to_owned();
                            let body = if length > 0 {
                                serde_json::from_slice(&bytes[at + 4..at + 4 + length]).unwrap()
                            } else {
                                serde_json::Value::Null
                            };
                            break (
                                method,
                                path,
                                body,
                                headers.contains(
                                    "authorization: bearer synthetic-project-fixture-only",
                                ),
                                headers.contains("x-fixture-provider:"),
                            );
                        }
                    }
                };
                seen.lock().unwrap().push(Receipt {
                    method: method.clone(),
                    bearer,
                    provider_header,
                    body,
                });
                if path.starts_with("/slow") {
                    stalling.fetch_add(1, Ordering::SeqCst);
                    stream
                        .set_read_timeout(Some(Duration::from_millis(30)))
                        .unwrap();
                    while !stopping.load(Ordering::SeqCst) {
                        match stream.read(&mut buffer) {
                            Ok(0) => {
                                closed.fetch_add(1, Ordering::SeqCst);
                                break;
                            }
                            Ok(_) => {}
                            Err(e)
                                if matches!(
                                    e.kind(),
                                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                                ) => {}
                            Err(_) => {
                                closed.fetch_add(1, Ordering::SeqCst);
                                break;
                            }
                        }
                    }
                    continue;
                }
                let (status, content_type, body) = if method == "get" {
                    if failing.load(Ordering::SeqCst) {
                        (
                            503,
                            "application/json",
                            "{\"error\":\"private fixture detail\"}".to_owned(),
                        )
                    } else {
                        let rows: Vec<_> = (0..170).map(|i| serde_json::json!({"id":format!("fixture-model-{i:03}"),"name":format!("Fixture model {i:03}"),"description":"Loopback only", "contextWindow":if i==169 {32000}else{1024},"maxOutputTokens":if i==169 {8192}else{128},"reasoning":["low"],"input":["text","image"],"deprecated":i==2})).collect();
                        (
                            200,
                            "application/json",
                            serde_json::json!({"version":1,"models":rows}).to_string(),
                        )
                    }
                } else {
                    (200,"text/event-stream","data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"catalog fixture reply\"}]}]}}\n\n".into())
                };
                let _ = write!(
                    stream,
                    "HTTP/1.1 {status} Fixture\r\nContent-Type: {content_type}\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{body}",
                    body.len()
                );
            }
        });
        Self {
            url,
            receipts,
            fail,
            stalled,
            cancelled,
            stop,
            worker: Some(worker),
        }
    }
    fn count(&self, method: &str) -> usize {
        self.receipts
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.method == method)
            .count()
    }
}
impl Drop for Gateway {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let result = worker.join();
            if !std::thread::panicking() {
                result.unwrap();
            }
        }
    }
}
fn catalog(
    root: &Entity<AgentView>,
    cx: &TestAppContext,
) -> crate::connection_settings_view::ConnectionCatalogPresentation {
    cx.read(|cx| {
        root.read(cx)
            .connections
            .presentation
            .active
            .as_ref()
            .unwrap()
            .catalog
            .clone()
    })
}
fn loaded(root: &Entity<AgentView>, cx: &mut TestAppContext) {
    wait(cx, |cx| !catalog(root, cx).loading);
}
fn choose(
    root: &Entity<AgentView>,
    window: WindowHandle<AgentView>,
    id: &str,
    cx: &mut TestAppContext,
) {
    edit(root, cx, |f| f.catalog_search = id.into());
    let state = catalog(root, cx);
    assert_eq!(state.models.len(), 1);
    act(
        window,
        Intent::ChooseCatalog {
            id: id.into(),
            generation: state.generation,
        },
        cx,
    );
}

#[gpui::test]
fn catalog_choose_save_fork_new_chat_and_explicit_posts_preserve_route_metadata(
    cx: &mut TestAppContext,
) {
    let (_dir, _control, window, root) = fixture(cx);
    let gateway = Gateway::new();
    edit(&root, cx, |f| {
        f.base_url = gateway.url.clone();
        f.catalog_url = format!("{}/catalog", gateway.url);
        f.key = SYNTHETIC_KEY.into();
        f.headers = "{\"X-Fixture-Provider\":\"synthetic-header-fixture-only\"}".into();
    });
    act(window, Intent::BrowseCatalog, cx);
    loaded(&root, cx);
    let state = catalog(&root, cx);
    assert_eq!(state.total, 169);
    assert_eq!(state.models.len(), 40);
    assert_eq!(state.pages, 5);
    assert_eq!(gateway.count("get"), 1);
    assert_eq!(gateway.count("post"), 0);
    let receipt = gateway.receipts.lock().unwrap()[0].clone();
    assert!(receipt.bearer);
    assert!(!receipt.provider_header);
    choose(&root, window, "fixture-model-169", cx);
    cx.read(|cx| {
        let view = root.read(cx);
        let form = &view.connections.forms[view.connections.active.as_ref().unwrap()];
        let draft = form.capture().unwrap();
        assert_eq!(draft.profile.model_output_limit, Some(8192));
        assert_eq!(draft.profile.max_output_tokens, 4096);
        assert_eq!(draft.profile.context_window, 32000);
        assert_eq!(draft.profile.thinking_level, "default");
        assert_eq!(draft.profile.input, ["text"]);
        assert!(form.dirty());
    });
    act(window, Intent::SaveAll, cx);
    let original = cx.read(|cx| root.read(cx).connections.choice.clone().unwrap());
    assert_eq!(gateway.count("post"), 0);
    root.update(cx, |view, cx| view.select_connection(&original, cx));
    cx.run_until_parked();
    root.update(cx, |view, cx| view.submit(Lane::FollowUp, cx));
    wait(cx, |_| gateway.count("post") == 1);
    wait(cx, |cx| {
        cx.read(|cx| root.read(cx).session.state != bello_agent_core::RunState::Running)
    });
    {
        let receipts = gateway.receipts.lock().unwrap();
        let post = receipts.iter().find(|r| r.method == "post").unwrap();
        assert_eq!(post.body["model"], "fixture-model-169");
        assert_eq!(post.body["max_output_tokens"], 8192);
        assert!(post.bearer);
        assert!(post.provider_header);
    }
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    act(window, Intent::BrowseCatalog, cx);
    loaded(&root, cx);
    choose(&root, window, "fixture-model-168", cx);
    act(window, Intent::SaveAll, cx);
    let fork = cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(
            view.record.connection_id.as_deref(),
            Some(original.as_str())
        );
        assert_eq!(
            view.controller.profile().unwrap().model_id,
            "fixture-model-169"
        );
        view.connections.choice.clone().unwrap()
    });
    assert_ne!(original, fork);
    assert_eq!(gateway.count("post"), 1);
    act(window, Intent::Select(original.clone()), cx);
    cx.read(|cx| {
        let view = root.read(cx);
        assert!(
            view.connections
                .presentation
                .active
                .as_ref()
                .unwrap()
                .inherited_catalog_name
                .is_some()
        );
        assert_eq!(
            view.controller.profile().unwrap().model_id,
            "fixture-model-169"
        );
    });
    act(window, Intent::Select(fork.clone()), cx);
    assert_eq!(gateway.count("post"), 1);
    act(window, Intent::Cancel, cx);
    window
        .update(cx, |view, window, cx| view.new_chat(window, cx))
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |view, cx| {
        assert_eq!(view.record.connection_id.as_deref(), Some(fork.as_str()));
        view.composer.update(cx, |editor, cx| {
            editor.set_text("explicit second request".into(), cx)
        });
        view.submit(Lane::FollowUp, cx);
    });
    wait(cx, |_| gateway.count("post") == 2);
    wait(cx, |cx| {
        cx.read(|cx| root.read(cx).session.state != bello_agent_core::RunState::Running)
    });
    assert_eq!(
        gateway
            .receipts
            .lock()
            .unwrap()
            .iter()
            .rfind(|r| r.method == "post")
            .unwrap()
            .body["model"],
        "fixture-model-168"
    );
}

#[gpui::test]
fn catalog_bundled_is_keyless_search_only_is_clean_and_metadata_survives_capture(
    cx: &mut TestAppContext,
) {
    let (_dir, _control, window, root) = fixture(cx);
    let gateway = Gateway::new();
    // Do not change saved values: opening/searching alone remains clean.
    act(window, Intent::BrowseCatalog, cx);
    loaded(&root, cx);
    assert_eq!(catalog(&root, cx).total, 6);
    edit(&root, cx, |f| f.catalog_search = "deepseek".into());
    cx.read(|cx| assert!(!root.read(cx).connections.presentation.dirty));
    choose(&root, window, "deepseek-v4.1-flash", cx);
    cx.read(|cx| {
        let view = root.read(cx);
        let form = &view.connections.forms[view.connections.active.as_ref().unwrap()];
        let draft = form.capture().unwrap();
        assert_eq!(draft.profile.max_output_tokens, 4096);
        assert_eq!(draft.profile.model_output_limit, Some(393216));
        assert!(form.dirty());
    });
    assert_eq!(gateway.count("get"), 0);
    assert_eq!(gateway.count("post"), 0);
    act(window, Intent::Cancel, cx);
}

#[gpui::test]
fn catalog_discard_reopen_removes_selected_metadata_and_success_notice(cx: &mut TestAppContext) {
    for close_path in 0..3 {
        let (_dir, control, window, root) = fixture(cx);
        let before = control.snapshot_bytes().unwrap();
        act(window, Intent::BrowseCatalog, cx);
        loaded(&root, cx);
        choose(&root, window, "deepseek-v4.1-flash", cx);
        cx.read(|cx| {
            let state = &root.read(cx).connections;
            let notice = state.presentation.notice.as_ref().unwrap();
            assert!(!notice.is_error);
            assert!(notice.text.contains("Model metadata applied"));
            assert_eq!(
                state.forms[state.active.as_ref().unwrap()]
                    .capture()
                    .unwrap()
                    .profile
                    .model_output_limit,
                Some(393216)
            );
        });
        match close_path {
            0 => act(window, Intent::Cancel, cx),
            1 => {
                act(window, Intent::RequestClose, cx);
                act(window, Intent::DiscardAndClose, cx);
            }
            _ => {
                act(window, Intent::DiscardCurrent, cx);
                act(window, Intent::RequestClose, cx);
            }
        }
        window
            .update(cx, |view, window, cx| view.open_connections(window, cx))
            .unwrap();
        cx.read(|cx| {
            let state = &root.read(cx).connections;
            let draft = state.forms[state.active.as_ref().unwrap()]
                .capture()
                .unwrap();
            assert_eq!(draft.profile.model_id, "local-test-fixture");
            assert_eq!(draft.profile.max_output_tokens, 4096);
            assert_eq!(draft.profile.model_output_limit, None);
            assert!(!state.presentation.dirty);
            assert!(
                state.presentation.notice.is_none(),
                "discard path {close_path}"
            );
        });
        assert_eq!(control.snapshot_bytes().unwrap(), before);
    }
}

#[gpui::test]
fn discarding_another_draft_keeps_the_selected_forms_notice(cx: &mut TestAppContext) {
    let (_dir, _control, window, root) = fixture(cx);
    let saved = save_fixture(window, &root, cx);
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    act(window, Intent::BrowseCatalog, cx);
    loaded(&root, cx);
    choose(&root, window, "deepseek-v4.1-flash", cx);
    let notice = cx.read(|cx| root.read(cx).connections.presentation.notice.clone());
    act(window, Intent::New, cx);
    let other = cx.read(|cx| root.read(cx).connections.active.clone().unwrap());
    assert_ne!(saved, other);
    act(window, Intent::DiscardCurrent, cx);
    cx.read(|cx| {
        let state = &root.read(cx).connections;
        assert_eq!(state.active.as_ref(), Some(&saved));
        assert_eq!(state.presentation.notice, notice);
        assert_eq!(
            state.forms[&saved]
                .capture()
                .unwrap()
                .profile
                .model_output_limit,
            Some(393216)
        );
    });
    act(window, Intent::Cancel, cx);
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    cx.read(|cx| assert!(root.read(cx).connections.presentation.notice.is_none()));
}

#[gpui::test]
fn catalog_failed_refresh_keeps_rows_but_source_change_clears_and_external_stays_anonymous(
    cx: &mut TestAppContext,
) {
    let (_dir, _control, window, root) = fixture(cx);
    let gateway = Gateway::new();
    edit(&root, cx, |f| {
        f.catalog_url = format!("{}/catalog?fixture=not-a-real-token", gateway.url);
        f.key = SYNTHETIC_KEY.into();
    });
    act(window, Intent::BrowseCatalog, cx);
    loaded(&root, cx);
    assert_eq!(catalog(&root, cx).total, 169);
    assert!(!gateway.receipts.lock().unwrap()[0].bearer);
    gateway.fail.store(true, Ordering::SeqCst);
    act(window, Intent::RefreshCatalog, cx);
    loaded(&root, cx);
    let failed = catalog(&root, cx);
    assert_eq!(failed.total, 169);
    assert!(failed.error.unwrap().contains("Previous results"));
    assert!(
        !format!(
            "{:?}",
            root.read_with(cx, |view, _| view.connections.presentation.clone())
        )
        .contains("not-a-real-token")
    );
    act(window, Intent::BrowseCatalog, cx);
    assert_eq!(gateway.count("get"), 2);
    act(window, Intent::RefreshCatalog, cx);
    loaded(&root, cx);
    assert_eq!(gateway.count("get"), 3);
    edit(&root, cx, |f| {
        f.catalog_url = format!("{}/other", gateway.url)
    });
    assert_eq!(catalog(&root, cx).total, 0);
    assert!(!catalog(&root, cx).loading);
    assert_eq!(gateway.count("post"), 0);
    act(window, Intent::Cancel, cx);
}

#[gpui::test]
fn catalog_cancel_and_tab_switch_fence_stalled_completion(cx: &mut TestAppContext) {
    let (_dir, _control, window, root) = fixture(cx);
    let gateway = Gateway::new();
    let saved = save_fixture(window, &root, cx);
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    edit(&root, cx, |f| {
        f.catalog_url = format!("{}/slow", gateway.url)
    });
    act(window, Intent::BrowseCatalog, cx);
    wait(cx, |_| gateway.stalled.load(Ordering::SeqCst) == 1);
    act(window, Intent::New, cx);
    wait(cx, |_| gateway.cancelled.load(Ordering::SeqCst) == 1);
    assert!(!catalog(&root, cx).opened);
    act(window, Intent::Select(saved), cx);
    assert!(!catalog(&root, cx).loading);
    assert_eq!(catalog(&root, cx).total, 0);
    edit(&root, cx, |f| {
        f.catalog_url = format!("{}/catalog", gateway.url)
    });
    act(window, Intent::BrowseCatalog, cx);
    loaded(&root, cx);
    assert_eq!(catalog(&root, cx).total, 169);
    act(window, Intent::Cancel, cx);
    assert_eq!(gateway.count("post"), 0);
}

#[gpui::test]
fn catalog_refresh_detecting_external_vault_revision_clears_stale_choices(cx: &mut TestAppContext) {
    let (_dir, control, window, root) = fixture(cx);
    let gateway = Gateway::new();
    edit(&root, cx, |f| {
        f.base_url = gateway.url.clone();
        f.catalog_url = format!("{}/catalog", gateway.url);
    });
    let saved = save_fixture(window, &root, cx);
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    act(window, Intent::BrowseCatalog, cx);
    loaded(&root, cx);
    let before = catalog(&root, cx);
    assert_eq!(before.total, 169);
    assert_eq!(gateway.count("get"), 1);
    let authority = control.authority();
    let current = authority.load_connections().unwrap();
    let mut changed = current.edit(&saved).unwrap();
    changed.name = "Changed outside the retained Settings form".into();
    authority.save_connection(&current, &changed).unwrap();
    act(window, Intent::RefreshCatalog, cx);
    let after = catalog(&root, cx);
    assert_eq!(after.total, 0);
    assert_ne!(after.generation, before.generation);
    assert!(after.error.is_some());
    assert!(!after.loading);
    assert_eq!(gateway.count("get"), 1);
    assert_eq!(gateway.count("post"), 0);
    act(
        window,
        Intent::ChooseCatalog {
            id: "fixture-model-169".into(),
            generation: before.generation,
        },
        cx,
    );
    cx.read(|cx| {
        assert_ne!(
            root.read(cx)
                .connections
                .presentation
                .active
                .as_ref()
                .unwrap()
                .fields
                .model,
            "fixture-model-169"
        )
    });
    act(window, Intent::Cancel, cx);
}

#[gpui::test]
fn native_settings_catalog_browse_refresh_choose_and_save_are_explicit_and_fixture_safe(
    cx: &mut TestAppContext,
) {
    let (_dir, control, window, root, _id) = native_mode_saved_fixture(cx);
    let gateway = Gateway::new();
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    edit(&root, cx, |f| {
        f.base_url = gateway.url.clone();
        f.catalog_url = format!("{}/catalog", gateway.url);
        f.key = SYNTHETIC_KEY.into();
    });
    assert_eq!(gateway.count("get"), 0);
    act(window, Intent::BrowseCatalog, cx);
    loaded(&root, cx);
    assert_eq!(gateway.count("get"), 1);
    assert_eq!(catalog(&root, cx).total, 169);
    choose(&root, window, "fixture-model-169", cx);
    act(window, Intent::RefreshCatalog, cx);
    loaded(&root, cx);
    assert_eq!(gateway.count("get"), 2);
    cx.read(|cx| {
        let view = root.read(cx);
        let draft = view.connections.forms[view.connections.active.as_ref().unwrap()]
            .capture()
            .unwrap();
        assert_eq!(draft.profile.model_id, "fixture-model-169");
        assert_eq!(draft.profile.model_output_limit, Some(8192));
        assert_eq!(
            draft.profile.input,
            ["text"],
            "catalog capability is not persisted as declared input"
        );
    });
    act(window, Intent::SaveAll, cx);
    assert_eq!(gateway.count("get"), 2, "Save never refreshes the catalog");
    assert_eq!(gateway.count("post"), 0);
    root.update(cx, |view, cx| {
        view.chat_models = Default::default();
        view.list_chat_models(cx);
    });
    cx.run_until_parked();
    assert_eq!(
        gateway.count("get"),
        2,
        "fixture-provenance chats never list their catalog passively"
    );
    let saved = control.authority().load_connections().unwrap();
    let model = saved
        .profiles()
        .iter()
        .find(|saved| saved.profile.model_id == "fixture-model-169")
        .unwrap();
    assert_eq!(model.profile.model_output_limit, Some(8192));
    assert!(
        !model.profile.supports_images(),
        "Native presentation never relaxes fixture provenance"
    );
}
