import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Only Bello Agent's own sidebar drags are accepted. A session reference is
/// not a file/text drop, and a drop never changes a chat's project or starts it.
struct TopicSessionDrag: Codable, Equatable {
    static let type = UTType(exportedAs: "com.belloware.belloagent.project-session", conformingTo: .data)
    static let maximumBytes = 65_536
    static let maximumItems = 32
    /// One drag carries a marked selection, bounded the way a bulk action is.
    static let maximumSessions = 500
    private static let currentProcessNonce = UUID().uuidString
    let version: Int
    let sessionIDs: [String]
    let workspaceID: String
    private let processNonce: String

    init(sessionIDs: [String], workspaceID: String) {
        self.version = 1; self.sessionIDs = sessionIDs; self.workspaceID = workspaceID
        self.processNonce = Self.currentProcessNonce
    }
    init(sessionID: String, workspaceID: String) { self.init(sessionIDs: [sessionID], workspaceID: workspaceID) }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512 && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    func encoded() -> Data? {
        guard !sessionIDs.isEmpty, sessionIDs.count <= Self.maximumSessions, sessionIDs.allSatisfy(Self.validID),
              Self.validID(workspaceID), let data = try? JSONEncoder().encode(self), data.count <= Self.maximumBytes else { return nil }
        return data
    }
    static func decode(_ data: Data, in projectID: String) -> TopicSessionDrag? {
        guard data.count <= maximumBytes,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1, value.processNonce == currentProcessNonce,
              value.workspaceID == projectID, validID(value.workspaceID),
              !value.sessionIDs.isEmpty, value.sessionIDs.count <= maximumSessions,
              value.sessionIDs.allSatisfy(validID) else { return nil }
        return value
    }
    /// The item an AppKit dragging session carries. Same bounded, nonce-stamped
    /// bytes the drop side decodes, so a drag that cannot be encoded drags
    /// nothing rather than an item no destination would accept.
    func pasteboardItem() -> NSPasteboardItem? {
        guard let data = encoded() else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(Self.type.identifier))
        return item
    }
    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        guard let data = encoded() else { return provider }
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil); return nil
        }
        return provider
    }

    /// Load bounded, authenticated metadata, then use the same transactional
    /// move path as the menu. An invalid item rejects the entire drop.
    @MainActor static func accept(_ providers: [NSItemProvider], in projectID: String,
                                  move: @escaping @MainActor ([String]) async throws -> Void,
                                  failure: @escaping @MainActor (String) -> Void) -> Bool {
        guard !providers.isEmpty, providers.count <= maximumItems,
              providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { return false }
        Task { @MainActor in
            var ids: [String] = []
            for provider in providers {
                let data: Data? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                        // Never parse unbounded external provider data.
                        continuation.resume(returning: data.flatMap { $0.count <= maximumBytes ? $0 : nil })
                    }
                }
                guard let data, let payload = decode(data, in: projectID) else {
                    failure("Move chats only between topics in the same project."); return
                }
                for id in payload.sessionIDs where !ids.contains(id) { ids.append(id) }
            }
            do { try await move(ids) } catch { failure(error.localizedDescription) }
        }
        return true
    }

    /// Both sidebar groups drop through here, so the whole group — its header
    /// strip and every chat row under it — accepts what only the header used to.
    @MainActor static func acceptSidebarDrop(_ providers: [NSItemProvider], model: WorkspaceModel,
                                             projectID: String, topicID: String?) -> Bool {
        accept(providers, in: projectID) { ids in
            try await model.moveSessions(ids, in: projectID, toTopic: topicID)
        } failure: { model.error = $0 }
    }
}

/// What a click on a sidebar chat row means. The AppKit surface below and the
/// row's own keyboard activation both decide it here, so the two can never
/// drift apart: Shift extends the marked range and Command adds or removes one
/// row, as a file list does, while an ordinary click drops the marks and opens.
enum SidebarRowClick: Equatable {
    case open, extendMarks, toggleMark

    init(modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) { self = .extendMarks }
        else if flags.contains(.command) { self = .toggleMark }
        else { self = .open }
    }

    @MainActor func apply(to model: WorkspaceModel, sessionID: String, open: () -> Void) {
        switch self {
        case .extendMarks: model.extendSessionMarks(to: sessionID)
        case .toggleMark: model.toggleSessionMark(sessionID)
        case .open: model.clearSessionMarks(); open()
        }
    }
}

/// Where a row's own controls sit. AppKit cannot hit-test against buttons
/// SwiftUI draws into the row, so a row publishes their bounds and the drag
/// surface declines exactly those presses.
struct SidebarRowControlBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}

