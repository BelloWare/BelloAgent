import AppKit

/// The models' shares as a ring, the reported cost in its middle, and the
/// four largest beside it; pointing at one lifts its arc and dims the rest.
/// Bounded native drawing: no chart engine or transcript work per live tick.
@MainActor final class ModelDistributionRing: DashView, PiKit.WidthSizing {
    private var models: [MonitorDistribution] = []
    private var palette = MonitorModelPalette()
    private var metric = MonitorShareMetric.tokens
    private var cost: Double?
    private var updated = false
    private var highlighted: String? { didSet { if highlighted != oldValue { ring.needsDisplay = true } } }
    private let ring = Ring()
    private let center = ShellStack(.vertical, spacing: 4, alignment: .center)
    private let costLine = ScaledLine()
    private let costTitle = PiKit.TextLine(PiKit.Line("reported cost", font: .systemFont(ofSize: 10), color: .piInkSecondary))
    private let legend = ShellStack(.vertical, spacing: 12, alignment: .leading)
    private let more = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkSecondary))
    private let empty = PiKit.TextLine(PiKit.Line("Awaiting reported usage", font: PiKit.Font.caption, color: .piInkSecondary))
    static let side: CGFloat = 136

    override init(frame: NSRect) {
        super.init(frame: frame)
        ring.owner = self
        ring.setAccessibilityElement(false)
        center.items = [.view(costLine), .view(costTitle)]
        for view in [ring, center, legend] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func update(models: [MonitorDistribution], palette: MonitorModelPalette, metric: MonitorShareMetric, cost: Double?) {
        guard !updated || models != self.models || palette != self.palette || metric != self.metric || cost != self.cost else { return }
        updated = true
        self.models = models; self.palette = palette; self.metric = metric; self.cost = cost
        costLine.line = PiKit.Line(monitorCost(cost), font: PiKit.Font.monospacedDigits(.systemFont(ofSize: 15, weight: .semibold)), color: .labelColor)
        var items: [ShellItem] = Self.legend(models, metric: metric).map { row in
            let view = LegendRow(model: row, color: .monitorModel(palette.index(row.id)), share: share(row))
            view.onHover = { [weak self] inside in self?.highlighted = inside ? row.id : nil }
            return .view(view, .fill)
        }
        more.line.text = "+\(models.count - 4) more models"
        if models.count > 4 { items.append(.view(more)) }
        if models.isEmpty { items.append(.view(empty)) }
        legend.items = items
        ring.needsDisplay = true
        needsLayout = true
        PiKit.sizeChanged(self)
    }

    /// The four models the legend names, ranked by the share it shows.
    static func legend(_ models: [MonitorDistribution], metric: MonitorShareMetric) -> [MonitorDistribution] {
        Array((metric == .cost ? MonitorDistribution.byCost(models) : models).prefix(4))
    }
    fileprivate func share(_ row: MonitorDistribution) -> Double? { metric == .cost ? row.costShare : row.tokenShare }

    func height(forWidth width: CGFloat) -> CGFloat { max(Self.side, legend.height(forWidth: max(0, width - Self.side - 20))) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 444)) }
    override func layout() {
        super.layout()
        let scale = piScale
        let top = PiKit.round((bounds.height - Self.side) / 2, scale)
        ring.frame = CGRect(x: 0, y: top, width: Self.side, height: Self.side)
        let inner = Self.side - 34
        let height = center.height(forWidth: inner)
        center.frame = CGRect(x: 17, y: top + PiKit.round((Self.side - height) / 2, scale), width: inner, height: height)
        let width = max(0, bounds.width - Self.side - 20)
        let legendHeight = legend.height(forWidth: width)
        legend.frame = CGRect(x: Self.side + 20, y: PiKit.round((bounds.height - legendHeight) / 2, scale), width: width, height: legendHeight)
    }

    /// The track and an arc per model, clockwise from the top.
    final class Ring: DashView {
        weak var owner: ModelDistributionRing?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let owner, let context = NSGraphicsContext.current?.cgContext else { return }
            let center = CGPoint(x: bounds.midX, y: bounds.midY), radius = min(bounds.width, bounds.height) / 2 - 9
            context.setLineWidth(15)
            context.setStrokeColor(NSColor.piFillStrong.cgColor)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            var start = -90.0
            for row in owner.models.prefix(24) {
                guard let fraction = owner.share(row), fraction > 0 else { continue }
                let end = min(270, start + fraction * 360)
                let color = NSColor.monitorModel(owner.palette.index(row.id))
                let lit = owner.highlighted == nil || owner.highlighted == row.id
                context.setStrokeColor((lit ? color : color.piOpacity(0.25)).cgColor)
                context.beginPath()
                // Flipped: clockwise on screen is increasing angle.
                context.addArc(center: center, radius: radius, startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: false)
                context.strokePath()
                start = end
            }
        }
    }

    /// One line shrunk to fit its width, down to 65 per cent (`.minimumScaleFactor(0.65)`).
    final class ScaledLine: DashView {
        var line = PiKit.Line("", font: .systemFont(ofSize: 15), color: .labelColor) {
            didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(line.text) }
        }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize { line.size(scale: piScale) }
        override func draw(_ dirtyRect: NSRect) { PiKit.drawScaled(line, in: bounds, minimumScale: 0.65, scale: piScale) }
    }

    /// A model's dot, its name cut in the middle, and its share.
    final class LegendRow: DashView {
        let model: MonitorDistribution
        let color: NSColor
        let share: Double?
        var onHover: ((Bool) -> Void)?
        private var tracking: NSTrackingArea?
        init(model: MonitorDistribution, color: NSColor, share: Double?) {
            self.model = model; self.color = color; self.share = share
            super.init(frame: .zero)
            toolTip = "\(model.id) · \(menuBarTokens(model.tokens)) output · \(gatewayUSD(model.cost))\nRequested as \(model.aliases.sorted().joined(separator: ", "))"
            setAccessibilityElement(true); setAccessibilityRole(.staticText)
            setAccessibilityLabel(model.id + ", " + shareText)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        private var shareText: String { share.map { String(format: "%.3f%%", $0 * 100) } ?? "—" }
        private var name: PiKit.Line { PiKit.Line(model.id, font: PiKit.Font.caption, color: .labelColor) }
        private var figure: PiKit.Line { PiKit.Line(shareText, font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .labelColor) }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: name.lineHeight) }
        override func draw(_ dirtyRect: NSRect) {
            let scale = piScale
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: 0, y: PiKit.round((bounds.height - 7) / 2, scale), width: 7, height: 7)).fill()
            let figureSize = figure.size(scale: scale)
            figure.draw(at: CGPoint(x: bounds.width - figureSize.width, y: 0), scale: scale)
            let room = max(0, bounds.width - 13 - figureSize.width)
            name.draw(in: CGRect(x: 13, y: 0, width: min(room, name.size(scale: scale).width), height: bounds.height), truncation: .middle, scale: scale)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}
