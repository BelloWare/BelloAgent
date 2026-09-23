import AppKit
import SwiftUI

/// A long reply retains every block and its measured or provisional height, while only the part
/// near the outer conversation viewport participates in native scrolling.
/// This is not another scroll view and does not truncate the source or copy
/// targets. Small replies keep the simpler SwiftUI stack.
struct NativeMarkdownSurface: NSViewRepresentable {
    nonisolated static let minimumBlockCount = 8
    /// The message's markdown source. The surface reads it itself, so a token
    /// can extend the reply without SwiftUI rebuilding anything: the row's
    /// tree is untouched and only the block still open is read and measured
    /// again. Nothing here parses inside a view body.
    let source: String
    let style: MarkdownStyle
    let capsWidth: Bool
    let streaming: Bool
    let headings: [MarkdownCopyTarget]
    /// Which reply this is, so a token can be handed to the surface that is
    /// carrying it.
    var identity: String = ""

    func makeNSView(context: Context) -> NativeMarkdownContainer {
        let view = NativeMarkdownContainer()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: NativeMarkdownContainer, context: Context) {
        view.read(source: source, style: style, capsWidth: capsWidth, streaming: streaming, headings: headings,
                  environment: TranscriptRowEnvironment(context.environment), identity: identity)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeMarkdownContainer, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width)
    }
}

private struct NativeMarkdownItem: Equatable {
    var block: MarkdownBlock
    var style: MarkdownStyle
    var capsWidth: Bool
    var caret: Bool
    var headingTarget: MarkdownCopyTarget?
    var environment: TranscriptRowEnvironment

    func hasSameGeometry(as other: Self) -> Bool {
        guard block == other.block, style == other.style, capsWidth == other.capsWidth,
              environment.hasSameGeometry(as: other.environment) else { return false }
        // Code switches from a continuous stream to bounded source sections
        // at completion. That is a local layout dependency, unlike a caret.
        if case .code = block { return caret == other.caret }
        return true
    }
}

private struct NativeHostedMarkdownBlock: View {
    let item: NativeMarkdownItem
    let width: CGFloat
    let decoration: MarkdownBlockDecoration
    var nativeCodeChoice: Bool? = nil
    /// The scale the block is drawn at, for a host measured before its
    /// surface has a window: SwiftUI would otherwise lay the text out at 1x,
    /// taller than it draws, and the block would carry the difference as blank.
    var displayScale: CGFloat = 2
    var body: some View {
        MarkdownBlockView(block: item.block, style: item.style, capsWidth: item.capsWidth,
                          caret: item.caret, headingTarget: nil, nativeCodeChoice: nativeCodeChoice, decoration: decoration)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .environment(\.colorScheme, item.environment.colorScheme)
            .environment(\.dynamicTypeSize, item.environment.dynamicTypeSize)
            .environment(\.layoutDirection, item.environment.layoutDirection)
            .environment(\.locale, item.environment.locale)
            .environment(\.displayScale, displayScale)
            .disabled(!item.environment.isEnabled)
            .piStableLayout()
    }
}

@MainActor private final class NativeMarkdownBlockHost {
    private(set) var view: NSHostingView<NativeHostedMarkdownBlock>?
    private var item: NativeMarkdownItem
    private var nativeCodeChoice: Bool?
    private let decoration: MarkdownBlockDecoration
    private weak var selectionEditor: NSTextView?
    private var restoredSelection: (range: NSRange, original: NSRange, rendered: String)?
    private var selectionRevision = 0
    private var reconciliation: MarkdownSelection.Reconciliation?
    private var width: CGFloat = TranscriptMetrics.pageWidth
    private var sizes: [CGSize] = []
    var frame = CGRect.zero
    private(set) var measurementCount = 0
    var displayScale: CGFloat = 2 {
        didSet {
            guard displayScale != oldValue else { return }
            sizes.removeAll(keepingCapacity: true)
            view?.rootView = hosted
        }
    }
    private var hosted: NativeHostedMarkdownBlock {
        NativeHostedMarkdownBlock(item: item, width: width, decoration: decoration, nativeCodeChoice: nativeCodeChoice, displayScale: displayScale)
    }

