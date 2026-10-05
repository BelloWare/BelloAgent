import AppKit

enum WorkspaceLabel {
    static func name(_ workspace: WorkspaceRecord) -> String { URL(fileURLWithPath: workspace.path).lastPathComponent }
    static func folders(_ count: Int) -> String { count == 1 ? "1 folder" : "\(count) folders" }
    static func chats(_ count: Int) -> String { count == 1 ? "1 chat" : "\(count) chats" }
}

/// A one-point hairline in the hairline color.
@MainActor final class ShellHairline: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piHairline) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One folder line: path, primary marker and an optional remove action.
@MainActor final class WorkspaceFolderRowView: NSView, PiKit.WidthSizing {
    let path: String
    let removeButton: PiKit.IconButton?
    private let stack: ShellStack
    init(path: String, primary: Bool = false, remove: (() -> Void)? = nil) {
        self.path = path
        let icon = PiKit.SymbolView(PiKit.Symbol(primary ? "house" : "folder", size: 11, weight: .medium), color: primary ? .piAccent : .piInkSecondary)
        let text = ShellSelectableText(path, font: PiKit.Font.mono, color: .piInk, singleLine: true, truncation: .byTruncatingMiddle)
        text.toolTip = path
        var items: [ShellItem] = [.view(icon, .fixed(14)), .view(text, .flexible), .spacer(4)]
        if primary { items.append(.view(PiKit.Badge(text: "Primary", tone: .accent))) }
        removeButton = remove.map { PiKit.IconButton(symbol: "xmark", label: "Remove folder", size: 22, action: $0) }
        if let removeButton { items.append(.view(removeButton)) }
        stack = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: 6, left: PiSpacing.md, bottom: 6, right: PiSpacing.md), items)
        super.init(frame: .zero)
        addSubview(stack)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 400)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() { super.layout(); stack.frame = bounds }
}

/// Folder rows in their rounded inset, one under another with a hairline
/// between, kept by path so a row stays put while others come and go.
@MainActor final class WorkspaceFolderStack: NSView, PiKit.WidthSizing {
    private let column = ShellStack(.vertical, spacing: 0)
    private lazy var box = PiKit.inset(column)
    private var rows: [String: WorkspaceFolderRowView] = [:]
    private var lines: [String: ShellHairline] = [:]
    private var head: NSView?
    private var shownPaths: [String]?
    /// While rows come and go, the height eases from the old to the new over
    /// 0.2 s, a step a frame, and everything around lays out with it, as the
    /// SwiftUI stack's animated frame did.
    private let easing = ShellEasing(duration: WorkspaceFolderStack.easingDuration)
    /// The height is on its way somewhere (a test seam).
    var isEasing: Bool { easing.active }
    private static let easingDuration: CFTimeInterval = 0.2
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(box)
        easing.tick = { [weak self] in guard let self else { return }; self.invalidateIntrinsicContentSize(); self.needsLayout = true; PiKit.sizeChanged(self) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    /// The first line (a primary folder or what stands for it), then the
    /// extra folders, each made once; new ones arrive from above.
    func update(head: NSView, headKey: String, extras: [String], remove: @escaping (String) -> Void) {
        let paths = ["head:" + headKey] + extras
        guard paths != shownPaths || head !== self.head else { return }
        let old = Set(shownPaths ?? [])
        let animate = shownPaths != nil && window != nil && !piReducesMotion
        shownPaths = paths; self.head = head
        var items: [ShellItem] = [.view(head, .fill)]
        var arrived: [NSView] = []
        if animate, !old.contains(paths[0]) { arrived.append(head) }
        for path in extras {
            let line = lines[path] ?? ShellHairline()
            lines[path] = line
            let row = rows[path] ?? WorkspaceFolderRowView(path: path) { remove(path) }
            rows[path] = row
            if animate, !old.contains(path) { arrived.append(row) }
            items.append(.view(line, .fill, insets: NSEdgeInsets(top: 0, left: PiSpacing.md, bottom: 0, right: 0)))
            items.append(.view(row, .fill))
        }
        // Leaving rows go up and out over 0.2 s, and the rows under them
        // glide up into their place (`.transition(.move(edge: .top).combined(with: .opacity))`).
        var leaving: [NSView] = []
        for path in rows.keys where !extras.contains(path) {
            if animate, let row = rows[path], row.superview === column { leaving.append(row); if let line = lines[path] { leaving.append(line) } }
            rows[path] = nil; lines[path] = nil
        }
        let before = animate ? Dictionary(uniqueKeysWithValues: column.subviews.map { (ObjectIdentifier($0), $0.frame) }) : [:]
        let oldHeight = bounds.height
        column.items = items
        if animate, oldHeight > 0 { easing.begin(from: oldHeight, target: column.height(forWidth: bounds.width)) }
        PiKit.sizeChanged(self)
        needsLayout = true
        guard animate else { return }
        for view in leaving { column.addSubview(view) }
        layoutSubtreeIfNeeded()
        // Every track on one 0.2-second ease-in-ease-out: arrivals come down
        // from above and in, rows glide, leavers rise and fade, the inset eases.
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        for view in arrived {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            let drop = CABasicAnimation(keyPath: "position.y")
            let height = view.frame.height
            drop.fromValue = layer.position.y + (column.layer?.isGeometryFlipped == true ? -height : height); drop.toValue = layer.position.y
            let group = CAAnimationGroup(); group.animations = [fade, drop]
            group.duration = Self.easingDuration; group.timingFunction = timing; group.fillMode = .backwards
            layer.add(group, forKey: "arrive")
        }
        for item in items {
            guard let view = item.view, let from = before[ObjectIdentifier(view)], from.origin != view.frame.origin, let layer = view.layer else { continue }
            let glide = CABasicAnimation(keyPath: "position.y")
            // The column's layer runs top down when AppKit flips it with the view.
            let delta = from.minY - view.frame.minY
            glide.fromValue = layer.position.y + (column.layer?.isGeometryFlipped == true ? delta : -delta)
            glide.toValue = layer.position.y
            glide.duration = 0.2; glide.timingFunction = timing
            layer.add(glide, forKey: "glide")
        }
        for view in leaving {
            view.wantsLayer = true
            guard let layer = view.layer else { view.removeFromSuperview(); continue }
            CATransaction.begin()
            // Gone when its exit ends: on the animation's completion, or on
            // the clock if the window is not drawing to complete it.
            CATransaction.setCompletionBlock { [weak view] in view?.removeFromSuperview() }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.easingDuration + 0.05) { [weak self, weak view] in
                guard let view, let self, !self.rows.values.contains(where: { $0 === view }) else { return }
                view.removeFromSuperview()
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0
            // Up by its own height as it goes (`.move(edge: .top)`).
            let rise = CABasicAnimation(keyPath: "position.y")
            let height = view.frame.height
            rise.fromValue = layer.position.y; rise.toValue = layer.position.y + (column.layer?.isGeometryFlipped == true ? -height : height)
            let group = CAAnimationGroup(); group.animations = [fade, rise]
            group.duration = Self.easingDuration; group.timingFunction = timing
            group.fillMode = .forwards; group.isRemovedOnCompletion = false
            layer.add(group, forKey: "leave")
            CATransaction.commit()
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let target = column.height(forWidth: width)
        return easing.active ? PiKit.round(easing.value(target: target), piScale) : target
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 400)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    /// The rows keep their own heights while the inset eases around them.
    override func layout() { super.layout(); box.frame = bounds }
}

/// Primary and extra folders of a saved workspace with add/remove actions.
/// Shared by the manager sheet and onboarding.
@MainActor final class WorkspaceFolderListView: NSView, PiKit.WidthSizing, PiKit.SizeObserver {
    let model: WorkspaceModel
    let workspaceID: String
    var onError: (String) -> Void
    let addFolders = PiKit.Button("Add Folders…", symbol: "folder.badge.plus", style: .secondary, compact: true)
    private let folders = WorkspaceFolderStack()
    private let spinner = PiKit.spinner(controlSize: .mini)
    private let status = PiKit.TextLine()
    private let column: ShellStack
    private let actions: ShellStack
    private var observer: ShellObserver!
    private var busy = false { didSet { refresh() } }
    private var primaryRow: WorkspaceFolderRowView?
    private var shown: [String]?
    /// The window's disabled state (`.disabled` on the SwiftUI around it).
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { shown = nil; refresh() } } }

