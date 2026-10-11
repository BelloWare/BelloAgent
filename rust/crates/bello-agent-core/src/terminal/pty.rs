//! A shell (or any program) on a pseudo-terminal, as Swift 0.1.122
//! Terminal/PseudoTerminal.swift runs it: forkpty gives the child a session
//! of its own with the slave as its controlling terminal, so job control, ^C
//! and window-size changes work as in any terminal. Output is read off the
//! owner's thread into a bounded buffer the owner drains in arrival order.
//!
//! The child is reaped by a watcher that waits without reaping (WNOWAIT) and
//! then reaps under the same lock `terminate` signals under, so a delayed
//! SIGHUP or SIGKILL never reaches a recycled pid. The master descriptor is
//! shared by the reader, the writer and resizes and closes only when the
//! last of them lets it go, so a late keystroke never reaches whatever file
//! the number was handed to since.
use std::collections::VecDeque;
use std::ffi::{CString, OsStr, OsString};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// Bytes waiting for the owner; a full buffer pauses the reader (kernel
/// backpressure) rather than discarding bytes inside a sequence.
pub const OUTPUT_BYTE_LIMIT: usize = 1_048_576;
/// The most one `take_output` hands over, so a flood never blocks a frame.
pub const DELIVERY_BYTES: usize = 65_536;
/// Pastes admitted but not yet written, in bytes and in pastes.
pub const INPUT_BYTE_LIMIT: usize = 2_097_152;
pub const INPUT_FRAME_LIMIT: usize = 32;
/// How long the program has after SIGHUP before SIGKILL.
pub const KILL_DELAY: Duration = Duration::from_secs(2);
/// How long output written before exit is still read.
const FINAL_DRAIN: Duration = Duration::from_millis(100);
const POLL_INTERVAL_MS: i32 = 50;

pub const INPUT_FULL_NOTICE: &str = "Terminal input queue is full. This paste was not sent; wait for the program to read input and try again.";
pub const DRAIN_LIMIT_NOTICE: &str = "Terminal output exceeded the final-drain limit after exit; the remaining output was not displayed.";

/// What to start: the program, its whole argv (argv[0] included), exactly
/// this environment, and the directory it starts in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalLaunch {
    pub executable: PathBuf,
    pub arguments: Vec<OsString>,
    pub environment: Vec<(OsString, OsString)>,
    pub directory: PathBuf,
}

#[derive(Debug, thiserror::Error)]
#[error("Could not start the shell ({0})")]
pub struct SpawnError(pub String);

/// What `take_output` found.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Output {
    pub bytes: Vec<u8>,
    /// More is waiting: take again after drawing this.
    pub more: bool,
    /// The program has exited and everything it wrote has been taken.
    pub exit: Option<i32>,
    pub notices: Vec<String>,
}

#[derive(Default)]
struct State {
    pid: libc::pid_t,
    reaped: bool,
    pending: VecDeque<u8>,
    /// The reader stopped: end of file, an error, or the final drain done.
    reader_done: bool,
    /// The exit status, once reaped.
    status: Option<i32>,
    /// The reader has drained what was written before exit.
    finished: bool,
    /// The exit has been handed to the owner.
    delivered: bool,
    capped: bool,
    /// Writes and resizes are refused: the terminal ended or was terminated.
    closed: bool,
    input_cancelled: bool,
    /// SIGHUP was sent and SIGKILL is due.
    terminating: bool,
    input_bytes: usize,
    input_frames: usize,
    notices: Vec<String>,
    /// Set by the owner to stop the reader and writer (Drop).
    stop: bool,
}

struct Shared {
    state: Mutex<State>,
    /// Signalled when output is taken (room for the reader), on exit and on stop.
    changed: Condvar,
    /// Wakes an async owner: new output, exit or a notice.
    notify: tokio::sync::Notify,
}
impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

pub struct PseudoTerminal {
    shared: Arc<Shared>,
    master: Option<Arc<OwnedFd>>,
    input: Option<mpsc::Sender<Vec<u8>>>,
    pid: libc::pid_t,
}

