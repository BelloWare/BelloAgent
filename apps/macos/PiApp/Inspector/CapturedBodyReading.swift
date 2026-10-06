import Foundation
import Combine

// Reading a captured body for the screen: the one background worker, the
// document it builds, where the bytes come from, and the controller a view
// observes while they load.

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
    /// The document on screen that this newer read of the same body replaced.
    var replaces: UUID?
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
            return (try await archive.body(attemptID: attemptID, body: kind, offset: offset), try metadata.count())
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
            return (bytes, try CapturedBodyMetadata(body: value, hash: nil).count())
        })
    }
}

enum CapturedBodyReader {
    /// Capture states whose retained bytes can still grow: the archive is
    /// recording, or the helper is still receiving the response. Bytes are
    /// only ever appended, so the prefix a read starts with never changes.
    static func growable(_ state: String) -> Bool { state == "recording" || state == "partial" }

    /// Whether a read has come far enough since the progress on screen to
    /// show again: a tenth of the body, never less than 128 KiB, or its end,
    /// once. Each step shown lays the page out again: a 5 MB request redrew
    /// the Inspector's request page some forty-five times on its way in, and
    /// the Raw tab as often, at about 10 ms a time in a Debug build.
    static func progressWorthShowing(_ loaded: Int, of total: Int, shown: Int) -> Bool {
        loaded >= total ? shown < total : loaded - shown >= max(131_072, total / 10)
    }

    /// `combine` also builds the combined response view before returning, so
    /// a document that replaces one on screen never passes through a spinner.
    @MainActor static func read(kind: String, source: CapturedBodySource, combine: Bool = false, progress: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> CapturedBodyDocument {
        let (bytes, metadata) = try await readBytes(kind: kind, source: source, progress: progress)
        return try await CapturedBodyWorker.shared.run { try CapturedBodyDocument.parse(bytes: bytes, metadata: metadata, combine: combine) }
    }

    /// The retained bytes of one body and the descriptor that says what they
    /// are, without parsing them: the Inspector's documents parse the bytes
    /// their own way, on the worker.
    @MainActor static func readBytes(kind: String, source: CapturedBodySource, progress: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> (bytes: Data, metadata: CapturedBodyMetadata) {
        try Task.checkCancellation()
        let before = try await source.metadata()
        let state = before.body["state"]?.string ?? ""
        guard MessageBodyReader.canReadRetained(state) else {
            throw HostError.failure("Body unavailable: \(before.body["state"]?.string ?? "not captured"). \(before.body["reason"]?.string ?? "")")
        }
        let count = try before.count(), growing = growable(state)
        let bytes: Data
        if let whole = source.whole { bytes = try await whole(progress) }
        else {
            // A body still being written is read up to the length it had
            // when the read began; failing whenever a byte arrived meant a
            // streaming response could not be viewed until it finished.
            bytes = try await MessageBodyReader.assemble(length: growing ? count : nil, progress: progress, page: source.page)
        }
        try Task.checkCancellation()
        let after = try await source.metadata()
        var described = before
        if bytes.count != count || before != after {
            // Only growth past the prefix this read holds is not a change; a
            // body that did not grow must still have the same digest.
            guard growing, bytes.count >= count, MessageBodyReader.canReadRetained(after.body["state"]?.string ?? ""),
                  let now = try? after.count(), now >= bytes.count, now > count || after.hash == before.hash else {
                throw HostError.failure("The capture changed while reading. Refresh and try again.")
            }
            // Every byte the capture holds now was read: `after` describes them.
            described = now == bytes.count ? after : CapturedBodyMetadata(prefix: bytes.count, of: before)
        }
        return (bytes, described)
    }

    /// What a cache keys a body's document by: its retained length and digest.
    static func revision(_ metadata: CapturedBodyMetadata) -> String {
        let length = metadata.body["retainedBytes"]?.number.map { String(Int($0)) } ?? "?"
        return length + ":" + (metadata.hash?.object?["sha256"]?.string ?? metadata.body["state"]?.string ?? "")
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

    /// `preservingDocument` keeps the body on screen until its replacement
    /// lands; `combine` prepares the replacement's combined view first.
    func load(kind: String, source: CapturedBodySource, preservingDocument: Bool = false, combine: Bool = false) async {
        readTask?.cancel(); combinationTask?.cancel(); combinationTask = nil
        generation += 1
        let revision = generation, replacing = preservingDocument ? document?.id : nil
        if !preservingDocument { document = nil }
        loaded = 0; total = 0; notice = ""; loading = true
        let job = Task { @MainActor [weak self] in
            try await CapturedBodyReader.read(kind: kind, source: source, combine: combine) { [weak self] loaded, total in
                guard let self, self.generation == revision else { return }
                // Coalesce UI progress without changing the archive's 32 KiB reads.
                if self.total == 0 || CapturedBodyReader.progressWorthShowing(loaded, of: total, shown: self.loaded) {
                    self.loaded = loaded; self.total = total
                }
            }
        }
        readTask = job
        defer { if generation == revision { readTask = nil } }
        do {
            var result = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            try Task.checkCancellation()
            guard generation == revision else { return }
            result.replaces = replacing
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
