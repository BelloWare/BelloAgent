//! The pseudo-terminal and the registry with `/bin/sh` scripts in temporary
//! directories: spawn, output in order, resize, exit codes, terminate, no
//! inherited descriptors, no leaked processes, backpressure and the input
//! cap. Nothing here touches a real project or the user's shell.
use super::pty::{self, PseudoTerminal, TerminalLaunch};
use super::session::{self, Ending, Launcher, TerminalRegistry};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

fn sh(directory: &Path, script: &str) -> TerminalLaunch {
    TerminalLaunch {
        executable: "/bin/sh".into(),
        arguments: vec!["sh".into(), "-c".into(), script.into()],
        environment: vec![
            ("PATH".into(), "/usr/bin:/bin".into()),
            ("TERM".into(), "xterm-256color".into()),
        ],
        directory: directory.to_owned(),
    }
}

/// Everything the program writes until it exits, and its exit code.
fn collect(terminal: &mut PseudoTerminal, limit: Duration) -> (Vec<u8>, Option<i32>, Vec<String>) {
    let deadline = Instant::now() + limit;
    let (mut bytes, mut notices) = (Vec::new(), Vec::new());
    loop {
        let output = terminal.take_output();
        assert!(output.bytes.len() <= pty::DELIVERY_BYTES);
        bytes.extend(&output.bytes);
        notices.extend(output.notices);
        if output.exit.is_some() {
            return (bytes, output.exit, notices);
        }
        if Instant::now() > deadline {
            return (bytes, None, notices);
        }
        if !output.more {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}
fn alive(pid: libc::pid_t) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}
fn wait_gone(pid: libc::pid_t, limit: Duration) -> bool {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        if !alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    !alive(pid)
}
fn canonical(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap()
}

#[test]
fn runs_in_the_directory_and_reports_its_exit() {
    let dir = tempfile::tempdir().unwrap();
    let mut terminal =
        PseudoTerminal::start(&sh(dir.path(), "printf 'hello\\n'; pwd -P; exit 3"), 80, 24)
            .unwrap();
    let pid = terminal.process_id();
    let (bytes, exit, _) = collect(&mut terminal, Duration::from_secs(10));
    let out = text(&bytes);
    assert_eq!(exit, Some(3), "{out}");
    // The terminal's own line discipline turns \n into \r\n.
    assert!(out.starts_with("hello\r\n"), "{out:?}");
    assert!(
        out.contains(&canonical(dir.path()).display().to_string()),
        "{out:?}"
    );
    assert!(!terminal.running());
    assert!(!alive(pid), "the child was reaped");
    // Input after the end goes nowhere.
    terminal.write(b"ignored\n");
    terminal.resize(10, 10);
}

#[test]
fn a_signal_exit_counts_as_128_plus_the_signal() {
    let dir = tempfile::tempdir().unwrap();
    let mut terminal = PseudoTerminal::start(&sh(dir.path(), "kill -TERM $$"), 80, 24).unwrap();
    let (_, exit, _) = collect(&mut terminal, Duration::from_secs(10));
    assert_eq!(exit, Some(128 + libc::SIGTERM));
}

#[test]
fn a_missing_program_exits_127() {
    let dir = tempfile::tempdir().unwrap();
    let mut launch = sh(dir.path(), "");
    launch.executable = dir.path().join("no-such-shell");
    let mut terminal = PseudoTerminal::start(&launch, 80, 24).unwrap();
    let (_, exit, _) = collect(&mut terminal, Duration::from_secs(10));
    assert_eq!(exit, Some(127));
}

#[test]
fn resize_reaches_the_program_and_input_is_echoed() {
    let dir = tempfile::tempdir().unwrap();
    let mut terminal = PseudoTerminal::start(
        &sh(
            dir.path(),
            "stty size; read line; echo \"got $line\"; stty size",
        ),
        80,
        24,
    )
    .unwrap();
    // Wait for the first size before changing it.
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut seen = Vec::new();
    while !text(&seen).contains("24 80") && Instant::now() < deadline {
        seen.extend(terminal.take_output().bytes);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(text(&seen).contains("24 80"), "{:?}", text(&seen));
    terminal.resize(50, 7);
    terminal.write(b"abc\r");
    let (bytes, exit, _) = collect(&mut terminal, Duration::from_secs(10));
    let out = text(&bytes);
    assert_eq!(exit, Some(0));
    assert!(out.contains("abc"), "echoed: {out:?}");
    assert!(out.contains("got abc"), "{out:?}");
    assert!(out.contains("7 50"), "{out:?}");
}

#[test]
fn the_child_inherits_no_descriptors_but_its_terminal() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("held");
    std::fs::write(&file, "x").unwrap();
    let path = std::ffi::CString::new(file.to_str().unwrap()).unwrap();
    // Not close-on-exec, as Foundation's pipes were not.
    let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDONLY) };
    assert!(fd > 2);
    let script = format!("if [ -e /dev/fd/{fd} ]; then echo leaked; else echo closed; fi");
    let mut terminal = PseudoTerminal::start(&sh(dir.path(), &script), 80, 24).unwrap();
    let (bytes, exit, _) = collect(&mut terminal, Duration::from_secs(10));
    unsafe { libc::close(fd) };
    assert_eq!(exit, Some(0));
    assert!(text(&bytes).contains("closed"), "{:?}", text(&bytes));
}

