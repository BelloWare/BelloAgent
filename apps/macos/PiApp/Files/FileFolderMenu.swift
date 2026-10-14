import AppKit
import FileFinder

/// Pi menu entries shown in the app's popover surface. Submenus use a Back
/// row, keeping async loading and long names usable in a narrow file pane.
/// A submenu's children are read only after the reader enters it.
@MainActor final class FileFolderMenu: NSView, PiKit.WidthSizing {
    let browser: FolderBrowser
    private(set) var entries: [PiMenuEntry] = []
    private var buttons: [FileFolderMenuRow] = []
    private var rowViews: [NSView] = []
    private var stack: [URL] = []
    private let ancestors: [FileBreadcrumb]
    private let projectRoot: URL?
    private let open: (URL) -> Void
    private let showTree: (URL) -> Void
    private var focusedIndex = 0
    init(crumb: FileBreadcrumb, projectRoot: URL?, open: @escaping (URL) -> Void, showTree: @escaping (URL) -> Void,
         browser: FolderBrowser = FolderBrowser()) {
        self.browser = browser; self.ancestors = crumb.ancestors; self.projectRoot = projectRoot
        self.open = open; self.showTree = showTree
        super.init(frame: .zero)
        setAccessibilityLabel("Folder contents")
        browser.changed = { [weak self] in self?.rebuild() }
        if ancestors.isEmpty { enter(crumb.isDirectory ? crumb.url : crumb.url.deletingLastPathComponent()) }
        else { rebuild() }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { CGFloat(rowViews.count) * 28 + 12 }
    func enter(_ folder: URL) {
        stack.append(folder); focusedIndex = 0
        browser.showFolder(folder, relativeTo: projectRoot); rebuild()
    }
    func back() {
        guard stack.count > 1 || (!stack.isEmpty && !ancestors.isEmpty) else { return }
        stack.removeLast(); focusedIndex = 0
        if let folder = stack.last { browser.showFolder(folder, relativeTo: projectRoot) }
        else { browser.stop(); rebuild() }
    }
    private func rebuild() {
        let focused = (window?.firstResponder as? FileFolderMenuRow).flatMap {
            $0.isDescendant(of: self) ? $0.accessibilityIdentifier() : nil
        }
        entries = []
        if stack.count > 1 || (!stack.isEmpty && !ancestors.isEmpty) {
            entries.append(.button("Back", systemImage: "chevron.left", identifier: "folder-menu-back") { [weak self] in self?.back() })
        }
        if let folder = stack.last {
            entries += [.note(folder.lastPathComponent.isEmpty ? "/" : folder.lastPathComponent),
                .button("Show in Folder Tree", systemImage: "list.bullet.indent", identifier: "folder-menu-show-tree") { [weak self] in self?.showTree(folder) },
                .button("Reveal in Finder", systemImage: "arrow.up.forward.app", identifier: "folder-menu-reveal") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }, .separator]
            if let error = browser.failure(folder) {
                entries += [.note(error), .button("Try Again", systemImage: "arrow.clockwise", identifier: "folder-menu-retry") { [weak self] in self?.browser.showFolder(folder, relativeTo: self?.projectRoot) }]
            } else if let snapshot = browser.snapshot(folder) {
                for entry in browser.visibleEntries(in: folder) {
                    if entry.isDirectory {
                        entries.append(.submenu(title: entry.name, systemImage: "folder", identifier: entry.url.path, help: entry.url.path, entries: []))
                    } else {
                        entries.append(.button(entry.name, systemImage: FileTab.symbol(for: entry.url), identifier: entry.url.path, help: entry.url.path) { [weak self] in self?.open(entry.url) })
                    }
                }
                let count = browser.remaining(in: folder)
                if count > 0 { entries.append(.button("Show \(min(browser.pageSize, count)) more", systemImage: "ellipsis", identifier: "folder-menu-more") { [weak self] in self?.browser.showMore(in: folder) }) }
                if snapshot.entries.isEmpty { entries.append(.note("Empty folder")) }
                if let warning = snapshot.warning { entries.append(.note(warning)) }
            } else { entries.append(.note("Loading…")) }
        } else {
            entries = [.note("Parent folders")] + ancestors.map { .submenu(title: $0.title, systemImage: "folder", identifier: $0.url.path, help: $0.url.path, entries: []) }
        }
        rowViews.forEach { $0.removeFromSuperview() }; rowViews = []; buttons = []
        let dimmed = Set(stack.last.map { browser.visibleEntries(in: $0).filter(\.isDimmed).map { $0.url.path } } ?? [])
        for entry in entries {
            let row: NSView
            switch entry {
            case .item(let command):
                let button = FileFolderMenuRow(title: command.title, symbol: command.systemImage, submenu: false)
                button.isEnabled = command.enabled; button.dimmed = dimmed.contains(command.identifier ?? "")
                button.setAccessibilityIdentifier(command.identifier ?? ""); button.toolTip = command.help
                button.onPress = command.perform; buttons.append(button); row = button
            case .submenu(let title, let image, let identifier, let help, _):
                let button = FileFolderMenuRow(title: title, symbol: image, submenu: true)
                button.dimmed = dimmed.contains(identifier ?? ""); button.toolTip = help
                button.setAccessibilityIdentifier(identifier ?? "")
                button.onPress = { [weak self] in if let identifier { self?.enter(URL(fileURLWithPath: identifier, isDirectory: false)) } }
                buttons.append(button); row = button
            case .separator: row = HairlineView()
            case .note(let text):
                row = PiKit.TextLine(PiKit.Line(text, font: PiKit.Font.caption, color: .piInkTertiary)); row.toolTip = text
            }
            addSubview(row); rowViews.append(row)
        }
        for button in buttons { button.navigate = { [weak self] code in self?.navigate(code) ?? false } }
        needsLayout = true; PiKit.sizeChanged(self)
        if let focused, let next = buttons.first(where: { $0.accessibilityIdentifier() == focused }) ?? buttons.first {
            window?.makeFirstResponder(next)
        }
    }
    private func navigate(_ code: UInt16) -> Bool {
        guard !buttons.isEmpty else { return false }
        if let current = window?.firstResponder as? FileFolderMenuRow, let index = buttons.firstIndex(of: current) { focusedIndex = index }
        switch code {
        case 125: focusedIndex = min(buttons.count - 1, focusedIndex + 1)
        case 126: focusedIndex = max(0, focusedIndex - 1)
        case 123: back(); focusedIndex = 0
        case 124:
            guard buttons[min(focusedIndex, buttons.count - 1)].submenu else { return true }
            buttons[min(focusedIndex, buttons.count - 1)].performClick(nil); focusedIndex = 0
        case 36, 76:
            let button = buttons[min(focusedIndex, buttons.count - 1)]
            button.performClick(nil)
            // Normal actions such as Show More may rebuild in place and
            // have already restored focus by identifier. Keep that focus.
            if !button.submenu { return true }
            focusedIndex = 0
        default: return false
        }
        if !buttons.isEmpty { window?.makeFirstResponder(buttons[min(focusedIndex, buttons.count - 1)]) }
        return true
    }
    override func layout() {
        super.layout()
        for (index, row) in rowViews.enumerated() {
            row.frame = CGRect(x: 8, y: 6 + CGFloat(index) * 28 + (row is HairlineView ? 13 : 0), width: max(0, bounds.width - 16), height: row is HairlineView ? 1 : 28)
        }
    }
}

