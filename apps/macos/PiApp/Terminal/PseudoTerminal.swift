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
    private var master: Int32 = -1
    private var reader: DispatchSourceRead?
    private var exitWatcher: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "com.belloware.PiApp.pty", qos: .userInteractive)
    var onData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    /// Starts `executable` with `arguments` (argv[0] included) in `directory`
    /// with exactly this environment, on a terminal of the given size.
    func start(executable: String, arguments: [String], environment: [String: String], directory: String, columns: Int, rows: Int) throws {
        precondition(!running, "A pseudo-terminal runs one process")
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
        processID = pid; master = masterFD; running = true
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)
        let reader = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        reader.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = read(masterFD, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[0..<count])
                // The main queue keeps chunks in arrival order, which a Task per chunk would not promise.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onData?(data) } }
            } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.reader?.cancel(); self?.reader = nil } }
            }
        }
        reader.setCancelHandler { close(masterFD) }
        reader.resume()
        self.reader = reader
        let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        watcher.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(code) } }
        }
        watcher.resume()
        exitWatcher = watcher
    }
    private func finished(_ code: Int32) {
        guard running else { return }
        running = false
        exitWatcher?.cancel(); exitWatcher = nil
        // Drain what the child wrote before it exited, then close.
        queue.async { [weak self, master] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var tail = Data()
            while master >= 0 { let count = read(master, &buffer, buffer.count); if count <= 0 { break }; tail.append(contentsOf: buffer[0..<count]) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !tail.isEmpty { self?.onData?(tail) }
                    self?.reader?.cancel(); self?.reader = nil
                    self?.onExit?(code)
                }
            }
        }
    }

    func write(_ data: Data) {
        guard running, master >= 0, !data.isEmpty else { return }
        let fd = master
        queue.async {
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if written > 0 { offset += written }
                    else if written < 0 && errno == EAGAIN { usleep(500) }
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
        kill(processID, SIGHUP)
        let pid = processID
        queue.asyncAfter(deadline: .now() + 2) { kill(pid, SIGKILL) }
    }
}
