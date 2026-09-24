import AppKit
import SwiftUI

struct TranscriptQuote: Equatable, Sendable {
    let messageID: String
    /// The selected rendered text, with native UTF-16 selection boundaries.
    let text: String
}

/// A geometry-only marker behind assistant prose (including its code blocks).
/// User text, reasoning/tool details and accounting labels have no marker.
/// It neither intercepts input nor introduces another text/hosting surface.
struct TranscriptQuoteRegion: NSViewRepresentable {
    let messageID: String
    func makeNSView(context: Context) -> TranscriptQuoteRegionView { TranscriptQuoteRegionView() }
    func updateNSView(_ view: TranscriptQuoteRegionView, context: Context) { view.messageID = messageID }
}

final class TranscriptQuoteRegionView: NSView {
    var messageID = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
}

/// One input observer per mounted conversation, not per row or streamed delta.
/// AppKit still owns selection/copy. Wait until the native mouse/key event has
/// finished before reading the selection, then keep only that small snapshot.
@MainActor final class TranscriptQuoteSelectionController {
    private weak var scope: NSView?
    private let quote: (TranscriptQuote) -> Void
    private var enabled = false
    nonisolated(unsafe) private var monitor: Any?
    private var revision = 0
    private weak var editor: NSTextView?
    private var range = NSRange(location: NSNotFound, length: 0)
    private(set) var selectedQuote: TranscriptQuote?
    /// The floating "Ask in side chat" bar, while a quotable selection shows it.
    private(set) var bar: QuoteActionPanel?
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

    init(scope: NSView, quote: @escaping (TranscriptQuote) -> Void) {
        self.scope = scope; self.quote = quote
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; attach()
    }
    func attach() {
        guard enabled, let window = scope?.window else {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
            windowObservers = []
            dismiss(); return
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp, .scrollWheel]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.receive(event) ?? false }
            return handled ? nil : event
        }
        // The bar floats in a window of its own: it goes when its window
        // stops being the one in front, or changes size under the selection.
        for name in [NSWindow.didResignKeyNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
    }
    /// Returns whether the event was the bar's: Return asks, and is not
    /// passed on.
    private func receive(_ event: NSEvent) -> Bool {
        guard let scope, event.window === scope.window else { return false }
        switch event.type {
        case .leftMouseDown, .scrollWheel: dismiss()
        case .keyDown:
            if event.keyCode == 53 { dismiss() }
            else if bar != nil, [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                askInSideChat(); return true
            }
        case .leftMouseUp, .keyUp:
            if event.type == .keyUp && [53, 36, 76].contains(event.keyCode) { return false }
            let expected = revision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == expected else { return }
                self.presentSelection()
            }
        default: break
        }
        return false
    }
    func dismiss() {
        revision += 1
        if let bar {
            bar.parent?.removeChildWindow(bar); bar.orderOut(nil)
            self.bar = nil
        }
        selectedQuote = nil; editor = nil
        range = NSRange(location: NSNotFound, length: 0)
    }

    /// Finds the actual selection owner, including AppKit's shared field
    /// editor used by SwiftUI Text. Never guess by searching repeated words.
    private func selection() -> (NSTextView, NSRange, TranscriptQuote, (all: NSRect, first: NSRect))? {
        guard enabled, let scope, !scope.isHiddenOrHasHiddenAncestor, let window = scope.window,
              let text = window.firstResponder as? NSTextView else { return nil }
        let owner = text.isFieldEditor ? text.delegate as? NSView : text
        guard let owner, owner.isDescendant(of: scope), !owner.isHiddenOrHasHiddenAncestor else { return nil }
        let range = text.selectedRange(), source = text.string as NSString
        guard range.location != NSNotFound, range.length > 0, range.location <= source.length,
              range.length <= source.length - range.location else { return nil }
        let selected = Self.quoted(text, range)
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var ancestor: NSView? = owner
        while ancestor != nil && !(ancestor is TranscriptRowContainer) { ancestor = ancestor?.superview }
        guard let row = ancestor as? TranscriptRowContainer else { return nil }
        let screenRect = text.firstRect(forCharacterRange: range, actualRange: nil)
        guard !screenRect.isEmpty else { return nil }
        let anchor = scope.convert(window.convertFromScreen(screenRect), from: nil)
        guard anchor.intersects(scope.visibleRect) else { return nil }
        func findRegion(_ view: NSView) -> TranscriptQuoteRegionView? {
            if let region = view as? TranscriptQuoteRegionView,
               !region.messageID.isEmpty, region.convert(region.bounds, to: scope).insetBy(dx: -1, dy: -1).intersects(anchor) { return region }
            for child in view.subviews { if let region = findRegion(child) { return region } }
            return nil
        }
        guard let region = findRegion(row) else { return nil }
        return (text, range, TranscriptQuote(messageID: region.messageID, text: selected), Self.screenRects(text, range, first: screenRect))
    }
    /// The selected text as it reads: a reply's text gives it as a copy
    /// does, its list markers and table cells written out.
    private static func quoted(_ text: NSTextView, _ range: NSRange) -> String {
        if let reply = text as? MarkdownTextView { return reply.copyText([range]) }
        return (text.string as NSString).substring(with: range)
    }
    /// Every line of the selection on screen as one rectangle, and its first
    /// line: the bar is centred on the one and stands clear of the other.
    private static func screenRects(_ text: NSTextView, _ range: NSRange, first: NSRect) -> (all: NSRect, first: NSRect) {
        var all = first, remaining = range
        for _ in 0..<400 where remaining.length > 0 {
            var actual = NSRange(location: NSNotFound, length: 0)
            let line = text.firstRect(forCharacterRange: remaining, actualRange: &actual)
            guard actual.location != NSNotFound, actual.length > 0 else { break }
            if !line.isEmpty { all = all.union(line) }
            let end = actual.location + actual.length
            remaining = NSRange(location: end, length: max(0, range.location + range.length - end))
        }
        return (all, first)
    }

    func presentSelection() {
        guard let scope, let window = scope.window, let (text, selectedRange, value, rects) = selection() else { dismiss(); return }
        if bar?.isVisible == true, selectedQuote == value, editor === text, range == selectedRange { return }
        dismiss()
        editor = text; range = selectedRange; selectedQuote = value
        let bar = QuoteActionPanel { [weak self] in self?.askInSideChat() }
        // A window of its own does not inherit its parent's appearance.
        bar.appearance = window.effectiveAppearance
        let visible = window.convertToScreen(scope.convert(scope.visibleRect, to: nil))
        bar.place(selection: rects.all, firstLine: rects.first, within: visible)
        window.addChildWindow(bar, ordered: .above)
        self.bar = bar
    }

    func askInSideChat() {
        guard let saved = selectedQuote, let editor, editor.selectedRange() == range,
              // A selection can settle during streaming. Confirm the native
              // text has not been replaced before acting on the retained quote.
              range.location <= (editor.string as NSString).length,
              range.length <= (editor.string as NSString).length - range.location,
              Self.quoted(editor, range) == saved.text,
              scope?.window != nil, scope?.isHiddenOrHasHiddenAncestor == false else { dismiss(); return }
        dismiss()
        quote(saved)
    }
}

