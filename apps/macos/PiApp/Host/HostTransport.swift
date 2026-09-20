import Foundation
import Darwin

enum TransportEvent: Sendable { case frame([String: WireValue]), exited(Int32), failed(String) }

// Pipe I/O and parsing remain off the main thread; only Sendable values cross it.
final class HostTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.belloware.PiApp.host", qos: .userInitiated)
    private var process: Process?
    private var input: HostPipeWriter?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var decoder = HostFrameDecoder()
    private let receive: @Sendable (TransportEvent) -> Void
    private let sendLock = NSLock()
    private var pendingCommands = 0
    private let capture: (@Sendable ([String: WireValue]) async throws -> Void)?
    private var captureTask: Task<Void, Never>?
    private var capturePending = false
    private var hostEpoch: String?
    private var stopping = false

    init(capture: (@Sendable ([String: WireValue]) async throws -> Void)? = nil, receive: @escaping @Sendable (TransportEvent) -> Void) { self.capture = capture; self.receive = receive }
    /// The helper this transport started, for tests that need to end exactly
    /// that process and no other. Nil before start and after exit.
    var processIdentifier: Int32? { queue.sync { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } } }
    func start(executable: URL, arguments: [String], entry: URL? = nil, cwd: URL, environment: [String: String]) {
        queue.async { [self] in
            guard process == nil else { return }
            let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            child.executableURL = executable; child.arguments = arguments + (entry.map { [$0.path] } ?? [])
            child.currentDirectoryURL = cwd; child.environment = environment
            child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
            input = HostPipeWriter(handle: stdin.fileHandleForWriting, queue: queue,
                                   completed: { [weak self] counted in self?.commandWritten(counted: counted) },
                                   failed: { [weak self] in self?.receive(.failed("The host connection was interrupted. No command was replayed.")) })
            output = stdout.fileHandleForReading; errorOutput = stderr.fileHandleForReading
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                // Drained on the handle's own thread and handed to the serial queue without
                // waiting on it: a stdin write blocked on a full pipe must never stop stdout
                // from being read, or both processes wait on each other forever.
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil }
                self?.queue.async { [weak self] in self?.consume(bytes) }
            }
            // Never forward raw subprocess diagnostics to the UI or telemetry.
            stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
            child.terminationHandler = { [weak self] child in
                let status = child.terminationStatus
                self?.queue.async { [weak self] in self?.stopping = true; self?.captureEnded(); self?.closeHandles(); self?.process = nil; self?.receive(.exited(status)) }
            }
            do { try child.run(); process = child }
            catch {
                stopping = true
                closeHandles(); receive(.failed("The bundled host could not start. Reinstall this build."))
                // A failed spawn has no termination handler. Still release the
                // supervisor's connection and writer lock so it can reconnect.
                receive(.exited(127))
            }
        }
    }
    func send(_ frame: [String: WireValue]) {
        let counted = frame["method"]?.string != "turn.stop" && frame["kind"]?.string != "capture.ack"
        sendLock.lock()
        // Capture acknowledgments and Stop already have separate admission.
        // They must not consume the ordinary slots and reject the 32nd command.
        guard !counted || pendingCommands < 32 else { sendLock.unlock(); receive(.failed("The host command queue is full.")); return }
        if counted { pendingCommands += 1 }; sendLock.unlock()
        queue.async { [self] in
            guard !stopping else { commandWritten(counted: counted); return }
            do {
                guard let input else { throw WireError.invalid }
                var bytes = try JSONEncoder().encode(frame)
                guard bytes.count <= HostFrameDecoder.maximum else { throw WireError.oversized }
                bytes.append(10)
                input.append(bytes, counted: counted)
            } catch { commandWritten(counted: counted); receive(.failed("The host connection was interrupted. No command was replayed.")) }
        }
    }
    private func commandWritten(counted: Bool) {
        guard counted else { return }; sendLock.lock(); pendingCommands -= 1; sendLock.unlock()
    }
    func stop() {
        queue.async { [self] in
            guard !stopping else { return }; stopping = true
            input?.close(); input = nil
            let child = process
            queue.asyncAfter(deadline: .now() + 3.5) { if child?.isRunning == true { child?.terminate() } }
            queue.asyncAfter(deadline: .now() + 5) { if let child, child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) } }
        }
    }
    private func consume(_ bytes: Data) {
        do {
            if bytes.isEmpty { try decoder.finish(); output?.readabilityHandler = nil; return }
            for frame in try decoder.append(bytes) {
                if frame["kind"]?.string == "ready" { hostEpoch = frame["hostEpoch"]?.string }
                if frame["kind"]?.string == "capture" { receiveCapture(frame) }
                else { receive(.frame(frame)) }
            }
        } catch { receive(.failed("The bundled host sent an invalid or oversized frame.")); process?.terminate() }
    }
    private func receiveCapture(_ frame: [String: WireValue]) {
        guard frame["v"]?.number == 1, frame["hostEpoch"]?.string == hostEpoch,
              let id = frame["transferId"]?.string, UUID(uuidString: id) != nil, var packet = frame["packet"]?.object else { return }
        let epoch = frame["hostEpoch"] ?? .null
        guard let capture, !capturePending else { acknowledgeCapture(id, epoch: epoch, accepted: false); return }
        if var metadata = packet["metadata"]?.object { metadata["hostEpoch"] = epoch; packet["metadata"] = .object(metadata) }
        let value = packet; capturePending = true
        captureTask = Task { [self] in
            let accepted: Bool
            do { try await capture(value); accepted = true } catch { accepted = false }
            queue.async { [self] in
                capturePending = false; captureTask = nil
                if process?.isRunning == true { acknowledgeCapture(id, epoch: epoch, accepted: accepted) }
            }
        }
    }
    private func acknowledgeCapture(_ id: String, epoch: WireValue, accepted: Bool) {
        send(["v": .number(1), "kind": .string("capture.ack"), "hostEpoch": epoch, "transferId": .string(id), "accepted": .bool(accepted)])
    }
    private func captureEnded() {
        guard let capture, let epoch = hostEpoch else { return }
        let pending = captureTask
        Task { await pending?.value; try? await capture(["type": .string("interrupted"), "hostEpoch": .string(epoch)]) }
    }
    private func closeHandles() {
        output?.readabilityHandler = nil; errorOutput?.readabilityHandler = nil
        input?.close(); try? output?.close(); try? errorOutput?.close()
        input = nil; output = nil; errorOutput = nil
    }
}

