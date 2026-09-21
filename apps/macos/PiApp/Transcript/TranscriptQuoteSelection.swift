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
    private(set) var popover: NSPopover?

    init(scope: NSView, quote: @escaping (TranscriptQuote) -> Void) {
        self.scope = scope; self.quote = quote
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; attach()
    }
    func attach() {
        guard enabled, scope?.window != nil else {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            dismiss(); return
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
            return event
        }
    }
    private func receive(_ event: NSEvent) {
        guard let scope, event.window === scope.window else { return }
        switch event.type {
        case .leftMouseDown, .scrollWheel: dismiss()
        case .keyDown:
            if event.keyCode == 53 { dismiss() }
        case .leftMouseUp, .keyUp:
            if event.type == .keyUp && event.keyCode == 53 { return }
            let expected = revision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == expected else { return }
                self.presentSelection()
            }
        default: break
        }
    }
    func dismiss() {
        revision += 1
        popover?.close(); popover = nil
        selectedQuote = nil; editor = nil
        range = NSRange(location: NSNotFound, length: 0)
    }

    /// Finds the actual selection owner, including AppKit's shared field
    /// editor used by SwiftUI Text. Never guess by searching repeated words.
    private func selection() -> (NSTextView, NSRange, TranscriptQuote, NSRect)? {
        guard enabled, let scope, !scope.isHiddenOrHasHiddenAncestor, let window = scope.window,
              let text = window.firstResponder as? NSTextView else { return nil }
        let owner = text.isFieldEditor ? text.delegate as? NSView : text
        guard let owner, owner.isDescendant(of: scope), !owner.isHiddenOrHasHiddenAncestor else { return nil }
        let range = text.selectedRange(), source = text.string as NSString
        guard range.location != NSNotFound, range.length > 0, range.location <= source.length,
              range.length <= source.length - range.location else { return nil }
        let selected = source.substring(with: range)
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
        return (text, range, TranscriptQuote(messageID: region.messageID, text: selected), anchor.intersection(scope.visibleRect))
    }

    func presentSelection() {
        guard let scope, let (text, selectedRange, value, anchor) = selection() else { dismiss(); return }
        if popover?.isShown == true, selectedQuote == value, editor === text, range == selectedRange { return }
        dismiss()
        editor = text; range = selectedRange; selectedQuote = value
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = QuoteSelectionContent(quote: value.text) { [weak self] in self?.askInSideChat() }
        self.popover = popover
        popover.show(relativeTo: anchor, of: scope, preferredEdge: .maxY)
    }

    func askInSideChat() {
        guard let saved = selectedQuote, let editor, editor.selectedRange() == range,
              // A selection can settle during streaming. Confirm the native
              // text has not been replaced before acting on the retained quote.
              range.location <= (editor.string as NSString).length,
              range.length <= (editor.string as NSString).length - range.location,
              (editor.string as NSString).substring(with: range) == saved.text,
              scope?.window != nil, scope?.isHiddenOrHasHiddenAncestor == false else { dismiss(); return }
        dismiss()
        quote(saved)
    }
}

@MainActor private final class QuoteSelectionContent: NSViewController {
    private let selectedText: String
    private let ask: () -> Void
    init(quote: String, ask: @escaping () -> Void) {
        selectedText = quote; self.ask = ask
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let view = NSView()
        let preview = NSTextField(wrappingLabelWithString: String(selectedText.prefix(160)))
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = .secondaryLabelColor
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        let button = NSButton(title: "Ask in side chat", target: self, action: #selector(submit))
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.keyEquivalent = "\r"
        button.setAccessibilityIdentifier("quoteInSideChat")
        let stack = NSStackView(views: [preview, button])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            preview.widthAnchor.constraint(equalToConstant: 250)
        ])
        self.view = view
        preferredContentSize = NSSize(width: 278, height: 90)
    }
    @objc private func submit() { ask() }
}
