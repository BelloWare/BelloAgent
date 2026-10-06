import AppKit
import Combine
import FileView

// A file, as a tab beside the chats (`TabHost`): its path and state over its
// text. The tab remembers the project it was opened in: the path is shown
// against that project's root, and a file whose project was removed, or is
// no longer trusted, is not read at all; the tab says why instead. A file
// that is gone says so too. What is read of a file is let go of while its
// tab is hidden; its place and selection stay.

/// What a file tab knows of the project it was opened in.
enum FileProjectState: Equatable {
    /// Opened outside any project.
    case none
    case trusted(name: String, root: String)
    case untrusted(name: String)
    case removed
    var isTrusted: Bool { if case .trusted = self { return true }; return false }
}

@MainActor final class FileTab: AppKitHostedTab {
    override class var kind: String { "file" }
    let url: URL
    /// The project the file was opened in, if any.
    let projectID: String?
    /// What the app knows of a project, by id: set once by the app.
    static var resolveProject: (String?) -> FileProjectState = { $0 == nil ? .none : .removed }

    @Published private(set) var project: FileProjectState
    @Published private(set) var status: FileView.FileDocument.Status = .indexing
    @Published private(set) var fellBack = false
    private var madeDocument: FileView.FileDocument?
    private var madeScroll: FileTextScrollView?
    private var syntax: FileSyntax?
    private var watcher: FileWatch?
    private var shown = false
    private var followTask: Task<Void, Never>?
    private var following: FileView.FileDocument?
    private var madePreview: FilePreview?
    var previewKind: String? { FilePreview.kind(for: url) }
    var preview: FilePreview {
        if let madePreview { return madePreview }
        let preview = FilePreview(url: url)
        preview.changed = { [weak self, weak preview] in
            guard let self, let preview, self.madePreview === preview else { return }
            self.status = .ready; self.updateSymbol()
        }
        madePreview = preview
        return preview
    }
    private var followToken = 0
    var isWatching: Bool { watcher?.isWatching == true && watcher?.isArmed == true }

    override func didShow() {
        shown = true
        startWatching()
        followChange()
        blame.resume()
    }
    override func didHide() { shown = false; stopWatching(); blame.suspend() }
    /// Who changed each line, while it is shown (`FileBlame`).
    let blame = FileBlame()
    var isShownNow: Bool { shown }
    var scrollIfMade: FileTextScrollView? { madeScroll }
    /// The document if one is open, without opening one.
    var documentIfMade: FileView.FileDocument? { madeDocument }
    private func startWatching() {
        guard shown, readable else { return }
        if watcher == nil { watcher = FileWatch(url: url) { [weak self] in self?.followChange() } }
        watcher?.start()
    }
    private func stopWatching() {
        watcher?.stop(); followToken &+= 1
        followTask?.cancel(); followTask = nil
        following?.close(); following = nil
        madePreview?.suspend()
    }
    private func followChange() {
        guard shown, readable else { return }
        if previewKind != nil { madePreview?.load(); return }
        guard let old = madeDocument else { return }
        followToken &+= 1
        let token = followToken
        followTask?.cancel()
        followTask = Task { [weak self] in
            guard await old.hasChanged(), let self, !Task.isCancelled, self.shown, self.readable, self.followToken == token else { return }
            self.following?.close()
            var options = FileView.FileDocument.Options(); options.requiresResolvedPath = true
            let fresh = FileView.FileDocument(url: self.url, options: options)
            self.following = fresh
            fresh.onStatusChange = { [weak self, weak fresh] status in
                guard let self, let fresh, self.following === fresh, self.followToken == token else { return }
                switch status {
                case .ready, .truncated, .binary:
                    self.following = nil
                    self.madeDocument = fresh
                    if let scroll = self.madeScroll {
                        scroll.textView.show(fresh, name: self.title, preservingPosition: true)
                        self.syntax = FileSyntax(source: fresh, view: scroll.textView, extension: self.url.pathExtension)
                        scroll.textView.syntax = { [weak syntax = self.syntax] line, range, text in syntax?.colors(line: line, piece: range, text: text) ?? [] }
                    }
                    // The bar the reader had open stays open, its query, case
                    // and field as they were; finding goes on in the new text.
                    self.textChanged()
                    fresh.onStatusChange = { [weak self, weak fresh] status in
                        guard let self, let fresh, self.madeDocument === fresh else { return }
                        self.status = status; self.fellBack = fresh.fellBack; self.updateSymbol()
                    }
                    self.status = status; self.fellBack = fresh.fellBack; self.updateSymbol()
                    // After the status: blame reads only text said to be ready.
                    self.blame.documentChanged()
                    old.close()
                case .failed:
                    // Gone or unreadable: the bar stays, its search stops
                    // (no count of a text that is not there), and goes on
                    // once the file is back.
                    self.following = nil; fresh.close()
                    self.finder?.close(); self.finder = nil
                    self.status = status; self.updateSymbol(); self.findChanged()
                    self.blame.documentChanged()
                default: break
                }
            }
        }
    }
    private var target: ClosedRange<Int>?

