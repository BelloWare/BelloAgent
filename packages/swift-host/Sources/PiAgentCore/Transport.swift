import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SSEEvent: Sendable { public let event: String, data: String; public let start: Int, end: Int }
/// Handles UTF-8, multi-line data, CR, LF, and CRLF split at arbitrary byte boundaries.
public struct SSEParser: Sendable {
    private var line = Data(), fields: [String] = [], kind = "message", skipLF = false, firstLine = true
    private var offset = 0, start = 0, eventBytes = 0
    public init() {}
    public mutating func feed(_ bytes: Data) throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            offset += 1
            if skipLF { skipLF = false; if byte == 10 { if fields.isEmpty && line.isEmpty { start = offset }; continue } }
            if byte == 10 || byte == 13 {
                guard var value = String(data: line, encoding: .utf8) else { throw AgentError("invalid_sse", "Stream contains invalid UTF-8") }
                if firstLine { firstLine=false; if value.hasPrefix("\u{feff}") { value.removeFirst() } }
                line.removeAll(keepingCapacity: true)
                if value.isEmpty {
                    if !fields.isEmpty { events.append(SSEEvent(event: kind, data: fields.joined(separator: "\n"), start: start, end: offset)) }
                    fields.removeAll(keepingCapacity: true); kind="message"; eventBytes=0; start=offset
                } else if !value.hasPrefix(":") {
                    let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    var data = parts.count == 2 ? String(parts[1]) : ""
                    if data.hasPrefix(" ") { data.removeFirst() }
                    if parts[0] == "data" { fields.append(data); eventBytes += data.utf8.count + 1 }
                    if parts[0] == "event" { kind=data }
                }
                skipLF = byte == 13
            } else { line.append(byte) }
            guard line.count <= 4*1024*1024, eventBytes + line.count <= 8*1024*1024 else { throw AgentError("stream_limit", "An SSE event exceeded the 8 MiB limit") }
        }
        return events
    }
    // EOF does not manufacture a final blank line. Providers must send their terminal event.
}
public enum HTTPPart: Sendable { case head(Int, [String: String]), bytes(Data, Double) }

/// Workspace-wide accounting for bytes received but not yet parsed. It
/// refuses nothing: a stream pauses its own download when its consumer falls
/// behind (`HTTPStream`). Only counters cross delegate queues.
final class HTTPIngressBudget: @unchecked Sendable {
    static let shared = HTTPIngressBudget()
    private let lock = NSLock()
    private var used = 0, high = 0
    func reserve(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        used += max(0, count); high = max(high, used)
    }
    func release(_ count: Int) { lock.lock(); used -= min(used, max(0, count)); lock.unlock() }
    var accounting: (used: Int, peak: Int) { lock.lock(); defer { lock.unlock() }; return (used, high) }
}

/// Long-lived ephemeral URL sessions for model requests: one per origin and
/// connection identity (the credential and configured headers), so requests
/// and tool rounds reuse keep-alive connections the way pi's fetch does
/// instead of paying DNS, TCP and TLS every time. No cookies, URL cache or
/// credential storage. The session has no delegate: each task's `HTTPStream`
/// is its own (`URLSessionTask.delegate`). A transport failure drops the
/// session, and a changed base URL or header set gets a session of its own.
final class HTTPSessionPool: @unchecked Sendable {
    static let shared = HTTPSessionPool()
    static let capacity = 8
    private let lock = NSLock()
    private var sessions: [String: (session: URLSession, queue: OperationQueue)] = [:]
    private var recency: [String] = []
    private var made = 0
    /// Sessions this pool has created, for tests.
    var created: Int { lock.lock(); defer { lock.unlock() }; return made }
    func session(for key: String) -> (session: URLSession, queue: OperationQueue) {
        lock.lock(); defer { lock.unlock() }
        if let existing = sessions[key] { recency.removeAll { $0 == key }; recency.append(key); return existing }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = HTTPStream.idleTimeout; config.timeoutIntervalForResource = HTTPStream.totalTimeout
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let entry = (session: URLSession(configuration: config, delegate: nil, delegateQueue: queue), queue: queue)
        sessions[key] = entry; recency.append(key); made += 1
        while recency.count > Self.capacity { sessions.removeValue(forKey: recency.removeFirst())?.session.finishTasksAndInvalidate() }
        return entry
    }
    /// Drops a session after a transport failure; its running tasks finish.
    func discard(_ session: URLSession) {
        lock.lock()
        let key = sessions.first { $0.value.session === session }?.key
        if let key { sessions.removeValue(forKey: key); recency.removeAll { $0 == key } }
        lock.unlock()
        if key != nil { session.finishTasksAndInvalidate() }
    }
    /// The origin and every header but the per-request ones.
    static func key(_ request: URLRequest, perRequest: Set<String>) -> String {
        let url = request.url
        let origin = "\(url?.scheme ?? "")://\(url?.host ?? ""):\(url?.port ?? -1)"
        let headers = (request.allHTTPHeaderFields ?? [:]).filter { !perRequest.contains($0.key.lowercased()) }
            .map { "\($0.key.lowercased()):\($0.value)" }.sorted()
        return ([origin] + headers).joined(separator: "\n")
    }
}

