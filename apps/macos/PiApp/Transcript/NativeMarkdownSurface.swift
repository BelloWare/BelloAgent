import AppKit
import SwiftUI

/// A long reply retains every block and its exact height, while only the part
/// near the outer conversation viewport participates in native scrolling.
/// This is not another scroll view and does not truncate the source or copy
/// targets. Small replies keep the simpler SwiftUI stack.
struct NativeMarkdownSurface: NSViewRepresentable {
    static let minimumBlockCount = 32
    let blocks: [MarkdownBlock]
    let style: MarkdownStyle
    let capsWidth: Bool
    let streaming: Bool
    let headings: [MarkdownCopyTarget]

    func makeNSView(context: Context) -> NativeMarkdownContainer {
        let view = NativeMarkdownContainer()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: NativeMarkdownContainer, context: Context) {
        view.update(blocks: blocks, style: style, capsWidth: capsWidth, streaming: streaming,
                    headings: headings, environment: TranscriptRowEnvironment(context.environment))
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
    var body: some View {
        MarkdownBlockView(block: item.block, style: item.style, capsWidth: item.capsWidth,
                          caret: item.caret, headingTarget: item.headingTarget)
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
    let view: NSHostingView<NativeHostedMarkdownBlock>
    private var item: NativeMarkdownItem
    private var width: CGFloat = TranscriptMetrics.pageWidth
    private var sizes: [CGSize] = []
    var frame = CGRect.zero
    private(set) var measurementCount = 0

    init(item: NativeMarkdownItem) {
        self.item = item
        view = NSHostingView(rootView: NativeHostedMarkdownBlock(item: item, width: TranscriptMetrics.pageWidth))
        view.safeAreaRegions = []
        view.sizingOptions = [.intrinsicContentSize]
        applyAppearance()
    }
    @discardableResult func update(_ item: NativeMarkdownItem) -> Bool {
        guard self.item != item else { return false }
        self.item = item
        sizes.removeAll(keepingCapacity: true)
        view.rootView = NativeHostedMarkdownBlock(item: item, width: width)
        applyAppearance()
        return true
    }
    private func applyAppearance() {
        // colorSchemeContrast is read-only in SwiftUI's public environment.
        // The native appearance carries contrast across this hosting boundary.
        let dark = item.environment.colorScheme == .dark
        let increased = item.environment.contrast == .increased
        let name: NSAppearance.Name = increased ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua)
        view.appearance = NSAppearance(named: name)
    }
    func measure(width: CGFloat) -> CGSize {
        if let cached = sizes.last(where: { $0.width == width }) { return cached }
        if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownBlocksMeasured += 1 }
        setWidth(width)
        let size = CGSize(width: width, height: max(1, ceil(view.fittingSize.height)))
        if sizes.count == 4 { sizes.removeFirst() }
        sizes.append(size)
        measurementCount += 1
        return size
    }
    func setWidth(_ width: CGFloat) {
        guard self.width != width else { return }
        self.width = width
        view.rootView = NativeHostedMarkdownBlock(item: item, width: width)
    }
    func place(in container: NSView) {
        setWidth(frame.width)
        if view.frame != frame { view.frame = frame }
        if view.superview !== container { container.addSubview(view) }
    }
}

@MainActor final class NativeMarkdownContainer: NSView {
    private struct Layout {
        var width: CGFloat
        var heights: [CGFloat]
        var total: CGFloat
    }
    private var blocks: [NativeMarkdownBlockHost] = []
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
    var mountedBlockCount: Int { blocks.reduce(0) { $0 + ($1.view.superview === self ? 1 : 0) } }

    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }

    func update(blocks source: [MarkdownBlock], style: MarkdownStyle, capsWidth: Bool, streaming: Bool,
                headings: [MarkdownCopyTarget], environment: TranscriptRowEnvironment) {
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.markdownUpdateSeconds += TranscriptLayoutClock.now - clock } }
        var changed = blocks.count != source.count, headingIndex = 0
        for (index, block) in source.enumerated() {
            var heading: MarkdownCopyTarget?
            if case .heading = block {
                if headings.indices.contains(headingIndex) { heading = headings[headingIndex] }
                headingIndex += 1
            }
            let item = NativeMarkdownItem(block: block, style: style, capsWidth: capsWidth,
                                          caret: streaming && index == source.count - 1, headingTarget: heading, environment: environment)
            if blocks.indices.contains(index) { if blocks[index].update(item) { changed = true } }
            else { blocks.append(NativeMarkdownBlockHost(item: item)) }
        }
        if blocks.count > source.count {
            for block in blocks.dropFirst(source.count) { block.view.removeFromSuperview() }
            blocks.removeLast(blocks.count - source.count)
        }
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
        guard let responder = window?.firstResponder as? NSView else { return false }
        if responder === block.view || responder.isDescendant(of: block.view) { return true }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let owner = editor.delegate as? NSView {
            return owner === block.view || owner.isDescendant(of: block.view)
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
            else if block.view.superview === self { block.view.removeFromSuperview() }
        }
    }
}
