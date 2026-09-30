import AppKit
import SwiftUI
import FileFinder

// ⌘P: a file of the project on screen found by part of its name and opened
// in a tab beside the chat. The project's files are listed when this opens
// (`FileFinder`: as git lists them, or walked as its ignore files say), the
// last listing shown meanwhile; every keystroke searches them away from the
// main thread, the choice kept on its file as the list changes under it.
// With nothing typed, the files opened lately in the project. What this
// holds is its own: the rest of the window is not drawn again for it.

@MainActor final class QuickOpen: ObservableObject {
    /// The project a showing finds files in, as it was when it was asked.
    struct Project: Equatable {
        let id: String
        let name: String
        let roots: [String]
        let trusted: Bool
    }
    /// One file in the list: its name and folder, and where in each (UTF-8
    /// ranges) the query's characters are.
    struct Row: Identifiable, Equatable {
        /// The file's key (`FileTab.key`): one row a file.
        let id: String
        let url: URL
        let name: String
        let nameMatches: [Range<Int>]
        let folder: String
        let folderMatches: [Range<Int>]
        let symbol: String
        /// What VoiceOver reads: "Main.swift, Sources/App".
        var label: String { folder.isEmpty ? name : name + ", " + folder }
    }
    enum Status: Equatable {
        /// Listing the files for the first time.
        case listing
        case ready
        /// The files could not be listed.
        case failed(String)
        /// The project is not trusted: its files are not listed.
        case untrusted
    }

    @Published private(set) var isOpen = false
    @Published var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published private(set) var rows: [Row] = []
    /// The row Return opens, by its file.
    @Published private(set) var selection: String?
    @Published private(set) var status: Status = .listing
    @Published private(set) var project: Project?
    /// The listing stopped at its limit: not every file is searched.
    @Published private(set) var truncated = false
    /// What the listing left out or could not apply (a folder it could not
    /// read, an ignore file too large to read), for the reader.
    @Published private(set) var warnings: [String] = []
    /// The rows answer what was typed (a search ended), rather than
    /// offering the files opened lately.
    @Published private(set) var searched = false
    /// The query the rows answer: what was typed when their search began.
    private(set) var answered: String?

    /// How many files the list holds at most.
    nonisolated static let limit = FileFinderSearch.defaultLimit
    /// How many files lately opened are kept, a project.
    static let recentLimit = 20
    /// How many files a project's listing holds at most.
    static let fileLimit = FileListingLimits().files

    /// A finder a project, for the projects shown lately: each holds its
    /// last listing, so showing again answers at once.
    private var finders: [(key: String, finder: FileFinder)] = []
    private static let finderLimit = 2
    private var index: FileFinderIndex?
    private var generation = 0
    private var searching: SearchStop?
    private var listing: Task<Void, Never>?
    /// Return waits for its query; another query or closing discards it.
    private var pendingOpen: (query: String, id: String?, open: (Row, Int?) -> Void)?
    /// Files opened lately, newest first, by project.
    private var recents: [String: [URL]] = [:]
    /// Where the keyboard was before this took it.
    private weak var previousWindow: NSWindow?
    private weak var previousResponder: NSResponder?
    private var resignObserver: NSObjectProtocol?
    /// The window whose keyboard the list took, also where it is drawn.
    var presentationWindow: NSWindow? { isOpen ? previousWindow : nil }

    // MARK: Showing and closing

