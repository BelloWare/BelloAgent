import AppKit
import SwiftUI

// The strip of tabs over the pane beside the chat, and over each window:
// the chat's side first in the pane, then the tabs. A click shows a tab; its
// close button, a middle click or ⌘W closes it; its menu opens it in a window
// or moves it to the pane. A tab dragged along the strip moves there, onto
// another strip moves there, and let go of anywhere else pops out into a
// window of its own where it was let go of.

/// The chat's side, as the pane's strip shows it.
struct SideTabItem {
    let title: String
    let help: String
}

struct TabStrip: View {
    @ObservedObject var host: TabHost
    @ObservedObject var container: TabContainer
    /// The chat's side, in the pane when the chat has one.
    let side: SideTabItem?
    /// Room before the first tab: a window's buttons.
    var leadingInset: CGFloat = PiSpacing.sm
    static let height: CGFloat = 36
    @State private var frames: [String: CGRect] = [:]
    @State private var insertion: Int?

    private static let sideID = "side"
    private var shownID: String? {
        container.shownTab(sideAvailable: side != nil).map { $0.id.uuidString } ?? (side != nil ? Self.sideID : nil)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    if let side {
                        TabStripItem(title: side.title, symbol: "arrow.triangle.branch", help: side.help, selected: shownID == Self.sideID, closable: false,
                                     events: TabItemEvents(select: { host.showSide() }))
                            .id(Self.sideID)
                    }
                    ForEach(Array(container.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabStripTabItem(tab: tab, selected: shownID == tab.id.uuidString, insertionBefore: insertion == index,
                                        events: events(for: tab))
                            .id(tab.id.uuidString)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: TabFramesKey.self, value: [tab.id.uuidString: geometry.frame(in: .global)])
                            })
                    }
                    if insertion == container.tabs.count { TabInsertionMark() }
                }
                .padding(.leading, leadingInset).padding(.trailing, PiSpacing.sm)
                .frame(height: Self.height)
            }
            .onAppear { if let shownID { proxy.scrollTo(shownID) } }
            .onChange(of: shownID) { _, shown in if let shown { proxy.scrollTo(shown) } }
        }
        .onPreferenceChange(TabFramesKey.self) { frames = $0 }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TabDropTarget(accepts: { host.tab(withID: $0) != nil }, index: index(atWindowX:), hover: { insertion = $0 },
                                  drop: { id, index in
                                      guard let tab = host.tab(withID: id) else { return false }
                                      host.move(tab, to: container, at: index)
                                      return true
                                  }))
        .background(Color.piContent)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.piHairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(container.isPane ? "Tabs beside the chat" : "Tabs")
    }

    private func events(for tab: HostedTab) -> TabItemEvents {
        TabItemEvents(select: { host.activate(tab) }, close: { host.close(tab) }, menu: { [weak host] in
            guard let host else { return [] }
            var entries: [PiMenuEntry] = [.button("Close Tab", identifier: "tab-close") { host.close(tab) }]
            if tab.container?.tabs.count ?? 0 > 1 { entries.append(.button("Close Other Tabs", identifier: "tab-close-others") { host.closeOthers(than: tab) }) }
            entries.append(.separator)
            if tab.container?.isPane == true { entries.append(.button("Open in Window", identifier: "tab-pop-out") { host.popOut(tab) }) }
            else { entries.append(.button("Move to Pane", identifier: "tab-to-pane") { host.moveToPane(tab) }) }
            let own = tab.menuEntries()
            if !own.isEmpty { entries.append(.separator); entries.append(contentsOf: own) }
            return entries
        }, drag: { tab.id.uuidString }, poppedOut: { [weak host] point in host?.popOut(tab, at: point) })
    }
    /// Where a tab dropped at a point along the strip goes: before the first
    /// tab whose middle is right of it.
    private func index(atWindowX x: CGFloat) -> Int {
        for (index, tab) in container.tabs.enumerated() {
            if let frame = frames[tab.id.uuidString], x < frame.midX { return index }
        }
        return container.tabs.count
    }
}

private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Where a dragged tab would go.
private struct TabInsertionMark: View {
    var body: some View { Capsule().fill(Color.piAccent).frame(width: 2, height: 20) }
}

/// A hosted tab, following its title and symbol as they change.
private struct TabStripTabItem: View {
    @ObservedObject var tab: HostedTab
    let selected: Bool
    let insertionBefore: Bool
    let events: TabItemEvents
    var body: some View {
        HStack(spacing: 3) {
            if insertionBefore { TabInsertionMark() }
            TabStripItem(title: tab.title, symbol: tab.symbol, help: tab.help, selected: selected, closable: true, events: events)
        }
    }
}

/// What a tab does with the pointer: shown on a click, closed by a middle
/// click, its menu on a secondary click, and dragged.
struct TabItemEvents {
    var select: () -> Void
    var close: (() -> Void)? = nil
    var menu: (() -> [PiMenuEntry])? = nil
    /// What a drag carries: the tab's id; nil for a tab that stays put.
    var drag: (() -> String)? = nil
    /// Let go of outside every strip: a window of its own, there.
    var poppedOut: ((NSPoint) -> Void)? = nil
}

