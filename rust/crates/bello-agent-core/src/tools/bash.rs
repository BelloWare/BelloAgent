//! Owned Bash process lifetime, source-backed by Tools.swift::ShellRun.
//!
//! Only the bounded file executor runs this supervisor. Both pipes are polled
//! nonblocking on that same worker; no reader thread or timer can outlive it.
//! `waitid(WNOWAIT)` observes exit without releasing the leader's PID. This is
//! essential: every process-group signal happens before our sole owner reaps
//! that leader, so its numeric process group cannot have been recycled. No
//! process lookup, numeric-PID fallback, or escaped-group pursuit is permitted.
//! The supported host must leave SIGCHLD at SIG_DFL without SA_NOCLDWAIT and
//! give each Child exactly one reaper; no waitpid(-1)/P_ALL consumer may compete.
//! We reject other dispositions before spawning and before every signal. That
//! checked host contract is required: portable POSIX offers no atomic "signal
//! this old group incarnation" primitive against hostile concurrent reaping.
use super::{ToolError, ToolResult, bounded_int, result_text};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    ffi::OsString,
    fs::{self, File},
    io::{self, Read, Write},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{DirBuilderExt, OpenOptionsExt},
            process::{CommandExt, ExitStatusExt},
        },
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;

pub const PREVIEW_BYTES: usize = 32 * 1024;
const RETAIN_BYTES: usize = 64 * 1024 * 1024;
const EXIT_GRACE: Duration = Duration::from_millis(1500);
const STOP_GRACE: Duration = Duration::from_millis(500);
const KILL_GRACE: Duration = Duration::from_secs(1);
const STOP_LIMIT: Duration = Duration::from_secs(3);
const UPDATE_INTERVAL: Duration = Duration::from_millis(66);
const BACKGROUND_NOTE: &str = "Note: a background process still held this command's output when bash exited, so output after that point was not read and the process may be stopped by SIGPIPE if it writes again. Redirect a background job's output to keep it running, for example: cmd > cmd.log 2>&1 &";

