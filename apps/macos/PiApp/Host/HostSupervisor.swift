import AppKit
import Combine

enum HostError: LocalizedError {
    case failure(String)
    case rejected(String, String)
    var errorDescription: String? { switch self { case .failure(let message), .rejected(_, let message): message } }
}

@MainActor
final class HostSupervisor: ObservableObject {
    @Published private(set) var status = "Runtime stopped"
    @Published private(set) var isReady = false
    @Published var isBusy = false
    private(set) var epoch: String?
    var onEvent: (([String: WireValue]) -> Void)?
    var onLoss: (() -> Void)?
    private var transport: HostTransport?
    /// The running helper's pid, for tests that kill their own helper.
    var helperProcessIdentifier: Int32? { transport?.processIdentifier }
    private(set) var connectionID: UUID?
    private var ownership: WorkspaceLock?
    private var replies: [String: CheckedContinuation<WireValue, Error>] = [:]
    // A timed-out caller no longer has a continuation, but its helper task
    // still occupies capacity until a late reply or host loss reconciles it.
    private var outstandingCommands: Set<String> = []
    private var replyTimeouts: [String: Task<Void, Never>] = [:]
    private struct QueuedRequest {
        let id: String, method: String
        let cancellation: HostCommandCancellation
        let frame: [String: WireValue]
        let continuation: CheckedContinuation<WireValue, Error>
    }
    private var queuedRequests: [QueuedRequest] = []
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    /// Connections waiting for a stopping helper to exit.
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private func resumeExitWaiters() { let waiters = exitWaiters; exitWaiters.removeAll(); for waiter in waiters { waiter.resume() } }
    private var handshakeWatchdog: Task<Void, Never>?
    private var closing = false
    private(set) var clockOffset = 0.0
    private let commandSender: (@MainActor ([String: WireValue]) -> Void)?
    private let acknowledgmentTimeout: Duration?
    var queuedCommandCount: Int { queuedRequests.count }
    /// Test seam: every answered request — what was asked and the result as
    /// the caller received it, display transfers already reassembled. Nil in
    /// the app, where it costs one comparison per reply.
    var requestObserver: ((_ method: String, _ params: [String: WireValue], _ result: WireValue) -> Void)?

    // Dependency injection keeps admission/timeout races deterministic in
    // tests. Production commands always use the connected native transport.
    init(commandSender: (@MainActor ([String: WireValue]) -> Void)? = nil, acknowledgmentTimeout: Duration? = nil) {
        self.commandSender = commandSender; self.acknowledgmentTimeout = acknowledgmentTimeout
    }