    init(model: WorkspaceModel, workspaceID: String, onError: @escaping (String) -> Void = { _ in }) {
        self.model = model; self.workspaceID = workspaceID; self.onError = onError
        actions = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(addFolders), .view(spinner), .view(status, .flexible), .spacer(0)])
        column = ShellStack(.vertical, spacing: PiSpacing.sm, [.view(folders, .fill), .view(actions, .fill)])
        super.init(frame: .zero)
        addSubview(column)
        addFolders.onPress = { [weak self] in
            guard let self else { return }
            let model = self.model, id = self.workspaceID
            self.perform { try await model.addFoldersInteractively(to: id) }
        }
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(model)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func contentSizeChanged() { invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self) }

    private var workspace: WorkspaceRecord? { model.workspaces.first { $0.id == workspaceID } }
    func refresh() {
        guard let workspace else { return }
        let active = model.workspaceHasActiveWork(workspace.id)
        let key = [workspace.path] + workspace.paths + ["\(active)", "\(busy)", "\(inheritedEnabled)", "\(workspace.roots.count)"]
        guard key != shown else { return }
        let animate = shown != nil && window != nil && !piReducesMotion
        shown = key
        if primaryRow?.path != workspace.path { primaryRow = WorkspaceFolderRowView(path: workspace.path, primary: true) }
        let model = self.model, id = workspace.id
        folders.update(head: primaryRow!, headKey: workspace.path, extras: workspace.paths) { [weak self] folder in
            self?.perform { try await model.removeFolder(folder, from: id) }
        }
        let enabled = inheritedEnabled && !busy
        addFolders.isEnabled = enabled && !active && workspace.roots.count < WorkspaceModel.maximumRoots
        for row in folders.subviewsOfType(WorkspaceFolderRowView.self) { row.removeButton?.isEnabled = inheritedEnabled }
        spinner.isHidden = !busy
        let text = active ? "Stop this project's work before changing folders." : "\(WorkspaceLabel.folders(workspace.roots.count)) · Changes reopen the host on the next message"
        let line = PiKit.Line(text, font: PiKit.Font.caption, color: active ? .piWarning : .piInkTertiary)
        if status.line.text != line.text || status.line.color != line.color {
            status.line = line
            if animate { PiKit.fadeIn(status) }
        }
        actions.relayoutAll(); column.relayoutAll()
        PiKit.sizeChanged(self)
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { [weak self] in
            do { try await work() } catch { self?.onError(error.localizedDescription) }
            self?.busy = false
        }
    }
    func height(forWidth width: CGFloat) -> CGFloat { column.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 500)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() { super.layout(); column.frame = bounds }
}

extension NSView {
    /// Every view of type `T` in this view's tree.
    @MainActor func subviewsOfType<T: NSView>(_ type: T.Type = T.self) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + subviews.flatMap { $0.subviewsOfType(type) }
    }
}

