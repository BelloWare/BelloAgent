//! All filesystem coverage is confined to fresh tempfile fixture trees. There
//! are no real project/home reads, credential discovery or model requests.
use bello_agent_core::{
    provider::ToolCall,
    tools::{BlockingWorkExecutor, Capability, NativeTools, Occupancy, ToolError, ToolResult},
};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    fs,
    path::Path,
    sync::{Arc, Condvar, Mutex},
    thread::ThreadId,
    time::{Duration, Instant},
};
use tempfile::TempDir;
use tokio_util::sync::CancellationToken;

fn tools(root: &Path) -> NativeTools {
    NativeTools::new(root.to_owned(), [], root.to_owned(), [Capability::Ls]).unwrap()
}
fn call(arguments: Value) -> ToolCall {
    ToolCall {
        id: "fixture-ls".into(),
        name: "ls".into(),
        arguments,
    }
}
async fn invoke(tools: &NativeTools, arguments: Value) -> Value {
    tools
        .invoke(&call(arguments), CancellationToken::new())
        .await
        .unwrap()
}
fn text(result: &Value) -> &str {
    result["content"][0]["text"].as_str().unwrap()
}
fn mkdir(path: impl AsRef<Path>) {
    fs::create_dir_all(path).unwrap();
}
fn touch(path: impl AsRef<Path>) {
    fs::write(path, []).unwrap();
}

#[tokio::test]
async fn exact_definition_and_explicit_allowlist() {
    let root = TempDir::new().unwrap();
    let enabled = tools(root.path());
    let definitions = enabled.definitions();
    assert_eq!(definitions.len(), 1);
    assert_eq!(definitions[0].name, "ls");
    assert_eq!(
        definitions[0].description,
        "List a directory, including hidden entries. Results are sorted and bounded."
    );
    assert_eq!(
        definitions[0].schema,
        json!({"type":"object","properties":{"path":{"type":"string"},"limit":{"type":"integer","minimum":1}},"required":[],"additionalProperties":false})
    );
    assert_eq!(enabled.capability_ids(), ["ls"]);
    let disabled = NativeTools::new(root.path().into(), [], root.path().into(), []).unwrap();
    assert!(disabled.definitions().is_empty());
    assert!(disabled.capability_ids().is_empty());
    let error = disabled
        .invoke(&call(json!({})), CancellationToken::new())
        .await
        .unwrap_err();
    assert_eq!(error.code(), Some("tool_unavailable"));
    assert_eq!(error.to_string(), "Tool ls not found");
    let mut other = call(json!({}));
    other.name = "read".into();
    assert_eq!(
        enabled
            .invoke(&other, CancellationToken::new())
            .await
            .unwrap_err()
            .to_string(),
        "Tool read not found"
    );
    assert_eq!(
        disabled.prepare_call(&call(json!({"path":true}))).arguments,
        json!({"path":true})
    );
}

#[tokio::test]
async fn ls_exact_result_hidden_entries_directories_and_unicode_order() {
    let root = TempDir::new().unwrap();
    for file in ["z.txt", ".hidden", "a.txt", "e\u{301}.txt"] {
        touch(root.path().join(file));
    }
    mkdir(root.path().join("folder"));
    let result = invoke(&tools(root.path()), json!({})).await;
    assert_eq!(
        result,
        json!({"content":[{"type":"text","text":".hidden\na.txt\nfolder/\nz.txt\ne\u{301}.txt"}],"isError":false})
    );
    assert!(result.get("stats").is_none());
    let empty = TempDir::new().unwrap();
    assert_eq!(text(&invoke(&tools(empty.path()), json!({})).await), "");
}

#[tokio::test]
async fn limits_match_source_including_zero_and_no_clamping() {
    let root = TempDir::new().unwrap();
    for i in 0..2001 {
        touch(root.path().join(format!("entry-{i:04}")));
    }
    let native = tools(root.path());
    let default = invoke(&native, json!({})).await;
    assert_eq!(text(&default).lines().count(), 201);
    assert!(text(&default).starts_with("entry-0000\n"));
    assert!(text(&default).ends_with("entry-0199\n[Truncated; 2001 entries]"));
    assert_eq!(
        text(&invoke(&native, json!({"limit":0})).await),
        "\n[Truncated; 2001 entries]"
    );
    let max = invoke(&native, json!({"limit":2000})).await;
    assert_eq!(text(&max).lines().count(), 2001);
    for limit in [
        json!(-1),
        json!(2001),
        json!(1.5),
        json!(true),
        json!("2"),
        json!([]),
        json!({}),
    ] {
        let error = native
            .invoke(&call(json!({"limit":limit})), CancellationToken::new())
            .await
            .unwrap_err();
        assert_eq!(error.code(), Some("invalid_range"));
        assert_eq!(error.to_string(), "Invalid numeric range");
    }
    assert_eq!(invoke(&native, json!({"limit":null})).await, default);
    assert_eq!(
        invoke(&native, json!({"limit":2.0})).await,
        invoke(&native, json!({"limit":2})).await
    );
}

