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

/// One delegate/URLSession per request. No global URL interception and no unbounded tee.
final class HTTPStream: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let ended = DispatchGroup()
    private var observed: JSON = [:]
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var continuation: AsyncThrowingStream<HTTPPart, Error>.Continuation?
    func start(_ request: URLRequest) -> AsyncThrowingStream<HTTPPart, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            self.continuation=continuation
            continuation.onTermination = { [weak self] _ in self?.cancel() }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest=120; config.timeoutIntervalForResource=1800
            config.httpCookieStorage=nil; config.urlCredentialStorage=nil; config.urlCache=nil
            let queue=OperationQueue(); queue.maxConcurrentOperationCount=1
            let session=URLSession(configuration: config, delegate:self, delegateQueue:queue)
            let task=session.dataTask(with: request)
            lock.lock(); self.session=session; self.task=task; lock.unlock()
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
        lock.lock(); observed["responseObservedBytes"] = JSON((observed["responseObservedBytes"].int ?? 0) + data.count); if !data.isEmpty && observed["firstBodyByte"].isNull { observed["firstBodyByte"] = JSON(time) }; lock.unlock()
        yield(.bytes(data, time))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        observed["httpEnd"] = JSON(nowMS())
        observed["transportOutcome"] = JSON(error == nil ? "eof" : (error as? URLError)?.code == .cancelled ? "cancelled" : "error")
        self.task=nil; self.session=nil; lock.unlock()
        ended.leave()
        if let error { continuation?.finish(throwing:error) } else { continuation?.finish() }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A configured endpoint must not redirect credentials to another route or origin.
        completionHandler(nil)
    }
}

