//! Exercise actual process-level exclusion and drop-based release, without a provider.
use bello_agent_core::{Result, SessionStore, workspace::WorkspaceStore};
use std::{
    any::Any,
    io::Write,
    path::Path,
    process::{Command, Stdio},
    sync::Mutex,
    time::{Duration, Instant},
};

// Concurrent fork/exec can briefly inherit the other case's locked descriptor
// before close-on-exec runs. Keep these ownership scenarios independent.
static PROCESS_CASE: Mutex<()> = Mutex::new(());

fn open_store(kind: &str, path: &Path, project: &Path) -> Result<Box<dyn Any>> {
    match kind {
        "session" => SessionStore::open(path).map(|store| Box::new(store) as Box<dyn Any>),
        "workspace" => {
            WorkspaceStore::open(path, project).map(|store| Box::new(store) as Box<dyn Any>)
        }
        _ => panic!("unknown lock test kind"),
    }
}

// Invoked as one exact test in a fresh process. A normal suite run is a no-op.
#[test]
fn subprocess_lock_probe() {
    let Ok(kind) = std::env::var("BELLO_LOCK_TEST_KIND") else {
        return;
    };
    let path = std::env::var_os("BELLO_LOCK_TEST_PATH").unwrap();
    let project = std::env::var_os("BELLO_LOCK_TEST_PROJECT").unwrap();
    let result = open_store(&kind, Path::new(&path), Path::new(&project));
    match std::env::var("BELLO_LOCK_TEST_EXPECT").unwrap().as_str() {
        "locked" => match result {
            Err(error) => assert_eq!(
                error.to_string(),
                format!("This Rust {kind} is already open elsewhere")
            ),
            Ok(_) => panic!("a different process acquired an already held {kind} lock"),
        },
        "available" => {
            let store = result.unwrap();
            drop(store);
            // A second open also proves the acquired guard releases on drop.
            drop(open_store(&kind, Path::new(&path), Path::new(&project)).unwrap());
        }
        "exit_held" => {
            let _store = result.unwrap();
            println!("BELLO_LOCK_PROBE_OK:{kind}");
            std::io::stdout().flush().unwrap();
            // process::exit skips Rust destructors: the OS must release the lock.
            std::process::exit(0);
        }
        _ => panic!("unknown lock test expectation"),
    }
    println!("BELLO_LOCK_PROBE_OK:{kind}");
}

fn probe(kind: &str, path: &Path, project: &Path, expected: &str) {
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "subprocess_lock_probe", "--nocapture"])
        .env("BELLO_LOCK_TEST_KIND", kind)
        .env("BELLO_LOCK_TEST_PATH", path)
        .env("BELLO_LOCK_TEST_PROJECT", project)
        .env("BELLO_LOCK_TEST_EXPECT", expected)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    // A regression to blocking lock acquisition must fail rather than hang CI.
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let output = child.wait_with_output().unwrap();
            panic!(
                "{kind} lock probe timed out ({expected}): {}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{kind} lock probe failed ({expected}): {}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stdout).contains(&format!("BELLO_LOCK_PROBE_OK:{kind}")),
        "the subprocess must actually execute the selected probe"
    );
}

fn exercise(kind: &str) {
    let _case = PROCESS_CASE.lock().unwrap();
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join(format!("{kind}.json"));
    let store = open_store(kind, &path, directory.path()).unwrap();
    let original_bytes = std::fs::read(&path).ok();
    probe(kind, &path, directory.path(), "locked");
    assert_eq!(std::fs::read(&path).ok(), original_bytes);
    drop(store);
    probe(kind, &path, directory.path(), "available");
    probe(kind, &path, directory.path(), "exit_held");
    // Ownership must return even when the child exits without dropping its guard.
    drop(open_store(kind, &path, directory.path()).unwrap());
    let unwind = std::panic::catch_unwind(|| {
        let _store = open_store(kind, &path, directory.path()).unwrap();
        panic!("exercise lock guard release during unwinding");
    });
    assert_eq!(
        unwind.unwrap_err().downcast_ref::<&str>(),
        Some(&"exercise lock guard release during unwinding")
    );
    probe(kind, &path, directory.path(), "available");
}

#[test]
fn session_excludes_other_process_and_reopens_after_drop() {
    exercise("session");
}

#[test]
fn workspace_excludes_other_process_and_reopens_after_drop() {
    exercise("workspace");
}
