import AppKit
import SwiftUI

// An item's whole text, shown where its preview was: laid out once by
// TextKit 1 away from the main thread, then handed to a selectable text view.
//
// A tool result, a system prompt or a turn's prompt can run to megabytes.
// Laying that out where it is shown would hold the main thread for as long as
// TextKit takes, a second or more for ten million characters, and a SwiftUI
// `Text` of it would do the same on every update. So the text system's objects
// (storage, layout manager, container) are built and laid out on
// `InspectorTextWorker` and handed over whole; from then on only the main
// actor touches them. TextKit 1 allows this: its objects may be used from any
// thread, one thread at a time, while no view is attached.
//
// Two things about a large layout cost the main thread in proportion to its
// length, and both are avoided here: setting a text view's options while the
// layout is attached (each one redisplays all of it), and taking the text view
// out of its superview while the layout is attached. A view is configured
// before it is given its layout, and lets go of the layout before it moves.
//
// Nothing is laid out again on the main thread: the container keeps the width
// it was laid out to, and a new width is laid out on the worker while the
// reader keeps the old one.

/// How the Inspector sets a text. In the outline, the fonts and the 18 pt
/// line of its preview rows, so the whole text starts where the preview did;
/// on a page, the page's body type in its own lines.
struct InspectorTextStyle: Sendable, Equatable {
    enum Face: Sendable, Equatable {
        /// JSON, tool calls and results: the outline's monospaced lines.
        case mono
        /// Messages and reasoning: the outline's text lines.
        case prose
        /// A page's body text, the width it is given: the Turn page's prompt.
        case body
    }
    var face: Face
    init(face: Face) { self.face = face }
    init(monospaced: Bool) { face = monospaced ? .mono : .prose }

    /// The outline's row pitch, which its whole texts keep.
    static let lineHeight: CGFloat = 18
    static let monoSize: CGFloat = 11.5
    static let textSize: CGFloat = 12.5
    static let bodySize: CGFloat = 13

    var font: NSFont {
        switch face {
        case .mono: return .monospacedSystemFont(ofSize: Self.monoSize, weight: .regular)
        case .prose: return .systemFont(ofSize: Self.textSize)
        case .body: return .systemFont(ofSize: Self.bodySize)
        }
    }
    var color: NSColor { face == .mono ? .piInkSecondary : .piInk }
    /// The outline's texts keep its rows' line; a page's body sets its own.
    var fixedLineHeight: CGFloat? { face == .body ? nil : Self.lineHeight }

    /// The width a text is laid out to when `available` points are free. In
    /// the outline a hundred columns at most, the measure the preview is
    /// wrapped to, so the whole text's lines read as the preview's did.
    func wrapWidth(_ available: CGFloat) -> CGFloat {
        let available = max(60, floor(available))
        guard face != .body else { return available }
        let sample = face == .mono ? "0000000000" : "the quick brown fox jumps over a lazy dog"
        let measure = ceil(Self.width(sample, font: font) / CGFloat(sample.count) * CGFloat(RequestDocument.wrapColumns))
        return min(available, measure)
    }

    /// Where the preview rows put a line's baseline, down from the line's top:
    /// centred on the row, as `InspectorRowCell.drawLine` draws it.
    func rowBaseline() -> CGFloat {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: "Hg", attributes: [.font: font])), &ascent, &descent, nil)
        return ((fixedLineHeight ?? Self.lineHeight) / 2 + (ascent - descent) / 2).rounded()
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), nil, nil, nil))
    }
}

/// A text laid out off the main thread: TextKit 1's storage, layout manager
/// and container, handed to the main actor whole. Built on the worker and
/// never touched there again; on the main actor it is only read, or attached
/// to one `InspectorTextView`.
final class InspectorLaidOutText: @unchecked Sendable {
    let storage: NSTextStorage
    let manager: NSLayoutManager
    let container: NSTextContainer
    /// The container's width: where the lines wrap.
    let width: CGFloat
    /// The laid-out lines' height.
    let height: CGFloat
    /// How much of the text it holds, in UTF-16 units, from the start.
    let characters: Int
    /// The length it was asked to hold; a cut ends on a line where it can.
    let limit: Int

    private init(storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer, width: CGFloat, height: CGFloat, characters: Int, limit: Int) {
        self.storage = storage; self.manager = manager; self.container = container
        self.width = width; self.height = height; self.characters = characters; self.limit = limit
    }

