import Foundation

/// The next request, as the helper would build it now: the prepared context
/// preview read whole and parsed like any request, compared with the last
/// request the session sent. Read only while its page is on screen; the
/// helper's snapshot is released when the page closes.
@MainActor final class NextRequestModel: ObservableObject {
    @Published private(set) var document: InspectorLoad<RequestDocument> = .idle
    /// The preview's own reading: counted tokens, budgets, how it counted.
    @Published private(set) var summary: [String: WireValue] = [:]
    @Published private(set) var delta: RequestDelta?
    @Published private(set) var deltaNote: String?
    @Published private(set) var previousLabel: String?
    private(set) var active = false
    private var task: Task<Void, Never>?
    private var revision: String?
    private var generation = 0
    weak var workspace: WorkspaceModel?
    let sessionID: String
    private let cache: InspectorDocumentCache
    /// Test seam: previews read.
    private(set) var reads = 0

    init(sessionID: String, workspace: WorkspaceModel?, cache: InspectorDocumentCache = .shared) {
        self.sessionID = sessionID; self.workspace = workspace; self.cache = cache
    }
    deinit { task?.cancel() }

    /// `previous` is the session's latest request, which the preview is compared with.
    func setActive(_ active: Bool, previous: InspectorRequestRow? = nil, previousLabel: String? = nil) {
        guard self.active != active else { return }
        self.active = active
        if active { load(previous: previous, previousLabel: previousLabel) } else { leave() }
    }

    func refresh(previous: InspectorRequestRow?, previousLabel: String?) {
        guard active else { return }
        load(previous: previous, previousLabel: previousLabel)
    }

    private func leave() {
        generation += 1
        task?.cancel(); task = nil
        if document.loading { document = .idle }
        // The helper keeps one prepared snapshot per session: let it go.
        if let revision, let workspace { let id = sessionID; Task { await workspace.clearPreparedContext(id, revision: revision) } }
        revision = nil
    }

    private func load(previous: InspectorRequestRow?, previousLabel: String?) {
        guard let workspace else { document = .failed("This chat is not open in the app."); return }
        task?.cancel()
        generation += 1
        let generation = generation, id = sessionID
        document = .loading(loaded: 0, total: 0); delta = nil; deltaNote = nil; self.previousLabel = previousLabel
        reads += 1
        task = Task { [weak self] in
            do {
                guard workspace.displays[id] != nil else { throw HostError.failure("Open this chat to preview its next request.") }
                let summary = try await workspace.preparedContext(id)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.summary = summary
                guard let revision = summary["revision"]?.string else { throw HostError.failure("The helper returned no prepared request.") }
                self.revision = revision
                // The complete prepared request, page by page, then parsed off
                // the main actor like any captured request.
                var pages: [String] = [], offset = 0, total = 0
                while true {
                    try Task.checkCancellation()
                    let page = try await workspace.readPreparedContext(id, revision: revision, section: "request", offset: offset)
                    guard self.generation == generation else { return }
                    let text = page["text"]?.string ?? ""
                    pages.append(text); total = Int(page["total"]?.number ?? 0)
                    self.document = .loading(loaded: offset + (text as NSString).length, total: total)
                    guard let next = page["next"]?.number.map(Int.init), next > offset else { break }
                    offset = next
                }
                let joined = pages
                let document = try await CapturedBodyWorker.shared.run { try RequestDocument.parse(Data(joined.joined().utf8)) }
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                self.document = .ready(document)
                guard let previous else { self.delta = RequestDelta.between(document.digests, previous: nil); return }
                do {
                    let sources = InspectorBodies.sources(previous, archive: workspace.traces, workspace: workspace, sessionID: id)
                    if let digests = try await InspectorBodies.digests(previous, sources: sources, cache: self.cache) {
                        guard self.generation == generation else { return }
                        self.delta = RequestDelta.between(document.digests, previous: digests)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { if self.generation == generation { self.deltaNote = "The last request's body is no longer retained, so what the next one adds cannot be told apart." } }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation else { return }
                self.document = .failed(error.localizedDescription)
            }
        }
    }

}