extension PiKit {
    /// A short fade in, as `.animation(.easeInOut(duration: 0.18))` on a change.
    @MainActor static func fadeIn(_ view: NSView, duration: CFTimeInterval = 0.18) {
        guard let layer = view.layer, !view.piReducesMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "fade-in")
    }
}

/// What a new project will be: its primary folder and the extra ones.
struct NewWorkspaceDraft: Equatable {
    var primary: String?
    var extras: [String] = []

    /// The draft as an editor reads and writes it: live state on every read,
    /// and no write once the draft is gone (an outgoing pane must not reopen
    /// a cancelled one).
    @MainActor struct Editing {
        let get: () -> NewWorkspaceDraft?
        let set: (NewWorkspaceDraft) -> Void
        let initial: NewWorkspaceDraft
        var wrappedValue: NewWorkspaceDraft {
            get { get() ?? initial }
            nonmutating set { if get() != nil { self.set(newValue) } }
        }
    }
    @MainActor static func editing(get: @escaping () -> NewWorkspaceDraft?, set: @escaping (NewWorkspaceDraft?) -> Void) -> Editing? {
        guard let initial = get() else { return nil }
        return Editing(get: get, set: { set($0) }, initial: initial)
    }

    mutating func selectPrimary(_ folder: String) {
        primary = folder
        extras.removeAll { $0 == folder }
    }
}

/// "Projects" sheet: every workspace with its folders and chat count, plus creation and removal.
@MainActor final class WorkspaceManagerSheetView: NSView, InheritsEnabled {
    static let size = NSSize(width: 780, height: 540)
    let model: WorkspaceModel
    private let dismiss: () -> Void
    private(set) var selection: String?
    private(set) var draft: NewWorkspaceDraft?
    private var busy = false { didSet { if oldValue != busy { refresh() } } }
    /// Remove Project asked once; the section shows the question until Remove or Keep.
    private(set) var confirmingRemove: String?
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { refresh() } } }

    let newProject = PiKit.Button("New Project…", symbol: "plus", style: .primary, compact: true)
    let done = PiKit.Button("Done", style: .secondary)
    private let status = ShellNote("")
    private let sheet: PiKit.Sheet
    private let footer: WorkspaceManagerFooter
    private let split = WorkspaceManagerSplit()
    private let list = WorkspaceManagerList()
    /// The pane on the right: a project's detail, the new-project form, or the placeholder.
    private let paneHolder = WorkspaceManagerPaneHolder()
    private var detail: WorkspaceManagerDetail?
    private var newPane: NewWorkspacePaneView?
    private lazy var placeholder = WorkspaceManagerPlaceholder()
    private var observer: ShellObserver!
    private var workspaceIDs: [String] = []

    init(model: WorkspaceModel, dismiss: @escaping () -> Void) {
        self.model = model; self.dismiss = dismiss
        footer = WorkspaceManagerFooter(status: status, done: done)
        split.list = list; split.pane = paneHolder
        sheet = PiKit.Sheet("Projects", subtitle: "Every chat belongs to one project. The primary folder is the working directory; extra folders are read, searched and edited by the same tools.",
                            symbol: "folder.badge.gearshape", content: split, actions: [newProject], footer: footer)
        sheet.width = Self.size.width; sheet.height = Self.size.height
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        addSubview(sheet)
        status.isHidden = true
        sheet.dismiss = { [weak self] in self?.dismiss() }
        done.onPress = { [weak self] in self?.dismiss() }
        newProject.onPress = { [weak self] in self?.startDraft() }
        list.choose = { [weak self] id in self?.select(id) }
        // `.onAppear`: the current project, or a new one when there is none.
        selection = model.selectedWorkspaceID ?? model.workspaces.first?.id
        if model.workspaces.isEmpty { draft = NewWorkspaceDraft() }
        workspaceIDs = model.workspaces.map(\.id)
        observer = ShellObserver { [weak self] in self?.modelChanged() }
        observer.observe(model)
        refresh(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }
    override func layout() { super.layout(); sheet.frame = bounds }

    // MARK: State

    private func modelChanged() {
        let ids = model.workspaces.map(\.id)
        if ids != workspaceIDs {
            workspaceIDs = ids
            // `.onChange(of: workspaces)`: a removed selection moves to the first.
            if let selection, !ids.contains(selection) { self.selection = ids.first; confirmingRemove = nil }
        }
        refresh()
    }
    func select(_ id: String) {
        let changed = selection != id
        draft = nil; selection = id
        if changed { confirmingRemove = nil }
        refresh()
    }
    private func startDraft() {
        guard draft == nil, !busy else { return }
        draft = NewWorkspaceDraft(); status.text = ""; status.isHidden = true; footer.changed()
        refresh()
    }
    private func report(_ text: String, _ tone: PiTone) {
        status.text = text; status.tone = tone; status.isHidden = text.isEmpty
        footer.changed()
        PiKit.fadeIn(status)
    }

    private func refresh(animated: Bool = true) {
        let enabled = inheritedEnabled
        newProject.isEnabled = draft == nil && !busy && enabled
        done.isEnabled = enabled
        sheet.cancelDisabled = !enabled
        list.update(model: model, selection: selection, washed: draft == nil, enabled: enabled)
        // One pane at a time over the other while they cross.
        let next: NSView
        if draft != nil {
            if newPane == nil {
                newPane = NewWorkspacePaneView(model: model, draft: { [weak self] in self?.draft }, setDraft: { [weak self] in self?.draft = $0; self?.refresh() },
                                               busy: { [weak self] in self?.busy ?? false }, setBusy: { [weak self] in self?.busy = $0 },
                                               cancel: { [weak self] in self?.draft = nil; self?.refresh() },
                                               created: { [weak self] id in self?.draft = nil; self?.selection = id; self?.refresh(); self?.report("Project created.", .success) },
                                               failed: { [weak self] in self?.report($0, .danger) })
            }
            newPane!.inheritedEnabled = enabled
            newPane!.refresh()
            next = newPane!
        } else if let selection, model.workspaces.contains(where: { $0.id == selection }) {
            newPane = nil
            if detail?.workspaceID != selection {
                detail = WorkspaceManagerDetail(model: model, workspaceID: selection,
                                                confirm: { [weak self] in self?.confirmingRemove = $0; self?.refresh() },
                                                remove: { [weak self] in self?.remove($0) },
                                                report: { [weak self] in self?.report($0, $1) })
            }
            detail!.update(confirming: confirmingRemove == selection, busy: busy, enabled: enabled)
            next = detail!
        } else {
            newPane = nil
            next = placeholder
        }
        paneHolder.show(next, slidesFromTrailing: next === newPane, animated: animated)
    }

    private func remove(_ id: String) {
        confirmingRemove = nil
        busy = true
        let model = self.model
        Task { [weak self] in
            do { try await model.removeWorkspace(id); self?.report("Project removed.", .success) }
            catch { self?.report(error.localizedDescription, .danger) }
            self?.busy = false
        }
    }
}