@MainActor private final class FileFolderMenuRow: PiKit.ButtonBase {
    let label: String, symbol: String?
    let submenu: Bool
    var dimmed = false
    var navigate: ((UInt16) -> Bool)?
    init(title: String, symbol: String?, submenu: Bool) {
        label = title; self.symbol = symbol; self.submenu = submenu
        super.init(frame: .zero)
        pressScales = false; setAccessibilityLabel(title)
        if submenu { setAccessibilityRole(.menuButton); setAccessibilityHelp("Open folder submenu") }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func cornerRadius(for size: CGSize) -> CGFloat { 5 }
    override func styleFace() { fill.backgroundColor = piCGColor(hovering || isPressedDown ? NSColor.piInk.withAlphaComponent(0.06) : .clear); stroke.borderColor = NSColor.clear.cgColor }
    override func keyDown(with event: NSEvent) { if navigate?(event.keyCode) != true { super.keyDown(with: event) } }
    override func drawContent(in rect: CGRect) {
        let ink: NSColor = dimmed ? .piInkTertiary : .piInk
        if let symbol { PiKit.Symbol(symbol, size: 12).draw(centredIn: CGRect(x: 8, y: 7, width: 14, height: 14), color: ink) }
        PiKit.Line(label, font: PiKit.Font.caption, color: ink).draw(in: CGRect(x: 30, y: 7, width: max(0, rect.width - 50), height: 16))
        if submenu { PiKit.Symbol("chevron.right", size: 9).draw(centredIn: CGRect(x: rect.width - 16, y: 9, width: 8, height: 10), color: .piInkTertiary) }
    }
}
