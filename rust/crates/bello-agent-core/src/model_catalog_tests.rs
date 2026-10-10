use super::*;
use serde_json::json;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
};

fn profile() -> Profile {
    serde_json::from_value(json!({"id":"fixture","api":"openai-responses","providerId":"litellm","modelId":"old","baseUrl":"http://127.0.0.1:3333","contextWindow":32000,"maxOutputTokens":4096})).unwrap()
}
fn decode(value: Value) -> Result<Vec<ModelDescriptor>, CatalogError> {
    parse(&serde_json::to_vec(&value).unwrap())
}
#[test]
fn bundled_is_the_single_checked_in_six_row_catalog() {
    let models = bundled().unwrap();
    assert_eq!(
        models,
        parse(include_bytes!(
            "../../../../catalogs/bello-agent.models.json"
        ))
        .unwrap()
    );
    assert_eq!(
        models.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
        [
            "deepseek-v4.1-flash",
            "glm-5.3-flash",
            "glm-5.3",
            "kimi-k3",
            "gemini-3.8-flash",
            "auto-router"
        ]
    );
    assert!(
        models
            .iter()
            .all(|m| !m.deprecated && !m.description.is_empty())
    );
}
#[test]
fn versions_aliases_and_stable_explicit_order_match_swift() {
    let rows = json!([
        {"id":"unordered"}, {"id":"max","order":i64::MAX},
        {"id":"second","order":2,"context":100,"maxOutput":99},
        {"id":" first ","order":-1,"context_window":200,"max_output_tokens":150},
        {"id":"tied","order":2,"contextWindow":300,"maxOutputTokens":100},
        {"id":"last"}
    ]);
    let expected = decode(rows.clone()).unwrap();
    assert_eq!(
        expected.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
        ["first", "second", "tied", "max", "unordered", "last"]
    );
    for root in [
        json!({"models":rows}),
        json!({"version":1,"models":rows}),
        json!({"version":1.0,"models":rows}),
    ] {
        assert_eq!(decode(root).unwrap(), expected);
    }
    assert_eq!(expected[0].context_window, Some(200));
    assert_eq!(expected[0].max_output_tokens, Some(150));
    assert_eq!(expected[1].context_window, Some(100));
    assert_eq!(expected[2].context_window, Some(300));
}
#[test]
fn parser_bounds_bytes_rows_trimmed_unique_ids_and_utf8_text() {
    assert_eq!(
        parse(&vec![b' '; MAX_CATALOG_BYTES + 1]),
        Err(CatalogError::Oversized)
    );
    let rows: Vec<_> = (0..MAX_CATALOG_MODELS)
        .map(|n| json!({"id":n.to_string()}))
        .collect();
    assert_eq!(decode(json!(rows)).unwrap().len(), MAX_CATALOG_MODELS);
    let rows: Vec<_> = (0..=MAX_CATALOG_MODELS)
        .map(|n| json!({"id":n.to_string()}))
        .collect();
    assert_eq!(decode(json!(rows)), Err(CatalogError::Oversized));
    assert!(decode(json!([{"id":"界".repeat(66)}])).is_ok());
    for bad in [
        json!([{"id":"界".repeat(67)}]),
        json!([{"id":"x"},{"id":" x "}]),
        json!([{"id":" \n "}]),
        json!([{"id":"bad\u{0}id"}]),
        json!([{"name":"missing"}]),
    ] {
        assert_eq!(decode(bad), Err(CatalogError::Malformed));
    }
    let text = "🦀".repeat(1025);
    let rows =
        decode(json!([{"id":"bounded","name":format!(" {text} "),"description":text}])).unwrap();
    assert_eq!(rows[0].name.len(), 2048);
    assert_eq!(rows[0].description.len(), 2048);
    assert!(!rows[0].description.contains('�'));
}
#[test]
fn strict_boolean_integral_and_array_metadata_fail_closed_without_echo() {
    for bad in [
        json!({"version":true,"models":[]}),
        json!({"version":2,"models":[]}),
        json!({"version":1.5,"models":[]}),
        json!({"models":[null]}),
        json!({"data":[]}),
    ] {
        assert_eq!(decode(bad), Err(CatalogError::Malformed));
    }
    for (field, values) in [
        (
            "contextWindow",
            vec![
                json!(true),
                json!(1),
                json!(10_000_001),
                json!(1.5),
                json!("3000"),
                Value::Null,
            ],
        ),
        (
            "maxOutputTokens",
            vec![json!(false), json!(0), json!(1_000_001), json!(-1)],
        ),
        (
            "order",
            vec![json!(true), json!(0.5), json!(1e100), json!(-1e100)],
        ),
        ("deprecated", vec![json!(1), json!("true"), Value::Null]),
        ("mini", vec![json!(0), json!("false"), Value::Null]),
        (
            "reasoning",
            vec![json!(true), json!({}), json!(["low", 2]), Value::Null],
        ),
        (
            "input",
            vec![json!(true), json!("image"), json!([1]), Value::Null],
        ),
    ] {
        for value in values {
            let mut row = json!({"id":"private-secret-model"});
            row[field] = value;
            let error = decode(json!([row])).unwrap_err();
            assert_eq!(error, CatalogError::Malformed);
            assert!(!format!("{error} {error:?}").contains("private-secret"));
        }
    }
    let valid =
        decode(json!([{"id":"x","contextWindow":2.0,"maxOutputTokens":1.0,"order":1.0}])).unwrap();
    assert_eq!(valid[0].context_window, Some(2));
}
#[test]
fn reasoning_absence_empty_and_known_inputs_are_distinct_and_stable() {
    let rows = decode(json!([
        {"id":"unknown"}, {"id":"empty","reasoning":[],"input":[]},
        {"id":"known","reasoning":{"efforts":["max","high","off","low","low","bogus","default","profile-default"]},"input":["image","audio","text","image"]}
    ])).unwrap();
    assert_eq!(rows[0].reasoning, None);
    assert_eq!(rows[0].input, None);
    assert_eq!(rows[1].reasoning, Some(vec![]));
    assert_eq!(rows[1].input, Some(vec![]));
    assert_eq!(
        rows[2].reasoning,
        Some(vec![
            "off".into(),
            "low".into(),
            "high".into(),
            "max".into()
        ])
    );
    assert_eq!(rows[2].input, Some(vec!["text".into(), "image".into()]));
}
#[test]
fn applying_never_grants_inputs_or_increases_budget_and_resets_incompatible_effort() {
    let mut p = profile();
    p.reasoning = true;
    p.thinking_level = "high".into();
    p.output_cap = Some(128);
    p.headers.insert("X-Private".into(), "unchanged".into());
    let before = p.clone();
    let small = decode(json!([{"id":"small","contextWindow":2048,"maxOutputTokens":8192,"reasoning":[],"input":["image"]}])).unwrap().remove(0);
    small.applying(&mut p);
    assert_eq!(p.model_id, "small");
    assert_eq!(p.context_window, 2048);
    assert_eq!(p.model_output_limit, Some(8192));
    assert_eq!(p.max_output_tokens, 2047);
    assert_eq!(p.thinking_level, "default");
    assert!(!p.reasoning);
    assert_eq!(p.input, before.input);
    assert!(!p.supports_images());
    assert_eq!(p.base_url, before.base_url);
    assert_eq!(p.id, before.id);
    assert_eq!(p.headers, before.headers);
    assert_eq!(p.output_cap, Some(128));
    let wide = decode(json!([{"id":"wide","contextWindow":1_000_000,"maxOutputTokens":800_000,"reasoning":["low"]}])).unwrap().remove(0);
    wide.applying(&mut p);
    assert_eq!(p.max_output_tokens, 2047);
    assert!(p.reasoning);
    p.thinking_level = "low".into();
    wide.applying(&mut p);
    assert_eq!(p.thinking_level, "low");
    let unknown = decode(json!([{"id":"unknown"}])).unwrap().remove(0);
    unknown.applying(&mut p);
    assert_eq!(p.thinking_level, "low");
    assert_eq!(p.model_output_limit, None);
}
#[test]
fn url_validation_and_origin_use_scheme_host_effective_port_only() {
    for bad in [
        "http://remote.example/catalog",
        "https://x:0/catalog",
        "https://user:secret@x/catalog",
        "https://@x/catalog",
        "https://x/#fragment",
        "https://x/a b",
        "https://x/a\nb",
        "https://x\\private",
        "http:127.0.0.1",
    ] {
        assert_eq!(CatalogUrl::parse(bad), Err(CatalogError::Url), "{bad}");
    }
    let query =
        CatalogUrl::parse(" https://CATALOG.example/catalog?access_token=private-secret ").unwrap();
    assert!(!format!("{query:?}").contains("private-secret"));
    assert_eq!(
        query.as_str(),
        "https://CATALOG.example/catalog?access_token=private-secret"
    );
    let mut p = profile();
    p.base_url = "https://gateway.example/v1".into();
    for same in [
        "https://GATEWAY.example/catalog",
        "https://gateway.example:443/catalog?x=1",
    ] {
        assert!(CatalogUrl::parse(same).unwrap().uses_gateway_credential(&p));
    }
    for external in [
        "https://gateway.example:444/catalog",
        "https://catalog.example/catalog",
        "http://localhost/catalog",
    ] {
        assert!(
            !CatalogUrl::parse(external)
                .unwrap()
                .uses_gateway_credential(&p)
        );
    }
    p.api = "anthropic-messages".into();
    assert!(
        !CatalogUrl::parse("https://gateway.example/catalog")
            .unwrap()
            .uses_gateway_credential(&p)
    );
    assert!(
        CatalogUrl::parse("http://127.0.0.1/catalog")
            .unwrap()
            .numeric_loopback()
    );
    assert!(
        CatalogUrl::parse("http://[::1]/catalog")
            .unwrap()
            .numeric_loopback()
    );
    assert!(
        !CatalogUrl::parse("http://localhost/catalog")
            .unwrap()
            .numeric_loopback()
    );
}
async fn read_request(socket: &mut TcpStream) -> String {
    let mut bytes = vec![];
    loop {
        let mut chunk = [0; 1024];
        let count = socket.read(&mut chunk).await.unwrap();
        assert!(count > 0);
        bytes.extend_from_slice(&chunk[..count]);
        if bytes.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
        assert!(bytes.len() < 32_768);
    }
    String::from_utf8(bytes).unwrap()
}
async fn server(
    response: Vec<u8>,
) -> (
    CatalogUrl,
    oneshot::Receiver<String>,
    tokio::task::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = CatalogUrl::parse(&format!(
        "http://{}/catalog?fixture=1",
        listener.local_addr().unwrap()
    ))
    .unwrap();
    let (send, receive) = oneshot::channel();
    let task = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let request = read_request(&mut socket).await;
        let _ = send.send(request);
        let _ = socket.write_all(&response).await;
    });
    (url, receive, task)
}
fn response(body: &[u8]) -> Vec<u8> {
    let mut value = format!(
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    value.extend_from_slice(body);
    value
}
#[tokio::test]
async fn fixture_transport_get_headers_are_minimal_and_anonymous_or_synthetic_only() {
    for authenticated in [false, true] {
        let (url, received, task) = server(response(br#"[{"id":"catalog-only"}]"#)).await;
        let key = authenticated.then(|| {
            Credential::new(crate::project_authority::connections::SYNTHETIC_KEY.into()).unwrap()
        });
        let rows = CatalogRequest::fixture(None, url, key)
            .unwrap()
            .load(CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(rows[0].id, "catalog-only");
        let request = received.await.unwrap().to_ascii_lowercase();
        assert!(request.starts_with("get /catalog?fixture=1 http/1.1\r\n"));
        assert!(request.contains("accept: application/json\r\n"));
        assert!(request.contains("cache-control: no-cache\r\n"));
        assert_eq!(
            request.contains("authorization: bearer synthetic-project-fixture-only\r\n"),
            authenticated
        );
        for forbidden in [
            "cookie:",
            "x-api-key:",
            "x-fixture:",
            "/models",
            "x-session-id:",
            "x-turn-id:",
        ] {
            assert!(!request.contains(forbidden), "{forbidden}");
        }
        task.await.unwrap();
    }
}
#[tokio::test]
async fn redirect_is_not_followed_and_http_errors_do_not_echo_body_or_url() {
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let redirect = format!(
        "HTTP/1.1 302 Found\r\nLocation: http://{}/private-secret\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        target.local_addr().unwrap()
    );
    let (url, _, task) = server(redirect.into_bytes()).await;
    let error = CatalogRequest::fixture(
        None,
        url,
        Some(Credential::new("synthetic-project-fixture-only".into()).unwrap()),
    )
    .unwrap()
    .load(CancellationToken::new())
    .await
    .unwrap_err();
    assert_eq!(error, CatalogError::Redirected);
    assert!(
        tokio::time::timeout(Duration::from_millis(40), target.accept())
            .await
            .is_err()
    );
    task.await.unwrap();
    let (url, _, task) = server(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 14\r\nConnection: close\r\n\r\nprivate-secret".to_vec()).await;
    let error = CatalogRequest::fixture(None, url, None)
        .unwrap()
        .load(CancellationToken::new())
        .await
        .unwrap_err();
    assert_eq!(error, CatalogError::Http);
    assert!(!format!("{error} {error:?}").contains("private-secret"));
    task.await.unwrap();
}
#[tokio::test]
async fn declared_and_streamed_oversized_bodies_fail_without_fallback() {
    let declared = format!(
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        MAX_CATALOG_BYTES + 1
    )
    .into_bytes();
    let mut streamed = b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".to_vec();
    streamed.extend(vec![b' '; MAX_CATALOG_BYTES + 1]);
    for reply in [declared, streamed] {
        let (url, _, task) = server(reply).await;
        assert_eq!(
            CatalogRequest::fixture(None, url, None)
                .unwrap()
                .load(CancellationToken::new())
                .await,
            Err(CatalogError::Oversized)
        );
        task.await.unwrap();
    }
    let (url, _, task) = server(response(br#"{"data":[{"id":"provider-model"}]}"#)).await;
    assert_eq!(
        CatalogRequest::fixture(None, url, None)
            .unwrap()
            .load(CancellationToken::new())
            .await,
        Err(CatalogError::Malformed)
    );
    task.await.unwrap();
}
#[tokio::test]
async fn cancellation_before_request_and_during_stream_closes_owned_transfer() {
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert_eq!(
        CatalogRequest::bundled(None).load(cancel).await,
        Err(CatalogError::Cancelled)
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = CatalogUrl::parse(&format!(
        "http://{}/catalog",
        listener.local_addr().unwrap()
    ))
    .unwrap();
    let cancel = CancellationToken::new();
    let copied = cancel.clone();
    let task = tokio::spawn(async move {
        CatalogRequest::fixture(None, url, None)
            .unwrap()
            .load(copied)
            .await
    });
    let (mut socket, _) = listener.accept().await.unwrap();
    read_request(&mut socket).await;
    socket
        .write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n[\r\n")
        .await
        .unwrap();
    cancel.cancel();
    assert_eq!(task.await.unwrap(), Err(CatalogError::Cancelled));
    let mut byte = [0];
    let read = tokio::time::timeout(Duration::from_secs(2), socket.read(&mut byte))
        .await
        .unwrap();
    assert!(matches!(read, Ok(0) | Err(_)));
}
#[tokio::test]
async fn idle_and_total_deadlines_are_separate_and_fixed_by_default() {
    assert_eq!(FetchLimits::default().idle, Duration::from_secs(8));
    assert_eq!(FetchLimits::default().total, Duration::from_secs(120));
    for trickle in [false, true] {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = CatalogUrl::parse(&format!(
            "http://{}/catalog",
            listener.local_addr().unwrap()
        ))
        .unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            read_request(&mut socket).await;
            if trickle {
                socket
                    .write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
                    .await
                    .unwrap();
                loop {
                    if socket.write_all(b"1\r\n \r\n").await.is_err() {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            } else {
                std::future::pending::<()>().await;
            }
        });
        let limits = FetchLimits {
            idle: Duration::from_millis(70),
            total: Duration::from_millis(160),
        };
        let binding = CatalogBinding::new(
            Arc::new(CatalogCache::default()),
            Some(&url),
            &profile(),
            "",
        );
        let request = CatalogRequest::native(None, url, None, binding.clone());
        assert_eq!(
            request.load_inner(CancellationToken::new(), limits).await,
            Err(CatalogError::TimedOut)
        );
        assert!(
            !binding.needs_load(),
            "idle and total timeouts both start the failure retry window"
        );
        server.abort();
    }
}
#[test]
fn blocking_load_works_without_a_tokio_reactor() {
    assert_eq!(
        CatalogRequest::bundled(None)
            .load_blocking(CancellationToken::new())
            .unwrap(),
        bundled().unwrap()
    );
}

#[test]
fn catalog_client_ignores_process_proxy_in_bounded_subprocess() {
    const CHILD: &str = "BELLO_CATALOG_PROXY_CHILD";
    if std::env::var_os(CHILD).is_some() {
        assert!(!std::env::var("HTTP_PROXY").unwrap().is_empty());
        assert_eq!(std::env::var("NO_PROXY").unwrap(), "");
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let (url, received, server) =
                    server(response(br#"[{"id":"direct-catalog-only"}]"#)).await;
                let key =
                    Credential::new(crate::project_authority::connections::SYNTHETIC_KEY.into())
                        .unwrap();
                let request = CatalogRequest::fixture(None, url, Some(key)).unwrap();
                let models = tokio::time::timeout(
                    Duration::from_secs(3),
                    request.load(CancellationToken::new()),
                )
                .await
                .expect("the catalog must reach its explicit loopback endpoint directly")
                .unwrap();
                assert_eq!(models[0].id, "direct-catalog-only");
                let request = received.await.unwrap().to_ascii_lowercase();
                assert!(request.starts_with("get /catalog?fixture=1 http/1.1\r\n"));
                assert!(
                    request.contains("authorization: bearer synthetic-project-fixture-only\r\n")
                );
                server.await.unwrap();
            });
        return;
    }

    // Process-local environment, so this test never changes another test's
    // transport environment. Empty NO_PROXY makes a missing no_proxy() visible.
    let proxy = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    proxy.set_nonblocking(true).unwrap();
    let proxy_url = format!("http://{}", proxy.local_addr().unwrap());
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--exact",
            "model_catalog::tests::catalog_client_ignores_process_proxy_in_bounded_subprocess",
            "--nocapture",
        ])
        .env(CHILD, "1")
        .env("NO_PROXY", "")
        .env("no_proxy", "")
        .env_remove("REQUEST_METHOD")
        .env_remove("request_method")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
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
                "catalog proxy child timed out: {:?}",
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
    assert!(matches!(proxy.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock));
}

#[tokio::test]
async fn dropping_or_aborting_load_closes_transfer_without_cancelling_token() {
    // Exercise both dropping the caller's future directly and aborting a task
    // polling it. Neither path calls CancellationToken::cancel; AbortFetch::Drop
    // must own teardown of the inner worker on the separate shared runtime.
    for abort_task in [false, true] {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = CatalogUrl::parse(&format!(
            "http://{}/catalog",
            listener.local_addr().unwrap()
        ))
        .unwrap();
        let cancel = CancellationToken::new();
        let request = CatalogRequest::fixture(None, url, None).unwrap();
        let mut load = Box::pin(request.load(cancel.clone()));
        let mut task = None;
        let (mut socket, _) = if abort_task {
            task = Some(tokio::spawn(load));
            tokio::time::timeout(Duration::from_secs(3), listener.accept())
                .await
                .expect("catalog request never reached the loopback fixture")
                .unwrap()
        } else {
            // Poll the future until its separately owned worker reaches HTTP.
            let mut socket = tokio::time::timeout(Duration::from_secs(3), async {
                tokio::select! {
                    accepted = listener.accept() => accepted.unwrap(),
                    result = &mut load => panic!("catalog finished before fixture accepted: {result:?}"),
                }
            })
            .await
            .expect("catalog request never reached the loopback fixture");
            // The uncompleted transfer owns a live socket before the load
            // future is dropped; reaching EOF must not depend on idle timeout.
            let request = tokio::time::timeout(Duration::from_secs(3), read_request(&mut socket.0))
                .await
                .unwrap();
            assert!(request.starts_with("GET /catalog HTTP/1.1\r\n"));
            drop(load);
            socket
        };
        if let Some(task) = task {
            let request = tokio::time::timeout(Duration::from_secs(3), read_request(&mut socket))
                .await
                .unwrap();
            assert!(request.starts_with("GET /catalog HTTP/1.1\r\n"));
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n[\r\n")
                .await
                .unwrap();
            task.abort();
            assert!(task.await.unwrap_err().is_cancelled());
        }
        assert!(!cancel.is_cancelled());
        let mut byte = [0];
        let closed = tokio::time::timeout(Duration::from_secs(2), socket.read(&mut byte))
            .await
            .expect("dropping load left its network worker detached");
        assert!(matches!(closed, Ok(0) | Err(_)));
        assert!(!cancel.is_cancelled());
        assert!(
            tokio::time::timeout(Duration::from_millis(40), listener.accept())
                .await
                .is_err(),
            "an aborted catalog operation must not reconnect"
        );
    }
}

#[test]
fn explicit_http_loopback_names_match_swift_and_fixture_requests_reject_other_keys() {
    for url in [
        "http://127.1/catalog",
        "http://127.0.0.2/catalog",
        "http://2130706433/catalog",
        "http://[0:0:0:0:0:0:0:1]/catalog",
    ] {
        assert_eq!(CatalogUrl::parse(url), Err(CatalogError::Url), "{url}");
    }
    let key = Credential::new("fake-nonfixture-key".into()).unwrap();
    assert!(matches!(
        CatalogRequest::fixture(
            None,
            CatalogUrl::parse("http://127.0.0.1/catalog").unwrap(),
            Some(key)
        ),
        Err(CatalogError::FixtureOnly)
    ));
}

#[test]
fn native_cache_fences_old_publication_keys_and_authorities_without_exposing_secrets() {
    let cache = Arc::new(CatalogCache::default());
    let profile = profile();
    let url = CatalogUrl::parse("http://127.0.0.1:3333/catalog?fake=1").unwrap();
    let binding = CatalogBinding::new(cache.clone(), Some(&url), &profile, "fake-key-one");
    assert!(binding.needs_load());
    let old = binding.begin().unwrap();
    let current = binding.begin().unwrap();
    assert!(
        !binding.needs_load(),
        "a listing in flight is joined, not repeated"
    );
    let rows = decode(json!([{"id":"old","input":["image"]}])).unwrap();
    old.finish(Some(&Ok(rows.clone())));
    assert!(binding.descriptor("old").is_none());
    drop(old);
    assert!(
        !binding.needs_load(),
        "a superseded listing does not end the newest"
    );
    current.finish(Some(&Ok(rows.clone())));
    assert!(binding.descriptor("old").is_some());
    assert!(
        !binding.needs_load(),
        "a fresh list is reused for five minutes"
    );
    // A failed refresh keeps the last good list; a cancelled one records nothing.
    let failed = binding.begin().unwrap();
    failed.finish(Some(&Err(CatalogError::Http)));
    assert!(binding.descriptor("old").is_some());
    assert!(
        !binding.needs_load(),
        "a failure is not retried for thirty seconds"
    );
    drop(binding.begin().unwrap());
    assert!(!binding.needs_load());
    assert!(binding.descriptor("old").is_some());
    let changed_key = CatalogBinding::new(cache, Some(&url), &profile, "fake-key-two");
    assert!(changed_key.descriptor("old").is_none());
    let foreign = CatalogBinding::new(
        Arc::new(CatalogCache::default()),
        Some(&url),
        &profile,
        "fake-key-one",
    );
    assert!(foreign.descriptor("old").is_none());
}