#[test]
fn terminate_hangs_up_then_kills_a_program_that_ignores_it() {
    let dir = tempfile::tempdir().unwrap();
    let mut polite = PseudoTerminal::start(&sh(dir.path(), "read x"), 80, 24).unwrap();
    let mut stubborn = PseudoTerminal::start(
        &sh(dir.path(), "trap '' HUP; echo ready; read x; read y"),
        80,
        24,
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut seen = Vec::new();
    while !text(&seen).contains("ready") && Instant::now() < deadline {
        seen.extend(stubborn.take_output().bytes);
        std::thread::sleep(Duration::from_millis(5));
    }
    let started = Instant::now();
    polite.terminate();
    stubborn.terminate();
    polite.terminate(); // twice is harmless
    let (_, exit, _) = collect(&mut polite, Duration::from_secs(10));
    assert_eq!(exit, Some(128 + libc::SIGHUP));
    let (_, exit, _) = collect(&mut stubborn, Duration::from_secs(10));
    assert_eq!(exit, Some(128 + libc::SIGKILL));
    assert!(started.elapsed() >= pty::KILL_DELAY - Duration::from_millis(100));
}

#[test]
fn dropping_a_running_terminal_leaves_no_process() {
    let dir = tempfile::tempdir().unwrap();
    let terminal =
        PseudoTerminal::start(&sh(dir.path(), "trap '' HUP; read x; read y"), 80, 24).unwrap();
    let pid = terminal.process_id();
    assert!(alive(pid));
    drop(terminal);
    assert!(
        wait_gone(pid, Duration::from_secs(5)),
        "pid {pid} still running"
    );
}

#[test]
fn output_before_exit_arrives_whole_and_in_order() {
    let dir = tempfile::tempdir().unwrap();
    // More than the 1 MiB buffer, so the reader must wait for room.
    let script = "i=0; while [ $i -lt 30000 ]; do echo \"line $i abcdefghijklmnopqrstuvwxyz\"; i=$((i+1)); done";
    let mut terminal = PseudoTerminal::start(&sh(dir.path(), script), 80, 24).unwrap();
    let (bytes, exit, notices) = collect(&mut terminal, Duration::from_secs(60));
    assert_eq!(exit, Some(0));
    assert!(notices.is_empty(), "{notices:?}");
    let out = text(&bytes);
    let lines: Vec<&str> = out.split("\r\n").filter(|l| !l.is_empty()).collect();
    assert_eq!(lines.len(), 30000);
    for (i, line) in lines.iter().enumerate() {
        assert_eq!(*line, format!("line {i} abcdefghijklmnopqrstuvwxyz"));
    }
}

#[test]
fn a_descendant_holding_the_terminal_does_not_hold_up_the_exit() {
    let dir = tempfile::tempdir().unwrap();
    let mut terminal =
        PseudoTerminal::start(&sh(dir.path(), "(sleep 1; echo late) & echo early"), 80, 24)
            .unwrap();
    let started = Instant::now();
    let (bytes, exit, notices) = collect(&mut terminal, Duration::from_secs(10));
    assert_eq!(exit, Some(0));
    assert!(text(&bytes).contains("early"));
    assert!(
        started.elapsed() < Duration::from_millis(900),
        "{:?}",
        started.elapsed()
    );
    assert!(notices.is_empty(), "{notices:?}");
}

#[test]
fn a_paste_the_queue_cannot_take_is_refused_whole() {
    let dir = tempfile::tempdir().unwrap();
    // The program never reads, so written input stays queued.
    let mut terminal =
        PseudoTerminal::start(&sh(dir.path(), "stty -icanon; sleep 30"), 80, 24).unwrap();
    std::thread::sleep(Duration::from_millis(200));
    let chunk = vec![b'a'; 300_000];
    for _ in 0..10 {
        terminal.write(&chunk);
    }
    assert!(terminal.buffered_input_bytes() <= pty::INPUT_BYTE_LIMIT);
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut notices = Vec::new();
    while notices.is_empty() && Instant::now() < deadline {
        notices.extend(terminal.take_output().notices);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        notices.first().map(String::as_str),
        Some(pty::INPUT_FULL_NOTICE)
    );
    let pid = terminal.process_id();
    drop(terminal);
    assert!(wait_gone(pid, Duration::from_secs(5)));
}

#[test]
fn changed_wakes_an_async_owner() {
    let dir = tempfile::tempdir().unwrap();
    let mut terminal =
        PseudoTerminal::start(&sh(dir.path(), "sleep 0.2; echo hi"), 80, 24).unwrap();
    let waiter = terminal.waiter();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .unwrap();
    let mut seen = Vec::new();
    let mut exit = None;
    runtime.block_on(async {
        while exit.is_none() {
            tokio::time::timeout(Duration::from_secs(10), waiter.changed())
                .await
                .expect("woken");
            loop {
                let output = terminal.take_output();
                seen.extend(output.bytes);
                exit = exit.or(output.exit);
                if !output.more {
                    break;
                }
            }
        }
    });
    assert_eq!(exit, Some(0));
    assert!(text(&seen).contains("hi"));
}

#[test]
fn the_login_shell_environment_follows_swift() {
    let env = [
        ("SHELL", "/bin/bash"),
        ("HOME", "/Users/test"),
        ("OPENAI_API_KEY", "secret"),
        ("LITELLM_MASTER_KEY", "secret"),
        ("LITELLM", "x"),
        ("MY_API_KEY_FILE", "kept"),
        ("TERM", "dumb"),
    ]
    .map(|(k, v)| (OsString::from(k), OsString::from(v)));
    let launch = pty::login_shell(Path::new("/tmp/project"), env, "0.1.122");
    assert_eq!(launch.executable, PathBuf::from("/bin/bash"));
    assert_eq!(
        launch.arguments,
        vec![OsString::from("-bash"), OsString::from("-l")]
    );
    assert_eq!(launch.directory, PathBuf::from("/tmp/project"));
    let get = |key: &str| {
        launch
            .environment
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.to_string_lossy().into_owned())
    };
    assert_eq!(get("TERM").as_deref(), Some("xterm-256color"));
    assert_eq!(get("COLORTERM").as_deref(), Some("truecolor"));
    assert_eq!(get("LANG").as_deref(), Some("en_US.UTF-8"));
    assert_eq!(get("TERM_PROGRAM").as_deref(), Some("BelloAgent"));
    assert_eq!(get("TERM_PROGRAM_VERSION").as_deref(), Some("0.1.122"));
    assert_eq!(get("BELLO_AGENT").as_deref(), Some("1"));
    assert_eq!(get("HOME").as_deref(), Some("/Users/test"));
    assert_eq!(get("MY_API_KEY_FILE").as_deref(), Some("kept"));
    for removed in ["OPENAI_API_KEY", "LITELLM_MASTER_KEY", "LITELLM"] {
        assert_eq!(get(removed), None, "{removed}");
    }
    // An unset or empty SHELL is zsh; a LANG of the user's own is kept.
    let launch = pty::login_shell(
        Path::new("/"),
        [
            ("SHELL".into(), "".into()),
            ("LANG".into(), "fr_FR.UTF-8".into()),
        ],
        "1",
    );
    assert_eq!(launch.executable, PathBuf::from("/bin/zsh"));
    assert_eq!(launch.arguments[0], OsString::from("-zsh"));
    assert!(
        launch
            .environment
            .contains(&("LANG".into(), "fr_FR.UTF-8".into()))
    );
}

