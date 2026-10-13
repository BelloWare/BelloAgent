import Foundation
import Darwin

/// A shell (or any program) on a pseudo-terminal: forkpty gives the child a
/// session of its own with the slave as its controlling terminal, so job
/// control, ^C and window-size changes work as in any terminal. Output is read
/// off the main thread and delivered on the main actor in the order it arrived.
@MainActor final class PseudoTerminal {
    enum Failure: Error, LocalizedError {
        case spawn(Int32), directory(String, Int32), directoryTimeout(String)
        var errorDescription: String? {
            switch self {
            case .spawn(let code): return "Could not start the shell (\(String(cString: strerror(code))))"
            case .directory(let path, let code): return "Could not open terminal in “\(path)” (\(String(cString: strerror(code))))."
            case .directoryTimeout(let path): return "Could not open terminal in “\(path)”: the folder did not respond in time."
            }
        }
    }

    private(set) var processID: pid_t = 0
    private(set) var running = false
    private var pendingKill: DispatchWorkItem?
    private var generation = UUID()
    private var inputLifetime = TerminalInputLifetime()
    private var master: Int32 = -1
    private var pending = PendingOutput()
    private var reader: TerminalReadControl?
    private var exitWatcher: DispatchSourceProcess?
    private var launchPending = false, exitedDuringLaunch = false, launchCancelled = false
    private let queue = DispatchQueue(label: "com.belloware.PiApp.pty", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "com.belloware.PiApp.pty.input", qos: .userInitiated)
    private let launchQueue = DispatchQueue(label: "com.belloware.PiApp.pty.launch", qos: .userInitiated)
    private let launchTimeout: TimeInterval
    /// A C function pointer keeps the post-fork path async-signal-safe, including fixtures.
    private let enterDirectory: @convention(c) (UnsafePointer<CChar>?) -> Int32
    init(launchTimeout: TimeInterval = 5, enterDirectory: @escaping @convention(c) (UnsafePointer<CChar>?) -> Int32 = chdir) {
        self.launchTimeout = launchTimeout; self.enterDirectory = enterDirectory
    }
    var onData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    /// Process ownership ends at reap, before the last output reaches its view.
    var onReap: (() -> Void)?
    var onNotice: ((String) -> Void)?
    /// Reaps the child if it can be reaped now: `waitpid` with `WNOHANG`,
    /// retried on `EINTR`. Zero means "not yet". A seam, so a test can make
    /// the kernel's answer late.
    var reap: (pid_t, UnsafeMutablePointer<Int32>) -> pid_t = PseudoTerminal.reapNow
    nonisolated static func reapNow(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>) -> pid_t {
        var reaped: pid_t
        repeat { reaped = waitpid(pid, status, WNOHANG) } while reaped < 0 && errno == EINTR
        return reaped
    }
    /// How long to wait before asking again when the exit event arrived
    /// before the child could be reaped, in seconds.
    static let reapBackoff: [Double] = [0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.4]
    var bufferedOutputBytes: Int { pending.count }
    var bufferedInputBytes: Int { inputLifetime.retainedBytes }

