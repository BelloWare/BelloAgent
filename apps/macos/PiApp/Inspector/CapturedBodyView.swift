import SwiftUI
import AppKit

struct CapturedBodyMetadata: Equatable, Sendable {
    let body: [String: WireValue]
    let hash: WireValue?

    func count(limit: Int) throws -> Int {
        guard let number = body["retainedBytes"]?.number, number.isFinite,
              number >= 0, number.rounded() == number, number <= Double(limit) else {
            throw HostError.failure("The retained body length is invalid or exceeds the capture limit.")
        }
        return Int(number)
    }
    var summary: String {
        let state = body["state"]?.string ?? "unavailable"
        let retained = body["retainedBytes"]?.number.map { String(format: "%.0f", $0) } ?? "unknown"
        let observed = body["observedBytes"]?.number.map { String(format: "%.0f", $0) } ?? "unknown"
        let reason = body["reason"]?.string ?? ""
        return "\(state) · all \(retained) retained bytes loaded / \(observed) observed" + (reason.isEmpty ? "" : " · \(reason)")
    }
}

/// JSONSerialization containers and captured event frames are immutable. They
/// are parsed off the main actor and only read afterward; the outline's mutable
/// child cache is a separate main-actor object.
struct CapturedJSON: @unchecked Sendable {
    let id = UUID()
    let value: Any
    let eagerFormatted: String?
    private let deferred: (@Sendable () throws -> String)?
    var rootLabel: String
    init(value: Any, formatted: String, rootLabel: String = "$") {
        self.value = value; eagerFormatted = formatted; deferred = nil; self.rootLabel = rootLabel
    }
    init(frames: [CapturedEventFrame]) {
        value = frames.map { $0 as Any }; eagerFormatted = nil; rootLabel = "Server-sent events"
        deferred = {
            var result = "Server-sent events · formatted view of retained frames\n\n"
            for (index, frame) in frames.enumerated() {
                try Task.checkCancellation()
                if index > 0 { result += "\n\n" }
                result += frame.formatted
            }
            return result
        }
    }
    var formatted: String { (try? render()) ?? "" }
    func render() throws -> String { try eagerFormatted ?? deferred?() ?? "" }
}

/// One immutable byte buffer plus byte ranges. Only derived frames that a reader
/// actually asks for enter the bounded cache. Never stores a second full stream.
final class CapturedEventStorage: @unchecked Sendable {
    let bytes: Data
    let cacheLimit: Int
    private let lock = NSLock()
    private var cache: [Int: (CapturedEventContent, Int)] = [:]
    private var order: [Int] = []
    private var cost = 0
    private var parsed = 0
    init(bytes: Data, cacheLimit: Int = 4 * 1_024 * 1_024) { self.bytes = bytes; self.cacheLimit = cacheLimit }
    var cachedBytes: Int { lock.lock(); defer { lock.unlock() }; return cost }
    var parsedFrames: Int { lock.lock(); defer { lock.unlock() }; return parsed }
    func cached(_ index: Int) -> CapturedEventContent? {
        lock.lock(); defer { lock.unlock() }; return cache[index]?.0
    }
    func content(for frame: CapturedEventFrame) -> CapturedEventContent {
        if let value = cached(frame.number) { return value }
        let fields = frame.lines.map { String(decoding: bytes[$0], as: UTF8.self) }
        let data = frame.dataLines.isEmpty ? nil : frame.dataLines.map { String(decoding: bytes[$0], as: UTF8.self) }.joined(separator: "\n")
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
        let value = CapturedEventContent(fields: fields, data: data, json: json)
        // Account conservatively for strings, Foundation containers and nodes,
        // not just source bytes. Oversized visible frames are never cache entries.
        let charge = frame.lines.reduce(256) { $0 + $1.count * 12 + 64 }
        lock.lock(); defer { lock.unlock() }
        parsed += 1
        if charge <= cacheLimit, cache[frame.number] == nil {
            while cost + charge > cacheLimit, !order.isEmpty {
                if let removed = cache.removeValue(forKey: order.removeFirst()) { cost -= removed.1 }
            }
            cache[frame.number] = (value, charge); order.append(frame.number); cost += charge
        }
        return value
    }
}
struct CapturedEventContent: @unchecked Sendable {
    let fields: [String]
    let data: String?
    let json: Any?
    var formattedData: String? {
        json.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) }
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