#[test]
fn the_shell_sees_that_environment() {
    let dir = tempfile::tempdir().unwrap();
    let env = [
        ("PATH", "/usr/bin:/bin"),
        ("SHELL", "/bin/sh"),
        ("ANTHROPIC_API_KEY", "secret"),
    ]
    .map(|(k, v)| (OsString::from(k), OsString::from(v)));
    let mut launch = pty::login_shell(dir.path(), env, "9.9");
    // The login shell's own argv, with a script so the test ends.
    launch.arguments = vec![
        "sh".into(),
        "-c".into(),
        "echo \"[$TERM|$BELLO_AGENT|$TERM_PROGRAM_VERSION|${ANTHROPIC_API_KEY-unset}]\"".into(),
    ];
    let mut terminal = PseudoTerminal::start(&launch, 80, 24).unwrap();
    let (bytes, exit, _) = collect(&mut terminal, Duration::from_secs(10));
    assert_eq!(exit, Some(0));
    assert!(
        text(&bytes).contains("[xterm-256color|1|9.9|unset]"),
        "{:?}",
        text(&bytes)
    );
}

fn registry(script: &'static str) -> TerminalRegistry {
    let launcher: Launcher = Arc::new(move |directory: &Path| sh(directory, script));
    TerminalRegistry::new(launcher)
}