    /// The key a file's tab is found by: one tab a file, whichever path
    /// reached it.
    nonisolated static func key(for url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    init(url: URL, projectID: String?, lines: ClosedRange<Int>? = nil) {
        let key = FileTab.key(for: url), file = URL(fileURLWithPath: key)
        self.url = file; self.projectID = projectID; self.target = lines
        project = FileTab.resolveProject(projectID)
        super.init(key: key, title: file.lastPathComponent, symbol: FileTab.symbol(for: file))
        blame.tab = self
        updateHelp()
    }

    /// Readable only in a trusted project, or outside any.
    var readable: Bool {
        switch project {
        case .none, .trusted: return true
        case .untrusted, .removed: return false
        }
    }
    /// Why the file cannot be shown, if it cannot.
    var missingReason: String? {
        switch project {
        case .removed: return "Its project was removed from Bello Agent."
        case .untrusted(let name): return "Its project, \(name), is not trusted."
        case .none, .trusted: break
        }
        if case .failed = status { return "It is not there any more, or can't be opened." }
        return nil
    }
    /// Whether the file has been opened.
    var hasDocument: Bool { madeDocument != nil }
    /// The document, opened when first needed and only where it may be read.
    /// Opening it changes nothing published (it is opened while the tab's
    /// view is being drawn): its status is `.indexing`, as the tab's is
    /// until the document says otherwise.
    var document: FileView.FileDocument? {
        guard readable, previewKind == nil else { return nil }
        if let madeDocument { return madeDocument }
        var options = FileView.FileDocument.Options(); options.requiresResolvedPath = true
        let document = FileView.FileDocument(url: url, options: options)
        document.onStatusChange = { [weak self, weak document] status in
            guard let self, let document, self.madeDocument === document else { return }
            self.fellBack = document.fellBack
            self.status = status
            self.updateSymbol()
            if status != .indexing { self.blame.documentChanged() }
        }
        madeDocument = document
        return document
    }
    /// The text, in the view kept while the tab is open.
    var scroll: FileTextScrollView? {
        if let madeScroll { return madeScroll }
        guard let document else { return nil }
        let scroll = FileTextScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        scroll.textView.usePiDesign()
        scroll.textView.show(document, name: title)
        syntax = FileSyntax(source: document, view: scroll.textView, extension: url.pathExtension)
        scroll.textView.syntax = { [weak syntax] line, range, text in syntax?.colors(line: line, piece: range, text: text) ?? [] }
        if let target { scroll.textView.reveal(lines: target); self.target = nil }
        madeScroll = scroll
        return scroll
    }
    /// Shows lines of the file, set apart.
    func reveal(lines: ClosedRange<Int>) {
        if let madeScroll { madeScroll.textView.reveal(lines: lines) } else { target = lines }
    }
    /// Shows the file from its start, nothing set apart, whatever was shown
    /// or asked for before.
    func showTop() {
        target = nil
        madeScroll?.textView.showTop()
    }

    override func makeAppKitContent() -> NSView { FileTabContent(tab: self) }
    override var focusView: NSView? { madeScroll?.textView }
    override func savedState() -> Data? { try? JSONEncoder().encode(Saved(project: projectID)) }
    private struct Saved: Codable { var project: String? }
    override class func restore(key: String, state: Data?) -> HostedTab? {
        let saved = state.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        return FileTab(url: URL(fileURLWithPath: key), projectID: saved?.project)
    }
    override func projectsChanged() {
        let now = Self.resolveProject(projectID)
        guard now != project else { return }
        project = now
        if !readable {
            stopWatching()
            // Not to be read: what was read goes, and the view with it, and
            // what was known of the file: read again from the start if it
            // may be read again.
            finder?.close(); finder = nil; bar = .none
            blame.hide()
            madeDocument?.close(); madeDocument = nil
            madeScroll = nil; syntax = nil
            madePreview?.close(); madePreview = nil
            status = .indexing; fellBack = false
        }
        if readable { startWatching(); followChange() }
        updateHelp(); updateSymbol()
    }
    override func willClose() {
        blame.hide()
        shown = false; stopWatching(); watcher = nil
        finder?.close(); finder = nil
        madeDocument?.close()
        madeDocument = nil; madeScroll = nil; syntax = nil
        madePreview?.close(); madePreview = nil
    }

    // MARK: Find and go to line

    /// The bar under the header: finding in the file, going to a line, or none.
    enum Bar: Equatable { case none, find, goToLine }
    @Published private(set) var bar = Bar.none
    /// The query and whether it matches case: kept while the tab is open.
    @Published var findQuery = "" { didSet { if findQuery != oldValue { finder?.set(query: findQuery, matchCase: matchCase) } } }
    @Published var matchCase = false { didSet { if matchCase != oldValue { finder?.set(query: findQuery, matchCase: matchCase) } } }
    /// What the find bar says of its search.
    @Published private(set) var findLabel = ""
    @Published private(set) var canStep = false
    @Published var lineQuery = ""
    /// Bumped to put the keys in the bar's field.
    @Published private(set) var barFocus = 0
    private var finder: FileFind?

    /// ⌘F in the text or the find bar opens it with the keys in its field;
    /// ⌘L goes to a line; ⌘G and ⇧⌘G go to the next and previous match
    /// while the find bar has a query. Any other key goes on.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard madeScroll != nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "f"): openFind(); return true
        case ([.command], "l"): openGoToLine(); return true
        case ([.command], "g") where bar == .find && !findQuery.isEmpty: findNext(); return true
        case ([.command, .shift], "g") where bar == .find && !findQuery.isEmpty: findPrevious(); return true
        default: return false
        }
    }
    /// Opens the find bar: a selection on one line, short enough to be a
    /// query, becomes it (a longer one is not read to find out).
    func openFind() {
        guard let view = madeScroll?.textView else { return }
        if let text = FileFind.query(fromSelectionIn: view) { findQuery = text }
        if finder == nil {
            let finder = FileFind(view: view)
            finder.onChange = { [weak self] in self?.findChanged() }
            self.finder = finder
            finder.set(query: findQuery, matchCase: matchCase)
        }
        bar = .find
        barFocus &+= 1
        selectFieldText()
        findChanged()
    }
    /// The file was read again: the find bar's search follows the new text,
    /// from where the reader is, nothing moved and the keys left where they
    /// are; a find bar whose search stopped while the file was gone starts
    /// again.
    private func textChanged() {
        guard bar == .find, let view = madeScroll?.textView else { return }
        if let finder { finder.textChanged() } else {
            let finder = FileFind(view: view)
            finder.onChange = { [weak self] in self?.findChanged() }
            self.finder = finder
            finder.resume(query: findQuery, matchCase: matchCase)
        }
        findChanged()
    }
    func findNext() { finder?.next() }
    func findPrevious() { finder?.previous() }
    func openGoToLine() {
        guard madeScroll != nil else { return }
        finder?.close(); finder = nil
        lineQuery = ""
        bar = .goToLine
        barFocus &+= 1
        selectFieldText()
    }
    /// ⌘F or ⌘L again with the keys already in the bar's field: its text
    /// selected, to type over (a field given the keys selects it itself).
    private func selectFieldText() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hasContent, let window = self.contentView.window,
                      let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, editor.isDescendant(of: self.contentView) else { return }
                editor.selectAll(nil)
            }
        }
    }
    /// Goes to the line asked for (from 1): a line not found yet is shown
    /// once it is, and past the end, the last (`reveal`).
    func goToLine() {
        guard let view = madeScroll?.textView, let number = Int(lineQuery.trimmingCharacters(in: .whitespaces)), number > 0 else { return }
        view.reveal(lines: (number - 1)...(number - 1))
        closeBar()
    }
    /// Closes the bar, the find's matches with it, and gives the keys back to
    /// the text.
    func closeBar() {
        finder?.close(); finder = nil
        bar = .none
        if let view = madeScroll?.textView, let window = view.window { window.makeFirstResponder(view) }
        findChanged()
    }
    /// The lines there are, beside the go-to-line field: more may come
    /// while the file is still being read through.
    var lineRange: String {
        guard let source = madeScroll?.textView.source else { return "" }
        return "Lines 1 to \(source.lineCount.formatted())\(source.isIndexing ? "+" : "")"
    }
    private func findChanged() {
        guard let finder, bar == .find else {
            if findLabel != "" { findLabel = "" }
            if canStep { canStep = false }
            return
        }
        let label: String
        if findQuery.isEmpty { label = "" }
        else if finder.isTooLong { label = "Too long to search" }
        else if let stopped = finder.stopped { label = stopped }
        else if finder.count == 0 { label = finder.isCounting ? "Searching…" : "No matches" }
        else {
            let total = finder.count.formatted() + (finder.isCounting ? "+" : "")
            label = finder.ordinal.map { "\($0.formatted()) of \(total) matches" } ?? "\(total) matches"
        }
        if findLabel != label { findLabel = label }
        let step = finder.count > 0 || finder.current != nil
        if canStep != step { canStep = step }
    }

    private func updateHelp() {
        switch project {
        case .trusted(let name, _), .untrusted(let name): help = "\(url.path)\nIn \(name)"
        case .none, .removed: help = url.path
        }
    }
    private func updateSymbol() { symbol = missingReason == nil ? Self.symbol(for: url) : "exclamationmark.triangle" }

    nonisolated static func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift", "js", "mjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "m", "mm", "cpp", "hpp", "java", "kt", "sh", "zsh",
             "json", "yml", "yaml", "toml", "css", "html", "xml", "sql":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "log", "csv", "rtf": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}