/// The sheet's footer: what the last action said, wrapping short of Done
/// (`HStack(spacing: md) { PiStatusLine; Spacer(); Done }`).
@MainActor final class WorkspaceManagerFooter: NSView {
    let status: ShellNote
    let done: NSView
    init(status: ShellNote, done: NSView) {
        self.status = status; self.done = done
        super.init(frame: .zero)
        addSubview(status); addSubview(done)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    /// Room for the status: all but Done, the stack's two gaps and the spacer's least length.
    private func statusWidth(_ width: CGFloat) -> CGFloat { max(0, width - done.intrinsicContentSize.width - PiSpacing.md * 2 - 8) }
    private func statusHeight(_ width: CGFloat) -> CGFloat { status.isHidden ? 0 : status.height(forWidth: min(status.naturalWidth, statusWidth(width))) }
    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 0 ? bounds.width : WorkspaceManagerSheetView.size.width - 2 * PiSpacing.xl
        return NSSize(width: NSView.noIntrinsicMetric, height: max(done.intrinsicContentSize.height, statusHeight(width)))
    }
    func changed() { invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self) }
    override func setFrameSize(_ newSize: NSSize) { let changed = newSize.width != frame.width; super.setFrameSize(newSize); if changed { self.changed() } }
    override func layout() {
        super.layout()
        let size = done.intrinsicContentSize
        done.frame = CGRect(x: bounds.width - size.width, y: PiKit.round((bounds.height - size.height) / 2, piScale), width: size.width, height: size.height)
        let width = min(status.naturalWidth, statusWidth(bounds.width)), height = statusHeight(bounds.width)
        status.frame = CGRect(x: 0, y: PiKit.round((bounds.height - height) / 2, piScale), width: width, height: height)
    }
}

/// The list beside the hairline beside the pane (`HStack { list.frame(width: 250); Rectangle(width: 1); pane }`).
@MainActor final class WorkspaceManagerSplit: NSView {
    var list: NSView? { didSet { oldValue?.removeFromSuperview(); if let list { addSubview(list) } } }
    var pane: NSView? { didSet { oldValue?.removeFromSuperview(); if let pane { addSubview(pane) } } }
    private let line = ShellHairline()
    override init(frame: NSRect) { super.init(frame: frame); addSubview(line) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        list?.frame = CGRect(x: 0, y: 0, width: 250, height: bounds.height)
        line.frame = CGRect(x: 250, y: 0, width: 1, height: bounds.height)
        pane?.frame = CGRect(x: 251, y: 0, width: max(0, bounds.width - 251), height: bounds.height)
    }
}

/// The right-hand pane's holder: the arriving pane fades (or slides from
/// the trailing edge) in over the leaving one, in one place.
@MainActor final class WorkspaceManagerPaneHolder: NSView {
    private(set) var current: NSView?
    private var leaving: [NSView] = []
    override var isFlipped: Bool { true }
    func show(_ view: NSView, slidesFromTrailing: Bool, animated: Bool) {
        guard view !== current else { return }
        let old = current, oldSlides = old is NewWorkspacePaneView
        current = view
        // A pane coming back (the detail after Cancel) arrives whole, with
        // nothing left of the way it went.
        leaving.removeAll { $0 === view }
        view.layer?.removeAnimation(forKey: "pane-fade"); view.layer?.removeAnimation(forKey: "pane-move")
        view.alphaValue = 1
        view.frame = bounds
        addSubview(view)
        view.layoutSubtreeIfNeeded()
        let animate = animated && window != nil && !piReducesMotion
        guard let old else { return }
        guard animate else { old.removeFromSuperview(); return }
        leaving.append(old)
        let duration: CFTimeInterval = 0.2
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak old] in
            guard let self, let old, old !== self.current else { return }
            old.removeFromSuperview(); self.leaving.removeAll { $0 === old }
        }
        Self.move(view, appearing: true, slides: slidesFromTrailing, width: bounds.width, duration: duration)
        Self.move(old, appearing: false, slides: oldSlides, width: bounds.width, duration: duration)
        old.alphaValue = 0
        CATransaction.commit()
    }
    private static func move(_ view: NSView, appearing: Bool, slides: Bool, width: CGFloat, duration: CFTimeInterval) {
        guard let layer = view.layer else { return }
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = appearing ? 0 : 1; fade.toValue = appearing ? 1 : 0
        fade.duration = duration; fade.timingFunction = timing
        layer.add(fade, forKey: "pane-fade")
        if slides {
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = appearing ? width : 0; move.toValue = appearing ? 0 : width
            move.duration = duration; move.timingFunction = timing
            move.fillMode = .forwards; move.isRemovedOnCompletion = appearing
            layer.add(move, forKey: "pane-move")
        }
    }
    override func layout() {
        super.layout()
        current?.frame = bounds
        for view in leaving { view.frame = bounds }
    }
}