    init(item: NativeMarkdownItem) {
        self.item = item
        decoration = MarkdownBlockDecoration(caret: item.caret, target: item.headingTarget)
        if case .code(_, let code) = item.block {
            nativeCodeChoice = NativeCodeText.enabled && (item.caret || code.utf8.count >= NativeCodeText.minimumBytes)
        } else { nativeCodeChoice = nil }
    }
    private func host() -> NSHostingView<NativeHostedMarkdownBlock> {
        if let view { return view }
        let next = NSHostingView(rootView: hosted)
        next.safeAreaRegions = []; next.sizingOptions = [.intrinsicContentSize]
        view = next; applyAppearance()
        return next
    }
    /// Geometry and source outlive the expensive native tree. No sizing
    /// surrogate is shared, and a selected owner is excluded by the caller.
    func releaseDetachedHost() { if view?.superview == nil { view = nil } }
    /// Whether this is the block a streaming reply is still being written into.
    var hasCaret: Bool { item.caret }
    @discardableResult func update(_ item: NativeMarkdownItem,
                                  source: () -> (previous: MarkdownSelection.Source?, current: MarkdownSelection.Source)? = { nil }) -> Bool {
        guard self.item != item else { return false }
        decoration.update(caret: item.caret, target: item.headingTarget)
        guard !self.item.hasSameGeometry(as: item) else {
            // A colour scheme, a contrast or an enabled state: painted again,
            // measured the same.
            let repaint = self.item.environment != item.environment
            self.item = item
            if repaint {
                view?.rootView = hosted
                applyAppearance()
            }
            return false
        }
        selectionRevision &+= 1
        restoredSelection = nil; selectionEditor = nil
        if case .paragraph(let oldText) = self.item.block, case .paragraph(let newText) = item.block {
            let old = String(oldText.characters), new = String(newText.characters)
            if !new.hasUTF8Prefix(old) {
                reconciliation = source().map {
                    MarkdownSelection.Reconciliation(previous: old, source: $0.current, previousSource: $0.previous,
                                                     rendered: new, keepsSoftBreaks: item.style.keepsSoftBreaks)
                }
            }
            if let editor = view?.window?.firstResponder as? NSTextView,
               textOwners.contains(where: { ($0 as? NSTextField)?.currentEditor() === editor }),
               !new.hasUTF8Prefix(old), let range = reconciliation?.range(editor.selectedRange()) {
                selectionEditor = editor
                restoredSelection = (range, editor.selectedRange(), new)
            }
        }
        // Retain the mounted leaf decision across idle host reclamation. A
        // completed short fence that began live must recreate the same TextKit
        // renderer, so its cached exact height still describes the new host.
        if case .code(_, let code) = item.block {
            if case .code = self.item.block {} else {
                nativeCodeChoice = NativeCodeText.enabled && (item.caret || code.utf8.count >= NativeCodeText.minimumBytes)
            }
        } else { nativeCodeChoice = nil }
        self.item = item
        sizes.removeAll(keepingCapacity: true)
        view?.rootView = hosted
        applyAppearance()
        // The field editor is updated by SwiftUI after the hosting root. A
        // bounded next-run-loop correction preserves the same editor without
        // replacing its contents or taking focus from a newer reader gesture.
        scheduleSelectionRestore(revision: selectionRevision, remaining: 2)
        return true
    }
    private func applyAppearance() {
        // colorSchemeContrast is read-only in SwiftUI's public environment.
        // The native appearance carries contrast across this hosting boundary.
        let dark = item.environment.colorScheme == .dark
        let increased = item.environment.contrast == .increased
        let name: NSAppearance.Name = increased ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua)
        view?.appearance = NSAppearance(named: name)
    }
    func estimate(width: CGFloat) -> CGFloat {
        switch item.block {
        case .paragraph(let text): return TranscriptRowEstimate.prose(String(text.characters), width: min(width, TranscriptMetrics.proseWidth), size: item.style.baseSize)
        case .heading(let level, let text, _): return TranscriptRowEstimate.prose(String(text.characters), width: width, size: item.style.baseSize * (level == 1 ? 1.5 : 1.3)) + 10
        case .code(_, let code): return min(12_000, CGFloat(code.utf8.filter { $0 == 10 }.count + 1) * 18 + 40)
        case .table(_, _, let rows): return CGFloat(rows.count + 1) * 28 + 20
        case .list(_, _, let items): return CGFloat(items.count) * 40
        case .quote(let blocks): return CGFloat(blocks.count) * 60
        }
    }
    /// This block's exact size at a width. Measured in `surface`'s window when
    /// it has one: detached, SwiftUI lays text out as if at 1x — even told the
    /// display's scale, a line lands half a point apart — which is taller
    /// than it draws, and the block would carry the difference as blank.
    func measure(width: CGFloat, in surface: NSView? = nil) -> CGSize {
        if let cached = sizes.last(where: { $0.width == width }) { return cached }
        if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownBlocksMeasured += 1 }
        setWidth(width)
        let view = host()
        let visiting = surface?.window != nil && view.superview == nil
        if visiting, let surface { surface.addSubview(view) }
        defer { if visiting { view.removeFromSuperview() } }
        // Exact: SwiftUI lays text out on the pixel grid, and rounding to
        // half a point only drops the arithmetic's noise. The page rounds the
        // bottom of each block, or of a list drawn in segments, to a whole
        // point below it; the host is exactly as tall as what it draws.
        let size = CGSize(width: width, height: max(1, (view.fittingSize.height * 2).rounded() / 2))
        if sizes.count == 4 { sizes.removeFirst() }
        sizes.append(size)
        measurementCount += 1
        restoreSelection()
        return size
    }
    struct CharacterAnchor: Equatable { var owner: Int; var range: NSRange; var displacement: CGFloat; var rendered: String }
    private var textOwners: [NSView] {
        func visit(_ view: NSView) -> [NSView] {
            if view is NSTextView || view is NSTextField { return [view] }
            return view.subviews.flatMap { visit($0) }
        }
        return view.map { visit($0) } ?? []
    }
    func characterAnchor(in surface: NSView, viewportTop: CGFloat) -> CharacterAnchor? {
        // Cached exact descriptors can outlive a detached native host. Its
        // accessibility rectangles are not in this surface's current geometry.
        guard let view, view.superview === surface, view.frame == frame,
              let window = surface.window else { return nil }
        for (ordinal, owner) in textOwners.enumerated() where owner.window === window {
            let rect = surface.convert(owner.bounds, from: owner)
            guard viewportTop >= rect.minY, viewportTop < rect.maxY else { continue }
            let screen = window.convertPoint(toScreen: surface.convert(NSPoint(x: rect.minX + 2, y: viewportTop + 2), to: nil))
            var range = owner.accessibilityRange(for: screen)
            // SwiftUI's selectable NSTextField exposes character rectangles,
            // but its point-to-range API returns an empty insertion range.
            // Search those actual AppKit layout rectangles by line, rather
            // than estimating a character from bytes, height, or line count.
            if range.length == 0, let field = owner as? NSTextField {
                let source = field.stringValue as NSString
                var lower = 0, upper = source.length
                while lower < upper {
                    let probe = source.rangeOfComposedCharacterSequence(at: lower + (upper - lower) / 2)
                    let frame = owner.accessibilityFrame(for: probe)
                    guard !frame.isEmpty else { break }
                    let local = surface.convert(window.convertFromScreen(frame), from: nil)
                    if local.maxY <= viewportTop + 2 { lower = NSMaxRange(probe) }
                    else { upper = max(lower, probe.location) }
                }
                if lower < source.length { range = source.rangeOfComposedCharacterSequence(at: lower) }
            }
            guard range.location != NSNotFound, range.length > 0 else { continue }
            let screenRect = owner.accessibilityFrame(for: range)
            guard !screenRect.isEmpty else { continue }
            let local = surface.convert(window.convertFromScreen(screenRect), from: nil)
            return CharacterAnchor(owner: ordinal, range: range, displacement: local.minY - viewportTop, rendered: (owner as? NSTextField)?.stringValue ?? (owner as? NSTextView)?.string ?? "")
        }
        return nil
    }
    func characterTop(_ anchor: CharacterAnchor, in surface: NSView) -> CGFloat? {
        guard let view, view.superview === surface, view.frame == frame,
              let owner = textOwners.indices.contains(anchor.owner) ? textOwners[anchor.owner] : nil,
              let window = surface.window, owner.window === window else { return nil }
        let rendered = (owner as? NSTextField)?.stringValue ?? (owner as? NSTextView)?.string ?? ""
        let range: NSRange
        if !rendered.hasUTF8Prefix(anchor.rendered), let mapped = reconciliation?.range(anchor.range, from: anchor.rendered, to: rendered) {
            range = mapped
        } else { range = anchor.range }
        let screen = owner.accessibilityFrame(for: range)
        guard !screen.isEmpty else { return nil }
        return surface.convert(window.convertFromScreen(screen), from: nil).minY - anchor.displacement
    }
    func exactMeasurement(width: CGFloat) -> CGSize? { sizes.last { $0.width == width } }
    func setWidth(_ width: CGFloat) {
        guard self.width != width else { return }
        self.width = width
        view?.rootView = hosted
    }
    func place(in container: NSView) {
        setWidth(frame.width)
        let view = host()
        if view.frame != frame { view.frame = frame }
        if view.superview !== container { container.addSubview(view) }
        restoreSelection()
    }
    private func restoreSelection() {
        guard let selection=restoredSelection, let editor=selectionEditor,
              view?.window?.firstResponder === editor else { return }
        // Do not modify attributed content or take first responder away from
        // the user. SwiftUI owns the text update; we restore only its selection.
        guard editor.string == selection.rendered else { return }
        let length = editor.string.utf16.count
        let clippedStart = min(selection.original.location, length)
        let clipped = NSRange(location: clippedStart, length: min(selection.original.length, length - clippedStart))
        guard [selection.original, selection.range, clipped].contains(editor.selectedRange()) else {
            restoredSelection = nil; selectionEditor = nil
            return
        }
        editor.setSelectedRange(selection.range); restoredSelection=nil; selectionEditor=nil
    }
    private func scheduleSelectionRestore(revision: Int, remaining: Int) {
        guard restoredSelection != nil, remaining > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectionRevision == revision else { return }
            self.restoreSelection()
            self.scheduleSelectionRestore(revision: revision, remaining: remaining - 1)
        }
    }
}