struct CapturedEventFrame: Sendable {
    let number: Int
    let storage: CapturedEventStorage
    let lines: [Range<Int>]
    let dataLines: [Range<Int>]
    let event: String?
    let terminated: Bool
    var content: CapturedEventContent { storage.content(for: self) }
    var fields: [String] { content.fields }
    var data: String? { content.data }
    var json: Any? { content.json }
    var formattedData: String? { content.formattedData }
    var initialLabel: String { "\(number) · " + (event?.isEmpty == false ? event! : (dataLines.isEmpty ? "SSE fields" : "message")) }
    var name: String { name(content) }
    func name(_ content: CapturedEventContent) -> String {
        if let event, !event.isEmpty { return event }
        if let type = (content.json as? [String: Any])?["type"] as? String, !type.isEmpty { return type }
        if content.data == "[DONE]" { return "[DONE]" }
        return content.data == nil ? "SSE fields" : "message"
    }
    var label: String { "\(number) · \(name)" }
    var summary: String { summary(content) }
    func summary(_ value: CapturedEventContent) -> String {
        let type = value.json != nil ? "JSON data" : value.data == "[DONE]" ? "Stream sentinel" : value.data == nil ? "No data" : "Non-JSON data"
        return type + (terminated ? "" : " · unfinished frame")
    }
    var count: Int { dataLines.isEmpty ? 2 : 3 }
    func entry(_ index: Int, prepared: CapturedEventContent? = nil) -> (String, Any) {
        let value = prepared ?? content
        if let data = value.data, index == 0 { return ("data", value.json ?? data) }
        let index = value.data == nil ? index : index - 1
        return index == 0 ? ("SSE fields", value.fields) : ("frame", terminated ? "Terminated by an empty line" : "Retained bytes end before the frame terminator")
    }
    var formatted: String {
        let value = content
        var result = "Event \(number) · \(name(value)) — \(summary(value))\nSSE fields:\n" + value.fields.joined(separator: "\n")
        if let pretty = value.formattedData { result += "\n\nFormatted data:\n" + pretty }
        return result
    }
    /// A cheap candidate check. The demand-driven combiner validates the actual
    /// JSON type before exposing a reconstructed response.
    var mightBeResponseEvent: Bool {
        if let event { return event.hasPrefix("response.") }
        return dataLines.contains { storage.bytes.range(of: Data("response.".utf8), in: $0) != nil }
    }
}

struct CapturedEventStream: Sendable {
    let frames: [CapturedEventFrame]
    let outline: CapturedJSON
    let storage: CapturedEventStorage
    init(frames: [CapturedEventFrame], outline: CapturedJSON, storage: CapturedEventStorage? = nil) {
        self.frames = frames; self.outline = outline
        self.storage = storage ?? frames.first?.storage ?? CapturedEventStorage(bytes: Data())
    }
    static func parse(_ bytes: Data) throws -> Self? {
        guard String(data: bytes, encoding: .utf8) != nil else { return nil }
        let storage = CapturedEventStorage(bytes: bytes)
        var frames: [CapturedEventFrame] = [], lines: [Range<Int>] = [], dataLines: [Range<Int>] = []
        var event: String?, hasSSEField = false
        func appendFrame(_ terminated: Bool) throws {
            guard !lines.isEmpty else { return }
            try Task.checkCancellation()
            frames.append(CapturedEventFrame(number: frames.count + 1, storage: storage, lines: lines, dataLines: dataLines, event: event, terminated: terminated))
            lines.removeAll(keepingCapacity: true); dataLines.removeAll(keepingCapacity: true); event = nil
        }
        try bytes.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            func appendLine(_ range: Range<Int>) {
                lines.append(range)
                if buffer[range.lowerBound] == 58 { hasSSEField = true; return }
                var separator = range.lowerBound
                while separator < range.upperBound, buffer[separator] != 58 { separator += 1 }
                let name = String(decoding: UnsafeBufferPointer(rebasing: buffer[range.lowerBound..<separator]), as: UTF8.self)
                var start = min(separator + 1, range.upperBound)
                if start < range.upperBound, buffer[start] == 32 { start += 1 }
                switch name {
                case "data": dataLines.append(start..<range.upperBound); hasSSEField = true
                case "event": event = String(decoding: UnsafeBufferPointer(rebasing: buffer[start..<range.upperBound]), as: UTF8.self); hasSSEField = true
                case "id", "retry": hasSSEField = true
                default: break
                }
            }
            var start = buffer.count >= 3 && buffer[0] == 0xef && buffer[1] == 0xbb && buffer[2] == 0xbf ? 3 : 0
            var cursor = start, check = start
            while cursor < buffer.count {
                if cursor >= check { try Task.checkCancellation(); check = cursor + 32_768 }
                let byte = buffer[cursor]
                guard byte == 10 || byte == 13 else { cursor += 1; continue }
                if cursor == start { try appendFrame(true) } else { appendLine(start..<cursor) }
                if byte == 13, cursor + 1 < buffer.count, buffer[cursor + 1] == 10 { cursor += 1 }
                cursor += 1; start = cursor
            }
            if start < buffer.count { appendLine(start..<buffer.count) }
            try appendFrame(false)
        }
        guard hasSSEField, !frames.isEmpty else { return nil }
        return Self(frames: frames, outline: CapturedJSON(frames: frames), storage: storage)
    }
}

/// One serial background owner bounds capture parsing/formatting across windows.
/// The caller's task cancellation remains visible inside every parse loop.
actor CapturedBodyWorker {
    static let shared = CapturedBodyWorker()
    func run<T: Sendable>(_ work: @Sendable () throws -> T) throws -> T {
        try Task.checkCancellation()
        let value = try work()
        try Task.checkCancellation()
        return value
    }
}

struct CapturedBodyCopySource: Sendable {
    let id: UUID
    let document: CapturedBodyDocument
    let format: CapturedBodyFormat
    let hex: String
    let plain: String
    func render() async throws -> String {
        try await CapturedBodyWorker.shared.run {
            if let structured = document.structured(format: format) { return try structured.render() }
            return document.displayedText(format: format, hex: hex, plain: plain)
        }
    }
}