    /// Shows the list for `project`, the keyboard taken from `window`.
    func show(_ project: Project, in window: NSWindow?) {
        if isOpen, self.project == project, previousWindow === window { return }
        close(restoringFocus: false)
        previousWindow = window; previousResponder = window?.firstResponder
        // Another project's files are not this one's, even for a moment.
        if self.project != project { index = nil }
        self.project = project
        query = ""; rows = []; selection = nil; searched = false
        truncated = index?.truncated ?? false; warnings = index?.warnings ?? []
        isOpen = true
        if let window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(restoringFocus: false) }
            }
        }
        guard project.trusted else { status = .untrusted; index = nil; truncated = false; warnings = []; return }
        let finder = finder(for: project)
        status = .listing
        // With nothing typed: the files opened lately, at once.
        refresh()
        listing = Task { [weak self] in
            let latest = await finder.latest
            guard let self, self.isOpen, self.project == project else { return }
            if let latest { self.adopt(latest) }
            let fresh = await finder.refreshed()
            guard self.isOpen, self.project == project else { return }
            if let fresh { self.adopt(fresh) }
            else { self.status = .failed(await finder.failure ?? "The project's files could not be listed.") }
        }
    }

    /// Closes the list; the keyboard goes back where it was, when asked and
    /// when that is still on screen in the same window.
    func close(restoringFocus: Bool) {
        guard isOpen else { return }
        isOpen = false
        pendingOpen = nil
        searching?.stop(); searching = nil
        listing?.cancel(); listing = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if restoringFocus, let window = previousWindow, let responder = previousResponder {
            if let view = responder as? NSView {
                if view.window === window, !view.isHiddenOrHasHiddenAncestor { window.makeFirstResponder(view) }
            } else {
                window.makeFirstResponder(responder)
            }
        }
        previousWindow = nil; previousResponder = nil
    }

    /// Forgets the projects that are gone or no longer trusted, and closes
    /// the list if it was for one of them.
    func projectsChanged(_ projects: [Project]) {
        let current = Set(projects.filter(\.trusted).map(Self.key))
        finders.removeAll { entry in
            guard !current.contains(entry.key) else { return false }
            Task { await entry.finder.cancel() }
            return true
        }
        if let project, isOpen, !projects.contains(where: { $0.id == project.id && $0.roots == project.roots && $0.trusted == project.trusted }) {
            close(restoringFocus: true)
        }
    }

    nonisolated private static func key(_ project: Project) -> String { ([project.id] + project.roots).joined(separator: "\u{0}") }

    private func finder(for project: Project) -> FileFinder {
        let key = Self.key(project)
        if let at = finders.firstIndex(where: { $0.key == key }) {
            let entry = finders.remove(at: at)
            finders.append(entry)
            return entry.finder
        }
        let finder = FileFinder(roots: project.roots)
        finders.append((key, finder))
        // The oldest go, and their indexes with them.
        while finders.count > Self.finderLimit { finders.removeFirst() }
        return finder
    }

    private func adopt(_ fresh: FileFinderIndex) {
        guard fresh !== index else { status = .ready; return }
        index = fresh
        truncated = fresh.truncated
        warnings = fresh.warnings
        status = .ready
        refresh()
    }

    // MARK: The list

    /// Moves the choice `step` rows, around neither end.
    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        let at = selection.flatMap { id in rows.firstIndex { $0.id == id } } ?? -1
        let next = min(rows.count - 1, max(0, at + step))
        selection = rows[next].id
    }
    func select(_ id: String) { if rows.contains(where: { $0.id == id }) { selection = id } }
    var selectedRow: Row? { selection.flatMap { id in rows.first { $0.id == id } } }
    /// The line a query ending ":N" asks for, from 1.
    var line: Int? { FileFinderQuery(query).line }

    /// Opens only a choice from the current query's answer. Keystrokes may
    /// arrive before the background search has delivered that answer.
    func openChoice(_ id: String? = nil, whenReady open: @escaping (Row, Int?) -> Void) {
        guard isOpen else { return }
        guard answered == query else { pendingOpen = (query, id, open); return }
        if let id {
            guard rows.contains(where: { $0.id == id }) else { return }
            select(id)
        }
        guard let row = selectedRow else { return }
        open(row, line)
    }

    /// Notes a file opened in `project`, for the list with nothing typed.
    func noteOpened(_ url: URL, projectID: String?) {
        guard let projectID else { return }
        var list = recents[projectID] ?? []
        list.removeAll { $0 == url }
        list.insert(url, at: 0)
        recents[projectID] = Array(list.prefix(Self.recentLimit))
    }

    private func refresh() {
        generation &+= 1
        let generation = generation
        searching?.stop(); searching = nil
        let typed = query, parsed = FileFinderQuery(query)
        if pendingOpen?.query != typed { pendingOpen = nil }
        answered = nil; searched = false
        guard isOpen, let project, project.trusted else { rows = []; selection = nil; return }
        if parsed.isEmpty {
            searched = false; answered = typed
            show(recentRows(project))
            return
        }
        guard let index else { rows = []; selection = nil; return }
        let stop = SearchStop()
        searching = stop
        let roots = project.roots.count
        DispatchQueue.global(qos: .userInteractive).async {
            let matches = FileFinderSearch.search(parsed, in: index, limit: Self.limit, cancelled: { stop.isStopped })
            let rows = matches.map { Self.row($0, in: index, labelRoots: roots > 1) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation, !stop.isStopped else { return }
                    self.searched = true; self.answered = typed
                    self.show(rows)
                }
            }
        }
    }

    /// Shows `rows`, the choice kept on its file if it is still there.
    private func show(_ rows: [Row]) {
        // Different listed paths may resolve to the same file. Keep the
        // first (best-ranked, or most recent) row for each tab key.
        var seen = Set<String>()
        let rows = rows.filter { seen.insert($0.id).inserted }
        self.rows = rows
        if selection == nil || !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
        if let pending = pendingOpen, pending.query == answered {
            pendingOpen = nil
            openChoice(pending.id, whenReady: pending.open)
        }
    }

    /// The files opened lately in `project` that are still there and still
    /// in it, newest first.
    private func recentRows(_ project: Project) -> [Row] {
        let roots = project.roots.map { FileTab.key(for: URL(fileURLWithPath: $0)) }
        return (recents[project.id] ?? []).compactMap { url in
            let key = FileTab.key(for: url)
            guard let root = roots.first(where: { key.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }),
                  FileManager.default.fileExists(atPath: key) else { return nil }
            let relative = String(key.dropFirst(root.count + (root.hasSuffix("/") ? 0 : 1)))
            let rootName = project.roots.count > 1 ? URL(fileURLWithPath: root).lastPathComponent : nil
            return Self.row(key: key, url: URL(fileURLWithPath: key), relative: relative, highlights: [], rootName: rootName)
        }
    }

    // MARK: Rows

    nonisolated static func row(_ match: FileFinderMatch, in index: FileFinderIndex, labelRoots: Bool) -> Row {
        let url = index.url(match.index)
        let root = index.root(match.index)
        return row(key: FileTab.key(for: url), url: url, relative: match.path, highlights: match.highlights,
                   rootName: labelRoots ? URL(fileURLWithPath: root).lastPathComponent : nil)
    }

    /// A row for the file at `relative` below its root, the UTF-8 ranges
    /// `highlights` of that path set apart.
    nonisolated static func row(key: String, url: URL, relative: String, highlights: [Range<Int>], rootName: String?) -> Row {
        let bytes = Array(relative.utf8)
        let slash = bytes.lastIndex(of: 0x2F)
        let nameStart = slash.map { $0 + 1 } ?? 0
        let name = String(decoding: bytes[nameStart...], as: UTF8.self)
        var folder = slash.map { String(decoding: bytes[..<$0], as: UTF8.self) } ?? ""
        let nameHighlights = highlights.compactMap { clip($0, to: nameStart..<bytes.count) }
        var folderHighlights = highlights.compactMap { clip($0, to: 0..<(slash ?? 0)) }
        if let rootName {
            let prefix = rootName + (folder.isEmpty ? "" : "/")
            folder = prefix + folder
            folderHighlights = folderHighlights.map { ($0.lowerBound + prefix.utf8.count)..<($0.upperBound + prefix.utf8.count) }
        }
        return Row(id: key, url: url, name: name, nameMatches: nameHighlights, folder: folder, folderMatches: folderHighlights,
                   symbol: FileTab.symbol(for: url))
    }

    /// `range` within `bounds`, as offsets from the bounds' start; nil when
    /// they do not meet.
    nonisolated private static func clip(_ range: Range<Int>, to bounds: Range<Int>) -> Range<Int>? {
        let lower = max(range.lowerBound, bounds.lowerBound), upper = min(range.upperBound, bounds.upperBound)
        guard lower < upper else { return nil }
        return (lower - bounds.lowerBound)..<(upper - bounds.lowerBound)
    }

}

/// A search a newer keystroke has replaced, so it stops.
final class SearchStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}