/// One delegate per request; model requests share a pooled session
/// (`HTTPSessionPool`), others get a session of their own. No global URL
/// interception and no unbounded tee.
///
/// Concurrency: `@unchecked` because URLSession calls its delegate from its own
/// queue. The invariant is that every mutable property except `continuation` is
/// read and written only while `lock` is held, and `continuation` is assigned
/// once inside `start` — before `task.resume()` makes any callback possible —
/// and thereafter only read, on a type that is itself thread-safe. `ended` is
/// entered exactly once in `start` and left exactly once on completion.
final class HTTPStream: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let ended = DispatchGroup()
    private var observed: JSON = [:]
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private let budget: HTTPIngressBudget
    /// Where the download pauses (a quarter of it) and resumes (an eighth):
    /// flow control, never a limit on what is received.
    private let bufferLimit: Int
    private var pendingBytes = 0, suspended = false
    private var pendingBody = Data(), inFlight = false, consumedBytes = 0, deliveredBytes = 0
    private var timingRuns: [(end: Int, at: Double)] = []
    private var completed = false, completionError: Error?
    private var delegateQueue: OperationQueue?
    private var pool: HTTPSessionPool?
    private var reused: Bool?
    /// Whether the request went out on a connection an earlier one opened.
    var reusedConnection: Bool? { lock.lock(); defer { lock.unlock() }; return reused }
    init(budget: HTTPIngressBudget = .shared, bufferLimit: Int = 4 * 1024 * 1024) {
        self.budget = budget; self.bufferLimit = max(1, bufferLimit)
        super.init()
    }
    deinit { budget.release(pendingBytes) }
    /// Called after the ordered capture/parser consumer finishes this chunk,
    /// including error and cancellation exits. Resuming is balanced under the
    /// delegate lock, so a simultaneous callback cannot invert suspend/resume.
    func consumed(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        let released = min(max(0, count), pendingBytes)
        pendingBytes -= released; budget.release(released)
        consumedBytes += released
        timingRuns.removeAll { $0.end <= consumedBytes }
        inFlight = false
        if suspended, pendingBytes <= bufferLimit / 8 {
            suspended = false; task?.resume()
        }
        // Flush already-received bytes after the current capture ACK. This
        // coalesces small callbacks without waiting for a future packet/ACK.
        delegateQueue?.addOperation { [weak self] in self?.flushBody() }
    }
    func receivedAt(byteOffset: Int, fallback: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        return timingRuns.first(where: { $0.end >= byteOffset })?.at ?? fallback
    }
    /// One 32 KiB body batch in flight to the ordered consumer. All remaining
    /// bytes are budgeted at ingress. Keep callback timestamps separately so
    /// batching never changes the content/terminal timing boundaries.
    private func flushBody() {
        lock.lock()
        guard !inFlight else { lock.unlock(); return }
        if !pendingBody.isEmpty {
            let count = min(32_768, pendingBody.count)
            let bytes = pendingBody.subdata(in: pendingBody.startIndex..<(pendingBody.startIndex + count))
            pendingBody.removeFirst(count); deliveredBytes += count; inFlight = true
            let time = timingRuns.first(where: { $0.end >= deliveredBytes })?.at ?? nowMS()
            lock.unlock(); yield(.bytes(bytes, time)); return
        }
        let done = completed, error = completionError
        lock.unlock()
        if done {
            if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
        }
    }
    private var continuation: AsyncThrowingStream<HTTPPart, Error>.Continuation?
    /// Pi's httpIdleTimeoutMs (300 s) bounds the wait for the response head
    /// and each gap in its body; pi sets no limit on a whole request, so the
    /// URL session's own week-long bound stays.
    static let idleTimeout: TimeInterval = 300
    static let totalTimeout: TimeInterval = 604_800
    func start(_ request: URLRequest, configuration: URLSessionConfiguration? = nil, pool: HTTPSessionPool? = nil, connection: String? = nil) -> AsyncThrowingStream<HTTPPart, Error> {
        // The queue retains whole, ordered delegate chunks. Byte admission is
        // paced BEFORE yield: the download pauses at 1 MiB pending and resumes
        // at 512 KiB. Callbacks already in flight are kept; nothing fails or is
        // dropped for size. Capture never holds the consumer (`TraceStore`).
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            self.continuation=continuation
            continuation.onTermination = { [weak self] _ in self?.cancel() }
            let session: URLSession, queue: OperationQueue, task: URLSessionDataTask
            if let pool, configuration == nil {
                // A pooled session is shared: the idle bound travels with the
                // request, the session keeps the same bounds, and this stream is
                // the task's own delegate, with its own parser state.
                var request = request; request.timeoutInterval = Self.idleTimeout
                let shared = pool.session(for: connection ?? HTTPSessionPool.key(request, perRequest: []))
                session = shared.session; queue = shared.queue
                task = session.dataTask(with: request); task.delegate = self
            } else {
                let config = configuration ?? URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest=Self.idleTimeout; config.timeoutIntervalForResource=Self.totalTimeout
                config.httpCookieStorage=nil; config.urlCredentialStorage=nil; config.urlCache=nil
                queue=OperationQueue(); queue.maxConcurrentOperationCount=1
                session=URLSession(configuration: config, delegate:self, delegateQueue:queue)
                task=session.dataTask(with: request)
            }
            lock.lock(); self.session=session; self.task=task; self.delegateQueue=queue; self.pool = configuration == nil ? pool : nil; lock.unlock()
            ended.enter()
            lock.lock(); observed["dispatch"] = JSON(nowMS()); observed["dispatchWallTimestamp"] = JSON(Date().timeIntervalSince1970); lock.unlock()
            task.resume()
        }
    }
    func observation() -> JSON { lock.lock(); defer { lock.unlock() }; return observed }
    func endObservation() async -> JSON {
        // Delegate completion is independent of the cancelled model task. Do
        // not invent EOF when URLSession has not acknowledged cancellation.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                _ = ended.wait(timeout: .now() + 1)
                continuation.resume(returning: observation())
            }
        }
    }
    func cancel() { lock.lock(); let task=self.task; lock.unlock(); task?.cancel() }
    private func yield(_ part: HTTPPart) {
        if case .dropped = continuation?.yield(part) {
            continuation?.finish(throwing: AgentError("stream_backpressure", "Consumer could not keep up; stream cancelled rather than silently dropping bytes")); cancel()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response=response as? HTTPURLResponse else { completionHandler(.cancel); return }
        var headers:[String:String]=[:]
        for (k,v) in response.allHeaderFields { headers[String(describing:k).lowercased()]=String(describing:v) }
        lock.lock(); observed["firstHTTPByte"] = JSON(nowMS()); lock.unlock()
        yield(.head(response.statusCode,headers)); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let time = nowMS()
        lock.lock()
        let received = (observed["responseObservedBytes"].int ?? 0) + data.count
        observed["responseObservedBytes"] = JSON(received)
        if !data.isEmpty && observed["firstBodyByte"].isNull { observed["firstBodyByte"] = JSON(time) }
        pendingBytes += data.count; budget.reserve(data.count)
        pendingBody.append(data); timingRuns.append((received, time))
        observed["peakPendingBodyBytes"] = JSON(max(observed["peakPendingBodyBytes"].int ?? 0, pendingBytes))
        if !suspended, pendingBytes >= bufferLimit / 4 { suspended = true; dataTask.suspend() }
        lock.unlock()
        flushBody()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        observed["httpEnd"] = JSON(nowMS())
        observed["transportOutcome"] = JSON(error == nil ? "eof" : (error as? URLError)?.code == .cancelled ? "cancelled" : "error")
        completed = true; completionError = error
        let pool = self.pool
        self.task=nil; self.session=nil; lock.unlock()
        ended.leave()
        flushBody()
        if let pool {
            // A connection or TLS failure drops the shared session: the next
            // request opens a fresh one. A cancelled request leaves it be.
            if let failure = error as? URLError, failure.code != .cancelled { pool.discard(session) }
        } else { session.finishTasksAndInvalidate() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); reused = metrics.transactionMetrics.last?.isReusedConnection; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A configured endpoint must not redirect credentials to another route or origin.
        completionHandler(nil)
    }
}

