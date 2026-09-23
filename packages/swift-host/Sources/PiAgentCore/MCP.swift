import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Every child is required to have its own process group. Cancellation can then
/// terminate descendants without ever signaling the application process group.
///
/// Concurrency: `@unchecked` because Foundation's `Process` and `Pipe` are not
/// `Sendable`. The invariant is that the three pipes and the process are
/// immutable after `init` and used only through operations Foundation
/// documents as thread-safe (`terminate`, `isRunning`, `fileHandleFor*`), and
/// that `stopped` and `processGroup` are touched only while `lock` is held, so
/// the process group is signalled at most once.
final class ManagedChild: @unchecked Sendable {
    let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock(); private var stopped = false; private var processGroup: Int32 = 0
    init(command: String, arguments: [String], cwd: URL, environment: [String: String]) throws {
        let executable: URL
        if command.hasPrefix("/") { executable = URL(fileURLWithPath: command) }
        else {
            guard let match = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map({ URL(fileURLWithPath: String($0)).appendingPathComponent(command) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw AgentError("missing_executable", "Required executable \(command) is not on the configured tools PATH") }; executable = match
        }
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = cwd; process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        // Foundation creates a separate group. Refuse an unsafe runtime rather
        // than falling back to a killpg that could affect unrelated processes.
        let pid=process.processIdentifier
        if getpgid(pid)==pid || (!process.isRunning && kill(-pid,0)==0) { processGroup=pid }
        else if process.isRunning { process.terminate();throw AgentError("process_group","Runtime did not isolate the tool process group") }
    }
    func stop(closeInput: Bool = true) {
        lock.lock(); if stopped { lock.unlock(); return }; stopped = true; let pid = process.processIdentifier, group = processGroup; lock.unlock()
        if closeInput { try? input.fileHandleForWriting.close() }
        if group > 0, group != getpgrp() { _ = kill(-group, SIGTERM) }
        else if process.isRunning { process.terminate() }
        let child=process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if group > 0, group != getpgrp(), kill(-group,0)==0 { _ = kill(-group, SIGKILL) }
            else if child.isRunning { _ = kill(pid, SIGKILL) }
        }
    }
    func finishedNormally() { lock.lock();stopped=true;lock.unlock() }
    deinit { stop() }
}
func toolEnvironment(_ extra: [String: String] = [:]) -> [String: String] {
    let p = ProcessInfo.processInfo.environment
    var env = ["HOME": p["HOME"] ?? NSHomeDirectory(), "PATH": p["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "LANG": p["LANG"] ?? "en_US.UTF-8", "TMPDIR": p["TMPDIR"] ?? NSTemporaryDirectory()]
    for (k,v) in extra { env[k] = v }; return env
}

public protocol MCPTransport: Sendable {
    func request(_ method: String, params: JSON) async throws -> JSON
    func notify(_ method: String, params: JSON) async throws
    func close() async
    /// False once the connection can carry no further request: the server
    /// process exited or its pipe broke, or an HTTP server forgot the session.
    /// The manager then sets up a new connection for the next request.
    func isAlive() async -> Bool
    /// Advances each time the server says its tool catalog changed.
    func catalogGeneration() async -> Int
}
public extension MCPTransport {
    func isAlive() async -> Bool { true }
    func catalogGeneration() async -> Int { 0 }
}
/// Errors that mean the server refused a request without processing it: a
/// JSON-RPC rejection of the request itself, an HTTP refusal, a session the
/// server no longer knows, or a request that was never sent. The call did not
/// run, so it leaves no unknown outcome behind.
let mcpNotExecutedCodes: Set<String> = ["mcp_rejected", "mcp_session_expired", "mcp_unavailable"]
/// A JSON-RPC error answer. Parse errors, invalid requests, unknown methods
/// and invalid params (an unknown tool or bad arguments) reject the request
/// itself; any other code can come from the tool while it ran.
func mcpRemoteError(_ error: JSON) -> AgentError {
    let detail = preview(error["message"].text ?? "", bytes: 512)
    if let code = error["code"].int, [-32700, -32600, -32601, -32602].contains(code) {
        return AgentError("mcp_rejected", "MCP server rejected the call (JSON-RPC \(code)" + (detail.isEmpty ? "" : ": " + detail) + "); it was not executed.")
    }
    return AgentError("mcp_remote_error", "MCP server returned JSON-RPC error \(error["code"].encoded()); invocation outcome may be unknown. No replay attempted.")
}

/// Bounded JSON-RPC stdio peer. No server-provided instructions are elevated to
/// system instructions. Unadvertised client operations are explicitly rejected.
///
/// Concurrency: `@unchecked` because FileHandle readability handlers and the
/// writer queue run off any actor. The invariant is that `pending` and `closed`
/// are touched only while `lock` is held, that each continuation is removed
/// from `pending` under that lock before it is resumed (so a reply, a timeout
/// and a cancellation cannot resume the same one twice), that `buffer` is
/// touched only from the readability handler, which FileHandle serializes for
/// one handle, and that writes go through the serial `writer` queue.
final class StdioMCP: MCPTransport, @unchecked Sendable {
    private let child: ManagedChild, lock = NSLock()
    private var writer: MCPWriteQueue!
    private var serverRequestWindow = 0.0, serverRequests = 0
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:], closed = false, buffer = Data()
    private var catalogChanges = 0
    private let timeout: UInt64
    init(command: String, args: [String], cwd: URL, environment: [String: String], timeoutSeconds: Int) throws {
        child = try ManagedChild(command: command, arguments: args, cwd: cwd, environment: environment); timeout = UInt64(timeoutSeconds) * 1_000_000_000
        writer = MCPWriteQueue(handle: child.input.fileHandleForWriting) { [weak self] in
            self?.fail(AgentError("mcp_backpressure", "MCP output queue exceeded its limit or disconnected; invocation outcome may be unknown. No replay attempted."))
        }
        for handle in [child.errors.fileHandleForReading, child.output.fileHandleForReading] {
            let fd = handle.fileDescriptor; _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        child.errors.fileHandleForReading.readabilityHandler = { handle in
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = read(handle.fileDescriptor, &bytes, bytes.count)
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { handle.readabilityHandler = nil }
        }
        child.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            // The callback retains the handle; no other path explicitly closes
            // stdout/stderr. POSIX returns an error rather than an ObjC exception,
            // and unlike Foundation's filling read it does not await 64 KiB.
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = read(handle.fileDescriptor, &bytes, bytes.count)
            if count < 0 {
                if errno != EAGAIN && errno != EINTR { self.fail(AgentError("mcp_read", "MCP output interrupted; invocation outcome may be unknown")) }
                return
            }
            let data = Data(bytes.prefix(count))
            if data.isEmpty { self.fail(AgentError("mcp_closed", "MCP server disconnected; an in-flight invocation may have completed remotely")); return }
            self.consume(data)
        }
    }
    func request(_ method: String, params: JSON) async throws -> JSON {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock(); guard !closed, pending.count < 32 else { lock.unlock(); continuation.resume(throwing: AgentError("mcp_unavailable", "MCP connection unavailable")); return }
                pending[id] = continuation; lock.unlock()
                if Task.isCancelled { resolve(id, .failure(CancellationError())); return }
                send(["jsonrpc":"2.0", "id":JSON(id), "method":JSON(method), "params":params])
                // The request deadline. Bounded rather than owned: it sleeps
                // once, holds only a weak reference, and `cancel` is a no-op
                // once the reply has removed this id from `pending`.
                Task { [weak self, timeout] in
                    try? await Task.sleep(nanoseconds: timeout)
                    self?.cancel(id, error: AgentError("mcp_timeout", "MCP request timed out; invocation outcome may be unknown. No replay attempted."))
                }
            }
        }, onCancel: { [weak self] in self?.cancel(id, error: CancellationError()) })
    }
    func notify(_ method: String, params: JSON) async throws { try Task.checkCancellation(); send(["jsonrpc":"2.0", "method":JSON(method), "params":params]) }
    func isAlive() async -> Bool { !isClosed }
    func catalogGeneration() async -> Int { changes }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    private var changes: Int { lock.lock(); defer { lock.unlock() }; return catalogChanges }
    private func cancel(_ id: String, error: Error) {
        lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
        if let c { send(["jsonrpc":"2.0", "method":"notifications/cancelled", "params":["requestId":JSON(id),"reason":"Client cancelled or deadline exceeded"]]); c.resume(throwing: error) }
    }
    private func resolve(_ id: String, _ result: Result<JSON, Error>) { lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock(); c?.resume(with: result) }
    private func send(_ value: JSON) {
        lock.lock(); let stopped = closed; lock.unlock(); guard !stopped else { return }
        do {
            var data = try value.data(); data.append(10)
            guard writer.append(data) else { throw AgentError("mcp_backpressure", "MCP outbound queue exceeded its byte/frame limit; invocation outcome may be unknown. No replay attempted.") }
        } catch { fail(error) }
    }
    private func consume(_ data: Data) {
        // FileHandle serializes callbacks for this handle. The buffer is never
        // shared with request/cancel paths, which operate only on pending.
        buffer.append(data)
        do {
            while let nl = buffer.firstIndex(of: 10) {
                lock.lock(); let stopped = closed; lock.unlock(); if stopped { buffer.removeAll(); return }
                guard nl <= 4 * 1024 * 1024 else { throw AgentError("mcp_limit", "MCP response frame too large") }
                let line = Data(buffer[..<nl]); buffer.removeSubrange(...nl)
                let v = try JSON.parse(line); guard v.isObject, v["jsonrpc"].text == "2.0" else { throw AgentError("mcp_protocol", "Invalid MCP JSON-RPC response") }
                if let method = v["method"].text {
                    if !v["id"].isNull {
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - serverRequestWindow >= 1 { serverRequestWindow = now; serverRequests = 0 }
                        serverRequests += 1
                        guard serverRequests <= 64 else { throw AgentError("mcp_server_flood", "MCP server exceeded 64 client-directed requests per second; invocation outcome may be unknown. No replay attempted.") }
                        var response: JSON = ["jsonrpc":"2.0", "id":v["id"]]
                        if method == "ping" { response["result"] = [:] }
                        else { response["error"] = ["code":-32601,"message":"Client capability not supported"] }
                        send(response)
                    } else if method == "notifications/tools/list_changed" { lock.lock(); catalogChanges += 1; lock.unlock() }
                    continue // No sampling, elicitation, or server-initiated execution.
                }
                guard let id = v["id"].text else { continue }
                if !v["error"].isNull { resolve(id, .failure(mcpRemoteError(v["error"]))) }
                else if v.map.keys.contains("result") { resolve(id, .success(v["result"])) }
                else { throw AgentError("mcp_protocol", "MCP response lacks result or error") }
            }
            guard buffer.count <= 4 * 1024 * 1024 else { throw AgentError("mcp_limit", "MCP response frame too large") }
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        lock.lock(); if closed { lock.unlock(); return }; closed = true; let waits = pending.values; pending.removeAll(); lock.unlock()
        writer.close()
        child.output.fileHandleForReading.readabilityHandler = nil; child.errors.fileHandleForReading.readabilityHandler = nil
        for c in waits { c.resume(throwing: error) }; child.stop(closeInput: false)
    }
    func close() async { fail(AgentError("mcp_closed", "MCP connection closed")); child.output.fileHandleForReading.readabilityHandler = nil; child.errors.fileHandleForReading.readabilityHandler = nil }
    deinit {
        writer.close(); child.stop(closeInput: false)
        child.output.fileHandleForReading.readabilityHandler = nil; child.errors.fileHandleForReading.readabilityHandler = nil
    }
}

