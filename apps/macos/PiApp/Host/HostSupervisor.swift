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
    private var ownership: WorkspaceLock?
    private var replies: [String: CheckedContinuation<WireValue, Error>] = [:]
    private var replyTimeouts: [String: Task<Void, Never>] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var closing = false
    private(set) var clockOffset = 0.0

    func connect(cwd: URL, state: URL, runtime: RuntimePreferences = RuntimePreferences(), capture: (@Sendable ([String: WireValue]) async throws -> Void)? = nil) async throws {
        if isReady { return }
        guard !closing else { throw HostError.failure("Project host is stopping") }
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
            let inbox = HostInbox { [weak self] events in for event in events { self?.receive(event) } }
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
            connection.send(["v": .number(1), "kind": .string("hello"), "major": .number(1), "minor": .number(1), "build": .string(ReleaseConfiguration.current.build)])
        }
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
            Task { try? await Task.sleep(for: .seconds(10)); if !self.isReady { self.fail("The native host did not complete its handshake"); self.shutdown() } }
        }
    }
    func request(_ method: String, sessionID: String? = nil, params: [String: WireValue] = [:], commandID: String = UUID().uuidString) async throws -> WireValue {
        guard isReady, !closing, let epoch, (replies.count < 32 || method == "turn.stop"), replies[commandID] == nil else { throw HostError.failure("Host is unavailable or its command queue is full") }
        return try await withCheckedThrowingContinuation { continuation in
            replies[commandID] = continuation
            var frame: [String: WireValue] = ["v": .number(1), "kind": .string("command"), "hostEpoch": .string(epoch), "commandId": .string(commandID), "method": .string(method), "params": .object(params)]
            if let sessionID { frame["sessionId"] = .string(sessionID) }
            transport?.send(frame)
            let timeout: Double = method.hasPrefix("mcp.") ? 315 : 30
            replyTimeouts[commandID] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                self?.replyTimeouts.removeValue(forKey: commandID)
                self?.replies.removeValue(forKey: commandID)?.resume(throwing: HostError.failure("Acknowledgment timed out. Outcome uncertain; this command was not resent."))
            }
        }
    }
    func shutdown() { closing = true; isReady = false; transport?.stop() }
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
        let error = HostError.failure(message)
        for waiter in readyWaiters { waiter.resume(throwing: error) }; readyWaiters.removeAll()
        for reply in replies.values { reply.resume(throwing: error) }; replies.removeAll()
        for timeout in replyTimeouts.values { timeout.cancel() }; replyTimeouts.removeAll()
        onLoss?()
    }
    private func receive(_ event: TransportEvent) {
        switch event {
        case .failed(let message): fail(message); shutdown()
        case .exited(let code):
            fail(code == 0 ? "Runtime stopped" : "Runtime interrupted (\(code)). No request was replayed.")
            transport = nil; ownership = nil; epoch = nil; closing = false
        case .frame(let frame):
            guard frame["v"]?.number == 1 else { fail("Incompatible host protocol"); shutdown(); return }
            if frame["kind"]?.string == "ready" {
                let capabilities = Set(frame["capabilities"]?.array?.compactMap(\.string) ?? [])
                guard frame["major"]?.number == 1, frame["engine"]?.string == "swift", frame["engineVersion"]?.string == "1.0.0",
                      Set(["responses", "mcp", "steering", "transport-capture"]).isSubset(of: capabilities),
                      let hostEpoch = frame["hostEpoch"]?.string else { fail("Packaged native runtime version or capability mismatch"); shutdown(); return }
                epoch = hostEpoch; isReady = true; status = "Ready · Swift"
                for waiter in readyWaiters { waiter.resume() }; readyWaiters.removeAll(); return
            }
            guard frame["hostEpoch"]?.string == epoch else { return }
            if frame["kind"]?.string == "reply", let id = frame["commandId"]?.string, let continuation = replies.removeValue(forKey: id) {
                replyTimeouts.removeValue(forKey: id)?.cancel()
                if frame["ok"] == .bool(true) { continuation.resume(returning: frame["result"] ?? .object([:])) }
                else { continuation.resume(throwing: HostError.rejected(frame["result"]?.object?["code"]?.string ?? "unknown", frame["result"]?.object?["message"]?.string ?? "Host command failed")) }
            } else { onEvent?(frame) }
        }
    }
}