// The pipe may be full while the helper is busy or failing. A nonblocking
// writer leaves the transport queue free to parse replies, acknowledge capture
// pages and run the shutdown deadlines. All methods run on that serial queue.
private final class HostPipeWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let completed: @Sendable (Bool) -> Void
    private let failed: @Sendable () -> Void
    private var source: DispatchSourceWrite?
    private var resumed = false
    private var pending: [(bytes: Data, counted: Bool)] = []
    private var offset = 0

    init(handle: FileHandle, queue: DispatchQueue, completed: @escaping @Sendable (Bool) -> Void, failed: @escaping @Sendable () -> Void) {
        self.handle = handle; self.completed = completed; self.failed = failed
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.flush() }
        source.setCancelHandler { try? handle.close() }
        self.source = source
    }
    func append(_ bytes: Data, counted: Bool) {
        guard source != nil else { completed(counted); failed(); return }
        pending.append((bytes, counted)); flush()
    }
    private func flush() {
        guard let source else { return }
        while let entry = pending.first {
            let bytes = entry.bytes
            // A frame is never empty, so the buffer always has a base address;
            // an empty one would read as a failed write rather than crash.
            let written = bytes.withUnsafeBytes { buffer in
                buffer.baseAddress.map { Darwin.write(handle.fileDescriptor, $0 + offset, bytes.count - offset) } ?? 0
            }
            if written > 0 {
                offset += written
                if offset == bytes.count { pending.removeFirst(); offset = 0; completed(entry.counted) }
            } else if written < 0 && errno == EINTR { continue }
            else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if !resumed { resumed = true; source.resume() }
                return
            } else { close(); failed(); return }
        }
        if resumed { resumed = false; source.suspend() }
    }
    func close() {
        guard let source else { return }
        self.source = nil
        for entry in pending { completed(entry.counted) }
        pending.removeAll(); offset = 0
        if !resumed { source.resume() }
        source.cancel()
    }
    deinit { close() }
}
