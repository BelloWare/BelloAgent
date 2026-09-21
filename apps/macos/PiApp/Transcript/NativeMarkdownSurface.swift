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
}

private struct NativeHostedMarkdownBlock: View {
    let item: NativeMarkdownItem
    let width: CGFloat
    var nativeCodeChoice: Bool? = nil
    var body: some View {
        MarkdownBlockView(block: item.block, style: item.style, capsWidth: item.capsWidth,
                          caret: item.caret, headingTarget: item.headingTarget, nativeCodeChoice: nativeCodeChoice)
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
    private weak var selectionEditor: NSTextView?
    private var restoredSelection: (range: NSRange, rendered: String)?
    private var width: CGFloat = TranscriptMetrics.pageWidth
    private var sizes: [CGSize] = []
    var frame = CGRect.zero
    private(set) var measurementCount = 0

    init(item: NativeMarkdownItem) {
        self.item = item
        if case .code(_, let code) = item.block {
            nativeCodeChoice = NativeCodeText.enabled && (item.caret || code.utf8.count >= NativeCodeText.minimumBytes)
        } else { nativeCodeChoice = nil }
    }
    private func host() -> NSHostingView<NativeHostedMarkdownBlock> {
        if let view { return view }
        let next = NSHostingView(rootView: NativeHostedMarkdownBlock(item: item, width: width, nativeCodeChoice: nativeCodeChoice))
        next.safeAreaRegions = []; next.sizingOptions = [.intrinsicContentSize]
        view = next; applyAppearance()
        return next
    }
    /// Geometry and source outlive the expensive native tree. No sizing
    /// surrogate is shared, and a selected owner is excluded by the caller.
    func releaseDetachedHost() { if view?.superview == nil { view = nil } }
    @discardableResult func update(_ item: NativeMarkdownItem, source: () -> String? = { nil }) -> Bool {
        guard self.item != item else { return false }
        if case .paragraph(let oldText)=self.item.block, case .paragraph(let newText)=item.block,
           let host=view, let editor=host.window?.firstResponder as? NSTextView,
           let field=editor.delegate as? NSTextField, field.isDescendant(of:host),
           let raw=source(), let range=MarkdownSelection.canonicalRange(editor.selectedRange(), literal:String(oldText.characters), source:raw, rendered:String(newText.characters), keepsSoftBreaks:item.style.keepsSoftBreaks) {
            selectionEditor=editor; restoredSelection=(range,String(newText.characters))
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
        view?.rootView = NativeHostedMarkdownBlock(item: item, width: width, nativeCodeChoice: nativeCodeChoice)
        applyAppearance()
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
    func setWidth(_ width: CGFloat) {
        guard self.width != width else { return }
        self.width = width
        view?.rootView = NativeHostedMarkdownBlock(item: item, width: width, nativeCodeChoice: nativeCodeChoice)
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
        editor.setSelectedRange(selection.range); restoredSelection=nil; selectionEditor=nil
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
    var blockOwnerIdentities: [ObjectIdentifier] { blocks.map(ObjectIdentifier.init) }
    private var layouts: [Layout] = []
    private var laidOutWidth: CGFloat?
    private var layoutDirtyFrom: Int? = 0
    private(set) var aggregateMeasurementVisits = 0
    private(set) var framePlacements = 0
    private var invalidationScheduled = false
    private var applyingLayout = false
    private var resolvingViewport = false
    private var resolveScheduled = false
    private var pendingAnchor: (anchor: LogicalAnchor, clipY: CGFloat, generation: Int)?
    private var contentGeneration = 0
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
    struct LogicalAnchor: Equatable { var block: MarkdownBlockIdentity; var offset: CGFloat }
    var logicalAnchor: LogicalAnchor? {
        guard let clip = observedClip else { return nil }
        let y = convert(clip.bounds, from: clip).minY
        guard let index = blocks.firstIndex(where: { $0.frame.maxY > y }), identities.indices.contains(index) else { return nil }
        return LogicalAnchor(block: identities[index], offset: blocks[index].frame.minY - y)
    }
    private weak var observedClip: NSClipView?
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var frameObservers: [NSObjectProtocol] = []
    private var frameCorrectionScheduled = false
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
        var changedFrom = min(self.identities.count, ids.count), headingIndex = 0
        for index in 0..<min(self.identities.count, ids.count) where self.identities[index] != ids[index] { changedFrom = index; break }
        var changed = self.identities != ids
        let old = Dictionary(uniqueKeysWithValues: zip(self.identities, blocks))
        var next: [NativeMarkdownBlockHost] = []
        for (index, block) in source.enumerated() {
            var heading: MarkdownCopyTarget?
            if case .heading = block {
                if headings.indices.contains(headingIndex) { heading = headings[headingIndex] }
                headingIndex += 1
            }
            let item = NativeMarkdownItem(block: block, style: style, capsWidth: capsWidth,
                                          caret: streaming && index == source.count - 1, headingTarget: heading, environment: environment)
            if let retained = old[ids[index]] {
                if retained.update(item, source: {
                    guard let sourceText, let sourceRanges, sourceRanges.indices.contains(index) else { return nil }
                    let range=sourceRanges[index], bytes=sourceText.utf8
                    guard range.lowerBound>=0, range.upperBound<=bytes.count else { return nil }
                    let start=bytes.index(bytes.startIndex,offsetBy:range.lowerBound), end=bytes.index(start,offsetBy:range.count)
                    return String(decoding:bytes[start..<end],as:UTF8.self)
                }) { changed = true; changedFrom = min(changedFrom, index) }
                next.append(retained)
            } else { next.append(NativeMarkdownBlockHost(item: item)); changed = true }
        }
        let retained = Set(ids)
        for (id, block) in old where !retained.contains(id) { block.view?.removeFromSuperview() }
        blocks = next; self.identities = ids
        guard changed else { return }
        contentGeneration += 1
        pendingAnchor = nil
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
            let deferred = blocks.count > 32 && index >= 6
            let height = deferred ? max(20, blocks[index].estimate(width: width)) : blocks[index].measure(width: width).height
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
        if let pending = pendingAnchor {
            if pending.generation == contentGeneration, observedClip?.bounds.minY == pending.clipY {
                restoreLogicalAnchor(pending.anchor)
            } else { pendingAnchor = nil }
        }
        mountVisibleBlocks()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bindViewport()
        mountVisibleBlocks()
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
    private func scheduleFrameCorrection() {
        guard pendingAnchor != nil, !frameCorrectionScheduled else { return }
        frameCorrectionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameCorrectionScheduled = false
            guard let pending = self.pendingAnchor, pending.generation == self.contentGeneration,
                  self.observedClip?.bounds.minY == pending.clipY else { self.pendingAnchor = nil; return }
            self.restoreLogicalAnchor(pending.anchor)
            self.mountVisibleBlocks()
        }
    }
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
        let retained = pendingAnchor.flatMap { pending in
            pending.generation == contentGeneration && observedClip?.bounds.minY == pending.clipY ? pending.anchor : nil
        }
        let anchor = retained ?? logicalAnchor, generation = contentGeneration
        var changedFrom = blocks.count
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
        if let anchor { restoreLogicalAnchor(anchor) }
        if let anchor, let clip = observedClip { pendingAnchor = (anchor, clip.bounds.minY, generation) }
        resolvingViewport = false
        guard !resolveScheduled else { return }
        resolveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resolveScheduled = false
            let pending = self.pendingAnchor
            let mayRestore = pending?.generation == self.contentGeneration && self.observedClip?.bounds.minY == pending?.clipY
            if !mayRestore { self.pendingAnchor = nil }
            self.resolvingViewport = true
            self.invalidateIntrinsicContentSize()
            self.needsLayout = true
            self.superview?.layoutSubtreeIfNeeded()
            if mayRestore, let pending { self.restoreLogicalAnchor(pending.anchor) }
            self.resolvingViewport = false
            self.mountVisibleBlocks()
        }
    }
    private func restoreLogicalAnchor(_ anchor: LogicalAnchor) {
        guard let clip = observedClip, let index = identities.firstIndex(of: anchor.block) else { return }
        let wasResolving = resolvingViewport
        resolvingViewport = true
        defer { resolvingViewport = wasResolving }
        // NSHostingView/NSClipView can have the opposite vertical direction to
        // this flipped native surface. Convert the displacement, not a point
        // assumed to be the clip's top edge.
        let currentTop = convert(clip.bounds, from: clip).minY
        let desiredTop = blocks[index].frame.minY - anchor.offset
        let delta = convert(NSPoint(x: 0, y: desiredTop), to: clip).y - convert(NSPoint(x: 0, y: currentTop), to: clip).y
        let newY = clip.bounds.minY + delta
        if abs(newY - clip.bounds.minY) > 0.5 {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, newY)))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        // The hosting row may adopt its final height on a later pass. Keep
        // this identity through that rebase too; any new scroll supersedes it.
        pendingAnchor = (anchor, clip.bounds.minY, contentGeneration)
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