#[tokio::test]
async fn native_argument_rejections_are_separate_from_preparation() {
    let root = TempDir::new().unwrap();
    let native = tools(root.path());
    for value in [Value::Null, json!([]), json!(false), json!("text")] {
        let error = native
            .invoke(&call(value), CancellationToken::new())
            .await
            .unwrap_err();
        assert_eq!(error.code(), Some("tool_arguments"));
        assert_eq!(error.to_string(), "Tool arguments must be an object");
    }
    assert_eq!(
        native
            .invoke(&call(json!({"unsupported":null})), CancellationToken::new())
            .await
            .unwrap_err()
            .to_string(),
        "Missing or unsupported tool arguments"
    );
    for path in [
        json!(""),
        json!(true),
        json!(3),
        json!([]),
        json!({}),
        json!("é".repeat(2049)),
    ] {
        let error = native
            .invoke(&call(json!({"path":path})), CancellationToken::new())
            .await
            .unwrap_err();
        assert_eq!(error.code(), Some("invalid_params"));
        assert_eq!(error.to_string(), "Invalid path");
    }
    assert_eq!(
        invoke(&native, json!({"path":null})).await,
        invoke(&native, json!({})).await
    );
}

#[tokio::test]
async fn prepared_ls_matches_the_applicable_pi_coercions_and_keeps_original() {
    let root = TempDir::new().unwrap();
    mkdir(root.path().join("true"));
    touch(root.path().join("true/file"));
    let native = tools(root.path());
    let raw = call(json!({"path":true,"limit":"\u{feff}0x10\u{a0}"}));
    assert_eq!(
        native.prepare_call(&raw).arguments,
        json!({"path":"true","limit":16})
    );
    assert_eq!(
        raw.arguments,
        json!({"path":true,"limit":"\u{feff}0x10\u{a0}"})
    );
    assert_eq!(
        text(
            &native
                .invoke_prepared(&raw, CancellationToken::new())
                .await
                .unwrap()
        ),
        "file"
    );
    assert_eq!(
        native
            .prepare_call(&call(json!({"path":null,"limit":null})))
            .arguments,
        json!({})
    );
    for (sent, expected) in [
        (json!(false), 0),
        (json!(true), 1),
        (json!("-0"), 0),
        (json!("2.0"), 2),
        (json!("1e3"), 1000),
        (json!("0o10"), 8),
        (json!("0B11"), 3),
        (json!("+1."), 1),
    ] {
        assert_eq!(
            native.prepare_call(&call(json!({"limit":sent}))).arguments,
            json!({"limit":expected})
        );
    }
    for sent in [
        "",
        " ",
        "\u{0085}2",
        "2.5",
        "0x",
        "-0x10",
        "0x1p3",
        "12px",
        "Infinity",
        "NaN",
        "1e9999",
        "1_0",
        ".",
        "+",
        "1e",
        "0b2",
    ] {
        assert_eq!(
            native.prepare_call(&call(json!({"limit":sent}))).arguments,
            json!({"limit":sent}),
            "{sent:?}"
        );
    }
    // The schema's minimum is not a second validator, even after preparation.
    assert_eq!(
        text(
            &native
                .invoke_prepared(&call(json!({"limit":false})), CancellationToken::new())
                .await
                .unwrap()
        ),
        "\n[Truncated; 1 entries]"
    );
    for (number, expected) in [
        (1e21, "1e+21"),
        (1e-7, "1e-7"),
        (0.000001, "0.000001"),
        (5.0, "5"),
        (-2.5, "-2.5"),
        (1.2345678901234568e20, "123456789012345680000"),
        (-0.0, "0"),
    ] {
        assert_eq!(
            native.prepare_call(&call(json!({"path":number}))).arguments,
            json!({"path":expected})
        );
    }
    assert_eq!(
        native
            .prepare_call(&call(json!({"limit":[],"path":{},"extra":null})))
            .arguments,
        json!({"limit":[],"path":{},"extra":null})
    );
}