/// Admission is byte/frame bounded before dispatching a closure. The sole
/// writer is nonblocking; cancellation owns descriptor close after writes stop.
final class MCPWriteQueue: @unchecked Sendable {
    static let byteLimit = 4 * 1024 * 1024 + 1, frameLimit = 64
    private let lock = NSLock(), queue = DispatchQueue(label: "pi.mcp.write")
    private let fd: Int32, failed: @Sendable () -> Void
    private var closed = false, bytes = 0, frames = 0
    private var source: DispatchSourceWrite?
    private var resumed = false, pending: [Data] = [], offset = 0
    var retainedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    init(handle: FileHandle, failed: @escaping @Sendable () -> Void) {
        fd = handle.fileDescriptor; self.failed = failed
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        #if canImport(Darwin)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        #endif
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.flush() }
        source.setCancelHandler { try? handle.close() }; self.source = source
    }
    func append(_ data: Data) -> Bool {
        lock.lock()
        guard !closed, frames < Self.frameLimit, data.count <= Self.byteLimit - bytes else { lock.unlock(); return false }
        frames += 1; bytes += data.count; lock.unlock()
        queue.async { [self] in
            guard source != nil else { release(data.count); return }
            pending.append(data); flush()
        }
        return true
    }
    private func release(_ count: Int) { lock.lock(); bytes -= count; frames -= 1; lock.unlock() }
    private func flush() {
        guard let source else { return }
        for _ in 0..<16 {
            guard let first = pending.first else { if resumed { source.suspend(); resumed = false }; return }
            let count = first.withUnsafeBytes { raw in
                raw.baseAddress.map { write(fd, $0 + offset, min(65_536, raw.count - offset)) } ?? 0
            }
            if count > 0 {
                offset += count
                if offset == first.count { pending.removeFirst(); offset = 0; release(first.count) }
            } else if count < 0, errno == EINTR { continue }
            else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
            else { close(); failed(); return }
        }
        if !resumed { source.resume(); resumed = true }
    }
    func close() {
        lock.lock(); if closed { lock.unlock(); return }; closed = true; lock.unlock()
        queue.async { [self] in
            for entry in pending { release(entry.count) }; pending.removeAll(); offset = 0
            if !resumed { source?.resume() }; source?.cancel(); source = nil
        }
    }
    deinit { if !resumed { source?.resume() }; source?.cancel() }
}