struct CapturedBodyDocument: Sendable {
    let id = UUID()
    let bytes: Data
    let metadata: CapturedBodyMetadata
    let json: CapturedJSON?
    let eventStream: CapturedEventStream?
    var combinedResponse: CombinedResponse?
    var combinationFinished = false
    var hasResponseEvents = false
    var structured: CapturedJSON? { json ?? eventStream?.outline }

    func availableFormats(kind: String) -> [(CapturedBodyFormat, String)] {
        var result: [(CapturedBodyFormat, String)] = []
        if kind == "response", combinedResponse != nil || !combinationFinished && hasResponseEvents { result.append((.combined, "Combined JSON")) }
        result += [(.json, eventStream == nil ? "JSON" : "Events"), (.text, "UTF-8"), (.hex, "Hex")]
        return result
    }

    func resolvedFormat(_ requested: CapturedBodyFormat, kind: String) -> CapturedBodyFormat {
        availableFormats(kind: kind).contains { $0.0 == requested } ? requested : .json
    }

    func structured(format: CapturedBodyFormat) -> CapturedJSON? {
        format == .combined ? combinedResponse?.json : format == .json ? structured : nil
    }

    /// `plain` is the retained bytes decoded as UTF-8, decoded once off the
    /// main actor by the view. Decoding here meant decoding a body of up to
    /// 64 MiB on every render that read this.
    func displayedText(format: CapturedBodyFormat, hex: String = "", plain: String = "") -> String {
        if format == .hex { return hex }
        return structured(format: format)?.formatted ?? plain
    }

    static func parse(bytes: Data, metadata: CapturedBodyMetadata, combine: Bool = true) throws -> Self {
        try Task.checkCancellation()
        var json: CapturedJSON?
        if let value = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]),
           let printed = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            json = CapturedJSON(value: value, formatted: String(decoding: printed, as: UTF8.self))
        }
        let eventStream = json == nil ? try CapturedEventStream.parse(bytes) : nil
        let combinedResponse = combine ? try eventStream.flatMap { try CombinedResponse.parse($0) } : nil
        try Task.checkCancellation()
        return Self(bytes: bytes, metadata: metadata, json: json, eventStream: eventStream, combinedResponse: combinedResponse, combinationFinished: combine,
                    hasResponseEvents: eventStream?.frames.contains(where: \.mightBeResponseEvent) == true)
    }
}

@MainActor struct CapturedBodySource {
    let metadata: () async throws -> CapturedBodyMetadata
    let page: (Int) async throws -> (Data, Int)
    var whole: ((@escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> Data)? = nil

    static func archive(_ archive: PayloadArchive, attemptID: String, kind: String) -> Self {
        Self(metadata: {
            let value = try await archive.metadata(attempt: attemptID)
            return CapturedBodyMetadata(body: value[kind]?.object ?? [:], hash: value[kind + "Hash"])
        }, page: { offset in
            let value = try await archive.metadata(attempt: attemptID)
            let metadata = CapturedBodyMetadata(body: value[kind]?.object ?? [:], hash: value[kind + "Hash"])
            return (try await archive.body(attemptID: attemptID, body: kind, offset: offset), try metadata.count(limit: CapturedBodyReader.limit(kind)))
        }, whole: { progress in
            try await archive.completeBody(attemptID: attemptID, body: kind) { loaded, total in
                await progress(loaded, total)
            }
        })
    }

    static func live(_ model: WorkspaceModel, sessionID: String, attemptID: String, kind: String) -> Self {
        Self(metadata: {
            let value = try await model.debugRequest("debug.attempt", sessionID: sessionID, params: ["attemptId": .string(attemptID)])
            return CapturedBodyMetadata(body: value[kind]?.object ?? [:], hash: value[kind + "Hash"])
        }, page: { offset in
            let value = try await model.debugRequest("debug.body", sessionID: sessionID, params: ["attemptId": .string(attemptID), "body": .string(kind), "offset": .number(Double(offset))])
            guard MessageBodyReader.canReadRetained(value["state"]?.string ?? ""),
                  let encoded = value["bytes"]?.string, let bytes = Data(base64Encoded: encoded) else {
                throw HostError.failure("This body was not captured or is no longer available.")
            }
            return (bytes, try CapturedBodyMetadata(body: value, hash: nil).count(limit: CapturedBodyReader.limit(kind)))
        })
    }
}

enum CapturedBodyReader {
    static func limit(_ kind: String) -> Int { kind == "request" ? 33_554_432 : 67_108_864 }