#[tokio::test]
async fn roots_are_fallback_context_primary_wins_ambiguity_does_not_guess() {
    let root = TempDir::new().unwrap();
    let primary = root.path().join("primary");
    let second = root.path().join("second");
    let third = root.path().join("third");
    for base in [&primary, &second, &third] {
        mkdir(base);
    }
    let native = NativeTools::new(
        primary.clone(),
        [second.clone(), third.clone(), second.clone()],
        root.path().into(),
        [Capability::Ls],
    )
    .unwrap();
    mkdir(second.join("only"));
    touch(second.join("only/secondary"));
    assert_eq!(
        text(&invoke(&native, json!({"path":"only"})).await),
        "secondary",
        "duplicate roots are removed"
    );
    mkdir(primary.join("only"));
    touch(primary.join("only/primary"));
    assert_eq!(
        text(&invoke(&native, json!({"path":"only"})).await),
        "primary"
    );
    mkdir(second.join("ambiguous"));
    mkdir(third.join("ambiguous"));
    assert!(matches!(
        native
            .invoke(&call(json!({"path":"ambiguous"})), CancellationToken::new())
            .await,
        Err(ToolError::Io(_))
    ));
    touch(primary.join("not-directory"));
    mkdir(second.join("not-directory"));
    assert!(
        matches!(
            native
                .invoke(
                    &call(json!({"path":"not-directory"})),
                    CancellationToken::new()
                )
                .await,
            Err(ToolError::Io(_))
        ),
        "an existing primary file blocks secondary fallback"
    );
    assert!(matches!(
        native
            .invoke(&call(json!({"path":"missing"})), CancellationToken::new())
            .await,
        Err(ToolError::Io(_))
    ));
}

#[tokio::test]
async fn absolute_parent_and_explicit_home_paths_are_not_sandboxed() {
    let root = TempDir::new().unwrap();
    let primary = root.path().join("workspace");
    let outside = root.path().join("outside");
    let home = root.path().join("fixture-home");
    for path in [&primary, &outside, &home] {
        mkdir(path);
    }
    touch(outside.join("outside-file"));
    touch(home.join("home-file"));
    let native = NativeTools::new(primary, [], home.clone(), [Capability::Ls]).unwrap();
    assert_eq!(
        text(&invoke(&native, json!({"path":outside})).await),
        "outside-file"
    );
    assert_eq!(
        text(&invoke(&native, json!({"path":"../outside"})).await),
        "outside-file"
    );
    for path in ["~", "~/.", "~//.", "~/../fixture-home"] {
        assert_eq!(
            text(&invoke(&native, json!({"path":path})).await),
            "home-file"
        );
    }
    assert_eq!(
        native
            .invoke(
                &call(json!({"path":"~some-user"})),
                CancellationToken::new()
            )
            .await
            .unwrap_err()
            .code(),
        Some("tool_unavailable")
    );
}

#[cfg(unix)]
#[tokio::test]
async fn symlink_paths_can_leave_roots_and_parent_traversal_uses_the_real_parent() {
    use std::os::unix::fs::symlink;
    let root = TempDir::new().unwrap();
    let primary = root.path().join("workspace");
    let outside = root.path().join("outside");
    mkdir(&primary);
    mkdir(&outside);
    mkdir(primary.join("local"));
    mkdir(root.path().join("local"));
    touch(outside.join("target"));
    touch(primary.join("local/own"));
    touch(root.path().join("local/real-parent"));
    symlink(&outside, primary.join("link")).unwrap();
    let native = tools(&primary);
    assert_eq!(
        text(&invoke(&native, json!({"path":"link"})).await),
        "target"
    );
    assert_eq!(
        text(&invoke(&native, json!({"path":"link/../local"})).await),
        "real-parent"
    );
    assert_eq!(text(&invoke(&native, json!({})).await), "link\nlocal/");
    symlink("../missing-dir", primary.join("dangling")).unwrap();
    assert_eq!(
        text(&invoke(&native, json!({"path":"dangling/../outside"})).await),
        "target",
        "a missing symlink target still changes which parent '..' means"
    );
}

#[tokio::test]
async fn native_ls_retains_more_than_session_preview_threshold_without_stats() {
    let root = TempDir::new().unwrap();
    for i in 0..400 {
        touch(root.path().join(format!("{i:04}-{}", "x".repeat(180))));
    }
    let result = invoke(&tools(root.path()), json!({"limit":400})).await;
    assert!(text(&result).len() > 65536);
    assert_eq!(text(&result).lines().count(), 400);
    assert!(!text(&result).contains("Truncated"));
    assert!(result.get("stats").is_none());
}