    /// Starts `executable` with `arguments` (argv[0] included) in `directory`
    /// with exactly this environment, on a terminal of the given size.
    /// Child-side launch failures arrive through onNotice, followed by onExit.
    func start(executable: String, arguments: [String], environment: [String: String], directory: String, columns: Int, rows: Int) throws {
        guard !running else { throw Failure.spawn(EBUSY) }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        // Everything the child needs is prepared before the fork: only async-signal-safe calls happen in between.
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let path = strdup(executable)
        let cwd = strdup(directory)
        defer { argv.forEach { free($0) }; envp.forEach { free($0) }; free(path); free(cwd) }
        guard let path, let cwd, argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else { throw Failure.spawn(ENOMEM) }
        // EOF is exec's acknowledgement; a failure sends its stage and errno.
        // This must come from the child: a parent-side directory check races a
        // rename or permission change, and silently falling back runs elsewhere.
        var launchPipe: [Int32] = [-1, -1]
        guard pipe(&launchPipe) == 0 else { throw Failure.spawn(errno) }
        defer { for fd in launchPipe where fd >= 0 { close(fd) } }
        for index in launchPipe.indices {
            if launchPipe[index] < 3 {
                let fd = fcntl(launchPipe[index], F_DUPFD_CLOEXEC, 3)
                guard fd >= 0 else { throw Failure.spawn(errno) }
                close(launchPipe[index]); launchPipe[index] = fd
            }
            guard fcntl(launchPipe[index], F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.spawn(errno) }
        }
        let launchRead = launchPipe[0], launchWrite = launchPipe[1]
        guard fcntl(launchRead, F_SETFL, fcntl(launchRead, F_GETFL) | O_NONBLOCK) == 0 else { throw Failure.spawn(errno) }
        let resetSignals = [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGCHLD, SIGHUP, SIGTSTP, SIGTTIN, SIGTTOU]
        var failure: [Int32] = [0, 0]
        // A forked child keeps every descriptor the app has open that is not
        // marked close-on-exec, and Foundation's pipes are not: the shell and
        // everything started from it held the helper's stdin, so a helper
        // stopped by closing it never saw it end. The child keeps its terminal
        // alone, closing every other number below this bound, which is read
        // before the fork like everything else the child uses.
        let descriptorLimit = getdtablesize()
        let enterDirectory = self.enterDirectory
        var masterFD: Int32 = -1
        // Enter these buffer scopes before fork, so the child never bridges or
        // mutates a Swift array while another thread may hold a runtime lock.
        let pid = argv.withUnsafeBufferPointer { argv in envp.withUnsafeBufferPointer { envp in
            resetSignals.withUnsafeBufferPointer { resetSignals in failure.withUnsafeMutableBytes { report in
                let pid = forkpty(&masterFD, nil, nil, &size)
                if pid == 0 {
                    var descriptor: Int32 = 3
                    while descriptor < descriptorLimit { if descriptor != launchWrite { _ = close(descriptor) }; descriptor += 1 }
                    var signals = sigset_t()
                    sigemptyset(&signals)
                    sigprocmask(SIG_SETMASK, &signals, nil)
                    for index in resetSignals.indices { Darwin.signal(resetSignals[index], SIG_DFL) }
                    var stage: Int32 = 1
                    if enterDirectory(cwd) == 0 { stage = 2; execve(path, argv.baseAddress!, envp.baseAddress!) }
                    let code = errno
                    report.storeBytes(of: stage, as: Int32.self)
                    report.storeBytes(of: code, toByteOffset: MemoryLayout<Int32>.size, as: Int32.self)
                    var sent = 0
                    while sent < report.count {
                        let count = Darwin.write(launchWrite, report.baseAddress! + sent, report.count - sent)
                        if count > 0 { sent += count } else if count < 0 && errno == EINTR { continue } else { break }
                    }
                    _exit(127)
                }
                return pid
            } }
        } }
        guard pid > 0 else { throw Failure.spawn(errno) }
        close(launchWrite); launchPipe[1] = -1
        let attempt = UUID(); generation = attempt; inputLifetime = TerminalInputLifetime()
        pending = PendingOutput()
        let pending = pending
        processID = pid; master = masterFD; running = true
        launchPending = true; exitedDuringLaunch = false; launchCancelled = false
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)
        let reader = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        let control = TerminalReadControl(source: reader)
        // DispatchSource's callback API does not infer Sendable here. Spell it
        // out so callbacks created on the main actor remain nonisolated when
        // Dispatch invokes them on the terminal queue.
        reader.setEventHandler { @Sendable [weak self, masterFD] in
            guard let self else { return }
            guard pending.available > 0 else {
                control.pause()
                // MainActor may have drained between the capacity check and
                // suspend; recheck so that race cannot lose the wakeup.
                if pending.available > 0 { control.resume() }
                return
            }
            var buffer = [UInt8](repeating: 0, count: min(65_536, pending.available))
            let count = read(masterFD, &buffer, buffer.count)
            if count > 0 {
                // A pty hands back whatever the driver has, which under a fast
                // writer is a few dozen bytes at a time: a hop to the main
                // thread each would be twenty thousand hops for one command.
                // Bytes waiting for a delivery already scheduled join it, in
                // arrival order, and no second delivery is scheduled.
                guard pending.append(Data(buffer[0..<count])) == .scheduled else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self.deliver(pending, attempt: attempt, control: control)
                } }
            } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard self.generation == attempt else { return }
                    // Cancelling closes the descriptor, so it stops being this
                    // terminal's: a keystroke or a resize arriving between the
                    // end of the terminal and the child's exit must not reach
                    // whatever file the number has been handed to since.
                    self.master = -1
                    self.reader?.cancel(); self.reader = nil
                } }
            }
        }
        reader.setCancelHandler { @Sendable [masterFD] in close(masterFD) }
        reader.resume()
        self.reader = control
        let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        // The watcher retains this terminal until the child is reaped. A
        // restart can release its UI owner immediately after terminate().
        watcher.setEventHandler { @Sendable [self] in
            // Keep the exited child unreaped until its main-actor state can
            // change with it. Its pid cannot be recycled before terminate's
            // running/generation checks have been invalidated.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(pid, attempt: attempt) } }
        }
        watcher.resume()
        exitWatcher = watcher
        // A network mount can leave chdir waiting forever. Own the child now
        // so Close and Quit work, and wait away from both MainActor and the
        // output queue that schedules terminate's forced stop.
        launchPipe[0] = -1
        let deadline = ProcessInfo.processInfo.systemUptime + launchTimeout
        launchQueue.async { @Sendable [self] in
            let failure = Self.readLaunch(launchRead, directory: directory, deadline: deadline)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard self.running, self.generation == attempt, self.processID == pid else { return }
                self.launchPending = false
                if let failure, !self.launchCancelled {
                    self.inputLifetime.cancel()
                    // Keep the pid owned until the normal watcher reaps it;
                    // even a failed or timed-out launch cannot leave a zombie.
                    kill(-pid, SIGKILL); kill(pid, SIGKILL)
                    self.onNotice?(failure.localizedDescription)
                }
                if self.exitedDuringLaunch { self.finished(pid, attempt: attempt) }
            } }
        }
    }
    private nonisolated static func readLaunch(_ fd: Int32, directory: String, deadline: TimeInterval) -> Failure? {
        // This queue alone closes the descriptor: a timeout must not race a
        // pending read and accidentally read from a reused descriptor number.
        defer { close(fd) }
        var failure: [Int32] = [0, 0], received = 0
        return failure.withUnsafeMutableBytes { report in
            while received < report.count {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return .directoryTimeout(directory) }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = poll(&descriptor, 1, Int32(min(ceil(remaining * 1_000), Double(Int32.max))))
                if ready == 0 { continue }
                if ready < 0 { if errno == EINTR { continue }; return .spawn(errno) }
                let count = read(fd, report.baseAddress! + received, report.count - received)
                if count > 0 { received += count }
                else if count == 0 { return received == 0 ? nil : .spawn(EIO) }
                else if errno != EINTR && errno != EAGAIN { return .spawn(errno) }
            }
            let stage = report.load(as: Int32.self), code = report.load(fromByteOffset: MemoryLayout<Int32>.size, as: Int32.self)
            return stage == 1 ? .directory(directory, code) : .spawn(code)
        }
    }
    private func finished(_ pid: pid_t, attempt: UUID, retry: Int = 0) {
        guard running, generation == attempt else { return }
        // The exit event fires once and can beat the launch packet. Classify
        // that packet before delivering onExit, then replay this observation.
        guard !launchPending else { exitedDuringLaunch = true; return }
        var status: Int32 = 0
        let reaped = reap(pid, &status)
        guard reaped != 0 else {
            // The exit event can arrive before the kernel lets the child be
            // reaped, and it arrives once: returning here left the terminal —
            // and anything waiting on it — running for ever. Ask again, a few
            // times, on the main actor; then wait for the child to become
            // reapable off the main thread without reaping it (WNOWAIT), so
            // it is still reaped here, with the state that says it is gone.
            if retry < Self.reapBackoff.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.reapBackoff[retry]) { MainActor.assumeIsolated {
                    self.finished(pid, attempt: attempt, retry: retry + 1)
                } }
            } else {
                DispatchQueue.global(qos: .utility).async { @Sendable [self] in
                    var info = siginfo_t()
                    while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(pid, attempt: attempt) } }
                }
            }
            return
        }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        running = false
        inputLifetime.cancel()
        exitWatcher?.setEventHandler(handler: nil); exitWatcher?.cancel(); exitWatcher = nil
        pendingKill?.cancel(); pendingKill = nil
        let notify = onReap; onReap = nil; notify?()
        // Drain what the child wrote before it exited, then close.
        let oldReader = reader, oldMaster = reader == nil ? -1 : master
        reader = nil; master = -1
        let pending = pending
        queue.async { @Sendable [self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var drained = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 0.1
            // A descendant may retain the slave and write after the shell exits.
            // The final drain has the same byte cap; it cannot loop forever.
            while oldMaster >= 0, pending.available > 0, drained < PendingOutput.byteLimit, ProcessInfo.processInfo.systemUptime < deadline {
                let count = read(oldMaster, &buffer, min(buffer.count, pending.available, PendingOutput.byteLimit - drained))
                if count <= 0 { break }
                drained += count
                _ = pending.append(Data(buffer.prefix(count)))
            }
            let capped = pending.available == 0 || drained == PendingOutput.byteLimit || ProcessInfo.processInfo.systemUptime >= deadline
            oldReader?.cancel()
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.deliver(pending, attempt: attempt, control: nil) {
                    if capped { self.onNotice?("Terminal output exceeded the final-drain limit after exit; the remaining output was not displayed.") }
                    self.onExit?(code)
                }
            } }
        }
    }

    private func deliver(_ pending: PendingOutput, attempt: UUID, control: TerminalReadControl?, completion: (() -> Void)? = nil) {
        guard generation == attempt else { return }
        let (chunk, more) = pending.take()
        control?.resume()
        if !chunk.isEmpty { onData?(chunk) }
        if more {
            DispatchQueue.main.async { [self] in deliver(pending, attempt: attempt, control: control, completion: completion) }
        } else { completion?() }
    }

    func write(_ data: Data) {
        guard running, master >= 0, !data.isEmpty, !inputLifetime.isCancelled else { return }
        // A large paste must not prevent output draining, exit observation or
        // the forced-stop deadline. Own a duplicate so a delayed write cannot
        // hit a descriptor reused by a restarted terminal or another file.
        let lifetime = inputLifetime
        guard lifetime.reserve(data.count) else {
            onNotice?("Terminal input queue is full. This paste was not sent; wait for the program to read input and try again.")
            return
        }
        let fd = fcntl(master, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { lifetime.release(data.count); return }
        writeQueue.async { @Sendable in
            defer { close(fd); lifetime.release(data.count) }
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count, !lifetime.isCancelled {
                    let written = Darwin.write(fd, base + offset, bytes.count - offset)
                    if written > 0 { offset += written }
                    else if written < 0 && errno == EAGAIN { usleep(500) }
                    else if written < 0 && errno == EINTR { continue }
                    else { break }
                }
            }
        }
    }
    func resize(columns: Int, rows: Int) {
        guard running, master >= 0 else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }
    /// Asks the process to stop, then kills it if it lingers.
    func terminate() {
        guard running, processID > 0 else { return }
        launchCancelled = true
        inputLifetime.cancel()
        kill(processID, SIGHUP)
        let pid = processID, attempt = generation
        // The delayed SIGKILL is dropped once the child is reaped, so a recycled pid is never signalled.
        let work = DispatchWorkItem { @Sendable [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard self.running, self.generation == attempt, self.processID == pid else { return }
                kill(pid, SIGKILL)
            } }
        }
        pendingKill?.cancel(); pendingKill = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// How long Quit waits after SIGHUP before SIGKILL, in seconds.
    static let quitGrace: TimeInterval = 0.05
    /// Ends terminals on the way out of the app. `terminate`'s forced stop is
    /// a timer the app does not live to run, so a program ignoring SIGHUP
    /// outlived it. Each program and its process group get SIGHUP, then all
    /// of them share at most `grace` to exit, then SIGKILL. Nothing is reaped
    /// here: until its exit is handled on the main actor, a child's pid and
    /// group id cannot be handed to another process.
    static func endForQuit(_ terminals: [PseudoTerminal], grace: TimeInterval = quitGrace) {
        let live = terminals.filter { $0.running && $0.processID > 0 }
        for terminal in live {
            terminal.launchCancelled = true
            terminal.inputLifetime.cancel()
            terminal.pendingKill?.cancel(); terminal.pendingKill = nil
            // forkpty made the child a session and group leader: the group is
            // the program and what it started outside its own jobs.
            kill(-terminal.processID, SIGHUP); kill(terminal.processID, SIGHUP)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + grace
        while ProcessInfo.processInfo.systemUptime < deadline, live.contains(where: { !exited($0.processID) }) { usleep(1_000) }
        for terminal in live { kill(-terminal.processID, SIGKILL); kill(terminal.processID, SIGKILL) }
    }
    /// The child has exited, without reaping it.
    private static func exited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        var result: Int32
        repeat { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) } while result < 0 && errno == EINTR
        return result < 0 || info.si_pid == pid
    }
}

