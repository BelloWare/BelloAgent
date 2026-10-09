//! Deterministic substitutions after the exact metadata used by production's
//! journal open. The FIFO probe is isolated so regressions cannot hang CI.
use super::open_after_metadata;
use std::fs;

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn fifo_substitution_child() {
    if std::env::var_os("BELLO_JOURNAL_FIFO_PROBE").is_none() {
        return;
    }
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("journal.jsonl");
    fs::write(&path, b"original").unwrap();
    let metadata = fs::symlink_metadata(&path).unwrap();
    fs::remove_file(&path).unwrap();
    let name = CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: name is a live, NUL-terminated pathname in a disposable tempdir.
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    // Crucially, there is no fresh metadata read before production opens this
    // path. Removing O_NONBLOCK makes this exact call wait for a FIFO writer.
    assert!(open_after_metadata(&path, &metadata, false).is_err());
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn fifo_substitution_after_stat_is_rejected_without_waiting_for_a_peer() {
    use std::{
        process::{Command, Stdio},
        time::{Duration, Instant},
    };
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "stream_journal::inspection_tests::fifo_substitution_child",
            "--nocapture",
        ])
        .env("BELLO_JOURNAL_FIFO_PROBE", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let output = child.wait_with_output().unwrap();
            panic!(
                "journal inspection blocked after FIFO substitution: {}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
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
}

#[cfg(unix)]
#[test]
fn same_length_mtime_replacement_after_stat_is_rejected_by_identity() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("journal.jsonl");
    let replacement = directory.path().join("replacement.jsonl");
    fs::write(&path, b"original").unwrap();
    let metadata = fs::symlink_metadata(&path).unwrap();
    fs::write(&replacement, b"replaced").unwrap();
    fs::File::options()
        .write(true)
        .open(&replacement)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(metadata.modified().unwrap()))
        .unwrap();
    fs::rename(&replacement, &path).unwrap();
    assert!(open_after_metadata(&path, &metadata, false).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"replaced");
}

#[cfg(unix)]
#[test]
fn symlink_substitution_after_stat_is_rejected_without_mutating_target() {
    use std::os::unix::fs::symlink;
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("journal.jsonl");
    let target = directory.path().join("target.jsonl");
    fs::write(&path, b"original").unwrap();
    fs::write(&target, b"target bytes").unwrap();
    let metadata = fs::symlink_metadata(&path).unwrap();
    fs::remove_file(&path).unwrap();
    symlink(&target, &path).unwrap();
    assert!(open_after_metadata(&path, &metadata, false).is_err());
    assert_eq!(fs::read(&target).unwrap(), b"target bytes");
}

#[test]
fn regular_journal_read_only_open_preserves_bytes_and_metadata() {
    use std::io::Read;
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("journal.jsonl");
    fs::write(&path, b"unchanged").unwrap();
    let metadata = fs::symlink_metadata(&path).unwrap();
    let mut file = open_after_metadata(&path, &metadata, false).unwrap();
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes, b"unchanged");
    assert_eq!(
        fs::metadata(&path).unwrap().modified().unwrap(),
        metadata.modified().unwrap()
    );
    assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 1);
}