public actor TraceStore {
    /// Owned exclusively by this actor. Never published across an await; packets
    /// and inspector results are immutable values. A reference prevents dictionary
    /// lookups from copying the growing Data and event-array storage on every chunk.
    private final class Trace {
        var id: String, session: String, turn: String, api: String, url: String, purpose: String, mode: String
        var wallTime=isoNow(), dispatch:Double?, firstContent:Double?, firstText:Double?, completed:Double?, eof:Double?
        /// When the last output token arrived: the latest non-empty delta or
        /// output item completion. Never the terminal event, which carries no
        /// token and which a gateway can hold back while it computes usage.
        var lastContent:Double?
        var firstHTTPByte:Double?, firstBodyByte:Double?, transportOutcome="pending"
        var status:Int?, headers:JSON=[:], requestHeaders:JSON=[:], usage:JSON=[:], outcome="running", modelOutcome="pending"
        var request=Data(), response=Data(), requestObserved=0, responseObserved=0, rawEvents:[JSON]=[], rawEventCount=0
        var requestedModel = "", messageIDs: [String] = [], outputMessageIDs: [String] = [], persistenceError: String?
        var wallTimestamp = Date().timeIntervalSince1970, dispatchWallTimestamp:Double?
        var sentEventIndices = 0, eventIndexError = false
        var identity: RoutingIdentity?
        var operation: JSON = .null
        var gateway: GatewayTelemetry?
        /// The context links still to be sent: after dispatch, or at finish
        /// for a request that never went out.
        var contextLinksPending = false
        var credentials = CaptureCredentials(headers: [:], configuredNames: [])
        var requestCaptureBytes = 0, credentialRedactions = 0, credentialOmitted = false
        /// The app confirmed this request's final record.
        var finishSaved = false
        /// A persisted chat's bodies and raw events are in the app's log, and
        /// the helper let go of its copies.
        var savedToLog = false
        var responseMasker = CaptureCredentials.ResponseMasker(CaptureCredentials(headers: [:], configuredNames: []))
        var responseCaptureBytes = 0, responseCredentialRedactions = 0
        init(id: String, session: String, turn: String, api: String, url: String, purpose: String, mode: String) {
            self.id = id; self.session = session; self.turn = turn; self.api = api
            self.url = url; self.purpose = purpose; self.mode = mode
        }
    }
    private var traces:[String:Trace]=[:], order:[String]=[], modes:[String:String]=[:]
    /// A decode span shorter than this is a reply delivered in one burst, not
    /// a measured generation: it contributes no tokens-per-second rate.
    public static let minimumDecodeSpanMs = 250.0
    /// Body bytes the helper holds: every request's until the app has saved
    /// it, and a session-memory chat's for good (they are its only copy).
    /// Nothing is capped or cut.
    private var retainedBytes = 0
    private let sink: @Sendable (JSON) async -> Bool
    public init(sink: @escaping @Sendable (JSON) async -> Bool = { _ in true }) { self.sink = sink }
    public func mode(_ session:String)->String { modes[session] ?? "memory" }
    public func begin(session:String, turn:String, profile:Profile, purpose:String, body:Data, headers:[String:String], messageIDs: [String] = []) async ->String {
        let id=UUID().uuidString, mode=mode(session)
        let t=Trace(id:id,session:session,turn:turn,api:profile.api,url:profile.endpoint.absoluteString,purpose:purpose,mode:mode)
        t.credentials = CaptureCredentials(headers: headers, configuredNames: Set(profile.raw["headers"].map.keys))
        t.responseMasker = CaptureCredentials.ResponseMasker(t.credentials)
        let captured = t.credentials.requestBody(body)
        t.requestCaptureBytes = captured.bytes.count; t.credentialRedactions = captured.replacements; t.credentialOmitted = captured.omitted
        t.requestObserved=body.count; if mode != "off" { t.request=captured.bytes }
        t.requestHeaders=t.credentials.requestHeaders(headers)
        if t.credentials.contains(t.url.removingPercentEncoding ?? t.url) { t.url = CaptureCredentials.fingerprint(t.url) }
        t.identity=RoutingIdentity(profile:profile); t.gateway=GatewayTelemetry(profile:profile); t.requestedModel=profile.model; t.messageIDs=Array(Set(messageIDs)).sorted()
        traces[id]=t; retainedBytes += t.request.count; order.append(id)
        // The attempt is recorded before dispatch, and the request goes out
        // without waiting for the app to save it: its packets are queued.
        // Its context links (every message id the request carries, one packet
        // per 512) follow once the request is on its way.
        post(["type":"begin", "metadata":metadata(t, messageIDs:false)], attempt: id, stage: .begin)
        t.contextLinksPending = true
        if mode == "persist" { deliverBytes(id, kind:"request", offset:0, bytes:captured.bytes) }
        return id
    }
    private func deliverLinks(_ id: String, field: String, ids: [String]) {
        for start in stride(from: 0, to: ids.count, by: 512) {
            var packet: JSON = ["type":"links", "attemptId":JSON(id)]
            packet[field] = .array(Array(ids.dropFirst(start).prefix(512)).map { JSON($0) })
            post(packet, attempt: id, stage: .links)
        }
    }
    private func deliverBytes(_ id: String, kind: String, offset: Int, bytes: Data) {
        for start in stride(from: 0, to: bytes.count, by: 32_768) {
            let page = bytes.subdata(in: start..<min(start + 32_768, bytes.count))
            // A page that continues this request's page still waiting joins
            // it, up to 32 KiB, when nothing else of the request was queued
            // after it: while the app is busy, a stream's small chunks go as
            // one page instead of one acknowledgment each.
            if let index = openPages[id], index >= outboxHead, index < outbox.count, var waiting = outbox[index].page,
               waiting.body == kind, waiting.offset + waiting.bytes.count == offset + start, waiting.bytes.count + page.count <= 32_768 {
                waiting.bytes.append(page); outbox[index].page = waiting
            } else {
                post(.null, attempt: id, stage: .bytes, page: Page(body: kind, offset: offset + start, bytes: page))
            }
        }
    }
    public func head(_ id:String, status:Int, headers:[String:String]) {
        guard let t=traces[id] else { return }; t.status=status
        let credentials = t.credentials
        t.identity?.head(headers, excluding: credentials.contains)
        t.gateway?.head(headers, excluding: credentials.contains)
        t.headers=credentials.responseHeaders(headers,metadataHeaders:(t.identity?.contract.headers ?? []).union(t.gateway?.headers ?? []))
    }
    public func reported(_ id:String, value:JSON, streaming:Bool) {
        guard let t = traces[id] else { return }; let credentials = t.credentials
        t.identity?.body(value,streaming:streaming,excluding: credentials.contains)
        t.gateway?.body(value,streaming:streaming,excluding: credentials.contains)
    }
    public func identity(_ id:String) -> JSON { guard let t = traces[id] else { return .null }; return t.credentials.metadata(t.identity?.json ?? .null) }
    /// Only checked numerical/identity metadata crosses the popup boundary.
    func monitoring(_ id: String) -> JSON {
        guard let t = traces[id] else { return [:] }
        let identity = t.credentials.metadata(t.identity?.json ?? .null), gateway = t.gateway?.json ?? .null
        // `outcome` leaves "running" once the attempt has ended: its cost is
        // final then, and the session adds it to the chat's spend.
        return ["identity":["status":identity["status"], "effectiveModel":identity["effectiveModel"]],
                "gateway":["version":1, "cost":["status":gateway["cost"]["status"], "usd":gateway["cost"]["usd"]]],
                "outcome":JSON(t.outcome),
                "dispatch":t.dispatch.map { JSON($0) } ?? .null, "firstContent":t.firstContent.map { JSON($0) } ?? .null,
                "modelComplete":t.completed.map { JSON($0) } ?? .null, "httpEnd":t.eof.map { JSON($0) } ?? .null,
                "dispatchWall":t.dispatchWallTimestamp.map { JSON($0) } ?? .null]
    }
    public func append(_ id:String, data:Data) async {
        guard let t=traces[id] else { return }; t.responseObserved += data.count
        let previousRedactions = t.responseCredentialRedactions
        let captured = t.mode == "off" ? Data() : t.responseMasker.feed(data)
        let offset = t.responseCaptureBytes
        t.responseCaptureBytes += captured.count; t.responseCredentialRedactions = t.responseMasker.replacements
        if t.mode != "off" { t.response.append(captured); retainedBytes += captured.count }
        if t.mode == "persist" {
            publishResponseTransformation(t, previousRedactions: previousRedactions)
            deliverBytes(id, kind:"response", offset:offset, bytes:captured)
        }
    }
    private func flushResponse(_ id: String) {
        guard let t = traces[id], t.mode != "off" else { return }
        let previousRedactions = t.responseCredentialRedactions
        let captured = t.responseMasker.feed(Data(), final: true), offset = t.responseCaptureBytes
        t.responseCaptureBytes += captured.count; t.responseCredentialRedactions = t.responseMasker.replacements
        t.response.append(captured); retainedBytes += captured.count
        if t.mode == "persist" {
            publishResponseTransformation(t, previousRedactions: previousRedactions)
            deliverBytes(id, kind: "response", offset: offset, bytes: captured)
        }
    }
    private func publishResponseTransformation(_ trace: Trace, previousRedactions: Int) {
        guard previousRedactions == 0, trace.responseCredentialRedactions > 0 else { return }
        // Publish the exception before its bytes, including during a live
        // stream or a cancelled tail; the inspector must never label them exact.
        post(["type": "metadata", "metadata": metadata(trace, messageIDs:false)], attempt: trace.id, stage: .masking)
    }
    public func event(_ id:String, _ event:SSEEvent) async {
        guard let t=traces[id] else { return }
        t.rawEvents.append(["type":JSON(preview(event.event, bytes:128)),"start":JSON(event.start),"end":JSON(event.end),"observedAt":JSON(nowMS())])
        t.rawEventCount += 1
        if t.mode == "persist", t.rawEvents.count - t.sentEventIndices >= 128 { flushEvents(id) }
    }
    private func flushEvents(_ id: String) {
        guard let trace = traces[id], trace.mode == "persist", trace.sentEventIndices < trace.rawEvents.count else { return }
        let offset = trace.sentEventIndices, page = Array(trace.rawEvents.dropFirst(offset).prefix(128))
        trace.sentEventIndices += page.count
        post(["type":"events", "attemptId":JSON(id), "offset":JSON(offset), "events":.array(page)], attempt: id, stage: .events)
    }
    public func dispatched(_ id: String, at time: Double, wall: Double = Date().timeIntervalSince1970) async {
        traces[id]?.dispatch = time; traces[id]?.dispatchWallTimestamp = wall
        if let t = traces[id] { post(["type":"metadata", "metadata":metadata(t, messageIDs:false)], attempt: id, stage: .update) }
        deliverContextLinks(id)
    }
    private func deliverContextLinks(_ id: String) {
        guard let t = traces[id], t.contextLinksPending else { return }
        t.contextLinksPending = false
        deliverLinks(id, field: "messageIds", ids: t.messageIDs)
    }
    /// An output item opened, of any kind: the model started generating, so
    /// the first opening can be the first output. It carries no token itself.
    public func opened(_ id:String, at time:Double) { guard let t=traces[id] else { return }; if t.firstContent==nil { t.firstContent=time } }
    /// A non-empty delta (text, reasoning, a tool's name or arguments): output
    /// arrived. The earliest is the first output, the latest the last.
    public func content(_ id:String, text:Bool, at time:Double) {
        guard let t=traces[id] else { return }
        if t.firstContent==nil { t.firstContent=time }; if text && t.firstText==nil { t.firstText=time }
        produced(t, at: time)
    }
    /// An output item completed; a reasoning item's completion is the end of
    /// its hidden reasoning. Its last token has arrived by now.
    public func closed(_ id:String, at time:Double) { guard let t=traces[id] else { return }; produced(t, at: time) }
    /// Output that only a final body carried (a gateway that sends no deltas,
    /// or a JSON response): it all arrived with that body, unless deltas or
    /// item completions already said when it did.
    public func finalContent(_ id:String, text:Bool, at time:Double) {
        guard let t=traces[id] else { return }
        if t.firstContent==nil { t.firstContent=time }; if text && t.firstText==nil { t.firstText=time }
        if t.lastContent==nil { produced(t, at: time) }
    }
    /// Output evidence after the model's terminal event is not a token of
    /// this response: the decode span never ends after the terminal.
    private func produced(_ t:Trace, at time:Double) {
        guard t.completed == nil, time.isFinite else { return }
        t.lastContent = max(t.lastContent ?? time, time)
    }
    public func terminal(_ id:String, at time:Double) { if traces[id]?.completed == nil { traces[id]?.completed=time } }
    public func transport(_ id:String, observation:JSON) {
        guard let t=traces[id] else { return }
        t.dispatch=observation["dispatch"].double; t.dispatchWallTimestamp=observation["dispatchWallTimestamp"].double ?? t.dispatchWallTimestamp;
        t.responseObserved=max(t.responseObserved,observation["responseObservedBytes"].int ?? 0); t.firstHTTPByte=observation["firstHTTPByte"].double
        t.firstBodyByte=observation["firstBodyByte"].double; t.eof=observation["httpEnd"].double
        t.transportOutcome=observation["transportOutcome"].text ?? "unobserved"
    }
    public func usage(_ id:String, _ usage:JSON) { traces[id]?.usage=usage }
    public func operation(_ id:String, _ value:JSON) async {
        guard let trace=traces[id] else { return }
        trace.operation=value
        // Semantic summary validation happens after HTTP completion. Persist
        // its diagnosis too, including attempts that produced no checkpoint.
        if trace.outcome != "running" { post(["type":"metadata","metadata":metadata(trace, messageIDs:false)], attempt: id, stage: .operation) }
    }
    public func finish(_ id:String, outcome:String, modelOutcome:String) async {
        deliverContextLinks(id)
        flushResponse(id)
        flushEvents(id)
        traces[id]?.outcome=outcome; traces[id]?.modelOutcome=modelOutcome
        if let trace = traces[id] { post(["type":"finish", "metadata":metadata(trace, messageIDs:false)], attempt: id, stage: .finish) }
    }
    public func outputs(_ id: String, messageIDs: [String]) async {
        if let trace = traces[id] { trace.outputMessageIDs=Array(Set(trace.outputMessageIDs + messageIDs)).sorted() }
        deliverLinks(id, field: "outputMessageIds", ids: messageIDs)
    }
    // MARK: Delivery to the app's request log

    /// What a rejected packet means for its request's later packets.
    private enum Stage { case begin, update, links, bytes, masking, events, operation, finish }
    private struct Outgoing { let packet: JSON; let attempt: String; let stage: Stage; var page: Page? }
    /// A body page's bytes stay raw until sent, so a later page can join it.
    private struct Page { let body: String, offset: Int; var bytes: Data }
    private struct Delivery { var refused = false, bytesStopped = false, linksStopped = false, eventsStopped = false }
    /// Every capture packet, in the order it was made. One consumer sends
    /// them, each after the app confirmed the one before. Neither a model
    /// request nor its stream waits on this queue: a slow app delays its log,
    /// never the chat, and nothing is dropped for being slow.
    private var outbox: [Outgoing] = [], outboxHead = 0, draining = false
    /// Each request's last queued packet, when it is a body page: the page a
    /// following chunk of the same body may join.
    private var openPages: [String: Int] = [:]
    private var deliveries: [String: Delivery] = [:]
    private var idle: [CheckedContinuation<Void, Never>] = []
    private func post(_ packet: JSON, attempt: String, stage: Stage, page: Page? = nil) {
        outbox.append(Outgoing(packet: packet, attempt: attempt, stage: stage, page: page))
        if page != nil { openPages[attempt] = outbox.count - 1 } else { openPages.removeValue(forKey: attempt) }
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }
    /// Returns once every packet queued so far has been answered. Nothing in
    /// a chat waits on this; tests read the log after it.
    func delivered() async {
        guard draining else { return }
        await withCheckedContinuation { idle.append($0) }
    }
    private func drain() async {
        while outboxHead < outbox.count {
            let item = outbox[outboxHead]; outboxHead += 1
            if outboxHead >= 256, outboxHead * 2 >= outbox.count {
                outbox.removeFirst(outboxHead)
                openPages = openPages.compactMapValues { $0 >= outboxHead ? $0 - outboxHead : nil }; outboxHead = 0
            }
            let delivery = deliveries[item.attempt] ?? Delivery()
            // A request the log refused, or a kind of packet it stopped taking
            // for that request, sends nothing more of that kind.
            if delivery.refused || (item.stage == .bytes && delivery.bytesStopped) || (item.stage == .links && delivery.linksStopped)
                || (item.stage == .events && delivery.eventsStopped) { continue }
            let packet: JSON = item.page.map { ["type":"bytes", "attemptId":JSON(item.attempt), "body":JSON($0.body), "offset":JSON($0.offset), "bytes":JSON($0.bytes.base64EncodedString())] } ?? item.packet
            let accepted = await sink(packet)
            recorded(item.stage, accepted: accepted, attempt: item.attempt)
        }
        outbox.removeAll(); outboxHead = 0; draining = false; openPages.removeAll()
        let waiting = idle; idle.removeAll()
        for waiter in waiting { waiter.resume() }
    }
    private func recorded(_ stage: Stage, accepted: Bool, attempt id: String) {
        var delivery = deliveries[id] ?? Delivery()
        let trace = traces[id]
        switch stage {
        case .begin:
            if !accepted { delivery.refused = true; trace?.persistenceError = "Native request recorder was unavailable at dispatch" }
        case .bytes:
            if !accepted { delivery.bytesStopped = true; trace?.persistenceError = "Native payload retention stopped; inspect the durable prefix and metrics" }
        case .masking:
            if !accepted { delivery.bytesStopped = true; trace?.persistenceError = "Native recorder could not acknowledge response credential masking; body retention stopped" }
        case .links:
            if !accepted { delivery.linksStopped = true; if trace?.persistenceError == nil { trace?.persistenceError = "Native message/request links were not durably acknowledged" } }
        case .events:
            if !accepted { delivery.eventsStopped = true; trace?.eventIndexError = true }
        case .operation:
            if !accepted { trace?.persistenceError = "Native recorder could not acknowledge compaction outcome metadata" }
        case .update: break
        case .finish:
            if !accepted { trace?.persistenceError = "Native request finalization was unavailable; durable request remains interrupted" }
            else if let trace { saved(trace, complete: !delivery.bytesStopped && !delivery.eventsStopped && !delivery.linksStopped) }
        }
        // A cleared or released request's late packets leave no state behind.
        if traces[id] != nil { deliveries[id] = delivery } else { deliveries.removeValue(forKey: id) }
    }
    /// The app confirmed a request's final record. When it also took every
    /// page of a persisted chat's request (bodies, raw events and links), that
    /// log holds all of it, so the helper lets go of its copies; otherwise the
    /// helper's copy is the complete one and stays. A session-memory chat keeps
    /// everything, as the helper holds its only copy. Output links and a
    /// compaction's outcome can still follow a final record, so a saved record
    /// itself goes only once a later request of the same chat has been saved.
    private func saved(_ trace: Trace, complete: Bool) {
        trace.finishSaved = true
        guard trace.mode != "memory" else { return }
        if trace.mode == "persist", complete {
            retainedBytes -= trace.request.count + trace.response.count
            trace.request = Data(); trace.response = Data(); trace.rawEvents = []
            trace.savedToLog = true
        }
        let earlier = Set(order.filter { id in
            guard id != trace.id, let other = traces[id] else { return false }
            return other.session == trace.session && other.finishSaved && (other.savedToLog || other.mode == "off")
        })
        guard !earlier.isEmpty else { return }
        for id in earlier {
            if let old = traces.removeValue(forKey: id) { retainedBytes -= old.request.count + old.response.count }
            deliveries.removeValue(forKey: id)
        }
        order.removeAll { earlier.contains($0) }
    }
    private func bodyInfo(_ t:Trace, request:Bool)->JSON {
        let observed=request ? t.requestObserved:t.responseObserved
        let captured = request ? t.requestCaptureBytes : t.responseCaptureBytes
        // Every captured byte is kept: in the helper until the app has saved
        // it, and then in the app's log.
        let retained = t.savedToLog ? captured : request ? t.request.count : t.response.count
        let omitted = request && t.credentialOmitted, redactions = request ? t.credentialRedactions : t.responseCredentialRedactions
        let redacted = redactions > 0
        let state=t.mode=="off" ? "not-captured":omitted ? "credential-omitted":!request && (t.transportOutcome != "eof" || captured < observed) ? "partial":redacted ? (request ? "credential-hashed" : "credential-masked"):"complete"
        var result:JSON = ["state":JSON(state),"observedBytes":JSON(observed),"retainedBytes":JSON(retained),"savedToLog":JSON(t.savedToLog),"reason": t.mode=="off" ? "Capture was disabled" : omitted ? "Credential replacement exceeded capture safety limits; request body was not retained." : .null]
        if request {
            result["captureBytes"] = JSON(captured); result["credentialRedactions"] = JSON(t.credentialRedactions); result["byteExact"] = JSON(!redacted && !omitted)
            result["transformations"] = .array(omitted ? ["Request body omitted because credential replacement exceeded capture safety limits. No request-body bytes were retained."] : redacted ? ["Known authentication credential bytes replaced by labeled SHA-256 fingerprints. Offsets and hashes describe retained transformed bytes, not the submitted wire body."] : [])
        } else {
            result["captureBytes"] = JSON(t.responseCaptureBytes); result["credentialRedactions"] = JSON(redactions); result["byteExact"] = JSON(!redacted)
            result["transformations"] = .array(redacted ? ["Known authentication credential echoes replaced by same-length asterisks in captured response bytes only. SSE byte offsets remain unchanged; hashes describe the masked capture, not the original received body."] : [])
        }
        return result
    }
    private func metrics(_ t:Trace)->JSON {
        func span(_ start: Double?, _ end: Double?) -> JSON {
            guard let start, let end, start.isFinite, end.isFinite, end >= start, (end-start).isFinite else { return .null }; return JSON(end-start)
        }
        let output=t.usage["output"].double
        // The decode span, which the stream duration reports and the rate
        // divides by: first output → last output (the latest non-empty delta
        // or output item completion). It exists once the model's terminal event
        // was observed. An attempt that stamped no last output ends at that
        // terminal, the only end it has; the archive projects `stream_ms` by
        // the same rule, so the Inspector, the report and the ledger agree.
        let decode = span(t.firstContent, t.completed.map { t.lastContent ?? $0 })
        // The settled decode rate, the standard decode speed (LLMPerf, vLLM's
        // TPOT): the reported output tokens after the first (N − 1, reasoning
        // included) over that span. Over it the first token is already out, so
        // only N − 1 arrive in it, and the terminal event carries none. Only
        // the gateway's completed usage is a token count; one token has no
        // decode speed, and a span shorter than the floor is no measurement.
        var decodeRate: JSON = .null
        if t.outcome == "completed", t.modelOutcome == "completed", let decodeMS = decode.double, decodeMS >= Self.minimumDecodeSpanMs,
           let output, output.isFinite, output >= 2, ((output - 1) / (decodeMS / 1000)).isFinite { decodeRate = JSON((output - 1) / (decodeMS / 1000)) }
        return ["observedTTFTms":span(t.dispatch,t.firstContent), "firstTextMs":span(t.dispatch,t.firstText),
                "streamDurationMs":decode, "httpDurationMs":span(t.dispatch,t.eof),
                "decodeTokensPerSecond":decodeRate, "minimumDecodeSpanMs":JSON(Self.minimumDecodeSpanMs),
                "inputIncludingCache":t.usage["inputIncludingCache"],"completeness":t.modelOutcome=="completed" ? "complete":"partial",
                "rateSource":"Gateway-reported output tokens after the first (N − 1, reasoning included) / first output → last output token (the model terminal when no last output was stamped); completed attempts with N ≥ 2 over at least minimumDecodeSpanMs","liveTokenRate":.null]
    }
    /// An attempt's metadata. `messageIDs: false` leaves out the context and
    /// output id lists: the recorder is sent those as `links` packets, and a
    /// session snapshot's `latestAttempt` (4 Hz while busy, and every idle
    /// poll) never reads them, while at 1,000 messages they were ~39 KB.
    private func metadata(_ t:Trace, messageIDs:Bool = true)->JSON {
        var value:JSON = ["attemptId":JSON(t.id),"sessionId":JSON(t.session),"turnId":JSON(t.turn),"api":JSON(t.api),"purpose":JSON(t.purpose),"mode":JSON(t.mode),"wallTime":JSON(t.wallTime),"method":"POST","url":JSON(t.url),"status":t.status.map { JSON($0) } ?? .null,
         "outcome":JSON(t.outcome),"modelOutcome":JSON(t.modelOutcome),"transportOutcome":JSON(t.transportOutcome),"requestHeaders":t.requestHeaders,"responseHeaders":t.headers,"usage":t.usage,"gateway":t.gateway?.json ?? .null,"operation":t.operation,
         "identity":t.credentials.metadata(t.identity?.json ?? .null),"requestedModel":JSON(t.credentials.metadataText(t.requestedModel)),"wallTimestamp":JSON(t.wallTimestamp),"persistenceError":t.persistenceError.map { JSON($0) } ?? .null,
         "rawEventsOmitted":0,"eventIndexPersistenceError":JSON(t.eventIndexError),
         "request":bodyInfo(t,request:true),"response":bodyInfo(t,request:false),"metrics":metrics(t),"rawEventIndexCount":JSON(t.rawEventCount),
         "timingVersion":2,"dispatchWallTimestamp":t.dispatchWallTimestamp.map { JSON($0) } ?? .null,
         "timingBoundary":"Monotonic URLSession dispatch, header callback (first HTTP observation), decoded body callbacks, body bytes containing parsed content/terminal, and task completion. Not socket/TLS or paint timing.",
         "timings":["dispatch":t.dispatch.map { JSON($0) } ?? .null,"firstHTTPByte":t.firstHTTPByte.map { JSON($0) } ?? .null,"firstBodyByte":t.firstBodyByte.map { JSON($0) } ?? .null,"firstContent":t.firstContent.map { JSON($0) } ?? .null,"firstText":t.firstText.map { JSON($0) } ?? .null,"lastContent":t.lastContent.map { JSON($0) } ?? .null,"modelComplete":t.completed.map { JSON($0) } ?? .null,"httpEnd":t.eof.map { JSON($0) } ?? .null]]
        if messageIDs { value["messageIds"] = .array(t.messageIDs.map { JSON($0) }); value["outputMessageIds"] = .array(t.outputMessageIDs.map { JSON($0) }) }
        return value
    }
    public func latest(_ session:String)->JSON { guard let id=order.last(where:{traces[$0]?.session==session}),let t=traces[id] else { return .null }; return metadata(t, messageIDs:false) }
    public func command(_ method:String, session:String, params p:JSON) throws -> JSON {
        let boundary:JSON="Application HTTP boundary after serialization and HTTP decoding, not TLS packets. Gateway upstream traffic is unavailable. Authentication headers are masked; long request tokens retain only their last four characters, and short tokens, cookies and secret response headers are fully masked. Known credential literals in request bodies are labeled SHA-256 fingerprints; response credential echoes are replaced by same-length asterisks. Body transformations are explicit byte-exactness exceptions. Other captured bytes remain untransformed and sensitive."
        if method=="debug.mode" {
            guard let mode=p["mode"].text,["off","memory","persist"].contains(mode) else { throw AgentError("invalid_mode","Choose off, memory or persist") }
            // The native UI owns explicit trace-file export/persistence.
            modes[session]=mode; return ["mode":JSON(mode),"appliesTo":"future attempts; existing captures are cleared separately"]
        }
        if method=="debug.clear" {
            guard !traces.values.contains(where:{$0.session==session && $0.outcome=="running"}) else { throw AgentError("capture_busy", "Stop the active request before clearing body captures") }
            let ids=Set(order.filter{traces[$0]?.session==session}); ids.forEach { if let old = traces.removeValue(forKey: $0) { retainedBytes -= old.request.count + old.response.count }; deliveries.removeValue(forKey: $0) }; order.removeAll{ids.contains($0)}; return ["cleared":true]
        }
        if method=="debug.list" {
            let all=order.reversed().compactMap{traces[$0]}.filter{$0.session==session}, offset=try boundedInt(p["offset"],maximum:Int.max)
            let page=Array(all.dropFirst(offset).prefix(64))
            return ["attempts":.array(page.map { metadata($0) }),"total":JSON(all.count),"next":offset+page.count<all.count ? JSON(offset+page.count):.null,"mode":JSON(mode(session)),"boundary":boundary,"workspaceRetainedBytes":JSON(retainedBytes)]
        }
        guard let id=p["attemptId"].text,let t=traces[id],t.session==session else { throw AgentError("capture_unavailable","Attempt is unavailable or belongs to another session") }
        if method=="debug.attempt" { var v=metadata(t); v["boundary"]=boundary;v["requestHash"]=t.mode=="off" || t.savedToLog ? .null:["sha256":JSON(sha256(t.request)),"scope":"retained bytes"];v["responseHash"]=t.mode=="off" || t.savedToLog ? .null:["sha256":JSON(sha256(t.response)),"scope":"retained bytes"]; return v }
        // A saved request's bodies and events are read from the app's log.
        guard !t.savedToLog else { throw AgentError("capture_saved","This request is saved in the app's request log; read it there") }
        if method=="debug.raw-events" { let offset=try boundedInt(p["offset"],maximum:Int.max); return ["events":.array(Array(t.rawEvents.dropFirst(offset).prefix(128))),"total":JSON(t.rawEvents.count),"response":bodyInfo(t,request:false),"omitted":0] }
        if method=="debug.body" {
            guard ["request","response"].contains(p["body"].text ?? "") else { throw AgentError("invalid_body","Choose request or response") }
            let request=p["body"].text=="request", body=request ? t.request:t.response, offset=try boundedInt(p["offset"],maximum:Int.max)
            guard offset<=body.count else { throw AgentError("invalid_range","Offset exceeds retained bytes") }
            let end=min(body.count,offset+32768);var v=bodyInfo(t,request:request)
            v["offset"]=JSON(offset);v["bytes"]=JSON(body.subdata(in:offset..<end).base64EncodedString());v["next"]=end<body.count ? JSON(end):.null;return v
        }
        throw AgentError("unsupported_debug_command","Unsupported inspector operation")
    }
}
