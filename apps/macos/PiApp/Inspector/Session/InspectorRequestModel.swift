import Foundation

/// What a body read has come to: nothing asked yet, bytes arriving, a
/// document, or why there is none.
enum InspectorLoad<Value> {
    case idle
    case loading(loaded: Int, total: Int)
    case ready(Value)
    case failed(String)
    var value: Value? { if case .ready(let value) = self { value } else { nil } }
    var loading: Bool { if case .loading = self { true } else { false } }
}

/// The request page's reads: the request's one metadata record, and the body
/// behind whichever tab is on screen. A tab that is not visible reads nothing,
/// a window that is hidden reads nothing, and every body is parsed on the
/// capture worker; the main actor only ever receives finished documents.
@MainActor final class InspectorRequestModel: ObservableObject {
    enum Tab: String, CaseIterable, Sendable { case conversation, response, raw }

    @Published private(set) var row: InspectorRequestRow?
    @Published private(set) var metadata: [String: WireValue] = [:]
    @Published private(set) var metadataLoaded = false
    @Published private(set) var metadataFailure: String?
    @Published var tab: Tab = .conversation { didSet { if tab != oldValue { tabChanged() } } }
    @Published private(set) var conversation: InspectorLoad<RequestDocument> = .idle
    @Published private(set) var delta: RequestDelta?
    /// Why the delta could not be computed: the earlier body expired, for one.
    @Published private(set) var deltaNote: String?
    /// "request 1", "turn 2": what the delta compares with.
    @Published private(set) var previousLabel: String?
    @Published private(set) var response: InspectorLoad<ResponseDocument> = .idle
    /// Bytes of the response the document on screen was built from.
    @Published private(set) var responseBytes = 0
    /// Retained bytes the latest metadata poll reported for a response still being written.
    @Published private(set) var growingBytes: Int?
    /// The metadata record as formatted JSON, for Raw; formatted off the main actor.
    @Published private(set) var metadataText = ""
    /// Which part of the capture Raw shows, and what it searches for.
    @Published var raw: RawPart = .request
    @Published var query = ""
    /// Bumped by ⌘F: Raw focuses its search field.
    @Published var searchFocus = 0
    enum RawPart: String, CaseIterable, Sendable { case request, response, headers, metadata, links, events }

    let archive: PayloadArchive
    let sessionID: String
    weak var workspace: WorkspaceModel?
    let cache: InspectorDocumentCache
    private(set) var predecessor: InspectorRequestRow?
    private(set) var active = false
    private var generation = 0
    private var bodyGeneration = 0
    private var bodyTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    /// Test seam: how many body reads started.
    private(set) var bodyReads = 0
    var metadataPollInterval: Duration = .milliseconds(1_500)
    /// Replace how a request's metadata and bodies are found, for tests.
    var sourceOverride: ((InspectorRequestRow, String) -> CapturedBodySource?)?
    var metadataOverride: ((InspectorRequestRow) async throws -> [String: WireValue])?

    init(archive: PayloadArchive, sessionID: String, workspace: WorkspaceModel?, cache: InspectorDocumentCache = .shared) {
        self.archive = archive; self.sessionID = sessionID; self.workspace = workspace; self.cache = cache
    }
    deinit { bodyTask?.cancel(); metadataTask?.cancel() }

    /// Shows a request. The same request keeps its documents and gets the
    /// newer row; another one starts over.
    func open(_ row: InspectorRequestRow, predecessor: InspectorRequestRow?, previousLabel: String?) {
        if self.row?.id != row.id {
            cancel()
            self.row = row; self.predecessor = predecessor; self.previousLabel = previousLabel
            metadata = [:]; metadataText = ""; metadataLoaded = false; metadataFailure = nil; query = ""
            conversation = .idle; delta = nil; deltaNote = nil; response = .idle; responseBytes = 0; growingBytes = nil
            if row.source == .record { tab = .conversation }
            if active { start() }
        } else {
            let metadataChanged = self.row?.source != row.source || self.row?.outcome != row.outcome
            if self.row != row { self.row = row }
            if active, metadataChanged { loadMetadata() }
            if self.predecessor?.id != predecessor?.id { self.predecessor = predecessor; self.previousLabel = previousLabel; delta = nil; deltaNote = nil; if active { loadVisibleTab() } }
        }
    }