#[tokio::test]
async fn cancellation_precedes_tool_or_argument_validation() {
    let root = TempDir::new().unwrap();
    let cancelled = CancellationToken::new();
    cancelled.cancel();
    let mut unavailable = call(json!([]));
    unavailable.name = "bash".into();
    assert!(matches!(
        tools(root.path()).invoke(&unavailable, cancelled).await,
        Err(ToolError::Cancelled)
    ));
}

#[derive(Default)]
struct BarrierState {
    released: bool,
    started: Vec<usize>,
    threads: HashSet<ThreadId>,
    active: usize,
    peak: usize,
}
#[derive(Default)]
struct WorkerBarrier {
    state: Mutex<BarrierState>,
    condition: Condvar,
}
impl WorkerBarrier {
    fn release(&self) {
        self.state.lock().unwrap().released = true;
        self.condition.notify_all();
    }
    fn enter(
        &self,
        index: usize,
        token: CancellationToken,
        cooperative: bool,
    ) -> ToolResult<usize> {
        let mut state = self.state.lock().unwrap();
        state.started.push(index);
        state.threads.insert(std::thread::current().id());
        state.active += 1;
        state.peak = state.peak.max(state.active);
        let deadline = Instant::now() + Duration::from_secs(10);
        let result = loop {
            if cooperative && token.is_cancelled() {
                break Err(ToolError::Cancelled);
            }
            if state.released {
                break Ok(index);
            }
            assert!(
                Instant::now() < deadline,
                "fixture barrier was not released"
            );
            state = self
                .condition
                .wait_timeout(state, Duration::from_millis(5))
                .unwrap()
                .0;
        };
        state.active -= 1;
        result
    }
    fn started(&self) -> Vec<usize> {
        self.state.lock().unwrap().started.clone()
    }
}
struct ReleaseOnDrop(Arc<WorkerBarrier>);
impl Drop for ReleaseOnDrop {
    fn drop(&mut self) {
        self.0.release();
    }
}
async fn eventually(condition: impl Fn() -> bool) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while !condition() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("fixture condition deadline");
}
fn held(
    workers: &BlockingWorkExecutor,
    barrier: &Arc<WorkerBarrier>,
    index: usize,
    token: CancellationToken,
    cooperative: bool,
) -> tokio::task::JoinHandle<ToolResult<usize>> {
    let workers = workers.clone();
    let barrier = barrier.clone();
    tokio::spawn(async move {
        workers
            .run(token, move |token| barrier.enter(index, token, cooperative))
            .await
    })
}

#[tokio::test]
async fn default_pool_bounds_four_os_workers_and_sixty_four_waiters() {
    let workers = BlockingWorkExecutor::default();
    assert_eq!(workers.limits(), (4, 64));
    assert_eq!(BlockingWorkExecutor::shared().limits(), (4, 64));
    let barrier = Arc::new(WorkerBarrier::default());
    let _release = ReleaseOnDrop(barrier.clone());
    let tasks: Vec<_> = (0..68)
        .map(|index| held(&workers, &barrier, index, CancellationToken::new(), true))
        .collect();
    eventually(|| {
        workers.occupancy()
            == Occupancy {
                active: 4,
                waiting: 64,
            }
            && barrier.started().len() == 4
    })
    .await;
    assert_eq!(barrier.state.lock().unwrap().threads.len(), 4);
    assert_eq!(barrier.state.lock().unwrap().peak, 4);
    let error = workers
        .run(CancellationToken::new(), |_| Ok(99))
        .await
        .unwrap_err();
    assert_eq!(error.code(), Some("tool_busy"));
    assert_eq!(
        error.to_string(),
        "File workers and their waiting queue are full. Retry after an active read or search finishes."
    );
    barrier.release();
    for (index, task) in tasks.into_iter().enumerate() {
        assert_eq!(task.await.unwrap().unwrap(), index);
    }
    eventually(|| workers.occupancy() == Occupancy::default()).await;
    assert_eq!(barrier.started().len(), 68);
    assert!(barrier.state.lock().unwrap().peak <= 4);
}

