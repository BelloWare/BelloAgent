use super::*;
use crate::{
    provider::ToolCall,
    tools::{BlockingWorkExecutor, Capability, NativeTools},
};
use serde_json::json;

fn tools(root: &Path) -> NativeTools {
    NativeTools::new(root.into(), [], root.into(), [Capability::Bash])
        .unwrap()
        .with_shell_output(root.join("out"))
        .with_shell_environment(Environment {
            home: root.into(),
            path: "/usr/bin:/bin".into(),
            lang: "C".into(),
            temporary: root.into(),
        })
}
fn call(command: &str, timeout: u64) -> ToolCall {
    ToolCall {
        id: "bash".into(),
        name: "bash".into(),
        arguments: json!({"command":command,"timeout":timeout}),
    }
}
fn text(result: &Value) -> &str {
    result["content"][0]["text"].as_str().unwrap()
}

#[tokio::test]
async fn drains_both_pipes_and_preserves_exit_status() {
    let root = tempfile::tempdir().unwrap();
    let tools = tools(root.path());
    let result = tools
        .invoke(
            &call("printf hello; printf error >&2; exit 7", 2),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert!(text(&result).contains("hello"));
    assert!(text(&result).contains("error"));
    assert!(text(&result).contains("Exit code: 7"));
    assert_eq!(result["isError"], true);
    tools.join_processes().await.unwrap();
}
#[tokio::test]
async fn validates_before_creating_output_and_readonly_never_offers_bash() {
    let root = tempfile::tempdir().unwrap();
    let tools = tools(root.path());
    for arguments in [
        json!({"command":"printf hi","timeout":0}),
        json!({"command":"printf hi","extra":1}),
        json!({"command":""}),
        json!({"command":"x\u{0000}y"}),
        json!({"command":"x".repeat(262145)}),
    ] {
        let mut invalid = call("", 1);
        invalid.arguments = arguments;
        assert!(
            tools
                .invoke(&invalid, CancellationToken::new())
                .await
                .is_err()
        );
        assert!(!root.path().join("out").exists());
    }
    assert!(
        crate::runtime::TrustedReadOnlyTools::new_with_capabilities(
            root.path().into(),
            vec![],
            root.path().into(),
            [Capability::Bash]
        )
        .is_err()
    );
}
#[tokio::test]
async fn deadline_covers_inherited_pipes_after_leader_exit() {
    let root = tempfile::tempdir().unwrap();
    let tools = tools(root.path());
    let start = Instant::now();
    let result = tools
        .invoke(&call("sleep 4 & exit 0", 1), CancellationToken::new())
        .await
        .unwrap();
    assert!(start.elapsed() < Duration::from_millis(3500));
    assert_eq!(result["isError"], true);
    assert!(text(&result).contains("timed out after 1 seconds"));
    assert!(text(&result).contains("Exit code: 0"));
}
#[tokio::test]
async fn raw_preview_bounds_lossy_expansion_and_live_updates_stop_at_cap() {
    let root = tempfile::tempdir().unwrap();
    let updates = Arc::new(Mutex::new(Vec::new()));
    let captured = updates.clone();
    let tools = tools(root.path()).with_shell_update(Some(Arc::new(move |update| {
        captured.lock().unwrap().push(update)
    })));
    let result = tools.invoke(&call("for i in $(seq 1 14); do head -c 4096 /dev/zero | tr '\\0' '\\377'; sleep 0.07; done; exit 3", 10), CancellationToken::new()).await.unwrap();
    assert_eq!(result["isError"], true);
    assert!(text(&result).len() > 65_536);
    assert_eq!(
        text(&result)
            .chars()
            .take_while(|c| *c == '\u{fffd}')
            .count(),
        PREVIEW_BYTES
    );
    let updates = updates.lock().unwrap();
    assert!(updates.len() <= 9 && updates.len() >= 2);
    assert!(
        updates
            .windows(2)
            .all(|w| w[0].sequence < w[1].sequence && w[0].preview.len() < w[1].preview.len())
    );
    assert!(updates.iter().all(|u| u.preview.len() <= 3 * PREVIEW_BYTES));
}
#[tokio::test]
async fn cancellation_and_dropped_awaiter_hold_gate_through_owned_escalation() {
    let root = tempfile::tempdir().unwrap();
    let gate = Arc::new(tokio::sync::Mutex::new(()));
    let executor = BlockingWorkExecutor::new(1, 4);
    let tools = tools(root.path())
        .with_executor(executor.clone())
        .with_editing_gate(gate.clone());
    let token = CancellationToken::new();
    let running_tools = tools.clone();
    let running_token = token.clone();
    let task = tokio::spawn(async move {
        running_tools
            .invoke(
                &call(
                    "trap '' TERM; printf started; while :; do sleep 0.1; done",
                    30,
                ),
                running_token,
            )
            .await
    });
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if root.path().join("out").exists()
                && gate.try_lock().is_err()
                && executor.occupancy().active == 1
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    tokio::time::sleep(Duration::from_millis(80)).await;
    task.abort();
    let _ = task.await;
    assert!(
        tokio::time::timeout(Duration::from_millis(200), gate.lock())
            .await
            .is_err()
    );
    tokio::time::timeout(Duration::from_secs(4), tools.join_processes())
        .await
        .unwrap()
        .unwrap();
    assert!(gate.try_lock().is_ok());
    // The job registry signals after physical cleanup, just before the owning
    // executor decrements its slot. Require actual slot retirement by a
    // deadline rather than assuming both publications are simultaneous.
    tokio::time::timeout(Duration::from_secs(4), async {
        while executor.occupancy().active != 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the physically settled Bash worker must release its executor slot");
    assert_eq!(executor.occupancy().active, 0);
}
#[test]
fn prepares_source_schema_coercion() {
    let root = tempfile::tempdir().unwrap();
    let tools = tools(root.path());
    let mut call = call("", 1);
    call.arguments = json!({"command":12,"timeout":"2"});
    assert_eq!(
        tools.prepare_call(&call).arguments,
        json!({"command":"12","timeout":2})
    );
    call.arguments = json!({"command":true,"timeout":null});
    assert_eq!(
        tools.prepare_call(&call).arguments,
        json!({"command":"true"})
    );
}

#[tokio::test]
async fn drains_beyond_64mib_retention_without_unbounded_memory_or_reader_threads() {
    let root = tempfile::tempdir().unwrap();
    let tools = tools(root.path());
    let result = tools
        .invoke(
            &call("head -c 68157440 /dev/zero; printf err >&2", 10),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(result["isError"], false);
    assert!(text(&result).contains("Retained 67108864 of 68157443 bytes"));
    let private = fs::read_dir(root.path().join("out"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let file = private.join("output.log");
    assert_eq!(fs::metadata(&file).unwrap().len(), 67_108_864);
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        fs::metadata(private).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(file).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert!(!text(&result).contains("background process"));
}
#[tokio::test]
async fn split_utf8_is_decoded_from_raw_prefix_and_child_environment_is_allowlisted() {
    let root = tempfile::tempdir().unwrap();
    let tools = tools(root.path());
    let result = tools.invoke(&call("printf '\\303'; sleep 0.08; printf '\\251'; printf '\\n%s\\n%s' \"$HOME\" \"$TMPDIR\"; if read -r line; then exit 9; fi; test -z \"$BASH_ENV\"; test -z \"$AWS_SECRET_ACCESS_KEY\"", 3), CancellationToken::new()).await.unwrap();
    assert_eq!(result["isError"], false);
    assert!(text(&result).starts_with("é\n"));
    assert!(text(&result).contains(root.path().to_str().unwrap()));
}
#[test]
fn retention_failure_keeps_draining_count_and_reports_source_warning_as_error() {
    let root = tempfile::tempdir().unwrap();
    let mut output = Output::create(&root.path().join("out")).unwrap();
    output.file = File::open(&output.path).unwrap();
    output.consume(b"kept preview", None);
    output.consume(b" and more", None);
    assert_eq!(output.observed, 21);
    assert_eq!(output.retained, 0);
    let result = output.finish(Some(0), false, false, 1);
    assert_eq!(result["isError"], true);
    assert!(text(&result).contains("Warning: output could not be fully retained."));
}
#[tokio::test]
async fn normal_background_pipe_grace_is_bounded_and_does_not_claim_it_was_killed() {
    let root = tempfile::tempdir().unwrap();
    let tools = tools(root.path());
    let start = Instant::now();
    let result = tools
        .invoke(
            &call("sleep 2 & printf background", 5),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert!(start.elapsed() < Duration::from_millis(2400));
    assert_eq!(result["isError"], false);
    assert!(text(&result).contains(BACKGROUND_NOTE));
    assert!(text(&result).contains("Exit code: 0"));
    // The source deliberately permits background work. It is short-lived and
    // does not access any files; wait for the fixture's own lifetime to expire.
    tokio::time::sleep(Duration::from_millis(600)).await;
}
#[tokio::test]
async fn stopped_shell_never_chases_short_lived_escaped_process_group() {
    let root = tempfile::tempdir().unwrap();
    let tools = tools(root.path());
    let cancel = CancellationToken::new();
    let captured = tools.clone();
    let token = cancel.clone();
    // This predefined isolated fixture exits by itself. We never read a PID
    // file and signal a number that could have been recycled by the kernel.
    let running = tokio::spawn(async move {
        captured.invoke(&call("perl -MPOSIX -e 'setsid() or die; open(my $ready, q(>), q(escaped-started)); print $ready q(ready); close $ready; sleep 2; open(my $f, q(>), q(escaped-finished)); print $f q(done)' & printf started; sleep 20",10),token).await
    });
    tokio::time::timeout(Duration::from_secs(5), async {
        while !root.path().join("escaped-started").exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    cancel.cancel();
    assert!(matches!(
        tokio::time::timeout(Duration::from_secs(3), running)
            .await
            .unwrap()
            .unwrap(),
        Err(ToolError::Cancelled)
    ));
    tokio::time::timeout(Duration::from_secs(3), async {
        // The child creates the file before it publishes the complete marker.
        while !fs::read_to_string(root.path().join("escaped-finished"))
            .is_ok_and(|marker| marker == "done")
        {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        fs::read_to_string(root.path().join("escaped-finished")).unwrap(),
        "done"
    );
}

#[test]
fn deadline_uses_fresh_time_after_drain_even_if_leader_and_pipes_already_finished() {
    let root = tempfile::tempdir().unwrap();
    let advanced = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let clock = advanced.clone();
    let advance = advanced.clone();
    let mut request = Request::parse(&json!({"command":"printf drained","timeout":1})).unwrap();
    request.observe_exited_before_drain = true;
    request.clock = Some(Arc::new(move || {
        Instant::now()
            + if clock.load(Ordering::Acquire) {
                Duration::from_secs(2)
            } else {
                Duration::ZERO
            }
    }));
    let update: OnUpdate = Arc::new(move |update| {
        if update.sequence > 0 {
            advance.store(true, Ordering::Release);
        }
    });
    let result = run(
        request,
        root.path(),
        &root.path().join("out"),
        Environment {
            home: root.path().into(),
            path: "/usr/bin:/bin".into(),
            lang: "C".into(),
            temporary: root.path().into(),
        },
        &CancellationToken::new(),
        Some(update),
    )
    .unwrap()
    .result
    .unwrap();
    assert!(advanced.load(Ordering::Acquire));
    assert_eq!(result["isError"], true);
    assert!(text(&result).contains("timed out after 1 seconds"));
    assert!(text(&result).contains("drained\nExit code: 0"));
}
#[test]
fn bounded_logical_cleanup_keeps_owned_child_until_reaped() {
    let root = tempfile::tempdir().unwrap();
    // Start is separately cancelled only after spawning, so use the output
    // callback as the deterministic admission barrier.
    let token = CancellationToken::new();
    let stop = token.clone();
    let mut request =
        Request::parse(&json!({"command":"printf begun; sleep 10","timeout":20})).unwrap();
    request.ignore_exit_for_cleanup_test = true;
    let mut completion = run(
        request,
        root.path(),
        &root.path().join("out"),
        Environment {
            home: root.path().into(),
            path: "/usr/bin:/bin".into(),
            lang: "C".into(),
            temporary: root.path().into(),
        },
        &token,
        Some(Arc::new(move |_| stop.cancel())),
    )
    .unwrap();
    assert!(matches!(completion.result, Err(ToolError::Cancelled)));
    assert!(!completion.physically_settled());
    let owner = completion.reaper.as_mut().unwrap();
    assert!(
        owner.exited().unwrap(),
        "SIGKILL completed, but this fixture withheld exit settlement"
    );
    let id = owner.child.id();
    completion.reap();
    assert!(completion.physically_settled());
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    assert_eq!(
        unsafe {
            libc::waitid(
                libc::P_PID,
                id,
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        },
        -1
    );
    assert_eq!(
        io::Error::last_os_error().raw_os_error(),
        Some(libc::ECHILD)
    );
}
#[test]
fn auto_reap_policy_is_rejected_in_an_isolated_test_process() {
    const MARKER: &str = "BELLO_BASH_AUTOREAP_PROBE";
    if std::env::var_os(MARKER).is_some() {
        unsafe {
            libc::signal(libc::SIGCHLD, libc::SIG_IGN);
        }
        assert!(exclusive_reaping_policy().is_err());
        let root = tempfile::tempdir().unwrap();
        let result = run(
            Request::parse(&json!({"command":"printf forbidden > effect","timeout":1})).unwrap(),
            root.path(),
            &root.path().join("out"),
            Environment {
                home: root.path().into(),
                path: "/usr/bin:/bin".into(),
                lang: "C".into(),
                temporary: root.path().into(),
            },
            &CancellationToken::new(),
            None,
        );
        assert!(result.is_err());
        assert!(!root.path().join("out").exists());
        assert!(!root.path().join("effect").exists());
        return;
    }
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "tools::bash::tests::auto_reap_policy_is_rejected_in_an_isolated_test_process",
            "--nocapture",
        ])
        .env(MARKER, "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    let bound = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        if Instant::now() >= bound {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("isolated policy probe stalled");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn lost_wait_ownership_after_exit_observation_disables_all_further_group_signals() {
    let mut owner = ProcessOwner {
        child: Command::new("/bin/bash")
            .args(["--noprofile", "--norc", "-c", "exit 0"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .env_clear()
            .process_group(0)
            .spawn()
            .unwrap(),
        may_signal: true,
    };
    let bound = Instant::now() + Duration::from_secs(2);
    while !owner.exited().unwrap() {
        assert!(Instant::now() < bound);
        std::thread::yield_now();
    }
    // Deliberately model an unsupported competing reaper. signal must observe
    // ECHILD even though a previous waitid had already confirmed leader exit.
    owner.child.wait().unwrap();
    owner.signal(libc::SIGTERM);
    assert!(!owner.may_signal);
    owner.signal(libc::SIGKILL);
    assert!(!owner.may_signal);
}