    /// The window is on screen and this request's page is open.
    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        if active { start() } else { cancel() }
    }

    /// "Load latest": read a response that grew since it was read.
    func loadLatest() {
        guard active, tab == .response else { return }
        response = .idle
        loadVisibleTab()
    }

    func cancel() {
        generation += 1
        bodyGeneration += 1
        bodyTask?.cancel(); bodyTask = nil
        metadataTask?.cancel(); metadataTask = nil
        if conversation.loading { conversation = .idle }
        if response.loading { response = .idle }
    }

    private func start() {
        guard active, row != nil else { return }
        loadMetadata()
        loadVisibleTab()
    }

    private func tabChanged() {
        // The tab that was on screen stops reading; the one now on screen reads.
        bodyGeneration += 1; bodyTask?.cancel(); bodyTask = nil
        if conversation.loading { conversation = .idle }
        if response.loading { response = .idle }
        if active { loadVisibleTab() }
    }

    // MARK: Metadata

    private func loadMetadata() {
        guard let row, row.source != .record else { metadataLoaded = true; return }
        metadataTask?.cancel()
        let id = row.id, generation = generation
        metadataTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == generation else { return }
                do {
                    guard let current = self.row, current.id == id else { return }
                    let value = try await self.readMetadata(current)
                    guard !Task.isCancelled, self.generation == generation, self.row?.id == id else { return }
                    if self.metadata["request"] != value["request"] {
                        // The page may have opened before the request capture
                        // arrived. An empty/partial parse is not its final body.
                        // Refresh only on a changed descriptor, not every poll.
                        if self.tab == .conversation {
                            self.bodyGeneration += 1; self.bodyTask?.cancel(); self.bodyTask = nil
                        }
                        self.conversation = .idle; self.delta = nil; self.deltaNote = nil
                    }
                    if value != self.metadata {
                        self.metadata = value
                        let text = await Task.detached(priority: .userInitiated) { WireValue.object(value).pretty }.value
                        guard !Task.isCancelled, self.generation == generation else { return }
                        self.metadataText = text
                    }
                    self.metadataLoaded = true; self.metadataFailure = nil
                    let running = ["running", "streaming"].contains(value["outcome"]?.string ?? "")
                    let grown = running ? value["response"]?.object?["retainedBytes"]?.nonnegativeInteger : nil
                    if grown != self.growingBytes { self.growingBytes = grown }
                    if self.bodyTask == nil { self.loadVisibleTab() }
                    // Only a request still running is read again, and only its metadata.
                    guard running else { return }
                } catch is CancellationError { return }
                catch {
                    guard self.generation == generation else { return }
                    self.metadataLoaded = true; self.metadataFailure = error.localizedDescription
                    return
                }
                do { try await Task.sleep(for: self.metadataPollInterval) } catch { return }
            }
        }
    }

    private func readMetadata(_ row: InspectorRequestRow) async throws -> [String: WireValue] {
        if let metadataOverride { return try await metadataOverride(row) }
        if row.source != .live, let value = try? await archive.metadata(attempt: row.id) { return value }
        guard let workspace else { throw HostError.failure("This request's record is unavailable.") }
        return try await workspace.debugRequest("debug.attempt", sessionID: sessionID, params: ["attemptId": .string(row.id)])
    }

    // MARK: Bodies

    private func source(_ row: InspectorRequestRow, kind: String) -> CapturedBodySource? {
        if let sourceOverride { return sourceOverride(row, kind) }
        let state = metadata[kind]?.object?["state"]?.string ?? ""
        if row.source != .live, MessageBodyReader.canReadRetained(state) { return .archive(archive, attemptID: row.id, kind: kind) }
        if let workspace, metadataLoaded, liveCapture { return .live(workspace, sessionID: sessionID, attemptID: row.id, kind: kind) }
        return nil
    }
    /// The chat's helper is running and holds its session-memory captures.
    private var liveCapture: Bool {
        guard let workspace, let record = workspace.record(sessionID) else { return false }
        return workspace.hosts[record.workspaceID]?.isReady == true
    }

    private func loadVisibleTab() {
        guard active, let row, row.source != .record else { return }
        switch tab {
        case .conversation:
            guard conversation.value == nil || (delta == nil && deltaNote == nil), !conversation.loading else { return }
            startBody { model in try await model.loadConversation(row) }
        case .response:
            guard response.value == nil, !response.loading else { return }
            startBody { model in try await model.loadResponse(row) }
        case .raw: break
        }
    }

    private func startBody(_ work: @escaping @MainActor (InspectorRequestModel) async throws -> Void) {
        bodyTask?.cancel()
        bodyGeneration += 1
        let generation = generation, bodyGeneration = bodyGeneration
        bodyTask = Task { [weak self] in
            guard let self, self.generation == generation, self.bodyGeneration == bodyGeneration, !Task.isCancelled else { return }
            do { try await work(self) }
            catch is CancellationError { }
            catch {
                guard self.generation == generation, self.bodyGeneration == bodyGeneration, !Task.isCancelled else { return }
                let message = error.localizedDescription
                switch self.tab {
                case .conversation: if self.conversation.value == nil { self.conversation = .failed(message) } else { self.deltaNote = message }
                case .response: self.response = .failed(message)
                case .raw: break
                }
            }
            if self.generation == generation, self.bodyGeneration == bodyGeneration { self.bodyTask = nil }
        }
    }

    private func loadConversation(_ row: InspectorRequestRow) async throws {
        let document: RequestDocument
        if let ready = conversation.value { document = ready }
        else {
            guard let source = source(row, kind: "request") else {
                if !metadataLoaded { return }
                throw HostError.failure(bodyUnavailable("request"))
            }
            conversation = .loading(loaded: 0, total: 0)
            document = try await requestDocument(row, source: source) { [weak self] loaded, total in
                guard let self, self.row?.id == row.id, self.conversation.loading else { return }
                self.conversation = .loading(loaded: loaded, total: total)
            }
            try Task.checkCancellation()
            guard self.row?.id == row.id else { return }
            conversation = .ready(document)
        }
        // What is new: the digests of the request before, read and parsed
        // once for this and kept.
        guard let previous = predecessor else { delta = RequestDelta.between(document.digests, previous: nil); return }
        guard previous.source != .record else {
            deltaNote = "The request before this one has no retained body to compare with."; return
        }
        let digests = try await self.digests(previous)
        try Task.checkCancellation()
        guard self.row?.id == row.id else { return }
        if let digests { delta = RequestDelta.between(document.digests, previous: digests) }
        else { deltaNote = "The request before this one is not a JSON request to compare with." }
    }


    private func loadResponse(_ row: InspectorRequestRow) async throws {
        guard let source = source(row, kind: "response") else {
            if !metadataLoaded { return }
            throw HostError.failure(bodyUnavailable("response"))
        }
        response = .loading(loaded: 0, total: 0)
        let before = try await source.metadata()
        let key = InspectorDocumentCache.Key(attempt: row.id, kind: "response", revision: CapturedBodyReader.revision(before))
        if case .response(let cached)? = await cache.value(key) {
            try Task.checkCancellation()
            responseBytes = before.body["retainedBytes"]?.nonnegativeInteger ?? 0
            response = .ready(cached); return
        }
        bodyReads += 1
        let (bytes, described) = try await CapturedBodyReader.readBytes(kind: "response", source: source) { [weak self] loaded, total in
            guard let self, self.row?.id == row.id, self.response.loading else { return }
            self.response = .loading(loaded: loaded, total: total)
        }
        let document = try await CapturedBodyWorker.shared.run { try ResponseDocument.parse(bytes) }
        try Task.checkCancellation()
        guard self.row?.id == row.id else { return }
        guard let document else { throw HostError.failure("This response is neither a JSON response nor an event stream. Raw shows its bytes.") }
        let revision = CapturedBodyReader.revision(described)
        await cache.store(.response(document), for: InspectorDocumentCache.Key(attempt: row.id, kind: "response", revision: revision), cost: bytes.count * 2)
        try Task.checkCancellation()
        responseBytes = bytes.count
        response = .ready(document)
    }

    private func requestDocument(_ row: InspectorRequestRow, source: CapturedBodySource,
                                 progress: @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> RequestDocument {
        let before = try await source.metadata()
        let key = InspectorDocumentCache.Key(attempt: row.id, kind: "request", revision: CapturedBodyReader.revision(before))
        if case .request(let cached)? = await cache.value(key) { return cached }
        bodyReads += 1
        let (bytes, described) = try await CapturedBodyReader.readBytes(kind: "request", source: source, progress: progress)
        let document = try await CapturedBodyWorker.shared.run { try RequestDocument.parse(bytes) }
        let readKey = InspectorDocumentCache.Key(attempt: row.id, kind: "request", revision: CapturedBodyReader.revision(described))
        await cache.store(.request(document), for: readKey, cost: bytes.count + document.items.count * 1_024)
        await cache.storeDigests(document.digests, for: readKey)
        return document
    }

    private func digests(_ row: InspectorRequestRow) async throws -> RequestDigests? {
        if let sourceOverride {
            guard let source = sourceOverride(row, "request") else { throw InspectorBodies.expired }
            bodyReads += 1
            return try await InspectorBodies.digests(row, sources: [source], cache: cache)
        }
        bodyReads += 1
        return try await InspectorBodies.digests(row, sources: InspectorBodies.sources(row, archive: archive, workspace: liveCapture ? workspace : nil, sessionID: sessionID), cache: cache)
    }

    private func bodyUnavailable(_ kind: String) -> String {
        let descriptor = metadata[kind]?.object ?? [:]
        let state = descriptor["state"]?.string ?? "not captured"
        let reason = descriptor["reason"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return "The \(kind) body is \(Self.stateWords(state))" + (reason.map { ": " + $0 } ?? ".")
    }

    /// A capture state as a reader would say it.
    static func stateWords(_ state: String) -> String {
        switch state {
        case "not-retained": return "not retained"
        case "expired": return "no longer retained (it expired)"
        case "purged": return "cleared"
        case "credential-omitted": return "not retained, because hashing its credentials exceeded capture limits"
        case "corrupt": return "damaged"
        default: return state.isEmpty ? "not captured" : state.replacingOccurrences(of: "-", with: " ")
        }
    }
}

/// Reads the Inspector's two models share.
@MainActor enum InspectorBodies {
    static let expired = HostError.failure("The request before this one is no longer retained, so what is new cannot be told apart.")

    /// Where a request's body may be: the archive, then the helper's session memory.
    static func sources(_ row: InspectorRequestRow, archive: PayloadArchive, workspace: WorkspaceModel?, sessionID: String) -> [CapturedBodySource] {
        var sources: [CapturedBodySource] = []
        if row.source != .live { sources.append(.archive(archive, attemptID: row.id, kind: "request")) }
        if let workspace { sources.append(.live(workspace, sessionID: sessionID, attemptID: row.id, kind: "request")) }
        return sources
    }

    /// What a summary request asked for, from the first source that still
    /// holds its body: the same parse, and the same cached document, as its
    /// page's. Nil for a body that is not a summary request.
    static func summary(_ row: InspectorRequestRow, sources: [CapturedBodySource], cache: InspectorDocumentCache) async throws -> SummaryRequestInfo? {
        for source in sources {
            try Task.checkCancellation()
            guard let before = try? await source.metadata(), MessageBodyReader.canReadRetained(before.body["state"]?.string ?? "") else { continue }
            let key = InspectorDocumentCache.Key(attempt: row.id, kind: "request", revision: CapturedBodyReader.revision(before))
            if case .request(let cached)? = await cache.value(key) { return cached.summary }
            let (bytes, described) = try await CapturedBodyReader.readBytes(kind: "request", source: source)
            let document = try await CapturedBodyWorker.shared.run { try RequestDocument.parse(bytes) }
            let readKey = InspectorDocumentCache.Key(attempt: row.id, kind: "request", revision: CapturedBodyReader.revision(described))
            await cache.store(.request(document), for: readKey, cost: bytes.count + document.items.count * 1_024)
            return document.summary
        }
        return nil
    }

    /// The digests of the request a delta compares with, from the first source
    /// that still holds its body; kept, so it is read and parsed once.
    static func digests(_ row: InspectorRequestRow, sources: [CapturedBodySource], cache: InspectorDocumentCache) async throws -> RequestDigests? {
        for source in sources {
            try Task.checkCancellation()
            guard let before = try? await source.metadata(), MessageBodyReader.canReadRetained(before.body["state"]?.string ?? "") else { continue }
            let key = InspectorDocumentCache.Key(attempt: row.id, kind: "request", revision: CapturedBodyReader.revision(before))
            if let digests = await cache.digests(key) { return digests }
            if case .request(let cached)? = await cache.value(key) { return cached.digests }
            let (bytes, described) = try await CapturedBodyReader.readBytes(kind: "request", source: source)
            let digests = try await CapturedBodyWorker.shared.run { try RequestDocument.digests(bytes) }
            let readKey = InspectorDocumentCache.Key(attempt: row.id, kind: "request", revision: CapturedBodyReader.revision(described))
            if let digests { await cache.storeDigests(digests, for: readKey) }
            return digests
        }
        throw expired
    }
}
