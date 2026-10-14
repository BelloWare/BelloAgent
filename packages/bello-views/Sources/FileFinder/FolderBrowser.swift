import Foundation

/// Lazy, viewer-only navigation shared by the tree and folder menus. The
/// caller supplies file-opening and styling; nothing here knows an agent.
@MainActor public final class FolderBrowser {
    public typealias Reader = @Sendable (URL, URL) async throws -> FolderDirectory
    public struct Row: Equatable {
        public enum Kind: Equatable { case entry, more(Int), loading, message(String) }
        public let url: URL
        public let depth: Int
        public let kind: Kind
        public let entry: FolderEntry?
    }
    public private(set) var root: URL?
    public private(set) var selectedURL: URL?
    public private(set) var expanded: Set<URL> = []
    public var changed: (() -> Void)?
    public var openFile: ((URL) -> Void)?
    public let pageSize: Int
    private let reader: Reader
    private var home = FileManager.default.homeDirectoryForCurrentUser
    private var projectRoot: URL?
    private var target: URL?
    private var directories: [URL: FolderDirectory] = [:]
    private var limits: [URL: Int] = [:]
    private var failures: [URL: String] = [:]
    private var jobs: [URL: Task<Void, Never>] = [:]
    private var tokens: [URL: UUID] = [:]

    public init(pageSize: Int = 200, reader: @escaping Reader = { try await FolderDirectory.read($0, relativeTo: $1) }) {
        self.pageSize = max(1, pageSize); self.reader = reader
    }
    deinit { for job in jobs.values { job.cancel() } }
    public var canGoUp: Bool { guard let root else { return false }; return projectRoot == nil && root.path != "/" && root != home }
    public func snapshot(_ folder: URL) -> FolderDirectory? { directories[FileBreadcrumb.normalized(folder)] }
    public func failure(_ folder: URL) -> String? { failures[FileBreadcrumb.normalized(folder)] }
    public func isLoading(_ folder: URL) -> Bool { jobs[FileBreadcrumb.normalized(folder)] != nil }

