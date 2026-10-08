import AppKit
import QuartzCore

/// The scroll view's document: the list's entries laid out top to bottom,
/// with views only for those near the visible part; the drop target for
/// chats dragged within a project.
@MainActor final class SidebarListDocument: NSView {
    private let model: WorkspaceModel
    let glide = PiKit.SelectionGlide()
    private(set) var contents = SidebarListContents()
    private var frames: [CGRect] = []
    /// Heights measured for entries without views, with what they were measured for.
    private var heights: [String: (entry: SidebarEntry, width: CGFloat, height: CGFloat)] = [:]
    /// The entries that have views now, by entry id.
    private(set) var views: [String: NSView] = [:]
    private var leaving: [NSView] = []
    /// The list's own padding: eight points at the sides, twelve under the last entry.
    static let padding = NSEdgeInsets(top: 0, left: PiSpacing.sm, bottom: PiSpacing.md, right: PiSpacing.sm)
    /// How far past the visible part entries keep their views.
    static let overscan: CGFloat = 600

    // What the list's owner handles.
    var setProjectExpanded: ((String, Bool) -> Void)?
    var setTopicExpanded: ((String, Bool) -> Void)?
    var confirmRemove: ((String) -> Void)?
    var cancelRemove: ((String) -> Void)?
    var removeTopic: ((String) -> Void)?
    var setShownRoots: ((String, Int, String) -> Void)?
    var setSideFolded: ((String, Bool) -> Void)?
    /// Where a drag over the list would drop, for the headers' highlight.
    var dropTargetChanged: (((project: String, topic: String?)?) -> Void)?

    init(model: WorkspaceModel) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([NSPasteboard.PasteboardType(TopicSessionDrag.type.identifier)])
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    // MARK: Contents

    /// Takes new contents; `animated` lets rows glide to their new places,
    /// new ones come out from under the one above and gone ones go back.
    func update(_ new: SidebarListContents, width: CGFloat, animated: Bool) {
        let oldFrames = Dictionary(zip(contents.entries.map(\.id), frames), uniquingKeysWith: { a, _ in a })
        contents = new
        // Views that stay take their new values first, so they are measured as they will be.
        updatingViews = true
        for entry in new.entries { if let view = views[entry.id] { update(view, with: entry) } }
        updatingViews = false
        layoutEntries(width: width)
        // Entries whose views stay take the new values; views of entries
        // that went are let go of (with motion, when it moves).
        let ids = Set(new.entries.map(\.id))
        for (id, view) in views where !ids.contains(id) {
            views[id] = nil
            if animated, window != nil, !PiKit.Motion.reduced, let frame = oldFrames[id] {
                leaving.append(view)
                Self.reveal(view, from: frame, arriving: false) { [weak self, weak view] in
                    view?.removeFromSuperview(); self?.leaving.removeAll { $0 === view }
                }
            } else { view.removeFromSuperview() }
        }
        materialize(animated: animated, oldFrames: oldFrames)
    }

    /// Something inside an entry changed its height: lay the list out again.
    /// Entry views report a height change while the list is updating them
    /// too; the update lays the list out once at its end.
    func entryChangedHeight() {
        guard !updatingViews else { return }
        // The entry has a view, which is what its height is read from.
        layoutEntries(width: bounds.width)
        materialize(animated: false, oldFrames: [:])
    }
    private var updatingViews = false