/// The caller selects the four source variables. No inherited credentials or
/// shell startup files enter the child. Tests always inject private HOME/TMPDIR.
#[derive(Clone, Debug)]
pub struct Environment {
    pub home: PathBuf,
    pub path: OsString,
    pub lang: OsString,
    pub temporary: PathBuf,
}
impl Environment {
    pub(crate) fn from_process(home: PathBuf) -> Self {
        Self {
            home,
            path: std::env::var_os("PATH").unwrap_or_else(|| {
                "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin".into()
            }),
            lang: std::env::var_os("LANG").unwrap_or_else(|| "en_US.UTF-8".into()),
            temporary: std::env::var_os("TMPDIR")
                .map(PathBuf::from)
                .unwrap_or_else(std::env::temp_dir),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Update {
    pub sequence: u64,
    pub preview: String,
}
pub type OnUpdate = Arc<dyn Fn(Update) + Send + Sync>;

/// Physical owners are registered before dispatch, and stay registered through
/// retained-output conversion and any last-resort reaping. A cancelled shutdown
/// waiter cannot consume the only ownership record or release the session lock.
#[derive(Default)]
pub(crate) struct Jobs {
    next: AtomicU64,
    pending: Mutex<BTreeMap<u64, CancellationToken>>,
    released: tokio::sync::Notify,
}
pub(crate) struct Job {
    owner: Arc<Jobs>,
    id: u64,
}
impl Jobs {
    pub fn register(self: &Arc<Self>, token: CancellationToken) -> ToolResult<Job> {
        let mut id = self.next.load(Ordering::Acquire);
        loop {
            let next = id.checked_add(1).ok_or_else(|| {
                ToolError::failure("tool_worker", "Bash worker identity exhausted")
            })?;
            match self
                .next
                .compare_exchange_weak(id, next, Ordering::AcqRel, Ordering::Acquire)
            {
                Ok(_) => break,
                Err(current) => id = current,
            }
        }
        self.pending
            .lock()
            .map_err(|_| ToolError::failure("tool_worker", "Bash ownership unavailable"))?
            .insert(id, token);
        Ok(Job {
            owner: self.clone(),
            id,
        })
    }
    pub fn cancel(&self) {
        if let Ok(pending) = self.pending.lock() {
            for token in pending.values() {
                token.cancel();
            }
        }
    }
    pub async fn join(&self) -> crate::Result<()> {
        loop {
            let released = self.released.notified();
            tokio::pin!(released);
            released.as_mut().enable();
            if self
                .pending
                .lock()
                .map_err(|_| crate::invalid("Bash ownership unavailable"))?
                .is_empty()
            {
                return Ok(());
            }
            released.await;
        }
    }
}
impl Drop for Job {
    fn drop(&mut self) {
        if let Ok(mut pending) = self.owner.pending.lock() {
            pending.remove(&self.id);
        }
        self.owner.released.notify_waiters();
    }
}

pub(crate) struct Request {
    command: String,
    timeout: u64,
    #[cfg(test)]
    clock: Option<Arc<dyn Fn() -> Instant + Send + Sync>>,
    #[cfg(test)]
    observe_exited_before_drain: bool,
    #[cfg(test)]
    ignore_exit_for_cleanup_test: bool,
    #[cfg(test)]
    before_reap: Option<Arc<dyn Fn() + Send + Sync>>,
}
impl Request {
    pub fn parse(arguments: &Value) -> ToolResult<Self> {
        let command = arguments["command"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 262_144 && !s.contains('\0'))
            .ok_or_else(|| ToolError::failure("invalid_params", "Invalid command"))?
            .to_owned();
        let timeout = bounded_int(&arguments["timeout"], 120, 600)?;
        if timeout == 0 {
            return Err(ToolError::failure(
                "tool_arguments",
                "Timeout must be positive",
            ));
        }
        Ok(Self {
            command,
            timeout: timeout as u64,
            #[cfg(test)]
            clock: None,
            #[cfg(test)]
            observe_exited_before_drain: false,
            #[cfg(test)]
            ignore_exit_for_cleanup_test: false,
            #[cfg(test)]
            before_reap: None,
        })
    }
}

impl Request {
    #[cfg(test)]
    pub(crate) fn with_cleanup_fixture(
        mut self,
        barrier: Option<Arc<dyn Fn() + Send + Sync>>,
    ) -> Self {
        if barrier.is_some() {
            self.ignore_exit_for_cleanup_test = true;
        }
        self.before_reap = barrier;
        self
    }
    fn now(&self) -> Instant {
        #[cfg(test)]
        if let Some(clock) = &self.clock {
            return clock();
        }
        Instant::now()
    }
    fn observes_exit(&self) -> bool {
        #[cfg(test)]
        if self.ignore_exit_for_cleanup_test {
            return false;
        }
        true
    }
}
fn exclusive_reaping_policy() -> io::Result<()> {
    let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
    if unsafe { libc::sigaction(libc::SIGCHLD, std::ptr::null(), &mut action) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if action.sa_sigaction != libc::SIG_DFL || action.sa_flags & libc::SA_NOCLDWAIT != 0 {
        return Err(io::Error::other(
            "Bash requires exclusive child reaping and the default SIGCHLD disposition",
        ));
    }
    Ok(())
}

struct ProcessOwner {
    child: Child,
    may_signal: bool,
}
impl ProcessOwner {
    fn exited(&mut self) -> io::Result<bool> {
        // WNOWAIT is available in the pinned libc on both Linux and Darwin.
        // No other code receives/reaps this Child; the leader reserves its PID.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                self.child.id(),
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result == -1 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                return Ok(false);
            }
            // ECHILD removes ownership evidence. Re-check before EVERY signal,
            // including after an earlier WNOWAIT observation of leader exit.
            self.may_signal = false;
            return Err(error);
        }
        Ok(unsafe { info.si_pid() } != 0)
    }
    fn signal(&mut self, signal: i32) {
        if !self.may_signal {
            return;
        }
        if exclusive_reaping_policy().is_err() || self.exited().is_err() {
            self.may_signal = false;
            return;
        }
        let pid = self.child.id() as libc::pid_t;
        if pid > 1 && pid != unsafe { libc::getpgrp() } {
            unsafe {
                libc::kill(-pid, signal);
            }
        }
    }
    fn reap(&mut self) -> io::Result<std::process::ExitStatus> {
        // Permanently disable group signals BEFORE releasing the PID.
        self.may_signal = false;
        self.child.wait()
    }
}
impl Drop for ProcessOwner {
    fn drop(&mut self) {
        if self.may_signal {
            self.signal(libc::SIGKILL);
            let _ = self.reap();
        }
    }
}

pub(crate) struct Completion {
    pub result: ToolResult<Value>,
    // A bounded logical result never means physical cleanup was completed.
    // This sole owner stays on the same bounded worker with the editing guard.
    reaper: Option<ProcessOwner>,
    #[cfg(test)]
    before_reap: Option<Arc<dyn Fn() + Send + Sync>>,
}
impl Completion {
    pub fn reap(&mut self) {
        if let Some(mut owner) = self.reaper.take() {
            #[cfg(test)]
            if let Some(barrier) = self.before_reap.take() {
                barrier();
            }
            let _ = owner.reap();
        }
    }
    pub fn physically_settled(&self) -> bool {
        self.reaper.is_none()
    }
}

struct Output {
    file: File,
    path: PathBuf,
    preview: Vec<u8>,
    observed: u64,
    retained: usize,
    io_error: bool,
    published: usize,
    last_update: Option<Instant>,
    sequence: u64,
}
impl Output {
    fn create(directory: &Path) -> ToolResult<Self> {
        let prepare = || -> io::Result<_> {
            let mut dirs = fs::DirBuilder::new();
            dirs.recursive(true).mode(0o700);
            dirs.create(directory)?;
            if fs::symlink_metadata(directory)?.file_type().is_symlink() {
                return Err(io::Error::other("Tool output directory is a symbolic link"));
            }
            // A private fresh child avoids relying on an existing folder's mode.
            let private = directory.join(uuid::Uuid::new_v4().to_string());
            fs::DirBuilder::new().mode(0o700).create(&private)?;
            let path = private.join("output.log");
            let file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&path)?;
            Ok((path, file))
        };
        let (path, file) = prepare()
            .map_err(|_| ToolError::failure("tool_output", "Cannot create retained tool output"))?;
        Ok(Self {
            file,
            path,
            preview: Vec::with_capacity(PREVIEW_BYTES),
            observed: 0,
            retained: 0,
            io_error: false,
            published: 0,
            last_update: None,
            sequence: 0,
        })
    }
    fn consume(&mut self, bytes: &[u8], update: Option<&OnUpdate>) {
        self.observed = self.observed.saturating_add(bytes.len() as u64);
        let take = bytes.len().min(PREVIEW_BYTES - self.preview.len());
        self.preview.extend_from_slice(&bytes[..take]);
        let keep = bytes.len().min(RETAIN_BYTES - self.retained);
        if self.io_error || self.file.write_all(&bytes[..keep]).is_err() {
            self.io_error = true;
        } else {
            self.retained += keep;
        }
        if self.preview.len() > self.published
            && self
                .last_update
                .is_none_or(|at| at.elapsed() >= UPDATE_INTERVAL)
        {
            self.last_update = Some(Instant::now());
            self.published = self.preview.len();
            self.sequence += 1;
            if let Some(update) = update {
                update(Update {
                    sequence: self.sequence,
                    preview: String::from_utf8_lossy(&self.preview).into_owned(),
                });
            }
        }
    }
    fn finish(mut self, exit: Option<i32>, held: bool, timed_out: bool, limit: u64) -> Value {
        if self.file.sync_all().is_err() {
            self.io_error = true;
        }
        let mut text = format!(
            "{}\nExit code: {}",
            String::from_utf8_lossy(&self.preview),
            exit.map_or_else(|| "unknown".into(), |n| n.to_string())
        );
        if timed_out {
            text = format!(
                "Command timed out after {limit} seconds and was terminated. Re-run with a larger timeout (up to 600 seconds) or split the work.\n{text}"
            );
        }
        if self.observed > self.preview.len() as u64 {
            text.push_str(&format!("\nOutput preview truncated. Retained {} of {} bytes at {}. Use read with offset/limit to inspect.", self.retained, self.observed, self.path.display()));
        }
        if self.io_error {
            text.push_str("\nWarning: output could not be fully retained.");
        }
        if held {
            text.push('\n');
            text.push_str(BACKGROUND_NOTE);
        }
        result_text(text, exit != Some(0) || self.io_error || timed_out)
    }
}
fn nonblocking(fd: i32) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags == -1 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
fn drain(
    pipe: &mut Option<impl Read + AsRawFd>,
    output: &mut Output,
    update: Option<&OnUpdate>,
    buffer: &mut [u8],
) -> bool {
    let Some(reader) = pipe.as_mut() else {
        return false;
    };
    for _ in 0..16 {
        match reader.read(buffer) {
            Ok(0) => {
                *pipe = None;
                return false;
            }
            Ok(count) => output.consume(&buffer[..count], update),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return false,
            Err(_) => {
                output.io_error = true;
                *pipe = None;
                return true;
            }
        }
    }
    false
}

pub(crate) fn run(
    request: Request,
    cwd: &Path,
    directory: &Path,
    environment: Environment,
    cancel: &CancellationToken,
    update: Option<OnUpdate>,
) -> ToolResult<Completion> {
    if cancel.is_cancelled() {
        return Err(ToolError::NotExecuted(
            "Not executed: cancelled before invocation".into(),
        ));
    }
    exclusive_reaping_policy()
        .map_err(|error| ToolError::failure("process_spawn", error.to_string()))?;
    let mut output = Output::create(directory)?;
    if cancel.is_cancelled() {
        return Err(ToolError::NotExecuted(
            "Not executed: cancelled before invocation".into(),
        ));
    }
    let child = Command::new("/bin/bash")
        .args(["--noprofile", "--norc", "-c", &request.command])
        .current_dir(cwd)
        .env_clear()
        .env("HOME", environment.home)
        .env("PATH", environment.path)
        .env("LANG", environment.lang)
        .env("TMPDIR", environment.temporary)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .map_err(|error| {
            ToolError::failure("process_spawn", format!("Cannot start command: {error}"))
        })?;
    let mut owner = ProcessOwner {
        child,
        may_signal: true,
    };
    if let Some(update) = &update {
        update(Update {
            sequence: 0,
            preview: String::new(),
        });
    }
    let mut stdout = owner.child.stdout.take();
    let mut stderr = owner.child.stderr.take();
    nonblocking(stdout.as_ref().expect("piped stdout").as_raw_fd())?;
    nonblocking(stderr.as_ref().expect("piped stderr").as_raw_fd())?;
    let deadline = request.now() + Duration::from_secs(request.timeout);
    #[cfg(test)]
    if request.observe_exited_before_drain {
        let bound = Instant::now() + Duration::from_secs(2);
        while !owner.exited()? {
            assert!(Instant::now() < bound);
            std::thread::yield_now();
        }
    }
    let mut exited_at = None;
    let mut stopped_at = None;
    let mut kill_sent = false;
    let mut abandoned_output = false;
    let mut timed_out = false;
    let mut cancelled = false;
    let mut buffer = vec![0_u8; 65_536];
    loop {
        let now = request.now();
        if exited_at.is_none() {
            match owner.exited() {
                Ok(true) if request.observes_exit() => exited_at = Some(now),
                Ok(true) => {}
                Ok(false) => {}
                Err(_) => {
                    // Ownership cannot be re-established by probing a number.
                    return Ok(Completion {
                        result: Err(ToolError::failure(
                            "process_owner",
                            "Command ownership could not be confirmed; effects may have occurred. No automatic replay.",
                        )),
                        reaper: Some(owner),
                        #[cfg(test)]
                        before_reap: request.before_reap.clone(),
                    });
                }
            }
        }
        let pipe_error = drain(&mut stdout, &mut output, update.as_ref(), &mut buffer)
            | drain(&mut stderr, &mut output, update.as_ref(), &mut buffer);
        // Draining can include disk writes. A timestamp from before those
        // writes cannot authorize successful completion past the deadline.
        let now = request.now();
        if stopped_at.is_none() && (cancel.is_cancelled() || now >= deadline || pipe_error) {
            cancelled = cancel.is_cancelled();
            timed_out = !cancelled && now >= deadline;
            stopped_at = Some(now);
            owner.signal(libc::SIGTERM);
        }
        if let Some(stopped) = stopped_at {
            if exited_at.is_some_and(|exit| now.duration_since(exit.max(stopped)) >= STOP_GRACE) {
                abandoned_output |= stdout.is_some() || stderr.is_some();
                stdout = None;
                stderr = None;
            }
            if !kill_sent && now.duration_since(stopped) >= KILL_GRACE {
                owner.signal(libc::SIGKILL);
                kill_sent = true;
            }
            let settled = exited_at.is_some_and(|exit| {
                stdout.is_none() && stderr.is_none()
                    || now.duration_since(exit.max(stopped)) >= STOP_GRACE
            });
            // Complete signalling while the unreaped leader still reserves its
            // identity, even if TERM made bash exit before its descendants.
            if kill_sent && settled {
                break;
            }
            if now.duration_since(stopped) >= STOP_LIMIT {
                drop(stdout);
                drop(stderr);
                return Ok(Completion {
                    result: Err(if cancelled {
                        ToolError::Cancelled
                    } else {
                        ToolError::failure(
                            "process_cleanup",
                            "Command cleanup is still pending; effects may have occurred. No automatic replay.",
                        )
                    }),
                    reaper: Some(owner),
                    #[cfg(test)]
                    before_reap: request.before_reap.clone(),
                });
            }
        } else if exited_at.is_some_and(|exit| {
            stdout.is_none() && stderr.is_none() || now.duration_since(exit) >= EXIT_GRACE
        }) {
            break;
        }
        let mut fds = [
            libc::pollfd {
                fd: stdout.as_ref().map_or(-1, AsRawFd::as_raw_fd),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: stderr.as_ref().map_or(-1, AsRawFd::as_raw_fd),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        // Short bounded sleep also observes cancellation/deadlines when an
        // escaped descendant holds silent pipes. No Tokio/UI thread blocks.
        if unsafe { libc::poll(fds.as_mut_ptr(), 2, 10) } < 0
            && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted
        {
            output.io_error = true;
            if stopped_at.is_none() {
                stopped_at = Some(request.now());
                owner.signal(libc::SIGTERM);
            }
        }
    }
    let held = abandoned_output || stdout.is_some() || stderr.is_some();
    drop(stdout);
    drop(stderr);
    let status = owner.reap()?;
    let exit = status.code().or_else(|| status.signal());
    let result = if cancelled || cancel.is_cancelled() {
        Err(ToolError::Cancelled)
    } else {
        Ok(output.finish(exit, held, timed_out, request.timeout))
    };
    Ok(Completion {
        result,
        reaper: None,
        #[cfg(test)]
        before_reap: None,
    })
}

#[cfg(test)]
#[path = "bash_tests.rs"]
mod tests;