/// The action a transcript selection offers: one compact bar floating just
/// above the selection, on the app's own surface. It is a borderless child
/// window rather than a popover, so it has no arrow and no system material,
/// and it never takes key status: the selection stays the reader's, Return
/// (through the selection controller) asks, Escape dismisses.
@MainActor final class QuoteActionPanel: NSPanel {
    /// Room around the bar inside the panel, for its shadow.
    static let margin: CGFloat = 14
    /// Between the bar and the line it stands above (or below).
    static let gap: CGFloat = 6

    init(ask: @escaping () -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        isReleasedWhenClosed = false; animationBehavior = .none
        becomesKeyOnlyIfNeeded = true; hidesOnDeactivate = true
        let host = NSHostingView(rootView: QuoteActionBar(ask: ask).padding(Self.margin))
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
        setContentSize(host.fittingSize)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The bar itself on screen, without the room kept for its shadow.
    var barFrame: NSRect { frame.insetBy(dx: Self.margin, dy: Self.margin) }

    /// Just above the selection's first line, centred on the selection;
    /// below its last line when there is no room above. It stays inside the
    /// part of the conversation that is on screen, and never over the text.
    func place(selection: NSRect, firstLine: NSRect, within visible: NSRect) {
        let bar = barFrame.size
        var x = selection.midX - bar.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - 8 - bar.width))
        var y = firstLine.maxY + Self.gap
        if y + bar.height > visible.maxY { y = selection.minY - Self.gap - bar.height }
        setFrameOrigin(NSPoint(x: x - Self.margin, y: y - Self.margin))
    }
}

/// The bar's face: the bubble glyph in the accent, the action in the app's
/// ink, and a quiet key hint. The press, the pointer, the tooltip and the
/// accessibility action belong to the app's AppKit press target over it.
private struct QuoteActionBar: View {
    let ask: () -> Void
    @State private var hovering = false
    @State private var arrived = false
    @Environment(\.piReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.piAccent)
            Text("Ask in side chat").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.piInk)
            Text("↩").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.piFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(hovering ? Color.piFillStrong : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(3)
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.piHairlineStrong, lineWidth: 1))
        .shadow(color: Color.piShadow, radius: 10, y: 3)
        .overlay {
            PiPopoverTrigger(label: "Ask in side chat", identifier: "quoteInSideChat",
                             help: "Ask about the selected text in a side chat (Return)",
                             onHover: { hovering = $0 }, onPress: { _ in ask() })
        }
        .piAnimation(PiMotion.quick, value: hovering)
        .scaleEffect(arrived || reduceMotion ? 1 : 0.96)
        .opacity(arrived || reduceMotion ? 1 : 0)
        .onAppear { if reduceMotion { arrived = true } else { withAnimation(PiMotion.quick) { arrived = true } } }
    }
}