    /// Lays out the first `limit` characters of `text` at `width`, a slice at
    /// a time so a text the reader has left stops being laid out. Call on the
    /// worker.
    static func make(_ text: String, limit: Int, width: CGFloat, style: InspectorTextStyle) throws -> InspectorLaidOutText {
        try Task.checkCancellation()
        let whole = text as NSString
        let count = cut(whole, limit: limit)
        let font = style.font
        let paragraph = NSMutableParagraphStyle()
        if let line = style.fixedLineHeight { paragraph.minimumLineHeight = line; paragraph.maximumLineHeight = line }
        paragraph.lineBreakMode = .byWordWrapping
        // A tab is four columns, as the preview writes it.
        paragraph.tabStops = []; paragraph.defaultTabInterval = 4 * InspectorTextStyle.width("0", font: font)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.color, .paragraphStyle: paragraph]
        if style.fixedLineHeight != nil { attributes[.baselineOffset] = baselineOffset(style: style, paragraph: paragraph) }
        let storage = NSTextStorage(string: count == whole.length ? text : whole.substring(to: count), attributes: attributes)
        let (manager, container) = stack(storage, width: width)
        var done = 0
        let length = storage.length
        while done < length {
            try Task.checkCancellation()
            done = min(length, done + 131_072)
            manager.ensureLayout(forCharacterRange: NSRange(location: 0, length: done))
        }
        if length == 0 { manager.ensureLayout(for: container) }
        let used = manager.usedRect(for: container)
        let line = style.fixedLineHeight ?? ceil(manager.defaultLineHeight(for: font))
        return InspectorLaidOutText(storage: storage, manager: manager, container: container, width: width,
                                    height: max(line, ceil(used.maxY)), characters: count, limit: limit)
    }

    private static func stack(_ storage: NSTextStorage, width: CGFloat) -> (NSLayoutManager, NSTextContainer) {
        let manager = NSLayoutManager()
        manager.allowsNonContiguousLayout = false
        // Idle-time layout would run on the main thread once a view is attached.
        manager.backgroundLayoutEnabled = false
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false; container.heightTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return (manager, container)
    }

    /// Given a fixed line height, TextKit sets the baseline at the line's foot
    /// less the descent; the preview rows centre it. This moves TextKit's to
    /// the rows', measured on a line of two letters.
    private static func baselineOffset(style: InspectorTextStyle, paragraph: NSParagraphStyle) -> CGFloat {
        let probe = NSTextStorage(string: "Hg", attributes: [.font: style.font, .paragraphStyle: paragraph])
        let (manager, _) = stack(probe, width: 400)
        let fragment = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let baseline = fragment.minY + manager.location(forGlyphAt: 0).y
        return baseline - style.rowBaseline()
    }

    /// Where the first `limit` characters end: on a line break in the last
    /// stretch before the limit when there is one, and never inside a
    /// character.
    static func cut(_ text: NSString, limit: Int) -> Int {
        guard limit < text.length else { return text.length }
        let end = text.rangeOfComposedCharacterSequence(at: max(0, limit)).location
        let window = NSRange(location: max(0, end - 8_192), length: min(8_192, end))
        let newline = text.range(of: "\n", options: .backwards, range: window)
        return newline.location == NSNotFound ? end : newline.location + 1
    }
}

/// One serial owner of the Inspector's text layout, apart from the capture
/// worker so a long layout never holds up a body being read, or the reverse.
actor InspectorTextWorker {
    static let shared = InspectorTextWorker()
    func layout(_ text: String, limit: Int, width: CGFloat, style: InspectorTextStyle) throws -> InspectorLaidOutText {
        try InspectorLaidOutText.make(text, limit: limit, width: width, style: style)
    }
}

/// One text the reader asked to see whole: read, laid out a step at a time,
/// and laid out again when its width changes. The outline keeps one per open
/// item; a Turn page keeps one for its prompt.
@MainActor final class InspectorExpansion: ObservableObject {
    enum Phase: Equatable { case loading, shown, failed(String) }

    /// How much of a text is laid out at first, and how much more each time
    /// the reader asks: every character of a text up to this long. The screen
    /// says when a text is longer. A test seam.
    static var step = 1_048_576
    /// How long a new width must hold before the text is laid out to it.
    static var settle: Duration = .milliseconds(120)