    func connect(cwd: URL, state: URL, runtime: RuntimePreferences = RuntimePreferences(), capture: (@Sendable ([String: WireValue]) async throws -> Void)? = nil) async throws {
        if isReady { return }
        if closing {
            // The app stops idle helpers on its own. Sending the next message
            // inside that window must start a fresh helper, not report that the
            // host "is stopping". The previous transport always reaches its
            // exit: stop() terminates and then kills it on its own deadlines.
            guard transport != nil else { throw HostError.failure("Project host is stopping") }
            // Its exit resumes this at once (see `receive`); the deadline is
            // only a backstop, since stop() kills the helper within five seconds.
            let backstop = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8)); self?.resumeExitWaiters()
            }
            await withCheckedContinuation { exitWaiters.append($0) }
            backstop.cancel()
            try Task.checkCancellation()
            if isReady { return }
            guard !closing else { throw HostError.failure("The previous project host did not exit. Try again.") }
        }
        if transport == nil {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            do { ownership = try WorkspaceLock(url: state.appendingPathComponent("writer.lock")) }
            catch { throw HostError.failure("This project already has an app writer. Close its other Bello Agent instance first.") }
            guard let resources = Bundle.main.resourceURL else { ownership = nil; throw HostError.failure("Application resources are missing") }
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pi-native-host")
            struct Manifest: Decodable { let engine: String; let engineVersion: String; let protocolMajor: Int }
            guard FileManager.default.isExecutableFile(atPath: helper.path),
                  let bytes = try? Data(contentsOf: resources.appendingPathComponent("Host/bundle-manifest.json")),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes),
                  manifest.engine == "swift", manifest.engineVersion == "1.0.0", manifest.protocolMajor == 1 else {
                ownership = nil; throw HostError.failure("The native host or its manifest is missing or incompatible. Reinstall this build.")
            }
            let connectionID = UUID(); self.connectionID = connectionID
            let inbox = HostInbox { [weak self] events in
                for event in events { self?.receive(event, connectionID: connectionID) }
            }
            let connection = HostTransport(capture: capture) { event in inbox.enqueue(event) }
            transport = connection; status = "Starting native runtime…"
            let environment = [
                "HOME": NSHomeDirectory(), "PATH": runtime.toolsPATH,
                "LANG": "en_US.UTF-8", "TMPDIR": ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory(),
                "PI_APP_VERSION": ReleaseConfiguration.current.version,
                "PI_APP_BENCHMARK": PerformanceProbe.shared.enabled ? "1" : "0"
            ]
            // The vault supplies only tool search paths here; credentials use private IPC.
            connection.start(executable: helper, arguments: [], cwd: cwd, environment: environment)
            // `unknownToolOutcomes`: this app reads a call stopped while it ran
            // as "unknown" (TranscriptActivity.outcome). Without it the helper
            // sends such a call as "cancelled" live and "failed" once saved.
            connection.send(["v": .number(1), "kind": .string("hello"), "major": .number(1), "minor": .number(1), "displayTransfers": .bool(true),
                             "unknownToolOutcomes": .bool(true), "build": .string(ReleaseConfiguration.current.build)])
        }
        let attempt = transport
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
            // One watchdog per connection attempt, dropped as soon as the handshake lands
            // or the attempt fails: a stale one must never shoot down a later, healthy host.
            handshakeWatchdog?.cancel()
            handshakeWatchdog = Task { [weak self, weak attempt] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, let attempt, self.transport === attempt, !self.isReady else { return }
                self.fail("The native host did not complete its handshake"); self.shutdown()
            }
        }
    }
    func request(_ method: String, sessionID: String? = nil, params: [String: WireValue] = [:], commandID: String = UUID().uuidString) async throws -> WireValue {
        let connection = connectionID
        let result = try await requestFrame(method, sessionID:sessionID, params:params, commandID:commandID)
        guard result.object?["_displayTransfer"]?.number == 1 else { requestObserver?(method, params, result); return result }
        let whole = try await DisplayResultReader.read(result) { [self] id, offset in
            try await readDisplayTransfer(id, offset:offset, connection:connection)
        }
        requestObserver?(method, params, whole)
        return whole
    }
    private func readDisplayTransfer(_ id: String, offset: Int, connection: UUID?) async throws -> WireValue {
        guard connectionID == connection else { throw HostError.failure("The helper changed while loading the conversation. Reload it to continue.") }
        return try await requestFrame("display.result.read", params:["id":.string(id),"offset":.number(Double(offset))])
    }
    private func requestFrame(_ method: String, sessionID: String? = nil, params: [String: WireValue] = [:], commandID: String = UUID().uuidString) async throws -> WireValue {
        try Task.checkCancellation()
        guard isReady, !closing, let epoch, !outstandingCommands.contains(commandID),
              !queuedRequests.contains(where: { $0.id == commandID }),
              queuedRequests.count < 128 || method == "turn.stop" else { throw HostError.failure("Host is unavailable or its command queue is full") }
        let cancellation = HostCommandCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                var frame: [String: WireValue] = ["v": .number(1), "kind": .string("command"), "hostEpoch": .string(epoch), "commandId": .string(commandID), "method": .string(method), "params": .object(params)]
                if let sessionID { frame["sessionId"] = .string(sessionID) }
                let request = QueuedRequest(id: commandID, method: method, cancellation: cancellation, frame: frame, continuation: continuation)
                // Stop must reach a running command even when every normal
                // slot is occupied. Other bursts wait FIFO for helper capacity.
                if method == "turn.stop" { dispatch(request) }
                else { queuedRequests.append(request); dispatchQueuedRequests() }
            }
        } onCancel: { [weak self] in
            // Mark synchronously: a reply can free a slot before the scheduled
            // main-actor cleanup gets its turn.
            cancellation.cancel()
            Task { @MainActor in self?.cancelQueuedRequest(commandID, cancellation: cancellation) }
        }
    }
    private func dispatchQueuedRequests() {
        guard isReady, !closing else { return }
        while outstandingCommands.count < 32, !queuedRequests.isEmpty { dispatch(queuedRequests.removeFirst()) }
    }
    private func dispatch(_ request: QueuedRequest) {
        guard !request.cancellation.isCancelled else { request.continuation.resume(throwing: CancellationError()); return }
        outstandingCommands.insert(request.id)
        replies[request.id] = request.continuation
        if let commandSender { commandSender(request.frame) } else { transport?.send(request.frame) }
        // Queueing time is not an uncertain dispatched outcome. Start this
        // deadline only when the command has entered its transport slot.
        let timeout = acknowledgmentTimeout ?? .seconds(request.method.hasPrefix("mcp.") ? 315 : 30)
        replyTimeouts[request.id] = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self else { return }
            self.replyTimeouts.removeValue(forKey: request.id)
            self.replies.removeValue(forKey: request.id)?.resume(throwing: HostError.failure("Acknowledgment timed out. Outcome uncertain; this command was not resent."))
        }
    }
    private func cancelQueuedRequest(_ id: String, cancellation: HostCommandCancellation) {
        guard let index = queuedRequests.firstIndex(where: { $0.id == id && $0.cancellation === cancellation }) else { return }
        queuedRequests.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    func shutdown() {
        closing = true; isReady = false
        // A watchdog belongs to the attempt being stopped. Leaving it armed
        // lets a deliberate stop surface as a handshake failure ten seconds later.
        handshakeWatchdog?.cancel(); handshakeWatchdog = nil
        for request in queuedRequests { request.continuation.resume(throwing: HostError.failure("Host stopped before this queued command was dispatched.")) }
        queuedRequests.removeAll()
        // Without a transport there is no exit event to clear `closing`, and
        // this supervisor would refuse every later connection for good.
        if let transport { transport.stop() } else { closing = false }
    }
    func calibrateClock() async throws {
        var best = Double.infinity
        for _ in 0..<5 {
            let start = PerformanceProbe.now, result = try await request("clock.sync").object ?? [:], end = PerformanceProbe.now
            if let host = result["monotonic"]?.number, end - start < best { best = end - start; clockOffset = (start + end) / 2 - host }
        }
        PerformanceProbe.shared.observe("clockCalibrationUncertaintyMs", milliseconds: best / 2)
    }
    func shutdownAndWait() async throws {
        shutdown()
        for _ in 0..<300 { if transport == nil { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw HostError.failure("The project host did not exit. Update installation was cancelled.")
    }
    private func fail(_ message: String) {
        status = message; isReady = false; isBusy = false
        handshakeWatchdog?.cancel(); handshakeWatchdog = nil
        let error = HostError.failure(message)
        for waiter in readyWaiters { waiter.resume(throwing: error) }; readyWaiters.removeAll()
        for reply in replies.values { reply.resume(throwing: error) }; replies.removeAll()
        outstandingCommands.removeAll()
        for request in queuedRequests { request.continuation.resume(throwing: error) }; queuedRequests.removeAll()
        for timeout in replyTimeouts.values { timeout.cancel() }; replyTimeouts.removeAll()
        onLoss?()
    }
    // Reads and process exit arrive from independent callbacks. A late event
    // from a retired pipe must never resurrect it or close its replacement.
    func receive(_ event: TransportEvent, connectionID: UUID) {
        guard self.connectionID == connectionID else { return }
        switch event {
        case .failed(let message):
            guard !closing else { return }
            fail(message); shutdown()
        case .exited(let code):
            self.connectionID = nil
            fail(code == 0 ? "Runtime stopped" : "Runtime interrupted (\(code)). No request was replayed.")
            transport = nil; ownership = nil; epoch = nil; closing = false
            resumeExitWaiters()
        case .frame(let frame):
            guard !closing, transport != nil else { return }
            guard frame["v"]?.number == 1 else { fail("Incompatible host protocol"); shutdown(); return }
            if frame["kind"]?.string == "ready" {
                let capabilities = Set(frame["capabilities"]?.array?.compactMap(\.string) ?? [])
                guard frame["major"]?.number == 1, frame["engine"]?.string == "swift", frame["engineVersion"]?.string == "1.0.0",
                      Set(["responses", "mcp", "steering", "transport-capture"]).isSubset(of: capabilities),
                      let hostEpoch = frame["hostEpoch"]?.string else { fail("Packaged native runtime version or capability mismatch"); shutdown(); return }
                epoch = hostEpoch; isReady = true; status = "Ready · Swift"
                handshakeWatchdog?.cancel(); handshakeWatchdog = nil
                for waiter in readyWaiters { waiter.resume() }; readyWaiters.removeAll(); return
            }
            guard frame["hostEpoch"]?.string == epoch else { return }
            if frame["kind"]?.string == "reply", let id = frame["commandId"]?.string, outstandingCommands.remove(id) != nil {
                defer { dispatchQueuedRequests() }
                replyTimeouts.removeValue(forKey: id)?.cancel()
                let continuation = replies.removeValue(forKey: id)
                if frame["ok"] == .bool(true) { continuation?.resume(returning: frame["result"] ?? .object([:])) }
                else { continuation?.resume(throwing: HostError.rejected(frame["result"]?.object?["code"]?.string ?? "unknown", frame["result"]?.object?["message"]?.string ?? "Host command failed")) }
            } else { onEvent?(frame) }
        }
    }
}

/// One flag, read by the main actor and set by a cancelled Task. Every
/// access goes through the lock below, which is the whole invariant.
private final class HostCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