    private func height(of entry: SidebarEntry, width: CGFloat) -> CGFloat {
        let inner = width - Self.padding.left - Self.padding.right
        if case .nothing = entry { return 0 }
        if let view = views[entry.id] as? SidebarEntryView {
            // Kept for when the view goes: its height may have moved on screen.
            let height = view.entryHeight(width: inner)
            heights[entry.id] = (entry, inner, height)
            return height
        }
        // An entry without a view yet is measured with a fresh one, once.
        if let known = heights[entry.id], known.width == inner, known.entry == entry { return known.height }
        let height = measure(entry, width: inner)
        heights[entry.id] = (entry, inner, height)
        return height
    }
    /// An entry's height without building its view: rows are measured on one
    /// shared row body, headers once per kind; only the rare small entries
    /// are built to be measured.
    private let measuringBody = ChatRowBodyView()
    private lazy var measuringRow = PiKit.SelectableRow(content: measuringBody)
    private var headerHeights: [String: CGFloat] = [:]
    private func measure(_ entry: SidebarEntry, width: CGFloat) -> CGFloat {
        switch entry {
        case .chat(let chat, let state, _):
            measuringBody.update(SidebarChatRowView.content(model: model, chat: chat, state: state,
                                                            display: SidebarChatRowView.liveDisplay(model: model, chatID: chat.id, state: state), retained: nil))
            return measuringRow.height(forWidth: max(0, width - state.indent))
        case .side(let state):
            measuringBody.update(SidebarSideRowView.content(model: model, state: state))
            return measuringRow.height(forWidth: max(0, width - state.indent))
        case .searchSnippet(let state):
            return SidebarSearchSnippetView.height(of: state, width: width)
        case .projectHeader, .topicHeader:
            let kind = entry.id.hasPrefix("project|") ? "project" : "topic"
            if let known = headerHeights[kind] { return known }
            let height = (makeView(entry) as? SidebarEntryView)?.entryHeight(width: width) ?? 0
            headerHeights[kind] = height
            return height
        default:
            return (makeView(entry) as? SidebarEntryView)?.entryHeight(width: width) ?? 0
        }
    }
    private func layoutEntries(width: CGFloat) {
        var y = Self.padding.top
        frames = []
        frames.reserveCapacity(contents.entries.count)
        let inner = width - Self.padding.left - Self.padding.right
        for (index, entry) in contents.entries.enumerated() {
            y += contents.gaps[index]
            let height = height(of: entry, width: width)
            frames.append(CGRect(x: Self.padding.left, y: y, width: inner, height: height))
            y += height
        }
        let total = y + Self.padding.bottom
        if frame.height != total || frame.width != width { setFrameSize(NSSize(width: width, height: total)) }
    }

    /// Gives every entry near the visible part a view, in its place.
    func materialize(animated: Bool = false, oldFrames: [String: CGRect] = [:]) {
        let visible = visibleRect.insetBy(dx: 0, dy: -Self.overscan)
        var wanted = Set<String>()
        // A height measured while the entry had no view can be out of date by
        // the time it gets one (its figures moved off screen).
        var stale = false
        var corrected: [(id: String, entry: SidebarEntry, height: CGFloat)] = []
        for (index, entry) in contents.entries.enumerated() where frames[index].intersects(visible) || frames[index].height == 0 && visible.contains(frames[index].origin) {
            let id = entry.id
            wanted.insert(id)
            let frame = frames[index]
            if let view = views[id] {
                if view.frame != frame {
                    let from = view.frame
                    view.frame = frame
                    if animated, window != nil, !PiKit.Motion.reduced, from.minY != frame.minY { Self.glide(view, from: from, to: frame) }
                }
            } else {
                let view = makeView(entry)
                if !inheritedEnabled { Self.disable(view) }
                view.frame = frame
                addSubview(view)
                views[id] = view
                if let measured = (view as? SidebarEntryView)?.entryHeight(width: frame.width), measured != frame.height {
                    stale = true; corrected.append((id, entry, measured))
                }
                if animated, window != nil, !PiKit.Motion.reduced {
                    if let from = oldFrames[id], from.minY != frame.minY { Self.glide(view, from: from, to: frame) }
                    else if oldFrames[id] == nil { Self.reveal(view, from: frame, arriving: true) }
                }
            }
        }
        // Far from the visible part: no view.
        for (id, view) in views where !wanted.contains(id) { view.removeFromSuperview(); views[id] = nil }
        // Kept for when the view goes again; laid out until nothing moves
        // (a corrected entry can bring others into range), a few passes at most.
        for item in corrected { heights[item.id] = (item.entry, bounds.width - Self.padding.left - Self.padding.right, item.height) }
        if stale, remeasuringPasses < 4 {
            remeasuringPasses += 1; defer { remeasuringPasses -= 1 }
            layoutEntries(width: bounds.width)
            materialize(animated: false)
        }
    }
    private var remeasuringPasses = 0