/// What a press on a row can turn into. The row is rebuilt on every sidebar
/// change, so the retained surface asks for these instead of holding a snapshot
/// of what the row carried when it was installed.
struct TopicSessionRowActions {
    var item: @MainActor () -> NSPasteboardItem? = { nil }
    var image: @MainActor () -> NSImage? = { nil }
    var click: @MainActor (NSEvent.ModifierFlags) -> Void = { _ in }
    var doubleClick: @MainActor () -> Void = { }
}

/// Dragging a marked row carries every marked chat of that project; dragging an
/// unmarked row carries only that chat, and the drag image says how many travel.
/// AppKit owns the press: a SwiftUI `Button` claims mouse-down on macOS, so
/// `.onDrag` on a row inside one never started a drag at all.
struct TopicSessionDragSource: ViewModifier {
    /// Held, never observed: the ids and the drag image are read when a press
    /// happens, and observing the workspace here made every chat row's drag
    /// surface a dependency of every published change in the app.
    let model: WorkspaceModel
    let sessionID: String
    let projectID: String
    let enabled: Bool
    let click: @MainActor (NSEvent.ModifierFlags) -> Void
    let doubleClick: @MainActor () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.overlayPreferenceValue(SidebarRowControlBounds.self) { controls in
                GeometryReader { row in
                    TopicSessionDragSurface(actions: TopicSessionRowActions(item: dragItem, image: dragImage,
                                                                            click: click, doubleClick: doubleClick),
                                            controls: controls.map { row[$0] })
                }
            }
        } else { content }
    }

    /// What this row would put on the drag pasteboard right now. Read before the
    /// press is applied, so a marked row still carries the marks it was dragged by.
    func dragItem() -> NSPasteboardItem? {
        TopicSessionDrag(sessionIDs: model.dragSessionIDs(for: sessionID, in: projectID), workspaceID: projectID).pasteboardItem()
    }

    /// Rendered only once a drag really starts; an ordinary click must not pay
    /// for a bitmap nobody sees.
    func dragImage() -> NSImage? {
        let count = model.dragSessionIDs(for: sessionID, in: projectID).count
        let renderer = ImageRenderer(content: TopicSessionDragPreview(count: count, title: model.record(sessionID)?.title ?? "Chat"))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}

private struct TopicSessionDragSurface: NSViewRepresentable {
    let actions: TopicSessionRowActions
    let controls: [CGRect]
    func makeNSView(context: Context) -> TopicSessionDragSurfaceView { update(TopicSessionDragSurfaceView()) }
    func updateNSView(_ view: TopicSessionDragSurfaceView, context: Context) { _ = update(view) }
    @discardableResult private func update(_ view: TopicSessionDragSurfaceView) -> TopicSessionDragSurfaceView {
        view.actions = actions; view.controls = controls
        return view
    }
}

/// The transparent surface over a draggable chat row. It takes the plain left
/// press, begins a real dragging session once the pointer travels, and hands
/// every other press straight back to the SwiftUI row underneath.
final class TopicSessionDragSurfaceView: NSView, NSDraggingSource {
    /// Far enough that a shaky click still selects, short enough that a
    /// deliberate pull shows the drag image at once.
    static let dragThreshold: CGFloat = 4
    var actions = TopicSessionRowActions()
    /// The row's own buttons, in this view's coordinates; see `SidebarRowControlBounds`.
    var controls: [CGRect] = []
    private var hoverTracking: NSTrackingArea?
    /// SwiftUI measures the row from its top-left, and the control cut-outs
    /// arrive in those coordinates.
    override var isFlipped: Bool { true }

    static func startsDrag(from origin: CGPoint, to point: CGPoint) -> Bool {
        max(abs(point.x - origin.x), abs(point.y - origin.y)) >= dragThreshold
    }

    /// Only a plain left press starts a row's press. Right-click and
    /// Control-click must reach the row so its context menu opens, and hover,
    /// tooltips, scrolling and a drag already in flight carry no press of ours.
    static func claims(_ event: NSEvent) -> Bool {
        event.type == .leftMouseDown && !event.modifierFlags.contains(.control)
    }
    /// Archiving a chat or folding its side chats stays a button press: those
    /// buttons are drawn by SwiftUI underneath and would never see the mouse.
    static func claims(_ point: CGPoint, controls: [CGRect]) -> Bool {
        !controls.contains { $0.contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) === self, let event = NSApp.currentEvent, Self.claims(event),
              Self.claims(convert(point, from: superview), controls: controls) else { return nil }
        return self
    }