impl PseudoTerminal {
    /// Starts the program on a terminal of the given size.
    pub fn start(launch: &TerminalLaunch, columns: u16, rows: u16) -> Result<Self, SpawnError> {
        // Everything the child needs is prepared before the fork: only
        // async-signal-safe calls happen in between.
        let c = |text: &OsStr| {
            CString::new(text.as_bytes()).map_err(|_| SpawnError("Invalid argument".into()))
        };
        let path = c(launch.executable.as_os_str())?;
        let argv: Vec<CString> = launch
            .arguments
            .iter()
            .map(|a| c(a))
            .collect::<Result<_, _>>()?;
        let envp: Vec<CString> = launch
            .environment
            .iter()
            .map(|(key, value)| {
                let mut entry = key.clone();
                entry.push("=");
                entry.push(value);
                c(&entry)
            })
            .collect::<Result<_, _>>()?;
        let cwd = c(launch.directory.as_os_str())?;
        let mut argv_ptrs: Vec<*const libc::c_char> = argv.iter().map(|a| a.as_ptr()).collect();
        argv_ptrs.push(std::ptr::null());
        let mut envp_ptrs: Vec<*const libc::c_char> = envp.iter().map(|e| e.as_ptr()).collect();
        envp_ptrs.push(std::ptr::null());
        let mut size = libc::winsize {
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // A forked child keeps every descriptor not marked close-on-exec; the
        // child keeps its terminal alone, closing every other number below
        // this bound, read before the fork like everything else it uses.
        let descriptor_limit = unsafe { libc::getdtablesize() };
        let mut master_fd: libc::c_int = -1;
        let pid = unsafe {
            libc::forkpty(
                &mut master_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut::<libc::termios>() as _,
                &mut size as *mut libc::winsize as _,
            )
        };
        if pid == 0 {
            // Child: nothing but the terminal, default signal dispositions, its directory, then the program.
            unsafe {
                let mut descriptor = 3;
                while descriptor < descriptor_limit {
                    libc::close(descriptor);
                    descriptor += 1;
                }
                let mut signals: libc::sigset_t = std::mem::zeroed();
                libc::sigemptyset(&mut signals);
                libc::sigprocmask(libc::SIG_SETMASK, &signals, std::ptr::null_mut());
                for signal in [
                    libc::SIGPIPE,
                    libc::SIGINT,
                    libc::SIGQUIT,
                    libc::SIGTERM,
                    libc::SIGCHLD,
                    libc::SIGHUP,
                    libc::SIGTSTP,
                    libc::SIGTTIN,
                    libc::SIGTTOU,
                ] {
                    libc::signal(signal, libc::SIG_DFL);
                }
                libc::chdir(cwd.as_ptr());
                libc::execve(path.as_ptr(), argv_ptrs.as_ptr(), envp_ptrs.as_ptr());
                libc::_exit(127);
            }
        }
        if pid < 0 {
            let error = std::io::Error::last_os_error();
            return Err(SpawnError(strerror(error.raw_os_error().unwrap_or(0))));
        }
        unsafe {
            let flags = libc::fcntl(master_fd, libc::F_GETFL);
            libc::fcntl(master_fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
            libc::fcntl(master_fd, libc::F_SETFD, libc::FD_CLOEXEC);
        }
        let master = Arc::new(unsafe { OwnedFd::from_raw_fd(master_fd) });
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                pid,
                ..State::default()
            }),
            changed: Condvar::new(),
            notify: tokio::sync::Notify::new(),
        });
        // The reaper first: from then on the child is always reaped. Any
        // worker that cannot start ends the child and the workers started.
        let spawn = |name: &str, work: Box<dyn FnOnce() + Send>| {
            std::thread::Builder::new()
                .name(name.into())
                .spawn(work)
                .map(drop)
                .map_err(|e| SpawnError(e.to_string()))
        };
        {
            let worker = shared.clone();
            if let Err(error) = spawn("bello-pty-wait", Box::new(move || wait_loop(&worker, pid))) {
                abandon(&shared, pid, false);
                return Err(error);
            }
        }
        {
            let (worker, master) = (shared.clone(), master.clone());
            if let Err(error) = spawn(
                "bello-pty-read",
                Box::new(move || read_loop(&worker, &master)),
            ) {
                abandon(&shared, pid, true);
                return Err(error);
            }
        }
        let (sender, receiver) = mpsc::channel::<Vec<u8>>();
        {
            let (worker, master) = (shared.clone(), master.clone());
            if let Err(error) = spawn(
                "bello-pty-write",
                Box::new(move || write_loop(&worker, &master, receiver)),
            ) {
                abandon(&shared, pid, true);
                return Err(error);
            }
        }
        Ok(Self {
            shared,
            master: Some(master),
            input: Some(sender),
            pid,
        })
    }

    pub fn process_id(&self) -> libc::pid_t {
        self.pid
    }
    /// The program has not been seen to exit yet.
    pub fn running(&self) -> bool {
        !self.shared.lock().delivered
    }
    /// Bytes read and not yet taken.
    pub fn buffered_output_bytes(&self) -> usize {
        self.shared.lock().pending.len()
    }
    /// Bytes admitted for writing and not yet written.
    pub fn buffered_input_bytes(&self) -> usize {
        self.shared.lock().input_bytes
    }

    /// Waits until there is output, an exit or a notice to take.
    pub async fn changed(&self) {
        self.shared.notify.notified().await;
    }
    /// A handle that waits like `changed` without borrowing the terminal.
    pub fn waiter(&self) -> TerminalWaiter {
        TerminalWaiter(self.shared.clone())
    }

    /// What arrived, in order: at most `DELIVERY_BYTES` of output, then the
    /// exit once everything written before it has been taken.
    pub fn take_output(&mut self) -> Output {
        let mut state = self.shared.lock();
        let count = state.pending.len().min(DELIVERY_BYTES);
        let bytes: Vec<u8> = state.pending.drain(..count).collect();
        let more = !state.pending.is_empty();
        let mut notices = std::mem::take(&mut state.notices);
        let mut exit = None;
        if !more && state.finished && !state.delivered {
            state.delivered = true;
            state.closed = true;
            state.input_cancelled = true;
            if state.capped {
                notices.push(DRAIN_LIMIT_NOTICE.into());
            }
            exit = state.status;
        }
        drop(state);
        if count > 0 {
            self.shared.changed.notify_all();
        }
        if exit.is_some() {
            self.master = None;
            self.input = None;
        }
        Output {
            bytes,
            more,
            exit,
            notices,
        }
    }

    /// Sends input as one write. A paste the queue cannot take whole is
    /// refused with a notice, never sent in part.
    pub fn write(&mut self, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        let Some(input) = self.input.as_ref() else {
            return;
        };
        {
            let mut state = self.shared.lock();
            if state.closed || state.input_cancelled || state.delivered {
                return;
            }
            if data.len() > INPUT_BYTE_LIMIT - state.input_bytes.min(INPUT_BYTE_LIMIT)
                || state.input_frames >= INPUT_FRAME_LIMIT
            {
                state.notices.push(INPUT_FULL_NOTICE.into());
                drop(state);
                self.shared.notify.notify_one();
                return;
            }
            state.input_bytes += data.len();
            state.input_frames += 1;
        }
        if input.send(data.to_vec()).is_err() {
            let mut state = self.shared.lock();
            state.input_bytes -= data.len();
            state.input_frames -= 1;
        }
    }
    pub fn resize(&mut self, columns: u16, rows: u16) {
        let Some(master) = self.master.as_ref() else {
            return;
        };
        if self.shared.lock().closed {
            return;
        }
        let size = libc::winsize {
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        unsafe {
            libc::ioctl(master.as_raw_fd(), libc::TIOCSWINSZ, &size);
        }
    }
    /// The program has been reaped.
    pub fn reaped(&self) -> bool {
        self.shared.lock().reaped
    }
    /// SIGKILL now, unless the program was already reaped: for the app's
    /// exit, when no thread outlives the process to send the delayed one.
    pub fn kill_now(&mut self) {
        let mut state = self.shared.lock();
        state.input_cancelled = true;
        state.closed = true;
        if !state.reaped && state.pid > 0 {
            unsafe { libc::kill(state.pid, libc::SIGKILL) };
        }
    }
    /// Asks the program to stop (SIGHUP), then kills it if it lingers.
    pub fn terminate(&mut self) {
        let pid = {
            let mut state = self.shared.lock();
            state.input_cancelled = true;
            state.closed = true;
            if state.reaped || state.pid <= 0 || state.terminating {
                return;
            }
            state.terminating = true;
            unsafe { libc::kill(state.pid, libc::SIGHUP) };
            state.pid
        };
        self.input = None;
        let shared = self.shared.clone();
        // The delayed SIGKILL is dropped once the child is reaped, so a recycled pid is never signalled.
        let _ = std::thread::Builder::new()
            .name("bello-pty-kill".into())
            .spawn(move || {
                let deadline = Instant::now() + KILL_DELAY;
                let mut state = shared.lock();
                while !state.reaped {
                    let now = Instant::now();
                    if now >= deadline {
                        unsafe { libc::kill(pid, libc::SIGKILL) };
                        return;
                    }
                    state = shared
                        .changed
                        .wait_timeout(state, deadline - now)
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .0;
                }
            });
    }
}