#[test]
fn registry_numbers_selects_renames_restarts_and_closes_like_swift() {
    let dir = tempfile::tempdir().unwrap();
    let mut registry = registry("read x");
    let project = "p";
    let first = registry
        .ensure_initial_session(project, dir.path())
        .unwrap();
    assert_eq!(
        registry.ensure_initial_session(project, dir.path()),
        Some(first)
    );
    let second = registry.create(project, dir.path());
    let third = registry.create(project, dir.path());
    let names: Vec<String> = registry
        .sessions(project)
        .iter()
        .map(|s| s.display_name())
        .collect();
    assert_eq!(names, ["Terminal 1", "Terminal 2", "Terminal 3"]);
    assert_eq!(registry.selected(project).unwrap().id, third);
    assert!(registry.select(first, project));
    assert!(!registry.select(first, project), "already shown");
    // Names: trimmed, 64 characters at most, empty for the number back.
    registry.rename(second, project, "  build  ");
    assert_eq!(
        registry.find(second, project).unwrap().display_name(),
        "build"
    );
    registry.rename(second, project, &"é".repeat(70));
    assert_eq!(
        registry
            .find(second, project)
            .unwrap()
            .display_name()
            .chars()
            .count(),
        64
    );
    registry.rename(second, project, "  ");
    assert_eq!(
        registry.find(second, project).unwrap().display_name(),
        "Terminal 2"
    );
    registry.rename(second, project, "logs");
    // A restart keeps the place, the id, the number and the name.
    let old_pid = registry
        .find(second, project)
        .unwrap()
        .process
        .as_ref()
        .unwrap()
        .process_id();
    assert_eq!(
        registry.restart(second, project, 1),
        None,
        "stale generation"
    );
    assert_eq!(registry.restart(second, project, 0), Some(second));
    let restarted = registry.find(second, project).unwrap();
    assert_eq!(
        (
            restarted.generation,
            restarted.number,
            restarted.display_name()
        ),
        (1, 2, "logs".into())
    );
    assert_ne!(restarted.process.as_ref().unwrap().process_id(), old_pid);
    assert!(wait_gone(old_pid, Duration::from_secs(5)));
    // Closing the shown one shows the one after it, then the one before.
    registry.close(first, project, 0);
    assert_eq!(registry.selected(project).unwrap().id, second);
    registry.close(second, project, 0); // stale generation: nothing
    assert_eq!(registry.sessions(project).len(), 2);
    registry.close(third, project, 0);
    assert_eq!(registry.selected(project).unwrap().id, second);
    registry.close(second, project, 1);
    assert!(registry.selected(project).is_none());
    // All closed: the project stays empty until asked, and numbers go on.
    assert_eq!(registry.ensure_initial_session(project, dir.path()), None);
    let fourth = registry.create(project, dir.path());
    assert_eq!(registry.find(fourth, project).unwrap().number, 4);
    assert_eq!(registry.open_projects(), vec!["p".to_string()]);
    let pid = registry
        .find(fourth, project)
        .unwrap()
        .process
        .as_ref()
        .unwrap()
        .process_id();
    registry.close_project(project);
    assert!(registry.open_projects().is_empty());
    assert!(wait_gone(pid, Duration::from_secs(5)));
}