/// No project chosen: a folder and a line in the middle.
@MainActor final class WorkspaceManagerPlaceholder: NSView {
    private let column = ShellStack(.vertical, spacing: 8, alignment: .center, [
        .view(PiKit.SymbolView(PiKit.Symbol("folder", size: 26), color: .piInkTertiary)),
        .view(PiKit.TextLine(PiKit.Line("Select a project or create one.", font: PiKit.Font.body, color: .piInkSecondary))),
    ])
    override init(frame: NSRect) { super.init(frame: frame); addSubview(column) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let size = CGSize(width: column.intrinsicContentSize.width, height: column.height(forWidth: bounds.width))
        column.frame = CGRect(x: PiKit.round((bounds.width - size.width) / 2, piScale), y: PiKit.round((bounds.height - size.height) / 2, piScale),
                              width: size.width, height: size.height)
    }
}

/// The projects down the left: a count, then a row for each with its chats,
/// its folders and, while its host runs, a dot.
@MainActor final class WorkspaceManagerList: NSView {
    var choose: ((String) -> Void)?
    private let heading = PiKit.TextLine()
    private let scroll = NSScrollView()
    private var clipWatcher: ShellClipWatcher?
    private let document = FlippedDocument()
    private let stack = ShellStack(.vertical, spacing: 1, padding: NSEdgeInsets(top: 0, left: PiSpacing.sm, bottom: 0, right: PiSpacing.sm))
    private var rows: [String: (row: PiKit.SelectableRow, content: WorkspaceManagerRowContent)] = [:]
    private lazy var empty = ShellStack(.vertical, spacing: 8, alignment: .center, padding: NSEdgeInsets(top: PiSpacing.lg, left: PiSpacing.lg, bottom: PiSpacing.lg, right: PiSpacing.lg), [
        .view(PiKit.SymbolView(PiKit.Symbol("folder.badge.plus", size: 22), color: .piInkTertiary)),
        .view(PiKit.TextLine(PiKit.Line("No projects yet.", font: PiKit.Font.caption, color: .piInkSecondary))),
    ])
    private var order: [String] = []
    private var shown: [String]?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.documentView = document
        clipWatcher = ShellClipWatcher(scroll, owner: self)
        document.addSubview(stack)
        addSubview(heading); addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piWindow) }

    /// `selection` is the chosen project (its accent icon and semibold name);
    /// `washed` whether its row is highlighted, which a new project's form takes away.
    func update(model: WorkspaceModel, selection: String?, washed: Bool, enabled: Bool) {
        let workspaces = model.workspaces
        // What the list shows; a model change that leaves it alone lays nothing out.
        let key = workspaces.map { workspace -> String in
            let host = model.hosts[workspace.id]?.isReady == true ? (model.workspaceHasActiveWork(workspace.id) ? "busy" : "idle") : "none"
            return [workspace.id, workspace.path, workspace.trusted ? "t" : "u", workspace.paths.joined(separator: "|"),
                    "\(model.chatCount(workspaceID: workspace.id))", host].joined(separator: "\u{1}")
        } + [selection ?? "", "\(washed)", "\(enabled)"]
        guard key != shown else { return }
        shown = key
        heading.line = PiKit.Line(workspaces.isEmpty ? "Projects" : "Projects · \(workspaces.count)", font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.5, uppercased: true)
        let ids = workspaces.map(\.id)
        for workspace in workspaces {
            let entry = rows[workspace.id] ?? {
                let content = WorkspaceManagerRowContent()
                let id = workspace.id
                let row = PiKit.SelectableRow(content: content, action: { [weak self] in self?.choose?(id) })
                return (row, content)
            }()
            rows[workspace.id] = entry
            let host = model.hosts[workspace.id]?.isReady == true
            entry.content.update(workspace: workspace, chats: model.chatCount(workspaceID: workspace.id), selected: selection == workspace.id,
                                 host: host ? (model.workspaceHasActiveWork(workspace.id) ? .busy : .idle) : nil)
            entry.row.selected = washed && selection == workspace.id
            entry.row.setAccessibilityLabel(entry.content.spoken)
            if entry.row.isEnabled != enabled { entry.row.isEnabled = enabled }
        }
        for id in rows.keys where !ids.contains(id) { rows[id] = nil }
        if ids != order {
            order = ids
            stack.items = ids.compactMap { rows[$0].map { .view($0.row, .fill) } }
        }
        stack.relayoutAll()
        if workspaces.isEmpty { if empty.superview == nil { addSubview(empty) } } else { empty.removeFromSuperview() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = heading.intrinsicContentSize
        // `.padding(.horizontal, lg).padding(.top, md).padding(.bottom, 4)`
        heading.frame = CGRect(x: PiSpacing.lg, y: PiSpacing.md, width: min(size.width, bounds.width - 2 * PiSpacing.lg), height: size.height)
        let top = PiSpacing.md + size.height + 4
        scroll.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        scroll.shellFit(document) { stack.height(forWidth: $0) }
        stack.frame = document.bounds
        if empty.superview != nil {
            let emptySize = CGSize(width: empty.intrinsicContentSize.width, height: empty.height(forWidth: bounds.width))
            empty.frame = CGRect(x: PiKit.round((bounds.width - emptySize.width) / 2, piScale), y: top + PiKit.round((scroll.frame.height - emptySize.height) / 2, piScale),
                                 width: emptySize.width, height: emptySize.height)
        }
    }
}