/// Streamable HTTP 2025-11-25/2025-06-18, with no automatic reconnect/replay.
/// The optional server GET channel is not opened; no server-initiated capability
/// is advertised. A response SSE stream is terminated after its matching reply.
actor HTTPMCP: MCPTransport {
    let url: URL, headers: [String: String]
    var session: String?, version = "2025-11-25"
    /// Set when the server answered 404 to a request carrying its session id:
    /// it has forgotten the session, and this connection is spent.
    private var expired = false, catalogChanges = 0
    init(url: URL, headers: [String: String]) { self.url=url; self.headers=headers }
    func isAlive() -> Bool { !expired }
    func catalogGeneration() -> Int { catalogChanges }
    func request(_ method: String, params: JSON) async throws -> JSON {
        let id = UUID().uuidString
        let result = try await exchange(["jsonrpc":"2.0","id":JSON(id),"method":JSON(method),"params":params], expected: id)
        if method == "initialize", let v = result["protocolVersion"].text { version = v }; return result
    }
    func notify(_ method: String, params: JSON) async throws { _ = try await exchange(["jsonrpc":"2.0","method":JSON(method),"params":params], expected: nil) }
    private func exchange(_ message: JSON, expected: String?) async throws -> JSON {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = try message.data()
        for (key,value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let sentSession = session
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if message["method"].text != "initialize" { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        let transport = HTTPStream(); defer { transport.cancel() }
        var code = 0, sse = false, parser = SSEParser(), body = Data()
        for try await part in transport.start(request) {
            try Task.checkCancellation()
            switch part {
            case .head(let status, let fields):
                code=status; sse=fields.first(where: { $0.key.lowercased() == "content-type" })?.value.lowercased().contains("text/event-stream") ?? false
                if let sid = fields.first(where: { $0.key.lowercased() == "mcp-session-id" })?.value, sid.utf8.count <= 1024 { session = sid }
                if expected == nil, status == 202 || status == 204 { return [:] }
                guard (200..<300).contains(status) else {
                    // A server that restarted forgets its sessions and answers
                    // 404 without processing the request.
                    if status == 404, sentSession != nil, message["method"].text != "initialize" {
                        expired = true; session = nil
                        throw AgentError("mcp_session_expired", "MCP server no longer knows this session (HTTP 404); the request was not processed")
                    }
                    if [400, 401, 403, 404, 405, 429].contains(status) { throw AgentError("mcp_rejected", "MCP server rejected the request with HTTP \(status); it was not executed. No automatic replay.") }
                    throw AgentError("mcp_http", "MCP HTTP \(status); invocation outcome may be unknown. No automatic reconnection or invocation replay")
                }
            case .bytes(let bytes, _):
                // HTTPStream permits one body batch in flight. JSON needs EOF
                // and SSE may span many batches; both must release ingress even
                // when returning early on the matching response or throwing.
                defer { transport.consumed(bytes.count) }
                if sse {
                    for event in try parser.feed(bytes) {
                        let v = try JSON.parse(Data(event.data.utf8))
                        if v["id"].text == expected, expected != nil { return try response(v) }
                        if !v["method"].isNull && !v["id"].isNull { throw AgentError("mcp_capability", "Server requested an unsupported client capability") }
                        if v["method"].text == "notifications/tools/list_changed" { catalogChanges += 1 }
                    }
                } else { body.append(bytes); guard body.count <= 4 * 1024 * 1024 else { throw AgentError("mcp_limit", "MCP body exceeds 4 MiB") } }
            }
        }
        if expected == nil, (200..<300).contains(code) { return [:] }
        guard !sse, !body.isEmpty else { throw AgentError("mcp_incomplete", "MCP stream ended without its response; invocation outcome is unknown") }
        let value = try JSON.parse(body); guard value["id"].text == expected else { throw AgentError("mcp_protocol", "Mismatched MCP response identity") }; return try response(value)
    }
    private func response(_ v: JSON) throws -> JSON {
        guard v.isObject, v["jsonrpc"].text == "2.0" else { throw AgentError("mcp_protocol", "Invalid JSON-RPC response") }
        if !v["error"].isNull { throw mcpRemoteError(v["error"]) }
        guard v.map.keys.contains("result") else { throw AgentError("mcp_protocol", "Missing MCP result") }; return v["result"]
    }
    func close() async { session = nil }
}

/// Actor reentrancy does not itself serialize async work. This explicit gate
/// holds across awaits. All MCP invocations in this workspace share one gate.
public actor AsyncGate {
    private var locked=false
    private var waiters:[(UUID,CheckedContinuation<Void,Error>)]=[]
    public init() {}
    public func acquire() async throws {
        try Task.checkCancellation()
        if !locked { locked=true; return }
        let id=UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
                if Task.isCancelled { c.resume(throwing:CancellationError()) }
                else { waiters.append((id,c)) }
            }
        // Cancellation handlers are synchronous; reaching the actor needs a
        // task. It must not itself be cancellable, or a cancelled waiter would
        // stay in `waiters` and never be resumed.
        },onCancel:{ Task { await self.cancel(id) } })
        if Task.isCancelled { release(); throw CancellationError() }
    }
    private func cancel(_ id:UUID) {
        if let i=waiters.firstIndex(where:{$0.0==id}) { waiters.remove(at:i).1.resume(throwing:CancellationError()) }
    }
    public func release() { if waiters.isEmpty { locked=false } else { waiters.removeFirst().1.resume() } }
}