/// Source suspension and cancellation are balanced under one lock. Descriptor
/// closure remains in its queue's cancellation handler, after any read returns.
private final class TerminalReadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var paused = false
    init(source: DispatchSourceRead) { self.source = source }
    func pause() { lock.lock(); defer { lock.unlock() }; if let source, !paused { paused = true; source.suspend() } }
    func resume() { lock.lock(); defer { lock.unlock() }; if let source, paused { paused = false; source.resume() } }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if let source { if paused { source.resume() }; source.cancel() }
        source = nil; paused = false
    }
}

/// A bounded byte stream. Full buffers pause the PTY reader (kernel
/// backpressure), not discard bytes in the middle of UTF-8 or escape sequences.
final class PendingOutput: @unchecked Sendable {
    static let byteLimit = 1_048_576
    static let deliveryBytes = 65_536
    private let lock = NSLock()
    private var data = Data()
    private var scheduled = false
    var count: Int { lock.lock(); defer { lock.unlock() }; return data.count }
    var available: Int { Self.byteLimit - count }
    /// What became of bytes handed to `append`.
    enum Appended {
        /// They are waiting, and the caller must schedule their delivery.
        case scheduled
        /// They joined bytes whose delivery is already scheduled.
        case joined
        /// They would pass the limit and were not taken. A reader that reads
        /// at most `available` never sees this: only a delivery frees room.
        case refused
    }
    func append(_ bytes: Data) -> Appended {
        lock.lock(); defer { lock.unlock() }
        guard bytes.count <= Self.byteLimit - data.count else { return .refused }
        data.append(bytes)
        guard !scheduled else { return .joined }
        scheduled = true; return .scheduled
    }
    func take() -> (Data, Bool) {
        lock.lock(); defer { lock.unlock() }
        let value = Data(data.prefix(Self.deliveryBytes)); data.removeFirst(value.count)
        if data.isEmpty { scheduled = false }
        return (value, !data.isEmpty)
    }
}

/// Admit complete pastes before duplicating a descriptor or queuing a closure.
/// Backpressure never partially enqueues a paste or blocks MainActor.
final class TerminalInputLifetime: @unchecked Sendable {
    static let byteLimit = 2_097_152, frameLimit = 32
    private let lock = NSLock()
    private var cancelled = false, bytes = 0, frames = 0
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var retainedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    func reserve(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, count >= 0, count <= Self.byteLimit - bytes, frames < Self.frameLimit else { return false }
        bytes += count; frames += 1; return true
    }
    func release(_ count: Int) { lock.lock(); bytes -= count; frames -= 1; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