struct TabStripItem: View {
    let title: String
    let symbol: String
    let help: String
    let selected: Bool
    let closable: Bool
    let events: TabItemEvents
    @State private var hovering = false
    @State private var closeHovering = false
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.piAccent : Color.piInkTertiary)
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.piInk : Color.piInkSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.leading, 10).padding(.trailing, closable ? 4 : 10)
            .frame(height: 26)
            .contentShape(Rectangle())
            .overlay(TabItemEventView(title: title, events: events))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { events.select() }
            if closable, let close = events.close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(closeHovering ? Color.piInk : Color.piInkTertiary)
                        .frame(width: 16, height: 16)
                        .background(closeHovering ? Color.piFillStrong : Color.clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).piPointer()
                .onHover { closeHovering = $0 }
                .opacity(selected || hovering ? 1 : 0)
                .padding(.trailing, 6)
                .help("Close Tab (⌘W)")
                .accessibilityLabel("Close \(title)")
            }
        }
        .frame(maxWidth: 240)
        .background(selected ? Color.piSurface : hovering ? Color.piFill : Color.clear, in: shape)
        .overlay(shape.stroke(selected ? Color.piHairlineStrong : Color.clear, lineWidth: 1))
        .onHover { hovering = $0 }
        .piAnimation(PiMotion.quick, value: hovering)
        .help(help)
    }
}

// MARK: Pointer and drag, in AppKit

/// The pasteboard type a dragged tab travels as: its id.
extension NSPasteboard.PasteboardType {
    static let belloTab = NSPasteboard.PasteboardType("com.belloware.bello-agent.tab")
}

/// Over a tab's label: a click shows the tab, a middle click closes it, a
/// secondary click opens its menu, and a drag carries it.
private struct TabItemEventView: NSViewRepresentable {
    let title: String
    let events: TabItemEvents
    func makeNSView(context: Context) -> TabItemEventNSView { TabItemEventNSView() }
    func updateNSView(_ view: TabItemEventNSView, context: Context) { view.title = title; view.events = events }
}

final class TabItemEventNSView: NSView, NSDraggingSource {
    var title = ""
    var events: TabItemEvents?
    private var down: NSEvent?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func mouseDown(with event: NSEvent) {
        down = event
        events?.select()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down, let drag = events?.drag else { return }
        let from = down.locationInWindow, to = event.locationInWindow
        guard hypot(to.x - from.x, to.y - from.y) > 4 else { return }
        self.down = nil
        let item = NSPasteboardItem()
        item.setString(drag(), forType: .belloTab)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = Self.image(title: title)
        let at = convert(from, from: nil)
        dragging.setDraggingFrame(NSRect(x: at.x - 12, y: at.y - image.size.height / 2, width: image.size.width, height: image.size.height), contents: image)
        beginDraggingSession(with: [dragging], event: down, source: self)
    }
    override func mouseUp(with event: NSEvent) { down = nil }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { events?.close?() } else { super.otherMouseDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let entries = events?.menu?(), !entries.isEmpty else { return nil }
        return PiMenus.menu(entries)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Let go of where no strip took it: a window of its own, there. A
        // drag given up with Escape ends with the button still held: it
        // stays where it was.
        if operation == [], NSEvent.pressedMouseButtons & 1 == 0 { events?.poppedOut?(screenPoint) }
    }
    /// What a dragged tab looks like: its title on a raised tab.
    static func image(title: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.piInk])
        let size = NSSize(width: min(240, ceil(text.size().width) + 24), height: 26)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NSColor.piSurface.setFill(); path.fill()
            NSColor.piHairlineStrong.setStroke(); path.stroke()
            text.draw(with: NSRect(x: 12, y: (rect.height - text.size().height) / 2, width: rect.width - 24, height: text.size().height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }
}

/// Behind a strip: takes a tab dragged onto it, where along it it lands.
private struct TabDropTarget: NSViewRepresentable {
    let accepts: (String) -> Bool
    let index: (CGFloat) -> Int
    let hover: (Int?) -> Void
    let drop: (String, Int) -> Bool
    func makeNSView(context: Context) -> TabDropNSView {
        let view = TabDropNSView()
        view.registerForDraggedTypes([.belloTab])
        return view
    }
    func updateNSView(_ view: TabDropNSView, context: Context) {
        view.accepts = accepts; view.index = index; view.hover = hover; view.dropped = drop
    }
}

final class TabDropNSView: NSView {
    var accepts: ((String) -> Bool)?
    var index: ((CGFloat) -> Int)?
    var hover: ((Int?) -> Void)?
    var dropped: ((String, Int) -> Bool)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private func id(_ sender: NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: .belloTab).flatMap { accepts?($0) == true ? $0 : nil }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard id(sender) != nil else { return [] }
        hover?(index?(sender.draggingLocation.x))
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { hover?(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { hover?(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hover?(nil)
        guard let id = id(sender), let index = index?(sender.draggingLocation.x) else { return false }
        return dropped?(id, index) ?? false
    }
}

extension TabHost {
    func tab(withID id: String) -> HostedTab? { allTabs.first { $0.id.uuidString == id } }
}