    /// How long the press waits for the next event before checking that the
    /// button is still down. Short enough that an abandoned press is noticed
    /// within a frame or two, long enough to cost nothing while one is held.
    static let pressPollInterval: TimeInterval = 0.1
    /// Polls of complete silence before the press is abandoned: a minute of a
    /// button reported as held with no motion and no release is not a press.
    static let pressIdleLimit = 600

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // The second press of a double-click renames; the first already selected.
        guard event.clickCount < 2 else { actions.doubleClick(); return }
        let item = actions.item(), origin = event.locationInWindow, pressed = window
        var idle = 0
        // Hold the press until it declares itself: a drag past the threshold, or
        // the click the row has always handled.
        while true {
            // Never `.distantFuture`. A release can go missing — the window
            // closes or deactivates under the press, a sheet takes the event
            // stream, the row is torn down while held — and the main thread
            // would then wait for it for the rest of the session with every
            // timer, stream and redraw stopped behind it.
            guard let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                             until: Date(timeIntervalSinceNow: Self.pressPollInterval),
                                             inMode: .eventTracking, dequeue: true) else {
                idle += 1
                // The button is no longer down, the row left its window, or the
                // press has been "held" without a single event for longer than
                // anyone holds a row: none of those is a press to wait on.
                guard NSEvent.pressedMouseButtons & 1 == 1, window === pressed, idle < Self.pressIdleLimit else { return }
                continue
            }
            idle = 0
            // The row went away while it was held: a chat deleted from another
            // window, a filter flipping, a topic collapsing. Releasing must not
            // then open or mark whatever used to be here.
            guard window === pressed else { return }
            guard next.type == .leftMouseDragged else { break }
            guard let item, pressed != nil, Self.startsDrag(from: origin, to: next.locationInWindow) else { continue }
            beginDrag(item, with: next)
            return
        }
        actions.click(modifiers)
    }

    private func beginDrag(_ item: NSPasteboardItem, with event: NSEvent) {
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = actions.image(), point = convert(event.locationInWindow, from: nil)
        let size = image?.size ?? bounds.size
        dragging.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                         width: size.width, height: size.height), contents: image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    /// A chat is desktop organization, never a file: it may move inside this
    /// application, and nothing at all is offered to anyone else. The sidebar's
    /// own groups answer a drop with `.copy`, so a mask of `.move` alone would
    /// refuse every drag the moment it reached its destination.
    static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : []
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operationMask(for: context)
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    /// An open hand says the row can be pulled, not merely clicked. The row's
    /// own pointing hand is turned off for these rows so only one cursor is
    /// pushed, and it is popped again exactly the way `piPointer` does.
    override func mouseEntered(with event: NSEvent) { pushCursor() }
    override func mouseExited(with event: NSEvent) { popCursor() }
    override func viewDidMoveToWindow() { if window == nil { popCursor() } }
    /// AppKit shows its own cursor for the length of a drag, and sends no exit
    /// while it does: ours steps aside and returns if the row is still under it.
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { popCursor() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        pushCursor()
    }
    private func pushCursor() {
        guard window != nil else { return }
        SidebarRowCursor.shared.push(self)
    }
    private func popCursor() { SidebarRowCursor.shared.pop(self) }
}

/// `NSCursor.push` is a process-wide stack, and a sidebar row does not always
/// get the exit event that would pop it: closing the window under the pointer,
/// deactivating the app, or a chat deleted while hovered used to leave the open
/// hand on every other surface for the rest of the session, and left a stray
/// entry for the next unrelated `NSCursor.pop` to take. One owner holds the one
/// push, and loses it the moment it stops being a live row under the pointer.
@MainActor final class SidebarRowCursor {
    static let shared = SidebarRowCursor()
    private weak var owner: NSView?
    private var pushed = false
    private var observers: [NSObjectProtocol] = []
    /// Test seam: whether the shared open hand is currently on the stack.
    var isPushed: Bool { pushed }

    func push(_ view: NSView) {
        observe()
        // Two rows can never be hovered at once, and a row deallocated under
        // the pointer leaves no owner behind: a missed exit must not stack a
        // second hand on top of the first.
        if pushed, owner !== view { NSCursor.pop(); pushed = false }
        owner = view
        guard !pushed else { return }
        NSCursor.openHand.push(); pushed = true
    }
    func pop(_ view: NSView) {
        guard owner === view || owner == nil else { return }
        release()
    }
    private func release() {
        owner = nil
        guard pushed else { return }
        NSCursor.pop(); pushed = false
    }
    /// The window is going away, or the app is: nothing will send the exit.
    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = ObjectIdentifier(note.object as AnyObject)
            MainActor.assumeIsolated {
                let shared = SidebarRowCursor.shared
                if let window = shared.owner?.window, ObjectIdentifier(window) != closing { return }
                shared.release()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SidebarRowCursor.shared.release() }
        })
    }
}

private struct TopicSessionDragPreview: View {
    let count: Int
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: count > 1 ? "square.stack" : "bubble.left.and.text.bubble.right").font(.system(size: 11, weight: .semibold))
            Text(count > 1 ? "\(count) chats" : title).font(PiFont.caption).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(Color.piInk)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous).stroke(Color.piAccent.opacity(0.6), lineWidth: 1))
        .frame(maxWidth: 220)
    }
}