    public func show(file: URL, projectRoot: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        stop()
        self.home = FileBreadcrumb.normalized(home)
        let file = FileBreadcrumb.normalized(file)
        self.projectRoot = projectRoot.flatMap { FileBreadcrumb.contains(file, in: $0) ? FileBreadcrumb.normalized($0) : nil }
        root = self.projectRoot ?? FileBreadcrumb.normalized(file.deletingLastPathComponent())
        directories = [:]; failures = [:]; limits = [:]; expanded = []
        target = file; selectedURL = file
        reveal(file)
    }
    /// A menu reads only the level entered, never its unopened submenus.
    public func showFolder(_ folder: URL, relativeTo base: URL? = nil) {
        let folder = FileBreadcrumb.normalized(folder)
        stop(); root = folder; projectRoot = base.map(FileBreadcrumb.normalized); target = nil; selectedURL = nil
        directories = [:]; failures = [:]; limits = [:]; expanded = [folder]
        load(folder); changed?()
    }
    public func reveal(_ file: URL, isDirectory: Bool = false) {
        let file = FileBreadcrumb.normalized(file)
        guard let root, FileBreadcrumb.contains(file, in: root) else { return }
        target = file; selectedURL = file
        var folder = isDirectory ? file : FileBreadcrumb.normalized(file.deletingLastPathComponent())
        while FileBreadcrumb.contains(folder, in: root) {
            expanded.insert(folder); load(folder)
            if folder == root { break }
            folder = FileBreadcrumb.normalized(folder.deletingLastPathComponent())
        }
        changed?()
    }
    public func goUp() {
        guard canGoUp, let root else { return }
        let parent = FileBreadcrumb.normalized(root.deletingLastPathComponent())
        stop(); self.root = parent; expanded.insert(parent)
        for folder in expanded { load(folder) }
        if let target { reveal(target) } else { load(parent); changed?() }
    }
    public func expand(_ folder: URL) { let folder = FileBreadcrumb.normalized(folder); expanded.insert(folder); load(folder, refresh: true); changed?() }
    public func collapse(_ folder: URL) {
        let folder = FileBreadcrumb.normalized(folder)
        expanded = expanded.filter { !FileBreadcrumb.contains($0, in: folder) }
        for url in Array(jobs.keys) where FileBreadcrumb.contains(url, in: folder) { cancel(url) }
        changed?()
    }
    public func select(_ url: URL) { selectedURL = FileBreadcrumb.normalized(url); changed?() }
    public func activate(_ entry: FolderEntry) {
        select(entry.url)
        if entry.isDirectory {
            if expanded.contains(entry.url) { collapse(entry.url) } else { expand(entry.url) }
        } else { openFile?(entry.url) }
    }
    public func showMore(in folder: URL) { let folder = FileBreadcrumb.normalized(folder); limits[folder] = (limits[folder] ?? pageSize) + pageSize; changed?() }
    public func visibleEntries(in folder: URL) -> [FolderEntry] {
        let folder = FileBreadcrumb.normalized(folder)
        guard let snapshot = directories[folder] else { return [] }
        let limit = limits[folder] ?? pageSize
        var result = Array(snapshot.entries.prefix(limit))
        // Pin the open file (or the folder leading to it) within the cap,
        // even if it sorts after the first page. Other rows stay paginated.
        if let target, let needed = snapshot.entries.first(where: { $0.url == target || ($0.isDirectory && FileBreadcrumb.contains(target, in: $0.url)) }), !result.contains(needed) {
            if !result.isEmpty { result.removeLast() }; result.append(needed)
        }
        return result
    }
    public func remaining(in folder: URL) -> Int { max(0, (snapshot(folder)?.entries.count ?? 0) - visibleEntries(in: folder).count) }
    public var rows: [Row] {
        guard let root else { return [] }
        var result: [Row] = []
        func append(_ folder: URL, depth: Int) {
            if let error = failures[folder] { result.append(Row(url: folder, depth: depth, kind: .message(error), entry: nil)); return }
            guard let snapshot = directories[folder] else {
                result.append(Row(url: folder, depth: depth, kind: .loading, entry: nil)); return
            }
            for entry in visibleEntries(in: folder) {
                result.append(Row(url: entry.url, depth: depth, kind: .entry, entry: entry))
                if entry.isDirectory, expanded.contains(entry.url) { append(entry.url, depth: depth + 1) }
            }
            let count = remaining(in: folder)
            if count > 0 { result.append(Row(url: folder, depth: depth, kind: .more(min(pageSize, count)), entry: nil)) }
            if let warning = snapshot.warning { result.append(Row(url: folder, depth: depth, kind: .message(warning), entry: nil)) }
            if snapshot.entries.isEmpty { result.append(Row(url: folder, depth: depth, kind: .message("Empty folder"), entry: nil)) }
        }
        append(root, depth: 0); return result
    }
    // Tests await the real publication boundary even for a reader that ignores cancellation.
    func pendingRead(in folder: URL) -> Task<Void, Never>? { jobs[FileBreadcrumb.normalized(folder)] }

    public func stop() {
        for url in Array(jobs.keys) { cancel(url) }
    }
    private func cancel(_ url: URL) { jobs.removeValue(forKey: url)?.cancel(); tokens.removeValue(forKey: url) }
    private func load(_ folder: URL, refresh: Bool = false) {
        guard jobs[folder] == nil, refresh || directories[folder] == nil else { return }
        let token = UUID(), reader = reader, base = projectRoot ?? root ?? folder
        tokens[folder] = token; failures[folder] = nil
        let work = Task.detached(priority: .userInitiated) { try await reader(folder, base) }
        jobs[folder] = Task { [weak self] in
            let result: Result<FolderDirectory, Error>
            do { result = .success(try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }) }
            catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.tokens[folder] == token else { return }
            self.jobs[folder] = nil; self.tokens[folder] = nil
            switch result {
            case .success(let value): self.directories[folder] = value
            case .failure(let error): self.failures[folder] = String(describing: error)
            }
            self.changed?()
        }
    }
}