#[tokio::test]
async fn cancelled_waiter_is_removed_without_running_and_fifo_survives() {
    let workers = BlockingWorkExecutor::new(1, 2);
    let barrier = Arc::new(WorkerBarrier::default());
    let _release = ReleaseOnDrop(barrier.clone());
    let first = held(&workers, &barrier, 0, CancellationToken::new(), true);
    eventually(|| barrier.started() == [0]).await;
    let second = held(&workers, &barrier, 1, CancellationToken::new(), true);
    eventually(|| workers.occupancy().waiting == 1).await;
    let cancelled = CancellationToken::new();
    let third = held(&workers, &barrier, 2, cancelled.clone(), true);
    eventually(|| workers.occupancy().waiting == 2).await;
    cancelled.cancel();
    assert!(matches!(third.await.unwrap(), Err(ToolError::Cancelled)));
    assert_eq!(workers.occupancy().waiting, 1);
    assert_eq!(barrier.started(), [0]);
    let replacement = held(&workers, &barrier, 3, CancellationToken::new(), true);
    eventually(|| workers.occupancy().waiting == 2).await;
    barrier.release();
    for task in [first, second, replacement] {
        task.await.unwrap().unwrap();
    }
    assert_eq!(barrier.started(), [0, 1, 3]);
}

#[tokio::test]
async fn dropping_a_waiting_future_cancels_it_without_cancelling_the_parent() {
    let workers = BlockingWorkExecutor::new(1, 1);
    let barrier = Arc::new(WorkerBarrier::default());
    let _release = ReleaseOnDrop(barrier.clone());
    let token = CancellationToken::new();
    let first = held(&workers, &barrier, 0, token.clone(), true);
    eventually(|| barrier.started() == [0]).await;
    let waiter = held(&workers, &barrier, 1, token.clone(), true);
    eventually(|| workers.occupancy().waiting == 1).await;
    waiter.abort();
    assert!(waiter.await.unwrap_err().is_cancelled());
    eventually(|| workers.occupancy().waiting == 0).await;
    assert!(!token.is_cancelled());
    assert_eq!(barrier.started(), [0]);
    barrier.release();
    assert_eq!(first.await.unwrap().unwrap(), 0);
}

#[tokio::test]
async fn pre_cancelled_and_dropped_running_futures_do_not_execute_extra_work() {
    let workers = BlockingWorkExecutor::new(1, 1);
    let cancelled = CancellationToken::new();
    cancelled.cancel();
    let result = workers
        .run::<(), _>(cancelled, |_| panic!("cancelled work ran"))
        .await;
    assert!(matches!(result, Err(ToolError::Cancelled)));
    assert_eq!(workers.occupancy(), Occupancy::default());

    let barrier = Arc::new(WorkerBarrier::default());
    let _release = ReleaseOnDrop(barrier.clone());
    let running = held(&workers, &barrier, 0, CancellationToken::new(), false);
    eventually(|| barrier.started() == [0]).await;
    running.abort();
    assert!(running.await.unwrap_err().is_cancelled());
    let neighbor = held(&workers, &barrier, 1, CancellationToken::new(), true);
    eventually(|| workers.occupancy().waiting == 1).await;
    assert_eq!(
        workers.occupancy(),
        Occupancy {
            active: 1,
            waiting: 1
        }
    );
    assert_eq!(barrier.started(), [0]);
    barrier.release();
    assert_eq!(neighbor.await.unwrap().unwrap(), 1);
    eventually(|| workers.occupancy() == Occupancy::default()).await;
}

#[tokio::test]
async fn running_cooperative_cancellation_releases_its_slot_for_a_neighbor() {
    let workers = BlockingWorkExecutor::new(1, 1);
    let barrier = Arc::new(WorkerBarrier::default());
    let _release = ReleaseOnDrop(barrier.clone());
    let cancelled = CancellationToken::new();
    let first = held(&workers, &barrier, 0, cancelled.clone(), true);
    eventually(|| barrier.started() == [0]).await;
    let next_workers = workers.clone();
    let next = tokio::spawn(async move {
        next_workers
            .run(CancellationToken::new(), |_| Ok("neighbor"))
            .await
    });
    eventually(|| workers.occupancy().waiting == 1).await;
    cancelled.cancel();
    assert!(matches!(first.await.unwrap(), Err(ToolError::Cancelled)));
    assert_eq!(next.await.unwrap().unwrap(), "neighbor");
}