#[test]
fn shutdown_ends_every_shell() {
    let dir = tempfile::tempdir().unwrap();
    let mut registry = registry("read x");
    registry.create("a", dir.path());
    registry.create("b", dir.path());
    let pids: Vec<_> = ["a", "b"]
        .iter()
        .map(|p| {
            registry
                .selected(p)
                .unwrap()
                .process
                .as_ref()
                .unwrap()
                .process_id()
        })
        .collect();
    drop(registry);
    for pid in pids {
        assert!(wait_gone(pid, Duration::from_secs(5)), "{pid}");
    }
}

#[test]
fn a_session_feeds_its_grid_answers_programs_and_coalesces_bells() {
    let dir = tempfile::tempdir().unwrap();
    // Asks for the cursor position and prints the answer it reads back.
    let mut registry = registry(
        "printf '\\033]2;my title\\007\\007\\007'; stty raw -echo; printf '\\033[6n'; dd bs=1 count=6 2>/dev/null | od -c | head -1; sleep 0.3; printf '\\007'",
    );
    let id = registry.create("p", dir.path());
    let deadline = Instant::now() + Duration::from_secs(10);
    let start = Instant::now();
    let mut clock = start;
    loop {
        let session = registry.find_mut(id, "p").unwrap();
        clock += Duration::from_millis(100);
        session.pump(clock);
        if session.exited || Instant::now() > deadline {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let session = registry.find(id, "p").unwrap();
    assert!(session.exited);
    assert_eq!(session.exit_code, Some(0));
    assert_eq!(session.shell_title, "my title");
    let screen = session.emulator.screen_text();
    assert!(screen.contains("033   [   1   ;   1   R"), "{screen}");
    // Two bells together ring once; the third, later, rings again.
    assert_eq!(session.bells_rung, 2);
    assert!(!session.running());
}

#[test]
fn a_shell_that_cannot_start_is_a_failure_not_a_crash() {
    let dir = tempfile::tempdir().unwrap();
    let launcher: Launcher = Arc::new(|directory: &Path| {
        let mut launch = sh(directory, "");
        launch.arguments.push("bad\0argument".into());
        launch
    });
    let mut registry = TerminalRegistry::new(launcher);
    let id = registry.create("p", dir.path());
    let session = registry.find(id, "p").unwrap();
    assert!(session.exited);
    assert_eq!(
        session.failure.as_deref(),
        Some("Could not start the shell (Invalid argument)")
    );
}

#[test]
fn ending_questions_read_as_swift_asks_them() {
    let (title, detail, action) =
        session::ending_question(Ending::Restart, "Terminal 1", "app", "/p/app");
    assert_eq!(title, "Restart “Terminal 1” in “app”?");
    assert_eq!(
        detail,
        "This ends the shell in this terminal and may interrupt a command it is running. Its scrollback is removed, and a new shell starts in /p/app."
    );
    assert_eq!(action, "Restart Terminal");
    let (title, detail, action) = session::ending_question(Ending::Close, "logs", "app", "/p/app");
    assert_eq!(title, "Close “logs” in “app”?");
    assert_eq!(
        detail,
        "This ends the shell in this terminal and may interrupt a command it is running. Its output is removed. The project's other terminals keep running."
    );
    assert_eq!(action, "Close Terminal");
}

#[test]
fn quitting_kills_a_shell_that_ignores_hangup_at_once() {
    let dir = tempfile::tempdir().unwrap();
    let mut registry = registry("trap '' HUP; read x; read y");
    let first = registry.create("p", dir.path());
    let second = registry.create("p", dir.path());
    std::thread::sleep(Duration::from_millis(200));
    let pids: Vec<_> = [first, second]
        .iter()
        .map(|id| {
            registry
                .find(*id, "p")
                .unwrap()
                .process
                .as_ref()
                .unwrap()
                .process_id()
        })
        .collect();
    let started = Instant::now();
    registry.end_all_now(Duration::from_millis(50));
    assert!(registry.open_projects().is_empty());
    for pid in pids {
        assert!(wait_gone(pid, Duration::from_secs(1)), "{pid}");
    }
    assert!(started.elapsed() < Duration::from_secs(1));
}