impl Drop for PseudoTerminal {
    fn drop(&mut self) {
        self.terminate();
        self.shared.lock().stop = true;
        self.shared.changed.notify_all();
    }
}

/// Waits for a terminal's output without holding the terminal.
#[derive(Clone)]
pub struct TerminalWaiter(Arc<Shared>);
impl TerminalWaiter {
    pub async fn changed(&self) {
        self.0.notify.notified().await;
    }
}

/// Ends a child whose terminal could not be set up: stops any worker, kills
/// the child and, when no reaper was started, reaps it here.
fn abandon(shared: &Shared, pid: libc::pid_t, reaper_started: bool) {
    let mut state = shared.lock();
    state.stop = true;
    state.closed = true;
    state.input_cancelled = true;
    if !state.reaped {
        unsafe { libc::kill(pid, libc::SIGKILL) };
        if !reaper_started {
            let mut status = 0;
            while unsafe { libc::waitpid(pid, &mut status, 0) } < 0
                && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR)
            {}
            state.reaped = true;
        }
    }
    drop(state);
    shared.changed.notify_all();
}

fn strerror(code: i32) -> String {
    unsafe {
        let text = libc::strerror(code);
        if text.is_null() {
            return code.to_string();
        }
        std::ffi::CStr::from_ptr(text)
            .to_string_lossy()
            .into_owned()
    }
}