    let title: String
    let style: InspectorTextStyle
    @Published private(set) var phase: Phase = .loading
    /// The layout on screen: replaced, never changed.
    @Published private(set) var layout: InspectorLaidOutText?
    /// Laying out the next step, or a new width, while the reader keeps the last.
    @Published private(set) var laying = false
    /// The whole text, as far as it was read.
    private(set) var text = ""
    /// Its length in UTF-16 units.
    private(set) var length = 0
    /// The length of what it was read from: more than `length` when the read
    /// stopped short (a Turn page's prompt).
    private(set) var total = 0
    private(set) var loaded = false
    /// The view that shows `layout`.
    private(set) var textView: InspectorTextView?
    /// Called after the layout or the phase changed, with the layout before.
    var changed: ((_ previous: InspectorLaidOutText?) -> Void)?
    /// What the text view's Show Less does.
    var showLess: (() -> Void)?

    private var wanted: Int
    private var available: CGFloat?
    private var reading: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    private var settling: Task<Void, Never>?
    private var generation = 0

    init(title: String, style: InspectorTextStyle) {
        self.title = title; self.style = style; wanted = Self.step
    }

    var shown: Int { layout?.characters ?? 0 }
    /// Laid out short of the whole text.
    var capped: Bool { layout != nil && shown < length }
    /// How much the next "Show more" adds.
    var nextStep: Int { min(Self.step, max(0, length - shown)) }

    /// Reads the text on the capture worker, as the documents render it.
    func load(render: @escaping @Sendable () throws -> String) {
        load {
            let (text, length) = try await CapturedBodyWorker.shared.run { () -> (String, Int) in
                let text = try render()
                return (text, (text as NSString).length)
            }
            return (text, length, length)
        }
    }

    /// Reads the text through `read`: the text, its length, and the length of
    /// the whole it was read from.
    func load(_ read: @escaping @MainActor () async throws -> (text: String, length: Int, total: Int)) {
        reading?.cancel()
        loaded = false
        if phase != .loading { phase = .loading }
        reading = Task { [weak self] in
            do {
                let value = try await read()
                guard let self, !Task.isCancelled else { return }
                self.reading = nil
                self.text = value.text; self.length = value.length; self.total = max(value.total, value.length)
                self.loaded = true
                self.lay()
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.reading = nil
                self.fail(error)
            }
        }
    }

    /// The width its host has for it. The first one lays the text out as soon
    /// as it is read; a later change waits for the width to settle.
    func offer(width: CGFloat) {
        guard width.isFinite, width > 1 else { return }
        let changedWidth = available.map { abs(style.wrapWidth($0) - style.wrapWidth(width)) >= 1 } ?? true
        available = width
        guard loaded, changedWidth || layout == nil else { return }
        guard let layout else { if layoutTask == nil { lay() }; return }
        guard abs(layout.width - style.wrapWidth(width)) >= 1 else { settling?.cancel(); return }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            self?.lay()
        }
    }

    /// Lays out the next step of a text longer than what is shown.
    func reveal() {
        guard capped, !laying else { return }
        wanted = shown + Self.step
        lay()
    }

    /// Stops every read and layout, and lets go of the layout.
    func cancel() {
        reading?.cancel(); layoutTask?.cancel(); settling?.cancel()
        generation += 1
        textView?.release()
        changed = nil; showLess = nil
    }

    private func lay() {
        guard loaded, let available else { return }
        let width = style.wrapWidth(available), limit = min(wanted, length)
        if let layout, abs(layout.width - width) < 1, layout.limit == limit { return }
        layoutTask?.cancel(); settling?.cancel()
        generation += 1
        let generation = generation, text = text, style = style
        if !laying { laying = true }
        layoutTask = Task { [weak self] in
            do {
                let laid = try await InspectorTextWorker.shared.layout(text, limit: limit, width: width, style: style)
                guard let self, self.generation == generation else { return }
                self.layoutTask = nil
                self.install(laid)
            } catch {
                guard let self, self.generation == generation, !(error is CancellationError) else { return }
                self.layoutTask = nil
                self.fail(error)
            }
        }
    }

    private func install(_ laid: InspectorLaidOutText) {
        let previous = layout
        // The old view lets go of its layout before its host takes it away.
        textView?.release()
        textView = InspectorTextView(laid, expansion: self)
        layout = laid
        laying = false
        if phase != .shown { phase = .shown }
        changed?(previous)
    }

    private func fail(_ error: Error) {
        laying = false
        phase = .failed(error.localizedDescription)
        changed?(layout)
    }
}

