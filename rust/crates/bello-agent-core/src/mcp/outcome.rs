//! Project outcome evidence outlives transport success. A ticket can be settled
//! only after its canonical chat checkpoint or Inspector receipt is durable.
use crate::{Error, Result, invalid};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
const MAX_MARKER: usize = 65_536;
const MAX_PENDING: usize = 64;
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    server: String,
    tool: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    version: u32,
    project: String,
    pending: BTreeMap<String, Entry>,
}
struct State {
    record: Record,
    unknown: bool,
    live: HashSet<String>,
}
// Lock the stable sidecar, not the atomically replaced evidence inode. Every
// Ledger Arc (including a late Ticket or blocking receipt worker) owns this
// guard. Different workspace catalogs cannot share the outcome writer merely
// because their own catalog locks differ.
struct WriterLease(File);
impl WriterLease {
    fn acquire(path: &Path) -> Result<Self> {
        if let Ok(metadata) = fs::symlink_metadata(path)
            && !metadata.is_file()
        {
            return Err(invalid("MCP outcome writer lock is not a regular file"));
        }
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        nonblocking_nofollow(&mut options);
        let file = options
            .open(path)
            .map_err(|_| invalid("MCP outcome writer lock could not be opened"))?;
        if !file.metadata()?.is_file() {
            return Err(invalid("MCP outcome writer lock is not a regular file"));
        }
        file.try_lock().map_err(|_| {
            invalid("MCP outcome evidence is already open elsewhere; close the other project owner before retrying")
        })?;
        Ok(Self(file))
    }
}
impl Drop for WriterLease {
    fn drop(&mut self) {
        // Explicit unlock also releases inherited/duplicated descriptors. Never
        // unlink this path: replacing its inode would admit a second writer.
        let _ = self.0.unlock();
    }
}
pub(super) struct Ledger {
    path: PathBuf,
    _writer: WriterLease,
    state: Mutex<State>,
    cached_status: Mutex<Status>,
    project: String,
    abandoned: std::sync::atomic::AtomicBool,
    #[cfg(test)]
    fault: std::sync::atomic::AtomicU8,
    #[cfg(test)]
    receipt_fault: std::sync::atomic::AtomicU8,
}
#[derive(Clone)]
pub(super) struct Status {
    pub unknown: bool,
    pub unknown_id: Option<String>,
    pub pending: usize,
}
impl Ledger {
    pub fn open(directory: &Path, project: &str) -> Result<Arc<Self>> {
        if uuid::Uuid::parse_str(project).is_err() || !directory.is_dir() {
            return Err(invalid("Invalid MCP project outcome location"));
        }
        // Resolve parent aliases before deriving the stable lock identity. The
        // evidence leaf itself must be regular/non-symlink, checked on read.
        let path = fs::canonicalize(directory)?.join(format!("mcp-outcomes-{project}.json"));
        let writer = WriterLease::acquire(&path.with_extension("lock"))?;
        let record = match read_bounded(&path, MAX_MARKER)? {
            None => Record {
                version: 1,
                project: project.into(),
                pending: BTreeMap::new(),
            },
            Some(bytes) => {
                let record: Record = serde_json::from_slice(&bytes).map_err(|_| {
                    invalid("MCP outcome evidence is invalid; saved bytes were preserved")
                })?;
                if record.version != 1
                    || record.project != project
                    || record.pending.len() > MAX_PENDING
                    || record.pending.iter().any(|(id, e)| {
                        uuid::Uuid::parse_str(id).is_err()
                            || e.server.is_empty()
                            || e.server.len() > 128
                            || e.tool.is_empty()
                            || e.tool.len() > 256
                    })
                {
                    return Err(invalid(
                        "MCP outcome evidence identity is invalid; saved bytes were preserved",
                    ));
                }
                record
            }
        };
        let unknown = !record.pending.is_empty();
        let cached_status = Status {
            unknown,
            unknown_id: unknown.then(|| fingerprint(&record)),
            pending: 0,
        };
        Ok(Arc::new(Self {
            path,
            _writer: writer,
            cached_status: Mutex::new(cached_status),
            project: project.into(),
            abandoned: std::sync::atomic::AtomicBool::new(false),
            state: Mutex::new(State {
                record,
                unknown,
                live: HashSet::new(),
            }),
            #[cfg(test)]
            fault: std::sync::atomic::AtomicU8::new(0),
            #[cfg(test)]
            receipt_fault: std::sync::atomic::AtomicU8::new(0),
        }))
    }
    // UI callers never wait behind the ledger's fsync/rename critical section.
    pub fn status(&self) -> Status {
        self.cached_status
            .try_lock()
            .map(|status| {
                let mut status = status.clone();
                status.unknown |= self.abandoned.load(std::sync::atomic::Ordering::Acquire);
                status
            })
            .unwrap_or(Status {
                unknown: true,
                unknown_id: None,
                pending: 1,
            })
    }
    /// Operation admission must use actual outcome evidence. The conservative
    /// presentation fallback above also represents cached-reader contention,
    /// which is not evidence that an earlier invocation has an unknown result.
    /// Call on the blocking pool: the state lock can cover durable ledger I/O.
    pub fn has_unknown_outcome(&self) -> Result<bool> {
        self.state
            .lock()
            .map(|state| state.unknown || self.abandoned.load(std::sync::atomic::Ordering::Acquire))
            .map_err(|_| invalid("MCP outcome evidence is unavailable"))
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub fn during_status_read_for_test<T>(&self, read: impl FnOnce() -> T) -> T {
        let _status = self.cached_status.lock().unwrap();
        read()
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub fn poison_state_for_test(&self) {
        let _state = self.state.lock().unwrap();
        panic!("synthetic outcome-state poisoning");
    }
    fn publish_status(&self, state: &State) {
        let status = Status {
            unknown: state.unknown,
            unknown_id: state.unknown.then(|| fingerprint(&state.record)),
            pending: state.live.len(),
        };
        *self.cached_status.lock().unwrap_or_else(|e| e.into_inner()) = status;
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub fn hold_write_lock_for_test(
        &self,
        started: std::sync::mpsc::Sender<()>,
        release: std::sync::mpsc::Receiver<()>,
    ) {
        let _state = self.state.lock().unwrap();
        started.send(()).unwrap();
        release
            .recv_timeout(std::time::Duration::from_secs(3))
            .unwrap();
    }
    pub fn begin(self: &Arc<Self>, server: &str, tool: &str) -> Result<Ticket> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| invalid("MCP outcome evidence is unavailable"))?;
        if state.unknown || self.abandoned.load(std::sync::atomic::Ordering::Acquire) {
            return Err(invalid(
                "A previous MCP invocation has an unknown outcome. Review its effects and acknowledge before another invocation.",
            ));
        }
        if state.record.pending.len() >= MAX_PENDING {
            return Err(invalid(
                "Too many MCP results are waiting for durable retention",
            ));
        }
        let id = uuid::Uuid::new_v4().to_string();
        let mut next = state.record.clone();
        next.pending.insert(
            id.clone(),
            Entry {
                server: server.into(),
                tool: tool.into(),
            },
        );
        if let Err(error) = self.write(&next) {
            state.record = next;
            state.unknown = true;
            self.publish_status(&state);
            return Err(error);
        }
        state.record = next;
        state.live.insert(id.clone());
        self.publish_status(&state);
        Ok(Ticket {
            ledger: self.clone(),
            id,
            settled: false,
            target: (server.into(), tool.into()),
        })
    }
    fn write(&self, record: &Record) -> Result<()> {
        let bytes = serde_json::to_vec(record)?;
        if bytes.len() > MAX_MARKER {
            return Err(invalid("MCP outcome marker exceeds its storage limit"));
        }
        #[cfg(test)]
        let fault = self.fault.load(std::sync::atomic::Ordering::Acquire);
        #[cfg(not(test))]
        let fault = 0;
        atomic_write(&self.path, &bytes, fault)
    }
    fn settle(&self, id: &str) -> Result<()> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| invalid("MCP outcome evidence is unavailable"))?;
        if !state.record.pending.contains_key(id) || !state.live.contains(id) {
            return Err(invalid("MCP outcome receipt is no longer current"));
        }
        let mut next = state.record.clone();
        next.pending.remove(id);
        if let Err(error) = self.write(&next) {
            state.unknown = true;
            self.publish_status(&state);
            return Err(error);
        }
        state.record = next;
        state.live.remove(id);
        self.publish_status(&state);
        // Never clear a different unknown invocation as a side effect.
        Ok(())
    }
    pub fn acknowledge(&self, expected: &str, confirmed: bool) -> Result<()> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| invalid("MCP outcome evidence is unavailable"))?;
        if !confirmed || !state.unknown || fingerprint(&state.record) != expected {
            return Err(invalid(
                "MCP outcome changed. Review the current outcome before acknowledging.",
            ));
        }
        if !state.live.is_empty() {
            return Err(invalid(
                "An MCP invocation or result retention is still running",
            ));
        }
        let mut next = state.record.clone();
        next.pending.clear();
        self.write(&next)?;
        state.record = next;
        state.unknown = false;
        self.abandoned
            .store(false, std::sync::atomic::Ordering::Release);
        self.publish_status(&state);
        Ok(())
    }
    pub fn write_receipt(&self, bytes: &[u8]) -> Result<()> {
        #[cfg(test)]
        let fault = self
            .receipt_fault
            .load(std::sync::atomic::Ordering::Acquire);
        #[cfg(not(test))]
        let fault = 0;
        atomic_write(&self.receipt_path(), bytes, fault)
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub fn set_receipt_fault(&self, value: u8) {
        self.receipt_fault
            .store(value, std::sync::atomic::Ordering::Release);
    }
    pub fn receipt_path(&self) -> PathBuf {
        self.path
            .with_file_name(format!("mcp-latest-result-{}.json", self.project))
    }
    #[cfg(all(test, feature = "synthetic-authority"))]
    pub fn set_fault(&self, value: u8) {
        self.fault
            .store(value, std::sync::atomic::Ordering::Release);
    }
}
fn fingerprint(record: &Record) -> String {
    format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(record).expect("marker JSON"))
    )
}
pub(crate) struct Ticket {
    ledger: Arc<Ledger>,
    id: String,
    settled: bool,
    target: (String, String),
}
impl Ticket {
    pub fn id(&self) -> &str {
        &self.id
    }
    pub fn target(&self) -> Result<(String, String)> {
        Ok(self.target.clone())
    }
    pub fn settle(mut self) -> Result<()> {
        self.ledger.settle(&self.id)?;
        self.settled = true;
        Ok(())
    }
}
impl Drop for Ticket {
    fn drop(&mut self) {
        if self.settled {
            return;
        }
        // The flag closes admission immediately, without waiting on a state
        // mutex held through fsync. Cleanup owns the Ledger/OS lease until it
        // physically finishes, even when this ticket is dropped on Tokio.
        self.ledger
            .abandoned
            .store(true, std::sync::atomic::Ordering::Release);
        if let Ok(mut state) = self.ledger.state.try_lock() {
            state.unknown = true;
            state.live.remove(&self.id);
            self.ledger.publish_status(&state);
            return;
        }
        let ledger = self.ledger.clone();
        let id = self.id.clone();
        super::persistence_runtime().spawn(async move {
            let _ = super::persistence(move || {
                let mut state = ledger.state.lock().unwrap_or_else(|e| e.into_inner());
                state.unknown = true;
                state.live.remove(&id);
                ledger.publish_status(&state);
            })
            .await;
        });
    }
}
pub(super) fn atomic_write(path: &Path, bytes: &[u8], fault: u8) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| invalid("MCP receipt directory is unavailable"))?;
    let temporary = parent.join(format!(".mcp-{}.tmp", uuid::Uuid::new_v4()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let result = (|| {
        let mut file = options.open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        if fault == 1 {
            return Err(invalid("Injected MCP pre-rename failure"));
        }
        fs::rename(&temporary, path)?;
        if fault == 2 {
            return Err(Error::PersistenceUncertain(
                "Injected MCP post-rename failure".into(),
            ));
        }
        File::open(parent).and_then(|f| f.sync_all()).map_err(|_| {
            Error::PersistenceUncertain(
                "MCP outcome/receipt synchronization was not confirmed".into(),
            )
        })?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}
pub(super) fn read_bounded(path: &Path, limit: usize) -> Result<Option<Vec<u8>>> {
    let mut options = OpenOptions::new();
    options.read(true);
    nonblocking_nofollow(&mut options);
    let file = match options.open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => {
            return Err(invalid(
                "MCP outcome evidence could not be opened; it was preserved",
            ));
        }
    };
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > limit as u64 {
        return Err(invalid(
            "MCP outcome evidence is not a bounded regular file",
        ));
    }
    let mut bytes = vec![];
    file.take(limit as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(invalid("MCP outcome evidence exceeds its limit"));
    }
    Ok(Some(bytes))
}
fn nonblocking_nofollow(options: &mut OpenOptions) {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        #[cfg(target_os = "linux")]
        let flags = 0x800 | 0x20000;
        #[cfg(target_os = "macos")]
        let flags = 0x4 | 0x100;
        options.custom_flags(flags);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        process::{Command, Stdio},
        time::{Duration, Instant},
    };

    #[test]
    fn acknowledgment_uses_authoritative_live_set_even_with_stale_presentation() {
        let directory = tempfile::tempdir().unwrap();
        let ledger = Ledger::open(directory.path(), &uuid::Uuid::new_v4().to_string()).unwrap();
        let first = ledger.begin("fixture", "first").unwrap();
        let second = ledger.begin("fixture", "second").unwrap();
        drop(first);
        let expected = ledger.status().unknown_id.unwrap();
        ledger.cached_status.lock().unwrap().pending = 0;
        assert!(
            ledger
                .acknowledge(&expected, true)
                .unwrap_err()
                .to_string()
                .contains("still running")
        );
        second.settle().unwrap();
        assert!(ledger.status().unknown);
        assert!(ledger.acknowledge(&expected, true).is_err());
        ledger
            .acknowledge(&ledger.status().unknown_id.unwrap(), true)
            .unwrap();
    }

    fn paths(directory: &Path, project: &str) -> (PathBuf, PathBuf) {
        let marker = directory.join(format!("mcp-outcomes-{project}.json"));
        let lock = marker.with_extension("lock");
        (marker, lock)
    }

    #[test]
    fn writer_exclusion_precedes_marker_read_and_preserves_evidence() {
        let directory = tempfile::tempdir().unwrap();
        let project = uuid::Uuid::new_v4().to_string();
        let (marker, lock) = paths(directory.path(), &project);
        let lease = WriterLease::acquire(&lock).unwrap();
        fs::write(&marker, b"unrelated invalid saved evidence").unwrap();
        let before = fs::read(&marker).unwrap();
        let error = Ledger::open(directory.path(), &project).err().unwrap();
        assert!(error.to_string().contains("already open elsewhere"));
        assert_eq!(fs::read(&marker).unwrap(), before);
        drop(lease);
        let error = Ledger::open(directory.path(), &project).err().unwrap();
        assert!(error.to_string().contains("saved bytes were preserved"));
        assert_eq!(fs::read(&marker).unwrap(), before);
        // Even an invalid-ledger error must release its acquired writer lease.
        drop(WriterLease::acquire(&lock).unwrap());
    }

    #[test]
    fn writer_lock_remains_stable_and_explicitly_unlocks() {
        let directory = tempfile::tempdir().unwrap();
        let project = uuid::Uuid::new_v4().to_string();
        let (_, lock) = paths(directory.path(), &project);
        let ledger = Ledger::open(directory.path(), &project).unwrap();
        assert!(!ledger.path.exists());
        let duplicate = ledger._writer.0.try_clone().unwrap();
        #[cfg(unix)]
        let identity = {
            use std::os::unix::fs::{MetadataExt, PermissionsExt};
            let metadata = fs::metadata(&lock).unwrap();
            assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
            (metadata.dev(), metadata.ino())
        };
        drop(ledger);
        assert!(lock.is_file());
        let reopened = Ledger::open(directory.path(), &project).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let metadata = fs::metadata(&lock).unwrap();
            assert_eq!((metadata.dev(), metadata.ino()), identity);
        }
        drop(reopened);
        drop(duplicate);
    }

    #[test]
    #[cfg(unix)]
    fn canonical_parent_alias_and_unsafe_lock_leaves_cannot_admit_writers() {
        use std::os::unix::fs::symlink;
        let directory = tempfile::tempdir().unwrap();
        let real = directory.path().join("real");
        fs::create_dir(&real).unwrap();
        let alias = directory.path().join("alias");
        symlink(&real, &alias).unwrap();
        let project = uuid::Uuid::new_v4().to_string();
        let (_, lock) = paths(&real, &project);
        let ledger = Ledger::open(&real, &project).unwrap();
        assert!(Ledger::open(&alias, &project).is_err());
        drop(ledger);
        fs::remove_file(&lock).unwrap();
        let target = directory.path().join("preserved");
        fs::write(&target, b"unchanged").unwrap();
        symlink(&target, &lock).unwrap();
        assert!(Ledger::open(&real, &project).is_err());
        assert_eq!(fs::read(&target).unwrap(), b"unchanged");
        fs::remove_file(&lock).unwrap();
        fs::create_dir(&lock).unwrap();
        assert!(Ledger::open(&real, &project).is_err());
        fs::remove_dir(&lock).unwrap();
        assert!(
            Command::new("mkfifo")
                .arg(&lock)
                .status()
                .unwrap()
                .success()
        );
        external_probe(&real, &project, "unsafe");
    }

    // Invoked by external_probe; ordinary test runs deliberately do no work.
    #[test]
    fn outcome_writer_subprocess_probe() {
        let Some(directory) = std::env::var_os("BELLO_MCP_WRITER_DIRECTORY") else {
            return;
        };
        let directory = PathBuf::from(directory);
        let project = std::env::var("BELLO_MCP_WRITER_PROJECT").unwrap();
        let expected = std::env::var("BELLO_MCP_WRITER_EXPECTED").unwrap();
        let (marker, _) = paths(&directory, &project);
        let before = fs::read(&marker).ok();
        let result = Ledger::open(&directory, &project);
        match expected.as_str() {
            "blocked" => assert!(
                result
                    .err()
                    .unwrap()
                    .to_string()
                    .contains("already open elsewhere")
            ),
            "unsafe" => assert!(result.err().unwrap().to_string().contains("regular file")),
            "unknown" => assert!(result.unwrap().status().unknown),
            _ => panic!("unexpected probe mode"),
        }
        assert_eq!(fs::read(&marker).ok(), before);
    }

    fn external_probe(directory: &Path, project: &str, expected: &str) {
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "mcp::outcome::tests::outcome_writer_subprocess_probe",
                "--nocapture",
            ])
            .env("BELLO_MCP_WRITER_DIRECTORY", directory)
            .env("BELLO_MCP_WRITER_PROJECT", project)
            .env("BELLO_MCP_WRITER_EXPECTED", expected)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if child.try_wait().unwrap().is_some() {
                break;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let output = child.wait_with_output().unwrap();
                panic!(
                    "outcome writer probe blocked: {}{}",
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

    #[test]
    fn outcome_writer_excludes_subprocess_until_last_ticket_drops() {
        let directory = tempfile::tempdir().unwrap();
        let project = uuid::Uuid::new_v4().to_string();
        let ledger = Ledger::open(directory.path(), &project).unwrap();
        let ticket = ledger.begin("fixture", "echo").unwrap();
        external_probe(directory.path(), &project, "blocked");
        drop(ledger);
        external_probe(directory.path(), &project, "blocked");
        drop(ticket);
        external_probe(directory.path(), &project, "unknown");
    }
}
