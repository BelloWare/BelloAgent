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
    func stop() {
        lock.lock(); if stopped { lock.unlock(); return }; stopped = true; let pid = process.processIdentifier, group = processGroup; lock.unlock()
        try? input.fileHandleForWriting.close()
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
}

/// Bounded JSON-RPC stdio peer. No server-provided instructions are elevated to
/// system instructions. Unadvertised client operations are explicitly rejected.
final class StdioMCP: MCPTransport, @unchecked Sendable {
    private let child: ManagedChild, lock = NSLock(), writer = DispatchQueue(label: "pi.mcp.write")
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:], closed = false, buffer = Data()
    private let timeout: UInt64
    init(command: String, args: [String], cwd: URL, environment: [String: String], timeoutSeconds: Int) throws {
        child = try ManagedChild(command: command, arguments: args, cwd: cwd, environment: environment); timeout = UInt64(timeoutSeconds) * 1_000_000_000
        child.errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        child.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
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
                Task { [weak self, timeout] in
                    try? await Task.sleep(nanoseconds: timeout)
                    self?.cancel(id, error: AgentError("mcp_timeout", "MCP request timed out; invocation outcome may be unknown. No replay attempted."))
                }
            }
        }, onCancel: { [weak self] in self?.cancel(id, error: CancellationError()) })
    }
    func notify(_ method: String, params: JSON) async throws { try Task.checkCancellation(); send(["jsonrpc":"2.0", "method":JSON(method), "params":params]) }
    private func cancel(_ id: String, error: Error) {
        lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
        if let c { send(["jsonrpc":"2.0", "method":"notifications/cancelled", "params":["requestId":JSON(id),"reason":"Client cancelled or deadline exceeded"]]); c.resume(throwing: error) }
    }
    private func resolve(_ id: String, _ result: Result<JSON, Error>) { lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock(); c?.resume(with: result) }
    private func send(_ value: JSON) {
        writer.async { [self] in
            do { var data = try value.data(); guard data.count <= 4 * 1024 * 1024 else { throw AgentError("mcp_limit", "MCP frame too large") }; data.append(10); try child.input.fileHandleForWriting.write(contentsOf: data) }
            catch { fail(AgentError("mcp_write", "MCP write failed; no invocation replay attempted")) }
        }
    }
    private func consume(_ data: Data) {
        // FileHandle serializes callbacks for this handle. The buffer is never
        // shared with request/cancel paths, which operate only on pending.
        buffer.append(data)
        do {
            while let nl = buffer.firstIndex(of: 10) {
                guard nl <= 4 * 1024 * 1024 else { throw AgentError("mcp_limit", "MCP response frame too large") }
                let line = Data(buffer[..<nl]); buffer.removeSubrange(...nl)
                let v = try JSON.parse(line); guard v.isObject, v["jsonrpc"].text == "2.0" else { throw AgentError("mcp_protocol", "Invalid MCP JSON-RPC response") }
                if let method = v["method"].text {
                    if !v["id"].isNull {
                        var response: JSON = ["jsonrpc":"2.0", "id":v["id"]]
                        if method == "ping" { response["result"] = [:] }
                        else { response["error"] = ["code":-32601,"message":"Client capability not supported"] }
                        send(response)
                    }
                    continue // No sampling, elicitation, or server-initiated execution.
                }
                guard let id = v["id"].text else { continue }
                if !v["error"].isNull { resolve(id, .failure(AgentError("mcp_remote_error", "MCP server returned JSON-RPC error \(v["error"]["code"].encoded())"))) }
                else if v.map.keys.contains("result") { resolve(id, .success(v["result"])) }
                else { throw AgentError("mcp_protocol", "MCP response lacks result or error") }
            }
            guard buffer.count <= 4 * 1024 * 1024 else { throw AgentError("mcp_limit", "MCP response frame too large") }
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        lock.lock(); if closed { lock.unlock(); return }; closed = true; let waits = pending.values; pending.removeAll(); lock.unlock()
        for c in waits { c.resume(throwing: error) }; child.stop()
    }
    func close() async { fail(AgentError("mcp_closed", "MCP connection closed")); child.output.fileHandleForReading.readabilityHandler = nil; child.errors.fileHandleForReading.readabilityHandler = nil }
}