#[tokio::test]
async fn uninterruptible_cancellation_retains_worker_slot_until_return() {
    let workers = BlockingWorkExecutor::new(1, 1);
    let barrier = Arc::new(WorkerBarrier::default());
    let _release = ReleaseOnDrop(barrier.clone());
    let cancelled = CancellationToken::new();
    let first = held(&workers, &barrier, 0, cancelled.clone(), false);
    eventually(|| barrier.started() == [0]).await;
    let neighbor = held(&workers, &barrier, 1, CancellationToken::new(), true);
    eventually(|| workers.occupancy().waiting == 1).await;
    cancelled.cancel();
    assert_eq!(
        workers.occupancy(),
        Occupancy {
            active: 1,
            waiting: 1
        }
    );
    assert_eq!(barrier.started(), [0]);
    assert!(!first.is_finished());
    barrier.release();
    assert!(matches!(first.await.unwrap(), Err(ToolError::Cancelled)));
    assert_eq!(neighbor.await.unwrap().unwrap(), 1);
}

#[tokio::test]
async fn twenty_native_ls_jobs_keep_results_and_definitions_available_while_queued() {
    let root = TempDir::new().unwrap();
    let workers = BlockingWorkExecutor::default();
    let barrier = Arc::new(WorkerBarrier::default());
    let _release = ReleaseOnDrop(barrier.clone());
    let blockers: Vec<_> = (0..4)
        .map(|i| held(&workers, &barrier, i, CancellationToken::new(), true))
        .collect();
    eventually(|| barrier.started().len() == 4).await;
    let native = tools(root.path()).with_executor(workers.clone());
    let mut jobs = Vec::new();
    for i in 0..20 {
        mkdir(root.path().join(format!("job-{i}")));
        touch(root.path().join(format!("job-{i}/file-{i}")));
        let tool = native.clone();
        jobs.push(tokio::spawn(async move {
            invoke(&tool, json!({"path":format!("job-{i}")})).await
        }));
    }
    eventually(|| workers.occupancy().waiting == 20).await;
    assert_eq!(native.definitions()[0].name, "ls");
    assert_eq!(native.capability_ids(), ["ls"]);
    barrier.release();
    for blocker in blockers {
        blocker.await.unwrap().unwrap();
    }
    for (i, job) in jobs.into_iter().enumerate() {
        assert_eq!(text(&job.await.unwrap()), format!("file-{i}"));
    }
}

#[tokio::test]
async fn worker_panic_does_not_leak_capacity_or_prevent_later_jobs() {
    let workers = BlockingWorkExecutor::new(1, 0);
    let failure = workers
        .run::<(), _>(CancellationToken::new(), |_| {
            panic!("synthetic fixture panic")
        })
        .await
        .unwrap_err();
    assert_eq!(failure.code(), Some("tool_worker"));
    eventually(|| workers.occupancy() == Occupancy::default()).await;
    assert_eq!(
        workers
            .run(CancellationToken::new(), |_| Ok(12))
            .await
            .unwrap(),
        12
    );
}

#[cfg(not(target_os = "macos"))]
#[test]
fn unsupported_find_is_rejected_before_any_provider_offer() {
    let root = TempDir::new().unwrap();
    for capabilities in [
        vec![Capability::Find],
        vec![Capability::Ls, Capability::Find],
    ] {
        let error = NativeTools::new(root.path().into(), [], root.path().into(), capabilities)
            .err()
            .expect("unsupported Find must fail construction");
        assert_eq!(error.code(), Some("tool_unavailable"));
        assert_eq!(
            error.to_string(),
            "Find requires the macOS Foundation implementation"
        );
    }
    assert!(
        bello_agent_core::runtime::TrustedReadOnlyTools::new_with_capabilities(
            root.path().into(),
            vec![],
            root.path().into(),
            [Capability::Find]
        )
        .is_err()
    );
    assert!(
        bello_agent_core::runtime::TrustedReadOnlyTools::new(
            root.path().into(),
            vec![],
            root.path().into()
        )
        .is_ok()
    );
}

#[cfg(not(target_os = "macos"))]
#[test]
fn unsupported_grep_is_rejected_before_any_provider_offer() {
    let root = TempDir::new().unwrap();
    for capabilities in [
        vec![Capability::Grep],
        vec![Capability::Ls, Capability::Find, Capability::Grep],
    ] {
        let error = NativeTools::new(root.path().into(), [], root.path().into(), capabilities)
            .err()
            .expect("unsupported Grep must fail construction");
        assert_eq!(error.code(), Some("tool_unavailable"));
        assert_eq!(
            error.to_string(),
            "Grep requires the macOS Foundation implementation"
        );
    }
    assert!(
        bello_agent_core::runtime::TrustedReadOnlyTools::new_with_capabilities(
            root.path().into(),
            vec![],
            root.path().into(),
            [Capability::Grep]
        )
        .is_err()
    );
}