@MainActor final class NativeMarkdownContainer: NSView {
    /// How many items of a list one block host draws. A longer list is drawn
    /// as consecutive segments of this many items, spaced as its items are, so
    /// a token on its last item rebuilds and measures one segment, not the
    /// list. A test seam: `.max` draws every list whole.
    static var listSegmentLength = 16
    /// The space between two blocks, and between two segments of one list,
    /// which is the space between the list's items.
    static let blockSpacing: CGFloat = 10
    static let listItemSpacing: CGFloat = 4
    private final class Layout {
        let width: CGFloat
        /// Each block's exact height, and the space above it as this layout
        /// added it up: the spacing, and after a block — or a list drawn in
        /// segments — whatever takes its bottom to a whole point.
        var heights: [CGFloat] = []
        var gaps: [CGFloat] = []
        /// That rounding after the last block.
        var trailing: CGFloat = 0
        var total: CGFloat = 0
        var validPrefix = 0
        var provisional: Set<Int> = []
        /// No provisional block is at or past this index.
        var provisionalBound = 0
        init(width: CGFloat) { self.width = width }
        func insertProvisional(_ index: Int) { provisional.insert(index); provisionalBound = max(provisionalBound, index + 1) }
        /// Drops what a change from `index` on has made stale.
        func invalidate(from index: Int) {
            validPrefix = min(validPrefix, index)
            if provisionalBound > index { provisional = provisional.filter { $0 < index }; provisionalBound = index }
        }
    }
    /// One block as drawn: a record of the reading, or one segment of a long list in it.
    private struct Placement {
        var identity: MarkdownBlockIdentity
        var range: Range<Int>?
        var heading: Bool
        /// Drawn as one of several segments of a list.
        var segmented: Bool
        /// Continues the list the block above began: it sits as far below it
        /// as the list's items sit from each other, and the list's bottom is
        /// rounded to a whole point only after its last segment.
        var continues: Bool
    }
    /// What an update draws with besides the blocks: when these are what the
    /// last update drew with, the blocks it did not change keep their hosts.
    private struct Inputs: Equatable {
        var style: MarkdownStyle
        var capsWidth: Bool
        var streaming: Bool
        var headings: [MarkdownCopyTarget]
        var environment: TranscriptRowEnvironment
    }
    private var blocks: [NativeMarkdownBlockHost] = []
    private var placements: [Placement] = []
    /// Which block an identity is, where each record of the reading begins
    /// among the blocks, and how many headings come before each block.
    private var positions: [MarkdownBlockIdentity: Int] = [:]
    private var recordStarts: [Int] = [0]
    private var headingsBefore: [Int] = [0]
    private var lastInputs: Inputs?
    /// Whether the last update drew this surface's own reading, whose
    /// unchanged prefix the next one can then take on trust.
    private var drewReading = false
    private var priorSourceText: String?
    var blockOwnerIdentities: [ObjectIdentifier] { blocks.map(ObjectIdentifier.init) }
    private var layouts: [Layout] = []
    private var laidOutWidth: CGFloat?
    private var layoutDirtyFrom: Int? = 0
    private(set) var aggregateMeasurementVisits = 0
    private(set) var framePlacements = 0
    /// Blocks the last update compared with what they were: a token's should
    /// not grow with the reply.
    private(set) var reconciledBlockVisits = 0
    private var invalidationScheduled = false
    private var applyingLayout = false
    private var resolvingViewport = false
    /// Deterministic native regression seam between measuring a viewport and
    /// the hosting parent's deferred intrinsic-height adoption.
    var didPrepareVisibleBlocks: (() -> Void)?
    var willPrepareVisibleBlocks: (() -> Void)?
    var didDrawPreparedContent: (() -> Void)?
    private var resolveScheduled = false
    private var loadingSection: NSProgressIndicator?
    /// The hosts in the view tree, and the ones with a native tree out of it,
    /// which the idle scheduler reclaims once they are far from the viewport.
    private var mountedHosts: [ObjectIdentifier: NativeMarkdownBlockHost] = [:]
    private var detachedHosts: [ObjectIdentifier: NativeMarkdownBlockHost] = [:]
    var hasProvisionalGeometry: Bool { layouts.last?.provisional.isEmpty == false }
    var visibleContentPrepared: Bool {
        guard let clip = observedClip, let layout = layouts.last(where: { $0.width == bounds.width }) else { return blocks.isEmpty }
        let viewport = convert(clip.bounds, from: clip)
        guard !resolveScheduled else { return false }
        return !onScreen(viewport).contains { layout.provisional.contains($0) }
    }
    var provisionalBlockCount: Int { layouts.last?.provisional.count ?? 0 }
    /// A logical source/block identity, independent of estimated row heights.
    struct LogicalAnchor: Equatable { var block: MarkdownBlockIdentity; var offset: CGFloat; fileprivate var character: NativeMarkdownBlockHost.CharacterAnchor? = nil; var sourceUTF16Range: NSRange? { character?.range } }
    var logicalAnchor: LogicalAnchor? {
        guard let clip = observedClip else { return nil }
        let y = convert(clip.bounds, from: clip).minY
        let index = firstBlock(below: y)
        guard index < blocks.count else { return nil }
        return LogicalAnchor(block: placements[index].identity, offset: blocks[index].frame.minY - y)
    }
    var preparedLogicalAnchor: LogicalAnchor? {
        guard let clip = observedClip else { return nil }
        let viewport = convert(clip.bounds, from: clip)
        guard let index = onScreen(viewport).first(where: { blocks[$0].exactMeasurement(width: bounds.width) != nil }) else { return nil }
        return LogicalAnchor(block: placements[index].identity, offset: blocks[index].frame.minY - viewport.minY,
                             character: blocks[index].characterAnchor(in: self, viewportTop: viewport.minY))
    }
    func displacement(of anchor: LogicalAnchor) -> CGFloat? {
        guard let clip = observedClip, let top = top(for: anchor) else { return nil }
        return top - convert(clip.bounds, from: clip).minY
    }
    private weak var observedClip: NSClipView?
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var frameObservers: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: layouts.last(where: { $0.width == bounds.width && $0.validPrefix == blocks.count && $0.heights.count == blocks.count })?.total ?? NSView.noIntrinsicMetric)
    }
    /// Evidence for regressions: pure scrolling must reuse exact measurements.
    var blockMeasurementCount: Int { blocks.reduce(0) { $0 + $1.measurementCount } }
    var retainedBlockCount: Int { blocks.count }
    var hostedBlockCount: Int { blocks.reduce(0) { $0 + ($1.view == nil ? 0 : 1) } }
    var mountedBlockCount: Int { blocks.reduce(0) { $0 + ($1.view?.superview === self ? 1 : 0) } }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The reading of this message, owned here rather than by a view body, so
    /// that a token can extend it without SwiftUI running at all.
    private let reading = StreamingMarkdownState()
    private var readingContext: (style: MarkdownStyle, capsWidth: Bool, streaming: Bool, headings: [MarkdownCopyTarget],
                                 environment: TranscriptRowEnvironment, identity: String)?
    /// Which reply this surface carries, for the row handing it a token.
    var readingIdentity: String? { readingContext?.identity }
    /// How many tokens this surface has taken without SwiftUI rebuilding the
    /// row, and how many blocks each of them had to read again.
    private(set) var appendCount = 0
    private var appending = false

    /// The message as it stands. Called by SwiftUI when anything other than
    /// the arriving text changes: the appearance, the width, the reply
    /// settling, the reader opening something.
    func read(source: String, style: MarkdownStyle, capsWidth: Bool, streaming: Bool,
              headings: [MarkdownCopyTarget], environment: TranscriptRowEnvironment, identity: String) {
        // A token can reach this surface directly, ahead of the view that
        // carries the same text. A view update that is a token behind must not
        // rewind the reading — that would throw away every block of it and
        // rebuild the lot. While a reply arrives its text only grows, so the
        // longer of the two is the one to read, and everything else in the
        // update (the appearance, the width, the copy targets) still applies.
        var source = source
        if streaming, identity == readingContext?.identity, source != reading.source, reading.source.hasUTF8Prefix(source) {
            source = reading.source
        }
        let sameReply = readingContext?.identity == identity
        readingContext = (style, capsWidth, streaming, headings, environment, identity)
        let readingStarted = TranscriptLayoutClock.recording && appending ? TranscriptLayoutClock.now : 0
        let records = reading.update(source, style: style, streaming: streaming, identity: identity)
        if readingStarted > 0 { TranscriptLayoutClock.markdownReadingSeconds += TranscriptLayoutClock.now - readingStarted }
        reconcile(records, unchangedPrefix: drewReading && sameReply ? reading.unchangedPrefix : 0, sourceText: source,
                  inputs: Inputs(style: style, capsWidth: capsWidth, streaming: streaming, headings: headings, environment: environment))
        drewReading = true
    }
    /// A token arrived: this reply's text grew by a suffix. The block still
    /// open is read again and measured again; every block above it keeps the
    /// exact height it already had, and no SwiftUI tree is rebuilt. Returns
    /// how much taller the message became, or nil when this surface is not
    /// the one carrying that reply.
    func appendStreaming(_ next: String, identity: String) -> CGFloat? {
        let appendStarted = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownAppendSeconds += TranscriptLayoutClock.now - appendStarted } }
        // A pass already running owns this geometry: a block being prepared
        // for the viewport is part way through re-placing every block. Such a
        // token takes the ordinary path rather than changing the ground under
        // that pass.
        guard let context = readingContext, context.streaming, context.identity == identity, !identity.isEmpty,
              bounds.width > 0, !applyingLayout, !resolvingViewport,
              next.utf8.count > reading.source.utf8.count, !reading.source.isEmpty, next.hasUTF8Prefix(reading.source) else { return nil }
        let before = exactLayout(width: bounds.width).total
        appending = true
        read(source: next, style: context.style, capsWidth: context.capsWidth, streaming: true,
             headings: context.headings, environment: context.environment, identity: identity)
        appending = false
        let after = exactLayout(width: bounds.width).total
        if abs(bounds.height - after) > 0.01 { setFrameSize(NSSize(width: bounds.width, height: after)) }
        // The blocks are placed by this surface's own layout, in the pass the
        // page is already about to run: the page has the new height now, from
        // the measurement above, and the reader's position is corrected in
        // that same pass rather than a frame later.
        needsLayout = true
        appendCount += 1
        return after - before
    }

    func update(blocks source: [MarkdownBlock], style: MarkdownStyle, capsWidth: Bool, streaming: Bool,
                headings: [MarkdownCopyTarget], environment: TranscriptRowEnvironment, identities: [MarkdownBlockIdentity]? = nil, sourceText: String? = nil, sourceRanges: [Range<Int>]? = nil) {
        let ids = identities?.count == source.count ? identities! : source.indices.map { MarkdownBlockIdentity(generation: 0, sourceOffset: $0) }
        let records = source.indices.map { index in
            StreamingMarkdownRecord(id: ids[index], range: sourceRanges.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? 0..<0,
                                    block: source[index], provisional: false)
        }
        drewReading = false
        reconcile(records, unchangedPrefix: 0, sourceText: sourceText, hasRanges: sourceRanges != nil,
                  inputs: Inputs(style: style, capsWidth: capsWidth, streaming: streaming, headings: headings, environment: environment))
    }

    /// Draws `records`: every one, a long list as segments. The records before
    /// `unchangedPrefix` are the ones the last update drew, unchanged, so their
    /// blocks keep their hosts without being looked at; the last of them is
    /// compared again, since it may have just stopped being the reply's last
    /// block and so lost its caret. Everything after is matched by identity,
    /// so a block keeps its host, its selection and its exact heights.
    private func reconcile(_ records: [StreamingMarkdownRecord], unchangedPrefix: Int, sourceText: String?, hasRanges: Bool = true, inputs: Inputs) {
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownUpdateSeconds += TranscriptLayoutClock.now - clock } }
        enclosingScrollView?.transcriptReading.capture(self)
        let keep = inputs == lastInputs ? max(0, min(unchangedPrefix, recordStarts.count - 1, records.count) - 1) : 0
        let keepBlocks = recordStarts[keep]
        // The blocks from `keep` on: identities made unique, a duplicate
        // taking the next component, and a long list cut into segments.
        var drawn: [(block: MarkdownBlock, placement: Placement)] = []
        var starts: [Int] = []
        var seen = Set<MarkdownBlockIdentity>()
        let length = max(1, Self.listSegmentLength)
        for index in keep..<records.count {
            let record = records[index]
            var id = record.id
            while !seen.insert(id).inserted || (positions[id].map { $0 < keepBlocks } ?? false) { id.component += 1 }
            starts.append(keepBlocks + drawn.count)
            let range: Range<Int>? = hasRanges ? record.range : nil
            if case .list(let ordered, let start, let items) = record.block, items.count > length {
                var first = 0, segment = 0
                while first < items.count {
                    let last = min(items.count, first + length)
                    var part = id; part.segment = segment
                    drawn.append((.list(ordered: ordered, start: start + first, items: Array(items[first..<last])),
                                  Placement(identity: part, range: range, heading: false, segmented: true, continues: segment > 0)))
                    first = last; segment += 1
                }
            } else {
                var heading = false
                if case .heading = record.block { heading = true }
                drawn.append((record.block, Placement(identity: id, range: range, heading: heading, segmented: false, continues: false)))
            }
        }
        let oldCount = blocks.count, count = keepBlocks + drawn.count
        var old: [MarkdownBlockIdentity: Int] = [:]
        for index in keepBlocks..<oldCount { old[placements[index].identity] = index }
        var changedFrom = count == oldCount ? count : min(count, oldCount)
        var next: [NativeMarkdownBlockHost] = []
        next.reserveCapacity(drawn.count)
        var headingIndex = headingsBefore[keepBlocks]
        let scale = displayScale
        var nextHeadings: [Int] = []
        nextHeadings.reserveCapacity(drawn.count + 1)
        for (offset, entry) in drawn.enumerated() {
            let index = keepBlocks + offset
            nextHeadings.append(headingIndex)
            var target: MarkdownCopyTarget?
            if entry.placement.heading {
                if inputs.headings.indices.contains(headingIndex) { target = inputs.headings[headingIndex] }
                headingIndex += 1
            }
            let item = NativeMarkdownItem(block: entry.block, style: inputs.style, capsWidth: inputs.capsWidth,
                                          caret: inputs.streaming && index == count - 1, headingTarget: target, environment: inputs.environment)
            reconciledBlockVisits += 1
            if let prior = old.removeValue(forKey: entry.placement.identity) {
                let host = blocks[prior], was = placements[prior]
                let range = entry.placement.range, priorSource = priorSourceText
                let updated = host.update(item, source: {
                    guard let sourceText, let range, let current = MarkdownSelection.Source(sourceText, bytes: range) else { return nil }
                    let previous = priorSource.flatMap { text in was.range.flatMap { MarkdownSelection.Source(text, bytes: $0) } }
                    return (previous, current)
                })
                host.displayScale = scale
                if updated || prior != index || was.continues != entry.placement.continues || was.segmented != entry.placement.segmented {
                    changedFrom = min(changedFrom, index)
                }
                next.append(host)
            } else {
                let host = NativeMarkdownBlockHost(item: item)
                host.displayScale = scale
                next.append(host)
                changedFrom = min(changedFrom, index)
            }
        }
        nextHeadings.append(headingIndex)
        // Hosts no longer drawn leave the view tree and every list of them.
        for (_, index) in old {
            let host = blocks[index]
            host.view?.removeFromSuperview()
            mountedHosts[ObjectIdentifier(host)] = nil; detachedHosts[ObjectIdentifier(host)] = nil
        }
        for index in keepBlocks..<oldCount where positions[placements[index].identity] == index { positions[placements[index].identity] = nil }
        blocks.replaceSubrange(keepBlocks..., with: next)
        placements.replaceSubrange(keepBlocks..., with: drawn.map(\.placement))
        headingsBefore.replaceSubrange(keepBlocks..., with: nextHeadings)
        recordStarts.replaceSubrange(keep..., with: starts + [count])
        for index in keepBlocks..<count { positions[placements[index].identity] = index }
        priorSourceText = sourceText
        lastInputs = inputs
        guard changedFrom < count || oldCount != count else { return }
        // Completed blocks retain their exact width-specific heights. Only the
        // changed suffix participates in aggregate sizing and frame placement.
        for layout in layouts { layout.invalidate(from: changedFrom) }
        layoutDirtyFrom = min(layoutDirtyFrom ?? changedFrom, changedFrom)
        needsLayout = true
        // A token's own pass has already told the row how much taller the
        // message became, and the row has already had the page placed around
        // it. Advertising a new intrinsic size here would put the whole row
        // through SwiftUI a second time for the same text.
        guard !appending else { return }
        // Input changes can arrive during a parent's fittingSize pass. Let
        // SwiftUI finish that update before advertising a new intrinsic size.
        guard !invalidationScheduled else { return }
        invalidationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidationScheduled = false
            self.invalidateIntrinsicContentSize()
        }
    }

    /// The scale this surface draws at, or will once it is in a window.
    private var displayScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    /// Drawn at a new scale: every block is measured again at it.
    private func adoptDisplayScale() {
        let scale = displayScale
        guard blocks.contains(where: { $0.displayScale != scale }) else { return }
        for block in blocks { block.displayScale = scale }
        layouts.removeAll(); laidOutWidth = nil; layoutDirtyFrom = 0
        needsLayout = true
        invalidateIntrinsicContentSize()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        adoptDisplayScale()
    }
    /// What takes the bottom of the run of blocks ending at `index` — one
    /// block, or every segment of one list — to a whole point.
    private func rounding(afterRunEndingAt index: Int, _ layout: Layout) -> CGFloat {
        var bottom = layout.heights[index], block = index
        while block > 0, placements[block].continues { bottom += layout.gaps[block] + layout.heights[block - 1]; block -= 1 }
        return max(0, (bottom - 0.001).rounded(.up) - bottom)
    }

    private func exactLayout(width: CGFloat) -> Layout {
        let layout: Layout
        if let cached = layouts.last(where: { $0.width == width }) { layout = cached }
        else {
            layout = Layout(width: width)
            if layouts.count == 4 { layouts.removeFirst() }
            layouts.append(layout)
        }
        guard layout.validPrefix < blocks.count || layout.heights.count != blocks.count else { return layout }
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownLayoutSeconds += TranscriptLayoutClock.now - clock } }
        let prefix = min(layout.validPrefix, blocks.count, layout.heights.count)
        layout.total -= layout.heights[prefix...].reduce(0, +) + layout.gaps[prefix...].reduce(0, +) + layout.trailing
        layout.heights.removeSubrange(prefix...); layout.gaps.removeSubrange(prefix...); layout.trailing = 0
        for index in prefix..<blocks.count {
            let block = blocks[index]
            // Descriptor estimates never enter a shared exact-size cache.
            // A giant message prepares a few blocks, then only the viewport.
            let known = block.exactMeasurement(width: width)
            // The block a streaming reply is still being written into is the
            // one the reader is watching, and a token has just changed it: it
            // is measured, never stood at an estimate the row would then carry
            // until its next full measurement.
            let deferred = known == nil && blocks.count > 32 && index >= 6 && block.view?.superview == nil && !block.hasCaret
            var height: CGFloat
            if let known { height = known.height }
            else if deferred { height = max(20, block.estimate(width: width)) }
            else {
                height = block.measure(width: width, in: self).height
                if block.view?.superview !== self { detachedHosts[ObjectIdentifier(block)] = block }
            }
            if deferred { layout.insertProvisional(index) } else { layout.provisional.remove(index) }
            // A segment sits below the one before it as the list's items sit
            // from each other; any other block below the whole point the run
            // above it ends on.
            let gap = index == 0 ? 0 : placements[index].continues ? Self.listItemSpacing
                : Self.blockSpacing + rounding(afterRunEndingAt: index - 1, layout)
            layout.heights.append(height); layout.gaps.append(gap); layout.total += height + gap
            aggregateMeasurementVisits += 1
        }
        layout.trailing = blocks.isEmpty ? 0 : rounding(afterRunEndingAt: blocks.count - 1, layout)
        layout.total += layout.trailing
        layout.validPrefix = blocks.count
        return layout
    }

    func measure(width proposed: CGFloat?) -> CGSize {
        if proposed == 0 { return .zero }
        let width = proposed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (bounds.width > 0 ? bounds.width : TranscriptMetrics.pageWidth)
        return CGSize(width: width, height: exactLayout(width: width).total)
    }
    /// Puts every block from `first` down where the layout says it goes.
    private func place(from first: Int, layout: Layout) {
        guard first < blocks.count else { return }
        var y: CGFloat = first > 0 ? blocks[first - 1].frame.maxY + layout.gaps[first] : 0
        for index in first..<blocks.count {
            framePlacements += 1
            blocks[index].frame = CGRect(x: 0, y: y, width: bounds.width, height: layout.heights[index])
            y += layout.heights[index] + (index + 1 < blocks.count ? layout.gaps[index + 1] : 0)
        }
    }
    override func layout() {
        super.layout()
        guard bounds.width > 0, !applyingLayout else { return }
        applyingLayout = true
        defer { applyingLayout = false }
        if laidOutWidth != bounds.width || layoutDirtyFrom != nil {
            let layout = exactLayout(width: bounds.width)
            place(from: laidOutWidth == bounds.width ? min(layoutDirtyFrom ?? 0, blocks.count) : 0, layout: layout)
            laidOutWidth = bounds.width; layoutDirtyFrom = nil
        }
        bindViewport()
        enclosingScrollView?.transcriptReading.geometryChanged()
        mountVisibleBlocks()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { adoptDisplayScale() }
        bindViewport()
        mountVisibleBlocks()
    }
    override func viewWillDraw() {
        super.viewWillDraw()
        enclosingScrollView?.transcriptReading.restore()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        didDrawPreparedContent?()
    }
    private func bindViewport() {
        let clip = enclosingScrollView?.contentView
        guard observedClip !== clip else { return }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
        frameObservers = []
        boundsObserver = nil; observedClip = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mountVisibleBlocks() }
        }
        // A hosting ancestor can adopt its new intrinsic height without
        // relaying out this already-sized child. Its coordinate rebase still
        // changes the text under the viewport, so observe just this chain.
        var ancestor = superview
        while let view = ancestor, view !== clip {
            view.postsFrameChangedNotifications = true
            frameObservers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFrameCorrection() }
            })
            ancestor = view.superview
        }
    }
    private func scheduleFrameCorrection() { enclosingScrollView?.transcriptReading.geometryChanged() }

    /// The first block reaching below `y`. The blocks are placed top to
    /// bottom, so finding it is a bisection, not a walk down the reply.
    private func firstBlock(below y: CGFloat) -> Int {
        var low = 0, high = min(blocks.count, layoutDirtyFrom ?? blocks.count)
        while low < high {
            let middle = (low + high) / 2
            if blocks[middle].frame.maxY > y { high = middle } else { low = middle + 1 }
        }
        return low
    }
    /// The blocks in `rect`: the placed ones found by bisection, and any not
    /// yet placed since the last change, by where they stood.
    private func onScreen(_ rect: CGRect) -> [Int] {
        guard !rect.isNull, !blocks.isEmpty else { return [] }
        let placed = min(blocks.count, layoutDirtyFrom ?? blocks.count)
        var result: [Int] = []
        var index = firstBlock(below: rect.minY)
        while index < placed, blocks[index].frame.minY < rect.maxY {
            if blocks[index].frame.intersects(rect) { result.append(index) }
            index += 1
        }
        for index in placed..<blocks.count where blocks[index].frame.intersects(rect) { result.append(index) }
        return result
    }

    private func resolveVisibleBlocks(in viewport: CGRect) {
        guard !resolvingViewport, !viewport.isNull, let layout = layouts.last(where: { $0.width == bounds.width }),
              !layout.provisional.isEmpty else { return }
        let candidates = onScreen(viewport).filter { layout.provisional.contains($0) }
        guard !candidates.isEmpty else { loadingSection?.removeFromSuperview(); return }
        if candidates.count > 4 {
            let spinner = loadingSection ?? NSProgressIndicator()
            spinner.style = .spinning; spinner.controlSize = .small; spinner.isIndeterminate = true
            spinner.setAccessibilityLabel("Preparing this section")
            spinner.frame = CGRect(x: 8, y: max(viewport.minY + 8, blocks[candidates[4]].frame.minY), width: 16, height: 16)
            if spinner.superview == nil { addSubview(spinner) }
            spinner.startAnimation(nil); loadingSection = spinner
        } else { loadingSection?.stopAnimation(nil); loadingSection?.removeFromSuperview() }
        resolvingViewport = true
        // Several native layout passes can happen before SwiftUI adopts the
        // new intrinsic height. Keep one logical position through that batch,
        // unless the reader has moved the clip in the meantime.
        enclosingScrollView?.transcriptReading.capture(self)
        willPrepareVisibleBlocks?()
        let totalBefore = layout.total
        let prepared = Array(candidates.prefix(4))
        for index in prepared {
            _ = blocks[index].measure(width: bounds.width, in: self)
            if blocks[index].view?.superview !== self { detachedHosts[ObjectIdentifier(blocks[index])] = blocks[index] }
            layout.provisional.remove(index)
        }
        // The layout takes their heights from here down — including where a
        // list drawn in segments now ends — and the blocks are placed again.
        let changedFrom = prepared.min() ?? blocks.count
        layout.validPrefix = min(layout.validPrefix, changedFrom)
        _ = exactLayout(width: bounds.width)
        let resolved = layout.total - totalBefore
        layoutDirtyFrom = min(layoutDirtyFrom ?? changedFrom, changedFrom)
        // Reposition descriptors synchronously, but ask the enclosing hosting
        // row to resize after this native layout callback has returned.
        place(from: changedFrom, layout: layout)
        enclosingScrollView?.transcriptReading.capture(self)
        didPrepareVisibleBlocks?()
        // The row this reply is drawn in is as tall as the rest of it plus
        // this text, so it changes by exactly as much. It hears of it here:
        // nothing the hosting tree reports afterwards reaches it.
        if abs(resolved) > 0.01 {
            var ancestor = superview
            while let view = ancestor, !(view is TranscriptRowContainer) { ancestor = view.superview }
            (ancestor as? TranscriptRowContainer)?.surfaceResolved(resolved)
        }
        enclosingScrollView?.transcriptReading.geometryChanged()
        resolvingViewport = false
        guard !resolveScheduled else { return }
        resolveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resolveScheduled = false
            self.resolvingViewport = true
            self.invalidateIntrinsicContentSize()
            self.needsLayout = true
            self.superview?.layoutSubtreeIfNeeded()
            self.enclosingScrollView?.transcriptReading.geometryChanged()
            self.resolvingViewport = false
            self.mountVisibleBlocks()
        }
    }
    /// The coordinator asks after both descriptor and hosting geometry have
    /// landed. If a block disappeared, use its nearest surviving predecessor,
    /// then successor; never substitute the newest response.
    func top(for anchor: LogicalAnchor) -> CGFloat? {
        let index = positions[anchor.block] ?? placements.lastIndex(where: {
            $0.identity.generation == anchor.block.generation && $0.identity.sourceOffset <= anchor.block.sourceOffset
        }) ?? placements.firstIndex(where: { $0.identity.generation == anchor.block.generation })
        guard let index, blocks.indices.contains(index) else { return nil }
        if let character = anchor.character, placements[index].identity == anchor.block,
           let top = blocks[index].characterTop(character, in: self) { return top }
        return blocks[index].frame.minY - anchor.offset
    }
    private func containsSelection(_ block: NativeMarkdownBlockHost, responder: NSView?) -> Bool {
        guard let view = block.view, let responder else { return false }
        if responder === view || responder.isDescendant(of: view) { return true }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let owner = editor.delegate as? NSView {
            return owner === view || owner.isDescendant(of: view)
        }
        return false
    }
    private func mountVisibleBlocks() {
        guard laidOutWidth != nil else { return }
        let viewport: CGRect
        if let clip = observedClip {
            viewport = convert(clip.bounds, from: clip)
        } else if window != nil {
            viewport = visibleRect
        } else {
            // An offscreen retained transcript row is detached as a whole.
            // Keep its data and exact sizes, but no native text views mounted.
            viewport = .null
        }
        let visible = viewport.isNull ? viewport : viewport.insetBy(dx: 0, dy: -max(120, viewport.height / 4))
        resolveVisibleBlocks(in: visible)
        let provisional = layouts.last(where: { $0.width == bounds.width })?.provisional ?? []
        // The blocks on screen, found by bisection; a block holding the
        // reader's selection stays, wherever it is.
        var wanted: [ObjectIdentifier: NativeMarkdownBlockHost] = [:]
        for index in onScreen(visible) where !provisional.contains(index) { wanted[ObjectIdentifier(blocks[index])] = blocks[index] }
        let responder = window?.firstResponder as? NSView
        for (key, host) in mountedHosts where wanted[key] == nil && containsSelection(host, responder: responder) { wanted[key] = host }
        for (key, host) in mountedHosts where wanted[key] == nil {
            if host.view?.superview === self { host.view?.removeFromSuperview() }
            if host.view != nil { detachedHosts[key] = host }
        }
        for (key, host) in wanted { host.place(in: self); detachedHosts[key] = nil }
        mountedHosts = wanted
        // Reclaim distant trees only during the shared input-quiet budget.
        // Measurements stay exact. Visible/nearby trees and selection owners
        // survive; reconstruction is required only after travelling well away.
        let retention = viewport.isNull ? viewport : viewport.insetBy(dx: 0, dy: -max(720, viewport.height * 3))
        let candidates = detachedHosts.values.filter { $0.view != nil && $0.view?.superview == nil && (retention.isNull || !$0.frame.intersects(retention)) }
        guard !candidates.isEmpty else { TranscriptIdleScheduler.shared.cancel(self); return }
        var cursor = 0
        TranscriptIdleScheduler.shared.request(self, after: ProcessInfo.processInfo.systemUptime + TranscriptNativeDocument.sliceQuietPeriod) { [weak self] in
            guard let self else { return false }
            let responder = self.window?.firstResponder as? NSView
            while cursor < candidates.count {
                let block = candidates[cursor]; cursor += 1
                guard block.view != nil, block.view?.superview == nil, !self.containsSelection(block, responder: responder) else { continue }
                block.releaseDetachedHost()
                self.detachedHosts[ObjectIdentifier(block)] = nil
                return cursor < candidates.count
            }
            return false
        }
    }
}
