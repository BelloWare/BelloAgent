//! Barrier-based concurrency and durable ownership regressions.
use super::*;

fn pool_test_lock() -> &'static tokio::sync::Mutex<()> {
    static LOCK: std::sync::OnceLock<tokio::sync::Mutex<()>> = std::sync::OnceLock::new();
    LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

struct ConcurrentServer {
    url: String,
    calls: tokio::sync::mpsc::UnboundedReceiver<Request>,
    starts: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for ConcurrentServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl ConcurrentServer {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/mcp", listener.local_addr().unwrap());
        let (send, calls) = tokio::sync::mpsc::unbounded_channel();
        let starts = Arc::new(AtomicUsize::new(0));
        let count = starts.clone();
        let task = tokio::spawn(async move {
            loop {
                let request = Request::accept(&listener).await;
                match request.body["method"].as_str().unwrap() {
                    "initialize" => {
                        count.fetch_add(1, Ordering::SeqCst);
                        let body = json!({"jsonrpc":"2.0","id":request.body["id"],"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}}}}).to_string();
                        request
                            .raw(
                                200,
                                "application/json",
                                &body,
                                "Mcp-Session-Id: initial-session\r\n",
                            )
                            .await;
                    }
                    "notifications/initialized" => {
                        request.raw(202, "application/json", "", "").await
                    }
                    "tools/list" => {
                        request
                            .json(
                                json!({"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}),
                            )
                            .await
                    }
                    "tools/call" => {
                        send.send(request).unwrap();
                    }
                    other => panic!("unexpected {other}"),
                }
            }
        });
        Self {
            url,
            calls,
            starts,
            task,
        }
    }
    async fn next(&mut self) -> Request {
        timeout(DEADLINE, self.calls.recv()).await.unwrap().unwrap()
    }
}
fn start_call(
    manager: Arc<McpManager>,
    mode: &'static str,
) -> tokio::task::JoinHandle<McpResult<Performed>> {
    tokio::spawn(async move { invoke(&manager, mode).await })
}
async fn success(request: Request) {
    request
        .json(json!({"content":[{"type":"text","text":"retained"}]}))
        .await;
}

#[tokio::test]
async fn same_server_calls_overlap_and_initialize_once_with_sticky_unknown() {
    let mut server = ConcurrentServer::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    let first = start_call(manager.clone(), "first");
    let a = server.next().await;
    let second = start_call(manager.clone(), "second");
    let b = server.next().await; // Must arrive before either response is sent.
    assert_eq!(server.starts.load(Ordering::SeqCst), 1);
    assert_eq!(manager.status().pending_results, 2);
    assert!(manager.status().busy);
    drop(a); // An uncertain sibling cannot be erased by later success.
    assert!(first.await.unwrap().is_err());
    success(b).await;
    settle(second.await.unwrap().unwrap()).await;
    assert!(manager.status().outcome_unknown);
    assert_eq!(manager.status().pending_results, 0);
    assert!(!manager.status().busy);
    assert!(
        manager
            .acknowledge_unknown(&manager.status().unknown_id.unwrap(), true)
            .await
            .is_ok()
    );
}

#[tokio::test]
async fn completed_ticket_releases_read_admission_before_fair_writer_and_late_sibling() {
    use std::task::Poll;
    let mut server = ConcurrentServer::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    let first = start_call(manager.clone(), "first");
    let a = server.next().await;
    let mut writer = Box::pin(manager.wait_configuration_change(CancellationToken::new()));
    assert!(
        futures_util::future::poll_fn(|cx| Poll::Ready(writer.as_mut().poll(cx).is_pending()))
            .await
    );
    let second = start_call(manager.clone(), "second");
    success(a).await;
    let retained = timeout(DEADLINE, first).await.unwrap().unwrap().unwrap();
    assert!(timeout(DEADLINE, writer).await.unwrap().is_err());
    // The earlier ticket is deliberately still outstanding, but the writer
    // has drained and refused it, so the late sibling must dispatch.
    let b = server.next().await;
    success(b).await;
    let later = timeout(DEADLINE, second).await.unwrap().unwrap().unwrap();
    assert!(manager.begin_configuration_change().is_err());
    assert!(
        manager
            .perform_inspector(
                &json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{}}),
                false,
                CancellationToken::new(),
                || async { Ok(()) }
            )
            .await
            .is_err()
    );
    settle(retained).await;
    settle(later).await;
    assert!(manager.begin_configuration_change().is_ok());
}

#[tokio::test]
async fn configuration_drain_cancellation_does_not_cancel_active_call() {
    let mut server = ConcurrentServer::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    let call = start_call(manager.clone(), "first");
    let request = server.next().await;
    let cancel = CancellationToken::new();
    let token = cancel.clone();
    let copy = manager.clone();
    let writer = tokio::spawn(async move { copy.wait_configuration_change(token).await });
    cancel.cancel();
    assert!(timeout(DEADLINE, writer).await.unwrap().unwrap().is_err());
    success(request).await;
    settle(call.await.unwrap().unwrap()).await;
    assert!(!manager.status().outcome_unknown);
}

#[tokio::test]
async fn delayed_old_session_404_cannot_expire_a_rotated_session() {
    let mut server = ConcurrentServer::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    let first = start_call(manager.clone(), "rotate");
    let a = server.next().await;
    let second = start_call(manager.clone(), "late-404");
    let b = server.next().await;
    assert!(a.headers.contains("mcp-session-id: initial-session"));
    assert!(b.headers.contains("mcp-session-id: initial-session"));
    let body = json!({"jsonrpc":"2.0","id":a.body["id"],"result":{"content":[{"type":"text","text":"rotated"}]}}).to_string();
    a.raw(
        200,
        "application/json",
        &body,
        "Mcp-Session-Id: replacement-session\r\n",
    )
    .await;
    let retained = first.await.unwrap().unwrap();
    b.raw(404, "application/json", "{}", "").await;
    let retried = server.next().await;
    assert!(
        retried
            .headers
            .contains("mcp-session-id: replacement-session")
    );
    assert_eq!(server.starts.load(Ordering::SeqCst), 1);
    success(retried).await;
    settle(second.await.unwrap().unwrap()).await;
    settle(retained).await;
    assert!(!manager.status().outcome_unknown);
}

#[tokio::test]
async fn delayed_old_session_success_cannot_replace_a_newer_session() {
    let mut server = ConcurrentServer::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    let first = start_call(manager.clone(), "rotate");
    let a = server.next().await;
    let second = start_call(manager.clone(), "late-success");
    let b = server.next().await;
    let response = |request: &Request| {
        json!({"jsonrpc":"2.0","id":request.body["id"],"result":{"content":[{"type":"text","text":"ok"}]}}).to_string()
    };
    let body = response(&a);
    a.raw(
        200,
        "application/json",
        &body,
        "Mcp-Session-Id: replacement-session\r\n",
    )
    .await;
    settle(first.await.unwrap().unwrap()).await;
    let body = response(&b);
    b.raw(
        200,
        "application/json",
        &body,
        "Mcp-Session-Id: obsolete-session\r\n",
    )
    .await;
    settle(second.await.unwrap().unwrap()).await;
    let third = start_call(manager.clone(), "verify");
    let request = server.next().await;
    assert!(
        request
            .headers
            .contains("mcp-session-id: replacement-session")
    );
    success(request).await;
    settle(third.await.unwrap().unwrap()).await;
}

#[tokio::test]
async fn persistence_drop_keeps_four_physical_slots_and_pre_effect_wait_cancels() {
    let _pool_test = pool_test_lock().lock().await;
    let (started, mut arrivals) = tokio::sync::mpsc::unbounded_channel();
    let (release, wait) = std::sync::mpsc::channel();
    let wait = Arc::new(StdMutex::new(wait));
    let active = Arc::new(AtomicUsize::new(0));
    let maximum = Arc::new(AtomicUsize::new(0));
    let mut awaiting = vec![];
    for _ in 0..4 {
        let (started, wait, active, maximum) = (
            started.clone(),
            wait.clone(),
            active.clone(),
            maximum.clone(),
        );
        awaiting.push(tokio::spawn(async move {
            persistence(move || {
                let count = active.fetch_add(1, Ordering::SeqCst) + 1;
                maximum.fetch_max(count, Ordering::SeqCst);
                started.send(()).unwrap();
                wait.lock().unwrap().recv_timeout(DEADLINE).unwrap();
                active.fetch_sub(1, Ordering::SeqCst);
            })
            .await
        }));
    }
    for _ in 0..4 {
        timeout(DEADLINE, arrivals.recv()).await.unwrap().unwrap();
    }
    for task in &awaiting {
        task.abort();
    }
    for task in awaiting {
        assert!(task.await.unwrap_err().is_cancelled());
    }
    assert_eq!(active.load(Ordering::SeqCst), 4);
    assert_eq!(persistence_slots().available_permits(), 0);
    let token = CancellationToken::new();
    let entered = Arc::new(AtomicUsize::new(0));
    let copy = entered.clone();
    let cancelled = persistence_before(&token, move || {
        copy.fetch_add(1, Ordering::SeqCst);
    });
    tokio::pin!(cancelled);
    use std::task::Poll;
    assert!(
        futures_util::future::poll_fn(|cx| Poll::Ready(cancelled.as_mut().poll(cx).is_pending()))
            .await
    );
    token.cancel();
    assert!(timeout(DEADLINE, cancelled).await.unwrap().is_err());
    assert_eq!(entered.load(Ordering::SeqCst), 0);
    let fifth = tokio::spawn(async { persistence(|| 5).await });
    for _ in 0..4 {
        release.send(()).unwrap();
    }
    assert_eq!(timeout(DEADLINE, fifth).await.unwrap().unwrap().unwrap(), 5);
    timeout(DEADLINE, async {
        while active.load(Ordering::SeqCst) != 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert_eq!(maximum.load(Ordering::SeqCst), 4);
}

#[tokio::test]
async fn persistence_progresses_while_native_physical_workers_are_full() {
    let native = crate::tools::BlockingWorkExecutor::new(4, 64);
    let (started, mut arrivals) = tokio::sync::mpsc::unbounded_channel();
    let (release, wait) = std::sync::mpsc::channel();
    let wait = Arc::new(StdMutex::new(wait));
    let mut jobs = vec![];
    for _ in 0..4 {
        let (native, started, wait) = (native.clone(), started.clone(), wait.clone());
        jobs.push(tokio::spawn(async move {
            native
                .run(CancellationToken::new(), move |_| {
                    started.send(()).unwrap();
                    wait.lock().unwrap().recv_timeout(DEADLINE).unwrap();
                    Ok(())
                })
                .await
        }));
    }
    for _ in 0..4 {
        timeout(DEADLINE, arrivals.recv()).await.unwrap().unwrap();
    }
    let result = timeout(DEADLINE, persistence(|| 42)).await;
    for _ in 0..4 {
        release.send(()).unwrap();
    }
    for job in jobs {
        job.await.unwrap().unwrap();
    }
    assert_eq!(result.unwrap().unwrap(), 42);
}

#[tokio::test]
async fn dropped_ticket_never_waits_for_fsync_state_and_retains_writer_lease() {
    let server = ServerFixture::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    let performed = invoke(&manager, "ok").await.unwrap();
    let (started, ready) = std::sync::mpsc::channel();
    let (release, wait) = std::sync::mpsc::channel();
    let ledger = manager.ledger.clone();
    let physical = std::thread::spawn(move || ledger.hold_write_lock_for_test(started, wait));
    ready.recv_timeout(DEADLINE).unwrap();
    let (done, dropped) = std::sync::mpsc::channel();
    let cleanup = std::thread::spawn(move || {
        drop(performed);
        done.send(()).unwrap();
    });
    let fast = dropped.recv_timeout(Duration::from_millis(200));
    assert!(manager.status().outcome_unknown);
    release.send(()).unwrap();
    physical.join().unwrap();
    cleanup.join().unwrap();
    fast.expect("ticket Drop must not block on fsync state");
    timeout(DEADLINE, async {
        while manager.status().pending_results != 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert!(manager.status().outcome_unknown);
}

#[tokio::test]
async fn independent_servers_dispatch_before_either_returns() {
    let mut first_server = ConcurrentServer::start().await;
    let mut second_server = ConcurrentServer::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &first_server.url);
    let manager = fixture.manager();
    let reservation = manager.begin_configuration_change().unwrap();
    let loaded = fixture.config(json!({"servers":{
        "fixture":{"url":first_server.url,"allowedTools":["echo"]},
        "second":{"url":second_server.url,"allowedTools":["echo"]}
    }}));
    reservation
        .apply_configuration(loaded, CancellationToken::new())
        .await
        .unwrap();
    let first = start_call(manager.clone(), "first");
    let a = first_server.next().await;
    let copy = manager.clone();
    let second = tokio::spawn(async move {
        copy.perform(
            &json!({"action":"invoke","server":"second","tool":"echo","arguments":{}}),
            false,
            CancellationToken::new(),
            || async { Ok(()) },
        )
        .await
    });
    let b = second_server.next().await;
    assert_eq!(manager.status().pending_results, 2);
    success(b).await;
    settle(second.await.unwrap().unwrap()).await;
    assert!(!first.is_finished());
    success(a).await;
    settle(first.await.unwrap().unwrap()).await;
}

#[tokio::test]
async fn discovery_waiter_cancels_without_waiting_for_single_flight_initialization() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let fixture = Fixture::new(
        "http://127.0.0.1:9",
        &format!("http://{}/mcp", listener.local_addr().unwrap()),
    );
    let manager = fixture.manager();
    let copy = manager.clone();
    let first =
        tokio::spawn(async move { copy.list_tools("fixture", CancellationToken::new()).await });
    let hello = Request::accept(&listener).await;
    assert_eq!(hello.body["method"], "initialize");
    let cancel = CancellationToken::new();
    let copy = manager.clone();
    let token = cancel.clone();
    let second = tokio::spawn(async move { copy.list_tools("fixture", token).await });
    cancel.cancel();
    assert!(timeout(DEADLINE, second).await.unwrap().unwrap().is_err());
    // First discovery remains alive and owns initialization coordination.
    assert!(!first.is_finished());
    hello
        .json(json!({"protocolVersion":"2025-11-25","capabilities":{"tools":{}}}))
        .await;
    let initialized = Request::accept(&listener).await;
    assert_eq!(initialized.body["method"], "notifications/initialized");
    initialized.raw(202, "application/json", "", "").await;
    let list = Request::accept(&listener).await;
    assert_eq!(list.body["method"], "tools/list");
    list.json(json!({"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}))
        .await;
    assert!(timeout(DEADLINE, first).await.unwrap().unwrap().is_ok());
    assert!(!manager.status().outcome_unknown);
}

#[tokio::test]
async fn acknowledgment_refuses_live_receipts_after_network_admission_ends() {
    let mut server = ConcurrentServer::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    let first = start_call(manager.clone(), "unknown");
    let a = server.next().await;
    let second = start_call(manager.clone(), "retained");
    let b = server.next().await;
    drop(a);
    assert!(first.await.unwrap().is_err());
    success(b).await;
    let retained = second.await.unwrap().unwrap();
    assert!(!manager.status().busy);
    assert_eq!(manager.status().pending_results, 1);
    let unknown = manager.status().unknown_id.unwrap();
    assert!(
        manager
            .acknowledge_unknown(&unknown, true)
            .await
            .unwrap_err()
            .to_string()
            .contains("still running")
    );
    settle(retained).await;
    assert!(manager.status().outcome_unknown);
    assert!(manager.acknowledge_unknown(&unknown, true).await.is_err());
    manager
        .acknowledge_unknown(&manager.status().unknown_id.unwrap(), true)
        .await
        .unwrap();
}

#[tokio::test]
async fn abandoned_acknowledgment_keeps_exclusive_admission_while_pool_is_full() {
    let _pool_test = pool_test_lock().lock().await;
    use std::task::Poll;
    let server = ServerFixture::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    drop(manager.ledger.begin("fixture", "echo").unwrap());
    let unknown = manager.status().unknown_id.unwrap();
    let (started, mut arrivals) = tokio::sync::mpsc::unbounded_channel();
    let (release, wait) = std::sync::mpsc::channel();
    let wait = Arc::new(StdMutex::new(wait));
    let mut physical = vec![];
    for _ in 0..4 {
        let (started, wait) = (started.clone(), wait.clone());
        physical.push(tokio::spawn(async move {
            persistence(move || {
                started.send(()).unwrap();
                wait.lock().unwrap().recv_timeout(DEADLINE).unwrap();
            })
            .await
        }));
    }
    for _ in 0..4 {
        timeout(DEADLINE, arrivals.recv()).await.unwrap().unwrap();
    }
    let mut acknowledge = Box::pin(manager.acknowledge_unknown(&unknown, true));
    assert!(
        futures_util::future::poll_fn(|cx| Poll::Ready(acknowledge.as_mut().poll(cx).is_pending()))
            .await
    );
    drop(acknowledge);
    assert!(manager.status().busy);
    assert!(manager.begin_configuration_change().is_err());
    assert!(manager.status().outcome_unknown);
    for _ in 0..4 {
        release.send(()).unwrap();
    }
    for task in physical {
        task.await.unwrap().unwrap();
    }
    timeout(DEADLINE, async {
        while manager.status().busy {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert!(!manager.status().outcome_unknown);
    assert!(manager.begin_configuration_change().is_ok());
}

#[tokio::test]
async fn acknowledgment_waiting_for_fsync_never_blocks_current_thread_runtime() {
    use std::task::Poll;
    let server = ServerFixture::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    drop(manager.ledger.begin("fixture", "echo").unwrap());
    let expected = manager.status().unknown_id.unwrap();
    let (started, ready) = std::sync::mpsc::channel();
    let (release, wait) = std::sync::mpsc::channel();
    let ledger = manager.ledger.clone();
    let writer = std::thread::spawn(move || ledger.hold_write_lock_for_test(started, wait));
    ready.recv_timeout(DEADLINE).unwrap();
    let mut ack = Box::pin(manager.acknowledge_unknown(&expected, true));
    assert!(
        futures_util::future::poll_fn(|cx| Poll::Ready(ack.as_mut().poll(cx).is_pending())).await
    );
    assert!(
        timeout(Duration::from_millis(100), tokio::spawn(async { 1 }))
            .await
            .is_ok()
    );
    drop(ack);
    assert!(manager.status().busy);
    release.send(()).unwrap();
    writer.join().unwrap();
    timeout(DEADLINE, async {
        while manager.status().busy {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert!(!manager.status().outcome_unknown);
}

#[tokio::test]
async fn contended_ticket_cleanup_owns_writer_after_all_manager_owners_drop() {
    let _pool_test = pool_test_lock().lock().await;
    let server = ServerFixture::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    let performed = invoke(&manager, "ok").await.unwrap();
    let loaded = fixture.authority.load_mcp(&fixture.project).unwrap();
    let directory = fixture.workspace.lock().unwrap().state_directory();
    let (entered, mut starts) = tokio::sync::mpsc::unbounded_channel();
    let (release_pool, wait_pool) = std::sync::mpsc::channel();
    let wait_pool = Arc::new(StdMutex::new(wait_pool));
    let mut jobs = vec![];
    for _ in 0..4 {
        let (entered, wait_pool) = (entered.clone(), wait_pool.clone());
        jobs.push(tokio::spawn(async move {
            persistence(move || {
                entered.send(()).unwrap();
                wait_pool.lock().unwrap().recv_timeout(DEADLINE).unwrap();
            })
            .await
        }));
    }
    for _ in 0..4 {
        timeout(DEADLINE, starts.recv()).await.unwrap().unwrap();
    }
    let (started, ready) = std::sync::mpsc::channel();
    let (release, wait) = std::sync::mpsc::channel();
    let ledger = manager.ledger.clone();
    let writer = std::thread::spawn(move || ledger.hold_write_lock_for_test(started, wait));
    ready.recv_timeout(DEADLINE).unwrap();
    drop(performed); // Cannot acquire state, so cleanup queues behind pool.
    release.send(()).unwrap();
    writer.join().unwrap();
    let _directory_owner = fixture.into_directory();
    drop(manager);
    assert!(McpManager::new(loaded.clone(), &directory).is_err());
    for _ in 0..4 {
        release_pool.send(()).unwrap();
    }
    for job in jobs {
        job.await.unwrap().unwrap();
    }
    let reopened = timeout(DEADLINE, async {
        loop {
            if let Ok(manager) = McpManager::new(loaded.clone(), &directory) {
                break manager;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert!(reopened.status().outcome_unknown);
}

#[tokio::test]
async fn repeated_session_expiry_stops_after_one_retry_without_unknown() {
    let mut server = ConcurrentServer::start().await;
    let fixture = Fixture::new("http://127.0.0.1:9", &server.url);
    let manager = fixture.manager();
    let call = start_call(manager.clone(), "always-expired");
    server
        .next()
        .await
        .raw(404, "application/json", "{}", "")
        .await;
    server
        .next()
        .await
        .raw(404, "application/json", "{}", "")
        .await;
    let error = timeout(DEADLINE, call)
        .await
        .unwrap()
        .unwrap()
        .err()
        .unwrap();
    assert_eq!(error.code, "mcp_session_expired");
    assert!(error.not_executed);
    assert_eq!(server.starts.load(Ordering::SeqCst), 2);
    assert!(server.calls.try_recv().is_err());
    assert!(!manager.status().outcome_unknown);
    assert_eq!(manager.status().pending_results, 0);
}

#[cfg(unix)]
#[tokio::test]
async fn saved_mixed_batch_overlaps_then_commits_in_order_and_never_replays() {
    mixed_saved_batch(false, 0).await;
}
#[cfg(unix)]
#[tokio::test]
async fn stop_and_retirement_join_mixed_batch_with_completed_mcp_receipt() {
    mixed_saved_batch(true, 0).await;
}
#[cfg(unix)]
#[tokio::test]
async fn live_terminal_cards_do_not_hide_failed_checkpoint_or_replay_on_reopen() {
    for fault in [1, 2] {
        mixed_saved_batch(false, fault).await;
    }
}
#[cfg(unix)]
async fn mixed_saved_batch(stop: bool, fault: u8) {
    let _pool_test = if stop {
        Some(pool_test_lock().lock().await)
    } else {
        None
    };
    let mut server = ConcurrentServer::start().await;
    let provider = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut fixture = Fixture::new(
        &format!("http://{}", provider.local_addr().unwrap()),
        &server.url,
    );
    fixture.factory = fixture.factory.clone().with_mixed_mcp_test_tools();
    let (record, actor) = fixture.chat(ChatToolMode::Editing);
    fixture.submit(&record, &actor, "run a mixed concurrent batch");
    let request = Request::accept(&provider).await;
    request.provider(json!([
        {"type":"function_call","call_id":"remote","name":"mcp","arguments":json!({"action":"invoke","server":"fixture","tool":"echo","arguments":{}}).to_string()},
        {"type":"function_call","call_id":"native","name":"write","arguments":json!({"path":"native-marker","content":"native done"}).to_string()},
        {"type":"function_call","call_id":"shell","name":"bash","arguments":json!({"command":"while [ ! -f native-marker ]; do sleep 0.01; done; printf 'shell ready' > shell-marker; while [ ! -f release-bash ]; do sleep 0.01; done; printf 'shell done'","timeout":10}).to_string()}
    ])).await;
    let remote = server.next().await;
    timeout(DEADLINE, async {
        while std::fs::read_to_string(fixture.project.path.join("shell-marker"))
            .ok()
            .as_deref()
            != Some("shell ready")
        {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
    // Native and Bash have both progressed while the first MCP request is held.
    assert_eq!(
        std::fs::read_to_string(fixture.project.path.join("native-marker")).unwrap(),
        "native done"
    );
    // The native card must settle independently while MCP and Bash are held.
    timeout(DEADLINE, async {
        loop {
            if actor.snapshot().live_tools.iter().any(|view| {
                view.call_id == "native" && view.outcome == Some(ToolOutcome::Completed)
            }) {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert!(
        !actor
            .snapshot()
            .live_tools
            .iter()
            .any(|view| view.call_id == "remote" && view.outcome.is_some())
    );
    success(remote).await;
    let manager = fixture.manager();
    timeout(DEADLINE, async {
        while manager.status().busy {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert_eq!(manager.status().pending_results, 1);
    assert!(manager.begin_configuration_change().is_err());
    // Result normalization has completed, but the Ticket remains pending and no
    // canonical output or provider continuation exists until the sibling joins.
    timeout(DEADLINE, async {
        loop {
            let snapshot = actor.snapshot();
            if ["native", "remote"].iter().all(|call| {
                snapshot.live_tools.iter().any(|view| {
                    view.call_id == *call && view.outcome == Some(ToolOutcome::Completed)
                })
            }) {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let before_commit = actor.snapshot();
    assert!(
        before_commit
            .messages
            .iter()
            .all(|row| !matches!(&row.tool_record, Some(ToolRecord::Result(_))))
    );
    assert!(
        !before_commit
            .live_tools
            .iter()
            .any(|view| view.call_id == "shell" && view.outcome.is_some())
    );
    let mut premature = Box::pin(provider.accept());
    assert!(
        futures_util::future::poll_fn(|cx| std::task::Poll::Ready(
            premature.as_mut().poll(cx).is_pending()
        ))
        .await
    );
    drop(premature);
    assert_eq!(manager.status().pending_results, 1);
    if fault != 0 {
        actor.mcp_checkpoint_fault_for_test(fault);
        std::fs::write(fixture.project.path.join("release-bash"), b"release").unwrap();
        settled(&actor).await;
        assert!(manager.status().outcome_unknown);
        actor.mcp_checkpoint_fault_for_test(0);
        actor.retire_and_wait().await.unwrap();
        let saved = fixture
            .workspace
            .lock()
            .unwrap()
            .snapshot()
            .chats
            .into_iter()
            .find(|chat| chat.id == record.id)
            .unwrap();
        let reopened = fixture.factory.open_registered(&saved).unwrap();
        assert!(reopened.snapshot().live_tools.is_empty());
        let expected = if fault == 1 {
            ToolOutcome::Unknown
        } else {
            ToolOutcome::Completed
        };
        assert!(reopened.snapshot().messages.iter().any(|row| matches!(&row.tool_record, Some(ToolRecord::Result(result)) if result.call_id == "remote" && result.outcome == expected)));
        assert!(manager.status().outcome_unknown);
        assert!(server.calls.try_recv().is_err());
        assert!(
            timeout(Duration::from_millis(40), provider.accept())
                .await
                .is_err()
        );
        reopened.retire_and_wait().await.unwrap();
        return;
    }
    if stop {
        // Hold the physical persistence pool after all MCP/native effects and
        // before the remaining Bash call retires. Stop must still checkpoint
        // ordered rows, then retain its joined worker/receipt until settlement.
        let (entered, mut starts) = tokio::sync::mpsc::unbounded_channel();
        let (release, wait) = std::sync::mpsc::channel();
        let wait = Arc::new(StdMutex::new(wait));
        let mut physical = vec![];
        for _ in 0..4 {
            let (entered, wait) = (entered.clone(), wait.clone());
            physical.push(tokio::spawn(async move {
                persistence(move || {
                    entered.send(()).unwrap();
                    wait.lock().unwrap().recv_timeout(DEADLINE).unwrap();
                })
                .await
            }));
        }
        for _ in 0..4 {
            timeout(DEADLINE, starts.recv()).await.unwrap().unwrap();
        }
        actor.stop().unwrap();
        timeout(DEADLINE, async {
            while actor
                .snapshot()
                .messages
                .iter()
                .filter(|m| matches!(&m.tool_record, Some(ToolRecord::Result(_))))
                .count()
                != 3
            {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(manager.status().pending_results, 1);
        let mut retirement = Box::pin(actor.retire_and_wait());
        use std::task::Poll;
        assert!(
            futures_util::future::poll_fn(|cx| Poll::Ready(
                retirement.as_mut().poll(cx).is_pending()
            ))
            .await
        );
        for _ in 0..4 {
            release.send(()).unwrap();
        }
        for task in physical {
            task.await.unwrap().unwrap();
        }
        timeout(DEADLINE, retirement).await.unwrap().unwrap();
    } else {
        std::fs::write(fixture.project.path.join("release-bash"), b"release").unwrap();
        let continuation = Request::accept(&provider).await;
        let outputs: Vec<_> = continuation.body["input"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|v| v["type"] == "function_call_output")
            .collect();
        assert_eq!(
            outputs
                .iter()
                .map(|v| v["call_id"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["remote", "native", "shell"]
        );
        assert_eq!(manager.status().pending_results, 0);
        continuation.provider(json!([{"type":"message","content":[{"type":"output_text","text":"mixed complete"}]}])).await;
        settled(&actor).await;
        actor.retire_and_wait().await.unwrap();
    }
    assert!(!manager.status().outcome_unknown);
    assert_eq!(manager.status().pending_results, 0);
    let snapshot = actor.snapshot();
    let outcomes: Vec<_> = snapshot
        .messages
        .iter()
        .filter_map(|m| match &m.tool_record {
            Some(ToolRecord::Result(r)) => Some((r.call_id.as_str(), r.outcome)),
            _ => None,
        })
        .collect();
    assert_eq!(
        outcomes,
        vec![
            ("remote", ToolOutcome::Completed),
            ("native", ToolOutcome::Completed),
            (
                "shell",
                if stop {
                    ToolOutcome::Unknown
                } else {
                    ToolOutcome::Completed
                }
            )
        ]
    );
    let saved = fixture
        .workspace
        .lock()
        .unwrap()
        .snapshot()
        .chats
        .into_iter()
        .find(|chat| chat.id == record.id)
        .unwrap();
    let reopened = fixture.factory.open_registered(&saved).unwrap();
    assert_eq!(reopened.snapshot().messages.len(), snapshot.messages.len());
    assert!(server.calls.try_recv().is_err());
    assert!(
        timeout(Duration::from_millis(40), provider.accept())
            .await
            .is_err()
    );
    reopened.retire_and_wait().await.unwrap();
}