    @MainActor static func read(kind: String, source: CapturedBodySource, progress: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> CapturedBodyDocument {
        try Task.checkCancellation()
        let before = try await source.metadata()
        guard MessageBodyReader.canReadRetained(before.body["state"]?.string ?? "") else {
            throw HostError.failure("Body unavailable: \(before.body["state"]?.string ?? "not captured"). \(before.body["reason"]?.string ?? "")")
        }
        let count = try before.count(limit: limit(kind))
        let bytes: Data
        if let whole = source.whole { bytes = try await whole(progress) }
        else {
            guard let assembled = try await MessageBodyReader.assemble(limit: limit(kind), progress: progress, page: source.page) else {
                throw HostError.failure("The capture changed while reading. Refresh and try again.")
            }
            bytes = assembled
        }
        guard bytes.count == count else {
            throw HostError.failure("The capture changed while reading. Refresh and try again.")
        }
        try Task.checkCancellation()
        guard before == (try await source.metadata()) else {
            throw HostError.failure("The capture changed while reading. Refresh and try again.")
        }
        return try await CapturedBodyWorker.shared.run { try CapturedBodyDocument.parse(bytes: bytes, metadata: before, combine: false) }
    }
}

@MainActor final class CapturedBodyController: ObservableObject {
    @Published private(set) var document: CapturedBodyDocument?
    @Published private(set) var loading = false
    @Published private(set) var loaded = 0
    @Published private(set) var total = 0
    @Published private(set) var notice = ""
    private var generation = 0
    private var readTask: Task<CapturedBodyDocument, Error>?
    private var combinationTask: Task<CombinedResponse?, Error>?

