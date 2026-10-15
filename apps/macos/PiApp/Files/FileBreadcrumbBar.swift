import AppKit
import FileFinder

@MainActor final class FileBreadcrumbBar: NSView {
    private weak var tab: FileTab?
    private var crumbs: [FileBreadcrumb] = []
    private var shown: [FileBreadcrumb] = []
    private var buttons: [FileCrumbButton] = []
    init(tab: FileTab) { self.tab = tab; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func refresh() {
        guard let tab else { return }
        let project: (String, URL)?
        if case .trusted(let name, _) = tab.project, let root = tab.folders.projectRoot { project = (name, root) }
        else { project = nil }
        crumbs = FileBreadcrumb.path(to: tab.url, project: project)
        toolTip = tab.help; needsLayout = true
    }
    override func layout() {
        super.layout()
        var next = FileBreadcrumb.collapsed(crumbs, width: bounds.width, measure: { PiKit.Line($0, font: PiKit.Font.caption, color: .piInkSecondary).width + 10 })
        if bounds.width < 100, next.count > 2, let last = next.last {
            var overflow = next[1]
            overflow.ancestors = Array(crumbs.dropLast())
            next = [overflow, last]
        }
        if next != shown {
            buttons.forEach { $0.removeFromSuperview() }; buttons = []; shown = next
            for crumb in next {
                let button = FileCrumbButton(crumb: crumb)
                button.onPress = { [weak self, weak button] in guard let self, let button else { return }; self.tab?.folders.showMenu(crumb, from: button) }
                buttons.append(button); addSubview(button)
            }
        }
        let separators = CGFloat(max(0, buttons.count - 1)) * 12
        var remaining = max(0, bounds.width - separators), x: CGFloat = 0
        for (index, button) in buttons.enumerated() {
            let count = buttons.count - index
            let ideal = button.intrinsicContentSize.width
            let width = index == buttons.count - 1 ? remaining : min(ideal, max(18, remaining / CGFloat(count)))
            button.frame = CGRect(x: x, y: 3, width: max(0, min(width, remaining)), height: 26)
            remaining = max(0, remaining - width); x += width + 12
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        for button in buttons.dropLast() { PiKit.Symbol("chevron.right", size: 8).draw(centredIn: CGRect(x: button.frame.maxX + 2, y: 12, width: 8, height: 8), color: .piInkTertiary) }
    }
}

@MainActor private final class FileCrumbButton: PiKit.ButtonBase {
    let crumb: FileBreadcrumb
    init(crumb: FileBreadcrumb) {
        self.crumb = crumb; super.init(frame: .zero); pressScales = false
        setAccessibilityIdentifier("file-crumb-" + (crumb.ancestors.isEmpty ? crumb.url.path : "ancestors"))
        setAccessibilityLabel(crumb.ancestors.isEmpty ? crumb.title + (crumb.isDirectory ? ", folder" : ", file") : "Hidden parent folders")
        setAccessibilityHelp("Browse folder contents"); toolTip = crumb.url.path
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: PiKit.Line(crumb.title, font: PiKit.Font.caption, color: .piInkSecondary).width + 10, height: 26) }
    override func cornerRadius(for size: CGSize) -> CGFloat { 5 }
    override func styleFace() { fill.backgroundColor = piCGColor(hovering || isPressedDown ? NSColor.piInk.withAlphaComponent(0.06) : .clear); stroke.borderColor = NSColor.clear.cgColor }
    override func drawContent(in rect: CGRect) {
        PiKit.Line(crumb.title, font: PiKit.Font.caption, color: hovering ? .piInk : .piInkSecondary)
            .draw(in: CGRect(x: 5, y: 6, width: max(0, rect.width - 10), height: 16), truncation: .start)
    }
}