public actor TraceStore {
    struct Trace: Sendable {
        var id: String, session: String, turn: String, api: String, url: String, purpose: String, mode: String
        var wallTime=isoNow(), dispatch:Double?, firstContent:Double?, firstText:Double?, completed:Double?, eof:Double?
        var firstHTTPByte:Double?, firstBodyByte:Double?, transportOutcome="pending"
        var status:Int?, headers:JSON=[:], requestHeaders:JSON=[:], usage:JSON=[:], outcome="running", modelOutcome="pending"
        var request=Data(), response=Data(), requestObserved=0, responseObserved=0, rawEvents:[JSON]=[], rawEventsDropped=0
        var requestedModel = "", messageIDs: [String] = [], outputMessageIDs: [String] = [], persistenceError: String?
        var wallTimestamp = Date().timeIntervalSince1970, dispatchWallTimestamp:Double?
        var sentEventIndices = 0, eventIndexError = false
        var identity: RoutingIdentity?
        var gateway: GatewayTelemetry?
        var credentials = CaptureCredentials(headers: [:], configuredNames: [])
        var requestCaptureBytes = 0, credentialRedactions = 0, credentialOmitted = false
        var responseMasker = CaptureCredentials.ResponseMasker(CaptureCredentials(headers: [:], configuredNames: []))
        var responseCaptureBytes = 0, responseCredentialRedactions = 0
    }
    private var traces:[String:Trace]=[:], order:[String]=[], modes:[String:String]=[:], droppedMetadata=0
    public static let perBodyLimit=8*1024*1024, totalLimit=128*1024*1024
    private let sink: @Sendable (JSON) async -> Bool
    public init(sink: @escaping @Sendable (JSON) async -> Bool = { _ in true }) { self.sink = sink }
    public func mode(_ session:String)->String { modes[session] ?? "memory" }
    public func begin(session:String, turn:String, profile:Profile, purpose:String, body:Data, headers:[String:String], messageIDs: [String] = []) async ->String {
        let id=UUID().uuidString, mode=mode(session)
        var t=Trace(id:id,session:session,turn:turn,api:profile.api,url:profile.endpoint.absoluteString,purpose:purpose,mode:mode)
        t.credentials = CaptureCredentials(headers: headers, configuredNames: Set(profile.raw["headers"].map.keys))
        t.responseMasker = CaptureCredentials.ResponseMasker(t.credentials)
        let captured = t.credentials.requestBody(body)
        t.requestCaptureBytes = captured.bytes.count; t.credentialRedactions = captured.replacements; t.credentialOmitted = captured.omitted
        t.requestObserved=body.count; if mode != "off" { t.request=captured.bytes.prefix(Self.perBodyLimit) }
        t.requestHeaders=t.credentials.requestHeaders(headers)
        if t.credentials.contains(t.url.removingPercentEncoding ?? t.url) { t.url = CaptureCredentials.fingerprint(t.url) }
        t.identity=RoutingIdentity(profile:profile); t.gateway=GatewayTelemetry(profile:profile); t.requestedModel=profile.model; t.messageIDs=Array(Set(messageIDs)).sorted()
        traces[id]=t; order.append(id); trim()
        if !(await sink(["type":"begin", "metadata":metadata(t).removing(["messageIds", "outputMessageIds"])])) { traces[id]?.persistenceError="Native request recorder was unavailable at dispatch" }
        else { await deliverLinks(id, field: "messageIds", ids: t.messageIDs) }
        if mode == "persist" { await deliverBytes(id, kind:"request", offset:0, bytes:captured.bytes) }
        return id
    }
    private func deliverLinks(_ id: String, field: String, ids: [String]) async {
        for start in stride(from: 0, to: ids.count, by: 512) {
            var packet: JSON = ["type":"links", "attemptId":JSON(id)]
            packet[field] = .array(Array(ids.dropFirst(start).prefix(512)).map { JSON($0) })
            if !(await sink(packet)) { traces[id]?.persistenceError="Native message/request links were not durably acknowledged"; return }
        }
    }
    private func deliverBytes(_ id: String, kind: String, offset: Int, bytes: Data) async {
        guard traces[id]?.persistenceError == nil else { return }
        for start in stride(from: 0, to: bytes.count, by: 32_768) {
            let page = bytes.subdata(in: start..<min(start + 32_768, bytes.count))
            if !(await sink(["type":"bytes", "attemptId":JSON(id), "body":JSON(kind), "offset":JSON(offset+start), "bytes":JSON(page.base64EncodedString())])) {
                traces[id]?.persistenceError="Native payload retention stopped; inspect the durable prefix and metrics"; return
            }
        }
    }
    public func head(_ id:String, status:Int, headers:[String:String]) {
        guard var t=traces[id] else { return }; t.status=status
        let credentials = t.credentials
        t.identity?.head(headers, excluding: credentials.contains)
        t.gateway?.head(headers, excluding: credentials.contains)
        t.headers=credentials.responseHeaders(headers,metadataHeaders:(t.identity?.contract.headers ?? []).union(t.gateway?.headers ?? [])); traces[id]=t
    }
    public func reported(_ id:String, value:JSON, streaming:Bool) {
        guard var t = traces[id] else { return }; let credentials = t.credentials
        t.identity?.body(value,streaming:streaming,excluding: credentials.contains)
        t.gateway?.body(value,streaming:streaming,excluding: credentials.contains); traces[id] = t
    }
    public func identity(_ id:String) -> JSON { guard let t = traces[id] else { return .null }; return t.credentials.metadata(t.identity?.json ?? .null) }
    public func append(_ id:String, data:Data) async {
        guard var t=traces[id] else { return }; t.responseObserved += data.count
        let previousRedactions = t.responseCredentialRedactions
        let captured = t.mode == "off" ? Data() : t.responseMasker.feed(data)
        let offset = t.responseCaptureBytes
        t.responseCaptureBytes += captured.count; t.responseCredentialRedactions = t.responseMasker.replacements
        if t.mode != "off" { t.response.append(captured.prefix(max(0,Self.perBodyLimit-t.response.count))) }
        traces[id]=t; trim()
        if t.mode == "persist" {
            await publishResponseTransformation(t, previousRedactions: previousRedactions)
            await deliverBytes(id, kind:"response", offset:offset, bytes:captured)
        }
    }
    private func flushResponse(_ id: String) async {
        guard var t = traces[id], t.mode != "off" else { return }
        let previousRedactions = t.responseCredentialRedactions
        let captured = t.responseMasker.feed(Data(), final: true), offset = t.responseCaptureBytes
        t.responseCaptureBytes += captured.count; t.responseCredentialRedactions = t.responseMasker.replacements
        t.response.append(captured.prefix(max(0, Self.perBodyLimit - t.response.count)))
        traces[id] = t; trim()
        if t.mode == "persist" {
            await publishResponseTransformation(t, previousRedactions: previousRedactions)
            await deliverBytes(id, kind: "response", offset: offset, bytes: captured)
        }
    }
    private func publishResponseTransformation(_ trace: Trace, previousRedactions: Int) async {
        guard previousRedactions == 0, trace.responseCredentialRedactions > 0 else { return }
        // Publish the exception before its bytes, including during a live
        // stream or a cancelled tail; the inspector must never label them exact.
        if !(await sink(["type": "metadata", "metadata": metadata(trace).removing(["messageIds", "outputMessageIds"])])) {
            traces[trace.id]?.persistenceError = "Native recorder could not acknowledge response credential masking; body retention stopped"
        }
    }
    public func event(_ id:String, _ event:SSEEvent) async {
        guard var t=traces[id] else { return }
        guard t.rawEvents.count<4096 else { t.rawEventsDropped += 1;traces[id]=t;return }
        t.rawEvents.append(["type":JSON(preview(event.event, bytes:128)),"start":JSON(event.start),"end":JSON(event.end),"observedAt":JSON(nowMS())]); traces[id]=t
        if t.mode == "persist", t.rawEvents.count - t.sentEventIndices >= 128 { await flushEvents(id) }
    }
    private func flushEvents(_ id: String) async {
        guard var trace = traces[id], trace.mode == "persist", !trace.eventIndexError, trace.sentEventIndices < trace.rawEvents.count else { return }
        let offset = trace.sentEventIndices, page = Array(trace.rawEvents.dropFirst(offset).prefix(128))
        trace.sentEventIndices += page.count; traces[id] = trace
        if !(await sink(["type":"events", "attemptId":JSON(id), "offset":JSON(offset), "events":.array(page)])) { traces[id]?.eventIndexError = true }
    }
    public func dispatched(_ id: String, at time: Double, wall: Double = Date().timeIntervalSince1970) async {
        traces[id]?.dispatch = time; traces[id]?.dispatchWallTimestamp = wall
        if let t = traces[id] { _ = await sink(["type":"metadata", "metadata":metadata(t).removing(["messageIds", "outputMessageIds"])]) }
    }
    public func content(_ id:String, text:Bool, at time:Double) { guard var t=traces[id] else { return }; if t.firstContent==nil { t.firstContent=time }; if text && t.firstText==nil { t.firstText=time }; traces[id]=t }
    public func terminal(_ id:String, at time:Double) { if traces[id]?.completed == nil { traces[id]?.completed=time } }
    public func transport(_ id:String, observation:JSON) {
        guard var t=traces[id] else { return }
        t.dispatch=observation["dispatch"].double; t.dispatchWallTimestamp=observation["dispatchWallTimestamp"].double ?? t.dispatchWallTimestamp;
        t.responseObserved=max(t.responseObserved,observation["responseObservedBytes"].int ?? 0); t.firstHTTPByte=observation["firstHTTPByte"].double
        t.firstBodyByte=observation["firstBodyByte"].double; t.eof=observation["httpEnd"].double
        t.transportOutcome=observation["transportOutcome"].text ?? "unobserved"; traces[id]=t
    }
    public func usage(_ id:String, _ usage:JSON) { traces[id]?.usage=usage }
    public func finish(_ id:String, outcome:String, modelOutcome:String) async {
        await flushResponse(id)
        await flushEvents(id)
        traces[id]?.outcome=outcome; traces[id]?.modelOutcome=modelOutcome
        if let trace = traces[id], !(await sink(["type":"finish", "metadata":metadata(trace).removing(["messageIds", "outputMessageIds"])])) { traces[id]?.persistenceError="Native request finalization was unavailable; durable request remains interrupted" }
    }
    public func outputs(_ id: String, messageIDs: [String]) async {
        if var trace = traces[id] { trace.outputMessageIDs=Array(Set(trace.outputMessageIDs + messageIDs)).sorted(); traces[id]=trace }
        await deliverLinks(id, field: "outputMessageIds", ids: messageIDs)
    }
    private func trim() {
        var retained=traces.values.reduce(0) { $0+$1.request.count+$1.response.count }
        while order.count>64 || retained>Self.totalLimit {
            guard let index=order.firstIndex(where:{ traces[$0]?.outcome != "running" }) else { break }
            let id=order.remove(at:index); if let old=traces.removeValue(forKey:id) { retained -= old.request.count+old.response.count; droppedMetadata += 1 }
        }
    }
    private func bodyInfo(_ t:Trace, request:Bool)->JSON {
        let observed=request ? t.requestObserved:t.responseObserved, retained=request ? t.request.count:t.response.count
        let captured = request ? t.requestCaptureBytes : t.responseCaptureBytes
        let omitted = request && t.credentialOmitted, redactions = request ? t.credentialRedactions : t.responseCredentialRedactions
        let redacted = redactions > 0
        let state=t.mode=="off" ? "not-captured":omitted ? "credential-omitted":retained<captured ? "truncated":!request && (t.transportOutcome != "eof" || captured < observed) ? "partial":redacted ? (request ? "credential-hashed" : "credential-masked"):"complete"
        var result:JSON = ["state":JSON(state),"observedBytes":JSON(observed),"retainedBytes":JSON(retained),"reason": t.mode=="off" ? "Capture was disabled" : omitted ? "Credential replacement exceeded capture safety limits; request body was not retained." : retained<captured ? "8 MiB per-body limit" : .null]
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
            guard let start, let end, end >= start else { return .null }; return JSON(end-start)
        }
        let requestMS = span(t.dispatch, t.completed).double, output=t.usage["output"].double
        return ["observedTTFTms":span(t.dispatch,t.firstContent), "firstTextMs":span(t.dispatch,t.firstText),
                "streamDurationMs":span(t.firstContent,t.completed), "httpDurationMs":span(t.dispatch,t.eof),
                "outputTokensPerSecond":(requestMS != nil && requestMS!>0 && output != nil) ? JSON(output!/(requestMS!/1000)):.null,
                "inputIncludingCache":t.usage["inputIncludingCache"],"completeness":t.modelOutcome=="completed" ? "complete":"partial",
                "rateSource":"provider output / request dispatch-to-model-terminal; not decode speed","liveTokenRate":.null]
    }
    private func metadata(_ t:Trace)->JSON {
        ["attemptId":JSON(t.id),"sessionId":JSON(t.session),"turnId":JSON(t.turn),"api":JSON(t.api),"purpose":JSON(t.purpose),"mode":JSON(t.mode),"wallTime":JSON(t.wallTime),"method":"POST","url":JSON(t.url),"status":t.status.map { JSON($0) } ?? .null,
         "outcome":JSON(t.outcome),"modelOutcome":JSON(t.modelOutcome),"transportOutcome":JSON(t.transportOutcome),"requestHeaders":t.requestHeaders,"responseHeaders":t.headers,"usage":t.usage,"gateway":t.gateway?.json ?? .null,
         "identity":t.credentials.metadata(t.identity?.json ?? .null),"requestedModel":JSON(t.credentials.metadataText(t.requestedModel)),"messageIds":.array(t.messageIDs.map { JSON($0) }),"outputMessageIds":.array(t.outputMessageIDs.map { JSON($0) }),"wallTimestamp":JSON(t.wallTimestamp),"persistenceError":t.persistenceError.map { JSON($0) } ?? .null,
         "rawEventsOmitted":JSON(t.rawEventsDropped),"eventIndexPersistenceError":JSON(t.eventIndexError),
         "request":bodyInfo(t,request:true),"response":bodyInfo(t,request:false),"metrics":metrics(t),"rawEventIndexCount":JSON(t.rawEvents.count),
         "timingVersion":2,"dispatchWallTimestamp":t.dispatchWallTimestamp.map { JSON($0) } ?? .null,
         "timingBoundary":"Monotonic URLSession dispatch, header callback (first HTTP observation), decoded body callbacks, body bytes containing parsed content/terminal, and task completion. Not socket/TLS or paint timing.",
         "timings":["dispatch":t.dispatch.map { JSON($0) } ?? .null,"firstHTTPByte":t.firstHTTPByte.map { JSON($0) } ?? .null,"firstBodyByte":t.firstBodyByte.map { JSON($0) } ?? .null,"firstContent":t.firstContent.map { JSON($0) } ?? .null,"firstText":t.firstText.map { JSON($0) } ?? .null,"modelComplete":t.completed.map { JSON($0) } ?? .null,"httpEnd":t.eof.map { JSON($0) } ?? .null]]
    }
    public func latest(_ session:String)->JSON { guard let id=order.last(where:{traces[$0]?.session==session}),let t=traces[id] else { return .null }; return metadata(t) }
    public func command(_ method:String, session:String, params p:JSON) throws -> JSON {
        let boundary:JSON="Application HTTP boundary after serialization and HTTP decoding, not TLS packets. Gateway upstream traffic is unavailable. Authentication headers are masked; long request tokens retain only their last four characters, and short tokens, cookies and secret response headers are fully masked. Known credential literals in request bodies are labeled SHA-256 fingerprints; response credential echoes are replaced by same-length asterisks. Body transformations are explicit byte-exactness exceptions. Other captured bytes remain untransformed and sensitive."
        if method=="debug.mode" {
            guard let mode=p["mode"].text,["off","memory","persist"].contains(mode) else { throw AgentError("invalid_mode","Choose off, memory or persist") }
            // The native UI owns explicit trace-file export/persistence; raw host captures remain bounded memory.
            modes[session]=mode; return ["mode":JSON(mode),"appliesTo":"future attempts; existing captures are cleared separately"]
        }
        if method=="debug.clear" {
            guard !traces.values.contains(where:{$0.session==session && $0.outcome=="running"}) else { throw AgentError("capture_busy", "Stop the active request before clearing body captures") }
            let ids=Set(order.filter{traces[$0]?.session==session}); ids.forEach{traces.removeValue(forKey:$0)}; order.removeAll{ids.contains($0)}; return ["cleared":true]
        }
        if method=="debug.list" {
            let all=order.reversed().compactMap{traces[$0]}.filter{$0.session==session}, offset=try boundedInt(p["offset"])
            let page=Array(all.dropFirst(offset).prefix(64))
            return ["attempts":.array(page.map(metadata)),"total":JSON(all.count),"next":offset+page.count<all.count ? JSON(offset+page.count):.null,"mode":JSON(mode(session)),"boundary":boundary,"workspaceRetainedBytes":JSON(traces.values.reduce(0){$0+$1.request.count+$1.response.count}),"limits":["bodyBytes":JSON(Self.perBodyLimit),"workspaceBytes":JSON(Self.totalLimit)],"droppedMetadata":JSON(droppedMetadata)]
        }
        guard let id=p["attemptId"].text,let t=traces[id],t.session==session else { throw AgentError("capture_unavailable","Attempt is unavailable or belongs to another session") }
        if method=="debug.attempt" { var v=metadata(t); v["boundary"]=boundary;v["requestHash"]=t.mode=="off" ? .null:["sha256":JSON(sha256(t.request)),"scope":"retained bytes"];v["responseHash"]=t.mode=="off" ? .null:["sha256":JSON(sha256(t.response)),"scope":"retained bytes"]; return v }
        if method=="debug.raw-events" { let offset=try boundedInt(p["offset"]); return ["events":.array(Array(t.rawEvents.dropFirst(offset).prefix(128))),"total":JSON(t.rawEvents.count),"response":bodyInfo(t,request:false),"omitted":JSON(t.rawEventsDropped)] }
        if method=="debug.body" {
            guard ["request","response"].contains(p["body"].text ?? "") else { throw AgentError("invalid_body","Choose request or response") }
            let request=p["body"].text=="request", body=request ? t.request:t.response, offset=try boundedInt(p["offset"],maximum:Self.perBodyLimit)
            guard offset<=body.count else { throw AgentError("invalid_range","Offset exceeds retained bytes") }
            let end=min(body.count,offset+32768);var v=bodyInfo(t,request:request)
            v["offset"]=JSON(offset);v["bytes"]=JSON(body.subdata(in:offset..<end).base64EncodedString());v["next"]=end<body.count ? JSON(end):.null;return v
        }
        throw AgentError("unsupported_debug_command","Unsupported inspector operation")
    }
}
