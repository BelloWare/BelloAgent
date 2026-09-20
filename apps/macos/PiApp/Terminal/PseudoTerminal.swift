import Foundation
import Darwin

/// A shell (or any program) on a pseudo-terminal: forkpty gives the child a
/// session of its own with the slave as its controlling terminal, so job
/// control, ^C and window-size changes work as in any terminal. Output is read
/// off the main thread and delivered on the main actor in the order it arrived.
@MainActor final class PseudoTerminal {
    enum Failure: Error, LocalizedError {
        case spawn(Int32)
        var errorDescription: String? {
            switch self { case .spawn(let code): return "Could not start the shell (\(String(cString: strerror(code))))" }
        }
    }

    private(set) var processID: pid_t = 0
    private(set) var running = false
    private var pendingKill: DispatchWorkItem?
    private var generation = UUID()
    private var inputLifetime = TerminalInputLifetime()
    private var master: Int32 = -1
    private let pending = PendingOutput()
    private var reader: DispatchSourceRead?
    private var exitWatcher: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "com.belloware.PiApp.pty", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "com.belloware.PiApp.pty.input", qos: .userInitiated)
    var onData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    /// Starts `executable` with `arguments` (argv[0] included) in `directory`
    /// with exactly this environment, on a terminal of the given size.
    func start(executable: String, arguments: [String], environment: [String: String], directory: String, columns: Int, rows: Int) throws {
        guard !running else { throw Failure.spawn(EBUSY) }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        // Everything the child needs is prepared before the fork: only async-signal-safe calls happen in between.
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let path = strdup(executable)
        let cwd = strdup(directory)
        defer { argv.forEach { free($0) }; envp.forEach { free($0) }; free(path); free(cwd) }
        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, &size)
        if pid == 0 {
            // Child: the shell's own signal dispositions, its directory, then the program.
            var signals = sigset_t()
            sigemptyset(&signals)
            sigprocmask(SIG_SETMASK, &signals, nil)
            for signal in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGCHLD, SIGHUP, SIGTSTP, SIGTTIN, SIGTTOU] { Darwin.signal(signal, SIG_DFL) }
            if let cwd { _ = chdir(cwd) }
            execve(path, argv, envp)
            _exit(127)
        }
        guard pid > 0 else { throw Failure.spawn(errno) }
        let attempt = UUID(); generation = attempt; inputLifetime = TerminalInputLifetime()
        pending.reset()
        let pending = pending
        processID = pid; master = masterFD; running = true
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)
        let reader = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        // DispatchSource's callback API does not infer Sendable here. Spell it
        // out so callbacks created on the main actor remain nonisolated when
        // Dispatch invokes them on the terminal queue.
        reader.setEventHandler { @Sendable [weak self, masterFD] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = read(masterFD, &buffer, buffer.count)
            if count > 0 {
                // A pty hands back whatever the driver has, which under a fast
                // writer is a few dozen bytes at a time: a hop to the main
                // thread each would be twenty thousand hops for one command.
                // Bytes waiting for a delivery already scheduled join it, in
                // arrival order, and no second delivery is scheduled.
                guard pending.append(Data(buffer[0..<count])) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    let chunk = pending.take()
                    guard self.generation == attempt, !chunk.isEmpty else { return }
                    self.onData?(chunk)
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
        self.reader = reader
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
    }
    private func finished(_ pid: pid_t, attempt: UUID) {
        guard running, generation == attempt else { return }
        var status: Int32 = 0, reaped: pid_t
        repeat { reaped = waitpid(pid, &status, WNOHANG) } while reaped < 0 && errno == EINTR
        guard reaped != 0 else { return }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        running = false
        inputLifetime.cancel()
        exitWatcher?.setEventHandler(handler: nil); exitWatcher?.cancel(); exitWatcher = nil
        pendingKill?.cancel(); pendingKill = nil
        // Drain what the child wrote before it exited, then close.
        let oldReader = reader.map { TerminalReaderTransfer(source: $0) }, oldMaster = reader == nil ? -1 : master
        reader = nil; master = -1
        queue.async { @Sendable [self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var tail = Data()
            while oldMaster >= 0 { let count = read(oldMaster, &buffer, buffer.count); if count <= 0 { break }; tail.append(contentsOf: buffer[0..<count]) }
            oldReader?.source.cancel()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == attempt else { return }
                    // Whatever was waiting for a delivery comes first, then the
                    // last bytes the child wrote, then the exit.
                    let queued = self.pending.take() + tail
                    if !queued.isEmpty { self.onData?(queued) }
                    self.onExit?(code)
                }
            }
        }
    }

    func write(_ data: Data) {
        guard running, master >= 0, !data.isEmpty, !inputLifetime.isCancelled else { return }
        // A large paste must not prevent output draining, exit observation or
        // the forced-stop deadline. Own a duplicate so a delayed write cannot
        // hit a descriptor reused by a restarted terminal or another file.
        let fd = fcntl(master, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { return }
        let lifetime = inputLifetime
        writeQueue.async { @Sendable in
            defer { close(fd) }
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
}

// A one-way transfer after the main actor clears `reader`: the terminal queue
// drains its descriptor, then cancels this source. No actor accesses it again.
private struct TerminalReaderTransfer: @unchecked Sendable {
    let source: DispatchSourceRead
}

// Queued pastes relinquish their duplicated descriptors promptly on exit or
// Stop, including when a surviving child still has the slave terminal open.
// Bytes read from the terminal that have not reached the main actor yet. One
// delivery is scheduled at a time; everything read meanwhile joins it in order.
private final class PendingOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var scheduled = false
    /// Adds bytes; true when the caller must schedule the delivery.
    func append(_ bytes: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        data.append(bytes)
        guard !scheduled else { return false }
        scheduled = true; return true
    }
    /// Everything waiting, leaving nothing scheduled.
    func take() -> Data {
        lock.lock(); defer { lock.unlock() }
        let value = data; data = Data(); scheduled = false
        return value
    }
    func reset() { lock.lock(); data = Data(); scheduled = false; lock.unlock() }
}

/// Whether the write this owns is still wanted. Set from the terminal queue,
/// read from the main actor, and every access goes through the lock below.
private final class TerminalInputLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
