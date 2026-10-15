import Combine
import Foundation

/// One owner for list reads. Every publication carries a request identity,
/// separate from both the query value and the controller's status refresh.
@MainActor public final class GitHistoryState: ObservableObject {
    public struct Reading: Equatable {
        public init() {}
        public var query = GitHistoryQuery()
        public var snapshot: GitHistorySnapshot?
        public var commits: [GitCommit] = []
        public var next: GitHistoryCursor?
        public var loading = false
        public var paging = false
        public var notice = ""
    }
    @Published public private(set) var reading = Reading()
    private let service: GitService
    private var identity = UUID()
    private var task: Task<GitHistoryPage, Error>?
    private var pageTask: Task<GitHistoryPage, Error>?
    /// A completed read held at its publication boundary by behavioral tests.
    var didRead: ((GitHistoryQuery) async -> Void)?

    public init(service: GitService = .shared) { self.service = service }
    deinit { task?.cancel(); pageTask?.cancel() }

    public func cancel() {
        identity = UUID(); task?.cancel(); task = nil; pageTask?.cancel(); pageTask = nil
        if reading.loading || reading.paging { var next = reading; next.loading = false; next.paging = false; reading = next }
    }

    /// A closed panel releases its rows and query; hiding only cancels reads.
    public func reset() { cancel(); reading = Reading() }

    /// Returns false for a retired read. Its success, error and loading state
    /// all stay private, even if a test/IO completion ignores cancellation.
    @discardableResult public func reload(in root: String, query: GitHistoryQuery, preservingCount: Bool = false) async -> Bool {
        cancel()
        let token = identity, old = reading
        defer {
            if identity == token {
                task = nil
                if reading.loading { var idle = reading; idle.loading = false; reading = idle }
            }
        }
        let keep = old.snapshot?.root == root && old.query == query
        let limit = preservingCount && keep ? max(50, old.commits.count) : 50
        // Watcher refreshes keep the displayed rows, cursor and flags until
        // replacement data arrives. A loading tail would change geometry on
        // every save even when the history itself has not changed.
        if !(preservingCount && keep) {
            var next = keep ? old : Reading()
            next.query = query; next.loading = true; next.paging = false; next.notice = ""; next.next = nil
            reading = next
        }
        guard identity == token else { return false }
        let service = service
        do {
            // Resolution belongs to the same task as the page, so switching
            // queries cancels both the ref read and the subsequent log.
            var snapshot: GitHistorySnapshot?
            let work = Task { @MainActor in
                let resolved = try await service.historySnapshot(in: root, query: query)
                try Task.checkCancellation()
                snapshot = resolved
                return try await service.historyPage(resolved, limit: limit)
            }
            task = work
            let page = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            await didRead?(query)
            guard identity == token, !Task.isCancelled else { return false }
            var result = Reading(); result.query = query; result.snapshot = snapshot; result.commits = page.commits; result.next = page.next
            task = nil; reading = result
            return identity == token
        } catch {
            guard identity == token, !Task.isCancelled else { return false }
            task = nil
            var result = reading; result.loading = false
            if !(error is CancellationError) { result.notice = error.localizedDescription }
            reading = result
            return false
        }
    }

    @discardableResult public func loadMore() async -> Bool {
        guard task == nil, !reading.loading, !reading.paging, let snapshot = reading.snapshot, let cursor = reading.next else { return false }
        let token = identity
        defer {
            if identity == token {
                pageTask = nil
                if reading.paging { var idle = reading; idle.paging = false; reading = idle }
            }
        }
        var next = reading; next.paging = true; next.notice = ""; reading = next
        guard identity == token else { return false }
        let service = service, work = Task { try await service.historyPage(snapshot, after: cursor) }
        pageTask = work
        do {
            let page = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            await didRead?(snapshot.query)
            guard identity == token, !Task.isCancelled, reading.next == cursor else { return false }
            var result = reading
            let known = Set(result.commits.map(\.hash))
            result.commits += page.commits.filter { !known.contains($0.hash) }
            result.next = page.next; result.paging = false
            pageTask = nil; reading = result
            return identity == token
        } catch {
            guard identity == token, !Task.isCancelled else { return false }
            pageTask = nil
            var result = reading; result.paging = false
            if !(error is CancellationError) { result.notice = error.localizedDescription }
            reading = result
            return false
        }
    }
}