/// Streamable HTTP 2025-11-25/2025-06-18, with no automatic reconnect/replay.
/// The optional server GET channel is not opened; no server-initiated capability
/// is advertised. A response SSE stream is terminated after its matching reply.
actor HTTPMCP: MCPTransport {
    let url: URL, headers: [String: String]
    var session: String?, version = "2025-11-25"
    init(url: URL, headers: [String: String]) { self.url=url; self.headers=headers }
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
                guard (200..<300).contains(status) else { throw AgentError("mcp_http", "MCP HTTP \(status); no automatic reconnection or invocation replay") }
            case .bytes(let bytes, _):
                if sse {
                    for event in try parser.feed(bytes) {
                        let v = try JSON.parse(Data(event.data.utf8))
                        if v["id"].text == expected, expected != nil { return try response(v) }
                        if !v["method"].isNull && !v["id"].isNull { throw AgentError("mcp_capability", "Server requested an unsupported client capability") }
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
        if !v["error"].isNull { throw AgentError("mcp_remote_error", "MCP server returned an error; no replay attempted") }
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
        },onCancel:{ Task { await self.cancel(id) } })
        if Task.isCancelled { release(); throw CancellationError() }
    }
    private func cancel(_ id:UUID) {
        if let i=waiters.firstIndex(where:{$0.0==id}) { waiters.remove(at:i).1.resume(throwing:CancellationError()) }
    }
    public func release() { if waiters.isEmpty { locked=false } else { waiters.removeFirst().1.resume() } }
}

public actor MCPManager {
    struct Server { var name: String; var config: JSON; var transport: (any MCPTransport)?; var initialized = false }
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
            guard var s = servers[name] else { throw AgentError("mcp_server", "Unknown or disabled MCP server") }
            if s.initialized, let t = s.transport { await connectionGate.release(); return t }
            if s.transport == nil {
                if s.config["url"].text != nil {
                    var headers: [String: String] = [:]
                    for (key,value) in s.config["headers"].map {
                        guard let v = value.text, !v.utf8.contains(13), !v.utf8.contains(10), !["host","content-length"].contains(key.lowercased()) else { throw AgentError("mcp_config", "Invalid MCP header") }; headers[key]=v
                    }
                    s.transport = HTTPMCP(url:URL(string:s.config["url"].text!)!,headers:headers)
                } else {
                    var env: [String:String] = [:]
                    for (key,value) in s.config["env"].map { guard let value = value.text else { throw AgentError("mcp_config", "Environment values must be strings") }; env[key]=value }
                    s.transport = try StdioMCP(command:required(s.config["command"], "command"), args:s.config["args"].list.compactMap(\.text), cwd:cwd, environment:toolEnvironment(env), timeoutSeconds:min(300,max(1,s.config["timeoutSeconds"].int ?? 60)))
                }
            }
            let t=s.transport!
            let hello = try await t.request("initialize", params:["protocolVersion":"2025-11-25","capabilities":[:],"clientInfo":["name":"pi-app-native","version":"1.0.0"]])
            guard ["2025-11-25","2025-06-18"].contains(hello["protocolVersion"].text), hello["capabilities"]["tools"].isObject else { await t.close(); throw AgentError("mcp_version", "Server must support MCP 2025-11-25 or 2025-06-18 and tools capability") }
            try await t.notify("notifications/initialized", params:[:]); s.initialized=true; servers[name]=s
            await connectionGate.release(); return t
        } catch { await connectionGate.release(); throw error }
    }
    private func tools(_ name: String) async throws -> [JSON] {
        let t = try await connect(name); var cursor: String?, seen = Set<String>(), result: [JSON] = [], names = Set<String>()
        repeat {
            let page = try await t.request("tools/list", params: cursor.map { ["cursor":JSON($0)] } ?? [:])
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
            return ["servers":.array(servers.keys.sorted().map { ["server":JSON($0),"connected":JSON(servers[$0]?.initialized ?? false)] }),"outcomeUnknown":JSON(unknownOutcome)]
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
            var dispatched=false
            do {
                guard !unknownOutcome else { throw AgentError("mcp_outcome_unknown","A previous invocation has an unknown outcome. The user must verify it and acknowledge before another invocation.") }
                guard try await tools(server).contains(where:{$0["name"].text == name}) else { throw AgentError("mcp_tool", "Unknown or disallowed MCP tool") }
                let transport = try await connect(server)
                if let outcomeMarker {
                    let bytes = try JSON.object(["server":JSON(server),"tool":JSON(name),"startedAt":JSON(isoNow()),"state":"outcome-unknown-until-result-retained"]).data()
                    try bytes.write(to:outcomeMarker,options:.atomic)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:outcomeMarker.path)
                    let marker = try FileHandle(forWritingTo:outcomeMarker);try marker.synchronize();try marker.close()
                }
                dispatched=true;invoking=true
                let result = try await transport.request("tools/call", params:["name":JSON(name),"arguments":p["arguments"]])
                if let outcomeMarker { try FileManager.default.removeItem(at:outcomeMarker) }
                invoking=false;await gate.release(); return result
            } catch { invoking=false;if dispatched { unknownOutcome=true }; await gate.release(); throw error }
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