    /// Whether the window around the list lets it be used (`.disabled` on
    /// the SwiftUI around it, while an install is being prepared).
    var inheritedEnabled = true {
        didSet {
            guard inheritedEnabled != oldValue else { return }
            // Views take their own enabled states again when built afresh.
            for view in views.values { view.removeFromSuperview() }
            views.removeAll()
            materialize()
        }
    }
    private static func disable(_ view: NSView) {
        if let control = view as? NSControl { control.isEnabled = false }
        for child in view.subviews { disable(child) }
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize) }

    // MARK: Entry views

    private func makeView(_ entry: SidebarEntry) -> NSView {
        switch entry {
        case .projectHeader(let state):
            let view = ProjectHeaderEntry(model: model, state: state)
            view.header.setExpanded = { [weak self] in self?.setProjectExpanded?(state.projectID, $0) }
            return view
        case .projectUnavailable:
            return SidebarNoteView(text: "Project unavailable · History only", leading: 23, vertical: 3)
        case .topicHeader(let state):
            let view = TopicHeaderEntry(model: model, state: state)
            view.header.setExpanded = { [weak self] in self?.setTopicExpanded?(state.topicID, $0) }
            view.header.confirmRemove = { [weak self] in self?.confirmRemove?(state.topicID) }
            return view
        case .topicRemove(let topicID, let removing):
            let view = SidebarTopicRemoveView()
            view.update(removing: removing)
            view.remove.onPress = { [weak self] in self?.removeTopic?(topicID) }
            view.cancel.onPress = { [weak self] in self?.cancelRemove?(topicID) }
            return view
        case .archiveHeading(let groupID, let count, let indent):
            return SidebarArchiveHeadingView(groupID: groupID, count: count, indent: indent)
        case .chat(let chat, let state, let projectID):
            return SidebarChatRowView(model: model, chat: chat, state: state, projectID: projectID, glide: glide)
        case .side(let state):
            return SidebarSideRowView(model: model, state: state, glide: glide)
        case .searchSnippet(let state):
            let view = SidebarSearchSnippetView(state: state)
            let model = self.model, id = state.chatID
            view.open = { Task { await model.openFromSidebar(id) } }
            return view
        case .pagination(let groupID, let projectID, let hidden, let shown, let indent):
            let view = SidebarPaginationView(groupID: groupID)
            view.update(hiddenRoots: hidden, shownRoots: shown, indent: indent)
            view.showMore = { [weak self, weak view] in
                guard let self, let view, let entry = self.entry(for: view), case .pagination(_, _, let hidden, let shown, _) = entry else { return }
                self.setShownRoots?(groupID, shown + SidebarSessionPresentation.pageSize * 2, projectID); _ = hidden
            }
            view.showLess = { [weak self] in self?.setShownRoots?(groupID, SidebarSessionPresentation.pageSize, projectID) }
            return view
        case .empty(_, let text, let indent):
            return SidebarNoteView(text: text, leading: indent + 20, vertical: 6)
        case .nothing:
            return NSView()
        }
    }
    private func entry(for view: NSView) -> SidebarEntry? {
        guard let id = views.first(where: { $0.value === view })?.key else { return nil }
        return contents.entries.first { $0.id == id }
    }
    private func update(_ view: NSView, with entry: SidebarEntry) {
        defer { if !inheritedEnabled { Self.disable(view) } }
        switch entry {
        case .projectHeader(let state): (view as? ProjectHeaderEntry)?.header.update(state)
        case .topicHeader(let state): (view as? TopicHeaderEntry)?.header.update(state)
        case .topicRemove(_, let removing): (view as? SidebarTopicRemoveView)?.update(removing: removing)
        case .archiveHeading(_, let count, let indent): (view as? SidebarArchiveHeadingView)?.update(count: count, indent: indent)
        case .chat(let chat, let state, let projectID): (view as? SidebarChatRowView)?.apply(chat: chat, state: state, projectID: projectID)
        case .side(let state): (view as? SidebarSideRowView)?.apply(state)
        case .searchSnippet(let state): (view as? SidebarSearchSnippetView)?.apply(state)
        case .pagination(_, _, let hidden, let shown, let indent): (view as? SidebarPaginationView)?.update(hiddenRoots: hidden, shownRoots: shown, indent: indent)
        case .empty(_, let text, let indent): (view as? SidebarNoteView)?.update(text: text, leading: indent + 20)
        case .projectUnavailable, .nothing: break
        }
    }

    // MARK: Motion

    /// A row that moved glides from where it was (`PiKit.Motion.glide`).
    private static func glide(_ view: NSView, from: CGRect, to: CGRect) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let spring = PiKit.Motion.glide("transform.translation.y")
        spring.fromValue = from.minY - to.minY; spring.toValue = 0
        layer.add(spring, forKey: "glide")
    }
    /// A row coming out from under the one above, or going back
    /// (`.move(edge: .top).combined(with: .opacity)`), on the glide spring.
    private static func reveal(_ view: NSView, from frame: CGRect, arriving: Bool, done: (() -> Void)? = nil) {
        view.wantsLayer = true
        guard let layer = view.layer else { done?(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { done?() }
        let move = PiKit.Motion.glide("transform.translation.y")
        move.fromValue = arriving ? -frame.height : 0; move.toValue = arriving ? 0 : -frame.height
        let fade = PiKit.Motion.glide("opacity")
        fade.fromValue = arriving ? 0 : 1; fade.toValue = arriving ? 1 : 0
        let group = CAAnimationGroup()
        group.animations = [move, fade]; group.duration = move.duration
        if !arriving { group.fillMode = .forwards; group.isRemovedOnCompletion = false }
        layer.add(group, forKey: "reveal")
        CATransaction.commit()
    }

    /// Where the entry `id` sits in the list, views or not.
    func frame(of id: String) -> CGRect? {
        contents.entries.firstIndex { $0.id == id }.map { frames[$0] }
    }

    // MARK: Dropping chats

    /// What a drag over `point` would do: move the chats before or after a
    /// row it is over, or into the topic or project whose area it is in.
    enum DropTarget: Equatable {
        case row(id: String, projectID: String, after: Bool)
        case group(projectID: String, topicID: String?)
    }
    func dropTarget(at point: CGPoint) -> DropTarget? {
        guard let index = frames.firstIndex(where: { $0.minY <= point.y && point.y < $0.maxY + SidebarListContents.rowSpacing }) else {
            return projectArea(at: point)
        }
        // Over the row itself, not the indent beside it: that is the group's.
        if case .chat(let chat, let state, let projectID) = contents.entries[index], state.draggable,
           point.x >= frames[index].minX + state.indent, frames[index].contains(CGPoint(x: min(point.x, frames[index].maxX - 0.5), y: point.y)) {
            return .row(id: chat.id, projectID: projectID, after: point.y > frames[index].midY)
        }
        let owner = contents.owners[index]
        if let topic = owner.topic { return .group(projectID: owner.project, topicID: topic) }
        return scratch(owner.project) ? nil : .group(projectID: owner.project, topicID: nil)
    }
    private func scratch(_ projectID: String) -> Bool { projectID == WorkspaceRecord.scratchID }
    private func projectArea(at point: CGPoint) -> DropTarget? {
        // Between entries (in a gap): the entry above's owner.
        guard let index = frames.lastIndex(where: { $0.minY <= point.y }) else { return nil }
        let owner = contents.owners[index]
        if let topic = owner.topic { return .group(projectID: owner.project, topicID: topic) }
        return scratch(owner.project) ? nil : .group(projectID: owner.project, topicID: nil)
    }
    private var shownTarget: DropTarget?
    private func show(_ target: DropTarget?) {
        guard target != shownTarget else { return }
        if case .row(let id, _, _) = shownTarget { (views["chat|" + id] as? SidebarChatRowView)?.insertionAfter = nil }
        shownTarget = target
        if case .row(let id, _, let after) = target { (views["chat|" + id] as? SidebarChatRowView)?.insertionAfter = after }
        if case .group(let project, let topic) = target { dropTargetChanged?((project, topic)) } else { dropTargetChanged?(nil) }
    }
    private func accepts(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.availableType(from: [NSPasteboard.PasteboardType(TopicSessionDrag.type.identifier)]) != nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender), inheritedEnabled else { show(nil); return [] }
        let target = dropTarget(at: convert(sender.draggingLocation, from: nil))
        show(target)
        switch target {
        case .row: return .move
        case .group: return .copy
        case nil: return []
        }
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { show(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { show(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard inheritedEnabled else { show(nil); return false }
        let target = dropTarget(at: convert(sender.draggingLocation, from: nil))
        show(nil)
        let model = self.model
        switch target {
        case .row(let id, let projectID, let after):
            return TopicSessionDrag.accept(sender.draggingPasteboard, in: projectID) { ids in
                try await model.reorderSessions(ids, relativeTo: id, after: after, in: projectID)
            } failure: { model.error = $0 }
        case .group(let projectID, let topicID):
            return TopicSessionDrag.acceptSidebarDrop(sender.draggingPasteboard, model: model, projectID: projectID, topicID: topicID)
        case nil:
            return false
        }
    }
}

/// A project header as a list entry.
@MainActor final class ProjectHeaderEntry: NSView, SidebarEntryView {
    let header: ProjectHeaderView
    init(model: WorkspaceModel, state: ProjectHeaderState) {
        header = ProjectHeaderView(model: model, state: state)
        super.init(frame: .zero)
        addSubview(header)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func entryHeight(width: CGFloat) -> CGFloat { header.preferredHeight }
    override func layout() { super.layout(); header.frame = bounds }
}

/// A topic header as a list entry.
@MainActor final class TopicHeaderEntry: NSView, SidebarEntryView {
    let header: TopicHeaderView
    init(model: WorkspaceModel, state: TopicHeaderState) {
        header = TopicHeaderView(model: model, state: state)
        super.init(frame: .zero)
        addSubview(header)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func entryHeight(width: CGFloat) -> CGFloat { header.preferredHeight }
    override func layout() { super.layout(); header.frame = bounds }
}
