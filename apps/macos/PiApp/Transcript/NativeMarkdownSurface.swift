import AppKit
import SwiftUI

/// A long reply retains every block and its measured or provisional height, while only the part
/// near the outer conversation viewport participates in native scrolling.
/// This is not another scroll view and does not truncate the source or copy
/// targets. Small replies keep the simpler SwiftUI stack.
struct NativeMarkdownSurface: NSViewRepresentable {
    nonisolated static let minimumBlockCount = 8
    let blocks: [MarkdownBlock]
    let style: MarkdownStyle
    let capsWidth: Bool
    let streaming: Bool
    let headings: [MarkdownCopyTarget]
    var identities: [MarkdownBlockIdentity]? = nil
    var sourceText: String? = nil
    var sourceRanges: [Range<Int>]? = nil

    func makeNSView(context: Context) -> NativeMarkdownContainer {
        let view = NativeMarkdownContainer()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: NativeMarkdownContainer, context: Context) {
        view.update(blocks: blocks, style: style, capsWidth: capsWidth, streaming: streaming,
                    headings: headings, environment: TranscriptRowEnvironment(context.environment), identities: identities, sourceText: sourceText, sourceRanges: sourceRanges)
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
              environment == other.environment else { return false }
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
            .disabled(!item.environment.isEnabled)
            .piStableLayout()
    }
}

@MainActor private final class NativeMarkdownBlockHost {
    private(set) var view: NSHostingView<NativeHostedMarkdownBlock>?
    private var item: NativeMarkdownItem
    private var nativeCodeChoice: Bool?
    private let decoration = MarkdownBlockDecoration()
    private weak var selectionEditor: NSTextView?
    private var restoredSelection: (range: NSRange, original: NSRange, rendered: String)?
    private var selectionRevision = 0
    private var reconciliation: MarkdownSelection.Reconciliation?
    private var width: CGFloat = TranscriptMetrics.pageWidth
    private var sizes: [CGSize] = []
    var frame = CGRect.zero
    private(set) var measurementCount = 0