public actor MCPManager {
    struct Server {
        var name: String; var config: JSON; var transport: (any MCPTransport)?; var initialized = false
        /// The tool catalog this connection listed, at the catalog generation
        /// it listed it. A new connection or a list_changed notice relists.
        var catalog: [JSON]? = nil, catalogGeneration = 0
    }
    private var servers: [String: Server] = [:]
    private var unknownOutcome=false
    private let gate = AsyncGate(), connectionGate = AsyncGate(), cwd: URL
    /// Workspace roots, primary first. stdio servers start in the primary root.
    public let roots: [URL]
    private let outcomeMarker: URL?
    private var invoking = false
    public init(cwd: URL, roots: [URL] = [], outcomeMarker: URL? = nil) { self.cwd=cwd; self.roots=workspaceRoots(primary:cwd,additional:roots); self.outcomeMarker=outcomeMarker; unknownOutcome=outcomeMarker.map { FileManager.default.fileExists(atPath:$0.path) } ?? false }
    public func serverNames() -> [String] { servers.keys.sorted() }
    public func configure(_ config: JSON) async throws {
        guard config.isObject, Set(config.map.keys) == ["servers"], config["servers"].isObject, config["servers"].map.count <= 32,
              try config.data().count <= 262144 else { throw AgentError("mcp_config", "Expected {servers:{name:configuration}} with at most 32 servers within 256 KiB") }
        // Releases are deliberately unowned and uncancellable: a gate that is
        // not released strands every later invocation in this workspace, so
        // these must run even when the invoking turn is being cancelled.
        try await gate.acquire(); defer { Task { await gate.release() } }
        try await connectionGate.acquire(); defer { Task { await connectionGate.release() } }
        var proposed: [String: Server] = [:]
        for (name, c) in config["servers"].map {
            _ = try identity(JSON(name)); guard c.isObject else { throw AgentError("mcp_config", "Invalid server configuration") }
            guard Set(c.map.keys).isSubset(of:["enabled","transport","command","args","env","url","headers","allowedTools","timeoutSeconds"]) else { throw AgentError("mcp_config", "Unsupported MCP configuration fields") }
            guard c["enabled"].isNull || c["enabled"].flag != nil else { throw AgentError("mcp_config","enabled must be a boolean") }
            guard c["inheritEnv"].isNull, c["headerEnv"].isNull else { throw AgentError("mcp_config", "Store explicit MCP credentials in the native configuration vault; inherited credential references are unsupported") }
            for key in ["args","allowedTools"] where !c[key].isNull { guard case .array(let values)=c[key],values.count<=256,values.allSatisfy({$0.text != nil}) else { throw AgentError("mcp_config","\(key) must be a bounded string array") } }
            for key in ["env","headers"] where !c[key].isNull { guard c[key].isObject,c[key].map.count<=64,c[key].map.values.allSatisfy({$0.text != nil}) else { throw AgentError("mcp_config","\(key) must be a string mapping") } }
            for (key,value) in c["env"].map {
                guard key.range(of:"^[A-Za-z_][A-Za-z0-9_]{0,127}$",options:.regularExpression) != nil, let text=value.text, text.utf8.count<=16384, !text.utf8.contains(0) else { throw AgentError("mcp_config", "Invalid explicit MCP environment") }
            }
            for (key,value) in c["headers"].map {
                guard key.range(of:"^[A-Za-z0-9-]{1,128}$",options:.regularExpression) != nil, let text=value.text, text.utf8.count<=16384,
                      !text.utf8.contains(where:{$0<32 || $0==127}), !["host","content-length","transfer-encoding","connection"].contains(key.lowercased()) else { throw AgentError("mcp_config", "Invalid MCP header") }
            }
            if c["enabled"].flag == false { continue }
            let transport = c["transport"].text ?? (c["url"].text == nil ? "stdio" : "http")
            guard ["stdio","http"].contains(transport) else { throw AgentError("mcp_config", "Supported transports are stdio and Streamable HTTP") }
            if transport == "stdio" { _ = try required(c["command"], "MCP command"); guard c["url"].isNull, c["args"].isNull || c["args"].list.allSatisfy({ $0.text != nil }) else { throw AgentError("mcp_config", "MCP args must be strings and stdio cannot specify a URL") } }
            else {
                guard let text=c["url"].text, !text.contains(where: \.isWhitespace), let url = URLComponents(string: text), let host=url.host, !host.isEmpty,
                      c["command"].isNull, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.scheme == "https" || url.scheme == "http" && ["localhost","127.0.0.1","::1","[::1]"].contains(host) else { throw AgentError("mcp_config", "MCP URLs require HTTPS or loopback HTTP, no embedded credentials or stdio command") }
            }
            proposed[name] = Server(name:name, config:c)
        }
        for server in servers.values { await server.transport?.close() }; servers=proposed
    }
    /// Injection point for deterministic transport tests, never exposed on IPC.
    public func installForTesting(name: String, transport: any MCPTransport) { servers[name] = Server(name:name, config:[:], transport:transport) }
    private func connect(_ name: String) async throws -> any MCPTransport {
        try await connectionGate.acquire()
        do {
            guard var server = servers[name] else { throw AgentError("mcp_server", "Unknown or disabled MCP server") }
            if server.initialized, let ready = server.transport {
                if await ready.isAlive() { await connectionGate.release(); return ready }
                // The connection died after setup: the process exited, its
                // pipe broke or the server forgot the session. Start a new
                // one (new process, new initialize). Nothing is replayed.
                await ready.close()
                server.transport = nil; server.initialized = false; server.catalog = nil
                servers[name] = server
            }
            if server.transport == nil {
                if let configured = server.config["url"].text {
                    var headers: [String: String] = [:]
                    for (key,value) in server.config["headers"].map {
                        guard let v = value.text, !v.utf8.contains(13), !v.utf8.contains(10), !["host","content-length"].contains(key.lowercased()) else { throw AgentError("mcp_config", "Invalid MCP header") }; headers[key]=v
                    }
                    guard let url = URL(string: configured) else { throw AgentError("mcp_config", "This server's URL is not a usable address; correct it in the native vault") }
                    server.transport = HTTPMCP(url:url,headers:headers)
                } else {
                    var env: [String:String] = [:]
                    for (key,value) in server.config["env"].map { guard let value = value.text else { throw AgentError("mcp_config", "Environment values must be strings") }; env[key]=value }
                    server.transport = try StdioMCP(command:required(server.config["command"], "command"), args:server.config["args"].list.compactMap(\.text), cwd:cwd, environment:toolEnvironment(env), timeoutSeconds:min(300,max(1,server.config["timeoutSeconds"].int ?? 60)))
                }
            }
            guard let transport=server.transport else { throw AgentError("mcp_server", "MCP server has no usable transport") }
            let hello = try await transport.request("initialize", params:["protocolVersion":"2025-11-25","capabilities":[:],"clientInfo":["name":"pi-app-native","version":"1.0.0"]])
            guard ["2025-11-25","2025-06-18"].contains(hello["protocolVersion"].text), hello["capabilities"]["tools"].isObject else { await transport.close(); throw AgentError("mcp_version", "Server must support MCP 2025-11-25 or 2025-06-18 and tools capability") }
            try await transport.notify("notifications/initialized", params:[:]); server.initialized=true; servers[name]=server
            await connectionGate.release(); return transport
        } catch { await connectionGate.release(); throw error }
    }
    private static func same(_ a: (any MCPTransport)?, _ b: any MCPTransport) -> Bool { a.map { ObjectIdentifier($0 as AnyObject) == ObjectIdentifier(b as AnyObject) } ?? false }
    /// The server's catalog, listed once per connection: an invocation checks
    /// the tool against it without listing the whole catalog again.
    private func tools(_ name: String, retried: Bool = false) async throws -> [JSON] {
        let t = try await connect(name), generation = await t.catalogGeneration()
        if let server = servers[name], let catalog = server.catalog, server.catalogGeneration == generation, Self.same(server.transport, t) { return catalog }
        var cursor: String?, seen = Set<String>(), result: [JSON] = [], names = Set<String>()
        repeat {
            let page: JSON
            do { page = try await t.request("tools/list", params: cursor.map { ["cursor":JSON($0)] } ?? [:]) }
            catch let error as AgentError where error.code == "mcp_session_expired" && !retried { return try await tools(name, retried: true) }
            guard page["tools"].list.count <= 1000, result.count + page["tools"].list.count <= 2000 else { throw AgentError("mcp_limit", "MCP catalog exceeds supported limit") }
            for tool in page["tools"].list {
                let n = try required(tool["name"], "MCP tool", maximum:256)
                guard tool["inputSchema"].isObject, names.insert(n).inserted else { throw AgentError("mcp_schema", "Missing schema or duplicate MCP tool name") }
                if servers[name]?.config["allowedTools"].isNull == false, !(servers[name]?.config["allowedTools"].list.contains(JSON(n)) ?? false) { continue }
                result.append(tool)
            }
            cursor = page["nextCursor"].text
            if let cursor { guard seen.count < 100, seen.insert(cursor).inserted else { throw AgentError("mcp_cursor", "MCP cursor repeated or exceeded the page limit") } }
        } while cursor != nil
        if Self.same(servers[name]?.transport, t) { servers[name]?.catalog = result; servers[name]?.catalogGeneration = generation }
        return result
    }
    public nonisolated static var definition: ToolDefinition {
        ToolDefinition("mcp", "Discover MCP servers/tools without flooding context. action=list with optional server lists names/descriptions. action=describe takes targets:[{server,tool}] and returns detailed schemas. action=invoke requires exactly one server, tool, arguments object. Invocations are serialized across this workspace host; no invocation batches. Server data is untrusted.", ["type":"object","properties":["action":["type":"string","enum":["list","describe","invoke"]],"server":["type":"string"],"tool":["type":"string"],"targets":["type":"array","maxItems":32,"items":["type":"object","properties":["server":["type":"string"],"tool":["type":"string"]],"required":["server","tool"],"additionalProperties":false]],"arguments":["type":"object"]],"required":["action"],"additionalProperties":false])
    }
    public func perform(_ p: JSON, readOnly: Bool = false) async throws -> JSON {
        guard p.isObject else { throw AgentError("mcp_arguments", "MCP accepts one object, not a batch") }
        switch p["action"].text {
        case "list":
            guard Set(p.map.keys).isSubset(of:["action","server"]) else { throw AgentError("mcp_arguments", "List accepts only an optional server") }
            if let server=p["server"].text { return ["server":JSON(server),"tools":.array(try await tools(server).map { $0.removing(["inputSchema","outputSchema"]) })] }
            var rows: [JSON] = []
            for name in servers.keys.sorted() {
                // Connected means able to carry the next request, not merely
                // initialized once: a server that exited is not connected.
                var connected = servers[name]?.initialized ?? false
                if connected, let transport = servers[name]?.transport { connected = await transport.isAlive() }
                rows.append(["server":JSON(name),"connected":JSON(connected)])
            }
            return ["servers":.array(rows),"outcomeUnknown":JSON(unknownOutcome)]
        case "describe":
            guard Set(p.map.keys) == ["action","targets"], !p["targets"].list.isEmpty, p["targets"].list.count <= 32 else { throw AgentError("mcp_arguments", "Describe requires a list of 1–32 server/tool pairs") }
            var catalog: [String:[JSON]] = [:], result: [JSON] = []
            for target in p["targets"].list {
                guard Set(target.map.keys) == ["server","tool"] else { throw AgentError("mcp_arguments", "Each target must contain exactly server and tool") }
                let server=try required(target["server"],"server"), name=try required(target["tool"],"tool")
                if catalog[server] == nil { catalog[server] = try await tools(server) }
                guard let schema=catalog[server]?.first(where:{$0["name"].text == name}) else { throw AgentError("mcp_tool", "Unknown or disallowed MCP tool") }
                result.append(["server":JSON(server),"tool":JSON(name),"schema":schema])
            }
            return ["tools":.array(result)]
        case "invoke":
            guard !readOnly else { throw AgentError("read_only", "MCP invocation is disabled in discussion-only sessions; annotations are not authorization") }
            guard Set(p.map.keys) == ["action","server","tool","arguments"], p["arguments"].isObject else { throw AgentError("mcp_arguments", "Invoke requires exactly one server, tool and arguments object; batches are not supported") }
            let server=try required(p["server"],"server"), name=try required(p["tool"],"tool")
            try await gate.acquire()
            // dispatched: a tools/call may have reached the server and run.
            // marked: this invocation wrote the outcome marker.
            var dispatched=false, marked=false
            do {
                guard !unknownOutcome else { throw AgentError("mcp_outcome_unknown","A previous invocation has an unknown outcome. The user must verify it and acknowledge before another invocation.") }
                guard try await tools(server).contains(where:{$0["name"].text == name}) else { throw AgentError("mcp_tool", "Unknown or disallowed MCP tool") }
                var transport = try await connect(server)
                if let outcomeMarker {
                    marked=true
                    let bytes = try JSON.object(["server":JSON(server),"tool":JSON(name),"startedAt":JSON(isoNow()),"state":"outcome-unknown-until-result-retained"]).data()
                    try bytes.write(to:outcomeMarker,options:.atomic)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:outcomeMarker.path)
                    let marker = try FileHandle(forWritingTo:outcomeMarker);try marker.synchronize();try marker.close()
                }
                dispatched=true;invoking=true
                let call: JSON = ["name":JSON(name),"arguments":p["arguments"]], result: JSON
                do { result = try await transport.request("tools/call", params:call) }
                catch let error as AgentError where error.code == "mcp_session_expired" {
                    // The server forgot the session and did not process the
                    // call: set the session up again and send it once more.
                    dispatched=false; transport = try await connect(server); dispatched=true
                    result = try await transport.request("tools/call", params:call)
                }
                if let outcomeMarker { try FileManager.default.removeItem(at:outcomeMarker) }
                invoking=false;await gate.release(); return result
            } catch {
                invoking=false
                // A call the server refused without processing it did not run:
                // it leaves no unknown outcome, in memory or on disk.
                if dispatched, !mcpNotExecutedCodes.contains((error as? AgentError)?.code ?? "") { unknownOutcome=true }
                else if marked, let outcomeMarker { try? FileManager.default.removeItem(at:outcomeMarker) }
                await gate.release(); throw error
            }
        default: throw AgentError("mcp_arguments", "Use list, describe, or invoke")
        }
    }
    public func acknowledgeUnknown() throws {
        guard !invoking else { throw AgentError("mcp_busy","An invocation is still running") }
        if let outcomeMarker, FileManager.default.fileExists(atPath:outcomeMarker.path) { try FileManager.default.removeItem(at:outcomeMarker) }
        unknownOutcome=false
    }
    public func close() async { for s in servers.values { await s.transport?.close() }; servers.removeAll() }
}
