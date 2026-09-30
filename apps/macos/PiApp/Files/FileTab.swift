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
    static func key(for url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

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
            madeDocument?.close(); madeDocument = nil
            madeScroll = nil
            status = .indexing; fellBack = false
        }
        updateHelp(); updateSymbol()
    }
    override func willClose() {
        madeDocument?.close()
        madeDocument = nil; madeScroll = nil
    }

    private func updateHelp() {
        switch project {
        case .trusted(let name, _), .untrusted(let name): help = "\(url.path)\nIn \(name)"
        case .none, .removed: help = url.path
        }
    }
    private func updateSymbol() { symbol = missingReason == nil ? Self.symbol(for: url) : "exclamationmark.triangle" }

    static func symbol(for url: URL) -> String {
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
                FileTextHost(view: scroll)
            }
        }
        .background(Color.piContent)
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