fn poll_fd(fd: RawFd, events: libc::c_short, timeout: i32) -> bool {
    let mut descriptor = libc::pollfd {
        fd,
        events,
        revents: 0,
    };
    let ready = unsafe { libc::poll(&mut descriptor, 1, timeout) };
    ready > 0
}

/// Appends what was read and wakes the owner when this starts a delivery.
fn deliver(shared: &Shared, bytes: &[u8]) {
    let mut state = shared.lock();
    let was_empty = state.pending.is_empty();
    state.pending.extend(bytes);
    drop(state);
    if was_empty {
        shared.notify.notify_one();
    }
}

fn read_loop(shared: &Shared, master: &OwnedFd) {
    let fd = master.as_raw_fd();
    let mut buffer = vec![0u8; DELIVERY_BYTES];
    loop {
        let available = {
            let mut state = shared.lock();
            loop {
                if state.stop {
                    state.reader_done = true;
                    return;
                }
                if state.status.is_some() {
                    break;
                }
                let available = OUTPUT_BYTE_LIMIT - state.pending.len();
                if available > 0 {
                    break;
                }
                state = shared
                    .changed
                    .wait_timeout(state, Duration::from_millis(POLL_INTERVAL_MS as u64))
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .0;
            }
            if state.status.is_some() {
                drop(state);
                final_drain(shared, fd, &mut buffer);
                return;
            }
            OUTPUT_BYTE_LIMIT - state.pending.len()
        };
        if !poll_fd(fd, libc::POLLIN, POLL_INTERVAL_MS) {
            continue;
        }
        let count =
            unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len().min(available)) };
        if count > 0 {
            deliver(shared, &buffer[..count as usize]);
            continue;
        }
        let error = std::io::Error::last_os_error().raw_os_error();
        if count < 0 && matches!(error, Some(libc::EAGAIN) | Some(libc::EINTR)) {
            continue;
        }
        // End of file (or EIO once the slave closes): this terminal's
        // descriptor is no longer written to; the exit finishes it.
        let mut state = shared.lock();
        state.reader_done = true;
        state.closed = true;
        if state.status.is_some() {
            state.finished = true;
            drop(state);
            shared.notify.notify_one();
        }
        return;
    }
}

/// Drains what the child wrote before it exited, within a time and byte cap:
/// a descendant may keep the slave and write after the shell exits.
fn final_drain(shared: &Shared, fd: RawFd, buffer: &mut [u8]) {
    let deadline = Instant::now() + FINAL_DRAIN;
    let mut drained = 0usize;
    let capped;
    loop {
        let available = OUTPUT_BYTE_LIMIT - shared.lock().pending.len();
        if available == 0 || drained >= OUTPUT_BYTE_LIMIT || Instant::now() >= deadline {
            capped = true;
            break;
        }
        let count = unsafe {
            libc::read(
                fd,
                buffer.as_mut_ptr().cast(),
                buffer.len().min(available).min(OUTPUT_BYTE_LIMIT - drained),
            )
        };
        if count > 0 {
            drained += count as usize;
            deliver(shared, &buffer[..count as usize]);
            continue;
        }
        if count < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        capped = false;
        break;
    }
    let mut state = shared.lock();
    state.reader_done = true;
    state.closed = true;
    state.capped = capped;
    state.finished = true;
    drop(state);
    shared.notify.notify_one();
}

