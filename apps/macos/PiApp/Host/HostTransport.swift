import Foundation

enum TransportEvent: Sendable { case frame([String: WireValue]), exited(Int32), failed(String) }

// Pipe I/O and parsing remain off the main thread; only Sendable values cross it.
final class HostTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.belloware.PiApp.host", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
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

    init(capture: (@Sendable ([String: WireValue]) async throws -> Void)? = nil, receive: @escaping @Sendable (TransportEvent) -> Void) { self.capture = capture; self.receive = receive }
    func start(executable: URL, arguments: [String], entry: URL? = nil, cwd: URL, environment: [String: String]) {
        queue.async { [self] in
            guard process == nil else { return }
            let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            child.executableURL = executable; child.arguments = arguments + (entry.map { [$0.path] } ?? [])
            child.currentDirectoryURL = cwd; child.environment = environment
            child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
            input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; errorOutput = stderr.fileHandleForReading
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                self?.queue.sync { [weak self] in self?.consume(bytes) }
            }
            // Never forward raw subprocess diagnostics to the UI or telemetry.
            stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
            child.terminationHandler = { [weak self] child in
                let status = child.terminationStatus
                self?.queue.async { [weak self] in self?.captureEnded(); self?.closeHandles(); self?.process = nil; self?.receive(.exited(status)) }
            }
            do { try child.run(); process = child }
            catch { closeHandles(); receive(.failed("The bundled host could not start. Reinstall this build.")) }
        }
    }
    func send(_ frame: [String: WireValue]) {
        sendLock.lock()
        guard pendingCommands < 32 || frame["method"]?.string == "turn.stop" || frame["kind"]?.string == "capture.ack" else { sendLock.unlock(); receive(.failed("The host command queue is full.")); return }
        pendingCommands += 1; sendLock.unlock()
        queue.async { [self] in
            defer { sendLock.lock(); pendingCommands -= 1; sendLock.unlock() }
            do {
                var bytes = try JSONEncoder().encode(frame)
                guard bytes.count <= HostFrameDecoder.maximum else { throw WireError.oversized }
                bytes.append(10)
                guard let input else { throw WireError.invalid }
                try input.write(contentsOf: bytes)
            } catch { receive(.failed("The host connection was interrupted. No command was replayed.")) }
        }
    }
    func stop() {
        queue.async { [self] in
            try? input?.close(); input = nil
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
        try? input?.close(); try? output?.close(); try? errorOutput?.close()
        input = nil; output = nil; errorOutput = nil
    }
}