/// A project row's words: its folder, name and extra-folder count, chats and folders, and the host's dot.
@MainActor final class WorkspaceManagerRowContent: NSView, PiKit.WidthSizing {
    enum Host: Equatable { case idle, busy }
    private let icon = PiKit.SymbolView(PiKit.Symbol("folder.fill", size: 12, weight: .medium), color: .piInkSecondary)
    private let name = PiKit.TextLine()
    private let extra = PiKit.TextLine()
    private let detail = PiKit.TextLine()
    private let dot = WorkspaceHostDot()
    private let nameRow: ShellStack
    private let words: ShellStack
    private let stack: ShellStack
    private var shown: [String]?
    override init(frame: NSRect) {
        nameRow = ShellStack(.horizontal, spacing: 5, [.view(name, .flexible), .view(extra)])
        words = ShellStack(.vertical, spacing: 2, alignment: .leading, [.view(nameRow, .flexible), .view(detail, .flexible)])
        stack = ShellStack(.horizontal, spacing: 8, [.view(icon, .fixed(16)), .view(words, .flexible), .spacer(0), .view(dot)])
        super.init(frame: frame)
        addSubview(stack)
        dot.toolTip = "Host running"
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(workspace: WorkspaceRecord, chats: Int, selected: Bool, host: Host?) {
        let key = [workspace.path, workspace.trusted ? "t" : "u", "\(workspace.paths.count)", "\(workspace.roots.count)", "\(chats)", "\(selected)", "\(String(describing: host))"]
        guard key != shown else { return }
        shown = key
        icon.symbol = PiKit.Symbol(workspace.trusted ? "folder.fill" : "folder.badge.questionmark", size: 12, weight: .medium)
        icon.color = selected ? .piAccent : .piInkSecondary
        name.line = PiKit.Line(WorkspaceLabel.name(workspace), font: .systemFont(ofSize: 13, weight: selected ? .semibold : .regular), color: .piInk)
        extra.isHidden = workspace.paths.isEmpty
        extra.line = PiKit.Line("+\(workspace.paths.count)", font: PiKit.Font.micro, color: .piAccent)
        detail.line = PiKit.Line(WorkspaceLabel.chats(chats) + " · " + WorkspaceLabel.folders(workspace.roots.count), font: PiKit.Font.caption, color: .piInkTertiary)
        dot.isHidden = host == nil
        dot.busy = host == .busy
        stack.relayoutAll()
        PiKit.sizeChanged(self)
    }
    /// What VoiceOver reads: the shown words only.
    var spoken: String {
        ([name.line.text] + (extra.isHidden ? [] : [extra.line.text]) + [detail.line.text] + (dot.isHidden ? [] : ["Host running"])).joined(separator: ", ")
    }
    func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 210)) }
    override var fittingSize: NSSize { NSSize(width: bounds.width, height: height(forWidth: bounds.width > 0 ? bounds.width : 210)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() { super.layout(); stack.frame = bounds }
}

/// A 6-point dot: green while the host idles, amber while it works.
@MainActor final class WorkspaceHostDot: NSView {
    var busy = false { didSet { if oldValue != busy { needsDisplay = true } } }
    override var intrinsicContentSize: NSSize { NSSize(width: 6, height: 6) }
    override func draw(_ dirtyRect: NSRect) {
        (busy ? NSColor.piWarning : NSColor.piSuccess).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// A project's detail: name and badges, its folders, and removal.
@MainActor final class WorkspaceManagerDetail: NSView {
    let model: WorkspaceModel
    let workspaceID: String
    private let confirm: (String?) -> Void
    private let remove: (String) -> Void
    private let scroll = NSScrollView()
    private var clipWatcher: ShellClipWatcher?
    private let document = FlippedDocument()
    private let column = ShellStack(.vertical, spacing: PiSpacing.lg, padding: NSEdgeInsets(top: PiSpacing.xl, left: PiSpacing.xl, bottom: PiSpacing.xl, right: PiSpacing.xl))
    private let title = PiKit.TextLine()
    private let chatsBadge = PiKit.Badge(text: "", icon: "bubble.left")
    private let working = PiKit.Badge(text: "Working", tone: .warning, dot: true)
    let switchButton = PiKit.Button("Switch to It", style: .ghost)
    private let current = PiKit.Badge(text: "Current", tone: .accent)
    private let header: ShellStack
    private let foldersHeader = PiKit.SectionHeader("Folders", subtitle: "Tools resolve relative paths against the primary folder; skills and instructions are discovered in every folder.")
    let folders: WorkspaceFolderListView
    private let removeHeader = PiKit.SectionHeader("Remove", subtitle: "")
    let removeButton = PiKit.Button("Remove Project…", symbol: "trash", style: .danger)
    private let question = ShellText("", font: PiKit.Font.caption, color: .piDanger)
    let keep = PiKit.Button("Keep", style: .secondary, compact: true)
    let confirmRemove = PiKit.Button("Remove Project", symbol: "trash", style: .danger)
    private let confirmRow: ShellStack
    private let removeSection = ShellStack(.vertical, spacing: PiSpacing.sm)
    private var confirming = false
    private var shown: [String]?

    init(model: WorkspaceModel, workspaceID: String, confirm: @escaping (String?) -> Void, remove: @escaping (String) -> Void,
         report: @escaping (String, PiTone) -> Void) {
        self.model = model; self.workspaceID = workspaceID; self.confirm = confirm; self.remove = remove
        folders = WorkspaceFolderListView(model: model, workspaceID: workspaceID, onError: { report($0, .danger) })
        header = ShellStack(.horizontal, spacing: PiSpacing.sm, alignment: .firstBaseline,
                            [.view(title, .flexible), .view(chatsBadge), .view(working), .spacer(8), .view(switchButton), .view(current)])
        confirmRow = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(question, .flexible), .view(keep), .view(confirmRemove)])
        super.init(frame: .zero)
        scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.documentView = document
        clipWatcher = ShellClipWatcher(scroll, owner: self)
        document.addSubview(column)
        addSubview(scroll)
        let folderSection = ShellStack(.vertical, spacing: PiSpacing.sm, [.view(foldersHeader, .fill), .view(folders, .fill)])
        column.items = [.view(header, .fill), .view(folderSection, .fill), .view(removeSection, .fill)]
        removeButton.setAccessibilityIdentifier("workspace-remove")
        confirmRemove.setAccessibilityIdentifier("workspace-confirm-remove")
        switchButton.onPress = { [weak self] in guard let self else { return }; self.model.selectedWorkspaceID = self.workspaceID }
        removeButton.onPress = { [weak self] in guard let self else { return }; self.confirm(self.workspaceID) }
        keep.onPress = { [weak self] in self?.confirm(nil) }
        confirmRemove.onPress = { [weak self] in guard let self else { return }; self.remove(self.workspaceID) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func update(confirming: Bool, busy: Bool, enabled: Bool) {
        guard let workspace = model.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let chats = model.chatCount(workspaceID: workspace.id)
        let hasTopics = !model.topics(in: workspace.id).isEmpty
        let key = [workspace.path, "\(chats)", "\(hasTopics)", "\(model.workspaceHasActiveWork(workspace.id))",
                   "\(model.selectedWorkspaceID == workspace.id)", "\(confirming)", "\(busy)", "\(enabled)"]
        // The folder list watches the model itself; this shows only what changed here.
        folders.inheritedEnabled = enabled
        guard key != shown else { return }
        shown = key
        title.line = PiKit.Line(WorkspaceLabel.name(workspace), font: PiKit.Font.title(17), color: .piInk)
        chatsBadge.text = WorkspaceLabel.chats(chats)
        working.isHidden = !model.workspaceHasActiveWork(workspace.id)
        let isCurrent = model.selectedWorkspaceID == workspace.id
        switchButton.isHidden = isCurrent; current.isHidden = !isCurrent
        switchButton.isEnabled = enabled
        removeHeader.setSubtitle(chats > 0 ? "Delete its \(WorkspaceLabel.chats(chats)) first; a project with chats cannot be removed."
            : hasTopics ? "Remove this project's topics first. Removing a topic keeps its chats."
            : "Forget this project. Its folders on disk stay untouched.")
        question.set("Remove “\(WorkspaceLabel.name(workspace))”? Bello Agent forgets this project and its folder trust. Nothing on disk is deleted.", color: .piDanger)
        removeButton.isEnabled = chats == 0 && !hasTopics && !busy && enabled
        keep.isEnabled = enabled; confirmRemove.isEnabled = !busy && enabled
        let arriving = confirming != self.confirming && window != nil
        self.confirming = confirming
        removeSection.items = [.view(removeHeader, .fill), confirming ? .view(confirmRow, .fill) : .view(removeButton)]
        if arriving { PiKit.fadeIn(confirming ? confirmRow : removeButton) }
        header.relayoutAll(); column.relayoutAll()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = scroll.shellFit(document, fill: true) { column.height(forWidth: $0) }
        column.frame = CGRect(x: 0, y: 0, width: width, height: column.height(forWidth: width))
    }
}

/// Create flow: choose a primary folder, optional extras, then trust and save.
@MainActor final class NewWorkspacePaneView: NSView, PiKit.SizeObserver {
    let model: WorkspaceModel
    private let editing: NewWorkspaceDraft.Editing?
    private let busy: () -> Bool
    private let setBusy: (Bool) -> Void
    private let cancel: () -> Void
    private let created: (String) -> Void
    private let failed: (String) -> Void
    private let scroll = NSScrollView()
    private var clipWatcher: ShellClipWatcher?
    private let document = FlippedDocument()
    private let column = ShellStack(.vertical, spacing: PiSpacing.lg, padding: NSEdgeInsets(top: PiSpacing.xl, left: PiSpacing.xl, bottom: PiSpacing.xl, right: PiSpacing.xl))
    private let header = PiKit.SectionHeader("New project", subtitle: "Pick the primary folder first. Add more folders when a task spans several repositories.")
    private let folders = WorkspaceFolderStack()
    private let noPrimary = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: 8, left: PiSpacing.md, bottom: 8, right: PiSpacing.md), [
        .view(PiKit.SymbolView(PiKit.Symbol("house", size: 11, weight: .medium), color: .piInkTertiary), .fixed(14)),
        .view(PiKit.TextLine(PiKit.Line("No primary folder chosen", font: PiKit.Font.caption, color: .piInkTertiary)), .flexible), .spacer(8),
    ])
    private var primaryRow: WorkspaceFolderRowView?
    let choosePrimary = PiKit.Button("Choose Primary Folder…", symbol: "house", style: .secondary, compact: true)
    let addExtras = PiKit.Button("Add Folders…", symbol: "folder.badge.plus", style: .secondary, compact: true)
    private let count = PiKit.TextLine()
    private let existing = ShellNote("This folder is already a project. Creating it again replaces its extra folders.", tone: .warning)
    private let trust = ShellNote("Editing chats can read files, run shell commands and change files in these folders with your account's permissions. Read-only chats expose only local read and search tools.")
    let cancelButton = PiKit.Button("Cancel", style: .ghost)
    let create = PiKit.Button("Create Project", symbol: "checkmark", style: .primary)
    private let buttons: ShellStack
    private let actions: ShellStack
    var inheritedEnabled = true

    init(model: WorkspaceModel, draft: @escaping () -> NewWorkspaceDraft?, setDraft: @escaping (NewWorkspaceDraft?) -> Void,
         busy: @escaping () -> Bool, setBusy: @escaping (Bool) -> Void,
         cancel: @escaping () -> Void, created: @escaping (String) -> Void, failed: @escaping (String) -> Void) {
        self.model = model; self.editing = NewWorkspaceDraft.editing(get: draft, set: setDraft)
        self.busy = busy; self.setBusy = setBusy; self.cancel = cancel; self.created = created; self.failed = failed
        actions = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(choosePrimary), .view(addExtras), .spacer(8), .view(count)])
        buttons = ShellStack(.horizontal, spacing: 8, [.view(cancelButton), .spacer(8), .view(create)])
        super.init(frame: .zero)
        scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.documentView = document
        clipWatcher = ShellClipWatcher(scroll, owner: self)
        document.addSubview(column)
        addSubview(scroll)
        choosePrimary.onPress = { [weak self] in self?.pickPrimary() }
        addExtras.onPress = { [weak self] in self?.pickExtras() }
        cancelButton.onPress = { [weak self] in self?.cancel() }
        create.onPress = { [weak self] in self?.save() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func contentSizeChanged() { needsLayout = true }

    private var draft: NewWorkspaceDraft { editing?.wrappedValue ?? NewWorkspaceDraft() }
    private var roots: [String] { (draft.primary.map { [$0] } ?? []) + draft.extras }

    private var shown: [String]?
    func refresh() {
        let draft = self.draft, busy = self.busy(), enabled = inheritedEnabled && !busy
        let exists = draft.primary.map { path in model.workspaces.contains { $0.path == path } } ?? false
        let key = [draft.primary ?? "\u{0}"] + draft.extras + ["\(busy)", "\(enabled)", "\(exists)"]
        guard key != shown else { return }
        shown = key
        let head: NSView
        if let primary = draft.primary {
            if primaryRow?.path != primary { primaryRow = WorkspaceFolderRowView(path: primary, primary: true) }
            head = primaryRow!
        } else { head = noPrimary }
        folders.update(head: head, headKey: draft.primary ?? "", extras: draft.extras) { [weak self] folder in
            guard let self, let editing = self.editing else { return }
            editing.wrappedValue.extras.removeAll { $0 == folder }
            self.refresh()
        }
        for row in folders.subviewsOfType(WorkspaceFolderRowView.self) { row.removeButton?.isEnabled = enabled }
        choosePrimary.title = draft.primary == nil ? "Choose Primary Folder…" : "Change Primary…"
        choosePrimary.isEnabled = enabled
        addExtras.isEnabled = enabled && draft.primary != nil && roots.count < WorkspaceModel.maximumRoots
        count.line = PiKit.Line(WorkspaceLabel.folders(roots.count), font: PiKit.Font.caption, color: .piInkTertiary)
        cancelButton.isEnabled = enabled
        create.title = busy ? "Creating…" : "Create Project"
        create.isEnabled = enabled && draft.primary != nil
        var items: [ShellItem] = [.view(header, .fill), .view(folders, .fill), .view(actions, .fill)]
        if exists { items.append(.view(existing, .fill)) }
        items.append(.view(trust, .fill))
        items.append(.view(buttons, .fill))
        column.items = items
        actions.relayoutAll(); buttons.relayoutAll(); column.relayoutAll()
        needsLayout = true
    }
    private func pickPrimary() {
        Task { [weak self] in
            guard let folder = await WorkspaceModel.chooseFolders(message: "Choose the primary working directory for this project.", multiple: false).first,
                  let self, let editing = self.editing else { return }
            editing.wrappedValue.selectPrimary(folder)
            self.refresh()
        }
    }
    private func pickExtras() {
        Task { [weak self] in
            let picked = await WorkspaceModel.chooseFolders(message: "Choose additional folders for this project.", multiple: true)
            guard let self, let editing = self.editing else { return }
            let roots = self.roots
            let added = picked.filter { !roots.contains($0) }
            guard !added.isEmpty else { return }
            editing.wrappedValue.extras += added
            self.refresh()
        }
    }
    private func save() {
        guard let primary = draft.primary, !busy() else { return }
        do { try WorkspaceModel.validateRoots(roots) } catch { failed(error.localizedDescription); return }
        let extras = draft.extras, model = self.model
        // The sheet's, not this pane's: the pane may have gone (another project
        // chosen) before the project is made, and busy must still end.
        let setBusy = self.setBusy, created = self.created, failed = self.failed
        setBusy(true)
        Task {
            do { let workspace = try await model.createWorkspace(primary: primary, extras: extras); setBusy(false); created(workspace.id) }
            catch { setBusy(false); failed(error.localizedDescription) }
        }
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = scroll.shellFit(document, fill: true) { column.height(forWidth: $0) }
        column.frame = CGRect(x: 0, y: 0, width: width, height: column.height(forWidth: width))
    }
}