    init(item: NativeMarkdownItem) {
        self.item = item
        decoration.update(caret: item.caret, target: item.headingTarget)
        if case .code(_, let code) = item.block {
            nativeCodeChoice = NativeCodeText.enabled && (item.caret || code.utf8.count >= NativeCodeText.minimumBytes)
        } else { nativeCodeChoice = nil }
    }
    private func host() -> NSHostingView<NativeHostedMarkdownBlock> {
        if let view { return view }
        let next = NSHostingView(rootView: NativeHostedMarkdownBlock(item: item, width: width, decoration: decoration, nativeCodeChoice: nativeCodeChoice))
        next.safeAreaRegions = []; next.sizingOptions = [.intrinsicContentSize]
        view = next; applyAppearance()
        return next
    }
    /// Geometry and source outlive the expensive native tree. No sizing
    /// surrogate is shared, and a selected owner is excluded by the caller.
    func releaseDetachedHost() { if view?.superview == nil { view = nil } }
    @discardableResult func update(_ item: NativeMarkdownItem,
                                  source: () -> (previous: MarkdownSelection.Source?, current: MarkdownSelection.Source)? = { nil }) -> Bool {
        guard self.item != item else { return false }
        decoration.update(caret: item.caret, target: item.headingTarget)
        guard !self.item.hasSameGeometry(as: item) else { self.item = item; return false }
        selectionRevision &+= 1
        restoredSelection = nil; selectionEditor = nil
        if case .paragraph(let oldText) = self.item.block, case .paragraph(let newText) = item.block {
            let old = String(oldText.characters), new = String(newText.characters)
            if !new.hasPrefix(old) {
                reconciliation = source().map {
                    MarkdownSelection.Reconciliation(previous: old, source: $0.current, previousSource: $0.previous,
                                                     rendered: new, keepsSoftBreaks: item.style.keepsSoftBreaks)
                }
            }
            if let editor = view?.window?.firstResponder as? NSTextView,
               textOwners.contains(where: { ($0 as? NSTextField)?.currentEditor() === editor }),
               !new.hasPrefix(old), let range = reconciliation?.range(editor.selectedRange()) {
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
        view?.rootView = NativeHostedMarkdownBlock(item: item, width: width, decoration: decoration, nativeCodeChoice: nativeCodeChoice)
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
    func measure(width: CGFloat) -> CGSize {
        if let cached = sizes.last(where: { $0.width == width }) { return cached }
        if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownBlocksMeasured += 1 }
        setWidth(width)
        let size = CGSize(width: width, height: max(1, ceil(host().fittingSize.height)))
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
        if !rendered.hasPrefix(anchor.rendered), let mapped = reconciliation?.range(anchor.range, from: anchor.rendered, to: rendered) {
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
        view?.rootView = NativeHostedMarkdownBlock(item: item, width: width, decoration: decoration, nativeCodeChoice: nativeCodeChoice)
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
    private final class Layout {
        let width: CGFloat
        var heights: [CGFloat] = []
        var total: CGFloat = 0
        var validPrefix = 0
        var provisional: Set<Int> = []
        init(width: CGFloat) { self.width = width }
    }
    private var blocks: [NativeMarkdownBlockHost] = []
    private var identities: [MarkdownBlockIdentity] = []
    private var priorSourceText: String?
    private var priorSourceRanges: [Range<Int>]?
    var blockOwnerIdentities: [ObjectIdentifier] { blocks.map(ObjectIdentifier.init) }
    private var layouts: [Layout] = []
    private var laidOutWidth: CGFloat?
    private var layoutDirtyFrom: Int? = 0
    private(set) var aggregateMeasurementVisits = 0
    private(set) var framePlacements = 0
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
    var hasProvisionalGeometry: Bool { layouts.last?.provisional.isEmpty == false }
    var visibleContentPrepared: Bool {
        guard let clip = observedClip, let layout = layouts.last(where: { $0.width == bounds.width }) else { return blocks.isEmpty }
        let viewport = convert(clip.bounds, from: clip)
        guard !resolveScheduled else { return false }
        return !layout.provisional.contains { blocks.indices.contains($0) && blocks[$0].frame.intersects(viewport) }
    }
    var provisionalBlockCount: Int { layouts.last?.provisional.count ?? 0 }
    /// A logical source/block identity, independent of estimated row heights.
    struct LogicalAnchor: Equatable { var block: MarkdownBlockIdentity; var offset: CGFloat; fileprivate var character: NativeMarkdownBlockHost.CharacterAnchor? = nil; var sourceUTF16Range: NSRange? { character?.range } }
    var logicalAnchor: LogicalAnchor? {
        guard let clip = observedClip else { return nil }
        let y = convert(clip.bounds, from: clip).minY
        guard let index = blocks.firstIndex(where: { $0.frame.maxY > y }), identities.indices.contains(index) else { return nil }
        return LogicalAnchor(block: identities[index], offset: blocks[index].frame.minY - y)
    }
    var preparedLogicalAnchor: LogicalAnchor? {
        guard let clip = observedClip else { return nil }
        let viewport = convert(clip.bounds, from: clip)
        guard let index = blocks.indices.first(where: {
            blocks[$0].frame.intersects(viewport) && blocks[$0].exactMeasurement(width: bounds.width) != nil
        }) else { return nil }
        return LogicalAnchor(block: identities[index], offset: blocks[index].frame.minY - viewport.minY, character: blocks[index].characterAnchor(in: self, viewportTop: viewport.minY))
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

    func update(blocks source: [MarkdownBlock], style: MarkdownStyle, capsWidth: Bool, streaming: Bool,
                headings: [MarkdownCopyTarget], environment: TranscriptRowEnvironment, identities: [MarkdownBlockIdentity]? = nil, sourceText: String? = nil, sourceRanges: [Range<Int>]? = nil) {
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownUpdateSeconds += TranscriptLayoutClock.now - clock } }
        var ids = identities?.count == source.count ? identities! : source.indices.map { MarkdownBlockIdentity(generation: 0, sourceOffset: $0) }
        var seen = Set<MarkdownBlockIdentity>()
        for index in ids.indices {
            while !seen.insert(ids[index]).inserted { ids[index].component += 1 }
        }
        enclosingScrollView?.transcriptReading.capture(self)
        var changedFrom = min(self.identities.count, ids.count), headingIndex = 0
        for index in 0..<min(self.identities.count, ids.count) where self.identities[index] != ids[index] { changedFrom = index; break }
        var changed = self.identities != ids
        let old = Dictionary(uniqueKeysWithValues: zip(self.identities, blocks.enumerated()))
        var next: [NativeMarkdownBlockHost] = []
        for (index, block) in source.enumerated() {
            var heading: MarkdownCopyTarget?
            if case .heading = block {
                if headings.indices.contains(headingIndex) { heading = headings[headingIndex] }
                headingIndex += 1
            }
            let item = NativeMarkdownItem(block: block, style: style, capsWidth: capsWidth,
                                          caret: streaming && index == source.count - 1, headingTarget: heading, environment: environment)
            if let prior = old[ids[index]] {
                let retained = prior.element
                if retained.update(item, source: {
                    guard let sourceText, let sourceRanges, sourceRanges.indices.contains(index),
                          let current = MarkdownSelection.Source(sourceText, bytes: sourceRanges[index]) else { return nil }
                    var previous: MarkdownSelection.Source?
                    if let priorSourceText, let priorSourceRanges, priorSourceRanges.indices.contains(prior.offset) {
                        previous = MarkdownSelection.Source(priorSourceText, bytes: priorSourceRanges[prior.offset])
                    }
                    return (previous, current)
                }) { changed = true; changedFrom = min(changedFrom, index) }
                next.append(retained)
            } else { next.append(NativeMarkdownBlockHost(item: item)); changed = true }
        }
        let retained = Set(ids)
        for (id, prior) in old where !retained.contains(id) { prior.element.view?.removeFromSuperview() }
        blocks = next; self.identities = ids
        priorSourceText = sourceText; priorSourceRanges = sourceRanges
        guard changed else { return }
        // Completed blocks retain their exact width-specific heights. Only the
        // changed suffix participates in aggregate sizing and frame placement.
        for layout in layouts { layout.validPrefix = min(layout.validPrefix, changedFrom); layout.provisional = layout.provisional.filter { $0 < changedFrom } }
        layoutDirtyFrom = min(layoutDirtyFrom ?? changedFrom, changedFrom)
        needsLayout = true
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
        let prefix = min(layout.validPrefix, blocks.count)
        let oldSpacing = CGFloat(max(0, layout.heights.count - 1)) * 10
        let removed = layout.heights[prefix...].reduce(0, +)
        layout.total -= oldSpacing + removed
        layout.heights.removeSubrange(prefix...)
        for index in prefix..<blocks.count {
            // Descriptor estimates never enter a shared exact-size cache.
            // A giant message prepares a few blocks, then only the viewport.
            let known = blocks[index].exactMeasurement(width: width)
            let deferred = known == nil && blocks.count > 32 && index >= 6 && blocks[index].view?.superview == nil
            let height = known?.height ?? (deferred ? max(20, blocks[index].estimate(width: width)) : blocks[index].measure(width: width).height)
            if deferred { layout.provisional.insert(index) } else { layout.provisional.remove(index) }
            layout.heights.append(height); layout.total += height; aggregateMeasurementVisits += 1
        }
        layout.total += CGFloat(max(0, blocks.count - 1)) * 10
        layout.validPrefix = blocks.count
        return layout
    }

    func measure(width proposed: CGFloat?) -> CGSize {
        if proposed == 0 { return .zero }
        let width = proposed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (bounds.width > 0 ? bounds.width : TranscriptMetrics.pageWidth)
        return CGSize(width: width, height: exactLayout(width: width).total)
    }
    override func layout() {
        super.layout()
        guard bounds.width > 0, !applyingLayout else { return }
        applyingLayout = true
        defer { applyingLayout = false }
        if laidOutWidth != bounds.width || layoutDirtyFrom != nil {
            let layout = exactLayout(width: bounds.width)
            let first = laidOutWidth == bounds.width ? min(layoutDirtyFrom ?? 0, blocks.count) : 0
            var y: CGFloat = first > 0 ? blocks[first - 1].frame.maxY + 10 : 0
            for index in first..<blocks.count {
                let block = blocks[index]
                framePlacements += 1
                block.frame = CGRect(x: 0, y: y, width: bounds.width, height: layout.heights[index])
                y += layout.heights[index] + 10
            }
            laidOutWidth = bounds.width; layoutDirtyFrom = nil
        }
        bindViewport()
        enclosingScrollView?.transcriptReading.geometryChanged()
        mountVisibleBlocks()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
    private func resolveVisibleBlocks(in viewport: CGRect) {
        guard !resolvingViewport, !viewport.isNull, let layout = layouts.last(where: { $0.width == bounds.width }),
              !layout.provisional.isEmpty else { return }
        let candidates = layout.provisional.sorted().filter { blocks.indices.contains($0) && blocks[$0].frame.intersects(viewport) }
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
        var changedFrom = blocks.count
        willPrepareVisibleBlocks?()
        for index in candidates.prefix(4) {
            let height = blocks[index].measure(width: bounds.width).height
            layout.total += height - layout.heights[index]; layout.heights[index] = height
            layout.provisional.remove(index); changedFrom = min(changedFrom, index)
        }
        layoutDirtyFrom = min(layoutDirtyFrom ?? changedFrom, changedFrom)
        // Reposition descriptors synchronously, but ask the enclosing hosting
        // row to resize after this native layout callback has returned.
        var y: CGFloat = 0
        for index in blocks.indices {
            blocks[index].frame = CGRect(x: 0, y: y, width: bounds.width, height: layout.heights[index])
            y += layout.heights[index] + 10
        }
        enclosingScrollView?.transcriptReading.capture(self)
        didPrepareVisibleBlocks?()
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
        let index = identities.firstIndex(of: anchor.block) ?? identities.lastIndex(where: {
            $0.generation == anchor.block.generation && $0.sourceOffset <= anchor.block.sourceOffset
        }) ?? identities.firstIndex(where: { $0.generation == anchor.block.generation })
        guard let index, blocks.indices.contains(index) else { return nil }
        if let character = anchor.character, identities[index] == anchor.block,
           let top = blocks[index].characterTop(character, in: self) { return top }
        return blocks[index].frame.minY - anchor.offset
    }
    private func containsSelection(_ block: NativeMarkdownBlockHost) -> Bool {
        guard let view = block.view, let responder = window?.firstResponder as? NSView else { return false }
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
        for (index, block) in blocks.enumerated() {
            if ((!visible.isNull && block.frame.intersects(visible)) || containsSelection(block)) && !provisional.contains(index) { block.place(in: self) }
            else if block.view?.superview === self { block.view?.removeFromSuperview() }
        }
        // Reclaim distant trees only during the shared input-quiet budget.
        // Measurements stay exact. Visible/nearby trees and selection owners
        // survive; reconstruction is required only after travelling well away.
        let retention = viewport.isNull ? viewport : viewport.insetBy(dx: 0, dy: -max(720, viewport.height * 3))
        let candidates = blocks.filter { $0.view != nil && $0.view?.superview == nil &&
            (retention.isNull || !$0.frame.intersects(retention)) && !containsSelection($0) }
        guard !candidates.isEmpty else { TranscriptIdleScheduler.shared.cancel(self); return }
        var cursor = 0
        TranscriptIdleScheduler.shared.request(self, after: ProcessInfo.processInfo.systemUptime + TranscriptNativeDocument.sliceQuietPeriod) { [weak self] in
            guard let self else { return false }
            while cursor < candidates.count {
                let block = candidates[cursor]; cursor += 1
                guard block.view != nil, block.view?.superview == nil, !self.containsSelection(block) else { continue }
                block.releaseDetachedHost()
                return cursor < candidates.count
            }
            return false
        }

    }
}
