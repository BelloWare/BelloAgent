import AppKit
import SwiftUI
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
}

@MainActor final class FileTab: HostedTab {
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
    private var target: ClosedRange<Int>?

    /// The key a file's tab is found by: one tab a file, whichever path
    /// reached it.
    nonisolated static func key(for url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    init(url: URL, projectID: String?, lines: ClosedRange<Int>? = nil) {
        let key = FileTab.key(for: url), file = URL(fileURLWithPath: key)
        self.url = file; self.projectID = projectID; self.target = lines
        project = FileTab.resolveProject(projectID)
        super.init(key: key, title: file.lastPathComponent, symbol: FileTab.symbol(for: file))
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
        guard readable else { return nil }
        if let madeDocument { return madeDocument }
        let document = FileView.FileDocument(url: url)
        document.onStatusChange = { [weak self, weak document] status in
            guard let self, let document, self.madeDocument === document else { return }
            self.fellBack = document.fellBack
            self.status = status
            self.updateSymbol()
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

    override func makeContent() -> AnyView { AnyView(FileTabContent(tab: self)) }
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
            // Not to be read: what was read goes, and the view with it, and
            // what was known of the file: read again from the start if it
            // may be read again.
            finder?.close(); finder = nil; bar = .none
            madeDocument?.close(); madeDocument = nil
            madeScroll = nil
            status = .indexing; fellBack = false
        }
        updateHelp(); updateSymbol()
    }
    override func willClose() {
        finder?.close(); finder = nil
        madeDocument?.close()
        madeDocument = nil; madeScroll = nil
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

/// A file tab's content: its header over its text, or what it shows instead.
struct FileTabContent: View {
    @ObservedObject var tab: FileTab
    var body: some View {
        VStack(spacing: 0) {
            FileTabHeader(tab: tab)
            if let reason = tab.missingReason {
                FileTabNotice(symbol: "questionmark.folder", title: "Missing", detail: reason, url: tab.url)
            } else if tab.status == .binary {
                FileTabNotice(symbol: "doc", title: "Not text", detail: FileTabNotice.describe(tab.url), url: tab.url)
            } else if let scroll = tab.scroll {
                switch tab.bar {
                case .find: FileFindBar(tab: tab)
                case .goToLine: FileGoToLineBar(tab: tab)
                case .none: EmptyView()
                }
                FileTextHost(view: scroll)
            }
        }
        .background(Color.piContent)
    }
}

/// A file's find bar, under its header: the query, where the match shown is
/// among them all, match case, previous and next, and close.
private struct FileFindBar: View {
    @ObservedObject var tab: FileTab
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: PiSpacing.sm) {
            FileBarField(symbol: "magnifyingglass", placeholder: "Find in file", text: $tab.findQuery, focused: $focused, identifier: "file-find-field") {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { tab.findPrevious() } else { tab.findNext() }
            }
            Text(tab.findLabel).font(PiFont.caption).monospacedDigit().foregroundStyle(Color.piInkSecondary).lineLimit(1)
                .accessibilityIdentifier("file-find-count")
            Spacer(minLength: 0)
            PiIconButton(symbol: "textformat", label: tab.matchCase ? "Match Case: On" : "Match Case: Off", tone: tab.matchCase ? .accent : .neutral, size: 24, filled: tab.matchCase) {
                tab.matchCase.toggle()
            }
            .accessibilityIdentifier("file-find-match-case")
            Button { tab.findPrevious() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.piGhost).disabled(!tab.canStep).help("Previous match").accessibilityLabel("Previous match")
            Button { tab.findNext() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.piGhost).disabled(!tab.canStep).help("Next match").accessibilityLabel("Next match")
            PiIconButton(symbol: "xmark", label: "Close Find", size: 24) { tab.closeBar() }
        }
        .padding(.horizontal, PiSpacing.md).frame(height: 36)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.piHairline).frame(height: 1) }
        .onExitCommand { tab.closeBar() }
        .onAppear { focused = true }
        .onChange(of: tab.barFocus) { _, _ in focused = true }
        .accessibilityIdentifier("file-find-bar")
    }
}

/// A file's go-to-line bar, where the find bar would be.
private struct FileGoToLineBar: View {
    @ObservedObject var tab: FileTab
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: PiSpacing.sm) {
            FileBarField(symbol: "arrow.right.to.line", placeholder: "Go to line", text: $tab.lineQuery, focused: $focused, identifier: "file-go-to-line-field") {
                tab.goToLine()
            }
            Text(tab.lineRange).font(PiFont.caption).monospacedDigit().foregroundStyle(Color.piInkSecondary).lineLimit(1)
            Spacer(minLength: 0)
            PiIconButton(symbol: "xmark", label: "Close", size: 24) { tab.closeBar() }
        }
        .padding(.horizontal, PiSpacing.md).frame(height: 36)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.piHairline).frame(height: 1) }
        .onExitCommand { tab.closeBar() }
        .onAppear { focused = true }
        .onChange(of: tab.barFocus) { _, _ in focused = true }
        .accessibilityIdentifier("file-go-to-line-bar")
    }
}