fn exit_code(status: libc::c_int) -> i32 {
    if status & 0x7f == 0 {
        (status >> 8) & 0xff
    } else {
        128 + (status & 0x7f)
    }
}

fn wait_loop(shared: &Shared, pid: libc::pid_t) {
    // Wait for the exit without reaping, so terminate's checks under the
    // lock still see a pid that cannot have been recycled.
    loop {
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                pid as libc::id_t,
                &mut info,
                libc::WEXITED | libc::WNOWAIT,
            )
        };
        if result == 0 {
            break;
        }
        if std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            break;
        }
    }
    let mut status: libc::c_int = 0;
    let mut state = shared.lock();
    loop {
        let reaped = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
        if reaped == pid {
            break;
        }
        if reaped < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        if reaped == 0 {
            // Reported before the kernel lets it be reaped: ask again shortly.
            drop(state);
            std::thread::sleep(Duration::from_millis(5));
            state = shared.lock();
            continue;
        }
        // Someone else reaped it (ECHILD): it is gone all the same.
        status = 0;
        break;
    }
    state.reaped = true;
    state.status = Some(exit_code(status));
    state.input_cancelled = true;
    if state.reader_done {
        state.finished = true;
    }
    drop(state);
    shared.changed.notify_all();
    shared.notify.notify_one();
}

fn write_loop(shared: &Shared, master: &OwnedFd, input: mpsc::Receiver<Vec<u8>>) {
    let fd = master.as_raw_fd();
    while let Ok(data) = input.recv() {
        let mut offset = 0;
        while offset < data.len() {
            if shared.lock().input_cancelled {
                break;
            }
            let written =
                unsafe { libc::write(fd, data[offset..].as_ptr().cast(), data.len() - offset) };
            if written > 0 {
                offset += written as usize;
                continue;
            }
            match std::io::Error::last_os_error().raw_os_error() {
                Some(libc::EAGAIN) => {
                    poll_fd(fd, libc::POLLOUT, POLL_INTERVAL_MS);
                }
                Some(libc::EINTR) => {}
                _ => break,
            }
        }
        let mut state = shared.lock();
        state.input_bytes -= data.len();
        state.input_frames -= 1;
    }
}

/// The login shell Swift's TerminalSession.start runs in `directory`: the
/// user's `$SHELL` (zsh when unset or empty) as a login shell, with the app's
/// environment plus the terminal's own variables. Provider credentials never
/// reach the shell: LITELLM* and *_API_KEY variables are removed.
pub fn login_shell(
    directory: &Path,
    environment: impl IntoIterator<Item = (OsString, OsString)>,
    version: &str,
) -> TerminalLaunch {
    let mut map: std::collections::BTreeMap<OsString, OsString> = environment.into_iter().collect();
    let shell = map
        .get(OsStr::new("SHELL"))
        .filter(|value| !value.is_empty())
        .cloned()
        .unwrap_or_else(|| "/bin/zsh".into());
    map.insert("TERM".into(), "xterm-256color".into());
    map.insert("COLORTERM".into(), "truecolor".into());
    map.entry("LANG".into())
        .or_insert_with(|| "en_US.UTF-8".into());
    map.insert("TERM_PROGRAM".into(), "BelloAgent".into());
    map.insert("TERM_PROGRAM_VERSION".into(), version.into());
    map.insert("BELLO_AGENT".into(), "1".into());
    map.retain(|key, _| {
        let key = key.to_string_lossy();
        !(key.starts_with("LITELLM") || key.ends_with("_API_KEY"))
    });
    let name = Path::new(&shell)
        .file_name()
        .map(OsStr::to_os_string)
        .unwrap_or_else(|| shell.clone());
    let mut login = OsString::from("-");
    login.push(name);
    TerminalLaunch {
        executable: PathBuf::from(shell),
        arguments: vec![login, "-l".into()],
        environment: map.into_iter().collect(),
        directory: directory.to_owned(),
    }
}
