import AppKit
import SwiftUI

/// A long reply retains every block and its exact height, while only the part
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
    private struct Layout {
        var width: CGFloat
        var heights: [CGFloat]
        var total: CGFloat
    }
    private var blocks: [NativeMarkdownBlockHost] = []
    private var identities: [MarkdownBlockIdentity] = []
    var blockOwnerIdentities: [ObjectIdentifier] { blocks.map(ObjectIdentifier.init) }
    private var layouts: [Layout] = []
    private var laidOutWidth: CGFloat?
    private var invalidationScheduled = false
    private var applyingLayout = false
    private weak var observedClip: NSClipView?
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: layouts.last(where: { $0.width == bounds.width })?.total ?? NSView.noIntrinsicMetric)
    }
    /// Evidence for regressions: pure scrolling must reuse exact measurements.
    var blockMeasurementCount: Int { blocks.reduce(0) { $0 + $1.measurementCount } }
    var retainedBlockCount: Int { blocks.count }
    var hostedBlockCount: Int { blocks.reduce(0) { $0 + ($1.view == nil ? 0 : 1) } }
    var mountedBlockCount: Int { blocks.reduce(0) { $0 + ($1.view?.superview === self ? 1 : 0) } }

    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }

    func update(blocks source: [MarkdownBlock], style: MarkdownStyle, capsWidth: Bool, streaming: Bool,
                headings: [MarkdownCopyTarget], environment: TranscriptRowEnvironment, identities: [MarkdownBlockIdentity]? = nil, sourceText: String? = nil, sourceRanges: [Range<Int>]? = nil) {
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownUpdateSeconds += TranscriptLayoutClock.now - clock } }
        var ids = identities?.count == source.count ? identities! : source.indices.map { MarkdownBlockIdentity(generation: 0, sourceOffset: $0) }
        var seen = Set<MarkdownBlockIdentity>()
        for index in ids.indices {
            while !seen.insert(ids[index]).inserted { ids[index].component += 1 }
        }
        var changed = self.identities != ids, headingIndex = 0
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
                }) { changed = true }
                next.append(retained)
            } else { next.append(NativeMarkdownBlockHost(item: item)); changed = true }
        }
        let retained = Set(ids)
        for (id, block) in old where !retained.contains(id) { block.view?.removeFromSuperview() }
        blocks = next; self.identities = ids
        guard changed else { return }
        layouts.removeAll(keepingCapacity: true)
        laidOutWidth = nil
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
        if let cached = layouts.last(where: { $0.width == width }) { return cached }
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownLayoutSeconds += TranscriptLayoutClock.now - clock } }
        let heights = blocks.map { $0.measure(width: width).height }
        let layout = Layout(width: width, heights: heights, total: heights.reduce(0, +) + CGFloat(max(0, blocks.count - 1)) * 10)
        if layouts.count == 4 { layouts.removeFirst() }
        layouts.append(layout)
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
        if laidOutWidth != bounds.width {
            let layout = exactLayout(width: bounds.width)
            var y: CGFloat = 0
            for (index, block) in blocks.enumerated() {
                block.frame = CGRect(x: 0, y: y, width: bounds.width, height: layout.heights[index])
                y += layout.heights[index] + 10
            }
            laidOutWidth = bounds.width
        }
        bindViewport()
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
        boundsObserver = nil; observedClip = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mountVisibleBlocks() }
        }
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
        let visible = viewport.isNull ? viewport : viewport.insetBy(dx: 0, dy: -max(240, viewport.height / 2))
        for block in blocks {
            if (!visible.isNull && block.frame.intersects(visible)) || containsSelection(block) { block.place(in: self) }
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