/// The whole text: selectable, never editable, laid out before it arrives.
/// It holds its layout only while it is in a window, and lets go of it before
/// it moves.
final class InspectorTextView: NSTextView {
    let laidOut: InspectorLaidOutText
    private weak var expansion: InspectorExpansion?
    private var released = false

    init(_ laidOut: InspectorLaidOutText, expansion: InspectorExpansion) {
        self.laidOut = laidOut; self.expansion = expansion
        super.init(frame: NSRect(x: 0, y: 0, width: laidOut.width, height: laidOut.height), textContainer: nil)
        // Set before the layout is attached: with it attached, each of these
        // redisplays the whole text.
        isEditable = false; isSelectable = true
        drawsBackground = false
        isVerticallyResizable = false; isHorizontallyResizable = false
        textContainerInset = .zero
        allowsUndo = false; usesFontPanel = false; usesRuler = false
        isAutomaticLinkDetectionEnabled = false
        selectedTextAttributes = [.backgroundColor: NSColor.piTextSelection]
        focusRingType = .none
        setAccessibilityLabel(expansion.title + ", whole text")
        setAccessibilityIdentifier("inspector-whole-text")
    }
    required init?(coder: NSCoder) { nil }

    /// Whether the layout is on this view now.
    var attached: Bool { laidOut.container.textView === self }

    /// Lets go of the layout for good: the view is being replaced or removed.
    func release() {
        released = true
        detach()
    }
    private func detach() { if attached { laidOut.container.textView = nil } }
    private func attach() {
        guard !released, window != nil, superview != nil, !attached else { return }
        laidOut.container.textView = self
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        detach()
        super.viewWillMove(toSuperview: newSuperview)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { detach() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    /// Copy, the whole text, Select All and Show Less, built when it opens.
    override func menu(for event: NSEvent) -> NSMenu? { PiMenus.menu(menuEntries()) }
    func menuEntries() -> [PiMenuEntry] {
        let whole = expansion?.text ?? laidOut.storage.string
        let count = expansion?.length ?? laidOut.characters
        var entries: [PiMenuEntry] = [
            .button("Copy", enabled: selectedRange().length > 0, identifier: "inspector-text-copy") { [weak self] in self?.copy(nil) },
            .button("Copy All " + TranscriptActivity.grouped(Double(count)) + " Characters", identifier: "inspector-text-copy-all") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(whole, forType: .string)
            },
            .button("Select All", identifier: "inspector-text-select-all") { [weak self] in self?.selectAll(nil) },
        ]
        if let showLess = expansion?.showLess {
            entries += [.divider, .button("Show Less", identifier: "inspector-text-show-less") { showLess() }]
        }
        return entries
    }
}

/// A whole text in a SwiftUI page: the Turn page's prompt. It is as tall as
/// its layout, and a new width is laid out on the worker after the update
/// that offered it.
struct InspectorTextBlock: NSViewRepresentable {
    @ObservedObject var expansion: InspectorExpansion

    func makeNSView(context: Context) -> InspectorTextBlockView { InspectorTextBlockView() }
    func updateNSView(_ view: InspectorTextBlockView, context: Context) { view.show(expansion) }
    static func dismantleNSView(_ view: InspectorTextBlockView, coordinator: ()) { view.show(nil) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InspectorTextBlockView, context: Context) -> CGSize? {
        let width = proposal.width ?? expansion.layout?.width ?? 0
        return CGSize(width: width.isFinite ? width : expansion.layout?.width ?? 0, height: expansion.layout?.height ?? 0)
    }
}

/// Hosts an expansion's text view at its top left and tells the expansion the
/// width it has, from AppKit's layout rather than SwiftUI's update.
final class InspectorTextBlockView: NSView {
    private weak var expansion: InspectorExpansion?
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    func show(_ expansion: InspectorExpansion?) {
        self.expansion = expansion
        let view = expansion?.textView
        for case let other as InspectorTextView in subviews where other !== view { other.removeFromSuperview() }
        if let view, view.superview !== self { addSubview(view) }
        needsLayout = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        let wider = newSize.width != frame.width
        super.setFrameSize(newSize)
        if wider { needsLayout = true }
    }
    override func layout() {
        super.layout()
        guard let expansion else { return }
        if let view = expansion.textView, view.superview === self {
            let frame = NSRect(x: 0, y: 0, width: view.laidOut.width, height: view.laidOut.height)
            if view.frame != frame { view.frame = frame }
        }
        expansion.offer(width: bounds.width)
    }
}