    func load(kind: String, source: CapturedBodySource, preservingDocument: Bool = false) async {
        readTask?.cancel(); combinationTask?.cancel(); combinationTask = nil
        generation += 1
        let revision = generation
        if !preservingDocument { document = nil }
        loaded = 0; total = 0; notice = ""; loading = true
        let job = Task { @MainActor [weak self] in
            try await CapturedBodyReader.read(kind: kind, source: source) { [weak self] loaded, total in
                guard let self, self.generation == revision else { return }
                // Coalesce UI progress without changing the archive's 32 KiB reads.
                if loaded == total || loaded - self.loaded >= 131_072 || self.total == 0 {
                    self.loaded = loaded; self.total = total
                }
            }
        }
        readTask = job
        defer { if generation == revision { readTask = nil } }
        do {
            let result = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            try Task.checkCancellation()
            guard generation == revision else { return }
            document = result; loading = false
        } catch {
            guard generation == revision else { return }
            loading = false
            if !(error is CancellationError) { notice = error.localizedDescription }
        }
    }
    func prepareCombined() async {
        guard let document, document.combinedResponse == nil, let stream = document.eventStream else { return }
        let revision = generation, id = document.id
        let task = combinationTask ?? Task { try await CapturedBodyWorker.shared.run { try CombinedResponse.parse(stream) } }
        combinationTask = task
        defer { if generation == revision { combinationTask = nil } }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, revision == generation, self.document?.id == id else { return }
            self.document?.combinedResponse = value
            self.document?.combinationFinished = true
        } catch { if revision == generation, !(error is CancellationError) { notice = error.localizedDescription } }
    }
    func cancel() { generation += 1; readTask?.cancel(); readTask = nil; combinationTask?.cancel(); combinationTask = nil; loading = false; document = nil }

}

enum CapturedBodyFormat: String, CaseIterable, Sendable { case json, combined, text, hex }

/// No body pagination: both native entry points share this complete retained
/// body presentation. Expiry and prefix states remain visible above the bytes.
struct CapturedBodyView: View {
    let source: CapturedBodySource
    let sessionID: String
    let attemptID: String
    let kind: String
    let retained: Bool
    var revision = 0
    /// Only the request inspector consumes this (Copy View and redaction).
    /// A card that ignores it must not be handed a second full copy of the body.
    var displayedText: Binding<String>? = nil
    var copySource: Binding<CapturedBodyCopySource?>? = nil
    var searchQuery = ""
    var searchHeaders: [String: WireValue] = [:]
    @StateObject private var controller = CapturedBodyController()
    @StateObject private var search = PayloadSearchController()
    @State private var previousSelection: Selection?
    @State private var format = CapturedBodyFormat.json
    @State private var selection = ""
    @State private var expandRevision = 0
    @State private var expandAll = false
    @State private var hex = ""
    /// The retained bytes decoded as UTF-8, once per document.
    @State private var utf8 = ""
    private struct Selection: Equatable {
        let session: String, attempt: String, kind: String
        let retained: Bool
        let revision: Int
    }
    private struct FormatSelection: Equatable {
        let format: CapturedBodyFormat
        let document: UUID?
    }
    private struct SearchSelection: Equatable {
        let query: String
        let document: UUID?
        let format: CapturedBodyFormat
        let combined: Bool
        let headers: [String: WireValue]
    }
    init(model: WorkspaceModel, sessionID: String, attemptID: String, kind: String, retained: Bool,
         revision: Int = 0, displayedText: Binding<String>? = nil, copySource: Binding<CapturedBodyCopySource?>? = nil,
         initialFormat: CapturedBodyFormat = .json) {
        self.source = retained ? .archive(model.traces, attemptID: attemptID, kind: kind) : .live(model, sessionID: sessionID, attemptID: attemptID, kind: kind)
        self.sessionID = sessionID; self.attemptID = attemptID; self.kind = kind; self.retained = retained
        self.revision = revision; self.displayedText = displayedText; self.copySource = copySource
        _format = State(initialValue: initialFormat)
    }
    init(source: CapturedBodySource, sessionID: String, attemptID: String, kind: String, retained: Bool,
         revision: Int = 0, copySource: Binding<CapturedBodyCopySource?>? = nil,
         initialFormat: CapturedBodyFormat = .json, searchQuery: String = "", searchHeaders: [String: WireValue] = [:]) {
        self.source = source; self.sessionID = sessionID; self.attemptID = attemptID; self.kind = kind; self.retained = retained
        self.revision = revision; self.copySource = copySource; self.searchQuery = searchQuery; self.searchHeaders = searchHeaders
        _format = State(initialValue: initialFormat)
    }
    private var identity: Selection { Selection(session: sessionID, attempt: attemptID, kind: kind, retained: retained, revision: revision) }
    private var activeFormat: CapturedBodyFormat { controller.document?.resolvedFormat(format, kind: kind) ?? .json }
    private var selectedFormat: Binding<CapturedBodyFormat> {
        Binding(get: { activeFormat }, set: { format = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: PiSpacing.sm) {
                PiTabs(selection: selectedFormat, items: controller.document?.availableFormats(kind: kind) ?? [(.json, "JSON"), (.text, "UTF-8"), (.hex, "Hex")])
                Spacer()
                if searchQuery.isEmpty, controller.document?.structured(format: activeFormat) != nil {
                    Button("Expand all") { expandAll = true; expandRevision += 1 }.buttonStyle(.piGhost)
                    Button("Collapse all") { expandAll = false; expandRevision += 1 }.buttonStyle(.piGhost)
                }
            }
            if !searchQuery.isEmpty {
                searchResults
            } else if let document = controller.document {
                if let json = document.structured(format: activeFormat) {
                    JSONOutlineView(json: json, selection: $selection, expandRevision: expandRevision, expandAll: expandAll)
                        .piInset(sunken: true)
                    if !selection.isEmpty {
                        PagedTextView(text: selection, accessibilityLabel: "Selected JSON value")
                            .frame(height: 100).piInset(sunken: true)
                    }
                    Text(activeFormat == .combined ? document.combinedResponse?.notice ?? ""
                         : document.eventStream == nil
                         ? "Select a value to see its full contents. Formatting is a derived view; retained bytes are unchanged."
                         : "Events appear in captured order. Expand a frame and its data to inspect JSON. This is a formatted view; UTF-8, Hex and exports preserve the retained bytes.")
                        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                } else if activeFormat == .combined {
                    VStack { ProgressView(); Text("Combining captured response events…").font(PiFont.caption) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PagedTextView(text: activeFormat == .hex ? hex : utf8, accessibilityLabel: "Complete retained HTTP body")
                        .piInset(sunken: true)
                    if activeFormat == .json { Text("Not a JSON document or UTF-8 event stream · showing retained UTF-8.").font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                }
                Text(document.metadata.summary).font(PiFont.micro).foregroundStyle(Color.piInkSecondary).textSelection(.enabled)
            } else if controller.loading {
                VStack(spacing: PiSpacing.sm) {
                    ProgressView(value: Double(controller.loaded), total: Double(max(1, controller.total))).frame(maxWidth: 300)
                    Text("Loading all retained bytes · \(controller.loaded.formatted()) / \(controller.total.formatted())")
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(controller.notice.isEmpty ? "No retained body" : controller.notice)
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if !searchQuery.isEmpty, let document = controller.document {
                Text(document.metadata.summary).font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            }
            if controller.document != nil, !controller.notice.isEmpty {
                Text(controller.notice).font(PiFont.micro).foregroundStyle(Color.piWarning)
            }
        }
        .task(id: identity) {
            let preserve = previousSelection.map { $0.session == identity.session && $0.attempt == identity.attempt && $0.kind == identity.kind } ?? false
            previousSelection = identity
            displayedText?.wrappedValue = ""; copySource?.wrappedValue = nil; selection = ""; hex = ""; utf8 = ""
            if !preserve { expandAll = false; expandRevision = 0 }
            await controller.load(kind: kind, source: source, preservingDocument: preserve)
            guard !Task.isCancelled else { return }
            await updateDisplayedText()
        }
        .task(id: FormatSelection(format: activeFormat, document: controller.document?.id)) {
            selection = ""; expandAll = false; expandRevision = 0
            if activeFormat == .combined { await controller.prepareCombined() }
            guard !Task.isCancelled else { return }
            await updateHexIfNeeded()
            await updateUTF8IfNeeded()
            await updateDisplayedText()
        }
        .task(id: SearchSelection(query: searchQuery, document: controller.document?.id, format: activeFormat,
                                  combined: controller.document?.combinationFinished ?? false, headers: searchHeaders)) {
            guard !searchQuery.isEmpty else { search.cancel(); return }
            if activeFormat == .combined, controller.document?.combinationFinished == false { return }
            await search.search(document: controller.document, format: activeFormat, headers: searchHeaders, kind: kind, query: searchQuery)
        }
        .onDisappear { controller.cancel(); search.cancel(); copySource?.wrappedValue = nil }
        .accessibilityIdentifier("captured-body-view")
    }
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if let result = search.result {
                    Text(result.matches.isEmpty ? "No matches in body or headers" : "\(search.selected + 1) of \(result.matches.count)\(result.limited ? "+" : "") matches")
                        .font(PiFont.caption).monospacedDigit().accessibilityIdentifier("payload-search-count")
                    Spacer()
                    if search.loading { Text("Updating…").font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                    Button { search.move(-1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.piGhost).disabled(result.matches.isEmpty).help("Previous match").accessibilityLabel("Previous match")
                    Button { search.move(1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.piGhost).disabled(result.matches.isEmpty).help("Next match").accessibilityLabel("Next match")
                } else if search.loading { PiShimmerText(text: "Searching body and headers…", size: 11) }
            }
            if let result = search.result {
                PayloadSearchTextView(result: result, selected: search.selected).piInset(sunken: true)
            } else {
                Text(search.notice).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func updateDisplayedText() async {
        guard let document = controller.document else { displayedText?.wrappedValue = ""; copySource?.wrappedValue = nil; return }
        let id = identity, requested = activeFormat
        let source = CapturedBodyCopySource(id: document.id, document: document, format: requested, hex: hex, plain: utf8)
        copySource?.wrappedValue = source
        // Legacy binding is used by native fixtures. The production inspector
        // requests full derived text only when Copy/Redacted Export is invoked.
        if let displayedText, let text = try? await source.render(), !Task.isCancelled,
           id == identity, controller.document?.id == document.id, requested == activeFormat { displayedText.wrappedValue = text }
    }
    /// The retained bytes as UTF-8, decoded once per document on a detached
    /// task. This used to run inside `body`, so every progress tick, poll,
    /// hover or resize re-decoded the whole payload on the main thread.
    private func updateUTF8IfNeeded() async {
        guard activeFormat != .hex, utf8.isEmpty, let document = controller.document,
              document.structured(format: activeFormat) == nil, !document.bytes.isEmpty else { return }
        let identity = identity, bytes = document.bytes, requested = activeFormat
        let decoding = Task.detached(priority: .userInitiated) { String(decoding: bytes, as: UTF8.self) }
        let value = await withTaskCancellationHandler(operation: { await decoding.value }, onCancel: { decoding.cancel() })
        guard !Task.isCancelled, identity == self.identity, activeFormat == requested else { return }
        utf8 = value
    }
    private func updateHexIfNeeded() async {
        guard activeFormat == .hex, hex.isEmpty, let bytes = controller.document?.bytes else { return }
        let identity = identity
        let rendering = Task.detached(priority: .userInitiated) { try CapturedBodyHex.render(bytes) }
        do {
            let value = try await withTaskCancellationHandler(operation: { try await rendering.value }, onCancel: { rendering.cancel() })
            guard !Task.isCancelled, identity == self.identity, format == .hex else { return }
            hex = value
        } catch { /* Leaving the view or format cancels expensive rendering. */ }
    }
}

enum CapturedBodyHex {
    /// One byte buffer for the whole dump. `String(format:)` per sixteen bytes
    /// meant four million formatter calls, and as many intermediate strings,
    /// for a large body.
    static func render(_ bytes: Data) throws -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8](); out.reserveCapacity(bytes.count * 4 + 16)
        for start in stride(from: 0, to: bytes.count, by: 16) {
            if start % 32_768 == 0 { try Task.checkCancellation() }
            for shift in stride(from: 28, through: 0, by: -4) { out.append(digits[(start >> shift) & 15]) }
            out.append(32); out.append(32)
            for byte in bytes[start..<min(start + 16, bytes.count)] { out.append(digits[Int(byte >> 4)]); out.append(digits[Int(byte & 15)]); out.append(32) }
            out.append(10)
        }
        return String(decoding: out, as: UTF8.self)
    }
}

@MainActor final class JSONOutlineNode {
    private let baseKey: String
    let value: Any
    var prepared: CapturedEventContent?
    var key: String {
        guard let frame = value as? CapturedEventFrame else { return baseKey }
        return prepared.map { "\(frame.number) · " + frame.name($0) } ?? frame.initialLabel
    }
    func releasePreparation() { prepared = nil; children.removeAll() }
    let formattedDetail: String?
    private var children: [Int: JSONOutlineNode] = [:]
    private lazy var keys = (value as? [String: Any])?.keys.sorted() ?? []
    init(key: String, value: Any, formattedDetail: String? = nil) {
        self.baseKey = key; self.value = value; self.formattedDetail = formattedDetail
        if let frame = value as? CapturedEventFrame { prepared = frame.storage.cached(frame.number) }
    }
    var count: Int { (value as? CapturedEventFrame).map { prepared == nil ? 0 : $0.count } ?? (value as? [String: Any])?.count ?? (value as? [Any])?.count ?? 0 }
    var cachedChildren: Int { children.count }
    func child(_ index: Int) -> JSONOutlineNode {
        if let result = children[index] { return result }
        let result: JSONOutlineNode
        if let frame = value as? CapturedEventFrame {
            let (key, value) = frame.entry(index, prepared: prepared)
            result = JSONOutlineNode(key: key, value: value)
        } else if let values = value as? [String: Any] { result = JSONOutlineNode(key: keys[index], value: values[keys[index]] ?? NSNull()) }
        else {
            let list = value as? [Any] ?? []
            let value: Any = list.indices.contains(index) ? list[index] : NSNull()
            result = JSONOutlineNode(key: (value as? CapturedEventFrame)?.initialLabel ?? "[\(index)]", value: value)
        }
        children[index] = result
        return result
    }
    var summary: String {
        if let frame = value as? CapturedEventFrame { return prepared.map { frame.summary($0) } ?? "" }
        if value is [String: Any] { return "{ \(count) \(count == 1 ? "key" : "keys") }" }
        if value is [Any] { return "[ \(count) \(count == 1 ? "item" : "items") ]" }
        if let string = value as? String {
            let preview = String(string.prefix(251))
            return "\"" + String(preview.prefix(250)).replacingOccurrences(of: "\n", with: "\\n") + (preview.count > 250 ? "…" : "") + "\""
        }
        return detail
    }
    var detail: String {
        if let formattedDetail { return formattedDetail }
        if let frame = value as? CapturedEventFrame { return frame.formatted }
        // Custom event values are not Foundation JSON containers. This
        // fallback also protects roots constructed outside the live viewer;
        // the viewer supplies its already formatted root to avoid this work.
        if let frames = value as? [CapturedEventFrame], !frames.isEmpty {
            return "Server-sent events · formatted view of retained frames\n\n" + frames.map(\.formatted).joined(separator: "\n\n")
        }
        if let string = value as? String { return string }
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct JSONOutlineView: NSViewRepresentable {
    let json: CapturedJSON
    @Binding var selection: String
    let expandRevision: Int
    let expandAll: Bool
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let outline = NSOutlineView(); outline.headerView = nil; outline.backgroundColor = .clear
        outline.rowHeight = 24; outline.intercellSpacing = NSSize(width: 10, height: 2); outline.indentationPerLevel = 14
        let key = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key")); key.width = 240; key.minWidth = 100
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value")); value.width = 420; value.minWidth = 120
        outline.addTableColumn(key); outline.addTableColumn(value); outline.outlineTableColumn = key
        outline.dataSource = context.coordinator; outline.delegate = context.coordinator
        outline.setAccessibilityLabel("Expandable captured JSON")
        scroll.documentView = outline
        context.coordinator.observeViewport(scroll.contentView, outline: outline)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        let coordinator = context.coordinator
        coordinator.selection = $selection
        // One controller document is immutable. Rebuild only after a new body,
        // not after selecting a row or changing the expanded state.
        if coordinator.documentID != json.id {
            coordinator.cancelPendingSelection()
            coordinator.documentID = json.id
            coordinator.root = JSONOutlineNode(key: json.rootLabel, value: json.value, formattedDetail: json.eagerFormatted)
            coordinator.revision = expandRevision
            outline.reloadData(); outline.expandItem(coordinator.root)
        }
        if coordinator.revision != expandRevision {
            coordinator.revision = expandRevision
            coordinator.expandEverything = expandAll
            if expandAll { coordinator.expandAll(in: outline) }
            else { coordinator.cancelExpansion(); outline.collapseItem(nil, collapseChildren: true); outline.expandItem(coordinator.root) }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        outline.delegate = nil; outline.dataSource = nil
    }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var root: JSONOutlineNode?
        var documentID: UUID?
        var revision = 0
        var selection: Binding<String>
        private var selectionRevision = 0
        var expandEverything = false
        private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var preparedNodes: [ObjectIdentifier: JSONOutlineNode] = [:]
        private var requestedExpansion: Set<ObjectIdentifier> = []
        private var detailTask: Task<Void, Never>?
        private var expansionTask: Task<Void, Never>?
        nonisolated(unsafe) private var viewportObserver: NSObjectProtocol?
        deinit { if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) } }
        func observeViewport(_ clip: NSClipView, outline: NSOutlineView) {
            clip.postsBoundsChangedNotifications = true
            viewportObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak outline] _ in
                MainActor.assumeIsolated { if let outline { self?.trimPreparedFrames(outline) } }
            }
        }
        func stopObserving() {
            cancelPendingSelection()
            if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver); self.viewportObserver = nil }
        }
        private func trimPreparedFrames(_ outline: NSOutlineView) {
            let visible = outline.rows(in: outline.visibleRect)
            for (id, node) in preparedNodes {
                let row = outline.row(forItem: node)
                if !NSLocationInRange(row, visible), !outline.isItemExpanded(node) {
                    node.releasePreparation(); preparedNodes[id] = nil
                }
            }
        }
        private func prepare(_ node: JSONOutlineNode, outline: NSOutlineView) {
            guard expansionTask == nil, node.prepared == nil, let frame = node.value as? CapturedEventFrame else { return }
            let key = ObjectIdentifier(node), document = documentID
            guard pending[key] == nil else { return }
            pending[key] = Task { [weak self, weak outline, weak node] in
                defer { if self?.documentID == document { self?.pending[key] = nil } }
                guard let content = try? await CapturedBodyWorker.shared.run({ frame.content }), !Task.isCancelled,
                      let self, let outline, let node, self.documentID == document, outline.delegate === self else { return }
                node.prepared = content; self.preparedNodes[key] = node
                outline.reloadItem(node, reloadChildren: true)
                if self.expandEverything || self.requestedExpansion.contains(key) { outline.expandItem(node, expandChildren: true) }
                self.trimPreparedFrames(outline)
            }
        }
        /// Expand all also includes offscreen events. One bounded worker job at
        /// a time replaces a task per frame, and each publication preserves the
        /// visible outline item while rows are inserted above it.
        func expandAll(in outline: NSOutlineView) {
            cancelExpansion()
            guard let root, let frames = root.value as? [CapturedEventFrame] else {
                outline.expandItem(nil, expandChildren: true); return
            }
            pending.values.forEach { $0.cancel() }; pending.removeAll()
            let document = documentID, revision = revision
            expansionTask = Task { [weak self, weak outline] in
                defer { if self?.documentID == document, self?.revision == revision { self?.expansionTask = nil } }
                for start in stride(from: 0, to: frames.count, by: 8) {
                    let end = min(start + 8, frames.count)
                    let batch = Array(frames[start..<end])
                    guard let contents = try? await CapturedBodyWorker.shared.run({ try batch.map { frame in try Task.checkCancellation(); return frame.content } }),
                          !Task.isCancelled, let self, let outline, self.documentID == document,
                          self.revision == revision, self.expandEverything, outline.delegate === self else { return }
                    let visible = outline.rows(in: outline.visibleRect)
                    let anchor = visible.length > 0 ? outline.item(atRow: visible.location) : nil
                    let offset = visible.length > 0 ? outline.visibleRect.minY - outline.rect(ofRow: visible.location).minY : 0
                    for (index, content) in zip(start..<end, contents) {
                        let node = root.child(index)
                        node.prepared = content; self.preparedNodes[ObjectIdentifier(node)] = node
                        outline.reloadItem(node, reloadChildren: true)
                        outline.expandItem(node, expandChildren: true)
                    }
                    if let anchor, let clip = outline.enclosingScrollView?.contentView {
                        let row = outline.row(forItem: anchor)
                        if row >= 0 { clip.scroll(to: NSPoint(x: clip.bounds.minX, y: outline.rect(ofRow: row).minY + offset)) }
                    }
                }
            }
        }
        func cancelExpansion() { expansionTask?.cancel(); expansionTask = nil }
        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let outline = notification.object as? NSOutlineView, let node = notification.userInfo?["NSObject"] as? JSONOutlineNode else { return }
            requestedExpansion.insert(ObjectIdentifier(node)); prepare(node, outline: outline)
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? JSONOutlineNode else { return }
            requestedExpansion.remove(ObjectIdentifier(node))
        }
        init(selection: Binding<String>) { self.selection = selection }
        func cancelPendingSelection() {
            selectionRevision += 1; detailTask?.cancel(); detailTask = nil
            cancelExpansion()
            pending.values.forEach { $0.cancel() }; pending.removeAll(); preparedNodes.removeAll(); requestedExpansion.removeAll(); expandEverything = false
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? JSONOutlineNode)?.count ?? (root == nil ? 0 : 1) }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? JSONOutlineNode)?.child(index) ?? root ?? JSONOutlineNode(key: "", value: [String: Any]()) }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (((item as? JSONOutlineNode)?.value as? CapturedEventFrame)?.count ?? (item as? JSONOutlineNode)?.count ?? 0) > 0 }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? JSONOutlineNode else { return nil }
            prepare(node, outline: outlineView)
            let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("value")
            let field = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
            field.identifier = identifier; field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
            field.stringValue = identifier.rawValue == "key" ? node.key : node.summary
            field.textColor = identifier.rawValue == "key" ? .labelColor : .secondaryLabelColor
            return field
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline = notification.object as? NSOutlineView else { return }
            // reloadData and collapseItem post this synchronously from updateNSView; the
            // SwiftUI binding is written on the next turn, never inside that update.
            // Read only the final selection, and discard work from a replaced body
            // or a dismantled outline before it can repopulate the cleared detail.
            selectionRevision += 1
            let revision = selectionRevision, documentID = documentID, root = root
            DispatchQueue.main.async { [weak self, weak outline] in
                guard let self, let outline, outline.delegate === self,
                      self.selectionRevision == revision, self.documentID == documentID,
                      self.root === root else { return }
                self.detailTask?.cancel()
                guard let node = outline.item(atRow: outline.selectedRow) as? JSONOutlineNode,
                      node.count == 0 || node === root || node.value is CapturedEventFrame else {
                    self.selection.wrappedValue = ""; return
                }
                let value = CapturedOutlineDetail(value: node.value, formatted: node.formattedDetail)
                self.detailTask = Task { [weak self, weak outline] in
                    guard let detail = try? await CapturedBodyWorker.shared.run({ try value.render() }), !Task.isCancelled,
                          let self, let outline, outline.delegate === self, self.selectionRevision == revision,
                          self.documentID == documentID else { return }
                    if self.selection.wrappedValue != detail { self.selection.wrappedValue = detail }
                }
            }
        }
    }
}

/// Immutable Foundation data crosses to the bounded worker, never outline nodes.
private struct CapturedOutlineDetail: @unchecked Sendable {
    let value: Any
    let formatted: String?
    func render() throws -> String {
        if let formatted { return formatted }
        if let frame = value as? CapturedEventFrame { return frame.formatted }
        if let frames = value as? [CapturedEventFrame] { return try CapturedJSON(frames: frames).render() }
        if let string = value as? String { return string }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: bytes, as: UTF8.self)
    }
}
