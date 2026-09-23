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
    private var pending = PendingOutput()
    private var reader: TerminalReadControl?
    private var exitWatcher: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "com.belloware.PiApp.pty", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "com.belloware.PiApp.pty.input", qos: .userInitiated)
    var onData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onNotice: ((String) -> Void)?
    var bufferedOutputBytes: Int { pending.count }
    var bufferedInputBytes: Int { inputLifetime.retainedBytes }

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
        // A forked child keeps every descriptor the app has open that is not
        // marked close-on-exec, and Foundation's pipes are not: the shell and
        // everything started from it held the helper's stdin, so a helper
        // stopped by closing it never saw it end. The child keeps its terminal
        // alone, closing every other number below this bound, which is read
        // before the fork like everything else the child uses.
        let descriptorLimit = getdtablesize()
        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, &size)
        if pid == 0 {
            // Child: nothing but the terminal, the shell's own signal dispositions, its directory, then the program.
            var descriptor: Int32 = 3
            while descriptor < descriptorLimit { _ = close(descriptor); descriptor += 1 }
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
        pending = PendingOutput()
        let pending = pending
        processID = pid; master = masterFD; running = true
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
                guard pending.append(Data(buffer[0..<count])) else { return }
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
    func append(_ bytes: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard bytes.count <= Self.byteLimit - data.count else { return false }
        data.append(bytes)
        guard !scheduled else { return false }
        scheduled = true; return true
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
