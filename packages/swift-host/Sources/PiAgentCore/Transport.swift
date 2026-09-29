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