/// A bar's field: as the inspector's search field is drawn.
private struct FileBarField: View {
    let symbol: String
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let identifier: String
    let submit: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.piInkTertiary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(PiFont.caption)
                .focused(focused).onSubmit(submit).accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(focused.wrappedValue ? Color.piAccent.opacity(0.5) : Color.piHairline, lineWidth: 1))
        .frame(maxWidth: 280)
    }
}

private struct FileTabHeader: View {
    @ObservedObject var tab: FileTab
    var body: some View {
        HStack(spacing: PiSpacing.sm) {
            path
            status
            Spacer(minLength: PiSpacing.sm)
            PiIconButton(symbol: "arrow.up.forward.app", label: "Open in \(Self.appName(for: tab.url))", size: 26) {
                NSWorkspace.shared.open(tab.url)
            }
            .accessibilityIdentifier("file-open-in-app")
        }
        .padding(.horizontal, PiSpacing.md).frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.piHairline).frame(height: 1) }
    }
    private var path: some View {
        let (project, rest) = shownPath
        return HStack(spacing: 4) {
            if let project {
                Text(project).font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInkSecondary).lineLimit(1).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
            }
            Text(rest).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.head)
        }
        .help(tab.help)
        .accessibilityElement(children: .combine)
    }
    /// The project's name and the path within it, or the path from home.
    private var shownPath: (String?, String) {
        let path = tab.url.path
        switch tab.project {
        case .trusted(let name, let root):
            let root = root.hasSuffix("/") ? String(root.dropLast()) : root
            if path.hasPrefix(root + "/") { return (name, String(path.dropFirst(root.count + 1))) }
            return (name, Self.abbreviated(path))
        case .untrusted(let name): return (name, Self.abbreviated(path))
        case .none, .removed: return (nil, Self.abbreviated(path))
        }
    }
    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    @ViewBuilder private var status: some View {
        if tab.missingReason != nil {
            PiBadge(text: "Missing", tone: .danger, icon: "exclamationmark.triangle").fixedSize()
        } else {
            switch tab.status {
            case .indexing: PiBadge(text: "Reading…", icon: "hourglass").fixedSize()
            case .ready: if tab.fellBack { PiBadge(text: "Latin-1", tone: .warning, icon: "textformat").fixedSize().help("Not valid UTF-8: shown a byte a character") }
            case .binary: PiBadge(text: "Not text", icon: "doc").fixedSize()
            case .changed: PiBadge(text: "Changed on disk", tone: .warning, icon: "arrow.triangle.2.circlepath").fixedSize().help("Shown as it was when opened")
            case .truncated(let limit): PiBadge(text: "First \(limit.formatted()) lines", tone: .warning, icon: "scissors").fixedSize()
            case .failed: EmptyView()
            }
        }
    }
    /// The app a file opens in, for the button that opens it there.
    static func appName(for url: URL) -> String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "Default App" }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// What a file tab shows in place of text: a file that is missing, or not text.
private struct FileTabNotice: View {
    let symbol: String
    let title: String
    let detail: String
    let url: URL
    var body: some View {
        VStack(spacing: PiSpacing.md) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Color.piInkTertiary)
            Text(title).font(PiFont.heading).foregroundStyle(Color.piInk)
            Text(detail).font(PiFont.body).foregroundStyle(Color.piInkSecondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            if FileManager.default.fileExists(atPath: url.path) {
                Button("Open in \(FileTabHeader.appName(for: url))") { NSWorkspace.shared.open(url) }
            }
        }
        .padding(PiSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
    /// A binary file: its size and its type.
    static func describe(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .localizedTypeDescriptionKey])
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [values?.localizedTypeDescription, size].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A file's kept scroll view, in a container of this representable's own.
struct FileTextHost: NSViewRepresentable {
    let view: FileTextScrollView
    func makeNSView(context: Context) -> TabContentContainerPlain {
        let container = TabContentContainerPlain()
        container.place(view)
        return container
    }
    func updateNSView(_ container: TabContentContainerPlain, context: Context) { if view.superview !== container { container.place(view) } }
    static func dismantleNSView(_ container: TabContentContainerPlain, coordinator: ()) {
        for subview in container.subviews { subview.removeFromSuperview() }
    }
}
final class TabContentContainerPlain: NSView {
    func place(_ content: NSView) {
        content.removeFromSuperview()
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
}
